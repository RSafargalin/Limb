import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

@Suite struct IndependentMRTRContinuationContractTests {
    struct Arguments: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let initial: String
        let retry: String
    }

    // Send the source JSON directly so the client cannot reorder or normalize member names.
    static let argumentCases = [
        Arguments(testDescription: "unchanged", initial: #"{"one":"fern","two":"moss"}"#, retry: #"{"one":"fern","two":"moss"}"#),
        Arguments(testDescription: "ASCII order", initial: #"{"one":"fern","two":"moss"}"#, retry: #"{"two":"moss","one":"fern"}"#),
        Arguments(
            testDescription: "Unicode keys unchanged",
            initial: #"{"\u00e9":"fern","e\u0301":"moss"}"#,
            retry: #"{"\u00e9":"fern","e\u0301":"moss"}"#),
        Arguments(
            testDescription: "Unicode key order",
            initial: #"{"\u00e9":"fern","e\u0301":"moss"}"#,
            retry: #"{"e\u0301":"moss","\u00e9":"fern"}"#),
        Arguments(
            testDescription: "nested object order with stable array order",
            initial: #"{"plants":[{"\u00e9":"fern","e\u0301":"moss"},{"first":true,"second":null}]}"#,
            retry: #"{"plants":[{"e\u0301":"moss","\u00e9":"fern"},{"second":null,"first":true}]}"#),
        Arguments(testDescription: "equivalent numbers", initial: #"{"count":1e2}"#, retry: #"{"count":100}"#),
    ]

    private static let capabilities: JSONObject = ["elicitation": ["form": [:]]]
    private static let form: JSONObject = ["type": "object", "properties": ["plant": ["type": "string"]]]

    @Test(arguments: argumentCases)
    func equivalentArgumentsResumeTheSameElicitation(_ arguments: Arguments) async throws {
        let server = Server(name: "plant-label", version: "1")
        try server.register(
            tool: ToolDefinition(name: "label", annotations: ToolAnnotations(readOnlyHint: true))
        ) { _, context in
            let answer = try await context.elicit("label", message: "Choose a plant", schema: Self.form)
            return .text(answer.content?["plant"]?.stringValue ?? "")
        }
        let client = TestClient(server, modern: true, capabilities: Self.capabilities)
        do {
            let metadata =
                #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}}}}"#
            func call(id: Int, arguments: String, continuation: String = "") async throws -> JSONValue {
                client.send(
                    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"label","arguments":\#(arguments),\#(metadata)\#(continuation)}}"#
                )
                return try await client.response(to: RequestID(id))
            }

            let first = try await call(id: 100, arguments: arguments.initial)
            let state = try Self.requireElicitation(from: first)
            let echoedState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            let retry = try await call(
                id: 101, arguments: arguments.retry,
                continuation: #","requestState":\#(echoedState),"inputResponses":{"label":{"action":"accept","content":{"plant":"fern"}}}"#)
            #expect(retry["error"] == nil)
            #expect(retry["result"]?["resultType"] == "complete")
            #expect(retry.firstText == "fern")
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    enum RetryFields: Sendable, CaseIterable {
        case stateAndResponses
        case responsesOnly
        case emptyResponsesOnly
        case stateOnly
    }

    @Test(arguments: RetryFields.allCases)
    func resourceReadWithContinuationFieldsUsesPrivateZeroTTL(_ fields: RetryFields) async throws {
        let server = Server(name: "plant-resource", version: "1")
        let policy = CachePolicy(ttlMilliseconds: 3210, scope: .public)
        let plainURI = "plant://plain"
        let interactiveURI = "plant://interactive"
        let requiresElicitation = Mutex(true)
        try server.register(resource: ResourceDefinition(uri: plainURI, name: "plain"), cache: policy) { request, _ in
            [.text(uri: request.uri, text: "catalog")]
        }
        try server.register(
            resource: ResourceDefinition(uri: interactiveURI, name: "interactive"), cache: policy
        ) { request, context in
            if requiresElicitation.withLock({ $0 }) {
                let answer = try await context.elicit("label", message: "Choose a plant", schema: Self.form)
                return [.text(uri: request.uri, text: answer.content?["plant"]?.stringValue ?? "")]
            }
            return [.text(uri: request.uri, text: "catalog")]
        }

        let client = TestClient(server, modern: true, capabilities: Self.capabilities)
        do {
            let fresh = try await client.request("resources/read", ["uri": .string(plainURI)])
            Self.expectRead(fresh, text: "catalog", ttl: 3210, scope: "public")

            var params: JSONObject = ["uri": .string(interactiveURI)]
            var expected = "fern"
            if fields == .emptyResponsesOnly {
                params = ["uri": .string(plainURI), "inputResponses": [:]]
                expected = "catalog"
            } else {
                let initial = try await client.request("resources/read", params)
                let state = try Self.requireElicitation(from: initial)
                #expect(initial.result?["ttlMs"] == nil)
                #expect(initial.result?["cacheScope"] == nil)
                if fields != .responsesOnly {
                    params["requestState"] = .string(state)
                }
                if fields != .stateOnly {
                    params["inputResponses"] = ["label": elicited(["plant": "fern"])]
                } else {
                    // The resource no longer needs the answer, so the issued state alone can complete.
                    requiresElicitation.withLock { $0 = false }
                    expected = "catalog"
                }
            }

            let retry = try await client.request("resources/read", params)
            Self.expectRead(retry, text: expected, ttl: 0, scope: "private")
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    private static func requireElicitation(from response: JSONValue) throws -> String {
        let result = try #require(response.result, "Expected elicitation, got \(response)")
        try #require(result["resultType"] == "input_required")
        try #require(result["inputRequests"]?["label"]?["method"] == "elicitation/create")
        return try #require(result["requestState"]?.stringValue)
    }

    private static func expectRead(_ response: JSONValue, text: String, ttl: Int, scope: String) {
        #expect(response["error"] == nil)
        #expect(response.result?["resultType"] == "complete")
        #expect(response.result?["contents"]?[0]?["text"]?.stringValue == text)
        #expect(response.result?["ttlMs"]?.intValue == ttl)
        #expect(response.result?["cacheScope"]?.stringValue == scope)
    }
}
