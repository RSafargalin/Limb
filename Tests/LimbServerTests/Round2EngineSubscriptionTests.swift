import Limb
import LimbTesting
import Synchronization
import Testing

// S4: the subscription budgets, by count and by bytes; each URI counted once per connection
// across legacy `resources/subscribe` and every `subscriptions/listen` stream; released on
// unsubscribe, stream cancellation, repeated `initialize` and close; refusal -31001.

private let modernMeta: JSONObject = [
    MetaKey.protocolVersion: "2026-07-28", MetaKey.clientCapabilities: [:],
]

private func server(count: Int = 10_000, bytes: Int = 1 << 20) throws -> Server {
    let server = round2EngineServer { configuration in
        configuration.budgets.maxSubscribedResources = count
        configuration.budgets.maxSubscribedResourceBytes = bytes
    }
    // Legacy `resources/subscribe` needs the resources capability.
    try server.register(resource: ResourceDefinition(uri: "r2://fixed", name: "fixed")) { request, _ in
        [.text(uri: request.uri, text: "")]
    }
    return server
}

/// Opens a stream; returns the response if the server answered at once (a refusal), or `nil`
/// when the acknowledgment came.
private func listen(_ client: TestClient, id: String, uris: [String], meta: JSONObject? = nil) async throws -> JSONValue? {
    let requestID = client.post(
        "subscriptions/listen",
        ["notifications": ["resourceSubscriptions": .array(uris.map(JSONValue.string))]],
        id: RequestID(id), meta: meta)
    let message = try await client.next()
    if message["method"] == "notifications/subscriptions/acknowledged" {
        #expect(message["params"]?["_meta"]?[MetaKey.subscriptionID] == requestID.json)
        return nil
    }
    #expect(message["id"] == requestID.json)
    return message
}

private func subscribe(_ client: TestClient, _ uri: String) async throws -> JSONValue {
    try await client.request("resources/subscribe", ["uri": .string(uri)])
}

private func cancel(_ client: TestClient, _ id: String) {
    client.notify("notifications/cancelled", ["requestId": .string(id)])
}

@Suite(.timeLimit(.minutes(2)))
struct Round2EngineSubscriptionTests {
    // MARK: Legacy resources/subscribe

    @Test func legacyCountBoundaryIsExact() async throws {
        let client = TestClient(try server(count: 3), modern: false)
        try await client.initialize()
        for index in 0..<3 { #expect(try await subscribe(client, "u\(index)")["result"] != nil) }
        let refused = try await subscribe(client, "u3")
        #expect(refused.round2EngineCode == -31001)
        // Subscribing again to a URI already counted costs nothing.
        #expect(try await subscribe(client, "u0")["result"] != nil)
        #expect(try await client.request("resources/unsubscribe", ["uri": "u1"])["result"] != nil)
        #expect(try await subscribe(client, "u3")["result"] != nil)
        #expect(try await subscribe(client, "u4").round2EngineCode == -31001)
        // Unsubscribing from something never subscribed releases nothing.
        #expect(try await client.request("resources/unsubscribe", ["uri": "never"])["result"] != nil)
        #expect(try await subscribe(client, "u4").round2EngineCode == -31001)
    }

    @Test func legacyByteBoundaryIsExact() async throws {
        let client = TestClient(try server(bytes: 10), modern: false)
        try await client.initialize()
        #expect(try await subscribe(client, "aaaaa")["result"] != nil)
        #expect(try await subscribe(client, "bbbbbb").round2EngineCode == -31001)
        #expect(try await subscribe(client, "bbbbb")["result"] != nil)
        #expect(try await subscribe(client, "c").round2EngineCode == -31001)
        // Bytes, not characters.
        _ = try await client.request("resources/unsubscribe", ["uri": "bbbbb"])
        #expect(try await subscribe(client, "ééé").round2EngineCode == -31001)
        #expect(try await subscribe(client, "éé")["result"] != nil)
    }

    @Test func aRefusedLegacySubscriptionLeavesNoState() async throws {
        let srv = try server(count: 1)
        let client = TestClient(srv, modern: false)
        try await client.initialize()
        #expect(try await subscribe(client, "kept")["result"] != nil)
        #expect(try await subscribe(client, "refused").round2EngineCode == -31001)
        srv.notifyResourceUpdated(uri: "refused")
        srv.notifyResourceUpdated(uri: "kept")
        let update = try await client.next()
        #expect(update["params"]?["uri"] == "kept")
        #expect(await client.isSilent())
    }

    @Test func aRepeatedInitializeReleasesTheSessionsSubscriptions() async throws {
        let srv = try server(count: 2)
        let client = TestClient(srv, modern: false)
        try await client.initialize()
        #expect(try await subscribe(client, "a")["result"] != nil)
        #expect(try await subscribe(client, "b")["result"] != nil)
        try await client.initialize()
        #expect(try await subscribe(client, "c")["result"] != nil)
        #expect(try await subscribe(client, "d")["result"] != nil)
        #expect(try await subscribe(client, "e").round2EngineCode == -31001)
        // The old session's subscriptions are gone, not merely uncounted.
        srv.notifyResourceUpdated(uri: "a")
        srv.notifyResourceUpdated(uri: "c")
        #expect(try await client.next()["params"]?["uri"] == "c")
        #expect(await client.isSilent())
    }

    // MARK: subscriptions/listen

    @Test func streamCountBoundaryAndReleaseOnCancel() async throws {
        let client = TestClient(try server(count: 3))
        #expect(try await listen(client, id: "s1", uris: ["a", "b"]) == nil)
        #expect(try await listen(client, id: "s2", uris: ["c"]) == nil)
        #expect(try await listen(client, id: "s3", uris: ["d"])?.round2EngineCode == -31001)
        cancel(client, "s1")
        #expect(try await listen(client, id: "s3", uris: ["d", "e"]) == nil)
        #expect(try await listen(client, id: "s4", uris: ["f"])?.round2EngineCode == -31001)
    }

    @Test func streamByteBoundaryAcrossStreams() async throws {
        let client = TestClient(try server(bytes: 10))
        #expect(try await listen(client, id: "s1", uris: ["aaaaa"]) == nil)
        #expect(try await listen(client, id: "s2", uris: ["bbbbbb"])?.round2EngineCode == -31001)
        #expect(try await listen(client, id: "s2", uris: ["bbbbb"]) == nil)
        #expect(try await listen(client, id: "s3", uris: ["c"])?.round2EngineCode == -31001)
        // A stream without URIs costs nothing.
        #expect(try await listen(client, id: "s3", uris: []) == nil)
    }

    @Test func aRefusedStreamLeavesNoState() async throws {
        let srv = try server(count: 2)
        let client = TestClient(srv)
        #expect(try await listen(client, id: "s1", uris: ["a", "b", "c"])?.round2EngineCode == -31001)
        // Nothing of the refused stream was counted or registered.
        #expect(try await listen(client, id: "s1", uris: ["a", "b"]) == nil)
        srv.notifyResourceUpdated(uri: "c")
        srv.notifyResourceUpdated(uri: "a")
        let update = try await client.next()
        #expect(update["params"]?["uri"] == "a")
        #expect(await client.isSilent())
    }

    @Test func repeatsInOneListAreBoundedAsGivenButCountedOnce() async throws {
        let client = TestClient(try server(count: 2))
        // The list is echoed in the acknowledgment, so three entries exceed a budget of two.
        #expect(try await listen(client, id: "s1", uris: ["a", "a", "a"])?.round2EngineCode == -31001)
        #expect(try await listen(client, id: "s1", uris: ["a", "a"]) == nil)
        // ... and the stream holds one URI, so one more fits.
        #expect(try await listen(client, id: "s2", uris: ["b"]) == nil)
        #expect(try await listen(client, id: "s3", uris: ["c"])?.round2EngineCode == -31001)
    }

    @Test func theSameURIInSeveralStreamsIsCountedOnce() async throws {
        // round2-rules S4: "each URI counted once per connection (legacy resources/subscribe
        // plus resourceSubscriptions of all streams)".
        let client = TestClient(try server(count: 1))
        #expect(try await listen(client, id: "s1", uris: ["u"]) == nil)
        let second = try await listen(client, id: "s2", uris: ["u"])
        #expect(second == nil, "second stream refused: \(second.map { "\($0)" } ?? "")")
        // Still one URI held: a new one does not fit.
        #expect(try await listen(client, id: "s3", uris: ["v"])?.round2EngineCode == -31001)
    }

    @Test func aURIInTheSessionAndInAStreamIsCountedOnce() async throws {
        let client = TestClient(try server(count: 1), modern: false)
        try await client.initialize()
        #expect(try await subscribe(client, "u")["result"] != nil)
        let stream = try await listen(client, id: "s1", uris: ["u"], meta: modernMeta)
        #expect(stream == nil, "stream refused: \(stream.map { "\($0)" } ?? "")")
    }

    @Test func legacyAndStreamsShareOneBudget() async throws {
        let client = TestClient(try server(count: 2), modern: false)
        try await client.initialize()
        #expect(try await subscribe(client, "a")["result"] != nil)
        #expect(try await listen(client, id: "s1", uris: ["b"], meta: modernMeta) == nil)
        #expect(try await subscribe(client, "c").round2EngineCode == -31001)
        #expect(try await listen(client, id: "s2", uris: ["c"], meta: modernMeta)?.round2EngineCode == -31001)
        // Cancelling the stream gives its URI back to the session.
        cancel(client, "s1")
        #expect(try await subscribe(client, "c")["result"] != nil)
        // A repeated initialize releases the session's URIs, not the streams'.
        #expect(try await listen(client, id: "s3", uris: [], meta: modernMeta) == nil)
        try await client.initialize()
        #expect(try await listen(client, id: "s4", uris: ["x", "y"], meta: modernMeta) == nil)
        #expect(try await subscribe(client, "z").round2EngineCode == -31001)
    }

    @Test func eachStreamGetsTheUpdateOfAURIItShares() async throws {
        let srv = try server()
        let client = TestClient(srv)
        #expect(try await listen(client, id: "s1", uris: ["u"]) == nil)
        #expect(try await listen(client, id: "s2", uris: ["u", "v"]) == nil)
        srv.notifyResourceUpdated(uri: "u")
        var streams: Set<String> = []
        for _ in 0..<2 {
            let message = try await client.next()
            #expect(message["method"] == "notifications/resources/updated")
            if let id = message["params"]?["_meta"]?[MetaKey.subscriptionID]?.stringValue { streams.insert(id) }
        }
        #expect(streams == ["s1", "s2"])
        cancel(client, "s1")
        srv.notifyResourceUpdated(uri: "u")
        #expect(try await client.next()["params"]?["_meta"]?[MetaKey.subscriptionID] == "s2")
        #expect(await client.isSilent())
    }

    @Test func closeEndsStreamsAndAConnectionAfterItIsUnaffected() async throws {
        let srv = try server(count: 1)
        let first = TestClient(srv)
        #expect(try await listen(first, id: "s1", uris: ["u"]) == nil)
        await first.connection.close(graceSeconds: 0)
        // The budget is per connection: another connection has its own.
        let second = TestClient(srv)
        #expect(try await listen(second, id: "s1", uris: ["u"]) == nil)
        srv.notifyResourceUpdated(uri: "u")
        #expect(try await second.next()["params"]?["_meta"]?[MetaKey.subscriptionID] == "s1")
    }

    // MARK: Reference counts (E2): the count must return to zero, bytes with it

    /// Fills the budget with fresh one-byte URIs: exactly `count` fit, one more does not. Proves
    /// that whatever happened before left nothing behind and nothing negative.
    private func expectEmptyBudget(_ client: TestClient, count: Int, tag: String, meta: JSONObject? = nil) async throws {
        let uris = (0..<count).map { "\(tag)\($0)" }
        #expect(try await listen(client, id: "fill-\(tag)", uris: uris, meta: meta) == nil, "budget not free (\(tag))")
        #expect(try await listen(client, id: "over-\(tag)", uris: ["\(tag)x"], meta: meta)?.round2EngineCode == -31001, "budget exceeded (\(tag))")
        cancel(client, "fill-\(tag)")
    }

    @Test func holdersInEveryReleaseOrderReturnTheCountToZero() async throws {
        let orders: [[String]] = [["legacy", "s1", "s2"], ["s2", "s1", "legacy"], ["s1", "legacy", "s2"], ["init", "s2", "s1"]]
        for (round, order) in orders.enumerated() {
            let client = TestClient(try server(count: 3, bytes: 300), modern: false)
            try await client.initialize()
            #expect(try await subscribe(client, "u")["result"] != nil)
            #expect(try await listen(client, id: "s1", uris: ["u", "v", "v"], meta: modernMeta) == nil)
            #expect(try await listen(client, id: "s2", uris: ["u", "v", "w"], meta: modernMeta) == nil)
            // u, v, w: the budget of three is full, whatever holds them.
            #expect(try await subscribe(client, "x").round2EngineCode == -31001)
            for holder in order {
                switch holder {
                case "legacy": _ = try await client.request("resources/unsubscribe", ["uri": "u"])
                case "init": try await client.initialize()
                default: cancel(client, holder)
                }
                // Releasing twice must not release twice.
                switch holder {
                case "legacy": _ = try await client.request("resources/unsubscribe", ["uri": "u"])
                case "init": try await client.initialize()
                default: cancel(client, holder)
                }
            }
            try await expectEmptyBudget(client, count: 3, tag: "r\(round)-", meta: modernMeta)
        }
    }

    @Test func bytesReturnToZeroWithSharedURIs() async throws {
        let client = TestClient(try server(count: 100, bytes: 10))
        #expect(try await listen(client, id: "s1", uris: ["aaaaa", "bbbbb"]) == nil)
        // Repeats count as given against the budget (the list is echoed), so only two entries here.
        #expect(try await listen(client, id: "s2", uris: ["bbbbb", "aaaaa"]) == nil)
        #expect(try await listen(client, id: "s3", uris: ["c"])?.round2EngineCode == -31001)
        cancel(client, "s1")
        // s2 still holds both.
        #expect(try await listen(client, id: "s3", uris: ["c"])?.round2EngineCode == -31001)
        cancel(client, "s2")
        cancel(client, "s2")
        cancel(client, "never")
        #expect(try await listen(client, id: "s4", uris: ["0123456789"]) == nil)
        #expect(try await listen(client, id: "s5", uris: ["z"])?.round2EngineCode == -31001)
    }

    @Test func aRefusalOnlyCountsNewURIs() async throws {
        let client = TestClient(try server(count: 2))
        #expect(try await listen(client, id: "s1", uris: ["a", "b"]) == nil)
        // Only URIs already held: fits although the budget is full.
        #expect(try await listen(client, id: "s2", uris: ["b", "a"]) == nil)
        // One new: refused, and the refusal leaves the counts untouched.
        #expect(try await listen(client, id: "s3", uris: ["a", "c"])?.round2EngineCode == -31001)
        cancel(client, "s1")
        cancel(client, "s2")
        try await expectEmptyBudget(client, count: 2, tag: "n")
    }

    @Test func manyRandomOperationsNeverDrift() async throws {
        var seed: UInt64 = 0x1234_5678
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let client = TestClient(try server(count: 6, bytes: 600), modern: false)
        try await client.initialize()
        var open: Set<String> = []
        for step in 0..<300 {
            let uris = (0..<next(4)).map { _ in "u\(next(5))" }
            switch next(5) {
            case 0: _ = try await subscribe(client, "u\(next(5))")
            case 1: _ = try await client.request("resources/unsubscribe", ["uri": .string("u\(next(5))")])
            case 2:
                let id = "s\(step)"
                if try await listen(client, id: id, uris: uris, meta: modernMeta) == nil { open.insert(id) }
            case 3:
                if !open.isEmpty {
                    let id = open.sorted()[next(open.count)]
                    cancel(client, id)
                    open.remove(id)
                }
            default:
                if next(10) == 0 { try await client.initialize() }
            }
        }
        for id in open { cancel(client, id) }
        try await client.initialize()
        try await expectEmptyBudget(client, count: 6, tag: "end", meta: modernMeta)
    }
}
