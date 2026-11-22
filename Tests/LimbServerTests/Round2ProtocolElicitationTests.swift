import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

/// S9: URL-mode elicitation of `2025-11-25` (`elicitationId`, `notifications/elicitation/complete`,
/// error `-32042`), against `schema/2025-11-25/schema.ts` and `client/elicitation.mdx`.
@Suite(.timeLimit(.minutes(2)))
struct Round2ProtocolElicitationTests {
    private static let urlAndForm: JSONObject = ["elicitation": ["form": [:], "url": [:]]]

    /// A server with tools that elicit in URL mode, in form mode, and that throw `-32042`.
    private static func server(
        diagnostics: R2PDiagnostics = R2PDiagnostics(), notified: R2PBox<[Bool]> = R2PBox([])
    ) throws -> Server {
        let server = R2P.server(diagnostics: diagnostics)
        try server.register(tool: ToolDefinition(name: "url")) { arguments, context in
            let id = arguments["id"]?.stringValue
            let result = try await context.elicit("k", message: "Sign in, please", url: "https://example.com/connect", elicitationID: id)
            if arguments["complete"] == true, let id {
                let sent = context.notifyElicitationComplete(id)
                notified.withLock { $0.append(sent) }
                return .text("\(result.action.rawValue) notified=\(sent)")
            }
            return .text(result.action.rawValue)
        }
        try server.register(tool: ToolDefinition(name: "form")) { _, context in
            let result = try await context.elicit("k", message: "Name?", schema: R2P.formSchema)
            return .text(result.content?["name"]?.stringValue ?? result.action.rawValue)
        }
        try server.register(tool: ToolDefinition(name: "required")) { arguments, _ in
            let id = arguments["id"]?.stringValue
            throw MCPError.urlElicitationRequired([
                ElicitRequest(message: "Authorize Example Co", url: "https://example.com/secret-connect", elicitationID: id),
                ElicitRequest(message: "Pay", url: "https://example.com/pay"),
            ])
        }
        try server.register(tool: ToolDefinition(name: "notify")) { arguments, context in
            .text("\(context.notifyElicitationComplete(arguments["id"]?.stringValue ?? "x"))")
        }
        try server.register(resource: ResourceDefinition(uri: "r2p://needs-auth", name: "needs-auth")) { _, _ in
            throw MCPError.urlElicitationRequired([ElicitRequest(message: "Authorize", url: "https://example.com/r", elicitationID: "res-1")])
        }
        try server.register(prompt: PromptDefinition(name: "needs-auth")) { _, _ in
            throw MCPError.urlElicitationRequired([ElicitRequest(message: "Authorize", url: "https://example.com/p", elicitationID: "prompt-1")])
        }
        return server
    }

    // MARK: elicitation/create in URL mode

    /// `ElicitRequestURLParams` (2025-11-25 schema.ts:2183): `mode: "url"`, `message`,
    /// `elicitationId: string` (required), `url`. Nothing else.
    @Test func urlModeIn2025_11_25HasExactlyTheFourMembers() async throws {
        let client = try await R2P.client(try Self.server(), .r2025_11_25, capabilities: Self.urlAndForm)
        let call = client.post("tools/call", ["name": "url"])
        let request = try await R2P.expectMessage(client, "elicitation/create")
        let params = try #require(request["params"])
        #expect(R2P.keys(params) == ["mode", "message", "elicitationId", "url"])
        #expect(params["mode"] == "url")
        #expect(params["message"] == "Sign in, please")
        #expect(params["url"] == "https://example.com/connect")
        let id = try #require(params["elicitationId"]?.stringValue)
        #expect(!id.isEmpty)
        #expect(IndependentProtocolRevision.r2025_11_25.schema.violations(in: params, as: "ElicitRequestURLParams") == [])
        R2P.answer(client, request, ["action": "accept"])
        #expect(try await client.response(to: call).r2pText == "accept")
    }

    /// "The ID of the elicitation, which must be unique within the context of the server."
    @Test func generatedIdsAreUniqueAcrossRequestsAndConnections() async throws {
        let server = try Self.server()
        var ids: Set<String> = []
        for _ in 0..<3 {
            let client = try await R2P.client(server, .r2025_11_25, capabilities: Self.urlAndForm)
            for _ in 0..<20 {
                let call = client.post("tools/call", ["name": "url"])
                let request = try await R2P.expectMessage(client, "elicitation/create")
                let id = try #require(request["params"]?["elicitationId"]?.stringValue)
                ids.insert(id)
                R2P.answer(client, request, ["action": "decline"])
                #expect(try await client.response(to: call).r2pText == "decline")
            }
        }
        #expect(ids.count == 60)
    }

    /// An id the handler supplies is sent exactly, including characters JSON must escape.
    @Test(arguments: ["550e8400-e29b-41d4-a716-446655440000", "quote\"back\\slash\nline\u{1}", "\u{E9}\u{1F600}", ""])
    func handlerSuppliedIdIsSentVerbatim(id: String) async throws {
        let client = try await R2P.client(try Self.server(), .r2025_11_25, capabilities: Self.urlAndForm)
        let call = client.post("tools/call", ["name": "url", "arguments": ["id": JSONValue.string(id)]])
        let request = try await R2P.expectMessage(client, "elicitation/create")
        #expect(request["params"]?["elicitationId"] == JSONValue.string(id))
        R2P.answer(client, request, ["action": "cancel"])
        #expect(try await client.response(to: call).r2pText == "cancel")
    }

    /// Form mode in 2025-11-25: `mode` is `"form"` or absent, and there is no `elicitationId`.
    @Test func formModeIn2025_11_25HasNoElicitationId() async throws {
        let client = try await R2P.client(try Self.server(), .r2025_11_25, capabilities: Self.urlAndForm)
        let call = client.post("tools/call", ["name": "form"])
        let request = try await R2P.expectMessage(client, "elicitation/create")
        let params = try #require(request["params"])
        #expect(params["elicitationId"] == nil)
        #expect(params["mode"] == nil || params["mode"] == "form")
        #expect(R2P.keys(params).isSubset(of: ["mode", "message", "requestedSchema"]))
        #expect(IndependentProtocolRevision.r2025_11_25.schema.violations(in: params, as: "ElicitRequestFormParams") == [])
        R2P.answer(client, request, ["action": "accept", "content": ["name": "Ada"]])
        #expect(try await client.response(to: call).r2pText == "Ada")
    }

    /// 2025-06-18 has form mode only (no `mode`, no `elicitationId`); 2025-03-26 has no
    /// elicitation. URL mode is never sent there, whatever the client claims.
    @Test(arguments: [IndependentProtocolRevision.r2025_03_26, .r2025_06_18])
    func olderRevisionsNeverSendUrlMode(revision: IndependentProtocolRevision) async throws {
        let client = try await R2P.client(try Self.server(), revision, capabilities: Self.urlAndForm)
        let response = try await client.request("tools/call", ["name": "url"])
        #expect(response.r2pIsToolError, "\(response)")
        #expect(client.received.isEmpty, "\(String(describing: client.received))")
        if revision == .r2025_06_18 {
            let call = client.post("tools/call", ["name": "form"])
            let request = try await R2P.expectMessage(client, "elicitation/create")
            #expect(R2P.keys(request["params"]) == ["message", "requestedSchema"])
            R2P.answer(client, request, ["action": "accept", "content": ["name": "Ada"]])
            #expect(try await client.response(to: call).r2pText == "Ada")
        }
    }

    /// "Servers MUST NOT send elicitation requests with modes that are not supported by the
    /// client"; `{}` means form only.
    @Test(arguments: [[:], ["elicitation": [:]], ["elicitation": ["form": [:]]]] as [JSONObject])
    func urlModeNeedsTheUrlCapability(capabilities: JSONObject) async throws {
        let client = try await R2P.client(try Self.server(), .r2025_11_25, capabilities: capabilities)
        let response = try await client.request("tools/call", ["name": "url"])
        #expect(response.r2pIsToolError, "\(response)")
        #expect(client.received.isEmpty)
    }

    /// `2026-07-28` (schema.ts:2832): `{mode, message, url}` and no `elicitationId`, even when the
    /// handler supplies one; the input-required round trip is otherwise unchanged.
    @Test func modernUrlModeHasNoElicitationIdAndRoundTrips() async throws {
        let client = TestClient(try Self.server(), capabilities: Self.urlAndForm)
        let first = try await client.request("tools/call", ["name": "url", "arguments": ["id": "given"]])
        let result = try #require(first["result"])
        #expect(result["resultType"] == "input_required")
        let entry = try #require(result["inputRequests"]?["k"])
        #expect(entry["method"] == "elicitation/create")
        let params = try #require(entry["params"])
        #expect(R2P.keys(params) == ["mode", "message", "url"])
        #expect(IndependentProtocolRevision.r2026_07_28.schema.violations(in: params, as: "ElicitRequestURLParams") == [])
        let second = try await client.request(
            "tools/call",
            ["name": "url", "arguments": ["id": "given"], "requestState": result["requestState"]!, "inputResponses": ["k": ["action": "accept"]]])
        #expect(second["result"]?["resultType"] == "complete")
        #expect(second.r2pText == "accept")
        #expect(client.received.isEmpty)
    }

    // MARK: notifications/elicitation/complete

    /// `ElicitationCompleteNotification` (schema.ts:2491): `params: { elicitationId }`, sent to the
    /// client that initiated the elicitation, here from inside the handler.
    @Test func completionFromTheHandlerHasTheSpecifiedShape() async throws {
        let notified = R2PBox<[Bool]>([])
        let client = try await R2P.client(try Self.server(notified: notified), .r2025_11_25, capabilities: Self.urlAndForm)
        let call = client.post("tools/call", ["name": "url", "arguments": ["id": "e-42", "complete": true]])
        let request = try await R2P.expectMessage(client, "elicitation/create")
        #expect(request["params"]?["elicitationId"] == "e-42")
        R2P.answer(client, request, ["action": "accept"])
        let messages = try await R2P.collect(client, until: call)
        #expect(messages.count == 2, "\(messages)")
        let notification = messages[0]
        #expect(notification["method"] == "notifications/elicitation/complete")
        #expect(R2P.keys(notification) == ["jsonrpc", "method", "params"])
        #expect(notification["params"] == ["elicitationId": "e-42"])
        #expect(messages.last?.r2pText == "accept notified=true")
        #expect(notified.withLock { $0 } == [true])
    }

    /// The notification concerns the session: it may be sent after the request ended, through
    /// the `Connection`.
    @Test func completionThroughTheConnectionAfterTheRequestEnded() async throws {
        let client = try await R2P.client(try Self.server(), .r2025_11_25, capabilities: Self.urlAndForm)
        let call = client.post("tools/call", ["name": "url", "arguments": ["id": "later"]])
        let request = try await R2P.expectMessage(client, "elicitation/create")
        R2P.answer(client, request, ["action": "accept"])
        #expect(try await client.response(to: call).r2pText == "accept")
        #expect(client.connection.notifyElicitationComplete("later"))
        let notification = try await R2P.expectMessage(client, "notifications/elicitation/complete")
        #expect(notification["params"] == ["elicitationId": "later"])
        #expect(await client.isSilent(for: .milliseconds(50)))
    }

    /// Returns `false` and sends nothing where the revision has no such notification or the
    /// client does not do URL elicitation.
    private static let withoutCompletion: [(IndependentProtocolRevision, JSONObject)] = [
        (.r2025_11_25, [:]),
        (.r2025_11_25, ["elicitation": [:]]),
        (.r2025_11_25, ["elicitation": ["form": [:]]]),
        (.r2025_06_18, ["elicitation": ["form": [:], "url": [:]]]),
        (.r2025_03_26, ["elicitation": ["form": [:], "url": [:]]]),
        (.r2026_07_28, ["elicitation": ["form": [:], "url": [:]]]),
    ]

    @Test(arguments: withoutCompletion)
    func completionIsRefusedWhereItDoesNotExist(revision: IndependentProtocolRevision, capabilities: JSONObject) async throws {
        let client = try await R2P.client(try Self.server(), revision, capabilities: capabilities)
        #expect(!client.connection.notifyElicitationComplete("x"))
        let response = try await client.request("tools/call", ["name": "notify", "arguments": ["id": "y"]])
        #expect(response.r2pText == "false")
        #expect(client.received.isEmpty, "\(String(describing: client.received))")
        #expect(await client.isSilent(for: .milliseconds(30)))
    }

    /// Before `initialize`, and after the connection closed: nothing is sent.
    @Test func completionBeforeInitializeAndAfterClose() async throws {
        let server = try Self.server()
        let fresh = TestClient(server, modern: false)
        #expect(!fresh.connection.notifyElicitationComplete("x"))
        #expect(await fresh.isSilent(for: .milliseconds(30)))

        let client = try await R2P.client(server, .r2025_11_25, capabilities: Self.urlAndForm)
        await client.close(graceSeconds: 0)
        #expect(!client.connection.notifyElicitationComplete("x"))
        #expect(await client.isSilent(for: .milliseconds(30)))
    }

    // MARK: -32042 URLElicitationRequiredError

    /// `URLElicitationRequiredError` (schema.ts:188): code -32042, `data.elicitations` a list of
    /// `ElicitRequestURLParams`, each with an `elicitationId`.
    @Test func urlElicitationRequiredErrorHasTheSpecifiedShape() async throws {
        let client = try await R2P.client(try Self.server(), .r2025_11_25, capabilities: Self.urlAndForm)
        let response = try await client.request("tools/call", ["name": "required", "arguments": ["id": "auth-1"]])
        #expect(response.r2pCode == -32042, "\(response)")
        #expect(R2P.keys(response) == ["jsonrpc", "id", "error"])
        let error = try #require(response["error"])
        #expect(error["message"]?.stringValue?.isEmpty == false)
        let elicitations = try #require(error["data"]?["elicitations"]?.arrayValue)
        #expect(elicitations.count == 2)
        for elicitation in elicitations {
            #expect(R2P.keys(elicitation) == ["mode", "message", "elicitationId", "url"])
            #expect(elicitation["mode"] == "url")
            #expect(elicitation["elicitationId"]?.stringValue?.isEmpty == false)
            #expect(IndependentProtocolRevision.r2025_11_25.schema.violations(in: elicitation, as: "ElicitRequestURLParams") == [])
        }
        #expect(elicitations[0]["elicitationId"] == "auth-1")
        #expect(elicitations[0]["url"] == "https://example.com/secret-connect")
        #expect(elicitations[0]["message"] == "Authorize Example Co")
        #expect(elicitations[1]["elicitationId"] != elicitations[0]["elicitationId"])
    }

    /// Resources and prompts may answer with it as well ("When a request cannot be processed
    /// until an elicitation is completed").
    @Test func urlElicitationRequiredFromResourcesAndPrompts() async throws {
        let client = try await R2P.client(try Self.server(), .r2025_11_25, capabilities: Self.urlAndForm)
        let read = try await client.request("resources/read", ["uri": "r2p://needs-auth"])
        #expect(read.r2pCode == -32042)
        #expect(read["error"]?["data"]?["elicitations"]?[0]?["elicitationId"] == "res-1")
        let prompt = try await client.request("prompts/get", ["name": "needs-auth"])
        #expect(prompt.r2pCode == -32042)
        #expect(prompt["error"]?["data"]?["elicitations"]?[0]?["elicitationId"] == "prompt-1")
    }

    /// Only 2025-11-25 has -32042, and only a client that does URL elicitation can act on it.
    /// Anywhere else the peer gets -32603 without details, and the operator one diagnostic that
    /// carries no elicitation text.
    private static let without32042: [(IndependentProtocolRevision, JSONObject)] = [
        (.r2025_11_25, [:]),
        (.r2025_11_25, ["elicitation": ["form": [:]]]),
        (.r2025_06_18, ["elicitation": ["form": [:], "url": [:]]]),
        (.r2025_03_26, ["elicitation": ["form": [:], "url": [:]]]),
        (.r2026_07_28, ["elicitation": ["form": [:], "url": [:]]]),
    ]

    @Test(arguments: without32042)
    func urlElicitationRequiredElsewhereIsAnInternalError(revision: IndependentProtocolRevision, capabilities: JSONObject) async throws {
        let diagnostics = R2PDiagnostics()
        let client = try await R2P.client(try Self.server(diagnostics: diagnostics), revision, capabilities: capabilities)
        let response = try await client.request("tools/call", ["name": "required", "arguments": ["id": "auth-1"]])
        #expect(response.r2pCode == -32603, "\(response)")
        #expect(response["error"]?["data"] == nil)
        let message = response["error"]?["message"]?.stringValue ?? ""
        #expect(!message.contains("example.com") && !message.contains("auth-1") && !message.contains("Authorize"))
        #expect(diagnostics.all.count == 1, "\(diagnostics.all)")
        for line in diagnostics.all {
            #expect(!line.contains("secret-connect") && !line.contains("Authorize Example Co"))
        }
    }

    /// In a 2025-03-26 batch the member is an internal error, and the batch is still answered.
    @Test func urlElicitationRequiredInsideA2025_03_26Batch() async throws {
        let client = try await R2P.client(try Self.server(), .r2025_03_26, capabilities: Self.urlAndForm)
        client.send(
            #"[{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"required"}},{"jsonrpc":"2.0","id":"b","method":"tools/call","params":{"name":"notify"}}]"#
        )
        let batch = try #require(try await client.next().arrayValue)
        #expect(batch.count == 2)
        let a = batch.first { $0["id"] == "a" }
        let b = batch.first { $0["id"] == "b" }
        #expect(a?.r2pCode == -32603)
        #expect(b?.r2pText == "false")
    }

    /// Hand-made `data` values of a -32042 error; `valid: false` means the server must refuse
    /// to send it (-32603), `true` that it goes out as is.
    private static let handMade: [(name: String, data: JSONValue?, valid: Bool)] = [
        ("no data", nil, false),
        ("data not an object", "x", false),
        ("no elicitations", ["other": 1], false),
        ("elicitations not an array", ["elicitations": ["mode": "url", "message": "m", "elicitationId": "e", "url": "https://u"]], false),
        ("empty list", ["elicitations": []], false),
        ("form entry", ["elicitations": [["mode": "form", "message": "x"]]], false),
        ("mode missing", ["elicitations": [["message": "m", "elicitationId": "e", "url": "https://u"]]], false),
        ("id missing", ["elicitations": [["mode": "url", "message": "m", "url": "https://u"]]], false),
        ("id not a string", ["elicitations": [["mode": "url", "message": "m", "elicitationId": 7, "url": "https://u"]]], false),
        ("url not a string", ["elicitations": [["mode": "url", "message": "m", "elicitationId": "e", "url": 7]]], false),
        ("url missing", ["elicitations": [["mode": "url", "message": "m", "elicitationId": "e"]]], false),
        ("message missing", ["elicitations": [["mode": "url", "elicitationId": "e", "url": "https://u"]]], false),
        ("message not a string", ["elicitations": [["mode": "url", "message": ["x"], "elicitationId": "e", "url": "https://u"]]], false),
        ("entry not an object", ["elicitations": ["https://u"]], false),
        ("entry null", ["elicitations": [nil]], false),
        (
            "mixed valid and invalid",
            ["elicitations": [["mode": "url", "message": "m", "elicitationId": "e", "url": "https://u"], ["mode": "form", "message": "x"]]], false
        ),
        ("valid", ["elicitations": [["mode": "url", "message": "m", "elicitationId": "e", "url": "https://u"]]], true),
        // The schema types elicitationId as a string; an empty one is a string.
        ("empty id", ["elicitations": [["mode": "url", "message": "m", "elicitationId": "", "url": "https://u"]]], true),
        // ElicitRequestURLParams is open (`_meta`, `task`), and so is `data` ("[key: string]: unknown").
        (
            "extra members",
            ["elicitations": [["mode": "url", "message": "m", "elicitationId": "e", "url": "https://u", "_meta": ["k": 1]]], "retryAfter": 5], true
        ),
    ]

    /// `URLElicitationRequiredError` (schema.ts:188): "The error MUST include a list of
    /// elicitations"; each "MUST be URL mode elicitations and have an elicitationId property".
    @Test func aHandMadeMinus32042IsSentOnlyWhenWellFormed() async throws {
        let diagnostics = R2PDiagnostics()
        let server = R2P.server(diagnostics: diagnostics)
        for (index, entry) in Self.handMade.enumerated() {
            try server.register(tool: ToolDefinition(name: "case\(index)")) { _, _ in
                throw MCPError(code: -32042, message: "needs a URL", data: entry.data)
            }
        }
        let client = try await R2P.client(server, .r2025_11_25, capabilities: Self.urlAndForm)
        for (index, entry) in Self.handMade.enumerated() {
            diagnostics.clear()
            let response = try await client.request("tools/call", ["name": .string("case\(index)")])
            if entry.valid {
                #expect(response.r2pCode == -32042, "\(entry.name): \(response)")
                #expect(response["error"]?["data"] == entry.data, "\(entry.name)")
                #expect(diagnostics.all.isEmpty, "\(entry.name)")
            } else {
                #expect(response.r2pCode == -32603, "\(entry.name): \(response)")
                #expect(response["error"]?["data"] == nil, "\(entry.name)")
                #expect(diagnostics.all.count == 1, "\(entry.name): \(diagnostics.all)")
            }
        }
    }

    /// `urlElicitationRequired` with a form-mode request no longer traps: the server refuses
    /// to send it and answers -32603.
    @Test func urlElicitationRequiredWithAFormRequestIsRefused() async throws {
        let diagnostics = R2PDiagnostics()
        let server = R2P.server(diagnostics: diagnostics)
        try server.register(tool: ToolDefinition(name: "form")) { _, _ in
            throw MCPError.urlElicitationRequired([
                ElicitRequest(message: "ok", url: "https://u", elicitationID: "e"),
                ElicitRequest(message: "m", requestedSchema: ["type": "object"]),
            ])
        }
        try server.register(tool: ToolDefinition(name: "empty")) { _, _ in throw MCPError.urlElicitationRequired([]) }
        let client = try await R2P.client(server, .r2025_11_25, capabilities: Self.urlAndForm)
        for name in ["form", "empty"] {
            let response = try await client.request("tools/call", ["name": .string(name)])
            #expect(response.r2pCode == -32603, "\(name): \(response)")
        }
        #expect(diagnostics.all.count == 2, "\(diagnostics.all)")
    }

    /// An answer's `content` belongs to an accepted form; for URL mode it is dropped.
    @Test func urlModeAnswersCarryNoContent() async throws {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "url")) { _, context in
            let result = try await context.elicit("k", message: "m", url: "https://u")
            return .text("\(result.action.rawValue) content=\(result.content == nil ? "none" : "present")")
        }
        let client = try await R2P.client(server, .r2025_11_25, capabilities: Self.urlAndForm)
        let call = client.post("tools/call", ["name": "url"])
        R2P.answer(client, try await R2P.expectMessage(client, "elicitation/create"), ["action": "accept", "content": ["password": "hunter2"]])
        #expect(try await client.response(to: call).r2pText == "accept content=none")
    }
}
