import Limb
import LimbTesting
import Synchronization
import Testing

// S8: replies to `2025-03-26` batches — the joined reply is bounded by `maxResponseBytes`
// (largest members replaced by -31002 first), members cut off by `close` settle their slot,
// a malformed reply inside a batch fills its slot.

private typealias ICWire = IndependentConcurrencyWire
private typealias ICBox = IndependentConcurrencyBox
private typealias ICGate = IndependentConcurrencyGate

private func call(_ id: String, size: Int) -> String {
    #"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"blob","arguments":{"size":\#(size)}}}"#
}

private func ping(_ id: String) -> String { #"{"jsonrpc":"2.0","id":"\#(id)","method":"ping"}"# }

private func batch(_ members: [String]) -> String { "[" + members.joined(separator: ",") + "]" }

/// A `2025-03-26` session on a recording sink, with `blob` registered.
private func session(maxResponseBytes: Int = 16 << 20, _ configure: (Server) throws -> Void = { _ in }) async throws -> ICWire {
    let server = round2EngineServer { $0.budgets.maxResponseBytes = maxResponseBytes }
    try round2EngineRegisterBlob(server)
    try configure(server)
    let wire = ICWire(server, modern: false)
    try await wire.initialize(version: .v2025_03_26)
    return wire
}

/// The next frame, which must be a batch reply; its members and its size in bytes.
private func nextBatch(_ wire: ICWire) async throws -> (members: [JSONValue], bytes: Int) {
    let record = try await wire.nextRecord()
    let members = try #require(record.json?.arrayValue, "expected a batch reply, got \(record.text.prefix(200))")
    return (members, record.frame.count)
}

private func ids(_ members: [JSONValue]) -> [String] { members.compactMap { $0["id"]?.stringValue } }

@Suite(.timeLimit(.minutes(2)))
struct Round2EngineBatchTests {
    // MARK: The joined reply and maxResponseBytes

    @Test func theLargestMembersAreReplacedFirstUntilTheReplyFits() async throws {
        let wire = try await session(maxResponseBytes: 250_000)
        wire.send(batch([ping("p1"), call("a", size: 200_000), call("b", size: 180_000), call("c", size: 160_000), ping("p2")]))
        let (members, bytes) = try await nextBatch(wire)
        // Members keep their slots and ids, in request order.
        #expect(ids(members) == ["p1", "a", "b", "c", "p2"])
        #expect(bytes <= 250_000)
        #expect(members[1].round2EngineCode == -31002)
        #expect(members[2].round2EngineCode == -31002)
        #expect(members[1].round2EngineMessage?.contains("batch") == true)
        // The smallest large member fits once the two largest are gone, so it is kept.
        #expect(members[3]["result"]?["content"]?[0]?["text"]?.stringValue?.utf8.count == 160_000)
        #expect(members[0]["result"] != nil && members[4]["result"] != nil)
    }

    @Test func theBoundaryIsExact() async throws {
        // Measure the reply with room to spare, then serve the same batch with exactly that
        // limit (kept whole) and one byte less (the largest member replaced).
        let members = [call("a", size: 30_000), call("b", size: 20_000), ping("p")]
        let roomy = try await session()
        roomy.send(batch(members))
        let size = try await nextBatch(roomy).bytes

        let exact = try await session(maxResponseBytes: size)
        exact.send(batch(members))
        let whole = try await nextBatch(exact)
        #expect(whole.bytes == size)
        #expect(whole.members.allSatisfy { $0["result"] != nil })

        let tight = try await session(maxResponseBytes: size - 1)
        tight.send(batch(members))
        let cut = try await nextBatch(tight)
        #expect(cut.bytes <= size - 1)
        #expect(ids(cut.members) == ["a", "b", "p"])
        #expect(cut.members[0].round2EngineCode == -31002)
        #expect(cut.members[1]["result"] != nil)
        #expect(cut.members[2]["result"] != nil)
    }

    @Test func membersTooLargeAloneAreReplacedOneByOne() async throws {
        let wire = try await session(maxResponseBytes: 100_000)
        wire.send(batch([call("a", size: 150_000), call("b", size: 120_000), call("c", size: 10)]))
        let (members, bytes) = try await nextBatch(wire)
        #expect(ids(members) == ["a", "b", "c"])
        #expect(members[0].round2EngineCode == -31002)
        #expect(members[1].round2EngineCode == -31002)
        #expect(members[2]["result"] != nil)
        #expect(bytes <= 100_000)
    }

    @Test func everyMemberTooLargeTogetherButNotAlone() async throws {
        let wire = try await session(maxResponseBytes: 100_000)
        wire.send(batch([call("a", size: 60_000), call("b", size: 60_000), call("c", size: 60_000)]))
        let (members, bytes) = try await nextBatch(wire)
        #expect(ids(members) == ["a", "b", "c"])
        #expect(bytes <= 100_000)
        // 3 × 60 kB: two must go; one can stay.
        #expect(members.filter { $0.round2EngineCode == -31002 }.count == 2)
        #expect(members.filter { $0["result"] != nil }.count == 1)
    }

    @Test func aListingMemberIsBoundedLikeAHandlersResult() async throws {
        let wire = try await session(maxResponseBytes: 200_000) { server in
            try round2EngineRegisterManyTools(server, count: 1000)
        }
        wire.send(batch([#"{"jsonrpc":"2.0","id":"l","method":"tools/list"}"#, ping("p")]))
        let (members, _) = try await nextBatch(wire)
        #expect(ids(members) == ["l", "p"])
        #expect(members[0].round2EngineCode == -31002)
        #expect(members[1]["result"] != nil)
    }

    /// A reply that replacing members cannot bring under the limit: many small members, each
    /// smaller than the error that would replace it. Rule (E4, third version): every request
    /// member gets -31002 under its own id, in an array; the reply may exceed a very small limit.
    @Test func aReplyOfManySmallMembersGetsAnErrorPerMember() async throws {
        let wire = try await session(maxResponseBytes: 200)
        wire.send(batch((0..<10).map { ping("p\($0)") }))
        let (members, _) = try await nextBatch(wire)
        #expect(ids(members) == (0..<10).map { "p\($0)" })
        #expect(members.allSatisfy { $0.round2EngineCode == -31002 })
        // The connection carries on.
        #expect(try await wire.request("ping")["result"] != nil)
    }

    @Test func aMixedReplyThatCannotFitGetsAnErrorPerMemberIncludingMalformedOnes() async throws {
        let wire = try await session(maxResponseBytes: 200)
        // A large member, a malformed request (answered with a null id) and small ones.
        wire.send(batch([call("a", size: 1000), #"{"jsonrpc":"2.0","id":"bad","method":5}"#, ping("p1"), ping("p2")]))
        let (members, bytes) = try await nextBatch(wire)
        #expect(members.count == 4)
        #expect(members.allSatisfy { $0.round2EngineCode == -31002 }, "\(members)")
        #expect(ids(members) == ["a", "bad", "p1", "p2"])
        // Bounded by the ids plus a constant per member.
        #expect(bytes < 4 * 200)
    }

    /// With `maxResponseBytes` this small, no initialize result fits it: there is no session,
    /// and so no batch.
    @Test func aLimitBelowTheInitializeResultLeavesNoSessionForBatches() async throws {
        let server = round2EngineServer { $0.budgets.maxResponseBytes = 40 }
        let wire = ICWire(server, modern: false)
        let answer = try await wire.request(
            "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        #expect(answer.round2EngineCode == -31002)
        wire.send(batch([ping("p")]))
        #expect(try await wire.next().round2EngineCode == -32600)
    }

    @Test func aLimitSmallerThanTheErrorItself() async throws {
        // Ids of 150 characters: each answer fits 200 bytes alone, its -31002 does not.
        let wire = try await session(maxResponseBytes: 200)
        let names = (0..<3).map { "\($0)" + String(repeating: "i", count: 149) }
        wire.send(batch(names.map(ping)))
        let (members, bytes) = try await nextBatch(wire)
        #expect(ids(members) == names)
        #expect(members.allSatisfy { $0.round2EngineCode == -31002 })
        // Documented: the reply exceeds the limit, bounded by the ids plus a constant per member.
        #expect(bytes > 200 && bytes < 3 * (150 + 200))
    }

    // MARK: Close or cancellation in the middle of a batch

    private static func slowSession(started: IndependentConcurrencyMeter) async throws -> ICWire {
        try await session { server in
            try server.register(tool: ToolDefinition(name: "slow")) { _, _ in
                started.enter()
                // Honours cancellation, as a well-behaved handler does.
                try await Task.sleep(for: .seconds(120))
                return .text("late")
            }
        }
    }

    private static func slow(_ id: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"slow"}}"#
    }

    @Test func finishedMembersAreSentWhenCloseCancelsARunningOne() async throws {
        let started = IndependentConcurrencyMeter()
        let wire = try await Self.slowSession(started: started)
        wire.send(batch([call("fast", size: 5), Self.slow("slow")]))
        #expect(await independentConcurrencyEventually { started.total == 1 })
        // The grace period lets "fast" finish; "slow" is then cancelled.
        await round2EngineWithin(.seconds(30)) { await wire.connection.close(graceSeconds: 1) }
        let record = await wire.sink.next(timeout: .seconds(2))
        let members = try #require(record?.json?.arrayValue, "no batch reply after close")
        #expect(ids(members) == ["fast"])
    }

    @Test(arguments: [
        (["s1", "fast", "s2"], ["fast"]), (["s1", "s2", "fast"], ["fast"]), (["fast", "s1", "s2"], ["fast"]),
        (["s1"], []), (["s1", "s2", "s3"], []),
    ])
    func closeCancellingSeveralMembers(layout: [String], expected: [String]) async throws {
        let started = IndependentConcurrencyMeter()
        let wire = try await Self.slowSession(started: started)
        let slowCount = layout.filter { $0 != "fast" }.count
        wire.send(batch(layout.map { $0 == "fast" ? call("fast", size: 5) : Self.slow($0) }))
        #expect(await independentConcurrencyEventually { started.total == slowCount })
        await round2EngineWithin(.seconds(30)) { await wire.connection.close(graceSeconds: 0.5) }
        let record = await wire.sink.next(timeout: .seconds(1))
        if expected.isEmpty {
            // Nothing to answer: no reply at all (an empty array is not a valid reply).
            #expect(record == nil, "\(record?.text ?? "")")
        } else {
            #expect(record?.json?.arrayValue.map(ids) == expected, "\(record?.text ?? "nothing")")
        }
    }

    @Test(arguments: [
        (["s1", "fast", "s2"], ["s1", "s2"], ["fast"]), (["s1", "fast"], ["s1"], ["fast"]),
        (["fast", "s1"], ["s1"], ["fast"]), (["s1"], ["s1"], []), (["s1", "s2"], ["s2", "s1"], []),
    ])
    func peerCancellingRunningMembers(layout: [String], cancelled: [String], expected: [String]) async throws {
        let started = IndependentConcurrencyMeter()
        let wire = try await Self.slowSession(started: started)
        let slowCount = layout.filter { $0 != "fast" }.count
        wire.send(batch(layout.map { $0 == "fast" ? call("fast", size: 5) : Self.slow($0) }))
        #expect(await independentConcurrencyEventually { started.total == slowCount })
        for id in cancelled { wire.cancel(RequestID(id)) }
        if expected.isEmpty {
            #expect(await wire.isSilent(for: .milliseconds(300)))
        } else {
            let (members, _) = try await nextBatch(wire)
            #expect(ids(members) == expected)
            #expect(await wire.isSilent())
        }
        // The connection is fine afterwards, and nothing more arrives for the cancelled ones.
        #expect(try await wire.request("ping")["result"] != nil)
        await round2EngineWithin { await wire.connection.close(graceSeconds: 0) }
    }

    @Test func finishedMembersAreSentWhenCloseDropsAQueuedOne() async throws {
        let gate = ICGate()
        let server = round2EngineServer { $0.execution = .serial }
        try round2EngineRegisterBlob(server)
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server, modern: false)
        try await wire.initialize(version: .v2025_03_26)
        // In serial mode "hold" takes the only slot; "late" waits at the gate and never starts.
        wire.send(
            batch([
                #"{"jsonrpc":"2.0","id":"hold","method":"tools/call","params":{"name":"hold"}}"#, call("late", size: 5),
                ping("p"),
            ]))
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        // "hold" ignores cancellation and is still running when close gives up on it; "late"
        // is dropped without running. The ping answered at once must still be sent.
        await round2EngineWithin { await wire.connection.close(graceSeconds: 0) }
        let (members, _) = try await nextBatch(wire)
        #expect(ids(members) == ["p"])
        gate.open()
    }

    @Test func aMemberCancelledInTheSameBatchGetsNoResponse() async throws {
        let wire = try await session { server in
            try server.register(tool: ToolDefinition(name: "slow")) { _, _ in
                try await Task.sleep(for: .seconds(120))
                return .text("late")
            }
        }
        wire.send(
            batch([
                #"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":{"name":"slow"}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"s"}}"#, ping("p"),
            ]))
        let (members, _) = try await nextBatch(wire)
        #expect(ids(members) == ["p"])
    }

    // MARK: Malformed replies and notifications inside a batch

    @Test func aMalformedReplyInsideABatchIsNotAnswered() async throws {
        let wire = try await session()
        wire.send(
            batch([
                #"{"jsonrpc":"1.0","id":"r","result":{}}"#, ping("p"), #"{"jsonrpc":"2.0","method":"notifications/whatever"}"#,
                #"{"jsonrpc":"2.0","id":7,"result":{}}"#,
            ]))
        let (members, _) = try await nextBatch(wire)
        #expect(ids(members) == ["p"])
        #expect(await wire.isSilent())
    }

    @Test func aBatchOfOnlyMalformedRepliesAndNotificationsGetsNoReply() async throws {
        let wire = try await session()
        wire.send(
            batch([
                #"{"jsonrpc":"1.0","id":"r","result":{}}"#, #"{"jsonrpc":"2.0","method":"notifications/x"}"#,
                #"{"jsonrpc":"2.0","method":5}"#,
            ]))
        #expect(await wire.isSilent(for: .milliseconds(300)))
        // The connection still answers.
        let answer = try await wire.request("ping")
        #expect(answer["result"] != nil)
    }

    // MARK: Large members through a real queue

    @Test func aBatchWithAListingLargerThanTheReserveGoesOutAsOrdinaryOutput() async throws {
        let server = round2EngineServer()
        try round2EngineRegisterManyTools(server, count: 300)
        let client = Round2EngineQueueClient(server, budget: 8 << 20, reserve: 16 << 10)
        client.send(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        )
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        client.drain()
        client.send(batch([#"{"jsonrpc":"2.0","id":"l","method":"tools/list"}"#, ping("p")]))
        #expect(!client.overflowed)
        let usage = client.queue.usage
        #expect(usage.urgentBytes == 0)
        #expect(usage.ordinaryBytes > 100_000)
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.count == 1)
        #expect(frames.first?.arrayValue.map(ids) == ["l", "p"])
    }
}
