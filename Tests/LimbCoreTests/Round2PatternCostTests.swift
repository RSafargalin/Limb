import LimbCore
import Testing


private func seconds(_ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let elapsed = clock.measure(body)
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

private func compiles(_ pattern: String, _ limits: JSONSchema.Limits = JSONSchema.Limits()) -> Bool {
    (try? JSONSchema(["pattern": .string(pattern)], limits: limits)) != nil
}

@Suite struct Round2PatternCostTests {
    /// Shapes that take exponential time in a backtracking engine, on 100,000 characters.
    @Test(arguments: [
        (#"^(a+)+$"#, "a", "b"), (#"^(\w+\s?)+$"#, "ab ", "!"), (#"(a*)*b"#, "a", "c"), (#"^(a|a)*$"#, "a", "b"),
        (#"^(a|aa)+$"#, "a", "b"), (#"(x+x+)+y"#, "x", "z"), (#"^(([a-z])+.)+[A-Z]([a-z])+$"#, "aa", "!"),
        (#"^(\d+)*$"#, "1", "x"), (#"^(a?){50}a{50}$"#, "a", "b"),
    ])
    func catastrophicBacktrackingShapesAreLinear(pattern: String, unit: String, tail: String) throws {
        let schema = try JSONSchema(["pattern": .string(pattern)])
        let string = String(repeating: unit, count: 100_000 / unit.count) + tail
        var violation: SchemaViolation?
        let time = seconds { violation = schema.validate(.string(string)) }
        #expect(violation != nil)
        #expect(time < 10, "\(pattern): \(time) s")
    }

    @Test func theStateLimitIsExact() {
        // The automaton has one instruction per character of `a{n}`, plus the final match.
        #expect(compiles("a{10000}"))
        #expect(!compiles("a{10001}"))
        #expect(compiles("(a{100}){100}"))
        #expect(!compiles("(a{100}){101}"))
        var small = JSONSchema.Limits()
        small.maxPatternStates = 100
        #expect(compiles("a{100}", small))
        #expect(!compiles("a{101}", small))
        // `a{2,5}` is `aa` plus three optional copies of (split, a): 2 + 3 × 2.
        small.maxPatternStates = 8
        #expect(compiles("a{2,5}", small))
        small.maxPatternStates = 7
        #expect(!compiles("a{2,5}", small))
    }

    /// Short patterns that expand to a great deal: each must be answered (compiled or refused)
    /// quickly — the compiler must not work for seconds before refusing.
    @Test(arguments: [
        "((a{0}){100000}){100000}", "(((a{0,0}){1000}){1000}){1000}", "((((a{0,100}){0,100}){0,100}){0,100})",
        "(a?){5000}a{5000}", "(a{100}){100}", "((a{10}){10}){10}", "((?:){100000}){100000}", #"(?:\b){100000}"#,
        #"[\p{L}\p{N}]{0,4999}"#, "(?:(?:(?:(?:(?:a|b){0,10}){0,10}){0,10}){0,10}){0,10}", "((((((((a*)*)*)*)*)*)*)*)*",
        "(?:a{100000}){100000}", "(?:(?:){0,100000}){0,100000}", "(a|){100000}",
    ])
    func compileCostIsBounded(pattern: String) {
        let time = seconds { _ = compiles(pattern) }
        #expect(time < 2, "\(pattern): \(time) s")
    }

    @Test func groupNestingIsLimitedToSixtyFour() throws {
        let deepest = String(repeating: "(", count: 64) + "a" + String(repeating: ")", count: 64)
        let tooDeep = "(" + deepest + ")"
        #expect(compiles(deepest))
        #expect(compiles(String(repeating: "(?:", count: 64) + "a" + String(repeating: ")", count: 64)))
        do {
            _ = try JSONSchema(["pattern": .string(tooDeep)])
            Issue.record("65 nested groups compiled")
        } catch {
            #expect(error.reason.contains("64"))
        }
        // Sixty-four groups in sequence are not nesting.
        #expect(compiles(String(repeating: "(a)", count: 1000)))
    }

    @Test func manyAlternativesAreLinear() throws {
        let words = (0..<1000).map { "w\($0)x" }
        let schema = try JSONSchema(["pattern": .string("^(?:" + words.joined(separator: "|") + ")$")])
        #expect(schema.validate("w999x") == nil)
        #expect(schema.validate("w1000x") != nil)
        let long = String(repeating: "w1", count: 20_000)
        let time = seconds { _ = schema.validate(.string(long)) }
        #expect(time < 10)
    }

    @Test func matchingCostIsProportionalToLength() throws {
        let schema = try JSONSchema(["pattern": "a{0,200}b"])
        let short = String(repeating: "a", count: 16 * 1024)
        let long = String(repeating: "a", count: 64 * 1024)
        _ = schema.validate(.string(short))
        let shortTime = seconds { #expect(schema.validate(.string(short)) != nil) }
        let longTime = seconds { #expect(schema.validate(.string(long)) != nil) }
        #expect(longTime < shortTime * 8 + 0.5, "16 KiB: \(shortTime) s, 64 KiB: \(longTime) s")
    }

    @Test(arguments: [#"a{0,4990}b"#, #"(?:a?){4990}b"#, #"\p{L}{0,4990}b"#, #"[\p{Lu}\p{Ll}\d]{0,4990}b"#, #"(?:[^a]|a){0,1990}b"#])
    func theWorstPatternsAreCutOff(pattern: String) throws {
        #if DEBUG
        var limits = JSONSchema.Limits()
        limits.maxPatternSteps = 5_000_000
        #else
        let limits = JSONSchema.Limits()
        #endif
        let schema = try JSONSchema(["pattern": .string(pattern)], limits: limits)
        for length in [64 * 1024, 1024 * 1024] {
            let string = JSONValue.string(String(repeating: "a", count: length))
            var violation: SchemaViolation?
            let time = seconds { violation = schema.validate(string) }
            #expect(violation?.reason == "matching patterns against this value takes more than \(limits.maxPatternSteps) steps")
            #expect(violation?.path == [])
            #expect(time < 10, "\(pattern) on \(length): \(time) s")
        }
    }

    /// Each call to the matcher sets up state for the whole automaton, however short the
    /// string: `patternProperties` with large automata against many short keys.
    @Test func manyShortStringsAgainstLargeAutomata() throws {
        let schema = try JSONSchema([
            "patternProperties": ["a{0,4990}b": true, "c{0,4990}d": true, "e{0,4990}f": true]
        ])
        var object = JSONObject()
        for index in 0..<20_000 { object.appendUnchecked("k\(index)", 0) }
        var violation: SchemaViolation?
        let time = seconds { violation = schema.validate(.object(object)) }
        #expect(violation == nil)
        #expect(time < 30, "\(time) s")
    }
}
