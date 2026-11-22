import Foundation
import Limb
import LimbTesting
import Testing

/// S5: `ServerConfiguration.clientRequestTimeoutSeconds`. `basic/lifecycle.mdx` (2025-11-25:246):
/// "Implementations SHOULD establish timeouts for all sent requests … the sender SHOULD issue a
/// cancellation notification for that request and stop waiting for a response."
@Suite(.timeLimit(.minutes(2)))
struct Round2ProtocolClientTimeoutTests {
    enum Kind: String, CaseIterable, Sendable {
        case elicit, sample, roots

        var method: String {
            switch self {
            case .elicit: "elicitation/create"
            case .sample: "sampling/createMessage"
            case .roots: "roots/list"
            }
        }

        var reply: JSONValue {
            switch self {
            case .elicit: ["action": "accept", "content": ["name": "Ada"]]
            case .sample: R2P.samplingReply
            case .roots: ["roots": [["uri": "file:///a"]]]
            }
        }
    }

    private static let everything: JSONObject = ["elicitation": [:], "sampling": [:], "roots": [:]]

    /// A server whose tool `ask` asks once and reports what happened; `uncaught` lets the error
    /// through; `again` asks a second time after a timeout; `three` asks for three inputs at once.
    private static func server(seconds: Double, diagnostics: R2PDiagnostics = R2PDiagnostics()) throws -> Server {
        let server = R2P.server(diagnostics: diagnostics) { $0.clientRequestTimeoutSeconds = seconds }
        @Sendable func ask(_ kind: Kind, _ context: RequestContext) async throws -> String {
            switch kind {
            case .elicit: return try await context.elicit("k", message: "Name?", schema: R2P.formSchema).content?["name"]?.stringValue ?? "?"
            case .sample: return try await context.sample("k", SamplingRequest(prompt: "?", maxTokens: 5)).text ?? "?"
            case .roots: return try await context.roots("k").map(\.uri).joined(separator: ",")
            }
        }
        try server.register(tool: ToolDefinition(name: "ask", inputSchema: ["type": "object"])) { arguments, context in
            let kind = Kind(rawValue: arguments["kind"]?.stringValue ?? "") ?? .elicit
            do {
                return .text("answer:\(try await ask(kind, context))")
            } catch let error as MCPError {
                return .text("error:\(error.code)")
            }
        }
        try server.register(tool: ToolDefinition(name: "uncaught")) { _, context in
            .text(try await ask(.elicit, context))
        }
        try server.register(tool: ToolDefinition(name: "again")) { _, context in
            do {
                _ = try await ask(.elicit, context)
                return .text("first answered")
            } catch let error as MCPError where error.code == MCPError.Code.requestTimedOut {
                return .text("second:\(try await ask(.roots, context))")
            }
        }
        try server.register(tool: ToolDefinition(name: "three")) { _, context in
            do {
                _ = try await context.input([
                    "e": .elicit(ElicitRequest(message: "?", requestedSchema: R2P.formSchema)),
                    "s": .sample(SamplingRequest(prompt: "?", maxTokens: 1)),
                    "r": .roots,
                ])
                return .text("all answered")
            } catch let error as MCPError {
                return .text("error:\(error.code)")
            }
        }
        try server.register(tool: ToolDefinition(name: "three-then-again")) { _, context in
            do {
                _ = try await context.input(["s": .sample(SamplingRequest(prompt: "?", maxTokens: 1)), "r": .roots])
                return .text("all answered")
            } catch let error as MCPError where error.code == MCPError.Code.requestTimedOut {}
            // "r" was answered: refused. "s" timed out: may be asked again.
            var answeredAgain = "asked"
            do { _ = try await context.roots("r") } catch let error as MCPError { answeredAgain = "\(error.code)" }
            let again = try await context.roots("s")
            return .text("r:\(answeredAgain) s:\(again.map(\.uri).joined())")
        }
        return server
    }

    private static func revision(for kind: Kind) -> [IndependentProtocolRevision] {
        kind == .elicit ? [.r2025_06_18, .r2025_11_25] : IndependentProtocolRevision.legacy
    }

    private static var cases: [(IndependentProtocolRevision, Kind)] {
        Kind.allCases.flatMap { kind in revision(for: kind).map { ($0, kind) } }
    }

    /// On expiry: exactly one `notifications/cancelled` naming the request, the handler's call
    /// throws -31003, the handler answers; a late reply is dropped without a word.
    @Test(arguments: cases)
    func expiryWithdrawsTheRequestAndTheHandlerAnswers(revision: IndependentProtocolRevision, kind: Kind) async throws {
        let diagnostics = R2PDiagnostics()
        let client = try await R2P.client(try Self.server(seconds: 0.03, diagnostics: diagnostics), revision, capabilities: Self.everything)
        let call = client.post("tools/call", ["name": "ask", "arguments": ["kind": .string(kind.rawValue)]])
        let request = try await R2P.expectMessage(client, kind.method)
        let requestID = try #require(request["id"])
        // The withdrawal, then the answer, and nothing after.
        let messages = try await R2P.collect(client, until: call) + (await Self.drain(client))
        try #require(messages.count == 2, "\(messages)")
        #expect(messages[0]["method"] == "notifications/cancelled")
        #expect(messages[0]["params"]?["requestId"] == requestID)
        #expect(IndependentProtocol.notificationViolations(messages[0], as: "CancelledNotification", in: revision) == [])
        #expect(messages[1].r2pText == "error:-31003")

        // The late reply, and an error reply, are ignored; the connection still works.
        R2P.answer(client, request, kind.reply)
        client.send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -1, "message": "too late"]])
        let ping = try await client.request("ping")
        #expect(ping["result"] != nil)
        #expect(await client.isSilent(for: .milliseconds(60)))
        #expect(diagnostics.all.isEmpty, "\(diagnostics.all)")
    }

    /// Uncaught, the timeout is the call's JSON-RPC error with code -31003.
    @Test func uncaughtTimeoutIsMinus31003() async throws {
        let client = try await R2P.client(try Self.server(seconds: 0.02), .r2025_11_25, capabilities: Self.everything)
        let call = client.post("tools/call", ["name": "uncaught"])
        _ = try await R2P.expectMessage(client, "elicitation/create")
        let messages = try await R2P.collect(client, until: call)
        #expect(messages.last?.r2pCode == -31003, "\(messages)")
        #expect(messages.last?["error"]?["message"]?.stringValue?.isEmpty == false)
    }

    /// Many late replies to timed-out requests: no diagnostics, no output.
    @Test func lateRepliesDoNotFloodDiagnostics() async throws {
        let diagnostics = R2PDiagnostics()
        let client = try await R2P.client(try Self.server(seconds: 0.01, diagnostics: diagnostics), .r2025_11_25, capabilities: Self.everything)
        var ids: [JSONValue] = []
        for _ in 0..<5 {
            let call = client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
            let request = try await R2P.expectMessage(client, "roots/list")
            ids.append(request["id"]!)
            #expect(try await R2P.collect(client, until: call).last?.r2pText == "error:-31003")
        }
        for round in 0..<200 {
            client.send(["jsonrpc": "2.0", "id": ids[round % ids.count], "result": ["roots": []]])
        }
        #expect(try await client.request("ping")["result"] != nil)
        #expect(await client.isSilent(for: .milliseconds(30)))
        #expect(diagnostics.all.isEmpty, "\(diagnostics.all.count) diagnostics")
    }

    /// After a timeout the handler may ask again, and that request is answered normally.
    @Test func theHandlerCanAskAgainAfterATimeout() async throws {
        let client = try await R2P.client(try Self.server(seconds: 0.25), .r2025_11_25, capabilities: Self.everything)
        let call = client.post("tools/call", ["name": "again"])
        let first = try await R2P.expectMessage(client, "elicitation/create")
        // The withdrawal comes before anything the handler does after the timeout.
        let cancelled = try await R2P.expectMessage(client, "notifications/cancelled")
        #expect(cancelled["params"]?["requestId"] == first["id"])
        let second = try await R2P.expectMessage(client, "roots/list")
        #expect(second["id"] != first["id"])
        R2P.answer(client, second, Kind.roots.reply)
        #expect(try await client.response(to: call).r2pText == "second:file:///a")
    }

    /// `input` with three requests, one answered: one cancellation for each of the other two,
    /// none for the answered one.
    @Test func severalOutstandingRequestsEachWithdrawnOnce() async throws {
        let client = try await R2P.client(try Self.server(seconds: 0.4), .r2025_11_25, capabilities: Self.everything)
        let call = client.post("tools/call", ["name": "three"])
        var requests: [String: JSONValue] = [:]
        for _ in 0..<3 {
            let message = try await client.next()
            requests[message["method"]?.stringValue ?? "?"] = message
        }
        #expect(Set(requests.keys) == ["elicitation/create", "sampling/createMessage", "roots/list"])
        R2P.answer(client, requests["roots/list"]!, Kind.roots.reply)
        let messages = try await R2P.collect(client, until: call) + (await Self.drain(client, quiet: .milliseconds(450)))
        let cancelled = messages.filter { $0["method"] == "notifications/cancelled" }.compactMap { $0["params"]?["requestId"] }
        #expect(cancelled.count == 2, "\(messages)")
        #expect(Set(cancelled.map(\.description)) == Set([requests["elicitation/create"]!["id"]!, requests["sampling/createMessage"]!["id"]!].map(\.description)))
        #expect(messages.contains { $0.r2pText == "error:-31003" })
        #expect(messages.count == 3, "\(messages)")
    }

    @Test func afterAPartialTimeoutOnlyTheUnansweredKeyMayBeAskedAgain() async throws {
        let client = try await R2P.client(try Self.server(seconds: 0.3), .r2025_11_25, capabilities: Self.everything)
        let call = client.post("tools/call", ["name": "three-then-again"])
        var requests: [String: JSONValue] = [:]
        for _ in 0..<2 {
            let message = try await client.next()
            requests[message["method"]?.stringValue ?? "?"] = message
        }
        R2P.answer(client, try #require(requests["roots/list"]), Kind.roots.reply)
        let cancelled = try await R2P.expectMessage(client, "notifications/cancelled")
        #expect(cancelled["params"]?["requestId"] == requests["sampling/createMessage"]?["id"])
        let again = try await R2P.expectMessage(client, "roots/list")
        R2P.answer(client, again, ["roots": [["uri": "file:///b"]]])
        #expect(try await client.response(to: call).r2pText == "r:-32603 s:file:///b")
    }

    /// `.infinity` and anything from 1e9 up mean "no limit", and must not trap; the request is
    /// still answered normally.
    @Test(arguments: [Double.infinity, 1e9, 1e300, Double.greatestFiniteMagnitude, 1e8])
    func hugeLimitsMeanNoLimit(seconds: Double) async throws {
        let client = try await R2P.client(try Self.server(seconds: seconds), .r2025_11_25, capabilities: Self.everything)
        let call = client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
        let request = try await R2P.expectMessage(client, "roots/list")
        #expect(await client.isSilent(for: .milliseconds(50)))
        R2P.answer(client, request, Kind.roots.reply)
        #expect(try await client.response(to: call).r2pText == "answer:file:///a")
    }

    /// Zero, negative values and NaN disable requests to the client (the doc comment): nothing
    /// is sent, nothing is withdrawn, the call throws -31003 at once — every time.
    @Test(arguments: [0, -1, -Double.infinity, Double.nan])
    func nonPositiveLimitsGiveUpAtOnceTheSameWayEveryTime(seconds: Double) async throws {
        let client = try await R2P.client(try Self.server(seconds: seconds), .r2025_11_25, capabilities: Self.everything)
        var all: [JSONValue] = []
        for _ in 0..<60 {
            let call = client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
            let messages = try await R2P.collect(client, until: call)
            #expect(messages.last?.r2pText == "error:-31003", "\(messages)")
            all += messages
        }
        all += await Self.drain(client)
        let sent = all.filter { $0["method"] == "roots/list" }.compactMap { $0["id"] }
        let withdrawn = all.filter { $0["method"] == "notifications/cancelled" }.compactMap { $0["params"]?["requestId"] }
        #expect(sent.isEmpty, "the request went out \(sent.count) times of 60")
        #expect(withdrawn.isEmpty, "\(withdrawn)")
        // Several at once: none goes out either.
        let call = client.post("tools/call", ["name": "three"])
        let messages = try await R2P.collect(client, until: call)
        #expect(messages.count == 1 && messages[0].r2pText == "error:-31003", "\(messages)")
    }

    /// The timeout racing the reply: the handler gets exactly one of the two, and the request is
    /// withdrawn exactly when the handler got the timeout.
    @Test func timeoutRacingTheReply() async throws {
        let client = try await R2P.client(try Self.server(seconds: 0.002), .r2025_11_25, capabilities: Self.everything)
        var outcomes: [(request: JSONValue, timedOut: Bool)] = []
        var all: [JSONValue] = []
        for _ in 0..<150 {
            let call = client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
            let request = try await R2P.expectMessage(client, "roots/list")
            R2P.answer(client, request, Kind.roots.reply)
            let messages = try await R2P.collect(client, until: call)
            all += messages
            switch messages.last?.r2pText {
            case "answer:file:///a": outcomes.append((request["id"]!, false))
            case "error:-31003": outcomes.append((request["id"]!, true))
            default: Issue.record("unexpected outcome \(messages)")
            }
        }
        all += await Self.drain(client)
        for (request, timedOut) in outcomes {
            let count = all.count { $0["method"] == "notifications/cancelled" && $0["params"]?["requestId"] == request }
            #expect(count == (timedOut ? 1 : 0), "request \(request): timed out \(timedOut), withdrawn \(count) times")
        }
    }

    /// The withdrawal of a timed-out request should reach the client before the answer of the
    /// request it served: the handler's answer may depend on the withdrawal (it gave up), and a
    /// client that closes after the answer never hears of it.
    @Test func theWithdrawalPrecedesTheAnswer() async throws {
        let client = try await R2P.client(try Self.server(seconds: 0.0002), .r2025_11_25, capabilities: Self.everything)
        for _ in 0..<300 {
            let call = client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
            let messages = try await R2P.collect(client, until: call)
            // request, withdrawal, answer — exactly in this order.
            #expect(messages.map { $0["method"]?.stringValue ?? "response" } == ["roots/list", "notifications/cancelled", "response"], "\(messages)")
            #expect(messages.last?.r2pText == "error:-31003")
        }
        #expect(await client.isSilent(for: .milliseconds(30)))
    }

    /// The timeout racing the client's cancellation of the outer request: at most one
    /// cancellation for each inner request, and the connection keeps working.
    @Test func timeoutRacingOuterCancellation() async throws {
        let client = try await R2P.client(try Self.server(seconds: 0.002), .r2025_11_25, capabilities: Self.everything)
        var all: [JSONValue] = []
        var inner: [JSONValue] = []
        for _ in 0..<100 {
            let call = client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
            let request = try await R2P.expectMessage(client, "roots/list")
            inner.append(request["id"]!)
            client.notify("notifications/cancelled", ["requestId": call.json])
            all += try await R2P.collect(client, until: client.post("ping"))
        }
        all += await Self.drain(client)
        for id in inner {
            let count = all.count { $0["method"] == "notifications/cancelled" && $0["params"]?["requestId"] == id }
            #expect(count <= 1, "request \(id) withdrawn \(count) times")
        }
        let final = client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
        let request = try await R2P.expectMessage(client, "roots/list")
        _ = request
        #expect(try await R2P.collect(client, until: final).last?.r2pText == "error:-31003")
    }

    /// Everything the server sends until it is quiet for `quiet`.
    private static func drain(_ client: TestClient, quiet: Duration = .milliseconds(50)) async -> [JSONValue] {
        var seen: [JSONValue] = []
        while let message = try? await client.next(timeout: quiet) { seen.append(message) }
        return seen
    }

    /// The timeout racing the connection's close: close returns, nothing is written after it.
    @Test func timeoutRacingClose() async throws {
        let server = try Self.server(seconds: 0.003)
        for _ in 0..<40 {
            let client = try await R2P.client(server, .r2025_11_25, capabilities: Self.everything)
            client.post("tools/call", ["name": "ask", "arguments": ["kind": "roots"]])
            _ = try await R2P.expectMessage(client, "roots/list")
            await client.close(graceSeconds: 0.5)
            // Whatever the handler wrote before the close completed is fine; a frame after it
            // makes `next` throw "after the connection was closed".
            while true {
                do {
                    _ = try await client.next(timeout: .milliseconds(20))
                } catch let error as TestClientError where error.reason.hasPrefix("no message") {
                    break
                }
            }
        }
    }

    /// The modern revision has no requests to the client: the limit does not touch the
    /// input-required round trip, however long the client takes.
    @Test func modernRevisionIsUnaffected() async throws {
        let client = TestClient(try Self.server(seconds: 0.005), capabilities: Self.everything)
        let first = try #require(try await client.request("tools/call", ["name": "ask", "arguments": ["kind": "elicit"]])["result"])
        #expect(first["resultType"] == "input_required")
        try await Task.sleep(for: .milliseconds(40))  // well past the limit
        let second = try await client.request(
            "tools/call",
            ["name": "ask", "arguments": ["kind": "elicit"], "requestState": first["requestState"]!, "inputResponses": ["k": Kind.elicit.reply]])
        #expect(second.r2pText == "answer:Ada")
        #expect(client.received.isEmpty, "\(String(describing: client.received))")
    }
}
