#if os(macOS)
import Dispatch
import Foundation
import Limb
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioClientOperationsTests {
    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"])
    func publicOperationsAcrossRevisions(version: String) async throws {
        try await withOperationsPeer(version: version, script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                method=$(extract "$frame" method)
                case "$method" in
                    tools/list)
                        cursor=$(extract "$frame" params.cursor 2>/dev/null || :)
                        if [ "$cursor" = 'opaque:tool-2' ]; then
                            cached "$id" '"tools":[]' 0 private
                        else
                            output_schema=''
                            if [ "$version" != '2025-03-26' ]; then
                                output_schema=',"outputSchema":{"type":"object","properties":{"answer":{"type":"integer"}},"example.test/extension":42}'
                            fi
                            tool=$(printf '{"name":"inspect","inputSchema":{"type":"object","$defs":{"tag":{"type":"string"}},"properties":{"tag":{"$ref":"#/$defs/tag","x-mcp-header":"X-Tag"}},"additionalProperties":false},"_meta":{"example.test/item":{"ready":true}},"example.test/descriptor":"kept"%s}' "$output_schema")
                            cached "$id" "$(printf '"tools":[%s],"nextCursor":"opaque:tool-2","_meta":{"example.test/page":["a",2]},"example.test/opaque":42' "$tool")" 3000 private
                        fi
                        ;;
                    tools/call)
                        link=''
                        if [ "$version" != '2025-03-26' ]; then
                            link=',{"type":"resource_link","name":"linked","uri":"memo:///linked"}'
                        fi
                        content='"content":[{"type":"text","text":"tool reply"},{"type":"image","data":"AQI=","mimeType":"image/png"},{"type":"audio","data":"AgM=","mimeType":"audio/wav"},{"type":"resource","resource":{"uri":"memo:///embedded","text":"embedded reply"}}'
                        complete "$id" "$content$link]"
                        ;;
                    resources/list)
                        cached "$id" '"resources":[{"name":"note","uri":"memo:///note","description":"a note"}],"nextCursor":"opaque:resources-2"' 12 public
                        ;;
                    resources/templates/list)
                        cached "$id" '"resourceTemplates":[{"name":"notes","uriTemplate":"memo:///{topic}"}],"nextCursor":"opaque:templates-2"' 13 private
                        ;;
                    resources/read)
                        cached "$id" '"contents":[{"uri":"memo:///note","text":"hello","mimeType":"text/plain"},{"uri":"memo:///bytes","blob":"AQI=","mimeType":"application/octet-stream"}]' 275 private
                        ;;
                    prompts/list)
                        cached "$id" '"prompts":[{"name":"explain","arguments":[{"name":"topic","required":true}]}],"nextCursor":"opaque:prompts-2"' 14 public
                        ;;
                    prompts/get)
                        complete "$id" '"description":"explanation","messages":[{"role":"user","content":{"type":"text","text":"Explain Swift"}}],"_meta":{"example.test/prompt":true}'
                        ;;
                    completion/complete)
                        complete "$id" '"completion":{"values":["swift","swiftui"],"total":3,"hasMore":true}'
                        ;;
                    *) reject "$id" '{"code":-32601,"message":"unexpected method"}' ;;
                esac
            done
            """#) { client, peer in
            #expect(client.protocolVersion.rawValue == version)
            let tools = try await client.listTools(options: ordinaryRequest)
            let tool = try #require(tools.value.items.first)
            #expect(tools.value.items.count == 1)
            #expect(tool.name == "inspect")
            #expect(tools.value.nextCursor == "opaque:tool-2")
            #expect(tools.metadata == ["example.test/page": ["a", 2]])
            #expect(tools.raw["example.test/opaque"] == 42)
            let rawTool = try #require(tools.raw["tools"]?.arrayValue?.first)
            #expect(rawTool["example.test/descriptor"] == "kept")
            #expect(rawTool["_meta"]?["example.test/item"] == ["ready": true])
            let schema: JSONObject = [
                "type": "object",
                "$defs": ["tag": ["type": "string"]],
                "properties": ["tag": ["$ref": "#/$defs/tag", "x-mcp-header": "X-Tag"]],
                "additionalProperties": false,
            ]
            #expect(rawTool["inputSchema"] == .object(schema))
            #expect(tool.inputSchema == schema)
            #expect(tool.meta == ["example.test/item": ["ready": true]])
            if version == "2025-03-26" {
                #expect(tool.outputSchema == nil)
            } else {
                let outputSchema: JSONObject = [
                    "type": "object",
                    "properties": ["answer": ["type": "integer"]],
                    "example.test/extension": 42,
                ]
                #expect(tool.outputSchema == outputSchema)
                #expect(rawTool["outputSchema"] == .object(outputSchema))
            }

            let second = try await client.listTools(cursor: tools.value.nextCursor, options: ordinaryRequest)
            #expect(second.value.items.isEmpty)
            #expect(second.value.nextCursor == nil)

            // The declared schema requires a string when tag is provided and forbids other members.
            let call = try await client.callTool(
                "inspect", arguments: ["tag": 7, "extra": true], options: ordinaryRequest
            )
            var expectedContent: [ContentBlock] = [
                .text("tool reply"),
                .image(data: "AQI=", mimeType: "image/png"),
                .audio(data: "AgM=", mimeType: "audio/wav"),
                .resource(.text(uri: "memo:///embedded", text: "embedded reply")),
            ]
            if version != "2025-03-26" {
                expectedContent.append(.resourceLink(.init(uri: "memo:///linked", name: "linked")))
            }
            #expect(call.value.content == expectedContent)
            #expect(call.value.isError == false)
            #expect(call.raw["content"]?.arrayValue?.first == ["type": "text", "text": "tool reply"])

            let resources = try await client.listResources(cursor: "resources/start", options: ordinaryRequest)
            #expect(resources.value.items.map(\.name) == ["note"])
            #expect(resources.value.items.map(\.uri) == ["memo:///note"])
            #expect(resources.value.nextCursor == "opaque:resources-2")

            let templates = try await client.listResourceTemplates(cursor: "templates/start", options: ordinaryRequest)
            #expect(templates.value.items.map(\.name) == ["notes"])
            #expect(templates.value.items.map(\.uriTemplate) == ["memo:///{topic}"])
            #expect(templates.value.nextCursor == "opaque:templates-2")

            let read = try await client.readResource("memo:///note", options: ordinaryRequest)
            #expect(read.value == [
                .text(uri: "memo:///note", mimeType: "text/plain", text: "hello"),
                .blob(uri: "memo:///bytes", mimeType: "application/octet-stream", base64: "AQI="),
            ])
            #expect(read.raw["contents"]?.arrayValue?.last?["blob"] == "AQI=")

            let prompts = try await client.listPrompts(cursor: "prompts/start", options: ordinaryRequest)
            #expect(prompts.value.items.map(\.name) == ["explain"])
            #expect(prompts.value.nextCursor == "opaque:prompts-2")
            let prompt = try await client.getPrompt("explain", arguments: ["topic": "Swift"], options: ordinaryRequest)
            #expect(prompt.value.description == "explanation")
            #expect(prompt.value.messages == [.user("Explain Swift")])
            #expect(prompt.metadata == ["example.test/prompt": true])

            let promptCompletion = try await client.complete(
                .prompt(name: "explain"), argument: "topic", value: "sw",
                context: ["language": "en"], options: ordinaryRequest
            )
            let templateCompletion = try await client.complete(
                .resource(uri: "memo:///{topic}"), argument: "topic", value: "", options: ordinaryRequest
            )
            for value in [promptCompletion.value, templateCompletion.value] {
                #expect(value.values == ["swift", "swiftui"])
                #expect(value.total == 3)
                #expect(value.hasMore == true)
            }

            if version == "2026-07-28" {
                #expect(tools.cache?.ttlMilliseconds == 3000)
                #expect(tools.cache?.scope == .private)
                #expect(second.cache?.ttlMilliseconds == 0)
                #expect(second.cache?.scope == .private)
                #expect(resources.cache?.ttlMilliseconds == 12)
                #expect(templates.cache?.ttlMilliseconds == 13)
                #expect(prompts.cache?.ttlMilliseconds == 14)
                #expect(read.cache?.ttlMilliseconds == 275)
                #expect(read.cache?.scope == .private)
            } else {
                #expect(tools.cache == nil)
                #expect(second.cache == nil)
                #expect(resources.cache == nil)
                #expect(templates.cache == nil)
                #expect(prompts.cache == nil)
                #expect(read.cache == nil)
            }
            #expect(call.cache == nil)
            #expect(prompt.cache == nil)
            #expect(promptCompletion.cache == nil)

            let requests = try peer.requests()
            #expect(requests.compactMap { $0["method"]?.stringValue } == [
                "tools/list", "tools/list", "tools/call", "resources/list", "resources/templates/list",
                "resources/read", "prompts/list", "prompts/get", "completion/complete", "completion/complete",
            ])
            try #require(requests.count == 10)
            let params = requests.map { $0["params"] }
            #expect(params[0]?["cursor"] == nil)
            #expect(params[1]?["cursor"] == "opaque:tool-2")
            #expect(params[2]?["name"] == "inspect")
            #expect(params[2]?["arguments"] == ["tag": 7, "extra": true])
            #expect(params[3]?["cursor"] == "resources/start")
            #expect(params[4]?["cursor"] == "templates/start")
            #expect(params[5]?["uri"] == "memo:///note")
            #expect(params[6]?["cursor"] == "prompts/start")
            #expect(params[7]?["name"] == "explain")
            #expect(params[7]?["arguments"] == ["topic": "Swift"])
            #expect(params[8]?["ref"] == ["type": "ref/prompt", "name": "explain"])
            #expect(params[8]?["argument"] == ["name": "topic", "value": "sw"])
            if version == "2025-03-26" {
                #expect(params[8]?["context"] == nil)
            } else {
                #expect(params[8]?["context"] == ["arguments": ["language": "en"]])
            }
            #expect(params[9]?["ref"] == ["type": "ref/resource", "uri": "memo:///{topic}"])
            #expect(params[9]?["argument"] == ["name": "topic", "value": ""])
            #expect(params[9]?["context"] == nil)
            let expectedVersion: JSONValue? = version == "2026-07-28" ? .string(version) : nil
            for param in params {
                #expect(param?["_meta"]?["io.modelcontextprotocol/protocolVersion"] == expectedVersion)
                #expect(param?["_meta"]?["progressToken"] == nil)
            }
        }
    }

    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"])
    func typedToolUsesStructuredOutputOrOneStrictJSONTextBlock(version: String) async throws {
        try await withOperationsPeer(version: version, script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                name=$(extract "$frame" params.name)
                case "$name" in
                    value)
                        if [ "$version" = '2025-03-26' ]; then
                            complete "$id" '"content":[{"type":"text","text":"{\"answer\":9007199254740993}"}]'
                        else
                            complete "$id" '"content":[{"type":"text","text":"{\"answer\":8}"}],"structuredContent":{"answer":9007199254740993}'
                        fi
                        ;;
                    incomplete-json)
                        complete "$id" '"content":[{"type":"text","text":"{\"answer\":1} trailing"}]'
                        ;;
                    multiple-blocks)
                        complete "$id" '"content":[{"type":"text","text":"{\"answer\":1}"},{"type":"text","text":""}]'
                        ;;
                    wrong-output)
                        if [ "$version" = '2025-03-26' ]; then
                            complete "$id" '"content":[{"type":"text","text":"{\"answer\":\"seven\"}"}]'
                        else
                            complete "$id" '"content":[{"type":"text","text":"{\"answer\":7}"}],"structuredContent":{"answer":"seven"}'
                        fi
                        ;;
                    tool-error)
                        complete "$id" '"content":[{"type":"text","text":"tool could not finish"}],"isError":true'
                        ;;
                    remote-error)
                        reject "$id" '{"code":-32602,"message":"tool rejected","data":{"example.test/why":"fixture"}}'
                        ;;
                    bad-result) complete "$id" '"content":{}' ;;
                    *) reject "$id" '{"code":-32601,"message":"unexpected call"}' ;;
                esac
            done
            """#) { client, peer in
            let arguments = ["input": 41]
            let result = try await client.callTool("value", arguments: arguments, decoding: [String: Int].self, options: ordinaryRequest)
            #expect(result.value.output == ["answer": 9_007_199_254_740_993])
            #expect(result.value.result.content.count == 1)
            #expect(result.value.result.isError == false)
            if version == "2025-03-26" {
                #expect(result.raw["structuredContent"] == nil)
            } else {
                #expect(result.raw["structuredContent"] == ["answer": 9_007_199_254_740_993])
            }

            for name in ["incomplete-json", "multiple-blocks", "wrong-output"] {
                let error = await #expect(throws: ClientResponseError.self) {
                    try await client.callTool(name, arguments: arguments, decoding: [String: Int].self, options: ordinaryRequest)
                }
                guard case .invalidToolOutput? = error else {
                    Issue.record("Expected invalidToolOutput for \(name), got \(String(describing: error))")
                    continue
                }
            }

            let failure = try await client.callTool(
                "tool-error", arguments: arguments, decoding: [String: Int].self, options: ordinaryRequest
            )
            #expect(failure.value.result.isError)
            #expect(failure.value.output == nil)
            #expect(failure.raw["isError"] == true)
            await #expect(throws: MCPError(code: -32602, message: "tool rejected", data: ["example.test/why": "fixture"])) {
                try await client.callTool("remote-error", options: ordinaryRequest)
            }
            await expectInvalidResult("tools/call") {
                try await client.callTool("bad-result", options: ordinaryRequest)
            }
            let invalidArguments = await #expect(throws: ClientResponseError.self) {
                try await client.callTool("invalid-arguments", arguments: [1, 2], decoding: Int.self, options: ordinaryRequest)
            }
            guard case .invalidToolArguments? = invalidArguments else {
                Issue.record("Expected invalidToolArguments, got \(String(describing: invalidArguments))")
                return
            }

            let requests = try peer.requests()
            #expect(requests.compactMap { $0["params"]?["name"]?.stringValue } == [
                "value", "incomplete-json", "multiple-blocks", "wrong-output", "tool-error", "remote-error", "bad-result",
            ])
            #expect(requests.first?["params"]?["arguments"] == ["input": 41])
            #expect(requests.last?["params"]?["arguments"] == nil)
        }
    }

    @Test(arguments: ["2025-03-26", "2026-07-28"])
    func descriptorCallValidatesSuccessfulOutputWithoutDiscoveringTools(version: String) async throws {
        try await withOperationsPeer(version: version, script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                if [ "$(extract "$frame" method)" != 'tools/call' ]; then
                    reject "$id" '{"code":-32601,"message":"unexpected method"}'
                    continue
                fi
                case "$(extract "$frame" params.name)" in
                    accepted) score=12 ;;
                    violated) score=1 ;;
                    failed)
                        complete "$id" '"isError":true,"content":[{"type":"text","text":"execution failed"}]'
                        continue
                        ;;
                    text-only)
                        complete "$id" '"content":[{"type":"text","text":"unstructured reply"}]'
                        continue
                        ;;
                    *) reject "$id" '{"code":-32602,"message":"unexpected tool"}'; continue ;;
                esac
                if [ "$version" = '2025-03-26' ]; then
                    complete "$id" "$(printf '%s%s%s' '"content":[{"type":"text","text":"{\"score\":' "$score" '}"}]')"
                else
                    complete "$id" "$(printf '%s%s%s' '"content":[{"type":"text","text":"{\"score\":99}"}],"structuredContent":{"score":' "$score" '}')"
                fi
            done
            """#) { client, peer in
            let schema: JSONObject = [
                "type": "object",
                "properties": ["score": ["type": "integer", "minimum": 10]],
                "required": ["score"],
            ]
            let accepted = ToolDefinition(name: "accepted", outputSchema: schema)
            let plain = try await client.callTool(accepted, arguments: ["input": 3], options: ordinaryRequest)
            #expect(plain.value.isError == false)
            #expect(plain.value.content.count == 1)
            let typed = try await client.callTool(
                accepted, arguments: ["input": 4], decoding: [String: Int].self, options: ordinaryRequest
            )
            #expect(typed.value.output == ["score": 12])

            let violated = ToolDefinition(name: "violated", outputSchema: schema)
            let plainError = await #expect(throws: ClientResponseError.self) {
                try await client.callTool(violated, options: ordinaryRequest)
            }
            let typedError = await #expect(throws: ClientResponseError.self) {
                try await client.callTool(violated, arguments: ["input": 5], decoding: [String: Int].self, options: ordinaryRequest)
            }
            for error in [plainError, typedError] {
                guard case let .toolOutputSchemaViolation(violation)? = error else {
                    Issue.record("Expected toolOutputSchemaViolation, got \(String(describing: error))")
                    continue
                }
                #expect(violation.path == ["score"])
                #expect(violation.reason == "must be at least 10")
            }

            let failed = ToolDefinition(name: "failed", outputSchema: schema)
            let failedPlain = try await client.callTool(failed, options: ordinaryRequest)
            let failedTyped = try await client.callTool(
                failed, arguments: ["input": 6], decoding: [String: Int].self, options: ordinaryRequest
            )
            #expect(failedPlain.value.isError)
            #expect(failedTyped.value.result.isError)
            #expect(failedTyped.value.output == nil)

            let unsupported = ToolDefinition(name: "invalid", outputSchema: ["required": 42])
            let badPlainSchema = await #expect(throws: ClientResponseError.self) {
                try await client.callTool(unsupported, options: ordinaryRequest)
            }
            let badTypedSchema = await #expect(throws: ClientResponseError.self) {
                try await client.callTool(unsupported, arguments: ["input": 7], decoding: [String: Int].self, options: ordinaryRequest)
            }
            for error in [badPlainSchema, badTypedSchema] {
                guard case .invalidToolSchema? = error else {
                    Issue.record("Expected invalidToolSchema, got \(String(describing: error))")
                    continue
                }
            }

            let text = try await client.callTool(ToolDefinition(name: "text-only"), options: ordinaryRequest)
            #expect(text.raw["content"] == [["type": "text", "text": "unstructured reply"]])
            let requests = try peer.requests()
            #expect(requests.allSatisfy { $0["method"] == "tools/call" })
            #expect(requests.compactMap { $0["params"]?["name"]?.stringValue } == [
                "accepted", "accepted", "violated", "violated", "failed", "failed", "text-only",
            ])
            #expect(requests.first?["params"]?["arguments"] == ["input": 3])
        }
    }

    @Test(arguments: ["2025-03-26", "2026-07-28"])
    func explicitToolOutputExtractorRunsOnlyWhenStructuredContentIsMissing(version: String) async throws {
        try await withOperationsPeer(version: version, script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                [ "$(extract "$frame" method)" = 'tools/call' ]
                case "$(extract "$frame" params.name)" in
                    text) complete "$id" '"content":[{"type":"text","text":"score=12"}]' ;;
                    violates) complete "$id" '"content":[{"type":"text","text":"score=1"}]' ;;
                    malformed) complete "$id" '"content":[{"type":"text","text":"missing score"}]' ;;
                    failed) complete "$id" '"isError":true,"content":[{"type":"text","text":"failed"}]' ;;
                    null) complete "$id" '"structuredContent":null,"content":[{"type":"text","text":"score=12"}]' ;;
                    object) complete "$id" '"structuredContent":{"score":15},"content":[{"type":"text","text":"score=12"}]' ;;
                    *) exit 1 ;;
                esac
            done
            """#) { client, _ in
            let arguments = JSONObject()
            let extracting: ToolOutputExtractor = { result throws(JSONDecodingError) in
                let prefix = "score="
                guard result.content.count == 1,
                      case let .text(text, _, _)? = result.content.first,
                      text.hasPrefix(prefix), let score = Int(text.dropFirst(prefix.count))
                else {
                    throw JSONDecodingError("expected score text", path: ["content"])
                }
                return ["score": JSONValue(score)]
            }
            let byName = try await client.callTool(
                "text", arguments: arguments, decoding: [String: Int].self,
                extracting: extracting, options: ordinaryRequest
            )
            #expect(byName.value.output == ["score": 12])

            let schema: JSONObject = [
                "type": "object",
                "properties": ["score": ["type": "integer", "minimum": 10]],
                "required": ["score"],
            ]
            let byDescriptor = try await client.callTool(
                ToolDefinition(name: "text", outputSchema: schema), arguments: arguments, decoding: [String: Int].self,
                extracting: extracting, options: ordinaryRequest
            )
            #expect(byDescriptor.value.output == ["score": 12])

            let invalidSchemaOutput = await #expect(throws: ClientResponseError.self) {
                try await client.callTool(
                    ToolDefinition(name: "violates", outputSchema: schema), arguments: arguments, decoding: Int.self,
                    extracting: extracting, options: ordinaryRequest
                )
            }
            if case let .toolOutputSchemaViolation(violation)? = invalidSchemaOutput {
                #expect(violation.path == ["score"])
                #expect(violation.reason == "must be at least 10")
            } else {
                Issue.record("Expected toolOutputSchemaViolation, got \(String(describing: invalidSchemaOutput))")
            }
            let invalidExtractedOutput = await #expect(throws: ClientResponseError.self) {
                try await client.callTool(
                    "malformed", arguments: arguments, decoding: [String: Int].self,
                    extracting: extracting, options: ordinaryRequest
                )
            }
            if case let .invalidToolOutput(error)? = invalidExtractedOutput {
                #expect(error == JSONDecodingError("expected score text", path: ["content"]))
            } else {
                Issue.record("Expected invalidToolOutput, got \(String(describing: invalidExtractedOutput))")
            }

            let rejectsExtraction: ToolOutputExtractor = { _ throws(JSONDecodingError) in
                throw JSONDecodingError("extractor should be skipped")
            }
            let failed = try await client.callTool(
                "failed", arguments: arguments, decoding: [String: Int].self,
                extracting: rejectsExtraction, options: ordinaryRequest
            )
            #expect(failed.value.result.isError)
            #expect(failed.value.output == nil)

            if version == "2026-07-28" {
                let null = try await client.callTool(
                    "null", arguments: arguments, decoding: JSONValue.self,
                    extracting: rejectsExtraction, options: ordinaryRequest
                )
                #expect(null.value.output == .some(.null))
                let object = try await client.callTool(
                    ToolDefinition(name: "object", outputSchema: schema), arguments: arguments, decoding: [String: Int].self,
                    extracting: rejectsExtraction, options: ordinaryRequest
                )
                #expect(object.value.output == ["score": 15])
            }
        }
    }

    @Test func modernStructuredNullArrayAndScalarArePresent() async throws {
        try await withOperationsPeer(script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                case "$(extract "$frame" params.name)" in
                    'null') output='null' ;;
                    array) output='[true,34,"tag"]' ;;
                    scalar) output='9007199254740993' ;;
                    *) exit 1 ;;
                esac
                complete "$id" "$(printf '"content":[{"type":"text","text":"0"}],"structuredContent":%s' "$output")"
            done
            """#) { client, _ in
            let outputs: [(String, JSONValue)] = [
                ("null", .null), ("array", [true, 34, "tag"]), ("scalar", 9_007_199_254_740_993),
            ]
            for (name, expected) in outputs {
                let result = try await client.callTool(
                    name, arguments: JSONObject(), decoding: JSONValue.self, options: ordinaryRequest
                )
                #expect(result.value.output == expected)
                #expect(result.raw["structuredContent"] == expected)
            }
        }
    }

    @Test(arguments: ["2025-06-18", "2025-11-25"])
    func legacyStructuredContentMustBeAnObject(version: String) async throws {
        try await withOperationsPeer(version: version, script: #"""
            while receive; do
                complete "$(wire_value id "$frame")" '"content":[{"type":"text","text":"42"}],"structuredContent":[42]'
            done
            """#) { client, _ in
            await expectInvalidResult("tools/call") {
                try await client.callTool("inspect", arguments: JSONObject(), decoding: JSONValue.self, options: ordinaryRequest)
            }
        }
    }

    @Test func modernResponsesCheckDiscriminatorsAndRequiredCache() async throws {
        try await withOperationsPeer(script: #"""
            receive; reply "$(wire_value id "$frame")" '{"tools":[],"ttlMs":20,"cacheScope":"public"}'
            receive; reply "$(wire_value id "$frame")" '{"resultType":"example.test/unknown","tools":[],"ttlMs":20,"cacheScope":"public"}'
            receive; complete "$(wire_value id "$frame")" '"tools":[],"ttlMs":20'
            receive; complete "$(wire_value id "$frame")" '"resources":[],"ttlMs":1.5,"cacheScope":"public"'
            receive; complete "$(wire_value id "$frame")" '"resourceTemplates":[],"ttlMs":-1,"cacheScope":"public"'
            receive; complete "$(wire_value id "$frame")" '"prompts":[],"ttlMs":0,"cacheScope":"shared"'
            receive; complete "$(wire_value id "$frame")" '"contents":[],"cacheScope":"public"'
            receive; reply "$(wire_value id "$frame")" '{"resultType":"input_required","requestState":"c3RhdGU="}'
            receive; reply "$(wire_value id "$frame")" '{"resultType":"input_required"}'
            receive; cached "$(wire_value id "$frame")" '"tools":[]' 9007199254740993 public
            while receive; do :; done
            """#) { client, _ in
            for _ in 0..<3 {
                await expectInvalidResult("tools/list") { try await client.listTools(options: ordinaryRequest) }
            }
            await expectInvalidResult("resources/list") { try await client.listResources(options: ordinaryRequest) }
            let templates = try await client.listResourceTemplates(options: ordinaryRequest)
            #expect(templates.value.items.isEmpty)
            #expect(templates.cache?.ttlMilliseconds == 0)
            #expect(templates.cache?.scope == .public)
            #expect(templates.raw["ttlMs"] == -1)
            await expectInvalidResult("prompts/list") { try await client.listPrompts(options: ordinaryRequest) }
            await expectInvalidResult("resources/read") {
                try await client.readResource("memo:///note", options: ordinaryRequest)
            }
            await expectInvalidResult("prompts/list") { try await client.listPrompts(options: ordinaryRequest) }
            await expectInvalidResult("tools/call") { try await client.callTool("inspect", options: ordinaryRequest) }
            let list = try await client.listTools(options: ordinaryRequest)
            #expect(list.value.items.isEmpty)
            #expect(list.cache?.ttlMilliseconds == 9_007_199_254_740_993)
        }
    }

    @Test func toolCatalogRejectsInvalidOrOverLimitSchemas() async throws {
        try await withOperationsPeer(script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                case "$(extract "$frame" params.cursor)" in
                    nested)
                        tool='{"name":"invalid","inputSchema":{"type":"object","properties":{"nested":{"type":"object","required":42}}}}'
                        ;;
                    dialect)
                        tool='{"name":"dialect","inputSchema":{"type":"object","$schema":"https://json-schema.org/draft/2019-09/schema"}}'
                        ;;
                    depth)
                        schema='{"type":"string"}'
                        depth=0
                        while [ "$depth" -lt 40 ]; do
                            schema=$(printf '{"not":%s}' "$schema")
                            depth=$((depth + 1))
                        done
                        tool=$(printf '{"name":"deep","inputSchema":{"type":"object","properties":{"member":%s}}}' "$schema")
                        ;;
                    output)
                        tool='{"name":"invalid-output","inputSchema":{"type":"object"},"outputSchema":{"type":"object","required":42}}'
                        ;;
                    valid)
                        tool='{"name":"valid","inputSchema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"}}'
                        ;;
                    *) exit 1 ;;
                esac
                cached "$id" "$(printf '"tools":[%s]' "$tool")" 0 public
            done
            """#) { client, _ in
            for cursor in ["nested", "dialect", "depth", "output"] {
                await expectInvalidResult("tools/list") {
                    try await client.listTools(cursor: cursor, options: ordinaryRequest)
                }
            }
            let valid = try await client.listTools(cursor: "valid", options: ordinaryRequest)
            #expect(valid.value.items.map(\.name) == ["valid"])
        }
    }

    @Test func requiredInputIsDistinctFromFailureAndDoesNotRetry() async throws {
        try await withOperationsPeer(script: #"""
            while receive; do
                case "$(extract "$frame" method)" in
                    tools/call|resources/read|prompts/get)
                        reply "$(wire_value id "$frame")" '{"resultType":"input_required","requestState":"c3RhdGU=","_meta":{"example.test/round":1}}'
                        ;;
                    *) exit 1 ;;
                esac
            done
            """#) { client, peer in
            await expectInputRequired("tools/call") { try await client.callTool("inspect", options: ordinaryRequest) }
            await expectInputRequired("resources/read") {
                try await client.readResource("memo:///note", options: ordinaryRequest)
            }
            await expectInputRequired("prompts/get") { try await client.getPrompt("explain", options: ordinaryRequest) }
            let methods = try peer.requests().compactMap { $0["method"]?.stringValue }
            #expect(methods == [
                "tools/call", "resources/read", "prompts/get",
            ])
        }
    }

    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"], [false, true])
    func ignoresForeignDecreasingAndLateProgress(version: String, timeOut: Bool) async throws {
        try await withOperationsPeer(version: version, script: #"""
            progress() {
                printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":%s,"total":8.5,"message":"%s"}}\n' "$1" "$2" "$3"
            }
            receive
            interrupted_id=$(wire_value id "$frame")
            interrupted_token=$(wire_value params._meta.progressToken "$frame")
            progress "$interrupted_token" 1.25 first
            progress '"foreign"' 2 foreign
            progress "$interrupted_token" 1 decreasing
            progress "$interrupted_token" 1.25 duplicate
            progress "$interrupted_token" 3 second
            receive
            first=$frame
            receive
            if [ "$(extract "$first" method)" = 'notifications/cancelled' ]; then
                sibling=$frame
            else
                [ "$(extract "$frame" method)" = 'notifications/cancelled' ]
                sibling=$first
            fi
            sibling_id=$(wire_value id "$sibling")
            sibling_token=$(wire_value params._meta.progressToken "$sibling")
            progress "$interrupted_token" 5 late
            complete "$interrupted_id" '"content":[{"type":"text","text":"late result"}]'
            progress "$sibling_token" 4 sibling
            while [ ! -f "$directory/release-sibling" ]; do /bin/sleep 0.01; done
            complete "$sibling_id" '"content":[{"type":"text","text":"sibling result"}]'
            while receive; do :; done
            """#) { client, peer in
            let updates = Mutex<[ClientProgress]>([])
            let collect: @Sendable (ClientProgress) -> Void = { event in updates.withLock { $0.append(event) } }
            let interrupted = Task { @Sendable in
                try await client.callTool("interrupted", options: .init(
                    timeout: .seconds(timeOut ? 2 : 5), onProgress: collect
                ))
            }
            defer { interrupted.cancel() }
            try await waitForOperationsEvent("progress before interruption") {
                updates.withLock { $0.contains { $0.message == "second" } }
            }
            if timeOut {
                await #expect(throws: ClientError.timedOut(.unknown)) { try await interrupted.value }
            } else {
                interrupted.cancel()
                await #expect(throws: ClientError.cancelled(.unknown)) { try await interrupted.value }
            }
            let sibling = Task { @Sendable in
                try await client.callTool("sibling", options: .init(
                    timeout: .seconds(5), onProgress: collect
                ))
            }
            defer { sibling.cancel() }
            try await waitForOperationsEvent("progress from the sibling request") {
                updates.withLock { $0.contains { $0.message == "sibling" } }
            }
            try Data().write(to: peer.directory.appendingPathComponent("release-sibling"))
            let result = try await sibling.value
            #expect(result.raw["content"] == [["type": "text", "text": "sibling result"]])
            let observed = updates.withLock { $0 }
            #expect(observed.map(\.message) == ["first", "second", "sibling"])
            #expect(observed.map(\.progress) == [1.25, 3, 4])
            #expect(observed.map(\.total) == [8.5, 8.5, 8.5])

            let frames = try peer.requests()
            try #require(frames.count == 3)
            let first = try #require(frames.first)
            let second = try #require(frames.first { $0["params"]?["name"] == "sibling" })
            let cancellation = try #require(frames.first { $0["method"] == "notifications/cancelled" })
            let firstToken = try #require(first["params"]?["_meta"]?["progressToken"])
            let secondToken = try #require(second["params"]?["_meta"]?["progressToken"])
            #expect(firstToken != secondToken)
            #expect(first["id"] != second["id"])
            #expect(cancellation["params"]?["requestId"] == first["id"])
        }
    }

    @Test func slowProgressCallbackAllowsOtherOperationsToFinish() async throws {
        try await withOperationsPeer(script: #"""
            receive
            slow_id=$(wire_value id "$frame")
            token=$(wire_value params._meta.progressToken "$frame")
            printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":1}}\n' "$token"
            receive
            [ "$(extract "$frame" params.name)" = 'sibling' ]
            complete "$(wire_value id "$frame")" '"content":[{"type":"text","text":"sibling result"}]'
            complete "$slow_id" '"content":[{"type":"text","text":"slow result"}]'
            while receive; do :; done
            """#) { client, _ in
            let entered = Mutex(false)
            let gateExpired = Mutex(false)
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let slow = Task {
                try await client.callTool("slow", options: .init(timeout: .seconds(5), onProgress: { _ in
                    entered.withLock { $0 = true }
                    let result = gate.wait(timeout: .now() + .seconds(8))
                    gateExpired.withLock { $0 = result == .timedOut }
                }))
            }
            defer { slow.cancel() }
            try await waitForOperationsEvent("the progress callback reaches its gate") { entered.withLock { $0 } }
            let sibling = try await client.callTool("sibling", options: ordinaryRequest)
            let result = try await slow.value
            #expect(sibling.raw["content"] == [["type": "text", "text": "sibling result"]])
            #expect(result.raw["content"] == [["type": "text", "text": "slow result"]])
            #expect(!gateExpired.withLock { $0 })
        }
    }

    @Test func completedRequestsWithRunningProgressCallbacksStillCountAgainstWorkQuota() async throws {
        try await withOperationsPeer(
            options: .init(timeout: .seconds(5), discoveryTimeout: .seconds(1), maxPending: 2),
            script: #"""
                while receive; do
                    id=$(wire_value id "$frame")
                    case "$(extract "$frame" method)" in
                        tools/call)
                            name=$(extract "$frame" params.name)
                            case "$name" in
                                first|second)
                                    token=$(wire_value params._meta.progressToken "$frame")
                                    printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":1}}\n' "$token"
                                    while [ ! -f "$directory/$name" ]; do /bin/sleep 0.01; done
                                    ;;
                            esac
                            complete "$id" '"content":[]'
                            ;;
                        fixture/raw) complete "$id" '"marker":"raw reply"' ;;
                        *) exit 1 ;;
                    esac
                done
                """#
        ) { client, peer in
            let names = ["first", "second"]
            let gates = names.map { _ in OperationsCallbackGate() }
            defer { for gate in gates { gate.release.signal() } }

            for (name, gate) in zip(names, gates) {
                let call = Task { @Sendable in
                    try await client.callTool(name, options: .init(timeout: .seconds(5), onProgress: { _ in gate.block() }))
                }
                defer { call.cancel() }
                try await waitForOperationsEvent("the \(name) callback blocks") { gate.isBlocked }
                try Data().write(to: peer.directory.appendingPathComponent(name))
                let result = try await call.value
                #expect(result.value.content.isEmpty)
            }
            let bothBlocked = gates.allSatisfy(\.isBlocked)
            try #require(bothBlocked)

            await #expect(throws: ClientError.workOverloaded(.notSent)) {
                try await client.callTool("rejected", options: .init(timeout: .seconds(5), onProgress: { _ in }))
            }
            let raw = try await client.request("fixture/raw", timeout: .seconds(5))
            #expect(raw["marker"] == "raw reply")
            let stillBlocked = gates.allSatisfy(\.isBlocked)
            #expect(stillBlocked)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["method"]?.stringValue } == ["tools/call", "tools/call", "fixture/raw"])
            #expect(frames.compactMap { $0["params"]?["name"]?.stringValue } == names)
        }
    }

    @Test func oversizedRequestFailsLocallyAndLeavesTheChildUsable() async throws {
        let maxFrameBytes = 512
        try await withOperationsPeer(
            options: .init(timeout: .seconds(5), discoveryTimeout: .seconds(1), maxFrameBytes: maxFrameBytes),
            script: #"""
                while receive; do
                    [ "$(extract "$frame" method)" = 'tools/call' ]
                    complete "$(wire_value id "$frame")" '"content":[{"type":"text","text":"received"}]'
                done
                """#
        ) { client, peer in
            let payload = String(repeating: "x", count: 1024)
            let error = await #expect(throws: ClientError.self) {
                try await client.callTool("oversized", arguments: ["text": .string(payload)], options: ordinaryRequest)
            }
            if case let .requestTooLarge(bytes, limit)? = error {
                #expect(bytes > payload.utf8.count)
                #expect(limit == maxFrameBytes)
            } else {
                Issue.record("Expected requestTooLarge, got \(String(describing: error))")
            }

            let result = try await client.callTool("normal", arguments: ["text": "ok"], options: ordinaryRequest)
            #expect(result.value.content == [.text("received")])
            let requests = try peer.requests()
            #expect(requests.count == 1)
            #expect(requests.first?["params"]?["name"] == "normal")
            #expect(requests.first?["params"]?["arguments"] == ["text": "ok"])
        }
    }

    @Test func typedCallTimesOutWhileItsDecoderIsStillRunning() async throws {
        try await withOperationsPeer(script: #"""
            while receive; do
                case "$(extract "$frame" method)" in
                    'tools/call')
                        id=$(wire_value id "$frame")
                        if [ "$(extract "$frame" params.name)" = 'slow-decode' ]; then
                            complete "$id" '"content":[],"structuredContent":{"ready":true}'
                        else
                            complete "$id" '"content":[{"type":"text","text":"sibling result"}]'
                        fi
                        ;;
                    'notifications/cancelled') ;;
                    *) exit 1 ;;
                esac
            done
            """#) { client, _ in
            let gate = BlockingOutput.duringTimeout
            let completed = Mutex(false)
            let call = Task { @Sendable in
                defer { completed.withLock { $0 = true } }
                return try await client.callTool(
                    "slow-decode", arguments: JSONObject(), decoding: BlockingOutput.self,
                    options: .init(timeout: .seconds(1))
                )
            }
            defer {
                gate.release.signal()
                call.cancel()
            }
            try await waitForOperationsEvent("the typed decoder starts") { gate.isBlocked }

            let deadline = ContinuousClock.now + .seconds(3)
            while !completed.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let completedBeforeRelease = completed.withLock { $0 }
            #expect(completedBeforeRelease, "Timeout should resolve the request while the decoder is blocked")
            if completedBeforeRelease {
                let sibling = try await client.callTool("sibling", options: ordinaryRequest)
                #expect(sibling.raw["content"] == [["type": "text", "text": "sibling result"]])
            }
            gate.release.signal()
            await #expect(throws: ClientError.timedOut(.unknown)) { try await call.value }
        }
    }

    @Test func aClosedClientDoesNotEncodeTypedArguments() async throws {
        try await withOperationsPeer(script: #"""
            while receive; do exit 1; done
            """#) { client, _ in
            await client.close()
            let arguments = InvalidToolArguments()
            await #expect(throws: ClientError.closed) {
                try await client.callTool(
                    "closed", arguments: arguments, decoding: Int.self, options: ordinaryRequest
                )
            }
            await #expect(throws: ClientError.closed) {
                try await client.callTool(
                    ToolDefinition(name: "closed"), arguments: arguments, decoding: Int.self, options: ordinaryRequest
                )
            }
            #expect(!arguments.wasEncoded.withLock { $0 })
        }
    }

    @Test func anUnfinishedDecoderPreventsASubsequentToolCallFromBeingSent() async throws {
        try await withOperationsPeer(
            options: .init(timeout: .seconds(5), discoveryTimeout: .seconds(1), maxPending: 1),
            script: #"""
                while receive; do
                    case "$(extract "$frame" method)" in
                        tools/call)
                            id=$(wire_value id "$frame")
                            case "$(extract "$frame" params.name)" in
                                slow-decode)
                                    complete "$id" '"content":[],"structuredContent":{"gate":"quota"}'
                                    ;;
                                side-effect)
                                    complete "$id" '"content":[{"type":"text","text":"executed"}]'
                                    ;;
                                *) exit 1 ;;
                            esac
                            ;;
                        'notifications/cancelled') ;;
                        *) exit 1 ;;
                    esac
                done
                """#
        ) { client, peer in
            let gate = BlockingOutput.duringQuota
            let call = Task { @Sendable in
                try await client.callTool(
                    "slow-decode", arguments: JSONObject(), decoding: BlockingOutput.self,
                    options: .init(timeout: .seconds(1))
                )
            }
            defer {
                gate.release.signal()
                call.cancel()
            }
            try await waitForOperationsEvent("the typed decoder starts") { gate.isBlocked }
            await #expect(throws: ClientError.timedOut(.unknown)) { try await call.value }
            try #require(gate.isBlocked)

            await #expect(throws: ClientError.workOverloaded(.notSent)) {
                try await client.callTool("side-effect", options: ordinaryRequest)
            }
            #expect(gate.isBlocked)
            let requests = try peer.requests()
            #expect(requests.compactMap { $0["params"]?["name"]?.stringValue } == ["slow-decode"])
        }
    }

    @Test func explicitCloseResolvesTheCallWhileItsDecoderIsStillRunning() async throws {
        try await withOperationsPeer(script: #"""
            receive
            complete "$(wire_value id "$frame")" '"content":[],"structuredContent":{"gate":"close"}'
            while receive; do :; done
            """#) { client, _ in
            let gate = BlockingOutput.duringClose
            let completed = Mutex(false)
            let call = Task { @Sendable in
                defer { completed.withLock { $0 = true } }
                return try await client.callTool(
                    "slow-decode", arguments: JSONObject(), decoding: BlockingOutput.self,
                    options: .init(timeout: .seconds(30))
                )
            }
            defer {
                gate.release.signal()
                call.cancel()
            }
            try await waitForOperationsEvent("the typed decoder starts") { gate.isBlocked }

            let closed = Mutex(false)
            let close = Task { @Sendable in
                await client.close()
                closed.withLock { $0 = true }
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline, !closed.withLock({ $0 }) || !completed.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(closed.withLock { $0 }, "Client close should return while the decoder is blocked")
            #expect(completed.withLock { $0 }, "Client close should resolve the call while the decoder is blocked")
            #expect(gate.isBlocked)
            gate.release.signal()
            await close.value
            await #expect(throws: ClientError.closedDuringRequest(.unknown)) { try await call.value }
        }
    }

    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"])
    func onlyLegacyRequiresPreviouslyAdvertisedCapabilities(version: String) async throws {
        try await withOperationsPeer(version: version, capabilities: "{}", script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                case "$(extract "$frame" method)" in
                    tools/list)
                        if [ "$version" = '2026-07-28' ]; then
                            cached "$id" '"tools":[]' 0 private
                            continue
                        fi
                        ;;
                    fixture/raw)
                        complete "$id" '"marker":"ready"'
                        continue
                        ;;
                esac
                reject "$id" '{"code":-32601,"message":"fixture received an unadvertised operation"}'
            done
            """#) { client, peer in
            if version == "2026-07-28" {
                let tools = try await client.listTools(options: ordinaryRequest)
                #expect(tools.value.items.isEmpty)
                let requests = try peer.requests()
                #expect(requests.compactMap { $0["method"]?.stringValue } == ["tools/list"])
                return
            }

            await expectUnsupportedMethod("tools/list") { try await client.listTools(options: ordinaryRequest) }
            await expectUnsupportedMethod("tools/call") { try await client.callTool("run", options: ordinaryRequest) }
            let arguments = InvalidToolArguments()
            await expectUnsupportedMethod("tools/call") {
                try await client.callTool("run", arguments: arguments, decoding: Int.self, options: ordinaryRequest)
            }
            let tool = ToolDefinition(name: "run")
            await expectUnsupportedMethod("tools/call") { try await client.callTool(tool, options: ordinaryRequest) }
            await expectUnsupportedMethod("tools/call") {
                try await client.callTool(tool, arguments: arguments, decoding: Int.self, options: ordinaryRequest)
            }
            #expect(!arguments.wasEncoded.withLock { $0 })
            await expectUnsupportedMethod("resources/list") { try await client.listResources(options: ordinaryRequest) }
            await expectUnsupportedMethod("resources/templates/list") {
                try await client.listResourceTemplates(options: ordinaryRequest)
            }
            await expectUnsupportedMethod("resources/read") {
                try await client.readResource("memo:///note", options: ordinaryRequest)
            }
            await expectUnsupportedMethod("prompts/list") { try await client.listPrompts(options: ordinaryRequest) }
            await expectUnsupportedMethod("prompts/get") { try await client.getPrompt("explain", options: ordinaryRequest) }
            await expectUnsupportedMethod("completion/complete") {
                try await client.complete(.prompt(name: "explain"), argument: "topic", value: "", options: ordinaryRequest)
            }
            await expectUnsupportedMethod("logging/setLevel") {
                try await client.setLogLevel(.info, options: ordinaryRequest)
            }

            let raw = try await client.request("fixture/raw", timeout: .seconds(5))
            #expect(raw["marker"] == "ready")
            let requests = try peer.requests()
            #expect(requests.compactMap { $0["method"]?.stringValue } == ["fixture/raw"])
        }
    }

    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"])
    func sendsProfileSpecificLoggingAndPublishesMessages(version: String) async throws {
        try await withOperationsPeer(version: version, script: #"""
            while receive; do
                id=$(wire_value id "$frame")
                case "$(extract "$frame" method)" in
                    logging/setLevel) reply "$id" '{}' ;;
                    tools/call)
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"warning","logger":"stderr","data":"unrelated standard error"}}' >&2
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"verbose","data":"invalid level"}}'
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"warning","logger":"operations-peer","data":{"number":9007199254740993},"_meta":{"example.test/log":true}}}'
                        complete "$id" '"content":[]'
                        ;;
                    *) reject "$id" '{"code":-32601,"message":"unexpected method"}' ;;
                esac
            done
            """#) { client, peer in
            let stream = await client.logMessages(bufferSize: 2)
            if version == "2026-07-28" {
                let error = await #expect(throws: ClientResponseError.self) {
                    try await client.setLogLevel(.warning, options: ordinaryRequest)
                }
                guard case .unsupportedMethod("logging/setLevel")? = error else {
                    Issue.record("Expected unsupportedMethod, got \(String(describing: error))")
                    return
                }
            } else {
                try await client.setLogLevel(.warning, options: ordinaryRequest)
            }
            _ = try await client.callTool("logs", options: .init(timeout: .seconds(5), logLevel: .warning))
            await client.close()
            var iterator = stream.makeAsyncIterator()
            let message = try #require(await iterator.next())
            #expect(message.level == .warning)
            #expect(message.logger == "operations-peer")
            #expect(message.data == ["number": 9_007_199_254_740_993])
            #expect(message.metadata == ["example.test/log": true])
            #expect(await iterator.next() == nil)

            let requests = try peer.requests()
            let methods = requests.compactMap { $0["method"]?.stringValue }
            if version == "2026-07-28" {
                #expect(methods == ["tools/call"])
                #expect(requests.last?["params"]?["_meta"]?["io.modelcontextprotocol/logLevel"] == "warning")
            } else {
                #expect(methods == ["logging/setLevel", "tools/call"])
                #expect(requests.first?["params"]?["level"] == "warning")
                #expect(requests.last?["params"]?["_meta"]?["io.modelcontextprotocol/logLevel"] == nil)
            }
        }
    }
}

private let ordinaryRequest = ClientRequestOptions(timeout: .seconds(5))

private final class OperationsCallbackGate: Sendable {
    private let blocked = Mutex(false)
    let release = DispatchSemaphore(value: 0)

    var isBlocked: Bool { blocked.withLock { $0 } }

    func block() {
        blocked.withLock { $0 = true }
        _ = release.wait(timeout: .now() + .seconds(20))
        blocked.withLock { $0 = false }
    }
}

private struct BlockingOutput: JSONDecodable, Sendable {
    static let duringTimeout = OperationsCallbackGate()
    static let duringClose = OperationsCallbackGate()
    static let duringQuota = OperationsCallbackGate()

    init(json: JSONValue) throws(JSONDecodingError) {
        let gate: OperationsCallbackGate
        switch json["gate"]?.stringValue {
        case "close": gate = Self.duringClose
        case "quota": gate = Self.duringQuota
        default: gate = Self.duringTimeout
        }
        gate.block()
    }
}

private final class InvalidToolArguments: JSONEncodable, Sendable {
    let wasEncoded = Mutex(false)

    func encode(to writer: inout JSONWriter) {
        wasEncoded.withLock { $0 = true }
        [1].encode(to: &writer)
    }
}

private func expectInvalidResult<Value>(
    _ method: String, _ request: () async throws -> Value,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let error = await #expect(throws: ClientResponseError.self, sourceLocation: sourceLocation) {
        try await request()
    }
    guard case let .invalidResult(actual, _)? = error else {
        Issue.record("Expected invalidResult, got \(String(describing: error))", sourceLocation: sourceLocation)
        return
    }
    #expect(actual == method, sourceLocation: sourceLocation)
}

private func expectInputRequired<Value>(
    _ method: String, _ request: () async throws -> Value,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let error = await #expect(throws: ClientResponseError.self, sourceLocation: sourceLocation) {
        try await request()
    }
    guard case let .inputRequired(actual, result)? = error else {
        Issue.record("Expected inputRequired, got \(String(describing: error))", sourceLocation: sourceLocation)
        return
    }
    #expect(actual == method, sourceLocation: sourceLocation)
    #expect(result == [
        "resultType": "input_required", "requestState": "c3RhdGU=", "_meta": ["example.test/round": 1],
    ], sourceLocation: sourceLocation)
}

private func expectUnsupportedMethod<Value>(
    _ method: String, _ request: () async throws -> Value,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let error = await #expect(throws: ClientResponseError.self, sourceLocation: sourceLocation) {
        try await request()
    }
    guard case let .unsupportedMethod(actual)? = error else {
        Issue.record("Expected unsupportedMethod, got \(String(describing: error))", sourceLocation: sourceLocation)
        return
    }
    #expect(actual == method, sourceLocation: sourceLocation)
}

private struct OperationsPeer {
    let directory: URL
    static let capabilities = #"{"tools":{},"resources":{},"prompts":{},"completions":{},"logging":{}}"#

    func requests() throws -> [JSONValue] {
        let transcript = directory.appendingPathComponent("requests")
        return try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").map {
            try JSON.parse(String($0))
        }
    }

    static let script = #"""
        version=$1
        directory=$2
        extract() { printf '%s\n' "$1" | /usr/bin/plutil -extract "$2" raw -o - -; }
        wire_value() {
            case "$(printf '%s\n' "$2" | /usr/bin/plutil -type "$1" -)" in
                string) printf '"%s"' "$(extract "$2" "$1")" ;;
                integer) extract "$2" "$1" ;;
                *) return 1 ;;
            esac
        }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        reject() { printf '{"jsonrpc":"2.0","id":%s,"error":%s}\n' "$1" "$2"; }
        complete() {
            if [ "$version" = '2026-07-28' ]; then
                reply "$1" "$(printf '{"resultType":"complete",%s}' "$2")"
            else
                reply "$1" "$(printf '{%s}' "$2")"
            fi
        }
        cached() {
            if [ "$version" = '2026-07-28' ]; then
                complete "$1" "$(printf '%s,"ttlMs":%s,"cacheScope":"%s"' "$2" "$3" "$4")"
            else
                complete "$1" "$2"
            fi
        }
        capabilities=$3
        IFS= read -r frame
        [ "$(extract "$frame" method)" = 'server/discover' ]
        if [ "$version" = '2026-07-28' ]; then
            cached "$(wire_value id "$frame")" "$(printf '"supportedVersions":["2026-07-28"],"capabilities":%s' "$capabilities")" 0 public
        else
            reject "$(wire_value id "$frame")" '{"code":-32601,"message":"method not found"}'
            IFS= read -r frame
            [ "$(extract "$frame" method)" = 'initialize' ]
            reply "$(wire_value id "$frame")" "$(printf '{"protocolVersion":"%s","serverInfo":{"name":"operations-peer","version":"1"},"capabilities":%s}' "$version" "$capabilities")"
            IFS= read -r frame
            [ "$(extract "$frame" method)" = 'notifications/initialized' ]
        fi
        receive() {
            IFS= read -r frame || return 1
            printf '%s\n' "$frame" >> "$directory/requests"
        }
        """#
}

private func withOperationsPeer(
    version: String = "2026-07-28", capabilities: String = OperationsPeer.capabilities,
    options: StdioClientOptions = .init(timeout: .seconds(5), discoveryTimeout: .seconds(1)),
    script: String,
    _ body: (Client, OperationsPeer) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-operations-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = OperationsPeer(directory: directory)
    let client = try await Client.connect(
        stdio: .init(
            executable: "/bin/sh",
            arguments: ["-ec", OperationsPeer.script + "\n" + script, "operations-peer", version, directory.path, capabilities]
        ),
        options: options
    )
    do {
        try await body(client, peer)
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}

private func waitForOperationsEvent(_ event: String, condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for \(event)")
        try await Task.sleep(for: .milliseconds(10))
    }
}
#endif
