#if os(macOS)
import Darwin
import Limb
import Synchronization

func belongsToDriver(_ pid: Int32) -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var data = kinfo_proc()
    var bytes = MemoryLayout<kinfo_proc>.stride
    return sysctl(&mib, UInt32(mib.count), &data, &bytes, nil, 0) == 0
        && bytes == MemoryLayout<kinfo_proc>.stride && data.kp_eproc.e_ppid == getpid()
}

final class LifecycleTally: Sendable {
    let value = Mutex(0)
}

func mixedLifecycle(_ path: String, _ arguments: [String], expected: String) async throws -> Bool {
    let cycles = max(1, setting("EPOCHS", 12))
    let active = max(1, setting("SECONDS", 15))
    let idle = setting("IDLE_SECONDS", 10)
    let workerCount = max(1, min(16, setting("WORKERS", 8)))
    let uri = "fixture://system/alpha"
    let filter = ClientSubscriptionFilter(resourceSubscriptions: [uri])
    let clockStart = clock.now
    let client = try await makeClient(path, arguments, expected: expected, recovery: true)
    let updates = LifecycleTally()
    let interruptions = LifecycleTally()
    let reopenings = LifecycleTally()
    let progress = LifecycleTally()
    let sub = try await client.subscribe(filter: filter, bufferSize: 256)
    let listener = Task { () -> Bool in
        do {
            for try await event in sub {
                switch event {
                case .resourceUpdated(let actual) where actual == uri: updates.value.withLock { $0 += 1 }
                case .interrupted: interruptions.value.withLock { $0 += 1 }
                case .resubscribed(let actual) where actual == filter: reopenings.value.withLock { $0 += 1 }
                default: return false
                }
            }
            return true
        } catch { return false }
    }

    for cycle in 0..<cycles {
        let phase = clock.now
        let beforeUpdates = updates.value.withLock { $0 }
        let beforeProgress = progress.value.withLock { $0 }
        let endActive = phase + .seconds(active)
        let counts = try await withThrowingTaskGroup(of: Counts.self, returning: Counts.self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    let payload = String(repeating: "z", count: 1_048_576)
                    let answer = String(repeating: "x", count: 65_536)
                    var sequence = worker
                    var result = Counts()
                    while clock.now < endActive {
                        let label = "\(cycle)/\(worker)/\(sequence)"
                        let large = sequence % 257 == 0
                        let response = sequence % 127 == 0
                        let token = large ? label + payload : label
                        let start = clock.now
                        try await verify(client, token: token, response: response ? answer : nil,
                                         responseBytes: response ? answer.utf8.count : nil)
                        result.record(microseconds(start.duration(to: clock.now)),
                                      bytes: token.utf8.count + (response ? answer.utf8.count : token.utf8.count))
                        sequence += workerCount
                    }
                    return result
                }
            }
            group.addTask {
                let reply = try await client.callTool("system_publish", arguments: [
                    "stream": "alpha", "count": 128, "spacingMicros": 2000,
                ], options: .init(timeout: .seconds(5), onProgress: { _ in progress.value.withLock { $0 += 1 } }))
                guard try text(from: reply) == "128" else { throw ProbeError.invalidReply }
                return Counts()
            }
            var result = Counts()
            for try await partial in group { result.merge(partial) }
            return result
        }
        let phaseWall = microseconds(phase.duration(to: clock.now))
        let reached = try await state(client)
        let held = Task {
            do {
                _ = try await client.callTool("system_hold", options: .init(timeout: .seconds(8)))
                return false
            } catch ClientError.cancelled(.unknown) { return true }
            catch { return false }
        }
        let ready = clock.now + .seconds(2)
        while try await state(client).held == reached.held && clock.now < ready {
            try await Task.sleep(for: .milliseconds(1))
        }
        held.cancel()
        guard await held.value else { throw ProbeError.invalidReply }
        var recovery = 0
        // The adapter promises one relaunch per unexpected disconnect.
        if cycle == cycles / 2 {
            let pid = reached.pid
            let loss = clock.now
            guard belongsToDriver(pid), kill(pid, SIGKILL) == 0 else { throw ProbeError.invalidReply }
            let deadline = loss + .seconds(5)
            while reopenings.value.withLock({ $0 }) < 1 && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard interruptions.value.withLock({ $0 }) == 1, reopenings.value.withLock({ $0 }) == 1,
                  try await state(client).pid != pid, gone(pid) else { throw ProbeError.invalidReply }
            recovery = microseconds(loss.duration(to: clock.now))
        }
        let delivered = updates.value.withLock { $0 } - beforeUpdates
        let observedProgress = progress.value.withLock { $0 } - beforeProgress
        try emit(["event": "mixed_active", "epoch": cycle, "elapsed_us": microseconds(clockStart.duration(to: clock.now)),
                  "duration_us": phaseWall, "completed": counts.completed, "payload_bytes": counts.bytes,
                  "updates_attempted": 128, "updates_delivered": delivered,
                  "progress_attempted": 128, "progress_delivered": observedProgress,
                  "cancelled": 1, "recovery_us": recovery, "histogram_us": histogram(counts)])
        guard (1...128).contains(delivered), (1...128).contains(observedProgress) else {
            throw ProbeError.invalidReply
        }
        if idle > 0 { try await Task.sleep(for: .seconds(idle)) }
        try await verify(client, token: "after-idle/\(cycle)")
        try emit(["event": "mixed_idle", "epoch": cycle, "idle_s": idle])
    }
    await sub.cancel()
    let ended = await listener.value
    await client.close()
    return ended
}
#endif
