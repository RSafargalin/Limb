import Testing
import LimbCore

@Suite struct JSONParserTests {
    @Test func scalars() throws {
        #expect(try JSON.parse("null") == .null)
        #expect(try JSON.parse(" true ") == true)
        #expect(try JSON.parse("false") == false)
        #expect(try JSON.parse("42") == 42)
        #expect(try JSON.parse("-7") == -7)
        #expect(try JSON.parse("1.5") == 1.5)
        #expect(try JSON.parse("\"hi\"") == "hi")
    }

    @Test func numbersKeepTheirLexeme() throws {
        for text in ["1.0", "-0", "1e400", "12345678901234567890123", "1E+2", "0.1e-7", "9007199254740993"] {
            let value = try JSON.parse(text)
            #expect(value.description == text)
        }
        #expect(try JSON.parse("1.0") == 1)
        #expect(try JSON.parse("1e2").intValue == 100)
        #expect(try JSON.parse("1.5").intValue == nil)
        #expect(try JSON.parse("9007199254740993").numberValue?.int64Value == 9_007_199_254_740_993)
    }

    @Test func stringsAndEscapes() throws {
        #expect(try JSON.parse(#""a\"b\\c\/d\b\f\n\r\t""#) == "a\"b\\c/d\u{08}\u{0C}\n\r\t")
        #expect(try JSON.parse(#""é中😀""#) == "é中😀")
        #expect(try JSON.parse("\"é中😀 long enough to take the eight-byte path\"") == "é中😀 long enough to take the eight-byte path")
        #expect(try JSON.parse(#""data:text/plain;base64,aGk=""#) == "data:text/plain;base64,aGk=")
    }

    @Test func structures() throws {
        let value = try JSON.parse(#"{"a":[1,2,{"b":null}],"c":{},"d":[]}"#)
        #expect(value == ["a": [1, 2, ["b": nil]], "c": [:], "d": []])
        #expect(value["a"]?[2]?["b"] == .null)
        #if FoundationJSON
        #expect(try JSON.parse(value.description) == value)
        #else
        #expect(value.description == #"{"a":[1,2,{"b":null}],"c":{},"d":[]}"#)
        #endif
    }

    static var rejected: [String] {
        var texts = [
            "", " ", "[1 2]", "01", "1.", ".5", "1e", "+1", "-", "nul", "tru", "fals",
            #"{"a"}"#, #"{a:1}"#, "[", "{", #""abc"#, "\"a\nb\"", #""\x""#, #""\u12""#, #""\ud800""#,
            #""\udc00""#, #""\ud800A""#, "1 2", "[1]]", "NaN", "Infinity", "'a'",
            "\u{FEFF}1",
        ]
        #if !FoundationJSON
        // Foundation lets these three through; `acceptsWhatFoundationAccepts` pins what it makes of them.
        texts += Self.rejectedByTheDefaultCodecOnly
        #endif
        return texts
    }

    static let rejectedByTheDefaultCodecOnly = ["[1,]", #"{"a":1,}"#, #"{"a":1,"a":2}"#]

    @Test(arguments: rejected)
    func rejects(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSON.parse(text) }
    }

    #if FoundationJSON
    /// The counterpart of the cases left out of `rejects` under the fallback codec.
    @Test func acceptsWhatFoundationAccepts() throws {
        // A trailing comma is skipped; it does not add an element or a member.
        #expect(try JSON.parse("[1,]") == [1])
        #expect(try JSON.parse("[1,]").arrayValue?.count == 1)
        #expect(try JSON.parse(#"{"a":1,}"#) == ["a": 1])
        #expect(try JSON.parse(#"{"a":1,}"#).objectValue?.count == 1)
        // A repeated key is not an error, and exactly one of the members survives.
        let duplicate = try JSON.parse(#"{"a":1,"a":2}"#)
        #expect(duplicate.objectValue?.count == 1)
        #expect(duplicate["a"] == 1 || duplicate["a"] == 2)
        // `rejectDuplicateKeys` is on by default and makes no difference.
        #expect(throws: Never.self) {
            try JSON.parse(#"{"a":1,"a":2}"#, options: JSONParseOptions(rejectDuplicateKeys: true))
        }
    }
    #endif

    @Test func rejectsInvalidUTF8() {
        #expect(throws: JSONParseError.self) { try JSON.parse([0x22, 0xFF, 0x22] as [UInt8]) }
        #expect(throws: JSONParseError.self) { try JSON.parse([0x22, 0xC3, 0x22] as [UInt8]) }
    }

    @Test func limits() throws {
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(throws: Never.self) { try JSON.parse(deep) }
        #expect(throws: JSONParseError.self) { try JSON.parse(deep, options: JSONParseOptions(maxDepth: 99)) }
        let tooDeep = String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
        #expect(throws: JSONParseError.self) { try JSON.parse(tooDeep) }
        // A limit raised beyond what the stack can hold becomes an error, not a crash.
        let bottomless = String(repeating: "[", count: 200_000)
        #expect(throws: JSONParseError.self) { try JSON.parse(bottomless, options: JSONParseOptions(maxDepth: .max)) }
        let nestedObjects = String(repeating: "{\"a\":", count: 200_000)
        #expect(throws: JSONParseError.self) { try JSON.parse(nestedObjects, options: JSONParseOptions(maxDepth: .max)) }
        let wide = "[" + Array(repeating: "0", count: 100).joined(separator: ",") + "]"
        #expect(throws: JSONParseError.self) { try JSON.parse(wide, options: JSONParseOptions(maxNodes: 50)) }
    }

    @Test func manyKeysDuplicateDetection() throws {
        let members = (0..<100).map { "\"k\($0)\":\($0)" }
        #expect(try JSON.parse("{" + members.joined(separator: ",") + "}").objectValue?.count == 100)
        #if !FoundationJSON
        #expect(throws: JSONParseError.self) {
            try JSON.parse("{" + (members + ["\"k7\":0"]).joined(separator: ",") + "}")
        }
        #else
        // The fallback cannot see the repeat: the object keeps 100 members and one of the two values.
        let repeated = try JSON.parse("{" + (members + ["\"k7\":0"]).joined(separator: ",") + "}")
        #expect(repeated.objectValue?.count == 100)
        #expect(repeated["k7"] == 7 || repeated["k7"] == 0)
        #expect(repeated["k8"] == 8)
        #endif
    }
}

@Suite struct JSONWriterTests {
    @Test func escaping() {
        var writer = JSONWriter()
        writer.write("a\"b\\c\n\r\t\u{01}\u{1F} é中😀 and a long tail with a \"quote\" in it")
        #expect(String(decoding: writer.bytes, as: UTF8.self)
            == #""a\"b\\c\n\r\t\u0001\u001f é中😀 and a long tail with a \"quote\" in it""#)
    }

    @Test func structure() {
        var writer = JSONWriter()
        writer.beginObject()
        writer.field("a", 1)
        writer.key("b")
        writer.beginArray()
        writer.write(true)
        writer.writeNull()
        writer.beginObject()
        writer.endObject()
        writer.write(Int64.min)
        writer.endArray()
        writer.field("c", String?.none)
        writer.field("d", "x")
        writer.endObject()
        #expect(String(decoding: writer.bytes, as: UTF8.self) == #"{"a":1,"b":[true,null,{},-9223372036854775808],"d":"x"}"#)
    }

    @Test func roundTripsArbitraryText() throws {
        var text = ""
        for scalar in 0..<0x300 { text.unicodeScalars.append(Unicode.Scalar(scalar)!) }
        text += "😀\u{2028}\u{2029}"
        let encoded = JSONValue.string(text).encoded()
        #expect(!encoded.contains(0x0A))
        #expect(try JSON.parse(encoded) == .string(text))
    }

    @Test func numbers() {
        #expect(JSONValue(1.5).description == "1.5")
        #expect(JSONValue(Double.nan) == .null)
        #expect(JSONValue(1e100).description == "1e+100")
        #expect(JSONValue(0).description == "0")
        #expect(JSONValue(-12345).description == "-12345")
    }

    @Test func objectEqualityIgnoresOrder() {
        let a: JSONValue = ["x": 1, "y": 2]
        let b: JSONValue = ["y": 2, "x": 1.0]
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}
