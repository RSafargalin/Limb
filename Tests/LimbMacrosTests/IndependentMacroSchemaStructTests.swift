import Limb
import Testing


/// The schema of an optional of something whose schema is `wrapped`.
private func nullable(_ wrapped: JSONValue) -> JSONValue { ["anyOf": [wrapped, ["type": "null"]]] }

// MARK: - Fixtures

@Schema
private struct IMScalars: Equatable {
    var text: String
    var flag: Bool
    var count: Int
    var wide: Int64
    var ratio: Double
}

@Schema
private struct IMOptionals: Equatable {
    var text: String?
    var flag: Bool?
    var count: Int?
    var wide: Int64?
    var ratio: Double?
    var spelledOut: Optional<Int>
    var list: [String]?
    var map: [String: Int]?
}

@Schema
private struct IMCollections: Equatable {
    var strings: [String]
    var matrix: [[Int]]
    var map: [String: Int]
    var mapOfLists: [String: [Double]]
    var listOfMaps: [[String: Bool]]
    var spelledArray: Array<String>
    var spelledDictionary: Dictionary<String, Bool>
}

/// Collections whose elements are optional: `nil` elements are encoded, so the schema has to
/// allow them.
@Schema
private struct IMOptionalElements: Equatable {
    var list: [Int?]
    var map: [String: String?]
    var maybeList: [Int?]?
}

@Schema
private struct IMLeaf: Equatable {
    var name: String
    var weight: Double?
}

@Schema
private enum IMKind: String, Equatable, CaseIterable {
    case small, medium, large
}

@Schema
private struct IMNested: Equatable {
    var leaf: IMLeaf
    var maybeLeaf: IMLeaf?
    var leaves: [IMLeaf]
    var leafByName: [String: IMLeaf]
    var kind: IMKind
    var kinds: [IMKind]
    var maybeKind: IMKind?
}

@Schema
private struct IMDefaults: Equatable {
    var required: String
    var count: Int = 3
    var tags: [String] = ["a", "b"]
    var kind: IMKind = .medium
    var ratio: Double = 0.5
    var label: String = "none"
    var flag: Bool = true
}

/// An optional property that also has a default value.
@Schema
private struct IMOptionalWithDefault: Equatable {
    var limit: Int? = 10
    var name: String? = "anonymous"
}

@Schema
private struct IMLetAndVar: Equatable {
    let id: Int
    let note: String?
    var mutable: Int
    /// A constant with a value: not part of the data.
    let version: Int = 2
    let inferred = "x"
    static let shared = 1
    static var counter: Int { 0 }
    var computed: Int { id * 2 }
    var computedWithSetter: Int {
        get { mutable }
        set { mutable = newValue }
    }
}

@Schema
private struct IMEmpty: Equatable {}

@Schema
private struct IMFreeForm: Equatable {
    var anything: JSONValue
    var maybeAnything: JSONValue?
    var bag: [String: JSONValue]
}

@Schema
private struct IMAccess: Equatable {
    var visible: Int
    private var hidden: Int
    private(set) var readOnly: String
    init(visible: Int, hidden: Int, readOnly: String) {
        self.visible = visible
        self.hidden = hidden
        self.readOnly = readOnly
    }
}

@Schema
private struct IMUnicodeNames: Equatable {
    var café: Int
    var 名前: String
    var snake_case: Bool
    var _leading: Int
    var x1: Int
}

@Schema
private struct IMKeywordNames: Equatable {
    var `default`: Int
    var `class`: String
    var `in`: Bool
}

/// A property that is literally called `self`.
@Schema
private struct IMSelfNamed: Equatable {
    var `self`: Int
    var other: String
}

/// A stored property with an observer is still a stored property.
@Schema
private struct IMObserved: Equatable {
    var plain: Int
    var watched: Int = 0 {
        didSet { plain += 1 }
    }
}

@propertyWrapper
private struct IMClamped: Equatable {
    var wrappedValue: Int
    init(wrappedValue: Int) { self.wrappedValue = min(max(wrappedValue, 0), 10) }
}

@Schema
private struct IMWrapped: Equatable {
    @IMClamped var level: Int
    @IMClamped var defaulted: Int = 3
}

@Schema
private struct IMTwoOnOneLine: Equatable {
    var a: Int, b: String
}

private enum IMNamespace {
    @Schema
    struct Inner: Equatable {
        var value: Int
    }
}

extension IMNamespace {
    @Schema
    struct DeclaredInExtension: Equatable {
        var flag: Bool
        var inner: IMNamespace.Inner
    }

    struct Deep {
        @Schema
        enum Level: String, Equatable { case low, high }

        @Schema
        struct Leaf: Equatable {
            var level: IMNamespace.Deep.Level
        }
    }
}

/// A tree: the type refers to itself through an array (Э1 lists "рекурсивный тип").
@Schema
private struct IMTree: Equatable {
    var value: Int
    var children: [IMTree]
}

@Schema
private struct IMGraphNode: Equatable {
    var name: String
    var edges: [String: IMGraphNode]?
}

// MARK: - Schema shape

@Suite struct IndependentMacroSchemaStructShapeTests {
    @Test func scalarPropertiesMapToJSONSchemaTypes() {
        let schema = IMScalars.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["type"] == "object")
        #expect(schema["properties"]?["text"] == ["type": "string"])
        #expect(schema["properties"]?["flag"] == ["type": "boolean"])
        #expect(schema["properties"]?["count"] == ["type": "integer"])
        #expect(schema["properties"]?["wide"] == ["type": "integer"])
        #expect(schema["properties"]?["ratio"] == ["type": "number"])
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["text", "flag", "count", "wide", "ratio"])
        #expect(schema["required"] == ["text", "flag", "count", "wide", "ratio"])
        // No doc comment on the type: no description, rather than an empty one.
        #expect(schema["description"] == nil)
    }

    @Test func optionalPropertiesAreDeclaredButNotRequired() {
        let schema = IMOptionals.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["text", "flag", "count", "wide", "ratio", "spelledOut", "list", "map"])
        #expect(schema["required"] == [])
        #expect(schema["properties"]?["text"] == nullable(["type": "string"]))
        #expect(schema["properties"]?["flag"] == nullable(["type": "boolean"]))
        #expect(schema["properties"]?["count"] == nullable(["type": "integer"]))
        #expect(schema["properties"]?["wide"] == nullable(["type": "integer"]))
        #expect(schema["properties"]?["ratio"] == nullable(["type": "number"]))
        #expect(schema["properties"]?["spelledOut"] == nullable(["type": "integer"]))
        #expect(schema["properties"]?["list"] == nullable(["type": "array", "items": ["type": "string"]]))
        #expect(schema["properties"]?["map"] == nullable(["type": "object", "additionalProperties": ["type": "integer"]]))
    }

    /// The schema and the decoder agree about `null` for an optional: both accept it.
    @Test func explicitNullIsAValidInstanceForAnOptionalProperty() throws {
        let schema = try JSONSchema(.object(IMOptionals.jsonSchema))
        let nulls: JSONValue = [
            "text": nil, "flag": nil, "count": nil, "wide": nil, "ratio": nil, "spelledOut": nil, "list": nil, "map": nil,
        ]
        #expect(schema.validate(nulls) == nil)
        #expect(schema.validate([:]) == nil)
        #expect(schema.validate(["count": 1, "list": ["a"]]) == nil)
        #expect(schema.validate(["count": "1"]) != nil)
        #expect(schema.validate(["list": [1]]) != nil)
        #expect(schema.validate(["list": [nil]]) != nil)
        #expect(try IMOptionals(json: nulls) == IMOptionals(json: [:]))
    }

    @Test func collectionsNest() {
        let schema = IMCollections.jsonSchema
        IndependentMacroCheckSchema(schema)
        let properties = schema["properties"]
        #expect(properties?["strings"] == ["type": "array", "items": ["type": "string"]])
        #expect(properties?["matrix"] == ["type": "array", "items": ["type": "array", "items": ["type": "integer"]]])
        #expect(properties?["map"] == ["type": "object", "additionalProperties": ["type": "integer"]])
        #expect(
            properties?["mapOfLists"]
                == ["type": "object", "additionalProperties": ["type": "array", "items": ["type": "number"]]])
        #expect(
            properties?["listOfMaps"]
                == ["type": "array", "items": ["type": "object", "additionalProperties": ["type": "boolean"]]])
        #expect(properties?["spelledArray"] == properties?["strings"])
        #expect(properties?["spelledDictionary"] == ["type": "object", "additionalProperties": ["type": "boolean"]])
        #expect(schema["required"]?.arrayValue?.count == 7)
    }

    @Test func nestedSchemaTypesAreInlined() {
        let schema = IMNested.jsonSchema
        IndependentMacroCheckSchema(schema)
        let properties = schema["properties"]
        #expect(properties?["leaf"] == .object(IMLeaf.jsonSchema))
        #expect(properties?["maybeLeaf"] == nullable(.object(IMLeaf.jsonSchema)))
        #expect(properties?["maybeKind"] == nullable(["type": "string", "enum": ["small", "medium", "large"]]))
        // An optional inside the nested type is nullable there too.
        #expect(properties?["leaf"]?["properties"]?["weight"] == nullable(["type": "number"]))
        #expect(properties?["leaves"] == ["type": "array", "items": .object(IMLeaf.jsonSchema)])
        #expect(properties?["leafByName"] == ["type": "object", "additionalProperties": .object(IMLeaf.jsonSchema)])
        #expect(properties?["kind"] == ["type": "string", "enum": ["small", "medium", "large"]])
        #expect(properties?["kinds"]?["items"]?["enum"] == ["small", "medium", "large"])
        #expect(schema["required"] == ["leaf", "leaves", "leafByName", "kind", "kinds"])
    }

    @Test func propertiesWithDefaultsAreNotRequired() {
        let schema = IMDefaults.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["required"] == ["required"])
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["required", "count", "tags", "kind", "ratio", "label", "flag"])
    }

    @Test func onlyStoredInstanceDataAppears() {
        let schema = IMLetAndVar.jsonSchema
        IndependentMacroCheckSchema(schema)
        // `let` without a value is data; `let` with a value, statics and computed properties are not.
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["id", "note", "mutable"])
        #expect(schema["required"] == ["id", "mutable"])
        let value = IMLetAndVar(id: 4, note: nil, mutable: 5)
        #expect(value.jsonValue == ["id": 4, "mutable": 5])
        IndependentMacroCheckRoundTrip(value)
        IndependentMacroCheckRoundTrip(IMLetAndVar(id: -1, note: "n", mutable: 0))
    }

    @Test func emptyStructIsAnObjectWithNoProperties() throws {
        let schema = IMEmpty.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["type"] == "object")
        #expect(schema["properties"] == [:])
        #expect(IMEmpty().jsonValue == [:])
        #expect(try IMEmpty(json: [:]) == IMEmpty())
        let error = IndependentMacroDecodingError(IMEmpty.self, [1, 2])
        #expect(error?.path == [])
        #expect(error?.reason.contains("object") == true)
    }

    @Test func freeFormValuesHaveAnUnconstrainedSchema() throws {
        let schema = IMFreeForm.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?["anything"] == [:])
        #expect(schema["properties"]?["bag"] == ["type": "object", "additionalProperties": [:]])
        #expect(schema["required"] == ["anything", "bag"])
        IndependentMacroCheckRoundTrip(IMFreeForm(anything: ["a": [1, 2.5, nil, "x"]], maybeAnything: [true], bag: ["k": nil, "z": 1]))
        // `null` is a legitimate value of a required free-form property.
        let decoded = try IMFreeForm(json: ["anything": nil, "bag": [:]])
        #expect(decoded.anything == .null)
        #expect(decoded.maybeAnything == nil)
    }

    @Test func privatePropertiesAreSerialized() {
        let schema = IMAccess.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["visible", "hidden", "readOnly"])
        IndependentMacroCheckRoundTrip(IMAccess(visible: 1, hidden: 2, readOnly: "r"))
    }

    @Test func nonASCIIAndUnderscoredNamesAreKeptVerbatim() {
        let schema = IMUnicodeNames.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["café", "名前", "snake_case", "_leading", "x1"])
        let value = IMUnicodeNames(café: 1, 名前: "n", snake_case: true, _leading: 2, x1: 3)
        #expect(value.jsonValue == ["café": 1, "名前": "n", "snake_case": true, "_leading": 2, "x1": 3])
        IndependentMacroCheckRoundTrip(value)
    }

    /// Backticks are Swift's escaping, not part of the name: `` var `default`: Int `` is the
    /// property `default`, and that is what a client must send.
    @Test func keywordPropertyNamesLoseTheirBackticks() throws {
        let schema = IMKeywordNames.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["default", "class", "in"])
        #expect(schema["required"] == ["default", "class", "in"])
        let value = IMKeywordNames(default: 1, class: "c", in: true)
        #expect(value.jsonValue == ["default": 1, "class": "c", "in": true])
        #expect(try IMKeywordNames(json: ["default": 1, "class": "c", "in": true]) == value)
    }

    /// `willSet`/`didSet` do not make a property computed.
    @Test func observedStoredPropertiesAreData() throws {
        let schema = IMObserved.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["plain", "watched"])
        var value = IMObserved(plain: 1)
        value.watched = 7
        #expect(value.jsonValue["watched"] == 7)
        #expect(try IMObserved(json: ["plain": 1, "watched": 7]).watched == 7)
    }

    // observed, unspecified: a wrapped property is described by its declared type and decoded
    // through the wrapper's `init(wrappedValue:)` / setter.
    @Test func wrappedPropertiesUseTheWrappedType() throws {
        let schema = IMWrapped.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["level", "defaulted"])
        #expect(schema["properties"]?["level"] == ["type": "integer"])
        #expect(schema["required"] == ["level"])
        let decoded = try IMWrapped(json: ["level": 99])
        #expect(decoded.level == 10)
        #expect(decoded.defaulted == 3)
        #expect(decoded.jsonValue == ["level": 10, "defaulted": 3])
    }

    @Test func severalBindingsInOneDeclaration() {
        #expect(IMTwoOnOneLine.jsonSchema["properties"]?.objectValue?.map(\.key) == ["a", "b"])
        #expect(IMTwoOnOneLine.jsonSchema["properties"]?["b"] == ["type": "string"])
        IndependentMacroCheckRoundTrip(IMTwoOnOneLine(a: 1, b: "x"))
    }

    @Test func nestedTypesAndTypesDeclaredInExtensions() {
        IndependentMacroCheckRoundTrip(IMNamespace.Inner(value: 3))
        IndependentMacroCheckRoundTrip(IMNamespace.DeclaredInExtension(flag: true, inner: .init(value: 1)))
        IndependentMacroCheckRoundTrip(IMNamespace.Deep.Leaf(level: .high))
        #expect(IMNamespace.DeclaredInExtension.jsonSchema["properties"]?["inner"] == .object(IMNamespace.Inner.jsonSchema))
        #expect(IMNamespace.Deep.Leaf.jsonSchema["properties"]?["level"]?["enum"] == ["low", "high"])
    }

    @Test func theSchemaIsStableAcrossAccesses() {
        #expect(IMNested.jsonSchema == IMNested.jsonSchema)
        #expect(IMNested.jsonSchema.map(\.key) == IMNested.jsonSchema.map(\.key))
    }
}

// MARK: - Values

@Suite struct IndependentMacroSchemaStructValueTests {
    @Test func scalarsRoundTrip() {
        IndependentMacroCheckRoundTrip(IMScalars(text: "", flag: false, count: 0, wide: 0, ratio: 0))
        IndependentMacroCheckRoundTrip(IMScalars(text: "x", flag: true, count: .max, wide: .max, ratio: .greatestFiniteMagnitude))
        IndependentMacroCheckRoundTrip(IMScalars(text: "\u{0}\"\\\n😀", flag: true, count: .min, wide: .min, ratio: -.leastNonzeroMagnitude))
        IndependentMacroCheckRoundTrip(IMScalars(text: "1", flag: false, count: 1, wide: 1, ratio: 1e-7))
        IndependentMacroCheckRoundTrip(IMScalars(text: "1", flag: false, count: 1, wide: 1, ratio: 0.1 + 0.2))
    }

    @Test func generatedScalarsRoundTrip() {
        var random = IndependentMacroRandom(seed: 0x5EED)
        for _ in 0..<300 {
            IndependentMacroCheckRoundTrip(
                IMScalars(
                    text: random.string(), flag: Bool.random(using: &random), count: random.int(), wide: Int64(random.int()),
                    ratio: random.double()))
        }
    }

    @Test func generatedOptionalsRoundTrip() {
        var random = IndependentMacroRandom(seed: 0xA11)
        func maybe<T>(_ make: (inout IndependentMacroRandom) -> T) -> T? {
            Bool.random(using: &random) ? make(&random) : nil
        }
        for _ in 0..<300 {
            IndependentMacroCheckRoundTrip(
                IMOptionals(
                    text: maybe { $0.string() }, flag: maybe { Bool.random(using: &$0) }, count: maybe { $0.int() },
                    wide: maybe { Int64($0.int()) }, ratio: maybe { $0.double() }, spelledOut: maybe { $0.int() },
                    list: maybe { r in (0..<Int.random(in: 0...3, using: &r)).map { _ in r.string() } },
                    map: maybe { r in
                        Dictionary((0..<Int.random(in: 0...3, using: &r)).map { _ in (r.string(), r.int()) }, uniquingKeysWith: { a, _ in a })
                    }))
        }
        // All absent: an empty object, not a row of nulls.
        let empty = IMOptionals(text: nil, flag: nil, count: nil, wide: nil, ratio: nil, spelledOut: nil, list: nil, map: nil)
        #expect(empty.jsonValue == [:])
    }

    @Test func generatedCollectionsRoundTrip() {
        var random = IndependentMacroRandom(seed: 0xC0FFEE)
        func list<T>(_ make: (inout IndependentMacroRandom) -> T) -> [T] {
            (0..<Int.random(in: 0...4, using: &random)).map { _ in make(&random) }
        }
        func map<T>(_ make: (inout IndependentMacroRandom) -> T) -> [String: T] {
            Dictionary(list { r in (r.string(), make(&r)) }, uniquingKeysWith: { a, _ in a })
        }
        for _ in 0..<200 {
            IndependentMacroCheckRoundTrip(
                IMCollections(
                    strings: list { $0.string() },
                    matrix: list { r in (0..<Int.random(in: 0...3, using: &r)).map { _ in r.int() } },
                    map: map { $0.int() },
                    mapOfLists: map { r in (0..<Int.random(in: 0...3, using: &r)).map { _ in r.double() } },
                    listOfMaps: list { r in [r.string(): Bool.random(using: &r)] },
                    spelledArray: list { $0.string() },
                    spelledDictionary: map { Bool.random(using: &$0) }))
        }
    }

    @Test func nestedValuesRoundTrip() {
        let leaf = IMLeaf(name: "l", weight: 1.5)
        let bare = IMLeaf(name: "", weight: nil)
        IndependentMacroCheckRoundTrip(
            IMNested(leaf: leaf, maybeLeaf: bare, leaves: [leaf, bare], leafByName: ["a": leaf, "": bare], kind: .small, kinds: IMKind.allCases, maybeKind: .large))
        IndependentMacroCheckRoundTrip(
            IMNested(leaf: bare, maybeLeaf: nil, leaves: [], leafByName: [:], kind: .large, kinds: [], maybeKind: nil))
    }

    /// `[Int?]` encodes `nil` as `null`, so the schema of the element has to accept `null`;
    /// otherwise a value the type itself produced is rejected by the type's own schema (and,
    /// for a tool's output, by the server: §8.1 "structuredContent соответствует outputSchema").
    @Test func collectionsOfOptionalsValidateAgainstTheirOwnSchema() throws {
        let properties = IMOptionalElements.jsonSchema["properties"]
        #expect(properties?["list"] == ["type": "array", "items": nullable(["type": "integer"])])
        #expect(properties?["map"] == ["type": "object", "additionalProperties": nullable(["type": "string"])])
        #expect(properties?["maybeList"] == nullable(["type": "array", "items": nullable(["type": "integer"])]))
        #expect(IMOptionalElements.jsonSchema["required"] == ["list", "map"])
        // `null` is allowed for an element, not for something else in its place.
        let schema = try JSONSchema(.object(IMOptionalElements.jsonSchema))
        #expect(schema.validate(["list": [1, nil], "map": ["a": nil]]) == nil)
        #expect(schema.validate(["list": [1, "x"], "map": [:]]) != nil)
        #expect(schema.validate(["list": nil, "map": [:]]) != nil)
        #expect(schema.validate(["list": [], "map": ["a": 1]]) != nil)
        IndependentMacroCheckRoundTrip(IMOptionalElements(list: [1, 2], map: ["a": "x"], maybeList: [3]))
        IndependentMacroCheckRoundTrip(IMOptionalElements(list: [1, nil, 3], map: [:], maybeList: nil))
        IndependentMacroCheckRoundTrip(IMOptionalElements(list: [], map: ["a": nil, "b": "x"], maybeList: nil))
        IndependentMacroCheckRoundTrip(IMOptionalElements(list: [], map: [:], maybeList: [nil]))
    }

    @Test func defaultsApplyOnlyWhenThePropertyIsAbsent() throws {
        let minimal = try IMDefaults(json: ["required": "r"])
        #expect(minimal == IMDefaults(required: "r"))
        #expect(minimal.count == 3)
        #expect(minimal.tags == ["a", "b"])
        #expect(minimal.kind == .medium)
        #expect(minimal.flag == true)

        let full = try IMDefaults(
            json: ["required": "r", "count": 0, "tags": [], "kind": "small", "ratio": 0, "label": "", "flag": false])
        #expect(full == IMDefaults(required: "r", count: 0, tags: [], kind: .small, ratio: 0, label: "", flag: false))
        IndependentMacroCheckRoundTrip(minimal)
        IndependentMacroCheckRoundTrip(full)

        // A present value of the wrong type is an error, not a silent fall back to the default.
        let error = IndependentMacroDecodingError(IMDefaults.self, ["required": "r", "count": "three"])
        #expect(error?.path == ["count"])
    }

    /// "Optional properties and properties with default values are not required": a property
    /// that is both must still get its default when the member is absent.
    @Test func optionalPropertyKeepsItsDefaultWhenAbsent() throws {
        #expect(IMOptionalWithDefault().limit == 10)
        let decoded = try IMOptionalWithDefault(json: [:])
        #expect(decoded.limit == 10)
        #expect(decoded.name == "anonymous")
        #expect(decoded == IMOptionalWithDefault())
        // A present value still wins.
        #expect(try IMOptionalWithDefault(json: ["limit": 1, "name": "n"]) == IMOptionalWithDefault(limit: 1, name: "n"))
        #expect(try IMOptionalWithDefault(json: ["limit": nil, "name": nil]) == IMOptionalWithDefault())
        #expect(try JSONSchema(.object(IMOptionalWithDefault.jsonSchema)).validate(["limit": nil, "name": nil]) == nil)
        IndependentMacroCheckRoundTrip(IMOptionalWithDefault())
        IndependentMacroCheckRoundTrip(IMOptionalWithDefault(limit: 1, name: "n"))
        // observed, a consequence of the rule: a property that is optional and has a non-nil
        // default cannot be set to `nil` through JSON; `nil` is encoded by omission and comes
        // back as the default.
        let cleared = IMOptionalWithDefault(limit: nil, name: nil)
        #expect(cleared.jsonValue == [:])
        #expect(try IMOptionalWithDefault(json: cleared.jsonValue) == IMOptionalWithDefault())
    }

    @Test func nullForANonOptionalPropertyWithADefault() throws {
        let json: JSONValue = ["required": "r", "count": nil, "tags": nil]
        #expect(try IMDefaults(json: json) == IMDefaults(required: "r"))
        #expect(try JSONSchema(.object(IMDefaults.jsonSchema)).validate(json) != nil)
    }

    @Test func integersAcceptWhatJSONSchemaCallsAnInteger() throws {
        // JSON Schema 2020-12: any number with a zero fractional part is an integer.
        for text in ["{\"text\":\"\",\"flag\":true,\"count\":3.0,\"wide\":1e2,\"ratio\":7}"] {
            let json = try JSON.parse(Array(text.utf8))
            #expect(try JSONSchema(.object(IMScalars.jsonSchema)).validate(json) == nil)
            let value = try IMScalars(json: json)
            #expect(value.count == 3)
            #expect(value.wide == 100)
            #expect(value.ratio == 7)
        }
    }
}

// MARK: - Decoding failures

@Suite struct IndependentMacroSchemaStructErrorTests {
    private let valid: JSONObject = ["text": "t", "flag": true, "count": 1, "wide": 2, "ratio": 0.5]

    private func replacing(_ key: String, with value: JSONValue?) -> JSONValue {
        var object = JSONObject()
        for (name, member) in valid where name != key { object[name] = member }
        if let value { object[key] = value }
        return .object(object)
    }

    @Test func aValidObjectDecodes() throws {
        #expect(try IMScalars(json: .object(valid)) == IMScalars(text: "t", flag: true, count: 1, wide: 2, ratio: 0.5))
    }

    @Test(arguments: ["text", "flag", "count", "wide", "ratio"])
    func aMissingRequiredPropertyIsNamed(key: String) {
        let error = IndependentMacroDecodingError(IMScalars.self, replacing(key, with: nil))
        #expect(error?.path == [key])
        #expect(error?.description.contains(key) == true)
        #expect(error?.reason.contains("missing") == true)
        // The schema agrees that this instance is invalid.
        #expect((try? JSONSchema(.object(IMScalars.jsonSchema)))?.validate(replacing(key, with: nil)) != nil)
    }

    @Test(arguments: ["text", "flag", "count", "wide", "ratio"])
    func nullForARequiredPropertyIsAnErrorNamingIt(key: String) {
        let error = IndependentMacroDecodingError(IMScalars.self, replacing(key, with: .null))
        #expect(error?.path == [key])
        #expect(error?.reason.contains("null") == true)
        #expect((try? JSONSchema(.object(IMScalars.jsonSchema)))?.validate(replacing(key, with: .null)) != nil)
    }

    @Test func wrongTypesAreErrorsNamingThePropertyAndBothTypes() {
        let cases: [(String, JSONValue, String)] = [
            ("text", 1, "string"), ("text", true, "string"), ("text", ["a"], "string"),
            ("flag", "true", "boolean"), ("flag", 1, "boolean"), ("flag", 0, "boolean"),
            ("count", "1", "integer"), ("count", 1.5, "integer"), ("count", true, "integer"), ("count", [:], "integer"),
            ("wide", "1", "integer"), ("wide", 0.1, "integer"),
            ("ratio", "0.5", "number"), ("ratio", false, "number"), ("ratio", [0.5], "number"),
        ]
        for (key, value, expected) in cases {
            let error = IndependentMacroDecodingError(IMScalars.self, replacing(key, with: value))
            #expect(error?.path == [key], "\(key) = \(value)")
            #expect(error?.reason.contains(expected) == true, "\(key) = \(value): \(String(describing: error))")
            #expect((try? JSONSchema(.object(IMScalars.jsonSchema)))?.validate(replacing(key, with: value)) != nil, "\(key) = \(value)")
        }
    }

    @Test func integersOutOfRangeAreErrorsNotTraps() throws {
        var lexemes = ["9223372036854775808", "1e30", "123456789012345678901234567890"]
        #if !FoundationJSON
        lexemes.append("-9223372036854775809")
        #endif
        for lexeme in lexemes {
            let json = try JSON.parse(Array("{\"text\":\"\",\"flag\":true,\"count\":\(lexeme),\"wide\":1,\"ratio\":1}".utf8))
            let error = IndependentMacroDecodingError(IMScalars.self, json)
            #expect(error?.path == ["count"], "\(lexeme)")
            let wide = try JSON.parse(Array("{\"text\":\"\",\"flag\":true,\"count\":1,\"wide\":\(lexeme),\"ratio\":1}".utf8))
            #expect(IndependentMacroDecodingError(IMScalars.self, wide)?.path == ["wide"], "\(lexeme)")
        }
    }

    @Test func aNumberTooLargeForADoubleIsAnErrorNotInfinity() throws {
        let huge = try #require(JSONNumber(lexeme: "1e999"))
        let error = IndependentMacroDecodingError(IMScalars.self, replacing("ratio", with: .number(huge)))
        #expect(error?.path == ["ratio"])
    }

    @Test func aNonObjectIsAnErrorAtTheRoot() {
        for json: JSONValue in [nil, 1, "x", true, [], [["text": "t"]]] {
            let error = IndependentMacroDecodingError(IMScalars.self, json)
            #expect(error?.path == [], "\(json)")
            #expect(error?.reason.contains("object") == true, "\(json)")
        }
    }

    @Test func extraMembersAreIgnored() throws {
        var object = valid
        object["unexpected"] = ["nested": true]
        #expect(try IMScalars(json: .object(object)) == IMScalars(text: "t", flag: true, count: 1, wide: 2, ratio: 0.5))
        #expect(try JSONSchema(.object(IMScalars.jsonSchema)).validate(.object(object)) == nil)
        #expect(IMScalars.jsonSchema["additionalProperties"] == nil)
    }

    @Test func optionalPropertiesTreatNullAsAbsent() throws {
        let decoded = try IMOptionals(json: ["text": nil, "count": nil, "list": nil, "map": nil])
        #expect(decoded == IMOptionals(text: nil, flag: nil, count: nil, wide: nil, ratio: nil, spelledOut: nil, list: nil, map: nil))
        // …but a present value of the wrong type is still an error.
        #expect(IndependentMacroDecodingError(IMOptionals.self, ["count": "1"])?.path == ["count"])
        #expect(IndependentMacroDecodingError(IMOptionals.self, ["list": [1]])?.path.first == "list")
        #expect(IndependentMacroDecodingError(IMOptionals.self, ["spelledOut": 1.5])?.path == ["spelledOut"])
    }

    @Test func errorsInsideNestedValuesCarryTheWholePath() {
        let leaf: JSONValue = ["name": "n"]
        func nested(_ change: (inout JSONObject) -> Void) -> JSONValue {
            var object: JSONObject = ["leaf": leaf, "leaves": [leaf, leaf], "leafByName": ["k": leaf], "kind": "small", "kinds": ["small"]]
            change(&object)
            return .object(object)
        }

        var error = IndependentMacroDecodingError(IMNested.self, nested { $0["leaf"] = ["name": 1] })
        #expect(error?.path == ["leaf", "name"])

        error = IndependentMacroDecodingError(IMNested.self, nested { $0["leaf"] = [:] })
        #expect(error?.path == ["leaf", "name"])
        #expect(error?.reason.contains("missing") == true)

        error = IndependentMacroDecodingError(IMNested.self, nested { $0["leaves"] = [leaf, ["name": "ok", "weight": "heavy"]] })
        #expect(error?.path.first == "leaves")
        #expect(error?.path.last == "weight")
        #expect(error?.path.count == 3)
        #expect(error?.path.dropFirst().first?.contains("1") == true)

        error = IndependentMacroDecodingError(IMNested.self, nested { $0["leafByName"] = ["first": leaf, "second": ["name": nil]] })
        #expect(error?.path == ["leafByName", "second", "name"])

        error = IndependentMacroDecodingError(IMNested.self, nested { $0["kinds"] = ["small", "huge"] })
        #expect(error?.path.first == "kinds")
        #expect(error?.path.count == 2)
        #expect(error?.description.contains("small") == true)

        error = IndependentMacroDecodingError(IMNested.self, nested { $0["maybeLeaf"] = "leaf" })
        #expect(error?.path == ["maybeLeaf"])

        error = IndependentMacroDecodingError(IMNested.self, nested { $0["maybeKind"] = 3 })
        #expect(error?.path == ["maybeKind"])
    }

    @Test func collectionsRejectWrongShapes() {
        func collections(_ change: (inout JSONObject) -> Void) -> JSONValue {
            var object: JSONObject = [
                "strings": [], "matrix": [], "map": [:], "mapOfLists": [:], "listOfMaps": [], "spelledArray": [],
                "spelledDictionary": [:],
            ]
            change(&object)
            return .object(object)
        }
        #expect((try? IMCollections(json: collections { _ in })) != nil)
        #expect(IndependentMacroDecodingError(IMCollections.self, collections { $0["strings"] = "a" })?.path == ["strings"])
        #expect(IndependentMacroDecodingError(IMCollections.self, collections { $0["strings"] = [:] })?.path == ["strings"])
        #expect(IndependentMacroDecodingError(IMCollections.self, collections { $0["map"] = [] })?.path == ["map"])
        #expect(IndependentMacroDecodingError(IMCollections.self, collections { $0["map"] = ["k": "v"] })?.path == ["map", "k"])
        let matrix = IndependentMacroDecodingError(IMCollections.self, collections { $0["matrix"] = [[1], [2, "x"]] })
        #expect(matrix?.path.first == "matrix")
        #expect(matrix?.path.count == 3)
        let lists = IndependentMacroDecodingError(IMCollections.self, collections { $0["mapOfLists"] = ["k": [1, nil]] })
        #expect(lists?.path.prefix(2) == ["mapOfLists", "k"])
        #expect(lists?.path.count == 3)
    }

    /// Every malformed input must come back as an error. The loop feeds each property every
    /// kind of JSON value; a trap anywhere fails the whole run.
    @Test func noInputShapeTraps() {
        let shapes: [JSONValue] = [nil, true, 0, -1, 1.5, "", "x", [], [nil], [1, "a"], [:], ["a": nil], ["a": [1]], [[[]]]]
        for key in IMNested.jsonSchema["properties"]?.objectValue?.map(\.key) ?? [] {
            for shape in shapes {
                var object: JSONObject = [
                    "leaf": ["name": "n"], "leaves": [], "leafByName": [:], "kind": "small", "kinds": [],
                ]
                object[key] = shape
                let json = JSONValue.object(object)
                let schemaAccepts = (try? JSONSchema(.object(IMNested.jsonSchema)))?.validate(json) == nil
                do {
                    let value = try IMNested(json: json)
                    // Whatever decodes must have been acceptable to the schema.
                    #expect(schemaAccepts, "decoded \(json) that the schema rejects into \(value)")
                } catch {
                    #expect(error.path.first == key, "\(json): \(error)")
                    #expect(!schemaAccepts, "the schema accepts \(json) but decoding fails: \(error)")
                }
            }
        }
    }
}

// MARK: - Recursive types

@Suite struct IndependentMacroSchemaRecursionTests {
    /// Э1 names a recursive type among the schemas the macros must handle. Building the schema
    /// of `IMTree` evaluates `[IMTree].jsonSchema`, which needs `IMTree.jsonSchema` again while
    /// its `static let` is still being initialized. Run in a child process, because the failure
    /// mode is a trap or a hang rather than a wrong value.
    @Test func recursiveTypeHasASchema() async {
        await #expect(processExitsWith: .success) {
            let schema = IMTree.jsonSchema
            guard schema["type"] == "object" else { fatalError("no schema") }
        }
    }

    @Test func recursiveTypeRoundTrips() async {
        await #expect(processExitsWith: .success) {
            let tree = IMTree(value: 1, children: [IMTree(value: 2, children: []), IMTree(value: 3, children: [IMTree(value: 4, children: [])])])
            guard let decoded = try? IMTree(json: tree.jsonValue), decoded == tree else { fatalError("round trip") }
            guard let schema = try? JSONSchema(.object(IMTree.jsonSchema)), schema.validate(tree.jsonValue) == nil else {
                fatalError("schema")
            }
        }
    }

    /// The same through an optional dictionary.
    @Test func recursionThroughAnOptionalDictionaryHasASchema() async {
        await #expect(processExitsWith: .success) {
            let leaf = IMGraphNode(name: "leaf", edges: nil)
            let root = IMGraphNode(name: "root", edges: ["a": leaf, "b": IMGraphNode(name: "mid", edges: ["c": leaf])])
            guard let schema = try? JSONSchema(.object(IMGraphNode.jsonSchema)), schema.validate(root.jsonValue) == nil else {
                fatalError("schema")
            }
            guard let decoded = try? IMGraphNode(json: root.jsonValue), decoded == root else { fatalError("round trip") }
        }
    }

    /// `` var `self`: Int `` is legal Swift. In a child process, because the generated encoder
    /// reads `` `self` `` — the whole value — instead of the property and recurses until the
    /// stack runs out.
    @Test func aPropertyNamedSelfIsEncodedAsAProperty() async {
        await #expect(processExitsWith: .success) {
            let value = IMSelfNamed(self: 7, other: "o")
            guard value.jsonValue == ["self": 7, "other": "o"] else { fatalError("wrong encoding") }
        }
    }

    @Test func aPropertyNamedSelfIsDeclaredAndDecoded() throws {
        #expect(IMSelfNamed.jsonSchema["properties"]?.objectValue?.map(\.key) == ["self", "other"])
        #expect(try IMSelfNamed(json: ["self": 7, "other": "o"]) == IMSelfNamed(self: 7, other: "o"))
    }

    /// Decoding and encoding do not touch the schema, so they work even for a recursive type.
    @Test func recursiveValuesDecodeWithoutTheSchema() throws {
        let json: JSONValue = ["value": 1, "children": [["value": 2, "children": []]]]
        let tree = try IMTree(json: json)
        #expect(tree == IMTree(value: 1, children: [IMTree(value: 2, children: [])]))
        #expect(tree.jsonValue == json)
        let error = IndependentMacroDecodingError(IMTree.self, ["value": 1, "children": [["value": 2, "children": [["value": "x", "children": []]]]]])
        #expect(error?.path.first == "children")
        #expect(error?.path.last == "value")
        #expect(error?.path.count == 5)
    }
}
