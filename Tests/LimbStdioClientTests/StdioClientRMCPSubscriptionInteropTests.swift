#if os(macOS)
import Darwin
import Foundation
import Limb
import Testing

private let rmcpSubscriptionsExecutable = ProcessInfo.processInfo.environment["LIMB_RMCP_SUBSCRIPTIONS_STDIO"]
private let rmcpSubscriptionVersions: [ProtocolVersion] = [.v2025_03_26, .v2025_06_18, .v2025_11_25, .v2026_07_28]

@Suite(
    .enabled(
        if: rmcpSubscriptionsExecutable != nil,
        "Set LIMB_RMCP_SUBSCRIPTIONS_STDIO to the absolute path of the RMCP subscriptions fixture"
    ),
    .timeLimit(.minutes(1))
)
struct StdioClientRMCPSubscriptionInteropTests {
    private let alpha = "fixture://subscriptions/alpha"
    private let beta = "fixture://subscriptions/beta"
    private let requestOptions = ClientRequestOptions(timeout: .seconds(3))

    @Test(arguments: rmcpSubscriptionVersions)
    func routesParallelSubscriptionsAndCancelsIndependently(_ version: ProtocolVersion) async throws {
        try await withClient(version) { client in
            let (alphaSubscription, betaSubscription) = try await openSubscriptions(client, version: version)
            var alphaEvents = alphaSubscription.makeAsyncIterator()
            var betaEvents = betaSubscription.makeAsyncIterator()
            let initial = try await waitForRegistrations(client, alpha: 1, beta: 1)
            #expect(initial.alphaOpened == 1)
            #expect(initial.betaOpened == 1)
            #expect(initial.alphaRequestedTools == isModern(version))

            try await publish(beta, on: client, expected: 1)
            try #require(try await betaEvents.next() == .resourceUpdated(uri: beta))
            // Legacy notifications can identify a sub-resource without identifying its subscription.
            if !isModern(version) {
                let invalidation = try await alphaEvents.next()
                try #require(invalidation == .resourceInvalidated(uri: alpha))
            }
            try await publish(alpha, on: client, expected: 1)
            let alphaUpdate = try await alphaEvents.next()
            try #require(alphaUpdate == .resourceUpdated(uri: alpha))
            if !isModern(version) {
                let invalidation = try await betaEvents.next()
                try #require(invalidation == .resourceInvalidated(uri: beta))
            }

            await alphaSubscription.cancel()
            try #require(try await alphaEvents.next() == nil)
            let surviving = try await waitForRegistrations(client, alpha: 0, beta: 1)
            #expect(surviving.pid == initial.pid)
            #expect(surviving.alphaOpened == 1)
            #expect(surviving.betaOpened == 1)
            try await publish(alpha, on: client, expected: 0)
            try await publish(beta, on: client, expected: 1)
            try #require(try await betaEvents.next() == .resourceUpdated(uri: beta))
        }
    }

    @Test(arguments: rmcpSubscriptionVersions)
    func reopensBothSubscriptionsAfterSIGKILL(_ version: ProtocolVersion) async throws {
        try await withClient(version, recover: true) { client in
            let (alphaSubscription, betaSubscription) = try await openSubscriptions(client, version: version)
            var alphaEvents = alphaSubscription.makeAsyncIterator()
            var betaEvents = betaSubscription.makeAsyncIterator()
            let initial = try await waitForRegistrations(client, alpha: 1, beta: 1)
            #expect(initial.alphaRequestedTools == isModern(version))

            try killFixture(initial.pid)
            try #require(try await alphaEvents.next() == .interrupted)
            try #require(try await betaEvents.next() == .interrupted)
            try #require(try await alphaEvents.next() == .resubscribed(confirmedFilter: filter(for: alpha)))
            try #require(try await betaEvents.next() == .resubscribed(confirmedFilter: filter(for: beta)))

            let replacement = try await waitForRegistrations(client, alpha: 1, beta: 1)
            try #require(replacement.pid != initial.pid)
            #expect(replacement.alphaOpened == 1)
            #expect(replacement.betaOpened == 1)
            #expect(replacement.alphaRequestedTools == isModern(version))
            try await waitForReaping(initial.pid)

            try await publish(alpha, on: client, expected: 1)
            try #require(try await alphaEvents.next() == .resourceUpdated(uri: alpha))
            if !isModern(version) {
                let invalidation = try await betaEvents.next()
                try #require(invalidation == .resourceInvalidated(uri: beta))
            }
            try await publish(beta, on: client, expected: 1)
            let betaUpdate = try await betaEvents.next()
            try #require(betaUpdate == .resourceUpdated(uri: beta))
            if !isModern(version) {
                let invalidation = try await alphaEvents.next()
                try #require(invalidation == .resourceInvalidated(uri: alpha))
            }
            try await publish(alpha, on: client, expected: 1)
            try #require(try await alphaEvents.next() == .resourceUpdated(uri: alpha))
            if !isModern(version) {
                let invalidation = try await betaEvents.next()
                try #require(invalidation == .resourceInvalidated(uri: beta))
            }

            await client.close()
            try #require(try await alphaEvents.next() == nil)
            try #require(try await betaEvents.next() == nil)
            try await waitForReaping(replacement.pid)
        }
    }

    @Test(arguments: rmcpSubscriptionVersions)
    func cancellationDuringGatedNegotiationSuppressesReopening(_ version: ProtocolVersion) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limb-rmcp-subscriptions-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withClient(version, recover: true, arguments: [directory.path]) { client in
            let (alphaSubscription, betaSubscription) = try await openSubscriptions(client, version: version)
            var alphaEvents = alphaSubscription.makeAsyncIterator()
            var betaEvents = betaSubscription.makeAsyncIterator()
            let initial = try await waitForRegistrations(client, alpha: 1, beta: 1)
            #expect(initial.alphaRequestedTools == isModern(version))

            try killFixture(initial.pid)
            try #require(try await alphaEvents.next() == .interrupted)
            try #require(try await betaEvents.next() == .interrupted)
            let gatePID = try await waitForRelaunch(in: directory)
            try #require(gatePID != initial.pid)

            await alphaSubscription.cancel()
            try #require(try await alphaEvents.next() == nil)
            try Data().write(to: directory.appendingPathComponent("allow-relaunch"), options: .atomic)

            try #require(try await betaEvents.next() == .resubscribed(confirmedFilter: filter(for: beta)))
            let replacement = try await waitForRegistrations(client, alpha: 0, beta: 1)
            #expect(replacement.pid == gatePID)
            #expect(replacement.alphaOpened == 0)
            #expect(replacement.betaOpened == 1)
            #expect(!replacement.alphaRequestedTools)
            try await publish(alpha, on: client, expected: 0)
            try await publish(beta, on: client, expected: 1)
            try #require(try await betaEvents.next() == .resourceUpdated(uri: beta))

            // Give a delayed replay a chance to reach the replacement before checking the final state.
            let alphaAttempt = directory.appendingPathComponent("alpha-attempted")
            try await Task.sleep(for: .milliseconds(250))
            let surviving = try await state(client)
            #expect(surviving.pid == replacement.pid)
            #expect(surviving.alphaActive == 0)
            #expect(surviving.betaActive == 1)
            #expect(surviving.alphaOpened == 0)
            #expect(surviving.betaOpened == 1)
            #expect(!surviving.alphaRequestedTools)
            #expect(!FileManager.default.fileExists(atPath: alphaAttempt.path))

            await client.close()
            try await waitForReaping(replacement.pid)
            #expect(!FileManager.default.fileExists(atPath: alphaAttempt.path))
        }
    }

    private func openSubscriptions(_ client: Client, version: ProtocolVersion) async throws
        -> (ClientSubscription, ClientSubscription)
    {
        async let alphaSubscription = client.subscribe(
            filter: .init(toolsListChanged: isModern(version), resourceSubscriptions: [alpha]), timeout: .seconds(3)
        )
        async let betaSubscription = client.subscribe(filter: filter(for: beta), timeout: .seconds(3))
        let (first, second) = try await (alphaSubscription, betaSubscription)
        try #require(first.confirmedFilter == filter(for: alpha))
        try #require(second.confirmedFilter == filter(for: beta))
        return (first, second)
    }

    private func filter(for uri: String) -> ClientSubscriptionFilter {
        .init(resourceSubscriptions: [uri])
    }

    private func isModern(_ version: ProtocolVersion) -> Bool {
        version.rawValue == ProtocolVersion.v2026_07_28.rawValue
    }

    private func withClient(
        _ version: ProtocolVersion,
        recover: Bool = false,
        arguments: [String] = [],
        _ body: (Client) async throws -> Void
    ) async throws {
        let path = try #require(rmcpSubscriptionsExecutable)
        try #require(path.hasPrefix("/"), "LIMB_RMCP_SUBSCRIPTIONS_STDIO must be an absolute path")
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try executable.resourceValues(forKeys: [.isRegularFileKey])
        try #require(
            attributes.isRegularFile == true && FileManager.default.isExecutableFile(atPath: executable.path),
            "LIMB_RMCP_SUBSCRIPTIONS_STDIO must point to an executable file"
        )
        let pin = isModern(version) ? nil : version
        let client = try await Client.connect(
            stdio: .init(executable: executable.path, arguments: arguments),
            options: .init(
                timeout: .seconds(5), discoveryTimeout: .seconds(5), legacyVersion: pin,
                recovery: recover ? .init(backoff: .milliseconds(50)) : nil
            )
        )

        // Event iteration has no per-call deadline. Close the client to unblock a stalled stream.
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            Issue.record("RMCP subscription scenario exceeded its deadline")
            await client.close()
        }
        defer { watchdog.cancel() }
        do {
            try #require(client.protocolVersion.rawValue == version.rawValue)
            try #require(client.serverInfo?.name == "limb-rmcp-subscriptions")
            try #require(client.serverInfo?.version == "0.1.0")
            try await body(client)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    private struct FixtureState: CustomStringConvertible {
        let pid: pid_t
        let alphaActive: Int
        let betaActive: Int
        let alphaOpened: Int
        let betaOpened: Int
        let alphaRequestedTools: Bool

        var description: String {
            "pid=\(pid), alpha=\(alphaActive)/\(alphaOpened), beta=\(betaActive)/\(betaOpened) (active/opened)"
        }
    }

    private func state(_ client: Client) async throws -> FixtureState {
        let result = try await client.callTool("fixture_state", options: requestOptions)
        try #require(result.value.isError == false)
        let values = try textContent(result.value.content).split(separator: " ")
        try #require(values.count == 6)
        let pid = try #require(pid_t(values[0]))
        let counts = try values[1..<5].map { try #require(Int($0)) }
        let requestedTools = try #require(Int(values[5]))
        try #require(pid > 1 && counts.allSatisfy { $0 >= 0 })
        try #require(requestedTools == 0 || requestedTools == 1)
        return FixtureState(
            pid: pid, alphaActive: counts[0], betaActive: counts[1], alphaOpened: counts[2], betaOpened: counts[3],
            alphaRequestedTools: requestedTools == 1
        )
    }

    private func textContent(_ content: [ContentBlock]) throws -> String {
        try #require(content.count == 1)
        guard case let .text(encoded, _, _)? = content.first else {
            throw FixtureResponseError.expectedText
        }
        return encoded
    }

    private enum FixtureResponseError: Error {
        case expectedText
    }

    private func waitForRegistrations(_ client: Client, alpha: Int, beta: Int) async throws -> FixtureState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let current = try await state(client)
            if current.alphaActive == alpha && current.betaActive == beta {
                return current
            }
            try #require(ContinuousClock.now < deadline, "Expected \(alpha) alpha and \(beta) beta registrations, got \(current)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func publish(_ uri: String, on client: Client, expected: Int) async throws {
        let result = try await client.callTool(
            "fixture_publish", arguments: ["uri": .string(uri)], options: requestOptions
        )
        try #require(result.value.isError == false)
        try #require(try textContent(result.value.content) == String(expected), "Unexpected notification count for \(uri)")
    }

    private func killFixture(_ pid: pid_t) throws {
        let executable = try #require(rmcpSubscriptionsExecutable)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let mibCount = UInt32(mib.count)
        try #require(sysctl(&mib, mibCount, &info, &size, nil, 0) == 0)
        try #require(size == MemoryLayout<kinfo_proc>.stride && info.kp_eproc.e_ppid == getpid())
        // Darwin defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN in its C headers.
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let capacity = UInt32(bytes.count)
        let length = proc_pidpath(pid, &bytes, capacity)
        try #require(length > 0)
        let processPath = String(decoding: bytes.prefix(Int(length)), as: UTF8.self)
        try #require(
            URL(fileURLWithPath: processPath).resolvingSymlinksInPath().path ==
                URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        )
        try #require(kill(pid, SIGKILL) == 0)
    }

    private func waitForReaping(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try #require(ContinuousClock.now < deadline, "Fixture process \(pid) was not reaped")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForRelaunch(in directory: URL) async throws -> pid_t {
        let marker = directory.appendingPathComponent("relaunch-pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path) {
            try #require(ContinuousClock.now < deadline, "Replacement child never reached the negotiation gate")
            try await Task.sleep(for: .milliseconds(10))
        }
        let value = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(value))
        try #require(pid > 1)
        return pid
    }
}
#endif
