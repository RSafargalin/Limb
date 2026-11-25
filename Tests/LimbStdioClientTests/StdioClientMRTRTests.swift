#if os(macOS)
import Dispatch
import Foundation
import Limb
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioClientMRTRTests {
    @Test(arguments: [false, true])
    func allHandlersAndEveryContinuationPreserveTheWireContract(typed: Bool) async throws {
        let observed = Mutex([(key: [UInt8], round: Int, deadline: ContinuousClock.Instant)]())
        @Sendable func observe(_ context: ClientInputContext) {
            #expect(context.protocolVersion.rawValue == "2026-07-28")
            #expect(context.serverInfo?.name == "mrtr-peer")
            #expect(context.deadline > ContinuousClock.now)
            observed.withLock { $0.append((Array(context.requestKey.utf8), context.round, context.deadline)) }
        }
        let handlers = ClientInputHandlers(
            elicitForm: { request, context in
                observe(context)
                #expect(request.message == "What should we call you?")
                #expect(request == ElicitRequest(message: "What should we call you?", requestedSchema: annotatedFormSchema))
                return .init(action: .accept, content: ["name": "Ada"])
            },
            elicitURL: { request, context in
                observe(context)
                #expect(request.message == "Sign in")
                return .init(action: .decline)
            },
            sample: { request, context in
                observe(context)
                #expect(request.params["maxTokens"] == 20)
                return .init(role: .assistant, content: ["type": "text", "text": "Four"], model: "fixture", stopReason: "endTurn")
            },
            roots: { context in
                observe(context)
                return [.init(uri: "file:///my-workspace", name: "Workspace")]
            }
        )
        try await withMRTRPeer(handlers: handlers, script: groupedScript) { client, peer in
            if typed {
                let result = try await client.callTool(
                    "grouped", arguments: ["count": 7], decoding: [String: Int].self, options: mrtrRequest
                )
                #expect(result.value.output == ["value": 42])
            } else {
                let result = try await client.callTool(
                    "grouped", arguments: ["count": 7], options: mrtrRequest
                )
                #expect(result.value.content == [.text("finished")])
            }
            let frames = try peer.requests()
            try #require(frames.count == 3)
            let ids = try frames.map { try #require($0["id"]) }
            #expect(ids[0] != ids[1] && ids[0] != ids[2] && ids[1] != ids[2])
            let requestCapabilities: JSONValue = ["elicitation": ["form": [:], "url": [:]], "sampling": [:], "roots": [:]]
            for frame in frames {
                #expect(frame["method"] == "tools/call")
                #expect(frame["params"]?["name"] == "grouped")
                #expect(frame["params"]?["arguments"] == ["count": 7])
                #expect(frame["params"]?["_meta"]?[mrtrCapabilitiesKey] == requestCapabilities)
            }
            #expect(frames[0]["params"]?["requestState"] == nil)
            #expect(frames[0]["params"]?["inputResponses"] == nil)
            #expect(frames[1]["params"]?["requestState"] == "opaque\nstate")
            let answers = try #require(frames[1]["params"]?["inputResponses"]?.objectValue)
            #expect(answers.count == 4)
            #expect(answers["form"] == ["action": "accept", "content": ["name": "Ada"]])
            #expect(answers["url"] == ["action": "decline"])
            #expect(answers["sample"] == [
                "role": "assistant", "model": "fixture", "stopReason": "endTurn",
                "content": ["type": "text", "text": "Four"],
            ])
            #expect(answers["roots"] == ["roots": [["uri": "file:///my-workspace", "name": "Workspace"]]])
            #expect(frames[2]["params"]?["requestState"] == nil)
            #expect(frames[2]["params"]?["inputResponses"] == ["again": ["roots": [["uri": "file:///my-workspace", "name": "Workspace"]]]])

            let contexts = observed.withLock { $0 }
            #expect(Set(contexts.filter { $0.round == 1 }.map(\.key)) == Set(["form", "url", "sample", "roots"].map { Array($0.utf8) }))
            #expect(contexts.filter { $0.round == 2 }.map(\.key) == [Array("again".utf8)])
            #expect(contexts.count == 5)
            #expect(Set(contexts.map(\.deadline)).count == 1)
        }
    }

    @Test func canonicallyEquivalentKeysAreDistinctOnTheWire() async throws {
        let keys = Mutex([[UInt8]]())
        let handlers = ClientInputHandlers(roots: { context in
            let key = Array(context.requestKey.utf8)
            keys.withLock { $0.append(key) }
            return [.init(uri: "file:///root", name: key == Array("é".utf8) ? "precomposed" : "decomposed")]
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","inputRequests":{"\u00e9":{"method":"roots/list"},"e\u0301":{"method":"roots/list"}}}'
            receive
            finished
            while receive; do :; done
            """#) { client, peer in
            _ = try await client.callTool("keys", options: mrtrRequest)
            let frames = try peer.requests()
            try #require(frames.count == 2)
            let answers = try #require(frames[1]["params"]?["inputResponses"]?.objectValue)
            #expect(answers.count == 2)
            #expect(answers["é"]?["roots"]?[0]?["name"] == "precomposed")
            #expect(answers["e\u{0301}"]?["roots"]?[0]?["name"] == "decomposed")
            #expect(Set(keys.withLock { $0 }) == Set([Array("é".utf8), Array("e\u{0301}".utf8)]))
        }
    }

    @Test func simultaneousToolsKeepTheSameInputKeyAndStateSeparate() async throws {
        let firstCallback = MRTRCallbackGate()
        let calls = Mutex(0)
        let handlers = ClientInputHandlers(roots: { context in
            #expect(context.requestKey == "shared-key")
            #expect(context.round == 1)
            let index = calls.withLock { count in
                count += 1
                return count
            }
            if index == 1 { await firstCallback.pause() }
            return [.init(uri: "file:///root-\(index)")]
        })
        try await withMRTRPeer(handlers: handlers, maxPending: 2, script: #"""
            while receive; do
                name=$(extract params.name)
                if extract params.requestState >/dev/null 2>&1; then
                    finished
                else
                    reply "$id" "$(printf '{"resultType":"input_required","requestState":"%s-state","inputRequests":{"shared-key":{"method":"roots/list"}}}' "$name")"
                fi
            done
            """#) { client, peer in
            let first = Task { @Sendable in try await client.callTool("first", options: mrtrRequest) }
            defer {
                firstCallback.resume()
                first.cancel()
            }
            try await waitForMRTRCondition { firstCallback.isPaused }
            let second = try await client.callTool("second", options: mrtrRequest)
            #expect(second.value.content == [.text("finished")])
            #expect(firstCallback.isPaused)
            firstCallback.resume()
            let result = try await first.value
            #expect(result.value.content == [.text("finished")])

            let frames = try peer.requests()
            try #require(frames.count == 4)
            #expect(frames.compactMap { $0["params"]?["name"] } == ["first", "second", "second", "first"])
            #expect(frames.map { $0["params"]?["requestState"] } == [nil, nil, "second-state", "first-state"])
            #expect(frames.map { $0["params"]?["inputResponses"]?["shared-key"]?["roots"]?[0]?["uri"] } == [
                nil, nil, "file:///root-2", "file:///root-1",
            ])
            let ids = try frames.map { try #require($0["id"]) }
            for (index, id) in ids.enumerated() {
                #expect(!ids[..<index].contains(id))
            }
            #expect(calls.withLock { $0 } == 2)
        }
    }

    @Test(arguments: ["https://example.test/root", "file:///workspace/%2E%2E/outside"])
    func invalidRootURINeverContinuesTheTool(uri: String) async throws {
        let calls = Mutex(0)
        let handlers = ClientInputHandlers(roots: { _ in
            calls.withLock { $0 += 1 }
            return [.init(uri: "file:///workspace"), .init(uri: uri)]
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","requestState":"roots-state","inputRequests":{"workspace":{"method":"roots/list"}}}'
            while receive; do finished; done
            """#) { client, peer in
            let error = await #expect(throws: ClientInputError.self) {
                try await client.callTool("invalid-root", options: mrtrRequest)
            }
            switch error {
            case .invalidResponse(round: 1, key: "workspace")?: break
            default: Issue.record("Expected invalidResponse, got \(String(describing: error))")
            }
            _ = try await client.callTool("independent", options: mrtrRequest)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["invalid-root", "independent"])
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test func emptyHandlersAllowStateOnlyContinuation() async throws {
        try await withMRTRPeer(handlers: .init(), maxPending: 1, script: stateOnlyScript) { client, peer in
            for value in 0..<12 {
                let result = try await client.callTool("state-only", arguments: ["value": .string(String(value))], options: mrtrRequest)
                #expect(result.value.content == [.text("finished")])
            }
            let frames = try peer.requests()
            try #require(frames.count == 24)
            for value in 0..<12 {
                let original = frames[value * 2]
                let continuation = frames[value * 2 + 1]
                #expect(original["id"] != continuation["id"])
                #expect(original["params"]?["requestState"] == nil)
                #expect(continuation["params"]?["requestState"] == "opaque\nstate")
                for frame in [original, continuation] {
                    #expect(frame["method"] == "tools/call")
                    #expect(frame["params"]?["arguments"] == ["value": .string(String(value))])
                    #expect(frame["params"]?["inputResponses"] == nil)
                    #expect(frame["params"]?["_meta"]?[mrtrCapabilitiesKey] == [:])
                }
            }
        }
    }

    @Test func stateOnlyContinuationHasFreshProgressWhileTheFirstCallbackIsStillRunning() async throws {
        let updates = Mutex<[String]>([])
        let completed = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        try await withMRTRPeer(handlers: .init(), maxPending: 1, script: #"""
            progress() {
                printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":%s,"message":"%s"}}\n' "$1" "$2" "$3"
            }
            receive
            first_token=$(wire_value params._meta.progressToken)
            progress "$first_token" 1 first
            while [ ! -f "$2/first-callback" ]; do /bin/sleep 0.02; done
            reply "$id" '{"resultType":"input_required","requestState":"progress-state"}'
            receive
            [ "$(extract method)" = 'tools/call' ]
            [ "$(extract params.requestState)" = 'progress-state' ]
            second_token=$(wire_value params._meta.progressToken)
            : > "$2/continuation"
            progress "$first_token" 9 stale
            progress "$second_token" 2 continued
            while [ ! -f "$2/finish" ]; do /bin/sleep 0.02; done
            finished
            while receive; do :; done
            """#) { client, peer in
            let options = ClientRequestOptions(timeout: .seconds(10), onProgress: { event in
                let message = event.message ?? ""
                updates.withLock { $0.append(message) }
                if message == "first" { _ = release.wait(timeout: .now() + .seconds(12)) }
            })
            let call = Task { @Sendable in
                defer { completed.withLock { $0 = true } }
                return try await client.callTool("progress", options: options)
            }
            defer {
                release.signal()
                call.cancel()
            }
            try await waitForMRTRCondition { updates.withLock { $0 } == ["first"] }
            try Data().write(to: peer.directory.appendingPathComponent("first-callback"))
            let continuation = peer.directory.appendingPathComponent("continuation")
            try await waitForMRTRCondition {
                FileManager.default.fileExists(atPath: continuation.path) || completed.withLock { $0 }
            }
            if completed.withLock({ $0 }) {
                _ = try await call.value
            }
            try #require(FileManager.default.fileExists(atPath: continuation.path))
            release.signal()

            try await waitForMRTRCondition { updates.withLock { $0.contains("continued") } }
            try Data().write(to: peer.directory.appendingPathComponent("finish"))
            let result = try await call.value
            #expect(result.value.content == [.text("finished")])
            #expect(updates.withLock { $0 } == ["first", "continued"])
            let frames = try peer.requests()
            try #require(frames.count == 2)
            let firstToken = try #require(frames[0]["params"]?["_meta"]?["progressToken"])
            let secondToken = try #require(frames[1]["params"]?["_meta"]?["progressToken"])
            #expect(firstToken != secondToken)
        }
    }

    @Test func absentHandlersStillReturnInputRequiredWithoutRetrying() async throws {
        try await withMRTRPeer(script: #"""
            while receive; do
                reply "$id" '{"resultType":"input_required","requestState":"untouched"}'
            done
            """#) { client, peer in
            let error = await #expect(throws: ClientResponseError.self) {
                try await client.callTool("disabled", options: mrtrRequest)
            }
            guard case let .inputRequired(method, result)? = error else {
                Issue.record("Expected inputRequired, got \(String(describing: error))")
                return
            }
            #expect(method == "tools/call")
            #expect(result["requestState"] == "untouched")
            let frames = try peer.requests()
            #expect(frames.count == 1)
        }
    }

    @Test(arguments: [
        #"{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":"20"}}"#,
        #"{"method":"elicitation/create","params":{"message":"Your name?","requestedSchema":{"type":"object"}}}"#,
        #"{"method":"elicitation/create","params":{"message":"Your name?","requestedSchema":{"type":"object","title":123,"properties":{"name":{"type":"string"}}}}}"#,
        #"{"method":"elicitation/create","params":{"message":"Your name?","requestedSchema":{"type":"object","description":false,"properties":{"name":{"type":"string"}}}}}"#,
        ##"{"method":"elicitation/create","params":{"message":"Your name?","requestedSchema":{"type":"object","title":"Contact information","$ref":"#/properties/name","properties":{"name":{"type":"string"}}}}}"##,
        #"{"method":"elicitation/create","params":{"message":"Your name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string","title":123}}}}}"#,
        #"{"method":"elicitation/create","params":{"message":"Your name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string","description":false}}}}}"#,
        #"{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"image","mimeType":"image/png","data":"!"}}],"maxTokens":20}}"#,
        #"{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"audio","mimeType":"audio/wav","data":"!"}}],"maxTokens":20}}"#,
    ])
    func oneMalformedEntryPreventsAllCallbacksAndAnyContinuation(entry: String) async throws {
        let calls = Mutex(0)
        let handlers = ClientInputHandlers(
            elicitForm: { _, _ in
                calls.withLock { $0 += 1 }
                return .init(action: .decline)
            },
            sample: { _, _ in
                calls.withLock { $0 += 1 }
                return .init(role: .assistant, content: ["type": "text", "text": "Wrongly invoked"], model: "fixture")
            },
            roots: { _ in
                calls.withLock { $0 += 1 }
                return []
            }
        )
        try await withMRTRPeer(handlers: handlers, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","requestState":"one","inputRequests":{"a-valid":{"method":"roots/list"},"z-malformed":\#(entry)}}'
            while receive; do finished; done
            """#) { client, peer in
            let error = await #expect(throws: ClientResponseError.self) {
                try await client.callTool("bad-batch", options: mrtrRequest)
            }
            switch error {
            case .invalidResult("tools/call", _)?: break
            default: Issue.record("Expected invalidResult, got \(String(describing: error))")
            }
            let sibling = try await client.callTool("independent", options: mrtrRequest)
            #expect(sibling.value.content == [.text("finished")])
            #expect(calls.withLock { $0 } == 0)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["bad-batch", "independent"])
        }
    }

    @Test func theInputAndRoundLimitsFailBeforeRequestingMoreInput() async throws {
        let calls = Mutex(0)
        let handlers = ClientInputHandlers(
            roots: { _ in
                calls.withLock { $0 += 1 }
                return []
            },
            maxInputRounds: 1,
            maxInputsPerRound: 1
        )
        try await withMRTRPeer(handlers: handlers, script: #"""
            while receive; do
                case "$(extract params.name)" in
                    input-limit)
                        reply "$id" '{"resultType":"input_required","inputRequests":{"first":{"method":"roots/list"},"second":{"method":"roots/list"}}}'
                        ;;
                    round-limit)
                        reply "$id" '{"resultType":"input_required","requestState":"round","inputRequests":{"first":{"method":"roots/list"}}}'
                        ;;
                    independent) finished ;;
                esac
            done
            """#) { client, peer in
            let inputError = await #expect(throws: ClientInputError.self) {
                try await client.callTool("input-limit", options: mrtrRequest)
            }
            guard case .inputLimitExceeded(round: 1, limit: 1)? = inputError else {
                Issue.record("Expected inputLimitExceeded, got \(String(describing: inputError))")
                return
            }
            #expect(calls.withLock { $0 } == 0)
            let roundError = await #expect(throws: ClientInputError.self) {
                try await client.callTool("round-limit", options: mrtrRequest)
            }
            guard case .roundLimitExceeded(limit: 1)? = roundError else {
                Issue.record("Expected roundLimitExceeded, got \(String(describing: roundError))")
                return
            }
            #expect(calls.withLock { $0 } == 1)
            _ = try await client.callTool("independent", options: mrtrRequest)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == [
                "input-limit", "round-limit", "round-limit", "independent",
            ])
        }
    }

    @Test func eachElicitationModeRequiresItsOwnHandlerAndAdvertisesItsOwnCapability() async throws {
        let calls = Mutex(0)
        let handlers = ClientInputHandlers(elicitForm: { _, _ in
            calls.withLock { $0 += 1 }
            return .init(action: .decline)
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            while receive; do
                case "$(extract params.name)" in
                    url)
                        reply "$id" '{"resultType":"input_required","inputRequests":{"sign-in":{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.test/sign-in"}}}}'
                        ;;
                    unknown)
                        reply "$id" '{"resultType":"input_required","inputRequests":{"odd-key":{"method":"fixture/unknown","params":{}}}}'
                        ;;
                esac
            done
            """#) { client, peer in
            let unavailable = await #expect(throws: ClientInputError.self) {
                try await client.callTool("url", options: mrtrRequest)
            }
            guard case .unavailableHandler(round: 1, key: "sign-in", method: "elicitation/create")? = unavailable else {
                Issue.record("Expected unavailableHandler, got \(String(describing: unavailable))")
                return
            }
            let unsupported = await #expect(throws: ClientInputError.self) {
                try await client.callTool("unknown", options: mrtrRequest)
            }
            guard case .unsupportedMethod(round: 1, key: "odd-key", method: "fixture/unknown")? = unsupported else {
                Issue.record("Expected unsupportedMethod, got \(String(describing: unsupported))")
                return
            }
            #expect(calls.withLock { $0 } == 0)
            let frames = try peer.requests()
            try #require(frames.count == 2)
            for frame in frames {
                #expect(frame["params"]?["_meta"]?[mrtrCapabilitiesKey] == ["elicitation": ["form": [:]]])
            }
        }
    }

    @Test func callbackFailureAndInvalidAnswerNeverContinueTheTool() async throws {
        let handlers = ClientInputHandlers(elicitForm: { _, context in
            if context.requestKey == "throws" { throw MRTRApplicationError.denied }
            return .init(action: .accept, content: ["name": 123])
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            while receive; do
                name=$(extract params.name)
                case "$name" in
                    throws|invalid)
                        reply "$id" "$(printf '{"resultType":"input_required","inputRequests":{"%s":{"method":"elicitation/create","params":{"message":"Your name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}}}' "$name")"
                        ;;
                    independent) finished ;;
                esac
            done
            """#) { client, peer in
            await #expect(throws: MRTRApplicationError.denied) {
                try await client.callTool("throws", options: mrtrRequest)
            }
            let invalid = await #expect(throws: ClientInputError.self) {
                try await client.callTool("invalid", options: mrtrRequest)
            }
            guard case .invalidResponse(round: 1, key: "invalid")? = invalid else {
                Issue.record("Expected invalidResponse, got \(String(describing: invalid))")
                return
            }
            _ = try await client.callTool("independent", options: mrtrRequest)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["throws", "invalid", "independent"])
        }
    }

    @Test func acceptingURLElicitationCannotIncludeInBandContent() async throws {
        let handlers = ClientInputHandlers(elicitURL: { _, _ in
            .init(action: .accept, content: ["extra": "in-band data"])
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","inputRequests":{"url":{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.test/sign-in"}}}}'
            while receive; do finished; done
            """#) { client, peer in
            let error = await #expect(throws: ClientInputError.self) {
                try await client.callTool("url-content", options: mrtrRequest)
            }
            switch error {
            case .invalidResponse(round: 1, key: "url")?: break
            default: Issue.record("Expected invalidResponse, got \(String(describing: error))")
            }
            _ = try await client.callTool("independent", options: mrtrRequest)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["url-content", "independent"])
        }
    }

    @Test(arguments: [("image", "image/png"), ("audio", "audio/wav")])
    func samplingMediaRequiresBase64InTheAnswer(type: String, mimeType: String) async throws {
        let calls = Mutex(0)
        let handlers = ClientInputHandlers(sample: { request, context in
            calls.withLock { $0 += 1 }
            #expect(request.params["messages"]?[0]?["content"]?["data"] == "AQI=")
            let data = context.requestKey == "invalid" ? "!" : "AgM="
            let content: JSONValue = ["type": .string(type), "mimeType": .string(mimeType), "data": .string(data)]
            return .init(role: .assistant, content: content, model: "fixture")
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            while receive; do
                name=$(extract params.name)
                if extract params.inputResponses >/dev/null 2>&1; then
                    finished
                else
                    reply "$id" "$(printf '{"resultType":"input_required","inputRequests":{"%s":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"\#(type)","mimeType":"\#(mimeType)","data":"AQI="}}],"maxTokens":20}}}}' "$name")"
                fi
            done
            """#) { client, peer in
            let error = await #expect(throws: ClientInputError.self) {
                try await client.callTool("invalid", options: mrtrRequest)
            }
            switch error {
            case .invalidResponse(round: 1, key: "invalid")?: break
            default: Issue.record("Expected invalidResponse, got \(String(describing: error))")
            }
            let valid = try await client.callTool("valid", options: mrtrRequest)
            #expect(valid.value.content == [.text("finished")])
            #expect(calls.withLock { $0 } == 2)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["invalid", "valid", "valid"])
            let answer = frames.last?["params"]?["inputResponses"]?["valid"]?["content"]
            #expect(answer == ["type": .string(type), "mimeType": .string(mimeType), "data": "AgM="])
        }
    }

    @Test(arguments: [
        #""tools":[{"name":"extra","inputSchema":{"type":"object"}}]"#,
        #""toolChoice":{"mode":"auto"}"#,
        #""includeContext":"thisServer""#,
    ])
    func unadvertisedSamplingFeaturesNeverInvokeTheCallback(feature: String) async throws {
        let calls = Mutex(0)
        let handlers = ClientInputHandlers(sample: { _, _ in
            calls.withLock { $0 += 1 }
            return .init(role: .assistant, content: ["type": "text", "text": "Unexpected callback"], model: "fixture")
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","inputRequests":{"sample":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Hello"}}],"maxTokens":10,\#(feature)}}}}'
            while receive; do finished; done
            """#) { client, peer in
            let error = await #expect(throws: ClientInputError.self) {
                try await client.callTool("unadvertised", options: mrtrRequest)
            }
            switch error {
            case .unavailableHandler(round: 1, key: "sample", method: "sampling/createMessage")?: break
            default: Issue.record("Expected unavailableHandler, got \(String(describing: error))")
            }
            _ = try await client.callTool("independent", options: mrtrRequest)
            let frames = try peer.requests()
            #expect(frames.first?["params"]?["_meta"]?[mrtrCapabilitiesKey] == ["sampling": [:]])
            #expect(frames.compactMap { $0["params"]?["name"] } == ["unadvertised", "independent"])
            #expect(calls.withLock { $0 } == 0)
        }
    }

    @Test func oversizedRootsContinuationNeverReachesTheSubprocess() async throws {
        let limit = 1024
        let handlers = ClientInputHandlers(roots: { _ in
            [.init(uri: "file:///root", name: String(repeating: "x", count: limit * 2))]
        })
        try await withMRTRPeer(handlers: handlers, maxFrameBytes: limit, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","requestState":"roots-state","inputRequests":{"roots":{"method":"roots/list"}}}'
            while receive; do finished; done
            """#) { client, peer in
            let error = await #expect(throws: ClientInputError.self) {
                try await client.callTool("oversized", options: mrtrRequest)
            }
            switch error {
            case let .continuationFailed(.requestTooLarge(bytes, actualLimit))?:
                #expect(actualLimit == limit)
                #expect(bytes > limit)
            default: Issue.record("Expected continuationFailed wrapping requestTooLarge, got \(String(describing: error))")
            }
            _ = try await client.callTool("independent", options: mrtrRequest)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["oversized", "independent"])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func modernResourceAndPromptRequestsContinueWithInput(readResource: Bool, malformedFinal: Bool) async throws {
        let handlers = ClientInputHandlers(roots: { context in
            #expect(context.requestKey == "after-state")
            #expect(context.round == 2)
            return [.init(uri: "file:///workspace")]
        })
        let method = readResource ? "resources/read" : "prompts/get"
        let finalResult: String
        switch (readResource, malformedFinal) {
        case (true, false):
            finalResult = #"{"resultType":"complete","contents":[{"uri":"memo:///input","text":"resolved"}],"ttlMs":37,"cacheScope":"private"}"#
        case (true, true):
            finalResult = #"{"resultType":"complete","contents":[],"ttlMs":37}"#
        case (false, false):
            finalResult = #"{"resultType":"complete","description":"Resolved prompt","messages":[{"role":"user","content":{"type":"text","text":"Explain Swift"}}]}"#
        case (false, true):
            finalResult = #"{"resultType":"complete","messages":[{"role":"user","content":{"type":"text"}}]}"#
        }
        try await withMRTRPeer(handlers: handlers, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","requestState":"opaque\nstate"}'
            receive
            reply "$id" '{"resultType":"input_required","inputRequests":{"after-state":{"method":"roots/list"}}}'
            receive
            reply "$id" '\#(finalResult)'
            while receive; do :; done
            """#) { client, peer in
            func resolve() async throws {
                if readResource {
                    let result = try await client.readResource("memo:///input", options: mrtrRequest)
                    #expect(result.value == [.text(uri: "memo:///input", mimeType: nil, text: "resolved")])
                    #expect(result.cache == nil)
                    #expect(result.raw["ttlMs"] == 37)
                    #expect(result.raw["cacheScope"] == "private")
                } else {
                    let result = try await client.getPrompt("input", arguments: ["topic": "Swift"], options: mrtrRequest)
                    #expect(result.value.description == "Resolved prompt")
                    #expect(result.value.messages == [.user("Explain Swift")])
                    #expect(result.cache == nil)
                }
            }
            if malformedFinal {
                let error = await #expect(throws: ClientResponseError.self) { try await resolve() }
                guard case let .invalidResult(actual, _)? = error else {
                    Issue.record("Expected invalidResult for \(method), got \(String(describing: error))")
                    return
                }
                #expect(actual == method)
            } else {
                try await resolve()
            }

            let frames = try peer.requests()
            try #require(frames.count == 3)
            let ids = try frames.map { try #require($0["id"]) }
            #expect(ids[0] != ids[1] && ids[0] != ids[2] && ids[1] != ids[2])
            for frame in frames {
                #expect(frame["method"] == .string(method))
                let params = try #require(frame["params"])
                #expect(params["_meta"]?[mrtrCapabilitiesKey] == ["roots": [:]])
                if readResource {
                    #expect(params["uri"] == "memo:///input")
                } else {
                    #expect(params["name"] == "input")
                    #expect(params["arguments"] == ["topic": "Swift"])
                }
            }
            #expect(frames[0]["params"]?["requestState"] == nil)
            #expect(frames[0]["params"]?["inputResponses"] == nil)
            #expect(frames[1]["params"]?["requestState"] == "opaque\nstate")
            #expect(frames[1]["params"]?["inputResponses"] == nil)
            #expect(frames[2]["params"]?["requestState"] == nil)
            #expect(frames[2]["params"]?["inputResponses"] == ["after-state": ["roots": [["uri": "file:///workspace"]]]])
        }
    }

    @Test func unrelatedMethodsDoNotAdvertiseOrContinueWithInput() async throws {
        let handlers = ClientInputHandlers(roots: { _ in
            Issue.record("Unexpected callback for a list request")
            return []
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            while receive; do
                reply "$id" '{"resultType":"input_required","inputRequests":{"roots":{"method":"roots/list"}}}'
            done
            """#) { client, peer in
            let error = await #expect(throws: ClientResponseError.self) {
                try await client.listResources(options: mrtrRequest)
            }
            guard case .invalidResult("resources/list", _)? = error else {
                Issue.record("Expected invalidResult, got \(String(describing: error))")
                return
            }
            let frames = try peer.requests()
            try #require(frames.count == 1)
            #expect(frames[0]["params"]?["_meta"]?[mrtrCapabilitiesKey] == [:])
        }
    }

    @Test func legacyInitializationAdvertisesRegisteredHandlers() async throws {
        let handlers = ClientInputHandlers(roots: { _ in
            Issue.record("Unexpected legacy callback")
            return []
        })
        try await withMRTRPeer(version: "2025-11-25", handlers: handlers, script: #"""
            while receive; do
                reply "$id" '{"content":[{"type":"text","text":"legacy"}]}'
            done
            """#) { client, peer in
            let result = try await client.callTool("legacy", options: mrtrRequest)
            #expect(client.protocolVersion.rawValue == "2025-11-25")
            #expect(result.value.content == [.text("legacy")])
            let initialize = try JSON.parse(String(
                contentsOf: peer.directory.appendingPathComponent("initialize"), encoding: .utf8
            ))
            #expect(initialize["params"]?["capabilities"]?["roots"] == [:])
            #expect(initialize["params"]?["capabilities"]?["sampling"] == nil)
            #expect(initialize["params"]?["capabilities"]?["elicitation"] == nil)
            let frames = try peer.requests()
            try #require(frames.count == 1)
            #expect(frames[0]["params"]?["_meta"]?[mrtrCapabilitiesKey] == nil)
        }
    }

    @Test(arguments: [false, true])
    func cancellationAndTimeoutSettleDespiteANoncooperativeCallback(cancel: Bool) async throws {
        let gate = MRTRCallbackGate()
        let completed = Mutex(false)
        let handlers = ClientInputHandlers(roots: { _ in
            await gate.pause()
            return [.init(uri: "file:///too-late")]
        })
        try await withMRTRPeer(handlers: handlers, maxPending: 2, script: blockedCallbackScript) { client, peer in
            let call = Task { @Sendable in
                defer { completed.withLock { $0 = true } }
                return try await client.callTool(
                    "blocked", options: .init(timeout: cancel ? .seconds(15) : .seconds(2))
                )
            }
            do {
                try await waitForMRTRCondition { gate.isPaused }

                let sibling = try await client.callTool("sibling", options: mrtrRequest)
                #expect(sibling.value.content == [.text("finished")])

                if cancel { call.cancel() }
                try await waitForMRTRCondition { completed.withLock { $0 } && gate.cancellationObserved }
                #expect(gate.isPaused)
                if cancel {
                    await #expect(throws: ClientError.cancelled(.unknown)) { try await call.value }
                } else {
                    await #expect(throws: ClientError.timedOut(.unknown)) { try await call.value }
                }
                gate.resume()

                let after = try await client.callTool("after", options: mrtrRequest)
                #expect(after.value.content == [.text("finished")])
                let frames = try peer.requests().filter { $0["method"] == "tools/call" }
                #expect(frames.compactMap { $0["params"]?["name"] } == ["blocked", "sibling", "after"])
                for frame in frames {
                    #expect(frame["params"]?["requestState"] == nil)
                    #expect(frame["params"]?["inputResponses"] == nil)
                }
            } catch {
                gate.resume()
                call.cancel()
                throw error
            }
        }
    }

    @Test(arguments: [false, true])
    func closingTheChannelSettlesTheToolWhileTheCallbackIsStillPaused(explicit: Bool) async throws {
        let gate = MRTRCallbackGate()
        let completed = Mutex(false)
        let handlers = ClientInputHandlers(roots: { _ in
            await gate.pause()
            return []
        })
        try await withMRTRPeer(handlers: handlers, script: #"""
            receive
            reply "$id" '{"resultType":"input_required","inputRequests":{"roots":{"method":"roots/list"}}}'
            while [ ! -f "$2/exit" ]; do /bin/sleep 0.02; done
            exit 0
            """#) { client, peer in
            let call = Task { @Sendable in
                defer { completed.withLock { $0 = true } }
                return try await client.callTool("process-exit", options: .init(timeout: .seconds(15)))
            }
            defer {
                gate.resume()
                call.cancel()
            }
            try await waitForMRTRCondition { gate.isPaused }
            if explicit {
                let closed = Mutex(false)
                let close = Task { @Sendable in
                    await client.close()
                    closed.withLock { $0 = true }
                }
                try await waitForMRTRCondition { closed.withLock { $0 } && completed.withLock { $0 } }
                await close.value
            } else {
                try Data().write(to: peer.directory.appendingPathComponent("exit"))
                try await waitForMRTRCondition { completed.withLock { $0 } }
            }
            try await waitForMRTRCondition { gate.cancellationObserved }
            #expect(gate.isPaused)
            let expected: ClientError = explicit ? .closedDuringRequest(.unknown) : .connectionLost(.unknown)
            await #expect(throws: expected) { try await call.value }
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["process-exit"])
        }
    }

    @Test(arguments: [false, true])
    func aBlockedInputCallbackOccupiesThePendingQuota(cancelCaller: Bool) async throws {
        let gate = MRTRCallbackGate()
        let handlers = ClientInputHandlers(roots: { _ in
            await gate.pause()
            return []
        })
        try await withMRTRPeer(handlers: handlers, maxPending: 1, script: blockedCallbackScript) { client, peer in
            let call = Task { @Sendable in try await client.callTool("blocked", options: mrtrRequest) }
            defer {
                gate.resume()
                call.cancel()
            }
            try await waitForMRTRCondition { gate.isPaused }
            await #expect(throws: ClientError.workOverloaded(.notSent)) {
                try await client.callTool("sibling", options: mrtrRequest)
            }
            if cancelCaller {
                call.cancel()
                await #expect(throws: ClientError.cancelled(.unknown)) { try await call.value }
                try await waitForMRTRCondition { gate.cancellationObserved }
                #expect(gate.isPaused)
                await #expect(throws: ClientError.workOverloaded(.notSent)) {
                    try await client.callTool("after-cancellation", options: mrtrRequest)
                }
            }
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["params"]?["name"] } == ["blocked"])
            gate.resume()
            if !cancelCaller {
                let resumed = try await call.value
                #expect(resumed.value.content == [.text("finished")])
            }
            let retryDeadline = ContinuousClock.now + .seconds(2)
            while true {
                do {
                    let after = try await client.callTool("after", options: mrtrRequest)
                    #expect(after.value.content == [.text("finished")])
                    break
                } catch ClientError.workOverloaded(.notSent) where cancelCaller && ContinuousClock.now < retryDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let finalFrames = try peer.requests()
            let expected = cancelCaller ? ["blocked", "after"] : ["blocked", "blocked", "after"]
            #expect(finalFrames.compactMap { $0["params"]?["name"]?.stringValue } == expected)
        }
    }
}

private enum MRTRApplicationError: Error { case denied }

private let mrtrRequest = ClientRequestOptions(timeout: .seconds(5))

private let mrtrCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"

private let annotatedFormSchema: JSONObject = [
    "$schema": "http://json-schema.org/draft-07/schema#",
    "title": "Contact information",
    "description": "Used for the greeting",
    "type": "object",
    "properties": ["name": ["description": "The name to use", "type": "string"]],
    "required": ["name"],
]

private let groupedScript = #"""
    receive
    reply "$id" '{"resultType":"input_required","requestState":"opaque\nstate","inputRequests":{"form":{"method":"elicitation/create","params":{"mode":"form","message":"What should we call you?","requestedSchema":{"$schema":"http://json-schema.org/draft-07/schema#","title":"Contact information","description":"Used for the greeting","type":"object","properties":{"name":{"description":"The name to use","type":"string"}},"required":["name"]}}},"url":{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.test/sign-in"}},"sample":{"method":"sampling/createMessage","params":{"maxTokens":20,"messages":[{"role":"user","content":{"type":"text","text":"What is 2 + 2?"}}]}},"roots":{"method":"roots/list"}}}'
    receive
    reply "$id" '{"resultType":"input_required","inputRequests":{"again":{"method":"roots/list","params":{}}}}'
    receive
    finished
    while receive; do :; done
    """#

private let stateOnlyScript = #"""
    while receive; do
        if extract params.requestState >/dev/null 2>&1; then
            finished
        else
            reply "$id" '{"resultType":"input_required","requestState":"opaque\nstate"}'
        fi
    done
    """#

private struct MRTRPeer: Sendable {
    let directory: URL

    func requests() throws -> [JSONValue] {
        let transcript = directory.appendingPathComponent("requests")
        return try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").map {
            try JSON.parse(String($0))
        }
    }

    static let preamble = #"""
        version=$1
        transcript=$2/requests
        extract() { printf '%s\n' "$frame" | /usr/bin/plutil -extract "$1" raw -o - -; }
        wire_value() {
            case "$(printf '%s\n' "$frame" | /usr/bin/plutil -type "$1" - 2>/dev/null || :)" in
                string) printf '"%s"' "$(extract "$1")" ;;
                integer) extract "$1" ;;
                *) return 1 ;;
            esac
        }
        read_frame() {
            IFS= read -r frame || return 1
            id=$(wire_value id || :)
        }
        receive() {
            read_frame || return 1
            printf '%s\n' "$frame" >> "$transcript"
        }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        finished() { reply "$id" '{"resultType":"complete","content":[{"type":"text","text":"finished"}],"structuredContent":{"value":42}}'; }
        read_frame
        [ "$(extract method)" = 'server/discover' ]
        if [ "$version" = '2026-07-28' ]; then
            reply "$id" '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{},"prompts":{}},"ttlMs":0,"cacheScope":"public","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"mrtr-peer","version":"1"}}}'
        else
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id"
            read_frame
            [ "$(extract method)" = 'initialize' ]
            printf '%s\n' "$frame" > "$2/initialize"
            reply "$id" '{"protocolVersion":"2025-11-25","serverInfo":{"name":"mrtr-peer","version":"1"},"capabilities":{"tools":{},"resources":{},"prompts":{}}}'
            read_frame
            [ "$(extract method)" = 'notifications/initialized' ]
        fi
        """#
}

private func withMRTRPeer(
    version: String = "2026-07-28", handlers: ClientInputHandlers? = nil,
    maxPending: Int = 8, maxFrameBytes: Int = 8 * 1024 * 1024, script: String,
    _ body: (Client, MRTRPeer) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-mrtr-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = try await Client.connect(
        stdio: .init(
            executable: "/bin/sh",
            arguments: ["-ec", MRTRPeer.preamble + "\n" + script, "mrtr-peer", version, directory.path]
        ),
        options: .init(
            timeout: .seconds(5), discoveryTimeout: .seconds(1), maxFrameBytes: maxFrameBytes,
            maxPending: maxPending, inputHandlers: handlers
        )
    )
    do {
        try await body(client, MRTRPeer(directory: directory))
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}

private let blockedCallbackScript = #"""
    blocked_seen=no
    while receive; do
        if [ "$(extract method)" != 'tools/call' ]; then continue; fi
        if [ "$(extract params.name)" = 'blocked' ] && [ "$blocked_seen" = 'no' ]; then
            blocked_seen=yes
            reply "$id" '{"resultType":"input_required","requestState":"blocked-state","inputRequests":{"roots":{"method":"roots/list"}}}'
        else
            finished
        fi
    done
    """#

private final class MRTRCallbackGate: Sendable {
    private struct State {
        var waiter: CheckedContinuation<Void, Never>?
        var released = false
        var cancellationObserved = false
    }

    private let state = Mutex(State())

    var isPaused: Bool { state.withLock { $0.waiter != nil } }
    var cancellationObserved: Bool { state.withLock { $0.cancellationObserved } }

    func pause() async {
        await withTaskCancellationHandler {
            await suspendUntilReleased()
        } onCancel: {
            state.withLock { $0.cancellationObserved = true }
        }
    }

    private func suspendUntilReleased() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock { state in
                guard !state.released else { return true }
                state.waiter = continuation
                return false
            }
            if released { continuation.resume() }
        }
    }

    func resume() {
        let waiter = state.withLock { state in
            state.released = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

private func waitForMRTRCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for callback or operation")
        try await Task.sleep(for: .milliseconds(10))
    }
}
#endif
