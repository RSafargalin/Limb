import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
}

private let initialize2025_11_25 =
    #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#

/// The JSON-RPC envelope: what is a request, a notification, a response or garbage, which error
/// each failure gets, and what `id` the answer carries. Sources: JSON-RPC 2.0 §4–§5 and
/// `docs/specification/2026-07-28/basic/index.mdx`, "Messages" (the same rules in every revision).
@Suite struct IndependentProtocolEnvelopeTests {
    /// A raw connection with a `2025-11-25` session, so that a bare `ping` is a valid request.
    private func legacyPeer(_ server: Server? = nil) throws -> IndependentProtocolRawPeer {
        let peer = IndependentProtocolRawPeer(try server ?? IndependentProtocolRich.server())
        let reply = peer.send(initialize2025_11_25)
        try #require(reply.count == 1 && reply[0].contains(#""protocolVersion":"2025-11-25""#), "\(reply)")
        return peer
    }

    /// Whether `frames` is exactly one response with an empty result under `id` (as JSON text).
    private static func isEmptyResult(_ frames: [String], id: String) -> Bool {
        guard frames.count == 1, let object = IndependentProtocolRawPeer.foundationObject(frames[0]) else { return false }
        return Set(object.keys) == ["jsonrpc", "id", "result"] && (object["result"] as? [String: Any])?.isEmpty == true
            && IndependentProtocolRawPeer.idText(of: frames[0]) == id
    }

    // MARK: Garbage and invalid requests

    private struct Rejection: Sendable, CustomTestStringConvertible {
        let frame: String
        let code: Int
        /// The exact text of the `id` in the answer.
        let id: String
        var testDescription: String { frame.count > 80 ? String(frame.prefix(80)) + "…" : frame }
    }

    /// -32700: "Invalid JSON was received by the server". The id is unknown, hence `null`
    /// (JSON-RPC 2.0 §5.1) — MCP: "except in error cases where the ID could not be read".
    private static let unparseable: [Rejection] = [
        "", " ", "\t", "{", "}", "[", "nul", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"", #"{"jsonrpc":"2.0","id":1,"method":"ping"} x"#,
        #"{"jsonrpc":"2.0","id":1,"method":"ping"}{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        #"{'jsonrpc':'2.0','id':1,'method':'ping'}"#, #"{jsonrpc:"2.0",id:1,method:"ping"}"#,
        #"{"jsonrpc":"2.0","id":01,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":+1,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":.5,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":1.,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":NaN,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":Infinity,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":0x10,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"pi\qng"}"#, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"pi\nng\"}",
        #"{"jsonrpc":"2.0","id":1,"method":"\ud800"}"#, "// comment\n{}", #"{"jsonrpc":"2.0","id":1,"method":"ping"}/* c */"#,
        "\u{FEFF}{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
    ].map { Rejection(frame: $0, code: -32700, id: "null") }

    #if FoundationJSON
    private static let trailingComma: [Rejection] = []
    #else
    private static let trailingComma = [Rejection(frame: #"{"jsonrpc":"2.0","id":1,"method":"ping",}"#, code: -32700, id: "null")]
    #endif

    /// -32600: "The JSON sent is not a valid Request object". The id is echoed when it could be read.
    private static let invalidRequests: [Rejection] = [
        // Valid JSON that is not an object.
        Rejection(frame: "42", code: -32600, id: "null"),
        Rejection(frame: #""ping""#, code: -32600, id: "null"),
        Rejection(frame: "null", code: -32600, id: "null"),
        Rejection(frame: "true", code: -32600, id: "null"),
        Rejection(frame: "{}", code: -32600, id: "null"),
        // "jsonrpc MUST be exactly "2.0"".
        Rejection(frame: #"{"id":7,"method":"ping"}"#, code: -32600, id: "7"),
        Rejection(frame: #"{"jsonrpc":"1.0","id":7,"method":"ping"}"#, code: -32600, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2","id":7,"method":"ping"}"#, code: -32600, id: "7"),
        Rejection(frame: #"{"jsonrpc":2.0,"id":"seven","method":"ping"}"#, code: -32600, id: #""seven""#),
        Rejection(frame: #"{"jsonrpc":null,"id":7,"method":"ping"}"#, code: -32600, id: "7"),
        Rejection(frame: #"{"JSONRPC":"2.0","id":7,"method":"ping"}"#, code: -32600, id: "7"),
        // "Requests MUST include a string or integer ID"; "the ID MUST NOT be null".
        Rejection(frame: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, code: -32600, id: "null"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, code: -32600, id: "null"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":[1],"method":"ping"}"#, code: -32600, id: "null"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":{"n":1},"method":"ping"}"#, code: -32600, id: "null"),
        // "method: A String".
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":5}"#, code: -32600, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":null}"#, code: -32600, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":["ping"]}"#, code: -32600, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":{"name":"ping"}}"#, code: -32600, id: "7"),
        // Neither a request nor a response. With an id but no method, result or error the message
        // cannot be told from a reply whose result was lost on the way (a JavaScript client that
        // serializes `result: undefined` writes exactly this), and an error sent under that id
        // could land on one of the peer's own requests: it goes out with a null id.
        Rejection(frame: #"{"jsonrpc":"2.0","id":7}"#, code: -32600, id: "null"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":"seven"}"#, code: -32600, id: "null"),
        Rejection(frame: #"{"jsonrpc":"2.0"}"#, code: -32600, id: "null"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"params":{}}"#, code: -32600, id: "null"),
    ]

    /// -32602: `params` of a request, when present, is an object in MCP (`params?: { [key: string]: unknown }`).
    private static let invalidParams: [Rejection] = [
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":"ping","params":[]}"#, code: -32602, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":"ping","params":[1,2]}"#, code: -32602, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":"s","method":"ping","params":"x"}"#, code: -32602, id: #""s""#),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":"ping","params":5}"#, code: -32602, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":"ping","params":true}"#, code: -32602, id: "7"),
        Rejection(frame: #"{"jsonrpc":"2.0","id":7,"method":"ping","params":null}"#, code: -32602, id: "7"),
    ]

    @Test(arguments: unparseable + trailingComma + invalidRequests + invalidParams)
    private func malformedMessagesGetTheRightErrorAndId(_ rejection: Rejection) throws {
        let peer = try legacyPeer()
        let replies = peer.send(rejection.frame)
        try #require(replies.count == 1, "\(replies)")
        let reply = try #require(IndependentProtocolRawPeer.foundationObject(replies[0]), "not JSON: \(replies[0])")
        #expect(Set(reply.keys) == ["jsonrpc", "id", "error"], "\(replies[0])")
        #expect(reply["jsonrpc"] as? String == "2.0")
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? Int == rejection.code, "\(replies[0])")
        #expect((error["message"] as? String)?.isEmpty == false)
        #expect(IndependentProtocolRawPeer.idText(of: replies[0]) == rejection.id, "\(replies[0])")
        // One bad frame does not disturb the connection: the next request is served.
        #expect(Self.isEmptyResult(peer.send(#"{"jsonrpc":"2.0","id":"after","method":"ping"}"#), id: #""after""#))
    }

    @Test func invalidUTF8IsAParseError() throws {
        let peer = try legacyPeer()
        let prefix = Array(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":""#.utf8)
        let suffix = Array(#""}}"#.utf8)
        for bad in [[0xFF], [0xC3], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0x80]] as [[UInt8]] {
            let replies = peer.send(bytes: prefix + bad + suffix)
            try #require(replies.count == 1, "\(bad): \(replies)")
            #expect(replies[0].contains(#""code":-32700"#), "\(bad): \(replies[0])")
            #expect(IndependentProtocolRawPeer.idText(of: replies[0]) == "null")
        }
        #expect(Self.isEmptyResult(peer.send(#"{"jsonrpc":"2.0","id":"after","method":"ping"}"#), id: #""after""#))
    }

    // MARK: The id

    /// "Result responses MUST include the same ID as the request they correspond to." A string
    /// stays a string and a number stays that number, digit for digit.
    @Test(arguments: [
        // Integers, including ones no double holds exactly.
        "0", "1", "-1", "7", "2147483648", "9007199254740993", "-9007199254740993", "9223372036854775807",
        "-9223372036854775808", "18446744073709551615",
        // Strings: numeric-looking, empty, spaces, quotes and escapes, non-ASCII, long.
        #""0""#, #""1""#, #""-1""#, #""""#, #"" ""#, #""null""#, #""true""#, #""a b""#, #""a\"b""#, #""a\\b""#, #""{\"id\":1}""#,
        #""é""#, #""日本語""#, #""😀""#, #""é""#, #""req-0000000000000000000000000000000000000000000000000000000000000000""#,
    ])
    func idIsEchoedExactly(_ id: String) throws {
        let peer = try legacyPeer()
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(id.utf8), options: .fragmentsAllowed) as? NSObject)
        for (method, key) in [("ping", "result"), ("no/such/method", "error"), ("tools/call", "error")] {
            let replies = peer.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#)
            try #require(replies.count == 1, "\(replies)")
            let reply = try #require(IndependentProtocolRawPeer.foundationObject(replies[0]))
            #expect(reply[key] != nil, "\(replies[0])")
            let echoed = try #require(IndependentProtocolRawPeer.idText(of: replies[0]), "\(replies[0])")
            if id.hasPrefix("\"") {
                // Same string value; the escaping on the way back is the server's choice.
                #expect(reply["id"] is String)
                #expect((reply["id"] as? NSObject) == expected, "\(replies[0])")
                #expect(echoed.hasPrefix("\""))
            } else {
                #expect(echoed == id, "\(replies[0])")
            }
        }
    }

    #if !FoundationJSON
    @Test(arguments: [
        "18446744073709551616", "123456789012345678901234567890123456789012345678901234567890", "-123456789012345678901234567890",
        "-0", "1.0", "1.50", "0.1", "1e2", "1E2", "1e+2", "1e-2", "100e-2", "1.5", "-2.5e3", "1e400",
    ])
    func numericIdKeepsItsText(_ id: String) throws {
        let peer = try legacyPeer()
        let replies = peer.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)
        try #require(replies.count == 1, "\(replies)")
        let echoed = IndependentProtocolRawPeer.idText(of: replies[0])
        if replies[0].contains(#""result""#) {
            #expect(echoed == id, "\(replies[0])")
        } else {
            #expect(replies[0].contains(#""code":-32600"#), "\(replies[0])")
            #expect(echoed == id || echoed == "null", "\(replies[0])")
        }
    }
    #endif

    /// A string id and a numeric id with the same digits are different ids: both can be in flight.
    @Test func stringAndNumberIdsDoNotCollide() async throws {
        let gate = Gate()
        let server = try makeServer(gate: gate)
        let client = TestClient(server)
        let number = client.post("tools/call", ["name": "wait"], id: 1)
        let string = client.post("tools/call", ["name": "wait"], id: "1")
        // If the two were taken for one id, the second would be refused at once as a duplicate.
        let early = try await IndependentProtocol.drain(client)
        #expect(early.allSatisfy { $0["error"] == nil }, "\(early)")
        gate.open()
        let answers = await IndependentProtocol.responses(client, to: [number, string])
        let first = answers[number]
        let second = answers[string]
        #expect(first?["id"] == 1 && first?["result"]?["content"]?[0]?["text"] == "released", "\(answers)")
        #expect(second?["id"] == "1" && second?["result"]?["content"]?[0]?["text"] == "released", "\(answers)")
    }

    // MARK: Notifications

    /// "The receiver MUST NOT send a response" (basic/index.mdx, "Notifications"); JSON-RPC 2.0
    /// §4.1: "The Server MUST NOT reply to a Notification" and the client "would not be aware of
    /// any errors (like e.g. "Invalid params", "Internal error")". A message with a string
    /// `method` and no `id` is a notification, whatever else is wrong with it.
    @Test(arguments: [
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{"x":1},"extra":[1,2]}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":12345}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"never-sent","reason":"x"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":{"id":1}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":[1]}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":5}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/unknown/made_up","params":{"a":{"b":{"c":[1,2,3]}}}}"#,
        #"{"jsonrpc":"2.0","method":"","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"ping"}"#,
        #"{"jsonrpc":"2.0","method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"plain"}}"#,
        #"{"jsonrpc":"2.0","method":"no/such/method"}"#,
        #"{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized","unknownTopLevel":true}"#,
        // Malformed parameters: still notifications, still no reply.
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":[1]}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":"x"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":7}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":null}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized","params":[]}"#,
        #"{"jsonrpc":"2.0","method":"notifications/unknown","params":false}"#,
    ])
    func notificationsAreNeverAnswered(_ frame: String) async throws {
        let recorder = IndependentProtocolRecorder()
        let server = try IndependentProtocolRich.server(recorder: recorder)
        // With a handshake session, and on a fresh connection that has none.
        for peer in [try legacyPeer(server), IndependentProtocolRawPeer(server)] {
            let replies = peer.send(frame)
            #expect(replies.isEmpty, "a notification was answered: \(replies)")
        }
        // A notification never runs a request handler, and never changes the negotiated revision.
        let peer = try legacyPeer(server)
        _ = peer.send(frame)
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
        let list = try #require(peer.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).first)
        #expect(list.contains(#""icons""#), "the session is no longer 2025-11-25: \(list)")
    }

    // MARK: Responses from the client

    /// A response to a request the server never sent is not a request: nothing to answer.
    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":99,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":"x","result":{"roots":[]}}"#,
        #"{"jsonrpc":"2.0","id":99,"result":null}"#,
        #"{"jsonrpc":"2.0","id":99,"error":{"code":-32601,"message":"Method not found"}}"#,
        #"{"jsonrpc":"2.0","id":99,"error":{"code":-1,"message":"refused","data":{"why":[1]}}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{},"unknown":1}"#,
        // A reply whose `error` is not an error object is a reply all the same.
        #"{"jsonrpc":"2.0","id":99,"error":"text"}"#, #"{"jsonrpc":"2.0","id":99,"error":null}"#, #"{"jsonrpc":"2.0","id":99,"error":{}}"#,
        #"{"jsonrpc":"2.0","id":99,"error":{"code":"x"}}"#, #"{"jsonrpc":"2.0","id":99,"error":{"message":"no code"}}"#,
        #"{"jsonrpc":"2.0","id":99,"error":[-32603,"m"]}"#, #"{"jsonrpc":"2.0","id":99,"error":{"code":1.5,"message":"m"}}"#,
        #"{"jsonrpc":"2.0","id":99,"result":{},"error":{"code":1,"message":"both"}}"#,
    ])
    func strayResponsesAreIgnored(_ frame: String) throws {
        let peer = try legacyPeer()
        #expect(peer.send(frame).isEmpty)
        // The id of a stray response is not "taken": a request may use it.
        #expect(Self.isEmptyResult(peer.send(#"{"jsonrpc":"2.0","id":99,"method":"ping"}"#), id: "99"))
    }

    // MARK: Tolerance

    @Test(arguments: IndependentProtocolRevision.allCases)
    func unknownMembersChangeNothing(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        let client = try await IndependentProtocol.client(server, revision)
        var calls = IndependentProtocolRich.calls
        if revision.isModern {
            calls.append(("server/discover", [:]))
        } else {
            calls += [("ping", [:]), ("logging/setLevel", ["level": "info"]), ("resources/subscribe", ["uri": "rich://static"])]
        }
        let junkMeta: JSONObject = [
            "com.example/unknown": ["nested": [1, 2, ["deep": nil]]], "traceparent": "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
            "io.modelcontextprotocol/somethingFromTheFuture": true, "": "empty key",
        ]
        var number = 1000
        for (method, params) in calls {
            let baseline = try #require(try await client.request(method, params)["result"], "\(method)")

            var withParams = params
            withParams["unknownParameter"] = ["a": [1, 2, 3]]
            withParams["task"] = ["ttl": 1]
            #expect(try await client.request(method, withParams)["result"] == baseline, "\(revision.rawValue) \(method): unknown params")

            #expect(try await client.request(method, params, meta: junkMeta)["result"] == baseline, "\(revision.rawValue) \(method): unknown _meta keys")

            // Unknown members next to jsonrpc/id/method/params.
            var metaForFrame = junkMeta
            if revision.isModern { metaForFrame = metaForFrame.merging(IndependentProtocol.modernMeta) }
            var fullParams = params
            fullParams["_meta"] = .object(metaForFrame)
            number += 1
            let frame: JSONValue = [
                "futureEnvelopeField": ["x": 1], "jsonrpc": "2.0", "id": .init(number), "method": .string(method),
                "params": .object(fullParams), "auth": "ignored", "result_": nil,
            ]
            client.send(frame)
            #expect(try await client.response(to: RequestID(number))["result"] == baseline, "\(revision.rawValue) \(method): unknown envelope members")
        }
    }

    /// Absent `params`, empty `params`: the same request.
    @Test func absentAndEmptyParamsAreTheSame() throws {
        let peer = try legacyPeer()
        for method in ["ping", "tools/list", "resources/list", "resources/templates/list", "prompts/list"] {
            let without = try #require(peer.send(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)"}"#).first)
            let empty = try #require(peer.send(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{}}"#).first)
            #expect(without == empty, "\(method)")
            #expect(without.contains(#""result""#))
        }
    }

    // MARK: Every frame the server writes

    /// One line, valid UTF-8, strict JSON, a JSON-RPC 2.0 response with the members of exactly one
    /// kind — for results and for every error the dispatcher can produce.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func everyFrameIsOneWellFormedMessage(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        let peer = IndependentProtocolRawPeer(server)
        var meta = ""
        if revision.isModern {
            meta = IndependentProtocol.modernMetaText
        } else {
            let frame = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(revision.rawValue)","capabilities":{}}}"#
            try #require(peer.send(frame).first?.contains(revision.rawValue) == true)
        }
        var requests = IndependentProtocolRich.calls
        requests += [
            ("tools/call", ["name": "nope"]), ("tools/call", ["name": "secret_failure"]), ("tools/call", ["name": "protocol_error"]),
            ("resources/read", ["uri": "rich://nope"]), ("prompts/get", ["name": "nope"]), ("prompts/get", ["name": "rich_prompt"]),
            ("completion/complete", [:]), ("no/such/method", [:]), ("tools/list", ["cursor": "zzz"]),
        ]
        for (index, (method, params)) in requests.enumerated() {
            var body = JSONValue.object(params).description
            if !meta.isEmpty { body = "{" + meta + (params.isEmpty ? "" : ",") + body.dropFirst() }
            let frames = await peer.send(#"{"jsonrpc":"2.0","id":\#(index + 1),"method":"\#(method)","params":\#(body)}"#, awaiting: 1)
            try #require(frames.count == 1, "\(method): \(frames)")
            let frame = frames[0]
            #expect(!frame.utf8.contains(0x0A) && !frame.utf8.contains(0x0D), "embedded line break in \(frame)")
            let object = try #require(IndependentProtocolRawPeer.foundationObject(frame), "not JSON: \(frame)")
            #expect(object["jsonrpc"] as? String == "2.0")
            #expect(IndependentProtocolRawPeer.idText(of: frame) == "\(index + 1)")
            let keys = Set(object.keys)
            #expect(keys == ["jsonrpc", "id", "result"] || keys == ["jsonrpc", "id", "error"], "\(frame)")
            if let error = object["error"] as? [String: Any] {
                #expect(error["code"] is Int && error["message"] is String, "\(frame)")
                #expect(Set(error.keys).isSubset(of: ["code", "message", "data"]), "\(frame)")
            }
            // "resultType" on results of 2026-07-28 only, and once.
            let occurrences = frame.components(separatedBy: #""resultType""#).count - 1
            #expect(occurrences == (revision.isModern && keys.contains("result") ? 1 : 0), "\(frame)")
        }
    }

    // MARK: What errors reveal

    @Test(arguments: IndependentProtocolRevision.allCases)
    func unexpectedFailuresDoNotLeakDetails(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        try server.register(resource: ResourceDefinition(uri: "secret://resource", name: "secret")) { _, _ in throw IndependentProtocolSecretFailure() }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "secret://t/{x}", name: "secret template"), complete: { _, _ in throw IndependentProtocolSecretFailure() }) { _, _ in
            throw IndependentProtocolSecretFailure()
        }
        try server.register(prompt: PromptDefinition(name: "secret_prompt"), complete: { _, _ in throw IndependentProtocolSecretFailure() }) { _, _ in
            throw IndependentProtocolSecretFailure()
        }
        try server.register(method: "secret/method") { _, _ in throw IndependentProtocolSecretFailure() }
        let client = try await IndependentProtocol.client(server, revision)
        for (method, params) in [
            ("tools/call", ["name": "secret_failure"]), ("resources/read", ["uri": "secret://resource"]),
            ("resources/read", ["uri": "secret://t/1"]), ("prompts/get", ["name": "secret_prompt"]),
            ("completion/complete", ["ref": ["type": "ref/prompt", "name": "secret_prompt"], "argument": ["name": "a", "value": ""]]),
            ("completion/complete", ["ref": ["type": "ref/resource", "uri": "secret://t/{x}"], "argument": ["name": "x", "value": ""]]),
            ("secret/method", [:]),
        ] as [(String, JSONObject)] {
            let response = try await client.request(method, params)
            #expect(response.code == -32603, "\(method): \(response)")
            let text = response.description
            #expect(!text.contains(IndependentProtocolSecretFailure.secret), "\(method) leaked: \(text)")
            #expect(!text.contains("10.0.0.1") && !text.contains("IndependentProtocolSecretFailure"), "\(method) leaked: \(text)")
        }
        // An `MCPError` thrown by a handler is the handler's own answer: passed through as is.
        let own = try await client.request("tools/call", ["name": "protocol_error"])
        #expect(own.code == 4242)
        #expect(own["error"]?["message"] == "application failure")
        #expect(own["error"]?["data"] == ["detail": [1, 2, 3]])
    }
}
