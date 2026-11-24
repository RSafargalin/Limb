#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Limb
import Testing


private typealias Client = IndependentStdioClient

private func temporaryFile() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("independent-stdio-\(UUID().uuidString)").path
}

/// A descriptor number that is certainly not open, and not one another test could get.
private func closedDescriptor() -> Int32 {
    var candidate: Int32 = 60_000
    while fcntl(candidate, F_GETFD) != -1 { candidate += 1 }
    return candidate
}

extension IndependentStdioTransportTests {
    @Suite struct Descriptors {
        // MARK: Flags

        @Test(arguments: [false, true], [false, true])
        func descriptorFlagsAreTheSameBeforeDuringAndAfterASession(socket: Bool, nonBlocking: Bool) throws {
            let fixture = try independentStdioFixture()
            let client = Client(fixture.server, channel: socket ? .socketpair : .pipes)
            defer { client.tearDown() }
            if nonBlocking {
                // A parent may have made a shared pipe non-blocking before the server started.
                independentStdioSetNonBlocking(client.serverInput)
                independentStdioSetNonBlocking(client.serverOutput)
            }
            let inputBefore = try #require(IndependentStdioDescriptorState(client.serverInput))
            let outputBefore = try #require(IndependentStdioDescriptorState(client.serverOutput))
            #expect(inputBefore.isNonBlocking == nonBlocking)

            client.start()
            #expect(client.initialize() == "2025-11-25")
            // Idle: the reader is waiting for input.
            usleep(20_000)
            #expect(IndependentStdioDescriptorState(client.serverInput) == inputBefore, "input, idle")
            #expect(IndependentStdioDescriptorState(client.serverOutput) == outputBefore, "output, idle")

            // Busy: responses larger than the channel holds, so the writer has to wait for room.
            for id in 1...6 { #expect(client.call(id, "blob", #"{"size":400000,"seed":\#(id)}"#)) }
            var changedWhileBusy = 0
            for _ in 0..<50 {
                if IndependentStdioDescriptorState(client.serverInput) != inputBefore { changedWhileBusy += 1 }
                if IndependentStdioDescriptorState(client.serverOutput) != outputBefore { changedWhileBusy += 1 }
                usleep(2000)
            }
            #expect(changedWhileBusy == 0, "flags differed in \(changedWhileBusy) samples while the writer was blocked")
            let answers = client.responses(to: Set(1...6), timeout: 60)
            #expect(answers.count == 6)
            for (id, answer) in answers {
                #expect(Client.text(of: answer) == independentStdioBlob(size: 400_000, seed: id), "blob \(id)")
            }
            #expect(IndependentStdioDescriptorState(client.serverInput) == inputBefore, "input, after the burst")
            #expect(IndependentStdioDescriptorState(client.serverOutput) == outputBefore, "output, after the burst")

            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(IndependentStdioDescriptorState(client.serverInput) == inputBefore, "input, after run returned")
            #expect(IndependentStdioDescriptorState(client.serverOutput) == outputBefore, "output, after run returned")
            #expect(client.violations == [])
        }

        /// The transport is given descriptor numbers, not ownership: nothing in the API says it
        /// closes them, and the standard streams of a process must stay usable after `run`.
        @Test func descriptorsAreLeftOpenAndUsableAfterRunReturns() throws {
            let fixture = try independentStdioFixture()
            let client = Client.started(fixture.server)
            defer { client.tearDown() }
            let inputBefore = try #require(IndependentStdioDescriptorState(client.serverInput))
            let outputBefore = try #require(IndependentStdioDescriptorState(client.serverOutput))
            #expect(client.request(1, "ping"))
            #expect(Client.id(of: client.readMessage()) == 1)
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(IndependentStdioDescriptorState(client.serverInput) == inputBefore)
            #expect(IndependentStdioDescriptorState(client.serverOutput) == outputBefore)
            // The output still reaches the client: the process can go on to print its own goodbye.
            let farewell = Array(#"{"jsonrpc":"2.0","method":"notifications/independent"}"#.utf8) + [0x0A]
            #expect(farewell.withUnsafeBytes { write(client.serverOutput, $0.baseAddress, $0.count) } == farewell.count)
            #expect(client.readMessage()?["method"] as? String == "notifications/independent")
        }

        // MARK: Sockets

        @Test(arguments: [false, true])
        func oneSocketAsInputAndOutputCarriesLargeTrafficBothWays(nonBlocking: Bool) throws {
            let fixture = try independentStdioFixture()
            let client = Client(fixture.server, channel: .socketpair)
            defer { client.tearDown() }
            if nonBlocking { independentStdioSetNonBlocking(client.serverInput) }
            client.start()
            #expect(client.initialize() == "2025-11-25")
            // Large requests and large responses at the same time, on the same socket.
            let payload = independentStdioBlob(size: 300_000, seed: 77)
            var expected: [Int: String] = [:]
            for id in 1...10 {
                if id % 2 == 0 {
                    #expect(client.call(id, "length", #"{"text":"\#(payload)"}"#))
                    expected[id] = "300000"
                } else {
                    #expect(client.call(id, "blob", #"{"size":500000,"seed":\#(id)}"#))
                    expected[id] = independentStdioBlob(size: 500_000, seed: id)
                }
            }
            let answers = client.responses(to: Set(1...10), timeout: 60, chunk: 8192)
            #expect(answers.count == 10)
            for (id, answer) in answers { #expect(Client.text(of: answer) == expected[id], "request \(id)") }
            #expect(client.violations == [])
            // Half-close: the client is done sending but still reads.
            #expect(client.call(11, "nap", #"{"ms":150,"tag":"after-half-close"}"#))
            client.closeInput()
            #expect(Client.text(of: client.responses(to: [11])[11]) == "woke after-half-close")
            #expect(client.stopped(within: 10))
        }

        // MARK: Files and devices

        @Test func aRegularFileAsInputIsReadToItsEndAndAnswered() throws {
            // A file is read as fast as the reader can go: leave room for every request to wait.
            let fixture = try independentStdioFixture { $0.budgets.maxQueuedRequests = 4096 }
            let path = temporaryFile()
            defer { unlink(path) }
            var script = Client.requestLine(0, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"file","version":"1"}}"#)
            script += #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
            for id in 1...200 { script += Client.callLine(id, "echo", #"{"text":"from a file \#(id)"}"#) }
            // Larger than one read of the transport.
            script += Client.callLine(201, "length", #"{"text":"\#(String(repeating: "f", count: 200_000))"}"#)
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            let input = open(path, O_RDONLY)
            try #require(input >= 0)
            var fromServer: [Int32] = [-1, -1]
            try #require(pipe(&fromServer) == 0)
            let client = Client(fixture.server, serverInput: input, serverOutput: fromServer[1], writeEnd: -1, readEnd: fromServer[0]).start()
            defer { client.tearDown() }
            let answers = client.responses(to: Set(0...201), timeout: 30)
            #expect(answers.count == 202)
            #expect(Client.text(of: answers[200]) == "from a file 200")
            #expect(Client.text(of: answers[201]) == "200000")
            // End of file is end of input.
            #expect(client.stopped(within: 10))
            #expect(client.violations == [])
        }

        @Test func aRegularFileAsOutputReceivesExactlyTheMessages() throws {
            let fixture = try independentStdioFixture()
            let path = temporaryFile()
            defer { unlink(path) }
            let output = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            try #require(output >= 0)
            var toServer: [Int32] = [-1, -1]
            try #require(pipe(&toServer) == 0)
            let client = Client(fixture.server, serverInput: toServer[0], serverOutput: output, writeEnd: toServer[1], readEnd: -1).start()
            defer { client.tearDown() }
            var script = Client.requestLine(0, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"file","version":"1"}}"#)
            for id in 1...50 { script += Client.callLine(id, "blob", #"{"size":\#(id * 3000),"seed":\#(id)}"#) }
            #expect(client.send(script))
            client.closeInput()
            #expect(client.stopped(within: 20))
            let written = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(written.last == 0x0A)
            let lines = written.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
            #expect(lines.count == 51)
            var seen: Set<Int> = []
            for line in lines {
                let message = try #require(try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                #expect(message["jsonrpc"] as? String == "2.0")
                let id = try #require(Client.id(of: message))
                if id > 0 { #expect(Client.text(of: message) == independentStdioBlob(size: id * 3000, seed: id), "blob \(id)") }
                seen.insert(id)
            }
            #expect(seen == Set(0...50))
        }

        @Test func devNullAsInputIsAnImmediateEndOfInput() throws {
            let fixture = try independentStdioFixture()
            let input = open("/dev/null", O_RDONLY)
            try #require(input >= 0)
            var fromServer: [Int32] = [-1, -1]
            try #require(pipe(&fromServer) == 0)
            let client = Client(fixture.server, serverInput: input, serverOutput: fromServer[1], writeEnd: -1, readEnd: fromServer[0]).start()
            defer { client.tearDown() }
            #expect(client.stopped(within: 5))
            #expect(client.drain(seconds: 0.1).isEmpty)
            #expect(fixture.log.all == [])
        }

        @Test func devNullAsOutputSwallowsTheAnswers() throws {
            let fixture = try independentStdioFixture()
            let output = open("/dev/null", O_WRONLY)
            try #require(output >= 0)
            var toServer: [Int32] = [-1, -1]
            try #require(pipe(&toServer) == 0)
            let client = Client(fixture.server, serverInput: toServer[0], serverOutput: output, writeEnd: toServer[1], readEnd: -1).start()
            defer { client.tearDown() }
            var script = Client.requestLine(0, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"null","version":"1"}}"#)
            for id in 1...40 { script += Client.callLine(id, "blob", #"{"size":200000,"seed":\#(id)}"#) }
            #expect(client.send(script))
            #expect(fixture.probe.eventually(seconds: 20) { $0.finishedTags.count == 40 })
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(fixture.log.all == [])
        }

        @Test func anInputAlreadyAtItsEndStopsTheServerAtOnce() throws {
            let fixture = try independentStdioFixture()
            let client = Client(fixture.server)
            defer { client.tearDown() }
            client.closeInput()
            client.start()
            #expect(client.stopped(within: 5))
            #expect(client.drain(seconds: 0.1).isEmpty)
            #expect(fixture.log.all == [])
        }

        /// A client that writes its requests and closes the stream before the server has even
        /// started reading ("a client that pipes requests in and closes stdin still wants
        /// answers", `Connection.close`).
        @Test func requestsWrittenBeforeTheServerStartedAreAnsweredAfterTheInputClosed() throws {
            let fixture = try independentStdioFixture()
            let client = Client(fixture.server)
            defer { client.tearDown() }
            var script = Client.requestLine(0, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"early","version":"1"}}"#)
            for id in 1...20 { script += Client.callLine(id, "echo", #"{"text":"early \#(id)"}"#) }
            #expect(client.send(script))
            client.closeInput()
            client.start()
            let answers = client.responses(to: Set(0...20), timeout: 20)
            #expect(answers.count == 21)
            #expect(client.stopped(within: 10))
        }

        // MARK: Terminals

        /// `StdioTransport`: "Pipes, sockets, files and terminals all work as either end."
        /// A pseudo-terminal in raw mode stands in for a terminal.
        #if canImport(Darwin)
        @Test func aTerminalWorksAsBothEnds() throws {
            let fixture = try independentStdioFixture()
            let master = posix_openpt(O_RDWR | O_NOCTTY)
            try #require(master >= 0)
            try #require(grantpt(master) == 0 && unlockpt(master) == 0)
            let name = try #require(ptsname(master).map { String(cString: $0) })
            let slave = open(name, O_RDWR | O_NOCTTY)
            try #require(slave >= 0)
            var settings = termios()
            try #require(tcgetattr(slave, &settings) == 0)
            cfmakeraw(&settings)
            try #require(tcsetattr(slave, TCSANOW, &settings) == 0)
            let before = try #require(IndependentStdioDescriptorState(slave))

            let client = Client(fixture.server, serverInput: slave, serverOutput: slave, writeEnd: master, readEnd: master).start()
            defer { client.tearDown() }
            #expect(client.initialize() == "2025-11-25")
            for id in 1...20 {
                #expect(client.call(id, "echo", #"{"text":"tty \#(id)"}"#))
                let response = client.readMessage(timeout: 10)
                #expect(Client.id(of: response) == id)
                #expect(Client.text(of: response) == "tty \(id)")
            }
            #expect(IndependentStdioDescriptorState(slave) == before)
            var after = termios()
            #expect(tcgetattr(slave, &after) == 0)
            #expect(after.c_lflag == settings.c_lflag && after.c_iflag == settings.c_iflag && after.c_oflag == settings.c_oflag, "terminal modes changed")
            #expect(client.violations == [])
            // A terminal has no end of input to send in raw mode; stop the way a signal handler would.
            client.cancelRun()
            #expect(client.stopped(within: 10))
        }

        // MARK: Descriptors that are not open

        #endif
        @Test func aClosedInputDescriptorEndsTheSessionWithADiagnostic() throws {
            let fixture = try independentStdioFixture()
            var fromServer: [Int32] = [-1, -1]
            try #require(pipe(&fromServer) == 0)
            let client = Client(fixture.server, serverInput: closedDescriptor(), serverOutput: fromServer[1], writeEnd: -1, readEnd: fromServer[0]).start()
            defer {
                client.cancelRun()
                _ = client.stopped(within: 10)
                close(fromServer[0])
                close(fromServer[1])
            }
            #expect(client.stopped(within: 5))
            #expect(client.drain(seconds: 0.1).isEmpty)
            #expect(fixture.log.all.count == 1, "\(fixture.log.all)")
        }

        @Test func aClosedOutputDescriptorEndsTheSessionWithADiagnostic() throws {
            let fixture = try independentStdioFixture()
            var toServer: [Int32] = [-1, -1]
            try #require(pipe(&toServer) == 0)
            let client = Client(fixture.server, serverInput: toServer[0], serverOutput: closedDescriptor(), writeEnd: toServer[1], readEnd: -1).start()
            defer {
                client.cancelRun()
                _ = client.stopped(within: 10)
                close(toServer[0])
                close(toServer[1])
            }
            usleep(50_000)
            // Nothing has been written yet, so nothing has failed yet.
            #expect(!client.hasReturned)
            #expect(client.request(1, "ping"))
            #expect(client.stopped(within: 5))
            #expect(fixture.log.all.contains { $0.contains("write") }, "\(fixture.log.all)")
        }

        @Test func minusOneAsInputWaitsUntilCancelledObservedUnspecified() throws {
            let fixture = try independentStdioFixture()
            var fromServer: [Int32] = [-1, -1]
            try #require(pipe(&fromServer) == 0)
            let client = Client(fixture.server, serverInput: -1, serverOutput: fromServer[1], writeEnd: -1, readEnd: fromServer[0]).start()
            defer {
                client.cancelRun()
                _ = client.stopped(within: 10)
                close(fromServer[0])
                close(fromServer[1])
            }
            #expect(!client.stopped(within: 0.5), "observed: run does not return")
            #expect(fixture.log.all == [], "observed: nothing is logged")
            client.cancelRun()
            #expect(client.stopped(within: 10))
        }
    }
}
