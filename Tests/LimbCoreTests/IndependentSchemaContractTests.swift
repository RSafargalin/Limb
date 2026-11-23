import LimbCore
import Testing

@Suite struct IndependentSchemaContractTests {
    @Test(arguments: [false, true])
    func pointerKeepsDistinctUnicodeMemberNames(reverseDefinitions: Bool) throws {
        // RFC 6901 compares object member names without Unicode normalization.
        let composed = #""\u00e9": {"type": "string"}"#
        let decomposed = #""e\u0301": {"type": "integer"}"#
        let definitions = reverseDefinitions ? [decomposed, composed] : [composed, decomposed]
        let members = definitions.joined(separator: ", ")
        let schema = try compile("""
        {
            "$defs": { \(members) },
            "type": "object",
            "required": ["label", "count"],
            "properties": {
                "label": {"$ref": "#/$defs/%C3%A9"},
                "count": {"$ref": "#/$defs/e%CC%81"}
            }
        }
        """)

        try expectValidation(schema, #"{"label":"plant","count":2}"#, valid: true)
        try expectValidation(schema, #"{"count":2,"label":"plant"}"#, valid: true)
        try expectValidation(schema, #"{"label":2,"count":2}"#, valid: false)
        try expectValidation(schema, #"{"label":"plant","count":"plant"}"#, valid: false)
    }

    @Test func pointerDecodesSlashAndTildeInNestedTokens() throws {
        let schema = try compile("""
        {
            "$defs": {
                "a/b": {"$defs": {"c~1": {"type": "string"}}}
            },
            "$ref": "#/$defs/a~1b/$defs/c~01"
        }
        """)

        try expectValidation(schema, #""plant""#, valid: true)
        try expectValidation(schema, "2", valid: false)
    }

    @Test(arguments: ["#/$defs/a~1%CC%81", "#%2F$defs%2Fa~1%CC%81"])
    func pointerDecodesDelimitersAndEscapesBeforeACombiningMark(reference: String) throws {
        let schema = try compile("""
        {
            "$defs": {"a/\u{0301}": {"type": "string"}},
            "$ref": "\(reference)"
        }
        """)

        try expectValidation(schema, #""plant""#, valid: true)
        try expectValidation(schema, "2", valid: false)
    }

    @Test(arguments: ["#/$defs/%FF", "#/$defs/a~2"])
    func pointerRejectsMalformedUTF8AndTildeEscapes(reference: String) throws {
        // These names would resolve if decoding replaced invalid UTF-8 or left ~2 untouched.
        let schema = try JSON.parse("""
        {
            "$defs": {"\u{FFFD}": true, "a~2": true},
            "$ref": "\(reference)"
        }
        """)
        #expect(throws: JSONSchemaError.self) { try JSONSchema(schema) }
    }

    @Test(arguments: [
        "",
        #""$schema": "https://json-schema.org/draft/2020-12/schema","#,
        #""$schema": "http://json-schema.org/draft-07/schema#","#,
    ])
    func dialectControlsContainsBounds(declaration: String) throws {
        let schema = try compile("""
        {
            \(declaration)
            "type": "array",
            "contains": {"type": "integer"},
            "minContains": 2,
            "maxContains": 2
        }
        """)
        let isDraft7 = declaration.contains("draft-07")
        try expectValidation(schema, #"["plant", 1, 2]"#, valid: true)
        try expectValidation(schema, #"["plant"]"#, valid: false)
        try expectValidation(schema, #"["plant", 1]"#, valid: isDraft7)
        try expectValidation(schema, "[1, 2, 3]", valid: isDraft7)
    }

    @Test(arguments: ["[false]", "42"])
    func draft7UsesTupleItemsAndIgnoresPrefixItems(prefixItems: String) throws {
        let schema = try compile("""
        {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "array",
            "items": [{"type": "string"}, {"type": "integer"}],
            "additionalItems": false,
            "prefixItems": \(prefixItems)
        }
        """)

        try expectValidation(schema, #"["plant", 2]"#, valid: true)
        try expectValidation(schema, #"[2, "plant"]"#, valid: false)
        try expectValidation(schema, #"["plant", 2, null]"#, valid: false)
    }

    @Test(arguments: ["[false]", "42"])
    func draft7UsesSingleItemsSchemaAndIgnoresPrefixItems(prefixItems: String) throws {
        let schema = try compile("""
        {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "array",
            "items": {"type": "integer"},
            "prefixItems": \(prefixItems)
        }
        """)

        try expectValidation(schema, "[1, 2]", valid: true)
        try expectValidation(schema, #"[1, "plant"]"#, valid: false)
    }

    @Test func draft7SupportsBothFormsOfDependencies() throws {
        let schema = try compile("""
        {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "dependencies": {
                "label": ["count"],
                "count": {"properties": {"count": {"type": "integer"}}}
            }
        }
        """)

        try expectValidation(schema, "{}", valid: true)
        try expectValidation(schema, #"{"label":"plant","count":2}"#, valid: true)
        try expectValidation(schema, #"{"label":"plant"}"#, valid: false)
        try expectValidation(schema, #"{"count":"two"}"#, valid: false)
    }

    @Test(arguments: [
        "",
        #""$schema": "https://json-schema.org/draft/2020-12/schema","#,
    ])
    func modernDialectUsesDependentRequiredAndIgnoresLegacyDependencies(declaration: String) throws {
        let schema = try compile("""
        {
            \(declaration)
            "type": "object",
            "dependencies": {
                "label": ["legacyCount"],
                "legacyCount": false
            },
            "dependentRequired": {"label": ["count"]}
        }
        """)

        try expectValidation(schema, "{}", valid: true)
        try expectValidation(schema, #"{"label":"plant","count":2}"#, valid: true)
        try expectValidation(schema, #"{"legacyCount":2}"#, valid: true)
        try expectValidation(schema, #"{"label":"plant","legacyCount":2}"#, valid: false)
    }

    @Test func defaultDialectUsesPrefixItemsAndItems() throws {
        let schema = try compile("""
        {
            "type": "array",
            "prefixItems": [{"type": "string"}, {"type": "integer"}],
            "items": false
        }
        """)

        try expectValidation(schema, #"["plant", 2]"#, valid: true)
        try expectValidation(schema, #"[2, "plant"]"#, valid: false)
        try expectValidation(schema, #"["plant", 2, null]"#, valid: false)
    }

    @Test(arguments: [
        #""title": 42"#,
        #""description": false"#,
        #""$comment": []"#,
        #""examples": "plant""#,
        #""readOnly": "true""#,
        #""writeOnly": null"#,
    ], [
        "",
        #""$schema": "http://json-schema.org/draft-07/schema#","#,
    ])
    func activeDialectRejectsMalformedMetadata(member: String, declaration: String) throws {
        let value = try JSON.parse("{ \(declaration) \"type\": \"string\", \(member) }")
        #expect(throws: JSONSchemaError.self) { try JSONSchema(value) }
    }

    @Test func deprecatedHasATypeOnlyInTheModernDialect() throws {
        let value = try JSON.parse(#"{"type":"string","deprecated":"true"}"#)
        #expect(throws: JSONSchemaError.self) { try JSONSchema(value) }

        let draft7 = try compile("""
        {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "string",
            "deprecated": "true"
        }
        """)
        try expectValidation(draft7, #""plant""#, valid: true)
        try expectValidation(draft7, "2", valid: false)
    }

    @Test func validMetadataAndCustomAnnotationsLeaveAssertionsIntact() throws {
        let schema = try compile("""
        {
            "$comment": "Internal documentation",
            "type": "string",
            "title": "Label",
            "description": "A plant label",
            "default": 42,
            "examples": [null, "succulent"],
            "deprecated": true,
            "readOnly": true,
            "writeOnly": false,
            "x-display": {"widget": "text"}
        }
        """)

        try expectValidation(schema, #""plant""#, valid: true)
        try expectValidation(schema, "42", valid: false)
        try expectValidation(schema, "null", valid: false)
    }

    @Test func requiredMustContainUniqueNames() throws {
        let duplicated = try JSON.parse(#"{"type":"object","required":["label","label"]}"#)
        #expect(throws: JSONSchemaError.self) { try JSONSchema(duplicated) }

        let distinct = try compile(#"{"type":"object","required":["label","count"]}"#)
        try expectValidation(distinct, #"{"label":"plant","count":2}"#, valid: true)
        try expectValidation(distinct, #"{"label":"plant"}"#, valid: false)
    }

    private func compile(_ text: String) throws -> JSONSchema {
        try JSONSchema(JSON.parse(text))
    }

    private func expectValidation(
        _ schema: JSONSchema,
        _ text: String,
        valid: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let value = try JSON.parse(text)
        let violation = schema.validate(value)
        #expect((violation == nil) == valid, "Input: \(text)", sourceLocation: sourceLocation)
    }
}
