public import LimbCore

/// A failure the tool wants the model to see.
///
/// Throwing `ToolError` from a tool produces a result with `isError: true` and this message,
/// which lets the model correct its call. Any other error is treated as a server fault and
/// answered with `-32603` without exposing its details.
public struct ToolError: Error, Sendable, CustomStringConvertible {
    public var message: String
    /// The result's `_meta`, as `ToolResult.meta`.
    public var meta: JSONObject?
    public init(_ message: String, meta: JSONObject? = nil) {
        self.message = message
        self.meta = meta
    }
    public var description: String { message }
}

/// The arguments of a tool call could not be read, although they passed the tool's input
/// schema — for example an integer too large for the tool's parameter type.
///
/// It is reported the way the negotiated revision reports invalid arguments: as a tool error
/// the model can read and correct from `2025-11-25` on, as `-32602` before.
public struct InvalidToolArguments: Error, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Input was requested where the peer cannot provide it: the client did not declare the
/// capability, or the negotiated revision does not define the request.
///
/// Thrown only for legacy peers, where a tool can fall back or report failure. Modern peers
/// get the protocol's own answer, `-32021`, with the missing capability.
public struct InputUnavailable: Error, Sendable, CustomStringConvertible {
    public var capability: String
    public var description: String { "the client does not support \(capability)" }
}

/// Handles `tools/call`. `arguments` have already been validated against the tool's input schema.
public typealias ToolHandler = @Sendable (_ arguments: JSONObject, _ context: RequestContext) async throws -> ToolResult

/// A tool declared as a type. The `@Tool` macro generates conformances; it can also be written by hand.
public protocol MCPTool: Sendable {
    static var definition: ToolDefinition { get }
    func call(arguments: JSONObject, context: RequestContext) async throws -> ToolResult
}

/// A `resources/read` request, with the variables matched from a URI template.
public struct ResourceRequest: Sendable {
    public let uri: String
    /// Template variables, percent-decoded. Empty for a fixed resource.
    ///
    /// They are the client's text: decoding turns `%2F` into `/`, and nothing stops `..`, so a
    /// value is not safe to use as a path component, or in a path, without checking it.
    public let variables: [String: String]
}

public typealias ResourceReader = @Sendable (_ request: ResourceRequest, _ context: RequestContext) async throws -> [ResourceContents]

public typealias PromptHandler = @Sendable (_ arguments: [String: String], _ context: RequestContext) async throws -> PromptResult

/// A `completion/complete` request for one argument.
public struct CompletionRequest: Sendable {
    public let argumentName: String
    /// What the user has typed so far.
    public let value: String
    /// Arguments already resolved, if the client sent them.
    public let resolvedArguments: [String: String]
}

public typealias CompletionHandler = @Sendable (_ request: CompletionRequest, _ context: RequestContext) async throws -> CompletionResult

/// Handles a method the typed API does not cover: raw params in, raw result out.
public typealias MethodHandler = @Sendable (_ params: JSONObject, _ context: RequestContext) async throws -> JSONObject

/// Why a registration was refused.
public struct RegistrationError: Error, Sendable, CustomStringConvertible {
    public var reason: String
    public var description: String { reason }
}

// MARK: - URI templates

/// An RFC 6570 template restricted to simple `{name}` and reserved `{+name}` expressions,
/// which is what resource templates use in practice.
struct URITemplate: Sendable {
    enum Part: Sendable {
        case literal([UInt8])
        /// A variable; `reserved` variables may contain `/`.
        case variable(name: String, reserved: Bool)
    }

    let parts: [Part]

    /// Templates and URIs are compared as bytes. `String` works in characters, and to it a `/`
    /// followed by a combining mark is not a slash, and two spellings of "é" are one text —
    /// neither is how a URI is read.
    init?(_ template: String) {
        let bytes = Array(template.utf8)
        var parts: [Part] = []
        var names: Set<String> = []
        var literal: [UInt8] = []
        var index = 0
        while index < bytes.count {
            // RFC 6570 allows neither brace in a literal: a lone "}" is a broken expression.
            if bytes[index] == 0x7D { return nil }
            guard bytes[index] == 0x7B else {
                literal.append(bytes[index])
                index += 1
                continue
            }
            guard let close = bytes[index...].firstIndex(of: 0x7D) else { return nil }
            var name = bytes[(index + 1)..<close]
            var reserved = false
            if name.first == 0x2B {
                reserved = true
                name = name.dropFirst()
            }
            // RFC 6570: a variable name is made of ASCII letters, digits and "_", in parts that
            // may be joined by single dots ("user.id"). Percent-encoded name characters are not
            // accepted.
            let isNameByte: (UInt8) -> Bool = { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
            }
            let pieces = name.split(separator: 0x2E, omittingEmptySubsequences: false)
            guard pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isNameByte) }) else { return nil }
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = []
            }
            let variable = String(decoding: name, as: UTF8.self)
            // A second variable of the same name would silently overwrite the first's value.
            guard !names.contains(variable) else { return nil }
            names.insert(variable)
            parts.append(.variable(name: variable, reserved: reserved))
            index = close + 1
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        self.parts = parts
    }

    /// The longest URI a template is matched against. Matching keeps a table of
    /// (template parts × URI bytes), and no resource is named by more than this.
    static let maxURIBytes = 64 * 1024

    /// Matches `uri` against the template, returning its variables.
    ///
    /// Each variable takes as much as it can while the rest still matches, as a greedy regular
    /// expression would. The answer is found without trying the alternatives one by one: a table
    /// of "can the rest of the template match from here" is filled from the end, so the time is
    /// proportional to the URI's length times the template's, whatever the URI. The request path
    /// runs this on the connection's reader, where a slow refusal would stall everything else.
    func match(_ uri: String) -> [String: String]? {
        let bytes = Array(uri.utf8)
        let count = bytes.count
        guard count <= URITemplate.maxURIBytes else { return nil }
        // Most URIs that do not match differ in the fixed text at either end; say so before
        // building a table for them. A read that misses pays this for every template.
        if case .literal(let text)? = parts.first, !bytes.starts(with: text) { return nil }
        if case .literal(let text)? = parts.last, !(bytes.count >= text.count && bytes.suffix(text.count).elementsEqual(text)) {
            return nil
        }

        // Where a variable that may not contain "/" has to stop.
        var nextSlash = [Int](repeating: count, count: count + 1)
        for position in stride(from: count - 1, through: 0, by: -1) {
            nextSlash[position] = bytes[position] == 0x2F ? position : nextSlash[position + 1]
        }
        // A value ends between characters, never inside one.
        func isBoundary(_ position: Int) -> Bool { position == count || bytes[position] & 0xC0 != 0x80 }

        // rest[i][p]: parts i… match the bytes from p to the end.
        var rest = [[Bool]](repeating: [], count: parts.count + 1)
        var row = [Bool](repeating: false, count: count + 1)
        row[count] = true
        rest[parts.count] = row
        for index in stride(from: parts.count - 1, through: 0, by: -1) {
            let after = rest[index + 1]
            row = [Bool](repeating: false, count: count + 1)
            switch parts[index] {
            case .literal(let text):
                if text.count <= count {
                    for position in 0...(count - text.count) where after[position + text.count] {
                        var equal = true
                        for offset in 0..<text.count where bytes[position + offset] != text[offset] {
                            equal = false
                            break
                        }
                        row[position] = equal
                    }
                }
            case .variable(_, let reserved):
                // The last place at or before each position where the value could end.
                var lastEnd = [Int](repeating: -1, count: count + 1)
                var latest = -1
                for position in 0...count {
                    if after[position], isBoundary(position) { latest = position }
                    lastEnd[position] = latest
                }
                for position in 0..<count {
                    // A value is never empty: it has to end after it starts.
                    row[position] = lastEnd[reserved ? count : nextSlash[position]] > position
                }
            }
            rest[index] = row
        }
        guard rest[0][0] else { return nil }

        // Walk forward, giving each variable the longest value that leaves the rest matchable.
        var variables: [String: String] = [:]
        var position = 0
        for (index, part) in parts.enumerated() {
            switch part {
            case .literal(let text):
                position += text.count
            case .variable(let name, let reserved):
                let after = rest[index + 1]
                var end = reserved ? count : nextSlash[position]
                while end > position, !(after[end] && isBoundary(end)) { end -= 1 }
                variables[name] = percentDecode(String(decoding: bytes[position..<end], as: UTF8.self))
                position = end
            }
        }
        return variables
    }

    /// Decodes `%XX` escapes. Text that is not a well-formed escape is left exactly as it is —
    /// `50%off` stays `50%off` — and so is the whole value when the decoded bytes are not UTF-8:
    /// a handler must never receive something the client did not send.
    private func percentDecode(_ text: String) -> String {
        guard text.contains("%") else { return text }
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            if source[index] == 0x25, index + 2 < source.count,
                let high = hex(source[index + 1]), let low = hex(source[index + 2])
            {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(validating: bytes, as: UTF8.self) ?? text
    }
}
