import Limb
import LimbTesting
import Testing

@Schema
private struct OptionalInputWithDefault {
    var value: String? = "default"
}

@Schema
private struct NonnullableInputWithDefault {
    var value: String = "default"
}

/// Echo an optional string.
@Tool
private struct OptionalInputTool {
    func call(value: String? = "default") -> String {
        value ?? "nil"
    }
}

/// Echo a nonnullable string.
@Tool
private struct NonnullableInputTool {
    func call(value: String = "default") -> String {
        value
    }
}

private typealias ConsumerContext = Limb.RequestContext

/// Echo the input and the method through an explicitly named context alias.
@Tool("macro-consumer.context-alias", contextParameter: "context")
private struct AliasedContextTool {
    func call(value: String, context: ConsumerContext) -> String {
        "\(value) from \(context.method)"
    }
}

private enum MacroInputConsumer {
    struct JSONValue {}
    struct JSONObject {}
    struct ToolDefinition {}
    enum ToolSupport {}
    enum SchemaSupport {}
    struct ToolContext {}

    @Schema
    struct Input {
        var value: Swift.String
    }

    /// Echo the input through the registered tool.
    @Tool("macro-consumer.echo")
    struct Echo {
        func call(input: Input, context: Limb.ToolContext) -> Swift.String {
            "\(input.value) from \(context.method)"
        }
    }
}

@Suite struct IndependentMacroInputContractTests {
    @Test(arguments: ["Limb.ToolContext", "LimbServer.RequestContext"])
    func onlyLimbContextTypesAreInjected(_ contextType: String) {
        // Expanding as syntax keeps the test target buildable if a generated call passes
        // the server context to the unrelated parameter.
        let expansion = IndependentMacroExpansion("""
            enum Other {
                @Schema struct RequestContext {
                    var value: String
                }
            }

            /// Echo the caller's payload and the method.
            @Tool
            struct Echo {
                func call(payload: Other.RequestContext, context: \(contextType)) -> String {
                    "\\(payload.value) from \\(context.method)"
                }
            }
            """)

        #expect(expansion.errors.isEmpty, "\(expansion.errors)")
        #expect(expansion.expanded.contains("\"payload\""), "\(expansion.expanded)")
        #expect(!expansion.expanded.contains("\"context\""), "\(expansion.expanded)")
    }

    @Test func expandedToolAndSchemaWorkInAScopeWithUnrelatedTypes() async throws {
        let server = try Server(name: "consumer", version: "1") { MacroInputConsumer.Echo() }
        let client = TestClient(server)
        let name = "macro-consumer.echo"
        let listed = try #require(try await client.independentMacroListed(name))
        #expect(listed["inputSchema"]?["required"] == ["input"])

        let reply = try await client.independentMacroCall(name, ["input": ["value": "consumer value"]])
        #expect(reply.independentMacroFirstText == "consumer value from tools/call", "\(reply)")
    }

    @Test func explicitlyNamedContextAliasIsInjected() async throws {
        let server = try Server(name: "consumer", version: "1") { AliasedContextTool() }
        let client = TestClient(server)
        let name = "macro-consumer.context-alias"
        let listed = try #require(try await client.independentMacroListed(name))
        #expect(listed["inputSchema"]?["properties"]?.objectValue?.map(\.key) == ["value"])
        #expect(listed["inputSchema"]?["required"] == ["value"])

        let reply = try await client.independentMacroCall(name, ["value": "aliased context"])
        #expect(reply.independentMacroFirstText == "aliased context from tools/call", "\(reply)")
    }

    @Test func schemaDistinguishesAbsentNullAndPresentValues() throws {
        #expect(try OptionalInputWithDefault(json: [:]).value == "default")
        #expect(try OptionalInputWithDefault(json: ["value": .null]).value == nil)
        #expect(try OptionalInputWithDefault(json: ["value": "supplied"]).value == "supplied")

        #expect(try NonnullableInputWithDefault(json: [:]).value == "default")
        #expect(throws: JSONDecodingError.self) {
            try NonnullableInputWithDefault(json: ["value": .null])
        }
        #expect(try NonnullableInputWithDefault(json: ["value": "supplied"]).value == "supplied")
    }

    @Test(arguments: [false, true])
    func toolDistinguishesAbsentNullAndPresentValues(modern: Bool) async throws {
        let server = try Server(name: "inputs", version: "1") {
            OptionalInputTool()
            NonnullableInputTool()
        }
        let client = TestClient(server, modern: modern)
        if !modern {
            let initialization = try await client.initialize()
            try #require(initialization["result"] != nil, "\(initialization)")
        }

        let optional = OptionalInputTool.definition.name
        let required = NonnullableInputTool.definition.name
        for (arguments, expected) in [([:], "default"), (["value": "supplied"], "supplied")] as [(JSONValue, String)] {
            for name in [optional, required] {
                let reply = try await client.independentMacroCall(name, arguments)
                #expect(reply.independentMacroFirstText == expected, "\(reply)")
            }
        }

        let accepted = try await client.independentMacroCall(optional, ["value": .null])
        #expect(accepted.independentMacroFirstText == "nil", "\(accepted)")
        let rejected = try await client.independentMacroCall(required, ["value": .null])
        #expect(rejected["result"]?["isError"] == true || rejected["error"]?["code"] == -32602, "\(rejected)")
    }
}
