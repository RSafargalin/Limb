import Limb
import LimbTesting
import Testing

@Suite struct ErrorTests {
    @Test func malformedInput() async throws {
        let client = TestClient(try makeServer())
        client.send("{not json")
        let parse = try await client.next()
        #expect(parse.errorCode == -32700)
        #expect(parse["id"] == .null)

        client.send(#"{"jsonrpc":"1.0","id":4,"method":"ping"}"#)
        let version = try await client.next()
        #expect(version.errorCode == -32600)
        #expect(version["id"] == 4)

        client.send(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        #expect(try await client.next().errorCode == -32600)
        client.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":[1]}"#)
        #expect(try await client.next().errorCode == -32602)
        client.send(#""just a string""#)
        #expect(try await client.next().errorCode == -32600)
        client.send(#"{"jsonrpc":"2.0","id":6,"method":"a","id":7}"#)
        #if !FoundationJSON
        #expect(try await client.next().errorCode == -32700)
        #else
        // The fallback codec cannot detect a repeated key: the message is not a parse error. It is
        // answered under one of the two ids, the way the same request with a single id is.
        let repeated = try await client.next()
        client.send(#"{"jsonrpc":"2.0","id":6,"method":"a"}"#)
        let single = try await client.next()
        #expect(repeated.errorCode != -32700)
        #expect(repeated.errorCode != nil && repeated.errorCode == single.errorCode)
        #expect(repeated["id"] == 6 || repeated["id"] == 7)
        #endif
    }

    @Test func toolFailures() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.request("tools/call", ["name": "missing"]).errorCode == -32602)
        #expect(try await client.request("tools/call", [:]).errorCode == -32602)
        #expect(try await client.request("tools/call", ["name": "echo", "arguments": [1]]).errorCode == -32602)

        let failed = try await client.request("tools/call", ["name": "fail"])
        #expect(failed.result?["isError"] == true)
        #expect(failed.firstText == "the disk is full")

        // An unexpected error is a server fault; its details stay with the operator.
        let crashed = try await client.request("tools/call", ["name": "crash"])
        #expect(crashed.errorCode == -32603)
        #expect(crashed["error"]?["message"] == "Internal error")

        #expect(try await client.request("tools/call", ["name": "bad_output"]).errorCode == -32603)
    }

    @Test func stringsAreNeverReinterpreted() async throws {
        let client = TestClient(try makeServer())
        let text = "data:text/plain;base64,aGVsbG8="
        #expect(try await client.request("tools/call", ["name": "echo", "arguments": ["text": .string(text)]]).firstText == text)
    }

    @Test func oversizedResponseIsAnErrorNotATruncation() async throws {
        let client = TestClient(try makeServer { $0.budgets.maxResponseBytes = 10_000 })
        let response = try await client.request("tools/call", ["name": "huge"])
        #expect(response.errorCode == MCPError.Code.responseTooLarge)
    }

    @Test func promptsAndCompletion() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.request("prompts/get", ["name": "summarize"]).errorCode == -32602)
        #expect(try await client.request("prompts/get", ["name": "nope"]).errorCode == -32602)
        let prompt = try #require(try await client.request("prompts/get", ["name": "summarize", "arguments": ["topic": "actors"]]).result)
        #expect(prompt["messages"]?[0]?["content"]?["text"] == "Summarize actors")
        #expect(prompt["description"] == "A summary")

        let completion = try #require(
            try await client.request(
                "completion/complete",
                ["ref": ["type": "ref/prompt", "name": "summarize"], "argument": ["name": "topic", "value": "sw"]]
            ).result?["completion"])
        #expect(completion["values"] == ["swift", "swiftui"])
        #expect(completion["total"] == 3)
        let template = try await client.request(
            "completion/complete",
            ["ref": ["type": "ref/resource", "uri": "test://items/{id}"], "argument": ["name": "id", "value": "3"]])
        #expect(template.result?["completion"]?["values"] == ["30"])
        let none = try await client.request(
            "completion/complete", ["ref": ["type": "ref/prompt", "name": "ask"], "argument": ["name": "x", "value": ""]])
        #expect(none.result?["completion"]?["values"] == [])
    }

    @Test func registrationRejectsWhatCannotBeEnforced() throws {
        let server = try makeServer()
        #expect(throws: RegistrationError.self) { try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("") } }
        #expect(throws: RegistrationError.self) { try server.register(tool: ToolDefinition(name: "has space")) { _, _ in .text("") } }
        #expect(throws: RegistrationError.self) {
            try server.register(tool: ToolDefinition(name: "t1", inputSchema: ["type": "object", "$ref": "https://example.com/schema.json"])) { _, _ in .text("") }
        }
        #expect(throws: RegistrationError.self) {
            try server.register(tool: ToolDefinition(name: "t2", inputSchema: ["type": "object", "unevaluatedProperties": false])) { _, _ in .text("") }
        }
        #expect(throws: RegistrationError.self) {
            try server.register(tool: ToolDefinition(name: "t3", inputSchema: ["type": "array"])) { _, _ in .text("") }
        }
    }
}

@Suite struct CancellationTests {
    @Test func cancellationRightBehindTheRequestIsNeverLost() async throws {
        let observed = Counter()
        var clients: [TestClient] = []
        for _ in 0..<200 {
            let server = try makeServer()
            try server.register(tool: ToolDefinition(name: "sleeper")) { _, _ in
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    observed.increment()
                    throw error
                }
                return .text("never")
            }
            let client = TestClient(server)
            let id = client.post("tools/call", ["name": "sleeper"])
            client.notify("notifications/cancelled", ["requestId": id.json])
            clients.append(client)
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while observed.count < 200, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(observed.count == 200)
        for client in clients { #expect(await client.isSilent(for: .milliseconds(1))) }
    }

    @Test func nothingIsSentAfterCancellation() async throws {
        let gate = Gate()
        let started = Counter()
        let client = TestClient(try makeServer(gate: gate, started: started))
        let id = client.post("tools/call", ["name": "wait"], meta: ["progressToken": 1])
        #expect(try await client.next()["method"] == "notifications/progress")
        client.notify("notifications/cancelled", ["requestId": id.json, "reason": "user"])
        gate.open()
        #expect(await client.isSilent())
    }

    @Test func lateCancellationDoesNotTouchANewRequestWithTheSameId() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.request("tools/call", ["name": "echo", "arguments": ["text": "1"]], id: 9).firstText == "1")
        // The cancellation is for the finished request; no tombstone may survive to kill the next one.
        client.notify("notifications/cancelled", ["requestId": 9])
        #expect(try await client.request("tools/call", ["name": "echo", "arguments": ["text": "2"]], id: 9).firstText == "2")
    }

    @Test func idIsFreeAgainRightAfterCancellation() async throws {
        let client = TestClient(try makeServer())
        client.post("tools/call", ["name": "hang"], id: 5)
        client.notify("notifications/cancelled", ["requestId": 5])
        #expect(try await client.request("tools/call", ["name": "echo", "arguments": ["text": "new"]], id: 5).firstText == "new")
        #expect(await client.isSilent())
    }

    @Test func duplicateIdInFlightIsRejected() async throws {
        let gate = Gate()
        let client = TestClient(try makeServer(gate: gate))
        client.post("tools/call", ["name": "wait"], id: 1)
        client.post("tools/call", ["name": "echo", "arguments": ["text": "x"]], id: 1)
        #expect(try await client.next().errorCode == -32600)
        gate.open()
        #expect(try await client.next().firstText == "released")
    }

    @Test func unknownCancellationsAreIgnored() async throws {
        let client = TestClient(try makeServer())
        client.notify("notifications/cancelled", ["requestId": 404])
        client.notify("notifications/cancelled", [:])
        client.notify("notifications/cancelled", ["requestId": [1]])
        #expect(try await client.request("tools/call", ["name": "echo", "arguments": ["text": "alive"]]).firstText == "alive")
    }
}

@Suite struct AdmissionTests {
    @Test func cheapMethodsDoNotWaitBehindHandlers() async throws {
        let gate = Gate()
        let started = Counter()
        let client = TestClient(try makeServer(gate: gate, started: started) { $0.execution = .serial })
        let blocked = client.post("tools/call", ["name": "wait"])
        // The handler slot is taken, yet discovery and listings answer at once.
        #expect(try await client.request("server/discover").result != nil)
        #expect(try await client.request("tools/list").result != nil)
        gate.open()
        #expect(try await client.response(to: blocked).firstText == "released")
    }

    @Test func serialModeRunsInArrivalOrder() async throws {
        let gate = Gate()
        let client = TestClient(try makeServer(gate: gate) { $0.execution = .serial })
        let first = client.post("tools/call", ["name": "wait"])
        var ids: [RequestID] = []
        for index in 0..<10 {
            ids.append(client.post("tools/call", ["name": "echo", "arguments": ["text": .string("\(index)")]]))
        }
        #expect(await client.isSilent(for: .milliseconds(50)))
        gate.open()
        var order: [JSONValue] = []
        for _ in 0..<11 { order.append(try await client.next()["id"]!) }
        #expect(order == ([first] + ids).map(\.json))
    }

    @Test func overloadIsAnExplicitError() async throws {
        let gate = Gate()
        let client = TestClient(
            try makeServer(gate: gate) {
                $0.budgets.maxConcurrentHandlers = 2
                $0.budgets.maxQueuedRequests = 3
            })
        var ids: [RequestID] = []
        for _ in 0..<5 { ids.append(client.post("tools/call", ["name": "wait"])) }
        let rejected = client.post("tools/call", ["name": "wait"])
        let response = try await client.response(to: rejected)
        #expect(response.errorCode == MCPError.Code.overloaded)
        // Cancellation works under load, and frees the queue slot.
        client.notify("notifications/cancelled", ["requestId": ids[4].json])
        let retried = client.post("tools/call", ["name": "wait"])
        gate.open()
        var answered: Set<JSONValue> = []
        for _ in 0..<5 { answered.insert(try await client.next()["id"]!) }
        #expect(answered == Set((ids.prefix(4) + [retried]).map(\.json)))
    }

    @Test func manyConcurrentCallsAllAnswerOnce() async throws {
        let client = TestClient(try makeServer { $0.budgets.maxQueuedRequests = 5000 })
        let total = 2000
        for index in 0..<total {
            client.post("tools/call", ["name": "echo", "arguments": ["text": .string("m\(index)")]], id: RequestID(index))
        }
        var seen: [Int: String] = [:]
        for _ in 0..<total {
            let message = try await client.next()
            let id = try #require(message["id"]?.intValue)
            #expect(seen[id] == nil)
            seen[id] = message.firstText
        }
        #expect(seen.count == total)
        #expect(seen.allSatisfy { $0.value == "m\($0.key)" })
    }

    @Test func closeWaitsForInFlightThenCancels() async throws {
        let gate = Gate()
        let started = Counter()
        let client = TestClient(try makeServer(gate: gate, started: started))
        let finishing = client.post("tools/call", ["name": "wait"])
        client.post("tools/call", ["name": "hang"])
        // Bounded: a handler that never starts must fail this test, not stall the suite.
        let deadline = ContinuousClock.now + .seconds(30)
        while started.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(started.count == 2)
        gate.open()
        await client.close(graceSeconds: 0.2)
        #expect(try await client.response(to: finishing).firstText == "released")
        #expect(await client.isSilent(for: .milliseconds(50)))
        // New requests after close are not served.
        client.post("tools/call", ["name": "echo", "arguments": ["text": "x"]])
        #expect(await client.isSilent(for: .milliseconds(50)))
    }
}
