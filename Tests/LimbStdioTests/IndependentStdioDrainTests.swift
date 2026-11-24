#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Limb
import Synchronization
import Testing


private typealias Client = IndependentStdioClient

#if canImport(Darwin)
private let openFilesResource = RLIMIT_NOFILE
#elseif canImport(Glibc)
private let openFilesResource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
#endif

#if canImport(Darwin)
private struct Abandoned {
    let client: IndependentStdioClient
    let fixture: IndependentStdioFixture
    /// The writer thread `run` left behind.
    let writer: Set<UInt64>
}

/// A session whose client never read: `run` has returned after its drain deadline and the
/// writer thread is still there, with most of 3.6 MB of responses unwritten.
private func abandonedSession(socket: Bool, nonBlocking: Bool, drain: Double = 0.2, signals: Bool = false) throws -> Abandoned {
    let fixture = try independentStdioFixture { $0.outputDrainSeconds = drain }
    let before = Set(independentStdioTransportThreads().map(\.id))
    let client = Client(fixture.server, channel: socket ? .socketpair : .pipes)
    if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
    client.start(signals: signals)
    #expect(client.initialize() == "2025-11-25")
    for id in 1...6 {
        #expect(client.send(Client.callLine(id, "blob", #"{"size":600000,"seed":\#(id)}"#), absorb: false))
    }
    #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count >= 6 })
    usleep(100_000)
    client.closeInput()
    #expect(client.stopped(within: 10), "run did not return by its drain deadline")
    // Whatever is left of this session's threads once `run` is back.
    var left: Set<UInt64> = []
    for _ in 0..<50 {
        left = Set(independentStdioTransportThreads().filter { !before.contains($0.id) && $0.name == "limb-stdio-writer" }.map(\.id))
        if left.count == 1 { break }
        usleep(20_000)
    }
    return Abandoned(client: client, fixture: fixture, writer: left)
}
#endif

private struct PacedOutcome {
    /// `run` logged that it gave up on the reader.
    var gaveUp: Bool
    /// Scheduled reads that actually took bytes before `run` returned or gave up.
    var steps: Int
    var log: [String]
    /// The reader that went on got the whole response, intact, and every line was valid.
    var intact: Bool
}

/// Leave room for an entire write started before draining or a full pipe page on Linux.
private func pacedReadSize() -> Int {
    max(16 * 1024, Int(sysconf(Int32(_SC_PAGESIZE))))
}

/// Take an initial burst and then one chunk every period until the server finishes or gives
/// up. The reader then drains the remainder and verifies the response.
private func pacedDrain(
    channel: IndependentStdioClient.Channel, nonBlocking: Bool, limit: Double, period: Double,
    readSize: Int = pacedReadSize()
) throws -> PacedOutcome {
    let burst = max(80 * 1024, readSize)
    let capacity = channel == .pipes ? 64 * 1024 : 16 * 1024
    let size = burst + capacity + max(12 * readSize, 60 * 1024)
    let fixture = try independentStdioFixture { $0.outputDrainSeconds = limit }
    #if canImport(Darwin)
    let before = Set(independentStdioTransportThreads().map(\.id))
    #endif
    let client = Client(fixture.server, channel: channel)
    defer { client.tearDown() }
    if channel == .socketpair {
        // One scheduled read can free the full send buffer, including the extra space
        // the system may apply to the requested size.
        var sendBuffer: Int32 = 8 * 1024
        try #require(setsockopt(client.serverOutput, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0)
    }
    if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
    client.start()
    #expect(client.initialize() == "2025-11-25")
    #expect(client.send(Client.callLine(1, "blob", #"{"size":\#(size),"seed":7}"#), absorb: false))
    #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count >= 1 })
    client.closeInput()
    usleep(100_000)
    var taken = 0
    let burstDeadline = Date().addingTimeInterval(5)
    while taken < burst, Date() < burstDeadline {
        let count = client.absorb(limit: Swift.min(16 * 1024, burst - taken))
        if count == 0 { usleep(500) }
        taken += count
    }
    try #require(taken == burst, "The reader could not establish the initial burst")
    // The writer fills the channel again in no time; from here on it is blocked.
    usleep(20_000)
    var steps = 0
    var scheduled = 0
    let start = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - start < 60 {
        if !fixture.log.all.isEmpty || client.hasReturned { break }
        scheduled += 1
        let wait = start + Double(scheduled) * period - ProcessInfo.processInfo.systemUptime
        if wait > 0 { usleep(useconds_t(wait * 1e6)) }
        if client.absorb(limit: readSize) > 0 { steps += 1 }
    }
    let answer = client.responses(to: [1], timeout: 30)[1]
    let intact = Client.text(of: answer) == independentStdioBlob(size: size, seed: 7) && client.violations == []
    #expect(client.stopped(within: 10))
    #if canImport(Darwin)
    let left = Set(independentStdioTransportThreads().map(\.id)).subtracting(before)
    #expect(threadsGone(left, within: 5))
    #endif
    let log = fixture.log.all
    return PacedOutcome(gaveUp: !log.isEmpty, steps: steps, log: log, intact: intact)
}

#if canImport(Darwin)
private func threadsGone(_ ids: Set<UInt64>, within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        if Set(independentStdioTransportThreads().map(\.id)).isDisjoint(with: ids) { return true }
        if Date() >= deadline { return false }
        usleep(10_000)
    }
}
#endif

extension IndependentStdioTransportTests {
    @Suite struct Drain {
        // MARK: The deadline

        #if canImport(Darwin)
        @Test(arguments: [0.5, 2.0])
        func aClientThatNeverReadsCostsExactlyTheDeadline(seconds: Double) throws {
            let abandoned: Abandoned
            let started = Date()
            abandoned = try abandonedSession(socket: false, nonBlocking: false, drain: seconds)
            defer { abandoned.client.tearDown() }
            // `abandonedSession` waits 0.1 s before the end of input and returns when run did.
            let took = Date().timeIntervalSince(started)
            #expect(took >= seconds, "run gave up after \(took) s in all; the deadline alone is \(seconds) s")
            #expect(abandoned.fixture.log.all.count == 1, "\(abandoned.fixture.log.all)")
            #expect(abandoned.writer.count == 1, "the writer left behind: \(abandoned.writer.count) threads")
        }

        #endif

        /// The deadline is a limit, not a wait: with nothing left to write `run` returns at once.
        @Test func nothingToWriteMeansNothingToWaitFor() throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 60 }
            // End of input on an idle session.
            let idle = Client.ready(fixture.server)
            var at = Date()
            idle.closeInput()
            #expect(idle.stopped(within: 10))
            #expect(Date().timeIntervalSince(at) < 3)
            idle.tearDown()
            // After answers the client has read.
            let busy = Client.ready(fixture.server, channel: .socketpair)
            for id in 1...50 { #expect(busy.call(id, "blob", #"{"size":50000,"seed":\#(id)}"#)) }
            #expect(busy.responses(to: Set(1...50)).count == 50)
            at = Date()
            busy.closeInput()
            #expect(busy.stopped(within: 10))
            #expect(Date().timeIntervalSince(at) < 3)
            busy.tearDown()
            // Cancellation.
            let cancelled = Client.ready(fixture.server)
            at = Date()
            cancelled.cancelRun()
            #expect(cancelled.stopped(within: 10))
            #expect(Date().timeIntervalSince(at) < 3)
            cancelled.tearDown()
            #expect(fixture.log.all == [])
        }

        @Test func aSteadyReaderIsWaitedForBeyondTheLimit() throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 0.5 }
            #if canImport(Darwin)
            let before = Set(independentStdioTransportThreads().map(\.id))
            #endif
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            for id in 1...6 {
                #expect(client.send(Client.callLine(id, "blob", #"{"size":600000,"seed":\#(id)}"#), absorb: false))
            }
            client.closeInput()
            var answers: [Int: [String: Any]] = [:]
            var unreadWhenRunReturned: Int?
            let started = Date()
            let deadline = Date().addingTimeInterval(60)
            while answers.count < 6, Date() < deadline {
                client.absorb(limit: 16 * 1024)
                while let message = client.readMessage(timeout: 0) {
                    if let id = Client.id(of: message) { answers[id] = message }
                }
                if unreadWhenRunReturned == nil, client.hasReturned { unreadWhenRunReturned = 3_600_000 - client.bytesRead }
                usleep(15_000)
            }
            #expect(Date().timeIntervalSince(started) > 1.5, "the reader was not slow enough to say anything")
            #expect(answers.count == 6)
            for (id, answer) in answers {
                #expect(Client.text(of: answer) == independentStdioBlob(size: 600_000, seed: id), "blob \(id)")
            }
            // `run` returns when the last byte is written, that is while the reader still has
            // what the channel holds in front of it — and not before.
            #expect((unreadWhenRunReturned ?? 0) < 300_000, "run returned with \(unreadWhenRunReturned ?? 0) bytes still to be read")
            #expect(client.stopped(within: 10))
            // Giving up is logged; an ordinary end is not.
            #expect(fixture.log.all == [], "\(fixture.log.all)")
            #if canImport(Darwin)
            let rest = Set(independentStdioTransportThreads().map(\.id)).subtracting(before)
            #expect(threadsGone(rest, within: 5))
            #endif
            #expect(client.violations == [])
        }

        @Test(arguments: [false, true])
        func aReaderSlowerThanOneLargePieceInTheLimitIsStillWaitedFor(nonBlocking: Bool) throws {
            let limit = 0.5
            let step = 8 * 1024
            let pause: useconds_t = 50_000
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = limit }
            #if canImport(Darwin)
            let before = Set(independentStdioTransportThreads().map(\.id))
            #endif
            let client = Client(fixture.server)
            defer { client.tearDown() }
            if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
            client.start()
            #expect(client.initialize() == "2025-11-25")
            for id in 1...3 {
                #expect(client.send(Client.callLine(id, "blob", #"{"size":300000,"seed":\#(id)}"#), absorb: false))
            }
            #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count >= 3 })
            client.closeInput()
            // Steady reading for at least three limits (or until everything is read).
            var answers: [Int: [String: Any]] = [:]
            var gaveUpAfter: Double?
            let started = Date()
            while answers.count < 3, Date().timeIntervalSince(started) < 25 {
                client.absorb(limit: step)
                while let message = client.readMessage(timeout: 0) {
                    if let id = Client.id(of: message) { answers[id] = message }
                }
                // Giving up is logged; an ordinary end (everything written) is not.
                if gaveUpAfter == nil, !fixture.log.all.isEmpty { gaveUpAfter = Date().timeIntervalSince(started) }
                if gaveUpAfter != nil { break }
                usleep(pause)
            }
            #expect(gaveUpAfter == nil, "run gave up on a reader taking \(step) bytes every \(Double(pause) / 1e6) s after \(gaveUpAfter ?? 0) s; the limit on standing still is \(limit) s")
            // Whatever was decided, a reader that goes on gets everything.
            let rest = client.responses(to: Set(1...3).subtracting(answers.keys), timeout: 30)
            #expect(answers.count + rest.count == 3)
            #expect(client.stopped(within: 10))
            #if canImport(Darwin)
            let left = Set(independentStdioTransportThreads().map(\.id)).subtracting(before)
            #expect(threadsGone(left, within: 5))
            #endif
            #expect(client.violations == [])
        }

        @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair], [false, true])
        func aReaderMakingProgressWithinEachLimitIsWaitedFor(channel: IndependentStdioClient.Channel, nonBlocking: Bool) throws {
            let limit = 0.75
            for fraction in [0.4, 0.8] {
                let outcome = try pacedDrain(channel: channel, nonBlocking: nonBlocking, limit: limit, period: limit * fraction)
                #expect(!outcome.gaveUp, "\(channel), non-blocking \(nonBlocking): run gave up on a reader taking up to \(pacedReadSize()) bytes every \(limit * fraction) s after \(outcome.steps) reads. Log: \(outcome.log)")
                #expect(outcome.steps >= 5, "the writer was not blocked long enough to say anything (\(outcome.steps) steps)")
                #expect(outcome.intact)
            }
        }

        #if canImport(Darwin)
        @Test func aDarwinPipeKeepsDrainingDuringKilobyteReads() throws {
            let outcome = try pacedDrain(channel: .pipes, nonBlocking: true, limit: 0.75, period: 0.06, readSize: 1024)
            #expect(!outcome.gaveUp, "\(outcome.log)")
            #expect(outcome.steps >= 20)
            #expect(outcome.intact)
        }
        #endif

        /// With one read per 1.25 or 2 limits, the writer stalls for longer than the limit.
        /// The server gives up, logs once, and the reader can still collect the whole response.
        @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair], [false, true])
        func aReaderMakingNoProgressDuringTheLimitIsGivenUpOn(channel: IndependentStdioClient.Channel, nonBlocking: Bool) throws {
            for fraction in [1.25, 2.0] {
                let outcome = try pacedDrain(channel: channel, nonBlocking: nonBlocking, limit: 0.5, period: 0.5 * fraction)
                #expect(outcome.gaveUp, "\(channel), non-blocking \(nonBlocking): run waited for a reader taking up to \(pacedReadSize()) bytes every \(0.5 * fraction) s")
                #expect(outcome.log.count == 1 && outcome.log.first?.contains("did not read") == true, "\(outcome.log)")
                #expect(outcome.intact)
            }
        }

        /// A pause shorter than the limit is not standing still; a pause longer than the limit
        /// is. The limit is 2 s; the pauses are 1 s and 4.5 s.
        @Test(arguments: [false, true])
        func aPauseUnderTheLimitIsWaitedOutAndAPauseOverItIsNot(socket: Bool) throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 2 }
            #if canImport(Darwin)
            let before = Set(independentStdioTransportThreads().map(\.id))
            #endif
            let client = Client.ready(fixture.server, channel: socket ? .socketpair : .pipes)
            defer { client.tearDown() }
            for id in 1...6 {
                #expect(client.send(Client.callLine(id, "blob", #"{"size":600000,"seed":\#(id)}"#), absorb: false))
            }
            #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count >= 6 })
            client.closeInput()
            func take(_ bytes: Int) {
                let target = client.bytesRead + bytes
                let deadline = Date().addingTimeInterval(20)
                while client.bytesRead < target, Date() < deadline {
                    if client.absorb(limit: 64 * 1024) == 0 { usleep(1000) }
                }
            }
            take(1_000_000)
            usleep(1_000_000)
            #expect(!client.hasReturned, "run gave up during a pause of 1 s; the limit is 2 s")
            take(1_000_000)
            #expect(!client.hasReturned)
            #expect(fixture.log.all == [])
            usleep(4_500_000)
            #expect(client.hasReturned, "run was still waiting after the reader stood still for 4.5 s; the limit is 2 s")
            #expect(fixture.log.all.count == 1, "\(fixture.log.all)")
            // The reader comes back: it still gets everything, from the writer left behind.
            let answers = client.responses(to: Set(1...6), timeout: 30)
            #expect(answers.count == 6)
            for (id, answer) in answers {
                #expect(Client.text(of: answer) == independentStdioBlob(size: 600_000, seed: id), "blob \(id)")
            }
            #if canImport(Darwin)
            let left = Set(independentStdioTransportThreads().map(\.id)).subtracting(before)
            #expect(threadsGone(left, within: 5))
            #endif
            #expect(client.violations == [])
        }

        @Test func aZeroDeadlineWithNothingToWriteReportsNothing() throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 0 }
            var stuck = 0
            for _ in 0..<300 {
                let client = Client.ready(fixture.server)
                client.closeInput()
                if !client.stopped(within: 10) { stuck += 1 }
                client.tearDown()
            }
            #expect(stuck == 0)
            #expect(fixture.log.all.count == 0, "\(fixture.log.all.count) of 300 idle sessions were reported as a peer that did not read")
        }

        @Test(arguments: [0.0, 0.001], [false, true])
        func aDeliveredFrameStillChargedToTheQueueDoesNotDiagnoseASlowPeer(limit: Double, closeOutput: Bool) throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = limit }
            let frameWritten = DispatchSemaphore(value: 0)
            let finishAccounting = DispatchSemaphore(value: 0)
            let client = Client(fixture.server, channel: closeOutput ? .socketpair : .pipes).start { transport in
                transport.beforeWriteAccounting = {
                    frameWritten.signal()
                    if finishAccounting.wait(timeout: .now() + .seconds(15)) == .timedOut {
                        Issue.record("The test did not release the writer")
                    }
                }
            }
            defer {
                finishAccounting.signal()
                client.tearDown()
            }
            try #require(client.initialize() == "2025-11-25")
            try #require(frameWritten.wait(timeout: .now() + .seconds(5)) == .success)
            if closeOutput { client.closeOutput() }
            client.closeInput()
            try #require(client.stopped(within: 5))
            #expect(fixture.log.all.isEmpty, "\(fixture.log.all)")
        }

        #if canImport(Glibc)
        @Test func aWrittenFrameDoesNotLookStalledWhenItFillsTheLastPipeBuffer() throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 0 }
            let frameWritten = DispatchSemaphore(value: 0)
            let finishAccounting = DispatchSemaphore(value: 0)
            let client = Client(fixture.server)
            defer {
                finishAccounting.signal()
                client.tearDown()
            }
            independentStdioSetNonBlocking(client.serverOutput)
            let pageSize = Int(getpagesize())
            let padding = [UInt8](repeating: 0, count: pageSize)
            var filled = 0
            while filled < 1 << 20 {
                let count = padding.withUnsafeBytes { write(client.serverOutput, $0.baseAddress, $0.count) }
                if count < 0 {
                    try #require(errno == EAGAIN)
                    break
                }
                try #require(count == pageSize)
                filled += count
            }
            try #require(filled < 1 << 20, "The test pipe should reach its normal kernel capacity")
            var drained = [UInt8](repeating: 0, count: pageSize)
            try #require(drained.withUnsafeMutableBytes { read(client.readEnd, $0.baseAddress, $0.count) } == pageSize)

            client.start { transport in
                transport.beforeWriteAccounting = {
                    frameWritten.signal()
                    if finishAccounting.wait(timeout: .now() + .seconds(15)) == .timedOut {
                        Issue.record("The test did not release the writer")
                    }
                }
            }
            try #require(client.send(#"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"# + "\n", absorb: false))
            try #require(frameWritten.wait(timeout: .now() + .seconds(5)) == .success)
            var descriptor = pollfd(fd: client.serverOutput, events: Int16(POLLOUT), revents: 0)
            try #require(poll(&descriptor, 1, 0) == 0, "The written frame occupied the last pipe buffer")

            client.closeInput()
            try #require(client.stopped(within: 5))
            #expect(fixture.log.all.isEmpty, "\(fixture.log.all)")
        }
        #endif

        @Test func aZeroDeadlineDoesNotLoseAnswersOfAReadingClient() throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 0 }
            var incomplete = 0
            for _ in 0..<100 {
                let client = Client.ready(fixture.server)
                var script = ""
                for id in 1...20 { script += Client.callLine(id, "echo", #"{"text":"z\#(id)"}"#) }
                client.send(script)
                client.closeInput()
                if client.responses(to: Set(1...20), timeout: 10).count != 20 { incomplete += 1 }
                _ = client.stopped(within: 10)
                client.tearDown()
            }
            #expect(incomplete == 0)
        }

        @Test(arguments: [-1.0, -Double.infinity, Double.nan, 1e10, 1e18, 9e18])
        func unusualDeadlinesBehaveLikeZeroOrForEver(seconds: Double) throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = seconds }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(client.call(1, "echo", #"{"text":"x"}"#))
            #expect(Client.text(of: client.readMessage()) == "x")
            client.closeInput()
            #expect(client.stopped(within: 10))
        }

        @Test func anInfiniteDeadlineDoesNotCrash() throws {
            let fixture = try independentStdioFixture {
                $0.outputDrainSeconds = .infinity
                $0.shutdownGraceSeconds = .infinity
            }
            let client = Client.ready(fixture.server)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            // With a request in flight, so that the grace period is waited out too.
            #expect(client.call(1, "nap", #"{"ms":300,"tag":"n"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 1 })
            client.closeInput()
            #expect(Client.text(of: client.responses(to: [1], timeout: 10)[1]) == "woke n")
            #expect(client.stopped(within: 10))
            #expect(fixture.log.all == [])
        }

        @Test func aFullQueueAtEndOfInputStillEnds() throws {
            let fixture = try independentStdioFixture {
                $0.budgets.maxOutboundBytes = 64 * 1024
                $0.budgets.maxQueuedRequests = 200
                $0.shutdownGraceSeconds = 1
                $0.outputDrainSeconds = 1
            }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var script = ""
            for id in 1...40 { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id)}"#) }
            #expect(client.send(script, absorb: false))
            usleep(500_000)
            let closedAt = Date()
            client.closeInput()
            #expect(client.stopped(within: 15))
            let took = Date().timeIntervalSince(closedAt)
            #expect(took >= 0.9 && took < 10, "took \(took) s")
        }

        /// "If the transport threads or the wake pipe cannot be created, `run` now cleans up and
        /// closes the connection." The process is starved of descriptors for a moment, which
        /// would break every other test running at the same time — so this one runs only when
        /// asked for by name: `LIMB_INDEPENDENT_ISOLATED=1 swift test --filter whenTheWakeUpPipe`.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["LIMB_INDEPENDENT_ISOLATED"] != nil))
        func whenTheWakeUpPipeCannotBeCreatedRunReturnsAndLeavesNothingBehind() throws {
            let fixture = try independentStdioFixture()
            let client = Client(fixture.server)
            defer { client.tearDown() }
            #if canImport(Darwin)
            let threads = independentStdioTransportThreads().count
            #endif
            let descriptors = independentStdioOpenDescriptorCount()
            // No descriptor number is left: lower the limit to just above the highest one in
            // use and fill every gap below it.
            var limit = rlimit()
            try #require(getrlimit(openFilesResource, &limit) == 0)
            let original = limit
            var highest: Int32 = 0
            for descriptor in 0..<Int32(Swift.min(Int(getdtablesize()), 65536)) where fcntl(descriptor, F_GETFD) != -1 { highest = descriptor }
            limit.rlim_cur = rlim_t(highest + 1)
            try #require(setrlimit(openFilesResource, &limit) == 0)
            var fillers: [Int32] = []
            while true {
                let filler = dup(client.serverInput)
                if filler < 0 { break }
                fillers.append(filler)
            }
            client.start()
            let returned = client.stopped(within: 10)
            for filler in fillers { close(filler) }
            var restored = original
            #expect(setrlimit(openFilesResource, &restored) == 0)
            #expect(returned, "run did not return although it could not start")
            #expect(fixture.log.all.count == 1, "\(fixture.log.all)")
            #expect(fixture.log.all.first?.contains("wake-up pipe") == true)
            #if canImport(Darwin)
            #expect(independentStdioTransportThreads().count == threads)
            #endif
            #expect(independentStdioOpenDescriptorCount() == descriptors)
            #expect(client.drain(seconds: 0.2).isEmpty)
            // The server is none the worse for it.
            let next = Client.ready(fixture.server)
            #expect(next.request(1, "ping"))
            #expect(Client.id(of: next.readMessage()) == 1)
            next.closeInput()
            #expect(next.stopped(within: 10))
            next.tearDown()
        }

        /// Frames much larger than the 16 KiB piece, up to several megabytes, reach a reader
        /// that is steady but slower than the writer, once the input has ended (that is, in
        /// 1 KiB pieces). Limit 0.5 s; the reader takes at most 64 KiB every 10 ms (a socket pair
        /// hands out 8 KiB at a time).
        @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair])
        func largeFramesReachASteadyReaderWhileDraining(channel: IndependentStdioClient.Channel) throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 0.5 }
            let client = Client.ready(fixture.server, channel: channel)
            defer { client.tearDown() }
            let sizes = [1: 40_000, 2: 4 << 20, 3: 17 * 1024, 4: 1_500_000]
            for (id, size) in sizes.sorted(by: { $0.key < $1.key }) {
                #expect(client.send(Client.callLine(id, "blob", #"{"size":\#(size),"seed":\#(id)}"#), absorb: false))
            }
            #expect(fixture.probe.eventually(seconds: 30) { $0.finishedTags.count >= 4 })
            client.closeInput()
            // Only bytes are taken while `run` drains (parsing a 4 MB line in a debug or
            // sanitizer build can take longer than the limit, and would make this reader stand
            // still); the messages are read once `run` is back.
            let deadline = Date().addingTimeInterval(60)
            while !client.hasReturned, Date() < deadline {
                client.absorb(limit: 64 * 1024)
                usleep(10_000)
            }
            let answers = client.responses(to: Set(sizes.keys), timeout: 30)
            #expect(answers.count == 4)
            for (id, size) in sizes { #expect(Client.text(of: answers[id]) == independentStdioBlob(size: size, seed: id), "blob \(id)") }
            #expect(client.stopped(within: 10))
            #expect(fixture.log.all == [], "\(fixture.log.all)")
            #expect(client.violations == [])
        }

        // MARK: The writer left behind

        #if canImport(Darwin)
        /// "The writer thread stays blocked in `write` until the peer reads or goes away."
        @Test(arguments: [false, true], [false, true])
        func theWriterLeftBehindEndsWhenThePeerGoesAwayOrReads(socket: Bool, nonBlocking: Bool) throws {
            // The peer goes away.
            let first = try abandonedSession(socket: socket, nonBlocking: nonBlocking)
            #expect(first.writer.count == 1)
            first.client.closeOutput()
            #expect(threadsGone(first.writer, within: 5), "the writer outlived its peer")
            first.client.tearDown()
            // The peer reads after all: it gets everything, late.
            let second = try abandonedSession(socket: socket, nonBlocking: nonBlocking)
            #expect(second.writer.count == 1)
            let answers = second.client.responses(to: Set(1...6), timeout: 30)
            #expect(answers.count == 6)
            for (id, answer) in answers {
                #expect(Client.text(of: answer) == independentStdioBlob(size: 600_000, seed: id), "blob \(id)")
            }
            #expect(threadsGone(second.writer, within: 5), "the writer did not end after writing everything")
            #expect(second.client.violations == [])
            second.client.tearDown()
        }
        #endif

        #if canImport(Darwin)
        /// Many sessions in a row whose clients never read. While the clients are still there,
        /// one thread per session stays (that is the documented price); the wake-up pipes are
        /// closed all the same. Once the clients go, nothing is left.
        @Test func sessionsWithWritersLeftBehindLeakNothingOnceTheirPeersAreGone() throws {
            let descriptors = independentStdioOpenDescriptorCount()
            let threads = independentStdioTransportThreads().count
            var sessions: [Abandoned] = []
            for index in 0..<30 {
                sessions.append(try abandonedSession(socket: index % 2 == 1, nonBlocking: index % 4 >= 2, drain: 0.05))
            }
            let writers = sessions.reduce(into: Set<UInt64>()) { $0.formUnion($1.writer) }
            #expect(writers.count == 30)
            // 15 sessions on two pipes (three descriptors left: the client closed its writing
            // end), 15 on a socket pair (two), and for each the writer's own duplicate of the
            // output, which "stays until the peer reads or closes". No wake-up pipe of a finished
            // session is among them. (The author's suite may hold a few more.)
            let held = independentStdioOpenDescriptorCount() - descriptors
            #expect(held >= 105 && held <= 105 + 6, "\(held) descriptors are open for 30 finished sessions; their own are 75 and 30 duplicates")
            for session in sessions { session.client.closeOutput() }
            #expect(threadsGone(writers, within: 10), "writers outlived their peers")
            for session in sessions { session.client.tearDown() }
            var after = (descriptors: Int.max, threads: Int.max)
            let deadline = Date().addingTimeInterval(5)
            repeat {
                after = (independentStdioOpenDescriptorCount(), independentStdioTransportThreads().count)
                if after.descriptors <= descriptors + 6, after.threads <= threads + 2 { break }
                usleep(50_000)
            } while Date() < deadline
            #expect(after.descriptors <= descriptors + 6, "open descriptors: \(descriptors) before, \(after.descriptors) after")
            #expect(after.threads <= threads + 2, "transport threads: \(threads) before, \(after.threads) after")
        }
        #endif

        #if canImport(Darwin)
        @Test(arguments: [false, true], [false, true])
        func theWriterLeftBehindNeverTouchesADescriptorTheCallerReused(socket: Bool, nonBlocking: Bool) throws {
            independentStdioCountSIGUSR1()
            let abandoned = try abandonedSession(socket: socket, nonBlocking: nonBlocking, signals: true)
            #expect(abandoned.writer.count == 1)
            let number = abandoned.client.serverOutput
            var mine: [Int32] = [-1, -1]
            try #require(pipe(&mine) == 0)
            independentStdioSetNonBlocking(mine[0])
            abandoned.client.disownServerEnds()
            try #require(dup2(mine[1], number) == number)
            close(mine[1])
            // A signal handled on the writer's thread gets it out of whatever it is waiting in.
            let handledBefore = independentStdioHandledSignals.load(ordering: .relaxed)
            #expect(independentStdioSignalThreads(ids: abandoned.writer, signal: SIGUSR1) == 1)
            #expect(abandoned.fixture.probe.eventually(seconds: 5) { _ in
                independentStdioHandledSignals.load(ordering: .relaxed) > handledBefore
            }, "the signal was not handled")
            usleep(200_000)
            // The old client comes back and reads: everything is still its own.
            let answers = abandoned.client.responses(to: Set(1...6), timeout: 30)
            #expect(answers.count == 6)
            for (id, answer) in answers {
                #expect(Client.text(of: answer) == independentStdioBlob(size: 600_000, seed: id), "blob \(id)")
            }
            #expect(threadsGone(abandoned.writer, within: 5), "the writer did not end after writing everything")
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            let stray = read(mine[0], &buffer, buffer.count)
            #expect(stray <= 0, "\(stray) bytes of the finished session's output arrived in a descriptor that only shares its number")

            // Clean up whatever is left, so that no stray thread writes anywhere later.
            close(mine[0])
            for _ in 0..<50 where !threadsGone(abandoned.writer, within: 0.1) {
                _ = independentStdioSignalThreads(ids: abandoned.writer, signal: SIGUSR1)
            }
            close(number)
            if !socket { close(abandoned.client.serverInput) }
            abandoned.client.tearDown()
        }
        #endif

        @Test func aSessionOpensThreeDescriptorsAllCloseOnExecAndReturnsThem() throws {
            let fixture = try independentStdioFixture()
            func open() -> Set<Int32> {
                var set: Set<Int32> = []
                for descriptor in 0..<Int32(Swift.min(Int(getdtablesize()), 65536)) where fcntl(descriptor, F_GETFD) != -1 { set.insert(descriptor) }
                return set
            }
            // The author's suite may open descriptors at the same moment: look for a quiet one.
            var fresh: Set<Int32> = []
            var inherited: [Int32] = []
            var duplicates = 0
            var leftOpen: Set<Int32> = []
            for _ in 0..<10 {
                let client = Client(fixture.server)
                let before = open()
                client.start()
                #expect(client.initialize() == "2025-11-25")
                fresh = open().subtracting(before)
                inherited = fresh.filter { fcntl($0, F_GETFD) & FD_CLOEXEC == 0 }.sorted()
                let output = IndependentStdioDescriptorState(client.serverOutput)
                duplicates = fresh.filter { IndependentStdioDescriptorState($0)?.inode == output?.inode }.count
                client.closeInput()
                #expect(client.stopped(within: 10))
                usleep(50_000)
                leftOpen = open().subtracting(before)
                client.tearDown()
                if fresh.count == 3, leftOpen.isEmpty { break }
            }
            #expect(fresh.count == 3, "a session opened \(fresh.count) descriptors of its own")
            #expect(duplicates == 1, "one of them is the duplicate of the output")
            #expect(leftOpen.isEmpty, "descriptors still open after run returned: \(leftOpen.sorted())")
            #expect(inherited == [], "\(inherited.count) of the session's descriptors are not close-on-exec")
        }

        #if canImport(Darwin)
        /// Two hundred sessions in a row on one server, every eighth with a client that never
        /// reads (its writer is left behind). After each `run` the caller hands the output's
        /// number straight to a pipe of its own, as a server that accepts connections would. The
        /// rule: "After `run` returns, the caller's descriptor number is never written to again,
        /// whatever it has come to mean"; the duplicate "stays until the peer reads or closes".
        /// At the end the clients left behind read everything: complete answers, nothing in any
        /// of the pipes that took over a number, and no descriptor or thread left.
        @Test func hundredsOfSessionsWithSomeWritersLeftBehindNeverWriteToAReusedNumber() throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 0.05 }
            let descriptors = independentStdioOpenDescriptorCount()
            let threads = Set(independentStdioTransportThreads().map(\.id))
            struct Left {
                let client: IndependentStdioClient
                let probe: Int32
            }
            var left: [Left] = []
            var strays: [String] = []
            var failures: [String] = []
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            for index in 0..<200 {
                let abandon = index % 8 == 7
                let client = Client(fixture.server, channel: index % 3 == 2 ? .socketpair : .pipes)
                if index % 5 == 4 { independentStdioSetNonBlocking(client.serverOutput) }
                client.start()
                guard client.initialize() == "2025-11-25" else {
                    failures.append("session \(index): no handshake")
                    client.tearDown()
                    continue
                }
                if abandon {
                    client.send(Client.callLine(1, "blob", #"{"size":300000,"seed":\#(index)}"#), absorb: false)
                } else {
                    client.call(1, "echo", #"{"text":"s\#(index)"}"#)
                    if Client.text(of: client.responses(to: [1], timeout: 10)[1]) != "s\(index)" { failures.append("session \(index): no answer") }
                }
                client.closeInput()
                guard client.stopped(within: 10) else {
                    failures.append("session \(index): run did not return")
                    client.tearDown()
                    continue
                }
                // The caller reuses the number at once.
                var mine: [Int32] = [-1, -1]
                try #require(pipe(&mine) == 0)
                independentStdioSetNonBlocking(mine[0])
                client.disownServerEnds()
                try #require(dup2(mine[1], client.serverOutput) == client.serverOutput)
                close(mine[1])
                if client.serverInput != client.serverOutput { close(client.serverInput) }
                if abandon {
                    left.append(Left(client: client, probe: mine[0]))
                } else {
                    usleep(1000)
                    let stray = read(mine[0], &buffer, buffer.count)
                    if stray > 0 { strays.append("session \(index): \(stray) bytes") }
                    close(client.serverOutput)
                    close(mine[0])
                    client.tearDown()
                }
            }
            #expect(failures == [])
            #expect(left.count == 25)
            // Each client left behind holds its own end(s); each writer its duplicate.
            let held = independentStdioOpenDescriptorCount() - descriptors
            #expect(held >= 25 * 3, "\(held) descriptors held for 25 sessions left behind")
            for (index, entry) in left.enumerated() {
                let seed = (index + 1) * 8 - 1
                let answer = entry.client.responses(to: [1], timeout: 30)[1]
                if Client.text(of: answer) != independentStdioBlob(size: 300_000, seed: seed) { failures.append("session \(seed): the late answer is incomplete") }
                #expect(entry.client.violations == [])
            }
            #expect(failures == [])
            usleep(100_000)
            for entry in left {
                let stray = read(entry.probe, &buffer, buffer.count)
                if stray > 0 { strays.append("left behind: \(stray) bytes") }
                close(entry.probe)
                close(entry.client.serverOutput)
                entry.client.tearDown()
            }
            #expect(strays == [], "output of finished sessions arrived in descriptors that only share their number")
            var after = (descriptors: Int.max, threads: [IndependentStdioThread]())
            let deadline = Date().addingTimeInterval(10)
            repeat {
                after = (independentStdioOpenDescriptorCount(), independentStdioTransportThreads().filter { !threads.contains($0.id) })
                if after.descriptors <= descriptors + 6, after.threads.count <= 2 { break }
                usleep(50_000)
            } while Date() < deadline
            #expect(after.descriptors <= descriptors + 6, "open descriptors: \(descriptors) before, \(after.descriptors) after")
            #expect(after.threads.count <= 2, "transport threads left: \(after.threads.map(\.name))")
        }
        #endif

        /// The fallback: "If the descriptor cannot be duplicated (already closed …) the session
        /// uses the caller's number and the first failed write ends it." With -1 there is
        /// nothing to fail until something is written; then the session ends, says why, and
        /// leaves every descriptor of the process as it was.
        @Test func minusOneAsOutputEndsTheSessionAtTheFirstWrite() throws {
            let fixture = try independentStdioFixture()
            var toServer: [Int32] = [-1, -1]
            try #require(pipe(&toServer) == 0)
            defer {
                close(toServer[0])
                close(toServer[1])
            }
            let before = independentStdioOpenDescriptorCount()
            let client = Client(fixture.server, serverInput: toServer[0], serverOutput: -1, writeEnd: toServer[1], readEnd: -1)
            client.disownServerEnds()
            client.start()
            defer {
                client.cancelRun()
                _ = client.stopped(within: 10)
            }
            #expect(!client.stopped(within: 0.2), "nothing was written yet, so nothing failed yet")
            #expect(client.request(1, "ping"))
            #expect(client.stopped(within: 5))
            #expect(fixture.log.all.count == 1 && fixture.log.all.first?.contains("write failed") == true, "\(fixture.log.all)")
            #expect(independentStdioOpenDescriptorCount() == before)
            #expect(fcntl(toServer[0], F_GETFD) != -1 && fcntl(toServer[1], F_GETFD) != -1)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["LIMB_INDEPENDENT_ISOLATED"] != nil), arguments: [false, true])
        func whenTheOutputCannotBeDuplicatedRunDoesNotServe(nonBlocking: Bool) throws {
            let fixture = try independentStdioFixture()
            let client = Client(fixture.server)
            defer { client.tearDown() }
            if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
            // A request is waiting in the channel: an answer to it would show the session served.
            var script = Client.requestLine(0, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"independent","version":"1"}}"#)
            script += Client.requestLine(1, "ping")
            #expect(client.send(script, absorb: false))
            #if canImport(Darwin)
            let threads = Set(independentStdioTransportThreads().map(\.id))
            #endif
            var limit = rlimit()
            try #require(getrlimit(openFilesResource, &limit) == 0)
            let original = limit
            var highest: Int32 = 0
            for descriptor in 0..<Int32(Swift.min(Int(getdtablesize()), 65536)) where fcntl(descriptor, F_GETFD) != -1 { highest = descriptor }
            limit.rlim_cur = rlim_t(highest + 3)
            try #require(setrlimit(openFilesResource, &limit) == 0)
            var fillers: [Int32] = []
            while true {
                let filler = dup(client.serverInput)
                if filler < 0 { break }
                fillers.append(filler)
            }
            close(fillers.removeLast())
            close(fillers.removeLast())
            let descriptors = independentStdioOpenDescriptorCount()
            client.start()
            let returned = client.stopped(within: 5)
            let descriptorsAfter = independentStdioOpenDescriptorCount()
            for filler in fillers { close(filler) }
            var restored = original
            #expect(setrlimit(openFilesResource, &restored) == 0)
            #expect(returned, "run did not return although it could not duplicate the output")
            #expect(fixture.log.all.count == 1 && fixture.log.all.first?.contains("could not duplicate") == true, "\(fixture.log.all)")
            #expect(descriptorsAfter == descriptors, "descriptors: \(descriptors) before, \(descriptorsAfter) after")
            #if canImport(Darwin)
            #expect(Set(independentStdioTransportThreads().map(\.id)).subtracting(threads).isEmpty, "a transport thread was left behind")
            #endif
            #expect(client.drain(seconds: 0.3).isEmpty, "something was written")
            #expect(fcntl(client.serverOutput, F_GETFD) != -1, "the caller's output was closed")
        }

        // MARK: The peer goes away, at every point

        /// While idle there is nothing to notice: a closed output shows only when something is
        /// written to it. The session ends at the end of its input like any other.
        @Test func aPeerThatClosedItsEndWhileIdleIsNoticedAtTheNextWriteOrNotAtAll() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            client.closeOutput()
            #expect(!client.stopped(within: 0.3))
            client.closeInput()
            #expect(client.stopped(within: 5))
            #expect(fixture.log.all == [])
        }

        @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair], [false, true])
        func aPeerThatLeavesInTheMiddleOfAFrameEndsTheSession(channel: IndependentStdioClient.Channel, nonBlocking: Bool) throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 30 }
            #if canImport(Darwin)
            let before = Set(independentStdioTransportThreads().map(\.id))
            #endif
            let client = Client(fixture.server, channel: channel)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
            client.start()
            #expect(client.initialize() == "2025-11-25")
            #if canImport(Darwin)
            let threads = Set(independentStdioSessionThreads(startedAfter: before).map(\.id))
            #endif
            #expect(client.call(1, "hold", #"{"tag":"bystander"}"#))
            #expect(client.call(2, "blob", #"{"size":3000000,"seed":2}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.contains("bystander") && $0.finishedTags.contains("blob-2") })
            // The client takes the first few kilobytes of the 3 MB frame and goes.
            #expect(client.outputReadable(within: 10))
            #expect(client.absorb(limit: 10_000) > 0)
            let left = Date()
            client.closeOutput()
            #expect(client.stopped(within: 10))
            #expect(Date().timeIntervalSince(left) < 5, "the grace period of 30 s is not for a peer that is gone")
            #expect(fixture.probe.cancelledTags == ["bystander"])
            #if canImport(Darwin)
            #expect(threadsGone(threads, within: 5))
            #endif
        }

        @Test func aSocketPeerThatLeavesIsNotLoggedAsAWriteFailure() throws {
            var logged: [String] = []
            for round in 0..<60 {
                let fixture = try independentStdioFixture()
                let client = Client(fixture.server, channel: .socketpair)
                if round % 2 == 1 { independentStdioSetNonBlocking(client.serverOutput) }
                client.start()
                #expect(client.initialize() == "2025-11-25")
                #expect(client.call(2, "blob", #"{"size":3000000,"seed":2}"#))
                #expect(client.outputReadable(within: 10))
                client.absorb(limit: 10_000)
                client.closeOutput()
                #expect(client.stopped(within: 10))
                logged += fixture.log.all
                client.tearDown()
            }
            #expect(logged == [], "\(logged.count) of 60 departures were logged: \(Set(logged))")
        }

        /// "requests in flight are cancelled at once" — the running ones and the ones still
        /// waiting for a handler slot.
        @Test func aPeerThatLeavesCancelsRequestsRunningAndQueued() throws {
            let fixture = try independentStdioFixture {
                $0.shutdownGraceSeconds = 30
                $0.budgets.maxConcurrentHandlers = 2
            }
            let client = Client.ready(fixture.server)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            var script = ""
            for id in 1...8 { script += Client.callLine(id, "hold", #"{"tag":"q\#(id)"}"#) }
            #expect(client.send(script))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 2 })
            client.closeOutput()
            #expect(client.request(100, "ping"))
            let left = Date()
            #expect(client.stopped(within: 10))
            #expect(Date().timeIntervalSince(left) < 5)
            // Every handler that started was cancelled; none ran to its end.
            #expect(Set(fixture.probe.startedTags) == Set(fixture.probe.cancelledTags))
            #expect(fixture.probe.finishedTags == [])
            #expect(fixture.log.all == [], "\(fixture.log.all)")
        }

        @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair])
        func requestsInFlightAreCancelledWhenTheClientGoesAwayAfterEndOfInput(channel: IndependentStdioClient.Channel) throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 30 }
            let client = Client.ready(fixture.server, channel: channel)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.call(1, "hold", #"{"tag":"orphan"}"#))
            // Its answer is the write that fails.
            #expect(client.call(2, "nap", #"{"ms":300,"tag":"late"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 2 })
            client.closeInput()
            client.closeOutput()
            #expect(fixture.probe.eventually(seconds: 10) { $0.finishedTags.contains("late") })
            let cancelled = fixture.probe.eventually(seconds: 5) { $0.cancelledTags.contains("orphan") }
            #expect(cancelled, "5 s after the write to the vanished client failed, the request in flight was still running")
            #expect(client.stopped(within: 5), "run had not returned 10 s after the client vanished")
        }
    }

    @Suite struct Limits {
        // MARK: maxFrameBytes

        @Test func theLargestFrameLimitWorksThroughASession() throws {
            let fixture = try independentStdioFixture { $0.budgets.maxFrameBytes = .max }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(client.request(1, "ping"))
            #expect(Client.id(of: client.readMessage()) == 1)
            let text = independentStdioBlob(size: 3 << 20, seed: 9)
            #expect(client.send(Client.callLine(2, "length", #"{"text":"\#(text)"}"#).dropLast() + "\r\n"))
            #expect(Client.text(of: client.readMessage(timeout: 60)) == "\(3 << 20)")
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(fixture.log.all == [])
        }

        /// The smallest limits make every message oversized. That is a useless server, not a
        /// crashing one: the first message is refused, the second closes the connection (§7.3
        /// "-32600; закрытие при повторе"), blank lines are still nothing.
        @Test(arguments: [0, 1])
        func theSmallestFrameLimitsRefuseEverythingAndDoNotCrash(limit: Int) throws {
            let fixture = try independentStdioFixture { $0.budgets.maxFrameBytes = limit }
            let client = Client.started(fixture.server)
            defer { client.tearDown() }
            #expect(client.send("\n\r\n\n" + Client.requestLine(1, "ping") + "\n"))
            let first = client.readMessage()
            #expect(Client.errorCode(of: first) == -32600 && Client.isNullID(first))
            #expect(!client.stopped(within: 0.2))
            #expect(client.send(String(repeating: "x", count: 100_000) + "\r\n"))
            #expect(Client.errorCode(of: client.readMessage()) == -32600)
            #expect(client.stopped(within: 10))
            #expect(client.drain(seconds: 0.2).isEmpty)
            #expect(fixture.log.all.count == 1, "\(fixture.log.all)")
            #expect(client.violations == [])
        }

        // MARK: maxOutboundBytes

        /// `Int.max`: no backpressure. 0 and 1: every response is over budget by itself, so
        /// handlers deliver one at a time — slow, but every answer still arrives intact.
        @Test(arguments: [Int.max, 0, 1])
        func extremeOutboundBudgetsStillDeliverEveryAnswer(budget: Int) throws {
            let fixture = try independentStdioFixture {
                $0.budgets.maxOutboundBytes = budget
                $0.budgets.maxQueuedRequests = 1024
            }
            let client = Client.ready(fixture.server, channel: budget == 1 ? .socketpair : .pipes)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            var script = ""
            var sizes: [Int: Int] = [:]
            for id in 1...60 {
                sizes[id] = [0, 1, 500, 40_000, 200_000][id % 5]
                script += Client.callLine(id, "blob", #"{"size":\#(sizes[id]!),"seed":\#(id)}"#)
                // Answered by the reader itself, from the urgent reserve.
                script += Client.requestLine(1000 + id, "ping")
            }
            // A handler that logs: with a tiny budget its messages may be dropped (§7.3), but
            // they must not break anything.
            script += Client.callLine(500, "chatty", #"{"tag":"c","count":200,"size":100}"#)
            #expect(client.send(script))
            let expected = Set(1...60).union((1...60).map { 1000 + $0 })
            let answers = client.responses(to: expected, timeout: 60)
            #expect(answers.count == expected.count, "missing: \(expected.subtracting(answers.keys).sorted().prefix(10))")
            let damaged = (1...60).filter { Client.text(of: answers[$0]) != independentStdioBlob(size: sizes[$0]!, seed: $0) }
            #expect(damaged == [])
            fixture.probe.release()
            #expect(Client.text(of: client.responses(to: [500], timeout: 20)[500]) == "released c")
            client.closeInput()
            #expect(client.stopped(within: 10))
            // With no budget at all the handler's log messages are dropped, which is logged once
            // ("the peer is not reading: log messages from handlers are being dropped" — the
            // peer is reading here; the budget is the cause).
            if budget == .max { #expect(fixture.log.all == [], "\(fixture.log.all)") }
            #expect(fixture.log.all.count <= 1, "\(fixture.log.all)")
            #expect(client.violations == [])
        }

        /// With a budget of zero and nobody reading, handlers must feel the pressure at once.
        @Test func aZeroOutboundBudgetHoldsHandlersBackWhenNobodyReads() throws {
            let fixture = try independentStdioFixture {
                $0.budgets.maxOutboundBytes = 0
                $0.budgets.maxConcurrentHandlers = 4
                $0.budgets.maxQueuedRequests = 500
                $0.outputDrainSeconds = 0.5
            }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var script = ""
            for id in 1...100 { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id)}"#) }
            #expect(client.send(script, absorb: false))
            usleep(1_000_000)
            let produced = fixture.probe.startedTags.count
            #expect(produced >= 1 && produced <= 12, "\(produced) of 100 responses were produced with nobody reading and no budget")
            let answers = client.responses(to: Set(1...100), timeout: 120)
            #expect(answers.count == 100)
            #expect(client.violations == [])
        }
    }
}
