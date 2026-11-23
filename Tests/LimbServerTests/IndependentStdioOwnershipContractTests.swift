#if os(macOS) || (os(Linux) && canImport(Glibc))
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Dispatch
import Foundation
import Limb
import Synchronization
import Testing

@Suite struct IndependentStdioOwnershipContractTests {
    @Test func onlyOneDefaultSessionCanRunAndTheNextSessionCanReuseIt() async {
        await #expect(processExitsWith: .success) {
            await StdioOwnershipProbe.run { try await StdioOwnershipProbe.checkDefaultSessions() }
        }
    }

    @Test func hostStdoutReplacementSurvivesDefaultSessionShutdown() async {
        await #expect(processExitsWith: .success) {
            await StdioOwnershipProbe.run { try await StdioOwnershipProbe.checkHostStdoutReplacement() }
        }
    }

    @Test func customSessionsCanOverlapAndLeaveCallerDescriptorsOpen() async {
        await #expect(processExitsWith: .success) {
            await StdioOwnershipProbe.run { try await StdioOwnershipProbe.checkCustomSessions() }
        }
    }

    @Test func transportPreservesTheProcessSIGPIPEDisposition() async {
        await #expect(processExitsWith: .success) {
            await StdioOwnershipProbe.run { try await StdioOwnershipProbe.checkSignalDisposition() }
        }
    }

    @Test func closingThePeerOutputEndsTheSessionWithDefaultSignalDisposition() async {
        await #expect(processExitsWith: .success) {
            await StdioOwnershipProbe.run { try await StdioOwnershipProbe.checkPeerDeparture() }
        }
    }

    #if canImport(Darwin)
    @Test func writerRestoresTheCallersOutputSignalOption() async {
        await #expect(processExitsWith: .success) {
            await StdioOwnershipProbe.run { try await StdioOwnershipProbe.checkOutputSignalOption() }
        }
    }

    @Test func aWriterRetainsItsOutputUntilItActuallyExits() async {
        await #expect(processExitsWith: .success) {
            await StdioOwnershipProbe.run { try await StdioOwnershipProbe.checkOutputOwnershipAfterDrain() }
        }
    }
    #endif
}

// Every probe runs in a Swift Testing child process. Pipes and descriptors stay open unless
// the probe explicitly closes them to send EOF. The OS releases any remaining handles on exit.
private enum StdioOwnershipProbe {
    private struct Failure: Error {
        let description: String
    }

    private struct Channel {
        let readEnd: Int32
        let writeEnd: Int32

        init() throws {
            var ends: [Int32] = [-1, -1]
            try check(pipe(&ends) == 0, "Could not create a pipe")
            readEnd = ends[0]
            writeEnd = ends[1]
        }

        func send(_ line: String) throws {
            let bytes = Array((line + "\n").utf8)
            let count = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) }
            try check(count == bytes.count, "Could not write a complete line")
        }

        func receiveMarker(_ marker: String) throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if try receiveLine(before: deadline) == marker { return }
            }
            throw Failure(description: "The application log did not appear on stderr")
        }

        func receiveLine(before deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(5)) throws -> String {
            var bytes: [UInt8] = []
            while ContinuousClock.now < deadline {
                var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                try check(ready > 0, "Could not poll the pipe")
                var byte: UInt8 = 0
                let count = read(readEnd, &byte, 1)
                if count < 0 && errno == EINTR { continue }
                try check(count == 1, "The pipe ended before a complete line arrived")
                if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(byte)
                try check(bytes.count <= 65_536, "Unexpectedly large reply")
            }
            throw Failure(description: "Timed out waiting for a complete line")
        }
    }

    private struct Peer {
        let input: Channel
        let output: Channel

        init() throws {
            input = try Channel()
            output = try Channel()
        }

        func installAsStandardStreams() throws {
            try check(dup2(input.readEnd, STDIN_FILENO) == STDIN_FILENO, "Could not install test stdin")
            try check(dup2(output.writeEnd, STDOUT_FILENO) == STDOUT_FILENO, "Could not install test stdout")
        }

        var transport: StdioTransport { StdioTransport(input: input.readEnd, output: output.writeEnd) }

        func requestToolList(id: Int) throws {
            try input.send(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
            )
        }

        func listTools(id: Int, serverName: String) throws {
            try requestToolList(id: id)
            let line = try output.receiveLine()
            let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let result = reply?["result"] as? [String: Any]
            let metadata = result?["_meta"] as? [String: Any]
            let serverInfo = metadata?["io.modelcontextprotocol/serverInfo"] as? [String: Any]
            try check(reply?["jsonrpc"] as? String == "2.0" && reply?["id"] as? Int == id, "Wrong JSON-RPC reply for request \(id)")
            try check(serverInfo?["name"] as? String == serverName, "Wrong server identity for request \(id): \(line)")
            let tools = result?["tools"] as? [[String: Any]]
            try check(tools?.first?["name"] as? String == "probe", "Wrong tool list for request \(id): \(line)")
        }

        func endInput() throws {
            try check(close(input.writeEnd) == 0, "Could not send end of input")
        }
    }

    private final class Session: Sendable {
        private let finished = Mutex(false)

        init(name: String, transport: StdioTransport = StdioTransport(), drainSeconds: Double = 5) throws {
            let server = Server(name: name, version: "1") { $0.outputDrainSeconds = drainSeconds }
            try server.register(tool: ToolDefinition(name: "probe", inputSchema: ["type": "object"])) { _, _ in
                .text("ok")
            }
            Task.detached { [self] in
                await server.run(transport)
                finished.withLock { $0 = true }
            }
        }

        var hasReturned: Bool { finished.withLock { $0 } }

        func waitForReturn(_ message: String) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while !hasReturned && clock.now < deadline {
                try await clock.sleep(for: .milliseconds(5))
            }
            try check(hasReturned, message)
        }
    }

    static func run(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            let description = (error as? Failure)?.description ?? String(describing: error)
            try? FileHandle.standardError.write(contentsOf: Data((description + "\n").utf8))
            exit(1)
        }
    }

    static func checkDefaultSessions() async throws {
        let errors = try Channel()
        let savedError = dup(STDERR_FILENO)
        try check(savedError >= 0, "Could not save stderr")
        defer {
            _ = dup2(savedError, STDERR_FILENO)
            close(savedError)
        }
        try check(dup2(errors.writeEnd, STDERR_FILENO) == STDERR_FILENO, "Could not install test stderr")

        let first = try Peer()
        try first.installAsStandardStreams()
        let owner = try Session(name: "first-default")
        try first.listTools(id: 1, serverName: "first-default")

        let contender = try Session(name: "second-default")
        try await contender.waitForReturn("A second default session waited for the first session's EOF")
        try check(!owner.hasReturned, "The second run stopped the active owner")

        // The diagnostic can appear before the marker, for example when the second run refuses to start.
        let marker = "stdio ownership test log"
        let bytes = Array((marker + "\n").utf8)
        let count = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        try check(count == bytes.count, "Could not write the application log")
        try first.listTools(id: 2, serverName: "first-default")
        try errors.receiveMarker(marker)

        try first.endInput()
        try await owner.waitForReturn("The active default session did not finish at EOF")

        let next = try Peer()
        try next.installAsStandardStreams()
        let successor = try Session(name: "next-default")
        try next.listTools(id: 3, serverName: "next-default")
        try next.endInput()
        try await successor.waitForReturn("The subsequent default session did not finish at EOF")
    }

    static func checkHostStdoutReplacement() async throws {
        let peer = try Peer()
        let hostOutput = try Channel()
        try peer.installAsStandardStreams()
        let session = try Session(name: "default-with-host-output")
        try peer.listTools(id: 1, serverName: "default-with-host-output")

        try check(dup2(hostOutput.writeEnd, STDOUT_FILENO) == STDOUT_FILENO, "Could not replace stdout")
        // The live transport must continue writing protocol replies to the original pipe.
        try peer.listTools(id: 2, serverName: "default-with-host-output")

        try peer.endInput()
        try await session.waitForReturn("The default session did not finish at EOF")

        let marker = "application output after transport shutdown"
        let bytes = Array((marker + "\n").utf8)
        let count = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        try check(count == bytes.count, "Could not write to stdout after transport shutdown")
        try check(try hostOutput.receiveLine() == marker, "Transport shutdown replaced the host's stdout")
    }

    static func checkCustomSessions() async throws {
        let first = try Peer()
        let second = try Peer()
        let one = try Session(name: "first-custom", transport: first.transport)
        try first.listTools(id: 1, serverName: "first-custom")
        let two = try Session(name: "second-custom", transport: second.transport)
        try second.listTools(id: 2, serverName: "second-custom")
        try check(!one.hasReturned && !two.hasReturned, "Both custom sessions must remain active")

        try first.endInput()
        try await one.waitForReturn("The first custom session did not finish at EOF")
        try second.listTools(id: 3, serverName: "second-custom")
        try second.endInput()
        try await two.waitForReturn("The second custom session did not finish at EOF")
        for peer in [first, second] {
            try check(fcntl(peer.input.readEnd, F_GETFD) >= 0, "The transport closed the caller's input descriptor")
            try check(fcntl(peer.output.writeEnd, F_GETFD) >= 0, "The transport closed the caller's output descriptor")
            try peer.output.send("caller still controls the writer")
            try check(try peer.output.receiveLine() == "caller still controls the writer", "The caller's output stopped working")
        }
    }

    static func checkSignalDisposition() async throws {
        let before = try installSignalDisposition()
        let peer = try Peer()
        let session = try Session(name: "signal-check", transport: peer.transport)
        try peer.listTools(id: 1, serverName: "signal-check")
        try check(try sigpipeDisposition() == before, "Transport startup changed the SIGPIPE disposition")
        try peer.endInput()
        try await session.waitForReturn("The signal test session did not finish at EOF")
        try check(try sigpipeDisposition() == before, "Transport shutdown changed the SIGPIPE disposition")
    }

    static func checkPeerDeparture() async throws {
        let previous = signal(SIGPIPE, SIG_DFL)
        try check(unsafeBitCast(previous, to: UInt.self) != unsafeBitCast(SIG_ERR, to: UInt.self), "Could not use the default disposition")
        let peer = try Peer()
        let session = try Session(name: "peer-departure", transport: peer.transport)
        try peer.listTools(id: 1, serverName: "peer-departure")
        try check(close(peer.output.readEnd) == 0, "Could not close the peer's output reader")
        try peer.requestToolList(id: 2)
        try await session.waitForReturn("The server did not return after the peer closed its reader")
    }

    #if canImport(Darwin)
    static func checkOutputSignalOption() async throws {
        for original: Int32 in [0, 1] {
            let peer = try Peer()
            let output = peer.output.writeEnd
            try check(fcntl(output, F_SETNOSIGPIPE, original) == 0, "Could not configure the caller's output")
            let session = try Session(name: "signal-option", transport: peer.transport)
            try peer.listTools(id: 1, serverName: "signal-option")
            try peer.endInput()
            try await session.waitForReturn("The session did not end after EOF")
            try check(fcntl(output, F_GETNOSIGPIPE) == original, "The writer changed the caller's option after shutdown")
        }
    }

    static func checkOutputOwnershipAfterDrain() async throws {
        let peer = try Peer()
        let writerReachedFrame = Atomic(false)
        let releaseWriter = DispatchSemaphore(value: 0)
        var transport = peer.transport
        transport.beforeKeyedWrite = { _ in
            writerReachedFrame.store(true, ordering: .releasing)
            _ = releaseWriter.wait(timeout: .now() + .seconds(12))
        }
        let owner = try Session(name: "draining-writer", transport: transport, drainSeconds: 0)
        defer { releaseWriter.signal() }
        try peer.input.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"probe","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#)
        let clock = ContinuousClock()
        let firstDeadline = clock.now + .seconds(5)
        while !writerReachedFrame.load(ordering: .acquiring), clock.now < firstDeadline {
            try await clock.sleep(for: .milliseconds(5))
        }
        try check(writerReachedFrame.load(ordering: .acquiring), "Writer did not reach its frame")
        try peer.endInput()
        try await owner.waitForReturn("The session did not return while its writer was still active")

        let other = try Channel()
        let alias = dup(peer.output.writeEnd)
        try check(alias >= 0, "Could not duplicate the active output")
        let aliasedTransport = StdioTransport(input: other.readEnd, output: alias)
        let contender = try Session(name: "overlapping-writer", transport: aliasedTransport)
        try await contender.waitForReturn("A second writer started on the still-active output")

        releaseWriter.signal()
        let first = try peer.output.receiveLine()
        try check(first.contains("draining-writer"), "The first writer did not finish its response")
        let deadline = clock.now + .seconds(5)
        while fcntl(alias, F_GETNOSIGPIPE) != 0, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(5))
        }
        try check(fcntl(alias, F_GETNOSIGPIPE) == 0, "The old writer did not restore the output option")

        let successor = try Session(name: "replacement-writer", transport: aliasedTransport)
        try other.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#)
        let second = try peer.output.receiveLine()
        try check(second.contains("replacement-writer"), "The output was not available for the successor")
        try check(close(other.writeEnd) == 0, "Could not end the replacement session's input")
        try await successor.waitForReturn("The replacement session did not end at EOF")
    }
    #endif

    private static func installSignalDisposition() throws -> UInt {
        // Install an application-owned disposition in this child. The test never sends SIGPIPE.
        let previous = signal(SIGPIPE, { _ in })
        try check(unsafeBitCast(previous, to: UInt.self) != unsafeBitCast(SIG_ERR, to: UInt.self), "Could not set the SIGPIPE disposition")
        return try sigpipeDisposition()
    }

    private static func sigpipeDisposition() throws -> UInt {
        var action = sigaction()
        try check(sigaction(SIGPIPE, nil, &action) == 0, "Could not read the SIGPIPE disposition")
        #if canImport(Darwin)
        let handler = action.__sigaction_u.__sa_handler
        #else
        let handler = action.__sigaction_handler.sa_handler
        #endif
        return unsafeBitCast(handler, to: UInt.self)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }
}
#endif
