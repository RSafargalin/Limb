import Foundation
import LimbCore
import Testing

// Tests for the codec switch (the package trait `FoundationJSON`).
//
// The first two suites hold in both builds: they pin what the rest of Limb relies on whichever
// codec is compiled in. Everything after `#if FoundationJSON` describes the fallback only — its
// documented differences from the default codec, and what must stay true on untrusted input.

// MARK: - Both builds

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

/// The stack handlers run on. `JSONSerialization` alone overflows it at about 512 nested objects.
private let handlerStack = 512 * 1024

private func nested(_ open: String, _ close: String, _ depth: Int, around core: String = "") -> String {
    String(repeating: open, count: depth) + core + String(repeating: close, count: depth)
}

/// A small deterministic generator, so that a failure can be reproduced from its iteration.
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

@Suite struct JSONCodecSelectionTests {
    @Test func codecMatchesTheBuild() {
        #if FoundationJSON
        #expect(JSON.codec == .foundation)
        #else
        #expect(JSON.codec == .limb)
        #endif
        #expect(JSON.Codec(rawValue: "limb") == .limb)
        #expect(JSON.Codec(rawValue: "foundation") == .foundation)
    }

    /// The constant is not just the same `#if` echoed back: it agrees with what the parser does.
    @Test func codecMatchesTheBehaviour() {
        let keepsNumberText = (try? JSON.parse("1E+2"))?.description == "1E+2"
        #expect(keepsNumberText == (JSON.codec == .limb))
        let acceptsTrailingComma = (try? JSON.parse("[1,]")) != nil
        #expect(acceptsTrailingComma == (JSON.codec == .foundation))
        let acceptsDuplicateKeys = (try? JSON.parse(#"{"a":1,"a":2}"#)) != nil
        #expect(acceptsDuplicateKeys == (JSON.codec == .foundation))
    }
}

/// The default `maxDepth` is 128, and a document that deep is an ordinary document.
@Suite struct JSONDepthLimitTests {
    @Test func nestingAtTheDefaultLimitIsAccepted() {
        #expect(throws: Never.self) { try JSON.parse(nested("[", "]", 128)) }
        #expect(throws: Never.self) { try JSON.parse(nested("{\"a\":", "}", 128, around: "1")) }
        #expect(throws: Never.self) { try JSON.parse(nested("[{\"a\":", "}]", 64, around: "1")) }
        #expect(throws: Never.self) { try JSON.parse(nested("{\"a\":[", "]}", 64, around: "1")) }
        #expect(throws: JSONParseError.self) { try JSON.parse(nested("[", "]", 129)) }
        #expect(throws: JSONParseError.self) { try JSON.parse(nested("{\"a\":", "}", 129, around: "1")) }
    }

    /// The same on the stack handlers run on.
    @Test func nestingAtTheDefaultLimitIsAcceptedOnAHandlerThread() {
        for text in [nested("[", "]", 128), nested("{\"a\":", "}", 128, around: "1"), nested("[{\"a\":", "}]", 64, around: "1")] {
            let bytes = Array(text.utf8)
            let parsed = onThread(stackSize: handlerStack) { (try? JSON.parse(bytes)) != nil }
            #expect(parsed, "\(text.prefix(12))…")
        }
    }

    /// `maxDepth` can be raised, but only so far: each codec has a ceiling above which the
    /// option has no effect — 256 for the default codec, 128 for the fallback — because what
    /// the parser returns has to be compared, written and destroyed, and that costs stack per level.
    @Test func maxDepthStopsAtTheCeiling() {
        #expect(JSONParseOptions.depthCeiling == 256)
        let ceiling = JSON.codec == .limb ? JSONParseOptions.depthCeiling : 128
        for limit in [ceiling, ceiling + 1, 1000, Int.max] {
            let options = JSONParseOptions(maxDepth: limit)
            #expect(throws: Never.self) { try JSON.parse(nested("[", "]", ceiling), options: options) }
            #expect(throws: Never.self) { try JSON.parse(nested("{\"a\":", "}", ceiling, around: "1"), options: options) }
            for text in [nested("[", "]", ceiling + 1), nested("{\"a\":", "}", ceiling + 1, around: "1"), String(repeating: "[", count: 200_000)] {
                let error = #expect(throws: JSONParseError.self) { try JSON.parse(text, options: options) }
                #expect(error?.kind == .depthLimitExceeded(ceiling), "\(text.prefix(8))… with maxDepth \(limit)")
            }
        }
        // Below the ceiling the option is the limit.
        let options = JSONParseOptions(maxDepth: 100)
        #expect(throws: Never.self) { try JSON.parse(nested("[", "]", 100), options: options) }
        let error = #expect(throws: JSONParseError.self) { try JSON.parse(nested("[", "]", 101), options: options) }
        #expect(error?.kind == .depthLimitExceeded(100))
    }
}

private func written(_ string: String) -> [UInt8] {
    var writer = JSONWriter()
    writer.write(string)
    return writer.bytes
}

private func writtenText(_ string: String) -> String {
    String(decoding: written(string), as: UTF8.self)
}

/// What `JSONWriter` puts on the wire for a string. The two codecs must agree byte for byte:
/// a peer cannot be asked to care which one the server was built with.
@Suite struct JSONWriterEscapingTests {
    @Test func controlCharacters() {
        let short: [UInt8: String] = [0x08: #"\b"#, 0x09: #"\t"#, 0x0A: #"\n"#, 0x0C: #"\f"#, 0x0D: #"\r"#]
        for byte in UInt8(0)..<0x20 {
            let hex = String(byte, radix: 16)
            let escape = short[byte] ?? #"\u00"# + (hex.count == 1 ? "0" + hex : hex)
            #expect(writtenText(String(Unicode.Scalar(byte))) == "\"" + escape + "\"", "U+00\(hex)")
        }
    }

    @Test func quotesBackslashesAndSlashes() {
        #expect(writtenText("\"") == #""\"""#)
        #expect(writtenText("\\") == #""\\""#)
        #expect(writtenText("\\\"") == #""\\\"""#)
        #expect(writtenText("\\n") == #""\\n""#)
        // A slash needs no escape, and escaping it would bloat every URL and path.
        #expect(writtenText("/") == #""/""#)
        #expect(writtenText("https://example.com/a/b") == #""https://example.com/a/b""#)
        #expect(writtenText("</script>") == #""</script>""#)
        #expect(writtenText("") == #""""#)
        #expect(writtenText(" ") == #"" ""#)
    }

    @Test(arguments: [
        "é", "e\u{301}", "中", "😀", "👨‍👩‍👧", "\u{7F}", "\u{80}", "\u{85}", "\u{A0}", "\u{2028}", "\u{2029}",
        "\u{FEFF}", "\u{FFFD}", "\u{FFFE}", "\u{FFFF}", "\u{D7FF}", "\u{E000}", "\u{10000}", "\u{10FFFF}",
        "ключ", "مرحبا", "\u{200F}\u{202E}abc",
    ])
    func nonASCIIIsWrittenAsItsOwnBytes(_ text: String) {
        #expect(written(text) == [0x22] + Array(text.utf8) + [0x22])
    }

    /// Newline-delimited framing: a raw line break inside a message would split it in two.
    @Test func outputHasNoRawControlBytes() {
        var all = ""
        for scalar in 0..<0x100 { all.unicodeScalars.append(Unicode.Scalar(scalar)!) }
        for text in [all, "\n", "\r", "\r\n", "a\nb\rc\r\nd", "\n\n\n", "\u{2028}\u{2029}\u{85}\u{0B}\u{0C}", all + all] {
            let bytes = written(text)
            #expect(!bytes.contains(0x0A))
            #expect(!bytes.contains(0x0D))
            #expect(!bytes.contains { $0 < 0x20 })
        }
    }

    @Test func megabyteString() throws {
        let plain = String(repeating: "a", count: 1 << 20)
        let plainBytes = written(plain)
        #expect(plainBytes.count == (1 << 20) + 2)
        #expect(plainBytes.first == 0x22 && plainBytes.last == 0x22)
        #expect(try JSON.parse(plainBytes) == .string(plain))

        let unit = "line \"quoted\" \\ / é 中 😀\n\r\t\u{01}\u{1F}\u{0}"
        var mixed = ""
        while mixed.utf8.count < 1 << 20 { mixed += unit }
        let mixedBytes = written(mixed)
        #expect(!mixedBytes.contains { $0 < 0x20 })
        #expect(try JSON.parse(mixedBytes) == .string(mixed))
    }

    static let corpus: [String] = [
        "", " ", "a", "\"", "\\", "/", "\\\\", "\\\"", "\"\"", "\\n", "\\u0041", "\\ud83d", "a\\", "\\a",
        "\n", "\r", "\r\n", "\t", "\u{0}", "a\u{0}b", "\u{0}\u{0}", "\u{1F}", "\u{7F}", "\u{80}", "\u{9F}",
        "é", "e\u{301}", "\u{E9}e\u{301}", "\u{212B}\u{C5}A\u{30A}", "\u{1100}\u{1161}", "\u{AC00}",
        "中文", "😀", "👨‍👩‍👧‍👦", "🇺🇳", "\u{2028}", "\u{2029}", "x\u{FEFF}", "x\u{FEFF}y",
        "\u{FFFD}", "\u{FFFE}", "\u{FFFF}", "\u{D7FF}\u{E000}", "\u{10000}", "\u{1FFFF}", "\u{10FFFF}",
        "\u{200B}\u{200D}\u{200E}\u{200F}", "\u{202E}txt.exe", "\u{301}", "\u{301}\u{301}a",
        "[1,2,3]", "{\"a\":1}", "[[[[[[[[", "]]]]", "null", "true", "1e400", "-0",
        "data:text/plain;base64,aGk=", "C:\\Users\\name\\file.txt", "<!-- --> </script> &amp;",
        String(repeating: "\\", count: 101), String(repeating: "\"", count: 101),
        String(repeating: "\\\"", count: 50), String(repeating: "\n", count: 64),
        "exactly8", "exactly8\"", "seven77\\", "abcdefg\nhijklmnop\u{0}qrstuvwx\"yz",
    ]

    @Test(arguments: corpus.indices)
    func roundTrips(_ index: Int) throws {
        let text = Self.corpus[index]
        let parsed = try JSON.parse(written(text))
        #expect(parsed == .string(text))
        // `==` on JSONValue is already bytewise; this spells out that nothing was normalized.
        #expect(parsed.stringValue.map { Array($0.utf8) } == Array(text.utf8))
        // The second pass writes the same bytes: the parsed string is not a different spelling.
        #expect(parsed.encoded() == written(text))
    }

    /// A string that starts with U+FEFF. The default codec reads back what it wrote. The fallback
    /// writes it too — it is valid JSON and a strict peer reads it — but refuses to read it:
    /// `JSONSerialization` would drop the character, so the text is rejected rather than changed.
    @Test(arguments: ["\u{FEFF}", "\u{FEFF}x", "\u{FEFF}\u{FEFF}x", "\u{FEFF}[1]", "\u{FEFF}\u{0}", "\u{FEFF}\u{FFFE}"])
    func aLeadingByteOrderMarkIsNeverLost(_ text: String) throws {
        let bytes = written(text)
        #expect(bytes.starts(with: [0x22, 0xEF, 0xBB, 0xBF]))
        // As a key, where losing it would merge two members into one.
        let object = JSONValue.object([text: 1, String(text.dropFirst()): 2]).encoded()
        #if !FoundationJSON
        let parsed = try JSON.parse(bytes)
        #expect(parsed == .string(text))
        #expect(parsed.stringValue.map { Array($0.utf8) } == Array(text.utf8))
        let members = try JSON.parse(object)
        #expect(members.objectValue?.count == 2)
        #expect(members[text] == 1)
        #else
        #expect(outcome(bytes).error == Refusal(kind: .malformed, offset: 0))
        #expect(outcome(object).error == Refusal(kind: .malformed, offset: 1))
        #expect(outcome(JSONValue.array([1, .string(text)]).encoded()).error == Refusal(kind: .malformed, offset: 3))
        #endif
    }

    @Test func roundTripsEveryScalarBelow0x100() throws {
        var all = ""
        for value in UInt32(0)..<0x100 {
            let scalar = Unicode.Scalar(value)!
            all.unicodeScalars.append(scalar)
            let single = String(scalar)
            #expect(try JSON.parse(written(single)) == .string(single), "U+\(String(value, radix: 16))")
            // Surrounded by ASCII, so the scalar is neither first nor last in the scan.
            let padded = "abcdefgh" + single + "ijklmnop"
            #expect(try JSON.parse(written(padded)) == .string(padded), "U+\(String(value, radix: 16)) padded")
        }
        #expect(try JSON.parse(written(all)) == .string(all))
    }

    @Test func roundTripsEveryPlane() throws {
        // The whole Basic Multilingual Plane, then every 17th scalar of the planes above it.
        var chunk = ""
        var chunks: [String] = []
        func flushIfFull(force: Bool = false) {
            if force || chunk.unicodeScalars.count >= 0x1000 {
                if !chunk.isEmpty { chunks.append(chunk) }
                chunk = ""
            }
        }
        for value in UInt32(0)..<0x10000 {
            guard let scalar = Unicode.Scalar(value) else { continue }  // surrogates
            chunk.unicodeScalars.append(scalar)
            flushIfFull()
        }
        for value in stride(from: UInt32(0x10000), through: 0x10FFFF, by: 17) {
            chunk.unicodeScalars.append(Unicode.Scalar(value)!)
            flushIfFull()
        }
        chunk.unicodeScalars.append(Unicode.Scalar(0x10FFFF)!)
        flushIfFull(force: true)
        for text in chunks {
            let bytes = written(text)
            let first = text.unicodeScalars.first!.value
            #expect(!bytes.contains { $0 < 0x20 }, "chunk at U+\(String(first, radix: 16))")
            #expect(try JSON.parse(bytes) == .string(text), "chunk at U+\(String(first, radix: 16))")
        }
    }

    /// Position matters to some decoders: a scalar may be treated specially when it opens or
    /// closes a string. Every Unicode scalar is tried first and last, and every scalar of the
    /// Basic Multilingual Plane alone as well. U+FEFF is left to `aLeadingByteOrderMarkIsNeverLost`.
    @Test func everyScalarSurvivesAtEitherEndOfAString() throws {
        var start: UInt32 = 0
        while start < 0x110000 {
            var strings: [String] = []
            var origins: [UInt32] = []
            for value in start..<(start + 0x1000) where value != 0xFEFF {
                guard let scalar = Unicode.Scalar(value) else { continue }  // surrogates
                let single = String(scalar)
                if value < 0x10000 { strings.append(single); origins.append(value) }
                strings.append(single + "x")
                strings.append("x" + single)
                origins.append(value)
                origins.append(value)
            }
            start += 0x1000
            guard !strings.isEmpty else { continue }
            let parsed = try JSON.parse(JSONValue.array(strings.map(JSONValue.string)).encoded())
            let items = try #require(parsed.arrayValue)
            try #require(items.count == strings.count)
            for (index, expected) in strings.enumerated() where items[index] != .string(expected) {
                Issue.record("U+\(String(origins[index], radix: 16)) did not survive in \(expected.unicodeScalars.map { String($0.value, radix: 16) })")
            }
        }
    }

    /// The same question asked without `JSONWriter`: random short strings of awkward scalars,
    /// spelled by an encoder that lives in this test (raw, short escapes, `\u` escapes in either
    /// hex case, surrogate pairs), as values and as keys. What comes back must be the string that
    /// went in, scalar for scalar — or, under the fallback codec, a refusal for the one case it
    /// documents: a string that starts with U+FEFF.
    @Test func randomStringsSurviveAnIndependentEncoder() throws {
        let awkward: [UInt32] = [
            0x00, 0x01, 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x1F, 0x20, 0x22, 0x2F, 0x5C, 0x61, 0x75, 0x7F, 0x80, 0xA0, 0xAD, 0xE9,
            0x301, 0x34F, 0x61C, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x202E, 0x2060, 0x2066,
            0xD7FF, 0xE000, 0xFDD0, 0xFE00, 0xFE0F, 0xFEFF, 0xFFF9, 0xFFFB, 0xFFFC, 0xFFFD, 0xFFFE, 0xFFFF,
            0x10000, 0x1F600, 0x1FFFE, 0xE0001, 0xE0020, 0xE0100, 0x10FFFD, 0x10FFFF,
        ]
        let hex = Array("0123456789abcdef")
        var generator = SplitMix64(state: 0x4C49_4D42)
        func unit(_ value: UInt32, _ generator: inout SplitMix64) -> String {
            var text = "\\u"
            for shift in [12, 8, 4, 0] {
                let digit = String(hex[Int(value >> UInt32(shift) & 0xF)])
                text += Bool.random(using: &generator) ? digit.uppercased() : digit
            }
            return text
        }
        func spell(_ scalar: Unicode.Scalar, _ generator: inout SplitMix64) -> String {
            let value = scalar.value
            let short: [UInt32: String] = [0x22: "\\\"", 0x5C: "\\\\", 0x2F: "\\/", 0x08: "\\b", 0x0C: "\\f", 0x0A: "\\n", 0x0D: "\\r", 0x09: "\\t"]
            let mustEscape = value < 0x20 || value == 0x22 || value == 0x5C
            switch Int.random(in: 0..<3, using: &generator) {
            case 0 where !mustEscape: return String(scalar)
            case 1: if let escape = short[value] { return escape }
            default: break
            }
            if value < 0x10000 { return unit(value, &generator) }
            let offset = value - 0x10000
            return unit(0xD800 + (offset >> 10), &generator) + unit(0xDC00 + (offset & 0x3FF), &generator)
        }
        var failures = 0
        for iteration in 0..<20_000 {
            var scalars: [Unicode.Scalar] = []
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                var value = awkward.randomElement(using: &generator)!
                if Int.random(in: 0..<4, using: &generator) == 0 { value = UInt32.random(in: 0..<0x110000, using: &generator) }
                scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            }
            var expected = ""
            expected.unicodeScalars.append(contentsOf: scalars)
            let literal = "\"" + scalars.map { spell($0, &generator) }.joined() + "\""
            let form = Int.random(in: 0..<4, using: &generator)
            let document = [literal, "[1,\(literal)]", "{\"k\":\(literal)}", "{\(literal):1}"][form]
            let quote = [0, 3, 5, 1][form]
            let found: String?
            do {
                let parsed = try JSON.parse(document)
                switch form {
                case 0: found = parsed.stringValue
                case 1: found = parsed[1]?.stringValue
                case 2: found = parsed["k"]?.stringValue
                default: found = parsed.objectValue?.count == 1 ? parsed.objectValue?.first?.key : nil
                }
            } catch {
                #if FoundationJSON
                if scalars.first?.value == 0xFEFF, error.kind == .malformed, error.offset == quote { continue }
                #endif
                failures += 1
                if failures <= 10 { Issue.record("iteration \(iteration): \(document.debugDescription) was rejected: \(error)") }
                continue
            }
            #if FoundationJSON
            if scalars.first?.value == 0xFEFF {
                failures += 1
                if failures <= 10 { Issue.record("iteration \(iteration): \(document.debugDescription) starts with U+FEFF and was accepted") }
                continue
            }
            #endif
            if found.map({ Array($0.utf8) }) != Array(expected.utf8) {
                failures += 1
                if failures <= 10 {
                    Issue.record("iteration \(iteration): \(document.debugDescription) came back as \(found.map { $0.unicodeScalars.map { String($0.value, radix: 16) } } ?? [])")
                }
            }
        }
        #expect(failures == 0)
    }

    @Test func objectKeysAreEscapedTheSameWay() throws {
        let keys = [
            "", "plain", "a\"b", "back\\slash", "line\nbreak", "cr\rlf", "\u{0}", "\u{1F}", "/", "a/b",
            "é", "e\u{301}", "😀", "\u{2028}", "\\\"", "[", "{\"k\":1}",
        ]
        for key in keys {
            var writer = JSONWriter()
            writer.beginObject()
            writer.key(key)
            writer.writeNull()
            writer.endObject()
            #expect(writer.bytes == [0x7B] + written(key) + Array(":null}".utf8))
        }
        var writer = JSONWriter()
        writer.beginObject()
        for (index, key) in keys.enumerated() { writer.field(key, index) }
        writer.endObject()
        #expect(!writer.bytes.contains { $0 < 0x20 })
        let parsed = try JSON.parse(writer.bytes)
        #expect(parsed.objectValue?.count == keys.count)
        for (index, key) in keys.enumerated() { #expect(parsed[key] == JSONValue(index), "key \(index)") }

        // The same through a JSONObject, keys and values alike.
        let object: JSONValue = ["a\nb": "c\rd", "\"": "\\", "e\u{301}": "\u{E9}", "\u{E9}": "e\u{301}"]
        let encoded = object.encoded()
        #expect(!encoded.contains { $0 < 0x20 })
        #expect(try JSON.parse(encoded) == object)
    }

    @Test func canonicallyEquivalentTextStaysDistinctOnTheWire() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(written(composed) != written(decomposed))
        #expect(try JSON.parse(written(composed)) != JSONValue.string(decomposed))
        #expect(try JSON.parse(written(decomposed)) == JSONValue.string(decomposed))
    }
}

// MARK: - The fallback codec

#if FoundationJSON

private typealias Outcome = Result<JSONValue, JSONParseError>

/// What a `JSONParseError` says. The error type has no public initializer, so an expected
/// error is spelled as one of these and compared field by field.
private struct Refusal: Equatable {
    var kind: JSONParseError.Kind
    var offset: Int
    var description = ""

    static func == (lhs: Refusal, rhs: Refusal) -> Bool { lhs.kind == rhs.kind && lhs.offset == rhs.offset }
}

extension Result where Success == JSONValue, Failure == JSONParseError {
    fileprivate var value: JSONValue? { if case .success(let value) = self { value } else { nil } }
    fileprivate var error: Refusal? {
        guard case .failure(let error) = self else { return nil }
        return Refusal(kind: error.kind, offset: error.offset, description: error.description)
    }
}

private func outcome(_ bytes: [UInt8], _ options: JSONParseOptions = .default) -> Outcome {
    do { return .success(try JSON.parse(bytes, options: options)) } catch { return .failure(error) }
}

private func outcome(_ text: String, _ options: JSONParseOptions = .default) -> Outcome {
    do { return .success(try JSON.parse(text, options: options)) } catch { return .failure(error) }
}

private let syntaxError = Refusal(kind: .malformed, offset: 0)

// MARK: Documented differences

/// The list of things the fallback does differently on purpose. Each one is pinned here so that
/// it is a tested property of the build, not a footnote.
@Suite struct FoundationCodecDifferenceTests {
    // 1. Number text is not preserved. An integer that fits Int64 or UInt64 is exact; every
    //    other number is a Double.
    static let numberTexts: [(text: String, written: String)] = [
        // Integers in the Int64 and UInt64 range are exact.
        ("0", "0"), ("-0", "0"), ("7", "7"), ("-7", "-7"),
        ("9223372036854775807", "9223372036854775807"), ("-9223372036854775808", "-9223372036854775808"),
        ("9223372036854775808", "9223372036854775808"), ("18446744073709551615", "18446744073709551615"),
        ("9007199254740993", "9007199254740993"), ("1000000000000000000", "1000000000000000000"),
        ("10000000000000000000", "10000000000000000000"),
        // One step outside that range the number is a Double, and says so when written back.
        ("18446744073709551616", "1.8446744073709552e+19"), ("18446744073709551617", "1.8446744073709552e+19"),
        ("-9223372036854775809", "-9.223372036854776e+18"), ("-18446744073709551615", "-1.8446744073709552e+19"),
        ("-18446744073709551616", "-1.8446744073709552e+19"), ("100000000000000000000", "1e+20"),
        ("99999999999999999999", "1e+20"), ("12345678901234567890123", "1.2345678901234568e+22"),
        ("123456789012345678901234567890", "1.2345678901234568e+29"),
        ("-123456789012345678901234567890", "-1.2345678901234568e+29"),
        // Everything with a fraction or an exponent is a Double, written the way Swift prints one.
        ("0.1", "0.1"), ("-1.5", "-1.5"), ("1.5e3", "1500.0"), ("1e2", "100.0"), ("1E2", "100.0"),
        ("1e+2", "100.0"), ("1E+2", "100.0"), ("1e-2", "0.01"), ("1.0", "1.0"), ("1.10", "1.1"),
        ("100.0", "100.0"), ("0.0", "0.0"), ("-0.0", "-0.0"), ("0e0", "0.0"), ("-0e0", "-0.0"), ("1e0", "1.0"),
        ("1e01", "10.0"), ("15e-1", "1.5"), ("0.1e-7", "1e-08"), ("0.30000000000000004", "0.30000000000000004"),
        ("1e19", "1e+19"), ("1e308", "1e+308"), ("1.7976931348623157e308", "1.7976931348623157e+308"),
        ("12345678901234567e3", "1.2345678901234567e+19"), ("5e-324", "5e-324"), ("4.9e-324", "5e-324"),
        ("9007199254740993.0", "9007199254740992.0"),
        // Also when the digits spell an integer that would have fitted.
        ("18446744073709551615.0", "1.8446744073709552e+19"), ("9223372036854775807.0", "9.223372036854776e+18"),
        ("1.00000000000000000000", "1.0"), ("0.10000000000000000000", "0.1"), ("100000000000000000000.0", "1e+20"),
        ("7e0", "7.0"), ("7.0", "7.0"), ("70e-1", "7.0"),
        // Below the smallest Double the value collapses to zero without an error.
        ("1e-400", "0.0"),
    ]

    @Test(arguments: numberTexts.indices)
    func numberTextIsNotPreserved(_ index: Int) throws {
        let (text, expected) = Self.numberTexts[index]
        let value = try JSON.parse(text)
        #expect(value.numberValue != nil)
        #expect(value.description == expected, "\(text)")
        // Whatever is written back is itself a JSON number, and reading it changes nothing more.
        #expect(JSONNumber(lexeme: value.description) != nil, "\(text)")
        let again = try JSON.parse(value.encoded())
        #expect(again == value, "\(text)")
        #expect(again.description == value.description, "\(text)")
        // The same through the byte entry point and inside containers.
        #expect(try JSON.parse(Array(text.utf8)).description == expected, "\(text)")
        #expect(try JSON.parse("[\(text)]")[0]?.description == expected, "\(text)")
        #expect(try JSON.parse("{\"n\":\(text)}")["n"]?.description == expected, "\(text)")
    }

    // 2. Numbers out of Double range are rejected, although they are valid JSON.
    @Test(arguments: ["1e400", "-1e400", "1E400", "1e+400", "2e308", "1.7976931348623159e308", "1e1000", "[1e400]", #"{"n":1e400}"#])
    func numbersBeyondDoubleRangeAreRejected(_ text: String) {
        #expect(outcome(text).error != nil)
        #expect(outcome(Array(text.utf8)).error != nil)
    }

    // 3. Trailing commas.
    @Test func trailingCommasAreAccepted() throws {
        #expect(try JSON.parse("[1,]") == [1])
        #expect(try JSON.parse("[1 , ]") == [1])
        #expect(try JSON.parse("[1,\n]") == [1])
        #expect(try JSON.parse("[null,]") == [nil])
        #expect(try JSON.parse("[[1,],]") == [[1]])
        #expect(try JSON.parse("[1,2,]").arrayValue?.count == 2)
        #expect(try JSON.parse(#"{"a":1,}"#) == ["a": 1])
        #expect(try JSON.parse(#"{"a":[1,],}"#) == ["a": [1]])
        #expect(try JSON.parse(#"{"a":{"b":2,},}"#) == ["a": ["b": 2]])
        #expect(try JSON.parse(#"{"a":1,}"#).objectValue?.count == 1)
    }

    /// One trailing comma is all Foundation forgives: anything else about commas is still an error.
    @Test(arguments: [
        "[,]", "[,1]", "[1,,]", "[1,,2]", "[1,2,,]", "{,}", #"{"a":1,,}"#, #"{,"a":1}"#, "1,", "[1],", ",", ",1",
        "[1,]]", "[1,],", #"{"a":1,}}"#, #"{"a":,}"#, #"{"a",}"#,
    ])
    func otherCommaMistakesAreStillRejected(_ text: String) {
        #expect(outcome(text).error == syntaxError)
    }

    // 4. Duplicate keys.
    @Test func duplicateKeysAreNotDetected() throws {
        let cases: [(text: String, key: String, candidates: [JSONValue], count: Int)] = [
            (#"{"a":1,"a":2}"#, "a", [1, 2], 1),
            (#"{"a":1,"a":1}"#, "a", [1], 1),
            (#"{"a":1,"a":2,"a":3}"#, "a", [1, 2, 3], 1),
            (#"{"a":1,"b":2,"a":3}"#, "a", [1, 3], 2),
            (#"{"a":{"x":1},"a":[2]}"#, "a", [["x": 1], [2]], 1),
            (#"{"a":null,"a":false}"#, "a", [nil, false], 1),
            (#"{"":1,"":2}"#, "", [1, 2], 1),
            (#"{"\u0061":1,"a":2}"#, "a", [1, 2], 1),
        ]
        for (text, key, candidates, count) in cases {
            for options in [JSONParseOptions.default, JSONParseOptions(rejectDuplicateKeys: false)] {
                let value = try JSON.parse(text, options: options)
                #expect(value.objectValue?.count == count, "\(text)")
                let survivor = try #require(value[key], "\(text)")
                #expect(candidates.contains(survivor), "\(text) kept \(survivor)")
            }
        }
        // Nested objects are no different.
        #expect(try JSON.parse(#"[{"a":1,"a":2}]"#)[0]?.objectValue?.count == 1)
        #expect(try JSON.parse(#"{"o":{"a":1,"a":2}}"#)["o"]?.objectValue?.count == 1)
    }

    #if canImport(Darwin)
    /// On Apple platforms it is the first member that survives — the opposite of what the default
    /// codec does when duplicates are allowed. Nothing promises this; it is pinned so that a
    /// change in Foundation is noticed, because which duplicate wins is what smuggling relies on.
    @Test func firstDuplicateWinsOnDarwin() throws {
        #expect(try JSON.parse(#"{"a":1,"a":2}"#) == ["a": 1])
        #expect(try JSON.parse(#"{"a":1,"b":2,"a":3}"#) == ["a": 1, "b": 2])
        #expect(try JSON.parse(#"{"a":{"x":1},"a":[2]}"#) == ["a": ["x": 1]])
        #expect(try JSON.parse(#"{"a":1,"a":2,"a":3}"#, options: JSONParseOptions(rejectDuplicateKeys: false)) == ["a": 1])
        let members = (0..<200).map { "\"k\":\($0)" }
        #expect(try JSON.parse("{" + members.joined(separator: ",") + "}") == ["k": 0])
    }
    #endif

    // 5. Member order is not preserved; equality never depended on it.
    @Test func membersSurviveInSomeOrder() throws {
        let names = (0..<50).map { "member\($0)" }
        let text = "{" + names.enumerated().map { "\"\($1)\":\($0)" }.joined(separator: ",") + "}"
        let value = try JSON.parse(text)
        let object = try #require(value.objectValue)
        #expect(object.count == names.count)
        #expect(Set(object.map(\.key)) == Set(names))
        for (index, name) in names.enumerated() { #expect(object[name] == JSONValue(index)) }
        #expect(value == .object(JSONObject(names.enumerated().map { ($1, JSONValue($0)) })))
        // Whatever the order, writing and reading again gives the same object.
        #expect(try JSON.parse(value.encoded()) == value)
    }

    // 6. Errors carry no position and no reason.
    @Test(arguments: [
        "", " ", "[1 2]", "01", "nul", #"{"a"}"#, "[", "{", #""abc"#, "1 2", "[1]]", "NaN", "'a'", #""\x""#,
        #""\ud800""#, "\"a\nb\"", "1e400",
    ])
    func syntaxErrorsAreAllTheSame(_ text: String) {
        #expect(outcome(text).error == syntaxError)
        #expect(outcome(text).error?.description == "input is not valid JSON, or the Foundation codec cannot represent it")
    }

    /// The checks Limb makes itself, before Foundation, still say what and where.
    @Test func errorsFoundBeforeFoundationKeepTheirPosition() {
        #expect(outcome("[1,\u{0}2]").error == Refusal(kind: .unexpectedByte(0), offset: 3))
        #expect(outcome("\u{FEFF}[1]").error == Refusal(kind: .unexpectedByte(0xEF), offset: 0))
        #expect(outcome([0x5B, 0x22, 0xFF, 0x22, 0x5D]).error == Refusal(kind: .invalidUTF8, offset: 2))
        #expect(outcome("[[[1]]]", JSONParseOptions(maxDepth: 2)).error == Refusal(kind: .depthLimitExceeded(2), offset: 2))
        #expect(outcome("[1,2,3]", JSONParseOptions(maxNodes: 3)).error == Refusal(kind: .nodeLimitExceeded(3), offset: 0))
    }

    // 7. `maxDepth` cannot be raised above 128.
    @Test func maxDepthCannotBeRaisedAboveTheCeiling() {
        let arrays = nested("[", "]", 129)
        let objects = nested("{\"a\":", "}", 129, around: "1")
        for limit in [129, 130, 512, 1000, 1_000_000, Int.max] {
            let options = JSONParseOptions(maxDepth: limit)
            #expect(outcome(arrays, options).error == Refusal(kind: .depthLimitExceeded(128), offset: 128))
            // Each level of `{"a":` is five bytes; the 129th brace is the one refused.
            #expect(outcome(objects, options).error == Refusal(kind: .depthLimitExceeded(128), offset: 128 * 5))
        }
    }

    // 8. `maxNodes` is enforced, only later than in the default codec.
    @Test func nodeLimitIsEnforced() {
        func zeros(_ count: Int) -> String { "[" + Array(repeating: "0", count: count).joined(separator: ",") + "]" }
        // The array is a value too: 49 zeros make 50 nodes.
        #expect(outcome(zeros(49), JSONParseOptions(maxNodes: 50)).value != nil)
        #expect(outcome(zeros(50), JSONParseOptions(maxNodes: 50)).error == Refusal(kind: .nodeLimitExceeded(50), offset: 0))
        // Keys are not values: an object with two members is three nodes.
        #expect(outcome(#"{"a":1,"b":2}"#, JSONParseOptions(maxNodes: 3)).value != nil)
        #expect(outcome(#"{"a":1,"b":2}"#, JSONParseOptions(maxNodes: 2)).error?.kind == .nodeLimitExceeded(2))
        #expect(outcome("1", JSONParseOptions(maxNodes: 1)).value == 1)
        #expect(outcome("1", JSONParseOptions(maxNodes: 0)).error?.kind == .nodeLimitExceeded(0))
        #expect(outcome("[]", JSONParseOptions(maxNodes: 1)).value == [])
        #expect(outcome("[[]]", JSONParseOptions(maxNodes: 1)).error?.kind == .nodeLimitExceeded(1))
        #expect(outcome(#"[[1,"a"],{"b":null}]"#, JSONParseOptions(maxNodes: 6)).value != nil)
        #expect(outcome(#"[[1,"a"],{"b":null}]"#, JSONParseOptions(maxNodes: 5)).error?.kind == .nodeLimitExceeded(5))
        // The default limit of a million values.
        #expect(outcome(zeros(999_999)).value?.arrayValue?.count == 999_999)
        #expect(outcome(zeros(1_000_000)).error == Refusal(kind: .nodeLimitExceeded(1_000_000), offset: 0))
    }

    // 9. Some valid numbers inside Double range are refused. This is `JSONSerialization` on
    //    macOS 27: past about 17 significant digits it reads the number as a decimal, whose
    //    exponent range is far narrower than a Double's, and reports an error instead of falling
    //    back. The default codec accepts every one of these, and so does `Double(_:)`.
    static let refusedInsideDoubleRange: [String] = [
        "1.2345678901234567890123e200", "1.2345678901234567890123e-130", "12345678901234567890123e-150",
        "4.940656458412465442e-324", "1" + String(repeating: "0", count: 166),  // an integer of 167 digits
        "1" + String(repeating: "0", count: 300), "-1" + String(repeating: "0", count: 200),
        "[1,1.2345678901234567890123e200]", #"{"n":1.2345678901234567890123e-130}"#,
    ]

    @Test(arguments: refusedInsideDoubleRange)
    func someNumbersInsideDoubleRangeAreRejected(_ text: String) {
        if let value = Double(text) { #expect(value.isFinite) }
        #expect(outcome(text).error == syntaxError, "\(text.prefix(40)) (\(text.utf8.count) bytes)")
        #expect(outcome(Array(text.utf8)).error == syntaxError)
    }

    /// The edge of that behaviour, so that a change in Foundation is noticed: the same digits with
    /// a smaller exponent, and an integer one digit shorter, are read.
    @Test func theSameNumbersCloserToOneAreAccepted() {
        #expect(outcome("1.2345678901234567890123e100").value?.doubleValue != nil)
        #expect(outcome("1.2345678901234567890123e-100").value?.doubleValue != nil)
        #expect(outcome("1" + String(repeating: "0", count: 165)).value?.doubleValue != nil)  // 166 digits
        #expect(outcome("1.2345678901234567e200").value?.doubleValue == 1.2345678901234567e200)
        #expect(outcome("1e300").value?.doubleValue == 1e300)
    }

    // 10. A string that starts with U+FEFF is refused, value or key, raw or escaped: valid JSON
    //     that this codec cannot hand back unchanged. `FoundationCodecStringTests` attacks the check.
    @Test func stringsStartingWithAByteOrderMarkAreRejected() {
        #expect(outcome("\"\u{FEFF}text\"").error == Refusal(kind: .malformed, offset: 0))
        #expect(outcome(#""\ufefftext""#).error == Refusal(kind: .malformed, offset: 0))
        #expect(outcome(#"{"\uFEFFkey":1}"#).error == Refusal(kind: .malformed, offset: 1))
        #expect(outcome("\"text\u{FEFF}\"").value == "text\u{FEFF}")
    }
}

// MARK: Strictness kept

/// Foundation is lenient about trailing commas and duplicate keys. This is everything else a
/// lenient parser might let through, and the fallback must not.
@Suite struct FoundationCodecStrictnessTests {
    @Test(arguments: [
        // Structure.
        #"{"a":1 "b":2}"#, #"{"a" 1}"#, #"{"a"::1}"#, #"{"a":}"#, "{:1}", #"{"a":1,"b"}"#, "{a:1}", "{'a':1}",
        "{1:1}", "{null:1}", #"{["a"]:1}"#, "[}", "{]", "[1}", #"{"a":1]"#, "]", "}", "[]]", "{}}", "[[]", "{{}",
        "[1", #"{"a""#, #"{"a":"#, #"{"a":1"#, "[1 2]", "[1;2]", "[1:2]", #"["a":1]"#, "(1)", "<1>",
        // Numbers.
        "01", "-01", "00", "-00", "1.", ".5", "-.5", "1e", "1e+", "1E-", "+1", "++1", "--1", "- 1", "-", "0x10",
        "-0x10", "0x1p4", "0b1", "0o7", "1_000", "1 000", "1,000", "1.2.3", "0.0.0", "1e1.5", "1e1e1", "1.e1", "0.e1",
        "2.e+3", "0.", "-0.", "1.5.", "1+1", "1-1", "1a", "1f", "1d", "1L", "0e", "-0e", "١", "１", "½", "1e٣",
        "Infinity", "-Infinity", "+Infinity", "inf", "-inf", "NaN", "+NaN", "nan", "-nan", "-NAN", "-Nan", "-NaNx", "-NaN1",
        // Literals.
        "True", "TRUE", "False", "Null", "NULL", "nil", "none", "None", "undefined", "truee", "nulll", "falsee",
        "tru", "fals", "nul", "t", "f", "n", "[truefalse]", "[true false]", "-true", "-null", "yes", "on",
        // Trailing data and comments.
        "1 2", "[] []", "{} {}", "{} x", "\"a\" \"b\"", "null null", "true false", "1/**/", "//c\n1", "/* */ 1",
        "[1] //x", "[1] #x", "# x\n1", "1;", "[1];", "{};", "[1]x", "1x", "\"a\"x", "[1]\u{0B}", "nullnull",
        // Whitespace that is not JSON whitespace.
        "\u{0B}1", "\u{0C}1", "1\u{0B}", "1\u{0C}", "[1,\u{0C}2]", "\u{A0}1", "1\u{A0}", "\u{85}1", "\u{2028}1",
        "\u{2029}1", "\u{2003}1", "\u{3000}1", "\u{1680}1", "\u{200B}1", "[\u{FEFF}1]", "1\u{FEFF}", " \u{FEFF}1",
        "\u{1}1", "\u{1F}1", "\u{7F}1", "1\u{7F}",
        // Strings.
        "'a'", "\"a", "a\"", "\"", "\"\\\"", #""\a""#, #""\'""#, #""\0""#, #""\x41""#, #""\U0041""#, #""\v""#,
        #""\e""#, #""\ ""#, #""\u""#, #""\u1""#, #""\u12""#, #""\u123""#, #""\u00G0""#, #""\u 041""#, #""\u+041""#,
        #""\u-041""#, #""\u{41}""#, #""\N{DIGIT ONE}""#, "\"\\\n\"", "\"\\é\"", "“a”", "`a`",
    ])
    func rejects(_ text: String) {
        #expect(outcome(text).error != nil)
        #expect(outcome(Array(text.utf8)).error != nil)
    }

    /// `JSONSerialization` itself reads `-NaN` as a number. It must not survive as one.
    @Test(arguments: ["-NaN", " -NaN ", "[-NaN]", "[1,-NaN]", #"{"a":-NaN}"#, #"{"a":[-NaN]}"#])
    func negativeNaNIsRejected(_ text: String) {
        #expect(outcome(text).error != nil)
    }

    @Test func emptyAndBlankInputIsRejected() {
        #expect(outcome([UInt8]()).error == syntaxError)
        for text in ["", " ", "\n", "\t", "\r", "\r\n", " \t\r\n ", String(repeating: " ", count: 100_000)] {
            #expect(outcome(text).error == syntaxError)
            #expect(outcome(Array(text.utf8)).error == syntaxError)
        }
    }

    @Test func topLevelScalars() throws {
        #expect(try JSON.parse("null") == .null)
        #expect(try JSON.parse("true") == .bool(true))
        #expect(try JSON.parse("false") == .bool(false))
        #expect(try JSON.parse("0") == 0)
        #expect(try JSON.parse("-12") == -12)
        #expect(try JSON.parse("1.5") == 1.5)
        #expect(try JSON.parse("\"\"") == "")
        #expect(try JSON.parse("\"text\"") == "text")
        #expect(try JSON.parse("[]") == [])
        #expect(try JSON.parse("{}") == [:])
        // The four JSON whitespace characters, on either side, in any amount.
        for text in [" null", "null ", "\tnull\t", "\nnull\n", "\rnull\r", "\r\n null \r\n", "  \t\n\r null \r\n\t  "] {
            #expect(try JSON.parse(text) == .null, "\(text.debugDescription)")
        }
        #expect(try JSON.parse(String(repeating: " ", count: 100_000) + "7" + String(repeating: "\n", count: 100_000)) == 7)
        #expect(try JSON.parse(" [ 1 , { \"a\" : [ ] } , \"b\" ] ") == [1, ["a": []], "b"])
    }

    /// Handlers parse on many threads at once; nothing in the fallback may be shared between calls.
    @Test func concurrentUse() {
        let document = #"{"a":[1,2.5,true,null,"é\ud83d\ude00",{"b":[]}],"n":18446744073709551616,"s":"x"}"#
        let expected = outcome(document)
        #expect(expected.value != nil)
        let mismatches = Slot<Int>()
        mismatches.value = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 16) { worker in
            var wrong = 0
            for round in 0..<200 {
                if outcome(document) != expected { wrong += 1 }
                if outcome(String(repeating: "[", count: 129 + round)).error?.kind != .depthLimitExceeded(128) { wrong += 1 }
                if outcome("[\(worker),\(round),]").value != [JSONValue(worker), JSONValue(round)] { wrong += 1 }
            }
            lock.withLock { mismatches.value! += wrong }
        }
        #expect(mismatches.value == 0)
    }

    @Test func booleansAndNumbersStayDistinct() throws {
        let value = try JSON.parse(
            #"[true,false,1,0,[true,1,[false,0]],{"t":true,"one":1,"f":false,"zero":0,"n":null},1.0,0.0]"#)
        #expect(value[0] == .bool(true))
        #expect(value[1] == .bool(false))
        #expect(value[2] == .number(1))
        #expect(value[3] == .number(0))
        #expect(value[0]?.numberValue == nil && value[1]?.numberValue == nil)
        #expect(value[2]?.boolValue == nil && value[3]?.boolValue == nil)
        #expect(value[0] != value[2] && value[1] != value[3])
        #expect(value[4] == [true, 1, [false, 0]])
        #expect(value[4]?[0]?.boolValue == true)
        #expect(value[4]?[1]?.intValue == 1 && value[4]?[1]?.boolValue == nil)
        #expect(value[4]?[2]?[0]?.boolValue == false)
        #expect(value[4]?[2]?[1]?.intValue == 0 && value[4]?[2]?[1]?.boolValue == nil)
        let object = try #require(value[5])
        #expect(object["t"] == .bool(true) && object["t"]?.numberValue == nil)
        #expect(object["f"] == .bool(false) && object["f"]?.numberValue == nil)
        #expect(object["one"] == .number(1) && object["one"]?.boolValue == nil)
        #expect(object["zero"] == .number(0) && object["zero"]?.boolValue == nil)
        #expect(object["n"] == .null)
        // A double that happens to equal 1 or 0 is not a boolean either.
        #expect(value[6]?.boolValue == nil && value[6] == 1)
        #expect(value[7]?.boolValue == nil && value[7] == 0)
        #expect(value[0]?.typeName == "boolean" && value[2]?.typeName == "integer")
        #expect(try JSON.parse("[true,false,1,0]").description == "[true,false,1,0]")
        #expect(try JSON.parse("true").description == "true")
        #expect(try JSON.parse("1").description == "1")

        // Many of each, interleaved: no caching on Foundation's side may blur them.
        let unit = ["true", "1", "false", "0"]
        let many = try JSON.parse("[" + (0..<4000).map { unit[$0 % 4] }.joined(separator: ",") + "]")
        let items = try #require(many.arrayValue)
        #expect(items.count == 4000)
        for (index, item) in items.enumerated() {
            switch index % 4 {
            case 0: #expect(item == .bool(true), "index \(index)")
            case 1: #expect(item == .number(1) && item.boolValue == nil, "index \(index)")
            case 2: #expect(item == .bool(false), "index \(index)")
            default: #expect(item == .number(0) && item.boolValue == nil, "index \(index)")
            }
        }
    }
}

// MARK: Numbers

@Suite struct FoundationCodecNumberTests {
    @Test func integersInMachineRange() throws {
        #expect(try JSON.parse("0").intValue == 0)
        #expect(try JSON.parse("-0").intValue == 0)
        #expect(try JSON.parse("-0") == 0)
        #expect(try JSON.parse("-7").intValue == -7)
        #expect(try JSON.parse("9223372036854775807").numberValue?.int64Value == .max)
        #expect(try JSON.parse("-9223372036854775808").numberValue?.int64Value == .min)
        #expect(try JSON.parse("9007199254740993").numberValue?.int64Value == 9_007_199_254_740_993)
        // Above Int64 there is no machine integer to return, but up to UInt64 the text is exact.
        let aboveInt64 = try JSON.parse("9223372036854775808")
        #expect(aboveInt64.numberValue?.int64Value == nil)
        #expect(aboveInt64.description == "9223372036854775808")
        #expect(aboveInt64.numberValue?.isInteger == true)
        let maxUnsigned = try JSON.parse("18446744073709551615")
        #expect(maxUnsigned.numberValue?.int64Value == nil)
        #expect(maxUnsigned.description == String(UInt64.max))
        #expect(maxUnsigned.typeName == "integer")
        #expect(maxUnsigned != (try JSON.parse("18446744073709551614")))
        #expect(maxUnsigned == (try JSON.parse("18446744073709551615")))
        // Neighbouring integers inside the range stay different numbers.
        for (lower, upper) in [
            ("9223372036854775806", "9223372036854775807"), ("9223372036854775807", "9223372036854775808"),
            ("9223372036854775808", "9223372036854775809"), ("-9223372036854775808", "-9223372036854775807"),
            ("18446744073709551614", "18446744073709551615"), ("9007199254740992", "9007199254740993"),
        ] {
            #expect(try JSON.parse(lower) != JSON.parse(upper), "\(lower) vs \(upper)")
        }
        // Every integer of 1 to 19 digits, and the 20-digit ones that fit, digit for digit.
        var generator = SplitMix64(state: 64)
        for digits in 1...20 {
            for _ in 0..<200 {
                var text = String(Int.random(in: 1...9, using: &generator))
                for _ in 1..<digits { text += String(Int.random(in: 0...9, using: &generator)) }
                guard UInt64(text) != nil else { continue }
                #expect(try JSON.parse(text).description == text)
                if Int64("-" + text) != nil { #expect(try JSON.parse("-" + text).description == "-" + text) }
            }
        }
    }

    @Test func integersBeyondSixtyFourBitsAreDoubles() throws {
        let twoToThe64 = try JSON.parse("18446744073709551616")
        #expect(twoToThe64.numberValue?.int64Value == nil)
        #expect(twoToThe64.doubleValue == 18446744073709551616.0)
        #expect(twoToThe64.description == "1.8446744073709552e+19")
        #expect(twoToThe64.typeName == "integer")
        #expect(twoToThe64 == .number(JSONNumber(lexeme: "18446744073709552000")!))
        #expect(twoToThe64 == (try JSON.parse("18446744073709551617")))
        #expect(twoToThe64.hashValue == (try JSON.parse("18446744073709551617")).hashValue)
        // UInt64.max fits 64 bits and stays exact: it is not its rounded neighbour.
        let uint64Max = try JSON.parse("18446744073709551615")
        #expect(uint64Max.description == "18446744073709551615")
        #expect(twoToThe64 != uint64Max)
        #expect(uint64Max.numberValue! < twoToThe64.numberValue!)
        let belowInt64 = try JSON.parse("-9223372036854775809")
        #expect(belowInt64.description == "-9.223372036854776e+18")
        #expect(belowInt64 == .number(JSONNumber(lexeme: "-9223372036854776000")!))
        #expect(belowInt64 == (try JSON.parse("-9223372036854775810")))
        #expect(belowInt64 != (try JSON.parse("-9223372036854775808")))
        #expect(belowInt64.numberValue?.int64Value == nil)
        #expect(belowInt64.numberValue! < JSONNumber(Int64.min))
        #expect(try JSON.parse("123456789012345678901234567890") == JSON.parse("123456789012345678901234567891"))
        // Far apart they are still different numbers.
        #expect(twoToThe64 != (try JSON.parse("36893488147419103232")))
        #expect(try JSON.parse("1" + String(repeating: "0", count: 30)) != JSON.parse("1" + String(repeating: "0", count: 31)))
    }

    @Test func doubles() throws {
        #expect(try JSON.parse("0.1").doubleValue == 0.1)
        #expect(try JSON.parse("1.5e3").doubleValue == 1500)
        #expect(try JSON.parse("1.5e3").intValue == 1500)
        #expect(try JSON.parse("1e2").intValue == 100)
        #expect(try JSON.parse("1.0") == 1)
        #expect(try JSON.parse("1.0").typeName == "integer")
        #expect(try JSON.parse("1.5").intValue == nil)
        #expect(try JSON.parse("1.5").typeName == "number")
        #expect(try JSON.parse("-0.0").doubleValue?.sign == .minus)
        #expect(try JSON.parse("-0.0") == 0)
        #expect(try JSON.parse("1e308").doubleValue == 1e308)
        #expect(try JSON.parse("5e-324").doubleValue == 5e-324)
        #expect(try JSON.parse("0.30000000000000004").doubleValue == 0.1 + 0.2)
        #expect(try JSON.parse("3.141592653589793").doubleValue == Double.pi)
    }

    static func looksExact(_ written: String) -> Bool {
        written.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    /// What the rule about numbers is for: a value that is not exactly what was sent must be
    /// visibly approximate when written back — a Double, with its `.` or `e` — and never a
    /// different integer that looks exact. (`JSONSerialization` hands back 38 digits of a longer
    /// integer as if they were all of it; that text must not reach the caller.)
    static let inexactNumbers: [String] = [
        String(repeating: "9", count: 20), String(repeating: "9", count: 38), String(repeating: "9", count: 39),
        String(repeating: "9", count: 40), String(repeating: "9", count: 100),
        "340282366920938463463374607431768211455", "340282366920938463463374607431768211456",  // 2^128 - 1, 2^128
        "-340282366920938463463374607431768211457", "18446744073709551616", "-9223372036854775809",
        "1234567890123456789012345678901234567890123456789012345678901234567891",
        "1" + String(repeating: "0", count: 38), "1" + String(repeating: "0", count: 39), "1" + String(repeating: "0", count: 165),
        "18446744073709551615.0", "18446744073709551615.5", "9223372036854775807.0", "9223372036854775807.5",
        "12345678901234567890.5", "0.1000000000000000055511151231257827", "3.141592653589793238462643383279502884197",
        "123456789012345678901234567890e100", "0.000000000000000000000000000000000000001",
        "99999999999999999999999999999999999999.9", "1e19", "1e20", "1.0e18", "100e16", "9223372036854775807e0",
    ]

    @Test(arguments: inexactNumbers)
    func inexactNumbersNeverLookExact(_ text: String) throws {
        let value = try JSON.parse(text)
        let written = value.description
        #expect(!Self.looksExact(written), "\(text) came back as the exact-looking \(written)")
        // Approximate, but not arbitrary: within a few units of the last place of the nearest Double.
        let nearest = try #require(Double(text))
        let found = try #require(value.doubleValue)
        #expect(abs(found - nearest) <= abs(nearest) * 1e-15, "\(text) came back as \(written), nearest is \(nearest)")
    }

    /// The same property over generated numbers: integers of 1 to 60 digits and the same digits
    /// with a fraction or an exponent attached.
    @Test func generatedNumbersAreExactOrVisiblyApproximate() throws {
        var generator = SplitMix64(state: 0xD2)
        var failures = 0
        func record(_ message: String) {
            failures += 1
            if failures <= 10 { Issue.record(Comment(rawValue: message)) }
        }
        for iteration in 0..<6000 {
            var digits = String(Int.random(in: 1...9, using: &generator))
            for _ in 1..<Int.random(in: 1...60, using: &generator) { digits += String(Int.random(in: 0...9, using: &generator)) }
            let sign = Bool.random(using: &generator) ? "-" : ""
            let suffix = ["", "", "", ".0", ".5", "e0", "E0", "e1", "e-1", ".25e2"][Int.random(in: 0..<10, using: &generator)]
            let text = sign + digits + suffix
            guard let value = try? JSON.parse(text) else {
                // Long digit strings with an exponent can fall into documented difference 9.
                if suffix.isEmpty { record("iteration \(iteration): \(text) was rejected") }
                continue
            }
            let written = value.description
            let fits = suffix.isEmpty && (Int64(text) != nil || UInt64(text) != nil)
            if fits {
                if written != text { record("iteration \(iteration): \(text) fits 64 bits and came back as \(written)") }
            } else if Self.looksExact(written) {
                record("iteration \(iteration): \(text) came back as the exact-looking \(written)")
            }
        }
        #expect(failures == 0)
    }

    /// "Becomes a Double" means the nearest Double, which is what the default codec and
    /// `Double(_:)` give. Foundation hands a number with more than about 17 significant digits
    /// back as a decimal; its own `doubleValue` is not correctly rounded (`1e30` written out in
    /// full comes back as 9.999999999999999e+29), so the fallback reads the decimal's text.
    @Test(arguments: [
        "0.1000000000000000055511151231257827",  // the exact value of the Double 0.1
        "0.3000000000000000444089209850062616169452667236328125",  // the exact value of 0.1 + 0.2
        "12345678901234567890.5", "2.718281828459045235360287471352662497757",
        "1000000000000000000000000000000", "0.1234567890123456789012345678901234567890123",
        "-68926151071865268500", "520912869028140993020", "0.078467816386878719", "47846214.2880053073",
        "3632650099319.34082", "16991216176667.20312",
        // Halfway between two Doubles, and a hair to either side, within the 38 digits a decimal keeps.
        "9007199254740993", "9007199254740993.0", "9007199254740993.00000000000000000001", "9007199254740992.99999999999999999999",
        "1.00000000000000011102230246251565404", "1.00000000000000011102230246251565405", "1.0000000000000001110223024625156541",
        "1.7976931348623157e308", "2.2250738585072014e-308",
        "123456789012345678", "1234567890123456789.0", "0.1e1", "1e23", "8.5e22", "9.5e22", "1e22", "4.35", "2.675", "0.57", "8.7",
    ])
    func longNumbersBecomeTheNearestDouble(_ text: String) throws {
        let nearest = try #require(Double(text))
        let value = try JSON.parse(text)
        #expect(value.doubleValue == nearest, "\(text) came back as \(value), the nearest Double is \(nearest)")
    }

    /// The usual way to write a Double so that nothing is lost is 17 significant digits
    /// (`%.17g`); careless writers use more. Such text must read back as the Double it was
    /// written from, and shorter text as the Double it names.
    @Test(arguments: [1, 5, 15, 16, 17, 18, 20, 25, 38, 40])
    func doublesWrittenWithAnyNumberOfDigitsComeBackUnchanged(_ precision: Int) throws {
        var generator = SplitMix64(state: UInt64(precision))
        var wrong = 0
        var rejected = 0
        var examples: [String] = []
        let count = 3000
        for _ in 0..<count {
            let exponent = Int.random(in: -20...20, using: &generator)
            let sent = Double.random(in: 1..<10, using: &generator) * pow(10, Double(exponent))
            let text = String(format: "%.\(precision)g", sent)
            // With fewer than 17 digits the text names a neighbour of `sent`; that is the target.
            let target = precision >= 17 ? sent : Double(text)!
            guard let found = try? JSON.parse(text).doubleValue else {
                rejected += 1
                continue
            }
            if found != target {
                wrong += 1
                if examples.count < 3 { examples.append("\(text) -> \(found)") }
            }
        }
        #expect(wrong == 0, "\(wrong) of \(count) Doubles written with \(precision) digits changed, e.g. \(examples)")
        #expect(rejected == 0, "\(rejected) of \(count) Doubles written with \(precision) digits were rejected")
    }

    /// The same for numbers that are not printed Doubles: random digits, any length, with
    /// fractions and exponents. Whatever is accepted is the nearest Double, or — for an integer
    /// that fits 64 bits — exact.
    @Test func generatedNumbersAreCorrectlyRounded() throws {
        var generator = SplitMix64(state: 0xD0B1E)
        var failures = 0
        for iteration in 0..<20_000 {
            var text = Bool.random(using: &generator) ? "-" : ""
            text += String(Int.random(in: 1...9, using: &generator))
            for _ in 0..<Int.random(in: 0...40, using: &generator) { text += String(Int.random(in: 0...9, using: &generator)) }
            if Bool.random(using: &generator) {
                text += "."
                for _ in 0..<Int.random(in: 1...40, using: &generator) { text += String(Int.random(in: 0...9, using: &generator)) }
            }
            if Int.random(in: 0..<3, using: &generator) == 0 { text += "e\(Int.random(in: -60...60, using: &generator))" }
            guard let value = try? JSON.parse(text), let found = value.doubleValue, let nearest = Double(text) else { continue }
            let exact = Int64(text) != nil || UInt64(text) != nil
            if exact ? value.description != text : found != nearest {
                failures += 1
                if failures <= 10 { Issue.record("iteration \(iteration): \(text) came back as \(value), the nearest Double is \(nearest)") }
            }
        }
        #expect(failures == 0)
    }

    /// The known limit of reading the decimal's text: Foundation keeps 38 digits and drops the
    /// rest, so a number that sits just above the midpoint of two Doubles, with the difference
    /// past the 38th digit, is seen as the midpoint itself and rounds to the even neighbour —
    /// one unit in the last place away from the right answer. The default codec gets these right.
    /// Pinned as it is; if Foundation or the fallback changes, this says so.
    @Test func digitsPastTheThirtyEighthAreNotSeen() throws {
        let cases: [(text: String, nearest: Double, found: Double)] = [
            // 2^53 + 1 and a little: the right answer is 2^53 + 2.
            ("9007199254740993." + String(repeating: "0", count: 30) + "1", 9007199254740994, 9007199254740992),
            // 1 + 2^-53 and a little: the right answer is the Double after 1.
            ("1.00000000000000011102230246251565404236316680908203126", 1.0000000000000002, 1.0),
        ]
        for (text, nearest, found) in cases {
            #expect(Double(text) == nearest)
            let value = try JSON.parse(text)
            #expect(value.doubleValue == found, "\(text) came back as \(value)")
            #expect(abs(found - nearest) == nearest.ulp || abs(found - nearest) == found.ulp)
        }
        // The same digits cut to 38: nothing is lost, and the answer is right.
        #expect(try JSON.parse("9007199254740993." + String(repeating: "0", count: 20) + "1").doubleValue == 9007199254740994)
    }

    /// Below the Double range the fallback is not even consistent with itself: some underflows
    /// become zero, larger ones are errors. Pinned as observed; the default codec keeps both.
    @Test func underflow() throws {
        #expect(try JSON.parse("1e-400").description == "0.0")
        #expect(try JSON.parse("2e-324").description == "0.0")
        #expect(outcome("1e-1000").error == syntaxError)
    }

    /// Very long number literals must cost time proportional to their length and no stack.
    @Test func hugeLiteralsAreHarmless() {
        let million = 1_000_000
        let inputs = [
            String(repeating: "1", count: million),
            "0." + String(repeating: "1", count: million),
            "0." + String(repeating: "0", count: million) + "1",
            "1e" + String(repeating: "0", count: million) + "1",
            "1e-" + String(repeating: "0", count: million) + "1",
            "-" + String(repeating: "9", count: million) + "." + String(repeating: "9", count: million),
            "[" + Array(repeating: String(repeating: "9", count: 100), count: 10_000).joined(separator: ",") + "]",
        ]
        for input in inputs {
            let bytes = Array(input.utf8)
            let clock = ContinuousClock()
            var result: Outcome?
            let elapsed = clock.measure { result = onThread(stackSize: handlerStack) { outcome(bytes) } }
            // Accepted or refused, either is fine here; a crash or a stall is not.
            #expect(result != nil)
            #expect(elapsed < .seconds(5), "\(input.prefix(12))… took \(elapsed)")
            if let value = result?.value { #expect(value.encoded().count <= bytes.count + 2) }
        }
    }
}

// MARK: Depth

@Suite struct FoundationCodecDepthTests {
    /// Depths every build handles, including on a handler thread, with the structure intact.
    @Test func ordinaryNesting() throws {
        for depth in [1, 2, 16, 64, 100] {
            let arrays = nested("[", "]", depth, around: "7")
            let objects = nested("{\"a\":", "}", depth, around: "7")
            for input in [arrays, objects] {
                let bytes = Array(input.utf8)
                let here = try #require(outcome(bytes).value, "depth \(depth)")
                let there = try #require(onThread(stackSize: handlerStack) { outcome(bytes) }.value, "depth \(depth)")
                #expect(here == there)
                var cursor = here
                for _ in 0..<depth { cursor = try #require(cursor[0] ?? cursor["a"]) }
                #expect(cursor == 7)
                #expect(String(decoding: here.encoded(), as: UTF8.self) == input)
            }
        }
    }

    @Test func oneLevelBeyondTheCeilingIsRejected() {
        #expect(outcome(nested("[", "]", 129)).error == Refusal(kind: .depthLimitExceeded(128), offset: 128))
        #expect(outcome(nested("{\"a\":", "}", 129, around: "1")).error == Refusal(kind: .depthLimitExceeded(128), offset: 640))
        #expect(outcome(nested("[{\"a\":", "}]", 65, around: "1")).error?.kind == .depthLimitExceeded(128))
        // Unclosed: the check does not wait for the document to be complete.
        #expect(outcome(String(repeating: "[", count: 129)).error == Refusal(kind: .depthLimitExceeded(128), offset: 128))
        // Depth is what is open at once, not how many brackets there are.
        let siblings = "[" + Array(repeating: nested("[", "]", 20), count: 500).joined(separator: ",") + "]"
        #expect(outcome(siblings).value?.arrayValue?.count == 500)
    }

    @Test func aLowerLimitIsHonoured() {
        #expect(outcome("1", JSONParseOptions(maxDepth: 0)).value == 1)
        #expect(outcome("\"[\"", JSONParseOptions(maxDepth: 0)).value == "[")
        #expect(outcome("[]", JSONParseOptions(maxDepth: 0)).error == Refusal(kind: .depthLimitExceeded(0), offset: 0))
        #expect(outcome("{}", JSONParseOptions(maxDepth: 0)).error == Refusal(kind: .depthLimitExceeded(0), offset: 0))
        #expect(outcome("[]", JSONParseOptions(maxDepth: -1)).error?.kind == .depthLimitExceeded(-1))
        #expect(outcome("[]", JSONParseOptions(maxDepth: .min)).error != nil)
        #expect(outcome("1", JSONParseOptions(maxDepth: .min)).value == 1)
        #expect(outcome("[[[1]]]", JSONParseOptions(maxDepth: 3)).value == [[[1]]])
        #expect(outcome("[[[[1]]]]", JSONParseOptions(maxDepth: 3)).error == Refusal(kind: .depthLimitExceeded(3), offset: 3))
        #expect(outcome(#"{"a":{"a":{"a":1}}}"#, JSONParseOptions(maxDepth: 3)).value != nil)
        #expect(outcome(#"{"a":{"a":{"a":{}}}}"#, JSONParseOptions(maxDepth: 3)).error == Refusal(kind: .depthLimitExceeded(3), offset: 15))
        #expect(outcome(#"[{"a":[{}]}]"#, JSONParseOptions(maxDepth: 3)).error == Refusal(kind: .depthLimitExceeded(3), offset: 7))
        // Siblings do not add up.
        #expect(outcome("[[[1]],[[2]],[[3]]]", JSONParseOptions(maxDepth: 3)).value != nil)
        #expect(outcome("[[[1]],[[2]],[[[3]]]]", JSONParseOptions(maxDepth: 3)).error == Refusal(kind: .depthLimitExceeded(3), offset: 15))
    }

    /// The reason the pre-check exists: this much nesting kills the process inside Foundation.
    @Test func bottomlessNestingIsAnErrorNotACrash() {
        let inputs: [[UInt8]] = [
            Array(String(repeating: "[", count: 200_000).utf8),
            Array(String(repeating: "{\"a\":", count: 200_000).utf8),
            Array(nested("[", "]", 200_000).utf8),
            Array(nested("{\"a\":", "}", 200_000, around: "1").utf8),
            Array(nested("[{\"a\":", "}]", 100_000, around: "1").utf8),
            Array(String(repeating: "[", count: 513).utf8),
            Array(nested("{\"a\":", "}", 513, around: "1").utf8),
        ]
        for bytes in inputs {
            for options in [JSONParseOptions.default, JSONParseOptions(maxDepth: .max), JSONParseOptions(maxDepth: 200_000)] {
                #expect(outcome(bytes, options).error?.kind == .depthLimitExceeded(128))
                #expect(onThread(stackSize: handlerStack) { outcome(bytes, options) }.error?.kind == .depthLimitExceeded(128))
            }
        }
    }

    /// JSON source text of strings that a careless scanner would misread.
    static let trickyStrings: [String] = {
        var texts = [
            #""[[[[""#, #""]]]]""#, #""{{{{""#, #""}}}}""#, #""[{\"[{""#, #""\u0022[[[""#, #""\u005c""#, #""\u005C[[[""#,
            #""\/[[[""#, #""[[[\n[[[""#, "\"[[[é中😀[[[\"", #""'[[['""#, #""\\u005c\"[[[""#, #""[\t\"\\\"\\\\[""#,
            #""\ud83d\ude00[[[""#, #""[[[\u0000[[[""#,
        ]
        for count in 0...6 {
            let backslashes = String(repeating: #"\\"#, count: count)
            texts.append("\"[[" + backslashes + "\"")  // ends right after `count` escaped backslashes
            texts.append("\"[[" + backslashes + #"\"[["# + "\"")  // then an escaped quote and more brackets
        }
        return texts
    }()

    /// Brackets inside a string are text. Brackets after it count from where they really are.
    @Test(arguments: trickyStrings)
    func bracketsInsideStringsDoNotCount(_ string: String) throws {
        let none = JSONParseOptions(maxDepth: 0)
        let three = JSONParseOptions(maxDepth: 3)
        let text = try #require(outcome(string, none).value?.stringValue)
        // As an element.
        #expect(outcome("[\(string)]", JSONParseOptions(maxDepth: 1)).value == [.string(text)])
        #expect(outcome("[\(string),[[1]]]", three).value == [.string(text), [[1]]])
        #expect(
            outcome("[\(string),[[[1]]]]", three).error
                == Refusal(kind: .depthLimitExceeded(3), offset: string.utf8.count + 4))
        // As a key and as a member value.
        #expect(outcome("{\(string):[[1]]}", three).value == .object([text: [[1]]]))
        #expect(
            outcome("{\(string):[[[1]]]}", three).error
                == Refusal(kind: .depthLimitExceeded(3), offset: string.utf8.count + 4))
        #expect(outcome("{\"k\":\(string),\"d\":[[1]]}", three).value == ["k": .string(text), "d": [[1]]])
        #expect(outcome("{\"k\":\(string),\"d\":[[[1]]]}", three).error?.kind == .depthLimitExceeded(3))
        // Many of them in a row do not drift.
        let row = Array(repeating: string, count: 50).joined(separator: ",")
        #expect(outcome("[\(row),[[1]]]", three).value?.arrayValue?.count == 51)
        #expect(outcome("[\(row),[[[1]]]]", three).error?.kind == .depthLimitExceeded(3))
    }

    @Test func stringsFullOfBracketsAreAccepted() throws {
        let million = String(repeating: "[", count: 1_000_000)
        let mixed = String(repeating: "[{", count: 500_000)
        let closers = String(repeating: "]}", count: 500_000)
        for content in [million, mixed, closers] {
            let bytes = Array("\"\(content)\"".utf8)
            #expect(outcome(bytes).value == .string(content))
            #expect(onThread(stackSize: handlerStack) { outcome(bytes) }.value == .string(content))
            #expect(outcome(bytes, JSONParseOptions(maxDepth: 0)).value == .string(content))
        }
        let bracketKey = String(repeating: "[", count: 200_000)
        #expect(try JSON.parse("{\"\(bracketKey)\":\"\(bracketKey)\"}") == .object([bracketKey: .string(bracketKey)]))
        // An escaped quote first, so the string does not end where it seems to.
        let afterQuote = try JSON.parse("[\"\\\"" + bracketKey + "\"]")
        #expect(afterQuote == [.string("\"" + bracketKey)])
        let afterBackslash = try JSON.parse("[\"\\\\\\\"" + bracketKey + "\\\\\"]")
        #expect(afterBackslash == [.string("\\\"" + bracketKey + "\\")])
    }
}

// MARK: Getting past the pre-check

/// Input built to make a bracket counter and a real JSON lexer disagree about where strings
/// begin and end, so that nesting the counter never saw would reach Foundation. Every one of
/// these is invalid JSON: the only acceptable result is an error, on any stack.
struct HostileInput: Sendable, CustomTestStringConvertible {
    let name: String
    let bytes: [UInt8]
    var testDescription: String { name }

    init(_ name: String, _ text: String) {
        self.name = name
        self.bytes = Array(text.utf8)
    }

    static let all: [HostileInput] = {
        let deepArrays = String(repeating: "[", count: 200_000)
        let deepObjects = String(repeating: "{\"a\":", count: 200_000)
        var inputs: [HostileInput] = []
        // A quote where no string may start: the counter enters "string" mode, the lexer stops.
        for (name, prefix) in [
            ("after an element", "[1 \""), ("glued to a number", "[1\""), ("glued to a literal", "[true\""),
            ("after a key", "{\"a\" \""), ("after a member", "{\"a\":1 \""), ("after a top-level value", "1\""),
            ("after a closed string", "[\"a\"\""), ("after a closed array", "[]\""), ("after a colon twice", "{\"a\":\"b\"\""),
            ("in place of a key", "{1,\""), ("after a minus", "[-\""), ("after an exponent", "[1e\""),
        ] {
            inputs.append(HostileInput("stray quote \(name), arrays", prefix + deepArrays))
            inputs.append(HostileInput("stray quote \(name), objects", prefix + deepObjects))
        }
        // A string that never ends.
        inputs.append(HostileInput("unterminated string", "\"" + deepArrays))
        inputs.append(HostileInput("unterminated string in an array", "[\"" + deepArrays))
        inputs.append(HostileInput("unterminated key", "{\"" + deepObjects))
        inputs.append(HostileInput("unterminated string ending in a backslash", "[\"" + deepArrays + "\\"))
        // An error inside a string, then a second string holding the nesting.
        for (name, broken) in [
            ("bad escape", #""\x""#), ("raw newline", "\"\n\""), ("raw tab", "\"\t\""), ("short \\u", #""\u12""#),
            ("lone high surrogate", #""\ud83d""#), ("lone low surrogate", #""\ude00""#),
        ] {
            inputs.append(HostileInput("\(name), then a string of brackets", "[\(broken),\"" + deepArrays + "\"]"))
            inputs.append(HostileInput("\(name), then real brackets", "[\(broken)," + deepArrays))
        }
        // Escapes whose last backslash swallows the closing quote for the counter only if the
        // lexer were to forgive the escape before it.
        inputs.append(HostileInput("broken \\u before an escaped quote", "[\"\\u00\\\"," + deepArrays + "\"]"))
        inputs.append(HostileInput("high surrogate before an escaped quote", "[\"\\ud83d\\\"," + deepArrays + "\"]"))
        inputs.append(HostileInput("bad escape before an escaped quote", "[\"\\x\\\"," + deepArrays + "\"]"))
        inputs.append(HostileInput("escaped backslash, then real brackets", "[\"\\\\\"," + deepArrays))
        inputs.append(HostileInput("three backslashes and a quote, then brackets", "[\"\\\\\\\"\"," + deepArrays))
        inputs.append(HostileInput("unicode-escaped quote, then real brackets", "[\"\\u0022\"," + deepArrays))
        inputs.append(HostileInput("unicode-escaped backslash, then real brackets", "[\"\\u005c\"," + deepArrays))
        // Closers that keep the counter low while nothing is really closed.
        inputs.append(HostileInput("array opened, object closed, repeated", String(repeating: "[}", count: 200_000)))
        inputs.append(HostileInput("object opened, array closed, repeated", String(repeating: "{]", count: 200_000)))
        inputs.append(HostileInput("key then wrong closer, repeated", String(repeating: "{\"a\":]", count: 200_000)))
        inputs.append(HostileInput("closers first", String(repeating: "]", count: 200_000) + deepArrays))
        inputs.append(HostileInput("closers first, objects", String(repeating: "}", count: 200_000) + deepObjects))
        inputs.append(HostileInput("a value, closers, then brackets", "[]" + String(repeating: "]", count: 1000) + deepArrays))
        inputs.append(HostileInput("empty pairs with no commas", String(repeating: "[]", count: 200_000)))
        inputs.append(HostileInput("open, close, open deeper", String(repeating: "[[]", count: 200_000)))
        // Nesting that only begins after the text is already invalid.
        inputs.append(HostileInput("after a bad token", "[1,2,x" + deepArrays))
        inputs.append(HostileInput("after trailing data", "1 " + deepArrays))
        inputs.append(HostileInput("after a complete document", "{} " + deepObjects))
        inputs.append(HostileInput("after a missing colon", "{\"a\" " + deepObjects))
        inputs.append(HostileInput("after a missing comma", "[1 " + deepArrays))
        inputs.append(HostileInput("after a comment", "/*" + deepArrays + "*/1"))
        inputs.append(HostileInput("inside single quotes", "['" + deepArrays + "']"))
        inputs.append(HostileInput("after a trailing comma at every level", String(repeating: "[1,", count: 200_000)))
        inputs.append(HostileInput("commas only", "[" + String(repeating: ",", count: 1_000_000) + "]"))
        inputs.append(HostileInput("colons only", "{" + String(repeating: ":", count: 1_000_000) + "}"))
        return inputs
    }()
}

@Suite struct FoundationCodecPrecheckTests {
    @Test(arguments: HostileInput.all)
    func hostileInputIsAnErrorNotACrash(_ input: HostileInput) {
        let bytes = input.bytes
        for options in [JSONParseOptions.default, JSONParseOptions(maxDepth: .max)] {
            #expect(outcome(bytes, options).error != nil)
            #expect(onThread(stackSize: handlerStack) { outcome(bytes, options) }.error != nil)
        }
    }

    /// The same texts as `String`, which skips UTF-8 validation and goes straight to the pre-check.
    @Test func hostileInputThroughTheStringEntryPoint() {
        for input in HostileInput.all {
            let text = String(decoding: input.bytes, as: UTF8.self)
            #expect(outcome(text).error != nil, "\(input.name)")
        }
    }

    /// Wide rather than deep: nothing here should cost stack.
    @Test func wideDocumentsOnAHandlerThread() {
        let siblings = Array(("[" + Array(repeating: "[]", count: 200_000).joined(separator: ",") + "]").utf8)
        #expect(onThread(stackSize: handlerStack) { outcome(siblings) }.value?.arrayValue?.count == 200_000)
        let zigzag = Array(("[" + String(repeating: "[[]],", count: 100_000) + "1]").utf8)
        #expect(onThread(stackSize: handlerStack) { outcome(zigzag) }.value?.arrayValue?.count == 100_001)
        let members = (0..<100_000).map { "\"k\($0)\":[\($0)]" }.joined(separator: ",")
        let object = Array(("{" + members + "}").utf8)
        #expect(onThread(stackSize: handlerStack) { outcome(object) }.value?.objectValue?.count == 100_000)
        let longKey = String(repeating: "k", count: 1_000_000)
        let keyed = Array("{\"\(longKey)\":1}".utf8)
        #expect(onThread(stackSize: handlerStack) { outcome(keyed) }.value == .object([longKey: 1]))
    }
}

// MARK: Encodings

@Suite struct FoundationCodecEncodingTests {
    static let document = #"{"a":[1,"b",true]}"#

    /// `JSONSerialization` would happily sniff and decode all of these. The protocol is UTF-8 only.
    @Test func otherUnicodeEncodingsAreRejected() {
        func encoded(_ text: String, _ encoding: String.Encoding) -> [UInt8] { Array(text.data(using: encoding)!) }
        for text in [Self.document, "1", "\"a\"", "[]", "null"] {
            let utf16le = encoded(text, .utf16LittleEndian)
            let utf16be = encoded(text, .utf16BigEndian)
            let utf32le = encoded(text, .utf32LittleEndian)
            let utf32be = encoded(text, .utf32BigEndian)
            // Without a byte order mark ASCII text in these encodings is valid UTF-8 full of zero
            // bytes; the first zero is what gives it away.
            #expect(outcome(utf16le).error == Refusal(kind: .unexpectedByte(0), offset: 1), "\(text)")
            #expect(outcome(utf16be).error == Refusal(kind: .unexpectedByte(0), offset: 0), "\(text)")
            #expect(outcome(utf32le).error == Refusal(kind: .unexpectedByte(0), offset: 1), "\(text)")
            #expect(outcome(utf32be).error == Refusal(kind: .unexpectedByte(0), offset: 0), "\(text)")
            // With one, the mark itself is not UTF-8.
            #expect(outcome([0xFF, 0xFE] + utf16le).error?.kind == .invalidUTF8, "\(text)")
            #expect(outcome([0xFE, 0xFF] + utf16be).error?.kind == .invalidUTF8, "\(text)")
            #expect(outcome([0xFF, 0xFE, 0x00, 0x00] + utf32le).error?.kind == .invalidUTF8, "\(text)")
            #expect(outcome([0x00, 0x00, 0xFE, 0xFF] + utf32be).error?.kind == .invalidUTF8, "\(text)")
            // The same bytes arriving as a String: no validation step, only the zero-byte check.
            #expect(outcome(String(decoding: utf16le, as: UTF8.self)).error?.kind == .unexpectedByte(0), "\(text)")
            #expect(outcome(String(decoding: utf32be, as: UTF8.self)).error?.kind == .unexpectedByte(0), "\(text)")
        }
        // Non-ASCII content in UTF-16 is not UTF-8 at all.
        #expect(outcome(encoded("\"é\"", .utf16LittleEndian)).error != nil)
        #expect(outcome(encoded("\"中\"", .utf16BigEndian)).error != nil)
        #expect(outcome(encoded("\"😀\"", .utf32LittleEndian)).error != nil)
    }

    @Test func zeroBytesAreRejectedAnywhere() {
        let bytes = Array(Self.document.utf8)
        for index in 0...bytes.count {
            var poisoned = bytes
            poisoned.insert(0, at: index)
            #expect(outcome(poisoned).error == Refusal(kind: .unexpectedByte(0), offset: index), "inserted at \(index)")
            #expect(
                outcome(String(decoding: poisoned, as: UTF8.self)).error == Refusal(kind: .unexpectedByte(0), offset: index),
                "inserted at \(index), as String")
        }
        for index in bytes.indices {
            var poisoned = bytes
            poisoned[index] = 0
            #expect(outcome(poisoned).error == Refusal(kind: .unexpectedByte(0), offset: index), "replaced at \(index)")
        }
        #expect(outcome([0]).error == Refusal(kind: .unexpectedByte(0), offset: 0))
        #expect(outcome([0, 0, 0, 0]).error == Refusal(kind: .unexpectedByte(0), offset: 0))
        #expect(outcome([0x22, 0x00, 0x22]).error == Refusal(kind: .unexpectedByte(0), offset: 1))
        #expect(outcome([0x31, 0x00]).error == Refusal(kind: .unexpectedByte(0), offset: 1))
        #expect(outcome([0x20, 0x00, 0x31]).error == Refusal(kind: .unexpectedByte(0), offset: 1))
        // The escape is the only way to put U+0000 into a string.
        #expect(outcome(#""\u0000""#).value == "\u{0}")
    }

    @Test func byteOrderMarkIsRejected() {
        let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
        let refused = Refusal(kind: .unexpectedByte(0xEF), offset: 0)
        for text in [Self.document, "1", "\"a\"", "[]", "", " "] {
            #expect(outcome(mark + Array(text.utf8)).error == refused, "\(text)")
            #expect(outcome("\u{FEFF}" + text).error == refused, "\(text)")
        }
        #expect(outcome(mark + mark + Array("1".utf8)).error == refused)
        // Anywhere but the very start it is simply not JSON.
        #expect(outcome([0x20] + mark + Array("1".utf8)).error == syntaxError)
        #expect(outcome([0x0A] + mark + Array("[1]".utf8)).error == syntaxError)
        #expect(outcome(Array("1".utf8) + mark).error == syntaxError)
        #expect(outcome(Array("[".utf8) + mark + Array("1]".utf8)).error == syntaxError)
        // A truncated mark is not UTF-8.
        #expect(outcome([0xEF, 0xBB]).error?.kind == .invalidUTF8)
        #expect(outcome([0xEF, 0xBB, 0x31]).error?.kind == .invalidUTF8)
        // Inside a string, after its first character, U+FEFF is an ordinary character.
        #expect(outcome("\"a\u{FEFF}\"").value == "a\u{FEFF}")
        #expect(outcome("\"a\u{FEFF}b\u{FEFF}\"").value == "a\u{FEFF}b\u{FEFF}")
        #expect(outcome(#""a\ufeff""#).value == "a\u{FEFF}")
    }

    @Test(arguments: [
        [0xFF], [0xFE], [0x80], [0xBF], [0xC0, 0xAF], [0xC1, 0xBF], [0xC3], [0xC3, 0x28], [0xE2, 0x82],
        [0xE2, 0x28, 0xA1], [0xE0, 0x80, 0xAF], [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80],
        [0xF0, 0x9F, 0x98], [0xF0, 0x80, 0x80, 0xAF], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
        [0xF8, 0x88, 0x80, 0x80, 0x80], [0xE9], [0xC3, 0xA9, 0xA9],
    ] as [[UInt8]])
    func invalidUTF8IsRejected(_ sequence: [UInt8]) {
        let start = sequence == [0xC3, 0xA9, 0xA9] ? 2 : 0
        func refused(after prefix: Int) -> Refusal { Refusal(kind: .invalidUTF8, offset: prefix + start) }
        // In a string, in a key, between tokens, at either end.
        #expect(outcome([0x22] + sequence + [0x22]).error == refused(after: 1))
        #expect(outcome([0x22, 0x61] + sequence + [0x62, 0x22]).error == refused(after: 2))
        #expect(outcome(Array("{\"".utf8) + sequence + Array("\":1}".utf8)).error == refused(after: 2))
        #expect(outcome(Array("[1,".utf8) + sequence + Array("2]".utf8)).error == refused(after: 3))
        #expect(outcome(sequence + Array("1".utf8)).error == refused(after: 0))
        #expect(outcome(Array("1".utf8) + sequence).error == refused(after: 1))
        #expect(outcome(sequence).error == refused(after: 0))
        // Behind an escape, where a lazy scanner might skip a byte.
        #expect(outcome([0x22, 0x5C] + sequence + [0x22]).error != nil)
    }
}

// MARK: Strings and keys

@Suite struct FoundationCodecStringTests {
    @Test func everyEscape() throws {
        #expect(try JSON.parse(#""\"""#) == "\"")
        #expect(try JSON.parse(#""\\""#) == "\\")
        #expect(try JSON.parse(#""\/""#) == "/")
        #expect(try JSON.parse(#""\b""#) == "\u{08}")
        #expect(try JSON.parse(#""\f""#) == "\u{0C}")
        #expect(try JSON.parse(#""\n""#) == "\n")
        #expect(try JSON.parse(#""\r""#) == "\r")
        #expect(try JSON.parse(#""\t""#) == "\t")
        #expect(try JSON.parse(#""a\"b\\c\/d\b\f\n\r\te""#) == "a\"b\\c/d\u{08}\u{0C}\n\r\te")
        #expect(try JSON.parse(#""\\n""#) == "\\n")
        #expect(try JSON.parse(#""\\\\""#) == "\\\\")
        #expect(try JSON.parse(#""\\\"""#) == "\\\"")
        #expect(try JSON.parse(#""\\u0041""#) == "\\u0041")
        #expect(try JSON.parse(#""/""#) == "/")
    }

    @Test func unicodeEscapes() throws {
        #expect(try JSON.parse(#""\u0041""#) == "A")
        #expect(try JSON.parse(#""\u00e9""#) == "\u{E9}")
        #expect(try JSON.parse(#""\u00E9""#) == "\u{E9}")
        #expect(try JSON.parse(#""\u00e9\u00E9""#) == "\u{E9}\u{E9}")
        #expect(try JSON.parse(#""\u4e2d\u4E2D""#) == "中中")
        #expect(try JSON.parse(#""e\u0301""#) == "e\u{301}")
        #expect(try JSON.parse(#""\u0022\u005c\u002f""#) == "\"\\/")
        #expect(try JSON.parse(#""\u000a\u000d\u0009""#) == "\n\r\t")
        #expect(try JSON.parse(#""\u007f""#) == "\u{7F}")
        #expect(try JSON.parse(#""\u2028\u2029""#) == "\u{2028}\u{2029}")
        // Noncharacters are scalars like any other. (Swift has no literal for U+FDD0.)
        #expect(try JSON.parse(#""\uffff\ufffe\ufdd0""#) == .string("\u{FFFF}\u{FFFE}" + String(Unicode.Scalar(0xFDD0 as UInt32)!)))
        #expect(try JSON.parse(#""\ud7ff\ue000""#) == "\u{D7FF}\u{E000}")
        // Surrogate pairs, in either hex case, become one scalar.
        #expect(try JSON.parse(#""\ud83d\ude00""#) == "😀")
        #expect(try JSON.parse(#""\uD83D\uDE00""#) == "😀")
        #expect(try JSON.parse(#""\uD83d\uDe00""#) == "😀")
        #expect(try JSON.parse(#""\ud800\udc00""#) == "\u{10000}")
        #expect(try JSON.parse(#""\udbff\udfff""#) == "\u{10FFFF}")
        #expect(try JSON.parse(#""a\ud83d\ude00b\ud83d\ude00""#) == "a😀b😀")
        // The escaped and the raw spelling are the same string, byte for byte.
        #expect(try JSON.parse(#""\ud83d\ude00""#) == JSON.parse("\"😀\""))
        #expect(try JSON.parse(#""\u00e9""#).stringValue.map { Array($0.utf8) } == [0xC3, 0xA9])
        #expect(try JSON.parse(#""e\u0301""#).stringValue.map { Array($0.utf8) } == [0x65, 0xCC, 0x81])
    }

    /// Every `\uXXXX` escape of the Basic Multilingual Plane, in both hex cases, at the start, in
    /// the middle and at the end of a string. U+FEFF is left to `aStringMayStartWithAByteOrderMark`.
    @Test func everyBasicPlaneEscapeDecodes() throws {
        let hex = Array("0123456789abcdef")
        func escape(_ value: UInt32, uppercase: Bool) -> String {
            let digits = String([hex[Int(value >> 12)], hex[Int(value >> 8 & 0xF)], hex[Int(value >> 4 & 0xF)], hex[Int(value & 0xF)]])
            return "\\u" + (uppercase ? digits.uppercased() : digits)
        }
        var start: UInt32 = 0
        while start < 0x10000 {
            var sources: [String] = []
            var expected: [String] = []
            for value in start..<(start + 0x1000) where value != 0xFEFF {
                guard let scalar = Unicode.Scalar(value) else { continue }  // surrogates
                let lower = escape(value, uppercase: false)
                let upper = escape(value, uppercase: true)
                sources.append("\"\(lower)\",\"\(upper)x\",\"x\(lower)\",\"x\(upper)y\"")
                let single = String(scalar)
                expected.append(contentsOf: [single, single + "x", "x" + single, "x" + single + "y"])
            }
            let parsed = try JSON.parse("[" + sources.joined(separator: ",") + "]")
            let items = try #require(parsed.arrayValue)
            try #require(items.count == expected.count)
            for (index, text) in expected.enumerated() where items[index] != .string(text) {
                Issue.record("escape near U+\(String(start, radix: 16)), item \(index), decoded to \(items[index])")
            }
            start += 0x1000
        }
    }

    @Test func embeddedNull() throws {
        let value = try JSON.parse(#""a\u0000b""#)
        #expect(value == "a\u{0}b")
        #expect(value.stringValue?.utf8.count == 3)
        #expect(value.description == #""a\u0000b""#)
        #expect(try JSON.parse(value.encoded()) == value)
        #expect(try JSON.parse(#""\u0000""#).stringValue?.utf8.count == 1)
        #expect(try JSON.parse(#""\u0000\u0000tail""#) == "\u{0}\u{0}tail")
        // Not a terminator anywhere on the way: what follows it is still there.
        #expect(try JSON.parse(#"["x\u0000y","z"]"#) == ["x\u{0}y", "z"])
        let object = try JSON.parse(#"{"k\u0000":1,"k":2,"k\u0000\u0000":3}"#)
        #expect(object.objectValue?.count == 3)
        #expect(object["k\u{0}"] == 1 && object["k"] == 2 && object["k\u{0}\u{0}"] == 3)
    }

    @Test(arguments: [
        #""\ud800""#, #""\udbff""#, #""\udc00""#, #""\udfff""#, #""\ud83d""#, #""\ude00""#, #""\ud83dA""#,
        #""\ud83d\u0041""#, #""\ud83d\ud83d""#, #""\ude00\ud83d""#, #""\ud83d\n""#, #""\ud83d\\""#, #""a\ud83d""#,
        #""\ud83d\ude0""#, #""\ud83d\u""#, #""\ud83d\ud""#, #""\ud83d ""#, #""\ud83d\ude00\ud83d""#,
        #""\ud83d\ude00\ude00""#, #"["\ud800"]"#, #"{"\ud800":1}"#, #"{"a":"\udc00"}"#, #""\uD800\uD800\uDC00""#,
    ])
    func loneSurrogatesAreRejected(_ text: String) {
        #expect(outcome(text).error != nil)
    }

    @Test func rawControlCharactersAreRejected() {
        for byte in UInt8(1)..<0x20 {
            let hex = String(byte, radix: 16)
            #expect(outcome([0x22, byte, 0x22]).error == syntaxError, "0x\(hex) alone")
            #expect(outcome([0x22, 0x61, byte, 0x62, 0x22]).error == syntaxError, "0x\(hex) inside")
            #expect(outcome(Array("{\"".utf8) + [byte] + Array("\":1}".utf8)).error == syntaxError, "0x\(hex) in a key")
            #expect(outcome(Array("[\"long enough to leave any fast path ".utf8) + [byte] + Array("\"]".utf8)).error == syntaxError, "0x\(hex) late")
            // Outside strings only tab, line feed and carriage return mean anything.
            let isWhitespace = byte == 0x09 || byte == 0x0A || byte == 0x0D
            #expect((outcome([byte, 0x31]).value == 1) == isWhitespace, "0x\(hex) before a value")
            #expect((outcome([0x31, byte]).value == 1) == isWhitespace, "0x\(hex) after a value")
            #expect((outcome([0x5B, 0x31, 0x2C, byte, 0x32, 0x5D]).value == [1, 2]) == isWhitespace, "0x\(hex) between elements")
        }
    }

    /// Characters that look dangerous and are perfectly legal inside a JSON string.
    @Test func legalOddities() throws {
        #expect(try JSON.parse("\"\u{7F}\"") == "\u{7F}")
        #expect(try JSON.parse("\"\u{80}\u{9F}\"") == "\u{80}\u{9F}")
        #expect(try JSON.parse("\"\u{2028}\u{2029}\"") == "\u{2028}\u{2029}")
        #expect(try JSON.parse("\"\u{85}\u{A0}\u{200B}\"") == "\u{85}\u{A0}\u{200B}")
        #expect(try JSON.parse("\"\u{FFFF}\u{FFFE}\u{10FFFF}\"") == "\u{FFFF}\u{FFFE}\u{10FFFF}")
        #expect(try JSON.parse("\"\u{202E}evil\"") == "\u{202E}evil")
        #expect(try JSON.parse("\"\"") == "")
        #expect(try JSON.parse("\" \"") == " ")
        #expect(try JSON.parse("\"'\"") == "'")
        #expect(try JSON.parse("\"//comment\"") == "//comment")
        #expect(try JSON.parse("\"/* */\"") == "/* */")
        #expect(try JSON.parse("\"null\"") == "null")
        #expect(try JSON.parse("\"1\"") == "1")
        #expect(try JSON.parse("\"1\"") != 1)
        #expect(try JSON.parse("\"true\"") != true)
        #expect(try JSON.parse(#""data:text/plain;base64,aGk=""#) == "data:text/plain;base64,aGk=")
        #expect(try JSON.parse("\"2026-11-16T00:00:00Z\"") == "2026-11-16T00:00:00Z")
    }

    /// `JSONSerialization` removes a U+FEFF that opens a string, raw or escaped, in values and
    /// in keys. The fallback refuses such a string instead: the error is `.malformed` at the
    /// opening quote. Every spelling of the character has to be caught, wherever the string is.
    static let stringsOpeningWithAByteOrderMark: [(text: String, quote: Int)] = [
        // text, offset of the opening quote
        ("\"\u{FEFF}\"", 0), ("\"\u{FEFF}x\"", 0), ("\"\u{FEFF}\u{FEFF}x\"", 0),
        (#""\ufeff""#, 0), (#""\uFEFF""#, 0), (#""\uFeFf""#, 0), (#""\ufEfF""#, 0), (#""\uFEff""#, 0), (#""\ufeFF""#, 0),
        (#""\ufeffx""#, 0), (#""\ufeff\ufeffx""#, 0), ("\"\\ufeff\u{FEFF}\"", 0), ("\"\u{FEFF}\\ufeff\"", 0),
        (#""\ufeff\u0000""#, 0), (#""\ufeff\"""#, 0), (#""\ufeff\\""#, 0), (#""\ufeff\ud83d\ude00""#, 0),
        (#" "\ufeff""#, 1), ("\n\t\"\u{FEFF}\"\n", 2),
        (#"["\ufeffa","a"]"#, 1), (#"["a","\ufeffa"]"#, 5), (#"["","\ufeff"]"#, 4), (#"[1,[2,["\uFEFF"]]]"#, 7),
        (#"{"\ufeffa":1,"a":2}"#, 1), (#"{"a":2,"\ufeffa":1}"#, 7), ("{\"\u{FEFF}a\":1,\"a\":2}", 1),
        (#"{"\ufeff":1,"":2}"#, 1), (#"{"a":"\ufeff"}"#, 5), (#"{"a":{"b":[{"\ufeffk":1}]}}"#, 12),
        (#"["\\","\ufeff"]"#, 6), (#"["\"","\ufeff"]"#, 6), (#"["\\\"","\ufeff"]"#, 8), (#"["[\"","\uFEFF"]"#, 7),
        (#"{"\\":"\ufeff"}"#, 6), (#"["x\ufeff","\ufeff"]"#, 11),
    ]

    @Test(arguments: stringsOpeningWithAByteOrderMark.indices)
    func aStringStartingWithAByteOrderMarkIsRejected(_ index: Int) {
        let (text, quote) = Self.stringsOpeningWithAByteOrderMark[index]
        let refused = Refusal(kind: .malformed, offset: quote)
        #expect(outcome(text).error == refused)
        #expect(outcome(Array(text.utf8)).error == refused)
        #expect(onThread(stackSize: handlerStack) { outcome(text) }.error == refused)
    }

    /// A key that starts with U+FEFF at the deepest level the codec accepts.
    @Test func aByteOrderMarkKeyIsFoundAtAnyDepth() {
        for depth in [1, 2, 64, 127] {
            let prefix = String(repeating: "{\"a\":", count: depth)
            let text = prefix + #"{"\ufeffk":1}"# + String(repeating: "}", count: depth)
            #expect(outcome(text).error == Refusal(kind: .malformed, offset: prefix.utf8.count + 1), "depth \(depth)")
            let plain = prefix + #"{"k\ufeff":1}"# + String(repeating: "}", count: depth)
            #expect(outcome(plain).value != nil, "depth \(depth)")
        }
    }

    /// Everywhere but at the start of a string U+FEFF is an ordinary character, and text that
    /// merely looks like the escape is ordinary text. None of this may be refused or altered.
    static let stringsWithAByteOrderMarkElsewhere: [(text: String, expected: String?)] = [
        // source text, the string it spells (nil: not valid JSON)
        ("\"a\u{FEFF}\"", "a\u{FEFF}"), (#""a\ufeff""#, "a\u{FEFF}"), ("\"a\u{FEFF}b\"", "a\u{FEFF}b"),
        ("\"a\u{FEFF}\u{FEFF}b\"", "a\u{FEFF}\u{FEFF}b"), (#""a\ufeff\uFEFF""#, "a\u{FEFF}\u{FEFF}"),
        // Right after an escape, where a decoder that works in runs starts a new run.
        ("\"\\n\u{FEFF}x\"", "\n\u{FEFF}x"), (#""\n\ufeffx""#, "\n\u{FEFF}x"),
        ("\"\\\"\u{FEFF}x\"", "\"\u{FEFF}x"), (#""\"\ufeffx""#, "\"\u{FEFF}x"),
        ("\"\\\\\u{FEFF}\"", "\\\u{FEFF}"), (#""\\\ufeff""#, "\\\u{FEFF}"),
        ("\"\\u0041\u{FEFF}\"", "A\u{FEFF}"), (#""\u0041\ufeff""#, "A\u{FEFF}"),
        ("\"\\ud83d\\ude00\u{FEFF}\"", "😀\u{FEFF}"), (#""\ud83d\ude00\ufeff""#, "😀\u{FEFF}"),
        (#""\u0000\ufeff""#, "\u{0}\u{FEFF}"), ("\"\\u0000\u{FEFF}x\"", "\u{0}\u{FEFF}x"), (#""\/\ufeff""#, "/\u{FEFF}"),
        // After other characters of every width.
        ("\"é\u{FEFF}\"", "é\u{FEFF}"), ("\"中\u{FEFF}\"", "中\u{FEFF}"), ("\"😀\u{FEFF}\"", "😀\u{FEFF}"),
        ("\" \u{FEFF}\"", " \u{FEFF}"), ("\"\u{200B}\u{FEFF}\"", "\u{200B}\u{FEFF}"), ("\"\u{FFFE}\u{FEFF}\"", "\u{FFFE}\u{FEFF}"),
        // An escaped backslash followed by the letters of the escape is six characters of text.
        (#""\\uFEFF""#, "\\uFEFF"), (#""\\ufeff""#, "\\ufeff"), (#""\\ufeffx""#, "\\ufeffx"), (#""\\\\ufeff""#, "\\\\ufeff"),
        (#""\\\\\ufeff""#, "\\\\\u{FEFF}"), (#""ufeff""#, "ufeff"), (#""uFEFF\ufeff""#, "uFEFF\u{FEFF}"),
        // Near misses of the escape and of the bytes.
        (#""\ufefe""#, "\u{FEFE}"), (#""\ufeef""#, "\u{FEEF}"), (#""\ufffe""#, "\u{FFFE}"), (#""\ufef""#, nil),
        (#""\ufeffe""#, nil), (#""\ufe0f""#, "\u{FE0F}"), (#""\uffef""#, "\u{FFEF}"), (#""\ueeff""#, "\u{EEFF}"),
        (#""\u00ef\u00bb\u00bf""#, "\u{EF}\u{BB}\u{BF}"), ("\"\u{EF}\u{BB}\u{BF}\"", "\u{EF}\u{BB}\u{BF}"),
        ("\"\u{FEFE}\"", "\u{FEFE}"), ("\"\u{FFFE}\"", "\u{FFFE}"), ("\"\u{FFFE}x\"", "\u{FFFE}x"), ("\"\u{FEEF}\"", "\u{FEEF}"),
        ("\"\u{FBFF}\"", "\u{FBFF}"), ("\"\u{EFBB}\u{BF}\"", "\u{EFBB}\u{BF}"), ("\"\u{FE}\u{FF}\"", "\u{FE}\u{FF}"),
        (#""\u00fe\u00ff""#, "\u{FE}\u{FF}"), (#""\u00ff\u00fe""#, "\u{FF}\u{FE}"),
        // Other invisible characters at the start: only U+FEFF is special.
        (#""\u200bx""#, "\u{200B}x"), (#""\u2060x""#, "\u{2060}x"), (#""\u00adx""#, "\u{AD}x"), (#""\u180ex""#, "\u{180E}x"),
        (#""\ufff9\ufffa\ufffb""#, "\u{FFF9}\u{FFFA}\u{FFFB}"), (#""\udb40\udc01x""#, "\u{E0001}x"),
        (#""\ud83f\udeff""#, "\u{1FEFF}"), (#""\udbbf\udeff""#, "\u{FFEFF}"), (#""\ufe00\ufeff""#, "\u{FE00}\u{FEFF}"),
    ]

    @Test(arguments: stringsWithAByteOrderMarkElsewhere.indices)
    func aByteOrderMarkElsewhereIsKept(_ index: Int) throws {
        let (text, expected) = Self.stringsWithAByteOrderMarkElsewhere[index]
        guard let expected else {
            // Not valid JSON at all, and must not be mistaken for anything else.
            #expect(outcome(text).error != nil)
            return
        }
        let value = try JSON.parse(text)
        #expect(value == .string(expected))
        #expect(value.stringValue.map { Array($0.utf8) } == Array(expected.utf8))
        // As a key and as an element, through both entry points, and written back.
        let object = try JSON.parse(Array("{\(text):[\(text)]}".utf8))
        #expect(object.objectValue?.count == 1)
        #expect(object[expected] == [.string(expected)])
        #expect(try JSON.parse(value.encoded()) == value)
    }

    /// The sweep of `everyBasicPlaneEscapeDecodes` for the planes above: every 7th scalar as a
    /// surrogate pair escape, first, in the middle and last.
    @Test func surrogatePairEscapesDecode() throws {
        let hex = Array("0123456789abcdef")
        func unit(_ value: UInt32, uppercase: Bool) -> String {
            let digits = String([hex[Int(value >> 12)], hex[Int(value >> 8 & 0xF)], hex[Int(value >> 4 & 0xF)], hex[Int(value & 0xF)]])
            return "\\u" + (uppercase ? digits.uppercased() : digits)
        }
        var sources: [String] = []
        var expected: [String] = []
        func check() throws {
            guard !sources.isEmpty else { return }
            let parsed = try JSON.parse("[" + sources.joined(separator: ",") + "]")
            let items = try #require(parsed.arrayValue)
            try #require(items.count == expected.count)
            for (index, text) in expected.enumerated() where items[index] != .string(text) {
                Issue.record("pair for U+\(String(text.unicodeScalars.first { $0.value > 0xFFFF }?.value ?? 0, radix: 16)) decoded to \(items[index])")
            }
            sources.removeAll(keepingCapacity: true)
            expected.removeAll(keepingCapacity: true)
        }
        for value in stride(from: UInt32(0x10000), through: 0x10FFFF, by: 7) {
            let offset = value - 0x10000
            let uppercase = value % 2 == 0
            let pair = unit(0xD800 + (offset >> 10), uppercase: uppercase) + unit(0xDC00 + (offset & 0x3FF), uppercase: !uppercase)
            let single = String(Unicode.Scalar(value)!)
            sources.append("\"\(pair)\",\"\(pair)x\",\"x\(pair)y\",\"x\(pair)\"")
            expected.append(contentsOf: [single, single + "x", "x" + single + "y", "x" + single])
            if sources.count == 2048 { try check() }
        }
        try check()
    }

    @Test func textIsNotNormalized() throws {
        let composed = "\u{E9}"
        let decomposed = "e\u{301}"
        #expect(try JSON.parse("\"\(composed)\"") == .string(composed))
        #expect(try JSON.parse("\"\(decomposed)\"") == .string(decomposed))
        #expect(try JSON.parse("\"\(composed)\"") != .string(decomposed))
        #expect(try JSON.parse("\"\(decomposed)\"").stringValue.map { Array($0.utf8) } == Array(decomposed.utf8))
        #expect(try JSON.parse("[\"\(composed)\",\"\(decomposed)\"]").encoded() == Array("[\"\(composed)\",\"\(decomposed)\"]".utf8))
        // Hangul, the angstrom sign and a compatibility ligature: none may be folded.
        for text in ["\u{AC00}", "\u{1100}\u{1161}", "\u{212B}", "\u{C5}", "A\u{30A}", "\u{FB01}", "\u{2126}", "\u{3A9}"] {
            #expect(try JSON.parse("\"\(text)\"").stringValue.map { Array($0.utf8) } == Array(text.utf8), "\(text.unicodeScalars.map(\.value))")
        }
    }

    @Test func canonicallyEquivalentKeysStayDistinct() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)  // Swift's view
        let object = try JSON.parse("{\"\(composed)\":1,\"\(decomposed)\":2}")
        #expect(object.objectValue?.count == 2)
        #expect(object[composed] == 1)
        #expect(object[decomposed] == 2)
        // The other order, so that neither answer is just "the first one".
        let reversed = try JSON.parse("{\"\(decomposed)\":2,\"\(composed)\":1}")
        #expect(reversed.objectValue?.count == 2)
        #expect(reversed[composed] == 1 && reversed[decomposed] == 2)
        #expect(reversed == object)
        // Written with escapes instead of raw bytes.
        let escaped = try JSON.parse(#"{"caf\u00e9":1,"cafe\u0301":2}"#)
        #expect(escaped == object)
        // Three spellings of the same letter.
        let angstrom = try JSON.parse("{\"\u{212B}\":1,\"\u{C5}\":2,\"A\u{30A}\":3}")
        #expect(angstrom.objectValue?.count == 3)
        #expect(angstrom["\u{212B}"] == 1 && angstrom["\u{C5}"] == 2 && angstrom["A\u{30A}"] == 3)
        // Among many keys, and nested.
        let members = (0..<200).map { "\"k\($0)\":0" } + ["\"\(composed)\":1", "\"\(decomposed)\":2"]
        let large = try JSON.parse("{" + members.joined(separator: ",") + "}")
        #expect(large.objectValue?.count == 202)
        #expect(large[composed] == 1 && large[decomposed] == 2)
        let nestedObject = try JSON.parse("[{\"o\":{\"\(composed)\":[1],\"\(decomposed)\":[2]}}]")
        #expect(nestedObject[0]?["o"]?[composed] == [1])
        #expect(nestedObject[0]?["o"]?[decomposed] == [2])
        // And they survive being written and read again.
        let again = try JSON.parse(object.encoded())
        #expect(again.objectValue?.count == 2)
        #expect(again[composed] == 1 && again[decomposed] == 2)
    }

    @Test func keysThatDifferOnlySlightly() throws {
        let object = try JSON.parse(#"{"a":1,"A":2,"a ":3," a":4,"":5,"a\u0000":6,"\u0061\u0301":7,"\u00e1":8,"1":9,"1.0":10,"01":11}"#)
        #expect(object.objectValue?.count == 11)
        #expect(object["a"] == 1 && object["A"] == 2 && object["a "] == 3 && object[" a"] == 4)
        #expect(object[""] == 5 && object["a\u{0}"] == 6)
        #expect(object["a\u{301}"] == 7 && object["\u{E1}"] == 8)
        #expect(object["1"] == 9 && object["1.0"] == 10 && object["01"] == 11)
        #expect(object["missing"] == nil)
    }

    @Test func longStrings() throws {
        let plain = String(repeating: "a", count: 1 << 20)
        #expect(try JSON.parse("\"\(plain)\"") == .string(plain))
        let escaped = String(repeating: #"\u00e9"#, count: 200_000)
        #expect(try JSON.parse("\"\(escaped)\"") == .string(String(repeating: "\u{E9}", count: 200_000)))
        let pairs = String(repeating: #"\ud83d\ude00"#, count: 100_000)
        #expect(try JSON.parse("\"\(pairs)\"") == .string(String(repeating: "😀", count: 100_000)))
        let quotes = String(repeating: #"\""#, count: 500_000)
        #expect(try JSON.parse("\"\(quotes)\"") == .string(String(repeating: "\"", count: 500_000)))
        let backslashes = String(repeating: #"\\"#, count: 500_000)
        #expect(try JSON.parse("\"\(backslashes)\"") == .string(String(repeating: "\\", count: 500_000)))
    }
}

#endif
