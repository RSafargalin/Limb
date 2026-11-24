import Limb
import LimbTesting
import Synchronization
import Testing

@Suite
struct IndependentFanoutAndBatchAccountingTests {
    private static let uri = "test://fanout"
    private static let eventMethod = "notifications/resources/updated"
    private static let acknowledgmentMethod = "notifications/subscriptions/acknowledged"
    private static let subscriptionKey = "io.modelcontextprotocol/subscriptionId"

    @Test func fanoutResumesOnlyTheUndeliveredRecipient() async throws {
        let server = independentConcurrencyServer()
        let sink = FanoutSink(firstEvent: .acceptAndBlock)
        let connection = server.connect(to: sink)
        defer { sink.output.unblockCapacity() }
        let other = IndependentConcurrencyWire(server)

        try await open(11, on: connection, sink: sink.output)
        try await open(12, on: connection, sink: sink.output)
        try await open(13, on: connection, sink: sink.output, uri: "test://different")
        other.send(Self.listen(21, uri: Self.uri))
        try expectAcknowledgment(try await other.next(timeout: .seconds(2)), id: 21)

        server.notifyResourceUpdated(uri: Self.uri)

        let first = try await next(sink.output)
        let firstID = try eventID(first)
        try #require(Set([11, 12]).contains(firstID))
        #expect(sink.isOverBudget)
        #expect(try eventID(try await other.next(timeout: .seconds(2))) == 21)
        try #require(await independentConcurrencyEventually(timeout: .seconds(2)) {
            sink.output.capacityWaiterCount > 0
        })
        #expect(sink.attemptedEventIDs == [firstID])

        sink.output.unblockCapacity()
        let secondID = try eventID(try await next(sink.output))
        #expect(Set([firstID, secondID]) == Set([11, 12]))
        #expect(sink.attemptedEventIDs == [firstID, secondID])
        #expect(await sink.output.next(timeout: .milliseconds(100)) == nil)
    }

    @Test func blockedUpdatesCoalesceForSubscriptionsStillOpenAtResume() async throws {
        let server = independentConcurrencyServer()
        let wire = IndependentConcurrencyWire(server)
        defer { wire.sink.unblockCapacity() }
        for id in [41, 42, 43] {
            wire.send(Self.listen(id, uri: Self.uri))
            try expectAcknowledgment(try await next(wire.sink), id: id)
        }

        wire.sink.blockCapacity()
        let mark = wire.sink.mark
        server.notifyResourceUpdated(uri: Self.uri)
        try #require(await independentConcurrencyEventually(timeout: .seconds(2)) {
            wire.sink.capacityWaiterCount > 0
        })
        server.notifyResourceUpdated(uri: Self.uri)
        let cancelled = RequestID(42)
        wire.cancel(cancelled)
        try #require(await independentConcurrencyEventually(timeout: .seconds(2)) {
            wire.sink.discards.contains(cancelled)
        })
        #expect(wire.sink.mark == mark)

        wire.sink.unblockCapacity()
        let first = try eventID(try await next(wire.sink))
        let second = try eventID(try await next(wire.sink))
        #expect(Set([first, second]) == Set([41, 43]))
        #expect(await wire.sink.next(timeout: .milliseconds(100)) == nil)
    }

    @Test func refusalWithRoomDropsOnlyThatRecipient() async throws {
        let diagnostics = IndependentConcurrencyBox<[String]>([])
        let server = independentConcurrencyServer { configuration in
            configuration.diagnostics = { message in diagnostics.update { $0.append(message) } }
        }
        let sink = FanoutSink(firstEvent: .refuse)
        let connection = server.connect(to: sink)
        try await open(31, on: connection, sink: sink.output)
        try await open(32, on: connection, sink: sink.output)
        let diagnosticCount = diagnostics.value.count

        server.notifyResourceUpdated(uri: Self.uri)

        let delivered = try eventID(try await next(sink.output))
        let attempts = sink.attemptedEventIDs
        try #require(attempts.count == 2)
        #expect(Set(attempts) == Set([31, 32]))
        #expect(attempts.last == delivered)
        #expect(await independentConcurrencyEventually(timeout: .seconds(2)) {
            diagnostics.value.count > diagnosticCount
        })
        #expect(await sink.output.next(timeout: .milliseconds(100)) == nil)

        server.notifyResourceUpdated(uri: Self.uri)
        let nextID = try eventID(try await next(sink.output))
        let finalID = try eventID(try await next(sink.output))
        #expect(Set([nextID, finalID]) == Set([31, 32]))
    }

    @Test func legacyBatchChargesEachQueuedCallItsCompactMemberSize() async throws {
        let gate = IndependentConcurrencyGate()
        defer { gate.open() }

        func call(_ id: Int, label: String) -> JSONValue {
            [
                "jsonrpc": "2.0", "id": JSONValue(id), "method": "tools/call",
                "params": ["name": "label", "arguments": ["label": .string(label)]],
            ]
        }
        let small = call(12, label: "short")
        let large = call(11, label: "a slightly longer label")
        let ignored: JSONValue = ["jsonrpc": "2.0", "method": "notifications/fixture"]
        let budget = small.encoded().count
        try #require(large.encoded().count > budget)
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 1
            configuration.budgets.maxQueuedRequests = 4
            configuration.budgets.maxQueuedBytes = budget
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("released")
        }
        try server.register(tool: ToolDefinition(name: "label")) { arguments, _ in
            .text(arguments["label"]?.stringValue ?? "")
        }

        let wire = IndependentConcurrencyWire(server, modern: false)
        try await wire.initialize(version: .v2025_03_26)
        wire.call("hold", id: RequestID(10))
        try #require(await independentConcurrencyEventually(timeout: .seconds(2)) { gate.waiting == 1 })
        wire.send(.array([large, ignored, small]))
        let ping = try await wire.request("ping", id: RequestID(13))
        #expect(ping["result"] != nil)
        #expect(wire.others.isEmpty)

        gate.open()
        let first = try await wire.next(timeout: .seconds(2))
        let second = try await wire.next(timeout: .seconds(2))
        let held = first["id"] == 10 ? first : second
        let batch = try #require((first.arrayValue ?? second.arrayValue))
        #expect(held["id"] == 10)
        #expect(held.independentConcurrencyText == "released")
        #expect(batch.count == 2)
        let refused = try #require(batch.first { $0["id"] == 11 })
        let accepted = try #require(batch.first { $0["id"] == 12 })
        #expect(refused.independentConcurrencyErrorCode == -31001)
        #expect(accepted.independentConcurrencyText == "short")

        wire.send(call(14, label: "next"))
        let nextCall = try await wire.response(to: RequestID(14), timeout: .seconds(2))
        #expect(nextCall.independentConcurrencyText == "next")
    }

    private static func listen(_ id: Int, uri: String) -> JSONValue {
        [
            "jsonrpc": "2.0", "id": JSONValue(id), "method": "subscriptions/listen",
            "params": [
                "notifications": ["resourceSubscriptions": [.string(uri)]],
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": [:],
                ],
            ],
        ]
    }

    private func open(
        _ id: Int, on connection: Connection, sink: IndependentConcurrencySink, uri: String = Self.uri
    ) async throws {
        connection.receive(Self.listen(id, uri: uri).encoded())
        try expectAcknowledgment(try await next(sink), id: id)
    }

    private func expectAcknowledgment(_ message: JSONValue, id: Int) throws {
        try #require(message["method"]?.stringValue == Self.acknowledgmentMethod)
        #expect(message["params"]?["_meta"]?[Self.subscriptionKey]?.intValue == id)
    }

    private func eventID(_ message: JSONValue) throws -> Int {
        try #require(message["method"]?.stringValue == Self.eventMethod)
        #expect(message["params"]?["uri"]?.stringValue == Self.uri)
        return try #require(message["params"]?["_meta"]?[Self.subscriptionKey]?.intValue)
    }

    private func next(_ sink: IndependentConcurrencySink) async throws -> JSONValue {
        let record = try #require(await sink.next(timeout: .seconds(2)))
        return try #require(record.json)
    }
}

private final class FanoutSink: FrameSink {
    enum FirstEvent: Sendable {
        case acceptAndBlock
        case refuse
    }

    let output = IndependentConcurrencySink()
    private let firstEvent: FirstEvent
    private let attempts = Mutex<[Int]>([])

    init(firstEvent: FirstEvent) { self.firstEvent = firstEvent }

    var isOverBudget: Bool { output.isOverBudget }
    var attemptedEventIDs: [Int] { attempts.withLock { $0 } }
    func waitForCapacity() async { await output.waitForCapacity() }
    func discard(key: RequestID) { output.discard(key: key) }

    func enqueue(_ frame: [UInt8], key: RequestID?, urgent: Bool, replacesProgress: Bool) -> Bool {
        let message = try? JSON.parse(frame)
        guard message?["method"]?.stringValue == "notifications/resources/updated" else {
            return output.enqueue(frame, key: key, urgent: urgent, replacesProgress: replacesProgress)
        }
        let id = message?["params"]?["_meta"]?["io.modelcontextprotocol/subscriptionId"]?.intValue
        let first = attempts.withLock { attempts in
            attempts.append(id ?? -1)
            return attempts.count == 1
        }
        guard !isOverBudget else { return false }
        if first {
            switch firstEvent {
            case .refuse: return false
            case .acceptAndBlock: output.blockCapacity()
            }
        }
        return output.enqueue(frame, key: key, urgent: urgent, replacesProgress: replacesProgress)
    }
}
