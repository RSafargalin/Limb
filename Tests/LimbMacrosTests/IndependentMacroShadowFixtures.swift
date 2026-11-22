import Limb


private struct String {}
private struct Optional {}
private struct Bool {}
private struct Int {}
private struct Int64 {}
private struct Double {}
private struct Array {}
private struct Dictionary {}
private struct Void {}
private struct Error {}

private struct JSONValue {}
private struct JSONObject {}
private struct JSONNumber {}
private struct JSONDecodingError {}
private struct JSONSchema {}
private struct SchemaBuilder {}
private enum SchemaSupport {}
private enum ToolSupport {}
private struct ToolResult {}
private struct ToolDefinition {}
private struct ToolAnnotations {}
private struct ToolError {}
private struct MCPError {}
private struct InvalidToolArguments {}
private struct ContentBlock {}
private struct Server {}
private protocol SchemaRepresentable {}
private protocol JSONDecodable {}
private protocol JSONEncodable {}
private protocol MCPTool {}

/// Shadowed.
@Schema
struct IndependentMacroShadowThing: Equatable {
    /// A number.
    var number: Swift.Int
    var text: Swift.String?
    var list: [Swift.String] = []
    var flags: [Swift.String: Swift.Bool] = [:]
    var ratio: Swift.Double = 0.5
}

/// Shadowed tool.
@Tool(readOnly: true)
struct IndependentMacroShadowTool {
    /// - Parameter number: A number.
    func call(number: Swift.Int, text: Swift.String? = nil, flag: Swift.Bool = true) throws -> IndependentMacroShadowThing {
        IndependentMacroShadowThing(number: number, text: text, flags: ["flag": flag])
    }
}

/// A fixture.
@Tool
struct IndependentMacroShadowVoidTool {
    func call() {}
}
