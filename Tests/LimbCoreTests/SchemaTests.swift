import Testing
import LimbCore

@Suite struct JSONSchemaTests {
    func violation(_ schema: JSONValue, _ instance: JSONValue) throws -> String? {
        try JSONSchema(schema).validate(instance)?.description
    }

    @Test func typesAndRequired() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["name": ["type": "string"], "age": ["type": "integer", "minimum": 0]],
            "required": ["name"],
            "additionalProperties": false,
        ]
        #expect(try violation(schema, ["name": "Ada", "age": 36]) == nil)
        #expect(try violation(schema, ["name": "Ada", "age": 36.0]) == nil)
        #expect(try violation(schema, ["age": 1]) == "name: missing required field")
        #expect(try violation(schema, ["name": 5]) == "name: expected string, got integer")
        // The bound is quoted as the schema writes it: `0` (an integer literal), not "0.0".
        #expect(try violation(schema, ["name": "Ada", "age": -1]) == "age: must be at least 0")
        #expect(try violation(schema, ["name": "Ada", "age": 1.5]) == "age: expected integer, got number")
        #expect(try violation(schema, ["name": "Ada", "extra": true]) == "extra: unknown field")
        #expect(try violation(schema, [1]) == "expected object, got array")
    }

    @Test func nestedPathsNameTheField() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["items": ["type": "array", "items": ["type": "object", "required": ["id"]]]],
        ]
        #expect(try violation(schema, ["items": [["id": 1], [:]]]) == "items.[1].id: missing required field")
    }

    @Test func stringsNumbersArrays() throws {
        #expect(try violation(["type": "string", "minLength": 2, "maxLength": 3], "é中") == nil)
        #expect(try violation(["maxLength": 1], "😀😀") != nil)
        #expect(try violation(["pattern": "^[a-z]+$"], "abc") == nil)
        #expect(try violation(["pattern": "^[a-z]+$"], "ab1") != nil)
        #expect(try violation(["enum": ["a", "b", 1]], 1.0) == nil)
        #expect(try violation(["enum": ["a", "b"]], "c") == "must be one of: \"a\", \"b\"")
        #expect(try violation(["const": ["x": [1, 2]]], ["x": [1, 2.0]]) == nil)
        #expect(try violation(["multipleOf": 0.01], 0.07) == nil)
        #expect(try violation(["multipleOf": 3], 10) != nil)
        #expect(try violation(["exclusiveMinimum": 0, "exclusiveMaximum": 1], 0) != nil)
        #expect(try violation(["uniqueItems": true], [1, 2, 1.0]) != nil)
        #expect(try violation(["minItems": 1, "maxItems": 2], []) != nil)
        #expect(try violation(["prefixItems": [["type": "string"]], "items": ["type": "integer"]], ["a", 1, 2]) == nil)
        #expect(try violation(["prefixItems": [["type": "string"]], "items": false], ["a", 1]) != nil)
        #expect(try violation(["contains": ["type": "integer"], "minContains": 2], [1, "a", 2]) == nil)
        #expect(try violation(["contains": ["type": "integer"]], ["a"]) != nil)
    }

    @Test func composition() throws {
        let schema: JSONValue = [
            "oneOf": [["type": "string"], ["type": "integer"]],
            "not": ["const": "forbidden"],
        ]
        #expect(try violation(schema, "ok") == nil)
        #expect(try violation(schema, 5) == nil)
        #expect(try violation(schema, true) != nil)
        #expect(try violation(schema, "forbidden") != nil)
        #expect(try violation(["anyOf": [["minimum": 5], ["type": "string"]]], 3) != nil)
        #expect(try violation(["allOf": [["minimum": 5], ["maximum": 9]]], 7) == nil)
        let conditional: JSONValue = [
            "if": ["properties": ["kind": ["const": "a"]]], "then": ["required": ["x"]], "else": ["required": ["y"]],
        ]
        #expect(try violation(conditional, ["kind": "a", "x": 1]) == nil)
        #expect(try violation(conditional, ["kind": "a"]) != nil)
        #expect(try violation(conditional, ["kind": "b", "y": 1]) == nil)
        #expect(try violation(["dependentRequired": ["card": ["cvv"]]], ["card": "1"]) != nil)
    }

    @Test func localReferencesAndRecursion() throws {
        let tree: JSONValue = [
            "$defs": ["node": ["type": "object", "properties": ["children": ["type": "array", "items": ["$ref": "#/$defs/node"]]], "required": ["id"]]],
            "$ref": "#/$defs/node",
        ]
        #expect(try violation(tree, ["id": 1, "children": [["id": 2, "children": []]]]) == nil)
        #expect(try violation(tree, ["id": 1, "children": [["children": []]]]) == "children.[0].id: missing required field")
        // A schema that refers to itself without consuming input must not loop forever.
        #expect(try violation(["$ref": "#"], 1) == "the schema refers to itself without consuming input")
        #expect(try violation(["$defs": ["a": ["allOf": [["$ref": "#/$defs/b"]]], "b": ["anyOf": [["$ref": "#/$defs/a"]]]], "$ref": "#/$defs/a"], 1) != nil)
        // Deep input is validated like any other: when the stack this runs on is too short for
        // it, the validator starts over on a larger one instead of refusing.
        let nested: JSONValue = ["items": ["$ref": "#"]]
        var shallow: JSONValue = []
        for _ in 0..<20 { shallow = [shallow] }
        #expect(try violation(nested, shallow) == nil)
        var deep: JSONValue = []
        for _ in 0..<120 { deep = [deep] }
        #expect(try violation(nested, deep) == nil)
        var spoiled: JSONValue = "not an array"
        for _ in 0..<120 { spoiled = [spoiled] }
        #expect(try violation(["type": "array", "items": ["$ref": "#"]], spoiled)?.hasSuffix("expected array, got string") == true)
        // What is refused is recursion beyond the validator's own limit, on any stack.
        var limits = JSONSchema.Limits()
        #expect(limits.maxValidationRecursion == 4096)
        limits.maxValidationRecursion = 50
        #expect(try JSONSchema(nested, limits: limits).validate(deep)?.reason == "nested deeper than the validator allows")
        #expect(try JSONSchema(nested, limits: limits).validate(shallow) == nil)
        #expect(try violation(["$defs": ["a/b": ["type": "string"], "p%q": ["type": "integer"]], "properties": ["x": ["$ref": "#/$defs/a~1b"], "y": ["$ref": "#/$defs/p%25q"]]], ["x": "s", "y": 1]) == nil)
    }

    @Test func draft07Spellings() throws {
        let schema: JSONValue = [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "definitions": ["positive": ["type": "integer", "minimum": 1]],
            "type": "object",
            "properties": ["count": ["$ref": "#/definitions/positive", "maximum": 0]],
            "dependencies": ["a": ["b"]],
            "items": [["type": "string"]],
        ]
        // In draft-07 `$ref` replaces its siblings, so the contradictory `maximum` is ignored.
        #expect(try violation(schema, ["count": 3]) == nil)
        #expect(try violation(schema, ["count": 0]) != nil)
        #expect(try violation(schema, ["a": 1]) != nil)
    }

    /// A failed `const` or `enum` quotes the schema's constant when it is shallow and only names
    /// it when it is nested more than eight levels: writing a value out recurses once per level,
    /// and a message is built on whatever stack is left.
    @Test func constantsInMessagesAreWrittenOnlyWhenShallow() throws {
        func nested(_ depth: Int, objects: Bool = false, core: JSONValue = 1) -> JSONValue {
            var value = core
            for _ in 0..<depth { value = objects ? .object(["a": value]) : .array([value]) }
            return value
        }
        // Shallow constants are written as before.
        #expect(try violation(["const": 5], 7) == "must be 5")
        #expect(try violation(["const": "x"], 7) == "must be \"x\"")
        #expect(try violation(["const": nil], 7) == "must be null")
        #expect(try violation(["const": ["a": [1, 2], "b": "c"]], 7) == #"must be {"a":[1,2],"b":"c"}"#)
        #expect(try violation(["const": []], 7) == "must be []")
        #expect(try violation(["const": nested(8)], 7) == "must be [[[[[[[[1]]]]]]]]")
        #expect(try violation(["const": nested(8, objects: true)], 7) == #"must be {"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":1}}}}}}}}"#)
        #expect(try violation(["const": nested(7, core: [])], 7) == "must be [[[[[[[[]]]]]]]]")
        // One level more and the constant is named instead.
        #expect(try violation(["const": nested(9)], 7) == "must be a value nested 9 levels deep")
        #expect(try violation(["const": nested(9, objects: true)], 7) == "must be a value nested 9 levels deep")
        #expect(try violation(["const": nested(8, core: [:])], 7) == "must be a value nested 9 levels deep")
        #expect(try violation(["const": nested(256, objects: true)], "x") == "must be a value nested 256 levels deep")
        // The deepest branch decides, wherever it is.
        #expect(try violation(["const": ["shallow": 1, "list": [1, 2, nested(8)], "z": nil]], 7) == "must be a value nested 10 levels deep")
        // The instance plays no part in the message, deep or not.
        #expect(try violation(["const": 5], nested(40)) == "must be 5")
        #expect(try violation(["const": nested(9)], nested(9, core: 2)) == "must be a value nested 9 levels deep")
        #expect(try violation(["const": nested(8)], nested(8, core: 2)) == "must be [[[[[[[[1]]]]]]]]")
        #expect(try violation(["const": nested(9)], nested(9)) == nil)

        // `enum`: each alternative on its own terms, the first twelve of them.
        #expect(try violation(["enum": [1, "x", [1], ["a": nil]]], 7) == #"must be one of: 1, "x", [1], {"a":null}"#)
        #expect(
            try violation(["enum": [1, nested(8), nested(9), "x", nested(200, objects: true), nested(3)]], 7)
                == #"must be one of: 1, [[[[[[[[1]]]]]]]], a value nested 9 levels deep, "x", a value nested 200 levels deep, [[[1]]]"#)
        let many = JSONValue.array((0..<20).map { nested(9 + $0, core: JSONValue($0)) })
        #expect(
            try violation(["enum": many], 7)
                == "must be one of: " + (0..<12).map { "a value nested \(9 + $0) levels deep" }.joined(separator: ", "))
        #expect(try violation(["enum": .array((0..<20).map { JSONValue($0) })], 99) == "must be one of: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11")
        #expect(try violation(["enum": many], nested(20, core: 11)) == nil)
        // Nested in a property, the path is added in front as for any other violation.
        #expect(try violation(["properties": ["k": ["const": nested(12)]]], ["k": 1]) == "k: must be a value nested 12 levels deep")
    }

    @Test func refusesWhatItCannotEnforce() {
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["$ref": "https://example.com/schema.json"]) }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["unevaluatedProperties": "invalid"]) }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["$dynamicRef": "#x"]) }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["$schema": "https://json-schema.org/draft/2019-09/schema"]) }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["type": "strnig"]) }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["pattern": "("]) }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["$ref": "#/$defs/missing"]) }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(5) }
        var deep: JSONValue = ["type": "string"]
        for _ in 0..<40 { deep = ["items": deep] }
        #expect(throws: JSONSchemaError.self) { try JSONSchema(deep) }
    }
}

@Suite struct ExactStringTests {
    @Test func canonicallyEquivalentStringsAreDifferentJSON() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)  // Swift's view
        #expect(JSONValue.string(composed) != JSONValue.string(decomposed))  // JSON's view
        let object = try JSON.parse("{\"\(composed)\":1,\"\(decomposed)\":2}")
        #expect(object.objectValue?.count == 2)
        #expect(object[composed] == 1)
        #expect(object[decomposed] == 2)
        #expect(try JSONSchema(["const": .string(composed)]).validate(.string(decomposed)) != nil)
        // Many keys take the hashed path, which must stay exact too.
        let members = (0..<40).map { "\"k\($0)\":0" } + ["\"\(composed)\":1", "\"\(decomposed)\":2"]
        #expect(try JSON.parse("{" + members.joined(separator: ",") + "}").objectValue?.count == 42)
    }

    @Test func duplicateKeysCanBeAllowed() throws {
        let value = try JSON.parse(#"{"a":1,"b":2,"a":3}"#, options: JSONParseOptions(rejectDuplicateKeys: false))
        #if !FoundationJSON
        #expect(value == ["a": 3, "b": 2])
        #else
        // Which duplicate wins is Foundation's choice, not the last one by contract.
        #expect(value.objectValue?.count == 2)
        #expect(value["a"] == 1 || value["a"] == 3)
        #expect(value["b"] == 2)
        // The option changes nothing in this build: the same text is accepted with it on.
        #expect(try JSON.parse(#"{"a":1,"b":2,"a":3}"#) == value)
        #endif
    }
}

@Suite struct LineFramerTests {
    func frames(_ framer: inout LineFramer) -> [String] {
        var result: [String] = []
        while let event = framer.next() {
            switch event {
            case .frame(let range): result.append(String(decoding: framer.buffer[range], as: UTF8.self))
            case .oversized: result.append("<oversized>")
            }
        }
        return result
    }

    @Test func splitsAcrossArbitraryChunks() {
        let stream = Array("{\"a\":1}\n\r\n{\"b\":2}\r\n\n{\"c\":3}\n{\"partial\"".utf8)
        for chunkSize in [1, 2, 3, 7, 64] {
            var framer = LineFramer(maxFrameBytes: 1024)
            var collected: [String] = []
            var offset = 0
            while offset < stream.count {
                var chunk = stream[offset..<min(offset + chunkSize, stream.count)]
                while !chunk.isEmpty {
                    chunk = chunk.dropFirst(framer.append(chunk))
                    collected += frames(&framer)
                }
                offset += chunkSize
            }
            #expect(collected == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"], "chunk \(chunkSize)")
            #expect(framer.hasPartialFrame)
        }
    }

    @Test func oversizedFramesAreDroppedAndTheStreamResynchronizes() {
        var stream = Array("ok1\n".utf8)
        stream.append(contentsOf: repeatElement(UInt8(0x61), count: 50_000))
        stream.append(contentsOf: "\nok2\n".utf8)
        stream.append(contentsOf: repeatElement(UInt8(0x62), count: 4097))
        stream.append(contentsOf: "\nok3\n".utf8)
        stream.append(contentsOf: repeatElement(UInt8(0x63), count: 4096))
        stream.append(0x0A)

        for chunkSize in [5, 4096, 100_000] {
            var framer = LineFramer(maxFrameBytes: 4096)
            var collected: [String] = []
            var offset = 0
            while offset < stream.count {
                var chunk = stream[offset..<min(offset + chunkSize, stream.count)]
                while !chunk.isEmpty {
                    chunk = chunk.dropFirst(framer.append(chunk))
                    collected += frames(&framer)
                }
                offset += chunkSize
            }
            #expect(collected.count == 6, "chunk \(chunkSize)")
            #expect(collected.prefix(5) == ["ok1", "<oversized>", "ok2", "<oversized>", "ok3"], "chunk \(chunkSize)")
            #expect(collected.last?.utf8.count == 4096, "chunk \(chunkSize)")
        }
    }
}

@Suite struct Base64Tests {
    @Test func roundTrips() {
        for length in 0..<70 {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
            #expect(Base64.decode(Base64.encode(bytes)) == bytes)
            #expect(Base64.decode(Base64.encode(bytes, urlSafe: true)) == bytes)
        }
        #expect(Base64.encode(Array("hello".utf8)) == "aGVsbG8=")
        #expect(Base64.decode("aGVsbG8") == Array("hello".utf8))
        #expect(Base64.decode("a$b") == nil)
    }
}
