import Limb
import LimbTesting
import Testing

struct IndependentMalformedLegacyReplyContractTests {
    @Test
    func malformedRootsErrorFinishesOnlyTheAwaitingOperation() async throws {
        let timeout: Duration = .seconds(3)
        let peerErrorCode = 1234
        let server = Server(name: "Roots reply fixture", version: "1") {
            $0.clientRequestTimeoutSeconds = 15
        }
        try server.register(tool: ToolDefinition(name: "read-roots")) { _, context in
            do {
                return .text(try await context.roots("roots").map(\.uri).joined(separator: ","))
            } catch let error as MCPError where error.code == peerErrorCode {
                return .text("peer error accepted")
            } catch {
                return .text("roots unavailable")
            }
        }

        let client = try await IndependentProtocol.client(server, .r2025_11_25, capabilities: ["roots": [:]])
        let firstCall = client.post("tools/call", ["name": "read-roots"], id: "first-roots-call")
        let firstRequest = try await client.next(timeout: timeout)
        try #require(firstRequest["method"] == "roots/list")
        let firstRequestID = try #require(firstRequest["id"])

        // The peer sends its reply without the required JSON-RPC error message.
        client.send([
            "jsonrpc": "2.0", "id": firstRequestID,
            "error": ["code": JSONValue(peerErrorCode)],
        ])
        let firstReply = try await client.next(timeout: timeout)
        try #require(firstReply["id"] == firstCall.json)
        #expect(firstReply["result"]?["content"]?[0]?["text"] == "roots unavailable")

        let secondCall = client.post("tools/call", ["name": "read-roots"], id: "second-roots-call")
        let secondRequest = try await client.next(timeout: timeout)
        try #require(secondRequest["method"] == "roots/list")
        let secondRequestID = try #require(secondRequest["id"])
        #expect(secondRequestID != firstRequestID)
        client.send([
            "jsonrpc": "2.0", "id": secondRequestID,
            "result": ["roots": [["uri": "file:///fixture"]]],
        ])
        let secondReply = try await client.next(timeout: timeout)
        #expect(secondReply["id"] == secondCall.json)
        #expect(secondReply["result"]?["content"]?[0]?["text"] == "file:///fixture")

        let marker = client.post("ping", id: "after-roots-calls")
        let ping = try await client.next(timeout: timeout)
        #expect(ping["id"] == marker.json)
        #expect(ping["result"] != nil)
    }
}
