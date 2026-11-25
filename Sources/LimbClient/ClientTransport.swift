package import LimbCore
import Synchronization

package enum ClientRouting: Sendable {
    case sharedChannel
    case isolatedExchanges
    case legacySession

    func accepts(_ source: ClientResponseSource, for requestID: RequestID) -> Bool {
        switch (self, source) {
        case (.sharedChannel, .channel):
            true
        case (.isolatedExchanges, .exchange(let id)),
             (.legacySession, .exchange(let id)),
             (.legacySession, .resumedExchange(let id)):
            id == requestID
        default:
            false
        }
    }

    func acceptsLog(_ source: ClientResponseSource) -> Bool {
        switch (self, source) {
        case (.sharedChannel, .channel), (.isolatedExchanges, .exchange),
             (.legacySession, .exchange), (.legacySession, .resumedExchange):
            true
        default:
            false
        }
    }

    func acceptsUnsolicitedLegacy(_ source: ClientResponseSource) -> Bool {
        if case (.sharedChannel, .channel) = (self, source) { return true }
        return false
    }
}

package enum ClientResponseSource: Sendable {
    case channel
    case exchange(RequestID)
    /// A legacy stream for which the adapter verified the original exchange and session.
    case resumedExchange(RequestID)
}

package enum ClientTransportEvent: Sendable {
    case response(source: ClientResponseSource, id: RequestID, result: Result<JSONValue, MCPError>)
    case notification(source: ClientResponseSource, method: String, params: JSONObject)
    /// The adapter verified that the error without an ID came from this request's original POST.
    case uncorrelatedError(exchange: RequestID, error: MCPError)
    /// A malformed response the adapter could reliably attribute to this request.
    case protocolViolation(source: ClientResponseSource, id: RequestID)
    /// An HTTP rejection of the original POST without a usable JSON-RPC error.
    case httpRejected(exchange: RequestID, status: Int)
    /// Local frame preparation exceeded the adapter's limit before sending.
    case requestTooLarge(RequestID, bytes: Int, limit: Int)
    /// This submission failed. Set provenNotSent only if the adapter can prove no request was sent.
    case sendFailed(RequestID, provenNotSent: Bool = false)
    case exchangeEnded(RequestID)
    /// Delivered after all complete messages already received on the channel.
    case channelEnded
}

/// Share the receiver's isolation convention with adapters built under different Swift settings.
package typealias ClientEventReceiver = @Sendable (ClientTransportEvent) async -> Void

package struct ClientRequest: Sendable {
    package let id: RequestID
    package let method: String
    package let params: JSONObject
    package let profile: RevisionProfile
    package let deadline: ContinuousClock.Instant
}

package enum ClientCancellation: Sendable {
    case cancelExchange
    /// Retire the bootstrap locally. Legacy MCP forbids a wire cancellation for initialize.
    case abortBootstrap
}

package protocol ClientTransport: Sendable {
    /// Accept an outbound request. Claim its submission before doing I/O. Report failure if
    /// the exchange cannot be started. The adapter may retain the receiver for incoming events.
    /// Keep this call active while the exchange can still receive a response or has work
    /// in the writer or HTTP owner. Deliver and await the final event before returning.
    /// For a cancelled exchange, return after its cancellation is consumed or superseded
    /// by a final response, local abort or shutdown. Shared transport writes may use one
    /// writer while these calls suspend independently.
    func send(
        _ request: ClientRequest,
        submission: ClientSubmission,
        receive: @escaping ClientEventReceiver
    ) async

    /// Stop accepting submissions, unblock send calls and release the transport resources.
    func close() async
}

/// Linearizes the handoff to I/O against cancellation, including cancellation before send starts.
package final class ClientSubmission: Sendable {
    enum Ending {
        case response
        case cancelled
        case timedOut
        case closed
        case connectionLost
        case exchangeLost(provenNotSent: Bool = false)
        case requestTooLarge(bytes: Int, limit: Int)
        case protocolViolation
        case httpRejected(Int)

        var requiresClaim: Bool {
            switch self {
            case .response, .protocolViolation, .httpRejected: true
            default: false
            }
        }

        var cancelsIO: Bool {
            switch self {
            case .cancelled, .timedOut, .closed: true
            default: false
            }
        }

        func outcome(delivery: ClientDelivery, expired: Bool) -> Outcome {
            if expired { return .failure(.timedOut(delivery)) }
            switch self {
            case .response: return .response
            case .cancelled: return .failure(.cancelled(delivery))
            case .timedOut: return .failure(.timedOut(delivery))
            case .closed: return .failure(.closedDuringRequest(delivery))
            case .connectionLost: return .failure(.connectionLost(delivery))
            case .exchangeLost: return .failure(.exchangeLost(delivery))
            case .requestTooLarge(let bytes, let limit): return .failure(.requestTooLarge(bytes: bytes, limit: limit))
            case .protocolViolation: return .failure(.protocolViolation(delivery))
            case .httpRejected(let status): return .failure(.httpRejected(status: status, delivery: delivery))
            }
        }
    }

    enum Outcome {
        case response
        case failure(ClientError)
    }

    private typealias CancellationHook = @Sendable (ClientCancellation) -> Void

    private enum State {
        case queued(CancellationHook? = nil)
        case claimed(CancellationHook, acknowledged: Bool = false)
        case finished(Outcome, delivery: ClientDelivery, cancellationPending: Bool)
    }

    private let state = Mutex<State>(.queued())
    private let cancellation: ClientCancellation
    private let deadline: ContinuousClock.Instant

    init(cancellation: ClientCancellation, deadline: ContinuousClock.Instant) {
        self.cancellation = cancellation
        self.deadline = deadline
    }

    /// Wake a transport that can retire a queued request without waiting for its writer.
    /// The observer stops applying once the transport claims the submission.
    package func observeWithdrawal(_ observer: @escaping @Sendable (ClientCancellation) -> Void) -> Bool {
        state.withLock {
            guard case .queued = $0 else { return false }
            $0 = .queued(observer)
            return true
        }
    }

    /// Register the cancellation hook and obtain exclusive permission to start I/O. The hook
    /// must hand off promptly and coordinate with the adapter's writer or HTTP task. For stdio
    /// it orders any wire cancellation after the complete request frame. It can run before
    /// claim returns or race with a final response. The owner must disregard the hook
    /// if it has already retired the exchange. Check isCancellationPending when consuming
    /// a queued cancellation, since the client may have accepted a terminal event meanwhile.
    package func claim(onCancel: @escaping @Sendable (ClientCancellation) -> Void) -> Bool {
        state.withLock {
            guard case .queued = $0, ContinuousClock().now < deadline else { return false }
            $0 = .claimed(onCancel)
            return true
        }
    }

    var canSubmit: Bool {
        state.withLock {
            if case .queued = $0 { return true }
            return false
        }
    }

    var acceptsProgress: Bool {
        state.withLock {
            guard case .claimed(_, let acknowledged) = $0 else { return false }
            return acknowledged || ContinuousClock.now < deadline
        }
    }

    /// After acknowledging a long-lived exchange, the opening deadline no longer applies.
    func acknowledge() -> Bool {
        state.withLock {
            guard case .claimed(let hook, false) = $0, ContinuousClock.now < deadline else { return false }
            $0 = .claimed(hook, acknowledged: true)
            return true
        }
    }

    /// Check before emitting a queued wire cancellation. A response already observed by
    /// the client can make that cancellation unnecessary.
    package var isCancellationPending: Bool {
        state.withLock {
            if case .finished(_, _, cancellationPending: true) = $0 { return true }
            return false
        }
    }

    var delivery: ClientDelivery {
        state.withLock {
            switch $0 {
            case .queued: .notSent
            case .claimed: .unknown
            case .finished(_, let delivery, _): delivery
            }
        }
    }

    /// Choose the application's outcome before calling the adapter. Ending the transport can
    /// clear a queued wire cancellation, but cannot change an outcome already selected here.
    func finish(_ ending: Ending) -> Outcome? {
        let (outcome, hook) = state.withLock { state -> (Outcome?, CancellationHook?) in
            let delivery: ClientDelivery
            let hook: CancellationHook?
            let cancellationPending: Bool
            let expired: Bool
            switch state {
            case .queued(let observer):
                guard !ending.requiresClaim else { return (nil, nil) }
                delivery = .notSent
                hook = ending.cancelsIO ? observer : nil
                cancellationPending = false
                expired = ContinuousClock.now >= deadline
            case .claimed(let onCancel, let acknowledged):
                if case .exchangeLost(provenNotSent: true) = ending {
                    delivery = .notSent
                } else {
                    delivery = .unknown
                }
                hook = ending.cancelsIO ? onCancel : nil
                cancellationPending = hook != nil
                expired = !acknowledged && ContinuousClock.now >= deadline
            case .finished(let selected, let delivery, _):
                if !ending.cancelsIO { state = .finished(selected, delivery: delivery, cancellationPending: false) }
                return (selected, nil)
            }
            let selected = ending.outcome(delivery: delivery, expired: expired)
            state = .finished(selected, delivery: delivery, cancellationPending: cancellationPending)
            return (selected, hook)
        }
        hook?(cancellation)
        return outcome
    }
}
