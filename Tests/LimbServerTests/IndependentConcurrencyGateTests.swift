import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private struct GateRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0xABCD }
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

/// A `tools/call` frame of exactly `size` bytes.
private func frame(id: Int, tool: String, size: Int) -> String {
    let head = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{"pad":""#
    let tail = #""},\#(modernMeta)}}"#
    return head + String(repeating: "x", count: size - head.utf8.count - tail.utf8.count) + tail
}

/// A server whose handlers can be held, slept, or made to ignore cancellation, and that counts
/// how many of them run.
private final class GateFixture: Sendable {
    let server: Server
    let limit: Int
    let queueLimit: Int
    let active = ICMeter()
    let holding = ICMeter()
    let holdGate = ICBox(ICGate())
    let stubbornGate = ICBox(ICGate())
    let order = ICBox<[String]>([])

    init(limit: Int, queueLimit: Int, configure: @escaping @Sendable (inout ServerConfiguration) -> Void = { _ in }) throws {
        self.limit = limit
        self.queueLimit = queueLimit
        server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = limit
            configuration.budgets.maxQueuedRequests = queueLimit
            configure(&configuration)
        }
        let active = active
        let holding = holding
        let holdGate = holdGate
        let stubbornGate = stubbornGate
        let order = order
        try server.register(tool: ToolDefinition(name: "quick")) { arguments, _ in
            active.enter()
            defer { active.leave() }
            if let tag = arguments["tag"]?.stringValue { order.update { $0.append(tag) } }
            await Task.yield()
            return .text("quick")
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
        try server.register(tool: ToolDefinition(name: "hold")) { arguments, _ in
            active.enter()
            defer { active.leave() }
            if let tag = arguments["tag"]?.stringValue { order.update { $0.append(tag) } }
            holding.enter()
            await holdGate.value.wait()
            return .text("held")
        }
    }

    /// Proves that exactly `limit` handler slots and `queueLimit` queue places are free: that
    /// many requests are taken, one more is refused, and all of the taken ones complete.
    func expectFullCapacity(_ comment: Comment) async {
        #expect(await independentConcurrencyEventually { self.active.current == 0 }, "handlers still running; \(comment)")
        holdGate.set(ICGate())
        let wire = ICWire(server)
        let before = holding.total
        for _ in 0..<limit { wire.call("hold") }
        let allRunning = await independentConcurrencyEventually(timeout: .seconds(10)) { self.holding.total == before + self.limit }
        #expect(allRunning, "only \(holding.total - before) of \(limit) handler slots are free; \(comment)")
        for _ in 0..<queueLimit { wire.call("hold") }
        #expect(wire.sink.history.isEmpty, "the queue has fewer than \(queueLimit) free places; \(comment)")
        let extra = wire.call("hold")
        let refusal = wire.sink.history.last?.json
        #expect(refusal?["id"] == extra.json, "the queue has more than \(queueLimit) places; \(comment)")
        #expect(refusal?.independentConcurrencyErrorCode == MCPError.Code.overloaded, comment)
        // No more than `limit` ever run at once.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(holding.total == before + (allRunning ? limit : holding.total - before), comment)
        #expect(active.current <= limit, "\(active.current) handlers run with a limit of \(limit); \(comment)")
        holdGate.value.open()
        let total = limit + queueLimit
        let answered = await independentConcurrencyEventually(timeout: .seconds(20)) {
            wire.sink.history.filter { $0.json?.independentConcurrencyText == "held" }.count == total
        }
        #expect(answered, "not every admitted request was answered; \(comment)")
        #expect(await independentConcurrencyEventually { self.active.current == 0 })
        await wire.connection.close(graceSeconds: 0)
    }
}

@Suite(.timeLimit(.minutes(8)))
struct IndependentConcurrencyGateTests {
    // MARK: Limits hold across connections

    @Test func theHandlerLimitHoldsAcrossConnectionsAndIsReached() async throws {
        let fixture = try GateFixture(limit: 3, queueLimit: 10_000)
        let wires = (0..<8).map { _ in ICWire(fixture.server) }
        var expected = 0
        for round in 0..<400 {
            wires[round % wires.count].call("quick")
            expected += 1
        }
        let total = expected
        #expect(
            await independentConcurrencyEventually(timeout: .seconds(30)) {
                wires.reduce(0) { $0 + $1.sink.history.count } == total
            })
        #expect(fixture.active.peak <= 3, "\(fixture.active.peak) handlers ran at once across connections; the limit is 3")
        for wire in wires {
            #expect(wire.sink.history.allSatisfy { $0.json?.independentConcurrencyText == "quick" })
        }

        let heldCalls = wires.prefix(3).map { wire in (wire, wire.call("hold")) }
        #expect(await independentConcurrencyEventually {
            fixture.holding.total == 3 && fixture.active.current == 3
        }, "three handlers on distinct connections should run concurrently")
        fixture.holdGate.value.open()
        #expect(await independentConcurrencyEventually {
            heldCalls.allSatisfy { wire, id in
                wire.sink.history.contains { $0.json?["id"] == id.json && $0.json?.independentConcurrencyText == "held" }
            }
        })
        for wire in wires {
            #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await wire.connection.close(graceSeconds: 0) })
        }

        await fixture.expectFullCapacity("after 400 quick calls on 8 connections")
    }

    @Test func queueLimitByCountAtTheExactBoundaryAcrossConnections() async throws {
        let fixture = try GateFixture(limit: 2, queueLimit: 3)
        let a = ICWire(fixture.server)
        let b = ICWire(fixture.server)
        let c = ICWire(fixture.server)
        let d = ICWire(fixture.server)
        a.call("hold")
        b.call("hold")
        #expect(await independentConcurrencyEventually { fixture.holding.total == 2 })
        // Three places in the queue, whoever fills them.
        let queuedB = b.call("hold")
        c.call("hold")
        c.call("hold")
        #expect(a.sink.history.isEmpty && b.sink.history.isEmpty && c.sink.history.isEmpty)
        // The next one is refused on whichever connection it arrives, under its own id.
        for wire in [d, a, c] {
            let refused = wire.call("hold", id: "over")
            let refusal = try await wire.next()
            #expect(refusal["id"] == refused.json)
            #expect(refusal.independentConcurrencyErrorCode == -31001)
        }
        // A cancellation on one connection frees a place for any other.
        b.cancel(queuedB)
        d.call("hold")
        #expect(d.sink.history.count == 1, "the place freed by connection B's cancellation was not usable by connection D")
        d.call("hold", id: "over-again")
        #expect(try await d.next().independentConcurrencyErrorCode == -31001)
        // Cheap methods are not subject to the gate on any connection.
        #expect(try await d.request("server/discover")["result"] != nil)
        #expect(try await a.request("tools/list")["result"] != nil)
        fixture.holdGate.value.open()
        #expect(await independentConcurrencyEventually { fixture.active.current == 0 && fixture.holding.total == 5 })
        #expect(fixture.holding.total == 5, "a refused or cancelled request ran")
        await fixture.expectFullCapacity("after the boundary test")
    }

    @Test func queueLimitByBytesAtTheExactBoundaryAcrossConnections() async throws {
        let fixture = try GateFixture(limit: 1, queueLimit: 1000) { $0.budgets.maxQueuedBytes = 10_000 }
        let a = ICWire(fixture.server)
        let b = ICWire(fixture.server)
        let c = ICWire(fixture.server)
        a.send(frame(id: 1, tool: "hold", size: 300))  // runs
        #expect(await independentConcurrencyEventually { fixture.holding.total == 1 })
        b.send(frame(id: 2, tool: "hold", size: 6000))  // waits: 6000 bytes
        c.send(frame(id: 3, tool: "hold", size: 4001))  // 10 001 > 10 000
        let refusal = try await c.next()
        #expect(refusal["id"] == 3)
        #expect(refusal.independentConcurrencyErrorCode == -31001)
        c.send(frame(id: 4, tool: "hold", size: 4000))  // exactly 10 000
        #expect(c.sink.history.count == 1, "a frame that exactly fills the byte budget was refused")
        a.send(frame(id: 5, tool: "hold", size: 300))
        #expect(try await a.next().independentConcurrencyErrorCode == -31001)
        // Closing a connection returns the bytes of its waiting requests to everyone else.
        #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await b.connection.close(graceSeconds: 0) })
        a.send(frame(id: 6, tool: "hold", size: 6001))
        #expect(try await a.next().independentConcurrencyErrorCode == -31001)
        a.send(frame(id: 7, tool: "hold", size: 6000))
        #expect(a.sink.history.count == 2, "closing connection B did not release the bytes of its queued request")
        fixture.holdGate.value.open()
        // 1, 4 and 7 run, one after the other; 2 (closed while queued), 3, 5 and 6 (refused) never do.
        #expect(await independentConcurrencyEventually { fixture.holding.total == 3 && fixture.active.current == 0 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.holding.total == 3)
        #expect(b.sink.history.isEmpty)
    }

    // MARK: Order

    @Test func serialModeRunsInArrivalOrderAcrossConnections() async throws {
        let fixture = try GateFixture(limit: 16, queueLimit: 10_000) { $0.execution = .serial }
        let wires = (0..<5).map { _ in ICWire(fixture.server) }
        wires[0].call("hold", ["tag": "first"])
        #expect(await independentConcurrencyEventually { fixture.holding.total == 1 })
        var expected = ["first"]
        var random = GateRandom(seed: 5)
        var cancelled: Set<String> = []
        var calls: [(wire: Int, id: RequestID, tag: String)] = []
        for index in 0..<120 {
            let wire = random.below(wires.count)
            let tag = "w\(wire)-\(index)"
            calls.append((wire, wires[wire].call("quick", ["tag": .string(tag)]), tag))
        }
        // Some are cancelled while they wait: they leave the line without disturbing it.
        for call in calls where random.below(4) == 0 {
            wires[call.wire].cancel(call.id)
            cancelled.insert(call.tag)
        }
        expected += calls.map(\.tag).filter { !cancelled.contains($0) }
        #expect(fixture.order.value == ["first"])
        // Cheap methods on other connections do not wait in that line.
        #expect(try await wires[3].request("server/discover")["result"] != nil)
        fixture.holdGate.value.open()
        let expectedCount = expected.count
        #expect(await independentConcurrencyEventually(timeout: .seconds(30)) { fixture.order.value.count == expectedCount })
        #expect(fixture.order.value == expected, "handlers of a .serial server did not run in arrival order across connections")
        #expect(fixture.active.peak == 1)
    }

    @Test func aFreedSlotGoesToTheRequestThatWaitedLongestWhicheverConnectionItIsOn() async throws {
        let fixture = try GateFixture(limit: 1, queueLimit: 100)
        let a = ICWire(fixture.server)
        let b = ICWire(fixture.server)
        let c = ICWire(fixture.server)
        a.call("hold", ["tag": "a1"])
        #expect(await independentConcurrencyEventually { fixture.holding.total == 1 })
        b.call("quick", ["tag": "b1"])
        c.call("quick", ["tag": "c1"])
        a.call("quick", ["tag": "a2"])
        b.call("quick", ["tag": "b2"])
        c.call("quick", ["tag": "c2"])
        fixture.holdGate.value.open()
        #expect(await independentConcurrencyEventually { fixture.order.value.count == 6 })
        #expect(fixture.order.value == ["a1", "b1", "c1", "a2", "b2", "c2"])
    }

    // MARK: Closing one connection and the others

    @Test func closingAConnectionDoesNotStrandQueuedRequestsOfOthers() async throws {
        let fixture = try GateFixture(limit: 1, queueLimit: 100)
        let holder = ICWire(fixture.server)
        let doomed = ICWire(fixture.server)
        let survivor = ICWire(fixture.server)
        let dropped: ICWire? = ICWire(fixture.server)
        holder.call("sleep")
        #expect(await independentConcurrencyEventually { fixture.active.current == 1 })
        // Interleaved in the queue: doomed, survivor, dropped, doomed, survivor.
        doomed.call("quick", ["tag": "doomed-1"])
        let first = survivor.call("quick", ["tag": "survivor-1"])
        dropped?.call("quick", ["tag": "dropped-1"])
        doomed.call("quick", ["tag": "doomed-2"])
        let second = survivor.call("quick", ["tag": "survivor-2"])

        // One waiting connection closes at once: its requests never run.
        #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await doomed.connection.close(graceSeconds: 0) })
        #expect(fixture.order.value.isEmpty)
        // The connection that holds the only slot closes: its handler is cancelled, the slot
        // passes on, and the requests of the surviving connections run.
        #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await holder.connection.close(graceSeconds: 0) })
        #expect(try await survivor.response(to: first).independentConcurrencyText == "quick")
        #expect(try await survivor.response(to: second).independentConcurrencyText == "quick")
        #expect(await independentConcurrencyEventually { fixture.active.current == 0 })
        #expect(fixture.order.value == ["survivor-1", "dropped-1", "survivor-2"])
        #expect(doomed.sink.history.isEmpty)
        #expect(dropped?.sink.history.count == 1)
        await fixture.expectFullCapacity("after closing a waiting connection and the connection holding the slot")
    }

    /// A handler that ignores cancellation keeps its slot until it returns — it is still user
    /// code in progress — but not a moment longer, also when its connection is long closed.
    @Test func aStubbornHandlerOfAClosedConnectionReturnsItsSlotWhenItEnds() async throws {
        let fixture = try GateFixture(limit: 2, queueLimit: 100)
        let closing = ICWire(fixture.server)
        let other = ICWire(fixture.server)
        closing.call("stubborn")
        closing.call("stubborn")
        #expect(await independentConcurrencyEventually { fixture.active.current == 2 })
        let waiting = other.call("quick", ["tag": "after"])
        #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await closing.connection.close(graceSeconds: 0) })
        let mark = closing.sink.mark
        // Both slots are still taken by code that is still running.
        #expect(await other.isSilent(for: .milliseconds(100)))
        #expect(fixture.order.value.isEmpty)
        fixture.stubbornGate.value.open()
        #expect(try await other.response(to: waiting).independentConcurrencyText == "quick")
        #expect(await independentConcurrencyEventually { fixture.active.current == 0 })
        // Nothing of the closed connection's late handlers was sent.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(closing.sink.history.count == mark)
        fixture.stubbornGate.set(ICGate())
        await fixture.expectFullCapacity("after stubborn handlers of a closed connection returned")
    }

    @Test func cheapMethodsAnswerOnEveryConnectionWhileTheGateIsFull() async throws {
        let fixture = try GateFixture(limit: 1, queueLimit: 1)
        try fixture.server.register(prompt: PromptDefinition(name: "plain")) { _, _ in PromptResult(messages: []) }
        let busy = ICWire(fixture.server)
        busy.call("hold")
        busy.call("hold")
        #expect(await independentConcurrencyEventually { fixture.holding.total == 1 })
        let other = ICWire(fixture.server)
        // The gate is full: user code is refused…
        #expect(try await other.request("tools/call", ["name": "quick"]).independentConcurrencyErrorCode == -31001)
        // …while everything without user code answers at once.
        #expect(try await other.request("server/discover")["result"] != nil)
        #expect(try await other.request("tools/list")["result"]?["tools"]?.arrayValue?.count == 4)
        #expect(try await other.request("prompts/list")["result"] != nil)
        #expect(try await other.request("no/such/method").independentConcurrencyErrorCode == -32601)
        let listen = other.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        #expect(try await other.next()["method"] == "notifications/subscriptions/acknowledged")
        other.cancel(listen)
        let legacy = ICWire(fixture.server, modern: false)
        try await legacy.initialize()
        #expect(try await legacy.request("ping")["result"] != nil)
        #expect(try await legacy.request("logging/setLevel", ["level": "error"])["result"] != nil)
        fixture.holdGate.value.open()
        #expect(await independentConcurrencyEventually { fixture.active.current == 0 })
    }

    // MARK: Liveness across connections

    @Test func aPeerThatDoesNotReadDoesNotStarveOtherConnections() async throws {
        let done = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 100
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in
            done.enter()
            return .text(String(repeating: "b", count: 3000))
        }
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        // Connection A: a real outbound queue with a small budget that nobody drains.
        let stuckQueue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 100_000)
        let stuck = server.connect(to: stuckQueue)
        for id in 0..<4 {
            stuck.receive(Array(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"blob",\#(modernMeta)}}"#.utf8))
        }
        // All four handlers have returned (the first response is queued, the rest wait for room).
        #expect(await independentConcurrencyEventually { done.total >= 3 })
        try? await Task.sleep(for: .milliseconds(100))
        // Connection B is healthy.
        let healthy = ICWire(server)
        let id = healthy.call("echo")
        let answer = await healthy.sink.next(timeout: .seconds(3))
        #expect(
            answer?.json?["id"] == id.json,
            "a healthy connection got no handler slot: handlers that already returned hold the slots while their peer does not read")
        // Let everything go.
        stuckQueue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.close(graceSeconds: 0) }
    }

    // MARK: No slot is ever lost

    @Test(arguments: [UInt64(1), 2, 3])
    func noSlotIsLostWhateverHappensToRequestsAndConnections(seed: UInt64) async throws {
        let fixture = try GateFixture(limit: 3, queueLimit: 5)
        var random = GateRandom(seed: seed)
        for cycle in 0..<20 {
            fixture.stubbornGate.set(ICGate())
            let wires = (0..<4).map { _ in ICWire(fixture.server) }
            var outstanding: [[RequestID]] = Array(repeating: [], count: wires.count)
            for _ in 0..<40 {
                let index = random.below(wires.count)
                let wire = wires[index]
                switch random.below(10) {
                case 0, 1, 2: wire.call("quick")
                case 3, 4: outstanding[index].append(wire.call("sleep"))
                case 5: outstanding[index].append(wire.call("stubborn"))
                case 6, 7:
                    // Cancel something of this connection: it may be running, queued, finished or refused.
                    if !outstanding[index].isEmpty {
                        wire.cancel(outstanding[index].remove(at: random.below(outstanding[index].count)))
                    }
                case 8: wire.cancel(RequestID(random.below(2000) + 900))
                default: await Task.yield()
                }
            }
            // In most cycles the stubborn handlers end before their connections go away.
            let stubbornOutliveTheirConnection = cycle % 5 == 4
            if !stubbornOutliveTheirConnection { fixture.stubbornGate.value.open() }
            for (index, wire) in wires.enumerated() {
                switch (index + cycle) % 4 {
                case 0:
                    let connection = wire.connection
                    #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: 0) })
                case 1:
                    let connection = wire.connection
                    #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: 0.01) })
                case 2:
                    // Stays open: the client cancels what it still has in flight.
                    for id in outstanding[index] { wire.cancel(id) }
                default:
                    // Closed twice, concurrently, while requests are in flight.
                    let connection = wire.connection
                    async let one = independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: 0) }
                    async let two = independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: 0.005) }
                    let both = await (one, two)
                    #expect(both.0 && both.1)
                }
            }
            fixture.stubbornGate.value.open()
            await fixture.expectFullCapacity("seed \(seed), cycle \(cycle)")
        }
    }

    // MARK: Stress across connections

    @Test(arguments: [UInt64(21), 22])
    func randomTrafficOnManyConnectionsKeepsEveryInvariant(seed: UInt64) async throws {
        let fixture = try GateFixture(limit: 4, queueLimit: 6)
        var random = GateRandom(seed: seed &+ UInt64.random(in: 0..<1000) &* 8)
        let context = "seed \(random.state)"
        let count = 6
        let wires = (0..<count).map { _ in ICWire(fixture.server) }
        var cancelMark: [[Int: Int]] = Array(repeating: [:], count: count)
        var posted: [Int] = Array(repeating: 0, count: count)
        var closedAt: [Int?] = Array(repeating: nil, count: count)
        // Readers take frames off the queues while the engine works.
        let stop = ICBox(false)
        let readers = wires.map { wire in
            Task { while !stop.value { _ = await wire.sink.next(timeout: .milliseconds(5)) } }
        }
        for step in 0..<3000 {
            let index = random.below(count)
            guard closedAt[index] == nil else { continue }
            let wire = wires[index]
            let number = posted[index]
            posted[index] += 1
            wire.call("quick", ["tag": .string("c\(index)-\(number)")], id: RequestID(number))
            switch random.below(8) {
            case 0:
                wire.cancel(RequestID(number))
                cancelMark[index][number] = wire.sink.mark
            case 1:
                let earlier = random.below(number + 1)
                if cancelMark[index][earlier] == nil {
                    wire.cancel(RequestID(earlier))
                    cancelMark[index][earlier] = wire.sink.mark
                }
            default: break
            }
            // Two of the connections go away in the middle of the traffic.
            if step == 1200 || step == 2100 {
                let victim = step == 1200 ? 1 : 4
                let connection = wires[victim].connection
                #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: step == 1200 ? 0 : 0.002) }, "\(context)")
                closedAt[victim] = wires[victim].sink.mark
            }
            if step % 12 == 0 { await Task.yield() }
        }
        // Quiescence: every request of an open connection that was not cancelled is answered.
        @Sendable func counts(_ index: Int) -> [Int: [Int]] {
            var positions: [Int: [Int]] = [:]
            for record in wires[index].sink.sent {
                guard let message = record.json, message["method"] == nil, let id = message["id"]?.intValue else { continue }
                positions[id, default: []].append(record.index)
            }
            return positions
        }
        let (finalClosed, finalPosted, finalMarks) = (closedAt, posted, cancelMark)
        let settled = await independentConcurrencyEventually(timeout: .seconds(60)) {
            guard fixture.active.current == 0 else { return false }
            for index in 0..<count where finalClosed[index] == nil {
                let answered = counts(index)
                for number in 0..<finalPosted[index] where finalMarks[index][number] == nil && answered[number] == nil { return false }
            }
            return true
        }
        #expect(settled, "\(context): requests that were not cancelled were never answered")
        try? await Task.sleep(for: .milliseconds(100))
        stop.set(true)
        for reader in readers { await reader.value }

        #expect(fixture.active.peak <= 4, "\(context): \(fixture.active.peak) handlers ran at once; the limit is 4")
        for index in 0..<count {
            let answered = counts(index)
            var problems: [String] = []
            for number in 0..<posted[index] {
                let positions = answered[number] ?? []
                if positions.count > 1 { problems.append("\(number) answered \(positions.count) times") }
                if let mark = cancelMark[index][number], positions.contains(where: { $0 >= mark }) {
                    problems.append("\(number) answered after its cancellation")
                }
                if let closed = closedAt[index], positions.contains(where: { $0 >= closed }) {
                    problems.append("\(number) answered after close returned")
                }
                if closedAt[index] == nil, cancelMark[index][number] == nil, positions.count != 1 {
                    problems.append("\(number) answered \(positions.count) times")
                }
            }
            // Each response is on the connection that asked, and nowhere else.
            for record in wires[index].sink.sent {
                guard let message = record.json else {
                    problems.append("not JSON")
                    continue
                }
                if let text = message.independentConcurrencyText, text != "quick" { problems.append("foreign content \(text)") }
                if let id = message["id"]?.intValue, id >= posted[index] { problems.append("response to a request never sent: \(id)") }
            }
            if let closed = closedAt[index] {
                #expect(wires[index].sink.history.count == closed, "\(context): connection \(index) got frames after close returned")
            }
            #expect(problems.isEmpty, "\(context), connection \(index): \(problems.prefix(5))")
        }
        await fixture.expectFullCapacity("\(context), after the storm")
    }
}
