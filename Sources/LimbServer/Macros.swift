public import LimbCore

/// Declares an MCP tool as a type.
///
/// The `call` method's parameters are the tool's arguments; stored properties are its
/// dependencies. The name defaults to the type's name in snake case, the description comes from
/// the `///` comment, argument descriptions from its `- Parameters:` section, and the input and
/// output schemas from the Swift types.
///
/// ```swift
/// /// Current weather for a location.
/// @Tool(readOnly: true)
/// struct Weather {
///     let service: WeatherService
///
///     /// - Parameters:
///     ///   - location: City name or coordinates.
///     ///   - units: Units of measurement.
///     func call(location: String, units: Units = .metric, context: ToolContext) async throws -> Forecast {
///         try await service.forecast(for: location, units: units)
///     }
/// }
/// ```
///
/// Parameters need types that conform to `SchemaRepresentable` (scalars, arrays, optionals,
/// string-keyed dictionaries and `@Schema` types); anything else is a compile-time error.
/// A parameter of type `ToolContext` receives the request context and is not an argument.
///
/// A tool type isolated to a global actor works when the attribute is written on the type
/// (`@MainActor @Tool struct …`): the macro then makes `definition` nonisolated. Isolation the
/// macro cannot see in the declaration — inferred from a `@MainActor` protocol the type
/// conforms to, or a global actor spelled through a lowercase typealias — still fails to
/// compile with "conformance … crosses into main actor-isolated code"; write the attribute on
/// the tool type itself.
@attached(member, names: named(definition), named(call(arguments:context:)), named(__limbDefault(__limbArgument:)))
@attached(extension, conformances: MCPTool)
public macro Tool(
    _ name: String? = nil, title: String? = nil, readOnly: Bool? = nil, destructive: Bool? = nil,
    idempotent: Bool? = nil, openWorld: Bool? = nil
) = #externalMacro(module: "LimbMacros", type: "ToolMacro")

/// Derives a JSON Schema and JSON conversion for a struct or a string-backed enum.
///
/// Property descriptions come from their `///` comments. Optional properties and properties
/// with default values are not required.
@attached(
    extension, conformances: SchemaRepresentable,
    names: named(jsonSchema(in:)), named(init(json:)), named(jsonValue))
public macro Schema() = #externalMacro(module: "LimbMacros", type: "SchemaMacro")

/// Helpers the `@Tool` macro expands to. Not meant to be called by hand.
public enum ToolSupport {
    public static func result(_ value: ToolResult) -> ToolResult { value }
    public static func result(_ value: String) -> ToolResult { .text(value) }
    public static func result(_ value: [ContentBlock]) -> ToolResult { ToolResult(content: value) }
    public static func result(_ value: ContentBlock) -> ToolResult { ToolResult(content: [value]) }
    public static func result<T: SchemaRepresentable>(_ value: T) -> ToolResult { .structured(value.jsonValue) }

    public static func outputSchema(_ type: ToolResult.Type) -> JSONObject? { nil }
    public static func outputSchema(_ type: String.Type) -> JSONObject? { nil }
    public static func outputSchema(_ type: [ContentBlock].Type) -> JSONObject? { nil }
    public static func outputSchema(_ type: ContentBlock.Type) -> JSONObject? { nil }

    /// Revisions before `2026-07-28` allow only object schemas for structured output, so other
    /// result types are sent without a declared schema.
    public static func outputSchema<T: SchemaRepresentable>(_ type: T.Type) -> JSONObject? {
        let schema = T.jsonSchema
        return schema["type"] == "object" ? schema : nil
    }

    @available(
        *, unavailable,
        message: "a tool cannot return this type: return String, ToolResult, content blocks, or a type with a JSON Schema (@Schema, scalars, arrays, optionals, [String: …])"
    )
    @_disfavoredOverload
    public static func result<T>(_ value: T) -> ToolResult { ToolResult() }

    @available(*, unavailable, message: "this result type has no JSON Schema; see the error on the tool's 'call' method")
    @_disfavoredOverload
    public static func outputSchema<T>(_ type: T.Type) -> JSONObject? { nil }

    /// The error for arguments that passed the schema and still could not be decoded.
    public static func invalidArguments(_ error: JSONDecodingError) -> any Error {
        InvalidToolArguments(error.description)
    }
}

/// Collects tools for `Server(name:version:tools:)`.
@resultBuilder
public enum ToolListBuilder {
    public static func buildExpression(_ tool: any MCPTool) -> [any MCPTool] { [tool] }

    @available(*, unavailable, message: "only tools can be listed here; is the type missing @Tool?")
    @_disfavoredOverload
    public static func buildExpression<T>(_ value: T) -> [any MCPTool] { [] }
    public static func buildBlock(_ parts: [any MCPTool]...) -> [any MCPTool] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any MCPTool]?) -> [any MCPTool] { part ?? [] }
    public static func buildEither(first part: [any MCPTool]) -> [any MCPTool] { part }
    public static func buildEither(second part: [any MCPTool]) -> [any MCPTool] { part }
    public static func buildArray(_ parts: [[any MCPTool]]) -> [any MCPTool] { parts.flatMap { $0 } }
}

extension Server {
    /// Creates a server with the given tools.
    ///
    /// ```swift
    /// let server = try Server(name: "weather", version: "1.0.0") {
    ///     Weather(service: service)
    ///     Alerts(service: service)
    /// }
    /// ```
    ///
    /// - Parameter configure: Adjusts the rest of the configuration before the server is
    ///   created, as in `init(name:version:title:instructions:configure:)`. Leaves it unchanged
    ///   by default.
    public convenience init(
        name: String, version: String, title: String? = nil, instructions: String? = nil,
        configure: (inout ServerConfiguration) -> Void = { _ in },
        @ToolListBuilder tools: () -> [any MCPTool]
    ) throws(RegistrationError) {
        self.init(name: name, version: version, title: title, instructions: instructions, configure: configure)
        for tool in tools() { try register(tool) }
    }
}
