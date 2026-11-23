import Limb
import LimbTesting
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif


// MARK: - Expansion: J12

private let storedInIfMessage =
    "@Schema does not support stored properties inside '#if': the schema, the decoder and the encoder would leave them out"
private let caseInIfMessage = "@Schema does not support enum cases inside '#if': the schema and the decoder would disagree about them"

/// One `@Schema` declaration and what the macro must say about it.
struct Round2ConditionalCase: Sendable, CustomTestStringConvertible {
    var name: String
    var source: String
    /// The error expected, at the first `#if` of the source; nil if the declaration is accepted.
    var error: String?
    var testDescription: String { name }

    static let all: [Round2ConditionalCase] = [
        // Refused: a stored property or a case somewhere under a `#if`.
        .init(name: "stored property", source: "@Schema struct S {\n    var a: Int\n    #if DEBUG\n    var b: Int\n    #endif\n}", error: storedInIfMessage),
        .init(name: "stored property with a default", source: "@Schema struct S {\n    #if DEBUG\n    var b: Int = 0\n    #endif\n    var a: Int\n}", error: storedInIfMessage),
        .init(name: "constant without a value", source: "@Schema struct S {\n    var a: Int\n    #if DEBUG\n    let k: Int\n    #endif\n}", error: storedInIfMessage),
        .init(name: "variable with a value", source: "@Schema struct S {\n    var a: Int\n    #if DEBUG\n    var k = 5\n    #endif\n}", error: storedInIfMessage),
        .init(name: "constant with a value next to a stored one", source: "@Schema struct S {\n    #if DEBUG\n    let k = 5, j: Int\n    #endif\n}", error: storedInIfMessage),
        .init(name: "stored property with observers", source: "@Schema struct S {\n    #if DEBUG\n    var b: Int = 0 { didSet {} }\n    #endif\n}", error: storedInIfMessage),
        .init(name: "in an #else", source: "@Schema struct S {\n    #if DEBUG\n    func f() {}\n    #else\n    var b: Int\n    #endif\n}", error: storedInIfMessage),
        .init(name: "in an #elseif", source: "@Schema struct S {\n    #if A\n    #elseif B\n    var b: Int\n    #endif\n}", error: storedInIfMessage),
        .init(name: "nested two deep", source: "@Schema struct S {\n    #if A\n    static let s = 1\n    #if B\n    var b: Int\n    #endif\n    #endif\n}", error: storedInIfMessage),
        .init(
            name: "nested three deep in an #else",
            source: "@Schema struct S {\n    #if A\n    #else\n    #if B\n    #elseif C\n    #if D\n    var b: [String]?\n    #endif\n    #endif\n    #endif\n}",
            error: storedInIfMessage),
        .init(name: "two bindings, one stored", source: "@Schema struct S {\n    #if A\n    var b: Int, c: Int\n    #endif\n}", error: storedInIfMessage),
        .init(name: "enum case", source: "@Schema enum E: String {\n    case a, b = \"bee\"\n    #if DEBUG\n    case dbg\n    #endif\n}", error: caseInIfMessage),
        .init(name: "enum case in an #elseif", source: "@Schema enum E: String {\n    case a\n    #if A\n    static let s = 1\n    #elseif B\n    case b\n    #endif\n}", error: caseInIfMessage),
        .init(name: "enum case nested", source: "@Schema enum E: String {\n    case a\n    #if A\n    #if B\n    #else\n    case b\n    #endif\n    #endif\n}", error: caseInIfMessage),
        // Accepted: nothing that is part of the data.
        .init(
            name: "computed, static and methods",
            source: "@Schema struct S {\n    var a: Int\n    #if A\n    var c: Int { a }\n    static var s = 1\n    static let t: Int = 2\n    func f() {}\n    init(a: Int) { self.a = a }\n    #elseif B\n    var d: Int { get { a } set { a = newValue } }\n    #else\n    subscript(i: Int) -> Int { i }\n    #endif\n}",
            error: nil),
        .init(
            name: "nested types with stored properties",
            source: "@Schema struct S {\n    var a: Int\n    #if A\n    struct Inner { var x: Int }\n    enum Kind: String { case one }\n    #endif\n}", error: nil),
        .init(
            name: "enum with members under #if",
            source: "@Schema enum E: String {\n    case a\n    #if A\n    static let s = 1\n    var doubled: String { rawValue + rawValue }\n    func f() {}\n    enum Inner { case x }\n    #endif\n}",
            error: nil),
        .init(name: "attributes under #if", source: "@Schema struct S {\n    #if A\n    @available(*, deprecated)\n    #endif\n    var a: Int\n}", error: nil),
        .init(name: "constant with a value", source: "@Schema struct S {\n    var a: Int\n    #if DEBUG\n    let k = 5\n    #endif\n}", error: nil),
        .init(name: "constants with values, nested", source: "@Schema struct S {\n    var a: Int\n    #if A\n    #if B\n    let k = 5, c = \"x\"\n    #else\n    let k: Int = 6\n    #endif\n    #endif\n}", error: nil),
        .init(name: "empty #if", source: "@Schema struct S {\n    var a: Int\n    #if A\n    #endif\n}", error: nil),
    ]
}

@Suite struct Round2ConditionalMemberExpansionTests {
    @Test(arguments: Round2ConditionalCase.all)
    func conditionalMembers(_ example: Round2ConditionalCase) throws {
        let expansion = IndependentMacroExpansion(example.source)
        if let error = example.error {
            #expect(expansion.diagnostics.count == 1, "\(expansion.diagnostics)")
            let diagnostic = try #require(expansion.errors.first)
            #expect(diagnostic.message == error)
            let position = try #require(IndependentMacroPosition(of: "#if", in: example.source))
            #expect(diagnostic.line == position.line && diagnostic.column == position.column, "\(diagnostic)")
            #expect(!expansion.producedExtension)
        } else {
            #expect(expansion.diagnostics.isEmpty, "\(expansion.diagnostics)")
            #expect(expansion.producedExtension)
            // Only the plain stored property is described.
            #expect(!expansion.expanded.contains("\\Self.k") && !expansion.expanded.contains("\\Self.c") && !expansion.expanded.contains("\\Self.d") && !expansion.expanded.contains("\\Self.s"))
        }
    }

    @Test func membersOutsideAnyIfAreUnaffected() {
        let expansion = IndependentMacroExpansion("@Schema struct S {\n    #if A\n    func f() {}\n    #endif\n    var a: Int\n    var b: String?\n}")
        #expect(expansion.diagnostics.isEmpty)
        #expect(expansion.expanded.contains("__limbFields.add(\"a\", \\Self.a"))
        #expect(expansion.expanded.contains("__limbFields.add(\"b\", \\Self.b"))
    }
}

// MARK: - Expansion: J13, `name:`

@Suite struct Round2ToolIsolationExpansionTests {
    private func definitionLine(_ source: String) -> String? {
        IndependentMacroExpansion(source).expanded.split(separator: "\n").first { $0.contains("static var definition") }.map(String.init)
    }

    @Test func onlyMainActorTypesGetANonisolatedDefinition() {
        let isolated = [
            "/// D.\n@MainActor @Tool struct T { func call() {} }", "/// D.\n@Tool @MainActor struct T { func call() {} }",
            "/// D.\n@Swift.MainActor @Tool struct T { func call() {} }", "/// D.\n@MainActor @Tool final class T { func call() {} }",
            "/// D.\n@MainActor\n@Tool public struct T { public func call() {} }",
        ]
        for source in isolated {
            let line = definitionLine(source)
            #expect(line?.contains("nonisolated static var definition") == true, "\(source): \(String(describing: line))")
        }
        // Second pass: any capitalized attribute but `@Tool` may be a global actor.
        for source in ["/// D.\n@G @Tool struct T { func call() {} }", "/// D.\n@Tool @Module.G final class T { func call() {} }", "/// D.\n@Observable @Tool final class T { func call() {} }"] {
            #expect(definitionLine(source)?.contains("nonisolated static var definition") == true, "\(source)")
        }
        let plain = [
            "/// D.\n@Tool struct T { func call() {} }", "/// D.\n@Tool actor T { func call() {} }", "/// D.\n@Tool struct T { @MainActor func call() {} }",
            "/// D.\n@available(macOS 26, *) @Tool struct T { func call() {} }",
            "/// D.\n@frozen @usableFromInline @Tool struct T { func call() {} }", "/// D.\n@mainActor @Tool struct T { func call() {} }",
        ]
        for source in plain {
            let line = definitionLine(source)
            #expect(line != nil && line?.contains("nonisolated") == false, "\(source): \(String(describing: line))")
        }
        // `call` is never marked: it stays isolated to the type.
        let expanded = IndependentMacroExpansion("/// D.\n@MainActor @Tool struct T { func call(x: Int) -> Int { x } }").expanded
        #expect(expanded.contains("func call(\n") || expanded.contains("func call("))
        #expect(!expanded.contains("nonisolated func call") && !expanded.contains("nonisolated(nonsending) func call"))
        // The public access level comes before `nonisolated`.
        #expect(definitionLine("/// D.\n@MainActor @Tool public struct T { public func call() {} }")?.contains("public nonisolated static var definition") == true)
    }

    /// The macro declaration takes the name unlabelled; a `name:` label is an unknown argument.
    @Test func aNameLabelIsUnknown() throws {
        let source = "/// D.\n@Tool(name: \"x\")\nstruct T { func call() {} }"
        let expansion = IndependentMacroExpansion(source)
        #expect(expansion.errors.map(\.message) == ["unknown @Tool argument 'name'"])
        #expect(!expansion.producedCode)
        let unlabelled = IndependentMacroExpansion("/// D.\n@Tool(\"x\")\nstruct T { func call() {} }")
        #expect(unlabelled.diagnostics.isEmpty)
        #expect(unlabelled.expanded.contains("name: \"x\""))
    }
}

// MARK: - Compiled fixtures: J12

/// Members under `#if` that are not data, in every kind of branch and nested.
@Schema
private struct R2MConditionalStruct: Equatable {
    var a: Int
    #if DEBUG
    var debugOnly: Int { a * 2 }
    static let mode = "debug"
    func describe() -> String { "debug \(a)" }
    #elseif canImport(Darwin)
    var debugOnly: Int { a * 3 }
    static let mode = "release on Darwin"
    func describe() -> String { "release \(a)" }
    #else
    var debugOnly: Int { a * 4 }
    static let mode = "release"
    func describe() -> String { "other \(a)" }
    #endif
    #if canImport(Darwin)
    #if compiler(>=6.0)
    var nested: String { "nested" }
    #else
    var nested: String { "old" }
    #endif
    #endif
    var b: String?
}

@Schema
private enum R2MConditionalEnum: String {
    case a, b = "bee"
    #if DEBUG
    static let built = "debug"
    var shout: String { rawValue.uppercased() }
    #else
    static let built = "release"
    var shout: String { rawValue }
    #endif
    #if true
    #if false
    func never() {}
    #else
    func always() -> Int { 1 }
    #endif
    #endif
}

@Suite struct Round2ConditionalMemberCompilationTests {
    @Test func structWithConditionalMembers() throws {
        let schema = R2MConditionalStruct.jsonSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["a", "b"])
        #expect(schema["required"] == ["a"])
        IndependentMacroCheckRoundTrip(R2MConditionalStruct(a: 3, b: "x"))
        IndependentMacroCheckRoundTrip(R2MConditionalStruct(a: -1, b: nil))
        let value = try R2MConditionalStruct(json: ["a": 2])
        #expect(value.jsonValue == ["a": 2])
        #if canImport(Darwin)
        #expect(value.nested == "nested")
        #endif
        #expect(value.debugOnly > 2)
        #if DEBUG
        #expect(R2MConditionalStruct.mode == "debug")
        #elseif canImport(Darwin)
        #expect(R2MConditionalStruct.mode == "release on Darwin")
        #else
        #expect(R2MConditionalStruct.mode == "release")
        #endif
    }

    @Test func enumWithConditionalMembers() throws {
        #expect(R2MConditionalEnum.jsonSchema == ["type": "string", "enum": ["a", "bee"]])
        #expect(try R2MConditionalEnum(json: "bee") == .b)
        #expect(throws: JSONDecodingError.self) { try R2MConditionalEnum(json: "b") }
        #expect(R2MConditionalEnum.a.always() == 1)
        #expect(R2MConditionalEnum.b.shout.lowercased() == "bee")
    }
}

// MARK: - Compiled fixtures: J13

@MainActor
private enum R2MMainState {
    static var total = 0
    static var calls: [String] = []
}

/// Adds to a total kept on the main actor.
@MainActor
@Tool
private struct R2MMainAdd {
    let label: String
    func call(amount: Int, note: String? = nil) -> Int {
        MainActor.assertIsolated()
        R2MMainState.total += amount
        R2MMainState.calls.append(label + (note ?? ""))
        return R2MMainState.total
    }
}

/// Counts in a main-actor class, asynchronously, with a default taken from a static member.
@MainActor
@Tool("main_counter", readOnly: false)
private final class R2MMainCounter {
    var count = 0
    static let step = 5
    func call(by: Int = step, context: ToolContext) async throws -> String {
        MainActor.assertIsolated()
        await Task.yield()
        MainActor.assertIsolated()
        count += by
        if by < 0 { throw ToolError("negative steps are refused") }
        return "\(context.method) \(count)"
    }
}

/// Returns a value of a schema type declared inside the main-actor tool.
@MainActor
@Tool
private struct R2MMainPoint {
    @Schema struct Point: Equatable {
        var x: Int
        var y: Int
    }

    func call(point: Point) -> Point {
        MainActor.assertIsolated()
        return Point(x: point.y, y: point.x)
    }
}

@globalActor private actor R2MOtherActor {
    static let shared = R2MOtherActor()
}

@R2MOtherActor private enum R2MOtherState { static var calls = 0 }

/// Counts calls on another global actor.
@R2MOtherActor
@Tool
private final class R2MOtherActorTool {
    func call(by: Int = 1) -> Int {
        R2MOtherActor.shared.assertIsolated()
        R2MOtherState.calls += by
        return R2MOtherState.calls
    }
}

@MainActor
private enum R2MMainNamespace {
    /// A tool nested in a main-actor type, without an attribute of its own: not isolated.
    @Tool struct Nested { func call(x: Int) -> Int { x * 2 } }
}

/// Marked `@available`: lowercase, so `definition` stays as it is.
@available(macOS 26, *)
@Tool
private struct R2MAvailable { func call() -> String { "available" } }

/// `definition` is nonisolated: read from a nonisolated synchronous context.
private nonisolated func round2MainDefinitions() -> [ToolDefinition] {
    [R2MMainAdd.definition, R2MMainCounter.definition, R2MMainPoint.definition, R2MOtherActorTool.definition, R2MMainNamespace.Nested.definition, R2MAvailable.definition]
}

@Suite(.serialized) struct Round2MainActorToolTests {
    @Test func definitionsAreReadableAnywhere() throws {
        let definitions = round2MainDefinitions()
        #expect(definitions.map(\.name) == ["r2_m_main_add", "main_counter", "r2_m_main_point", "r2_m_other_actor_tool", "nested", "r2_m_available"])
        #expect(definitions[0].description == "Adds to a total kept on the main actor.")
        #expect(definitions[2].outputSchema?["properties"]?.objectValue?.map(\.key) == ["x", "y"])
        IndependentMacroCheckSchema(definitions[1].inputSchema)
    }

    @Test func toolsOnAnotherGlobalActorAndNestedToolsAreCalledThroughAServer() async throws {
        let tool = await R2MOtherActorTool()
        let server = try Server(name: "actors", version: "1") {
            tool
            R2MMainNamespace.Nested()
            R2MAvailable()
        }
        let client = TestClient(server)
        let first = try await client.independentMacroCall("r2_m_other_actor_tool")
        let before = first["result"]?["structuredContent"]?.intValue ?? -1
        #expect(before >= 1, "\(first)")
        let second = try await client.independentMacroCall("r2_m_other_actor_tool", ["by": 2])
        #expect(second["result"]?["structuredContent"] == JSONValue(before + 2))
        #expect(try await client.independentMacroCall("nested", ["x": 21])["result"]?["structuredContent"] == 42)
        #expect(try await client.independentMacroCall("r2_m_available").independentMacroFirstText == "available")
        await client.close()
    }

    @Test func mainActorToolsAreCalledThroughAServer() async throws {
        let counter = await R2MMainCounter()
        let server = try await Server(name: "main", version: "1") {
            R2MMainAdd(label: "first")
            counter
            R2MMainPoint()
        }
        let client = TestClient(server)
        let before = await MainActor.run { R2MMainState.total }
        let added = try await client.independentMacroCall("r2_m_main_add", ["amount": 4, "note": "!"])
        #expect(added["result"]?["structuredContent"] == JSONValue(before + 4), "\(added)")
        // Concurrent calls all run on the main actor; none is lost. (Sent at once and collected
        // as they come: `TestClient.response(to:)` is not meant for concurrent waiters.)
        let ids = (0..<20).map { _ in client.post("tools/call", ["name": "r2_m_main_add", "arguments": ["amount": 1]]) }
        var answered: Set<String> = []
        for _ in ids {
            let message = try await client.next()
            #expect(message["result"]?["isError"] == false, "\(message)")
            answered.insert(message["id"]?.description ?? "")
        }
        #expect(answered == Set(ids.map { $0.json.description }))
        let after = await MainActor.run { (R2MMainState.total, R2MMainState.calls.suffix(21)) }
        #expect(after.0 == before + 24)
        #expect(after.1.first == "first!")
        // The class keeps its state between calls; the default comes from the static member.
        let first = try await client.independentMacroCall("main_counter")
        #expect(first.independentMacroFirstText == "tools/call 5", "\(first)")
        let second = try await client.independentMacroCall("main_counter", ["by": 2])
        #expect(second.independentMacroFirstText == "tools/call 7")
        let refused = try await client.independentMacroCall("main_counter", ["by": -1])
        #expect(refused["result"]?["isError"] == true, "\(refused)")
        #expect(refused.independentMacroFirstText == "negative steps are refused")
        #expect(await counter.count == 6)
        // Arguments are still validated before the main actor is asked.
        let invalid = try await client.independentMacroCall("r2_m_main_add", ["amount": "x"])
        #expect(invalid["result"]?["isError"] == true || invalid["error"] != nil, "\(invalid)")
        #expect(await MainActor.run { R2MMainState.total } == before + 24)
        let point = try await client.independentMacroCall("r2_m_main_point", ["point": ["x": 1, "y": 2]])
        #expect(point["result"]?["structuredContent"] == ["x": 2, "y": 1], "\(point)")
        await client.close()
    }
}

// MARK: - The builder initializer's `configure:`

/// A fixture.
@Tool private struct R2MPing { func call() -> String { "pong" } }

@Suite struct Round2BuilderConfigureTests {
    @Test func configureRunsOnceAfterTheParametersAndBeforeTheTools() async throws {
        var calls = 0
        var seen: (String, String?, String?) = ("", nil, nil)
        let server = try Server(name: "conf", version: "2", title: "Title", instructions: "from the parameter", configure: { configuration in
            calls += 1
            seen = (configuration.info.name, configuration.info.title, configuration.instructions)
            configuration.instructions = "from configure"
            configuration.execution = .serial
            configuration.budgets.maxInputResponses = 3
        }) {
            R2MPing()
        }
        #expect(calls == 1)
        #expect(seen.0 == "conf" && seen.1 == "Title" && seen.2 == "from the parameter")
        #expect(server.configuration.instructions == "from configure")
        #expect(server.configuration.budgets.maxInputResponses == 3)
        if case .serial = server.configuration.execution {} else { Issue.record("execution is \(server.configuration.execution)") }
        let client = TestClient(server)
        let initialized = try await client.initialize()
        #expect(initialized["result"]?["instructions"] == "from configure" || initialized["instructions"] == "from configure", "\(initialized)")
        #expect(try await client.independentMacroCall("r2_m_ping").independentMacroFirstText == "pong")
        await client.close()
    }

    @Test func everySpellingOfTheInitializerCompiles() throws {
        // Trailing closure only: the tools.
        let plain = try Server(name: "a", version: "1") { R2MPing() }
        #expect(plain.configuration.instructions == nil)
        // Both as trailing closures.
        let both = try Server(name: "b", version: "1") { $0.instructions = "both" } tools: {
            R2MPing()
        }
        #expect(both.configuration.instructions == "both")
        // Labelled configure, trailing tools; no tools at all.
        let empty = try Server(name: "c", version: "1", configure: { $0.instructions = "empty" }) {}
        #expect(empty.configuration.instructions == "empty")
        // The plain initializer without tools keeps its own configure.
        let bare = Server(name: "d", version: "1") { $0.instructions = "bare" }
        #expect(bare.configuration.instructions == "bare")
    }
}

// MARK: - J2 from the wire: extreme numbers

/// A fixture.
@Tool private struct R2MHalf { func call(x: Double) -> Double { x / 2 } }
/// A fixture.
@Tool private struct R2MWhole { func call(n: Int) -> Int { n } }
/// A fixture.
@Tool private struct R2MProgress {
    func call(context: ToolContext) -> String {
        context.progress(0.5)
        return "ok"
    }
}

/// Sends requests with extreme numbers in every place the server hashes, compares or converts
/// a number (request id, progress token, the id in a cancellation, integer and number arguments,
/// `_meta` values) and returns what differs from the expected answers. Both codecs preserve
/// numeric input before the tool converts it to its declared argument type.
private func round2ExtremeNumbersOnTheWire() async -> [String] {
    var problems: [String] = []
    let server = try! Server(name: "wire", version: "1") {
        R2MHalf()
        R2MWhole()
        R2MProgress()
    }
    let client = TestClient(server)
    func next() async -> JSONValue? { try? await client.next(timeout: .seconds(5)) }
    let texts = ["1e9999999999999999999", "-1e9999999999999999999", "1e-9999999999999999999", "4e4000000000000000000", "-4e-4000000000000000000",
        "1e9223372036854775807", "1e9223372036854775808", "1e" + String(repeating: "9", count: 30), "0e" + String(repeating: "9", count: 30),
        "-0.000e-99999999999999999999", "1e00000000000000000000000000005", String(repeating: "7", count: 4000) + "e-4000000000000000000",
        "9223372036854775807", "-9223372036854775808", "9223372036854775808", "1e400", "2.5e-400", "1e18", "123.0"]
    for text in texts {
        let number = JSONNumber(lexeme: text)!
        if (try? JSON.parse(text))?.numberValue?.description != text {
            problems.append("parse \(text): number spelling changed or was rejected")
        }
        let double = number.doubleValue
        func check(_ label: String, _ message: JSONValue?, _ expected: (JSONValue?) -> Bool) {
            if !expected(message) { problems.append("\(label) \(text): \(String(describing: message))") }
        }
        // The number as a request id (only integers: the test client refuses other ids).
        if number.isInteger {
            let id = client.post("tools/list", id: .number(number))
            check("id", await next()) { $0?["result"] != nil && $0?["id"] == id.json }
        }
        // As an integer argument.
        _ = client.post("tools/call", ["name": "r2_m_whole", "arguments": ["n": .number(number)]])
        check("integer", await next()) { message in
            let expected = number.isInteger ? number.intValue : nil
            if let expected { return message?["result"]?["structuredContent"] == JSONValue(expected) }
            return message?["result"]?["isError"] == true
        }
        // As a number argument.
        _ = client.post("tools/call", ["name": "r2_m_half", "arguments": ["x": .number(number)]])
        check("number", await next()) { message in
            if double.isFinite { return message?["result"]?["structuredContent"]?.doubleValue == double / 2 }
            return message?["result"]?["isError"] == true
        }
        // As a progress token, and as a value in `_meta`.
        _ = client.post("tools/call", ["name": "r2_m_progress"], meta: ["progressToken": .number(number), "x": [.number(number)]])
        if number.isInteger {
            let progress = await next()
            if progress?["method"] != "notifications/progress" || progress?["params"]?["progressToken"]?.numberValue?.description != text {
                problems.append("progress \(text): \(String(describing: progress))")
            }
        }
        let done = await next()
        if done?["result"]?["isError"] != false { problems.append("progress \(text), response: \(String(describing: done))") }
        // As the id in a cancellation: nothing to cancel; the server still answers afterwards.
        client.notify("notifications/cancelled", ["requestId": .number(number)])
        let after = client.post("tools/list")
        let pong = await next()
        if pong?["id"] != after.json || pong?["result"] == nil { problems.append("after \(text): \(String(describing: pong))") }
    }
    await client.close()
    return problems
}

@Suite struct Round2ExtremeNumbersOnTheWireTests {
    @Test func extremeNumbersEverywhereTheServerReadsNumbers() async {
        let result = await #expect(processExitsWith: .success) {
            let problems = await round2ExtremeNumbersOnTheWire()
            precondition(problems.isEmpty, "\(problems)")
        }
        guard result?.exitStatus == .exitCode(0) else { return }
        let problems = await round2ExtremeNumbersOnTheWire()
        #expect(problems.isEmpty, "\(problems)")
    }
}

// MARK: - D3 from the wire: long numbers for a Double argument

/// Calls a tool whose argument is a `Double` with long numbers, in a child process: 20,000
/// digits, and four megabytes. Exits with status 3 on a wrong answer, so that it is told apart
/// from a trap. Both codecs let the tool convert the complete number to Double and halve it.
private func round2LongNumbersForADouble() async {
    let server = try! Server(name: "wire", version: "1") { R2MHalf() }
    let client = TestClient(server)
    let fourMiB = 4 * 1024 * 1024
    let texts = [
        "2" + String(repeating: "0", count: 20_000) + "e-20000",
        "0." + String(repeating: "0", count: fourMiB) + "5e\(fourMiB + 1)",
        "-" + String(repeating: "3", count: fourMiB) + "e-\(fourMiB - 1)",
    ]
    let expected: [Double] = [1, 2.5, -1.6666666666666667]
    for (text, half) in zip(texts, expected) {
        _ = client.post("tools/call", ["name": "r2_m_half", "arguments": ["x": .number(JSONNumber(lexeme: text)!)]])
        let answer = try? await client.next(timeout: .seconds(10))
        if answer?["result"]?["structuredContent"]?.doubleValue != half { exit(3) }
    }
    await client.close()
}

@Suite struct Round2LongNumberOnTheWireTests {
    @Test func longNumbersForADoubleArgumentAreAnsweredExactly() async {
        await #expect(processExitsWith: .success) { await round2LongNumbersForADouble() }
    }
}
