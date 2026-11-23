import Limb
import Synchronization

/// Returns the input text without modification.
@Tool(readOnly: true)
struct Echo {
    func call(text: String) -> String { text }
}

enum FixtureError: Error {
    case expectedProtocolVersion
}

private final class FixtureState: Sendable {
    let status = Mutex("ready")
}

private func completions(_ candidates: [String], matching prefix: String) -> CompletionResult {
    let values = candidates.filter { $0.hasPrefix(prefix) }
    return CompletionResult(values: values, total: values.count, hasMore: false)
}

private func runFixture(version: ProtocolVersion) async throws {
    var configuration = ServerConfiguration(info: .init(name: "limb-inspector-fixture", version: "1.0.0"))
    configuration.supportedVersions = [version]
    let server = Server(configuration: configuration)
    let state = FixtureState()
    let statusURI = "limb-fixture://state/status"
    let textMimeType = "text/plain"

    try server.register(Echo())
    try server.register(tool: .init(name: "protocol_version", description: "Returns the revision used for this request.")) { _, context in
        .text(context.protocolVersion.rawValue)
    }
    try server.register(tool: .init(
        name: "update_status", description: "Updates the status resource.",
        inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
    )) { [weak server] arguments, _ in
        let text: String = try arguments.required("text")
        state.status.withLock { $0 = text }
        server?.notifyResourceUpdated(uri: statusURI)
        return .text(text)
    }

    try server.register(resource: .init(uri: statusURI, name: "status", mimeType: textMimeType)) { request, _ in
        let text = state.status.withLock { $0 }
        return [.text(uri: request.uri, mimeType: textMimeType, text: text)]
    }
    try server.register(
        resourceTemplate: .init(uriTemplate: "limb-fixture://items/{name}", name: "item", mimeType: textMimeType),
        complete: { request, _ in completions(["alpha", "alpine", "beta"], matching: request.value) }
    ) { request, _ in
        [.text(uri: request.uri, mimeType: textMimeType, text: "item:\(request.variables["name", default: ""])")]
    }
    try server.register(
        prompt: .init(name: "greet", arguments: [.init(name: "name", required: true)]),
        complete: { request, _ in completions(["Ada", "Alan", "Grace"], matching: request.value) }
    ) { arguments, _ in
        PromptResult(messages: [.user("Hello, \(arguments["name", default: ""])."), .assistant("Ready.")])
    }
    try registerPreferences(on: server)
    try registerSteps(on: server)
    await server.run()
}

guard CommandLine.arguments.count == 2 else { throw FixtureError.expectedProtocolVersion }
let argument = CommandLine.arguments[1]
if argument == "--protocol-versions" {
    for version in ProtocolVersion.all { print(version.rawValue) }
} else if argument == "--codec" {
    print(JSON.codec == .foundation ? "FoundationJSON" : "default")
} else {
    let version = ProtocolVersion(rawValue: argument)
    guard ProtocolVersion.all.contains(version) else { throw FixtureError.expectedProtocolVersion }
    try await runFixture(version: version)
}
