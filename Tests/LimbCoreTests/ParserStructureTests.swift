import Foundation
import LimbCore
import Testing

// The structure of a JSON text: containers, separators, limits and where exactly a broken text
// is refused. The default parser keeps nesting in an array instead of the call stack, so every
// state a recursive parser gets for free from its frames is spelled out here.
//
// What is accepted is checked in both builds. Error kinds and offsets, duplicate keys, member
// order and number text belong to the default codec only: the fallback documents that it has
// no positions, does not see duplicates, and keeps neither order nor text.

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What a parse came to, with the error taken apart: `JSONParseError` has no public initializer.
private enum Parse: Equatable, CustomStringConvertible {
    case value(JSONValue)
    case failure(JSONParseError.Kind, Int)

    init(_ bytes: [UInt8], _ options: JSONParseOptions = .default) {
        do { self = .value(try JSON.parse(bytes, options: options)) } catch { self = .failure(error.kind, error.offset) }
    }

    init(_ text: String, _ options: JSONParseOptions = .default) {
        do { self = .value(try JSON.parse(text, options: options)) } catch { self = .failure(error.kind, error.offset) }
    }

    var description: String {
        switch self {
        case .value(let value): "value \(value)"
        case .failure(let kind, let offset): "\(kind) at \(offset)"
        }
    }
}

// MARK: - A document written by the test

/// Writes a value the way `JSONWriter` does not: any whitespace anywhere it is allowed.
private func spell(_ value: JSONValue, whitespace: Bool, _ generator: inout SplitMix64) -> String {
    func gap(_ generator: inout SplitMix64) -> String {
        guard whitespace else { return "" }
        return ["", "", "", " ", "\n", "\t", "\r", "  ", " \r\n\t "].randomElement(using: &generator)!
    }
    func quoted(_ string: String) -> String {
        var text = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0..<0x20:
                let hex = String(scalar.value, radix: 16)
                text += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text + "\""
    }
    switch value {
    case .null: return "null"
    case .bool(let flag): return flag ? "true" : "false"
    case .number(let number): return number.description
    case .string(let string): return quoted(string)
    case .array(let items):
        var text = "[" + gap(&generator)
        for (index, item) in items.enumerated() {
            if index > 0 { text += "," + gap(&generator) }
            text += spell(item, whitespace: whitespace, &generator) + gap(&generator)
        }
        return text + "]"
    case .object(let object):
        var text = "{" + gap(&generator)
        for (index, member) in object.enumerated() {
            if index > 0 { text += "," + gap(&generator) }
            text += quoted(member.key) + gap(&generator) + ":" + gap(&generator)
            text += spell(member.value, whitespace: whitespace, &generator) + gap(&generator)
        }
        return text + "}"
    }
}

/// A random value both codecs can carry: 64-bit integers, doubles of ordinary size, and strings
/// that do not start with U+FEFF. Keys are unique within an object.
private func randomValue(depth: Int, _ generator: inout SplitMix64) -> JSONValue {
    let scalars: [UInt32] = [
        0x00, 0x09, 0x0A, 0x1F, 0x20, 0x22, 0x2F, 0x5C, 0x61, 0x62, 0x7F, 0xE9, 0x301, 0x2028, 0x4E2D, 0xFEFF, 0xFFFE, 0x1F600,
        0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3A,
    ]
    func string(_ generator: inout SplitMix64) -> String {
        var text = ""
        for _ in 0..<Int.random(in: 0...6, using: &generator) {
            text.unicodeScalars.append(Unicode.Scalar(scalars.randomElement(using: &generator)!)!)
        }
        if text.unicodeScalars.first?.value == 0xFEFF { text = "x" + text }
        return text
    }
    let kinds = depth > 0 ? 8 : 6
    switch Int.random(in: 0..<kinds, using: &generator) {
    case 0: return .null
    case 1: return .bool(Bool.random(using: &generator))
    case 2:
        let pick = Int.random(in: 0..<6, using: &generator)
        let edges: [Int64] = [0, 1, -1, 7, -12345, .max, .min, 9_007_199_254_740_993, 999_999_999_999_999_999]
        return pick == 0 ? .number(JSONNumber(edges.randomElement(using: &generator)!)) : .number(JSONNumber(Int64.random(in: -1000...1000, using: &generator)))
    case 3:
        let exponent = Int.random(in: -12...12, using: &generator)
        return JSONValue(Double.random(in: -10...10, using: &generator) * pow(10, Double(exponent)))
    case 4, 5: return .string(string(&generator))
    case 6:
        return .array((0..<Int.random(in: 0...5, using: &generator)).map { _ in randomValue(depth: depth - 1, &generator) })
    default:
        var object = JSONObject()
        for _ in 0..<Int.random(in: 0...5, using: &generator) {
            let key = string(&generator)
            if !object.contains(key) { object.appendUnchecked(key, randomValue(depth: depth - 1, &generator)) }
        }
        return .object(object)
    }
}

/// Keys in document order, depth first: equality of objects ignores order, this does not.
private func keyOrder(_ value: JSONValue) -> [String] {
    switch value {
    case .array(let items): return items.flatMap(keyOrder)
    case .object(let object): return object.flatMap { [$0.key] + keyOrder($0.value) }
    default: return []
    }
}

private final class Slot<Value>: @unchecked Sendable {
    var value: Value?
}

/// Runs `body` on a thread with a 64 MiB stack and waits for the result.
private func onRoomyThread<Value: Sendable>(_ body: @escaping @Sendable () -> Value) -> Value {
    let slot = Slot<Value>()
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
        slot.value = body()
        finished.signal()
    }
    thread.stackSize = 64 << 20
    thread.start()
    finished.wait()
    return slot.value!
}

// MARK: - Both builds

@Suite struct ParserStructureTests {
    static let scalars: [(text: String, value: JSONValue)] = [
        ("null", .null), ("true", true), ("false", false), ("0", 0), ("-1", -1), ("12", 12), ("1.5", 1.5), ("-2.5e-3", -0.0025),
        ("\"s\"", "s"), ("\"\"", ""), ("\"a\\\"b\"", "a\"b"), ("[]", []), ("{}", [:]), ("[[]]", [[]]), ("{\"x\":{}}", ["x": [:]]),
    ]

    /// Every kind of value in every seat: alone, first, in the middle, last, as a member's value,
    /// and one and two levels down.
    @Test func everyValueInEverySeat() throws {
        for (text, value) in Self.scalars {
            for (other, otherValue) in Self.scalars {
                let cases: [(String, JSONValue)] = [
                    (text, value),
                    ("[\(text)]", [value]),
                    ("[\(text),\(other)]", [value, otherValue]),
                    ("[\(other),\(text)]", [otherValue, value]),
                    ("[\(other),\(text),\(other)]", [otherValue, value, otherValue]),
                    ("{\"k\":\(text)}", ["k": value]),
                    ("{\"k\":\(text),\"o\":\(other)}", ["k": value, "o": otherValue]),
                    ("{\"o\":\(other),\"k\":\(text)}", ["o": otherValue, "k": value]),
                    ("{\"a\":\(other),\"k\":\(text),\"z\":\(other)}", ["a": otherValue, "k": value, "z": otherValue]),
                    ("[[\(text)],\(other)]", [[value], otherValue]),
                    ("[\(other),[\(text)]]", [otherValue, [value]]),
                    ("[{\"k\":\(text)},\(other)]", [["k": value], otherValue]),
                    ("{\"k\":[\(text),\(other)]}", ["k": [value, otherValue]]),
                    ("{\"k\":{\"k\":\(text)},\"o\":\(other)}", ["k": ["k": value], "o": otherValue]),
                    ("[[[\(text)]],[[\(other)]]]", [[[value]], [[otherValue]]]),
                ]
                for (document, expected) in cases {
                    #expect(Parse(document) == .value(expected), "\(document)")
                    #expect(Parse(Array(document.utf8)) == .value(expected), "\(document) as bytes")
                }
            }
        }
    }

    /// Whitespace between any two tokens, before the first and after the last, changes nothing.
    @Test func whitespaceInEveryPosition() throws {
        let documents: [[String]] = [
            ["[", "]"], ["{", "}"], ["1"], ["\"s\""], ["null"],
            ["[", "1", "]"], ["[", "1", ",", "2", "]"], ["[", "[", "]", ",", "{", "}", "]"],
            ["{", "\"a\"", ":", "1", "}"], ["{", "\"a\"", ":", "1", ",", "\"b\"", ":", "2", "}"],
            ["{", "\"a\"", ":", "[", "1", ",", "true", ",", "null", "]", ",", "\"b\"", ":", "{", "\"c\"", ":", "\"d\"", "}", "}"],
            ["[", "{", "\"a\"", ":", "{", "}", "}", ",", "[", "[", "]", "]", ",", "-1.5e3", ",", "false", "]"],
        ]
        for tokens in documents {
            let expected = try JSON.parse(tokens.joined())
            for space in [" ", "\n", "\t", "\r", " \r\n\t ", String(repeating: " ", count: 64)] {
                for position in 0...tokens.count {
                    var pieces = tokens
                    pieces.insert(space, at: position)
                    #expect(Parse(pieces.joined()) == .value(expected), "\(tokens.joined()) with space at \(position)")
                }
                #expect(Parse(space + tokens.joined(separator: space) + space) == .value(expected), "\(tokens.joined()) spaced out")
            }
            // What is not JSON whitespace is not whitespace anywhere.
            for junk in ["\u{0B}", "\u{0C}", "\u{A0}", "\u{2028}", "/**/"] {
                for position in 0...tokens.count {
                    var pieces = tokens
                    pieces.insert(junk, at: position)
                    if case .value = Parse(pieces.joined()) { Issue.record("\(tokens.joined()) accepted \(junk.debugDescription) at \(position)") }
                }
            }
        }
    }

    /// Random values, written out by the test with random whitespace, come back as themselves.
    @Test func generatedDocumentsComeBackAsWritten() throws {
        var generator = SplitMix64(state: 0x5354_5255)
        var failures = 0
        for iteration in 0..<6000 {
            let value = randomValue(depth: Int.random(in: 0...6, using: &generator), &generator)
            let text = spell(value, whitespace: iteration % 2 == 0, &generator)
            let found = iteration % 3 == 0 ? Parse(Array(text.utf8)) : Parse(text)
            var wrong = found != .value(value)
            #if !FoundationJSON
            // Member order and the text of every number, not just equality.
            if case .value(let parsed) = found {
                if keyOrder(parsed) != keyOrder(value) { wrong = true }
                if parsed.description != value.description { wrong = true }
            }
            #endif
            if wrong {
                failures += 1
                if failures <= 10 { Issue.record("iteration \(iteration): \(text.debugDescription) came back as \(found)") }
            }
        }
        #expect(failures == 0)
    }

    /// `maxDepth` counts open containers, and an empty one counts like any other.
    @Test func depthLimitBoundaries() {
        func nested(_ open: String, _ close: String, _ depth: Int, _ core: String) -> String {
            String(repeating: open, count: depth) + core + String(repeating: close, count: depth)
        }
        for limit in [0, 1, 2, 3, 7, 64, 127, 128] {
            let options = JSONParseOptions(maxDepth: limit)
            let shapes: [(open: String, close: String, core: String, step: Int)] = [
                ("[", "]", "", 1), ("{\"a\":", "}", "1", 5), ("[", "]", "1", 1), ("[", "]", "\"s\"", 1),
            ]
            for (open, close, core, step) in shapes {
                // Exactly at the limit.
                if limit > 0 {
                    if case .failure = Parse(nested(open, close, limit, core), options) {
                        Issue.record("\(limit) levels of \(open) were refused with maxDepth \(limit)")
                    }
                }
                // One more level, whether it holds something, is empty, or is never closed.
                for innermost in [open + core + close, "[]", "{}", "[", "{"] {
                    let text = String(repeating: open, count: limit) + innermost + String(repeating: close, count: limit)
                    let found = Parse(text, options)
                    guard case .failure(let kind, let offset) = found else {
                        Issue.record("\(limit) levels of \(open) around \(innermost) were accepted with maxDepth \(limit)")
                        continue
                    }
                    guard case .depthLimitExceeded = kind else {
                        Issue.record("\(limit) levels of \(open) around \(innermost): \(found)")
                        continue
                    }
                    #if !FoundationJSON
                    // The error names the limit and points at the bracket that crossed it.
                    #expect(found == .failure(.depthLimitExceeded(limit), limit * step), "\(open) around \(innermost), maxDepth \(limit)")
                    #else
                    _ = offset
                    #endif
                }
            }
            // Siblings do not add up, however many there are.
            if limit >= 2 {
                let siblings = "[" + Array(repeating: nested("[", "]", limit - 1, ""), count: 50).joined(separator: ",") + "]"
                if case .failure = Parse(siblings, options) { Issue.record("50 siblings of depth \(limit - 1) were refused with maxDepth \(limit)") }
            }
        }
        // Scalars need no depth at all; a negative limit refuses every container.
        #expect(Parse("1", JSONParseOptions(maxDepth: 0)) == .value(1))
        #expect(Parse("\"[\"", JSONParseOptions(maxDepth: 0)) == .value("["))
        #expect(Parse("1", JSONParseOptions(maxDepth: .min)) == .value(1))
        for text in ["[]", "{}", "[1]", "[[]]"] {
            for limit in [0, -1, Int.min] {
                guard case .failure(.depthLimitExceeded, _) = Parse(text, JSONParseOptions(maxDepth: limit)) else {
                    Issue.record("\(text) with maxDepth \(limit): \(Parse(text, JSONParseOptions(maxDepth: limit)))")
                    continue
                }
            }
        }
    }

    /// `maxNodes` counts values: containers and scalars alike, keys not at all.
    @Test func nodeLimitBoundaries() {
        let documents: [(text: String, nodes: Int)] = [
            ("1", 1), ("\"s\"", 1), ("[]", 1), ("{}", 1), ("[1]", 2), ("[[]]", 2), ("[{}]", 2), ("{\"a\":1}", 2), ("{\"a\":[]}", 2),
            ("[1,2,3]", 4), ("[[],[],[]]", 4), ("{\"a\":1,\"b\":2,\"c\":3}", 4), ("[[1,\"a\"],{\"b\":null}]", 6),
            ("{\"a\":{\"b\":{\"c\":[1,2]}}}", 6), ("[[[[[[[]]]]]]]", 7), ("[null,true,false,0,\"\",[],{}]", 8),
        ]
        for (text, nodes) in documents {
            if case .failure = Parse(text, JSONParseOptions(maxNodes: nodes)) { Issue.record("\(text) refused with maxNodes \(nodes)") }
            if case .failure = Parse(text, JSONParseOptions(maxNodes: nodes + 1)) { Issue.record("\(text) refused with maxNodes \(nodes + 1)") }
            for limit in [nodes - 1, 0, -1] {
                guard case .failure(.nodeLimitExceeded(limit), _) = Parse(text, JSONParseOptions(maxNodes: limit)) else {
                    Issue.record("\(text) with maxNodes \(limit): \(Parse(text, JSONParseOptions(maxNodes: limit)))")
                    continue
                }
            }
        }
        func zeros(_ count: Int) -> String { "[" + Array(repeating: "0", count: count).joined(separator: ",") + "]" }
        guard case .value = Parse(zeros(999_999)) else {
            Issue.record("a million values were refused")
            return
        }
        guard case .failure(.nodeLimitExceeded(1_000_000), _) = Parse(zeros(1_000_000)) else {
            Issue.record("a million and one values: \(Parse(zeros(1_000_000)))")
            return
        }
    }

    /// Size must cost time in proportion and nothing else: wide, long and deep.
    @Test func largeDocumentsTakeLinearTime() {
        let clock = ContinuousClock()
        func seconds(_ text: String, _ options: JSONParseOptions = .default) -> Double {
            let bytes = Array(text.utf8)
            let elapsed = clock.measure { _ = Parse(bytes, options) }
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        func wideArray(_ count: Int) -> String { "[" + Array(repeating: "[0,\"s\"]", count: count).joined(separator: ",") + "]" }
        func wideObject(_ count: Int) -> String { "{" + (0..<count).map { "\"key\($0)\":\($0)" }.joined(separator: ",") + "}" }
        // As deep as both codecs go, many times over.
        func deep(_ count: Int) -> String {
            let one = String(repeating: "[{\"a\":", count: 50) + "1" + String(repeating: "}]", count: 50)
            return "[" + Array(repeating: one, count: count).joined(separator: ",") + "]"
        }
        let shapes: [(name: String, make: (Int) -> String, small: Int, options: JSONParseOptions)] = [
            ("an array of pairs", wideArray, 40_000, .default),
            ("an object", wideObject, 40_000, .default),
            ("deep siblings", deep, 500, .default),
        ]
        for (name, make, small, options) in shapes {
            let once = (0..<3).map { _ in seconds(make(small), options) }.min()!
            let fourfold = (0..<3).map { _ in seconds(make(small * 4), options) }.min()!
            // Four times the input in at most about eight times the time; quadratic work would take sixteen.
            #expect(fourfold < once * 10 + 0.05, "\(name): \(small) took \(once) s, \(small * 4) took \(fourfold) s")
        }
    }
}

// MARK: - The default codec

#if !FoundationJSON

/// `count` strings (at most 5040) that Swift's `String` considers equal and JSON does not: one
/// letter followed by seven combining marks of seven different combining classes, in every
/// order. Marks of different classes may be reordered without changing the text canonically.
private func equivalentSpellings(_ count: Int) -> [String] {
    // Overlay, nukta, kana voicing, cedilla, horn, below, above.
    let marks: [Unicode.Scalar] = ["\u{334}", "\u{93C}", "\u{3099}", "\u{327}", "\u{31B}", "\u{316}", "\u{301}"]
    var spellings: [String] = []
    var order = Array(marks.indices)
    func permute(_ start: Int) {
        guard spellings.count < count else { return }
        if start == order.count {
            var text = "a"
            for index in order { text.unicodeScalars.append(marks[index]) }
            spellings.append(text)
            return
        }
        for index in start..<order.count {
            order.swapAt(start, index)
            permute(start + 1)
            order.swapAt(start, index)
        }
    }
    permute(0)
    return spellings
}

/// A second parser, recursive and plain, written from the grammar and from what the errors are
/// documented to mean. It exists only to disagree with the real one.
private struct Reference {
    struct Failure: Error {
        var kind: JSONParseError.Kind
        var offset: Int
    }

    let bytes: [UInt8]
    let options: JSONParseOptions
    var index = 0
    var nodes = 0
    var depth = 0

    static func parse(_ bytes: [UInt8], _ options: JSONParseOptions) -> Parse {
        if let offset = firstIllFormedUTF8(bytes) { return .failure(.invalidUTF8, offset) }
        var reference = Reference(bytes: bytes, options: options)
        do {
            reference.skipWhitespace()
            let value = try reference.value()
            reference.skipWhitespace()
            guard reference.index == bytes.count else { return .failure(.trailingData, reference.index) }
            return .value(value)
        } catch {
            return .failure(error.kind, error.offset)
        }
    }

    static func firstIllFormedUTF8(_ bytes: [UInt8]) -> Int? {
        var start = 0
        while start < bytes.count {
            let lead = bytes[start]
            let ranges: [ClosedRange<UInt8>]
            switch lead {
            case 0x00...0x7F: ranges = []
            case 0xC2...0xDF: ranges = [0x80...0xBF]
            case 0xE0: ranges = [0xA0...0xBF, 0x80...0xBF]
            case 0xED: ranges = [0x80...0x9F, 0x80...0xBF]
            case 0xE1...0xEF: ranges = [0x80...0xBF, 0x80...0xBF]
            case 0xF0: ranges = [0x90...0xBF, 0x80...0xBF, 0x80...0xBF]
            case 0xF4: ranges = [0x80...0x8F, 0x80...0xBF, 0x80...0xBF]
            case 0xF1...0xF3: ranges = [0x80...0xBF, 0x80...0xBF, 0x80...0xBF]
            default: return start
            }
            for (offset, range) in ranges.enumerated() {
                let position = start + 1 + offset
                guard position < bytes.count, range.contains(bytes[position]) else { return start }
            }
            start += 1 + ranges.count
        }
        return nil
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    func fail(_ kind: JSONParseError.Kind, _ offset: Int) -> Failure { Failure(kind: kind, offset: offset) }

    mutating func value() throws(Failure) -> JSONValue {
        guard index < bytes.count else { throw fail(.unexpectedEnd, index) }
        nodes += 1
        if nodes > options.maxNodes { throw fail(.nodeLimitExceeded(options.maxNodes), index) }
        let byte = bytes[index]
        switch byte {
        case 0x22: return .string(try string())
        case 0x5B: return try array()
        case 0x7B: return try object()
        case 0x2D, 0x30...0x39: return try number()
        case 0x74: return try literal("true", true)
        case 0x66: return try literal("false", false)
        case 0x6E: return try literal("null", .null)
        default: throw fail(.unexpectedByte(byte), index)
        }
    }

    /// A literal is judged as a whole: too short is the end of input, anything else is its first byte.
    mutating func literal(_ word: String, _ value: JSONValue) throws(Failure) -> JSONValue {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count else { throw fail(.unexpectedEnd, index) }
        guard Array(bytes[index..<index + expected.count]) == expected else { throw fail(.unexpectedByte(bytes[index]), index) }
        index += expected.count
        return value
    }

    mutating func enter() throws(Failure) {
        depth += 1
        let limit = min(options.maxDepth, JSONParseOptions.depthCeiling)
        if depth > limit { throw fail(.depthLimitExceeded(limit), index) }
        index += 1
        skipWhitespace()
        guard index < bytes.count else { throw fail(.unexpectedEnd, index) }
    }

    /// After a member: a comma (true) or the closer (false).
    mutating func more(closer: UInt8) throws(Failure) -> Bool {
        skipWhitespace()
        guard index < bytes.count else { throw fail(.unexpectedEnd, index) }
        let byte = bytes[index]
        index += 1
        if byte == 0x2C { return true }
        if byte == closer { return false }
        throw fail(.unexpectedByte(byte), index - 1)
    }

    mutating func array() throws(Failure) -> JSONValue {
        try enter()
        var items: [JSONValue] = []
        if bytes[index] == 0x5D {
            index += 1
        } else {
            repeat {
                skipWhitespace()
                items.append(try value())
            } while try more(closer: 0x5D)
        }
        depth -= 1
        return .array(items)
    }

    mutating func object() throws(Failure) -> JSONValue {
        try enter()
        var keys: [String] = []
        var values: [JSONValue] = []
        if bytes[index] == 0x7D {
            index += 1
        } else {
            repeat {
                skipWhitespace()
                guard index < bytes.count else { throw fail(.unexpectedEnd, index) }
                guard bytes[index] == 0x22 else { throw fail(.unexpectedByte(bytes[index]), index) }
                let keyOffset = index
                let key = try string()
                let existing = keys.firstIndex { Array($0.utf8) == Array(key.utf8) }
                if options.rejectDuplicateKeys, existing != nil { throw fail(.duplicateKey(key), keyOffset) }
                skipWhitespace()
                guard index < bytes.count else { throw fail(.unexpectedEnd, index) }
                guard bytes[index] == 0x3A else { throw fail(.unexpectedByte(bytes[index]), index) }
                index += 1
                skipWhitespace()
                let member = try value()
                if let existing { values[existing] = member } else {
                    keys.append(key)
                    values.append(member)
                }
            } while try more(closer: 0x7D)
        }
        depth -= 1
        var object = JSONObject()
        for (key, member) in zip(keys, values) { object.appendUnchecked(key, member) }
        return .object(object)
    }

    mutating func number() throws(Failure) -> JSONValue {
        let start = index
        func isDigit(_ at: Int) -> Bool { at < bytes.count && bytes[at] >= 0x30 && bytes[at] <= 0x39 }
        var cursor = index
        if bytes[cursor] == 0x2D {
            cursor += 1
            guard cursor < bytes.count else { throw fail(.unexpectedEnd, cursor) }
        }
        guard isDigit(cursor) else { throw fail(.invalidNumber, cursor) }
        if bytes[cursor] == 0x30 {
            cursor += 1
            if isDigit(cursor) { throw fail(.invalidNumber, cursor) }
        } else {
            while isDigit(cursor) { cursor += 1 }
        }
        func digits(_ cursor: inout Int) throws(Failure) {
            guard isDigit(cursor) else { throw fail(cursor < bytes.count ? .invalidNumber : .unexpectedEnd, cursor) }
            while isDigit(cursor) { cursor += 1 }
        }
        if cursor < bytes.count, bytes[cursor] == 0x2E {
            cursor += 1
            try digits(&cursor)
        }
        if cursor < bytes.count, bytes[cursor] == 0x65 || bytes[cursor] == 0x45 {
            cursor += 1
            if cursor < bytes.count, bytes[cursor] == 0x2B || bytes[cursor] == 0x2D { cursor += 1 }
            try digits(&cursor)
        }
        index = cursor
        return .number(JSONNumber(lexeme: String(decoding: bytes[start..<cursor], as: UTF8.self))!)
    }

    mutating func hex4(_ cursor: inout Int) throws(Failure) -> UInt32 {
        guard cursor + 4 <= bytes.count else { throw fail(.unexpectedEnd, cursor) }
        var value: UInt32 = 0
        for offset in 0..<4 {
            guard let digit = UInt32(String(UnicodeScalar(bytes[cursor + offset])), radix: 16) else {
                throw fail(.invalidUnicodeEscape, cursor + offset)
            }
            value = value << 4 | digit
        }
        cursor += 4
        return value
    }

    mutating func string() throws(Failure) -> String {
        var cursor = index + 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() {
            scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
            raw.removeAll()
        }
        while true {
            guard cursor < bytes.count else { throw fail(.unexpectedEnd, cursor) }
            let byte = bytes[cursor]
            if byte == 0x22 { break }
            if byte < 0x20 { throw fail(.controlCharacterInString, cursor) }
            if byte != 0x5C {
                raw.append(byte)
                cursor += 1
                continue
            }
            flush()
            cursor += 1
            guard cursor < bytes.count else { throw fail(.unexpectedEnd, cursor) }
            let escape = bytes[cursor]
            cursor += 1
            let simple: [UInt8: Unicode.Scalar] = [
                0x22: "\"", 0x5C: "\\", 0x2F: "/", 0x62: "\u{08}", 0x66: "\u{0C}", 0x6E: "\n", 0x72: "\r", 0x74: "\t",
            ]
            if let scalar = simple[escape] {
                scalars.append(scalar)
            } else if escape == 0x75 {
                var code = try hex4(&cursor)
                if (0xD800...0xDBFF).contains(code) {
                    guard cursor + 1 < bytes.count, bytes[cursor] == 0x5C, bytes[cursor + 1] == 0x75 else {
                        throw fail(.invalidUnicodeEscape, cursor)
                    }
                    cursor += 2
                    let low = try hex4(&cursor)
                    guard (0xDC00...0xDFFF).contains(low) else { throw fail(.invalidUnicodeEscape, cursor) }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(code) {
                    throw fail(.invalidUnicodeEscape, cursor)
                }
                scalars.append(Unicode.Scalar(code)!)
            } else {
                throw fail(.invalidEscape, cursor - 1)
            }
        }
        flush()
        index = cursor + 1
        return String(scalars)
    }
}

@Suite struct DefaultParserStructureTests {
    static let malformed: [(text: String, kind: JSONParseError.Kind, offset: Int)] = [
        // Nothing, or not a value.
        ("", .unexpectedEnd, 0), (" ", .unexpectedEnd, 1), ("\n\t ", .unexpectedEnd, 3),
        ("]", .unexpectedByte(0x5D), 0), ("}", .unexpectedByte(0x7D), 0), (",", .unexpectedByte(0x2C), 0), (":", .unexpectedByte(0x3A), 0),
        (" x", .unexpectedByte(0x78), 1),
        // After a complete value.
        ("1 2", .trailingData, 2), ("[] []", .trailingData, 3), ("[]]", .trailingData, 2), ("{}}", .trailingData, 2),
        ("[1]]", .trailingData, 3), ("{\"a\":1}}", .trailingData, 7), ("[],", .trailingData, 2), ("{} x", .trailingData, 3),
        ("null null", .trailingData, 5), ("\"a\"\"b\"", .trailingData, 3), ("[1] [", .trailingData, 4),
        // Arrays: unclosed at each point.
        ("[", .unexpectedEnd, 1), ("[ ", .unexpectedEnd, 2), ("[1", .unexpectedEnd, 2), ("[1 ", .unexpectedEnd, 3),
        ("[1,", .unexpectedEnd, 3), ("[1, ", .unexpectedEnd, 4), ("[1,2", .unexpectedEnd, 4), ("[[", .unexpectedEnd, 2),
        ("[[]", .unexpectedEnd, 3), ("[[1]", .unexpectedEnd, 4), ("[[],", .unexpectedEnd, 4), ("[{}", .unexpectedEnd, 3),
        ("[\"a\"", .unexpectedEnd, 4), ("[true", .unexpectedEnd, 5), ("[null,", .unexpectedEnd, 6),
        // Arrays: commas.
        ("[1,]", .unexpectedByte(0x5D), 3), ("[1, ]", .unexpectedByte(0x5D), 4), ("[1 ,]", .unexpectedByte(0x5D), 4),
        ("[,]", .unexpectedByte(0x2C), 1), ("[,1]", .unexpectedByte(0x2C), 1), ("[ ,1]", .unexpectedByte(0x2C), 2),
        ("[1,,2]", .unexpectedByte(0x2C), 3), ("[1,2,]", .unexpectedByte(0x5D), 5), ("[[],]", .unexpectedByte(0x5D), 4),
        ("[1 2]", .unexpectedByte(0x32), 3), ("[1\n2]", .unexpectedByte(0x32), 3), ("[\"a\" \"b\"]", .unexpectedByte(0x22), 5),
        ("[[] []]", .unexpectedByte(0x5B), 4), ("[{} {}]", .unexpectedByte(0x7B), 4), ("[true false]", .unexpectedByte(0x66), 6),
        // Arrays: the wrong closer or a stray separator.
        ("[}", .unexpectedByte(0x7D), 1), ("[1}", .unexpectedByte(0x7D), 2), ("[1,}", .unexpectedByte(0x7D), 3),
        ("[[}]", .unexpectedByte(0x7D), 2), ("[[1}]", .unexpectedByte(0x7D), 3), ("[1:2]", .unexpectedByte(0x3A), 2),
        ("[\"a\":1]", .unexpectedByte(0x3A), 4), ("[1;2]", .unexpectedByte(0x3B), 2), ("[:]", .unexpectedByte(0x3A), 1),
        // Objects: unclosed at each point.
        ("{", .unexpectedEnd, 1), ("{ ", .unexpectedEnd, 2), ("{\"a\"", .unexpectedEnd, 4), ("{\"a\" ", .unexpectedEnd, 5),
        ("{\"a\":", .unexpectedEnd, 5), ("{\"a\": ", .unexpectedEnd, 6), ("{\"a\":1", .unexpectedEnd, 6), ("{\"a\":1 ", .unexpectedEnd, 7),
        ("{\"a\":1,", .unexpectedEnd, 7), ("{\"a\":1, ", .unexpectedEnd, 8), ("{\"a\":1,\"b\"", .unexpectedEnd, 10),
        ("{\"a\":1,\"b\":", .unexpectedEnd, 11), ("{\"a\":1,\"b\":2", .unexpectedEnd, 12), ("{\"a\":{", .unexpectedEnd, 6),
        ("{\"a\":{}", .unexpectedEnd, 7), ("{\"a\":[", .unexpectedEnd, 6), ("{\"a\":[]", .unexpectedEnd, 7), ("{\"a", .unexpectedEnd, 3),
        // Objects: the key.
        ("{,}", .unexpectedByte(0x2C), 1), ("{:1}", .unexpectedByte(0x3A), 1), ("{1:2}", .unexpectedByte(0x31), 1),
        ("{a:1}", .unexpectedByte(0x61), 1), ("{null:1}", .unexpectedByte(0x6E), 1), ("{true:1}", .unexpectedByte(0x74), 1),
        ("{[]:1}", .unexpectedByte(0x5B), 1), ("{{}:1}", .unexpectedByte(0x7B), 1), ("{'a':1}", .unexpectedByte(0x27), 1),
        ("{ ]", .unexpectedByte(0x5D), 2), ("{]", .unexpectedByte(0x5D), 1), ("{\"a\":1,2:3}", .unexpectedByte(0x32), 7),
        ("{\"a\":1,[]:3}", .unexpectedByte(0x5B), 7), ("{\"a\":1, b:3}", .unexpectedByte(0x62), 8),
        // Objects: the colon.
        ("{\"a\"}", .unexpectedByte(0x7D), 4), ("{\"a\" }", .unexpectedByte(0x7D), 5), ("{\"a\" 1}", .unexpectedByte(0x31), 5),
        ("{\"a\",1}", .unexpectedByte(0x2C), 4), ("{\"a\"=1}", .unexpectedByte(0x3D), 4), ("{\"a\"\"b\"}", .unexpectedByte(0x22), 4),
        ("{\"a\"::1}", .unexpectedByte(0x3A), 5), ("{\"a\":}", .unexpectedByte(0x7D), 5), ("{\"a\": }", .unexpectedByte(0x7D), 6),
        ("{\"a\":,}", .unexpectedByte(0x2C), 5), ("{\"a\":1,\"b\"}", .unexpectedByte(0x7D), 10), ("{\"a\":1,\"b\":}", .unexpectedByte(0x7D), 11),
        ("{\"a\":1,\"b\" 2}", .unexpectedByte(0x32), 11),
        // Objects: commas and closers.
        ("{\"a\":1,}", .unexpectedByte(0x7D), 7), ("{\"a\":1, }", .unexpectedByte(0x7D), 8), ("{\"a\":1,,\"b\":2}", .unexpectedByte(0x2C), 7),
        ("{\"a\":1 \"b\":2}", .unexpectedByte(0x22), 7), ("{\"a\":1 2}", .unexpectedByte(0x32), 7), ("{\"a\":1:2}", .unexpectedByte(0x3A), 6),
        ("{\"a\":1]", .unexpectedByte(0x5D), 6), ("{\"a\":[}", .unexpectedByte(0x7D), 6), ("{\"a\":[1}", .unexpectedByte(0x7D), 7),
        ("{\"a\":{]", .unexpectedByte(0x5D), 6), ("{{}", .unexpectedByte(0x7B), 1), ("[{]", .unexpectedByte(0x5D), 2),
        ("[{\"a\":1]", .unexpectedByte(0x5D), 7), ("[{\"a\":[1,{\"b\":2]}]", .unexpectedByte(0x5D), 15),
        // The error is where the mistake is, not where the outer container notices.
        ("[[[1,]]]", .unexpectedByte(0x5D), 5), ("{\"a\":{\"b\":{\"c\"}}}", .unexpectedByte(0x7D), 14),
        ("[1,[2,[3,[4 5]]]]", .unexpectedByte(0x35), 12), ("[{},{\"a\":[]},{\"b\":[1,]}]", .unexpectedByte(0x5D), 21),
        // Literals and numbers inside containers.
        ("[nul]", .unexpectedByte(0x6E), 1), ("[tru", .unexpectedEnd, 1), ("[fals]", .unexpectedByte(0x66), 1), ("[fals", .unexpectedEnd, 1),
        ("[truee]", .unexpectedByte(0x65), 5), ("[nullx]", .unexpectedByte(0x78), 5), ("{\"a\":nul}", .unexpectedByte(0x6E), 5),
        ("[01]", .invalidNumber, 2), ("[-]", .invalidNumber, 2), ("[1.]", .invalidNumber, 3), ("[1e]", .invalidNumber, 3),
        ("[-", .unexpectedEnd, 2), ("[1.", .unexpectedEnd, 3), ("[1e+", .unexpectedEnd, 4), ("[.5]", .unexpectedByte(0x2E), 1),
        ("[+1]", .unexpectedByte(0x2B), 1), ("[1.5.2]", .unexpectedByte(0x2E), 4), ("{\"a\":01}", .invalidNumber, 6),
        // Strings inside containers.
        ("[\"a", .unexpectedEnd, 3), ("[\"a\\", .unexpectedEnd, 4), ("[\"a\nb\"]", .controlCharacterInString, 3),
        ("[\"\\x\"]", .invalidEscape, 3), ("[\"\\u12\"]", .invalidUnicodeEscape, 6), ("[\"\\ud800\"]", .invalidUnicodeEscape, 8),
        ("{\"a\nb\":1}", .controlCharacterInString, 3), ("{\"\\x\":1}", .invalidEscape, 3), ("{\"a\":\"b", .unexpectedEnd, 7),
    ]

    @Test(arguments: malformed.indices)
    func malformedStructureIsRefusedWhereItBreaks(_ index: Int) {
        let (text, kind, offset) = Self.malformed[index]
        #expect(Parse(text) == .failure(kind, offset), "\(text.debugDescription)")
        #expect(Parse(Array(text.utf8)) == .failure(kind, offset), "\(text.debugDescription) as bytes")
        // The second parser agrees, so the table and the reference check each other.
        #expect(Reference.parse(Array(text.utf8), .default) == .failure(kind, offset), "\(text.debugDescription) by the reference")
        // Nested one level down in either container, the same mistake is found the same distance in.
        if kind != .trailingData, !text.allSatisfy(\.isWhitespace) {
            if text != "]" { #expect(Parse("[" + text) == .failure(kind, offset + 1), "\(text.debugDescription) in an array") }
            #expect(Parse("{\"k\":" + text) == .failure(kind, offset + 5), "\(text.debugDescription) in an object")
            #expect(Parse("[0, " + text) == .failure(kind, offset + 4), "\(text.debugDescription) as a second element")
        }
    }

    /// Cut a valid document anywhere: what is left is refused, at its end, as an unexpected end —
    /// except inside a literal, where the error points at the literal's first byte.
    @Test func everyPrefixOfAValidDocumentIsRefused() {
        let documents = [
            #"{"a":[1,{"b":null,"c":[true,false]},"x\ny\u00e9"],"d":{"e":{}},"f":[],"g":-1.5e+3}"#,
            #"[[[]],{"k":{"k":{"k":[]}}}, "s" ,0 , [ 1 , 2 ] ]"#,
            #"{ "a" : 1 , "b" : [ ] , "c" : { } , "d" : "\ud83d\ude00" }"#,
        ]
        for document in documents {
            let bytes = Array(document.utf8)
            #expect(Parse(bytes) == Reference.parse(bytes, .default))
            for length in 0..<bytes.count {
                let prefix = Array(bytes[..<length])
                let found = Parse(prefix)
                guard case .failure(let kind, let offset) = found else {
                    Issue.record("the first \(length) bytes of \(document) were accepted")
                    continue
                }
                #expect(found == Reference.parse(prefix, .default), "the first \(length) bytes of \(document)")
                // Cut between the two halves of a surrogate pair, the half that is there is reported
                // as an invalid escape rather than as the end of input.
                #expect(kind == .unexpectedEnd || kind == .invalidUnicodeEscape, "the first \(length) bytes of \(document): \(found)")
                #expect(offset <= length && offset >= length - 5, "the first \(length) bytes of \(document): \(found)")
            }
        }
    }

    // MARK: Duplicate keys

    @Test func duplicateKeysAreRejectedWhereTheyRepeat() {
        // Small objects compare keys one by one; from the 25th member on a set is used.
        for count in [1, 2, 3, 23, 24, 25, 26, 27, 48, 49, 50, 100, 1000] {
            let members = (0..<count).map { "\"k\($0)\":\($0)" }
            let clean = "{" + members.joined(separator: ",") + "}"
            guard case .value(let value) = Parse(clean) else {
                Issue.record("\(count) distinct keys were refused: \(Parse(clean))")
                continue
            }
            #expect(value.objectValue?.count == count)
            #expect(value.objectValue.map { $0.map(\.key) } == (0..<count).map { "k\($0)" })
            // Repeat each of a few keys in turn, at the end and right after the original.
            for repeated in Set([0, 1, count / 2, max(count - 2, 0), count - 1]).filter({ $0 < count }) {
                let key = "k\(repeated)"
                let atTheEnd = "{" + (members + ["\"\(key)\":true"]).joined(separator: ",") + "}"
                #expect(Parse(atTheEnd) == .failure(.duplicateKey(key), clean.utf8.count), "\(count) keys, \(key) repeated at the end")
                var adjacent = members
                adjacent.insert("\"\(key)\":true", at: repeated + 1)
                let offset = 1 + members[...repeated].map { $0.utf8.count + 1 }.reduce(0, +)
                #expect(
                    Parse("{" + adjacent.joined(separator: ",") + "}") == .failure(.duplicateKey(key), offset),
                    "\(count) keys, \(key) repeated next to itself")
                // Allowed: the last value wins and keeps the first one's place.
                guard case .value(let merged) = Parse(atTheEnd, JSONParseOptions(rejectDuplicateKeys: false)) else {
                    Issue.record("\(count) keys with a repeat were refused although repeats are allowed")
                    continue
                }
                #expect(merged.objectValue?.count == count)
                #expect(merged[key] == true)
                #expect(merged.objectValue.map { $0.map(\.key) } == (0..<count).map { "k\($0)" })
            }
        }
    }

    @Test func duplicateKeysInEveryForm() {
        let cases: [(text: String, key: String, offset: Int)] = [
            (#"{"a":1,"a":2}"#, "a", 7), (#"{"a":1,"b":2,"a":3}"#, "a", 13), (#"{"":1,"":2}"#, "", 6),
            (#"{"a":1,"\u0061":2}"#, "a", 7), (#"{"\u0061":1,"a":2}"#, "a", 12), (#"{"a\n":1,"a\u000a":2}"#, "a\n", 9),
("{\"\u{E9}\":1,\"\\u00e9\":2}", "\u{E9}", 8), (#"{"a":{"a":1},"a":2}"#, "a", 13), (#"{"a":[{"a":1}],"a":2}"#, "a", 15),
            (#"{"x":{"a":1,"a":2}}"#, "a", 12), (#"[{"a":1},{"a":1,"a":2}]"#, "a", 16), (#"{"a":1, "a" :2}"#, "a", 8),
            (#"{"a":1,"a""#, "a", 7), (#"{"a":1,"a":"#, "a", 7), (#"{"a":1,"a"}"#, "a", 7),
        ]
        for (text, key, offset) in cases {
            #expect(Parse(text) == .failure(.duplicateKey(key), offset), "\(text)")
            #expect(Reference.parse(Array(text.utf8), .default) == .failure(.duplicateKey(key), offset), "\(text) by the reference")
        }
        // The same key in different objects is not a duplicate.
        for text in [#"{"a":{"a":{"a":1}}}"#, #"[{"a":1},{"a":2}]"#, #"{"a":[{"a":1},{"a":2}],"b":{"a":3}}"#] {
            if case .failure = Parse(text) { Issue.record("\(text): \(Parse(text))") }
        }
        // Allowed: every repeat overwrites, nested objects included, and order is that of first sight.
        let merged = Parse(#"{"a":1,"b":{"x":1,"x":2},"a":{"y":1,"y":[1],"y":3},"c":0,"b":4}"#, JSONParseOptions(rejectDuplicateKeys: false))
        #expect(merged == .value(["a": ["y": 3], "b": 4, "c": 0]))
        if case .value(let value) = merged { #expect(value.objectValue.map { $0.map(\.key) } == ["a", "b", "c"]) }
    }

    /// Canonically equivalent keys are different keys, on the linear path and on the set path.
    @Test func equivalentKeysAreNotDuplicates() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        for padding in [0, 1, 22, 23, 24, 25, 40, 200] {
            let others = (0..<padding).map { "\"k\($0)\":0" }
            for (first, second) in [(composed, decomposed), (decomposed, composed)] {
                // Both spellings, in each order, before, after and around the other members.
                let layouts = [
                    others + ["\"\(first)\":1", "\"\(second)\":2"],
                    ["\"\(first)\":1", "\"\(second)\":2"] + others,
                    ["\"\(first)\":1"] + others + ["\"\(second)\":2"],
                ]
                for members in layouts {
                    let text = "{" + members.joined(separator: ",") + "}"
                    guard case .value(let value) = Parse(text) else {
                        Issue.record("\(padding) other keys: \(Parse(text))")
                        continue
                    }
                    #expect(value.objectValue?.count == padding + 2)
                    #expect(value[first] == 1 && value[second] == 2)
                    // A real repeat of either spelling is still caught, and named exactly.
                    for (which, repeated) in [first, second].enumerated() {
                        let again = "{" + (members + ["\"\(repeated)\":3"]).joined(separator: ",") + "}"
                        guard case .failure(.duplicateKey(let key), let offset) = Parse(again) else {
                            Issue.record("\(padding) other keys, a repeated spelling: \(Parse(again))")
                            continue
                        }
                        #expect(Array(key.utf8) == Array(repeated.utf8))
                        #expect(offset == text.utf8.count)
                        // Allowed: it overwrites its own spelling and leaves the other alone.
                        let merged = Parse(again, JSONParseOptions(rejectDuplicateKeys: false))
                        guard case .value(let value) = merged else {
                            Issue.record("\(padding) other keys, repeats allowed: \(merged)")
                            continue
                        }
                        #expect(value.objectValue?.count == padding + 2)
                        #expect(value[repeated] == 3)
                        // (`first == second` is true for Swift, so the spellings are told apart by position.)
                        #expect(value[which == 0 ? second : first] == (which == 0 ? 2 : 1))
                    }
                }
            }
        }
    }

    /// Finding a repeated key must not cost a walk over the members already read, with
    /// duplicates rejected or allowed. (Before keys were indexed by their bytes, 80,000 members
    /// took 15 s with duplicates allowed.)
    @Test func objectsTakeLinearTimeInEitherMode() {
        let clock = ContinuousClock()
        func seconds(_ text: String, _ options: JSONParseOptions) -> Double {
            let bytes = Array(text.utf8)
            var best = Double.infinity
            for _ in 0..<3 {
                let elapsed = clock.measure { _ = Parse(bytes, options) }
                best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            return best
        }
        func distinct(_ count: Int) -> String { "{" + (0..<count).map { "\"key\($0)\":\($0)" }.joined(separator: ",") + "}" }
        // Every member repeats one of 100 keys: nothing but overwrites after the first hundred.
        func repeating(_ count: Int) -> String { "{" + (0..<count).map { "\"key\($0 % 100)\":\($0)" }.joined(separator: ",") + "}" }
        // The same letter under seven combining marks in every order: equivalent for `String`,
        // different as bytes — so all of them land in one bucket of anything keyed by `String`.
        func equivalent(_ count: Int) -> String { "{" + equivalentSpellings(count).map { "\"\($0)\":0" }.joined(separator: ",") + "}" }
        let allowing = JSONParseOptions(rejectDuplicateKeys: false)
        let shapes: [(name: String, make: (Int) -> String, small: Int, options: JSONParseOptions)] = [
            ("distinct keys, duplicates rejected", distinct, 10_000, .default),
            ("distinct keys, duplicates allowed", distinct, 10_000, allowing),
            ("repeated keys, duplicates allowed", repeating, 10_000, allowing),
            ("equivalent keys, duplicates rejected", equivalent, 1250, .default),
            ("equivalent keys, duplicates allowed", equivalent, 1250, allowing),
        ]
        for (name, make, small, options) in shapes {
            let once = seconds(make(small), options)
            let fourfold = seconds(make(small * 4), options)
            #expect(fourfold < once * 10 + 0.02, "\(name): \(small) members took \(once) s, \(small * 4) took \(fourfold) s")
        }
    }

    /// The index keys go into once an object has 24 members must agree with the member list it
    /// stands for, in both modes, whichever side of the switch a key and its repeat fall on.
    @Test func repeatsOnEitherSideOfTheSwitch() {
        let allowing = JSONParseOptions(rejectDuplicateKeys: false)
        for size in [22, 23, 24, 25, 26, 30, 60] {
            let keys = (0..<size).map { "k\($0)" }
            for original in Set([0, 1, 22, 23, 24, 25, size - 2, size - 1]).filter({ $0 >= 0 && $0 < size }) {
                // The repeat goes in at every position after the original, so it is read before
                // the switch, as the member that causes it, right after it, and long after.
                for position in Set([original + 1, 23, 24, 25, 26, size]).filter({ $0 > original && $0 <= size }) {
                    var members = keys.enumerated().map { "\"\($1)\":\($0)" }
                    members.insert("\"k\(original)\":\"again\"", at: position)
                    let text = "{" + members.joined(separator: ",") + "}"
                    let offset = 1 + members[..<position].map { $0.utf8.count + 1 }.reduce(0, +)
                    let label: Comment = "\(size) members, k\(original) repeated at \(position)"
                    #expect(Parse(text) == .failure(.duplicateKey("k\(original)"), offset), label)
                    guard case .value(let merged) = Parse(text, allowing) else {
                        Issue.record("\(label): refused although repeats are allowed")
                        continue
                    }
                    // Last value, first position, nothing else disturbed.
                    #expect(merged.objectValue.map { $0.map(\.key) } == keys, label)
                    for (index, key) in keys.enumerated() {
                        #expect(merged[key] == (index == original ? "again" : JSONValue(index)), "\(label): \(key)")
                    }
                    #expect(Parse(text, allowing) == Reference.parse(Array(text.utf8), allowing), label)
                }
            }
            // The same key over and over, and two keys taking turns, across the switch.
            let pattern = (0..<size * 3).map { "\"k\($0 % 2 == 0 ? $0 % 7 : $0 % 29)\":\($0)" }
            let text = "{" + pattern.joined(separator: ",") + "}"
            let found = Parse(text, allowing)
            #expect(found == Reference.parse(Array(text.utf8), allowing), "\(size * 3) members drawn from few keys")
            if case .value(let a) = found, case .value(let b) = Reference.parse(Array(text.utf8), allowing) {
                #expect(a.description == b.description, "\(size * 3) members drawn from few keys")
            }
            #expect(Parse(text) == Reference.parse(Array(text.utf8), .default), "\(size * 3) members drawn from few keys, rejected")
        }
    }

    /// Thousands of spellings of one canonically equivalent key are thousands of keys.
    @Test func manyEquivalentKeysStayDistinct() {
        let spellings = equivalentSpellings(5040)
        // The construction does what it says: one string for Swift, 5040 for JSON.
        #expect(Set(spellings).count == 1)
        #expect(Set(spellings.map { Array($0.utf8) }).count == 5040)
        let text = "{" + spellings.enumerated().map { "\"\($1)\":\($0)" }.joined(separator: ",") + "}"
        for options in [JSONParseOptions.default, JSONParseOptions(rejectDuplicateKeys: false)] {
            guard case .value(let value) = Parse(text, options), let object = value.objectValue else {
                Issue.record("5040 spellings: \(Parse(String(text.prefix(80)), options))")
                continue
            }
            #expect(object.count == 5040)
            var intact = true
            for (index, member) in object.enumerated() where Array(member.key.utf8) != Array(spellings[index].utf8) || member.value != JSONValue(index) {
                intact = false
            }
            #expect(intact)
            // A real repeat of one spelling, early or late, is still that spelling's repeat.
            for repeated in [0, 23, 24, 2500, 5039] {
                let again = "{" + (spellings.enumerated().map { "\"\($1)\":\($0)" } + ["\"\(spellings[repeated])\":-1"]).joined(separator: ",") + "}"
                switch Parse(again, options) {
                case .failure(.duplicateKey(let key), let offset):
                    #expect(options.rejectDuplicateKeys)
                    #expect(Array(key.utf8) == Array(spellings[repeated].utf8))
                    #expect(offset == text.utf8.count)
                case .value(let merged):
                    #expect(!options.rejectDuplicateKeys)
                    #expect(merged.objectValue?.count == 5040)
                    let member = merged.objectValue?[repeated]
                    #expect(member.map { Array($0.key.utf8) } == Array(spellings[repeated].utf8))
                    #expect(member?.value == -1)
                    #expect(merged.objectValue?[repeated == 0 ? 1 : 0].value == JSONValue(repeated == 0 ? 1 : 0))
                case .failure(let kind, let offset):
                    Issue.record("spelling \(repeated) repeated: \(kind) at \(offset)")
                }
            }
        }
    }

    /// A key is its characters, however they are written; and its length is no obstacle.
    @Test func keysInEverySpellingAndSize() {
        let allowing = JSONParseOptions(rejectDuplicateKeys: false)
        for padding in [0, 5, 23, 24, 25, 60] {
            let others = (0..<padding).map { "\"p\($0)\":0" }
            // Raw and escaped spellings of the same key, in both orders.
            let pairs: [(first: String, second: String, key: String)] = [
                ("\"a\"", "\"\\u0061\"", "a"), ("\"\\u0061\"", "\"a\"", "a"), ("\"\\u0061\"", "\"\\u0061\"", "a"),
                ("\"/\"", "\"\\/\"", "/"), ("\"\\n\"", "\"\\u000a\"", "\n"), ("\"\\u000A\"", "\"\\n\"", "\n"),
                ("\"\u{E9}\"", "\"\\u00e9\"", "\u{E9}"), ("\"\\u00E9\"", "\"\\u00e9\"", "\u{E9}"),
                ("\"\u{1F600}\"", "\"\\ud83d\\ude00\"", "\u{1F600}"), ("\"\\uD83D\\uDE00\"", "\"\\ud83d\\ude00\"", "\u{1F600}"),
                ("\"\"", "\"\"", ""), ("\"\\u0000\"", "\"\\u0000\"", "\u{0}"), ("\"p\\u0030\"", "\"p0\"", "p0"),
                ("\"\\\"\"", "\"\\u0022\"", "\""), ("\"\\\\\"", "\"\\u005c\"", "\\"),
            ]
            for (first, second, key) in pairs where !(key == "p0" && padding > 0) {
                let before = (others + ["\(first):1"]).joined(separator: ",")
                let text = "{" + before + ",\(second):2}"
                let label: Comment = "\(first) then \(second) after \(padding) other members"
                #expect(Parse(text) == .failure(.duplicateKey(key), before.utf8.count + 2), label)
                guard case .value(let merged) = Parse(text, allowing) else {
                    Issue.record("\(label): refused although repeats are allowed")
                    continue
                }
                #expect(merged.objectValue?.count == padding + 1, label)
                #expect(merged[key] == 2, label)
                #expect(merged.objectValue?.last.map { Array($0.key.utf8) } == Array(key.utf8), label)
            }
            // Spellings that only look alike are different keys.
            let lookalikes = ["a", "A", "a ", " a", "\u{E9}", "e\u{301}", "\u{212B}", "\u{C5}", "A\u{30A}", "", " ", "\u{0}", "\\u0061", "a\u{0}", "\u{FEFF}a"]
            let members = others + lookalikes.enumerated().map { "\"\($1.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\u{0}", with: "\\u0000"))\":\($0)" }
            for options in [JSONParseOptions.default, allowing] {
                guard case .value(let value) = Parse("{" + members.joined(separator: ",") + "}", options) else {
                    Issue.record("look-alike keys after \(padding) members: \(Parse("{" + members.joined(separator: ",") + "}", options))")
                    continue
                }
                #expect(value.objectValue?.count == padding + lookalikes.count)
                for (index, key) in lookalikes.enumerated() { #expect(value[key] == JSONValue(index), "look-alike \(index) after \(padding) members") }
            }
        }
        // Long keys: equal up to the last byte, on both sides of the switch, and repeated.
        let stem = String(repeating: "k", count: 1 << 20)
        for padding in [0, 30] {
            let others = (0..<padding).map { "\"\(String(repeating: "p", count: 50_000))\($0)\":0" }
            let members = others + ["\"\(stem)a\":1", "\"\(stem)b\":2", "\"\(stem)\":3"]
            let text = "{" + members.joined(separator: ",") + "}"
            guard case .value(let value) = Parse(text) else {
                Issue.record("megabyte keys after \(padding) members were refused")
                continue
            }
            #expect(value.objectValue?.count == padding + 3)
            #expect(value[stem + "a"] == 1 && value[stem + "b"] == 2 && value[stem] == 3)
            let again = "{" + (members + ["\"\(stem)b\":4"]).joined(separator: ",") + "}"
            #expect(Parse(again) == .failure(.duplicateKey(stem + "b"), text.utf8.count))
            guard case .value(let merged) = Parse(again, allowing) else {
                Issue.record("a repeated megabyte key after \(padding) members was refused")
                continue
            }
            #expect(merged.objectValue?.count == padding + 3)
            #expect(merged[stem + "b"] == 4 && merged[stem + "a"] == 1)
        }
    }

    // MARK: Order, text, limits

    @Test func memberOrderAndNumberTextArePreserved() throws {
        let head = #"{"z":1,"a":[{"m":1.0,"b":-0,"y":1E+2},{"k":1e400}],"m":{"3":3,"1":1,"2":2},"":0,"#
        let text = head + "\"\u{E9}\":[],\"e\\u0301\":{}}"
        let value = try JSON.parse(text)
        #expect(value.objectValue.map { $0.map(\.key) } == ["z", "a", "m", "", "\u{E9}", "e\u{301}"])
        #expect(value["m"]?.objectValue.map { $0.map(\.key) } == ["3", "1", "2"])
        #expect(value["a"]?[0]?.objectValue.map { $0.map(\.key) } == ["m", "b", "y"])
        #expect(value.description == head + "\"\u{E9}\":[],\"e\u{301}\":{}}")
        // A thousand members, shuffled by construction, stay in the order they were written.
        var generator = SplitMix64(state: 7)
        let keys = (0..<1000).map { "k\($0)" }.shuffled(using: &generator)
        let large = try JSON.parse("{" + keys.map { "\"\($0)\":[]" }.joined(separator: ",") + "}")
        #expect(large.objectValue.map { $0.map(\.key) } == keys)
    }

    /// Which error wins when two apply: the limits are checked as each value starts.
    @Test func limitsAndSyntaxErrorsInOrder() {
        // The node limit is reached before the byte that is wrong.
        #expect(Parse("[1,]", JSONParseOptions(maxNodes: 2)) == .failure(.nodeLimitExceeded(2), 3))
        #expect(Parse("[1,]", JSONParseOptions(maxNodes: 3)) == .failure(.unexpectedByte(0x5D), 3))
        #expect(Parse("[1,x", JSONParseOptions(maxNodes: 2)) == .failure(.nodeLimitExceeded(2), 3))
        // Nodes before depth, at the same bracket.
        #expect(Parse("[[", JSONParseOptions(maxDepth: 1, maxNodes: 1)) == .failure(.nodeLimitExceeded(1), 1))
        #expect(Parse("[[", JSONParseOptions(maxDepth: 1, maxNodes: 2)) == .failure(.depthLimitExceeded(1), 1))
        // Depth is refused at the bracket, before anything inside it is looked at.
        #expect(Parse("[[x", JSONParseOptions(maxDepth: 1)) == .failure(.depthLimitExceeded(1), 1))
        #expect(Parse("[{\"a\"", JSONParseOptions(maxDepth: 1)) == .failure(.depthLimitExceeded(1), 1))
        #expect(Parse("[[]", JSONParseOptions(maxDepth: 1)) == .failure(.depthLimitExceeded(1), 1))
        // A key is not a node, and a duplicate is found before its value is counted.
        #expect(Parse(#"{"a":1,"a":2}"#, JSONParseOptions(maxNodes: 2)) == .failure(.duplicateKey("a"), 7))
        #expect(Parse(#"{"a":1,"b":2}"#, JSONParseOptions(maxNodes: 2)) == .failure(.nodeLimitExceeded(2), 11))
        // `maxDepth` cannot be lifted past the ceiling: nesting that never closes is refused at
        // the 257th bracket, whatever the limit says and whatever else is wrong further on.
        let ceiling = JSONParseOptions.depthCeiling
        #expect(ceiling == 256)
        let bottomless = String(repeating: "[", count: 100_000)
        for limit in [Int.max, 100_000, 99_999, 257, 256] {
            let options = JSONParseOptions(maxDepth: limit)
            #expect(Parse(bottomless, options) == .failure(.depthLimitExceeded(256), 256), "maxDepth \(limit)")
            #expect(Parse(String(repeating: "{\"a\":", count: 100_000), options) == .failure(.depthLimitExceeded(256), 1280), "maxDepth \(limit)")
            #expect(Parse(bottomless + "]", options) == .failure(.depthLimitExceeded(256), 256), "maxDepth \(limit)")
            #expect(Parse(bottomless + "}", options) == .failure(.depthLimitExceeded(256), 256), "maxDepth \(limit)")
            #expect(Parse(String(repeating: "[", count: 256), options) == .failure(.unexpectedEnd, 256), "maxDepth \(limit)")
            #expect(Parse(String(repeating: "[", count: 256) + "x", options) == .failure(.unexpectedByte(0x78), 256), "maxDepth \(limit)")
        }
        #expect(Parse(bottomless, JSONParseOptions(maxDepth: 255)) == .failure(.depthLimitExceeded(255), 255))
        #expect(Parse(bottomless, JSONParseOptions(maxDepth: .max, maxNodes: 5000)) == .failure(.depthLimitExceeded(256), 256))
        #expect(Parse(bottomless, JSONParseOptions(maxDepth: .max, maxNodes: 256)) == .failure(.nodeLimitExceeded(256), 256))
        #expect(Parse(bottomless, JSONParseOptions(maxDepth: .max, maxNodes: 100)) == .failure(.nodeLimitExceeded(100), 100))
    }

    /// Up to the ceiling `maxDepth` means what it says; above it, it means the ceiling.
    @Test func depthCeiling() {
        // On a thread of its own: writing a value 256 levels deep back out recurses that deep,
        // and how much stack the test runner leaves is not this test's business.
        let problems: [String] = onRoomyThread {
            var problems: [String] = []
            func nested(_ open: String, _ close: String, _ depth: Int, _ core: String) -> String {
                String(repeating: open, count: depth) + core + String(repeating: close, count: depth)
            }
            let shapes: [(open: String, close: String, core: String, step: Int)] = [
                ("[", "]", "", 1), ("{\"a\":", "}", "1", 5), ("[{\"a\":", "}]", "null", 6),
            ]
            for (open, close, core, step) in shapes {
                let levels = step == 6 ? 2 : 1
                for limit in [129, 200, 255, 256, 257, 1000, Int.max] {
                    let effective = min(limit, 256)
                    // Two levels at a time cannot land on an odd limit.
                    if levels == 2, effective % 2 != 0 { continue }
                    let options = JSONParseOptions(maxDepth: limit)
                    let fits = nested(open, close, effective / levels, core)
                    guard case .value(let value) = Parse(fits, options) else {
                        problems.append("\(effective) levels of \(open) refused with maxDepth \(limit): \(Parse(fits, options))")
                        continue
                    }
                    if value.description != fits { problems.append("\(effective) levels of \(open) came back changed") }
                    // One bracket more — holding something, empty, or left open.
                    let prefix = String(repeating: open, count: effective / levels)
                    let suffix = String(repeating: close, count: effective / levels)
                    for innermost in ["[]", "{}", "[1]", "{\"k\":1}", "[", "{"] {
                        let found = Parse(prefix + innermost + suffix, options)
                        if found != .failure(.depthLimitExceeded(effective), effective / levels * step) {
                            problems.append("\(effective) levels of \(open) around \(innermost), maxDepth \(limit): \(found)")
                        }
                    }
                }
                // The default has not moved.
                if case .failure = Parse(nested(open, close, 128 / levels, core)) { problems.append("128 levels of \(open) refused by default") }
                let over = Parse(nested(open, close, 128 / levels + 1, core))
                if over != .failure(.depthLimitExceeded(128), 128 / levels * step) { problems.append("\(open) beyond the default: \(over)") }
            }
            // Siblings at the ceiling, and the ceiling crossed in the second of two.
            let deepest = nested("[", "]", 255, "")
            let siblings = "[" + Array(repeating: deepest, count: 20).joined(separator: ",") + "]"
            if case .value(let value) = Parse(siblings, JSONParseOptions(maxDepth: .max)) {
                if value.arrayValue?.count != 20 { problems.append("siblings at the ceiling: wrong count") }
            } else {
                problems.append("siblings at the ceiling were refused")
            }
            let crossed = Parse("[" + deepest + ",[" + deepest + "]]", JSONParseOptions(maxDepth: .max))
            if crossed != .failure(.depthLimitExceeded(256), 767) { problems.append("the ceiling crossed in a sibling: \(crossed)") }
            return problems
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    // MARK: Against the reference

    /// Random documents, then the same documents damaged at random, under random limits. The
    /// two parsers must agree on everything: the value, the order of members, the text of
    /// numbers — or the kind of error and the byte it points at.
    @Test func agreesWithTheReferenceParser() {
        var generator = SplitMix64(state: 0x5245_4631)
        let alphabet = Array(#"[]{}:,"\ 01e.-+tfnul/"#.utf8) + [0x0A, 0x09, 0x01, 0x7F]
        var disagreements = 0
        var accepted = 0
        var rejected = 0
        func compare(_ bytes: [UInt8], _ options: JSONParseOptions, _ label: String) {
            let real = Parse(bytes, options)
            let reference = Reference.parse(bytes, options)
            var same = real == reference
            if same, case .value(let a) = real, case .value(let b) = reference {
                same = a.description == b.description && keyOrder(a) == keyOrder(b)
                accepted += 1
            } else {
                rejected += 1
            }
            if !same {
                disagreements += 1
                if disagreements <= 10 {
                    Issue.record("\(label): \(String(decoding: bytes, as: UTF8.self).debugDescription) parsed to \(real), the reference says \(reference)")
                }
            }
        }
        for iteration in 0..<4000 {
            let value = randomValue(depth: Int.random(in: 1...6, using: &generator), &generator)
            let bytes = Array(spell(value, whitespace: iteration % 2 == 0, &generator).utf8)
            compare(bytes, .default, "iteration \(iteration)")
            for round in 0..<12 {
                var damaged = bytes
                for _ in 0..<Int.random(in: 1...3, using: &generator) where !damaged.isEmpty {
                    let position = Int.random(in: 0..<damaged.count, using: &generator)
                    switch Int.random(in: 0..<5, using: &generator) {
                    case 0: damaged.remove(at: position)
                    case 1: damaged.insert(alphabet.randomElement(using: &generator)!, at: position)
                    case 2: damaged[position] = alphabet.randomElement(using: &generator)!
                    case 3: damaged.removeSubrange(position...)
                    default: damaged.insert(damaged[Int.random(in: 0..<damaged.count, using: &generator)], at: position)
                    }
                }
                let options = round % 3 == 0
                    ? JSONParseOptions(
                        maxDepth: Int.random(in: 0...5, using: &generator), maxNodes: Int.random(in: 0...40, using: &generator),
                        rejectDuplicateKeys: Bool.random(using: &generator))
                    : JSONParseOptions(rejectDuplicateKeys: round % 3 == 1)
                compare(damaged, options, "iteration \(iteration), round \(round)")
            }
        }
        #expect(disagreements == 0)
        // The damage did both: plenty of documents on each side of the line.
        #expect(accepted > 4000 && rejected > 4000, "\(accepted) accepted, \(rejected) rejected")
    }

    /// Objects with many members, repeats and all, where the duplicate check changes strategy.
    @Test func agreesWithTheReferenceParserOnLargeObjects() {
        var generator = SplitMix64(state: 0x4F42_4A53)
        let names = ["a", "b", "caf\u{E9}", "cafe\u{301}", "", "k", "K", "a\u{0}", "\u{212B}", "\u{C5}", "A\u{30A}"] + (0..<40).map { "n\($0)" }
        var disagreements = 0
        for iteration in 0..<1500 {
            let count = Int.random(in: 0...(iteration % 5 == 0 ? 400 : 60), using: &generator)
            // Few names for many members: repeats are common, early and late.
            let pool = names.prefix(Int.random(in: 1...names.count, using: &generator))
            func quoted(_ key: String) -> String { "\"" + key.replacingOccurrences(of: "\u{0}", with: "\\u0000") + "\"" }
            let members = (0..<count).map { index -> String in
                let key = pool.randomElement(using: &generator)!
                let inner = pool.randomElement(using: &generator)!
                return quoted(key) + ":" + (Bool.random(using: &generator) ? "\(index)" : "{\(quoted(inner)):\(index)}")
            }
            let bytes = Array(("{" + members.joined(separator: ",") + "}").utf8)
            for options in [JSONParseOptions.default, JSONParseOptions(rejectDuplicateKeys: false)] {
                let real = Parse(bytes, options)
                let reference = Reference.parse(bytes, options)
                var same = real == reference
                if same, case .value(let a) = real, case .value(let b) = reference { same = a.description == b.description }
                // `duplicateKey` compares its key the way Swift compares strings; spell it out.
                if case .failure(.duplicateKey(let a), _) = real, case .failure(.duplicateKey(let b), _) = reference, Array(a.utf8) != Array(b.utf8) {
                    same = false
                }
                if !same {
                    disagreements += 1
                    if disagreements <= 10 {
                        Issue.record("iteration \(iteration): \(String(decoding: bytes, as: UTF8.self).debugDescription) parsed to \(real), the reference says \(reference)")
                    }
                }
            }
        }
        #expect(disagreements == 0)
    }
}

#endif
