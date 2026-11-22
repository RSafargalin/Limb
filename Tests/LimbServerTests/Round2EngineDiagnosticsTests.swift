import Dispatch
import Limb
import LimbTesting
import Synchronization
import Testing

// S7: peer-controlled text in diagnostics is escaped and shortened (fields 128, lines 2048);
// at most 100 diagnostics per kind per connection, then one line, and the counts at close;
// the `diagnostics` closure is never called under a lock, so it may block or call back in.

private typealias ICWire = IndependentConcurrencyWire
private typealias ICBox = IndependentConcurrencyBox
private typealias ICMeter = IndependentConcurrencyMeter

private struct R2Boom: Error, CustomStringConvertible {
    var description: String
}

private let forged = "x\nlimb: stdio: the peer did not read the remaining output; giving up on it\u{1B}[31m\r\u{2028}\u{2029}\u{85}\u{7F}\u{0}\t"

/// Whether `line` could forge a line of its own or drive a terminal.
private func isClean(_ line: String) -> Bool {
    line.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 0..<0x20, 0x7F...0x9F, 0x2028, 0x2029: false
        default: true
        }
    }
}

private func failingServer(lines: ICBox<[String]>, message: String = "boom") throws -> Server {
    let server = round2EngineServer(lines: lines)
    try server.register(tool: ToolDefinition(name: "fail")) { _, _ in throw R2Boom(description: message) }
    try server.register(tool: ToolDefinition(name: "ok")) { _, _ in .text("ok") }
    return server
}

private func ids(_ count: Int, _ suffix: String = "") -> String { String(repeating: "i", count: count) + suffix }

private let idCases: [(String, String)] = [
    (ids(128), ids(128)),
    (ids(129), ids(128, "…")),
    (ids(122, "\u{1B}"), ids(122, "\\u{1b}")),
    (ids(123, "\u{1B}"), ids(123, "…")),
    (ids(123, "\u{0}"), ids(123, "\\u{0}")),
    (ids(124, "\u{0}"), ids(124, "…")),
    (ids(120, "\u{2028}"), ids(120, "\\u{2028}")),
    (ids(121, "\u{2028}"), ids(121, "…")),
    (ids(122, "\u{85}"), ids(122, "\\u{85}")),
    (ids(122, "\u{7F}j"), ids(122, "\\u{7f}…")),
    (String(repeating: "\u{1F600}", count: 129), String(repeating: "\u{1F600}", count: 128) + "…"),
]

@Suite(.timeLimit(.minutes(2)))
struct Round2EngineDiagnosticsTests {
    // MARK: Escaping and truncation

    @Test func aForgedRequestIDIsEscaped() async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(try failingServer(lines: lines))
        let response = try await wire.request("tools/call", ["name": "fail"], id: RequestID(forged))
        #expect(response.round2EngineCode == -32603)
        let line = try #require(lines.value.first)
        #expect(lines.value.count == 1)
        #expect(isClean(line), "\(Array(line.unicodeScalars))")
        #expect(line.contains("\\u{a}limb: stdio"))
        #expect(line.contains("\\u{1b}[31m"))
        #expect(line.contains("\\u{2028}"))
    }

    @Test func aLongRequestIDIsCutTo128Characters() async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(try failingServer(lines: lines))
        _ = try await wire.request("tools/call", ["name": "fail"], id: RequestID(String(repeating: "i", count: 5000)))
        let line = try #require(lines.value.first)
        #expect(line.contains(String(repeating: "i", count: 128) + "…"))
        #expect(!line.contains(String(repeating: "i", count: 129)))
    }

    @Test func aLongIDOfEscapedCharactersStaysWithinTheLineLimit() async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(try failingServer(lines: lines, message: String(repeating: "\u{1}", count: 5000)))
        _ = try await wire.request("tools/call", ["name": "fail"], id: RequestID(String(repeating: "\u{001B}", count: 32)))
        let line = try #require(lines.value.first)
        #expect(isClean(line))
        // round2-rules S7 / E3: at most 2048 characters as written, plus the "…" of the cut.
        #expect(line.unicodeScalars.count <= 2049, "\(line.unicodeScalars.count) characters")
        #expect(line.hasSuffix("…"))
        // The id field: 21 escapes of 6 characters fit 128, the 22nd does not.
        #expect(line.contains("#" + String(repeating: "\\u{1b}", count: 21) + "… failed"), "\(line.prefix(200))")
    }

    /// The id field of `tools/call #<id> failed: …`.
    private static func idField(_ line: String) -> Substring? {
        guard let start = line.firstIndex(of: "#"), let end = line.firstRange(of: " failed: ")?.lowerBound else { return nil }
        return line[line.index(after: start)..<end]
    }

    @Test(arguments: idCases)
    func theIDFieldLimitIsExactForEveryEscapeLength(id: String, field: String) async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(try failingServer(lines: lines))
        _ = try await wire.request("tools/call", ["name": "fail"], id: RequestID(id))
        let line = try #require(lines.value.first)
        #expect(Self.idField(line).map(String.init) == field, "\(line)")
    }

    @Test(arguments: [false, true])
    func theLineLimitIsExact(escaped: Bool) async throws {
        // Measure the fixed part of the line, then make the whole line exactly 2048 characters
        // as written, and one more.
        let probeLines = ICBox<[String]>([])
        _ = try await ICWire(try failingServer(lines: probeLines, message: "m")).request("tools/call", ["name": "fail"], id: "f")
        let prefix = try #require(probeLines.value.first).unicodeScalars.count - 1
        let unit = escaped ? "\u{1}" : "m"
        let unitLength = escaped ? 5 : 1
        // Fill with whole units up to 2048, padding with plain characters.
        let room = 2048 - prefix
        let message = String(repeating: unit, count: room / unitLength) + String(repeating: "p", count: room % unitLength)
        for (extra, cut) in [("", false), ("q", true)] {
            let lines = ICBox<[String]>([])
            _ = try await ICWire(try failingServer(lines: lines, message: message + extra)).request("tools/call", ["name": "fail"], id: "f")
            let line = try #require(lines.value.first)
            #expect(line.unicodeScalars.count == (cut ? 2049 : 2048), "\(line.unicodeScalars.count)")
            #expect(line.hasSuffix("…") == cut)
        }
    }

    @Test func aURIThatReachesADiagnosticIsEscapedAndCut() async throws {
        let lines = ICBox<[String]>([])
        let server = round2EngineServer(lines: lines)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "r2://doc/{id}", name: "doc")) { request, context in
            // Catching the input error and going on is what makes the engine report the URI.
            _ = try? await context.elicit("a", message: "A?", schema: ["type": "object"])
            return [.text(uri: request.uri, text: "")]
        }
        let wire = ICWire(server, capabilities: ["elicitation": [:]])
        let uri = "r2://doc/" + forged + String(repeating: "u", count: 300)
        let response = try await wire.request("resources/read", ["uri": .string(uri)])
        #expect(response["result"]?["resultType"] == "input_required", "\(response)")
        let line = try #require(lines.value.first)
        #expect(isClean(line))
        #expect(line.contains("r2://doc/x\\u{a}limb: stdio"))
        #expect(!line.contains(String(repeating: "u", count: 200)))
    }

    @Test func malformedFramesAndNotificationsLeaveCleanLines() async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(round2EngineServer(lines: lines))
        let escaped = #"\n\u001b[31m limb: forged"#
        wire.send(#"{"jsonrpc":"2.0","method":17,"params":{"x":"\#(escaped)"}}"#)
        wire.send(#"{"jsonrpc":"1.0","id":"\#(escaped)","result":{}}"#)
        wire.send(#"{"jsonrpc":"2.0","id":"\#(escaped)","result":{},"error":{"code":1,"message":"\#(escaped)"}}"#)
        wire.send(#"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"\#(escaped)"}}"#)
        wire.send(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"\#(escaped)","progress":1}}"#)
        wire.send(#"{"jsonrpc":"2.0","method":"\#(escaped)"}"#)
        wire.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"\#(escaped)"}}"#)
        wire.send("{\"jsonrpc\":\"2.0\",\"method\":\"\u{1B}\n\"}")
        #expect(!lines.value.isEmpty)
        for line in lines.value { #expect(isClean(line), "\(line)") }
    }

    // MARK: The cap per kind

    @Test func atMostAHundredPerKindThenOneLineThenTheCountAtClose() async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(try failingServer(lines: lines))
        for _ in 0..<150 { wire.send(#"{"jsonrpc":"2.0","method":5}"#) }
        let notifications = lines.value.filter { $0.contains("ignored a malformed notification") }
        #expect(notifications.count == 100)
        #expect(lines.value.count == 101)
        #expect(lines.value.last?.contains("counted") == true)
        // Another kind is counted apart.
        _ = try await wire.request("tools/call", ["name": "fail"])
        #expect(lines.value.count == 102)
        // And another connection has its own count.
        let other = ICWire(try failingServer(lines: lines))
        other.send(#"{"jsonrpc":"2.0","method":5}"#)
        #expect(lines.value.count == 103)
        await round2EngineWithin { await wire.connection.close(graceSeconds: 0) }
        let last = try #require(lines.value.last)
        #expect(last.contains("50"), "\(last)")
        #expect(last.contains("malformed notifications"), "\(last)")
        #expect(lines.value.count == 104)
    }

    @Test func exactlyAHundredIsNotFollowedByACount() async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(round2EngineServer(lines: lines))
        for _ in 0..<100 { wire.send(#"{"jsonrpc":"1.0","id":"r","result":{}}"#) }
        #expect(lines.value.count == 100)
        await round2EngineWithin { await wire.connection.close(graceSeconds: 0) }
        #expect(lines.value.count == 100)
        wire.send(#"{"jsonrpc":"1.0","id":"r","result":{}}"#)
    }

    @Test func handlerFailuresAreCappedToo() async throws {
        let lines = ICBox<[String]>([])
        let wire = ICWire(try failingServer(lines: lines))
        for index in 0..<120 { _ = try await wire.request("tools/call", ["name": "fail"], id: RequestID(index)) }
        #expect(lines.value.count == 101)
        await round2EngineWithin { await wire.connection.close(graceSeconds: 0) }
        #expect(lines.value.last?.contains("20 more") == true, "\(lines.value.last ?? "")")
    }

    // MARK: A diagnostics closure that blocks or calls back in

    @Test func aClosureThatRegistersAndRemovesToolsAndNotifiesDoesNotDeadlock() async throws {
        let calls = ICMeter()
        let holder = ICBox<Server?>(nil)
        let server = round2EngineServer { configuration in
            configuration.diagnostics = { _ in
                let count = calls.enter()
                guard let server = holder.value else { return }
                try? server.register(tool: ToolDefinition(name: "added\(count)")) { _, _ in .text("") }
                server.removeTool(named: "added\(count)")
                server.notifyResourceUpdated(uri: "r2://x")
            }
        }
        holder.set(server)
        try server.register(tool: ToolDefinition(name: "fail")) { _, _ in throw R2Boom(description: "x") }
        let wire = ICWire(server)
        wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true, "resourceSubscriptions": ["r2://x"]]], id: "s")
        #expect(try await wire.next()["method"] == "notifications/subscriptions/acknowledged")
        await round2EngineWithin {
            wire.send(#"{"jsonrpc":"2.0","method":5}"#)
            _ = try await wire.request("tools/call", ["name": "fail"], id: "f")
            for _ in 0..<110 { wire.send(#"{"jsonrpc":"2.0","method":5}"#) }
            await wire.connection.close(graceSeconds: 0)
        }
        #expect(calls.total >= 3)
        holder.set(nil)
    }

    @Test func aClosureThatCallsBackIntoTheConnectionDoesNotDeadlock() async throws {
        let holder = ICBox<Connection?>(nil)
        let reentered = ICMeter()
        let server = round2EngineServer { configuration in
            configuration.diagnostics = { _ in
                guard let connection = holder.value, reentered.enter() < 50 else { return }
                _ = connection.hasOverflowed
                // A frame from inside the closure: the reader is the caller here.
                connection.receive(
                    Array(#"{"jsonrpc":"2.0","id":"inner","method":"server/discover","params":{\#(round2EngineModernMeta)}}"#.utf8))
            }
        }
        try server.register(tool: ToolDefinition(name: "fail")) { _, _ in throw R2Boom(description: "x") }
        let wire = ICWire(server)
        holder.set(wire.connection)
        await round2EngineWithin {
            wire.send(#"{"jsonrpc":"2.0","method":5}"#)
            #expect(try await wire.response(to: "inner")["result"] != nil)
            _ = try await wire.request("tools/call", ["name": "fail"], id: "f")
            await wire.connection.close(graceSeconds: 0)
        }
        holder.set(nil)
    }

    @Test func aClosureThatClosesTheConnectionDoesNotDeadlock() async throws {
        let holder = ICBox<Connection?>(nil)
        let closings = ICBox<[Task<Void, Never>]>([])
        let server = round2EngineServer { configuration in
            configuration.diagnostics = { _ in
                guard let connection = holder.value else { return }
                closings.update { $0.append(Task { await connection.close(graceSeconds: 0) }) }
            }
        }
        try server.register(tool: ToolDefinition(name: "fail")) { _, _ in throw R2Boom(description: "x") }
        let wire = ICWire(server)
        holder.set(wire.connection)
        await round2EngineWithin {
            _ = try await wire.request("tools/call", ["name": "fail"], id: "f")
            for task in closings.value { await task.value }
        }
        holder.set(nil)
        // Closed: further requests are not answered.
        wire.post("server/discover", id: "late")
        #expect(await wire.isSilent())
    }

    @Test func aClosureThatBlocksInAHandlersTaskDoesNotStopTheReader() async throws {
        let release = DispatchSemaphore(value: 0)
        let blocked = ICMeter()
        let server = round2EngineServer { configuration in
            configuration.diagnostics = { line in
                guard line.contains("failed") else { return }
                blocked.enter()
                _ = release.wait(timeout: .now() + 0.5)
            }
        }
        try server.register(tool: ToolDefinition(name: "fail")) { _, _ in throw R2Boom(description: "x") }
        let wire = ICWire(server)
        wire.post("tools/call", ["name": "fail"], id: "f")
        #expect(await independentConcurrencyEventually { blocked.total == 1 })
        await round2EngineWithin(.seconds(20)) {
            let discovery = try await wire.request("server/discover", id: "d")
            #expect(discovery["result"] != nil)
        }
        release.signal()
        #expect(try await round2EngineResponse(wire, to: "f").round2EngineCode == -32603)
    }

    @Test func aClosureCalledForDroppedLogsMayCallBackIn() async throws {
        let holder = ICBox<Connection?>(nil)
        let lines = ICBox<[String]>([])
        let server = round2EngineServer { configuration in
            configuration.diagnostics = { line in
                lines.update { $0.append(line) }
                _ = holder.value?.hasOverflowed
            }
        }
        try server.register(tool: ToolDefinition(name: "chatty")) { _, context in
            for index in 0..<5 { context.log(.error, .string("line \(index)")) }
            return .text("done")
        }
        let wire = ICWire(server, modern: false)
        try await wire.initialize()
        holder.set(wire.connection)
        wire.sink.blockCapacity()
        wire.call("chatty", id: "c")
        #expect(await independentConcurrencyEventually { lines.value.contains { $0.contains("log messages") } })
        wire.sink.unblockCapacity()
        await round2EngineWithin { _ = try await wire.response(to: "c") }
        #expect(lines.value.filter { $0.contains("log messages") }.count == 1)
        holder.set(nil)
    }
}
