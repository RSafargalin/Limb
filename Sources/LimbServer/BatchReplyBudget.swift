import Synchronization

/// The encoded reply bytes that legacy batches retain before passing their joined frame to a sink.
final class BatchReplyBudget: Sendable {
    private let limit: Int
    private let used = Mutex(0)

    init(limit: Int) { self.limit = limit }

    func reserve(_ bytes: Int) -> Bool {
        used.withLock { used in
            guard bytes <= limit - used else { return false }
            used += bytes
            return true
        }
    }

    func release(_ bytes: Int) {
        if bytes > 0 { used.withLock { $0 -= bytes } }
    }
}
