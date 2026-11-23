#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Limb
import Testing


private typealias Client = IndependentStdioClient

/// A connected TCP pair over the loopback interface: the server's end and the client's.
private func tcpPair() throws -> (server: Int32, client: Int32) {
    let listener = socket(AF_INET, independentStdioStreamSocket, 0)
    try #require(listener >= 0)
    defer { close(listener) }
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = in_addr_t(UInt32(0x7F00_0001).bigEndian)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } }
    try #require(bound == 0)
    try #require(listen(listener, 1) == 0)
    let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
    try #require(named == 0)
    let client = socket(AF_INET, independentStdioStreamSocket, 0)
    try #require(client >= 0)
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) } }
    try #require(connected == 0)
    let server = accept(listener, nil, nil)
    try #require(server >= 0)
    #if canImport(Darwin)
    var on: Int32 = 1
    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    #endif
    return (server, client)
}

/// Makes the next `close` of a TCP socket send a reset instead of an orderly end.
private func resetOnClose(_ descriptor: Int32) {
    var option = linger(l_onoff: 1, l_linger: 0)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
}

enum IndependentStdioWay: String, CaseIterable, CustomTestStringConvertible {
    case pipes, socketpair, tcp, tcpReset
    var testDescription: String { rawValue }
}

/// A started client over the given channel. For `.tcpReset` the client's socket resets on close.
private func client(_ server: Server, _ way: IndependentStdioWay, nonBlocking: Bool = false) throws -> Client {
    let client: Client
    switch way {
    case .pipes: client = Client(server, channel: .pipes)
    case .socketpair: client = Client(server, channel: .socketpair)
    case .tcp, .tcpReset:
        let pair = try tcpPair()
        if way == .tcpReset { resetOnClose(pair.client) }
        client = Client(server, serverInput: pair.server, serverOutput: pair.server, writeEnd: pair.client, readEnd: pair.client)
    }
    if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
    return client.start()
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

/// The two kinds of meaning a time limit can have, as far as a test of a few seconds can tell.
private func waitsNoticeably(_ seconds: Double) -> Bool { seconds >= 1 }

private let unusualLimits: [Double] = [
    .nan, -.nan, .infinity, -.infinity, 0, -0.0, -1, -1e300, .leastNonzeroMagnitude, .leastNormalMagnitude, 1e-9,
    1e9, (1e9).nextDown, (1e9).nextUp, 999_999_999, 9e18, 1e300, .greatestFiniteMagnitude,
]

extension IndependentStdioTransportTests {
    @Suite struct Round4 {
        // MARK: 1. A peer that is gone ends the grace period

        /// The failed write comes during the grace period, and one of the handlers in flight
        /// ignores cancellation: it is still told to stop at once, and `run` does not wait for
        /// it longer than the second it gives such handlers.
        #if os(Linux)
        @Test(arguments: [IndependentStdioWay.pipes, .socketpair])
        #else
        @Test(arguments: [IndependentStdioWay.pipes, .socketpair, .tcp])
        #endif
        func aPeerGoneDuringTheGracePeriodCutsItShortEvenForAStubbornHandler(way: IndependentStdioWay) throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 60 }
            let client = try client(fixture.server, way)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.initialize() == "2025-11-25")
            #expect(client.call(1, "hold", #"{"tag":"held"}"#))
            #expect(client.call(2, "stubborn", #"{"ms":20000,"tag":"stubborn"}"#))
            // The answers are written after the peer closes its reading end.
            #expect(client.call(3, "nap", #"{"ms":400,"tag":"late"}"#))
            #expect(client.call(4, "nap", #"{"ms":800,"tag":"later"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 4 })
            client.closeInput()
            client.closeOutput()
            #expect(fixture.probe.eventually(seconds: 10) { $0.finishedTags.contains("late") })
            let failedAt = Date()
            #expect(fixture.probe.eventually(seconds: 3) { $0.cancelledTags.contains("held") && $0.cancelledTags.contains("stubborn") }, "cancelled: \(fixture.probe.cancelledTags)")
            #expect(client.stopped(within: 5), "run had not returned 5 s after the write to a vanished client failed")
            #expect(Date().timeIntervalSince(failedAt) < 4)
            #expect(fixture.log.all == [], "\(fixture.log.all)")
        }

        /// The failed write comes before the input ends (the client closes its reading end and
        /// keeps its input open): `endGracePeriod` is called with no `close` waiting. The `close`
        /// that follows must not wait for the stubborn handler beyond the second it gives such
        /// handlers. (Over a socket a client cannot close one direction so that writes fail:
        /// `shutdown(SHUT_RD)` does not do that on Darwin; pipes only.)
        @Test func aPeerGoneBeforeTheInputEndedLeavesNoGracePeriodForLater() throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 60 }
            let client = Client.ready(fixture.server)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.call(1, "stubborn", #"{"ms":20000,"tag":"stubborn"}"#))
            #expect(client.call(2, "hold", #"{"tag":"held"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 2 })
            client.closeOutput()
            let left = Date()
            // Something to write: the reader answers a ping itself, and that write fails.
            #expect(client.request(3, "ping"))
            #expect(fixture.probe.eventually(seconds: 5) { Set($0.cancelledTags) == ["stubborn", "held"] }, "cancelled: \(fixture.probe.cancelledTags)")
            #expect(client.stopped(within: 5))
            #expect(Date().timeIntervalSince(left) < 4)
            #expect(fixture.log.all == [], "\(fixture.log.all)")
        }

        /// A read that fails with ECONNRESET (a TCP peer that resets the connection) is a peer
        /// that left: requests in flight are cancelled at once, nothing is logged.
        @Test func aReadThatFailsWithConnectionResetEndsTheGracePeriod() throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 60 }
            let client = try client(fixture.server, .tcpReset)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.initialize() == "2025-11-25")
            #expect(client.call(1, "hold", #"{"tag":"held"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 1 })
            let left = Date()
            client.closeOutput()
            #expect(fixture.probe.eventually(seconds: 5) { $0.cancelledTags == ["held"] }, "the request in flight was not cancelled after the reset")
            #expect(client.stopped(within: 5))
            #expect(Date().timeIntervalSince(left) < 4)
            #expect(fixture.log.all == [], "\(fixture.log.all)")
        }

        /// A peer that is still there gets the whole grace period: cutting it short is only for
        /// a failed write or read, never for an ordinary end of input.
        @Test func anOrdinaryEndOfInputStillGetsTheWholeGracePeriod() throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 1.5 }
            let client = Client.ready(fixture.server)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.call(1, "nap", #"{"ms":700,"tag":"slow"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 1 })
            client.closeInput()
            let answer = client.responses(to: [1], timeout: 10)[1]
            #expect(Client.text(of: answer) == "woke slow")
            #expect(fixture.probe.cancelledTags == [])
            #expect(client.stopped(within: 5))
        }

        // MARK: 7. A peer that leaves, at every point and over every channel

        /// The client leaves (closes everything; over `tcpReset` with a reset) at a given point.
        /// Whatever the point and the channel: nothing is logged, `run` returns promptly,
        /// requests in flight are cancelled, the transport's threads end.
        @Test(arguments: IndependentStdioWay.allCases, ["idle", "midFrame", "inFlightAndQueued", "afterEndOfInput"])
        func aPeerThatLeavesIsAnOrdinaryEndAtEveryPoint(way: IndependentStdioWay, point: String) throws {
            let fixture = try independentStdioFixture {
                $0.shutdownGraceSeconds = 60
                $0.budgets.maxConcurrentHandlers = 4
            }
            #if canImport(Darwin)
            let before = Set(independentStdioTransportThreads().map(\.id))
            #endif
            let client = try client(fixture.server, way)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.initialize() == "2025-11-25")
            #if canImport(Darwin)
            let threads = Set(independentStdioSessionThreads(startedAfter: before).map(\.id))
            #endif
            switch point {
            case "midFrame":
                #expect(client.call(1, "hold", #"{"tag":"bystander"}"#))
                #expect(client.call(2, "blob", #"{"size":3000000,"seed":2}"#))
                #expect(fixture.probe.eventually(seconds: 10) { $0.finishedTags.contains("blob-2") })
                #expect(client.outputReadable(within: 10))
                client.absorb(limit: 10_000)
            case "inFlightAndQueued":
                // The naps' answers are the writes that fail (over TCP the second one); the holds
                // run or wait for a slot.
                var script = Client.callLine(9, "nap", #"{"ms":500,"tag":"late"}"#) + Client.callLine(10, "nap", #"{"ms":900,"tag":"later"}"#)
                for id in 1...6 { script += Client.callLine(id, "hold", #"{"tag":"q\#(id)"}"#) }
                script += Client.callLine(7, "blob", #"{"size":2000000,"seed":7}"#)
                #expect(client.send(script))
                #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 4 })
            case "afterEndOfInput":
                #expect(client.call(1, "hold", #"{"tag":"held"}"#))
                #expect(client.call(2, "nap", #"{"ms":300,"tag":"late"}"#))
                #expect(client.call(3, "nap", #"{"ms":700,"tag":"later"}"#))
                #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 3 })
                client.closeInput()
                usleep(50_000)
            default:
                break
            }
            let left = Date()
            client.closeOutput()
            // Nothing tells an idle server over a pipe that its client left until it writes or
            // its input ends; on a socket the end of input comes with the departure.
            if way == .pipes { client.closeInput() }
            #expect(client.stopped(within: 10), "run did not return after the client left")
            #expect(Date().timeIntervalSince(left) < 5, "the grace period of 60 s is not for a peer that is gone")
            // Every handler that started either finished or was cancelled; the holds never finish.
            let finished = Set(fixture.probe.finishedTags)
            #expect(Set(fixture.probe.cancelledTags) == Set(fixture.probe.startedTags.filter { !$0.hasPrefix("blob") && !finished.contains($0) }))
            #expect(fixture.log.all == [], "\(way) \(point): \(fixture.log.all)")
            #if canImport(Darwin)
            #expect(threadsGone(threads, within: 5))
            #endif
        }

        /// The same departures repeated, mid-frame, on every socket kind: the error the writer
        /// sees varies (EPIPE, ENOTCONN, ECONNRESET), and none of them is logged.
        @Test(arguments: [IndependentStdioWay.socketpair, .tcp, .tcpReset])
        func socketDeparturesInTheMiddleOfAFrameAreNeverLogged(way: IndependentStdioWay) throws {
            var logged: [String] = []
            var slow = 0
            for round in 0..<40 {
                let fixture = try independentStdioFixture()
                let client = try client(fixture.server, way, nonBlocking: round % 2 == 1)
                #expect(client.initialize() == "2025-11-25")
                #expect(client.call(2, "blob", #"{"size":2000000,"seed":2}"#))
                #expect(client.outputReadable(within: 10))
                client.absorb(limit: 1 + round * 997 % 60_000)
                let left = Date()
                client.closeOutput()
                if !client.stopped(within: 10) || Date().timeIntervalSince(left) > 5 { slow += 1 }
                logged += fixture.log.all
                client.tearDown()
            }
            #expect(slow == 0)
            #expect(logged == [], "\(logged.count) of 40 departures were logged: \(Set(logged))")
        }

        // MARK: 2. Retrying a full non-blocking output

        #if canImport(Darwin)
        @Test(arguments: [false, true], [0.0, 0.001, 0.4, 5.0])
        func aBlockedNonBlockingWriterDoesNotSpin(socket: Bool, drain: Double) throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = drain }
            let before = Set(independentStdioTransportThreads().map(\.id))
            let client = Client(fixture.server, channel: socket ? .socketpair : .pipes)
            defer { client.tearDown() }
            independentStdioSetNonBlocking(client.serverOutput)
            client.start()
            #expect(client.initialize() == "2025-11-25")
            let ids = Set(independentStdioSessionThreads(startedAfter: before).map(\.id))
            for id in 1...4 { #expect(client.send(Client.callLine(id, "blob", #"{"size":300000,"seed":\#(id)}"#), absorb: false)) }
            #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count >= 4 })
            usleep(200_000)
            // During the session.
            var start = independentStdioCPUSeconds(of: ids)
            usleep(1_000_000)
            let during = independentStdioCPUSeconds(of: ids) - start
            #expect(during < 0.004, "drain \(drain): a writer behind a full non-blocking \(socket ? "socket" : "pipe") used \(during) s of CPU in 1 s, before the input ended")
            // Left behind.
            client.closeInput()
            #expect(client.stopped(within: drain + 10))
            let writer = Set(independentStdioTransportThreads().filter { ids.contains($0.id) && $0.name == "limb-stdio-writer" }.map(\.id))
            #expect(writer.count == 1)
            start = independentStdioCPUSeconds(of: writer)
            usleep(1_000_000)
            let after = independentStdioCPUSeconds(of: writer) - start
            #expect(after < 0.01, "drain \(drain): a writer left behind used \(after) s of CPU in 1 s")
            // It still delivers everything once the client reads.
            #expect(client.responses(to: Set(1...4), timeout: 30).count == 4)
            #expect(threadsGone(writer, within: 5))
        }
        #endif

        // MARK: 4. Unusual time limits

        /// `outputDrainSeconds`: a client that reads nothing at the end of input. "Do not wait":
        /// `run` gives up at once and says so. "As long as it takes": `run` waits; when the client
        /// reads after all, it gets everything and nothing is logged.
        @Test(arguments: unusualLimits)
        func unusualDrainLimitsMeanWhatTheySay(seconds: Double) throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = seconds }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            for id in 1...2 { #expect(client.send(Client.callLine(id, "blob", #"{"size":300000,"seed":\#(id)}"#), absorb: false)) }
            #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count >= 2 })
            usleep(100_000)
            client.closeInput()
            if waitsNoticeably(seconds) {
                #expect(!client.stopped(within: 1.5), "\(seconds): run gave up although the limit says to wait")
                #expect(fixture.log.all == [])
                #expect(client.responses(to: [1, 2], timeout: 30).count == 2)
                #expect(client.stopped(within: 5))
                #expect(fixture.log.all == [], "\(fixture.log.all)")
            } else {
                #expect(client.stopped(within: 2), "\(seconds): run waited although the limit says not to")
                #expect(fixture.log.all.count == 1 && fixture.log.all.first?.contains("did not read") == true, "\(fixture.log.all)")
                #expect(client.responses(to: [1, 2], timeout: 30).count == 2)
            }
        }

        /// `shutdownGraceSeconds`: a request in flight at the end of input. "Do not wait": it is
        /// cancelled at once. "As long as it takes": it is not cancelled, its answer arrives when
        /// it finishes, and `run` returns then.
        @Test(arguments: unusualLimits)
        func unusualGracePeriodsMeanWhatTheySay(seconds: Double) throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = seconds }
            let client = Client.ready(fixture.server)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.call(1, "hold", #"{"tag":"held"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.count == 1 })
            client.closeInput()
            if waitsNoticeably(seconds) {
                #expect(!fixture.probe.eventually(seconds: 1.5) { !$0.cancelledTags.isEmpty }, "\(seconds): the request was cancelled although the grace period says to wait")
                #expect(!client.hasReturned)
                fixture.probe.release()
                #expect(Client.text(of: client.responses(to: [1], timeout: 10)[1]) == "released held")
                #expect(client.stopped(within: 5))
            } else {
                #expect(fixture.probe.eventually(seconds: 2) { $0.cancelledTags == ["held"] }, "\(seconds): the request was not cancelled at once")
                #expect(client.stopped(within: 3))
            }
            #expect(fixture.log.all == [], "\(fixture.log.all)")
        }

        // MARK: 5. Nothing left to write, tiny limits

        /// Thousands of sessions with drain limits of zero or next to it, idle or with answers the
        /// client read before its input ended: none has anything left to write, so none is
        /// reported as a peer that did not read.
        @Test func tinyDrainLimitsNeverReportASessionWithNothingLeftToWrite() throws {
            var reported = 0
            var stuck = 0
            for (index, limit) in [0.0, 1e-9, 1e-6, 0.001].enumerated() {
                let fixture = try independentStdioFixture { $0.outputDrainSeconds = limit }
                for round in 0..<500 {
                    let client = Client.ready(fixture.server, channel: round % 3 == 2 ? .socketpair : .pipes)
                    if round % 2 == 1 {
                        #expect(client.call(1, "blob", #"{"size":\#((round * 131 + index) % 40_000),"seed":1}"#))
                        #expect(client.responses(to: [1], timeout: 10).count == 1)
                    }
                    client.closeInput()
                    if !client.stopped(within: 10) { stuck += 1 }
                    client.tearDown()
                }
                reported += fixture.log.all.count
            }
            #expect(stuck == 0)
            #expect(reported == 0, "\(reported) of 2000 sessions with nothing left to write were reported as a peer that did not read")
        }

        // MARK: 6. What a child process inherits

        #if canImport(Darwin)
        /// A child process started during a session (with `posix_spawn`, which hands over every
        /// descriptor that is not close-on-exec; its table is read with `proc_pidinfo`) inherits none of the session's own descriptors.
        @Test func aChildProcessStartedDuringASessionInheritsNothingOfIt() throws {
            let fixture = try independentStdioFixture()
            func open() -> Set<Int32> {
                var set: Set<Int32> = []
                for descriptor in 0..<Int32(Swift.min(Int(getdtablesize()), 65536)) where fcntl(descriptor, F_GETFD) != -1 { set.insert(descriptor) }
                return set
            }
            var fresh: Set<Int32> = []
            var inherited: Set<Int32> = []
            for _ in 0..<10 {
                let client = Client(fixture.server)
                let before = open()
                client.start()
                #expect(client.initialize() == "2025-11-25")
                fresh = open().subtracting(before)
                // A child that opens nothing itself; its descriptors are listed from here.
                var child: pid_t = 0
                let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("10"), nil]
                let spawned = posix_spawn(&child, "/bin/sleep", nil, nil, arguments, environ)
                for argument in arguments { free(argument) }
                try #require(spawned == 0)
                usleep(100_000)
                var table = [proc_fdinfo](repeating: proc_fdinfo(), count: 4096)
                let bytes = proc_pidinfo(child, PROC_PIDLISTFDS, 0, &table, Int32(table.count * MemoryLayout<proc_fdinfo>.stride))
                kill(child, SIGKILL)
                var status: Int32 = 0
                waitpid(child, &status, 0)
                try #require(bytes > 0)
                let numbers = Set(table.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride).map(\.proc_fd))
                inherited = fresh.intersection(numbers)
                client.closeInput()
                #expect(client.stopped(within: 10))
                client.tearDown()
                if fresh.count == 3 { break }
            }
            #expect(fresh.count == 3, "a session opened \(fresh.count) descriptors of its own")
            #expect(inherited == [], "a child process inherited the session's descriptors \(inherited.sorted())")
        }
        #endif
    }
}


/// A started session on a non-blocking output whose client reads nothing; its writer is blocked
/// behind the full channel once this returns. Returns the client and the session's threads.
private func blockedNonBlockingSession(
    _ fixture: IndependentStdioFixture, socket: Bool, count: Int = 4, size: Int = 300_000
) throws -> (client: IndependentStdioClient, threads: Set<UInt64>) {
    #if canImport(Darwin)
    let before = Set(independentStdioTransportThreads().map(\.id))
    #endif
    let client = Client(fixture.server, channel: socket ? .socketpair : .pipes)
    independentStdioSetNonBlocking(client.serverOutput)
    client.start()
    #expect(client.initialize() == "2025-11-25")
    #if canImport(Darwin)
    let threads = Set(independentStdioSessionThreads(startedAfter: before).map(\.id))
    #else
    let threads: Set<UInt64> = []
    #endif
    for id in 1...count { #expect(client.send(Client.callLine(id, "blob", #"{"size":\#(size),"seed":\#(id)}"#), absorb: false)) }
    #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.filter { $0.hasPrefix("blob") }.count >= count })
    usleep(150_000)
    return (client, threads)
}

#if canImport(Darwin)
private func writerCPU(_ threads: Set<UInt64>, over seconds: Double) -> Double {
    let writer = Set(independentStdioTransportThreads().filter { threads.contains($0.id) && $0.name == "limb-stdio-writer" }.map(\.id))
    let start = independentStdioCPUSeconds(of: writer)
    usleep(useconds_t(seconds * 1e6))
    return independentStdioCPUSeconds(of: writer) - start
}
#endif

extension IndependentStdioTransportTests {
    @Suite struct Round5 {
        #if canImport(Darwin)
        @Test(arguments: [false, true], [0.0, 1e-6, 0.4, 3.0, 30.0, Double.infinity])
        func theWriterBehindAFullNonBlockingOutputCostsNothingInEveryPhase(socket: Bool, drain: Double) throws {
            let fixture = try independentStdioFixture {
                $0.outputDrainSeconds = drain
                $0.shutdownGraceSeconds = 1.5
            }
            let (client, threads) = try blockedNonBlockingSession(fixture, socket: socket)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            let label = "\(socket ? "socket" : "pipe"), drain \(drain)"
            let before = writerCPU(threads, over: 1)
            #expect(before < 0.004, "\(label): \(before) s of CPU in 1 s before the input ended")
            // A request in flight keeps the grace period going after the cancellation.
            #expect(client.call(50, "hold", #"{"tag":"held"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.contains("held") })
            client.cancelRun()
            usleep(100_000)
            let grace = writerCPU(threads, over: 1)
            #expect(grace < 0.004, "\(label): \(grace) s of CPU in 1 s of grace period after a cancellation")
            // The grace period (1.5 s) is over now or soon; draining begins.
            #expect(fixture.probe.eventually(seconds: 5) { $0.cancelledTags.contains("held") })
            usleep(200_000)
            if drain >= 3 {
                #expect(!client.hasReturned)
                let draining = writerCPU(threads, over: 1)
                #expect(draining < 0.004, "\(label): \(draining) s of CPU in 1 s of draining")
            } else {
                #expect(client.stopped(within: drain + 5))
                let left = writerCPU(threads, over: 1)
                #expect(left < 0.002, "\(label): \(left) s of CPU in 1 s left behind")
            }
            // Everything still arrives once the client reads, and the writer ends.
            #expect(client.responses(to: Set(1...4), timeout: 30).count == 4)
            #expect(client.stopped(within: 10))
            #if canImport(Darwin)
            #expect(threadsGone(threads, within: 5))
            #endif
        }
        #endif

        /// Cancelling the task before, during and after draining, with the writer blocked behind
        /// a full non-blocking output: `run` returns (by the drain limit at the latest once
        /// draining has begun), nothing is lost for a client that reads later, no thread stays.
        @Test(arguments: [false, true], ["before", "during", "after"])
        func cancellingAtEveryPhaseOfDrainingEndsCleanly(socket: Bool, when: String) throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 1 }
            let (client, threads) = try blockedNonBlockingSession(fixture, socket: socket)
            defer { client.tearDown() }
            switch when {
            case "before":
                client.cancelRun()
            case "during":
                client.closeInput()
                usleep(300_000)
                #expect(!client.hasReturned)
                client.cancelRun()
            default:
                client.closeInput()
                #expect(client.stopped(within: 10))
                client.cancelRun()
            }
            #expect(client.stopped(within: 10), "\(when): run did not return")
            #expect(fixture.log.all.allSatisfy { $0.contains("did not read") }, "\(fixture.log.all)")
            #expect(client.responses(to: Set(1...4), timeout: 30).count == 4)
            #if canImport(Darwin)
            #expect(threadsGone(threads, within: 5))
            #endif
        }

        /// Thousands of sessions whose writer is behind a full non-blocking output when the input
        /// ends, with drain limits of zero and next to it: `cleanUp` often runs while the writer
        /// is still in `poll` on the wake-up pipe. Right after `run` returns the test takes every
        /// descriptor number that is free (as a caller opening new connections would), holds
        /// them while the old client reads and the writer ends, and checks that none of them was
        /// closed or written to. At the end the process holds as many descriptors as before.
        @Test func zeroDrainLimitsNeverTouchADescriptorNumberReusedAfterRun() throws {
            let baseline = independentStdioOpenDescriptorCount()
            var touched: [String] = []
            var stuck = 0
            var incomplete = 0
            var buffer = [UInt8](repeating: 0, count: 65536)
            for (index, limit) in [0.0, 1e-9, 1e-4, 0.002].enumerated() {
                let fixture = try independentStdioFixture { $0.outputDrainSeconds = limit }
                for round in 0..<300 {
                    let socket = round % 2 == 1
                    let client = Client(fixture.server, channel: socket ? .socketpair : .pipes)
                    independentStdioSetNonBlocking(client.serverOutput)
                    client.start()
                    guard client.initialize() == "2025-11-25" else {
                        stuck += 1
                        client.tearDown()
                        continue
                    }
                    let size = socket ? 20_000 : 100_000
                    client.send(Client.callLine(1, "blob", #"{"size":\#(size),"seed":\#(round)}"#), absorb: false)
                    _ = fixture.probe.eventually(seconds: 10) { $0.finishedTags.count > round }
                    client.closeInput()
                    guard client.stopped(within: 10) else {
                        stuck += 1
                        client.tearDown()
                        continue
                    }
                    // Take the freed numbers: four pipes, eight descriptors.
                    var taken: [Int32] = []
                    for _ in 0..<4 {
                        var ends: [Int32] = [-1, -1]
                        if pipe(&ends) == 0 {
                            independentStdioSetNonBlocking(ends[0])
                            taken += ends
                        }
                    }
                    if Client.text(of: client.responses(to: [1], timeout: 10)[1]) != independentStdioBlob(size: size, seed: round) { incomplete += 1 }
                    client.tearDown()
                    usleep(2000)
                    for (position, descriptor) in taken.enumerated() {
                        if fcntl(descriptor, F_GETFD) == -1 {
                            touched.append("limit \(limit), session \(round): descriptor \(descriptor) was closed under the caller")
                        } else if position % 2 == 0, read(descriptor, &buffer, buffer.count) > 0 {
                            touched.append("limit \(limit), session \(round): bytes arrived in descriptor \(descriptor)")
                        }
                    }
                    for descriptor in taken { close(descriptor) }
                    _ = index
                }
            }
            #expect(stuck == 0)
            #expect(incomplete == 0, "\(incomplete) answers did not arrive complete")
            #expect(touched.isEmpty, "\(touched.count) reused descriptors were touched: \(touched.prefix(5))")
            var after = Int.max
            let deadline = Date().addingTimeInterval(10)
            repeat {
                after = independentStdioOpenDescriptorCount()
                if after <= baseline + 6 { break }
                usleep(50_000)
            } while Date() < deadline
            #expect(after <= baseline + 6, "open descriptors: \(baseline) before 1200 sessions, \(after) after")
        }
    }
}
