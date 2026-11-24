import Dispatch
import Limb
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct IndependentClientRequestDeliveryTests {
    @Test
    func refusedRootsFailsPromptlyAndNextRootsSucceeds() async throws {
        let fixture = try Fixture(refuseFirstRoots: true)
        try await fixture.initialize()

        fixture.call(id: "refused")
        // The response must arrive well before the configured 20-second request timeout.
        let failedCall = try await fixture.response(id: "refused")
        #expect(Self.text(in: failedCall) == "MCPError -31004")
        let refusals = fixture.sink.refusals
        try #require(refusals.count == 1)
        let refusedID = try #require(refusals[0]["id"])

        fixture.call(id: "accepted")
        let roots = try await fixture.next()
        try #require(roots["method"] == "roots/list")
        let acceptedID = try #require(roots["id"])
        #expect(acceptedID != refusedID)
        fixture.send([
            "jsonrpc": "2.0", "id": acceptedID,
            "result": ["roots": [["uri": "file:///delivery-fixture"]]],
        ])
        let successfulCall = try await fixture.response(id: "accepted")
        #expect(Self.text(in: successfulCall) == "file:///delivery-fixture")

        await fixture.connection.close(graceSeconds: 1)
        #expect(fixture.sink.cancellations(for: refusedID).isEmpty)
        #expect(fixture.sink.cancellations(for: acceptedID).isEmpty)
    }

    @Test
    func cancellingTheCallingToolWithdrawsAnAcceptedRootsRequestOnce() async throws {
        let fixture = try Fixture(refuseFirstRoots: false)
        defer { fixture.handlerCancelled.open() }
        try await fixture.initialize()

        fixture.call(id: "cancelled")
        let roots = try await fixture.next()
        try #require(roots["method"] == "roots/list")
        let rootsID = try #require(roots["id"])
        fixture.send([
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": "cancelled"],
        ])

        let cancellation = try await fixture.next()
        #expect(cancellation["method"] == "notifications/cancelled")
        #expect(cancellation["params"]?["requestId"] == rootsID)
        let handlerObservedCancellation = await independentConcurrencyFinishes(within: .seconds(5)) {
            await fixture.handlerCancelled.wait()
        }
        #expect(handlerObservedCancellation)

        fixture.send(["jsonrpc": "2.0", "id": rootsID, "result": ["roots": []]])
        fixture.send(["jsonrpc": "2.0", "id": "ping", "method": "ping"])
        let ping = try await fixture.response(id: "ping")
        #expect(ping["result"] != nil)

        await fixture.connection.close(graceSeconds: 1)
        #expect(fixture.sink.cancellations(for: rootsID).count == 1)
        #expect(!fixture.sink.accepted.history.contains { $0.json?["id"] == "cancelled" })
    }

    @Test
    func cancellationDuringSinkRefusalDoesNotWithdrawTheUnsentRequest() async throws {
        let race = RefusalRace()
        defer {
            race.releaseSink.signal()
            race.releaseHandler.open()
        }
        let fixture = try Fixture(refuseFirstRoots: true, race: race)
        try await fixture.initialize()
        fixture.call(id: "racing")
        try #require(await independentConcurrencyEventually { fixture.sink.refusals.count == 1 && race.request.value != nil })
        let refusedID = try #require(fixture.sink.refusals.first?["id"])
        let rootsTask = try #require(race.request.value)
        DispatchQueue.global().async {
            rootsTask.cancel()
            race.cancelReturned.set(true)
        }
        // The task's cancellation is committed while enqueue is still inside the refusal barrier.
        try #require(await independentConcurrencyEventually { rootsTask.isCancelled })

        race.releaseSink.signal()
        try #require(await independentConcurrencyEventually { race.cancelReturned.value })
        try #require(fixture.sink.cancellations(for: refusedID).isEmpty)
        try #require(await independentConcurrencyEventually { race.releaseHandler.waiting == 1 })
        #expect(!race.sinkTimedOut.value)
        #expect(race.errors.value == [MCPError.Code.requestDeliveryFailed])
        fixture.send([
            "jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "racing"],
        ])
        race.releaseHandler.open()

        fixture.call(id: "after-race")
        let roots = try await fixture.next()
        try #require(roots["method"] == "roots/list")
        let acceptedID = try #require(roots["id"])
        #expect(acceptedID != refusedID)
        fixture.send([
            "jsonrpc": "2.0", "id": acceptedID,
            "result": ["roots": [["uri": "file:///after-race"]]],
        ])
        #expect(try Self.text(in: await fixture.response(id: "after-race")) == "file:///after-race")
        await fixture.connection.close(graceSeconds: 1)

        #expect(race.errors.value == [MCPError.Code.requestDeliveryFailed])
        #expect(fixture.sink.cancellations(for: refusedID).isEmpty)
        #expect(fixture.sink.cancellations(for: acceptedID).isEmpty)
        #expect(!fixture.sink.accepted.history.contains { $0.json?["id"] == "racing" })
    }

    private static func text(in reply: JSONValue) -> String? {
        reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
    }

    private struct Fixture: Sendable {
        let sink: RefusingRootsSink
        let connection: Connection
        let handlerCancelled: IndependentConcurrencyGate

        init(refuseFirstRoots: Bool, race: RefusalRace? = nil) throws {
            let server = Server(name: "client-request-delivery", version: "1") {
                $0.clientRequestTimeoutSeconds = 20
            }
            let handlerCancelled = IndependentConcurrencyGate()
            try server.register(tool: ToolDefinition(name: "read_roots")) { _, context in
                do {
                    let roots: [Root]
                    if let race {
                        let request = Task { try await context.roots() }
                        race.request.set(request)
                        roots = try await request.value
                    } else {
                        roots = try await context.roots()
                    }
                    return .text(roots.map(\.uri).joined(separator: ","))
                } catch let error as MCPError {
                    if let race {
                        race.errors.update { $0.append(error.code) }
                        await race.releaseHandler.wait()
                    }
                    return .text("MCPError \(error.code)")
                } catch let error as CancellationError {
                    handlerCancelled.open()
                    throw error
                }
            }
            self.handlerCancelled = handlerCancelled
            sink = RefusingRootsSink(refuseFirstRoots: refuseFirstRoots, race: race)
            connection = server.connect(to: sink)
        }

        func initialize() async throws {
            send([
                "jsonrpc": "2.0", "id": "init", "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": ["roots": [:]],
                    "clientInfo": ["name": "delivery-fixture", "version": "1"],
                ],
            ])
            let reply = try await response(id: "init")
            try #require(reply["result"]?["protocolVersion"] == "2025-11-25")
            send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        }

        func call(id: String) {
            send([
                "jsonrpc": "2.0", "id": .string(id), "method": "tools/call",
                "params": ["name": "read_roots", "arguments": [:]],
            ])
        }

        func send(_ message: JSONValue) {
            connection.receive(message.encoded())
        }

        func next(expecting description: Comment = "Expected an outbound frame within five seconds") async throws -> JSONValue {
            let record = try #require(await sink.accepted.next(timeout: .seconds(5)), description)
            return try #require(record.json)
        }

        func response(id: String) async throws -> JSONValue {
            let reply = try await next(expecting: "Expected a response to \(id) within five seconds")
            try #require(reply["id"] == .string(id))
            return reply
        }
    }
}

private final class RefusalRace: Sendable {
    let request = IndependentConcurrencyBox<Task<[Root], any Error>?>(nil)
    let releaseSink = DispatchSemaphore(value: 0)
    let releaseHandler = IndependentConcurrencyGate()
    let sinkTimedOut = IndependentConcurrencyBox(false)
    let cancelReturned = IndependentConcurrencyBox(false)
    let errors = IndependentConcurrencyBox<[Int]>([])
}

private final class RefusingRootsSink: FrameSink {
    let accepted = IndependentConcurrencySink()
    private let refuseFirstRoots: Bool
    private let race: RefusalRace?
    private let refusedFrames = Mutex<[JSONValue]>([])

    init(refuseFirstRoots: Bool, race: RefusalRace?) {
        self.refuseFirstRoots = refuseFirstRoots
        self.race = race
    }

    var refusals: [JSONValue] { refusedFrames.withLock { $0 } }

    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        if refuseFirstRoots, !urgent, let message = try? JSON.parse(frame), message["method"] == "roots/list" {
            let refused = refusedFrames.withLock { frames in
                guard frames.isEmpty else { return false }
                frames.append(message)
                return true
            }
            if refused {
                if let race, race.releaseSink.wait(timeout: .now() + .seconds(15)) == .timedOut {
                    race.sinkTimedOut.set(true)
                }
                return false
            }
        }
        return accepted.enqueue(frame, key: key, urgent: urgent, replacesProgress: replacesProgress)
    }

    func waitForCapacity() async { await accepted.waitForCapacity() }
    func discard(key: RequestID) { accepted.discard(key: key) }
    var isOverBudget: Bool { accepted.isOverBudget }

    func cancellations(for id: JSONValue) -> [JSONValue] {
        accepted.history.compactMap(\.json).filter {
            $0["method"] == "notifications/cancelled" && $0["params"]?["requestId"] == id
        }
    }
}
