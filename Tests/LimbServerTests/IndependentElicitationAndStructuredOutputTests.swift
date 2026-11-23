import Limb
import LimbTesting
import Testing

@Suite(.timeLimit(.minutes(2)))
struct IndependentElicitationAndStructuredOutputTests {
    private static let capabilityCases: [(JSONObject, Bool, Bool)] = [
        ([:], false, false),
        (["elicitation": true], false, false),
        (["elicitation": [:]], true, false),
        (["elicitation": ["other": [:]]], false, false),
        (["elicitation": ["form": [:]]], true, false),
        (["elicitation": ["url": [:]]], false, true),
        (["elicitation": ["form": [:], "url": [:]]], true, true),
        (["elicitation": ["form": true, "url": [:]]], false, true),
        (["elicitation": ["form": [:], "url": "yes"]], true, false),
    ]

    @Test(arguments: capabilityCases)
    func elicitationCapabilitiesDistinguishModes(raw: JSONObject, form: Bool, url: Bool) {
        let capabilities = ClientCapabilities(raw: raw)
        #expect(capabilities.supportsElicitation == form)
        #expect(capabilities.supportsURLElicitation == url)
    }

    @Test(arguments: capabilityCases)
    func modernWireRequestsOnlyAdvertisedElicitationModes(raw: JSONObject, form: Bool, url: Bool) async throws {
        let server = try Self.formServer(api: .typed, schema: R2P.formSchema)
        try server.register(tool: ToolDefinition(name: "connect")) { _, context in
            _ = try await context.elicit("connect", message: "Connect your account?", url: "https://example.com/connect")
            return .text("connection requested")
        }
        let client = TestClient(server, capabilities: raw)
        for (name, supported) in [("preferences", form), ("connect", url)] {
            let reply = try await client.request("tools/call", ["name": .string(name)])
            if supported {
                #expect(reply["result"]?["resultType"] == "input_required")
                #expect(reply["result"]?["inputRequests"]?[name]?["method"] == "elicitation/create")
            } else {
                #expect(reply["error"] != nil || reply.r2pIsToolError, "\(reply)")
                #expect(reply["result"]?["resultType"] != "input_required")
                #expect(reply["result"]?["inputRequests"] == nil)
            }
        }
    }

    private static let validSchemas: [JSONValue] = [
        [
            "type": "object",
            "properties": ["name": ["type": "string", "default": "Ada"], "confirmed": ["type": "boolean", "default": false]],
        ],
        ["type": "object", "properties": ["color": ["type": "string", "enum": ["blue", "green"]]]],
        titledEnumSchema,
    ]

    private static let titledEnumSchema: JSONValue = [
        "type": "object",
        "properties": [
            "color": [
                "type": "string",
                "oneOf": [["const": "blue", "title": "Ocean Blue"], ["const": "green", "title": "Forest Green"]],
            ],
        ],
    ]

    private static let invalidSchemas: [JSONValue] = [
        ["type": "string"],
        ["type": "object", "properties": ["name": ["type": "string", "default": 42]]],
        [
            "type": "object",
            "properties": [
                "colors": ["type": "array", "items": ["type": "string", "enum": ["blue", "green"]], "default": ["blue", 42]],
            ],
        ],
        ["type": "object", "properties": ["profile": ["type": "object", "properties": ["name": ["type": "string"]]]]],
        [
            "type": "object",
            "properties": ["name": ["type": "string"]],
            "allOf": [["properties": ["profile": ["type": "object", "properties": ["city": ["type": "string"]]]]]],
        ],
        [
            "type": "object",
            "properties": [
                "name": ["type": "string", "not": ["type": "object", "properties": ["city": ["type": "string"]]]],
            ],
        ],
    ]

    private enum InputAPI: String, CaseIterable {
        case typed, grouped
    }

    private static func formServer(api: InputAPI, schema: JSONObject) throws -> Server {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "preferences")) { _, context in
            switch api {
            case .typed:
                _ = try await context.elicit("preferences", message: "Your preferences?", schema: schema)
            case .grouped:
                _ = try await context.input([
                    "preferences": .elicit(ElicitRequest(message: "Your preferences?", requestedSchema: schema)),
                ])
            }
            return .text("preferences received")
        }
        return server
    }

    @Test(arguments: InputAPI.allCases, validSchemas)
    private func modernFormPreservesSupportedSchema(api: InputAPI, schema: JSONValue) async throws {
        let server = try Self.formServer(api: api, schema: #require(schema.objectValue))
        let client = TestClient(server, capabilities: ["elicitation": ["form": [:]]])
        let reply = try await client.request("tools/call", ["name": "preferences"])
        let result = try #require(reply["result"])
        #expect(result["resultType"] == "input_required")
        let input = try #require(result["inputRequests"]?["preferences"])
        #expect(input["method"] == "elicitation/create")
        #expect(input["params"]?["requestedSchema"] == schema)
        let state = try #require(result["requestState"])
        let completed = try await client.request("tools/call", [
            "name": "preferences",
            "requestState": state,
            "inputResponses": ["preferences": ["action": "decline"]],
        ])
        #expect(completed["result"]?["resultType"] == "complete")
        #expect(completed.r2pText == "preferences received")
    }

    @Test(arguments: InputAPI.allCases)
    private func november2025FormPreservesTitledEnum(api: InputAPI) async throws {
        let server = try Self.formServer(api: api, schema: #require(Self.titledEnumSchema.objectValue))
        let client = try await R2P.client(server, .r2025_11_25, capabilities: ["elicitation": ["form": [:]]])
        let call = client.post("tools/call", ["name": "preferences"])
        let request = try await R2P.expectMessage(client, "elicitation/create")
        #expect(request["params"]?["requestedSchema"] == Self.titledEnumSchema)
        R2P.answer(client, request, ["action": "accept", "content": ["color": "green"]])
        #expect(try await client.response(to: call).r2pText == "preferences received")
    }

    @Test(arguments: InputAPI.allCases, invalidSchemas)
    private func invalidModernFormFailsWithoutRequestingInput(api: InputAPI, schema: JSONValue) async throws {
        let server = try Self.formServer(api: api, schema: #require(schema.objectValue))
        let client = TestClient(server, capabilities: ["elicitation": ["form": [:]]])
        let reply = try await client.request("tools/call", ["name": "preferences"])
        #expect(reply["error"] != nil || reply.r2pIsToolError, "\(reply)")
        #expect(reply["result"]?["resultType"] != "input_required")
        #expect(reply["result"]?["inputRequests"] == nil)
        #expect(client.received.isEmpty)
    }

    private static let acceptedFormResponses: [(JSONValue, Bool)] = [
        (["action": "accept", "content": [:]], true),
        (["action": "accept", "content": ["extra": "flat"]], true),
        (["action": "accept"], false),
        (["action": "accept", "content": .null], false),
        (["action": "accept", "content": ["extra": ["city": "Paris"]]], false),
    ]

    @Test(arguments: acceptedFormResponses)
    func modernFormAcceptRequiresAnObjectWithFlatValues(response: JSONValue, accepted: Bool) async throws {
        let server = try Self.formServer(api: .typed, schema: [
            "type": "object",
            "properties": ["name": ["type": "string"]],
        ])
        let client = TestClient(server, capabilities: ["elicitation": ["form": [:]]])
        let initial = try await client.request("tools/call", ["name": "preferences"])
        #expect(initial["result"]?["resultType"] == "input_required")
        let state = try #require(initial["result"]?["requestState"])
        let reply = try await client.request("tools/call", [
            "name": "preferences",
            "requestState": state,
            "inputResponses": ["preferences": response],
        ])
        if accepted {
            #expect(reply["result"]?["resultType"] == "complete")
            #expect(reply.r2pText == "preferences received")
        } else {
            #expect(reply["error"] != nil || reply.r2pIsToolError, "\(reply)")
            #expect(reply["result"]?["inputRequests"] == nil)
        }
    }

    @Test(arguments: ["https:///connect", "https://example.com/%zz"])
    func invalidModernURLFailsWithoutRequestingInput(url: String) async throws {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "connect")) { _, context in
            _ = try await context.elicit("connect", message: "Connect your account?", url: url)
            return .text("connection requested")
        }
        let client = TestClient(server, capabilities: ["elicitation": ["url": [:]]])
        let reply = try await client.request("tools/call", ["name": "connect"])
        #expect(reply["error"] != nil || reply.r2pIsToolError, "\(reply)")
        #expect(reply["result"]?["resultType"] != "input_required")
        #expect(reply["result"]?["inputRequests"] == nil)
        #expect(client.received.isEmpty)
    }

    @Test(arguments: IndependentProtocolRevision.allCases)
    func toolContentMirrorsStructuredOutputExactlyOnce(revision: IndependentProtocolRevision) async throws {
        let server = R2P.server()
        let structured: JSONValue = ["color": "blue", "count": 2]
        let prose = "Found two blue items."
        let existingJSON = #" { "count" : 2, "color" : "blue" } "#
        try server.register(tool: ToolDefinition(name: "explain")) { _, _ in
            ToolResult(content: [.text(prose)], structuredContent: structured)
        }
        try server.register(tool: ToolDefinition(name: "already_serialized")) { _, _ in
            ToolResult(content: [.text(prose), .text(existingJSON)], structuredContent: structured)
        }
        try server.register(tool: ToolDefinition(name: "plain")) { _, _ in .text(prose) }

        let client = try await R2P.client(server, revision)
        let explained = try #require(try await client.request("tools/call", ["name": "explain"])["result"])
        if revision.isAtLeast(.r2025_06_18) {
            #expect(explained["structuredContent"] == structured)
        } else {
            #expect(explained["structuredContent"] == nil)
        }
        let blocks = try #require(explained["content"]?.arrayValue)
        #expect(blocks.count == 2)
        #expect(blocks.first?["text"] == .string(prose))
        let fallback = try #require(blocks.last?["text"]?.stringValue)
        #expect(blocks.last?["type"] == "text")
        #expect(try JSON.parse(Array(fallback.utf8)) == structured)

        let serialized = try #require(try await client.request("tools/call", ["name": "already_serialized"])["result"])
        if revision.isAtLeast(.r2025_06_18) {
            #expect(serialized["structuredContent"] == structured)
        } else {
            #expect(serialized["structuredContent"] == nil)
        }
        #expect(serialized["content"] == [
            ["type": "text", "text": .string(prose)],
            ["type": "text", "text": .string(existingJSON)],
        ])

        let plain = try #require(try await client.request("tools/call", ["name": "plain"])["result"])
        #expect(plain["structuredContent"] == nil)
        #expect(plain["content"] == [["type": "text", "text": .string(prose)]])
    }
}
