import LimbCore
import Testing


private struct Round2MiscRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - J10

@Suite struct Round2DictionaryNormalizationTests {
    private func failure<T: JSONDecodable>(_ type: T.Type, _ value: JSONValue) -> JSONDecodingError? {
        do {
            _ = try T(json: value)
            return nil
        } catch {
            return error
        }
    }

    private let message = "the object has another member whose name differs from this one only in Unicode normalization"

    @Test func keysThatDifferOnlyInNormalizationAreRefused() throws {
        let pairs: [(String, String)] = [("caf\u{E9}", "cafe\u{301}"), ("\u{212B}", "\u{C5}"), ("\u{C5}", "A\u{30A}"), ("\u{AC00}", "\u{1100}\u{1161}")]
        for (first, second) in pairs {
            for (a, b) in [(first, second), (second, first)] {
                let members: [(String, JSONValue)] = [(a, 1), ("plain", 2), (b, 3)]
                let object = JSONValue.object(JSONObject(members))
                let error = failure([String: Int].self, object)
                #expect(error == JSONDecodingError(message, path: [b]), "\(a.debugDescription) then \(b.debugDescription)")
                #expect(error?.description == "\(b): \(message)")
            }
        }
        // Three spellings of Å: refused at the second.
        let three = JSONValue.object(JSONObject([("\u{212B}", 1), ("\u{C5}", 2), ("A\u{30A}", 3)]))
        #expect(failure([String: Int].self, three)?.path == ["\u{C5}"])
        // Nested, and inside arrays: the path leads to it.
        let nested: JSONValue = ["outer": .object(JSONObject([("caf\u{E9}", 1), ("cafe\u{301}", 2)]))]
        #expect(failure([String: [String: Int]].self, nested)?.path == ["outer", "cafe\u{301}"])
        let inArray: JSONValue = [.object(JSONObject([("x", 1)])), .object(JSONObject([("caf\u{E9}", 1), ("cafe\u{301}", 2)]))]
        #expect(failure([[String: Int]].self, inArray)?.path == ["[1]", "cafe\u{301}"])
        // Values that are any JSON too.
        #expect(failure([String: JSONValue].self, .object(JSONObject([("caf\u{E9}", nil), ("cafe\u{301}", nil)]))) != nil)
        // Many distinct keys, none equivalent: decodes, every entry kept.
        let many = JSONObject((0..<500).map { ("k\($0)", JSONValue($0)) } + [("caf\u{E9}", 500)])
        let decoded = try [String: Int](json: .object(many))
        #expect(decoded.count == 501)
        #expect(decoded["k499"] == 499 && decoded["cafe\u{301}"] == 500)
    }

    /// From bytes, with either codec: two members for the parser, an error for the dictionary.
    @Test func fromTheWire() throws {
        let text = "{\"caf\u{E9}\":1,\"cafe\u{301}\":2}"
        let value = try JSON.parse(text)
        #expect(value.objectValue?.count == 2)
        #expect(failure([String: Int].self, value)?.path == [value.objectValue!.last!.key])
        // A value error before the collision is reported as the value error.
        let typed = try JSON.parse("{\"caf\u{E9}\":1,\"cafe\u{301}\":\"x\"}")
        #expect(failure([String: Int].self, typed)?.reason == "expected integer, got string")
    }
}

// MARK: - J11

@Suite struct Round2Base64Tests {
    /// The four canonical spellings of some bytes.
    private func spellings(_ bytes: [UInt8]) -> Set<String> {
        let padded = Base64.encode(bytes)
        let unpadded = String(padded.filter { $0 != "=" })
        func urlSafe(_ text: String) -> String {
            String(text.map { $0 == "+" ? "-" : $0 == "/" ? "_" : $0 })
        }
        #expect(Base64.encode(bytes, urlSafe: true) == urlSafe(unpadded))
        return [padded, unpadded, urlSafe(padded), urlSafe(unpadded)]
    }

    @Test func malformedBase64IsRejected() {
        for text in ["=", "==", "QUJD=", "QUJD==", "QQ=", "QQ===", "QR==", "QR", "Q", "Q===", "QUI==", "QUJ", "+-==", "+/-_", "a+b_",
            "QQ==QQ==", "QQ== ", " QQ==", "QQ\n==", "QU JD", "QUJD\u{0}", "QUJ\u{E9}", "Q=Q=", "=QQQ"] as [String]
        {
            #expect(Base64.decode(text) == nil, "\(text.debugDescription)")
        }
        #expect(Base64.decode("") == [])
        #expect(Base64.decode("QQ==") == [0x41])
        #expect(Base64.decode("QQ") == [0x41])
        #expect(Base64.decode("QUI") == [0x41, 0x42])
        #expect(Base64.decode("QUI=") == [0x41, 0x42])
        #expect(Base64.decode("QUJD") == [0x41, 0x42, 0x43])
        #expect(Base64.decode("+/+/") == [0xFB, 0xFF, 0xBF])
        #expect(Base64.decode("-_-_") == [0xFB, 0xFF, 0xBF])
        #expect(Base64.decode("+_-/") == nil)
    }

    /// Every string up to five characters over an alphabet that has both alphabets' special
    /// characters, padding and characters whose low bits are and are not zero: a string decodes
    /// exactly when it is one of the canonical spellings of what it decodes to.
    @Test func exactlyTheCanonicalSpellingsDecode() {
        let alphabet: [Character] = ["A", "Q", "B", "g", "w", "+", "/", "-", "_", "="]
        var accepted = 0
        var texts: [String] = [""]
        var frontier: [String] = [""]
        for _ in 0..<5 {
            frontier = frontier.flatMap { prefix in alphabet.map { prefix + String($0) } }
            texts += frontier
        }
        var problems: [String] = []
        for text in texts {
            let decoded = Base64.decode(text)
            if let decoded {
                accepted += 1
                if !spellings(decoded).contains(text) { problems.append("\(text) decodes to \(decoded) but is not canonical") }
            }
            if problems.count > 10 { break }
        }
        #expect(problems.isEmpty, "\(problems)")
        #expect(accepted > 1000, "\(accepted) of \(texts.count) accepted")
    }

    /// Every byte string up to two bytes, and random longer ones: all four canonical spellings
    /// decode to the bytes.
    @Test func everyCanonicalSpellingDecodes() {
        var inputs: [[UInt8]] = [[]]
        for a in 0...255 {
            inputs.append([UInt8(a)])
            for b in 0...255 { inputs.append([UInt8(a), UInt8(b)]) }
        }
        var random = Round2MiscRandom(state: 0x4A31_3131)
        for _ in 0..<2000 {
            inputs.append((0..<Int.random(in: 3...40, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) })
        }
        var problems: [String] = []
        for bytes in inputs {
            for spelling in spellings(bytes) where Base64.decode(spelling) != bytes {
                problems.append("\(spelling) does not decode to \(bytes)")
            }
            if problems.count > 10 { break }
        }
        #expect(problems.isEmpty, "\(problems)")
    }
}

// MARK: - J14: where invalid UTF-8 is

/// The offset of the first byte of the first ill-formed sequence (Unicode Table 3-7), or nil.
private func round2FirstInvalidUTF8(_ bytes: [UInt8]) -> Int? {
    var index = 0
    while index < bytes.count {
        let lead = bytes[index]
        if lead < 0x80 {
            index += 1
            continue
        }
        let length: Int
        var low: UInt8 = 0x80
        var high: UInt8 = 0xBF
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0: length = 3; low = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED: length = 3; high = 0x9F
        case 0xF0: length = 4; low = 0x90
        case 0xF1...0xF3: length = 4
        case 0xF4: length = 4; high = 0x8F
        default: return index
        }
        guard index + length <= bytes.count else { return index }
        guard bytes[index + 1] >= low, bytes[index + 1] <= high else { return index }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) { return index }
        index += length
    }
    return nil
}

/// "kind@offset" for a parse that fails, "parsed" for one that does not.
private func round2Failure(_ bytes: [UInt8], span: Bool = false) -> String {
    do {
        _ = span ? try JSON.parse(bytes.span) : try JSON.parse(bytes)
        return "parsed"
    } catch {
        return "\(error.kind)@\(error.offset)"
    }
}

@Suite struct Round2InvalidUTF8OffsetTests {
    static let sequences: [[UInt8]] = [
        // Continuation bytes without a lead.
        [0x80], [0xBF], [0x80, 0x80],
        // Overlong encodings.
        [0xC0, 0x80], [0xC0, 0xAF], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF], [0xF0, 0x80, 0x80, 0x80], [0xF0, 0x8F, 0xBF, 0xBF],
        // Surrogates, alone and paired (CESU-8).
        [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80],
        // Beyond U+10FFFF, and bytes that never occur.
        [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80], [0xFC, 0x84, 0x80, 0x80, 0x80, 0x80], [0xFE], [0xFF],
        // Truncated: a lead with too few continuations, followed by ASCII.
        [0xC3], [0xE2, 0x82], [0xF0, 0x9F, 0x98], [0xC3, 0x28], [0xE2, 0x28, 0xA1], [0xF0, 0x9F, 0x41, 0x41],
        // A valid character followed by an extra continuation.
        [0xC3, 0xA9, 0xA9],
    ]

    /// Every sequence in every kind of place, after prefixes of different lengths (ASCII and
    /// multi-byte): the offset is that of the first byte of the ill-formed sequence.
    @Test(arguments: sequences)
    func theOffsetIsTheFirstInvalidByte(_ sequence: [UInt8]) {
        let prefixes: [[UInt8]] = [[], Array("a".utf8), Array("\u{E9}".utf8), Array("\u{1F600}x".utf8), Array(String(repeating: "\u{20AC}", count: 7).utf8)]
        var documents: [[UInt8]] = []
        for prefix in prefixes {
            documents.append(sequence)
            documents.append([0x22] + prefix + sequence + [0x22])
            documents.append(Array("[1,\"".utf8) + prefix + sequence + Array("\"]".utf8))
            documents.append(Array("{\"".utf8) + prefix + sequence + Array("\":1}".utf8))
            documents.append(Array("{\"k\":\"".utf8) + prefix + sequence + Array("\"}".utf8))
            documents.append(Array("[1,".utf8) + sequence + Array("2]".utf8))
            documents.append(Array("  ".utf8) + sequence + Array("1".utf8))
            documents.append(Array("[\"".utf8) + prefix + Array("\"]".utf8) + sequence)
            documents.append(Array("\"\\".utf8) + sequence + Array("\"".utf8))
            documents.append(Array("\"\\u00e9".utf8) + prefix + sequence)
            // The sequence cut short by the end of input.
            documents.append([0x22] + prefix + sequence.dropLast())
        }
        for document in documents {
            guard let expected = round2FirstInvalidUTF8(document) else { continue }
            do {
                let value = try JSON.parse(document)
                Issue.record("\(document) parsed to \(value)")
            } catch {
                #expect(error.kind == .invalidUTF8 && error.offset == expected, "\(document.map { String($0, radix: 16) }): \(error)")
                #expect(error.description == "input is not valid UTF-8 at byte \(expected)")
            }
            // The same through Span.
            #expect(round2Failure(document, span: true) == "invalidUTF8@\(expected)")
        }
    }

    /// UTF-8 is checked before anything else, in both codecs: an invalid byte after a syntax
    /// error is what is reported.
    @Test func utf8IsCheckedBeforeSyntax() {
        #expect(round2Failure([0x5B, 0x78, 0x2C, 0xFF]) == "invalidUTF8@3")
        #expect(round2Failure(Array("[1,2,3]   ".utf8) + [0x80]) == "invalidUTF8@10")
    }

    /// Random damage to valid documents full of multi-byte characters: the offset always
    /// agrees with the reference.
    @Test func randomDamageAgreesWithTheReference() {
        var random = Round2MiscRandom(state: 0x4A31_3134)
        let pieces = ["\u{E9}", "\u{20AC}", "\u{1F600}", "a", "\u{10FFFF}", "\u{7FF}", "\u{800}", "\u{FFFF}", "\u{10000}"]
        var checked = 0
        for _ in 0..<3000 {
            let text = (0..<Int.random(in: 1...8, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
            var bytes = Array("{\"\(text)\":[\"\(text)\"]}".utf8)
            for _ in 0..<Int.random(in: 1...2, using: &random) {
                let position = Int.random(in: 0..<bytes.count, using: &random)
                switch Int.random(in: 0..<3, using: &random) {
                case 0: bytes.remove(at: position)
                case 1: bytes.insert(UInt8.random(in: 0x80...0xFF, using: &random), at: position)
                default: bytes[position] = UInt8.random(in: 0x80...0xFF, using: &random)
                }
            }
            guard let expected = round2FirstInvalidUTF8(bytes) else { continue }
            checked += 1
            #expect(round2Failure(bytes) == "invalidUTF8@\(expected)", "\(bytes)")
        }
        #expect(checked > 1500)
    }
}

// MARK: - J14: null where a number is expected

@Suite struct Round2NullForANumberTests {
    @Test func theMessageNamesTheLikelyCause() throws {
        let hint = "(a Double that is NaN or infinite is written as null)"
        for schema: JSONValue in [["type": "number"], ["type": "integer"], ["type": ["number", "string"]], ["properties": ["x": ["type": "number"]]]] {
            let compiled = try JSONSchema(schema)
            let instance: JSONValue = schema["properties"] == nil ? .null : ["x": nil]
            let violation = compiled.validate(instance)
            #expect(violation?.reason.hasSuffix(hint) == true, "\(schema): \(String(describing: violation))")
        }
        // Not when a number is not among the expected types, nor when null is allowed.
        #expect(try JSONSchema(["type": "string"]).validate(.null)?.reason == "expected string, got null")
        #expect(try JSONSchema(["type": ["number", "null"]]).validate(.null) == nil)
        #expect(try JSONSchema(["type": "number"]).validate("x")?.reason.contains("NaN") == false)
    }
}
