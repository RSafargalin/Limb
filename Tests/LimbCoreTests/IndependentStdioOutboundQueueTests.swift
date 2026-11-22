import Foundation
import LimbCore
import Synchronization
import Testing


/// What the queue reports about itself, in a comparable form.
private struct Usage: Equatable, CustomStringConvertible {
    var ordinary: Int
    var urgent: Int
    var frames: Int
    init(_ ordinary: Int, _ urgent: Int, _ frames: Int) {
        self.ordinary = ordinary
        self.urgent = urgent
        self.frames = frames
    }
    init(_ queue: OutboundQueue) {
        let usage = queue.usage
        self.init(usage.ordinaryBytes, usage.urgentBytes, usage.queuedFrames)
    }
    var description: String { "(ordinary \(ordinary), urgent \(urgent), frames \(frames))" }
}

private func frame(_ text: String) -> [UInt8] { Array(text.utf8) }
private func text(_ frames: [[UInt8]]?) -> [String]? { frames?.map { String(decoding: $0, as: UTF8.self) } }

/// Runs `body` on its own thread and lets the test wait for it with a deadline, so a consumer
/// that never wakes fails the test instead of stalling the suite.
private final class Background<Value: Sendable>: Sendable {
    private let result = Mutex<Value?>(nil)

    init(_ body: @escaping @Sendable () -> Value) {
        let thread = Thread { [self] in
            let value = body()
            self.result.withLock { $0 = value }
        }
        thread.start()
    }

    var value: Value? { result.withLock { $0 } }

    func wait(seconds: Double) -> Value? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value { return value }
            usleep(2000)
        }
        return value
    }
}

private struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

private final class Flag: Sendable {
    private let state = Mutex(0)
    func raise() { state.withLock { $0 += 1 } }
    var count: Int { state.withLock { $0 } }
    func reaches(_ target: Int, seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if count >= target { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return count >= target
    }
}

@Suite struct IndependentStdioOutboundQueueTests {
    // MARK: Order and delivery

    @Test func framesComeOutInTheOrderTheyWentIn() {
        let queue = OutboundQueue(budgetBytes: 1 << 20)
        for index in 0..<100 { #expect(queue.enqueue(frame("f\(index)"))) }
        #expect(text(queue.take()) == (0..<100).map { "f\($0)" })
        #expect(queue.takeAvailable().isEmpty)
    }

    @Test func takeBlocksUntilAFrameArrives() {
        let queue = OutboundQueue(budgetBytes: 1024)
        let consumer = Background { text(queue.take()) }
        #expect(consumer.wait(seconds: 0.2) == nil, "take() returned although nothing was queued")
        #expect(queue.enqueue(frame("late")))
        #expect(consumer.wait(seconds: 10) == ["late"])
    }

    @Test func closeWakesABlockedConsumerWithNil() {
        let queue = OutboundQueue(budgetBytes: 1024)
        let consumer = Background { queue.take() == nil }
        #expect(consumer.wait(seconds: 0.1) == nil)
        queue.close()
        #expect(consumer.wait(seconds: 10) == true)
    }

    @Test func framesQueuedBeforeCloseAreStillHandedOutAndNothingIsAcceptedAfter() {
        let queue = OutboundQueue(budgetBytes: 1024)
        #expect(!queue.isClosed)
        #expect(queue.enqueue(frame("a")))
        #expect(queue.enqueue(frame("b"), key: 7))
        queue.close()
        #expect(queue.isClosed)
        #expect(!queue.enqueue(frame("c")))
        #expect(!queue.enqueue(frame("d"), key: nil, urgent: true))
        #expect(!queue.enqueue(frame("e"), key: 7, urgent: false, replacesProgress: true))
        #expect(text(queue.take()) == ["a", "b"])
        #expect(queue.take() == nil)
        #expect(queue.take() == nil)
        #expect(queue.takeAvailable().isEmpty)
        queue.close()
        #expect(queue.take() == nil)
    }

    @Test func takeAvailableNeverBlocks() {
        let queue = OutboundQueue(budgetBytes: 1024)
        #expect(queue.takeAvailable().isEmpty)
        queue.enqueue(frame("x"))
        queue.enqueue(frame("y"))
        #expect(text(queue.takeAvailable()) == ["x", "y"])
        #expect(queue.takeAvailable().isEmpty)
    }

    /// Many producers, one consumer: every frame exactly once, each producer's frames in order.
    @Test func concurrentProducersLoseAndDuplicateNothing() {
        let queue = OutboundQueue(budgetBytes: 1 << 16)
        let producers = 8
        let perProducer = 4000
        let consumer = Background { () -> [[UInt8]] in
            var all: [[UInt8]] = []
            while let batch = queue.take() {
                all += batch
                queue.didWrite(bytes: batch.reduce(0) { $0 + $1.count })
            }
            return all
        }
        let finished = (0..<producers).map { producer in
            Background { () -> Bool in
                for sequence in 0..<perProducer {
                    if !queue.enqueue(frame("\(producer):\(sequence)"), key: RequestID(producer), urgent: false, replacesProgress: false) {
                        return false
                    }
                    if sequence % 97 == 0 { sched_yield() }
                }
                return true
            }
        }
        for producer in finished { #expect(producer.wait(seconds: 60) == true) }
        queue.close()
        guard let all = consumer.wait(seconds: 60) else {
            Issue.record("the consumer did not finish after close()")
            return
        }
        #expect(all.count == producers * perProducer)
        var next = [Int](repeating: 0, count: producers)
        var outOfOrder = 0
        for entry in all {
            let parts = String(decoding: entry, as: UTF8.self).split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else {
                outOfOrder += 1
                continue
            }
            if next[parts[0]] != parts[1] { outOfOrder += 1 }
            next[parts[0]] = parts[1] + 1
        }
        #expect(outOfOrder == 0)
        #expect(next == [Int](repeating: perProducer, count: producers))
        #expect(Usage(queue) == Usage(0, 0, 0))
        #expect(!queue.enqueue(frame("late"), key: nil, urgent: true), "a closed queue accepts no urgent frame")
    }

    // MARK: Budget and reserve

    @Test func usageReportsWhatIsQueuedByKind() {
        let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 50)
        #expect(Usage(queue) == Usage(0, 0, 0))
        queue.enqueue([UInt8](repeating: 1, count: 37))
        queue.enqueue([UInt8](repeating: 1, count: 5), key: 1, urgent: true)
        queue.enqueue([UInt8](repeating: 1, count: 3), key: 1, urgent: false, replacesProgress: true)
        #expect(Usage(queue) == Usage(40, 5, 3))
        #expect(!queue.isOverBudget)
        queue.enqueue([UInt8](repeating: 1, count: 61))
        #expect(Usage(queue) == Usage(101, 5, 4))
        #expect(queue.isOverBudget)
    }

    /// `FrameSink.enqueue`: "Urgent frames draw on a reserve; false is returned when it is
    /// exhausted". The reserve is for urgent frames alone: ordinary output neither uses it up
    /// nor is helped by it.
    @Test func urgentFramesDrawOnTheReserveAndAreRefusedWhenItIsExhausted() {
        let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 50)
        #expect(queue.enqueue([UInt8](repeating: 2, count: 30), key: nil, urgent: true))
        #expect(queue.enqueue([UInt8](repeating: 3, count: 20), key: nil, urgent: true))
        // Exactly full.
        #expect(!queue.enqueue([UInt8](repeating: 4, count: 1), key: nil, urgent: true))
        #expect(queue.enqueue([UInt8](), key: nil, urgent: true))
        #expect(Usage(queue) == Usage(0, 50, 3))
        // Refused frames are not queued.
        #expect(queue.takeAvailable().map(\.count) == [30, 20, 0])
        // Handed to the writer is not written: the reserve is still in use.
        #expect(!queue.enqueue([UInt8](repeating: 4, count: 1), key: nil, urgent: true))
        queue.didWrite(bytes: 50)
        #expect(queue.enqueue([UInt8](repeating: 4, count: 50), key: nil, urgent: true))
        #expect(!queue.enqueue([UInt8](repeating: 4, count: 1), key: nil, urgent: true))
    }

    @Test func theReserveIsHonouredWhateverTheOrdinaryLoad() {
        let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 50)
        for _ in 0..<20 { #expect(queue.enqueue([UInt8](repeating: 1, count: 1000))) }
        #expect(queue.isOverBudget)
        #expect(queue.enqueue([UInt8](repeating: 2, count: 50), key: nil, urgent: true))
        #expect(!queue.enqueue([UInt8](repeating: 2, count: 1), key: nil, urgent: true))
        #expect(Usage(queue) == Usage(20_000, 50, 21))
        // An urgent frame larger than the whole reserve can never be sent.
        let empty = OutboundQueue(budgetBytes: 1 << 20, urgentReserveBytes: 50)
        #expect(!empty.enqueue([UInt8](repeating: 2, count: 51), key: nil, urgent: true))
        #expect(Usage(empty) == Usage(0, 0, 0))
    }

    /// "Bytes queued or handed to the writer but not yet written": frames the writer took still
    /// count until it reports them, otherwise a blocked writer would hide its backlog.
    @Test func framesHandedToTheWriterCountUntilItReportsThem() {
        let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 50)
        queue.enqueue([UInt8](repeating: 1, count: 150))
        queue.enqueue([UInt8](repeating: 1, count: 40), key: nil, urgent: true)
        #expect(queue.take()?.count == 2)
        #expect(Usage(queue) == Usage(150, 40, 0))
        #expect(queue.isOverBudget)
        // Queued while the writer is busy: not part of what it reports next.
        queue.enqueue([UInt8](repeating: 1, count: 7))
        queue.enqueue([UInt8](repeating: 1, count: 3), key: nil, urgent: true)
        queue.didWrite(bytes: 190)
        #expect(Usage(queue) == Usage(7, 3, 2))
        #expect(!queue.isOverBudget)
        // A report with nothing taken releases nothing.
        queue.didWrite(bytes: 10)
        #expect(Usage(queue) == Usage(7, 3, 2))
        #expect(queue.takeAvailable().count == 2)
        queue.didWrite(bytes: 10)
        #expect(Usage(queue) == Usage(0, 0, 0))
    }

    @Test func ordinaryFramesAreNotRefusedOverBudget() {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 5)
        #expect(queue.enqueue([UInt8](repeating: 1, count: 1000)))
        #expect(queue.enqueue([UInt8](repeating: 1, count: 1000)))
        #expect(Usage(queue) == Usage(2000, 0, 2))
    }

    @Test(arguments: [0, 1, Int.max])
    func extremeBudgetsDoNotTrap(budget: Int) {
        for reserve in [0, 1, Int.max] {
            let queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: reserve)
            #expect(queue.enqueue([1, 2, 3], key: nil, urgent: true) == (reserve >= 3))
            #expect(queue.enqueue([1, 2, 3], key: 1, urgent: false, replacesProgress: true))
            #expect(queue.enqueue([1], key: 1, urgent: false, replacesProgress: true))
            #expect(queue.enqueue([UInt8]()))
            #expect(queue.isOverBudget == (budget < 1))
            #expect(Usage(queue) == Usage(1, reserve >= 3 ? 3 : 0, reserve >= 3 ? 3 : 2))
            queue.discard(key: 1)
            #expect(queue.take() != nil)
            queue.didWrite(bytes: .max)
            #expect(Usage(queue) == Usage(0, 0, 0))
        }
    }

    // MARK: waitForCapacity

    @Test func waitForCapacityReturnsAtOnceWithinTheBudget() async {
        let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 0)
        let passed = Flag()
        let empty = Task {
            await queue.waitForCapacity()
            passed.raise()
        }
        #expect(await passed.reaches(1, seconds: 10))
        // "Suspends while the queue is over its byte budget": exactly at the budget is not over.
        queue.enqueue([UInt8](repeating: 1, count: 100))
        let atBudget = Task {
            await queue.waitForCapacity()
            passed.raise()
        }
        #expect(await passed.reaches(2, seconds: 10))
        _ = (empty, atBudget)
    }

    @Test func waitForCapacitySuspendsOverBudgetUntilTheWriterCatchesUp() async {
        let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 1000)
        queue.enqueue([UInt8](repeating: 1, count: 60))
        queue.enqueue([UInt8](repeating: 1, count: 60))
        let resumed = Flag()
        let waiters = (0..<5).map { _ in
            Task {
                await queue.waitForCapacity()
                resumed.raise()
            }
        }
        #expect(await !resumed.reaches(1, seconds: 0.2), "resumed while 120 of 100 bytes were pending")
        #expect(queue.take()?.count == 2)
        // Taking is not writing.
        #expect(await !resumed.reaches(1, seconds: 0.1), "resumed before the writer reported anything")
        // More output arrives while the writer is busy; what it reports covers what it took.
        queue.enqueue([UInt8](repeating: 1, count: 101))
        queue.didWrite(bytes: 120)
        #expect(await !resumed.reaches(1, seconds: 0.1), "resumed while 101 of 100 bytes were pending")
        #expect(queue.take()?.count == 1)
        queue.enqueue([UInt8](repeating: 1, count: 100))
        queue.didWrite(bytes: 101)
        #expect(await resumed.reaches(5, seconds: 10), "not every waiter resumed at 100 of 100 bytes")
        _ = waiters
    }

    /// Urgent frames are not the handlers' business: they neither make handlers wait nor
    /// count as ordinary output over budget.
    @Test func urgentFramesDoNotMakeHandlersWait() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 1000)
        #expect(queue.enqueue([UInt8](repeating: 1, count: 900), key: nil, urgent: true))
        #expect(!queue.isOverBudget)
        let passed = Flag()
        let waiter = Task {
            await queue.waitForCapacity()
            passed.raise()
        }
        #expect(await passed.reaches(1, seconds: 10))
        _ = waiter
    }

    @Test func closeReleasesWaiters() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 0)
        queue.enqueue([UInt8](repeating: 1, count: 50))
        let resumed = Flag()
        let waiter = Task {
            await queue.waitForCapacity()
            resumed.raise()
        }
        #expect(await !resumed.reaches(1, seconds: 0.1))
        queue.close()
        #expect(await resumed.reaches(1, seconds: 10))
        // And nobody waits on a closed queue.
        let late = Task {
            await queue.waitForCapacity()
            resumed.raise()
        }
        #expect(await resumed.reaches(2, seconds: 10))
        _ = (waiter, late)
    }

    /// `isOverBudget`: "Must be `false` once the sink is closed: `waitForCapacity` returns at
    /// once then". Bytes still pending do not change that.
    @Test func aClosedQueueIsNeverOverBudget() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 0)
        queue.enqueue([UInt8](repeating: 1, count: 50))
        #expect(queue.isOverBudget)
        queue.close()
        #expect(!queue.isOverBudget)
        #expect(Usage(queue) == Usage(50, 0, 1))
        let passed = Flag()
        let waiter = Task {
            await queue.waitForCapacity()
            passed.raise()
        }
        #expect(await passed.reaches(1, seconds: 10))
        _ = waiter
    }

    /// "Returns at once when the calling task is cancelled: a cancelled request has nothing left
    /// to send and must not stay parked behind a peer that does not read."
    @Test func waitForCapacityReturnsAtOnceForACancelledTask() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 0)
        queue.enqueue([UInt8](repeating: 1, count: 50))
        let passed = Flag()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await queue.waitForCapacity()
            passed.raise()
        }
        #expect(await passed.reaches(1, seconds: 10), "a task cancelled before it asked was parked")
        _ = waiter
        #expect(Usage(queue) == Usage(50, 0, 1))
    }

    /// A task cancelled while it waits is let go at once; the others keep waiting until there
    /// is room, and then all of them go.
    @Test func cancellingOneWaiterReleasesOnlyThatOne() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 0)
        queue.enqueue([UInt8](repeating: 1, count: 50))
        let resumed = Flag()
        let cancelledResumed = Flag()
        let waiters = (0..<4).map { _ in
            Task {
                await queue.waitForCapacity()
                resumed.raise()
            }
        }
        let victim = Task {
            await queue.waitForCapacity()
            cancelledResumed.raise()
        }
        #expect(await !cancelledResumed.reaches(1, seconds: 0.1))
        victim.cancel()
        #expect(await cancelledResumed.reaches(1, seconds: 10), "a waiting task that was cancelled stayed parked")
        #expect(await !resumed.reaches(1, seconds: 0.1), "cancelling one waiter let others go while over budget")
        #expect(queue.take()?.count == 1)
        queue.didWrite(bytes: 50)
        #expect(await resumed.reaches(4, seconds: 10))
        _ = waiters
    }

    /// Cancellation at every moment relative to the wait: before it, while it registers, while
    /// it is parked, at the same time as room appears. No waiter is ever lost (each returns),
    /// and none returns while over budget unless it was cancelled or the queue closed.
    @Test(arguments: 1...4)
    func cancellationRacingWithRoomLosesNoWaiter(seed: Int) async {
        var rng = SplitMix(UInt64(seed))
        for _ in 0..<40 {
            let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 0)
            queue.enqueue([UInt8](repeating: 1, count: 150))
            let early = Flag()
            let total = 60
            let returned = Flag()
            var tasks: [Task<Void, Never>] = []
            var cancelled = Set<Int>()
            for index in 0..<total {
                tasks.append(Task {
                    await queue.waitForCapacity()
                    if !Task.isCancelled, queue.usage.ordinaryBytes > 100, !queue.isClosed { early.raise() }
                    returned.raise()
                })
                if rng.below(3) == 0 {
                    cancelled.insert(index)
                    if rng.below(2) == 0 { await Task.yield() }
                    tasks[index].cancel()
                }
            }
            await Task.yield()
            switch rng.below(3) {
            case 0:
                _ = queue.takeAvailable()
                queue.didWrite(bytes: 150)
            case 1:
                queue.close()
            default:
                for (index, task) in tasks.enumerated() where !cancelled.contains(index) { task.cancel() }
            }
            #expect(await returned.reaches(total, seconds: 20), "\(total - returned.count) of \(total) waiters never returned")
            #expect(early.count == 0, "a waiter returned while over budget although neither cancelled nor closed")
        }
    }

    @Test func discardingACancelledRequestsFramesReleasesWaiters() async {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 0)
        queue.enqueue([UInt8](repeating: 1, count: 50), key: 1)
        queue.enqueue([UInt8](repeating: 1, count: 5), key: 2)
        let resumed = Flag()
        let waiter = Task {
            await queue.waitForCapacity()
            resumed.raise()
        }
        #expect(await !resumed.reaches(1, seconds: 0.1))
        queue.discard(key: 1)
        #expect(await resumed.reaches(1, seconds: 10))
        _ = waiter
    }

    // MARK: Withdrawing frames of a cancelled request (§7.2)

    @Test func discardWithdrawsOnlyThatRequestsUnwrittenFrames() {
        let queue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 100)
        queue.enqueue(frame("a1"), key: 1)
        queue.enqueue(frame("none"))
        queue.enqueue(frame("b1"), key: 2)
        queue.enqueue(frame("a2-progress"), key: 1, urgent: false, replacesProgress: true)
        queue.enqueue(frame("s1"), key: "1")
        queue.enqueue(frame("a3"), key: 1, urgent: true)
        #expect(Usage(queue) == Usage(2 + 4 + 2 + 11 + 2, 2, 6))
        queue.discard(key: 1)
        #expect(Usage(queue) == Usage(4 + 2 + 2, 0, 3))
        queue.discard(key: 99)
        #expect(Usage(queue) == Usage(8, 0, 3))
        // The string id "1" is a different request from the number 1 (RequestID: "the two never
        // convert into each other").
        #expect(text(queue.takeAvailable()) == ["none", "b1", "s1"])
        queue.didWrite(bytes: 8)
        #expect(Usage(queue) == Usage(0, 0, 0))
    }

    @Test func discardCannotWithdrawWhatTheWriterAlreadyTookAndTheBudgetStillBalances() {
        let queue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 100)
        queue.enqueue([UInt8](repeating: 1, count: 100), key: 1)
        queue.enqueue([UInt8](repeating: 1, count: 30), key: 1, urgent: true)
        queue.enqueue([UInt8](repeating: 1, count: 9), key: 1, urgent: false, replacesProgress: true)
        #expect(queue.take()?.count == 3)
        // The same request queues more while the writer holds the first three.
        queue.enqueue([UInt8](repeating: 2, count: 40), key: 1)
        queue.enqueue([UInt8](repeating: 2, count: 5), key: 1, urgent: true)
        queue.enqueue([UInt8](repeating: 2, count: 6), key: 1, urgent: false, replacesProgress: true)
        #expect(Usage(queue) == Usage(109 + 46, 35, 3))
        queue.discard(key: 1)
        // Only what was still queued is withdrawn; what the writer holds stays on the books
        // until it reports.
        #expect(Usage(queue) == Usage(109, 30, 0))
        #expect(queue.takeAvailable().isEmpty)
        // The request id is free again: a new request with it queues progress of its own.
        queue.enqueue([UInt8](repeating: 3, count: 4), key: 1, urgent: false, replacesProgress: true)
        queue.enqueue([UInt8](repeating: 3, count: 2), key: 1, urgent: false, replacesProgress: true)
        #expect(Usage(queue) == Usage(109 + 2, 30, 1))
        queue.didWrite(bytes: 139)
        #expect(Usage(queue) == Usage(2, 0, 1))
        queue.discard(key: 1)
        #expect(Usage(queue) == Usage(0, 0, 0))
        queue.didWrite(bytes: 0)
        #expect(Usage(queue) == Usage(0, 0, 0))
    }

    // MARK: Progress coalescing (§7.3)

    @Test func aNewProgressValueReplacesTheQueuedOneForTheSameRequest() {
        let queue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 0)
        queue.enqueue(frame("p1=1"), key: 1, urgent: false, replacesProgress: true)
        queue.enqueue(frame("other"), key: 2)
        queue.enqueue(frame("p2=1"), key: 2, urgent: false, replacesProgress: true)
        queue.enqueue(frame("p1=2-longer"), key: 1, urgent: false, replacesProgress: true)
        queue.enqueue(frame("p1=3"), key: 1, urgent: false, replacesProgress: true)
        #expect(Usage(queue) == Usage(4 + 5 + 4, 0, 3))
        let frames = text(queue.takeAvailable()) ?? []
        #expect(frames.sorted() == ["other", "p1=3", "p2=1"])
        #expect(frames.filter { $0.hasPrefix("p1") } == ["p1=3"])
    }

    @Test func progressNeverReplacesAnythingButProgressOfTheSameRequest() {
        let queue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 0)
        queue.enqueue(frame("log"), key: 1)
        queue.enqueue(frame("p-other"), key: 2, urgent: false, replacesProgress: true)
        queue.enqueue(frame("p-none"), key: nil, urgent: false, replacesProgress: true)
        queue.enqueue(frame("p1"), key: 1, urgent: false, replacesProgress: true)
        queue.enqueue(frame("p-none-2"), key: nil, urgent: false, replacesProgress: true)
        #expect(text(queue.takeAvailable()) == ["log", "p-other", "p-none", "p1", "p-none-2"])
    }

    @Test func progressAlreadyHandedToTheWriterIsNotReplaced() {
        let queue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 0)
        queue.enqueue(frame("p=1"), key: 1, urgent: false, replacesProgress: true)
        #expect(text(queue.take()) == ["p=1"])
        queue.enqueue(frame("p=2"), key: 1, urgent: false, replacesProgress: true)
        #expect(text(queue.take()) == ["p=2"])
    }

    @Test func progressStaysCoalescedHoweverManyRequestsReportIt() {
        let queue = OutboundQueue(budgetBytes: 1 << 20, urgentReserveBytes: 0)
        let requests = 100
        for round in 1...50 {
            for request in 0..<requests {
                queue.enqueue(frame("progress \(request)=\(round)"), key: RequestID(request), urgent: false, replacesProgress: true)
            }
        }
        let frames = text(queue.takeAvailable()) ?? []
        #expect(frames.count == requests, "\(frames.count) progress frames queued for \(requests) requests")
        #expect(Set(frames) == Set((0..<requests).map { "progress \($0)=50" }))
    }

    @Test func progressBehindManyOtherFramesIsStillReplaced() {
        let queue = OutboundQueue(budgetBytes: 1 << 20, urgentReserveBytes: 0)
        queue.enqueue(frame("p=1"), key: 1, urgent: false, replacesProgress: true)
        for index in 0..<100 { queue.enqueue(frame("log \(index)"), key: 2) }
        queue.enqueue(frame("p=2"), key: 1, urgent: false, replacesProgress: true)
        let progress = (text(queue.takeAvailable()) ?? []).filter { $0.hasPrefix("p=") }
        #expect(progress == ["p=2"])
    }

    // MARK: Mixed load

    /// Producers, cancellations and a consumer at once. At the end the accounting is back to
    /// zero, every frame was delivered at most once, in per-producer order, and a frame that
    /// was neither delivered nor withdrawn does not exist.
    @Test func mixedLoadKeepsTheAccountingExact() {
        let queue = OutboundQueue(budgetBytes: 4096, urgentReserveBytes: 4096)
        let producers = 6
        let perProducer = 3000
        let delivered = Mutex<[String]>([])
        // The consumer leaves when it meets this frame, so that the counters are read with
        // nobody else touching the queue.
        let last = "last"
        let consumer = Background { () -> Bool in
            while let batch = queue.take() {
                let names = batch.map { String(decoding: $0, as: UTF8.self) }
                delivered.withLock { $0 += names.filter { $0 != last } }
                queue.didWrite(bytes: batch.reduce(0) { $0 + $1.count })
                if names.contains(last) { return true }
            }
            return false
        }
        let accepted = Mutex<Set<String>>([])
        let workers = (0..<producers).map { producer in
            Background { () -> Bool in
                for sequence in 0..<perProducer {
                    let name = "\(producer):\(sequence)"
                    let urgent = sequence % 5 == 0
                    if queue.enqueue(frame(name), key: RequestID(producer * 10 + sequence % 3), urgent: urgent, replacesProgress: false) {
                        accepted.withLock { _ = $0.insert(name) }
                    }
                    if sequence % 50 == 49 { queue.discard(key: RequestID(producer * 10 + 1)) }
                }
                return true
            }
        }
        for worker in workers { #expect(worker.wait(seconds: 60) == true) }
        #expect(queue.enqueue(frame(last)))
        #expect(consumer.wait(seconds: 30) == true, "the consumer never saw the last frame")
        #expect(Usage(queue) == Usage(0, 0, 0))
        queue.close()
        let all = delivered.withLock { $0 }
        #expect(Set(all).count == all.count, "a frame was delivered twice")
        #expect(Set(all).isSubset(of: accepted.withLock { $0 }))
        var newest = [Int](repeating: -1, count: producers)
        var outOfOrder = 0
        for name in all {
            let parts = name.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else {
                outOfOrder += 1
                continue
            }
            if parts[1] <= newest[parts[0]] { outOfOrder += 1 }
            newest[parts[0]] = parts[1]
        }
        #expect(outOfOrder == 0)
        // Frames with a key that was never discarded all arrive.
        let neverDiscarded = accepted.withLock { $0 }.filter { name in
            let parts = name.split(separator: ":").compactMap { Int($0) }
            return parts[1] % 3 != 1
        }
        #expect(neverDiscarded.isSubset(of: Set(all)))
    }

    // MARK: Against a model

    /// Random enqueue / discard / take / didWrite on one thread, checked step by step against
    /// a model of the documented rules:
    ///
    ///   * an urgent frame is accepted exactly when urgent bytes alone stay within the reserve;
    ///   * an ordinary frame is always accepted;
    ///   * a progress frame replaces the queued progress frame of the same request, in place;
    ///   * `discard` withdraws what is queued for a request and nothing the writer holds;
    ///   * `take` hands out everything, in order; `didWrite` releases what was taken;
    ///   * the counters are the sum of what is queued and what the writer holds.
    @Test(arguments: 1...12)
    func randomOperationsMatchAModel(seed: Int) {
        struct Item: Equatable {
            var bytes: [UInt8]
            var key: RequestID?
            var urgent: Bool
            var progress: Bool
        }
        var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let budget = [0, 1, 500, 5000, Int.max][seed % 5]
        let reserve = [0, 64, 300, 2000][seed % 4]
        let queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: reserve)
        var queued: [Item] = []
        var takenOrdinary = 0
        var takenUrgent = 0
        var counter = 0
        var mismatches: [String] = []
        func note(_ text: String) { if mismatches.count < 5 { mismatches.append("step \(counter): \(text)") } }

        for _ in 0..<6000 {
            counter += 1
            let key: RequestID? = next(5) == 0 ? nil : (next(2) == 0 ? RequestID(next(6)) : RequestID("s\(next(3))"))
            let size = [0, 1, 7, 60, 250][next(5)] + next(3)
            let bytes = (0..<size).map { _ in UInt8(truncatingIfNeeded: counter) }
            switch next(20) {
            case 0...6:
                #expect(queue.enqueue(bytes, key: key, urgent: false, replacesProgress: false))
                queued.append(Item(bytes: bytes, key: key, urgent: false, progress: false))
            case 7...10:
                let urgentQueued = queued.filter(\.urgent).reduce(0) { $0 + $1.bytes.count } + takenUrgent
                let expected = urgentQueued + size <= reserve
                if queue.enqueue(bytes, key: key, urgent: true, replacesProgress: false) != expected {
                    note("urgent frame of \(size) bytes with \(urgentQueued) of \(reserve) in use: accepted \(!expected)")
                }
                if expected { queued.append(Item(bytes: bytes, key: key, urgent: true, progress: false)) }
            case 11...14:
                #expect(queue.enqueue(bytes, key: key, urgent: false, replacesProgress: true))
                if let key, let index = queued.lastIndex(where: { $0.progress && $0.key == key }) {
                    queued[index].bytes = bytes
                } else {
                    queued.append(Item(bytes: bytes, key: key, urgent: false, progress: true))
                }
            case 15, 16:
                if let key {
                    queue.discard(key: key)
                    queued.removeAll { $0.key == key }
                }
            case 17, 18:
                let batch = queue.takeAvailable()
                if batch != queued.map(\.bytes) { note("take returned \(batch.count) frames, the model has \(queued.count)") }
                takenOrdinary += queued.filter { !$0.urgent }.reduce(0) { $0 + $1.bytes.count }
                takenUrgent += queued.filter(\.urgent).reduce(0) { $0 + $1.bytes.count }
                queued = []
            default:
                queue.didWrite(bytes: takenOrdinary + takenUrgent)
                takenOrdinary = 0
                takenUrgent = 0
            }
            let expected = Usage(
                queued.filter { !$0.urgent }.reduce(0) { $0 + $1.bytes.count } + takenOrdinary,
                queued.filter(\.urgent).reduce(0) { $0 + $1.bytes.count } + takenUrgent, queued.count)
            if Usage(queue) != expected { note("usage \(Usage(queue)), model \(expected)") }
            if queue.isOverBudget != (expected.ordinary > budget) { note("isOverBudget \(queue.isOverBudget) with \(expected.ordinary) of \(budget)") }
            // At most one queued progress frame per request (§7.3).
            let progressKeys = queued.filter { $0.progress && $0.key != nil }.map { $0.key! }
            if Set(progressKeys).count != progressKeys.count { note("the model itself holds two progress frames for a request") }
        }
        #expect(mismatches == [], "seed \(seed), budget \(budget), reserve \(reserve)")
        // Everything leaves; the counters return to zero.
        queue.close()
        var rest: [[UInt8]] = []
        while let batch = queue.take() { rest += batch }
        #expect(rest == queued.map(\.bytes))
        queue.didWrite(bytes: 0)
        #expect(Usage(queue) == Usage(0, 0, 0))
    }

    @Test func replacingProgressBehindALongQueueStaysAffordable() {
        let queue = OutboundQueue(budgetBytes: .max, urgentReserveBytes: 0)
        queue.enqueue(frame("p"), key: 1, urgent: false, replacesProgress: true)
        for _ in 0..<50_000 { queue.enqueue([0x78], key: 2) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for round in 0..<500 { queue.enqueue(frame("p\(round)"), key: 1, urgent: false, replacesProgress: true) }
        }
        #expect(Usage(queue).frames == 50_001)
        #expect(elapsed < .seconds(30), "500 progress updates behind 50 000 frames took \(elapsed)")
    }
}

@Suite struct IndependentStdioConditionLockTests {
    @Test func withLockExcludesOtherThreads() {
        let lock = ConditionLock()
        nonisolated(unsafe) var counter = 0
        let workers = (0..<8).map { _ in
            Background { () -> Bool in
                for _ in 0..<20_000 { lock.withLock { counter += 1 } }
                return true
            }
        }
        for worker in workers { #expect(worker.wait(seconds: 60) == true) }
        #expect(lock.withLock { counter } == 160_000)
    }

    @Test func withLockReleasesWhenTheBodyThrows() {
        struct Failure: Error {}
        let lock = ConditionLock()
        #expect(throws: Failure.self) { try lock.withLock { throw Failure() } }
        let reentered = Background { lock.withLock { true } }
        #expect(reentered.wait(seconds: 10) == true)
    }

    @Test func signalWakesAWaiterAndBroadcastWakesAll() {
        let lock = ConditionLock()
        nonisolated(unsafe) var tokens = 0
        nonisolated(unsafe) var open = false
        let waiters = (0..<6).map { _ in
            Background { () -> Bool in
                lock.lock()
                while tokens == 0 && !open { lock.wait() }
                if tokens > 0 { tokens -= 1 }
                lock.unlock()
                return true
            }
        }
        usleep(50_000)
        #expect(waiters.allSatisfy { $0.value == nil })
        lock.withLock { tokens = 1 }
        lock.signal()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, waiters.count(where: { $0.value != nil }) < 1 { usleep(1000) }
        usleep(50_000)
        #expect(waiters.count { $0.value != nil } == 1)
        lock.withLock { open = true }
        lock.broadcast()
        for waiter in waiters { #expect(waiter.wait(seconds: 10) == true) }
    }
}
