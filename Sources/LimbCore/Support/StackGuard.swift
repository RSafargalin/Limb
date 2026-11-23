#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if os(Linux)
import CLimbPosix
import CDispatch
#endif

/// Measures how much stack a recursive algorithm has used since it started.
///
/// Recursion over untrusted input needs a depth limit, but a count of levels says nothing about
/// bytes: frame sizes differ several-fold between debug and release builds, and handlers run on
/// threads with stacks as small as 512 KiB. This turns "too deep" into an ordinary error before
/// the stack runs out, whatever the build mode.
struct StackGuard {
    private let origin: Int
    private let budget: Int
    private let record = Record()

    /// Shared by every copy of the guard, so the caller at the top can ask afterwards.
    private final class Record {
        var exhausted = false
    }

    /// Whether `isExhausted` has ever answered yes. An algorithm that swallows "too deep" on
    /// some paths (a schema's `anyOf` treats any failure as "this alternative does not match")
    /// would otherwise turn a lack of stack into a wrong answer.
    var wasExhausted: Bool { record.exhausted }

    /// Records that something was refused for lack of stack by a check other than this guard's.
    func noteExhausted() { record.exhausted = true }

    /// - Parameter budget: bytes of stack the algorithm may use beyond its entry point.
    @inline(__always)
    init(budget: Int = 256 * 1024) {
        var marker = 0
        origin = withUnsafePointer(to: &marker) { Int(bitPattern: $0) }
        #if canImport(Darwin)
        // The budget is counted from the entry point, and the entry point may already be deep:
        // a caller that has used most of its stack must not be granted a full budget on top.
        if let remaining = StackGuard.remaining {
            self.budget = min(budget, remaining - StackGuard.reserve)
        } else {
            self.budget = budget
        }
        #else
        // Not done here: glibc answers the question for the main thread by reading
        // /proc/self/maps, which is far too slow to do on every parse.
        self.budget = budget
        #endif
    }

    /// Stack kept free below the budget for whatever the algorithm calls at its deepest point.
    static let reserve = 32 * 1024

    /// Bytes of stack left on the current thread, or `nil` where the platform does not say.
    static var remaining: Int? {
        var marker = 0
        let here = withUnsafePointer(to: &marker) { Int(bitPattern: $0) }
        #if canImport(Darwin)
        let thread = pthread_self()
        let top = Int(bitPattern: pthread_get_stackaddr_np(thread))
        return pthread_get_stacksize_np(thread) - (top - here)
        #elseif os(Linux)
        var low: UnsafeMutableRawPointer?
        var size = 0
        guard limb_thread_stack_bounds(&low, &size) == 0, let low else { return nil }
        return here - Int(bitPattern: low)
        #else
        return nil
        #endif
    }

    /// Whether the current frame is deeper than the budget allows.
    @inline(__always)
    var isExhausted: Bool {
        var marker = 0
        let here = withUnsafePointer(to: &marker) { Int(bitPattern: $0) }
        // The stack grows toward lower addresses on every platform Swift supports.
        guard origin - here > budget else { return false }
        record.exhausted = true
        return true
    }
}

private final class LargeStackJob {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// Runs `body` on a thread with a stack of `bytes` and waits for it.
///
/// For the rare input that a recursive algorithm cannot finish on the caller's stack — handlers
/// run on 512 KiB, and an unoptimized build spends several kilobytes per level. The caller's
/// thread blocks meanwhile, which is acceptable only because this is a fallback, not a path.
func onLargeStack<T>(bytes: Int, _ body: () -> T) -> T {
    typealias Job = LargeStackJob
    var result: T?
    var started = false
    withoutActuallyEscaping(body) { body in
        withUnsafeMutablePointer(to: &result) { slot in
            let context = Unmanaged.passRetained(Job { slot.pointee = body() }).toOpaque()
            var attributes = pthread_attr_t()
            guard pthread_attr_init(&attributes) == 0 else {
                Unmanaged<Job>.fromOpaque(context).release()
                return
            }
            defer { pthread_attr_destroy(&attributes) }
            // A thread with the default stack would be no better than this one.
            guard pthread_attr_setstacksize(&attributes, bytes) == 0 else {
                Unmanaged<Job>.fromOpaque(context).release()
                return
            }
            // `pthread_t` is a pointer that `pthread_create` fills in on Darwin and Musl, and an
            // integer on Glibc; the start routine's argument is optional except on Darwin.
            #if canImport(Darwin)
            var thread: pthread_t?
            let status = pthread_create(&thread, &attributes, { context in
                Unmanaged<Job>.fromOpaque(context).takeRetainedValue().run()
                return nil
            }, context)
            guard status == 0, let thread else {
                Unmanaged<Job>.fromOpaque(context).release()
                return
            }
            #elseif canImport(Musl)
            // In both branches below `context!` is the non-nil pointer handed to `pthread_create`.
            var thread: pthread_t?
            let status = pthread_create(&thread, &attributes, { context in
                Unmanaged<Job>.fromOpaque(context!).takeRetainedValue().run()
                return nil
            }, context)
            guard status == 0, let thread else {
                Unmanaged<Job>.fromOpaque(context).release()
                return
            }
            #else
            var thread = pthread_t()
            let status = pthread_create(&thread, &attributes, { context in
                Unmanaged<Job>.fromOpaque(context!).takeRetainedValue().run()
                return nil
            }, context)
            guard status == 0 else {
                Unmanaged<Job>.fromOpaque(context).release()
                return
            }
            #endif
            pthread_join(thread, nil)
            started = true
        }
    }
    // No thread to be had: do what can be done where we are.
    if !started { return body() }
    // The thread ran `body` and stored its result before `pthread_join` returned.
    return result!
}
