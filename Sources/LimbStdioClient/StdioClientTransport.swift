#if os(macOS)
package import LimbClient
package import LimbCore

extension Client {
    /// Connect an explicitly selected wire profile to a child process. Profile negotiation
    /// and feature handlers are owned by the client lifecycle, above this transport.
    package static func connectStdio(
        _ configuration: StdioProcessConfiguration,
        profile: RevisionProfile,
        maxFrameBytes: Int = 8 * 1024 * 1024,
        maxPending: Int = 128,
        launchTimeout: Duration = .seconds(5)
    ) async throws -> Client {
        try await connectStdio(
            StdioProcessStartup(configuration), profile: profile,
            maxFrameBytes: maxFrameBytes, maxPending: maxPending, launchTimeout: launchTimeout)
    }

    /// Retain the startup in a lifecycle owner that might wait for cleanup before retrying.
    package static func connectStdio(
        _ startup: StdioProcessStartup,
        profile: RevisionProfile,
        maxFrameBytes: Int = 8 * 1024 * 1024,
        maxPending: Int = 128,
        launchTimeout: Duration = .seconds(5)
    ) async throws -> Client {
        guard maxFrameBytes > 0 else { throw StdioProcessError.invalidConfiguration }
        let process = try await startup.launch(timeout: launchTimeout)
        let transport = StdioClientTransport(
            process: process, startup: startup, profile: profile,
            maxFrameBytes: maxFrameBytes, controlLimit: max(1, maxPending))
        let client = Client(transport: transport, profile: profile, routing: .sharedChannel, maxPending: maxPending)
        await transport.start { [weak client] event in
            await client?.receive(event)
        }
        if Task.isCancelled {
            _ = await transport.beginShutdown()
            throw CancellationError()
        }
        return client
    }
}

actor StdioClientTransport: ClientTransport {
    private enum Phase {
        case queued, writingRequest, sent, writingCancellation

        var usesWriter: Bool { self == .writingRequest || self == .writingCancellation }
    }

    private struct Exchange {
        let request: ClientRequest
        let submission: ClientSubmission
        let completion: CheckedContinuation<Void, Never>
        var phase: Phase = .queued
        var terminalStarted = false
        var terminalDelivered = false
        var cancellationQueued = false
    }

    private enum Control {
        case cancel(RequestID)
        case reply([UInt8])
    }

    private struct BatchPosition {
        let batch: UInt64
        let index: Int
    }

    private struct Incoming {
        let ticket: UInt64
        let position: BatchPosition?
        let task: Task<Void, Never>
        let urlID: String?
    }

    private struct IncomingBatch {
        var replies: [[UInt8]?] = []
        var pending = 0
        var sealed = false
        var bytes = 0
    }

    private let process: StdioProcess
    private let startup: StdioProcessStartup
    private let serverIdentity: String?
    private let executionQuotas: ClientExecutionQuotas?
    private var profile: RevisionProfile
    private var clientIdentity: JSONValue?
    private var bootstrap: StdioBootstrapInbox?
    private let maxFrameBytes: Int
    private let controlLimit: Int
    private var framer: LineFramer
    private var receiver: ClientEventReceiver?
    private var exchanges: [RequestID: Exchange] = [:]
    private var queued: [RequestID] = []
    private var controls: [Control] = []
    private var queuedReplyCount = 0
    private var queuedReplyBytes = 0
    private var bufferedBatchBytes = 0
    private var legacyInput: ClientLegacyInput?
    private var incoming: [RequestID: Incoming] = [:]
    private var incomingBatches: [UInt64: IncomingBatch] = [:]
    private var lastIncomingTicket: UInt64 = 0
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var channelEnded = false

    init(
        process: StdioProcess, startup: StdioProcessStartup, profile: RevisionProfile,
        maxFrameBytes: Int, controlLimit: Int, bootstrap: StdioBootstrapInbox? = nil, serverIdentity: String? = nil,
        executionQuotas: ClientExecutionQuotas? = nil
    ) {
        self.process = process
        self.startup = startup
        self.serverIdentity = serverIdentity
        self.executionQuotas = executionQuotas
        self.profile = profile
        self.maxFrameBytes = maxFrameBytes
        self.controlLimit = controlLimit
        self.framer = LineFramer(maxFrameBytes: maxFrameBytes)
        self.bootstrap = bootstrap
    }

    func start(receive: @escaping ClientEventReceiver) {
        receiver = receive
        startReading()
    }

    func startReading() {
        reader = Task { [weak self, process] in
            while let chunk = try? await process.read() {
                guard let self else { break }
                await self.consume(chunk)
            }
            await self?.endChannel()
        }
    }

    func bootRequest(_ method: String, params: JSONObject, until deadline: ContinuousClock.Instant) async throws -> RequestID {
        let inbox = try checkBootstrap(until: deadline)
        let id = try inbox.issueID()
        let frame = Frame.request(id: id, method: method) { $0.write(params) }
        try await writeBootstrapFrame(frame, until: deadline)
        return id
    }

    @discardableResult
    func writeBootstrapFrame(
        _ frame: [UInt8], watching late: RequestID? = nil, ready: Bool = false,
        until deadline: ContinuousClock.Instant
    ) async throws -> StdioBootstrapWrite {
        let inbox = try checkBootstrap(until: deadline)
        guard frame.count <= maxFrameBytes else { throw StdioNegotiationError.frameTooLarge }
        var line = frame
        line.append(0x0a)
        let allow: (@Sendable () -> Bool)?
        if late != nil || ready { allow = { inbox.permitWrite(watching: late, ready: ready) } }
        else { allow = nil }
        let written: Bool
        do {
            written = try await process.writeGuarded(line, deadline: deadline, sealBootstrap: ready, whileAllowed: allow)
        } catch StdioProcessError.writeInterrupted {
            _ = try checkBootstrap()
            return .partial
        } catch {
            _ = try checkBootstrap(until: deadline)
            throw StdioNegotiationError.connectionLost
        }
        _ = try checkBootstrap()
        return written ? .complete : .withheld
    }

    func takeBootstrapReply(matching id: RequestID, until deadline: ContinuousClock.Instant) throws -> StdioBootstrapReply? {
        try checkBootstrap().take(id, until: deadline)
    }

    func bootstrapReply(
        matching ids: [RequestID], watching late: RequestID? = nil, until deadline: ContinuousClock.Instant
    ) async throws -> StdioBootstrapReply {
        let inbox = try checkBootstrap()
        while true {
            switch try await inbox.next(matching: ids, until: deadline) {
            case .reply(let reply):
                return reply
            case .ping(let ping):
                if try await writeBootstrapPong(ping, watching: late, until: deadline) != .complete {
                    guard let late, let reply = try takeBootstrapReply(matching: late, until: deadline) else {
                        throw StdioNegotiationError.connectionLost
                    }
                    return reply
                }
            }
        }
    }

    func writeBootstrapPong(
        _ ping: StdioBootstrapPing, watching late: RequestID?, until deadline: ContinuousClock.Instant
    ) async throws -> StdioBootstrapWrite {
        try await writeBootstrapFrame(Self.pong(ping), watching: late, until: deadline)
    }

    @discardableResult
    func checkBootstrap(until deadline: ContinuousClock.Instant? = nil) throws -> StdioBootstrapInbox {
        try Task.checkCancellation()
        guard let bootstrap, shutdown == nil else { throw StdioNegotiationError.connectionLost }
        if let failure = bootstrap.failure { throw failure }
        if let deadline, ContinuousClock.now >= deadline { throw StdioNegotiationError.timedOut }
        return bootstrap
    }

    func install(
        _ peer: StdioPeer, options: StdioClientOptions,
        legacyCapabilities: JSONObject? = nil, until deadline: ContinuousClock.Instant
    ) throws -> Client {
        let inbox = try checkBootstrap(until: deadline)
        if peer.profile.hasDiscover { try inbox.validateBatchPolicy(acceptsBatch: false) }
        let identity = peer.profile.hasDiscover ? try stdioIdentity(options.clientInfo, profile: peer.profile) : nil
        try Task.checkCancellation()
        let runningFramer = try process.detachBootstrap(until: deadline)
        profile = peer.profile
        clientIdentity = identity
        if let handlers = options.inputHandlers, let legacyCapabilities, !legacyCapabilities.isEmpty {
            legacyInput = ClientLegacyInput(
                profile: peer.profile, serverIdentity: serverIdentity, serverInfo: peer.info,
                handlers: handlers, capabilities: legacyCapabilities,
                timeout: options.legacyInputTimeout, maxPending: options.maxPending, maxIDBytes: options.maxFrameBytes,
                executionQuotas: executionQuotas)
        }
        let client = Client(
            transport: self, profile: peer.profile, routing: .sharedChannel, maxPending: options.maxPending,
            lastIssuedRequestID: inbox.lastID, serverInfo: peer.info, serverCapabilities: peer.capabilities,
            inputHandlers: options.inputHandlers, serverIdentity: serverIdentity, legacyInput: legacyInput,
            executionQuotas: executionQuotas)
        receiver = { [weak client] event in await client?.receive(event) }
        framer = runningFramer
        bootstrap = nil
        startReading()
        return client
    }

    func send(
        _ request: ClientRequest,
        submission: ClientSubmission,
        receive: @escaping ClientEventReceiver
    ) async {
        guard shutdown == nil else {
            await receive(.sendFailed(request.id, provenNotSent: true))
            return
        }
        await withCheckedContinuation { completion in
            guard submission.observeWithdrawal({ [weak self, id = request.id] _ in
                Task { await self?.withdraw(id) }
            }) else {
                completion.resume()
                return
            }
            exchanges[request.id] = Exchange(request: request, submission: submission, completion: completion)
            queued.append(request.id)
            startWriter()
        }
    }

    func close() async {
        let stopping = beginShutdown()
        await stopping.value
        await reader?.value
        await writer?.value
    }

    func beginShutdown() -> Task<Void, Never> {
        if let shutdown { return shutdown }
        queued.removeAll()
        controls.removeAll()
        queuedReplyCount = 0
        queuedReplyBytes = 0
        legacyInput?.close()
        for request in incoming.values { request.task.cancel() }
        incoming.removeAll()
        incomingBatches.removeAll()
        bufferedBatchBytes = 0
        let stopping = Task { [process, startup] in
            _ = try? await process.close()
            await startup.waitForCleanup()
        }
        shutdown = stopping
        return stopping
    }

    private func startWriter() {
        guard writer == nil else { return }
        writer = Task { [weak self] in await self?.writeQueuedFrames() }
    }

    private func writeQueuedFrames() async {
        defer { writer = nil }
        while shutdown == nil {
            if !controls.isEmpty {
                switch controls.removeFirst() {
                case .cancel(let id): await writeCancellation(id)
                case .reply(let bytes):
                    queuedReplyCount -= 1
                    queuedReplyBytes -= bytes.count
                    if !(await writeControl(bytes)) { _ = beginShutdown() }
                }
            } else if !queued.isEmpty {
                await writeRequest(queued.removeFirst())
            } else {
                return
            }
        }
    }

    private func writeRequest(_ id: RequestID) async {
        guard let exchange = exchanges[id] else { return }
        let params = stdioRequestParams(exchange.request.params, profile: profile, clientIdentity: clientIdentity)
        var bytes = Frame.request(id: id, method: exchange.request.method, params.isEmpty ? nil : { $0.write(params) })
        guard bytes.count <= maxFrameBytes else {
            await receiver?(.requestTooLarge(id, bytes: bytes.count, limit: maxFrameBytes))
            retire(id)
            return
        }
        guard exchange.submission.claim(onCancel: { [weak self] action in
            Task { await self?.cancel(id, action) }
        }) else {
            retire(id)
            return
        }
        exchanges[id]?.phase = .writingRequest
        bytes.append(0x0a)

        do {
            try await process.write(bytes, deadline: exchange.request.deadline)
            exchanges[id]?.phase = .sent
            retireIfFinished(id)
            // Cancellation can win the token before its callback reaches this actor.
            if exchange.submission.isCancellationPending {
                let bootstrap = profile.hasInitialize && exchange.request.method == "initialize"
                cancel(id, bootstrap ? .abortBootstrap : .cancelExchange)
            }
        } catch {
            exchanges[id]?.phase = .sent
            if let error = error as? StdioProcessError {
                switch error {
                case .writeTimedOut(bytesWritten: 0):
                    await deliver(.sendFailed(id, provenNotSent: true), to: id)
                    retireIfFinished(id)
                    return
                case .writeFailed(bytesWritten: 0, errno: _), .writeClosed(bytesWritten: 0):
                    await deliver(.sendFailed(id, provenNotSent: true), to: id)
                default:
                    break
                }
            }
            _ = beginShutdown()
            retireIfFinished(id)
        }
    }

    private func withdraw(_ id: RequestID) {
        guard exchanges[id]?.phase == .queued else { return }
        retire(id)
    }

    private func cancel(_ id: RequestID, _ action: ClientCancellation) {
        guard shutdown == nil else { return }
        if case .abortBootstrap = action {
            // An initialize that may have reached the server leaves this session unusable.
            _ = beginShutdown()
            return
        }
        guard let exchange = exchanges[id], exchange.phase == .sent,
              !exchange.terminalStarted, !exchange.cancellationQueued, exchange.submission.isCancellationPending else { return }
        exchanges[id]?.cancellationQueued = true
        enqueueControl(.cancel(id))
    }

    private func writeCancellation(_ id: RequestID) async {
        guard let exchange = exchanges[id], !exchange.terminalStarted, exchange.submission.isCancellationPending else {
            retireIfFinished(id)
            return
        }
        exchanges[id]?.phase = .writingCancellation
        let bytes = Frame.notification(method: "notifications/cancelled") { writer in
            writer.beginObject()
            writer.field("requestId", id)
            writer.endObject()
        }
        let written = await writeControl(bytes)
        exchanges[id]?.phase = .sent
        if !written { _ = beginShutdown() }
        if exchanges[id]?.terminalStarted == true { retireIfFinished(id) }
        else { retire(id) }
    }

    private func writeControl(_ payload: [UInt8]) async -> Bool {
        guard payload.count <= maxFrameBytes else { return false }
        var line = payload
        line.append(0x0a)
        do {
            try await process.write(line, deadline: .now + .seconds(1))
            return true
        } catch {
            return false
        }
    }

    private func enqueueControl(_ control: Control) {
        guard shutdown == nil else { return }
        switch control {
        case .cancel:
            // Calls, subscription opens and legacy releases reserve their own cancellations.
            let openCapacity = controlLimit + min(controlLimit, Int.max - controlLimit)
            let capacity = profile.legacySubscriptions ? openCapacity + min(controlLimit, Int.max - openCapacity) : openCapacity
            guard controls.count - queuedReplyCount < capacity else {
                _ = beginShutdown()
                return
            }
        case .reply(let bytes):
            guard queuedReplyCount < controlLimit, bytes.count <= maxFrameBytes - queuedReplyBytes - bufferedBatchBytes else {
                _ = beginShutdown()
                return
            }
            queuedReplyCount += 1
            queuedReplyBytes += bytes.count
        }
        controls.append(control)
        startWriter()
    }

    private func consume(_ chunk: [UInt8]) async {
        var offset = 0
        while offset < chunk.count {
            offset += framer.append(chunk[offset...])
            while let frame = framer.next() {
                guard case .frame(let range) = frame else { continue }
                // The strict parser preserves numbers and rejects duplicate keys under either codec.
                do {
                    let value = try JSON.parseStrict(framer.buffer.span.extracting(range))
                    await dispatchFrame(value)
                } catch {
                    if profile.serverInitiatedRequests {
                        enqueueControl(.reply(Frame.error(id: nil, .parseError("invalid JSON frame"))))
                    }
                }
            }
        }
    }

    private func dispatchFrame(_ value: JSONValue) async {
        guard case .array(let values) = value else {
            if let reply = await dispatch(value) { enqueueControl(.reply(reply)) }
            return
        }
        guard profile.acceptsBatch else { return }
        if values.isEmpty {
            enqueueControl(.reply(Frame.error(id: nil, .invalidRequest("empty batch"))))
            return
        }
        // Each sealed batch holds at least one incoming call until it becomes ready to send.
        // The reader collects one additional batch, which may contain only outgoing responses.
        let batch: UInt64?
        if shutdown == nil, let ticket = issueIncomingTicket() {
            incomingBatches[ticket] = IncomingBatch()
            batch = ticket
        } else {
            _ = beginShutdown()
            batch = nil
        }
        for member in values {
            guard let reply = await dispatch(member, batch: batch), let batch,
                  let position = appendBatchPosition(batch, pending: false) else { continue }
            storeBatchReply(reply, at: position)
        }
        if let batch {
            incomingBatches[batch]?.sealed = true
            flushBatch(batch)
        }
    }

    private func dispatch(_ value: JSONValue, batch: UInt64? = nil) async -> [UInt8]? {
        if profile.serverInitiatedRequests, value.objectValue == nil {
            return Frame.error(id: nil, .invalidRequest("expected a JSON-RPC object"))
        }
        do {
            switch try ClientMessage.classify(value) {
            case .response(let id, let outcome):
                await deliver(.response(source: .channel, id: id, result: outcome), to: id)
            case .notification(let method, let params):
                if profile.serverInitiatedRequests, method == "notifications/cancelled" {
                    if let reason = params["reason"], reason.stringValue == nil { return nil }
                    if let id = params["requestId"].flatMap(RequestID.init(json:)) { cancelIncoming(id) }
                    return nil
                }
                if profile.hasSubscriptionsListen, method == "notifications/cancelled",
                   let id = ClientSubscriptionWire.cancellationID(params),
                   exchanges[id]?.request.method == "subscriptions/listen" {
                    await deliver(.notification(source: .channel, method: method, params: params), to: id)
                    return nil
                }
                await receiver?(.notification(source: .channel, method: method, params: params))
            case .request(let id, "ping", _) where profile.hasPing:
                return Self.pong(id)
            case .request(let id, let method, let params) where profile.serverInitiatedRequests:
                return startIncoming(id, method: method, params: params, batch: batch)
            case .request, .uncorrelatedError:
                break
            }
        } catch .malformedResponse(let id) {
            await deliver(.protocolViolation(source: .channel, id: id), to: id)
        } catch .invalidRequestParameters(let id, let method) {
            if profile.serverInitiatedRequests {
                let supported = (method == "ping" && profile.hasPing) || legacyInput?.supports(method) == true
                let error: MCPError = supported
                    ? .invalidParams("expected an object") : unavailableIncomingMethod(method)
                return Frame.error(id: id, error)
            }
        } catch .invalidEnvelope {
            if profile.serverInitiatedRequests, let object = value.objectValue {
                let hasResponse = object["result"] != nil || object["error"] != nil
                let notificationEnvelope = object["jsonrpc"] == "2.0" && object["id"] == nil
                    && object["method"]?.stringValue != nil && !hasResponse
                if (!hasResponse || object["method"] != nil) && !notificationEnvelope {
                    return Frame.error(id: nil, .invalidRequest("invalid JSON-RPC request envelope"))
                }
            }
        } catch {
            // An invalid envelope without a proven correlation must not end a sibling request.
        }
        return nil
    }

    private func issueIncomingTicket() -> UInt64? {
        guard lastIncomingTicket < UInt64.max else { return nil }
        lastIncomingTicket += 1
        return lastIncomingTicket
    }

    private func unavailableIncomingMethod(_ method: String) -> MCPError {
        if profile.elicitationCompletion, method == "elicitation/create" {
            return .invalidParams("elicitation mode was not negotiated")
        }
        return MCPError(code: MCPError.Code.methodNotFound, message: "Method not found")
    }

    private func startIncoming(
        _ id: RequestID, method: String, params: JSONObject, batch: UInt64?
    ) -> [UInt8]? {
        guard shutdown == nil, incoming[id] == nil, legacyInput?.isOpen != false else { return nil }
        guard let input = legacyInput, input.supports(method) else {
            return Frame.error(id: id, unavailableIncomingMethod(method))
        }
        if profile.version == .v2025_11_25, params["task"] != nil {
            return Frame.error(id: id, .invalidParams("task augmentation was not negotiated"))
        }
        guard incoming.count < controlLimit, let ticket = issueIncomingTicket() else {
            return Frame.error(id: id, .overloaded("client input quota is occupied"))
        }
        let deadline = input.deadline
        let url: ElicitRequest?
        do { url = try input.prepareURL(method: method, params: params, request: id) }
        catch { return Frame.error(id: id, error) }
        let position = batch.flatMap { appendBatchPosition($0, pending: true) }
        let maxFrameBytes = self.maxFrameBytes
        let task = Task.detached { [weak self] in
            let result = await input.answer(id: id, method: method, params: params, url: url, until: deadline)
            let frame: [UInt8]?
            var accepted = false
            switch result {
            case .success(let value):
                frame = Frame.result(id: id) { $0.write(value) }
                accepted = value["action"] == "accept"
            case .failure(let error):
                frame = Frame.error(id: id, error)
            case nil:
                frame = nil
            }
            let bytes: [UInt8]?
            if let frame, frame.count > maxFrameBytes {
                bytes = Frame.error(id: id, .responseTooLarge(bytes: frame.count, limit: maxFrameBytes))
                accepted = false
            } else {
                bytes = frame
            }
            await self?.finishIncoming(id, ticket: ticket, bytes: bytes, acceptedURL: accepted)
        }
        incoming[id] = Incoming(ticket: ticket, position: position, task: task, urlID: url?.elicitationID)
        return nil
    }

    private func finishIncoming(_ id: RequestID, ticket: UInt64, bytes: [UInt8]?, acceptedURL: Bool) {
        guard incoming[id]?.ticket == ticket, let request = incoming.removeValue(forKey: id) else { return }
        if let urlID = request.urlID { legacyInput?.finishURL(urlID, request: id, accepted: acceptedURL) }
        guard legacyInput?.isOpen == true else {
            _ = beginShutdown()
            return
        }
        submitIncomingReply(bytes, at: request.position)
    }

    private func cancelIncoming(_ id: RequestID) {
        guard let request = incoming.removeValue(forKey: id) else { return }
        if let urlID = request.urlID { legacyInput?.finishURL(urlID, request: id, accepted: false) }
        request.task.cancel()
        submitIncomingReply(nil, at: request.position)
    }

    private func submitIncomingReply(_ bytes: [UInt8]?, at position: BatchPosition?) {
        if let position {
            if let bytes { storeBatchReply(bytes, at: position) }
            incomingBatches[position.batch]?.pending -= 1
            flushBatch(position.batch)
        } else if let bytes {
            enqueueControl(.reply(bytes))
        }
    }

    private func appendBatchPosition(_ ticket: UInt64, pending: Bool) -> BatchPosition? {
        guard let index = incomingBatches[ticket]?.replies.count else { return nil }
        incomingBatches[ticket]?.replies.append(nil)
        if pending { incomingBatches[ticket]?.pending += 1 }
        return BatchPosition(batch: ticket, index: index)
    }

    private func storeBatchReply(_ bytes: [UInt8], at position: BatchPosition) {
        guard incomingBatches[position.batch] != nil else { return }
        // Reserve a comma for each answer and one extra byte for the array wrapper.
        let cost = bytes.count + 1
        guard cost <= maxFrameBytes - queuedReplyBytes - bufferedBatchBytes - 1 else {
            _ = beginShutdown()
            return
        }
        bufferedBatchBytes += cost
        incomingBatches[position.batch]?.bytes += cost
        incomingBatches[position.batch]?.replies[position.index] = bytes
    }

    private func flushBatch(_ ticket: UInt64) {
        guard incomingBatches[ticket]?.sealed == true, incomingBatches[ticket]?.pending == 0,
              let batch = incomingBatches.removeValue(forKey: ticket) else { return }
        bufferedBatchBytes -= batch.bytes
        guard batch.bytes > 0 else { return }
        var frame: [UInt8] = [0x5b]
        frame.reserveCapacity(batch.bytes + 1)
        for reply in batch.replies {
            guard let reply else { continue }
            if frame.count > 1 { frame.append(0x2c) }
            frame.append(contentsOf: reply)
        }
        frame.append(0x5d)
        enqueueControl(.reply(frame))
    }

    private static func pong(_ ping: StdioBootstrapPing) -> [UInt8] {
        switch ping {
        case .request(let id):
            return pong(id)
        case .batch(let ids):
            var bytes: [UInt8] = [0x5b]
            for id in ids {
                if bytes.count > 1 { bytes.append(0x2c) }
                bytes.append(contentsOf: pong(id))
            }
            bytes.append(0x5d)
            return bytes
        }
    }

    private static func pong(_ id: RequestID) -> [UInt8] {
        Frame.result(id: id) { writer in
            writer.beginObject()
            writer.endObject()
        }
    }

    private func deliver(_ event: ClientTransportEvent, to id: RequestID) async {
        guard !channelEnded, let exchange = exchanges[id], exchange.phase != .queued, !exchange.terminalStarted else { return }
        exchanges[id]?.terminalStarted = true
        await receiver?(event)
        exchanges[id]?.terminalDelivered = true
        retireIfFinished(id)
    }

    private func endChannel() async {
        guard !channelEnded else { return }
        channelEnded = true
        _ = beginShutdown()
        await receiver?(.channelEnded)
        // The channel terminal has reached the client before any send can fall back to exchangeLost.
        for id in Array(exchanges.keys) {
            exchanges[id]?.terminalDelivered = true
            retireIfFinished(id)
        }
    }

    private func retireIfFinished(_ id: RequestID) {
        guard let exchange = exchanges[id], exchange.terminalDelivered, !exchange.phase.usesWriter else { return }
        retire(id)
    }

    private func retire(_ id: RequestID) {
        guard let exchange = exchanges.removeValue(forKey: id) else { return }
        if exchange.phase == .queued { queued.removeAll { $0 == id } }
        if exchange.cancellationQueued {
            controls.removeAll {
                if case .cancel(let queuedID) = $0 { return queuedID == id }
                return false
            }
        }
        exchange.completion.resume()
    }

    deinit { reader?.cancel() }
}
#endif
