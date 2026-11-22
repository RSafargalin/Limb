#if FoundationJSON
import Limb
import LimbTesting
import Testing

/// The fallback codec behind a real connection: the same frames a peer could send, checked at
/// the point where the server answers them. The codec itself is covered in LimbCoreTests.
@Suite struct FoundationCodecServerTests {
    /// Frames that would kill the process inside Foundation, or that Foundation would decode
    /// although the protocol forbids them, are answered as parse errors — and the connection
    /// keeps working afterwards.
    @Test func hostileFramesAreParseErrors() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize()
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let deepParams =
            #"{"jsonrpc":"2.0","id":1,"method":"ping","params":"#
            + String(repeating: "[", count: 200) + String(repeating: "]", count: 200) + "}"
        let frames: [(name: String, frame: String)] = [
            ("bottomless arrays", String(repeating: "[", count: 200_000)),
            ("bottomless objects", String(repeating: "{\"a\":", count: 200_000)),
            ("nesting hidden behind a stray quote", "[1 \"" + String(repeating: "[", count: 200_000)),
            ("deep params in a valid request", deepParams),
            ("byte order mark", "\u{FEFF}" + ping),
            ("UTF-16", String(decoding: ping.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }, as: UTF8.self)),
            ("a zero byte after the message", ping + "\u{0}"),
            ("a number out of range", #"{"jsonrpc":"2.0","id":1e400,"method":"ping"}"#),
            // Valid JSON the fallback cannot read: documented differences, not attacks.
            ("a number Foundation refuses", #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"n":1.2345678901234567890123e200}}"#),
            ("a string that starts with U+FEFF", #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"s":"\ufeffx"}}"#),
            ("a key that starts with U+FEFF", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"\u{FEFF}k\":1}}"),
        ]
        for (name, frame) in frames {
            client.send(frame)
            let response = try await client.next()
            #expect(response.errorCode == -32700, "\(name)")
            #expect(response["id"] == .null, "\(name)")
            // Still alive, and still in step: the next request gets its own answer.
            #expect(try await client.request("tools/call", ["name": "echo", "arguments": ["text": .string(name)]]).firstText == name)
        }
    }

    /// What Foundation forgives is served, not refused: the documented price of the fallback.
    @Test func trailingCommasAreServed() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize()
        client.send(#"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi",},},}"#)
        let response = try await client.next()
        #expect(response["id"] == 41)
        #expect(response.firstText == "hi")
    }

    /// Text goes through Foundation in both directions and comes back unchanged.
    @Test(arguments: [
        "plain", "", "line\nbreak\r\n\ttab", "quote \" backslash \\ slash /", "\u{0}\u{1}\u{1F}\u{7F}",
        "é vs e\u{301}", "中文 😀 👨‍👩‍👧", "\u{2028}\u{2029}", "[{\"not\":\"json\"}]", "1e400", "data:text/plain;base64,aGk=",
        "inner\u{FEFF}mark", "trailing mark\u{FEFF}", "\\ufeff is six characters", "\u{FFFE}reversed mark first",
    ])
    func textSurvivesTheRoundTrip(_ text: String) async throws {
        let client = TestClient(try makeServer())
        let response = try await client.request("tools/call", ["name": "echo", "arguments": ["text": .string(text)]])
        #expect(response.result?["content"]?[0]?["text"] == .string(text))
    }

    /// The other side of refusing strings that start with U+FEFF: the server still writes them —
    /// a tool may return the contents of a file that begins with a byte order mark, and the frame
    /// is valid JSON. `TestClient` reads frames with the same fallback codec, so in this build it
    /// cannot read that one and reports it as invalid output. Pinned so the limitation is known.
    @Test func aResultStartingWithAByteOrderMarkIsWrittenButNotReadable() async throws {
        let server = try makeServer()
        try server.register(tool: ToolDefinition(name: "bom")) { _, _ in .text("\u{FEFF}from a file") }
        try server.register(tool: ToolDefinition(name: "inner")) { _, _ in .text("from a\u{FEFF} file") }
        let client = TestClient(server)
        // In the middle of the text there is nothing special about it.
        #expect(try await client.request("tools/call", ["name": "inner"]).firstText == "from a\u{FEFF} file")
        client.post("tools/call", ["name": "bom"])
        await #expect(throws: TestClientError.self) { try await client.next() }
        // The connection itself is unharmed.
        #expect(try await client.request("tools/call", ["name": "echo", "arguments": ["text": "still here"]]).firstText == "still here")
    }

    /// Booleans and numbers arrive at the schema validator as what they were sent as.
    @Test func booleansAreNotNumbersForValidation() async throws {
        let client = TestClient(try makeServer(), modern: false)
        try await client.initialize()
        client.send(#"{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"add","arguments":{"a":1,"b":2}}}"#)
        let sum = try await client.next()
        #expect(sum.result?["structuredContent"]?["sum"] == 3)
        client.send(#"{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"add","arguments":{"a":true,"b":2}}}"#)
        let refused = try await client.next()
        #expect(refused["id"] == 52)
        #expect(refused.errorCode != nil || refused.result?["isError"] == true)
    }
}
#endif
