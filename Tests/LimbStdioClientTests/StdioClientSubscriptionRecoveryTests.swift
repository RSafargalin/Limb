#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Limb
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioClientSubscriptionRecoveryTests {
    @Test func idleClientReconnectsBeforeItsFirstOperation() async throws {
        try await withRecoveryPeer(version: "2026-07-28", backoff: .milliseconds(30)) { client, peer in
            let initialPID = try peer.pid(for: 1)
            try #require(kill(initialPID, SIGKILL) == 0)
            try await peer.waitUntilReplacementHandshake()
            #expect(try peer.pid(for: 2) != initialPID)
            // The marker follows the server's write. Allow the client to consume the discovery result.
            try await Task.sleep(for: .milliseconds(100))

            let result = try await client.callTool("new-generation")
            #expect(result.value.content == [.text("new-generation")])
        }
    }

    @Test(arguments: [false, true])
    func droppingClientReapsTheChildAndStopsRecovery(duringBackoff: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-stdio-release-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let peer = RecoveryPeer(directory: directory)
        let backoff: Duration = .seconds(1)
        var client: Client? = try await peer.connect(version: "2026-07-28", backoff: backoff)
        weak var released = client
        let initialPID = try peer.pid(for: 1)
        let result = try await client?.callTool("current-generation")
        #expect(result?.value.content == [.text("1")])

        if duringBackoff {
            await #expect(throws: ClientError.connectionLost(.unknown)) {
                try await client?.callTool("lose-generation")
            }
            await #expect(throws: ClientError.recovering) {
                try await client?.callTool("during-backoff")
            }
        }

        client = nil
        let releasedAt = ContinuousClock.now
        let deadline = releasedAt.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && (released != nil || kill(initialPID, 0) == 0) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(released == nil, "The recovery monitor retained the Client")
        #expect(kill(initialPID, 0) == -1 && errno == ESRCH, "The first child was not reaped")
        try await ContinuousClock().sleep(until: releasedAt.advanced(by: backoff + .milliseconds(200)))
        #expect(!peer.started(generation: 2), "The recovery monitor started another child after release")
        await released?.close()
    }

    @Test(arguments: [false, true])
    func blockedOldEncoderStillCountsAgainstWorkQuotaAfterRecovery(cancelBeforeLoss: Bool) async throws {
        try await withRecoveryPeer(version: "2026-07-28", backoff: .milliseconds(30), maxPending: 1) { client, peer in
            let requested = ClientSubscriptionFilter(
                toolsListChanged: true, promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
            )
            let subscription = try await client.subscribe(filter: requested)
            var events = subscription.makeAsyncIterator()
            let gate = RecoveryWorkGate()
            let call = Task {
                try await client.callTool(
                    "blocked-encoder", arguments: GatedRecoveryArguments(gate: gate), decoding: Int.self,
                    options: .init(timeout: .seconds(5))
                )
            }
            defer {
                gate.release()
                call.cancel()
            }
            try await gate.waitUntilEntered()
            if cancelBeforeLoss {
                call.cancel()
                await #expect(throws: ClientError.cancelled(.notSent)) { try await call.value }
            }
            try #require(gate.isBlocked)

            try #require(kill(try peer.pid(for: 1), SIGKILL) == 0)
            try #require(try await events.next() == .interrupted)
            try #require(try await events.next() == .resubscribed(confirmedFilter: .init(
                promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
            )))
            await #expect(throws: ClientError.workOverloaded(.notSent)) {
                try await client.callTool("new-generation")
            }
            try #require(gate.isBlocked)
            gate.release()
            if !cancelBeforeLoss {
                await #expect(throws: ClientError.connectionLost(.notSent)) { try await call.value }
            }

            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                do {
                    let result = try await client.callTool("new-generation")
                    #expect(result.value.content == [.text("new-generation")])
                    break
                } catch ClientError.workOverloaded(.notSent) {
                    try #require(ContinuousClock.now < deadline, "Released encoder kept its work quota")
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            for generation in [1, 2] {
                #expect(try !peer.frames(for: generation).contains { $0["params"]?["name"] == "blocked-encoder" })
            }
        }
    }

    @Test func acceptedToolReplyFinishesDecodingAcrossRecoveryWithoutReplay() async throws {
        try await withRecoveryPeer(version: "2026-07-28", backoff: .milliseconds(30)) { client, peer in
            let requested = ClientSubscriptionFilter(
                toolsListChanged: true, promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
            )
            let subscription = try await client.subscribe(filter: requested)
            var events = subscription.makeAsyncIterator()
            let gate = RecoveryWorkGate()
            let extracting: ToolOutputExtractor = { result throws(JSONDecodingError) in
                gate.block()
                guard result.content == [.text("1")] else {
                    throw JSONDecodingError("Expected the old child's result", path: ["content"])
                }
                return ["generation": 1]
            }
            let call = Task {
                try await client.callTool(
                    "current-generation", arguments: JSONObject(), decoding: [String: Int].self,
                    extracting: extracting, options: .init(timeout: .seconds(5))
                )
            }
            defer {
                gate.release()
                call.cancel()
            }
            try await gate.waitUntilEntered()
            try #require(kill(try peer.pid(for: 1), SIGKILL) == 0)
            try #require(try await events.next() == .interrupted)
            try #require(try await events.next() == .resubscribed(confirmedFilter: .init(
                promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
            )))
            try #require(gate.isBlocked)
            gate.release()

            #expect(try await call.value.value.output == ["generation": 1])
            #expect(try peer.frames(for: 1).filter { $0["params"]?["name"] == "current-generation" }.count == 1)
            #expect(try !peer.frames(for: 2).contains { $0["params"]?["name"] == "current-generation" })
        }
    }

    @Test func firstListenReturnsItsCompletedHandleWhenAcknowledgementPrecedesEOF() async throws {
        try await withRecoveryPeer(
            version: "2026-07-28", backoff: .milliseconds(30), acknowledgement: .completeFirst
        ) { client, peer in
            let requested = ClientSubscriptionFilter(toolsListChanged: true)
            let subscription = try await client.subscribe(filter: requested)
            #expect(subscription.confirmedFilter == requested)
            var events = subscription.makeAsyncIterator()
            try #require(try await events.next() == .toolsListChanged)
            #expect(try await events.next() == nil)

            try await peer.waitUntilReplacementHandshake()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                do {
                    let result = try await client.callTool("new-generation")
                    #expect(result.value.content == [.text("new-generation")])
                    break
                } catch ClientError.recovering {
                    try #require(ContinuousClock.now < deadline, "Replacement discovery never completed")
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            #expect(try peer.frames(for: 2).map { $0["method"] } == ["server/discover", "tools/call"])
        }
    }

    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"])
    func reconnectDrainsOldEventsAndRestoresTheOriginalFilter(version: String) async throws {
        let modern = version == "2026-07-28"
        let old = ClientSubscriptionFilter(toolsListChanged: true, resourceSubscriptions: ["file:///shared"])
        let requested = ClientSubscriptionFilter(
            toolsListChanged: true, promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
        )
        let restored = ClientSubscriptionFilter(promptsListChanged: true, resourceSubscriptions: ["file:///shared"])

        try await withRecoveryPeer(version: version, backoff: .milliseconds(700)) { client, peer in
            let first = try await client.subscribe(filter: requested)
            let second = try await client.subscribe(filter: requested)
            #expect(first.confirmedFilter == old)
            #expect(second.confirmedFilter == old)

            // The child receives this request, emits two events and exits without replying.
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }

            var firstEvents = first.makeAsyncIterator()
            var secondEvents = second.makeAsyncIterator()
            try #require(try await firstEvents.next() == .toolsListChanged)
            try #require(try await firstEvents.next() == .resourceUpdated(uri: "file:///shared"))
            try #require(try await firstEvents.next() == .interrupted)
            try #require(try await secondEvents.next() == .toolsListChanged)
            try #require(try await secondEvents.next() == .resourceUpdated(uri: "file:///shared"))
            try #require(try await secondEvents.next() == .interrupted)

            await #expect(throws: ClientError.recovering) {
                try await client.callTool("during-recovery")
            }
            await #expect(throws: ClientError.recovering) {
                try await client.subscribe(filter: requested)
            }
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await failedCall.value }

            try #require(try await firstEvents.next() == .resubscribed(confirmedFilter: restored))
            try #require(try await secondEvents.next() == .resubscribed(confirmedFilter: restored))
            #expect(first.confirmedFilter == old)
            #expect(second.confirmedFilter == old)
            #expect(client.protocolVersion.rawValue == version)
            #expect(try peer.pid(for: 1) != peer.pid(for: 2))
            #expect(try peer.oldProcessWasGoneAtReplacementStart())

            let result = try await client.callTool("new-generation")
            #expect(result.value.content == [.text("new-generation")])
            #expect(try await firstEvents.next() == .promptsListChanged)
            #expect(try await secondEvents.next() == .promptsListChanged)

            let replacementRequests = try peer.frames(for: 2)
            let expectedMethods: [JSONValue] = modern
                ? ["server/discover", "subscriptions/listen", "subscriptions/listen", "tools/call"]
                : ["server/discover", "initialize", "notifications/initialized", "resources/subscribe", "tools/call"]
            #expect(replacementRequests.map { $0["method"] } == expectedMethods.map(Optional.some))
            #expect(replacementRequests.last?["params"]?["name"] == "new-generation")
            let initialIDs = try peer.frames(for: 1).compactMap { $0["id"] }
            let replacementIDs = replacementRequests.compactMap { $0["id"] }
            #expect(initialIDs.count == 4)
            #expect(replacementIDs.count == 4)
            #expect(!replacementIDs.contains { initialIDs.contains($0) })
            if modern {
                let filters = replacementRequests.filter { $0["method"] == "subscriptions/listen" }.map {
                    $0["params"]?["notifications"]
                }
                #expect(filters.count == 2)
                for filter in filters {
                    #expect(filter?["promptsListChanged"] == true)
                    #expect(filter?["resourceSubscriptions"] == ["file:///shared"])
                }
            } else {
                #expect(replacementRequests.dropLast().last?["params"]?["uri"] == "file:///shared")
            }
        }
    }

    @Test(arguments: ["complete", "server-cancel"])
    func terminalStreamsStayTerminalWhenASiblingRecovers(terminalOperation: String) async throws {
        try await withRecoveryPeer(version: "2026-07-28", backoff: .milliseconds(20)) { client, peer in
            let requested = ClientSubscriptionFilter(
                toolsListChanged: true, promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
            )
            let terminal = try await client.subscribe(filter: requested)
            let recovering = try await client.subscribe(filter: requested)
            var terminalEvents = terminal.makeAsyncIterator()
            var recoveringEvents = recovering.makeAsyncIterator()
            _ = try await client.callTool(terminalOperation)
            try #require(try await terminalEvents.next() == nil)

            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            try #require(try await recoveringEvents.next() == .toolsListChanged)
            try #require(try await recoveringEvents.next() == .resourceUpdated(uri: "file:///shared"))
            try #require(try await recoveringEvents.next() == .interrupted)
            try #require(try await recoveringEvents.next() == .resubscribed(confirmedFilter: .init(
                promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
            )))
            #expect(try await terminalEvents.next() == nil)
            #expect(try peer.frames(for: 2).map { $0["method"] } == ["server/discover", "subscriptions/listen"])
        }
    }

    @Test func disabledRecoveryPreservesTerminalEOF() async throws {
        try await withRecoveryPeer(version: "2026-07-28", backoff: nil) { client, peer in
            let subscription = try await client.subscribe(filter: .init(
                toolsListChanged: true, resourceSubscriptions: ["file:///shared"]
            ))
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            var events = subscription.makeAsyncIterator()
            try #require(try await events.next() == .toolsListChanged)
            try #require(try await events.next() == .resourceUpdated(uri: "file:///shared"))
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await events.next() }
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await failedCall.value }
            #expect(!peer.started(generation: 2))
        }
    }

    @Test func mismatchEndsSubscriptionWithoutSendingReplacementListen() async throws {
        try await withRecoveryPeer(
            version: "2026-07-28", replacementVersion: "2025-11-25", backoff: .milliseconds(20)
        ) { client, peer in
            let originalRevision = client.protocolVersion
            let subscription = try await client.subscribe(filter: .init(
                toolsListChanged: true, resourceSubscriptions: ["file:///shared"]
            ))
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            var events = subscription.makeAsyncIterator()
            try #require(try await events.next() == .toolsListChanged)
            try #require(try await events.next() == .resourceUpdated(uri: "file:///shared"))
            try #require(try await events.next() == .interrupted)
            do {
                _ = try await events.next()
                Issue.record("Expected incompatible replacement revision")
            } catch ClientSubscriptionError.incompatibleRevision(let expected, let actual) {
                #expect(expected == originalRevision)
                #expect(actual.rawValue == "2025-11-25")
            }
            #expect(try peer.frames(for: 2).map { $0["method"] } == [
                "server/discover", "initialize", "notifications/initialized",
            ])
            #expect(!peer.started(generation: 3))
        }
    }

    @Test func acknowledgedSiblingAndToolCallsProgressWhileAnotherAcknowledgementIsHeld() async throws {
        try await withRecoveryPeer(
            version: "2026-07-28", backoff: .milliseconds(700), acknowledgement: .holdSecond
        ) { client, peer in
            let firstFilter = ClientSubscriptionFilter(promptsListChanged: true)
            let secondFilter = ClientSubscriptionFilter(resourceSubscriptions: ["file:///shared"])
            let first = try await client.subscribe(filter: firstFilter, timeout: .seconds(3))
            let second = try await client.subscribe(filter: secondFilter, timeout: .seconds(3))
            var firstEvents = first.makeAsyncIterator()
            var secondEvents = second.makeAsyncIterator()
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            try #require(try await firstEvents.next() == .interrupted)
            try #require(try await secondEvents.next() == .interrupted)
            await #expect(throws: ClientError.recovering) {
                try await client.callTool("during-backoff")
            }

            try await peer.waitUntilReplacementAwaitsAcknowledgement()
            let result = try await client.callTool("new-generation")
            #expect(result.value.content == [.text("new-generation")])
            #expect(try peer.frames(for: 2).last?["params"]?["name"] == "new-generation")
            try #require(try await firstEvents.next() == .resubscribed(confirmedFilter: firstFilter))
            try #require(try await firstEvents.next() == .promptsListChanged)

            _ = try await client.callTool("release-second-ack")
            try #require(try await secondEvents.next() == .resubscribed(confirmedFilter: secondFilter))
            #expect(try await secondEvents.next() == .resourceUpdated(uri: "file:///shared"))
        }
    }

    @Test func replacementPreservesAcknowledgementAndTerminalFramesInTheSameRead() async throws {
        try await withRecoveryPeer(
            version: "2026-07-28", backoff: .milliseconds(100), acknowledgement: .holdBoth
        ) { client, peer in
            let firstFilter = ClientSubscriptionFilter(promptsListChanged: true)
            let first = try await client.subscribe(filter: firstFilter)
            let second = try await client.subscribe(filter: .init(resourceSubscriptions: ["file:///shared"]))
            var firstEvents = first.makeAsyncIterator()
            var secondEvents = second.makeAsyncIterator()
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            try #require(try await firstEvents.next() == .interrupted)
            try #require(try await secondEvents.next() == .interrupted)
            try await peer.waitUntilReplacementAwaitsAcknowledgement()

            let replacementFailure = Task { try await client.callTool("release-first-and-lose-replacement") }
            defer { replacementFailure.cancel() }
            try #require(try await firstEvents.next() == .resubscribed(confirmedFilter: firstFilter))
            try #require(try await firstEvents.next() == .promptsListChanged)
            #expect(try await firstEvents.next() == nil)
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await secondEvents.next() }
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await replacementFailure.value }
            try await Task.sleep(for: .milliseconds(250))
            #expect(!peer.started(generation: 3))
        }
    }

    @Test func replacementDrainsItsTerminalFramesWhileSiblingAwaitsAcknowledgement() async throws {
        try await withRecoveryPeer(
            version: "2026-07-28", backoff: .milliseconds(100), acknowledgement: .holdSecond
        ) { client, peer in
            let firstFilter = ClientSubscriptionFilter(promptsListChanged: true)
            let first = try await client.subscribe(filter: firstFilter)
            let second = try await client.subscribe(filter: .init(resourceSubscriptions: ["file:///shared"]))
            var firstEvents = first.makeAsyncIterator()
            var secondEvents = second.makeAsyncIterator()
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            try #require(try await firstEvents.next() == .interrupted)
            try #require(try await secondEvents.next() == .interrupted)
            try await peer.waitUntilReplacementAwaitsAcknowledgement()
            try #require(try await firstEvents.next() == .resubscribed(confirmedFilter: firstFilter))
            try #require(try await firstEvents.next() == .promptsListChanged)

            let replacementFailure = Task { try await client.callTool("lose-replacement") }
            defer { replacementFailure.cancel() }
            try #require(try await firstEvents.next() == .promptsListChanged)
            #expect(try await firstEvents.next() == nil)
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await secondEvents.next() }
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await replacementFailure.value }
            try await Task.sleep(for: .milliseconds(250))
            #expect(!peer.started(generation: 3))
        }
    }

    @Test func replacementLossBeforeAcknowledgementEndsTheRecoveryAttempt() async throws {
        try await withRecoveryPeer(
            version: "2026-07-28", backoff: .milliseconds(100), acknowledgement: .holdSecond
        ) { client, peer in
            let subscription = try await client.subscribe(filter: .init(resourceSubscriptions: ["file:///shared"]))
            var events = subscription.makeAsyncIterator()
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            try #require(try await events.next() == .interrupted)

            try await peer.waitUntilReplacementAwaitsAcknowledgement()
            let replacementPID = try peer.pid(for: 2)
            try #require(kill(replacementPID, SIGKILL) == 0)
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await events.next() }
            try await Task.sleep(for: .milliseconds(250))
            #expect(!peer.started(generation: 3))
        }
    }

    @Test func cancellationWhileReplacementAcknowledgementIsPendingStopsTheStream() async throws {
        try await withRecoveryPeer(
            version: "2026-07-28", backoff: .milliseconds(20), acknowledgement: .waitForFile
        ) { client, peer in
            let requested = ClientSubscriptionFilter(
                toolsListChanged: true, promptsListChanged: true, resourceSubscriptions: ["file:///shared"]
            )
            let cancelling = try await client.subscribe(filter: requested)
            var events = cancelling.makeAsyncIterator()
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            try #require(try await events.next() == .toolsListChanged)
            try #require(try await events.next() == .resourceUpdated(uri: "file:///shared"))
            try #require(try await events.next() == .interrupted)

            try await peer.waitUntilReplacementAwaitsAcknowledgement()
            await cancelling.cancel()
            try peer.releaseReplacementAcknowledgement()
            #expect(try await events.next() == nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                do {
                    let result = try await client.callTool("new-generation")
                    #expect(result.value.content == [.text("new-generation")])
                    break
                } catch ClientError.recovering {
                    try #require(ContinuousClock.now < deadline, "Connection stayed in recovery after cancellation")
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func cancellationAndCloseSuppressReplayDuringBackoff(closeClient: Bool) async throws {
        try await withRecoveryPeer(version: "2026-07-28", backoff: .milliseconds(900)) { client, peer in
            let subscription = try await client.subscribe(filter: .init(
                toolsListChanged: true, resourceSubscriptions: ["file:///shared"]
            ))
            let failedCall = Task { try await client.callTool("lose-generation") }
            defer { failedCall.cancel() }
            var events = subscription.makeAsyncIterator()
            try #require(try await events.next() == .toolsListChanged)
            try #require(try await events.next() == .resourceUpdated(uri: "file:///shared"))
            try #require(try await events.next() == .interrupted)
            if closeClient {
                await client.close()
            } else {
                await subscription.cancel()
            }
            #expect(try await events.next() == nil)
            try await Task.sleep(for: .milliseconds(1_000))
            if closeClient {
                #expect(!peer.started(generation: 2))
            } else if peer.started(generation: 2) {
                #expect(try !peer.frames(for: 2).contains { $0["method"] == "subscriptions/listen" })
            }
        }
    }
}

private final class RecoveryWorkGate: Sendable {
    private let blocked = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    var isBlocked: Bool { blocked.withLock { $0 } }

    func block() {
        blocked.withLock { $0 = true }
        _ = semaphore.wait(timeout: .now() + .seconds(8))
        blocked.withLock { $0 = false }
    }

    func release() {
        semaphore.signal()
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !isBlocked {
            try #require(ContinuousClock.now < deadline, "Synchronous tool work never reached its gate")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct GatedRecoveryArguments: JSONEncodable, Sendable {
    let gate: RecoveryWorkGate

    func encode(to writer: inout JSONWriter) {
        gate.block()
        JSONObject().encode(to: &writer)
    }
}

private struct RecoveryPeer {
    let directory: URL

    func connect(
        version: String,
        replacementVersion: String? = nil,
        backoff: Duration?,
        maxPending: Int = 8,
        acknowledgement: RecoveryAcknowledgement = .immediate
    ) async throws -> Client {
        try await Client.connect(
            stdio: .init(executable: "/bin/sh", arguments: [
                "-ec", Self.script, "stdio-recovery-peer", directory.path, version, replacementVersion ?? version,
                acknowledgement.rawValue,
            ]),
            options: .init(
                timeout: .seconds(4), discoveryTimeout: .seconds(1), maxPending: maxPending,
                recovery: backoff.map { StdioRecoveryOptions(backoff: $0) }
            )
        )
    }

    func started(generation: Int) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid-\(generation)").path)
    }

    func pid(for generation: Int) throws -> pid_t {
        let value = try String(contentsOf: directory.appendingPathComponent("pid-\(generation)"), encoding: .utf8)
        return try #require(pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func frames(for generation: Int) throws -> [JSONValue] {
        let contents = try String(
            contentsOf: directory.appendingPathComponent("frames-\(generation)"), encoding: .utf8
        )
        return try contents.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map {
            try JSON.parse(String($0))
        }
    }

    func oldProcessWasGoneAtReplacementStart() throws -> Bool {
        let url = directory.appendingPathComponent("old-process-at-replacement")
        return try String(contentsOf: url, encoding: .utf8) == "gone\n"
    }

    func waitUntilReplacementHandshake() async throws {
        let marker = directory.appendingPathComponent("replacement-handshake")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path) {
            try #require(ContinuousClock.now < deadline, "Idle connection never negotiated a replacement")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilReplacementAwaitsAcknowledgement() async throws {
        let marker = directory.appendingPathComponent("awaiting-ack")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path) {
            try #require(ContinuousClock.now < deadline, "Replacement never received the listen request")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseReplacementAcknowledgement() throws {
        try Data().write(to: directory.appendingPathComponent("release-ack"))
    }

    static let script = #"""
        directory=$1
        version=$2
        generation=1
        while [ -f "$directory/pid-$generation" ]; do
            generation=$((generation + 1))
        done
        printf '%s\n' "$$" > "$directory/pid-$generation"
        transcript="$directory/frames-$generation"
        : > "$transcript"

        if [ "$generation" -eq 1 ]; then
            capabilities='{"tools":{"listChanged":true},"resources":{"subscribe":true}}'
            confirmed='{"toolsListChanged":true,"resourceSubscriptions":["file:///shared"]}'
        elif [ "$generation" -eq 2 ]; then
            IFS= read -r old_pid < "$directory/pid-1"
            if kill -0 "$old_pid" 2>/dev/null; then state=alive; else state=gone; fi
            printf '%s\n' "$state" > "$directory/old-process-at-replacement"
            version=$3
            capabilities='{"tools":{},"prompts":{"listChanged":true},"resources":{"subscribe":true}}'
            confirmed='{"promptsListChanged":true,"resourceSubscriptions":["file:///shared"]}'
        else
            exit 74
        fi

        extract() { printf '%s\n' "$frame" | /usr/bin/plutil -extract "$1" raw -o - -; }
        receive() {
            IFS= read -r frame || return 1
            printf '%s\n' "$frame" >> "$transcript"
            method=$(extract method)
            case "$(printf '%s\n' "$frame" | /usr/bin/plutil -type id - 2>/dev/null || :)" in
                string) id=$(printf '"%s"' "$(extract id)") ;;
                integer) id=$(extract id) ;;
                *) id='' ;;
            esac
        }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        notify() {
            if [ "$modern" = yes ]; then
                printf '{"jsonrpc":"2.0","method":"%s","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":%s}%s}}\n' "$1" "$2" "${3:-}"
            elif [ -n "${3:-}" ]; then
                printf '{"jsonrpc":"2.0","method":"%s","params":{%s}}\n' "$1" "${3#,}"
            else
                printf '{"jsonrpc":"2.0","method":"%s"}\n' "$1"
            fi
        }

        receive
        [ "$method" = server/discover ]
        if [ "$version" = 2026-07-28 ]; then
            modern=yes
            reply "$id" "$(printf '{"resultType":"complete","supportedVersions":["%s"],"capabilities":%s,"ttlMs":0,"cacheScope":"public","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"recovery-peer","version":"1"}}}' "$version" "$capabilities")"
        else
            modern=no
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id"
            receive
            [ "$method" = initialize ]
            reply "$id" "$(printf '{"protocolVersion":"%s","serverInfo":{"name":"recovery-peer","version":"1"},"capabilities":%s}' "$version" "$capabilities")"
            receive
            [ "$method" = notifications/initialized ]
        fi

        if [ "$generation" -eq 2 ]; then : > "$directory/replacement-handshake"; fi
        ids=''
        held=''
        ready=''
        while receive; do
            case "$method" in
                subscriptions/listen)
                    ids="$ids $id"
                    if [ "$4" = completeFirst ] && [ "$generation" -eq 1 ]; then
                        printf '%s\n' \
                            "$(notify notifications/subscriptions/acknowledged "$id" ',"notifications":{"toolsListChanged":true}')" \
                            "$(notify notifications/tools/list_changed "$id")" \
                            "$(printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":%s}}}' "$id" "$id")"
                        exit 77
                    fi
                    if [ "$4" = holdSecond ] || [ "$4" = holdBoth ]; then
                        if [ "$generation" -eq 1 ]; then
                            notify notifications/subscriptions/acknowledged "$id" ',"notifications":{}'
                        elif [ "$(extract params.notifications.resourceSubscriptions.0 2>/dev/null || :)" = file:///shared ]; then
                            held=$id
                            if [ "$4" = holdSecond ]; then : > "$directory/awaiting-ack"; fi
                        else
                            ready=$id
                            if [ "$4" = holdSecond ]; then
                                notify notifications/subscriptions/acknowledged "$id" ',"notifications":{"promptsListChanged":true}'
                                notify notifications/prompts/list_changed "$id"
                            fi
                        fi
                        if [ "$4" = holdBoth ] && [ -n "$ready" ] && [ -n "$held" ]; then
                            : > "$directory/awaiting-ack"
                        fi
                        continue
                    fi
                    if [ "$generation" -eq 2 ] && [ "$4" = waitForFile ]; then
                        : > "$directory/awaiting-ack"
                        for attempt in $(/usr/bin/seq 100); do
                            [ ! -f "$directory/release-ack" ] || break
                            /bin/sleep .03
                        done
                        [ -f "$directory/release-ack" ]
                    fi
                    notify notifications/subscriptions/acknowledged "$id" ",\"notifications\":$confirmed"
                    if [ "$generation" -eq 2 ]; then
                        notify notifications/prompts/list_changed "$id"
                    fi
                    ;;
                resources/subscribe|resources/unsubscribe) reply "$id" '{}' ;;
                tools/call)
                    case "$(extract params.name)" in
                        current-generation)
                            reply "$id" "$(printf '{"resultType":"complete","content":[{"type":"text","text":"%s"}]}' "$generation")"
                            ;;
                        lose-generation)
                            [ "$generation" -eq 1 ]
                            if [ "$modern" = no ]; then ids=legacy; fi
                            if [ "$4" != holdSecond ] && [ "$4" != holdBoth ]; then
                                for subscription in $ids; do
                                    notify notifications/tools/list_changed "$subscription"
                                    notify notifications/resources/updated "$subscription" ',"uri":"file:///shared"'
                                done
                            fi
                            exec 1>&-
                            IFS= read -r ignored || :
                            exit 73
                            ;;
                        complete|server-cancel)
                            for subscription in $ids; do break; done
                            ids=${ids#" $subscription"}
                            if [ "$(extract params.name)" = complete ]; then
                                reply "$subscription" "$(printf '{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":%s}}' "$subscription")"
                            else
                                notify notifications/cancelled "$subscription" ",\"requestId\":$subscription"
                            fi
                            reply "$id" '{"resultType":"complete","content":[]}'
                            ;;
                        release-first-and-lose-replacement)
                            [ -n "$ready" ] && [ -n "$held" ]
                            printf '%s\n' \
                                "$(notify notifications/subscriptions/acknowledged "$ready" ',"notifications":{"promptsListChanged":true}')" \
                                "$(notify notifications/prompts/list_changed "$ready")" \
                                "$(printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":%s}}}' "$ready" "$ready")"
                            exit 77
                            ;;
                        lose-replacement)
                            [ -n "$ready" ] && [ -n "$held" ]
                            notify notifications/prompts/list_changed "$ready"
                            reply "$ready" "$(printf '{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":%s}}' "$ready")"
                            exit 77
                            ;;
                        release-second-ack)
                            [ -n "$held" ]
                            notify notifications/subscriptions/acknowledged "$held" ',"notifications":{"resourceSubscriptions":["file:///shared"]}'
                            notify notifications/resources/updated "$held" ',"uri":"file:///shared"'
                            held=''
                            reply "$id" '{"resultType":"complete","content":[]}'
                            ;;
                        new-generation)
                            [ "$generation" -eq 2 ]
                            if [ "$modern" = yes ]; then
                                reply "$id" '{"resultType":"complete","content":[{"type":"text","text":"new-generation"}]}'
                            else
                                notify notifications/prompts/list_changed legacy
                                reply "$id" '{"content":[{"type":"text","text":"new-generation"}]}'
                            fi
                            ;;
                        *) exit 75 ;;
                    esac
                    ;;
                notifications/cancelled) ;;
                *) exit 76 ;;
            esac
        done
        """#
}

private enum RecoveryAcknowledgement: String {
    case immediate
    case waitForFile
    case holdSecond
    case holdBoth
    case completeFirst
}

private func withRecoveryPeer(
    version: String,
    replacementVersion: String? = nil,
    backoff: Duration?,
    maxPending: Int = 8,
    acknowledgement: RecoveryAcknowledgement = .immediate,
    _ body: (Client, RecoveryPeer) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-stdio-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = RecoveryPeer(directory: directory)
    let client = try await peer.connect(
        version: version, replacementVersion: replacementVersion, backoff: backoff, maxPending: maxPending,
        acknowledgement: acknowledgement
    )
    do {
        try await body(client, peer)
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}
#endif
