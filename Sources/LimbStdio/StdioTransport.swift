import LimbCore
public import LimbServer
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if os(Linux)
import CDispatch
import CLimbPosix
#endif

/// Newline-delimited JSON-RPC over a pair of file descriptors: stdin and stdout by default,
/// or any stream (a Unix socket, a TCP connection) that uses the same framing.
///
/// Each direction has its own OS thread:
///
/// - The **reader** blocks in `poll` and `read`, so a message is picked up the moment it
///   arrives instead of at the next polling interval, and no file descriptor flag is changed
///   (descriptors inherited from a parent are shared with it, so there is nothing to restore).
/// - The **writer** is the only code that writes. It takes whole frames from a queue and
///   writes each to completion, so frames cannot interleave however many handlers finish at
///   once and however slowly the peer reads.
///
/// Pipes, sockets, files and terminals all work as either end. A descriptor that `poll` cannot
/// watch (on macOS: `/dev/null`, `/dev/zero` and other devices) works as the input too, with
/// one limitation: while a `read` from it blocks, stopping the session waits for that `read`.
///
/// With the default transport, stdout belongs to the protocol alone, so anything else the
/// process writes there — a handler's `print`, a child process's output — is sent to stderr
/// while a session runs; see `protectsStandardOutput`.
public struct StdioTransport: Sendable {
    public var input: Int32
    public var output: Int32
    /// Whether `run` points descriptor 1 at stderr for as long as the session runs, so that
    /// stray writes to stdout cannot corrupt the protocol. The protocol itself goes out
    /// through a private duplicate of the original stdout. The transport restores descriptor 1
    /// when `run` returns if it still points to the redirected destination. Coordinate any
    /// concurrent replacement of stdout with `run`. Protection applies when `output` is
    /// `STDOUT_FILENO` and stderr is open.
    ///
    /// `true` for `init()`, `false` for `init(input:output:)`: descriptors given explicitly
    /// are the caller's business, and the process's stdout may be something else entirely.
    public var protectsStandardOutput: Bool
    package var beforeKeyedWrite: (@Sendable ([UInt8]) -> Void)? = nil
    package var afterFirstByte: (@Sendable ([UInt8]) -> Void)? = nil
    package var beforeWriteAccounting: (@Sendable () -> Void)? = nil

    /// Standard input and standard output, with stray output to stdout sent to stderr.
    public init() {
        input = STDIN_FILENO
        output = STDOUT_FILENO
        protectsStandardOutput = true
    }

    public init(input: Int32, output: Int32) {
        self.input = input
        self.output = output
        protectsStandardOutput = false
    }
}

extension Server {
    /// Serves one connection over stdio and returns when the input ends.
    ///
    /// On end of input the server stops reading, lets requests in flight finish within the
    /// configured grace period, writes what is queued and returns. Cancelling the calling
    /// task stops it the same way. A last frame that is not followed by a newline is dropped
    /// with a diagnostic. On a terminal, a hangup (`read` failing with `EIO`) is end of input.
    ///
    /// Writing waits only while the peer reads: once the input has ended, a peer that takes
    /// nothing for `outputDrainSeconds` is given up on, and `run` returns while its writer stays
    /// behind. The writer writes to its own duplicate of `transport.output`, so after `run`
    /// returns the caller's descriptor number is never written to again; if no duplicate can be
    /// made for lack of descriptors, `run` does not start. A peer that goes away (a write fails
    /// because the pipe or socket is closed or reset) is an ordinary end at any moment: requests
    /// in flight are cancelled at once and nothing is logged.
    ///
    /// With `transport.protectsStandardOutput` (the default transport), descriptor 1 refers to
    /// stderr while the session runs and is restored when `run` returns. Output that `print`
    /// buffered before `run` and had not written yet goes to stderr too, and what the session's
    /// stray output left in the buffer is flushed to stderr before stdout is restored. Child
    /// processes started meanwhile inherit stderr as their stdout. Only one session using
    /// stdin or stdout may run at once. A second such call reports a diagnostic and returns.
    ///
    /// A closed output is handled as `EPIPE` with the application's `SIGPIPE` disposition
    /// intact. On Darwin the writer of a non-socket output temporarily enables
    /// `F_SETNOSIGPIPE` on the shared open file description. Limb reserves the endpoint
    /// until the writer exits, which can be after `run` returns when output stops draining.
    /// Another session using that endpoint is rejected. Coordinate host writes and changes
    /// to that option on aliased descriptors with the writer's lifetime.
    public func run(_ transport: StdioTransport = StdioTransport()) async {
        let usesStandardStreams = transport.input == STDIN_FILENO || transport.output == STDOUT_FILENO
        if usesStandardStreams, !StandardStreamOwnership.acquire() {
            configuration.diagnostics("stdio: stdin or stdout already belongs to another session")
            return
        }
        defer { if usesStandardStreams { StandardStreamOwnership.release() } }

        var transport = transport
        let realStandardOutput =
            transport.protectsStandardOutput && transport.output == STDOUT_FILENO
            ? StandardOutputProtection.begin() : nil
        if let realStandardOutput { transport.output = realStandardOutput.saved }
        defer { if let realStandardOutput { StandardOutputProtection.end(realStandardOutput) } }

        let queue = OutboundQueue(budgetBytes: configuration.budgets.maxOutboundBytes)
        let connection = connect(to: queue)
        let session = StdioSession(
            transport: transport, connection: connection, queue: queue,
            maxFrameBytes: configuration.budgets.maxFrameBytes, drainLimit: timeLimit(seconds: configuration.outputDrainSeconds),
            diagnostics: configuration.diagnostics)
        guard session.start() else {
            session.cleanUp()
            await connection.close(graceSeconds: 0)
            return
        }

        await withTaskCancellationHandler {
            await session.readerFinished()
        } onCancel: {
            session.stopReading()
        }
        // Input is over: finish what is in flight, then let the writer drain and stop. If the
        // peer is gone — found out before or during the grace period — there is nobody to
        // finish for: the writer ends the grace period and requests in flight are cancelled.
        await connection.close()
        queue.close()
        if await session.drainWriter() {
            // The peer keeps its end open and has stopped reading. The writer thread stays
            // blocked in `write` until the peer reads or goes away — nothing can interrupt it
            // without touching the descriptor — but the server does not wait for that. The
            // writer works on its own duplicate of the descriptor, so the caller is free to
            // close or reuse the one it passed in.
            configuration.diagnostics("stdio: the peer did not read the remaining output; giving up on it")
        }
        session.cleanUp()
    }
}

private enum StandardStreamOwnership {
    private static let active = Mutex(false)

    static func acquire() -> Bool {
        active.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
    }

    static func release() { active.withLock { $0 = false } }
}

private struct StdioWriterOutput: Sendable {
    let descriptor: Int32

    #if canImport(Darwin)
    // Use the live file identity conservatively. Separate opens of one file may compare
    // equal. Reject their overlapping use instead of assuming they share a signal option.
    private struct Identity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t
        let type: mode_t
    }

    private static let reserved = Mutex<Set<Identity>>([])
    private let socket: Bool
    private let reservation: Identity?
    private let restoreSignalOption: Bool
    #endif

    enum SetupError: Error {
        case inUse
        case posix(Int32)
    }

    init(_ descriptor: Int32) throws(SetupError) {
        self.descriptor = descriptor
        #if canImport(Darwin)
        guard descriptor >= 0 else {
            socket = false
            reservation = nil
            restoreSignalOption = false
            return
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw .posix(errno) }
        let type = information.st_mode & mode_t(S_IFMT)
        socket = type == mode_t(S_IFSOCK)
        if socket {
            reservation = nil
            restoreSignalOption = false
            return
        }

        let identity = Identity(device: information.st_dev, inode: information.st_ino, type: type)
        guard Self.reserved.withLock({ $0.insert(identity).inserted }) else { throw .inUse }
        let previous = fcntl(descriptor, F_GETNOSIGPIPE)
        if previous < 0 || (previous == 0 && fcntl(descriptor, F_SETNOSIGPIPE, 1) < 0) {
            let failure = errno
            Self.reserved.withLock { _ = $0.remove(identity) }
            throw .posix(failure)
        }
        reservation = identity
        restoreSignalOption = previous == 0
        #endif
    }

    func write(_ bytes: UnsafeRawPointer?, count: Int) -> Int {
        #if canImport(Darwin)
        if socket { return Darwin.send(descriptor, bytes, count, MSG_NOSIGNAL) }
        return Darwin.write(descriptor, bytes, count)
        #elseif canImport(Glibc)
        return Glibc.write(descriptor, bytes, count)
        #else
        return Musl.write(descriptor, bytes, count)
        #endif
    }

    func closeAndRestore() -> Int32? {
        guard descriptor >= 0 else { return nil }
        #if canImport(Darwin)
        if let reservation {
            return Self.reserved.withLock { endpoints in
                let failure = restoreSignalOption && fcntl(descriptor, F_SETNOSIGPIPE, 0) < 0 ? errno : nil
                close(descriptor)
                endpoints.remove(reservation)
                return failure
            }
        }
        #endif
        close(descriptor)
        return nil
    }
}

/// Keeps stray writes to descriptor 1 off the protocol while default-transport sessions run.
/// Called by the sole owner of the standard streams.
private enum StandardOutputProtection {
    struct Redirect {
        let saved: Int32
        let destination: stat
    }

    /// Points descriptor 1 at stderr. Returns a descriptor for the real stdout, to write the
    /// protocol to, or `nil` when nothing was changed: stderr or stdout is not open, or no
    /// descriptor is left to save stdout in. The session then uses descriptor 1 as it is.
    static func begin() -> Redirect? {
        // A closed stderr: there is nowhere better for stray output to go.
        var destination = stat()
        guard fstat(STDERR_FILENO, &destination) == 0 else { return nil }
        let saved = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0)
        guard saved >= 0 else { return nil }
        // Buffered ordinary stdout output goes to stderr when flushed during the session.
        guard redirect(STDERR_FILENO, to: STDOUT_FILENO) else {
            close(saved)
            return nil
        }
        return Redirect(saved: saved, destination: destination)
    }

    static func end(_ protection: Redirect) {
        defer { close(protection.saved) }
        var current = stat()
        let destination = protection.destination
        guard fstat(STDOUT_FILENO, &current) == 0, current.st_dev == destination.st_dev,
            current.st_ino == destination.st_ino, current.st_rdev == destination.st_rdev else { return }
        // Stray output still in the C library's buffer belongs to the session while redirected.
        fflush(nil)
        _ = redirect(protection.saved, to: STDOUT_FILENO)
    }

    private static func redirect(_ source: Int32, to target: Int32) -> Bool {
        while dup2(source, target) < 0 {
            if errno != EINTR { return false }
        }
        return true
    }
}

final class StdioSession: Sendable {
    private let transport: StdioTransport
    private let connection: Connection
    private let queue: OutboundQueue
    private let maxFrameBytes: Int
    /// How long the writer may stand still once the input has ended; `nil` for as long as it takes.
    private let drainLimit: Duration?
    private let diagnostics: @Sendable (String) -> Void
    private let beforeKeyedWrite: (@Sendable ([UInt8]) -> Void)?
    private let afterFirstByte: (@Sendable ([UInt8]) -> Void)?
    private let beforeWriteAccounting: (@Sendable () -> Void)?
    /// Written to wake the reader out of `poll` when it must stop without end of input, and the
    /// writer when draining begins. Nobody reads it: once written, it stays readable.
    private let wake: (read: Int32, write: Int32)
    /// Why the wake-up pipe could not be created, if it could not.
    private let wakeError: Int32?
    /// The writer's own duplicate of the output descriptor. It refers to the same pipe or
    /// socket and shares its flags, but its number is this session's alone: a writer that is
    /// still busy after `run` returned can never write into whatever the caller's number has
    /// come to mean since. Closed by the writer when it ends. -1 when the caller's descriptor
    /// is not open: the first write then fails and ends the session the ordinary way, without
    /// ever touching a number the caller may open something else on.
    private let output: Int32
    /// Why the output could not be duplicated although it is open (the process is out of
    /// descriptors). The session does not start then: the writer would have to use the
    /// caller's number, and a writer left behind could write into whatever that number is
    /// given to next.
    private let duplicationError: Int32?

    private struct Completion {
        var readerDone = false
        var writerDone = false
        /// The writer is about to close its descriptor. The watchdog can no longer poll it.
        var writerFinishing = false
        /// The writer settled its frame but has yet to remove its charge from the queue.
        var frameFinished = false
        /// The session stopped waiting for the writer; set before any waiter could be missed.
        var writerAbandoned = false
        var backpressuredAtDeadline = false
        var cleanedUp = false
        /// When the writer last got bytes out.
        var lastProgress = ContinuousClock.now
        /// The input has ended and the session waits only for the queued output to be written.
        var draining = false
        /// Something was written to the wake-up pipe.
        var wakeWritten = false
        /// The writer waits in `poll` on the wake-up pipe; it closes the pipe itself if the
        /// session is cleaned up meanwhile, so that it never polls a number reused since.
        var writerWatchesWake = false
        var readerWaiter: CheckedContinuation<Void, Never>?
        var writerWaiter: CheckedContinuation<Void, Never>?
    }

    private let completion = Mutex(Completion())

    init(
        transport: StdioTransport, connection: Connection, queue: OutboundQueue, maxFrameBytes: Int,
        drainLimit: Duration?, diagnostics: @escaping @Sendable (String) -> Void
    ) {
        self.transport = transport
        self.connection = connection
        self.queue = queue
        self.maxFrameBytes = maxFrameBytes
        self.drainLimit = drainLimit
        self.diagnostics = diagnostics
        beforeKeyedWrite = transport.beforeKeyedWrite
        afterFirstByte = transport.afterFirstByte
        beforeWriteAccounting = transport.beforeWriteAccounting
        // Close-on-exec like the duplicate: a child process a handler starts must not inherit
        // the session's descriptors.
        var descriptors: [Int32] = [-1, -1]
        #if canImport(Darwin)
        // Darwin has no `pipe2`. A process started by another thread between the two calls
        // can still inherit the pipe; that window is as narrow as it gets.
        let created = pipe(&descriptors) == 0
        wakeError = created ? nil : errno
        if created {
            for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        } else {
            descriptors = [-1, -1]
        }
        #else
        let created = limb_cloexec_pipe(&descriptors) == 0
        wakeError = created ? nil : errno
        if !created { descriptors = [-1, -1] }
        #endif
        wake = (descriptors[0], descriptors[1])
        let duplicate = fcntl(transport.output, F_DUPFD_CLOEXEC, 0)
        let error = errno
        output = duplicate
        duplicationError = duplicate < 0 && error != EBADF ? error : nil
    }

    func start() -> Bool {
        if let wakeError {
            diagnostics("stdio: could not create the wake-up pipe: \(String(cString: strerror(wakeError)))")
            if output >= 0 { close(output) }
            return false
        }
        if let duplicationError {
            diagnostics("stdio: could not duplicate the output descriptor: \(String(cString: strerror(duplicationError)))")
            return false
        }
        let writerOutput: StdioWriterOutput
        do {
            writerOutput = try StdioWriterOutput(output)
        } catch {
            switch error {
            case .inUse: diagnostics("stdio: the output endpoint already belongs to another writer")
            case .posix(let code): diagnostics("stdio: could not prepare the writer output: \(String(cString: strerror(code)))")
            }
            if output >= 0 { close(output) }
            queue.close()
            return false
        }
        guard spawnThread(name: writerThreadName, { self.writeLoop(writingTo: writerOutput) }) else {
            diagnostics("stdio: could not start the writer thread")
            closeWriterOutput(writerOutput)
            queue.close()
            return false
        }
        guard spawnThread(name: readerThreadName, { self.readLoop() }) else {
            diagnostics("stdio: could not start the reader thread")
            // The writer sees the closed queue, ends and closes its descriptor.
            queue.close()
            return false
        }
        return true
    }

    func stopReading() {
        // Under the lock, so that the pipe cannot be closed — and its number reused for some
        // other descriptor — between the check and the write. An abandoned writer may still
        // get here long after the session ended.
        completion.withLock { state in
            guard !state.cleanedUp else { return }
            var byte: UInt8 = 1
            _ = write(wake.write, &byte, 1)
            state.wakeWritten = true
        }
    }

    func cleanUp() {
        completion.withLock { state in
            guard !state.cleanedUp else { return }
            state.cleanedUp = true
            // A writer waiting on the pipe was woken when draining began; it closes the pipe
            // when it is out of `poll`.
            if !state.writerWatchesWake { closeWake() }
        }
    }

    private func closeWake() {
        close(wake.read)
        close(wake.write)
    }

    func readerFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = completion.withLock { state in
                if state.readerDone { return true }
                state.readerWaiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Waits for the writer to drain the queue and stop, or leaves it behind at `drainLimit`.
    /// Returns whether the output was backpressured at the deadline and needs a diagnostic.
    ///
    /// The limit is on standing still, not on the total: a peer that reads slowly but keeps
    /// reading gets everything, however long it takes. Call after the queue is closed.
    func drainWriter() async -> Bool {
        let started = ContinuousClock.now
        completion.withLock { $0.draining = true }
        // A writer waiting for room without a timeout must start timing its retries now.
        stopReading()
        let watchdog = drainLimit.map { limit in
            Task { [self] in
                var deadline = started + limit
                while true {
                    guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
                    var next: ContinuousClock.Instant?
                    let waiter: CheckedContinuation<Void, Never>? = completion.withLock { state in
                        guard !state.writerFinishing else { return nil }
                        // Read the queue under the same lock as frameFinished. When no frame
                        // remains, just wait for the writer to notice the closed queue.
                        let usage = queue.usage
                        guard usage.ordinaryBytes != 0 || usage.urgentBytes != 0 else { return nil }
                        let idleSince = Swift.max(state.lastProgress, started)
                        if ContinuousClock.now - idleSince < limit {
                            next = idleSince + limit
                            return nil
                        }
                        state.writerAbandoned = true
                        // A settled frame still counted by the queue can itself have filled
                        // the last buffer. Only probe if there is more work to write. The
                        // writer takes this same lock before closing its duplicate.
                        if output >= 0, !state.frameFinished || usage.queuedFrames > 0 {
                            var descriptor = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                            state.backpressuredAtDeadline = poll(&descriptor, 1, 0) == 0
                        }
                        defer { state.writerWaiter = nil }
                        return state.writerWaiter
                    }
                    waiter?.resume()
                    guard let next else { return }
                    deadline = next
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = completion.withLock { state in
                if state.writerDone || state.writerAbandoned { return true }
                state.writerWaiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
        watchdog?.cancel()
        return completion.withLock { !$0.writerDone && $0.backpressuredAtDeadline }
    }

    // MARK: Reader

    private func readLoop() {
        var framer = LineFramer(maxFrameBytes: maxFrameBytes)
        let input = transport.input
        var descriptors = [
            pollfd(fd: input, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
        ]
        // `poll` answers POLLNVAL for an input it cannot watch: on macOS `/dev/null`,
        // `/dev/zero` and other devices, and anywhere a descriptor that is not open. From then
        // on only the wake-up pipe is polled, and the input is read without asking first: a
        // device answers at once, and a descriptor that is not open fails the read, which ends
        // the session with a diagnostic. A read that blocks cannot be interrupted, so a stop
        // takes effect once it returns.
        var inputIsPollable = true
        // Milliseconds to wait before reading an input that cannot be polled: zero, except
        // after it said "try again", so that a non-blocking one is not read in a busy loop.
        var unpollableRetryDelay: Int32 = 0
        reading: while true {
            // Hand every complete frame to the engine before touching the descriptor again:
            // a request is registered before the frame behind it is read.
            while let event = framer.next() {
                switch event {
                case .frame(let range):
                    connection.receive(framer.buffer.span.extracting(range))
                case .oversized:
                    if !connection.receivedOversizedFrame() {
                        diagnostics("stdio: closing after repeated oversized frames")
                        break reading
                    }
                }
            }
            // The writer closed the queue: the peer went away. That is an ordinary end, and it
            // is not the same thing as a peer that is there and does not read.
            if queue.isClosed { break }
            if connection.hasOverflowed {
                diagnostics("stdio: the peer is not reading responses; closing")
                break
            }

            descriptors[0].revents = 0
            descriptors[1].revents = 0
            let ready =
                inputIsPollable
                ? poll(&descriptors, 2, -1)
                : poll(&descriptors[1], 1, unpollableRetryDelay)
            if ready < 0 {
                let error = errno
                if error == EINTR { continue }
                diagnostics("stdio: poll failed: \(String(cString: strerror(error)))")
                break
            }
            if descriptors[1].revents != 0 { break }
            if descriptors[0].revents & Int16(POLLNVAL) != 0 { inputIsPollable = false }

            var readError: Int32 = 0
            let count = framer.receive { buffer in
                let count = read(input, buffer.baseAddress, buffer.count)
                if count < 0 { readError = errno }
                return count
            }
            unpollableRetryDelay = 0
            if count > 0 { continue }
            if count == 0 {
                // End of input: the graceful shutdown signal.
                reportPartialFrame(framer)
                break
            }
            if readError == EINTR { continue }
            if readError == EAGAIN {
                if !inputIsPollable { unpollableRetryDelay = 10 }
                continue
            }
            if meansPeerIsGone(readError) {
                // A reset connection: the peer is not coming back for its answers.
                connection.endGracePeriod()
            } else if readError == EIO, isatty(input) != 0 {
                // A terminal that hung up (Linux reports it this way, not as end of file), or a
                // background process that may not read its terminal: either way no more input
                // is coming, which is end of input.
                reportPartialFrame(framer)
            } else {
                diagnostics("stdio: read failed: \(String(cString: strerror(readError)))")
            }
            break
        }
        let waiter = completion.withLock { state in
            state.readerDone = true
            defer { state.readerWaiter = nil }
            return state.readerWaiter
        }
        waiter?.resume()
    }

    /// A frame is complete only with its newline, so bytes after the last one are dropped when
    /// the input ends; a peer that forgot the newline should hear why it got no answer.
    private func reportPartialFrame(_ framer: LineFramer) {
        if framer.hasPartialFrame {
            diagnostics("stdio: the input ended in the middle of a frame (no newline after it); dropped it")
        }
    }

    // MARK: Writer

    private func writeLoop(writingTo writerOutput: StdioWriterOutput) {
        var healthy = true
        #if !canImport(Darwin)
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        let status = pthread_sigmask(SIG_BLOCK, &blocked, nil)
        if status != 0 {
            diagnostics("stdio: could not suppress SIGPIPE for the writer: \(String(cString: strerror(status)))")
            queue.close()
            stopReading()
            connection.endGracePeriod()
            healthy = false
        }
        #endif
        while let frame = queue.takeFrame() {
            if healthy {
                healthy = writeFrame(frame, writingTo: writerOutput)
                if !healthy {
                    // The peer is gone. Stop accepting output, wake the reader to shut down, and
                    // cancel what is in flight: whether or not the input has ended already,
                    // nobody is left to answer.
                    queue.close()
                    stopReading()
                    connection.endGracePeriod()
                }
            }
            completion.withLock { $0.frameFinished = true }
            beforeWriteAccounting?()
            queue.didWrite()
            completion.withLock { $0.frameFinished = false }
        }
        completion.withLock { $0.writerFinishing = true }
        closeWriterOutput(writerOutput)
        let waiter = completion.withLock { state in
            state.writerDone = true
            defer { state.writerWaiter = nil }
            return state.writerWaiter
        }
        waiter?.resume()
    }

    private func closeWriterOutput(_ output: StdioWriterOutput) {
        if let error = output.closeAndRestore() {
            diagnostics("stdio: could not restore the output SIGPIPE option: \(String(cString: strerror(error)))")
        }
    }

    private func writeFrame(_ frame: OutboundQueue.FrameLease, writingTo writerOutput: StdioWriterOutput) -> Bool {
        var offset = 0
        var bytes = frame.bytes
        let appendedNewline = bytes.count < 32 * 1024
        if appendedNewline { bytes.append(0x0A) }
        if frame.key == nil {
            // Unkeyed frames cannot be withdrawn by cancellation.
            _ = queue.writeIfCurrent(frame) { _ in 1 }
        } else {
            beforeKeyedWrite?(frame.bytes)
            while queue.isCurrent(frame) {
                // This session is the only writer to its stream. Wait without queue locks,
                // then attempt at most one byte so a blocked peer cannot hold the queue lock.
                var outputReady = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                if output >= 0 {
                    let readiness = poll(&outputReady, 1, 0)
                    if readiness < 0 {
                        let error = errno
                        if error == EINTR { continue }
                        reportWriteFailure(error)
                        return false
                    }
                    if readiness == 0 {
                        waitForRoom()
                        continue
                    }
                }
                var writeError: Int32 = 0
                let attempt = queue.writeIfCurrent(frame) { _ in
                    bytes.withUnsafeBytes { raw in
                        let count = writerOutput.write(raw.baseAddress, count: 1)
                        if count < 0 { writeError = errno }
                        return count
                    }
                }
                guard let attempt else { return true }
                if attempt == 1 {
                    offset = 1
                    completion.withLock { $0.lastProgress = ContinuousClock.now }
                    afterFirstByte?(frame.bytes)
                    break
                }
                if writeError == EINTR { continue }
                if writeError == EAGAIN {
                    waitForRoom()
                    continue
                }
                reportWriteFailure(writeError)
                return false
            }
            guard offset > 0 else { return true }
        }
        return writeAll(bytes, from: offset, writingTo: writerOutput, finishesFrame: appendedNewline) &&
            (appendedNewline || writeAll([0x0A], writingTo: writerOutput, finishesFrame: true))
    }

    private func reportWriteFailure(_ error: Int32) {
        if error == 0 {
            diagnostics("stdio: write failed: the output accepted no bytes")
        } else if !meansPeerIsGone(error) {
            diagnostics("stdio: write failed: \(String(cString: strerror(error)))")
        }
    }

    /// Writes all of `bytes`, however many `write` calls it takes.
    ///
    /// A large frame goes out in pieces. A blocking `write` of the whole frame would return only
    /// when all of it is through, and until then nobody could tell a peer that reads slowly from
    /// one that has stopped. The drain timer measures successful writes. Once draining begins,
    /// each new write uses at most 1 KiB, while an earlier write can still be up to 16 KiB.
    /// The kernel can free buffer space in larger units, such as pages for a Linux pipe.
    private func writeAll(
        _ bytes: [UInt8], from start: Int = 0, writingTo writerOutput: StdioWriterOutput, finishesFrame: Bool
    ) -> Bool {
        return bytes.withUnsafeBytes { raw in
            var offset = start
            while offset < raw.count {
                // Small pieces once the session is only waiting for the output to drain: that is
                // when "is the peer still reading?" is asked, and the answer must not take the
                // time a slow peer needs for a large piece.
                let pieceSize = completion.withLock { $0.draining } ? 1024 : 16 * 1024
                let written = writerOutput.write(raw.baseAddress! + offset, count: Swift.min(raw.count - offset, pieceSize))
                if written > 0 {
                    offset += written
                    completion.withLock { state in
                        state.lastProgress = ContinuousClock.now
                        if finishesFrame, offset == raw.count { state.frameFinished = true }
                    }
                    continue
                }
                if written == 0 {
                    // Not an error, so `errno` says nothing; but an output that takes nothing
                    // and does not say why will not take more on the next try either.
                    reportWriteFailure(0)
                    return false
                }
                let error = errno
                if error == EINTR { continue }
                if error == EAGAIN {
                    // The descriptor was made non-blocking by someone else; wait for room.
                    waitForRoom()
                    continue
                }
                reportWriteFailure(error)
                return false
            }
            return true
        }
    }

    /// Waits until a non-blocking output may take more, or it is time to try again.
    ///
    /// `poll` reports room only once a low-water mark is free (2 KiB for a socket on Darwin, half
    /// the buffer on Linux), while a kilobyte written is already progress. So while draining,
    /// when the writer is timed, it also tries again often enough to notice a peer that takes a
    /// little at a time well within `drainLimit`. Before that it waits for `poll` alone, and for
    /// the wake-up pipe, which tells it that draining has begun. Left behind, or with no limit,
    /// nobody times it, and it waits for `poll` alone.
    private func waitForRoom() {
        enum Wait {
            case untilRoom
            case untilRoomOrDraining
            case retryAfter(milliseconds: Int32)
        }
        let wait: Wait = completion.withLock { state in
            if state.writerAbandoned { return .untilRoom }
            if state.draining {
                guard let drainLimit else { return .untilRoom }
                let milliseconds = drainLimit / .milliseconds(1) / 8
                return .retryAfter(milliseconds: Int32(Swift.min(Swift.max(milliseconds, 1), 50)))
            }
            // The pipe stays readable once written, so it is no use as a signal any more: the
            // reader was told to stop and draining follows within the grace period.
            if state.wakeWritten || state.cleanedUp { return .retryAfter(milliseconds: 50) }
            state.writerWatchesWake = true
            return .untilRoomOrDraining
        }
        var descriptors = [pollfd(fd: output, events: Int16(POLLOUT), revents: 0)]
        switch wait {
        case .untilRoom:
            _ = poll(&descriptors, 1, -1)
        case .retryAfter(let milliseconds):
            _ = poll(&descriptors, 1, milliseconds)
        case .untilRoomOrDraining:
            descriptors.append(pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0))
            _ = poll(&descriptors, 2, -1)
            completion.withLock { state in
                state.writerWatchesWake = false
                if state.cleanedUp { closeWake() }
            }
        }
    }
}

/// Whether a failed read or write means the peer is gone — an ordinary end, not worth a word:
/// the pipe or socket was closed (EPIPE; ENOTCONN, which Darwin may report for a socket closed
/// in the middle of a write; ESHUTDOWN; EPROTOTYPE, which Darwin may report for a write that
/// races the socket's close) or the connection was reset or aborted. Anything else (EBADF,
/// EIO, ENOSPC, a timeout, …) is a failure worth reporting.
private func meansPeerIsGone(_ error: Int32) -> Bool {
    switch error {
    case EPIPE, ECONNRESET, ENOTCONN, ESHUTDOWN, ECONNABORTED, EPROTOTYPE: true
    default: false
    }
}

// Thread names as tools show them. Linux keeps at most 15 bytes of a name and refuses a longer
// one outright (ERANGE), so the names are shorter there.
#if canImport(Darwin)
private let readerThreadName = "limb-stdio-reader"
private let writerThreadName = "limb-stdio-writer"
#else
private let readerThreadName = "limb-stdio-in"
private let writerThreadName = "limb-stdio-out"
#endif

/// The stack each transport thread gets. The platform default ranges from 128 KiB (Musl) to
/// 8 MiB (glibc); the reader parses, dispatches and destroys values nested up to the parser's
/// depth limit, which takes up to about 400 KiB in a debug build.
private let threadStackBytes = 1 << 20

private final class ThreadStart {
    let name: String
    let body: @Sendable () -> Void
    init(name: String, body: @escaping @Sendable () -> Void) {
        self.name = name
        self.body = body
    }
}

/// What a transport thread runs: takes ownership of its `ThreadStart`, names itself, works.
private func runThread(_ context: UnsafeMutableRawPointer) {
    let start = Unmanaged<ThreadStart>.fromOpaque(context).takeRetainedValue()
    #if canImport(Darwin)
    pthread_setname_np(start.name)
    #else
    // A name is a convenience for whoever looks at the process; failing to set one is not
    // worth stopping for.
    limb_name_current_thread(start.name)
    #endif
    start.body()
}

/// Starts a detached OS thread with a `threadStackBytes` stack. Transport I/O blocks, so it
/// must not run on the cooperative pool. Returns `false` if no such thread could be had,
/// including when the stack size is refused: the default may be too small for the reader.
private func spawnThread(name: String, _ body: @escaping @Sendable () -> Void) -> Bool {
    var attributes = pthread_attr_t()
    guard pthread_attr_init(&attributes) == 0 else { return false }
    defer { pthread_attr_destroy(&attributes) }
    guard pthread_attr_setstacksize(&attributes, threadStackBytes) == 0,
        pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED)) == 0
    else { return false }

    let context = Unmanaged.passRetained(ThreadStart(name: name, body: body)).toOpaque()
    // `pthread_t` is an opaque pointer on Darwin and Musl, and an integer on glibc; the
    // start routine's argument is non-optional only in Darwin's headers.
    #if canImport(Darwin)
    var thread: pthread_t?
    let status = pthread_create(&thread, &attributes, { context in
        runThread(context)
        return nil
    }, context)
    #elseif canImport(Musl)
    var thread: pthread_t?
    let status = pthread_create(&thread, &attributes, { context in
        runThread(context!)
        return nil
    }, context)
    #else
    var thread = pthread_t()
    let status = pthread_create(&thread, &attributes, { context in
        runThread(context!)
        return nil
    }, context)
    #endif
    guard status == 0 else {
        Unmanaged<ThreadStart>.fromOpaque(context).release()
        return false
    }
    return true
}
