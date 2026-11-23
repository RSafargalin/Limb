public import Limb
import Synchronization

/// A failure of the test harness itself: a timeout, or output that is not valid protocol.
public struct TestClientError: Error, Sendable, CustomStringConvertible {
    public var reason: String
    public var description: String { reason }
}

/// An in-memory client for exercising a `Server` in tests: no process and no pipes. It waits
/// only where a test asks it to: for the next message, up to a timeout, and in `isSilent`.
///
/// Every frame the server emits is checked when the test receives it, by `next`, `response`,
/// `request` and `isSilent` alike. It must be one line of JSON, and a JSON-RPC 2.0 message a
/// server may send: `"jsonrpc": "2.0"`; a request (a string `method` and an `id`) or a
/// notification (a `method`, no `id`), neither with `result` or `error`; or a response with an
/// `id` and exactly one of `result` and `error`, the error an object with an integer `code` and
/// a string `message`, and a null `id` only on an error; or a non-empty batch of responses. The
/// JSON is checked as strictly as the server parses its input: by Limb's own parser, or, with
/// the `FoundationJSON` trait, by Foundation's, which also accepts some input that is not
/// strict JSON (trailing commas, duplicate keys).
///
/// ```swift
/// let client = TestClient(server)
/// let tools = try await client.request("tools/list")
/// ```
///
/// The client stands in for the stdio transport and a peer that reads everything at once,
/// which is not quite the transport's `OutboundQueue`:
///
/// - Frames wait in memory until the test reads them, without a byte budget: a handler never
///   waits for capacity, and nothing is ever over budget, as with a peer that keeps up.
/// - Nothing is coalesced: every progress notification is kept, as when the transport's writer
///   takes each one before the next arrives.
/// - There is no reserve for urgent frames, since nothing ever runs out of room.
/// - When a request is cancelled, its frames that the test has not read yet are withdrawn.
///   The transport can withdraw only frames it has not written, so a real peer may still get
///   some of them.
/// - After `close`, frames are refused as the transport refuses them once the connection has
///   closed; the server is told so. Unlike the transport, the client remembers them: the test
///   reading next gets an error, and `isSilent` answers `false`.
public final class TestClient: Sendable {
    public let connection: Connection
    private let sink = MemorySink()
    private let state: Mutex<State>

    private struct State {
        var nextID = 1
        var meta: JSONObject?
    }

    /// - Parameter modern: speak `2026-07-28` (per-request metadata) by default. Pass `false`
    ///   to send bare requests, as a legacy client does after `initialize`.
    public init(_ server: Server, modern: Bool = true, capabilities: JSONObject = JSONObject()) {
        connection = server.connect(to: sink)
        var meta: JSONObject?
        if modern {
            meta = [
                MetaKey.protocolVersion: .string(ProtocolVersion.latest.rawValue),
                MetaKey.clientInfo: ["name": "limb-test-client", "version": "1.0.0"],
                MetaKey.clientCapabilities: .object(capabilities),
            ]
        }
        state = Mutex(State(meta: meta))
    }

    /// Messages received that were not the response a `request` was waiting for: notifications
    /// and requests from the server, in arrival order.
    public var received: [JSONValue] { sink.received }

    public func clearReceived() { sink.clearReceived() }

    // MARK: Sending

    /// Sends a raw frame exactly as given.
    public func send(_ frame: String) {
        connection.receive(Array(frame.utf8))
    }

    public func send(_ message: JSONValue) {
        connection.receive(message.encoded())
    }

    public func notify(_ method: String, _ params: JSONObject = JSONObject()) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": .object(params)])
    }

    /// Sends a request without waiting for the response. Returns its id.
    ///
    /// The client's default metadata, then `meta`, then an object `_meta` in `params` are merged
    /// into `params._meta`. A `_meta` in `params` that is not an object is sent as given.
    @discardableResult
    public func post(_ method: String, _ params: JSONObject = JSONObject(), id: RequestID? = nil, meta: JSONObject? = nil) -> RequestID {
        let (requestID, defaultMeta): (RequestID, JSONObject?) = state.withLock { state in
            defer { state.nextID += 1 }
            return (id ?? RequestID(state.nextID), state.meta)
        }
        var params = params
        if params["_meta"] == nil || params["_meta"]?.objectValue != nil {
            var merged = defaultMeta ?? JSONObject()
            if let meta { merged = merged.merging(meta) }
            if let existing = params["_meta"]?.objectValue { merged = merged.merging(existing) }
            if !merged.isEmpty { params["_meta"] = .object(merged) }
        }
        send(["jsonrpc": "2.0", "id": requestID.json, "method": .string(method), "params": .object(params)])
        return requestID
    }

    // MARK: Receiving

    /// The next message from the server.
    public func next(timeout: Duration = .seconds(5)) async throws -> JSONValue {
        try await receive(.next, timeout: timeout)
    }

    private func receive(_ read: MemorySink.Read, timeout: Duration) async throws -> JSONValue {
        guard let message = await sink.next(read, until: .now + timeout) else {
            throw TestClientError(reason: "no message from the server within \(timeout)")
        }
        return try message.get()
    }

    /// Waits up to `timeout` for the response to `id`. Notifications and server requests that
    /// arrive first are kept in `received`. Other replies remain available by ID or through `next`.
    public func response(to id: RequestID, timeout: Duration = .seconds(5)) async throws -> JSONValue {
        try await receive(.response(id), timeout: timeout)
    }

    /// Sends a request and returns the full response message (with `result` or `error`).
    public func request(
        _ method: String, _ params: JSONObject = JSONObject(), id: RequestID? = nil, meta: JSONObject? = nil
    ) async throws -> JSONValue {
        let id = post(method, params, id: id, meta: meta)
        return try await response(to: id)
    }

    /// Whether the server stays silent for `duration`. For asserting that nothing is sent.
    ///
    /// A message that arrives is kept in `received`. A frame that fails the checks is written to
    /// stderr, and the next `next`, `response` or `request` throws the same error.
    public func isSilent(for duration: Duration = .milliseconds(150)) async -> Bool {
        guard let frame = await sink.next(.observe, until: .now + duration) else { return true }
        if case .failure(let error) = frame {
            ServerConfiguration.standardErrorDiagnostics("TestClient: \(error.reason)")
        }
        return false
    }

    // MARK: Checking frames

    fileprivate static func check(_ bytes: [UInt8]) throws(TestClientError) -> JSONValue {
        guard !bytes.contains(0x0A), !bytes.contains(0x0D) else {
            throw TestClientError(reason: "the server emitted a frame with an embedded line break")
        }
        let message: JSONValue
        do {
            message = try JSON.parse(bytes)
        } catch {
            throw TestClientError(reason: "the server emitted invalid JSON (\(error)): \(String(decoding: bytes, as: UTF8.self))")
        }
        if let problem = envelopeProblem(message) {
            throw TestClientError(reason: "the server emitted an invalid JSON-RPC message (\(problem)): \(String(decoding: bytes, as: UTF8.self))")
        }
        return message
    }

    /// What makes `message` something other than a JSON-RPC 2.0 message a server may send.
    private static func envelopeProblem(_ message: JSONValue) -> String? {
        if let batch = message.arrayValue {
            if batch.isEmpty { return "an empty batch" }
            for (index, element) in batch.enumerated() {
                guard let object = element.objectValue else { return "batch item \(index) is not an object" }
                if object.contains("method") { return "batch item \(index) is not a response" }
                if let problem = envelopeProblem(object) { return "batch item \(index): \(problem)" }
            }
            return nil
        }
        guard let object = message.objectValue else { return "not an object" }
        return envelopeProblem(object)
    }

    private static func envelopeProblem(_ object: JSONObject) -> String? {
        guard object["jsonrpc"] == "2.0" else { return #"no "jsonrpc": "2.0""# }
        let hasResult = object.contains("result")
        let hasError = object.contains("error")
        if let method = object["method"] {
            guard method.stringValue != nil else { return "a method that is not a string" }
            if hasResult || hasError { return "a request or notification with a result or error" }
            if let id = object["id"], !isRequestID(id) { return "a request id that is neither a string nor an integer" }
            if let params = object["params"], params.objectValue == nil, params.arrayValue == nil {
                return "params that are neither an object nor an array"
            }
            return nil
        }
        guard let id = object["id"] else { return "neither a method nor an id" }
        switch (hasResult, hasError) {
        case (false, false): return "a response with neither result nor error"
        case (true, true): return "a response with both result and error"
        case (true, false):
            return isRequestID(id) ? nil : "a result whose id is neither a string nor an integer"
        case (false, true):
            guard isRequestID(id) || id.isNull else { return "an error whose id is not a string, an integer or null" }
            guard let error = object["error"]?.objectValue else { return "an error that is not an object" }
            guard error["code"]?.numberValue?.isInteger == true else { return "an error code that is not an integer" }
            guard error["message"]?.stringValue != nil else { return "an error message that is not a string" }
            return nil
        }
    }

    private static func isRequestID(_ id: JSONValue) -> Bool {
        id.stringValue != nil || id.numberValue?.isInteger == true
    }

    // MARK: Legacy handshake

    /// Performs the `initialize` handshake of a legacy revision and switches this client to
    /// sending bare requests. Returns the `initialize` response.
    @discardableResult
    public func initialize(
        version: ProtocolVersion = .latestLegacy, capabilities: JSONObject = JSONObject()
    ) async throws -> JSONValue {
        state.withLock { $0.meta = nil }
        let response = try await request(
            "initialize",
            [
                "protocolVersion": .string(version.rawValue),
                "capabilities": .object(capabilities),
                "clientInfo": ["name": "limb-test-client", "version": "1.0.0"],
            ])
        notify("notifications/initialized")
        return response
    }

    /// Ends the connection as a closed input stream would: once requests in flight are done
    /// (or `graceSeconds` is up), further frames are refused, as the stdio transport does.
    public func close(graceSeconds: Double = 1) async {
        await connection.close(graceSeconds: graceSeconds)
        sink.close()
    }
}

/// A `FrameSink` that keeps frames in memory until the test reads them. See `TestClient` for
/// how it differs from the transport's `OutboundQueue`.
final class MemorySink: FrameSink {
    typealias Message = Result<JSONValue, TestClientError>

    enum Read {
        case next, response(RequestID), observe
    }

    private struct Entry {
        enum Content {
            case frame([UInt8], afterClose: Bool)
            case decoded(Message)
        }

        var content: Content
        var key: RequestID?

        mutating func decode() -> Message {
            switch content {
            case .decoded(let message): return message
            case .frame(let frame, let afterClose):
                let message = Message { () throws(TestClientError) in
                    if afterClose {
                        let text = String(decoding: frame, as: UTF8.self)
                        throw TestClientError(reason: "the server sent a frame after the connection was closed: \(text)")
                    }
                    return try TestClient.check(frame)
                }
                content = .decoded(message)
                return message
            }
        }
    }

    private struct State {
        var entries: [Entry] = []
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter = 0
        var generation: UInt64 = 0
        var closed = false
        var log: [JSONValue] = []
        /// What was wrong with a frame that `isSilent` received; the next read reports it.
        var problem: TestClientError?

        mutating func take(_ read: Read) -> Message? {
            switch read {
            case .observe:
                let message = takeFirst()
                switch message {
                case .success(let value): log.append(value)
                case .failure(let error): problem = error
                case nil: break
                }
                return message
            case .next, .response:
                if let problem {
                    self.problem = nil
                    return .failure(problem)
                }
                if case .response(let id) = read { return takeResponse(to: id) }
                return takeFirst()
            }
        }

        private mutating func takeFirst() -> Message? {
            guard !entries.isEmpty else { return nil }
            var entry = entries.removeFirst()
            return entry.decode()
        }

        /// Observe notifications and requests in queue order. Compact the scanned prefix once
        /// so any unrelated replies remain queued in their original order.
        private mutating func takeResponse(to id: RequestID) -> Message? {
            var kept = 0
            var examined = 0
            var selected: Message?
            while examined < entries.count, selected == nil {
                let message = entries[examined].decode()
                switch message {
                case .failure:
                    selected = message
                case .success(let value) where value["method"] != nil:
                    log.append(value)
                case .success(let value) where value["id"].flatMap(RequestID.init(json:)) == id:
                    selected = message
                case .success:
                    if kept != examined { entries[kept] = entries[examined] }
                    kept += 1
                }
                examined += 1
            }
            if kept != examined { entries.removeSubrange(kept..<examined) }
            return selected
        }
    }

    private let state = Mutex(State())

    var received: [JSONValue] { state.withLock { $0.log } }

    func clearReceived() { state.withLock { $0.log = [] } }

    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        let (accepted, waiters): (Bool, [CheckedContinuation<Void, Never>]) = state.withLock { state in
            state.entries.append(Entry(content: .frame(frame, afterClose: state.closed), key: key))
            state.generation &+= 1
            let waiters = Array(state.waiters.values)
            state.waiters = [:]
            return (!state.closed, waiters)
        }
        for waiter in waiters { waiter.resume() }
        return accepted
    }

    func waitForCapacity() async {}

    func discard(key: RequestID) {
        state.withLock { $0.entries.removeAll { $0.key == key } }
    }

    func close() {
        state.withLock { $0.closed = true }
    }

    func next(_ read: Read, until deadline: ContinuousClock.Instant) async -> Message? {
        repeat {
            let (message, token, generation): (Message?, Int, UInt64) = state.withLock { state in
                if Task.isCancelled { return (nil, 0, 0) }
                if let message = state.take(read) { return (message, 0, 0) }
                state.nextWaiter += 1
                return (nil, state.nextWaiter, state.generation)
            }
            if let message { return message }
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            await waitForEnqueue(since: generation, token: token, until: deadline)
        } while !Task.isCancelled && ContinuousClock.now < deadline
        return nil
    }

    private func waitForEnqueue(since generation: UInt64, token: Int, until deadline: ContinuousClock.Instant) async {
        await withTaskCancellationHandler {
            var timer: Task<Void, Never>?
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if Task.isCancelled || generation != state.generation { return true }
                    state.waiters[token] = continuation
                    return false
                }
                if ready {
                    continuation.resume()
                    return
                }
                // Started only once the continuation is registered: a timer that fired before
                // would find nothing to resume, and the wait would never end.
                timer = Task { [self] in
                    try? await Task.sleep(until: deadline)
                    state.withLock { $0.waiters.removeValue(forKey: token) }?.resume()
                }
            }
            timer?.cancel()
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: token) }?.resume()
        }
    }
}
