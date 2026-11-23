/// Where a connection puts complete outgoing frames.
///
/// The contract that makes interleaved frames impossible: `enqueue` takes a whole frame and
/// never suspends, and exactly one consumer writes frames out, one after another.
public protocol FrameSink: Sendable {
    /// Queues one complete frame (no trailing newline).
    ///
    /// - Parameters:
    ///   - key: the request this frame belongs to, so it can be withdrawn if the request is cancelled.
    ///   - urgent: the caller cannot wait for capacity (the reader thread answering a protocol
    ///     error). Urgent frames draw on a reserve; `false` is returned when it is exhausted or
    ///     the sink is closed, and the caller should drop the connection.
    ///   - replacesProgress: a progress notification; it replaces a queued, unwritten one for the same key.
    @discardableResult
    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool

    /// Suspends while the queue is over its byte budget: backpressure for request handlers.
    func waitForCapacity() async

    /// Withdraws queued, unwritten frames for a request that was cancelled.
    func discard(key: RequestID)

    /// Whether ordinary output is over its budget, that is the peer is not keeping up. Frames
    /// that are worth less than the memory they take (log messages) are not queued then.
    /// Must be `false` once the sink is closed: `waitForCapacity` returns at once then, and a
    /// caller that waits for room would otherwise never see any.
    var isOverBudget: Bool { get }
}

extension FrameSink {
    public var isOverBudget: Bool { false }

    @discardableResult
    public func enqueue(_ frame: [UInt8], key: RequestID? = nil, urgent: Bool = false) -> Bool {
        enqueue(frame, key: key, urgent: urgent, replacesProgress: false)
    }
}

/// A byte-budgeted queue of outgoing frames with a single blocking consumer.
public final class OutboundQueue: FrameSink, @unchecked Sendable {
    package final class FrameLease: Sendable {
        package let bytes: [UInt8]
        package let key: RequestID?
        fileprivate let urgent: Bool

        fileprivate init(bytes: [UInt8], key: RequestID?, urgent: Bool) {
            self.bytes = bytes
            self.key = key
            self.urgent = urgent
        }
    }

    private struct Entry {
        var frame: [UInt8]
        var key: RequestID?
        var isProgress: Bool
        var isUrgent: Bool
    }

    private let lock = ConditionLock()
    private var entries: [Entry?] = []
    private var head = 0
    private var selected: FrameLease?
    /// Ordinary bytes queued or handed to the writer but not yet written.
    private var pendingBytes = 0
    /// The same for urgent frames. They are counted apart, so that ordinary output — however
    /// far over its budget a large response takes it — never uses up the reserve.
    private var urgentBytes = 0
    /// What the writer holds right now, by kind.
    private var takenOrdinary = 0
    private var takenUrgent = 0
    /// Requests that have a progress notification in `entries`. There is never more than one
    /// per request, so progress cannot make the queue grow however often a handler reports.
    private var queuedProgress: Set<RequestID> = []
    private var closed = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0
    /// Waits cancelled before they registered their continuation.
    private var cancelledWaiters: Set<Int> = []

    /// Handlers wait while more than this many bytes are pending.
    public let budgetBytes: Int
    /// Extra room, beyond the budget, for frames whose sender cannot wait.
    public let urgentReserveBytes: Int

    public init(budgetBytes: Int, urgentReserveBytes: Int = 1 << 20) {
        self.budgetBytes = budgetBytes
        self.urgentReserveBytes = urgentReserveBytes
    }

    @discardableResult
    public func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        if urgent {
            guard urgentBytes + frame.count <= urgentReserveBytes else { return false }
            urgentBytes += frame.count
            entries.append(Entry(frame: frame, key: key, isProgress: false, isUrgent: true))
            lock.signal()
            return true
        }
        if replacesProgress, let key {
            // Only the latest unwritten progress value per request is worth sending.
            if queuedProgress.contains(key),
                let index = entries.lastIndex(where: { $0?.isProgress == true && $0?.key == key }),
                let previous = entries[index]
            {
                pendingBytes += frame.count - previous.frame.count
                entries[index]?.frame = frame
                return true
            }
            queuedProgress.insert(key)
        }
        pendingBytes += frame.count
        entries.append(Entry(frame: frame, key: key, isProgress: replacesProgress, isUrgent: false))
        lock.signal()
        return true
    }

    /// A closed queue is never "over budget": it takes nothing more, and nobody should wait
    /// for room in it.
    public var isOverBudget: Bool { lock.withLock { !closed && pendingBytes > budgetBytes } }

    /// Returns at once when the calling task is cancelled: a cancelled request has nothing left
    /// to send and must not stay parked behind a peer that does not read.
    public func waitForCapacity() async {
        let token: Int? = lock.withLock {
            if closed || pendingBytes <= budgetBytes { return nil }
            nextWaiter += 1
            return nextWaiter
        }
        guard let token else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if closed || pendingBytes <= budgetBytes || cancelledWaiters.remove(token) != nil { return true }
                    waiters[token] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                if let waiter = waiters.removeValue(forKey: token) { return waiter }
                cancelledWaiters.insert(token)
                return nil
            }
            waiter?.resume()
        }
        lock.withLock { _ = cancelledWaiters.remove(token) }
    }

    public func discard(key: RequestID) {
        lock.lock()
        var freed = 0
        var freedUrgent = 0
        entries.removeAll { entry in
            guard let entry else { return true }
            guard entry.key == key else { return false }
            if entry.isUrgent { freedUrgent += entry.frame.count } else { freed += entry.frame.count }
            return true
        }
        head = 0
        if let selected, selected.key == key {
            if selected.urgent { freedUrgent += selected.bytes.count } else { freed += selected.bytes.count }
            self.selected = nil
        }
        pendingBytes -= freed
        urgentBytes -= freedUrgent
        queuedProgress.remove(key)
        let resumable = takeWaitersIfRoom()
        lock.unlock()
        for waiter in resumable { waiter.resume() }
    }

    /// Stops accepting frames. Frames already queued are still handed to the consumer.
    public func close() {
        lock.lock()
        closed = true
        let resumable = Array(waiters.values)
        waiters = [:]
        lock.broadcast()
        lock.unlock()
        for waiter in resumable { waiter.resume() }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// What the queue holds right now: bytes queued or handed to the writer and not yet reported
    /// written, by kind, and the number of frames still queued. For metrics and for tests.
    public var usage: (ordinaryBytes: Int, urgentBytes: Int, queuedFrames: Int) {
        lock.withLock { (pendingBytes, urgentBytes, entries.count - head) }
    }

    /// Selects a single frame without committing it to the writer. Only the writer may select
    /// a frame, and it settles that frame before selecting the next one.
    package func takeFrame() -> FrameLease? {
        lock.withLock {
            precondition(selected == nil)
            while head == entries.count {
                if closed { return nil }
                lock.wait()
            }
            guard let entry = entries[head] else { preconditionFailure("queue head has no frame") }
            entries[head] = nil
            head += 1
            if head >= 64, head >= entries.count - head {
                entries.removeFirst(head)
                head = 0
            }
            if entry.isProgress, let key = entry.key { queuedProgress.remove(key) }
            let lease = FrameLease(bytes: entry.frame, key: entry.key, urgent: entry.isUrgent)
            selected = lease
            return lease
        }
    }

    package func isCurrent(_ lease: FrameLease) -> Bool { lock.withLock { selected === lease } }

    /// Runs an immediately available first write while cancellation and the writer agree on
    /// ownership. A positive write commits the whole frame. A retry leaves it withdrawable.
    package func writeIfCurrent(_ lease: FrameLease, _ write: ([UInt8]) -> Int) -> Int? {
        lock.withLock {
            guard selected === lease else { return nil }
            let written = write(lease.bytes)
            if written > 0 {
                if lease.urgent { takenUrgent += lease.bytes.count } else { takenOrdinary += lease.bytes.count }
                selected = nil
            }
            return written
        }
    }

    /// Blocks until frames are available and returns all of them, in order; `nil` once the
    /// queue is closed and drained. Call from the single writer thread.
    public func take() -> [[UInt8]]? {
        lock.lock()
        defer { lock.unlock() }
        while head == entries.count {
            if closed { return nil }
            lock.wait()
        }
        return takeLocked()
    }

    private func takeLocked() -> [[UInt8]] {
        var batch: [[UInt8]] = []
        batch.reserveCapacity(entries.count - head)
        for case let entry? in entries[head...] {
            if entry.isUrgent { takenUrgent += entry.frame.count } else { takenOrdinary += entry.frame.count }
            batch.append(entry.frame)
        }
        entries.removeAll(keepingCapacity: true)
        head = 0
        queuedProgress.removeAll(keepingCapacity: true)
        return batch
    }

    /// Non-blocking variant of `take()`; an empty array means nothing is queued.
    public func takeAvailable() -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return takeLocked()
    }

    /// The same as `didWrite()`. `bytes` is not used: the queue keeps its own account of what
    /// it handed out, by kind, and releases all of it whatever the caller passes.
    public func didWrite(bytes: Int) {
        didWrite()
    }

    /// The consumer reports that it is done with everything it took so far (written or given
    /// up on), releasing that budget and resuming handlers waiting for capacity if there is
    /// room now.
    public func didWrite() {
        lock.lock()
        if let selected {
            if selected.urgent { urgentBytes -= selected.bytes.count } else { pendingBytes -= selected.bytes.count }
            self.selected = nil
        }
        pendingBytes -= takenOrdinary
        urgentBytes -= takenUrgent
        takenOrdinary = 0
        takenUrgent = 0
        let resumable = takeWaitersIfRoom()
        lock.unlock()
        for waiter in resumable { waiter.resume() }
    }

    private func takeWaitersIfRoom() -> [CheckedContinuation<Void, Never>] {
        guard pendingBytes <= budgetBytes, !waiters.isEmpty else { return [] }
        let resumable = Array(waiters.values)
        waiters = [:]
        return resumable
    }
}
