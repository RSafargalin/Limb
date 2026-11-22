import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let formSchema: JSONObject = ["type": "object", "properties": ["v": ["type": "string"]]]

/// Lives exactly as long as the handler frame that created it.
private final class Sentinel: Sendable {
    let live: ICMeter
    init(_ live: ICMeter) {
        self.live = live
        live.enter()
    }
    deinit { live.leave() }
}

@Suite(.timeLimit(.minutes(5)))
struct IndependentConcurrencyCloseTests {
    @Test func runningAndQueuedRequestsAreAnsweredWithinTheGracePeriod() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 100
        }
        try server.register(tool: ToolDefinition(name: "hold")) { arguments, context in
            await gate.wait()
            context.progress(1)
            return .text("held \(arguments["n"]?.intValue ?? -1)")
        }
        let wire = ICWire(server)
        var ids: [RequestID] = []
        for index in 0..<12 { ids.append(wire.call("hold", ["n": JSONValue(index)], meta: ["progressToken": JSONValue(index)])) }
        let connection = wire.connection
        let closed = ICBox(false)
        Task {
            await connection.close(graceSeconds: 60)
            closed.set(true)
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!closed.value, "close returned although twelve requests were in flight")
        gate.open()
        // A client that pipes requests in and closes stdin still gets every answer.
        var answered: Set<JSONValue> = []
        while answered.count < ids.count {
            let message = try await wire.next()
            if message["method"] == nil, let id = message["id"] {
                #expect(answered.insert(id).inserted)
                #expect(message.independentConcurrencyText?.hasPrefix("held") == true)
            }
        }
        #expect(answered == Set(ids.map(\.json)))
        // Idle now: close returns long before its sixty seconds are over.
        #expect(await independentConcurrencyEventually { closed.value })
        #expect(await wire.isSilent())
    }

    @Test func handlersStillRunningAfterTheGracePeriodAreCancelledAndCloseReturns() async throws {
        let cancelledSeen = ICMeter()
        let live = ICMeter()
        let never = ICGate()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            let sentinel = Sentinel(live)
            defer { _ = sentinel }
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                cancelledSeen.enter()
                throw error
            }
            return .text("woke")
        }
        try server.register(tool: ToolDefinition(name: "stuck")) { _, _ in
            await never.wait()
            return .text("never")
        }
        let wire = ICWire(server)
        for _ in 0..<5 { wire.call("sleep") }
        #expect(await independentConcurrencyEventually { live.current == 5 })
        let connection = wire.connection
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await independentConcurrencyFinishes(within: .seconds(30)) { await connection.close(graceSeconds: 0.3) })
        #expect(clock.now - start >= .milliseconds(250), "close did not wait for the grace period")
        #expect(cancelledSeen.total == 5)
        // The cancelled handlers are gone: nothing is left suspended.
        #expect(await independentConcurrencyEventually { live.current == 0 })
        #expect(await wire.isSilent(for: .milliseconds(50)))

        // "A handler that ignores cancellation must not keep the process alive."
        let other = ICWire(server)
        other.call("stuck")
        let stuckConnection = other.connection
        #expect(await independentConcurrencyFinishes(within: .seconds(30)) { await stuckConnection.close(graceSeconds: 0.1) })
        never.open()
    }

    /// With no grace at all the handlers are cancelled at once. Repeated, because the wait for
    /// idleness races its own timer.
    @Test func zeroGraceCancelsImmediatelyEveryTime() async throws {
        let cancelledSeen = ICMeter()
        let started = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            started.enter()
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                cancelledSeen.enter()
                throw error
            }
            return .text("woke")
        }
        var hung = 0
        var hungRounds: [String] = []
        let rounds = 1500
        for round in 0..<rounds {
            let wire = ICWire(server)
            wire.call("sleep")
            #expect(await independentConcurrencyEventually { started.total == round + 1 })
            let connection = wire.connection
            let grace: Double = round % 3 == 0 ? 0 : (round % 3 == 1 ? -1 : 0.000_001)
            if await !independentConcurrencyFinishes(within: .seconds(20), { await connection.close(graceSeconds: grace) }) {
                hung += 1
                hungRounds.append("round \(round) (grace \(grace))")
                if hung >= 3 { break }
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let neverCancelled = started.total - cancelledSeen.total
        #expect(
            hung == 0,
            "close(graceSeconds: 0) did not return within 20 s in \(hung) of \(started.total) rounds; \(neverCancelled) handlers were never cancelled; \(hungRounds)")
    }

    @Test func nothingIsSentAfterCloseHasReturned() async throws {
        let gate = ICGate()
        let finished = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "stubborn")) { _, context in
            await gate.wait()
            context.progress(1)
            context.log(.error, "after close")
            finished.enter()
            return .text("after close")
        }
        let wire = ICWire(server)
        wire.call("stubborn", meta: ["progressToken": 1, MetaKey.logLevel: "debug"])
        let connection = wire.connection
        #expect(await independentConcurrencyFinishes(within: .seconds(30)) { await connection.close(graceSeconds: 0.05) })
        let mark = wire.sink.mark
        gate.open()
        #expect(await independentConcurrencyEventually { finished.total == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        let late = wire.sink.history.filter { $0.index >= mark }.map(\.text)
        #expect(late.isEmpty, "queued after close() returned: \(late)")
    }

    @Test func requestsThatArriveWhileClosingAreNotStartedButCancellationStillWorks() async throws {
        let ran = ICMeter()
        let cancelledSeen = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            ran.enter()
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                cancelledSeen.enter()
                throw error
            }
            return .text("woke")
        }
        let wire = ICWire(server)
        let running = wire.call("sleep")
        #expect(await independentConcurrencyEventually { ran.total == 1 })
        let connection = wire.connection
        let closed = ICBox(false)
        Task {
            await connection.close(graceSeconds: 120)
            closed.set(true)
        }
        try? await Task.sleep(for: .milliseconds(50))
        // New work is not accepted any more…
        wire.call("sleep")
        wire.post("resources/read", ["uri": "ic://none"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ran.total == 1)
        // …but a cancellation for a request in flight is still honoured, which ends the wait early.
        wire.cancel(running)
        #expect(await independentConcurrencyEventually { cancelledSeen.total == 1 })
        #expect(await independentConcurrencyEventually { closed.value }, "close kept waiting although nothing was in flight")
        #expect(wire.framesSent(for: running).isEmpty)
    }

    @Test func aHandlerWaitingForTheClientIsReleasedByClose() async throws {
        let live = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "ask")) { _, context in
            let sentinel = Sentinel(live)
            defer { _ = sentinel }
            let answer = try await context.elicit("k", message: "?", schema: formSchema)
            return .text(answer.action.rawValue)
        }
        let wire = ICWire(server, modern: false)
        try await wire.initialize(capabilities: ["elicitation": [:]])
        let calls = (0..<8).map { _ in wire.call("ask") }
        var requests: [JSONValue] = []
        for _ in 0..<8 { requests.append(try await wire.next()) }
        #expect(live.current == 8)
        let connection = wire.connection
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await independentConcurrencyFinishes(within: .seconds(30)) { await connection.close(graceSeconds: 20) })
        // The client will never answer: close does not sit out the whole grace period for it.
        #expect(clock.now - start < .seconds(15))
        #expect(await independentConcurrencyEventually { live.current == 0 }, "\(live.current) handlers are still suspended")
        // Each call is answered at most once, and answers that arrive now are ignored.
        for request in requests { wire.send(["jsonrpc": "2.0", "id": request["id"]!, "result": ["action": "accept"]]) }
        try? await Task.sleep(for: .milliseconds(100))
        for call in calls { #expect(wire.framesSent(for: call).count <= 1) }
        #expect(!wire.sink.history.compactMap(\.json).contains { $0.independentConcurrencyText == "accept" })
    }

    @Test func concurrentAndRepeatedClosesAllReturn() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server)
        let id = wire.call("hold")
        let connection = wire.connection
        let returned = ICMeter()
        for index in 0..<8 {
            Task {
                await connection.close(graceSeconds: index % 2 == 0 ? 30 : 0.05)
                returned.enter()
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        gate.open()
        #expect(await independentConcurrencyEventually(timeout: .seconds(20)) { returned.total == 8 }, "\(returned.total) of 8 closes returned")
        #expect(await independentConcurrencyFinishes(within: .seconds(10)) { await connection.close(graceSeconds: 5) })
        _ = id
    }

    @Test func closeReturnsEvenIfThePeerNeverReadsTheResponses() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 4000)) }
        let queue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 1000)
        let connection = server.connect(to: queue)
        for id in 0..<6 {
            connection.receive(
                Array(
                    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"blob","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                        .utf8))
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await independentConcurrencyFinishes(within: .seconds(30)) { await connection.close(graceSeconds: 0.2) })
        queue.close()
    }

    // MARK: Release of resources

    @Test func theConnectionIsReleasedOnceItIsClosedAndIdle() async throws {
        let live = ICMeter()
        let gate = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 100
        }
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            let sentinel = Sentinel(live)
            defer { _ = sentinel }
            try await Task.sleep(for: .seconds(300))
            return .text("woke")
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            let sentinel = Sentinel(live)
            defer { _ = sentinel }
            await gate.wait()
            return .text("held")
        }
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }

        weak var closedConnection: Connection?
        weak var droppedConnection: Connection?
        weak var sink: IndependentConcurrencySink?
        do {
            // Closed with requests running, queued, cancelled, and a subscription open.
            let wire = ICWire(server)
            closedConnection = wire.connection
            sink = wire.sink
            wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
            wire.call("sleep")
            wire.call("hold")
            for _ in 0..<10 { wire.call("echo") }  // queued behind the two running handlers
            let cancelled = wire.call("echo")
            wire.cancel(cancelled)
            await wire.connection.close(graceSeconds: 0.1)
            gate.open()

            // Dropped by its transport without `close`, idle, with a subscription open.
            let idle = ICWire(server)
            droppedConnection = idle.connection
            idle.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
            #expect(try await idle.request("tools/call", ["name": "echo"]).independentConcurrencyText == "ok")
        }
        #expect(await independentConcurrencyEventually { live.current == 0 })
        let closedReleased = await independentConcurrencyEventually(timeout: .seconds(5)) { [closedConnection] in closedConnection == nil }
        _ = closedReleased
        try? await Task.sleep(for: .milliseconds(200))
        #expect(closedConnection == nil, "a closed, idle connection is still alive: something retains it")
        #expect(sink == nil, "the sink of a closed connection is still alive")
        #expect(droppedConnection == nil, "an idle connection dropped by its transport is still alive")
        // The server no longer delivers events to them (nothing to observe but the absence of a crash).
        try server.register(tool: ToolDefinition(name: "later")) { _, _ in .text("") }
    }
}
