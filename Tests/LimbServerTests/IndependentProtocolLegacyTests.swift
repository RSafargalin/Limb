import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var text: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}

/// What exists only in the handshake revisions: `ping`, `logging/setLevel`, and — in
/// `2025-03-26` alone — JSON-RPC batches.
@Suite struct IndependentProtocolLegacyTests {
    // MARK: Logging

    /// "the server SHOULD send … messages at or above the requested level"; the levels are those
    /// of RFC 5424, least severe first (`server/utilities/logging.mdx`). For every level, in every
    /// handshake revision, exactly the levels at or above it arrive.
    @Test(arguments: IndependentProtocolRevision.legacy)
    func setLevelFiltersExactlyByThreshold(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        // Not in order of severity, so that raising and lowering the threshold are both exercised.
        for level in ["warning", "debug", "emergency", "info", "alert", "notice", "critical", "error"] {
            let set = try await client.request("logging/setLevel", ["level": .string(level)])
            #expect(set["result"] == [:], "\(level): \(set)")
            client.clearReceived()
            _ = try await client.request("tools/call", ["name": "log_all"])
            let received = client.received.filter { $0["method"] == "notifications/message" }.compactMap { $0["params"]?["level"]?.stringValue }
            let threshold = try #require(IndependentProtocolRich.levels.firstIndex(of: level))
            #expect(received == Array(IndependentProtocolRich.levels[threshold...]), "threshold \(level) in \(revision.rawValue)")
        }
    }

    /// The same filter in `2026-07-28`, where the level travels with the request
    /// (`_meta["io.modelcontextprotocol/logLevel"]`).
    @Test func perRequestLevelFiltersExactlyByThreshold() async throws {
        let client = TestClient(try IndependentProtocolRich.server())
        for level in IndependentProtocolRich.levels.reversed() {
            client.clearReceived()
            _ = try await client.request("tools/call", ["name": "log_all"], meta: ["io.modelcontextprotocol/logLevel": .string(level)])
            let received = client.received.filter { $0["method"] == "notifications/message" }.compactMap { $0["params"]?["level"]?.stringValue }
            let threshold = try #require(IndependentProtocolRich.levels.firstIndex(of: level))
            #expect(received == Array(IndependentProtocolRich.levels[threshold...]), "threshold \(level)")
        }
        // "The server MUST NOT emit notifications/message for a request that does not include this field."
        client.clearReceived()
        _ = try await client.request("tools/call", ["name": "log_all"])
        #expect(client.received.isEmpty)
    }

    /// "Invalid log level: -32602 (Invalid params)" — and a refused request changes nothing.
    @Test(arguments: IndependentProtocolRevision.legacy)
    func invalidLevelsAreRefusedAndChangeNothing(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        #expect(try await client.request("logging/setLevel", ["level": "error"])["result"] == [:])
        for params in [
            "{}", #"{"level":"verbose"}"#, #"{"level":"warn"}"#, #"{"level":"DEBUG"}"#, #"{"level":"Debug"}"#, #"{"level":" debug"}"#,
            #"{"level":"debug "}"#, #"{"level":""}"#, #"{"level":"trace"}"#, #"{"level":"fatal"}"#, #"{"level":"off"}"#, #"{"level":"0"}"#,
            #"{"level":0}"#, #"{"level":7}"#, #"{"level":null}"#, #"{"level":true}"#, #"{"level":["debug"]}"#, #"{"level":{"level":"debug"}}"#,
            #"{"Level":"debug"}"#, #"{"logLevel":"debug"}"#,
        ] {
            let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":8,"method":"logging/setLevel","params":\#(params)}"#)
            #expect(reply.code == -32602, "\(revision.rawValue) \(params): \(reply)")
        }
        client.clearReceived()
        _ = try await client.request("tools/call", ["name": "log_all"])
        let received = client.received.compactMap { $0["params"]?["level"]?.stringValue }
        #expect(received == ["error", "critical", "alert", "emergency"], "the level moved: \(received)")
    }

    /// The level belongs to the session that set it, not to the server.
    @Test func theLevelIsPerConnection() async throws {
        let server = try IndependentProtocolRich.server()
        let loud = try await IndependentProtocol.client(server, .r2025_11_25)
        let quiet = try await IndependentProtocol.client(server, .r2025_11_25)
        _ = try await loud.request("logging/setLevel", ["level": "debug"])
        _ = try await quiet.request("logging/setLevel", ["level": "emergency"])
        _ = try await loud.request("tools/call", ["name": "log_all"])
        _ = try await quiet.request("tools/call", ["name": "log_all"])
        _ = try await loud.request("tools/call", ["name": "log_all"])
        #expect(loud.received.count { $0["method"] == "notifications/message" } == 16)
        #expect(quiet.received.count { $0["method"] == "notifications/message" } == 1)
    }

    // MARK: Ping

    /// "The receiver MUST respond promptly with an empty response" (`basic/utilities/ping.mdx`):
    /// `{}` — whatever the client adds to the request, and whatever happened on the connection before.
    @Test(arguments: IndependentProtocolRevision.legacy)
    func pingIsAlwaysAnEmptyResult(_ revision: IndependentProtocolRevision) async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), revision)
        _ = try await client.request("tools/list", meta: IndependentProtocol.modernMeta)
        _ = try await client.request("tools/call", ["name": "everything", "arguments": ["count": 1]])
        for params in ["", #","params":{}"#, #","params":{"_meta":{"progressToken":7}}"#, #","params":{"anything":[1,2,3],"_meta":{"x":"y"}}"#] {
            let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":"p","method":"ping"\#(params)}"#)
            #expect(reply == ["jsonrpc": "2.0", "id": "p", "result": [:]], "\(reply)")
        }
    }

    // MARK: Batches (2025-03-26)

    private func batchClient(_ server: Server) async throws -> TestClient {
        try await IndependentProtocol.client(server, .r2025_03_26)
    }

    /// The reply to a batch: one array, one response per request, none for notifications
    /// (JSON-RPC 2.0 §6); "MCP implementations … MUST support receiving JSON-RPC batches"
    /// (`2025-03-26/basic/index.mdx`).
    @Test func aBatchIsAnsweredWithOneArray() async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await batchClient(try IndependentProtocolRich.server(recorder: recorder))
        client.send(
            """
            [{"jsonrpc":"2.0","id":1,"method":"ping"},\
            {"jsonrpc":"2.0","method":"notifications/initialized"},\
            {"jsonrpc":"2.0","id":"two","method":"tools/call","params":{"name":"plain"}},\
            {"jsonrpc":"2.0","id":3,"method":"tools/list"},\
            {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"nobody"}},\
            {"jsonrpc":"2.0","id":4,"method":"no/such/method"},\
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool"}},\
            {"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"rich://static"}},\
            {"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":"bare"}},\
            {"jsonrpc":"2.0","id":99,"result":{}},\
            {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"tool_error"}}]
            """)
        let reply = try await client.next()
        let responses = try #require(reply.arrayValue, "the reply to a batch must be an array: \(reply)")
        #expect(responses.count == 8, "\(reply)")
        func response(_ id: JSONValue) -> JSONValue? {
            let matching = responses.filter { $0["id"] == id }
            #expect(matching.count == 1, "\(matching.count) responses for id \(id)")
            return matching.first
        }
        #expect(response(1)?["result"] == [:])
        #expect(response("two")?.text == "plain result")
        #expect(response(3)?["result"]?["tools"]?.arrayValue?.isEmpty == false)
        #expect(response(4)?.code == -32601)
        #expect(response(5)?.code == -32602)
        #expect(response(6)?["result"]?["contents"]?[0]?["text"] == "static contents")
        #expect(response(7)?["result"]?["messages"] == [])
        #expect(response(8)?["result"]?["isError"] == true)
        // Every element is a well-formed 2025-03-26 response, and nothing else follows.
        let methods: [JSONValue: String] = [
            1: "ping", "two": "tools/call", 3: "tools/list", 4: "no/such/method", 5: "tools/call", 6: "resources/read", 7: "prompts/get",
            8: "tools/call",
        ]
        for element in responses {
            let method = try #require(methods[element["id"] ?? .null], "a response nobody asked for: \(element)")
            let violations = IndependentProtocol.responseViolations(element, to: method, in: .r2025_03_26)
            #expect(violations.isEmpty, "\(element): \(violations)")
        }
        #expect(try await IndependentProtocol.drain(client).isEmpty)
        #expect(recorder.count(of: "plain") == 1)
    }

    /// "If there are no Response objects contained within the Response array as it is to be sent
    /// to the client, the server MUST NOT return an empty Array and should return nothing at all"
    /// (JSON-RPC 2.0 §6).
    @Test(arguments: [
        #"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#,
        #"[{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","method":"notifications/unknown","params":{"a":1}}]"#,
        #"[{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}},{"jsonrpc":"2.0","id":1,"result":{}}]"#,
        #"[{"jsonrpc":"2.0","id":7,"result":{}},{"jsonrpc":"2.0","id":8,"error":{"code":-1,"message":"no"}}]"#,
        #"[{"jsonrpc":"2.0","method":"tools/call","params":{"name":"plain"}}]"#,
        // Notifications with malformed parameters are notifications all the same.
        #"[{"jsonrpc":"2.0","method":"notifications/cancelled","params":[1]}]"#,
        #"[{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","method":"notifications/x","params":"oops"}]"#,
    ])
    func aBatchWithNothingToAnswerIsNotAnswered(_ frame: String) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await batchClient(try IndependentProtocolRich.server(recorder: recorder))
        let replies = try await IndependentProtocol.exchange(client, frame)
        #expect(replies.isEmpty, "\(replies)")
        #expect(recorder.entries.isEmpty)
    }

    /// JSON-RPC 2.0 §7, "rpc call with an empty Array": a single error object, -32600, id null.
    @Test func anEmptyBatchIsOneInvalidRequestError() async throws {
        let client = try await batchClient(try IndependentProtocolRich.server())
        for frame in ["[]", "[ ]", " [\t] "] {
            let reply = try await IndependentProtocol.reply(client, frame)
            #expect(reply.arrayValue == nil, "a single object, not an array: \(reply)")
            #expect(reply.code == -32600)
            #expect(reply["id"] == .null)
        }
    }

    /// JSON-RPC 2.0 §7, "rpc call with invalid Batch": one -32600 error with a null id per
    /// invalid element, in an array; valid elements next to them are still served.
    @Test(arguments: [
        ("[1]", 1), ("[1,2,3]", 3), ("[null]", 1), (#"["ping"]"#, 1), ("[true,false]", 2), ("[[]]", 1), ("[[1]]", 1), ("[{}]", 1),
        (#"[[{"jsonrpc":"2.0","id":1,"method":"ping"}]]"#, 1), (#"[{"id":1,"method":"ping"}]"#, 1), (#"[{"jsonrpc":"2.0","id":null,"method":"ping"}]"#, 1),
        (#"[{"jsonrpc":"2.0","id":[1],"method":"ping"},{"jsonrpc":"2.0","id":{},"method":"ping"}]"#, 2),
    ])
    func invalidBatchMembersEachGetAnError(_ frame: String, _ count: Int) async throws {
        let client = try await batchClient(try IndependentProtocolRich.server())
        let alone = try #require(try await IndependentProtocol.reply(client, frame).arrayValue)
        #expect(alone.count == count, "\(alone)")
        #expect(alone.allSatisfy { $0.code == -32600 }, "\(alone)")
        // With a valid request in front of and behind them.
        let mixed = #"[{"jsonrpc":"2.0","id":"first","method":"ping"},"# + frame.dropFirst().dropLast() + #",{"jsonrpc":"2.0","id":"last","method":"ping"}]"#
        let responses = try #require(try await IndependentProtocol.reply(client, String(mixed)).arrayValue)
        #expect(responses.count == count + 2, "\(responses)")
        #expect(responses.count { $0["result"] == [:] && ($0["id"] == "first" || $0["id"] == "last") } == 2)
        #expect(responses.count { $0.code == -32600 } == count)
    }

    @Test func aBatchOfOneIsStillAnsweredWithAnArray() async throws {
        let client = try await batchClient(try IndependentProtocolRich.server())
        let reply = try await IndependentProtocol.reply(client, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        #expect(reply == [["jsonrpc": "2.0", "id": 1, "result": [:]]])
    }

    /// "The request ID MUST NOT have been previously used by the requestor within the same
    /// session" (`2025-03-26/basic/index.mdx`): two requests of one batch under one id are not
    /// both served; each still gets a response, as JSON-RPC requires of every request.
    @Test func duplicateIdsInsideABatch() async throws {
        let gate = Gate()
        let started = Counter()
        let client = try await batchClient(try makeServer(gate: gate, started: started))
        client.send(
            #"[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait"}},{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait"}},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#)
        // Nothing can be sent before the first is released: a batch is answered as a whole.
        #expect(try await IndependentProtocol.drain(client).isEmpty)
        gate.open()
        let responses = try #require(try await client.next().arrayValue)
        #expect(responses.count == 3, "\(responses)")
        let forOne = responses.filter { $0["id"] == 1 }
        #expect(forOne.count == 2)
        #expect(forOne.count { $0.text == "released" } == 1, "\(forOne)")
        #expect(forOne.count { $0.code == -32600 } == 1, "\(forOne)")
        #expect(responses.count { $0["id"] == 2 && $0["result"] == [:] } == 1)
        #expect(started.count == 1, "the duplicate must not run")
    }

    @Test func theBatchSizeLimitIsExact() async throws {
        func batch(_ count: Int) -> String {
            "[" + (1...count).map { #"{"jsonrpc":"2.0","id":\#($0),"method":"tools/call","params":{"name":"plain"}}"# }.joined(separator: ",") + "]"
        }
        for limit in [64, 2, 1] {
            let recorder = IndependentProtocolRecorder()
            let server = try IndependentProtocolRich.server(recorder: recorder) { $0.budgets.maxBatchItems = limit }
            let client = try await batchClient(server)
            client.send(batch(limit))
            let served = try #require(try await client.next().arrayValue)
            #expect(served.count == limit)
            #expect(Set(served.compactMap { $0["id"]?.intValue }) == Set(1...limit))
            #expect(served.allSatisfy { $0.text == "plain result" })
            #expect(recorder.count(of: "plain") == limit)

            let refused = try await IndependentProtocol.reply(client, batch(limit + 1))
            #expect(refused.arrayValue == nil && refused.code == -32600 && refused["id"] == .null, "\(refused)")
            _ = try await IndependentProtocol.drain(client)
            #expect(recorder.count(of: "plain") == limit, "a refused batch ran its requests")
        }
    }

    @Test(arguments: [IndependentProtocolRevision.r2025_06_18, .r2025_11_25])
    func batchesAreRefusedAfter2025_03_26(_ revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(recorder: recorder), revision)
        for frame in [
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
            #"[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"plain"}},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"plain"}}]"#,
            #"[{"jsonrpc":"2.0","id":1,"method":"logging/setLevel","params":{"level":"emergency"}}]"#,
            "[]", "[1]",
        ] {
            let reply = try await IndependentProtocol.reply(client, frame)
            #expect(reply.arrayValue == nil, "\(reply)")
            #expect(reply.code == -32600, "\(frame): \(reply)")
            #expect(reply["id"] == .null)
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
        // The refused setLevel did not take effect, and the connection goes on.
        client.clearReceived()
        _ = try await client.request("tools/call", ["name": "log_all"])
        #expect(client.received.count { $0["method"] == "notifications/message" } > 1)
    }

    /// No handshake, no batch: `2026-07-28` has no batching, and without a session there is no
    /// revision that would allow one.
    @Test func batchesAreRefusedWithoutASession() async throws {
        let recorder = IndependentProtocolRecorder()
        let server = try IndependentProtocolRich.server(recorder: recorder)
        let modernCall = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(IndependentProtocol.modernMetaText),"name":"plain"}}"#
        for client in [TestClient(server, modern: false), TestClient(server)] {
            for frame in ["[\(modernCall)]", "[\(modernCall),\(modernCall)]", #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, "[]",
                          #"[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}]"#] {
                let reply = try await IndependentProtocol.reply(client, frame)
                #expect(reply.arrayValue == nil && reply.code == -32600 && reply["id"] == .null, "\(frame): \(reply)")
            }
            // In particular the batched `initialize` created no session ("The initialize request
            // MUST NOT be part of a JSON-RPC batch", `2025-03-26/basic/lifecycle.mdx`).
            let bare = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            #expect(bare.code == -32602)
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
    }

    @Test func modernRequestsAreNotServedFromABatch() async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await batchClient(try IndependentProtocolRich.server(recorder: recorder))
        let modernCall = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(IndependentProtocol.modernMetaText),"name":"plain"}}"#
        client.send("[\(modernCall)]")
        let reply = try await client.next()
        let element = reply.arrayValue?.first ?? reply
        #expect(element["result"] == nil, "a 2026-07-28 request was served from a batch: \(reply)")
        #expect(element.code == -32600, "\(reply)")
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
    }
}
