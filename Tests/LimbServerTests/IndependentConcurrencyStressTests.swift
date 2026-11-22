import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private struct ChaosError: Error {}

/// SplitMix64: reproducible randomness, so a failing seed can be replayed.
private struct Random: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private let formSchema: JSONObject = ["type": "object", "properties": ["v": ["type": "string"]]]

/// Thousands of requests with random handler behaviour and random cancellations, then the
/// invariants: one response per request, nothing after a response or a processed cancellation,
/// the parallelism limit, and every counter back at zero.
@Suite(.timeLimit(.minutes(10)))
struct IndependentConcurrencyStressTests {
    private static let limit = 3
    private static let queueLimit = 3

    private func chaosServer(active: ICMeter, gate: ICGate, holding: ICMeter) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = Self.limit
            configuration.budgets.maxQueuedRequests = Self.queueLimit
        }
        try server.register(tool: ToolDefinition(name: "chaos")) { arguments, context in
            active.enter()
            defer { active.leave() }
            let tag = arguments["tag"]?.stringValue ?? "?"
            switch arguments["mode"]?.intValue ?? 0 {
            case 0: return .text("ok \(tag)")
            case 1:
                for _ in 0..<5 { await Task.yield() }
                return .text("ok \(tag)")
            case 2:
                context.progress(1)
                context.log(.info, .string("log \(tag)"))
                await Task.yield()
                context.progress(2)
                return .text("ok \(tag)")
            case 3: throw ToolError("tool error \(tag)")
            case 4: throw ChaosError()
            case 5:
                try await Task.sleep(for: .milliseconds(2))
                return .text("ok \(tag)")
            case 6:
                // Ignores cancellation.
                for _ in 0..<30 { await Task.yield() }
                context.progress(1)
                return .text("ok \(tag)")
            case 7:
                Task.detached {
                    await Task.yield()
                    context.progress(9)
                    context.log(.error, .string("log \(tag)"))
                }
                return .text("ok \(tag)")
            case 8: throw MCPError.invalidParams("chaos \(tag)")
            default: throw CancellationError()
            }
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gate.wait()
            return .text("held")
        }
        return server
    }

    private func runChaos(seed: UInt64, requests: Int) async throws {
        var random = Random(seed: seed)
        let active = ICMeter()
        let gate = ICGate()
        let holding = ICMeter()
        let server = try chaosServer(active: active, gate: gate, holding: holding)
        let wire = ICWire(server)

        // The "writer": takes frames off the queue while the engine works, so some frames are
        // already written when a cancellation arrives and some are not.
        let stop = ICBox(false)
        let reader = Task {
            while !stop.value { _ = await wire.sink.next(timeout: .milliseconds(5)) }
        }

        var cancelMark: [Int: Int] = [:]
        var expectedResponses: [Int: Int] = [:]
        var modes: [Int: Int] = [:]
        var delayed: [(due: Int, index: Int)] = []
        func cancel(_ index: Int) {
            wire.cancel(RequestID("r\(index)"))
            cancelMark[index] = wire.sink.mark
        }
        for index in 0..<requests {
            let mode = random.below(10)
            modes[index] = mode
            let id = RequestID("r\(index)")
            let meta: JSONObject = ["progressToken": .string("p\(index)"), MetaKey.logLevel: "debug"]
            wire.call("chaos", ["mode": JSONValue(mode), "tag": .string("r\(index)")], id: id, meta: meta)
            expectedResponses[index] = 1
            switch random.below(8) {
            case 0: cancel(index)
            case 1:
                for _ in 0..<random.below(4) { await Task.yield() }
                cancel(index)
            case 2: delayed.append((index + 1 + random.below(40), index))
            case 3:
                // A second request under an id that may still be in flight. Whether it is
                // refused as a duplicate or served afresh, it gets exactly one response.
                wire.call("chaos", ["mode": 0, "tag": .string("r\(index)")], id: id, meta: meta)
                expectedResponses[index] = 2
            default: break
            }
            delayed.removeAll { entry in
                guard entry.due <= index else { return false }
                cancel(entry.index)
                return true
            }
            if index % 16 == 0 { await Task.yield() }
        }
        for entry in delayed { cancel(entry.index) }

        // Quiescence: every request that was not cancelled has its responses, no handler runs.
        func responseCounts() -> [Int: Int] {
            var counts: [Int: Int] = [:]
            for record in wire.sink.sent {
                guard let message = record.json, message["method"] == nil, let id = message["id"]?.stringValue,
                    let index = Int(id.dropFirst())
                else { continue }
                counts[index, default: 0] += 1
            }
            return counts
        }
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            let counts = responseCounts()
            let settled = expectedResponses.allSatisfy { index, expected in
                cancelMark[index] != nil || (counts[index] ?? 0) >= expected
            }
            if settled, active.current == 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(150))
        stop.set(true)
        await reader.value

        // MARK: Invariants
        let context = "seed \(seed)"
        #expect(active.current == 0, "\(context): handlers still running")
        #expect(active.peak <= Self.limit, "\(context): \(active.peak) handlers ran at once, the limit is \(Self.limit)")

        var responses: [Int: [Int]] = [:]  // request → positions of its responses
        var notifications: [Int: [Int]] = [:]  // request → positions of its progress and log frames
        var malformed = 0
        var foreign = 0
        var wrongContent = 0
        for record in wire.sink.sent {
            guard !record.frame.contains(0x0A), !record.frame.contains(0x0D), let message = record.json else {
                malformed += 1
                continue
            }
            if message["method"] == nil {
                guard let id = message["id"]?.stringValue, let index = Int(id.dropFirst()), index < requests else {
                    foreign += 1
                    continue
                }
                responses[index, default: []].append(record.index)
                // The response belongs to the request it names.
                let code = message.independentConcurrencyErrorCode
                let text = message.independentConcurrencyText
                let plausible: Bool
                if code == MCPError.Code.overloaded || code == -32600 {
                    plausible = true
                } else if expectedResponses[index] == 2, text == "ok r\(index)" {
                    plausible = true
                } else {
                    switch modes[index]! {
                    case 0, 1, 2, 5, 6, 7: plausible = text == "ok r\(index)"
                    case 3: plausible = text == "tool error r\(index)" && message["result"]?["isError"] == true
                    case 4, 9: plausible = code == -32603
                    default: plausible = code == -32602
                    }
                }
                if !plausible { wrongContent += 1 }
            } else if let token = message["params"]?["progressToken"]?.stringValue, let index = Int(token.dropFirst()) {
                notifications[index, default: []].append(record.index)
            } else if message["method"] == "notifications/message", let tag = message["params"]?["data"]?.stringValue,
                let index = Int(tag.dropFirst("log r".count))
            {
                notifications[index, default: []].append(record.index)
            } else {
                foreign += 1
            }
        }
        #expect(malformed == 0, "\(context): frames that are not one line of JSON")
        #expect(foreign == 0, "\(context): frames that belong to no request")
        #expect(wrongContent == 0, "\(context): responses whose content does not match their request")

        var unanswered = 0
        var answeredTooOften = 0
        var afterCancellation = 0
        var afterResponse = 0
        for index in 0..<requests {
            let positions = responses[index] ?? []
            let expected = expectedResponses[index]!
            if let mark = cancelMark[index] {
                if positions.count > 1 { answeredTooOften += 1 }
                if positions.contains(where: { $0 >= mark }) { afterCancellation += 1 }
                if (notifications[index] ?? []).contains(where: { $0 >= mark }) { afterCancellation += 1 }
            } else {
                if positions.count < expected { unanswered += 1 }
                if positions.count > expected { answeredTooOften += 1 }
            }
            // With a single request under the id, nothing follows its response.
            if expected == 1, let last = positions.last, (notifications[index] ?? []).contains(where: { $0 > last }) {
                afterResponse += 1
            }
        }
        #expect(unanswered == 0, "\(context): requests that were not cancelled and got no response")
        #expect(answeredTooOften == 0, "\(context): requests with more responses than requests")
        #expect(afterCancellation == 0, "\(context): frames queued after their request's cancellation was processed")
        #expect(afterResponse == 0, "\(context): notifications after the response of their request")
        // Frames are only ever withdrawn for cancelled requests.
        let withdrawnForLive = wire.sink.history.filter { record in
            guard record.withdrawn, case .string(let id)? = record.key, let index = Int(id.dropFirst()) else { return false }
            return cancelMark[index] == nil
        }
        #expect(withdrawnForLive.isEmpty, "\(context): frames of a request that was not cancelled were withdrawn")

        // MARK: Counters back at zero
        let before = wire.sink.mark
        for _ in 0..<Self.limit { wire.call("hold") }
        #expect(
            await independentConcurrencyEventually { holding.total == Self.limit },
            "\(context): only \(holding.total) of \(Self.limit) handler slots are free after the storm")
        for _ in 0..<Self.queueLimit { wire.call("hold") }
        #expect(wire.sink.mark == before, "\(context): the admission queue did not return to empty")
        let extra = wire.call("hold")
        let refusal = wire.sink.history.last?.json
        #expect(refusal?["id"] == extra.json)
        #expect(refusal?.independentConcurrencyErrorCode == MCPError.Code.overloaded)
        gate.open()
        let total = Self.limit + Self.queueLimit
        #expect(
            await independentConcurrencyEventually(timeout: .seconds(30)) {
                wire.sink.history.filter { $0.index > before && $0.json?.independentConcurrencyText == "held" }.count == total
            }, "\(context): not every held request was answered")
        let connection = wire.connection
        #expect(await independentConcurrencyFinishes(within: .seconds(30)) { await connection.close(graceSeconds: 5) })
    }

    @Test(arguments: [UInt64(1), 2, 3, 4])
    func randomRequestsAndCancellationsKeepEveryInvariant(seed: UInt64) async throws {
        // A fresh seed every run; a failure names it, and `fixedSeedsKeepEveryInvariant` can replay it.
        try await runChaos(seed: seed &+ UInt64.random(in: 0..<1_000_000) &* 16, requests: 2500)
    }

    @Test func fixedSeedsKeepEveryInvariant() async throws {
        for seed in [UInt64(11), 12] { try await runChaos(seed: seed, requests: 2000) }
    }

    /// The legacy input flow under the same treatment: calls that ask the client, answers in
    /// random order, client errors, calls cancelled while they wait.
    @Test func legacyInputUnderRandomAnswersErrorsAndCancellations() async throws {
        var random = Random(seed: 77)
        let live = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 16
            configuration.budgets.maxQueuedRequests = 5000
        }
        try server.register(tool: ToolDefinition(name: "ask")) { arguments, context in
            live.enter()
            defer { live.leave() }
            let tag = arguments["tag"]?.stringValue ?? "?"
            let answers = try await context.input([
                "one": .elicit(ElicitRequest(message: "\(tag) one", requestedSchema: formSchema)),
                "two": .elicit(ElicitRequest(message: "\(tag) two", requestedSchema: formSchema)),
            ])
            guard case .elicit(let one) = answers["one"], case .elicit(let two) = answers["two"] else { return .error("incomplete") }
            return .text("\(tag): \(one.content?["v"]?.stringValue ?? "-") \(two.content?["v"]?.stringValue ?? "-")")
        }
        let wire = ICWire(server, modern: false)
        try await wire.initialize(capabilities: ["elicitation": [:]])
        let calls = 600
        for index in 0..<calls { wire.call("ask", ["tag": .string("c\(index)")], id: RequestID(index)) }

        enum Fate { case answer, clientError, cancelNow, abandonThenCancel }
        var fates: [Int: Fate] = [:]
        var cancelMark: [Int: Int] = [:]
        var responses: [Int: [JSONValue]] = [:]
        var serverRequests: [JSONValue: Int] = [:]  // server request id → call
        var answeredRequests: Set<JSONValue> = []
        var withdrawn: Set<JSONValue> = []
        var abandoned: [Int] = []
        func settled() -> Bool {
            (0..<calls).allSatisfy { index in cancelMark[index] != nil || responses[index] != nil }
        }
        while !settled() {
            guard let record = await wire.sink.next(timeout: .milliseconds(200)) else {
                // Nothing moves any more: cancel the calls whose requests were left unanswered.
                if abandoned.isEmpty { break }
                for index in abandoned {
                    wire.cancel(RequestID(index))
                    cancelMark[index] = wire.sink.mark
                }
                abandoned = []
                continue
            }
            let message = try #require(record.json)
            if message["method"] == "elicitation/create" {
                let text = try #require(message["params"]?["message"]?.stringValue)
                let index = try #require(Int(text.dropFirst().prefix { $0.isNumber }))
                let requestID = try #require(message["id"])
                #expect(serverRequests[requestID] == nil, "the server reused request id \(requestID)")
                serverRequests[requestID] = index
                if cancelMark[index] != nil { continue }
                let fate = fates[index] ?? [Fate.answer, .answer, .answer, .answer, .clientError, .cancelNow, .abandonThenCancel][random.below(7)]
                fates[index] = fate
                switch fate {
                case .answer:
                    answeredRequests.insert(requestID)
                    wire.send(["jsonrpc": "2.0", "id": requestID, "result": ["action": "accept", "content": ["v": .string(String(text.suffix(3)))]]])
                case .clientError:
                    answeredRequests.insert(requestID)
                    wire.send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32000, "message": "client failed"]])
                case .cancelNow:
                    wire.cancel(RequestID(index))
                    cancelMark[index] = wire.sink.mark
                case .abandonThenCancel:
                    if !abandoned.contains(index) { abandoned.append(index) }
                }
            } else if message["method"] == "notifications/cancelled" {
                withdrawn.insert(message["params"]?["requestId"] ?? .null)
            } else if let index = message["id"]?.intValue {
                responses[index, default: []].append(message)
                if let mark = cancelMark[index] {
                    #expect(record.index < mark, "call \(index) was answered after its cancellation")
                }
            } else {
                Issue.record("unexpected frame \(record.text)")
            }
        }
        #expect(settled(), "some calls were neither answered nor cancelled")
        #expect(await independentConcurrencyEventually { live.current == 0 }, "\(live.current) handlers are still suspended")
        try? await Task.sleep(for: .milliseconds(100))
        while let record = await wire.sink.next(timeout: .milliseconds(20)) {
            if record.json?["method"] == "notifications/cancelled" { withdrawn.insert(record.json?["params"]?["requestId"] ?? .null) }
        }
        for index in 0..<calls {
            let answers = responses[index] ?? []
            switch fates[index] {
            case .answer?:
                #expect(answers.count == 1, "call \(index)")
                #expect(answers.first?.independentConcurrencyText == "c\(index): one two", "call \(index)")
            case .clientError?:
                #expect(answers.count == 1, "call \(index)")
                #expect(answers.first?.independentConcurrencyErrorCode != nil || answers.first?["result"]?["isError"] == true, "call \(index)")
            case .cancelNow?, .abandonThenCancel?:
                #expect(answers.isEmpty, "call \(index) was cancelled and still answered")
            case nil:
                Issue.record("call \(index) never asked the client")
            }
        }
        // Every request the server sent was either answered by the client or withdrawn by the server.
        let dangling = serverRequests.keys.filter { !answeredRequests.contains($0) && !withdrawn.contains($0) }
        #expect(dangling.isEmpty, "\(dangling.count) requests to the client were neither answered nor withdrawn")
        // The server never withdraws a request the client has not been sent.
        #expect(withdrawn.isSubset(of: Set(serverRequests.keys)))
        #expect(wire.sink.history.allSatisfy { !$0.frame.contains(0x0A) && $0.json != nil })
    }
}
