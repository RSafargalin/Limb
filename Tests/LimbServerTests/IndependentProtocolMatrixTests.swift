import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var text: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}

/// The "capability × revision" matrix, built from the specification's changelogs and the
/// `schema.json` of each revision (`docs/specification/<revision>/changelog.mdx`), not from
/// Limb's `RevisionProfile`.
@Suite struct IndependentProtocolMatrixTests {
    // MARK: Wire shapes against the schema of each revision

    /// Every result the server can produce is valid for the revision it is sent under, and
    /// declares no member that revision's schema does not know.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func everyResultConformsToTheSchemaOfItsRevision(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        for (method, params) in IndependentProtocolRich.calls {
            let response = try await client.request(method, params)
            #expect(response["result"] != nil, "\(method) \(JSONValue.object(params)) failed: \(response)")
            let violations = IndependentProtocol.responseViolations(response, to: method, in: revision)
            #expect(violations.isEmpty, "\(revision.rawValue) \(method) \(JSONValue.object(params)): \(violations.joined(separator: "\n"))")
        }
        if revision.isAtLeast(.r2025_11_25) {
            // From 2025-11-25 a failed input validation is a result too (SEP-1303).
            let response = try await client.request("tools/call", ["name": "strict", "arguments": ["n": 0]])
            #expect(response["result"]?["isError"] == true)
            let violations = IndependentProtocol.responseViolations(response, to: "tools/call", in: revision)
            #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        }
    }

    @Test(arguments: IndependentProtocolRevision.legacy)
    func initializeResultConformsToTheSchemaOfItsRevision(_ revision: IndependentProtocolRevision) async throws {
        let client = TestClient(try IndependentProtocolRich.server(), modern: false)
        let response = try await client.initialize(version: revision.version)
        let violations = IndependentProtocol.responseViolations(response, to: "initialize", in: revision)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        for (method, params) in [
            ("ping", [:]), ("logging/setLevel", ["level": "debug"]), ("resources/subscribe", ["uri": "rich://static"]),
            ("resources/unsubscribe", ["uri": "rich://static"]),
        ] as [(String, JSONObject)] {
            let response = try await client.request(method, params)
            // "The receiver MUST respond promptly with an empty response" (basic/utilities/ping.mdx);
            // the other three return EmptyResult in the schema.
            #expect(response["result"] == [:], "\(method) in \(revision.rawValue): \(response)")
            #expect(IndependentProtocol.responseViolations(response, to: method, in: revision).isEmpty, "\(method)")
        }
    }

    @Test func discoverResultConformsToTheSchema() async throws {
        let client = TestClient(try IndependentProtocolRich.server())
        let response = try await client.request("server/discover")
        let violations = IndependentProtocol.responseViolations(response, to: "server/discover", in: .r2026_07_28)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    /// One server, every revision, interleaved: what was encoded for one peer must not be reused
    /// for a peer of another revision (list results are cached per revision). The oracle is the
    /// same request on a server that only ever saw that one revision.
    @Test func oneServerServesEveryRevisionWithoutMixingShapes() async throws {
        var expected: [IndependentProtocolRevision: [String: JSONValue]] = [:]
        for revision in IndependentProtocolRevision.allCases {
            let alone = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
            for (method, params) in IndependentProtocolRich.calls {
                expected[revision, default: [:]]["\(method) \(JSONValue.object(params))"] = try await alone.request(method, params)["result"]
            }
        }
        let shared = try IndependentProtocolRich.server()
        var clients: [(IndependentProtocolRevision, TestClient)] = []
        for revision in IndependentProtocolRevision.allCases.reversed() {
            clients.append((revision, try await IndependentProtocol.client(shared, revision)))
        }
        for round in 0..<3 {
            let order = round % 2 == 0 ? clients : clients.reversed()
            for (method, params) in IndependentProtocolRich.calls {
                for (revision, client) in order {
                    let key = "\(method) \(JSONValue.object(params))"
                    let result = try await client.request(method, params)["result"]
                    #expect(result != nil, "\(revision.rawValue) \(key)")
                    #expect(result == expected[revision]?[key], "round \(round) \(revision.rawValue) \(key)")
                }
            }
        }
    }

    /// Both eras on a single connection, alternating: the shape follows the request, not the
    /// request before it.
    @Test func oneConnectionAlternatesErasWithoutMixingShapes() async throws {
        var expected: [IndependentProtocolRevision: [String: JSONValue]] = [:]
        for revision in IndependentProtocolRevision.allCases {
            let alone = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
            for (method, params) in IndependentProtocolRich.calls {
                expected[revision, default: [:]]["\(method) \(JSONValue.object(params))"] = try await alone.request(method, params)["result"]
            }
        }
        let server = try IndependentProtocolRich.server()
        for legacy in IndependentProtocolRevision.legacy {
            let client = try await IndependentProtocol.client(server, legacy)
            for round in 0..<2 {
                for (method, params) in IndependentProtocolRich.calls {
                    let key = "\(method) \(JSONValue.object(params))"
                    let old = try await client.request(method, params)["result"]
                    #expect(old != nil && old == expected[legacy]?[key], "round \(round) \(legacy.rawValue) \(key)")
                    let new = try await client.request(method, params, meta: IndependentProtocol.modernMeta)["result"]
                    #expect(new != nil && new == expected[.r2026_07_28]?[key], "round \(round) modern on a \(legacy.rawValue) connection, \(key)")
                }
            }
        }
    }

    // MARK: Presence of every field that differs between revisions

    private struct Cell: Sendable {
        let method: String
        let params: JSONObject
        /// Object keys as strings, array indices as integers.
        let path: [JSONValue]
        /// The first revision whose schema declares the member.
        let since: IndependentProtocolRevision
        init(_ method: String, _ params: JSONObject = [:], _ path: [JSONValue], since: IndependentProtocolRevision = .r2025_03_26) {
            self.method = method
            self.params = params
            self.path = path
            self.since = since
        }
    }

    private static let serverInfo = "io.modelcontextprotocol/serverInfo"
    private static let everything: JSONObject = ["name": "everything", "arguments": ["count": 3]]
    private static let richPrompt: JSONObject = ["name": "rich_prompt", "arguments": ["topic": "swift"]]

    /// Each row is one field and the revision that introduced it. Sources: the changelog of the
    /// revision named in `since` and that revision's `schema.ts`.
    private static let cells: [Cell] = [
        // Tool. 2025-06-18: `title` (PR #663), `outputSchema` (PR #371), `_meta` (PR #710).
        // 2025-11-25: `icons` (SEP-973).
        Cell("tools/list", [:], ["tools", 0, "name"]),
        Cell("tools/list", [:], ["tools", 0, "description"]),
        Cell("tools/list", [:], ["tools", 0, "inputSchema", "properties", "count"]),
        Cell("tools/list", [:], ["tools", 0, "annotations", "title"]),
        Cell("tools/list", [:], ["tools", 0, "annotations", "readOnlyHint"]),
        Cell("tools/list", [:], ["tools", 0, "annotations", "destructiveHint"]),
        Cell("tools/list", [:], ["tools", 0, "annotations", "idempotentHint"]),
        Cell("tools/list", [:], ["tools", 0, "annotations", "openWorldHint"]),
        Cell("tools/list", [:], ["tools", 0, "title"], since: .r2025_06_18),
        Cell("tools/list", [:], ["tools", 0, "outputSchema"], since: .r2025_06_18),
        Cell("tools/list", [:], ["tools", 0, "_meta", "com.example/k"], since: .r2025_06_18),
        Cell("tools/list", [:], ["tools", 0, "icons", 0, "src"], since: .r2025_11_25),
        Cell("tools/list", [:], ["tools", 0, "icons", 0, "theme"], since: .r2025_11_25),
        // Resource.
        Cell("resources/list", [:], ["resources", 0, "uri"]),
        Cell("resources/list", [:], ["resources", 0, "name"]),
        Cell("resources/list", [:], ["resources", 0, "description"]),
        Cell("resources/list", [:], ["resources", 0, "mimeType"]),
        Cell("resources/list", [:], ["resources", 0, "size"]),
        Cell("resources/list", [:], ["resources", 0, "annotations", "audience"]),
        Cell("resources/list", [:], ["resources", 0, "annotations", "priority"]),
        Cell("resources/list", [:], ["resources", 0, "annotations", "lastModified"], since: .r2025_06_18),
        Cell("resources/list", [:], ["resources", 0, "title"], since: .r2025_06_18),
        Cell("resources/list", [:], ["resources", 0, "_meta", "com.example/k"], since: .r2025_06_18),
        Cell("resources/list", [:], ["resources", 0, "icons", 0, "src"], since: .r2025_11_25),
        // ResourceTemplate.
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "uriTemplate"]),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "name"]),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "description"]),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "mimeType"]),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "annotations", "priority"]),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "annotations", "lastModified"], since: .r2025_06_18),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "title"], since: .r2025_06_18),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "_meta", "com.example/k"], since: .r2025_06_18),
        Cell("resources/templates/list", [:], ["resourceTemplates", 0, "icons", 0, "src"], since: .r2025_11_25),
        // Prompt and PromptArgument.
        Cell("prompts/list", [:], ["prompts", 0, "name"]),
        Cell("prompts/list", [:], ["prompts", 0, "description"]),
        Cell("prompts/list", [:], ["prompts", 0, "arguments", 0, "name"]),
        Cell("prompts/list", [:], ["prompts", 0, "arguments", 0, "description"]),
        Cell("prompts/list", [:], ["prompts", 0, "arguments", 0, "required"]),
        Cell("prompts/list", [:], ["prompts", 0, "title"], since: .r2025_06_18),
        Cell("prompts/list", [:], ["prompts", 0, "arguments", 0, "title"], since: .r2025_06_18),
        Cell("prompts/list", [:], ["prompts", 0, "_meta", "com.example/k"], since: .r2025_06_18),
        Cell("prompts/list", [:], ["prompts", 0, "icons", 0, "src"], since: .r2025_11_25),
        // CallToolResult and content blocks. `_meta` on a result exists in every revision;
        // on content blocks and resource contents from 2025-06-18 (PR #710).
        Cell("tools/call", everything, ["content", 0, "text"]),
        Cell("tools/call", everything, ["content", 0, "annotations", "audience"]),
        Cell("tools/call", everything, ["content", 0, "annotations", "priority"]),
        Cell("tools/call", everything, ["content", 0, "annotations", "lastModified"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 0, "_meta", "com.example/k"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 1, "data"]),
        Cell("tools/call", everything, ["content", 1, "mimeType"]),
        Cell("tools/call", everything, ["content", 1, "_meta"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 2, "data"]),
        Cell("tools/call", everything, ["content", 2, "_meta"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 3, "uri"], since: .r2025_06_18),  // resource_link (PR #603)
        Cell("tools/call", everything, ["content", 3, "name"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 3, "size"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 3, "icons"], since: .r2025_11_25),
        Cell("tools/call", everything, ["content", 4, "resource", "text"]),
        Cell("tools/call", everything, ["content", 4, "resource", "mimeType"]),
        Cell("tools/call", everything, ["content", 4, "annotations", "audience"]),
        Cell("tools/call", everything, ["content", 4, "_meta"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 4, "resource", "_meta"], since: .r2025_06_18),
        Cell("tools/call", everything, ["content", 5, "resource", "blob"]),
        Cell("tools/call", everything, ["structuredContent", "count"], since: .r2025_06_18),
        Cell("tools/call", everything, ["_meta", "com.example/trace"]),
        // ReadResourceResult.
        Cell("resources/read", ["uri": "rich://static"], ["contents", 0, "uri"]),
        Cell("resources/read", ["uri": "rich://static"], ["contents", 0, "mimeType"]),
        Cell("resources/read", ["uri": "rich://static"], ["contents", 0, "text"]),
        Cell("resources/read", ["uri": "rich://static"], ["contents", 1, "blob"]),
        Cell("resources/read", ["uri": "rich://static"], ["contents", 0, "_meta"], since: .r2025_06_18),
        Cell("resources/read", ["uri": "rich://static"], ["contents", 1, "_meta"], since: .r2025_06_18),
        // GetPromptResult.
        Cell("prompts/get", richPrompt, ["description"]),
        Cell("prompts/get", richPrompt, ["messages", 0, "role"]),
        Cell("prompts/get", richPrompt, ["messages", 1, "content", "data"]),
        Cell("prompts/get", richPrompt, ["messages", 1, "content", "annotations", "lastModified"], since: .r2025_06_18),
        Cell("prompts/get", richPrompt, ["messages", 3, "content", "resource", "text"]),
        Cell("prompts/get", richPrompt, ["messages", 4, "content", "uri"], since: .r2025_06_18),
        // 2026-07-28: `resultType` on every result (SEP-2322), `serverInfo` in `_meta` (SEP-2575),
        // `ttlMs` and `cacheScope` on list and read results (SEP-2549).
        Cell("tools/list", [:], ["resultType"], since: .r2026_07_28),
        Cell("tools/list", [:], ["ttlMs"], since: .r2026_07_28),
        Cell("tools/list", [:], ["cacheScope"], since: .r2026_07_28),
        Cell("tools/list", [:], ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell("resources/list", [:], ["resultType"], since: .r2026_07_28),
        Cell("resources/list", [:], ["ttlMs"], since: .r2026_07_28),
        Cell("resources/list", [:], ["cacheScope"], since: .r2026_07_28),
        Cell("resources/list", [:], ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell("resources/templates/list", [:], ["resultType"], since: .r2026_07_28),
        Cell("resources/templates/list", [:], ["ttlMs"], since: .r2026_07_28),
        Cell("resources/templates/list", [:], ["cacheScope"], since: .r2026_07_28),
        Cell("resources/templates/list", [:], ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell("prompts/list", [:], ["resultType"], since: .r2026_07_28),
        Cell("prompts/list", [:], ["ttlMs"], since: .r2026_07_28),
        Cell("prompts/list", [:], ["cacheScope"], since: .r2026_07_28),
        Cell("prompts/list", [:], ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell("resources/read", ["uri": "rich://static"], ["resultType"], since: .r2026_07_28),
        Cell("resources/read", ["uri": "rich://static"], ["ttlMs"], since: .r2026_07_28),
        Cell("resources/read", ["uri": "rich://static"], ["cacheScope"], since: .r2026_07_28),
        Cell("resources/read", ["uri": "rich://static"], ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell("tools/call", everything, ["resultType"], since: .r2026_07_28),
        Cell("tools/call", everything, ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell("tools/call", ["name": "tool_error"], ["resultType"], since: .r2026_07_28),
        Cell("tools/call", ["name": "tool_error"], ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell("tools/call", ["name": "strict", "arguments": ["n": 5]], ["_meta", .string(serverInfo), "version"], since: .r2026_07_28),
        Cell("prompts/get", richPrompt, ["resultType"], since: .r2026_07_28),
        Cell("prompts/get", richPrompt, ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
        Cell(
            "completion/complete", ["ref": ["type": "ref/prompt", "name": "rich_prompt"], "argument": ["name": "topic", "value": ""]],
            ["completion", "values"]),
        Cell(
            "completion/complete", ["ref": ["type": "ref/prompt", "name": "rich_prompt"], "argument": ["name": "topic", "value": ""]],
            ["resultType"], since: .r2026_07_28),
        Cell(
            "completion/complete", ["ref": ["type": "ref/prompt", "name": "rich_prompt"], "argument": ["name": "topic", "value": ""]],
            ["_meta", .string(serverInfo), "name"], since: .r2026_07_28),
    ]

    /// A field is sent to exactly the revisions whose schema declares it: not stripped from a
    /// revision that has it, not leaked into one that does not.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func everyFieldReachesExactlyTheRevisionsThatDeclareIt(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        var responses: [String: JSONValue] = [:]
        for cell in Self.cells {
            let key = "\(cell.method) \(JSONValue.object(cell.params))"
            if responses[key] == nil { responses[key] = try await client.request(cell.method, cell.params) }
            let result = try #require(responses[key]?["result"], "\(key) failed: \(responses[key] ?? .null)")
            var value: JSONValue? = result
            for step in cell.path {
                if let name = step.stringValue { value = value?[name] } else if let index = step.intValue { value = value?[index] }
            }
            let expected = revision.isAtLeast(cell.since)
            let path = cell.path.map { "\($0)" }.joined(separator: ".")
            #expect((value != nil) == expected, "\(revision.rawValue) \(key): \(path) should be \(expected ? "present" : "absent") (introduced in \(cell.since.rawValue))")
        }
    }

    /// `Implementation`: `title` from 2025-06-18 (PR #663); `description`, `icons` and
    /// `websiteUrl` from 2025-11-25 (changelog, minor change 2, and SEP-973).
    @Test(arguments: IndependentProtocolRevision.allCases)
    func serverIdentityByRevision(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        let info: JSONValue
        if revision.isModern {
            let result = try #require(try await TestClient(server).request("server/discover")["result"])
            info = try #require(result["_meta"]?["io.modelcontextprotocol/serverInfo"])
            // The modern revision has no InitializeResult: these belong to it alone.
            #expect(result["protocolVersion"] == nil)
            #expect(result["serverInfo"] == nil)
            #expect(result["instructions"] == "Read the manual.")
        } else {
            let result = try #require(try await TestClient(server, modern: false).initialize(version: revision.version)["result"])
            info = try #require(result["serverInfo"])
            #expect(result["instructions"] == "Read the manual.")
            // Nothing of 2026-07-28 in a handshake result.
            #expect(result["supportedVersions"] == nil)
            #expect(result["resultType"] == nil)
            #expect(result["ttlMs"] == nil)
            #expect(result["cacheScope"] == nil)
            #expect(result["_meta"] == nil)
        }
        #expect(info["name"] == "rich")
        #expect(info["version"] == "9.9.9")
        #expect((info["title"] != nil) == revision.isAtLeast(.r2025_06_18))
        #expect((info["description"] != nil) == revision.isAtLeast(.r2025_11_25))
        #expect((info["websiteUrl"] != nil) == revision.isAtLeast(.r2025_11_25))
        #expect((info["icons"] != nil) == revision.isAtLeast(.r2025_11_25))
    }

    // MARK: Methods

    private enum Availability { case served, notFound }

    /// Which request methods exist in which revision, from the `ClientRequest` union of each
    /// `schema.ts`. 2026-07-28 removed `initialize`, `ping`, `logging/setLevel`,
    /// `resources/subscribe` and `resources/unsubscribe` and added `server/discover` and
    /// `subscriptions/listen` (changelog, major changes 2–5).
    private static let methods: [(method: String, params: JSONObject, legacy: Availability, modern: Availability)] = [
        ("ping", [:], .served, .notFound),
        ("logging/setLevel", ["level": "info"], .served, .notFound),
        ("resources/subscribe", ["uri": "rich://static"], .served, .notFound),
        ("resources/unsubscribe", ["uri": "rich://static"], .served, .notFound),
        ("server/discover", [:], .notFound, .served),
        ("tools/list", [:], .served, .served),
        ("tools/call", ["name": "plain"], .served, .served),
        ("resources/list", [:], .served, .served),
        ("resources/templates/list", [:], .served, .served),
        ("resources/read", ["uri": "rich://static"], .served, .served),
        ("prompts/list", [:], .served, .served),
        ("prompts/get", ["name": "bare"], .served, .served),
        ("completion/complete", ["ref": ["type": "ref/prompt", "name": "bare"], "argument": ["name": "a", "value": ""]], .served, .served),
        // Client-side methods, methods of features Limb does not advertise, and nonsense.
        ("roots/list", [:], .notFound, .notFound),
        ("sampling/createMessage", [:], .notFound, .notFound),
        ("elicitation/create", [:], .notFound, .notFound),
        ("tasks/get", ["taskId": "t"], .notFound, .notFound),
        ("tasks/list", [:], .notFound, .notFound),
        ("tasks/cancel", ["taskId": "t"], .notFound, .notFound),
        ("tasks/result", ["taskId": "t"], .notFound, .notFound),
        ("notifications/initialized", [:], .notFound, .notFound),
        ("notifications/cancelled", ["requestId": 1], .notFound, .notFound),
        ("Tools/List", [:], .notFound, .notFound),
        ("tools/list ", [:], .notFound, .notFound),
        ("tools", [:], .notFound, .notFound),
        ("", [:], .notFound, .notFound),
        ("rpc.discover", [:], .notFound, .notFound),
    ]

    @Test(arguments: IndependentProtocolRevision.allCases)
    func methodsExistExactlyInTheRevisionsThatDefineThem(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        for (method, params, legacy, modern) in Self.methods {
            let response = try await client.request(method, params)
            switch revision.isModern ? modern : legacy {
            case .served:
                #expect(response["result"] != nil, "\(revision.rawValue) must serve \(method): \(response)")
            case .notFound:
                #expect(response.code == -32601, "\(revision.rawValue) must answer \(method) with -32601: \(response)")
            }
        }
    }

    /// `subscriptions/listen` is 2026-07-28 only; in a handshake session it does not exist, and
    /// asking for it must not open anything.
    @Test(arguments: IndependentProtocolRevision.legacy)
    func subscriptionsListenDoesNotExistBefore2026(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        let client = try await IndependentProtocol.client(server, revision)
        let response = try await client.request("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        #expect(response.code == -32601)
    }

    // MARK: Error codes that changed

    /// "Change resource not found error code from -32002 to -32602" (2026-07-28 changelog, minor
    /// change 6); "Implementations of this protocol version MUST NOT emit" -32002 (basic/index.mdx).
    @Test(arguments: IndependentProtocolRevision.allCases)
    func resourceNotFoundCode(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        for uri in ["rich://missing", "rich://items/", "rich://items/a/b", "", "RICH://static", "rich://static/"] {
            let response = try await client.request("resources/read", ["uri": .string(uri)])
            #expect(response.code == (revision.isModern ? -32602 : -32002), "\(revision.rawValue) \(uri): \(response)")
            #expect(response["result"] == nil)
        }
    }

    /// "Clarify that input validation errors should be returned as Tool Execution Errors rather
    /// than Protocol Errors" (2025-11-25 changelog, minor change 5, SEP-1303). Before that the
    /// tools pages list them under protocol errors with -32602.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func invalidToolArgumentsByRevision(_ revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(recorder: recorder), revision)
        let invalid: [JSONObject] = [
            [:], ["n": 0], ["n": 11], ["n": 1.5], ["n": "1"], ["n": nil], ["n": 1, "mode": "medium"], ["n": 1, "tags": ["a", "b", "c"]],
            ["n": 1, "tags": [1]], ["n": 1, "nested": [:]], ["n": 1, "nested": ["flag": "yes"]], ["n": 1, "unknown": true],
        ]
        for arguments in invalid {
            let response = try await client.request("tools/call", ["name": "strict", "arguments": .object(arguments)])
            if revision.isAtLeast(.r2025_11_25) {
                #expect(response["result"]?["isError"] == true, "\(revision.rawValue) \(JSONValue.object(arguments)): \(response)")
                #expect(response.text?.isEmpty == false, "the model needs a reason: \(response)")
            } else {
                #expect(response.code == -32602, "\(revision.rawValue) \(JSONValue.object(arguments)): \(response)")
            }
        }
        // "arguments have already been validated": the handler never saw any of these.
        #expect(recorder.count(of: "strict") == 0)
        // And an unknown tool is a protocol error in every revision (tools.mdx, "Error Handling").
        #expect(try await client.request("tools/call", ["name": "no_such_tool"]).code == -32602)
        // The valid call still runs.
        #expect(try await client.request("tools/call", ["name": "strict", "arguments": ["n": 10, "mode": "fast", "tags": ["a", "b"], "nested": ["flag": false]]]).text == "n=10")
        #expect(recorder.count(of: "strict") == 1)
    }

    // MARK: Structured content

    /// 2025-03-26 has no `structuredContent`; 2025-06-18 and 2025-11-25 type it as an object;
    /// 2026-07-28 "structuredContent to allow any JSON value" (changelog, minor change 10).
    /// In every revision the serialized JSON is also there as text (tools.mdx: "SHOULD also
    /// return the serialized JSON in a TextContent block").
    @Test(arguments: IndependentProtocolRevision.allCases)
    func structuredContentByRevision(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)

        let object = try #require(try await client.request("tools/call", ["name": "object_out"])["result"])
        #expect((object["structuredContent"] != nil) == revision.isAtLeast(.r2025_06_18))
        if revision.isAtLeast(.r2025_06_18) { #expect(object["structuredContent"] == ["sum": 3]) }
        let objectText = try #require(object["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(Array(objectText.utf8)) == ["sum": 3])

        let scalar = try #require(try await client.request("tools/call", ["name": "scalar_out"])["result"])
        #expect((scalar["structuredContent"] != nil) == revision.isModern, "\(revision.rawValue): \(scalar)")
        if revision.isModern { #expect(scalar["structuredContent"] == "just a string") }
        let scalarText = try #require(scalar["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(Array(scalarText.utf8)) == "just a string")
    }

    // MARK: Notifications sent while a request runs

    @Test(arguments: IndependentProtocolRevision.allCases)
    func progressNotificationsConformToTheSchema(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        for token in ["a token", 0, -7, 9_007_199_254_740_993] as [JSONValue] {
            client.clearReceived()
            let response = try await client.request("tools/call", ["name": "progress"], meta: ["progressToken": token])
            #expect(response.text == "done")
            let notifications = client.received
            #expect(notifications.count == 3, "\(notifications)")
            for notification in notifications {
                #expect(notification["method"] == "notifications/progress")
                // "an opaque token that will be attached to any subsequent notifications": same type, same value.
                #expect(notification["params"]?["progressToken"] == token)
                #expect(notification["params"]?["progressToken"]?.description == token.description)
                let violations = IndependentProtocol.notificationViolations(notification, as: "ProgressNotification", in: revision)
                #expect(violations.isEmpty, "\(revision.rawValue): \(violations.joined(separator: "\n"))")
            }
            #expect(notifications.map { $0["params"]?["progress"]?.doubleValue } == [1, 2.5, 4])
            #expect(notifications.map { $0["params"]?["total"]?.doubleValue } == [4, 4, nil])
            #expect(notifications.map { $0["params"]?["message"]?.stringValue } == ["a quarter", nil, nil])
        }
        // No token, or a token that is neither a string nor a number: no progress.
        for meta in [[:], ["progressToken": nil], ["progressToken": true], ["progressToken": ["x"]], ["progressToken": ["a": 1]]] as [JSONObject] {
            client.clearReceived()
            _ = try await client.request("tools/call", ["name": "progress"], meta: meta)
            #expect(client.received.isEmpty, "\(JSONValue.object(meta)): \(client.received)")
        }
    }

    @Test(arguments: IndependentProtocolRevision.allCases)
    func logNotificationsConformToTheSchema(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        if revision.isModern {
            _ = try await client.request("tools/call", ["name": "log_all"], meta: ["io.modelcontextprotocol/logLevel": "debug"])
        } else {
            #expect(try await client.request("logging/setLevel", ["level": "debug"])["result"] == [:])
            _ = try await client.request("tools/call", ["name": "log_all"])
        }
        let notifications = client.received
        #expect(notifications.count == 8)
        for notification in notifications {
            #expect(notification["method"] == "notifications/message")
            #expect(notification["params"]?["logger"] == "rich")
            let violations = IndependentProtocol.notificationViolations(notification, as: "LoggingMessageNotification", in: revision)
            #expect(violations.isEmpty, "\(revision.rawValue): \(violations.joined(separator: "\n"))")
        }
        #expect(notifications.compactMap { $0["params"]?["level"]?.stringValue } == IndependentProtocolRich.levels)
    }
}
