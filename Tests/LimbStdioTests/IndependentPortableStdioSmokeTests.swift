#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Limb
import Testing

struct IndependentPortableStdioSmokeTests {
    enum ProtocolEra: CaseIterable {
        case modern
        case legacy
    }

    @Test(arguments: ProtocolEra.allCases)
    func discoversOrInitializesAndCallsToolOverPipes(_ era: ProtocolEra) async throws {
        let server = Server(name: "stdio-smoke", version: "1")
        try server.register(tool: ToolDefinition(name: "echo", inputSchema: ["type": "object"])) { arguments, _ in
            .text(arguments["text"]?.stringValue ?? "")
        }

        let input = Pipe()
        let output = Pipe()
        let transport = StdioTransport(input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
        let worker = Task.detached {
            // Keep both server descriptors alive until run returns, including on test failure.
            defer { withExtendedLifetime(input) {} }
            await server.run(transport)
            try? output.fileHandleForWriting.close()
        }
        defer {
            try? input.fileHandleForWriting.close()
            worker.cancel()
        }

        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        let arguments = #""name":"echo","arguments":{"text":"portable\nstdio"}"#
        let callParameters: String
        switch era {
        case .modern:
            try send(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{\#(meta)}}"#, to: input)
            let result = try response(id: 1, from: output)
            #expect(result["supportedVersions"]?[0] == "2026-07-28")
            callParameters = "{\(meta),\(arguments)}"
        case .legacy:
            try send(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke-client","version":"1"}}}"#,
                to: input)
            let result = try response(id: 1, from: output)
            #expect(result["protocolVersion"] == "2025-11-25")
            #expect(result["serverInfo"]?["name"] == "stdio-smoke")
            try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, to: input)
            callParameters = "{\(arguments)}"
        }

        try send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":\#(callParameters)}"#, to: input)
        let result = try response(id: 2, from: output)
        #expect(result["content"]?[0]?["type"] == "text")
        #expect(result["content"]?[0]?["text"] == "portable\nstdio")

        try input.fileHandleForWriting.close()
        // The task closes the output writer only after run returns.
        #expect(try readChunk(from: output, before: ContinuousClock.now + .seconds(5)).isEmpty)
    }

    private func send(_ message: String, to input: Pipe) throws {
        // These fixed requests (including the legacy notification) fit in an empty POSIX pipe.
        try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
    }

    private func response(id: Int, from output: Pipe) throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(5)
        var bytes: [UInt8] = []
        while !bytes.contains(0x0A) {
            let chunk = try readChunk(from: output, before: deadline)
            try #require(!chunk.isEmpty, "stdio ended before the response to request \(id)")
            bytes.append(contentsOf: chunk)
            try #require(bytes.count <= 65_536, "Unexpectedly large smoke-test response")
        }
        try #require(bytes.firstIndex(of: 0x0A) == bytes.count - 1, "Expected one newline-delimited response")
        let message = try JSON.parse(Array(bytes.dropLast()))
        #expect(message["jsonrpc"] == "2.0")
        #expect(message["id"]?.intValue == id)
        return try #require(message["result"])
    }

    private func readChunk(from output: Pipe, before deadline: ContinuousClock.Instant) throws -> [UInt8] {
        let fd = output.fileHandleForReading.fileDescriptor
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var bytes = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            let ready = poll(&descriptor, 1, 50)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            try #require(ready > 0, "Could not poll the server output")
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            try #require(count >= 0, "Could not read the server output")
            return Array(bytes.prefix(count))
        }
        Issue.record("Timed out waiting for server output")
        throw OutputTimeout()
    }

    private struct OutputTimeout: Error {}
}
#endif
