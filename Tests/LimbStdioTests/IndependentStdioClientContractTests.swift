#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Limb
import Testing

extension IndependentStdioTransportTests {
    @Test(arguments: [IndependentStdioClient.Channel.pipes, .socketpair])
    func theFixtureHandlesAPeerClosingItsInput(channel: IndependentStdioClient.Channel) throws {
        let server = Server(name: "fixture-contract", version: "1")
        let client = IndependentStdioClient(server, channel: channel)
        defer { _ = client.tearDown(wait: 0) }

        let originalMask = try currentMask()
        let bytes: [UInt8] = [0x61, 0x62, 0x63]
        try #require(client.send(bytes))
        var received = Array(repeating: UInt8(0), count: bytes.count)
        #expect(read(client.serverInput, &received, bytes.count) == bytes.count)
        #expect(received == bytes)

        client.disownServerEnds()
        // For a socketpair the two server descriptors are the same socket.
        if client.serverOutput != client.serverInput { close(client.serverOutput) }
        try #require(close(client.serverInput) == 0)
        #expect(!client.send(bytes, timeout: 1))
        var unchanged = try currentMask()
        var original = originalMask
        #expect(sigismember(&unchanged, SIGPIPE) == sigismember(&original, SIGPIPE))
    }

    private func currentMask() throws -> sigset_t {
        var mask = sigset_t()
        try #require(pthread_sigmask(SIG_BLOCK, nil, &mask) == 0)
        return mask
    }
}
