#if os(macOS)
import Darwin
import Foundation
import Limb
import Testing

private let loadExecutablePath = ProcessInfo.processInfo.environment["LIMB_RMCP_CLIENT_LOAD_STDIO"]
private let loadVersions: [ProtocolVersion] = [.v2025_03_26, .v2025_06_18, .v2025_11_25, .v2026_07_28]

@Suite(
    .enabled(
        if: loadExecutablePath != nil,
        "Set LIMB_RMCP_CLIENT_LOAD_STDIO to the absolute path of the RMCP load fixture"
    ),
    .serialized,
    .timeLimit(.minutes(3))
)
struct StdioClientRMCPLoadTests {
    private let requestOptions = ClientRequestOptions(timeout: .seconds(5))

    @Test(arguments: loadVersions)
    func routesConcurrentEchoes(_ version: ProtocolVersion) async throws {
        let finalSeconds = try finalPhaseSeconds()
        let reports = try reportDirectory()
        try await withClient(version) { client, executable in
            var previous = try await state(client)
            try #require(previous.isEmpty)
            let pid = previous.pid
            try confirmChild(pid, executable: executable)
            var phases: [PhaseReport] = []
            for (concurrency, seconds) in [(1, 2), (8, 2), (32, 2), (64, finalSeconds)] {
                let report = try await runPhase(
                    client, revision: version.rawValue, concurrency: concurrency, targetSeconds: seconds
                )
                let current = try await state(client)
                try #require(current.pid == pid)
                try #require(current.held == 0)
                try #require(current.received - previous.received == report.completed)
                try #require(current.returned - previous.returned == report.completed)
                phases.append(report)
                previous = current
                print(
                    "RMCP load \(version.rawValue) concurrency=\(concurrency) duration_s=\(report.durationSeconds) "
                        + "submitted=\(report.submitted) completed=\(report.completed) req/s=\(report.requestsPerSecond) "
                        + "p50/p95/p99_ms=\(report.p50Milliseconds)/\(report.p95Milliseconds)/\(report.p99Milliseconds) "
                        + "(\(PhaseReport.latencyMethod))"
                )
            }

            await client.close()
            try await waitForReaping(pid)
            try writeReport(
                SteadyReport(
                    revision: version.rawValue, pid: pid, latencyMethod: PhaseReport.latencyMethod, phases: phases,
                    peerReceived: previous.received, peerHeld: previous.held, peerReturned: previous.returned
                ),
                directory: reports, version: version, scenario: "steady"
            )
        }
    }

    @Test(arguments: loadVersions)
    func losesHeldCallsWithoutReplayingThem(_ version: ProtocolVersion) async throws {
        let reports = try reportDirectory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limb-rmcp-load-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("allow-relaunch"), options: .atomic)

        try await withClient(version, recoveryDirectory: directory) { client, executable in
            let initial = try await state(client)
            try #require(initial.isEmpty)
            let heldCalls = 32
            let killedAt = try await withThrowingTaskGroup(of: Void.self) { group in
                for sequence in 0..<heldCalls {
                    group.addTask {
                        let token = "\(version.rawValue)/held/\(sequence)"
                        do {
                            _ = try await client.callTool(
                                "fixture_load_echo", arguments: ["token": .string(token), "hold": .bool(true)],
                                options: .init(timeout: .seconds(15))
                            )
                        } catch ClientError.connectionLost(.unknown) {
                            return
                        } catch {
                            throw ScenarioError.unexpectedHeldError(token: token, error: String(describing: error))
                        }
                        throw ScenarioError.unexpectedHeldReply(token: token)
                    }
                }

                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while true {
                    let current = try await state(client)
                    try #require(current.pid == initial.pid && current.returned == 0)
                    if current.held == heldCalls {
                        try #require(current.received == heldCalls)
                        break
                    }
                    try #require(ContinuousClock.now < deadline, "Only \(current.held) of \(heldCalls) calls were held")
                    try await Task.sleep(for: .milliseconds(10))
                }

                try confirmChild(initial.pid, executable: executable)
                let killedAt = ContinuousClock.now
                try #require(kill(initial.pid, SIGKILL) == 0)
                try await group.waitForAll()
                return killedAt
            }

            try await waitForReaping(initial.pid)
            let replacement = try await waitForReplacement(client)
            let recoveredAt = ContinuousClock.now
            try #require(replacement.pid != initial.pid && replacement.isEmpty)
            try confirmChild(replacement.pid, executable: executable)
            let relaunchedPID = try String(
                contentsOf: directory.appendingPathComponent("relaunch-pid"), encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(pid_t(relaunchedPID) == replacement.pid)

            try await echo("\(version.rawValue)/replacement/sentinel", on: client)
            let replayMarker = directory.appendingPathComponent("load-replayed")
            let observationDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            repeat {
                try #require(!FileManager.default.fileExists(atPath: replayMarker.path))
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < observationDeadline
            let final = try await state(client)
            try #require(final.pid == replacement.pid)
            try #require(final.received == 1 && final.held == 0 && final.returned == 1)
            try #require(!FileManager.default.fileExists(atPath: replayMarker.path))

            await client.close()
            try await waitForReaping(replacement.pid)
            try #require(!FileManager.default.fileExists(atPath: replayMarker.path))
            try writeReport(
                RecoveryReport(
                    revision: version.rawValue, originalPID: initial.pid, replacementPID: replacement.pid,
                    heldCalls: heldCalls, connectionLostErrors: heldCalls,
                    recoverySeconds: seconds(killedAt.duration(to: recoveredAt)), sentinelReplies: final.returned,
                    replayed: false
                ),
                directory: reports, version: version, scenario: "recovery"
            )
        }
    }

    private func runPhase(
        _ client: Client, revision: String, concurrency: Int, targetSeconds: Int
    ) async throws -> PhaseReport {
        let start = ContinuousClock.now
        let stopSubmitting = start.advanced(by: .seconds(targetSeconds))
        let (counts, end) = try await withThrowingTaskGroup(of: (WorkerCounts, ContinuousClock.Instant).self) { group in
            for worker in 0..<concurrency {
                group.addTask {
                    var counts = WorkerCounts()
                    while ContinuousClock.now < stopSubmitting {
                        try Task.checkCancellation()
                        let token = "\(revision)/steady/\(concurrency)/\(worker)/\(counts.submitted)"
                        counts.submitted += 1
                        let sentAt = ContinuousClock.now
                        try await echo(token, on: client)
                        counts.record(milliseconds: seconds(sentAt.duration(to: .now)) * 1_000)
                    }
                    return (counts, .now)
                }
            }

            var total = WorkerCounts()
            var latestFinish = start
            for try await (worker, finishedAt) in group {
                try #require(worker.submitted == worker.completed && worker.completed > 0)
                total.merge(worker)
                latestFinish = max(latestFinish, finishedAt)
            }
            return (total, latestFinish)
        }
        let duration = seconds(start.duration(to: end))
        return PhaseReport(
            concurrency: concurrency, targetSeconds: targetSeconds, durationSeconds: duration,
            submitted: counts.submitted, completed: counts.completed,
            requestsPerSecond: Double(counts.completed) / duration,
            p50Milliseconds: counts.percentile(50), p95Milliseconds: counts.percentile(95),
            p99Milliseconds: counts.percentile(99)
        )
    }

    private func echo(_ token: String, on client: Client) async throws {
        let response = try await client.callTool(
            "fixture_load_echo", arguments: ["token": .string(token)], options: requestOptions
        )
        guard response.value.isError == false,
            response.value.content.count == 1,
            case let .text(reply, _, _)? = response.value.content.first, reply == token
        else {
            throw ScenarioError.invalidEcho(token: token, content: String(describing: response.value.content))
        }
    }

    private func state(_ client: Client) async throws -> FixtureState {
        let response = try await client.callTool("fixture_load_state", options: requestOptions)
        try #require(response.value.isError == false && response.value.content.count == 1)
        guard case let .text(value, _, _)? = response.value.content.first else {
            throw ScenarioError.nonTextState
        }
        let fields = value.split(separator: " ")
        try #require(fields.count == 4)
        let pid = try #require(pid_t(fields[0]))
        let counts = try fields.dropFirst().map { try #require(Int($0)) }
        try #require(pid > 1 && counts.allSatisfy { $0 >= 0 })
        return FixtureState(pid: pid, received: counts[0], held: counts[1], returned: counts[2])
    }

    private func waitForReplacement(_ client: Client) async throws -> FixtureState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while true {
            do {
                return try await state(client)
            } catch ClientError.recovering {
                try #require(ContinuousClock.now < deadline, "RMCP fixture did not recover")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func withClient(
        _ version: ProtocolVersion, recoveryDirectory: URL? = nil,
        _ body: (Client, URL) async throws -> Void
    ) async throws {
        let path = try #require(loadExecutablePath)
        try #require(path.hasPrefix("/"), "LIMB_RMCP_CLIENT_LOAD_STDIO must be an absolute path")
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try executable.resourceValues(forKeys: [.isRegularFileKey])
        try #require(
            attributes.isRegularFile == true && FileManager.default.isExecutableFile(atPath: executable.path),
            "LIMB_RMCP_CLIENT_LOAD_STDIO must point to an executable file"
        )

        let modern = version.rawValue == ProtocolVersion.v2026_07_28.rawValue
        let client = try await Client.connect(
            stdio: .init(executable: executable.path, arguments: recoveryDirectory.map { [$0.path] } ?? []),
            options: .init(
                timeout: .seconds(5), discoveryTimeout: .seconds(5), maxPending: 128,
                legacyVersion: modern ? nil : version,
                recovery: recoveryDirectory == nil ? nil : .init(backoff: .milliseconds(50))
            )
        )
        do {
            try #require(client.protocolVersion.rawValue == version.rawValue)
            try #require(client.serverInfo?.name == "limb-rmcp-subscriptions")
            try #require(client.serverInfo?.version == "0.1.0")
            try await body(client, executable)
        } catch {
            await client.close()
            throw error
        }
    }

    private func confirmChild(_ pid: pid_t, executable: URL) throws {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let mibCount = UInt32(mib.count)
        try #require(sysctl(&mib, mibCount, &info, &size, nil, 0) == 0)
        try #require(size == MemoryLayout<kinfo_proc>.stride && info.kp_eproc.e_ppid == getpid())

        // Darwin defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN.
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let capacity = UInt32(bytes.count)
        let length = proc_pidpath(pid, &bytes, capacity)
        try #require(length > 0)
        let path = String(decoding: bytes.prefix(Int(length)), as: UTF8.self)
        try #require(URL(fileURLWithPath: path).resolvingSymlinksInPath().path == executable.path)
    }

    private func waitForReaping(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try #require(ContinuousClock.now < deadline, "Fixture child \(pid) was not reaped")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finalPhaseSeconds() throws -> Int {
        guard let value = ProcessInfo.processInfo.environment["LIMB_CLIENT_LOAD_SECONDS"] else { return 60 }
        let seconds = try #require(Int(value), "LIMB_CLIENT_LOAD_SECONDS must be a positive integer")
        try #require(seconds > 0, "LIMB_CLIENT_LOAD_SECONDS must be a positive integer")
        return seconds
    }

    private func reportDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["LIMB_CLIENT_LOAD_REPORT_DIR"] else { return nil }
        try #require(path.hasPrefix("/"), "LIMB_CLIENT_LOAD_REPORT_DIR must be an absolute directory")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        try #require(exists && isDirectory.boolValue, "LIMB_CLIENT_LOAD_REPORT_DIR must name an existing directory")
        return directory
    }

    private func writeReport(
        _ report: some Encodable, directory: URL?, version: ProtocolVersion, scenario: String
    ) throws {
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = directory.appendingPathComponent("rmcp-client-load-\(version.rawValue)-\(scenario).json")
        try encoder.encode(report).write(to: destination, options: .atomic)
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private struct FixtureState {
        let pid: pid_t
        let received: Int
        let held: Int
        let returned: Int

        var isEmpty: Bool { received == 0 && held == 0 && returned == 0 }
    }

    private struct WorkerCounts {
        private static let bucketsPerMillisecond = 100.0

        var submitted = 0
        private(set) var completed = 0
        private var histogram = [Int](repeating: 0, count: 10_001)
        private var maximumMilliseconds: Double = 0

        mutating func record(milliseconds: Double) {
            let bucket = min(Int((milliseconds * Self.bucketsPerMillisecond).rounded(.up)), histogram.count - 1)
            histogram[bucket] += 1
            completed += 1
            maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        }

        mutating func merge(_ other: Self) {
            submitted += other.submitted
            completed += other.completed
            for bucket in histogram.indices {
                histogram[bucket] += other.histogram[bucket]
            }
            maximumMilliseconds = max(maximumMilliseconds, other.maximumMilliseconds)
        }

        func percentile(_ percentile: Int) -> Double {
            let rank = (completed * percentile + 99) / 100
            var count = 0
            for bucket in histogram.indices {
                count += histogram[bucket]
                if count >= rank {
                    let upperBound = bucket == histogram.count - 1
                        ? (maximumMilliseconds * Self.bucketsPerMillisecond).rounded(.up)
                        : Double(bucket)
                    return upperBound / Self.bucketsPerMillisecond
                }
            }
            preconditionFailure("A completed latency sample was missing from the histogram")
        }
    }

    private struct PhaseReport: Encodable {
        static let latencyMethod = "nearest rank, 10 µs upper-bound bins through 100 ms, maximum for the final bin"

        let concurrency: Int
        let targetSeconds: Int
        let durationSeconds: Double
        let submitted: Int
        let completed: Int
        let requestsPerSecond: Double
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let p99Milliseconds: Double
    }

    private struct SteadyReport: Encodable {
        let revision: String
        let pid: pid_t
        let latencyMethod: String
        let phases: [PhaseReport]
        let peerReceived: Int
        let peerHeld: Int
        let peerReturned: Int
    }

    private struct RecoveryReport: Encodable {
        let revision: String
        let originalPID: pid_t
        let replacementPID: pid_t
        let heldCalls: Int
        let connectionLostErrors: Int
        let recoverySeconds: Double
        let sentinelReplies: Int
        let replayed: Bool
    }

    private enum ScenarioError: Error {
        case invalidEcho(token: String, content: String)
        case nonTextState
        case unexpectedHeldReply(token: String)
        case unexpectedHeldError(token: String, error: String)
    }
}
#endif
