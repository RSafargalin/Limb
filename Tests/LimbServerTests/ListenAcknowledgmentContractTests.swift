import Limb
import Synchronization
import Testing

@Suite
struct ListenAcknowledgmentContractTests {
    @Test
    func overBudgetQueueRejectsListenAndReleasesAdmission() throws {
        let server = makeServer()
        let queue = OutboundQueue(budgetBytes: 512)
        let connection = server.connect(to: queue)
        let existingFrame = [UInt8](repeating: 32, count: 513)
        try #require(queue.enqueue(existingFrame, key: nil, urgent: false, replacesProgress: false))
        try #require(queue.isOverBudget)

        connection.receive(listenRequest(uri: "test://refused"))

        let rejectedOutput = queue.takeAvailable()
        try #require(rejectedOutput.count == 2)
        #expect(rejectedOutput.contains(existingFrame))
        try expectRejection(rejectedOutput.filter { $0 != existingFrame }, code: -31001)
        for _ in rejectedOutput {
            queue.didWrite()
        }
        #expect(!queue.isOverBudget)
        #expect(!connection.hasOverflowed)

        try expectRecovery(server: server, connection: connection, takeFrames: queue.takeAvailable)
    }

    @Test
    func ordinarySinkRefusalRejectsListenEvenWhenCapacityIsReported() throws {
        let server = makeServer()
        let sink = RefusingSink()
        let connection = server.connect(to: sink)
        #expect(!sink.isOverBudget)

        connection.receive(listenRequest(uri: "test://refused"))

        #expect(sink.refusedOrdinaryFrames == 1)
        try expectRejection(sink.takeFrames(), code: -31001)
        #expect(!connection.hasOverflowed)

        sink.acceptOrdinaryFrames()
        try expectRecovery(server: server, connection: connection, takeFrames: sink.takeFrames)
    }

    @Test
    func oversizedAcknowledgmentRejectsListen() throws {
        let server = makeServer(maxResponseBytes: 32)
        let queue = OutboundQueue(budgetBytes: 512)
        let connection = server.connect(to: queue)

        connection.receive(listenRequest(uri: "test://refused"))

        let rejectedOutput = queue.takeAvailable()
        try expectRejection(rejectedOutput, code: -31002)
        for _ in rejectedOutput {
            queue.didWrite()
        }
        server.notifyResourceUpdated(uri: "test://refused")
        #expect(queue.takeAvailable().isEmpty)
        #expect(!connection.hasOverflowed)
    }

    private func makeServer(maxResponseBytes: Int = 4096) -> Server {
        Server(name: "Listen contract test", version: "1.0") { configuration in
            configuration.budgets.maxResponseBytes = maxResponseBytes
            configuration.budgets.maxSubscriptions = 1
            configuration.budgets.maxSubscribedResources = 1
            configuration.diagnostics = { _ in }
        }
    }

    private func listenRequest(uri: JSONValue) -> [UInt8] {
        let request: JSONValue = [
            "jsonrpc": "2.0",
            "id": 41,
            "method": "subscriptions/listen",
            "params": [
                "notifications": ["resourceSubscriptions": [uri]],
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": [:],
                ],
            ],
        ]
        return request.encoded()
    }

    private func expectRejection(_ frames: [[UInt8]], code: JSONValue) throws {
        try #require(frames.count == 1)
        let response = try JSON.parse(frames[0])
        #expect(response["jsonrpc"]?.stringValue == "2.0")
        #expect(response["id"]?.intValue == 41)
        #expect(response["error"]?["code"] == code)
        #expect(response["result"] == nil)
        #expect(response["method"] == nil)
    }

    private func expectRecovery(
        server: Server,
        connection: Connection,
        takeFrames: () -> [[UInt8]]
    ) throws {
        server.notifyResourceUpdated(uri: "test://refused")
        #expect(takeFrames().isEmpty)

        connection.receive(listenRequest(uri: "test://accepted"))
        server.notifyResourceUpdated(uri: "test://refused")
        server.notifyResourceUpdated(uri: "test://accepted")

        let frames = takeFrames()
        try #require(frames.count == 2)
        let acknowledgment = try JSON.parse(frames[0])
        #expect(acknowledgment["method"]?.stringValue == "notifications/subscriptions/acknowledged")
        #expect(acknowledgment["params"]?["_meta"]?["io.modelcontextprotocol/subscriptionId"]?.intValue == 41)

        let event = try JSON.parse(frames[1])
        #expect(event["method"]?.stringValue == "notifications/resources/updated")
        #expect(event["params"]?["uri"]?.stringValue == "test://accepted")
    }
}

private final class RefusingSink: FrameSink {
    private struct State {
        var acceptsOrdinaryFrames = false
        var refusedOrdinaryFrames = 0
        var frames: [[UInt8]] = []
    }

    private let state = Mutex(State())

    var isOverBudget: Bool { false }

    var refusedOrdinaryFrames: Int {
        state.withLock { $0.refusedOrdinaryFrames }
    }

    func enqueue(
        _ frame: [UInt8],
        key: RequestID?,
        urgent: Bool,
        replacesProgress: Bool
    ) -> Bool {
        state.withLock { state in
            guard urgent || state.acceptsOrdinaryFrames else {
                state.refusedOrdinaryFrames += 1
                return false
            }
            state.frames.append(frame)
            return true
        }
    }

    func waitForCapacity() async {}

    func discard(key: RequestID) {}

    func acceptOrdinaryFrames() {
        state.withLock { $0.acceptsOrdinaryFrames = true }
    }

    func takeFrames() -> [[UInt8]] {
        state.withLock { state in
            let frames = state.frames
            state.frames.removeAll()
            return frames
        }
    }
}
