import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private struct ICUnexpected: Error {}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyOrderingTests {
    @Test(arguments: [ProtocolVersion.v2026_07_28, .v2025_11_25, .v2025_03_26])
    func nothingIsSentForARequestAfterItsResponse(_ version: ProtocolVersion) async throws {
        let gate = ICGate()
        let lateDone = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "leaky")) { _, context in
            context.progress(1)
            // Unstructured tasks that outlive the handler and keep using its context.
            Task.detached {
                await gate.wait()
                context.progress(2)
                context.log(.emergency, "after the response")
                lateDone.enter()
            }
            Task {
                await gate.wait()
                context.progress(3, total: 3, message: "late")
                context.log(.error, ["late": true], logger: "child")
                lateDone.enter()
            }
            return .text("done")
        }
        let wire: ICWire
        if version == .latest {
            wire = ICWire(server)
        } else {
            wire = ICWire(server, modern: false)
            try await wire.initialize(version: version)
        }
        let id = wire.call("leaky", meta: ["progressToken": 99, MetaKey.logLevel: "debug"])
        let progress = try await wire.next()
        #expect(progress["method"] == "notifications/progress")
        #expect(progress["params"]?["progressToken"] == 99)
        let response = try await wire.next()
        #expect(response["id"] == id.json)
        #expect(response.independentConcurrencyText == "done")
        let mark = wire.sink.mark
        gate.open()
        #expect(await independentConcurrencyEventually { lateDone.total == 2 })
        #expect(await wire.isSilent(for: .milliseconds(100)))
        #expect(wire.sink.history.count == mark, "frames were queued for a request that was already answered")
    }

    @Test func progressIncreasesAndEchoesTheTokenExactly() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "steps")) { _, context in
            for value in [1, 1, 0.5, 2, Double.nan, Double.infinity, -Double.infinity, 3, 2.5, 3] {
                context.progress(value, total: 3)
            }
            return .text("done")
        }
        let wire = ICWire(server)
        let tokens: [String] = [#""tok""#, "7", "0", "-3", "9007199254740993", #""""#, #""7""#]
        for (index, token) in tokens.enumerated() {
            let mark = wire.sink.mark
            wire.send(
                #"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"steps","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":\#(token)}}}"#)
            _ = try await wire.response(to: RequestID(index))
            let frames = wire.sink.history.filter { $0.index >= mark }
            let expectedToken = try JSON.parse(Array(token.utf8))
            let progress = frames.compactMap(\.json).filter { $0["method"] == "notifications/progress" }
            // 1, then 2, then 3: equal and smaller values are dropped, as are NaN and infinities.
            #expect(progress.map { $0["params"]?["progress"]?.doubleValue } == [1, 2, 3], "token \(token)")
            #expect(progress.allSatisfy { $0["params"]?["progressToken"] == expectedToken }, "token \(token)")
            // The token travels back with the same JSON type and the same digits.
            for frame in frames where frame.json?["method"] == "notifications/progress" {
                #expect(frame.text.contains(#""progressToken":\#(token)"#), "token \(token) in \(frame.text)")
            }
            // Progress precedes the response.
            #expect(frames.last?.json?["id"] == JSONValue(index))
        }
    }

    @Test func noProgressWithoutAValidToken() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "steps")) { _, context in
            context.progress(1)
            context.progress(2)
            return .text("done")
        }
        let wire = ICWire(server)
        // "Progress tokens MUST be a string or integer value": other JSON types are not tokens.
        let invalid: [JSONValue?] = [nil, .null, true, ["a": 1], [1]]
        for token in invalid {
            let mark = wire.sink.mark
            var meta = JSONObject()
            if let token { meta["progressToken"] = token }
            _ = try await wire.request("tools/call", ["name": "steps"], meta: meta)
            #expect(wire.sink.history.count == mark + 1, "token \(String(describing: token))")
        }
    }

    @Test func concurrentRequestsKeepTheirOwnTokensAndOrder() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "steps")) { _, context in
            for value in 1...5 {
                context.progress(Double(value))
                await Task.yield()
            }
            return .text("done")
        }
        let wire = ICWire(server)
        let count = 30  // fewer than the default limit of concurrent handlers: none is refused
        for index in 0..<count { wire.call("steps", id: RequestID(index), meta: ["progressToken": .string("token-\(index)")]) }
        var seen: [Int: [Double]] = [:]
        var answered: Set<Int> = []
        while answered.count < count {
            let message = try await wire.next()
            if let id = message["id"]?.intValue {
                #expect(!answered.contains(id), "request \(id) answered twice")
                answered.insert(id)
                // Everything the handler reported arrived before the response, in order.
                #expect(seen[id] == [1, 2, 3, 4, 5], "request \(id)")
            } else {
                let token = try #require(message["params"]?["progressToken"]?.stringValue)
                let id = try #require(Int(token.dropFirst("token-".count)))
                #expect(!answered.contains(id), "progress for \(id) after its response")
                seen[id, default: []].append(try #require(message["params"]?["progress"]?.doubleValue))
            }
        }
        #expect(await wire.isSilent())
    }

    @Test func everyRequestGetsExactlyOneResponseWhateverTheHandlerDoes() async throws {
        // Room for every request: overload is not what this test is about.
        let server = independentConcurrencyServer { $0.budgets.maxQueuedRequests = 10_000 }
        try server.register(tool: ToolDefinition(name: "ok")) { _, _ in .text("ok") }
        try server.register(tool: ToolDefinition(name: "toolError")) { _, _ in throw ToolError("bad input") }
        try server.register(tool: ToolDefinition(name: "protocolError")) { _, _ in
            throw MCPError(code: -32602, message: "nope", data: ["field": "x"])
        }
        try server.register(tool: ToolDefinition(name: "crash")) { _, _ in throw ICUnexpected() }
        try server.register(tool: ToolDefinition(name: "selfCancelled")) { _, _ in throw CancellationError() }
        try server.register(tool: ToolDefinition(name: "slowCrash")) { _, _ in
            for _ in 0..<20 { await Task.yield() }
            throw ICUnexpected()
        }
        try server.register(resource: ResourceDefinition(uri: "ic://crash", name: "crash")) { _, _ in throw ICUnexpected() }
        try server.register(prompt: PromptDefinition(name: "crash")) { _, _ in throw ICUnexpected() }
        try server.register(method: "custom/crash") { _, _ in throw ICUnexpected() }
        try server.register(method: "custom/ok") { _, _ in ["value": 1] }
        let wire = ICWire(server)
        let rounds = 40
        var expected: [RequestID: String] = [:]
        for _ in 0..<rounds {
            for name in ["ok", "toolError", "protocolError", "crash", "selfCancelled", "slowCrash"] {
                expected[wire.call(name)] = name
            }
            expected[wire.post("resources/read", ["uri": "ic://crash"])] = "resource"
            expected[wire.post("prompts/get", ["name": "crash"])] = "prompt"
            expected[wire.post("custom/crash")] = "customCrash"
            expected[wire.post("custom/ok")] = "customOK"
        }
        var answered: Set<RequestID> = []
        for _ in 0..<expected.count {
            let message = try await wire.next()
            let id = try #require(message["id"].flatMap(RequestID.init(json:)))
            let kind = try #require(expected[id])
            #expect(answered.insert(id).inserted, "\(kind) #\(id) answered twice")
            switch kind {
            case "ok": #expect(message.independentConcurrencyText == "ok")
            case "toolError":
                #expect(message["result"]?["isError"] == true)
                #expect(message.independentConcurrencyText == "bad input")
            case "protocolError":
                #expect(message.independentConcurrencyErrorCode == -32602)
                #expect(message["error"]?["data"]?["field"] == "x")
            case "customOK": #expect(message["result"]?["value"] == 1)
            case "selfCancelled":
                // The request was not cancelled by the client, so it must still be answered.
                #expect(message.independentConcurrencyErrorCode == -32603)
            default:
                #expect(message.independentConcurrencyErrorCode == -32603, "\(kind)")
                // Details of an unexpected failure stay with the operator.
                #expect(message["error"]?["message"]?.stringValue?.contains("ICUnexpected") == false)
            }
        }
        #expect(answered.count == expected.count)
        #expect(await wire.isSilent())
    }

    // MARK: Duplicate ids

    /// `basic/index.mdx` (2026-07-28): "The request ID MUST NOT match the ID of any other request
    /// the sender has issued and not yet received a response for." A client that does it anyway
    /// must not get the two requests confused: the second is refused, the first is untouched.
    @Test func duplicateOfARunningRequestIsRefusedAndTheOriginalIsUntouched() async throws {
        let gate = ICGate()
        let ran = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("original")
        }
        try server.register(tool: ToolDefinition(name: "count")) { _, _ in
            ran.enter()
            return .text("duplicate ran")
        }
        try server.register(resource: ResourceDefinition(uri: "ic://r", name: "r")) { _, _ in
            ran.enter()
            return []
        }
        let wire = ICWire(server)
        wire.call("hold", id: "dup")
        wire.call("count", id: "dup")
        let refusal = try await wire.next()
        #expect(refusal["id"] == "dup")
        #expect(refusal.independentConcurrencyErrorCode == -32600)
        wire.post("resources/read", ["uri": "ic://r"], id: "dup")
        #expect(try await wire.next().independentConcurrencyErrorCode == -32600)
        wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]], id: "dup")
        #expect(try await wire.next().independentConcurrencyErrorCode == -32600)
        #expect(ran.total == 0)
        gate.open()
        let response = try await wire.next()
        #expect(response["id"] == "dup")
        #expect(response.independentConcurrencyText == "original")
        #expect(await wire.isSilent())
        // The refused listen left no subscription behind.
        try server.register(tool: ToolDefinition(name: "later")) { _, _ in .text("") }
        #expect(await wire.isSilent())
        // After the response the id is free again.
        #expect(try await wire.request("tools/call", ["name": "count"], id: "dup").independentConcurrencyText == "duplicate ran")
    }

    @Test func duplicateOfAQueuedRequestIsRefusedAndTheOriginalRunsOnce() async throws {
        let gate = ICGate()
        let ran = ICMeter()
        let server = independentConcurrencyServer { $0.budgets.maxConcurrentHandlers = 1 }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        try server.register(tool: ToolDefinition(name: "count")) { arguments, _ in
            ran.enter()
            return .text(arguments["tag"]?.stringValue ?? "?")
        }
        let wire = ICWire(server)
        let running = wire.call("hold", id: 1)
        wire.call("count", ["tag": "first"], id: 2)
        wire.call("count", ["tag": "second"], id: 2)
        let refusal = try await wire.next()
        #expect(refusal["id"] == 2)
        #expect(refusal.independentConcurrencyErrorCode == -32600)
        gate.open()
        #expect(try await wire.next()["id"] == running.json)
        let queued = try await wire.next()
        #expect(queued["id"] == 2)
        #expect(queued.independentConcurrencyText == "first")
        #expect(await wire.isSilent())
        #expect(ran.total == 1)
    }

    @Test func duplicateOfAnOpenSubscriptionIsRefusedAndTheSubscriptionSurvives() async throws {
        let ran = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "count")) { _, _ in
            ran.enter()
            return .text("ran")
        }
        let wire = ICWire(server)
        wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]], id: 1)
        #expect(try await wire.next()["method"] == "notifications/subscriptions/acknowledged")
        wire.call("count", id: 1)
        let refusal = try await wire.next()
        #expect(refusal.independentConcurrencyErrorCode == -32600)
        #expect(ran.total == 0)
        wire.post("subscriptions/listen", ["notifications": ["promptsListChanged": true]], id: 1)
        #expect(try await wire.next().independentConcurrencyErrorCode == -32600)
        // The original subscription still delivers, with its original filter.
        try server.register(prompt: PromptDefinition(name: "p")) { _, _ in PromptResult(messages: []) }
        #expect(await wire.isSilent(for: .milliseconds(50)))
        try server.register(tool: ToolDefinition(name: "later")) { _, _ in .text("") }
        let changed = try await wire.next()
        #expect(changed["method"] == "notifications/tools/list_changed")
        #expect(changed["params"]?["_meta"]?[MetaKey.subscriptionID] == 1)
    }
}
