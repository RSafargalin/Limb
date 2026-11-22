import LimbMacros
import SwiftDiagnostics
import Testing


struct IndependentMacroMistake: Sendable, CustomTestStringConvertible {
    var name: String
    var source: String
    /// Texts whose first occurrence is an acceptable place for the diagnostic.
    var offenders: [String]
    /// What the message has to mention; `|` separates alternatives. Compared case-insensitively.
    var mentions: [String]

    var testDescription: String { name }

    /// A documented tool named `T` with the given `call` declaration.
    static func tool(_ name: String, call: String, offenders: [String], mentions: [String]) -> IndependentMacroMistake {
        .init(name: name, source: "/// Does something.\n@Tool\nstruct T {\n    \(call)\n}", offenders: offenders, mentions: mentions)
    }

    static let all: [IndependentMacroMistake] = [
        // @Tool on the wrong kind of declaration
        .init(
            name: "tool on an enum", source: "/// Doc.\n@Tool\nenum T {\n    func call() {}\n}", offenders: ["@Tool", "enum T"],
            mentions: ["struct"]),
        .init(
            name: "tool on a protocol", source: "/// Doc.\n@Tool\nprotocol P {\n    func call()\n}", offenders: ["@Tool", "protocol P"],
            mentions: ["struct"]),
        .init(
            name: "tool on an extension", source: "struct T {}\n/// Doc.\n@Tool\nextension T {\n    func call() {}\n}",
            offenders: ["@Tool", "extension T"], mentions: ["struct"]),
        .init(
            name: "tool on a public enum", source: "/// Doc.\n@Tool\npublic enum T {\n    func call() {}\n}",
            offenders: ["@Tool", "public enum T", "enum T"], mentions: ["struct"]),
        // The `call` method
        .tool("tool without call", call: "func run(x: Int) {}", offenders: ["@Tool", "struct T"], mentions: ["call"]),
        .init(
            name: "tool with several call methods",
            source: "/// Doc.\n@Tool\nstruct T {\n    func call() {}\n    func call(x: Int) {}\n}", offenders: ["func call(x: Int)", "call(x: Int)"],
            mentions: ["call", "several|more than one|multiple|exactly one"]),
        .tool("static call", call: "static func call(x: Int) -> Int { x }", offenders: ["static func", "func call", "call(x"], mentions: ["static|instance"]),
        .tool("mutating call", call: "mutating func call(x: Int) -> Int { x }", offenders: ["mutating func", "func call", "call(x"], mentions: ["mutating"]),
        .tool(
            "generic call", call: "func call<V: SchemaRepresentable>(x: V) -> Int { 1 }", offenders: ["<V: SchemaRepresentable>", "x: V", "V) ->"],
            mentions: ["generic"]),
        .tool(
            "call with the protocol's own signature",
            call: "func call(arguments: JSONObject, context: RequestContext) async throws -> ToolResult { .text(\"\") }",
            offenders: ["func call", "call(arguments"], mentions: ["call(arguments:context:)|MCPTool"]),
        // Parameters that cannot be arguments
        .tool("inout parameter", call: "func call(a: Int, x: inout Int) {}", offenders: ["x: inout Int", "inout Int"], mentions: ["inout", "'x'"]),
        .tool("variadic parameter", call: "func call(a: Int, x: Int...) {}", offenders: ["x: Int...", "Int..."], mentions: ["variadic", "'x'"]),
        .tool("closure parameter", call: "func call(a: Int, handler: () -> Void) {}", offenders: ["handler: () -> Void", "() -> Void"], mentions: ["handler"]),
        .tool(
            "escaping closure parameter", call: "func call(a: Int, handler: @escaping @Sendable (Int) -> Void) {}",
            offenders: ["handler: @escaping", "@escaping"], mentions: ["handler"]),
        .tool("optional closure parameter", call: "func call(a: Int, handler: (() -> Void)?) {}", offenders: ["handler: (()", "(() -> Void)?"], mentions: ["handler"]),
        .tool("tuple parameter", call: "func call(a: Int, pair: (Int, String)) {}", offenders: ["pair: (Int, String)", "(Int, String)"], mentions: ["pair"]),
        .tool("Any parameter", call: "func call(a: Int, value: Any) {}", offenders: ["value: Any", "Any"], mentions: ["value"]),
        .tool("AnyObject parameter", call: "func call(a: Int, value: AnyObject) {}", offenders: ["value: AnyObject", "AnyObject"], mentions: ["value"]),
        .tool("existential parameter", call: "func call(a: Int, value: any Sendable) {}", offenders: ["value: any Sendable", "any Sendable"], mentions: ["value"]),
        .tool("opaque parameter", call: "func call(a: Int, value: some Sendable) {}", offenders: ["value: some Sendable", "some Sendable"], mentions: ["value"]),
        .tool("borrowing parameter", call: "func call(a: Int, value: borrowing String) {}", offenders: ["value: borrowing", "borrowing String"], mentions: ["value"]),
        .tool("implicitly unwrapped parameter", call: "func call(a: Int, value: Int!) {}", offenders: ["value: Int!", "Int!"], mentions: ["value", "?|optional"]),
        .tool("parameter without a name", call: "func call(a: Int, _ _: Int) {}", offenders: ["_ _: Int"], mentions: ["name"]),
        .tool("duplicate argument names", call: "func call(_ a: Int, a b: Int) {}", offenders: ["a b: Int"], mentions: ["'a'", "two|duplicate|same|twice"]),
        // Names
        .init(
            name: "empty explicit name", source: "/// Doc.\n@Tool(\"\")\nstruct T {\n    func call() {}\n}", offenders: ["\"\""],
            mentions: ["name"]),
        .init(
            name: "explicit name with a space", source: "/// Doc.\n@Tool(\"get weather\")\nstruct T {\n    func call() {}\n}",
            offenders: ["\"get weather\""], mentions: ["get weather"]),
        .init(
            name: "explicit name with a slash", source: "/// Doc.\n@Tool(\"fs/read\")\nstruct T {\n    func call() {}\n}",
            offenders: ["\"fs/read\""], mentions: ["fs/read"]),
        .init(
            name: "explicit name outside ASCII", source: "/// Doc.\n@Tool(\"погода\")\nstruct T {\n    func call() {}\n}",
            offenders: ["\"погода\""], mentions: ["погода"]),
        .init(
            name: "explicit name of 129 characters",
            source: "/// Doc.\n@Tool(\"\(String(repeating: "n", count: 129))\")\nstruct T {\n    func call() {}\n}",
            offenders: ["\"nnnn"], mentions: ["128"]),
        .init(
            name: "derived name outside ASCII", source: "/// Doc.\n@Tool\nstruct Погода {\n    func call() {}\n}",
            offenders: ["@Tool", "struct Погода", "Погода"], mentions: ["name"]),
        .init(
            name: "name that is not a literal", source: "let toolName = \"x\"\n/// Doc.\n@Tool(toolName)\nstruct T {\n    func call() {}\n}",
            offenders: ["toolName)"], mentions: ["literal"]),
        .init(
            name: "interpolated name", source: "/// Doc.\n@Tool(\"a\\(1)\")\nstruct T {\n    func call() {}\n}", offenders: ["\"a\\(1)\""],
            mentions: ["literal"]),
        // @Schema on the wrong kind of declaration
        .init(
            name: "schema on a class", source: "@Schema\nfinal class C {\n    var a: Int = 0\n}", offenders: ["@Schema", "final class C"],
            mentions: ["struct"]),
        .init(name: "schema on an actor", source: "@Schema\nactor C {\n    var a: Int = 0\n}", offenders: ["@Schema", "actor C"], mentions: ["struct"]),
        .init(
            name: "schema on a protocol", source: "@Schema\nprotocol P {\n    var a: Int { get }\n}", offenders: ["@Schema", "protocol P"],
            mentions: ["struct"]),
        // Enums that cannot be expressed
        .init(
            name: "enum without raw values", source: "@Schema\nenum E {\n    case a, b\n}", offenders: ["@Schema", "enum E"],
            mentions: ["String"]),
        .init(
            name: "enum with integer raw values", source: "@Schema\nenum E: Int {\n    case a = 1, b\n}",
            offenders: ["@Schema", "enum E", "Int {"], mentions: ["String"]),
        .init(
            name: "enum with associated values", source: "@Schema\nenum E {\n    case plain\n    case loaded(Int)\n}",
            offenders: ["loaded(Int)", "case loaded", "(Int)"], mentions: ["associated"]),
        .init(
            name: "String enum with associated values", source: "@Schema\nenum E: String {\n    case plain\n    case loaded(Int)\n}",
            offenders: ["loaded(Int)", "case loaded", "(Int)"], mentions: ["associated"]),
        // Properties
        .init(
            name: "property without a type annotation", source: "@Schema\nstruct S {\n    var a: Int\n    var d = 4\n}",
            offenders: ["var d = 4", "d = 4"], mentions: ["'d'", "type"]),
        .init(
            name: "tuple pattern property", source: "@Schema\nstruct S {\n    var a: Int\n    var (b, c): (Int, Int) = (1, 2)\n}",
            offenders: ["var (b, c)", "(b, c)"], mentions: ["propert"]),
        .init(
            name: "lazy property", source: "@Schema\nstruct S {\n    var a: Int\n    lazy var b: Int = 1\n}",
            offenders: ["lazy var b", "var b", "b: Int"], mentions: ["lazy"]),
        .init(
            name: "implicitly unwrapped property", source: "@Schema\nstruct S {\n    var a: Int\n    var b: Int!\n}",
            offenders: ["var b: Int!", "b: Int!", "Int!"], mentions: ["?|optional"]),
    ]

    /// Valid declarations; the tools are documented.
    static let validSources: [String] = [
        "@Schema\nstruct S {\n    var a: Int\n    let b: String?\n    var c: [String: [Double]] = [:]\n}",
        "@Schema\nstruct S {\n    var a, b: Int\n    var c: Int { a }\n    var d: Int = 0 { didSet {} }\n}",
        "@Schema\nenum E: String {\n    case a, b = \"B\"\n}",
        "@Schema\nenum E: Swift.String {\n    case a\n}",
        "@Schema\nstruct Empty {}",
        "/// Doc.\n@Tool\nstruct T {\n    func call() {}\n}",
        "@Tool\nstruct T {\n    /// Only the method is documented.\n    func call() {}\n}",
        "/** Doc. */\n@Tool(\"x.y-z_1\", title: \"T\", readOnly: true, destructive: false, idempotent: true, openWorld: false)\nfinal class T {\n    func call(a: Int, context: ToolContext) async throws -> String { \"\" }\n}",
        "/// Doc.\n@Tool\nactor T {\n    func call(_ a: Int, b c: Int = 1, d _: Int, `in`: Int?, context: LimbServer.ToolContext?) -> Swift.Void {}\n}",
    ]
}

@Suite struct IndependentMacroDiagnosticsTests {
    @Test(arguments: IndependentMacroMistake.all)
    func mistakeIsReportedOnceWithItsCause(_ mistake: IndependentMacroMistake) {
        let expansion = IndependentMacroExpansion(mistake.source)
        // One error and nothing else: no second error, no warning riding along.
        #expect(
            expansion.diagnostics.count == 1,
            "expected exactly one diagnostic from the macro, got \(expansion.diagnostics); expansion:\n\(expansion.expanded)")
        #expect(expansion.errors.count == 1)
        guard let error = expansion.errors.first else { return }
        let message = error.message.lowercased()
        for alternatives in mistake.mentions {
            let options = alternatives.split(separator: "|").map { $0.lowercased() }
            #expect(options.contains { message.contains($0) }, "\"\(error.message)\" does not mention \(alternatives)")
        }
    }

    @Test(arguments: IndependentMacroMistake.all)
    func mistakeIsReportedOnTheOffendingNode(_ mistake: IndependentMacroMistake) {
        let expansion = IndependentMacroExpansion(mistake.source)
        guard let error = expansion.errors.first else {
            Issue.record("no error to locate; diagnostics: \(expansion.diagnostics)")
            return
        }
        let acceptable = mistake.offenders.compactMap { IndependentMacroPosition(of: $0, in: mistake.source) }
        #expect(acceptable.count == mistake.offenders.count, "a needle of the test itself is not in the source")
        #expect(
            acceptable.contains { $0.line == error.line && $0.column == error.column },
            "the error is at \(error.line):\(error.column), expected one of \(acceptable) (\(mistake.offenders))")
    }

    /// A declaration the macro refuses must not be half-expanded: whatever is generated next to
    /// the error produces errors of its own, in code the user did not write. (With the member
    /// role failing and the extension role still adding `: MCPTool`, the compiler adds "type
    /// 'T' does not conform to protocol 'MCPTool'" inside the macro expansion.)
    @Test(arguments: IndependentMacroMistake.all)
    func aRejectedDeclarationIsNotHalfExpanded(_ mistake: IndependentMacroMistake) {
        let expansion = IndependentMacroExpansion(mistake.source)
        guard !expansion.errors.isEmpty else { return }
        #expect(!expansion.producedCode, "generated next to the error:\n\(expansion.expanded)")
    }

    @Test func validDeclarationsProduceNoDiagnostics() {
        for source in IndependentMacroMistake.validSources {
            let expansion = IndependentMacroExpansion(source)
            #expect(expansion.diagnostics.isEmpty, "\(source)\n\(expansion.diagnostics)")
            #expect(expansion.producedExtension, "\(source)")
            #expect(expansion.producedCode, "\(source)")
        }
    }

    /// Э1 lists "забытое описание" among the mistakes to catch: a tool the model has to choose
    /// without being told what it does. It is a warning, not an error — the tool still works —
    /// it sits on the tool's name, says what to do, and does not stop the expansion.
    @Test func aToolWithoutADescriptionGetsOneWarningOnItsName() {
        let source = "@Tool(readOnly: true)\nstruct Lookup {\n    // Not a doc comment.\n    func call(query: String) -> String { query }\n}"
        let expansion = IndependentMacroExpansion(source)
        #expect(expansion.errors.isEmpty)
        #expect(expansion.warnings.count == 1, "\(expansion.diagnostics)")
        #expect(expansion.diagnostics.count == 1)
        guard let warning = expansion.warnings.first else { return }
        let name = IndependentMacroPosition(of: "Lookup", in: source)
        #expect(warning.line == name?.line && warning.column == name?.column, "the warning is at \(warning.line):\(warning.column)")
        #expect(warning.message.contains("lookup"), "\(warning.message)")
        #expect(warning.message.lowercased().contains("description"), "\(warning.message)")
        #expect(warning.message.contains("///"), "\(warning.message)")
        #expect(expansion.producedExtension)
        #expect(expansion.expanded.contains("description: nil"))
    }

    /// Any documentation that becomes the description silences the warning: on the type, on
    /// `call`, as a line or a block comment.
    @Test func anyDescriptionSilencesTheWarning() {
        let documented = [
            "/// Looks things up.\n@Tool\nstruct Lookup {\n    func call(query: String) -> String { query }\n}",
            "/** Looks things up. */\n@Tool\nstruct Lookup {\n    func call(query: String) -> String { query }\n}",
            "@Tool\nstruct Lookup {\n    /// Looks things up.\n    func call(query: String) -> String { query }\n}",
            "/// Looks things up.\n@Tool public struct Lookup {\n    func call(query: String) -> String { query }\n}",
        ]
        for source in documented {
            let expansion = IndependentMacroExpansion(source)
            #expect(expansion.diagnostics.isEmpty, "\(source)\n\(expansion.diagnostics)")
            #expect(expansion.expanded.contains("description: \"Looks things up.\""), "\(source)")
        }
        // A comment that documents only the parameters leaves the tool itself undescribed.
        let parametersOnly = IndependentMacroExpansion(
            "@Tool\nstruct Lookup {\n    /// - Parameter query: What to look for.\n    func call(query: String) -> String { query }\n}")
        #expect(parametersOnly.warnings.count == 1)
        #expect(parametersOnly.errors.isEmpty)
    }

    /// The missing description is the only warning there is: `@Schema` never warns, and
    /// undocumented variants of every valid tool get exactly that one warning.
    @Test func theMissingDescriptionIsTheOnlyWarning() {
        for source in IndependentMacroMistake.validSources {
            let stripped = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains("///") && !$0.contains("/**") }.joined(separator: "\n")
            let expansion = IndependentMacroExpansion(stripped)
            #expect(expansion.errors.isEmpty, "\(stripped)\n\(expansion.diagnostics)")
            let expected = stripped.contains("@Tool") ? 1 : 0
            #expect(expansion.warnings.count == expected, "\(stripped)\n\(expansion.diagnostics)")
            for warning in expansion.warnings {
                #expect(warning.message.lowercased().contains("description"), "\(warning.message)")
            }
        }
    }

    @Test func mistakesAreErrorsNotWarnings() {
        for mistake in IndependentMacroMistake.all {
            let expansion = IndependentMacroExpansion(mistake.source)
            #expect(expansion.warnings.isEmpty, "\(mistake.name): \(expansion.diagnostics)")
            #expect(!expansion.errors.isEmpty, "\(mistake.name): no error")
        }
    }

    /// `var a, b: Int` declares two `Int` properties; the type is there.
    @Test func aTypeAnnotationSharedByTwoBindingsIsAccepted() {
        let expansion = IndependentMacroExpansion("@Schema\nstruct S {\n    var a, b: Int\n}")
        #expect(expansion.diagnostics.isEmpty, "\(expansion.diagnostics)")
        #expect(expansion.expanded.contains("\"a\""))
        #expect(expansion.expanded.contains("\"b\""))
    }

    /// `Swift.String` is `String`.
    @Test func aQualifiedStringRawTypeIsAccepted() {
        let expansion = IndependentMacroExpansion("@Schema\nenum E: Swift.String {\n    case a\n}")
        #expect(expansion.diagnostics.isEmpty, "\(expansion.diagnostics)")
        #expect(expansion.producedExtension)
    }

    /// The advice in a message must not lead to another error: an enum with associated values
    /// cannot be "declared as 'enum E: String'".
    @Test func adviceForAssociatedValuesIsNotToAddARawType() {
        let expansion = IndependentMacroExpansion("@Schema\nenum E {\n    case plain\n    case loaded(Int)\n}")
        let message = expansion.errors.first?.message ?? ""
        #expect(!message.isEmpty)
        #expect(!message.contains("declare it as 'enum E: String'"), "\(message)")
    }
}
