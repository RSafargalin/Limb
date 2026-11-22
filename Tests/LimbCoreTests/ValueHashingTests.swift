import Foundation
import LimbCore
import Testing

// `JSONValue` hashes as many levels as the parser can produce (256); below that a container
// contributes its size and nothing else, so hashing a value built in code to any depth still
// ends. What that must not break — equal values hash equally, sets and dictionaries stay
// correct — and what it costs.

/// `core` wrapped in `depth` single-element arrays (or single-member objects).
private func wrapped(_ core: JSONValue, depth: Int, inObjects: Bool = false) -> JSONValue {
    var value = core
    for _ in 0..<depth { value = inObjects ? .object(["a": value]) : .array([value]) }
    return value
}

private func parsed(_ text: String) -> JSONValue {
    (try? JSON.parse(text)) ?? .string("unparsable: \(text)")
}

@Suite struct JSONValueHashingTests {
    /// Pairs that are equal and written differently.
    static let equalPairs: [(JSONValue, JSONValue)] = [
        (1, 1.0), (0, -0.0), (100, 1e2), (-7, -7.0), (parsed("1"), parsed("1.0")), (parsed("1e2"), parsed("100")),
        (parsed("1.5"), parsed("15e-1")), (parsed("-0"), parsed("0")), (parsed("0.0"), parsed("0")), (parsed("1E0"), 1),
        (parsed("9007199254740993"), .number(9_007_199_254_740_993)), (parsed("1.0e2"), parsed("1e+2")),
        (["a": 1, "b": 2], ["b": 2, "a": 1]), (["a": 1, "b": [1, 2], "c": ["x": nil]], ["c": ["x": nil], "b": [1.0, 2.0], "a": 1.0]),
        ([["a": 1, "b": 2], ["c": 3]], [["b": 2, "a": 1], ["c": 3.0]]),
        (parsed(#"{"a":1,"b":{"c":[1,2,{"d":null,"e":true}]}}"#), parsed(#"{ "b" : { "c" : [1.0, 2e0, {"e":true,"d":null}] }, "a" : 1 }"#)),
        ("caf\u{E9}", "caf\u{E9}"), ([], []), ([:], [:]), (nil, nil), (true, true),
    ]

    @Test func equalValuesHashEqually() {
        for (index, (left, right)) in Self.equalPairs.enumerated() {
            #expect(left == right, "pair \(index): \(left) and \(right)")
            #expect(left.hashValue == right.hashValue, "pair \(index): \(left) and \(right)")
            // At every level, including those where only the size of a container is hashed.
            for depth in [1, 2, 6, 7, 8, 9, 10, 20, 60] {
                for inObjects in [false, true] {
                    let a = wrapped(left, depth: depth, inObjects: inObjects)
                    let b = wrapped(right, depth: depth, inObjects: inObjects)
                    #expect(a == b, "pair \(index) at depth \(depth)")
                    #expect(a.hashValue == b.hashValue, "pair \(index) at depth \(depth)")
                    #expect(Set([a, b]).count == 1, "pair \(index) at depth \(depth)")
                    #expect([a: "x"][b] == "x", "pair \(index) at depth \(depth)")
                }
            }
            // As members of an object, in either member order.
            let one: JSONValue = ["first": left, "second": [right, left]]
            let other: JSONValue = ["second": [left, right], "first": right]
            #expect(one == other && one.hashValue == other.hashValue, "pair \(index) as members")
        }
        // The objects themselves, not only values that hold them.
        let object: JSONObject = ["a": 1, "b": ["c": [1, 2]], "z": nil]
        let reordered: JSONObject = ["z": nil, "b": ["c": [1.0, 2.0]], "a": 1.0]
        #expect(object == reordered && object.hashValue == reordered.hashValue)
        #expect(Set([object, reordered]).count == 1)
    }

    /// The same around the depth where hashing stops looking (256), and well past it. Run on a
    /// thread with room: comparing and destroying values this deep recurses once per level.
    @Test func equalValuesHashEquallyAtAnyDepth() {
        let problems: [String] = onRoomyThread {
            var problems: [String] = []
            for depth in [200, 254, 255, 256, 257, 258, 300, 1000] {
                for inObjects in [false, true] {
                    for (index, (left, right)) in Self.equalPairs.enumerated() {
                        let a = wrapped(left, depth: depth, inObjects: inObjects)
                        let b = wrapped(right, depth: depth, inObjects: inObjects)
                        if a != b || a.hashValue != b.hashValue || Set([a, b]).count != 1 || [a: 1][b] != 1 {
                            problems.append("pair \(index) at depth \(depth)")
                        }
                    }
                    // Unequal values stay apart whether their hashes differ (above 256) or not.
                    let distinct = (0..<50).map { wrapped(JSONValue($0), depth: depth, inObjects: inObjects) }
                    let set = Set(distinct)
                    if set.count != 50 || !distinct.allSatisfy(set.contains) || set.contains(wrapped(50, depth: depth, inObjects: inObjects)) {
                        problems.append("50 distinct values at depth \(depth)")
                    }
                    var table: [JSONValue: Int] = [:]
                    for (index, value) in distinct.enumerated() { table[value] = index }
                    if table.count != 50 || !distinct.enumerated().allSatisfy({ table[$1] == $0 }) {
                        problems.append("a dictionary of 50 values at depth \(depth)")
                    }
                }
            }
            return problems
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    /// Things that are not equal stay apart in a set, whether or not their hashes differ.
    @Test func unequalValuesStayDistinct() {
        let distinct: [JSONValue] = [
            nil, true, false, 0, 1, -1, 1.5, "", "1", "true", "null", "a", "A", "caf\u{E9}", "cafe\u{301}", [], [:], [nil], [0], [[]], [[:]],
            ["a": 1], ["a": 2], ["b": 1], ["a": 1, "b": 1], ["a": [1]], ["a": ["a": 1]], [1, 2], [2, 1], [1, 2, 3], [[1], 2], [1, [2]],
            ["a": nil], ["": nil], [true], [false], ["1"], [1.5],
        ]
        #expect(Set(distinct).count == distinct.count)
        for depth in [1, 7, 8, 9, 12, 40] {
            for inObjects in [false, true] {
                let deep = distinct.map { wrapped($0, depth: depth, inObjects: inObjects) }
                let set = Set(deep)
                #expect(set.count == deep.count, "depth \(depth)")
                for value in deep { #expect(set.contains(value), "depth \(depth): \(value)") }
                // Arrays and objects of the same depth around the same core are different values.
                #expect(!set.contains(wrapped("not there", depth: depth, inObjects: inObjects)))
                #expect(!set.contains(wrapped(distinct[5], depth: depth, inObjects: !inObjects)))
                var table: [JSONValue: Int] = [:]
                for (index, value) in deep.enumerated() { table[value] = index }
                #expect(table.count == deep.count, "depth \(depth)")
                for (index, value) in deep.enumerated() { #expect(table[value] == index, "depth \(depth): \(value)") }
            }
        }
    }

    /// `uniqueItems` rests on that set: it must still tell a repeat from a near miss when the
    /// difference lies deeper than the hash looks.
    @Test func uniqueItemsBelowTheHashedDepth() throws {
        let schema = try JSONSchema(["uniqueItems": true])
        for depth in [0, 1, 7, 8, 9, 10, 16, 60] {
            for inObjects in [false, true] {
                let label: Comment = "depth \(depth), \(inObjects ? "objects" : "arrays")"
                let items = (0..<40).map { wrapped(JSONValue($0), depth: depth, inObjects: inObjects) }
                #expect(schema.validate(.array(items)) == nil, label)
                // An exact repeat, first and last, adjacent, and built separately.
                #expect(schema.validate(.array(items + [items[0]]))?.reason == "items must be unique", label)
                #expect(schema.validate(.array(items + [wrapped(39, depth: depth, inObjects: inObjects)]))?.reason == "items must be unique", label)
                #expect(schema.validate(.array([items[7], items[7]]))?.reason == "items must be unique", label)
                // Equal without being identical: `1` and `1.0`, and members in another order.
                #expect(schema.validate(.array(items + [wrapped(5.0, depth: depth, inObjects: inObjects)]))?.reason == "items must be unique", label)
                let ordered = wrapped(["x": 1, "y": [2, 3]], depth: depth, inObjects: inObjects)
                let reordered = wrapped(["y": [2.0, 3], "x": 1.0], depth: depth, inObjects: inObjects)
                #expect(schema.validate([ordered, reordered])?.reason == "items must be unique", label)
                // Near misses: another leaf, another key, one more or one fewer level, the other container.
                let nearMisses: [JSONValue] = [
                    wrapped(["x": 1, "y": [2, 4]], depth: depth, inObjects: inObjects),
                    wrapped(["x": 1, "z": [2, 3]], depth: depth, inObjects: inObjects),
                    wrapped(["x": 1, "y": [2, 3]], depth: depth + 1, inObjects: inObjects),
                    wrapped(["x": 1, "y": [[2, 3]]], depth: depth, inObjects: inObjects),
                    wrapped(["x": 1, "y": [2, 3]], depth: depth, inObjects: !inObjects),
                ]
                let candidates = depth == 0 ? Array(nearMisses.dropLast()) : nearMisses
                #expect(schema.validate(.array([ordered] + candidates)) == nil, label)
            }
        }
        // Through the parser, the way an instance really arrives.
        func document(_ leaves: [Int]) -> String { "[" + leaves.map { "[[[[[[[[[[{\"k\":[\($0)]}]]]]]]]]]]" }.joined(separator: ",") + "]" }
        #expect(schema.validate(try JSON.parse(document(Array(0..<50)))) == nil)
        #expect(schema.validate(try JSON.parse(document(Array(0..<50) + [17])))?.reason == "items must be unique")
    }

    /// The rule itself: every level a parsed value can have takes part in its hash; levels a
    /// value can only have when it is built in code do not, so hashing ends at any depth.
    @Test func hashingFollowsDepthUpToTheParserCeiling() {
        #expect(JSONParseOptions.depthCeiling == 256)
        // Built and taken apart on a thread with room: destroying a deep value is recursive.
        let (within, beyond): ([Bool], [Bool]) = {
            let slot = Slot<([Bool], [Bool])>()
            let finished = DispatchSemaphore(value: 0)
            let thread = Thread {
                // Different only at the leaf, as deep as a parsed value goes: different hashes.
                // (Not a law — two hashes may coincide — but 64 bits make it one.)
                let within = [1, 8, 9, 100, 254, 255].flatMap { depth in
                    [false, true].map { inObjects in
                        wrapped(1, depth: depth, inObjects: inObjects).hashValue != wrapped(2, depth: depth, inObjects: inObjects).hashValue
                    }
                }
                // Deeper than any parsed value: the difference is out of sight, and the cost stays bounded.
                let beyond = [257, 300, 20_000].flatMap { depth in
                    [false, true].map { inObjects in
                        let one = wrapped(1, depth: depth, inObjects: inObjects)
                        let other = wrapped(2, depth: depth, inObjects: inObjects)
                        return one.hashValue == other.hashValue && one != other && Set([one, other]).count == 2
                    }
                }
                slot.value = (within, beyond)
                finished.signal()
            }
            thread.stackSize = 256 << 20
            thread.start()
            finished.wait()
            return slot.value!
        }()
        #expect(within.allSatisfy { $0 }, "\(within)")
        #expect(beyond.allSatisfy { $0 }, "\(beyond)")
    }

    /// Values a parser can return that differ anywhere hash differently, so a set of them stays a
    /// set and `uniqueItems` takes time in proportion to the number of elements. (When only the
    /// top eight levels were hashed, 32,000 elements `[[[[[[[[[n]]]]]]]]]` — 757 KB of JSON —
    /// took 10.9 s in a release build.)
    @Test func uniqueItemsOverDeepValuesScalesLinearly() throws {
        let schema = try JSONSchema(["uniqueItems": true])
        let clock = ContinuousClock()
        func seconds(_ count: Int, depth: Int) -> Double {
            let instance = JSONValue.array((0..<count).map { wrapped(JSONValue($0), depth: depth) })
            var best = Double.infinity
            for _ in 0..<3 {
                var valid = false
                let elapsed = clock.measure { valid = schema.validate(instance) == nil }
                #expect(valid)
                best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            return best
        }
        for depth in [8, 9, 64, 200] {
            let count = depth > 9 ? 250 : 1000
            // Under a parallel run other tests compete for the CPU, and one measurement can be
            // off by more than the margin. A quadratic cost is 16 times as much every time, so
            // the pair is measured again, up to three times, before the ratio counts as failed.
            var once = 0.0
            var fourfold = 0.0
            for _ in 0..<3 {
                once = seconds(count, depth: depth)
                fourfold = seconds(count * 4, depth: depth)
                if fourfold < once * 8 + 0.01 { break }
            }
            #expect(fourfold < once * 8 + 0.01, "depth \(depth): \(count) elements took \(once) s, \(count * 4) took \(fourfold) s")
        }
        // Through the parser, at request size: 32,000 elements, each ten levels deep.
        let text = "[" + (0..<32_000).map { "[[[[[[[[[\($0)]]]]]]]]]" }.joined(separator: ",") + "]"
        let parsed = try JSON.parse(text)
        var valid = false
        let elapsed = clock.measure { valid = schema.validate(parsed) == nil }
        #expect(valid)
        #expect(elapsed < .seconds(5), "32,000 elements took \(elapsed)")
    }
}

private final class Slot<Value>: @unchecked Sendable {
    var value: Value?
}

/// Runs `body` on a thread with a 256 MiB stack and waits for the result.
private func onRoomyThread<Value: Sendable>(_ body: @escaping @Sendable () -> Value) -> Value {
    let slot = Slot<Value>()
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
        slot.value = body()
        finished.signal()
    }
    thread.stackSize = 256 << 20
    thread.start()
    finished.wait()
    return slot.value!
}
