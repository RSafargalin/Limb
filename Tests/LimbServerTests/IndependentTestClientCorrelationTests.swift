import Limb
import LimbTesting
import Testing

@Suite struct IndependentTestClientCorrelationTests {
    @Test(arguments: [true, false])
    func reverseLookupPreservesEarlierReply(modern: Bool) async throws {
        let client = try await Self.fixture(modern: modern)
        let first = Self.post("first", to: client)
        let second = Self.post("second", to: client)

        let secondReply = try await client.response(to: second)
        Self.expectEcho(secondReply, marker: "second")

        let firstReply = try await client.response(to: first, timeout: .seconds(1))
        Self.expectEcho(firstReply, marker: "first")
        await client.close()
    }

    @Test(arguments: [true, false])
    func concurrentLookupsGetTheirOwnReplies(modern: Bool) async throws {
        let release = Gate()
        let client = try await Self.fixture(modern: modern, release: release)
        defer { release.open() }

        let first = Self.post("first", to: client)
        let second = Self.post("second", to: client)
        async let firstReply = client.response(to: first, timeout: .seconds(2))
        async let secondReply = client.response(to: second, timeout: .seconds(2))
        release.open()

        let (firstMessage, secondMessage) = try await (firstReply, secondReply)
        Self.expectEcho(firstMessage, marker: "first")
        Self.expectEcho(secondMessage, marker: "second")
        await client.close()
    }

    @Test(arguments: [true, false])
    func clearingObservedMessagesPreservesUnreadMessages(modern: Bool) async throws {
        let client = try await Self.fixture(modern: modern)
        let first = Self.post("first", to: client, progressToken: "first-progress")
        _ = Self.post("second", to: client, progressToken: "second-progress")
        let barrier = Self.post("barrier", to: client)
        Self.expectEcho(try await client.response(to: barrier), marker: "barrier")

        let tokens = client.received
            .filter { $0["method"] == "notifications/progress" }
            .compactMap { $0["params"]?["progressToken"]?.stringValue }
        #expect(tokens == ["first-progress", "second-progress"])
        client.clearReceived()
        #expect(client.received.isEmpty)

        let nextReply = try await client.next(timeout: .seconds(1))
        Self.expectEcho(nextReply, marker: "first")
        Self.expectEcho(try await client.next(timeout: .seconds(1)), marker: "second")

        await #expect(throws: TestClientError.self) {
            try await client.response(to: first, timeout: .milliseconds(100))
        }
        await #expect(throws: TestClientError.self) {
            try await client.next(timeout: .milliseconds(100))
        }
        await client.close()
    }

    @Test(arguments: [true, false])
    func zeroTimeoutCanTakeBufferedReply(modern: Bool) async throws {
        let client = try await Self.fixture(modern: modern)
        let first = Self.post("first", to: client)
        let barrier = Self.post("barrier", to: client)
        Self.expectEcho(try await client.response(to: barrier), marker: "barrier")

        let clock = ContinuousClock()
        let beginning = clock.now
        await #expect(throws: TestClientError.self) {
            try await client.response(to: RequestID("missing"), timeout: .zero)
        }
        #expect(beginning.duration(to: clock.now) < .seconds(1))
        Self.expectEcho(try await client.response(to: first, timeout: .zero), marker: "first")
        await client.close()
    }

    @Test(arguments: [true, false])
    func cancelledLookupLeavesBufferedReplyForAnotherConsumer(modern: Bool) async throws {
        let client = try await Self.fixture(modern: modern)
        let first = Self.post("first", to: client)
        let barrier = Self.post("barrier", to: client)
        Self.expectEcho(try await client.response(to: barrier), marker: "barrier")

        let release = Gate()
        let lookup = Task {
            await release.wait()
            return try await client.response(to: first, timeout: .seconds(1))
        }
        lookup.cancel()
        release.open()

        await #expect(throws: (any Error).self) { try await lookup.value }
        Self.expectEcho(try await client.response(to: first, timeout: .zero), marker: "first")
        await #expect(throws: TestClientError.self) {
            try await client.response(to: first, timeout: .zero)
        }
        await client.close()
    }

    @Test(arguments: [true, false])
    func numericAndStringIDsStayDistinct(modern: Bool) async throws {
        let client = try await Self.fixture(modern: modern)
        let number = client.post("fixture/echo", ["marker": "numeric"], id: RequestID(1))
        let string = client.post("fixture/echo", ["marker": "textual"], id: RequestID("1"))

        let textualReply = try await client.response(to: string)
        #expect(textualReply["id"]?.stringValue == "1")
        #expect(textualReply["result"]?["marker"] == "textual")

        let numericReply = try await client.response(to: number, timeout: .seconds(1))
        #expect(numericReply["id"]?.intValue == 1)
        #expect(numericReply["result"]?["marker"] == "numeric")
        await client.close()
    }

    @Test(arguments: [true, false])
    func competingLookupsConsumeOneReplyOnce(modern: Bool) async throws {
        let release = Gate()
        let client = try await Self.fixture(modern: modern, release: release)
        defer { release.open() }

        let id = Self.post("first", to: client)
        async let first = try? client.response(to: id, timeout: .seconds(1))
        async let second = try? client.response(to: id, timeout: .seconds(1))
        release.open()

        let replies = await [first, second].compactMap { $0 }
        let reply = try #require(replies.first)
        #expect(replies.count == 1)
        Self.expectEcho(reply, marker: "first")
        await client.close()
    }

    @Test(arguments: [true, false])
    func unrelatedNotificationsDoNotExtendLookupDeadline(modern: Bool) async throws {
        let started = Gate()
        let client = try await Self.fixture(modern: modern, trafficStarted: started)
        _ = Self.post("traffic", to: client, progressToken: "deadline-progress")
        let handlerStarted = await independentConcurrencyFinishes(within: .seconds(5)) { await started.wait() }
        try #require(handlerStarted)

        let clock = ContinuousClock()
        let beginning = clock.now
        await #expect(throws: TestClientError.self) {
            try await client.response(to: RequestID("missing"), timeout: .seconds(1))
        }
        let elapsed = beginning.duration(to: clock.now)
        let progress = client.received.filter { $0["params"]?["progressToken"] == "deadline-progress" }
        #expect(progress.count >= 2, "The fixture must deliver unrelated traffic during the wait.")
        #expect(elapsed >= .milliseconds(850))
        #expect(elapsed < .milliseconds(1600), "Lookup took \(elapsed).")
        await client.close()
    }

    private static func fixture(
        modern: Bool, release: Gate? = nil, trafficStarted: Gate? = nil
    ) async throws -> TestClient {
        let server = Server(name: "correlation-fixture", version: "1") {
            $0.execution = .serial
        }
        try server.register(method: "fixture/echo") { arguments, context in
            switch arguments["marker"]?.stringValue {
            case "first":
                await release?.wait()
                context.progress(1)
            case "second":
                context.progress(1)
            case "traffic":
                let clock = ContinuousClock()
                let beginning = clock.now
                trafficStarted?.open()
                for step in 1...6 {
                    try await clock.sleep(until: beginning.advanced(by: .milliseconds(200 * step)))
                    context.progress(Double(step))
                }
            default:
                break
            }
            return arguments
        }
        let client = TestClient(server, modern: modern)
        if !modern { try await client.initialize(version: .v2025_11_25) }
        let ready = post("ready", to: client)
        expectEcho(try await client.response(to: ready), marker: "ready")
        client.clearReceived()
        return client
    }

    private static func post(_ marker: String, to client: TestClient, progressToken: String? = nil) -> RequestID {
        client.post(
            "fixture/echo", ["marker": .string(marker)], id: RequestID(marker),
            meta: progressToken.map { ["progressToken": .string($0)] }
        )
    }

    private static func expectEcho(_ message: JSONValue, marker: String) {
        #expect(message["id"]?.stringValue == marker)
        #expect(message["result"]?["marker"]?.stringValue == marker)
    }
}
