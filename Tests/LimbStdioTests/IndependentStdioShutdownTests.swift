import Foundation
import Limb
import Testing


private typealias Client = IndependentStdioClient

/// Fills the server's output until its writer is stuck in `write`: the client reads nothing.
/// Returns once every one of the responses has been produced by its handler.
private func blockTheWriter(_ client: Client, _ fixture: IndependentStdioFixture, firstID: Int = 9000, count: Int = 6) -> Bool {
    for offset in 0..<count {
        guard client.send(Client.callLine(firstID + offset, "blob", #"{"size":300000,"seed":\#(firstID + offset)}"#), absorb: false) else { return false }
    }
    let produced = fixture.probe.eventually(seconds: 20) { probe in
        probe.finishedTags.filter { $0.hasPrefix("blob-9") }.count >= count
    }
    // Time for the writer to take the frames and fill the channel.
    usleep(100_000)
    return produced
}

extension IndependentStdioTransportTests {
    @Suite struct Shutdown {
        // MARK: End of input

        @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair])
        func anIdleSessionUsesNoCPUAndEndsPromptlyAtEndOfInput(channel: IndependentStdioClient.Channel) throws {
            let fixture = try independentStdioFixture()
            let before = Set(independentStdioTransportThreads().map(\.id))
            let client = Client.ready(fixture.server, channel: channel)
            defer { client.tearDown() }
            let threads = independentStdioSessionThreads(startedAfter: before)
            #expect(threads.map(\.name).sorted() == ["limb-stdio-reader", "limb-stdio-writer"])
            let ids = Set(threads.map(\.id))

            // The measurement itself must see work when there is some.
            let atStart = independentStdioCPUSeconds(of: ids)
            var burst = ""
            for id in 1...3000 { burst += Client.requestLine(id, "ping") }
            #expect(client.send(burst))
            #expect(client.responses(to: Set(1...3000), timeout: 30).count == 3000)
            #expect(independentStdioCPUSeconds(of: ids) > atStart, "the CPU probe saw no work in 3000 requests")

            // Idle: waiting for input must be a blocking wait, not a polling loop.
            let idleStart = independentStdioCPUSeconds(of: ids)
            usleep(500_000)
            let idleCPU = independentStdioCPUSeconds(of: ids) - idleStart
            #expect(idleCPU < 0.05, "the transport threads used \(idleCPU) s of CPU in 0.5 s of idling")

            let closedAt = Date()
            client.closeInput()
            #expect(client.stopped(within: 10))
            let took = Date().timeIntervalSince(closedAt)
            #expect(took < 2, "run returned \(took) s after end of input")
            // Both threads are gone, not parked.
            let gone = fixture.probe.eventually(seconds: 5) { _ in
                independentStdioTransportThreads().allSatisfy { !ids.contains($0.id) }
            }
            #expect(gone, "transport threads outlived run()")
            #expect(fixture.log.all == [])
        }

        @Test func nothingSpinsWhileRequestsInFlightUseTheGracePeriod() throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 1.5 }
            let before = Set(independentStdioTransportThreads().map(\.id))
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let ids = Set(independentStdioSessionThreads(startedAfter: before).map(\.id))
            #expect(ids.count == 2)
            #expect(client.call(1, "hold", #"{"tag":"slow"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.contains("slow") })

            let start = independentStdioCPUSeconds(of: ids)
            let closedAt = Date()
            client.closeInput()
            usleep(1_000_000)
            #expect(!client.hasReturned, "the grace period of 1.5 s was cut short")
            let cpu = independentStdioCPUSeconds(of: ids) - start
            #expect(cpu < 0.05, "the transport threads used \(cpu) s of CPU during 1 s of waiting after end of input")

            // "what is still running after that is cancelled"
            #expect(client.stopped(within: 15))
            let took = Date().timeIntervalSince(closedAt)
            #expect(took >= 1.4 && took < 10, "run returned \(took) s after end of input; the grace period is 1.5 s")
            #expect(fixture.probe.cancelledTags == ["slow"])
        }

        @Test func requestsRunningAndQueuedAtEndOfInputAreAnswered() throws {
            let fixture = try independentStdioFixture { $0.budgets.maxConcurrentHandlers = 2 }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var script = ""
            for id in 1...12 { script += Client.callLine(id, "nap", #"{"ms":100,"tag":"n\#(id)"}"#) }
            #expect(client.send(script))
            client.closeInput()
            let answers = client.responses(to: Set(1...12), timeout: 20)
            #expect(answers.count == 12, "answered: \(answers.keys.sorted())")
            for (id, answer) in answers { #expect(Client.text(of: answer) == "woke n\(id)") }
            #expect(client.stopped(within: 10))
            #expect(client.violations == [])
        }

        /// "writes what is queued and returns": when `run` is back, a process may exit, so
        /// every answer must already be in the channel.
        @Test func everyAnswerIsWrittenBeforeRunReturns() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var script = ""
            for id in 1...60 { script += Client.callLine(id, "nap", #"{"ms":\#(id % 7 * 10),"tag":"w\#(id)"}"#) }
            #expect(client.send(script))
            client.closeInput()
            // Nothing is read until run has returned (60 short answers fit in the channel).
            #expect(client.stopped(within: 20))
            let messages = client.drain(seconds: 0.3)
            #expect(Set(messages.compactMap { Client.id(of: $0) }) == Set(1...60))
            #expect(messages.count == 60)
            #expect(client.violations == [])
        }

        /// End of input with large answers still to come and a client that reads them slowly
        /// (but does read): nothing is cut off.
        @Test func aSlowReaderStillGetsEverythingAfterEndOfInput() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var script = ""
            for id in 1...20 { script += Client.callLine(id, "blob", #"{"size":300000,"seed":\#(id),"delayMs":\#(id * 5)}"#) }
            #expect(client.send(script, absorb: false))
            client.closeInput()
            let answers = client.responses(to: Set(1...20), timeout: 60, chunk: 8192)
            #expect(answers.count == 20)
            let damaged = answers.filter { Client.text(of: $0.value) != independentStdioBlob(size: 300_000, seed: $0.key) }.keys.sorted()
            #expect(damaged == [])
            #expect(client.stopped(within: 10))
            #expect(client.violations == [])
        }

        @Test func endOfInputWhileTheClientIsNotReadingEndsByTheWriteDeadline() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(blockTheWriter(client, fixture))
            let closedAt = Date()
            client.closeInput()
            let stopped = client.stopped(within: 15)
            let took = Date().timeIntervalSince(closedAt)
            #expect(stopped, "run had not returned \(took) s after end of input; the client was not reading")
            // Not before the deadline either: until then the client may still start reading.
            #expect(took >= 4.5, "run gave up on the output after \(took) s; the deadline is 5 s")
            #expect(fixture.log.all.count == 1, "giving up on unread output is logged once: \(fixture.log.all)")
        }

        // MARK: Cancelling the task

        @Test func cancellingTheTaskStopsAnIdleSession() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            client.cancelRun()
            #expect(client.stopped(within: 5))
            // The input was never closed, and is still usable by its owner.
            #expect(IndependentStdioDescriptorState(client.serverInput) != nil)
            #expect(fixture.log.all == [])
        }

        @Test func cancellingATaskThatHasBarelyStartedStopsTheSession() throws {
            let fixture = try independentStdioFixture()
            for _ in 0..<50 {
                let client = Client(fixture.server)
                client.start()
                client.cancelRun()
                let stopped = client.stopped(within: 5)
                #expect(stopped)
                client.tearDown()
                if !stopped { break }
            }
        }

        /// "Cancelling the calling task stops it the same way": requests in flight still finish
        /// within the grace period and are answered.
        @Test func cancellingTheTaskLetsRequestsInFlightFinish() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(client.call(1, "nap", #"{"ms":300,"tag":"busy"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.contains("busy") })
            client.cancelRun()
            #expect(Client.text(of: client.responses(to: [1], timeout: 10)[1]) == "woke busy")
            #expect(client.stopped(within: 10))
            #expect(fixture.probe.cancelledTags == [])
        }

        @Test func cancellingTheTaskUnderLoadStopsTheSession() throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 1 }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var script = ""
            for id in 1...300 { script += Client.callLine(id, "blob", #"{"size":20000,"seed":\#(id),"delayMs":\#(id % 5)}"#) }
            #expect(client.send(script))
            _ = client.readMessage()
            client.cancelRun()
            // Keep reading so the writer is never the reason for a delay.
            let deadline = Date().addingTimeInterval(20)
            while !client.hasReturned, Date() < deadline { _ = client.readLine(timeout: 0.05) }
            #expect(client.hasReturned)
            _ = client.drain(seconds: 0.2)
            // Whatever was answered is intact.
            #expect(client.violations == [])
        }

        @Test func cancellingTheTaskWhileTheClientIsNotReadingEndsByTheWriteDeadline() throws {
            let fixture = try independentStdioFixture { $0.outputDrainSeconds = 1 }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(blockTheWriter(client, fixture))
            client.cancelRun()
            #expect(client.stopped(within: 15), "run had not returned 15 s after its task was cancelled; the client was not reading")
        }

        // MARK: The client goes away

        @Test func aClientThatClosedItsEndStopsTheServerCleanly() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            client.closeOutput()
            // Nothing has been written since, so the server cannot know yet.
            usleep(50_000)
            #expect(!client.hasReturned)
            var script = ""
            for id in 1...30 { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id)}"#) }
            #expect(client.send(script))
            // The input is still open: the server stops because writing failed.
            #expect(client.stopped(within: 10))
            #expect(IndependentStdioDescriptorState(client.serverInput) != nil)
        }

        @Test func aClientThatClosedItsEndIsNotReportedAsAClientThatDoesNotRead() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            client.closeOutput()
            var script = ""
            for id in 1...30 { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id)}"#) }
            for id in 100...3000 { script += Client.requestLine(id, "ping") }
            // The server may stop reading before all of it is taken.
            _ = client.send(script, timeout: 5)
            #expect(client.stopped(within: 10))
            #expect(fixture.log.all == [])
        }

        /// A client that first stopped reading and then went away: the writer, stuck in
        /// `write`, must notice.
        @Test func aClientThatStoppedReadingAndThenClosedItsEndStopsTheServer() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(blockTheWriter(client, fixture))
            #expect(!client.hasReturned)
            client.closeOutput()
            #expect(client.stopped(within: 10))
        }

        /// The same over one socket, as Node wires a child: the client closes the socket while
        /// requests are in the pipeline, so the server sees end of input and then EPIPE.
        @Test func aClientThatClosedItsSocketStopsTheServerCleanly() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server, channel: .socketpair)
            defer { client.tearDown() }
            var script = ""
            for id in 1...30 { script += Client.callLine(id, "blob", #"{"size":100000,"seed":\#(id),"delayMs":50}"#) }
            #expect(client.send(script, absorb: false))
            client.closeOutput()
            #expect(client.stopped(within: 10))
            #expect(IndependentStdioDescriptorState(client.serverInput) != nil)
        }

        @Test func sigpipeIsIgnoredAfterASessionAsTheDesignSays() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            client.closeInput()
            #expect(client.stopped(within: 10))
            client.tearDown()
            var current = sigaction()
            #expect(sigaction(SIGPIPE, nil, &current) == 0)
            // SIG_IGN is the handler value 1.
            #expect(unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == 1, "SIGPIPE is not ignored")
        }

        @Test func requestsInFlightAreCancelledWhenTheClientIsGone() throws {
            let fixture = try independentStdioFixture { $0.shutdownGraceSeconds = 30 }
            let client = Client.ready(fixture.server)
            defer {
                fixture.probe.release()
                client.tearDown()
            }
            #expect(client.call(1, "hold", #"{"tag":"orphan"}"#))
            #expect(fixture.probe.eventually(seconds: 10) { $0.startedTags.contains("orphan") })
            client.closeOutput()
            // Any write now fails with EPIPE.
            #expect(client.request(2, "ping"))
            let cancelled = fixture.probe.eventually(seconds: 5) { $0.cancelledTags.contains("orphan") }
            #expect(cancelled, "5 s after the write failed the request in flight was still running")
            #expect(client.stopped(within: 5), "run had not returned 10 s after the client closed its end")
        }
    }

    @Suite struct Lifecycle {
        /// Counts are taken for the whole process. The author's suite in this target may have
        /// one session open at the same moment (two threads, up to five descriptors), hence the
        /// small allowance; a leak of one descriptor or thread per session would show as hundreds.
        private func settled(descriptors baseline: Int, threads: Int, allowance: Int) -> (descriptors: Int, threads: Int) {
            var best = (Int.max, Int.max)
            let deadline = Date().addingTimeInterval(5)
            repeat {
                best = (Swift.min(best.0, independentStdioOpenDescriptorCount()), Swift.min(best.1, independentStdioTransportThreads().count))
                if best.0 <= baseline + allowance, best.1 <= threads + 2 { break }
                usleep(50_000)
            } while Date() < deadline
            return best
        }

        @Test func hundredsOfSessionsOnOneServerLeakNoDescriptorsOrThreads() throws {
            let fixture = try independentStdioFixture()
            func session(_ index: Int) -> Bool {
                let client = Client.ready(fixture.server, channel: index % 2 == 0 ? .pipes : .socketpair)
                client.call(1, "echo", #"{"text":"session \#(index)"}"#)
                let answered = Client.text(of: client.readMessage()) == "session \(index)"
                client.closeInput()
                let stopped = client.stopped(within: 10)
                client.tearDown()
                return answered && stopped
            }
            #expect(session(0))
            let descriptors = independentStdioOpenDescriptorCount()
            let threads = independentStdioTransportThreads().count
            var failed = 0
            for index in 1...400 where !session(index) { failed += 1 }
            #expect(failed == 0)
            let after = settled(descriptors: descriptors, threads: threads, allowance: 6)
            #expect(after.descriptors <= descriptors + 6, "open descriptors: \(descriptors) before, \(after.descriptors) after 400 sessions")
            #expect(after.threads <= threads + 2, "transport threads: \(threads) before, \(after.threads) after 400 sessions")
            #expect(fixture.log.all == [])
        }

        /// The other ways a session ends must clean up too: the client goes away (EPIPE), the
        /// task is cancelled, the connection is dropped after a second oversized frame.
        @Test func sessionsThatEndAbnormallyLeakNoDescriptorsOrThreads() throws {
            let fixture = try independentStdioFixture { $0.budgets.maxFrameBytes = 4096 }
            let oversized = String(repeating: "x", count: 5000) + "\n"
            func session(_ index: Int) -> Bool {
                let client = Client.ready(fixture.server, channel: index % 2 == 0 ? .pipes : .socketpair)
                switch index % 3 {
                case 0:
                    if index % 2 == 0 {
                        client.closeOutput()
                        client.send(Client.requestLine(1, "ping") + Client.requestLine(2, "ping"))
                    } else {
                        client.send(Client.requestLine(1, "ping") + Client.requestLine(2, "ping"))
                        client.closeOutput()
                    }
                case 1:
                    client.call(1, "nap", #"{"ms":5,"tag":"x"}"#)
                    client.cancelRun()
                default:
                    client.send(oversized + oversized)
                }
                let stopped = client.stopped(within: 10)
                client.tearDown()
                return stopped
            }
            #expect(session(0) && session(1) && session(2))
            let descriptors = independentStdioOpenDescriptorCount()
            let threads = independentStdioTransportThreads().count
            var failed = 0
            for index in 3..<153 where !session(index) { failed += 1 }
            #expect(failed == 0)
            let after = settled(descriptors: descriptors, threads: threads, allowance: 6)
            #expect(after.descriptors <= descriptors + 6, "open descriptors: \(descriptors) before, \(after.descriptors) after 150 sessions")
            #expect(after.threads <= threads + 2, "transport threads: \(threads) before, \(after.threads) after 150 sessions")
        }

        @Test func sessionsAtTheSameTimeOnOneServerDoNotMix() throws {
            // Handler admission is one gate for the whole server: leave room for all 480 requests.
            let fixture = try independentStdioFixture { $0.budgets.maxQueuedRequests = 4096 }
            let clients = (0..<12).map { Client.ready(fixture.server, channel: $0 % 2 == 0 ? .pipes : .socketpair) }
            defer { for client in clients { client.tearDown() } }
            // The same ids on every connection: on stdio the id alone is the key (§7.2).
            for round in 1...40 {
                for (index, client) in clients.enumerated() {
                    #expect(client.call(round, "blob", #"{"size":\#(1000 * (index + 1)),"seed":\#(index * 1000 + round)}"#))
                }
            }
            for (index, client) in clients.enumerated() {
                let answers = client.responses(to: Set(1...40), timeout: 30)
                #expect(answers.count == 40, "session \(index)")
                let wrong = answers.filter { Client.text(of: $0.value) != independentStdioBlob(size: 1000 * (index + 1), seed: index * 1000 + $0.key) }
                #expect(wrong.isEmpty, "session \(index) got answers that are not its own: \(wrong.keys.sorted())")
                #expect(client.violations == [])
            }
            // Ending one session leaves the others running.
            clients[0].closeInput()
            #expect(clients[0].stopped(within: 10))
            clients[1].closeOutput()
            clients[1].request(99, "ping")
            #expect(clients[1].stopped(within: 10))
            for client in clients.dropFirst(2) {
                #expect(!client.hasReturned)
                #expect(client.request(100, "ping"))
                #expect(Client.id(of: client.readMessage()) == 100)
            }
            for client in clients.dropFirst(2) { client.closeInput() }
            for client in clients.dropFirst(2) { #expect(client.stopped(within: 10)) }
        }

        /// A second `run` on the same descriptors after the first returned: the transport holds
        /// no state of its own between sessions.
        @Test func aSecondSessionOnTheSameDescriptorsWorks() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server, channel: .socketpair)
            defer { client.tearDown() }
            client.cancelRun()
            #expect(client.stopped(within: 5))
            let second = Client(fixture.server, serverInput: client.serverInput, serverOutput: client.serverOutput, writeEnd: -1, readEnd: -1).start()
            // A new session is a new connection: the handshake of the first one is gone.
            #expect(client.request(1, "tools/list"))
            #expect(Client.errorCode(of: client.readMessage()) != nil)
            #expect(client.initialize() == "2025-11-25")
            #expect(client.call(2, "echo", #"{"text":"again"}"#))
            #expect(Client.text(of: client.readMessage()) == "again")
            client.closeInput()
            #expect(second.stopped(within: 10))
        }
    }
}
