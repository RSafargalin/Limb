import Limb
import LimbTesting
import Testing

@Suite struct LegacyEraTests {
    @Test(arguments: [ProtocolVersion.v2025_03_26, .v2025_06_18, .v2025_11_25])
    func negotiatesRequestedVersion(_ version: ProtocolVersion) async throws {
        let client = TestClient(try makeServer(), modern: false)
        let result = try #require(try await client.initialize(version: version).result)
        #expect(result["protocolVersion"]?.stringValue == version.rawValue)
        #expect(result["serverInfo"]?["name"] == "fixture")
        #expect(result["capabilities"]?["tools"]?["listChanged"] == true)
        #expect(result["instructions"] == "Use wisely.")
        #expect(result["resultType"] == nil)
    }

    @Test func unknownVersionGetsTheNewestLegacyOne() async throws {
        let client = TestClient(try makeServer(), modern: false)
        #expect(try await client.initialize(version: ProtocolVersion(rawValue: "2099-01-01")).result?["protocolVersion"] == "2025-11-25")
        // The modern revision is never the answer to initialize.
        #expect(try await client.initialize(version: .v2026_07_28).result?["protocolVersion"] == "2025-11-25")
    }

    @Test func toleratesUnknownFieldsInInitialize() async throws {
        let client = TestClient(try makeServer(), modern: false)
        client.send(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"x":{"y":[1,2]}},"elicitation":{},"future":true},"clientInfo":{"name":"openai-mcp","version":"1.0.0","extra":{"a":1}},"somethingNew":[1,2,3]}}"#)
        let response = try await client.next()
        #expect(response.result?["protocolVersion"] == "2025-06-18")
    }

    @Test func repeatedInitializeRenegotiates() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: .v2025_11_25)
        #expect(try await client.request("tools/list").result?["tools"]?[0]?["title"] == "Echo")
        #expect(try await client.initialize(version: .v2025_03_26).result?["protocolVersion"] == "2025-03-26")
        #expect(try await client.request("tools/list").result?["tools"]?[0]?["title"] == nil)
    }

    @Test func pingWorksBeforeAndAfterInitialize() async throws {
        let client = TestClient(try makeServer(), modern: false)
        #expect(try await client.request("ping").result == [:])
        try await client.initialize()
        #expect(try await client.request("ping").result == [:])
    }

    @Test func modernOnlyServerNamesItsVersionsOnInitialize() async throws {
        let client = TestClient(try makeServer { $0.supportedVersions = [.v2026_07_28] }, modern: false)
        let response = try await client.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:]])
        #expect(response["error"]?["message"]?.stringValue?.contains("2026-07-28") == true)
    }

    // MARK: Matrix rows

    @Test func batchIsRequiredIn2025_03_26() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: .v2025_03_26)
        client.send(
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/unknown"},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"b"}}},{"jsonrpc":"2.0","id":3,"method":"nope"},42]"#)
        let batch = try #require(try await client.next().arrayValue)
        #expect(batch.count == 4)
        #expect(batch.first { $0["id"] == 1 }?["result"] == [:])
        #expect(batch.first { $0["id"] == 2 }?.firstText == "b")
        #expect(batch.first { $0["id"] == 3 }?.errorCode == -32601)
        #expect(batch.contains { $0["id"] == .null && $0.errorCode == -32600 })

        client.send("[]")
        #expect(try await client.next().errorCode == -32600)
        // Only notifications: nothing comes back.
        client.send(#"[{"jsonrpc":"2.0","method":"notifications/unknown"}]"#)
        #expect(await client.isSilent())
    }

    @Test(arguments: [ProtocolVersion.v2025_06_18, .v2025_11_25])
    func batchIsRejectedAfter2025_03_26(_ version: ProtocolVersion) async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: version)
        client.send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        let response = try await client.next()
        #expect(response.errorCode == -32600)
        #expect(response["id"] == .null)
    }

    @Test func batchIsRejectedWithoutASession() async throws {
        let client = TestClient(try makeServer())
        client.send(#"[{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}]"#)
        #expect(try await client.next().errorCode == -32600)
    }

    @Test(arguments: [
        (ProtocolVersion.v2025_03_26, false), (.v2025_06_18, false), (.v2025_11_25, true),
    ])
    func invalidArgumentsByRevision(_ version: ProtocolVersion, _ asToolError: Bool) async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: version)
        let response = try await client.request("tools/call", ["name": "echo", "arguments": ["text": 5]])
        if asToolError {
            #expect(response.result?["isError"] == true)
            #expect(response.firstText?.contains("text: expected string, got integer") == true)
        } else {
            #expect(response.errorCode == -32602)
            #expect(response["error"]?["message"]?.stringValue?.contains("text") == true)
        }
    }

    @Test(arguments: [ProtocolVersion.v2025_03_26, .v2025_06_18, .v2025_11_25])
    func resourceNotFoundCode(_ version: ProtocolVersion) async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: version)
        #expect(try await client.request("resources/read", ["uri": "test://missing"]).errorCode == -32002)
    }

    @Test func structuredOutputByRevision() async throws {
        let server = try makeServer()
        let old = TestClient(server, modern: false)
        try await old.initialize(version: .v2025_03_26)
        let oldResult = try #require(try await old.request("tools/call", ["name": "add", "arguments": ["a": 1, "b": 2]]).result)
        // Before 2025-06-18 there is no structuredContent: the result travels as text only.
        #expect(oldResult["structuredContent"] == nil)
        #expect(oldResult["content"]?[0]?["text"] == #"{"sum":3.0}"#)
        let oldTools = try #require(try await old.request("tools/list").result?["tools"]?.arrayValue)
        #expect(oldTools.allSatisfy { $0["outputSchema"] == nil && $0["title"] == nil })
        // The display name survives where the old revision can carry it.
        #expect(oldTools[0]["annotations"]?["title"] == "Echo")

        let new = TestClient(server, modern: false)
        try await new.initialize(version: .v2025_06_18)
        let newResult = try #require(try await new.request("tools/call", ["name": "add", "arguments": ["a": 1, "b": 2]]).result)
        #expect(newResult["structuredContent"]?["sum"] == 3)
        #expect(newResult["content"]?[0]?["text"] == #"{"sum":3.0}"#)
        #expect(try await new.request("tools/list").result?["tools"]?[1]?["outputSchema"] != nil)
    }

    @Test func loggingFollowsSetLevel() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize()
        _ = try await client.request("tools/call", ["name": "chatty"])
        #expect(client.received.filter { $0["method"] == "notifications/message" }.count == 1)
        client.clearReceived()
        #expect(try await client.request("logging/setLevel", ["level": "debug"]).result == [:])
        _ = try await client.request("tools/call", ["name": "chatty"])
        #expect(client.received.filter { $0["method"] == "notifications/message" }.count == 2)
        #expect(try await client.request("logging/setLevel", ["level": "verbose"]).errorCode == -32602)
    }

    @Test func listChangedAndResourceSubscriptions() async throws {
        let server = try makeServer()
        let client = TestClient(server, modern: false)
        try await client.initialize()
        try server.register(tool: ToolDefinition(name: "late")) { _, _ in .text("late") }
        #expect(try await client.next()["method"] == "notifications/tools/list_changed")
        #expect(try await client.request("tools/list").result?["tools"]?.arrayValue?.last?["name"] == "late")

        server.notifyResourceUpdated(uri: "test://static")
        #expect(await client.isSilent())
        #expect(try await client.request("resources/subscribe", ["uri": "test://static"]).result == [:])
        server.notifyResourceUpdated(uri: "test://static")
        let update = try await client.next()
        #expect(update["method"] == "notifications/resources/updated")
        #expect(update["params"]?["uri"] == "test://static")
        _ = try await client.request("resources/unsubscribe", ["uri": "test://static"])
        server.notifyResourceUpdated(uri: "test://static")
        #expect(await client.isSilent())
    }

    @Test func elicitationIsARequestToTheClient() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: .v2025_06_18, capabilities: ["elicitation": [:]])
        let call = client.post("tools/call", ["name": "greet"])
        let request = try await client.next()
        #expect(request["method"] == "elicitation/create")
        #expect(request["params"]?["message"] == "What is your name?")
        #expect(request["params"]?["mode"] == nil)
        let requestID = try #require(request["id"])
        client.send(["jsonrpc": "2.0", "id": requestID, "result": elicited(["name": "Ada"])])
        #expect(try await client.response(to: call).firstText == "Hello, Ada")
    }

    @Test func severalInputsGoOutTogether() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(capabilities: ["elicitation": [:], "sampling": [:], "roots": [:]])
        let call = client.post("tools/call", ["name": "gather"])
        var methods: Set<String> = []
        for _ in 0..<3 {
            let request = try await client.next()
            let method = try #require(request["method"]?.stringValue)
            methods.insert(method)
            let reply: JSONValue
            switch method {
            case "elicitation/create": reply = elicited(["name": "Ada"])
            case "sampling/createMessage":
                reply = ["role": "assistant", "content": ["type": "text", "text": "Paris"], "model": "m"]
            default: reply = ["roots": [["uri": "file:///a"], ["uri": "file:///b"]]]
            }
            client.send(["jsonrpc": "2.0", "id": request["id"]!, "result": reply])
        }
        #expect(methods == ["elicitation/create", "sampling/createMessage", "roots/list"])
        #expect(try await client.response(to: call).firstText == "Ada|Paris|2")
    }

    @Test func inputWithoutCapabilityIsAToolError() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: .v2025_11_25)
        let response = try await client.request("tools/call", ["name": "greet"])
        #expect(response.result?["isError"] == true)
        #expect(response.firstText?.contains("elicitation") == true)
        // 2025-03-26 has no elicitation at all, whatever the client claims.
        let old = TestClient(try makeServer(), modern: false)
        try await old.initialize(version: .v2025_03_26, capabilities: ["elicitation": [:]])
        #expect(try await old.request("tools/call", ["name": "greet"]).result?["isError"] == true)
    }

    @Test func cancellingTheCallCancelsTheRequestToTheClient() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(capabilities: ["elicitation": [:]])
        let call = client.post("tools/call", ["name": "greet"])
        let request = try await client.next()
        client.notify("notifications/cancelled", ["requestId": call.json])
        let cancellation = try await client.next()
        #expect(cancellation["method"] == "notifications/cancelled")
        #expect(cancellation["params"]?["requestId"] == request["id"])
        #expect(await client.isSilent())
    }
}
