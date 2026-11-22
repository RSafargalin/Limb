import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing


private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

private struct R5Random {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x5555 }
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

/// A connection on a real `OutboundQueue` that only the test drains.
private final class R5Client: @unchecked Sendable {
    let queue: OutboundQueue
    let connection: Connection

    init(_ server: Server, budget: Int) {
        queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: 1 << 20)
        connection = server.connect(to: queue)
    }

    static func frame(_ tool: String, id: String) -> [UInt8] {
        Array(#"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(tool)","arguments":{},\#(modernMeta)}}"#.utf8)
    }

    func call(_ tool: String, id: String) { connection.receive(Self.frame(tool, id: id)) }

    func cancel(_ id: String) {
        connection.receive(Array(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"\#(id)"}}"#.utf8))
    }

    /// Takes and "writes" everything queued; returns the ids of the responses, in order.
    @discardableResult func drain() -> [String] {
        let frames = queue.takeAvailable()
        queue.didWrite(bytes: frames.reduce(0) { $0 + $1.count })
        return frames.compactMap { frame in
            guard let message = try? JSON.parse(frame), message["method"] == nil else { return nil }
            return message["id"]?.stringValue
        }
    }

    /// One response queued over budget, `places` parked: every further request waits for a place.
    func saturate(places: Int, tool: String = "blob") async {
        call(tool, id: "fill-0")
        _ = await independentConcurrencyEventually { self.queue.usage.queuedFrames >= 1 }
        for index in 1...places { call(tool, id: "fill-\(index)") }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: - A connection's queue with withdrawals, against a model

/// The engine as the test expects it to behave for one connection in `.serial` mode whose
/// responses (600 bytes) each put its output (budget 500) over budget, and with an own queue
/// limit of `limit`.
private struct SerialConnectionModel {
    let limit: Int
    /// Ordinary responses in the outbound queue; the output is over budget while there is one.
    var queued = 0
    /// Refusals in the outbound queue (urgent frames: they do not count towards the budget).
    var urgent = 0
    /// The request whose handler is done and whose response waits for room.
    var parked: String?
    var waiting: [String] = []
    var ran: [String] = []
    /// Response ids in the order they are queued, refusals included.
    var answered: [String] = []

    private mutating func run(_ id: String) {
        ran.append(id)
        if queued >= 1 {
            parked = id
        } else {
            queued += 1
            answered.append(id)
        }
    }

    private mutating func advance() {
        while parked == nil, !waiting.isEmpty { run(waiting.removeFirst()) }
    }

    mutating func append(_ id: String) {
        if parked == nil, waiting.isEmpty {
            run(id)
        } else if waiting.count >= limit {
            answered.append(id)  // refused at once
            urgent += 1
        } else {
            waiting.append(id)
        }
    }

    mutating func drain() {
        queued = 0
        urgent = 0
        if let id = parked {
            parked = nil
            queued += 1
            answered.append(id)
        }
        advance()
    }

    mutating func cancel(_ id: String) {
        if parked == id {
            parked = nil
            advance()
        } else if let index = waiting.firstIndex(of: id) {
            waiting.remove(at: index)
        }
    }
}

@Suite(.timeLimit(.minutes(8)))
struct IndependentConcurrencyOwnerQueueModelTests {
    private let finished = ICBox(0)

    private func makeServer(limit: Int, log: ICBox<[String]>) throws -> Server {
        let finished = finished
        let server = independentConcurrencyServer { configuration in
            configuration.execution = .serial
            configuration.budgets.maxQueuedRequests = limit
        }
        try server.register(tool: ToolDefinition(name: "mark")) { _, context in
            log.update { $0.append(context.requestID.description) }
            // Counted on the way out, so that the test can wait for a handler to be done (and
            // its response queued or parked) and not merely started.
            finished.update { $0 += 1 }
            return .text(String(repeating: "m", count: 600))
        }
        return server
    }

    /// Waits until the engine has done what the model says, then compares.
    private func settle(_ client: R5Client, _ log: ICBox<[String]>, _ model: SerialConnectionModel, _ context: String) async -> Bool {
        let settled = await independentConcurrencyEventually(timeout: .seconds(5)) {
            log.value.count >= model.ran.count && finished.value >= model.ran.count
                && client.queue.usage.queuedFrames >= model.queued + model.urgent
        }
        _ = settled
        let ran = log.value
        guard ran == model.ran else {
            Issue.record("\(context): ran \(ran.suffix(6)), the model says \(model.ran.suffix(6))")
            return false
        }
        return true
    }

    /// Random appends, withdrawals (of the head, the tail, the parked request, unknown ids, the
    /// same id twice), refusals at the own limit, and reads by the peer that let the head
    /// start. Oracle: the model above — what runs, in which order, and which responses are
    /// sent in which order; nothing withdrawn ever runs, nothing live is lost, and the own
    /// limit is exact after any number of withdrawals and compactions.
    @Test(arguments: [UInt64(61), 62, 63, 64])
    func aConnectionsQueueWithWithdrawalsBehavesLikeTheModel(seed: UInt64) async throws {
        let limit = 40
        let log = ICBox<[String]>([])
        let server = try makeServer(limit: limit, log: log)
        let client = R5Client(server, budget: 500)
        var model = SerialConnectionModel(limit: limit)
        var random = R5Random(seed: seed)
        var answered: [String] = []
        var next = 0
        var cancelled: [String] = []
        // Responses are compared as a whole at the end; reads collect them as they happen.
        func read() {
            answered += client.drain()
            model.drain()
        }
        for step in 0..<3000 {
            let context = "seed \(seed), step \(step)"
            switch random.below(12) {
            case 0...3:
                for _ in 0..<(1 + random.below(6)) {
                    let id = "r\(next)"
                    next += 1
                    client.call("mark", id: id)
                    model.append(id)
                }
            case 4:
                if let id = model.waiting.first {
                    client.cancel(id)
                    model.cancel(id)
                    cancelled.append(id)
                }
            case 5:
                if let id = model.waiting.last {
                    client.cancel(id)
                    model.cancel(id)
                    cancelled.append(id)
                }
            case 6:
                if !model.waiting.isEmpty {
                    let id = model.waiting[random.below(model.waiting.count)]
                    client.cancel(id)
                    model.cancel(id)
                    cancelled.append(id)
                }
            case 7:
                if let id = model.parked {
                    client.cancel(id)
                    model.cancel(id)
                    cancelled.append(id)
                }
            case 8:
                // Unknown, already cancelled, or already answered: nothing happens.
                let id = [cancelled.last ?? "nope", "nope-\(step)", model.ran.first ?? "nope"][random.below(3)]
                client.cancel(id)
                model.cancel(id)
            default:
                read()
            }
            guard await settle(client, log, model, context) else { return }
        }
        // The peer reads until everything has run.
        for _ in 0..<10_000 {
            read()
            if model.parked == nil, model.waiting.isEmpty { break }
            guard await settle(client, log, model, "seed \(seed), winding down") else { return }
        }
        read()
        try await Task.sleep(for: .milliseconds(50))
        read()
        #expect(log.value == model.ran, "seed \(seed): \(log.value.count) ran, the model says \(model.ran.count)")
        #expect(answered == model.answered, "seed \(seed): responses differ from the model, first at \(Array(zip(answered, model.answered)).firstIndex { $0.0 != $0.1 } ?? min(answered.count, model.answered.count))")
        #expect(Set(cancelled).isDisjoint(with: Set(answered)), "seed \(seed): a cancelled request was answered")
        await client.connection.close(graceSeconds: 0)
    }

    /// Compaction boundaries: a backlog of 128 with 63, 64 or 65 requests withdrawn from the
    /// head or from the middle, or exactly half. The own limit (128) is exact afterwards —
    /// exactly as many new requests fit as were withdrawn — and the order of what remains holds.
    @Test(arguments: [(63, false), (64, false), (65, false), (63, true), (64, true), (65, true), (64, nil), (1, nil)] as [(Int, Bool?)])
    func compactionBoundaries(withdrawn: Int, fromHead: Bool?) async throws {
        let limit = 128
        let log = ICBox<[String]>([])
        let server = try makeServer(limit: limit, log: log)
        let client = R5Client(server, budget: 500)
        var model = SerialConnectionModel(limit: limit)
        let context0 = "setup"
        for index in 0..<(limit + 2) {
            client.call("mark", id: "r\(index)")
            model.append("r\(index)")
            // The first two one at a time: a request that arrives while the one before still
            // runs waits for the place, which the model (rightly) does not count on.
            if index < 2 { guard await settle(client, log, model, context0) else { return } }
        }
        let context = "\(withdrawn) withdrawn, \(fromHead.map { $0 ? "head" : "middle" } ?? "every other")"
        guard await settle(client, log, model, context) else { return }
        #expect(model.waiting.count == limit)
        let victims: [String]
        switch fromHead {
        case true?: victims = Array(model.waiting.prefix(withdrawn))
        case false?: victims = Array(model.waiting[30..<(30 + withdrawn)])
        case nil: victims = Array(stride(from: 1, to: model.waiting.count, by: 2).map { model.waiting[$0] }.prefix(withdrawn))
        }
        for id in victims {
            client.cancel(id)
            model.cancel(id)
        }
        // Exactly `withdrawn` more fit; the next is refused.
        let urgentBefore = client.queue.usage.urgentBytes
        for index in 0..<withdrawn {
            client.call("mark", id: "n\(index)")
            model.append("n\(index)")
        }
        #expect(client.queue.usage.urgentBytes == urgentBefore, "\(context): a request within the limit was refused")
        client.call("mark", id: "over")
        model.append("over")
        #expect(client.queue.usage.urgentBytes > urgentBefore, "\(context): the limit took one more after the withdrawals")
        var answered: [String] = []
        for _ in 0..<1000 {
            answered += client.drain()
            model.drain()
            if model.parked == nil, model.waiting.isEmpty { break }
            guard await settle(client, log, model, context) else { return }
        }
        try await Task.sleep(for: .milliseconds(30))
        answered += client.drain()
        model.drain()
        #expect(log.value == model.ran, "\(context)")
        #expect(answered == model.answered, "\(context)")
        await client.connection.close(graceSeconds: 0)
    }
}

// MARK: - Counting the limits by whether the peer is behind

/// A sink with a fixed answer to `isOverBudget` that takes everything at once.
private final class FixedSink: FrameSink {
    let behind: Bool
    let frames = ICBox<[JSONValue]>([])
    init(behind: Bool) { self.behind = behind }
    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        if let message = try? JSON.parse(frame) { frames.update { $0.append(message) } }
        return true
    }
    func waitForCapacity() async {}
    func discard(key: RequestID) {}
    var isOverBudget: Bool { behind }
    var refusals: Int { frames.value.count { $0.independentConcurrencyErrorCode == -31001 } }
}

@Suite(.timeLimit(.minutes(5)))
struct IndependentConcurrencyBehindCountingTests {
    private func makeServer(
        limit: Int, queueLimit: Int, queueBytes: Int = 64 << 20, holding: ICMeter, gate: ICGate, order: ICBox<[String]> = ICBox([])
    ) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = limit
            configuration.budgets.maxQueuedRequests = queueLimit
            configuration.budgets.maxQueuedBytes = queueBytes
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, context in
            order.update { $0.append(context.requestID.description) }
            return .text(String(repeating: "b", count: 3000))
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gate.wait()
            return .text("held")
        }
        return server
    }

    /// The bound on a behind connection's own backlog, by bytes: exactly as many requests as fit
    /// in `maxQueuedBytes`, and after withdrawals exactly as many more. The others share the
    /// same number of bytes, exactly, at the same time.
    @Test func aBehindConnectionsOwnByteLimitIsExactAndSoIsTheSharedOne() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let size = R5Client.frame("blob", id: "w00").count
        let server = try makeServer(limit: 2, queueLimit: 1000, queueBytes: 10 * size + size / 2, holding: holding, gate: gate)
        let stuck = R5Client(server, budget: 1000)
        await stuck.saturate(places: 2)
        for index in 0..<10 { stuck.call("blob", id: String(format: "w%02d", index)) }
        #expect(stuck.queue.usage.urgentBytes == 0, "a request within the byte limit was refused")
        stuck.call("blob", id: "w10")
        let afterOne = stuck.queue.usage.urgentBytes
        #expect(afterOne > 0, "the byte limit took an eleventh request")
        for id in ["w00", "w05", "w09"] { stuck.cancel(id) }
        for index in 11..<14 { stuck.call("blob", id: "w\(index)") }
        #expect(stuck.queue.usage.urgentBytes == afterOne, "after three withdrawals, three requests did not fit")
        stuck.call("blob", id: "w14")
        #expect(stuck.queue.usage.urgentBytes > afterOne, "after three withdrawals, four fit")
        // The others: ten frames of the same size wait, the eleventh is refused.
        let healthy = ICWire(server)
        healthy.call("hold")
        healthy.call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        let shared = R5Client(server, budget: 1 << 20)
        for index in 0..<10 { shared.call("hold", id: String(format: "h%02d", index)) }
        #expect(shared.queue.usage.urgentBytes == 0, "the stuck connection's bytes took room from the others")
        shared.call("hold", id: "h10")
        #expect(shared.queue.usage.urgentBytes > 0, "the shared byte limit took an eleventh request")
        gate.open()
        stuck.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.connection.close(graceSeconds: 0) }
        await shared.connection.close(graceSeconds: 5)
    }

    /// Over budget, but with free places: a big response sits unread, nothing is parked. Its
    /// waiting requests are counted against itself (they only add to what waits for its peer)
    /// and the others keep the whole shared room. Its requests are older, so they run first.
    @Test func overBudgetWithFreePlacesIsCountedAlone() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let order = ICBox<[String]>([])
        let server = try makeServer(limit: 2, queueLimit: 3, holding: holding, gate: gate, order: order)
        let behind = R5Client(server, budget: 1000)
        behind.call("blob", id: "big")
        #expect(await independentConcurrencyEventually { behind.queue.isOverBudget })
        let healthy = R5Client(server, budget: 1 << 20)
        healthy.call("hold", id: "run-1")
        healthy.call("hold", id: "run-2")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        for index in 0..<3 { behind.call("blob", id: "b\(index)") }
        for index in 0..<3 { healthy.call("hold", id: "h\(index)") }
        #expect(behind.queue.usage.urgentBytes == 0 && healthy.queue.usage.urgentBytes == 0, "a request within one of the limits was refused")
        behind.call("blob", id: "b-over")
        healthy.call("hold", id: "h-over")
        #expect(behind.queue.usage.urgentBytes > 0, "the behind connection's own limit took a fourth")
        #expect(healthy.queue.usage.urgentBytes > 0, "the shared limit took a fourth")
        gate.open()
        #expect(await independentConcurrencyEventually { holding.total == 5 })
        #expect(await independentConcurrencyEventually { order.value.count >= 2 })
        #expect(order.value.prefix(1) == ["big"])
        behind.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await behind.connection.close(graceSeconds: 0) }
    }

    /// Custom sinks with a fixed answer. Always behind: each such connection has the limit to
    /// itself, and the others still have the whole shared room. Never behind: everything
    /// shares one limit.
    @Test func customSinksThatAreAlwaysOrNeverBehind() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let server = try makeServer(limit: 1, queueLimit: 3, holding: holding, gate: gate)
        let runner = ICWire(server)
        runner.call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 1 })
        let behindA = FixedSink(behind: true)
        let behindB = FixedSink(behind: true)
        let never = FixedSink(behind: false)
        let a = server.connect(to: behindA)
        let b = server.connect(to: behindB)
        let c = server.connect(to: never)
        for index in 0..<3 {
            a.receive(R5Client.frame("hold", id: "a\(index)"))
            b.receive(R5Client.frame("hold", id: "b\(index)"))
        }
        c.receive(R5Client.frame("hold", id: "c0"))
        runner.call("hold")
        runner.call("hold")
        #expect(behindA.refusals == 0 && behindB.refusals == 0 && never.refusals == 0 && runner.sink.history.isEmpty)
        a.receive(R5Client.frame("hold", id: "a-over"))
        c.receive(R5Client.frame("hold", id: "c-over"))
        #expect(behindA.refusals == 1, "an always-behind connection's own limit took a fourth")
        #expect(never.refusals == 1, "the shared limit took a fourth")
        gate.open()
        for connection in [a, b, c] { await connection.close(graceSeconds: 5) }
    }

    /// A closed sink is never over budget, so a connection whose transport closed its queue
    /// counts in the shared limit — it is not behind, it is gone, and its requests still run
    /// unless the transport calls `close()`. The shared limit stays exact.
    @Test func aClosedSinkCountsInTheSharedLimit() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let server = try makeServer(limit: 1, queueLimit: 3, holding: holding, gate: gate)
        let runner = ICWire(server)
        runner.call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 1 })
        let gone = R5Client(server, budget: 1000)
        gone.queue.close()
        gone.call("hold", id: "g0")
        gone.call("hold", id: "g1")
        runner.call("hold")
        #expect(runner.sink.history.isEmpty)
        let extra = runner.call("hold", id: "extra")
        let refusal = await runner.sink.next(timeout: .seconds(2))
        #expect(refusal?.json?["id"] == extra.json && refusal?.json?.independentConcurrencyErrorCode == -31001, "the shared limit is not exact with a closed sink in it")
        gate.open()
        await gone.connection.close(graceSeconds: 5)
    }

    /// A connection that catches up while its backlog waits: from then on its requests are no
    /// longer waiting for its peer, they share the limit. The shared limit may then be over-full
    /// (that backlog was admitted under the connection's own limit); while it is, nobody gets in.
    /// When the connection falls behind again, the others have their room back.
    @Test func aConnectionThatFlipsBetweenBehindAndNotWhileItsRequestsWait() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let server = try makeServer(limit: 2, queueLimit: 3, holding: holding, gate: gate)
        let flipper = R5Client(server, budget: 1000)
        await flipper.saturate(places: 2)
        let healthy = R5Client(server, budget: 1 << 20)
        healthy.call("hold", id: "run-1")
        healthy.call("hold", id: "run-2")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        for index in 0..<3 { flipper.call("blob", id: "f\(index)") }
        for index in 0..<3 { healthy.call("hold", id: "h\(index)") }
        #expect(healthy.queue.usage.urgentBytes == 0, "the behind connection crowded the healthy one out")
        // The flipper's peer reads everything, twice (the parked responses come up in between).
        flipper.drain()
        _ = await independentConcurrencyEventually(timeout: .seconds(2)) { flipper.queue.usage.queuedFrames >= 2 }
        flipper.drain()
        #expect(!flipper.queue.isOverBudget)
        // Six requests of connections that are not behind now wait, with a limit of three.
        healthy.call("hold", id: "h-over")
        flipper.call("blob", id: "f-over")
        #expect(healthy.queue.usage.urgentBytes > 0, "admitted into an over-full shared queue")
        #expect(flipper.queue.usage.urgentBytes > 0, "admitted into an over-full shared queue")
        flipper.drain()
        // It falls behind again: an unread frame puts it over budget (the refusal above is
        // urgent and does not count). A big response needs a slot, so the test fakes nothing:
        // it lets the gate go, and checks only that everything admitted runs once.
        gate.open()
        #expect(await independentConcurrencyEventually { holding.total == 5 })
        flipper.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await flipper.connection.close(graceSeconds: 0) }
    }
}
