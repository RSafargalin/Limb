import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A macro error or warning attached to the piece of source that caused it.
struct MacroMessage: DiagnosticMessage {
    let message: String
    let severity: DiagnosticSeverity
    var diagnosticID: MessageID { MessageID(domain: "Limb", id: severity == .error ? "error" : "warning") }
}

/// An error reported on `node` rather than on the macro attribute.
func failure(_ message: String, at node: some SyntaxProtocol) -> DiagnosticsError {
    DiagnosticsError(diagnostics: [
        Diagnostic(node: Syntax(node), message: MacroMessage(message: message, severity: .error))
    ])
}

func warn(_ message: String, at node: some SyntaxProtocol, in context: some MacroExpansionContext) {
    context.diagnose(Diagnostic(node: Syntax(node), message: MacroMessage(message: message, severity: .warning)))
}

/// The text of a declaration's documentation comment, split into its summary and parameter notes.
struct Documentation {
    var summary: String?
    var parameters: [String: String] = [:]

    init(_ trivia: Trivia) {
        var lines: [String] = []
        for piece in trivia {
            switch piece {
            case .docLineComment(let text):
                var line = Substring(text).dropFirst(3)
                if line.hasPrefix(" ") { line = line.dropFirst() }
                lines.append(String(line))
            case .docBlockComment(let text):
                let body = text.dropFirst(3).dropLast(2)
                // Characters are split, not grapheme clusters: "\r\n" is one Character.
                for raw in body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
                    var line = raw.drop { $0 == " " || $0 == "\t" }
                    if line.hasPrefix("*") { line = line.dropFirst() }
                    if line.hasPrefix(" ") { line = line.dropFirst() }
                    lines.append(String(line))
                }
            default: break
            }
        }

        enum Section { case discussion, parameters, other }
        var section = Section.discussion
        var discussion: [String] = []
        /// The parameter whose description the next unmarked line continues.
        var current: String?
        var afterBlankLine = false
        for line in lines {
            let trimmed = line.trimmingWhitespace()
            if trimmed.isEmpty {
                afterBlankLine = true
                if section == .discussion { discussion.append("") }
                continue
            }
            defer { afterBlankLine = false }
            if trimmed.hasPrefix("- Parameters:") {
                section = .parameters
                current = nil
                continue
            }
            if trimmed.hasPrefix("- Parameter ") {
                section = .parameters
                let rest = trimmed.dropFirst("- Parameter ".count)
                if let colon = rest.firstIndex(of: ":") {
                    let name = String(rest[..<colon]).trimmingWhitespace()
                    parameters[name] = String(rest[rest.index(after: colon)...]).trimmingWhitespace()
                    current = name
                }
                continue
            }
            if trimmed.hasPrefix("- Returns:") || trimmed.hasPrefix("- Throws:") || trimmed.hasPrefix("- Note:") {
                section = .other
                current = nil
                continue
            }
            if section == .parameters, trimmed.hasPrefix("- "), let colon = trimmed.firstIndex(of: ":") {
                let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon]).trimmingWhitespace()
                parameters[name] = String(trimmed[trimmed.index(after: colon)...]).trimmingWhitespace()
                current = name
                continue
            }
            if afterBlankLine, section != .discussion {
                // A paragraph after a list belongs to the discussion again.
                section = .discussion
                current = nil
                discussion.append("")
            }
            switch section {
            case .parameters:
                // A wrapped continuation of the parameter's description.
                if let name = current { parameters[name, default: ""] += " " + trimmed }
            case .other:
                break
            case .discussion:
                discussion.append(trimmed)
            }
        }
        // Paragraph breaks survive; lines inside a paragraph are joined.
        var paragraphs: [String] = []
        var paragraph: [String] = []
        for line in discussion {
            if line.isEmpty {
                if !paragraph.isEmpty { paragraphs.append(paragraph.joined(separator: " ")) }
                paragraph = []
            } else {
                paragraph.append(line)
            }
        }
        if !paragraph.isEmpty { paragraphs.append(paragraph.joined(separator: " ")) }
        self.summary = paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var view = self[...]
        while let first = view.first, first == " " || first == "\t" || first == "\r" { view = view.dropFirst() }
        while let last = view.last, last == " " || last == "\t" || last == "\r" { view = view.dropLast() }
        return String(view)
    }

    /// A Swift string literal with this content.
    var literal: String {
        var result = "\""
        for scalar in unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// The identifier without the backticks that let a keyword be used as a name.
    var withoutBackticks: String {
        hasPrefix("`") && hasSuffix("`") && count > 2 ? String(dropFirst().dropLast()) : self
    }

    /// `WeatherForecast` becomes `weather_forecast`; `HTTPFetch` becomes `http_fetch`.
    var snakeCased: String {
        let characters = Array(self)
        var result = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase, index > 0 {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                    result.append("_")
                }
            }
            result += character.lowercased()
        }
        return result
    }
}

extension Optional where Wrapped == String {
    /// A Swift expression: a string literal, or `nil`.
    var literalOrNil: String { self?.literal ?? "nil" }
}

/// `public ` or `package ` if the declaration is; otherwise nothing.
func accessPrefix(of declaration: some DeclGroupSyntax) -> String {
    for modifier in declaration.modifiers {
        switch modifier.name.tokenKind {
        case .keyword(.public), .keyword(.open): return "public "
        case .keyword(.package): return "package "
        default: continue
        }
    }
    return ""
}

/// The last component of a possibly qualified type name: `Swift.String` gives `String`.
func baseName(of type: TypeSyntax) -> String? {
    if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
    if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
    return nil
}

/// Where a mistake about the declaration as a whole is reported: its first modifier, or the
/// keyword that opens it (`struct`, `enum`, …) — not the macro attribute above it.
func introducer(of declaration: some DeclGroupSyntax) -> Syntax {
    if let modifier = declaration.modifiers.first { return Syntax(modifier) }
    if let node = declaration.as(StructDeclSyntax.self) { return Syntax(node.structKeyword) }
    if let node = declaration.as(EnumDeclSyntax.self) { return Syntax(node.enumKeyword) }
    if let node = declaration.as(ClassDeclSyntax.self) { return Syntax(node.classKeyword) }
    if let node = declaration.as(ActorDeclSyntax.self) { return Syntax(node.actorKeyword) }
    if let node = declaration.as(ProtocolDeclSyntax.self) { return Syntax(node.protocolKeyword) }
    if let node = declaration.as(ExtensionDeclSyntax.self) { return Syntax(node.extensionKeyword) }
    return Syntax(declaration)
}
