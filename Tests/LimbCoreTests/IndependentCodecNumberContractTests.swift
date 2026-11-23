import LimbCore
import Testing

/// These cases run in both the default build and the FoundationJSON trait build.
@Suite struct IndependentCodecNumberContractTests {
    @Test(
        arguments: [
            "1.0000000000000000001", "18446744073709551617", "1e400",
            "-0", "-0.000E-001", "1E+002", "3.125e-002", "-0.1250",
        ],
        [false, true]
    )
    func inputNumberBytesSurviveScalarAndNestedParsing(_ lexeme: String, nested: Bool) throws {
        if nested {
            let document = #"{"items":["\#(lexeme)",\#(lexeme),{"\#(lexeme)":\#(lexeme)}]}"#
            let parsed = try JSON.parse(Array(document.utf8))
            let items = try #require(parsed["items"]?.arrayValue)
            try #require(items.count == 3)
            #expect(items[0] == .string(lexeme))
            #expect(items[2].objectValue?.count == 1)
            let field = try #require(items[2][lexeme])
            #expect(items[1].encoded() == Array(lexeme.utf8))
            #expect(field.encoded() == Array(lexeme.utf8))
        } else {
            let padded = " \t\(lexeme)\r\n"
            let value = try JSON.parse(Array(padded.utf8))
            #expect(value.encoded() == Array(lexeme.utf8))
        }
    }

    @Test func numericTypeUsesTheExactValue() throws {
        let input = #"{"integral":[-0,1.000E+002,18446744073709551617,1e400],"fractional":[1.0000000000000000001,1e-400,-0.2500]}"#
        let parsed = try JSON.parse(Array(input.utf8))
        let integers = try #require(parsed["integral"]?.arrayValue)
        let fractions = try #require(parsed["fractional"]?.arrayValue)
        #expect(integers.count == 4)
        #expect(fractions.count == 3)
        for value in integers {
            let number = try #require(value.numberValue)
            #expect(number.isInteger, "\(value)")
        }
        for value in fractions {
            let number = try #require(value.numberValue)
            #expect(!number.isInteger, "\(value)")
        }
    }

    @Test func booleansNumbersAndStringsRemainDistinct() throws {
        let document = #"[true,1,"1",false,0,"0",{"1":"true","0":"false"}]"#
        let parsed = try JSON.parse(Array(document.utf8))
        #expect(parsed[0] == .bool(true))
        #expect(parsed[0]?.numberValue == nil)
        #expect(parsed[1] == .number(1))
        #expect(parsed[1]?.boolValue == nil)
        #expect(parsed[2] == .string("1"))
        #expect(parsed[2]?.numberValue == nil)
        #expect(parsed[3] == .bool(false))
        #expect(parsed[3]?.numberValue == nil)
        #expect(parsed[4] == .number(0))
        #expect(parsed[4]?.boolValue == nil)
        #expect(parsed[5] == .string("0"))
        #expect(parsed[5]?.numberValue == nil)
        #expect(parsed[6]?["1"] == .string("true"))
        #expect(parsed[6]?["0"] == .string("false"))
    }

    @Test func mixedValuesAndUnicodeKeysSurviveReencoding() throws {
        let document = #"{"outer":{"caf\u00e9":[9223372036854775807,"9223372036854775807",true],"cafe\u0301":[-0.0,false,"\ud83d\ude03"],"a\ufeffb":"left\ufeffright"}}"#
        let decoded = try JSON.parse(Array(document.utf8))
        let roundTrip = try JSON.parse(decoded.encoded())
        for value in [decoded, roundTrip] {
            let object = try #require(value["outer"]?.objectValue)
            #expect(object.count == 3)
            let composed = try #require(object["caf\u{E9}"]?.arrayValue)
            let decomposed = try #require(object["cafe\u{301}"]?.arrayValue)
            try #require(composed.count == 3 && decomposed.count == 3)
            #expect(composed[0].numberValue?.int64Value == .max)
            #expect(composed[0].description == "9223372036854775807")
            #expect(composed[1] == .string("9223372036854775807"))
            #expect(composed[2] == .bool(true))
            #expect(decomposed[0].numberValue?.description == "-0.0")
            #expect(decomposed[1] == .bool(false))
            #expect(decomposed[2] == .string("😃"))
            #expect(object["a\u{FEFF}b"] == .string("left\u{FEFF}right"))
        }
    }

    @Test func escapedDuplicateKeyFollowsTheSelectedCodecPolicy() throws {
        let document = #"{"outer":{"caf\u00e9":"first","café":2.00}}"#
        #if FoundationJSON
        let value = try JSON.parse(Array(document.utf8))
        let object = try #require(value["outer"]?.objectValue)
        #expect(object.count == 1)
        let survivor = try #require(object["café"])
        #expect(survivor == .string("first") || survivor.numberValue?.description == "2.00")
        #expect(try JSON.parse(value.encoded()) == value)
        #else
        #expect(throws: JSONParseError.self) { try JSON.parse(Array(document.utf8)) }
        #endif
    }

    @Test(arguments: ["01", "-01", "+1", ".5", "-.5", "1.", "1e", "1e+", "1e-", "NaN", "Infinity", "0x1"])
    func malformedNumberFormsAreRejected(_ token: String) {
        let documents = [token, "[true,\(token),\"\(token)\"]", "{\"\(token)\":\(token)}"]
        for document in documents {
            #expect(throws: JSONParseError.self) { try JSON.parse(Array(document.utf8)) }
        }
    }
}
