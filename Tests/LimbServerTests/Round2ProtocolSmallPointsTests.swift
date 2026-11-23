import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(2)))
struct Round2ProtocolSmallPointsTests {
    private static let meta: JSONObject = ["com.example/trace": "abc", "nested": ["a": [1, 2]]]

    // MARK: _meta on tool results

    private static func metaServer() throws -> Server {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "text")) { _, _ in
            ToolResult(content: [.text("x")], meta: meta)
        }
        try server.register(tool: ToolDefinition(name: "returned-error")) { _, _ in
            ToolResult(content: [.text("bad")], isError: true, meta: meta)
        }
        try server.register(tool: ToolDefinition(name: "thrown-error")) { _, _ in
            throw ToolError("bad", meta: meta)
        }
        try server.register(
            tool: ToolDefinition(name: "structured", outputSchema: ["type": "object", "properties": ["n": ["type": "integer"]], "required": ["n"]])
        ) { _, _ in
            ToolResult(structuredContent: ["n": 1], meta: meta)
        }
        try server.register(tool: ToolDefinition(name: "reserved")) { _, _ in
            ToolResult(content: [.text("x")], meta: ["io.modelcontextprotocol/serverInfo": ["name": "forged", "version": "0"], "k": "v"])
        }
        return server
    }

    /// `CallToolResult extends Result`, and `Result` has `_meta` in every revision: the handler's
    /// `_meta` is the result's `_meta`, on errors and structured results alike.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func toolResultMetaInEveryRevision(revision: IndependentProtocolRevision) async throws {
        let client = try await R2P.client(try Self.metaServer(), revision)
        for name in ["text", "returned-error", "thrown-error", "structured"] {
            let response = try await client.request("tools/call", ["name": .string(name)])
            let result = try #require(response["result"], "\(name): \(response)")
            #expect(result["_meta"]?["com.example/trace"] == "abc", "\(revision) \(name): \(response)")
            #expect(result["_meta"]?["nested"] == ["a": [1, 2]], "\(revision) \(name)")
            #expect(IndependentProtocol.responseViolations(response, to: "tools/call", in: revision) == [], "\(revision) \(name)")
            if name.hasSuffix("error") { #expect(result["isError"] == true) }
            if revision.isModern { #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "r2p") }
        }
    }

    /// A handler cannot forge the reserved `serverInfo` key, and it appears once.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func reservedServerInfoKeyIsNotTakenFromTheHandler(revision: IndependentProtocolRevision) async throws {
        let client = try await R2P.client(try Self.metaServer(), revision)
        let response = try await client.request("tools/call", ["name": "reserved"])
        let meta = try #require(response["result"]?["_meta"])
        #expect(meta["k"] == "v")
        if revision.isModern {
            #expect(meta["io.modelcontextprotocol/serverInfo"]?["name"] == "r2p")
        } else {
            #expect(meta["io.modelcontextprotocol/serverInfo"] == nil)
        }
    }

    /// Inside a 2025-03-26 batch each member keeps its `_meta`.
    @Test func toolResultMetaInsideABatch() async throws {
        let client = try await R2P.client(try Self.metaServer(), .r2025_03_26)
        client.send(
            #"[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"text"}},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"thrown-error"}}]"#
        )
        let batch = try #require(try await client.next().arrayValue)
        #expect(batch.count == 2)
        for member in batch {
            #expect(member["result"]?["_meta"]?["com.example/trace"] == "abc", "\(member)")
        }
    }

    /// `ToolResult.encode(to:profile:)` itself writes `_meta`.
    @Test func toolResultEncodeWritesMeta() throws {
        for profile in RevisionProfile.all {
            var writer = JSONWriter()
            ToolResult(content: [.text("x")], isError: true, meta: Self.meta).encode(to: &writer, profile: profile)
            let value = try JSON.parse(writer.bytes)
            #expect(value["_meta"]?["com.example/trace"] == "abc", "\(profile.version)")
            #expect(value["isError"] == true)
            var empty = JSONWriter()
            ToolResult(content: [.text("x")], meta: [:]).encode(to: &empty, profile: profile)
            #expect(try JSON.parse(empty.bytes)["_meta"] == nil)
        }
    }

    // MARK: Completion: exact template first

    @Test(arguments: [false, true])
    func completionPrefersTheTemplateNamedExactly(exactFirst: Bool) async throws {
        let server = R2P.server()
        func add(_ template: String, _ answer: String) throws {
            try server.register(
                resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: answer),
                complete: { _, _ in CompletionResult(values: [answer]) }
            ) { request, _ in [.text(uri: request.uri, text: answer)] }
        }
        // "x://{a}" matches the text "x://{b}" (a = "{b}"), and "x://{+any}" matches everything.
        if exactFirst {
            try add("x://{b}", "B")
            try add("x://{a}", "A")
        } else {
            try add("x://{+any}", "ANY")
            try add("x://{a}", "A")
            try add("x://{b}", "B")
        }
        for revision in IndependentProtocolRevision.allCases {
            let client = try await R2P.client(server, revision)
            func complete(_ uri: String) async throws -> JSONValue? {
                let response = try await client.request(
                    "completion/complete", ["ref": ["type": "ref/resource", "uri": .string(uri)], "argument": ["name": "v", "value": ""]])
                return response["result"]?["completion"]?["values"]?[0]
            }
            #expect(try await complete("x://{b}") == "B", "\(revision)")
            #expect(try await complete("x://{a}") == "A", "\(revision)")
            // Not the name of any template: the first that matches.
            #expect(try await complete("x://other") == (exactFirst ? "B" : "ANY"), "\(revision)")
        }
    }

    // MARK: input(): repeated keys

    private static func duplicateServer() throws -> Server {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "same-call")) { _, context in
            _ = try await context.input(["k": .roots, "k": .elicit(ElicitRequest(message: "?", requestedSchema: R2P.formSchema))])
            return .text("no error")
        }
        try server.register(tool: ToolDefinition(name: "two-calls")) { _, context in
            let first = try await context.elicit("k", message: "First name?", schema: R2P.formSchema)
            let second = try await context.elicit("k", message: "Last name?", schema: R2P.formSchema)
            return .text("\(first.content?["name"]?.stringValue ?? "?") \(second.content?["name"]?.stringValue ?? "?")")
        }
        return server
    }

    /// A key used twice in one call is an error (-32603) before anything is sent, in both eras.
    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28])
    func aKeyRepeatedInOneCallIsRefusedBeforeAsking(revision: IndependentProtocolRevision) async throws {
        let client = try await R2P.client(try Self.duplicateServer(), revision, capabilities: ["roots": [:], "elicitation": [:]])
        let response = try await client.request("tools/call", ["name": "same-call"])
        #expect(response.r2pCode == -32603, "\(response)")
        #expect(response["result"] == nil)
        #expect(client.received.isEmpty)
        #expect(await client.isSilent(for: .milliseconds(30)))
    }

    private static func keyRuleServer() throws -> Server {
        let server = R2P.server { $0.clientRequestTimeoutSeconds = 0.3 }
        @Sendable func name(_ result: ElicitResult) -> String { result.content?["name"]?.stringValue ?? result.action.rawValue }
        try server.register(tool: ToolDefinition(name: "answered-twice")) { _, context in
            let first = try await context.elicit("k", message: "First name?", schema: R2P.formSchema)
            let second = try await context.elicit("k", message: "Last name?", schema: R2P.formSchema)
            return .text("\(name(first)) \(name(second))")
        }
        try server.register(tool: ToolDefinition(name: "declined-then-again")) { _, context in
            let first = try await context.elicit("k", message: "Name?", schema: R2P.formSchema)
            let second = try await context.elicit("k", message: "Name, really?", schema: R2P.formSchema)
            return .text("\(name(first)) \(name(second))")
        }
        try server.register(tool: ToolDefinition(name: "refused-then-again")) { _, context in
            // No roots capability: the first call fails without asking; the key stays free.
            do { _ = try await context.roots("k") } catch is InputUnavailable {} catch let error as MCPError where error.code == -32021 {}
            return .text(name(try await context.elicit("k", message: "Name?", schema: R2P.formSchema)))
        }
        try server.register(tool: ToolDefinition(name: "caught-then-again")) { _, context in
            var first = "-"
            do { first = name(try await context.elicit("k", message: "First?", schema: R2P.formSchema)) } catch {}
            let second = try await context.elicit("k", message: "Second?", schema: R2P.formSchema)
            return .text("\(first) \(name(second))")
        }
        try server.register(tool: ToolDefinition(name: "concurrent")) { _, context in
            async let first = context.elicit("k", message: "First name?", schema: R2P.formSchema)
            async let second = context.elicit("k", message: "Last name?", schema: R2P.formSchema)
            let (a, b) = try await (first, second)
            return .text("\(name(a)) \(name(b))")
        }
        return server
    }

    /// Answers every question with the next of `answers`; returns the final response and the
    /// questions asked (legacy: requests sent; modern: input requests per round).
    private static func drive(
        _ client: TestClient, _ revision: IndependentProtocolRevision, _ tool: String, _ answers: [JSONValue],
        arguments: JSONObject = [:]
    ) async throws -> (response: JSONValue, questions: [String]) {
        var queue = answers
        var questions: [String] = []
        func nextAnswer() -> JSONValue { queue.isEmpty ? ["action": "cancel"] : queue.removeFirst() }
        if revision.isModern {
            var params: JSONObject = ["name": .string(tool), "arguments": .object(arguments)]
            var collected = JSONObject()
            for _ in 0..<5 {
                let response = try await client.request("tools/call", params)
                guard let result = response["result"], result["resultType"] == "input_required" else { return (response, questions) }
                for (key, request) in result["inputRequests"]?.objectValue ?? JSONObject() {
                    questions.append(request["params"]?["message"]?.stringValue ?? key)
                    collected[key] = nextAnswer()
                }
                params["requestState"] = result["requestState"]
                params["inputResponses"] = .object(collected)
            }
            Issue.record("more than five rounds")
            return (.null, questions)
        }
        let call = client.post("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
        while true {
            let message = try await client.next()
            if message["method"] == nil, message["id"] == call.json { return (message, questions) }
            if message["id"] != nil, let method = message["method"]?.stringValue, method != "notifications/cancelled" {
                questions.append(message["params"]?["message"]?.stringValue ?? method)
                R2P.answer(client, message, nextAnswer())
            }
        }
    }

    private static let ada: JSONValue = ["action": "accept", "content": ["name": "Ada"]]
    private static let lovelace: JSONValue = ["action": "accept", "content": ["name": "Lovelace"]]

    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28])
    func aKeyAnsweredEarlierInTheRunCannotBeAskedAgain(revision: IndependentProtocolRevision) async throws {
        let client = try await R2P.client(try Self.keyRuleServer(), revision, capabilities: ["elicitation": [:]])
        // Accepted, then asked again.
        var (response, questions) = try await Self.drive(client, revision, "answered-twice", [Self.ada, Self.lovelace])
        #expect(response.r2pCode == -32603, "\(revision): \(response)")
        #expect(questions == ["First name?"], "\(revision): \(questions)")
        // A decline is an answer too.
        (response, questions) = try await Self.drive(client, revision, "declined-then-again", [["action": "decline"], Self.ada])
        #expect(response.r2pCode == -32603, "\(revision): \(response)")
        #expect(questions == ["Name?"], "\(revision): \(questions)")
        // Caught and asked again: never the first question's answer for the second.
        (response, questions) = try await Self.drive(client, revision, "caught-then-again", [Self.ada, Self.lovelace])
        #expect(response.r2pCode == -32603, "\(revision): \(response) after \(questions)")
        // A call that failed before asking leaves the key free.
        (response, questions) = try await Self.drive(client, revision, "refused-then-again", [Self.ada])
        #expect(response.r2pText == "Ada", "\(revision): \(response)")
    }

    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28])
    func aKeyAskedTwiceConcurrentlyIsAnError(revision: IndependentProtocolRevision) async throws {
        let client = try await R2P.client(try Self.keyRuleServer(), revision, capabilities: ["elicitation": [:]])
        for _ in 0..<(revision.isModern ? 200 : 50) {
            let (response, questions) = try await Self.drive(client, revision, "concurrent", [Self.ada, Self.lovelace])
            #expect(response.r2pCode == -32603, "\(revision): \(response) after \(questions)")
            // At most one question: the refused asker may end the handler before the other's
            // question goes out (a cancelled request sends nothing).
            #expect(questions.count <= 1, "\(revision): \(questions)")
        }
    }


    /// `n` concurrent askers of key "k" and `others` askers of distinct keys, each reporting its
    /// own outcome: "k3=Ada", "k1!-32603", "o0=Ada".
    private static func crowdServer(timeout: Double = 900) throws -> Server {
        let server = R2P.server { $0.clientRequestTimeoutSeconds = timeout }
        try server.register(tool: ToolDefinition(name: "crowd", inputSchema: ["type": "object"])) { arguments, context in
            let n = arguments["n"]?.intValue ?? 2
            let others = arguments["others"]?.intValue ?? 0
            let outcomes = await withTaskGroup(of: String.self) { group in
                for (prefix, key, count) in [("k", nil as String?, n), ("o", "", others)] {
                    for index in 0..<count {
                        let tag = "\(prefix)\(index)"
                        let askKey = key == nil ? "k" : tag
                        group.addTask {
                            do {
                                let answer = try await context.elicit(askKey, message: tag, schema: R2P.formSchema)
                                return "\(tag)=\(answer.content?["name"]?.stringValue ?? answer.action.rawValue)"
                            } catch let error as MCPError {
                                return "\(tag)!\(error.code)"
                            } catch {
                                return "\(tag)!other"
                            }
                        }
                    }
                }
                var all: [String] = []
                for await outcome in group { all.append(outcome) }
                return all.sorted()
            }
            return .text(outcomes.joined(separator: ","))
        }
        return server
    }

    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28], [2, 3, 8])
    func concurrentAskersOfOneKeyGetOneQuestion(revision: IndependentProtocolRevision, n: Int) async throws {
        let client = try await R2P.client(try Self.crowdServer(), revision, capabilities: ["elicitation": [:]])
        let others = 3
        for _ in 0..<60 {
            let (response, questions) = try await Self.drive(
                client, revision, "crowd", Array(repeating: Self.ada, count: 1 + others), arguments: ["n": JSONValue(n), "others": JSONValue(others)])
            // Exactly one question for "k" (from one of its askers), one per other key.
            #expect(questions.filter { $0.hasPrefix("k") }.count == 1, "\(questions)")
            #expect(Set(questions.filter { $0.hasPrefix("o") }) == ["o0", "o1", "o2"], "\(questions)")
            let outcomes = (response.r2pText ?? "").split(separator: ",").map(String.init)
            #expect(outcomes.count == n + others, "\(response)")
            #expect(outcomes.filter { $0.hasPrefix("k") && $0.hasSuffix("=Ada") }.count == 1, "\(outcomes)")
            #expect(outcomes.filter { $0.hasPrefix("k") && $0.hasSuffix("!-32603") }.count == n - 1, "\(outcomes)")
            #expect(outcomes.filter { $0.hasPrefix("o") && $0.hasSuffix("=Ada") }.count == others, "\(outcomes)")
        }
    }

    /// Release racing a new asker: 8 askers of one key retry after a timeout or a refusal. At
    /// no moment are two questions for the key outstanding: on the wire every request is
    /// followed by its own withdrawal before the next request.
    @Test func releaseRacingANewAskerNeverOverlaps() async throws {
        let server = R2P.server { $0.clientRequestTimeoutSeconds = 0.001 }
        try server.register(tool: ToolDefinition(name: "retry")) { _, context in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        for _ in 0..<40 {
                            do {
                                _ = try await context.elicit("k", message: "q\(index)", schema: R2P.formSchema)
                                return
                            } catch {
                                try? await Task.sleep(for: .microseconds(300))
                            }
                        }
                    }
                }
            }
            return .text("done")
        }
        for _ in 0..<10 {
            let client = try await R2P.client(server, .r2025_11_25, capabilities: ["elicitation": [:]])
            let call = client.post("tools/call", ["name": "retry"])
            let messages = try await R2P.collect(client, until: call)
            #expect(messages.last?.r2pText == "done")
            var outstanding: JSONValue?
            var asked = 0
            for message in messages.dropLast() {
                if message["method"] == "elicitation/create" {
                    #expect(outstanding == nil, "a second question while \(outstanding.map(\.description) ?? "") is outstanding")
                    outstanding = message["id"]
                    asked += 1
                } else if message["method"] == "notifications/cancelled" {
                    #expect(message["params"]?["requestId"] == outstanding, "\(message)")
                    outstanding = nil
                }
            }
            #expect(outstanding == nil)
            #expect(asked > 8, "too few questions to exercise the race: \(asked)")
        }
    }

    /// The key is released when its question got no answer: an error reply, a malformed reply,
    /// a cancelled asker. Each time the key may be asked again, and that question goes out.
    @Test func aKeyWithoutAnAnswerIsReleased() async throws {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "again", inputSchema: ["type": "object"])) { arguments, context in
            switch arguments["how"]?.stringValue {
            case "cancel":
                let child = Task { try await context.elicit("k", message: "first", schema: R2P.formSchema) }
                // Wait until the test has seen the first question, then cancel its asker.
                let deadline = ContinuousClock.now + .seconds(5)
                while R2PSignal.shared.take() == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
                child.cancel()
                _ = await child.result
            default:
                do { _ = try await context.elicit("k", message: "first", schema: R2P.formSchema) } catch {}
            }
            let second = try await context.elicit("k", message: "second", schema: R2P.formSchema)
            return .text(second.content?["name"]?.stringValue ?? "?")
        }
        let client = try await R2P.client(server, .r2025_11_25, capabilities: ["elicitation": [:]])
        for how in ["error", "malformed", "cancel"] {
            let call = client.post("tools/call", ["name": "again", "arguments": ["how": .string(how)]])
            let first = try await R2P.expectMessage(client, "elicitation/create")
            #expect(first["params"]?["message"] == "first")
            switch how {
            case "error": client.send(["jsonrpc": "2.0", "id": first["id"]!, "error": ["code": -1, "message": "no"]])
            case "malformed": R2P.answer(client, first, ["action": 5])
            default:
                R2PSignal.shared.fire()
                let cancelled = try await R2P.expectMessage(client, "notifications/cancelled")
                #expect(cancelled["params"]?["requestId"] == first["id"])
            }
            let second = try await R2P.expectMessage(client, "elicitation/create")
            #expect(second["params"]?["message"] == "second", "\(how)")
            R2P.answer(client, second, Self.ada)
            #expect(try await client.response(to: call).r2pText == "Ada", "\(how)")
        }
    }

    /// A call refused because one of its keys collides reserves none of its keys.
    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28])
    func aRefusedMultiKeyCallLeaksNoReservation(revision: IndependentProtocolRevision) async throws {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "collide")) { _, context in
            _ = try await context.elicit("k", message: "k", schema: R2P.formSchema)
            var codes: [Int] = []
            do {
                _ = try await context.input([
                    "b": .elicit(ElicitRequest(message: "b-in-call", requestedSchema: R2P.formSchema)),
                    "k": .elicit(ElicitRequest(message: "k-again", requestedSchema: R2P.formSchema)),
                ])
            } catch let error as MCPError { codes.append(error.code) }
            do {
                _ = try await context.input([
                    "c": .elicit(ElicitRequest(message: "c-in-call", requestedSchema: R2P.formSchema)),
                    "c": .elicit(ElicitRequest(message: "c-twice", requestedSchema: R2P.formSchema)),
                ])
            } catch let error as MCPError { codes.append(error.code) }
            let b = try await context.elicit("b", message: "b", schema: R2P.formSchema)
            let c = try await context.elicit("c", message: "c", schema: R2P.formSchema)
            return .text("\(codes) \(b.action.rawValue) \(c.action.rawValue)")
        }
        let client = try await R2P.client(server, revision, capabilities: ["elicitation": [:]])
        let (response, questions) = try await Self.drive(client, revision, "collide", [Self.ada, Self.ada, Self.ada])
        #expect(response.r2pText == "[-32603, -32603] accept accept", "\(revision): \(response)")
        #expect(questions == ["k", "b", "c"], "\(revision): \(questions)")
    }

    // MARK: requestState lifetime at extreme values

    private static func lifetimeServer(_ seconds: Int) throws -> Server {
        let server = R2P.server { $0.requestStateLifetimeSeconds = seconds }
        try server.register(tool: ToolDefinition(name: "ask")) { _, context in
            .text(try await context.elicit("k", message: "?", schema: R2P.formSchema).content?["name"]?.stringValue ?? "?")
        }
        return server
    }

    private static func roundTrip(_ server: Server) async throws -> JSONValue {
        let client = TestClient(server, capabilities: ["elicitation": [:]])
        let first = try #require(try await client.request("tools/call", ["name": "ask"])["result"])
        try #require(first["resultType"] == "input_required", "\(first)")
        return try await client.request(
            "tools/call", ["name": "ask", "requestState": first["requestState"]!, "inputResponses": ["k": ["action": "accept", "content": ["name": "Ada"]]]])
    }

    @Test(arguments: [Int.max, Int.max - 1, 1 << 62, 3600])
    func longLifetimesDoNotTrapAndWork(seconds: Int) async throws {
        #expect(try await Self.roundTrip(try Self.lifetimeServer(seconds)).r2pText == "Ada")
    }

    @Test(arguments: [-1, -3600, Int.min, Int.min + 1])
    func negativeLifetimesDoNotTrapAndRefuseTheState(seconds: Int) async throws {
        let response = try await Self.roundTrip(try Self.lifetimeServer(seconds))
        #expect(response.r2pCode == -32602, "\(response)")
        #expect(response["error"]?["message"]?.stringValue?.contains("expired") == true)
    }

    // MARK: AEADRequestStateSealer keys

    @Test func sealerAcceptsTheBoundaryKeys() throws {
        let a = [UInt8](repeating: 1, count: 32)
        let b = [UInt8](repeating: 2, count: 32)
        let longID = String(repeating: "x", count: 255)
        for id in ["", "k1", longID, "\u{E9}t\u{E9}"] {
            let sealer = AEADRequestStateSealer(key: a, keyID: id)
            #expect(try sealer.open(try sealer.seal([1, 2, 3])) == [1, 2, 3], "id \(id.utf8.count) bytes")
        }
        // Rotation: a state sealed under an old key opens with the new sealer.
        let old = AEADRequestStateSealer(key: a, keyID: longID)
        let rotated = AEADRequestStateSealer(key: b, keyID: "", previous: [longID: a, "spare": [UInt8](repeating: 3, count: 64)])
        #expect(try rotated.open(try old.seal([9])) == [9])
        #expect(try rotated.open(try rotated.seal([8])) == [8])
        // A previous key under the current id does not replace the current key.
        let shadowed = AEADRequestStateSealer(key: b, keyID: "k", previous: ["k": a])
        #expect(try AEADRequestStateSealer(key: b, keyID: "k").open(try shadowed.seal([7])) == [7])
        #expect(throws: RequestStateError.self) { try shadowed.open(try AEADRequestStateSealer(key: a, keyID: "k").seal([7])) }
    }

    @Test func sealerRefusesAShortCurrentKey() async {
        await #expect(processExitsWith: .failure) { _ = AEADRequestStateSealer(key: [UInt8](repeating: 1, count: 31)) }
    }

    @Test func sealerRefusesAShortPreviousKey() async {
        await #expect(processExitsWith: .failure) {
            _ = AEADRequestStateSealer(key: [UInt8](repeating: 1, count: 32), previous: ["old": [UInt8](repeating: 1, count: 31)])
        }
    }

    @Test func sealerRefusesALongKeyID() async {
        await #expect(processExitsWith: .failure) {
            _ = AEADRequestStateSealer(key: [UInt8](repeating: 1, count: 32), keyID: String(repeating: "x", count: 256))
        }
    }

    @Test func sealerRefusesALongPreviousKeyID() async {
        await #expect(processExitsWith: .failure) {
            _ = AEADRequestStateSealer(
                key: [UInt8](repeating: 1, count: 32), previous: [String(repeating: "x", count: 256): [UInt8](repeating: 1, count: 32)])
        }
    }

    // MARK: elicit(schema:) checks an accepted answer

    private static let ageSchema: JSONObject = [
        "type": "object",
        "properties": ["name": ["type": "string", "maxLength": 10], "age": ["type": "integer", "minimum": 0]],
        "required": ["name"],
    ]

    private static func elicitServer(diagnostics: R2PDiagnostics = R2PDiagnostics()) throws -> Server {
        let server = R2P.server(diagnostics: diagnostics)
        try server.register(tool: ToolDefinition(name: "ask")) { _, context in
            let result = try await context.elicit("k", message: "?", schema: ageSchema)
            return .text("\(result.action.rawValue):\(result.content?["name"]?.stringValue ?? "-")")
        }
        try server.register(tool: ToolDefinition(name: "uncompilable")) { _, context in
            _ = try await context.elicit("k", message: "?", schema: ["type": "object", "properties": ["x": ["type": "string", "pattern": "(?<=a)b"]]])
            return .text("asked")
        }
        return server
    }

    /// Answers and what the handler sees; `nil` means an error.
    private static let answers: [(answer: JSONValue, expected: String?)] = [
        (["action": "accept", "content": ["name": "Ada", "age": 36]], "accept:Ada"),
        (["action": "accept", "content": ["name": "Ada"]], "accept:Ada"),
        (["action": "accept", "content": ["name": "Ada", "age": "old"]], nil),
        (["action": "accept", "content": ["name": "Ada", "age": -1]], nil),
        (["action": "accept", "content": ["name": "much too long a name"]], nil),
        (["action": "accept", "content": [:]], nil),
        (["action": "accept"], nil),
        (["action": "decline"], "decline:-"),
        (["action": "cancel"], "cancel:-"),
        // Content belongs to an accepted answer only: a declined or cancelled answer's is dropped.
        (["action": "decline", "content": ["name": "Ada"]], "decline:-"),
        (["action": "cancel", "content": ["name": 5]], "cancel:-"),
    ]

    @Test(arguments: [IndependentProtocolRevision.r2025_06_18, .r2025_11_25, .r2026_07_28])
    func acceptedContentIsCheckedAgainstTheRequestedSchema(revision: IndependentProtocolRevision) async throws {
        let server = try Self.elicitServer()
        for (answer, expected) in Self.answers {
            let client = try await R2P.client(server, revision, capabilities: ["elicitation": [:]])
            let response: JSONValue
            if revision.isModern {
                let first = try #require(try await client.request("tools/call", ["name": "ask"])["result"])
                response = try await client.request(
                    "tools/call", ["name": "ask", "requestState": first["requestState"]!, "inputResponses": ["k": answer]])
            } else {
                let call = client.post("tools/call", ["name": "ask"])
                R2P.answer(client, try await R2P.expectMessage(client, "elicitation/create"), answer)
                response = try await client.response(to: call)
            }
            if let expected {
                #expect(response.r2pText == expected, "\(revision) \(answer): \(response)")
            } else {
                #expect(response.r2pCode == (revision.isModern ? -32602 : -32603), "\(revision) \(answer): \(response)")
            }
        }
    }

    /// The client's content reaches the error message escaped by JSON, and no diagnostic carries
    /// it raw.
    @Test func hostileContentIsNotEchoedRaw() async throws {
        let diagnostics = R2PDiagnostics()
        let client = try await R2P.client(try Self.elicitServer(diagnostics: diagnostics), .r2025_11_25, capabilities: ["elicitation": [:]])
        let call = client.post("tools/call", ["name": "ask"])
        let hostile = "\u{1B}[31m\nlimb: stdio: forged line\u{2028}"
        R2P.answer(
            client, try await R2P.expectMessage(client, "elicitation/create"),
            ["action": "accept", "content": ["name": .string(hostile), "age": .string(hostile)]])
        let response = try await client.response(to: call)
        #expect(response.r2pCode == -32603)
        for line in diagnostics.all {
            #expect(!line.contains("\u{1B}") && !line.contains("\n") && !line.contains("\u{2028}"), "\(line)")
        }
    }

    /// A schema that cannot be enforced is an error before anything is asked.
    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28])
    func anUncompilableSchemaFailsBeforeAsking(revision: IndependentProtocolRevision) async throws {
        let client = try await R2P.client(try Self.elicitServer(), revision, capabilities: ["elicitation": [:]])
        let response = try await client.request("tools/call", ["name": "uncompilable"])
        #expect(response.r2pCode == -32603, "\(response)")
        #expect(response["result"]?["resultType"] == nil)
        #expect(client.received.isEmpty)
    }

    // MARK: URI templates

    private static func registers(_ template: String) -> Bool {
        let server = R2P.server()
        do {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: "t")) { request, _ in
                [.text(uri: request.uri, text: "")]
            }
            return true
        } catch {
            return false
        }
    }

    /// RFC 6570 level 1 (`{var}`) and level 2 reserved (`{+var}`); `varname = varchar *( ["."]
    /// varchar )`. Braces never stand alone in a literal.
    @Test func templateSyntax() {
        for accepted in ["x://{a}", "x://{user.id}", "x://{a.b.c}", "x://{+path}", "x://{_9}", "x://{a}{b}", "x://lit/{a}/lit", "x://{+a.b}"] {
            #expect(Self.registers(accepted), "\(accepted)")
        }
        for refused in [
            "x://a}b", "x://{a", "x://{}", "x://{a.}", "x://{.a}", "x://{a..b}", "x://{a,b}", "x://{a:3}", "x://{a*}",
            "x://{#a}", "x://{/a}", "x://{?a}", "x://{&a}", "x://{;a}", "x://{a}}", "x://{{a}", "x://{a-b}", "x://{\u{E9}}", "x://{ a}",
        ] {
            #expect(!Self.registers(refused), "\(refused)")
        }
    }

    private static func templateServer(recorder: R2PBox<[String: String]>) throws -> Server {
        let server = R2P.server()
        for template in ["d://{user.id}/x", "a://{first}{second}", "p://{v}", "r://{+rest}", "s://pre{v}post"] {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: template)) { request, _ in
                recorder.withLock { $0 = request.variables }
                return [.text(uri: request.uri, text: "")]
            }
        }
        return server
    }

    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28])
    func templateMatching(revision: IndependentProtocolRevision) async throws {
        let recorder = R2PBox<[String: String]>([:])
        let client = try await R2P.client(try Self.templateServer(recorder: recorder), revision)
        func read(_ uri: String) async throws -> [String: String]? {
            recorder.withLock { $0 = ["unread": ""] }
            let response = try await client.request("resources/read", ["uri": .string(uri)])
            return response["result"] == nil ? nil : recorder.value
        }
        #expect(try await read("d://42/x") == ["user.id": "42"])
        #expect(try await read("a://xyz") == ["first": "xy", "second": "z"])
        #expect(try await read("p://a%20b") == ["v": "a b"])
        #expect(try await read("p://a%2Fb") == ["v": "a/b"])
        #expect(try await read("p://50%off") == ["v": "50%off"])
        #expect(try await read("p://%FF") == ["v": "%FF"])
        #expect(try await read("p://a/b") == nil)
        #expect(try await read("r://a/b/c") == ["rest": "a/b/c"])
        #expect(try await read("s://preXpost") == ["v": "X"])
        #expect(try await read("p://") == ["v": ""])
        #expect(try await read("s://prepost") == ["v": ""])
    }

    // MARK: Registry mutation from a deinit

    private final class DeinitHook: Sendable {
        let action: @Sendable () -> Void
        init(_ action: @escaping @Sendable () -> Void) { self.action = action }
        deinit { action() }
    }

    enum Removal: String, CaseIterable, Sendable { case tool, resource, prompt }

    /// A handler's captured object whose `deinit` registers and removes: removing the handler
    /// must not deadlock.
    @Test(arguments: Removal.allCases)
    func registryMutationFromADeinitDoesNotDeadlock(removal: Removal) async throws {
        let server = R2P.server()
        let ran = R2PBox(false)
        do {
            let hook = DeinitHook { [server] in
                try? server.register(tool: ToolDefinition(name: "born-in-deinit")) { _, _ in .text("") }
                server.removeTool(named: "born-in-deinit")
                try? server.register(method: "x/born") { _, _ in [:] }
                ran.withLock { $0 = true }
            }
            switch removal {
            case .tool: try server.register(tool: ToolDefinition(name: "victim")) { _, _ in _ = hook; return .text("") }
            case .resource: try server.register(resource: ResourceDefinition(uri: "v://r", name: "v")) { _, _ in _ = hook; return [] }
            case .prompt: try server.register(prompt: PromptDefinition(name: "victim")) { _, _ in _ = hook; return PromptResult(messages: []) }
            }
        }
        let done = R2PBox(false)
        let thread = Thread {
            switch removal {
            case .tool: server.removeTool(named: "victim")
            case .resource: server.removeResource(uri: "v://r")
            case .prompt: server.removePrompt(named: "victim")
            }
            done.withLock { $0 = true }
        }
        thread.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !done.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(done.value, "removal deadlocked")
        #expect(ran.value, "the deinit did not run, so the test proved nothing")
    }

    // MARK: subscriptions/listen while the connection closes

    /// Every acknowledged subscription is also ended by `close`; nothing comes after it.
    @Test func listenRacingClose() async throws {
        let server = R2P.server()
        for _ in 0..<20 {
            let client = TestClient(server)
            let sender = Task.detached {
                for index in 0..<100 {
                    client.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]], id: RequestID("s\(index)"))
                }
            }
            await client.close(graceSeconds: 0)
            await sender.value
            var acknowledged: Set<String> = []
            var ended: Set<String> = []
            while true {
                let message: JSONValue
                do {
                    message = try await client.next(timeout: .milliseconds(20))
                } catch let error as TestClientError where error.reason.hasPrefix("no message") {
                    break
                }
                if message["method"] == "notifications/subscriptions/acknowledged",
                    let id = message["params"]?["_meta"]?["io.modelcontextprotocol/subscriptionId"]?.stringValue
                {
                    acknowledged.insert(id)
                } else if message["method"] == nil, let id = message["id"]?.stringValue, message["result"] != nil {
                    ended.insert(id)
                }
            }
            #expect(acknowledged.isSubset(of: ended), "acknowledged but never ended: \(acknowledged.subtracting(ended).sorted())")
        }
    }

    // MARK: Regressions: handshake and discovery

    @Test(arguments: IndependentProtocolRevision.allCases)
    func handshakeAndDiscoveryStillConform(revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        if revision.isModern {
            let client = TestClient(server, capabilities: ["elicitation": ["url": [:]], "sampling": ["tools": [:]]])
            let response = try await client.request("server/discover")
            #expect(IndependentProtocol.responseViolations(response, to: "server/discover", in: revision) == [], "\(response)")
            let capabilities = R2P.keys(response["result"]?["capabilities"])
            #expect(capabilities == ["tools", "resources", "prompts", "logging", "completions"], "\(capabilities)")
        } else {
            let client = TestClient(server, modern: false)
            let response = try await client.initialize(
                version: revision.version, capabilities: ["elicitation": ["form": [:], "url": [:]], "sampling": ["tools": [:]], "roots": [:]])
            #expect(IndependentProtocol.responseViolations(response, to: "initialize", in: revision) == [], "\(response)")
            #expect(response["result"]?["protocolVersion"] == .string(revision.rawValue))
            let capabilities = R2P.keys(response["result"]?["capabilities"])
            #expect(capabilities == ["tools", "resources", "prompts", "logging", "completions"], "\(capabilities)")
        }
    }
}
