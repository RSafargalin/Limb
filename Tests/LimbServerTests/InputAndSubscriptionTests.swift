import Limb
import LimbTesting
import Synchronization
import Testing

@Suite struct MultiRoundTripTests {
    let capabilities: JSONObject = ["elicitation": [:], "sampling": [:], "roots": [:]]

    @Test func elicitationRoundTrip() async throws {
        let client = TestClient(try makeServer(), capabilities: capabilities)
        let first = try #require(try await client.request("tools/call", ["name": "greet"]).result)
        #expect(first["resultType"] == "input_required")
        let request = try #require(first["inputRequests"]?["user_name"])
        #expect(request["method"] == "elicitation/create")
        #expect(request["params"]?["mode"] == "form")
        #expect(request["params"]?["message"] == "What is your name?")
        #expect(first["ttlMs"] == nil)
        let state = try #require(first["requestState"])

        let second = try await client.request(
            "tools/call", ["name": "greet", "inputResponses": ["user_name": elicited(["name": "Ada"])], "requestState": state])
        #expect(second.result?["resultType"] == "complete")
        #expect(second.firstText == "Hello, Ada")
    }

    @Test func severalInputsInOneRound() async throws {
        let client = TestClient(try makeServer(), capabilities: capabilities)
        let first = try #require(try await client.request("tools/call", ["name": "gather"]).result)
        let requests = try #require(first["inputRequests"]?.objectValue)
        #expect(Set(requests.map { $0.value["method"]?.stringValue }) == ["elicitation/create", "sampling/createMessage", "roots/list"])
        let second = try await client.request(
            "tools/call",
            [
                "name": "gather", "requestState": first["requestState"]!,
                "inputResponses": [
                    "who": elicited(["name": "Ada"]),
                    "capital": ["role": "assistant", "content": ["type": "text", "text": "Paris"], "model": "m"],
                    "workspace": ["roots": [["uri": "file:///a"]]],
                    "unexpected": ["ignored": true],
                ],
            ])
        #expect(second.firstText == "Ada|Paris|1")
    }

    @Test func multipleRoundsCarryEarlierAnswersInState() async throws {
        let started = Counter()
        let client = TestClient(try makeServer(started: started), capabilities: capabilities)
        let first = try #require(try await client.request("tools/call", ["name": "two_rounds"]).result)
        #expect(first["inputRequests"]?.objectValue?.map(\.key) == ["name"])
        let second = try #require(
            try await client.request(
                "tools/call",
                ["name": "two_rounds", "requestState": first["requestState"]!, "inputResponses": ["name": elicited(["name": "Ada"])]]
            ).result)
        #expect(second["resultType"] == "input_required")
        #expect(second["inputRequests"]?.objectValue?.map(\.key) == ["color"])
        #expect(second["requestState"] != first["requestState"])
        // The client returns only this round's answer; the first one travels in requestState.
        let third = try await client.request(
            "tools/call",
            ["name": "two_rounds", "requestState": second["requestState"]!, "inputResponses": ["color": elicited(["color": "teal"])]])
        #expect(third.firstText == "Ada likes teal")
        #expect(started.count == 3)
    }

    @Test func missingAnswerIsAskedAgain() async throws {
        let client = TestClient(try makeServer(), capabilities: capabilities)
        let result = try #require(
            try await client.request("tools/call", ["name": "greet", "inputResponses": ["wrong_key": elicited(["name": "x"])]]).result)
        #expect(result["resultType"] == "input_required")
        #expect(result["inputRequests"]?["user_name"] != nil)
    }

    @Test func tamperedOrMisusedStateIsRejected() async throws {
        let client = TestClient(try makeServer(), capabilities: capabilities)
        let first = try #require(try await client.request("tools/call", ["name": "two_rounds"]).result)
        let state = try #require(first["requestState"]?.stringValue)
        var tampered = Array(state.utf8)
        tampered[tampered.count / 2] = tampered[tampered.count / 2] == 0x41 ? 0x42 : 0x41
        for bad in [String(decoding: tampered, as: UTF8.self), "not-a-state", ""] {
            let response = try await client.request("tools/call", ["name": "two_rounds", "requestState": .string(bad), "inputResponses": [:]])
            #expect(response.errorCode == -32602, "\(bad.prefix(12))")
        }
        // Valid state, different request: refused.
        #expect(try await client.request("tools/call", ["name": "greet", "requestState": .string(state)]).errorCode == -32602)
        #expect(try await client.request("tools/call", ["name": "two_rounds", "requestState": 5]).errorCode == -32602)
    }

    @Test func expiredStateIsRejected() async throws {
        // Born expired.
        let client = TestClient(try makeServer { $0.requestStateLifetimeSeconds = -1 }, capabilities: capabilities)
        let first = try #require(try await client.request("tools/call", ["name": "two_rounds"]).result)
        let response = try await client.request(
            "tools/call", ["name": "two_rounds", "requestState": first["requestState"]!, "inputResponses": ["name": elicited([:])]])
        #expect(response.errorCode == -32602)

        // Valid when issued, expired later: the case a client actually meets.
        let lifetime = 2
        let later = TestClient(try makeServer { $0.requestStateLifetimeSeconds = lifetime }, capabilities: capabilities)
        let clock = ContinuousClock()
        let issuedAfter = clock.now
        let issued = try #require(try await later.request("tools/call", ["name": "two_rounds"]).result)
        let issuedBefore = clock.now
        let retry: JSONObject = ["name": "two_rounds", "requestState": issued["requestState"]!, "inputResponses": ["name": elicited([:])]]
        let fresh = try await later.request("tools/call", retry)
        // Asserted only if this test was not stalled past the lifetime in between.
        if clock.now - issuedAfter < .seconds(lifetime) { #expect(fresh.result?["resultType"] == "input_required") }
        try await Task.sleep(until: issuedBefore + .seconds(lifetime) + .milliseconds(1300), clock: clock)
        #expect(try await later.request("tools/call", retry).errorCode == -32602)
    }

    @Test func missingCapabilityIsReportedWithTheSpecCode() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.request("tools/call", ["name": "greet"])
        #expect(response.errorCode == -32021)
        #expect(response["error"]?["data"]?["requiredCapabilities"]?["elicitation"] != nil)
    }

    @Test func malformedAnswerIsAProtocolError() async throws {
        let client = TestClient(try makeServer(), capabilities: capabilities)
        let response = try await client.request("tools/call", ["name": "greet", "inputResponses": ["user_name": ["action": "maybe"]]])
        #expect(response.errorCode == -32602)
        #expect(try await client.request("tools/call", ["name": "greet", "inputResponses": [1]]).errorCode == -32602)
    }

    @Test func promptsCanAskForInput() async throws {
        let client = TestClient(try makeServer(), capabilities: capabilities)
        let first = try #require(try await client.request("prompts/get", ["name": "ask"]).result)
        #expect(first["resultType"] == "input_required")
        let second = try await client.request(
            "prompts/get",
            ["name": "ask", "requestState": first["requestState"]!, "inputResponses": ["subject": elicited(["subject": "tides"])]])
        #expect(second.result?["messages"]?[0]?["content"]?["text"] == "Tell me about tides")
    }

    @Test func aHandlerCannotSwallowTheEndOfARun() async throws {
        let diagnostics = Mutex<[String]>([])
        let cancelledAfter = Mutex<Bool?>(nil)
        let server = try makeServer { configuration in
            configuration.diagnostics = { line in diagnostics.withLock { $0.append(line) } }
        }
        try server.register(tool: ToolDefinition(name: "swallow_and_report")) { _, context in
            context.progress(1)
            _ = try? await context.elicit("x", message: "X?", schema: ["type": "object", "properties": [:]])
            cancelledAfter.withLock { $0 = Task.isCancelled }
            context.progress(2)
            context.log(.error, "after the input point")
            return .text("must be discarded")
        }
        let client = TestClient(server, capabilities: capabilities)
        let result = try #require(try await client.request("tools/call", ["name": "swallow"]).result)
        #expect(result["resultType"] == "input_required")
        #expect(result["content"] == nil)
        #expect(diagnostics.withLock { $0.contains { $0.contains("swallow") } })

        client.clearReceived()
        let reported = try #require(
            try await client.request(
                "tools/call", ["name": "swallow_and_report"], meta: ["progressToken": "p", MetaKey.logLevel: "debug"]
            ).result)
        #expect(reported["resultType"] == "input_required")
        #expect(reported["content"] == nil)
        #expect(cancelledAfter.withLock { $0 } == true)
        #expect(await client.isSilent(for: .milliseconds(50)))
        // Progress from before the input point is fine; nothing from after it.
        #expect(client.received.map { $0["params"]?["progress"]?.doubleValue } == [1])
        #expect(diagnostics.withLock { $0.contains { $0.contains("swallow_and_report") } })
    }
}

@Suite struct SubscriptionTests {
    @Test func acknowledgmentComesFirstAndNotificationsAreTagged() async throws {
        let server = try makeServer()
        let client = TestClient(server)
        let id = client.post(
            "subscriptions/listen",
            ["notifications": ["toolsListChanged": true, "resourceSubscriptions": ["test://static"]]])
        let acknowledgment = try await client.next()
        #expect(acknowledgment["method"] == "notifications/subscriptions/acknowledged")
        #expect(acknowledgment["params"]?["_meta"]?[MetaKey.subscriptionID] == id.json)
        #expect(acknowledgment["params"]?["notifications"] == ["toolsListChanged": true, "resourceSubscriptions": ["test://static"]])

        try server.register(tool: ToolDefinition(name: "late")) { _, _ in .text("") }
        let changed = try await client.next()
        #expect(changed["method"] == "notifications/tools/list_changed")
        #expect(changed["params"]?["_meta"]?[MetaKey.subscriptionID] == id.json)

        server.notifyResourceUpdated(uri: "test://static")
        let updated = try await client.next()
        #expect(updated["method"] == "notifications/resources/updated")
        #expect(updated["params"]?["uri"] == "test://static")
        #expect(updated["params"]?["_meta"]?[MetaKey.subscriptionID] == id.json)

        // Types the client did not ask for are never sent.
        try server.register(prompt: PromptDefinition(name: "late")) { _, _ in PromptResult(messages: []) }
        server.notifyResourceUpdated(uri: "test://other")
        #expect(await client.isSilent())
    }

    @Test func nothingIsPushedWithoutASubscription() async throws {
        let server = try makeServer()
        let client = TestClient(server)
        _ = try await client.request("tools/list")
        try server.register(tool: ToolDefinition(name: "late")) { _, _ in .text("") }
        #expect(await client.isSilent())
    }

    @Test func clientCancellationEndsTheStreamSilently() async throws {
        let server = try makeServer()
        let client = TestClient(server)
        let id = client.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        _ = try await client.next()
        client.notify("notifications/cancelled", ["requestId": id.json])
        try server.register(tool: ToolDefinition(name: "late")) { _, _ in .text("") }
        #expect(await client.isSilent())
    }

    @Test func serverTeardownIsSignalled() async throws {
        let client = TestClient(try makeServer())
        let id = client.post("subscriptions/listen", ["notifications": ["promptsListChanged": true]])
        _ = try await client.next()
        await client.close(graceSeconds: 0.1)
        let cancelled = try await client.next()
        #expect(cancelled["method"] == "notifications/cancelled")
        #expect(cancelled["params"]?["requestId"] == id.json)
        let result = try await client.next()
        #expect(result["id"] == id.json)
        #expect(result.result?["resultType"] == "complete")
        #expect(result.result?["_meta"]?[MetaKey.subscriptionID] == id.json)
    }

    @Test func subscriptionBudget() async throws {
        let client = TestClient(try makeServer { $0.budgets.maxSubscriptions = 2 })
        for _ in 0..<2 {
            client.post("subscriptions/listen", ["notifications": [:]])
            _ = try await client.next()
        }
        #expect(try await client.request("subscriptions/listen", ["notifications": [:]]).errorCode == MCPError.Code.overloaded)
        #expect(try await client.request("subscriptions/listen", [:]).errorCode == -32602)
    }
}
