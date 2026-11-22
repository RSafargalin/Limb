import Limb
import Testing

struct RequestIDEncodingContractTests {
    // Content costs 1 + 2 + 2 + 2 + 6 + 2 UTF-8 bytes on the wire.
    private let exactID = "a\"\\\n\u{0001}é"
    private let limit = 15

    private func makeServer() -> Server {
        Server(name: "Request ID tests", version: "1") { configuration in
            configuration.budgets.maxRequestIDBytes = limit
            configuration.diagnostics = { _ in }
        }
    }

    private func ping(id: String) -> [UInt8] {
        let frame: JSONValue = [
            "jsonrpc": "2.0",
            "id": .string(id),
            "method": "ping",
        ]
        return frame.encoded()
    }

    private func invalidRequest(id: String) -> [UInt8] {
        let frame: JSONValue = [
            "jsonrpc": "2.0",
            "id": .string(id),
            "method": 17,
        ]
        return frame.encoded()
    }

    private func expectInvalidRequest(_ reply: JSONValue) {
        #expect(reply["error"]?["code"]?.intValue == -32600)
        #expect(reply["id"]?.isNull == true)
    }

    @Test func escapedIDAtLimitIsPreservedInSuccess() throws {
        let queue = OutboundQueue(budgetBytes: 1024)
        let server = makeServer()
        let connection = server.connect(to: queue)
        connection.receive(ping(id: exactID))

        let reply = try takeReply(from: queue)
        #expect(reply["id"]?.stringValue == exactID)
        #expect(reply["result"] != nil)
    }

    @Test func escapedIDOneByteOverLimitIsRejected() throws {
        let queue = OutboundQueue(budgetBytes: 1024)
        let server = makeServer()
        let connection = server.connect(to: queue)
        connection.receive(ping(id: exactID + "b"))

        try expectInvalidRequest(takeReply(from: queue))
    }

    @Test func malformedRequestNeverEchoesOverLimitID() throws {
        let queue = OutboundQueue(budgetBytes: 1024)
        let server = makeServer()
        let connection = server.connect(to: queue)
        connection.receive(invalidRequest(id: exactID + "b"))

        try expectInvalidRequest(takeReply(from: queue))
    }

    @Test func escapedIDAtLimitIsPreservedInOrdinaryError() throws {
        let queue = OutboundQueue(budgetBytes: 1024)
        let server = makeServer()
        let connection = server.connect(to: queue)
        connection.receive(Array(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8))
        let initialized = try takeReply(from: queue)
        try #require(initialized["result"] != nil)
        connection.receive(Array(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))

        let request: JSONValue = [
            "jsonrpc": "2.0",
            "id": .string(exactID),
            "method": "test/unknown",
        ]
        connection.receive(request.encoded())

        let reply = try takeReply(from: queue)
        #expect(reply["error"]?["code"]?.intValue == -32601)
        #expect(reply["id"]?.stringValue == exactID)
    }

    @Test func numericIDUsesAllEmittedDigits() throws {
        let queue = OutboundQueue(budgetBytes: 1024)
        let server = makeServer()
        let connection = server.connect(to: queue)
        connection.receive(Array(#"{"jsonrpc":"2.0","id":123456789012345,"method":"ping"}"#.utf8))

        let accepted = try takeReply(from: queue)
        #expect(accepted["id"]?.intValue == 123456789012345)
        #expect(accepted["result"] != nil)

        connection.receive(Array(#"{"jsonrpc":"2.0","id":1234567890123456,"method":"ping"}"#.utf8))

        try expectInvalidRequest(takeReply(from: queue))
    }

    @Test func overLimitIDGetsBoundedReplyWhileReaderIsBehind() throws {
        let queuedFrame = Array(#"{"jsonrpc":"2.0","id":0,"result":{}}"#.utf8)
        let reserve = 256
        let queue = OutboundQueue(budgetBytes: queuedFrame.count - 1, urgentReserveBytes: reserve)
        let server = makeServer()
        let connection = server.connect(to: queue)
        try #require(queue.enqueue(queuedFrame))
        try #require(queue.isOverBudget)

        connection.receive(ping(id: exactID + "b"))

        #expect(!connection.hasOverflowed)
        let frames = queue.takeAvailable()
        queue.didWrite()
        try #require(frames.count == 2)
        let errorFrame = try #require(frames.first { $0 != queuedFrame })
        #expect(errorFrame.count <= reserve)
        try expectInvalidRequest(JSON.parse(errorFrame))
    }

    private func takeReply(from queue: OutboundQueue) throws -> JSONValue {
        let frames = queue.takeAvailable()
        queue.didWrite()
        try #require(frames.count == 1)
        let frame = try #require(frames.first)
        return try JSON.parse(frame)
    }
}
