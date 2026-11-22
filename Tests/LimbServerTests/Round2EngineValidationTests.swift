import Dispatch
import Limb
import LimbTesting
import Synchronization
import Testing

// S1: argument validation and `makeInputState` run in the request's task, after admission,
// holding a slot; error forms by revision unchanged; `requestState` failures answered from the
// task. S2: at most `maxInputResponses` entries in `inputResponses`.

private typealias ICWire = IndependentConcurrencyWire
private typealias ICBox = IndependentConcurrencyBox
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter

private let inputs: JSONObject = ["elicitation": [:], "sampling": [:], "roots": [:]]
private let formSchema: JSONObject = ["type": "object", "properties": ["v": ["type": "string"]]]
private func accepted(_ value: String) -> JSONValue { ["action": "accept", "content": ["v": .string(value)]] }

/// A schema whose check takes a long time on a long string: the automaton of the pattern has
/// about 200 states and the string never matches, so every character costs all of them.
private let slowSchema: JSONObject = [
    "type": "object", "properties": ["s": ["type": "string", "pattern": "[ab]{0,200}c"]],
]
private let slowArguments: JSONObject = ["s": .string(String(repeating: "a", count: 2_000))]

private struct SealerFailure: Error {}

/// Lets the test hold `open` and counts how often it is called.
/// It blocks a thread of the cooperative pool, so at most half a second: a test elsewhere may need every
/// thread of the pool at once.
private final class BlockingSealer: RequestStateSealer, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let opened = ICMeter()
    let blocks: Bool
    init(blocks: Bool) { self.blocks = blocks }
    func seal(_ plaintext: [UInt8]) throws -> String { "sealed" }
    func open(_ sealed: String) throws -> [UInt8] {
        opened.enter()
        if blocks { _ = release.wait(timeout: .now() + 0.5) }
        throw SealerFailure()
    }
}

private func slowServer(_ configure: (inout ServerConfiguration) -> Void = { _ in }) throws -> (Server, ICMeter) {
    let runs = ICMeter()
    let server = round2EngineServer(configure)
    try server.register(tool: ToolDefinition(name: "slow", inputSchema: slowSchema)) { _, _ in
        runs.enter()
        return .text("ran")
    }
    try server.register(tool: ToolDefinition(name: "fast")) { _, _ in .text("fast") }
    return (server, runs)
}

@Suite(.timeLimit(.minutes(3)))
struct Round2EngineValidationTests {
    // MARK: Nothing schema-dependent on the reader

    @Test func slowValidationDoesNotDelayAnswersFromTheReader() async throws {
        let (server, runs) = try slowServer()
        let wire = ICWire(server)
        // Were the check on the reader, its answer would be queued before the reader's own.
        wire.call("slow", slowArguments, id: "slow")
        wire.post("server/discover", id: "d")
        wire.post("tools/list", id: "l")
        wire.post("no/such/method", id: "m")
        var order: [String] = []
        for _ in 0..<4 {
            let message = try await wire.next(timeout: .seconds(120))
            if let id = message["id"]?.stringValue { order.append(id) }
        }
        #expect(order == ["d", "l", "m", "slow"])
        #expect(runs.total == 0)
    }

    @Test func slowValidationDoesNotDelayAPingOfALegacySession() async throws {
        let (server, _) = try slowServer()
        let wire = ICWire(server, modern: false)
        try await wire.initialize(version: .v2025_06_18)
        wire.call("slow", slowArguments, id: "slow")
        wire.post("ping", id: "p")
        let first = try await wire.next(timeout: .seconds(120))
        #expect(first["id"] == "p")
        let second = try await wire.next(timeout: .seconds(120))
        #expect(second["id"] == "slow")
        #expect(second.round2EngineCode == -32602)
    }

    @Test func aRequestCancelledWhileItsArgumentsAreCheckedGetsNoResponse() async throws {
        // Serial: "slow" holds the only slot while its arguments are checked; "fast" queued
        // behind it answers only after that check ended.
        let (server, _) = try slowServer { $0.execution = .serial }
        let wire = ICWire(server)
        wire.call("slow", slowArguments, id: "slow")
        wire.cancel("slow")
        wire.call("fast", id: "fast")
        let message = try await wire.next(timeout: .seconds(120))
        #expect(message["id"] == "fast")
        #expect(await wire.isSilent())
    }

    @Test func aRequestCancelledBeforeItStartsNeverOpensItsState() async throws {
        let gate = ICGate()
        let sealer = BlockingSealer(blocks: false)
        let server = round2EngineServer { configuration in
            configuration.execution = .serial
            configuration.requestStateSealer = sealer
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        try server.register(tool: ToolDefinition(name: "fast")) { _, _ in .text("fast") }
        let wire = ICWire(server)
        wire.call("hold", id: "hold")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        wire.post("tools/call", ["name": "fast", "requestState": "forged"], id: "queued")
        wire.cancel("queued")
        wire.post("tools/call", ["name": "fast", "requestState": "forged"], id: "after")
        gate.open()
        #expect(try await wire.response(to: "hold")["result"] != nil)
        let after = try await wire.response(to: "after")
        #expect(after.round2EngineCode == -32602)
        // Only the request that was not cancelled opened its state.
        #expect(sealer.opened.total == 1)
        #expect(!wire.others.contains { $0["id"] == "queued" })
    }

    @Test func aBlockingSealerDoesNotStallTheReader() async throws {
        let sealer = BlockingSealer(blocks: true)
        let server = round2EngineServer { $0.requestStateSealer = sealer }
        try server.register(tool: ToolDefinition(name: "fast")) { _, _ in .text("fast") }
        let wire = ICWire(server)
        wire.post("tools/call", ["name": "fast", "requestState": "anything"], id: "c")
        #expect(await independentConcurrencyEventually { sealer.opened.total == 1 })
        // The sealer is blocked in the request's task; the reader still answers.
        await round2EngineWithin(.seconds(20)) {
            let discovery = try await wire.request("server/discover", id: "d")
            #expect(discovery["result"] != nil)
            let other = try await wire.request("tools/call", ["name": "fast"], id: "f")
            #expect(other["result"]?["content"]?[0]?["text"] == "fast")
        }
        sealer.release.signal()
        // Under heavy load the bounded wait may have ended first and the answer been read above.
        let refused = try await round2EngineResponse(wire, to: "c")
        #expect(refused.round2EngineCode == -32602)
        #expect(refused.round2EngineMessage?.contains("requestState") == true)
    }

    // MARK: Error forms by revision

    @Test(arguments: [
        (ProtocolVersion.v2026_07_28, true), (.v2025_11_25, true), (.v2025_06_18, false), (.v2025_03_26, false),
    ])
    func invalidArgumentsByRevision(version: ProtocolVersion, isToolError: Bool) async throws {
        let server = round2EngineServer()
        try server.register(
            tool: ToolDefinition(name: "strict", inputSchema: ["type": "object", "required": ["x"]])
        ) { _, _ in .text("ran") }
        let wire = ICWire(server, modern: version == .v2026_07_28)
        if version != .v2026_07_28 { try await wire.initialize(version: version) }
        let response = try await wire.request("tools/call", ["name": "strict", "arguments": ["y": 1]])
        if isToolError {
            #expect(response["result"]?["isError"] == true)
            #expect(response["result"]?["content"]?[0]?["text"]?.stringValue?.contains("Invalid arguments for tool \"strict\"") == true)
        } else {
            #expect(response.round2EngineCode == -32602)
            #expect(response.round2EngineMessage?.contains("Invalid arguments for tool \"strict\"") == true)
        }
    }

    // MARK: Validation holds a slot

    @Test func inSerialModeAnInvalidCallWaitsItsTurnAndAnswersInOrder() async throws {
        let gate = ICGate()
        let server = round2EngineServer { $0.execution = .serial }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        try server.register(
            tool: ToolDefinition(name: "strict", inputSchema: ["type": "object", "required": ["x"]])
        ) { _, _ in .text("strict") }
        let wire = ICWire(server, modern: false)
        try await wire.initialize(version: .v2025_06_18)
        wire.call("hold", id: "1")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        wire.call("strict", ["y": 1], id: "2")
        wire.call("strict", ["x": 1], id: "3")
        wire.call("strict", ["z": 1], id: "4")
        wire.post("ping", id: "5")
        #expect(try await wire.next()["id"] == "5")
        // The invalid calls wait behind the running handler like valid ones.
        #expect(await wire.isSilent(for: .milliseconds(200)))
        gate.open()
        var order: [String] = []
        var codes: [String: Int] = [:]
        for _ in 0..<4 {
            let message = try await wire.next()
            let id = message["id"]?.stringValue ?? "?"
            order.append(id)
            if let code = message.round2EngineCode { codes[id] = code }
        }
        #expect(order == ["1", "2", "3", "4"])
        #expect(codes == ["2": -32602, "4": -32602])
    }

    @Test func withTheQueueFullAnInvalidCallIsRefusedAsOverload() async throws {
        let gate = ICGate()
        let server = round2EngineServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 1
            configuration.budgets.maxQueuedRequests = 1
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        try server.register(
            tool: ToolDefinition(name: "strict", inputSchema: ["type": "object", "required": ["x"]])
        ) { _, _ in .text("strict") }
        let wire = ICWire(server)
        wire.call("hold", id: "1")
        #expect(await independentConcurrencyEventually { gate.waiting == 1 })
        wire.call("strict", ["x": 1], id: "2")
        let refused = try await wire.request("tools/call", ["name": "strict", "arguments": ["y": 1]], id: "3")
        #expect(refused.round2EngineCode == -31001)
        gate.open()
        #expect(try await wire.response(to: "1")["result"] != nil)
        #expect(try await wire.response(to: "2")["result"] != nil)
    }

    // MARK: requestState failures, answered from the task

    private enum Target: String, CaseIterable, Sendable { case tool, prompt, resource }
    private enum Failure: String, CaseIterable, Sendable { case forged, expired, fingerprint }

    private static func stateServer(lifetime: Int) throws -> Server {
        let server = round2EngineServer { $0.requestStateLifetimeSeconds = lifetime }
        try server.register(tool: ToolDefinition(name: "ask")) { _, context in
            let a = try await context.elicit("a", message: "A?", schema: formSchema)
            return .text(a.content?["v"]?.stringValue ?? "-")
        }
        try server.register(prompt: PromptDefinition(name: "ask", arguments: [PromptArgument(name: "k")])) { _, context in
            let a = try await context.elicit("a", message: "A?", schema: formSchema)
            return PromptResult(messages: [.user(a.content?["v"]?.stringValue ?? "-")])
        }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "r2://doc/{id}", name: "doc")) { request, context in
            let a = try await context.elicit("a", message: "A?", schema: formSchema)
            return [.text(uri: request.uri, text: a.content?["v"]?.stringValue ?? "-")]
        }
        return server
    }

    private static func request(_ target: Target, variant: Int) -> (String, JSONObject) {
        switch target {
        case .tool: ("tools/call", ["name": "ask", "arguments": ["k": .number(JSONNumber(variant))]])
        case .prompt: ("prompts/get", ["name": "ask", "arguments": ["k": .string("v\(variant)")]])
        case .resource: ("resources/read", ["uri": .string("r2://doc/\(variant)")])
        }
    }

    @Test(arguments: Target.allCases, Failure.allCases)
    private func requestStateFailures(target: Target, failure: Failure) async throws {
        let server = try Self.stateServer(lifetime: failure == .expired ? -5 : 900)
        let wire = ICWire(server, capabilities: inputs)
        let (method, params) = Self.request(target, variant: 1)
        let first = try await wire.request(method, params)
        #expect(first["result"]?["resultType"] == "input_required")
        let issued = try #require(first["result"]?["requestState"])
        var retry = failure == .fingerprint ? Self.request(target, variant: 2).1 : params
        retry["requestState"] = failure == .forged ? "forged-state" : issued
        retry["inputResponses"] = ["a": accepted("A")]
        let response = try await wire.request(method, retry)
        #expect(response.round2EngineCode == -32602, "\(response)")
        let expected =
            switch failure {
            case .forged: "failed verification"
            case .expired: "expired"
            case .fingerprint: "different request"
            }
        #expect(response.round2EngineMessage?.contains(expected) == true, "\(response)")
        // And with the right state the round completes.
        if failure != .expired {
            var good = params
            good["requestState"] = issued
            good["inputResponses"] = ["a": accepted("A")]
            let done = try await wire.request(method, good)
            #expect(done["result"]?["resultType"] == "complete", "\(done)")
        }
    }

    // MARK: S2 — inputResponses

    private static func countingServer(limit: Int?, runs: ICMeter) throws -> Server {
        let server = round2EngineServer { configuration in
            if let limit { configuration.budgets.maxInputResponses = limit }
        }
        try server.register(tool: ToolDefinition(name: "plain")) { _, _ in
            runs.enter()
            return .text("ran")
        }
        try server.register(prompt: PromptDefinition(name: "plain")) { _, _ in
            runs.enter()
            return PromptResult(messages: [])
        }
        try server.register(resource: ResourceDefinition(uri: "r2://plain", name: "plain")) { request, _ in
            runs.enter()
            return [.text(uri: request.uri, text: "")]
        }
        return server
    }

    private static func responses(_ count: Int) -> JSONValue {
        var object = JSONObject()
        for index in 0..<count { object["k\(index)"] = accepted("\(index)") }
        return .object(object)
    }

    @Test(arguments: [(nil, 64), (3, 3), (0, 0), (1, 1)] as [(Int?, Int)])
    func exactlyTheLimitIsAcceptedAndOneMoreRefused(configured: Int?, limit: Int) async throws {
        let runs = ICMeter()
        let wire = ICWire(try Self.countingServer(limit: configured, runs: runs), capabilities: inputs)
        let fits = try await wire.request("tools/call", ["name": "plain", "inputResponses": Self.responses(limit)])
        #expect(fits["result"]?["content"]?[0]?["text"] == "ran", "\(fits)")
        let over = try await wire.request("tools/call", ["name": "plain", "inputResponses": Self.responses(limit + 1)])
        #expect(over.round2EngineCode == -32602)
        #expect(over.round2EngineMessage?.contains("inputResponses") == true)
        #expect(runs.total == 1)
    }

    @Test func theLimitAppliesToPromptsAndResources() async throws {
        let runs = ICMeter()
        let wire = ICWire(try Self.countingServer(limit: 2, runs: runs), capabilities: inputs)
        let prompt = try await wire.request("prompts/get", ["name": "plain", "inputResponses": Self.responses(3)])
        #expect(prompt.round2EngineCode == -32602)
        let resource = try await wire.request("resources/read", ["uri": "r2://plain", "inputResponses": Self.responses(3)])
        #expect(resource.round2EngineCode == -32602)
        #expect(runs.total == 0)
        let fine = try await wire.request("resources/read", ["uri": "r2://plain", "inputResponses": Self.responses(2)])
        #expect(fine["result"] != nil)
    }

    @Test func tooManyEntriesAreRefusedBeforeTheStateIsOpened() async throws {
        let sealer = BlockingSealer(blocks: false)
        let server = round2EngineServer { configuration in
            configuration.budgets.maxInputResponses = 2
            configuration.requestStateSealer = sealer
        }
        try server.register(tool: ToolDefinition(name: "plain")) { _, _ in .text("ran") }
        let wire = ICWire(server, capabilities: inputs)
        let response = try await wire.request(
            "tools/call", ["name": "plain", "requestState": "x", "inputResponses": Self.responses(3)])
        #expect(response.round2EngineMessage?.contains("inputResponses") == true)
        #expect(sealer.opened.total == 0)
    }

    @Test(arguments: [ProtocolVersion.v2025_11_25, .v2025_06_18, .v2025_03_26])
    func legacyRevisionsHaveNoInputResponsesToLimit(version: ProtocolVersion) async throws {
        let runs = ICMeter()
        let wire = ICWire(try Self.countingServer(limit: 2, runs: runs), modern: false)
        try await wire.initialize(version: version)
        let response = try await wire.request("tools/call", ["name": "plain", "inputResponses": Self.responses(50)])
        #expect(response["result"]?["content"]?[0]?["text"] == "ran", "\(response)")
    }
}
