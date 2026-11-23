#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Limb
import Synchronization
import Testing


private typealias Client = IndependentStdioClient

/// Fills the server's output until its writer is stuck in `write`: the client reads nothing.
private func blockTheWriter(_ client: Client, _ fixture: IndependentStdioFixture, firstID: Int = 9000, count: Int = 6) -> Bool {
    for offset in 0..<count {
        guard client.send(Client.callLine(firstID + offset, "blob", #"{"size":300000,"seed":\#(firstID + offset)}"#), absorb: false) else { return false }
    }
    let produced = fixture.probe.eventually(seconds: 20) { probe in
        probe.finishedTags.filter { $0.hasPrefix("blob-9") }.count >= count
    }
    usleep(100_000)
    return produced
}

extension IndependentStdioTransportTests {
    @Suite struct Backpressure {
        // MARK: A slow reader

        @Test(arguments: [false, true], [false, true])
        func framesArriveWholeHoweverSlowlyTheClientReads(socket: Bool, nonBlocking: Bool) throws {
            let fixture = try independentStdioFixture { $0.budgets.maxQueuedRequests = 1024 }
            let client = Client(fixture.server, channel: socket ? .socketpair : .pipes)
            defer { client.tearDown() }
            if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
            client.start()
            #expect(client.initialize() == "2025-11-25")
            var random = IndependentStdioRandom(socket ? 11 : 12)
            let total = 150
            var sizes: [Int: Int] = [:]
            var script = ""
            for id in 1...total {
                // From far below one write to several times the channel's capacity, on both
                // sides of the writer's 32 KiB switch between copied and direct writes.
                let size = [0, 1, 100, 5000, 32_000, 33_000, 70_000, 150_000, 400_000][random.below(9)] + random.below(700)
                sizes[id] = size
                script += Client.callLine(id, "blob", #"{"size":\#(size),"seed":\#(id),"delayMs":\#(random.below(4))}"#)
            }
            #expect(client.send(script, absorb: false))
            // Let responses pile up against a full channel before reading anything.
            usleep(300_000)
            var answers: [Int: [String: Any]] = [:]
            var extra = 0
            let deadline = Date().addingTimeInterval(120)
            while answers.count < total, Date() < deadline {
                // Small reads of varying size, with pauses.
                guard let message = client.readMessage(timeout: 30, chunk: 1 + random.below(6000)) else { break }
                if random.chance(5) { usleep(useconds_t(random.below(3000))) }
                if let id = Client.id(of: message), answers[id] == nil { answers[id] = message } else { extra += 1 }
            }
            #expect(answers.count == total)
            #expect(extra == 0, "\(extra) frames that are not a first answer to a request")
            var damaged: [Int] = []
            for (id, answer) in answers where Client.text(of: answer) != independentStdioBlob(size: sizes[id] ?? -1, seed: id) {
                damaged.append(id)
            }
            #expect(damaged == [], "responses that did not arrive intact: \(damaged.sorted())")
            #expect(client.violations == [])
            client.closeInput()
            #expect(client.stopped(within: 10))
        }

        @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair])
        func multiMegabyteResponsesArriveIntact(channel: IndependentStdioClient.Channel) throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server, channel: channel)
            defer { client.tearDown() }
            // The largest is just under the 16 MiB response budget.
            let sizes = [1 << 20, 3 << 20, (8 << 20) + 12_345, (16 << 20) - 4096, 2 << 20, 64 * 1024]
            for (id, size) in sizes.enumerated() {
                #expect(client.call(id + 1, "blob", #"{"size":\#(size),"seed":\#(id + 1)}"#))
            }
            // Small requests answered while the big ones are in the pipeline.
            for id in 100..<140 { #expect(client.call(id, "echo", #"{"text":"small \#(id)"}"#)) }
            let answers = client.responses(to: Set(1...sizes.count).union(100..<140), timeout: 180)
            #expect(answers.count == sizes.count + 40)
            for (index, size) in sizes.enumerated() {
                let text = Client.text(of: answers[index + 1]) ?? ""
                #expect(text.utf8.count == size, "response \(index + 1): \(text.utf8.count) bytes of \(size)")
                #expect(independentStdioDigest(text) == independentStdioDigest(independentStdioBlob(size: size, seed: index + 1)), "response \(index + 1)")
            }
            for id in 100..<140 { #expect(Client.text(of: answers[id]) == "small \(id)") }
            #expect(client.violations == [])
            client.closeInput()
            #expect(client.stopped(within: 10))
        }

        // MARK: A client that does not read

        @Test func whileTheClientDoesNotReadRequestsAreStillReadAndCancellationsGetThrough() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(blockTheWriter(client, fixture))

            // The reader still takes requests …
            #expect(client.send(Client.callLine(1, "hold", #"{"tag":"h1"}"#) + Client.callLine(2, "hold", #"{"tag":"h2"}"#), absorb: false))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.contains("h1") && $0.startedTags.contains("h2") })
            // … and cancellations.
            #expect(client.send(Client.cancelLine(1), absorb: false))
            #expect(fixture.probe.eventually(seconds: 10) { $0.cancelledTags == ["h1"] }, "the cancellation was not delivered while the writer was blocked")
            // Cheap requests are answered from the reader; they must not block it either.
            var pings = ""
            for id in 100..<600 { pings += Client.requestLine(id, "ping") }
            #expect(client.send(pings, timeout: 10, absorb: false), "the reader stopped taking input")
            #expect(client.send(Client.callLine(3, "nap", #"{"ms":1,"tag":"n3"}"#), absorb: false))
            #expect(fixture.probe.eventually(seconds: 10) { $0.finishedTags.contains("n3") })
            #expect(!client.hasReturned)

            // The client reads again.
            fixture.probe.release()
            let expected = Set(9000..<9006).union(100..<600).union([2, 3])
            var others: [[String: Any]] = []
            let answers = client.responses(to: expected, timeout: 60) { others.append($0) }
            #expect(answers.count == expected.count, "missing: \(expected.subtracting(answers.keys).sorted().prefix(20))")
            for id in 9000..<9006 {
                #expect(Client.text(of: answers[id]) == independentStdioBlob(size: 300_000, seed: id), "blob \(id)")
            }
            #expect(Client.text(of: answers[2]) == "released h2")
            client.closeInput()
            #expect(client.stopped(within: 10))
            others += client.drain(seconds: 0.2)
            // Specification, stdio "Cancellation": servers "MUST NOT send any further messages for it".
            #expect(!others.contains { Client.id(of: $0) == 1 }, "the cancelled request was answered")
            #expect(others.isEmpty, "\(others.count) unexpected messages")
            #expect(client.violations == [])
        }

        #if canImport(Darwin)
        /// Waiting for the client must be a blocking wait on every kind of output, including
        /// one that somebody else made non-blocking (`write` then fails with EAGAIN instead of
        /// blocking, and retrying it in a loop would burn a core for as long as the client is slow).
        @Test(arguments: [false, true], [false, true])
        func aBlockedWriterUsesNoCPU(socket: Bool, nonBlocking: Bool) throws {
            let fixture = try independentStdioFixture()
            let before = Set(independentStdioTransportThreads().map(\.id))
            let client = Client(fixture.server, channel: socket ? .socketpair : .pipes)
            defer { client.tearDown() }
            if nonBlocking { independentStdioSetNonBlocking(client.serverOutput) }
            client.start()
            #expect(client.initialize() == "2025-11-25")
            let ids = Set(independentStdioSessionThreads(startedAfter: before).map(\.id))
            #expect(ids.count == 2)
            #expect(blockTheWriter(client, fixture))
            let start = independentStdioCPUSeconds(of: ids)
            usleep(700_000)
            let cpu = independentStdioCPUSeconds(of: ids) - start
            #expect(cpu < 0.07, "the transport threads used \(cpu) s of CPU in 0.7 s of waiting for the client to read")
            let answers = client.responses(to: Set(9000..<9006), timeout: 60)
            #expect(answers.count == 6)
            client.closeInput()
            #expect(client.stopped(within: 10))
        }
        #endif

        @Test func handlersFeelBackpressureWhileTheClientDoesNotRead() throws {
            let fixture = try independentStdioFixture {
                $0.budgets.maxOutboundBytes = 256 * 1024
                $0.budgets.maxConcurrentHandlers = 4
                $0.budgets.maxQueuedRequests = 500
            }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let total = 120
            var script = ""
            for id in 1...total { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id)}"#) }
            #expect(client.send(script, absorb: false))
            usleep(1_500_000)
            let produced = fixture.probe.startedTags.count
            // 256 KiB of budget is three responses, the pipe holds less than one, four more wait
            // in their handler slots. Without backpressure all 120 (12 MB) would be in memory.
            #expect(produced >= 4)
            #expect(produced <= 24, "\(produced) of \(total) responses were produced with nobody reading and a 256 KiB budget")
            #expect(!client.hasReturned)
            // Reading releases the pressure and everything arrives.
            let answers = client.responses(to: Set(1...total), timeout: 120, chunk: 16384)
            #expect(answers.count == total)
            let damaged = answers.filter { Client.text(of: $0.value) != independentStdioBlob(size: 100_000, seed: $0.key) }.keys.sorted()
            #expect(damaged == [])
            #expect(fixture.log.all == [])
            #expect(client.violations == [])
        }

        @Test func aClientThatDoesNotReadDoesNotStallOtherSessionsOfTheServer() throws {
            let fixture = try independentStdioFixture {
                $0.budgets.maxConcurrentHandlers = 4
                $0.budgets.maxOutboundBytes = 64 * 1024
                $0.budgets.maxQueuedRequests = 500
                $0.outputDrainSeconds = 0.5
                $0.shutdownGraceSeconds = 0.5
            }
            let slow = Client.ready(fixture.server)
            let other = Client.ready(fixture.server, channel: .socketpair)
            defer {
                slow.tearDown()
                other.tearDown()
            }
            // Cheap requests are answered by the reader and need no slot: the other session is alive.
            #expect(other.request(1, "ping"))
            #expect(Client.id(of: other.readMessage()) == 1)
            var script = ""
            for id in 1...40 { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id)}"#) }
            #expect(slow.send(script, absorb: false))
            usleep(1_000_000)
            // The other client reads everything it is sent; its request needs one handler slot.
            #expect(other.call(2, "echo", #"{"text":"am I served?"}"#))
            let answer = other.responses(to: [2], timeout: 5)[2]
            #expect(Client.text(of: answer) == "am I served?", "a reading client got no answer in 5 s while another client of the same server was not reading")
            // Once the slow client reads, everybody is served.
            #expect(slow.responses(to: Set(1...40), timeout: 60).count == 40)
            if answer == nil { #expect(Client.text(of: other.responses(to: [2], timeout: 20)[2]) == "am I served?") }
        }

        @Test func queuedFramesOfACancelledRequestAreWithdrawn() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(blockTheWriter(client, fixture))
            // Both requests queue log notifications behind the blocked writer.
            #expect(client.send(Client.callLine(1, "chatty", #"{"tag":"doomed","count":50,"size":10}"#), absorb: false))
            #expect(client.send(Client.callLine(2, "chatty", #"{"tag":"kept","count":50,"size":10}"#), absorb: false))
            #expect(fixture.probe.eventually(seconds: 10) { $0.finishedTags.contains("logged-doomed") && $0.finishedTags.contains("logged-kept") })
            #expect(client.send(Client.cancelLine(1), absorb: false))
            #expect(fixture.probe.eventually(seconds: 10) { $0.cancelledTags == ["doomed"] })
            #expect(client.send(Client.requestLine(3, "ping"), absorb: false))
            fixture.probe.release()

            var logs: [String] = []
            var others: [[String: Any]] = []
            let answers = client.responses(to: Set(9000..<9006).union([2, 3]), timeout: 60) { message in
                if message["method"] as? String == "notifications/message", let data = (message["params"] as? [String: Any])?["data"] as? String {
                    logs.append(data)
                } else {
                    others.append(message)
                }
            }
            #expect(answers.count == 8)
            #expect(logs.count { $0.hasPrefix("chatty-kept-") } == 50, "the other request's notifications must not be touched")
            #expect(logs.count { $0.hasPrefix("chatty-doomed-") } == 0, "notifications of the cancelled request were still sent")
            #expect(others.isEmpty)
            #expect(client.violations == [])
        }

        @Test func whenTheUrgentReserveIsExhaustedTheServerStopsReadingAndLogsIt() throws {
            let fixture = try independentStdioFixture { $0.budgets.maxOutboundBytes = 64 * 1024 }
            let client = Client.started(fixture.server)
            defer { client.tearDown() }
            // Each line is answered with a parse error of roughly 100 bytes; the reserve is 1 MiB.
            let garbage = String(repeating: "x\n", count: 50_000)
            _ = client.send(garbage, timeout: 20, absorb: false)
            #expect(fixture.probe.eventually(seconds: 20) { _ in !fixture.log.all.isEmpty }, "nothing was logged")
            #expect(fixture.log.all.count == 1, "\(fixture.log.all)")
            // The server no longer reads: its input fills up and stays full.
            let more = String(repeating: "y\n", count: 200_000)
            #expect(!client.send(more, timeout: 1.5, absorb: false), "the server still takes input after the reserve was exhausted")
            // What was queued is still a clean stream of messages.
            let queued = client.drain(seconds: 2)
            #expect(queued.count > 1000)
            #expect(queued.allSatisfy { Client.errorCode(of: $0) == -32700 })
            #expect(client.violations == [])
        }

        @Test func whenTheUrgentReserveIsExhaustedRunReturns() throws {
            let fixture = try independentStdioFixture {
                $0.budgets.maxOutboundBytes = 64 * 1024
                $0.outputDrainSeconds = 1
            }
            let client = Client.started(fixture.server)
            defer { client.tearDown() }
            _ = client.send(String(repeating: "x\n", count: 50_000), timeout: 20, absorb: false)
            #expect(fixture.probe.eventually(seconds: 20) { _ in !fixture.log.all.isEmpty }, "nothing was logged")
            #expect(client.stopped(within: 15), "15 s after the connection was declared closed, run had not returned")
        }

        @Test func logNotificationsDoNotGrowTheQueueBeyondItsBudget() async throws {
            let fixture = try independentStdioFixture()
            // The transport's own queue, with nobody taking frames out: a client that does not read.
            let queue = OutboundQueue(budgetBytes: 64 * 1024)
            let connection = fixture.server.connect(to: queue)
            connection.receive(Array(Client.requestLine(0, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"q","version":"1"}}"#).utf8.dropLast()))
            connection.receive(Array(Client.callLine(1, "chatty", #"{"tag":"flood","count":20000,"size":1000}"#).utf8.dropLast()))
            #expect(fixture.probe.eventually(seconds: 60) { $0.finishedTags.contains("logged-flood") })
            let usage = queue.usage
            // One frame may take the queue over its budget; nothing is queued after that.
            #expect(usage.ordinaryBytes <= queue.budgetBytes + 2000, "\(usage.ordinaryBytes) bytes queued; the budget is \(queue.budgetBytes) bytes")
            // And logging is not switched off altogether: what fits the budget is kept.
            #expect(usage.ordinaryBytes >= queue.budgetBytes / 2, "only \(usage.ordinaryBytes) bytes of log messages were kept")
            #expect(queue.takeAvailable().reduce(0) { $0 + $1.count } == usage.ordinaryBytes + usage.urgentBytes)
            fixture.probe.release()
            queue.close()
            await connection.close(graceSeconds: 5)
        }

        /// The rule: while ordinary output is over budget, "registry events (list changes,
        /// resource updates) are remembered once each and delivered when there is room"
        /// (`Connection.deliver`: "nothing is lost, and memory holds at most one of each").
        /// Thirty tool registrations while the client does not read become one
        /// `notifications/tools/list_changed` once it reads, and every response still arrives.
        @Test func listChangesWhileTheClientDoesNotReadArriveOnceWhenThereIsRoom() throws {
            let fixture = try independentStdioFixture {
                $0.budgets.maxOutboundBytes = 64 * 1024
                $0.budgets.maxQueuedRequests = 200
            }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let anyObject: JSONObject = ["type": "object"]
            func listChanges(_ messages: [[String: Any]]) -> Int {
                messages.filter { $0["method"] as? String == "notifications/tools/list_changed" }.count
            }
            // Legacy sessions get these notifications once `notifications/initialized` has been
            // handled; a ping answered means it has (frames are handled in order).
            #expect(client.request(899, "ping"))
            #expect(client.responses(to: [899], timeout: 10).count == 1)
            // With room, a change is announced at once.
            try fixture.server.register(tool: ToolDefinition(name: "extra-0", inputSchema: anyObject)) { _, _ in .text("") }
            var others: [[String: Any]] = []
            #expect(client.request(900, "ping"))
            #expect(client.responses(to: [900], timeout: 10) { others.append($0) }.count == 1)
            #expect(listChanges(others) == 1, "a change with room to spare was not announced once: \(others)")
            // Nobody reads: the queue goes over its budget.
            var script = ""
            for id in 1...10 { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id)}"#) }
            #expect(client.send(script, absorb: false))
            #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count >= 2 })
            usleep(200_000)
            for index in 1...30 {
                try fixture.server.register(tool: ToolDefinition(name: "extra-\(index)", inputSchema: anyObject)) { _, _ in .text("") }
            }
            others = []
            let answers = client.responses(to: Set(1...10), timeout: 60) { others.append($0) }
            #expect(answers.count == 10)
            // The deferred event goes out once there is room, which may be after the last answer.
            #expect(client.request(901, "ping"))
            _ = client.responses(to: [901], timeout: 10) { others.append($0) }
            others += client.drain(seconds: 0.3)
            #expect(listChanges(others) == 1, "\(listChanges(others)) list changes announced for 30 registrations while the client did not read")
            #expect(client.violations == [])
        }

        // MARK: Signals

        #if canImport(Darwin)
        @Test func signalsDeliveredToTheTransportThreadsDoNotDisturbTheSession() throws {
            independentStdioCountSIGUSR1()
            let handledBefore = independentStdioHandledSignals.load(ordering: .relaxed)

            let fixture = try independentStdioFixture()
            let before = Set(independentStdioTransportThreads().map(\.id))
            let client = Client(fixture.server).start(signals: true)
            defer { client.tearDown() }
            #expect(client.initialize() == "2025-11-25")
            let ids = Set(independentStdioSessionThreads(startedAfter: before).map(\.id))
            #expect(ids.count == 2)

            let stop = Mutex(false)
            let delivered = Mutex(0)
            let signaller = Thread {
                while !stop.withLock({ $0 }) {
                    let reached = independentStdioSignalThreads(ids: ids, signal: SIGUSR1)
                    delivered.withLock { $0 += reached }
                    usleep(300)
                }
            }
            signaller.start()
            defer { stop.withLock { $0 = true } }

            // Idle under signals: the reader's poll is interrupted again and again.
            usleep(100_000)
            #expect(!client.hasReturned, "a signal ended the session")
            // Large responses with a slow client: the writer is interrupted inside write.
            let total = 40
            var script = ""
            for id in 1...total { script += Client.callLine(id, "blob", #"{"size":250000,"seed":\#(id)}"#) }
            // And a large request: the reader is interrupted between reads.
            script += Client.callLine(500, "length", #"{"text":"\#(String(repeating: "r", count: 2_000_000))"}"#)
            #expect(client.send(script))
            var random = IndependentStdioRandom(5)
            var answers: [Int: [String: Any]] = [:]
            let deadline = Date().addingTimeInterval(120)
            while answers.count < total + 1, Date() < deadline {
                guard let message = client.readMessage(timeout: 30, chunk: 2000 + random.below(20_000)) else { break }
                if let id = Client.id(of: message) { answers[id] = message }
            }
            #expect(answers.count == total + 1)
            let damaged = (1...total).filter { Client.text(of: answers[$0]) != independentStdioBlob(size: 250_000, seed: $0) }
            #expect(damaged == [])
            #expect(Client.text(of: answers[500]) == "2000000")
            #expect(!client.hasReturned)
            #expect(delivered.withLock { $0 } > 200, "only \(delivered.withLock { $0 }) signals were sent to the transport threads")
            // Sent is not handled: count what the handler itself saw.
            let handled = independentStdioHandledSignals.load(ordering: .relaxed) - handledBefore
            #expect(handled > 100, "only \(handled) signals were handled on the transport threads")
            stop.withLock { $0 = true }
            usleep(5000)
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(fixture.log.all == [], "\(fixture.log.all)")
            #expect(client.violations == [])
        }
        #endif
    }
}
