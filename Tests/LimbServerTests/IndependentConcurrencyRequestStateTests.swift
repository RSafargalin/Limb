import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let inputs: JSONObject = ["elicitation": [:], "sampling": [:], "roots": [:]]
private let formSchema: JSONObject = ["type": "object", "properties": ["v": ["type": "string"]]]
private func accepted(_ value: String) -> JSONValue { ["action": "accept", "content": ["v": .string(value)]] }

private func key(_ seed: UInt8) -> [UInt8] { (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &* 31 &+ $0) } }

/// `RequestStateError` cannot be created outside Limb (its initializer is internal), so custom
/// sealers need an error type of their own.
private struct SealerFailure: Error {
    var reason: String
}

/// Passes the payload through in the clear, so tests can read and forge what is inside.
private struct TransparentSealer: RequestStateSealer {
    func seal(_ plaintext: [UInt8]) throws -> String { "clear:" + String(decoding: plaintext, as: UTF8.self) }
    func open(_ sealed: String) throws -> [UInt8] {
        guard sealed.hasPrefix("clear:") else { throw SealerFailure(reason: "not mine") }
        return Array(sealed.dropFirst("clear:".count).utf8)
    }
}

private struct FailingSealer: RequestStateSealer {
    var failSeal: Bool
    func seal(_ plaintext: [UInt8]) throws -> String {
        if failSeal { throw SealerFailure(reason: "no key available") }
        return "ok"
    }
    func open(_ sealed: String) throws -> [UInt8] { throw SealerFailure(reason: "cannot open") }
}

/// Registers tools that need two rounds of input and count how often their handlers run.
private func makeServer(runs: ICMeter = ICMeter(), configure: (inout ServerConfiguration) -> Void = { _ in }) throws -> Server {
    let server = independentConcurrencyServer(configure)
    for name in ["steps", "twin"] {
        try server.register(
            tool: ToolDefinition(name: name, inputSchema: ["type": "object"])
        ) { arguments, context in
            runs.enter()
            let a = try await context.elicit("a", message: "A?", schema: formSchema)
            let b = try await context.elicit("b", message: "B?", schema: formSchema)
            return .text("\(name):\(a.content?["v"]?.stringValue ?? "-")\(b.content?["v"]?.stringValue ?? "-"):\(arguments.count)")
        }
    }
    try server.register(prompt: PromptDefinition(name: "twin")) { _, context in
        runs.enter()
        let a = try await context.elicit("a", message: "A?", schema: formSchema)
        return PromptResult(messages: [.user(a.content?["v"]?.stringValue ?? "-")])
    }
    try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "ic://doc/{id}", name: "doc")) { request, context in
        runs.enter()
        let a = try await context.elicit("a", message: "A?", schema: formSchema)
        return [.text(uri: request.uri, text: a.content?["v"]?.stringValue ?? "-")]
    }
    return server
}

private func issueState(
    _ wire: ICWire, tool: String = "steps", arguments: JSONObject = ["x": 1, "y": ["p": true, "q": [1, 2]]]
) async throws -> String {
    let response = try await wire.request("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
    #expect(response["result"]?["resultType"] == "input_required")
    return try #require(response["result"]?["requestState"]?.stringValue)
}

private func retry(
    _ wire: ICWire, state: JSONValue, tool: String = "steps",
    arguments: JSONObject = ["x": 1, "y": ["p": true, "q": [1, 2]]], meta: JSONObject? = nil
) async throws -> JSONValue {
    try await wire.request(
        "tools/call",
        ["name": .string(tool), "arguments": .object(arguments), "requestState": state, "inputResponses": ["a": accepted("A")]],
        meta: meta)
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyRequestStateSealerTests {
    @Test func sealedStatesOpenToTheirPlaintextAndNeverRepeat() throws {
        let sealer = AEADRequestStateSealer(key: key(1))
        var seen: Set<String> = []
        for length in [0, 1, 2, 3, 31, 32, 33, 255, 256, 257, 4096, 100_000] {
            let plaintext = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            for _ in 0..<3 {
                let sealed = try sealer.seal(plaintext)
                #expect(seen.insert(sealed).inserted, "two seals of \(length) bytes were identical")
                #expect(try sealer.open(sealed) == plaintext)
                // The client must be able to echo it in a JSON string and a URL alike.
                #expect(sealed.utf8.allSatisfy { byte in
                    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                        || byte == 0x2D || byte == 0x5F
                })
            }
        }
        // The plaintext is not readable in the sealed form.
        let secret = Array("the journal holds a password: hunter2".utf8)
        let sealed = try sealer.seal(secret)
        let raw = try #require(Base64.decode(sealed))
        #expect(!raw.indices.contains { index in raw[index...].starts(with: Array("hunter2".utf8)) })
    }

    @Test func everySingleBitFlipIsRejected() async throws {
        let sealer = AEADRequestStateSealer(key: key(2), keyID: "prod-2026")
        let plaintext = Array(#"{"v":1,"exp":1900000000,"fp":"abc","j":{"a":{"action":"accept"}}}"#.utf8)
        let sealed = try sealer.seal(plaintext)
        let raw = try #require(Base64.decode(sealed))
        var accepted = 0
        for index in raw.indices {
            await Task.yield()
            for bit in 0..<8 {
                var tampered = raw
                tampered[index] ^= 1 << UInt8(bit)
                let text = Base64.encode(tampered, urlSafe: true)
                if (try? sealer.open(text)) != nil { accepted += 1 }
            }
        }
        #expect(accepted == 0, "\(accepted) of \(raw.count * 8) single-bit changes passed verification")
    }

    /// A changed character either fails verification or is another spelling of the very same
    /// bytes (base64 has spare bits); it never opens to a different plaintext.
    @Test func noChangedCharacterOpensToADifferentPlaintext() async throws {
        let sealer = AEADRequestStateSealer(key: key(3))
        let plaintext = Array("state that decides what the handler does".utf8)
        let sealed = try sealer.seal(plaintext)
        let original = try #require(Base64.decode(sealed))
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+/=".utf8)
        var characters = Array(sealed.utf8)
        var differentPlaintext = 0
        var acceptedWithOtherBytes = 0
        for index in characters.indices {
            await Task.yield()
            let saved = characters[index]
            for replacement in alphabet where replacement != saved {
                characters[index] = replacement
                let text = String(decoding: characters, as: UTF8.self)
                if let opened = try? sealer.open(text) {
                    if opened != plaintext { differentPlaintext += 1 }
                    if Base64.decode(text) != original { acceptedWithOtherBytes += 1 }
                }
            }
            characters[index] = saved
        }
        #expect(differentPlaintext == 0)
        #expect(acceptedWithOtherBytes == 0, "a state with different bytes passed verification")
    }

    @Test func truncatedAndExtendedStatesAreRejected() throws {
        let sealer = AEADRequestStateSealer(key: key(4))
        let plaintext = Array("payload".utf8)
        let sealed = try sealer.seal(plaintext)
        let raw = try #require(Base64.decode(sealed))
        for length in 0..<raw.count {
            #expect((try? sealer.open(Base64.encode(raw[..<length], urlSafe: true))) == nil, "truncated to \(length) bytes")
        }
        for length in 0..<sealed.utf8.count {
            #expect((try? sealer.open(String(sealed.prefix(length)))) == nil, "truncated to \(length) characters")
        }
        for extra in [[UInt8(0)], [0x41], Array(repeating: UInt8(0), count: 16), raw] {
            #expect((try? sealer.open(Base64.encode(raw + extra, urlSafe: true))) == nil, "extended by \(extra.count) bytes")
            #expect((try? sealer.open(Base64.encode(extra + raw, urlSafe: true))) == nil, "prefixed by \(extra.count) bytes")
        }
        for garbage in ["", "A", "=", "====", "not base64 at all!", "\u{0}", sealed + "!", " " + sealed, sealed + "\n", "AAAA", "AQ", "AQFw"] {
            #expect((try? sealer.open(garbage)) == nil, "\(garbage.debugDescription)")
        }
    }

    @Test func onlyAKnownKeyOpensAState() throws {
        let current = AEADRequestStateSealer(key: key(5), keyID: "k2", previous: ["k1": key(6)])
        let old = AEADRequestStateSealer(key: key(6), keyID: "k1")
        let stranger = AEADRequestStateSealer(key: key(7), keyID: "k1")
        let sameNameOtherKey = AEADRequestStateSealer(key: key(8), keyID: "k2")
        let plaintext = Array("rotation".utf8)
        // Rotation: a state sealed under the previous key is still accepted.
        #expect(try current.open(try old.seal(plaintext)) == plaintext)
        // The old server does not know the new key.
        #expect((try? old.open(try current.seal(plaintext))) == nil)
        // The same key identifier with other key material is not enough.
        #expect((try? current.open(try stranger.seal(plaintext))) == nil)
        #expect((try? current.open(try sameNameOtherKey.seal(plaintext))) == nil)
        // Two process-lifetime sealers never accept each other's states.
        let first = AEADRequestStateSealer.ephemeral()
        let second = AEADRequestStateSealer.ephemeral()
        #expect(try first.open(try first.seal(plaintext)) == plaintext)
        #expect((try? second.open(try first.seal(plaintext))) == nil)
        // Key identifiers of every length the format allows.
        for length in [0, 1, 17, 255] {
            let sealer = AEADRequestStateSealer(key: key(9), keyID: String(repeating: "k", count: length))
            #expect(try sealer.open(try sealer.seal(plaintext)) == plaintext, "key id of \(length) bytes")
        }
    }

    @Test func aHugeForgedStateIsRejectedQuickly() async throws {
        let sealer = AEADRequestStateSealer(key: key(10))
        let genuine = try sealer.seal(Array("x".utf8))
        let huge = String(repeating: "A", count: 8 << 20)
        let rejected = await independentConcurrencyValue(within: .seconds(30)) {
            (try? sealer.open(huge)) == nil && (try? sealer.open(genuine + huge)) == nil
        }
        #expect(rejected == true)
    }

    @Test func sealingAndOpeningFromManyTasksAtOnce() async throws {
        let sealer = AEADRequestStateSealer(key: key(11))
        let failures = ICMeter()
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<16 {
                group.addTask {
                    for round in 0..<200 {
                        let plaintext = Array("task \(task) round \(round)".utf8)
                        guard let sealed = try? sealer.seal(plaintext), (try? sealer.open(sealed)) == plaintext else {
                            failures.enter()
                            continue
                        }
                    }
                }
            }
        }
        #expect(failures.total == 0)
    }
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyRequestStateTests {
    @Test func aGenuineStateIsAcceptedAndCompletes() async throws {
        let runs = ICMeter()
        let wire = ICWire(try makeServer(runs: runs), capabilities: inputs)
        let state = try await issueState(wire)
        let second = try await retry(wire, state: .string(state))
        #expect(second["result"]?["resultType"] == "input_required")
        #expect(second["result"]?["inputRequests"]?.objectValue?.map(\.key) == ["b"])
        let final = try await wire.request(
            "tools/call",
            [
                "name": "steps", "arguments": ["x": 1, "y": ["p": true, "q": [1, 2]]],
                "requestState": second["result"]!["requestState"]!, "inputResponses": ["b": accepted("B")],
            ])
        #expect(final.independentConcurrencyText == "steps:AB:2")
        #expect(runs.total == 3)
    }

    @Test func everyBitFlipOfARealStateIsRejectedBeforeTheHandlerRuns() async throws {
        let runs = ICMeter()
        let wire = ICWire(try makeServer(runs: runs), capabilities: inputs)
        let state = try await issueState(wire)
        let raw = try #require(Base64.decode(state))
        let runsBefore = runs.total
        var wrong: [String] = []
        for index in raw.indices {
            await Task.yield()  // a long loop that never suspends would hold a thread of the pool
            for bit in 0..<8 {
                var tampered = raw
                tampered[index] ^= 1 << UInt8(bit)
                let response = try await retry(wire, state: .string(Base64.encode(tampered, urlSafe: true)))
                if response.independentConcurrencyErrorCode != -32602 { wrong.append("byte \(index) bit \(bit): \(response)") }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) tampered states were not rejected with -32602; first: \(wrong.first ?? "")")
        // "проверка — до вызова обработчика": no tampered state ever reached user code.
        #expect(runs.total == runsBefore)
        // The genuine state still works afterwards.
        #expect(try await retry(wire, state: .string(state))["result"]?["resultType"] == "input_required")
    }

    @Test func truncatedExtendedAndForeignStatesAreRejected() async throws {
        let runs = ICMeter()
        let wire = ICWire(try makeServer(runs: runs), capabilities: inputs)
        let state = try await issueState(wire)
        let runsBefore = runs.total
        var candidates: [JSONValue] = []
        for length in stride(from: 0, to: state.utf8.count, by: 1) { candidates.append(.string(String(state.prefix(length)))) }
        candidates += [
            .string(state + "A"), .string(state + state), .string("A" + state), .string(state + " "), .string(" " + state),
            .string(String(state.reversed())), .string(state.uppercased()), .string(state.lowercased()),
            .string("clear:{\"v\":1,\"exp\":4102444800,\"fp\":\"\",\"j\":{}}"), .string("null"), .string("{}"),
            5, 0, -1, 1.5, true, false, [1], ["a": 1], .array([.string(state)]), ["state": .string(state)],
        ]
        for candidate in candidates {
            await Task.yield()
            let response = try await retry(wire, state: candidate)
            #expect(response.independentConcurrencyErrorCode == -32602, "\(candidate)")
        }
        #expect(runs.total == runsBefore)
    }

    @Test func aStateIsBoundToTheRequestItWasIssuedFor() async throws {
        let runs = ICMeter()
        let wire = ICWire(try makeServer(runs: runs), capabilities: inputs)
        let arguments: JSONObject = ["x": 1, "y": ["p": true, "q": [1, 2]], "s": "caf\u{e9}"]
        let state = JSONValue.string(try await issueState(wire, arguments: arguments))

        let reordered: JSONObject = ["s": "caf\u{e9}", "y": ["q": [1, 2], "p": true], "x": 1]
        #expect(try await retry(wire, state: state, arguments: reordered)["result"]?["resultType"] == "input_required")
        let otherMeta: JSONObject = ["progressToken": "another", "traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"]
        #expect(try await retry(wire, state: state, arguments: arguments, meta: otherMeta)["result"]?["resultType"] == "input_required")

        let runsBefore = runs.total
        let variations: [(String, JSONObject)] = [
            ("another value", ["x": 2, "y": ["p": true, "q": [1, 2]], "s": "caf\u{e9}"]),
            ("another nested value", ["x": 1, "y": ["p": false, "q": [1, 2]], "s": "caf\u{e9}"]),
            ("array order", ["x": 1, "y": ["p": true, "q": [2, 1]], "s": "caf\u{e9}"]),
            ("an extra argument", ["x": 1, "y": ["p": true, "q": [1, 2]], "s": "caf\u{e9}", "z": .null]),
            ("a missing argument", ["x": 1, "y": ["p": true, "q": [1, 2]]]),
            ("no arguments", [:]),
            ("a string for a number", ["x": "1", "y": ["p": true, "q": [1, 2]], "s": "caf\u{e9}"]),
            // Canonically equivalent Unicode is still a different JSON string.
            ("a decomposed character", ["x": 1, "y": ["p": true, "q": [1, 2]], "s": "cafe\u{301}"]),
        ]
        for (name, changed) in variations {
            let response = try await retry(wire, state: state, arguments: changed)
            #expect(response.independentConcurrencyErrorCode == -32602, "replayed with \(name)")
        }
        // Another tool with the same arguments, another method with the same name.
        #expect(try await retry(wire, state: state, tool: "twin", arguments: arguments).independentConcurrencyErrorCode == -32602)
        let prompt = try await wire.request("prompts/get", ["name": "twin", "requestState": state, "inputResponses": ["a": accepted("A")]])
        #expect(prompt.independentConcurrencyErrorCode == -32602)
        let resource = try await wire.request("resources/read", ["uri": "ic://doc/1", "requestState": state, "inputResponses": ["a": accepted("A")]])
        #expect(resource.independentConcurrencyErrorCode == -32602)
        #expect(runs.total == runsBefore)

        // And between two resources of one template.
        let first = try await wire.request("resources/read", ["uri": "ic://doc/1"])
        let docState = try #require(first["result"]?["requestState"])
        let other = try await wire.request("resources/read", ["uri": "ic://doc/2", "requestState": docState, "inputResponses": ["a": accepted("A")]])
        #expect(other.independentConcurrencyErrorCode == -32602)
        let same = try await wire.request("resources/read", ["uri": "ic://doc/1", "requestState": docState, "inputResponses": ["a": accepted("A")]])
        #expect(same["result"]?["contents"]?[0]?["text"] == "A")
    }

    @Test func aStateExpires() async throws {
        let runs = ICMeter()
        let lifetime = 3
        let wire = ICWire(try makeServer(runs: runs) { $0.requestStateLifetimeSeconds = lifetime }, capabilities: inputs)
        let clock = ContinuousClock()
        let beforeIssue = clock.now
        let state = JSONValue.string(try await issueState(wire))
        let afterIssue = clock.now
        // Fresh: accepted. Only asserted if this test was not stalled past the lifetime meanwhile.
        let fresh = try await retry(wire, state: state)
        if clock.now - beforeIssue < .seconds(lifetime) {
            #expect(fresh["result"]?["resultType"] == "input_required")
        }
        // More than a second past its lifetime: refused, before the handler runs.
        try await Task.sleep(until: afterIssue + .seconds(lifetime) + .milliseconds(1300), clock: clock)
        let runsBefore = runs.total
        #expect(try await retry(wire, state: state).independentConcurrencyErrorCode == -32602)
        #expect(runs.total == runsBefore)

        let expired = ICWire(try makeServer { $0.requestStateLifetimeSeconds = -5 }, capabilities: inputs)
        let dead = JSONValue.string(try await issueState(expired))
        #expect(try await retry(expired, state: dead).independentConcurrencyErrorCode == -32602)
    }

    @Test func statesOfOtherServersNeedTheSameKey() async throws {
        // Two instances with their own process-lifetime keys (the stdio default).
        let first = ICWire(try makeServer(), capabilities: inputs)
        let second = ICWire(try makeServer(), capabilities: inputs)
        let foreign = JSONValue.string(try await issueState(first))
        #expect(try await retry(second, state: foreign).independentConcurrencyErrorCode == -32602)
        #expect(try await retry(first, state: foreign)["result"]?["resultType"] == "input_required")

        // Two instances behind a load balancer share a key: either one can finish the request,
        // because "the server processing the retry does not need any information beyond what is
        // directly present in the retry request".
        let shared = key(42)
        let a = ICWire(try makeServer { $0.requestStateSealer = AEADRequestStateSealer(key: shared, keyID: "s") }, capabilities: inputs)
        let b = ICWire(try makeServer { $0.requestStateSealer = AEADRequestStateSealer(key: shared, keyID: "s") }, capabilities: inputs)
        let roundOne = JSONValue.string(try await issueState(a))
        let roundTwo = try await retry(b, state: roundOne)
        #expect(roundTwo["result"]?["resultType"] == "input_required")
        let final = try await a.request(
            "tools/call",
            [
                "name": "steps", "arguments": ["x": 1, "y": ["p": true, "q": [1, 2]]],
                "requestState": roundTwo["result"]!["requestState"]!, "inputResponses": ["b": accepted("B")],
            ])
        #expect(final.independentConcurrencyText == "steps:AB:2")

        // Another key under the same name is refused; a rotated-out key is still accepted.
        let wrong = ICWire(try makeServer { $0.requestStateSealer = AEADRequestStateSealer(key: key(43), keyID: "s") }, capabilities: inputs)
        #expect(try await retry(wrong, state: roundOne).independentConcurrencyErrorCode == -32602)
        let rotated = ICWire(
            try makeServer { $0.requestStateSealer = AEADRequestStateSealer(key: key(44), keyID: "t", previous: ["s": shared]) },
            capabilities: inputs)
        #expect(try await retry(rotated, state: roundOne)["result"]?["resultType"] == "input_required")
    }

    @Test func anAbsurdlyLargeStateIsRejectedAndTheServerStaysResponsive() async throws {
        let runs = ICMeter()
        let wire = ICWire(try makeServer(runs: runs), capabilities: inputs)
        let state = try await issueState(wire)
        let runsBefore = runs.total
        for huge in [String(repeating: "A", count: 4 << 20), state + String(repeating: "A", count: 4 << 20)] {
            let response = try await retry(wire, state: .string(huge))
            #expect(response.independentConcurrencyErrorCode == -32602)
            // The error does not echo megabytes back.
            #expect((response["error"]?.encoded().count ?? 0) < 2000)
        }
        #expect(runs.total == runsBefore)
        #expect(try await wire.request("server/discover")["result"] != nil)
    }

    /// The payload inside the seal is checked too: a sealer is replaceable (key rotation, another
    /// algorithm), so what it returns is still input that came through the client.
    @Test func aPayloadWithMissingOrWrongFieldsIsRejected() async throws {
        let runs = ICMeter()
        let wire = ICWire(try makeServer(runs: runs) { $0.requestStateSealer = TransparentSealer() }, capabilities: inputs)
        let state = try await issueState(wire)
        #expect(state.hasPrefix("clear:"))
        let payload = try #require(try JSON.parse(Array(state.dropFirst("clear:".count).utf8)).objectValue)
        // The genuine payload, re-encoded, is accepted: the forgeries below differ from it in one thing.
        func seal(_ object: JSONObject) -> JSONValue { .string("clear:" + String(decoding: JSONValue.object(object).encoded(), as: UTF8.self)) }
        #expect(try await retry(wire, state: seal(payload))["result"]?["resultType"] == "input_required")

        let runsBefore = runs.total
        var forgeries: [(String, JSONValue)] = []
        for (name, _) in payload {
            var object = payload
            object[name] = nil
            forgeries.append(("without \(name)", seal(object)))
            for wrong: JSONValue in [.null, "text", 1.5, true, [1], ["k": "v"], -1, 1e300] where wrong != payload[name] {
                // Skip replacements that are legitimate values for that member.
                if case .object = payload[name], case .object = wrong { continue }
                if payload[name]?.stringValue != nil, wrong.stringValue != nil { continue }
                object[name] = wrong
                forgeries.append(("\(name) = \(wrong)", seal(object)))
            }
        }
        forgeries += [
            ("not JSON", "clear:{"), ("an array", "clear:[]"), ("a string", "clear:\"x\""), ("empty", "clear:"),
            ("null", "clear:null"),
        ]
        var accepted: [String] = []
        for (name, forged) in forgeries {
            let response = try await retry(wire, state: forged)
            if response.independentConcurrencyErrorCode != -32602 { accepted.append(name) }
        }
        // A wrong string for the fingerprint or an out-of-range number for the expiry are covered
        // by the dedicated tests; everything structurally wrong must be refused here.
        #expect(accepted.isEmpty, "accepted forged payloads: \(accepted)")
        #expect(runs.total == runsBefore)
    }

    @Test func aSealerThatFailsNeverLeaksAnUnsealedStateOrCrashes() async throws {
        let diagnostics = ICBox<[String]>([])
        let failing = ICWire(
            try makeServer { configuration in
                configuration.requestStateSealer = FailingSealer(failSeal: true)
                configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
            }, capabilities: inputs)
        let response = try await failing.request("tools/call", ["name": "steps"])
        // No state can be issued: an internal error, with nothing about the key in it.
        #expect(response.independentConcurrencyErrorCode == -32603)
        #expect(response["result"] == nil)
        #expect(response["error"]?["message"]?.stringValue?.contains("key") == false)
        #expect(!diagnostics.value.isEmpty)

        let closed = ICWire(try makeServer { $0.requestStateSealer = FailingSealer(failSeal: false) }, capabilities: inputs)
        let first = try await closed.request("tools/call", ["name": "steps"])
        #expect(first["result"]?["requestState"] == "ok")
        #expect(try await retry(closed, state: "ok", arguments: [:]).independentConcurrencyErrorCode == -32602)
    }

    @Test func theJournalOfAnswersIsBounded() async throws {
        let wire = ICWire(try makeServer(), capabilities: inputs)
        let state = JSONValue.string(try await issueState(wire))
        let big = String(repeating: "j", count: 3 << 20)
        let response = try await wire.request(
            "tools/call",
            [
                "name": "steps", "arguments": ["x": 1, "y": ["p": true, "q": [1, 2]]], "requestState": state,
                "inputResponses": ["a": accepted(big)],
            ])
        let issued = response["result"]?["requestState"]?.stringValue?.utf8.count ?? 0
        #expect(
            issued <= (1 << 20) * 4 / 3 + 4096,
            "a 3 MiB answer was carried into a requestState of \(issued) bytes; the journal limit is 1 MiB")
        if issued == 0 {
            #expect(response["result"]?["isError"] == true || response.independentConcurrencyErrorCode != nil)
        }
    }
}
