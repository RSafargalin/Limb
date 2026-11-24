import Limb
import Testing

@Suite
struct IndependentConfigurationAndFilterContractTests {
    private static let listen = "subscriptions/listen"
    private static let acknowledgment = "notifications/subscriptions/acknowledged"
    private static let resource = "test://subscription-filter"
    private static let listChangeKeys = ["toolsListChanged", "promptsListChanged", "resourcesListChanged"]
    private static let invalidBooleans: [JSONValue] = [1, "true", .null, []]
    private static let invalidURILists: [JSONValue] = [.null, "test://subscription-filter", [1], ["test://subscription-filter", .null]]

    @Test(arguments: listChangeKeys, invalidBooleans)
    func listChangeFieldsRequireBooleans(_ key: String, _ value: JSONValue) async throws {
        try await assertRejectedFilter([key: value, "resourceSubscriptions": [.string(Self.resource)]])
    }

    @Test(arguments: invalidURILists)
    func resourceSubscriptionFieldRequiresAnArrayOfStrings(_ value: JSONValue) async throws {
        try await assertRejectedFilter(["resourceSubscriptions": value, "toolsListChanged": true])
    }

    private func assertRejectedFilter(_ filter: JSONObject) async throws {
        let server = independentConcurrencyServer { $0.budgets.maxSubscriptions = 1 }
        let wire = IndependentConcurrencyWire(server)
        let invalidID = wire.post(Self.listen, ["notifications": .object(filter)])
        let response = try await wire.next(timeout: .seconds(2))
        #expect(response["id"] == invalidID.json)
        #expect(response["method"] == nil)
        #expect(response.independentConcurrencyErrorCode == -32602)
        #expect(response["result"] == nil)

        server.notifyResourceUpdated(uri: Self.resource)
        try server.register(tool: ToolDefinition(name: "changed")) { _, _ in .text("changed") }

        let validID = wire.post(Self.listen, ["notifications": ["resourceSubscriptions": [.string(Self.resource)]]])
        let acknowledgment = try await wire.next(timeout: .seconds(2))
        #expect(acknowledgment["method"] == .string(Self.acknowledgment))
        #expect(acknowledgment["params"]?["_meta"]?[MetaKey.subscriptionID] == validID.json)
        server.notifyResourceUpdated(uri: Self.resource)
        let event = try await wire.next(timeout: .seconds(2))
        #expect(event["method"] == "notifications/resources/updated")
        #expect(event["params"]?["_meta"]?[MetaKey.subscriptionID] == validID.json)
        #expect(!wire.sink.history.contains { $0.json?["params"]?["_meta"]?[MetaKey.subscriptionID] == invalidID.json })
        wire.cancel(validID)
    }

    @Test
    func emptyFiltersAndUnknownFieldsAllowAcknowledgment() async throws {
        let server = independentConcurrencyServer()
        let wire = IndependentConcurrencyWire(server)
        let filters: [JSONObject] = [
            [:],
            ["resourceSubscriptions": [], "toolsListChanged": false],
            ["resourceSubscriptions": [.string(Self.resource)], "futureFilter": ["enabled": true]],
        ]

        var ids: [RequestID] = []
        for filter in filters {
            let id = wire.post(Self.listen, ["notifications": .object(filter)])
            ids.append(id)
            let ack = try await wire.next(timeout: .seconds(2))
            #expect(ack["method"] == .string(Self.acknowledgment))
            #expect(ack["params"]?["_meta"]?[MetaKey.subscriptionID] == id.json)
            #expect(ack["params"]?["notifications"]?["futureFilter"] == nil)
        }

        try server.register(tool: ToolDefinition(name: "changed")) { _, _ in .text("changed") }
        server.notifyResourceUpdated(uri: Self.resource)
        let event = try await wire.next(timeout: .seconds(2))
        #expect(event["method"] == "notifications/resources/updated")
        #expect(event["params"]?["uri"] == .string(Self.resource))
        #expect(event["params"]?["_meta"]?[MetaKey.subscriptionID] == ids.last?.json)
        #expect(await wire.isSilent(for: .milliseconds(50)))
        for id in ids { wire.cancel(id) }
    }

    @Test(arguments: [-1, Int.min, 0, 8, Int.max])
    func serverExposesEffectiveIntegerLimits(_ limit: Int) {
        var configuration = ServerConfiguration(info: Implementation(name: "limit-contract", version: "1"))
        configuration.budgets.maxConcurrentHandlers = limit
        configuration.budgets.maxBatchItems = limit
        configuration.budgets.maxFrameBytes = limit
        configuration.budgets.maxInputResponses = limit
        configuration.budgets.maxOutboundBytes = limit
        configuration.budgets.maxQueuedBytes = limit
        configuration.budgets.maxQueuedRequests = limit
        configuration.budgets.maxRequestIDBytes = limit
        configuration.budgets.maxResponseBytes = limit
        configuration.budgets.maxSubscribedResourceBytes = limit
        configuration.budgets.maxSubscribedResources = limit
        configuration.budgets.maxSubscriptions = limit
        configuration.pageSize = limit
        configuration.maxRequestStateBytes = limit
        configuration.requestStateLifetimeSeconds = limit

        let effective = Server(configuration: configuration).configuration
        let nonnegative = max(0, limit)
        #expect(effective.budgets.maxConcurrentHandlers == max(1, limit))
        #expect(effective.budgets.maxBatchItems == nonnegative)
        #expect(effective.budgets.maxFrameBytes == nonnegative)
        #expect(effective.budgets.maxInputResponses == nonnegative)
        #expect(effective.budgets.maxOutboundBytes == nonnegative)
        #expect(effective.budgets.maxQueuedBytes == nonnegative)
        #expect(effective.budgets.maxQueuedRequests == nonnegative)
        #expect(effective.budgets.maxRequestIDBytes == nonnegative)
        #expect(effective.budgets.maxResponseBytes == nonnegative)
        #expect(effective.budgets.maxSubscribedResourceBytes == nonnegative)
        #expect(effective.budgets.maxSubscribedResources == nonnegative)
        #expect(effective.budgets.maxSubscriptions == nonnegative)
        #expect(effective.pageSize == max(1, limit))
        #expect(effective.maxRequestStateBytes == nonnegative)
        #expect(effective.requestStateLifetimeSeconds == nonnegative)
    }

    @Test
    func unconfiguredPageSizeStaysUnconfigured() {
        var configuration = ServerConfiguration(info: Implementation(name: "page-contract", version: "1"))
        configuration.pageSize = nil
        #expect(Server(configuration: configuration).configuration.pageSize == nil)
    }

    @Test
    func directReceiveEnforcesFrameLimitBeforeCallingHandler() async throws {
        // The two complete JSON frames are equivalent apart from the ID and trailing whitespace.
        func request(id: Int) -> String {
            #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        }
        let compact = request(id: 1)
        let padded = request(id: 2) + " "
        let limit = compact.utf8.count
        try #require(padded.utf8.count == limit + 1)
        let server = independentConcurrencyServer {
            $0.budgets.maxFrameBytes = limit
            $0.budgets.maxConcurrentHandlers = 1
        }
        let invocations = IndependentConcurrencyMeter()
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in
            invocations.enter()
            invocations.leave()
            return .text("called")
        }
        let wire = IndependentConcurrencyWire(server)
        wire.send(padded)
        wire.send(compact)
        let control = try await wire.response(to: RequestID(1), timeout: .seconds(2))
        #expect(control.independentConcurrencyText == "called")
        #expect(invocations.total == 1)
        #expect(!wire.sink.history.contains { $0.json?["id"] == 2 && $0.json?["result"] != nil })
    }
}
