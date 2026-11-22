import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var values: [String]? { self["result"]?["completion"]?["values"]?.arrayValue?.compactMap(\.stringValue) }
}

/// `prompts/get` and `completion/complete`.
/// Sources: `server/prompts.mdx`, `server/utilities/completion.mdx` and `schema.ts` of each revision.
@Suite struct IndependentProtocolPromptsTests {
    // MARK: prompts/get

    /// "Invalid prompt name: -32602 (Invalid params); Missing required arguments: -32602"
    /// (prompts.mdx, "Error Handling"). `arguments` is `{ [key: string]: string }` in the schema:
    /// anything else is a malformed request. Nothing reaches the handler.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func invalidPromptRequestsAreInvalidParams(_ revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(recorder: recorder), revision)
        let meta = revision.isModern ? IndependentProtocol.modernMetaText : ""
        let bodies = [
            // The name.
            "", #""name":5"#, #""name":null"#, #""name":["rich_prompt"]"#, #""name":{}"#, #""arguments":{"topic":"x"}"#,
            #""name":"no_such_prompt""#, #""name":"""#, #""name":"Rich_Prompt""#, #""name":"rich_prompt ""#, #""name":"everything""#,
            // Required argument missing.
            #""name":"rich_prompt""#, #""name":"rich_prompt","arguments":{}"#, #""name":"rich_prompt","arguments":{"tone":"dry"}"#,
            #""name":"rich_prompt","arguments":{"Topic":"x"}"#, #""name":"rich_prompt","arguments":{"topic ":"x"}"#,
            // Argument values that are not strings.
            #""name":"rich_prompt","arguments":{"topic":5}"#, #""name":"rich_prompt","arguments":{"topic":null}"#,
            #""name":"rich_prompt","arguments":{"topic":true}"#, #""name":"rich_prompt","arguments":{"topic":["x"]}"#,
            #""name":"rich_prompt","arguments":{"topic":{"value":"x"}}"#, #""name":"rich_prompt","arguments":{"topic":"x","tone":5}"#,
            #""name":"rich_prompt","arguments":{"topic":"x","undeclared":5}"#, #""name":"bare","arguments":{"anything":1}"#,
        ]
        for body in bodies {
            let params = [meta, body].filter { !$0.isEmpty }.joined(separator: ",")
            let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":"p","method":"prompts/get","params":{\#(params)}}"#)
            #expect(reply.code == -32602, "\(revision.rawValue) {\(body)}: \(reply)")
            #expect(reply["id"] == "p")
        }
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
        // The error says which argument is missing, and which prompt is unknown.
        let missing = try await client.request("prompts/get", ["name": "rich_prompt"])
        #expect(missing["error"]?["message"]?.stringValue?.contains("topic") == true, "\(missing)")
        let unknown = try await client.request("prompts/get", ["name": "no_such_prompt"])
        #expect(unknown["error"]?["message"]?.stringValue?.contains("no_such_prompt") == true, "\(unknown)")
    }

    /// `arguments?: { [key: string]: string }` (`GetPromptRequestParams`): an array, a string, a
    /// number or a boolean in its place is a malformed request even when the prompt requires no
    /// argument — `InvalidParamsError`: "the method parameters are invalid or malformed". The
    /// same mistake in `tools/call` is refused.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func promptArgumentsMustBeAnObject(_ revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(recorder: recorder), revision)
        let meta = revision.isModern ? IndependentProtocol.modernMetaText + "," : ""
        for (index, arguments) in [#"["topic","swift"]"#, #""topic=swift""#, "5", "true", #"[{"topic":"swift"}]"#].enumerated() {
            client.send(#"{"jsonrpc":"2.0","id":\#(index + 100),"method":"prompts/get","params":{\#(meta)"name":"bare","arguments":\#(arguments)}}"#)
            let reply = try await client.response(to: RequestID(index + 100))
            #expect(reply.code == -32602, "\(revision.rawValue) arguments \(arguments): \(reply)")
        }
        #expect(recorder.entries.isEmpty, "the handler ran for a malformed request: \(recorder.entries)")
    }

    /// The handler gets the arguments as sent: empty strings count as present, optional ones may
    /// be absent, and every value arrives untouched.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func theHandlerGetsTheArguments(_ revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(recorder: recorder), revision)
        let cases: [(JSONObject, String)] = [
            (["topic": "swift"], "prompt:topic=swift"),
            (["topic": ""], "prompt:topic="),
            (["topic": "a,b=c", "tone": "dry"], "prompt:tone=dry,topic=a,b=c"),
            (["topic": "línea\n\"dos\" \u{1F600}", "tone": ""], "prompt:tone=,topic=línea\n\"dos\" \u{1F600}"),
            (["topic": "data:text/plain;base64,aGk="], "prompt:topic=data:text/plain;base64,aGk="),
            (["topic": "123"], "prompt:topic=123"),
        ]
        for (arguments, expected) in cases {
            recorder.clear()
            let response = try await client.request("prompts/get", ["name": "rich_prompt", "arguments": .object(arguments)])
            #expect(response["result"]?["messages"]?.arrayValue?.count == 5, "\(response)")
            #expect(recorder.entries == [expected])
            #expect(response["result"]?["description"] == .string("About \(arguments["topic"]?.stringValue ?? "")"))
        }
        // A prompt without arguments: `arguments` may be absent or empty.
        for params in [["name": "bare"], ["name": "bare", "arguments": [:]]] as [JSONObject] {
            recorder.clear()
            let response = try await client.request("prompts/get", params)
            #expect(response["result"]?["messages"] == [])
            // No description was given: the member is absent rather than null or empty.
            #expect(response["result"]?["description"] == nil)
            #expect(recorder.entries == ["prompt:bare"])
        }
    }

    /// Every message has a role of the schema's `Role` and one content block.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func promptMessagesKeepRolesAndOrder(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        let messages = try #require(try await client.request("prompts/get", ["name": "rich_prompt", "arguments": ["topic": "t"]])["result"]?["messages"]?.arrayValue)
        #expect(messages.map { $0["role"] } == ["user", "assistant", "user", "user", "assistant"])
        let types = messages.map { $0["content"]?["type"]?.stringValue }
        #expect(types == ["text", "image", "audio", "resource", revision.isAtLeast(.r2025_06_18) ? "resource_link" : "text"])
        #expect(messages[0]["content"]?["text"] == "Tell me about t")
        #expect(messages[1]["content"]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } == Data(IndependentProtocolRich.pngBytes))
        #expect(messages[3]["content"]?["resource"]?["uri"] == "rich://embedded/text")
        for message in messages { #expect(Set(message.objectValue?.map(\.key) ?? []) == ["role", "content"]) }
    }

    /// Prompt names are not restricted the way tool names are: any name that was registered is
    /// the name to ask for.
    @Test func promptNamesAreExactStrings() async throws {
        let names = ["summarize", "Summarize", "summarize ", "с пробелом", "a/b", "a.b", "é", "😀", "tools/call", "0", "quote\"d", "back\\slash", ""]
        let server = Server(name: "prompts", version: "1")
        for name in names {
            try server.register(prompt: PromptDefinition(name: name)) { _, _ in PromptResult(messages: [.user("I am " + name)]) }
        }
        let client = TestClient(server)
        let listed = try await client.request("prompts/list")["result"]?["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(listed == names)
        for name in names {
            let text = try await client.request("prompts/get", ["name": .string(name)])["result"]?["messages"]?[0]?["content"]?["text"]?.stringValue
            #expect(text == "I am " + name, "\(name.debugDescription)")
        }
        for name in names {
            let error = #expect(throws: RegistrationError.self) {
                try server.register(prompt: PromptDefinition(name: name)) { _, _ in PromptResult(messages: []) }
            }
            if !name.isEmpty { #expect(error?.description.contains(name) == true) }
        }
    }

    @Test func namesAndURIsThatDifferOnlyInNormalizationAreDifferent() async throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        try #require(Array(composed.utf8) != Array(decomposed.utf8))
        let server = Server(name: "unicode", version: "1")
        try server.register(prompt: PromptDefinition(name: composed)) { _, _ in PromptResult(messages: [.user("composed")]) }
        try server.register(resource: ResourceDefinition(uri: "u://" + composed, name: "composed")) { request, _ in
            [.text(uri: request.uri, text: "composed")]
        }
        let client = TestClient(server)
        // Asked under the other spelling, there is no such prompt and no such resource.
        let prompt = try await client.request("prompts/get", ["name": .string(decomposed)])
        #expect(prompt.code == -32602, "a prompt registered as U+00E9 answered to e + U+0301: \(prompt)")
        let resource = try await client.request("resources/read", ["uri": .string("u://" + decomposed)])
        #expect(resource.code == -32602, "a resource registered as U+00E9 answered to e + U+0301: \(resource)")
        // And the other spelling is free to be registered as a prompt and a resource of its own.
        #expect(throws: Never.self) {
            try server.register(prompt: PromptDefinition(name: decomposed)) { _, _ in PromptResult(messages: [.user("decomposed")]) }
        }
        #expect(throws: Never.self) {
            try server.register(resource: ResourceDefinition(uri: "u://" + decomposed, name: "decomposed")) { request, _ in
                [.text(uri: request.uri, text: "decomposed")]
            }
        }
        let names = try await client.request("prompts/list")["result"]?["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue.map { Array($0.utf8) } }
        #expect(names == [Array(composed.utf8), Array(decomposed.utf8)])
    }

    // MARK: completion/complete

    /// `CompleteRequestParams`: `ref` is a `PromptReference` (`type: "ref/prompt"`, `name`) or a
    /// `ResourceTemplateReference` (`type: "ref/resource"`, `uri`); `argument` has string `name`
    /// and `value`. "Invalid prompt name: -32602; Missing required arguments: -32602"
    /// (completion.mdx, "Error Handling").
    @Test(arguments: IndependentProtocolRevision.allCases)
    func invalidCompletionRequestsAreInvalidParams(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        let meta = revision.isModern ? IndependentProtocol.modernMetaText : ""
        let prompt = #""ref":{"type":"ref/prompt","name":"rich_prompt"}"#
        let argument = #""argument":{"name":"topic","value":"s"}"#
        let bodies = [
            "", argument, prompt,
            #""ref":null,\#(argument)"#, #""ref":"rich_prompt",\#(argument)"#, #""ref":["ref/prompt","rich_prompt"],\#(argument)"#, #""ref":{},\#(argument)"#,
            #""ref":{"name":"rich_prompt"},\#(argument)"#, #""ref":{"type":"ref/tool","name":"everything"},\#(argument)"#,
            #""ref":{"type":"prompt","name":"rich_prompt"},\#(argument)"#, #""ref":{"type":"REF/PROMPT","name":"rich_prompt"},\#(argument)"#,
            #""ref":{"type":5,"name":"rich_prompt"},\#(argument)"#,
            #""ref":{"type":"ref/prompt"},\#(argument)"#, #""ref":{"type":"ref/prompt","name":"no_such_prompt"},\#(argument)"#,
            #""ref":{"type":"ref/prompt","name":5},\#(argument)"#, #""ref":{"type":"ref/prompt","uri":"rich://items/{id}"},\#(argument)"#,
            #""ref":{"type":"ref/resource"},\#(argument)"#, #""ref":{"type":"ref/resource","uri":"nope://{x}"},\#(argument)"#,
            #""ref":{"type":"ref/resource","uri":5},\#(argument)"#, #""ref":{"type":"ref/resource","name":"rich_prompt"},\#(argument)"#,
            #""ref":{"type":"ref/resource","uri":"rich://static"},\#(argument)"#,
            #"\#(prompt),"argument":null"#, #"\#(prompt),"argument":"topic""#, #"\#(prompt),"argument":["topic","s"]"#, #"\#(prompt),"argument":{}"#,
            #"\#(prompt),"argument":{"name":"topic"}"#, #"\#(prompt),"argument":{"value":"s"}"#, #"\#(prompt),"argument":{"name":5,"value":"s"}"#,
            #"\#(prompt),"argument":{"name":"topic","value":5}"#, #"\#(prompt),"argument":{"name":"topic","value":null}"#,
        ]
        for body in bodies {
            let params = [meta, body].filter { !$0.isEmpty }.joined(separator: ",")
            let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":9,"method":"completion/complete","params":{\#(params)}}"#)
            #expect(reply.code == -32602, "\(revision.rawValue) {\(body)}: \(reply)")
        }
    }

    /// What the handler is asked: the argument's name, the text typed so far, and the arguments
    /// already resolved (`context.arguments`, added in 2025-06-18).
    @Test(arguments: IndependentProtocolRevision.allCases)
    func theCompletionHandlerGetsTheRequest(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "completions", version: "1")
        let handler: CompletionHandler = { request, context in
            let resolved = request.resolvedArguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            return CompletionResult(values: ["name:\(request.argumentName)", "value:\(request.value)", "resolved:\(resolved)", "method:\(context.method)"])
        }
        try server.register(prompt: PromptDefinition(name: "p", arguments: [PromptArgument(name: "a"), PromptArgument(name: "b")]), complete: handler) { _, _ in
            PromptResult(messages: [])
        }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "c://{owner}/{repo}", name: "t"), complete: handler) { _, _ in [] }
        let client = try await IndependentProtocol.client(server, revision)

        let plain = try await client.request("completion/complete", ["ref": ["type": "ref/prompt", "name": "p"], "argument": ["name": "a", "value": "típ \"x\""]])
        #expect(plain.values == ["name:a", "value:típ \"x\"", "resolved:", "method:completion/complete"])
        let empty = try await client.request("completion/complete", ["ref": ["type": "ref/prompt", "name": "p"], "argument": ["name": "b", "value": ""]])
        #expect(empty.values == ["name:b", "value:", "resolved:", "method:completion/complete"])
        let withContext = try await client.request(
            "completion/complete",
            ["ref": ["type": "ref/resource", "uri": "c://{owner}/{repo}"], "argument": ["name": "repo", "value": "li"], "context": ["arguments": ["owner": "apple", "extra": "1"]]])
        #expect(withContext.values == ["name:repo", "value:li", "resolved:extra=1&owner=apple", "method:completion/complete"])
        // `uri` is "the URI or URI template of the resource": a concrete URI of the template works too.
        let concrete = try await client.request(
            "completion/complete", ["ref": ["type": "ref/resource", "uri": "c://apple/swift"], "argument": ["name": "repo", "value": "s"]])
        #expect(concrete.values?.first == "name:repo")
        // Unknown members of `ref` (a `title`, say: PromptReference extends BaseMetadata) change nothing.
        let titled = try await client.request(
            "completion/complete", ["ref": ["type": "ref/prompt", "name": "p", "title": "P", "x": 1], "argument": ["name": "a", "value": "v", "x": 1]])
        #expect(titled.values?.prefix(2) == ["name:a", "value:v"])
    }

    /// `completion.values`: "Must not exceed 100 items" (schema: `maxItems: 100`). `total` is
    /// "the total number of completion options available", `hasMore` "indicates whether there are
    /// additional completion options beyond those provided in the current response".
    @Test(arguments: IndependentProtocolRevision.allCases)
    func completionResultsAreCappedAndDescribed(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "completions", version: "1")
        try server.register(
            prompt: PromptDefinition(name: "p", arguments: [PromptArgument(name: "count")]),
            complete: { request, _ in
                // "<count>" or "<count>,<total>,<hasMore>" as the typed value.
                let parts = request.value.split(separator: ",").map(String.init)
                let count = Int(parts[0]) ?? 0
                return CompletionResult(
                    values: (0..<count).map { "v\($0)" }, total: parts.count > 1 ? Int(parts[1]) : nil,
                    hasMore: parts.count > 2 ? parts[2] == "true" : nil)
            }
        ) { _, _ in PromptResult(messages: []) }
        let client = try await IndependentProtocol.client(server, revision)
        func complete(_ value: String) async throws -> JSONValue {
            let response = try await client.request("completion/complete", ["ref": ["type": "ref/prompt", "name": "p"], "argument": ["name": "count", "value": .string(value)]])
            let violations = IndependentProtocol.responseViolations(response, to: "completion/complete", in: revision)
            #expect(violations.isEmpty, "\(value): \(violations.joined(separator: "\n"))")
            return try #require(response["result"]?["completion"], "\(response)")
        }
        for count in [0, 1, 99, 100] {
            let completion = try await complete("\(count)")
            #expect(completion["values"]?.arrayValue?.count == count)
            #expect(completion["values"]?.arrayValue?.first == (count == 0 ? nil : "v0"))
            #expect(completion["hasMore"] ?? false == false, "nothing was left out of \(count) values")
            #expect(completion["total"] == nil)
        }
        for count in [101, 150, 1000] {
            let completion = try await complete("\(count)")
            #expect(completion["values"]?.arrayValue?.count == 100, "\(count) values were sent")
            #expect(completion["values"]?.arrayValue?.last == "v99", "the first hundred, in order")
            #expect(completion["hasMore"] == true, "\(count - 100) values were left out")
        }
        // What the handler states is passed on.
        let stated = try await complete("3,42,true")
        #expect(stated["values"] == ["v0", "v1", "v2"])
        #expect(stated["total"] == 42)
        #expect(stated["hasMore"] == true)
        let exact = try await complete("2,2,false")
        #expect(exact["total"] == 2 && exact["hasMore"] == false)
        // The handler said "no more" about its own 150 values; after the cut to 100 there are more.
        let cut = try await complete("150,150,false")
        #expect(cut["values"]?.arrayValue?.count == 100)
        #expect(cut["total"] == 150)
        #expect(cut["hasMore"] == true, "50 values were dropped, yet hasMore is \(cut["hasMore"] ?? "absent")")
    }

    /// A prompt or template without a completion handler has nothing to suggest: an empty list,
    /// not an error (the reference exists).
    @Test(arguments: IndependentProtocolRevision.allCases)
    func referencesWithoutACompletionHandlerSuggestNothing(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "quiet://{x}", name: "quiet")) { _, _ in [] }
        let client = try await IndependentProtocol.client(server, revision)
        for ref in [["type": "ref/prompt", "name": "bare"], ["type": "ref/resource", "uri": "quiet://{x}"]] as [JSONObject] {
            let response = try await client.request("completion/complete", ["ref": .object(ref), "argument": ["name": "x", "value": "a"]])
            #expect(response.values == [], "\(response)")
            #expect(response["result"]?["completion"]?["hasMore"] ?? false == false)
            #expect(IndependentProtocol.responseViolations(response, to: "completion/complete", in: revision).isEmpty)
        }
    }
}
