#if os(macOS)
import Foundation
import Limb
import Synchronization
import Testing

private let everythingExecutable = ProcessInfo.processInfo.environment["LIMB_MCP_EVERYTHING_STDIO"]

@Suite(
    .enabled(
        if: everythingExecutable != nil,
        "Set LIMB_MCP_EVERYTHING_STDIO to the absolute launcher path for server-everything 2.3.1"
    ),
    .timeLimit(.minutes(1))
)
struct StdioClientEverythingInteropTests {
    private let requestOptions = ClientRequestOptions(timeout: .seconds(5))

    @Test func listsAndCallsEcho() async throws {
        try await withClient { client in
            let catalog = try await client.listTools(options: requestOptions)
            let echo = try #require(catalog.value.items.first { $0.name == "echo" })

            let message = "Привет, \"世界\" 👋\nSecond line"
            let result = try await client.callTool(
                echo, arguments: ["message": .string(message)], options: requestOptions
            )
            #expect(result.value.isError == false)
            #expect(result.value.content == [.text("Echo: \(message)")])
        }
    }

    @Test func routesListChangesToTheMatchingSubscription() async throws {
        try await withClient { client in
            // Iteration has no read deadline, so close the connection if a notification never arrives.
            let watchdog = Task {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                Issue.record("Timed out waiting for Everything list-change subscriptions")
                await client.close()
            }
            defer { watchdog.cancel() }

            let toolsFilter = ClientSubscriptionFilter(toolsListChanged: true)
            let promptsFilter = ClientSubscriptionFilter(promptsListChanged: true)
            let tools = try await client.subscribe(filter: toolsFilter, timeout: .seconds(5))
            let prompts = try await client.subscribe(filter: promptsFilter, timeout: .seconds(5))
            try #require(tools.confirmedFilter == toolsFilter)
            try #require(prompts.confirmedFilter == promptsFilter)
            var toolsEvents = tools.makeAsyncIterator()
            var promptsEvents = prompts.makeAsyncIterator()

            try await triggerListChange("tools", on: client)
            try #require(try await toolsEvents.next() == .toolsListChanged)
            try await triggerListChange("prompts", on: client)
            try #require(try await promptsEvents.next() == .promptsListChanged)

            await tools.cancel()
            try #require(try await toolsEvents.next() == nil)
            try await triggerListChange("tools", on: client)
            try await triggerListChange("prompts", on: client)
            try #require(try await promptsEvents.next() == .promptsListChanged)
            await prompts.cancel()
            try #require(try await promptsEvents.next() == nil)
        }
    }

    @Test func completesTwoRoundsOfFormElicitation() async throws {
        let observedKeys = Mutex<[String]>([])
        let handlers = ClientInputHandlers(elicitForm: { request, context in
            #expect(context.protocolVersion.rawValue == "2026-07-28")
            #expect(context.serverInfo?.name == "mcp-servers/everything")
            #expect(context.serverInfo?.version == "2.3.1")
            #expect(context.method == "elicitation/create")
            #expect(context.deadline > ContinuousClock.now)
            #expect(context.legacyRequestID == nil)
            observedKeys.withLock { $0.append(context.requestKey) }

            guard case let .form(schema) = request.mode else {
                Issue.record("Expected Everything to request form elicitation")
                return .init(action: .decline)
            }
            #expect(schema["type"] == "object")
            switch context.requestKey {
            case "name":
                #expect(context.round == 1)
                #expect(request.message == "What is your name?")
                #expect(schema["properties"]?["name"]?["type"] == "string")
                #expect(schema["properties"]?["name"]?["minLength"] == 1)
                #expect(schema["required"] == ["name"])
                return .init(action: .accept, content: ["name": "Ada"])
            case "color":
                #expect(context.round == 2)
                #expect(request.message == "Thanks, Ada. Which color do you like best?")
                #expect(schema["properties"]?["color"]?["enum"] == ["red", "green", "blue"])
                #expect(schema["required"] == ["color"])
                return .init(action: .accept, content: ["color": "blue"])
            default:
                Issue.record("Unexpected Everything elicitation key \(context.requestKey)")
                return .init(action: .decline)
            }
        })

        try await withClient(handlers: handlers) { client in
            let result = try await client.callTool("trigger-multi-step-elicitation", options: requestOptions)
            #expect(result.value.isError == false)
            #expect(result.value.content == [.text("Ada's favorite color is blue.")])
            #expect(result.raw["structuredContent"] == ["name": "Ada", "color": "blue"])
            #expect(observedKeys.withLock { $0 } == ["name", "color"])
        }
    }

    private func triggerListChange(_ list: String, on client: Client) async throws {
        let result = try await client.callTool(
            "trigger-list-changed", arguments: ["list": .string(list)], options: requestOptions
        )
        try #require(result.value.isError == false)
        #expect(result.value.content == [.text("Sent notifications/\(list)/list_changed")])
    }

    private func withClient(
        handlers: ClientInputHandlers? = nil,
        _ body: (Client) async throws -> Void
    ) async throws {
        let path = try #require(everythingExecutable)
        try #require(path.hasPrefix("/"), "LIMB_MCP_EVERYTHING_STDIO must be an absolute path")
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try executable.resourceValues(forKeys: [.isRegularFileKey])
        try #require(
            attributes.isRegularFile == true && FileManager.default.isExecutableFile(atPath: executable.path),
            "LIMB_MCP_EVERYTHING_STDIO must point to an executable file"
        )
        let client = try await Client.connect(
            stdio: .init(executable: executable.path),
            options: .init(timeout: .seconds(5), discoveryTimeout: .seconds(5), inputHandlers: handlers)
        )

        do {
            try #require(client.protocolVersion.rawValue == "2026-07-28")
            try #require(client.serverInfo?.name == "mcp-servers/everything")
            try #require(client.serverInfo?.version == "2.3.1")
            try await body(client)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }
}
#endif
