import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

/// The client's end of a pipe pair to an in-process `Server.run`, driven with blocking calls
/// so it can be used from a plain thread.
private final class PipePeer: @unchecked Sendable {
    let writeEnd: Int32
    let readEnd: Int32
    private var pending: [UInt8] = []
    private var scanned = 0
    private var readClosed = false
    let stopped = ICBox(false)

    init(_ server: Server) {
        signal(SIGPIPE, SIG_IGN)
        var toServer: [Int32] = [0, 0]
        var fromServer: [Int32] = [0, 0]
        precondition(pipe(&toServer) == 0 && pipe(&fromServer) == 0)
        writeEnd = toServer[1]
        readEnd = fromServer[0]
        let transport = StdioTransport(input: toServer[0], output: fromServer[1])
        let stopped = stopped
        Task.detached {
            await server.run(transport)
            close(transport.input)
            close(transport.output)
            stopped.set(true)
        }
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress! + offset, bytes.count - offset) }
            guard written > 0 else { return }
            offset += written
        }
    }

    func request(_ id: String, _ method: String, _ body: String = "", progressToken: String? = nil) {
        var meta = modernMeta
        if let progressToken { meta = String(meta.dropLast()) + #","progressToken":\#(progressToken)}"# }
        let params = body.isEmpty ? "{\(meta)}" : "{\(body),\(meta)}"
        send(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"# + "\n")
    }

    func cancel(_ id: String) {
        send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"# + "\n")
    }

    /// The next line without its terminator; `nil` on end of stream or timeout.
    func readLine(timeoutMilliseconds: Int32 = 10_000, chunk: Int = 65536) -> [UInt8]? {
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

    func readMessage(timeoutMilliseconds: Int32 = 10_000) -> JSONValue? {
        readLine(timeoutMilliseconds: timeoutMilliseconds).flatMap { try? JSON.parse($0) }
    }

    func closeInput() { close(writeEnd) }

    /// Stops reading for good: pending writes of the server fail with EPIPE.
    func closeOutput() {
        guard !readClosed else { return }
        readClosed = true
        close(readEnd)
    }

    func serverStopped(within seconds: Double) async -> Bool {
        let stopped = stopped
        return await independentConcurrencyEventually(timeout: .milliseconds(Int(seconds * 1000))) { stopped.value }
    }
}

/// Blocks the calling thread. A plain function, so it may be called from a handler: this is
/// exactly the misbehaviour under test.
private func blockThread(on semaphore: DispatchSemaphore) { semaphore.wait() }

@Suite(.timeLimit(.minutes(5)))
struct IndependentConcurrencyStdioTests {
    /// §11.3: "Блокирующих обработчиков не меньше, чем ядер — отмена и `server/discover` отвечают,
    /// пока все обработчики заблокированы".
    @Test func discoveryAndCancellationAnswerWhileEveryCoreIsBlockedByAHandler() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let calls = cores + 3
        let blocked = ICMeter()
        let release = DispatchSemaphore(value: 0)
        let sawCancellation = ICBox<[String: Bool]>([:])
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = calls
        }
        try server.register(tool: ToolDefinition(name: "block")) { _, context in
            blocked.enter()
            blockThread(on: release)
            let cancelled = Task.isCancelled
            sawCancellation.update { $0[context.requestID.description] = cancelled }
            return .text("unblocked")
        }
        let peer = PipePeer(server)

        struct Report: Sendable {
            var blocked = 0
            var discover: JSONValue?
            var list: JSONValue?
            var afterCancel: JSONValue?
            var answered: Set<Int> = []
            var extra: [JSONValue] = []
        }
        // Everything below runs on a plain thread: while the handlers block, no task can run,
        // this test's own included. The thread always releases the handlers before it reports.
        let report: Report = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var report = Report()
                for index in 0..<calls { peer.request("\(index)", "tools/call", #""name":"block""#) }
                // Not long: while this waits, the threads already blocked are lost to every other test.
                let deadline = Date().addingTimeInterval(4)
                while blocked.total < cores, Date() < deadline { usleep(1000) }
                report.blocked = blocked.total
                peer.request("1000", "server/discover")
                report.discover = peer.readMessage(timeoutMilliseconds: 5000)
                peer.request("1001", "tools/list")
                report.list = peer.readMessage(timeoutMilliseconds: 5000)
                peer.cancel("0")
                peer.request("1002", "server/discover")
                report.afterCancel = peer.readMessage(timeoutMilliseconds: 5000)
                for _ in 0..<(calls * 2) { release.signal() }
                while report.answered.count < calls - 1, let message = peer.readMessage(timeoutMilliseconds: 10_000) {
                    if let id = message["id"]?.intValue, id < calls { report.answered.insert(id) } else { report.extra.append(message) }
                }
                while let message = peer.readMessage(timeoutMilliseconds: 200) { report.extra.append(message) }
                continuation.resume(returning: report)
            }
        }
        // A precondition, not a property of Limb: other tests' CPU-bound work can keep a thread busy.
        #expect(report.blocked >= cores, "inconclusive: only \(report.blocked) handlers got to block \(cores) cores within 4 s")
        #expect(report.discover?["id"] == 1000, "server/discover was not answered while every core was blocked")
        #expect(report.discover?["result"]?["supportedVersions"] != nil)
        #expect(report.list?["id"] == 1001, "tools/list was not answered while every core was blocked")
        #expect(report.afterCancel?["id"] == 1002)
        // The cancellation was processed while the handlers were blocked: request 0 is never
        // answered, and its handler saw the cancellation when it woke up.
        #expect(report.answered == Set(1..<calls))
        #expect(report.extra.isEmpty, "unexpected frames: \(report.extra)")
        #expect(sawCancellation.value["0"] == true)
        #expect(sawCancellation.value.filter { $0.key != "0" }.allSatisfy { $0.value == false })
        peer.closeInput()
        #expect(await peer.serverStopped(within: 20))
    }

    // MARK: Frame size

    @Test func frameLimitAtTheExactBoundaryOverTheWire() async throws {
        let limit = 2048
        let server = independentConcurrencyServer { $0.budgets.maxFrameBytes = limit }
        try server.register(tool: ToolDefinition(name: "size")) { arguments, _ in
            .text("\(arguments["pad"]?.stringValue?.utf8.count ?? -1)")
        }
        @Sendable func frame(id: Int, size: Int) -> String {
            let head = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"size","arguments":{"pad":""#
            let tail = #""},\#(modernMeta)}}"#
            return head + String(repeating: "x", count: size - head.utf8.count - tail.utf8.count) + tail
        }
        let peer = PipePeer(server)
        let outcome: [JSONValue?] = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var messages: [JSONValue?] = []
                peer.send(frame(id: 1, size: limit - 1) + "\n")
                messages.append(peer.readMessage())
                peer.send(frame(id: 2, size: limit) + "\n")  // exactly the limit
                messages.append(peer.readMessage())
                peer.send(frame(id: 3, size: limit) + "\r\n")  // the terminator is not part of the frame
                messages.append(peer.readMessage())
                peer.send(frame(id: 4, size: limit + 1) + "\n")  // one byte over
                messages.append(peer.readMessage())
                peer.send(frame(id: 5, size: 400) + "\n")  // the stream recovers
                messages.append(peer.readMessage())
                peer.send(frame(id: 6, size: limit + 1) + "\n")  // the second time is not an accident
                messages.append(peer.readMessage())
                continuation.resume(returning: messages)
            }
        }
        #expect(outcome[0]?["id"] == 1)
        #expect(outcome[1]?["id"] == 2, "a frame of exactly maxFrameBytes was not served: \(String(describing: outcome[1]))")
        #expect(outcome[1]?["result"]?["content"]?[0]?["text"] != nil)
        #expect(outcome[2]?["id"] == 3, "a frame of exactly maxFrameBytes followed by CRLF was not served")
        #expect(outcome[3]?["error"]?["code"] == -32600)
        #expect(outcome[3]?["id"] == .null)
        #expect(outcome[4]?["id"] == 5)
        #expect(outcome[5]?["error"]?["code"] == -32600)
        // "закрытие при повторе".
        #expect(await peer.serverStopped(within: 20))
    }

    @Test func lineFramerHonoursTheLimitHoweverTheBytesArrive() {
        let limit = 5000
        func line(_ count: Int, _ byte: UInt8) -> [UInt8] { [UInt8](repeating: byte, count: count) + [0x0A] }
        var stream: [UInt8] = []
        stream += line(limit - 1, 0x61)
        stream += line(limit, 0x62)
        stream += [UInt8](repeating: 0x63, count: limit - 1) + [0x0D, 0x0A]
        stream += line(limit + 1, 0x64)
        stream += line(3, 0x65)
        stream += line(limit * 3, 0x66)
        stream += line(limit, 0x67)
        stream += [0x0A, 0x0D, 0x0A]  // blank lines are skipped
        stream += line(1, 0x68)
        let expected = ["a\(limit - 1)", "b\(limit)", "c\(limit - 1)", "oversized", "e3", "oversized", "g\(limit)", "h1"]
        for chunk in [1, 2, 7, 4095, 4096, 4097, limit, limit + 1, stream.count] {
            var framer = LineFramer(maxFrameBytes: limit)
            var events: [String] = []
            var offset = 0
            func drain() {
                while let event = framer.next() {
                    switch event {
                    case .frame(let range):
                        let bytes = framer.buffer[range]
                        let uniform = bytes.allSatisfy { $0 == bytes.first }
                        events.append(uniform ? "\(Character(UnicodeScalar(bytes.first ?? 0x3F)))\(bytes.count)" : "mixed")
                    case .oversized: events.append("oversized")
                    }
                }
            }
            while offset < stream.count {
                let slice = stream[offset..<min(offset + chunk, stream.count)]
                var taken = 0
                while taken < slice.count {
                    let accepted = framer.append(slice.dropFirst(taken))
                    taken += accepted
                    drain()
                    if accepted == 0 && taken < slice.count {
                        // `append` takes nothing while frames are waiting; they were just drained.
                        let retry = framer.append(slice.dropFirst(taken))
                        if retry == 0 { break }
                        taken += retry
                        drain()
                    }
                }
                #expect(taken == slice.count, "the framer stopped accepting input (chunk \(chunk), offset \(offset))")
                if taken != slice.count { break }
                offset += slice.count
            }
            #expect(events == expected, "chunks of \(chunk) bytes")
            #expect(!framer.hasPartialFrame)
        }
    }

    @Test func aFrameOfExactlyTheLimitEndingInCRLFIsAcceptedWhereverTheStreamIsSplit() {
        let limit = 5000
        let frame = [UInt8](repeating: 0x63, count: limit)
        for split in [limit - 1, limit, limit + 1, limit + 2] {
            let stream = frame + [0x0D, 0x0A]
            var framer = LineFramer(maxFrameBytes: limit, initialCapacity: 64 * 1024)
            var events: [String] = []
            for part in [stream[..<split], stream[split...]] where !part.isEmpty {
                var taken = 0
                while taken < part.count {
                    let accepted = framer.append(part.dropFirst(taken))
                    taken += accepted
                    while let event = framer.next() {
                        switch event {
                        case .frame(let range): events.append("frame of \(range.count)")
                        case .oversized: events.append("oversized")
                        }
                    }
                    if accepted == 0 { break }
                }
            }
            #expect(events == ["frame of \(limit)"], "stream split after \(split) bytes")
        }
    }

    // MARK: A peer that does not read

    private func blobServer(
        cancelledSeen: ICMeter, started: ICMeter, diagnostics: ICBox<[String]>,
        configure: (inout ServerConfiguration) -> Void = { _ in }
    ) throws -> Server {
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxOutboundBytes = 64 * 1024
            configuration.shutdownGraceSeconds = 0.2
            configuration.diagnostics = { line in diagnostics.update { $0.append(line) } }
            configure(&configuration)
        }
        try server.register(tool: ToolDefinition(name: "blob")) { _, _ in .text(String(repeating: "b", count: 300_000)) }
        try server.register(tool: ToolDefinition(name: "sleepy")) { _, _ in
            started.enter()
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                cancelledSeen.enter()
                throw error
            }
            return .text("woke")
        }
        return server
    }

    /// §11.3 "Клиент не читает stdout": "читатель не блокируется, отмены обрабатываются", and
    /// "EOF на stdin при нечитающем клиенте — процесс выходит по дедлайну дозаписи" (§6.1: the
    /// deadline is 5 seconds by default).
    @Test func aPeerThatNeverReadsStillGetsItsCancellationsProcessedAndTheServerStopsAtEndOfInput() async throws {
        let cancelledSeen = ICMeter()
        let started = ICMeter()
        let peer = PipePeer(try blobServer(cancelledSeen: cancelledSeen, started: started, diagnostics: ICBox([])))
        // Responses far larger than the pipe buffer and the outbound budget; nobody reads them.
        for index in 0..<8 { peer.request("\(index)", "tools/call", #""name":"blob""#) }
        try await Task.sleep(for: .milliseconds(300))
        // The writer is stuck in `write`. The reader must still take requests and cancellations.
        peer.request("100", "tools/call", #""name":"sleepy""#)
        #expect(await independentConcurrencyEventually { started.total == 1 }, "the reader stopped taking requests")
        peer.cancel("100")
        #expect(await independentConcurrencyEventually { cancelledSeen.total == 1 }, "a cancellation was not processed while the writer was blocked")

        peer.closeInput()
        let stopped = await peer.serverStopped(within: 20)
        #expect(stopped, "Server.run did not return within 20 s of end of input: the writer has no deadline")
        // Let the stuck writer go, whatever happened.
        peer.closeOutput()
        if !stopped { _ = await peer.serverStopped(within: 10) }
    }

    /// §6.1: when the reserve is exhausted too, "соединение закрывается с записью в журнал".
    @Test func aPeerThatNeverReadsIsDroppedOnceTheReserveIsExhausted() async throws {
        let diagnostics = ICBox<[String]>([])
        let peer = PipePeer(try blobServer(cancelledSeen: ICMeter(), started: ICMeter(), diagnostics: diagnostics))
        // Each bad line costs the server an error reply of about a hundred bytes; the pipe takes
        // 64 KiB, the queue's budget another 64 KiB, the reserve 1 MiB.
        let flood = Thread {
            let line = "{not json\n"
            let block = String(repeating: line, count: 2000)
            for _ in 0..<20 {
                peer.send(block)
                if diagnostics.value.contains(where: { $0.contains("not reading") }) { break }
            }
        }
        flood.start()
        #expect(
            await independentConcurrencyEventually(timeout: .seconds(30)) {
                diagnostics.value.contains { $0.contains("not reading") }
            }, "the server never gave up on a peer that does not read; diagnostics: \(diagnostics.value)")
        let stopped = await peer.serverStopped(within: 20)
        #expect(stopped, "Server.run did not return within 20 s of dropping the connection")
        peer.closeOutput()
        if !stopped { _ = await peer.serverStopped(within: 10) }
    }

    // MARK: Stress over real pipes

    @Test func framesStayWholeAndAnsweredOnceOverPipesWithASlowReader() async throws {
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 16
            configuration.budgets.maxQueuedRequests = 10_000
            configuration.budgets.maxOutboundBytes = 256 * 1024
        }
        try server.register(tool: ToolDefinition(name: "payload")) { arguments, context in
            let index = arguments["n"]?.intValue ?? 0
            context.progress(1, total: 2, message: "half \(index)")
            if index % 3 == 0 { await Task.yield() }
            let size = [10, 500, 5_000, 40_000, 120_000][index % 5]
            // Characters that need escaping, so a torn frame cannot go unnoticed.
            return .text("#\(index):" + String(repeating: "é\n\"\\", count: size / 5))
        }
        let peer = PipePeer(server)
        let total = 1500
        struct Outcome: Sendable {
            var responses: [Int: Int] = [:]
            var badLines = 0
            var wrongText = 0
            var lines = 0
        }
        let cancelled = ICBox<Set<Int>>([])
        let writerDone = ICBox(false)
        let writer = Thread {
            defer { writerDone.set(true) }
            for index in 0..<total {
                peer.request("\(index)", "tools/call", #""name":"payload","arguments":{"n":\#(index)}"#, progressToken: "\(index)")
                if index % 7 == 3 {
                    peer.cancel("\(index)")
                    cancelled.update { _ = $0.insert(index) }
                }
            }
        }
        writer.start()
        let outcome: Outcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var outcome = Outcome()
                var quietRounds = 0
                while quietRounds < 2 {
                    let expected = total - cancelled.value.count
                    let answered = outcome.responses.keys.filter { !cancelled.value.contains($0) }.count
                    if writerDone.value, answered >= expected { quietRounds += 1 }
                    guard let line = peer.readLine(timeoutMilliseconds: quietRounds > 0 ? 300 : 20_000, chunk: [7, 513, 4096, 65536][outcome.lines % 4]) else {
                        if quietRounds > 0 { continue }
                        break
                    }
                    outcome.lines += 1
                    if outcome.lines % 50 == 0 { usleep(2000) }
                    guard let message = try? JSON.parse(line) else {
                        outcome.badLines += 1
                        continue
                    }
                    guard let id = message["id"]?.intValue else { continue }
                    outcome.responses[id, default: 0] += 1
                    let text = message["result"]?["content"]?[0]?["text"]?.stringValue ?? ""
                    let size = [10, 500, 5_000, 40_000, 120_000][id % 5]
                    if text != "#\(id):" + String(repeating: "é\n\"\\", count: size / 5) { outcome.wrongText += 1 }
                }
                continuation.resume(returning: outcome)
            }
        }
        let cancelledIDs = cancelled.value
        #expect(outcome.badLines == 0, "\(outcome.badLines) lines were not whole JSON messages")
        #expect(outcome.wrongText == 0, "\(outcome.wrongText) responses carried damaged content")
        #expect(outcome.responses.values.allSatisfy { $0 == 1 }, "a request was answered more than once")
        let missing = (0..<total).filter { !cancelledIDs.contains($0) && outcome.responses[$0] == nil }
        #expect(missing.isEmpty, "\(missing.count) requests were never answered, e.g. \(missing.prefix(5))")
        peer.closeInput()
        #expect(await peer.serverStopped(within: 20))
    }
}
