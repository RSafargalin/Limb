#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Limb
import Synchronization
import Testing

/// The client's end of a stdio connection to an in-process server.
final class Peer: @unchecked Sendable {
    let writeEnd: Int32
    let readEnd: Int32
    private var pending: [UInt8] = []
    private var scanned = 0
    let finished: Task<Void, Never>

    enum Channel { case pipes, socketpair }

    init(_ server: Server, channel: Channel = .pipes) {
        switch channel {
        case .pipes:
            var toServer: [Int32] = [0, 0]
            var fromServer: [Int32] = [0, 0]
            precondition(pipe(&toServer) == 0 && pipe(&fromServer) == 0)
            writeEnd = toServer[1]
            readEnd = fromServer[0]
            let transport = StdioTransport(input: toServer[0], output: fromServer[1])
            finished = Task {
                await server.run(transport)
                close(transport.input)
                close(transport.output)
            }
        case .socketpair:
            // One socket as both stdin and stdout: how Node spawns child processes.
            var sockets: [Int32] = [0, 0]
            precondition(socketpair(AF_UNIX, independentStdioStreamSocket, 0, &sockets) == 0)
            writeEnd = sockets[0]
            readEnd = sockets[0]
            let transport = StdioTransport(input: sockets[1], output: sockets[1])
            finished = Task {
                await server.run(transport)
                close(transport.input)
            }
        }
    }

    /// Whether everything was written. `false` means the server's input is gone.
    @discardableResult
    func send(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    @discardableResult
    func request(_ id: Int, _ method: String, _ params: String = "{}") -> Bool {
        send(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"# + "\n")
    }

    func initialize() -> JSONValue? {
        request(0, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#)
        let response = readMessage()
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n")
        return response
    }

    /// The next line, without its terminator; `nil` on end of stream or timeout.
    func readLine(timeoutMilliseconds: Int32 = 5000, chunk: Int = 65536) -> [UInt8]? {
        while true {
            if let newline = pending[scanned...].firstIndex(of: 0x0A) {
                let line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                scanned = 0
                return line
            }
            scanned = pending.count
            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: chunk)
            let count = read(readEnd, &buffer, chunk)
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer[..<count])
        }
    }

    func readMessage(timeoutMilliseconds: Int32 = 5000) -> JSONValue? {
        readLine(timeoutMilliseconds: timeoutMilliseconds).flatMap { try? JSON.parse($0) }
    }

    func closeInput() {
        if writeEnd == readEnd { shutdown(writeEnd, Int32(SHUT_WR)) } else { close(writeEnd) }
    }

    /// Whether the server's `run` returned within the time limit.
    func serverStopped(within seconds: Double) async -> Bool {
        let done = Mutex(false)
        let watcher = Task {
            await finished.value
            done.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if done.withLock({ $0 }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        watcher.cancel()
        return done.withLock { $0 }
    }
}

func makeStdioServer(
    release: Gate = Gate(), hangCancelled: Gate = Gate(), configure: (inout ServerConfiguration) -> Void = { _ in }
) throws -> Server {
    let server = Server(name: "stdio-fixture", version: "1.0.0") { configuration in
        configuration.diagnostics = { _ in }
        configure(&configuration)
    }
    try server.register(
        tool: ToolDefinition(name: "echo", inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]])
    ) { arguments, _ in .text(arguments["text"]?.stringValue ?? "") }
    try server.register(
        tool: ToolDefinition(name: "big", inputSchema: ["type": "object", "properties": ["tag": ["type": "string"]]])
    ) { arguments, _ in
        .text(
            String(
                repeating: (arguments["tag"]?.stringValue ?? "?") + " line of a large response\\n\n",
                count: arguments["lines"]?.intValue ?? 2000))
    }
    try server.register(tool: ToolDefinition(name: "wait")) { _, _ in
        await release.wait()
        return .text("released")
    }
    try server.register(tool: ToolDefinition(name: "hang")) { _, _ in
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            hangCancelled.open()
            throw error
        }
        return .text("never")
    }
    return server
}

final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    var isOpen: Bool { state.withLock { $0.open } }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

@Suite(.serialized) struct StdioTransportTests {
    @Test func roundTripOverPipes() async throws {
        let peer = Peer(try makeStdioServer())
        #expect(peer.initialize()?["result"]?["protocolVersion"] == "2025-11-25")
        peer.request(1, "tools/call", #"{"name":"echo","arguments":{"text":"hi"}}"#)
        #expect(peer.readMessage()?["result"]?["content"]?[0]?["text"] == "hi")
        peer.closeInput()
        #expect(await peer.serverStopped(within: 2))
    }

    @Test func worksWhenStdinAndStdoutAreOneSocket() async throws {
        let peer = Peer(try makeStdioServer(), channel: .socketpair)
        #expect(peer.initialize()?["result"]?["serverInfo"]?["name"] == "stdio-fixture")
        for index in 1...50 {
            peer.request(index, "tools/call", #"{"name":"echo","arguments":{"text":"s\#(index)"}}"#)
            #expect(peer.readMessage()?["result"]?["content"]?[0]?["text"]?.stringValue == "s\(index)")
        }
        peer.closeInput()
        #expect(await peer.serverStopped(within: 2))
    }

    @Test func toleratesCRLFAndBlankLines() async throws {
        let peer = Peer(try makeStdioServer())
        peer.send("\n\r\n" + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\r\n\n")
        #expect(peer.readMessage()?["result"] == [:])
        peer.closeInput()
        #expect(await peer.serverStopped(within: 2))
    }

    @Test func modernRequestsNeedNoHandshake() async throws {
        let peer = Peer(try makeStdioServer())
        peer.request(
            1, "server/discover",
            #"{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}"#)
        #expect(peer.readMessage()?["result"]?["supportedVersions"]?[0] == "2026-07-28")
        peer.closeInput()
        #expect(await peer.serverStopped(within: 2))
    }

    @Test func framesNeverInterleaveUnderBackpressure() async throws {
        let peer = Peer(try makeStdioServer { $0.budgets.maxQueuedRequests = 256 })
        _ = peer.initialize()
        let total = 96
        let lines = [1, 40, 900, 1100, 2000, 6000]
        for index in 1...total {
            peer.request(index, "tools/call", #"{"name":"big","arguments":{"tag":"r\#(index)","lines":\#(lines[index % lines.count])}}"#)
        }
        // Let responses pile up against a full pipe before reading anything.
        try await Task.sleep(for: .milliseconds(300))
        var seen: Set<Int> = []
        for round in 1...total {
            let line = try #require(peer.readLine(chunk: [1, 7, 512, 4096, 65536][round % 5]))
            let message = try JSON.parse(line)
            let id = try #require(message["id"]?.intValue)
            let text = try #require(message["result"]?["content"]?[0]?["text"]?.stringValue)
            #expect(text == String(repeating: "r\(id) line of a large response\\n\n", count: lines[id % lines.count]))
            seen.insert(id)
        }
        #expect(seen.count == total)
        peer.closeInput()
        #expect(await peer.serverStopped(within: 2))
    }

    @Test func endOfInputStopsTheServerPromptly() async throws {
        let before = Peer(try makeStdioServer())
        before.closeInput()
        #expect(await before.serverStopped(within: 1))

        let after = Peer(try makeStdioServer())
        _ = after.initialize()
        after.closeInput()
        #expect(await after.serverStopped(within: 1))
    }

    @Test func requestsInFlightAtEndOfInputStillGetAnswers() async throws {
        let release = Gate()
        let peer = Peer(try makeStdioServer(release: release))
        _ = peer.initialize()
        peer.request(1, "tools/call", #"{"name":"wait"}"#)
        peer.request(2, "tools/call", #"{"name":"echo","arguments":{"text":"piped"}}"#)
        peer.closeInput()
        #expect(peer.readMessage()?["result"]?["content"]?[0]?["text"] == "piped")
        release.open()
        #expect(peer.readMessage()?["id"] == 1)
        #expect(await peer.serverStopped(within: 2))
    }

    /// Changed by the independent test author: the test only checked that `run` returned
    /// within 3 s, which it also would with no grace period at all or with a handler that was
    /// never cancelled. It now checks both.
    @Test func handlersStillRunningAfterTheGracePeriodAreCancelled() async throws {
        let cancelled = Gate()
        let peer = Peer(try makeStdioServer(hangCancelled: cancelled) { $0.shutdownGraceSeconds = 1 })
        _ = peer.initialize()
        peer.request(1, "tools/call", #"{"name":"hang"}"#)
        // The handshake's notification and the request are behind us once this ping is answered.
        peer.request(2, "ping")
        #expect(peer.readMessage()?["id"] == 2)
        peer.closeInput()
        #expect(await !peer.serverStopped(within: 0.5), "the grace period of 1 s was not granted")
        #expect(!cancelled.isOpen, "the handler was cancelled before the grace period was over")
        #expect(await peer.serverStopped(within: 5))
        #expect(cancelled.isOpen, "the handler was never cancelled")
    }

    @Test func oversizedFrameIsRejectedAndTheStreamRecovers() async throws {
        let peer = Peer(try makeStdioServer { $0.budgets.maxFrameBytes = 8192 })
        _ = peer.initialize()
        peer.request(1, "tools/call", #"{"name":"echo","arguments":{"text":"\#(String(repeating: "a", count: 20_000))"}}"#)
        let rejected = peer.readMessage()
        #expect(rejected?["error"]?["code"] == -32600)
        #expect(rejected?["id"] == .null)
        peer.request(2, "ping")
        #expect(peer.readMessage()?["id"] == 2)
        // A second oversized frame is not an accident: the server gives up on the connection.
        peer.request(3, "tools/call", #"{"name":"echo","arguments":{"text":"\#(String(repeating: "b", count: 20_000))"}}"#)
        #expect(peer.readMessage()?["error"]?["code"] == -32600)
        #expect(await peer.serverStopped(within: 2))
    }

    @Test func invalidUTF8IsAParseError() async throws {
        let peer = Peer(try makeStdioServer())
        var bytes = Array(#"{"jsonrpc":"2.0","id":1,"method":""#.utf8)
        bytes += [0xFF, 0xFE]
        bytes += Array("\"}\n".utf8)
        _ = bytes.withUnsafeBytes { write(peer.writeEnd, $0.baseAddress, $0.count) }
        #expect(peer.readMessage()?["error"]?["code"] == -32700)
        peer.closeInput()
        #expect(await peer.serverStopped(within: 2))
    }

    @Test func aPeerThatStopsReadingDoesNotCrashOrHangTheServer() async throws {
        let peer = Peer(try makeStdioServer { $0.outputDrainSeconds = 1 })
        _ = peer.initialize()
        for index in 1...20 {
            peer.request(index, "tools/call", #"{"name":"big","arguments":{"tag":"x"}}"#)
        }
        peer.closeInput()
        #expect(await peer.serverStopped(within: 8))
        // The writer left behind ends when the peer goes: before the server's descriptors are
        // closed by the task above, nothing else must be written to them.
        close(peer.readEnd)
    }

    /// The old body of the test above: the peer closes its end, and the server's writes fail
    /// with EPIPE. `Peer` no longer ignores SIGPIPE itself, so this also shows that `run` does.
    @Test func aPeerThatClosedItsEndDoesNotCrashOrHangTheServer() async throws {
        let peer = Peer(try makeStdioServer())
        _ = peer.initialize()
        close(peer.readEnd)
        for index in 1...20 {
            peer.request(index, "tools/call", #"{"name":"big","arguments":{"tag":"x"}}"#)
        }
        #expect(await peer.serverStopped(within: 3))
    }

    @Test func cancellingTheTaskStopsTheServer() async throws {
        let peer = Peer(try makeStdioServer())
        _ = peer.initialize()
        peer.finished.cancel()
        #expect(await peer.serverStopped(within: 2))
    }
}
