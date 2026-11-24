#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Limb
import LimbTesting
import Synchronization
import Testing

// Third pass: the invariant "every request is answered exactly once, or the connection is
// marked overflowed; an answer is never dropped while the connection lives", `maxRequestIDBytes`,
// memory with a dead or slow peer, and the `initialize` rules.

private typealias ICBox = IndependentConcurrencyBox

private final class RejectFirstOrdinaryFrameSink: FrameSink {
    let output = IndependentConcurrencySink()
    private let rejected = Mutex(false)

    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        if !urgent, rejected.withLock({ rejected in
            defer { rejected = true }
            return !rejected
        }) {
            return false
        }
        return output.enqueue(frame, key: key, urgent: urgent, replacesProgress: replacesProgress)
    }

    func waitForCapacity() async { await output.waitForCapacity() }
    func discard(key: RequestID) { output.discard(key: key) }
}

private struct Random {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x2545_F491 }
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// A `2025-03-26` server with reader answers of several sizes: tools/list about 20 kB,
/// prompts/list about 75 kB, resources/list small; and `blob`, a handler.
private func invariantServer(maxResponseBytes: Int = 16 << 20) throws -> Server {
    let server = round2EngineServer { $0.budgets.maxResponseBytes = maxResponseBytes }
    try round2EngineRegisterBlob(server)
    let description = String(repeating: "d", count: 450)
    for index in 0..<40 {
        try server.register(tool: ToolDefinition(name: "t\(index)", description: description)) { _, _ in .text("") }
    }
    for index in 0..<150 {
        try server.register(prompt: PromptDefinition(name: "p\(index)", description: description)) { _, _ in PromptResult(messages: []) }
    }
    try server.register(resource: ResourceDefinition(uri: "r2://a", name: "a")) { request, _ in [.text(uri: request.uri, text: "")] }
    return server
}

/// One request of the model and how it should be answered.
private enum Expectation { case id(String), nullID }

/// Builds a request of kind `kind` with id `id`; returns its text and what answers it.
private func request(_ kind: Int, id: String, random: inout Random) -> (String, Expectation) {
    func req(_ method: String, _ params: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(method)","params":\#(params)}"#
    }
    switch kind {
    case 0: return (req("ping"), .id(id))
    case 1: return (req("tools/list"), .id(id))
    case 2: return (req("prompts/list"), .id(id))
    case 3: return (req("resources/list"), .id(id))
    case 4: return (req("logging/setLevel", #"{"level":"info"}"#), .id(id))
    case 5: return (req("resources/subscribe", #"{"uri":"r2://u\#(random.below(5))"}"#), .id(id))
    case 6: return (req("resources/unsubscribe", #"{"uri":"r2://u\#(random.below(5))"}"#), .id(id))
    case 7: return (req("completion/complete", #"{"ref":{"type":"ref/prompt","name":"p1"},"argument":{"name":"a","value":""}}"#), .id(id))
    case 8: return (req("no/such/method"), .id(id))
    case 9: return (req("tools/call", #"{"name":"nope"}"#), .id(id))
    case 10: return (req("tools/call", #"{"name":"blob","arguments":{"size":\#([10, 3000, 30000, 90000][random.below(4)])}}"#), .id(id))
    case 11: return (#"{"jsonrpc":"2.0","id":"\#(id)","method":5}"#, .id(id))
    case 12:
        let long = id + String(repeating: "x", count: 8 * 1024)
        return (#"{"jsonrpc":"2.0","id":"\#(long)","method":"ping"}"#, .nullID)
    default: return (req("server/discover"), .id(id))  // not in 2025-03-26: method not found
    }
}

private struct Tally {
    var expected: [String: Int] = [:]
    var expectedNull = 0
    var answered: [String: Int] = [:]
    var answeredNull = 0
    var unexpected: [String] = []

    mutating func expect(_ expectation: Expectation) {
        switch expectation {
        case .id(let id): expected[id, default: 0] += 1
        case .nullID: expectedNull += 1
        }
    }

    mutating func record(_ frames: [[UInt8]]) {
        for frame in frames {
            guard let message = try? JSON.parse(frame) else {
                unexpected.append("unparsable frame")
                continue
            }
            for item in message.arrayValue ?? [message] where item["method"] == nil {
                if let id = item["id"]?.stringValue {
                    answered[id, default: 0] += 1
                    if expected[id] == nil { unexpected.append(id) }
                } else if item["id"]?.isNull == true {
                    answeredNull += 1
                } else {
                    unexpected.append("\(item)")
                }
            }
        }
    }

    var duplicates: [String] { answered.filter { $0.value > 1 }.map(\.key) }
    var missing: [String] { expected.keys.filter { answered[$0] == nil } }
}

private let invariantConfigurations: [(budget: Int, reserve: Int)] = [
    (64 << 10, 1 << 20), (64 << 10, 16 << 10), (64 << 10, 3 << 10), (64 << 10, 0), (8 << 10, 64 << 10),
]

@Suite(.timeLimit(.minutes(3)))
struct Round2EngineInvariantTests {
    // MARK: Every request answered exactly once, or overflowed

    @Test(arguments: invariantConfigurations.indices, [UInt64(1), 2, 3])
    func everyRequestIsAnsweredExactlyOnceOrTheConnectionOverflows(configuration: Int, seed: UInt64) async throws {
        let (budget, reserve) = invariantConfigurations[configuration]
        var random = Random(seed: seed &* 31 &+ UInt64(configuration))
        let client = Round2EngineQueueClient(try invariantServer(), budget: budget, reserve: reserve)
        try client.initializeLegacy(.v2025_03_26)
        var tally = Tally()
        var heldByWriter = false
        var next = 0
        func newID() -> String {
            next += 1
            return "r\(next)"
        }
        for _ in 0..<400 {
            if client.overflowed { break }
            switch random.below(10) {
            case 0...5:
                let (text, expectation) = request(random.below(14), id: newID(), random: &random)
                tally.expect(expectation)
                client.send(text)
            case 6:
                client.send("{not json")
                tally.expect(.nullID)
            case 7:
                var members: [String] = []
                for _ in 0..<(1 + random.below(8)) {
                    // No parse errors inside a batch: those are whole frames.
                    let (text, expectation) = request(random.below(14), id: newID(), random: &random)
                    members.append(text)
                    tally.expect(expectation)
                }
                if random.chance(20) { members.append(#"{"jsonrpc":"2.0","method":"notifications/x"}"#) }
                client.send("[" + members.joined(separator: ",") + "]")
            default:
                // The peer reads at random: takes frames, reports them written, or both.
                switch random.below(3) {
                case 0:
                    tally.record(client.queue.takeAvailable())
                    heldByWriter = true
                case 1:
                    if heldByWriter { client.queue.didWrite() }
                    heldByWriter = false
                default:
                    tally.record(client.drain())
                    heldByWriter = false
                }
            }
        }
        let overflowed = client.overflowed
        // Read everything, including handler results still to come.
        if heldByWriter { client.queue.didWrite() }
        let deadline = ContinuousClock.now + (overflowed ? .milliseconds(500) : .seconds(20))
        while ContinuousClock.now < deadline {
            tally.record(client.drain())
            if !overflowed, tally.missing.isEmpty, tally.answeredNull >= tally.expectedNull { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let context = "budget \(budget), reserve \(reserve), seed \(seed), overflowed \(overflowed)"
        #expect(tally.duplicates.isEmpty, "answered twice: \(tally.duplicates.prefix(5)) — \(context)")
        #expect(tally.unexpected.isEmpty, "unexpected: \(tally.unexpected.prefix(3)) — \(context)")
        if !overflowed {
            #expect(tally.missing.isEmpty, "never answered: \(tally.missing.prefix(5)) of \(tally.expected.count) — \(context)")
            #expect(tally.answeredNull == tally.expectedNull, "null-id answers \(tally.answeredNull) of \(tally.expectedNull) — \(context)")
        } else {
            #expect(tally.answeredNull <= tally.expectedNull, "\(context)")
        }
    }

    // MARK: maxRequestIDBytes

    private static func pingID(_ id: String) -> String { #"{"jsonrpc":"2.0","id":"\#(id)","method":"ping"}"# }

    private static func legacyClient(budget: Int = 64 << 20, reserve: Int = 1 << 20) throws -> Round2EngineQueueClient {
        let client = Round2EngineQueueClient(try invariantServer(), budget: budget, reserve: reserve)
        try client.initializeLegacy(.v2025_03_26)
        return client
    }

    @Test(arguments: [
        (String(repeating: "i", count: 8192), true), (String(repeating: "i", count: 8193), false),
        (String(repeating: "é", count: 4096), true), (String(repeating: "é", count: 4096) + "a", false),
    ])
    func stringIDBoundaryInBytes(id: String, accepted: Bool) throws {
        let client = try Self.legacyClient()
        client.send(Self.pingID(id))
        let answer = try #require(Round2EngineQueueClient.parse(client.drain()).first)
        if accepted {
            #expect(answer["id"]?.stringValue == id)
            #expect(answer["result"] != nil)
        } else {
            #expect(answer["id"]?.isNull == true)
            #expect(answer.round2EngineCode == -32600)
        }
    }

    // The Foundation codec cannot represent integers of thousands of digits (a parse error).
    #if !FoundationJSON
    @Test(arguments: [(8192, true), (8193, false)])
    func numberIDBoundaryInDigits(digits: Int, accepted: Bool) throws {
        let client = try Self.legacyClient()
        let number = "1" + String(repeating: "0", count: digits - 1)
        client.send(#"{"jsonrpc":"2.0","id":\#(number),"method":"ping"}"#)
        let answer = try #require(Round2EngineQueueClient.parse(client.drain()).first)
        #expect((answer["result"] != nil) == accepted, "\(String(describing: answer.round2EngineMessage))")
        if !accepted { #expect(answer["id"]?.isNull == true) }
    }

    #endif

    @Test func aLongIDInOneBatchMemberRefusesOnlyThatMember() throws {
        let client = try Self.legacyClient()
        let long = String(repeating: "x", count: 9000)
        client.send("[" + [Self.pingID("a"), Self.pingID(long), Self.pingID("b")].joined(separator: ",") + "]")
        let reply = try #require(Round2EngineQueueClient.parse(client.drain()).first?.arrayValue)
        #expect(reply.count == 3)
        #expect(reply[0]["id"] == "a" && reply[0]["result"] != nil)
        #expect(reply[1]["id"]?.isNull == true && reply[1].round2EngineCode == -32600)
        #expect(reply[2]["id"] == "b" && reply[2]["result"] != nil)
    }

    @Test func longIDsInCancellationsAndRepliesAreIgnoredQuietly() throws {
        let client = try Self.legacyClient()
        let long = String(repeating: "x", count: 100_000)
        client.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"\#(long)"}}"#)
        client.send(#"{"jsonrpc":"2.0","id":"\#(long)","result":{}}"#)
        #if !FoundationJSON
        client.send(#"{"jsonrpc":"2.0","id":\#("9" + String(repeating: "9", count: 20_000)),"result":{}}"#)
        #endif
        #expect(client.drain().isEmpty)
        client.send(Self.pingID("after"))
        #expect(Round2EngineQueueClient.parse(client.drain()).first?["id"] == "after")
    }

    // MARK: Memory

    @Test func listenAcknowledgementsAreBoundedByTheOutputBudget() throws {
        let server = round2EngineServer {
            $0.budgets.maxSubscriptions = 2
            $0.budgets.maxSubscribedResources = 2
        }
        let client = Round2EngineQueueClient(server, budget: 64, reserve: 4096)
        client.post("subscriptions/listen", id: "first", params: #""notifications":{"resourceSubscriptions":["r2://first"]}"#)
        let firstAcknowledgmentBytes = client.queue.usage.ordinaryBytes
        #expect(client.queue.isOverBudget)

        client.post("subscriptions/listen", id: "retry", params: #""notifications":{"resourceSubscriptions":["r2://refused"]}"#)
        #expect(client.queue.usage.ordinaryBytes == firstAcknowledgmentBytes)
        #expect(!client.overflowed)

        let messages = Round2EngineQueueClient.parse(client.drain())
        #expect(messages.count == 2)
        #expect(messages.first?["method"] == "notifications/subscriptions/acknowledged")
        #expect(messages.first?["params"]?["_meta"]?[MetaKey.subscriptionID] == "first")
        #expect(messages.last?["id"] == "retry")
        #expect(messages.last?.round2EngineCode == MCPError.Code.overloaded)

        server.notifyResourceUpdated(uri: "r2://refused")
        #expect(client.drain().isEmpty)
        client.post("subscriptions/listen", id: "retry", params: #""notifications":{"resourceSubscriptions":["r2://accepted"]}"#)
        let acknowledgment = try #require(Round2EngineQueueClient.parse(client.drain()).first)
        #expect(acknowledgment["method"] == "notifications/subscriptions/acknowledged")
        #expect(acknowledgment["params"]?["_meta"]?[MetaKey.subscriptionID] == "retry")
        server.notifyResourceUpdated(uri: "r2://accepted")
        let update = try #require(Round2EngineQueueClient.parse(client.drain()).first)
        #expect(update["method"] == "notifications/resources/updated")
        #expect(update["params"]?["_meta"]?[MetaKey.subscriptionID] == "retry")
    }

    @Test func anOversizedListenAcknowledgmentDoesNotOpenASubscription() throws {
        let server = round2EngineServer {
            $0.budgets.maxResponseBytes = 256
            $0.budgets.maxSubscriptions = 1
        }
        let client = Round2EngineQueueClient(server, budget: 4096)
        let uri = "r2://" + String(repeating: "a", count: 128)
        client.post("subscriptions/listen", id: "limited", params: #""notifications":{"resourceSubscriptions":["\#(uri)"]}"#)
        #expect(client.queue.usage.ordinaryBytes == 0)
        let error = try #require(Round2EngineQueueClient.parse(client.drain()).first)
        #expect(error["id"] == "limited")
        #expect(error.round2EngineCode == MCPError.Code.responseTooLarge)

        server.notifyResourceUpdated(uri: uri)
        #expect(client.drain().isEmpty)
        client.post("subscriptions/listen", id: "limited", params: #""notifications":{}"#)
        let acknowledgment = try #require(Round2EngineQueueClient.parse(client.drain()).first)
        #expect(acknowledgment["method"] == "notifications/subscriptions/acknowledged")
        #expect(acknowledgment["params"]?["_meta"]?[MetaKey.subscriptionID] == "limited")
    }

    @Test func aRefusedListenEnqueueLeavesTheSubscriptionSlotAvailable() throws {
        let server = round2EngineServer {
            $0.budgets.maxSubscriptions = 1
            $0.budgets.maxSubscribedResources = 1
        }
        let sink = RejectFirstOrdinaryFrameSink()
        let connection = server.connect(to: sink)

        func subscribe(to uri: String) {
            connection.receive(Array(
                #"{"jsonrpc":"2.0","id":"retry","method":"subscriptions/listen","params":{"notifications":{"resourceSubscriptions":["\#(uri)"]},\#(round2EngineModernMeta)}}"#
                    .utf8))
        }

        #expect(!sink.isOverBudget)
        subscribe(to: "r2://refused")
        let refusal = try #require(sink.output.history.first)
        #expect(refusal.urgent)
        #expect(refusal.json?["id"] == "retry")
        #expect(refusal.json?.round2EngineCode == MCPError.Code.overloaded)
        #expect(!connection.hasOverflowed)

        server.notifyResourceUpdated(uri: "r2://refused")
        #expect(sink.output.history.count == 1)
        subscribe(to: "r2://accepted")
        let acknowledgment = try #require(sink.output.history.last?.json)
        #expect(acknowledgment["method"] == "notifications/subscriptions/acknowledged")
        #expect(acknowledgment["params"]?["_meta"]?[MetaKey.subscriptionID] == "retry")
        server.notifyResourceUpdated(uri: "r2://accepted")
        let update = try #require(sink.output.history.last?.json)
        #expect(update["method"] == "notifications/resources/updated")
        #expect(update["params"]?["_meta"]?[MetaKey.subscriptionID] == "retry")
    }

    #if canImport(Darwin)
    /// Reader-built members of a batch are kept in memory until the batch's handler members end,
    /// outside every budget: a few kilobytes of requests hold hundreds of megabytes. Measures
    /// the process's resident memory, so it does not run with the suite.
    @Test(.disabled("defect: measures resident memory; run alone with --filter batchReplyMembersArePinned"))
    func batchReplyMembersArePinnedOutsideEveryBudget() async throws {
        let gate = IndependentConcurrencyGate()
        let server = round2EngineServer { configuration in
            configuration.execution = .serial
            configuration.budgets.maxQueuedRequests = 1000
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("h")
        }
        try round2EngineRegisterManyTools(server, count: 200, descriptionBytes: 450)  // about 100 kB
        let client = Round2EngineQueueClient(server, budget: 64 << 20)
        try client.initializeLegacy(.v2025_03_26)
        let before = Self.residentBytes()
        let lists = (0..<63).map { #"{"jsonrpc":"2.0","id":"l\#($0)","method":"tools/list"}"# }.joined(separator: ",")
        var sent = 0
        for batch in 0..<40 {
            let text = "[" + #"{"jsonrpc":"2.0","id":"h\#(batch)","method":"tools/call","params":{"name":"hold"}}"# + "," + lists + "]"
            sent += text.utf8.count
            client.send(text)
        }
        let grown = Self.residentBytes() - before
        gate.open()
        #expect(client.queue.usage.ordinaryBytes == 0)
        #expect(grown < 50 * sent, "\(sent) bytes of requests grew resident memory by \(grown / 1_000_000) MB")
    }
    #endif

    #if canImport(Darwin)
    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    #endif

    @Test(arguments: [(64 << 10, 1 << 20), (64 << 10, 16 << 10), (8 << 10, 64 << 10), (64 << 10, 2 << 10)])
    func aDeadPeerOfReaderAnswersStaysWithinBudgetPlusOneFramePlusReserve(budget: Int, reserve: Int) throws {
        let client = Round2EngineQueueClient(try invariantServer(), budget: budget, reserve: reserve)
        try client.initializeLegacy(.v2025_03_26)
        // The largest reader answer here: prompts/list.
        client.send(#"{"jsonrpc":"2.0","id":"probe","method":"prompts/list"}"#)
        let largest = client.drain()[0].count
        var random = Random(seed: 7)
        var peak = 0
        var sent = 0
        while !client.overflowed, sent < 20_000 {
            let (text, _) = request([0, 1, 2, 3, 8, 9, 11][random.below(7)], id: "d\(sent)", random: &random)
            client.send(text)
            sent += 1
            let usage = client.queue.usage
            peak = max(peak, usage.ordinaryBytes + usage.urgentBytes)
        }
        #expect(client.overflowed, "a peer that never reads was not detected after \(sent) requests")
        #expect(peak <= budget + largest + reserve, "peak \(peak) > \(budget) + \(largest) + \(reserve)")
    }

    // MARK: initialize (F2)

    @Test func anInitializeRefusedWhileOverBudgetLeavesTheSessionAsItWas() async throws {
        let server = round2EngineServer { $0.instructions = String(repeating: "i", count: 100_000) }
        try round2EngineRegisterBlob(server)
        try server.register(resource: ResourceDefinition(uri: "r2://a", name: "a")) { request, _ in [.text(uri: request.uri, text: "")] }
        let client = Round2EngineQueueClient(server, budget: 64 << 10)
        try client.initializeLegacy(.v2025_03_26)
        client.send(#"{"jsonrpc":"2.0","id":"s","method":"resources/subscribe","params":{"uri":"r2://u"}}"#)
        client.drain()
        client.send(#"{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"blob","arguments":{"size":100000}}}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        client.send(
            #"{"jsonrpc":"2.0","id":"again","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        )
        let refused = Round2EngineQueueClient.parse(client.drain())
        #expect(refused.last?["id"] == "again")
        #expect(refused.last?.round2EngineCode == -31001)
        // Still the 2025-03-26 session: batches work, and the subscription is kept.
        client.send(#"[{"jsonrpc":"2.0","id":"b","method":"ping"}]"#)
        #expect(Round2EngineQueueClient.parse(client.drain()).first?.arrayValue?.first?["id"] == "b")
        server.notifyResourceUpdated(uri: "r2://u")
        #expect(Round2EngineQueueClient.parse(client.drain()).first?["params"]?["uri"] == "r2://u")
    }

    @Test func instructionsLargerThanMaxResponseBytesAreReportedOnceAtStartUp() throws {
        let lines = ICBox<[String]>([])
        let server = round2EngineServer(lines: lines) { configuration in
            configuration.budgets.maxResponseBytes = 10_000
            configuration.instructions = String(repeating: "i", count: 20_000)
        }
        #expect(lines.value.count == 1, "\(lines.value)")
        #expect(lines.value.first?.contains("maxResponseBytes") == true)
        let client = Round2EngineQueueClient(server, budget: 64 << 20)
        client.send(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        )
        #expect(Round2EngineQueueClient.parse(client.drain()).first?.round2EngineCode == -31002)
        #expect(lines.value.count == 2)
        #expect(lines.value.last?.contains("20000") == true, "\(lines.value)")
    }
}
