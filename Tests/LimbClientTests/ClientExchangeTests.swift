import Dispatch
@testable import LimbClient
import LimbCore
import Synchronization
import Testing

private final class ExchangeProbe: Sendable {
    let request: ClientRequest
    let submission: ClientSubmission
    let receive: ClientEventReceiver
    private let cancellations = Mutex<[String]>([])

    init(
        request: ClientRequest, submission: ClientSubmission,
        receive: @escaping ClientEventReceiver
    ) {
        self.request = request
        self.submission = submission
        self.receive = receive
    }

    var id: RequestID { request.id }

    func claim(onCancellation: @escaping @Sendable () -> Void = {}) -> Bool {
        submission.claim { [weak self] policy in
            self?.cancellations.withLock { actions in
                switch policy {
                case .cancelExchange: actions.append("cancelExchange")
                case .abortBootstrap: actions.append("abortBootstrap")
                }
            }
            onCancellation()
        }
    }

    var cancellationActions: [String] {
        cancellations.withLock { $0 }
    }

    func respond(
        _ value: JSONValue, from source: ClientResponseSource, id responseID: RequestID? = nil
    ) async {
        await receive(.response(source: source, id: responseID ?? id, result: .success(value)))
    }
}

private actor ExchangeTransport: ClientTransport {
    private let holdSendsOnClose: Bool
    private var isDraining = false
    private var sendWaiters: [RequestID: CheckedContinuation<Void, Never>] = [:]
    private var calls: [RequestID: ExchangeProbe] = [:]
    private var callIDs: [String: [RequestID]] = [:]
    private(set) var closeCount = 0
    private(set) var finishedSendCount = 0
    var receivedSendCount: Int { calls.count }

    init(holdSendsOnClose: Bool = false) {
        self.holdSendsOnClose = holdSendsOnClose
    }

    func send(
        _ request: ClientRequest, submission: ClientSubmission,
        receive: @escaping ClientEventReceiver
    ) async {
        calls[request.id] = ExchangeProbe(request: request, submission: submission, receive: receive)
        callIDs[request.method, default: []].append(request.id)
        if !isDraining {
            await withCheckedContinuation { sendWaiters[request.id] = $0 }
        }
        finishedSendCount += 1
    }

    func close() async {
        closeCount += 1
        if !holdSendsOnClose { releaseSends() }
    }

    // Each script releases its transport record after delivering the terminal event.
    func retire(_ call: ExchangeProbe) {
        sendWaiters.removeValue(forKey: call.id)?.resume()
    }

    func releaseSends() {
        isDraining = true
        for waiter in sendWaiters.values { waiter.resume() }
        sendWaiters.removeAll()
    }

    func call(_ method: String, occurrence: Int = 1) async throws -> ExchangeProbe {
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(5)
        while (callIDs[method]?.count ?? 0) < occurrence, clock.now < limit {
            try await clock.sleep(for: .milliseconds(1))
        }
        let id = try #require(
            callIDs[method]?.dropFirst(occurrence - 1).first,
            "Transport did not receive occurrence \(occurrence) of \(method)")
        return try #require(calls[id])
    }

    func waitForClose() async throws {
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(5)
        while closeCount == 0, clock.now < limit {
            try await clock.sleep(for: .milliseconds(1))
        }
        try #require(closeCount == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ClientExchangeTests {
    @Test(arguments: [false, true])
    func cancelledRegistrationRespectsAbsoluteDeadline(expired: Bool) async {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)

        func register(
            on client: isolated Client, deadline: ContinuousClock.Instant
        ) async throws -> JSONValue {
            let request = ClientRequest(
                id: "registration", method: "tools/call", params: [:], profile: .r2026_07_28,
                deadline: deadline)
            let submission = ClientSubmission(cancellation: .cancelExchange, deadline: deadline)
            return try await withCheckedThrowingContinuation { continuation in
                client.register(request, submission: submission, continuation: continuation)
            }
        }

        let request = Task {
            let deadline = ContinuousClock.now + .seconds(expired ? -60 : 60)
            withUnsafeCurrentTask { $0?.cancel() }
            try #require(Task.isCancelled)
            return try await register(on: client, deadline: deadline)
        }
        let expected: ClientError = expired ? .timedOut(.notSent) : .cancelled(.notSent)
        await #expect(throws: expected) { try await request.value }
        await client.close()
        #expect(await transport.receivedSendCount == 0)
    }

    @Test func requestIDExhaustionAutomaticallyClosesTransport() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(
            transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges,
            lastIssuedRequestID: Int.max - 1)
        let last = Task { try await client.request("last ID", timeout: .seconds(5)) }
        let call = try await transport.call("last ID")
        try #require(call.claim())

        await #expect(throws: ClientError.requestIDsExhausted) {
            try await client.request("exhausts IDs", timeout: .seconds(5))
        }
        try await transport.waitForClose()
        await #expect(throws: ClientError.closedDuringRequest(.unknown)) { try await last.value }
        await #expect(throws: ClientError.closed) {
            try await client.request("after exhaustion", timeout: .seconds(5))
        }
        #expect(await transport.closeCount == 1)

        await client.close()
        #expect(await transport.closeCount == 1)
    }

    @Test func claimChecksExpiredDeadlineWithoutTimer() {
        let submission = ClientSubmission(
            cancellation: .cancelExchange, deadline: ContinuousClock.now - .seconds(1))
        #expect(!submission.claim { _ in Issue.record("Expired submission invoked the cancellation hook") })
    }

    @Test func responseAfterAbsoluteDeadlineTimesOutWithoutTimer() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        let submission = ClientSubmission(cancellation: .cancelExchange, deadline: deadline)
        let claimed = submission.claim { _ in
            Issue.record("A response after the deadline invoked the cancellation hook")
        }
        try #require(claimed)
        try await clock.sleep(until: deadline)

        guard case .failure(let error)? = submission.finish(.response) else {
            Issue.record("A response after the deadline should produce a timeout failure")
            return
        }
        #expect(error == .timedOut(.unknown))
    }

    @Test(arguments: [false, true])
    func sendReturnWithoutTerminalEventUsesClaimState(claimed: Bool) async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        let request = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        let call = try await transport.call("tools/call")
        if claimed { try #require(call.claim()) }

        await transport.retire(call)
        let expected = ClientError.exchangeLost(claimed ? .unknown : .notSent)
        await #expect(throws: expected) { try await request.value }
        #expect(!call.claim())
        await call.respond("late response", from: .exchange(call.id))
        await call.receive(.exchangeEnded(call.id))
        guard case .failure(let error)? = call.submission.finish(.response) else {
            Issue.record("Late response changed the outcome selected when send returned")
            return
        }
        #expect(error == expected)
        #expect(call.cancellationActions.isEmpty)
    }

    @Test func channelEndClearsPendingCancellationDuringExplicitClose() async throws {
        let transport = ExchangeTransport(holdSendsOnClose: true)
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .sharedChannel)
        let request = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        let call = try await transport.call("tools/call")
        try #require(call.claim())

        let close = Task { await client.close() }
        try await transport.waitForClose()
        try #require(call.submission.isCancellationPending)
        await call.receive(.channelEnded)
        #expect(!call.submission.isCancellationPending)
        await #expect(throws: ClientError.closedDuringRequest(.unknown)) { try await request.value }

        await transport.releaseSends()
        await close.value
        #expect(await transport.finishedSendCount == 1)
    }

    private enum TerminalEvent: CaseIterable, Sendable {
        case exchangeEnded, sendFailed, channelEnded
    }

    @Test(arguments: TerminalEvent.allCases)
    private func cancellationWinsOverTerminalEventsDeliveredByItsHook(event: TerminalEvent) async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        let request = Task { try await client.request("tools/call", timeout: .seconds(10)) }
        let call = try await transport.call("tools/call")
        let acceptedDuringCancellation = Mutex(false)
        let claimed = call.claim { [weak call] in
            guard let call, call.submission.isCancellationPending else { return }
            let eventAccepted = DispatchSemaphore(value: 0)
            Task.detached {
                switch event {
                case .exchangeEnded: await call.receive(.exchangeEnded(call.id))
                case .sendFailed: await call.receive(.sendFailed(call.id))
                case .channelEnded: await call.receive(.channelEnded)
                }
            }
            Task.detached {
                let clock = ContinuousClock()
                let deadline = clock.now + .seconds(2)
                while call.submission.isCancellationPending, clock.now < deadline {
                    do {
                        try await clock.sleep(for: .milliseconds(1))
                    } catch {
                        Issue.record("The cancellation observer stopped waiting: \(error)")
                        return
                    }
                }
                if !call.submission.isCancellationPending { eventAccepted.signal() }
            }
            let accepted = eventAccepted.wait(timeout: .now() + .seconds(3)) == .success
            acceptedDuringCancellation.withLock { $0 = accepted }
        }
        try #require(claimed)

        await withCheckedContinuation { (cancelled: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                request.cancel()
                cancelled.resume()
            }
        }

        try #require(acceptedDuringCancellation.withLock { $0 })
        await #expect(throws: ClientError.cancelled(.unknown)) { try await request.value }
        await transport.retire(call)
        #expect(call.cancellationActions == ["cancelExchange"])
    }

    @Test func provenSendFailureAfterClaimReportsNotSentAndLeavesSiblingPending() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        let first = Task { try await client.request("tools/list", timeout: .seconds(5)) }
        let second = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        let failed = try await transport.call("tools/list")
        let sibling = try await transport.call("tools/call")
        #expect(failed.claim())
        #expect(sibling.claim())

        await failed.receive(.sendFailed(failed.id, provenNotSent: true))
        await transport.retire(failed)
        await #expect(throws: ClientError.exchangeLost(.notSent)) { try await first.value }
        await sibling.respond("sibling answer", from: .exchange(sibling.id))
        await transport.retire(sibling)
        #expect(try await second.value == "sibling answer")
    }

    @Test func lateProofOfNoPublicationAllowsRetryingACancelledLegacySubscribe() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(
            transport: transport, profile: .r2025_11_25, routing: .sharedChannel, maxPending: 2,
            serverCapabilities: ["resources": ["subscribe": true]]
        )
        let filter = ClientSubscriptionFilter(resourceSubscriptions: ["file:///watched"])
        let opening = Task { try await client.subscribe(filter: filter, timeout: .seconds(5)) }
        defer { opening.cancel() }
        let first = try await transport.call("resources/subscribe")
        try #require(first.claim())
        opening.cancel()
        await #expect(throws: ClientError.cancelled(.unknown)) { try await opening.value }
        await first.receive(.sendFailed(first.id, provenNotSent: true))
        await transport.retire(first)

        let retry = Task { try await client.subscribe(filter: filter, timeout: .seconds(4)) }
        defer { retry.cancel() }
        let second: ExchangeProbe
        do {
            second = try await transport.call("resources/subscribe", occurrence: 2)
        } catch {
            _ = try await retry.value
            throw error
        }
        try #require(second.claim())
        await second.respond([:], from: .channel)
        await transport.retire(second)
        let subscription = try await retry.value
        #expect(subscription.confirmedFilter == filter)

        let release = Task { await subscription.cancel() }
        defer { release.cancel() }
        let unsubscribe = try await transport.call("resources/unsubscribe")
        try #require(unsubscribe.claim())
        await unsubscribe.respond([:], from: .channel)
        await transport.retire(unsubscribe)
        await release.value
        await client.close()
    }

    @Test(arguments: [false, true])
    func scopedFailureRequiresClaimAndLeavesSiblingPending(http: Bool) async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        let first = Task { try await client.request("tools/list", timeout: .seconds(5)) }
        let second = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        let failed = try await transport.call("tools/list")
        let sibling = try await transport.call("tools/call")
        try #require(sibling.claim())
        if http {
            await failed.receive(.httpRejected(exchange: failed.id, status: 429))
        } else {
            await failed.receive(.protocolViolation(source: .exchange(failed.id), id: failed.id))
        }
        try #require(failed.claim())
        await sibling.receive(.protocolViolation(source: .exchange(failed.id), id: sibling.id))
        await sibling.receive(.protocolViolation(source: .channel, id: sibling.id))

        if http {
            await failed.receive(.httpRejected(exchange: failed.id, status: 503))
            await #expect(throws: ClientError.httpRejected(status: 503, delivery: .unknown)) {
                try await first.value
            }
        } else {
            await failed.receive(.protocolViolation(source: .exchange(failed.id), id: failed.id))
            await #expect(throws: ClientError.protocolViolation(.unknown)) { try await first.value }
        }
        await transport.retire(failed)

        await sibling.respond("sibling answer", from: .exchange(sibling.id))
        await transport.retire(sibling)
        #expect(try await second.value == "sibling answer")
    }

    @Test func concurrentCallsToTheSameMethodReceiveTheirOwnResponses() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        let first = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        let a = try await transport.call("tools/call")
        let second = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        let b = try await transport.call("tools/call", occurrence: 2)
        #expect(a.id != b.id)
        try #require(a.claim())
        try #require(b.claim())

        await b.respond("second answer", from: .exchange(b.id))
        await transport.retire(b)
        #expect(try await second.value == "second answer")
        await a.respond("first answer", from: .exchange(a.id))
        await transport.retire(a)
        #expect(try await first.value == "first answer")
    }

    @Test func sharedChannelUsesWireIDAndEndsEveryPendingRequest() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .sharedChannel)
        let first = Task { try await client.request("first", params: ["argument": 1], timeout: .seconds(5)) }
        let second = Task { try await client.request("second", timeout: .seconds(5)) }
        let third = Task { try await client.request("third", timeout: .seconds(5)) }
        let a = try await transport.call("first")
        let b = try await transport.call("second")
        let c = try await transport.call("third")

        #expect(Set([a.id, b.id, c.id]).count == 3)
        #expect(a.request.params == ["argument": 1])
        #expect(a.claim())
        #expect(b.claim())
        await a.respond("wrong source", from: .exchange(a.id))
        await b.respond("unknown ID", from: .channel, id: "unknown")
        await b.respond("first answer", from: .channel, id: a.id)
        await transport.retire(a)
        #expect(try await first.value == "first answer")

        await b.receive(.channelEnded)
        await transport.retire(b)
        await transport.retire(c)
        await #expect(throws: ClientError.connectionLost(.unknown)) { try await second.value }
        await #expect(throws: ClientError.connectionLost(.notSent)) { try await third.value }
        #expect(!c.claim())
        #expect(b.cancellationActions.isEmpty)
        await #expect(throws: ClientError.closed) {
            try await client.request("after EOF", timeout: .seconds(5))
        }
    }

    @Test func isolatedExchangeRequiresBothTheSourceAndWireID() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        let first = Task { try await client.request("first", timeout: .seconds(5)) }
        let second = Task { try await client.request("second", timeout: .seconds(5)) }
        let a = try await transport.call("first")
        let b = try await transport.call("second")
        #expect(a.claim())
        #expect(b.claim())

        await a.respond("foreign reply", from: .exchange(a.id), id: b.id)
        await b.respond("unscoped reply", from: .channel)
        await b.respond("resumed reply", from: .resumedExchange(b.id))
        await a.receive(.exchangeEnded(a.id))
        await #expect(throws: ClientError.exchangeLost(.unknown)) { try await first.value }
        #expect(a.cancellationActions.isEmpty)
        await a.respond("late reply", from: .exchange(a.id))
        await transport.retire(a)

        await b.respond("second answer", from: .exchange(b.id))
        await b.receive(.exchangeEnded(b.id))
        await transport.retire(b)
        #expect(try await second.value == "second answer")
    }

    @Test func legacyResponseCanResumeAndUncorrelatedErrorTargetsItsOwnExchange() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2025_11_25, routing: .legacySession)
        let first = Task { try await client.request("first", timeout: .seconds(5)) }
        let second = Task { try await client.request("second", timeout: .seconds(5)) }
        let a = try await transport.call("first")
        let b = try await transport.call("second")
        #expect(a.claim())
        #expect(b.claim())

        let failure = MCPError(code: -32042, message: "request rejected", data: ["reason": "test"])
        await a.respond("unscoped reply", from: .channel)
        await a.respond("foreign resumed reply", from: .resumedExchange(a.id), id: b.id)
        await b.receive(.uncorrelatedError(exchange: b.id, error: failure))
        await transport.retire(b)
        await a.respond("resumed answer", from: .resumedExchange(a.id))
        await transport.retire(a)
        await #expect(throws: failure) { try await second.value }
        #expect(try await first.value == "resumed answer")
    }

    @Test(arguments: [
        ClientRouting.sharedChannel, .isolatedExchanges, .legacySession,
    ])
    func sendFailureUsesClaimStateAndLeavesSiblingPending(routing: ClientRouting) async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let profile: RevisionProfile = switch routing {
        case .sharedChannel, .isolatedExchanges: .r2026_07_28
        case .legacySession: .r2025_11_25
        }
        let client = Client(transport: transport, profile: profile, routing: routing)
        let unclaimed = Task { try await client.request("unclaimed", timeout: .seconds(5)) }
        let claimed = Task { try await client.request("claimed", timeout: .seconds(5)) }
        let sibling = Task { try await client.request("sibling", timeout: .seconds(5)) }
        let a = try await transport.call("unclaimed")
        let b = try await transport.call("claimed")
        let c = try await transport.call("sibling")
        #expect(b.claim())
        #expect(c.claim())

        await a.receive(.sendFailed(a.id))
        await #expect(throws: ClientError.exchangeLost(.notSent)) { try await unclaimed.value }
        await transport.retire(a)
        #expect(!a.claim())
        #expect(a.cancellationActions.isEmpty)

        await b.receive(.sendFailed(b.id))
        await #expect(throws: ClientError.exchangeLost(.unknown)) { try await claimed.value }
        await transport.retire(b)

        let source: ClientResponseSource
        switch routing {
        case .sharedChannel: source = .channel
        case .isolatedExchanges, .legacySession: source = .exchange(c.id)
        }
        await c.respond("sibling answer", from: source)
        await transport.retire(c)
        #expect(try await sibling.value == "sibling answer")
        #expect(c.cancellationActions.isEmpty)
    }

    @Test func cancellationBeforeClaimWithdrawsSubmissionAndFreesCapacity() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(
            transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges, maxPending: 1)
        let first = Task { try await client.request("first", timeout: .seconds(5)) }
        let a = try await transport.call("first")

        await a.respond("reply before claim", from: .exchange(a.id))
        await #expect(throws: ClientError.overloaded) {
            try await client.request("overloaded", timeout: .seconds(5))
        }
        first.cancel()
        let claimedAfterCancellation = a.claim()
        #expect(!claimedAfterCancellation)
        await #expect(throws: ClientError.cancelled(.notSent)) { try await first.value }
        #expect(a.cancellationActions.isEmpty)
        await transport.retire(a)

        let second = Task {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while true {
                do {
                    return try await client.request("second", timeout: .seconds(5))
                } catch ClientError.overloaded where clock.now < deadline {
                    try await clock.sleep(for: .milliseconds(1))
                }
            }
        }
        let b = try await transport.call("second")
        #expect(a.id != b.id)
        #expect(b.claim())
        await a.respond("late reply", from: .exchange(a.id))
        await b.respond("second answer", from: .exchange(b.id))
        await transport.retire(b)
        #expect(try await second.value == "second answer")
    }

    @Test(arguments: ["tools/list", "initialize"])
    func cancellationAfterClaimUsesMethodSpecificActionOnce(method: String) async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2025_11_25, routing: .legacySession)
        let request = Task { try await client.request(method, timeout: .seconds(5)) }
        let call = try await transport.call(method)
        #expect(call.claim())
        request.cancel()
        request.cancel()

        await #expect(throws: ClientError.cancelled(.unknown)) { try await request.value }
        await call.respond("late reply", from: .exchange(call.id))
        await call.receive(.exchangeEnded(call.id))
        await transport.retire(call)
        await client.close()
        #expect(call.cancellationActions == [method == "initialize" ? "abortBootstrap" : "cancelExchange"])
    }

    @Test func deadlineTerminatesOnlyTheExpiredExchange() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        await #expect(throws: ClientError.timedOut(.notSent)) {
            try await client.request("already expired", timeout: .zero)
        }

        let long = Task { try await client.request("long", timeout: .seconds(5)) }
        let b = try await transport.call("long")
        #expect(b.claim())
        let short = Task { try await client.request("short", timeout: .seconds(1)) }
        let queued = Task { try await client.request("queued", timeout: .seconds(1)) }
        let a = try await transport.call("short")
        let queuedCall = try await transport.call("queued")
        #expect(a.claim())

        await #expect(throws: ClientError.timedOut(.unknown)) { try await short.value }
        await #expect(throws: ClientError.timedOut(.notSent)) { try await queued.value }
        #expect(!queuedCall.claim())
        #expect(queuedCall.cancellationActions.isEmpty)
        await transport.retire(queuedCall)
        #expect(a.cancellationActions == ["cancelExchange"])
        await a.respond("late answer", from: .exchange(a.id))
        await transport.retire(a)
        await b.respond("long answer", from: .exchange(b.id))
        await transport.retire(b)
        #expect(try await long.value == "long answer")
    }

    @Test func closeIsIdempotentAndRejectsNewRequests() async throws {
        let transport = ExchangeTransport()
        defer { Task { await transport.releaseSends() } }
        let client = Client(transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges)
        let pending = Task { try await client.request("pending", timeout: .seconds(5)) }
        let queued = Task { try await client.request("queued", timeout: .seconds(5)) }
        let call = try await transport.call("pending")
        let queuedCall = try await transport.call("queued")
        #expect(call.claim())

        async let first: Void = client.close()
        async let second: Void = client.close()
        _ = await (first, second)
        await client.close()

        await #expect(throws: ClientError.closedDuringRequest(.unknown)) { try await pending.value }
        await #expect(throws: ClientError.closedDuringRequest(.notSent)) { try await queued.value }
        #expect(!queuedCall.claim())
        #expect(queuedCall.cancellationActions.isEmpty)
        #expect(call.cancellationActions == ["cancelExchange"])
        #expect(await transport.closeCount == 1)
        await #expect(throws: ClientError.closed) {
            try await client.request("after close", timeout: .seconds(5))
        }
    }

    @Test func cancelledSendOccupiesCapacityAndCloseWaitsForTransportToReleaseIt() async throws {
        let transport = ExchangeTransport(holdSendsOnClose: true)
        defer { Task { await transport.releaseSends() } }
        let client = Client(
            transport: transport, profile: .r2026_07_28, routing: .isolatedExchanges, maxPending: 1)
        let pending = Task { try await client.request("pending", timeout: .seconds(5)) }
        let call = try await transport.call("pending")
        #expect(call.claim())

        pending.cancel()
        await #expect(throws: ClientError.cancelled(.unknown)) { try await pending.value }
        #expect(call.submission.isCancellationPending)
        await #expect(throws: ClientError.overloaded) {
            try await client.request("while cancelling", timeout: .seconds(1))
        }

        await call.respond("late answer", from: .exchange(call.id))
        #expect(!call.submission.isCancellationPending)
        await #expect(throws: ClientError.overloaded) {
            try await client.request("after late answer", timeout: .seconds(1))
        }

        let finishedSendsAtClose = Mutex<Int?>(nil)
        let close = Task {
            await client.close()
            let finishedSends = await transport.finishedSendCount
            finishedSendsAtClose.withLock { $0 = finishedSends }
        }
        defer { close.cancel() }
        try await transport.waitForClose()
        #expect(await transport.finishedSendCount == 0)
        #expect(finishedSendsAtClose.withLock { $0 } == nil)
        close.cancel()
        await transport.releaseSends()
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(5)
        while finishedSendsAtClose.withLock({ $0 }) == nil, clock.now < limit {
            try await clock.sleep(for: .milliseconds(1))
        }
        #expect(finishedSendsAtClose.withLock { $0 } == 1)
        #expect(call.cancellationActions == ["cancelExchange"])
    }
}
