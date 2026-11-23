#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Limb
import Testing

private func logFrame(_ value: String) -> [UInt8] {
    Array((#"{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"error","data":"\#(value)"}}"# + "\n").utf8)
}

private let independentReply = Array((#"{"jsonrpc":"2.0","id":2,"result":{}}"# + "\n").utf8)

@Suite struct IndependentStdioWriterCancellationContractTests {
    @Test(arguments: [false, true])
    func cancellationWithdrawsASelectedFrameBeforeAnyByteIsWritten(attemptWouldBlock: Bool) throws {
        let queue = OutboundQueue(budgetBytes: 4096)
        let selected = logFrame("selected")
        try #require(queue.enqueue(selected, key: 1))
        try #require(queue.enqueue(logFrame("still queued"), key: 1))
        try #require(queue.enqueue(independentReply, key: 2))

        let lease = try #require(queue.takeFrame())
        if attemptWouldBlock {
            let attempt = queue.writeIfCurrent(lease) { bytes in
                #expect(Array(bytes) == selected)
                return -1
            }
            try #require(attempt == -1)
        }

        queue.discard(key: 1)
        queue.close()
        #expect(queue.usage.ordinaryBytes == independentReply.count)

        let rejected = queue.writeIfCurrent(lease) { _ in
            Issue.record("The writer was offered bytes from the cancelled request")
            return 1
        }
        #expect(rejected == nil)

        let next = try #require(queue.takeFrame())
        let written = queue.writeIfCurrent(next) { bytes in
            #expect(Array(bytes) == independentReply)
            return bytes.count
        }
        try #require(written == independentReply.count)
        queue.didWrite(bytes: independentReply.count)
        #expect(queue.takeFrame() == nil)
        #expect(queue.usage.ordinaryBytes == 0)
    }

    @Test func cancellationPreservesAFrameOnceItsFirstByteIsWritten() throws {
        let queue = OutboundQueue(budgetBytes: 4096)
        let first = logFrame("started")
        try #require(queue.enqueue(first, key: 1))
        try #require(queue.enqueue(logFrame("still queued"), key: 1))
        try #require(queue.enqueue(independentReply, key: 2))

        var output: [UInt8] = []
        var remainder: [UInt8] = []
        let lease = try #require(queue.takeFrame())
        let firstWrite = queue.writeIfCurrent(lease) { bytes in
            output.append(contentsOf: bytes.prefix(1))
            remainder = Array(bytes.dropFirst())
            return output.count
        }
        try #require(firstWrite == 1)

        queue.discard(key: 1)
        queue.close()
        #expect(queue.usage.ordinaryBytes == first.count + independentReply.count)

        // Complete the committed frame before taking any more output from the queue.
        output.append(contentsOf: remainder)
        queue.didWrite(bytes: first.count)
        let next = try #require(queue.takeFrame())
        let written = queue.writeIfCurrent(next) { bytes in
            output.append(contentsOf: bytes)
            return bytes.count
        }
        try #require(written == independentReply.count)
        queue.didWrite(bytes: independentReply.count)

        #expect(output == first + independentReply)
        #expect(queue.takeFrame() == nil)
        #expect(queue.usage.ordinaryBytes == 0)
    }
}

extension IndependentStdioTransportTests {
    @Test(arguments: [false, true])
    func cancellationAtTheStdioWriteBoundary(firstByteWritten: Bool) throws {
        let fixture = try independentStdioFixture()
        let selected = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let pause: @Sendable ([UInt8]) -> Void = { bytes in
            guard String(decoding: bytes, as: UTF8.self).contains("chatty-cancelled-0 ") else { return }
            selected.signal()
            if resume.wait(timeout: .now() + 20) == .timedOut {
                Issue.record("The test did not release the stdio writer")
            }
        }
        let client = IndependentStdioClient(fixture.server).start { transport in
            if firstByteWritten {
                transport.afterFirstByte = pause
            } else {
                transport.beforeKeyedWrite = pause
            }
        }
        defer {
            resume.signal()
            fixture.probe.release()
            client.tearDown()
        }
        try #require(client.initialize() == "2025-11-25")
        var expectedByteCount = client.bytesRead

        func readMessage() throws -> [String: Any] {
            let received = client.readLine(timeout: 5)
            let line = try #require(received)
            expectedByteCount += line.count + 1
            return try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }

        typealias Client = IndependentStdioClient
        try #require(client.send(Client.callLine(1, "chatty", #"{"tag":"cancelled","count":2}"#), timeout: 5, absorb: false))
        try #require(selected.wait(timeout: .now() + 5) == .success, "The writer did not reach the requested boundary")
        try #require(fixture.probe.eventually(seconds: 5) { $0.finishedTags.contains("logged-cancelled") })
        let bytesAtBoundary = client.absorb(limit: 4096)
        #expect(bytesAtBoundary == (firstByteWritten ? 1 : 0))

        try #require(client.send(Client.cancelLine(1), timeout: 5, absorb: false))
        try #require(fixture.probe.eventually(seconds: 5) { $0.cancelledTags == ["cancelled"] })
        try #require(client.send(Client.callLine(2, "echo", #"{"text":"independent"}"#), timeout: 5, absorb: false))
        resume.signal()

        if firstByteWritten {
            let notification = try readMessage()
            #expect(notification["method"] as? String == "notifications/message")
            #expect((notification["params"] as? [String: Any])?["data"] as? String == "chatty-cancelled-0 ")
        }
        let response = try readMessage()
        #expect(Client.id(of: response) == 2)
        #expect(Client.text(of: response) == "independent")

        client.closeInput()
        try #require(client.stopped(within: 5))
        client.disownServerEnds()
        close(client.serverInput)
        close(client.serverOutput)
        #expect(client.readLine(timeout: 5) == nil)
        #expect(client.sawEndOfOutput)
        #expect(client.bytesRead == expectedByteCount)
        #expect(client.violations.isEmpty)
    }
}
