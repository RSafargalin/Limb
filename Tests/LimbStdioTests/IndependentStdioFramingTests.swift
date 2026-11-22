import Foundation
import Limb
import Testing


private typealias Client = IndependentStdioClient

/// A `tools/call` of `length` whose line (without the terminator) is exactly `bytes` long.
private func paddedCall(id: Int, bytes: Int) -> (line: String, padding: Int) {
    let empty = Client.callLine(id, "length", #"{"text":""}"#).utf8.count - 1
    let padding = bytes - empty
    precondition(padding >= 0)
    var line = Client.callLine(id, "length", #"{"text":"\#(String(repeating: "a", count: padding))"}"#)
    line.removeLast()
    precondition(line.utf8.count == bytes)
    return (line, padding)
}

extension IndependentStdioTransportTests {
    @Suite struct Framing {
        @Test func aRequestSplitAtEveryBytePositionIsAnswered() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            // Multi-byte characters, so some cuts fall inside a UTF-8 sequence.
            let text = "h\u{E9}llo \u{2192} \u{1F600}"
            let sample = Array(Client.callLine(1000, "echo", #"{"text":"\#(text)"}"#).utf8)
            var wrong: [Int] = []
            for cut in 0...sample.count {
                let line = Array(Client.callLine(cut, "echo", #"{"text":"\#(text)"}"#).utf8)
                let at = Swift.min(cut, line.count)
                #expect(client.send(Array(line[..<at])))
                // Long enough for the reader to pick the first part up as its own read.
                usleep(1500)
                #expect(client.send(Array(line[at...])))
                let response = client.readMessage()
                if Client.id(of: response) != cut || Client.text(of: response) != text { wrong.append(cut) }
            }
            #expect(wrong == [], "wrong or missing answers for cuts at \(wrong)")
            #expect(client.violations == [])
            client.closeInput()
            #expect(client.stopped(within: 10))
        }

        @Test func aRequestArrivingOneByteAtATimeIsAnswered() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            for byte in Array(Client.callLine(7, "echo", #"{"text":"slow typist"}"#).utf8) {
                #expect(client.send([byte]))
                usleep(300)
            }
            let response = client.readMessage()
            #expect(Client.id(of: response) == 7)
            #expect(Client.text(of: response) == "slow typist")
        }

        @Test func manyMessagesInOneWriteAreAllAnswered() throws {
            let fixture = try independentStdioFixture { $0.budgets.maxQueuedRequests = 4096 }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let count = 2000
            var bulk = ""
            for id in 1...count { bulk += Client.callLine(id, "echo", #"{"text":"m\#(id)"}"#) }
            #expect(client.send(bulk))
            let answers = client.responses(to: Set(1...count), timeout: 60)
            #expect(answers.count == count)
            let wrong = answers.filter { Client.text(of: $0.value) != "m\($0.key)" }.keys.sorted()
            #expect(wrong == [], "first wrong answer: \(wrong.first.flatMap { answers[$0] }.map { "\($0)" } ?? "")")
            #expect(client.violations == [])
        }

        /// 20 000 lines at once: requests, notifications nobody handles, and blank lines.
        @Test func aHugeBurstOfTinyFramesIsHandled() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let pings = 8000
            var bulk = ""
            for id in 1...pings {
                bulk += Client.requestLine(id, "ping")
                bulk += #"{"jsonrpc":"2.0","method":"notifications/independent"}"# + "\n"
                if id % 2 == 0 { bulk += "\n" }
                if id % 4 == 0 { bulk += "\r\n" }
            }
            #expect(client.send(bulk, timeout: 60))
            var unexpected = 0
            let answers = client.responses(to: Set(1...pings), timeout: 90) { _ in unexpected += 1 }
            #expect(answers.count == pings)
            #expect(answers.values.allSatisfy { $0["result"] != nil })
            #expect(unexpected == 0, "\(unexpected) messages that answer nothing")
            #expect(client.violations == [])
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(client.drain(seconds: 0.2).isEmpty)
        }

        // MARK: Line terminators

        @Test func carriageReturnNewlineEndsAFrameLikeNewline() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var line = Client.callLine(1, "echo", #"{"text":"crlf"}"#)
            line.removeLast()
            #expect(client.send(line + "\r\n"))
            #expect(Client.text(of: client.readMessage()) == "crlf")
            // Split between the carriage return and the newline.
            line = Client.callLine(2, "echo", #"{"text":"split"}"#)
            line.removeLast()
            #expect(client.send(line + "\r"))
            usleep(20_000)
            #expect(client.send("\n"))
            #expect(Client.text(of: client.readMessage()) == "split")
            // The output side uses the newline alone (§6.1 "на выходе — только \n"); `violations`
            // records any carriage return in a line.
            #expect(client.violations == [])
        }

        /// A carriage return that is not followed by a newline does not end a message: the
        /// specification names the newline as the delimiter, and inside a JSON text a carriage
        /// return between tokens is insignificant whitespace (RFC 8259 §2).
        @Test func aLoneCarriageReturnDoesNotSplitAMessage() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(client.send("{\"jsonrpc\":\"2.0\",\r\"id\":1,\r\"method\":\"ping\"}\n"))
            let first = client.readMessage()
            #expect(Client.id(of: first) == 1)
            #expect(first?["result"] != nil)
            // Two carriage returns before the newline: one is the terminator's, one is whitespace.
            #expect(client.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\r\r\n"))
            let second = client.readMessage()
            #expect(Client.id(of: second) == 2)
            #expect(second?["result"] != nil)
            #expect(client.violations == [])
        }

        @Test func emptyLinesProduceNothing() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(client.send("\n\n\r\n\n\r\n" + Client.requestLine(1, "ping") + "\n\r\n\n" + Client.requestLine(2, "ping")))
            #expect(Client.id(of: client.readMessage()) == 1)
            #expect(Client.id(of: client.readMessage()) == 2)
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(client.drain(seconds: 0.2).isEmpty)
            #expect(client.violations == [])
        }

        @Test func whitespaceOnlyLinesDoNotDisturbTheStream() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(client.send("   \n\t\n \r\n" + Client.requestLine(5, "ping")))
            var others: [[String: Any]] = []
            let answers = client.responses(to: [5], timeout: 20) { others.append($0) }
            #expect(answers[5]?["result"] != nil)
            #expect(others.count == 3, "observed: one parse error per whitespace-only line")
            #expect(others.allSatisfy { Client.errorCode(of: $0) == -32700 && Client.isNullID($0) })
            #expect(client.violations == [])
        }

        @Test func endOfInputDiscardsAnUnterminatedFrameAndLogsOnce() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var unterminated = Client.requestLine(2, "ping")
            unterminated.removeLast()
            #expect(client.send(Client.requestLine(1, "ping") + unterminated))
            client.closeInput()
            #expect(client.stopped(within: 10))
            let messages = client.drain(seconds: 1)
            #expect(messages.count == 1)
            #expect(Client.id(of: messages.first) == 1)
            #expect(messages.first?["result"] != nil)
            let diagnostics = fixture.log.all
            #expect(diagnostics.count == 1, "\(diagnostics)")
            #expect(diagnostics.first?.contains("middle of a frame") == true)
            #expect(diagnostics.first?.contains("no newline") == true)
            #expect(client.violations == [])
        }

        // MARK: The frame size limit

        @Test(arguments: [8192, 1 << 20])
        func aFrameOfExactlyTheLimitIsHandledAndOneByteMoreIsRejected(limit: Int) throws {
            let fixture = try independentStdioFixture { $0.budgets.maxFrameBytes = limit }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }

            let exact = paddedCall(id: 1, bytes: limit)
            #expect(client.send(exact.line + "\n"))
            let accepted = client.readMessage()
            #expect(Client.id(of: accepted) == 1)
            #expect(Client.text(of: accepted) == "\(exact.padding)")

            let over = paddedCall(id: 2, bytes: limit + 1)
            #expect(client.send(over.line + "\n"))
            let rejected = client.readMessage()
            #expect(Client.errorCode(of: rejected) == -32600)
            #expect(Client.isNullID(rejected))

            // "the next frame must be handled"
            #expect(client.request(3, "ping"))
            #expect(Client.id(of: client.readMessage()) == 3)
            #expect(client.violations == [])
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(client.drain(seconds: 0.2).isEmpty)
        }

        @Test(arguments: [8192, 1 << 20])
        func aFrameOfExactlyTheLimitIsHandledWithCRLF(limit: Int) throws {
            let fixture = try independentStdioFixture { $0.budgets.maxFrameBytes = limit }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            var rejected: [String] = []
            for (id, pause) in [(1, false), (2, true)] {
                let exact = paddedCall(id: id, bytes: limit)
                if pause {
                    // The carriage return arrives, the newline a moment later.
                    #expect(client.send(exact.line + "\r"))
                    usleep(50_000)
                    #expect(client.send("\n"))
                } else {
                    #expect(client.send(exact.line + "\r\n"))
                }
                let response = client.readMessage()
                if Client.id(of: response) != id || Client.text(of: response) != "\(exact.padding)" {
                    rejected.append("\(pause ? "CR, pause, LF" : "CR LF in one write"): error \(Client.errorCode(of: response).map(String.init) ?? "none")")
                }
            }
            #expect(rejected == [])
        }

        @Test func aVastlyOversizedFrameIsRejectedOnceAndTheNextFrameIsHandled() throws {
            let fixture = try independentStdioFixture { $0.budgets.maxFrameBytes = 8192 }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            #expect(client.request(1, "ping"))
            #expect(Client.id(of: client.readMessage()) == 1)
            // 6 MiB, written in pieces, with no newline until the very end.
            let piece = [UInt8](repeating: 0x7A, count: 256 * 1024)
            for _ in 0..<24 { #expect(client.send(piece)) }
            // Nothing is said until the frame ends: there is nothing to answer yet.
            #expect(!client.outputReadable(within: 0.2))
            #expect(client.send("\n" + Client.requestLine(2, "ping")))
            let rejected = client.readMessage()
            #expect(Client.errorCode(of: rejected) == -32600)
            #expect(Client.isNullID(rejected))
            #expect(Client.id(of: client.readMessage()) == 2)
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(client.drain(seconds: 0.2).isEmpty)
            #expect(client.violations == [])
        }

        @Test func aSecondOversizedFrameClosesTheConnection() throws {
            let fixture = try independentStdioFixture { $0.budgets.maxFrameBytes = 4096 }
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let big = String(repeating: "x", count: 5000) + "\n"
            #expect(client.send(big))
            #expect(Client.errorCode(of: client.readMessage()) == -32600)
            #expect(client.request(1, "ping"))
            #expect(Client.id(of: client.readMessage()) == 1)
            #expect(!client.hasReturned)
            #expect(client.send(big + Client.requestLine(2, "ping")))
            #expect(Client.errorCode(of: client.readMessage()) == -32600)
            // The input is still open: the server ends the session by itself.
            #expect(client.stopped(within: 10))
            #expect(!client.drain(seconds: 0.2).contains { Client.id(of: $0) == 2 })
            #expect(fixture.log.all.count == 1, "the closing is logged once: \(fixture.log.all)")
            #expect(client.violations == [])
        }

        // MARK: Bytes that are not JSON text

        @Test func zeroBytesAndInvalidUTF8AreParseErrorsAndTheStreamGoesOn() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let head = Array(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":""#.utf8)
            let tail = Array(#""}}}"#.utf8)
            let bad: [(String, [UInt8])] = [
                ("zero byte in a string", head + [0x00] + tail),
                ("zero byte between tokens", Array(#"{"jsonrpc":"2.0","#.utf8) + [0x00] + Array(#""id":1,"method":"ping"}"#.utf8)),
                ("only zero bytes", [0x00, 0x00, 0x00]),
                ("0xFF 0xFE", head + [0xFF, 0xFE] + tail),
                ("lone continuation byte", head + [0x80] + tail),
                ("overlong slash", head + [0xC0, 0xAF] + tail),
                ("truncated three-byte sequence", head + [0xE2, 0x82] + tail),
                ("surrogate encoded as UTF-8", head + [0xED, 0xA0, 0x80] + tail),
                ("beyond U+10FFFF", head + [0xF4, 0x90, 0x80, 0x80] + tail),
                ("truncated sequence at the end of the frame", Array(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8) + [0xE2]),
                ("raw control character in a string", head + [0x01] + tail),
            ]
            var wrong: [String] = []
            for (index, (name, frame)) in bad.enumerated() {
                #expect(client.send(frame + [0x0A]))
                let response = client.readMessage()
                // JSON-RPC 2.0: invalid JSON is a parse error, -32700, with a null id.
                if Client.errorCode(of: response) != -32700 || !Client.isNullID(response) {
                    wrong.append("\(name): \(response.map { "\($0)" } ?? "no answer")")
                }
                // The stream goes on after each of them.
                #expect(client.request(100 + index, "ping"))
                if Client.id(of: client.readMessage()) != 100 + index { wrong.append("\(name): the next request was not answered") }
            }
            #expect(wrong == [])
            // The error messages themselves must be clean: valid UTF-8, one line each.
            #expect(client.violations == [])
        }

        // MARK: What the server writes

        /// "Messages … MUST NOT contain embedded newlines": whatever a handler returns, the
        /// frame is one line of valid JSON, and the text survives the round trip.
        @Test func textThatNeedsEscapingStaysOnOneLineAndRoundTrips() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let texts = [
                "line1\nline2", "cr\rlf\r\n", "tab\tquote\"backslash\\", "\u{2028}\u{2029}\u{85}", "\u{0}\u{1}\u{1F}\u{7F}",
                "\u{1F600} \u{10FFFF} \u{FEFF}", String(repeating: "\n", count: 1000), "</script>\u{FFFD}", "",
            ]
            for (index, text) in texts.enumerated() {
                let arguments = try JSONSerialization.data(withJSONObject: ["text": text])
                #expect(client.call(index, "echo", String(decoding: arguments, as: UTF8.self)))
                let response = client.readMessage()
                #expect(Client.id(of: response) == index)
                #expect(Client.text(of: response)?.unicodeScalars.elementsEqual(text.unicodeScalars) == true, "text \(index)")
            }
            #expect(client.violations == [])
        }

        /// "The server MUST NOT write anything to its stdout that is not a valid MCP message":
        /// that includes the transport's own diagnostics. This server keeps the default
        /// diagnostics sink (the line it prints goes to the test run's stderr).
        @Test func diagnosticsDoNotGoToTheOutputDescriptor() throws {
            let server = Server(name: "independent-stdio-default-diagnostics", version: "1.0.0") { $0.budgets.maxFrameBytes = 4096 }
            let client = Client.started(server)
            defer { client.tearDown() }
            let big = String(repeating: "x", count: 5000) + "\n"
            #expect(client.send(big + Client.requestLine(1, "ping") + big))
            // The second oversized frame closes the connection, which is logged.
            #expect(client.stopped(within: 10))
            let messages = client.drain(seconds: 0.3)
            #expect(messages.count == 3)
            #expect(messages.filter { Client.errorCode(of: $0) == -32600 }.count == 2)
            #expect(client.violations == [])
        }

        /// A JSON-RPC batch reply (`2025-03-26`) is one message and therefore one line.
        @Test func aBatchReplyIsOneLine() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server, version: "2025-03-26")
            defer { client.tearDown() }
            var first = Client.callLine(1, "echo", #"{"text":"one\ntwo"}"#)
            first.removeLast()
            var second = Client.requestLine(2, "ping")
            second.removeLast()
            var third = Client.callLine(3, "blob", #"{"size":100000,"seed":3}"#)
            third.removeLast()
            #expect(client.send("[" + first + "," + second + "," + third + "]\n"))
            let line = try #require(client.readLine())
            let reply = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [[String: Any]])
            #expect(Set(reply.compactMap { Client.id(of: $0) }) == [1, 2, 3])
            #expect(reply.contains { Client.text(of: $0) == independentStdioBlob(size: 100_000, seed: 3) })
            #expect(client.violations == [])
            client.closeInput()
            #expect(client.stopped(within: 10))
            #expect(client.drain(seconds: 0.2).isEmpty)
        }

        @Test func theDefaultTransportIsStandardInputAndOutput() {
            let transport = StdioTransport()
            #expect(transport.input == STDIN_FILENO)
            #expect(transport.output == STDOUT_FILENO)
            let custom = StdioTransport(input: 7, output: 9)
            #expect(custom.input == 7 && custom.output == 9)
        }

        /// U+FEFF inside a string is an ordinary character. Checked on the raw bytes of the
        /// answer, because Foundation's decoder (this client's) drops it at the start of a string.
        @Test func aLeadingByteOrderMarkInAStringSurvivesTheRoundTrip() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let raw = Array(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":""#.utf8)
                + [0xEF, 0xBB, 0xBF] + Array(#"bom"}}}"#.utf8) + [0x0A]
            #expect(client.send(raw))
            #expect(client.call(2, "echo", #"{"text":"\ufeffbom"}"#))
            // The two answers may come in either order.
            let lines = [try #require(client.readLine()), try #require(client.readLine())].map { String(decoding: $0, as: UTF8.self) }.sorted()
            for (id, text) in zip([1, 2], lines) {
                #if FoundationJSON
                #expect(text.contains(#""id":null"#) && text.contains("-32700"), "request \(id): \(text)")
                #else
                #expect(text.contains(#""id":\#(id)"#))
                let kept = text.contains("\u{FEFF}bom") || text.lowercased().contains(#"\ufeffbom"#)
                #expect(kept, "request \(id): \(text)")
                #endif
            }
            // Either way the stream goes on.
            #expect(client.request(3, "ping"))
            #expect(Client.id(of: client.readMessage()) == 3)
            #expect(client.violations == [])
        }

        /// Lines that are JSON but not JSON-RPC messages. JSON-RPC 2.0 §5.1: "Invalid Request"
        /// is -32600, and the id is null when it could not be determined. Whatever the server
        /// makes of each of them, it answers with one clean error line and carries on.
        @Test func jsonThatIsNotAMessageIsRejectedAndTheStreamGoesOn() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            let lines = ["123", #""text""#, "null", "true", "[]", "{}", #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, #"{"id":1}"#, "[1,2]"]
            var wrong: [String] = []
            for (index, line) in lines.enumerated() {
                #expect(client.send(line + "\n" + Client.requestLine(100 + index, "ping")))
                var errors: [[String: Any]] = []
                let answers = client.responses(to: [100 + index], timeout: 20) { errors.append($0) }
                if answers[100 + index]?["result"] == nil { wrong.append("\(line): the next request was not answered") }
                if errors.isEmpty || !errors.allSatisfy({ Client.errorCode(of: $0) == -32600 }) {
                    wrong.append("\(line): \(errors.map { "\(Client.errorCode(of: $0) ?? 0)" })")
                }
            }
            #expect(wrong == [])
            #expect(client.violations == [])
        }

        @Test func idsAndMethodNamesThatNeedEscapingStayOnOneLine() throws {
            let fixture = try independentStdioFixture()
            let client = Client.ready(fixture.server)
            defer { client.tearDown() }
            // The id comes back in a result, the method name in an error message.
            #expect(client.send(#"{"jsonrpc":"2.0","id":"a\nb\r \"c\u0000","method":"ping"}"# + "\n"))
            let pong = client.readMessage()
            #expect((pong?["id"] as? String)?.unicodeScalars.elementsEqual("a\nb\r\u{2028}\"c\u{0}".unicodeScalars) == true)
            #expect(client.send(#"{"jsonrpc":"2.0","id":2,"method":"no\nsuch\r \u0000\"method"}"# + "\n"))
            #expect(Client.errorCode(of: client.readMessage()) == -32601)
            // Escaped lone surrogates: whatever the answer is, it must be a clean line.
            #expect(client.send(#"{"jsonrpc":"2.0","id":"\ud800","method":"ping"}"# + "\n"))
            #expect(client.send(#"{"jsonrpc":"2.0","id":3,"method":"\udc00\ud800"}"# + "\n"))
            #expect(client.call(4, "echo", #"{"text":"\ud83d"}"#))
            #expect(client.request(5, "ping"))
            let answers = client.responses(to: [5], timeout: 20)
            #expect(answers[5] != nil)
            #expect(client.violations == [])
        }
    }
}
