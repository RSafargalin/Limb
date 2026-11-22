import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var text: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
    var readText: String? { self["result"]?["contents"]?[0]?["text"]?.stringValue }
}

private func initializeFrame(_ revision: IndependentProtocolRevision) -> String {
    #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"\#(revision.rawValue)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
}

@Suite struct IndependentProtocolSecondPassTests {
    // MARK: Notifications

    /// Everything here has a string `method` and no `id`: a notification, well-formed or not.
    private static let notifications: [String] = [
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"nobody"}}"#,
        // `params` of every wrong JSON type.
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":[]}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":[{"requestId":1}]}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":"1"}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":""}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":1}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":0}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":-1.5e3}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":true}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":false}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":null}"#,
        // An object, but not what the notification defines.
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":{"n":1}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":[1]}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":true}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestID":1}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":"half"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":"not an object"}}"#,
        // Request methods sent without an id, with good and bad parameters.
        #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"plain"}}"#,
        #"{"jsonrpc":"2.0","method":"tools/call","params":["plain"]}"#,
        #"{"jsonrpc":"2.0","method":"tools/call","params":"plain"}"#,
        #"{"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"emergency"}}"#,
        #"{"jsonrpc":"2.0","method":"logging/setLevel","params":"emergency"}"#,
        #"{"jsonrpc":"2.0","method":"initialize","params":[]}"#,
        #"{"jsonrpc":"2.0","method":"ping","params":null}"#,
        #"{"jsonrpc":"2.0","method":"","params":[]}"#,
        #"{"jsonrpc":"2.0","method":"no/such/thing","params":7}"#,
        // Carrying modern metadata, valid and not.
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"nobody",\#(IndependentProtocol.modernMetaText)}}"#,
        #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"plain",\#(IndependentProtocol.modernMetaText)}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/x","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/x","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":7}}}"#,
        // Members a notification does not have, next to those it has.
        #"{"jsonrpc":"2.0","method":"notifications/x","result":{}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/x","error":{"code":-1,"message":"m"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/x","params":[],"result":{},"extra":[1]}"#,
        #"{"params":[1],"method":"notifications/x","jsonrpc":"2.0"}"#,
    ]

    /// "The receiver MUST NOT send a response" — alone, on a connection of every kind.
    @Test(arguments: notifications)
    func noNotificationIsAnsweredOnAnyConnection(_ frame: String) async throws {
        let recorder = IndependentProtocolRecorder()
        let server = try IndependentProtocolRich.server(recorder: recorder)
        var peers = [IndependentProtocolRawPeer(server)]
        for revision in IndependentProtocolRevision.legacy {
            let peer = IndependentProtocolRawPeer(server)
            try #require(peer.send(initializeFrame(revision)).count == 1)
            peers.append(peer)
        }
        for peer in peers {
            #expect(peer.send(frame).isEmpty, "answered")
            #expect(peer.send(frame).isEmpty, "answered the second time")
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.entries.isEmpty, "a notification ran a handler: \(recorder.entries)")
        // No state changed: each session still speaks its revision at its default log level.
        for (peer, revision) in zip(peers.dropFirst(), IndependentProtocolRevision.legacy) {
            let listing = try #require(peer.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).first)
            #expect(listing.contains(#""icons""#) == revision.isAtLeast(.r2025_11_25), "\(revision.rawValue)")
            // The oracle for the log level is a session that never saw the notification.
            let untouched = IndependentProtocolRawPeer(server)
            try #require(untouched.send(initializeFrame(revision)).count == 1)
            let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"log_all"}}"#
            let expected = await untouched.send(call, untilResponseTo: "2")
            let frames = await peer.send(call, untilResponseTo: "2")
            #expect(frames == expected, "the log level moved: \(frames.count) frames instead of \(expected.count)")
        }
        recorder.clear()
        #expect(peers[0].send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#).first?.contains("-32602") == true, "a session appeared")
    }

    /// In a `2025-03-26` batch: the requests around a notification are answered, the notification
    /// is not, and a batch of nothing but such messages gets no reply at all (JSON-RPC 2.0 §6).
    /// The replies come in the order of the requests — JSON-RPC allows any order, Limb keeps it.
    @Test(arguments: notifications)
    func noNotificationIsAnsweredInsideABatch(_ notification: String) async throws {
        let recorder = IndependentProtocolRecorder()
        let peer = IndependentProtocolRawPeer(try IndependentProtocolRich.server(recorder: recorder))
        try #require(peer.send(initializeFrame(.r2025_03_26)).count == 1)
        for count in 1...3 {
            #expect(peer.send("[" + Array(repeating: notification, count: count).joined(separator: ",") + "]").isEmpty, "\(count) of them")
        }
        #expect(peer.send(#"[\#(notification),{"jsonrpc":"2.0","id":77,"result":{}},\#(notification)]"#).isEmpty)

        func request(_ id: String, _ method: String, _ params: String = "{}") -> String {
            #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        }
        let batches: [(String, [String])] = [
            ("[\(notification),\(request("1", "ping"))]", ["1"]),
            ("[\(request("1", "ping")),\(notification)]", ["1"]),
            ("[\(request(#""a""#, "ping")),\(notification),\(request("2", "no/such/method")),\(notification),\(request("3", "tools/list"))]", [#""a""#, "2", "3"]),
            ("[\(notification),\(notification),\(request("9", "tools/call", "{}")),\(request("8", "ping")),\(notification)]", ["9", "8"]),
            ("[\(request("5", "ping")),42,\(notification),\(request("6", "ping"))]", ["5", "null", "6"]),
        ]
        for (batch, expected) in batches {
            let frames = peer.send(batch)
            try #require(frames.count == 1, "\(batch) → \(frames)")
            let reply = try #require(try JSONSerialization.jsonObject(with: Data(frames[0].utf8)) as? [[String: Any]], "\(frames[0])")
            let ids = reply.map { element -> String in
                switch element["id"] {
                case let text as String: #""\#(text)""#
                case let number as NSNumber: number.stringValue
                default: "null"
                }
            }
            #expect(ids == expected, "\(batch) → \(frames[0])")
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
    }

    // MARK: Batch members that state another revision (fix 12)

    /// A `2026-07-28` request inside a `2025-03-26` batch is refused under its own id; its
    /// neighbours of the session's revision are served; notifications and responses that carry
    /// modern metadata are, as ever, not answered.
    @Test func modernMembersOfABatch() async throws {
        let recorder = IndependentProtocolRecorder()
        let server = try IndependentProtocolRich.server(recorder: recorder)
        try server.register(method: "acme/custom") { _, _ in
            recorder.note("custom")
            return ["v": 1]
        }
        let client = try await IndependentProtocol.client(server, .r2025_03_26)
        let meta = IndependentProtocol.modernMetaText
        client.send(
            """
            [{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"plain",\(meta)}},\
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"plain"}},\
            {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"nobody",\(meta)}},\
            {"jsonrpc":"2.0","id":3,"method":"server/discover","params":{\(meta)}},\
            {"jsonrpc":"2.0","id":4,"method":"tools/list","params":{\(meta)}},\
            {"jsonrpc":"2.0","id":55,"result":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}},\
            {"jsonrpc":"2.0","id":5,"method":"acme/custom","params":{\(meta)}},\
            {"jsonrpc":"2.0","id":6,"method":"ping","params":{\(meta)}},\
            {"jsonrpc":"2.0","id":7,"method":"no/such/method","params":{\(meta)}},\
            {"jsonrpc":"2.0","id":8,"method":"ping"}]
            """)
        let responses = try #require(try await client.next().arrayValue)
        #expect(responses.map { $0["id"] } == [1, 2, 3, 4, 5, 6, 7, 8], "\(responses)")
        for id in [1, 3, 4, 5, 6, 7] {
            let response = responses.first { $0["id"] == JSONValue(id) }
            #expect(response?.code == -32600, "member \(id): \(response ?? .null)")
            #expect(response?["result"] == nil)
        }
        #expect(responses.first { $0["id"] == 2 }?.text == "plain result")
        #expect(responses.first { $0["id"] == 8 }?["result"] == [:])
        #expect(recorder.entries == ["plain"], "\(recorder.entries)")
        #expect(try await IndependentProtocol.drain(client).isEmpty)

        // A batch made only of modern notifications and responses: no reply.
        let silent = try await IndependentProtocol.exchange(
            client,
            #"[{"jsonrpc":"2.0","method":"notifications/x","params":{\#(meta)}},{"jsonrpc":"2.0","id":9,"result":{}},{"jsonrpc":"2.0","method":"tools/call","params":{"name":"plain",\#(meta)}}]"#)
        #expect(silent.isEmpty, "\(silent)")
        // A member whose metadata is unusable is refused too, one way or another, under its id.
        for badMeta in [#"{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}"#, #"{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}"#, #"{"io.modelcontextprotocol/protocolVersion":7}"#] {
            let reply = try #require(try await IndependentProtocol.reply(client, #"[{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"plain","_meta":\#(badMeta)}}]"#).arrayValue)
            #expect(reply.count == 1 && reply[0]["id"] == 10 && [-32600, -32602, -32022].contains(reply[0].code ?? 0), "\(reply)")
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.entries == ["plain"], "\(recorder.entries)")
        // Outside a batch the same connection still serves both eras.
        #expect(try await client.request("tools/call", ["name": "plain"], meta: IndependentProtocol.modernMeta).text == "plain result")
        #expect(try await client.request("tools/call", ["name": "plain"]).text == "plain result")
    }

    // MARK: The capability gate (fix 6)

    private struct Registered: OptionSet, Sendable, CustomTestStringConvertible {
        let rawValue: Int
        static let tool = Registered(rawValue: 1)
        static let resource = Registered(rawValue: 2)
        static let template = Registered(rawValue: 4)
        static let templateCompletion = Registered(rawValue: 8)
        static let prompt = Registered(rawValue: 16)
        static let promptCompletion = Registered(rawValue: 32)
        var testDescription: String {
            let names = ["tool", "resource", "template", "template+completion", "prompt", "prompt+completion"]
            let present = names.enumerated().filter { rawValue & (1 << $0.offset) != 0 }.map(\.element)
            return present.isEmpty ? "nothing" : present.joined(separator: ", ")
        }
    }

    private static func server(with registered: Registered) throws -> Server {
        let server = Server(name: "gate", version: "1")
        if registered.contains(.tool) { try server.register(tool: ToolDefinition(name: "t")) { _, _ in .text("t") } }
        if registered.contains(.resource) {
            try server.register(resource: ResourceDefinition(uri: "g://fixed", name: "f")) { request, _ in [.text(uri: request.uri, text: "f")] }
        }
        if registered.contains(.template) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "g://plain/{x}", name: "p")) { request, _ in [.text(uri: request.uri, text: "p")] }
        }
        if registered.contains(.templateCompletion) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "g://completing/{x}", name: "c"), complete: { _, _ in CompletionResult(values: ["v"]) }) { request, _ in
                [.text(uri: request.uri, text: "c")]
            }
        }
        if registered.contains(.prompt) { try server.register(prompt: PromptDefinition(name: "plain")) { _, _ in PromptResult(messages: []) } }
        if registered.contains(.promptCompletion) {
            try server.register(prompt: PromptDefinition(name: "completing"), complete: { _, _ in CompletionResult(values: ["v"]) }) { _, _ in PromptResult(messages: []) }
        }
        return server
    }

    /// The methods behind each capability, with parameters that name nothing that exists: what
    /// is asked is only whether the method exists.
    private static let gated: [(capability: String, method: String, params: JSONObject, legacyOnly: Bool)] = [
        ("tools", "tools/list", [:], false), ("tools", "tools/call", ["name": "nobody"], false),
        ("resources", "resources/list", [:], false), ("resources", "resources/templates/list", [:], false),
        ("resources", "resources/read", ["uri": "nowhere://x"], false), ("resources", "resources/subscribe", ["uri": "nowhere://x"], true),
        ("resources", "resources/unsubscribe", ["uri": "nowhere://x"], true),
        ("prompts", "prompts/list", [:], false), ("prompts", "prompts/get", ["name": "nobody"], false),
        ("completions", "completion/complete", ["ref": ["type": "ref/prompt", "name": "nobody"], "argument": ["name": "a", "value": ""]], false),
    ]

    /// For every combination of what is registered and every revision: a method answers -32601
    /// exactly when the capability it belongs to is not in the capabilities the server announces
    /// (`initialize` result or `server/discover`). `MethodNotFoundError`: "one gated behind a
    /// server capability the server did not advertise".
    @Test(arguments: (0..<64).map { Registered(rawValue: $0) })
    private func methodsExistExactlyWhenTheirCapabilityIsAnnounced(_ registered: Registered) async throws {
        let server = try Self.server(with: registered)
        for revision in IndependentProtocolRevision.allCases {
            let client: TestClient
            let capabilities: JSONValue
            if revision.isModern {
                client = TestClient(server)
                capabilities = try #require(try await client.request("server/discover")["result"]?["capabilities"])
            } else {
                client = TestClient(server, modern: false)
                capabilities = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"])
            }
            // What must be announced follows from what is registered.
            #expect((capabilities["tools"] != nil) == registered.contains(.tool))
            #expect((capabilities["resources"] != nil) == !registered.isDisjoint(with: [.resource, .template, .templateCompletion]))
            #expect((capabilities["prompts"] != nil) == !registered.isDisjoint(with: [.prompt, .promptCompletion]))
            #expect((capabilities["completions"] != nil) == !registered.isDisjoint(with: [.templateCompletion, .promptCompletion]))
            for (capability, method, params, legacyOnly) in Self.gated {
                let response = try await client.request(method, params)
                let exists = capabilities[capability] != nil && !(legacyOnly && revision.isModern)
                #expect((response.code != -32601) == exists, "\(revision.rawValue) \(method) with capabilities \(capabilities): \(response)")
            }
        }
    }

    /// `2026-07-28` is stateless: what a request gets follows the registry at that moment, and
    /// agrees with what `server/discover` says at that moment.
    @Test func theModernGateFollowsTheRegistry() async throws {
        let server = Server(name: "gate", version: "1")
        let client = TestClient(server)
        func announced() async throws -> Bool { try await client.request("server/discover")["result"]?["capabilities"]?["tools"] != nil }
        #expect(try await !announced())
        #expect(try await client.request("tools/list").code == -32601)
        try server.register(tool: ToolDefinition(name: "first")) { _, _ in .text("first") }
        #expect(try await announced())
        #expect(try await client.request("tools/list")["result"]?["tools"]?.arrayValue?.count == 1)
        #expect(try await client.request("tools/call", ["name": "first"]).text == "first")
        #expect(try await client.request("tools/call", ["name": "nobody"]).code == -32602)
        server.removeTool(named: "first")
        #expect(try await !announced())
        #expect(try await client.request("tools/list").code == -32601)
        #expect(try await client.request("tools/call", ["name": "first"]).code == -32601)
    }

    /// A handshake session negotiated its capabilities once: "Both parties MUST … only use
    /// capabilities that were successfully negotiated" (`2025-11-25/basic/lifecycle.mdx`,
    /// "Operation"). A server that announced `tools` with `listChanged: true` and then removes
    /// its last tool tells the client so with `notifications/tools/list_changed`; the client's
    /// answer to that is `tools/list`, and the answer to *that* is the list as it now is — empty —
    /// not "method not found" for a capability this session holds. The same for prompts and resources.
    @Test(arguments: IndependentProtocolRevision.legacy)
    func aNegotiatedCapabilityOutlivesItsLastItem(_ revision: IndependentProtocolRevision) async throws {
        let server = try Self.server(with: [.tool, .resource, .prompt])
        let client = TestClient(server, modern: false)
        let capabilities = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"])
        #expect(capabilities["tools"]?["listChanged"] == true && capabilities["prompts"]?["listChanged"] == true && capabilities["resources"]?["listChanged"] == true)
        _ = try await IndependentProtocol.drain(client)

        server.removeTool(named: "t")
        #expect(try await IndependentProtocol.drain(client).map { $0["method"] } == ["notifications/tools/list_changed"])
        let tools = try await client.request("tools/list")
        #expect(tools["result"]?["tools"] == [], "after list_changed, tools/list says: \(tools)")
        // A call to the tool that is gone is a call to an unknown tool, as it was before the last one went.
        #expect(try await client.request("tools/call", ["name": "t"]).code == -32602)

        server.removePrompt(named: "plain")
        #expect(try await IndependentProtocol.drain(client).map { $0["method"] } == ["notifications/prompts/list_changed"])
        let prompts = try await client.request("prompts/list")
        #expect(prompts["result"]?["prompts"] == [], "after list_changed, prompts/list says: \(prompts)")

        server.removeResource(uri: "g://fixed")
        #expect(try await IndependentProtocol.drain(client).map { $0["method"] } == ["notifications/resources/list_changed"])
        let resources = try await client.request("resources/list")
        #expect(resources["result"]?["resources"] == [], "after list_changed, resources/list says: \(resources)")
        #expect(try await client.request("resources/read", ["uri": "g://fixed"]).code == -32002)
        #expect(try await client.request("resources/subscribe", ["uri": "g://fixed"])["result"] == [:])

        // And it works again when something is registered again.
        try server.register(tool: ToolDefinition(name: "again")) { _, _ in .text("again") }
        #expect(try await IndependentProtocol.drain(client).map { $0["method"] } == ["notifications/tools/list_changed"])
        #expect(try await client.request("tools/list")["result"]?["tools"]?.arrayValue?.count == 1)
    }

    /// The other direction: a session opened while the server had no tools. If the server tells
    /// such a session that the tool list changed, the list it points to has to be there.
    /// (Whether it should tell a session that never negotiated `tools` at all is not pinned here.)
    @Test(arguments: IndependentProtocolRevision.legacy)
    func whatListChangedAnnouncesCanBeListed(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "late", version: "1")
        let client = TestClient(server, modern: false)
        let capabilities = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"])
        #expect(capabilities["tools"] == nil && capabilities["prompts"] == nil && capabilities["resources"] == nil)
        #expect(try await client.request("tools/list").code == -32601)

        try server.register(tool: ToolDefinition(name: "late")) { _, _ in .text("late") }
        try server.register(prompt: PromptDefinition(name: "late")) { _, _ in PromptResult(messages: []) }
        try server.register(resource: ResourceDefinition(uri: "late://r", name: "late")) { request, _ in [.text(uri: request.uri, text: "late")] }
        let announced = Set(try await IndependentProtocol.drain(client).compactMap { $0["method"]?.stringValue })
        if announced.contains("notifications/tools/list_changed") {
            #expect(try await client.request("tools/list")["result"]?["tools"]?[0]?["name"] == "late")
            #expect(try await client.request("tools/call", ["name": "late"]).text == "late")
        }
        if announced.contains("notifications/prompts/list_changed") {
            #expect(try await client.request("prompts/list")["result"]?["prompts"]?[0]?["name"] == "late")
        }
        if announced.contains("notifications/resources/list_changed") {
            #expect(try await client.request("resources/list")["result"]?["resources"]?[0]?["uri"] == "late://r")
            #expect(try await client.request("resources/read", ["uri": "late://r"]).readText == "late")
        }
        // A new session on the same connection sees the capabilities as they now are.
        let renewed = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"])
        #expect(renewed["tools"] != nil && renewed["prompts"] != nil && renewed["resources"] != nil)
    }

    // MARK: Cursors (fix 11)

    /// Every short string over the characters a cursor could be confused with, against the only
    /// oracle there is: the set of cursors the server actually hands out for that listing.
    @Test(arguments: [(12, 1), (7, 2), (9, 3), (4, 4), (5, 100)])
    func onlyIssuedCursorsAreAccepted(_ count: Int, _ pageSize: Int) async throws {
        let server = Server(name: "paged", version: "1") { $0.pageSize = pageSize }
        for index in 0..<count {
            try server.register(tool: ToolDefinition(name: "tool_\(index)")) { _, _ in .text("") }
            try server.register(resource: ResourceDefinition(uri: "paged://r/\(index)", name: "r")) { _, _ in [] }
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "paged://t\(index)/{x}", name: "t")) { _, _ in [] }
            try server.register(prompt: PromptDefinition(name: "prompt_\(index)")) { _, _ in PromptResult(messages: []) }
        }
        let peer = IndependentProtocolRawPeer(server)
        let meta = IndependentProtocol.modernMetaText
        func page(_ method: String, cursor: String?) throws -> (served: Bool, next: String?) {
            let cursorMember = try cursor.map { #","cursor":"# + String(decoding: try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed), as: UTF8.self) } ?? ""
            let frames = peer.send(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{\#(meta)\#(cursorMember)}}"#)
            try #require(frames.count == 1)
            let object = try #require(IndependentProtocolRawPeer.foundationObject(frames[0]), "\(frames[0])")
            if let result = object["result"] as? [String: Any] { return (true, result["nextCursor"] as? String) }
            let code = (object["error"] as? [String: Any])?["code"] as? Int
            #expect(code == -32602, "\(method) cursor \(cursor.debugDescription): \(frames[0])")
            return (false, nil)
        }
        let methods = ["tools/list", "resources/list", "resources/templates/list", "prompts/list"]
        var issued: [String: Set<String>] = [:]
        for method in methods {
            var cursor = try page(method, cursor: nil).next
            var pages = 1
            while let current = cursor {
                issued[method, default: []].insert(current)
                cursor = try page(method, cursor: current).next
                pages += 1
                try #require(pages <= count + 1)
            }
            #expect(pages == (count + pageSize - 1) / pageSize, "\(method)")
        }
        // No two listings share a cursor.
        let all = methods.flatMap { Array(issued[$0] ?? []) }
        #expect(Set(all).count == all.count, "\(issued)")

        let alphabet = Array("trmpT0123456789+- .")
        var candidates: [String] = []
        for a in alphabet {
            candidates.append(String(a))
            for b in alphabet {
                candidates.append(String([a, b]))
                for c in alphabet { candidates.append(String([a, b, c])) }
            }
        }
        candidates += all
        for real in all {
            let letter = String(real.prefix(1))
            let digits = String(real.dropFirst())
            let variants: [String] = [
                real + "0", real + " ", " " + real, real + "\n", real + "\u{0}", real.uppercased(), real + ".0", real + "e0",
                letter + "0" + digits, letter + "+" + digits, letter + "-" + digits, letter + " " + digits, real + real,
            ]
            candidates += variants
            #if !FoundationJSON
            candidates.append("\u{FEFF}" + real)
            #endif
        }
        candidates += [
            "", "t9223372036854775807", "t9223372036854775808", "t18446744073709551615", "t18446744073709551616", "t-9223372036854775808",
            "t" + String(repeating: "9", count: 400), "t" + String(repeating: "0", count: 400) + "2", "t٢", "t２", "t²", "t1\u{301}", "ｔ2",
            "t\u{0}2", "T2", "tools2", "t2,t4", "2t",
        ]
        for method in methods {
            let real = issued[method] ?? []
            for candidate in candidates {
                let served = try page(method, cursor: candidate).served
                if served != real.contains(candidate) {
                    Issue.record("\(method) with \(count) items, page size \(pageSize): cursor \(candidate.debugDescription) was \(served ? "accepted" : "refused"); issued: \(real.sorted())")
                }
            }
        }
    }

    /// The registry changes between two pages. The specification promises no consistency across
    /// pages (caching.mdx: "clients may observe duplicates or gaps"); what must hold is that every
    /// answer is a non-empty page or an "expired cursor" error, and that following cursors ends.
    @Test func pagingSurvivesARegistryThatChanges() async throws {
        for pageSize in [1, 2, 3] {
            for script in [[-1], [-1, -1, -1], [1], [1, 1, 1, 1], [-1, 1, -1, 1], [-3], [-5], [-6], [3, -4], [-2, -2, 5]] {
                let server = Server(name: "moving", version: "1") { $0.pageSize = pageSize }
                var names = (0..<6).map { "tool_\($0)" }
                var next = 6
                for name in names { try server.register(tool: ToolDefinition(name: name)) { _, _ in .text("") } }
                let client = TestClient(server)
                var cursor: JSONValue?
                var steps = 0
                var changes = script[...]
                repeat {
                    let response = try await client.request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
                    if let result = response["result"] {
                        let items = try #require(result["tools"]?.arrayValue)
                        #expect(!items.isEmpty && items.count <= pageSize, "page size \(pageSize) script \(script): \(result)")
                        #expect(items.allSatisfy { names.contains($0["name"]?.stringValue ?? "") }, "a tool that is not registered: \(result)")
                        cursor = result["nextCursor"]
                    } else {
                        // Refused: the registry no longer has that position — or has no tools at all.
                        #expect(response.code == (names.isEmpty ? -32601 : -32602), "page size \(pageSize) script \(script): \(response)")
                        cursor = nil
                    }
                    if let change = changes.popFirst() {
                        if change > 0 {
                            for _ in 0..<change {
                                try server.register(tool: ToolDefinition(name: "tool_\(next)")) { _, _ in .text("") }
                                names.append("tool_\(next)")
                                next += 1
                            }
                        } else {
                            for _ in 0..<min(-change, names.count) { server.removeTool(named: names.removeFirst()) }
                        }
                    }
                    steps += 1
                    try #require(steps < 40, "paging does not end: page size \(pageSize) script \(script)")
                } while cursor != nil
                // A fresh walk afterwards sees exactly what is registered.
                var seen: [String] = []
                cursor = nil
                repeat {
                    let response = try await client.request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
                    guard let result = response["result"] else {
                        #expect(names.isEmpty && response.code == -32601, "\(response)")
                        break
                    }
                    seen += result["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
                    cursor = result["nextCursor"]
                } while cursor != nil
                #expect(seen == names, "page size \(pageSize) script \(script)")
            }
        }
    }

    /// Page sizes at the edges of `Int`: no arithmetic on them may trap.
    @Test(arguments: [Int.max, Int.max - 1, 1 << 62, 0, -1, Int.min])
    func extremePageSizesDoNotTrap(_ pageSize: Int) async throws {
        let server = Server(name: "edge", version: "1") { $0.pageSize = pageSize }
        for index in 0..<5 { try server.register(tool: ToolDefinition(name: "tool_\(index)")) { _, _ in .text("") } }
        let client = TestClient(server)
        var names: [String] = []
        var cursor: JSONValue?
        var pages = 0
        repeat {
            let result = try #require(try await client.request("tools/list", cursor.map { ["cursor": $0] } ?? [:])["result"])
            names += result["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
            cursor = result["nextCursor"]
            pages += 1
        } while cursor != nil && pages < 10
        #expect(names == (0..<5).map { "tool_\($0)" })
        for bad in ["t9223372036854775807", "t9223372036854775806", "t4611686018427387904", "t1", "t5"] where pageSize > 5 {
            #expect(try await client.request("tools/list", ["cursor": .string(bad)]).code == -32602, "\(bad)")
        }
    }

    // MARK: Percent-decoding (fix 2)

    /// The rule as stated: a well-formed `%XX` is decoded, anything else stays as written, and if
    /// the decoded bytes are not UTF-8 the whole value stays as written. Written out again here,
    /// independently, with Foundation as the UTF-8 judge.
    private static func expectedDecoding(_ text: String) -> String {
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
                let high = Character(UnicodeScalar(source[index + 1])).hexDigitValue, let low = Character(UnicodeScalar(source[index + 2])).hexDigitValue,
                source[index + 1] < 0x80, source[index + 2] < 0x80
            {
                bytes.append(UInt8(high * 16 + low))
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        // Valid UTF-8 is what survives a repairing decode unchanged. (Not `String(data:encoding:)`:
        // Foundation drops a leading byte order mark.)
        let repaired = String(decoding: bytes, as: UTF8.self)
        return Array(repaired.utf8) == bytes ? repaired : text
    }

    private static func readVariable(_ client: TestClient, template: String, value: String) async throws -> String? {
        let uri = String(template.prefix { $0 != "{" }) + value
        let response = try await client.request("resources/read", ["uri": .string(uri)])
        guard let text = response["result"]?["contents"]?[0]?["text"]?.stringValue else { return nil }
        #expect(response["result"]?["contents"]?[0]?["uri"] == .string(uri))
        return text
    }

    private static func echoServer(_ templates: [String]) throws -> Server {
        let server = Server(name: "echo", version: "1")
        for template in templates {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: template)) { request, _ in
                [.text(uri: request.uri, text: request.variables["v"] ?? "(none)")]
            }
        }
        return server
    }

    /// Hand-picked forms: every malformed escape, and escapes that decode to bytes that are not
    /// UTF-8 — overlong forms, surrogates, code points past U+10FFFF, stray and missing
    /// continuation bytes.
    @Test(arguments: [
        // Well-formed and valid.
        ("%41", "A"), ("%61%62", "ab"), ("a%20b", "a b"), ("%25", "%"), ("%2541", "%41"), ("%252F", "%2F"), ("%25%34%31", "%41"),
        ("%e2%82%ac", "€"), ("%E2%82%AC", "€"), ("%F0%9F%98%80", "😀"), ("%C3%A9", "é"), ("e%CC%81", "e\u{301}"), ("x%EF%BB%BF", "x\u{FEFF}"),
        ("%7F", "\u{7F}"), ("%C2%80", "\u{80}"), ("%F4%8F%BF%BF", "\u{10FFFF}"), ("%EF%BF%BD", "\u{FFFD}"), ("é%C3%A9", "éé"),
        // Malformed escapes: left as written, the well-formed ones around them decoded.
        ("%", "%"), ("%%", "%%"), ("%%%", "%%%"), ("%4", "%4"), ("a%", "a%"), ("a%4", "a%4"), ("%zz", "%zz"), ("%4z", "%4z"), ("%z4", "%z4"),
        ("%G0", "%G0"), ("%0G", "%0G"), ("%+1", "%+1"), ("%-1", "%-1"), ("% 41", "% 41"), ("%0x41", "%0x41"), ("%u0041", "%u0041"),
        ("%41%zz", "A%zz"), ("%zz%41", "%zzA"), ("%%41", "%A"), ("%4%41", "%4A"), ("%41%", "A%"), ("%41%4", "A%4"), ("50%off", "50%off"),
        ("100%25%", "100%%"), ("%٤١", "%٤١"), ("%４１", "%４１"), ("%4１", "%4１"), ("%é", "%é"), ("%4é", "%4é"),
        // Decoded bytes that are not UTF-8: the whole value as written.
        ("%FF", "%FF"), ("%80", "%80"), ("%BF", "%BF"), ("%C3", "%C3"), ("%C3x", "%C3x"), ("%C3%28", "%C3%28"), ("%E2%82", "%E2%82"),
        ("%E2%28%A1", "%E2%28%A1"), ("%F0%9F%98", "%F0%9F%98"), ("a%C3", "a%C3"),
        // Overlong encodings of "/", ".", NUL and "A".
        ("%C0%AF", "%C0%AF"), ("%E0%80%AF", "%E0%80%AF"), ("%F0%80%80%AF", "%F0%80%80%AF"), ("%C0%AE", "%C0%AE"), ("%C0%80", "%C0%80"),
        ("%C1%81", "%C1%81"), ("%E0%9F%BF", "%E0%9F%BF"), ("%F0%8F%BF%BF", "%F0%8F%BF%BF"),
        // Surrogates, alone and as a CESU-8 pair; past U+10FFFF; five- and six-byte forms.
        ("%ED%A0%80", "%ED%A0%80"), ("%ED%BF%BF", "%ED%BF%BF"), ("%ED%A0%BD%ED%B8%80", "%ED%A0%BD%ED%B8%80"), ("%F4%90%80%80", "%F4%90%80%80"),
        ("%F5%80%80%80", "%F5%80%80%80"), ("%F8%88%80%80%80", "%F8%88%80%80%80"), ("%FC%84%80%80%80%80", "%FC%84%80%80%80%80"), ("%FE", "%FE"),
        // One bad byte spoils the value: nothing is half-decoded.
        ("caf%C3%A9%FF", "caf%C3%A9%FF"), ("%41%C0%AF%42", "%41%C0%AF%42"), ("%E2%82%AC%ED%A0%80", "%E2%82%AC%ED%A0%80"),
    ])
    func percentEscapesAreDecodedByTheRule(_ value: String, _ expected: String) async throws {
        try #require(Self.expectedDecoding(value) == expected, "the table disagrees with the rule for \(value)")
        let client = TestClient(try Self.echoServer(["simple://{v}", "reserved://{+v}", "middle://{v}/tail", "two://{other}/{v}"]))
        for template in ["simple://{v}", "reserved://{+v}", "middle://{v}/tail"] {
            let uri = template.replacingOccurrences(of: "{v}", with: value).replacingOccurrences(of: "{+v}", with: value)
            let response = try await client.request("resources/read", ["uri": .string(uri)])
            let seen = response.readText
            #expect(seen.map { Array($0.utf8) } == Array(expected.utf8), "\(uri) → \(seen.debugDescription), expected \(expected.debugDescription)")
        }
        // A "/" that only appears after decoding does not split a segment.
        let two = try await client.request("resources/read", ["uri": .string("two://x/" + value)])
        #expect(two.readText.map { Array($0.utf8) } == Array(expected.utf8))
    }

    #if !FoundationJSON
    @Test func aPercentEncodedByteOrderMarkIsDecoded() async throws {
        let client = TestClient(try Self.echoServer(["simple://{v}"]))
        let seen = try await Self.readVariable(client, template: "simple://{v}", value: "%EF%BB%BFx")
        #expect(seen.map { Array($0.utf8) } == [0xEF, 0xBB, 0xBF, 0x78])
    }
    #endif

    /// Every string of up to four characters from a small alphabet of trouble.
    @Test func percentDecodingAgreesWithTheRuleOnEveryShortString() async throws {
        let client = TestClient(try Self.echoServer(["simple://{v}", "reserved://{+v}"]))
        let alphabet = ["%", "4", "1", "C", "3", "A", "9", "z", "f", "F"]
        var values: [String] = []
        for a in alphabet {
            values.append(a)
            for b in alphabet {
                values.append(a + b)
                for c in alphabet {
                    values.append(a + b + c)
                    for d in alphabet where a == "%" || b == "%" { values.append(a + b + c + d) }
                }
            }
        }
        // Six characters: two escapes side by side, good and bad.
        for first in ["%C3", "%A9", "%41", "%zz", "%4", "%FF", "%E2"] { for second in ["%A9", "%C3", "%41", "%z", "%", "%82", "%28"] { values.append(first + second) } }
        var failures = 0
        for value in values {
            for template in ["simple://{v}", "reserved://{+v}"] {
                let seen = try await Self.readVariable(client, template: template, value: value)
                let expected = Self.expectedDecoding(value)
                if seen.map({ Array($0.utf8) }) != Array(expected.utf8) {
                    failures += 1
                    if failures <= 10 { Issue.record("\(template) with \(value.debugDescription): handler saw \(seen.debugDescription), expected \(expected.debugDescription)") }
                }
            }
        }
        #expect(failures == 0, "\(failures) of \(values.count * 2) values")
    }

    // MARK: Exact strings (fix 9)

    private static let composed = "caf\u{E9}"
    private static let decomposed = "cafe\u{301}"
    /// U+212A KELVIN SIGN is canonically equivalent to the ASCII letter K.
    private static let kelvin = "\u{212A}"

    /// Tool names are ASCII by Limb's own rule, but the name in a request is not: a look-alike
    /// that Swift's `==` equates with an ASCII name must not reach the tool.
    @Test func toolNamesAreMatchedByBytes() async throws {
        let server = Server(name: "exact", version: "1")
        try server.register(tool: ToolDefinition(name: "K")) { _, _ in .text("K") }
        try server.register(tool: ToolDefinition(name: "a.K_b")) { _, _ in .text("a.K_b") }
        let client = TestClient(server)
        #expect(try await client.request("tools/call", ["name": "K"]).text == "K")
        for name in [Self.kelvin, "a.\(Self.kelvin)_b", "K\u{301}", "K\u{FEFF}", "K\u{200B}"] {
            let response = try await client.request("tools/call", ["name": .string(name)])
            #expect(response.code == -32602, "\(name.debugDescription) reached a tool: \(response)")
        }
        #expect(throws: RegistrationError.self) { try server.register(tool: ToolDefinition(name: Self.kelvin)) { _, _ in .text("") } }
    }

    @Test func customMethodNamesAreMatchedByBytes() async throws {
        let server = Server(name: "exact", version: "1")
        try server.register(method: Self.composed + "/run") { _, _ in ["which": "composed"] }
        try server.register(method: "K/run") { _, _ in ["which": "K"] }
        let client = TestClient(server)
        #expect(try await client.request(Self.composed + "/run")["result"]?["which"] == "composed")
        #expect(try await client.request("K/run")["result"]?["which"] == "K")
        let other = try await client.request(Self.decomposed + "/run")
        #expect(other.code == -32601, "a method registered with U+00E9 answered to e + U+0301: \(other)")
        let lookalike = try await client.request(Self.kelvin + "/run")
        #expect(lookalike.code == -32601, "a method registered as K answered to U+212A: \(lookalike)")
        // The other spellings are names of their own: registering them replaces nothing.
        try server.register(method: Self.decomposed + "/run") { _, _ in ["which": "decomposed"] }
        try server.register(method: Self.kelvin + "/run") { _, _ in ["which": "kelvin"] }
        #expect(try await client.request(Self.composed + "/run")["result"]?["which"] == "composed", "the first registration was replaced")
        #expect(try await client.request(Self.decomposed + "/run")["result"]?["which"] == "decomposed")
        #expect(try await client.request("K/run")["result"]?["which"] == "K", "the first registration was replaced")
        #expect(try await client.request(Self.kelvin + "/run")["result"]?["which"] == "kelvin")
    }

    /// A URI template is matched against the URI as written: its literal parts by their bytes,
    /// "/" wherever the byte occurs.
    @Test func templatesAreMatchedByBytes() async throws {
        let server = Server(name: "exact", version: "1")
        let read: ResourceReader = { request, _ in
            [.text(uri: request.uri, text: request.variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))]
        }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "u://\(Self.composed)/{id}", name: "literal"), read: read)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "seg://items/{id}", name: "segment"), read: read)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "K://{id}", name: "kelvin"), read: read)
        let client = TestClient(server)
        #expect(try await client.request("resources/read", ["uri": .string("u://\(Self.composed)/7")]).readText == "id=7")

        // The literal part in the other normalization is a different literal.
        let other = try await client.request("resources/read", ["uri": .string("u://\(Self.decomposed)/7")])
        #expect(other.code == -32602, "a template with U+00E9 matched e + U+0301: \(other)")
        let lookalike = try await client.request("resources/read", ["uri": .string("\(Self.kelvin)://7")])
        #expect(lookalike.code == -32602, "a template with K matched U+212A: \(lookalike)")

        // A value that begins with a combining mark is still a value after the literal "…/".
        let combining = try await client.request("resources/read", ["uri": "seg://items/\u{301}abc"])
        #expect(combining.readText.map { Array($0.utf8) } == Array("id=\u{301}abc".utf8), "\(combining)")
        // A "/" followed by a combining mark is still a "/": `{id}` is one segment.
        let smuggled = try await client.request("resources/read", ["uri": "seg://items/a/\u{301}b"])
        #expect(smuggled.code == -32602, "{id} spanned a slash: \(smuggled)")

        // Two templates that differ only in normalization are two templates.
        #expect(throws: Never.self) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "u://\(Self.decomposed)/{id}", name: "literal 2"), read: read)
        }
        let listed = try await client.request("resources/templates/list")["result"]?["resourceTemplates"]?.arrayValue?.count
        #expect(listed == 4)
    }

    /// RFC 6570 §2.3: `varchar = ALPHA / DIGIT / "_" / pct-encoded` — ASCII. Limb implements
    /// "simple {name} and reserved {+name} expressions"; a name outside that alphabet is not such
    /// an expression, and standard template libraries on the client side cannot expand it.
    @Test func templateVariableNamesAreASCII() throws {
        for name in ["é", "名前", "x²", "٣", "ｘ", "x\u{301}", "ñandú", "α", "Ⅷ"] {
            let server = Server(name: "names", version: "1")
            #expect(throws: RegistrationError.self, "{\(name)} was accepted as a variable name") {
                try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "t://{\(name)}", name: "x")) { _, _ in [] }
            }
        }
    }

    /// Prompt arguments are a JSON object: its member names are distinct when their bytes are.
    /// A required argument is present only under its own name.
    @Test func promptArgumentNamesAreMatchedByBytes() async throws {
        let seen = IndependentProtocolRecorder()
        let server = Server(name: "exact", version: "1")
        try server.register(prompt: PromptDefinition(name: "p", arguments: [PromptArgument(name: Self.composed, required: true)])) { arguments, _ in
            seen.note("\(arguments.count)")
            return PromptResult(messages: [.user(arguments[Self.composed] ?? "(absent)")])
        }
        try server.register(prompt: PromptDefinition(name: "k", arguments: [PromptArgument(name: "K", required: true)])) { arguments, _ in
            PromptResult(messages: [.user(arguments["K"] ?? "(absent)")])
        }
        let client = TestClient(server)
        let right = try await client.request("prompts/get", ["name": "p", "arguments": [Self.composed: "yes"]])
        #expect(right["result"]?["messages"]?[0]?["content"]?["text"] == "yes")

        let wrong = try await client.request("prompts/get", ["name": "p", "arguments": [Self.decomposed: "no"]])
        #expect(wrong.code == -32602, "the required argument was taken as present under another spelling: \(wrong)")
        let lookalike = try await client.request("prompts/get", ["name": "k", "arguments": [Self.kelvin: "no"]])
        #expect(lookalike.code == -32602, "the required argument K was taken as present under U+212A: \(lookalike)")

        // Both spellings in one request are two arguments; the declared one keeps its own value.
        client.send(#"{"jsonrpc":"2.0","id":"both","method":"prompts/get","params":{\#(IndependentProtocol.modernMetaText),"name":"p","arguments":{"caf\u00e9":"declared","cafe\u0301":"other"}}}"#)
        let both = try await client.response(to: "both")
        #expect(both["result"]?["messages"]?[0]?["content"]?["text"] == "declared", "\(both)")
        client.send(#"{"jsonrpc":"2.0","id":"both2","method":"prompts/get","params":{\#(IndependentProtocol.modernMetaText),"name":"p","arguments":{"cafe\u0301":"other","caf\u00e9":"declared"}}}"#)
        let reversed = try await client.response(to: "both2")
        #expect(reversed["result"]?["messages"]?[0]?["content"]?["text"] == "declared", "\(reversed)")
    }

    /// Request ids are compared the same way: two ids that differ in bytes are two requests, and
    /// a cancellation names exactly one of them.
    @Test func requestIdsAreMatchedByBytes() async throws {
        let gate = Gate()
        let started = Counter()
        let client = TestClient(try makeServer(gate: gate, started: started))
        let first = client.post("tools/call", ["name": "wait"], id: RequestID(Self.composed))
        let second = client.post("tools/call", ["name": "wait"], id: RequestID(Self.decomposed))
        let third = client.post("tools/call", ["name": "wait"], id: "K")
        let fourth = client.post("tools/call", ["name": "wait"], id: RequestID(Self.kelvin))
        let early = try await IndependentProtocol.drain(client)
        #expect(early.allSatisfy { $0["error"] == nil }, "an id was taken for another: \(early)")
        // Cancel the second and the fourth; the first and the third are different requests.
        client.notify("notifications/cancelled", ["requestId": .string(Self.decomposed)])
        client.notify("notifications/cancelled", ["requestId": .string(Self.kelvin)])
        gate.open()
        // Two answers are due. (While ids are confused this waits out its timeout: the answers never come.)
        let answers = await IndependentProtocol.responses(client, to: [first, third], timeout: .seconds(5))
        #expect(answers[first]?.text == "released", "the request with U+00E9 was cancelled under the other spelling: \(answers[first] ?? .null)")
        #expect(answers[third]?.text == "released", "the request K was cancelled as U+212A: \(answers[third] ?? .null)")
        _ = (second, fourth)
        #expect(started.count == 4, "\(started.count) of 4 requests ran")
    }

    // MARK: A custom result and the members the server adds (fix 4)

    /// Whatever a custom handler puts in its result, every frame is one JSON object without
    /// repeated member names, in both eras.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func customResultsNeverRepeatAMember(_ revision: IndependentProtocolRevision) async throws {
        let server = try IndependentProtocolRich.server()
        let results: [(String, JSONObject)] = [
            ("plain", ["v": 1]), ("typed", ["resultType": "complete", "v": 1]), ("extension", ["v": 1, "resultType": "com.example/partial"]),
            ("number", ["resultType": 5]), ("null", ["resultType": nil]), ("object", ["resultType": ["a": 1]]), ("empty", ["resultType": ""]),
            ("meta", ["_meta": ["a": 1], "v": 1]), ("metaString", ["_meta": "text"]), ("metaInfo", ["_meta": ["io.modelcontextprotocol/serverInfo": ["name": "impostor", "version": "0"]]]),
            ("cache", ["ttlMs": 5, "cacheScope": "public"]), ("everything", ["resultType": "x", "_meta": ["k": "v"], "ttlMs": 1, "cacheScope": "private", "jsonrpc": "1.0", "id": 9, "result": [:], "error": nil]),
        ]
        for (name, result) in results { try server.register(method: "acme/\(name)") { _, _ in result } }
        let peer = IndependentProtocolRawPeer(server)
        var meta = ""
        if revision.isModern { meta = IndependentProtocol.modernMetaText } else { try #require(peer.send(initializeFrame(revision)).count == 1) }
        for (name, returned) in results {
            let frames = await peer.send(#"{"jsonrpc":"2.0","id":1,"method":"acme/\#(name)","params":{\#(meta)}}"#, awaiting: 1)
            let frame = try #require(frames.first)
            #expect(IndependentProtocolRawPeer.duplicateMembers(in: frame).isEmpty, "\(revision.rawValue) acme/\(name): repeated \(IndependentProtocolRawPeer.duplicateMembers(in: frame)) in \(frame)")
            let object = try #require(IndependentProtocolRawPeer.foundationObject(frame), "\(frame)")
            #expect(Set(object.keys) == ["jsonrpc", "id", "result"], "\(frame)")
            let result = try #require(object["result"] as? [String: Any], "\(frame)")
            if revision.isModern {
                // `resultType: string` is required of every result; a handler's own string is kept.
                let type = result["resultType"] as? String
                #expect(type != nil, "\(frame)")
                if let own = returned["resultType"]?.stringValue { #expect(type == own, "\(frame)") }
                let info = (result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any]
                #expect(info?["name"] as? String == "rich", "\(frame)")
            } else {
                #expect(result["_meta"] as? [String: Any] == nil || returned["_meta"]?.objectValue != nil, "\(frame)")
            }
            #expect(result["v"] as? Int == returned["v"]?.intValue)
        }
        // The same scan over everything the typed API produces.
        for (index, (method, params)) in IndependentProtocolRich.calls.enumerated() {
            var body = JSONValue.object(params).description
            if !meta.isEmpty { body = "{" + meta + (params.isEmpty ? "" : ",") + body.dropFirst() }
            let frames = await peer.send(#"{"jsonrpc":"2.0","id":\#(index),"method":"\#(method)","params":\#(body)}"#, awaiting: 1)
            let frame = try #require(frames.first)
            #expect(IndependentProtocolRawPeer.duplicateMembers(in: frame).isEmpty, "\(method): \(frame)")
        }
    }

    // MARK: Output schemas (fix 3)

    /// The older revisions get an output schema only in the form they define (`type: "object"`),
    /// and whatever they are shown is honoured; `2026-07-28` gets every schema.
    @Test(arguments: [IndependentProtocolRevision.r2025_06_18, .r2025_11_25, .r2026_07_28])
    func outputSchemasPerRevision(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "outputs", version: "1") { $0.diagnostics = { _ in } }
        let tools: [(String, JSONObject, JSONValue, Bool)] = [
            ("object", ["type": "object"], ["k": "v"], true),
            ("object_with_more", ["type": "object", "properties": ["k": ["type": "string"]], "required": ["k"], "$schema": "https://json-schema.org/draft/2020-12/schema"], ["k": "v"], true),
            ("nullable_object", ["type": ["object", "null"]], ["k": "v"], false), ("nullable_object_null", ["type": ["object", "null"]], nil, false),
            ("object_in_list", ["type": ["object"]], ["k": "v"], false), ("array", ["type": "array"], [1], false),
            ("untyped", ["properties": ["k": ["type": "string"]]], ["k": "v"], false), ("any", [:], true, false),
            ("ref", ["$ref": "#/$defs/o", "$defs": ["o": ["type": "object"]]], ["k": "v"], false),
        ]
        for (name, schema, value, _) in tools {
            try server.register(tool: ToolDefinition(name: name, outputSchema: schema)) { _, _ in .structured(value) }
        }
        let client = try await IndependentProtocol.client(server, revision)
        let listing = try await client.request("tools/list")
        let violations = IndependentProtocol.responseViolations(listing, to: "tools/list", in: revision)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        let listed = try #require(listing["result"]?["tools"]?.arrayValue)
        for (index, (name, schema, value, legacyForm)) in tools.enumerated() {
            let advertised = listed[index]["outputSchema"]
            #expect((advertised != nil) == (revision.isModern || legacyForm), "\(revision.rawValue) \(name)")
            if let advertised { #expect(advertised == .object(schema), "\(name): the schema was altered") }
            let response = try await client.request("tools/call", ["name": .string(name)])
            let result = try #require(response["result"], "\(name): \(response)")
            #expect(IndependentProtocol.responseViolations(response, to: "tools/call", in: revision).isEmpty, "\(name): \(response)")
            if advertised != nil { #expect(result["structuredContent"] == value, "\(revision.rawValue) \(name): \(result)") }
            let text = try #require(result["content"]?[0]?["text"]?.stringValue)
            #expect(try JSON.parse(Array(text.utf8)) == value, "\(name)")
        }
    }
}
