import Foundation
import Limb
import LimbTesting
import Testing

/// S10: tool-enabled sampling. `client/sampling.mdx` (2025-11-25:40, 2026-07-28:52): "Servers
/// MUST NOT send tool-enabled sampling requests to Clients that have not declared support for
/// tool use via the `sampling.tools` capability." `tools` / `toolChoice` do not exist before
/// 2025-11-25 (`CreateMessageRequestParams`, schema.ts:1615).
@Suite(.timeLimit(.minutes(2)))
struct Round2ProtocolSamplingToolsTests {
    enum Variant: String, CaseIterable, Sendable {
        case plain, tools, toolChoiceOnly, emptyTools, both

        var params: JSONObject {
            var params: JSONObject = [
                "messages": [["role": "user", "content": ["type": "text", "text": "What is the weather?"]]],
                "maxTokens": 50,
            ]
            let tool: JSONValue = ["name": "get_weather", "inputSchema": ["type": "object", "properties": ["city": ["type": "string"]]]]
            switch self {
            case .plain: break
            case .tools: params["tools"] = [tool]
            case .toolChoiceOnly: params["toolChoice"] = ["mode": "auto"]
            case .emptyTools: params["tools"] = []
            case .both:
                params["tools"] = [tool]
                params["toolChoice"] = ["mode": "required"]
            }
            return params
        }

        var usesTools: Bool { self != .plain }
    }

    enum Capability: String, CaseIterable, Sendable {
        case none, sampling, samplingTools, toolsNotAnObject

        var object: JSONObject {
            switch self {
            case .none: [:]
            case .sampling: ["sampling": [:]]
            case .samplingTools: ["sampling": ["tools": [:]]]
            case .toolsNotAnObject: ["sampling": ["tools": true]]
            }
        }
    }

    private static func server() throws -> Server {
        let server = R2P.server()
        try server.register(tool: ToolDefinition(name: "sample", inputSchema: ["type": "object"])) { arguments, context in
            let variant = Variant(rawValue: arguments["variant"]?.stringValue ?? "") ?? .plain
            do {
                let result = try await context.sample("k", SamplingRequest(params: variant.params))
                return .text("sampled:\(result.text ?? "")")
            } catch let unavailable as InputUnavailable {
                return .text("unavailable:\(unavailable.capability)")
            }
        }
        return server
    }

    /// Whether the request may reach the client: sampling declared, and for tools also
    /// `sampling.tools` (an object) in a revision that has it.
    private static func allowed(_ revision: IndependentProtocolRevision, _ capability: Capability, _ variant: Variant) -> Bool {
        guard capability != .none else { return false }
        guard variant.usesTools else { return true }
        return revision.isAtLeast(.r2025_11_25) && capability == .samplingTools
    }

    @Test(arguments: IndependentProtocolRevision.legacy, Capability.allCases)
    func legacyMatrix(revision: IndependentProtocolRevision, capability: Capability) async throws {
        let client = try await R2P.client(try Self.server(), revision, capabilities: capability.object)
        for variant in Variant.allCases {
            let call = client.post("tools/call", ["name": "sample", "arguments": ["variant": .string(variant.rawValue)]])
            if Self.allowed(revision, capability, variant) {
                let request = try await R2P.expectMessage(client, "sampling/createMessage")
                // Passed through exactly as the handler wrote it.
                #expect(request["params"] == .object(variant.params), "\(variant)")
                R2P.answer(client, request, R2P.samplingReply)
                #expect(try await client.response(to: call).r2pText == "sampled:ok", "\(revision) \(capability) \(variant)")
            } else {
                let response = try await client.response(to: call)
                let expected = capability == .none ? "unavailable:sampling" : "unavailable:sampling with tools"
                #expect(response.r2pText == expected, "\(revision) \(capability) \(variant): \(response)")
                #expect(client.received.isEmpty, "\(revision) \(capability) \(variant): nothing may be sent")
            }
            client.clearReceived()
        }
    }

    @Test(arguments: Capability.allCases)
    func modernMatrix(capability: Capability) async throws {
        let server = try Self.server()
        for variant in Variant.allCases {
            let client = TestClient(server, capabilities: capability.object)
            let response = try await client.request("tools/call", ["name": "sample", "arguments": ["variant": .string(variant.rawValue)]])
            if Self.allowed(.r2026_07_28, capability, variant) {
                #expect(response["result"]?["resultType"] == "input_required", "\(capability) \(variant): \(response)")
                #expect(response["result"]?["inputRequests"]?["k"]?["method"] == "sampling/createMessage")
                #expect(response["result"]?["inputRequests"]?["k"]?["params"] == .object(variant.params))
            } else {
                // basic/index.mdx:391: -32021 whose data.requiredCapabilities lists what is missing.
                #expect(response.r2pCode == -32021, "\(capability) \(variant): \(response)")
                let required: JSONValue = capability == .none ? ["sampling": [:]] : ["sampling": ["tools": [:]]]
                #expect(response["error"]?["data"] == ["requiredCapabilities": required], "\(capability) \(variant): \(response)")
                #expect(
                    IndependentProtocolRevision.r2026_07_28.schema.violations(in: response, as: "MissingRequiredClientCapabilityError") == [],
                    "\(response)")
                #expect(response["result"] == nil)
            }
            #expect(client.received.isEmpty)
        }
    }

    /// The modern answer round trip with tools still works for a client that declared them.
    @Test func modernToolSamplingRoundTrip() async throws {
        let client = TestClient(try Self.server(), capabilities: Capability.samplingTools.object)
        let first = try #require(try await client.request("tools/call", ["name": "sample", "arguments": ["variant": "both"]])["result"])
        let reply: JSONValue = [
            "role": "assistant", "content": [["type": "text", "text": "sunny"]], "model": "m", "stopReason": "endTurn",
        ]
        let second = try await client.request(
            "tools/call",
            ["name": "sample", "arguments": ["variant": "both"], "requestState": first["requestState"]!, "inputResponses": ["k": reply]])
        #expect(second.r2pText == "sampled:sunny")
    }
}
