import LimbCore
import Testing

@Suite struct IndependentSchemaVocabularyContractTests {
    @Test
    func staticAnchorAppliesTheIdentifiedSubschemaAndRefSiblings() throws {
        // Core §§ 8.2.2 and 8.2.3.1.
        let schema = try JSONSchema([
            "$defs": ["label": ["$anchor": "label", "type": "string"]],
            "$ref": "#label",
            "minLength": 2,
        ])

        #expect(schema.validate("oak") == nil)
        #expect(schema.validate("a") != nil)
        #expect(schema.validate(2) != nil)
    }

    @Test
    func dynamicRefCanResolveAStaticAnchor() throws {
        // Core § 8.2.3.2.
        let schema = try JSONSchema([
            "$defs": ["count": ["$anchor": "count", "type": "integer"]],
            "$dynamicRef": "#count",
        ])

        #expect(schema.validate(2) == nil)
        #expect(schema.validate("two") != nil)
    }

    @Test
    func relativeReferencesUseTheContainingResourceBaseAndAnchor() throws {
        // Core §§ 8.2.1–8.2.3 and 9.3.
        let schema = try JSONSchema([
            "$id": "https://example.invalid/catalog/root.json",
            "$defs": [
                "rootEntry": ["$anchor": "entry", "type": "string"],
                "branch": [
                    "$id": "branches/panel.json",
                    "$defs": [
                        "panelEntry": ["$anchor": "entry", "type": "integer"],
                        "flag": ["$id": "types/flag.json", "type": "boolean"],
                    ],
                    "properties": [
                        "level": ["$ref": "#entry"],
                        "enabled": ["$ref": "types/flag.json"],
                    ],
                ],
            ],
            "properties": [
                "name": ["$ref": "#entry"],
                "panel": ["$ref": "branches/panel.json"],
            ],
        ])

        #expect(schema.validate(["name": "main", "panel": ["level": 2, "enabled": true]]) == nil)
        #expect(schema.validate(["name": 1, "panel": ["level": 2, "enabled": true]]) != nil)
        #expect(schema.validate(["name": "main", "panel": ["level": "low", "enabled": true]]) != nil)
        #expect(schema.validate(["name": "main", "panel": ["level": 2, "enabled": "yes"]]) != nil)
    }

    @Test
    func recursiveDescriptorUsesTheOutermostDynamicAnchor() throws {
        // Core §§ 7.1 and 8.2.3.2, and Appendix C.
        let schema = try JSONSchema([
            "$id": "https://example.invalid/descriptors/named.json",
            "$dynamicAnchor": "descriptor",
            "$ref": "descriptor.json",
            "required": ["name"],
            "$defs": [
                "base": [
                    "$id": "descriptor.json",
                    "$dynamicAnchor": "descriptor",
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "child": ["$dynamicRef": "#descriptor"],
                    ],
                ],
            ],
        ])

        #expect(schema.validate(["name": "root", "child": ["name": "leaf"]]) == nil)
        #expect(schema.validate(["name": "root", "child": [:]]) != nil)
        #expect(schema.validate(["name": "root", "child": ["name": 9]]) != nil)
    }

    @Test
    func unevaluatedPropertiesCollectsSuccessfulApplicatorAnnotations() throws {
        // Core §§ 8.2.3.1, 10.2.1.1–2, 10.2.2.4, and 11.3.
        let schema = try JSONSchema([
            "$defs": ["base": ["properties": ["name": ["type": "string"]]]],
            "$ref": "#/$defs/base",
            "allOf": [["properties": ["category": ["type": "string"]]]],
            "anyOf": [
                ["required": ["count"], "properties": ["count": ["type": "integer"]]],
                ["required": ["active"], "properties": ["active": ["type": "boolean"]]],
            ],
            "dependentSchemas": [
                "active": ["properties": ["mode": ["type": "string"]]],
            ],
            "unevaluatedProperties": false,
        ])

        #expect(schema.validate([
            "name": "oak", "category": "tree", "count": 3, "active": true, "mode": "manual",
        ]) == nil)
        #expect(schema.validate(["name": "oak", "count": 3]) == nil)
        #expect(schema.validate(["name": "oak", "count": 3, "mode": "manual"]) != nil)
        #expect(schema.validate(["name": "oak", "active": true, "count": "three"]) != nil)
    }

    @Test
    func failedAnyOfBranchDiscardsItsPropertyAnnotations() throws {
        // Core §§ 7.7.1.2, 10.2.1.2, and 11.3.
        let schema = try JSONSchema([
            "anyOf": [
                ["properties": ["name": ["type": "string"]]],
                [
                    "required": ["enabled"],
                    "properties": ["count": ["type": "integer"], "enabled": ["const": true]],
                ],
            ],
            "unevaluatedProperties": false,
        ])

        #expect(schema.validate(["name": "oak"]) == nil)
        #expect(schema.validate(["name": "oak", "count": 3, "enabled": true]) == nil)
        #expect(schema.validate(["name": "oak", "count": 3]) != nil)
    }

    @Test
    func unevaluatedItemsUsesPrefixAndContainsAnnotationsByIndex() throws {
        // Core §§ 10.3.1.1, 10.3.1.3, and 11.2.
        let schema = try JSONSchema([
            "allOf": [["prefixItems": [["type": "string"]]]],
            "contains": ["type": "integer"],
            "unevaluatedItems": ["type": "boolean"],
        ])

        #expect(schema.validate(["oak", 2, true, 4]) == nil)
        #expect(schema.validate(["oak", 2, "spruce", 4]) != nil)
        #expect(schema.validate(["oak", true]) != nil)
    }

    @Test
    func failedAnyOfBranchDiscardsItsItemAnnotations() throws {
        // Core §§ 7.7.1.2, 10.2.1.2, and 11.2.
        let schema = try JSONSchema([
            "anyOf": [
                ["prefixItems": [["type": "string"]]],
                ["prefixItems": [true, true], "minItems": 3, "items": ["type": "boolean"]],
            ],
            "unevaluatedItems": false,
        ])

        #expect(schema.validate(["oak"]) == nil)
        #expect(schema.validate(["oak", 2, true]) == nil)
        #expect(schema.validate(["oak", 2]) != nil)
    }

    @Test(arguments: [
        "https://example.invalid/cache/label.json",
        "https://example.invalid/schemas/label.json",
    ])
    func registeredResourceResolvesByRetrievalURIAndCanonicalID(reference: String) throws {
        // Core §§ 8.2.1, 9.1.1–2, and 9.2.
        let document: JSONValue = [
            "$id": "https://example.invalid/schemas/label.json",
            "type": "string",
        ]
        let schema: JSONValue = ["$ref": .string(reference)]
        let registeredSchemas = ["https://example.invalid/cache/label.json": document]

        let compiled = try JSONSchema(schema, registeredSchemas: registeredSchemas)
        #expect(compiled.validate("oak") == nil)
        #expect(compiled.validate(2) != nil)
        #expect(throws: JSONSchemaError.self) { try JSONSchema(schema, registeredSchemas: [:]) }
    }

    @Test func registeredMetaSchemaResolvesByRetrievalURIAndCanonicalID() throws {
        let retrieval = "https://registry.example.test/dialects/core-validation"
        let canonical = "https://schemas.example.test/dialects/core-validation"
        let registry: [String: JSONValue] = [retrieval: [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": .string(canonical),
            "$vocabulary": [
                "https://json-schema.org/draft/2020-12/vocab/core": true,
                "https://json-schema.org/draft/2020-12/vocab/validation": true,
            ],
            "type": ["object", "boolean"],
        ]]
        for uri in [retrieval, canonical, retrieval + "#", canonical + "#"] {
            let document: JSONValue = ["$schema": .string(uri), "type": "integer", "minimum": 2]
            let compiled = try JSONSchema(document, registeredSchemas: registry)
            #expect(compiled.validate(2) == nil)
            #expect(compiled.validate(1) != nil)
            #expect(compiled.validate("2") != nil)
        }
        let unknown: JSONValue = ["$schema": "https://registry.example.test/dialects/missing", "type": "integer", "minimum": 2]
        #expect(throws: JSONSchemaError.self) { try JSONSchema(unknown, registeredSchemas: registry) }
    }

    @Test func emptyFragmentSelectsTheDefaultMetaSchemaResource() throws {
        let schema = try JSONSchema(["$schema": "https://json-schema.org/draft/2020-12/schema#", "type": "integer"])
        #expect(schema.validate(2) == nil)
        #expect(schema.validate("2") != nil)
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema(["$schema": "https://json-schema.org/draft/2020-12/schema#unknown", "type": "integer"])
        }
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema(["$schema": "http://json-schema.org/draft-07/schema##", "type": "integer"])
        }
    }

    @Test
    func registeredMetaSchemaSelectsTheVocabulariesInUse() throws {
        // Core §§ 8.1.1–2 and 10.3.2.1.
        let metaSchemaURI = "https://example.invalid/dialects/applicator.json"
        let metaSchema: JSONValue = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": .string(metaSchemaURI),
            "$vocabulary": [
                "https://json-schema.org/draft/2020-12/vocab/core": true,
                "https://json-schema.org/draft/2020-12/vocab/applicator": true,
            ],
        ]
        let schema = try JSONSchema(
            [
                "$schema": .string(metaSchemaURI),
                "properties": ["blocked": false, "quantity": ["minimum": 5]],
            ],
            registeredSchemas: [metaSchemaURI: metaSchema]
        )

        #expect(schema.validate(["quantity": 2]) == nil)
        #expect(schema.validate(["quantity": 8]) == nil)
        #expect(schema.validate(["blocked": true, "quantity": 8]) != nil)
    }

    @Test func embeddedResourceChecksAnnotationsUsingItsOwnDialect() throws {
        let current: JSONValue = "https://json-schema.org/draft/2020-12/schema"
        let legacy: JSONValue = "http://json-schema.org/draft-07/schema#"
        func document(outer: JSONValue, embedded: JSONValue, deprecated: JSONValue) -> JSONValue {
            [
                "$schema": outer,
                "type": "object",
                "properties": ["value": [
                    "$id": "https://example.test/leaf",
                    "$schema": embedded,
                    "type": "string",
                    "deprecated": deprecated,
                ]],
            ]
        }
        let draft7 = try JSONSchema(document(outer: current, embedded: legacy, deprecated: "legacy"))
        #expect(draft7.validate(["value": "oak"]) == nil)
        #expect(draft7.validate(["value": 2]) != nil)

        let currentResource = try JSONSchema(document(outer: legacy, embedded: current, deprecated: true))
        #expect(currentResource.validate(["value": "oak"]) == nil)
        #expect(throws: JSONSchemaError.self) {
            try JSONSchema(document(outer: legacy, embedded: current, deprecated: "legacy"))
        }
    }

    @Test func optionalVocabularyNeedsANormalizedAbsoluteURI() throws {
        let uri = "https://example.test/project-meta"
        func registry(_ optionalVocabulary: String) -> [String: JSONValue] {
            let vocabularies: JSONObject = [
                "https://json-schema.org/draft/2020-12/vocab/core": true,
                optionalVocabulary: false,
            ]
            return [uri: [
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "$id": .string(uri),
                "$vocabulary": .object(vocabularies),
            ]]
        }
        let schema: JSONValue = ["$schema": .string(uri)]
        for valid in ["https://example.test/vocabulary", "https://example.test/Vocabulary%2FName"] {
            let compiled = try JSONSchema(schema, registeredSchemas: registry(valid))
            #expect(compiled.validate("oak") == nil)
        }
        for invalid in [
            "relative/vocabulary", "HTTPS://example.test/vocabulary", "https://EXAMPLE.test/vocabulary",
            "https://example.test/a/../vocabulary", "https://example.test/%76ocabulary", "https://example.test/Vocabulary%2fName",
        ] {
            #expect(throws: JSONSchemaError.self, "\(invalid)") {
                try JSONSchema(schema, registeredSchemas: registry(invalid))
            }
        }
    }

    @Test(arguments: [false, true])
    func unknownVocabularyIsRejectedOnlyWhenRequired(required: Bool) throws {
        // Core § 8.1.2.
        let metaSchemaURI = "https://example.invalid/dialects/quantity.json"
        let metaSchema: JSONValue = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": .string(metaSchemaURI),
            "$vocabulary": [
                "https://json-schema.org/draft/2020-12/vocab/core": true,
                "https://json-schema.org/draft/2020-12/vocab/validation": true,
                "https://example.invalid/vocab/catalog": .bool(required),
            ],
        ]
        let document: JSONValue = ["$schema": .string(metaSchemaURI), "minimum": 5]
        let registeredSchemas = [metaSchemaURI: metaSchema]

        if required {
            #expect(throws: JSONSchemaError.self) { try JSONSchema(document, registeredSchemas: registeredSchemas) }
        } else {
            let schema = try JSONSchema(document, registeredSchemas: registeredSchemas)
            #expect(schema.validate(8) == nil)
            #expect(schema.validate(2) != nil)
        }
    }
}
