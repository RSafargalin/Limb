import Limb
import LimbTesting
import Synchronization

struct Boom: Error {}

/// Lets a test hold a handler open and release it deterministically.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

final class Counter: Sendable {
    private let value = Mutex(0)
    @discardableResult func increment() -> Int { value.withLock { $0 += 1; return $0 } }
    var count: Int { value.withLock { $0 } }
}

func makeServer(
    gate: Gate = Gate(), started: Counter = Counter(),
    configure: (inout ServerConfiguration) -> Void = { _ in }
) throws -> Server {
    let server = Server(name: "fixture", version: "1.2.3", title: "Fixture", instructions: "Use wisely.") { configuration in
        configuration.diagnostics = { _ in }
        configure(&configuration)
    }
    try server.register(
        tool: ToolDefinition(
            name: "echo", title: "Echo", description: "Returns its input.",
            inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
            annotations: ToolAnnotations(readOnlyHint: true))
    ) { arguments, _ in
        .text(arguments["text"]?.stringValue ?? "")
    }
    try server.register(
        tool: ToolDefinition(
            name: "add",
            inputSchema: [
                "type": "object", "properties": ["a": ["type": "number"], "b": ["type": "number"]],
                "required": ["a", "b"],
            ],
            outputSchema: ["type": "object", "properties": ["sum": ["type": "number"]], "required": ["sum"]])
    ) { arguments, _ in
        let sum = (arguments["a"]?.doubleValue ?? 0) + (arguments["b"]?.doubleValue ?? 0)
        return .structured(["sum": JSONValue(sum)])
    }
    try server.register(tool: ToolDefinition(name: "fail")) { _, _ in throw ToolError("the disk is full") }
    try server.register(tool: ToolDefinition(name: "crash")) { _, _ in throw Boom() }
    try server.register(
        tool: ToolDefinition(name: "bad_output", outputSchema: ["type": "object", "required": ["sum"]])
    ) { _, _ in .structured(["total": 1]) }
    try server.register(tool: ToolDefinition(name: "wait")) { _, context in
        started.increment()
        context.progress(1, total: 2, message: "started")
        await gate.wait()
        try Task.checkCancellation()
        context.progress(2, total: 2)
        return .text("released")
    }
    try server.register(tool: ToolDefinition(name: "hang")) { _, _ in
        started.increment()
        try await Task.sleep(for: .seconds(60))
        return .text("never")
    }
    try server.register(tool: ToolDefinition(name: "chatty")) { _, context in
        context.log(.debug, "fine detail")
        context.log(.warning, ["problem": "something"], logger: "fixture")
        context.progress(1)
        context.progress(1)
        context.progress(3)
        return .text("ok")
    }
    try server.register(tool: ToolDefinition(name: "greet")) { _, context in
        let answer = try await context.elicit(
            "user_name", message: "What is your name?",
            schema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]])
        guard answer.action == .accept, let name = answer.content?["name"]?.stringValue else {
            return .text("Hello, stranger")
        }
        return .text("Hello, \(name)")
    }
    try server.register(tool: ToolDefinition(name: "gather")) { _, context in
        let answers = try await context.input([
            "who": .elicit(ElicitRequest(message: "Name?", requestedSchema: ["type": "object", "properties": [:]])),
            "capital": .sample(SamplingRequest(prompt: "Capital of France?", maxTokens: 20)),
            "workspace": .roots,
        ])
        guard case .elicit(let who) = answers["who"], case .sample(let capital) = answers["capital"],
            case .roots(let roots) = answers["workspace"]
        else { return .error("incomplete") }
        return .text("\(who.content?["name"]?.stringValue ?? "?")|\(capital.text ?? "?")|\(roots.count)")
    }
    try server.register(tool: ToolDefinition(name: "two_rounds")) { _, context in
        started.increment()
        let first = try await context.elicit("name", message: "Name?", schema: ["type": "object", "properties": [:]])
        let second = try await context.elicit("color", message: "Color?", schema: ["type": "object", "properties": [:]])
        return .text("\(first.content?["name"]?.stringValue ?? "?") likes \(second.content?["color"]?.stringValue ?? "?")")
    }
    try server.register(tool: ToolDefinition(name: "swallow")) { _, context in
        // A handler that wrongly catches the signal that ends a run.
        _ = try? await context.elicit("x", message: "X?", schema: ["type": "object", "properties": [:]])
        return .text("must be discarded")
    }
    try server.register(tool: ToolDefinition(name: "huge")) { _, _ in
        .text(String(repeating: "x", count: 100_000))
    }

    try server.register(
        resource: ResourceDefinition(uri: "test://static", name: "static", title: "Static", mimeType: "text/plain")
    ) { request, _ in
        [.text(uri: request.uri, mimeType: "text/plain", text: "static contents")]
    }
    try server.register(
        resourceTemplate: ResourceTemplateDefinition(uriTemplate: "test://items/{id}", name: "item"),
        complete: { request, _ in
            CompletionResult(values: ["1", "2", "30"].filter { $0.hasPrefix(request.value) })
        }
    ) { request, _ in
        [.blob(uri: request.uri, mimeType: "application/octet-stream", bytes: Array((request.variables["id"] ?? "").utf8))]
    }
    try server.register(
        prompt: PromptDefinition(
            name: "summarize", description: "Summarizes a topic.",
            arguments: [PromptArgument(name: "topic", required: true), PromptArgument(name: "tone")]),
        complete: { request, _ in
            CompletionResult(values: ["swift", "swiftui", "rust"].filter { $0.hasPrefix(request.value) }, total: 3)
        }
    ) { arguments, _ in
        PromptResult(description: "A summary", messages: [.user("Summarize \(arguments["topic"] ?? "")")])
    }
    try server.register(prompt: PromptDefinition(name: "ask")) { _, context in
        let answer = try await context.elicit("subject", message: "About what?", schema: ["type": "object", "properties": [:]])
        return PromptResult(messages: [.user("Tell me about \(answer.content?["subject"]?.stringValue ?? "?")")])
    }
    return server
}

extension JSONValue {
    var result: JSONValue? { self["result"] }
    var errorCode: Int? { self["error"]?["code"]?.intValue }
    var firstText: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}

func elicited(_ content: JSONObject) -> JSONValue {
    ["action": "accept", "content": .object(content)]
}
