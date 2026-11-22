import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

// Shared by the IndependentProtocol* test files. Everything here is derived from the MCP
// specification (prose and schema of each revision), never from Limb's `RevisionProfile`.

// MARK: - Revisions

/// The four revisions Limb claims, oldest first, as the specification names them.
enum IndependentProtocolRevision: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case r2025_03_26 = "2025-03-26"
    case r2025_06_18 = "2025-06-18"
    case r2025_11_25 = "2025-11-25"
    case r2026_07_28 = "2026-07-28"

    var testDescription: String { rawValue }
    var version: ProtocolVersion { ProtocolVersion(rawValue: rawValue) }
    /// `2026-07-28` conveys version and capabilities per request; earlier revisions use `initialize`.
    var isModern: Bool { self == .r2026_07_28 }
    static let legacy: [IndependentProtocolRevision] = [.r2025_03_26, .r2025_06_18, .r2025_11_25]

    /// Whether this revision is `other` or later. Dated names order lexically.
    func isAtLeast(_ other: IndependentProtocolRevision) -> Bool { rawValue >= other.rawValue }

    var schema: IndependentProtocolSchema {
        switch self {
        case .r2025_03_26: IndependentProtocolSchema.r2025_03_26
        case .r2025_06_18: IndependentProtocolSchema.r2025_06_18
        case .r2025_11_25: IndependentProtocolSchema.r2025_11_25
        case .r2026_07_28: IndependentProtocolSchema.r2026_07_28
        }
    }

    /// The schema definition of the result of `method` in this revision.
    func resultDefinition(for method: String) -> String? {
        switch method {
        case "initialize": isModern ? nil : "InitializeResult"
        case "server/discover": isModern ? "DiscoverResult" : nil
        case "ping", "logging/setLevel", "resources/subscribe", "resources/unsubscribe": isModern ? nil : "EmptyResult"
        case "tools/list": "ListToolsResult"
        case "tools/call": "CallToolResult"
        case "resources/list": "ListResourcesResult"
        case "resources/templates/list": "ListResourceTemplatesResult"
        case "resources/read": "ReadResourceResult"
        case "prompts/list": "ListPromptsResult"
        case "prompts/get": "GetPromptResult"
        case "completion/complete": "CompleteResult"
        default: nil
        }
    }
}

/// Free functions of the IndependentProtocol* tests, namespaced so they cannot clash.
enum IndependentProtocol {
    /// The `_meta` a `2026-07-28` request must carry (`basic/index.mdx`, "Per-request protocol fields").
    static let modernMeta: JSONObject = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    /// The same as raw JSON members, for hand-written frames.
    static let modernMetaText =
        #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

    /// A client speaking `revision` to `server`: after the `initialize` handshake for legacy
    /// revisions, with per-request metadata for the modern one.
    static func client(
        _ server: Server, _ revision: IndependentProtocolRevision, capabilities: JSONObject = JSONObject()
    ) async throws -> TestClient {
        if revision.isModern { return TestClient(server, modern: true, capabilities: capabilities) }
        let client = TestClient(server, modern: false)
        let response = try await client.initialize(version: revision.version, capabilities: capabilities)
        try #require(
            response["result"]?["protocolVersion"]?.stringValue == revision.rawValue,
            "initialize did not negotiate \(revision.rawValue): \(response)")
        return client
    }

    /// Sends `frame` and collects everything the server says before it answers a sentinel
    /// request sent right behind it. Responses written by the reader keep arrival order, so for
    /// anything answered without running user code this needs no sleeping: silence shows up as
    /// an empty array.
    static func exchange(_ client: TestClient, _ frame: String) async throws -> [JSONValue] {
        client.send(frame)
        return try await drain(client)
    }

    /// Everything the server sent up to (not including) the answer to a fresh sentinel request.
    static func drain(_ client: TestClient) async throws -> [JSONValue] {
        let marker = "independent-protocol-sentinel-\(UUID().uuidString)"
        // `initialize` without `protocolVersion` needs no session and no metadata, is answered by
        // the reader, and is rejected without touching the connection's state.
        client.send(#"{"jsonrpc":"2.0","id":"\#(marker)","method":"initialize"}"#)
        var seen: [JSONValue] = []
        while true {
            let message = try await client.next()
            if message["id"] == .string(marker) {
                try #require(message["error"] != nil, "the sentinel must not create a session: \(message)")
                return seen
            }
            seen.append(message)
        }
    }

    /// Waits for the responses to `ids`, in whatever order they arrive. (`TestClient.response(to:)`
    /// called for one id after another loses a response that arrives ahead of its turn.) Returns
    /// what arrived before `timeout`; an id that got no response is absent.
    static func responses(
        _ client: TestClient, to ids: [RequestID], timeout: Duration = .seconds(20)
    ) async -> [RequestID: JSONValue] {
        var found: [RequestID: JSONValue] = [:]
        let deadline = ContinuousClock.now + timeout
        while found.count < ids.count, ContinuousClock.now < deadline {
            guard let message = try? await client.next(timeout: deadline - ContinuousClock.now) else { break }
            guard message["method"] == nil else { continue }
            // Matched on the JSON value, bytewise: "1" is not 1, U+00E9 is not e + U+0301.
            if let id = ids.first(where: { $0.json == message["id"] }) { found[id] = message }
        }
        return found
    }

    /// The single message the server sends in reply to `frame`.
    static func reply(
        _ client: TestClient, _ frame: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> JSONValue {
        let replies = try await exchange(client, frame)
        try #require(replies.count == 1, "expected exactly one reply to \(frame), got \(replies)", sourceLocation: sourceLocation)
        return replies[0]
    }

    /// Walks object keys (strings) and array indices (integers).
    static func at(_ value: JSONValue?, _ path: Any...) -> JSONValue? {
        var current = value
        for step in path {
            if let key = step as? String {
                current = current?[key]
            } else if let index = step as? Int {
                current = current?[index]
            } else {
                return nil
            }
        }
        return current
    }

    /// Checks a response message: the JSON-RPC envelope by the rules shared by every revision
    /// (`basic/index.mdx`, "Responses"), then the result against the revision's schema, strictly.
    static func responseViolations(
        _ message: JSONValue, to method: String, in revision: IndependentProtocolRevision
    ) -> [String] {
        var out: [String] = []
        guard let object = message.objectValue else { return ["the response is not an object: \(message)"] }
        if object["jsonrpc"] != "2.0" { out.append("jsonrpc is not \"2.0\"") }
        let keys = Set(object.map(\.key))
        if let result = object["result"] {
            if keys != ["jsonrpc", "id", "result"] { out.append("result response has members \(keys.sorted())") }
            if let definition = revision.resultDefinition(for: method) {
                out += revision.schema.violations(in: result, as: definition)
            } else {
                out.append("\(method) has no result in \(revision.rawValue)")
            }
        } else if let error = object["error"] {
            if keys != ["jsonrpc", "id", "error"] { out.append("error response has members \(keys.sorted())") }
            out += errorObjectViolations(error)
        } else {
            out.append("response has neither result nor error")
        }
        return out
    }

    /// Checks a notification against `definition`. The `2025-03-26` and `2025-06-18` schemas
    /// describe notifications without the JSON-RPC envelope, so `jsonrpc` is checked by hand.
    static func notificationViolations(
        _ message: JSONValue, as definition: String, in revision: IndependentProtocolRevision
    ) -> [String] {
        var out: [String] = []
        guard var object = message.objectValue else { return ["the notification is not an object: \(message)"] }
        if object["jsonrpc"] != "2.0" { out.append("jsonrpc is not \"2.0\"") }
        if object["id"] != nil { out.append("a notification must not have an id") }
        if !revision.isAtLeast(.r2025_11_25) { object.removeValue(forKey: "jsonrpc") }
        return out + revision.schema.violations(in: .object(object), as: definition)
    }

    /// `{ code: integer, message: string, data?: unknown }`, the same in every revision.
    static func errorObjectViolations(_ error: JSONValue) -> [String] {
        var out: [String] = []
        guard let object = error.objectValue else { return ["error is not an object: \(error)"] }
        if object["code"]?.intValue == nil { out.append("error.code is not an integer: \(error)") }
        if object["message"]?.stringValue == nil { out.append("error.message is not a string: \(error)") }
        for (key, _) in object where !["code", "message", "data"].contains(key) { out.append("error has undeclared member \"\(key)\"") }
        return out
    }
}

// MARK: - Schema oracle

/// A small JSON Schema checker for the keywords the specification's generated `schema.json`
/// files use. It deliberately does not use Limb's own validator: the checker must not be the
/// thing checked.
///
/// On top of plain validation it is *strict*: a member that the definition does not declare is a
/// violation, even though the TypeScript interfaces are structurally open. That is what catches
/// a field of a later revision leaking into an earlier one. Members that are open by design
/// (`_meta`, schemas, structured content, error data, experimental capabilities) are exempt.
struct IndependentProtocolSchema: Sendable {
    let name: String
    let definitions: JSONObject

    static let r2025_03_26 = IndependentProtocolSchema(name: "2025-03-26", text: IndependentProtocolSchemaText.r2025_03_26)
    static let r2025_06_18 = IndependentProtocolSchema(name: "2025-06-18", text: IndependentProtocolSchemaText.r2025_06_18)
    static let r2025_11_25 = IndependentProtocolSchema(name: "2025-11-25", text: IndependentProtocolSchemaText.r2025_11_25)
    static let r2026_07_28 = IndependentProtocolSchema(name: "2026-07-28", text: IndependentProtocolSchemaText.r2026_07_28)

    private init(name: String, text: String) {
        self.name = name
        guard let parsed = try? JSON.parse(Array(text.utf8)), let object = parsed.objectValue else {
            fatalError("the embedded \(name) schema does not parse")
        }
        definitions = object
    }

    /// Members whose value is free-form by specification: undeclared keys inside are allowed.
    private static let openMembers: Set<String> = [
        "_meta", "inputSchema", "outputSchema", "structuredContent", "data", "experimental", "extensions",
        "requestedSchema", "arguments",
    ]

    func has(_ definition: String) -> Bool { definitions[definition] != nil }

    /// Violations of `definition` in `value`; empty when it conforms.
    func violations(in value: JSONValue, as definition: String) -> [String] {
        guard let schema = definitions[definition] else { return ["schema \(name) has no definition \(definition)"] }
        var out: [String] = []
        check(value, schema, path: definition, open: false, into: &out)
        return out
    }

    /// Names a schema declares for an object, through `$ref` and `allOf` (an intersection type
    /// declares the members of all its parts).
    private func declaredMembers(_ schema: JSONValue) -> Set<String> {
        guard let schema = schema.objectValue else { return [] }
        var names = Set((schema["properties"]?.objectValue ?? JSONObject()).map(\.key))
        if let reference = schema["$ref"]?.stringValue, let resolved = definitions[String(reference.dropFirst(2))] {
            names.formUnion(declaredMembers(resolved))
        }
        for member in schema["allOf"]?.arrayValue ?? [] { names.formUnion(declaredMembers(member)) }
        return names
    }

    private func check(
        _ value: JSONValue, _ schema: JSONValue, path: String, open: Bool, declaredElsewhere: Set<String> = [],
        into out: inout [String]
    ) {
        guard let schema = schema.objectValue else { return }  // `true` and non-objects constrain nothing
        if let reference = schema["$ref"]?.stringValue {
            let target = String(reference.dropFirst(2))
            guard let resolved = definitions[target] else {
                out.append("\(path): unresolved $ref \(reference)")
                return
            }
            check(value, resolved, path: path, open: open, declaredElsewhere: declaredElsewhere, into: &out)
        }
        if let parts = schema["allOf"]?.arrayValue {
            let together = declaredElsewhere.union(declaredMembers(.object(schema)))
            for part in parts { check(value, part, path: path, open: open, declaredElsewhere: together, into: &out) }
        }
        if let alternatives = schema["anyOf"]?.arrayValue {
            var best: [String]?
            for alternative in alternatives {
                var attempt: [String] = []
                check(value, alternative, path: path, open: open, declaredElsewhere: declaredElsewhere, into: &attempt)
                if attempt.isEmpty {
                    best = []
                    break
                }
                if best == nil || attempt.count < best!.count { best = attempt }
            }
            if let best, !best.isEmpty {
                out.append("\(path): matches no alternative of anyOf; closest: \(best.joined(separator: "; "))")
            }
        }
        if let constant = schema["const"], value != constant { out.append("\(path): expected \(constant), got \(value)") }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            out.append("\(path): \(value) is not one of \(JSONValue.array(allowed))")
        }
        if let type = schema["type"] {
            let names = type.arrayValue?.compactMap(\.stringValue) ?? [type.stringValue ?? ""]
            if !names.contains(where: { Self.value(value, hasType: $0) }) {
                out.append("\(path): expected \(names.joined(separator: "|")), got \(value)")
            }
        }
        switch value {
        case .object(let object):
            for required in schema["required"]?.arrayValue ?? [] {
                if let key = required.stringValue, object[key] == nil { out.append("\(path): missing required \"\(key)\"") }
            }
            let properties = schema["properties"]?.objectValue ?? JSONObject()
            let additional = schema["additionalProperties"]
            for (key, member) in object {
                let memberPath = "\(path).\(key)"
                let memberIsOpen = Self.openMembers.contains(key)
                if let declared = properties[key] {
                    check(member, declared, path: memberPath, open: memberIsOpen, into: &out)
                } else if case .bool(false) = additional {
                    out.append("\(memberPath): not allowed here")
                } else if let additional = additional?.objectValue, !additional.isEmpty {
                    check(member, .object(additional), path: memberPath, open: memberIsOpen, into: &out)
                } else if !properties.isEmpty, !open, !declaredElsewhere.contains(key) {
                    out.append("\(memberPath): not a member of this type in \(name)")
                }
            }
        case .array(let elements):
            if let items = schema["items"] {
                for (index, element) in elements.enumerated() {
                    check(element, items, path: "\(path)[\(index)]", open: false, into: &out)
                }
            }
            if let limit = schema["maxItems"]?.intValue, elements.count > limit {
                out.append("\(path): \(elements.count) items, at most \(limit) allowed")
            }
        case .number(let number):
            if let minimum = schema["minimum"]?.doubleValue, number.doubleValue < minimum {
                out.append("\(path): \(number) is below the minimum \(minimum)")
            }
            if let maximum = schema["maximum"]?.doubleValue, number.doubleValue > maximum {
                out.append("\(path): \(number) is above the maximum \(maximum)")
            }
        case .string(let text):
            if schema["format"] == "byte", Data(base64Encoded: text) == nil {
                out.append("\(path): not valid base64")
            }
        default:
            break
        }
    }

    private static func value(_ value: JSONValue, hasType name: String) -> Bool {
        switch (name, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number):
            return true
        case ("integer", .number(let number)):
            let double = number.doubleValue
            return double.isFinite && double.rounded(.towardZero) == double
        default:
            return false
        }
    }
}

// MARK: - A server that uses every optional field

/// Records what handlers saw, so tests can tell whether user code ran.
final class IndependentProtocolRecorder: Sendable {
    private let state = Mutex<[String]>([])
    func note(_ entry: String) { state.withLock { $0.append(entry) } }
    var entries: [String] { state.withLock { $0 } }
    func count(of entry: String) -> Int { state.withLock { $0.count { $0 == entry } } }
    func clear() { state.withLock { $0 = [] } }
}

struct IndependentProtocolSecretFailure: Error, CustomStringConvertible {
    static let secret = "hunter2-do-not-leak"
    var description: String { "connection to db://admin:\(Self.secret)@10.0.0.1 failed" }
}

enum IndependentProtocolRich {
    static let icon = Icon(src: "https://example.com/icon.png", mimeType: "image/png", sizes: ["48x48", "96x96"], theme: .dark)
    static let annotations = Annotations(audience: [.user, .assistant], priority: 0.5, lastModified: "2025-05-03T14:30:00Z")
    static let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF]
    static let wavBytes: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x00]

    static let linked = ResourceDefinition(
        uri: "rich://linked", name: "linked", title: "Linked", description: "A linked resource.",
        mimeType: "text/plain", annotations: annotations, size: 12, icons: [icon], meta: ["com.example/k": "link"])

    /// All eight levels, least severe first (`server/utilities/logging.mdx`, RFC 5424 order).
    static let levels = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]

    /// A server whose every definition and result sets every optional field the public API has.
    static func server(
        recorder: IndependentProtocolRecorder = IndependentProtocolRecorder(),
        configure: (inout ServerConfiguration) -> Void = { _ in }
    ) throws -> Server {
        var configuration = ServerConfiguration(
            info: Implementation(
                name: "rich", title: "Rich Server", version: "9.9.9", description: "Sets every optional field.",
                websiteURL: "https://example.com/rich", icons: [icon]))
        configuration.instructions = "Read the manual."
        configuration.diagnostics = { _ in }
        configure(&configuration)
        let server = Server(configuration: configuration)

        try server.register(
            tool: ToolDefinition(
                name: "everything", title: "Everything", description: "Returns one block of every kind.",
                inputSchema: [
                    "type": "object",
                    "properties": ["count": ["type": "integer", "minimum": 0], "label": ["type": "string"]],
                    "required": ["count"],
                ],
                outputSchema: ["type": "object", "properties": ["count": ["type": "integer"]], "required": ["count"]],
                annotations: ToolAnnotations(
                    title: "Everything (annotation)", readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                    openWorldHint: false),
                icons: [icon], meta: ["com.example/k": "tool"])
        ) { arguments, _ in
            recorder.note("everything")
            return ToolResult(
                content: [
                    .text("some text", annotations: annotations, meta: ["com.example/k": "text"]),
                    .image(data: Data(pngBytes).base64EncodedString(), mimeType: "image/png", annotations: annotations, meta: ["com.example/k": "image"]),
                    .audio(data: Data(wavBytes).base64EncodedString(), mimeType: "audio/wav", annotations: annotations, meta: ["com.example/k": "audio"]),
                    .resourceLink(linked),
                    .resource(
                        .text(uri: "rich://embedded/text", mimeType: "text/plain", text: "embedded text", meta: ["com.example/k": "contents"]),
                        annotations: annotations, meta: ["com.example/k": "embedded"]),
                    .resource(.blob(uri: "rich://embedded/blob", mimeType: "application/octet-stream", bytes: pngBytes)),
                ],
                structuredContent: ["count": arguments["count"] ?? 0],
                meta: ["com.example/trace": "abc"])
        }
        try server.register(tool: ToolDefinition(name: "plain")) { _, _ in
            recorder.note("plain")
            return .text("plain result")
        }
        try server.register(
            tool: ToolDefinition(
                name: "strict",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "n": ["type": "integer", "minimum": 1, "maximum": 10],
                        "mode": ["type": "string", "enum": ["fast", "slow"]],
                        "tags": ["type": "array", "items": ["type": "string"], "maxItems": 2],
                        "nested": ["type": "object", "properties": ["flag": ["type": "boolean"]], "required": ["flag"]],
                    ],
                    "required": ["n"], "additionalProperties": false,
                ])
        ) { arguments, _ in
            recorder.note("strict")
            return .text("n=\(arguments["n"]?.intValue ?? -1)")
        }
        try server.register(
            tool: ToolDefinition(name: "object_out", outputSchema: ["type": "object", "properties": ["sum": ["type": "number"]], "required": ["sum"]])
        ) { _, _ in .structured(["sum": 3]) }
        try server.register(tool: ToolDefinition(name: "scalar_out")) { _, _ in .structured("just a string") }
        try server.register(tool: ToolDefinition(name: "tool_error")) { _, _ in
            recorder.note("tool_error")
            throw ToolError("the disk is full")
        }
        try server.register(tool: ToolDefinition(name: "secret_failure")) { _, _ in throw IndependentProtocolSecretFailure() }
        try server.register(tool: ToolDefinition(name: "protocol_error")) { _, _ in
            throw MCPError(code: 4242, message: "application failure", data: ["detail": [1, 2, 3]])
        }
        try server.register(tool: ToolDefinition(name: "log_all")) { _, context in
            for level in LoggingLevel.allCases { context.log(level, .string(level.rawValue), logger: "rich") }
            return .text("logged")
        }
        try server.register(tool: ToolDefinition(name: "progress")) { _, context in
            context.progress(1, total: 4, message: "a quarter")
            context.progress(2.5, total: 4)
            context.progress(4)
            return .text("done")
        }

        try server.register(
            resource: ResourceDefinition(
                uri: "rich://static", name: "static", title: "Static", description: "A fixed resource.",
                mimeType: "text/plain", annotations: annotations, size: 15, icons: [icon], meta: ["com.example/k": "resource"])
        ) { request, _ in
            recorder.note("read:\(request.uri)")
            return [
                .text(uri: request.uri, mimeType: "text/plain", text: "static contents", meta: ["com.example/k": "text"]),
                .blob(uri: request.uri + "#raw", mimeType: "application/octet-stream", base64: Data(pngBytes).base64EncodedString(), meta: ["com.example/k": "blob"]),
            ]
        }
        try server.register(
            resourceTemplate: ResourceTemplateDefinition(
                uriTemplate: "rich://items/{id}", name: "item", title: "Item", description: "One item.",
                mimeType: "application/json", annotations: annotations, icons: [icon], meta: ["com.example/k": "template"]),
            complete: { request, _ in
                CompletionResult(values: ["alpha", "beta", "gamma"].filter { $0.hasPrefix(request.value) }, total: 3, hasMore: false)
            }
        ) { request, _ in
            recorder.note("read:\(request.uri)")
            return [.text(uri: request.uri, mimeType: "application/json", text: #"{"id":"\#(request.variables["id"] ?? "")"}"#)]
        }

        try server.register(
            prompt: PromptDefinition(
                name: "rich_prompt", title: "Rich Prompt", description: "A prompt with everything.",
                arguments: [
                    PromptArgument(name: "topic", title: "Topic", description: "What it is about.", required: true),
                    PromptArgument(name: "tone", title: "Tone", description: "How it should sound."),
                ],
                icons: [icon], meta: ["com.example/k": "prompt"]),
            complete: { request, _ in
                CompletionResult(values: ["swift", "swiftui", "rust"].filter { $0.hasPrefix(request.value) })
            }
        ) { arguments, _ in
            recorder.note("prompt:\(arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
            return PromptResult(
                description: "About \(arguments["topic"] ?? "")",
                messages: [
                    .user("Tell me about \(arguments["topic"] ?? "")"),
                    PromptMessage(role: .assistant, content: .image(data: Data(pngBytes).base64EncodedString(), mimeType: "image/png", annotations: annotations)),
                    PromptMessage(role: .user, content: .audio(data: Data(wavBytes).base64EncodedString(), mimeType: "audio/wav")),
                    PromptMessage(role: .user, content: .resource(.text(uri: "rich://embedded/text", mimeType: "text/plain", text: "embedded"), annotations: annotations)),
                    PromptMessage(role: .assistant, content: .resourceLink(linked)),
                ])
        }
        try server.register(prompt: PromptDefinition(name: "bare")) { _, _ in
            recorder.note("prompt:bare")
            return PromptResult(messages: [])
        }
        return server
    }

    /// One well-formed request per method that returns a result, with the parameters it needs.
    static let calls: [(method: String, params: JSONObject)] = [
        ("tools/list", [:]),
        ("tools/call", ["name": "everything", "arguments": ["count": 3]]),
        ("tools/call", ["name": "plain"]),
        ("tools/call", ["name": "object_out"]),
        ("tools/call", ["name": "scalar_out"]),
        ("tools/call", ["name": "tool_error"]),
        ("tools/call", ["name": "strict", "arguments": ["n": 7]]),
        ("resources/list", [:]),
        ("resources/templates/list", [:]),
        ("resources/read", ["uri": "rich://static"]),
        ("resources/read", ["uri": "rich://items/42"]),
        ("prompts/list", [:]),
        ("prompts/get", ["name": "rich_prompt", "arguments": ["topic": "swift", "tone": "dry"]]),
        ("prompts/get", ["name": "bare"]),
        ("completion/complete", ["ref": ["type": "ref/prompt", "name": "rich_prompt"], "argument": ["name": "topic", "value": "sw"]]),
        ("completion/complete", ["ref": ["type": "ref/resource", "uri": "rich://items/{id}"], "argument": ["name": "id", "value": ""]]),
        ("completion/complete", ["ref": ["type": "ref/prompt", "name": "bare"], "argument": ["name": "x", "value": ""]]),
    ]
}

// MARK: - Raw frames

/// A connection whose output is kept as the exact bytes the server wrote, for assertions the
/// parsed view cannot make: the text of a number, one frame per line, no duplicate members.
final class IndependentProtocolRawPeer: Sendable {
    private final class Sink: FrameSink {
        let frames = Mutex<[(frame: [UInt8], key: RequestID?)]>([])
        func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
            frames.withLock { $0.append((frame, key)) }
            return true
        }
        func waitForCapacity() async {}
        func discard(key: RequestID) { frames.withLock { $0.removeAll { $0.key == key } } }
    }

    let connection: Connection
    private let sink = Sink()

    init(_ server: Server) { connection = server.connect(to: sink) }

    /// Frames written so far and not yet taken, as text.
    func take() -> [String] {
        sink.frames.withLock { frames in
            defer { frames = [] }
            return frames.map { String(decoding: $0.frame, as: UTF8.self) }
        }
    }

    /// Delivers `frame` and returns what the server wrote before `receive` returned: everything
    /// the reader answers itself (errors, pings, listings, discovery) is there by then.
    func send(_ frame: String) -> [String] { send(bytes: Array(frame.utf8)) }

    func send(bytes: [UInt8]) -> [String] {
        connection.receive(bytes)
        return take()
    }

    /// Delivers `frame` and waits for `count` frames; for requests answered by a handler.
    func send(_ frame: String, awaiting count: Int, timeout: Duration = .seconds(20)) async -> [String] {
        connection.receive(Array(frame.utf8))
        var collected: [String] = []
        let deadline = ContinuousClock.now + timeout
        while collected.count < count, ContinuousClock.now < deadline {
            collected += take()
            if collected.count < count { try? await Task.sleep(for: .milliseconds(2)) }
        }
        return collected
    }

    /// Delivers `frame` and collects frames up to and including the response whose `id` is
    /// written as `id`; for a request whose handler sends notifications before it answers.
    func send(_ frame: String, untilResponseTo id: String, timeout: Duration = .seconds(20)) async -> [String] {
        connection.receive(Array(frame.utf8))
        var collected: [String] = []
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            collected += take()
            if let last = collected.last, !last.contains(#""method""#), Self.idText(of: last) == id { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return collected
    }

    /// Text of the top-level `id` member exactly as written, or `nil` if the frame has none.
    static func idText(of frame: String) -> String? {
        // Every frame Limb writes starts `{"jsonrpc":"2.0",`; the id, when present, comes next.
        // Not relied upon: the member is located wherever it is at nesting depth 1.
        let bytes = Array(frame.utf8)
        var depth = 0
        var index = 0
        var inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if byte == UInt8(ascii: "\\") { index += 1 } else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                if depth == 1, bytes[index...].starts(with: Array(#""id":"#.utf8)) {
                    var end = index + 5
                    if bytes[end] == UInt8(ascii: "\"") {
                        end += 1
                        while bytes[end] != UInt8(ascii: "\"") { end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1 }
                        end += 1
                    } else {
                        while end < bytes.count, bytes[end] != UInt8(ascii: ","), bytes[end] != UInt8(ascii: "}") { end += 1 }
                    }
                    return String(decoding: bytes[(index + 5)..<end], as: UTF8.self)
                }
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    /// Parses a frame with Foundation, independently of Limb's codec. `nil` if it is not JSON.
    static func foundationObject(_ frame: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
    }
}

// MARK: - Duplicate members

extension IndependentProtocolRawPeer {
    /// Names that occur more than once in one object of `frame`, at any depth. A scanner of its
    /// own, because the parsers at hand either refuse such input (Limb) or silently keep one
    /// member (Foundation). Assumes `frame` is otherwise valid JSON.
    static func duplicateMembers(in frame: String) -> [String] {
        let bytes = Array(frame.utf8)
        var duplicates: [String] = []
        /// One entry per open container: the names seen so far for an object, `nil` for an array.
        var stack: [Set<[UInt8]>?] = []
        var index = 0
        /// In an object, whether the next string is a member name.
        var expectingName = false
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                stack.append([])
                expectingName = true
            case UInt8(ascii: "["):
                stack.append(nil)
                expectingName = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                stack.removeLast()
                expectingName = false
            case UInt8(ascii: ","):
                if let top = stack.last, top != nil { expectingName = true }
            case UInt8(ascii: "\""):
                let start = index + 1
                index += 1
                while bytes[index] != UInt8(ascii: "\"") { index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1 }
                if expectingName, let top = stack.last, var names = top {
                    let name = Array(bytes[start..<index])
                    if !names.insert(name).inserted { duplicates.append(String(decoding: name, as: UTF8.self)) }
                    stack[stack.count - 1] = names
                    expectingName = false
                }
            default:
                break
            }
            index += 1
        }
        return duplicates
    }
}
