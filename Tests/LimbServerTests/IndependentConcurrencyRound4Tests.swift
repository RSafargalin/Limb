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

// Tests written against the fourth version of the engine: one queue per connection at the
// gate with a set of saturated connections, queue limits counted apart for them, deferred
// events kept in order, and the drain rule of one kilobyte per interval.

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

/// A connection on a real `OutboundQueue` that nobody drains unless the test does.
private final class StuckClient: @unchecked Sendable {
    let queue: OutboundQueue
    let connection: Connection

    init(_ server: Server, budget: Int = 1000) {
        queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: 1 << 20)
        connection = server.connect(to: queue)
    }

    func call(_ tool: String, id: String, arguments: String = "{}") {
        connection.receive(
            Array(#"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments),\#(modernMeta)}}"#.utf8))
    }

    func send(_ text: String) { connection.receive(Array(text.utf8)) }

    func cancel(_ id: String) {
        connection.receive(Array(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"\#(id)"}}"#.utf8))
    }

    /// Takes and "writes" everything queued; returns the messages.
    @discardableResult func drain() -> [JSONValue] {
        let frames = queue.takeAvailable()
        queue.didWrite(bytes: frames.reduce(0) { $0 + $1.count })
        return frames.compactMap { try? JSON.parse($0) }
    }

    /// Fills the connection: one response queued (over budget), `places` responses parked.
    /// Afterwards every further request of this connection waits for a place.
    func saturate(places: Int, tool: String = "blob") async {
        call(tool, id: "fill-0")
        _ = await independentConcurrencyEventually { self.queue.usage.queuedFrames >= 1 }
        for index in 1...places { call(tool, id: "fill-\(index)") }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@Suite(.timeLimit(.minutes(8)))
struct IndependentConcurrencyGateQueueTests {
    private func makeServer(
        limit: Int, queueLimit: Int, order: ICBox<[String]> = ICBox([]), holding: ICMeter = ICMeter(), gate: ICGate = ICGate(),
        configure: @escaping @Sendable (inout ServerConfiguration) -> Void = { _ in }
    ) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = limit
            configuration.budgets.maxQueuedRequests = queueLimit
            configure(&configuration)
        }
        try server.register(tool: ToolDefinition(name: "blob")) { arguments, _ in
            if let tag = arguments["tag"]?.stringValue { order.update { $0.append(tag) } }
            return .text(String(repeating: "b", count: 3000))
        }
        try server.register(tool: ToolDefinition(name: "quick")) { arguments, _ in
            if let tag = arguments["tag"]?.stringValue { order.update { $0.append(tag) } }
            return .text("q")
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gate.wait()
            return .text("held")
        }
        return server
    }

    /// The limits of the queue, counted apart: a connection that waits for its own peer has
    /// the limit to itself; the requests that wait for a handler slot share it across the
    /// server, exactly, whatever the stuck connection has piled up.
    @Test func queueLimitsAreExactForASaturatedConnectionAndForTheOthers() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let server = try makeServer(limit: 2, queueLimit: 4, holding: holding, gate: gate)
        let stuck = StuckClient(server)
        await stuck.saturate(places: 2)
        // Its own backlog is bounded by the same number: four wait, the fifth is refused.
        for index in 0..<4 { stuck.call("blob", id: "w\(index)") }
        #expect(stuck.queue.usage.queuedFrames == 1, "a waiting request of the saturated connection was refused or answered")
        stuck.call("blob", id: "w4")
        // The refusal is queued at once, as an urgent frame. (The queue is not drained here:
        // that would let the stuck connection move, and this test needs it to stay stuck.)
        let usage = stuck.queue.usage
        #expect(usage.queuedFrames == 2 && usage.urgentBytes > 0, "the fifth waiting request of a saturated connection was not refused")

        // The others: two run, exactly four wait for a slot, the next is refused.
        let a = ICWire(server)
        let b = ICWire(server)
        a.call("hold")
        b.call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        a.call("hold")
        b.call("hold")
        a.call("hold")
        b.call("hold")
        #expect(a.sink.history.isEmpty && b.sink.history.isEmpty, "the stuck connection's backlog took room from the others")
        let extra = b.call("hold", id: "extra")
        let overload = await b.sink.next(timeout: .seconds(2))
        #expect(overload?.json?["id"] == extra.json)
        #expect(overload?.json?.independentConcurrencyErrorCode == -31001, "the server-wide queue took a fifth waiting request")
        // A cancellation on the stuck connection does not make room for the others,
        // and one of theirs does.
        stuck.cancel("w0")
        b.call("hold", id: "extra-2")
        #expect((await b.sink.next(timeout: .seconds(2)))?.json?.independentConcurrencyErrorCode == -31001)
        let queued = a.call("hold")
        _ = queued
        #expect((await a.sink.next(timeout: .milliseconds(100)))?.json?.independentConcurrencyErrorCode == -31001)
        gate.open()
        #expect(await independentConcurrencyEventually { holding.total == 6 })
        let refused = stuck.drain().first { $0["id"] == "w4" }
        #expect(refused?.independentConcurrencyErrorCode == -31001)
        stuck.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.connection.close(graceSeconds: 0) }
    }

    /// When the stuck peer reads a little, its backlog is back among the requests that wait
    /// for a slot. It may then use the shared room like anyone else — but only for what it
    /// can actually run: requests that will go straight back to waiting for their own peer
    /// must not take the others' room in the meantime.
    @Test func aStuckConnectionThatReadsALittleDoesNotCrowdTheOthersOutAgain() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let server = try makeServer(limit: 2, queueLimit: 4, holding: holding, gate: gate)
        let stuck = StuckClient(server)
        await stuck.saturate(places: 2)
        for index in 0..<4 { stuck.call("blob", id: "w\(index)") }
        let healthy = ICWire(server)
        healthy.call("hold")
        healthy.call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        healthy.call("hold")
        healthy.call("hold")
        #expect(healthy.sink.history.isEmpty)
        // The stuck peer reads what is queued: `didWrite` resumes every capacity waiter, so both
        // parked responses are queued and both places free (and the output is over budget
        // again). Both handler slots are busy, so none of its waiting requests can start.
        stuck.drain()
        try await Task.sleep(for: .milliseconds(100))
        // Two of the healthy connection's requests wait for a slot; there is room for two more.
        healthy.call("hold")
        healthy.call("hold")
        let refusal = await healthy.sink.next(timeout: .milliseconds(300))
        #expect(
            refusal == nil,
            "a healthy connection was refused (\(refusal?.json?.independentConcurrencyErrorCode ?? 0)) with two of its requests waiting and a limit of four")
        gate.open()
        stuck.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.connection.close(graceSeconds: 0) }
    }

    @Test func cancellingTheHeadOfASaturatedConnectionsQueueLetsTheNextOneThrough() async throws {
        let order = ICBox<[String]>([])
        let server = try makeServer(limit: 2, queueLimit: 100, order: order)
        let stuck = StuckClient(server)
        await stuck.saturate(places: 2)
        for tag in ["w1", "w2", "w3", "w4"] { stuck.call("quick", id: tag, arguments: #"{"tag":"\#(tag)"}"#) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.value.isEmpty)
        // The oldest waiting request is cancelled, then one in the middle.
        stuck.cancel("w1")
        stuck.cancel("w3")
        // Meanwhile other connections are served, in their own order.
        let other = ICWire(server)
        #expect(try await other.request("tools/call", ["name": "quick", "arguments": ["tag": "o1"]]).independentConcurrencyText == "q")
        // The peer reads: the remaining requests run in their order; the cancelled ones never do.
        var answered: Set<String> = []
        for _ in 0..<200 {
            for message in stuck.drain() { if let id = message["id"]?.stringValue, message["method"] == nil { answered.insert(id) } }
            if answered.isSuperset(of: ["w2", "w4"]) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        // Two places free at once when the peer reads, so w2 and w4 may run side by side and
        // record in either order (seen once in 20 runs); start order is checked under `.serial`.
        #expect(order.value.first == "o1" && order.value.count == 3 && Set(order.value.dropFirst()) == ["w2", "w4"], "\(order.value)")
        #expect(answered.isSuperset(of: ["fill-0", "fill-1", "fill-2", "w2", "w4"]))
        #expect(answered.isDisjoint(with: ["w1", "w3"]))
        await stuck.connection.close(graceSeconds: 0)
    }

    @Test func closingAConnectionWithALongBacklogIsQuickAndLeavesNothingBehind() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let order = ICBox<[String]>([])
        let server = try makeServer(limit: 3, queueLimit: 50_000, order: order, holding: holding, gate: gate)
        let stuck = StuckClient(server)
        await stuck.saturate(places: 3)
        for index in 0..<30_000 { stuck.call("quick", id: "b\(index)", arguments: #"{"tag":"backlog"}"#) }
        // Cancelling from both ends and the middle of a long backlog.
        for index in stride(from: 0, to: 30_000, by: 7) { stuck.cancel("b\(index)") }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await independentConcurrencyFinishes(within: .seconds(60)) { await stuck.connection.close(graceSeconds: 0) })
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(10), "closing a connection with a backlog of 30000 took \(elapsed)")
        stuck.queue.close()
        #expect(order.value.isEmpty, "a request of the backlog ran")
        // Nothing of it is left at the gate: three run, exactly the queue limit waits.
        let probe = ICWire(server)
        for _ in 0..<3 { probe.call("hold") }
        #expect(await independentConcurrencyEventually { holding.total == 3 })
        gate.open()
        #expect(await independentConcurrencyEventually { probe.sink.history.count == 3 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.value.isEmpty)
    }

    /// A transport may drop a connection without `close()`. The object's identity is then free
    /// for a new connection, which must start with a clean slate at the gate.
    @Test func aNewConnectionDoesNotInheritTheSaturationOfADroppedOne() async throws {
        let server = try makeServer(limit: 2, queueLimit: 100)
        var slow = 0
        var reused = 0
        var seen: Set<ObjectIdentifier> = []
        for round in 0..<150 {
            weak var dropped: Connection?
            do {
                let stuck = StuckClient(server)
                dropped = stuck.connection
                seen.insert(ObjectIdentifier(stuck.connection))
                await stuck.saturate(places: 2)
                for index in 0..<3 { stuck.call("blob", id: "w\(index)") }
                if round % 2 == 0 { stuck.cancel("w0") }
                // The transport gives up: it closes its queue and forgets the connection.
                stuck.queue.close()
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while dropped != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(dropped == nil, "round \(round): a dropped connection is still alive")
            if dropped != nil { break }
            // New connections, some of which get the dropped one's identity.
            for _ in 0..<3 {
                let fresh = ICWire(server)
                if seen.contains(ObjectIdentifier(fresh.connection)) { reused += 1 }
                let id = fresh.call("quick")
                if (await fresh.sink.next(timeout: .seconds(3)))?.json?["id"] != id.json { slow += 1 }
                await fresh.connection.close(graceSeconds: 0)
            }
            if slow > 0 { break }
        }
        #expect(slow == 0, "a new connection's first request did not run: it inherited the state of a dropped connection")
        #expect(reused > 0, "no identity was reused in 150 rounds: the test did not exercise the case")
    }
}

// MARK: - Deferred events while a flush is under way

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyDeferredOrderTests {
    @Test func eventsArrivingDuringAFlushGoBehindThoseAlreadyWaiting() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
        for round in 0..<40 {
            // Room for about three notifications at a time.
            let client = StuckClient(server, budget: 450)
            let uris = (0..<12).map { "ic://r\(round)/\($0)" }
            let list = uris.map { "\"\($0)\"" }.joined(separator: ",")
            client.send(
                #"{"jsonrpc":"2.0","id":"sub","method":"subscriptions/listen","params":{"notifications":{"resourceSubscriptions":[\#(list)]},\#(modernMeta)}}"#)
            client.call("blob", id: "big")
            #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
            for uri in uris.prefix(6) { server.notifyResourceUpdated(uri: uri) }
            server.notifyResourceUpdated(uri: uris[0])  // already waiting: not a second time
            var delivered: [String] = []
            func collect() {
                for message in client.drain() {
                    if message["method"] == "notifications/resources/updated", let uri = message["params"]?["uri"]?.stringValue {
                        delivered.append(uri)
                    }
                }
            }
            // The peer starts reading; the first deferred events go out.
            collect()
            _ = await independentConcurrencyEventually(timeout: .seconds(2)) { client.queue.usage.queuedFrames > 0 }
            // In the middle of that, new events arrive, and one that may already have gone out.
            for uri in uris.suffix(6) { server.notifyResourceUpdated(uri: uri) }
            for _ in 0..<300 {
                collect()
                if delivered.count >= 12 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            try await Task.sleep(for: .milliseconds(60))
            collect()
            #expect(delivered == uris, "round \(round): delivered \(delivered.map { $0.split(separator: "/").last ?? "" })")
            if delivered != uris { break }
            await client.connection.close(graceSeconds: 0)
            client.queue.close()
        }
    }
}

// MARK: - The drain rule: one kilobyte per interval

@Suite(.timeLimit(.minutes(5)), .serialized)
struct IndependentConcurrencyKilobyteRuleTests {
    private static let total = 90_000

    private final class Session: @unchecked Sendable {
        let toServer: (read: Int32, write: Int32)
        let fromServer: (read: Int32, write: Int32)
        let returned = ICBox(false)
        var received = 0
        var tail: [UInt8] = []

        init(_ server: Server) {
            signal(SIGPIPE, SIG_IGN)
            var input: [Int32] = [0, 0]
            var output: [Int32] = [0, 0]
            precondition(pipe(&input) == 0 && pipe(&output) == 0)
            toServer = (input[0], input[1])
            fromServer = (output[0], output[1])
            let transport = StdioTransport(input: input[0], output: output[1])
            let returned = returned
            Task.detached {
                await server.run(transport)
                returned.set(true)
            }
        }

        /// Reads up to `limit` bytes; 0 on timeout, -1 at end of stream.
        func read(limit: Int, timeoutMilliseconds: Int32) -> Int {
            var descriptor = pollfd(fd: fromServer.read, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return 0 }
            var buffer = [UInt8](repeating: 0, count: limit)
            #if canImport(Darwin)
            let count = Darwin.read(fromServer.read, &buffer, limit)
            #elseif canImport(Glibc)
            let count = Glibc.read(fromServer.read, &buffer, limit)
            #else
            let count = Musl.read(fromServer.read, &buffer, limit)
            #endif
            guard count > 0 else { return -1 }
            received += count
            tail = Array((tail + buffer[..<count]).suffix(8))
            return count
        }

        func closeAll() {
            close(toServer.read)
            close(fromServer.write)
            close(fromServer.read)
        }
    }

    private func makeServer(drain: Double, diagnostics: ICBox<[String]>) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.shutdownGraceSeconds = 0.3
            configuration.outputDrainSeconds = drain
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: Self.total)) }
        return server
    }

    /// Brings a session to the point where the pipe is full, the session is draining, the
    /// piece that was under way is through, and the writer has a few kilobytes left.
    private func prepare(_ session: Session) async {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"blob",\#(modernMeta)}}"# + "\n"
        _ = request.withCString { write(session.toServer.write, $0, strlen($0)) }
        try? await Task.sleep(for: .milliseconds(300))
        close(session.toServer.write)  // end of input: the session starts draining
        try? await Task.sleep(for: .milliseconds(600))
        // Fast: everything but a full pipe and six kilobytes.
        let fast = Self.total - 65536 - 6 * 1024
        while session.received < fast {
            if session.read(limit: min(4096, fast - session.received), timeoutMilliseconds: 2000) <= 0 { break }
        }
    }

    private static var pipeProgressBytes: Int {
        #if os(Linux)
        Int(sysconf(Int32(_SC_PAGESIZE)))
        #else
        1024
        #endif
    }

    /// A reader that frees a writable amount of space once per second stays within the
    /// two-second drain limit.
    @Test func aPeerThatTakesAKilobytePerIntervalIsStillReading() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = Session(try makeServer(drain: 2.0, diagnostics: diagnostics))
        await prepare(session)
        // Slow: one read per second until the writer is done.
        var slowReads = 0
        while !session.returned.value, slowReads < 60 {
            if session.read(limit: Self.pipeProgressBytes, timeoutMilliseconds: 3000) < 0 { break }
            slowReads += 1
            try await Task.sleep(for: .seconds(1))
        }
        let gaveUp = diagnostics.value.filter { $0.contains("did not read") }
        #expect(gaveUp.isEmpty, "given up after \(slowReads) reads of \(Self.pipeProgressBytes) bytes per second with a limit of two seconds")
        #expect(session.returned.value, "run did not return after \(slowReads) slow reads")
        // The rest is in the pipe; the response arrives whole.
        while session.read(limit: 65536, timeoutMilliseconds: 2000) > 0 {}
        #expect(session.received > Self.total)
        #expect(session.tail.last == 0x0A)
        session.closeAll()
    }

    /// Just below the rule: one kilobyte every 3.2 seconds with a limit of two. That peer is
    /// given up — after the limit, not at once.
    @Test func aPeerThatTakesLessThanAKilobytePerIntervalIsGivenUp() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = Session(try makeServer(drain: 2.0, diagnostics: diagnostics))
        await prepare(session)
        let clock = ContinuousClock()
        _ = session.read(limit: 1024, timeoutMilliseconds: 3000)
        let start = clock.now
        let returned = session.returned
        #expect(await independentConcurrencyEventually(timeout: .seconds(20)) { returned.value }, "run never gave up on a peer that stopped")
        #expect(clock.now - start >= .milliseconds(1500), "given up \(clock.now - start) after the peer's last read; the limit is two seconds")
        #expect(diagnostics.value.contains { $0.contains("did not read") })
        session.closeAll()
    }
}


/// SplitMix64, so that a failing seed can be replayed.
private struct R4Random {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x4444 }
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

private func r4SpinUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    var spins = 0
    while !condition() {
        spins += 1
        if spins % 256 == 0, ContinuousClock.now >= deadline { return false }
        await Task.yield()
    }
    return true
}

@Suite(.timeLimit(.minutes(8)))
struct IndependentConcurrencyGateQueueMoreTests {
    private func makeServer(
        limit: Int, queueLimit: Int, execution: ExecutionMode = .concurrent, holding: ICMeter = ICMeter(), gate: ICGate = ICGate()
    ) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = limit
            configuration.budgets.maxQueuedRequests = queueLimit
            configuration.execution = execution
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
        try server.register(tool: ToolDefinition(name: "quick")) { _, _ in .text("q") }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gate.wait()
            return .text("held")
        }
        return server
    }

    /// P2 from the other side. The rule: "requests of a saturated connection are counted against
    /// that connection alone … A stuck connection cannot crowd others out of the queue." Here the
    /// peer stops reading and its requests arrive while every handler slot is busy, so the gate
    /// never asks the connection for a place and never learns that it has none. Its requests wait
    /// for their own peer all the same — and they take the whole server-wide room.
    @Test func requestsOfAStuckPeerThatArriveWhileEverySlotIsBusyDoNotCrowdOthersOut() async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let server = try makeServer(limit: 2, queueLimit: 4, holding: holding, gate: gate)
        let stuck = StuckClient(server)
        // One response queued (over budget), two parked: both places taken, both slots free.
        await stuck.saturate(places: 2)
        let healthy = ICWire(server)
        healthy.call("hold")
        healthy.call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        // Now the stuck peer's further requests: they can never run before their peer reads.
        for index in 0..<4 { stuck.call("blob", id: "w\(index)") }
        #expect(stuck.queue.usage.queuedFrames == 1, "a request of the stuck connection was refused or answered")
        // The healthy connection has nothing waiting; its next request must be queued.
        let third = healthy.call("hold")
        let refusal = await healthy.sink.next(timeout: .milliseconds(300))
        #expect(
            refusal == nil,
            "a healthy connection's first waiting request was refused (\(refusal?.json?.independentConcurrencyErrorCode ?? 0)): the room is taken by requests that wait for another connection's peer")
        gate.open()
        if refusal == nil { #expect(try await healthy.response(to: third).independentConcurrencyText == "held") }
        stuck.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.connection.close(graceSeconds: 0) }
    }

    /// Exactness of the saturated connection's own limit and of the server-wide one for the
    /// others, swept over several limits: `queueLimit` wait, the next is refused, on each side.
    @Test(arguments: [1, 2, 3, 7])
    func bothQueueLimitsAreExactForEveryLimit(queueLimit: Int) async throws {
        let holding = ICMeter()
        let gate = ICGate()
        let server = try makeServer(limit: 2, queueLimit: queueLimit, holding: holding, gate: gate)
        let stuck = StuckClient(server)
        await stuck.saturate(places: 2)
        // Saturated (the gate asked while slots were free): its own limit, exactly.
        for index in 0..<queueLimit { stuck.call("blob", id: "w\(index)") }
        #expect(stuck.queue.usage.queuedFrames == 1, "limit \(queueLimit): a waiting request of the saturated connection was refused")
        stuck.call("blob", id: "over")
        #expect(stuck.queue.usage.queuedFrames == 2, "limit \(queueLimit): the saturated connection's own limit let one more wait")
        // The others: exactly `queueLimit` wait for a slot.
        let wires = (0..<3).map { _ in ICWire(server) }
        wires[0].call("hold")
        wires[1].call("hold")
        #expect(await independentConcurrencyEventually { holding.total == 2 })
        for index in 0..<queueLimit { wires[index % 3].call("hold") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(wires.allSatisfy { $0.sink.history.isEmpty }, "limit \(queueLimit): a request within the server-wide limit was refused")
        let extra = wires[2].call("hold", id: "extra")
        let refusal = await wires[2].sink.next(timeout: .seconds(2))
        #expect(refusal?.json?["id"] == extra.json && refusal?.json?.independentConcurrencyErrorCode == -31001, "limit \(queueLimit): the server-wide queue took one more")
        gate.open()
        #expect(await independentConcurrencyEventually { holding.total == 2 + queueLimit })
        stuck.queue.close()
        _ = await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.connection.close(graceSeconds: 0) }
    }

    /// Cancelling requests of a long backlog: each cancellation should cost about the same,
    /// however long the backlog of that connection is, and it must not hold up the gate for the
    /// others in proportion to somebody else's backlog (P6's sibling: the gate's lock is shared).
    @Test func cancellingALongBacklogCostsAboutAsMuchAsCancellingManyShortOnes() async throws {
        func measure(connections: Int, total: Int) async throws -> Duration {
            let server = try makeServer(limit: 2, queueLimit: 100_000)
            var clients: [StuckClient] = []
            for _ in 0..<connections {
                let client = StuckClient(server)
                await client.saturate(places: 2)
                for index in 0..<(total / connections) { client.call("quick", id: "b\(index)") }
                clients.append(client)
            }
            let clock = ContinuousClock()
            let start = clock.now
            // The newest first: what a client does when it gives up on what it asked last.
            for client in clients {
                for index in stride(from: total / connections - 1, through: 0, by: -1) { client.cancel("b\(index)") }
            }
            let elapsed = clock.now - start
            for client in clients {
                client.queue.close()
                _ = await independentConcurrencyFinishes(within: .seconds(20)) { await client.connection.close(graceSeconds: 0) }
            }
            return elapsed
        }
        let spread = try await measure(connections: 20, total: 20_000)
        let single = try await measure(connections: 1, total: 20_000)
        #expect(
            single < spread * 10 + .seconds(1),
            "cancelling 20000 waiting requests took \(single) on one connection and \(spread) spread over twenty: each cancellation rebuilds the connection's whole queue under the gate's lock")
    }

    /// `gateForget` after `close()`: a connection that closes while saturated and with requests
    /// queued leaves nothing behind, and the next connections — some with its identity — start
    /// clean: exactly `limit` run and exactly `queueLimit` wait.
    @Test func closingWhileSaturatedAndQueuedLeavesTheGateExact() async throws {
        let holding = ICMeter()
        let gateBox = ICBox(ICGate())
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 2
            configuration.budgets.maxQueuedRequests = 3
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gateBox.value.wait()
            return .text("held")
        }
        var seen: Set<ObjectIdentifier> = []
        var reused = 0
        for round in 0..<60 {
            do {
                let stuck = StuckClient(server)
                seen.insert(ObjectIdentifier(stuck.connection))
                await stuck.saturate(places: 2)
                for index in 0..<3 { stuck.call("blob", id: "w\(index)") }
                if round % 3 == 1 { stuck.cancel("w0") }
                let grace = [0.0, -1.0, 0.001][round % 3]
                #expect(await independentConcurrencyFinishes(within: .seconds(10)) { await stuck.connection.close(graceSeconds: grace) })
                stuck.queue.close()
            }
            gateBox.set(ICGate())
            let probe = ICWire(server)
            if seen.contains(ObjectIdentifier(probe.connection)) { reused += 1 }
            let before = holding.total
            probe.call("hold")
            probe.call("hold")
            let ran = await independentConcurrencyEventually(timeout: .seconds(5)) { holding.total == before + 2 }
            #expect(ran, "round \(round): only \(holding.total - before) of 2 handlers run after a saturated connection closed")
            for _ in 0..<3 { probe.call("hold") }
            try await Task.sleep(for: .milliseconds(5))
            let early = probe.sink.history.count
            probe.call("hold", id: "extra")
            let refusal = await probe.sink.next(timeout: .seconds(2))
            #expect(early == 0 && refusal?.json?.independentConcurrencyErrorCode == -31001, "round \(round): the queue does not take exactly three")
            gateBox.value.open()
            #expect(await independentConcurrencyEventually { probe.sink.history.count == 6 })
            await probe.connection.close(graceSeconds: 0)
            if !ran { break }
        }
        _ = reused  // Identity reuse is likely but not guaranteed here; the drop test asserts it.
    }
}

// MARK: - `.serial` order with parked responses on several connections

@Suite(.timeLimit(.minutes(10)))
struct IndependentConcurrencySerialManyTests {
    /// Variations of P1 over two connections at once: both have a response waiting for room and
    /// a request waiting for a place; their peers read again in a random order and at a random
    /// moment, and a third request arrives on each right behind. Oracle: one handler at a time,
    /// each connection's requests in their arrival order, and every request runs.
    @Test(arguments: [UInt64(41), 42])
    func serialArrivalOrderPerConnectionWithTwoParkedResponses(seed: UInt64) async throws {
        let order = ICBox<[Int]>([])
        let active = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.execution = .serial
            configuration.budgets.maxQueuedRequests = 1000
        }
        try server.register(tool: ToolDefinition(name: "mark")) { arguments, _ in
            active.enter()
            defer { active.leave() }
            order.update { $0.append(arguments["n"]?.intValue ?? -1) }
            return .text("m")
        }
        let a = ICWire(server)
        let b = ICWire(server)
        var random = R4Random(seed: seed)
        var broken: [Int] = []
        let rounds = 12_000
        for round in 0..<rounds {
            let base = round * 10
            order.set([])
            a.sink.blockCapacity()
            b.sink.blockCapacity()
            a.call("mark", ["n": JSONValue(base + 0)])
            b.call("mark", ["n": JSONValue(base + 5)])
            guard await r4SpinUntil({ a.sink.capacityWaiterCount == 1 && b.sink.capacityWaiterCount == 1 }) else {
                Issue.record("round \(round): the first responses never waited for room")
                break
            }
            a.call("mark", ["n": JSONValue(base + 1)])
            b.call("mark", ["n": JSONValue(base + 6)])
            let aFirst = random.below(2) == 0
            let first = aFirst ? a : b
            let second = aFirst ? b : a
            let firstThird = base + (aFirst ? 2 : 7)
            let secondThird = base + (aFirst ? 7 : 2)
            first.sink.unblockCapacity()
            for _ in 0..<random.below(5) { await Task.yield() }
            first.call("mark", ["n": JSONValue(firstThird)])
            let early = random.below(2) == 0
            if early { second.call("mark", ["n": JSONValue(secondThird)]) }
            second.sink.unblockCapacity()
            for _ in 0..<random.below(3) { await Task.yield() }
            if !early { second.call("mark", ["n": JSONValue(secondThird)]) }
            guard await r4SpinUntil({ order.value.count == 6 }) else {
                Issue.record("round \(round): only \(order.value.count) of 6 handlers ran")
                break
            }
            let ran = order.value
            let ofA = ran.filter { $0 < base + 5 }.map { $0 - base }
            let ofB = ran.filter { $0 >= base + 5 }.map { $0 - base }
            if ofA != ofA.sorted() || ofB != ofB.sorted() || Set(ofA).count != ofA.count || Set(ofB).count != ofB.count {
                broken.append(round)
            }
            if active.peak > 1 { break }
        }
        #expect(active.peak == 1, "two handlers ran at once in serial mode")
        #expect(broken.isEmpty, "seed \(seed): a connection's requests ran out of arrival order in \(broken.count) of \(rounds) rounds, first round \(broken.first ?? -1)")
    }
}

// MARK: - Nothing lost, with connections dropped without `close()`

/// A client on a real `OutboundQueue`, read by a plain thread while `reading` is set. The test
/// can drop the connection the way a transport that gives up does: close the queue and forget.
private final class R4Client: @unchecked Sendable {
    let queue: OutboundQueue
    /// Touched only by the test's task.
    var connection: Connection?
    weak var weakConnection: Connection?
    private let lock = Mutex<(reading: Bool, responses: [String: Int], strays: Int)>((false, [:], 0))

    init(_ server: Server, budget: Int, reading: Bool) {
        queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: 1 << 20)
        let connection = server.connect(to: queue)
        self.connection = connection
        weakConnection = connection
        lock.withLock { $0.reading = reading }
    }

    var reading: Bool {
        get { lock.withLock { $0.reading } }
        set { lock.withLock { $0.reading = newValue } }
    }

    func call(_ tool: String, id: String) {
        connection?.receive(
            Array(#"{"jsonrpc":"2.0","id":"\#(id)","method":"tools/call","params":{"name":"\#(tool)","arguments":{},\#(modernMeta)}}"#.utf8))
    }

    func cancel(_ id: String) {
        connection?.receive(Array(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"\#(id)"}}"#.utf8))
    }

    func drainOnce() {
        guard reading else { return }
        let frames = queue.takeAvailable()
        guard !frames.isEmpty else { return }
        lock.withLock { state in
            for frame in frames {
                if let message = try? JSON.parse(frame), message["method"] == nil, let id = message["id"]?.stringValue {
                    state.responses[id, default: 0] += 1
                } else {
                    state.strays += 1
                }
            }
        }
        queue.didWrite(bytes: frames.reduce(0) { $0 + $1.count })
    }

    func responses(to id: String) -> Int { lock.withLock { $0.responses[id] ?? 0 } }
    var allResponses: [String: Int] { lock.withLock { $0.responses } }
    var strays: Int { lock.withLock { $0.strays } }
}

private final class R4Drainer: Sendable {
    private let clients = ICBox<[R4Client]>([])
    private let stop = ICBox(false)
    private let stopped = ICBox(false)

    init() {
        let clients = clients
        let stop = stop
        let stopped = stopped
        Thread.detachNewThread {
            while !stop.value {
                for client in clients.value { client.drainOnce() }
                usleep(150)
            }
            stopped.set(true)
        }
    }

    func add(_ client: R4Client) { clients.update { $0.append(client) } }

    func finish() async {
        stop.set(true)
        let stopped = stopped
        _ = await independentConcurrencyEventually { stopped.value }
    }
}

@Suite(.timeLimit(.minutes(10)))
struct IndependentConcurrencyNothingLostRound4Tests {
    /// Long random runs, concurrent and `.serial`: peers read, stop and resume; requests are
    /// cancelled while running, waiting and parked; the queue overflows; connections are closed
    /// with grace 0, tiny and negative, and dropped without `close()` and replaced by new ones
    /// (whose identities may be the dropped ones'). Oracle: the handler limit always holds; on a
    /// surviving connection every request that was not cancelled is answered exactly once; every
    /// dropped connection is released; and at the end exactly `limit` handlers can run on each
    /// connection and the queue takes exactly its limit.
    @Test(arguments: [(UInt64(51), false), (52, false), (53, true), (54, true)])
    func noPlaceOrSlotIsLostWhenConnectionsAreDroppedWithoutClose(seed: UInt64, serial: Bool) async throws {
        let limit = serial ? 1 : 3
        let queueLimit = 5
        let active = ICMeter()
        let holding = ICMeter()
        let holdGate = ICBox(ICGate())
        let stubbornGate = ICBox(ICGate())
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = limit
            configuration.budgets.maxQueuedRequests = queueLimit
            configuration.execution = serial ? .serial : .concurrent
        }
        try server.register(tool: ToolDefinition(name: "quick")) { _, _ in
            active.enter()
            defer { active.leave() }
            await Task.yield()
            return .text("q")
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in
            active.enter()
            defer { active.leave() }
            return .text(String(repeating: "b", count: 1500))
        }
        try server.register(tool: ToolDefinition(name: "nap")) { _, _ in
            active.enter()
            defer { active.leave() }
            try await Task.sleep(for: .milliseconds(3))
            return .text("n")
        }
        try server.register(tool: ToolDefinition(name: "stubborn")) { _, _ in
            active.enter()
            defer { active.leave() }
            await stubbornGate.value.wait()
            return .text("s")
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            active.enter()
            defer { active.leave() }
            holding.enter()
            await holdGate.value.wait()
            return .text("held")
        }
        var random = R4Random(seed: seed)
        let drainer = R4Drainer()
        struct Slot {
            var client: R4Client
            var posted = 0
            var outstanding: [String] = []
            var cancelled: Set<String> = []
        }
        func makeClient() -> R4Client {
            let client = R4Client(server, budget: 2000, reading: random.below(2) == 0)
            drainer.add(client)
            return client
        }
        var slots = (0..<5).map { _ in Slot(client: makeClient()) }
        var dropped: [R4Client] = []
        var closed: [R4Client] = []
        let context = "seed \(seed)\(serial ? " serial" : "")"
        for step in 0..<5000 {
            let index = random.below(slots.count)
            switch random.below(24) {
            case 0...8:
                let tool = ["quick", "quick", "blob", "blob", "blob", "nap", "stubborn"][random.below(7)]
                let id = "c\(index)-\(slots[index].posted)"
                slots[index].posted += 1
                slots[index].client.call(tool, id: id)
                slots[index].outstanding.append(id)
            case 9...13:
                if !slots[index].outstanding.isEmpty {
                    let id = slots[index].outstanding.remove(at: random.below(slots[index].outstanding.count))
                    slots[index].client.cancel(id)
                    slots[index].cancelled.insert(id)
                }
            case 14, 15: slots[index].client.reading.toggle()
            case 16:
                if step % 4 == 0 {
                    let old = slots[index].client
                    let grace = [0, 0.000_001, -1, 0.002][random.below(4)]
                    let connection = old.connection!
                    #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: grace) }, "\(context), step \(step)")
                    old.queue.close()
                    old.connection = nil
                    closed.append(old)
                    slots[index] = Slot(client: makeClient())
                }
            case 17:
                if step % 4 == 1 {
                    // The transport gives up without `close()`: it closes its queue and forgets.
                    let old = slots[index].client
                    old.queue.close()
                    old.connection = nil
                    dropped.append(old)
                    slots[index] = Slot(client: makeClient())
                }
            case 18:
                stubbornGate.value.open()
                stubbornGate.set(ICGate())
            default: await Task.yield()
            }
            #expect(active.current <= limit, "\(context): \(active.current) handlers run at once")
            if active.current > limit { break }
        }
        // Wind down: every peer reads, every stubborn handler may end.
        stubbornGate.value.open()
        for slot in slots { slot.client.reading = true }
        #expect(await independentConcurrencyEventually(timeout: .seconds(30)) { active.current == 0 }, "\(context): handlers still running")
        try await Task.sleep(for: .milliseconds(150))
        #expect(active.peak <= limit, "\(context): \(active.peak) handlers ran at once; the limit is \(limit)")
        // Nothing keeps a dropped or closed connection alive once its work is over.
        let gone = dropped + closed
        let released = await independentConcurrencyEventually(timeout: .seconds(10)) {
            gone.allSatisfy { $0.weakConnection == nil }
        }
        #expect(released, "\(context): \((dropped + closed).filter { $0.weakConnection != nil }.count) dropped or closed connections are still alive")
        // Every request on a surviving connection that was not cancelled has exactly one response.
        for (index, slot) in slots.enumerated() {
            let responses = slot.client.allResponses
            #expect(responses.values.allSatisfy { $0 == 1 }, "\(context): a request was answered twice")
            let missing = slot.outstanding.filter { responses[$0] == nil }
            #expect(missing.isEmpty, "\(context): connection \(index) never answered \(missing.prefix(5))")
            let late = slot.cancelled.filter { (responses[$0] ?? 0) > 1 }
            #expect(late.isEmpty)
            #expect(slot.client.strays == 0, "\(context): unexpected frames")
        }
        // Every surviving connection has all its places and the server all its slots.
        for (index, slot) in slots.enumerated() {
            holdGate.set(ICGate())
            let before = holding.total
            for number in 0..<limit { slot.client.call("hold", id: "probe-\(index)-\(number)") }
            let all = await independentConcurrencyEventually(timeout: .seconds(10)) { holding.total == before + limit }
            #expect(all, "\(context): connection \(index) runs only \(holding.total - before) of \(limit) handlers at once: a place or a slot was lost")
            holdGate.value.open()
            #expect(await independentConcurrencyEventually { active.current == 0 })
            #expect(await independentConcurrencyEventually(timeout: .seconds(10)) { (0..<limit).allSatisfy { slot.client.responses(to: "probe-\(index)-\($0)") == 1 } })
        }
        // A brand-new connection: exactly `limit` run, exactly `queueLimit` wait, one more is refused.
        holdGate.set(ICGate())
        let probe = ICWire(server)
        let before = holding.total
        for _ in 0..<limit { probe.call("hold") }
        #expect(await independentConcurrencyEventually { holding.total == before + limit }, "\(context)")
        for _ in 0..<queueLimit { probe.call("hold") }
        try await Task.sleep(for: .milliseconds(10))
        #expect(probe.sink.history.isEmpty, "\(context): the queue still holds requests of the storm")
        probe.call("hold", id: "extra")
        #expect((await probe.sink.next(timeout: .seconds(2)))?.json?.independentConcurrencyErrorCode == MCPError.Code.overloaded, "\(context): the queue has more room than its limit")
        holdGate.value.open()
        #expect(await independentConcurrencyEventually { active.current == 0 })
        await drainer.finish()
        for slot in slots {
            slot.client.queue.close()
            if let connection = slot.client.connection { await connection.close(graceSeconds: 0) }
        }
    }
}

// MARK: - Deferred events, more shapes

/// After accepting the acknowledgment, the sink reports capacity available while staying over budget.
private final class LyingSink: FrameSink {
    let waits = ICMeter()
    let frames = ICBox(0)
    let overBudget = ICBox(false)
    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        frames.update { $0 += 1 }
        return true
    }
    func waitForCapacity() async { waits.enter() }
    func discard(key: RequestID) {}
    var isOverBudget: Bool { overBudget.value }
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyDeferredMoreTests {
    /// "if a round delivers nothing the task sleeps 50 ms instead of spinning": a sink that
    /// reports room and then takes nothing.
    @Test func aSinkThatReportsRoomButTakesNothingDoesNotCauseABusyLoop() async throws {
        let server = independentConcurrencyServer()
        let sink = LyingSink()
        let connection = server.connect(to: sink)
        connection.receive(
            Array(#"{"jsonrpc":"2.0","id":"sub","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},\#(modernMeta)}}"#.utf8))
        sink.overBudget.set(true)
        try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("") }
        try await Task.sleep(for: .milliseconds(100))
        let before = sink.waits.total
        try await Task.sleep(for: .seconds(1))
        let rounds = sink.waits.total - before
        #expect(rounds <= 30, "\(rounds) rounds in one second for a sink that never takes anything")
        #expect(rounds >= 1, "the deferred event is never tried again")
        await connection.close(graceSeconds: 0)
        let waitsAtClose = sink.waits.total
        let framesAtClose = sink.frames.value
        try await Task.sleep(for: .milliseconds(320))
        // An iteration that passed its previous check can enter the capacity wait once.
        #expect(sink.waits.total <= waitsAtClose + 1, "still trying after close()")
        #expect(sink.frames.value == framesAtClose, "emitted a frame after close()")
    }

    /// A legacy session and a modern subscription on one connection both want the same events.
    /// While the peer does not read, events pile up as one entry each; some arrive while the
    /// flush is under way. Each session gets each event once, in the order of first arrival.
    @Test func legacyAndModernOnOneConnectionGetTheSameOrderDuringAFlush() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
        let uris = (0..<10).map { "ic://lm/\($0)" }
        for uri in uris { try server.register(resource: ResourceDefinition(uri: uri, name: uri)) { _, _ in [] } }
        for round in 0..<20 {
            let client = StuckClient(server, budget: 600)
            client.send(#"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
            client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            for (index, uri) in uris.enumerated() {
                client.send(#"{"jsonrpc":"2.0","id":"s\#(index)","method":"resources/subscribe","params":{"uri":"\#(uri)"}}"#)
                client.drain()
            }
            let list = uris.map { "\"\($0)\"" }.joined(separator: ",")
            client.send(
                #"{"jsonrpc":"2.0","id":"m","method":"subscriptions/listen","params":{"notifications":{"resourceSubscriptions":[\#(list)]},\#(modernMeta)}}"#)
            _ = await independentConcurrencyEventually { client.queue.usage.queuedFrames > 0 }
            client.drain()
            client.call("blob", id: "big")
            #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
            for uri in uris.prefix(5) { server.notifyResourceUpdated(uri: uri) }
            server.notifyResourceUpdated(uri: uris[1])
            var legacy: [String] = []
            var modern: [String] = []
            func collect() {
                for message in client.drain() where message["method"] == "notifications/resources/updated" {
                    guard let uri = message["params"]?["uri"]?.stringValue else { continue }
                    if message["params"]?["_meta"]?[MetaKey.subscriptionID] != nil { modern.append(uri) } else { legacy.append(uri) }
                }
            }
            collect()
            _ = await independentConcurrencyEventually(timeout: .seconds(2)) { client.queue.usage.queuedFrames > 0 }
            for uri in uris.suffix(5) { server.notifyResourceUpdated(uri: uri) }
            for _ in 0..<500 {
                collect()
                if legacy.count >= 10, modern.count >= 10 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            try await Task.sleep(for: .milliseconds(60))
            collect()
            #expect(legacy == uris, "round \(round): legacy got \(legacy)")
            #expect(modern == uris, "round \(round): modern got \(modern)")
            await client.connection.close(graceSeconds: 0)
            client.queue.close()
            if legacy != uris || modern != uris { break }
        }
    }

    /// An event deferred for a connection that is then dropped without `close()` (its queue
    /// closed): the delivering task ends and nothing keeps the connection alive.
    @Test func aDroppedConnectionWithDeferredEventsIsReleased() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
        weak var weakConnection: Connection?
        do {
            let client = StuckClient(server, budget: 1000)
            weakConnection = client.connection
            client.send(
                #"{"jsonrpc":"2.0","id":"sub","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["ic://x"]},\#(modernMeta)}}"#)
            client.call("blob", id: "big")
            #expect(await independentConcurrencyEventually { client.queue.isOverBudget })
            server.notifyResourceUpdated(uri: "ic://x")
            try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("") }
            client.queue.close()
        }
        let released = await independentConcurrencyEventually(timeout: .seconds(5)) { [weakConnection] in weakConnection == nil }
        _ = released
        #expect(weakConnection == nil, "a dropped connection with deferred events is kept alive")
        // Later events find no trace of it.
        server.notifyResourceUpdated(uri: "ic://x")
    }
}

// MARK: - The drain rule at its boundary

extension IndependentConcurrencyKilobyteRuleTests {
    /// Each read frees a writable amount of space, every two thirds of the drain limit.
    @Test func aPeerJustAboveAKilobytePerIntervalIsStillReading() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = Session(try makeServer(drain: 1.5, diagnostics: diagnostics))
        await prepare(session)
        var slowReads = 0
        while !session.returned.value, slowReads < 40 {
            if session.read(limit: Self.pipeProgressBytes, timeoutMilliseconds: 3000) < 0 { break }
            slowReads += 1
            try await Task.sleep(for: .seconds(1))
        }
        let gaveUp = diagnostics.value.filter { $0.contains("did not read") }
        #expect(gaveUp.isEmpty, "given up after \(slowReads) reads of \(Self.pipeProgressBytes) bytes per second with a limit of 1.5 seconds")
        #expect(session.returned.value)
        while session.read(limit: 65536, timeoutMilliseconds: 2000) > 0 {}
        #expect(session.received > Self.total)
        #expect(session.tail.last == 0x0A)
        session.closeAll()
    }

    /// Just below the rule: a kilobyte every 1.25 limits. The rule does not promise such a peer
    /// anything, but when it is given up, that happens no sooner than the limit after the last
    /// byte it took.
    @Test func aPeerJustBelowAKilobytePerIntervalIsNotGivenUpBeforeTheLimit() async throws {
        let diagnostics = ICBox<[String]>([])
        let session = Session(try makeServer(drain: 1.2, diagnostics: diagnostics))
        await prepare(session)
        let clock = ContinuousClock()
        var lastRead = clock.now
        var reads = 0
        while !session.returned.value, reads < 40 {
            let count = session.read(limit: 1024, timeoutMilliseconds: 100)
            if count < 0 { break }
            if count > 0 { lastRead = clock.now }
            reads += 1
            // Wait 1.5 s, but notice when `run` returns meanwhile.
            let deadline = clock.now + .milliseconds(1500)
            while clock.now < deadline, !session.returned.value { try await Task.sleep(for: .milliseconds(5)) }
        }
        let returnedAt = clock.now
        #expect(session.returned.value, "run did not return")
        if diagnostics.value.contains(where: { $0.contains("did not read") }) {
            #expect(returnedAt - lastRead >= .milliseconds(1000), "given up \(returnedAt - lastRead) after the peer's last read; the limit is 1.2 s")
        }
        session.closeAll()
    }
}

// MARK: - Gate throughput under a large backlog

@Suite(.timeLimit(.minutes(8)), .serialized)
struct IndependentConcurrencyGateThroughputTests {
    @Test func quickCallsNextToLargeBacklogs() async throws {
        func measure(stuckConnections: Int, each: Int) async throws -> Duration {
            let server = independentConcurrencyServer { configuration in
                configuration.budgets.maxConcurrentHandlers = 4
                configuration.budgets.maxQueuedRequests = 100_000
            }
            try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 3000)) }
            try server.register(tool: ToolDefinition(name: "quick")) { _, _ in .text("q") }
            var stuck: [StuckClient] = []
            for _ in 0..<stuckConnections {
                let client = StuckClient(server)
                client.call("blob", id: "s")
                _ = await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 }
                for index in 0..<(each + 4) { client.call("blob", id: "s\(index)") }
                stuck.append(client)
            }
            try await Task.sleep(for: .milliseconds(100))
            let healthy = ICWire(server)
            let calls = 3000
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<calls { healthy.call("quick") }
            #expect(await independentConcurrencyEventually(timeout: .seconds(120)) { healthy.sink.history.count == calls })
            let elapsed = clock.now - start
            for client in stuck {
                client.queue.close()
                _ = await independentConcurrencyFinishes(within: .seconds(20)) { await client.connection.close(graceSeconds: 0) }
            }
            return elapsed
        }
        let alone = try await measure(stuckConnections: 0, each: 0)
        let oneLong = try await measure(stuckConnections: 1, each: 20_000)
        let manyShort = try await measure(stuckConnections: 1000, each: 5)
        #expect(oneLong < alone * 20 + .seconds(1), "P6: \(oneLong) next to one backlog of 20000, \(alone) alone")
        #expect(manyShort < alone * 20 + .seconds(1), "\(manyShort) next to 1000 stuck connections, \(alone) alone")
    }
}
