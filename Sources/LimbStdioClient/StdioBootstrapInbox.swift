#if os(macOS)
import LimbClient
import LimbCore
import Synchronization

struct StdioBootstrapReply: Sendable {
    let id: RequestID
    let response: Result<JSONValue, MCPError>?
    let receivedAt: ContinuousClock.Instant

    var result: Result<JSONValue, MCPError> {
        get throws(StdioNegotiationError) {
            guard let response else { throw .malformedResponse }
            return response
        }
    }
}

enum StdioBootstrapEvent: Sendable {
    case reply(StdioBootstrapReply)
    case ping(StdioBootstrapPing)
}

enum StdioBootstrapPing: Sendable {
    case request(RequestID)
    case batch([RequestID])

    var count: Int {
        switch self {
        case .request: 1
        case .batch(let ids): ids.count
        }
    }
}

/// The process worker observes complete frames before making any guarded write.
final class StdioBootstrapInbox: Sendable {
    private struct Wait {
        let ticket: Int
        let ids: [RequestID]
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<StdioBootstrapEvent, any Error>
    }

    private struct State {
        var framer: LineFramer
        var lastID = 0
        var lastWaitTicket = 0
        var expected: Set<RequestID> = []
        var replies: [StdioBootstrapReply] = []
        var legacyPingLimit = 0
        var legacyPings: [StdioBootstrapPing] = []
        var legacyPingCount = 0
        var sawLegacyBatch = false
        var legacyBatchesAllowed: Bool?
        var failure: StdioNegotiationError?
        var wait: Wait?

        mutating func take(matching ids: [RequestID], before deadline: ContinuousClock.Instant) -> StdioBootstrapReply? {
            guard let index = replies.firstIndex(where: { ids.contains($0.id) && $0.receivedAt < deadline }) else {
                return nil
            }
            return replies.remove(at: index)
        }

        mutating func finish(_ error: any Error) {
            let pending = wait
            wait = nil
            pending?.continuation.resume(throwing: error)
        }

        mutating func resolve() {
            guard let pending = wait else { return }
            if let failure {
                finish(failure)
            } else if let reply = take(matching: pending.ids, before: pending.deadline) {
                wait = nil
                pending.continuation.resume(returning: .reply(reply))
            } else if ContinuousClock.now >= pending.deadline {
                finish(StdioNegotiationError.timedOut)
            } else if let ping = takePing() {
                wait = nil
                pending.continuation.resume(returning: .ping(ping))
            }
        }

        mutating func receive(_ bytes: ArraySlice<UInt8>, at observed: ContinuousClock.Instant) {
            var offset = bytes.startIndex
            while offset < bytes.endIndex, failure == nil {
                offset += framer.append(bytes[offset...])
                while let frame = framer.next() {
                    guard case .frame(let range) = frame else {
                        failure = .frameTooLarge
                        return
                    }
                    do {
                        let value = try JSON.parseStrict(framer.buffer.span.extracting(range))
                        try receive(value, at: observed)
                    } catch ClientMessageError.malformedResponse(let id) {
                        record(id, nil, at: observed)
                    } catch {
                        failure = .malformedResponse
                        return
                    }
                }
                if framer.isDiscardingOversizedFrame {
                    failure = .frameTooLarge
                    return
                }
            }
        }

        mutating func receive(_ value: JSONValue, at observed: ContinuousClock.Instant) throws {
            if case .array(let batch) = value {
                try receiveLegacyBatch(batch)
                return
            }
            switch try ClientMessage.classify(value) {
            case .response(let id, let response):
                record(id, response, at: observed)
            case .request(let id, "ping", _) where legacyPingLimit > 0:
                try addPing(.request(id))
            default:
                break
            }
        }

        mutating func receiveLegacyBatch(_ batch: [JSONValue]) throws(StdioNegotiationError) {
            guard legacyPingLimit > 0, legacyBatchesAllowed != false, !batch.isEmpty else {
                throw .malformedResponse
            }
            // March 2025 permits server pings in a separate batch before initialized.
            // The actual initialize response still has its own frame.
            var ids: [RequestID] = []
            for value in batch {
                switch try? ClientMessage.classify(value) {
                case .request(let id, "ping", _):
                    guard ids.count < legacyPingLimit - legacyPingCount else { throw .malformedResponse }
                    ids.append(id)
                case .notification:
                    break
                default:
                    throw .malformedResponse
                }
            }
            sawLegacyBatch = true
            if !ids.isEmpty { try addPing(.batch(ids)) }
        }

        mutating func takePing() -> StdioBootstrapPing? {
            guard !legacyPings.isEmpty else { return nil }
            let ping = legacyPings.removeFirst()
            legacyPingCount -= ping.count
            return ping
        }

        mutating func addPing(_ ping: StdioBootstrapPing) throws(StdioNegotiationError) {
            guard ping.count <= legacyPingLimit - legacyPingCount else { throw .malformedResponse }
            legacyPingCount += ping.count
            legacyPings.append(ping)
        }

        mutating func record(_ id: RequestID, _ response: Result<JSONValue, MCPError>?, at observed: ContinuousClock.Instant) {
            guard expected.remove(id) != nil else { return }
            replies.append(StdioBootstrapReply(id: id, response: response, receivedAt: observed))
        }
    }

    private let state: Mutex<State>

    init(maxFrameBytes: Int, lastID: Int = 0) {
        state = Mutex(State(framer: LineFramer(maxFrameBytes: maxFrameBytes), lastID: lastID))
    }

    var lastID: Int { state.withLock { $0.lastID } }
    var failure: StdioNegotiationError? { state.withLock { $0.failure } }

    func issueID() throws(ClientError) -> RequestID {
        try state.withLock { state throws(ClientError) in
            guard state.lastID < Int.max else { throw .requestIDsExhausted }
            state.lastID += 1
            let id = RequestID(state.lastID)
            state.expected.insert(id)
            return id
        }
    }

    func receive(_ bytes: ArraySlice<UInt8>) {
        let now = ContinuousClock.now
        state.withLock {
            $0.receive(bytes, at: now)
            $0.resolve()
        }
    }

    func end() {
        state.withLock {
            if $0.failure == nil { $0.failure = $0.framer.hasPartialFrame ? .malformedResponse : .connectionLost }
            $0.resolve()
        }
    }

    func allowLegacyPings(limit: Int) { state.withLock { $0.legacyPingLimit = limit } }

    func validateBatchPolicy(acceptsBatch: Bool) throws(StdioNegotiationError) {
        try state.withLock { state throws(StdioNegotiationError) in
            if state.sawLegacyBatch, !acceptsBatch { throw .malformedResponse }
            state.legacyBatchesAllowed = acceptsBatch
        }
    }

    func handoff(until deadline: ContinuousClock.Instant) throws(StdioNegotiationError) -> LineFramer {
        try state.withLock { state throws(StdioNegotiationError) in
            if let failure = state.failure { throw failure }
            guard ContinuousClock.now < deadline else { throw .timedOut }
            return state.framer
        }
    }

    func permitWrite(watching id: RequestID?, ready: Bool = false) -> Bool {
        state.withLock { state in
            guard state.failure == nil, !ready || state.legacyPings.isEmpty else { return false }
            guard let id, let reply = state.replies.first(where: { $0.id == id }) else { return true }
            if case .legacy? = try? StdioDiscovery(reply.result, offered: .r2026_07_28) { return true }
            return false
        }
    }

    func takePing() -> StdioBootstrapPing? { state.withLock { $0.takePing() } }

    func take(_ id: RequestID, until deadline: ContinuousClock.Instant) -> StdioBootstrapReply? {
        state.withLock { $0.take(matching: [id], before: deadline) }
    }

    func next(matching ids: [RequestID], until deadline: ContinuousClock.Instant) async throws -> StdioBootstrapEvent {
        let ticket = state.withLock {
            $0.lastWaitTicket += 1
            return $0.lastWaitTicket
        }
        let timer = Task.detached {
            do {
                try await ContinuousClock().sleep(until: deadline)
                self.state.withLock {
                    if $0.wait?.ticket == ticket { $0.resolve() }
                }
            } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock {
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    $0.wait = Wait(ticket: ticket, ids: ids, deadline: deadline, continuation: continuation)
                    $0.resolve()
                }
            }
        } onCancel: {
            self.state.withLock {
                if $0.wait?.ticket == ticket { $0.finish(CancellationError()) }
            }
        }
    }
}
#endif
