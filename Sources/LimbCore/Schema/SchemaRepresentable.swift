/// A type that knows its JSON Schema and converts to and from JSON.
///
/// This is what lets a tool be declared with ordinary Swift types: the schema sent to the
/// client, the decoding of arguments and the encoding of results all come from one declaration,
/// so they cannot drift apart. The `@Schema` macro generates conformances for structs and
/// string-backed enums; the standard scalar and collection types conform already.
public protocol SchemaRepresentable: JSONDecodable, JSONEncodable {
    /// The JSON Schema (2020-12) every value of this type satisfies, as a part of a larger
    /// schema that is being assembled.
    ///
    /// A type that contains other schema-representable types asks each of them through the same
    /// builder. That is what lets a type refer to itself: the builder notices the repeat and
    /// writes a `$ref` to a definition instead of descending forever.
    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject
    var jsonValue: JSONValue { get }
    /// Converts this value with a limit on nested JSON arrays and objects. A custom recursive
    /// conformer can override this method to check the limit before recursing.
    func jsonValue(maxDepth: Int) throws(JSONEncodingDepthError) -> JSONValue
}

/// A typed value needs more levels of JSON arrays and objects than the caller permits.
public struct JSONEncodingDepthError: Error, Sendable {
    public init() {}
}

extension SchemaRepresentable {
    /// The complete, self-contained schema of this type, with the `$defs` it refers to.
    public static var jsonSchema: JSONObject {
        var builder = SchemaBuilder()
        let schema = jsonSchema(in: &builder)
        return builder.finish(schema)
    }

    public func encode(to writer: inout JSONWriter) { writer.write(jsonValue) }

    public func jsonValue(maxDepth: Int) throws(JSONEncodingDepthError) -> JSONValue {
        let value = jsonValue
        // Custom conformers using the default method may already have built their tree.
        var pending = [(value, max(0, maxDepth))]
        while let (element, remaining) = pending.popLast() {
            switch element {
            case .array(let array):
                guard remaining > 0 else { throw JSONEncodingDepthError() }
                for child in array { pending.append((child, remaining - 1)) }
            case .object(let object):
                guard remaining > 0 else { throw JSONEncodingDepthError() }
                for (_, child) in object { pending.append((child, remaining - 1)) }
            default:
                break
            }
        }
        return value
    }
}

/// Assembles one schema document out of the schemas of the types it mentions.
///
/// Types that turn out to contain themselves are written once under `$defs` and referred to by
/// `$ref`; all other types are written in place.
public struct SchemaBuilder {
    var definitions = JSONObject()
    /// Named types whose schema is being built right now, outermost first.
    var open: [ObjectIdentifier] = []
    /// Named types that were asked for while they were still being built.
    var recursive: Set<ObjectIdentifier> = []
    /// The name each type goes by in `$defs`.
    var names: [ObjectIdentifier: String] = [:]
    var usedNames: Set<String> = []

    public init() {}

    /// The schema of a named type: `body` when the type does not contain itself, otherwise a
    /// reference to a definition holding `body`.
    public mutating func named(_ type: Any.Type, _ body: (inout SchemaBuilder) -> JSONObject) -> JSONObject {
        let identity = ObjectIdentifier(type)
        if open.contains(identity) || recursive.contains(identity) {
            recursive.insert(identity)
            return SchemaBuilder.reference(to: name(for: type))
        }
        open.append(identity)
        let schema = body(&self)
        open.removeLast()
        guard recursive.contains(identity) else { return schema }
        definitions[name(for: type)] = .object(schema)
        return SchemaBuilder.reference(to: name(for: type))
    }

    private static func reference(to name: String) -> JSONObject {
        ["$ref": .string("#/$defs/" + name)]
    }

    /// The type's name in this document: its own name, reduced to characters that need no
    /// escaping in a JSON pointer or a URI fragment, and numbered when another type already
    /// goes by it.
    ///
    /// Types are told apart by identity, not by name, so two types that share a name — in
    /// different namespaces, or with names that differ only outside ASCII — get two definitions.
    /// The name does not depend on anything that changes between launches: a listing must be
    /// the same every time, and must not show where the process keeps its metadata.
    private mutating func name(for type: Any.Type) -> String {
        let identity = ObjectIdentifier(type)
        if let known = names[identity] { return known }
        var base = ""
        for scalar in String(describing: type).unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "-", "_": base.unicodeScalars.append(scalar)
            default: base.append("_")
            }
        }
        if base.isEmpty { base = "Type" }
        var name = base
        var suffix = 2
        while usedNames.contains(name) {
            name = "\(base)_\(suffix)"
            suffix += 1
        }
        usedNames.insert(name)
        names[identity] = name
        return name
    }

    /// Completes the document: attaches the definitions that `schema` refers to.
    ///
    /// When the document as a whole is a recursive type, its root would be a bare `$ref`. The
    /// definition is written out at the root instead, so that the root says what it is — a tool's
    /// output schema, for one, has to be visibly an object.
    public func finish(_ schema: JSONObject) -> JSONObject {
        guard !definitions.isEmpty else { return schema }
        var schema = schema
        if schema.count == 1, let target = schema["$ref"]?.stringValue,
            case .object(let body)? = definitions[String(target.dropFirst("#/$defs/".count))]
        {
            schema = body
        }
        schema["$defs"] = .object(definitions)
        return schema
    }
}

extension String: SchemaRepresentable {
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject { ["type": "string"] }
    public var jsonValue: JSONValue { .string(self) }
}

extension Bool: SchemaRepresentable {
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject { ["type": "boolean"] }
    public var jsonValue: JSONValue { .bool(self) }
}

extension Int: SchemaRepresentable {
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject { ["type": "integer"] }
    public var jsonValue: JSONValue { .number(JSONNumber(self)) }
}

extension Int64: SchemaRepresentable {
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject { ["type": "integer"] }
    public var jsonValue: JSONValue { .number(JSONNumber(self)) }
}

extension Double: SchemaRepresentable {
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject { ["type": "number"] }
    /// NaN and the infinities have no JSON spelling and are written as `null`. A tool result
    /// that contains one fails its own output schema (the message says why); in a `Double?`
    /// property the `null` is allowed and reads as "no value", so check such values first.
    public var jsonValue: JSONValue { JSONValue(self) }
}

extension JSONValue: SchemaRepresentable {
    /// Any JSON value.
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject { [:] }
    public var jsonValue: JSONValue { self }
}

extension Array: SchemaRepresentable where Element: SchemaRepresentable {
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        ["type": "array", "items": .object(Element.jsonSchema(in: &builder))]
    }

    public var jsonValue: JSONValue { .array(map(\.jsonValue)) }

    public func jsonValue(maxDepth: Int) throws(JSONEncodingDepthError) -> JSONValue {
        guard maxDepth > 0 else { throw JSONEncodingDepthError() }
        var values: [JSONValue] = []
        values.reserveCapacity(count)
        for element in self { values.append(try element.jsonValue(maxDepth: maxDepth - 1)) }
        return .array(values)
    }
}

extension Optional: SchemaRepresentable where Wrapped: SchemaRepresentable {
    /// The wrapped type or `null`. An absent value is written as `null` wherever a value has to
    /// be written (an element of an array, a result), so the schema has to allow it; as a
    /// property it is simply left out, and the property is not required.
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        ["anyOf": [.object(Wrapped.jsonSchema(in: &builder)), ["type": "null"]]]
    }

    public var jsonValue: JSONValue { self?.jsonValue ?? .null }

    public func jsonValue(maxDepth: Int) throws(JSONEncodingDepthError) -> JSONValue {
        try self?.jsonValue(maxDepth: maxDepth) ?? .null
    }
}

/// Lets generic code ask "is this type an Optional?" and "is this value absent?" without
/// knowing the wrapped type — including for type aliases, which no macro can see through.
protocol AbsentRepresentable {
    static var absent: Self { get }
    var isAbsent: Bool { get }
}

extension Optional: AbsentRepresentable {
    static var absent: Wrapped? { nil }
    var isAbsent: Bool { self == nil }
}

extension Dictionary: JSONEncodable where Key == String, Value: JSONEncodable {
    /// Keys are written in sorted order, so output is deterministic.
    public func encode(to writer: inout JSONWriter) {
        writer.beginObject()
        for key in keys.sorted() {
            writer.key(key)
            // Every key comes from the dictionary itself.
            self[key]!.encode(to: &writer)
        }
        writer.endObject()
    }
}

extension Dictionary: SchemaRepresentable where Key == String, Value: SchemaRepresentable {
    public static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        ["type": "object", "additionalProperties": .object(Value.jsonSchema(in: &builder))]
    }

    public var jsonValue: JSONValue {
        // Every key comes from the dictionary itself.
        .object(JSONObject(keys.sorted().map { ($0, self[$0]!.jsonValue) }))
    }

    public func jsonValue(maxDepth: Int) throws(JSONEncodingDepthError) -> JSONValue {
        guard maxDepth > 0 else { throw JSONEncodingDepthError() }
        var object = JSONObject(minimumCapacity: count)
        for (key, value) in sorted(by: { $0.key < $1.key }) {
            object.appendUnchecked(key, try value.jsonValue(maxDepth: maxDepth - 1))
        }
        return .object(object)
    }
}

/// Helpers the `@Schema` and `@Tool` macros expand to. Not meant to be called by hand.
public enum SchemaSupport {
    /// The members of an object schema, collected one by one.
    public struct Fields {
        var properties = JSONObject()
        var required: [JSONValue] = []

        public init() {}

        /// Adds a member of type `T`. It is required unless it has a default or `T` is optional.
        public mutating func add<T: SchemaRepresentable>(
            _ name: String, _ type: T.Type, description: String?, hasDefault: Bool,
            in builder: inout SchemaBuilder
        ) {
            var schema = T.jsonSchema(in: &builder)
            if let description { schema["description"] = .string(description) }
            properties[name] = .object(schema)
            if !hasDefault, !(T.self is any AbsentRepresentable.Type) { required.append(.string(name)) }
        }

        /// The same, naming the member by its key path: generated code can then state a
        /// property's type without spelling it.
        public mutating func add<Root, T: SchemaRepresentable>(
            _ name: String, _ keyPath: KeyPath<Root, T>, description: String?, hasDefault: Bool,
            in builder: inout SchemaBuilder
        ) {
            add(name, T.self, description: description, hasDefault: hasDefault, in: &builder)
        }

        @available(
            *, unavailable,
            message: "this type has no JSON Schema, so it cannot be a tool argument: use String, Bool, Int, Double, arrays, optionals, [String: …] or a @Schema type"
        )
        @_disfavoredOverload
        public mutating func add<T>(
            _ name: String, _ type: T.Type, description: String?, hasDefault: Bool, in builder: inout SchemaBuilder
        ) {}

        @available(
            *, unavailable,
            message: "the type of this property has no JSON Schema: use String, Bool, Int, Double, arrays, optionals, [String: …] or a @Schema type"
        )
        @_disfavoredOverload
        public mutating func add<Root, T>(
            _ name: String, _ keyPath: KeyPath<Root, T>, description: String?, hasDefault: Bool,
            in builder: inout SchemaBuilder
        ) {}

        /// The finished object schema.
        public func schema(description: String?) -> JSONObject {
            var schema: JSONObject = ["type": "object"]
            if let description { schema["description"] = .string(description) }
            schema["properties"] = .object(properties)
            schema["required"] = .array(required)
            return schema
        }
    }

    /// Decodes a member. An absent member is `nil` for an optional type and an error otherwise.
    public static func decode<T: JSONDecodable>(_ object: JSONObject, _ key: String) throws(JSONDecodingError) -> T {
        guard let value = object[key] else {
            // `optional` is `T.self`, so its `absent` is a `T`.
            if let optional = T.self as? any AbsentRepresentable.Type { return optional.absent as! T }
            throw JSONDecodingError("missing required field", path: [key])
        }
        do {
            return try T(json: value)
        } catch {
            throw error.nested(in: key)
        }
    }

    @available(*, unavailable, message: "this type cannot be read from JSON; see the error where it is added to the schema")
    @_disfavoredOverload
    public static func decode<T>(_ object: JSONObject, _ key: String) throws(JSONDecodingError) -> T {
        throw JSONDecodingError("unsupported type")
    }

    @available(*, unavailable, message: "this type cannot be read from JSON; see the error where it is added to the schema")
    @_disfavoredOverload
    public static func decode<T>(
        _ object: JSONObject, _ key: String, default defaultValue: @autoclosure () -> T
    ) throws(JSONDecodingError) -> T {
        defaultValue()
    }

    /// Decodes a member that has a default. Only an absent key uses the default.
    public static func decode<T: JSONDecodable>(
        _ object: JSONObject, _ key: String, default defaultValue: @autoclosure () -> T
    ) throws(JSONDecodingError) -> T {
        guard let value = object[key] else { return defaultValue() }
        do {
            return try T(json: value)
        } catch {
            throw error.nested(in: key)
        }
    }

    /// Decodes a member of the type `keyPath` leads to. An absent key leaves its default intact.
    /// A present JSON null is decoded by the property type.
    public static func decodeIfPresent<Root, T: JSONDecodable>(
        _ object: JSONObject, _ key: String, for keyPath: KeyPath<Root, T>
    ) throws(JSONDecodingError) -> T? {
        guard let value = object[key] else { return nil }
        do {
            return .some(try T(json: value))
        } catch {
            throw error.nested(in: key)
        }
    }

    /// Adds a member. Defaulted optional properties need explicit nulls to round-trip `nil`.
    public static func set<T: SchemaRepresentable>(_ object: inout JSONObject, _ key: String, _ value: T, includeNil: Bool = false) {
        if !includeNil, let optional = value as? any AbsentRepresentable, optional.isAbsent { return }
        object.appendUnchecked(key, value.jsonValue)
    }

    public static func set<T: SchemaRepresentable>(
        _ object: inout JSONObject, _ key: String, _ value: T, includeNil: Bool = false, maxDepth: Int
    ) throws(JSONEncodingDepthError) {
        if !includeNil, let optional = value as? any AbsentRepresentable, optional.isAbsent { return }
        object.appendUnchecked(key, try value.jsonValue(maxDepth: maxDepth))
    }
}
