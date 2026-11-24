/// A JSON-RPC request identifier, kept exactly as the peer sent it.
///
/// A numeric id is returned as the same number text and a string id as a string;
/// the two never convert into each other.
public enum RequestID: Sendable, Hashable, CustomStringConvertible {
    case string(String)
    /// Use an integer JSON number for protocol IDs.
    case number(JSONNumber)

    public init(_ value: Int) { self = .number(JSONNumber(value)) }
    public init(_ value: String) { self = .string(value) }

    /// Reads an ID from a message. An MCP ID is a string or a mathematical integer.
    public init?(json: JSONValue) {
        switch json {
        case .string(let value): self = .string(value)
        case .number(let value) where value.isInteger: self = .number(value)
        default: return nil
        }
    }

    public var json: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .number(let value): .number(value)
        }
    }

    public var description: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.lexeme
        }
    }

    /// Tests the byte count of the encoded ID, excluding the two framing quotes for a string.
    package func fitsEncodedByteLimit(_ limit: Int) -> Bool {
        switch self {
        case .number(let value):
            return value.lexeme.utf8.count <= limit
        case .string(let value):
            let utf8 = value.utf8
            let count = utf8.count
            guard count <= limit else { return false }

            // Both codecs write plain printable ASCII IDs without further escaping.
            if utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F && $0 != 0x22 && $0 != 0x5C }) {
                return true
            }

            var writer = JSONWriter(capacity: count)
            writer.write(value)
            return writer.bytes.count - 2 <= limit
        }
    }

    /// String ids are the same id only when they are the same bytes: `String`'s own `==` would
    /// make "é" and "e" + combining accent one id, and a cancellation for one would hit the other.
    public static func == (lhs: RequestID, rhs: RequestID) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a.isBytewiseEqual(to: b)
        case (.number(let a), .number(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let value):
            hasher.combine(0)
            hasher.combine(ExactString(value))
        case .number(let value):
            hasher.combine(1)
            hasher.combine(value)
        }
    }
}

extension RequestID: JSONEncodable {
    public func encode(to writer: inout JSONWriter) {
        switch self {
        case .string(let value): writer.write(value)
        case .number(let value): writer.write(value)
        }
    }
}

extension RequestID: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    public init(integerLiteral value: Int) { self.init(value) }
    public init(stringLiteral value: String) { self.init(value) }
}
