import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var text: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}

private let allVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

@Suite struct IndependentProtocolEraTests {
    // MARK: Handshake negotiation (legacy)

    @Test(arguments: [
        ("2025-03-26", "2025-03-26"), ("2025-06-18", "2025-06-18"), ("2025-11-25", "2025-11-25"),
        // Older than anything supported, newer than anything supported, the modern revision.
        ("2024-11-05", "2025-11-25"), ("2024-10-07", "2025-11-25"), ("1900-01-01", "2025-11-25"), ("2099-12-31", "2025-11-25"),
        ("2026-07-28", "2025-11-25"), ("2025-11-26", "2025-11-25"), ("2025-06-17", "2025-11-25"),
        // Malformed strings are just versions the server does not support.
        ("", "2025-11-25"), (" ", "2025-11-25"), ("latest", "2025-11-25"), ("2025-11-25 ", "2025-11-25"), (" 2025-11-25", "2025-11-25"),
        ("2025-11-25\n", "2025-11-25"), ("2025-6-18", "2025-11-25"), ("20250618", "2025-11-25"), ("2025/06/18", "2025-11-25"),
        ("2025-06-18T00:00:00Z", "2025-11-25"), ("v2025-06-18", "2025-11-25"), ("DRAFT-2026-v1", "2025-11-25"), ("２０２５-06-18", "2025-11-25"),
        ("2025-03-26\u{0}", "2025-11-25"),
    ])
    func initializeNegotiatesTheVersion(_ requested: String, _ expected: String) async throws {
        let client = TestClient(try IndependentProtocolRich.server(), modern: false)
        let response = try await client.initialize(version: ProtocolVersion(rawValue: requested))
        #expect(response["result"]?["protocolVersion"]?.stringValue == expected, "\(response)")
        // The session then really speaks the version it announced.
        let revision = try #require(IndependentProtocolRevision(rawValue: expected))
        let list = try await client.request("tools/list")
        let violations = IndependentProtocol.responseViolations(list, to: "tools/list", in: revision)
        #expect(violations.isEmpty, "\(violations)")
        #expect((list["result"]?["tools"]?[0]?["title"] != nil) == revision.isAtLeast(.r2025_06_18))
        #expect((list["result"]?["tools"]?[0]?["icons"] != nil) == revision.isAtLeast(.r2025_11_25))
        #expect(list["result"]?["resultType"] == nil)
    }

    /// `protocolVersion` is a required string of `InitializeRequest`: without one there is nothing
    /// to negotiate, and a failed handshake leaves no session behind.
    @Test(arguments: [
        #"{}"#, #"{"capabilities":{},"clientInfo":{"name":"c","version":"1"}}"#, #"{"protocolVersion":null,"capabilities":{}}"#,
        #"{"protocolVersion":20251125,"capabilities":{}}"#, #"{"protocolVersion":true,"capabilities":{}}"#,
        #"{"protocolVersion":["2025-11-25"],"capabilities":{}}"#, #"{"protocolVersion":{"version":"2025-11-25"},"capabilities":{}}"#,
        #"{"ProtocolVersion":"2025-11-25","capabilities":{}}"#,
    ])
    func initializeWithoutAUsableVersionIsRejected(_ params: String) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = TestClient(try IndependentProtocolRich.server(recorder: recorder), modern: false)
        let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":\#(params)}"#)
        #expect(reply.code == -32602, "\(reply)")
        #expect(reply["id"] == 1)
        // No session: a bare request is still a request that does not state its version.
        let next = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"plain"}}"#)
        #expect(next.code == -32602, "\(next)")
        #expect(recorder.entries.isEmpty)
    }

    /// Negotiation uses the configured set, whatever its order.
    @Test func initializeNegotiatesWithinTheConfiguredVersions() async throws {
        let cases: [(configured: [ProtocolVersion], requested: String, expected: String)] = [
            ([.v2026_07_28, .v2025_06_18, .v2025_03_26], "2025-11-25", "2025-06-18"),
            ([.v2026_07_28, .v2025_06_18, .v2025_03_26], "2025-03-26", "2025-03-26"),
            ([.v2026_07_28, .v2025_06_18, .v2025_03_26], "2025-06-18", "2025-06-18"),
            ([.v2026_07_28, .v2025_06_18, .v2025_03_26], "2026-07-28", "2025-06-18"),
            ([.v2025_03_26, .v2025_06_18], "2099-01-01", "2025-06-18"),
            ([.v2025_06_18, .v2025_03_26], "2099-01-01", "2025-06-18"),
            ([.v2025_03_26, .v2025_11_25, .v2025_06_18], "nonsense", "2025-11-25"),
            ([.v2025_03_26], "2025-11-25", "2025-03-26"),
            ([.v2025_03_26, .v2026_07_28], "2025-06-18", "2025-03-26"),
            ([.v2025_11_25], "2025-03-26", "2025-11-25"),
        ]
        for (configured, requested, expected) in cases {
            let client = TestClient(try IndependentProtocolRich.server { $0.supportedVersions = configured }, modern: false)
            let response = try await client.initialize(version: ProtocolVersion(rawValue: requested))
            #expect(response["result"]?["protocolVersion"]?.stringValue == expected, "\(configured) asked \(requested): \(response)")
        }
    }

    /// "A server that supports only modern versions SHOULD name the protocol versions it supports
    /// in any error it returns to an initialize request" (`2026-07-28/basic/versioning.mdx`).
    @Test func modernOnlyServerRejectsTheHandshakeAndSaysWhatItSpeaks() async throws {
        let recorder = IndependentProtocolRecorder()
        let server = try IndependentProtocolRich.server(recorder: recorder) { $0.supportedVersions = [.v2026_07_28] }
        let client = TestClient(server, modern: false)
        for version in ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28", "x"] {
            let response = try await client.initialize(version: ProtocolVersion(rawValue: version))
            #expect(response["result"] == nil, "\(response)")
            #expect(response.code != nil)
            #expect(response["error"]?["message"]?.stringValue?.contains("2026-07-28") == true, "\(response)")
        }
        // Nothing of the handshake era works afterwards, with or without the attempt.
        for (method, params) in [("ping", [:]), ("tools/list", [:]), ("tools/call", ["name": "plain"]), ("logging/setLevel", ["level": "info"])] as [(String, JSONObject)] {
            let response = try await client.request(method, params)
            #expect(response["result"] == nil, "\(method) was served without a version: \(response)")
        }
        #expect(recorder.entries.isEmpty)
        // And the modern era does.
        #expect(try await client.request("tools/call", ["name": "plain"], meta: IndependentProtocol.modernMeta).text == "plain result")
        let discovered = try await client.request("server/discover", meta: IndependentProtocol.modernMeta)
        #expect(discovered["result"]?["supportedVersions"] == ["2026-07-28"])
    }

    // MARK: Before the handshake

    @Test func requestsThatStateNoVersionAreRejectedBeforeAnyHandshake() async throws {
        let recorder = IndependentProtocolRecorder()
        let client = TestClient(try IndependentProtocolRich.server(recorder: recorder), modern: false)
        var calls = IndependentProtocolRich.calls
        calls += [
            ("server/discover", [:]), ("logging/setLevel", ["level": "debug"]), ("resources/subscribe", ["uri": "rich://static"]),
            ("resources/unsubscribe", ["uri": "rich://static"]), ("subscriptions/listen", ["notifications": [:]]), ("no/such/method", [:]),
        ]
        let metas: [JSONObject?] = [
            nil, [:], ["progressToken": 1], ["io.modelcontextprotocol/clientCapabilities": [:]],
            ["io.modelcontextprotocol/clientInfo": ["name": "c", "version": "1"], "io.modelcontextprotocol/logLevel": "debug"],
        ]
        for (method, params) in calls {
            for meta in metas {
                var params = params
                if let meta { params["_meta"] = .object(meta) }
                let response = try await client.request(method, params)
                #expect(response.code == -32602, "\(method) with _meta \(meta.map { JSONValue.object($0).description } ?? "absent"): \(response)")
                #expect(response["error"]?["data"]?["supported"] == .array(allVersions.map(JSONValue.string)), "\(response)")
                let message = response["error"]?["message"]?.stringValue ?? ""
                #expect(allVersions.allSatisfy(message.contains), "\(message)")
            }
        }
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
        #expect(client.received.isEmpty, "\(client.received)")
    }

    @Test func pingBeforeTheHandshakeGetsAnEmptyResult() throws {
        let peer = IndependentProtocolRawPeer(try IndependentProtocolRich.server())
        for frame in [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"progressToken":"p"}}}"#,
        ] {
            let replies = peer.send(frame)
            try #require(replies.count == 1)
            let object = try #require(IndependentProtocolRawPeer.foundationObject(replies[0]))
            #expect((object["result"] as? [String: Any])?.isEmpty == true, "\(replies[0])")
        }
        // The ping created no session.
        #expect(peer.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#).first?.contains("-32602") == true)
    }

    // MARK: Per-request metadata (modern)

    private struct MetaCase: Sendable, CustomTestStringConvertible {
        /// The `_meta` member as JSON text, or `nil` to omit it.
        let meta: String?
        /// Acceptable outcomes: error codes, or `nil` for "served".
        let outcomes: [Int?]
        var testDescription: String { meta ?? "(no _meta)" }
    }

    private static let v = #""io.modelcontextprotocol/protocolVersion""#
    private static let c = #""io.modelcontextprotocol/clientCapabilities""#
    private static let l = #""io.modelcontextprotocol/logLevel""#
    private static let i = #""io.modelcontextprotocol/clientInfo""#

    /// `protocolVersion` (string) and `clientCapabilities` (object) are required, `clientInfo`
    /// and `logLevel` optional (`2026-07-28/basic/index.mdx`, "Per-request protocol fields").
    /// Missing or mistyped required field: -32602. Unsupported version: -32022. Unrecognized
    /// log level: -32602 (`server/utilities/logging.mdx`, "SHOULD reject").
    private static let metaCases: [MetaCase] = [
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{}}"#, outcomes: [nil]),
        MetaCase(meta: #"{\#(c):{},\#(v):"2026-07-28"}"#, outcomes: [nil]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{"roots":{},"sampling":{},"elicitation":{"form":{},"url":{}},"experimental":{"x":{}},"extensions":{"com.example/e":{}},"future":[1]}}"#, outcomes: [nil]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(i):{"name":"c","version":"1","title":"C","description":"d","websiteUrl":"https://e.example","icons":[{"src":"https://e.example/i.png"}],"extra":1}}"#, outcomes: [nil]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},"progressToken":"t","traceparent":"00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01","com.example/x":{"y":1}}"#, outcomes: [nil]),
        // Required field missing or of the wrong type.
        MetaCase(meta: nil, outcomes: [-32602]),
        MetaCase(meta: "{}", outcomes: [-32602]),
        MetaCase(meta: "null", outcomes: [-32602]),
        MetaCase(meta: #""2026-07-28""#, outcomes: [-32602]),
        MetaCase(meta: #"["2026-07-28"]"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(c):{}}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28"}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):null}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):[]}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):"all"}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):true}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):0}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):20260728,\#(c):{}}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):null,\#(c):{}}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):["2026-07-28"],\#(c):{}}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):{"version":"2026-07-28"},\#(c):{}}"#, outcomes: [-32602]),
        MetaCase(meta: #"{"protocolVersion":"2026-07-28","clientCapabilities":{}}"#, outcomes: [-32602]),
        MetaCase(meta: #"{"IO.modelcontextprotocol/protocolVersion":"2026-07-28",\#(c):{}}"#, outcomes: [-32602]),
        // A version the server does not speak.
        MetaCase(meta: #"{\#(v):"1900-01-01",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2099-01-01",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2026-07-29",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2024-11-05",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2026-07-28 ",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):" 2026-07-28",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2026-7-28",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"20260728",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"DRAFT-2026-v1",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"draft",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"latest",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2026-07-28\u0000",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2025-11-25",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2025-06-18",\#(c):{}}"#, outcomes: [-32022]),
        MetaCase(meta: #"{\#(v):"2025-03-26",\#(c):{}}"#, outcomes: [-32022]),
        // Both wrong: either complaint is right.
        MetaCase(meta: #"{\#(v):"2099-01-01"}"#, outcomes: [-32022, -32602]),
        MetaCase(meta: #"{\#(v):"2099-01-01",\#(c):null}"#, outcomes: [-32022, -32602]),
        // Log level.
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):"debug"}"#, outcomes: [nil]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):"emergency"}"#, outcomes: [nil]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):"loud"}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):"DEBUG"}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):"warn"}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):""}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):3}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):null}"#, outcomes: [-32602]),
        MetaCase(meta: #"{\#(v):"2026-07-28",\#(c):{},\#(l):["debug"]}"#, outcomes: [-32602]),
    ]

    @Test(arguments: metaCases)
    private func modernRequestMetadataIsValidatedOnEveryMethod(_ metaCase: MetaCase) async throws {
        let recorder = IndependentProtocolRecorder()
        let server = try IndependentProtocolRich.server(recorder: recorder)
        try server.register(method: "custom/echo") { params, _ in
            recorder.note("custom")
            return ["echo": params["value"] ?? nil]
        }
        let client = TestClient(server, modern: false)
        var calls = IndependentProtocolRich.calls
        calls += [("server/discover", [:]), ("custom/echo", ["value": 1])]
        var number = 0
        for (method, params) in calls {
            number += 1
            var body = JSONValue.object(params).description
            if let meta = metaCase.meta { body = #"{"_meta":\#(meta)"# + (params.isEmpty ? "" : ",") + body.dropFirst() }
            client.send(#"{"jsonrpc":"2.0","id":\#(number),"method":"\#(method)","params":\#(body)}"#)
            let response = try await client.response(to: RequestID(number))
            let outcome = response["result"] != nil ? nil : response.code
            #expect(metaCase.outcomes.contains(outcome), "\(method): \(response)")
            if response["result"] != nil {
                let violations = IndependentProtocol.responseViolations(response, to: method, in: .r2026_07_28)
                if method != "custom/echo" { #expect(violations.isEmpty, "\(method): \(violations)") }
            }
        }
        if !metaCase.outcomes.contains(nil) {
            #expect(recorder.entries.isEmpty, "user code ran for a rejected request: \(recorder.entries)")
        }
    }

    /// `UnsupportedProtocolVersionError`: "listing the versions it does support"; `data.requested`
    /// is "the protocol version that was requested by the client" (`schema.ts`).
    @Test(arguments: ["1900-01-01", "", "2026-07-28 ", "v\"quoted\"\\", "версия", "😀", String(repeating: "9", count: 300)])
    func unsupportedVersionErrorCarriesRequestedAndSupported(_ requested: String) async throws {
        for configured in [ProtocolVersion.all, [.v2026_07_28], [.v2026_07_28, .v2025_11_25]] {
            let client = TestClient(try IndependentProtocolRich.server { $0.supportedVersions = configured }, modern: false)
            let response = try await client.request(
                "tools/list", meta: ["io.modelcontextprotocol/protocolVersion": .string(requested), "io.modelcontextprotocol/clientCapabilities": [:]])
            #expect(response.code == -32022)
            #expect(response["error"]?["data"]?["requested"] == .string(requested))
            #expect(response["error"]?["data"]?["supported"] == .array(configured.map { .string($0.rawValue) }))
            let violations = IndependentProtocolSchema.r2026_07_28.violations(in: response, as: "UnsupportedProtocolVersionError")
            #expect(violations.isEmpty, "\(violations)")
        }
    }

    // MARK: Both eras on one connection

    /// "Servers MUST NOT rely on prior requests over the same connection to establish context
    /// (e.g., capabilities, protocol version, client identity)" (`2026-07-28/basic/index.mdx`,
    /// "Statelessness"). A handshake session on the connection is such prior context.
    @Test func modernRequestsInheritNothingFromTheHandshakeSession() async throws {
        let server = try makeServer()  // has `greet` (elicits) and `chatty` (logs)
        try server.register(tool: ToolDefinition(name: "log_all")) { _, context in
            for level in LoggingLevel.allCases { context.log(level, .string(level.rawValue)) }
            return .text("logged")
        }
        let client = TestClient(server, modern: false)
        try await client.initialize(version: .v2025_11_25, capabilities: ["elicitation": [:], "sampling": [:], "roots": [:]])
        #expect(try await client.request("logging/setLevel", ["level": "debug"])["result"] == [:])

        // The session's log level is not this request's log level.
        client.clearReceived()
        let logged = try await client.request("tools/call", ["name": "log_all"], meta: IndependentProtocol.modernMeta)
        #expect(logged.text == "logged")
        #expect(client.received.isEmpty, "\(client.received)")

        // The session's capabilities are not this request's capabilities.
        let refused = try await client.request("tools/call", ["name": "greet"], meta: IndependentProtocol.modernMeta)
        #expect(refused.code == -32021, "\(refused)")
        #expect(refused["error"]?["data"]?["requiredCapabilities"]?["elicitation"] != nil)
        let violations = IndependentProtocolSchema.r2026_07_28.violations(in: refused, as: "MissingRequiredClientCapabilityError")
        #expect(violations.isEmpty, "\(violations)")

        // Nor do one modern request's capabilities and log level carry to the next.
        let withCapability: JSONObject = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": ["elicitation": [:]],
            "io.modelcontextprotocol/logLevel": "debug",
        ]
        let asked = try await client.request("tools/call", ["name": "greet"], meta: withCapability)
        #expect(asked["result"]?["resultType"] == "input_required", "\(asked)")
        #expect(try await client.request("tools/call", ["name": "log_all"], meta: withCapability).text == "logged")
        #expect(client.received.count { $0["method"] == "notifications/message" } == 8)
        client.clearReceived()
        #expect(try await client.request("tools/call", ["name": "greet"], meta: IndependentProtocol.modernMeta).code == -32021)
        _ = try await client.request("tools/call", ["name": "log_all"], meta: IndependentProtocol.modernMeta)
        #expect(client.received.isEmpty, "\(client.received)")

        // And the session is untouched by all of that: still 2025-11-25, still at debug.
        _ = try await client.request("tools/call", ["name": "log_all"])
        #expect(client.received.count { $0["method"] == "notifications/message" } == 8)
        #expect(try await client.request("tools/list")["result"]?["resultType"] == nil)
    }

    /// Methods of one era asked for in the manner of the other, on a connection that has both.
    @Test func eachEraKeepsItsOwnMethodsOnASharedConnection() async throws {
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(), .r2025_03_26)
        let modern = IndependentProtocol.modernMeta
        // Removed in 2026-07-28: not found when the request says 2026-07-28, served when it does not.
        for (method, params) in [("ping", [:]), ("logging/setLevel", ["level": "info"]), ("resources/subscribe", ["uri": "rich://static"]), ("resources/unsubscribe", ["uri": "rich://static"])] as [(String, JSONObject)] {
            #expect(try await client.request(method, params, meta: modern).code == -32601, "\(method)")
            #expect(try await client.request(method, params)["result"] == [:], "\(method)")
        }
        // New in 2026-07-28: the other way round.
        #expect(try await client.request("server/discover").code == -32601)
        #expect(try await client.request("server/discover", meta: modern)["result"]?["supportedVersions"] != nil)
    }

    @Test func aRepeatedHandshakeStartsAFreshSession() async throws {
        let server = try IndependentProtocolRich.server()
        let reference = try await IndependentProtocol.client(server, .r2025_06_18)
        _ = try await reference.request("tools/call", ["name": "log_all"])
        let referenceLogs = reference.received.filter { $0["method"] == "notifications/message" }
        reference.clearReceived()

        let client = try await IndependentProtocol.client(server, .r2025_11_25)
        #expect(try await client.request("logging/setLevel", ["level": "emergency"])["result"] == [:])
        #expect(try await client.request("resources/subscribe", ["uri": "rich://static"])["result"] == [:])
        _ = try await client.request("tools/list", meta: IndependentProtocol.modernMeta)
        let second = try await client.initialize(version: .v2025_06_18)
        #expect(second["result"]?["protocolVersion"] == "2025-06-18")
        client.clearReceived()

        // Log level: back to what a new session has.
        _ = try await client.request("tools/call", ["name": "log_all"])
        #expect(client.received.filter { $0["method"] == "notifications/message" } == referenceLogs)
        client.clearReceived()
        // Resource subscription: gone, exactly as on the connection that never subscribed.
        server.notifyResourceUpdated(uri: "rich://static")
        let afterUpdate = try await IndependentProtocol.drain(client)
        let referenceAfterUpdate = try await IndependentProtocol.drain(reference)
        #expect(afterUpdate == referenceAfterUpdate, "\(afterUpdate)")
        // Shapes: those of the new revision.
        for (method, params) in IndependentProtocolRich.calls {
            #expect(try await client.request(method, params)["result"] == reference.request(method, params)["result"], "\(method)")
        }
    }

    /// `initialize` selects the handshake era even when it carries modern metadata.
    @Test func initializeWithModernMetadataIsStillAHandshake() async throws {
        let client = TestClient(try IndependentProtocolRich.server(), modern: false)
        let response = try await client.request(
            "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "c", "version": "1"]],
            meta: IndependentProtocol.modernMeta)
        #expect(response["result"]?["protocolVersion"] == "2025-06-18")
        #expect(IndependentProtocol.responseViolations(response, to: "initialize", in: .r2025_06_18).isEmpty)
        #expect(try await client.request("ping")["result"] == [:])
    }

    // MARK: Discovery

    @Test func discoverListsTheConfiguredVersions() async throws {
        for configured in [ProtocolVersion.all, [.v2026_07_28], [.v2026_07_28, .v2025_03_26], [.v2025_06_18, .v2026_07_28]] {
            let client = TestClient(try IndependentProtocolRich.server { $0.supportedVersions = configured })
            let result = try #require(try await client.request("server/discover")["result"])
            #expect(result["supportedVersions"] == .array(configured.map { .string($0.rawValue) }))
        }
    }

    /// Capabilities advertised match what is registered, in both eras, and follow the registry.
    @Test func capabilitiesReflectTheRegistry() async throws {
        let server = Server(name: "growing", version: "1")
        func capabilities() async throws -> (modern: JSONValue, legacy: JSONValue) {
            let modern = try #require(try await TestClient(server).request("server/discover")["result"]?["capabilities"])
            let legacy = try #require(try await TestClient(server, modern: false).initialize()["result"]?["capabilities"])
            return (modern, legacy)
        }
        var seen = try await capabilities()
        for name in ["tools", "resources", "prompts", "completions"] {
            #expect(seen.modern[name] == nil && seen.legacy[name] == nil, "\(name) advertised by an empty server")
        }
        try server.register(tool: ToolDefinition(name: "t")) { _, _ in .text("") }
        seen = try await capabilities()
        #expect(seen.modern["tools"] != nil && seen.legacy["tools"] != nil)
        #expect(seen.modern["resources"] == nil && seen.modern["prompts"] == nil && seen.modern["completions"] == nil)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "t://{x}", name: "t")) { _, _ in [] }
        seen = try await capabilities()
        #expect(seen.modern["resources"] != nil && seen.legacy["resources"] != nil, "a template alone is a resource capability")
        #expect(seen.modern["completions"] == nil && seen.legacy["completions"] == nil)
        try server.register(prompt: PromptDefinition(name: "p"), complete: { _, _ in CompletionResult() }) { _, _ in PromptResult(messages: []) }
        seen = try await capabilities()
        #expect(seen.modern["prompts"] != nil && seen.legacy["prompts"] != nil)
        #expect(seen.modern["completions"] != nil && seen.legacy["completions"] != nil)
        #expect(seen.modern == seen.legacy)
        server.removeTool(named: "t")
        seen = try await capabilities()
        #expect(seen.modern["tools"] == nil && seen.legacy["tools"] == nil)
    }

    @Test(arguments: IndependentProtocolRevision.allCases)
    func methodsOfUnadvertisedCapabilitiesAreNotFound(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "bare", version: "1")
        let client = try await IndependentProtocol.client(server, revision)
        for (method, params) in [
            ("tools/list", [:]), ("tools/call", ["name": "x"]), ("resources/list", [:]), ("resources/templates/list", [:]),
            ("resources/read", ["uri": "x://y"]), ("prompts/list", [:]), ("prompts/get", ["name": "x"]),
            ("completion/complete", ["ref": ["type": "ref/prompt", "name": "x"], "argument": ["name": "a", "value": ""]]),
        ] as [(String, JSONObject)] {
            let response = try await client.request(method, params)
            #expect(response.code == -32601, "\(revision.rawValue) \(method): \(response)")
        }
    }
}
