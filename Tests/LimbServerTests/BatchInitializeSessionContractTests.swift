import Limb
import Testing

struct BatchInitializeSessionContractTests {
    private let legacyVersion = "2025-03-26"
    private let laterVersion = "2025-06-18"
    private let resourceURI = "test://batch-initialize/subscribed"
    private let instructions = String(repeating: "i", count: 700)

    @Test
    func overloadedBatchInitializePreservesLegacySession() throws {
        let server = try makeServer()
        let queue = OutboundQueue(budgetBytes: 256, urgentReserveBytes: 512)
        let connection = server.connect(to: queue)
        try establishSession(connection, queue: queue, version: legacyVersion)
        try subscribe(connection, queue: queue)

        try expectOverloadedInitialize(connection, queue: queue)

        try expectLegacyBatchAccepted(connection, queue: queue)
        try expectSubscriptionRetained(server, queue: queue)
    }

    @Test
    func overloadedBatchInitializePreservesNegotiatedCapabilities() async throws {
        let server = try makeServer()
        try server.register(tool: ToolDefinition(name: "has-roots")) { _, context in
            .text(context.clientCapabilities.supportsRoots ? "true" : "false")
        }
        let queue = OutboundQueue(budgetBytes: 256, urgentReserveBytes: 512)
        let connection = server.connect(to: queue)
        try establishSession(connection, queue: queue, version: legacyVersion, clientCapabilities: ["roots": [:]])

        server.removeResource(uri: resourceURI)
        _ = drain(queue)
        try expectOverloadedInitialize(connection, queue: queue)

        let list: JSONValue = ["jsonrpc": "2.0", "id": 4, "method": "resources/list"]
        connection.receive(list.encoded())
        let listReply = try takeReply(queue)
        #expect(listReply["id"]?.intValue == 4)
        #expect(listReply["result"]?["resources"]?.arrayValue?.isEmpty == true)

        connection.receive(toolCall(id: 5, name: "has-roots").encoded())
        let rootsReply = try await waitForReply(queue)
        #expect(rootsReply["id"]?.intValue == 5)
        #expect(rootsReply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "true")
    }

    @Test
    func oversizedBatchResponsePreservesLegacySession() throws {
        let calibrationServer = try makeServer()
        let legacyQueue = OutboundQueue(budgetBytes: 4_096)
        let laterQueue = OutboundQueue(budgetBytes: 4_096)
        let legacyReplySize = try establishSession(
            calibrationServer.connect(to: legacyQueue), queue: legacyQueue, version: legacyVersion
        )
        let laterReplySize = try establishSession(
            calibrationServer.connect(to: laterQueue), queue: laterQueue, version: laterVersion
        )

        let maxResponseBytes = max(legacyReplySize, laterReplySize) + 24
        let server = try makeServer(maxResponseBytes: maxResponseBytes)
        let queue = OutboundQueue(budgetBytes: 4_096)
        let connection = server.connect(to: queue)
        try establishSession(connection, queue: queue, version: legacyVersion)
        try subscribe(connection, queue: queue)

        let batch: JSONValue = [initialize(id: 2, version: laterVersion), ping(id: 3), ping(id: 4)]
        connection.receive(batch.encoded())

        let replies = try indexedReplies(takeReply(queue), ids: [2, 3, 4])
        #expect(replies[2]?["error"]?["code"]?.intValue == -31002)
        #expect(replies[3]?["result"] != nil)
        #expect(replies[4]?["result"] != nil)
        #expect(!connection.hasOverflowed)

        try expectLegacyBatchAccepted(connection, queue: queue)
        try expectSubscriptionRetained(server, queue: queue)
    }

    @Test
    func successfulBatchInitializeSelectsNewVersionForLaterFrames() throws {
        let server = try makeServer()
        let queue = OutboundQueue(budgetBytes: 4_096)
        let connection = server.connect(to: queue)
        try establishSession(connection, queue: queue, version: legacyVersion)

        let initializeBatch: JSONValue = [initialize(id: 2, version: laterVersion), ping(id: 3)]
        connection.receive(initializeBatch.encoded())
        let replies = try indexedReplies(takeReply(queue), ids: [2, 3])
        #expect(replies[2]?["result"]?["protocolVersion"]?.stringValue == laterVersion)
        #expect(replies[3]?["result"] != nil)

        let laterBatch: JSONValue = [ping(id: 4), ping(id: 5)]
        connection.receive(laterBatch.encoded())
        let rejectedBatch = try takeReply(queue)
        #expect(rejectedBatch["id"]?.isNull == true)
        #expect(rejectedBatch["error"]?["code"]?.intValue == -32600)

        connection.receive(ping(id: 6).encoded())
        let singleReply = try takeReply(queue)
        #expect(singleReply["id"]?.intValue == 6)
        #expect(singleReply["result"] != nil)
    }

    @Test
    func batchInitializeChangesVersionAfterAsyncSiblingReplies() async throws {
        let server = try makeServer()
        let gate = ToolGate()
        defer { Task { await gate.open() } }
        try registerGatedTool(on: server, gate: gate)
        let queue = OutboundQueue(budgetBytes: 4_096)
        let connection = server.connect(to: queue)
        try establishSession(connection, queue: queue, version: legacyVersion)

        let initializeBatch: JSONValue = [initialize(id: 2, version: laterVersion), toolCall(id: 3, name: "wait")]
        connection.receive(initializeBatch.encoded())
        try await waitUntilToolStarts(gate)

        let probe: JSONValue = [ping(id: 7), ping(id: 8)]
        connection.receive(probe.encoded())
        let beforeJoin = try indexedReplies(await waitForReply(queue), ids: [7, 8])
        #expect(beforeJoin[7]?["result"] != nil)
        #expect(beforeJoin[8]?["result"] != nil)

        await gate.open()
        let joined = try indexedReplies(await waitForReply(queue), ids: [2, 3])
        #expect(joined[2]?["result"]?["protocolVersion"]?.stringValue == laterVersion)
        #expect(joined[3]?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "ok")

        connection.receive(probe.encoded())
        let afterJoin = try await waitForReply(queue)
        #expect(afterJoin["id"]?.isNull == true)
        #expect(afterJoin["error"]?["code"]?.intValue == -32600)
    }

    @Test
    func batchInitializeChangesVersionAfterAsyncSiblingIsCancelled() async throws {
        let server = try makeServer()
        let gate = ToolGate()
        defer { Task { await gate.open() } }
        try registerGatedTool(on: server, gate: gate)
        let queue = OutboundQueue(budgetBytes: 4_096)
        let connection = server.connect(to: queue)
        try establishSession(connection, queue: queue, version: legacyVersion)

        let batch: JSONValue = [initialize(id: 2, version: laterVersion), toolCall(id: 3, name: "wait")]
        connection.receive(batch.encoded())
        try await waitUntilToolStarts(gate)
        try expectLegacyBatchAccepted(connection, queue: queue)

        let cancel: JSONValue = [
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 3],
        ]
        connection.receive(cancel.encoded())

        let joined = try indexedReplies(await waitForReply(queue), ids: [2])
        #expect(joined[2]?["result"]?["protocolVersion"]?.stringValue == laterVersion)

        let probe: JSONValue = [ping(id: 4), ping(id: 5)]
        connection.receive(probe.encoded())
        let afterJoin = try await waitForReply(queue)
        #expect(afterJoin["id"]?.isNull == true)
        #expect(afterJoin["error"]?["code"]?.intValue == -32600)
    }

    private func expectOverloadedInitialize(_ connection: Connection, queue: OutboundQueue) throws {
        let outstandingNotification: JSONValue = [
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": ["data": .string(String(repeating: "x", count: 256)), "level": "info"],
        ]
        let outstandingFrame = outstandingNotification.encoded()
        try #require(queue.enqueue(outstandingFrame))
        try #require(queue.isOverBudget)

        let batch: JSONValue = [initialize(id: 2, version: laterVersion), ping(id: 3)]
        connection.receive(batch.encoded())

        let replyFrames = drain(queue).filter { $0 != outstandingFrame }
        try #require(replyFrames.count == 1)
        let wireReply = try #require(replyFrames.first)
        let replies = try indexedReplies(JSON.parse(wireReply), ids: [2, 3])
        #expect(replies[2]?["error"]?["code"]?.intValue == -31001)
        #expect(!connection.hasOverflowed)
    }

    private func registerGatedTool(on server: Server, gate: ToolGate) throws {
        try server.register(tool: ToolDefinition(name: "wait")) { _, _ in
            await gate.wait()
            return .text("ok")
        }
    }

    private func waitUntilToolStarts(_ gate: ToolGate) async throws {
        let clock = ContinuousClock()
        let toolStartDeadline = clock.now + .seconds(2)
        while clock.now < toolStartDeadline, await !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        let toolStarted = await gate.hasStarted
        try #require(toolStarted)
    }

    private actor ToolGate {
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var hasStarted = false

        func wait() async {
            hasStarted = true
            guard !isOpen else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func waitForReply(_ queue: OutboundQueue) async throws -> JSONValue {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        var frames = drain(queue)
        while frames.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            frames = drain(queue)
        }
        try #require(frames.count == 1)
        return try JSON.parse(#require(frames.first))
    }

    private func makeServer(maxResponseBytes: Int? = nil) throws -> Server {
        let server = Server(name: "Batch initialize test", version: "1") { configuration in
            configuration.instructions = instructions
            if let maxResponseBytes {
                configuration.budgets.maxResponseBytes = maxResponseBytes
            }
        }
        try server.register(resource: ResourceDefinition(uri: resourceURI, name: "Subscribed resource")) { request, _ in
            [.text(uri: request.uri, text: "")]
        }
        return server
    }

    @discardableResult
    private func establishSession(
        _ connection: Connection,
        queue: OutboundQueue,
        version: String,
        clientCapabilities: JSONValue = [:]
    ) throws -> Int {
        connection.receive(initialize(id: 1, version: version, clientCapabilities: clientCapabilities).encoded())
        let frames = drain(queue)
        try #require(frames.count == 1)
        let frame = try #require(frames.first)
        let reply = try JSON.parse(frame)
        try #require(reply["id"]?.intValue == 1)
        try #require(reply["result"]?["protocolVersion"]?.stringValue == version)

        let initialized: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        connection.receive(initialized.encoded())
        try #require(drain(queue).isEmpty)
        return frame.count
    }

    private func subscribe(_ connection: Connection, queue: OutboundQueue) throws {
        let request: JSONValue = [
            "jsonrpc": "2.0",
            "id": 9,
            "method": "resources/subscribe",
            "params": ["uri": .string(resourceURI)],
        ]
        connection.receive(request.encoded())

        let reply = try takeReply(queue)
        try #require(reply["id"]?.intValue == 9)
        try #require(reply["result"] != nil)
    }

    private func expectSubscriptionRetained(_ server: Server, queue: OutboundQueue) throws {
        server.notifyResourceUpdated(uri: resourceURI)
        let notification = try takeReply(queue)
        #expect(notification["method"]?.stringValue == "notifications/resources/updated")
        #expect(notification["params"]?["uri"]?.stringValue == resourceURI)
    }

    private func expectLegacyBatchAccepted(_ connection: Connection, queue: OutboundQueue) throws {
        let batch: JSONValue = [ping(id: 7), ping(id: 8)]
        connection.receive(batch.encoded())

        let replies = try indexedReplies(takeReply(queue), ids: [7, 8])
        #expect(replies[7]?["result"] != nil)
        #expect(replies[8]?["result"] != nil)
    }

    private func initialize(id: Int, version: String, clientCapabilities: JSONValue = [:]) -> JSONValue {
        [
            "jsonrpc": "2.0",
            "id": JSONValue(integerLiteral: Int64(id)),
            "method": "initialize",
            "params": [
                "protocolVersion": .string(version),
                "capabilities": clientCapabilities,
                "clientInfo": ["name": "Local test", "version": "1"],
            ],
        ]
    }

    private func toolCall(id: Int, name: String) -> JSONValue {
        [
            "jsonrpc": "2.0",
            "id": JSONValue(integerLiteral: Int64(id)),
            "method": "tools/call",
            "params": ["name": .string(name), "arguments": [:]],
        ]
    }

    private func ping(id: Int) -> JSONValue {
        ["jsonrpc": "2.0", "id": JSONValue(integerLiteral: Int64(id)), "method": "ping"]
    }

    private func takeReply(_ queue: OutboundQueue) throws -> JSONValue {
        let frames = drain(queue)
        try #require(frames.count == 1)
        return try JSON.parse(#require(frames.first))
    }

    private func drain(_ queue: OutboundQueue) -> [[UInt8]] {
        let frames = queue.takeAvailable()
        if !frames.isEmpty {
            queue.didWrite()
        }
        return frames
    }

    private func indexedReplies(_ value: JSONValue, ids: [Int]) throws -> [Int: JSONValue] {
        let replies = try #require(value.arrayValue)
        try #require(replies.count == ids.count)
        var indexed: [Int: JSONValue] = [:]
        for reply in replies {
            let id = try #require(reply["id"]?.intValue)
            try #require(indexed[id] == nil)
            indexed[id] = reply
        }
        try #require(Set(indexed.keys) == Set(ids))
        return indexed
    }
}
