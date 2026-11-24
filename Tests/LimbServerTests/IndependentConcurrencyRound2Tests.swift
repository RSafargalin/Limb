#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

// Tests written against the second version of the engine: separate urgent accounting, the
// drain deadline of `Server.run`, halting at an input point, and closing with requests that
// wait at the server-wide gate.

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
private let formSchema: JSONObject = ["type": "object", "properties": ["v": ["type": "string"]]]
private let allInputs: JSONObject = ["elicitation": ["form": [:], "url": [:]], "sampling": [:], "roots": [:]]

private struct R2Random {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x55AA }
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

// MARK: - Outbound accounting

/// `OutboundQueue`: ordinary and urgent bytes are counted apart, and both counts must come back
/// to exactly zero whatever was queued, withdrawn, taken and written in between.
@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyOutboundAccountingTests {
    private struct ModelEntry {
        var frame: [UInt8]
        var key: RequestID?
        var urgent: Bool
        var progress: Bool
    }

    @Test func bothCountersReturnToZeroAfterEveryMixOfOperations() async {
        let budget = 50
        let reserve = 40
        for seed in 0..<300 {
            var random = R2Random(seed: UInt64(seed))
            let queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: reserve)
            var queued: [ModelEntry] = []
            var ordinary = 0  // queued or taken, not yet written
            var urgent = 0
            var takenOrdinary = 0
            var takenUrgent = 0
            var sequence: UInt8 = 0
            var failure: String?
            func check(_ condition: Bool, _ message: @autoclosure () -> String) {
                if !condition, failure == nil { failure = message() }
            }
            for step in 0..<250 {
                let key: RequestID? = random.below(5) == 0 ? nil : RequestID(random.below(4))
                sequence &+= 1
                switch random.below(12) {
                case 0, 1, 2, 3:
                    let frame = [UInt8](repeating: sequence, count: random.below(21))
                    check(queue.enqueue(frame, key: key), "step \(step): ordinary enqueue refused")
                    queued.append(ModelEntry(frame: frame, key: key, urgent: false, progress: false))
                    ordinary += frame.count
                case 4, 5:
                    let frame = [UInt8](repeating: sequence, count: 1 + random.below(20))
                    check(queue.enqueue(frame, key: key, urgent: false, replacesProgress: true), "step \(step): progress refused")
                    if let key, let index = queued.lastIndex(where: { $0.progress && $0.key == key }) {
                        ordinary += frame.count - queued[index].frame.count
                        queued[index].frame = frame
                    } else {
                        queued.append(ModelEntry(frame: frame, key: key, urgent: false, progress: true))
                        ordinary += frame.count
                    }
                case 6, 7:
                    let frame = [UInt8](repeating: sequence, count: random.below(16))
                    let fits = urgent + frame.count <= reserve
                    // An urgent frame is queued under whatever key it was given.
                    let urgentKey = random.below(3) == 0 ? key : nil
                    check(
                        queue.enqueue(frame, key: urgentKey, urgent: true) == fits,
                        "step \(step): urgent frame of \(frame.count) bytes with \(urgent) of \(reserve) reserved bytes in use")
                    if fits {
                        queued.append(ModelEntry(frame: frame, key: urgentKey, urgent: true, progress: false))
                        urgent += frame.count
                    }
                case 8:
                    guard let key else { continue }
                    queue.discard(key: key)
                    for entry in queued where entry.key == key {
                        if entry.urgent { urgent -= entry.frame.count } else { ordinary -= entry.frame.count }
                    }
                    queued.removeAll { $0.key == key }
                case 9, 10:
                    let frames = queue.takeAvailable()
                    check(frames == queued.map(\.frame), "step \(step): the writer got \(frames.count) frames, expected \(queued.count)")
                    for entry in queued {
                        if entry.urgent { takenUrgent += entry.frame.count } else { takenOrdinary += entry.frame.count }
                    }
                    queued = []
                default:
                    queue.didWrite(bytes: takenOrdinary + takenUrgent)
                    ordinary -= takenOrdinary
                    urgent -= takenUrgent
                    takenOrdinary = 0
                    takenUrgent = 0
                }
                check(queue.isOverBudget == (ordinary > budget), "step \(step): isOverBudget is \(queue.isOverBudget) with \(ordinary) ordinary bytes pending")
            }
            // Everything out and written: both counters must be exactly zero again. A count that
            // drifted up shows as a refusal below the limit; one that drifted down, as room above it.
            let rest = queue.takeAvailable()
            check(rest == queued.map(\.frame), "final take")
            queue.didWrite(bytes: rest.reduce(0) { $0 + $1.count })
            check(!queue.isOverBudget, "over budget with nothing pending")
            check(queue.enqueue([UInt8](repeating: 1, count: budget)), "ordinary refused")
            check(!queue.isOverBudget, "exactly the budget counts as over budget: the ordinary counter did not return to zero")
            check(queue.enqueue([2]), "ordinary refused")
            check(queue.isOverBudget, "one byte over the budget is not over budget: the ordinary counter went below zero")
            check(queue.enqueue([UInt8](repeating: 3, count: reserve), key: nil, urgent: true), "the urgent counter did not return to zero")
            check(queue.enqueue([4], key: nil, urgent: true) == false, "the urgent counter went below zero")
            #expect(failure == nil, "seed \(seed): \(failure ?? "")")
            if failure != nil { break }
        }
    }

    /// An urgent frame that was given a key is withdrawn with its request and gives its bytes back.
    @Test func discardReturnsTheBytesOfUrgentFramesToo() {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 10)
        #expect(queue.enqueue([UInt8](repeating: 1, count: 10), key: 7, urgent: true))
        #expect(queue.enqueue([2], key: nil, urgent: true) == false)
        queue.discard(key: 7)
        #expect(queue.takeAvailable().isEmpty)
        #expect(queue.enqueue([UInt8](repeating: 3, count: 10), key: nil, urgent: true))
        #expect(queue.enqueue([4], key: nil, urgent: true) == false)
    }

    @Test func progressAfterTheWriterTookTheEarlierValueIsQueuedAnew() async {
        let queue = OutboundQueue(budgetBytes: 100, urgentReserveBytes: 10)
        func progress(_ text: String, _ key: RequestID) { queue.enqueue(Array(text.utf8), key: key, urgent: false, replacesProgress: true) }
        func text(_ frames: [[UInt8]]) -> [String] { frames.map { String(decoding: $0, as: UTF8.self) } }
        progress("a1", 1)
        progress("b1", 2)
        queue.enqueue(Array("log".utf8), key: 1)
        progress("a2", 1)
        // One progress frame per request, the latest value, in the place of the first.
        #expect(text(queue.takeAvailable()) == ["a2", "b1", "log"])
        // The writer holds those. A newer value is a new frame, not a change to what is being written.
        progress("a3", 1)
        progress("a4", 1)
        progress("b2", 2)
        #expect(text(queue.takeAvailable()) == ["a4", "b2"])
        queue.didWrite(bytes: 11)
        // Withdrawing a request removes its queued progress, and the next value starts afresh.
        progress("a5", 1)
        progress("b3", 2)
        queue.discard(key: 1)
        progress("a6", 1)
        progress("a7", 1)
        #expect(text(queue.takeAvailable()) == ["b3", "a7"])
        queue.didWrite(bytes: 4)
        // A thousand reports cost the queue one frame.
        for value in 0..<1000 { progress("p\(value)", 3) }
        #expect(!queue.isOverBudget)
        #expect(text(queue.takeAvailable()) == ["p999"])
        queue.didWrite(bytes: 4)
        #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await queue.waitForCapacity() })
    }

    @Test func subscriptionNotificationsAreBoundedWhenThePeerDoesNotRead() async throws {
        let server = independentConcurrencyServer()
        try server.register(resource: ResourceDefinition(uri: "ic://watched", name: "watched")) { _, _ in [] }
        let queue = OutboundQueue(budgetBytes: 10_000, urgentReserveBytes: 2000)
        let connection = server.connect(to: queue)
        connection.receive(
            Array(
                #"{"jsonrpc":"2.0","id":1,"method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["ic://watched"]},\#(modernMeta)}}"#
                    .utf8))
        for round in 0..<5000 {
            server.notifyResourceUpdated(uri: "ic://watched")
            if round % 10 == 0 {
                try server.register(tool: ToolDefinition(name: "t\(round)")) { _, _ in .text("") }
            }
        }
        let frames = queue.takeAvailable()
        let bytes = frames.reduce(0) { $0 + $1.count }
        #expect(
            bytes <= 10_000 + 2000 + 1000,
            "\(bytes) bytes (\(frames.count) frames) of notifications are queued for a peer that is not reading; the budget is 10000")
        // The reader can still answer.
        connection.receive(Array(#"{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{\#(modernMeta)}}"#.utf8))
        let overflowed = connection.hasOverflowed
        #expect(!overflowed)
        await connection.close(graceSeconds: 0)
    }
}

// MARK: - The drain deadline of Server.run

/// One stdio session whose descriptors the test owns, as a socket server would.
private final class ManualSession: @unchecked Sendable {
    let toServer: (read: Int32, write: Int32)
    let fromServer: (read: Int32, write: Int32)
    let returned = ICBox(false)
    private var pending: [UInt8] = []
    private var scanned = 0
    private var scratch = [UInt8](repeating: 0, count: 1 << 20)

    /// - Parameter outputDescriptor: if given, the session's output is moved onto that descriptor
    ///   number, replacing whatever it referred to — what the kernel does when a number is reused.
    init(_ server: Server, outputDescriptor: Int32? = nil) {
        signal(SIGPIPE, SIG_IGN)
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        precondition(pipe(&input) == 0 && pipe(&output) == 0)
        if let outputDescriptor, output[1] != outputDescriptor {
            precondition(dup2(output[1], outputDescriptor) == outputDescriptor)
            close(output[1])
            output[1] = outputDescriptor
        }
        toServer = (input[0], input[1])
        fromServer = (output[0], output[1])
        let transport = StdioTransport(input: input[0], output: output[1])
        let returned = returned
        Task.detached {
            await server.run(transport)
            returned.set(true)
        }
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(toServer.write, $0.baseAddress! + offset, bytes.count - offset) }
            guard written > 0 else { return }
            offset += written
        }
    }

    func call(_ id: String, _ tool: String) {
        send(#"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(tool)",\#(modernMeta)}}"# + "\n")
    }

    /// Reads up to `limit` bytes if any arrive within the timeout.
    func readChunk(limit: Int, timeoutMilliseconds: Int32) -> Int {
        var descriptor = pollfd(fd: fromServer.read, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = read(fromServer.read, &buffer, limit)
        guard count > 0 else { return -1 }
        pending.append(contentsOf: buffer[..<count])
        return count
    }

    /// Reads and throws away whatever is there, as fast as the pipe gives it. Returns `false` at
    /// end of stream.
    func discardAvailable(timeoutMilliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fromServer.read, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return true }
        return scratch.withUnsafeMutableBytes { read(fromServer.read, $0.baseAddress, $0.count) } > 0
    }

    /// Complete lines received so far.
    func takeLines() -> [[UInt8]] {
        var lines: [[UInt8]] = []
        while let newline = pending[scanned...].firstIndex(of: 0x0A) {
            lines.append(Array(pending[..<newline]))
            pending.removeSubrange(...newline)
            scanned = 0
        }
        scanned = pending.count
        return lines
    }

    var unterminatedBytes: Int { pending.count }

    func hasReturned(within seconds: Double) async -> Bool {
        let returned = returned
        return await independentConcurrencyEventually(timeout: .milliseconds(Int(seconds * 1000))) { returned.value }
    }
}

@Suite(.timeLimit(.minutes(5)), .serialized)
struct IndependentConcurrencyDrainTests {
    private func blobServer(drain: Double, diagnostics: ICBox<[String]> = ICBox([])) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.shutdownGraceSeconds = 0.3
            configuration.outputDrainSeconds = drain
            configuration.budgets.maxQueuedRequests = 100_000
            configuration.budgets.maxOutboundBytes = 256 << 20
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 200_000)) }
        // Larger than what the writer batches, smaller than a pipe: usually written without waiting.
        try server.register(tool: ToolDefinition(name: "medium")) { _, _ in .text(String(repeating: "m", count: 40_000)) }
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        return server
    }

    @Test func aPeerThatNeverReadsIsGivenUpAfterTheDrainDeadlineAndNotBefore() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = ManualSession(try blobServer(drain: 1.0, diagnostics: diagnostics))
        for index in 0..<6 { session.call("a\(index)", "blob") }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        close(session.toServer.write)
        #expect(await session.hasReturned(within: 20), "Server.run did not return after the drain deadline")
        // Not before the deadline: the peer had its second to start reading.
        #expect(clock.now - start >= .milliseconds(900))
        #expect(diagnostics.value.contains { $0.contains("did not read") })
        // Unblock the writer that was left behind, then give the descriptors back.
        close(session.fromServer.read)
        try await Task.sleep(for: .milliseconds(200))
        close(session.toServer.read)
        close(session.fromServer.write)
    }

    @Test func aDrainDeadlineOfZeroReturnsAtOnceAndDoesNotHang() async throws {
        for drain in [0.0, -1.0] {
            let session = ManualSession(try blobServer(drain: drain))
            for index in 0..<4 { session.call("z\(index)", "blob") }
            try await Task.sleep(for: .milliseconds(200))
            close(session.toServer.write)
            #expect(await session.hasReturned(within: 20), "outputDrainSeconds = \(drain)")
            close(session.fromServer.read)
            try await Task.sleep(for: .milliseconds(200))
            close(session.toServer.read)
            close(session.fromServer.write)
        }
    }

    @Test func aPeerThatReadsSteadilyButSlowlyStillGetsEveryResponse() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = ManualSession(try blobServer(drain: 1.0, diagnostics: diagnostics))
        let calls = 30  // 6 MB of responses
        for index in 0..<calls { session.call("s\(index)", "blob") }
        close(session.toServer.write)
        struct Outcome: Sendable {
            var complete = 0
            var damaged = 0
            var leftover = 0
            var returnedWhileReading = false
        }
        let outcome: Outcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var outcome = Outcome()
                var released = false
                // 64 KiB every 25 ms: about 2.5 MB/s, never idle, done in under three seconds.
                while true {
                    let count = session.readChunk(limit: 65536, timeoutMilliseconds: 3000)
                    if count <= 0 { break }
                    for line in session.takeLines() {
                        if (try? JSON.parse(line))?["result"]?["content"]?[0]?["text"]?.stringValue?.utf8.count == 200_000 {
                            outcome.complete += 1
                        } else {
                            outcome.damaged += 1
                        }
                    }
                    if session.returned.value, !released {
                        // `run` is back: the caller closes its descriptors, as a process exit would.
                        released = true
                        outcome.returnedWhileReading = outcome.complete < calls
                        close(session.toServer.read)
                        close(session.fromServer.write)
                    }
                    usleep(25_000)
                }
                outcome.leftover = session.unterminatedBytes
                if !released {
                    close(session.toServer.read)
                    close(session.fromServer.write)
                }
                close(session.fromServer.read)
                continuation.resume(returning: outcome)
            }
        }
        #expect(
            outcome.complete == calls,
            "a peer that was reading all along received \(outcome.complete) of \(calls) responses (\(outcome.leftover) bytes of a cut-off frame); run returned while it was still reading: \(outcome.returnedWhileReading)")
        #expect(outcome.damaged == 0)
        // Since the writer has its own descriptor it outlives `run` inside this process; in a
        // real process the output would end with `run`. So `run` must not have given up at all.
        #expect(diagnostics.value.isEmpty, "run gave up on a peer that was reading: \(diagnostics.value)")
        _ = await session.hasReturned(within: 10)
    }

    /// After `run` has returned, the transport's descriptors are the caller's again. A server
    /// that accepts connections closes them, and the kernel hands the same numbers to the next
    /// connection. Nothing of the finished session may ever be written there.
    @Test func anAbandonedWriterNeverWritesToADescriptorNumberThatWasReused() async throws {
        let server = try blobServer(drain: 0.3)
        let first = ManualSession(server)
        for index in 0..<6 { first.call("first-\(index)", "blob") }
        try await Task.sleep(for: .milliseconds(200))
        close(first.toServer.write)
        #expect(await first.hasReturned(within: 20))
        close(first.toServer.read)

        // The next session gets the first one's output descriptor number: `dup2` closes the old
        // descriptor and reuses its number in one step, so no other code can take it in between.
        let second = ManualSession(server, outputDescriptor: first.fromServer.write)
        second.call("second-0", "echo")
        var lines: [[UInt8]] = []
        let deadline = ContinuousClock.now + .seconds(10)
        while lines.isEmpty, ContinuousClock.now < deadline {
            _ = second.readChunk(limit: 65536, timeoutMilliseconds: 100)
            lines += second.takeLines()
        }
        #expect((try? JSON.parse(lines.first ?? []))?["id"] == "second-0")

        // Now the first peer finally reads what was stuck in its pipe, which lets the writer
        // that was left behind continue with the frames it still holds.
        for _ in 0..<200 {
            if first.readChunk(limit: 1 << 20, timeoutMilliseconds: 50) <= 0 { break }
        }
        // Whatever arrives on the second session must be its own.
        second.call("second-1", "echo")
        var foreign = 0
        var foreignBytes = 0
        var own = 0
        let quiet = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < quiet {
            let count = second.readChunk(limit: 1 << 20, timeoutMilliseconds: 100)
            if count < 0 { break }
            for line in second.takeLines() {
                if (try? JSON.parse(line))?["id"] == "second-1" {
                    own += 1
                } else {
                    foreign += 1
                    foreignBytes += line.count
                }
            }
        }
        foreignBytes += second.unterminatedBytes
        #expect(
            foreign == 0 && second.unterminatedBytes == 0,
            "the second session received \(foreign) lines (\(foreignBytes) bytes) that belong to the first session: its abandoned writer wrote to the reused descriptor")
        #expect(own == 1)
        close(second.toServer.write)
        _ = await second.hasReturned(within: 10)
        close(first.fromServer.read)
        close(second.fromServer.read)
        try await Task.sleep(for: .milliseconds(200))
        close(second.toServer.read)
        close(second.fromServer.write)
    }

    /// The same, when the writer that `run` left behind is not stuck but busy: the peer reads,
    /// only not fast enough to be done by the deadline (here the deadline is zero). The caller
    /// gets its descriptors back when `run` returns; the next connection reuses the number.
    @Test func aWriterLeftBehindWhileStillWritingNeverWritesToAReusedDescriptor() async throws {
        let server = try blobServer(drain: 0)
        var strayBytes = 0
        var attempts = 0
        while attempts < 30, strayBytes == 0 {
            attempts += 1
            let first = ManualSession(server)
            let calls = 600  // 24 MB of responses, in frames that fit a pipe
            for index in 0..<calls { first.call("first-\(index)", "medium") }
            // The first peer reads all the time, as fast as it can: the writer is busy, not stuck.
            let stopReading = ICBox(false)
            let readerDone = ICBox(false)
            let attempt = attempts
            Thread.detachNewThread {
                // A different pace on every attempt, to meet the writer in a different phase.
                let pause = UInt32([0, 0, 20, 50, 100, 200][attempt % 6])
                while !stopReading.value {
                    if !first.discardAvailable(timeoutMilliseconds: 50) { break }
                    if pause > 0 { usleep(pause) }
                }
                readerDone.set(true)
            }
            close(first.toServer.write)
            #expect(await first.hasReturned(within: 30))
            close(first.toServer.read)
            // The caller lets go of the output descriptor and the next session gets its number.
            let second = ManualSession(server, outputDescriptor: first.fromServer.write)
            second.call("second-0", "echo")
            var own = 0
            let quiet = ContinuousClock.now + .milliseconds(400)
            while ContinuousClock.now < quiet {
                let count = second.readChunk(limit: 1 << 20, timeoutMilliseconds: 50)
                if count < 0 { break }
                for line in second.takeLines() {
                    if (try? JSON.parse(line))?["id"] == "second-0" { own += 1 } else { strayBytes += line.count + 1 }
                }
            }
            strayBytes += second.unterminatedBytes
            #expect(own == 1 || strayBytes > 0)
            // Wind both sessions down: drain what the stray writer may still be pushing.
            close(second.toServer.write)
            var idle = 0
            while idle < 3 {
                let count = second.readChunk(limit: 1 << 20, timeoutMilliseconds: 50)
                if count < 0 { break }
                idle = count == 0 ? idle + 1 : 0
                _ = second.takeLines()
            }
            stopReading.set(true)
            _ = await independentConcurrencyEventually { readerDone.value }
            _ = await second.hasReturned(within: 10)
            close(first.fromServer.read)
            close(second.fromServer.read)
            try await Task.sleep(for: .milliseconds(50))
            close(second.toServer.read)
            close(second.fromServer.write)
        }
        #expect(
            strayBytes == 0,
            "attempt \(attempts): \(strayBytes) bytes of the first session's responses were written into the second session's stream")
    }

    @Test func manySessionsInOneProcessAfterAbandonedWritersStillWork() async throws {
        let server = try blobServer(drain: 0.1)
        var abandoned: [ManualSession] = []
        for round in 0..<6 {
            let stuck = ManualSession(server)
            for index in 0..<4 { stuck.call("stuck-\(round)-\(index)", "blob") }
            try await Task.sleep(for: .milliseconds(100))
            close(stuck.toServer.write)
            #expect(await stuck.hasReturned(within: 20), "round \(round)")
            abandoned.append(stuck)
            // A healthy session right after it gets every handler slot it needs and its answer.
            let healthy = ManualSession(server)
            healthy.call("ok-\(round)", "echo")
            var answer: JSONValue?
            let deadline = ContinuousClock.now + .seconds(10)
            while answer == nil, ContinuousClock.now < deadline {
                _ = healthy.readChunk(limit: 65536, timeoutMilliseconds: 100)
                answer = healthy.takeLines().first.flatMap { try? JSON.parse($0) }
            }
            #expect(answer?["id"] == .string("ok-\(round)"), "round \(round): a session after an abandoned one got no answer")
            close(healthy.toServer.write)
            #expect(await healthy.hasReturned(within: 20), "round \(round)")
            close(healthy.fromServer.read)
            close(healthy.toServer.read)
            close(healthy.fromServer.write)
        }
        // Release the writers that were left behind before their descriptors are closed.
        for session in abandoned { close(session.fromServer.read) }
        try await Task.sleep(for: .milliseconds(300))
        for session in abandoned {
            close(session.toServer.read)
            close(session.fromServer.write)
        }
    }
}

// MARK: - Halting at an input point, with child and detached tasks

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyHaltTests {
    @Test func childAndDetachedTasksOfAHaltedRunAreSilencedAndChildrenAreCancelled() async throws {
        let diagnostics = ICBox<[String]>([])
        let childCancelled = ICBox<Bool?>(nil)
        let detachedDone = ICMeter()
        let release = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
        }
        try server.register(tool: ToolDefinition(name: "family")) { _, context in
            context.progress(1)
            // A structured child that works until it is cancelled.
            async let child: Bool = {
                while !Task.isCancelled { await Task.yield() }
                context.progress(50)
                context.log(.error, "from the child after the halt")
                return true
            }()
            // Unstructured tasks do not see the cancellation; they report after the input point.
            Task.detached {
                await release.wait()
                context.progress(60)
                context.log(.error, "from a detached task after the halt")
                detachedDone.enter()
            }
            Task {
                await release.wait()
                context.progress(70)
                context.log(.error, "from an unstructured task after the halt")
                detachedDone.enter()
            }
            _ = try? await context.elicit("k", message: "?", schema: formSchema)
            childCancelled.set(await child)
            release.open()
            // Keep the request open until the stragglers have reported.
            while detachedDone.total < 2 { await Task.yield() }
            context.progress(80)
            return .text("discarded")
        }
        let wire = ICWire(server, capabilities: allInputs)
        let id = wire.call("family", meta: ["progressToken": "t", MetaKey.logLevel: "debug"])
        let response = try await wire.response(to: id)
        #expect(response["result"]?["resultType"] == "input_required")
        #expect(childCancelled.value == true, "the structured child of a halted run was not cancelled")
        #expect(await wire.isSilent(for: .milliseconds(100)))
        let notifications = wire.sink.history.compactMap(\.json).filter { $0["method"] != nil }
        #expect(notifications.map { $0["params"]?["progress"]?.doubleValue } == [1], "sent: \(notifications.map { $0.encoded().count })")
        #expect(!notifications.contains { $0["method"] == "notifications/message" })
        #expect(diagnostics.value.contains { $0.contains("family") })
    }

    @Test func aRunThatEndsAtItsInputPointProperlyIsNotDiagnosed() async throws {
        let diagnostics = ICBox<[String]>([])
        let server = independentConcurrencyServer { configuration in
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
        }
        try server.register(tool: ToolDefinition(name: "proper")) { _, context in
            let answer = try await context.elicit("k", message: "?", schema: formSchema)
            return .text(answer.action.rawValue)
        }
        try server.register(prompt: PromptDefinition(name: "swallowing_prompt")) { _, context in
            _ = try? await context.elicit("k", message: "?", schema: formSchema)
            return PromptResult(messages: [])
        }
        try server.register(resource: ResourceDefinition(uri: "ic://swallowing", name: "swallowing")) { _, context in
            _ = try? await context.elicit("k", message: "?", schema: formSchema)
            return []
        }
        let wire = ICWire(server, capabilities: allInputs)
        #expect(try await wire.request("tools/call", ["name": "proper"])["result"]?["resultType"] == "input_required")
        #expect(diagnostics.value.isEmpty, "a handler that followed the rule was diagnosed: \(diagnostics.value)")
        // A swallowed input point is named for prompts and resources as well.
        #expect(try await wire.request("prompts/get", ["name": "swallowing_prompt"])["result"]?["resultType"] == "input_required")
        #expect(diagnostics.value.contains { $0.contains("swallowing_prompt") })
        #expect(try await wire.request("resources/read", ["uri": "ic://swallowing"])["result"]?["resultType"] == "input_required")
        #expect(diagnostics.value.contains { $0.contains("ic://swallowing") })
    }

    /// A handler cancelled at its input point may still be waiting on something that does not
    /// honour cancellation. The `InputRequiredResult` is sent when it ends, and the halted
    /// request does not answer twice or leave its slot taken.
    @Test func aHaltedRunThatLingersAnswersOnceWhenItEnds() async throws {
        let gate = ICGate()
        let reached = ICMeter()
        let server = independentConcurrencyServer { $0.budgets.maxConcurrentHandlers = 1 }
        try server.register(tool: ToolDefinition(name: "lingers")) { _, context in
            _ = try? await context.elicit("k", message: "?", schema: formSchema)
            reached.enter()
            await gate.wait()
            return .text("discarded")
        }
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        let wire = ICWire(server, capabilities: allInputs)
        let id = wire.call("lingers")
        #expect(await independentConcurrencyEventually { reached.total == 1 })
        let waiting = wire.call("echo")
        #expect(await wire.isSilent(for: .milliseconds(80)))
        gate.open()
        let first = try await wire.next()
        #expect(first["id"] == id.json)
        #expect(first["result"]?["resultType"] == "input_required")
        #expect(try await wire.response(to: waiting).independentConcurrencyText == "ok")
        #expect(await wire.isSilent())
    }

    @Test func detachedTasksCannotAskTheClientOnceTheirCallIsAnsweredOrCancelled() async throws {
        let release = ICGate()
        let outcomes = ICBox<[String]>([])
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "leaves_tasks")) { arguments, context in
            let tag = arguments["tag"]?.stringValue ?? "?"
            for kind in ["detached", "unstructured"] {
                let work: @Sendable () async -> Void = {
                    await release.wait()
                    do {
                        _ = try await context.elicit("k", message: "late \(tag)", schema: formSchema)
                        outcomes.update { $0.append("\(tag) \(kind): answered") }
                    } catch {
                        outcomes.update { $0.append("\(tag) \(kind): refused") }
                    }
                }
                if kind == "detached" { Task.detached { await work() } } else { Task { await work() } }
            }
            if tag == "cancelled" { try await Task.sleep(for: .seconds(300)) }
            return .text("answered \(tag)")
        }
        let wire = ICWire(server, modern: false)
        try await wire.initialize(capabilities: ["elicitation": [:]])
        #expect(try await wire.request("tools/call", ["name": "leaves_tasks", "arguments": ["tag": "answered"]]).independentConcurrencyText == "answered answered")
        let cancelled = wire.call("leaves_tasks", ["tag": "cancelled"])
        wire.cancel(cancelled)
        let mark = wire.sink.mark
        release.open()
        #expect(await independentConcurrencyEventually { outcomes.value.count == 4 }, "\(outcomes.value)")
        #expect(outcomes.value.allSatisfy { $0.hasSuffix("refused") }, "\(outcomes.value)")
        #expect(await wire.isSilent(for: .milliseconds(100)))
        #expect(wire.sink.history.count == mark)
    }

    /// A request to the client that a detached task of a call sent *before* the call was
    /// cancelled is withdrawn like the ones the handler itself is waiting for: the client is
    /// told, and the task is released.
    @Test func aPendingRequestOfADetachedTaskIsWithdrawnWhenItsCallIsCancelled() async throws {
        let outcome = ICBox<String?>(nil)
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "asks_detached")) { _, context in
            Task.detached {
                do {
                    _ = try await context.elicit("k", message: "from a detached task", schema: formSchema)
                    outcome.set("answered")
                } catch {
                    outcome.set("released")
                }
            }
            try await Task.sleep(for: .seconds(300))
            return .text("never")
        }
        let wire = ICWire(server, modern: false)
        try await wire.initialize(capabilities: ["elicitation": [:]])
        let call = wire.call("asks_detached")
        let request = try await wire.next()
        #expect(request["method"] == "elicitation/create")
        wire.cancel(call)
        let withdrawn = await wire.sink.next(timeout: .seconds(2))
        #expect(withdrawn?.json?["method"] == "notifications/cancelled", "the client was not told that the request is no longer wanted")
        #expect(withdrawn?.json?["params"]?["requestId"] == request["id"])
        #expect(await independentConcurrencyEventually(timeout: .seconds(2)) { outcome.value != nil }, "the detached task is still waiting for an answer to a cancelled call")
        // Whatever the outcome above, do not leave the task suspended.
        wire.send(["jsonrpc": "2.0", "id": request["id"]!, "result": ["action": "cancel"]])
        await wire.connection.close(graceSeconds: 0)
    }
}

// MARK: - Closing with requests at the server-wide gate

@Suite(.timeLimit(.minutes(5)))
struct IndependentConcurrencyCloseGateTests {
    @Test(arguments: [0.0, -1.0, 0.000_001, 0.02, 0.3])
    func closeWithRunningQueuedAndWaitingRequestsReturnsAndSendsNothingAfter(grace: Double) async throws {
        let ran = ICMeter()
        let cancelledSeen = ICMeter()
        let gate = ICBox(ICGate())
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 3
            configuration.budgets.maxQueuedRequests = 100
        }
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                cancelledSeen.enter()
                throw error
            }
            return .text("woke")
        }
        try server.register(tool: ToolDefinition(name: "stubborn")) { _, context in
            await gate.value.wait()
            context.progress(1)
            context.log(.error, "late")
            return .text("late")
        }
        try server.register(tool: ToolDefinition(name: "ask")) { _, context in
            let answer = try await context.elicit("k", message: "?", schema: formSchema)
            return .text(answer.action.rawValue)
        }
        try server.register(tool: ToolDefinition(name: "count")) { _, _ in
            ran.enter()
            return .text("ran")
        }
        // Another connection must come through untouched.
        let bystander = ICWire(server)
        for round in 0..<25 {
            gate.set(ICGate())
            let wire = ICWire(server, modern: false)
            try await wire.initialize(capabilities: ["elicitation": [:]])
            let before = cancelledSeen.total
            wire.call("sleep")
            wire.call("stubborn", meta: ["progressToken": 1])
            wire.call("ask")
            let question = try await wire.next()
            #expect(question["method"] == "elicitation/create")
            // Three slots taken; these wait at the gate, two on this connection and one on the other.
            wire.call("count")
            wire.call("count")
            let survivor = bystander.call("count")
            let connection = wire.connection
            // Closed twice at once.
            async let one = independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: grace) }
            async let two = independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: grace) }
            let both = await (one, two)
            #expect(both.0 && both.1, "close(graceSeconds: \(grace)) did not return, round \(round)")
            let mark = wire.sink.mark
            // The sleeper was cancelled, and the slot it gave back reaches the bystander's request.
            // (A queued request of the closing connection may still have run if a slot came
            // free before the close got to it; what matters is that nothing of it is sent late.)
            #expect(await independentConcurrencyEventually { cancelledSeen.total == before + 1 }, "round \(round)")
            #expect(try await bystander.response(to: survivor).independentConcurrencyText == "ran")
            // The stubborn handler ends long after close: nothing of it is sent.
            gate.value.open()
            try? await Task.sleep(for: .milliseconds(30))
            wire.send(["jsonrpc": "2.0", "id": question["id"]!, "result": ["action": "accept"]])
            try? await Task.sleep(for: .milliseconds(30))
            #expect(wire.sink.history.count == mark, "frames were queued after close() returned, round \(round)")
            // Each of the five calls was answered at most once before that.
            let responses = wire.sink.history.compactMap(\.json).filter { $0["method"] == nil && $0["id"] != nil }
            #expect(Set(responses.map { $0["id"] }).count == responses.count)
            // A third close on a finished connection returns at once.
            #expect(await independentConcurrencyFinishes(within: .seconds(5)) { await connection.close(graceSeconds: 30) })
            #expect(await bystander.isSilent(for: .milliseconds(1)))
        }
        // Every slot is back.
        let holding = ICMeter()
        let hold = ICGate()
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await hold.wait()
            return .text("held")
        }
        for _ in 0..<3 { bystander.call("hold") }
        #expect(await independentConcurrencyEventually { holding.total == 3 }, "only \(holding.total) of 3 slots are free after 25 closes with grace \(grace)")
        hold.open()
    }
}

// MARK: - Smaller rules of the second version

private struct ClearSealer: RequestStateSealer {
    func seal(_ plaintext: [UInt8]) throws -> String { "clear:" + String(decoding: plaintext, as: UTF8.self) }
    func open(_ sealed: String) throws -> [UInt8] {
        guard sealed.hasPrefix("clear:") else { throw RequestStateError(reason: "not mine") }
        return Array(sealed.dropFirst("clear:".count).utf8)
    }
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyRound2RuleTests {
    /// `maxRequestStateBytes`: "The most a `requestState` may hold before sealing."
    @Test func requestStateSizeLimitAtTheExactBoundary() async throws {
        func makeServer(limit: Int) throws -> Server {
            let server = independentConcurrencyServer { configuration in
                configuration.requestStateSealer = ClearSealer()
                configuration.maxRequestStateBytes = limit
            }
            try server.register(tool: ToolDefinition(name: "two")) { _, context in
                let a = try await context.elicit("a", message: "A?", schema: formSchema)
                let b = try await context.elicit("b", message: "B?", schema: formSchema)
                return .text("\(a.action.rawValue) \(b.action.rawValue)")
            }
            try server.register(prompt: PromptDefinition(name: "two")) { _, context in
                _ = try await context.elicit("a", message: "A?", schema: formSchema)
                _ = try await context.elicit("b", message: "B?", schema: formSchema)
                return PromptResult(messages: [])
            }
            return server
        }
        let answer: JSONValue = ["action": "accept", "content": ["v": .string(String(repeating: "j", count: 5000))]]
        func secondRound(_ wire: ICWire, _ method: String) async throws -> JSONValue {
            let first = try await wire.request(method, ["name": "two"])
            let state = try #require(first["result"]?["requestState"])
            return try await wire.request(method, ["name": "two", "requestState": state, "inputResponses": ["a": answer]])
        }
        let reference = try await secondRound(ICWire(try makeServer(limit: 1 << 20), capabilities: allInputs), "tools/call")
        let sealed = try #require(reference["result"]?["requestState"]?.stringValue)
        let size = sealed.utf8.count - "clear:".count
        #expect(size > 5000)

        let exact = try await secondRound(ICWire(try makeServer(limit: size), capabilities: allInputs), "tools/call")
        #expect(exact["result"]?["resultType"] == "input_required", "a state of exactly the limit must pass")
        #expect(exact["result"]?["requestState"]?.stringValue?.utf8.count == sealed.utf8.count)

        let tight = try await secondRound(ICWire(try makeServer(limit: size - 1), capabilities: allInputs), "tools/call")
        #expect(tight["result"]?["isError"] == true)
        #expect(tight["result"]?["requestState"] == nil)
        #expect(tight["result"]?["inputRequests"] == nil)
        let prompt = try await secondRound(ICWire(try makeServer(limit: size - 1), capabilities: allInputs), "prompts/get")
        #expect(prompt.independentConcurrencyErrorCode != nil)
        #expect(prompt["result"] == nil)
    }

    /// A message without `method` that carries `result` or `error` is a reply, whatever else is
    /// wrong with it. Like a reply with a malformed `error`, it must not be answered under its
    /// id: that id may name one of the peer's own requests in flight.
    @Test func noBrokenReplyIsAnsweredUnderAnIdOfThePeersOwnRequest() async throws {
        let gate = ICBox(ICGate())
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.value.wait()
            return .text("held")
        }
        for modern in [true, false] {
            gate.set(ICGate())
            let wire = ICWire(server, modern: modern)
            if !modern { try await wire.initialize() }
            let call = wire.call("hold", id: 5)
            let mark = wire.sink.mark
            let broken = [
                #"{"jsonrpc":"2.0","id":5}"#,
                #"{"jsonrpc":"2.0","id":5,"error":"text"}"#,
                #"{"jsonrpc":"2.0","id":5,"error":{"message":"no code"}}"#,
                #"{"jsonrpc":"1.0","id":5,"result":{}}"#,
                #"{"id":5,"result":{}}"#,
                #"{"jsonrpc":"1.0","id":5,"error":{"code":1,"message":"m"}}"#,
            ]
            for message in broken { wire.send(message) }
            try? await Task.sleep(for: .milliseconds(30))
            let stray = wire.sink.history.filter { $0.index >= mark && $0.json?["id"] == call.json }.map(\.text)
            #expect(stray.isEmpty, "\(modern ? "modern" : "legacy"): answered under the id of a request in flight: \(stray)")
            gate.value.open()
            let responses = await independentConcurrencyEventually {
                wire.sink.history.filter { $0.json?["id"] == call.json && $0.json?["method"] == nil }.count >= 1
            }
            #expect(responses)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(wire.sink.history.filter { $0.json?["id"] == call.json && $0.json?["method"] == nil }.count == 1)
        }
    }

    @Test func cancellingRequestsWhoseResponsesWaitForRoomFreesTheirSlots() async throws {
        let done = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 100
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in
            done.enter()
            return .text(String(repeating: "b", count: 3000))
        }
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        let stuckQueue = OutboundQueue(budgetBytes: 1000, urgentReserveBytes: 100_000)
        let stuck = server.connect(to: stuckQueue)
        for id in 0..<3 {
            stuck.receive(Array(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"blob",\#(modernMeta)}}"#.utf8))
        }
        #expect(await independentConcurrencyEventually { done.total == 3 })
        try? await Task.sleep(for: .milliseconds(100))
        // The client gives up on everything it asked for.
        for id in 0..<3 {
            stuck.receive(Array(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"#.utf8))
        }
        let healthy = ICWire(server)
        let id = healthy.call("echo")
        let answer = await healthy.sink.next(timeout: .seconds(3))
        #expect(answer?.json?["id"] == id.json, "cancelled requests still hold the server's handler slots while their peer does not read")
        stuckQueue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.close(graceSeconds: 0) }
    }
}
