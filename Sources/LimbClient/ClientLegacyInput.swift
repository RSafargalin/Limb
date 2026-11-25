package import LimbCore
import Synchronization

/// Input requests have a session deadline and a separate quota from outgoing operations.
package final class ClientLegacyInput: Sendable {
    private let profile: RevisionProfile
    private let serverIdentity: String?
    private let serverInfo: Implementation?
    private let handlers: ClientInputHandlers
    private let capabilities: ClientCapabilities
    private let timeout: Duration
    private let work: ClientWorkPool
    private let urls: LegacyElicitationIDs

    package init(
        profile: RevisionProfile, serverIdentity: String?, serverInfo: Implementation?, handlers: ClientInputHandlers,
        capabilities: JSONObject, timeout: Duration, maxPending: Int, maxIDBytes: Int,
        executionQuotas: ClientExecutionQuotas? = nil
    ) {
        self.profile = profile
        self.serverIdentity = serverIdentity
        self.serverInfo = serverInfo
        self.handlers = handlers
        self.capabilities = ClientCapabilities(raw: capabilities)
        self.timeout = timeout
        work = ClientWorkPool(limit: maxPending, quota: executionQuotas?.incoming)
        urls = LegacyElicitationIDs(limit: max(32, maxPending), byteLimit: maxIDBytes)
    }

    package var deadline: ContinuousClock.Instant { .now + timeout }
    package var isOpen: Bool { urls.isOpen }
    var acceptsCompletions: Bool { profile.elicitationCompletion && capabilities.supportsURLElicitation }

    package func supports(_ method: String) -> Bool {
        switch method {
        case "roots/list": capabilities.supportsRoots
        case "sampling/createMessage": capabilities.supportsSampling
        case "elicitation/create": profile.elicitationRequests && (
            capabilities.supportsElicitation || acceptsCompletions)
        default: false
        }
    }

    /// Prepare wire values and run the host callback outside the reader and client actors.
    package func answer(
        id: RequestID, method: String, params: JSONObject, url: ElicitRequest?, until deadline: ContinuousClock.Instant
    ) async -> Result<JSONValue, MCPError>? {
        let context = ClientInputContext(
            protocolVersion: profile.version, serverIdentity: serverIdentity, serverInfo: serverInfo,
            method: method, legacyRequestID: id,
            requestKey: id.description, round: 1, deadline: deadline)
        do {
            guard ContinuousClock.now < deadline else { throw ClientError.timedOut(.unknown) }
            let permit = try work.reserve()
            let answer = try await permit.runHandler(until: deadline) { [handlers, capabilities, profile] in
                let job: ClientInputRound.Job
                if let url, let handler = handlers.elicitURL {
                    job = ClientInputRound.urlJob(url, key: context.requestKey, handler: handler)
                } else {
                    job = try ClientInputRound.job(
                        method: method, params: params, key: context.requestKey, handlers: handlers,
                        capabilities: capabilities, round: context.round, profile: profile)
                }
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ClientError.timedOut(.unknown) }
                do {
                    return try await job.respond(context)
                } catch let error as MCPError {
                    throw error
                } catch {
                    // Application errors can contain private details.
                    throw MCPError.internalError()
                }
            }
            return .success(answer)
        } catch let error as JSONDecodingError {
            return .failure(.invalidParams(error))
        } catch let error as ClientInputError {
            switch error {
            case .unavailableHandler where method == "elicitation/create" && profile.elicitationCompletion:
                return .failure(.invalidParams("elicitation mode was not negotiated"))
            case .unsupportedMethod, .unavailableHandler: return .failure(.methodNotFound(method))
            default: return .failure(.internalError())
            }
        } catch let error as MCPError {
            return .failure(error)
        } catch let error as ClientError {
            switch error {
            case .cancelled, .closed, .closedDuringRequest, .connectionLost: return nil
            case .timedOut:
                let duration = timeout.components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                return .failure(.requestTimedOut(method: method, seconds: seconds))
            case .workOverloaded: return .failure(.overloaded("client input quota is occupied"))
            default: return .failure(.internalError())
            }
        } catch is CancellationError {
            return nil
        } catch {
            return .failure(.internalError())
        }
    }

    /// Register the wire ID before the transport can dispatch an adjacent completion.
    package func prepareURL(
        method: String, params: JSONObject, request: RequestID
    ) throws(MCPError) -> ElicitRequest? {
        guard acceptsCompletions, method == "elicitation/create", params["mode"] == "url" else { return nil }
        let url: ElicitRequest
        do { url = try ClientInputRound.decodeURL(params, profile: profile) }
        catch { throw .invalidParams(error) }
        try urls.insert(url.elicitationID, request: request)
        return url
    }

    package func finishURL(_ id: String, request: RequestID, accepted: Bool) {
        urls.finish(id, request: request, accepted: accepted)
    }

    func recordRequiredURLs(_ error: MCPError) -> Bool {
        guard acceptsCompletions, error.isValidURLElicitationRequired,
              let entries = error.data?["elicitations"]?.arrayValue,
              entries.allSatisfy({ $0["url"]?.stringValue.map(ClientInputRound.isAbsoluteURL) == true }) else { return true }
        return urls.require(entries.compactMap { $0["elicitationId"]?.stringValue })
    }

    func completeURL(_ id: String) {
        if acceptsCompletions { urls.complete(id) }
    }

    func completions(bufferSize: Int) -> AsyncStream<String>? {
        acceptsCompletions ? urls.completions(bufferSize: bufferSize) : nil
    }

    package func close() {
        urls.close()
        work.close()
    }
}

/// Accepted and completed IDs remain associated with the current session. Admission applies
/// a count and byte budget to the session and keeps the state of previously admitted IDs.
private final class LegacyElicitationIDs: Sendable {
    private struct Entry {
        var request: RequestID?
        var eligible = false
        var notified = false
        var published = false
    }

    private struct State {
        var closed = false
        var entries: [ExactString: Entry] = [:]
        var bytes = 0
        var events: [ExactString] = []
        var nextSubscriber: UInt64 = 0
        var subscribers: [UInt64: AsyncStream<String>.Continuation] = [:]

        mutating func publishIfReady(_ id: ExactString) {
            guard let entry = entries[id], entry.eligible, entry.notified, !entry.published else { return }
            entries[id]?.published = true
            events.append(id)
            for subscriber in subscribers.values { subscriber.yield(id.text) }
        }
    }

    private let state = Mutex(State())
    private let limit: Int
    private let byteLimit: Int

    init(limit: Int, byteLimit: Int) {
        self.limit = limit
        self.byteLimit = byteLimit
    }

    var isOpen: Bool { state.withLock { !$0.closed } }

    func insert(_ rawID: String, request: RequestID) throws(MCPError) {
        let id = ExactString(rawID)
        let size = rawID.utf8.count
        try state.withLock { state throws(MCPError) in
            guard state.entries[id] == nil else {
                throw .invalidParams("elicitationId has already been registered")
            }
            guard !state.closed, state.entries.count < limit, size <= byteLimit - state.bytes else {
                throw .overloaded("client URL elicitation tracking budget is occupied")
            }
            state.entries[id] = Entry(request: request)
            state.bytes += size
        }
    }

    func require(_ rawIDs: [String]) -> Bool {
        let ids = rawIDs.map(ExactString.init)
        return state.withLock { state in
            guard !state.closed else { return false }
            let additions = Set(ids.filter { state.entries[$0] == nil })
            guard additions.count <= limit - state.entries.count else { return false }
            var bytes = state.bytes
            for id in additions {
                let size = id.text.utf8.count
                guard size <= byteLimit - bytes else { return false }
                bytes += size
            }
            state.bytes = bytes
            for id in additions { state.entries[id] = Entry() }
            for id in ids {
                state.entries[id]?.eligible = true
                state.publishIfReady(id)
            }
            return true
        }
    }

    func finish(_ rawID: String, request: RequestID, accepted: Bool) {
        let id = ExactString(rawID)
        state.withLock { state in
            guard var entry = state.entries[id], entry.request == request else { return }
            if accepted || entry.eligible {
                entry.request = nil
                entry.eligible = true
                state.entries[id] = entry
                state.publishIfReady(id)
            } else {
                state.entries.removeValue(forKey: id)
                state.bytes -= rawID.utf8.count
            }
        }
    }

    func complete(_ rawID: String) {
        let id = ExactString(rawID)
        state.withLock { state in
            state.entries[id]?.notified = true
            state.publishIfReady(id)
        }
    }

    func completions(bufferSize: Int) -> AsyncStream<String> {
        let capacity = max(1, bufferSize)
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        let id: UInt64? = state.withLock { state in
            guard !state.closed, state.nextSubscriber < UInt64.max else { return nil }
            state.nextSubscriber += 1
            state.subscribers[state.nextSubscriber] = continuation
            for event in state.events.suffix(capacity) { continuation.yield(event.text) }
            return state.nextSubscriber
        }
        if let id {
            continuation.onTermination = { [weak self] _ in
                Task { self?.removeSubscriber(id) }
            }
        } else {
            continuation.finish()
        }
        return stream
    }

    private func removeSubscriber(_ id: UInt64) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }

    func close() {
        let continuations = state.withLock {
            let continuations = Array($0.subscribers.values)
            $0 = State(closed: true)
            return continuations
        }
        for continuation in continuations { continuation.finish() }
    }
}
