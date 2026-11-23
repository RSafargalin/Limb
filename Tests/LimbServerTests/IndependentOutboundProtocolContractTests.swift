import Limb
import LimbTesting
import Testing

@Suite struct IndependentOutboundProtocolContractTests {
    @Test(arguments: IndependentProtocolRevision.legacy)
    func legacyCustomResultKeepsItsPayload(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "outbound", version: "1")
        try server.register(method: "example/inspect") { _, _ in ["payload": ["mode": "ordinary", "count": 3]] }
        let client = try await IndependentProtocol.client(server, revision)

        let response = try await client.request("example/inspect")
        #expect(response["result"] == ["payload": ["mode": "ordinary", "count": 3]])
        #expect(response["error"] == nil)
    }

    @Test(arguments: [JSONValue(7), "com.example/unnegotiated", "input_required"])
    func modernCustomResultRejectsInvalidExplicitDiscriminator(_ discriminator: JSONValue) async throws {
        let server = Server(name: "outbound", version: "1")
        try server.register(method: "example/inspect") { _, _ in
            ["resultType": discriminator, "payload": "example"]
        }
        let client = try await IndependentProtocol.client(server, .r2026_07_28)

        let id = client.post("example/inspect", id: "custom-result")
        let response = try await client.next()
        expectError(response, id: id, code: -32603)
    }

    @Test(arguments: [-32002, -32042, -32099, -32020, -32021, -32022])
    func modernCustomErrorCannotEmitUnrelatedOrRetiredMCPCode(_ code: Int) async throws {
        let server = Server(name: "outbound", version: "1")
        try server.register(method: "example/failure") { _, _ in
            throw MCPError(code: code, message: "Example handler error")
        }
        let client = try await IndependentProtocol.client(server, .r2026_07_28)

        let id = client.post("example/failure", id: "custom-error")
        let response = try await client.next()
        expectError(response, id: id, code: -32603)
    }

    @Test func modernCustomErrorKeepsApplicationCodeAndPayload() async throws {
        let server = Server(name: "outbound", version: "1")
        try server.register(method: "example/failure") { _, _ in
            throw MCPError(code: 1234, message: "Example handler error", data: ["detail": 37])
        }
        let client = try await IndependentProtocol.client(server, .r2026_07_28)

        let id = client.post("example/failure", id: "application-error")
        let response = try await client.next()
        expectError(response, id: id, code: 1234)
        #expect(response["error"]?["message"] == "Example handler error")
        #expect(response["error"]?["data"] == ["detail": 37])
    }

    @Test func discoveryKeepsItsTypedUnsupportedProtocolVersionError() async throws {
        let server = Server(name: "outbound", version: "1")
        let client = TestClient(server, modern: false)
        let requested = "1900-01-01"
        let id = client.post(
            "server/discover",
            id: "discovery-version",
            meta: [
                "io.modelcontextprotocol/protocolVersion": .string(requested),
                "io.modelcontextprotocol/clientCapabilities": [:],
            ]
        )
        let response = try await client.next()
        expectError(response, id: id, code: -32022)
        #expect(response["error"]?["data"]?["requested"] == .string(requested))
        #expect(response["error"]?["data"]?["supported"]?.arrayValue?.contains("2026-07-28") == true)
    }

    @Test(arguments: IndependentProtocolRevision.legacy)
    func legacyMissingResourceKeepsItsProtocolError(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        let client = try await IndependentProtocol.client(server, revision)

        let id = client.post("resources/read", ["uri": "rich://missing"], id: "missing-resource")
        let response = try await client.next()
        expectError(response, id: id, code: -32002)
    }

    @Test(
        arguments: IndependentProtocolRevision.allCases,
        [JSONValue(9), "example-token", 1.5, .null]
    )
    func progressUsesOnlyStringAndIntegerTokens(_ revision: IndependentProtocolRevision, token: JSONValue) async throws {
        let server = Server(name: "outbound", version: "1")
        try server.register(tool: ToolDefinition(name: "report")) { _, context in
            context.progress(1.5, total: 2.5, message: "working")
            return .text("finished")
        }
        let client = try await IndependentProtocol.client(server, revision)

        let response = try await client.request("tools/call", ["name": "report"], meta: ["progressToken": token])
        #expect(response["error"] == nil)
        #expect(response["result"]?["content"]?[0]?["text"] == "finished")
        let notices = client.received.filter { $0["method"] == "notifications/progress" }
        if token == 1.5 || token == .null {
            #expect(notices.isEmpty)
        } else {
            let notice = try #require(notices.first)
            #expect(notices.count == 1)
            #expect(notice["id"] == nil)
            #expect(notice["params"]?["progressToken"] == token)
            #expect(notice["params"]?["progress"] == 1.5)
            #expect(notice["params"]?["total"] == 2.5)
            #expect(notice["params"]?["message"] == "working")
        }
    }

    private func expectError(
        _ response: JSONValue, id: RequestID, code: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(response["jsonrpc"] == "2.0", sourceLocation: sourceLocation)
        #expect(response["id"] == id.json, sourceLocation: sourceLocation)
        #expect(response["result"] == nil, sourceLocation: sourceLocation)
        #expect(response["error"]?["code"]?.intValue == code, sourceLocation: sourceLocation)
        #expect(response["error"]?["message"]?.stringValue != nil, sourceLocation: sourceLocation)
    }
}
