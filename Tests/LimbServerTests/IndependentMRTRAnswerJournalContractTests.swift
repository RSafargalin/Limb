import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

@Suite struct IndependentMRTRAnswerJournalContractTests {
    private static let capabilities: JSONObject = ["elicitation": ["form": [:]]]
    private static let form: JSONObject = [
        "type": "object",
        "properties": ["name": ["type": "string"], "color": ["type": "string"]],
        "required": ["name", "color"],
    ]

    static let finalResponseOrders = [
        #"{"pot":{"action":"accept","content":{"name":"clay","color":"red"}}}"#,
        #"{"pot":{"content":{"color":"red","name":"clay"},"action":"accept"}}"#,
    ]

    @Test(arguments: finalResponseOrders)
    func thirdRequestCompletesWithEarlierAcceptedAnswer(_ finalResponses: String) async throws {
        let entries = Mutex(0)
        try await Self.withClient(onEntry: { entries.withLock { $0 += 1 } }) { client in
            let state = try await Self.reachPotQuestion(client)
            let third = try await Self.call(
                client, id: 102, tool: "label", state: state, inputResponses: finalResponses
            )

            #expect(third["error"] == nil)
            #expect(third.result?["resultType"] == "complete", "Unexpected third response: \(third)")
            #expect(third.firstText == "fern:green/clay:red")
            #expect(entries.withLock { $0 } == 3)
        }
    }

    @Test
    func acceptedAnswerRemainsAvailableAfterAnEntryThatDoesNotReadIt() async throws {
        let entries = Mutex(0)
        try await Self.withClient(
            shouldReadPlant: {
                entries.withLock { count in
                    count += 1
                    return count != 3
                }
            },
            asksForLocation: true
        ) { client in
            let potState = try await Self.reachPotQuestion(client)
            let third = try await Self.call(
                client, id: 102, tool: "label", state: potState, inputResponses: Self.finalResponseOrders[0]
            )
            let locationState = try Self.requireQuestion("location", in: third)
            let fourth = try await Self.call(
                client, id: 103, tool: "label", state: locationState,
                inputResponses: #"{"location":{"action":"accept","content":{"name":"shelf","color":"white"}}}"#
            )

            #expect(fourth.result?["resultType"] == "complete", "Unexpected fourth response: \(fourth)")
            #expect(fourth.firstText == "fern:green/clay:red/shelf:white")
            #expect(entries.withLock { $0 } == 4)
        }
    }

    @Test
    func redundantAnswerDoesNotReplaceAnAcceptedAnswer() async throws {
        try await Self.withClient { client in
            let state = try await Self.reachPotQuestion(client)
            // Limb keeps an already accepted answer when a client includes it alongside the current reply.
            let third = try await Self.call(
                client, id: 102, tool: "label", state: state,
                inputResponses: #"{"plant":{"action":"accept","content":{"name":"moss","color":"green"}},"pot":{"action":"accept","content":{"name":"clay","color":"red"}}}"#
            )

            #expect(third.result?["resultType"] == "complete", "Unexpected third response: \(third)")
            #expect(third.firstText == "fern:green/clay:red")
        }
    }

    @Test
    func freshOperationsStillAskForTheirOwnAnswer() async throws {
        try await Self.withClient { client in
            _ = try await Self.reachPotQuestion(client)

            let fresh = try await Self.call(client, id: 102, tool: "label")
            _ = try Self.requireQuestion("plant", in: fresh)

            let other = try await Self.call(client, id: 103, tool: "another-label")
            _ = try Self.requireQuestion("plant", in: other)
        }
    }

    @Test
    func sameAuthenticatedPrincipalCanContinueOnAnotherConnection() async throws {
        let server = Server(name: "plant-label", version: "1")
        try server.register(
            tool: ToolDefinition(name: "label", annotations: ToolAnnotations(readOnlyHint: true))
        ) { _, context in
            let plant = try await context.elicit("plant", message: "Choose a plant", schema: Self.form)
            return .text(plant.content?["name"]?.stringValue ?? "")
        }

        func request(id: Int, clientName: String, continuation: JSONObject = [:]) async throws -> JSONValue {
            let sink = IndependentConcurrencySink()
            let connection = server.connect(to: sink, authenticatedPrincipal: "plant-club-member")
            var params = continuation
            params["name"] = "label"
            params["arguments"] = [:]
            params["_meta"] = [
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": .object(Self.capabilities),
                "io.modelcontextprotocol/clientInfo": ["name": .string(clientName), "version": "1"],
            ]
            let frame: JSONValue = [
                "jsonrpc": "2.0", "id": RequestID(id).json, "method": "tools/call", "params": .object(params),
            ]
            connection.receive(frame.encoded())
            let reply = await sink.next(timeout: .seconds(10))
            await connection.close(graceSeconds: 0)
            let response = try #require(reply?.json, "Expected JSON-RPC response for request \(id)")
            #expect(response["id"] == RequestID(id).json)
            return response
        }

        let first = try await request(id: 100, clientName: "plant-desk")
        let state = try Self.requireQuestion("plant", in: first)
        let second = try await request(
            id: 101, clientName: "plant-tablet",
            continuation: [
                "requestState": .string(state),
                "inputResponses": ["plant": elicited(["name": "fern", "color": "green"])],
            ]
        )

        #expect(second.result?["resultType"] == "complete")
        #expect(second.firstText == "fern")
    }

    enum MissingResponses: Sendable, CaseIterable {
        case absent
        case empty

        var wireValue: String? {
            switch self {
            case .absent: nil
            case .empty: "{}"
            }
        }
    }

    @Test(arguments: MissingResponses.allCases)
    func absentAndEmptyResponsesAskForTheMissingAnswer(_ missing: MissingResponses) async throws {
        try await Self.withClient { client in
            let state = try await Self.reachPotQuestion(client)
            let retry = try await Self.call(
                client, id: 102, tool: "label", state: state, inputResponses: missing.wireValue
            )
            _ = try Self.requireQuestion("pot", in: retry)
        }
    }

    @Test
    func nullResponsesAreInvalid() async throws {
        try await Self.withClient { client in
            let first = try await Self.call(client, id: 100, tool: "label")
            let state = try Self.requireQuestion("plant", in: first)
            let retry = try await Self.call(
                client, id: 101, tool: "label", state: state, inputResponses: "null"
            )
            #expect(retry["error"] != nil, "Expected a protocol error for null inputResponses: \(retry)")
        }
    }

    @Test
    func nullStateIsInvalidWhileOmittedStateStartsAnOperation() async throws {
        try await Self.withClient { client in
            let first = try await Self.call(client, id: 100, tool: "label")
            _ = try Self.requireQuestion("plant", in: first)

            let malformed = try await Self.call(client, id: 101, tool: "label", nullState: true)
            #expect(malformed["error"] != nil, "Expected a protocol error for null requestState: \(malformed)")
        }
    }

    private static func withClient(
        onEntry: @escaping @Sendable () -> Void = {},
        shouldReadPlant: @escaping @Sendable () -> Bool = { true },
        asksForLocation: Bool = false,
        _ run: (TestClient) async throws -> Void
    ) async throws {
        let server = Server(name: "plant-label", version: "1")
        for name in ["label", "another-label"] {
            try server.register(
                tool: ToolDefinition(name: name, annotations: ToolAnnotations(readOnlyHint: true))
            ) { _, context in
                onEntry()
                let plant: ElicitResult?
                if shouldReadPlant() {
                    plant = try await context.elicit("plant", message: "Choose a plant", schema: Self.form)
                } else {
                    plant = nil
                }
                let pot = try await context.elicit("pot", message: "Choose a pot", schema: Self.form)
                let plantName = plant?.content?["name"]?.stringValue ?? ""
                let plantColor = plant?.content?["color"]?.stringValue ?? ""
                let potName = pot.content?["name"]?.stringValue ?? ""
                let potColor = pot.content?["color"]?.stringValue ?? ""
                let label = "\(plantName):\(plantColor)/\(potName):\(potColor)"
                if asksForLocation {
                    let location = try await context.elicit("location", message: "Choose a location", schema: Self.form)
                    let locationName = location.content?["name"]?.stringValue ?? ""
                    let locationColor = location.content?["color"]?.stringValue ?? ""
                    return .text("\(label)/\(locationName):\(locationColor)")
                }
                return .text(label)
            }
        }

        let client = TestClient(server, modern: true, capabilities: capabilities)
        do {
            try await run(client)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    private static func reachPotQuestion(_ client: TestClient) async throws -> String {
        let first = try await Self.call(client, id: 100, tool: "label")
        let plantState = try Self.requireQuestion("plant", in: first)
        let second = try await Self.call(
            client, id: 101, tool: "label", state: plantState,
            inputResponses: #"{"plant":{"action":"accept","content":{"name":"fern","color":"green"}}}"#
        )
        return try Self.requireQuestion("pot", in: second)
    }

    private static func requireQuestion(_ key: String, in response: JSONValue) throws -> String {
        let result = try #require(response.result, "Expected input_required for \(key), got \(response)")
        try #require(result["resultType"] == "input_required", "Expected input_required for \(key), got \(result)")
        let requests = try #require(result["inputRequests"]?.objectValue)
        try #require(requests.count == 1)
        try #require(requests[key]?["method"] == "elicitation/create", "Expected request for \(key), got \(requests)")
        return try #require(result["requestState"]?.stringValue)
    }

    private static func call(
        _ client: TestClient,
        id: Int,
        tool: String,
        state: String? = nil,
        nullState: Bool = false,
        inputResponses: String? = nil
    ) async throws -> JSONValue {
        let metadata = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}}}}"#
        var continuation = ""
        if let state {
            let echoedState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            continuation += #","requestState":\#(echoedState)"#
        } else if nullState {
            continuation += #","requestState":null"#
        }
        if let inputResponses {
            continuation += #","inputResponses":\#(inputResponses)"#
        }
        // Send source JSON so encoding cannot normalize object member order or omit explicit null.
        client.send(
            #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{},\#(metadata)\#(continuation)}}"#
        )
        return try await client.response(to: RequestID(id))
    }
}
