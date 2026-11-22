import LimbCore
import Testing


private struct Round2NumberRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `negative × digits × 10^scale`, with `digits` an integer without leading zeros ("" for zero).
private struct Round2Decimal {
    var negative: Bool
    var digits: String
    var scale: Int

    var isZero: Bool { digits.isEmpty }

    /// Reads a valid JSON number whose exponent fits an `Int` comfortably.
    init(_ text: String) {
        var chars = Substring(text)
        negative = chars.first == "-"
        if negative { chars = chars.dropFirst() }
        var mantissa = chars
        var exponent = 0
        if let e = chars.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = chars[..<e]
            exponent = Int(chars[chars.index(after: e)...])!
        }
        var integer = String(mantissa)
        var fractionLength = 0
        if let point = mantissa.firstIndex(of: ".") {
            integer = String(mantissa[..<point])
            let fraction = mantissa[mantissa.index(after: point)...]
            fractionLength = fraction.count
            integer += fraction
        }
        let stripped = integer.drop { $0 == "0" }
        digits = String(stripped)
        scale = exponent - fractionLength
        if digits.isEmpty {
            negative = false
            scale = 0
        }
    }

    /// The value as an integer string, if it is an integer.
    var integerText: String? {
        if isZero { return "0" }
        var text = digits
        var scale = self.scale
        while scale < 0 {
            guard text.last == "0" else { return nil }
            text.removeLast()
            scale += 1
        }
        guard scale < 2000 else { return nil }
        text += String(repeating: "0", count: scale)
        return (negative ? "-" : "") + text
    }

    static func compare(_ a: Round2Decimal, _ b: Round2Decimal) -> Int {
        let signA = a.isZero ? 0 : a.negative ? -1 : 1
        let signB = b.isZero ? 0 : b.negative ? -1 : 1
        if signA != signB { return signA < signB ? -1 : 1 }
        if signA == 0 { return 0 }
        let common = min(a.scale, b.scale)
        let left = a.digits + String(repeating: "0", count: a.scale - common)
        let right = b.digits + String(repeating: "0", count: b.scale - common)
        let magnitude: Int
        if left.count != right.count {
            magnitude = left.count < right.count ? -1 : 1
        } else if left == right {
            magnitude = 0
        } else {
            magnitude = left < right ? -1 : 1
        }
        return magnitude * signA
    }
}

/// Spellings of `digits × 10^scale` (digits without a sign, may have leading zeros stripped).
private func round2Spellings(digits: String, scale: Int, negative: Bool, _ random: inout Round2NumberRandom) -> [String] {
    let sign = negative ? "-" : ""
    var result: [String] = []
    func exponentText(_ value: Int) -> String {
        let letter = Bool.random(using: &random) ? "e" : "E"
        let plus = value >= 0 && Bool.random(using: &random) ? "+" : ""
        let zeros = String(repeating: "0", count: Int.random(in: 0...2, using: &random))
        return letter + (value < 0 ? "-" : plus) + zeros + String(value.magnitude)
    }
    // Plain decimal notation.
    if scale >= 0 {
        let plain = digits + String(repeating: "0", count: scale)
        result.append(sign + plain)
        result.append(sign + plain + "." + String(repeating: "0", count: Int.random(in: 1...3, using: &random)))
    } else {
        let padded = String(repeating: "0", count: max(0, -scale - digits.count + 1)) + digits
        let point = padded.index(padded.endIndex, offsetBy: scale)
        let text = padded[..<point] + "." + padded[point...]
        result.append(sign + text + String(repeating: "0", count: Int.random(in: 0...2, using: &random)))
    }
    // Exponent notation with the point in several places and trailing zeros added.
    for _ in 0..<4 {
        let zeros = Int.random(in: 0...2, using: &random)
        let mantissaDigits = digits + String(repeating: "0", count: zeros)
        let length = mantissaDigits.count
        let place = Int.random(in: 0...length, using: &random)
        let leading = place == 0 ? Int.random(in: 0...2, using: &random) : 0
        let mantissa: String
        if place == 0 {
            mantissa = "0." + String(repeating: "0", count: leading) + mantissaDigits
        } else if place == length {
            mantissa = mantissaDigits + (Bool.random(using: &random) ? "" : ".0")
        } else {
            let split = mantissaDigits.index(mantissaDigits.startIndex, offsetBy: place)
            mantissa = mantissaDigits[..<split] + "." + mantissaDigits[split...]
        }
        let exponent = scale - zeros + (length - place) + leading
        result.append(sign + mantissa + exponentText(exponent))
    }
    return result
}

private func number(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> JSONNumber {
    guard let value = JSONNumber(lexeme: text) else {
        Issue.record("not a valid number: \(text)", sourceLocation: sourceLocation)
        return 0
    }
    return value
}

@Suite struct Round2JSONNumberTests {
    // MARK: Equivalence, hashing and order on a generated set

    /// Every pair of a large set of numbers: `==` is the reference's equality, `<` its order,
    /// equal numbers hash alike, and exactly one of `<`, `==`, `>` holds.
    @Test func equalityHashingAndOrderAgreeWithArithmetic() {
        var random = Round2NumberRandom(state: 0x4A32_0001)
        let significands = [
            "1", "5", "9", "12", "123", "1001", "999999999999999999", "9007199254740993", "9223372036854775807",
            "9223372036854775808", "18446744073709551616", "1" + String(repeating: "0", count: 40) + "1",
        ]
        let scales = [-400, -19, 0, 1, 19, 300]
        var texts: [String] = []
        for significand in significands {
            for scale in scales {
                for negative in [false, true] {
                    texts += round2Spellings(digits: significand, scale: scale, negative: negative, &random).shuffled(using: &random).prefix(2)
                }
            }
        }
        texts += ["0", "-0", "0.0", "-0.0", "0e99999", "0E-99999", "-0e+0", "0.000e10", "1", "1.0", "1e0", "10e-1", "0.1e1", "100E-2"]

        // The numbers, in all three kinds of storage where the value allows it.
        var numbers: [(JSONNumber, Round2Decimal, String)] = texts.map { (number($0), Round2Decimal($0), "lexeme \($0)") }
        for value: Int64 in [0, 1, -1, 5, 12, 123, 1001, .max, .min, .max - 1, 999_999_999_999_999_999, -999_999_999_999_999_999, 9_007_199_254_740_993] {
            numbers.append((JSONNumber(value), Round2Decimal(String(value)), "Int64 \(value)"))
        }
        for value: Double in [0, -0.0, 1, -1, 0.1, 1.5, 1e-30, 1e19, 1e300, 1e-300, 5e-324, 9_007_199_254_740_992, 0x1p60, 0x1p63, 0x1p64, -0x1p63, 123.0, 1001, 1.7976931348623157e308] {
            guard let number = JSONNumber(value) else { continue }
            numbers.append((number, Round2Decimal(value.description), "Double \(value)"))
        }

        // Ranks by the reference order: equal values share a rank.
        let order = numbers.indices.sorted { Round2Decimal.compare(numbers[$0].1, numbers[$1].1) < 0 }
        var rank = [Int](repeating: 0, count: numbers.count)
        var current = 0
        for (position, index) in order.enumerated() {
            if position > 0, Round2Decimal.compare(numbers[order[position - 1]].1, numbers[index].1) != 0 { current += 1 }
            rank[index] = current
        }

        var problems: [String] = []
        for i in numbers.indices {
            let a = numbers[i].0
            for j in numbers.indices {
                let b = numbers[j].0
                let equal = a == b
                let less = a < b
                let greater = b < a
                if equal != (rank[i] == rank[j]) { problems.append("\(numbers[i].2) == \(numbers[j].2) is \(equal)") }
                if less != (rank[i] < rank[j]) { problems.append("\(numbers[i].2) < \(numbers[j].2) is \(less)") }
                if [equal, less, greater].filter({ $0 }).count != 1 { problems.append("trichotomy fails for \(numbers[i].2), \(numbers[j].2)") }
                if equal, a.hashValue != b.hashValue { problems.append("\(numbers[i].2) and \(numbers[j].2) are equal and hash differently") }
                if problems.count > 20 { break }
            }
            if problems.count > 20 { break }
        }
        #expect(problems.isEmpty, "\(problems)")
        // A set keeps one per value; a dictionary finds every spelling.
        let distinct = Set(numbers.map(\.0))
        #expect(distinct.count == current + 1)
        var byValue: [JSONNumber: Int] = [:]
        for (index, entry) in numbers.enumerated() where byValue[entry.0] == nil { byValue[entry.0] = rank[index] }
        for (index, entry) in numbers.enumerated() {
            #expect(byValue[entry.0] == rank[index], "\(entry.2)")
        }
        // The same through JSONValue, where numbers are inside containers.
        let values = Set(numbers.map { JSONValue.array([.number($0.0)]) })
        #expect(values.count == current + 1)
        // The set covered both sides of every boundary: many distinct values, many spellings each.
        #expect(current > 120 && numbers.count > 2 * current, "\(current + 1) values from \(numbers.count) numbers")
    }

    /// `isInteger`, `int64Value`, `intValue` and `typeName` agree with the reference for every
    /// spelling, including those next to the 64-bit limits.
    @Test func integerQueriesAreExact() {
        var random = Round2NumberRandom(state: 0x4A32_0002)
        var texts: [String] = []
        let significands = [
            "1", "9223372036854775807", "9223372036854775808", "9223372036854775806", "18446744073709551615",
            "18446744073709551616", "1000000000000000001", "10000000000000000001", "5", "25",
        ]
        for significand in significands {
            for scale in [-21, -20, -2, -1, 0, 1, 2, 18, 19, 20] {
                for negative in [false, true] {
                    texts += round2Spellings(digits: significand, scale: scale, negative: negative, &random)
                }
            }
        }
        texts += [
            "0.99999999999999999999", "1.0000000000000000001", "1e-400", "-1e-400", "9007199254740993.5", "1e400", "1E400",
            "-9223372036854775809", "-9223372036854775808.0", "-922337203685477580.8e1", "9223372036854775807.0000000000000000000001",
        ]
        var problems: [String] = []
        for text in texts {
            let value = number(text)
            let reference = Round2Decimal(text)
            let integer = reference.integerText
            let expected64 = integer.flatMap { Int64($0) }
            if value.isInteger != (integer != nil || (reference.scale > 0 && !reference.isZero)) {
                problems.append("\(text): isInteger \(value.isInteger)")
            }
            if value.int64Value != expected64 { problems.append("\(text): int64Value \(String(describing: value.int64Value)), expected \(String(describing: expected64))") }
            if value.intValue != expected64.flatMap({ Int(exactly: $0) }) { problems.append("\(text): intValue") }
            let typeName = JSONValue.number(value).typeName
            if typeName != (value.isInteger ? "integer" : "number") { problems.append("\(text): typeName \(typeName)") }
            // `Int(json:)` follows the same answers.
            let decoded = try? Int(json: .number(value))
            if decoded != expected64.flatMap({ Int(exactly: $0) }) { problems.append("\(text): Int(json:) \(String(describing: decoded))") }
            if problems.count > 20 { break }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func equivalentAndDistinctDecimalRepresentations() throws {
        let a = number("100000000000000000000"), b = number("1e20"), c = number("100000000000000000001")
        #expect(a == b)
        #expect(b != c)
        #expect(a != c)
        #expect(Set([a, c, b]).count == 2)
        #expect(number("1.0000000000000000001") != 1)
        #expect(number("1e-400") != 0)
        #expect(number("1e-400") > 0)
        #expect(number("-1e-400") < 0)
        #expect(number("1E400") == number("1e400"))
        #expect(number("1e400") == number("10e399"))
        #expect(number("1E400") == number("10e399"))
        let below = number("-9223372036854775809"), atMin = number("-9223372036854775808.0")
        #expect(below != atMin)
        #expect(below < atMin)
        #expect(atMin == JSONNumber(Int64.min))
        #expect(atMin.hashValue == JSONNumber(Int64.min).hashValue)
        #expect(Set([atMin]).contains(JSONNumber(Int64.min)))
        #expect(!Set([atMin]).contains(below))
        for text in ["0.99999999999999999999", "1.0000000000000000001", "1e-400", "9007199254740993.5"] {
            #expect(number(text).int64Value == nil, "\(text)")
            #expect(!number(text).isInteger, "\(text)")
            #expect(throws: JSONDecodingError.self, "\(text)") { try Int(json: .number(number(text))) }
            #expect(throws: JSONDecodingError.self, "\(text)") { try Int64(json: .number(number(text))) }
        }
        #expect(number("1e400").isInteger)
        #expect(number("1e400").int64Value == nil)
        // A number made from a Double is the decimal it is written as.
        #expect(JSONNumber(Double(1 << 60))!.int64Value == 1_152_921_504_606_847_000)
        #expect(JSONNumber(Double(1 << 60))! == number("1152921504606847000"))
        #expect(JSONNumber(Double(1 << 60))! != JSONNumber(Int64(1 << 60)))
        #expect(JSONNumber(Double(0.1))! == number("0.1"))
        #expect(JSONNumber(Double(0.1))! != number("0.1000000000000000055511151231257827021181583404541015625"))
        #expect(JSONNumber(Double(1e23))! == number("1e23"))
        #expect(JSONNumber(Double(1e23))! == number("100000000000000000000000"))
        #expect(JSONNumber(Double(-0.0))! == 0)
        #expect(JSONNumber(Double(-0.0))!.hashValue == JSONNumber(0).hashValue)
        #expect(JSONNumber(Double(9_007_199_254_740_991.0))!.int64Value == 9_007_199_254_740_991)
        #expect(JSONNumber(Double(4_503_599_627_370_495.5))!.int64Value == nil)
        #expect(JSONNumber(Double(4_503_599_627_370_495.5))!.isInteger == false)
        #expect(JSONNumber(Double(0x1p63))!.int64Value == nil)
        #expect(JSONNumber(Double(-0x1p63))!.int64Value == nil, "written -9.223372036854776e+18, below Int64.min")
        #expect(JSONNumber(Double.nan) == nil)
        #expect(JSONNumber(Double.infinity) == nil)
    }

    /// `doubleValue` is the correctly rounded value of the text, ±∞ and ±0 out of range.
    @Test func doubleValueIsStillRight() {
        let cases: [(String, Double)] = [
            ("0.1", 0.1), ("1e400", .infinity), ("-1e400", -.infinity), ("1e-400", 0), ("1.7976931348623157e308", .greatestFiniteMagnitude),
            ("1.7976931348623159e308", .infinity), ("4.9e-324", .leastNonzeroMagnitude), ("2.4703282292062328e-324", .leastNonzeroMagnitude),
            ("9007199254740993", 9_007_199_254_740_992), ("9007199254740993.0000000000000000001", 9_007_199_254_740_994),
            ("1" + String(repeating: "0", count: 400) + "e-400", 1), ("0." + String(repeating: "0", count: 400) + "1e401", 1),
            ("1e99999999999999999999999999", .infinity), ("-0", -0.0),
        ]
        for (text, expected) in cases {
            let value = number(text).doubleValue
            #expect(value == expected && value.sign == expected.sign, "\(text): \(value)")
        }
        #expect(number("-1e-400").doubleValue.sign == .minus)
        #expect(JSONNumber(Int64.max).doubleValue == 0x1p63)
        #expect(JSONNumber(Double(0.1))!.doubleValue == 0.1)
    }

    /// What the writer writes reads back as the same number with the same text.
    @Test func numbersRoundTripThroughTheWriter() throws {
        var random = Round2NumberRandom(state: 0x4A32_0003)
        var numbers: [JSONNumber] = [JSONNumber(Int64.min), JSONNumber(Int64.max), 0]
        for _ in 0..<500 {
            numbers.append(JSONNumber(Int64.random(in: .min ... .max, using: &random)))
            let double = Double(bitPattern: random.next())
            if let number = JSONNumber(double) { numbers.append(number) }
            let digits = String(random.next() % 1_000_000_007)
            numbers += round2Spellings(digits: digits, scale: Int.random(in: -500...500, using: &random), negative: Bool.random(using: &random), &random).map { number($0) }
        }
        for value in numbers {
            let text = JSONValue.number(value).description
            #expect(JSONNumber(lexeme: text) == value, "\(text)")
            #expect(JSONNumber(lexeme: text)?.description == text)
            #if !FoundationJSON
            let parsed = try JSON.parse(text)
            #expect(parsed == .number(value), "\(text)")
            #expect(parsed.description == text)
            #endif
        }
    }

    // MARK: The exponent clamp

    /// Right below the clamp everything is still exact.
    @Test func exponentsBelowTheClampAreExact() {
        #expect(number("1e999999999999999999") == number("10e999999999999999998"))
        #expect(number("1e999999999999999999") == number("0.1e1000000000000000000"))
        #expect(number("1e999999999999999998") < number("1e999999999999999999"))
        #expect(number("2e999999999999999998") > number("1.9999999999999999999e999999999999999998"))
        #expect(number("1e-999999999999999999") == number("10e-1000000000000000000"))
        #expect(number("1e-999999999999999999") > number("1e-1000000000000000000"))
        #expect(number("-1e999999999999999999") < number("-1e999999999999999998"))
        #expect(number("1e999999999999999999").isInteger)
        #expect(!number("1e-999999999999999999").isInteger)
        #expect(number("1e999999999999999999").hashValue == number("10e999999999999999998").hashValue)
    }

    @Test func theClampIsMonotone() {
        // Documented: values beyond the clamp merge.
        #expect(number("1e1000000000000000001") == number("1e1000000000000000002"))
        #expect(number("1e1000000000000000001") == number("1e" + String(repeating: "1", count: 100)))
        #expect(number("1e1000000000000000001").hashValue == number("1e1000000000000000002").hashValue)
        // 10e(10^18) and 1e(10^18 + 1) are the same number.
        #expect(number("10e1000000000000000000") == number("1e1000000000000000001"))
        #expect(number("10e1000000000000000000").hashValue == number("1e1000000000000000001").hashValue)
        // 1e(10^18 + 5) is not smaller than 10e(10^18) = 1e(10^18 + 1).
        #expect(!(number("1e1000000000000000005") < number("10e1000000000000000000")))
        // 1e-(10^18 + 5) is not larger than 0.01e-(10^18) = 1e-(10^18 + 2).
        #expect(!(number("1e-1000000000000000005") > number("0.01e-1000000000000000000")))
    }

    @Test func longExponentsDoNotTrap() async {
        await #expect(processExitsWith: .success) {
            precondition(JSONNumber(lexeme: "1e9999999999999999999")!.isInteger)
        }
        await #expect(processExitsWith: .success) {
            precondition(JSONNumber(lexeme: "1e-9999999999999999999")! != JSONNumber(0))
            precondition(JSONNumber(lexeme: "1e-9999999999999999999")! > JSONNumber(0))
        }
        await #expect(processExitsWith: .success) {
            precondition(JSONNumber(lexeme: "2E+999999999999999999999")!.hashValue == JSONNumber(lexeme: "1e1000000000000000001")!.hashValue)
        }
        await #expect(processExitsWith: .success) {
            _ = try? Int(json: JSON.parse("1e9999999999999999999"))
        }
        await #expect(processExitsWith: .success) {
            let schema = try! JSONSchema(["type": "integer"])
            precondition(schema.validate(.number(JSONNumber(lexeme: "1e9999999999999999999")!)) == nil)
        }
    }

    // MARK: Cost

    /// Comparing and hashing are linear in the length of the text, and nothing is allocated by
    /// the size of an exponent.
    @Test func longNumbersAndHugeExponentsAreCheap() {
        let clock = ContinuousClock()
        let long = String(repeating: "7", count: 50_000)
        let a = number(long + "1"), b = number(long + "2"), c = number(long + "1.000")
        let hugeExponent = number("1e1" + String(repeating: "0", count: 200_000))
        let elapsed = clock.measure {
            for _ in 0..<5 {
                #expect(a != b)
                #expect(a < b)
                #expect(a == c)
                #expect(a.hashValue == c.hashValue)
                #expect(hugeExponent > a)
                #expect(hugeExponent.isInteger)
                #expect(hugeExponent.int64Value == nil)
                #expect(number("1e-1000000000000000000") > 0)
            }
            _ = hugeExponent.hashValue
        }
        #expect(elapsed < .seconds(10), "\(elapsed)")
        // Five hundred distinct five-hundred-digit numbers in a set.
        let many = (0..<500).map { number(String(repeating: "3", count: 500) + String($0) + "e-500") }
        let setTime = clock.measure { #expect(Set(many).count == 500) }
        #expect(setTime < .seconds(5), "\(setTime)")
    }

    // MARK: Literals

    @Test func floatLiteralsThatAreFiniteWork() {
        let value: JSONNumber = 2.5
        #expect(value == number("2.5"))
        let json: JSONValue = 1e300
        #expect(json == .number(number("1e300")))
        #expect(json.description == "1e+300")
    }

    @Test func aNonFiniteFloatLiteralTraps() async {
        await #expect(processExitsWith: .failure) {
            let infinity = Double.infinity
            _ = JSONNumber(floatLiteral: infinity)
        }
        await #expect(processExitsWith: .failure) {
            _ = JSONNumber(floatLiteral: Double.nan)
        }
        await #expect(processExitsWith: .failure) {
            _ = JSONValue(floatLiteral: -Double.infinity)
        }
    }

    /// JSONValue's own Double initializer still maps non-finite values to null.
    @Test func jsonValueFromANonFiniteDoubleIsNull() {
        #expect(JSONValue(Double.nan) == .null)
        #expect(JSONValue(Double.infinity) == .null)
        var writer = JSONWriter()
        writer.beginArray()
        writer.write(Double.nan)
        writer.write(-Double.infinity)
        writer.endArray()
        #expect(String(decoding: writer.bytes, as: UTF8.self) == "[null,null]")
    }
}
