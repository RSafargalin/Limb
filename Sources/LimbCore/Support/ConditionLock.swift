#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A mutex with a condition variable, for the few places where a thread must block until
/// another thread produces work (`Synchronization.Mutex` has no way to wait).
///
/// Critical sections are short and contain no suspension points.
package final class ConditionLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let condition: UnsafeMutablePointer<pthread_cond_t>

    package init() {
        mutex = .allocate(capacity: 1)
        condition = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        condition.initialize(to: pthread_cond_t())
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
    }

    package func lock() { pthread_mutex_lock(mutex) }
    package func unlock() { pthread_mutex_unlock(mutex) }
    /// Releases the lock, sleeps until signalled, and reacquires it. Call with the lock held.
    package func wait() { pthread_cond_wait(condition, mutex) }
    package func signal() { pthread_cond_signal(condition) }
    package func broadcast() { pthread_cond_broadcast(condition) }

    package func withLock<R>(_ body: () throws -> R) rethrows -> R {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }
}
