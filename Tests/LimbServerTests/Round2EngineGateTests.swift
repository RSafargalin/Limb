import Limb
import LimbTesting
import Synchronization
import Testing

// S6: an entry withdrawn from the gate, or taken from it, drops its closure (and with it the
// request's payload) at once; order and limits of the gate are unchanged.
//
// The payload is observed through a tool handler that captures an object with a `deinit`
// counter: once the tool is removed from the registry, the queued request is the only owner.

private typealias ICWire = IndependentConcurrencyWire
private typealias ICBox = IndependentConcurrencyBox
private typealias ICGate = IndependentConcurrencyGate

/// Registers tool `name`, whose handler owns a fresh payload and logs its runs.
private func registerTracked(_ server: Server, _ name: String, released: ICBox<Int>, log: ICBox<[String]>) throws {
    let payload = Round2EnginePayload(released)
    try server.register(tool: ToolDefinition(name: name)) { _, _ in
        _ = payload.touch()
        log.update { $0.append(name) }
        return .text(name)
    }
}

private func gatedServer(
    queued: Int = 64, queuedBytes: Int = 64 << 20, gate: ICGate, log: ICBox<[String]>
) throws -> Server {
    let server = round2EngineServer { configuration in
        configuration.execution = .serial
        configuration.budgets.maxQueuedRequests = queued
        configuration.budgets.maxQueuedBytes = queuedBytes
    }
    try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
        log.update { $0.append("hold") }
        await gate.wait()
        return .text("held")
    }
    return server
}

@Suite(.timeLimit(.minutes(2)))
struct Round2EngineGateTests {
    @Test func withdrawnEntriesAtHeadMiddleAndTailReleaseTheirPayloadAtOnce() async throws {
        let gate = ICGate()
        let log = ICBox<[String]>([])
        let released = (0..<5).map { _ in ICBox(0) }
        let server = try gatedServer(gate: gate, log: log)
        for index in 0..<5 { try registerTracked(server, "t\(index)", released: released[index], log: log) }
        let wire = ICWire(server)
        wire.call("hold", id: "hold")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        for index in 0..<5 { wire.call("t\(index)", id: RequestID("r\(index)")) }
        // From here on the queued requests are the only owners of the handlers.
        for index in 0..<5 { server.removeTool(named: "t\(index)") }
        #expect(released.map(\.value) == [0, 0, 0, 0, 0])

        wire.cancel("r0")  // head
        #expect(released.map(\.value) == [1, 0, 0, 0, 0])
        wire.cancel("r2")  // middle
        #expect(released.map(\.value) == [1, 0, 1, 0, 0])
        wire.cancel("r4")  // tail
        #expect(released.map(\.value) == [1, 0, 1, 0, 1])

        gate.open()
        #expect(try await wire.response(to: "hold")["result"] != nil)
        #expect(try await wire.response(to: "r1")["result"]?["content"]?[0]?["text"] == "t1")
        #expect(try await wire.response(to: "r3")["result"]?["content"]?[0]?["text"] == "t3")
        #expect(log.value == ["hold", "t1", "t3"])
        // Taken entries release theirs once the request is over.
        #expect(await independentConcurrencyEventually { released.allSatisfy { $0.value == 1 } })
        #expect(await wire.isSilent())
    }

    @Test func fewWithdrawalsReleaseAtOnceWithoutWaitingForCompaction() async throws {
        // Before the change a withdrawn entry was kept until at least 64 were dead.
        let gate = ICGate()
        let log = ICBox<[String]>([])
        let released = (0..<20).map { _ in ICBox(0) }
        let server = try gatedServer(gate: gate, log: log)
        for index in 0..<20 { try registerTracked(server, "t\(index)", released: released[index], log: log) }
        let wire = ICWire(server)
        wire.call("hold", id: "hold")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        for index in 0..<20 { wire.call("t\(index)", id: RequestID("r\(index)")) }
        for index in 0..<20 { server.removeTool(named: "t\(index)") }
        for index in stride(from: 1, to: 20, by: 2) { wire.cancel(RequestID("r\(index)")) }
        #expect(released.enumerated().allSatisfy { index, box in box.value == index % 2 })
        gate.open()
        for index in stride(from: 0, to: 20, by: 2) { _ = try await wire.response(to: RequestID("r\(index)")) }
        #expect(log.value == ["hold"] + stride(from: 0, to: 20, by: 2).map { "t\($0)" })
    }

    @Test func theLastEntryOfAConnectionWithdrawnAndTheConnectionCarriesOn() async throws {
        let gate = ICGate()
        let log = ICBox<[String]>([])
        let released = ICBox(0)
        let server = try gatedServer(gate: gate, log: log)
        try registerTracked(server, "t", released: released, log: log)
        try round2EngineRegisterBlob(server)
        let wire = ICWire(server)
        wire.call("hold", id: "hold")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        wire.call("t", id: "only")
        server.removeTool(named: "t")
        wire.cancel("only")
        #expect(released.value == 1)
        // The connection's queue is empty again; a new request queues and runs normally.
        wire.call("blob", id: "next")
        gate.open()
        #expect(try await wire.response(to: "hold")["result"] != nil)
        #expect(try await wire.response(to: "next")["result"] != nil)
        #expect(log.value == ["hold"])
    }

    @Test func compactionWithManyWithdrawalsKeepsOrderAndReleasesEverything() async throws {
        let gate = ICGate()
        let log = ICBox<[String]>([])
        let count = 150
        let released = ICBox(0)
        let server = try gatedServer(queued: 1000, gate: gate, log: log)
        for index in 0..<count { try registerTracked(server, "t\(index)", released: released, log: log) }
        let wire = ICWire(server)
        wire.call("hold", id: "hold")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        for index in 0..<count { wire.call("t\(index)", id: RequestID("r\(index)")) }
        for index in 0..<count { server.removeTool(named: "t\(index)") }
        // Withdraw all but every tenth, from the head, the tail and in between, in a scrambled order.
        let kept = Set(stride(from: 5, to: count, by: 10))
        let withdrawn = (0..<count).filter { !kept.contains($0) }
        for index in withdrawn.sorted(by: { ($0 * 37) % count < ($1 * 37) % count }) { wire.cancel(RequestID("r\(index)")) }
        #expect(released.value == withdrawn.count)
        gate.open()
        for index in kept.sorted() { _ = try await wire.response(to: RequestID("r\(index)")) }
        #expect(log.value == ["hold"] + kept.sorted().map { "t\($0)" })
        #expect(await independentConcurrencyEventually { released.value == count })
    }

    @Test func withdrawnEntriesNoLongerCountAgainstTheQueueLimits() async throws {
        let gate = ICGate()
        let log = ICBox<[String]>([])
        let frame = 20_000
        let server = try gatedServer(queued: 2, queuedBytes: 2 * frame + 1000, gate: gate, log: log)
        try round2EngineRegisterBlob(server)
        let wire = ICWire(server)
        wire.call("hold", id: "hold")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        let padding: JSONObject = ["pad": .string(String(repeating: "p", count: frame - 200))]
        for round in 0..<5 {
            wire.call("blob", padding, id: RequestID("a\(round)"))
            wire.call("blob", padding, id: RequestID("b\(round)"))
            // Full: a third is refused.
            let refused = try await wire.request("tools/call", ["name": "blob"], id: RequestID("c\(round)"))
            #expect(refused.round2EngineCode == -31001)
            wire.cancel(RequestID("a\(round)"))
            wire.cancel(RequestID("b\(round)"))
        }
        wire.call("blob", padding, id: "last")
        gate.open()
        #expect(try await wire.response(to: "last")["result"] != nil)
    }

    @Test func aWithdrawnHeadDoesNotChangeTheOrderAcrossConnections() async throws {
        let gate = ICGate()
        let log = ICBox<[String]>([])
        let server = try gatedServer(gate: gate, log: log)
        let released = ICBox(0)
        for name in ["a1", "a2", "b1", "a3", "b2"] { try registerTracked(server, name, released: released, log: log) }
        let a = ICWire(server)
        let b = ICWire(server)
        a.call("hold", id: "hold")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        a.call("a1", id: "a1")
        a.call("a2", id: "a2")
        b.call("b1", id: "b1")
        a.call("a3", id: "a3")
        b.call("b2", id: "b2")
        a.cancel("a1")
        b.cancel("b2")
        gate.open()
        for id in ["a2", "a3"] { _ = try await a.response(to: RequestID(id)) }
        _ = try await b.response(to: "b1")
        #expect(log.value == ["hold", "a2", "b1", "a3"])
    }
}
