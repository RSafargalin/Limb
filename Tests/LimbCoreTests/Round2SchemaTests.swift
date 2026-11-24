import LimbCore
import Testing


private func number(_ text: String) -> JSONValue {
    guard let value = JSONNumber(lexeme: text) else { fatalError("not a JSON number: \(text)") }
    return .number(value)
}

private func compileError(_ schema: JSONValue, _ limits: JSONSchema.Limits = JSONSchema.Limits()) -> JSONSchemaError? {
    do {
        _ = try JSONSchema(schema, limits: limits)
        return nil
    } catch {
        return error
    }
}

private let draft7 = "http://json-schema.org/draft-07/schema#"

// MARK: - J3

@Suite struct Round2NumericKeywordTests {
    /// (keyword, bound, value, valid)
    static let bounds: [(String, String, String, Bool)] = [
        ("minimum", "9007199254740993", "9007199254740992", false),
        ("minimum", "9007199254740993", "9007199254740993", true),
        ("minimum", "9007199254740993", "9007199254740993.0", true),
        ("minimum", "9007199254740993", "9.007199254740993e15", true),
        ("maximum", "9007199254740992", "9007199254740993", false),
        ("maximum", "18446744073709551616", "18446744073709551615", true),
        ("maximum", "18446744073709551615", "18446744073709551616", false),
        ("minimum", "-9223372036854775809", "-9223372036854775808", true),
        ("minimum", "-9223372036854775808", "-9223372036854775809", false),
        ("exclusiveMinimum", "0", "1e-400", true),
        ("exclusiveMinimum", "0", "-0", false),
        ("exclusiveMinimum", "0", "0.0", false),
        ("exclusiveMaximum", "0", "-1e-400", true),
        ("minimum", "1e-400", "0", false),
        ("minimum", "0", "-0.0", true),
        ("maximum", "-0", "0", true),
        ("maximum", "1e400", "1e399", true),
        ("maximum", "1e399", "1e400", false),
        ("maximum", "1E400", "10e399", true),
        ("exclusiveMaximum", "1E400", "10e399", false),
        ("minimum", "1.0000000000000000001", "1", false),
        ("maximum", "0.99999999999999999999", "1", false),
        ("minimum", "-1e400", "-1e401", false),
        ("maximum", "-1e400", "-1e401", true),
        ("exclusiveMinimum", "2.5", "2.50000000000000000000001", true),
        ("exclusiveMaximum", "2.5", "25e-1", false),
    ]

    @Test func boundsCompareExactly() throws {
        for (keyword, bound, value, expected) in Self.bounds {
            let schema = try JSONSchema([keyword: number(bound)])
            #expect((schema.validate(number(value)) == nil) == expected, "\(keyword) \(bound), value \(value)")
        }
    }

    /// (divisor, value, multiple)
    static let multiples: [(String, String, Bool)] = [
        ("1", "1e-10", false), ("1", "1.0000000001", false), ("1", "1e400", true), ("1", "-7", true), ("1", "0", true),
        ("3", "18446744073709551616", false), ("3", "9223372036854775808", false), ("3", "18446744073709551615", true),
        ("3", "1e400", false), ("3", "3e400", true), ("7", "1e400", false), ("7", "7e400", true),
        ("0.1", "0.3", true), ("0.1", "0.35", false), ("0.1", "1e-1", true), ("0.10", "0.05", false),
        ("1e-5", "0.00003", true), ("1e-5", "0.000035", false), ("1e-5", "1e-400", false), ("1e-400", "1e-400", true),
        ("1e-400", "2e-400", true), ("1e-400", "1e-401", false), ("1e-400", "1", true),
        ("2.5", "7.5", true), ("2.5", "-7.5", true), ("2.5", "5", true), ("2.5", "6", false), ("2.5", "1e30", true),
        ("1e30", "1e30", true), ("1e30", "1e29", false), ("1e30", "3e31", true), ("1e30", "1e400", true),
        ("9999999999999999999", "19999999999999999998", true), ("9999999999999999999", "19999999999999999999", false),
        ("1234567890123456789000", "2469135780246913578000", true), ("0.0001", "0.00005", false),
        ("3", "1e999999999999999999", false), ("1e30", "1e999999999999999999", true), ("1e-5", "1e-999999999999999999", false),
    ]

    @Test func multipleOfIsAnExactRemainder() throws {
        for (divisor, value, expected) in Self.multiples {
            let schema = try JSONSchema(["multipleOf": number(divisor)])
            #expect((schema.validate(number(value)) == nil) == expected, "multipleOf \(divisor), value \(value)")
        }
    }

    /// Small integers times powers of ten, in several spellings, against exact arithmetic done
    /// here with 128-bit integers.
    @Test func multipleOfAgreesWithExactArithmetic() throws {
        var state: UInt64 = 0x1234_5678_9ABC_DEF1
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        var checked = 0
        for _ in 0..<300 {
            let divisor = next(999) + 1
            let divisorScale = next(13) - 6
            let schema = try JSONSchema(["multipleOf": number(Self.spell(divisor, divisorScale, style: next(4)))])
            for _ in 0..<40 {
                // Values near multiples are the interesting ones.
                var value = (next(2000) - 1000) * divisor
                if next(3) == 0 { value += next(5) - 2 }
                let valueScale = divisorScale + next(9) - 4
                let lowest = min(valueScale, divisorScale)
                let scaledValue = Int128(value) * Self.power(valueScale - lowest)
                let scaledDivisor = Int128(divisor) * Self.power(divisorScale - lowest)
                let expected = scaledValue % scaledDivisor == 0
                let text = Self.spell(value, valueScale, style: next(4))
                #expect((schema.validate(number(text)) == nil) == expected, "\(text) multipleOf \(divisor)e\(divisorScale)")
                checked += 1
            }
        }
        #expect(checked == 12_000)
    }

    static func power(_ exponent: Int) -> Int128 {
        var result: Int128 = 1
        for _ in 0..<exponent { result *= 10 }
        return result
    }

    /// `significand × 10^scale` written as JSON: exponent form, positional, normalized with
    /// a capital `E`, or positional with trailing fraction zeros.
    static func spell(_ significand: Int, _ scale: Int, style: Int) -> String {
        if significand == 0 { return ["0", "0.0", "0e\(scale)", "-0"][style] }
        let sign = significand < 0 ? "-" : ""
        let digits = String(significand.magnitude)
        switch style {
        case 0:
            return "\(significand)e\(scale)"
        case 2 where digits.count > 1:
            let first = digits.prefix(1)
            let rest = digits.dropFirst()
            return "\(sign)\(first).\(rest)E\(scale + rest.count >= 0 ? "+" : "")\(scale + rest.count)"
        default:
            var text: String
            if scale >= 0 {
                text = digits + String(repeating: "0", count: scale)
                if style == 3 { text += ".000" }
            } else {
                let padded = String(repeating: "0", count: max(0, -scale - digits.count + 1)) + digits
                let point = padded.count + scale
                text = padded.prefix(point) + "." + padded.dropFirst(point)
                if style == 3 { text += "00" }
            }
            return sign + text
        }
    }

    @Test func multipleOfMustBePositiveAndHaveAtMostNineteenDigits() {
        for divisor in ["0", "0.0", "-0", "-1", "-0.5", "0e10"] {
            let error = compileError(["multipleOf": number(divisor)])
            #expect(error?.pointer == "/multipleOf", "\(divisor)")
            #expect(error?.reason.contains("greater than 0") == true, "\(divisor)")
        }
        for divisor in ["12345678901234567891", "0.12345678901234567891", "1.2345678901234567891e300"] {
            #expect(compileError(["multipleOf": number(divisor)])?.reason.contains("19 significant digits") == true, "\(divisor)")
        }
        for divisor in ["1234567890123456789", "1234567890123456789000", "1.234567890123456789e-300", "1e400", "1e-400"] {
            #expect(compileError(["multipleOf": number(divisor)]) == nil, "\(divisor)")
        }
        #expect(compileError(["multipleOf": "1"])?.pointer == "/multipleOf")
    }

    @Test func messagesQuoteTheSchemaNumberAsWritten() throws {
        func reason(_ schema: JSONValue, _ instance: JSONValue) throws -> String? {
            try JSONSchema(schema).validate(instance)?.reason
        }
        #expect(try reason(["minimum": 0], -1) == "must be at least 0")
        #expect(try reason(["minimum": number("0.0")], -1) == "must be at least 0.0")
        #expect(try reason(["maximum": number("1E2")], 101) == "must be at most 1E2")
        #expect(try reason(["exclusiveMinimum": number("-0")], 0) == "must be greater than -0")
        #expect(try reason(["exclusiveMaximum": number("1e400")], number("1e401")) == "must be less than 1e400")
        #expect(try reason(["multipleOf": number("0.10")], number("0.05")) == "must be a multiple of 0.10")
    }
}

// MARK: - J7

@Suite struct Round2MalformedKeywordTests {
    static let notASchema: [JSONValue] = ["x", 1, nil, [], [true]]
    static let notAMap: [JSONValue] = ["x", 1, true, nil, [], ["a": 5], ["a": "x"]]
    static let notAList: [JSONValue] = ["x", 1, true, nil, [:], [5], ["x"]]
    static let notANumber: [JSONValue] = ["1", true, nil, [], [:], [1]]
    static let notACount: [JSONValue] = ["1", true, nil, [], [:], -1, number("1.5"), number("-0.5")]
    static let notAString: [JSONValue] = [1, true, nil, [], [:], ["x"]]
    static let notAStringList: [JSONValue] = ["a", 1, true, nil, [:], [1], ["a", 1], [nil]]

    /// (schema, the pointer the error must name), for every keyword the compiler reads.
    static var cases: [(JSONValue, String)] {
        var cases: [(JSONValue, String)] = []
        func add(_ keyword: String, _ values: [JSONValue], context: JSONObject = [:]) {
            for value in values {
                var object = context
                object[keyword] = value
                cases.append((.object(object), "/" + keyword))
            }
        }
        for keyword in ["items", "contains", "additionalProperties", "propertyNames", "not", "if"] { add(keyword, notASchema) }
        add("then", notASchema, context: ["if": true])
        add("else", notASchema, context: ["if": true])
        add("additionalItems", notASchema, context: ["$schema": .string(draft7), "items": [true]])
        add("items", ["x", 1, nil], context: ["$schema": .string(draft7)])
        add("items", [[true], []])
        for keyword in ["properties", "patternProperties", "dependentSchemas"] { add(keyword, notAMap) }
        add("prefixItems", notAList)
        for keyword in ["allOf", "anyOf", "oneOf"] { add(keyword, notAList + [[]]) }
        for keyword in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"] { add(keyword, notANumber) }
        for keyword in [
            "minLength", "maxLength", "minItems", "maxItems", "minContains", "maxContains", "minProperties", "maxProperties",
        ] {
            add(keyword, notACount)
        }
        add("minContains", notACount, context: ["contains": true])
        add("pattern", notAString)
        add("uniqueItems", ["true", 1, 0, nil, [], [:]])
        add("type", [1, true, nil, [:], [], [1], ["strin"], "strin", ["string", 1], "Integer"])
        add("enum", ["x", 1, true, nil, [:]])
        add("required", notAStringList)
        add("dependentRequired", ["x", 1, true, nil, [], ["a": "b"], ["a": [1]], ["a": true]])
        add("dependencies", ["x", 1, true, nil, [], ["a": 5], ["a": [1]], ["a": "b"]])
        add("dependencies", [["a": 5]], context: ["$schema": .string(draft7)])
        add("$ref", [1, true, nil, [], [:]])
        add("$id", [1, true, nil, [], [:]])
        add("$schema", [1, true, nil, [], [:], "http://json-schema.org/draft-04/schema#", "https://json-schema.org/draft/2019-09/schema"])
        return cases
    }

    @Test func everyKeywordWithAWrongTypeIsACompileError() {
        let cases = Self.cases
        #expect(cases.count > 200)
        for (schema, pointer) in cases {
            let error = compileError(schema)
            #expect(error != nil, "\(schema) must not compile")
            if let error { #expect(error.pointer.hasPrefix(pointer), "\(schema): \(error)") }
        }
    }

    @Test func theSameKeywordsNestedAreCompileErrorsWithTheNestedPointer() {
        for (schema, pointer) in Self.cases where !pointer.hasPrefix("/$") {
            guard case .object(let object) = schema, object["$schema"] == nil else { continue }
            let nested: JSONValue = ["properties": ["p": schema]]
            let error = compileError(nested)
            #expect(error?.pointer.hasPrefix("/properties/p" + pointer) == true, "\(nested): \(String(describing: error))")
        }
    }

    @Test func schemaDialectRequiresAResourceRoot() {
        let dialect: JSONValue = "https://json-schema.org/draft/2020-12/schema"
        for schema: JSONValue in [
            ["properties": ["a": ["$schema": dialect]]],
            ["items": ["$schema": dialect]],
            ["$defs": ["d": ["$schema": dialect]], "$ref": "#/$defs/d"],
            ["anyOf": [true, ["not": ["$schema": dialect]]]],
        ] {
            #expect(compileError(schema) != nil, "\(schema)")
        }
        #expect(compileError(["$id": "https://example.com/s", "$schema": dialect]) == nil)
        #expect(compileError([
            "$id": "https://example.com/s",
            "$defs": ["d": ["$id": "d.json", "$schema": dialect]],
            "$ref": "d.json",
        ]) == nil)
    }

    @Test func wellTypedValuesCompile() {
        let schemas: [JSONValue] = [
            ["type": ["string", "null"], "enum": [1, "a", nil], "const": [1], "uniqueItems": false, "minLength": number("2.0")],
            ["items": false, "prefixItems": [], "contains": true, "minContains": 0, "maxContains": 3],
            ["dependentRequired": ["a": []], "dependentSchemas": ["a": true], "required": []],
            ["$schema": .string(draft7), "items": [true, ["type": "string"]], "additionalItems": false, "dependencies": ["a": ["b"], "c": true]],
            ["if": false, "then": true, "else": ["type": "string"], "propertyNames": ["maxLength": 3]],
        ]
        for schema in schemas { #expect(compileError(schema) == nil, "\(schema)") }
    }
}

// MARK: - J8

@Suite struct Round2ReferenceTests {
    /// JSON Pointer escaping (`~0`, `~1`) and then URI percent-encoding, as RFC 6901 section 6 says.
    static func fragment(_ key: String, percentEncode: Bool) -> String {
        var token = key.replacing("~", with: "~0").replacing("/", with: "~1")
        if percentEncode {
            var encoded = ""
            for byte in token.utf8 {
                let isUnreserved = (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
                encoded += isUnreserved ? String(UnicodeScalar(byte)) : "%" + String(byte, radix: 16, uppercase: true).leftPadded()
            }
            token = encoded
        }
        return "#/$defs/" + token
    }

    static let oddNames = ["", "~", "/", "~1", "~0", "%", "%25", "a b", "\u{E9}", "$ref", "0", "-1", "properties", "a/b~c", "#", "😀", "\"", "\\"]

    @Test(arguments: [false, true])
    func referencesToDefinitionsWithOddNames(percentEncode: Bool) throws {
        var definitions = JSONObject()
        var properties = JSONObject()
        for (index, name) in Self.oddNames.enumerated() {
            definitions[name] = ["const": .string(name)]
            properties["p\(index)"] = ["$ref": .string(Self.fragment(name, percentEncode: percentEncode))]
        }
        if !percentEncode {
            // A raw "%" in a fragment is not percent-encoding of anything: leave those two out.
            properties["p5"] = nil
            properties["p6"] = nil
        }
        let schema = try JSONSchema(["$defs": .object(definitions), "properties": .object(properties)])
        for (index, name) in Self.oddNames.enumerated() where properties["p\(index)"] != nil {
            #expect(schema.validate(["p\(index)": .string(name)]) == nil, "\(name.debugDescription)")
            #expect(schema.validate(["p\(index)": .string(name + "x")]) != nil, "\(name.debugDescription)")
        }
    }

    @Test(arguments: [
        "#/enum/0", "#/const", "#/properties", "#/$defs", "#/required/0", "#/type", "#/default", "#/examples/0",
        "#/properties/a/type", "#/properties/a/enum", "#/prefixItems/01", "#/prefixItems/-0", "#/prefixItems/+0",
        "#/prefixItems/ 0", "#/prefixItems/0x0", "#/prefixItems/1", "#/prefixItems/-1", "#/prefixItems/0.0",
        "#/prefixItems/99999999999999999999", "#/$defs/missing", "#/$defs/d/", "#/$defs//d", "#d", "#/dependencies/a",
        "#/items/0", "#/unknown", "#/title", "#/", "http://example.com/s", "other.json#/$defs/d", "#/$defs/d/const",
        "#/$defs/d/properties", "#/allOf", "#/allOf/1", "#/patternProperties", "#/if/type",
    ])
    func referencesThatDoNotNameASchemaAreRefused(reference: String) {
        let schema: JSONValue = [
            "enum": [["type": "string"]], "const": ["type": "string"], "default": ["type": "string"],
            "examples": [["type": "string"]], "required": ["a"], "type": "object", "title": "t",
            "unknown": ["type": "string"],
            "properties": ["a": ["type": "string", "enum": ["x"]]],
            "prefixItems": [["type": "string"]], "items": ["type": "string"],
            "$defs": ["d": ["const": ["type": "string"], "properties": ["z": true]]],
            "dependencies": ["a": ["b"]], "allOf": [true], "patternProperties": ["^x": true],
            "if": ["type": "string"],
            "propertyNames": ["$ref": .string(reference)],
        ]
        #expect(compileError(schema) != nil, "\(reference)")
    }

    @Test(arguments: [
        "#", "#/items", "#/prefixItems/0", "#/prefixItems/10", "#/additionalProperties", "#/properties/a",
        "#/properties/a/items", "#/definitions/x", "#/not", "#/if", "#/then", "#/else", "#/allOf/0", "#/anyOf/1",
        "#/patternProperties/%5Ex", "#/patternProperties/^x", "#/dependentSchemas/d", "#/contains", "#/$defs/d/not",
        "#/dependencies/s", "#/properties/a/properties/b",
    ])
    func referencesToSchemasResolve(reference: String) {
        let schema: JSONValue = [
            "items": true, "prefixItems": .array(Array(repeating: true, count: 11)), "additionalProperties": true,
            "properties": ["a": ["items": true, "properties": ["b": true]]], "definitions": ["x": true], "not": false,
            "if": true, "then": true, "else": true, "allOf": [true], "anyOf": [false, true],
            "patternProperties": ["^x": true], "dependentSchemas": ["d": true], "contains": true,
            "$defs": ["d": ["not": false]], "dependencies": ["s": true],
            "propertyNames": ["$ref": .string(reference)],
        ]
        #expect(compileError(schema) == nil, "\(reference)")
    }

    @Test func draftSevenTupleItemsCanBeReferenced() throws {
        let schema = try JSONSchema([
            "$schema": .string(draft7), "items": [["type": "string"], ["type": "integer"]],
            "properties": ["a": ["$ref": "#/items/1"]],
        ])
        #expect(schema.validate(["a": 1]) == nil)
        #expect(schema.validate(["a": "x"]) != nil)
        #expect(compileError(["$schema": .string(draft7), "items": [true], "properties": ["a": ["$ref": "#/items/00"]]]) != nil)
        #expect(compileError(["$schema": .string(draft7), "items": [true], "properties": ["a": ["$ref": "#/items/1"]]]) != nil)
    }

    @Test func cyclesAndSelfReference() throws {
        // Recursion that consumes the instance is ordinary.
        let tree = try JSONSchema([
            "type": "object", "properties": ["value": ["type": "integer"], "children": ["items": ["$ref": "#"]]],
        ])
        var value: JSONValue = ["value": 1]
        for _ in 0..<40 { value = ["value": 1, "children": [value, ["value": 2]]] }
        #expect(tree.validate(value) == nil)
        value = ["value": 1, "children": [["value": "x"]]]
        #expect(tree.validate(value) != nil)

        // Recursion that does not: compiles, and every value is refused with its own message.
        for schema: JSONValue in [
            ["$ref": "#"],
            ["$defs": ["a": ["$ref": "#/$defs/b"], "b": ["$ref": "#/$defs/a"]], "$ref": "#/$defs/a"],
            ["allOf": [["$ref": "#"]]],
        ] {
            let compiled = try JSONSchema(schema)
            #expect(compiled.validate(1)?.reason == "the schema refers to itself without consuming input", "\(schema)")
        }
        // Under `anyOf` the cut is one failed alternative among others: still no value is valid.
        #expect(try JSONSchema(["anyOf": [["$ref": "#"], false]]).validate(1) != nil)
        // Left recursion with a way out means what its way out means.
        let leftRecursive = try JSONSchema(["anyOf": [["$ref": "#"], ["type": "string"]]])
        #expect(leftRecursive.validate("s") == nil)
        #expect(leftRecursive.validate(1) != nil)
    }

    static let selfReferenceRefusal = "the schema refers to itself without consuming input"

    /// (schema, instance, expected reason at the root or `nil` for valid). Each answer is the
    /// only defensible one: either the cut cannot change the outcome, or the schema has no
    /// meaning for the value and the run must say so.
    static let cuts: [(String, JSONValue, JSONValue, String?)] = [
        ("not self", ["not": ["$ref": "#"]], 1, selfReferenceRefusal),
        ("not self, one property", ["not": ["$ref": "#"], "properties": ["x": true]], 1, selfReferenceRefusal),
        ("not self, two properties", ["not": ["$ref": "#"], "properties": ["x": true, "y": true]], "s", selfReferenceRefusal),
        ("not anyOf not self", ["not": ["anyOf": [["not": ["$ref": "#"]]]]], 1, selfReferenceRefusal),
        ("not anyOf (not self, string)", ["not": ["anyOf": [["not": ["$ref": "#"]], ["type": "string"]]]], 1, selfReferenceRefusal),
        ("not not self", ["not": ["not": ["$ref": "#"]]], 1, selfReferenceRefusal),
        ("if self without then", ["if": ["$ref": "#"]], 1, selfReferenceRefusal),
        ("if self then false", ["if": ["$ref": "#"], "then": false], 1, selfReferenceRefusal),
        ("oneOf (self, true)", ["oneOf": [["$ref": "#"], true]], 1, selfReferenceRefusal),
        ("contains not self with maxContains", ["contains": ["not": ["$ref": "#/$defs/s"]], "maxContains": 0,
            "$defs": ["s": ["not": ["$ref": "#/$defs/s"]]]], [1], selfReferenceRefusal),
        ("mutual not", ["$defs": ["a": ["not": ["$ref": "#/$defs/b"]], "b": ["not": ["$ref": "#/$defs/a"]]], "$ref": "#/$defs/a"], 1, selfReferenceRefusal),
        ("anyOf to not", ["$defs": ["a": ["anyOf": [["$ref": "#/$defs/b"]]], "b": ["not": ["$ref": "#/$defs/a"]]], "$ref": "#/$defs/a"], 1, selfReferenceRefusal),
        ("dependentSchemas self", ["dependentSchemas": ["a": ["$ref": "#"]]], ["a": 1], selfReferenceRefusal),
        ("dependentSchemas not self", ["dependentSchemas": ["a": ["not": ["$ref": "#"]]]], ["a": 1], selfReferenceRefusal),
        ("self, with unrelated definitions", ["not": ["$ref": "#"], "$defs": ["u": true, "v": ["type": "string"], "w": false]], 1, selfReferenceRefusal),
        // The cut cannot change these outcomes.
        ("left recursion with a way out", ["anyOf": [["$ref": "#"], ["type": "string"]]], "s", nil),
        ("left recursion without", ["anyOf": [["$ref": "#"], ["type": "string"]]], 1, "does not match any of the allowed alternatives"),
        ("contains not self, minContains 0", ["contains": ["not": ["$ref": "#"]], "minContains": 0], [1], nil),
        ("propertyNames self", ["propertyNames": ["$ref": "#"]], ["a": 1], nil),
        ("anyOf with true first", ["anyOf": [true, ["not": ["$ref": "#"]]]], 1, nil),
    ]

    @Test func cutsUnderInvertingKeywordsDecideTheRun() throws {
        for (name, schema, instance, expected) in Self.cuts {
            let compiled = try JSONSchema(schema)
            let violation = compiled.validate(instance)
            #expect(violation?.reason == expected, "\(name): \(String(describing: violation))")
            if expected != nil, violation != nil, expected == Self.selfReferenceRefusal { #expect(violation?.path == [], "\(name)") }
            // Deterministic, and the same on every call.
            #expect(compiled.validate(instance)?.reason == expected, "\(name), second call")
        }
    }

    /// Recursive schemas that consume the instance are unaffected, at real depth and under the
    /// keywords that invert.
    @Test func recursiveSchemasStillValidateRealValues() throws {
        func list(_ depth: Int, last: JSONValue = nil) -> JSONValue {
            var value = last
            for _ in 0..<depth { value = ["v": 1, "next": value] }
            return value
        }
        let linked: JSONValue = [
            "anyOf": [["type": "null"], ["type": "object", "required": ["v"], "properties": ["v": ["type": "integer"], "next": ["$ref": "#"]]]],
        ]
        let schema = try JSONSchema(linked)
        #expect(schema.validate(list(120)) == nil)
        #expect(schema.validate(list(120, last: ["v": "x", "next": nil])) != nil)
        let notLinked = try JSONSchema(["not": linked])
        #expect(notLinked.validate(list(120))?.reason == "matches a schema it must not match")
        #expect(notLinked.validate(list(120, last: ["v": "x"])) == nil)
        let ifLinked = try JSONSchema(["if": linked, "then": true, "else": false])
        #expect(ifLinked.validate(list(120)) == nil)
        let oneOfLinked = try JSONSchema(["oneOf": [linked, ["type": "string"]]])
        #expect(oneOfLinked.validate(list(120)) == nil)
        let tree = try JSONSchema([
            "$defs": ["node": ["type": "object", "properties": ["kids": ["type": "array", "items": ["$ref": "#/$defs/node"]]]]],
            "not": ["not": ["$ref": "#/$defs/node"]],
        ])
        var value: JSONValue = [:]
        for _ in 0..<60 { value = ["kids": [value, [:]]] }
        #expect(tree.validate(value) == nil)
    }

    @Test(arguments: [
        ("%x", "#/$defs/%zzx"), ("a%", "#/$defs/a%2"), ("\u{F}", "#/$defs/%+F"), ("\u{0}", "#/$defs/%-0"),
        ("\u{FFFD}", "#/$defs/%FF"), ("a", "#/$defs/a%"), ("%", "#/$defs/%"), ("\u{E9}", "#/$defs/%C3"),
        ("\u{E9}", "#/$defs/%A9%C3"), ("a~2b", "#/$defs/a~2b"), ("a~", "#/$defs/a~"), ("~", "#/$defs/~"),
        ("a", "#/$defs/%61%"), ("\u{FFFD}", "#/$defs/%ED%A0%80"), ("/", "#/$defs/%C0%AF"),
    ])
    func malformedFragmentsAreRefused(definition: String, reference: String) {
        let schema: JSONValue = ["$defs": .object([definition: ["type": "string"]]), "$ref": .string(reference)]
        #expect(compileError(schema) != nil, "\(reference) resolved to \(definition.debugDescription)")
    }

    @Test(arguments: [
        ("\u{E9}", "#/$defs/%C3%A9"), ("\u{E9}", "#/$defs/%c3%a9"), ("😀", "#/$defs/%F0%9F%98%80"), ("a/b", "#/$defs/a%7E1b"),
        ("a/b", "#/$defs/a%7e1b"), ("a~b", "#/$defs/a~0b"), ("%", "#/$defs/%25"), ("a b", "#/$defs/a%20b"),
        ("~1", "#/$defs/~01"), ("\u{E9}", "#/$defs/\u{E9}"), ("", "#/$defs/"),
    ])
    func wellFormedFragmentsResolve(definition: String, reference: String) throws {
        let schema = try JSONSchema(["$defs": .object([definition: ["const": .string(definition)]]), "$ref": .string(reference)])
        #expect(schema.validate(.string(definition)) == nil, "\(reference)")
        #expect(schema.validate(.string(definition + "x")) != nil, "\(reference)")
    }
}


@Suite struct Round2DefinitionTests {
    @Test func unreferencedDefinitionsAreChecked() {
        for schema: JSONValue in [
            ["$defs": 5], ["definitions": "x"], ["$defs": ["a": 5]], ["$defs": ["a": ["type": "bogus"]]],
            ["definitions": ["a": ["pattern": "("]]], ["$defs": ["a": ["$defs": ["b": ["minLength": -1]]]]],
            ["properties": ["p": ["$defs": ["a": ["uniqueItems": 1]]]]], ["$defs": ["a": ["$ref": "#/nowhere"]]],
            ["$defs": ["a": ["$id": 1]]], ["then": 5], ["else": ["type": 1]], ["additionalItems": false],
            ["prefixItems": [true], "additionalItems": false],
        ] {
            #expect(compileError(schema) != nil, "\(schema)")
        }
        // Unused but well-formed, recursive, and nested definitions compile.
        for schema: JSONValue in [
            ["$defs": ["a": ["$ref": "#/$defs/b"], "b": ["$ref": "#/$defs/a"]]],
            ["$defs": ["a": ["$defs": ["b": ["$defs": ["c": true]]]]]],
            ["$defs": ["a": ["properties": ["x": ["$ref": "#/$defs/a"]]]]],
            ["$id": "https://example.com/s", "$defs": ["a": ["$id": "a.json"]]],
            ["then": true, "else": false],
            ["$schema": .string(draft7), "additionalItems": false],
        ] {
            #expect(compileError(schema) == nil, "\(schema)")
        }
    }

    @Test func unusedDefinitionsCountTowardTheSubschemaLimit() throws {
        var limits = JSONSchema.Limits()
        limits.maxSubschemas = 100
        func definitions(_ count: Int) -> JSONValue {
            var defs = JSONObject()
            for index in 0..<count { defs["d\(index)"] = true }
            return ["$defs": .object(defs)]
        }
        // The root is one node.
        #expect(compileError(definitions(99), limits) == nil)
        #expect(compileError(definitions(100), limits)?.reason == "more than 100 subschemas")
        // A definition referred to and compiled once is not counted twice.
        let shared: JSONValue = ["$defs": ["a": true], "properties": ["x": ["$ref": "#/$defs/a"], "y": ["$ref": "#/$defs/a"]]]
        limits.maxSubschemas = 4
        #expect(compileError(shared, limits) == nil)
        // An unused definition still limits depth.
        var deep: JSONValue = true
        for _ in 0..<40 { deep = ["not": deep] }
        #expect(compileError(["$defs": ["deep": deep]])?.reason == "schema nesting deeper than 32")
        // And the default limit leaves room for a large but ordinary set of definitions.
        #expect(compileError(definitions(5_000)) == nil)
    }

    @Test func countsBeyondIntMeanIntMax() throws {
        let long = JSONValue.string(String(repeating: "a", count: 10_000))
        #expect(try JSONSchema(["maxLength": number("1e400")]).validate(long) == nil)
        #expect(try JSONSchema(["minLength": number("99999999999999999999")]).validate(long) != nil)
        #expect(try JSONSchema(["minLength": number("1e400")]).validate("") != nil)
        #expect(try JSONSchema(["maxItems": number("1e30")]).validate([1, 2, 3]) == nil)
        #expect(try JSONSchema(["minProperties": number("1e19")]).validate(["a": 1]) != nil)
        #expect(try JSONSchema(["maxContains": number("1e19"), "contains": true]).validate([1, 1]) == nil)
        #expect(try JSONSchema(["minLength": number("2.0e0")]).validate("ab") == nil)
        for bad in ["-1e400", "1.5", "-0.5", "1e-400", "-99999999999999999999"] {
            #expect(compileError(["maxLength": number(bad)]) != nil, "\(bad)")
        }
        #expect(compileError(["maxLength": number("-0")]) == nil)
    }

    @Test func limitsAtTheirExtremesDoNotCrash() {
        var limits = JSONSchema.Limits()
        limits.maxEvaluations = -5
        limits.maxPatternSteps = -5
        limits.maxValidationRecursion = 0
        if let schema = try? JSONSchema(["pattern": "a"], limits: limits) { #expect(schema.validate("a") != nil) }
        limits = JSONSchema.Limits()
        limits.maxEvaluations = .max
        limits.maxPatternSteps = .max
        limits.maxPatternStates = .max
        limits.maxSubschemas = .max
        limits.maxDepth = .max
        limits.maxValidationRecursion = .max
        if let schema = try? JSONSchema(["pattern": "^a{1,5}$", "items": ["$ref": "#"]], limits: limits) {
            #expect(schema.validate("aaa") == nil)
            #expect(schema.validate([["aaaaaa"]]) != nil)
        } else {
            Issue.record("a schema with every limit at its maximum did not compile")
        }
        limits.maxPatternStates = 0
        #expect(compileError(["pattern": "a"], limits) != nil)
        limits.maxPatternStates = -1
        #expect(compileError(["pattern": "a"], limits) != nil)
        #expect(compileError(["pattern": ""], limits) != nil || compileError(["pattern": ""], limits) == nil)
    }
}


@Suite struct Round2PatternBudgetTests {
    static func limits(patternSteps: Int) -> JSONSchema.Limits {
        var limits = JSONSchema.Limits()
        limits.maxPatternSteps = patternSteps
        return limits
    }

    /// The pattern steps one non-matching string costs: the least budget it validates with
    /// under `not` (a non-match runs to the end of the string, so its cost is exact).
    static func cost(of pattern: String, on string: String) throws -> Int {
        var low = 0
        var high = 100_000_000
        while low < high {
            let middle = (low + high) / 2
            let schema = try JSONSchema(["not": ["pattern": .string(pattern)]], limits: limits(patternSteps: middle))
            if schema.validate(.string(string)) == nil { high = middle } else { low = middle + 1 }
        }
        return low
    }

    @Test func theBudgetCoversEveryMatchOfOneCall() throws {
        let pattern = "x{0,50}y"
        let string = String(repeating: "x", count: 200)
        let one = try Self.cost(of: pattern, on: string)
        #expect(one > 1_000)
        let limits = Self.limits(patternSteps: 10 * one)
        let schema = try JSONSchema(["items": ["not": ["pattern": .string(pattern)]]], limits: limits)
        let ten = JSONValue.array(Array(repeating: .string(string), count: 10))
        let eleven = JSONValue.array(Array(repeating: .string(string), count: 11))
        let message = "matching patterns against this value takes more than \(10 * one) steps"
        for _ in 0..<3 {
            #expect(schema.validate(ten) == nil)
            #expect(schema.validate(eleven)?.reason == message)
        }
        // Keys count too: patternProperties and propertyNames share the same budget.
        let keys = try JSONSchema(
            ["patternProperties": [pattern: true], "propertyNames": ["not": ["pattern": .string(pattern)]]], limits: limits)
        // Each key is matched twice (once for each keyword) and is one character longer than
        // `string`: four keys cost a little over 8 × `one`, five a little over 10 × `one`.
        var four = JSONObject()
        for index in 0..<4 { four[string + "\(index)"] = 0 }
        #expect(keys.validate(.object(four)) == nil)
        var five = four
        five[string + "4"] = 0
        #expect(keys.validate(.object(five))?.reason == message)
    }

    /// Cut short, a match would read as "no match"; under every keyword that can turn that
    /// into an answer, the run must be refused instead.
    @Test func theBudgetFailsClosedEverywhere() throws {
        let slow: JSONValue = ["pattern": "a{0,500}b"]
        let long = JSONValue.string(String(repeating: "a", count: 2_000))
        let cases: [(String, JSONValue, JSONValue)] = [
            ("pattern", slow, long),
            ("not", ["not": slow], long),
            ("not not", ["not": ["not": slow]], long),
            ("anyOf", ["anyOf": [slow, ["type": "number"]]], long),
            ("oneOf", ["oneOf": [slow, ["type": "string"]]], long),
            ("if", ["if": slow, "then": false], long),
            ("else", ["if": false, "else": slow], long),
            ("contains", ["contains": slow], [long]),
            ("contains with maxContains", ["contains": ["not": slow], "maxContains": 0], [long]),
            ("items", ["items": ["not": slow]], [long]),
            ("propertyNames", ["propertyNames": ["not": slow]], .object([String(repeating: "a", count: 2_000): 1])),
            ("patternProperties", ["patternProperties": ["a{0,500}b": false], "additionalProperties": true],
                .object([String(repeating: "a", count: 2_000): 1])),
            ("patternProperties then additionalProperties false", ["patternProperties": ["a{0,500}b": true], "additionalProperties": false],
                .object([String(repeating: "a", count: 2_000): 1])),
            ("not patternProperties", ["not": ["patternProperties": ["a{0,500}b": false]]], .object([String(repeating: "a", count: 2_000): 1])),
            ("dependentSchemas", ["dependentSchemas": ["k": ["not": ["properties": ["k": slow]]]]], ["k": long]),
        ]
        let limits = Self.limits(patternSteps: 50_000)
        for (name, schema, instance) in cases {
            let compiled = try JSONSchema(schema, limits: limits)
            let violation = compiled.validate(instance)
            #expect(violation?.reason == "matching patterns against this value takes more than 50000 steps", "\(name): \(String(describing: violation))")
            #expect(violation?.path == [], "\(name)")
        }
    }

    /// A budget of zero: a match found at the first position is still a correct answer;
    /// anything that needs a step more is refused, never "no match".
    @Test func aBudgetOfZero() throws {
        let limits = Self.limits(patternSteps: 0)
        #expect(try JSONSchema(["pattern": "a"], limits: limits).validate("b") != nil)
        #expect(try JSONSchema(["not": ["pattern": "a"]], limits: limits).validate("b")?.reason
            == "matching patterns against this value takes more than 0 steps")
        #expect(try JSONSchema(["type": "string"], limits: limits).validate("b") == nil)
    }

    /// One compiled schema used from many threads at once: each call has its own budget and
    /// working memory, so every answer equals the one given alone.
    @Test func oneSchemaFromManyThreads() async throws {
        let schema = try JSONSchema(
            [
                "type": "array",
                "items": [
                    "anyOf": [
                        ["type": "string", "pattern": "^(?:a|b)+c{0,40}$"],
                        ["type": "object", "patternProperties": ["^k\\d+$": ["type": "integer"]], "additionalProperties": false],
                    ]
                ],
            ], limits: Self.limits(patternSteps: 200_000))
        var instances: [JSONValue] = []
        for index in 0..<40 {
            let strings = (0..<(index * 7 % 50)).map { JSONValue.string(String(repeating: "ab", count: $0 % 30) + String(repeating: "c", count: $0 % 45)) }
            var object = JSONObject()
            for key in 0..<(index % 9) { object["k\(key)"] = key % 5 == 4 && index % 2 == 0 ? "x" : 1 }
            instances.append(.array(strings + [.object(object)]))
        }
        instances.append(.array(Array(repeating: .string(String(repeating: "a", count: 3_000)), count: 30)))
        let expected = instances.map { schema.validate($0)?.description }
        #expect(Set(expected.map { $0 == nil }).count == 2, "both valid and invalid instances")
        #expect(expected.contains { $0?.contains("matching patterns") == true })
        let asked = instances
        let mismatches = await withTaskGroup(of: Int.self) { group in
            for worker in 0..<16 {
                group.addTask {
                    var wrong = 0
                    for round in 0..<20 {
                        for (index, instance) in asked.enumerated() where (index + worker + round) % 3 != 0 {
                            if schema.validate(instance)?.description != expected[index] { wrong += 1 }
                        }
                    }
                    return wrong
                }
            }
            return await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }

    /// Ordinary arguments of the largest size a server accepts stay well inside the budget.
    @Test func largeOrdinaryArgumentsAreWithinThePatternBudget() throws {
        let cases: [(String, String)] = [
            ("[a-z0-9._%+-]{1,64}@[a-z0-9.-]{1,253}", "user.name@example.com"),
            ("^[a-z0-9._%+-]{1,64}@[a-z0-9.-]{1,253}\\.[a-z]{2,63}$", "user.name@example.com"),
            (#"^\d{4}-\d{2}-\d{2}$"#, "2026-11-17"),
            ("[A-Za-z0-9]{8,32}", "abcdefghABCDEFGH1234"),
        ]
        for (pattern, word) in cases {
            let schema = try JSONSchema(["items": ["pattern": .string(pattern)]])
            // About 4 MiB of JSON text.
            let count = (4 << 20) / (word.utf8.count + 3)
            #expect(schema.validate(.array(Array(repeating: .string(word), count: count))) == nil, "\(pattern)")
        }
        let text = String(repeating: "lorem ipsum dolor sit amet ", count: 38_000)
        #expect(try JSONSchema(["pattern": "^[^<>]*$"]).validate(.string(text)) == nil)
    }
}

// MARK: - J9

@Suite struct Round2EvaluationBudgetTests {
    static let hundredIntegers: JSONValue = .array(Array(repeating: 1, count: 100))

    static func limits(_ evaluations: Int) -> JSONSchema.Limits {
        var limits = JSONSchema.Limits()
        limits.maxEvaluations = evaluations
        return limits
    }

    /// Each schema's true answer is reached only after more than 20 steps; cut short, each
    /// composition keyword would read the cut as an answer and get it wrong (or right by luck).
    static let compositions: [(String, JSONValue)] = [
        ("top level", ["items": ["type": "integer"]]),
        ("not", ["not": ["items": ["type": "integer"]]]),
        ("not not", ["not": ["not": ["items": ["type": "integer"]]]]),
        ("anyOf", ["anyOf": [["items": ["type": "integer"]], ["type": "string"]]]),
        ("oneOf", ["oneOf": [["items": ["type": "integer"]], true]]),
        ("if/then", ["if": ["items": ["type": "integer"]], "then": false, "else": true]),
        ("if/else", ["if": ["items": ["type": "string"]], "then": true, "else": ["items": ["type": "integer"]]]),
        ("allOf", ["allOf": [true, ["items": ["type": "integer"]]]]),
        ("contains", ["contains": ["not": ["type": "integer"]], "minContains": 0]),
        ("dependentSchemas", ["dependentSchemas": ["a": ["not": ["properties": ["a": ["items": ["type": "integer"]]]]]]]),
    ]

    @Test func theBudgetFailsClosedUnderEveryComposition() throws {
        for (name, schema) in Self.compositions {
            let compiled = try JSONSchema(schema, limits: Self.limits(20))
            let instance: JSONValue = name == "dependentSchemas" ? ["a": Self.hundredIntegers] : Self.hundredIntegers
            let violation = compiled.validate(instance)
            #expect(violation?.reason == "checking this value takes more than 20 steps of the schema", "\(name): \(String(describing: violation))")
            #expect(violation?.path == [], "\(name)")
        }
    }

    @Test func theBudgetIsPerValidateCall() throws {
        let schema = try JSONSchema(["items": ["type": "integer"]], limits: Self.limits(150))
        for _ in 0..<5 { #expect(schema.validate(Self.hundredIntegers) == nil) }
        let large: JSONValue = .array(Array(repeating: 1, count: 149))
        #expect(schema.validate(large) == nil)
        let tooLarge: JSONValue = .array(Array(repeating: 1, count: 150))
        #expect(schema.validate(tooLarge)?.reason == "checking this value takes more than 150 steps of the schema")
        #expect(schema.validate(Self.hundredIntegers) == nil)
    }

    /// A chain of definitions where each `anyOf` repeats references to the next definition.
    @Test func exponentialSchemasAreCutOff() throws {
        var definitions = JSONObject()
        for level in 0..<7 {
            definitions["d\(level)"] =
                level == 6 ? ["type": "string"] : ["anyOf": .array(Array(repeating: ["$ref": .string("#/$defs/d\(level + 1)")], count: 20))]
        }
        let schemaValue: JSONValue = ["$defs": .object(definitions), "$ref": "#/$defs/d0"]
        #if DEBUG
        let limits = Self.limits(1_000_000)
        #else
        let limits = JSONSchema.Limits()
        #endif
        let schema = try JSONSchema(schemaValue, limits: limits)
        let clock = ContinuousClock()
        var violation: SchemaViolation?
        let elapsed = clock.measure { violation = schema.validate(1) }
        #expect(violation?.reason == "checking this value takes more than \(limits.maxEvaluations) steps of the schema")
        #expect(elapsed < .seconds(30))
        // The same schema on a string is answered at once: the first path succeeds.
        #expect(schema.validate("s") == nil)
    }

    /// A server parses at most a million values per message by default
    /// (`JSONParseOptions.maxNodes`); with ten million steps that is ten per value.
    @Test func largeOrdinaryInstancesAreWithinTheBudget() throws {
        let numbers: JSONValue = .array(Array(repeating: 0, count: 999_999))
        let schema = try JSONSchema(["type": "array", "items": ["type": "integer", "minimum": 0, "maximum": 9]])
        #expect(schema.validate(numbers) == nil)

        // About 1 MiB of objects (`{"id":123456,"name":"n","tags":["a"]}` is 37 bytes).
        let element: JSONValue = ["id": 123456, "name": "n", "tags": ["a"]]
        let objects: JSONValue = .array(Array(repeating: element, count: 28_000))
        let objectSchema = try JSONSchema([
            "type": "array",
            "items": [
                "type": "object", "required": ["id", "name"], "additionalProperties": false,
                "properties": [
                    "id": ["type": "integer", "minimum": 0], "name": ["type": "string", "minLength": 1],
                    "tags": ["type": "array", "items": ["type": "string"], "uniqueItems": true],
                ],
            ],
        ])
        #expect(objectSchema.validate(objects) == nil)
    }
}

extension String {
    fileprivate func leftPadded() -> String { count == 1 ? "0" + self : self }
}
