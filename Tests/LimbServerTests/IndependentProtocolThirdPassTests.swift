import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var text: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
    var readText: String? { self["result"]?["contents"]?[0]?["text"]?.stringValue }
}

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"
/// U+212A KELVIN SIGN: canonically equivalent to the ASCII letter K.
private let kelvin = "\u{212A}"

@Suite struct IndependentProtocolThirdPassTests {
    // MARK: Negotiated or offered (fix 1)

    private enum Item: String, CaseIterable, Sendable {
        case tool, resource, prompt, completing
        /// The capabilities an item brings.
        var capabilities: Set<String> {
            switch self {
            case .tool: ["tools"]
            case .resource: ["resources"]
            case .prompt: ["prompts"]
            case .completing: ["prompts", "completions"]
            }
        }
    }

    private static func add(_ item: Item, to server: Server) throws {
        switch item {
        case .tool: try server.register(tool: ToolDefinition(name: "t")) { _, _ in .text("t") }
        case .resource: try server.register(resource: ResourceDefinition(uri: "g://fixed", name: "f")) { request, _ in [.text(uri: request.uri, text: "f")] }
        case .prompt: try server.register(prompt: PromptDefinition(name: "plain")) { _, _ in PromptResult(messages: []) }
        case .completing:
            try server.register(prompt: PromptDefinition(name: "completing"), complete: { _, _ in CompletionResult(values: ["v"]) }) { _, _ in PromptResult(messages: []) }
        }
    }

    private static func remove(_ item: Item, from server: Server) {
        switch item {
        case .tool: server.removeTool(named: "t")
        case .resource: server.removeResource(uri: "g://fixed")
        case .prompt: server.removePrompt(named: "plain")
        case .completing: server.removePrompt(named: "completing")
        }
    }

    /// Methods per capability, with parameters that name nothing: the question is only whether
    /// the method exists. The last column is what a served call answers with.
    private static let gated: [(capability: String, method: String, params: JSONObject, legacyOnly: Bool)] = [
        ("tools", "tools/list", [:], false), ("tools", "tools/call", ["name": "nobody"], false),
        ("resources", "resources/list", [:], false), ("resources", "resources/templates/list", [:], false),
        ("resources", "resources/read", ["uri": "nowhere://x"], false), ("resources", "resources/subscribe", ["uri": "nowhere://x"], true),
        ("resources", "resources/unsubscribe", ["uri": "nowhere://x"], true),
        ("prompts", "prompts/list", [:], false), ("prompts", "prompts/get", ["name": "nobody"], false),
        ("completions", "completion/complete", ["ref": ["type": "ref/prompt", "name": "nobody"], "argument": ["name": "a", "value": ""]], false),
    ]

    /// Legacy requests use the capabilities announced by that session's initialize.
    /// Modern requests use current discovery, which retains list families across removals.
    /// Check each step for sessions opened before and during the registry changes.
    @Test(arguments: [
        "+tool -tool +tool -tool",
        "+tool +resource +prompt +completing | -tool -resource -prompt -completing",
        "+completing | -completing +prompt -prompt",
        "| +tool +resource | -tool -resource +prompt | -prompt +completing -completing",
        "+prompt +completing -prompt | -completing +tool -tool",
        "+resource | -resource +resource -resource | +tool",
    ])
    func routingUsesTheCapabilitiesOfItsOwnEra(_ script: String) async throws {
        let server = Server(name: "gate", version: "1")
        var registered: Set<Item> = []
        var registeredListFamilies: Set<String> = []
        func currentFamilies() -> Set<String> {
            registered.reduce(into: Set<String>()) { $0.formUnion($1.capabilities) }
        }
        /// Sessions, each with the capabilities its handshake announced (`nil` for the modern client).
        var sessions: [(label: String, client: TestClient, revision: IndependentProtocolRevision, negotiated: Set<String>?)] = []
        func open(_ label: String) async throws {
            for revision in IndependentProtocolRevision.legacy {
                let client = TestClient(server, modern: false)
                let capabilities = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"]?.objectValue)
                let negotiated = Set(capabilities.map(\.key))
                #expect(negotiated.subtracting(["logging"]) == currentFamilies(), "\(label) \(revision.rawValue)")
                sessions.append(("\(label) \(revision.rawValue)", client, revision, negotiated))
            }
            sessions.append(("\(label) modern", TestClient(server), .r2026_07_28, nil))
        }
        func check(_ step: String) async throws {
            let now = try #require(try await TestClient(server).request("server/discover")["result"]?["capabilities"]?.objectValue)
            let offered = Set(now.map(\.key))
            let expected = registeredListFamilies.union(currentFamilies().intersection(["completions"]))
            #expect(offered.subtracting(["logging"]) == expected, "after \(step)")
            for (label, client, revision, negotiated) in sessions {
                for (capability, method, params, legacyOnly) in Self.gated {
                    let response = try await client.request(method, params)
                    let exists = (negotiated ?? offered).contains(capability) && !(legacyOnly && revision.isModern)
                    #expect((response.code != -32601) == exists, "after \(step), session \(label) (negotiated \(negotiated?.sorted() ?? [])), offered \(offered.sorted()): \(method) → \(response)")
                    // A served listing shows what is registered now, whenever the session was opened.
                    if exists {
                        let result = response["result"]
                        switch method {
                        case "tools/list": #expect(result?["tools"]?.arrayValue?.count == (registered.contains(.tool) ? 1 : 0), "\(label) after \(step)")
                        case "resources/list": #expect(result?["resources"]?.arrayValue?.count == (registered.contains(.resource) ? 1 : 0), "\(label) after \(step)")
                        case "resources/templates/list": #expect(result?["resourceTemplates"] == [], "\(label) after \(step)")
                        case "prompts/list": #expect(result?["prompts"]?.arrayValue?.count == registered.intersection([.prompt, .completing]).count, "\(label) after \(step)")
                        default: break
                        }
                    }
                }
                client.clearReceived()
            }
        }
        try await open("opened first")
        try await check("start")
        var opened = 1
        for step in script.split(separator: " ") {
            if step == "|" {
                opened += 1
                try await open("opened #\(opened)")
            } else {
                let item = try #require(Item(rawValue: String(step.dropFirst())))
                if step.hasPrefix("+") {
                    try Self.add(item, to: server)
                    registered.insert(item)
                    registeredListFamilies.formUnion(item.capabilities.subtracting(["completions"]))
                } else {
                    Self.remove(item, from: server)
                    registered.remove(item)
                }
            }
            try await check(String(step))
        }
    }

    /// A second `initialize` on the connection starts a new session: its capabilities are the
    /// ones the second handshake announced. What the first one had negotiated is not carried over.
    @Test(arguments: IndependentProtocolRevision.legacy)
    func renegotiationReplacesTheNegotiatedCapabilities(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "gate", version: "1")
        for item in Item.allCases { try Self.add(item, to: server) }
        let client = TestClient(server, modern: false)
        let first = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"])
        #expect(first["tools"] != nil && first["resources"] != nil && first["prompts"] != nil && first["completions"] != nil)
        for item in Item.allCases { Self.remove(item, from: server) }
        // Still the first session: everything it negotiated is there, empty.
        #expect(try await client.request("tools/list")["result"]?["tools"] == [])
        #expect(try await client.request("prompts/list")["result"]?["prompts"] == [])
        #expect(try await client.request("resources/list")["result"]?["resources"] == [])
        #expect(try await client.request("resources/subscribe", ["uri": "g://fixed"])["result"] == [:])
        #expect(try await client.request("completion/complete", ["ref": ["type": "ref/prompt", "name": "completing"], "argument": ["name": "a", "value": ""]]).code == -32602)

        // A handshake that fails changes nothing.
        #expect(try await client.request("initialize", ["capabilities": [:]]).code == -32602)
        #expect(try await client.request("tools/list")["result"]?["tools"] == [])

        // The second handshake announces nothing, and nothing is what the new session has.
        let second = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"]?.objectValue)
        #expect(Set(second.map(\.key)) == ["logging"], "\(second)")
        for (_, method, params, _) in Self.gated {
            #expect(try await client.request(method, params).code == -32601, "\(method) survived the second handshake")
        }
        // A third handshake negotiates the family registered since the second handshake.
        try Self.add(.tool, to: server)
        #expect(try await client.request("tools/list").code == -32601)
        let third = try #require(try await client.initialize(version: revision.version)["result"]?["capabilities"])
        #expect(third["tools"] != nil && third["prompts"] == nil)
        #expect(try await client.request("tools/list")["result"]?["tools"]?[0]?["name"] == "t")
        Self.remove(.tool, from: server)
        #expect(try await client.request("tools/list")["result"]?["tools"] == [])
        #expect(try await client.request("prompts/list").code == -32601)
    }

    /// "Servers MUST NOT rely on prior requests over the same connection to establish context"
    /// (`2026-07-28/basic/index.mdx`): what a handshake session on the connection negotiated is
    /// not available to a request that states `2026-07-28` — in or out of a batch.
    @Test func modernRequestsDoNotBorrowTheSessionsCapabilities() async throws {
        let server = Server(name: "gate", version: "1")
        for item in Item.allCases { try Self.add(item, to: server) }
        let client = try await IndependentProtocol.client(server, .r2025_03_26)
        for item in Item.allCases { Self.remove(item, from: server) }
        client.clearReceived()
        for (capability, method, params, legacyOnly) in Self.gated {
            let legacy = try await client.request(method, params)
            #expect(legacy.code != -32601, "the session negotiated it: \(method) → \(legacy)")
            let modern = try await client.request(method, params, meta: IndependentProtocol.modernMeta)
            #expect((modern.code == -32601) == (legacyOnly || capability == "completions"), "\(method) with 2026-07-28 metadata → \(modern)")
        }
        let discovered = try #require(try await client.request("server/discover", meta: IndependentProtocol.modernMeta)["result"]?["capabilities"]?.objectValue)
        #expect(Set(discovered.map(\.key)) == ["logging", "tools", "resources", "prompts"])
    }

    // MARK: Ids (fix 2)

    /// Ids that differ only in normalization, in one `2025-03-26` batch: four requests, four
    /// answers, each under exactly the bytes it was asked with.
    @Test func batchRepliesKeepIdsThatDifferOnlyInNormalization() async throws {
        let gate = Gate()
        let started = Counter()
        let server = try makeServer(gate: gate, started: started)
        let peer = IndependentProtocolRawPeer(server)
        try #require(peer.send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#).count == 1)
        let ids = [composed, decomposed, "K", kelvin]
        let members = ids.map { #"{"jsonrpc":"2.0","id":"\#($0)","method":"tools/call","params":{"name":"wait"}}"# }
        #expect(peer.send("[" + members.joined(separator: ",") + "]").isEmpty)
        gate.open()
        var frames: [String] = []
        let deadline = ContinuousClock.now + .seconds(20)
        while frames.isEmpty, ContinuousClock.now < deadline {
            frames = peer.take()
            if frames.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        }
        try #require(frames.count == 1, "\(frames)")
        // Raw text: each id must be there as the bytes that were sent, once.
        // Counted on bytes: Foundation's string search would take the two spellings for one.
        let frame = Array(frames[0].utf8)
        for id in ids {
            let needle = Array(#""id":"\#(id)""#.utf8)
            let count = (0...(frame.count - needle.count)).count { frame[$0..<($0 + needle.count)].elementsEqual(needle) }
            #expect(count == 1, "id \(id.debugDescription) occurs \(count) times in \(frames[0])")
        }
        #expect(!frames[0].contains("already in use"), "\(frames[0])")
        #expect(frames[0].components(separatedBy: "released").count - 1 == 4)
        #expect(started.count == 4)
    }

    /// Progress and cancellation with such ids and such progress tokens: each request gets its
    /// own notifications under its own token; cancelling one leaves the other complete.
    @Test func progressAndCancellationKeepSuchIdsApart() async throws {
        let gate = Gate()
        let client = TestClient(try makeServer(gate: gate))
        let pairs = [(composed, decomposed), ("K", kelvin)]
        var all: [RequestID] = []
        for (kept, cancelled) in pairs {
            for id in [kept, cancelled] {
                all.append(client.post("tools/call", ["name": "wait"], id: RequestID(id), meta: ["progressToken": .string(id)]))
            }
        }
        // The first progress notification of each of the four, before anything is released.
        var firstProgress: [[UInt8]: Int] = [:]
        for _ in 0..<4 {
            let message = try await client.next()
            #expect(message["method"] == "notifications/progress", "\(message)")
            #expect(message["params"]?["progress"] == 1)
            firstProgress[Array((message["params"]?["progressToken"]?.stringValue ?? "?").utf8), default: 0] += 1
        }
        #expect(firstProgress == Dictionary(uniqueKeysWithValues: pairs.flatMap { [(Array($0.0.utf8), 1), (Array($0.1.utf8), 1)] }), "\(firstProgress)")
        for (_, cancelled) in pairs { client.notify("notifications/cancelled", ["requestId": .string(cancelled)]) }
        gate.open()
        let kept = pairs.map { RequestID($0.0) }
        // For each surviving request: its second progress notification and its response; nothing for the cancelled ones.
        var seen: [JSONValue] = []
        var responses = 0
        while responses < kept.count, let message = try? await client.next(timeout: .seconds(10)) {
            seen.append(message)
            if message["method"] == nil { responses += 1 }
        }
        for (keptID, cancelledID) in pairs {
            let mine = seen.filter { $0["id"] == .string(keptID) || $0["params"]?["progressToken"] == .string(keptID) }
            #expect(mine.count == 2, "request \(keptID.debugDescription): \(mine)")
            #expect(mine.contains { $0["params"]?["progress"] == 2 })
            #expect(mine.contains { $0["result"]?["content"]?[0]?["text"] == "released" })
            let theirs = seen.filter { $0["id"] == .string(cancelledID) || $0["params"]?["progressToken"] == .string(cancelledID) }
            #expect(theirs.isEmpty, "something was sent for the cancelled \(cancelledID.debugDescription): \(theirs)")
        }
        #expect(try await IndependentProtocol.drain(client).isEmpty)
        _ = all
    }

    @Test func theSameIdOnTwoConnectionsIsTwoRequests() async throws {
        let gate = Gate()
        let started = Counter()
        let server = try makeServer(gate: gate, started: started)
        let clients = [TestClient(server), TestClient(server), try await IndependentProtocol.client(server, .r2025_11_25)]
        for client in clients {
            client.post("tools/call", ["name": "wait"], id: 1)
            client.post("tools/call", ["name": "wait"], id: "same")
        }
        for client in clients {
            let early = try await IndependentProtocol.drain(client)
            #expect(early.isEmpty, "\(early)")
        }
        // Cancelling on one connection does not reach the others.
        clients[0].notify("notifications/cancelled", ["requestId": 1])
        gate.open()
        for (index, client) in clients.enumerated() {
            let answers = await IndependentProtocol.responses(client, to: index == 0 ? ["same"] : [1, "same"], timeout: .seconds(10))
            #expect(answers.count == (index == 0 ? 1 : 2), "connection \(index): \(answers)")
            #expect(answers.values.allSatisfy { $0.text == "released" })
        }
        #expect(started.count == 6)
    }

    // MARK: Templates as bytes (fix 5)

    /// The rule for a variable's value, written out independently (see the second-pass tests).
    private static func decoded(_ text: String) -> String {
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "%"), index + 2 < source.count, source[index + 1] < 0x80, source[index + 2] < 0x80,
                let high = Character(UnicodeScalar(source[index + 1])).hexDigitValue, let low = Character(UnicodeScalar(source[index + 2])).hexDigitValue
            {
                bytes.append(UInt8(high * 16 + low))
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        let repaired = String(decoding: bytes, as: UTF8.self)
        return Array(repaired.utf8) == bytes ? repaired : text
    }

    /// ICU matches quoted literals without canonical equivalence. Greedy quantifiers model the
    /// longest-first capture order, with a second expression for matches that need empty captures.
    private static func oracle(template: String) throws -> (String) -> [String: String]? {
        var nonemptyPattern = "\\A"
        var emptyAllowedPattern = "\\A"
        var names: [String] = []
        // By code points: to `String`, "}" followed by a combining mark is not a "}".
        var rest = template.unicodeScalars[...]
        func quoted(_ scalars: Substring.UnicodeScalarView) -> String { NSRegularExpression.escapedPattern(for: String(String.UnicodeScalarView(scalars))) }
        while let open = rest.firstIndex(of: "{") {
            let literal = quoted(rest[..<open])
            nonemptyPattern += literal
            emptyAllowedPattern += literal
            let close = try #require(rest[open...].firstIndex(of: "}"))
            var name = rest[rest.index(after: open)..<close]
            if name.first == "+" {
                name = name.dropFirst()
                nonemptyPattern += "(.+)"
                emptyAllowedPattern += "(.*)"
            } else {
                nonemptyPattern += "([^/]+)"
                emptyAllowedPattern += "([^/]*)"
            }
            names.append(String(String.UnicodeScalarView(name)))
            rest = rest[rest.index(after: close)...]
        }
        let suffix = quoted(rest) + "\\z"
        let nonempty = try NSRegularExpression(pattern: nonemptyPattern + suffix, options: [.dotMatchesLineSeparators])
        let emptyAllowed = try NSRegularExpression(pattern: emptyAllowedPattern + suffix, options: [.dotMatchesLineSeparators])
        return { uri in
            let text = uri as NSString
            let range = NSRange(location: 0, length: text.length)
            guard let match = nonempty.firstMatch(in: uri, range: range) ?? emptyAllowed.firstMatch(in: uri, range: range) else { return nil }
            var variables: [String: String] = [:]
            for (index, name) in names.enumerated() { variables[name] = decoded(text.substring(with: match.range(at: index + 1))) }
            return variables
        }
    }

    private static let pieces = ["a", "/", "\u{E9}", "e\u{301}", "\u{301}", "😀", "-", "K", "\u{212A}", "%2F", "%C3%A9", "%", "%C3"]

    /// Templates with multi-byte literals, variables next to multi-byte text, reserved variables
    /// across slashes and escapes next to multi-byte text — against every URI of up to three
    /// pieces of the same material, and the URIs each template is made to match.
    @Test(arguments: [
        "o://{x}", "o://{+x}", "o://a{x}", "o://{x}a", "o://\u{E9}{x}", "o://{x}\u{E9}", "o://e\u{301}{x}", "o://{x}e\u{301}", "o://{x}\u{301}",
        "o://\u{301}{x}", "o://{x}/{y}", "o://{+x}/{y}", "o://{x}/{+y}", "o://{+x}/{+y}", "o://{x}{y}", "o://{+x}{y}", "o://{x}{+y}", "o://{x}-{y}",
        "o://{x}\u{E9}{y}", "o://{+x}😀", "o://😀{x}", "o://{x}/\u{E9}/{y}", "o://K{x}", "o://\u{212A}{x}", "o://{x}%", "o://%{x}", "o://{x}%2F{y}",
        "o://{+x}/a", "o://a/{+x}/a", "o://{x}😀{+y}/", "o://{x}e{y}",
        // Shapes a table-driven matcher could get wrong at its edges: a template that is one
        // variable, that starts or ends with one, adjacent variables of both kinds, three in a
        // row, no variable at all. (A name used twice is refused at registration: see
        // `aVariableNameUsedTwiceIsRefused`.)
        "{x}", "{+x}", "{x}{y}", "{+x}{+y}", "{x}{+y}", "{+x}{y}", "{x}{y}{z}", "{+x}{y}{+z}", "{x}{+y}{z}", "{x}/", "/{x}", "{+x}/", "/{+x}",
        "{x}a", "a{x}", "{x}://a", "{+x}/{+y}/{+z}", "{+x}a{+y}a{+z}", "{x}/{y}/{z}/a", "a", "a/\u{E9}",
        "{+x}\u{E9}{+y}\u{E9}", "{x}\u{301}{y}", "{+x}//{+y}", "",
    ])
    func templateMatchingAgreesWithARegularExpression(_ template: String) async throws {
        let server = Server(name: "oracle", version: "1")
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: "t")) { request, _ in
            [.text(uri: request.uri, text: JSONValue.object(JSONObject(request.variables.map { ($0.key, JSONValue.string($0.value)) })).description)]
        }
        let client = TestClient(server)
        // URIs share the template's fixed start, if it has one, so that most get past it.
        let prefix = template.hasPrefix("o://") ? "o://" : ""
        var uris: [String] = ["", prefix]
        for a in Self.pieces {
            uris.append(prefix + a)
            for b in Self.pieces {
                uris.append(prefix + a + b)
                for c in Self.pieces { uris.append(prefix + a + b + c) }
            }
        }
        // Deeper ones over a smaller alphabet: every string of four to six of these.
        var deeper = [""]
        for length in 1...6 {
            deeper = deeper.flatMap { head in ["a", "/", "\u{E9}"].map { head + $0 } }
            if length >= 4 { uris += deeper.map { prefix + $0 } }
        }
        // Longer ones, built from the template itself so that deep matches are exercised.
        for value in ["a", "\u{E9}a", "a/a", "😀/e\u{301}", "a\u{301}/\u{E9}", "%C3%A9/\u{E9}%2F", "a-a/a-a", "/"] {
            for other in ["a", "\u{E9}/a", "e\u{301}"] {
                var uri = template
                for (variable, replacement) in [("{x}", value), ("{+x}", value), ("{y}", other), ("{+y}", other)] {
                    uri = uri.replacingOccurrences(of: variable, with: replacement, options: .literal)
                }
                uris.append(uri)
            }
        }
        var failures = 0
        var matched = 0
        let expectedMatch = try Self.oracle(template: template)
        for uri in uris {
            let expected = expectedMatch(uri)
            let response = try await client.request("resources/read", ["uri": .string(uri)])
            var seen: [String: String]?
            if let text = response.readText {
                seen = [:]
                for (key, value) in try JSON.parse(Array(text.utf8)).objectValue ?? JSONObject() { seen?[key] = value.stringValue }
            } else if response.code != -32602 {
                Issue.record("\(uri.debugDescription): \(response)")
            }
            if expected != nil { matched += 1 }
            let same = seen?.mapValues { Array($0.utf8) } == expected?.mapValues { Array($0.utf8) }
            if !same {
                failures += 1
                if failures <= 8 { Issue.record("\(template.debugDescription) ← \(uri.debugDescription): Limb \(seen.debugDescription), regular expression \(expected.debugDescription)") }
            }
        }
        #expect(failures == 0, "\(failures) of \(uris.count) URIs")
        #expect(matched > 0, "the oracle never matched: the test would prove nothing")
    }

    @Test(arguments: ["{x}/{x}", "{+x}{+x}", "{x}{x}{x}", "o://{x}/{+x}"])
    func aVariableNameUsedTwiceIsRefused(_ template: String) {
        let server = Server(name: "oracle", version: "1")
        #expect(throws: RegistrationError.self) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: "t")) { request, _ in
                [.text(uri: request.uri, text: "")]
            }
        }
    }

    /// `ref/resource` in `completion/complete` goes through the same byte-wise lookup.
    @Test func completionReferencesAreMatchedByBytes() async throws {
        let server = Server(name: "exact", version: "1")
        try server.register(
            resourceTemplate: ResourceTemplateDefinition(uriTemplate: "u://\(composed)/{id}", name: "t"),
            complete: { _, _ in CompletionResult(values: ["composed"]) }
        ) { _, _ in [] }
        try server.register(prompt: PromptDefinition(name: "K"), complete: { _, _ in CompletionResult(values: ["K"]) }) { _, _ in PromptResult(messages: []) }
        let client = TestClient(server)
        func complete(_ ref: JSONObject) async throws -> JSONValue {
            try await client.request("completion/complete", ["ref": .object(ref), "argument": ["name": "id", "value": ""]])
        }
        #expect(try await complete(["type": "ref/resource", "uri": .string("u://\(composed)/{id}")])["result"]?["completion"]?["values"] == ["composed"])
        #expect(try await complete(["type": "ref/resource", "uri": .string("u://\(composed)/7")])["result"]?["completion"]?["values"] == ["composed"])
        #expect(try await complete(["type": "ref/resource", "uri": .string("u://\(decomposed)/{id}")]).code == -32602)
        #expect(try await complete(["type": "ref/resource", "uri": .string("u://\(decomposed)/7")]).code == -32602)
        #expect(try await complete(["type": "ref/prompt", "name": "K"])["result"]?["completion"]?["values"] == ["K"])
        #expect(try await complete(["type": "ref/prompt", "name": .string(kelvin)]).code == -32602)
    }

    @Test func anUnlistedDocumentReturnsNotFoundWithAndWithoutTemplates() async throws {
        let library = Server(name: "library", version: "1")
        for section in ["guides", "reference", "releases"] {
            try library.register(
                resourceTemplate: ResourceTemplateDefinition(uriTemplate: "docs://library/\(section)/{title}.md", name: section)
            ) { request, _ in
                [.text(uri: request.uri, text: request.variables["title"] ?? "")]
            }
        }

        let catalog = Server(name: "catalog", version: "1")
        try catalog.register(resource: ResourceDefinition(uri: "docs://library/index.md", name: "index")) { request, _ in
            [.text(uri: request.uri, text: "Library index")]
        }

        let libraryClient = TestClient(library, modern: true)
        let catalogClient = TestClient(catalog, modern: true)
        let uri: JSONValue = "docs://library/guides/setup.pdf"
        #expect(try await libraryClient.request("resources/read", ["uri": uri]).code == -32602)
        #expect(try await catalogClient.request("resources/read", ["uri": uri]).code == -32602)
        #expect(try await libraryClient.request("resources/read", ["uri": "docs://library/guides/setup.md"]).readText == "setup")
        #expect(try await catalogClient.request("resources/read", ["uri": "docs://library/index.md"]).readText == "Library index")
    }

    /// The size limit for template matching, as stated with the rewrite: a URI of up to 64 KiB
    /// is matched as any other, a longer one matches no template, and a fixed resource is read
    /// whatever the length of its URI. (The specification sets no limit and forbids none; the
    /// number is Limb's.)
    @Test(arguments: IndependentProtocolRevision.allCases)
    func templateMatchingAtTheSizeLimit(_ revision: IndependentProtocolRevision) async throws {
        let limit = 64 * 1024
        let long = "fixed://" + String(repeating: "r", count: 2 * limit)
        let server = Server(name: "limit", version: "1")
        let read: ResourceReader = { request, _ in
            let lengths = request.variables.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.utf8.count)" }.joined(separator: ",")
            return [.text(uri: "short://answer", text: lengths)]
        }
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "one://{x}", name: "one"), read: read)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "two://{+x}/{y}", name: "two"), read: read)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "{+x}?end", name: "three"), read: read)
        try server.register(resource: ResourceDefinition(uri: long, name: "long")) { _, _ in [.text(uri: "short://answer", text: "fixed")] }
        let client = try await IndependentProtocol.client(server, revision)
        let notFound = revision.isModern ? -32602 : -32002
        for total in [limit - 1, limit, limit + 1, limit + 2, 2 * limit] {
            let matches = total <= limit
            // One variable taking everything; the last character is a multi-byte one.
            let one = "one://" + String(repeating: "a", count: total - 6 - 2) + "\u{E9}"
            try #require(one.utf8.count == total)
            let first = try await client.request("resources/read", ["uri": .string(one)])
            if matches { #expect(first.readText == "x:\(total - 6)", "\(total) bytes") } else { #expect(first.code == notFound, "\(total) bytes") }
            // Two variables with slashes in between: the reserved one takes all but the last segment.
            let tail = 3 + (total - 6 - 3) % 2
            let two = "two://" + String(repeating: "s/", count: (total - 6 - 3) / 2) + String(repeating: "t", count: tail)
            try #require(two.utf8.count == total)
            let second = try await client.request("resources/read", ["uri": .string(two)])
            if matches { #expect(second.readText == "x:\(total - 6 - tail - 1),y:\(tail)", "\(total) bytes") } else { #expect(second.code == notFound, "\(total) bytes") }
            // A template that starts with a variable and ends with a literal.
            let three = String(repeating: "\u{E9}", count: (total - 4) / 2) + String(repeating: "z", count: (total - 4) % 2) + "?end"
            try #require(three.utf8.count == total)
            let third = try await client.request("resources/read", ["uri": .string(three)])
            if matches { #expect(third.readText == "x:\(total - 4)", "\(total) bytes") } else { #expect(third.code == notFound, "\(total) bytes") }
            // The same length, one byte off at the end: not found either way.
            let off = String(three.dropLast()) + "x"
            #expect(try await client.request("resources/read", ["uri": .string(off)]).code == notFound)
        }
        // A fixed resource far above the limit is still read, and still listed.
        #expect(try await client.request("resources/read", ["uri": .string(long)]).readText == "fixed")
        #expect(try await client.request("resources/list")["result"]?["resources"]?[0]?["uri"] == .string(long))
        #expect(try await client.request("resources/read", ["uri": .string(long + "r")]).code == notFound)
    }

    // MARK: Names the server compares (the request path)

    /// Every code point whose canonical decomposition is plain ASCII, found by asking Foundation
    /// about all of Unicode: these are the characters that `String ==` equates with ASCII text.
    private static let canonicalLookalikes: [Character: [Character]] = {
        var found: [Character: [Character]] = [:]
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let decomposition = String(Character(scalar)).decomposedStringWithCanonicalMapping
            if decomposition.unicodeScalars.count == 1, let ascii = decomposition.unicodeScalars.first, ascii.isASCII {
                found[Character(ascii), default: []].append(Character(scalar))
            }
        }
        return found
    }()

    /// Strings that Swift's `==` equates with `name` though their bytes differ, plus a few that
    /// only look like it.
    private static func lookalikes(of name: String) -> [String] {
        var out: [String] = []
        for (index, character) in name.enumerated() {
            for twin in canonicalLookalikes[character] ?? [] {
                var characters = Array(name)
                characters[index] = twin
                out.append(String(characters))
            }
        }
        try? #require(out.allSatisfy { $0 == name && Array($0.utf8) != Array(name.utf8) })
        return out
    }

    /// Method names, notification names, log levels, reference types, metadata keys and version
    /// strings are ASCII literals compared with `String ==` or in a `switch`. Whatever `==`
    /// equates with one of them without being the same bytes is a different name.
    @Test func lookalikesOfProtocolNamesAreOtherNames() async throws {
        // The premise, checked: the only ASCII characters with a canonical twin.
        #expect(Set(Self.canonicalLookalikes.keys) == ["K", ";", "`"], "\(Self.canonicalLookalikes)")

        let recorder = IndependentProtocolRecorder()
        let server = try IndependentProtocolRich.server(recorder: recorder)
        try server.register(tool: ToolDefinition(name: "Kelvin")) { _, _ in .text("tool") }
        try server.register(method: "acme/Kind;`") { _, _ in ["which": "custom"] }
        try server.register(prompt: PromptDefinition(name: "Key;`")) { _, _ in PromptResult(messages: [.user("prompt")]) }
        try server.register(resource: ResourceDefinition(uri: "K://x;`", name: "r")) { request, _ in [.text(uri: request.uri, text: "resource")] }
        let legacy = try await IndependentProtocol.client(server, .r2025_11_25)
        let modern = TestClient(server)

        let builtins = [
            "initialize", "ping", "server/discover", "tools/list", "tools/call", "resources/list", "resources/templates/list", "resources/read",
            "resources/subscribe", "resources/unsubscribe", "prompts/list", "prompts/get", "completion/complete", "logging/setLevel",
            "subscriptions/listen",
        ]
        // Not equal for `String`, but the kind of thing a homograph is made of.
        func homographs(of name: String) -> [String] {
            [name + "\u{200B}", name + "\u{FE0F}", name + "\u{301}", "\u{200D}" + name, name.replacingOccurrences(of: "i", with: "\u{456}"),
             name.replacingOccurrences(of: "o", with: "\u{43E}"), name.replacingOccurrences(of: "l", with: "\u{FF4C}"), name.uppercased(),
             name.replacingOccurrences(of: "/", with: "\u{2215}")].filter { Array($0.utf8) != Array(name.utf8) }
        }
        for name in builtins {
            for twin in Self.lookalikes(of: name) + homographs(of: name) {
                for client in [legacy, modern] {
                    let response = try await client.request(twin, ["level": "debug", "uri": "rich://static", "name": "plain", "protocolVersion": "2025-03-26"])
                    #expect(response.code == -32601, "\(twin.debugDescription) was taken for \(name): \(response)")
                }
                // And it is free for a custom method, which then is that method and not the built-in.
                #expect(throws: Never.self) { try server.register(method: twin) { _, _ in ["custom": true] } }
                #expect(try await modern.request(twin)["result"]?["custom"] == true)
            }
        }
        #expect(try await legacy.request("tools/list")["result"]?["tools"] != nil)
        #expect(try await legacy.request("ping")["result"] == [:])

        // Names of the user's own that do contain such characters.
        for twin in Self.lookalikes(of: "Kelvin") {
            #expect(try await modern.request("tools/call", ["name": .string(twin)]).code == -32602, "\(twin.debugDescription)")
        }
        for twin in Self.lookalikes(of: "acme/Kind;`") {
            #expect(try await modern.request(twin).code == -32601, "\(twin.debugDescription)")
        }
        for twin in Self.lookalikes(of: "Key;`") {
            #expect(try await modern.request("prompts/get", ["name": .string(twin)]).code == -32602, "\(twin.debugDescription)")
        }
        for twin in Self.lookalikes(of: "K://x;`") {
            #expect(try await modern.request("resources/read", ["uri": .string(twin)]).code == -32602, "\(twin.debugDescription)")
            #expect(try await legacy.request("resources/read", ["uri": .string(twin)]).code == -32002, "\(twin.debugDescription)")
        }
        #expect(Self.lookalikes(of: "Kelvin").count == 1 && Self.lookalikes(of: "K://x;`").count == 3)

        // Log levels, reference types, versions: no canonical twin exists; the homographs are refused.
        for level in IndependentProtocolRich.levels {
            #expect(Self.lookalikes(of: level).isEmpty)
            for twin in homographs(of: level) {
                #expect(try await legacy.request("logging/setLevel", ["level": .string(twin)]).code == -32602, "\(twin.debugDescription)")
                #expect(try await modern.request("tools/list", meta: ["io.modelcontextprotocol/logLevel": .string(twin)]).code == -32602, "\(twin.debugDescription)")
            }
        }
        for type in ["ref/prompt", "ref/resource"] {
            for twin in homographs(of: type) {
                let response = try await modern.request("completion/complete", ["ref": ["type": .string(twin), "name": "rich_prompt", "uri": "rich://items/{id}"], "argument": ["name": "topic", "value": ""]])
                #expect(response.code == -32602, "\(twin.debugDescription): \(response)")
            }
        }
        for twin in homographs(of: "2026-07-28") + ["2026\u{2010}07\u{2010}28", "２０２６-07-28", "2026-07-28\u{0}"] {
            let response = try await legacy.request("tools/list", meta: ["io.modelcontextprotocol/protocolVersion": .string(twin), "io.modelcontextprotocol/clientCapabilities": [:]])
            #expect(response.code == -32022, "\(twin.debugDescription): \(response)")
        }
        #expect(recorder.entries.isEmpty, "\(recorder.entries)")
    }

    // MARK: Custom methods (fix 3)

    /// Registering a method twice is an error now, as for tools, prompts and resources; the
    /// first handler stays.
    @Test func aCustomMethodIsRegisteredOnce() async throws {
        let server = Server(name: "custom", version: "1")
        try server.register(method: "acme/once") { _, _ in ["which": "first"] }
        let error = #expect(throws: RegistrationError.self) { try server.register(method: "acme/once") { _, _ in ["which": "second"] } }
        #expect(error?.description.contains("acme/once") == true, "\(String(describing: error))")
        let client = TestClient(server)
        #expect(try await client.request("acme/once")["result"]?["which"] == "first")
        // Names that only differ in bytes are different methods and can all be registered.
        for name in ["acme/Once", "acme/once ", "acme/onc\u{E9}", "acme/once\u{301}", "acme/once\u{200B}"] {
            #expect(throws: Never.self) { try server.register(method: name) { _, _ in ["which": .string(name)] } }
        }
        for name in ["acme/Once", "acme/once ", "acme/onc\u{E9}", "acme/once\u{301}", "acme/once\u{200B}"] {
            #expect(try await client.request(name)["result"]?["which"]?.stringValue.map { Array($0.utf8) } == Array(name.utf8))
        }
        #expect(try await client.request("acme/once")["result"]?["which"] == "first")
    }

    // MARK: Prompt arguments (fix 4)

    /// Declared arguments arrive under their exact names; arguments the prompt does not declare
    /// are still passed on; a look-alike of a declared name is neither.
    @Test func promptArgumentsReachTheHandlerUnderTheirExactNames() async throws {
        let seen = IndependentProtocolRecorder()
        let server = Server(name: "exact", version: "1")
        try server.register(
            prompt: PromptDefinition(name: "p", arguments: [PromptArgument(name: composed, required: true), PromptArgument(name: "K"), PromptArgument(name: "plain")])
        ) { arguments, _ in
            seen.note(arguments.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }.map { "\(Array($0.key.utf8))=\($0.value)" }.joined(separator: "&"))
            return PromptResult(messages: [])
        }
        let client = TestClient(server)
        func get(_ arguments: String) async throws -> JSONValue {
            client.send(#"{"jsonrpc":"2.0","id":"g","method":"prompts/get","params":{\#(IndependentProtocol.modernMetaText),"name":"p","arguments":\#(arguments)}}"#)
            return try await client.response(to: "g")
        }
        func key(_ name: String) -> String { "\(Array(name.utf8))" }

        seen.clear()
        #expect(try await get(#"{"caf\u00e9":"1","K":"2","plain":"3","extra":"4"}"#)["result"] != nil)
        let all: Set<String> = [key("K") + "=2", key(composed) + "=1", key("extra") + "=4", key("plain") + "=3"]
        #expect(Set(seen.entries.first?.split(separator: "&").map(String.init) ?? []) == all, "\(seen.entries)")

        // The look-alikes alone: the required argument is missing.
        #expect(try await get(#"{"cafe\u0301":"1"}"#).code == -32602)
        #expect(try await get(#"{"cafe\u0301":"1","\u212a":"2"}"#).code == -32602)
        // Next to the real ones, in either order: the real ones win, the look-alikes are dropped.
        for arguments in [#"{"caf\u00e9":"real","cafe\u0301":"fake","K":"real","\u212a":"fake"}"#, #"{"\u212a":"fake","cafe\u0301":"fake","K":"real","caf\u00e9":"real"}"#] {
            seen.clear()
            #expect(try await get(arguments)["result"] != nil)
            let real: Set<String> = [key("K") + "=real", key(composed) + "=real"]
            #expect(Set(seen.entries.first?.split(separator: "&").map(String.init) ?? []) == real, "\(seen.entries)")
        }
        // A look-alike of an optional argument that is absent does not stand in for it.
        seen.clear()
        #expect(try await get(#"{"caf\u00e9":"real","\u212a":"fake"}"#)["result"] != nil)
        #expect(seen.entries == [key(composed) + "=real"], "\(seen.entries)")
    }
}
