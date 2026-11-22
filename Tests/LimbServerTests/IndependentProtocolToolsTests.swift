import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var text: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}

private enum ListKind: String, CaseIterable, Sendable {
    case tools = "tools/list"
    case resources = "resources/list"
    case templates = "resources/templates/list"
    case prompts = "prompts/list"

    /// The member of the result that holds the items, and the member of an item that names it.
    var members: (items: String, name: String) {
        switch self {
        case .tools: ("tools", "name")
        case .resources: ("resources", "uri")
        case .templates: ("resourceTemplates", "uriTemplate")
        case .prompts: ("prompts", "name")
        }
    }
}

/// A server with `count` items of every kind, named so that registration order is visible.
private func populated(_ count: Int, pageSize: Int?) throws -> Server {
    let server = Server(name: "paged", version: "1") {
        $0.pageSize = pageSize
        $0.diagnostics = { _ in }
    }
    for index in 0..<count {
        try server.register(tool: ToolDefinition(name: "tool_\(index)")) { _, _ in .text("tool_\(index)") }
        try server.register(resource: ResourceDefinition(uri: "paged://resource/\(index)", name: "r\(index)")) { request, _ in
            [.text(uri: request.uri, text: "resource \(index)")]
        }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "paged://t\(index)/{x}", name: "t\(index)")) { request, _ in
            [.text(uri: request.uri, text: "template \(index)")]
        }
        try server.register(prompt: PromptDefinition(name: "prompt_\(index)")) { _, _ in PromptResult(messages: [.user("prompt_\(index)")]) }
    }
    return server
}

private func expectedNames(_ kind: ListKind, _ count: Int) -> [String] {
    (0..<count).map { index in
        switch kind {
        case .tools: "tool_\(index)"
        case .resources: "paged://resource/\(index)"
        case .templates: "paged://t\(index)/{x}"
        case .prompts: "prompt_\(index)"
        }
    }
}

/// `tools/list`, pagination of all four listings, and `tools/call`.
/// Sources: `server/tools.mdx` and `server/utilities/pagination.mdx` of each revision.
@Suite struct IndependentProtocolToolsTests {
    // MARK: Pagination

    /// Whatever the page size, following `nextCursor` until it is absent yields every item
    /// exactly once, in registration order (tools.mdx: "Servers SHOULD return tools in a
    /// deterministic order"; pagination.mdx: "Treat a missing nextCursor as the end of results").
    @Test(arguments: [IndependentProtocolRevision.r2025_03_26, .r2025_11_25, .r2026_07_28])
    func pagesCoverTheWholeListExactlyOnce(_ revision: IndependentProtocolRevision) async throws {
        for count in [1, 2, 3, 5, 8] {
            for pageSize in [nil, 1, 2, 3, count - 1, count, count + 1, 100] as [Int?] where pageSize != 0 {
                let client = try await IndependentProtocol.client(try populated(count, pageSize: pageSize), revision)
                for kind in ListKind.allCases {
                    var names: [String] = []
                    var cursor: JSONValue?
                    var pages = 0
                    repeat {
                        let response = try await client.request(kind.rawValue, cursor.map { ["cursor": $0] } ?? [:])
                        let label = "\(revision.rawValue) \(kind.rawValue) count \(count) pageSize \(pageSize.map(String.init) ?? "nil") page \(pages)"
                        let result = try #require(response["result"], "\(label): \(response)")
                        #expect(IndependentProtocol.responseViolations(response, to: kind.rawValue, in: revision).isEmpty, "\(label)")
                        let items = try #require(result[kind.members.items]?.arrayValue, "\(label)")
                        if let pageSize { #expect(items.count <= pageSize, "\(label)") }
                        #expect(!items.isEmpty, "\(label): an empty page")
                        names += items.compactMap { $0[kind.members.name]?.stringValue }
                        cursor = result["nextCursor"]
                        if let cursor { #expect(cursor.stringValue != nil, "\(label): nextCursor must be a string, got \(cursor)") }
                        pages += 1
                        try #require(pages <= count + 1, "\(label): pagination does not terminate")
                    } while cursor != nil
                    #expect(names == expectedNames(kind, count), "\(revision.rawValue) \(kind.rawValue) count \(count) pageSize \(pageSize.map(String.init) ?? "nil")")
                    if let pageSize {
                        #expect(pages == (count + pageSize - 1) / pageSize, "\(kind.rawValue) count \(count) pageSize \(pageSize): \(pages) pages")
                    } else {
                        #expect(pages == 1)
                    }
                }
            }
        }
    }

    /// The same cursor gives the same page (pagination.mdx: "Provide stable cursors").
    @Test func aCursorCanBeUsedAgain() async throws {
        let client = TestClient(try populated(7, pageSize: 3))
        for kind in ListKind.allCases {
            let first = try #require(try await client.request(kind.rawValue)["result"])
            let cursor = try #require(first["nextCursor"])
            let second = try #require(try await client.request(kind.rawValue, ["cursor": cursor])["result"])
            let again = try #require(try await client.request(kind.rawValue, ["cursor": cursor])["result"])
            #expect(second == again)
            #expect(second[kind.members.items] != first[kind.members.items])
            // And the first page is still the first page.
            #expect(try await client.request(kind.rawValue)["result"] == first)
        }
    }

    /// "Invalid cursors SHOULD result in an error with code -32602 (Invalid params)"
    /// (pagination.mdx, "Error Handling"); `InvalidParamsError`: "Pagination: Invalid or expired
    /// cursor values".
    @Test(arguments: [
        #""bogus""#, #""""#, #"" ""#, #""-1""#, #""999999""#, #""1.5""#, #""1e0""#, #""0x1""#, #""١""#, #""eyJwYWdlIjogM30=""#,
        #""null""#, #""1; DROP TABLE""#, #""9223372036854775808""#, #""-9223372036854775809""#, "1", "0", "1.0", "true", "false", #"["1"]"#,
        #"{"cursor":"1"}"#,
    ])
    func malformedCursorsAreInvalidParams(_ cursor: String) async throws {
        let recorder = IndependentProtocolRecorder()
        for pageSize in [nil, 2] as [Int?] {
            let server = try populated(5, pageSize: pageSize)
            for revision in [IndependentProtocolRevision.r2025_06_18, .r2026_07_28] {
                let client = try await IndependentProtocol.client(server, revision)
                for kind in ListKind.allCases {
                    let meta = revision.isModern ? IndependentProtocol.modernMetaText + "," : ""
                    let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":5,"method":"\#(kind.rawValue)","params":{\#(meta)"cursor":\#(cursor)}}"#)
                    #expect(reply.code == -32602, "\(revision.rawValue) \(kind.rawValue) pageSize \(pageSize.map(String.init) ?? "nil"): \(reply)")
                    #expect(reply["id"] == 5)
                }
            }
        }
        #expect(recorder.entries.isEmpty)
    }

    /// A cursor that pointed into the list when it was issued and no longer does is "expired".
    @Test func aCursorPastTheEndOfAShrunkListIsRejected() async throws {
        let server = try populated(6, pageSize: 2)
        let client = TestClient(server)
        let first = try #require(try await client.request("tools/list")["result"])
        let second = try #require(try await client.request("tools/list", ["cursor": first["nextCursor"]!])["result"])
        let late = try #require(second["nextCursor"])
        for index in 1..<6 { server.removeTool(named: "tool_\(index)") }
        let response = try await client.request("tools/list", ["cursor": late])
        #expect(response.code == -32602, "\(response)")
    }

    /// Cursors are opaque tokens the server hands out for one listing. A token it never handed
    /// out for that listing — another spelling of a real one, the end position, or a cursor of
    /// a different listing — is not a valid cursor (pagination.mdx: "Invalid cursors SHOULD
    /// result in an error"; Limb's own message is "not a cursor this server issued").
    @Test func cursorsTheServerNeverIssuedAreRejected() async throws {
        let server = try populated(6, pageSize: 2)
        let client = TestClient(server)
        let issued = try #require(try await client.request("tools/list")["result"]?["nextCursor"]?.stringValue)
        var neverIssued = ["+" + issued, "0" + issued, " " + issued, issued + " ", issued + "\n"]
        // Walk to the end and collect every cursor the server really issues for tools.
        var real: Set<String> = []
        var cursor: JSONValue? = .string(issued)
        while let current = cursor {
            real.insert(current.stringValue ?? "")
            cursor = try await client.request("tools/list", ["cursor": current])["result"]?["nextCursor"]
        }
        // The position just past the last item is never issued: the last page has no nextCursor.
        neverIssued.append("6")
        for candidate in neverIssued where !real.contains(candidate) {
            let response = try await client.request("tools/list", ["cursor": .string(candidate)])
            #expect(response.code == -32602, "cursor \(candidate.debugDescription) was accepted: \(response)")
        }
        // A tools cursor presented to the other listings: they did not issue it.
        for kind in [ListKind.resources, .templates, .prompts] {
            let response = try await client.request(kind.rawValue, ["cursor": .string(issued)])
            #expect(response.code == -32602, "\(kind.rawValue) accepted a cursor issued by tools/list: \(response)")
        }
    }

    /// Without pagination the server never issues a cursor, so every cursor is foreign.
    @Test func anyCursorIsInvalidWhenTheServerDoesNotPaginate() async throws {
        let paged = TestClient(try populated(6, pageSize: 2))
        let issued = try #require(try await paged.request("tools/list")["result"]?["nextCursor"])
        let client = TestClient(try populated(6, pageSize: nil))
        for kind in ListKind.allCases {
            #expect(try await client.request(kind.rawValue)["result"]?["nextCursor"] == nil)
            #expect(try await client.request(kind.rawValue, ["cursor": issued]).code == -32602)
        }
    }

    // MARK: The registry behind the listings

    /// Removal keeps the order of what remains, and every name still reaches its own handler
    /// (the registry indexes by name; an index that is not rebuilt would call the neighbour).
    @Test func removalKeepsOrderAndHandlers() async throws {
        let server = try populated(6, pageSize: nil)
        let client = TestClient(server)
        var alive = Array(0..<6)
        for victim in [2, 0, 5, 4] {
            server.removeTool(named: "tool_\(victim)")
            server.removePrompt(named: "prompt_\(victim)")
            server.removeResource(uri: "paged://resource/\(victim)")
            alive.removeAll { $0 == victim }
            let tools = try await client.request("tools/list")["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
            #expect(tools == alive.map { "tool_\($0)" })
            let prompts = try await client.request("prompts/list")["result"]?["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
            #expect(prompts == alive.map { "prompt_\($0)" })
            let resources = try await client.request("resources/list")["result"]?["resources"]?.arrayValue?.compactMap { $0["uri"]?.stringValue }
            #expect(resources == alive.map { "paged://resource/\($0)" })
            for index in 0..<6 {
                let call = try await client.request("tools/call", ["name": .string("tool_\(index)")])
                let prompt = try await client.request("prompts/get", ["name": .string("prompt_\(index)")])
                let read = try await client.request("resources/read", ["uri": .string("paged://resource/\(index)")])
                if alive.contains(index) {
                    #expect(call.text == "tool_\(index)")
                    #expect(prompt["result"]?["messages"]?[0]?["content"]?["text"] == .string("prompt_\(index)"))
                    #expect(read["result"]?["contents"]?[0]?["text"] == .string("resource \(index)"))
                } else {
                    #expect(call.code == -32602, "a removed tool answered: \(call)")
                    #expect(prompt.code == -32602, "a removed prompt answered: \(prompt)")
                    #expect(read.code == -32602, "a removed resource answered: \(read)")
                }
            }
        }
        // Removing what is not there changes nothing; a removed name can be registered again, at the end.
        server.removeTool(named: "tool_2")
        server.removeTool(named: "never_registered")
        try server.register(tool: ToolDefinition(name: "tool_2")) { _, _ in .text("second life") }
        let tools = try await client.request("tools/list")["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(tools == ["tool_1", "tool_3", "tool_2"])
        #expect(try await client.request("tools/call", ["name": "tool_2"]).text == "second life")
    }

    // MARK: tools/call: the request

    /// "Protocol Errors: Unknown tool; Malformed requests (requests that fail to satisfy
    /// CallToolRequest schema)" → -32602 in every revision (tools.mdx, "Error Handling").
    @Test(arguments: IndependentProtocolRevision.allCases)
    func malformedCallsAreProtocolErrors(_ revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(recorder: recorder), revision)
        let meta = revision.isModern ? IndependentProtocol.modernMetaText : ""
        let bodies = [
            "", #""name":5"#, #""name":null"#, #""name":["plain"]"#, #""name":{"name":"plain"}"#, #""name":true"#,
            #""Name":"plain""#, #""arguments":{}"#,
            #""name":"plain","arguments":[]"#, #""name":"plain","arguments":"{}""#, #""name":"plain","arguments":5"#,
            #""name":"plain","arguments":true"#, #""name":"plain","arguments":[{}]"#,
            // Unknown tools; names are case-sensitive ("Tool names SHOULD be considered case-sensitive").
            #""name":"no_such_tool""#, #""name":"""#, #""name":"Plain""#, #""name":"PLAIN""#, #""name":" plain""#, #""name":"plain ""#,
            #""name":"plain\u0000""#, #""name":"tools/call""#, #""name":"plаin""#,
        ]
        for body in bodies {
            let params = [meta, body].filter { !$0.isEmpty }.joined(separator: ",")
            let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{\#(params)}}"#)
            #expect(reply.code == -32602, "\(revision.rawValue) {\(body)}: \(reply)")
            #expect(reply["id"] == "c")
        }
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
        // The unknown tool is named in the error (tools.mdx example: "Unknown tool: invalid_tool_name").
        let unknown = try await client.request("tools/call", ["name": "invalid_tool_name"])
        #expect(unknown["error"]?["message"]?.stringValue?.contains("invalid_tool_name") == true)
    }

    /// The handler gets the arguments exactly as sent, and the request's `_meta` with the keys
    /// Limb does not interpret (doc comment of `RequestContext.meta`).
    @Test(arguments: IndependentProtocolRevision.allCases)
    func theHandlerSeesTheRequestAsSent(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "mirror", version: "1")
        try server.register(tool: ToolDefinition(name: "mirror", inputSchema: ["type": "object"])) { arguments, context in
            ToolResult(structuredContent: [
                "arguments": .object(arguments), "trace": context.meta["traceparent"] ?? nil, "custom": context.meta["com.example/x"] ?? nil,
                "version": .string(context.protocolVersion.rawValue), "method": .string(context.method),
                "id": context.requestID.json, "client": .string(context.clientInfo?.name ?? "(none)"),
            ])
        }
        let client = try await IndependentProtocol.client(server, revision)
        let arguments: JSONObject = [
            "text": "línea\n\"quoted\" \\ \u{1F600} \u{2028}", "empty": "", "zero": 0, "negative": -17, "big": 9_007_199_254_740_993,
            "fraction": 0.125, "flag": false, "nothing": nil, "list": [1, "two", [3], ["four": 4]], "object": ["a": ["b": ["c": []]]],
            "": "empty key", "data": "data:text/plain;base64,aGk=",
        ]
        let response = try await client.request(
            "tools/call", ["name": "mirror", "arguments": .object(arguments)],
            id: "mirror-1", meta: ["traceparent": "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01", "com.example/x": ["y": [1, 2]]])
        // 2025-03-26 has no structuredContent: read the text form there.
        let text = try #require(response.text, "\(response)")
        let seen = try JSON.parse(Array(text.utf8))
        #expect(seen["arguments"] == .object(arguments))
        #expect(seen["trace"] == "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01")
        #expect(seen["custom"] == ["y": [1, 2]])
        #expect(seen["version"] == .string(revision.rawValue))
        #expect(seen["method"] == "tools/call")
        #expect(seen["id"] == "mirror-1")
        #expect(seen["client"] == "limb-test-client")
        // No arguments at all is an empty object for the handler.
        let bare = try await client.request("tools/call", ["name": "mirror"])
        let bareText = try #require(bare.text)
        #expect(try JSON.parse(Array(bareText.utf8))["arguments"] == [:])
    }

    // MARK: tools/call: errors of the tool

    /// "Tool Execution Errors … are reported in tool results with isError: true" — whether the
    /// tool throws `ToolError` or returns an error result; anything else it throws is -32603.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func toolFailuresAreResultsAndFaultsAreErrors(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        try server.register(tool: ToolDefinition(name: "returns_error")) { _, _ in .error("returned, not thrown") }
        try server.register(tool: ToolDefinition(name: "cancelled_inside")) { _, _ in throw CancellationError() }
        let client = try await IndependentProtocol.client(server, revision)

        let thrown = try await client.request("tools/call", ["name": "tool_error"])
        #expect(thrown["result"]?["isError"] == true)
        #expect(thrown.text == "the disk is full")
        #expect(IndependentProtocol.responseViolations(thrown, to: "tools/call", in: revision).isEmpty)

        let returned = try await client.request("tools/call", ["name": "returns_error"])
        #expect(returned["result"]?["isError"] == true)
        #expect(returned.text == "returned, not thrown")

        // A successful result is not an error: `isError` absent or false.
        let fine = try await client.request("tools/call", ["name": "plain"])
        #expect(fine["result"]?["isError"] ?? false == false)

        #expect(try await client.request("tools/call", ["name": "secret_failure"]).code == -32603)
        // A handler that throws CancellationError without the request having been cancelled must
        // still be answered: the client is waiting.
        #expect(try await client.request("tools/call", ["name": "cancelled_inside"]).code == -32603)
    }

    // MARK: Structured content and output schemas

    private static func outputServer() throws -> Server {
        let server = Server(name: "outputs", version: "1") { $0.diagnostics = { _ in } }
        let schema: JSONObject = [
            "type": "object", "properties": ["sum": ["type": "integer"], "label": ["type": "string"]], "required": ["sum"],
            "additionalProperties": false,
        ]
        try server.register(tool: ToolDefinition(name: "good", outputSchema: schema)) { _, _ in .structured(["sum": 3, "label": "three"]) }
        try server.register(tool: ToolDefinition(name: "missing", outputSchema: schema)) { _, _ in .text("no structured content") }
        try server.register(tool: ToolDefinition(name: "wrong_type", outputSchema: schema)) { _, _ in .structured(["sum": "3"]) }
        try server.register(tool: ToolDefinition(name: "missing_member", outputSchema: schema)) { _, _ in .structured(["label": "x"]) }
        try server.register(tool: ToolDefinition(name: "extra_member", outputSchema: schema)) { _, _ in .structured(["sum": 3, "secret": "s3cr3t-value"]) }
        try server.register(tool: ToolDefinition(name: "not_an_object", outputSchema: schema)) { _, _ in .structured([1, 2, 3]) }
        try server.register(tool: ToolDefinition(name: "failed", outputSchema: schema)) { _, _ in .error("could not compute") }
        try server.register(tool: ToolDefinition(name: "failed_by_throwing", outputSchema: schema)) { _, _ in throw ToolError("could not compute") }
        try server.register(tool: ToolDefinition(name: "own_text", outputSchema: schema)) { _, _ in
            ToolResult(content: [.text("The sum is three.")], structuredContent: ["sum": 3])
        }
        return server
    }

    @Test(arguments: IndependentProtocolRevision.allCases)
    func structuredResultsMustMatchTheOutputSchema(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try Self.outputServer(), revision)
        let good = try #require(try await client.request("tools/call", ["name": "good"])["result"])
        #expect(good["isError"] ?? false == false)
        if revision.isAtLeast(.r2025_06_18) { #expect(good["structuredContent"] == ["sum": 3, "label": "three"]) }
        let goodText = try #require(good["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(Array(goodText.utf8)) == ["sum": 3, "label": "three"])

        for name in ["missing", "wrong_type", "missing_member", "extra_member", "not_an_object"] {
            let response = try await client.request("tools/call", ["name": .string(name)])
            #expect(response.code == -32603, "\(revision.rawValue) \(name): \(response)")
            #expect(!response.description.contains("s3cr3t-value"), "the rejected content was sent anyway: \(response)")
        }
        // A failed call has nothing to conform: the error result goes through.
        for name in ["failed", "failed_by_throwing"] {
            let response = try await client.request("tools/call", ["name": .string(name)])
            #expect(response["result"]?["isError"] == true, "\(name): \(response)")
            #expect(response.text == "could not compute")
        }
        // The tool's own text is kept as it is; the structured form rides along where the revision has it.
        let own = try #require(try await client.request("tools/call", ["name": "own_text"])["result"])
        #expect(own["content"]?[0]?["text"] == "The sum is three.")
        #expect((own["structuredContent"] != nil) == revision.isAtLeast(.r2025_06_18))
    }

    /// 2025-06-18 and 2025-11-25 type both `outputSchema` (`type: "object"`) and
    /// `structuredContent` (an object); 2026-07-28 loosened both together (changelog, minor
    /// change 10). A tool whose output is not an object therefore has no structured form in the
    /// older revisions — and a tool advertised with an output schema must deliver structured
    /// content: "If an output schema is provided: Servers MUST provide structured results that
    /// conform to this schema" (tools.mdx of every revision that has output schemas).
    @Test(arguments: [IndependentProtocolRevision.r2025_06_18, .r2025_11_25, .r2026_07_28])
    func anAdvertisedOutputSchemaIsHonouredInThatRevision(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "outputs", version: "1") { $0.diagnostics = { _ in } }
        try server.register(tool: ToolDefinition(name: "list_out", outputSchema: ["type": "array", "items": ["type": "integer"]])) { _, _ in
            .structured([1, 2, 3])
        }
        try server.register(tool: ToolDefinition(name: "text_out", outputSchema: ["type": "string"])) { _, _ in .structured("hello") }
        try server.register(tool: ToolDefinition(name: "any_out", outputSchema: [:])) { _, _ in .structured(42) }
        try server.register(tool: ToolDefinition(name: "object_out", outputSchema: ["type": "object"])) { _, _ in .structured(["k": "v"]) }
        let client = try await IndependentProtocol.client(server, revision)
        let listing = try await client.request("tools/list")
        let listViolations = IndependentProtocol.responseViolations(listing, to: "tools/list", in: revision)
        #expect(listViolations.isEmpty, "\(revision.rawValue): \(listViolations.joined(separator: "\n"))")
        for tool in listing["result"]?["tools"]?.arrayValue ?? [] {
            let name = try #require(tool["name"]?.stringValue)
            let response = try await client.request("tools/call", ["name": .string(name)])
            let result = try #require(response["result"], "\(name): \(response)")
            let callViolations = IndependentProtocol.responseViolations(response, to: "tools/call", in: revision)
            #expect(callViolations.isEmpty, "\(revision.rawValue) \(name): \(callViolations.joined(separator: "\n"))")
            if tool["outputSchema"] != nil {
                #expect(result["structuredContent"] != nil, "\(revision.rawValue): \(name) is listed with an output schema but its result has no structuredContent")
            }
        }
    }

    // MARK: Content

    /// Binary content survives as the same bytes, whatever their number modulo three.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func binaryContentIsBase64OfTheSameBytes(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "binary", version: "1")
        let samples: [[UInt8]] = [[], [0], [0, 1], [0, 1, 2], [255, 254, 253, 252], Array(0...255), Array(repeating: 0xFF, count: 1001)]
        try server.register(tool: ToolDefinition(name: "bytes")) { _, _ in
            ToolResult(content: samples.flatMap { sample in
                [
                    ContentBlock.image(bytes: sample, mimeType: "image/png"), .audio(bytes: sample, mimeType: "audio/wav"),
                    .resource(.blob(uri: "bin://\(sample.count)", mimeType: "application/octet-stream", bytes: sample)),
                ]
            })
        }
        let client = try await IndependentProtocol.client(server, revision)
        let response = try await client.request("tools/call", ["name": "bytes"])
        #expect(IndependentProtocol.responseViolations(response, to: "tools/call", in: revision).isEmpty)
        let content = try #require(response["result"]?["content"]?.arrayValue)
        #expect(content.count == samples.count * 3)
        for (index, sample) in samples.enumerated() {
            let image = try #require(content[index * 3]["data"]?.stringValue)
            let audio = try #require(content[index * 3 + 1]["data"]?.stringValue)
            let blob = try #require(content[index * 3 + 2]["resource"]?["blob"]?.stringValue)
            for encoded in [image, audio, blob] {
                #expect(Data(base64Encoded: encoded) == Data(sample), "\(sample.count) bytes: \(encoded.prefix(40))")
                #expect(encoded == Data(sample).base64EncodedString())
            }
            #expect(content[index * 3]["type"] == "image" && content[index * 3]["mimeType"] == "image/png")
            #expect(content[index * 3 + 1]["type"] == "audio" && content[index * 3 + 1]["mimeType"] == "audio/wav")
            #expect(content[index * 3 + 2]["type"] == "resource")
        }
    }

    /// `content` is required in `CallToolResult`, even when there is none.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func anEmptyResultStillHasContent(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "empty", version: "1")
        try server.register(tool: ToolDefinition(name: "nothing")) { _, _ in ToolResult() }
        let client = try await IndependentProtocol.client(server, revision)
        let response = try await client.request("tools/call", ["name": "nothing"])
        #expect(response["result"]?["content"] == [])
        #expect(IndependentProtocol.responseViolations(response, to: "tools/call", in: revision).isEmpty)
    }

    // MARK: Text that is hard to carry

    private static let awkwardTexts: [String] = [
        "", " ", "line one\nline two\r\nline three\rline four", "tab\there", "quote \" backslash \\ slash / single '",
        "\u{0}", "\u{1}\u{1F}\u{7F}\u{80}\u{9F}", "\u{2028}line separator\u{2029}paragraph separator", "inner\u{FEFF}byte order mark",
        "é and e\u{301}", "中文 日本語 한국어 العربية עברית", "😀 👨‍👩‍👧 🇺🇳", "\u{202E}right-to-left override", "\u{FFFD}\u{FFFE}\u{FFFF}",
        "</script><script>alert(1)</script>", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", "data:text/plain;base64,aGk=", "null", "\\u0041 is six characters",
        "\\", "\"", String(repeating: "long ", count: 20_000),
    ]

    /// Titles, descriptions and results are free text: whatever a server author writes arrives
    /// unchanged, and never breaks the framing ("Messages … MUST NOT contain embedded newlines",
    /// transports/stdio.mdx).
    @Test(arguments: [IndependentProtocolRevision.r2025_03_26, .r2025_11_25, .r2026_07_28])
    func awkwardTextArrivesUnchanged(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "texts", version: "1")
        for (index, text) in Self.awkwardTexts.enumerated() {
            try server.register(
                tool: ToolDefinition(
                    name: "t\(index)", title: text, description: text,
                    inputSchema: ["type": "object", "properties": ["x": ["type": "string", "description": .string(text)]]],
                    annotations: ToolAnnotations(title: text))
            ) { arguments, _ in
                .text(text + (arguments["x"]?.stringValue ?? ""))
            }
        }
        try server.register(prompt: PromptDefinition(name: Self.awkwardTexts[2], description: Self.awkwardTexts[4])) { _, _ in
            PromptResult(description: Self.awkwardTexts[7], messages: [.user(Self.awkwardTexts[6])])
        }
        let peer = IndependentProtocolRawPeer(server)
        var meta = ""
        if revision.isModern {
            meta = IndependentProtocol.modernMetaText
        } else {
            _ = peer.send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(revision.rawValue)","capabilities":{}}}"#)
        }
        func parsed(_ frame: String) throws -> [String: Any] {
            #expect(!frame.utf8.contains(0x0A) && !frame.utf8.contains(0x0D), "embedded line break")
            return try #require(IndependentProtocolRawPeer.foundationObject(frame), "not JSON: \(frame.prefix(300))")
        }
        let listFrame = try #require(peer.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(meta)}}"#).first)
        let tools = try #require((try parsed(listFrame)["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == Self.awkwardTexts.count)
        for (index, text) in Self.awkwardTexts.enumerated() {
            let tool = tools[index]
            #expect(tool["description"] as? String == text, "description \(index)")
            #expect((tool["annotations"] as? [String: Any])?["title"] as? String == text, "annotation title \(index)")
            if revision.isAtLeast(.r2025_06_18) { #expect(tool["title"] as? String == text, "title \(index)") }
            let property = ((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["x"] as? [String: Any]
            #expect(property?["description"] as? String == text, "schema description \(index)")

            // The same text as an argument and back as a result.
            let argument = String(decoding: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
            let separator = meta.isEmpty ? "" : ","
            let frames = await peer.send(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{\#(meta)\#(separator)"name":"t\#(index)","arguments":{"x":\#(argument)}}}"#, awaiting: 1)
            let frame = try #require(frames.first)
            let result = try parsed(frame)["result"] as? [String: Any]
            let block = (result?["content"] as? [[String: Any]])?.first
            #expect(block?["text"] as? String == text + text, "result \(index)")
        }
        let separator = meta.isEmpty ? "" : ","
        let promptName = String(decoding: try JSONSerialization.data(withJSONObject: Self.awkwardTexts[2], options: .fragmentsAllowed), as: UTF8.self)
        let promptFrames = await peer.send(#"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{\#(meta)\#(separator)"name":\#(promptName)}}"#, awaiting: 1)
        let promptFrame = try #require(promptFrames.first)
        let prompt = try #require(try parsed(promptFrame)["result"] as? [String: Any], "\(promptFrames)")
        #expect(prompt["description"] as? String == Self.awkwardTexts[7])
        let message = (prompt["messages"] as? [[String: Any]])?.first?["content"] as? [String: Any]
        #expect(message?["text"] as? String == Self.awkwardTexts[6])
    }

    @Test(arguments: IndependentProtocolRevision.allCases)
    func aLeadingByteOrderMarkInTextIsKept(_ revision: IndependentProtocolRevision) async throws {
        let text = "\u{FEFF}starts with a byte order mark"
        let server = Server(name: "bom", version: "1")
        try server.register(tool: ToolDefinition(name: "bom", description: text)) { _, _ in .text(text) }
        let peer = IndependentProtocolRawPeer(server)
        var meta = ""
        if revision.isModern {
            meta = IndependentProtocol.modernMetaText
        } else {
            _ = peer.send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(revision.rawValue)","capabilities":{}}}"#)
        }
        func carriesTheText(_ frame: String) -> Bool {
            frame.contains("\"" + text + "\"") || frame.lowercased().contains(#""\ufeffstarts with a byte order mark""#)
        }
        let list = try #require(peer.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(meta)}}"#).first)
        #expect(carriesTheText(list), "\(list)")
        let separator = meta.isEmpty ? "" : ","
        let call = await peer.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{\#(meta)\#(separator)"name":"bom"}}"#, awaiting: 1)
        #expect(call.first.map(carriesTheText) == true, "\(call)")
    }

    // MARK: Names

    /// "Tool names SHOULD be between 1 and 128 characters … the only allowed characters:
    /// uppercase and lowercase ASCII letters, digits, underscore, hyphen and dot" (tools.mdx,
    /// "Tool Names"). Limb enforces the guidance at registration and says so in the error.
    @Test func toolNamesAreCheckedAtRegistration() throws {
        let valid = [
            "a", "A", "0", "_", "-", ".", "getUser", "DATA_EXPORT_v2", "admin.tools.list", "a-b_c.d", "..", "--", "__",
            String(repeating: "x", count: 128), "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.",
        ]
        let invalid = [
            "", String(repeating: "x", count: 129), "a b", " a", "a ", "a,b", "a/b", "a:b", "a@b", "a+b", "a#b", "a\nb", "a\tb", "a\u{0}b",
            "naïve", "имя", "名前", "😀", "a\u{301}", "ｔｏｏｌ", "tool!", "(tool)", "tool?", "a\\b", "a\"b", "a'b", "a=b", "a*b", "a%20b", "a|b",
        ]
        let server = Server(name: "names", version: "1")
        for name in valid {
            #expect(throws: Never.self, "\(name.debugDescription) is a valid tool name") {
                try server.register(tool: ToolDefinition(name: name)) { _, _ in .text(name) }
            }
        }
        for name in invalid {
            // A server of its own, so that the refusal can only be about the name.
            let fresh = Server(name: "names", version: "1")
            let error = #expect(throws: RegistrationError.self, "\(name.debugDescription) is not a valid tool name") {
                try fresh.register(tool: ToolDefinition(name: name)) { _, _ in .text(name) }
            }
            #expect(error?.description.isEmpty == false)
            if let error, !name.isEmpty { #expect(error.description.contains(name), "the error does not name the tool: \(error)") }
        }
        // Names differing only in case are different tools.
        #expect(throws: Never.self) { try server.register(tool: ToolDefinition(name: "GETUSER")) { _, _ in .text("upper") } }
        #expect(throws: Never.self) { try server.register(tool: ToolDefinition(name: "getuser")) { _, _ in .text("lower") } }
    }

    @Test func everyValidNameIsCallableByExactlyThatName() async throws {
        let names = ["a", "A", "_", "-", ".", "..", "getUser", "GETUSER", "getuser", "admin.tools.list", String(repeating: "x", count: 128)]
        let server = Server(name: "names", version: "1")
        for name in names { try server.register(tool: ToolDefinition(name: name)) { _, _ in .text("I am \(name)") } }
        let client = TestClient(server)
        let listed = try await client.request("tools/list")["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(listed == names)
        for name in names {
            #expect(try await client.request("tools/call", ["name": .string(name)]).text == "I am \(name)")
        }
    }
}
