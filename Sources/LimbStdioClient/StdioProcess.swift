#if os(macOS)
import Darwin
import Foundation
import LimbCore
import Synchronization

package struct StdioProcessConfiguration: Sendable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String: String]?
    let stderrLimit: Int
    let inputGrace: Duration
    let terminateGrace: Duration
    let drainGrace: Duration
    let cleanupGrace: Duration

    package init(
        executable: String, arguments: [String] = [], workingDirectory: String? = nil,
        environment: [String: String]? = nil, stderrLimit: Int = 4096,
        inputGrace: Duration = .milliseconds(200), terminateGrace: Duration = .milliseconds(200),
        drainGrace: Duration = .milliseconds(250), cleanupGrace: Duration = .seconds(2)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stderrLimit = stderrLimit
        self.inputGrace = inputGrace
        self.terminateGrace = terminateGrace
        self.drainGrace = drainGrace
        self.cleanupGrace = cleanupGrace
    }

    func validate(timeout: Duration) throws(StdioProcessError) {
        func validPath(_ value: String) -> Bool {
            value.hasPrefix("/") && !value.utf8.contains(0)
        }
        guard validPath(executable), workingDirectory.map(validPath) ?? true,
              arguments.allSatisfy({ !$0.utf8.contains(0) }), stderrLimit >= 0,
              timeout > .zero, timeout <= .seconds(Int32.max),
              [inputGrace, terminateGrace, drainGrace, cleanupGrace]
                .allSatisfy({ $0 >= .zero && $0 <= .seconds(Int32.max) }),
              environment?.allSatisfy({ key, value in
                  !key.isEmpty && !key.utf8.contains(0) && !key.utf8.contains(0x3d) && !value.utf8.contains(0)
              }) ?? true else {
            throw .invalidConfiguration
        }
    }
}

package enum StdioProcessExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

package enum StdioProcessError: Error, Equatable, Sendable {
    case invalidConfiguration
    case systemCall(String, Int32)
    case busy
    case writeTimedOut(bytesWritten: Int)
    case writeClosed(bytesWritten: Int)
    case writeInterrupted
    case writeFailed(bytesWritten: Int, errno: Int32)
    case cleanupPending
}

/// Owns one child and its stdio until closure and reaping finish.
package final class StdioProcess: Sendable {
    private let owner: StdioProcessOwner
    package let pid: Int32

    fileprivate init(owner: StdioProcessOwner, pid: Int32) {
        self.owner = owner
        self.pid = pid
    }

    package static func launch(
        _ configuration: StdioProcessConfiguration, timeout: Duration = .seconds(5)
    ) async throws -> StdioProcess {
        try await StdioProcessStartup(configuration).launch(timeout: timeout)
    }

    /// The single outstanding write owns the entire byte sequence and its absolute deadline.
    package func write(_ bytes: [UInt8], deadline: ContinuousClock.Instant) async throws {
        _ = try await writeGuarded(bytes, deadline: deadline)
    }

    // Check the gate on the worker immediately before its first write, after servicing stdout.
    func writeGuarded(
        _ bytes: [UInt8], deadline: ContinuousClock.Instant, sealBootstrap: Bool = false,
        whileAllowed: (@Sendable () -> Bool)? = nil
    ) async throws -> Bool {
        let ticket = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                owner.submitWrite(
                    bytes, deadline: deadline, ticket: ticket, sealBootstrap: sealBootstrap,
                    whileAllowed: whileAllowed, continuation: continuation)
            }
        } onCancel: {
            owner.cancelWrite(ticket)
        }
    }

    func detachBootstrap(until deadline: ContinuousClock.Instant) throws -> LineFramer {
        try owner.state.withLock { state throws(StdioNegotiationError) in
            guard let bootstrap = state.bootstrap else { throw .connectionLost }
            let handoff = try bootstrap.handoff(until: deadline)
            if !state.bootstrapSealed, state.publishedClosed { throw .connectionLost }
            state.bootstrap = nil
            return handoff
        }
    }

    /// Read one bounded chunk of stdout; nil marks the end after any buffered chunks.
    package func read() async throws -> [UInt8]? {
        let ticket = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                owner.read(ticket, continuation: continuation)
            }
        } onCancel: {
            owner.cancelRead(ticket)
        }
    }

    package func stderrTail() -> [UInt8] { owner.state.withLock { $0.stderr } }

    /// Close stdin, wait for the escalation and drain phases, and return the child's status.
    /// Cleanup continues to own the process if it outlives the caller's wait.
    package func close() async throws -> StdioProcessExit {
        try await withCheckedThrowingContinuation { owner.close($0) }
    }

    deinit { owner.requestClose() }
}

/// One launch attempt. Keep this handle after cancellation or an expired launch deadline so
/// a replacement can wait for the original worker to close its descriptors and reap the child.
package final class StdioProcessStartup: Sendable {
    private let owner = StdioProcessOwner()
    private let configuration: StdioProcessConfiguration
    private let didSpawn: (@Sendable (Int32) throws(StdioProcessError) -> Void)?

    package convenience init(_ configuration: StdioProcessConfiguration) {
        self.init(configuration, didSpawn: nil)
    }

    init(
        _ configuration: StdioProcessConfiguration, bootstrap: StdioBootstrapInbox? = nil,
        didSpawn: (@Sendable (Int32) throws(StdioProcessError) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.didSpawn = didSpawn
        owner.state.withLock { $0.bootstrap = bootstrap }
    }

    package func launch(timeout: Duration = .seconds(5)) async throws -> StdioProcess {
        guard owner.state.withLock({ state in
            if state.startupClaimed { return false }
            state.startupClaimed = true
            return true
        }) else { throw StdioProcessError.busy }
        do {
            try Task.checkCancellation()
            try configuration.validate(timeout: timeout)
        } catch {
            owner.completeCleanup()
            throw error
        }

        let deadline = ContinuousClock.now + timeout
        let timer = Task { [owner] in
            do {
                try await ContinuousClock().sleep(until: deadline)
                owner.abortLaunch(StdioProcessError.cleanupPending)
            } catch {}
        }
        defer { timer.cancel() }
        let pid = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if owner.prepareLaunch(continuation) {
                    do throws(StdioProcessError) {
                        try startProcessWorker { [configuration, owner, didSpawn] in
                            StdioProcessDriver.run(configuration, owner: owner, launchDeadline: deadline, didSpawn: didSpawn)
                        }
                    } catch {
                        owner.completeLaunch(.failure(error), before: deadline)
                        owner.completeCleanup()
                    }
                } else {
                    owner.completeCleanup()
                }
            }
        } onCancel: { [owner] in
            owner.abortLaunch(CancellationError())
        }
        if Task.isCancelled {
            owner.requestClose()
            throw CancellationError()
        }
        return StdioProcess(owner: owner, pid: pid)
    }

    /// Join an attempt that has started, including one that returned before spawning finished.
    package func waitForCleanup() async {
        await withCheckedContinuation { continuation in
            owner.state.withLock { state in
                if state.cleanupComplete { continuation.resume() }
                else { state.cleanupWaiters.append(continuation) }
            }
        }
    }

    /// Wait within the caller's connection budget while the worker retains cleanup ownership.
    func waitForCleanup(until deadline: ContinuousClock.Instant) async throws {
        let ticket = UUID()
        let timer = Task { [owner] in
            do {
                try await ContinuousClock().sleep(until: deadline)
                owner.endCleanupWait(ticket, with: StdioNegotiationError.cleanupPending)
            } catch {}
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                owner.state.withLock { state in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if state.cleanupComplete {
                        continuation.resume()
                    } else if ContinuousClock.now >= deadline {
                        continuation.resume(throwing: StdioNegotiationError.cleanupPending)
                    } else {
                        state.boundedCleanupWaiters[ticket] = .init(deadline: deadline, continuation: continuation)
                    }
                }
            }
        } onCancel: { [owner] in
            owner.endCleanupWait(ticket, with: CancellationError())
        }
    }
}

final class StdioProcessOwner: Sendable {
    struct CleanupWait {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    struct Write {
        let ticket: UUID
        let bytes: [UInt8]
        let deadline: ContinuousClock.Instant
        let sealBootstrap: Bool
        let whileAllowed: (@Sendable () -> Bool)?
        let continuation: CheckedContinuation<Bool, any Error>
        var written = 0
    }

    struct State {
        var eventQueue: Int32?
        var startupClaimed = false
        var launch: CheckedContinuation<Int32, any Error>?
        var launchAborted: (any Error)?
        var launchCompleted = false
        var closingSince: ContinuousClock.Instant?
        var publishedClosed = false
        var write: Write?
        var read: (UUID, CheckedContinuation<[UInt8]?, any Error>)?
        var stdout: [UInt8] = []
        var bootstrap: StdioBootstrapInbox?
        var bootstrapSealed = false
        var stderr: [UInt8] = []
        var outputEnded: Result<Void, StdioProcessError>?
        var closeWaiters: [CheckedContinuation<StdioProcessExit, any Error>] = []
        var closeResult: Result<StdioProcessExit, StdioProcessError>?
        var cleanupComplete = false
        var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
        var boundedCleanupWaiters: [UUID: CleanupWait] = [:]

        mutating func beginClose() {
            if closingSince == nil { closingSince = .now }
            publishedClosed = true
        }

        mutating func finishWrite(_ error: StdioProcessError? = nil, didWrite: Bool = true) {
            let current = write
            write = nil
            if let error { current?.continuation.resume(throwing: error) }
            else { current?.continuation.resume(returning: didWrite) }
        }

        mutating func interruptWrite(_ current: Write) {
            if current.written == 0 {
                finishWrite(didWrite: false)
            } else {
                // No further bytes may be sent to a process with an abandoned frame.
                publishedClosed = true
                finishWrite(.writeInterrupted)
            }
        }

        mutating func deliverOutput() {
            guard let (_, continuation) = read else { return }
            if !stdout.isEmpty {
                let bytes = stdout
                stdout = []
                read = nil
                continuation.resume(returning: bytes)
            } else if let outputEnded {
                read = nil
                continuation.resume(with: outputEnded.map { nil as [UInt8]? })
            }
        }

        mutating func completeClose(_ result: Result<StdioProcessExit, StdioProcessError>) {
            // Keep the shared result even if a retained worker finishes later.
            guard closeResult == nil else { return }
            closeResult = result
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters { waiter.resume(with: result) }
        }

        func wake() {
            if let eventQueue { triggerProcessWorker(eventQueue) }
        }
    }

    let state = Mutex(State())

    func completeCleanup() {
        state.withLock { state in
            state.cleanupComplete = true
            let waiters = state.cleanupWaiters
            state.cleanupWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            let bounded = state.boundedCleanupWaiters.values
            state.boundedCleanupWaiters.removeAll()
            let now = ContinuousClock.now
            for wait in bounded {
                if now < wait.deadline { wait.continuation.resume() }
                else { wait.continuation.resume(throwing: StdioNegotiationError.cleanupPending) }
            }
        }
    }

    func endCleanupWait(_ ticket: UUID, with error: any Error) {
        state.withLock { state in
            state.boundedCleanupWaiters.removeValue(forKey: ticket)?.continuation.resume(throwing: error)
        }
    }

    func prepareLaunch(_ continuation: CheckedContinuation<Int32, any Error>) -> Bool {
        state.withLock { state in
            if let aborted = state.launchAborted {
                continuation.resume(throwing: aborted)
                return false
            }
            state.launch = continuation
            return true
        }
    }

    func abortLaunch(_ error: any Error) {
        state.withLock { state in
            guard !state.launchCompleted, state.launchAborted == nil else { return }
            state.launchAborted = error
            state.beginClose()
            state.launch?.resume(throwing: error)
            state.launch = nil
            state.wake()
        }
    }

    func completeLaunch(_ result: Result<Int32, StdioProcessError>, before deadline: ContinuousClock.Instant) {
        state.withLock { state in
            guard !state.launchCompleted, state.launchAborted == nil else { return }
            state.launchCompleted = true
            let continuation = state.launch
            state.launch = nil
            if ContinuousClock.now >= deadline {
                state.beginClose()
                continuation?.resume(throwing: StdioProcessError.cleanupPending)
            } else {
                continuation?.resume(with: result)
            }
        }
    }

    func requestClose() {
        state.withLock { state in
            state.beginClose()
            state.wake()
        }
    }

    func close(_ continuation: CheckedContinuation<StdioProcessExit, any Error>) {
        state.withLock { state in
            if let result = state.closeResult {
                continuation.resume(with: result)
            } else {
                state.closeWaiters.append(continuation)
                state.beginClose()
                state.wake()
            }
        }
    }

    func submitWrite(
        _ bytes: [UInt8], deadline: ContinuousClock.Instant, ticket: UUID, sealBootstrap: Bool,
        whileAllowed: (@Sendable () -> Bool)?, continuation: CheckedContinuation<Bool, any Error>
    ) {
        state.withLock { state in
            if state.publishedClosed || Task.isCancelled {
                continuation.resume(throwing: StdioProcessError.writeClosed(bytesWritten: 0))
            } else if ContinuousClock.now >= deadline {
                continuation.resume(throwing: StdioProcessError.writeTimedOut(bytesWritten: 0))
            } else if state.write != nil {
                continuation.resume(throwing: StdioProcessError.busy)
            } else if bytes.isEmpty {
                continuation.resume(returning: true)
            } else {
                state.write = Write(
                    ticket: ticket, bytes: bytes, deadline: deadline, sealBootstrap: sealBootstrap,
                    whileAllowed: whileAllowed, continuation: continuation)
                state.wake()
            }
        }
    }

    func cancelWrite(_ ticket: UUID) {
        state.withLock { state in
            guard let write = state.write, write.ticket == ticket else { return }
            if write.written != 0 { state.beginClose() }
            state.finishWrite(.writeClosed(bytesWritten: write.written))
            state.wake()
        }
    }

    func read(_ ticket: UUID, continuation: CheckedContinuation<[UInt8]?, any Error>) {
        state.withLock { state in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else if state.read != nil {
                continuation.resume(throwing: StdioProcessError.busy)
            } else {
                state.read = (ticket, continuation)
                state.deliverOutput()
                state.wake()
            }
        }
    }

    func cancelRead(_ ticket: UUID) {
        state.withLock { state in
            guard let (current, continuation) = state.read, current == ticket else { return }
            state.read = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}

private final class StdioProcessWorker {
    let body: @Sendable () -> Void

    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
}

private func startProcessWorker(_ body: @escaping @Sendable () -> Void) throws(StdioProcessError) {
    var attributes = pthread_attr_t()
    let initialized = pthread_attr_init(&attributes)
    guard initialized == 0 else { throw .systemCall("pthread_attr_init", initialized) }
    defer { pthread_attr_destroy(&attributes) }
    let detached = pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))
    guard detached == 0 else { throw .systemCall("pthread_attr_setdetachstate", detached) }

    let context = Unmanaged.passRetained(StdioProcessWorker(body))
    var thread: pthread_t?
    let started = pthread_create(&thread, &attributes, { context in
        let worker = Unmanaged<StdioProcessWorker>.fromOpaque(context).takeRetainedValue()
        worker.body()
        return nil
    }, context.toOpaque())
    guard started == 0 else {
        context.release()
        throw .systemCall("pthread_create", started)
    }
}
#endif
