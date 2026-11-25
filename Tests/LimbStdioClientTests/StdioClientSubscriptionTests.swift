#if os(macOS)
import Foundation
import Limb
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioClientSubscriptionTests {
    @Test(arguments: [false, true])
    func concurrentSubscriptionsKeepTheirConfirmedFiltersAndEventsSeparate(finalFirst: Bool) async throws {
        let finish = finalFirst
            ? #"complete "$first"; server_cancel "$first"; server_cancel "$second"; complete "$second""#
            : #"server_cancel "$first"; complete "$first"; complete "$second"; server_cancel "$second""#
        try await withSubscriptionPeer(script: #"""
            receive
            first=$id
            ack "$first" '{"toolsListChanged":true,"resourceSubscriptions":["file:///one"]}'
            receive
            second=$id
            notify notifications/resources/updated '"foreign"' ',"uri":42'
            notify notifications/tools/list_changed "$first"
            ack "$second" '{"promptsListChanged":true,"resourcesListChanged":true,"resourceSubscriptions":["file:///two"]}'
            notify notifications/resources/updated "$second" ',"uri":"file:///two/child"'
            notify notifications/resources/updated "$first" ',"uri":"file:///one/child"'
            notify notifications/prompts/list_changed "$second"
            notify notifications/resources/list_changed "$second"
            \#(finish)
            while receive; do tool_result; done
            """#) { client, peer in
            let first = try await client.subscribe(filter: .init(
                toolsListChanged: true, promptsListChanged: true, resourceSubscriptions: ["file:///one", "file:///declined"]
            ))
            let secondFilter = ClientSubscriptionFilter(
                promptsListChanged: true, resourcesListChanged: true, resourceSubscriptions: ["file:///two"]
            )
            let second = try await client.subscribe(filter: secondFilter)
            #expect(first.confirmedFilter == .init(toolsListChanged: true, resourceSubscriptions: ["file:///one"]))
            #expect(second.confirmedFilter == secondFilter)
            var firstEvents = first.makeAsyncIterator()
            var secondEvents = second.makeAsyncIterator()
            guard case .toolsListChanged? = try await firstEvents.next() else {
                Issue.record("Expected tools change on the first stream")
                return
            }
            guard case .resourceUpdated(uri: "file:///two/child")? = try await secondEvents.next() else {
                Issue.record("Expected the second stream's resource change")
                return
            }
            guard case .resourceUpdated(uri: "file:///one/child")? = try await firstEvents.next() else {
                Issue.record("Expected the first stream's resource change")
                return
            }
            guard case .promptsListChanged? = try await secondEvents.next(),
                  case .resourcesListChanged? = try await secondEvents.next() else {
                Issue.record("Expected prompts and resources changes on the second stream")
                return
            }
            #expect(try await firstEvents.next() == nil)
            #expect(try await secondEvents.next() == nil)
            await first.cancel()
            await second.cancel()
            try await subscriptionBarrier(client)
            let frames = try peer.requests()
            #expect(frames.map { $0["method"] } == ["subscriptions/listen", "subscriptions/listen", "tools/call"])
            let firstID = try #require(frames.first?["id"])
            let secondID = try #require(frames.dropFirst().first?["id"])
            #expect(firstID != secondID)
            for frame in frames.prefix(2) {
                #expect(frame["jsonrpc"] == "2.0")
                let metadata = frame["params"]?["_meta"]
                #expect(metadata?[subscriptionVersionKey] == "2026-07-28")
                #expect(metadata?["io.modelcontextprotocol/clientInfo"]?["name"]?.stringValue?.isEmpty == false)
                #expect(metadata?["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil)
            }
            #expect(frames.first?["params"]?["notifications"]?["toolsListChanged"] == true)
            #expect(frames.first?["params"]?["notifications"]?["promptsListChanged"] == true)
            #expect(frames.first?["params"]?["notifications"]?["resourceSubscriptions"] == ["file:///one", "file:///declined"])
            #expect(frames.dropFirst().first?["params"]?["notifications"]?["resourceSubscriptions"] == ["file:///two"])
        }
    }

    @Test func openingDeadlineAndIterationLifetimeAreIndependent() async throws {
        try await withSubscriptionPeer(maxPending: 1, script: #"""
            receive
            listen=$id
            ack "$listen" '{"toolsListChanged":true}'
            notify notifications/tools/list_changed "$listen"
            while receive; do
                case "$(extract method)" in
                    tools/call) tool_result ;;
                    notifications/cancelled) complete "$listen" ;;
                esac
            done
            """#) { client, peer in
            let timeout: Duration = .milliseconds(800)
            let opened = ContinuousClock.now
            let subscription = try await client.subscribe(filter: .init(toolsListChanged: true), timeout: timeout)
            var readEvent = false
            for try await event in subscription {
                if case .toolsListChanged = event { readEvent = true }
                break
            }
            #expect(readEvent)
            try await ContinuousClock().sleep(until: opened.advanced(by: timeout + .milliseconds(100)))
            try await subscriptionBarrier(client)
            #expect(try peer.requests().map { $0["method"] } == ["subscriptions/listen", "tools/call"])

            let iteration = Task { @Sendable in
                var iterator = subscription.makeAsyncIterator()
                return try await iterator.next()
            }
            defer { iteration.cancel() }
            await #expect(throws: ClientSubscriptionError.alreadyIterating) { try await iteration.value }
            await subscription.cancel()
            await subscription.cancel()
            try await subscriptionBarrier(client)
            let frames = try peer.requests()
            #expect(frames.map { $0["method"] } == [
                "subscriptions/listen", "tools/call", "notifications/cancelled", "tools/call",
            ])
            #expect(frames.dropFirst(2).first?["params"]?["requestId"] == frames.first?["id"])
        }
    }

    @Test func unrelatedAckDoesNotOpenTheSubscription() async throws {
        try await withSubscriptionPeer(script: #"""
            receive
            listen=$id
            ack '"other"' '{"toolsListChanged":true}'
            receive
            tool_result
            receive
            ack "$listen" '{}'
            tool_result
            complete "$listen"
            while receive; do tool_result; done
            """#) { client, peer in
            let finished = Mutex(false)
            let opening = Task { @Sendable in
                defer { finished.withLock { $0 = true } }
                return try await client.subscribe(filter: .init(toolsListChanged: true), timeout: .seconds(5))
            }
            defer { opening.cancel() }
            try await peer.waitForRequestCount(1)
            try await subscriptionBarrier(client)
            #expect(!finished.withLock { $0 })
            try await subscriptionBarrier(client)
            let subscription = try await opening.value
            #expect(subscription.confirmedFilter == .init())
            var iterator = subscription.makeAsyncIterator()
            #expect(try await iterator.next() == nil)
        }
    }

    @Test func cancellingAWaitingIteratorSendsCancellationForItsSubscription() async throws {
        try await withSubscriptionPeer(script: #"""
            receive
            listen=$id
            ack "$listen" '{"toolsListChanged":true}'
            notify notifications/tools/list_changed "$listen"
            while receive; do
                case "$(extract method)" in
                    tools/call) tool_result ;;
                    notifications/cancelled) complete "$listen" ;;
                esac
            done
            """#) { client, peer in
            let subscription = try await client.subscribe(filter: .init(toolsListChanged: true))
            let consumed = Mutex(false)
            let waiter = Task { @Sendable in
                var iterator = subscription.makeAsyncIterator()
                guard case .toolsListChanged? = try await iterator.next() else {
                    Issue.record("Expected the subscription's initial event")
                    return
                }
                consumed.withLock { $0 = true }
                let final = try await iterator.next()
                Issue.record("Expected cancellation during next(), got \(String(describing: final))")
            }
            defer { waiter.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !consumed.withLock({ $0 }) {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            try await subscriptionBarrier(client)
            waiter.cancel()
            await #expect(throws: CancellationError.self) { try await waiter.value }
            try await peer.waitForRequestCount(3)
            try await subscriptionBarrier(client)
            let frames = try peer.requests()
            #expect(frames.map { $0["method"] } == [
                "subscriptions/listen", "tools/call", "notifications/cancelled", "tools/call",
            ])
            #expect(frames.dropFirst(2).first?["params"]?["requestId"] == frames.first?["id"])
        }
    }

    @Test(arguments: [false, true])
    func cancellationOrTimeoutBeforeAcknowledgmentRetiresTheRequest(explicit: Bool) async throws {
        try await withSubscriptionPeer(maxPending: 1, script: #"""
            receive
            listen=$id
            while receive; do
                case "$(extract method)" in
                    notifications/cancelled)
                        ack "$listen" '{"toolsListChanged":true}'
                        complete "$listen"
                        ;;
                    subscriptions/listen)
                        ack "$id" '{"toolsListChanged":true}'
                        complete "$id"
                        ;;
                    tools/call) tool_result ;;
                esac
            done
            """#) { client, peer in
            let opening = Task { @Sendable in
                try await client.subscribe(
                    filter: .init(toolsListChanged: true),
                    timeout: explicit ? .seconds(5) : .milliseconds(500)
                )
            }
            defer { opening.cancel() }
            if explicit {
                try await peer.waitForRequestCount(1)
                opening.cancel()
                await #expect(throws: ClientError.cancelled(.unknown)) { try await opening.value }
            } else {
                await #expect(throws: ClientError.timedOut(.unknown)) { try await opening.value }
            }
            try await peer.waitForRequestCount(2)
            let reopened = try await client.subscribe(filter: .init(toolsListChanged: true), timeout: .seconds(2))
            var iterator = reopened.makeAsyncIterator()
            #expect(try await iterator.next() == nil)
            try await subscriptionBarrier(client)
            let frames = try peer.requests()
            #expect(frames.map { $0["method"] } == [
                "subscriptions/listen", "notifications/cancelled", "subscriptions/listen", "tools/call",
            ])
            #expect(frames.dropFirst().first?["params"]?["requestId"] == frames.first?["id"])
            #expect(frames.dropFirst(2).first?["id"] != frames.first?["id"])
        }
    }

    @Test(arguments: [false, true])
    func gracefulTerminationAllowsImmediateReopenWithOnePendingSlot(serverUsesCancellation: Bool) async throws {
        let finish = serverUsesCancellation ? #"server_cancel "$id""# : #"complete "$id""#
        try await withSubscriptionPeer(maxPending: 1, script: #"""
            receive
            ack "$id" '{"toolsListChanged":true}'
            \#(finish)
            receive
            ack "$id" '{"toolsListChanged":true}'
            notify notifications/tools/list_changed "$id"
            complete "$id"
            while receive; do tool_result; done
            """#) { client, peer in
            let filter = ClientSubscriptionFilter(toolsListChanged: true)
            let first = try await client.subscribe(filter: filter, timeout: .seconds(2))
            var firstIterator = first.makeAsyncIterator()
            #expect(try await firstIterator.next() == nil)
            let second = try await client.subscribe(filter: filter, timeout: .seconds(2))
            var secondIterator = second.makeAsyncIterator()
            guard case .toolsListChanged? = try await secondIterator.next() else {
                Issue.record("Expected update on the replacement subscription")
                return
            }
            #expect(try await secondIterator.next() == nil)
            let frames = try peer.requests()
            #expect(frames.map { $0["method"] } == ["subscriptions/listen", "subscriptions/listen"])
            #expect(frames.first?["id"] != frames.last?["id"])
        }
    }

    @Test(arguments: 0..<6)
    func cancellingToolAndSubscriptionTogetherKeepsAOneSlotConnectionUsable(attempt: Int) async throws {
        try await withSubscriptionPeer(maxPending: 1, script: #"""
            receive
            ack "$id" '{"toolsListChanged":true}'
            while receive; do
                if [ "$(extract params.name 2>/dev/null || :)" = barrier ]; then tool_result; fi
            done
            """#) { client, peer in
            let subscription = try await client.subscribe(filter: .init(toolsListChanged: true), timeout: .seconds(2))
            let tool = Task { @Sendable in
                try await client.callTool("blocked-\(attempt)", options: .init(timeout: .seconds(4)))
            }
            defer { tool.cancel() }
            try await peer.waitForRequestCount(2)

            let stopSubscription = Task { @Sendable in await subscription.cancel() }
            tool.cancel()
            await stopSubscription.value
            await #expect(throws: ClientError.cancelled(.unknown)) { try await tool.value }
            try await peer.waitForRequestCount(4)
            try await subscriptionBarrier(client)
            let frames = try peer.requests()
            #expect(frames.map { $0["method"] } == [
                "subscriptions/listen", "tools/call", "notifications/cancelled", "notifications/cancelled", "tools/call",
            ])
            let cancelled = frames.dropFirst(2).prefix(2).compactMap { $0["params"]?["requestId"] }
            let originalIDs = frames.prefix(2).compactMap { $0["id"] }
            #expect(cancelled.count == 2)
            #expect(originalIDs.count == 2)
            for id in originalIDs {
                #expect(cancelled.filter { $0 == id }.count == 1)
            }
        }
    }

    @Test(arguments: ["early", "overscoped", "empty-malformed", "duplicate", "malformed", "terminal-id"])
    func malformedAddressedFramesFailTheSubscription(scenario: String) async throws {
        try await withSubscriptionPeer(script: #"""
            receive
            listen=$id
            case '\#(scenario)' in
                early) notify notifications/tools/list_changed "$listen" ;;
                overscoped) ack "$listen" '{"promptsListChanged":true}' ;;
                empty-malformed)
                    printf '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":%s}}}\n' "$listen"
                    ;;
                *) ack "$listen" '{"toolsListChanged":true,"resourceSubscriptions":["file:///one"]}' ;;
            esac
            while receive; do
                if [ "$(extract method)" = tools/call ]; then
                    case '\#(scenario)' in
                        duplicate) ack "$listen" '{"toolsListChanged":true}' ;;
                        malformed) notify notifications/resources/updated "$listen" ',"uri":null' ;;
                        terminal-id) reply "$listen" '{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":"other"}}' ;;
                    esac
                    complete "$listen"
                    tool_result
                fi
            done
            """#) { client, _ in
            let filter = ClientSubscriptionFilter(toolsListChanged: true, resourceSubscriptions: ["file:///one"])
            switch scenario {
            case "early", "overscoped", "empty-malformed":
                await #expect(throws: ClientError.protocolViolation(.unknown)) {
                    try await client.subscribe(filter: filter, timeout: .seconds(2))
                }
            default:
                let subscription = try await client.subscribe(filter: filter, timeout: .seconds(2))
                try await subscriptionBarrier(client)
                var iterator = subscription.makeAsyncIterator()
                await #expect(throws: ClientError.protocolViolation(.unknown)) { try await iterator.next() }
            }
        }
    }

    @Test(arguments: ["null-meta", "array-meta", "wrong-type", "different-id"])
    func malformedCancellationLeavesBothSubscriptionsActive(scenario: String) async throws {
        try await withSubscriptionPeer(script: #"""
            receive
            first=$id
            ack "$first" '{"toolsListChanged":true}'
            receive
            second=$id
            ack "$second" '{"promptsListChanged":true}'
            case '\#(scenario)' in
                null-meta) metadata=null ;;
                array-meta) metadata='[]' ;;
                wrong-type) metadata='{"io.modelcontextprotocol/subscriptionId":false}' ;;
                different-id) metadata=$(printf '{"io.modelcontextprotocol/subscriptionId":%s}' "$second") ;;
            esac
            printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%s,"_meta":%s}}\n' "$first" "$metadata"
            notify notifications/tools/list_changed "$first"
            notify notifications/prompts/list_changed "$second"
            printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%s}}\n' "$first"
            server_cancel "$second"
            while receive; do tool_result; done
            """#) { client, peer in
            let first = try await client.subscribe(filter: .init(toolsListChanged: true), timeout: .seconds(2))
            let second = try await client.subscribe(filter: .init(promptsListChanged: true), timeout: .seconds(2))
            var firstEvents = first.makeAsyncIterator()
            var secondEvents = second.makeAsyncIterator()
            guard case .toolsListChanged? = try await firstEvents.next() else {
                Issue.record("Malformed cancellation ended the first subscription")
                return
            }
            guard case .promptsListChanged? = try await secondEvents.next() else {
                Issue.record("Malformed cancellation ended the second subscription")
                return
            }
            #expect(try await firstEvents.next() == nil)
            #expect(try await secondEvents.next() == nil)
            try await subscriptionBarrier(client)
            #expect(try peer.requests().map { $0["method"] } == ["subscriptions/listen", "subscriptions/listen", "tools/call"])
        }
    }

    @Test func oneActiveSubscriptionBlocksAnotherListenButAllowsAToolCall() async throws {
        try await withSubscriptionPeer(maxPending: 1, script: #"""
            receive
            listen=$id
            ack "$listen" '{"toolsListChanged":true}'
            while receive; do
                case "$(extract method)" in
                    subscriptions/listen) ack "$id" '{"toolsListChanged":true}'; complete "$id" ;;
                    tools/call) tool_result ;;
                    notifications/cancelled) complete "$listen" ;;
                esac
            done
            """#) { client, peer in
            let filter = ClientSubscriptionFilter(toolsListChanged: true)
            let subscription = try await client.subscribe(filter: filter, timeout: .seconds(2))
            await #expect(throws: ClientError.overloaded) {
                try await client.subscribe(filter: filter, timeout: .seconds(2))
            }
            try await subscriptionBarrier(client)
            #expect(try peer.requests().map { $0["method"] } == ["subscriptions/listen", "tools/call"])
            await subscription.cancel()
        }
    }

    @Test func overflowRetainsThePrefixDespiteLaterGracefulCompletion() async throws {
        try await withSubscriptionPeer(script: #"""
            receive
            listen=$id
            ack "$listen" '{"resourceSubscriptions":["file:///watched"]}'
            receive
            notify notifications/resources/updated "$listen" ',"uri":"file:///watched/one"'
            notify notifications/resources/updated "$listen" ',"uri":"file:///watched/two"'
            notify notifications/resources/updated "$listen" ',"uri":"file:///watched/three"'
            complete "$listen"
            tool_result
            while receive; do tool_result; done
            """#) { client, _ in
            let subscription = try await client.subscribe(
                filter: .init(resourceSubscriptions: ["file:///watched"]), bufferSize: 2
            )
            try await subscriptionBarrier(client)
            var iterator = subscription.makeAsyncIterator()
            guard case .resourceUpdated(uri: "file:///watched/one")? = try await iterator.next(),
                  case .resourceUpdated(uri: "file:///watched/two")? = try await iterator.next() else {
                Issue.record("Expected the buffered prefix in wire order")
                return
            }
            await #expect(throws: ClientSubscriptionError.bufferOverflow) { try await iterator.next() }
        }
    }

    @Test(arguments: ["early-error", "late-error", "eof", "client-close", "explicit"])
    func endOfStreamReportsItsCause(scenario: String) async throws {
        try await withSubscriptionPeer(script: #"""
            receive
            listen=$id
            reject() {
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32042,"message":"peer rejected","data":{"why":"fixture"}}}\n' "$listen"
            }
            if [ '\#(scenario)' = early-error ]; then
                reject
            else
                ack "$listen" '{"toolsListChanged":true}'
            fi
            while receive; do
                case '\#(scenario)' in
                    late-error) reject; tool_result ;;
                    eof) exit 0 ;;
                    explicit) [ "$(extract method)" = notifications/cancelled ]; complete "$listen" ;;
                esac
            done
            """#) { client, peer in
            let filter = ClientSubscriptionFilter(toolsListChanged: true)
            let rejection = MCPError(code: -32042, message: "peer rejected", data: ["why": "fixture"])
            if scenario == "early-error" {
                await #expect(throws: rejection) { try await client.subscribe(filter: filter, timeout: .seconds(2)) }
                return
            }
            let subscription = try await client.subscribe(filter: filter, timeout: .seconds(2))
            var iterator = subscription.makeAsyncIterator()
            switch scenario {
            case "late-error":
                try await subscriptionBarrier(client)
                await #expect(throws: rejection) { try await iterator.next() }
            case "eof":
                let trigger = Task { @Sendable in try await subscriptionBarrier(client) }
                defer { trigger.cancel() }
                await #expect(throws: ClientError.connectionLost(.unknown)) { try await iterator.next() }
                _ = try? await trigger.value
            case "client-close":
                await client.close()
                #expect(try await iterator.next() == nil)
            default:
                await subscription.cancel()
                try await peer.waitForRequestCount(2)
                #expect(try await iterator.next() == nil)
                let frames = try peer.requests()
                #expect(frames.last?["method"] == "notifications/cancelled")
                #expect(frames.last?["params"]?["requestId"] == frames.first?["id"])
            }
        }
    }

    @Test func invalidOptionsDoNotSendAListenRequest() async throws {
        try await withSubscriptionPeer(script: #"while receive; do tool_result; done"#) { client, peer in
            await #expect(throws: ClientSubscriptionError.invalidOptions) {
                try await client.subscribe(filter: .init(toolsListChanged: true), bufferSize: 0)
            }
            await #expect(throws: ClientSubscriptionError.invalidOptions) {
                try await client.subscribe(filter: .init(toolsListChanged: true), timeout: .zero)
            }
            try await subscriptionBarrier(client)
            #expect(try peer.requests().map { $0["method"] } == ["tools/call"])
        }
    }
}

private let subscriptionVersionKey = "io.modelcontextprotocol/protocolVersion"

private func subscriptionBarrier(_ client: Client) async throws {
    let result = try await client.callTool("barrier", options: .init(timeout: .seconds(3)))
    #expect(result.value.content == [.text("barrier")])
}

private struct SubscriptionPeer {
    let transcript: URL

    func requests() throws -> [JSONValue] {
        let contents = try String(contentsOf: transcript, encoding: .utf8)
        let completeLines = contents.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        return try completeLines.map { try JSON.parse(String($0)) }
    }

    func waitForRequestCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let observed = try requests()
            guard observed.count < count else { return }
            let methods = observed.compactMap { $0["method"]?.stringValue }
            try #require(ContinuousClock.now < deadline, "Expected \(count) client frames, received \(methods)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static let preamble = #"""
        extract() { printf '%s\n' "$frame" | /usr/bin/plutil -extract "$1" raw -o - -; }
        read_frame() {
            IFS= read -r frame || return 1
            case "$(printf '%s\n' "$frame" | /usr/bin/plutil -type id - 2>/dev/null || :)" in
                string) id=$(printf '"%s"' "$(extract id)") ;;
                integer) id=$(extract id) ;;
                *) id='' ;;
            esac
        }
        transcript=$1
        receive() {
            read_frame || return 1
            printf '%s\n' "$frame" >> "$transcript"
        }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        tool_result() { reply "$id" '{"resultType":"complete","content":[{"type":"text","text":"barrier"}]}'; }
        notify() {
            printf '{"jsonrpc":"2.0","method":"%s","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":%s}%s}}\n' "$1" "$2" "${3:-}"
        }
        ack() { notify notifications/subscriptions/acknowledged "$1" ",\"notifications\":$2"; }
        complete() {
            reply "$1" "$(printf '{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":%s}}' "$1")"
        }
        server_cancel() {
            printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%s,"_meta":{"io.modelcontextprotocol/subscriptionId":%s}}}\n' "$1" "$1"
        }
        read_frame
        [ "$(extract method)" = server/discover ]
        reply "$id" '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true},"resources":{"listChanged":true,"subscribe":true},"prompts":{"listChanged":true}},"ttlMs":0,"cacheScope":"public","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"subscription-fixture","version":"1"}}}'
        """#
}

private func withSubscriptionPeer(
    maxPending: Int = 8,
    script: String,
    _ body: (Client, SubscriptionPeer) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-subscription-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = directory.appendingPathComponent("requests")
    try Data().write(to: transcript)
    let client = try await Client.connect(
        stdio: .init(
            executable: "/bin/sh",
            arguments: ["-ec", SubscriptionPeer.preamble + "\n" + script, "subscription-peer", transcript.path]
        ),
        options: .init(timeout: .seconds(5), discoveryTimeout: .seconds(1), maxPending: maxPending)
    )
    do {
        try await body(client, SubscriptionPeer(transcript: transcript))
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}
#endif
