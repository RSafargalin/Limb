#if os(macOS)
import Foundation
import Limb
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioClientLegacyInputTests {
    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25"])
    func handlesServerRequestsWithinAnOutboundToolCall(version: String) async throws {
        let includesContext = version == "2025-06-18"
        let sampling = includesContext
            ? samplingRequest.replacingOccurrences(of: #""maxTokens":20"#, with: #""maxTokens":20,"includeContext":"thisServer""#)
            : samplingRequest
        let handlers = ClientInputHandlers(
            elicitForm: { request, context in
                verify(context, version: version, id: RequestID(91), method: "elicitation/create")
                #expect(request.message == "Name?")
                return .init(action: .accept, content: ["name": "Ada"])
            },
            elicitURL: { request, context in
                verify(context, version: version, id: RequestID("91"), method: "elicitation/create")
                #expect(request.elicitationID == "account-42")
                return .init(action: .accept)
            },
            sample: { request, context in
                verify(context, version: version, id: RequestID("73"), method: "sampling/createMessage")
                #expect(request.params["maxTokens"] == 20)
                #expect(request.params["includeContext"] == (includesContext ? "thisServer" : nil))
                return .init(role: .assistant, content: ["type": "text", "text": "Four"], model: "fixture")
            },
            roots: { context in
                verify(context, version: version, id: RequestID(73), method: "roots/list")
                return [.init(uri: "file:///workspace")]
            }
        )
        try await withLegacyClient(version: version, handlers: handlers, maxPending: 1, script: """
            read_frame
            tool_id=$id
            send '\(rootsRequest)'
            capture
            send '\(sampling)'
            capture
            send '\(formRequest)'
            capture
            send '\(urlRequest)'
            capture
            finish_tool
            """) { client, peer in
            #expect(client.protocolVersion.rawValue == version)
            #expect(try peer.initialize()["params"]?["capabilities"] == [
                "roots": [:], "sampling": [:], "elicitation": ["form": [:], "url": [:]],
            ])
            try await callTool(client)
            let frames = try peer.responses()
            try #require(frames.count == 4)
            #expect(frames[0] == ["jsonrpc": "2.0", "id": 73, "result": ["roots": [["uri": "file:///workspace"]]]])
            #expect(frames[1] == [
                "jsonrpc": "2.0", "id": "73",
                "result": ["role": "assistant", "model": "fixture", "content": ["type": "text", "text": "Four"]],
            ])
            #expect(frames[2]["id"] == 91)
            if version == "2025-03-26" {
                #expect(frames[2]["error"]?["code"] == -32601)
            } else {
                #expect(frames[2]["result"] == ["action": "accept", "content": ["name": "Ada"]])
            }
            #expect(frames[3]["id"] == "91")
            if version == "2025-11-25" {
                #expect(frames[3]["result"] == ["action": "accept"])
            } else {
                #expect(frames[3]["error"]?["code"] == -32601)
            }
        }
    }

    @Test(arguments: ["auto-june", "auto-november", "pinned-november"])
    func urlOnlyCapabilityDependsOnExplicitPin(scenario: String) async throws {
        let pinned = scenario == "pinned-november"
        let version = scenario == "auto-june" ? "2025-06-18" : "2025-11-25"
        let handlers = ClientInputHandlers(elicitURL: { _, _ in .init(action: .decline) })
        try await withLegacyClient(
            version: version, pin: pinned ? .v2025_11_25 : nil, handlers: handlers, script: """
                read_frame
                tool_id=$id
                send '\(urlRequest)'
                capture
                send '\(formRequest)'
                capture
                finish_tool
                """
        ) { client, peer in
            let first = try peer.read("first")
            #expect(first["method"] == (pinned ? "initialize" : "server/discover"))
            if pinned { #expect(first["params"]?["protocolVersion"] == "2025-11-25") }
            let capabilities = try peer.initialize()["params"]?["capabilities"]
            #expect(capabilities == (pinned ? ["elicitation": ["url": [:]]] : [:]))
            try await callTool(client)
            let responses = try peer.responses()
            try #require(responses.count == 2)
            if pinned {
                #expect(responses[0]["result"] == ["action": "decline"])
            } else {
                #expect(responses[0]["error"]?["code"] == (version == "2025-11-25" ? -32602 : -32601))
            }
            #expect(responses[1]["error"]?["code"] == (version == "2025-11-25" ? -32602 : -32601))
        }
    }

    @Test func explicitPinRejectsDifferentLegacySelection() async throws {
        await #expect(throws: (any Error).self) {
            try await withLegacyClient(version: "2025-06-18", pin: .v2025_11_25) { _, _ in
                Issue.record("Connected despite server selecting a different legacy revision")
            }
        }
    }

    @Test func marchBatchRespondsOnceInRequestOrderAndRoutesPeerReply() async throws {
        let handlers = ClientInputHandlers(
            roots: { _ in [.init(uri: "file:///workspace")] }
        )
        try await withLegacyClient(version: "2025-03-26", handlers: handlers, script: """
            read_frame
            tool_id=$id
            send '[\(rootsRequest),{"jsonrpc":"2.0","method":"notifications/fixture"},{"jsonrpc":"2.0","id":8,"method":"fixtures/unavailable"},'"$(printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"done"}]}}' "$tool_id")"']'
            capture
            read_frame
            tool_id=$id
            finish_tool
            """) { client, peer in
            try await callTool(client, name: "before")
            try await peer.waitForResponses()
            try await callTool(client, name: "after")
            let frames = try peer.responses()
            try #require(frames.count == 1)
            let responses = try #require(frames[0].arrayValue)
            try #require(responses.count == 2)
            #expect(responses[0] == ["jsonrpc": "2.0", "id": 73, "result": ["roots": [["uri": "file:///workspace"]]]])
            #expect(responses[1]["id"] == 8)
            #expect(responses[1]["error"]?["code"] == -32601)
        }
    }

    @Test func marchReturnsStandaloneParseErrorAndContinuesReading() async throws {
        try await withLegacyClient(version: "2025-03-26", script: #"""
            read_frame
            tool_id=$id
            send 'not JSON'
            capture
            finish_tool
            """#) { client, peer in
            try await callTool(client)
            let frames = try peer.responses()
            try #require(frames.count == 1)
            #expect(frames[0]["jsonrpc"] == "2.0")
            #expect(frames[0]["id"] == .null)
            #expect(frames[0]["error"]?["code"] == -32700)
        }
    }

    @Test func marchBatchReportsMalformedRequestsAndIgnoresMalformedResponses() async throws {
        try await withLegacyClient(version: "2025-03-26", script: #"""
            read_frame
            tool_id=$id
            send '[{},{"jsonrpc":"2.0","id":18,"method":"ping"},{"jsonrpc":"2.0","id":17,"result":{},"error":{"code":-32603,"message":"invalid response"}},{"jsonrpc":"2.0","id":19,"method":7},{"jsonrpc":"2.0","id":20,"method":"ping","result":{}},{"method":"ping"},{"jsonrpc":"1.0","method":"ping"},{"jsonrpc":"2.0","method":"ping","result":{}},{"jsonrpc":"2.0","method":"notifications/fixture"},{"jsonrpc":"2.0","id":21,"method":"ping","params":[]}]'
            capture
            finish_tool
            read_frame
            tool_id=$id
            finish_tool
            """#) { client, peer in
            try await callTool(client)
            try await callTool(client, name: "after")
            let frames = try peer.responses()
            try #require(frames.count == 1)
            let responses = try #require(frames[0].arrayValue)
            #expect(responses.map { $0["id"] } == [.null, 18, .null, .null, .null, .null, .null, 21])
            #expect(responses.map { $0["error"]?["code"] } == [
                -32600, nil, -32600, -32600, -32600, -32600, -32600, -32602,
            ])
            let pong = try #require(responses.first { $0["id"] == 18 })
            #expect(pong == ["jsonrpc": "2.0", "id": 18, "result": [:]])
        }
    }

    @Test func responseOnlyMarchBatchCompletesWhileFirstBatchCallbackIsParked() async throws {
        let callback = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let handlers = ClientInputHandlers(roots: { _ in
            callback.continuation.yield(())
            var gate = release.stream.makeAsyncIterator()
            _ = await gate.next()
            return [.init(uri: "file:///workspace")]
        })
        try await withLegacyClient(version: "2025-03-26", handlers: handlers, maxPending: 1, inputTimeout: .seconds(12), script: """
            read_frame
            tool_id=$id
            send '[\(rootsRequest)]'
            attempts=0
            while [ ! -f "$dir/callback-started" ]; do
                attempts=$((attempts + 1))
                [ "$attempts" -le 400 ]
                /bin/sleep 0.01
            done
            send "[$(finish_request "$tool_id")]"
            capture
            read_frame
            tool_id=$id
            finish_tool
            """) { client, peer in
            let tool = Task { try await callTool(client, name: "overlapping-batches") }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(4))
                callback.continuation.finish()
            }
            defer {
                tool.cancel()
                watchdog.cancel()
                callback.continuation.finish()
                release.continuation.finish()
            }
            var started = callback.stream.makeAsyncIterator()
            try #require(await started.next() != nil)
            try Data().write(to: peer.directory.appendingPathComponent("callback-started"))
            try await tool.value
            release.continuation.finish()
            try await peer.waitForResponses()
            try await callTool(client, name: "after")
            #expect(try peer.responses() == [[
                ["jsonrpc": "2.0", "id": 73, "result": ["roots": [["uri": "file:///workspace"]]]],
            ]])
        }
    }

    @Test func cancellingInboundBatchMemberLeavesSameIDOutboundToolAndReaderAlive() async throws {
        let callback = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let handlers = ClientInputHandlers(roots: { _ in
            callback.continuation.yield(())
            do {
                try await Task.sleep(for: .seconds(20))
            } catch is CancellationError {
                cancelled.continuation.yield(())
                // A callback may return a value after observing cancellation.
                return [.init(uri: "file:///after-cancel")]
            }
            return []
        })
        try await withLegacyClient(version: "2025-03-26", handlers: handlers, script: #"""
            read_frame
            tool_id=$id
            send "[{\"jsonrpc\":\"2.0\",\"id\":$tool_id,\"method\":\"roots/list\"},{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"fixtures/unavailable\"}]"
            read_frame
            concurrent_id=$id
            cancel_request "$concurrent_id"
            finish_request "$concurrent_id"
            read_frame
            release_id=$id
            cancel_request "$tool_id"
            capture
            finish_tool
            finish_request "$release_id"
            read_frame
            tool_id=$id
            finish_tool
            """#) { client, peer in
            let blocked = Task { try await callTool(client, name: "blocked") }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(4))
                callback.continuation.finish()
                cancelled.continuation.finish()
            }
            defer {
                blocked.cancel()
                watchdog.cancel()
                callback.continuation.finish()
                cancelled.continuation.finish()
            }
            var started = callback.stream.makeAsyncIterator()
            try #require(await started.next() != nil)
            try await callTool(client, name: "concurrent")
            try await callTool(client, name: "release")
            try await blocked.value
            try await callTool(client, name: "after")
            var cancelledCallbacks = cancelled.stream.makeAsyncIterator()
            try #require(await cancelledCallbacks.next() != nil)
            let frames = try peer.responses()
            try #require(frames.count == 1)
            let responses = try #require(frames[0].arrayValue)
            try #require(responses.count == 1)
            #expect(responses[0]["id"] == 8)
            #expect(responses[0]["error"]?["code"] == -32601)
        }
    }

    @Test(arguments: [false, true])
    func reportsOnlyPreviouslyRegisteredURLCompletionsAndPreservesRawError(isNovember: Bool) async throws {
        let version = isNovember ? "2025-11-25" : "2025-06-18"
        let urlID = "caf\u{E9}"
        let differentID = "cafe\u{301}"
        let urlWithUnicodeID = urlRequest.replacingOccurrences(of: "account-42", with: urlID)
        let errorData: JSONValue = ["elicitations": [[
            "mode": "url", "elicitationId": "account-error", "url": "https://example.test/",
            "message": "Authorize",
        ]]]
        let handlers = ClientInputHandlers(
            elicitForm: { _, _ in .init(action: .decline) },
            elicitURL: { _, _ in .init(action: .accept) }
        )
        var completions: AsyncStream<String>?
        var replay: AsyncStream<String>?
        var boundedReplay: AsyncStream<String>?
        try await withLegacyClient(version: version, handlers: handlers, script: """
            read_frame
            tool_id=$id
            complete '\(urlID)'
            send '\(urlWithUnicodeID)'
            capture
            complete unknown
            complete '\(differentID)'
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32042,"message":"Authorization required","data":{"elicitations":[{"mode":"url","elicitationId":"account-error","url":"https://example.test/","message":"Authorize"}]}}}\n' "$tool_id"
            read_frame
            [ "$(extract params.name)" = 'barrier' ]
            tool_id=$id
            complete account-error
            complete account-error
            complete '\(urlID)'
            complete '\(urlID)'
            finish_tool
            """) { client, peer in
            completions = await client.elicitationCompletions(bufferSize: 8)
            await #expect(throws: MCPError(code: -32042, message: "Authorization required", data: errorData)) {
                try await client.callTool("authorize", options: .init(timeout: .seconds(5)))
            }
            try await callTool(client, name: "barrier")
            replay = await client.elicitationCompletions()
            boundedReplay = await client.elicitationCompletions(bufferSize: 1)
            let response = try #require(try peer.responses().first)
            if isNovember {
                #expect(response["result"] == ["action": "accept"])
            } else {
                #expect(response["error"]?["code"] == -32601)
            }
        }
        let expected = isNovember ? ["account-error", urlID] : []
        for subscription in [completions, replay] {
            let stream = try #require(subscription)
            var observed: [[UInt8]] = []
            for await id in stream { observed.append(Array(id.utf8)) }
            #expect(observed == expected.map { Array($0.utf8) })
        }
        let boundedStream = try #require(boundedReplay)
        var observed: [[UInt8]] = []
        for await id in boundedStream { observed.append(Array(id.utf8)) }
        #expect(observed == expected.suffix(1).map { Array($0.utf8) })
    }

    @Test(arguments: [false, true])
    func completionBeforeURLDecisionPublishesOnlyOnAcceptance(accept: Bool) async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let handlers = ClientInputHandlers(elicitURL: { _, _ in
            started.continuation.yield(())
            var gate = release.stream.makeAsyncIterator()
            _ = await gate.next()
            return .init(action: accept ? .accept : .decline)
        })
        var completions: AsyncStream<String>?
        try await withLegacyClient(version: "2025-11-25", pin: .v2025_11_25, handlers: handlers, script: """
            read_frame
            tool_id=$id
            if [ '\(accept ? "accept" : "decline")' = 'accept' ]; then
                printf '%s\n%s\n' '\(urlRequest)' '{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"account-42"}}'
            else
                send '\(urlRequest)'
            fi
            read_frame
            if [ '\(accept ? "accept" : "decline")' = 'decline' ]; then complete account-42; fi
            finish_request "$id"
            capture
            if [ '\(accept ? "accept" : "decline")' = 'decline' ]; then complete account-42; fi
            finish_tool
            """) { client, peer in
            completions = await client.elicitationCompletions()
            let tool = Task { try await callTool(client, name: "authorize") }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(4))
                started.continuation.finish()
            }
            defer {
                tool.cancel()
                watchdog.cancel()
                started.continuation.finish()
                release.continuation.finish()
            }
            var callbacks = started.stream.makeAsyncIterator()
            try #require(await callbacks.next() != nil)
            try await callTool(client, name: "barrier")
            release.continuation.finish()
            try await tool.value
            let response = try #require(try peer.responses().first)
            #expect(response["result"] == ["action": accept ? "accept" : "decline"])
        }
        let stream = try #require(completions)
        var observed: [String] = []
        for await id in stream { observed.append(id) }
        #expect(observed == (accept ? ["account-42"] : []))
    }

    @Test func urlCompletionCapacityPreservesPendingAndCompletedIDs() async throws {
        let handlers = ClientInputHandlers(elicitURL: { _, _ in .init(action: .accept) })
        let additionalRequirements = #"{"elicitations":[{"mode":"url","elicitationId":"registered-102","message":"Existing","url":"https://example.test/"},{"mode":"url","elicitationId":"error-new","message":"New","url":"https://example.test/"}]}"#
        let original = MCPError(
            code: -32042, message: "Authorization required at capacity", data: try JSON.parse(additionalRequirements)
        )
        var completions: AsyncStream<String>?
        try await withLegacyClient(version: "2025-11-25", pin: .v2025_11_25, handlers: handlers, script: #"""
            solicit() {
                printf '{"jsonrpc":"2.0","id":%s,"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.test/","elicitationId":"%s"}}\n' "$1" "$2"
                capture
            }
            read_frame
            tool_id=$id
            solicit 100 pending
            solicit 101 completed
            complete completed
            member=102
            while [ "$member" -le 131 ]; do
                solicit "$member" "registered-$member"
                member=$((member + 1))
            done
            solicit 132 overflow
            complete overflow
            complete pending
            complete pending
            solicit 133 completed
            complete completed
            finish_tool
            read_frame
            [ "$(extract params.name)" = 'authorize' ]
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32042,"message":"Authorization required at capacity","data":%s}}\n' "$id" '\#(additionalRequirements)'
            read_frame
            [ "$(extract params.name)" = 'barrier' ]
            complete error-new
            complete registered-102
            finish_request "$id"
            """#) { client, peer in
            completions = await client.elicitationCompletions(bufferSize: 8)
            try await callTool(client)
            let waiting = await #expect(throws: ClientInputError.self) {
                try await client.callTool("authorize", options: .init(timeout: .seconds(5)))
            }
            if case let .urlElicitationTrackingOverloaded(error) = waiting {
                #expect(error == original)
            } else {
                Issue.record("Expected URL tracking overload with original peer error, got \(String(describing: waiting))")
            }
            try await callTool(client, name: "barrier")
            let responses = try peer.responses()
            try #require(responses.count == 34)
            for accepted in responses.prefix(32) {
                #expect(accepted["result"] == ["action": "accept"])
            }
            #expect(responses[32]["id"] == 132)
            #expect(responses[32]["error"]?["code"] == -31001)
            #expect(responses[33]["id"] == 133)
            #expect(responses[33]["error"]?["code"] == -32602)
        }
        let stream = try #require(completions)
        var observed: [String] = []
        for await id in stream { observed.append(id) }
        #expect(observed == ["completed", "pending", "registered-102"])
    }

    @Test func novemberRejectsTaskAugmentedInputsWithoutNegotiatedTasks() async throws {
        let handlers = ClientInputHandlers(
            elicitForm: { _, _ in
                Issue.record("Task-augmented form was dispatched")
                return .init(action: .accept, content: ["name": "Ada"])
            },
            elicitURL: { _, _ in
                Issue.record("Task-augmented URL was dispatched")
                return .init(action: .accept)
            },
            sample: { _, _ in
                Issue.record("Task-augmented sampling was dispatched")
                return .init(role: .assistant, content: ["type": "text", "text": "Four"], model: "fixture")
            }
        )
        let commands = [samplingRequest, formRequest, urlRequest].map {
            let augmented = $0.replacingOccurrences(of: #""params":{"#, with: #""params":{"task":{},"#)
            return "send '\(augmented)'\ncapture"
        }.joined(separator: "\n")
        var completions: AsyncStream<String>?
        try await withLegacyClient(version: "2025-11-25", pin: .v2025_11_25, handlers: handlers, script: """
            read_frame
            tool_id=$id
            \(commands)
            complete account-42
            finish_tool
            """) { client, peer in
            let capabilities = try peer.initialize()["params"]?["capabilities"]
            #expect(capabilities == ["sampling": [:], "elicitation": ["form": [:], "url": [:]]])
            completions = await client.elicitationCompletions()
            try await callTool(client)
            let responses = try peer.responses()
            #expect(responses.map { $0["id"] } == ["73", 91, "91"])
            #expect(responses.map { $0["error"]?["code"] } == [-32602, -32602, -32602])
            #expect(responses.allSatisfy { $0["result"] == nil })
        }
        let stream = try #require(completions)
        var iterator = stream.makeAsyncIterator()
        let unexpectedEvent = await iterator.next()
        #expect(unexpectedEvent == nil)
    }

    @Test func reportsInvalidParamsUnavailableMethodsInvalidOutputThrowsAndTimeout() async throws {
        let handlers = ClientInputHandlers(
            elicitForm: { _, _ in .init(action: .accept, content: ["name": 44]) },
            sample: { _, _ in throw CallbackFailure.fixture },
            roots: { _ in
                try await Task.sleep(for: .seconds(20))
                return []
            }
        )
        try await withLegacyClient(
            version: "2025-11-25", handlers: handlers, inputTimeout: .milliseconds(100), script: """
                read_frame
                tool_id=$id
                send '{"jsonrpc":"2.0","id":301,"method":"sampling/createMessage","params":{"maxTokens":"many","messages":[]}}'
                capture
                send '{"jsonrpc":"2.0","id":302,"method":"fixtures/unavailable"}'
                capture
                send '\(formRequest)'
                capture
                send '\(samplingRequest)'
                capture
                send '\(rootsRequest)'
                capture
                finish_tool
                """
        ) { client, peer in
            try await callTool(client)
            let frames = try peer.responses()
            #expect(frames.map { $0["id"] } == [301, 302, 91, "73", 73])
            #expect(frames.map { $0["error"]?["code"] } == [-32602, -32601, -32603, -32603, -31003])
        }
    }
}

private enum CallbackFailure: Error { case fixture }

private func verify(_ context: ClientInputContext, version: String, id: RequestID, method: String) {
    #expect(context.protocolVersion.rawValue == version)
    #expect(context.serverIdentity == "/bin/./sh")
    #expect(context.serverInfo?.name == "legacy-peer")
    #expect(context.legacyRequestID == id)
    #expect(context.method == method)
    #expect(context.requestKey == id.description)
    #expect(context.round == 1)
    #expect(context.deadline > ContinuousClock.now)
}

private let rootsRequest = #"{"jsonrpc":"2.0","id":73,"method":"roots/list"}"#
private let samplingRequest = #"{"jsonrpc":"2.0","id":"73","method":"sampling/createMessage","params":{"maxTokens":20,"messages":[{"role":"user","content":{"type":"text","text":"What is 2+2?"}}]}}"#
private let formRequest = #"{"jsonrpc":"2.0","id":91,"method":"elicitation/create","params":{"message":"Name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}"#
private let urlRequest = #"{"jsonrpc":"2.0","id":"91","method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.test/","elicitationId":"account-42"}}"#

private func callTool(_ client: Client, name: String = "fixture") async throws {
    let result = try await client.callTool(name, options: .init(timeout: .seconds(5)))
    #expect(result.value.content == [.text("done")])
}

private struct LegacyInputPeer {
    let directory: URL

    func read(_ filename: String) throws -> JSONValue {
        try JSON.parse(String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8))
    }

    func initialize() throws -> JSONValue { try read("initialize") }

    func waitForResponses() async throws {
        let transcript = directory.appendingPathComponent("responses")
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: transcript.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(FileManager.default.fileExists(atPath: transcript.path))
    }

    func responses() throws -> [JSONValue] {
        let text = try String(contentsOf: directory.appendingPathComponent("responses"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSON.parse(String($0)) }
    }

    static let shell = #"""
        version=$1
        dir=$2
        extract() { printf '%s\n' "$frame" | /usr/bin/plutil -extract "$1" raw -o - -; }
        wire_id() {
            case "$(printf '%s\n' "$frame" | /usr/bin/plutil -type id - 2>/dev/null || :)" in
                string) printf '"%s"' "$(extract id)" ;;
                integer) extract id ;;
            esac
        }
        read_frame() {
            IFS= read -r frame || return 1
            id=$(wire_id)
        }
        capture() {
            read_frame
            printf '%s\n' "$frame" >> "$dir/responses"
        }
        send() { printf '%s\n' "$1"; }
        complete() { printf '{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"%s"}}\n' "$1"; }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        cancel_request() { printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%s}}\n' "$1"; }
        finish_request() { reply "$1" '{"content":[{"type":"text","text":"done"}]}'; }
        finish_tool() { finish_request "$tool_id"; }
        read_frame
        printf '%s\n' "$frame" > "$dir/first"
        if [ "$(extract method)" = 'server/discover' ]; then
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"not found"}}\n' "$id"
            read_frame
        fi
        [ "$(extract method)" = 'initialize' ]
        printf '%s\n' "$frame" > "$dir/initialize"
        reply "$id" "$(printf '{"protocolVersion":"%s","serverInfo":{"name":"legacy-peer","version":"1"},"capabilities":{"tools":{}}}' "$version")"
        read_frame
        [ "$(extract method)" = 'notifications/initialized' ]
        """#
}

private func withLegacyClient(
    version: String,
    pin: ProtocolVersion? = nil,
    handlers: ClientInputHandlers? = nil,
    maxPending: Int = 8,
    inputTimeout: Duration = .seconds(5),
    script: String = "",
    _ body: (Client, LegacyInputPeer) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-legacy-input-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = LegacyInputPeer.shell + "\n" + script + "\nwhile read_frame; do :; done\n"
    let client = try await Client.connect(
        stdio: .init(executable: "/bin/./sh", arguments: ["-ec", command, "legacy-input", version, directory.path]),
        options: .init(
            timeout: .seconds(5), discoveryTimeout: .seconds(1), maxPending: maxPending,
            inputHandlers: handlers, legacyVersion: pin, legacyInputTimeout: inputTimeout
        )
    )
    do {
        try await body(client, LegacyInputPeer(directory: directory))
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}
#endif
