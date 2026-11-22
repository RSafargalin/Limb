import Foundation
import Limb
import LimbTesting
import Testing

@Suite(.timeLimit(.minutes(2)))
struct Round2ProtocolRequestIDTests {
    private static func server(recorder: IndependentProtocolRecorder, configure: (inout ServerConfiguration) -> Void = { _ in }) throws -> Server {
        let server = R2P.server(configure: configure)
        try server.register(tool: ToolDefinition(name: "t")) { _, _ in
            recorder.note("ran")
            return .text("ok")
        }
        return server
    }

    /// Ids up to the limit are echoed exactly; one byte more is `-32600` with a null id, and
    /// the handler does not run. String and integer ids alike, counted in UTF-8 bytes.
    @Test(arguments: [IndependentProtocolRevision.r2025_11_25, .r2026_07_28])
    func idLengthLimit(revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await R2P.client(try Self.server(recorder: recorder), revision)
        let limit = ServerBudgets.local.maxRequestIDBytes
        #expect(limit == 8 * 1024)
        // An integer of `limit` digits; the FoundationJSON codec cannot represent one, so it is
        // left out there.
        let bigInteger = try? JSON.parse(Array(("1" + String(repeating: "0", count: limit - 1)).utf8))
        let accepted: [JSONValue] = [
            .string(String(repeating: "a", count: limit)),
            .string(String(repeating: "\u{E9}", count: limit / 2)),
        ] + (bigInteger.map { [$0] } ?? [])
        for id in accepted {
            let response = try await client.request("tools/call", ["name": "t"], id: try #require(RequestID(json: id)))
            #expect(response["id"] == id && response.r2pText == "ok", "\(id.description.prefix(20))…")
        }
        // Written as raw frames, so that the integer needs no codec on the test side.
        let refused: [(text: String, codes: Set<Int>)] = [
            ("\"" + String(repeating: "a", count: limit + 1) + "\"", [-32600]),
            ("\"" + String(repeating: "\u{E9}", count: limit / 2 + 1) + "\"", [-32600]),
            // Limb's parser reads it (-32600); Foundation's cannot represent it (-32700).
            (String(repeating: "7", count: limit + 1), bigInteger == nil ? [-32600, -32700] : [-32600]),
        ]
        recorder.clear()
        let meta = revision.isModern ? ",\(IndependentProtocol.modernMetaText)" : ""
        for (text, codes) in refused {
            client.send(#"{"jsonrpc":"2.0","id":\#(text),"method":"tools/call","params":{"name":"t"\#(meta)}}"#)
            let response = try await client.next()
            #expect(response.r2pCode.map(codes.contains) == true, "\(response.description.prefix(200))")
            #expect(response["id"] == .null)
            #expect(response.description.utf8.count < 1024)
        }
        #expect(recorder.entries.isEmpty, "a handler ran for a refused id")
        #expect(try await client.request("tools/call", ["name": "t"]).r2pText == "ok")
    }

    /// In a 2025-03-26 batch the over-long member is answered with its own null-id error; the
    /// others are served.
    @Test func idLengthLimitInsideABatch() async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await R2P.client(try Self.server(recorder: recorder), .r2025_03_26)
        let long = String(repeating: "x", count: 9000)
        client.send(
            #"[{"jsonrpc":"2.0","id":"\#(long)","method":"tools/call","params":{"name":"t"}},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"t"}}]"#
        )
        let batch = try #require(try await client.next().arrayValue)
        #expect(batch.count == 2)
        #expect(batch.contains { $0["id"] == .null && $0.r2pCode == -32600 })
        #expect(batch.contains { $0["id"] == 2 && $0.r2pText == "ok" })
        #expect(recorder.count(of: "ran") == 1)
    }

    /// A cancellation naming an over-long id is a notification: nothing is answered, and the
    /// connection keeps working.
    @Test func cancellationWithALongRequestID() async throws {
        let client = try await R2P.client(try Self.server(recorder: IndependentProtocolRecorder()), .r2025_11_25)
        client.notify("notifications/cancelled", ["requestId": .string(String(repeating: "c", count: 100_000)), "reason": "x"])
        #expect(try await client.request("tools/call", ["name": "t"]).r2pText == "ok")
        #expect(client.received.isEmpty)
    }

    /// An `initialize` whose result is over `maxResponseBytes` is an error under its id, and
    /// creates no session.
    @Test func anInitializeTooLargeToSendCreatesNoSession() async throws {
        let server = try Self.server(recorder: IndependentProtocolRecorder()) { configuration in
            configuration.instructions = String(repeating: "i", count: 4000)
            configuration.budgets.maxResponseBytes = 1000
        }
        let client = TestClient(server, modern: false)
        let response = try await client.initialize(version: .v2025_11_25)
        #expect(response.r2pCode == -31002, "\(response)")
        #expect(response["id"] != nil && response["id"] != .null)
        // No session: a session-only request is not served.
        let list = try await client.request("tools/list")
        #expect(list["result"] == nil, "\(list)")
    }

    /// A 2025-03-26 batch that cannot be brought within `maxResponseBytes`: an array in which
    /// every request member has `-31002` under its own id (2025-03-26 `basic/index.mdx`: the
    /// batch response contains a response for each request).
    @Test func aBatchThatCannotFitAnswersEveryMemberUnderItsOwnID() async throws {
        // The limit admits the handshake but not the batch.
        let small = R2P.server { $0.budgets.maxResponseBytes = 600 }
        try small.register(tool: ToolDefinition(name: "big")) { _, _ in .text(String(repeating: "b", count: 2000)) }
        let tight = try await R2P.client(small, .r2025_03_26)
        tight.send(
            #"[{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"big"}},{"jsonrpc":"2.0","id":"b","method":"tools/call","params":{"name":"big"}},{"jsonrpc":"2.0","method":"notifications/x"}]"#
        )
        let batch = try #require(try await tight.next().arrayValue)
        #expect(batch.count == 2, "\(batch)")
        for id in ["a", "b"] {
            #expect(batch.first { $0["id"] == .string(id) }?.r2pCode == -31002, "\(batch)")
        }
    }
}
