import LimbCore
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif


private struct Round2ExtremeRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let round2Bound: Int128 = 1_000_000_000_000_000_000

/// The reference value of a valid JSON number text.
private struct Round2Model: Equatable {
    var sign: Int = 0
    var digits: [UInt8] = []
    var exponent: Int128 = 0

    init(_ text: String) {
        var negative = false
        var point: Int128 = 0
        var inFraction = false
        var exponentText = ""
        var exponentNegative = false
        var inExponent = false
        for character in text {
            switch character {
            case "-": if inExponent { exponentNegative = true } else { negative = true }
            case "+": break
            case ".": inFraction = true
            case "e", "E": inExponent = true
            default:
                let digit = UInt8(character.asciiValue! - 48)
                if inExponent {
                    if !(exponentText.isEmpty && digit == 0) { exponentText.append(character) }
                } else if digits.isEmpty && digit == 0 {
                    if inFraction { point -= 1 }
                } else {
                    digits.append(digit)
                    if !inFraction { point += 1 }
                }
            }
        }
        while digits.last == 0 { digits.removeLast() }
        guard !digits.isEmpty else { return }
        sign = negative ? -1 : 1
        // Any exponent of more than 30 digits is far beyond every bound.
        let written: Int128 = exponentText.count > 30 ? Int128(10).power(30) : Int128(exponentText.isEmpty ? "0" : exponentText)!
        exponent = point + (exponentNegative ? -written : written)
        if exponent > round2Bound {
            digits = [1]
            exponent = round2Bound + 1
        } else if exponent < -round2Bound {
            digits = [1]
            exponent = -round2Bound - 1
        }
    }

    static func compare(_ a: Round2Model, _ b: Round2Model) -> Int {
        if a.sign != b.sign { return a.sign < b.sign ? -1 : 1 }
        if a.sign == 0 { return 0 }
        let magnitude: Int
        if a.exponent != b.exponent {
            magnitude = a.exponent < b.exponent ? -1 : 1
        } else if a.digits == b.digits {
            magnitude = 0
        } else {
            magnitude = a.digits.lexicographicallyPrecedes(b.digits) ? -1 : 1
        }
        return magnitude * a.sign
    }

    var isInteger: Bool { Int128(digits.count) <= exponent }

    var int64: Int64? {
        if sign == 0 { return 0 }
        guard isInteger, exponent <= 20 else { return nil }
        var value: Int128 = 0
        for index in 0..<Int(exponent) { value = value * 10 + Int128(index < digits.count ? digits[index] : 0) }
        return Int64(exactly: Int128(sign) * value)
    }

    /// Whether this value is an integer multiple of `divisor` (a positive value whose digits
    /// fit 19 decimal places), by modular arithmetic in Int128.
    func isMultiple(of divisor: Round2Model) -> Bool {
        if sign == 0 { return true }
        var modulus: Int128 = 0
        for digit in divisor.digits { modulus = modulus * 10 + Int128(digit) }
        let scale = divisor.exponent - Int128(divisor.digits.count)
        let shift = exponent - Int128(digits.count) - scale
        // Our digits do not end in zero, so a negative shift leaves a factor 1/10.
        guard shift >= 0 else { return false }
        var remainder: Int128 = 0
        for digit in digits { remainder = (remainder * 10 + Int128(digit)) % modulus }
        var power: Int128 = 10 % modulus
        var rest = shift
        while rest > 0, remainder != 0 {
            if rest & 1 == 1 { remainder = remainder * power % modulus }
            power = power * power % modulus
            rest >>= 1
        }
        return remainder == 0
    }
}

extension Int128 {
    fileprivate func power(_ exponent: Int) -> Int128 { (0..<exponent).reduce(1) { result, _ in result * self } }
}

/// Texts at every boundary the arithmetic has.
private func round2ExtremeTexts() -> [String] {
    let longDigits = String(repeating: "7", count: 20_000)
    var texts = [
        "0", "-0", "0.0", "-0.0", "0e0", "0e9999999999999999999", "-0e9999999999999999999", "0.000e-99999999999999999999",
        "-0E+" + String(repeating: "9", count: 40), "0." + String(repeating: "0", count: 1000) + "e4000000000000000000",
        "1", "-1", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "-9223372036854775809",
        "18446744073709551615", "18446744073709551616", "9.223372036854775807e18", "-92233720368547758.08e2",
        "1e18", "1e19", "1e20", "1e-18", "1e400", "-1e400", "1e-400",
        // Around the clamp, in 0.d × 10^e terms: e = 10^18 is the last exact exponent.
        "1e999999999999999999", "9.99e999999999999999999", "1e1000000000000000000", "9e1000000000000000000",
        "0.1e1000000000000000000", "0.999e1000000000000000000", "10e1000000000000000000", "1e1000000000000000001",
        "1e-1000000000000000000", "1e-1000000000000000001", "9e-1000000000000000001", "1e-1000000000000000002",
        "0.1e-999999999999999999", "0.01e-1000000000000000000", "-1e1000000000000000000", "-1e-1000000000000000002",
        // Around the reader's ceiling and Int64.
        "1e4000000000000000000", "1e3999999999999999999", "1e4000000000000000001", "1e400000000000000000", "1e399999999999999999",
        "1e9223372036854775807", "1e9223372036854775808", "1e-9223372036854775808", "1e18446744073709551616",
        "1e922337203685477580", "1e922337203685477581", "1e9999999999999999999", "1e-9999999999999999999",
        "2E+999999999999999999999", "1e" + String(repeating: "9", count: 30), "-1e-" + String(repeating: "9", count: 30),
        // Leading zeros in the exponent do not count.
        "1e" + String(repeating: "0", count: 40) + "5", "1e-" + String(repeating: "0", count: 40) + "1000000000000000001",
        "1e+" + String(repeating: "0", count: 20) + "999999999999999999",
        // Many digits with huge exponents: the position of the point moves the exponent.
        "1" + String(repeating: "0", count: 1000) + "e999999999999999000", "1" + String(repeating: "0", count: 1000) + "e999999999999998999",
        "0." + String(repeating: "0", count: 1000) + "1e-999999999999999000", "0." + String(repeating: "0", count: 1000) + "1e-999999999999998999",
        longDigits, longDigits + "e-4000000000000000000", longDigits + "e3999999999999999999", "0." + longDigits + "e-1000000000000000000",
        longDigits + "e-1000000000000000000", "1" + String(repeating: "0", count: 20_000) + "e-20000",
    ]
    texts += texts.filter { !$0.hasPrefix("-") && $0.utf8.count < 1000 }.map { "-" + $0 }
    return texts
}

private let round2Divisors = [
    "1", "3", "7", "0.5", "0.0001", "1e-400", "1.5", "25e17", "9999999999999999999", "9.999999999999999999e-1000000000000000000",
    "1e-2000000000000000000", "1e2000000000000000000", "7e999999999999999999", "4e-999999999999999999", "1e-1000000000000000000",
    "1e1000000000000000000", "1e-" + String(repeating: "9", count: 30),
]

private let round2Bounds = [
    "0", "1e1000000000000000000", "1e999999999999999999", "1e-1000000000000000000", "1e-1000000000000000002", "-1e1000000000000000001",
    "9223372036854775807", "1e9999999999999999999", "-1e-9999999999999999999",
]

private func round2SchemaSupports(_ model: Round2Model) -> Bool {
    (-round2Bound...round2Bound).contains(model.exponent)
}

private func round2IsExponentRefusal(_ reason: String?) -> Bool {
    reason?.lowercased().contains("exponent") == true
}

/// The numbers a text gives in each storage.
private func round2Storages(_ text: String) -> [(JSONNumber, String)] {
    let lexeme = JSONNumber(lexeme: text)!
    var result = [(lexeme, text)]
    if let value = lexeme.int64Value { result.append((JSONNumber(value), String(value))) }
    let double = lexeme.doubleValue
    if let number = JSONNumber(double) { result.append((number, double.description)) }
    return result
}

/// Every check on one list of texts; returns what differs from the model.
private func round2Check(_ texts: [String], pairs: Bool) -> [String] {
    var problems: [String] = []
    func note(_ text: String) {
        if problems.count < 30 { problems.append(text.count > 300 ? String(text.prefix(300)) + "…" : text) }
    }
    func compileOperand(_ key: String, _ text: String, additional: JSONObject = [:]) -> (JSONSchema, Round2Model, String)? {
        let model = Round2Model(text)
        var definition = additional
        definition[key] = .number(JSONNumber(lexeme: text)!)
        do {
            let schema = try JSONSchema(.object(definition))
            if round2SchemaSupports(model) { return (schema, model, text) }
            note("\(key) \(text): compiled outside the numeric domain")
        } catch {
            if round2SchemaSupports(model) || !round2IsExponentRefusal(error.reason) {
                note("\(key) \(text): \(error.reason)")
            }
        }
        return nil
    }
    let divisors = round2Divisors.compactMap { compileOperand("multipleOf", $0) }
    _ = compileOperand("exclusiveMaximum", "1e4000000000000000000")
    let ceiling = "2e999999999999999999"
    let ceilingValue = JSONValue.number(JSONNumber(lexeme: ceiling)!)
    let ceilingModel = Round2Model(ceiling)
    let bounds = round2Bounds.compactMap {
        compileOperand("minimum", $0, additional: ["exclusiveMaximum": ceilingValue])
    }
    var all: [(JSONNumber, Round2Model, String)] = []
    for text in texts {
        for (number, spelled) in round2Storages(text) {
            let model = Round2Model(spelled)
            all.append((number, model, spelled))
            let label = String(spelled.prefix(60))
            if number.isInteger != model.isInteger { note("\(label): isInteger \(number.isInteger)") }
            if number.int64Value != model.int64 { note("\(label): int64Value \(String(describing: number.int64Value)), model \(String(describing: model.int64))") }
            if number.intValue != model.int64.flatMap({ Int(exactly: $0) }) { note("\(label): intValue") }
            if JSONValue.number(number).typeName != (model.isInteger ? "integer" : "number") { note("\(label): typeName") }
            do {
                let double = number.doubleValue
                if model.sign == 0, double != 0 { note("\(label): doubleValue \(double)") }
                if model.exponent > 400, double.isFinite { note("\(label): doubleValue \(double)") }
                if model.exponent < -400, model.sign != 0, double != 0 { note("\(label): doubleValue \(double)") }
                if model.sign != 0, double != 0, (double < 0) != (model.sign < 0) { note("\(label): doubleValue sign") }
            }
            // The writer, and reading the text back.
            let written = JSONValue.number(number).description
            if JSONNumber(lexeme: written) != number { note("\(label): written as \(written.prefix(60))") }
            if number != number || number < number { note("\(label): not reflexive") }
            // Megabyte texts against three divisors only: each check reads every digit.
            for (schema, divisor, divisorText) in spelled.utf8.count > 100_000 ? Array(divisors.prefix(3)) : divisors {
                let violation = schema.validate(.number(number))
                if round2SchemaSupports(model) {
                    if (violation == nil) != model.isMultiple(of: divisor) { note("\(label) multipleOf \(divisorText): \(String(describing: violation))") }
                } else if !round2IsExponentRefusal(violation?.reason) {
                    note("\(label) multipleOf \(divisorText): expected exponent refusal")
                }
            }
            for (schema, bound, boundText) in bounds {
                let violation = schema.validate(.number(number))
                if round2SchemaSupports(model) {
                    let expected = Round2Model.compare(model, bound) >= 0 && Round2Model.compare(model, ceilingModel) < 0
                    if (violation == nil) != expected { note("\(label) minimum \(boundText): \(String(describing: violation))") }
                } else if !round2IsExponentRefusal(violation?.reason) {
                    note("\(label) minimum \(boundText): expected exponent refusal")
                }
            }
        }
    }
    if pairs {
        // Every pair of short texts; each long text (a comparison reads all of it) against a
        // sample of short ones in both orders, and against every other long one.
        let short = all.filter { $0.2.utf8.count <= 10_000 }
        let long = all.filter { $0.2.utf8.count > 10_000 }
        let sample = stride(from: 0, to: short.count, by: 7).map { short[$0] }
        var couples: [((JSONNumber, Round2Model, String), (JSONNumber, Round2Model, String))] = []
        for a in short { for b in short { couples.append((a, b)) } }
        for a in long {
            for b in sample { couples.append((a, b)); couples.append((b, a)) }
            for b in long { couples.append((a, b)) }
        }
        for ((a, ma, ta), (b, mb, tb)) in couples {
            let expected = Round2Model.compare(ma, mb)
            if (a == b) != (expected == 0) { note("\(ta.prefix(60)) == \(tb.prefix(60)) is \(a == b)") }
            if (a < b) != (expected < 0) { note("\(ta.prefix(60)) < \(tb.prefix(60)) is \(a < b)") }
            if a == b, a.hashValue != b.hashValue { note("\(ta.prefix(60)) and \(tb.prefix(60)) are equal, hash differently") }
        }
    } else {
        // Neighbours only, for long random lists.
        for index in all.indices.dropFirst() {
            let (a, ma, ta) = all[index - 1]
            let (b, mb, tb) = all[index]
            let expected = Round2Model.compare(ma, mb)
            if (a == b) != (expected == 0) || (a < b) != (expected < 0) || (b < a) != (expected > 0) {
                note("\(ta.prefix(60)) vs \(tb.prefix(60)): ==\(a == b) <\(a < b) >\(b < a), model \(expected)")
            }
            if a == b, a.hashValue != b.hashValue { note("\(ta.prefix(60)) and \(tb.prefix(60)) are equal, hash differently") }
        }
    }
    return problems
}

private func round2SchemaMagnitudeProblems() -> [String] {
    var problems: [String] = []
    func n(_ text: String) -> JSONValue { .number(JSONNumber(lexeme: text)!) }
    func expectExponentRefusal(_ key: String, _ text: String) {
        do {
            _ = try JSONSchema([key: n(text)])
            problems.append("\(key) \(text) compiled")
        } catch {
            if !round2IsExponentRefusal(error.reason) { problems.append("\(key) \(text): \(error.reason)") }
        }
    }
    // Integral counts beyond Int saturate to Int.max.
    for text in ["1e9999999999999999999", "18446744073709551616", "9223372036854775808", "1e400", "4e4000000000000000000"] {
        for key in ["maxLength", "maxItems", "maxProperties"] {
            guard let schema = try? JSONSchema([key: n(text)]) else { problems.append("\(key) \(text) refused"); continue }
            for value: JSONValue in ["abc", [1, 2], ["a": 1]] where schema.validate(value) != nil { problems.append("\(key) \(text) refused \(value)") }
        }
        for key in ["minLength", "minItems", "minProperties"] {
            guard let schema = try? JSONSchema([key: n(text)]) else { problems.append("\(key) \(text) refused"); continue }
            let value: JSONValue = key == "minLength" ? "abc" : key == "minItems" ? [1, 2] : ["a": 1]
            if schema.validate(value) == nil { problems.append("\(key) \(text) accepted \(value)") }
        }
    }
    // Not non-negative integers: refused at compile time.
    for text in ["-1e9999999999999999999", "1e-9999999999999999999", "-1", "0.5", "1.0000000000000000000001"] {
        if (try? JSONSchema(["maxLength": n(text)])) != nil { problems.append("maxLength \(text) compiled") }
    }
    if (try? JSONSchema(["maxLength": n("-0")])) == nil { problems.append("maxLength -0 refused") }
    // multipleOf requires a positive divisor within the exponent and significant-digit limits.
    for text in ["0", "-0e9999999999999999999", "-3", "-1e-9999999999999999999", "12345678901234567891"] {
        if (try? JSONSchema(["multipleOf": n(text)])) != nil { problems.append("multipleOf \(text) compiled") }
    }
    for text in ["1e-9999999999999999999", "1e9999999999999999999", "9999999999999999999e-4000000000000000000"] {
        expectExponentRefusal("multipleOf", text)
    }
    // Negative and huge limits: no trap; a negative step budget fails closed.
    var limits = JSONSchema.Limits()
    limits.maxEvaluations = -5
    limits.maxPatternSteps = .min
    limits.maxPatternStates = .max
    limits.maxValidationRecursion = .max
    if let schema = try? JSONSchema(["type": "string", "pattern": "^a+$"], limits: limits), schema.validate("aaa") == nil {
        problems.append("a negative evaluation budget accepted a value")
    }
    // Pattern counts and escapes beyond any width: refused, not trapped.
    for pattern in ["a{99999999999999999999999999}", "a{1,99999999999999999999999999}", "a{18446744073709551616}", "\\u{FFFFFFFFFFFFFFFFFFFFFFFF}",
        "a{9223372036854775807,9223372036854775808}"]
    {
        if (try? JSONSchema(["pattern": .string(pattern)])) != nil { problems.append("pattern \(pattern) compiled") }
    }
    return problems
}

/// The megabyte cases: few operations each, as every one of them reads all the digits.
private func round2CheckMegabytes() -> [String] {
    let digits = 4 * 1024 * 1024
    let sevens = String(repeating: "7", count: digits)
    let one = JSONNumber(lexeme: "1")!
    let integerSchema = try! JSONSchema(["type": "integer"])
    let multipleSchema = try! JSONSchema(["multipleOf": 1])
    var problems: [String] = []
    let cases: [(String, Int)] = [
        // text, expected sign of comparison with 1e(10^18) clamped (1 = above or merged? no: -1 below, 0 merged)
        (sevens, -1), (sevens + "e-4000000000000000000", -1), (sevens + "e3999999999999999999", 0), (sevens + "e999999999999999999", 0),
        (sevens + "e" + String(1_000_000_000_000_000_000 - digits), -1), (sevens + "e" + String(1_000_000_000_000_000_000 - digits + 1), 0),
        ("0." + sevens + "e-1000000000000000000", -1), ("1" + String(repeating: "0", count: digits) + "e-4194304", -1),
    ]
    let huge = JSONNumber(lexeme: "1e1000000000000000000")!
    for (text, expected) in cases {
        let number = JSONNumber(lexeme: text)!
        let model = Round2Model(text)
        let label = String(text.suffix(30))
        let comparison = number < huge ? -1 : number == huge ? 0 : 1
        if comparison != expected { problems.append("\(label): compared with 1e(10^18): \(comparison)") }
        if number.isInteger != model.isInteger { problems.append("\(label): isInteger") }
        if number.int64Value != model.int64 { problems.append("\(label): int64Value") }
        if (number == one) != (Round2Model.compare(model, Round2Model("1")) == 0) { problems.append("\(label): == 1") }
        let value = JSONValue.number(number)
        if (integerSchema.validate(value) == nil) != model.isInteger { problems.append("\(label): integer schema") }
        let violation = multipleSchema.validate(value)
        if round2SchemaSupports(model) {
            if (violation == nil) != model.isInteger { problems.append("\(label): multipleOf schema") }
        } else if !round2IsExponentRefusal(violation?.reason) {
            problems.append("\(label): multipleOf schema expected exponent refusal")
        }
        if expected == 0, number.hashValue != huge.hashValue { problems.append("\(label): merged but hashes differently") }
        if JSONNumber(lexeme: JSONValue.number(number).description) != number { problems.append("\(label): writer") }
    }
    return problems
}

/// Random number texts from the JSON grammar, biased to extremes: exponents placed so that the
/// value's exponent lands on and around ±10¹⁸, the reader's ceiling and the Int64 limits; long
/// and zero significands; leading zeros in exponents.
private func round2RandomTexts(_ count: Int, seed: UInt64) -> [String] {
    var random = Round2ExtremeRandom(state: seed)
    let targets: [Int128] = [
        0, 1, 19, 20, 400, -400, round2Bound - 1, round2Bound, round2Bound + 1, round2Bound + 2, -round2Bound - 2, -round2Bound - 1,
        -round2Bound, -round2Bound + 1, 4 * round2Bound, 4 * round2Bound + 1, -4 * round2Bound, Int128(Int64.max), Int128(Int64.max) + 1,
        -Int128(Int64.max), Int128(UInt64.max) + 7,
    ]
    var texts: [String] = []
    texts.reserveCapacity(count)
    for _ in 0..<count {
        var text = Bool.random(using: &random) && Int.random(in: 0..<10, using: &random) < 3 ? "-" : ""
        // The significand.
        var digits = ""
        let length: Int
        switch Int.random(in: 0..<100, using: &random) {
        case 0: length = Int.random(in: 200...2000, using: &random)
        case 1..<10: length = 0
        case 10..<30: length = 1
        default: length = Int.random(in: 1...25, using: &random)
        }
        for _ in 0..<length {
            let r = Int.random(in: 0..<10, using: &random)
            digits.append(r < 3 ? "9" : r < 6 ? "0" : String(Int.random(in: 0...9, using: &random)))
        }
        if digits.isEmpty { digits = "0" }
        let pointAt = Int.random(in: 0...digits.count, using: &random)
        var integerPart = String(digits.prefix(pointAt))
        var fraction = String(digits.dropFirst(pointAt))
        // JSON allows no leading zeros in the integer part.
        integerPart = String(integerPart.drop { $0 == "0" })
        if integerPart.isEmpty { integerPart = "0" }
        text += integerPart
        if !fraction.isEmpty, Int.random(in: 0..<4, using: &random) != 0 {
            text += "." + fraction
        } else {
            fraction = ""
        }
        // The exponent.
        if Int.random(in: 0..<10, using: &random) < 8 {
            text += Bool.random(using: &random) ? "e" : "E"
            // The position of the point of what has been written so far, in 0.d × 10^e terms.
            let significant = (integerPart == "0" ? "" : integerPart) + fraction
            let leadingZeros = integerPart == "0" ? fraction.prefix { $0 == "0" }.count : 0
            let point = integerPart == "0" ? -Int128(leadingZeros) : Int128(integerPart.count)
            var written: Int128
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<6 where !significant.allSatisfy({ $0 == "0" }):
                written = targets.randomElement(using: &random)! - point + Int128(Int.random(in: -2...2, using: &random))
            case 6:
                written = Int128(Int.random(in: -400...400, using: &random))
            case 7:
                var big = ""
                for _ in 0..<Int.random(in: 19...30, using: &random) { big.append(String(Int.random(in: 0...9, using: &random))) }
                written = Int128(big)! * (Bool.random(using: &random) ? 1 : -1)
            default:
                written = targets.randomElement(using: &random)! * (Bool.random(using: &random) ? 1 : -1)
            }
            if written < 0 {
                text += "-"
            } else if Bool.random(using: &random) {
                text += "+"
            }
            let zeros = Int.random(in: 0..<10, using: &random) == 0 ? String(repeating: "0", count: Int.random(in: 1...25, using: &random)) : ""
            text += zeros + String(written.magnitude)
        }
        texts.append(text)
    }
    return texts
}

@Suite struct Round2JSONNumberExtremesTests {
    @Test func doubleValueOfALongTextDoesNotTrap() async {
        #if canImport(Darwin)
        // Darwin's standard library accepts 16,384 bytes and rejects 16,385.
        #expect(Double(String(repeating: "7", count: 16_384)) != nil)
        #expect(Double(String(repeating: "7", count: 16_385)) == nil)
        #endif
        #expect(JSONNumber(lexeme: "1." + String(repeating: "0", count: 16_382))!.doubleValue == 1)
        await #expect(processExitsWith: .success) {
            precondition(JSONNumber(lexeme: "1." + String(repeating: "0", count: 16_383))!.doubleValue == 1)
        }
        await #expect(processExitsWith: .success) {
            precondition(JSONNumber(lexeme: String(repeating: "7", count: 20_000))!.doubleValue == .infinity)
        }
        await #expect(processExitsWith: .success) {
            precondition(JSONNumber(lexeme: "0." + String(repeating: "0", count: 20_000) + "1")!.doubleValue == 0)
        }
        await #expect(processExitsWith: .success) {
            let value = JSONValue.number(JSONNumber(lexeme: "2" + String(repeating: "0", count: 30_000) + "e-30000")!)
            precondition((try? Double(json: value)) == 2)
        }
    }

    /// Every boundary text, in all three storages, against the model and against each other.
    @Test func extremeTextsAgreeWithTheModel() async {
        let result = await #expect(processExitsWith: .success) {
            let problems = round2Check(round2ExtremeTexts(), pairs: true)
            precondition(problems.isEmpty)
        }
        guard result?.exitStatus == .exitCode(0) else { return }
        let problems = round2Check(round2ExtremeTexts(), pairs: true)
        #expect(problems.isEmpty, "\(problems)")
    }

    /// 80,000 random texts in a child process (a trap or a disagreement fails it), then 20,000
    /// here with the disagreements named. `R2_FUZZ_ROUNDS=n` runs n rounds of 20,000 in the
    /// child instead of 4 (300,000 texts: 15).
    @Test func randomExtremeTextsAgreeWithTheModel() async {
        await #expect(processExitsWith: .success) {
            let rounds = getenv("R2_FUZZ_ROUNDS").flatMap { UInt64(String(cString: $0)) } ?? 4
            for seed: UInt64 in 1...max(1, rounds) {
                let texts = round2RandomTexts(20_000, seed: 0x4A32_5000 &+ seed)
                for text in texts { precondition(JSONNumber(lexeme: text) != nil, text) }
                let problems = round2Check(texts, pairs: false)
                precondition(problems.isEmpty, "\(problems)")
            }
        }
        let texts = round2RandomTexts(20_000, seed: 0x4A32_5001)
        #expect(texts.allSatisfy { JSONNumber(lexeme: $0) != nil })
        let problems = round2Check(texts, pairs: false)
        #expect(problems.isEmpty, "\(problems)")
        // The generator reached both sides of the clamp and the ceiling.
        let models = texts.map(Round2Model.init)
        #expect(models.contains { $0.exponent == round2Bound + 1 } && models.contains { $0.exponent == round2Bound })
        #expect(models.contains { $0.exponent == -round2Bound - 1 } && models.contains { $0.exponent == -round2Bound })
        #expect(texts.contains { $0.utf8.count > 200 })
    }

    /// Four megabytes of digits combined with exponents at the clamp and the reader's ceiling:
    /// the position of the point (4,194,304) moves the value's exponent, and nothing overflows.
    @Test func megabyteNumbersWithHugeExponents() async {
        await #expect(processExitsWith: .success) {
            let problems = round2CheckMegabytes()
            precondition(problems.isEmpty, "\(problems)")
        }
    }

    /// Schema keywords that take counts and limits, given magnitudes beyond `Int`, negative
    /// limits, and pattern counts and escapes beyond any width: compiled or refused, never a
    /// trap. In a child process first.
    @Test func schemaMagnitudesBeyondEveryWidth() async {
        await #expect(processExitsWith: .success) { _ = round2SchemaMagnitudeProblems() }
        let problems = round2SchemaMagnitudeProblems()
        #expect(problems.isEmpty, "\(problems)")
    }

    /// D1 at the bound, against the doc comment of `JSONNumber`: "numbers whose decimal exponent
    /// is beyond ±10¹⁸ … merge". In `0.d × 10^e` terms that is exact; in scientific terms
    /// (d.ddd × 10^E) the merge starts at E = 10¹⁸ on the large side and at E = −10¹⁸ − 2 on the
    /// small side.
    @Test func theBoundIsWhereTheDocumentationSays() {
        func n(_ text: String) -> JSONNumber { JSONNumber(lexeme: text)! }
        // Large side: 0.999… × 10^(10^18) is the largest exact value; 10^(10^18) and everything
        // larger is one value.
        #expect(n("0.999e1000000000000000000") < n("1e1000000000000000000"))
        #expect(n("9.99e999999999999999999") < n("1e1000000000000000000"))
        #expect(n("1e1000000000000000000") == n("9e1000000000000000000"))
        #expect(n("1e1000000000000000000") == n("1e" + String(repeating: "9", count: 50)))
        #expect(n("1e1000000000000000000").hashValue == n("9e1000000000000000000").hashValue)
        #expect(n("1e1000000000000000000").isInteger)
        // Small side: 0.1 × 10^(−10^18) is the smallest exact positive value.
        #expect(n("1e-1000000000000000001") > n("1e-1000000000000000002"))
        #expect(n("1e-1000000000000000001") != n("2e-1000000000000000001"))
        #expect(n("1e-1000000000000000002") == n("9e-1000000000000000002"))
        #expect(n("1e-1000000000000000002") == n("1e-" + String(repeating: "9", count: 50)))
        #expect(n("1e-1000000000000000002").hashValue == n("9e-1000000000000000002").hashValue)
        #expect(n("1e-1000000000000000002") > 0 && !n("1e-1000000000000000002").isInteger)
        // Negative numbers mirror it; zero is never merged with anything.
        #expect(n("-1e1000000000000000000") == n("-9e1000000000000000000"))
        #expect(n("-1e1000000000000000000") < n("-0.999e1000000000000000000"))
        #expect(n("-1e-1000000000000000002") < 0 && n("-1e-1000000000000000002") > n("-1e-1000000000000000001"))
        #expect(n("0e9999999999999999999") == 0 && n("-0e-9999999999999999999") == 0)
        #expect(n("0e9999999999999999999").hashValue == JSONNumber(0).hashValue)
    }
}
