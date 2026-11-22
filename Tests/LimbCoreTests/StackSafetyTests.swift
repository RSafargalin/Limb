#if canImport(Darwin)
import Foundation
import LimbCore
import Testing

// Recursion over untrusted input on a stack that is small or nearly used up.
//
// The contract under test: nothing here may crash. The default parser keeps nesting on the
// heap, so what it answers must not depend on the stack at all. Neither may the schema
// validator's answer: it recurses, but when it runs out of stack it starts over on a thread
// with a large one. The fallback parser and the schema compiler recurse and give up instead:
// for them, input that needs more stack than the thread has left is an error, and ordinary
// input still works when a reasonable amount is left.
// A crash here does not fail a test, it kills the test process — so a run that ends with a
// signal instead of a summary points at this file.
//
// One limit comes from the harness, not from Limb: Swift Testing captures a backtrace whenever
// an error is thrown, and that needs a few kilobytes of stack itself. With less than about
// 8 KiB left the process dies inside `Backtrace.current`, after the parser has already thrown
// its error correctly. The tests therefore stop at 16 KiB.

private final class Slot<Value>: @unchecked Sendable {
    var value: Value?
}

/// Runs `body` on a new thread whose stack is `stackSize` bytes, and waits for the result.
private func onThread<Value: Sendable>(stackSize: Int, _ body: @escaping @Sendable () -> Value) -> Value {
    let slot = Slot<Value>()
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
        slot.value = body()
        finished.signal()
    }
    thread.stackSize = stackSize
    thread.start()
    finished.wait()
    return slot.value!
}

/// Bytes of stack left on the current thread.
private func stackLeft() -> Int {
    var marker = 0
    let here = withUnsafePointer(to: &marker) { Int(bitPattern: $0) }
    let thread = pthread_self()
    return pthread_get_stacksize_np(thread) - (Int(bitPattern: pthread_get_stackaddr_np(thread)) - here)
}

/// Uses up the current thread's stack until about `leave` bytes are left, then calls `body`.
@inline(never)
private func withStackLeft<Value>(_ leave: Int, _ body: () -> Value) -> Value {
    if stackLeft() <= leave { return body() }
    // An allocation this small is made on the stack; touching it makes the page real.
    return withUnsafeTemporaryAllocation(byteCount: 1024, alignment: 16) { buffer in
        buffer.storeBytes(of: 1, as: UInt8.self)
        return withStackLeft(leave, body)
    }
}

/// Runs `body` on a handler-sized thread with about `leave` bytes of its stack left.
private func onExhaustedThread<Value: Sendable>(leaving leave: Int, _ body: @escaping @Sendable () -> Value) -> Value {
    onThread(stackSize: 512 * 1024) { withStackLeft(leave, body) }
}

private let kib = 1024

private typealias Parsed = Result<JSONValue, JSONParseError>

/// Nothing but the call: describing an error takes stack, so that is left to the caller.
private func parse(_ bytes: [UInt8], _ options: JSONParseOptions = .default) -> Parsed {
    do { return .success(try JSON.parse(bytes, options: options)) } catch { return .failure(error) }
}

private enum Verdict: Equatable, CustomStringConvertible {
    case parsed
    case tooDeep
    /// The input ended inside a value, at this offset.
    case cutShort(Int)
    case refused(String)

    init(_ result: Parsed) {
        switch result {
        case .success: self = .parsed
        case .failure(let error):
            switch error.kind {
            case .depthLimitExceeded: self = .tooDeep
            case .unexpectedEnd: self = .cutShort(error.offset)
            default: self = .refused("\(error)")
            }
        }
    }

    var description: String {
        switch self {
        case .parsed: "parsed"
        case .tooDeep: "too deep"
        case .cutShort(let offset): "cut short at \(offset)"
        case .refused(let why): "refused (\(why))"
        }
    }

    /// What nesting that never closes must come to when `maxDepth` is lifted: both codecs have
    /// a ceiling of their own (256 levels and 128) and refuse at the bracket that crosses it.
    static func bottomless(_ bytes: [UInt8]) -> Verdict { .tooDeep }
}

private enum Shape: String, CaseIterable, Sendable {
    case arrays, objects, mixed, arraysAroundAHeavyLeaf, objectsAroundAHeavyLeaf

    /// Three levels of nesting with the kinds of values that cost the most to read at the bottom.
    static let leaf = #"["esc\u00e9\ud83d\ude00 text \n",1234567890.125,{"k1":1,"k2":[true,null],"k3":"v"},1e300,-0.5]"#

    /// A valid document nested exactly `depth` levels deep.
    func document(depth: Int) -> [UInt8] {
        func wrap(_ open: String, _ close: String, _ count: Int, _ core: String) -> String {
            String(repeating: open, count: count) + core + String(repeating: close, count: count)
        }
        let text: String
        switch self {
        case .arrays: text = wrap("[", "]", depth, "")
        case .objects: text = wrap("{\"a\":", "}", depth, "1")
        case .mixed: text = depth % 2 == 0 ? wrap("[{\"a\":", "}]", depth / 2, "1") : "[" + wrap("[{\"a\":", "}]", depth / 2, "1") + "]"
        case .arraysAroundAHeavyLeaf: text = depth >= 3 ? wrap("[", "]", depth - 3, Self.leaf) : wrap("[", "]", depth, "")
        case .objectsAroundAHeavyLeaf: text = depth >= 3 ? wrap("{\"a\":", "}", depth - 3, Self.leaf) : wrap("{\"a\":", "}", depth, "1")
        }
        return Array(text.utf8)
    }
}

private let depths = [1, 8, 32, 64, 128]

/// Values built in code rather than parsed, nested exactly `depth` levels around `core`.
private enum NestedShape: String, CaseIterable, Sendable {
    case arrays, objects, mixed
    /// Every level an object with six members, one of which is the next level.
    case wideObjects
}

private func nestedValue(_ shape: NestedShape, depth: Int, core: JSONValue = 1) -> JSONValue {
    var value = core
    for level in 0..<depth {
        switch shape {
        case .arrays: value = .array([value])
        case .objects: value = .object(["a": value])
        case .mixed: value = level % 2 == 0 ? .array([value]) : .object(["a": value])
        case .wideObjects:
            // The side members are scalars, so the level count stays what it says.
            value = .object(["k1": 1, "k2": "two", "k3": true, "nested": value, "k5": nil, "k6": 2.5])
        }
    }
    return value
}

/// `nil` when the schema compiles; the reason it does not otherwise.
private func compileOutcome(_ schema: JSONValue, _ limits: JSONSchema.Limits = JSONSchema.Limits()) -> String? {
    do {
        _ = try JSONSchema(schema, limits: limits)
        return nil
    } catch {
        return error.reason
    }
}

/// Makes the first-time costs happen on a roomy stack: metadata, lazy globals, and the
/// backtrace machinery Swift Testing runs on a thrown error.
private func warmUp() {
    _ = parse(Array("[".utf8))
    _ = parse(Array(#"{"a":[1,"b",2.5,true,null]}"#.utf8))
    _ = try? JSONSchema(5)
    _ = try? JSONSchema(["type": "object"]).validate(["a": 1])
}

@Suite struct StackSafetyTests {
    /// The shapes really are as deep as they say; the tests below lean on that.
    @Test func shapesHaveTheDepthTheyClaim() {
        for shape in Shape.allCases {
            for depth in [1, 2, 3, 4, 7, 8, 32] {
                let bytes = shape.document(depth: depth)
                #expect(Verdict(parse(bytes, JSONParseOptions(maxDepth: depth))) == .parsed, "\(shape) \(depth)")
                #expect(Verdict(parse(bytes, JSONParseOptions(maxDepth: depth - 1))) == .tooDeep, "\(shape) \(depth)")
            }
        }
    }

    /// Whole threads with small stacks.
    @Test func smallThreadStacks() {
        warmUp()
        for size in [64, 96, 128, 192, 256, 512] {
            for shape in Shape.allCases {
                var refusedFrom: Int?
                for depth in depths {
                    let bytes = shape.document(depth: depth)
                    let verdict = Verdict(onThread(stackSize: size * kib) { parse(bytes) })
                    let label: Comment = "\(shape) at depth \(depth) on a \(size) KiB stack: \(verdict)"
                    #if FoundationJSON
                    // Parsed or refused for depth — nothing else, and nothing that kills the process.
                    #expect(verdict == .parsed || verdict == .tooDeep, label)
                    // A handful of levels fits anywhere.
                    if depth <= 8 { #expect(verdict == .parsed, label) }
                    // On the stack handlers get, so does everything up to the default limit.
                    if size == 512 { #expect(verdict == .parsed, label) }
                    // Deeper never succeeds where shallower was refused.
                    if let refusedFrom { #expect(verdict == .tooDeep, "\(label), though depth \(refusedFrom) was refused") }
                    if verdict == .tooDeep, refusedFrom == nil { refusedFrom = depth }
                    #else
                    // The stack has no say: a document inside the limit parses.
                    #expect(verdict == .parsed, label)
                    _ = refusedFrom
                    #endif
                }
            }
            // Nesting without an end, with the limit lifted.
            for text in [String(repeating: "[", count: 100_000), String(repeating: "{\"a\":", count: 100_000)] {
                let bytes = Array(text.utf8)
                let verdict = Verdict(onThread(stackSize: size * kib) { parse(bytes, JSONParseOptions(maxDepth: .max)) })
                #expect(verdict == Verdict.bottomless(bytes), "bottomless \(text.prefix(5)) on a \(size) KiB stack: \(verdict)")
            }
        }
    }

    /// A handler thread that has used most of its stack before it gets to `JSON.parse`.
    @Test func nearlyExhaustedStack() {
        warmUp()
        let documents: [(name: String, depth: Int, bytes: [UInt8])] = Shape.allCases.flatMap { shape in
            depths.map { (shape.rawValue, $0, shape.document(depth: $0)) }
        }
        let inputs = documents.map(\.bytes)
        let bottomless = [Array(String(repeating: "[", count: 100_000).utf8), Array(String(repeating: "{\"a\":", count: 100_000).utf8)]
        // Errors of every other kind must not depend on the stack either.
        let broken = ["[1,]x", "{\"a\":1,\"a\"", "[[[[1 2]]]]", "[\"\\x\"]", "[01]", "[1]]", ""].map { Array($0.utf8) }
        let brokenOnAFullStack = broken.map { Verdict(parse($0)) }
        var parsedFrom = [Int?](repeating: nil, count: documents.count)
        for leave in stride(from: 16 * kib, through: 336 * kib, by: 2 * kib) {
            let (results, endless, failures) = onExhaustedThread(leaving: leave) {
                (inputs.map { parse($0) }, bottomless.map { parse($0, JSONParseOptions(maxDepth: .max)) }, broken.map { parse($0) })
            }
            for (index, result) in results.enumerated() {
                let (name, depth, _) = documents[index]
                let verdict = Verdict(result)
                let label: Comment = "\(name) at depth \(depth) with \(leave / kib) KiB of stack left: \(verdict)"
                #if FoundationJSON
                #expect(verdict == .parsed || verdict == .tooDeep, label)
                // With a fifth of a handler's stack left, a handful of levels still parses.
                if depth <= 8, leave >= 96 * kib { #expect(verdict == .parsed, label) }
                // More stack never turns a success into a refusal.
                if let from = parsedFrom[index] { #expect(verdict == .parsed, "\(label), though it parsed with \(from / kib) KiB") }
                #else
                #expect(verdict == .parsed, label)
                // And it is the same value as on a full stack.
                if case .success(let value) = result, leave % (32 * kib) == 0 {
                    #expect(value == (try? JSON.parse(documents[index].bytes)), label)
                }
                #endif
                if verdict == .parsed, parsedFrom[index] == nil { parsedFrom[index] = leave }
            }
            for (index, result) in endless.enumerated() {
                #expect(
                    Verdict(result) == Verdict.bottomless(bottomless[index]),
                    "bottomless nesting with \(leave / kib) KiB of stack left: \(Verdict(result))")
            }
            for (index, result) in failures.enumerated() {
                let verdict = Verdict(result)
                #if FoundationJSON
                // Refused either way; only the reason may be the stack instead of the syntax.
                #expect(verdict != .parsed, "broken input \(index) with \(leave / kib) KiB of stack left: \(verdict)")
                if leave >= 96 * kib { #expect(verdict == brokenOnAFullStack[index], "broken input \(index) with \(leave / kib) KiB of stack left") }
                #else
                #expect(verdict == brokenOnAFullStack[index], "broken input \(index) with \(leave / kib) KiB of stack left: \(verdict)")
                #endif
            }
        }
        // Somewhere below a full stack every shallow document did parse.
        for (index, document) in documents.enumerated() where document.depth <= 32 {
            #expect(parsedFrom[index] != nil, "\(document.name) at depth \(document.depth) never parsed")
        }
    }

    /// Long tokens and wide containers cost Foundation and Limb heap, not stack: with little
    /// stack left they parse or are refused for want of stack, like anything else.
    @Test func longTokensOnANearlyExhaustedStack() {
        warmUp()
        let documents: [(name: String, text: String)] = [
            ("a number with a million fraction digits", "0." + String(repeating: "7", count: 1_000_000)),
            ("many numbers with 22 digits", "[" + Array(repeating: "1234567890123456789.25", count: 50_000).joined(separator: ",") + "]"),
            ("a string of two megabytes", "\"" + String(repeating: "a", count: 2_000_000) + "\""),
            ("a string of escapes", "\"" + String(repeating: #"\u00e9\n\ud83d\ude00"#, count: 100_000) + "\""),
            ("a long key of escapes", "{\"" + String(repeating: #"\u00e9k"#, count: 200_000) + "\":1}"),
            ("a wide array", "[" + Array(repeating: "0", count: 500_000).joined(separator: ",") + "]"),
            ("a wide object", "{" + (0..<100_000).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"),
            ("many shallow siblings", "[" + Array(repeating: "[[[[[[[[1]]]]]]]]", count: 20_000).joined(separator: ",") + "]"),
        ]
        let inputs = documents.map { Array($0.text.utf8) }
        for leave in [24, 32, 34, 36, 38, 40, 44, 48, 56, 64, 80, 96, 128, 256].map({ $0 * kib }) {
            let results = onExhaustedThread(leaving: leave) { inputs.map { parse($0) } }
            for (index, result) in results.enumerated() {
                let verdict = Verdict(result)
                let label: Comment = "\(documents[index].name) with \(leave / kib) KiB of stack left: \(verdict)"
                #if FoundationJSON
                #expect(verdict == .parsed || verdict == .tooDeep, label)
                if leave >= 128 * kib { #expect(verdict == .parsed, label) }
                #else
                #expect(verdict == .parsed, label)
                #endif
            }
        }
    }

    @Test func schemaCompilerOnANearlyExhaustedStack() {
        warmUp()
        let runs: [(leave: Int, deep: String?, deepWithDefaultLimits: String?, small: String?)] = onThread(stackSize: 64 << 20) {
            var raised = JSONSchema.Limits()
            raised.maxDepth = 1_000_000
            raised.maxSubschemas = 10_000_000
            let limits = raised
            var building: JSONValue = ["type": "string"]
            for _ in 0..<400 { building = ["items": building] }
            let deepSchema = building
            let smallSchema: JSONValue = [
                "type": "object", "properties": ["a": ["type": "array", "items": ["type": "string"]]], "required": ["a"],
            ]
            return stride(from: 24 * kib, through: 336 * kib, by: 6 * kib).map { leave in
                onExhaustedThread(leaving: leave) {
                    (leave, compileOutcome(deepSchema, limits), compileOutcome(deepSchema), compileOutcome(smallSchema))
                }
            }
        }
        for run in runs {
            let label: Comment = "with \(run.leave / kib) KiB of stack left"
            #expect(run.deep == nil, label)
            #expect(run.deepWithDefaultLimits == "schema nesting deeper than 32", label)
            #expect(run.small == nil, label)
        }
    }

    /// Schemas of several shapes exactly at `maxDepth` and one level beyond: the answer on a
    /// handler's stack with little left is the one given with all the stack there is. The
    /// shapes include `Optional` structs (`anyOf` of null and an object) and
    /// a `$defs` chain of `anyOf` with `$ref`.
    @Test func schemaCompilerGivesTheSameAnswerOnAnyStack() {
        warmUp()
        func chain(_ levels: Int, _ wrap: (JSONValue, Int) -> JSONValue) -> JSONValue {
            var value: JSONValue = ["type": "string"]
            for level in 0..<levels { value = wrap(value, level) }
            return value
        }
        func definitions(_ levels: Int) -> JSONValue {
            var defs = JSONObject()
            for level in 0..<levels {
                defs["d\(level)"] = level == levels - 1
                    ? ["type": "string"] : ["anyOf": [["$ref": .string("#/$defs/d\(level + 1)")], ["type": "null"]]]
            }
            return ["$defs": .object(defs), "$ref": "#/$defs/d0"]
        }
        let shapes: [(String, (Int) -> JSONValue)] = [
            ("properties", { n in chain(n) { inner, _ in ["type": "object", "properties": ["a": inner]] } }),
            ("items", { n in chain(n) { inner, _ in ["items": inner] } }),
            ("not", { n in chain(n) { inner, _ in ["not": inner] } }),
            ("optional structs", { n in chain(n) { inner, level in level % 2 == 0 ? ["anyOf": [["type": "null"], inner]] : ["type": "object", "properties": ["v": inner]] } }),
            ("$defs chain", definitions),
        ]
        // With all the stack there is: the deepest that compiles, found by search.
        var questions: [(name: String, schema: JSONValue, compiles: Bool)] = []
        for (name, make) in shapes {
            var deepest = 1
            while (try? JSONSchema(make(deepest + 1))) != nil { deepest += 1 }
            #expect(deepest >= 16, "\(name): only \(deepest) levels compile")
            questions.append((name + " at the limit", make(deepest), true))
            questions.append((name + " beyond", make(deepest + 1), false))
        }
        let asked = questions.map(\.schema)
        for leave in [24, 48, 96, 160, 336].map({ $0 * kib }) {
            let answers = onExhaustedThread(leaving: leave) {
                asked.map { compileOutcome($0) }
            }
            for (index, answer) in answers.enumerated() {
                let label: Comment = "\(questions[index].name) with \(leave / kib) KiB left: \(answer ?? "compiles")"
                if questions[index].compiles {
                    #expect(answer == nil, label)
                } else {
                    #expect(answer == "schema nesting deeper than 32", label)
                }
            }
        }
    }

    /// Beyond what even the large stack holds, with limits raised out of the way: refused with
    /// its own message, without crashing. D6: in an optimized build the compiler works for
    /// about twelve seconds before it gives up (pointers to subschemas are strings that grow
    /// with the depth, so compiling is quadratic in it); an unoptimized build runs out of stack
    /// at a few thousand levels and answers at once.
    @Test func aSchemaTooDeepEvenForTheLargeStackIsRefused() {
        #if DEBUG
        let levels = 20_000
        #else
        let levels = 100_000
        #endif
        let (reason, elapsed): (String?, Duration) = onThread(stackSize: 512 << 20) {
            var limits = JSONSchema.Limits()
            limits.maxDepth = 10_000_000
            limits.maxSubschemas = 10_000_000
            var schema: JSONValue = ["type": "string"]
            for _ in 0..<levels { schema = ["not": schema] }
            var reason: String?
            let elapsed = ContinuousClock().measure { reason = compileOutcome(schema, limits) }
            return (reason, elapsed)
        }
        #expect(reason == "the schema is nested too deeply to compile")
        #if DEBUG
        #expect(elapsed < .seconds(5))
        #else
        withKnownIssue("D6: compiling is quadratic in the depth", isIntermittent: true) {
            #expect(elapsed < .seconds(3), "\(elapsed)")
        }
        #endif
    }

    /// A question put to the validator, and what it says with all the stack there is.
    private struct Question: Sendable {
        var name: String
        var schema: JSONSchema
        var instance: JSONValue
    }

    /// Asks every question with all the stack there is and then with less and less of a
    /// handler's stack left; returns the answers that differ from the first.
    private static func differences(_ questions: [Question], leaves: [Int]) -> [String] {
        let asked = questions
        let full = asked.map { $0.schema.validate($0.instance) }
        var differences: [String] = []
        for leave in leaves {
            let answers = onExhaustedThread(leaving: leave) { asked.map { $0.schema.validate($0.instance) } }
            for (index, answer) in answers.enumerated() where answer != full[index] {
                if differences.count < 12 {
                    differences.append(
                        "\(asked[index].name) with \(leave / kib) KiB left: \(answer?.reason.prefix(50) ?? "valid") instead of \(full[index]?.reason.prefix(50) ?? "valid")")
                } else {
                    differences.append("…")
                }
            }
        }
        return differences
    }

    /// The rule for the validator: whatever stack is left, the answer — valid, or the same
    /// violation at the same path — is the one it gives on a full stack. Running out of stack
    /// used to be reported as "nested deeper than the validator allows", and inside `anyOf`,
    /// `oneOf`, `not` and `if` that refusal was taken for "does not match": a wrong answer.
    @Test func validationGivesTheSameAnswerOnAnyStack() {
        warmUp()
        let (count, differences, expectations): (Int, [String], [String]) = onThread(stackSize: 64 << 20) {
            var questions: [Question] = []
            var expectations: [String] = []
            func ask(_ name: String, _ schema: JSONValue, _ instance: JSONValue, _ expected: String?) {
                let compiled = try! JSONSchema(schema)
                questions.append(Question(name: name, schema: compiled, instance: instance))
                // What the full-stack answer should be, so that "the same" is not "the same mistake".
                let found = compiled.validate(instance)?.reason
                if found != expected { expectations.append("\(name): \(found ?? "valid") instead of \(expected ?? "valid")") }
            }
            let lists: JSONValue = ["type": "array", "items": ["$ref": "#/$defs/list"]]
            let defs: JSONValue = ["list": lists, "tree": ["type": "object", "properties": ["a": ["$ref": "#/$defs/tree"]], "additionalProperties": false]]
            for depth in [3, 40, 128, 256] {
                let arrays = nestedValue(.arrays, depth: depth, core: [])
                let objects = nestedValue(.objects, depth: depth, core: [:])
                let spoiled = nestedValue(.arrays, depth: depth, core: "x")
                let stray = nestedValue(.objects, depth: depth, core: ["b": 1])
                let name = "depth \(depth)"
                let notAList = "expected array, got string"
                ask("self-reference, valid, \(name)", ["$defs": defs, "$ref": "#/$defs/list"], arrays, nil)
                ask("self-reference, wrong at the bottom, \(name)", ["$defs": defs, "$ref": "#/$defs/list"], spoiled, notAList)
                ask("objects, valid, \(name)", ["$defs": defs, "$ref": "#/$defs/tree"], objects, nil)
                ask("objects, stray member at the bottom, \(name)", ["$defs": defs, "$ref": "#/$defs/tree"], stray, "unknown field")
                // Composition: a branch that needs the whole depth decides the answer.
                ask("anyOf, deep branch matches, \(name)", ["$defs": defs, "anyOf": [["$ref": "#/$defs/list"], ["type": "integer"]]], arrays, nil)
                ask("anyOf, deep branch fails, \(name)", ["$defs": defs, "anyOf": [["$ref": "#/$defs/list"], ["type": "integer"]]], spoiled, "does not match any of the allowed alternatives")
                ask("oneOf, both match, \(name)", ["$defs": defs, "oneOf": [["$ref": "#/$defs/list"], ["type": "array"]]], arrays, "matches more than one alternative")
                ask("oneOf, only the shallow one matches, \(name)", ["$defs": defs, "oneOf": [["$ref": "#/$defs/list"], ["type": "array"]]], spoiled, nil)
                ask("not, deep branch matches, \(name)", ["$defs": defs, "not": ["$ref": "#/$defs/list"]], arrays, "matches a schema it must not match")
                ask("not, deep branch fails, \(name)", ["$defs": defs, "not": ["$ref": "#/$defs/list"]], spoiled, nil)
                ask("allOf, \(name)", ["$defs": defs, "allOf": [["type": "array"], ["$ref": "#/$defs/list"], ["minItems": 1]]], spoiled, notAList)
                ask("if matches, then fails, \(name)", ["$defs": defs, "if": ["$ref": "#/$defs/list"], "then": ["maxItems": 0], "else": ["type": "string"]], arrays, "must have at most 0 items")
                ask("if fails, else holds, \(name)", ["$defs": defs, "if": ["$ref": "#/$defs/list"], "then": ["maxItems": 0], "else": ["type": "array"]], spoiled, nil)
                ask("if fails, else fails, \(name)", ["$defs": defs, "if": ["$ref": "#/$defs/list"], "then": ["maxItems": 0], "else": ["type": "string"]], spoiled, "expected string, got array")
                ask("contains, \(name)", ["$defs": defs, "contains": ["$ref": "#/$defs/list"]], [1, "x", arrays], nil)
                ask("contains nothing, \(name)", ["$defs": defs, "contains": ["$ref": "#/$defs/list"]], [1, "x", spoiled], "must contain at least 1 matching items")
                ask("prefixItems, \(name)", ["$defs": defs, "prefixItems": [["type": "integer"], ["$ref": "#/$defs/list"]], "items": false], [1, spoiled], notAList)
                ask("dependentSchemas, \(name)", ["$defs": defs, "dependentSchemas": ["a": ["$ref": "#/$defs/tree"]]], stray, "unknown field")
                ask("patternProperties and propertyNames, \(name)", ["$defs": defs, "patternProperties": ["^a$": ["$ref": "#/$defs/tree"]], "propertyNames": ["maxLength": 1]], objects, nil)
                // Composition nested in composition, each level deep.
                ask(
                    "anyOf inside not inside oneOf, \(name)",
                    ["$defs": defs, "oneOf": [["not": ["anyOf": [["$ref": "#/$defs/list"], ["type": "null"]]]], ["type": "array"]]], arrays, nil)
                // Shallow constants compared at the bottom of a deep instance.
                ask(
                    "enum at the bottom, \(name)", ["$defs": ["n": ["anyOf": [["enum": ["x", "y"]], ["type": "array", "items": ["$ref": "#/$defs/n"]]]]], "$ref": "#/$defs/n"],
                    spoiled, nil)
                ask(
                    "enum at the bottom, no match, \(name)", ["$defs": ["n": ["anyOf": [["enum": ["y", "z"]], ["type": "array", "items": ["$ref": "#/$defs/n"]]]]], "$ref": "#/$defs/n"],
                    spoiled, "does not match any of the allowed alternatives")
            }
            // Wide and deep at once, with the violation in the last of many deep branches.
            let branch = nestedValue(.arrays, depth: 200, core: [])
            let wide = JSONValue.array(Array(repeating: branch, count: 30) + [nestedValue(.arrays, depth: 200, core: 7)])
            ask("the last of 31 deep branches is wrong", ["$defs": defs, "$ref": "#/$defs/list"], wide, "expected array, got integer")
            // Beyond what the validator allows at all: the same refusal on any stack.
            var limited = JSONSchema.Limits()
            limited.maxValidationRecursion = 50
            let refusing = try! JSONSchema(["$defs": defs, "$ref": "#/$defs/list"], limits: limited)
            questions.append(Question(name: "more recursion than the limit allows", schema: refusing, instance: nestedValue(.arrays, depth: 100, core: [])))
            if refusing.validate(nestedValue(.arrays, depth: 100, core: []))?.reason != "nested deeper than the validator allows" {
                expectations.append("the recursion limit was not reported")
            }
            let leaves = Array(stride(from: 12 * kib, through: 480 * kib, by: 12 * kib)) + [16 * kib, 20 * kib, 28 * kib, 32 * kib, 34 * kib, 38 * kib, 40 * kib, 44 * kib]
            return (questions.count, Self.differences(questions, leaves: leaves), expectations)
        }
        #expect(count == 90)
        #expect(expectations.isEmpty, "\(expectations)")
        #expect(differences.isEmpty, "\(differences.count) answers changed with the stack: \(differences.prefix(12))")
    }

    /// A violation found on the large stack comes back whole: its reason and every step of its path.
    @Test func violationsComeBackIntactFromTheLargeStack() {
        warmUp()
        let (short, full, direct): (SchemaViolation?, SchemaViolation?, SchemaViolation?) = onThread(stackSize: 64 << 20) {
            let schema = try! JSONSchema([
                "$defs": ["node": ["type": "object", "properties": ["next": ["$ref": "#/$defs/node"], "list": ["type": "array", "items": ["$ref": "#/$defs/node"]]], "required": ["id"]]],
                "$ref": "#/$defs/node",
            ])
            var instance: JSONValue = ["note": "the one without an id"]
            for level in 0..<120 {
                instance = level % 2 == 0 ? ["id": JSONValue(level), "next": instance] : ["id": JSONValue(level), "list": [["id": 0], instance]]
            }
            let value = instance
            return (onExhaustedThread(leaving: 40 * kib) { schema.validate(value) }, schema.validate(value), onThread(stackSize: 64 << 20) { schema.validate(value) })
        }
        #expect(short == full && full == direct)
        #expect(short?.reason == "missing required field")
        // 60 steps through "next", 60 through "list" and its second element, then the field.
        #expect(short?.path.count == 60 + 120 + 1)
        #expect(short?.path.last == "id")
        #expect(short?.path.first == "list")
        #expect(short?.path.filter { $0 == "[1]" }.count == 60)
    }

    @Test func budgetsAcrossTheLargeStackRetry() {
        warmUp()
        typealias Question = (name: String, schema: JSONSchema, value: JSONValue)
        let (questions, expected, leastSteps, leastEvaluations): ([Question], [String?], Int, Int) = onThread(stackSize: 64 << 20) {
            var deep: JSONValue = [:]
            for _ in 0..<150 { deep = ["next": deep] }
            let node: JSONValue = ["type": "object", "properties": ["next": ["$ref": "#/$defs/node"]]]
            let schemaValue: JSONValue = [
                "$defs": ["node": node],
                "type": "object",
                "properties": ["text": ["items": ["not": ["pattern": "x{0,40}y"]]], "deep": ["$ref": "#/$defs/node"]],
            ]
            let value: JSONValue = [
                "text": .array(Array(repeating: .string(String(repeating: "x", count: 150)), count: 8)), "deep": deep,
            ]
            func limits(steps: Int = 100_000_000, evaluations: Int = 10_000_000) -> JSONSchema.Limits {
                var limits = JSONSchema.Limits()
                limits.maxPatternSteps = steps
                limits.maxEvaluations = evaluations
                return limits
            }
            func least(_ valid: (Int) -> Bool) -> Int {
                var low = 0
                var high = 100_000_000
                while low < high {
                    let middle = (low + high) / 2
                    if valid(middle) { high = middle } else { low = middle + 1 }
                }
                return low
            }
            let steps = least { (try! JSONSchema(schemaValue, limits: limits(steps: $0))).validate(value) == nil }
            let evaluations = least { (try! JSONSchema(schemaValue, limits: limits(evaluations: $0))).validate(value) == nil }
            var questions: [Question] = []
            for stepsDelta in [-1, 0, 1] {
                for evaluationsDelta in [-1, 0, 1] {
                    questions.append(("steps \(stepsDelta), evaluations \(evaluationsDelta)",
                        try! JSONSchema(schemaValue, limits: limits(steps: steps + stepsDelta, evaluations: evaluations + evaluationsDelta)), value))
                }
            }
            questions.append(("half the steps", try! JSONSchema(schemaValue, limits: limits(steps: steps / 2)), value))
            questions.append(("half the evaluations", try! JSONSchema(schemaValue, limits: limits(evaluations: evaluations / 2)), value))
            // A budget runs out before the stack does: no retry, the budget's refusal.
            questions.append(("evaluations out at once", try! JSONSchema(schemaValue, limits: limits(evaluations: 10)), value))
            questions.append(("pattern steps out at once", try! JSONSchema(schemaValue, limits: limits(steps: 100)), value))
            // A sticky cut (a self-reference under `not`), then the stack runs out.
            questions.append(("cut, then deep", try! JSONSchema([
                "$defs": ["node": node], "type": "object",
                "properties": ["loop": ["not": ["$ref": "#/properties/loop"]], "deep": ["$ref": "#/$defs/node"]],
            ]), ["loop": 1, "deep": deep]))
            // The stack runs out in the depth check before a comparison, not in the evaluator.
            var nested: JSONValue = [1]
            for _ in 0..<150 { nested = [nested] }
            var nestedOther: JSONValue = [2]
            for _ in 0..<150 { nestedOther = [nestedOther] }
            questions.append(("uniqueItems on deep values, duplicates", try! JSONSchema(["uniqueItems": true]), [nested, nestedOther, nested]))
            questions.append(("uniqueItems on deep values, distinct", try! JSONSchema(["uniqueItems": true]), [nested, nestedOther]))
            questions.append(("const deep, equal", try! JSONSchema(["const": nested]), nested))
            questions.append(("const deep, different", try! JSONSchema(["const": nested]), nestedOther))
            questions.append(("enum deep", try! JSONSchema(["enum": [nestedOther, nested]]), nested))
            let expected = questions.map { $0.schema.validate($0.value)?.reason }
            return (questions, expected, steps, evaluations)
        }
        #expect(leastSteps > 5_000 && leastEvaluations > 150)
        // The table means what it should, on all the stack there is.
        #expect(expected[4] == nil)
        #expect(expected[1] == "matching patterns against this value takes more than \(leastSteps - 1) steps")
        #expect(expected[3] == "checking this value takes more than \(leastEvaluations - 1) steps of the schema")
        #expect(expected[5] == nil && expected[7] == nil && expected[8] == nil)
        #expect(expected[11] == "checking this value takes more than 10 steps of the schema")
        #expect(expected[12] == "matching patterns against this value takes more than 100 steps")
        #expect(expected[13] == "the schema refers to itself without consuming input")
        #expect(expected[14] == "items must be unique" && expected[15] == nil)
        #expect(expected[16] == nil && expected[17] != nil && expected[18] == nil)

        let asked = questions
        for leave in [336, 200, 128, 96, 64, 48, 40, 32, 24].map({ $0 * kib }) {
            let answers = onExhaustedThread(leaving: leave) { asked.map { $0.schema.validate($0.value)?.reason } }
            for (index, answer) in answers.enumerated() {
                #expect(answer == expected[index], "\(asked[index].name) with \(leave / kib) KiB left")
            }
        }

        // Many threads at once, each with a different amount left: the same answers.
        final class Answers: @unchecked Sendable {
            let lock = NSLock()
            var wrong: [String] = []
        }
        let answers = Answers()
        let leaves = [336, 96, 48, 32, 24, 200, 40, 64].map { $0 * kib }
        DispatchQueue.concurrentPerform(iterations: 16) { iteration in
            let leave = leaves[iteration % leaves.count]
            let got = onExhaustedThread(leaving: leave) { asked.map { $0.schema.validate($0.value)?.reason } }
            for (index, answer) in got.enumerated() where answer != expected[index] {
                answers.lock.lock()
                answers.wrong.append("\(asked[index].name), thread \(iteration)")
                answers.lock.unlock()
            }
        }
        #expect(answers.wrong.isEmpty, "\(answers.wrong.prefix(5))")
    }

    /// The retry itself: a thread is made and joined for every validation that runs out of
    /// stack. Thousands in a row, and from many threads at once, leave no threads behind and
    /// always bring the right answer back.
    @Test func theLargeStackRetryLeavesNothingBehind() {
        warmUp()
        func threadCount() -> Int {
            var list: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
            return Int(count)
        }
        let schema = try! JSONSchema(["anyOf": [["type": "array", "items": ["$ref": "#"]], ["type": "integer"]]])
        let valid = nestedValue(.arrays, depth: 150, core: 5)
        let invalid = nestedValue(.arrays, depth: 150, core: "x")
        // On a 64 KiB thread neither fits: every call is retried.
        let before = threadCount()
        let sequential: Int = onThread(stackSize: 64 * kib) {
            var wrong = 0
            for round in 0..<3000 {
                if round % 2 == 0 ? schema.validate(valid) != nil : schema.validate(invalid)?.reason != "does not match any of the allowed alternatives" { wrong += 1 }
            }
            return wrong
        }
        #expect(sequential == 0)
        // Thirty-two threads, each retrying two hundred times.
        let wrong = Slot<Int>()
        wrong.value = 0
        let lock = NSLock()
        let group = DispatchGroup()
        for worker in 0..<32 {
            group.enter()
            let thread = Thread {
                var mistakes = 0
                for round in 0..<200 {
                    let even = (round + worker) % 2 == 0
                    if even ? schema.validate(valid) != nil : schema.validate(invalid) == nil { mistakes += 1 }
                }
                lock.withLock { wrong.value! += mistakes }
                group.leave()
            }
            thread.stackSize = 64 * kib
            thread.start()
        }
        group.wait()
        #expect(wrong.value == 0)
        // From a thread that has next to nothing left.
        for leave in [24, 16, 12, 10, 8] {
            let answers = onExhaustedThread(leaving: leave * kib) { (schema.validate(valid) == nil, schema.validate(invalid) != nil) }
            #expect(answers == (true, true), "with \(leave) KiB of stack left")
        }
        // Give threads that have just finished a moment to be reaped, then count. Other tests
        // start threads of their own meanwhile, so the bound is loose — a leak would be thousands.
        Thread.sleep(forTimeInterval: 0.2)
        let after = threadCount()
        #expect(before > 0 && after - before < 200, "\(before) threads before, \(after) after 9,400 retries")
        // One retry costs a thread: far less than a millisecond.
        let clock = ContinuousClock()
        let shallow: JSONValue = [[1]]
        let elapsed: Duration = onExhaustedThread(leaving: 24 * kib) { clock.measure { for _ in 0..<500 { _ = schema.validate(shallow) } } }
        #expect(elapsed < .seconds(5), "500 retries took \(elapsed)")
    }

    /// Disabled because it uses up every thread the process may have, which no other test
    /// running beside it would survive; run alone it passes. When the thread for the retry
    /// cannot be made, the validation is repeated where it is, runs out of stack again, and the
    /// validator says so: "nested deeper than the validator allows" at the root — a refusal,
    /// never "valid" for a value that is not, and never a branch cut short and read as "no match".
    @Test(.disabled("uses up the process's threads; run alone"))
    func withoutAThreadForTheRetryTheValidatorRefuses() {
        let recursive = try! JSONSchema(["type": "array", "items": ["$ref": "#"]])
        let anyOf = try! JSONSchema(["anyOf": [["type": "array", "items": ["$ref": "#"]], ["type": "integer"]]])
        let never = try! JSONSchema(["not": ["anyOf": [["type": "array", "items": ["$ref": "#"]], ["type": "integer"]]]])
        let instance = nestedValue(.arrays, depth: 200, core: 5)
        let release = DispatchSemaphore(value: 0)
        let context = Unmanaged.passRetained(release).toOpaque()
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        pthread_attr_setstacksize(&attributes, 16 * kib)
        var threads: [pthread_t] = []
        while threads.count < 50_000 {
            var thread: pthread_t?
            let status = pthread_create(&thread, &attributes, { context in
                Unmanaged<DispatchSemaphore>.fromOpaque(context).takeUnretainedValue().wait()
                return nil
            }, context)
            guard status == 0, let thread else { break }
            threads.append(thread)
        }
        let answers = withStackLeft(60 * kib) { [recursive.validate(instance), anyOf.validate(instance), never.validate(instance)] }
        for _ in threads { release.signal() }
        for thread in threads { pthread_join(thread, nil) }
        // The refusal, at the root: no path.
        let refusal = "nested deeper than the validator allows"
        #expect(answers.map { $0?.description } == [refusal, refusal, refusal])
        // With threads to be had again, the same questions get their answers.
        #expect(withStackLeft(60 * kib) { recursive.validate(instance) }?.reason == "expected array, got integer")
        #expect(withStackLeft(60 * kib) { anyOf.validate(instance) } == nil)
        #expect(withStackLeft(60 * kib) { never.validate(instance) }?.reason == "matches a schema it must not match")
    }

    /// The large stack has an end too. A value too deep even for it is refused at the root, in
    /// so many words; it is never taken for valid, and a branch that was cut short is never
    /// read as "does not match".
    @Test func aValueTooDeepEvenForTheLargeStackIsRefused() {
        let answers: [[String]] = onThread(stackSize: 64 << 20) {
            var raised = JSONSchema.Limits()
            raised.maxValidationRecursion = .max
            let limits = raised
            let recursive = try! JSONSchema(["type": "array", "items": ["$ref": "#"]], limits: limits)
            let anyOf = try! JSONSchema(["anyOf": [["type": "array", "items": ["$ref": "#"]], ["type": "integer"]]], limits: limits)
            let never = try! JSONSchema(["not": ["anyOf": [["type": "array", "items": ["$ref": "#"]], ["type": "integer"]]]], limits: limits)
            // Two million levels: more than 64 MiB of validator frames in any build.
            var valid = nestedValue(.arrays, depth: 2_000_000, core: 5)
            var invalid = nestedValue(.arrays, depth: 2_000_000, core: "x")
            var answers: [[String]] = []
            for instance in [valid, invalid] {
                answers.append(onThread(stackSize: 512 * kib) { [recursive, anyOf, never].map { $0.validate(instance)?.description ?? "valid" } })
            }
            // Taken apart level by level: letting values this deep go in one piece recurses too.
            while case .array(let items) = valid, let first = items.first { valid = first }
            while case .array(let items) = invalid, let first = items.first { invalid = first }
            return answers
        }
        // The refusal, at the root: no path.
        let refusal = "nested deeper than the validator allows"
        #expect(answers == [[refusal, refusal, refusal], [refusal, refusal, refusal]])
    }

    /// `const`, `enum` and `uniqueItems` compare whole values, which recurses once per level
    /// and cannot fail, so the validator measures the instance first. When the stack that is
    /// left is too short for the comparison it does not answer: it starts over on the large
    /// stack, like any other run that ran out. So these keywords too give the same answer on
    /// any stack — alone and inside `not`, `anyOf`, `oneOf` and `if`, where a refusal used to
    /// be read as "does not match" and let through an instance that had to be refused.
    @Test func comparingKeywordsGiveTheSameAnswerOnAnyStack() {
        warmUp()
        let (differences, expectations): ([String], [String]) = onThread(stackSize: 64 << 20) {
            var questions: [Question] = []
            var expectations: [String] = []
            func ask(_ name: String, _ schema: JSONValue, _ instance: JSONValue, _ expected: String?) {
                let compiled = try! JSONSchema(schema)
                questions.append(Question(name: name, schema: compiled, instance: instance))
                let found = compiled.validate(instance)?.reason
                if found != expected { expectations.append("\(name): \(found ?? "valid") instead of \(expected ?? "valid")") }
            }
            for depth in [8, 64, 128, 256] {
                for shape in [NestedShape.arrays, .objects] {
                    let value = nestedValue(shape, depth: depth)
                    let twin = nestedValue(shape, depth: depth)
                    let other = nestedValue(shape, depth: depth, core: 2)
                    let name = "\(shape) at depth \(depth)"
                    let brief = depth <= 8 ? value.description : "a value nested \(depth) levels deep"
                    ask("const, equal, \(name)", ["const": value], twin, nil)
                    ask("const, different at the leaf, \(name)", ["const": value], other, "must be " + brief)
                    ask("enum, \(name)", ["enum": [other, value]], twin, nil)
                    ask("uniqueItems, distinct, \(name)", ["uniqueItems": true], [value, other], nil)
                    ask("uniqueItems, a repeat, \(name)", ["uniqueItems": true], [other, value, twin], "items must be unique")
                    // Where a refusal would be read as "does not match".
                    ask("not const, \(name)", ["not": ["const": value]], twin, "matches a schema it must not match")
                    ask("not enum, \(name)", ["not": ["enum": [other, value]]], twin, "matches a schema it must not match")
                    ask("not uniqueItems, distinct, \(name)", ["not": ["uniqueItems": true]], [value, other], "matches a schema it must not match")
                    ask("anyOf const or string, \(name)", ["anyOf": [["const": value], ["type": "string"]]], twin, nil)
                    ask("anyOf enum or string, none, \(name)", ["anyOf": [["enum": [other, 5]], ["type": "string"]]], twin, "does not match any of the allowed alternatives")
                    ask("anyOf uniqueItems or string, \(name)", ["anyOf": [["uniqueItems": true], ["type": "string"]]], [value, twin], "does not match any of the allowed alternatives")
                    ask("oneOf enum or uniqueItems, \(name)", ["oneOf": [["enum": [[value, other]]], ["uniqueItems": true]]], [twin, other], "matches more than one alternative")
                    ask("not anyOf const or enum, \(name)", ["not": ["anyOf": [["const": other], ["enum": [value]]]]], twin, "matches a schema it must not match")
                    ask("allOf not const and uniqueItems, \(name)", ["allOf": [["not": ["const": [other]]], ["uniqueItems": true]]], [value], nil)
                    ask("oneOf const or any, \(name)", ["oneOf": [["const": value], [:]]], twin, "matches more than one alternative")
                    ask("if const then string, \(name)", ["if": ["const": value], "then": ["type": "string"]], twin, "expected string, got \(shape == .arrays ? "array" : "object")")
                }
            }
            let leaves = Array(stride(from: 12 * kib, through: 480 * kib, by: 12 * kib))
            return (Self.differences(questions, leaves: leaves), expectations)
        }
        #expect(expectations.isEmpty, "\(expectations)")
        #expect(differences.isEmpty, "\(differences.count) answers changed with the stack: \(differences.prefix(12))")
    }

    /// The same where the two ways of running out meet: with a little over 32 KiB left the
    /// guard itself trips, a little above that only the comparison is refused, and for a value
    /// a dozen levels deep the two thresholds are a few kilobytes apart. Swept in steps of half
    /// a kilobyte, for the composition keywords around the comparing ones.
    @Test func comparingKeywordsWhereTheTwoRefusalsMeet() {
        warmUp()
        let (count, differences, expectations): (Int, [String], [String]) = onThread(stackSize: 64 << 20) {
            var questions: [Question] = []
            var expectations: [String] = []
            func ask(_ name: String, _ schema: JSONValue, _ instance: JSONValue, _ expected: String?) {
                let compiled = try! JSONSchema(schema)
                questions.append(Question(name: name, schema: compiled, instance: instance))
                let found = compiled.validate(instance)?.reason
                if found != expected { expectations.append("\(name): \(found ?? "valid") instead of \(expected ?? "valid")") }
            }
            let mustNot = "matches a schema it must not match"
            for depth in [1, 4, 8, 10, 12, 14, 16, 20, 24, 32] {
                for shape in [NestedShape.arrays, .objects, .wideObjects] {
                    let value = nestedValue(shape, depth: depth)
                    let twin = nestedValue(shape, depth: depth)
                    let other = nestedValue(shape, depth: depth, core: 2)
                    let name = "\(shape) at depth \(depth)"
                    ask("not const, \(name)", ["not": ["const": value]], twin, mustNot)
                    ask("not const, other, \(name)", ["not": ["const": value]], other, nil)
                    ask("not enum, \(name)", ["not": ["enum": [other, value]]], twin, mustNot)
                    ask("not uniqueItems, \(name)", ["not": ["uniqueItems": true]], [value, other], mustNot)
                    ask("not uniqueItems, a repeat, \(name)", ["not": ["uniqueItems": true]], [value, twin], nil)
                    ask("anyOf const, \(name)", ["anyOf": [["const": value], ["type": "string"]]], twin, nil)
                    ask("anyOf enum, none, \(name)", ["anyOf": [["enum": [other]], ["type": "string"]]], twin, "does not match any of the allowed alternatives")
                    ask("anyOf uniqueItems, a repeat, \(name)", ["anyOf": [["uniqueItems": true], ["type": "string"]]], [twin, value], "does not match any of the allowed alternatives")
                    ask("oneOf const or any, \(name)", ["oneOf": [["const": value], [:]]], twin, "matches more than one alternative")
                    ask("oneOf const or any, other, \(name)", ["oneOf": [["const": value], [:]]], other, nil)
                    ask("oneOf uniqueItems or enum, \(name)", ["oneOf": [["uniqueItems": true], ["enum": [[value, other]]]]], [twin, other], "matches more than one alternative")
                    ask("if const then never, \(name)", ["if": ["const": value], "then": false], twin, "no value is allowed here")
                    ask("if const then never, other, \(name)", ["if": ["const": value], "then": false], other, nil)
                    // Under a recursive schema: the comparison sits at the bottom of a deep run.
                    ask(
                        "const at the bottom of a list, \(name)",
                        ["$defs": ["n": ["anyOf": [["const": value], ["type": "array", "items": ["$ref": "#/$defs/n"], "maxItems": 1]]]], "$ref": "#/$defs/n"],
                        nestedValue(.arrays, depth: 20, core: twin), nil)
                }
            }
            let leaves = Array(stride(from: 20 * kib, through: 96 * kib, by: 512))
            return (questions.count, Self.differences(questions, leaves: leaves), expectations)
        }
        #expect(count == 420)
        #expect(expectations.isEmpty, "\(expectations)")
        #expect(differences.isEmpty, "\(differences.count) answers changed with the stack: \(differences.prefix(12))")
    }

    /// A comparison that fails quotes the schema's own constant in its message, and the instance
    /// that failed may be a scalar: nothing about it says how deep the constant is. So a deeply
    /// nested constant is named, not written out — writing recurses once per level — and the
    /// message is the same on any stack. (When it was written out, a 256-level constant took
    /// the process down in a debug build with less than about 212 KiB of stack left.)
    @Test func aFailedComparisonAgainstADeepConstantOnANearlyExhaustedStack() {
        warmUp()
        struct Question: Sendable {
            var name: String
            var schema: JSONSchema
            var instance: JSONValue
            var message: String
        }
        let general = "nested deeper than the validator allows"
        let tooDeepToCompare = "nested too deeply to compare on the stack that is left"
        let (questions, observations): ([Question], [(leave: Int, reasons: [String?])]) = onThread(stackSize: 64 << 20) {
            var questions: [Question] = []
            let instances: [(name: String, value: JSONValue)] = [("a number", 7), ("a string", "x"), ("null", nil), ("a short array", [1]), ("a small object", ["a": [1, 2]])]
            for depth in [8, 9, 64, 128, 256] {
                for shape in NestedShape.allCases {
                    let constant = nestedValue(shape, depth: depth)
                    let quoted = depth <= 8 ? constant.description : "a value nested \(depth) levels deep"
                    let const = try! JSONSchema(["const": constant])
                    // Thirteen more alternatives of this shape, shallow and deep in turn; the message
                    // lists the first twelve of the fourteen, each on its own terms.
                    let levels = [1, 3, 8, 9, depth / 2 + 1, depth, 2, depth, 7, 10, depth, 5, 4]
                    let alternatives = levels.map { nestedValue(shape, depth: $0, core: "alt") }
                    let enumeration = try! JSONSchema(["enum": .array([constant] + alternatives)])
                    let listed = zip([constant] + alternatives, [depth] + levels).prefix(12).map { value, own in
                        own <= 8 ? value.description : "a value nested \(own) levels deep"
                    }
                    for (label, instance) in instances {
                        questions.append(
                            Question(name: "const of \(depth) levels of \(shape) against \(label)", schema: const, instance: instance, message: "must be " + quoted))
                        questions.append(
                            Question(
                                name: "enum up to \(depth) levels of \(shape) against \(label)", schema: enumeration, instance: instance,
                                message: "must be one of: " + listed.joined(separator: ", ")))
                    }
                }
            }
            let asked = questions
            let observations = stride(from: 16 * kib, through: 480 * kib, by: 2 * kib).map { leave in
                (leave, onExhaustedThread(leaving: leave) { asked.map { $0.schema.validate($0.instance)?.reason } })
            }
            // And once with all the stack there is: the messages themselves.
            return (questions, observations + [(64 << 20, asked.map { $0.schema.validate($0.instance)?.reason })])
        }
        var failures = 0
        for (leave, reasons) in observations {
            for (index, reason) in reasons.enumerated() {
                // The message, whole and unchanged — or, with next to no stack, a refusal to start.
                let refused = (reason == general || reason == tooDeepToCompare) && leave < 48 * kib
                if reason != questions[index].message, !refused {
                    failures += 1
                    if failures <= 10 {
                        Issue.record("\(questions[index].name) with \(leave) bytes of stack left: \(reason?.prefix(80) ?? "valid")")
                    }
                }
            }
        }
        #expect(failures == 0)
        #expect(questions.count == 200)
    }

    @Test func deepValueOperationsFitTheDocumentedStack() {
        warmUp()
        let completed: [Bool] = onThread(stackSize: 64 << 20) {
            var completed: [Bool] = []
            for depth in [8, 32, 64, 128, 256] {
                for shape in NestedShape.allCases {
                    let value = nestedValue(shape, depth: depth)
                    let twin = nestedValue(shape, depth: depth)
                    let text = Array(value.description.utf8)
                    // Warm the same paths at this depth with all the stack in the world.
                    _ = value == twin
                    _ = value.encoded()
                    let leave = depth * 1536 + 16 * kib
                    completed.append(onExhaustedThread(leaving: leave) { value == twin })
                    completed.append(onExhaustedThread(leaving: leave) { value.hashValue == twin.hashValue })
                    completed.append(onExhaustedThread(leaving: leave) { value.encoded() == text })
                    completed.append(onExhaustedThread(leaving: leave) { value.description.utf8.count == text.count })
                    completed.append(onExhaustedThread(leaving: leave) { Set([value, twin]).count == 1 })
                    // Built and destroyed right there.
                    completed.append(onExhaustedThread(leaving: leave) { nestedValue(shape, depth: depth) == value })
                    // Parsed and destroyed right there. (The fallback asks for more stack than
                    // this before it starts, and refuses; that is its own rule, checked above.)
                    let parsed = onExhaustedThread(leaving: leave) { (try? JSON.parse(text, options: JSONParseOptions(maxDepth: 256))) != nil }
                    if JSON.codec == .limb { completed.append(parsed) }
                }
            }
            return completed
        }
        #expect(completed.count >= 120)
        #expect(completed.allSatisfy { $0 })
    }

    /// The claim behind the parser's ceiling: a value as deep as it gets can be parsed, compared
    /// with a separately parsed equal, hashed, written, described and let go on the stack a
    /// handler has, in any build. (Under the fallback the ceiling is 128.)
    @Test func aValueAtTheDepthCeilingOnAHandlerThread() {
        let ceiling = JSON.codec == .limb ? JSONParseOptions.depthCeiling : 128
        let documents: [String] = [
            String(repeating: "[", count: ceiling) + String(repeating: "]", count: ceiling),
            String(repeating: "{\"a\":", count: ceiling) + "1" + String(repeating: "}", count: ceiling),
            String(repeating: "[{\"a\":", count: ceiling / 2) + "null" + String(repeating: "}]", count: ceiling / 2),
            String(repeating: "{\"k1\":1,\"k2\":\"two\",\"k3\":[1,2,3],\"nested\":", count: ceiling - 1) + "{}" + String(repeating: ",\"k5\":null,\"k6\":{\"x\":true}}", count: ceiling - 1),
        ]
        let options = JSONParseOptions(maxDepth: .max)
        for (index, text) in documents.enumerated() {
            let bytes = Array(text.utf8)
            let passed = onThread(stackSize: 512 * kib) { () -> [Bool] in
                guard let value = try? JSON.parse(bytes, options: options), let twin = try? JSON.parse(bytes, options: options) else { return [false] }
                var checks = [value == twin, value.hashValue == twin.hashValue, Set([value, twin]).count == 1]
                checks.append(value.encoded().count == twin.description.utf8.count)
                let const = try? JSONSchema(["const": value])
                checks.append(const.map { $0.validate(twin) == nil } ?? false)
                let unique = try? JSONSchema(["uniqueItems": true])
                checks.append(unique?.validate([value, twin])?.reason == "items must be unique")
                return checks
                // Both values are destroyed here, on this thread.
            }
            #expect(passed == [Bool](repeating: true, count: 6), "document \(index): \(passed)")
        }
    }

    /// One level past the ceiling there is no value to destroy: the parser refuses, whatever
    /// `maxDepth` says and however small the thread. (Before the ceiling existed, 100,000 closed
    /// brackets parsed and the process died when the value was dropped.)
    @Test func nestingBeyondTheCeilingIsRefused() {
        let ceiling = JSON.codec == .limb ? JSONParseOptions.depthCeiling : 128
        for count in [ceiling + 1, 1000, 100_000] {
            let documents = [
                String(repeating: "[", count: count) + String(repeating: "]", count: count),
                String(repeating: "{\"a\":", count: count) + "1" + String(repeating: "}", count: count),
            ]
            for text in documents {
                let bytes = Array(text.utf8)
                for size in [64, 512, 8192] {
                    for limit in [Int.max, 100_000, ceiling + 1] {
                        let result = onThread(stackSize: size * kib) { parse(bytes, JSONParseOptions(maxDepth: limit)) }
                        #expect(Verdict(result) == .tooDeep, "\(count) levels with maxDepth \(limit) on a \(size) KiB stack: \(Verdict(result))")
                    }
                }
            }
        }
    }

    /// The reproducer for the documented limit above. Disabled because these do not fail, they
    /// kill the test process with SIGBUS: the operations on a 256-level value with far less stack
    /// than `deepValueOperationsFitTheDocumentedStack` grants them.
    @Test(.disabled("crashes with SIGBUS by design: ==, hashing, encoded() and deinit of a deep value cannot fail"))
    func deepValuesOnANearlyExhaustedStack() {
        warmUp()
        let survived: Bool = onThread(stackSize: 64 << 20) {
            let value = nestedValue(.objects, depth: 256)
            let twin = nestedValue(.objects, depth: 256)
            var results: [Bool] = []
            for leave in [256, 128, 64, 32, 16] {
                results.append(onExhaustedThread(leaving: leave * kib) { value == twin })
                results.append(onExhaustedThread(leaving: leave * kib) { value.hashValue == twin.hashValue })
                results.append(onExhaustedThread(leaving: leave * kib) { !value.encoded().isEmpty })
                results.append(onExhaustedThread(leaving: leave * kib) { !value.description.isEmpty })
                results.append(onExhaustedThread(leaving: leave * kib) { nestedValue(.objects, depth: 256) == value })
            }
            return results.allSatisfy { $0 }
        }
        #expect(survived)
    }
}
#endif
