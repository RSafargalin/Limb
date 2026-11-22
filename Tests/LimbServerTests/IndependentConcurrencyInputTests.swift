import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let allInputs: JSONObject = ["elicitation": ["form": [:], "url": [:]], "sampling": [:], "roots": [:]]
private let formSchema: JSONObject = ["type": "object", "properties": ["v": ["type": "string"]]]

private func accepted(_ value: String) -> JSONValue { ["action": "accept", "content": ["v": .string(value)]] }
private func sampled(_ text: String) -> JSONValue {
    ["role": "assistant", "content": ["type": "text", "text": .string(text)], "model": "m"]
}

private func value(_ result: ElicitResult) -> String { result.content?["v"]?.stringValue ?? "-" }

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyModernInputTests {
    private func threeStepServer(runs: ICMeter, diagnostics: ICBox<[String]> = ICBox([])) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
            configuration.budgets.maxQueuedRequests = 10_000  // these tests are not about overload
        }
        try server.register(tool: ToolDefinition(name: "three")) { _, context in
            runs.enter()
            let a = try await context.elicit("a", message: "A?", schema: formSchema)
            let b = try await context.elicit("b", message: "B?", schema: formSchema)
            let c = try await context.elicit("c", message: "C?", schema: formSchema)
            return .text("\(value(a)) \(value(b)) \(value(c))")
        }
        return server
    }

    @Test func theHandlerRunsAgainFromTheStartAndEarlierAnswersTravelInTheState() async throws {
        let runs = ICMeter()
        let wire = ICWire(try threeStepServer(runs: runs), capabilities: allInputs)
        var states: [JSONValue] = []
        var params: JSONObject = ["name": "three"]
        for (round, key) in ["a", "b", "c"].enumerated() {
            let response = try await wire.request("tools/call", params)
            let result = try #require(response["result"])
            #expect(result["resultType"] == "input_required", "round \(round)")
            // Only the missing input is asked for; earlier answers are not asked again.
            #expect(result["inputRequests"]?.objectValue?.map(\.key) == [key], "round \(round)")
            #expect(result["inputRequests"]?[key]?["method"] == "elicitation/create")
            #expect(result["content"] == nil)
            let state = try #require(result["requestState"])
            #expect(state.stringValue?.isEmpty == false)
            #expect(!states.contains(state))
            states.append(state)
            // The client returns only this round's answer and echoes the state.
            params = ["name": "three", "requestState": state, "inputResponses": [key: accepted(key.uppercased())]]
        }
        let final = try await wire.request("tools/call", params)
        #expect(final["result"]?["resultType"] == "complete")
        #expect(final.independentConcurrencyText == "A B C")
        #expect(runs.total == 4)
        // Modern servers never write JSON-RPC requests ("The server MUST NOT write JSON-RPC
        // requests to stdout").
        #expect(!wire.sink.history.compactMap(\.json).contains { $0["method"] != nil && $0["id"] != nil })

        // An older state knows fewer answers: the missing one is asked for again, not failed.
        let stale = try await wire.request(
            "tools/call", ["name": "three", "requestState": states[1], "inputResponses": ["c": accepted("C")]])
        #expect(stale["result"]?["resultType"] == "input_required")
        #expect(stale["result"]?["inputRequests"]?.objectValue?.map(\.key) == ["b"])
    }

    /// "do not by themselves guarantee single-use": a state may be presented again, and the same
    /// request with the same answers must give the same result every time.
    @Test func replayingTheSameRoundIsDeterministic() async throws {
        let runs = ICMeter()
        let wire = ICWire(try threeStepServer(runs: runs), capabilities: allInputs)
        let first = try await wire.request("tools/call", ["name": "three"])
        let state1 = try #require(first["result"]?["requestState"])
        let second = try await wire.request(
            "tools/call", ["name": "three", "requestState": state1, "inputResponses": ["a": accepted("A")]])
        let state2 = try #require(second["result"]?["requestState"])
        let third = try await wire.request(
            "tools/call", ["name": "three", "requestState": state2, "inputResponses": ["b": accepted("B")]])
        let state3 = try #require(third["result"]?["requestState"])

        var ids: [RequestID] = []
        for _ in 0..<60 {
            ids.append(wire.post("tools/call", ["name": "three", "requestState": state3, "inputResponses": ["c": accepted("C")]]))
            ids.append(wire.post("tools/call", ["name": "three", "requestState": state2, "inputResponses": ["b": accepted("B")]]))
        }
        var finals = 0
        var intermediates = 0
        for _ in ids {
            let message = try await wire.next()
            if message["result"]?["resultType"] == "complete" {
                #expect(message.independentConcurrencyText == "A B C")
                finals += 1
            } else {
                #expect(message["result"]?["inputRequests"]?.objectValue?.map(\.key) == ["c"])
                intermediates += 1
            }
        }
        #expect(finals == 60)
        #expect(intermediates == 60)
    }

    @Test func severalInputsOfDifferentKindsAndPartialAnswers() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "gather")) { _, context in
            let answers = try await context.input([
                "who": .elicit(ElicitRequest(message: "Who?", requestedSchema: formSchema)),
                "where": .elicit(ElicitRequest(message: "Sign in", url: "https://example.com/login")),
                "capital": .sample(SamplingRequest(prompt: "Capital of France?", maxTokens: 10)),
                "workspace": .roots,
            ])
            guard case .elicit(let who) = answers["who"], case .elicit(let place) = answers["where"],
                case .sample(let capital) = answers["capital"], case .roots(let roots) = answers["workspace"]
            else { return .error("incomplete") }
            return .text("\(value(who))|\(place.action.rawValue)|\(capital.text ?? "?")|\(roots.map(\.uri).joined(separator: ","))")
        }
        let wire = ICWire(server, capabilities: allInputs)
        let first = try #require(try await wire.request("tools/call", ["name": "gather"])["result"])
        #expect(first["resultType"] == "input_required")
        let requests = try #require(first["inputRequests"]?.objectValue)
        #expect(Set(requests.map(\.key)) == ["who", "where", "capital", "workspace"])
        #expect(requests["who"]?["method"] == "elicitation/create")
        #expect(requests["who"]?["params"]?["mode"] == "form")
        #expect(requests["where"]?["params"]?["mode"] == "url")
        #expect(requests["where"]?["params"]?["url"] == "https://example.com/login")
        #expect(requests["capital"]?["method"] == "sampling/createMessage")
        #expect(requests["workspace"]?["method"] == "roots/list")

        // The client answers two of four. "the server SHOULD respond with a new InputRequiredResult
        // requesting the missing information again, rather than returning an error."
        let second = try #require(
            try await wire.request(
                "tools/call",
                [
                    "name": "gather", "requestState": first["requestState"]!,
                    "inputResponses": ["who": accepted("Ada"), "capital": sampled("Paris"), "stray": ["x": 1]],
                ])["result"])
        #expect(second["resultType"] == "input_required")
        #expect(Set(second["inputRequests"]?.objectValue?.map(\.key) ?? []) == ["where", "workspace"])

        // The remaining two; the first two are not sent again, they travel in the state.
        let third = try await wire.request(
            "tools/call",
            [
                "name": "gather", "requestState": second["requestState"]!,
                "inputResponses": ["where": ["action": "decline"], "workspace": ["roots": [["uri": "file:///a"], ["uri": "file:///b"]]]],
            ])
        #expect(third["result"]?["resultType"] == "complete")
        #expect(third.independentConcurrencyText == "Ada|decline|Paris|file:///a,file:///b")
    }

    @Test func resourcesAndPromptsMayAskButOtherMethodsMayNot() async throws {
        let server = independentConcurrencyServer()
        try server.register(resource: ResourceDefinition(uri: "ic://asks", name: "asks")) { request, context in
            let answer = try await context.elicit("k", message: "?", schema: formSchema)
            return [.text(uri: request.uri, text: value(answer))]
        }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "ic://item/{id}", name: "item"), complete: { _, context in
            _ = try await context.elicit("k", message: "?", schema: formSchema)
            return CompletionResult(values: ["never"])
        }) { request, context in
            let answer = try await context.elicit("k", message: "?", schema: formSchema)
            return [.text(uri: request.uri, text: (request.variables["id"] ?? "") + value(answer))]
        }
        try server.register(method: "custom/asks") { _, context in
            _ = try await context.elicit("k", message: "?", schema: formSchema)
            return ["never": true]
        }
        let wire = ICWire(server, capabilities: allInputs)
        for uri in ["ic://asks", "ic://item/7"] {
            let first = try #require(try await wire.request("resources/read", ["uri": .string(uri)])["result"])
            #expect(first["resultType"] == "input_required")
            let second = try await wire.request(
                "resources/read", ["uri": .string(uri), "requestState": first["requestState"]!, "inputResponses": ["k": accepted("!")]])
            #expect(second["result"]?["resultType"] == "complete")
            #expect(second["result"]?["contents"]?[0]?["text"] == (uri == "ic://asks" ? "!" : "7!"))
        }
        // "Servers MUST NOT send InputRequiredResult responses on any other client requests."
        let completion = try await wire.request(
            "completion/complete", ["ref": ["type": "ref/resource", "uri": "ic://item/{id}"], "argument": ["name": "id", "value": ""]])
        #expect(completion["result"]?["resultType"] != "input_required")
        #expect(completion.independentConcurrencyErrorCode != nil)
        let custom = try await wire.request("custom/asks")
        #expect(custom["result"]?["resultType"] != "input_required")
        #expect(custom.independentConcurrencyErrorCode != nil)
    }

    /// "Servers MUST NOT send an `inputRequests` that the client has not declared support for";
    /// `basic/index.mdx`: the server MUST return `-32021` whose `data.requiredCapabilities` lists
    /// the missing capabilities.
    @Test func missingClientCapabilityIsReportedAndNeverAsked() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "ask")) { arguments, context in
            switch arguments["kind"]?.stringValue {
            case "form": _ = try await context.elicit("k", message: "?", schema: formSchema)
            case "url": _ = try await context.elicit("k", message: "?", url: "https://example.com")
            case "sample": _ = try await context.sample("k", SamplingRequest(prompt: "?", maxTokens: 1))
            case "roots": _ = try await context.roots("k")
            case "group":
                _ = try await context.input([
                    "form": .elicit(ElicitRequest(message: "?", requestedSchema: formSchema)), "roots": .roots,
                ])
            default: break
            }
            return .text("asked")
        }
        try server.register(tool: ToolDefinition(name: "fallback")) { _, context in
            do {
                _ = try await context.roots("k")
                return .text("roots")
            } catch let error as MCPError {
                return .text("fallback after \(error.code)")
            }
        }
        let cases: [(capabilities: JSONObject, kind: String, missing: String?)] = [
            ([:], "form", "elicitation"), ([:], "url", "elicitation"), ([:], "sample", "sampling"), ([:], "roots", "roots"),
            (["elicitation": [:]], "form", nil),  // an empty object means form mode
            (["elicitation": [:]], "url", "elicitation"),
            (["elicitation": ["url": [:]]], "form", "elicitation"),
            (["elicitation": ["url": [:]]], "url", nil),
            (["elicitation": ["form": [:]], "sampling": [:]], "roots", "roots"),
            (["elicitation": ["form": [:]]], "group", "roots"),
            (["roots": [:]], "group", "elicitation"),
        ]
        for (capabilities, kind, missing) in cases {
            let wire = ICWire(server, capabilities: capabilities)
            let response = try await wire.request("tools/call", ["name": "ask", "arguments": ["kind": .string(kind)]])
            if let missing {
                #expect(response.independentConcurrencyErrorCode == -32021, "\(kind) with \(capabilities)")
                #expect(response["error"]?["data"]?["requiredCapabilities"]?[missing] != nil, "\(kind) with \(capabilities)")
                #expect(response["result"] == nil)
            } else {
                #expect(response["result"]?["resultType"] == "input_required", "\(kind) with \(capabilities)")
            }
        }
        // The handler may treat the refusal as a signal to do without.
        let wire = ICWire(server)
        #expect(try await wire.request("tools/call", ["name": "fallback"]).independentConcurrencyText == "fallback after -32021")
    }

    @Test func answersThatDoNotFitTheRequestAreProtocolErrors() async throws {
        let runs = ICMeter()
        let wire = ICWire(try threeStepServer(runs: runs), capabilities: allInputs)
        let malformed: [JSONValue] = [
            ["a": ["action": "perhaps"]], ["a": "yes"], ["a": 5], ["a": ["content": ["v": "x"]]], [1, 2], "text", 7, true,
        ]
        for responses in malformed {
            let response = try await wire.request("tools/call", ["name": "three", "inputResponses": responses])
            #expect(response.independentConcurrencyErrorCode == -32602, "\(responses)")
        }
    }


    private func swallowingServer(
        after: ICBox<Bool?>, diagnostics: ICBox<[String]>
    ) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
        }
        try server.register(tool: ToolDefinition(name: "swallow_me")) { _, context in
            context.progress(1)
            _ = try? await context.elicit("k", message: "?", schema: formSchema)
            after.set(Task.isCancelled)
            context.progress(2)
            context.log(.error, "after the input point")
            return .text("must be discarded")
        }
        return server
    }

    /// Guarantee (1): exactly one response, the `InputRequiredResult`; "всё, что обработчик вернёт
    /// или выведет после точки ввода (результат, progress, журнал), отбрасывается".
    @Test func outputAfterASwallowedInputPointIsDiscarded() async throws {
        let wire = ICWire(try swallowingServer(after: ICBox(nil), diagnostics: ICBox([])), capabilities: allInputs)
        let id = wire.call("swallow_me", meta: ["progressToken": "t", MetaKey.logLevel: "debug"])
        let response = try await wire.response(to: id)
        #expect(response["result"]?["resultType"] == "input_required")
        #expect(response["result"]?["content"] == nil)
        #expect(await wire.isSilent(for: .milliseconds(50)))
        let before = wire.others
        // Progress reported before the input point is fine; nothing after it may be sent.
        #expect(before.filter { $0["method"] == "notifications/progress" }.map { $0["params"]?["progress"]?.doubleValue } == [1])
        #expect(!before.contains { $0["method"] == "notifications/message" }, "a log message written after the input point was sent")
        #expect(wire.sink.history.count == 2)
    }

    /// Guarantee (2): "задача обработчика отменяется".
    @Test func theHandlerTaskIsCancelledAtASwallowedInputPoint() async throws {
        let after = ICBox<Bool?>(nil)
        let wire = ICWire(try swallowingServer(after: after, diagnostics: ICBox([])), capabilities: allInputs)
        _ = try await wire.request("tools/call", ["name": "swallow_me"])
        #expect(after.value == true, "the handler kept running uncancelled after its run had ended")
    }

    #if DEBUG
    /// Guarantee (3): in a debug build "проглоченная остановка даёт диагностику с именем инструмента".
    @Test func aSwallowedInputPointIsDiagnosedByToolName() async throws {
        let diagnostics = ICBox<[String]>([])
        let client = TestClient(try swallowingServer(after: ICBox(nil), diagnostics: diagnostics), capabilities: allInputs)
        _ = try await client.request("tools/call", ["name": "swallow_me"])
        #expect(diagnostics.value.contains { $0.contains("swallow_me") }, "no diagnostic names the tool; got \(diagnostics.value)")
    }
    #endif
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyLegacyInputTests {
    private func makeServer(configure: (inout ServerConfiguration) -> Void = { _ in }) throws -> Server {
        let server = independentConcurrencyServer(configure)
        try server.register(tool: ToolDefinition(name: "ask")) { arguments, context in
            let answer = try await context.elicit("k", message: arguments["q"]?.stringValue ?? "?", schema: formSchema)
            return .text("answer: \(answer.action.rawValue) \(value(answer))")
        }
        try server.register(tool: ToolDefinition(name: "group")) { _, context in
            let answers = try await context.input([
                "first": .elicit(ElicitRequest(message: "first", requestedSchema: formSchema)),
                "second": .elicit(ElicitRequest(message: "second", requestedSchema: formSchema)),
                "model": .sample(SamplingRequest(prompt: "model", maxTokens: 5)),
                "roots": .roots,
            ])
            guard case .elicit(let first) = answers["first"], case .elicit(let second) = answers["second"],
                case .sample(let model) = answers["model"], case .roots(let roots) = answers["roots"]
            else { return .error("incomplete") }
            return .text("\(value(first))|\(value(second))|\(model.text ?? "?")|\(roots.count)")
        }
        return server
    }

    private func connect(_ server: Server, version: ProtocolVersion = .v2025_11_25, capabilities: JSONObject = allInputs) async throws -> ICWire {
        let wire = ICWire(server, modern: false)
        try await wire.initialize(version: version, capabilities: capabilities)
        return wire
    }

    private func reply(_ wire: ICWire, to request: JSONValue, _ result: JSONValue) {
        wire.send(["jsonrpc": "2.0", "id": request["id"]!, "result": result])
    }

    @Test func answersAreCorrelatedByIdWhateverTheirOrder() async throws {
        let wire = try await connect(try makeServer())
        let call = wire.call("group")
        var requests: [JSONValue] = []
        for _ in 0..<4 { requests.append(try await wire.next()) }
        // Four real requests with distinct ids, all sent before any answer.
        #expect(Set(requests.map { $0["id"] }).count == 4)
        #expect(requests.allSatisfy { $0["id"] != nil && $0["method"] != nil })
        #expect(
            Set(requests.map { $0["method"]?.stringValue })
                == ["elicitation/create", "sampling/createMessage", "roots/list"])
        // Answer in an order unrelated to the order of the requests.
        for request in requests.reversed() {
            switch request["method"]?.stringValue {
            case "elicitation/create":
                reply(wire, to: request, accepted("reply to \(request["params"]?["message"]?.stringValue ?? "?")"))
            case "sampling/createMessage": reply(wire, to: request, sampled("sampled"))
            default: reply(wire, to: request, ["roots": [["uri": "file:///a"], ["uri": "file:///b"], ["uri": "file:///c"]]])
            }
        }
        let response = try await wire.response(to: call)
        #expect(response.independentConcurrencyText == "reply to first|reply to second|sampled|3")
        #expect(await wire.isSilent())
    }

    @Test func concurrentCallsEachGetTheirOwnAnswers() async throws {
        let wire = try await connect(try makeServer())
        let count = 40
        var calls: [RequestID: String] = [:]
        for index in 0..<count { calls[wire.call("ask", ["q": .string("q\(index)")])] = "q\(index)" }
        var requests: [JSONValue] = []
        for _ in 0..<32 { requests.append(try await wire.next()) }  // 32 handlers run at once
        #expect(Set(requests.map { $0["id"] }).count == 32)
        var answered = 0
        var pending = requests.shuffled()
        while answered < count {
            if let request = pending.popLast() {
                reply(wire, to: request, accepted("to " + (request["params"]?["message"]?.stringValue ?? "?")))
            }
            let message = try await wire.next()
            if message["method"] == "elicitation/create" {
                pending.append(message)
                continue
            }
            let id = try #require(message["id"].flatMap(RequestID.init(json:)))
            let question = try #require(calls[id])
            #expect(message.independentConcurrencyText == "answer: accept to \(question)")
            answered += 1
        }
        #expect(await wire.isSilent())
    }

    /// The two directions number their requests independently, so the same id is in flight both
    /// ways. Nothing may be confused by that.
    @Test func equalIdsInTheTwoDirectionsDoNotCollide() async throws {
        let wire = try await connect(try makeServer())
        // The first server request of a connection, and the client's own request, share an id.
        let probe = wire.call("ask", ["q": "probe"], id: "probe")
        let probeRequest = try await wire.next()
        let serverID = try #require(probeRequest["id"].flatMap(RequestID.init(json:)))
        reply(wire, to: probeRequest, accepted("x"))
        _ = try await wire.response(to: probe)
        guard case .number = serverID, let number = serverID.json.intValue else {
            Issue.record("server request ids are expected to be integers, got \(serverID)")
            return
        }
        // Use, as the client's ids, exactly the ids the server will use next.
        let callA = wire.call("ask", ["q": "A"], id: RequestID(number + 1))
        let requestA = try await wire.next()
        #expect(requestA["id"] == JSONValue(number + 1))
        let callB = wire.call("ask", ["q": "B"], id: RequestID(number + 2))
        let requestB = try await wire.next()
        #expect(requestB["id"] == JSONValue(number + 2))
        // A cancellation from the client names the client's request, not the server's.
        wire.cancel(callA)
        let cancelled = try await wire.next()
        #expect(cancelled["method"] == "notifications/cancelled")
        #expect(cancelled["params"]?["requestId"] == requestA["id"])
        // A reply from the client names the server's request, not the client's.
        reply(wire, to: requestB, accepted("b"))
        let response = try await wire.next()
        #expect(response["id"] == callB.json)
        #expect(response["method"] == nil)
        #expect(response.independentConcurrencyText == "answer: accept b")
        // A late answer to the cancelled server request changes nothing.
        reply(wire, to: requestA, accepted("late"))
        #expect(await wire.isSilent(for: .milliseconds(100)))
    }

    @Test func duplicateUnknownAndLateAnswersAreIgnored() async throws {
        let wire = try await connect(try makeServer())
        // Answers to requests the server never sent.
        wire.send(#"{"jsonrpc":"2.0","id":1,"result":{"action":"accept"}}"#)
        wire.send(#"{"jsonrpc":"2.0","id":999999,"result":{}}"#)
        wire.send(#"{"jsonrpc":"2.0","id":"1","result":{}}"#)
        wire.send(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nobody asked"}}"#)
        #expect(await wire.isSilent(for: .milliseconds(50)))

        let call = wire.call("ask")
        let request = try await wire.next()
        // An answer under a string spelling of the id is not an answer to the numeric id.
        if let number = request["id"]?.intValue {
            wire.send(["jsonrpc": "2.0", "id": .string("\(number)"), "result": accepted("wrong id type")])
            #expect(await wire.isSilent(for: .milliseconds(50)))
        }
        reply(wire, to: request, accepted("first"))
        reply(wire, to: request, accepted("second"))
        reply(wire, to: request, accepted("third"))
        let response = try await wire.response(to: call)
        #expect(response.independentConcurrencyText == "answer: accept first")
        reply(wire, to: request, accepted("after the call ended"))
        #expect(await wire.isSilent(for: .milliseconds(80)))
    }

    @Test func aClientErrorReachesTheHandlerAndCancelsTheSiblingRequests() async throws {
        let server = try makeServer()
        try server.register(tool: ToolDefinition(name: "careful")) { _, context in
            do {
                _ = try await context.elicit("k", message: "?", schema: formSchema)
                return .text("answered")
            } catch let error as MCPError {
                return .text("client said \(error.code): \(error.message)")
            }
        }
        let wire = try await connect(server)
        // A handler can see and handle the client's error.
        let careful = wire.call("careful")
        let request = try await wire.next()
        wire.send(["jsonrpc": "2.0", "id": request["id"]!, "error": ["code": -1, "message": "User rejected"]])
        #expect(try await wire.response(to: careful).independentConcurrencyText == "client said -1: User rejected")

        // In a group, one failure ends the group: the others are withdrawn from the client.
        let call = wire.call("group")
        var requests: [JSONValue] = []
        for _ in 0..<4 { requests.append(try await wire.next()) }
        let failed = requests[1]
        wire.send(["jsonrpc": "2.0", "id": failed["id"]!, "error": ["code": -32603, "message": "client broke"]])
        var cancelled: Set<JSONValue> = []
        var response: JSONValue?
        for _ in 0..<4 {
            let message = try await wire.next()
            if message["method"] == "notifications/cancelled" {
                cancelled.insert(message["params"]?["requestId"] ?? .null)
            } else {
                response = message
            }
        }
        // Exactly one response to the call, and it is a failure, not a success.
        let answer = try #require(response)
        #expect(answer["id"] == call.json)
        #expect(answer.independentConcurrencyErrorCode != nil || answer["result"]?["isError"] == true)
        #expect(cancelled == Set(requests.filter { $0["id"] != failed["id"] }.map { $0["id"]! }))
        // Late answers to the withdrawn requests are ignored.
        for request in requests { reply(wire, to: request, accepted("late")) }
        #expect(await wire.isSilent(for: .milliseconds(80)))
    }

    @Test func aMalformedAnswerFailsTheCallAsAServerError() async throws {
        let wire = try await connect(try makeServer())
        let call = wire.call("ask")
        let request = try await wire.next()
        reply(wire, to: request, ["action": "sideways"])
        let response = try await wire.response(to: call)
        #expect(response.independentConcurrencyErrorCode == -32603)
        #expect(await wire.isSilent())
    }

    /// A reply that is not a valid response object (`error` is not an object) is the client's
    /// mistake about a *server* request. Whatever the server does with it, the client's own
    /// request with the same id must still get exactly one response: JSON-RPC answers requests,
    /// not responses.
    @Test func anInvalidReplyDoesNotProduceASecondResponseUnderTheClientsRequestId() async throws {
        let wire = try await connect(try makeServer())
        // Find the id the server will use, then make the client's own call under the same id.
        let probe = wire.call("ask", id: "probe")
        let probeRequest = try await wire.next()
        let number = try #require(probeRequest["id"]?.intValue)
        reply(wire, to: probeRequest, accepted("x"))
        _ = try await wire.response(to: probe)

        let call = wire.call("ask", id: RequestID(number + 1))
        let request = try await wire.next()
        #expect(request["id"] == JSONValue(number + 1))
        let mark = wire.sink.mark
        wire.send(#"{"jsonrpc":"2.0","id":\#(number + 1),"error":"the user closed the dialog"}"#)
        wire.send(#"{"jsonrpc":"2.0","id":\#(number + 1)}"#)
        try? await Task.sleep(for: .milliseconds(50))
        reply(wire, to: request, accepted("finally"))
        try? await Task.sleep(for: .milliseconds(100))
        let responses = wire.sink.history.filter { record in
            record.index >= mark && record.json?["method"] == nil && record.json?["id"] == call.json
        }
        #expect(
            responses.count == 1,
            "the client's request \(call) received \(responses.count) responses: \(responses.map(\.text))")
    }

    @Test func cancellingACallThatWaitsForTheClientWithdrawsTheRequestAndAnswersNothing() async throws {
        let server = try makeServer()
        let retried = ICBox<String?>(nil)
        try server.register(tool: ToolDefinition(name: "retries")) { _, context in
            do {
                _ = try await context.elicit("k", message: "first try", schema: formSchema)
            } catch {
                // Ignores the cancellation and asks again.
                do {
                    _ = try await context.elicit("k2", message: "second try", schema: formSchema)
                    retried.set("asked again")
                } catch {
                    retried.set("refused: \(type(of: error))")
                }
            }
            return .text("done anyway")
        }
        let wire = try await connect(server)
        let call = wire.call("retries")
        let request = try await wire.next()
        #expect(request["params"]?["message"] == "first try")
        wire.cancel(call)
        let cancelled = try await wire.next()
        // Legacy revisions let either side cancel its own requests.
        #expect(cancelled["method"] == "notifications/cancelled")
        #expect(cancelled["params"]?["requestId"] == request["id"])
        #expect(await independentConcurrencyEventually { retried.value != nil })
        // The second request is never sent, and the cancelled call is never answered.
        #expect(retried.value == "refused: CancellationError")
        #expect(await wire.isSilent(for: .milliseconds(100)))
        #expect(wire.framesSent(for: call).isEmpty)
    }

    /// `Connection`: "Nothing is sent for a cancelled request. Every frame that belongs to a
    /// request is queued under the same lock that cancellation takes". A request to the client
    /// made through the context of a cancelled request belongs to that request.
    @Test func noRequestGoesToTheClientOnBehalfOfACancelledCall() async throws {
        let gate = ICGate()
        let outcome = ICBox<String?>(nil)
        let server = try makeServer()
        try server.register(tool: ToolDefinition(name: "detached")) { _, context in
            await gate.wait()
            // Work moved to an unstructured task does not see the request's cancellation.
            let task = Task.detached {
                do {
                    _ = try await context.elicit("k", message: "from a cancelled call", schema: formSchema)
                    outcome.set("answered")
                } catch {
                    outcome.set("refused")
                }
            }
            await task.value
            return .text("late")
        }
        let wire = try await connect(server)
        let call = wire.call("detached")
        wire.cancel(call)
        let mark = wire.sink.mark
        gate.open()
        let leaked = await wire.sink.next(timeout: .milliseconds(200))
        let leakedText = leaked?.text
        #expect(leakedText == nil, "a frame was sent on behalf of a cancelled call")
        if let leaked, let id = leaked.json?["id"] {
            // Let the handler finish so nothing is left suspended.
            wire.send(["jsonrpc": "2.0", "id": id, "result": accepted("x")])
        }
        #expect(await independentConcurrencyEventually(timeout: .seconds(5)) { outcome.value != nil })
        #expect(wire.sink.history.count == mark)
    }

    @Test func noRequestIsSentWithoutTheClientsCapability() async throws {
        let server = try makeServer()
        try server.register(tool: ToolDefinition(name: "probe")) { arguments, context in
            do {
                switch arguments["kind"]?.stringValue {
                case "url": _ = try await context.elicit("k", message: "?", url: "https://example.com")
                case "sample": _ = try await context.sample("k", SamplingRequest(prompt: "?", maxTokens: 1))
                case "roots": _ = try await context.roots("k")
                default: _ = try await context.elicit("k", message: "?", schema: formSchema)
                }
                return .text("asked")
            } catch let error as InputUnavailable {
                return .text("unavailable: \(error.capability)")
            }
        }
        try server.register(prompt: PromptDefinition(name: "asks")) { _, context in
            _ = try await context.elicit("k", message: "?", schema: formSchema)
            return PromptResult(messages: [])
        }
        let cases: [(version: ProtocolVersion, capabilities: JSONObject, kind: String, sent: Bool)] = [
            (.v2025_11_25, [:], "form", false), (.v2025_11_25, [:], "sample", false), (.v2025_11_25, [:], "roots", false),
            (.v2025_11_25, ["elicitation": ["form": [:]]], "url", false),
            (.v2025_11_25, ["elicitation": ["url": [:]]], "form", false),
            (.v2025_11_25, ["elicitation": ["url": [:]]], "url", true),
            (.v2025_11_25, ["elicitation": [:]], "form", true),
            // URL mode does not exist before 2025-11-25, elicitation not before 2025-06-18.
            (.v2025_06_18, ["elicitation": ["url": [:], "form": [:]]], "url", false),
            (.v2025_06_18, ["elicitation": [:]], "form", true),
            (.v2025_03_26, allInputs, "form", false),
            (.v2025_03_26, allInputs, "sample", true),
            (.v2025_03_26, allInputs, "roots", true),
        ]
        for (version, capabilities, kind, sent) in cases {
            let wire = try await connect(server, version: version, capabilities: capabilities)
            let call = wire.call("probe", ["kind": .string(kind)])
            let first = try await wire.next()
            if sent {
                #expect(first["method"] != nil && first["id"] != nil, "\(version) \(kind) \(capabilities)")
                wire.cancel(call)
            } else {
                // "Servers MUST NOT send elicitation requests with modes that are not supported by the client."
                #expect(first["id"] == call.json, "\(version) \(kind) \(capabilities): \(first)")
                #expect(first.independentConcurrencyText?.hasPrefix("unavailable") == true, "\(version) \(kind)")
            }
        }
        // Left unhandled, the refusal is an execution error for a tool and a protocol error elsewhere.
        let wire = try await connect(server, capabilities: [:])
        let tool = try await wire.request("tools/call", ["name": "ask"])
        #expect(tool["result"]?["isError"] == true)
        let prompt = try await wire.request("prompts/get", ["name": "asks"])
        #expect(prompt.independentConcurrencyErrorCode != nil)
        #expect(!wire.sink.history.compactMap(\.json).contains { $0["method"] == "elicitation/create" })
    }

    @Test func serialModeDoesNotDeadlockOnInput() async throws {
        let wire = try await connect(try makeServer { $0.execution = .serial })
        let first = wire.call("ask", ["q": "one"])
        let second = wire.call("ask", ["q": "two"])
        let request = try await wire.next()
        #expect(request["params"]?["message"] == "one")
        // The second handler has not started: its question is not on the wire yet.
        #expect(await wire.isSilent(for: .milliseconds(50)))
        reply(wire, to: request, accepted("1"))
        var seen: [JSONValue] = []
        for _ in 0..<2 { seen.append(try await wire.next()) }
        let next = try #require(seen.first { $0["method"] == "elicitation/create" })
        #expect(seen.contains { $0["id"] == first.json && $0["method"] == nil })
        #expect(next["params"]?["message"] == "two")
        reply(wire, to: next, accepted("2"))
        #expect(try await wire.response(to: second).independentConcurrencyText == "answer: accept 2")
    }
}
