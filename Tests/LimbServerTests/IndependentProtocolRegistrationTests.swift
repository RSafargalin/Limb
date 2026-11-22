import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var text: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}

private let serverInfoKey = "io.modelcontextprotocol/serverInfo"

/// Custom methods, registration errors, and what `2026-07-28` adds to every result: `resultType`,
/// cache hints and the server's identity.
@Suite struct IndependentProtocolRegistrationTests {
    // MARK: Custom methods

    @Test(arguments: IndependentProtocolRevision.allCases)
    func customMethodsAreServedInEveryRevision(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        try server.register(method: "acme/echo") { params, context in
            ["params": .object(params), "method": .string(context.method), "version": .string(context.protocolVersion.rawValue), "list": [1, "two", nil]]
        }
        try server.register(method: "acme/empty") { _, _ in [:] }
        try server.register(method: "acme/meta") { _, _ in ["value": 1, "_meta": ["com.example/trace": "t-1", "progress": 0.5]] }
        try server.register(method: "acme/fails") { _, _ in throw MCPError(code: 12345, message: "custom failure", data: "details") }
        let client = try await IndependentProtocol.client(server, revision)

        let echoed = try #require(try await client.request("acme/echo", ["a": 1, "b": ["c": [true, nil]]])["result"])
        #expect(echoed["method"] == "acme/echo")
        #expect(echoed["version"] == .string(revision.rawValue))
        #expect(echoed["list"] == [1, "two", nil])
        #expect(echoed["params"]?["a"] == 1 && echoed["params"]?["b"] == ["c": [true, nil]])
        let added = Set(echoed.objectValue?.map(\.key) ?? []).subtracting(["params", "method", "version", "list"])
        #expect(added == (revision.isModern ? ["resultType", "_meta"] : []), "\(revision.rawValue) added \(added.sorted())")
        if revision.isModern {
            #expect(echoed["resultType"] == "complete")
            #expect(echoed["_meta"]?[serverInfoKey]?["name"] == "rich")
        }

        let empty = try #require(try await client.request("acme/empty")["result"])
        #expect(Set(empty.objectValue?.map(\.key) ?? []) == (revision.isModern ? ["resultType", "_meta"] : []))

        // The handler's own `_meta` is kept, next to the server's identity where the revision has it.
        let meta = try #require(try await client.request("acme/meta")["result"])
        #expect(meta["value"] == 1)
        #expect(meta["_meta"]?["com.example/trace"] == "t-1")
        #expect(meta["_meta"]?["progress"] == 0.5)
        #expect((meta["_meta"]?[serverInfoKey] != nil) == revision.isModern)

        let failed = try await client.request("acme/fails")
        #expect(failed.code == 12345 && failed["error"]?["message"] == "custom failure" && failed["error"]?["data"] == "details")
    }

    /// A result object has one `resultType` (JSON objects with duplicate names are not
    /// interoperable, RFC 8259 §4, and Limb's own parser refuses them). A custom handler may well
    /// return the member itself: "Extensions MAY add additional ResultType values"
    /// (`2026-07-28/basic/index.mdx`).
    @Test func aCustomResultThatNamesItsResultTypeIsStillOneObject() async throws {
        let server = Server(name: "custom", version: "1")
        try server.register(method: "acme/typed") { _, _ in ["resultType": "complete", "value": 1] }
        try server.register(method: "acme/extension") { _, _ in ["resultType": "com.example/partial", "value": 2] }
        let peer = IndependentProtocolRawPeer(server)
        for (method, expected) in [("acme/typed", "complete"), ("acme/extension", "com.example/partial")] {
            let frames = await peer.send(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{\#(IndependentProtocol.modernMetaText)}}"#, awaiting: 1)
            let frame = try #require(frames.first)
            let occurrences = frame.components(separatedBy: #""resultType":"#).count - 1
            #expect(occurrences == 1, "resultType appears \(occurrences) times: \(frame)")
            let result = IndependentProtocolRawPeer.foundationObject(frame)?["result"] as? [String: Any]
            #expect(result?["resultType"] as? String == expected, "\(frame)")
        }
    }

    /// "Protocol methods cannot be overridden" (doc comment of `register(method:)`): every request
    /// method of every revision Limb speaks.
    @Test func protocolMethodsCannotBeRegistered() async throws {
        // The `ClientRequest` unions of the four `schema.ts` files.
        let protocolMethods = [
            "initialize", "ping", "server/discover", "tools/list", "tools/call", "resources/list", "resources/templates/list", "resources/read",
            "resources/subscribe", "resources/unsubscribe", "prompts/list", "prompts/get", "completion/complete", "logging/setLevel",
            "subscriptions/listen",
        ]
        let server = try IndependentProtocolRich.server()
        for method in protocolMethods {
            let error = #expect(throws: RegistrationError.self, "\(method) was overridden") {
                try server.register(method: method) { _, _ in ["hijacked": true] }
            }
            #expect(error?.description.contains(method) == true, "\(String(describing: error))")
        }
        // And nothing was hijacked.
        let client = TestClient(server)
        #expect(try await client.request("tools/list")["result"]?["hijacked"] == nil)
        #expect(try await client.request("server/discover")["result"]?["supportedVersions"] != nil)
    }

    /// Any other name is the user's to define, and is matched exactly.
    @Test func customMethodNamesAreExactStrings() async throws {
        let names = ["acme/sum", "x", "Tools/List", "tools/list/extra", "tools", "a b", "метод/один", "com.example/do-it", "tasks/get", "roots/list", "0"]
        let server = Server(name: "custom", version: "1")
        for name in names { try server.register(method: name) { _, _ in ["name": .string(name)] } }
        let client = TestClient(server)
        for name in names {
            #expect(try await client.request(name)["result"]?["name"] == .string(name), "\(name)")
        }
        for near in ["acme/Sum", "acme/sum ", " acme/sum", "acme", "acme/sum/", "X"] {
            #expect(try await client.request(near).code == -32601, "\(near)")
        }
        // A custom method is no more reachable without a version than a built-in one.
        let bare = TestClient(server, modern: false)
        #expect(try await bare.request("acme/sum").code == -32602)
    }

    // MARK: Registration errors

    /// "Its schemas are compiled now, so a schema Limb cannot enforce is an error here rather
    /// than an unchecked call later" (doc comment of `register(tool:)`).
    @Test func invalidToolSchemasAreRefusedAtRegistration() throws {
        let badInput: [(String, JSONObject)] = [
            ("no type", [:]), ("root is not an object", ["type": "array"]), ("root is a string", ["type": "string"]),
            ("root type is a list", ["type": ["object", "null"]]), ("unknown type", ["type": "object", "properties": ["a": ["type": "text"]]]),
            ("type is a number", ["type": "object", "properties": ["a": ["type": 5]]]),
            ("properties is not an object", ["type": "object", "properties": ["a", "b"]]),
            ("required is not a list", ["type": "object", "required": "a"]),
            ("a property schema is a string", ["type": "object", "properties": ["a": "string"]]),
            ("dangling reference", ["type": "object", "properties": ["a": ["$ref": "#/$defs/missing"]]]),
            ("remote reference", ["type": "object", "properties": ["a": ["$ref": "https://example.com/schema.json"]]]),
            ("unsupported dialect", ["$schema": "http://json-schema.org/draft-03/schema#", "type": "object"]),
            ("enum is not a list", ["type": "object", "properties": ["a": ["enum": "x"]]]),
            ("negative length", ["type": "object", "properties": ["a": ["type": "string", "minLength": -1]]]),
            ("bad pattern", ["type": "object", "properties": ["a": ["type": "string", "pattern": "("]]]),
        ]
        for (label, schema) in badInput {
            let server = Server(name: "schemas", version: "1")
            let error = #expect(throws: RegistrationError.self, "input schema accepted: \(label)") {
                try server.register(tool: ToolDefinition(name: "probe", inputSchema: schema)) { _, _ in .text("") }
            }
            #expect(error?.description.contains("probe") == true, "\(label): the error does not name the tool: \(String(describing: error))")
        }
        let badOutput: [(String, JSONObject)] = [
            ("unknown type", ["type": "objekt"]), ("dangling reference", ["$ref": "#/$defs/missing"]),
            ("unsupported dialect", ["$schema": "http://json-schema.org/draft-03/schema#"]), ("items is a string", ["type": "array", "items": "string"]),
        ]
        for (label, schema) in badOutput {
            let server = Server(name: "schemas", version: "1")
            let error = #expect(throws: RegistrationError.self, "output schema accepted: \(label)") {
                try server.register(tool: ToolDefinition(name: "probe", outputSchema: schema)) { _, _ in .text("") }
            }
            #expect(error?.description.contains("probe") == true, "\(label): \(String(describing: error))")
        }
        // The schemas the specification itself uses as examples are accepted.
        let good: [JSONObject] = [
            ["type": "object"], ["type": "object", "properties": [:]], ["type": "object", "additionalProperties": false],
            ["type": "object", "properties": ["location": ["type": "string", "description": "City name or zip code"]], "required": ["location"]],
            ["$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "properties": ["name": ["type": "string"], "age": ["type": "integer", "minimum": 0]], "required": ["name"]],
            ["$schema": "http://json-schema.org/draft-07/schema#", "type": "object", "properties": ["name": ["type": "string"]]],
            ["type": "object", "$defs": ["point": ["type": "object", "properties": ["x": ["type": "number"]]]], "properties": ["p": ["$ref": "#/$defs/point"]]],
        ]
        for (index, schema) in good.enumerated() {
            let server = Server(name: "schemas", version: "1")
            #expect(throws: Never.self, "\(JSONValue.object(schema))") {
                try server.register(tool: ToolDefinition(name: "good_\(index)", inputSchema: schema, outputSchema: schema)) { _, _ in .text("") }
            }
        }
    }

    /// A refused registration leaves the server exactly as it was: same listings, same handlers,
    /// and no `list_changed` for a change that did not happen.
    @Test func aRefusedRegistrationChangesNothing() async throws {
        let server = try IndependentProtocolRich.server()
        let client = try await IndependentProtocol.client(server, .r2025_11_25)
        var before: [String: JSONValue] = [:]
        for method in ["tools/list", "resources/list", "resources/templates/list", "prompts/list"] {
            before[method] = try await client.request(method)["result"]
        }
        client.clearReceived()

        let duplicateTool = #expect(throws: RegistrationError.self) {
            try server.register(tool: ToolDefinition(name: "plain", description: "impostor")) { _, _ in .text("impostor") }
        }
        #expect(duplicateTool?.description.contains("plain") == true)
        let duplicatePrompt = #expect(throws: RegistrationError.self) {
            try server.register(prompt: PromptDefinition(name: "bare", description: "impostor")) { _, _ in PromptResult(messages: [.user("impostor")]) }
        }
        #expect(duplicatePrompt?.description.contains("bare") == true)
        #expect(throws: RegistrationError.self) {
            try server.register(resource: ResourceDefinition(uri: "rich://static", name: "impostor")) { _, _ in [] }
        }
        #expect(throws: RegistrationError.self) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "rich://items/{id}", name: "impostor")) { _, _ in [] }
        }
        #expect(throws: RegistrationError.self) { try server.register(tool: ToolDefinition(name: "bad name")) { _, _ in .text("") } }
        #expect(throws: RegistrationError.self) { try server.register(tool: ToolDefinition(name: "bad_schema", inputSchema: ["type": "array"])) { _, _ in .text("") } }
        #expect(throws: RegistrationError.self) {
            try server.register(tool: ToolDefinition(name: "bad_output", outputSchema: ["type": "nope"])) { _, _ in .text("") }
        }
        #expect(throws: RegistrationError.self) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "rich://{?query}", name: "bad")) { _, _ in [] }
        }

        #expect(try await IndependentProtocol.drain(client).isEmpty, "a notification for a registration that failed")
        for (method, listing) in before {
            #expect(try await client.request(method)["result"] == listing, "\(method) changed")
        }
        #expect(try await client.request("tools/call", ["name": "plain"]).text == "plain result")
        #expect(try await client.request("tools/call", ["name": "bad_schema"]).code == -32602)
        #expect(try await client.request("tools/call", ["name": "bad_output"]).code == -32602)
    }

    // MARK: Cache hints (2026-07-28)

    /// "Servers MUST include caching hints on results with resultType "complete" returned by":
    /// `server/discover`, the four listings and `resources/read` (`server/utilities/caching.mdx`).
    /// The other results are not `CacheableResult`s and carry none.
    @Test func cacheHintsAreOnCacheableResultsOnly() async throws {
        let server = try IndependentProtocolRich.server {
            $0.listCache = CachePolicy(ttlMilliseconds: 300_000, scope: .private)
            $0.resourceCache = CachePolicy(ttlMilliseconds: 1_500, scope: .public)
        }
        try server.register(method: "acme/custom") { _, _ in ["v": 1] }
        let client = TestClient(server)
        for method in ["server/discover", "tools/list", "resources/list", "resources/templates/list", "prompts/list"] {
            let result = try #require(try await client.request(method)["result"])
            #expect(result["ttlMs"] == 300_000, "\(method)")
            #expect(result["cacheScope"] == "private", "\(method)")
        }
        for uri in ["rich://static", "rich://items/9"] {
            let result = try #require(try await client.request("resources/read", ["uri": .string(uri)])["result"])
            #expect(result["ttlMs"] == 1_500 && result["cacheScope"] == "public", "\(uri): \(result)")
        }
        for (method, params) in [
            ("tools/call", ["name": "plain"]), ("tools/call", ["name": "tool_error"]), ("prompts/get", ["name": "bare"]),
            ("completion/complete", ["ref": ["type": "ref/prompt", "name": "rich_prompt"], "argument": ["name": "topic", "value": ""]]),
            ("acme/custom", [:]),
        ] as [(String, JSONObject)] {
            let result = try #require(try await client.request(method, params)["result"], "\(method)")
            #expect(result["ttlMs"] == nil && result["cacheScope"] == nil, "\(method) is not cacheable: \(result)")
        }
    }

    /// Defaults: "0 means always re-fetch"; listings are `public`, reads `private` (doc comments
    /// of `ServerConfiguration.listCache` / `.resourceCache`; caching.mdx, "Choosing a Cache Scope").
    @Test func defaultCacheHints() async throws {
        let client = TestClient(try IndependentProtocolRich.server())
        for method in ["server/discover", "tools/list", "resources/list", "resources/templates/list", "prompts/list"] {
            let result = try #require(try await client.request(method)["result"])
            #expect(result["ttlMs"] == 0 && result["cacheScope"] == "public", "\(method): \(result)")
        }
        let read = try #require(try await client.request("resources/read", ["uri": "rich://static"])["result"])
        #expect(read["ttlMs"] == 0 && read["cacheScope"] == "private")
    }

    /// A resource or a template can state its own policy; the others keep the default.
    @Test func aResourceCanOverrideTheCachePolicy() async throws {
        let server = Server(name: "cache", version: "1") { $0.resourceCache = CachePolicy(ttlMilliseconds: 10, scope: .private) }
        let reader: ResourceReader = { request, _ in [.text(uri: request.uri, text: "x")] }
        try server.register(resource: ResourceDefinition(uri: "c://default", name: "d"), read: reader)
        try server.register(resource: ResourceDefinition(uri: "c://long", name: "l"), cache: CachePolicy(ttlMilliseconds: 86_400_000, scope: .public), read: reader)
        try server.register(resource: ResourceDefinition(uri: "c://never", name: "n"), cache: CachePolicy(ttlMilliseconds: 0, scope: .private), read: reader)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "c://t/{x}", name: "t"), cache: CachePolicy(ttlMilliseconds: 7, scope: .public), read: reader)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "c://u/{x}", name: "u"), read: reader)
        let client = TestClient(server)
        for (uri, ttl, scope) in [
            ("c://default", 10, "private"), ("c://long", 86_400_000, "public"), ("c://never", 0, "private"), ("c://t/1", 7, "public"),
            ("c://u/1", 10, "private"), ("c://default", 10, "private"),
        ] {
            let result = try #require(try await client.request("resources/read", ["uri": .string(uri)])["result"])
            #expect(result["ttlMs"] == JSONValue(ttl) && result["cacheScope"] == .string(scope), "\(uri): \(result)")
        }
    }

    /// "Servers MUST provide a ttlMs value that is >= 0" (caching.mdx); the schema types it as an
    /// integer with `minimum: 0`. Whatever the configuration holds, a negative value never
    /// reaches the wire.
    @Test func ttlIsNeverNegativeOnTheWire() async throws {
        // Through the initializer…
        var viaInit = CachePolicy(ttlMilliseconds: -1, scope: .public)
        // …and through the public property, which is how a policy is adjusted after the fact.
        var viaProperty = CachePolicy(ttlMilliseconds: 5, scope: .private)
        viaProperty.ttlMilliseconds = -5_000
        viaInit.scope = .public
        for (label, policy) in [("initializer", viaInit), ("property", viaProperty)] {
            let server = Server(name: "cache", version: "1") {
                $0.listCache = policy
                $0.resourceCache = policy
            }
            try server.register(tool: ToolDefinition(name: "t")) { _, _ in .text("") }
            try server.register(resource: ResourceDefinition(uri: "c://r", name: "r"), cache: policy) { request, _ in [.text(uri: request.uri, text: "")] }
            let client = TestClient(server)
            for (method, params) in [("server/discover", [:]), ("tools/list", [:]), ("resources/list", [:]), ("resources/read", ["uri": "c://r"])] as [(String, JSONObject)] {
                let response = try await client.request(method, params)
                let ttl = try #require(response["result"]?["ttlMs"]?.intValue, "\(method): \(response)")
                #expect(ttl >= 0, "\(label): \(method) sent ttlMs \(ttl)")
                let violations = IndependentProtocol.responseViolations(response, to: method, in: .r2026_07_28)
                #expect(violations.isEmpty, "\(label) \(method): \(violations)")
            }
        }
    }

    /// "Servers MUST apply the same cacheScope to all response pages for a given list request";
    /// each page "carries its own ttlMs value" (caching.mdx, "Interaction with Pagination").
    @Test func everyPageCarriesTheHints() async throws {
        let server = Server(name: "pages", version: "1") {
            $0.pageSize = 2
            $0.listCache = CachePolicy(ttlMilliseconds: 60_000, scope: .private)
        }
        for index in 0..<5 { try server.register(tool: ToolDefinition(name: "t\(index)")) { _, _ in .text("") } }
        let client = TestClient(server)
        var cursor: JSONValue?
        var pages = 0
        repeat {
            let response = try await client.request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            let result = try #require(response["result"])
            #expect(result["ttlMs"] == 60_000 && result["cacheScope"] == "private", "page \(pages): \(result)")
            #expect(result["resultType"] == "complete")
            #expect(result["_meta"]?[serverInfoKey]?["name"] == "pages")
            #expect(IndependentProtocol.responseViolations(response, to: "tools/list", in: .r2026_07_28).isEmpty)
            cursor = result["nextCursor"]
            pages += 1
        } while cursor != nil && pages < 10
        #expect(pages == 3)
    }

    /// "Interim results with resultType "input_required" … are not cacheable and carry no caching
    /// hints" (caching.mdx) — even from `resources/read`, whose complete results do.
    @Test func inputRequiredResultsCarryNoCacheHints() async throws {
        let server = Server(name: "cache", version: "1") { $0.resourceCache = CachePolicy(ttlMilliseconds: 9_000, scope: .public) }
        try server.register(resource: ResourceDefinition(uri: "c://asks", name: "asks")) { request, context in
            let answer = try await context.elicit("who", message: "Who is reading?", schema: ["type": "object", "properties": ["name": ["type": "string"]]])
            return [.text(uri: request.uri, text: "for \(answer.content?["name"]?.stringValue ?? "nobody")")]
        }
        let client = TestClient(server, capabilities: ["elicitation": [:]])
        let interim = try await client.request("resources/read", ["uri": "c://asks"])
        let result = try #require(interim["result"], "\(interim)")
        #expect(result["resultType"] == "input_required")
        #expect(result["ttlMs"] == nil && result["cacheScope"] == nil, "\(result)")
        #expect(result["_meta"]?[serverInfoKey]?["name"] == "cache")
        let violations = IndependentProtocolSchema.r2026_07_28.violations(in: result, as: "InputRequiredResult")
        #expect(violations.isEmpty, "\(violations)")
        // The retry completes, and the complete result has its hints.
        let done = try await client.request(
            "resources/read",
            ["uri": "c://asks", "requestState": result["requestState"] ?? nil, "inputResponses": ["who": ["action": "accept", "content": ["name": "Ada"]]]])
        #expect(done["result"]?["contents"]?[0]?["text"] == "for Ada", "\(done)")
        #expect(done["result"]?["ttlMs"] == 9_000 && done["result"]?["cacheScope"] == "public")
    }

    // MARK: The server's identity in results (2026-07-28)

    /// "Servers SHOULD include … io.modelcontextprotocol/serverInfo in every result's _meta"
    /// (`basic/index.mdx`, "Per-response protocol fields"): the configured `Implementation`, on
    /// results of every kind, next to whatever `_meta` the handler set itself.
    @Test func everyModernResultIdentifiesTheServer() async throws {
        let server = try IndependentProtocolRich.server()
        try server.register(method: "acme/custom") { _, _ in ["v": 1] }
        let client = TestClient(server)
        var calls = IndependentProtocolRich.calls
        calls += [("server/discover", [:]), ("acme/custom", [:]), ("tools/call", ["name": "strict", "arguments": [:]])]
        let expected: JSONValue = [
            "name": "rich", "title": "Rich Server", "version": "9.9.9", "description": "Sets every optional field.",
            "websiteUrl": "https://example.com/rich",
            "icons": [["src": "https://example.com/icon.png", "mimeType": "image/png", "sizes": ["48x48", "96x96"], "theme": "dark"]],
        ]
        for (method, params) in calls {
            let result = try #require(try await client.request(method, params)["result"], "\(method)")
            #expect(result["_meta"]?[serverInfoKey] == expected, "\(method) \(JSONValue.object(params)): \(result["_meta"] ?? .null)")
            #expect(result["resultType"] == "complete", "\(method)")
        }
        // The tool's own metadata is still there.
        let everything = try #require(try await client.request("tools/call", ["name": "everything", "arguments": ["count": 1]])["result"])
        #expect(everything["_meta"]?["com.example/trace"] == "abc")
    }

    /// A minimal identity has only what it was given: no empty `title`, `icons` or `description`.
    @Test func aMinimalIdentityHasNoEmptyMembers() async throws {
        let server = Server(name: "minimal", version: "0.0.1")
        try server.register(tool: ToolDefinition(name: "t")) { _, _ in .text("") }
        let modern = try #require(try await TestClient(server).request("tools/list")["result"]?["_meta"]?[serverInfoKey])
        #expect(modern == ["name": "minimal", "version": "0.0.1"])
        let legacy = try #require(try await TestClient(server, modern: false).initialize()["result"])
        #expect(legacy["serverInfo"] == ["name": "minimal", "version": "0.0.1"])
        #expect(legacy["instructions"] == nil)
        let discovered = try #require(try await TestClient(server).request("server/discover")["result"])
        #expect(discovered["instructions"] == nil)
    }
}
