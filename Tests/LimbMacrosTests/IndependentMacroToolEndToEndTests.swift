import Limb
import LimbTesting
import Synchronization
import Testing


// MARK: - Fixtures

@Schema
private struct IMRunPoint: Equatable {
    var x: Int
    var y: Int
    var label: String?
}

@Schema
private enum IMRunMode: String { case fast, slow }

/// A fixture.
@Tool private struct IMRunPing { func call() -> String { "pong" } }
/// A fixture.
@Tool private struct IMRunNothing { func call() {} }

/// Echoes everything it was given.
@Tool
private struct IMRunEcho {
    func call(
        text: String, flag: Bool, count: Int, wide: Int64, ratio: Double, list: [String], map: [String: Int], point: IMRunPoint,
        mode: IMRunMode, any: JSONValue
    ) -> JSONValue {
        [
            "text": .string(text), "flag": .bool(flag), "count": JSONValue(count), "wide": wide.jsonValue, "ratio": JSONValue(ratio),
            "list": list.jsonValue, "map": map.jsonValue, "point": point.jsonValue, "mode": mode.jsonValue, "any": any,
        ]
    }
}

/// A fixture.
@Tool
private struct IMRunDefaults {
    func call(
        required: String, text: String = "dflt", flag: Bool = true, count: Int = 42, ratio: Double = 1.5, list: [Int] = [1, 2],
        map: [String: Int] = ["a": 1], mode: IMRunMode = .slow, maybe: Int? = nil, maybeSeven: Int? = 7
    ) -> JSONValue {
        [
            "required": .string(required), "text": .string(text), "flag": .bool(flag), "count": JSONValue(count),
            "ratio": JSONValue(ratio), "list": list.jsonValue, "map": map.jsonValue, "mode": mode.jsonValue, "maybe": maybe.jsonValue,
            "maybeSeven": maybeSeven.jsonValue,
        ]
    }
}

/// A fixture.
@Tool
private struct IMRunOptionals {
    func call(text: String?, count: Int?, point: IMRunPoint?, list: [String]?) -> JSONValue {
        ["text": text.jsonValue, "count": count.jsonValue, "point": point.jsonValue, "list": list.jsonValue]
    }
}

/// A fixture.
@Tool
private struct IMRunContext {
    func call(a: Int, context: ToolContext, b: Int) -> String { "\(context.method) \(context.protocolVersion) \(a + b)" }
}

/// A fixture.
@Tool
private struct IMRunContextFirst {
    func call(_ ctx: RequestContext, _ a: Int) -> String { "\(ctx.method) \(a)" }
}

/// A fixture.
@Tool
private struct IMRunPointResult {
    func call(x: Int, y: Int, label: String?) -> IMRunPoint { IMRunPoint(x: x, y: y, label: label) }
}

/// A fixture.
@Tool
private struct IMRunPoints {
    func call(n: Int) -> [IMRunPoint] { (0..<n).map { IMRunPoint(x: $0, y: -$0, label: nil) } }
}

/// A fixture.
@Tool private struct IMRunStrings { func call() -> [String] { ["a", "b"] } }
/// A fixture.
@Tool private struct IMRunSum { func call(a: Int, b: Int) -> Int { a + b } }
/// A fixture.
@Tool private struct IMRunDictionary { func call() -> [String: Int] { ["b": 2, "a": 1] } }

/// A fixture.
@Tool
private struct IMRunReady {
    func call(fail: Bool) -> ToolResult {
        fail ? .error("ready-made failure") : ToolResult(content: [.text("one"), .text("two")], structuredContent: ["k": 1])
    }
}

/// A fixture.
@Tool private struct IMRunBlock { func call() -> ContentBlock { .text("block") } }

/// A fixture.
@Tool
private struct IMRunBlocks {
    func call() -> [ContentBlock] { [.text("a"), .image(data: "AAAA", mimeType: "image/png")] }
}

/// Values with holes in them: optional elements, optional members.
@Schema
private struct IMRunSparse: Equatable {
    var list: [Int?]
    var map: [String: String?]
    var maybe: IMRunPoint?
}

/// Echoes a sparse value.
@Tool
private struct IMRunSparseEcho {
    func call(list: [Int?], map: [String: String?] = [:], maybe: IMRunPoint?) -> IMRunSparse {
        IMRunSparse(list: list, map: map, maybe: maybe)
    }
}

/// A lookup that may find nothing.
@Tool
private struct IMRunMaybePoint {
    func call(found: Bool) -> IMRunPoint? { found ? IMRunPoint(x: 1, y: 2, label: "hit") : nil }
}

private struct IMRunSecret: Error, CustomStringConvertible {
    var description: String { "secret-detail-9143" }
}

/// A fixture.
@Tool
private struct IMRunFailing {
    func call(mode: String) async throws -> String {
        switch mode {
        case "tool": throw ToolError("the tool says no")
        case "protocol": throw MCPError.invalidParams("custom protocol failure")
        case "other": throw IMRunSecret()
        default: return "fine"
        }
    }
}

/// A fixture.
@Tool
private struct IMRunSyncThrows {
    func call(fail: Bool) throws -> IMRunPoint {
        if fail { throw ToolError("sync failure") }
        return IMRunPoint(x: 0, y: 0, label: nil)
    }
}

/// A fixture.
@Tool
private struct IMRunTypedThrows {
    func call(fail: Bool) throws(ToolError) -> String {
        if fail { throw ToolError("typed failure") }
        return "typed ok"
    }
}

/// A fixture.
@Tool
private struct IMRunAsync {
    func call(a: Int) async -> Int {
        await Task.yield()
        return a * 2
    }
}

private final class IMRunStore: Sendable {
    let hits = Mutex(0)
}

/// Uses its dependencies.
@Tool
private struct IMRunDependent {
    let prefix: String
    let store: IMRunStore
    let limit: Int

    func call(text: String, limit: Int = 100) -> String {
        store.hits.withLock { $0 += 1 }
        return prefix + String(text.prefix(min(limit, self.limit)))
    }
}

/// A fixture.
@Tool
private actor IMRunCounter {
    var total = 0
    func call(by: Int = 1) -> Int {
        total += by
        return total
    }
}

/// A fixture.
@Tool
private final class IMRunClassTool {
    let base: Int
    init(base: Int) { self.base = base }
    func call(x: Int) -> Int { base + x }
}

private enum IMRunFlags {
    static let off = false
    static let on = true
}

// Default values that are expressions, not single literals.
/// A fixture.
@Tool private struct IMRunDefaultOr { func call(strict: Bool = IMRunFlags.off || IMRunFlags.on) -> String { "\(strict)" } }
/// A fixture.
@Tool private struct IMRunDefaultTernary { func call(count: Int = IMRunFlags.on ? 1 : 2) -> String { "\(count)" } }
/// A fixture.
@Tool private struct IMRunDefaultCompare { func call(strict: Bool = 1 < 2) -> String { "\(strict)" } }
/// A fixture.
@Tool private struct IMRunDefaultArithmetic { func call(count: Int = 1 + 2 * 3) -> String { "\(count)" } }

/// A fixture.
@Tool
private struct IMRunLabels {
    func call(for location: String, _ count: Int, from start: Int = 0) -> String { "\(location) \(count) \(start)" }
}

/// A fixture.
@Tool
private struct IMRunKeywordLabels {
    func call(in place: String, default fallback: Int = 1, class kind: String?) -> String { "\(place) \(fallback) \(kind ?? "-")" }
}

private func makeServer(store: IMRunStore = IMRunStore()) throws -> Server {
    try Server(name: "independent-macro", version: "1.0.0") {
        IMRunPing()
        IMRunNothing()
        IMRunEcho()
        IMRunDefaults()
        IMRunOptionals()
        IMRunContext()
        IMRunContextFirst()
        IMRunPointResult()
        IMRunPoints()
        IMRunStrings()
        IMRunSum()
        IMRunDictionary()
        IMRunReady()
        IMRunBlock()
        IMRunBlocks()
        IMRunMaybePoint()
        IMRunSparseEcho()
        IMRunFailing()
        IMRunSyncThrows()
        IMRunTypedThrows()
        IMRunAsync()
        IMRunDependent(prefix: ">", store: store, limit: 4)
        IMRunCounter()
        IMRunClassTool(base: 10)
        IMRunDefaultOr()
        IMRunDefaultTernary()
        IMRunDefaultCompare()
        IMRunDefaultArithmetic()
        IMRunLabels()
        IMRunKeywordLabels()
    }
}

private let echoArguments: JSONObject = [
    "text": "héllo \"w\"\n\\(x) 😀", "flag": true, "count": -7, "wide": 9_007_199_254_740_993, "ratio": 2.5, "list": ["a", ""],
    "map": ["b": 2, "a": 1], "point": ["x": 1, "y": 2, "label": "p"], "mode": "fast", "any": ["free": [1, nil, "x"]],
]

/// A tool execution error: a result, not a JSON-RPC error, with `isError: true` and a text the
/// model can read.
private func expectToolError(
    _ response: JSONValue, mentioning fragments: [String], sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(response["error"] == nil, "expected a tool result, got a protocol error: \(response)", sourceLocation: sourceLocation)
    #expect(response["result"]?["isError"] == true, "\(response)", sourceLocation: sourceLocation)
    let text = response.independentMacroFirstText ?? ""
    for fragment in fragments {
        #expect(text.contains(fragment), "\"\(fragment)\" is not mentioned in: \(text)", sourceLocation: sourceLocation)
    }
}

// MARK: - Calls

@Suite struct IndependentMacroToolCallTests {
    @Test func listingShowsEveryToolInRegistrationOrder() async throws {
        let client = TestClient(try makeServer())
        let tools = try await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.count == 30)
        #expect(tools.first?["name"] == "im_run_ping")
        #expect(tools.last?["name"] == "im_run_keyword_labels")
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == "object", "\(tool)")
            if let schema = tool["inputSchema"]?.objectValue { IndependentMacroCheckSchema(schema) }
            if let schema = tool["outputSchema"]?.objectValue { IndependentMacroCheckSchema(schema) }
        }
        let echo = try #require(try await client.independentMacroListed("im_run_echo"))
        #expect(echo["description"] == "Echoes everything it was given.")
        #expect(echo["inputSchema"] == .object(IMRunEcho.definition.inputSchema))
    }

    @Test func aToolWithoutArgumentsAcceptsAbsentEmptyAndNullArguments() async throws {
        let client = TestClient(try makeServer())
        for arguments: JSONValue? in [nil, [:], .null] {
            let response = try await client.independentMacroCall("im_run_ping", arguments)
            #expect(response.independentMacroFirstText == "pong", "\(String(describing: arguments))")
            #expect(response["result"]?["isError"] == false)
            #expect(response["result"]?["structuredContent"] == nil)
        }
        let nothing = try await client.independentMacroCall("im_run_nothing")
        #expect(nothing["result"]?["content"] == [])
        #expect(nothing["result"]?["isError"] == false)
        #expect(nothing["result"]?["structuredContent"] == nil)
    }

    @Test func everyArgumentTypeArrivesIntact() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("im_run_echo", .object(echoArguments))
        #expect(response["result"]?["isError"] == false)
        #expect(response["result"]?["structuredContent"] == .object(echoArguments))
    }

    @Test func numbersAreReadByValueNotBySpelling() async throws {
        let client = TestClient(try makeServer())
        // JSON Schema: 3.0 and 1e2 are integers; 2 is a number.
        let arguments = try JSON.parse(
            Array(
                """
                {"text":"","flag":false,"count":3.0,"wide":1e2,"ratio":2,"list":[],"map":{},"point":{"x":1.0,"y":0},"mode":"slow","any":null}
                """.utf8))
        let response = try await client.independentMacroCall("im_run_echo", arguments)
        let echoed = response["result"]?["structuredContent"]
        #expect(echoed?["count"]?.intValue == 3)
        #expect(echoed?["wide"]?.intValue == 100)
        #expect(echoed?["ratio"]?.doubleValue == 2)
        #expect(echoed?["point"]?["x"]?.intValue == 1)
        #expect(echoed?["any"] == .null)
    }

    @Test func wrongTypedArgumentsAreToolErrorsNamingTheArgument() async throws {
        let client = TestClient(try makeServer())
        let wrong: [(String, JSONValue)] = [
            ("text", 1), ("flag", "yes"), ("count", "7"), ("count", 1.5), ("wide", true), ("ratio", "2.5"), ("list", "a"), ("list", [1]),
            ("map", []), ("map", ["a": "one"]), ("point", "p"), ("point", ["x": 1]), ("point", ["x": "1", "y": 2]), ("mode", "medium"),
            ("mode", 1),
        ]
        for (key, value) in wrong {
            var arguments = echoArguments
            arguments[key] = value
            let response = try await client.independentMacroCall("im_run_echo", .object(arguments))
            expectToolError(response, mentioning: [key])
        }
    }

    @Test func missingArgumentsAreToolErrorsNamingTheArgument() async throws {
        let client = TestClient(try makeServer())
        for key in echoArguments.map(\.key) {
            var arguments = echoArguments
            arguments.removeValue(forKey: key)
            let response = try await client.independentMacroCall("im_run_echo", .object(arguments))
            expectToolError(response, mentioning: [key])
        }
        expectToolError(try await client.independentMacroCall("im_run_echo"), mentioning: [])
        expectToolError(try await client.independentMacroCall("im_run_echo", [:]), mentioning: [])
    }

    @Test func nullForARequiredArgumentIsAToolErrorNamingIt() async throws {
        let client = TestClient(try makeServer())
        for key in echoArguments.map(\.key) where key != "any" {
            var arguments = echoArguments
            arguments[key] = .null
            let response = try await client.independentMacroCall("im_run_echo", .object(arguments))
            expectToolError(response, mentioning: [key])
        }
        // `any` is a free-form value: `null` is one of its values.
        var arguments = echoArguments
        arguments["any"] = .null
        let response = try await client.independentMacroCall("im_run_echo", .object(arguments))
        #expect(response["result"]?["structuredContent"]?["any"] == .null)
        #expect(response["result"]?["isError"] == false)
    }

    // observed, unspecified: arguments the tool does not declare are accepted and ignored (the
    // generated input schema has no "additionalProperties": false).
    @Test func extraArgumentsAreIgnored() async throws {
        let client = TestClient(try makeServer())
        var arguments = echoArguments
        arguments["unexpected"] = ["x": 1]
        let response = try await client.independentMacroCall("im_run_echo", .object(arguments))
        #expect(response["result"]?["isError"] == false)
        #expect(response["result"]?["structuredContent"] == .object(echoArguments))
        let ping = try await client.independentMacroCall("im_run_ping", ["unexpected": 1])
        #expect(ping.independentMacroFirstText == "pong")
    }

    @Test func argumentsThatAreNotAnObjectAreAProtocolError() async throws {
        let client = TestClient(try makeServer())
        for arguments: JSONValue in ["text", [1], 1, true] {
            let response = try await client.independentMacroCall("im_run_ping", arguments)
            #expect(response["error"]?["code"] == -32602, "\(arguments)")
        }
        #expect(try await client.independentMacroCall("no_such_tool")["error"]?["code"] == -32602)
    }

    @Test func defaultsAreUsedForAbsentArguments() async throws {
        let client = TestClient(try makeServer())
        let minimal = try await client.independentMacroCall("im_run_defaults", ["required": "r"])
        #expect(minimal["result"]?["isError"] == false)
        #expect(
            minimal["result"]?["structuredContent"]
                == [
                    "required": "r", "text": "dflt", "flag": true, "count": 42, "ratio": 1.5, "list": [1, 2], "map": ["a": 1],
                    "mode": "slow", "maybe": nil, "maybeSeven": 7,
                ])

        let explicit: JSONObject = [
            "required": "r", "text": "", "flag": false, "count": 0, "ratio": 0.0, "list": [], "map": [:], "mode": "fast", "maybe": 5,
            "maybeSeven": 8,
        ]
        let full = try await client.independentMacroCall("im_run_defaults", .object(explicit))
        #expect(full["result"]?["structuredContent"] == .object(explicit))

        // A present argument of the wrong type is an error, not a fall back to the default.
        expectToolError(try await client.independentMacroCall("im_run_defaults", ["required": "r", "count": "many"]), mentioning: ["count"])
        expectToolError(try await client.independentMacroCall("im_run_defaults", ["text": "t"]), mentioning: ["required"])
    }

    @Test func optionalArgumentsMayBeAbsent() async throws {
        let client = TestClient(try makeServer())
        let absent = try await client.independentMacroCall("im_run_optionals", [:])
        #expect(absent["result"]?["structuredContent"] == ["text": nil, "count": nil, "point": nil, "list": nil])
        let none = try await client.independentMacroCall("im_run_optionals")
        #expect(none["result"]?["structuredContent"] == ["text": nil, "count": nil, "point": nil, "list": nil])
        let present = try await client.independentMacroCall(
            "im_run_optionals", ["text": "t", "count": 1, "point": ["x": 1, "y": 2], "list": ["l"]])
        #expect(present["result"]?["structuredContent"] == ["text": "t", "count": 1, "point": ["x": 1, "y": 2], "list": ["l"]])
        expectToolError(try await client.independentMacroCall("im_run_optionals", ["count": "1"]), mentioning: ["count"])
        expectToolError(try await client.independentMacroCall("im_run_optionals", ["point": ["x": 1]]), mentioning: ["point", "y"])
    }

    @Test func explicitNullForAnOptionalArgumentMeansAbsent() async throws {
        let client = TestClient(try makeServer())
        let listed = try #require(try await client.independentMacroListed("im_run_optionals"))
        #expect(listed["inputSchema"]?["properties"]?["count"] == ["anyOf": [["type": "integer"], ["type": "null"]]])
        #expect(listed["inputSchema"]?["required"] == [])

        let nulls = try await client.independentMacroCall("im_run_optionals", ["text": nil, "count": nil, "point": nil, "list": nil])
        #expect(nulls["result"]?["isError"] == false, "\(nulls)")
        #expect(nulls["result"]?["structuredContent"] == ["text": nil, "count": nil, "point": nil, "list": nil])

        // With a default, `null` yields the default, whatever the default is.
        let defaults = try await client.independentMacroCall("im_run_defaults", ["required": "r", "maybe": nil, "maybeSeven": nil])
        #expect(defaults["result"]?["isError"] == false, "\(defaults)")
        #expect(defaults["result"]?["structuredContent"]?["maybe"] == .null)
        #expect(defaults["result"]?["structuredContent"]?["maybeSeven"] == 7)

        // `null` is still not a value of the wrapped type: inside an optional object, a
        // required member cannot be null, and a wrong type is still wrong.
        expectToolError(try await client.independentMacroCall("im_run_optionals", ["point": ["x": nil, "y": 1]]), mentioning: ["point"])
        expectToolError(try await client.independentMacroCall("im_run_optionals", ["list": [nil]]), mentioning: ["list"])
        expectToolError(try await client.independentMacroCall("im_run_optionals", ["count": false]), mentioning: ["count"])
    }

    // observed: an argument that has a default but is not optional keeps the plain schema of
    // its type, so `null` for it is a validation error — although the generated decoder would
    // read `null` as "use the default". The schema decides, because it runs first.
    @Test func explicitNullForANonOptionalArgumentWithADefaultIsRejected() async throws {
        let client = TestClient(try makeServer())
        expectToolError(try await client.independentMacroCall("im_run_defaults", ["required": "r", "count": nil]), mentioning: ["count"])
        expectToolError(try await client.independentMacroCall("im_run_defaults", ["required": nil]), mentioning: ["required"])
    }

    /// Optional elements travel as `null` in both directions, and the result — which has a
    /// declared output schema — passes the server's own check of `structuredContent`.
    @Test func optionalElementsInArgumentsAndResults() async throws {
        let client = TestClient(try makeServer())
        let listed = try #require(try await client.independentMacroListed("im_run_sparse_echo"))
        let integerOrNull: JSONValue = ["anyOf": [["type": "integer"], ["type": "null"]]]
        #expect(listed["inputSchema"]?["properties"]?["list"] == ["type": "array", "items": integerOrNull])
        #expect(listed["inputSchema"]?["required"] == ["list"])
        #expect(listed["outputSchema"] == .object(IMRunSparse.jsonSchema))
        #expect(listed["outputSchema"]?["type"] == "object")

        let response = try await client.independentMacroCall(
            "im_run_sparse_echo", ["list": [1, nil, 3], "map": ["a": nil, "b": "x"], "maybe": ["x": 1, "y": 2, "label": nil]])
        #expect(response["error"] == nil, "\(response)")
        #expect(response["result"]?["isError"] == false)
        #expect(response["result"]?["structuredContent"] == ["list": [1, nil, 3], "map": ["a": nil, "b": "x"], "maybe": ["x": 1, "y": 2]])

        let holes = try await client.independentMacroCall("im_run_sparse_echo", ["list": [nil, nil], "maybe": nil])
        #expect(holes["result"]?["structuredContent"] == ["list": [nil, nil], "map": [:]])

        expectToolError(try await client.independentMacroCall("im_run_sparse_echo", ["list": [1, "x"]]), mentioning: ["list"])
        expectToolError(try await client.independentMacroCall("im_run_sparse_echo", ["list": nil]), mentioning: ["list"])
        expectToolError(try await client.independentMacroCall("im_run_sparse_echo", ["list": [], "map": ["a": 1]]), mentioning: ["map"])
    }

    @Test func theContextIsPassedInAnyPosition() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_run_context", ["a": 2, "b": 3]).independentMacroFirstText == "tools/call 2026-07-28 5")
        #expect(try await client.independentMacroCall("im_run_context_first", ["a": 9]).independentMacroFirstText == "tools/call 9")
        // `context` is not an argument: sending one changes nothing, omitting `b` is an error.
        expectToolError(try await client.independentMacroCall("im_run_context", ["a": 2]), mentioning: ["b"])
    }

    @Test func labelsAndUnlabeledParameters() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_run_labels", ["for": "Oslo", "count": 2]).independentMacroFirstText == "Oslo 2 0")
        #expect(
            try await client.independentMacroCall("im_run_labels", ["for": "Oslo", "count": 2, "from": 5]).independentMacroFirstText == "Oslo 2 5")
        #expect(
            try await client.independentMacroCall("im_run_keyword_labels", ["in": "here", "class": "k"]).independentMacroFirstText == "here 1 k")
        #expect(
            try await client.independentMacroCall("im_run_keyword_labels", ["in": "here", "default": 4]).independentMacroFirstText == "here 4 -")
    }

    @Test func dependenciesAreUsedAndAreNotArguments() async throws {
        let store = IMRunStore()
        let client = TestClient(try makeServer(store: store))
        #expect(try await client.independentMacroCall("im_run_dependent", ["text": "abcdefgh"]).independentMacroFirstText == ">abcd")
        #expect(try await client.independentMacroCall("im_run_dependent", ["text": "abcdefgh", "limit": 2]).independentMacroFirstText == ">ab")
        // Sending a dependency's name as an argument does not override the dependency.
        #expect(
            try await client.independentMacroCall("im_run_dependent", ["text": "abcdefgh", "prefix": "!"]).independentMacroFirstText == ">abcd")
        #expect(store.hits.withLock { $0 } == 3)
        let listed = try #require(try await client.independentMacroListed("im_run_dependent"))
        #if FoundationJSON
        #expect(listed["inputSchema"]?["properties"]?.objectValue?.map(\.key).sorted() == ["limit", "text"])
        #else
        #expect(listed["inputSchema"]?["properties"]?.objectValue?.map(\.key) == ["text", "limit"])
        #endif
        #expect(listed["inputSchema"]?["required"] == ["text"])
    }

    @Test func actorsAndClassesAreTools() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_run_counter").independentMacroResult?["structuredContent"] == 1)
        #expect(try await client.independentMacroCall("im_run_counter", ["by": 2]).independentMacroResult?["structuredContent"] == 3)
        #expect(try await client.independentMacroCall("im_run_counter", [:]).independentMacroResult?["structuredContent"] == 4)
        #expect(try await client.independentMacroCall("im_run_class_tool", ["x": 5]).independentMacroResult?["structuredContent"] == 15)
        #expect(try await client.independentMacroCall("im_run_async", ["a": 21]).independentMacroResult?["structuredContent"] == 42)
    }
}

// MARK: - Default values that are expressions

@Suite struct IndependentMacroToolDefaultExpressionTests {
    /// `strict: Bool = off || on` — an argument that is present must win over the default.
    @Test func explicitValueWinsOverADefaultWithALogicalOperator() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_run_default_or").independentMacroFirstText == "true")
        #expect(try await client.independentMacroCall("im_run_default_or", ["strict": true]).independentMacroFirstText == "true")
        #expect(try await client.independentMacroCall("im_run_default_or", ["strict": false]).independentMacroFirstText == "false")
    }

    /// `count: Int = flag ? 1 : 2`.
    @Test func explicitValueWinsOverATernaryDefault() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_run_default_ternary").independentMacroFirstText == "1")
        let explicit = try await client.independentMacroCall("im_run_default_ternary", ["count": 5])
        #expect(explicit["error"] == nil, "\(explicit)")
        #expect(explicit.independentMacroFirstText == "5")
    }

    /// `strict: Bool = 1 < 2`.
    @Test func explicitValueWinsOverAComparisonDefault() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_run_default_compare").independentMacroFirstText == "true")
        let explicit = try await client.independentMacroCall("im_run_default_compare", ["strict": false])
        #expect(explicit["error"] == nil, "\(explicit)")
        #expect(explicit.independentMacroFirstText == "false")
    }

    @Test func arithmeticDefault() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_run_default_arithmetic").independentMacroFirstText == "7")
        #expect(try await client.independentMacroCall("im_run_default_arithmetic", ["count": 0]).independentMacroFirstText == "0")
    }
}

// MARK: - Results

@Suite struct IndependentMacroToolResultTests {
    /// tools.mdx: structured content conforms to the output schema, and "a tool that returns
    /// structured content SHOULD also return the serialized JSON in a TextContent block".
    @Test func aSchemaTypeBecomesStructuredContent() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("im_run_point_result", ["x": 1, "y": -2, "label": "p"])
        let result = try #require(response["result"])
        #expect(result["structuredContent"] == ["x": 1, "y": -2, "label": "p"])
        #expect(result["isError"] == false)
        #expect(result["content"]?.arrayValue?.count == 1)
        #expect(result["content"]?[0]?["type"] == "text")
        let text = try #require(result["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(Array(text.utf8)) == ["x": 1, "y": -2, "label": "p"])
        #expect(try JSONSchema(.object(IMRunPoint.jsonSchema)).validate(result["structuredContent"] ?? .null) == nil)

        // An absent optional is left out rather than sent as null.
        let bare = try await client.independentMacroCall("im_run_point_result", ["x": 0, "y": 0])
        #expect(bare["result"]?["structuredContent"] == ["x": 0, "y": 0])
    }

    @Test func generatedValuesSurviveTheRoundTripThroughTheServer() async throws {
        let client = TestClient(try makeServer())
        var random = IndependentMacroRandom(seed: 0xE2E)
        for _ in 0..<50 {
            let point = IMRunPoint(x: random.int(), y: random.int(), label: Bool.random(using: &random) ? random.string() : nil)
            let response = try await client.independentMacroCall("im_run_point_result", point.jsonValue)
            let structured = try #require(response["result"]?["structuredContent"], "\(point): \(response)")
            #expect(try IMRunPoint(json: structured) == point)
        }
    }

    @Test func scalarsAndArraysAreStructuredContentForModernClients() async throws {
        let client = TestClient(try makeServer())
        let sum = try await client.independentMacroCall("im_run_sum", ["a": 2, "b": 3])
        #expect(sum["result"]?["structuredContent"] == 5)
        #expect(sum.independentMacroFirstText == "5")

        let points = try await client.independentMacroCall("im_run_points", ["n": 2])
        #expect(points["result"]?["structuredContent"] == [["x": 0, "y": 0], ["x": 1, "y": -1]])
        let text = try #require(points.independentMacroFirstText)
        #expect(try JSON.parse(Array(text.utf8)) == [["x": 0, "y": 0], ["x": 1, "y": -1]])

        let strings = try await client.independentMacroCall("im_run_strings")
        #expect(strings["result"]?["structuredContent"] == ["a", "b"])

        let dictionary = try await client.independentMacroCall("im_run_dictionary")
        #expect(dictionary["result"]?["structuredContent"] == ["a": 1, "b": 2])
        #expect(dictionary["result"]?["isError"] == false)
    }

    /// Before 2026-07-28 `structuredContent` must be an object, so other results travel as text.
    @Test func nonObjectResultsTravelAsTextForLegacyClients() async throws {
        for version in [ProtocolVersion.v2025_11_25, .v2025_06_18] {
            let client = TestClient(try makeServer(), modern: false)
            try await client.initialize(version: version)
            let points = try await client.independentMacroCall("im_run_points", ["n": 1])
            #expect(points["result"]?["structuredContent"] == nil, "\(version)")
            let text = try #require(points.independentMacroFirstText, "\(version)")
            #expect(try JSON.parse(Array(text.utf8)) == [["x": 0, "y": 0]], "\(version)")
            #expect(try await client.independentMacroCall("im_run_sum", ["a": 2, "b": 3]).independentMacroFirstText == "5", "\(version)")

            let point = try await client.independentMacroCall("im_run_point_result", ["x": 1, "y": 2])
            #expect(point["result"]?["structuredContent"] == ["x": 1, "y": 2], "\(version)")
        }
        // 2025-03-26 has no structured content at all.
        let oldest = TestClient(try makeServer(), modern: false)
        try await oldest.initialize(version: .v2025_03_26)
        let point = try await oldest.independentMacroCall("im_run_point_result", ["x": 1, "y": 2])
        #expect(point["result"]?["structuredContent"] == nil)
        let text = try #require(point.independentMacroFirstText)
        #expect(try JSON.parse(Array(text.utf8)) == ["x": 1, "y": 2])
    }

    @Test func aStringIsTextContent() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("im_run_ping")
        #expect(response["result"]?["content"] == [["type": "text", "text": "pong"]])
        #expect(response["result"]?["structuredContent"] == nil)
    }

    @Test func aReadyToolResultPassesThrough() async throws {
        let client = TestClient(try makeServer())
        let ready = try await client.independentMacroCall("im_run_ready", ["fail": false])
        #expect(ready["result"]?["content"] == [["type": "text", "text": "one"], ["type": "text", "text": "two"]])
        #expect(ready["result"]?["structuredContent"] == ["k": 1])
        #expect(ready["result"]?["isError"] == false)
        let failed = try await client.independentMacroCall("im_run_ready", ["fail": true])
        #expect(failed["result"]?["isError"] == true)
        #expect(failed.independentMacroFirstText == "ready-made failure")
    }

    @Test func contentBlocksPassThrough() async throws {
        let client = TestClient(try makeServer())
        let block = try await client.independentMacroCall("im_run_block")
        #expect(block["result"]?["content"] == [["type": "text", "text": "block"]])
        #expect(block["result"]?["structuredContent"] == nil)
        let blocks = try await client.independentMacroCall("im_run_blocks")
        #expect(
            blocks["result"]?["content"]
                == [["type": "text", "text": "a"], ["type": "image", "data": "AAAA", "mimeType": "image/png"]])
    }

    @Test func anOptionalResultMayBeNil() async throws {
        let client = TestClient(try makeServer())
        let found = try await client.independentMacroCall("im_run_maybe_point", ["found": true])
        #expect(found["result"]?["structuredContent"] == ["x": 1, "y": 2, "label": "hit"])

        let missing = try await client.independentMacroCall("im_run_maybe_point", ["found": false])
        #expect(missing["error"] == nil, "returning nil is answered with a protocol error: \(missing)")
        #expect(missing["result"]?["isError"] == false)
        // CallToolResult in schema.ts (2026-07-28): structured content "can be any JSON value
        // (object, array, string, number, boolean, or null)".
        #expect(missing["result"]?["structuredContent"] == .null)
        #expect(missing.independentMacroFirstText == "null")
    }

    // observed: the schema of `IMRunPoint?` is "IMRunPoint or null", which is not an object
    // schema, so — like every non-object result — the tool declares no output schema at all,
    // in any revision. Before 2026-07-28 `structuredContent` has to be an object, so `nil`
    // travels as the text "null" there.
    @Test func anOptionalResultDeclaresNoOutputSchema() async throws {
        #expect(IMRunMaybePoint.definition.outputSchema == nil)
        let legacy = TestClient(try makeServer(), modern: false)
        try await legacy.initialize(version: .v2025_11_25)
        let missing = try await legacy.independentMacroCall("im_run_maybe_point", ["found": false])
        #expect(missing["result"]?["structuredContent"] == nil)
        #expect(missing.independentMacroFirstText == "null")
        #expect(missing["result"]?["isError"] == false)
        let found = try await legacy.independentMacroCall("im_run_maybe_point", ["found": true])
        #expect(found["result"]?["structuredContent"] == ["x": 1, "y": 2, "label": "hit"])
    }
}

// MARK: - Failures

@Suite struct IndependentMacroToolFailureTests {
    @Test func aToolErrorIsAResultTheModelCanRead() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("im_run_failing", ["mode": "tool"])
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"] == true)
        #expect(response.independentMacroFirstText == "the tool says no")
        #expect(try await client.independentMacroCall("im_run_failing", ["mode": "ok"]).independentMacroFirstText == "fine")

        let sync = try await client.independentMacroCall("im_run_sync_throws", ["fail": true])
        #expect(sync["result"]?["isError"] == true)
        #expect(sync.independentMacroFirstText == "sync failure")
        #expect(try await client.independentMacroCall("im_run_sync_throws", ["fail": false])["result"]?["structuredContent"] == ["x": 0, "y": 0])

        let typed = try await client.independentMacroCall("im_run_typed_throws", ["fail": true])
        #expect(typed["result"]?["isError"] == true)
        #expect(typed.independentMacroFirstText == "typed failure")
        #expect(try await client.independentMacroCall("im_run_typed_throws", ["fail": false]).independentMacroFirstText == "typed ok")
    }

    @Test func aProtocolErrorKeepsItsCode() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("im_run_failing", ["mode": "protocol"])
        #expect(response["result"] == nil)
        #expect(response["error"]?["code"] == -32602)
        #expect(response["error"]?["message"]?.stringValue?.contains("custom protocol failure") == true)
    }

    @Test func anUnexpectedErrorIsAnInternalErrorWithoutDetails() async throws {
        let server = try makeServer()
        let client = TestClient(server)
        let response = try await client.independentMacroCall("im_run_failing", ["mode": "other"])
        #expect(response["result"] == nil)
        #expect(response["error"]?["code"] == -32603)
        #expect(!"\(response)".contains("secret-detail-9143"))
        // The server keeps working afterwards.
        #expect(try await client.independentMacroCall("im_run_ping").independentMacroFirstText == "pong")
    }

    @Test func argumentViolationsFollowTheRevision() async throws {
        for version in [ProtocolVersion.v2025_03_26, .v2025_06_18] {
            let client = TestClient(try makeServer(), modern: false)
            try await client.initialize(version: version)
            let response = try await client.independentMacroCall("im_run_sum", ["a": "1", "b": 2])
            #expect(response["error"]?["code"] == -32602, "\(version)")
            #expect(response["error"]?["message"]?.stringValue?.contains("a") == true, "\(version)")
            let missing = try await client.independentMacroCall("im_run_sum", ["a": 1])
            #expect(missing["error"]?["code"] == -32602, "\(version)")
            #expect(missing["error"]?["message"]?.stringValue?.contains("b") == true, "\(version)")
        }
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize(version: .v2025_11_25)
        expectToolError(try await client.independentMacroCall("im_run_sum", ["a": "1", "b": 2]), mentioning: ["a"])
        expectToolError(try await client.independentMacroCall("im_run_sum", ["a": 1]), mentioning: ["b"])
    }

    @Test func anIntegerOutOfRangeIsAToolError() async throws {
        let client = TestClient(try makeServer())
        var lexemes = ["9223372036854775808", "1e30"]
        #if !FoundationJSON
        lexemes.append("-9223372036854775809")
        #endif
        for lexeme in lexemes {
            let arguments = try JSON.parse(Array("{\"a\":\(lexeme),\"b\":1}".utf8))
            let response = try await client.independentMacroCall("im_run_sum", arguments)
            expectToolError(response, mentioning: ["a", "out of range"])
        }
        // …and, like every argument violation, a `-32602` before 2025-11-25.
        let legacy = TestClient(try makeServer(), modern: false)
        try await legacy.initialize(version: .v2025_06_18)
        let response = try await legacy.independentMacroCall("im_run_sum", try JSON.parse(Array("{\"a\":1e30,\"b\":1}".utf8)))
        #expect(response["result"] == nil, "\(response)")
        #expect(response["error"]?["code"] == -32602)
        #expect(response["error"]?["message"]?.stringValue?.contains("out of range") == true)
        #if !FoundationJSON
        let huge = try #require(JSONNumber(lexeme: "1e999"))
        let modern = try await client.independentMacroCall("im_run_echo", .object(echoArguments.merging(["ratio": .number(huge)])))
        expectToolError(modern, mentioning: ["ratio"])
        #endif
    }
}
