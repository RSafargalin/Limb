import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

/// A `tools/call` frame of exactly `size` bytes.
private func frame(id: Int, tool: String, size: Int) -> String {
    let head = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{"pad":""#
    let tail = #""},\#(modernMeta)}}"#
    let padding = size - head.utf8.count - tail.utf8.count
    precondition(padding >= 0, "frame cannot be that small")
    return head + String(repeating: "x", count: padding) + tail
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyAdmissionTests {
    // MARK: Parallelism

    @Test func parallelismLimitIsNeverExceededAndIsReached() async throws {
        let active = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 3
            configuration.budgets.maxQueuedRequests = 10_000
        }
        try server.register(tool: ToolDefinition(name: "work")) { arguments, _ in
            active.enter()
            defer { active.leave() }
            let spins = arguments["spins"]?.intValue ?? 0
            for _ in 0..<spins { await Task.yield() }
            if spins % 3 == 0 { try? await Task.sleep(for: .microseconds(200)) }
            return .text("done")
        }
        try server.register(resource: ResourceDefinition(uri: "ic://work", name: "work")) { _, _ in
            active.enter()
            defer { active.leave() }
            await Task.yield()
            return []
        }
        let wire = ICWire(server)
        let total = 600
        var cancelled: Set<RequestID> = []
        for index in 0..<total {
            let id =
                index % 4 == 0
                ? wire.post("resources/read", ["uri": "ic://work"])
                : wire.call("work", ["spins": JSONValue(index % 7)])
            // Cancelled handlers that are still running keep occupying their slot.
            if index % 5 == 0 {
                wire.cancel(id)
                cancelled.insert(id)
            }
        }
        var answered: Set<RequestID> = []
        while answered.count < total - cancelled.count {
            let message = try await wire.next()
            let id = try #require(message["id"].flatMap(RequestID.init(json:)))
            #expect(answered.insert(id).inserted)
        }
        #expect(await independentConcurrencyEventually { active.current == 0 })
        #expect(active.peak <= 3, "\(active.peak) handlers ran at once with a limit of 3")
        // The measurement is not vacuous: the limit was actually reached.
        #expect(active.peak == 3)
    }

    /// `ExecutionMode.serial`: "One at a time, in arrival order: for code that is not safe to run
    /// concurrently." `Server`: "serves them to any number of connections". Code that is not safe to
    /// run concurrently is not safe to run concurrently from two connections either.
    @Test func serialModeHoldsAcrossConnectionsOfOneServer() async throws {
        let active = ICMeter()
        let gate = ICGate()
        let server = independentConcurrencyServer { $0.execution = .serial }
        try server.register(tool: ToolDefinition(name: "exclusive")) { _, _ in
            active.enter()
            await gate.wait()
            active.leave()
            return .text("done")
        }
        let first = ICWire(server)
        let second = ICWire(server)
        let a = first.call("exclusive")
        #expect(await independentConcurrencyEventually { active.current == 1 })
        let b = second.call("exclusive")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(active.peak == 1, "two handlers of a .serial server ran at the same time")
        gate.open()
        _ = try await first.response(to: a)
        _ = try await second.response(to: b)
    }

    // MARK: Queue limits

    @Test func queueLimitByCountAtTheExactBoundary() async throws {
        let gate = ICGate()
        let started = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 3
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            started.enter()
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server)
        var accepted: [RequestID] = []
        for _ in 0..<5 { accepted.append(wire.call("hold")) }
        // Two run, three wait: nothing is refused yet.
        #expect(await wire.isSilent(for: .milliseconds(50)))
        #expect(started.total == 2)
        for id: RequestID in ["over-1", 777_777] {
            wire.call("hold", id: id)
            let refusal = try await wire.next()
            #expect(refusal["id"] == id.json)
            #expect(refusal.independentConcurrencyErrorCode == -31001)
            #expect(refusal.independentConcurrencyErrorCode == MCPError.Code.overloaded)
            #expect(refusal["error"]?["message"]?.stringValue?.isEmpty == false)
        }
        // Cheap methods and cancellation are not subject to admission.
        #expect(try await wire.request("server/discover")["result"] != nil)
        gate.open()
        var answered: [JSONValue] = []
        for _ in 0..<5 { answered.append(try await wire.next()["id"]!) }
        #expect(Set(answered) == Set(accepted.map(\.json)))
        // The refused requests never ran.
        #expect(started.total == 5)
        #expect(await wire.isSilent())
    }

    @Test func zeroLengthQueueRefusesAsSoonAsEveryHandlerIsBusy() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 1
            configuration.budgets.maxQueuedRequests = 0
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server)
        let running = wire.call("hold")
        let refused = wire.call("hold")
        let refusal = try await wire.next()
        #expect(refusal["id"] == refused.json)
        #expect(refusal.independentConcurrencyErrorCode == -31001)
        gate.open()
        #expect(try await wire.next()["id"] == running.json)
    }

    @Test func queueLimitByBytesAtTheExactBoundary() async throws {
        let gates = [ICGate(), ICGate()]
        let running = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 1
            configuration.budgets.maxQueuedRequests = 1000
            configuration.budgets.maxQueuedBytes = 10_000
        }
        try server.register(tool: ToolDefinition(name: "hold0")) { _, _ in
            running.enter()
            await gates[0].wait()
            return .text("held")
        }
        try server.register(tool: ToolDefinition(name: "hold1")) { _, _ in
            running.enter()
            await gates[1].wait()
            return .text("held")
        }
        let wire = ICWire(server)
        func expectOverload(_ id: Int, _ comment: Comment) async throws {
            let refusal = try await wire.next()
            #expect(refusal["id"] == JSONValue(id), comment)
            #expect(refusal.independentConcurrencyErrorCode == -31001, comment)
        }
        wire.send(frame(id: 1, tool: "hold0", size: 300))  // runs
        wire.send(frame(id: 2, tool: "hold0", size: 6000))  // waits: 6000 bytes
        #expect(await wire.isSilent(for: .milliseconds(30)))
        wire.send(frame(id: 3, tool: "hold0", size: 4001))  // 10 001 > 10 000
        try await expectOverload(3, "one byte over the queue's byte budget")
        wire.send(frame(id: 4, tool: "hold0", size: 4000))  // exactly 10 000
        #expect(await wire.isSilent(for: .milliseconds(30)), "a frame that exactly fills the byte budget was refused")
        wire.send(frame(id: 5, tool: "hold0", size: 300))
        try await expectOverload(5, "the byte budget is full")

        // Cancelling a waiting request returns its bytes.
        wire.cancel(2)
        wire.send(frame(id: 6, tool: "hold0", size: 6001))
        try await expectOverload(6, "one byte more than cancellation released")
        wire.send(frame(id: 7, tool: "hold1", size: 6000))
        #expect(await wire.isSilent(for: .milliseconds(30)), "cancellation did not release the cancelled request's bytes")

        // Waiting requests start in arrival order and give their bytes back when they start.
        gates[0].open()
        #expect(try await wire.next()["id"] == 1)
        #expect(try await wire.next()["id"] == 4)
        #expect(await independentConcurrencyEventually { running.total == 3 })  // 7 is running on gate 1
        wire.send(frame(id: 8, tool: "hold1", size: 10_000))
        #expect(await wire.isSilent(for: .milliseconds(30)), "the byte counter did not return to zero")
        wire.send(frame(id: 9, tool: "hold1", size: 300))
        try await expectOverload(9, "the byte budget is full again")
        gates[1].open()
        #expect(try await wire.next()["id"] == 7)
        #expect(try await wire.next()["id"] == 8)
        #expect(await wire.isSilent())
    }

    @Test func byteCounterDoesNotDriftOverManyCancelAndRefillCycles() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 1
            configuration.budgets.maxQueuedRequests = 1000
            configuration.budgets.maxQueuedBytes = 5000
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server)
        wire.send(frame(id: 0, tool: "hold", size: 300))
        var id = 1
        for cycle in 0..<200 {
            let sizes = cycle % 2 == 0 ? [2500, 2500] : [1000, 1500, 2500]
            var ids: [Int] = []
            for size in sizes {
                wire.send(frame(id: id, tool: "hold", size: size))
                ids.append(id)
                id += 1
            }
            for cancelled in ids.reversed() { wire.cancel(RequestID(cancelled)) }
        }
        #expect(wire.sink.history.isEmpty, "a refill that exactly fits was refused: the byte counter drifted")
        wire.send(frame(id: id, tool: "hold", size: 5000))
        #expect(await wire.isSilent(for: .milliseconds(30)))
        wire.send(frame(id: id + 1, tool: "hold", size: 300))
        #expect(try await wire.next().independentConcurrencyErrorCode == -31001)
        gate.open()
        #expect(try await wire.next()["id"] == 0)
        #expect(try await wire.next()["id"] == JSONValue(id))
    }

    // MARK: Serial mode

    @Test func serialModeRunsEveryKindOfUserCodeOneAtATimeInArrivalOrder() async throws {
        let active = ICMeter()
        let order = ICBox<[String]>([])
        let gate = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.execution = .serial
            configuration.budgets.maxQueuedRequests = 1000
            // The limit of concurrent handlers must not matter in serial mode.
            configuration.budgets.maxConcurrentHandlers = 16
        }
        @Sendable func step(_ name: String) async {
            active.enter()
            order.update { $0.append(name) }
            await Task.yield()
            await Task.yield()
            active.leave()
        }
        try server.register(tool: ToolDefinition(name: "first")) { _, _ in
            active.enter()
            order.update { $0.append("first") }
            await gate.wait()
            active.leave()
            return .text("first")
        }
        try server.register(tool: ToolDefinition(name: "tool")) { arguments, _ in
            await step("tool-\(arguments["n"]?.intValue ?? -1)")
            return .text("tool")
        }
        try server.register(resource: ResourceDefinition(uri: "ic://serial", name: "serial")) { _, _ in
            await step("resource")
            return [.text(uri: "ic://serial", text: "r")]
        }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "ic://item/{id}", name: "item"), complete: { _, _ in
            await step("complete-template")
            return CompletionResult(values: ["1"])
        }) { request, _ in
            await step("template")
            return [.text(uri: request.uri, text: "t")]
        }
        try server.register(prompt: PromptDefinition(name: "prompt"), complete: { _, _ in
            await step("complete-prompt")
            return CompletionResult(values: ["a"])
        }) { _, _ in
            await step("prompt")
            return PromptResult(messages: [.user("p")])
        }
        try server.register(prompt: PromptDefinition(name: "plain")) { _, _ in PromptResult(messages: []) }
        try server.register(method: "custom/step") { _, _ in
            await step("custom")
            return [:]
        }
        let wire = ICWire(server)
        let blocker = wire.call("first")
        #expect(await independentConcurrencyEventually { active.current == 1 })

        var expected = ["first"]
        var ids: [RequestID] = [blocker]
        for round in 0..<8 {
            ids.append(wire.call("tool", ["n": JSONValue(round)]))
            expected.append("tool-\(round)")
            ids.append(wire.post("resources/read", ["uri": "ic://serial"]))
            expected.append("resource")
            ids.append(wire.post("resources/read", ["uri": "ic://item/5"]))
            expected.append("template")
            ids.append(wire.post("prompts/get", ["name": "prompt"]))
            expected.append("prompt")
            ids.append(
                wire.post("completion/complete", ["ref": ["type": "ref/prompt", "name": "prompt"], "argument": ["name": "x", "value": ""]]))
            expected.append("complete-prompt")
            ids.append(
                wire.post(
                    "completion/complete",
                    ["ref": ["type": "ref/resource", "uri": "ic://item/{id}"], "argument": ["name": "id", "value": ""]]))
            expected.append("complete-template")
            ids.append(wire.post("custom/step"))
            expected.append("custom")
        }
        // Nothing that runs user code has started while the first handler holds the only slot.
        #expect(await wire.isSilent(for: .milliseconds(100)))
        #expect(order.value == ["first"])

        #expect(try await wire.request("server/discover")["result"] != nil)
        #expect(try await wire.request("tools/list")["result"]?["tools"]?.arrayValue?.count == 2)
        #expect(try await wire.request("resources/list")["result"] != nil)
        #expect(try await wire.request("resources/templates/list")["result"] != nil)
        #expect(try await wire.request("prompts/list")["result"] != nil)
        #expect(try await wire.request("tools/call", ["name": "no-such-tool"]).independentConcurrencyErrorCode == -32602)
        #expect(try await wire.request("no/such/method").independentConcurrencyErrorCode == -32601)
        let subscription = wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        #expect(try await wire.next()["method"] == "notifications/subscriptions/acknowledged")
        wire.cancel(subscription)
        let plain = try await wire.request(
            "completion/complete", ["ref": ["type": "ref/prompt", "name": "plain"], "argument": ["name": "x", "value": ""]])
        #expect(plain["result"]?["completion"]?["values"] == [])
        #expect(order.value == ["first"])

        gate.open()
        var answers: [JSONValue] = []
        for _ in 0..<ids.count { answers.append(try await wire.next()["id"]!) }
        // Strict arrival order, both of execution and of the responses.
        #expect(order.value == expected)
        #expect(answers == ids.map(\.json))
        #expect(active.peak == 1, "\(active.peak) handlers ran at once in .serial mode")
        #expect(await wire.isSilent())
    }

    @Test func legacyPingBypassesTheSerialQueue() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer { $0.execution = .serial }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server, modern: false)
        try await wire.initialize()
        let held = wire.call("hold")
        let ping = try await wire.request("ping")
        #expect(ping["result"] != nil)
        #expect(try await wire.request("logging/setLevel", ["level": "error"])["result"] != nil)
        gate.open()
        #expect(try await wire.response(to: held).independentConcurrencyText == "held")
    }

    // MARK: Response size

    @Test func responseSizeLimitAtTheExactBoundary() async throws {
        func makeServer(limit: Int) throws -> Server {
            let server = independentConcurrencyServer { $0.budgets.maxResponseBytes = limit }
            try server.register(tool: ToolDefinition(name: "big")) { _, _ in .text(String(repeating: "y", count: 5000)) }
            return server
        }
        // Measure the frame the unconstrained server produces.
        let reference = ICWire(try makeServer(limit: 1 << 20))
        reference.call("big", id: 42)
        let record = try await reference.nextRecord()
        let size = record.frame.count
        #expect(size > 5000)

        let exact = ICWire(try makeServer(limit: size))
        exact.call("big", id: 42)
        let passed = try await exact.nextRecord()
        #expect(passed.frame == record.frame, "a response of exactly the limit must pass unchanged")

        let tight = ICWire(try makeServer(limit: size - 1))
        tight.call("big", id: 42)
        let refused = try await tight.next()
        #expect(refused["id"] == 42)
        #expect(refused.independentConcurrencyErrorCode == -31002)
        #expect(refused.independentConcurrencyErrorCode == MCPError.Code.responseTooLarge)
        // Never a truncated success.
        #expect(refused["result"] == nil)
        #expect(await tight.isSilent())
    }
}
