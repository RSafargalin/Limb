import Limb
import Testing


// MARK: - Fixtures

@Schema
private enum IMColor: String, Equatable, CaseIterable {
    case red
    case green = "GREEN"
    case blue, alpha = "a", clear
}

@Schema
private enum IMSingle: String, Equatable, CaseIterable {
    case only
}

@Schema
private enum IMKeywordCases: String, Equatable, CaseIterable {
    case `default`
    case `class`, `in`
    case `self`
    case `for` = "FOR"
    case normal
}

/// Raw values that need escaping in a Swift literal and in JSON.
@Schema
private enum IMAwkwardRawValues: String, Equatable, CaseIterable {
    case quote = "say \"hi\""
    case backslash = "back\\slash"
    case newline = "line\nbreak"
    case tab = "tab\there"
    case interpolationLike = "\\(x)"
    case empty = ""
    case space = " "
    case unicode = "é漢😀"
    case escapedScalar = "\u{1F600}!"
    case raw = #"raw\n"quoted""#
    case null = "null"
    case number = "1"
}

/// Documented.
///
/// Second paragraph.
@Schema
private enum IMDocumented: String, Equatable {
    /// A case comment has no place in an `enum` schema and must not leak anywhere.
    case one
    case two
}

@Schema
private enum IMWithMembers: String, Equatable, CaseIterable {
    case north, south
    static let fallback = IMWithMembers.north
    var opposite: IMWithMembers { self == .north ? .south : .north }
    func describe() -> String { rawValue }
    init?(short: String) { self.init(rawValue: short == "n" ? "north" : "south") }
}

/// `é` as one scalar (U+00E9).
@Schema
private enum IMAccent: String, Equatable {
    case precomposed = "\u{E9}"
}

@Schema
private struct IMEnumHolder: Equatable {
    /// The holder's own words.
    var documented: IMDocumented
    var plain: IMDocumented
    var color: IMColor?
    var colors: [IMColor] = []
    var byName: [String: IMColor] = [:]
}

private struct IMOuter {
    @Schema
    enum Mode: String, Equatable, CaseIterable { case fast, slow }
}

// MARK: - Tests

@Suite struct IndependentMacroSchemaEnumTests {
    @Test func schemaListsRawValuesInDeclarationOrder() {
        let schema = IMColor.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["type"] == "string")
        #expect(schema["enum"] == ["red", "GREEN", "blue", "a", "clear"])
        // The schema and the language agree on the set of values.
        #expect(schema["enum"]?.arrayValue?.compactMap(\.stringValue) == IMColor.allCases.map(\.rawValue))
        #expect(schema["description"] == nil)
    }

    @Test func everyCaseRoundTrips() throws {
        for value in IMColor.allCases { IndependentMacroCheckRoundTrip(value) }
        for value in IMSingle.allCases { IndependentMacroCheckRoundTrip(value) }
        for value in IMKeywordCases.allCases { IndependentMacroCheckRoundTrip(value) }
        for value in IMAwkwardRawValues.allCases { IndependentMacroCheckRoundTrip(value) }
        for value in IMWithMembers.allCases { IndependentMacroCheckRoundTrip(value) }
        for value in IMOuter.Mode.allCases { IndependentMacroCheckRoundTrip(value) }
        #expect(IMColor.green.jsonValue == "GREEN")
        #expect(try IMColor(json: "a") == .alpha)
    }

    @Test func singleCase() {
        #expect(IMSingle.jsonSchema["enum"] == ["only"])
        #expect(IndependentMacroDecodingError(IMSingle.self, "other") != nil)
    }

    @Test func keywordCaseNamesLoseTheirBackticks() throws {
        #expect(IMKeywordCases.jsonSchema["enum"] == ["default", "class", "in", "self", "FOR", "normal"])
        #expect(IMKeywordCases.default.jsonValue == "default")
        #expect(try IMKeywordCases(json: "class") == .class)
        #expect(try IMKeywordCases(json: "self") == .`self`)
        #expect(IndependentMacroDecodingError(IMKeywordCases.self, "`default`") != nil)
        #expect(IndependentMacroDecodingError(IMKeywordCases.self, "for") != nil)
    }

    @Test func rawValuesThatNeedEscapingArriveIntact() throws {
        let schema = IMAwkwardRawValues.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(
            schema["enum"] == [
                "say \"hi\"", "back\\slash", "line\nbreak", "tab\there", "\\(x)", "", " ", "é漢😀", "😀!", "raw\\n\"quoted\"", "null", "1",
            ])
        #expect(schema["enum"]?.arrayValue?.compactMap(\.stringValue) == IMAwkwardRawValues.allCases.map(\.rawValue))
        // The strings "null" and "1" are strings, not the JSON values they look like.
        #expect(IndependentMacroDecodingError(IMAwkwardRawValues.self, nil) != nil)
        #expect(IndependentMacroDecodingError(IMAwkwardRawValues.self, 1) != nil)
        #expect(try IMAwkwardRawValues(json: "null") == .null)
    }

    @Test func membersOtherThanCasesAreIgnored() {
        #expect(IMWithMembers.jsonSchema["enum"] == ["north", "south"])
    }

    @Test func nestedEnum() {
        #expect(IMOuter.Mode.jsonSchema["enum"] == ["fast", "slow"])
    }

    @Test func descriptionComesFromTheDocComment() {
        let schema = IMDocumented.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["description"] == "Documented.\n\nSecond paragraph.")
        #expect(schema["enum"] == ["one", "two"])
        #expect(!"\(JSONValue.object(schema))".contains("case comment"))
    }

    /// A property's own comment describes the property; without one, the enum's description
    /// is what the model sees.
    @Test func propertyDescriptionOverridesTheEnumDescription() {
        let properties = IMEnumHolder.jsonSchema["properties"]
        #expect(properties?["documented"] == ["type": "string", "enum": ["one", "two"], "description": "The holder's own words."])
        #expect(properties?["plain"] == .object(IMDocumented.jsonSchema))
        #expect(IMEnumHolder.jsonSchema["required"] == ["documented", "plain"])
        IndependentMacroCheckSchema(IMEnumHolder.jsonSchema)
        IndependentMacroCheckRoundTrip(IMEnumHolder(documented: .one, plain: .two, color: .green, colors: IMColor.allCases, byName: ["x": .alpha]))
        IndependentMacroCheckRoundTrip(IMEnumHolder(documented: .two, plain: .one, color: nil))
    }

    @Test func unknownValuesAreErrorsThatListTheAllowedOnes() {
        let error = IndependentMacroDecodingError(IMColor.self, "purple")
        #expect(error?.path == [])
        for allowed in ["red", "GREEN", "blue", "a", "clear"] {
            #expect(error?.reason.contains(allowed) == true, "\(allowed) is not mentioned in \(String(describing: error))")
        }
        // Case names are not accepted in place of raw values, and matching is case-sensitive.
        #expect(IndependentMacroDecodingError(IMColor.self, "green") != nil)
        #expect(IndependentMacroDecodingError(IMColor.self, "alpha") != nil)
        #expect(IndependentMacroDecodingError(IMColor.self, "RED") != nil)
        #expect(IndependentMacroDecodingError(IMColor.self, " red") != nil)
        #expect(IndependentMacroDecodingError(IMColor.self, "") != nil)
    }

    @Test func nonStringsAreErrors() {
        for json: JSONValue in [nil, 0, 1, true, ["red"], ["rawValue": "red"], 1.5] {
            let error = IndependentMacroDecodingError(IMColor.self, json)
            #expect(error?.path == [], "\(json)")
            #expect((try? JSONSchema(.object(IMColor.jsonSchema)))?.validate(json) != nil, "\(json)")
        }
    }

    @Test func errorsInsideContainersNameThePath() {
        var error = IndependentMacroDecodingError(IMEnumHolder.self, ["documented": "three", "plain": "one"])
        #expect(error?.path == ["documented"])
        #expect(error?.reason.contains("one") == true)
        error = IndependentMacroDecodingError(IMEnumHolder.self, ["documented": "one", "plain": "one", "colors": ["red", "nope"]])
        #expect(error?.path.first == "colors")
        #expect(error?.path.count == 2)
        error = IndependentMacroDecodingError(IMEnumHolder.self, ["documented": "one", "plain": "one", "byName": ["k": 1]])
        #expect(error?.path == ["byName", "k"])
        error = IndependentMacroDecodingError(IMEnumHolder.self, ["documented": "one", "plain": "one", "color": "nope"])
        #expect(error?.path == ["color"])
    }

    @Test func decodingDoesNotAcceptACanonicallyEquivalentSpelling() throws {
        let decomposed = JSONValue.string("e\u{301}")
        #expect(try JSONSchema(.object(IMAccent.jsonSchema)).validate("\u{E9}") == nil)
        #expect(try JSONSchema(.object(IMAccent.jsonSchema)).validate(decomposed) != nil)
        #expect(try IMAccent(json: "\u{E9}") == .precomposed)
        #expect(throws: JSONDecodingError.self) { try IMAccent(json: decomposed) }
    }
}
