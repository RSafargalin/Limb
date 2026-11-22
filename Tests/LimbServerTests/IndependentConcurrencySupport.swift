import Limb
import LimbTesting
import Synchronization
import Testing

// Shared helpers of the independent concurrency test pass. Everything here is prefixed
// `IndependentConcurrency` so it cannot clash with helpers of other test authors.

/// A value behind a lock.
final class IndependentConcurrencyBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value { storage.withLock { $0 } }

    func set(_ value: Value) { storage.withLock { $0 = value } }

    @discardableResult
    func update<R: Sendable>(_ body: @Sendable (inout Value) -> R) -> R {
        storage.withLock { value in body(&value) }
    }
}

/// Counts events and remembers the high-water mark of things happening at once.
final class IndependentConcurrencyMeter: Sendable {
    private let state = Mutex<(current: Int, peak: Int, total: Int)>((0, 0, 0))

    @discardableResult func enter() -> Int {
        state.withLock { state in
            state.current += 1
            state.total += 1
            state.peak = max(state.peak, state.current)
            return state.current
        }
    }

    func leave() { state.withLock { $0.current -= 1 } }
    var current: Int { state.withLock { $0.current } }
    var peak: Int { state.withLock { $0.peak } }
    var total: Int { state.withLock { $0.total } }
}

/// Holds handlers until a test releases them.
final class IndependentConcurrencyGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    /// Suspends until `open()`. Not cancellable on purpose: it models a handler that ignores cancellation.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    var waiting: Int { state.withLock { $0.waiters.count } }
}

/// Runs `operation` without waiting for it longer than `limit`. Returns `nil` on timeout; the
/// operation is then left behind, so a hang in the code under test cannot stall the suite.
func independentConcurrencyValue<T: Sendable>(
    within limit: Duration, _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let (stream, continuation) = AsyncStream<T?>.makeStream()
    let work = Task {
        let value = await operation()
        continuation.yield(value)
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        continuation.yield(nil)
    }
    defer {
        timer.cancel()
        _ = work
    }
    for await value in stream { return value }
    return nil
}

func independentConcurrencyFinishes(
    within limit: Duration, _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await independentConcurrencyValue(within: limit) {
        await operation()
        return true
    } ?? false
}

/// Polls `condition` until it holds or `timeout` passes.
func independentConcurrencyEventually(
    timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// A `FrameSink` that remembers everything the engine did with it.
///
/// It models a writer that takes a frame out of the queue at the moment the test reads it:
/// frames not yet read can still be withdrawn by `discard(key:)`, frames already read cannot.
final class IndependentConcurrencySink: FrameSink {
    struct Record: Sendable {
        let index: Int
        let frame: [UInt8]
        let key: RequestID?
        let urgent: Bool
        let isProgress: Bool
        var withdrawn = false

        var json: JSONValue? { try? JSON.parse(frame) }
        var text: String { String(decoding: frame, as: UTF8.self) }
    }

    private struct State {
        var history: [Record] = []
        var cursor = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter = 0
        var discards: [RequestID] = []
        var capacityBlocked = false
        var capacityWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelledCapacityWaits: Set<Int> = []
        var nextCapacityWaiter = 0
        var capacityWaits = 0
    }

    private let state = Mutex(State())

    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.history.append(
                Record(index: state.history.count, frame: frame, key: key, urgent: urgent, isProgress: replacesProgress))
            let waiters = Array(state.waiters.values)
            state.waiters = [:]
            return waiters
        }
        for waiter in waiters { waiter.resume() }
        return true
    }

    /// Like `OutboundQueue`: suspends while the sink is over budget and returns at once when
    /// the calling task is cancelled.
    func waitForCapacity() async {
        let token: Int? = state.withLock { state in
            state.capacityWaits += 1
            guard state.capacityBlocked else { return nil }
            state.nextCapacityWaiter += 1
            return state.nextCapacityWaiter
        }
        guard let token else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    if !state.capacityBlocked || state.cancelledCapacityWaits.remove(token) != nil { return true }
                    state.capacityWaiters[token] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
                if let waiter = state.capacityWaiters.removeValue(forKey: token) { return waiter }
                state.cancelledCapacityWaits.insert(token)
                return nil
            }
            waiter?.resume()
        }
    }

    /// Over budget exactly while the test says the peer is not reading.
    var isOverBudget: Bool { state.withLock { $0.capacityBlocked } }

    func discard(key: RequestID) {
        state.withLock { state in
            state.discards.append(key)
            for index in state.cursor..<state.history.count where state.history[index].key == key {
                state.history[index].withdrawn = true
            }
        }
    }

    // MARK: Test side

    /// While blocked, `waitForCapacity` suspends: the peer is not reading.
    func blockCapacity() { state.withLock { $0.capacityBlocked = true } }

    func unblockCapacity() {
        let waiters = state.withLock { state in
            state.capacityBlocked = false
            defer { state.capacityWaiters = [:] }
            return Array(state.capacityWaiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    var capacityWaiterCount: Int { state.withLock { $0.capacityWaiters.count } }

    /// Every frame ever queued, including withdrawn ones.
    var history: [Record] { state.withLock { $0.history } }
    /// How many frames were queued so far: a position in `history`.
    var mark: Int { state.withLock { $0.history.count } }
    /// Frames that reach the peer: everything not withdrawn.
    var sent: [Record] { state.withLock { $0.history.filter { !$0.withdrawn } } }
    var discards: [RequestID] { state.withLock { $0.discards } }

    /// The next frame that reaches the peer, or `nil` on timeout.
    func next(timeout: Duration) async -> Record? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let (record, token): (Record?, Int) = state.withLock { state in
                while state.cursor < state.history.count {
                    let record = state.history[state.cursor]
                    state.cursor += 1
                    if !record.withdrawn { return (record, 0) }
                }
                state.nextWaiter += 1
                return (nil, state.nextWaiter)
            }
            if let record { return record }
            guard ContinuousClock.now < deadline else { return nil }
            let timer = Task { [self] in
                try? await Task.sleep(until: deadline)
                state.withLock { $0.waiters.removeValue(forKey: token) }?.resume()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if state.cursor < state.history.count { return true }
                    state.waiters[token] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
            timer.cancel()
        }
    }
}

struct IndependentConcurrencyError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// A client on top of `IndependentConcurrencySink`: like `TestClient`, but with access to raw
/// frames, their keys and their order.
final class IndependentConcurrencyWire: Sendable {
    let sink = IndependentConcurrencySink()
    let connection: Connection
    private let state: Mutex<(nextID: Int, meta: JSONObject?, others: [JSONValue])>

    init(_ server: Server, modern: Bool = true, capabilities: JSONObject = JSONObject()) {
        connection = server.connect(to: sink)
        var meta: JSONObject?
        if modern {
            meta = [
                MetaKey.protocolVersion: .string(ProtocolVersion.latest.rawValue),
                MetaKey.clientInfo: ["name": "independent-concurrency", "version": "1"],
                MetaKey.clientCapabilities: .object(capabilities),
            ]
        }
        state = Mutex((1000, meta, []))
    }

    /// Messages read while waiting for a particular response.
    var others: [JSONValue] { state.withLock { $0.others } }

    func send(_ frame: String) { connection.receive(Array(frame.utf8)) }
    func send(_ message: JSONValue) { connection.receive(message.encoded()) }

    func notify(_ method: String, _ params: JSONObject = JSONObject()) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": .object(params)])
    }

    func cancel(_ id: RequestID) { notify("notifications/cancelled", ["requestId": id.json]) }

    @discardableResult
    func post(_ method: String, _ params: JSONObject = JSONObject(), id: RequestID? = nil, meta: JSONObject? = nil) -> RequestID {
        let (requestID, defaultMeta): (RequestID, JSONObject?) = state.withLock { state in
            defer { state.nextID += 1 }
            return (id ?? RequestID(state.nextID), state.meta)
        }
        var params = params
        var merged = defaultMeta ?? JSONObject()
        if let meta { merged = merged.merging(meta) }
        if let existing = params["_meta"]?.objectValue { merged = merged.merging(existing) }
        if !merged.isEmpty { params["_meta"] = .object(merged) }
        send(["jsonrpc": "2.0", "id": requestID.json, "method": .string(method), "params": .object(params)])
        return requestID
    }

    @discardableResult
    func call(_ tool: String, _ arguments: JSONObject = JSONObject(), id: RequestID? = nil, meta: JSONObject? = nil) -> RequestID {
        post("tools/call", ["name": .string(tool), "arguments": .object(arguments)], id: id, meta: meta)
    }

    func nextRecord(timeout: Duration = .seconds(10)) async throws -> IndependentConcurrencySink.Record {
        guard let record = await sink.next(timeout: timeout) else {
            throw IndependentConcurrencyError("no message from the server within \(timeout)")
        }
        guard !record.frame.contains(0x0A), !record.frame.contains(0x0D) else {
            throw IndependentConcurrencyError("frame with an embedded line break: \(record.text)")
        }
        guard record.json != nil else {
            throw IndependentConcurrencyError("frame is not valid JSON: \(record.text)")
        }
        return record
    }

    func next(timeout: Duration = .seconds(10)) async throws -> JSONValue {
        try await nextRecord(timeout: timeout).json!
    }

    func response(to id: RequestID, timeout: Duration = .seconds(10)) async throws -> JSONValue {
        while true {
            let message = try await next(timeout: timeout)
            if message["method"] == nil, message["id"] == id.json { return message }
            state.withLock { $0.others.append(message) }
        }
    }

    func request(
        _ method: String, _ params: JSONObject = JSONObject(), id: RequestID? = nil, meta: JSONObject? = nil
    ) async throws -> JSONValue {
        let id = post(method, params, id: id, meta: meta)
        return try await response(to: id)
    }

    /// Whether nothing reaches the peer for `duration`.
    func isSilent(for duration: Duration = .milliseconds(100)) async -> Bool {
        guard let record = await sink.next(timeout: duration) else { return true }
        if let message = record.json { state.withLock { $0.others.append(message) } }
        return false
    }

    @discardableResult
    func initialize(
        version: ProtocolVersion = .latestLegacy, capabilities: JSONObject = JSONObject()
    ) async throws -> JSONValue {
        state.withLock { $0.meta = nil }
        let response = try await request(
            "initialize",
            [
                "protocolVersion": .string(version.rawValue),
                "capabilities": .object(capabilities),
                "clientInfo": ["name": "independent-concurrency", "version": "1"],
            ])
        notify("notifications/initialized")
        return response
    }

    /// Frames that reach the peer and mention request `id`: its response, or a notification
    /// carrying `token` as its progress token.
    func framesSent(for id: RequestID, progressToken token: JSONValue? = nil, from start: Int = 0) -> [IndependentConcurrencySink.Record] {
        sink.sent.filter { record in
            guard record.index >= start, let message = record.json else { return false }
            if record.key == id { return true }
            if message["method"] == nil, message["id"] == id.json { return true }
            if let token, message["params"]?["progressToken"] == token { return true }
            return false
        }
    }
}

/// A server with no registrations and silent diagnostics.
func independentConcurrencyServer(_ configure: (inout ServerConfiguration) -> Void = { _ in }) -> Server {
    Server(name: "independent-concurrency", version: "0.0.1") { configuration in
        configuration.diagnostics = { _ in }
        configure(&configuration)
    }
}

extension JSONValue {
    var independentConcurrencyErrorCode: Int? { self["error"]?["code"]?.intValue }
    var independentConcurrencyText: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
    var independentConcurrencyIsResponse: Bool { self["method"] == nil && self["id"] != nil }
}
