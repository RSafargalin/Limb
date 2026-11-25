#if os(macOS)
import Foundation
import Limb
import Synchronization

func text(from reply: ClientResult<ToolResult>) throws -> String {
    guard !reply.value.isError, reply.value.content.count == 1,
        case let .text(value, _, _)? = reply.value.content.first
    else { throw ProbeError.invalidReply }
    return value
}

func state(_ client: Client) async throws -> (pid: Int32, held: Int, cancelled: Int) {
    let reply = try await client.callTool("system_state", options: .init(timeout: .seconds(2)))
    let fields = try text(from: reply).split(separator: " ").compactMap { Int($0) }
    guard fields.count >= 2, let pid = Int32(exactly: fields[0]), pid > 1 else {
        throw ProbeError.invalidReply
    }
    return (pid, fields[1], fields.count > 2 ? fields[2] : 0)
}

func gone(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

func churn(_ executable: String, _ arguments: [String], expected: String) async throws -> Bool {
    let cycles = max(1, setting("OPERATIONS", 125))
    var seen = Set<Int32>()
    var errors = 0
    var total = Counts()
    for i in 0..<cycles {
        let began = clock.now
        let client = try await makeClient(executable, arguments, expected: expected)
        let pid = try await state(client).pid
        let connected = microseconds(began.duration(to: clock.now))
        try await verify(client, token: "churn/\(i)")
        await client.close()
        let deadline = clock.now + .seconds(2)
        while !gone(pid) && clock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let reaped = gone(pid)
        let novel = seen.insert(pid).inserted
        if !reaped || !novel { errors += 1 }
        total.record(microseconds(began.duration(to: clock.now)), bytes: 0)
        try emit(["event": "lifecycle", "cycle": i, "child_pid": pid, "reaped": reaped,
                  "unique_pid": novel, "connected_us": connected,
                  "duration_us": microseconds(began.duration(to: clock.now))])
    }
    try emit(["event": "churn", "completed": cycles, "errors": errors,
              "histogram_us": Dictionary(uniqueKeysWithValues: total.histogram.map { ("\($0.key)", $0.value) })])
    return errors == 0
}

func faultCase(_ executable: String, _ arguments: [String], expected: String) async throws -> Bool {
    let fault = environment["LIMB_SYSTEM_FAULT"] ?? ""
    let began = clock.now
    let client: Client
    do {
        client = try await makeClient(executable, arguments, expected: expected, recovery: true)
    } catch {
        try emit(["event": "fault", "phase": fault, "connect_error": String(describing: error),
                  "duration_us": microseconds(began.duration(to: clock.now))])
        let expected: StdioNegotiationError? = switch fault {
        case "before-handshake": .connectionLost
        case "during-handshake": .malformedResponse
        default: nil
        }
        return expected != nil && error as? StdioNegotiationError == expected
    }
    let first = try await state(client)
    let count = max(1, setting("PENDING_COUNT", 8))
    let results = await withTaskGroup(of: String.self, returning: [String: Int].self) { group in
        for i in 0..<count {
            group.addTask {
                do {
                    try await verify(client, token: "pending/\(i)")
                    return "success"
                } catch ClientError.connectionLost(.unknown) { return "connectionLostUnknown" }
                catch { return String(describing: error) }
            }
        }
        var result: [String: Int] = [:]
        for await outcome in group { result[outcome, default: 0] += 1 }
        return result
    }
    let lost = clock.now
    var second: (pid: Int32, held: Int, cancelled: Int)?
    let deadline = lost + .seconds(4)
    while clock.now < deadline {
        do {
            second = try await state(client)
            break
        } catch ClientError.recovering { try await Task.sleep(for: .milliseconds(2)) }
    }
    var resumed = false
    if second != nil {
        try await verify(client, token: "after-recovery")
        resumed = true
    }
    let recovery = microseconds(lost.duration(to: clock.now))
    await client.close()
    let recoveredNew = second.map { $0.pid != first.pid && $0.held == 0 } ?? false
    try emit(["event": "fault", "phase": fault, "initial_pid": first.pid,
              "replacement_pid": second?.pid ?? -1, "recovery_us": recovery,
              "operations": results, "old_reaped": gone(first.pid), "resumed": resumed])
    let wantedSuccess = fault == "after-full" ? 1 : 0
    return resumed && recoveredNew && gone(first.pid)
        && results["connectionLostUnknown", default: 0] == count - wantedSuccess
        && results["success", default: 0] == wantedSuccess
}

func boundaryCase(_ executable: String, _ arguments: [String], expected: String) async throws -> Bool {
    let client = try await makeClient(executable, arguments, expected: expected)
    let limit = setting("CLIENT_FRAME_LIMIT", 2 << 20)
    var actual: [String: String] = [:]
    for offset in [-1, 0, 1] {
        do {
            let reply = try await client.callTool(
                "system_echo", arguments: ["token": "boundary/", "frameBytes": JSONValue(limit + offset)],
                options: .init(timeout: .milliseconds(750)))
            let value = try text(from: reply)
            let matching = value.hasPrefix("boundary/") && value.dropFirst(9).allSatisfy { $0 == "x" }
            actual["\(offset)"] = matching ? "accepted" : "bad payload"
        } catch ClientError.timedOut(.unknown) { actual["\(offset)"] = "timedOutUnknown" }
        catch { actual["\(offset)"] = String(describing: error) }
    }
    var after = "accepted"
    do { try await verify(client, token: "after limit") }
    catch { after = String(describing: error) }
    await client.close()
    try emit(["event": "boundary", "limit": limit, "offsets": actual, "after": after])
    return actual["-1"] == "accepted" && actual["0"] == "accepted"
        && actual["1"] == "timedOutUnknown" && after == "accepted"
}

struct OpenPhase: Sendable {
    var arrived = 0
    var dispatched = 0
    var pending = 0
    var maximumPending = 0
    var dropped = 0
    var calls = Counts()
    var queue = Counts()
    var endToEnd = Counts()
}

final class OfferedTally: Sendable {
    let values = Mutex(OpenPhase())
}

func histogram(_ counts: Counts) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: counts.histogram.map { ("\($0.key)", $0.value) })
}

func offered(_ client: Client, concurrency: Int, seconds: Int) async throws -> Bool {
    let rates = (environment["LIMB_SYSTEM_RATES"] ?? "1000,5000,10000,20000,40000,80000,1000")
        .split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 && $0 <= 1_000_000 }
    guard !rates.isEmpty else { throw ProbeError.invalidArguments }
    for (index, rate) in rates.enumerated() {
        let state = OfferedTally()
        let start = clock.now
        let total = seconds * rate
        let burst = max(1, rate / 1000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for first in stride(from: 0, to: total, by: burst) {
                try await clock.sleep(until: start + .nanoseconds(first * 1_000_000_000 / rate))
                let count = min(burst, total - first)
                let admit = state.values.withLock { phase in
                    phase.arrived += count
                    let accepted = min(count, concurrency - phase.pending)
                    phase.pending += accepted
                    phase.dispatched += accepted
                    phase.dropped += count - accepted
                    phase.maximumPending = max(phase.maximumPending, phase.pending)
                    return accepted
                }
                for sequence in first..<(first + admit) {
                    let due = start + .nanoseconds(sequence * 1_000_000_000 / rate)
                    group.addTask {
                        let begin = max(clock.now, due)
                        if clock.now < due { try await clock.sleep(until: due) }
                        let actual = max(begin, clock.now)
                        let token = "offered/\(rate)/\(sequence)"
                        var failure: String?
                        do { try await verify(client, token: token) }
                        catch { failure = String(describing: error) }
                        let end = clock.now
                        state.values.withLock { phase in
                            phase.pending -= 1
                            phase.queue.record(microseconds(due.duration(to: actual)), bytes: 0)
                            if let failure { phase.calls.errors[failure, default: 0] += 1 }
                            else {
                                phase.calls.record(microseconds(actual.duration(to: end)), bytes: 0)
                                phase.endToEnd.record(microseconds(due.duration(to: end)), bytes: 0)
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        let wall = microseconds(start.duration(to: clock.now))
        let snapshot = state.values.withLock { $0 }
        let accounted = snapshot.arrived == total && snapshot.pending == 0
            && snapshot.dispatched + snapshot.dropped == total
            && snapshot.calls.completed + snapshot.calls.errors.values.reduce(0, +) == snapshot.dispatched
        try emit(["event": "offered", "phase": index, "rate": rate, "seconds": seconds,
                  "duration_us": wall, "offered": total, "dispatched": snapshot.dispatched,
                  "rejected_by_driver": snapshot.dropped, "completed": snapshot.calls.completed,
                  "errors": snapshot.calls.errors, "peak_pending": snapshot.maximumPending,
                  "queue_us": histogram(snapshot.queue), "service_us": histogram(snapshot.calls),
                  "histogram_us": histogram(snapshot.endToEnd), "accounted": accounted])
        if !accounted { return false }
        try await verify(client, token: "between/\(rate)")
    }
    return true
}

func cancellation(_ client: Client) async throws -> Bool {
    let repeats = max(1, setting("OPERATIONS", 50))
    let batch = min(24, max(1, setting("WORKERS", 16)))
    var expected = 0
    var failures = 0
    var metrics = Counts()
    for epoch in 0..<repeats {
        let tasks = (0..<batch).map { _ in
            Task {
                do {
                    _ = try await client.callTool("system_hold", options: .init(timeout: .seconds(7)))
                    return false
                } catch ClientError.cancelled(.unknown) { return true }
                catch { return false }
            }
        }
        let deadline = clock.now + .seconds(3)
        expected += batch
        while try await state(client).held != expected {
            guard clock.now < deadline else { throw ProbeError.invalidReply }
            try await Task.sleep(for: .milliseconds(1))
        }
        let start = clock.now
        for task in tasks { task.cancel() }
        try await verify(client, token: "sibling/\(epoch)")
        for task in tasks { if await !task.value { failures += 1 } }
        let notifyDeadline = clock.now + .seconds(3)
        while try await state(client).cancelled != expected {
            guard clock.now < notifyDeadline else { throw ProbeError.invalidReply }
            try await Task.sleep(for: .milliseconds(1))
        }
        metrics.record(microseconds(start.duration(to: clock.now)), bytes: 0)
    }
    try emit(["event": "cancel", "batches": repeats, "requests": expected,
              "server_confirmed": try await state(client).cancelled, "failures": failures,
              "histogram_us": histogram(metrics)])
    return failures == 0
}

final class StreamTally: Sendable {
    let values = Mutex([String: Int]())
}

func stream(_ client: Client, slow: Bool) async throws -> Bool {
    let amount = min(100_000, max(1, setting("OPERATIONS", 1000)))
    let spacing = setting("SPACING_US", 1000)
    let buffer = max(1, setting("BUFFER", 4096))
    let uri = "fixture://system/"
    let alpha = try await client.subscribe(filter: .init(resourceSubscriptions: [uri + "alpha"]),
                                           bufferSize: slow ? 4 : buffer)
    let beta = try await client.subscribe(filter: .init(resourceSubscriptions: [uri + "beta"]), bufferSize: buffer)
    let alphaEvents = StreamTally()
    let betaEvents = StreamTally()
    let progress = ProgressTally()
    let alphaReader = slow ? nil : Task { await readEvents(alpha, received: alphaEvents) }
    let betaReader = Task { await readEvents(beta, received: betaEvents) }

    let a = Task { try await publishStream(client, "alpha", amount, spacing: spacing, phase: "baseline", progress: progress) }
    let b = Task { try await publishStream(client, "beta", amount, spacing: spacing, phase: "baseline", progress: progress) }
    defer { a.cancel(); b.cancel() }
    var echoes = Counts()
    for i in 0..<min(amount, 250) {
        let start = clock.now
        try await verify(client, token: "stream-echo/\(i)")
        echoes.record(microseconds(start.duration(to: clock.now)), bytes: 0)
        try await Task.sleep(for: .microseconds(250))
    }
    try await a.value
    try await b.value
    try await Task.sleep(for: .milliseconds(150))
    let betaBefore = betaEvents.values.withLock { $0 }
    let aError: String
    if let alphaReader {
        await alpha.cancel()
        aError = await alphaReader.value
    } else {
        let closeIfMissingOverflow = Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            await alpha.cancel()
        }
        aError = await readEvents(alpha, received: alphaEvents)
        closeIfMissingOverflow.cancel()
        await closeIfMissingOverflow.value
        await alpha.cancel()
    }
    let alphaBefore = alphaEvents.values.withLock { $0 }
    try await publishStream(client, "beta", 10, spacing: spacing, phase: "remaining", progress: progress)
    try await publishStream(client, "alpha", 10, spacing: spacing, phase: "cancelled", progress: progress)
    try await Task.sleep(for: .milliseconds(150))
    await beta.cancel()
    let bError = await betaReader.value
    let afterA = alphaEvents.values.withLock { $0 }
    let afterB = betaEvents.values.withLock { $0 }
    let progressCounts = progress.values.withLock { current in
        current.mapValues { values in
            ["delivered": values.count, "first": values.first ?? 0, "last": values.last ?? 0,
             "nonIncreasing": zip(values, values.dropFirst()).filter { $0.0 >= $0.1 }.count]
        }
    }
    try emit(["event": "stream", "attempted_each": amount, "spacing_us": spacing, "slow": slow,
              "alpha": alphaBefore, "beta": betaBefore, "alpha_after_cancel": afterA, "beta_after": afterB,
              "alpha_error": aError, "beta_error": bError, "progress": progressCounts,
              "echo_completed": echoes.completed, "histogram_us": histogram(echoes)])
    let keyA = "updated/" + uri + "alpha"
    let keyB = "updated/" + uri + "beta"
    let gotA = alphaBefore[keyA, default: 0]
    let gotB = betaBefore[keyB, default: 0]
    // This paced fixture has a 99% delivery target. The protocol allows coalescing.
    let minimum = (amount * 99 + 99) / 100
    let alphaGood = slow
        ? alphaBefore.values.reduce(0, +) == 4 && aError.contains("bufferOverflow")
        : (minimum...amount).contains(gotA) && aError.isEmpty
    let expectedProgress = ["alpha/baseline": amount, "beta/baseline": amount,
                            "alpha/cancelled": 10, "beta/remaining": 10]
    let progressGood = expectedProgress.allSatisfy { name, count in
        guard let row = progressCounts[name], let n = row["delivered"], let first = row["first"],
              let last = row["last"] else { return false }
        return ((count * 99 + 99) / 100...count).contains(n)
            && (1...count).contains(first) && (first...count).contains(last) && row["nonIncreasing"] == 0
    }
    return alphaGood && (minimum...amount).contains(gotB)
        && afterB[keyB, default: 0] > gotB && bError.isEmpty
        && alphaBefore.keys.allSatisfy { $0.hasSuffix("/" + uri + "alpha") }
        && betaBefore.keys.allSatisfy { $0.hasSuffix("/" + uri + "beta") }
        && progressGood
}

final class ProgressTally: Sendable {
    let values = Mutex([String: [Int]]())
}

func publishStream(
    _ client: Client, _ which: String, _ count: Int, spacing: Int, phase: String, progress: ProgressTally
) async throws {
    let reply = try await client.callTool(
        "system_publish", arguments: [
            "stream": .string(which), "count": JSONValue(count), "spacingMicros": JSONValue(spacing),
        ], options: .init(timeout: .seconds(30), onProgress: { value in
            if let sequence = Int(exactly: value.progress) {
                progress.values.withLock { $0[which + "/" + phase, default: []].append(sequence) }
            }
        }))
    guard try text(from: reply) == String(count) else { throw ProbeError.invalidReply }
}

func readEvents(_ subscription: ClientSubscription, received: StreamTally) async -> String {
    do {
        for try await event in subscription {
            let key: String
            switch event {
            case .resourceUpdated(let uri): key = "updated/" + uri
            case .resourceInvalidated(let uri): key = "invalidated/" + uri
            default: key = String(describing: event)
            }
            received.values.withLock { $0[key, default: 0] += 1 }
        }
        return ""
    } catch { return String(describing: error) }
}

func liveRecovery(_ executable: String, _ arguments: [String], expected: String) async throws -> Bool {
    let cycles = max(1, setting("OPERATIONS", 8))
    let count = min(16, max(1, setting("WORKERS", 8)))
    let uri = "fixture://system/alpha"
    let filter = ClientSubscriptionFilter(resourceSubscriptions: [uri])
    for cycle in 0..<cycles {
        let client = try await makeClient(executable, arguments, expected: expected, recovery: true)
        let before = try await state(client)
        let subscription = try await client.subscribe(filter: filter, bufferSize: 32)
        let restoredLease = Mutex(false)
        let events = Task { () throws -> [String] in
            var observed: [String] = []
            for try await event in subscription {
                switch event {
                case .interrupted: observed.append("interrupted")
                case .resubscribed(confirmedFilter: let actual) where actual == filter:
                    observed.append("resubscribed")
                    restoredLease.withLock { $0 = true }
                case .resourceUpdated(let actual) where actual == uri: observed.append("updated")
                default: observed.append("unexpected")
                }
                if observed.count >= 3 { return observed }
            }
            return observed
        }
        let held = (0..<count).map { _ in
            Task {
                do {
                    _ = try await client.callTool("system_hold", options: .init(timeout: .seconds(8)))
                    return false
                } catch ClientError.connectionLost(.unknown) { return true }
                catch { return false }
            }
        }
        let readyDeadline = clock.now + .seconds(3)
        while try await state(client).held < count {
            guard clock.now < readyDeadline else { throw ProbeError.invalidReply }
            try await Task.sleep(for: .milliseconds(1))
        }
        let signalAt = clock.now
        guard belongsToDriver(before.pid), kill(before.pid, SIGKILL) == 0 else { throw ProbeError.invalidReply }
        var closed = 0
        for task in held { if await task.value { closed += 1 } }
        var after: (pid: Int32, held: Int, cancelled: Int)?
        let opensUntil = clock.now + .seconds(5)
        while clock.now < opensUntil {
            do {
                let current = try await state(client)
                if current.pid != before.pid { after = current; break }
            } catch ClientError.recovering {}
            try await Task.sleep(for: .milliseconds(1))
        }
        let restored = after != nil
        if restored {
            try await verify(client, token: "post-kill/\(cycle)")
            let wait = clock.now + .seconds(2)
            while !restoredLease.withLock({ $0 }) && clock.now < wait {
                try await Task.sleep(for: .milliseconds(1))
            }
            if restoredLease.withLock({ $0 }) {
                let reply = try await client.callTool("system_publish", arguments: [
                    "stream": "alpha", "count": 1, "spacingMicros": 0,
                ], options: .init(timeout: .seconds(2)))
                _ = try text(from: reply)
            }
        }
        await subscription.cancel()
        let observed = try await events.value
        let delay = microseconds(signalAt.duration(to: clock.now))
        await client.close()
        let result = restored && after?.held == 0 && gone(before.pid) && closed == count
            && observed == ["interrupted", "resubscribed", "updated"]
        try emit(["event": "live_recovery", "cycle": cycle, "pid": before.pid,
                  "replacement_pid": after?.pid ?? -1, "reaped": gone(before.pid), "held": count,
                  "ended_connection_lost": closed, "events": observed, "recovery_us": delay, "pass": result])
        if !result { return false }
    }
    return true
}
#endif
