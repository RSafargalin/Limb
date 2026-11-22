import Limb
import LimbTesting
import Testing


// MARK: - Fixtures: namespaces

private enum IMSiblings {
    @Schema
    struct In: Equatable {
        var a: Int
    }

    @Schema
    enum Mode: String { case on, off }

    /// Doubles, or not.
    @Tool
    struct Doubler {
        func call(x: In, mode: Mode = .on, more: [In] = []) -> In { In(a: (mode == .on ? x.a * 2 : x.a) + more.count) }
    }

    @Schema
    struct Holder: Equatable {
        var i: In
        var list: [In] = []
        var mode: Mode?
    }
}

extension IMSiblings {
    /// Declared in an extension of the namespace.
    @Tool
    struct InExtension {
        func call(holder: Holder) -> Holder { Holder(i: holder.i, list: holder.list + [holder.i], mode: holder.mode) }
    }
}

// MARK: - Fixtures: generics

@Schema
private struct IMPage<Item: SchemaRepresentable & Equatable>: Equatable {
    var items: [Item]
    var total: Int
    var next: Item?
}

/// Repeats a value.
@Tool
private struct IMEcho<Value: SchemaRepresentable & Sendable> {
    func call(value: Value, times: Int = 1) -> [Value] { Array(repeating: value, count: times) }
}

private struct IMBox<Wrapped> {
    @Schema
    struct Inner: Equatable {
        var a: Int
    }

    /// A tool nested in a generic type.
    @Tool
    struct Peek {
        func call(inner: Inner) -> Int { inner.a }
    }
}

/// Remembers the previous value.
@Tool
private actor IMLast<Value: SchemaRepresentable & Sendable> {
    var last: Value?
    func call(value: Value) -> Value? {
        defer { last = value }
        return last
    }
}

/// Counts values.
@Tool
private final class IMCount<Value: SchemaRepresentable & Sendable>: Sendable {
    func call(values: [Value]) -> Int { values.count }
}

// MARK: - Fixtures: conformances the user already wrote

@Schema
private struct IMExplicitSchema: SchemaRepresentable, Equatable {
    var x: Int
}

@Schema
private enum IMExplicitEnum: String, SchemaRepresentable { case a, b }

/// States its conformance.
@Tool
private struct IMExplicitTool: MCPTool {
    func call(x: IMExplicitSchema, e: IMExplicitEnum = .a) -> IMExplicitSchema { IMExplicitSchema(x: e == .a ? x.x : -x.x) }
}

/// States only Sendable.
@Tool
private struct IMExplicitSendable: Sendable {
    func call() -> String { "sendable" }
}

// MARK: - Fixtures: spellings of the context, of Void, of names

/// The context, module-qualified.
@Tool
private struct IMCtxQualified {
    func call(x: Int, context: LimbServer.ToolContext) -> String { "\(x) \(context.method)" }
}

/// The context, optional.
@Tool
private struct IMCtxOptional {
    func call(x: Int, context: ToolContext?) -> String { "\(x) \(context?.method ?? "none")" }
}

/// The context under its other name, qualified, optional, first.
@Tool
private struct IMCtxRequestQualified {
    func call(context: Limb.RequestContext?, x: Int) -> String { "\(x) \(context?.method ?? "none")" }
}

/// Returns nothing, spelled out.
@Tool
private struct IMSwiftVoid {
    func call(x: Int) -> Swift.Void {}
}

/// Parameters whose names are keywords.
@Tool
private struct IMBackticked {
    func call(`in`: String, `default`: Int = 1, class kind: String?) -> String { "\(`in`) \(`default`) \(kind ?? "-")" }
}

/// Parameters that are named for the client but unused by the method.
@Tool
private struct IMDiscarded {
    func call(a _: Int, b _: Int = 2, _ c: Int) -> String { "c=\(c)" }
}

/// Defaults that refer to static members of the tool, with and without `Self.`.
@Tool
private struct IMStaticDefault {
    static let fallback = 5
    private static let hidden = 6
    func call(
        x: Int = Self.fallback, y: Int = IMStaticDefault.hidden, z: [Int] = [Self.fallback, 1].sorted(), bare: Int = fallback + hidden
    ) -> String { "\(x) \(y) \(z) \(bare)" }
}

/// Defaults that are more than a literal.
@Tool
private struct IMRichDefaults {
    func call(
        x: [Int] = [3, 1, 2].sorted { $0 < $1 }, y: Int = { 5 }(), z: String = "a\(1)b", w: Double = .pi, v: Int? = .some(1),
        u: [String: [Int]] = ["k": []], t: Bool = !true || false, s: Int = true ? 1 : 2
    ) -> String { "\(x) \(y) \(z) \(w == .pi) \(v ?? 0) \(u) \(t) \(s)" }
}

// MARK: - Fixtures: names that used to collide

@Schema
private struct IMObjectNamed: Equatable {
    var object: String
    var id: Int
}

/// Stored properties with observers and no default value.
@Schema
private struct IMObservedNoDefault: Equatable {
    var a: Int {
        didSet { changes += 1 }
    }
    fileprivate var b: String {
        willSet {}
    }
    var changes: Int = 0
}

@Schema
private struct IMNestedShadow: Equatable {
    struct JSONValue: Equatable {}
    struct JSONObject {}
    struct JSONDecodingError: Error {}
    enum SchemaSupport {}
    struct SchemaBuilder {}
    var a: Int
    var b: Swift.String?
}

/// Declares types named like Limb's own.
@Tool
private struct IMNestedShadowTool {
    struct ToolResult {}
    struct ToolDefinition {}
    struct ToolAnnotations {}
    enum ToolSupport {}
    enum SchemaSupport {}
    struct RequestContextual {}
    struct JSONObject {}
    struct MCPError: Error {}
    func call(a: Int) throws -> IMNestedShadow { IMNestedShadow(a: a, b: nil) }
}

@Schema
private struct IMLimbNames: Equatable {
    var __limbObject: Int
    var __limbFields: Int = 1
    var __limbBuilder: Int?
    var __limbValue: Int = 2
    var __limbJSON: Int
    var __limbOuter: Int
}

/// Uses the names of the generated locals for its own members and parameters.
@Tool
private struct IMLimbNamesTool {
    let __limbArguments: Int
    let __limbContext: Int
    let __limbArgument0: Int
    func call(__limbArguments: Int, __limbContext: Int, __limbArgument0: Int = 3, __limbArgument1: Int, __limbBuilder: Int, __limbFields: Int) -> String {
        "\(__limbArguments) \(__limbContext) \(__limbArgument0) \(__limbArgument1) \(__limbBuilder) \(__limbFields) \(self.__limbArguments + self.__limbContext + self.__limbArgument0)"
    }
}

/// Has members named like the generated ones.
@Tool
private struct IMGeneratedNames {
    let definition: String
    func definition(for x: Int) -> Int { x }
    func call(text: String) -> String { definition + text + "\(definition(for: 1))" }
}

private func makeServer() throws -> Server {
    try Server(name: "contexts", version: "1") {
        IMSiblings.Doubler()
        IMSiblings.InExtension()
        IMEcho<IMSiblings.In>()
        IMBox<Int>.Peek()
        IMLast<String>()
        IMCount<Double>()
        IMExplicitTool()
        IMExplicitSendable()
        IMCtxQualified()
        IMCtxOptional()
        IMCtxRequestQualified()
        IMSwiftVoid()
        IMBackticked()
        IMDiscarded()
        IMStaticDefault()
        IMRichDefaults()
        IMNestedShadowTool()
        IMLimbNamesTool(__limbArguments: 100, __limbContext: 20, __limbArgument0: 3)
        IMGeneratedNames(definition: "def:")
    }
}

// MARK: - Tests

@Suite struct IndependentMacroMemberContextTests {
    @Test func everyToolRegistersAndListsAValidDefinition() async throws {
        let client = TestClient(try makeServer())
        let tools = try await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
        #expect(
            tools.compactMap { $0["name"]?.stringValue } == [
                "doubler", "in_extension", "im_echo", "peek", "im_last", "im_count", "im_explicit_tool", "im_explicit_sendable",
                "im_ctx_qualified", "im_ctx_optional", "im_ctx_request_qualified", "im_swift_void", "im_backticked", "im_discarded",
                "im_static_default", "im_rich_defaults", "im_nested_shadow_tool", "im_limb_names_tool", "im_generated_names",
            ])
        for tool in tools {
            #expect(tool["description"]?.stringValue?.isEmpty == false, "\(tool)")
            if let schema = tool["inputSchema"]?.objectValue { IndependentMacroCheckSchema(schema) }
            if let schema = tool["outputSchema"]?.objectValue { IndependentMacroCheckSchema(schema) }
        }
    }

    @Test func siblingsInANamespaceResolve() async throws {
        let definition = IMSiblings.Doubler.definition
        #expect(definition.name == "doubler")
        #expect(definition.inputSchema["properties"]?["x"] == .object(IMSiblings.In.jsonSchema))
        #expect(definition.inputSchema["properties"]?["mode"] == ["type": "string", "enum": ["on", "off"]])
        #expect(definition.inputSchema["properties"]?["more"] == ["type": "array", "items": .object(IMSiblings.In.jsonSchema)])
        #expect(definition.inputSchema["required"] == ["x"])
        #expect(definition.outputSchema == IMSiblings.In.jsonSchema)
        IndependentMacroCheckRoundTrip(IMSiblings.Holder(i: .init(a: 1), list: [.init(a: 2)], mode: .off))
        IndependentMacroCheckRoundTrip(IMSiblings.Holder(i: .init(a: 1), mode: nil))

        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("doubler", ["x": ["a": 4]])["result"]?["structuredContent"] == ["a": 8])
        #expect(
            try await client.independentMacroCall("doubler", ["x": ["a": 4], "mode": "off", "more": [["a": 0]]])["result"]?["structuredContent"]
                == ["a": 5])
        let holder = try await client.independentMacroCall("in_extension", ["holder": ["i": ["a": 1], "mode": "on"]])
        #expect(holder["result"]?["structuredContent"] == ["i": ["a": 1], "list": [["a": 1]], "mode": "on"])
        #expect(try await client.independentMacroCall("doubler", ["x": ["a": "4"]])["result"]?["isError"] == true)
    }

    @Test func genericSchemaTypes() throws {
        #expect(IMPage<Int>.jsonSchema["properties"]?["items"] == ["type": "array", "items": ["type": "integer"]])
        #expect(IMPage<String>.jsonSchema["properties"]?["items"] == ["type": "array", "items": ["type": "string"]])
        #expect(IMPage<Int>.jsonSchema["properties"]?["next"] == ["anyOf": [["type": "integer"], ["type": "null"]]])
        #expect(IMPage<IMSiblings.In>.jsonSchema["properties"]?["items"]?["items"] == .object(IMSiblings.In.jsonSchema))
        #expect(IMPage<Int>.jsonSchema["required"] == ["items", "total"])
        IndependentMacroCheckRoundTrip(IMPage(items: [1, 2], total: 2, next: 3))
        IndependentMacroCheckRoundTrip(IMPage(items: ["a"], total: 1, next: nil))
        IndependentMacroCheckRoundTrip(IMPage(items: [IMPage(items: [1.5], total: 1, next: nil)], total: 1, next: nil))
        #expect(IndependentMacroDecodingError(IMPage<Int>.self, ["items": ["a"], "total": 1])?.path.first == "items")
        #expect(try JSONSchema(.object(IMPage<Int>.jsonSchema)).validate(["items": ["a"], "total": 1]) != nil)
        // Nested in a generic type.
        IndependentMacroCheckRoundTrip(IMBox<String>.Inner(a: 1))
        #expect(IMBox<String>.Inner.jsonSchema == IMBox<Int>.Inner.jsonSchema)
    }

    @Test func genericTools() async throws {
        #expect(IMEcho<Int>.definition.name == "im_echo")
        #expect(IMEcho<Int>.definition.inputSchema["properties"]?["value"] == ["type": "integer"])
        #expect(IMEcho<String>.definition.inputSchema["properties"]?["value"] == ["type": "string"])
        #expect(IMEcho<[Bool]?>.definition.inputSchema["properties"]?["value"] == ["anyOf": [["type": "array", "items": ["type": "boolean"]], ["type": "null"]]])
        #expect(IMEcho<[Bool]?>.definition.inputSchema["required"] == [])
        #expect(IMEcho<Int>.definition == IMEcho<Int>.definition)
        #expect(IMEcho<Int>.definition != IMEcho<String>.definition)

        let client = TestClient(try makeServer())
        let echo = try await client.independentMacroCall("im_echo", ["value": ["a": 7], "times": 2])
        #expect(echo["result"]?["structuredContent"] == [["a": 7], ["a": 7]])
        #expect(try await client.independentMacroCall("im_echo", ["value": 7])["result"]?["isError"] == true)
        #expect(try await client.independentMacroCall("peek", ["inner": ["a": 9]])["result"]?["structuredContent"] == 9)
        #expect(try await client.independentMacroCall("im_count", ["values": [1, 2.5, 3]])["result"]?["structuredContent"] == 3)
        // The actor keeps state between calls.
        #expect(try await client.independentMacroCall("im_last", ["value": "one"])["result"]?["structuredContent"] == .null)
        #expect(try await client.independentMacroCall("im_last", ["value": "two"])["result"]?["structuredContent"] == "one")
        #expect(try await client.independentMacroCall("im_last", ["value": 3])["result"]?["isError"] == true)
        #expect(try await client.independentMacroCall("im_last", ["value": "three"])["result"]?["structuredContent"] == "two")
    }

    /// Two specializations of one generic tool have the same name; the registry says so.
    @Test func twoSpecializationsOfAGenericToolCollideByName() {
        #expect(throws: RegistrationError.self) {
            _ = try Server(name: "generic", version: "1") {
                IMEcho<Int>()
                IMEcho<String>()
            }
        }
    }

    @Test func explicitConformancesAreNotRepeated() async throws {
        IndependentMacroCheckRoundTrip(IMExplicitSchema(x: 3))
        IndependentMacroCheckRoundTrip(IMExplicitEnum.b)
        #expect(IMExplicitEnum.jsonSchema["enum"] == ["a", "b"])
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_explicit_tool", ["x": ["x": 2], "e": "b"])["result"]?["structuredContent"] == ["x": -2])
        #expect(try await client.independentMacroCall("im_explicit_sendable").independentMacroFirstText == "sendable")
    }

    /// "A parameter of type `ToolContext` receives the request context and is not an argument"
    /// — however the type is spelled.
    @Test func everySpellingOfTheContextIsTheContext() async throws {
        for schema in [IMCtxQualified.definition.inputSchema, IMCtxOptional.definition.inputSchema, IMCtxRequestQualified.definition.inputSchema] {
            #expect(schema["properties"]?.objectValue?.map(\.key) == ["x"])
            #expect(schema["required"] == ["x"])
        }
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_ctx_qualified", ["x": 1]).independentMacroFirstText == "1 tools/call")
        // An optional context is still given the context.
        #expect(try await client.independentMacroCall("im_ctx_optional", ["x": 2]).independentMacroFirstText == "2 tools/call")
        #expect(try await client.independentMacroCall("im_ctx_request_qualified", ["x": 3]).independentMacroFirstText == "3 tools/call")
    }

    @Test func swiftVoidIsNothing() async throws {
        #expect(IMSwiftVoid.definition.outputSchema == nil)
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("im_swift_void", ["x": 1])
        #expect(response["result"]?["content"] == [])
        #expect(response["result"]?["structuredContent"] == nil)
        #expect(response["result"]?["isError"] == false)
    }

    /// Backticks are Swift's escaping, not part of the name the client sends.
    @Test func keywordParameterNames() async throws {
        let schema = IMBackticked.definition.inputSchema
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["in", "default", "class"])
        #expect(schema["required"] == ["in"])
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_backticked", ["in": "here"]).independentMacroFirstText == "here 1 -")
        #expect(try await client.independentMacroCall("im_backticked", ["in": "here", "default": 5, "class": "k"]).independentMacroFirstText == "here 5 k")
        #expect(try await client.independentMacroCall("im_backticked", ["`in`": "here"])["result"]?["isError"] == true)
    }

    @Test func discardedParametersAreStillArguments() async throws {
        let schema = IMDiscarded.definition.inputSchema
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["a", "b", "c"])
        #expect(schema["required"] == ["a", "c"])
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_discarded", ["a": 1, "c": 3]).independentMacroFirstText == "c=3")
        #expect(try await client.independentMacroCall("im_discarded", ["c": 3])["result"]?["isError"] == true)
        #expect(try await client.independentMacroCall("im_discarded", ["a": 1, "b": "x", "c": 3])["result"]?["isError"] == true)
    }

    @Test func defaultsMayReferToStaticMembers() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_static_default").independentMacroFirstText == "5 6 [1, 5] 11")
        #expect(
            try await client.independentMacroCall("im_static_default", ["x": 0, "y": 0, "z": [], "bare": 1]).independentMacroFirstText
                == "0 0 [] 1")
    }

    /// Whatever expression the default is, it is used when the argument is absent — or `null`,
    /// for an optional — and only then.
    @Test func defaultsThatAreArbitraryExpressions() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_rich_defaults").independentMacroFirstText == "[1, 2, 3] 5 a1b true 1 [\"k\": []] false 1")
        #expect(try await client.independentMacroCall("im_rich_defaults", ["v": nil]).independentMacroFirstText == "[1, 2, 3] 5 a1b true 1 [\"k\": []] false 1")
        let explicit = try await client.independentMacroCall(
            "im_rich_defaults", ["x": [], "y": 0, "z": "", "w": 0, "v": 9, "u": [:], "t": true, "s": 7])
        #expect(explicit.independentMacroFirstText == "[] 0  false 9 [:] true 7")
    }

    @Test func aPropertyNamedObject() throws {
        #expect(IMObjectNamed.jsonSchema["properties"]?.objectValue?.map(\.key) == ["object", "id"])
        let value = IMObjectNamed(object: "charge", id: 7)
        #expect(value.jsonValue == ["object": "charge", "id": 7])
        IndependentMacroCheckRoundTrip(value)
        #expect(IndependentMacroDecodingError(IMObjectNamed.self, ["object": 1, "id": 7])?.path == ["object"])
    }

    /// `willSet`/`didSet` do not make a property computed, with or without a default; and
    /// decoding initializes the value without running the observers, as any initializer does.
    @Test func observedPropertiesWithoutDefaults() throws {
        #expect(IMObservedNoDefault.jsonSchema["properties"]?.objectValue?.map(\.key) == ["a", "b", "changes"])
        #expect(IMObservedNoDefault.jsonSchema["required"] == ["a", "b"])
        let decoded = try IMObservedNoDefault(json: ["a": 1, "b": "x"])
        #expect(decoded.a == 1)
        #expect(decoded.b == "x")
        #expect(decoded.changes == 0)
        IndependentMacroCheckRoundTrip(IMObservedNoDefault(a: 2, b: "y", changes: 5))
        #expect(IndependentMacroDecodingError(IMObservedNoDefault.self, ["a": 1])?.path == ["b"])
    }

    @Test func nestedTypesNamedLikeLimbTypes() async throws {
        IndependentMacroCheckRoundTrip(IMNestedShadow(a: 1, b: "b"))
        IndependentMacroCheckRoundTrip(IMNestedShadow(a: 1, b: nil))
        #expect(IMNestedShadow.jsonSchema["properties"]?.objectValue?.map(\.key) == ["a", "b"])
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_nested_shadow_tool", ["a": 5])["result"]?["structuredContent"] == ["a": 5])
        #expect(try await client.independentMacroCall("im_nested_shadow_tool", ["a": "5"])["result"]?["isError"] == true)
    }

    @Test func membersAndParametersNamedLikeGeneratedLocals() async throws {
        let value = IMLimbNames(__limbObject: 1, __limbFields: 2, __limbBuilder: 3, __limbValue: 4, __limbJSON: 5, __limbOuter: 6)
        IndependentMacroCheckRoundTrip(value)
        #expect(
            value.jsonValue
                == ["__limbObject": 1, "__limbFields": 2, "__limbBuilder": 3, "__limbValue": 4, "__limbJSON": 5, "__limbOuter": 6])
        #expect(try IMLimbNames(json: ["__limbObject": 1, "__limbJSON": 5, "__limbOuter": 6]).__limbValue == 2)

        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall(
            "im_limb_names_tool",
            ["__limbArguments": 1, "__limbContext": 2, "__limbArgument1": 4, "__limbBuilder": 5, "__limbFields": 6])
        #expect(response.independentMacroFirstText == "1 2 3 4 5 6 123")
        #expect(try await client.independentMacroCall("im_generated_names", ["text": "x"]).independentMacroFirstText == "def:x1")
        #expect(IMGeneratedNames.definition.name == "im_generated_names")
    }
}
