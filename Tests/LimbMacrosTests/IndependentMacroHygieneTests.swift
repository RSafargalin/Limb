import Limb
import LimbTesting
import Testing


// MARK: - Fixtures

@Schema
private struct IMHygieneProperties: Equatable {
    var arguments: Int
    var value: Int = 1
    var writer: Int
    var context: Int
    var result: Int
    var schema: Int
    var key: Int
    var json: Int
    var error: Int?
    var description: String
    var type: String
    var required: [String]
    var properties: [String: Int]
    var raw: String
    var rawValue: String
    var encoded: Bool
    var optional: Int?
    var some: Int
    var none: Int?
}

/// A fixture.
@Tool
private struct IMHygieneParameters {
    func call(
        arguments: Int, object: Int, value: Int, writer: Int, result: Int, schema: Int, key: Int, json: Int, error: Int,
        definition: Int, name: Int, call: Int, type: Int, context: String, tool: Int, required: Int, properties: Int,
        argument_arguments: Int, decode: Int, arguments_: Int
    ) -> JSONValue {
        [
            "arguments": JSONValue(arguments), "object": JSONValue(object), "value": JSONValue(value), "writer": JSONValue(writer),
            "result": JSONValue(result), "schema": JSONValue(schema), "key": JSONValue(key), "json": JSONValue(json),
            "error": JSONValue(error), "definition": JSONValue(definition), "name": JSONValue(name), "call": JSONValue(call),
            "type": JSONValue(type), "context": .string(context), "tool": JSONValue(tool), "required": JSONValue(required),
            "properties": JSONValue(properties), "argument_arguments": JSONValue(argument_arguments), "decode": JSONValue(decode),
            "arguments_": JSONValue(arguments_),
        ]
    }
}

/// Stored properties named like the generated method's parameters and members.
@Tool
private struct IMHygieneToolProperties {
    let arguments: Int
    let context: String
    let definition: Int
    func call(x: Int) -> String { "\(x + arguments) \(context) \(definition)" }
}

/// A `call` whose labels are exactly those of the generated `call(arguments:context:)`.
@Tool
private struct IMHygieneOverload {
    func call(arguments: [String], context: ToolContext) -> String { arguments.joined(separator: "+") + " " + context.method }
}

/// A parameter named `context` that is not the context, next to one that is.
@Tool
private struct IMHygieneTwoContexts {
    func call(context: String, ctx: ToolContext) -> String { "\(context) \(ctx.method)" }
}

private typealias IMMaybeInt = Int?

/// Optional types the macro cannot recognise by their spelling.
@Schema
private struct IMAliasOptional: Equatable {
    var plain: Int
    var aliased: IMMaybeInt
    var qualified: Swift.Optional<Int>
}

/// A fixture.
@Tool
private struct IMAliasOptionalTool {
    func call(plain: Int, aliased: IMMaybeInt, qualified: Swift.Optional<Int>) -> String {
        "\(plain) \(aliased.map(String.init) ?? "-") \(qualified.map(String.init) ?? "-")"
    }
}

// MARK: - Tests

@Suite struct IndependentMacroHygieneTests {
    @Test func propertiesNamedLikeGeneratedIdentifiers() throws {
        let names = [
            "arguments", "value", "writer", "context", "result", "schema", "key", "json", "error", "description", "type", "required",
            "properties", "raw", "rawValue", "encoded", "optional", "some", "none",
        ]
        #expect(IMHygieneProperties.jsonSchema["properties"]?.objectValue?.map(\.key) == names)
        IndependentMacroCheckSchema(IMHygieneProperties.jsonSchema)
        let value = IMHygieneProperties(
            arguments: 1, value: 2, writer: 3, context: 4, result: 5, schema: 6, key: 7, json: 8, error: 9, description: "d", type: "t",
            required: ["r"], properties: ["p": 10], raw: "raw", rawValue: "rv", encoded: true, optional: 11, some: 12, none: nil)
        IndependentMacroCheckRoundTrip(value)
        #expect(value.jsonValue["json"] == 8)
        #expect(value.jsonValue["schema"] == 6)
        #expect(value.jsonValue["value"] == 2)
        // The default of `value` is used when it is absent, even though the decoder has a
        // local of the same name.
        var object = value.jsonValue.objectValue ?? [:]
        object.removeValue(forKey: "value")
        #expect(try IMHygieneProperties(json: .object(object)).value == 1)
    }

    @Test func parametersNamedLikeGeneratedIdentifiers() async throws {
        let server = try Server(name: "hygiene", version: "1") {
            IMHygieneParameters()
            IMHygieneToolProperties(arguments: 100, context: "ctx", definition: 7)
            IMHygieneOverload()
            IMHygieneTwoContexts()
        }
        let client = TestClient(server)
        let arguments: JSONObject = [
            "arguments": 1, "object": 2, "value": 3, "writer": 4, "result": 5, "schema": 6, "key": 7, "json": 8, "error": 9,
            "definition": 10, "name": 11, "call": 12, "type": 13, "context": "c", "tool": 14, "required": 15, "properties": 16,
            "argument_arguments": 17, "decode": 18, "arguments_": 19,
        ]
        #expect(IMHygieneParameters.definition.inputSchema["properties"]?.objectValue?.map(\.key) == arguments.map(\.key))
        let response = try await client.independentMacroCall("im_hygiene_parameters", .object(arguments))
        #expect(response["result"]?["structuredContent"] == .object(arguments))

        #expect(try await client.independentMacroCall("im_hygiene_tool_properties", ["x": 1]).independentMacroFirstText == "101 ctx 7")
        #expect(IMHygieneToolProperties.definition.name == "im_hygiene_tool_properties")

        #expect(
            try await client.independentMacroCall("im_hygiene_overload", ["arguments": ["a", "b"]]).independentMacroFirstText == "a+b tools/call")
        #expect(IMHygieneOverload.definition.inputSchema["properties"]?.objectValue?.map(\.key) == ["arguments"])

        #expect(try await client.independentMacroCall("im_hygiene_two_contexts", ["context": "mine"]).independentMacroFirstText == "mine tools/call")
        #expect(IMHygieneTwoContexts.definition.inputSchema["properties"]?.objectValue?.map(\.key) == ["context"])
    }

    /// Standard type names shadowed in the declaring file (see IndependentMacroShadowFixtures.swift).
    @Test func shadowedStandardTypesDoNotBreakTheExpansion() async throws {
        IndependentMacroCheckSchema(IndependentMacroShadowThing.jsonSchema)
        #expect(IndependentMacroShadowThing.jsonSchema["description"] == "Shadowed.")
        #expect(IndependentMacroShadowThing.jsonSchema["required"] == ["number"])
        #expect(IndependentMacroShadowThing.jsonSchema["properties"]?["number"] == ["type": "integer", "description": "A number."])
        IndependentMacroCheckRoundTrip(IndependentMacroShadowThing(number: 1, text: "t", list: ["l"], flags: ["f": true], ratio: 2))
        IndependentMacroCheckRoundTrip(IndependentMacroShadowThing(number: 0, text: nil))

        let server = try Server(name: "shadow", version: "1") {
            IndependentMacroShadowTool()
            IndependentMacroShadowVoidTool()
        }
        let client = TestClient(server)
        let listed = try #require(try await client.independentMacroListed("independent_macro_shadow_tool"))
        #expect(listed["description"] == "Shadowed tool.")
        #expect(listed["annotations"] == ["readOnlyHint": true])
        #expect(listed["inputSchema"]?["required"] == ["number"])
        #expect(listed["inputSchema"]?["properties"]?["number"]?["description"] == "A number.")
        let response = try await client.independentMacroCall("independent_macro_shadow_tool", ["number": 4, "flag": false])
        #expect(response["result"]?["structuredContent"] == ["number": 4, "list": [], "flags": ["flag": false], "ratio": 0.5])
        #expect(try await client.independentMacroCall("independent_macro_shadow_void_tool")["result"]?["content"] == [])
    }

    /// The schema, the decoder and the encoder come from one declaration and must agree
    /// (§8.1). The encoder resolves optionality from the real type, the schema and the decoder
    /// from the spelling: for `Swift.Optional<Int>` or a typealias of `Int?` the property is
    /// declared required, yet `nil` is encoded by omitting it.
    @Test func optionalsSpelledDifferentlyAreStillOptional() throws {
        let schema = IMAliasOptional.jsonSchema
        #expect(schema["required"] == ["plain"])
        IndependentMacroCheckRoundTrip(IMAliasOptional(plain: 1, aliased: 2, qualified: 3))
        IndependentMacroCheckRoundTrip(IMAliasOptional(plain: 1, aliased: nil, qualified: nil))
        #expect(try IMAliasOptional(json: ["plain": 1]) == IMAliasOptional(plain: 1, aliased: nil, qualified: nil))
    }

    @Test func optionalArgumentsSpelledDifferentlyAreStillOptional() async throws {
        #expect(IMAliasOptionalTool.definition.inputSchema["required"] == ["plain"])
        let server = try Server(name: "alias", version: "1") { IMAliasOptionalTool() }
        let client = TestClient(server)
        let response = try await client.independentMacroCall("im_alias_optional_tool", ["plain": 1])
        #expect(response["result"]?["isError"] == false, "\(response)")
        #expect(response.independentMacroFirstText == "1 - -")
        #expect(
            try await client.independentMacroCall("im_alias_optional_tool", ["plain": 1, "aliased": 2, "qualified": 3]).independentMacroFirstText
                == "1 2 3")
    }
}
