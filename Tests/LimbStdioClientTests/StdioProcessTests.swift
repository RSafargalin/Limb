#if os(macOS)
import Darwin
import Dispatch
import Foundation
import LimbCore
@testable import LimbStdioClient
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioProcessTests {
    @Test func cancelledLaunchDoesNotSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("spawned").path
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StdioProcess.launch(
                .init(executable: "/bin/sh", arguments: ["-c", #"printf spawned > "$1""#, "fixture", marker])
            )
        }

        do {
            let process = try await task.value
            _ = try await process.close()
            Issue.record("A pre-cancelled launch returned a process")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(arguments: [StartupInterruption.cancellation, .timeout])
    func interruptedLaunchHasPendingCleanup(_ interruption: StartupInterruption) async throws {
        let spawned = AsyncStream.makeStream(of: Int32.self)
        let releaseWorker = DispatchSemaphore(value: 0)
        let workerHasResumed = Mutex(false)
        defer { releaseWorker.signal() }

        let startup = StdioProcessStartup(
            .init(executable: "/bin/sleep", arguments: ["8"]),
            didSpawn: { pid in
                spawned.continuation.yield(pid)
                _ = releaseWorker.wait(timeout: .now() + .seconds(5))
                workerHasResumed.withLock { $0 = true }
            }
        )
        let launcher = Task {
            defer { spawned.continuation.finish() }
            return try await startup.launch(timeout: interruption == .timeout ? .seconds(1) : .seconds(6))
        }

        var pids = spawned.stream.makeAsyncIterator()
        let spawnedPID = await pids.next()
        let pid = try #require(spawnedPID)
        if interruption == .cancellation {
            launcher.cancel()
        }

        do {
            let process = try await launcher.value
            releaseWorker.signal()
            _ = try await process.close()
            Issue.record("An interrupted launch returned a process")
        } catch {
            switch interruption {
            case .cancellation:
                #expect(error is CancellationError)
            case .timeout:
                #expect(error as? StdioProcessError == .cleanupPending)
            }
        }

        #expect(!workerHasResumed.withLock { $0 })
        var status: Int32 = 0
        let waited = Darwin.waitpid(pid, &status, WNOHANG)
        #expect(waited == 0, "The child should still be running while the spawn worker is held")

        let waiterStarted = AsyncStream.makeStream(of: Void.self)
        let cleanupFinished = Mutex(false)
        let waiter = Task {
            waiterStarted.continuation.yield()
            waiterStarted.continuation.finish()
            await startup.waitForCleanup()
            cleanupFinished.withLock { $0 = true }
        }
        var started = waiterStarted.stream.makeAsyncIterator()
        _ = await started.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!cleanupFinished.withLock { $0 }, "Cleanup returned while the spawn worker was held")

        releaseWorker.signal()
        await waiter.value
        let cleanupWaited = Darwin.waitpid(pid, &status, WNOHANG)
        let cleanupErrno = errno
        #expect(cleanupWaited == -1 && cleanupErrno == ECHILD)
    }

    @Test func expiredWriteDeadlineDoesNotSendBytes() async throws {
        let process = try await launchShell(#"if read -r line; then printf '%s' "$line"; fi"#)
        await #expect(throws: StdioProcessError.writeTimedOut(bytesWritten: 0)) {
            try await process.write(Array("expired\n".utf8), deadline: .now - .seconds(1))
        }

        try await process.write(Array("valid\n".utf8), deadline: .now + .seconds(3))
        #expect(try await process.close() == .exited(0))
        #expect(try await readToEOF(process) == Array("valid".utf8))
    }

    @Test func guardedWriteLeavesStdinUntouchedWhenCorrelatedBootstrapReplyIsAvailable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("reply-written")
        let transcript = directory.appendingPathComponent("stdin")
        let inbox = StdioBootstrapInbox(maxFrameBytes: 4096)
        let discoveryID = try inbox.issueID()
        let unrelatedID = try inbox.issueID()
        let script = #"""
            printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"public"}}\n' "$1"
            : > "$2"
            while IFS= read -r line; do printf '%s\n' "$line"; done > "$3"
            """#
        let startup = StdioProcessStartup(
            .init(
                executable: "/bin/sh",
                arguments: ["-ec", script, "fixture", discoveryID.json.description, ready.path, transcript.path]
            ),
            bootstrap: inbox
        )
        let process = try await startup.launch(timeout: .seconds(3))
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while !FileManager.default.fileExists(atPath: ready.path) {
                try #require(ContinuousClock.now < deadline, "Child did not write the bootstrap reply")
                try await Task.sleep(for: .milliseconds(5))
            }

            let blocked = try await process.writeGuarded(
                Array("must-not-send\n".utf8),
                deadline: .now + .seconds(3),
                sealBootstrap: true,
                whileAllowed: { inbox.permitWrite(watching: discoveryID) }
            )
            #expect(!blocked)
            let allowed = try await process.writeGuarded(
                Array("allowed\n".utf8),
                deadline: .now + .seconds(3),
                whileAllowed: { inbox.permitWrite(watching: unrelatedID) }
            )
            #expect(allowed)
        } catch {
            _ = try? await process.close()
            throw error
        }
        #expect(try await process.close() == .exited(0))
        #expect(try String(contentsOf: transcript, encoding: .utf8) == "allowed\n")
    }

    @Test func registrationFailureAfterLaunchDeadline() async {
        let owner = StdioProcessOwner()
        let hookInvoked = Mutex(false)
        let configuration = StdioProcessConfiguration(executable: "/bin/sleep", arguments: ["3"])
        let launchDeadline = ContinuousClock.now + .seconds(1)

        do {
            let _: Int32 = try await withCheckedThrowingContinuation { continuation in
                let prepared = owner.prepareLaunch(continuation)
                #expect(prepared)
                guard prepared else { return }
                Thread.detachNewThread {
                    StdioProcessDriver.run(
                        configuration,
                        owner: owner,
                        launchDeadline: launchDeadline,
                        didSpawn: { _ throws(StdioProcessError) in
                            hookInvoked.withLock { $0 = true }
                            while ContinuousClock.now < launchDeadline {
                                Thread.sleep(forTimeInterval: 0.01)
                            }
                            throw .systemCall("kevent register", EINVAL)
                        }
                    )
                }
            }
            Issue.record("The driver returned a PID even though registration failed")
        } catch {
            #expect(error as? StdioProcessError == .cleanupPending)
        }

        #expect(hookInvoked.withLock { $0 }, "The deadline must expire after the child is spawned")
    }

    @Test func passesLiteralArgumentsEnvironmentAndWorkingDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = directory.resolvingSymlinksInPath().path
        let argument = "one two; $(printf substitution) * \"quoted\"\n"
        let environment = "literal $HOME; *"
        let process = try await StdioProcess.launch(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", #"printf '%s\000%s\000%s\000%s' "$1" "$2" "$LIMB_VALUE" "$PWD""#, "fixture", argument, ""],
                workingDirectory: workingDirectory,
                environment: ["LIMB_VALUE": environment]
            )
        )

        let output = try await readToEOF(process)
        let actual = output.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        try #require(actual.count == 4, "Unexpected fixture output: \(actual)")
        #expect(actual[0] == argument)
        #expect(actual[1].isEmpty)
        #expect(actual[2] == environment)
        let actualDirectory = try #require(canonicalPath(actual[3]))
        let expectedDirectory = try #require(canonicalPath(workingDirectory))
        #expect(actualDirectory == expectedDirectory)
        #expect(try await process.close() == .exited(0))
    }

    @Test func closeDeliversInputEOFAndPreservesFinalStdout() async throws {
        let process = try await launchShell("/bin/cat; printf 'final'")
        let input: [UInt8] = [0x00, 0x41, 0xff, 0x0a]
        try await process.write(input, deadline: .now + .seconds(3))

        #expect(try await process.close() == .exited(0))
        #expect(try await readToEOF(process) == input + "final".utf8)
        await #expect(throws: StdioProcessError.writeClosed(bytesWritten: 0)) {
            try await process.write([0x41], deadline: .now + .seconds(3))
        }
    }

    @Test func readsDescendantOutputAfterLeaderExits() async throws {
        let process = try await StdioProcess.launch(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "printf leader; (/bin/sleep 0.65; printf descendant) & exit 17"],
                drainGrace: .seconds(2)
            )
        )

        #expect(try await readToEOF(process) == Array("leaderdescendant".utf8))
        #expect(try await process.close() == .exited(17))
    }

    @Test func drainGraceBoundsDescendantsAndPreservesLeaderOutput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("descendant-finished").path
        let process = try await StdioProcess.launch(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    #"(/bin/sleep 1.2; printf late > "$1") & printf 'last frame\n'; exit 17"#,
                    "fixture",
                    marker,
                ],
                drainGrace: .milliseconds(150)
            )
        )
        let started = ContinuousClock.now
        let exit = try await process.close()
        let output = try await readToEOF(process)
        #expect(exit == .exited(17))
        #expect(output == Array("last frame\n".utf8))
        #expect(started.duration(to: .now) < .seconds(1))

        try await ContinuousClock().sleep(until: started + .milliseconds(1500))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func reapsQuicklyExitingChildren() async throws {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for _ in 0..<24 {
                tasks.addTask {
                    let process = try await StdioProcess.launch(.init(executable: "/usr/bin/true"))
                    let pid = process.pid
                    let exit = try await process.close()
                    var status: Int32 = 0
                    let waited = Darwin.waitpid(pid, &status, WNOHANG)
                    let waitError = errno
                    #expect(exit == .exited(0), "Unexpected exit for PID \(pid)")
                    #expect(waited == -1 && waitError == ECHILD, "waitpid(\(pid)) returned \(waited), errno \(waitError)")
                }
            }
            try await tasks.waitForAll()
        }
    }

    @Test func drainsLargeStderrAndKeepsOnlyItsTail() async throws {
        let process = try await launchShell(
            """
            (/usr/bin/head -c 1048576 /dev/zero; printf diagnostic) >&2 &
            writer=$!
            printf stdout
            wait "$writer"
            printf complete
            """,
            stderrLimit: 19
        )

        #expect(try await readToEOF(process) == Array("stdoutcomplete".utf8))
        #expect(try await process.close() == .exited(0))
        let expected = [UInt8](repeating: 0, count: 9) + "diagnostic".utf8
        #expect(process.stderrTail() == expected)
    }

    @Test func stdoutBackpressureLeavesStderrDrainAvailable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("stdout-finished").path
        let diagnostic = Array("stderr drained".utf8)
        let process = try await StdioProcess.launch(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    (/usr/bin/head -c 2097152 /dev/zero; printf 'stdout finished'; printf done > "$1") &
                    writer=$!
                    /bin/sleep 0.2
                    /usr/bin/head -c 262144 /dev/zero >&2
                    printf 'stderr drained' >&2
                    wait "$writer"
                    """,
                    "fixture",
                    marker,
                ],
                stderrLimit: diagnostic.count
            )
        )

        let deadline = ContinuousClock.now + .seconds(3)
        while process.stderrTail() != diagnostic && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(process.stderrTail() == diagnostic)
        #expect(!FileManager.default.fileExists(atPath: marker))

        let output = try await readToEOF(process)
        #expect(output.count == 2 * 1024 * 1024 + "stdout finished".utf8.count)
        #expect(output.dropLast("stdout finished".utf8.count).allSatisfy { $0 == 0 })
        #expect(output.suffix("stdout finished".utf8.count).elementsEqual("stdout finished".utf8))
        #expect(try await process.close() == .exited(0))
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    @Test func closedStdinDoesNotDeliverSIGPIPE() async {
        await #expect(processExitsWith: .success) {
            _ = Darwin.signal(SIGPIPE, SIG_DFL)
            let process = try await launchShell("exec 0<&-; printf R; exec /bin/sleep 2")
            guard try await process.read() == [0x52] else {
                Darwin.exit(1)
            }

            do {
                try await process.write([0x41], deadline: .now + .seconds(1))
                Darwin.exit(2)
            } catch {
                guard error as? StdioProcessError == .writeFailed(bytesWritten: 0, errno: EPIPE) else {
                    Darwin.exit(3)
                }
            }

            // The write must leave the process-wide disposition at its default.
            guard Darwin.signal(SIGPIPE, SIG_DFL) == nil else {
                Darwin.exit(4)
            }
            _ = try await process.close()
        }
    }

    @Test func closeEscalatesForChildIgnoringTerminateAndIsShared() async throws {
        let process = try await launchShell("trap '' TERM; printf R; exec /bin/sleep 4")
        #expect(try await process.read() == [0x52])
        #expect(Darwin.getpgid(process.pid) == process.pid)
        let started = ContinuousClock.now

        async let first = process.close()
        async let second = process.close()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await process.close()
        }

        let firstExit = try await first
        let secondExit = try await second
        #expect(firstExit == .signaled(SIGKILL))
        #expect(secondExit == .signaled(SIGKILL))
        #expect(try await cancelled.value == .signaled(SIGKILL))
        #expect(try await process.close() == .signaled(SIGKILL))
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func closeKeepsCleanupPendingResultAfterReaping() async throws {
        let startup = StdioProcessStartup(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; printf R; exec /bin/sleep 3"],
                inputGrace: .milliseconds(40),
                terminateGrace: .milliseconds(40),
                drainGrace: .zero,
                cleanupGrace: .zero
            )
        )
        let process = try await startup.launch()
        #expect(try await process.read() == [0x52])

        async let first: Void = expectCloseCleanupPending(process)
        async let second: Void = expectCloseCleanupPending(process)
        _ = await (first, second)

        await startup.waitForCleanup()
        var status: Int32 = 0
        let waited = Darwin.waitpid(process.pid, &status, WNOHANG)
        let waitError = errno
        #expect(waited == -1 && waitError == ECHILD)
        await expectCloseCleanupPending(process)
    }

    @Test func partialWriteDeadlineStopsLaterWrites() async throws {
        let process = try await StdioProcess.launch(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "printf R; /bin/sleep 0.75; exec /usr/bin/wc -c"],
                inputGrace: .seconds(2)
            )
        )
        #expect(try await process.read() == [0x52])
        let payload = [UInt8](repeating: 0x41, count: 2 * 1024 * 1024)
        let started = ContinuousClock.now

        var reportedPrefix: Int?
        do {
            try await process.write(payload, deadline: started + .milliseconds(300))
            Issue.record("A child holding stdin unread accepted the entire payload")
        } catch {
            if case .writeTimedOut(let bytesWritten) = error as? StdioProcessError {
                reportedPrefix = bytesWritten
                #expect(bytesWritten > 0)
                #expect(bytesWritten < payload.count)
            } else {
                Issue.record("Expected a partial write timeout, got \(error)")
            }
        }
        #expect(started.duration(to: .now) < .seconds(2))

        await #expect(throws: StdioProcessError.writeClosed(bytesWritten: 0)) {
            try await process.write([0x42], deadline: .now + .seconds(1))
        }
        #expect(try await process.close() == .exited(0))
        let childOutput = try await readToEOF(process)
        let byteCount = String(decoding: childOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(byteCount) == reportedPrefix)
    }

    @Test func closeWakesWriterAfterPartialTransfer() async throws {
        let process = try await launchShell(
            "/usr/bin/head -c 1 >/dev/null; printf R; exec /bin/sleep 4"
        )
        let payload = [UInt8](repeating: 0x41, count: 2 * 1024 * 1024)
        let writer = Task {
            try await process.write(payload, deadline: .now + .seconds(6))
        }

        // The child sends its acknowledgement after consuming the first byte.
        #expect(try await process.read() == [0x52])
        let started = ContinuousClock.now
        async let exit = process.close()

        do {
            try await writer.value
            Issue.record("The blocked write completed during shutdown")
        } catch {
            if case .writeClosed(let bytesWritten) = error as? StdioProcessError {
                #expect(bytesWritten > 0)
                #expect(bytesWritten < payload.count)
            } else {
                Issue.record("Expected shutdown to close the write, got \(error)")
            }
        }
        #expect(started.duration(to: .now) < .seconds(2))
        _ = try await exit
    }
}

enum StartupInterruption: Sendable {
    case cancellation
    case timeout
}

private func launchShell(_ script: String, stderrLimit: Int = 4096) async throws -> StdioProcess {
    try await StdioProcess.launch(
        .init(executable: "/bin/sh", arguments: ["-c", script], stderrLimit: stderrLimit)
    )
}

private func readToEOF(_ process: StdioProcess) async throws -> [UInt8] {
    var bytes: [UInt8] = []
    while let chunk = try await process.read() {
        bytes.append(contentsOf: chunk)
    }
    return bytes
}

private func expectCloseCleanupPending(_ process: StdioProcess) async {
    await #expect(throws: StdioProcessError.cleanupPending) {
        _ = try await process.close()
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "limb-stdio-process-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func canonicalPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { Darwin.free(resolved) }
    return String(cString: resolved)
}
#endif
