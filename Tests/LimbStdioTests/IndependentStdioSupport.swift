#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Limb
import Synchronization
import Testing


/// Every transport test lives in an extension of this suite. Serialized on purpose: several of
/// them count file descriptors and threads of the process, or measure CPU time.
@Suite(.serialized) struct IndependentStdioTransportTests {}

// MARK: - Small utilities

final class IndependentStdioLog: Sendable {
    private let lines = Mutex<[String]>([])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// What handlers of the fixture server report back to the test.
final class IndependentStdioProbe: Sendable {
    private struct State {
        var started: [String] = []
        var finished: [String] = []
        var cancelled: [String] = []
        var open = false
    }

    private let state = Mutex(State())

    func started(_ tag: String) { state.withLock { $0.started.append(tag) } }
    func finished(_ tag: String) { state.withLock { $0.finished.append(tag) } }
    func cancelled(_ tag: String) { state.withLock { $0.cancelled.append(tag) } }
    var startedTags: [String] { state.withLock { $0.started } }
    var finishedTags: [String] { state.withLock { $0.finished } }
    var cancelledTags: [String] { state.withLock { $0.cancelled } }

    /// Lets every `hold` handler return.
    func release() { state.withLock { $0.open = true } }
    var isReleased: Bool { state.withLock { $0.open } }

    /// Polls `condition` until it holds or the time is up.
    func eventually(seconds: Double, _ condition: (IndependentStdioProbe) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(self) { return true }
            usleep(2000)
        }
        return condition(self)
    }
}

/// Deterministic text of exactly `size` UTF-8 bytes; different seeds give different text.
func independentStdioBlob(size: Int, seed: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    var block = "<\(seed):\(size)>"
    var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
    for _ in 0..<61 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        block.append(alphabet[Int(state >> 58)])
    }
    let blockBytes = block.utf8.count
    var text = String(repeating: block, count: size / blockBytes + 1)
    text.removeLast(text.utf8.count - size)
    return text
}

func independentStdioDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct IndependentStdioRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x2545_F491_4F6C_DD1D &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(Swift.max(1, bound))) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

// MARK: - Fixture server

struct IndependentStdioFixture {
    let server: Server
    let probe: IndependentStdioProbe
    let log: IndependentStdioLog
}

/// A server with the tools the tests need. Diagnostics are collected, never printed.
func independentStdioFixture(configure: (inout ServerConfiguration) -> Void = { _ in }) throws -> IndependentStdioFixture {
    let probe = IndependentStdioProbe()
    let log = IndependentStdioLog()
    let server = Server(name: "independent-stdio", version: "1.0.0") { configuration in
        configuration.diagnostics = { log.add($0) }
        configure(&configuration)
    }
    let anyObject: JSONObject = ["type": "object"]
    try server.register(tool: ToolDefinition(name: "echo", inputSchema: anyObject)) { arguments, _ in
        .text(arguments["text"]?.stringValue ?? "")
    }
    try server.register(tool: ToolDefinition(name: "length", inputSchema: anyObject)) { arguments, _ in
        .text("\(arguments["text"]?.stringValue?.utf8.count ?? -1)")
    }
    // A response of a chosen size.
    try server.register(tool: ToolDefinition(name: "blob", inputSchema: anyObject)) { arguments, _ in
        let size = arguments["size"]?.intValue ?? 0
        let seed = arguments["seed"]?.intValue ?? 0
        probe.started("blob-\(seed)")
        if let delay = arguments["delayMs"]?.intValue, delay > 0 {
            try await Task.sleep(for: .milliseconds(delay))
        }
        probe.finished("blob-\(seed)")
        return .text(independentStdioBlob(size: size, seed: seed))
    }
    // Runs until the test releases it or the request is cancelled.
    try server.register(tool: ToolDefinition(name: "hold", inputSchema: anyObject)) { arguments, _ in
        let tag = arguments["tag"]?.stringValue ?? "?"
        probe.started(tag)
        do {
            while !probe.isReleased { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            probe.cancelled(tag)
            throw error
        }
        probe.finished(tag)
        return .text("released \(tag)")
    }
    // Sleeps, then answers.
    try server.register(tool: ToolDefinition(name: "nap", inputSchema: anyObject)) { arguments, _ in
        let tag = arguments["tag"]?.stringValue ?? "?"
        probe.started(tag)
        do {
            try await Task.sleep(for: .milliseconds(arguments["ms"]?.intValue ?? 0))
        } catch {
            probe.cancelled(tag)
            throw error
        }
        probe.finished(tag)
        return .text("woke \(tag)")
    }
    // Runs for `ms` milliseconds whatever happens: ignores cancellation (records it, though).
    try server.register(tool: ToolDefinition(name: "stubborn", inputSchema: anyObject)) { arguments, _ in
        let tag = arguments["tag"]?.stringValue ?? "?"
        probe.started(tag)
        let end = ContinuousClock.now + .milliseconds(arguments["ms"]?.intValue ?? 0)
        do {
            try await Task.sleep(until: end, clock: .continuous)
        } catch {
            probe.cancelled(tag)
            // Keep the handler active until its original deadline without occupying a
            // cooperative executor thread that the transport needs for the grace timer.
            await Task.detached {
                try? await Task.sleep(until: end, clock: .continuous)
            }.value
        }
        probe.finished(tag)
        return .text("stubborn \(tag)")
    }
    // Emits log notifications, then holds.
    try server.register(tool: ToolDefinition(name: "chatty", inputSchema: anyObject)) { arguments, context in
        let tag = arguments["tag"]?.stringValue ?? "?"
        let count = arguments["count"]?.intValue ?? 0
        let padding = String(repeating: "x", count: arguments["size"]?.intValue ?? 0)
        probe.started(tag)
        for index in 0..<count {
            context.log(.error, .string("chatty-\(tag)-\(index) \(padding)"))
        }
        probe.finished("logged-\(tag)")
        do {
            while !probe.isReleased { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            probe.cancelled(tag)
            throw error
        }
        return .text("released \(tag)")
    }
    return IndependentStdioFixture(server: server, probe: probe, log: log)
}

// MARK: - File descriptors

#if canImport(Darwin)
let independentStdioStreamSocket = SOCK_STREAM
#elseif canImport(Glibc)
let independentStdioStreamSocket = Int32(SOCK_STREAM.rawValue)
#endif

struct IndependentStdioDescriptorState: Equatable, CustomStringConvertible {
    var statusFlags: Int32
    var descriptorFlags: Int32
    var device: UInt64
    var inode: UInt64

    init?(_ descriptor: Int32) {
        let status = fcntl(descriptor, F_GETFL)
        let flags = fcntl(descriptor, F_GETFD)
        var info = stat()
        guard status != -1, flags != -1, fstat(descriptor, &info) == 0 else { return nil }
        #if canImport(Darwin)
        // Darwin reports a kernel bookkeeping bit through F_GETFL, FWASWRITTEN (0x10000, XNU
        // bsd/sys/fcntl.h), which the kernel sets by itself on the first write to the open
        // file. It is not a flag anyone can set with fcntl, so it is left out of the comparison.
        statusFlags = status & ~0x10000
        #else
        statusFlags = status
        #endif
        descriptorFlags = flags
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
    }

    var isNonBlocking: Bool { statusFlags & O_NONBLOCK != 0 }
    var description: String { "F_GETFL=0x\(String(statusFlags, radix: 16)) F_GETFD=\(descriptorFlags) dev=\(device) ino=\(inode)" }
}

func independentStdioSetNonBlocking(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
}

/// Number of open file descriptors in this process.
func independentStdioOpenDescriptorCount() -> Int {
    var count = 0
    for descriptor in 0..<Int32(Swift.min(Int(getdtablesize()), 65536)) where fcntl(descriptor, F_GETFD) != -1 {
        count += 1
    }
    return count
}

// MARK: - Threads

#if canImport(Darwin)

struct IndependentStdioThread: Equatable {
    var id: UInt64
    var name: String
    /// User plus system CPU time, in seconds.
    var cpuSeconds: Double
}

/// The transport's threads alive in this process (they are named `limb-stdio-reader` and
/// `limb-stdio-writer`), with the CPU time each has used.
func independentStdioTransportThreads() -> [IndependentStdioThread] {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
    defer {
        vm_deallocate(
            mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
    }
    var threads: [IndependentStdioThread] = []
    for index in 0..<Int(count) {
        let port = list[index]
        defer { mach_port_deallocate(mach_task_self_, port) }

        var extended = thread_extended_info()
        var extendedCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
        let gotExtended = withUnsafeMutablePointer(to: &extended) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
            }
        }
        guard gotExtended == KERN_SUCCESS else { continue }
        let name = withUnsafeBytes(of: &extended.pth_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard name.hasPrefix("limb-stdio-") else { continue }

        var identifier = thread_identifier_info()
        var identifierCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size)
        let gotIdentifier = withUnsafeMutablePointer(to: &identifier) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
            }
        }
        guard gotIdentifier == KERN_SUCCESS else { continue }
        let cpu = Double(extended.pth_user_time + extended.pth_system_time) / 1_000_000_000
        threads.append(IndependentStdioThread(id: identifier.thread_id, name: name, cpuSeconds: cpu))
    }
    return threads
}

/// The reader and writer threads of a session started after `before` was sampled.
///
/// Another suite of this target may run a session of its own at the same moment; its threads
/// come and go within milliseconds, so the sample is repeated until exactly one reader and one
/// writer remain.
func independentStdioSessionThreads(startedAfter before: Set<UInt64>, seconds: Double = 5) -> [IndependentStdioThread] {
    let deadline = Date().addingTimeInterval(seconds)
    var fresh: [IndependentStdioThread] = []
    while true {
        fresh = independentStdioTransportThreads().filter { !before.contains($0.id) }
        if fresh.map(\.name).sorted() == ["limb-stdio-reader", "limb-stdio-writer"] || Date() >= deadline { return fresh }
        usleep(20_000)
    }
}

func independentStdioCPUSeconds(of ids: Set<UInt64>) -> Double {
    independentStdioTransportThreads().filter { ids.contains($0.id) }.reduce(0) { $0 + $1.cpuSeconds }
}

/// Counts signals as they are handled, per process. Install with `independentStdioCountSIGUSR1()`.
let independentStdioHandledSignals = Atomic<Int>(0)

/// Installs a SIGUSR1 handler that counts and does nothing else, without SA_RESTART, so that
/// `read`, `write` and `poll` on the signalled thread return early. The handler stays installed.
func independentStdioCountSIGUSR1() {
    var action = sigaction()
    action.__sigaction_u.__sa_handler = { _ in independentStdioHandledSignals.add(1, ordering: .relaxed) }
    action.sa_flags = 0
    sigemptyset(&action.sa_mask)
    sigaction(SIGUSR1, &action, nil)
}

/// Sends `signal` to every thread of this process whose id is in `ids`. Returns how many it reached.
func independentStdioSignalThreads(ids: Set<UInt64>, signal: Int32) -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
    defer {
        vm_deallocate(
            mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
    }
    var reached = 0
    for index in 0..<Int(count) {
        let port = list[index]
        defer { mach_port_deallocate(mach_task_self_, port) }
        var identifier = thread_identifier_info()
        var identifierCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &identifier) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
            }
        }
        guard got == KERN_SUCCESS, ids.contains(identifier.thread_id), let thread = pthread_from_mach_thread_np(port) else { continue }
        if pthread_kill(thread, signal) == 0 { reached += 1 }
    }
    return reached
}

#endif

// MARK: - The client's end of a session

/// Drives one `Server.run(_:)` over file descriptors from the client's side.
///
/// Not thread-safe: one test drives it. Every blocking step has a deadline, and the test never
/// awaits `run` directly, so a server that hangs fails the test instead of stalling the suite.
final class IndependentStdioClient: @unchecked Sendable {
    /// The descriptors given to the transport.
    let serverInput: Int32
    let serverOutput: Int32
    /// The client's ends; -1 when the test wired that direction itself.
    private(set) var writeEnd: Int32
    private(set) var readEnd: Int32

    private var pending: [UInt8] = []
    private var scanned = 0
    private(set) var sawEndOfOutput = false
    /// Lines that are not a single valid JSON-RPC message, with the reason.
    private(set) var violations: [String] = []
    private(set) var linesRead = 0
    private(set) var bytesRead = 0

    private let returned = Mutex<ContinuousClock.Instant?>(nil)
    private var task: Task<Void, Never>?
    private let server: Server
    private var closedServerEnds = false

    enum Channel {
        case pipes
        /// One socket as both stdin and stdout, as Node hands it to a child process.
        case socketpair
    }

    /// Creates the descriptors but does not start the server yet.
    init(_ server: Server, channel: Channel = .pipes) {
        self.server = server
        switch channel {
        case .pipes:
            var toServer: [Int32] = [-1, -1]
            var fromServer: [Int32] = [-1, -1]
            precondition(pipe(&toServer) == 0 && pipe(&fromServer) == 0)
            serverInput = toServer[0]
            serverOutput = fromServer[1]
            writeEnd = toServer[1]
            readEnd = fromServer[0]
        case .socketpair:
            var sockets: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, independentStdioStreamSocket, 0, &sockets) == 0)
            serverInput = sockets[1]
            serverOutput = sockets[1]
            writeEnd = sockets[0]
            readEnd = sockets[0]
        }
        independentStdioSetNonBlocking(writeEnd)
        if readEnd != writeEnd { independentStdioSetNonBlocking(readEnd) }
    }

    /// Wraps descriptors the test made itself. Pass -1 for a client end that does not exist.
    init(_ server: Server, serverInput: Int32, serverOutput: Int32, writeEnd: Int32, readEnd: Int32) {
        self.server = server
        self.serverInput = serverInput
        self.serverOutput = serverOutput
        self.writeEnd = writeEnd
        self.readEnd = readEnd
        if writeEnd >= 0 { independentStdioSetNonBlocking(writeEnd) }
        if readEnd >= 0, readEnd != writeEnd { independentStdioSetNonBlocking(readEnd) }
    }

    /// `signals: true` lets SIGUSR1 reach the transport's threads. A thread inherits the signal
    /// mask of the thread that creates it, and the threads of Swift's cooperative pool, which
    /// run this task, block SIGUSR1 — so without this a signal sent to a transport thread stays
    /// pending for ever and interrupts nothing. (A server that calls `run` from its `main` has
    /// the main thread's open mask, so there signals do arrive.) `run` reaches the creation of
    /// its threads without suspending, that is on the thread that unblocked the signal.
    @discardableResult
    func start(signals: Bool = false) -> Self {
        let transport = StdioTransport(input: serverInput, output: serverOutput)
        task = Task { [server, self] in
            if signals {
                var set = sigset_t()
                sigemptyset(&set)
                sigaddset(&set, SIGUSR1)
                pthread_sigmask(SIG_UNBLOCK, &set, nil)
            }
            await server.run(transport)
            self.returned.withLock { $0 = ContinuousClock.now }
        }
        return self
    }

    static func started(_ server: Server, channel: Channel = .pipes) -> IndependentStdioClient {
        IndependentStdioClient(server, channel: channel).start()
    }

    /// Started, and through the `initialize` handshake of a legacy revision.
    static func ready(_ server: Server, channel: Channel = .pipes, version: String = "2025-11-25") -> IndependentStdioClient {
        let client = started(server, channel: channel)
        let negotiated = client.initialize(version: version)
        #expect(negotiated == version, "the handshake did not complete")
        return client
    }

    func cancelRun() { task?.cancel() }

    // MARK: Sending

    /// Writes all of `bytes` to the server's input. While the input is full it keeps taking the
    /// server's output (unless `absorb` is false), so a single-threaded test cannot deadlock.
    @discardableResult
    func send(_ bytes: [UInt8], timeout: Double = 30, absorb: Bool = true) -> Bool {
        guard writeEnd >= 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress! + offset, bytes.count - offset) }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            guard written < 0, errno == EAGAIN else { return false }
            if Date() >= deadline { return false }
            var descriptors = [pollfd(fd: writeEnd, events: Int16(POLLOUT), revents: 0)]
            if absorb, readEnd >= 0, !sawEndOfOutput {
                descriptors.append(pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0))
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
            if descriptors.count == 2, descriptors[1].revents != 0 { fill() }
            if readEnd == writeEnd, absorb, descriptors[0].revents & Int16(POLLIN) != 0 { fill() }
        }
        return true
    }

    @discardableResult
    func send(_ text: String, timeout: Double = 30, absorb: Bool = true) -> Bool {
        send(Array(text.utf8), timeout: timeout, absorb: absorb)
    }

    static func requestLine(_ id: Int, _ method: String, _ params: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"# + "\n"
    }

    static func callLine(_ id: Int, _ tool: String, _ arguments: String = "{}") -> String {
        requestLine(id, "tools/call", #"{"name":"\#(tool)","arguments":\#(arguments)}"#)
    }

    static func cancelLine(_ id: Int) -> String {
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"# + "\n"
    }

    @discardableResult
    func request(_ id: Int, _ method: String, _ params: String = "{}") -> Bool {
        send(Self.requestLine(id, method, params))
    }

    @discardableResult
    func call(_ id: Int, _ tool: String, _ arguments: String = "{}") -> Bool {
        send(Self.callLine(id, tool, arguments))
    }

    @discardableResult
    func cancel(_ id: Int) -> Bool { send(Self.cancelLine(id)) }

    /// The `initialize` handshake of a legacy revision. Returns the negotiated version.
    @discardableResult
    func initialize(version: String = "2025-11-25") -> String? {
        request(0, "initialize", #"{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"independent","version":"1"}}"#)
        let response = readMessage()
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n")
        return (response?["result"] as? [String: Any])?["protocolVersion"] as? String
    }

    // MARK: Receiving

    /// Reads whatever is available right now into the buffer. Returns the number of bytes.
    @discardableResult
    private func fill(limit: Int = 65536) -> Int {
        guard readEnd >= 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = read(readEnd, &buffer, limit)
        if count > 0 {
            pending.append(contentsOf: buffer[..<count])
            bytesRead += count
            return count
        }
        if count == 0 { sawEndOfOutput = true }
        return 0
    }

    /// Takes up to `limit` bytes of the server's output if any are waiting; never blocks.
    /// The bytes are kept for `readLine`.
    @discardableResult
    func absorb(limit: Int) -> Int {
        guard readEnd >= 0, !sawEndOfOutput, limit > 0 else { return 0 }
        var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return 0 }
        return fill(limit: limit)
    }

    /// The next line of the server's output without its newline; `nil` on timeout or end of output.
    /// `chunk` limits how much is read at a time (a slow reader).
    func readLine(timeout: Double = 20, chunk: Int = 65536) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = pending[scanned...].firstIndex(of: 0x0A) {
                let line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                scanned = 0
                linesRead += 1
                validate(line)
                return line
            }
            scanned = pending.count
            if sawEndOfOutput || readEnd < 0 { return nil }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(Swift.min(remaining * 1000 + 1, 100)))
            if ready > 0 { fill(limit: chunk) }
        }
    }

    /// The specification: "The server MUST NOT write anything to its stdout that is not a
    /// valid MCP message" and "Messages are delimited by newlines, and MUST NOT contain
    /// embedded newlines". Checked for every line any test reads, with Foundation's parser
    /// rather than Limb's own.
    private func validate(_ line: [UInt8]) {
        func note(_ reason: String) {
            let shown = String(decoding: line.prefix(120), as: UTF8.self)
            violations.append("\(reason): \(shown)")
        }
        guard String(validating: line, as: UTF8.self) != nil else { return note("not valid UTF-8") }
        if line.contains(0x0D) { return note("contains a carriage return") }
        if line.contains(0x00) { return note("contains a zero byte") }
        guard let value = try? JSONSerialization.jsonObject(with: Data(line)) else { return note("not valid JSON") }
        let messages: [Any] = (value as? [Any]) ?? [value]
        if messages.isEmpty { return note("an empty batch") }
        for message in messages {
            guard let object = message as? [String: Any] else { return note("not a JSON object") }
            guard object["jsonrpc"] as? String == "2.0" else { return note("no jsonrpc 2.0 member") }
            let isResponse = object["id"] != nil && (object["result"] != nil) != (object["error"] != nil) && object["method"] == nil
            let isNotification = object["method"] is String && object["id"] == nil
            let isRequest = object["method"] is String && object["id"] != nil
            if !(isResponse || isNotification || isRequest) { return note("not a JSON-RPC message") }
        }
    }

    func readMessage(timeout: Double = 20, chunk: Int = 65536) -> [String: Any]? {
        guard let line = readLine(timeout: timeout, chunk: chunk) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    static func id(of message: [String: Any]?) -> Int? { (message?["id"] as? NSNumber)?.intValue }

    static func text(of message: [String: Any]?) -> String? {
        let content = (message?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String
    }

    static func errorCode(of message: [String: Any]?) -> Int? {
        ((message?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue
    }

    static func isNullID(_ message: [String: Any]?) -> Bool { message?["id"] is NSNull }

    /// Reads until every id in `ids` has a response, or the time is up. Other messages go to
    /// `others`. A second response to the same id is recorded as a violation.
    func responses(to ids: Set<Int>, timeout: Double = 30, chunk: Int = 65536, others: (([String: Any]) -> Void)? = nil) -> [Int: [String: Any]] {
        var found: [Int: [String: Any]] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        while found.count < ids.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let message = readMessage(timeout: remaining, chunk: chunk) else { break }
            if message["method"] == nil, let id = Self.id(of: message), ids.contains(id) {
                if found[id] != nil { violations.append("request \(id) was answered twice") }
                found[id] = message
            } else {
                others?(message)
            }
        }
        return found
    }

    /// Everything the server writes during `seconds`, or until its output ends.
    func drain(seconds: Double) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let message = readMessage(timeout: remaining) else { break }
            messages.append(message)
        }
        return messages
    }

    /// Whether the server's output has bytes waiting, without consuming them.
    func outputReadable(within seconds: Double) -> Bool {
        if pending.count > scanned { return true }
        guard readEnd >= 0 else { return false }
        var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, Int32(seconds * 1000)) > 0 && descriptor.revents & Int16(POLLIN) != 0
    }

    // MARK: Closing

    /// The shutdown signal of the specification: the client closes the server's input.
    func closeInput() {
        guard writeEnd >= 0 else { return }
        if writeEnd == readEnd {
            shutdown(writeEnd, Int32(SHUT_WR))
        } else {
            close(writeEnd)
            writeEnd = -1
        }
    }

    /// The client goes away without reading: the server's writes fail with EPIPE.
    ///
    /// With one socket for both directions the client closes the socket (a `shutdown(SHUT_RD)`
    /// on Darwin does not make the peer's writes fail), so the server sees the end of its input
    /// as well.
    func closeOutput() {
        guard readEnd >= 0 else { return }
        close(readEnd)
        if writeEnd == readEnd { writeEnd = -1 }
        readEnd = -1
    }

    var hasReturned: Bool { returned.withLock { $0 != nil } }

    /// The server's descriptors are handed over to the test (it replaces or closes them
    /// itself): `tearDown` then leaves them alone.
    func disownServerEnds() { closedServerEnds = true }

    /// Whether `run` returned within the time limit.
    func stopped(within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if hasReturned { return true }
            usleep(2000)
        }
        return hasReturned
    }

    /// Ends the session whatever state it is in: closes the client's ends, waits for `run`,
    /// then closes the server's descriptors. Returns `false` if `run` never returned, in which
    /// case the server's descriptors stay open (closing them under a running transport would
    /// only add noise).
    @discardableResult
    func tearDown(wait seconds: Double = 20) -> Bool {
        if writeEnd >= 0 {
            close(writeEnd)
            if readEnd == writeEnd { readEnd = -1 }
            writeEnd = -1
        }
        if readEnd >= 0 {
            close(readEnd)
            readEnd = -1
        }
        task?.cancel()
        let done = task == nil || stopped(within: seconds)
        if done, !closedServerEnds {
            closedServerEnds = true
            close(serverInput)
            if serverOutput != serverInput { close(serverOutput) }
        }
        return done
    }
}
