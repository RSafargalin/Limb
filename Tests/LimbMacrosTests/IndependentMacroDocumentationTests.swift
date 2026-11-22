import Limb
import Testing


private func normalized(_ text: String?) -> String? {
    guard let text else { return nil }
    var result = ""
    var pendingSpace = false
    for character in text {
        if character == " " || character == "\n" || character == "\t" || character == "\r" {
            pendingSpace = !result.isEmpty
        } else {
            if pendingSpace { result.append(" ") }
            pendingSpace = false
            result.append(character)
        }
    }
    return result
}

// MARK: - Fixtures: @Schema

/// Says "hi" to \(name), keeps a back\slash, a literal \n and \u{41}, #"raw"#, ${x}, 😀, «кавычки», 'single' & <tags>.
@Schema
private struct IMDocSpecial {
    /// Property with "quotes", a back\slash and \(interpolation).
    var a: Int
    /// Triple """ quotes and a trailing backslash \
    var b: Int
}

/// First line
/// continues here.
///
/// Second paragraph
/// also continues.
@Schema
private struct IMDocParagraphs {
    /// Property line one
    /// property line two.
    var a: Int
}

/**
 Block summary with "quotes" and \(interp).

 Second block paragraph.
 */
@Schema
private struct IMDocBlock {
    /** One-line block on a property. */
    var a: Int
    /**
     Multi-line block
     on a property.
     */
    var b: Int
}

/**
 * Starred summary.
 * More of it.
 */
@Schema
private struct IMDocStarred {
    var a: Int
}

// A plain comment is not documentation.
@Schema
private struct IMDocPlainComment {
    // Neither is this.
    var a: Int
    /* Nor this. */
    var b: Int
}

/// Real documentation.
// swiftlint:disable:next something
@Schema
private struct IMDocThenPlain {
    var a: Int
}

///No space after the slashes.
@Schema
private struct IMDocTight {
    ///Tight property.
    var a: Int
}

/// Uses `code`, *emphasis*, [a link](https://example.com/a?b=c&d=e) and a list:
/// - one
/// - two: with a colon
@Schema
private struct IMDocMarkup {
    var a: Int
}

/// Unicode: é (U+00E9), e\u{301} written out, 漢字, العربية, 👩‍👩‍👧‍👦, non‑breaking hyphen.
@Schema
private enum IMDocEnum: String {
    case a
}

// MARK: - Fixtures: @Tool

/// Tool summary with "quotes" and \(interpolation).
@Tool
private struct IMDocTool {
    /// The call's own summary is not the tool's description when the type has one.
    /// - Parameters:
    ///   - query: The "query" with \(text) and a back\slash.
    ///   - limit: How many, at most:
    ///     wrapped onto a second line.
    ///   - verbose: Say more.
    /// - Returns: The hits.
    /// - Throws: Nothing really.
    func call(query: String, limit: Int = 10, verbose: Bool?) -> String { query }
}

@Tool
private struct IMDocCallOnly {
    /// Looks things up.
    /// - Parameter key: The key: may contain a colon, https://example.com/x.
    /// - Parameter other: Second parameter.
    func call(key: String, other: Int) -> String { key }
}

@Tool
private struct IMDocNothing {
    func call(value: Int) -> Int { value }
}

@Tool
private struct IMDocOnlyParameters {
    /// - Parameters:
    ///   - value: Only the parameter is documented.
    func call(value: Int) -> Int { value }
}

/// Finds a route.
@Tool
private struct IMDocLabels {
    /// - Parameters:
    ///   - origin: Where to start.
    ///   - destination: Where to end.
    ///   - count: Unlabeled.
    func call(from origin: String, to destination: String, _ count: Int) -> String { origin + destination }
}

@Tool
private struct IMDocTrailingDiscussion {
    /// Summary first.
    ///
    /// - Parameters:
    ///   - a: First.
    ///
    /// Trailing discussion that belongs to the description.
    func call(a: Int) -> Int { a }
}

@Tool
private struct IMDocBlockParameters {
    /**
     Block tool summary.

     - Parameters:
       - a: First part
         second part.
       - b: Whole.
     - Returns: Something.
     */
    func call(a: Int, b: Int) -> Int { a + b }
}

@Tool
private struct IMDocMixedParameterForms {
    /// Mixed.
    /// - Parameter a: Single form.
    /// - Parameters:
    ///   - b: List form.
    /// - Parameter c: Single again.
    func call(a: Int, b: Int, c: Int) -> Int { a + b + c }
}

/// Described on the type.
@Tool
private struct IMDocBothSummaries {
    /// Described on the method.
    func call() {}
}

// MARK: - Tests

@Suite struct IndependentMacroDocumentationTests {
    @Test func specialCharactersArriveIntact() {
        #expect(
            IMDocSpecial.jsonSchema["description"]
                == "Says \"hi\" to \\(name), keeps a back\\slash, a literal \\n and \\u{41}, #\"raw\"#, ${x}, 😀, «кавычки», 'single' & <tags>.")
        #expect(
            IMDocSpecial.jsonSchema["properties"]?["a"]?["description"]
                == "Property with \"quotes\", a back\\slash and \\(interpolation).")
        #expect(IMDocSpecial.jsonSchema["properties"]?["b"]?["description"] == "Triple \"\"\" quotes and a trailing backslash \\")
        IndependentMacroCheckSchema(IMDocSpecial.jsonSchema)
    }

    @Test func linesAndParagraphs() {
        let description = IMDocParagraphs.jsonSchema["description"]?.stringValue
        #expect(normalized(description) == "First line continues here. Second paragraph also continues.")
        // The paragraph break survives in some form.
        #expect(description?.contains("here.\n") == true)
        #expect(normalized(IMDocParagraphs.jsonSchema["properties"]?["a"]?["description"]?.stringValue) == "Property line one property line two.")
    }

    @Test func blockComments() {
        let description = IMDocBlock.jsonSchema["description"]?.stringValue
        #expect(normalized(description) == "Block summary with \"quotes\" and \\(interp). Second block paragraph.")
        #expect(description?.contains("(interp).\n") == true)
        #expect(IMDocBlock.jsonSchema["properties"]?["a"]?["description"] == "One-line block on a property.")
        #expect(normalized(IMDocBlock.jsonSchema["properties"]?["b"]?["description"]?.stringValue) == "Multi-line block on a property.")
        #expect(normalized(IMDocStarred.jsonSchema["description"]?.stringValue) == "Starred summary. More of it.")
    }

    @Test func plainCommentsAreNotDescriptions() {
        #expect(IMDocPlainComment.jsonSchema["description"] == nil)
        #expect(IMDocPlainComment.jsonSchema["properties"]?["a"] == ["type": "integer"])
        #expect(IMDocPlainComment.jsonSchema["properties"]?["b"] == ["type": "integer"])
        #expect(IMDocThenPlain.jsonSchema["description"] == "Real documentation.")
    }

    @Test func noSpaceAfterTheSlashes() {
        #expect(IMDocTight.jsonSchema["description"] == "No space after the slashes.")
        #expect(IMDocTight.jsonSchema["properties"]?["a"]?["description"] == "Tight property.")
    }

    @Test func markupIsKeptAsText() {
        let description = normalized(IMDocMarkup.jsonSchema["description"]?.stringValue) ?? ""
        #expect(description.hasPrefix("Uses `code`, *emphasis*, [a link](https://example.com/a?b=c&d=e) and a list:"))
        #expect(description.contains("- one"))
        #expect(description.contains("- two: with a colon"))
    }

    @Test func unicodeArrivesIntact() {
        #expect(
            IMDocEnum.jsonSchema["description"]
                == "Unicode: é (U+00E9), e\\u{301} written out, 漢字, العربية, 👩‍👩‍👧‍👦, non‑breaking hyphen.")
        // Byte for byte, not merely canonically equivalent.
        #expect(
            IMDocEnum.jsonSchema["description"]?.stringValue.map { Array($0.utf8) }
                == Array("Unicode: é (U+00E9), e\\u{301} written out, 漢字, العربية, 👩‍👩‍👧‍👦, non‑breaking hyphen.".utf8))
    }

    @Test func toolDescriptionAndParameterDescriptions() {
        let definition = IMDocTool.definition
        #expect(definition.description == "Tool summary with \"quotes\" and \\(interpolation).")
        let properties = definition.inputSchema["properties"]
        #expect(properties?["query"] == ["type": "string", "description": "The \"query\" with \\(text) and a back\\slash."])
        #expect(normalized(properties?["limit"]?["description"]?.stringValue) == "How many, at most: wrapped onto a second line.")
        // The description of an optional argument sits next to its `anyOf`.
        #expect(properties?["verbose"] == ["anyOf": [["type": "boolean"], ["type": "null"]], "description": "Say more."])
        // Parameter notes are argument descriptions, not part of the tool's description.
        #expect(definition.description?.contains("query") == false)
        IndependentMacroCheckSchema(definition.inputSchema)
    }

    // observed, unspecified: with no comment on the type, the summary of `call` is used.
    @Test func descriptionFallsBackToTheMethodComment() {
        let definition = IMDocCallOnly.definition
        #expect(definition.description == "Looks things up.")
        let properties = definition.inputSchema["properties"]
        #expect(properties?["key"]?["description"] == "The key: may contain a colon, https://example.com/x.")
        #expect(properties?["other"]?["description"] == "Second parameter.")
        // The type's comment wins when both exist.
        #expect(IMDocBothSummaries.definition.description == "Described on the type.")
    }

    @Test func missingDocumentationIsAbsentNotEmpty() {
        #expect(IMDocNothing.definition.description == nil)
        #expect(IMDocNothing.definition.inputSchema["properties"]?["value"] == ["type": "integer"])
        #expect(IMDocOnlyParameters.definition.description == nil)
        #expect(IMDocOnlyParameters.definition.inputSchema["properties"]?["value"]?["description"] == "Only the parameter is documented.")
    }

    /// Swift documents a parameter under its parameter name (`origin`), not its argument label
    /// (`from`), so that is the name the lookup has to honour.
    @Test func parametersDocumentedByParameterNameAreFound() {
        let properties = IMDocLabels.definition.inputSchema["properties"]?.objectValue
        let descriptions = properties?.compactMap { $0.value["description"]?.stringValue }
        #expect(descriptions == ["Where to start.", "Where to end.", "Unlabeled."])
        #expect(IMDocLabels.definition.description == "Finds a route.")
    }

    @Test func singleAndListParameterFormsMix() {
        let properties = IMDocMixedParameterForms.definition.inputSchema["properties"]
        #expect(properties?["a"]?["description"] == "Single form.")
        #expect(properties?["b"]?["description"] == "List form.")
        #expect(properties?["c"]?["description"] == "Single again.")
        #expect(IMDocMixedParameterForms.definition.description == "Mixed.")
    }

    /// Text after the parameter list is still part of the comment's discussion; dropping it
    /// loses documentation the author wrote for the model.
    @Test func discussionAfterTheParameterListIsKept() {
        let description = IMDocTrailingDiscussion.definition.description ?? ""
        #expect(description.hasPrefix("Summary first."))
        #expect(description.contains("Trailing discussion that belongs to the description."))
        #expect(IMDocTrailingDiscussion.definition.inputSchema["properties"]?["a"]?["description"] == "First.")
    }

    /// The same parameter list in a `/** */` comment, where continuation lines are indented.
    @Test func wrappedParameterDescriptionInABlockComment() {
        let definition = IMDocBlockParameters.definition
        #expect(definition.description == "Block tool summary.")
        #expect(normalized(definition.inputSchema["properties"]?["a"]?["description"]?.stringValue) == "First part second part.")
        #expect(definition.inputSchema["properties"]?["b"]?["description"] == "Whole.")
    }

    /// A block comment in a file with Windows line endings: the carriage returns belong to the
    /// line endings, not to the text.
    @Test func carriageReturnsDoNotLeakIntoDescriptions() {
        let source = "/**\r\n Summary line.\r\n\r\n Second paragraph.\r\n */\r\n@Schema\r\nstruct S {\r\n    var a: Int\r\n}\r\n"
        let expansion = IndependentMacroExpansion(source)
        #expect(expansion.errors.isEmpty)
        #expect(expansion.expanded.contains("Summary line."))
        #expect(!expansion.expanded.contains("\\r"), "a carriage return was copied into a string literal")
    }
}
