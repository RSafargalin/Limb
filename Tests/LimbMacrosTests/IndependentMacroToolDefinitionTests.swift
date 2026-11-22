import Limb
import LimbTesting
import Testing


// MARK: - Fixtures: names

/// A fixture.
@Tool private struct HTTPFetch { func call() {} }
/// A fixture.
@Tool private struct WeatherForecastLookup { func call() {} }
/// A fixture.
@Tool private struct A { func call() {} }
/// A fixture.
@Tool private struct GetV2Data { func call() {} }
/// A fixture.
@Tool private struct Fetch2 { func call() {} }
/// A fixture.
@Tool private struct ParseJSON { func call() {} }
/// A fixture.
@Tool private struct URLOpener { func call() {} }
/// A fixture.
@Tool private struct lowercase { func call() {} }
/// A fixture.
@Tool private struct snake_case_already { func call() {} }
/// A fixture.
@Tool private struct Mixed_Case { func call() {} }
/// A fixture.
@Tool private struct MP3Player { func call() {} }
/// A fixture.
@Tool private struct ABC { func call() {} }
/// A fixture.
@Tool private struct SearchTool { func call() {} }
/// A fixture.
@Tool private struct _Hidden { func call() {} }

private enum IMToolNamespace {
    /// A fixture.
    @Tool struct NestedLookup { func call() {} }
}

/// A fixture.
@Tool("fs.read-file_v2") private struct IMExplicitName { func call() {} }
/// A fixture.
@Tool("GetWeather") private struct IMExplicitMixedCase { func call() {} }
/// A fixture.
@Tool("titled", title: "A \"quoted\" title \\(x)") private struct IMExplicitTitle { func call() {} }
/// A fixture.
@Tool(title: "Only a title") private struct IMOnlyTitle { func call() {} }
/// A fixture.
@Tool("n123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456x")
private struct IMLongestName { func call() {} }

// MARK: - Fixtures: annotations

/// A fixture.
@Tool private struct IMHintNone { func call() {} }
/// A fixture.
@Tool(readOnly: true) private struct IMHintReadOnly { func call() {} }
/// A fixture.
@Tool(readOnly: false) private struct IMHintNotReadOnly { func call() {} }
/// A fixture.
@Tool(destructive: true) private struct IMHintDestructive { func call() {} }
/// A fixture.
@Tool(destructive: false) private struct IMHintNotDestructive { func call() {} }
/// A fixture.
@Tool(idempotent: true) private struct IMHintIdempotent { func call() {} }
/// A fixture.
@Tool(idempotent: false) private struct IMHintNotIdempotent { func call() {} }
/// A fixture.
@Tool(openWorld: true) private struct IMHintOpenWorld { func call() {} }
/// A fixture.
@Tool(openWorld: false) private struct IMHintClosedWorld { func call() {} }
/// A fixture.
@Tool("all_hints", title: "All", readOnly: false, destructive: true, idempotent: false, openWorld: true)
private struct IMHintAll { func call() {} }
/// A fixture.
@Tool(readOnly: true, openWorld: false) private struct IMHintTwo { func call() {} }

// MARK: - Fixtures: signatures

@Schema
private struct IMDefLeaf: Equatable {
    /// The leaf's name.
    var name: String
    var weight: Double?
}

/// A size.
@Schema
private enum IMDefKind: String { case a, b, c }

/// A fixture.
@Tool private struct IMSigNoArguments { func call() -> String { "" } }

/// A fixture.
@Tool
private struct IMSigEveryType {
    func call(
        text: String, flag: Bool, count: Int, wide: Int64, ratio: Double, list: [String], matrix: [[Int]], map: [String: Int],
        leaf: IMDefLeaf, leaves: [IMDefLeaf], kind: IMDefKind, any: JSONValue
    ) -> String { text }
}

@Tool
private struct IMSigDefaults {
    func call(
        required: String, text: String = "dflt", flag: Bool = true, count: Int = 42, ratio: Double = 1.5, list: [Int] = [1, 2],
        map: [String: Int] = ["a": 1], kind: IMDefKind = .b, maybe: Int? = nil, maybeSeven: Int? = 7
    ) -> String { required }
}

/// A fixture.
@Tool
private struct IMSigOptionals {
    func call(text: String?, count: Int?, leaf: IMDefLeaf?, list: [String]?, spelled: Optional<Bool>) -> String { text ?? "" }
}

/// A fixture.
@Tool private struct IMSigContextFirst { func call(context: ToolContext, a: Int) -> Int { a } }
/// A fixture.
@Tool private struct IMSigContextMiddle { func call(a: Int, context: RequestContext, b: Int) -> Int { a + b } }
/// A fixture.
@Tool private struct IMSigContextUnlabeled { func call(_ ctx: ToolContext, _ a: Int) -> Int { a } }
/// A fixture.
@Tool private struct IMSigContextRenamed { func call(a: Int, with ctx: ToolContext) -> Int { a } }
/// A fixture.
@Tool private struct IMSigContextQualified { func call(a: Int, context: Limb.ToolContext) -> Int { a } }
/// A fixture.
@Tool private struct IMSigContextOnly { func call(context: ToolContext) {} }

/// A fixture.
@Tool private struct IMSigLabels { func call(for location: String, _ count: Int, from start: Int = 0) -> String { location } }

/// Stored properties are dependencies, not arguments.
@Tool
private struct IMSigDependencies {
    let prefix: String
    var limit: Int = 3
    static let shared = 1
    var computed: Int { limit }
    func call(text: String) -> String { prefix + text }
}

@Tool private struct IMOutString { func call() -> String { "" } }
/// A fixture.
@Tool private struct IMOutVoid { func call() {} }
/// A fixture.
@Tool private struct IMOutExplicitVoid { func call() -> Void {} }
/// A fixture.
@Tool private struct IMOutEmptyTuple { func call() -> () {} }
/// A fixture.
@Tool private struct IMOutStruct { func call() -> IMDefLeaf { IMDefLeaf(name: "", weight: nil) } }
/// A fixture.
@Tool private struct IMOutStructArray { func call() -> [IMDefLeaf] { [] } }
/// A fixture.
@Tool private struct IMOutDictionary { func call() -> [String: Int] { [:] } }
/// A fixture.
@Tool private struct IMOutInt { func call() -> Int { 0 } }
/// A fixture.
@Tool private struct IMOutEnum { func call() -> IMDefKind { .a } }
/// A fixture.
@Tool private struct IMOutToolResult { func call() -> ToolResult { ToolResult() } }
/// A fixture.
@Tool private struct IMOutBlock { func call() -> ContentBlock { .text("") } }
/// A fixture.
@Tool private struct IMOutBlocks { func call() -> [ContentBlock] { [] } }
/// A fixture.
@Tool private struct IMOutJSON { func call() -> JSONValue { nil } }
/// A fixture.
@Tool private struct IMOutAsyncThrows { func call() async throws -> IMDefLeaf { IMDefLeaf(name: "", weight: nil) } }

// MARK: - Names

@Suite struct IndependentMacroToolNameTests {
    @Test func namesAreTheTypeNameInSnakeCase() {
        #expect(HTTPFetch.definition.name == "http_fetch")
        #expect(WeatherForecastLookup.definition.name == "weather_forecast_lookup")
        #expect(A.definition.name == "a")
        #expect(ParseJSON.definition.name == "parse_json")
        #expect(URLOpener.definition.name == "url_opener")
        #expect(ABC.definition.name == "abc")
        #expect(lowercase.definition.name == "lowercase")
        #expect(snake_case_already.definition.name == "snake_case_already")
        #expect(Mixed_Case.definition.name == "mixed_case")
        #expect(_Hidden.definition.name == "_hidden")
        // Only the type's own name counts, not its enclosing types.
        #expect(IMToolNamespace.NestedLookup.definition.name == "nested_lookup")
    }

    // observed, unspecified: where a digit ends a word. "v2" stays together and a capital
    // after a digit starts a new word.
    @Test func digitsInNames() {
        #expect(GetV2Data.definition.name == "get_v2_data")
        #expect(Fetch2.definition.name == "fetch2")
        #expect(MP3Player.definition.name == "mp3_player")
    }

    // observed, unspecified: a `Tool` suffix on the type name is kept.
    @Test func toolSuffixIsKept() {
        #expect(SearchTool.definition.name == "search_tool")
    }

    @Test func derivedNamesSatisfyTheSpecification() {
        let names = [
            HTTPFetch.definition.name, WeatherForecastLookup.definition.name, A.definition.name, GetV2Data.definition.name,
            Fetch2.definition.name, ParseJSON.definition.name, URLOpener.definition.name, lowercase.definition.name,
            snake_case_already.definition.name, Mixed_Case.definition.name, MP3Player.definition.name, ABC.definition.name,
            SearchTool.definition.name, _Hidden.definition.name,
        ]
        for name in names {
            #expect((1...128).contains(name.utf8.count), "\(name)")
            #expect(name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }, "\(name)")
        }
        #expect(Set(names).count == names.count)
    }

    @Test func explicitNamesAreUsedVerbatim() {
        #expect(IMExplicitName.definition.name == "fs.read-file_v2")
        #expect(IMExplicitMixedCase.definition.name == "GetWeather")
        #expect(IMExplicitTitle.definition.name == "titled")
        #expect(IMExplicitTitle.definition.title == "A \"quoted\" title \\(x)")
        #expect(IMOnlyTitle.definition.name == "im_only_title")
        #expect(IMOnlyTitle.definition.title == "Only a title")
        #expect(IMLongestName.definition.name.utf8.count == 128)
        #expect(HTTPFetch.definition.title == nil)
    }

    @Test func everyNamedToolRegistersAndIsListedInOrder() async throws {
        let server = try Server(name: "names", version: "1") {
            HTTPFetch()
            A()
            IMExplicitName()
            IMExplicitMixedCase()
            IMLongestName()
            IMToolNamespace.NestedLookup()
            _Hidden()
        }
        let client = TestClient(server)
        let tools = try await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
        #expect(
            tools.compactMap { $0["name"]?.stringValue }
                == ["http_fetch", "a", "fs.read-file_v2", "GetWeather", IMLongestName.definition.name, "nested_lookup", "_hidden"])
    }
}

// MARK: - Annotations

@Suite struct IndependentMacroToolAnnotationTests {
    @Test func eachFlagMapsToItsHint() {
        #expect(IMHintNone.definition.annotations == nil)
        #expect(IMHintReadOnly.definition.annotations == ToolAnnotations(readOnlyHint: true))
        #expect(IMHintNotReadOnly.definition.annotations == ToolAnnotations(readOnlyHint: false))
        #expect(IMHintDestructive.definition.annotations == ToolAnnotations(destructiveHint: true))
        #expect(IMHintNotDestructive.definition.annotations == ToolAnnotations(destructiveHint: false))
        #expect(IMHintIdempotent.definition.annotations == ToolAnnotations(idempotentHint: true))
        #expect(IMHintNotIdempotent.definition.annotations == ToolAnnotations(idempotentHint: false))
        #expect(IMHintOpenWorld.definition.annotations == ToolAnnotations(openWorldHint: true))
        #expect(IMHintClosedWorld.definition.annotations == ToolAnnotations(openWorldHint: false))
        #expect(IMHintTwo.definition.annotations == ToolAnnotations(readOnlyHint: true, openWorldHint: false))
        #expect(
            IMHintAll.definition.annotations
                == ToolAnnotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true))
        // The title is the tool's title (schema.ts: precedence is `title`, then `annotations.title`).
        #expect(IMHintAll.definition.title == "All")
    }

    /// schema.ts `ToolAnnotations`: each hint is an optional boolean with its own default
    /// (`destructiveHint` and `openWorldHint` default to true), so an explicit `false` must be
    /// sent and an unset hint must be absent.
    @Test func hintsOnTheWire() async throws {
        let server = try Server(name: "hints", version: "1") {
            IMHintNone()
            IMHintReadOnly()
            IMHintNotReadOnly()
            IMHintDestructive()
            IMHintNotDestructive()
            IMHintIdempotent()
            IMHintNotIdempotent()
            IMHintOpenWorld()
            IMHintClosedWorld()
            IMHintAll()
            IMHintTwo()
        }
        let client = TestClient(server)
        func annotations(_ name: String) async throws -> JSONValue? { try await client.independentMacroListed(name)?["annotations"] }

        let none = try #require(try await client.independentMacroListed("im_hint_none"))
        #expect(none["annotations"] == nil)
        #expect(none["title"] == nil)
        #expect(try await annotations("im_hint_read_only") == ["readOnlyHint": true])
        #expect(try await annotations("im_hint_not_read_only") == ["readOnlyHint": false])
        #expect(try await annotations("im_hint_destructive") == ["destructiveHint": true])
        #expect(try await annotations("im_hint_not_destructive") == ["destructiveHint": false])
        #expect(try await annotations("im_hint_idempotent") == ["idempotentHint": true])
        #expect(try await annotations("im_hint_not_idempotent") == ["idempotentHint": false])
        #expect(try await annotations("im_hint_open_world") == ["openWorldHint": true])
        #expect(try await annotations("im_hint_closed_world") == ["openWorldHint": false])
        #expect(try await annotations("im_hint_two") == ["readOnlyHint": true, "openWorldHint": false])
        let all = try #require(try await client.independentMacroListed("all_hints"))
        #expect(all["annotations"] == ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true])
        #expect(all["title"] == "All")
    }

    @Test func hintsReachLegacyClientsToo() async throws {
        let server = try Server(name: "hints", version: "1") {
            IMHintAll()
            IMHintNone()
        }
        for version in [ProtocolVersion.v2025_11_25, .v2025_06_18, .v2025_03_26] {
            let client = TestClient(server, modern: false)
            try await client.initialize(version: version)
            let all = try #require(try await client.independentMacroListed("all_hints"), "\(version)")
            #expect(all["annotations"]?["readOnlyHint"] == false, "\(version)")
            #expect(all["annotations"]?["destructiveHint"] == true, "\(version)")
            #expect(all["annotations"]?["idempotentHint"] == false, "\(version)")
            #expect(all["annotations"]?["openWorldHint"] == true, "\(version)")
            // The display name is visible one way or the other.
            #expect(all["title"] == "All" || all["annotations"]?["title"] == "All", "\(version)")
            #expect(try await client.independentMacroListed("im_hint_none")?["annotations"] == nil, "\(version)")
        }
    }
}

// MARK: - Input and output schemas

@Suite struct IndependentMacroToolSchemaTests {
    /// The spec requires `inputSchema` to be a schema object with `"type": "object"`, also for
    /// a tool without parameters (tools.mdx recommends `additionalProperties: false`, and
    /// allows a bare `{"type": "object"}`).
    @Test func noArguments() {
        let schema = IMSigNoArguments.definition.inputSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["type"] == "object")
        #expect(schema["properties"] == nil || schema["properties"] == [:])
        #expect(schema["required"] == nil || schema["required"] == [])
        #expect((try? JSONSchema(.object(schema)))?.validate([:]) == nil)
    }

    @Test func everyArgumentTypeHasItsSchema() {
        let schema = IMSigEveryType.definition.inputSchema
        IndependentMacroCheckSchema(schema)
        let properties = schema["properties"]
        #expect(
            properties?.objectValue?.map(\.key)
                == ["text", "flag", "count", "wide", "ratio", "list", "matrix", "map", "leaf", "leaves", "kind", "any"])
        #expect(schema["required"] == ["text", "flag", "count", "wide", "ratio", "list", "matrix", "map", "leaf", "leaves", "kind", "any"])
        #expect(properties?["text"] == ["type": "string"])
        #expect(properties?["flag"] == ["type": "boolean"])
        #expect(properties?["count"] == ["type": "integer"])
        #expect(properties?["wide"] == ["type": "integer"])
        #expect(properties?["ratio"] == ["type": "number"])
        #expect(properties?["list"] == ["type": "array", "items": ["type": "string"]])
        #expect(properties?["matrix"] == ["type": "array", "items": ["type": "array", "items": ["type": "integer"]]])
        #expect(properties?["map"] == ["type": "object", "additionalProperties": ["type": "integer"]])
        #expect(properties?["leaf"] == .object(IMDefLeaf.jsonSchema))
        #expect(properties?["leaf"]?["properties"]?["name"]?["description"] == "The leaf's name.")
        #expect(properties?["leaves"] == ["type": "array", "items": .object(IMDefLeaf.jsonSchema)])
        #expect(properties?["kind"] == ["type": "string", "enum": ["a", "b", "c"], "description": "A size."])
        #expect(properties?["any"] == [:])
    }

    /// "the default must be used when the argument is absent and the schema must not require it".
    @Test func defaultedAndOptionalArgumentsAreNotRequired() {
        let defaults = IMSigDefaults.definition.inputSchema
        IndependentMacroCheckSchema(defaults)
        #expect(defaults["required"] == ["required"])
        #expect(
            defaults["properties"]?.objectValue?.map(\.key)
                == ["required", "text", "flag", "count", "ratio", "list", "map", "kind", "maybe", "maybeSeven"])
        #expect(defaults["properties"]?["count"] == ["type": "integer"])
        // An optional argument is "the type or null", with or without a default.
        #expect(defaults["properties"]?["maybe"] == ["anyOf": [["type": "integer"], ["type": "null"]]])
        #expect(defaults["properties"]?["maybeSeven"] == ["anyOf": [["type": "integer"], ["type": "null"]]])

        let optionals = IMSigOptionals.definition.inputSchema
        IndependentMacroCheckSchema(optionals)
        #expect(optionals["required"] == [])
        #expect(optionals["properties"]?.objectValue?.map(\.key) == ["text", "count", "leaf", "list", "spelled"])
        #expect(optionals["properties"]?["text"] == ["anyOf": [["type": "string"], ["type": "null"]]])
        #expect(optionals["properties"]?["spelled"] == ["anyOf": [["type": "boolean"], ["type": "null"]]])
        #expect(optionals["properties"]?["leaf"] == ["anyOf": [.object(IMDefLeaf.jsonSchema), ["type": "null"]]])
        #expect(optionals["properties"]?["list"] == ["anyOf": [["type": "array", "items": ["type": "string"]], ["type": "null"]]])
    }

    /// "A parameter of type `ToolContext` receives the request context and is not an argument."
    @Test func theContextParameterIsNotAnArgument() {
        for schema in [
            IMSigContextFirst.definition.inputSchema, IMSigContextUnlabeled.definition.inputSchema,
            IMSigContextRenamed.definition.inputSchema, IMSigContextQualified.definition.inputSchema,
        ] {
            #expect(schema["properties"]?.objectValue?.map(\.key) == ["a"])
            #expect(schema["required"] == ["a"])
        }
        #expect(IMSigContextMiddle.definition.inputSchema["properties"]?.objectValue?.map(\.key) == ["a", "b"])
        #expect(IMSigContextOnly.definition.inputSchema["properties"] == [:])
    }

    @Test func labelsNameTheArguments() {
        let schema = IMSigLabels.definition.inputSchema
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["for", "count", "from"])
        #expect(schema["required"] == ["for", "count"])
    }

    @Test func storedPropertiesAreNotArguments() {
        let schema = IMSigDependencies.definition.inputSchema
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["text"])
        #expect(schema["required"] == ["text"])
        #expect(IMSigDependencies.definition.description == "Stored properties are dependencies, not arguments.")
    }

    @Test func outputSchemaFollowsTheReturnType() {
        #expect(IMOutString.definition.outputSchema == nil)
        #expect(IMOutVoid.definition.outputSchema == nil)
        #expect(IMOutExplicitVoid.definition.outputSchema == nil)
        #expect(IMOutEmptyTuple.definition.outputSchema == nil)
        #expect(IMOutToolResult.definition.outputSchema == nil)
        #expect(IMOutBlock.definition.outputSchema == nil)
        #expect(IMOutBlocks.definition.outputSchema == nil)
        #expect(IMOutStruct.definition.outputSchema == IMDefLeaf.jsonSchema)
        #expect(IMOutAsyncThrows.definition.outputSchema == IMDefLeaf.jsonSchema)
        #expect(IMOutDictionary.definition.outputSchema == ["type": "object", "additionalProperties": ["type": "integer"]])
        if let schema = IMOutStruct.definition.outputSchema { IndependentMacroCheckSchema(schema) }
    }

    // observed, documented on `ToolSupport.outputSchema`: results that are not JSON objects get
    // no declared schema, because revisions before 2026-07-28 only allow object schemas.
    // (schema.ts for 2026-07-28 allows any schema, and has an array example.)
    @Test func nonObjectResultsDeclareNoOutputSchema() {
        #expect(IMOutStructArray.definition.outputSchema == nil)
        #expect(IMOutInt.definition.outputSchema == nil)
        #expect(IMOutEnum.definition.outputSchema == nil)
        #expect(IMOutJSON.definition.outputSchema == nil)
    }

    /// The whole definition as a client sees it, for one representative tool.
    @Test func definitionOnTheWire() async throws {
        let server = try Server(name: "wire", version: "1") {
            IMSigDefaults()
            IMOutStruct()
            IMOutString()
            IMSigNoArguments()
        }
        let client = TestClient(server)
        let defaults = try #require(try await client.independentMacroListed("im_sig_defaults"))
        #expect(defaults["inputSchema"] == .object(IMSigDefaults.definition.inputSchema))
        #expect(defaults["inputSchema"]?["type"] == "object")
        #expect(defaults["outputSchema"] == nil)
        #expect(defaults["description"] == nil)

        let structured = try #require(try await client.independentMacroListed("im_out_struct"))
        #expect(structured["outputSchema"] == .object(IMDefLeaf.jsonSchema))
        #expect(structured["outputSchema"]?["type"] == "object")
        #expect(structured["inputSchema"]?["type"] == "object")

        let plain = try #require(try await client.independentMacroListed("im_out_string"))
        #expect(plain["outputSchema"] == nil)
        #expect(plain.objectValue?.map(\.key).sorted() == ["inputSchema", "name"])
    }
}
