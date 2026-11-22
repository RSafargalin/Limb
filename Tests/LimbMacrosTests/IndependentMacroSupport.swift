import Limb
import LimbMacros
import LimbTesting
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

// Shared helpers for the independent macro tests. Everything here is named `IndependentMacro…`
// so that it cannot collide with the fixtures of the tests written by the macros' author.

/// One diagnostic a macro produced, with where it points in the original source.
struct IndependentMacroDiagnostic: CustomStringConvertible {
    var message: String
    var severity: DiagnosticSeverity
    /// 1-based, in the source handed to `IndependentMacroExpansion`.
    var line: Int
    var column: Int
    var description: String { "\(line):\(column): \(severity): \(message)" }
}

/// Runs `@Tool` and `@Schema` over a source text the way the compiler would, without compiling
/// the result. Diagnostics are collected instead of asserted, so a test can state what it
/// expects about them (count, severity, location, wording) independently.
struct IndependentMacroExpansion {
    var source: String
    var expanded: String
    var diagnostics: [IndependentMacroDiagnostic]

    static let specs: [String: MacroSpec] = [
        "Tool": MacroSpec(type: ToolMacro.self, conformances: [TypeSyntax(IdentifierTypeSyntax(name: .identifier("MCPTool")))]),
        "Schema": MacroSpec(
            type: SchemaMacro.self, conformances: [TypeSyntax(IdentifierTypeSyntax(name: .identifier("SchemaRepresentable")))]),
    ]

    init(_ source: String) {
        self.source = source
        let tree = Parser.parse(source: source)
        let context = BasicMacroExpansionContext(
            sourceFiles: [tree: .init(moduleName: "TestModule", fullFilePath: "test.swift")])
        let result = tree.expand(
            macroSpecs: Self.specs,
            contextGenerator: { BasicMacroExpansionContext(sharingWith: context, lexicalContext: $0.allMacroLexicalContexts()) },
            indentationWidth: .spaces(4))
        expanded = result.description
        diagnostics = context.diagnostics.map { diagnostic in
            let location = context.location(for: diagnostic.position, anchoredAt: diagnostic.node, fileName: "test.swift")
            return IndependentMacroDiagnostic(
                message: diagnostic.message, severity: diagnostic.diagMessage.severity, line: location.line,
                column: location.column)
        }
    }

    var errors: [IndependentMacroDiagnostic] { diagnostics.filter { $0.severity == .error } }
    var warnings: [IndependentMacroDiagnostic] { diagnostics.filter { $0.severity == .warning } }

    /// Whether the expansion produced a conformance extension.
    var producedExtension: Bool { expanded.contains("extension ") }

    /// Whether anything at all was generated: one of the names that generated code is made of
    /// appears in the expansion without having been in the source.
    var producedCode: Bool {
        ["MCPTool", "SchemaRepresentable", "ToolDefinition", "SchemaSupport", "jsonSchema", "__limb", "extension "].contains {
            expanded.contains($0) && !source.contains($0)
        }
    }
}

/// Position (1-based line and column) of the first occurrence of `needle` in `source`.
func IndependentMacroPosition(of needle: String, in source: String) -> (line: Int, column: Int)? {
    let haystack = Array(source.utf8)
    let pattern = Array(needle.utf8)
    guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }
    for start in 0...(haystack.count - pattern.count) where haystack[start..<(start + pattern.count)].elementsEqual(pattern) {
        let before = haystack[..<start]
        let line = before.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        let lineStart = before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        return (line, start - lineStart + 1)
    }
    return nil
}

/// Asserts the full expansion of `source`. Failures go to Swift Testing (the XCTest-based
/// `assertMacroExpansion` would be silent under Swift Testing).
func IndependentMacroAssertExpansion(
    _ source: String, expands expected: String, diagnostics: [DiagnosticSpec] = [],
    fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column
) {
    assertMacroExpansion(
        source, expandedSource: expected, diagnostics: diagnostics, macroSpecs: IndependentMacroExpansion.specs,
        indentationWidth: .spaces(4),
        failureHandler: { failure in
            Issue.record(
                Comment(rawValue: failure.message),
                sourceLocation: Testing.SourceLocation(
                    fileID: String(describing: failure.location.fileID), filePath: String(describing: failure.location.filePath),
                    line: Int(failure.location.line), column: Int(failure.location.column)))
        },
        fileID: fileID, filePath: filePath, line: line, column: column)
}

/// Checks that `schema` is a schema Limb's validator compiles, and that it only uses the
/// JSON Schema 2020-12 vocabulary the macros are expected to emit, with well-formed values:
/// `$defs` only at the root of the document, and every `$ref` pointing at one of them.
/// Returns the compiled schema, or `nil` after recording an issue.
@discardableResult
func IndependentMacroCheckSchema(
    _ schema: JSONObject, sourceLocation: Testing.SourceLocation = #_sourceLocation
) -> JSONSchema? {
    let definitions = schema["$defs"]?.objectValue
    func walk(_ value: JSONValue, at pointer: String) {
        guard let object = value.objectValue else {
            Issue.record("schema at \(pointer) is not an object: \(value)", sourceLocation: sourceLocation)
            return
        }
        for (key, member) in object {
            switch key {
            case "type":
                let known: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
                if let name = member.stringValue {
                    #expect(known.contains(name), "unknown type \(name) at \(pointer)", sourceLocation: sourceLocation)
                } else if let names = member.arrayValue {
                    #expect(names.allSatisfy { $0.stringValue.map(known.contains) == true }, "bad type list at \(pointer)", sourceLocation: sourceLocation)
                } else {
                    Issue.record("\"type\" at \(pointer) is neither a string nor an array", sourceLocation: sourceLocation)
                }
            case "description", "title":
                #expect(member.stringValue != nil, "\(key) at \(pointer) must be a string", sourceLocation: sourceLocation)
            case "properties":
                guard let properties = member.objectValue else {
                    Issue.record("\"properties\" at \(pointer) must be an object", sourceLocation: sourceLocation)
                    continue
                }
                for (name, property) in properties { walk(property, at: "\(pointer)/properties/\(name)") }
            case "required":
                guard let names = member.arrayValue else {
                    Issue.record("\"required\" at \(pointer) must be an array", sourceLocation: sourceLocation)
                    continue
                }
                let strings = names.compactMap(\.stringValue)
                #expect(strings.count == names.count, "\"required\" at \(pointer) must hold strings", sourceLocation: sourceLocation)
                #expect(Set(strings).count == strings.count, "\"required\" at \(pointer) must hold unique names", sourceLocation: sourceLocation)
                let declared = Set(object["properties"]?.objectValue?.map(\.key) ?? [])
                #expect(
                    strings.allSatisfy(declared.contains), "\"required\" at \(pointer) names an undeclared property: \(strings)",
                    sourceLocation: sourceLocation)
            case "items", "additionalProperties":
                if member.boolValue == nil { walk(member, at: "\(pointer)/\(key)") }
            case "enum":
                #expect(member.arrayValue != nil, "\"enum\" at \(pointer) must be an array", sourceLocation: sourceLocation)
            case "anyOf", "oneOf", "allOf":
                guard let branches = member.arrayValue, !branches.isEmpty else {
                    Issue.record("\"\(key)\" at \(pointer) must be a non-empty array", sourceLocation: sourceLocation)
                    continue
                }
                for (index, branch) in branches.enumerated() { walk(branch, at: "\(pointer)/\(key)/\(index)") }
            case "$ref":
                guard let target = member.stringValue, target.hasPrefix("#/$defs/") else {
                    Issue.record("\"$ref\" at \(pointer) is not a reference to a local definition: \(member)", sourceLocation: sourceLocation)
                    continue
                }
                let name = String(target.dropFirst("#/$defs/".count))
                #expect(definitions?[name] != nil, "\"$ref\" at \(pointer) points at a definition that does not exist: \(target)", sourceLocation: sourceLocation)
                #expect(
                    !name.contains("/") && !name.contains("~") && !name.contains("%") && !name.contains("#") && !name.contains(" "),
                    "definition name needs escaping in a JSON pointer: \(name)", sourceLocation: sourceLocation)
            case "$defs":
                #expect(pointer == "#", "\"$defs\" below the root at \(pointer): references are resolved against the root", sourceLocation: sourceLocation)
                guard let entries = member.objectValue else {
                    Issue.record("\"$defs\" at \(pointer) must be an object", sourceLocation: sourceLocation)
                    continue
                }
                for (name, definition) in entries { walk(definition, at: "\(pointer)/$defs/\(name)") }
            case "const", "default", "minimum", "maximum", "format":
                break
            default:
                Issue.record("unexpected schema keyword \"\(key)\" at \(pointer)", sourceLocation: sourceLocation)
            }
        }
    }
    walk(.object(schema), at: "#")
    do {
        return try JSONSchema(.object(schema))
    } catch {
        Issue.record("the schema does not compile: \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// The three properties every `@Schema` value must have: its encoding satisfies its own schema,
/// decoding the encoding gives the value back, and encoding is stable.
func IndependentMacroCheckRoundTrip<T: SchemaRepresentable & Equatable>(
    _ value: T, sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let schema = IndependentMacroCheckSchema(T.jsonSchema, sourceLocation: sourceLocation) else { return }
    let encoded = value.jsonValue
    let violation = schema.validate(encoded)
    #expect(violation == nil, "encoding of \(value) violates the type's own schema: \(encoded)", sourceLocation: sourceLocation)
    do {
        let decoded = try T(json: encoded)
        #expect(decoded == value, "decode(encode(x)) != x for \(encoded)", sourceLocation: sourceLocation)
        #expect(decoded.jsonValue == encoded, sourceLocation: sourceLocation)
    } catch {
        Issue.record("the type cannot decode its own encoding \(encoded): \(error)", sourceLocation: sourceLocation)
    }
    // The same through bytes, as it travels on the wire.
    do {
        let reparsed = try JSON.parse(encoded.encoded())
        #expect(try T(json: reparsed) == value, "round trip through bytes lost data: \(encoded)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("round trip through bytes failed for \(encoded): \(error)", sourceLocation: sourceLocation)
    }
}

/// The decoding error for `json`, or `nil` (with an issue recorded) if decoding succeeded.
func IndependentMacroDecodingError<T: JSONDecodable>(
    _ type: T.Type, _ json: JSONValue, sourceLocation: Testing.SourceLocation = #_sourceLocation
) -> JSONDecodingError? {
    do {
        let value = try T(json: json)
        Issue.record("expected a decoding error for \(json), got \(value)", sourceLocation: sourceLocation)
        return nil
    } catch {
        return error
    }
}

/// A deterministic generator for property-style tests (SplitMix64).
struct IndependentMacroRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func string() -> String {
        let alphabet: [String] = [
            "a", "Z", "0", " ", "\"", "\\", "/", "\n", "\t", "\r", "\u{0}", "\u{1F}", "é", "e\u{301}", "ß", "я", "漢", "😀", "\u{FEFF}",
            "\u{2028}", "{", "}", "[", "]", ":", ",", "\\(x)", "null", "\u{7F}", "\u{200D}",
        ]
        let text = (0..<Int.random(in: 0...6, using: &self)).map { _ in alphabet.randomElement(using: &self)! }.joined()
        #if FoundationJSON
        if text.unicodeScalars.first == "\u{FEFF}" { return "a" + text }
        #endif
        return text
    }

    mutating func int() -> Int {
        switch Int.random(in: 0..<6, using: &self) {
        case 0: return Int.min
        case 1: return Int.max
        case 2: return 0
        case 3: return Int.random(in: -3...3, using: &self)
        default: return Int.random(in: Int.min...Int.max, using: &self)
        }
    }

    mutating func double() -> Double {
        switch Int.random(in: 0..<8, using: &self) {
        case 0: return 0
        case 1: return -0.0
        case 2: return Double.greatestFiniteMagnitude
        case 3: return Double.leastNonzeroMagnitude
        case 4: return Double(Int.random(in: -1000...1000, using: &self))
        case 5: return Double.random(in: -1...1, using: &self)
        case 6: return 9_007_199_254_740_992
        default:
            let value = Double(bitPattern: next())
            return value.isFinite ? value : 1.5
        }
    }
}

extension JSONValue {
    var independentMacroResult: JSONValue? { self["result"] }
    var independentMacroError: JSONValue? { self["error"] }
    var independentMacroFirstText: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}

extension TestClient {
    /// Calls a tool and returns the whole response message.
    func independentMacroCall(_ name: String, _ arguments: JSONValue? = nil) async throws -> JSONValue {
        var params: JSONObject = ["name": .string(name)]
        if let arguments { params["arguments"] = arguments }
        return try await request("tools/call", params)
    }

    /// The definition of `name` as `tools/list` reports it.
    func independentMacroListed(_ name: String) async throws -> JSONValue? {
        let tools = try await request("tools/list")["result"]?["tools"]?.arrayValue ?? []
        return tools.first { $0["name"]?.stringValue == name }
    }
}
