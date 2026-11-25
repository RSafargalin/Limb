#if os(macOS)
import Darwin
import Synchronization

private func processEvent(_ identifier: UInt64, _ filter: Int16, _ flags: UInt16, _ notes: UInt32 = 0) -> kevent64_s {
    kevent64_s(ident: identifier, filter: filter, flags: flags, fflags: notes, data: 0, udata: 0, ext: (0, 0))
}

func triggerProcessWorker(_ queue: Int32) {
    var event = processEvent(1, Int16(EVFILT_USER), 0, UInt32(NOTE_TRIGGER))
    while kevent64(queue, &event, 1, nil, 0, 0, nil) < 0, errno == EINTR {}
}

struct StdioProcessDriver {
    private let owner: StdioProcessOwner
    private let child: StdioChild
    private let queue: StdioDescriptor
    private let configuration: StdioProcessConfiguration
    private var stdoutEnabled = true
    private var stdinEnabled = false
    private var exitObservedAt: ContinuousClock.Instant?
    private var termSent = false
    private var killSent = false
    private var reapRetry: ContinuousClock.Instant?
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    private static let stdoutLimit = 128 * 1024

    static func run(
        _ configuration: StdioProcessConfiguration, owner: StdioProcessOwner,
        launchDeadline: ContinuousClock.Instant, didSpawn: (@Sendable (Int32) throws(StdioProcessError) -> Void)?
    ) {
        defer { owner.completeCleanup() }
        guard owner.state.withLock({ $0.launchAborted == nil }) else { return }
        do throws(StdioProcessError) {
            let descriptor = kqueue()
            guard descriptor >= 0 else { throw .systemCall("kqueue", errno) }
            let queue = StdioDescriptor(descriptor)
            try queue.prepareForParent()
            // No child is started if startup resources fail or the launch was already withdrawn.
            if ContinuousClock.now >= launchDeadline { owner.abortLaunch(StdioProcessError.cleanupPending) }
            guard owner.state.withLock({ $0.launchAborted == nil }) else { return }
            let child = try StdioChild.spawn(configuration)
            var driver = Self(owner: owner, child: child, queue: queue, configuration: configuration)
            do throws(StdioProcessError) {
                try didSpawn?(child.pid)
                try driver.register()
                owner.state.withLock { $0.eventQueue = queue.value }
                owner.completeLaunch(.success(child.pid), before: launchDeadline)
                let status = try driver.runLoop()
                driver.closeDescriptors(.success(()))
                driver.publishClose(.success(status))
            } catch {
                owner.completeLaunch(.failure(error), before: launchDeadline)
                driver.recover(after: error)
            }
        } catch {
            owner.completeLaunch(.failure(error), before: launchDeadline)
        }
    }

    private mutating func register() throws(StdioProcessError) {
        try change(processEvent(1, Int16(EVFILT_USER), UInt16(EV_ADD | EV_CLEAR)))
        try change(processEvent(UInt64(child.output.value), Int16(EVFILT_READ), UInt16(EV_ADD)))
        try change(processEvent(UInt64(child.error.value), Int16(EVFILT_READ), UInt16(EV_ADD)))
        try change(processEvent(UInt64(child.input.value), Int16(EVFILT_WRITE), UInt16(EV_ADD | EV_DISABLE)))
        do {
            try change(processEvent(UInt64(child.pid), Int16(EVFILT_PROC), UInt16(EV_ADD | EV_ONESHOT), UInt32(NOTE_EXIT)))
        } catch StdioProcessError.systemCall(_, ESRCH) {
            // The child exited before EVFILT_PROC could attach. Its wait status remains ours.
            observeExit()
        } catch {
            throw error
        }
    }

    private func change(_ event: kevent64_s) throws(StdioProcessError) {
        var event = event
        while kevent64(queue.value, &event, 1, nil, 0, 0, nil) < 0 {
            if errno != EINTR { throw .systemCall("kevent register", errno) }
        }
    }

    private mutating func runLoop() throws(StdioProcessError) -> StdioProcessExit {
        var events = [kevent64_s](repeating: kevent64_s(), count: 8)
        while true {
            let now = ContinuousClock.now
            let deadline = try update(now)
            if exitObservedAt != nil, child.output.value < 0, child.error.value < 0,
               reapRetry.map({ now >= $0 }) ?? true
            {
                if let status = try reap() { return status }
                reapRetry = now + .milliseconds(5)
                continue
            }

            let count: Int32
            if let end = deadline {
                let duration = max(.zero, now.duration(to: end))
                let seconds = duration.components.seconds
                let nanos = duration.components.attoseconds / 1_000_000_000
                var timeout = timespec(tv_sec: Int(seconds), tv_nsec: Int(nanos))
                count = kevent64(queue.value, nil, 0, &events, Int32(events.count), 0, &timeout)
            } else {
                count = kevent64(queue.value, nil, 0, &events, Int32(events.count), 0, nil)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw .systemCall("kevent wait", errno)
            }

            // Establish process exit before servicing any writable event in the same batch.
            for event in events.prefix(Int(count)) where event.filter == Int16(EVFILT_PROC) {
                if event.flags & UInt16(EV_ERROR) != 0 { throw .systemCall("kevent process", Int32(event.data)) }
                observeExit()
            }
            for event in events.prefix(Int(count)) {
                if event.filter == Int16(EVFILT_WRITE), event.ident == UInt64(exactly: child.input.value) {
                    writeAvailable()
                } else if event.filter == Int16(EVFILT_READ), event.ident == UInt64(exactly: child.output.value) {
                    readAvailable(stdout: true)
                } else if event.filter == Int16(EVFILT_READ), event.ident == UInt64(exactly: child.error.value) {
                    readAvailable(stdout: false)
                }
            }
        }
    }

    private mutating func update(_ now: ContinuousClock.Instant) throws(StdioProcessError) -> ContinuousClock.Instant? {
        var next = reapRetry
        func consider(_ deadline: ContinuousClock.Instant) {
            next = next.map { min($0, deadline) } ?? deadline
        }

        let (close, writeDeadline, stdoutRoom) = owner.state.withLock { state in
            if let write = state.write {
                if state.publishedClosed {
                    state.finishWrite(.writeClosed(bytesWritten: write.written))
                } else if now >= write.deadline {
                    if write.written > 0 { state.beginClose() }
                    state.finishWrite(.writeTimedOut(bytesWritten: write.written))
                } else if write.whileAllowed?() == false {
                    // Readable stdout can invalidate a blocked write without a new writable event.
                    state.interruptWrite(write)
                }
            }
            return (state.closingSince, state.write?.deadline, Self.stdoutLimit - state.stdout.count)
        }

        if let close {
            child.input.close()
            let term = close + configuration.inputGrace
            let kill = term + configuration.terminateGrace
            let cleanup = shutdownDeadline(from: close)
            if exitObservedAt == nil {
                if !termSent {
                    if now >= term {
                        try signalGroup(SIGTERM)
                        termSent = true
                    } else { consider(term) }
                }
                if !killSent {
                    if now >= kill {
                        try signalGroup(SIGKILL)
                        killSent = true
                    } else { consider(kill) }
                }
            }
            if now >= cleanup {
                publishClose(.failure(.cleanupPending))
            } else { consider(cleanup) }
        }

        if let observed = exitObservedAt {
            let end = observed + configuration.drainGrace
            if now >= end {
                endStdout(.success(()))
                child.error.close()
            } else if child.output.value >= 0 || child.error.value >= 0 {
                consider(end)
            }
        }

        if child.input.value >= 0 {
            try setEnabled(child.input, filter: Int16(EVFILT_WRITE), current: stdinEnabled, desired: writeDeadline != nil)
            stdinEnabled = writeDeadline != nil
            if let writeDeadline { consider(writeDeadline) }
        }
        if child.output.value >= 0 {
            try setEnabled(child.output, filter: Int16(EVFILT_READ), current: stdoutEnabled, desired: stdoutRoom > 0)
            stdoutEnabled = stdoutRoom > 0
        }
        return next
    }

    private func setEnabled(
        _ descriptor: StdioDescriptor, filter: Int16, current: Bool, desired: Bool
    ) throws(StdioProcessError) {
        guard current != desired else { return }
        try change(processEvent(UInt64(descriptor.value), filter, UInt16(desired ? EV_ENABLE : EV_DISABLE)))
    }

    private mutating func observeExit() {
        if exitObservedAt == nil { exitObservedAt = .now }
        child.input.close()
        owner.state.withLock { state in
            state.publishedClosed = true
            if let write = state.write { state.finishWrite(.writeClosed(bytesWritten: write.written)) }
        }
    }

    private mutating func writeAvailable() {
        guard let ticket = owner.state.withLock({ $0.write?.ticket }) else { return }
        // Service available stdout before the first byte of a guarded write, even if kqueue
        // delivered the writable event first. Recheck cancellation and the deadline per chunk.
        while child.output.value >= 0,
              owner.state.withLock({ state in
                  guard !state.publishedClosed, let write = state.write, write.ticket == ticket,
                        let allowed = write.whileAllowed, ContinuousClock.now < write.deadline else { return false }
                  if allowed() { return true }
                  state.interruptWrite(write)
                  return false
              }),
              readAvailable(stdout: true) {
        }
        owner.state.withLock { state in
            guard !state.publishedClosed, var write = state.write, write.ticket == ticket,
                  ContinuousClock.now < write.deadline else { return }
            if write.whileAllowed?() == false {
                state.interruptWrite(write)
                return
            }
            let count = write.bytes.withUnsafeBytes { bytes in
                Darwin.write(child.input.value, bytes.baseAddress! + write.written, min(bytes.count - write.written, 64 * 1024))
            }
            if count > 0 {
                write.written += count
                state.write = write
                if write.written == write.bytes.count {
                    if write.sealBootstrap { state.bootstrapSealed = true }
                    state.finishWrite()
                }
            } else if count < 0 {
                let code = errno
                if code != EINTR, code != EAGAIN {
                    state.beginClose()
                    state.finishWrite(.writeFailed(bytesWritten: write.written, errno: code))
                }
            }
        }
    }

    @discardableResult
    private mutating func readAvailable(stdout: Bool) -> Bool {
        let descriptor = stdout ? child.output : child.error
        let room = stdout ? owner.state.withLock { Self.stdoutLimit - $0.stdout.count } : buffer.count
        let limit = min(room, buffer.count)
        guard limit > 0 else { return false }
        let count = Darwin.read(descriptor.value, &buffer, limit)
        if count > 0 {
            owner.state.withLock { state in
                if stdout {
                    if let bootstrap = state.bootstrap, !state.bootstrapSealed {
                        bootstrap.receive(buffer.prefix(count))
                    } else {
                        state.stdout.append(contentsOf: buffer.prefix(count))
                        state.deliverOutput()
                    }
                } else if configuration.stderrLimit > 0 {
                    let keep = min(count, configuration.stderrLimit)
                    let drop = max(0, state.stderr.count - (configuration.stderrLimit - keep))
                    if drop > 0 { state.stderr.removeFirst(drop) }
                    state.stderr.append(contentsOf: buffer[(count - keep)..<count])
                }
            }
            return true
        } else if count == 0 {
            if stdout { endStdout(.success(())) }
            else { descriptor.close() }
        } else {
            let code = errno
            if code == EINTR { return true }
            if code != EAGAIN {
                if stdout { endStdout(.failure(.systemCall("read stdout", code))) }
                else { descriptor.close() }
            }
        }
        return false
    }

    private func endStdout(_ result: Result<Void, StdioProcessError>) {
        child.output.close()
        owner.state.withLock { state in
            if state.outputEnded == nil {
                state.outputEnded = result
                if !state.bootstrapSealed { state.bootstrap?.end() }
                state.deliverOutput()
            }
        }
    }

    /// The leader's waitable status anchors its process group until we release it.
    private func signalGroup(_ signal: Int32) throws(StdioProcessError) {
        var info = siginfo_t()
        while waitid(P_PID, UInt32(child.pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            if errno == ECHILD { return }
            if errno != EINTR { throw .systemCall("waitid", errno) }
        }
        guard Darwin.kill(-child.pid, signal) != 0 else { return }
        let code = errno
        // Darwin can return EPERM when the group only contains its exiting leader.
        guard code != ESRCH, !(code == EPERM && (exitObservedAt != nil || info.si_pid == child.pid)) else { return }
        throw .systemCall("kill process group", code)
    }

    private mutating func reap() throws(StdioProcessError) -> StdioProcessExit? {
        if !killSent {
            try signalGroup(SIGKILL)
            killSent = true
        }
        var status: Int32 = 0
        while true {
            let reaped = waitpid(child.pid, &status, WNOHANG)
            if reaped == child.pid {
                let signal = status & 0x7f
                return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
            }
            if reaped == 0 { return nil }
            if errno != EINTR { throw .systemCall("waitpid", errno) }
        }
    }

    private func shutdownDeadline(from closingSince: ContinuousClock.Instant) -> ContinuousClock.Instant {
        closingSince + configuration.inputGrace + configuration.terminateGrace
            + configuration.cleanupGrace + configuration.drainGrace
    }

    private func recover(after error: StdioProcessError) {
        closeDescriptors(.failure(error))
        let limit = ContinuousClock.now + configuration.cleanupGrace
        let deadline = owner.state.withLock { $0.closingSince.map { min(shutdownDeadline(from: $0), limit) } ?? limit }
        // The event queue is no longer usable. The worker still owns the direct child while
        // the watchdog can return a shared pending result to callers of close().
        let watchdog = Task.detached { [owner] in
            do {
                try await ContinuousClock().sleep(until: deadline)
                owner.state.withLock { $0.completeClose(.failure(.cleanupPending)) }
            } catch {}
        }
        defer { watchdog.cancel() }

        try? signalGroup(SIGKILL)
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0, errno == EINTR {}
        publishClose(.failure(ContinuousClock.now < deadline ? error : .cleanupPending))
    }

    private func closeDescriptors(_ result: Result<Void, StdioProcessError>) {
        owner.state.withLock { state in
            // A submitted wake can no longer reference this descriptor before it is closed or reused.
            state.eventQueue = nil
            state.publishedClosed = true
            if let write = state.write { state.finishWrite(.writeClosed(bytesWritten: write.written)) }
        }
        queue.close()
        child.input.close()
        child.error.close()
        endStdout(result)
    }

    private func publishClose(_ result: Result<StdioProcessExit, StdioProcessError>) {
        owner.state.withLock { $0.completeClose(result) }
    }
}
#endif
