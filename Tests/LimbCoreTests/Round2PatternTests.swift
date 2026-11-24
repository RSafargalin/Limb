import LimbCore
import Testing
import Dispatch
import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif


/// Whether Limb accepts `string` under `{"pattern": pattern}`; `nil` if the schema is refused.
private func limbMatches(_ pattern: String, _ string: String) -> Bool? {
    guard let schema = try? JSONSchema(["pattern": .string(pattern)]) else { return nil }
    return schema.validate(.string(string)) == nil
}

private func compileError(_ pattern: String) -> String? {
    do {
        _ = try JSONSchema(["pattern": .string(pattern)])
        return nil
    } catch {
        return error.description
    }
}

@Suite struct Round2PatternTests {
    // MARK: - Answers that follow from ECMA 262 directly

    /// (pattern, string, expected) — each line is justified by the ECMA 262 text with the `u`
    /// flag: the input is a sequence of code points, `.` excludes only LF, CR, U+2028, U+2029,
    /// `\d` / `\w` / `\b` are ASCII, `\s` is WhiteSpace ∪ LineTerminator, `$` without `m` is the
    /// end of input only, and the search is unanchored.
    static let specified: [(String, String, Bool)] = [
        (#"^\d+$"#, "٣٤", false),
        (#"^\d+$"#, "0189", true),
        (#"^\w+$"#, "é", false),
        (#"^\w+$"#, "aZ_9", true),
        (#"^.{1,3}$"#, "e" + String(repeating: "\u{301}", count: 2000), false),
        (#"^.$"#, "e\u{301}", false),
        (#"^.{2}$"#, "e\u{301}", true),
        (#"^[^x]$"#, "\r\n", false),
        (#"^[^x]{2}$"#, "\r\n", true),
        (#"^.{2}$"#, "\r\n", false),
        (#"^\r\n$"#, "\r\n", true),
        (#"\s"#, "\u{85}", false),
        (#"\s"#, "\u{FEFF}", true),
        (#"\s"#, "\u{2028}", true),
        (#"\s"#, "\u{3000}", true),
        (#"\s"#, "\u{200B}", false),
        (#"^.$"#, "\u{2028}", false),
        (#"^.$"#, "\u{2029}", false),
        (#"^.$"#, "\u{85}", true),
        (#"^.$"#, "\u{FFFD}", true),
        (#"^\uFFFD$"#, "\u{FFFD}", true),
        (#"^.$"#, "😀", true),
        (#"^..$"#, "😀", false),
        (#"^\uD83D\uDE00$"#, "😀", true),
        (#"^[\uD83D\uDE00]$"#, "😀", true),
        (#"^\u{D83D}\u{DE00}$"#, "😀", false),
        (#"\uD83D"#, "😀", false),
        (#"^[^\uD800-\uDFFF]$"#, "😀", true),
        (#"^\0$"#, "\0", true),
        (#"^.$"#, "\0", true),
        (#"^\x00\x00$"#, "\0\0", true),
        (#"^[^]$"#, "\n", true),
        (#"^.$"#, "\n", false),
        (#"a$"#, "a\n", false),
        (#"^b"#, "a\nb", false),
        (#"\bé"#, "aé", true),
        (#"\bé"#, " é", false),
        (#"a\b"#, "aé", true),
        (#"\B"#, "a😀b", false),
        (#"^\cJ$"#, "\n", true),
        (#"^\cj$"#, "\n", true),
        (#"^[\b]$"#, "\u{8}", true),
        (#"\b"#, "\u{8}", false),
        (#"^\p{Lu}$"#, "É", true),
        (#"^\p{Lu}$"#, "é", false),
        (#"^\p{Lt}$"#, "ǅ", true),
        (#"^\P{L}$"#, "1", true),
        (#"^\p{Nd}+$"#, "٣٤", true),
        (#"^[^\p{L}\d]$"#, "-", true),
        (#"^[^\p{L}\d]$"#, "x", false),
        (#"^[^\p{L}\d]$"#, "7", false),
        (#"^\p{Zl}$"#, "\u{2028}", true),
        (#"^\p{Co}$"#, "\u{E000}", true),
        (#"^\p{Cs}$"#, "\u{FFFD}", false),
        (#"^(?:a|ab)c$"#, "abc", true),
        (#"^(a|ab)(c|bcd)(d*)$"#, "abcd", true),
        (#"^(?:a?){3}a{3}$"#, "aaa", true),
        (#"^(?:a*)*$"#, "aaaa", true),
        (#"^(?:a|)*b$"#, "aab", true),
        (#"^(?:\b)*a$"#, "a", true),
        (#"^(?:^a)+$"#, "a", true),
        (#"^(?:^a)+$"#, "aa", false),
        (#"(?:^|,)b"#, "a,b", true),
        (#"(?:^|,)b"#, "ab", false),
        (#"x{0}"#, "", true),
        (#"^a{2,}?$"#, "aaaa", true),
        (#"[]"#, "a", false),
        (#""#, "", true),
        (#"|"#, "abc", true),
    ]

    @Test func answersThatFollowFromTheSpecification() {
        for (pattern, string, expected) in Self.specified {
            #expect(limbMatches(pattern, string) == expected, "\(pattern) on \(string.debugDescription)")
        }
    }

    // MARK: - Syntax: what is refused

    /// Invalid in ECMA 262 with the `u` flag: each must be a compile error, never a meaning.
    static let invalidUnderTheUFlag: [String] = [
        #"\h"#, #"\Z"#, #"\a"#, #"\e"#, #"\z"#, #"\_"#, #"\ "#, "\\\u{E9}", #"\-"#, #"[\B]"#, #"[\h]"#,
        #"\c"#, #"\c1"#, #"[\c1]"#, #"\x4"#, #"\xGG"#, #"\u004"#, #"\u{}"#, #"\u{41"#, #"\u{110000}"#,
        #"\00"#, #"\01"#, #"[\00]"#, #"\1"#, #"[\1]"#, #"\k"#, #"\k<n>"#, #"[\k]"#,
        #"a**"#, #"a++"#, #"a*+"#, #"a{2}+"#, #"a*??"#, #"a{1}{2}"#, #"*a"#, #"+a"#, #"?a"#,
        #"{"#, #"a{"#, #"a{,2}"#, #"a{2,1}"#, #"a{1,2"#, #"}"#, #"a}"#, #"]"#, #"a]"#,
        #"["#, #"[a"#, #"("#, #")"#, #"a)"#, #"(a"#, #"(?"#, #"(?<n"#, #"(?<n>"#, #"(?<>a)"#, #"(?<1a>a)"#,
        #"(?P<n>a)"#, #"(?#c)"#, #"(?i)a"#, #"\b+"#, #"^*"#, #"$?"#, #"\B{2}"#,
        #"[\d-x]"#, #"[x-\d]"#, #"[\w-\s]"#, #"[\p{L}-z]"#, #"[z-a]"#,
        #"\p{RGI_Emoji}"#, #"\p{lu}"#, #"\p{L"#, #"\p{}"#, #"\p"#, #"\pL"#, #"\P"#,
    ]

    @Test func invalidPatternsAreRefused() {
        for pattern in Self.invalidUnderTheUFlag {
            #expect(compileError(pattern) != nil, "\(pattern) must not compile")
        }
    }

    /// Valid ECMA 262 that the doc comment of `JSONSchema` says is refused.
    static let documentedRefusals: [String] = [
        #"(?=a)"#, #"(?!a)"#, #"(?<=a)"#, #"(?<!a)"#, #"(a)\1"#, #"(?<n>a)\k<n>"#,
        #"\p{Script=Latin}"#, #"\p{sc=Latn}"#, #"\p{Script_Extensions=Latin}"#, #"\p{Any}"#, #"\P{Any}"#,
        #"\p{ASCII}"#, #"\p{Alphabetic}"#, #"\p{Lowercase}"#,
        // Counted repetition is expanded and bounded by `Limits.maxPatternStates`.
        #"x{99999}"#, #"x{10001}"#, #"(a{100}){101}"#,
    ]

    @Test func documentedRefusalsAreRefused() {
        for pattern in Self.documentedRefusals {
            #expect(compileError(pattern) != nil, "\(pattern)")
        }
    }

    /// The message names the pattern, the reason and the place, in all three places a pattern can be.
    @Test func anInvalidPatternIsACompileErrorInEveryPlace() throws {
        func error(_ schema: JSONValue) -> JSONSchemaError? {
            do {
                _ = try JSONSchema(schema)
                return nil
            } catch {
                return error
            }
        }
        let inPattern = try #require(error(["properties": ["a": ["pattern": "(?=x)"]]]))
        #expect(inPattern.pointer == "/properties/a/pattern")
        #expect(inPattern.reason.contains("(?=x)") && inPattern.reason.contains("lookahead"))

        let inPatternProperties = try #require(error(["patternProperties": ["a(": true]]))
        #expect(inPatternProperties.pointer.hasPrefix("/patternProperties"))
        #expect(inPatternProperties.reason.contains("a("))

        let inPropertyNames = try #require(error(["propertyNames": ["pattern": #"\k<x>"#]]))
        #expect(inPropertyNames.pointer == "/propertyNames/pattern")
        #expect(inPropertyNames.reason.contains("back-reference"))

        #expect(error(["pattern": 5])?.pointer == "/pattern")
        #expect(error(["patternProperties": ["(?<=a)b": ["type": "string"]]]) != nil)
    }

    @Test func patternPropertiesAndPropertyNamesUseTheSameDialect() throws {
        let schema = try JSONSchema([
            "patternProperties": [#"^\d+$"#: ["type": "integer"], #"^\p{Lu}"#: ["type": "string"]],
            "propertyNames": ["pattern": #"^[^\s]{1,8}$"#],
        ])
        #expect(schema.validate(["12": 1, "Éa": "x"]) == nil)
        #expect(schema.validate(["12": "x"]) != nil)
        // Arabic-Indic digits are not `\d`, so the integer rule does not apply to this key.
        #expect(schema.validate(["٣": "x"]) == nil)
        #expect(schema.validate(["Éa": 1]) != nil)
        // U+FEFF is ECMA white space: refused as a name.
        #expect(schema.validate(["a\u{FEFF}": 1]) != nil)
        // U+0085 is not.
        #expect(schema.validate(["a\u{85}": 1]) == nil)
        // Eight code points, one of them astral: within `{1,8}`.
        #expect(schema.validate(["aaaaaaa😀": 1]) == nil)
        #expect(schema.validate(["aaaaaaaa😀": 1]) != nil)
    }

    @Test func longStringsAndSpecialCharacters() {
        let long = String(repeating: "a", count: 256 * 1024)
        #expect(limbMatches(#"^a*$"#, long) == true)
        #expect(limbMatches(#"^(a|b)*$"#, long + "c") == false)
        #expect(limbMatches(#"b"#, long) == false)
        #expect(limbMatches(#"a$"#, long) == true)
        #expect(limbMatches(#"^a{0,100}$"#, long) == false)
        #expect(limbMatches(#"\u2028"#, long + "\u{2028}") == true)
        #expect(limbMatches(#"^[^\n]*$"#, long + "\r\n") == false)
        #expect(limbMatches(#"^[^\n]*\r\n$"#, long + "\r\n") == true)
        #expect(limbMatches(#"\0"#, long + "\0" + long) == true)
        #expect(limbMatches(#"^.*$"#, long + "\0\u{FFFD}" + long) == true)
    }

    @Test func invalidPatternsThatLimbAccepted() {
        let patterns = [
            #"(?<n>a)(?<n>b)"#,
            #"((?<ab>x)|(?<ab>y))(?<ab>z)"#,
            #"(?<n>(?<n>a))"#,
            #"(?:(?<a>x)|(?<a>y))(?<a>z)"#,
            #"(?<a>x)(?:(?<b>y)|(?<a>z))"#,
            #"(?:(?<a>x)|y)*(?<a>z)"#,
            "(?<\u{24B6}>x)",  // CIRCLED LATIN CAPITAL LETTER A: Alphabetic, not ID_Start
            "(?<\u{345}>x)",  // a combining mark: Alphabetic, not ID_Start
            "(?<\u{2E2F}>x)",  // VERTICAL TILDE: Lm but Pattern_Syntax, so not ID_Start
            "(?<1>x)", "(?<a-b>x)", "(?<a b>x)",
            #"\p{General_Category=gc=Lu}"#, #"\p{gc=General_Category=Lu}"#, #"\p{gc=gc=Lu}"#, #"\p{gc=}"#,
            #"\p{General_Category=}"#, #"\p{=Lu}"#,
        ]
        for pattern in patterns {
            #expect(compileError(pattern) != nil, "\(pattern)")
        }
    }

    /// Names that ECMA 262 allows, including the same name in different alternatives (ES2025)
    /// and ID_Start characters that are not letters (`Ⅰ` is Nl; `℘` is Other_ID_Start).
    /// JavaScriptCore refuses the last two — a deviation of its own from the specification.
    @Test func validGroupNames() {
        let patterns = [
            #"(?<n>a)|(?<n>b)"#, #"(?<a>x)|(?:(?<a>y)|(?<a>z))"#, #"(?:(?<a>x)|(?<a>y))|(?<a>z)"#,
            #"(?<a>x)(?<b>y)(?<c>z)"#, #"(?<$>x)"#, #"(?<_1>x)"#, #"(?<a1_$>x)"#, "(?<\u{E9}t\u{E9}>x)",
            "(?<\u{3B1}>x)", "(?<\u{4E2D}\u{6587}>x)", "(?<\u{2160}>x)", "(?<\u{2118}>x)", "(?<\u{1D400}>x)",
            #"\p{gc=Lu}"#, #"\p{General_Category=Letter}"#,
        ]
        for pattern in patterns {
            #expect(compileError(pattern) == nil, "\(pattern)")
        }
        #expect(limbMatches(#"^(?:(?<n>a)|(?<n>b))+$"#, "abba") == true)
    }

    @Test func zeroRepetitionDoesNotChangeCaptureNameSyntax() {
        #expect(compileError(#"(?<n>a)(?<n>b){0}"#) != nil)
        #expect(limbMatches(#"^(?:(?<n>a)|(?<n>b)){0}$"#, "") == true)
    }

    /// Valid ECMA 262 that Limb refuses without the doc comment of `JSONSchema` saying so
    /// (D5, a documentation defect): failing closed is safe, so this pins only the refusal.
    @Test func undocumentedRefusals() {
        for pattern in [#"(?i:a)"#, #"(?-i:a)"#, #"(?<\u0061>x)"#, "(?<a\u{661}>x)", "(?<a\u{200D}>x)"] {
            #expect(compileError(pattern) != nil, "\(pattern)")
        }
    }

    @Test func repetitionCountAboveOneHundredThousandIsRefusedWhateverTheStateLimit() throws {
        var limits = JSONSchema.Limits()
        limits.maxPatternStates = 1_000_000
        #expect(throws: JSONSchemaError.self) { try JSONSchema(["pattern": "a{100001}"], limits: limits) }
        let schema = try JSONSchema(["pattern": "^a{100000}$"], limits: limits)
        #expect(schema.validate(.string(String(repeating: "a", count: 100_000))) == nil)
        #expect(schema.validate(.string(String(repeating: "a", count: 99_999))) != nil)
    }

    // MARK: - Differential comparison with JavaScriptCore

    #if canImport(JavaScriptCore)
    /// Patterns for the cross product. Most constructs once, alone and in small combinations.
    static let crossPatterns: [String] = [
        "a", "abc", "a|b", "a|", "|a", "|", "ab|cd|", "(a)", "(?:a)", "(?<n>a)", "(?<$x_1>a)", "(?<\u{E9}>a)", "()", "(?:)",
        "(a|)+", "(a*)*", "(a*)+b", "(?:)*", "(?:a?)*?b", "(a|b)*c", "a*", "a+", "a?", "a{2}", "a{2,}", "a{2,3}", "a{0}",
        "a{0,0}b", "^a{2}$", "^a{2,}$", "^a{2,3}$", "^a{0}$", "a*?", "a+?", "a??", "a{2}?", "a{2,}?", "^a{2,3}?$",
        "^(?:a|ab)c$", #"^(a+)+$"#, #"^(\w+\s?)+$"#, "^", "$", "^$", "^a", "a$", "^a$", "^a|b$", "x^", "$x",
        #"\b"#, #"\B"#, #"\ba"#, #"a\b"#, #"\Ba"#, "\\b\u{E9}", "\u{E9}\\b", #"\b\B"#, #"^\b"#, ".", "^.$", "^..$", "^.*$",
        "[abc]", "[^abc]", "^[^abc]$", "[a-c]", "[a-cx-z]", "[-a]", "[a-]", #"[a\-z]"#, #"[\d]"#, #"[\D]"#, #"[\w-]"#,
        #"[-\w]"#, #"[\s]"#, #"[\S]"#, #"[\b]"#, #"[\n]"#, #"[\t-\r]"#, #"[^\n]"#, "[^]", "^[^]$", "[]", "^[]$", #"[\]]"#,
        #"[\\]"#, #"[\^]"#, "[a^]", "[[]", #"[\x41-\x43]"#, #"[\u0041-\u0043]"#, #"[\u{41}-\u{43}]"#, #"[\u{1F600}]"#,
        #"[\uD83D\uDE00]"#, #"\uD83D\uDE00"#, #"^\uD83D\uDE00$"#, #"^[\uD83D\uDE00]$"#, #"^\u{1F600}$"#,
        #"[\uD83D\uDE00-\uD83D\uDE4F]"#, #"\u{D83D}\u{DE00}"#, #"\uD83D\u{DE00}"#, #"\uD83D"#, #"[\uD800-\uDFFF]"#,
        #"[^\uD800-\uDFFF]"#, #"\u{0000000041}"#, #"\u{10FFFF}"#, #"\x41"#, #"\d"#, #"\D"#, #"\w"#, #"\W"#, #"\s"#, #"\S"#,
        #"^\d+$"#, #"^\w+$"#, #"^\s$"#, #"^\S$"#, #"\t"#, #"\n"#, #"\v"#, #"\f"#, #"\r"#, #"\0"#, #"\cJ"#, #"\cj"#,
        #"[\cJ]"#, #"\p{L}"#, #"\p{Lu}"#, #"\p{Ll}"#, #"\p{Lt}"#, #"\p{Lm}"#, #"\p{Lo}"#, #"\p{Letter}"#,
        #"\p{Uppercase_Letter}"#, #"\p{gc=Lu}"#, #"\p{General_Category=Lu}"#, #"\p{General_Category=Letter}"#,
        #"\p{LC}"#, #"\p{Cased_Letter}"#, #"\p{N}"#, #"\p{Nd}"#, #"\p{Nl}"#, #"\p{No}"#, #"\p{digit}"#, #"\p{punct}"#,
        #"\p{cntrl}"#, #"\p{Combining_Mark}"#, #"\p{M}"#, #"\p{Mn}"#, #"\p{Mc}"#, #"\p{P}"#, #"\p{Pd}"#, #"\p{Ps}"#,
        #"\p{Zs}"#, #"\p{Zl}"#, #"\p{Zp}"#, #"\p{Z}"#, #"\p{Cc}"#, #"\p{Cf}"#, #"\p{Co}"#, #"\p{Cs}"#, #"\p{C}"#,
        #"\p{S}"#, #"\p{Sm}"#, #"\p{Sc}"#, #"\p{Sk}"#, #"\p{So}"#, #"\P{L}"#, #"\P{Lu}"#, #"[\p{L}\d]"#, #"[^\p{L}]"#,
        #"[^\P{L}]"#, #"[\P{L}a]"#, #"^[^\p{L}\d]$"#, #"[\p{Lu}\p{Nd}]+"#, #"\^"#, #"\$"#, #"\\"#, #"\."#, #"\*"#, #"\+"#,
        #"\?"#, #"\("#, #"\)"#, #"\["#, #"\]"#, #"\{"#, #"\}"#, #"\|"#, #"\/"#, #"[\-]"#, #"[\0]"#, "[a-a]",
        #"\u{2028}"#, #"\u2028"#, #"\u2029"#, #".\u2028"#, #"\x00"#, #"^\x00$"#, #"\ufffd"#, #"^\uFFFD$"#, #"^\r\n$"#,
        #"^.\n$"#, #"^\r?\n$"#, "a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p", "(?:a|b)(?:c|d)", "(a|ab)(c|bcd)(d*)",
        "^(a|ab)(c|bcd)(d*)$", "^(?:a?){3}a{3}$", "^(a?){0,3}a{3}$", "^(?:a*)*$", "^(?:a|)*b$", "^(?:(?:)+)+$",
        #"^(?:\b)*a$"#, "^(?:$)*a$", "^(?:^a)+$", "(?:^|,)b", "b(?:$|,)", "^(?:^)+a", "(?<n>a)|(?<n>b)",
        "x{3,5}", "^x{3,5}$", "(?:ab){2,3}", "^(?:ab){2,3}$", #"[^\s\S]"#, #"[\s\S]"#, #"[\w\W]"#,
    ]

    static let crossStrings: [String] = [
        "", "a", "b", "aa", "aaa", "aaaa", "ab", "abc", "abcd", "ba", "c", "cd", "x", "xxx", "xxxxx", "xxxxxx", "A", "B",
        "ABC", "\u{E9}", "e\u{301}", "\u{C9}", "1", "123", "٣", "_", "-", " ", "\t", "\n", "\r", "\r\n", "\u{B}", "\u{C}",
        "\u{A0}", "\u{85}", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{3000}", "\u{1680}", "\u{200B}", "\0", "\0\0", "\u{FFFD}",
        "😀", "😀😀", "a😀b", "\u{10FFFF}", "]", "[", "\\", "^", "$", ".", "*", "{", "}", "|", "/", "(", ")", "?", "+",
        "\u{8}", "\u{1}", "\u{1F}", "\u{7F}", "a b", "a\nb", "a,b", ",b", "b,", "xxb", "aac", "abbcd", "acd", "abab",
        "ababab", "aaa b", "\u{1C4}", "\u{1C5}", "\u{300}", "\u{20AC}", "\u{E000}", "\u{378}", "\u{2160}", "\u{B2}",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaab", String(repeating: "a ", count: 20) + "!",
    ]

    /// Patterns JavaScriptCore accepts although ECMA 262 with the `u` flag makes them syntax
    /// errors (IdentityEscape[+U] is only SyntaxCharacter or `/`). Limb must refuse them.
    static let invalidButAcceptedByJavaScriptCore: Set<String> = ["\\\u{E9}"]

    @Test func handWrittenCrossProductAgreesWithJavaScript() throws {
        let oracle = try #require(ECMAOracle())
        var compared = 0
        var unexplained: [String] = []
        for pattern in Self.crossPatterns {
            let compiled = try? JSONSchema(["pattern": .string(pattern)])
            for string in Self.crossStrings {
                guard let expected = oracle.verdict(pattern, string) else { continue }
                let actual: Bool? = compiled.map { $0.validate(.string(string)) == nil }
                compared += 1
                if expected == actual { continue }
                if actual == nil && expected != nil && Self.invalidButAcceptedByJavaScriptCore.contains(pattern) { continue }
                if ECMAOracle.isSurrogateBoundaryDeviation(pattern, string, expected: expected, actual: actual) { continue }
                unexplained.append(
                    "\(pattern) on \(string.debugDescription): JavaScript \(expected.map(String.init) ?? "refuses"), Limb \(actual.map(String.init) ?? "refuses")"
                )
            }
        }
        #expect(compared > 20_000)
        #expect(unexplained.isEmpty, "\(unexplained.count) disagreements, first: \(unexplained.prefix(10))")
    }

    /// Refused patterns: compare only what JavaScript accepts against the documented list.
    @Test func everyRefusalOfAValidPatternIsDocumented() throws {
        let oracle = try #require(ECMAOracle())
        let undocumented: Set<String> = [#"(?i:a)"#, #"(?-i:a)"#, #"(?<\u0061>x)"#, "(?<a\u{661}>x)", "(?<a\u{200D}>x)"]
        for pattern in Self.documentedRefusals + Array(undocumented) {
            var accepted = false
            if case .some(.some) = oracle.verdict(pattern, "") { accepted = true }
            #expect(accepted, "JavaScript accepts \(pattern)")
            #expect(compileError(pattern) != nil, "Limb refuses \(pattern)")
        }
        for pattern in Self.invalidUnderTheUFlag where !Self.invalidButAcceptedByJavaScriptCore.contains(pattern) {
            // The oracle agrees that these are syntax errors (a guard on the list itself).
            #expect(oracle.verdict(pattern, "") == .some(nil), "JavaScript refuses \(pattern)")
        }
    }

    #endif

    /// Generated matches use fresh capture names. Duplicate-name syntax is checked separately
    /// against the static semantics because engines can simplify groups under quantifiers first.
    @Test(
        .enabled(if: NodePatternOracle.executable != nil, "Node.js is needed for the generated comparison"),
        arguments: [(UInt64(1), false), (2, false), (3, true), (4, true), (5, true), (6, true)]
    )
    func generatedPatternsAgreeWithJavaScript(seed: UInt64, rich: Bool) throws {
        let node = try #require(NodePatternOracle.executable)
        var generator = PatternGenerator(seed: seed, rich: rich)
        let groups = (0..<1_500).map { _ in
            let pattern = generator.pattern()
            return [pattern] + (0..<5).map { _ in generator.string() }
        }
        let verdicts = try NodePatternOracle.verdicts(for: groups, executable: node)
        try #require(verdicts.count == groups.count)
        var unexplained: [String] = []
        for (group, answers) in zip(groups, verdicts) {
            let pattern = group[0]
            let compiled = try? JSONSchema(["pattern": .string(pattern)])
            try #require(answers.utf8.count == group.count - 1)
            for (string, answer) in zip(group.dropFirst(), answers.utf8) {
                let expected: Bool?
                switch answer {
                case UInt8(ascii: "1"): expected = true
                case UInt8(ascii: "0"): expected = false
                case UInt8(ascii: "E"): expected = nil
                default: throw NodePatternOracle.Failure.invalidResult
                }
                let actual: Bool? = compiled.map { $0.validate(.string(string)) == nil }
                if expected == actual { continue }
                unexplained.append("\(pattern) on \(string.debugDescription): JavaScript \(expected.map(String.init) ?? "refuses"), Limb \(actual.map(String.init) ?? "refuses")")
            }
        }
        #expect(unexplained.isEmpty, "\(unexplained.count) disagreements, first: \(unexplained.prefix(5))")
    }
}

/// The generated cases use a separate runtime so a JavaScriptCore change cannot silently
/// become an expectation for Limb's pattern implementation.
private enum NodePatternOracle {
    enum Failure: Error { case timedOut, processFailed(Int32), invalidResult }

    static let executable: URL? = ProcessInfo.processInfo.environment["PATH"]?
        .split(separator: ":")
        .lazy.map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    static func verdicts(for groups: [[String]], executable: URL) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json")
        let output = directory.appendingPathComponent("output.json")
        try JSONEncoder().encode(groups).write(to: input)
        try Data().write(to: output)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-e", script]
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = try FileHandle(forWritingTo: output)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + .seconds(30)) == .success else {
            process.terminate()
            process.waitUntilExit()
            throw Failure.timedOut
        }
        guard process.terminationStatus == 0 else { throw Failure.processFailed(process.terminationStatus) }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
    }

    private static let script = """
        const fs = require('node:fs');
        const groups = JSON.parse(fs.readFileSync(0, 'utf8'));
        const answers = groups.map(([pattern, ...inputs]) => {
          let regex;
          try { regex = new RegExp(pattern, 'uy'); } catch (error) {
            if (error instanceof SyntaxError) return 'E'.repeat(inputs.length);
            throw error;
          }
          return inputs.map(input => {
            for (let offset = 0; offset <= input.length;) {
              regex.lastIndex = offset;
              if (regex.test(input)) return '1';
              offset += input.codePointAt(offset) > 0xFFFF ? 2 : 1;
            }
            return '0';
          }).join('');
        });
        fs.writeFileSync(1, JSON.stringify(answers));
        """
}

#if canImport(JavaScriptCore)
/// Unicode search in JavaScriptCore. Some SDK builds miss matches involving astral characters
/// in unanchored searches. Sticky probes follow ECMA 262's `AdvanceStringIndex` at each scalar boundary.
///
/// `verdict` is `.some(nil)` when JavaScript refuses the pattern, `.some(true/false)` for its
/// answer, and `nil` when there is no trustworthy answer: JavaScriptCore backtracks, and on a
/// pathological pattern it stops at an internal limit after about a second and reports
/// "no match" — so an answer that took longer than 50 ms is discarded.
private final class ECMAOracle {
    private let context: JSContext
    private let function: JSValue

    init?() {
        guard let context = JSContext() else { return nil }
        context.evaluateScript(
            """
            function verdict(p, s) {
              var r;
              try { r = new RegExp(p, "uy"); } catch (e) { return "E"; }
              var offset = 0;
              while (true) {
                r.lastIndex = offset;
                if (r.test(s)) return "1";
                if (offset === s.length) return "0";
                offset += s.codePointAt(offset) > 0xFFFF ? 2 : 1;
              }
            }
            """)
        guard let function = context.objectForKeyedSubscript("verdict"), !function.isUndefined else { return nil }
        self.context = context
        self.function = function
    }

    func verdict(_ pattern: String, _ string: String) -> Bool?? {
        let start = DispatchTime.now().uptimeNanoseconds
        let answer = function.call(withArguments: [pattern, string])?.toString()
        guard DispatchTime.now().uptimeNanoseconds - start < 50_000_000 else { return nil }
        switch answer {
        case "1": return .some(true)
        case "0": return .some(false)
        case "E": return .some(nil)
        default: return nil
        }
    }

    /// A deviation of JavaScriptCore from ECMA 262: with the `u` flag it tries a match between
    /// the two halves of a surrogate pair, where `\B` holds (neither half is a word character).
    /// The specification advances by code point (`AdvanceStringIndex`), so `/\B/u.test("a😀b")`
    /// is false; JavaScriptCore says true. Limb answers as the specification does
    /// (`answersThatFollowFromTheSpecification`).
    static func isSurrogateBoundaryDeviation(_ pattern: String, _ string: String, expected: Bool?, actual: Bool?) -> Bool {
        expected == true && actual == false && pattern.contains(#"\B"#) && string.unicodeScalars.contains { $0.value > 0xFFFF }
    }
}
#endif

/// Small random patterns: atoms, groups of all kinds, alternation, every quantifier form.
private struct PatternGenerator {
    var state: UInt64
    let rich: Bool
    var groupNames = 0

    let atoms: [String]

    init(seed: UInt64, rich: Bool) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        self.rich = rich
        atoms = rich ? Self.richAtoms : Self.plainAtoms
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }

    static let plainAtoms = [
        "a", "b", "c", ".", #"\d"#, #"\w"#, #"\s"#, #"\W"#, "[ab]", "[^a]", "[a-c]", #"\b"#, #"\B"#, "^", "$", "()", "(?:)",
        #"\n"#, #"[\s\d]"#, "[^]", "[]",
    ]
    static let richAtoms = [
        "a", "b", "1", " ", "\u{E9}", "😀", ".", #"\d"#, #"\D"#, #"\w"#, #"\W"#, #"\s"#, #"\S"#, "[a-c1]", #"[^a\d]"#,
        #"[\s\w]"#, #"[^\W]"#, #"\b"#, #"\B"#, "^", "$", #"\p{L}"#, #"\P{Ll}"#, #"[\p{N}a]"#, #"[^\p{L}]"#, #"\u{1F600}"#,
        #"\uD83D\uDE00"#, #"\x61"#, #"\u0062"#, #"\n"#, #"\cJ"#, #"\0"#, #"[\u{e9}-\u{1F600}]"#, "[-a]", "[a-]", #"[\b]"#,
        #"\."#, #"\$"#, "[^]", "[]", "(?:)",
    ]
    static let quantifiers = ["", "", "", "*", "+", "?", "{2}", "{0,2}", "{1,}", "*?", "+?", "??", "{0}", "{1,3}?"]
    static let assertions: Set<String> = [#"\b"#, #"\B"#, "^", "$"]

    mutating func pattern(depth: Int = 0) -> String {
        var result = ""
        for _ in 0..<(Int(next() % 4) + 1) {
            var atom: String
            if depth < 3 && next() % 10 < 3 {
                let kind = next() % 4
                let opening = kind == 0 ? "(?:" : kind == 1 && rich ? "(?<g\(groupNames)>" : "("
                if kind == 1 && rich { groupNames += 1 }
                atom = opening + pattern(depth: depth + 1) + (next() % 2 == 0 ? "|" + pattern(depth: depth + 1) : "") + ")"
            } else {
                atom = pick(atoms)
            }
            if !Self.assertions.contains(atom) { atom += pick(Self.quantifiers) }
            result += atom
        }
        if next() % 5 == 0 { result += "|" + pattern(depth: depth + 1) }
        return result
    }

    static let plainAlphabet: [Character] = ["a", "b", "c", " ", "1", "\n", "\u{E9}"]
    static let richAlphabet: [Character] = [
        "a", "b", "1", " ", "\u{E9}", "😀", "\n", "\u{2028}", "\0", "\u{FFFD}", "\r", "_", "\u{FEFF}", "\u{85}", "A", "٣",
        "\u{301}",
    ]

    mutating func string() -> String {
        let alphabet = rich ? Self.richAlphabet : Self.plainAlphabet
        var result = ""
        // Unicode scalars, not Characters: "\r" then "\n" must stay two scalars in the count.
        for _ in 0..<Int(next() % 7) { result.unicodeScalars.append(contentsOf: pick(alphabet).unicodeScalars) }
        return result
    }
}
