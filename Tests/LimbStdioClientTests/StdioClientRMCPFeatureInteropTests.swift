#if os(macOS)
import Foundation
import Limb
import Testing

// Supply completion and legacy elicitation with startup diagnostics on stderr,
// and the MRTR weather handler with a stdio launcher in place of its duplex demo.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["LIMB_RMCP_EXAMPLES_DIR"] != nil,
        "Set LIMB_RMCP_EXAMPLES_DIR to the absolute directory of the stdio-compatible rmcp-v3.11.0 examples"
    ),
    .timeLimit(.minutes(1))
)
struct StdioClientRMCPFeatureInteropTests {
    @Test(arguments: [ProtocolVersion.v2025_06_18, .v2025_11_25, .v2026_07_28])
    func structuredOutput(_ version: ProtocolVersion) async throws {
        try await withExample("servers_structured_output", version: version) { client in
            let catalog = try await client.listTools(options: interopRequestOptions)
            let calculate = try #require(catalog.value.items.first { $0.name == "calculate" })
            let schema = try #require(calculate.outputSchema)
            #expect(schema["type"] == "object")
            #expect(schema["properties"]?["result"]?["type"] == "number")
            #expect(schema["properties"]?["operation"]?["type"] == "string")
            #expect(schema["properties"]?["input_count"]?["type"] == "integer")

            let arguments: JSONObject = ["numbers": [2, 3, 5], "operation": "sum"]
            let result = try await client.callTool(calculate, arguments: arguments, options: interopRequestOptions)
            #expect(result.value.isError == false)
            let output = try #require(result.raw["structuredContent"])
            #expect(output["result"]?.doubleValue == 10)
            #expect(output["operation"] == "sum")
            #expect(output["input_count"] == 3)

            let typed = try await client.callTool(
                calculate, arguments: arguments, decoding: CalculationOutput.self, options: interopRequestOptions
            )
            let typedOutput = try #require(typed.value.output)
            #expect(typedOutput.result == 10)
            #expect(typedOutput.operation == "sum")
            #expect(typedOutput.inputCount == 3)
        }
    }

    @Test(arguments: [ProtocolVersion.v2025_03_26, .v2025_06_18, .v2025_11_25])
    func sampling(_ version: ProtocolVersion) async throws {
        let question = "What is the sum of two and three?"
        let answer = "The sum is five."
        let expectedMessages: JSONValue = [["role": "user", "content": ["type": "text", "text": .string(question)]]]
        let handlers = ClientInputHandlers(sample: { request, context in
            #expect(context.protocolVersion.rawValue == version.rawValue)
            #expect(context.method == "sampling/createMessage")
            #expect(request.params["messages"] == expectedMessages)
            #expect(request.params["maxTokens"] == 150)
            return .init(role: .assistant, content: ["type": "text", "text": .string(answer)], model: "fixture")
        })
        try await withExample("servers_sampling_stdio", version: version, handlers: handlers) { client in
            let result = try await client.callTool(
                "ask_llm", arguments: ["question": .string(question)], options: interopRequestOptions
            )
            #expect(result.value.isError == false)
            #expect(result.value.content == [.text("Question: \(question)\nAnswer: \(answer)")])
        }
    }

    @Test(arguments: [ProtocolVersion.v2025_06_18, .v2025_11_25])
    func formElicitation(_ version: ProtocolVersion) async throws {
        let handlers = ClientInputHandlers(elicitForm: { request, context in
            #expect(context.protocolVersion.rawValue == version.rawValue)
            #expect(context.method == "elicitation/create")
            #expect(request.message == "Please provide your name")
            return .init(action: .accept, content: ["name": "Ada"])
        })
        try await withExample("servers_elicitation_stdio", version: version, handlers: handlers) { client in
            let result = try await client.callTool(
                "greet_user", arguments: ["greeting": "Hello"], options: interopRequestOptions
            )
            #expect(result.value.isError == false)
            #expect(result.value.content == [.text("Hello Ada!")])
        }
    }

    @Test func modernFormElicitation() async throws {
        let version = ProtocolVersion.v2026_07_28
        let handlers = ClientInputHandlers(elicitForm: { request, context in
            #expect(context.protocolVersion.rawValue == version.rawValue)
            #expect(context.method == "elicitation/create")
            #expect(context.requestKey == "city")
            #expect(context.legacyRequestID == nil)
            #expect(request.message == "Which city do you want the weather for?")
            return .init(action: .accept, content: ["city": "Paris"])
        })
        try await withExample("servers_mrtr", version: version, handlers: handlers) { client in
            let result = try await client.callTool("weather", options: interopRequestOptions)
            #expect(result.value.isError == false)
            #expect(result.value.content == [.text("It is sunny in Paris.")])
        }
    }

    @Test func urlElicitation() async throws {
        let version = ProtocolVersion.v2025_11_25
        let handlers = ClientInputHandlers(elicitURL: { request, context in
            #expect(context.protocolVersion.rawValue == version.rawValue)
            #expect(context.method == "elicitation/create")
            #expect(request == ElicitRequest(
                message: "User must visit the following URL to complete tool call",
                url: "https://example.com/complete_tool", elicitationID: "elicit_123"
            ))
            return .init(action: .accept)
        })
        try await withExample("servers_elicitation_stdio", version: version, handlers: handlers) { client in
            let result = try await client.callTool("secure_tool_call", options: interopRequestOptions)
            #expect(result.value.isError == false)
            #expect(result.value.content == [.text("Elicitation via URL successful")])
        }
    }

    @Test(arguments: [ProtocolVersion.v2025_03_26, .v2025_06_18, .v2025_11_25, .v2026_07_28])
    func completion(_ version: ProtocolVersion) async throws {
        try await withExample("servers_completion_stdio", version: version) { client in
            let operation = try await client.complete(
                .prompt(name: "sql_query"), argument: "operation", value: "sel", options: interopRequestOptions
            )
            #expect(operation.value.values == ["SELECT"])
            #expect(operation.value.total == nil)
            #expect(operation.value.hasMore == false)

            if version.rawValue != ProtocolVersion.v2025_03_26.rawValue {
                let withoutContext = try await client.complete(
                    .prompt(name: "sql_query"), argument: "columns", value: "", options: interopRequestOptions
                )
                #expect(withoutContext.value.values == ["Choose operation first"])

                let columns = try await client.complete(
                    .prompt(name: "sql_query"), argument: "columns", value: "", context: ["operation": "SELECT"],
                    options: interopRequestOptions
                )
                #expect(columns.value.values == ["id", "name", "email", "created_at", "updated_at", "*"])
            }
        }
    }

    private func withExample(
        _ name: String,
        version: ProtocolVersion,
        handlers: ClientInputHandlers? = nil,
        body: (Client) async throws -> Void
    ) async throws {
        let executable = try rmcpFeatureExample(name, in: "LIMB_RMCP_EXAMPLES_DIR")
        let pin = version.rawValue == ProtocolVersion.v2026_07_28.rawValue ? nil : version
        try await withInteropStdioClient(executable, legacyVersion: pin, handlers: handlers) { client in
            try #require(client.protocolVersion.rawValue == version.rawValue)
            try await body(client)
        }
    }

    private struct CalculationOutput: JSONDecodable {
        let result: Double
        let operation: String
        let inputCount: Int

        init(json: JSONValue) throws(JSONDecodingError) {
            let object = try JSONObject(json: json)
            result = try object.required("result")
            operation = try object.required("operation")
            inputCount = try object.required("input_count")
        }
    }
}

// Keep these binaries unmodified so the stock stdout framing failure is checked
// independently of successful operations with the diagnostics-only fixtures.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["LIMB_RMCP_STOCK_EXAMPLES_DIR"] != nil,
        "Set LIMB_RMCP_STOCK_EXAMPLES_DIR to the absolute directory of the stock rmcp-v3.11.0 examples"
    ),
    .timeLimit(.minutes(1))
)
struct StdioClientRMCPStockBannerTests {
    @Test(arguments: ["servers_completion_stdio", "servers_elicitation_stdio"])
    func rejectsStockStdoutBanners(_ name: String) async throws {
        let executable = try rmcpFeatureExample(name, in: "LIMB_RMCP_STOCK_EXAMPLES_DIR")
        try validateInteropExecutable(executable)
        do {
            let client = try await Client.connect(
                stdio: .init(executable: executable.path),
                options: .init(timeout: .seconds(5), discoveryTimeout: .seconds(2))
            )
            await client.close()
            Issue.record("Expected discovery to reject the stdout banner from \(name)")
        } catch {
            #expect(error as? StdioNegotiationError == .malformedResponse)
        }
    }
}

@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["LIMB_MCP_LEGACY_STDIO"] != nil,
        "Set LIMB_MCP_LEGACY_STDIO to the absolute launcher path for server-everything 1.0.0 with SDK 1.32.2"
    ),
    .timeLimit(.minutes(1))
)
struct StdioClientMCPReferenceFallbackTests {
    @Test func automaticallyFallsBackToLegacyReferenceServer() async throws {
        let executable = try interopFixturePath("LIMB_MCP_LEGACY_STDIO")
        try await withInteropStdioClient(executable, legacyVersion: nil) { client in
            try #require(client.protocolVersion.rawValue == ProtocolVersion.v2025_11_25.rawValue)
            #expect(client.serverInfo?.name == "mcp-servers/everything")
            #expect(client.serverInfo?.version == "1.0.0")

            let catalog = try await client.listTools(options: interopRequestOptions)
            try #require(catalog.value.items.contains { $0.name == "echo" })

            let message = "fallback: \"echo\"\nnext line"
            let result = try await client.callTool(
                "echo", arguments: ["message": .string(message)], options: interopRequestOptions
            )
            #expect(result.value.isError == false)
            #expect(result.value.content == [.text("Echo: \(message)")])
        }
    }
}

private let interopRequestOptions = ClientRequestOptions(timeout: .seconds(5))

private func interopFixturePath(_ variable: String) throws -> URL {
    let path = try #require(ProcessInfo.processInfo.environment[variable])
    try #require(path.hasPrefix("/"), "\(variable) must be an absolute path")
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
}

private func rmcpFeatureExample(_ name: String, in variable: String) throws -> URL {
    let directory = try interopFixturePath(variable)
    let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey])
    try #require(attributes.isDirectory == true, "\(variable) must point to a directory")
    return directory.appendingPathComponent(name)
}

private func validateInteropExecutable(_ executable: URL) throws {
    let attributes = try executable.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
    try #require(
        attributes.isRegularFile == true && FileManager.default.isExecutableFile(atPath: executable.path),
        "\(executable.path) must point to an executable file"
    )
}

private func withInteropStdioClient(
    _ executable: URL,
    legacyVersion: ProtocolVersion?,
    handlers: ClientInputHandlers? = nil,
    body: (Client) async throws -> Void
) async throws {
    try validateInteropExecutable(executable)
    let client = try await Client.connect(
        stdio: .init(executable: executable.path),
        options: .init(
            timeout: .seconds(5), discoveryTimeout: .seconds(2), inputHandlers: handlers, legacyVersion: legacyVersion
        )
    )
    do {
        try await body(client)
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}
#endif
