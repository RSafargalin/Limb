import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

// Tests written against the third version of the engine: handler slots of the server and
// places of a connection, deferred registry events, the drain rule based on progress, and the
// writer's own duplicate of the output descriptor.

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

private struct R3Random {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x7711 }
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

/// Spins (yielding) until `condition` holds; for waits that are expected to take microseconds.
private func spinUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    var spins = 0
    while !condition() {
        spins += 1
        if spins % 256 == 0, ContinuousClock.now >= deadline { return false }
        await Task.yield()
    }
    return true
}

/// A client on a real `OutboundQueue` that the test drains (or does not).
private final class QueueClient: @unchecked Sendable {
    let queue: OutboundQueue
    let connection: Connection
    private let lock = Mutex<(reading: Bool, responses: [String: Int], others: [JSONValue], frames: Int, closed: Bool)>((false, [:], [], 0, false))

    init(_ server: Server, budget: Int, reading: Bool = false) {
        queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: 1 << 20)
        connection = server.connect(to: queue)
        lock.withLock { $0.reading = reading }
    }

    var reading: Bool {
        get { lock.withLock { $0.reading } }
        set { lock.withLock { $0.reading = newValue } }
    }

    func call(_ tool: String, id: String, arguments: String = "{}") {
        connection.receive(
            Array(#"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments),\#(modernMeta)}}"#.utf8))
    }

    func send(_ text: String) { connection.receive(Array(text.utf8)) }

    func cancel(_ id: String) {
        connection.receive(Array(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"\#(id)"}}"#.utf8))
    }

    /// Takes and "writes" whatever is queued, if this client is reading.
    func drainOnce() {
        guard reading else { return }
        let frames = queue.takeAvailable()
        guard !frames.isEmpty else { return }
        lock.withLock { state in
            state.frames += frames.count
            for frame in frames {
                guard let message = try? JSON.parse(frame) else {
                    state.others.append(.string("not JSON"))
                    continue
                }
                if message["method"] == nil, let id = message["id"]?.stringValue {
                    state.responses[id, default: 0] += 1
                } else {
                    state.others.append(message)
                }
            }
        }
        queue.didWrite(bytes: frames.reduce(0) { $0 + $1.count })
    }

    func responses(to id: String) -> Int { lock.withLock { $0.responses[id] ?? 0 } }
    var allResponses: [String: Int] { lock.withLock { $0.responses } }
    var others: [JSONValue] { lock.withLock { $0.others } }
    func clearOthers() { lock.withLock { $0.others = [] } }
}

/// Drains a changing set of clients from a plain thread, like so many writer threads.
private final class Drainer: Sendable {
    private let clients = ICBox<[QueueClient]>([])
    private let stop = ICBox(false)
    private let stopped = ICBox(false)

    init() {
        let clients = clients
        let stop = stop
        let stopped = stopped
        Thread.detachNewThread {
            while !stop.value {
                for client in clients.value { client.drainOnce() }
                usleep(150)
            }
            stopped.set(true)
        }
    }

    func add(_ client: QueueClient) { clients.update { $0.append(client) } }

    func finish() async {
        stop.set(true)
        let stopped = stopped
        _ = await independentConcurrencyEventually { stopped.value }
    }
}

// MARK: - Slots of the server and places of a connection

@Suite(.timeLimit(.minutes(8)))
struct IndependentConcurrencyPlaceTests {
    /// `.serial`: "One at a time, in arrival order". A response that waits for its peer to read
    /// holds its connection's only place but not the handler slot. When the peer reads again,
    /// the request that was waiting behind it must run before one that arrives just then.
    @Test func serialArrivalOrderSurvivesAResponseThatWaitedForRoom() async throws {
        let order = ICBox<[Int]>([])
        let server = independentConcurrencyServer { configuration in
            configuration.execution = .serial
            configuration.budgets.maxQueuedRequests = 1000
        }
        try server.register(tool: ToolDefinition(name: "mark")) { arguments, _ in
            let number = arguments["n"]?.intValue ?? -1
            order.update { $0.append(number) }
            return .text("m")
        }
        let wire = ICWire(server)
        var overtaken: [Int] = []
        let rounds = 30_000
        for round in 0..<rounds {
            let base = round * 3
            wire.sink.blockCapacity()
            wire.call("mark", ["n": JSONValue(base)])  // runs; its response waits for room
            guard await spinUntil({ wire.sink.capacityWaiterCount == 1 }) else {
                Issue.record("round \(round): the first response never waited for room")
                break
            }
            wire.call("mark", ["n": JSONValue(base + 1)])  // waits: the connection has no free place
            wire.sink.unblockCapacity()  // the peer reads again
            for _ in 0..<(round % 7) { _ = wire.sink.mark }  // a slightly different moment each round
            wire.call("mark", ["n": JSONValue(base + 2)])  // arrives right behind
            guard await spinUntil({ order.value.count == base + 3 }) else {
                Issue.record("round \(round): only \(order.value.count - base) of 3 handlers ran")
                break
            }
            if Array(order.value[base...]) != [base, base + 1, base + 2] { overtaken.append(round) }
        }
        #expect(
            overtaken.isEmpty,
            "in \(overtaken.count) of \(rounds) rounds a later request ran before one that had waited longer, first in round \(overtaken.first ?? -1)")
    }

    /// The same order across connections: requests that can run keep their arrival order while
    /// one connection's request waits for its own peer, and that request runs — before anything
    /// that arrived after it — as soon as its connection can take it.
    @Test func serialOrderAcrossConnectionsWithAParkedResponseInThePicture() async throws {
        let order = ICBox<[String]>([])
        let active = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.execution = .serial
            configuration.budgets.maxQueuedRequests = 1000
        }
        try server.register(tool: ToolDefinition(name: "mark")) { arguments, _ in
            active.enter()
            defer { active.leave() }
            order.update { $0.append(arguments["tag"]?.stringValue ?? "?") }
            await Task.yield()
            return .text(String(repeating: "r", count: 600))
        }
        let slow = QueueClient(server, budget: 500)  // one response puts it over budget
        let fast = ICWire(server)
        slow.call("mark", id: "a1", arguments: #"{"tag":"a1"}"#)  // queued directly: nothing pending yet
        #expect(await independentConcurrencyEventually { order.value == ["a1"] && active.current == 0 })
        slow.call("mark", id: "a2", arguments: #"{"tag":"a2"}"#)  // runs; its response waits for room
        #expect(await independentConcurrencyEventually { order.value == ["a1", "a2"] && active.current == 0 })
        slow.call("mark", id: "a3", arguments: #"{"tag":"a3"}"#)  // no place on its connection
        slow.call("mark", id: "a4", arguments: #"{"tag":"a4"}"#)
        // The other connection is not held up by them.
        let b1 = fast.call("mark", ["tag": "b1"])
        let b2 = fast.call("mark", ["tag": "b2"])
        _ = try await fast.response(to: b1)
        _ = try await fast.response(to: b2)
        #expect(order.value == ["a1", "a2", "b1", "b2"])
        // The slow peer reads. Its waiting requests run in their order, one per freed place,
        // before a request that arrives after they could run.
        slow.reading = true
        slow.drainOnce()
        #expect(await independentConcurrencyEventually { order.value.count == 5 })
        let b3 = fast.call("mark", ["tag": "b3"])
        _ = try await fast.response(to: b3)
        for _ in 0..<200 {
            slow.drainOnce()
            if order.value.count == 7 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(order.value.prefix(5) == ["a1", "a2", "b1", "b2", "a3"])
        #expect(Set(order.value.suffix(2)) == ["b3", "a4"])
        #expect(active.peak == 1)
        for _ in 0..<50 where slow.allResponses.count < 4 {
            slow.drainOnce()
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(slow.allResponses == ["a1": 1, "a2": 1, "a3": 1, "a4": 1])
    }

    @Test func requestsWaitingForTheirOwnPeerDoNotCrowdOthersOutOfTheQueue() async throws {
        let gate = ICGate()
        let holding = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 4
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gate.wait()
            return .text("held")
        }
        // A peer that does not read: one response queued, two waiting for room (both places
        // taken), four more requests waiting for a place.
        let stuck = QueueClient(server, budget: 1000)
        stuck.call("blob", id: "s0")
        #expect(await independentConcurrencyEventually { stuck.queue.usage.queuedFrames == 1 })
        for index in 1..<7 { stuck.call("blob", id: "s\(index)") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stuck.queue.usage.queuedFrames == 1)
        // A healthy connection: both handler slots are free, so two calls run…
        let healthy = ICWire(server)
        healthy.call("hold")
        healthy.call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        // …and a third has to wait for a slot. There is nothing unusual about that; with the
        // stuck connection out of the picture it would simply be queued.
        let third = healthy.call("hold")
        let refusal = await healthy.sink.next(timeout: .milliseconds(200))
        #expect(
            refusal == nil,
            "a healthy connection's request was refused (\(refusal?.json?.independentConcurrencyErrorCode ?? 0)): the queue is full of requests that wait for another connection's peer")
        gate.open()
        if refusal == nil { #expect(try await healthy.response(to: third).independentConcurrencyText == "held") }
        stuck.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.connection.close(graceSeconds: 0) }
    }

    /// A request passed over because its connection was busy keeps its position: once the
    /// connection can take it, it runs before requests that arrived later, however busy the
    /// other connections keep the server.
    @Test func aPassedOverRequestIsNotStarvedOnceItsConnectionFreesUp() async throws {
        let order = ICBox<[String]>([])
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 1
            configuration.budgets.maxQueuedRequests = 10_000
        }
        try server.register(tool: ToolDefinition(name: "mark")) { arguments, _ in
            order.update { $0.append(arguments["tag"]?.stringValue ?? "?") }
            await Task.yield()
            return .text(String(repeating: "r", count: 600))
        }
        let slow = QueueClient(server, budget: 500)
        slow.call("mark", id: "a1", arguments: #"{"tag":"a1"}"#)
        #expect(await independentConcurrencyEventually { order.value.count == 1 })
        try await Task.sleep(for: .milliseconds(20))
        slow.call("mark", id: "a2", arguments: #"{"tag":"a2"}"#)  // its response will wait for room
        #expect(await independentConcurrencyEventually { order.value.count == 2 })
        try await Task.sleep(for: .milliseconds(20))
        slow.call("mark", id: "late", arguments: #"{"tag":"late"}"#)  // passed over: no place
        // The other connection floods the server.
        let busy = ICWire(server)
        for index in 0..<400 { busy.call("mark", ["tag": .string("b\(index)")]) }
        // In the middle of that the slow peer reads.
        #expect(await independentConcurrencyEventually { order.value.count >= 50 })
        slow.reading = true
        slow.drainOnce()
        let seenWhenFreed = order.value.count
        #expect(await independentConcurrencyEventually(timeout: .seconds(30)) { order.value.count == 403 })
        let position = order.value.firstIndex(of: "late") ?? -1
        // It arrived before every one of the 400; it runs as soon as a slot comes free after
        // its connection did — not behind all of them.
        #expect(position >= 0 && position <= seenWhenFreed + 20, "ran at position \(position); its connection was free again at \(seenWhenFreed)")
        for _ in 0..<50 {
            slow.drainOnce()
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(slow.allResponses == ["a1": 1, "a2": 1, "late": 1])
    }

    /// Cancelling a request whose response waits for room frees its place at once, and the
    /// place goes to the connection's next waiting request.
    @Test func cancellingAParkedResponseGivesItsPlaceToTheNextRequestOfThatConnection() async throws {
        let ran = ICBox<[String]>([])
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 100
        }
        try server.register(tool: ToolDefinition(name: "blob")) { arguments, _ in
            ran.update { $0.append(arguments["tag"]?.stringValue ?? "?") }
            return .text(String(repeating: "b", count: 3000))
        }
        let stuck = QueueClient(server, budget: 1000)
        stuck.call("blob", id: "s0", arguments: #"{"tag":"s0"}"#)
        #expect(await independentConcurrencyEventually { stuck.queue.usage.queuedFrames == 1 })
        for index in 1..<6 { stuck.call("blob", id: "s\(index)", arguments: #"{"tag":"s\#(index)"}"#) }
        // s0 is queued, s1 and s2 wait for room and hold both places, s3…s5 wait for a place.
        #expect(await independentConcurrencyEventually { ran.value.count == 3 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran.value.count == 3, "a request ran although its connection had no free place")
        stuck.cancel("s1")
        #expect(await independentConcurrencyEventually { ran.value.count == 4 }, "the place of a cancelled, parked response was not passed on")
        stuck.cancel("s2")
        stuck.cancel("s3")  // was already running or parked by now, or still waiting: all are fine
        #expect(await independentConcurrencyEventually { ran.value.count >= 5 })
        try await Task.sleep(for: .milliseconds(50))
        // Nothing of the cancelled requests is ever written, and everything else arrives once.
        stuck.reading = true
        for _ in 0..<100 {
            stuck.drainOnce()
            try await Task.sleep(for: .milliseconds(2))
            if stuck.allResponses.count == 3 { break }
        }
        #expect(stuck.allResponses == ["s0": 1, "s4": 1, "s5": 1])
        #expect(Set(ran.value).isSuperset(of: ["s0", "s1", "s2", "s4", "s5"]))
    }

    /// The requests of a connection whose peer does not read wait in the server's queue. Every
    /// time a handler ends, the queue is looked through for someone who can run; that must not
    /// make the healthy connections pay for the length of somebody else's backlog.
    @Test func aLongBacklogOfOneConnectionDoesNotSlowTheOthersDown() async throws {
        func measure(backlog: Int) async throws -> Duration {
            let server = independentConcurrencyServer { configuration in
                configuration.budgets.maxConcurrentHandlers = 4
                configuration.budgets.maxQueuedRequests = 100_000
            }
            try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
            try server.register(tool: ToolDefinition(name: "quick")) { _, _ in .text("q") }
            let stuck = QueueClient(server, budget: 1000)
            if backlog > 0 {
                stuck.call("blob", id: "s")
                #expect(await independentConcurrencyEventually { stuck.queue.usage.queuedFrames == 1 })
                for index in 0..<(backlog + 4) { stuck.call("blob", id: "s\(index)") }
            }
            let healthy = ICWire(server)
            let calls = 3000
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<calls { healthy.call("quick") }
            #expect(await independentConcurrencyEventually(timeout: .seconds(120)) { healthy.sink.history.count == calls })
            let elapsed = clock.now - start
            stuck.queue.close()
            _ = await independentConcurrencyFinishes(within: .seconds(20)) { await stuck.connection.close(graceSeconds: 0) }
            return elapsed
        }
        let alone = try await measure(backlog: 0)
        let behind = try await measure(backlog: 20_000)
        #expect(
            behind < alone * 20 + .seconds(1),
            "3000 quick calls took \(behind) next to a connection with 20000 waiting requests, and \(alone) without it")
    }

    // MARK: Nothing is ever lost

    /// Long random runs over several connections whose peers read, stop reading and resume,
    /// with cancellations (of running, waiting and parked requests), overloads and closes.
    /// At the end every surviving connection has all its places and the server all its slots.
    @Test(arguments: [UInt64(31), 32, 33])
    func noPlaceOrSlotIsLostOverLongRandomRuns(seed: UInt64) async throws {
        let limit = 3
        let queueLimit = 6
        let active = ICMeter()
        let holding = ICMeter()
        let holdGate = ICBox(ICGate())
        let stubbornGate = ICBox(ICGate())
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = limit
            configuration.budgets.maxQueuedRequests = queueLimit
        }
        try server.register(tool: ToolDefinition(name: "quick")) { _, _ in
            active.enter()
            defer { active.leave() }
            await Task.yield()
            return .text("q")
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in
            active.enter()
            defer { active.leave() }
            return .text(String(repeating: "b", count: 1500))
        }
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            active.enter()
            defer { active.leave() }
            try await Task.sleep(for: .seconds(300))
            return .text("woke")
        }
        try server.register(tool: ToolDefinition(name: "stubborn")) { _, _ in
            active.enter()
            defer { active.leave() }
            await stubbornGate.value.wait()
            return .text("stubborn")
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            active.enter()
            defer { active.leave() }
            holding.enter()
            await holdGate.value.wait()
            return .text("held")
        }

        var random = R3Random(seed: seed)
        let drainer = Drainer()
        struct Slot {
            var client: QueueClient
            var posted = 0
            var outstanding: [String] = []
            var cancelled: Set<String> = []
        }
        func makeClient() -> QueueClient {
            let client = QueueClient(server, budget: 2000, reading: random.below(2) == 0)
            drainer.add(client)
            return client
        }
        var slots = (0..<5).map { _ in Slot(client: makeClient()) }
        var retired: [QueueClient] = []
        let context = "seed \(seed)"
        for step in 0..<6000 {
            let index = random.below(slots.count)
            switch random.below(20) {
            case 0...6:
                let tool = ["quick", "quick", "blob", "blob", "blob", "sleep", "stubborn"][random.below(7)]
                let id = "c\(index)-\(slots[index].posted)"
                slots[index].posted += 1
                slots[index].client.call(tool, id: id)
                slots[index].outstanding.append(id)
            case 7...11:
                if !slots[index].outstanding.isEmpty {
                    let id = slots[index].outstanding.remove(at: random.below(slots[index].outstanding.count))
                    slots[index].client.cancel(id)
                    slots[index].cancelled.insert(id)
                }
            case 12, 13: slots[index].client.reading.toggle()
            case 14:
                if step % 3 == 0 {
                    // The connection goes away, with whatever it has running, waiting and parked.
                    let old = slots[index].client
                    let grace = [0, 0.001, -1][random.below(3)]
                    #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await old.connection.close(graceSeconds: grace) }, "\(context), step \(step)")
                    old.queue.close()
                    old.reading = true
                    retired.append(old)
                    slots[index] = Slot(client: makeClient())
                }
            case 15:
                stubbornGate.value.open()
                stubbornGate.set(ICGate())
            default: await Task.yield()
            }
            #expect(active.current <= limit, "\(context): \(active.current) handlers run at once")
            if active.current > limit { break }
        }
        // Wind down: every peer reads, the client cancels what cannot end by itself.
        stubbornGate.value.open()
        for index in slots.indices {
            slots[index].client.reading = true
            for id in slots[index].outstanding where id.isEmpty == false {
                // Sleepers never end by themselves; cancelling an id that is already answered is harmless.
                slots[index].client.cancel(id)
                slots[index].cancelled.insert(id)
            }
        }
        #expect(await independentConcurrencyEventually(timeout: .seconds(30)) { active.current == 0 }, "\(context): handlers still running")
        try await Task.sleep(for: .milliseconds(100))
        #expect(active.peak <= limit, "\(context): \(active.peak) handlers ran at once; the limit is \(limit)")
        // Exactly one response for every request that was not cancelled, on surviving connections.
        for slot in slots {
            let responses = slot.client.allResponses
            #expect(responses.values.allSatisfy { $0 == 1 }, "\(context): a request was answered twice")
            #expect(slot.client.others.isEmpty, "\(context): unexpected frames \(slot.client.others.prefix(2))")
        }
        for client in retired { #expect(client.allResponses.values.allSatisfy { $0 == 1 }, "\(context): answered twice on a closed connection") }

        // Every surviving connection still has all its places, and the server all its slots:
        // on each connection in turn, `limit` handlers run at the same time.
        for (index, slot) in slots.enumerated() {
            holdGate.set(ICGate())
            let before = holding.total
            for number in 0..<limit { slot.client.call("hold", id: "probe-\(index)-\(number)") }
            let all = await independentConcurrencyEventually(timeout: .seconds(10)) { holding.total == before + limit }
            #expect(all, "\(context): connection \(index) runs only \(holding.total - before) of \(limit) handlers at once: a place or a slot was lost")
            holdGate.value.open()
            #expect(await independentConcurrencyEventually { active.current == 0 })
            let answered = await independentConcurrencyEventually(timeout: .seconds(10)) {
                (0..<limit).allSatisfy { slot.client.responses(to: "probe-\(index)-\($0)") == 1 }
            }
            #expect(answered, "\(context): connection \(index) did not answer its probes")
        }
        // And the queue is empty: exactly `queueLimit` requests can wait.
        holdGate.set(ICGate())
        let probe = ICWire(server)
        let before = holding.total
        for _ in 0..<limit { probe.call("hold") }
        #expect(await independentConcurrencyEventually { holding.total == before + limit }, "\(context)")
        for _ in 0..<queueLimit { probe.call("hold") }
        #expect(probe.sink.history.isEmpty, "\(context): the queue still holds requests of the storm")
        probe.call("hold", id: "extra")
        #expect(probe.sink.history.last?.json?.independentConcurrencyErrorCode == MCPError.Code.overloaded, "\(context): the queue has more room than its limit")
        holdGate.value.open()
        #expect(await independentConcurrencyEventually { active.current == 0 })
        await drainer.finish()
        for slot in slots {
            slot.client.queue.close()
            await slot.client.connection.close(graceSeconds: 0)
        }
    }
}

// MARK: - Registry events for a peer that is not reading

/// Forwards to an `OutboundQueue` and counts how often the engine asks it to wait.
private final class CountingSink: FrameSink {
    let queue: OutboundQueue
    let waits = ICMeter()
    init(_ queue: OutboundQueue) { self.queue = queue }
    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        queue.enqueue(frame, key: key, urgent: urgent, replacesProgress: replacesProgress)
    }
    func waitForCapacity() async {
        waits.enter()
        await queue.waitForCapacity()
    }
    func discard(key: RequestID) { queue.discard(key: key) }
    var isOverBudget: Bool { queue.isOverBudget }
}

@Suite(.timeLimit(.minutes(5)))
struct IndependentConcurrencyDeferredEventTests {
    private func makeServer() throws -> Server {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
        try server.register(resource: ResourceDefinition(uri: "ic://one", name: "one")) { _, _ in [] }
        try server.register(resource: ResourceDefinition(uri: "ic://two", name: "two")) { _, _ in [] }
        try server.register(prompt: PromptDefinition(name: "p")) { _, _ in PromptResult(messages: []) }
        return server
    }

    private func drain(_ client: QueueClient, until done: () -> Bool) async {
        client.reading = true
        for _ in 0..<3000 {
            client.drainOnce()
            if done() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        try? await Task.sleep(for: .milliseconds(30))
        client.drainOnce()
    }

    private func summary(_ messages: [JSONValue]) -> [String] {
        messages.map { message in
            var text = message["method"]?.stringValue ?? "?"
            if let uri = message["params"]?["uri"]?.stringValue { text += " " + uri }
            if let id = message["params"]?["_meta"]?[MetaKey.subscriptionID]?.stringValue { text += " @" + id }
            return text
        }
    }

    @Test func modernSubscribersGetEachDeferredEventOnceWhenThePeerReadsAgain() async throws {
        let server = try makeServer()
        let client = QueueClient(server, budget: 1000)
        client.send(
            #"{"jsonrpc":"2.0","id":"all","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true,"promptsListChanged":true,"resourcesListChanged":true,"resourceSubscriptions":["ic://one","ic://two"]},\#(modernMeta)}}"#)
        client.send(
            #"{"jsonrpc":"2.0","id":"tools","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},\#(modernMeta)}}"#)
        client.call("blob", id: "big")
        #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
        let before = client.queue.usage
        // A storm of events while the peer does not read.
        for round in 0..<300 {
            try server.register(tool: ToolDefinition(name: "t\(round)")) { _, _ in .text("") }
            server.notifyResourceUpdated(uri: "ic://one")
            if round % 2 == 0 { server.notifyResourceUpdated(uri: "ic://two") }
            if round % 3 == 0 { try server.register(prompt: PromptDefinition(name: "p\(round)")) { _, _ in PromptResult(messages: []) } }
            server.notifyResourceUpdated(uri: "ic://nobody-asked")
        }
        // Nothing was queued for them.
        #expect(client.queue.usage.queuedFrames == before.queuedFrames)
        #expect(client.queue.usage.ordinaryBytes == before.ordinaryBytes)

        await drain(client) { client.others.count >= 8 }
        let received = summary(client.others)
        #expect(Array(received.prefix(2)) == ["notifications/subscriptions/acknowledged @all", "notifications/subscriptions/acknowledged @tools"])
        // Each distinct event once per subscription that asked for it; nothing for the URI nobody asked about.
        #expect(
            received.dropFirst(2).sorted() == [
                "notifications/prompts/list_changed @all", "notifications/resources/updated ic://one @all",
                "notifications/resources/updated ic://two @all", "notifications/tools/list_changed @all",
                "notifications/tools/list_changed @tools",
            ], "\(received)")
        #expect(client.responses(to: "big") == 1)
        // With room again, events are delivered as they happen.
        client.clearOthers()
        server.notifyResourceUpdated(uri: "ic://two")
        await drain(client) { client.others.count >= 1 }
        #expect(summary(client.others) == ["notifications/resources/updated ic://two @all"])
    }

    @Test func legacySessionsGetEachDeferredEventOnceToo() async throws {
        let server = try makeServer()
        let client = QueueClient(server, budget: 1000, reading: true)
        client.send(#"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        client.send(#"{"jsonrpc":"2.0","id":"sub","method":"resources/subscribe","params":{"uri":"ic://one"}}"#)
        // The same connection also holds a modern subscription.
        client.send(
            #"{"jsonrpc":"2.0","id":"modern","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["ic://two"]},\#(modernMeta)}}"#)
        await drain(client) { client.others.count >= 1 && client.responses(to: "sub") == 1 }
        client.clearOthers()
        // The peer stops reading.
        client.reading = false
        client.send(#"{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"blob"}}"#)
        #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
        let before = client.queue.usage
        for round in 0..<200 {
            try server.register(tool: ToolDefinition(name: "t\(round)")) { _, _ in .text("") }
            server.notifyResourceUpdated(uri: "ic://one")
            server.notifyResourceUpdated(uri: "ic://two")
        }
        #expect(client.queue.usage.queuedFrames == before.queuedFrames)
        await drain(client) { client.others.count >= 4 }
        #expect(
            summary(client.others).sorted() == [
                "notifications/resources/updated ic://one", "notifications/resources/updated ic://two @modern",
                "notifications/tools/list_changed", "notifications/tools/list_changed @modern",
            ], "\(summary(client.others))")
    }

    @Test func anEventDeferredForASubscriptionThatIsThenCancelledIsNeverDelivered() async throws {
        let server = try makeServer()
        let client = QueueClient(server, budget: 1000)
        for id in ["kept", "dropped"] {
            client.send(
                #"{"jsonrpc":"2.0","id":"\#(id)","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["ic://one"]},\#(modernMeta)}}"#)
        }
        client.call("blob", id: "big")
        #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
        try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("") }
        server.notifyResourceUpdated(uri: "ic://one")
        client.cancel("dropped")
        await drain(client) { client.others.count >= 3 }
        // The cancelled stream's acknowledgment was withdrawn with it; nothing else is for it.
        #expect(
            summary(client.others).sorted() == [
                "notifications/resources/updated ic://one @kept", "notifications/subscriptions/acknowledged @kept",
                "notifications/tools/list_changed @kept",
            ], "\(summary(client.others))")
        // Cancel the last one while another event is deferred: then nobody wants it.
        client.reading = false
        client.call("blob", id: "big2")
        #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
        client.clearOthers()
        try server.register(tool: ToolDefinition(name: "newer")) { _, _ in .text("") }
        client.cancel("kept")
        await drain(client) { client.responses(to: "big2") == 1 }
        #expect(client.others.isEmpty, "\(summary(client.others))")
    }

    @Test func deferredEventsEndWithTheConnection() async throws {
        let server = try makeServer()
        weak var weakConnection: Connection?
        let queue: OutboundQueue
        do {
            let client = QueueClient(server, budget: 1000)
            weakConnection = client.connection
            queue = client.queue
            client.send(
                #"{"jsonrpc":"2.0","id":"sub","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},\#(modernMeta)}}"#)
            client.call("blob", id: "big")
            #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
            try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("") }
            #expect(await independentConcurrencyFinishes(within: .seconds(10)) { await client.connection.close(graceSeconds: 0) })
            try server.register(tool: ToolDefinition(name: "after-close")) { _, _ in .text("") }
            await drain(client) { client.others.count >= 2 }
            // The stream's teardown is there; the deferred event is not delivered to a closed stream.
            #expect(
                summary(client.others) == ["notifications/subscriptions/acknowledged @sub", "notifications/cancelled"],
                "\(summary(client.others))")
            #expect(client.responses(to: "sub") == 1)
        }
        // With the transport's queue closed, the task that waited for room has ended and
        // nothing keeps the connection alive.
        queue.close()
        let released = await independentConcurrencyEventually(timeout: .seconds(5)) { [weakConnection] in weakConnection == nil }
        _ = released
        #expect(weakConnection == nil, "a closed connection is kept alive by its deferred events")
    }

    /// A transport that closes its sink (the peer is gone) before it has called `close()` on
    /// the connection must not send the engine into a loop: a closed sink never has room again.
    @Test func aClosedSinkDoesNotMakeDeferredEventsSpin() async throws {
        let server = try makeServer()
        let sink = CountingSink(OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 1 << 20))
        let connection = server.connect(to: sink)
        connection.receive(
            Array(#"{"jsonrpc":"2.0","id":"sub","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},\#(modernMeta)}}"#.utf8))
        connection.receive(Array(#"{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"blob",\#(modernMeta)}}"#.utf8))
        #expect(await independentConcurrencyEventually { sink.isOverBudget })
        try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("") }
        try await Task.sleep(for: .milliseconds(50))
        let before = sink.waits.total
        sink.queue.close()
        try await Task.sleep(for: .seconds(1))
        let spins = sink.waits.total - before
        // Once would be natural (the wait that was pending returns); a loop shows as thousands.
        #expect(spins <= 3, "the engine asked a closed sink for room \(spins) times in one second")
        await connection.close(graceSeconds: 0)
        try await Task.sleep(for: .milliseconds(50))
        let after = sink.waits.total
        try await Task.sleep(for: .milliseconds(100))
        #expect(sink.waits.total == after, "still spinning after close()")
    }

    /// One notification is a small thing; remembering it must stay cheap however many
    /// different resources a client watches.
    @Test func manyDistinctResourcesAreEachDeliveredOnceAndRememberedCheaply() async throws {
        let server = try makeServer()
        try server.register(tool: ToolDefinition(name: "huge")) { _, _ in .text(String(repeating: "h", count: 2_200_000)) }
        // A budget that takes all the notifications in one go once there is room again.
        let client = QueueClient(server, budget: 2 << 20)
        let count = 8000
        let uris = (0..<count).map { "ic://watched/\($0)" }
        let list = uris.map { "\"\($0)\"" }.joined(separator: ",")
        client.send(
            #"{"jsonrpc":"2.0","id":"watch","method":"subscriptions/listen","params":{"notifications":{"resourceSubscriptions":[\#(list)]},\#(modernMeta)}}"#)
        client.reading = true
        client.drainOnce()
        client.reading = false
        client.clearOthers()
        client.call("huge", id: "big")
        #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
        let before = client.queue.usage
        // On a plain thread: a long loop that never suspends would hold a thread of the pool.
        let elapsed: Duration = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let clock = ContinuousClock()
                let elapsed = clock.measure {
                    for uri in uris { server.notifyResourceUpdated(uri: uri) }
                    for uri in uris.reversed() { server.notifyResourceUpdated(uri: uri) }
                }
                continuation.resume(returning: elapsed)
            }
        }
        #expect(client.queue.usage.queuedFrames == before.queuedFrames)
        await drain(client) { client.others.count >= count }
        let delivered = client.others.compactMap { $0["params"]?["uri"]?.stringValue }
        #expect(delivered.count == count, "\(delivered.count) notifications for \(count) resources")
        #expect(Set(delivered) == Set(uris))
        #expect(elapsed < .seconds(5), "remembering \(count * 2) updates of \(count) resources took \(elapsed) with the connection locked")
    }
}

// MARK: - The drain rule and the writer's own descriptor

/// One stdio session over pipes whose descriptors the test owns.
private final class R3Session: @unchecked Sendable {
    let toServer: (read: Int32, write: Int32)
    let fromServer: (read: Int32, write: Int32)
    let returned = ICBox(false)
    private var pending: [UInt8] = []
    private var scanned = 0

    init(_ server: Server, output: Int32? = nil) {
        signal(SIGPIPE, SIG_IGN)
        var input: [Int32] = [0, 0]
        var out: [Int32] = [-1, -1]
        precondition(pipe(&input) == 0)
        if output == nil { precondition(pipe(&out) == 0) }
        toServer = (input[0], input[1])
        fromServer = (out[0], output ?? out[1])
        let transport = StdioTransport(input: input[0], output: output ?? out[1])
        let returned = returned
        Task.detached {
            await server.run(transport)
            returned.set(true)
        }
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(toServer.write, $0.baseAddress! + offset, bytes.count - offset) }
            guard written > 0 else { return }
            offset += written
        }
    }

    func call(_ id: String, _ tool: String) {
        send(#"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(tool)",\#(modernMeta)}}"# + "\n")
    }

    /// Reads up to `limit` bytes. Returns 0 on timeout and -1 at end of stream.
    func readChunk(limit: Int, timeoutMilliseconds: Int32) -> Int {
        var descriptor = pollfd(fd: fromServer.read, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = read(fromServer.read, &buffer, limit)
        guard count > 0 else { return -1 }
        pending.append(contentsOf: buffer[..<count])
        return count
    }

    /// Complete lines received so far, as the sizes of their result texts (-1 if not a result).
    func takeResultSizes() -> [Int] {
        var sizes: [Int] = []
        while let newline = pending[scanned...].firstIndex(of: 0x0A) {
            let line = Array(pending[..<newline])
            pending.removeSubrange(...newline)
            scanned = 0
            sizes.append((try? JSON.parse(line))?["result"]?["content"]?[0]?["text"]?.stringValue?.utf8.count ?? -1)
        }
        scanned = pending.count
        return sizes
    }

    var unterminatedBytes: Int { pending.count }

    func hasReturned(within seconds: Double) async -> Bool {
        let returned = returned
        return await independentConcurrencyEventually(timeout: .milliseconds(Int(seconds * 1000))) { returned.value }
    }

    /// What a process does when `run` returns: it lets go of the descriptors it passed in.
    func releaseServerEnds() {
        close(toServer.read)
        if fromServer.read >= 0 { close(fromServer.write) }
    }
}

/// The number of open descriptors of this process.
private func openDescriptorCount() -> Int {
    var count = 0
    for descriptor in 0..<Int32(getdtablesize()) where fcntl(descriptor, F_GETFD) != -1 { count += 1 }
    return count
}

/// `ServerConfiguration.outputDrainSeconds` and `StdioSession.writerFinished(idleFor:)`: "The
/// limit is on standing still, not on the total: a peer that reads slowly but keeps reading
/// gets everything, however long it takes."
@Suite(.timeLimit(.minutes(8)), .serialized)
struct IndependentConcurrencyDrainRuleTests {
    private func makeServer(drain: Double, diagnostics: ICBox<[String]> = ICBox([])) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.shutdownGraceSeconds = 0.3
            configuration.outputDrainSeconds = drain
            configuration.budgets.maxQueuedRequests = 100_000
            configuration.budgets.maxOutboundBytes = 256 << 20
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 100_000)) }
        try server.register(tool: ToolDefinition(name: "giant")) { _, _ in .text(String(repeating: "g", count: 8_000_000)) }
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        return server
    }

    private struct Outcome: Sendable {
        var sizes: [Int] = []
        var leftover = 0
        var returnedBeforeTheEnd = false
    }

    /// Reads with `pace` until end of stream; when `run` returns, the server's ends are released.
    private func read(_ session: R3Session, chunk: Int, pauseMicroseconds: UInt32, expecting: Int) async -> Outcome {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var outcome = Outcome()
                var released = false
                while true {
                    let count = session.readChunk(limit: chunk, timeoutMilliseconds: 5000)
                    if count <= 0 { break }
                    outcome.sizes += session.takeResultSizes()
                    if session.returned.value, !released {
                        released = true
                        outcome.returnedBeforeTheEnd = outcome.sizes.count < expecting
                        session.releaseServerEnds()
                    }
                    if pauseMicroseconds > 0 { usleep(pauseMicroseconds) }
                }
                outcome.leftover = session.unterminatedBytes
                if !released { session.releaseServerEnds() }
                close(session.fromServer.read)
                continuation.resume(returning: outcome)
            }
        }
    }

    /// The scaled-down "one byte per second": the peer never stops reading, it only takes a
    /// few kilobytes at a time, so that 128 KiB take longer than the limit.
    @Test func aPeerThatReadsAFewKilobytesAtATimeWithoutEverStoppingIsNotGivenUp() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = R3Session(try makeServer(drain: 1.0, diagnostics: diagnostics))
        let calls = 5  // 500 KB
        for index in 0..<calls { session.call("s\(index)", "blob") }
        close(session.toServer.write)
        // 2 KiB every 40 ms: about 50 KB/s, steadily; the whole output takes about ten seconds.
        let outcome = await read(session, chunk: 2048, pauseMicroseconds: 40_000, expecting: calls)
        // The writer has its own descriptor and outlives `run` inside this test process, so the
        // bytes arrive either way. What a real process would lose is decided by whether `run`
        // gave up: it returns, the process exits, and the rest of the output dies with it.
        #expect(outcome.sizes == Array(repeating: 100_000, count: calls), "received \(outcome.sizes.count) of \(calls) responses")
        let gaveUp = diagnostics.value.filter { $0.contains("did not read") }
        #expect(gaveUp.isEmpty, "run gave up on a peer that never stopped reading: \(gaveUp)")
        _ = await session.hasReturned(within: 10)
    }

    @Test func aFrameFarLargerThanOnePieceReachesAPeerThatReadsSlowerThanTheLimitAllows() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = R3Session(try makeServer(drain: 0.5, diagnostics: diagnostics))
        session.call("g", "giant")
        session.call("e", "echo")
        close(session.toServer.write)
        // 64 KiB every 20 ms: the 8 MB frame alone takes about 2.5 s, five times the limit.
        let outcome = await read(session, chunk: 65536, pauseMicroseconds: 20_000, expecting: 2)
        #expect(outcome.sizes.sorted() == [2, 8_000_000], "received result sizes \(outcome.sizes), \(outcome.leftover) bytes left over")
        #expect(diagnostics.value.isEmpty, "run gave up on a peer that was reading: \(diagnostics.value)")
        _ = await session.hasReturned(within: 10)
    }

    @Test func aPauseShorterThanTheLimitIsForgivenAndALongerOneIsNot() async throws {
        // Shorter: the peer stops for 0.8 s of a 3 s limit and then reads everything.
        let patientDiagnostics = ICBox<[String]>([])
        let patient = R3Session(try makeServer(drain: 3.0, diagnostics: patientDiagnostics))
        for index in 0..<10 { patient.call("p\(index)", "blob") }
        close(patient.toServer.write)
        #expect(patient.readChunk(limit: 4096, timeoutMilliseconds: 5000) > 0)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!patient.returned.value, "given up after a pause of 0.8 s with a limit of 3 s")
        let first = await read(patient, chunk: 1 << 20, pauseMicroseconds: 0, expecting: 10)
        #expect(first.sizes == Array(repeating: 100_000, count: 10))
        #expect(patientDiagnostics.value.isEmpty, "\(patientDiagnostics.value)")
        #expect(await patient.hasReturned(within: 10))

        // Longer: the peer stops for good. `run` gives up after the limit and not before.
        let diagnostics = ICBox<[String]>([])
        let stalled = R3Session(try makeServer(drain: 1.0, diagnostics: diagnostics))
        for index in 0..<10 { stalled.call("q\(index)", "blob") }
        close(stalled.toServer.write)
        #expect(stalled.readChunk(limit: 4096, timeoutMilliseconds: 5000) > 0)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await stalled.hasReturned(within: 20), "run did not give up on a peer that stopped reading")
        #expect(clock.now - start >= .milliseconds(900), "given up before the limit")
        #expect(diagnostics.value.contains { $0.contains("did not read") })
        // The caller lets go of its descriptors. The writer has its own: when the peer reads
        // after all, it still gets every response, whole.
        stalled.releaseServerEnds()
        var sizes = stalled.takeResultSizes()
        while stalled.readChunk(limit: 1 << 20, timeoutMilliseconds: 2000) > 0 { sizes += stalled.takeResultSizes() }
        #expect(sizes == Array(repeating: 100_000, count: 10), "after the peer resumed it received \(sizes.count) of 10 responses")
        #expect(stalled.unterminatedBytes == 0)
        close(stalled.fromServer.read)
    }

    // MARK: Descriptors

    @Test func theDescriptorCountReturnsToWhereItStarted() async throws {
        let server = try makeServer(drain: 0.1)
        let before = openDescriptorCount()
        // Normal sessions.
        for round in 0..<80 {
            let session = R3Session(server)
            session.call("n\(round)", "echo")
            var sizes: [Int] = []
            let deadline = ContinuousClock.now + .seconds(10)
            while sizes.isEmpty, ContinuousClock.now < deadline {
                _ = session.readChunk(limit: 65536, timeoutMilliseconds: 100)
                sizes += session.takeResultSizes()
            }
            #expect(sizes == [2], "round \(round)")
            close(session.toServer.write)
            #expect(await session.hasReturned(within: 20), "round \(round)")
            session.releaseServerEnds()
            close(session.fromServer.read)
        }
        // Other tests of this process open and close descriptors meanwhile; a leak of one per
        // session would show as eighty.
        let afterNormal = await independentConcurrencyEventually(timeout: .seconds(5)) { openDescriptorCount() <= before + 30 }
        #expect(afterNormal, "\(openDescriptorCount() - before) more descriptors are open after 80 normal sessions")

        // Abandoned sessions: the peer does not read, `run` gives up, the caller lets go.
        var abandoned: [R3Session] = []
        for round in 0..<40 {
            let session = R3Session(server)
            for index in 0..<3 { session.call("a\(round)-\(index)", "blob") }
            close(session.toServer.write)
            #expect(await session.hasReturned(within: 20), "round \(round)")
            session.releaseServerEnds()
            abandoned.append(session)
        }
        // Each still holds the peer's end and the writer's duplicate. When the peers go away,
        // the writers end and close their duplicates.
        for session in abandoned { close(session.fromServer.read) }
        let afterAbandoned = await independentConcurrencyEventually(timeout: .seconds(10)) { openDescriptorCount() <= before + 30 }
        #expect(afterAbandoned, "\(openDescriptorCount() - before) more descriptors are open after 40 abandoned sessions whose peers have gone")
    }

    /// The fallback: an output descriptor that cannot be duplicated. The session must end by
    /// itself instead of hanging or crashing.
    @Test func anOutputThatCannotBeDuplicatedEndsTheSessionCleanly() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = R3Session(try makeServer(drain: 0.5, diagnostics: diagnostics), output: -1)
        session.call("x", "echo")
        // The first write fails; the peer is as good as gone, and the session ends without
        // waiting for the input to end.
        #expect(await session.hasReturned(within: 20), "run did not return although its output is unusable; diagnostics: \(diagnostics.value)")
        close(session.toServer.write)
        close(session.toServer.read)
    }
}
