import Limb
import LimbTesting
import Synchronization
import Testing


// MARK: - Fixtures

@Schema
private struct IMDefPoint: Equatable {
    var x: Int
    var y: Int
    static let origin = IMDefPoint(x: 0, y: 0)
    static func at(_ x: Int) -> IMDefPoint { IMDefPoint(x: x, y: 0) }
}

@Schema
private enum IMDefUnits: String {
    case metric, imperial
    static let preferred = IMDefUnits.imperial
}

/// A default of every kind.
@Tool
private struct IMDefEverything {
    static let limit = 7
    private static let hidden = "h"
    static var computed: Double { 2.5 }
    static func make(_ count: Int = 2) -> [Int] { Array(repeating: count, count: count) }

    func call(
        i: Int = 1, neg: Int = -1, hex: Int = 0xFF, big: Int64 = 1 << 40, sep: Int = 1_000,
        d: Double = 1.5, dInt: Double = 2, exp: Double = 1e-3,
        s: String = "plain", esc: String = "q\"\\\n", raw: String = #"r\n"#, interp: String = "a\(1 + 1)b",
        multi: String = """
            two
            lines
            """,
        b: Bool = true, nb: Bool = !true,
        arr: [Int] = [1, 2, 3], empty: [String] = [], nested: [[Int]] = [[1], []],
        dict: [String: Int] = ["a": 1], emptyDict: [String: Bool] = [:],
        opt: Int? = nil, optSome: Int? = 3, optExplicit: Int? = .some(4), optNone: String? = .none, optOfOpt: [Int?] = [nil, 1],
        e1: IMDefUnits = .metric, e2: IMDefUnits = IMDefUnits.imperial, e3: IMDefUnits = .preferred, e4: IMDefUnits? = .metric,
        st1: Int = limit, st2: Int = Self.limit, st3: Int = IMDefEverything.limit, st4: String = hidden, st5: Double = computed,
        f1: [Int] = make(), f2: [Int] = Self.make(3), f3: Int = max(limit, 10), f4: Int = Int.max,
        c1: Int = { 5 }(), c2: [Int] = [3, 1, 2].sorted { $0 < $1 }, c3: String = { () -> String in "c" }(),
        op1: Int = 1 + 2 * 3, op2: Bool = limit > 3 && !false, op3: Int = limit > 3 ? 1 : 2, op4: String = "a" + "b",
        op5: Int = (nil as Int?) ?? 9, op6: Bool = false || true,
        p1: IMDefPoint = IMDefPoint(x: 1, y: 2), p2: IMDefPoint = .origin, p3: IMDefPoint = .at(3), p4: IMDefPoint? = nil,
        p5: [IMDefPoint] = [.origin, .init(x: 1, y: 1)],
        j1: JSONValue = ["k": [1, nil, "s"]], j2: JSONValue = nil, j3: JSONValue? = nil
    ) -> JSONValue {
        var out = JSONObject()
        out["i"] = i.jsonValue
        out["neg"] = neg.jsonValue
        out["hex"] = hex.jsonValue
        out["big"] = big.jsonValue
        out["sep"] = sep.jsonValue
        out["d"] = d.jsonValue
        out["dInt"] = dInt.jsonValue
        out["exp"] = exp.jsonValue
        out["s"] = s.jsonValue
        out["esc"] = esc.jsonValue
        out["raw"] = raw.jsonValue
        out["interp"] = interp.jsonValue
        out["multi"] = multi.jsonValue
        out["b"] = b.jsonValue
        out["nb"] = nb.jsonValue
        out["arr"] = arr.jsonValue
        out["empty"] = empty.jsonValue
        out["nested"] = nested.jsonValue
        out["dict"] = dict.jsonValue
        out["emptyDict"] = emptyDict.jsonValue
        out["opt"] = opt.jsonValue
        out["optSome"] = optSome.jsonValue
        out["optExplicit"] = optExplicit.jsonValue
        out["optNone"] = optNone.jsonValue
        out["optOfOpt"] = optOfOpt.jsonValue
        out["e1"] = e1.jsonValue
        out["e2"] = e2.jsonValue
        out["e3"] = e3.jsonValue
        out["e4"] = e4.jsonValue
        out["st1"] = st1.jsonValue
        out["st2"] = st2.jsonValue
        out["st3"] = st3.jsonValue
        out["st4"] = st4.jsonValue
        out["st5"] = st5.jsonValue
        out["f1"] = f1.jsonValue
        out["f2"] = f2.jsonValue
        out["f3"] = f3.jsonValue
        out["f4"] = f4.jsonValue
        out["c1"] = c1.jsonValue
        out["c2"] = c2.jsonValue
        out["c3"] = c3.jsonValue
        out["op1"] = op1.jsonValue
        out["op2"] = op2.jsonValue
        out["op3"] = op3.jsonValue
        out["op4"] = op4.jsonValue
        out["op5"] = op5.jsonValue
        out["op6"] = op6.jsonValue
        out["p1"] = p1.jsonValue
        out["p2"] = p2.jsonValue
        out["p3"] = p3.jsonValue
        out["p4"] = p4.jsonValue
        out["p5"] = p5.jsonValue
        out["j1"] = j1
        out["j2"] = j2
        out["j3"] = j3.jsonValue
        return .object(out)
    }
}

private let everythingDefaults: JSONObject = [
    "i": 1, "neg": -1, "hex": 255, "big": 1_099_511_627_776, "sep": 1000,
    "d": 1.5, "dInt": 2, "exp": 0.001,
    "s": "plain", "esc": "q\"\\\n", "raw": "r\\n", "interp": "a2b", "multi": "two\nlines",
    "b": true, "nb": false,
    "arr": [1, 2, 3], "empty": [], "nested": [[1], []],
    "dict": ["a": 1], "emptyDict": [:],
    "opt": nil, "optSome": 3, "optExplicit": 4, "optNone": nil, "optOfOpt": [nil, 1],
    "e1": "metric", "e2": "imperial", "e3": "imperial", "e4": "metric",
    "st1": 7, "st2": 7, "st3": 7, "st4": "h", "st5": 2.5,
    "f1": [2, 2], "f2": [3, 3, 3], "f3": 10, "f4": 9_223_372_036_854_775_807,
    "c1": 5, "c2": [1, 2, 3], "c3": "c",
    "op1": 7, "op2": true, "op3": 1, "op4": "ab", "op5": 9, "op6": true,
    "p1": ["x": 1, "y": 2], "p2": ["x": 0, "y": 0], "p3": ["x": 3, "y": 0], "p4": nil, "p5": [["x": 0, "y": 0], ["x": 1, "y": 1]],
    "j1": ["k": [1, nil, "s"]], "j2": nil, "j3": nil,
]

private let defaultEvaluations = Mutex(0)

private func countedDefault() -> Int {
    defaultEvaluations.withLock {
        $0 += 1
        return $0
    }
}

/// Defaults with a visible side effect.
@Tool
private struct IMDefLazy {
    func call(n: Int = countedDefault(), m: Int? = countedDefault()) -> String { "\(n) \(m ?? -1)" }
}

/// Defaults whose type depends on the tool's own generic parameter.
@Tool
private struct IMDefGeneric<Value: SchemaRepresentable & Sendable> {
    static var none: Value? { nil }
    func call(
        value: Value, fallback: [Value] = [], maybe: Value? = nil, other: Value? = none, pair: [String: Value] = [:],
        size: Int = MemoryLayout<Value>.size
    ) -> JSONValue {
        ["value": value.jsonValue, "fallback": fallback.jsonValue, "maybe": maybe.jsonValue, "other": other.jsonValue, "pair": pair.jsonValue, "size": size.jsonValue]
    }
}

/// Defaults in an actor.
@Tool
private actor IMDefActor {
    static let step = 2
    var total = 0
    func call(by: Int = step, times: Int = IMDefActor.step * 2, label: String? = nil) -> String {
        total += by * times
        return "\(total) \(label ?? "-")"
    }
}

/// Defaults in a class.
@Tool
private final class IMDefClass: Sendable {
    static let base = 10
    let offset: Int
    init(offset: Int) { self.offset = offset }
    func call(x: Int = base, y: Int = IMDefClass.base + 1) -> Int { x + y + offset }
}

/// Forty defaulted arguments.
@Tool
private struct IMDefMany {
    func call(
        a0: Int = 0, a1: Int = 1, a2: Int = 2, a3: Int = 3, a4: Int = 4, a5: Int = 5, a6: Int = 6, a7: Int = 7, a8: Int = 8, a9: Int = 9,
        a10: Int = 10, a11: Int = 11, a12: Int = 12, a13: Int = 13, a14: Int = 14, a15: Int = 15, a16: Int = 16, a17: Int = 17,
        a18: Int = 18, a19: Int = 19, a20: String = "20", a21: String = "21", a22: String = "22", a23: String = "23", a24: [Int] = [24],
        a25: [Int] = [25], a26: Bool = true, a27: Bool = false, a28: Double = 28.5, a29: Double = 29, a30: Int? = 30, a31: Int? = nil,
        a32: [String: Int] = ["k": 32], a33: Int = 33, a34: Int = 34, a35: Int = 35, a36: Int = 36, a37: Int = 37, a38: Int = 38,
        a39: Int = 39
    ) -> String {
        let numbers = [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a33, a34, a35, a36, a37, a38, a39]
        return "\(numbers.reduce(0, +)) \(a20)\(a21)\(a22)\(a23) \(a24 + a25) \(a26) \(a27) \(a28 + a29) \(a30 ?? -1) \(a31 ?? -1) \(a32)"
    }
}

@Tool
private struct IMDefKeywords {
    func call(
        `in`: Int, `default`: Int = 1, `inout`: Int = 2, `var`: Int = 3, `let`: Int = 4, `self`: Int = 5, `Type`: Int = 6,
        class kind: Int = 7, `func`: Int = 8, _ `protocol`: Int = 9, `throws`: Int = 10, `is`: Int = 11, `Any`: Int = 12
    ) -> String {
        "\(`in`) \(`default`) \(`inout`) \(`var`) \(`let`) \(`self`) \(`Type`) \(kind) \(`func`) \(`protocol`) \(`throws`) \(`is`) \(`Any`)"
    }
}

@Tool
private struct IMDefUserStatic {
    static func __limbDefault(_ index: Int) -> Int { 99 }
    static func __limbDefault(_ index: Int) -> String { "user" }
    static func __limbDefault<Value>(_ index: Int) -> Value { fatalError("the user's generic method was called") }
    func call(x: Int = 5, s: String = "s", list: [Int] = [1]) -> String { "\(x) \(s) \(list)" }
}

/// Has a static method with the generated method's name and label, but not generic. (The
/// exact generic shape is an "invalid redeclaration": IndependentMacroDoesNotCompile.swift, 6.)
@Tool
private struct IMDefUserLabelled {
    static func __limbDefault(__limbArgument index: Int) -> Int { 99 }
    func call(x: Int = 5) -> Int { x }
}

/// Has instance members named like the generated static method.
@Tool
private struct IMDefUserInstance {
    let __limbDefault: Int
    func __limbDefault(_ index: Int) -> Int { 98 }
    func call(x: Int = 5) -> Int { x + __limbDefault }
}

/// Has a static member of that name and no defaults of its own.
@Tool
private struct IMDefUserNoDefaults {
    static func __limbDefault(_ index: Int) -> Int { 99 }
    func call(x: Int) -> Int { x + Self.__limbDefault(0) }
}

private func makeServer() throws -> Server {
    try Server(name: "defaults", version: "1") {
        IMDefEverything()
        IMDefLazy()
        IMDefGeneric<Int>()
        IMDefActor()
        IMDefClass(offset: 1)
        IMDefMany()
        IMDefKeywords()
        IMDefUserStatic()
        IMDefUserLabelled()
        IMDefUserInstance(__limbDefault: 1)
        IMDefUserNoDefaults()
    }
}

// MARK: - Tests

@Suite struct IndependentMacroDefaultValueTests {
    @Test func noDefaultedArgumentIsRequired() async throws {
        let schema = IMDefEverything.definition.inputSchema
        IndependentMacroCheckSchema(schema)
        #expect(schema["required"] == [])
        #expect(schema["properties"]?.objectValue?.map(\.key) == everythingDefaults.map(\.key))
        #expect(schema["properties"]?["e4"] == ["anyOf": [["type": "string", "enum": ["metric", "imperial"]], ["type": "null"]]])
        #expect(schema["properties"]?["big"] == ["type": "integer"])
        #expect(schema["properties"]?["p5"] == ["type": "array", "items": .object(IMDefPoint.jsonSchema)])
        #expect(IMDefMany.definition.inputSchema["required"] == [])
        #expect(IMDefMany.definition.inputSchema["properties"]?.objectValue?.count == 40)
        #expect(IMDefGeneric<String>.definition.inputSchema["required"] == ["value"])
    }

    @Test func everyKindOfDefaultIsUsedWhenTheArgumentIsAbsent() async throws {
        let client = TestClient(try makeServer())
        for arguments: JSONValue? in [nil, [:]] {
            let response = try await client.independentMacroCall("im_def_everything", arguments)
            #expect(response["result"]?["isError"] == false, "\(response)")
            let result = response["result"]?["structuredContent"]?.objectValue ?? [:]
            for (key, expected) in everythingDefaults {
                #expect(result[key] == expected, "\(key): got \(result[key] ?? "nothing"), expected \(expected)")
            }
            #expect(result.count == everythingDefaults.count)
        }
    }

    @Test func aPresentArgumentWinsOverEveryKindOfDefault() async throws {
        let client = TestClient(try makeServer())
        let explicit: JSONObject = [
            "i": 10, "neg": 11, "hex": 12, "big": 13, "sep": 14, "d": 0.5, "dInt": 0.25, "exp": 3,
            "s": "S", "esc": "", "raw": "R", "interp": "I", "multi": "M", "b": false, "nb": true,
            "arr": [], "empty": ["e"], "nested": [], "dict": [:], "emptyDict": ["t": true],
            "opt": 1, "optSome": 2, "optExplicit": 3, "optNone": "some", "optOfOpt": [],
            "e1": "imperial", "e2": "metric", "e3": "metric", "e4": "imperial",
            "st1": 1, "st2": 2, "st3": 3, "st4": "4", "st5": 5,
            "f1": [], "f2": [1], "f3": 0, "f4": 0, "c1": 0, "c2": [9], "c3": "",
            "op1": 0, "op2": false, "op3": 0, "op4": "", "op5": 0, "op6": false,
            "p1": ["x": 9, "y": 9], "p2": ["x": 8, "y": 8], "p3": ["x": 7, "y": 7], "p4": ["x": 6, "y": 6], "p5": [],
            "j1": 1, "j2": "two", "j3": [3],
        ]
        #expect(explicit.count == everythingDefaults.count)
        let response = try await client.independentMacroCall("im_def_everything", .object(explicit))
        #expect(response["result"]?["isError"] == false, "\(response)")
        let result = response["result"]?["structuredContent"]?.objectValue ?? [:]
        for (key, expected) in explicit {
            #expect(result[key] == expected, "\(key): got \(result[key] ?? "nothing"), expected \(expected)")
        }
    }

    /// One present argument must not disturb the defaults of the others (each default has its
    /// own slot in the generated `switch`).
    @Test func eachArgumentHasItsOwnDefault() async throws {
        let client = TestClient(try makeServer())
        let replacements: [(String, JSONValue)] = [
            ("op6", false), ("st1", 0), ("e3", "metric"), ("c2", []), ("p2", ["x": 5, "y": 5]), ("multi", "x"),
        ]
        for (key, replacement) in replacements {
            let response = try await client.independentMacroCall("im_def_everything", .object([key: replacement]))
            let result = response["result"]?["structuredContent"]?.objectValue ?? [:]
            for (name, expected) in everythingDefaults {
                #expect(result[name] == (name == key ? replacement : expected), "\(key) replaced; \(name): \(result[name] ?? "nothing")")
            }
        }
    }

    @Test func nullYieldsTheDefaultOfAnOptionalArgument() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall(
            "im_def_everything", ["opt": nil, "optSome": nil, "optExplicit": nil, "optNone": nil, "e4": nil, "p4": nil, "j3": nil])
        #expect(response["result"]?["isError"] == false, "\(response)")
        let result = response["result"]?["structuredContent"]
        #expect(result?["opt"] == .null)
        #expect(result?["optSome"] == 3)
        #expect(result?["optExplicit"] == 4)
        #expect(result?["optNone"] == .null)
        #expect(result?["e4"] == "metric")
        #expect(result?["p4"] == .null)
    }

    /// A default is evaluated when it is needed and only then, as in a Swift call: not when
    /// the tool is declared, not when the argument is present.
    @Test func defaultsAreEvaluatedOnlyWhenNeeded() async throws {
        let server = try makeServer()
        let client = TestClient(server)
        _ = IMDefLazy.definition
        _ = try await client.request("tools/list")
        let start = defaultEvaluations.withLock { $0 }
        #expect(try await client.independentMacroCall("im_def_lazy", ["n": 100, "m": 200]).independentMacroFirstText == "100 200")
        #expect(defaultEvaluations.withLock { $0 } == start)
        #expect(try await client.independentMacroCall("im_def_lazy", ["n": 100]).independentMacroFirstText == "100 \(start + 1)")
        #expect(try await client.independentMacroCall("im_def_lazy").independentMacroFirstText == "\(start + 2) \(start + 3)")
        #expect(try await client.independentMacroCall("im_def_lazy", ["m": nil]).independentMacroFirstText == "\(start + 4) \(start + 5)")
        #expect(defaultEvaluations.withLock { $0 } == start + 5)
        // An argument that fails validation costs no evaluation.
        #expect(try await client.independentMacroCall("im_def_lazy", ["n": "x"])["result"]?["isError"] == true)
        #expect(defaultEvaluations.withLock { $0 } == start + 5)
    }

    @Test func defaultsOverTheToolsGenericParameter() async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("im_def_generic", ["value": 1])
        #expect(response["result"]?["structuredContent"] == ["value": 1, "fallback": [], "maybe": nil, "other": nil, "pair": [:], "size": 8])
        let explicit = try await client.independentMacroCall(
            "im_def_generic", ["value": 1, "fallback": [2], "maybe": 3, "other": 4, "pair": ["k": 5], "size": 0])
        #expect(explicit["result"]?["structuredContent"] == ["value": 1, "fallback": [2], "maybe": 3, "other": 4, "pair": ["k": 5], "size": 0])
        #expect(try await client.independentMacroCall("im_def_generic", ["value": 1, "fallback": ["x"]])["result"]?["isError"] == true)
    }

    @Test func defaultsInActorsAndClasses() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_def_actor").independentMacroFirstText == "8 -")
        #expect(try await client.independentMacroCall("im_def_actor", ["by": 1]).independentMacroFirstText == "12 -")
        #expect(try await client.independentMacroCall("im_def_actor", ["times": 1, "label": "l"]).independentMacroFirstText == "14 l")
        #expect(try await client.independentMacroCall("im_def_class")["result"]?["structuredContent"] == 22)
        #expect(try await client.independentMacroCall("im_def_class", ["y": 0])["result"]?["structuredContent"] == 11)
    }

    @Test func manyDefaultedArguments() async throws {
        let client = TestClient(try makeServer())
        #expect(
            try await client.independentMacroCall("im_def_many").independentMacroFirstText
                == "442 20212223 [24, 25] true false 57.5 30 -1 [\"k\": 32]")
        #expect(
            try await client.independentMacroCall("im_def_many", ["a0": 100, "a39": 0, "a23": "x", "a31": 31, "a26": false])
                .independentMacroFirstText == "503 202122x [24, 25] false false 57.5 30 31 [\"k\": 32]")
    }

    @Test func keywordArgumentsWithDefaults() async throws {
        let schema = IMDefKeywords.definition.inputSchema
        #expect(
            schema["properties"]?.objectValue?.map(\.key)
                == ["in", "default", "inout", "var", "let", "self", "Type", "class", "func", "protocol", "throws", "is", "Any"])
        #expect(schema["required"] == ["in"])
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_def_keywords", ["in": 0]).independentMacroFirstText == "0 1 2 3 4 5 6 7 8 9 10 11 12")
        let explicit: JSONObject = [
            "in": 20, "default": 21, "inout": 22, "var": 31, "let": 32, "self": 23, "Type": 24, "class": 25, "func": 26, "protocol": 27,
            "throws": 28, "is": 29, "Any": 30,
        ]
        #expect(
            try await client.independentMacroCall("im_def_keywords", .object(explicit)).independentMacroFirstText
                == "20 21 22 31 32 23 24 25 26 27 28 29 30")
    }

    /// A type that has static methods called `__limbDefault` of its own must still get the
    /// defaults written in the signature.
    @Test func aUserStaticMethodNamedLikeTheGeneratedOne() async throws {
        let client = TestClient(try makeServer())
        let defaults = try await client.independentMacroCall("im_def_user_static").independentMacroFirstText
        #expect(defaults == "5 s [1]", "the defaults came from the user's methods: \(defaults ?? "nothing")")
        #expect(
            try await client.independentMacroCall("im_def_user_static", ["x": 1, "s": "t", "list": []]).independentMacroFirstText == "1 t []")
    }

    @Test(.disabled("known limitation: a user's static __limbDefault(__limbArgument:) with a concrete return type is chosen over the generated one"))
    func aUserStaticMethodWithTheGeneratedLabel() async throws {
        let client = TestClient(try makeServer())
        let value = try await client.independentMacroCall("im_def_user_labelled")["result"]?["structuredContent"]
        #expect(value == 5, "the default came from the user's method: \(value ?? .null)")
        #expect(try await client.independentMacroCall("im_def_user_labelled", ["x": 1])["result"]?["structuredContent"] == 1)
    }

    @Test func userInstanceMembersNamedLikeTheGeneratedOne() async throws {
        let client = TestClient(try makeServer())
        #expect(try await client.independentMacroCall("im_def_user_instance")["result"]?["structuredContent"] == 6)
        #expect(try await client.independentMacroCall("im_def_user_no_defaults", ["x": 1])["result"]?["structuredContent"] == 100)
    }
}
