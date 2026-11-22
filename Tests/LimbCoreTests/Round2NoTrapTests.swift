#if canImport(Darwin)
import Darwin
import LimbCore
import Testing


private struct Round2TrapRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func round2Scale() -> Int { getenv("R2_NOTRAP_SCALE").flatMap { Int(String(cString: $0)) } ?? 1 }

private func round2Strtod(_ text: String) -> Double { text.withCString { strtod($0, nil) } }

// MARK: - An exact oracle

/// A non-negative big integer, little-endian 32-bit limbs.
private struct Round2Big: Comparable {
    var limbs: [UInt32] = []

    init(_ value: UInt64) {
        var value = value
        while value != 0 {
            limbs.append(UInt32(truncatingIfNeeded: value))
            value >>= 32
        }
    }

    init(decimal digits: [UInt8]) {
        var chunk: UInt32 = 0
        var size: UInt32 = 1
        for digit in digits {
            chunk = chunk * 10 + UInt32(digit)
            size *= 10
            if size == 1_000_000_000 {
                multiply(by: size, adding: chunk)
                chunk = 0
                size = 1
            }
        }
        if size > 1 { multiply(by: size, adding: chunk) }
    }

    mutating func multiply(by factor: UInt32, adding addend: UInt32 = 0) {
        var carry = UInt64(addend)
        for index in limbs.indices {
            let product = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(truncatingIfNeeded: product)
            carry = product >> 32
        }
        if carry != 0 { limbs.append(UInt32(carry)) }
        while limbs.last == 0 { limbs.removeLast() }
    }

    mutating func multiplyByPowerOfTen(_ exponent: Int) {
        var rest = exponent
        while rest >= 9 {
            multiply(by: 1_000_000_000)
            rest -= 9
        }
        var factor: UInt32 = 1
        for _ in 0..<rest { factor *= 10 }
        multiply(by: factor)
    }

    mutating func multiplyByPowerOfTwo(_ exponent: Int) {
        guard !limbs.isEmpty else { return }
        let words = exponent / 32
        let bits = exponent % 32
        if bits != 0 {
            var carry: UInt32 = 0
            for index in limbs.indices {
                let value = limbs[index]
                limbs[index] = value << UInt32(bits) | carry
                carry = value >> UInt32(32 - bits)
            }
            if carry != 0 { limbs.append(carry) }
        }
        limbs.insert(contentsOf: repeatElement(0, count: words), at: 0)
    }

    /// Decimal digits, most significant first.
    var decimalDigits: [UInt8] {
        var value = limbs
        var chunks: [UInt32] = []
        while !value.isEmpty {
            var remainder: UInt64 = 0
            for index in value.indices.reversed() {
                let current = remainder << 32 | UInt64(value[index])
                value[index] = UInt32(current / 1_000_000_000)
                remainder = current % 1_000_000_000
            }
            while value.last == 0 { value.removeLast() }
            chunks.append(UInt32(remainder))
        }
        var digits: [UInt8] = []
        for (position, chunk) in chunks.reversed().enumerated() {
            let text = String(chunk)
            let padded = position == 0 ? text : String(repeating: "0", count: 9 - text.count) + text
            digits += padded.utf8.map { $0 - 48 }
        }
        return digits.isEmpty ? [0] : digits
    }

    static func < (a: Round2Big, b: Round2Big) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for index in a.limbs.indices.reversed() where a.limbs[index] != b.limbs[index] {
            return a.limbs[index] < b.limbs[index]
        }
        return false
    }
}

/// `digits × 10^scale`, read from a valid number text with a small exponent.
private func round2Exact(_ text: String) -> (negative: Bool, digits: [UInt8], scale: Int) {
    var negative = false
    var digits: [UInt8] = []
    var fraction = 0
    var inFraction = false
    var exponentText = ""
    var inExponent = false
    for byte in text.utf8 {
        switch byte {
        case 0x2D: if inExponent { exponentText.append("-") } else { negative = true }
        case 0x2B: break
        case 0x2E: inFraction = true
        case 0x45, 0x65: inExponent = true
        default:
            if inExponent {
                exponentText.append(Character(Unicode.Scalar(byte)))
            } else {
                if !(digits.isEmpty && byte == 0x30) { digits.append(byte - 48) }
                if inFraction { fraction += 1 }
            }
        }
    }
    return (negative, digits, (Int(exponentText) ?? 0) - fraction)
}

/// Compares `digits × 10^scale` with `significand × 2^power`: -1, 0 or 1.
private func round2Compare(_ digits: [UInt8], _ scale: Int, _ significand: UInt64, _ power: Int) -> Int {
    var left = Round2Big(decimal: digits)
    var right = Round2Big(significand)
    if scale >= 0 { left.multiplyByPowerOfTen(scale) } else { right.multiplyByPowerOfTen(-scale) }
    if power >= 0 { right.multiplyByPowerOfTwo(power) } else { left.multiplyByPowerOfTwo(-power) }
    return left < right ? -1 : right < left ? 1 : 0
}

/// Whether `result` is the correctly rounded (ties to even) Double of `text`, by exact
/// comparison with the midpoints around it.
private func round2IsCorrectlyRounded(_ text: String, _ result: Double) -> Bool {
    let exact = round2Exact(text)
    if exact.digits.isEmpty { return result == 0 && (result.sign == .minus) == exact.negative }
    if (result.sign == .minus) != exact.negative { return false }
    let magnitude = result.magnitude
    if magnitude == 0 {
        // At most half the smallest subnormal; the tie goes to zero, which is even.
        return round2Compare(exact.digits, exact.scale, 1, -1075) <= 0
    }
    if magnitude == .infinity {
        // At least half way from the largest finite value to 2^1024; the tie goes up.
        return round2Compare(exact.digits, exact.scale, (1 << 54) - 1, 970) >= 0
    }
    let bits = magnitude.bitPattern
    let biased = Int(bits >> 52)
    let fractionBits = bits & ((1 << 52) - 1)
    let significand = biased == 0 ? fractionBits : fractionBits | 1 << 52
    let power = biased == 0 ? -1074 : biased - 1075
    let even = significand & 1 == 0
    let upper = round2Compare(exact.digits, exact.scale, 2 * significand + 1, power - 1)
    let lower: Int
    if significand == 1 << 52, biased > 1 {
        lower = round2Compare(exact.digits, exact.scale, 4 * significand - 1, power - 2)
    } else {
        lower = round2Compare(exact.digits, exact.scale, 2 * significand - 1, power - 1)
    }
    if upper > 0 || lower < 0 { return false }
    if (upper == 0 || lower == 0) && !even { return false }
    return true
}

/// The exact decimal text of the midpoint above `value` (a positive finite double).
private func round2MidpointAbove(_ value: Double) -> String {
    let bits = value.bitPattern
    let biased = Int(bits >> 52)
    let fractionBits = bits & ((1 << 52) - 1)
    let significand = biased == 0 ? fractionBits : fractionBits | 1 << 52
    let power = (biased == 0 ? -1074 : biased - 1075) - 1
    var big = Round2Big(2 * significand + 1)
    if power >= 0 {
        big.multiplyByPowerOfTwo(power)
        return String(decoding: big.decimalDigits.map { $0 + 48 }, as: UTF8.self)
    }
    // m × 2^-k = m × 5^k / 10^k.
    for _ in 0..<(-power) { big.multiply(by: 5) }
    let digits = String(decoding: big.decimalDigits.map { $0 + 48 }, as: UTF8.self)
    return digits + "e-\(-power)"
}

// MARK: - D3 cases

/// A positive integer written in decimal, minus one.
private func round2Decrement(_ digits: String) -> String {
    var bytes = Array(digits.utf8)
    var index = bytes.count - 1
    while bytes[index] == 0x30 {
        bytes[index] = 0x39
        index -= 1
    }
    bytes[index] -= 1
    if bytes.count > 1, bytes[0] == 0x30 { bytes.removeFirst() }
    return String(decoding: bytes, as: UTF8.self)
}

private func round2RoundingCases() -> [(text: String, hard: Bool)] {
    var cases: [(String, Bool)] = []
    let zeros20k = String(repeating: "0", count: 17_000)
    let nines20k = String(repeating: "9", count: 17_000)
    // Lengths around Double(String)'s limit.
    for length in [16_383, 16_384, 16_385] {
        cases.append(("1." + String(repeating: "0", count: length - 3) + "5", false))
        cases.append(("0." + String(repeating: "3", count: length - 2), false))
        cases.append((String(repeating: "1", count: 300) + "." + String(repeating: "7", count: length - 301), false))
    }
    // All the significance in the tail, after 20,000 zeros.
    cases.append(("0." + zeros20k + "1234e17010", true))
    cases.append(("0." + zeros20k + "1234", false))
    cases.append(("0." + zeros20k + "4940656458412465441765687928682213723651e20323", true))
    // All of it in the head.
    cases.append(("1.234" + String(repeating: "5", count: 20_000) + "e-5", true))
    cases.append(("1234" + String(repeating: "5", count: 20_000), false))
    // Nines that carry.
    cases.append(("0." + nines20k, true))
    cases.append(("9." + nines20k + "e-1", true))
    cases.append(("1.7976931348623157" + nines20k + "e308", true))
    cases.append(("2.2250738585072013" + nines20k + "e-308", true))
    // A long significand with an exponent that moves the point back.
    cases.append(("1" + String(repeating: "2", count: 20_000) + "e-20000", true))
    cases.append(("3" + zeros20k + "e-17000", true))
    cases.append(("0." + zeros20k + "3e17001", true))
    // Midpoints: exactly (ties to even), a hair above (sticky digit), a hair below.
    var random = Round2TrapRandom(state: 0x4433_0001)
    var doubles: [Double] = [
        1, 0.1, 1e23, 9007199254740992, .leastNonzeroMagnitude, .leastNonzeroMagnitude * 3, Double.leastNormalMagnitude.nextDown,
        .leastNormalMagnitude, .greatestFiniteMagnitude.nextDown, 5e-324 * 1234567, 2.2250738585072014e-308 * 2,
    ]
    for _ in 0..<8 {
        let value = Double(bitPattern: random.next() >> 1)
        if value.isFinite, value > 0 { doubles.append(value) }
    }
    for value in doubles {
        let midpoint = round2MidpointAbove(value)
        let (mantissa, exponent) = midpoint.contains("e") ? (String(midpoint.split(separator: "e")[0]), "e" + midpoint.split(separator: "e")[1]) : (midpoint, "")
        cases.append((mantissa + exponent, true))
        cases.append((mantissa + "." + zeros20k + "1" + exponent, true))
        cases.append((round2Decrement(mantissa) + "." + nines20k + exponent, true))
    }
    // Overflow decided by the sticky digit alone: the midpoint between the largest finite value
    // and 2^1024, exactly (ties up, to infinity) and a hair below (the largest value).
    let overflow = round2MidpointAbove(.greatestFiniteMagnitude)
    cases.append((overflow, true))
    cases.append((round2Decrement(overflow) + "." + nines20k, true))
    cases.append((overflow + "." + zeros20k + "1", true))
    // Underflow decided by the sticky digit: half the smallest subnormal is a tie (to zero).
    let underflow = round2MidpointAbove(0) // 2^-1075, the midpoint between 0 and the smallest
    cases.append((underflow, true))
    let underflowMantissa = String(underflow.split(separator: "e")[0])
    let underflowExponent = "e" + underflow.split(separator: "e")[1]
    cases.append((underflowMantissa + "." + zeros20k + "1" + underflowExponent, true))
    // Zeros, and the sign of zero.
    cases.append(("-0." + zeros20k, false))
    cases.append(("0." + zeros20k, false))
    cases.append(("-0." + zeros20k + "1", false))
    cases.append(("-" + "0." + zeros20k + "1e-400", false))
    // Negative versions of everything so far.
    cases += cases.filter { !$0.0.hasPrefix("-") }.map { ("-" + $0.0, $0.1) }
    // Four megabytes: zeros after the point, then a digit, with an exponent that brings it back.
    let fourMiB = 4 * 1024 * 1024
    cases.append(("0." + String(repeating: "0", count: fourMiB) + "5e\(fourMiB + 1)", false))
    cases.append((String(repeating: "8", count: fourMiB) + "e-\(fourMiB - 1)", false))
    return cases
}

/// What differs from the oracles; empty when every case is right.
private func round2RoundingProblems(exact: Bool) -> [String] {
    var problems: [String] = []
    for (text, hard) in round2RoundingCases() {
        let label = text.count > 60 ? String(text.prefix(30)) + "…(\(text.utf8.count))…" + String(text.suffix(20)) : text
        guard let number = JSONNumber(lexeme: text) else {
            problems.append("\(label): not a valid lexeme")
            continue
        }
        let value = number.doubleValue
        let oracle = round2Strtod(text)
        if value.bitPattern != oracle.bitPattern { problems.append("\(label): doubleValue \(value), strtod \(oracle)") }
        // The exact oracle on the positive hard cases (the negative ones mirror them).
        if exact, hard, !text.hasPrefix("-"), text.utf8.count < 100_000, !round2IsCorrectlyRounded(text, value) {
            problems.append("\(label): \(value) is not the correctly rounded value")
        }
        // Double(json:) agrees, or refuses what is out of range.
        let decoded = try? Double(json: .number(number))
        if oracle.isFinite ? decoded?.bitPattern != oracle.bitPattern : decoded != nil {
            problems.append("\(label): Double(json:) \(String(describing: decoded))")
        }
    }
    return problems
}

// MARK: - Fuzz

/// Random and damaged documents through the parser; returns how many were parsed.
private func round2ParseFuzz(_ count: Int, seed: UInt64) -> Int {
    var random = Round2TrapRandom(state: seed)
    let pieces = [
        "{", "}", "[", "]", ":", ",", "\"", "\\", "\\u", "\\u00", "\\uD800", "\\uDC00", "\\uD83D\\uDE00", "0", "-", "1", "e", "E", "+", ".",
        "9", "true", "false", "null", " ", "\n", "\t", "a", "\u{E9}", "\u{1F600}", "\u{0}", "\u{1F}", "\u{7F}", "\u{FEFF}", "1e999999999999999999999",
    ]
    var parsed = 0
    for iteration in 0..<count {
        var bytes: [UInt8]
        switch iteration % 4 {
        case 0:
            // Raw bytes, short: lengths 0 to 17 straddle the eight-byte fast paths.
            bytes = (0..<Int.random(in: 0...17, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
        case 1:
            // Tokens glued together.
            bytes = Array((0..<Int.random(in: 0...12, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined().utf8)
        case 2:
            // A string that ends exactly at the end of input, with an escape near an 8-byte edge.
            let filler = String(repeating: "x", count: Int.random(in: 0...17, using: &random))
            let escape = ["\\n", "\\u0041", "\\\"", "\\", "\\u00", "\u{E9}", "\""].randomElement(using: &random)!
            let tail = String(repeating: "y", count: Int.random(in: 0...9, using: &random))
            bytes = Array(("\"" + filler + escape + tail + (Bool.random(using: &random) ? "\"" : "")).utf8)
        default:
            // A valid document, damaged.
            var text = Array(#"{"a":[1,-2.5e3,"sé\n",true,null,{"b":{}}],"c":"\#(String(repeating: "z", count: Int.random(in: 0...20, using: &random)))"}"#.utf8)
            for _ in 0..<Int.random(in: 1...3, using: &random) where !text.isEmpty {
                let position = Int.random(in: 0..<text.count, using: &random)
                switch Int.random(in: 0..<4, using: &random) {
                case 0: text.remove(at: position)
                case 1: text.insert(UInt8.random(in: 0...255, using: &random), at: position)
                case 2: text[position] = UInt8.random(in: 0...255, using: &random)
                default: text.removeSubrange(position...)
                }
            }
            bytes = text
        }
        let options = iteration % 5 == 0 ? JSONParseOptions(maxDepth: Int.random(in: -1...3, using: &random), maxNodes: Int.random(in: -1...5, using: &random), rejectDuplicateKeys: false) : .default
        if let value = try? JSON.parse(bytes, options: options) {
            parsed += 1
            // What parses writes and parses back to the same value.
            if let again = try? JSON.parse(value.description, options: JSONParseOptions(maxDepth: 256, maxNodes: .max)), again != value {
                fatalError("written and read back differently: \(bytes)")
            }
        }
    }
    return parsed
}

/// Random patterns through the compiler and the matcher; returns how many compiled.
private func round2PatternFuzz(_ count: Int, seed: UInt64) -> Int {
    var random = Round2TrapRandom(state: seed)
    let pieces = [
        "a", "b", "\\", "[", "]", "(", ")", "{", "}", ",", "-", "^", "$", ".", "*", "+", "?", "|", "0", "1", "9", "u", "x", "p", "P", "c", "d",
        "w", "s", "b", "B", "k", "n", "?:", "?=", "?!", "?<", "?<=", ">", "=", "!", "{1,", "{0}", "{2,1}", "{99999999999999999999}", "\\u{",
        "\\u{10FFFF}", "\\u{110000}", "\\uD83D", "\\uDE00", "\\p{", "\\p{L}", "\\p{gc=Lu}", "\\P{Nd}", "\\cJ", "\\c", "[^]", "[a-", "[z-a]",
        "\u{E9}", "\u{1F600}", "\u{0}", "\\0", "\\x4", "\\x41", "(?<n>", "\\k<n>", "{", "}", "]", "\\b", "\\B", "(?i)",
    ]
    let subjects = ["", "a", "ab", "aaaa", "b\u{E9}", "\u{1F600}x", "a\nb", String(repeating: "a", count: 40), "0123456789", "_ \t"]
    var compiled = 0
    var limits = JSONSchema.Limits()
    limits.maxPatternStates = 2000
    for _ in 0..<count {
        let pattern = (0..<Int.random(in: 0...8, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
        guard let schema = try? JSONSchema(["pattern": .string(pattern), "patternProperties": [pattern: ["type": "integer"]]], limits: limits) else {
            continue
        }
        compiled += 1
        for subject in subjects {
            _ = schema.validate(.string(subject))
            _ = schema.validate(.object([subject: "x"]))
        }
    }
    return compiled
}

/// Every prefix of patterns that use every construct: patterns that end abruptly.
private func round2AbruptPatterns() -> [String] {
    let full = [
        "^(?:a|[b-d\\u{10FFFF}]+?){1,3}\\p{gc=Lu}\\P{L}\\cJ\\x41\\u0041\\uD83D\\uDE00(?<name>x)\\b$", "[\\d-x]", "[^\\s\\S]", "a{2,}b{,3}",
        "(?=a)(?!b)(?<=c)(?<!d)\\k<name>\\1", "\\u{1F600}[\\u{0}-\\u{10FFFF}]", "(((((a)))))", "\\p{General_Category=Decimal_Number}",
    ]
    var result: [String] = []
    for pattern in full {
        let scalars = Array(pattern.unicodeScalars)
        for end in 0...scalars.count {
            var prefix = ""
            prefix.unicodeScalars.append(contentsOf: scalars[..<end])
            result.append(prefix)
        }
    }
    return result
}

/// Random schemas from keyword fragments, compiled and used; returns how many compiled.
private func round2SchemaFuzz(_ count: Int, seed: UInt64) -> Int {
    var random = Round2TrapRandom(state: seed)
    let numbers: [JSONValue] = [
        0, -1, 1, 3, 0.5, 2.5, .number(JSONNumber(lexeme: "1e9999999999999999999")!), .number(JSONNumber(lexeme: "-1e-9999999999999999999")!),
        .number(JSONNumber(lexeme: "18446744073709551616")!), .number(JSONNumber(lexeme: "1e-400")!), .number(JSONNumber(Int64.min)), .number(JSONNumber(Int64.max)),
        .number(JSONNumber(lexeme: "12345678901234567891")!),
    ]
    let keywords = [
        "type", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "pattern", "items",
        "prefixItems", "minItems", "maxItems", "uniqueItems", "contains", "minContains", "maxContains", "properties", "required",
        "additionalProperties", "patternProperties", "propertyNames", "minProperties", "maxProperties", "enum", "const", "allOf", "anyOf",
        "oneOf", "not", "if", "then", "else", "$ref", "$defs", "definitions", "dependencies", "dependentRequired", "dependentSchemas",
        "unevaluatedProperties", "format", "$id", "$schema", "$anchor", "description",
    ]
    func value(_ depth: Int) -> JSONValue {
        switch Int.random(in: 0..<10, using: &random) {
        case 0, 1: return numbers.randomElement(using: &random)!
        case 2: return .string(["integer", "number", "string", "#", "#/$defs/a", "#/items/0", "#/prefixItems/99999999999999999999", "#/properties/a", "^a", "["].randomElement(using: &random)!)
        case 3: return .bool(Bool.random(using: &random))
        case 4: return .array((0..<Int.random(in: 0...3, using: &random)).map { _ in depth > 0 ? schema(depth - 1) : .null })
        case 5: return ["a": depth > 0 ? schema(depth - 1) : true, "b": depth > 0 ? schema(depth - 1) : false]
        case 6: return [.string("a"), .string("b"), "integer"]
        default: return depth > 0 ? schema(depth - 1) : .null
        }
    }
    func schema(_ depth: Int) -> JSONValue {
        if Int.random(in: 0..<8, using: &random) == 0 { return .bool(Bool.random(using: &random)) }
        var object = JSONObject()
        for _ in 0..<Int.random(in: 0...4, using: &random) { object[keywords.randomElement(using: &random)!] = value(depth) }
        return .object(object)
    }
    let instances: [JSONValue] = [
        .null, true, 0, -1, 2.5, "a", "", [], [1, 1], ["a": 1], ["a": [1, "b"], "b": nil], .number(JSONNumber(lexeme: "1e9999999999999999999")!),
        .array(Array(repeating: 1, count: 30)), .string(String(repeating: "a", count: 300)),
    ]
    var compiled = 0
    for _ in 0..<count {
        guard let compiledSchema = try? JSONSchema(schema(3)) else { continue }
        compiled += 1
        for instance in instances { _ = compiledSchema.validate(instance) }
    }
    return compiled
}

/// Random number texts through every JSONNumber API and the decoders.
private func round2NumberFuzz(_ count: Int, seed: UInt64) {
    var random = Round2TrapRandom(state: seed)
    let divisors = ["1", "0.5", "7", "1e-9999999999999999999", "9999999999999999999"].map { try! JSONSchema(["multipleOf": .number(JSONNumber(lexeme: $0)!)]) }
    var previous = JSONNumber(0)
    for _ in 0..<count {
        var text = Bool.random(using: &random) ? "-" : ""
        let integer = Int.random(in: 0..<4, using: &random) == 0 ? "0" : String(Int.random(in: 1...9, using: &random)) + String(repeating: ["0", "9", "5"].randomElement(using: &random)!, count: Int.random(in: 0...30, using: &random))
        text += integer
        if Bool.random(using: &random) { text += "." + String(repeating: ["0", "9", "1"].randomElement(using: &random)!, count: Int.random(in: 1...40, using: &random)) }
        if Int.random(in: 0..<3, using: &random) != 0 {
            text += ["e", "E", "e+", "e-", "E-"].randomElement(using: &random)!
            text += String(repeating: "0", count: Int.random(in: 0...3, using: &random))
            text += ["0", "1", "308", "309", "324", "325", "400", "999999999999999999", "1000000000000000000", "4000000000000000000", "9223372036854775807", "9223372036854775808", "99999999999999999999999999"].randomElement(using: &random)!
        }
        let number = JSONNumber(lexeme: text)!
        _ = number == previous
        _ = number < previous
        _ = number.hashValue
        _ = number.isInteger
        _ = number.int64Value
        _ = number.intValue
        let double = number.doubleValue
        let oracle = round2Strtod(text)
        if double.bitPattern != oracle.bitPattern { fatalError("doubleValue of \(text): \(double), strtod \(oracle)") }
        _ = try? Double(json: .number(number))
        _ = try? Int(json: .number(number))
        _ = try? Int64(json: .number(number))
        _ = JSONValue.number(number).typeName
        _ = JSONValue.number(number).description
        for divisor in divisors { _ = divisor.validate(.number(number)) }
        previous = number
    }
}

/// Random values through the writer and back; returns how many round-tripped exactly.
private func round2WriterFuzz(_ count: Int, seed: UInt64) -> Int {
    var random = Round2TrapRandom(state: seed)
    let characters: [String] = ["a", "\"", "\\", "/", "\n", "\u{0}", "\u{1F}", "\u{7F}", "\u{E9}", "e\u{301}", "\u{2028}", "\u{FEFF}", "\u{1F600}", "\u{10FFFF}", "\u{FFFF}"]
    func scalar() -> JSONValue {
        switch Int.random(in: 0..<7, using: &random) {
        case 0: return .number(JSONNumber([Int64.min, Int64.max, 0, -1, Int64.random(in: .min ... .max, using: &random)].randomElement(using: &random)!))
        case 1:
            let double = [Double.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude, -.leastNormalMagnitude, -0.0, Double(bitPattern: random.next())].randomElement(using: &random)!
            return JSONValue(double)
        case 2: return .number(JSONNumber(lexeme: ["18446744073709551615", "-9223372036854775809", "1e400", "-0", "0.0", "1E-7"].randomElement(using: &random)!)!)
        case 3: return .bool(Bool.random(using: &random))
        case 4: return .null
        default: return .string((0..<Int.random(in: 0...17, using: &random)).map { _ in characters.randomElement(using: &random)! }.joined())
        }
    }
    func value(_ depth: Int) -> JSONValue {
        guard depth > 0, Bool.random(using: &random) else { return scalar() }
        if Bool.random(using: &random) { return .array((0..<Int.random(in: 0...4, using: &random)).map { _ in value(depth - 1) }) }
        return .object(JSONObject((0..<Int.random(in: 0...4, using: &random)).map { _ in ((0..<Int.random(in: 0...3, using: &random)).map { _ in characters.randomElement(using: &random)! }.joined(), value(depth - 1)) }))
    }
    var exact = 0
    for _ in 0..<count {
        let original = value(4)
        let text = original.description
        if let back = try? JSON.parse(text) {
            if back == original { exact += 1 } else if JSON.codec == .limb { fatalError("\(text) read back as \(back)") }
        } else if JSON.codec == .limb {
            fatalError("the writer wrote what the parser refuses: \(text)")
        }
    }
    return exact
}

// MARK: - Tests

@Suite struct Round2NoTrapTests {
    /// D3: every case against `strtod`, the hard ones also against the exact oracle.
    @Test func doubleValueIsCorrectlyRoundedAtAnyLength() async {
        let result = await #expect(processExitsWith: .success) {
            let problems = round2RoundingProblems(exact: false)
            if !problems.isEmpty { exit(3) }
        }
        guard result?.exitStatus == .exitCode(0) else { return }
        let problems = round2RoundingProblems(exact: true)
        #expect(problems.isEmpty, "\(problems)")
    }

    /// The exact oracle agrees with `strtod` on easy cases and catches a wrong answer.
    @Test func theExactOracleIsAnOracle() {
        #expect(round2IsCorrectlyRounded("0.1", 0.1))
        #expect(!round2IsCorrectlyRounded("0.1", 0.1.nextUp))
        #expect(round2IsCorrectlyRounded("1e23", 1e23))
        #expect(round2IsCorrectlyRounded("-0", -0.0) && !round2IsCorrectlyRounded("-0", 0.0))
        #expect(round2IsCorrectlyRounded("1e400", .infinity) && !round2IsCorrectlyRounded("1e308", .infinity))
        #expect(round2IsCorrectlyRounded("1e-400", 0))
        // 2^53 + 1 is a tie between 2^53 and 2^53 + 2: to even, 2^53.
        #expect(round2IsCorrectlyRounded("9007199254740993", 9007199254740992))
        #expect(!round2IsCorrectlyRounded("9007199254740993", 9007199254740994))
        #expect(round2MidpointAbove(1) == "100000000000000011102230246251565404236316680908203125e-53")
        #expect(round2Strtod("9007199254740993") == 9007199254740992)
    }

    @Test func randomAndDamagedDocumentsNeverTrapTheParser() async {
        await #expect(processExitsWith: .success) {
            let parsed = round2ParseFuzz(200_000 * round2Scale(), seed: 0x5041_5253)
            if parsed < 1000 { exit(3) }
        }
    }

    @Test func randomPatternsNeverTrapTheCompilerOrTheMatcher() async {
        await #expect(processExitsWith: .success) {
            let compiled = round2PatternFuzz(40_000 * round2Scale(), seed: 0x5041_5454)
            if compiled < 1000 { exit(3) }
            var limits = JSONSchema.Limits()
            limits.maxPatternStates = 2000
            for pattern in round2AbruptPatterns() {
                if let schema = try? JSONSchema(["pattern": .string(pattern)], limits: limits) {
                    _ = schema.validate("aAbB\u{1F600}x1\n")
                }
            }
        }
    }

    @Test func randomSchemasNeverTrapCompileOrValidate() async {
        await #expect(processExitsWith: .success) {
            let compiled = round2SchemaFuzz(20_000 * round2Scale(), seed: 0x5343_484D)
            if compiled < 1000 { exit(3) }
        }
    }

    @Test func randomNumberTextsNeverTrapAndDoubleValueIsStrtod() async {
        await #expect(processExitsWith: .success) {
            round2NumberFuzz(100_000 * round2Scale(), seed: 0x4E55_4D42)
        }
    }

    @Test func randomValuesRoundTripThroughTheWriter() async {
        await #expect(processExitsWith: .success) {
            let exact = round2WriterFuzz(30_000 * round2Scale(), seed: 0x5752_4954)
            if exact < 1000 { exit(3) }
        }
    }

    /// Specific inputs from the list of trap sites.
    @Test func edgeInputsFromTheTrapSiteList() async {
        await #expect(processExitsWith: .success) {
            // ExactDecimal from texts that are all zeros.
            for text in ["0", "-0", "0e0", "-0E-0", "0.0000", "-0.000e999999999999999999999", "0." + String(repeating: "0", count: 4 * 1024 * 1024) + "1"] {
                let number = JSONNumber(lexeme: text)!
                _ = (number.isInteger, number.int64Value, number.doubleValue, number.hashValue, number == 0)
            }
            // The resolver on pointers with huge or odd indices.
            for pointer in ["#/items/99999999999999999999", "#/prefixItems/-1", "#/prefixItems/01", "#/prefixItems/9223372036854775807", "#/prefixItems/0/", "#/$defs/~2", "#/$defs/%"] {
                _ = try? JSONSchema(["prefixItems": [true], "items": ["$ref": .string(pointer)], "$defs": ["a": true]])
                _ = try? JSONSchema(["$ref": .string(pointer), "prefixItems": [true], "items": true])
            }
            // The writer at the integer extremes.
            precondition(JSONValue.number(JSONNumber(Int64.min)).description == "-9223372036854775808")
            precondition(JSONValue.number(JSONNumber(lexeme: "18446744073709551615")!).description == "18446744073709551615")
            precondition(JSONValue(Double.greatestFiniteMagnitude).description == "1.7976931348623157e+308")
            precondition(JSONValue(-Double.leastNonzeroMagnitude).description == "-5e-324")
            // Every input of up to three bytes from a small alphabet.
            let alphabet: [UInt8] = [0x22, 0x5C, 0x75, 0x30, 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A, 0x2D, 0x65, 0x2E, 0x20, 0x80, 0xC3, 0xFF, 0x00]
            var inputs: [[UInt8]] = [[]]
            for a in alphabet {
                inputs.append([a])
                for b in alphabet {
                    inputs.append([a, b])
                    for c in alphabet { inputs.append([a, b, c]) }
                }
            }
            for input in inputs { _ = try? JSON.parse(input) }
        }
    }
}
#endif
