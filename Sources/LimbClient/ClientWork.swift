import Dispatch
import Synchronization

final class ClientWorkQuota: Sendable {
    private let active = Mutex(0)
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func reserve() -> Bool {
        active.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() { active.withLock { $0 -= 1 } }
}

/// A replacement session shares these budgets with workers still retiring from older sessions.
package final class ClientExecutionQuotas: Sendable {
    let outgoing: ClientWorkQuota
    let progress: ClientWorkQuota
    let incoming: ClientWorkQuota

    package init(limit: Int) {
        outgoing = ClientWorkQuota(limit: max(1, limit))
        progress = ClientWorkQuota(limit: max(1, limit))
        incoming = ClientWorkQuota(limit: max(1, limit))
    }
}

/// User codecs and handlers run off the client actor. A stopped wait still occupies
/// a slot until its worker returns, including handlers that ignore cancellation.
final class ClientWorkPool: Sendable {
    private enum StopReason { case closed, channelLost }

    private struct Reservation {
        var stop: (@Sendable (StopReason) -> Void)?
        var handler = false
        var ended = false
    }

    private struct State {
        var closed = false
        var channelLost = false
        var lastID: UInt64 = 0
        var active: [UInt64: Reservation] = [:]
    }

    private let state = Mutex(State())
    private let quota: ClientWorkQuota

    init(limit: Int, quota: ClientWorkQuota? = nil) { self.quota = quota ?? ClientWorkQuota(limit: limit) }

    var hasActiveReservations: Bool { state.withLock { !$0.active.isEmpty } }

    func reserve() throws(ClientError) -> ClientWorkPermit {
        let id = try state.withLock { state throws(ClientError) in
            guard !state.closed else { throw .closed }
            guard !state.channelLost else { throw .connectionLost(.notSent) }
            guard state.lastID < UInt64.max, quota.reserve() else {
                throw .workOverloaded(.notSent)
            }
            state.lastID += 1
            state.active[state.lastID] = Reservation()
            return state.lastID
        }
        return ClientWorkPermit(pool: self, id: id)
    }

    func close() {
        state.withLock {
            $0.closed = true
            for reservation in $0.active.values { reservation.stop?(.closed) }
        }
    }

    func channelEnded() {
        state.withLock {
            $0.channelLost = true
            // A complete response already read from stdout can still be decoded after EOF.
            for reservation in $0.active.values where reservation.handler {
                reservation.stop?(.channelLost)
            }
        }
    }

    fileprivate func release(_ id: UInt64) {
        state.withLock {
            if $0.active[id]?.stop != nil {
                $0.active[id]?.ended = true
            } else if $0.active.removeValue(forKey: id) != nil {
                quota.release()
            }
        }
    }

    fileprivate enum Worker<Value: Sendable>: Sendable {
        case synchronous(@Sendable () throws -> Value)
        case handler(@Sendable () async throws -> Value)

        var isHandler: Bool {
            if case .handler = self { return true }
            return false
        }
    }

    fileprivate func run<Value: Sendable>(
        _ id: UInt64, until deadline: ContinuousClock.Instant, delivery: ClientDelivery,
        worker: Worker<Value>
    ) async throws -> Value {
        if Task.isCancelled { throw ClientError.cancelled(delivery) }
        guard ContinuousClock.now < deadline else { throw ClientError.timedOut(delivery) }
        let wait = ClientWorkWait<Value>(deadline: deadline, delivery: delivery)
        try state.withLock { state throws(ClientError) in
            guard !state.closed else { throw .closedDuringRequest(delivery) }
            if worker.isHandler, state.channelLost { throw .connectionLost(delivery) }
            // A permit belongs to one operation, whose work stages run consecutively.
            precondition(state.active[id] != nil && state.active[id]?.stop == nil)
            state.active[id]?.handler = worker.isHandler
            state.active[id]?.stop = { reason in
                let error: ClientError = switch reason {
                case .closed: .closedDuringRequest(delivery)
                case .channelLost: .connectionLost(delivery)
                }
                wait.finish(.failure(error))
            }
        }
        let timer = Task.detached {
            do {
                try await ContinuousClock().sleep(until: deadline)
                wait.finish(.failure(ClientError.timedOut(delivery)))
            } catch {}
        }
        defer { timer.cancel() }
        let handler = Mutex<Task<Void, Never>?>(nil)
        defer {
            // Task.cancel() can run application cancellation hooks synchronously.
            if let task = handler.withLock({ $0 }), wait.stopped {
                Task.detached { task.cancel() }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard wait.register(continuation) else {
                    retire(id, wait, result: .failure(ClientError.cancelled(delivery)))
                    return
                }
                switch worker {
                case .synchronous(let body):
                    DispatchQueue.global().async {
                        guard wait.canStart else {
                            self.retire(id, wait, result: .failure(ClientError.timedOut(delivery)))
                            return
                        }
                        self.retire(id, wait, result: Result(catching: body))
                    }
                case .handler(let body):
                    let task = Task.detached {
                        guard wait.canStart else {
                            self.retire(id, wait, result: .failure(ClientError.timedOut(delivery)))
                            return
                        }
                        do { self.retire(id, wait, result: .success(try await body())) }
                        catch { self.retire(id, wait, result: .failure(error)) }
                    }
                    handler.withLock { $0 = task }
                }
            }
        } onCancel: {
            wait.finish(.failure(ClientError.cancelled(delivery)))
        }
    }

    private func retire<Value>(_ id: UInt64, _ wait: ClientWorkWait<Value>, result: Result<Value, any Error>) {
        state.withLock {
            if $0.active[id]?.ended == true {
                $0.active.removeValue(forKey: id)
                quota.release()
            } else {
                $0.active[id]?.stop = nil
                $0.active[id]?.handler = false
            }
            wait.finish(result, stopping: false)
        }
    }
}

/// Capacity is reserved before sending. The pool waits for both the operation and its worker
/// to end before making the reservation available again.
final class ClientWorkPermit: Sendable {
    private let pool: ClientWorkPool
    private let id: UInt64

    fileprivate init(pool: ClientWorkPool, id: UInt64) {
        self.pool = pool
        self.id = id
    }

    deinit { pool.release(id) }

    func run<Value: Sendable>(
        until deadline: ContinuousClock.Instant, delivery: ClientDelivery,
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await pool.run(id, until: deadline, delivery: delivery, worker: .synchronous(body))
    }

    func runHandler<Value: Sendable>(
        until deadline: ContinuousClock.Instant, _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await pool.run(id, until: deadline, delivery: .unknown, worker: .handler(body))
    }
}

private final class ClientWorkWait<Value: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Value, any Error>? = nil)
        case finished(Result<Value, any Error>, stopped: Bool)
    }

    private let state = Mutex<State>(.waiting())
    private let deadline: ContinuousClock.Instant
    private let delivery: ClientDelivery

    init(deadline: ContinuousClock.Instant, delivery: ClientDelivery) {
        self.deadline = deadline
        self.delivery = delivery
    }

    var canStart: Bool {
        state.withLock {
            guard case .waiting = $0 else { return false }
            return ContinuousClock.now < deadline
        }
    }

    var stopped: Bool {
        state.withLock {
            if case .finished(_, let stopped) = $0 { return stopped }
            return false
        }
    }

    func register(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        state.withLock {
            switch $0 {
            case .waiting:
                $0 = .waiting(continuation)
                return true
            case .finished(let result, _):
                continuation.resume(with: result)
                return false
            }
        }
    }

    func finish(_ result: Result<Value, any Error>, stopping: Bool = true) {
        state.withLock {
            guard case .waiting(let continuation) = $0 else { return }
            let outcome = ContinuousClock.now < deadline ? result : .failure(ClientError.timedOut(delivery))
            $0 = .finished(outcome, stopped: stopping)
            continuation?.resume(with: outcome)
        }
    }
}
