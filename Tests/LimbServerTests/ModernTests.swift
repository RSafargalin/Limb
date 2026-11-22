import Limb
import LimbTesting
import Testing

@Suite struct ModernEraTests {
    @Test func discover() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.request("server/discover")
        let result = try #require(response.result)
        #expect(result["resultType"] == "complete")
        #expect(result["supportedVersions"] == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"])
        #expect(result["capabilities"]?["tools"]?["listChanged"] == true)
        #expect(result["capabilities"]?["resources"]?["subscribe"] == true)
        #expect(result["capabilities"]?["completions"] == [:])
        #expect(result["instructions"] == "Use wisely.")
        #expect(result["ttlMs"] == 0)
        #expect(result["cacheScope"] == "public")
        #expect(result["_meta"]?[MetaKey.serverInfo]?["name"] == "fixture")
        #expect(result["_meta"]?[MetaKey.serverInfo]?["version"] == "1.2.3")
    }

    @Test func everyResultCarriesResultTypeAndServerInfo() async throws {
        let client = TestClient(try makeServer())
        for (method, params) in [
            ("tools/list", [:]), ("resources/list", [:]), ("resources/templates/list", [:]), ("prompts/list", [:]),
            ("tools/call", ["name": "echo", "arguments": ["text": "hi"]]),
            ("resources/read", ["uri": "test://static"]),
            ("prompts/get", ["name": "summarize", "arguments": ["topic": "x"]]),
        ] as [(String, JSONObject)] {
            let result = try #require(try await client.request(method, params).result, "\(method)")
            #expect(result["resultType"] == "complete", "\(method)")
            #expect(result["_meta"]?[MetaKey.serverInfo]?["name"] == "fixture", "\(method)")
        }
    }

    @Test func cacheHintsOnCacheableResults() async throws {
        let client = TestClient(try makeServer { $0.listCache = CachePolicy(ttlMilliseconds: 60_000, scope: .public) })
        for method in ["tools/list", "resources/list", "resources/templates/list", "prompts/list"] {
            let result = try #require(try await client.request(method).result)
            #expect(result["ttlMs"] == 60_000, "\(method)")
            #expect(result["cacheScope"] == "public", "\(method)")
        }
        let read = try #require(try await client.request("resources/read", ["uri": "test://static"]).result)
        #expect(read["ttlMs"] == 0)
        #expect(read["cacheScope"] == "private")
        let call = try #require(try await client.request("tools/call", ["name": "echo", "arguments": ["text": "x"]]).result)
        #expect(call["ttlMs"] == nil)
    }

    @Test func requestWithoutVersionIsInvalidParams() async throws {
        let client = TestClient(try makeServer(), modern: false)
        let response = try await client.request("tools/list")
        #expect(response.errorCode == -32602)
        #expect(response["error"]?["data"]?["supported"]?[0] == "2026-07-28")
    }

    @Test func requestWithoutCapabilitiesIsInvalidParams() async throws {
        let client = TestClient(try makeServer(), modern: false)
        let response = try await client.request("tools/list", ["_meta": [MetaKey.protocolVersion: "2026-07-28"]])
        #expect(response.errorCode == -32602)
    }

    @Test func unsupportedVersionListsSupportedOnes() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.request("tools/list", meta: [MetaKey.protocolVersion: "1900-01-01"])
        #expect(response.errorCode == -32022)
        #expect(response["error"]?["data"]?["requested"] == "1900-01-01")
        #expect(response["error"]?["data"]?["supported"]?.arrayValue?.contains("2026-07-28") == true)
        // A legacy revision cannot be spoken through per-request metadata.
        let legacy = try await client.request("tools/list", meta: [MetaKey.protocolVersion: "2025-11-25"])
        #expect(legacy.errorCode == -32022)
    }

    @Test func removedMethodsAreNotFound() async throws {
        let client = TestClient(try makeServer())
        for method in ["ping", "logging/setLevel", "resources/subscribe", "resources/unsubscribe", "nope/nothing"] {
            #expect(try await client.request(method, ["level": "info", "uri": "test://static"]).errorCode == -32601, "\(method)")
        }
    }

    @Test func invalidLogLevelIsRejected() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.request("tools/list", meta: [MetaKey.logLevel: "loud"])
        #expect(response.errorCode == -32602)
    }

    @Test func logMessagesOnlyWhenTheRequestAsks() async throws {
        let client = TestClient(try makeServer())
        _ = try await client.request("tools/call", ["name": "chatty"])
        #expect(client.received.isEmpty)

        _ = try await client.request("tools/call", ["name": "chatty"], meta: [MetaKey.logLevel: "info"])
        let messages = client.received.filter { $0["method"] == "notifications/message" }
        #expect(messages.count == 1)
        #expect(messages.first?["params"]?["level"] == "warning")
        #expect(messages.first?["params"]?["logger"] == "fixture")
        #expect(messages.first?["params"]?["data"]?["problem"] == "something")
    }

    @Test func progressNeedsATokenAndMustIncrease() async throws {
        let client = TestClient(try makeServer())
        _ = try await client.request("tools/call", ["name": "chatty"])
        #expect(client.received.isEmpty)
        _ = try await client.request("tools/call", ["name": "chatty"], meta: ["progressToken": "tok"])
        let progress = client.received.filter { $0["method"] == "notifications/progress" }
        #expect(progress.map { $0["params"]?["progress"] } == [1, 3])
        #expect(progress.allSatisfy { $0["params"]?["progressToken"] == "tok" })
    }

    @Test func resourceNotFoundIsInvalidParams() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.request("resources/read", ["uri": "test://missing"])
        #expect(response.errorCode == -32602)
        #expect(response["error"]?["data"]?["uri"] == "test://missing")
    }

    @Test func templatesAndBinaryContents() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.request("resources/read", ["uri": "test://items/a%20b"])
        let contents = try #require(response.result?["contents"]?[0])
        #expect(contents["uri"] == "test://items/a%20b")
        #expect(contents["blob"]?.stringValue.flatMap(Base64.decode) == Array("a b".utf8))
    }

    @Test func idMayBeReusedAfterItsResponse() async throws {
        let client = TestClient(try makeServer())
        for _ in 0..<3 {
            let response = try await client.request("tools/call", ["name": "echo", "arguments": ["text": "again"]], id: 7)
            #expect(response.firstText == "again")
        }
    }

    @Test func stringAndNumericIdsAreEchoedExactly() async throws {
        let client = TestClient(try makeServer())
        client.send(#"{"jsonrpc":"2.0","id":"7","method":"nope"}"#)
        #expect(try await client.next()["id"] == "7")
        client.send(#"{"jsonrpc":"2.0","id":12345678901234567890,"method":"nope"}"#)
        #expect(try await client.next()["id"]?.description == "12345678901234567890")
    }

    @Test func bothErasOnOneConnection() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.request("tools/list").result?["resultType"] == "complete")
        try await client.initialize(version: .v2025_06_18)
        let legacy = try #require(try await client.request("tools/list").result)
        #expect(legacy["resultType"] == nil)
        #expect(legacy["_meta"] == nil)
        // The legacy session does not get in the way of a request that carries its own version.
        let modern = try await client.request(
            "tools/list",
            meta: [MetaKey.protocolVersion: "2026-07-28", MetaKey.clientCapabilities: [:]])
        #expect(modern.result?["resultType"] == "complete")
    }

    @Test func pagination() async throws {
        let client = TestClient(try makeServer { $0.pageSize = 5 })
        var names: [String] = []
        var cursor: JSONValue?
        var pages = 0
        repeat {
            var params = JSONObject()
            if let cursor { params["cursor"] = cursor }
            let result = try #require(try await client.request("tools/list", params).result)
            names += result["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
            cursor = result["nextCursor"]
            pages += 1
        } while cursor != nil
        #expect(pages == 3)
        #expect(names.count == 13)
        #expect(Set(names).count == 13)
        #expect(try await client.request("tools/list", ["cursor": "bogus"]).errorCode == -32602)
    }

    @Test func listOrderIsRegistrationOrder() async throws {
        let client = TestClient(try makeServer())
        let first = try await client.request("tools/list").result?["tools"]
        let second = try await client.request("tools/list").result?["tools"]
        #expect(first == second)
        #expect(first?[0]?["name"] == "echo")
        #expect(first?[1]?["name"] == "add")
    }

    @Test func customMethod() async throws {
        let server = try makeServer()
        try server.register(method: "acme/sum") { params, _ in
            ["sum": JSONValue((params["a"]?.intValue ?? 0) + (params["b"]?.intValue ?? 0))]
        }
        #expect(throws: RegistrationError.self) { try server.register(method: "tools/list") { _, _ in [:] } }
        let client = TestClient(server)
        let result = try #require(try await client.request("acme/sum", ["a": 2, "b": 3]).result)
        #expect(result["sum"] == 5)
        #expect(result["resultType"] == "complete")
    }
}
