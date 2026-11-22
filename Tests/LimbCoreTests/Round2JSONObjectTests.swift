import LimbCore
import Testing


private struct Round2ObjectRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The model: an ordered list of pairs, compared by bytes.
private struct Round2Model {
    var pairs: [(key: String, value: JSONValue)] = []

    func position(of key: String) -> Int? { pairs.firstIndex { Array($0.key.utf8) == Array(key.utf8) } }

    subscript(key: String) -> JSONValue? {
        get { position(of: key).map { pairs[$0].value } }
        set {
            if let index = position(of: key) {
                if let newValue { pairs[index].value = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
        }
    }
}

/// Keys that differ only in normalization or in bytes Swift's `==` ignores, plus plain ones.
private let round2TrickyKeys = [
    "caf\u{E9}", "cafe\u{301}", "\u{212B}", "\u{C5}", "A\u{30A}", "", "a\u{0}", "a", "A", "\u{1F600}", "\u{FEFF}k", "k",
    "\u{1100}\u{1161}", "\u{AC00}",
]

private func round2Key(_ index: Int) -> String { "key\(index)" }

/// Everything about `object` that the model says: count, order, every lookup in `probe`.
private func round2Check(
    _ object: JSONObject, against model: Round2Model, probe: [String], _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Bool {
    var ok = true
    if object.count != model.pairs.count {
        Issue.record("\(label): count \(object.count), model \(model.pairs.count)", sourceLocation: sourceLocation)
        return false
    }
    for (index, member) in object.enumerated() {
        let expected = model.pairs[index]
        if Array(member.key.utf8) != Array(expected.key.utf8) || member.value != expected.value {
            Issue.record("\(label): member \(index) is \(member), model \(expected)", sourceLocation: sourceLocation)
            ok = false
            break
        }
    }
    for key in probe {
        if object[key] != model[key] || object.contains(key) != (model[key] != nil) {
            Issue.record("\(label): lookup of \(key.debugDescription) gave \(String(describing: object[key])), model \(String(describing: model[key]))", sourceLocation: sourceLocation)
            ok = false
            break
        }
    }
    // A fresh object with the model's members is equal and hashes alike.
    let fresh = JSONObject(model.pairs.map { ($0.key, $0.value) })
    if object != fresh || fresh != object || object.hashValue != fresh.hashValue {
        Issue.record("\(label): not equal to a fresh copy of the model", sourceLocation: sourceLocation)
        ok = false
    }
    return ok
}

@Suite struct Round2JSONObjectTests {
    /// Objects of every size around the threshold, built five ways, are equal, hash alike and
    /// answer every lookup.
    @Test(arguments: [0, 1, 2, 23, 24, 25, 26, 47, 48, 49, 100, 1000])
    func everyWayOfBuildingAgrees(size: Int) throws {
        let keys = (0..<size).map(round2Key)
        let pairs = keys.enumerated().map { ($1, JSONValue($0)) }
        var bySubscript = JSONObject()
        for (key, value) in pairs { bySubscript[key] = value }
        var byAppend = JSONObject(minimumCapacity: size)
        for (key, value) in pairs { byAppend.appendUnchecked(key, value) }
        let byInit = JSONObject(pairs)
        let byMerge = JSONObject(pairs.prefix(size / 2)).merging(JSONObject(pairs.dropFirst(size / 2)))
        let text = "{" + pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        let parsed = try #require(try JSON.parse(text).objectValue)
        let reversed = JSONObject(pairs.reversed())
        let all = [bySubscript, byAppend, byInit, byMerge, parsed, reversed]
        let model = Round2Model(pairs: pairs.map { (key: $0.0, value: $0.1) })
        let probe = keys + ["missing", "key", "key\(size)", "Key0", "key0 "]
        for (index, object) in all.enumerated() {
            for other in all {
                #expect(object == other, "way \(index), size \(size)")
                #expect(object.hashValue == other.hashValue, "way \(index), size \(size)")
            }
            for key in probe {
                #expect(object[key] == model[key], "way \(index), size \(size), key \(key)")
            }
            #expect(JSONValue.object(object) == .object(bySubscript))
        }
        // Order is insertion order (the fallback codec does not keep member order).
        for object in [bySubscript, byAppend, byInit, byMerge] {
            #expect(object.map(\.key) == keys)
        }
        #if !FoundationJSON
        #expect(parsed.map(\.key) == keys)
        #endif
        #expect(reversed.map(\.key) == keys.reversed())
        // One value different, or one key different, is a different object.
        if size > 0 {
            for position in Set([0, size / 2, size - 1]) {
                var changed = bySubscript
                changed[keys[position]] = "changed"
                #expect(changed != bySubscript, "size \(size), value at \(position)")
                var renamed = JSONObject(pairs.enumerated().map { $0.offset == position ? ("other", $0.element.1) : $0.element })
                #expect(renamed != bySubscript, "size \(size), key at \(position)")
                #expect(bySubscript != renamed, "size \(size), key at \(position)")
                renamed["other"] = nil
                #expect(renamed.count == size - 1)
            }
        }
    }

    /// Keys equal under Swift's `==` but not byte for byte are different members, on both sides
    /// of the threshold and when the object crosses it.
    @Test(arguments: [0, 10, 24 - round2TrickyKeys.count + 1, 30, 200])
    func keysAreComparedByBytes(filler: Int) throws {
        var object = JSONObject()
        var model = Round2Model()
        let fill = (0..<max(0, filler)).map(round2Key)
        for (index, key) in (fill + round2TrickyKeys).enumerated() {
            object[key] = JSONValue(index)
            model[key] = JSONValue(index)
        }
        #expect(round2Check(object, against: model, probe: round2TrickyKeys + fill + ["caf"], "filler \(filler)"))
        // Each normalization variant can be replaced and removed on its own.
        object["cafe\u{301}"] = "decomposed"
        model["cafe\u{301}"] = "decomposed"
        object.removeValue(forKey: "\u{212B}")
        model["\u{212B}"] = nil
        #expect(object["caf\u{E9}"] != "decomposed")
        #expect(object["\u{C5}"] != nil && object["A\u{30A}"] != nil)
        #expect(round2Check(object, against: model, probe: round2TrickyKeys + fill, "filler \(filler), after changes"))
        // The parser agrees, and so does init(_:) with the same members in another order.
        var parsable = model.pairs
        #if FoundationJSON
        // Documented difference of the fallback: a string starting with U+FEFF is refused.
        parsable.removeAll { $0.key.unicodeScalars.first == "\u{FEFF}" }
        #endif
        let text = "{" + parsable.map { "\(JSONValue.string($0.key)):\($0.value)" }.joined(separator: ",") + "}"
        let parsed = try #require(try JSON.parse(text).objectValue)
        #expect(parsed == JSONObject(parsable.map { ($0.key, $0.value) }))
        #expect(parsed.hashValue == JSONObject(parsable.map { ($0.key, $0.value) }).hashValue)
        #expect(JSONObject(model.pairs.reversed().map { ($0.key, $0.value) }) == object)
        // An object with "é" composed is not equal to one with it decomposed.
        var composed = JSONObject(fill.map { ($0, JSONValue(0)) })
        var decomposed = composed
        composed["caf\u{E9}"] = 1
        decomposed["cafe\u{301}"] = 1
        #expect(composed != decomposed)
        #expect(decomposed != composed)
    }

    /// `init(_:)` and the subscript with repeated keys: first position, last value, on both
    /// sides of the threshold and across it.
    @Test(arguments: [3, 23, 24, 25, 60])
    func repeatedKeysKeepTheFirstPositionAndTheLastValue(size: Int) {
        let keys = (0..<size).map(round2Key)
        var pairs = keys.map { ($0, JSONValue(0)) }
        pairs.append((keys[0], 1))
        pairs.append((keys[size - 1], 2))
        pairs.append(("new", 3))
        pairs.append((keys[size / 2], 4))
        pairs.append(("new", 5))
        let object = JSONObject(pairs)
        #expect(object.count == size + 1)
        #expect(object.map(\.key) == keys + ["new"])
        #expect(object[keys[0]] == 1)
        #expect(object[keys[size - 1]] == 2)
        #expect(object[keys[size / 2]] == 4)
        #expect(object["new"] == 5)
        #if !FoundationJSON
        // The parser, when told to keep the last of repeated keys, agrees.
        let text = "{" + pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        let parsed = try? JSON.parse(text, options: JSONParseOptions(rejectDuplicateKeys: false)).objectValue
        #expect(parsed == object)
        #expect(parsed?.map(\.key) == object.map(\.key))
        #endif
    }

    /// Random sequences of every mutating operation against the model, crossing the threshold
    /// up and down many times. After every step the object answers what the model answers.
    @Test func randomOperationsMatchTheModel() {
        var random = Round2ObjectRandom(state: 0x4A31_0001)
        let pool = (0..<25).map(round2Key) + round2TrickyKeys
        var crossings = 0
        for run in 0..<20 {
            var object = JSONObject()
            var model = Round2Model()
            var wasLarge = false
            for step in 0..<240 {
                // Phases of growth and of shrinking, so that every run crosses the threshold
                // up and down several times. While shrinking, keys are mostly ones present.
                let growing = (step / 40) % 2 == 0
                let key = !growing && !model.pairs.isEmpty && Int.random(in: 0..<4, using: &random) != 0
                    ? model.pairs.randomElement(using: &random)!.key : pool.randomElement(using: &random)!
                let value = JSONValue(Int.random(in: 0..<1000, using: &random))
                switch Int.random(in: 0..<10, using: &random) {
                case 0, 1, 2:
                    object[key] = growing ? value : nil
                    model[key] = growing ? value : nil
                case 3:
                    if !growing {
                        object[key] = nil
                        model[key] = nil
                    }
                case 4, 5:
                    if !growing || step % 3 == 0 {
                        let removed = object.removeValue(forKey: key)
                        let expected = model[key]
                        model[key] = nil
                        if removed != expected { Issue.record("run \(run) step \(step): removed \(String(describing: removed)), expected \(String(describing: expected))") }
                    }
                case 6:
                    if growing, model[key] == nil {
                        object.appendUnchecked(key, value)
                        model.pairs.append((key, value))
                    }
                case 7 where growing:
                    // Merge in a few members, some new, some existing.
                    let other = JSONObject((0..<Int.random(in: 0...(growing ? 30 : 3), using: &random)).map { _ in
                        (pool.randomElement(using: &random)!, JSONValue(Int.random(in: 0..<1000, using: &random)))
                    })
                    object = object.merging(other)
                    for (key, value) in other { model[key] = value }
                case 8 where growing:
                    // Merge this object into another one.
                    let base = JSONObject((0..<Int.random(in: 0...(growing ? 30 : 3), using: &random)).map { _ in
                        (pool.randomElement(using: &random)!, JSONValue(-1))
                    })
                    var baseModel = Round2Model()
                    for (key, value) in base { baseModel[key] = value }
                    for (key, value) in model.pairs { baseModel[key] = value }
                    object = base.merging(object)
                    model = baseModel
                default:
                    // A copy mutated on its own leaves this one alone.
                    var copy = object
                    copy[pool.randomElement(using: &random)!] = "copy"
                    if let first = copy.first?.key { copy.removeValue(forKey: first) }
                }
                let isLarge = model.pairs.count > 24
                if isLarge != wasLarge { crossings += 1 }
                wasLarge = isLarge
                if !round2Check(object, against: model, probe: pool + ["absent"], "run \(run) step \(step)") { return }
            }
        }
        #expect(crossings > 50, "the runs crossed the threshold only \(crossings) times")
    }

    /// Removal keeps every later position right, from the front, the middle and the back, and
    /// back down through the threshold to empty, after which the object grows again.
    @Test func removalKeepsTheIndexRight() {
        for order in ["front", "back", "middle", "alternate"] {
            var object = JSONObject((0..<60).map { (round2Key($0), JSONValue($0)) })
            var model = Round2Model(pairs: (0..<60).map { (key: round2Key($0), value: JSONValue($0)) })
            var flip = false
            while !model.pairs.isEmpty {
                let index: Int
                switch order {
                case "front": index = 0
                case "back": index = model.pairs.count - 1
                case "middle": index = model.pairs.count / 2
                default:
                    flip.toggle()
                    index = flip ? 0 : model.pairs.count - 1
                }
                let key = model.pairs[index].key
                #expect(object.removeValue(forKey: key) == model.pairs[index].value)
                model.pairs.remove(at: index)
                if !round2Check(object, against: model, probe: (0..<61).map(round2Key), "\(order), \(model.pairs.count) left") { break }
            }
            #expect(object.isEmpty)
            // Empty after having been large: it grows again from nothing.
            for index in 0..<40 { object[round2Key(index)] = JSONValue(index) }
            model.pairs = (0..<40).map { (key: round2Key($0), value: JSONValue($0)) }
            #expect(round2Check(object, against: model, probe: (0..<41).map(round2Key), "\(order), regrown"))
        }
    }

    /// Copy-on-write: a copy changed in any way does not disturb the original's lookups, in
    /// either direction.
    @Test(arguments: [10, 25, 200])
    func copiesDoNotShareTheIndex(size: Int) {
        let original = JSONObject((0..<size).map { (round2Key($0), JSONValue($0)) })
        let model = Round2Model(pairs: (0..<size).map { (key: round2Key($0), value: JSONValue($0)) })
        let probe = (0...size).map(round2Key) + ["extra"]
        var copy = original
        copy.removeValue(forKey: round2Key(0))
        copy["extra"] = 1
        copy[round2Key(size / 2)] = "changed"
        for index in 0..<30 { copy["more\(index)"] = 0 }
        #expect(round2Check(original, against: model, probe: probe, "original after the copy changed"))
        #expect(copy[round2Key(1)] == 1 && copy[round2Key(0)] == nil && copy["extra"] == 1)
        // The other way: the original changes, a copy taken before does not.
        var source = original
        let snapshot = source
        for index in 0..<size where index % 2 == 0 { source.removeValue(forKey: round2Key(index)) }
        source["extra"] = 2
        #expect(round2Check(snapshot, against: model, probe: probe, "snapshot after the source changed"))
        #expect(source[round2Key(1)] == 1 && source[round2Key(0)] == nil)
    }

    /// Objects nested in arrays and sets: equality and hashing see through order at every level.
    @Test func nestedLargeObjectsInSets() throws {
        var random = Round2ObjectRandom(state: 0x4A31_0002)
        var values: [JSONValue] = []
        for _ in 0..<50 {
            let size = Int.random(in: 20...30, using: &random)
            let pairs = (0..<size).map { (round2Key($0), JSONValue(Int.random(in: 0..<3, using: &random))) }
            values.append(.object(JSONObject(pairs)))
            values.append(.object(JSONObject(pairs.shuffled(using: &random))))
        }
        let unique = Set(values)
        var distinct: [JSONValue] = []
        for value in values where !distinct.contains(value) { distinct.append(value) }
        #expect(unique.count == distinct.count)
        #expect(unique.count <= 50)
    }

    // MARK: Cost

    /// The authors' figures are for release builds; the bounds here are loose enough for debug.
    @Test func largeObjectsAreLinear() throws {
        let clock = ContinuousClock()
        let count = 100_000
        let members = (0..<count).map { "\"k\($0)\":\($0)" }
        let text = "{" + members.joined(separator: ",") + "}"
        let reversedText = "{" + members.reversed().joined(separator: ",") + "}"
        let a = try #require(try JSON.parse(text).objectValue)
        let b = try #require(try JSON.parse(reversedText).objectValue)
        let compare = clock.measure {
            #expect(a == b)
            #expect(b == a)
        }
        #expect(compare < .seconds(2), "comparing two \(count)-member objects took \(compare)")
        // Not equal, found late.
        var c = b
        c["k0"] = -1
        let unequal = clock.measure { #expect(a != c) }
        #expect(unequal < .seconds(2), "\(unequal)")

        let build = clock.measure {
            var object = JSONObject()
            for index in 0..<30_000 { object["k\(index)"] = JSONValue(index) }
            #expect(object.count == 30_000)
        }
        #expect(build < .seconds(2), "building 30k keys through the subscript took \(build)")

        let byInit = clock.measure {
            let object = JSONObject((0..<50_000).map { ("k\($0 % 40_000)", JSONValue($0)) })
            #expect(object.count == 40_000)
        }
        #expect(byInit < .seconds(2), "init(_:) with 50k pairs took \(byInit)")

        let large = JSONObject((0..<40_000).map { ("k\($0)", JSONValue($0)) })
        let small = JSONObject((0..<10).map { ("k\($0 * 1000)", JSONValue(-$0)) })
        let merge = clock.measure {
            #expect(large.merging(large).count == 40_000)
            #expect(small.merging(large).count == 40_000)
            #expect(large.merging(small).count == 40_000)
            #expect(JSONObject().merging(large) == large)
        }
        #expect(merge < .seconds(3), "merging 40k keys took \(merge)")

        // Hashing a large object, and a set of large objects.
        let hashing = clock.measure {
            #expect(a.hashValue == b.hashValue)
            #expect(Set([JSONValue.object(a), .object(b), .object(c)]).count == 2)
        }
        #expect(hashing < .seconds(3), "\(hashing)")
    }

    /// The admitted caveat: removing from a large object rewrites every later position. Measured
    /// here so that it is visible, with a bound that only catches something far worse than the
    /// authors reported. (Not reachable from the wire: the server removes at most two keys from
    /// a handler's own result, `_meta` and `resultType`, and nothing else removes keys.)
    @Test func removalFromALargeObjectIsLinearPerRemoval() {
        let clock = ContinuousClock()
        var object = JSONObject((0..<20_000).map { ("k\($0)", JSONValue($0)) })
        let elapsed = clock.measure {
            for index in stride(from: 0, to: 20_000, by: 100) { object.removeValue(forKey: "k\(index)") }
        }
        #expect(object.count == 19_800)
        #expect(object["k1"] == 1 && object["k100"] == nil && object["k19999"] == 19999)
        #expect(elapsed < .seconds(5), "200 removals from 20k members took \(elapsed)")
        // Removing from the end is cheap: nothing comes after.
        let fromTheEnd = clock.measure {
            for index in stride(from: 19_999, to: 10_000, by: -1) where index % 100 != 0 { object.removeValue(forKey: "k\(index)") }
        }
        #expect(fromTheEnd < .seconds(2), "\(fromTheEnd)")
        #expect(object["k9999"] == 9999 && object["k10001"] == nil)
    }
}
