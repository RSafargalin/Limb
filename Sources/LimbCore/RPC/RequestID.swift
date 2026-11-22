/// A JSON-RPC request identifier, kept exactly as the peer sent it.
///
/// A numeric id is returned as the same number text and a string id as a string;
/// the two never convert into each other.
public enum RequestID: Sendable, Hashable, CustomStringConvertible {
    case string(String)
    case number(JSONNumber)

    public init(_ value: Int) { self = .number(JSONNumber(value)) }
    public init(_ value: String) { self = .string(value) }

    /// Reads an id from a message. `null` and non-scalar ids are not valid in MCP.
    public init?(json: JSONValue) {
        switch json {
        case .string(let value): self = .string(value)
        case .number(let value): self = .number(value)
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
