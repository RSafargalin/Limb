public import LimbCore

/// What the client can establish about publication of a failed request.
public enum ClientDelivery: Sendable, Equatable {
    /// The request was withdrawn before sending, or the adapter proved it was never sent.
    case notSent
    /// The client cannot establish that the request was never sent.
    case unknown
}

/// Local failures of the client. JSON-RPC errors from the peer are thrown as `MCPError`.
public enum ClientError: Error, Sendable, Equatable {
    case recovering
    case cancelled(ClientDelivery)
    case timedOut(ClientDelivery)
    case exchangeLost(ClientDelivery)
    case connectionLost(ClientDelivery)
    case protocolViolation(ClientDelivery)
    case httpRejected(status: Int, delivery: ClientDelivery)
    case closedDuringRequest(ClientDelivery)
    case closed
    case overloaded
    case workOverloaded(ClientDelivery)
    /// Frame preparation exceeded the transport's limit before sending. Bytes exclude the newline.
    case requestTooLarge(bytes: Int, limit: Int)
    case requestIDsExhausted
}

struct ClientExchangeResult: Sendable {
    let value: JSONValue
    // A response can reach the caller while the adapter is still releasing its send slot.
    let retirement: Task<Void, Never>?
}

/// A client for one configured MCP peer.
public actor Client {
    private struct Pending {
        let submission: ClientSubmission
        let timer: Task<Void, Never>
        let continuation: CheckedContinuation<JSONValue, any Error>
        let progress: ClientProgressDelivery?
        let ownsProgress: Bool
        var lastProgress: JSONNumber?

        func finishProgress(discardPending: Bool) {
            if ownsProgress { progress?.finish(discardPending: discardPending) }
        }
    }

    private struct Sending {
        let submission: ClientSubmission
        let task: Task<Void, Never>
    }

    private struct Subscription {
        struct Opening {
            let stream: ClientSubscription.Stream
            let continuation: CheckedContinuation<ClientSubscription, any Error>
            let timer: Task<Void, Never>
        }

        let submission: ClientSubmission
        let requested: ClientSubscriptionFilter
        let events: ClientSubscription.Stream.Continuation
        var opening: Opening?
        var confirmed: ClientSubscriptionFilter?

        func finish(_ error: (any Error)?) {
            opening?.timer.cancel()
            opening?.continuation.resume(throwing: error ?? ClientError.protocolViolation(.unknown))
            events.finish(throwing: error)
        }
    }

    private enum Connection: Sendable {
        case session(any ClientTransport)
        case recovering(ClientRecovery)
    }

    private nonisolated let connection: Connection
    private var transport: any ClientTransport {
        guard case .session(let transport) = connection else { preconditionFailure("Expected a physical MCP session") }
        return transport
    }
    nonisolated var recovery: ClientRecovery? {
        guard case .recovering(let recovery) = connection else { return nil }
        return recovery
    }
    nonisolated let profile: RevisionProfile
    nonisolated let work: ClientWorkPool
    nonisolated let inputHandlers: ClientInputHandlers?
    nonisolated let serverIdentity: String?
    private let legacyInput: ClientLegacyInput?
    public nonisolated var protocolVersion: ProtocolVersion { profile.version }
    private nonisolated let peerInfo: Implementation?
    private nonisolated let peerCapabilities: JSONObject?
    public nonisolated var serverInfo: Implementation? {
        if let recovery { return recovery.peer.info }
        return peerInfo
    }
    public nonisolated var serverCapabilities: JSONObject? {
        if let recovery { return recovery.peer.capabilities }
        return peerCapabilities
    }
    private let routing: ClientRouting
    private let maxPending: Int
    private let reportsDisconnectedSession: Bool
    private nonisolated let progressQuota: ClientWorkQuota
    private let clock = ContinuousClock()
    private var pending: [RequestID: Pending] = [:]
    private var sending: [RequestID: Sending] = [:]
    private var subscriptions: [RequestID: Subscription] = [:]
    private var subscriptionSends: [RequestID: Sending] = [:]
    private var legacySubscriptions = ClientLegacySubscriptions()
    private var lastID: Int
    private var shutdown: Task<Void, Never>?
    private var shutdownChannelLost = false
    private var disconnectObserver: AsyncStream<Void>.Continuation?
    private var logStreams: [UInt64: AsyncStream<ClientLogMessage>.Continuation] = [:]
    private var lastLogStreamID: UInt64 = 0

    package init(
        transport: any ClientTransport, profile: RevisionProfile, routing: ClientRouting,
        maxPending: Int = 128, lastIssuedRequestID: Int = 0,
        serverInfo: Implementation? = nil, serverCapabilities: JSONObject? = nil,
        inputHandlers: ClientInputHandlers? = nil, serverIdentity: String? = nil,
        legacyInput: ClientLegacyInput? = nil, executionQuotas: ClientExecutionQuotas? = nil
    ) {
        precondition(lastIssuedRequestID >= 0)
        self.connection = .session(transport)
        self.profile = profile
        self.routing = routing
        self.maxPending = max(1, maxPending)
        self.reportsDisconnectedSession = executionQuotas != nil
        self.work = ClientWorkPool(limit: max(1, maxPending), quota: executionQuotas?.outgoing)
        self.progressQuota = executionQuotas?.progress ?? ClientWorkQuota(limit: max(1, maxPending))
        self.lastID = lastIssuedRequestID
        self.peerInfo = serverInfo
        self.peerCapabilities = serverCapabilities
        self.inputHandlers = inputHandlers
        self.serverIdentity = serverIdentity
        self.legacyInput = legacyInput
    }

    private init(session: Client, limit: Int, recovery: ClientRecovery) {
        self.connection = .recovering(recovery)
        self.profile = session.profile
        self.routing = .sharedChannel
        self.maxPending = limit
        self.reportsDisconnectedSession = false
        self.work = ClientWorkPool(limit: limit)
        self.progressQuota = ClientWorkQuota(limit: limit)
        self.lastID = 0
        self.peerInfo = nil
        self.peerCapabilities = nil
        self.inputHandlers = nil
        self.serverIdentity = session.serverIdentity
        self.legacyInput = nil
    }

    deinit {
        if let recovery { Task { await recovery.close() } }
    }

    package static func withStdioRecovery(
        _ session: Client, limit: Int, backoff: Duration, reconnect: @escaping @Sendable (Int) async throws -> Client
    ) async throws -> Client {
        let recovery = ClientRecovery(session: session, limit: limit, backoff: backoff, reconnect: reconnect)
        do {
            try await recovery.start()
        } catch {
            await session.close()
            throw error
        }
        return Client(session: session, limit: limit, recovery: recovery)
    }

    func disconnects() -> AsyncStream<Void> {
        let (stream, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        if shutdown != nil {
            if shutdownChannelLost { signal.yield(()) }
            signal.finish()
        } else {
            disconnectObserver = signal
        }
        return stream
    }

    var lostChannel: Bool { shutdownChannelLost }

    func waitForDisconnectedCleanup() async { await shutdown?.value }

    var requestIDFloor: Int { lastID }

    /// Run one prepared RPC. The timeout includes waiting for the adapter.
    package func request(_ method: String, params: JSONObject = [:], timeout: Duration = .seconds(60)) async throws -> JSONValue {
        do {
            return try await request(method, params: params, options: ClientRequestOptions(timeout: timeout))
        } catch ClientError.requestTooLarge(_, _) {
            // Preserve the package-level exchange API's private transport failure contract.
            throw ClientError.exchangeLost(.notSent)
        }
    }

    func request(_ method: String, params: JSONObject, options: ClientRequestOptions) async throws -> JSONValue {
        if let recovery { return try await recovery.session().request(method, params: params, options: options) }
        return try await exchange(method, params: params, options: options).value
    }

    nonisolated func reserveProgress(_ callback: @escaping @Sendable (ClientProgress) -> Void) throws(ClientError) -> ClientProgressDelivery {
        guard let progress = ClientProgressDelivery(callback, quota: progressQuota) else {
            throw .workOverloaded(.notSent)
        }
        return progress
    }

    func exchange(
        _ method: String, params: JSONObject, options: ClientRequestOptions, progress shared: ClientProgressDelivery? = nil
    ) async throws -> ClientExchangeResult {
        try ensureOpen()
        guard !Task.isCancelled else { throw ClientError.cancelled(.notSent) }
        let deadline = options.absoluteDeadline ?? clock.now.advanced(by: options.timeout)
        guard clock.now < deadline else { throw ClientError.timedOut(.notSent) }
        guard pending.count < maxPending, sending.count < maxPending else { throw ClientError.overloaded }
        guard lastID < Int.max else {
            _ = beginClose(channelLost: false)
            throw ClientError.requestIDsExhausted
        }
        let progress = try shared ?? options.onProgress.map(reserveProgress)
        lastID += 1
        let id = RequestID(lastID)
        var params = params
        if progress != nil || (profile.hasDiscover && options.logLevel != nil) {
            var metadata = params["_meta"]?.objectValue ?? [:]
            if progress != nil { metadata[MetaKey.progressToken] = id.json }
            if profile.hasDiscover, let level = options.logLevel {
                metadata[MetaKey.logLevel] = .string(level.rawValue)
            }
            params["_meta"] = .object(metadata)
        }
        let request = ClientRequest(
            id: id, method: method, params: params, profile: profile,
            deadline: deadline
        )
        let submission = ClientSubmission(
            cancellation: profile.hasInitialize && request.method == "initialize" ? .abortBootstrap : .cancelExchange,
            deadline: request.deadline
        )
        let value: JSONValue = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    request, submission: submission, continuation: continuation, progress: progress,
                    ownsProgress: shared == nil)
            }
        } onCancel: {
            _ = submission.finish(.cancelled)
            Task { await self.fail(request.id, with: .cancelled) }
        }
        return ClientExchangeResult(value: value, retirement: sending[id]?.task)
    }

    /// Close the client and wait for the adapter to release its resources.
    public func close() async {
        if let recovery { await recovery.close(); return }
        work.close()
        await beginClose(channelLost: false).value
    }

    func ensureOpen() throws(ClientError) {
        if shutdown != nil {
            throw reportsDisconnectedSession && shutdownChannelLost ? .connectionLost(.notSent) : .closed
        }
    }

    private func issueRequestID() throws(ClientError) -> RequestID {
        guard lastID < Int.max else {
            _ = beginClose(channelLost: false)
            throw .requestIDsExhausted
        }
        lastID += 1
        return RequestID(lastID)
    }

    func continuationClosedError() -> ClientError {
        shutdownChannelLost ? .connectionLost(.unknown) : .closedDuringRequest(.unknown)
    }

    /// Receive MCP log notifications on this connection. A slow consumer gets the newest messages
    /// up to its buffer size. On shared stdio, the wire does not identify the originating call.
    public func logMessages(bufferSize: Int = 32) async -> AsyncStream<ClientLogMessage> {
        if let recovery {
            guard let session = try? await recovery.session() else { return AsyncStream { $0.finish() } }
            return await session.logMessages(bufferSize: bufferSize)
        }
        let (stream, continuation) = AsyncStream<ClientLogMessage>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, bufferSize)))
        guard shutdown == nil, lastLogStreamID < UInt64.max else {
            continuation.finish()
            return stream
        }
        lastLogStreamID += 1
        let id = lastLogStreamID
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLogStream(id) }
        }
        logStreams[id] = continuation
        return stream
    }

    private func removeLogStream(_ id: UInt64) {
        logStreams.removeValue(forKey: id)
    }

    /// Observe completed URL elicitation IDs on a negotiated MCP 2025-11-25 connection.
    /// Each subscriber starts with the newest completed IDs from this session and receives
    /// subsequent events up to its buffer size.
    public func elicitationCompletions(bufferSize: Int = 32) async -> AsyncStream<String> {
        if let recovery {
            guard let session = try? await recovery.session() else { return AsyncStream { $0.finish() } }
            return await session.elicitationCompletions(bufferSize: bufferSize)
        }
        if shutdown == nil, let stream = legacyInput?.completions(bufferSize: bufferSize) {
            return stream
        }
        return AsyncStream { $0.finish() }
    }

    func register(
        _ request: ClientRequest, submission: ClientSubmission, continuation: CheckedContinuation<JSONValue, any Error>,
        progress: ClientProgressDelivery? = nil, ownsProgress: Bool = true
    ) {
        // The cancellation handler can fire before the continuation is installed.
        if Task.isCancelled, case .failure(let error) = submission.finish(.cancelled) {
            if ownsProgress { progress?.finish(discardPending: true) }
            continuation.resume(throwing: error)
            return
        }
        let clock = self.clock
        let timer = Task { [weak self] in
            do {
                try await clock.sleep(until: request.deadline)
                await self?.fail(request.id, with: .timedOut)
            } catch {
                return
            }
        }
        pending[request.id] = Pending(
            submission: submission, timer: timer, continuation: continuation, progress: progress,
            ownsProgress: ownsProgress)
        sending[request.id] = startSend(request, submission: submission)
    }

    private func startSend(_ request: ClientRequest, submission: ClientSubmission) -> Sending {
        let task = Task { [transport, weak self] in
            if submission.canSubmit {
                await transport.send(request, submission: submission) { [weak self] event in
                    await self?.receive(event)
                }
            }
            await self?.submissionEnded(request.id)
        }
        return Sending(submission: submission, task: task)
    }

    private func submissionEnded(_ id: RequestID) {
        fail(id, with: .exchangeLost())
        sending.removeValue(forKey: id)
        subscriptionSends.removeValue(forKey: id)
        if let transition = legacySubscriptions.transitions.removeValue(forKey: id) {
            legacySubscriptions.retiring.removeValue(forKey: transition.key)
            collectLegacyReleases()
            pumpLegacyTransitions()
        }
    }

    package func receive(_ event: ClientTransportEvent) {
        switch event {
        case .response(let source, let id, let result):
            guard routing.accepts(source, for: id) else { return }
            respond(id, with: result)
        case .notification(let source, let method, let params):
            receiveNotification(method, params: params, source: source)
        case .uncorrelatedError(let id, let error):
            guard routing.accepts(.exchange(id), for: id) else { return }
            respond(id, with: .failure(error))
        case .protocolViolation(let source, let id):
            guard routing.accepts(source, for: id) else { return }
            fail(id, with: .protocolViolation)
        case .httpRejected(let id, let status):
            guard routing.accepts(.exchange(id), for: id) else { return }
            fail(id, with: .httpRejected(status))
        case .requestTooLarge(let id, let bytes, let limit):
            fail(id, with: .requestTooLarge(bytes: bytes, limit: limit))
        case .sendFailed(let id, let provenNotSent):
            fail(id, with: .exchangeLost(provenNotSent: provenNotSent))
        case .exchangeEnded(let id):
            guard routing.accepts(.exchange(id), for: id) else { return }
            fail(id, with: .exchangeLost())
        case .channelEnded:
            _ = beginClose(channelLost: true)
        }
    }

    private func receiveNotification(_ method: String, params: JSONObject, source: ClientResponseSource) {
        guard shutdown == nil else { return }
        if profile.hasSubscriptionsListen, receiveSubscriptionNotification(method, params: params, source: source) {
            return
        }
        if profile.legacySubscriptions, routing.acceptsUnsolicitedLegacy(source) {
            receiveLegacySubscriptionNotification(method, params: params)
        }
        switch method {
        case "notifications/progress":
            guard let value = params[MetaKey.progressToken], let id = RequestID(json: value),
                  routing.accepts(source, for: id), let entry = pending[id],
                  let progress = entry.progress, entry.submission.acceptsProgress,
                  let number = params["progress"]?.numberValue,
                  entry.lastProgress.map({ $0 < number }) ?? true, number.doubleValue.isFinite else { return }
            do {
                let total: Double? = try params.wireOptional("total")
                let message: String? = try params.wireOptional("message")
                pending[id]?.lastProgress = number
                progress.continuation.yield(ClientProgress(progress: number.doubleValue, total: total, message: message))
            } catch {
                // An invalid notification has no effect on the exchange.
            }
        case "notifications/message":
            guard !logStreams.isEmpty, routing.acceptsLog(source), let log = try? ClientLogMessage(params) else { return }
            for continuation in logStreams.values { continuation.yield(log) }
        case "notifications/elicitation/complete":
            guard routing.acceptsUnsolicitedLegacy(source),
                  let id = params["elicitationId"]?.stringValue else { return }
            legacyInput?.completeURL(id)
        default:
            break
        }
    }

    private func submission(for id: RequestID) -> ClientSubmission? {
        pending[id]?.submission ?? sending[id]?.submission
    }

    private func respond(_ id: RequestID, with result: Result<JSONValue, MCPError>) {
        if settleLegacyTransition(id, ending: .response, response: result) { return }
        if let (subscription, outcome) = takeSubscription(id, ending: .response) {
            switch outcome {
            case .failure(let error): subscription.finish(error)
            case .response:
                switch result {
                case .failure(let error): subscription.finish(error)
                case .success(let value):
                    if value["resultType"] == "complete",
                       value["_meta"]?[MetaKey.subscriptionID].flatMap(RequestID.init(json:)) == id {
                        subscription.finish(nil)
                    } else {
                        subscription.finish(ClientError.protocolViolation(.unknown))
                    }
                }
            }
            return
        }
        guard let outcome = submission(for: id)?.finish(.response), let entry = remove(id) else { return }
        switch outcome {
        case .response:
            entry.finishProgress(discardPending: false)
            if case .failure(let error) = result, legacyInput?.recordRequiredURLs(error) == false {
                entry.continuation.resume(throwing: ClientInputError.urlElicitationTrackingOverloaded(original: error))
                return
            }
            entry.continuation.resume(with: result)
        case .failure(let error):
            entry.finishProgress(discardPending: true)
            entry.continuation.resume(throwing: error)
        }
    }

    private func remove(_ id: RequestID) -> Pending? {
        let entry = pending.removeValue(forKey: id)
        entry?.timer.cancel()
        return entry
    }

    private func fail(_ id: RequestID, with ending: ClientSubmission.Ending) {
        if settleLegacyTransition(id, ending: ending) { return }
        if let (subscription, outcome) = takeSubscription(id, ending: ending) {
            if case .failure(let error) = outcome { subscription.finish(error) }
            return
        }
        guard let outcome = submission(for: id)?.finish(ending),
              case .failure(let error) = outcome, let entry = remove(id) else { return }
        entry.finishProgress(discardPending: true)
        entry.continuation.resume(throwing: error)
    }

    private func beginClose(channelLost: Bool) -> Task<Void, Never> {
        // The reader can report EOF while an explicit close is still draining sends.
        if channelLost {
            work.channelEnded()
            for send in sending.values { _ = send.submission.finish(.connectionLost) }
            for send in subscriptionSends.values { _ = send.submission.finish(.connectionLost) }
        }
        if let shutdown { return shutdown }
        shutdownChannelLost = channelLost
        for continuation in logStreams.values { continuation.finish() }
        logStreams.removeAll()
        legacyInput?.close()
        if profile.legacySubscriptions { closeLegacySubscriptions(channelLost: channelLost) }
        for id in pending.keys {
            fail(id, with: channelLost ? .connectionLost : .closed)
        }
        for id in subscriptions.keys {
            if let (subscription, outcome) = takeSubscription(id, ending: channelLost ? .connectionLost : .closed),
               case .failure(let error) = outcome {
                subscription.finish(!channelLost && subscription.opening == nil ? nil : error)
            }
        }
        let sends = sending.values.map(\.task) + subscriptionSends.values.map(\.task)
        let shutdown = Task { [transport] in
            await transport.close()
            for send in sends { await send.value }
        }
        self.shutdown = shutdown
        if channelLost { disconnectObserver?.yield(()) }
        disconnectObserver?.finish()
        disconnectObserver = nil
        return shutdown
    }
}

extension Client {
    /// Open a subscription using the negotiated revision. The timeout applies to opening
    /// the subscription. A confirmed subscription has no idle deadline.
    public func subscribe(
        filter: ClientSubscriptionFilter, timeout: Duration = .seconds(15), bufferSize: Int = 32
    ) async throws -> ClientSubscription {
        guard timeout > .zero, timeout <= .seconds(Int32.max), bufferSize > 0 else {
            throw ClientSubscriptionError.invalidOptions
        }
        if let recovery {
            return try await recovery.subscribe(filter: filter, timeout: timeout, bufferSize: bufferSize, owner: self)
        }
        try ensureOpen()
        guard !Task.isCancelled else { throw ClientError.cancelled(.notSent) }
        if profile.legacySubscriptions, case .sharedChannel = routing {
            return try await subscribeLegacy(filter: filter, timeout: timeout, bufferSize: bufferSize)
        }
        guard profile.hasSubscriptionsListen else { throw ClientSubscriptionError.unsupportedVersion(protocolVersion) }
        guard subscriptionSends.count < maxPending else { throw ClientError.overloaded }
        let id = try issueRequestID()
        let deadline = clock.now + timeout
        let submission = ClientSubmission(cancellation: .cancelExchange, deadline: deadline)
        let request = ClientRequest(
            id: id, method: "subscriptions/listen", params: ["notifications": .object(filter.wire)],
            profile: profile, deadline: deadline)
        let (stream, events) = ClientSubscription.Stream.makeStream(bufferingPolicy: .bufferingOldest(bufferSize))
        events.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.cancelSubscription(id) }
            }
        }
        let subscription: ClientSubscription = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: ClientError.cancelled(.notSent))
                    return
                }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.expireSubscriptionOpening(id)
                }
                subscriptions[id] = Subscription(
                    submission: submission, requested: filter, events: events,
                    opening: .init(stream: stream, continuation: continuation, timer: timer))
                subscriptionSends[id] = startSend(request, submission: submission)
            }
        } onCancel: {
            _ = submission.finish(.cancelled)
            Task { await self.cancelSubscription(id) }
        }
        if Task.isCancelled {
            await cancelSubscription(id)
            throw ClientError.cancelled(.unknown)
        }
        return subscription
    }

    private func expireSubscriptionOpening(_ id: RequestID) {
        if subscriptions[id]?.opening != nil { fail(id, with: .timedOut) }
    }

    private func cancelSubscription(_ id: RequestID) async {
        let send = subscriptionSends[id]?.task
        stopSubscription(id)
        await send?.value
    }

    private func stopSubscription(_ id: RequestID, error: (any Error)? = nil) {
        guard let (subscription, outcome) = takeSubscription(id, ending: .cancelled),
              case .failure(let failure) = outcome else { return }
        if case .cancelled = failure {
            subscription.finish(error ?? (subscription.opening != nil ? failure : nil))
        } else {
            subscription.finish(failure)
        }
    }

    private func takeSubscription(
        _ id: RequestID, ending: ClientSubmission.Ending
    ) -> (Subscription, ClientSubmission.Outcome)? {
        guard let subscription = subscriptions[id], let outcome = subscription.submission.finish(ending) else { return nil }
        subscriptions.removeValue(forKey: id)
        return (subscription, outcome)
    }

    /// A shared channel attributes an event only when the peer names its subscription.
    private func receiveSubscriptionNotification(
        _ method: String, params: JSONObject, source: ClientResponseSource
    ) -> Bool {
        if method == "notifications/cancelled" {
            guard let id = ClientSubscriptionWire.cancellationID(params), routing.accepts(source, for: id),
                  let (subscription, outcome) = takeSubscription(id, ending: .response) else { return true }
            switch outcome {
            case .response: subscription.finish(nil)
            case .failure(let error):
                subscription.finish(error)
            }
            return true
        }
        guard let wireID = params["_meta"]?[MetaKey.subscriptionID] else { return false }
        guard let id = RequestID(json: wireID), routing.accepts(source, for: id),
              let subscription = subscriptions[id], subscription.submission.acceptsProgress else { return true }
        if method == "notifications/subscriptions/acknowledged" {
            acknowledgeSubscription(id, subscription: subscription, params: params)
        } else if let event = subscription.confirmed?.event(method: method, params: params) {
            if case .dropped = subscription.events.yield(event) {
                stopSubscription(id, error: ClientSubscriptionError.bufferOverflow)
            }
        } else {
            stopSubscription(id, error: ClientError.protocolViolation(.unknown))
        }
        return true
    }

    private func acknowledgeSubscription(_ id: RequestID, subscription: Subscription, params: JSONObject) {
        guard let opening = subscription.opening, let send = subscriptionSends[id],
              let filter = params["notifications"]?.objectValue,
              let confirmed = try? ClientSubscriptionFilter(wire: filter), subscription.requested.contains(confirmed) else {
            stopSubscription(id, error: ClientError.protocolViolation(.unknown))
            return
        }
        guard subscription.submission.acknowledge() else { return }
        opening.timer.cancel()
        subscriptions[id]?.opening = nil
        subscriptions[id]?.confirmed = confirmed
        let handle = ClientSubscription(confirmedFilter: confirmed, stream: opening.stream, retirement: send.task) { [self] in
            await cancelSubscription(id)
        }
        opening.continuation.resume(returning: handle)
    }
}

extension Client {
    private enum LegacyLeaseEnd {
        case cancelled
        case timedOut
        case failed(any Error)

        func error(opening: Bool, delivery: ClientDelivery) -> (any Error)? {
            switch self {
            case .cancelled: opening ? ClientError.cancelled(delivery) : nil
            case .timedOut: ClientError.timedOut(delivery)
            case .failed(let error): error
            }
        }
    }

    private func subscribeLegacy(
        filter requested: ClientSubscriptionFilter, timeout: Duration, bufferSize: Int
    ) async throws -> ClientSubscription {
        guard legacySubscriptions.leases.count < maxPending, legacySubscriptions.lastLeaseID < UInt64.max else {
            throw ClientError.overloaded
        }
        let filter = ClientLegacySubscriptions.filter(requested, capabilities: serverCapabilities)
        let keys = serverCapabilities?["resources"]?["subscribe"]?.boolValue == true
            ? try legacySubscriptions.admittedKeys(requested.resourceSubscriptions) : []
        legacySubscriptions.lastLeaseID += 1
        let owner = legacySubscriptions.lastLeaseID
        let deadline = clock.now + timeout
        let opened: ClientLegacySubscriptions.Opened = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: ClientError.cancelled(.notSent))
                    return
                }
                let (stream, events) = ClientSubscription.Stream.makeStream(bufferingPolicy: .bufferingOldest(bufferSize))
                events.onTermination = { [weak self] termination in
                    if case .cancelled = termination { Task { await self?.endLegacyLease(owner, ending: .cancelled) } }
                }
                let (release, retired) = AsyncStream<Void>.makeStream()
                let retirement = Task { for await _ in release {} }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.endLegacyOpening(owner, ending: .timedOut)
                }
                legacySubscriptions.leases[owner] = .init(
                    keys: keys, events: events, retired: retired, retirement: retirement, filter: filter,
                    opening: .init(stream: stream, continuation: continuation, deadline: deadline, timer: timer),
                    awaiting: Set(keys))
                legacySubscriptions.addOwner(owner, keys: keys)
                for key in keys {
                    switch legacySubscriptions.resources[key]?.registration {
                    case .registered:
                        resolveLegacyOwner(owner, key: key, error: nil, delivery: .notSent)
                    case .unknown:
                        resolveLegacyOwner(
                            owner, key: key, error: ClientSubscriptionError.legacyResourceStateUnknown(uri: key.text),
                            delivery: .notSent)
                    default:
                        break
                    }
                }
                completeLegacyOpening(owner)
                collectLegacyReleases()
                pumpLegacyTransitions()
            }
        } onCancel: {
            Task { await self.endLegacyOpening(owner, ending: .cancelled) }
        }
        if Task.isCancelled {
            endLegacyLease(owner, ending: .cancelled)
            throw ClientError.cancelled(opened.delivery)
        }
        return opened.handle
    }

    private func resolveLegacyOwner(_ owner: UInt64, key: ExactString, error: (any Error)?, delivery: ClientDelivery) {
        guard legacySubscriptions.leases[owner]?.awaiting.remove(key) != nil else { return }
        if delivery == .unknown { legacySubscriptions.leases[owner]?.opening?.delivery = delivery }
        if let error {
            legacySubscriptions.leases[owner]?.opening?.errors[key] = error
            legacySubscriptions.resources[key]?.owners.remove(owner)
        } else {
            legacySubscriptions.leases[owner]?.confirmed.insert(key)
        }
    }

    private func completeLegacyOpening(_ owner: UInt64) {
        guard let lease = legacySubscriptions.leases[owner], let opening = lease.opening else { return }
        guard clock.now < opening.deadline else {
            endLegacyLease(owner, ending: .timedOut)
            return
        }
        guard lease.awaiting.isEmpty else { return }
        var filter = lease.filter
        filter.resourceSubscriptions = lease.keys.filter { lease.confirmed.contains($0) }.map(\.text)
        if filter == ClientSubscriptionFilter(), let error = lease.keys.lazy.compactMap({ opening.errors[$0] }).first {
            endLegacyLease(owner, ending: .failed(error))
            return
        }
        opening.timer.cancel()
        legacySubscriptions.leases[owner]?.opening = nil
        let handle = ClientSubscription(confirmedFilter: filter, stream: opening.stream, retirement: lease.retirement) { [self] in
            await endLegacyLease(owner, ending: .cancelled)
        }
        opening.continuation.resume(returning: .init(handle: handle, delivery: opening.delivery))
    }

    private func endLegacyOpening(_ owner: UInt64, ending: LegacyLeaseEnd) {
        if legacySubscriptions.leases[owner]?.opening != nil { endLegacyLease(owner, ending: ending) }
    }

    private func endLegacyLease(_ owner: UInt64, ending: LegacyLeaseEnd) {
        guard let lease = legacySubscriptions.leases.removeValue(forKey: owner) else { return }
        var delivery = lease.opening?.delivery ?? .notSent
        var released: Set<ExactString> = []
        for key in lease.keys {
            guard legacySubscriptions.resources[key]?.owners.remove(owner) != nil,
                  let resource = legacySubscriptions.resources[key] else { continue }
            if case .transitioning(.subscribe, let id) = resource.registration {
                let submission = subscriptionSends[id]?.submission
                if resource.owners.isEmpty {
                    _ = submission?.finish(.cancelled)
                    fail(id, with: .cancelled)
                }
                if submission?.delivery == .unknown { delivery = .unknown }
            }
            // An opening waiter behind an unsubscribe has no registration to release.
            if lease.confirmed.contains(key), resource.owners.isEmpty { released.insert(key) }
            legacySubscriptions.discardIfUnowned(key)
        }
        let error = ending.error(opening: lease.opening != nil, delivery: delivery)
        lease.opening?.timer.cancel()
        lease.opening?.continuation.resume(throwing: error ?? ClientError.cancelled(delivery))
        lease.events.finish(throwing: error)
        if released.isEmpty {
            lease.retired.finish()
        } else {
            legacySubscriptions.releases[owner] = .init(keys: released, retired: lease.retired)
        }
        collectLegacyReleases()
        pumpLegacyTransitions()
    }

    private func collectLegacyReleases() {
        for id in legacySubscriptions.releases.keys {
            guard var release = legacySubscriptions.releases[id] else { continue }
            release.keys = release.keys.filter { key in
                legacySubscriptions.retiring[key] != nil || legacySubscriptions.resources[key]?.needsRetirement == true
            }
            if release.keys.isEmpty {
                legacySubscriptions.releases.removeValue(forKey: id)
                release.retired.finish()
            } else {
                legacySubscriptions.releases[id] = release
            }
        }
    }

    private func pumpLegacyTransitions() {
        guard shutdown == nil else { return }
        let opening = legacySubscriptions.transitions.values.lazy.filter { $0.operation == .subscribe }.count
        var openSlots = maxPending - opening
        var releaseSlots = maxPending - (legacySubscriptions.transitions.count - opening)
        // Long-lived, unacknowledged opens cannot consume the capacity needed to release other URIs.
        while let (key, operation) = legacySubscriptions.nextTransition(
            canSubscribe: openSlots > 0, canUnsubscribe: releaseSlots > 0
        ) {
            guard let id = try? issueRequestID() else { return }
            let writeDeadline = clock.now + .seconds(15)
            let request = ClientRequest(
                id: id, method: operation.rawValue, params: ["uri": .string(key.text)], profile: profile, deadline: writeDeadline)
            // Owners set independent opening deadlines. A shared subscribe can keep receiving
            // after the write deadline until its last waiting owner leaves.
            let deadline = operation == .subscribe ? clock.now + .seconds(Int32.max) : writeDeadline
            let submission = ClientSubmission(cancellation: .cancelExchange, deadline: deadline)
            let timer: Task<Void, Never>?
            if operation == .unsubscribe {
                releaseSlots -= 1
                timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.fail(id, with: .timedOut)
                }
            } else {
                openSlots -= 1
                timer = nil
            }
            legacySubscriptions.resources[key]?.registration = .transitioning(operation, id)
            legacySubscriptions.transitions[id] = .init(key: key, operation: operation, timer: timer)
            legacySubscriptions.retiring[key] = id
            subscriptionSends[id] = startSend(request, submission: submission)
        }
    }

    private func settleLegacyTransition(
        _ id: RequestID, ending: ClientSubmission.Ending, response: Result<JSONValue, MCPError>? = nil
    ) -> Bool {
        guard let transition = legacySubscriptions.transitions[id] else { return false }
        guard let submission = subscriptionSends[id]?.submission, let outcome = submission.finish(ending),
              let resource = legacySubscriptions.resources[transition.key] else { return true }
        let key = transition.key
        if transition.settled {
            // A cancelled caller keeps its original delivery outcome. The adapter can still
            // prove that the wire state never changed before retiring this transition.
            if case .exchangeLost(provenNotSent: true) = ending, case .unknown = resource.registration {
                legacySubscriptions.resources[key]?.registration = transition.operation == .subscribe ? .unregistered : .retained
                legacySubscriptions.discardIfUnowned(key)
            }
            return true
        }
        legacySubscriptions.transitions[id]?.settled = true
        transition.timer?.cancel()
        let error: (any Error)?
        switch outcome {
        case .response:
            switch response {
            case .failure(let peerError): error = peerError
            case .success(let value) where value.objectValue.map(ClientLegacySubscriptions.hasValidMetadata) == true:
                error = nil
            default: error = ClientError.protocolViolation(.unknown)
            }
        case .failure(let localError): error = localError
        }
        let delivery = submission.delivery
        switch (transition.operation, error) {
        case (.subscribe, nil):
            legacySubscriptions.resources[key]?.registration = .registered
            for owner in resource.owners { resolveLegacyOwner(owner, key: key, error: nil, delivery: delivery) }
        case (.subscribe, let failure?):
            let certainRejection = delivery == .notSent || failure is MCPError
            legacySubscriptions.resources[key]?.registration = certainRejection ? .unregistered : .unknown
            let ownerError = certainRejection ? failure : ClientSubscriptionError.legacyResourceStateUnknown(uri: key.text)
            for owner in resource.owners { resolveLegacyOwner(owner, key: key, error: ownerError, delivery: delivery) }
        case (.unsubscribe, nil):
            legacySubscriptions.resources[key]?.registration = .unregistered
        case (.unsubscribe, _?):
            if delivery == .notSent {
                legacySubscriptions.resources[key]?.registration = resource.owners.isEmpty ? .retained : .registered
                for owner in resource.owners { resolveLegacyOwner(owner, key: key, error: nil, delivery: .notSent) }
            } else {
                legacySubscriptions.resources[key]?.registration = .unknown
                let error = ClientSubscriptionError.legacyResourceStateUnknown(uri: key.text)
                for owner in resource.owners { resolveLegacyOwner(owner, key: key, error: error, delivery: .notSent) }
            }
        }
        for owner in resource.owners { completeLegacyOpening(owner) }
        legacySubscriptions.discardIfUnowned(key)
        return true
    }

    private func receiveLegacySubscriptionNotification(_ method: String, params: JSONObject) {
        guard !legacySubscriptions.leases.isEmpty, ClientLegacySubscriptions.hasValidMetadata(params) else { return }
        switch method {
        case "notifications/tools/list_changed", "notifications/prompts/list_changed", "notifications/resources/list_changed":
            for (owner, lease) in legacySubscriptions.leases {
                if let event = lease.filter.event(method: method, params: params) { yieldLegacy(event, to: owner) }
            }
        case "notifications/resources/updated":
            guard let uri = params["uri"]?.stringValue else { return }
            let changed = ExactString(uri)
            for (owner, lease) in legacySubscriptions.leases {
                for key in lease.keys where lease.confirmed.contains(key) {
                    let event: ClientSubscriptionEvent = key == changed ? .resourceUpdated(uri: uri) : .resourceInvalidated(uri: key.text)
                    if !yieldLegacy(event, to: owner) { break }
                }
            }
        default:
            break
        }
    }

    @discardableResult
    private func yieldLegacy(_ event: ClientSubscriptionEvent, to owner: UInt64) -> Bool {
        guard let events = legacySubscriptions.leases[owner]?.events else { return false }
        if case .dropped = events.yield(event) {
            endLegacyLease(owner, ending: .failed(ClientSubscriptionError.bufferOverflow))
            return false
        }
        return true
    }

    private func closeLegacySubscriptions(channelLost: Bool) {
        for transition in legacySubscriptions.transitions.values { transition.timer?.cancel() }
        for send in subscriptionSends.values {
            _ = send.submission.finish(channelLost ? .connectionLost : .closed)
        }
        for lease in legacySubscriptions.leases.values {
            lease.opening?.timer.cancel()
            if let opening = lease.opening {
                let couldHaveSent = opening.delivery == .unknown || lease.awaiting.contains { key in
                    guard case .transitioning(.subscribe, let id) = legacySubscriptions.resources[key]?.registration else { return false }
                    return subscriptionSends[id]?.submission.delivery == .unknown
                }
                let delivery: ClientDelivery = couldHaveSent ? .unknown : .notSent
                opening.continuation.resume(throwing: channelLost
                    ? ClientError.connectionLost(delivery) : ClientError.closedDuringRequest(delivery))
            }
            lease.events.finish(throwing: channelLost ? ClientError.connectionLost(.unknown) : nil)
            lease.retired.finish()
        }
        for release in legacySubscriptions.releases.values { release.retired.finish() }
        legacySubscriptions = ClientLegacySubscriptions()
    }
}
