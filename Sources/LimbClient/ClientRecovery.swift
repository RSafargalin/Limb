import LimbCore
import Synchronization

/// A logical stdio client. Each physical client owns all of the exchanges of one process.
actor ClientRecovery {
    struct Peer: Sendable {
        let info: Implementation?
        let capabilities: JSONObject?

        init(_ session: Client) {
            info = session.serverInfo
            capabilities = session.serverCapabilities
        }
    }

    private struct Lease {
        let requested: ClientSubscriptionFilter
        let timeout: Duration
        let bufferSize: Int
        let events: ClientSubscription.Stream.Continuation
        let retired: AsyncStream<Void>.Continuation
        var wire: ClientSubscription?
        var forwarding: Task<Void, Never>?
        var reopening: Task<Void, Never>?
    }

    private let connect: @Sendable (Int) async throws -> Client
    private let backoff: Duration
    private let limit: Int
    private let revision: ProtocolVersion
    private nonisolated let peerSnapshot: Mutex<Peer>
    nonisolated var peer: Peer { peerSnapshot.withLock { $0 } }
    private var ready: Client?
    private var departing: Client?
    private var replacement: Client?
    private var observer: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var leases: [UInt64: Lease] = [:]
    private var retiring: [UInt64: Task<Void, Never>] = [:]
    private var disconnectedWork: [ClientWorkPool] = []
    private var opening = 0
    private var openingWaiter: CheckedContinuation<Void, Never>?
    private var lastLeaseID: UInt64 = 0

    init(session: Client, limit: Int, backoff: Duration, reconnect: @escaping @Sendable (Int) async throws -> Client) {
        ready = session
        peerSnapshot = Mutex(Peer(session))
        revision = session.protocolVersion
        self.limit = limit
        self.backoff = backoff
        connect = reconnect
    }

    func start() throws(CancellationError) {
        // This is the handoff from the cancellable factory to the logical client's lifetime.
        guard !Task.isCancelled else { throw CancellationError() }
        if let ready { observe(ready) }
    }

    func session() async throws(ClientError) -> Client {
        guard shutdown == nil else { throw .closed }
        if let client = ready {
            if await client.lostChannel { lost(client) }
            if ready === client { return client }
        }
        guard shutdown == nil else { throw .closed }
        if let ready { return ready }
        throw departing == nil ? .connectionLost(.notSent) : .recovering
    }

    func subscribe(
        filter: ClientSubscriptionFilter, timeout: Duration, bufferSize: Int, owner: Client
    ) async throws -> ClientSubscription {
        let client = try await session()
        guard ready === client else { throw shutdown == nil ? ClientError.recovering : ClientError.closed }
        guard leases.count + retiring.count + opening < limit, lastLeaseID < UInt64.max else { throw ClientError.overloaded }
        lastLeaseID += 1
        let id = lastLeaseID
        opening += 1
        defer {
            opening -= 1
            if opening == 0 {
                openingWaiter?.resume()
                openingWaiter = nil
            }
        }
        let wire = try await client.subscribe(filter: filter, timeout: timeout, bufferSize: bufferSize)
        guard shutdown == nil, !Task.isCancelled, ready === client || departing === client || replacement === client else {
            await wire.cancel()
            if Task.isCancelled { throw ClientError.cancelled(.unknown) }
            throw shutdown == nil ? ClientError.connectionLost(.unknown) : ClientError.closedDuringRequest(.unknown)
        }
        let (stream, events) = ClientSubscription.Stream.makeStream(bufferingPolicy: .bufferingOldest(bufferSize))
        events.onTermination = { [weak self] termination in
            if case .cancelled = termination { Task { await self?.cancel(id) } }
        }
        let (release, retired) = AsyncStream<Void>.makeStream()
        let retirement = Task { for await _ in release {} }
        leases[id] = Lease(requested: filter, timeout: timeout, bufferSize: bufferSize, events: events, retired: retired)
        bind(id, to: wire, on: client)
        return ClientSubscription(confirmedFilter: wire.confirmedFilter, stream: stream, retirement: retirement) { [self, owner] in
            await cancel(id)
            // A retained subscription can outlive the caller's reference to the client.
            withExtendedLifetime(owner) {}
        }
    }

    private func bind(_ id: UInt64, to wire: ClientSubscription, on client: Client) {
        leases[id]?.wire = wire
        leases[id]?.forwarding = Task { [weak self] in
            do {
                for try await event in wire {
                    guard await self?.forward(event, id: id, wire: wire) == true else { return }
                }
                await self?.bindingEnded(id, wire: wire, client: client, error: nil)
            } catch {
                await self?.bindingEnded(id, wire: wire, client: client, error: error)
            }
        }
    }

    private func forward(_ event: ClientSubscriptionEvent, id: UInt64, wire: ClientSubscription) -> Bool {
        guard leases[id]?.wire === wire else { return false }
        return emit(event, id: id)
    }

    private func emit(_ event: ClientSubscriptionEvent, id: UInt64) -> Bool {
        guard let events = leases[id]?.events else { return false }
        switch events.yield(event) {
        case .enqueued: return true
        case .dropped: finish(id, error: ClientSubscriptionError.bufferOverflow)
        case .terminated: finish(id, error: nil)
        @unknown default: finish(id, error: ClientSubscriptionError.bufferOverflow)
        }
        return false
    }

    private func bindingEnded(_ id: UInt64, wire: ClientSubscription, client: Client, error: (any Error)?) {
        guard leases[id]?.wire === wire else { return }
        if case .connectionLost = error as? ClientError, ready === client || departing === client {
            lost(client)
            if departing === client {
                leases[id]?.wire = nil
                leases[id]?.forwarding = nil
                _ = emit(.interrupted, id: id)
                return
            }
        }
        finish(id, error: error)
    }

    private func observe(_ client: Client) {
        observer = Task { [weak self, weak client] in
            guard let disconnects = await client?.disconnects() else { return }
            for await _ in disconnects {
                guard let client else { return }
                await self?.lost(client)
            }
        }
    }

    private func lost(_ client: Client) {
        guard shutdown == nil, ready === client else { return }
        ready = nil
        disconnectedWork.removeAll { !$0.hasActiveReservations }
        if client.work.hasActiveReservations { disconnectedWork.append(client.work) }
        // A process lost during restoration is the failure of the existing attempt.
        if replacement === client { return }
        departing = client
        recovery = Task { [weak self] in await self?.recover(client) }
    }

    private func waitForSubscriptionOpenings() async {
        guard opening > 0 else { return }
        await withCheckedContinuation { openingWaiter = $0 }
    }

    private func recover(_ old: Client) async {
        await old.waitForDisconnectedCleanup()
        // Public subscribe may still be handing off a wire handle accepted before EOF.
        await waitForSubscriptionOpenings()
        for stream in leases.values.compactMap(\.forwarding) { await stream.value }
        do {
            try Task.checkCancellation()
            try await Task.sleep(for: backoff)
            let client = try await connect(await old.requestIDFloor)
            if Task.isCancelled || shutdown != nil {
                await client.close()
                return
            }
            guard client.protocolVersion == revision else {
                await client.close()
                throw ClientSubscriptionError.incompatibleRevision(expected: revision, actual: client.protocolVersion)
            }
            replacement = client
            peerSnapshot.withLock { $0 = Peer(client) }
            ready = client
            observe(client)
            // A slow confirmation must not delay traffic on the negotiated session or
            // stop another subscription from resuming as soon as its own filter is accepted.
            var jobs: [Task<Void, Never>] = []
            for id in leases.keys.sorted() {
                guard let lease = leases[id], lease.wire == nil else { continue }
                let job = Task { [weak self, filter = lease.requested, timeout = lease.timeout, size = lease.bufferSize] in
                    do {
                        let wire = try await client.subscribe(filter: filter, timeout: timeout, bufferSize: size)
                        guard let self else { await wire.cancel(); return }
                        await self.rebound(id, wire: wire, on: client)
                    } catch {
                        await self?.finish(id, error: error)
                    }
                }
                leases[id]?.reopening = job
                jobs.append(job)
            }
            for job in jobs { await job.value }
            guard !Task.isCancelled, shutdown == nil else { return }
            if await client.lostChannel {
                lost(client)
                throw ClientError.connectionLost(.unknown)
            }
            if ready !== client {
                throw ClientError.connectionLost(.unknown)
            }
        } catch {
            ready = nil
            if let replacement {
                if await replacement.lostChannel { await replacement.waitForDisconnectedCleanup() }
                else { await replacement.close() }
                await waitForSubscriptionOpenings()
                for stream in leases.values.compactMap(\.forwarding) { await stream.value }
            }
            if shutdown == nil {
                for id in leases.keys { finish(id, error: error) }
            }
        }
        replacement = nil
        departing = nil
        recovery = nil
    }

    private func rebound(_ id: UInt64, wire: ClientSubscription, on client: Client) async {
        // A parsed acknowledgment can precede EOF even when this task resumes after it.
        // Drain that accepted stream from the tracked process before failing the attempt.
        guard shutdown == nil, replacement === client, !Task.isCancelled, leases[id] != nil else {
            await wire.cancel()
            return
        }
        leases[id]?.reopening = nil
        leases[id]?.wire = wire
        if emit(.resubscribed(confirmedFilter: wire.confirmedFilter), id: id) { bind(id, to: wire, on: client) }
    }

    private func cancel(_ id: UInt64) async {
        finish(id, error: nil)
        await retiring[id]?.value
    }

    private func finish(_ id: UInt64, error: (any Error)?) {
        guard let lease = leases.removeValue(forKey: id) else { return }
        lease.events.finish(throwing: error)
        lease.forwarding?.cancel()
        lease.reopening?.cancel()
        retiring[id] = Task { [weak self] in
            await lease.wire?.cancel()
            await lease.forwarding?.value
            await lease.reopening?.value
            await self?.release(id)
            lease.retired.finish()
        }
    }

    private func release(_ id: UInt64) { retiring.removeValue(forKey: id) }

    func close() async {
        if let shutdown { await shutdown.value; return }
        let sessions = [ready ?? replacement, departing].compactMap { $0 }
        ready = nil
        for work in disconnectedWork { work.close() }
        disconnectedWork.removeAll()
        observer?.cancel()
        recovery?.cancel()
        for id in leases.keys { finish(id, error: nil) }
        let pending = Array(retiring.values)
        let recovery = self.recovery
        let shutdown = Task {
            await withTaskGroup(of: Void.self) { group in
                for session in sessions { group.addTask { await session.close() } }
            }
            await recovery?.value
            for retirement in pending { await retirement.value }
        }
        self.shutdown = shutdown
        await shutdown.value
        departing = nil
        replacement = nil
        self.recovery = nil
        observer = nil
    }
}
