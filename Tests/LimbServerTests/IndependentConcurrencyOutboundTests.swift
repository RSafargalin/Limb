import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
private func texts(_ frames: [[UInt8]]) -> [String] { frames.map { String(decoding: $0, as: UTF8.self) } }

private let modernMeta: JSONObject = [
    MetaKey.protocolVersion: "2026-07-28", MetaKey.clientCapabilities: [:],
]

/// A client whose "stdout pipe" is an `OutboundQueue` that the test drains by hand.
private final class QueuePeer: Sendable {
    let queue: OutboundQueue
    let connection: Connection
    private let nextID = Mutex(1)

    init(_ server: Server, budget: Int, reserve: Int) {
        queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: reserve)
        connection = server.connect(to: queue)
    }

    @discardableResult
    func post(_ method: String, _ params: JSONObject = JSONObject(), meta: JSONObject = JSONObject()) -> RequestID {
        let id = nextID.withLock { value in
            defer { value += 1 }
            return value
        }
        var params = params
        params["_meta"] = .object(modernMeta.merging(meta))
        let message: JSONValue = ["jsonrpc": "2.0", "id": JSONValue(id), "method": .string(method), "params": .object(params)]
        connection.receive(message.encoded())
        return RequestID(id)
    }

    func cancel(_ id: RequestID) {
        let message: JSONValue = ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id.json]]
        connection.receive(message.encoded())
    }

    /// Takes what is queued, as the writer thread would, without reporting it written: the
    /// bytes stay charged to the budget, as they do while a `write` is blocked on a full pipe.
    func takeUnwritten() -> [JSONValue] {
        queue.takeAvailable().compactMap { try? JSON.parse($0) }
    }

    /// Waits until at least one frame is queued, then takes everything.
    func takeUnwrittenWhenReady(timeout: Duration = .seconds(10)) async -> [[UInt8]] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let frames = queue.takeAvailable()
            if !frames.isEmpty { return frames }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return []
    }
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyOutboundQueueTests {
    @Test func framesLeaveInArrivalOrder() {
        let queue = OutboundQueue(budgetBytes: 1000)
        #expect(queue.takeAvailable().isEmpty)
        for index in 0..<100 { #expect(queue.enqueue(bytes("frame-\(index)"))) }
        #expect(texts(queue.takeAvailable()) == (0..<100).map { "frame-\($0)" })
        #expect(queue.takeAvailable().isEmpty)
    }

    @Test func takeBlocksUntilAFrameArrivesAndEndsOnceClosedAndDrained() async {
        let queue = OutboundQueue(budgetBytes: 1000)
        let taken = ICBox<[String]>([])
        let finished = ICBox(false)
        Thread.detachNewThread {
            while let frames = queue.take() {
                taken.update { $0.append(contentsOf: texts(frames)) }
                queue.didWrite(bytes: frames.reduce(0) { $0 + $1.count })
            }
            finished.set(true)
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(taken.value.isEmpty)
        #expect(!finished.value)
        queue.enqueue(bytes("one"))
        #expect(await independentConcurrencyEventually { taken.value == ["one"] })
        queue.enqueue(bytes("two"))
        queue.enqueue(bytes("three"))
        queue.close()
        #expect(queue.isClosed)
        // "Frames already queued are still handed to the consumer."
        #expect(await independentConcurrencyEventually { finished.value })
        #expect(taken.value == ["one", "two", "three"])
        // A closed sink accepts nothing, urgent or not.
        #expect(queue.enqueue(bytes("late")) == false)
        #expect(queue.enqueue(bytes("late"), key: nil, urgent: true) == false)
        #expect(queue.takeAvailable().isEmpty)
        #expect(queue.take() == nil)
    }

    @Test func handlersWaitOnlyWhileMoreThanTheBudgetIsPending() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 0)
        queue.enqueue([UInt8](repeating: 0x61, count: 10))
        // Exactly the budget: no wait.
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
        queue.enqueue([0x62])
        let resumed = ICBox(false)
        Task {
            await queue.waitForCapacity()
            resumed.set(true)
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!resumed.value, "11 bytes pending with a 10-byte budget: the handler must wait")
        // Handing frames to the writer does not free the budget; writing them does.
        #expect(queue.takeAvailable().count == 2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!resumed.value, "frames taken by the writer but not written yet still count")
        queue.didWrite(bytes: 1)
        #expect(await independentConcurrencyEventually { resumed.value })
        queue.didWrite(bytes: 10)
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
    }

    @Test func urgentReserveAtTheExactBoundary() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 5)
        #expect(queue.budgetBytes == 10)
        #expect(queue.urgentReserveBytes == 5)
        // Ordinary output far over its budget.
        #expect(queue.enqueue([UInt8](repeating: 0x61, count: 1000)))
        #expect(queue.isOverBudget)
        // The reserve is still whole: usable up to its last byte, and not one byte further.
        #expect(queue.enqueue([UInt8](repeating: 0x62, count: 3), key: nil, urgent: true))
        #expect(queue.enqueue([UInt8](repeating: 0x62, count: 2), key: nil, urgent: true))
        #expect(queue.enqueue([0x63], key: nil, urgent: true) == false)
        #expect(queue.enqueue([], key: nil, urgent: true))
        // The refused frame was not queued; order is arrival order across both kinds.
        #expect(queue.takeAvailable().map(\.count) == [1000, 3, 2, 0])
        // Taken but not written: still charged.
        #expect(queue.enqueue([0x63], key: nil, urgent: true) == false)
        #expect(queue.isOverBudget)
        queue.didWrite(bytes: 1005)
        #expect(!queue.isOverBudget)
        // Urgent bytes do not count against the ordinary budget.
        #expect(queue.enqueue([UInt8](repeating: 0x64, count: 5), key: nil, urgent: true))
        #expect(queue.enqueue([0x65], key: nil, urgent: true) == false)
        #expect(queue.enqueue([UInt8](repeating: 0x66, count: 10)))
        #expect(!queue.isOverBudget)
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
        #expect(queue.enqueue([0x67]))
        #expect(queue.isOverBudget)
        // A single urgent frame larger than the whole reserve can never be sent.
        _ = queue.takeAvailable()
        queue.didWrite(bytes: 16)
        #expect(queue.enqueue([UInt8](repeating: 0x68, count: 6), key: nil, urgent: true) == false)
        #expect(queue.enqueue([UInt8](repeating: 0x68, count: 5), key: nil, urgent: true))
    }

    @Test func discardWithdrawsOnlyThatRequestsUnwrittenFramesAndFreesTheirBytes() async {
        let queue = OutboundQueue(budgetBytes: 20, urgentReserveBytes: 0)
        queue.enqueue(bytes("a-first...."), key: 1)  // 11 bytes
        queue.enqueue(bytes("b-keep"), key: 2)  // 6
        queue.enqueue(bytes("a-second..."), key: 1)  // 11
        queue.enqueue(bytes("unkeyed"), key: nil)  // 7
        queue.enqueue(bytes("a-string-id"), key: "1")  // 11: a different id
        let resumed = ICBox(false)
        Task {
            await queue.waitForCapacity()
            resumed.set(true)
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!resumed.value)  // 46 bytes pending
        queue.discard(key: 99)  // nothing to withdraw
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!resumed.value)
        queue.discard(key: 1)  // 24 bytes left: still over
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!resumed.value)
        queue.discard(key: "1")  // 13 bytes left
        #expect(await independentConcurrencyEventually { resumed.value }, "discard must release bytes and wake waiting handlers")
        #expect(texts(queue.takeAvailable()) == ["b-keep", "unkeyed"])
        // Frames the writer already took cannot be withdrawn and stay charged.
        queue.enqueue(bytes("12345678"), key: 2)
        queue.discard(key: 2)
        #expect(queue.takeAvailable().isEmpty)
        queue.didWrite(bytes: 13)
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
    }

    @Test func onlyTheLatestUnwrittenProgressPerRequestIsKept() async {
        let queue = OutboundQueue(budgetBytes: 17, urgentReserveBytes: 0)
        queue.enqueue(bytes("p1-long-long-long"), key: 1, urgent: false, replacesProgress: true)
        queue.enqueue(bytes("log"), key: 1, urgent: false, replacesProgress: false)
        queue.enqueue(bytes("q1"), key: 2, urgent: false, replacesProgress: true)
        queue.enqueue(bytes("p2"), key: 1, urgent: false, replacesProgress: true)
        queue.enqueue(bytes("q2"), key: 2, urgent: false, replacesProgress: true)
        queue.enqueue(bytes("none"), key: nil, urgent: false, replacesProgress: true)
        queue.enqueue(bytes("none2"), key: nil, urgent: false, replacesProgress: true)
        // Budget accounting follows the replacement: 2 + 3 + 2 + 4 + 5 = 16 bytes, not 31.
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
        let frames = texts(queue.takeAvailable())
        #expect(frames.filter { $0.hasPrefix("p") } == ["p2"])
        #expect(frames.filter { $0.hasPrefix("q") } == ["q2"])
        #expect(frames.contains("log"))
        // Frames without a key belong to no request and are never merged.
        #expect(frames.filter { $0.hasPrefix("none") } == ["none", "none2"])
        // What the writer has taken is on its way and is not replaced any more.
        queue.enqueue(bytes("p3"), key: 1, urgent: false, replacesProgress: true)
        #expect(texts(queue.takeAvailable()) == ["p3"])
        // A response (not progress) for the same request is never replaced by progress.
        queue.enqueue(bytes("response"), key: 1)
        queue.enqueue(bytes("p4"), key: 1, urgent: false, replacesProgress: true)
        #expect(texts(queue.takeAvailable()) == ["response", "p4"])
    }

    @Test func closeResumesEveryWaitingHandler() async {
        let queue = OutboundQueue(budgetBytes: 1, urgentReserveBytes: 0)
        queue.enqueue(bytes("over the budget"))
        let resumed = ICMeter()
        for _ in 0..<50 {
            Task {
                await queue.waitForCapacity()
                resumed.enter()
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(resumed.total == 0)
        queue.close()
        #expect(await independentConcurrencyEventually { resumed.total == 50 })
        // After close nobody waits again.
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
    }

    /// Many producers, discards and one consumer: every frame arrives whole, once, and in its
    /// producer's order. Also the Thread Sanitizer target for the queue.
    @Test func manyProducersOneConsumerKeepEveryFrameWholeAndOrdered() async {
        let queue = OutboundQueue(budgetBytes: 4096, urgentReserveBytes: 1024)
        let producers = 16
        let perProducer = 500
        let received = ICBox<[String]>([])
        let consumerDone = ICBox(false)
        Thread.detachNewThread {
            while let frames = queue.take() {
                received.update { $0.append(contentsOf: texts(frames)) }
                queue.didWrite(bytes: frames.reduce(0) { $0 + $1.count })
            }
            consumerDone.set(true)
        }
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<producers {
                group.addTask {
                    for index in 0..<perProducer {
                        let body = String(repeating: Character(UnicodeScalar(UInt8(0x61 + producer))), count: 10 + index % 90)
                        queue.enqueue(bytes("\(producer):\(index):\(body)"), key: RequestID(producer))
                        // Noise that is withdrawn again: it must never corrupt other frames.
                        queue.enqueue(bytes("noise"), key: RequestID(1000 + producer), urgent: false, replacesProgress: index % 2 == 0)
                        queue.discard(key: RequestID(1000 + producer))
                        if index % 16 == 0 { await queue.waitForCapacity() }
                    }
                }
            }
        }
        queue.close()
        #expect(await independentConcurrencyEventually { consumerDone.value })
        var next = [Int](repeating: 0, count: producers)
        var intact = true
        for frame in received.value where frame != "noise" {
            let parts = frame.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let producer = Int(parts[0]), let index = Int(parts[1]), producer < producers,
                parts[2].count == 10 + index % 90,
                parts[2].allSatisfy({ $0 == Character(UnicodeScalar(UInt8(0x61 + producer))) }),
                index == next[producer]
            else {
                intact = false
                break
            }
            next[producer] += 1
        }
        #expect(intact, "a frame was damaged, duplicated or reordered")
        #expect(next == [Int](repeating: perProducer, count: producers))
    }
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyBackpressureTests {
    private func makeServer() throws -> Server {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "blob")) { arguments, _ in
            .text(String(repeating: "z", count: arguments["size"]?.intValue ?? 0))
        }
        return server
    }

    @Test func handlersFeelBackpressureWhileTheReaderAndCancellationKeepWorking() async throws {
        let peer = QueuePeer(try makeServer(), budget: 2000, reserve: 100_000)
        let first = peer.post("tools/call", ["name": "blob", "arguments": ["size": 1500]])
        #expect(await peer.takeUnwrittenWhenReady().count == 1)  // 1500+ bytes pending, under the budget
        let second = peer.post("tools/call", ["name": "blob", "arguments": ["size": 1500]])
        #expect(await peer.takeUnwrittenWhenReady().count == 1)  // 3000+ bytes pending, over the budget
        // The writer is stuck. Further handler results must wait…
        let third = peer.post("tools/call", ["name": "blob", "arguments": ["size": 10]])
        let fourth = peer.post("tools/call", ["name": "blob", "arguments": ["size": 11]])
        try? await Task.sleep(for: .milliseconds(150))
        #expect(peer.takeUnwritten().isEmpty, "a handler's response was queued although the queue is over its budget")
        // …while the reader still answers cheap methods from the reserve…
        let discover = peer.post("server/discover")
        let answers = peer.takeUnwritten()
        #expect(answers.count == 1)
        #expect(answers.first?["id"] == discover.json)
        do {
            let overflowed = peer.connection.hasOverflowed
            #expect(!overflowed)
        }
        // …and still processes cancellations.
        peer.cancel(third)
        // The writer makes progress: the waiting response goes out, the cancelled one never does.
        peer.queue.didWrite(bytes: 100_000)
        let rest = await peer.takeUnwrittenWhenReady().compactMap { try? JSON.parse($0) }
        try? await Task.sleep(for: .milliseconds(100))
        let all = rest + peer.takeUnwritten()
        #expect(all.map { $0["id"] } == [fourth.json])
        _ = (first, second)
    }

    @Test func handlerResponsesDoNotConsumeTheUrgentReserve() async throws {
        let peer = QueuePeer(try makeServer(), budget: 4000, reserve: 1000)
        peer.post("tools/call", ["name": "blob", "arguments": ["size": 3000]])
        #expect(await peer.takeUnwrittenWhenReady().count == 1)  // ~3100 bytes pending: under the budget
        peer.post("tools/call", ["name": "blob", "arguments": ["size": 3000]])
        // The second response is admitted because the queue was under its budget when the
        // handler asked; if it is queued in full, ~6200 bytes are pending: budget plus reserve is 5000.
        try? await Task.sleep(for: .milliseconds(150))
        _ = peer.takeUnwritten()
        let discover = peer.post("server/discover")
        let answers = peer.takeUnwritten()
        #expect(answers.first?["id"] == discover.json, "a cheap method got no answer: handler output used up the urgent reserve")
        do {
            let overflowed = peer.connection.hasOverflowed
            #expect(!overflowed, "the connection asks to be closed although no urgent frame used the reserve")
        }
    }

    @Test func logMessagesFromAHandlerAreBoundedWhenThePeerDoesNotRead() async throws {
        let done = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "noisy")) { _, context in
            let line = String(repeating: "l", count: 200)
            for _ in 0..<5000 { context.log(.error, .string(line)) }
            done.enter()
            return .text("done")
        }
        let peer = QueuePeer(server, budget: 10_000, reserve: 2000)
        peer.post("tools/call", ["name": "noisy"], meta: [MetaKey.logLevel: "debug"])
        #expect(await independentConcurrencyEventually { done.total == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        // The reader can still answer: the reserve belongs to it.
        let discover = peer.post("server/discover")
        let frames = peer.queue.takeAvailable()
        let queuedBytes = frames.reduce(0) { $0 + $1.count }
        #expect(
            queuedBytes <= 10_000 + 2000 + 1000,
            "\(queuedBytes) bytes (\(frames.count) frames) are queued for a peer that is not reading; the budget is 10000")
        #expect(frames.compactMap { try? JSON.parse($0) }.contains { $0["id"] == discover.json })
        do {
            let overflowed = peer.connection.hasOverflowed
            #expect(!overflowed)
        }
    }

    @Test func progressFromAHandlerCollapsesToTheLatestValueWhenThePeerDoesNotRead() async throws {
        let done = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "ticker")) { _, context in
            for value in 1...5000 { context.progress(Double(value), total: 5000) }
            done.enter()
            return .text("done")
        }
        let peer = QueuePeer(server, budget: 10_000, reserve: 2000)
        let id = peer.post("tools/call", ["name": "ticker"], meta: ["progressToken": "t"])
        #expect(await independentConcurrencyEventually { done.total == 1 })
        let frames = await peer.takeUnwrittenWhenReady().compactMap { try? JSON.parse($0) }
        try? await Task.sleep(for: .milliseconds(50))
        let all = frames + peer.takeUnwritten()
        let progress = all.filter { $0["method"] == "notifications/progress" }
        #expect(progress.count == 1)
        #expect(progress.last?["params"]?["progress"] == 5000)
        #expect(all.last?["id"] == id.json)
    }

    @Test func urgentRepliesStopAtTheReserveAndTheConnectionAsksToBeClosed() async throws {
        let peer = QueuePeer(try makeServer(), budget: 1000, reserve: 2000)
        do {
            let overflowed = peer.connection.hasOverflowed
            #expect(!overflowed)
        }
        var sent = 0
        while !peer.connection.hasOverflowed, sent < 10_000 {
            peer.connection.receive(Array("{not json".utf8))
            sent += 1
        }
        let overflowed = peer.connection.hasOverflowed
        #expect(overflowed, "the reserve never ran out: the queue grows without bound")
        #expect(sent > 1)
        // Flooding further adds nothing.
        for _ in 0..<1000 { peer.connection.receive(Array("{not json".utf8)) }
        let frames = peer.queue.takeAvailable()
        let queuedBytes = frames.reduce(0) { $0 + $1.count }
        #expect(queuedBytes <= 3000, "\(queuedBytes) bytes queued with a budget of 1000 and a reserve of 2000")
        #expect(frames.count == sent - 1)
        #expect(frames.allSatisfy { (try? JSON.parse($0))?["error"]?["code"] == -32700 })
    }

    @Test func secondOversizedFrameAsksForTheConnectionToBeDropped() async throws {
        let peer = QueuePeer(try makeServer(), budget: 100_000, reserve: 1000)
        #expect(peer.connection.receivedOversizedFrame() == true)
        let first = peer.takeUnwritten()
        #expect(first.count == 1)
        #expect(first.first?["error"]?["code"] == -32600)
        #expect(first.first?["id"] == .null)
        #expect(peer.connection.receivedOversizedFrame() == false)
        #expect(peer.takeUnwritten().first?["error"]?["code"] == -32600)
    }

    @Test func cancellationWithdrawsQueuedFramesFromTheRealQueueAndReleasesTheirBytes() async throws {
        let gate = ICGate()
        let reached = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "chatty")) { _, context in
            context.progress(1)
            context.log(.error, .string(String(repeating: "m", count: 500)))
            reached.enter()
            await gate.wait()
            return .text("done")
        }
        let peer = QueuePeer(server, budget: 100, reserve: 100_000)
        let id = peer.post("tools/call", ["name": "chatty"], meta: ["progressToken": 1, MetaKey.logLevel: "debug"])
        #expect(await independentConcurrencyEventually { reached.total == 1 })
        peer.cancel(id)
        #expect(peer.queue.takeAvailable().isEmpty)
        // The withdrawn frames no longer count against the budget.
        let queue = peer.queue
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(peer.queue.takeAvailable().isEmpty)
    }
}
