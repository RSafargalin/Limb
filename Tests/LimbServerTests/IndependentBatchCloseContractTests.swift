import Dispatch
import Limb
import Testing

@Suite(.timeLimit(.minutes(1)))
struct IndependentBatchCloseContractTests {
    private static var batch: String {
        """
        [
          {"jsonrpc":"2.0","id":"ping","method":"ping"},
          {"jsonrpc":"2.0","id":"tool","method":"tools/call","params":{"name":"hold"}}
        ]
        """
    }

    private static func session(
        configure: (inout ServerConfiguration) -> Void = { _ in },
        _ hold: @escaping @Sendable () async -> Void
    ) async throws -> IndependentConcurrencyWire {
        let server = independentConcurrencyServer(configure)
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await hold()
            return .text("finished")
        }
        let wire = IndependentConcurrencyWire(server, modern: false)
        let initialized = try await wire.initialize(version: .v2025_03_26)
        try #require(initialized["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        return wire
    }

    private static func responses(from wire: IndependentConcurrencyWire, since mark: Int) throws -> [JSONValue] {
        let records = wire.sink.history.dropFirst(mark)
        try #require(records.count == 1, "Expected exactly one batch response")
        let members = try #require(records.first?.json?.arrayValue)
        for member in members {
            #expect(member["jsonrpc"]?.stringValue == "2.0")
            #expect(member["result"] != nil)
            #expect(member["error"] == nil)
        }
        return members
    }

    @Test func completedMembersAreJoinedExactlyOnceWithoutClose() async throws {
        let gate = IndependentConcurrencyGate()
        defer { gate.open() }
        let wire = try await Self.session { await gate.wait() }
        let mark = wire.sink.mark

        wire.send(Self.batch)
        try #require(await independentConcurrencyEventually { gate.waiting == 1 })
        #expect(wire.sink.mark == mark)
        gate.open()
        try #require(await independentConcurrencyEventually { wire.sink.mark > mark })
        try #require(await independentConcurrencyFinishes(within: .seconds(5)) {
            await wire.connection.close(graceSeconds: 0)
        })

        let members = try Self.responses(from: wire, since: mark)
        #expect(members.compactMap { $0["id"]?.stringValue }.sorted() == ["ping", "tool"])
        #expect(members.count == 2)
        #expect(members.first { $0["id"]?.stringValue == "tool" }?.independentConcurrencyText == "finished")
    }

    @Test func closePreservesTheReadyMemberAndReleasesWaitersWhileTheOtherHandlerIsHeld() async throws {
        let gate = IndependentConcurrencyGate()
        defer { gate.open() }
        let cancelled = IndependentConcurrencyBox(false)
        let exited = IndependentConcurrencyBox(false)
        let wire = try await Self.session {
            await withTaskCancellationHandler {
                await gate.wait()
                exited.set(true)
            } onCancel: {
                cancelled.set(true)
            }
        }
        let mark = wire.sink.mark

        wire.send(Self.batch)
        try #require(await independentConcurrencyEventually { gate.waiting == 1 })
        #expect(wire.sink.mark == mark)

        try #require(await independentConcurrencyFinishes(within: .seconds(5)) {
            async let first: Void = wire.connection.close(graceSeconds: 0)
            async let second: Void = wire.connection.close(graceSeconds: 0)
            _ = await (first, second)
        })
        #expect(cancelled.value)
        #expect(!exited.value)

        let members = try Self.responses(from: wire, since: mark)
        try #require(members.count == 1)
        #expect(members.first?["id"]?.stringValue == "ping")
        #expect(members.first?["result"] == [:])

        gate.open()
        try #require(await independentConcurrencyEventually { exited.value })
        try #require(await independentConcurrencyFinishes(within: .seconds(5)) {
            await wire.connection.close(graceSeconds: 0)
        })
        #expect(wire.sink.mark == mark + 1)
    }

    @Test func closedConnectionReleasesReaderWithoutStartingTheBatch() async throws {
        let calls = IndependentConcurrencyMeter()
        let wire = try await Self.session { calls.enter() }
        let mark = wire.sink.mark
        try #require(await independentConcurrencyFinishes(within: .seconds(5)) {
            await wire.connection.close(graceSeconds: 0)
        })
        try #require(await independentConcurrencyFinishes(within: .seconds(5)) {
            wire.send(Self.batch)
            await wire.connection.close(graceSeconds: 0)
        })
        #expect(calls.total == 0)
        #expect(wire.sink.mark == mark)
    }

    @Test func closeBetweenBatchMembersPreservesThePingAndDeclinesTheTool() async throws {
        let resumeAdmission = DispatchSemaphore(value: 0)
        defer { resumeAdmission.signal() }
        let reachedAdmission = IndependentConcurrencyBox(false)
        let admissionTimedOut = IndependentConcurrencyBox(false)
        let readerReturned = IndependentConcurrencyBox(false)
        let calls = IndependentConcurrencyMeter()
        let wire = try await Self.session(configure: { configuration in
            configuration.beforeAdmission = { id in
                guard id == RequestID("tool") else { return }
                reachedAdmission.set(true)
                if resumeAdmission.wait(timeout: .now() + .seconds(20)) == .timedOut {
                    admissionTimedOut.set(true)
                }
            }
        }) {
            calls.enter()
        }
        let mark = wire.sink.mark

        DispatchQueue.global().async {
            wire.send(Self.batch)
            readerReturned.set(true)
        }
        try #require(await independentConcurrencyEventually { reachedAdmission.value })
        #expect(wire.sink.mark == mark)
        #expect(calls.total == 0)
        try #require(await independentConcurrencyFinishes(within: .seconds(5)) {
            await wire.connection.close(graceSeconds: 0)
        })
        #expect(!readerReturned.value)

        resumeAdmission.signal()
        try #require(await independentConcurrencyEventually { readerReturned.value })
        #expect(!admissionTimedOut.value)
        #expect(calls.total == 0)
        let members = try Self.responses(from: wire, since: mark)
        try #require(members.count == 1)
        #expect(members.first?["id"]?.stringValue == "ping")
        #expect(members.first?["result"] == [:])
    }

    enum FirstBatchEnd: Sendable { case finish, cancel, close }

    @Test(arguments: [
        (false, FirstBatchEnd.finish), (false, .cancel), (true, .finish), (true, .cancel), (true, .close),
    ])
    func retainedBatchRepliesShareBudgetAndReleaseIt(secondConnection: Bool, end: FirstBatchEnd) async throws {
        let firstGate = IndependentConcurrencyGate()
        let otherGate = IndependentConcurrencyGate()
        defer {
            firstGate.open()
            otherGate.open()
        }
        let budget = 1_024
        let server = independentConcurrencyServer { $0.budgets.maxOutboundBytes = budget }
        try server.register(tool: ToolDefinition(name: "hold", description: String(repeating: "x", count: 640))) { arguments, _ in
            let gate = arguments["first"] == true ? firstGate : otherGate
            await gate.wait()
            return .text("finished")
        }
        let first = IndependentConcurrencyWire(server, modern: false)
        _ = try await first.initialize(version: .v2025_03_26)
        let second = secondConnection ? IndependentConcurrencyWire(server, modern: false) : first
        if secondConnection { _ = try await second.initialize(version: .v2025_03_26) }

        first.send(#"{"jsonrpc":"2.0","id":"l0","method":"tools/list"}"#)
        let listing = try #require(await first.sink.next(timeout: .seconds(2)))
        let pingBytes = #"{"jsonrpc":"2.0","id":"p1","result":{}}"#.utf8.count
        try #require(listing.frame.count > budget / 2)
        try #require(listing.frame.count + pingBytes <= budget)

        func sendBatch(_ wire: IndependentConcurrencyWire, _ number: Int) {
            wire.send("""
                [
                  {"jsonrpc":"2.0","id":"l\(number)","method":"tools/list"},
                  {"jsonrpc":"2.0","id":"p\(number)","method":"ping"},
                  {"jsonrpc":"2.0","id":"h\(number)","method":"tools/call","params":{"name":"hold","arguments":{"first":\(number == 1)}}}
                ]
                """)
        }

        let firstMark = first.sink.mark
        let secondMark = second.sink.mark
        sendBatch(first, 1)
        sendBatch(second, 2)
        try #require(await independentConcurrencyEventually { firstGate.waiting == 1 && otherGate.waiting == 1 })
        #expect(first.sink.mark == firstMark)
        #expect(second.sink.mark == secondMark)
        switch end {
        case .finish:
            firstGate.open()
        case .cancel:
            first.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"h1"}}"#)
        case .close:
            await first.connection.close(graceSeconds: 0)
        }
        let firstReply = try #require(await first.sink.next(timeout: .seconds(2)))
        let firstMembers = try #require(firstReply.json?.arrayValue)
        #expect(firstMembers.first { $0["id"] == "l1" }?["result"] == listing.json?["result"])
        #expect(firstMembers.first { $0["id"] == "p1" }?["result"] == [:])
        #expect(firstMembers.contains { $0["id"] == "h1" } == (end == .finish))

        // A new listing takes the released reservation even when the second batch still waits.
        let recovery = end == .close ? second : first
        sendBatch(recovery, 3)
        firstGate.open()
        otherGate.open()
        var remaining: [JSONValue] = []
        let next = try #require(await second.sink.next(timeout: .seconds(2)))
        remaining += try #require(next.json?.arrayValue)
        let last = try #require(await recovery.sink.next(timeout: .seconds(2)))
        remaining += try #require(last.json?.arrayValue)
        #expect(remaining.first { $0["id"] == "l2" }?["error"]?["code"]?.numberValue?.intValue == MCPError.Code.overloaded)
        #expect(remaining.first { $0["id"] == "p2" }?["result"] == [:])
        #expect(remaining.first { $0["id"] == "l3" }?["result"] == listing.json?["result"])
        #expect(remaining.first { $0["id"] == "h2" }?.independentConcurrencyText == "finished")
        #expect(remaining.first { $0["id"] == "h3" }?.independentConcurrencyText == "finished")
        #expect(remaining.count == 6)
        await first.connection.close(graceSeconds: 0)
        if secondConnection { await second.connection.close(graceSeconds: 0) }
    }

    @Test(arguments: [0, 1_024])
    func aReadyHandlerResponseUsesTheBudgetAndKeepsItsTypedID(budget: Int) async throws {
        let gate = IndependentConcurrencyGate()
        defer { gate.open() }
        let server = independentConcurrencyServer {
            $0.execution = .serial
            $0.budgets.maxOutboundBytes = budget
        }
        try server.register(tool: ToolDefinition(name: "payload")) { _, _ in
            .text(String(repeating: "a", count: 1_200))
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("finished")
        }
        let wire = IndependentConcurrencyWire(server, modern: false)
        _ = try await wire.initialize(version: .v2025_03_26)
        let mark = wire.sink.mark
        wire.send("""
            [
              {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"payload"}},
              {"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"hold"}}
            ]
            """)
        try #require(await independentConcurrencyEventually { gate.waiting == 1 })
        #expect(wire.sink.mark == mark)
        gate.open()
        let batch = try #require(await wire.sink.next(timeout: .seconds(2)))
        let members = try #require(batch.json?.arrayValue)
        #expect(members.count == 2)
        #expect(members.first { $0["id"] == 1 }?.independentConcurrencyErrorCode == MCPError.Code.overloaded)
        #expect(members.first { $0["id"] == "1" }?.independentConcurrencyText == "finished")
        await wire.connection.close(graceSeconds: 0)
    }

    @Test(arguments: [0, 1])
    func theRetainedResponseFitsAtItsExactEncodedLength(shortBy: Int) async throws {
        func makeServer(budget: Int) throws -> Server {
            let server = independentConcurrencyServer { $0.budgets.maxOutboundBytes = budget }
            try server.register(tool: ToolDefinition(name: "example", description: "Example tool")) { _, _ in .text("ok") }
            return server
        }

        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let reference = IndependentConcurrencyWire(try makeServer(budget: 1_024), modern: false)
        _ = try await reference.initialize(version: .v2025_03_26)
        reference.send(list)
        let exact = try #require(await reference.sink.next(timeout: .seconds(2)))
        let expected = try #require(exact.json?["result"])
        await reference.connection.close(graceSeconds: 0)

        let wire = IndependentConcurrencyWire(try makeServer(budget: exact.frame.count - shortBy), modern: false)
        _ = try await wire.initialize(version: .v2025_03_26)
        wire.send(#"[\#(list),{"jsonrpc":"2.0","id":"1","method":"ping"}]"#)
        let batch = try #require(await wire.sink.next(timeout: .seconds(2)))
        let members = try #require(batch.json?.arrayValue)
        #expect(members.count == 2)
        #expect(members.first { $0["id"] == "1" }?["result"] == [:])
        let retained = try #require(members.first { $0["id"] == 1 })
        if shortBy == 0 {
            #expect(retained["result"] == expected)
        } else {
            #expect(retained.independentConcurrencyErrorCode == MCPError.Code.overloaded)
        }
        await wire.connection.close(graceSeconds: 0)
    }

    @Test func aBatchHandoffKeepsTheReservationUntilTheSinkReturns() async throws {
        let budget = 1_024
        let server = independentConcurrencyServer { $0.budgets.maxOutboundBytes = budget }
        try server.register(tool: ToolDefinition(name: "sample", description: String(repeating: "x", count: 700))) { _, _ in
            .text("ok")
        }
        let firstSink = BatchHandoffSink()
        defer { firstSink.release.signal() }
        let first = server.connect(to: firstSink)
        first.receive(Array(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8))
        let handshake = try #require(await firstSink.recording.next(timeout: .seconds(2)))
        try #require(handshake.json?["result"]?["protocolVersion"] == "2025-03-26")
        first.receive(Array(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))

        let second = IndependentConcurrencyWire(server, modern: false)
        _ = try await second.initialize(version: .v2025_03_26)
        let request = #"[{"jsonrpc":"2.0","id":"list","method":"tools/list"},{"jsonrpc":"2.0","id":"ping","method":"ping"}]"#
        let firstReaderDone = IndependentConcurrencyBox(false)
        DispatchQueue.global().async {
            first.receive(Array(request.utf8))
            firstReaderDone.set(true)
        }
        try #require(await independentConcurrencyEventually { firstSink.handoffStarted.value })

        second.send(request)
        let pressure = try #require(await second.sink.next(timeout: .seconds(2)))
        let refused = try #require(pressure.json?.arrayValue)
        #expect(refused.first { $0["id"] == "list" }?.independentConcurrencyErrorCode == MCPError.Code.overloaded)
        #expect(refused.first { $0["id"] == "ping" }?["result"] == [:])

        firstSink.release.signal()
        try #require(await independentConcurrencyEventually { firstReaderDone.value })
        #expect(!firstSink.timedOut.value)
        let delivered = try #require(await firstSink.recording.next(timeout: .seconds(2)))
        let accepted = try #require(delivered.json?.arrayValue?.first { $0["id"] == "list" }?["result"])
        second.send(#"[{"jsonrpc":"2.0","id":"next","method":"tools/list"},{"jsonrpc":"2.0","id":"pong","method":"ping"}]"#)
        let recovered = try #require(await second.sink.next(timeout: .seconds(2)))
        #expect(recovered.json?.arrayValue?.first { $0["id"] == "next" }?["result"] == accepted)
        #expect(recovered.json?.arrayValue?.first { $0["id"] == "pong" }?["result"] == [:])
        await first.close(graceSeconds: 0)
        await second.connection.close(graceSeconds: 0)
    }
}

private final class BatchHandoffSink: FrameSink {
    let recording = IndependentConcurrencySink()
    let handoffStarted = IndependentConcurrencyBox(false)
    let timedOut = IndependentConcurrencyBox(false)
    let release = DispatchSemaphore(value: 0)

    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        if frame.first == 0x5B {
            handoffStarted.set(true)
            if release.wait(timeout: .now() + .seconds(15)) == .timedOut { timedOut.set(true) }
        }
        return recording.enqueue(frame, key: key, urgent: urgent, replacesProgress: replacesProgress)
    }

    func waitForCapacity() async { await recording.waitForCapacity() }
    func discard(key: RequestID) { recording.discard(key: key) }
}
