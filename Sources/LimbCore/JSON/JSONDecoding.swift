/// A typed-decoding failure that names the field it happened in.
public struct JSONDecodingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Path from the decoded root to the offending value, outermost first.
    public var path: [String]
    public var reason: String

    public init(_ reason: String, path: [String] = []) {
        self.reason = reason
        self.path = path
    }

    /// The same error, located one level further out.
    public func nested(in component: String) -> JSONDecodingError {
        JSONDecodingError(reason, path: [component] + path)
    }

    public var description: String {
        path.isEmpty ? reason : "\(path.joined(separator: ".")): \(reason)"
    }

    static func typeMismatch(expected: String, got value: JSONValue) -> JSONDecodingError {
        JSONDecodingError("expected \(expected), got \(value.typeName)")
    }
}

/// A type that reads itself from an already-parsed JSON value.
///
/// Decoding is direct: no `Decoder`, no containers. The `@Schema` macro generates conformances.
public protocol JSONDecodable {
    init(json: JSONValue) throws(JSONDecodingError)
}

extension JSONValue: JSONDecodable {
    public init(json: JSONValue) { self = json }
}

extension JSONObject: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .object(let object) = json else { throw .typeMismatch(expected: "object", got: json) }
        self = object
    }
}

extension String: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .string(let value) = json else { throw .typeMismatch(expected: "string", got: json) }
        self = value
    }
}

extension Bool: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .bool(let value) = json else { throw .typeMismatch(expected: "boolean", got: json) }
        self = value
    }
}

extension Int: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .number(let number) = json, number.isInteger else {
            throw .typeMismatch(expected: "integer", got: json)
        }
        guard let value = number.intValue else {
            throw JSONDecodingError("integer is out of range: it must fit in 64 bits")
        }
        self = value
    }
}

extension Int64: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .number(let number) = json, number.isInteger else {
            throw .typeMismatch(expected: "integer", got: json)
        }
        guard let value = number.int64Value else {
            throw JSONDecodingError("integer is out of range: it must fit in 64 bits")
        }
        self = value
    }
}

extension Double: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .number(let number) = json else { throw .typeMismatch(expected: "number", got: json) }
        let value = number.doubleValue
        guard value.isFinite else { throw JSONDecodingError("number is out of range for a double") }
        self = value
    }
}

extension Array: JSONDecodable where Element: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .array(let elements) = json else { throw .typeMismatch(expected: "array", got: json) }
        var result: [Element] = []
        result.reserveCapacity(elements.count)
        for (index, element) in elements.enumerated() {
            do {
                result.append(try Element(json: element))
            } catch {
                throw error.nested(in: "[\(index)]")
            }
        }
        self = result
    }
}

extension Optional: JSONDecodable where Wrapped: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        if case .null = json { self = nil } else { self = try Wrapped(json: json) }
    }
}

extension Dictionary: JSONDecodable where Key == String, Value: JSONDecodable {
    public init(json: JSONValue) throws(JSONDecodingError) {
        guard case .object(let object) = json else { throw .typeMismatch(expected: "object", got: json) }
        var result: [String: Value] = [:]
        result.reserveCapacity(object.count)
        for (key, value) in object {
            let decoded: Value
            do {
                decoded = try Value(json: value)
            } catch {
                throw error.nested(in: key)
            }
            // A Swift dictionary treats canonically equivalent strings as one key, a JSON object
            // does not: "é" as one code point and as "e" plus an accent are two members. Keeping
            // one of them would drop a value the schema validator has already accepted.
            if result.updateValue(decoded, forKey: key) != nil {
                throw JSONDecodingError(
                    "the object has another member whose name differs from this one only in Unicode normalization",
                    path: [key])
            }
        }
        self = result
    }
}

extension JSONObject {
    /// Decodes a member that must be present.
    public func required<T: JSONDecodable>(_ key: String, as type: T.Type = T.self) throws(JSONDecodingError) -> T {
        guard let value = self[key] else { throw JSONDecodingError("missing required field", path: [key]) }
        do {
            return try T(json: value)
        } catch {
            throw error.nested(in: key)
        }
    }

    /// Decodes a member that may be absent; an explicit `null` also yields `nil`.
    public func optional<T: JSONDecodable>(_ key: String, as type: T.Type = T.self) throws(JSONDecodingError) -> T? {
        guard let value = self[key], !value.isNull else { return nil }
        do {
            return try T(json: value)
        } catch {
            throw error.nested(in: key)
        }
    }
}
