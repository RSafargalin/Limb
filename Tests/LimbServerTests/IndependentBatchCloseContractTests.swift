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
}
