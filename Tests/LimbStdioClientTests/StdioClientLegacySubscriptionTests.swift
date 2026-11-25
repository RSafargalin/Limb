#if os(macOS)
import Foundation
import Limb
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioClientLegacySubscriptionTests {
    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25"])
    func negotiationFiltersNotificationsAndConfirmsOnlyAcceptedResources(version: String) async throws {
        let promptChanges = version == "2025-06-18"
        try await withLegacyPeer(
            version: version,
            capabilities: #"""
            {"tools":{"listChanged":true},"prompts":{"listChanged":\#(promptChanges)},"resources":{"listChanged":true,"subscribe":true}}
            """#,
            script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe)
                        if [ "$(extract params.uri)" = file:///denied ]; then reject -32042 denied
                        else reply "$id" '{}'; fi
                        ;;
                    resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call)
                        notify notifications/prompts/list_changed
                        notify notifications/tools/list_changed
                        updated file:///one
                        notify notifications/tools/list_changed
                        updated file:///one/child
                        notify notifications/resources/list_changed
                        tool_result
                        ;;
                esac
            done
            """#
        ) { client, peer in
            #expect(client.protocolVersion.rawValue == version)
            let subscription = try await client.subscribe(filter: .init(
                toolsListChanged: true, promptsListChanged: true, resourcesListChanged: true,
                resourceSubscriptions: ["file:///one", "file:///denied", "file:///two", "file:///one"]
            ), timeout: .seconds(3))
            #expect(subscription.confirmedFilter == .init(
                toolsListChanged: true, promptsListChanged: promptChanges, resourcesListChanged: true,
                resourceSubscriptions: ["file:///one", "file:///two"]
            ))
            try await legacyBarrier(client)
            var iterator = subscription.makeAsyncIterator()
            if promptChanges { #expect(try await iterator.next() == .promptsListChanged) }
            #expect(try await iterator.next() == .toolsListChanged)
            let exactEvents = try await collectResourceEvents(until: .toolsListChanged, from: &iterator)
            let exactUpdate = ClientSubscriptionEvent.resourceUpdated(uri: "file:///one")
            let firstInvalidation = ClientSubscriptionEvent.resourceInvalidated(uri: "file:///one")
            let otherInvalidation = ClientSubscriptionEvent.resourceInvalidated(uri: "file:///two")
            #expect(exactEvents.filter { $0 == exactUpdate }.count == 1)
            #expect(exactEvents.allSatisfy { $0 == exactUpdate || $0 == otherInvalidation })
            let childEvents = try await collectResourceEvents(until: .resourcesListChanged, from: &iterator)
            #expect(childEvents.filter { $0 == firstInvalidation }.count == 1)
            #expect(childEvents.allSatisfy { $0 == firstInvalidation || $0 == otherInvalidation })
            await subscription.cancel()
            #expect(try await iterator.next() == nil)
            let frames = try peer.requests()
            #expect(frames.compactMap { $0["method"]?.stringValue }.sorted() == [
                "resources/subscribe", "resources/subscribe", "resources/subscribe",
                "resources/unsubscribe", "resources/unsubscribe", "tools/call",
            ])
            #expect(peer.uris(for: "resources/subscribe", in: frames).sorted() == [
                "file:///denied", "file:///one", "file:///two",
            ])
            #expect(peer.uris(for: "resources/unsubscribe", in: frames).sorted() == [
                "file:///one", "file:///two",
            ])
        }
    }

    @Test func canonicallyEquivalentURIsKeepSeparateWireOwnership() async throws {
        let composed = "file:///caf\u{E9}"
        let decomposed = "file:///cafe\u{301}"
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe|resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call)
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///cafe\u0301"}}'
                        tool_result
                        ;;
                esac
            done
            """#) { client, peer in
            let first = try await client.subscribe(filter: .init(resourceSubscriptions: [composed]), timeout: .seconds(2))
            let second = try await client.subscribe(filter: .init(resourceSubscriptions: [decomposed]), timeout: .seconds(2))
            try await legacyBarrier(client)
            var firstEvents = first.makeAsyncIterator()
            var secondEvents = second.makeAsyncIterator()
            #expect(try await firstEvents.next() == .resourceInvalidated(uri: composed))
            #expect(try await secondEvents.next() == .resourceUpdated(uri: decomposed))
            await first.cancel()
            await second.cancel()
            let frames = try peer.requests()
            for method in ["resources/subscribe", "resources/unsubscribe"] {
                let uris = peer.uris(for: method, in: frames)
                #expect(uris.map { Array($0.utf8) } == [Array(composed.utf8), Array(decomposed.utf8)])
            }
        }
    }

    @Test func overflowRetainsTheBufferedPrefixAndReleasesTheResource() async throws {
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe|resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call)
                        updated file:///watched
                        updated file:///watched/child
                        updated file:///watched
                        tool_result
                        ;;
                esac
            done
            """#) { client, peer in
            let subscription = try await client.subscribe(
                filter: .init(resourceSubscriptions: ["file:///watched"]),
                timeout: .seconds(2), bufferSize: 2
            )
            try await legacyBarrier(client)
            var iterator = subscription.makeAsyncIterator()
            #expect(try await iterator.next() == .resourceUpdated(uri: "file:///watched"))
            #expect(try await iterator.next() == .resourceInvalidated(uri: "file:///watched"))
            await #expect(throws: ClientSubscriptionError.bufferOverflow) { try await iterator.next() }
            try await peer.waitForRequestCount(3)
            await subscription.cancel()
            let frames = try peer.requests()
            #expect(peer.uris(for: "resources/unsubscribe", in: frames) == ["file:///watched"])
        }
    }

    @Test func cancellingTheWaitingIteratorReleasesTheSubscription() async throws {
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe|resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call)
                        updated file:///watched
                        tool_result
                        ;;
                esac
            done
            """#) { client, peer in
            let subscription = try await client.subscribe(
                filter: .init(resourceSubscriptions: ["file:///watched"]), timeout: .seconds(2)
            )
            try await legacyBarrier(client)
            let consumed = Mutex(false)
            let waiting = Task {
                var iterator = subscription.makeAsyncIterator()
                try #require(try await iterator.next() == .resourceUpdated(uri: "file:///watched"))
                consumed.withLock { $0 = true }
                return try await iterator.next()
            }
            defer { waiting.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !consumed.withLock({ $0 }) {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            var otherIterator = subscription.makeAsyncIterator()
            await #expect(throws: ClientSubscriptionError.alreadyIterating) { try await otherIterator.next() }
            waiting.cancel()
            await #expect(throws: CancellationError.self) { try await waiting.value }
            try await peer.waitForRequestCount(3)
            await subscription.cancel()
            let frames = try peer.requests()
            #expect(peer.uris(for: "resources/unsubscribe", in: frames) == ["file:///watched"])
        }
    }

    @Test func unsupportedFiltersOpenWithoutWireRequests() async throws {
        try await withLegacyPeer(
            capabilities: #"{"tools":{},"prompts":{"listChanged":false},"resources":{"listChanged":false,"subscribe":false}}"#,
            script: #"while receive; do if [ "$method" = tools/call ]; then tool_result; fi; done"#
        ) { client, peer in
            let filter = ClientSubscriptionFilter(
                toolsListChanged: true, promptsListChanged: true, resourcesListChanged: true,
                resourceSubscriptions: ["file:///unsupported"]
            )
            let subscription = try await client.subscribe(filter: filter, timeout: .seconds(2))
            #expect(subscription.confirmedFilter == .init())
            await subscription.cancel()
            try await legacyBarrier(client)
            #expect(try peer.requests().map { $0["method"] } == ["tools/call"])
        }
    }

    @Test func sharedOwnershipAndReacquisitionWaitForUnsubscribeResponse() async throws {
        try await withLegacyPeer(script: #"""
            pending_release=''
            while receive; do
                case "$method" in
                    resources/subscribe) reply "$id" '{}' ;;
                    resources/unsubscribe)
                        if [ -z "$pending_release" ] && [ -z "${released:-}" ]; then pending_release=$id
                        else reply "$id" '{}'; fi
                        ;;
                    tools/call)
                        if [ "$(extract params.name)" = release ]; then
                            reply "$pending_release" '{}'
                            pending_release=''
                            released=yes
                        fi
                        tool_result
                        ;;
                esac
            done
            """#) { client, peer in
            let filter = ClientSubscriptionFilter(resourceSubscriptions: ["file:///shared"])
            let first = try await client.subscribe(filter: filter, timeout: .seconds(3))
            let second = try await client.subscribe(filter: filter, timeout: .seconds(3))
            #expect(second.confirmedFilter == filter)
            await first.cancel()
            try await legacyBarrier(client)
            #expect(try peer.requests().map { $0["method"] } == ["resources/subscribe", "tools/call"])

            let cancelled = Mutex(false)
            let release = Task {
                await second.cancel()
                cancelled.withLock { $0 = true }
            }
            defer { release.cancel() }
            try await peer.waitForRequestCount(3)
            await #expect(throws: ClientError.timedOut(.notSent)) {
                try await client.subscribe(filter: filter, timeout: .milliseconds(250))
            }
            #expect(try peer.requests().map { $0["method"] } == [
                "resources/subscribe", "tools/call", "resources/unsubscribe",
            ])
            let opening = Task { try await client.subscribe(filter: filter, timeout: .seconds(4)) }
            defer { opening.cancel() }
            try await legacyBarrier(client)
            #expect(!cancelled.withLock { $0 })
            #expect(try peer.requests().map { $0["method"] } == [
                "resources/subscribe", "tools/call", "resources/unsubscribe", "tools/call",
            ])
            try await legacyBarrier(client, name: "release")
            await release.value
            let third = try await opening.value
            #expect(third.confirmedFilter == filter)
            await third.cancel()
            #expect(try peer.requests().map { $0["method"] } == [
                "resources/subscribe", "tools/call", "resources/unsubscribe", "tools/call",
                "tools/call", "resources/subscribe", "resources/unsubscribe",
            ])
        }
    }

    @Test(arguments: [true, false])
    func interruptedPublishedSubscribeStaysUnknownDespiteLateSuccess(byCancellation: Bool) async throws {
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe)
                        if [ "$(extract params.uri)" = file:///slow ]; then slow=$id
                        else reply "$id" '{}'; fi
                        ;;
                    resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call)
                        if [ "$(extract params.name)" = late ]; then reply "$slow" '{}'; fi
                        tool_result
                        ;;
                esac
            done
            """#) { client, peer in
            let slow = ClientSubscriptionFilter(resourceSubscriptions: ["file:///slow"])
            let opening = Task {
                try await client.subscribe(
                    filter: .init(resourceSubscriptions: ["file:///fast", "file:///slow"]),
                    timeout: byCancellation ? .seconds(5) : .milliseconds(800)
                )
            }
            defer { opening.cancel() }
            try await peer.waitForRequestCount(2)
            try await legacyBarrier(client)
            if byCancellation {
                opening.cancel()
                await #expect(throws: ClientError.cancelled(.unknown)) { try await opening.value }
            } else {
                await #expect(throws: ClientError.timedOut(.unknown)) { try await opening.value }
            }
            try await legacyBarrier(client, name: "late")
            await #expect(throws: ClientSubscriptionError.legacyResourceStateUnknown(uri: "file:///slow")) {
                try await client.subscribe(filter: slow, timeout: .seconds(2))
            }
            let sibling = try await client.subscribe(filter: .init(
                resourceSubscriptions: ["file:///slow", "file:///good"]
            ), timeout: .seconds(2))
            #expect(sibling.confirmedFilter == .init(resourceSubscriptions: ["file:///good"]))
            await sibling.cancel()
            let frames = try peer.requests()
            #expect(peer.uris(for: "resources/subscribe", in: frames).sorted() == ["file:///fast", "file:///good", "file:///slow"])
            #expect(peer.uris(for: "resources/unsubscribe", in: frames).sorted() == ["file:///fast", "file:///good"])
        }
    }

    @Test func sharedSubscribeSurvivesTheShorterCallerDeadline() async throws {
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe) pending=$id ;;
                    resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call)
                        if [ "$(extract params.name)" = release ]; then reply "$pending" '{}'; fi
                        tool_result
                        ;;
                esac
            done
            """#) { client, peer in
            let filter = ClientSubscriptionFilter(resourceSubscriptions: ["file:///slow"])
            let short = Task { try await client.subscribe(filter: filter, timeout: .seconds(2)) }
            defer { short.cancel() }
            try await peer.waitForRequestCount(1)
            let long = Task { try await client.subscribe(filter: filter, timeout: .seconds(25)) }
            defer { long.cancel() }
            let releaseAfter = ContinuousClock.now.advanced(by: .seconds(16))
            await #expect(throws: ClientError.timedOut(.unknown)) { try await short.value }
            try await ContinuousClock().sleep(until: releaseAfter)
            #expect(try peer.requests().map { $0["method"] } == ["resources/subscribe"])
            try await legacyBarrier(client, name: "release")
            let subscription = try await long.value
            #expect(subscription.confirmedFilter == filter)
            await subscription.cancel()
            #expect(try peer.requests().map { $0["method"] } == [
                "resources/subscribe", "tools/call", "resources/unsubscribe",
            ])
        }
    }

    @Test func oversizedUnsubscribePreservesTheConfirmedRemoteSubscription() async throws {
        let prefix = "file:///watched/"
        let limit = 512
        let peerScript = #"""
            while receive; do
                case "$method" in
                    resources/subscribe) reply "$id" '{}' ;;
                    resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call) updated urn:changed-child; tool_result ;;
                esac
            done
            """#
        var overhead = 0
        try await withLegacyPeer(script: peerScript) { client, peer in
            let subscription = try await client.subscribe(
                filter: .init(resourceSubscriptions: [prefix]), timeout: .seconds(2)
            )
            let frame = try #require(try peer.requestLines().first)
            overhead = frame.utf8.count - prefix.utf8.count
            await subscription.cancel()
        }
        try #require((1..<(limit - prefix.utf8.count)).contains(overhead))
        let uri = prefix + String(repeating: "x", count: limit - overhead - prefix.utf8.count)
        let filter = ClientSubscriptionFilter(resourceSubscriptions: [uri])
        try await withLegacyPeer(maxFrameBytes: limit, script: peerScript) { client, peer in
            let first = try await client.subscribe(filter: filter, timeout: .seconds(2))
            let frame = try #require(try peer.requestLines().first)
            try #require(frame.utf8.count == limit)
            await first.cancel()

            let second = try await client.subscribe(filter: filter, timeout: .seconds(2))
            #expect(second.confirmedFilter == filter)
            try await legacyBarrier(client)
            var events = second.makeAsyncIterator()
            // A notification containing the full URI would exceed the same incoming frame limit.
            #expect(try await events.next() == .resourceInvalidated(uri: uri))
            await second.cancel()
            #expect(try peer.requests().map { $0["method"] } == ["resources/subscribe", "tools/call"])
        }
    }

    @Test(arguments: ["42", #"{"_meta":null}"#, #"{"_meta":true}"#])
    func malformedUnsubscribeResponseLeavesOnlyThatURIUnknown(result: String) async throws {
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe) reply "$id" '{}' ;;
                    resources/unsubscribe)
                        if [ "$(extract params.uri)" = file:///uncertain ]; then release=$id
                        else reply "$id" '{"_meta":{"example.test/release":true},"extension":42}'; fi
                        ;;
                    tools/call)
                        case "$(extract params.name)" in
                            malformed) reply "$release" '\#(result)' ;;
                            late) reply "$release" '{}' ;;
                        esac
                        tool_result
                        ;;
                esac
            done
            """#) { client, peer in
            let uri = "file:///uncertain"
            let filter = ClientSubscriptionFilter(resourceSubscriptions: [uri])
            let first = try await client.subscribe(filter: filter, timeout: .seconds(2))
            let release = Task { await first.cancel() }
            defer { release.cancel() }
            try await peer.waitForRequestCount(2)
            let opening = Task { try await client.subscribe(filter: filter, timeout: .seconds(4)) }
            defer { opening.cancel() }
            try await legacyBarrier(client)
            #expect(try peer.requests().map { $0["method"] } == [
                "resources/subscribe", "resources/unsubscribe", "tools/call",
            ])
            try await legacyBarrier(client, name: "malformed")
            await release.value
            let unknown = ClientSubscriptionError.legacyResourceStateUnknown(uri: uri)
            await #expect(throws: unknown) { try await opening.value }
            try await legacyBarrier(client, name: "late")
            await #expect(throws: unknown) {
                try await client.subscribe(filter: filter, timeout: .seconds(2))
            }
            let sibling = try await client.subscribe(
                filter: .init(resourceSubscriptions: ["file:///other"]), timeout: .seconds(2)
            )
            await sibling.cancel()
            let frames = try peer.requests()
            #expect(peer.uris(for: "resources/subscribe", in: frames) == [uri, "file:///other"])
            #expect(peer.uris(for: "resources/unsubscribe", in: frames) == [uri, "file:///other"])
        }
    }

    @Test(arguments: ["42", #"{"_meta":null}"#, #"{"_meta":true}"#])
    func malformedSubscribeResponseLeavesOnlyThatURIUnknown(result: String) async throws {
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe)
                        if [ "$(extract params.uri)" = file:///uncertain ]; then
                            reply "$id" '\#(result)'
                        else
                            reply "$id" '{"_meta":{"example.test/subscribe":true},"extension":42}'
                        fi
                        ;;
                    resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call) updated file:///other; tool_result ;;
                esac
            done
            """#) { client, peer in
            let sibling = try await client.subscribe(filter: .init(resourceSubscriptions: ["file:///other"]))
            let filter = ClientSubscriptionFilter(resourceSubscriptions: ["file:///uncertain"])
            let unknown = ClientSubscriptionError.legacyResourceStateUnknown(uri: "file:///uncertain")
            for _ in 0..<2 {
                await #expect(throws: unknown) {
                    try await client.subscribe(filter: filter, timeout: .seconds(2))
                }
            }
            try await legacyBarrier(client)
            var events = sibling.makeAsyncIterator()
            #expect(try await events.next() == .resourceUpdated(uri: "file:///other"))
            await sibling.cancel()
            let frames = try peer.requests()
            #expect(peer.uris(for: "resources/subscribe", in: frames) == ["file:///other", "file:///uncertain"])
            #expect(peer.uris(for: "resources/unsubscribe", in: frames) == ["file:///other"])
        }
    }

    @Test func malformedNotificationMetadataDoesNotDeliverEvents() async throws {
        try await withLegacyPeer(capabilities: #"{"tools":{"listChanged":true},"resources":{"subscribe":true}}"#, script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe|resources/unsubscribe) reply "$id" '{}' ;;
                    tools/call)
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":null}}'
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///other","_meta":true}}'
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///watched","_meta":{"example.test/update":true}}}'
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"example.test/change":1}}}'
                        tool_result
                        ;;
                esac
            done
            """#) { client, _ in
            let subscription = try await client.subscribe(filter: .init(
                toolsListChanged: true, resourceSubscriptions: ["file:///watched"]
            ))
            try await legacyBarrier(client)
            var events = subscription.makeAsyncIterator()
            #expect(try await events.next() == .resourceUpdated(uri: "file:///watched"))
            #expect(try await events.next() == .toolsListChanged)
            await subscription.cancel()
        }
    }

    @Test func lastOwnerCanReleaseWhileTwoOtherResourceOpeningsUseEveryPendingSlot() async throws {
        try await withLegacyPeer(maxPending: 2, script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe)
                        case "$(extract params.uri)" in
                            file:///a) reply "$id" '{}' ;;
                            file:///b) pending_b=$id ;;
                            file:///c) pending_c=$id ;;
                        esac
                        ;;
                    resources/unsubscribe)
                        reply "$id" '{}'
                        if [ "$(extract params.uri)" = file:///a ]; then
                            reply "$pending_b" '{}'
                            reply "$pending_c" '{}'
                        fi
                        ;;
                esac
            done
            """#) { client, peer in
            let first = try await client.subscribe(
                filter: .init(resourceSubscriptions: ["file:///a"]), timeout: .seconds(2)
            )
            let filter = ClientSubscriptionFilter(resourceSubscriptions: ["file:///b", "file:///c"])
            let opening = Task { try await client.subscribe(filter: filter, timeout: .seconds(5)) }
            defer { opening.cancel() }
            try await peer.waitForRequestCount(3)
            let release = Task { await first.cancel() }
            defer { release.cancel() }
            try await peer.waitForRequestCount(4)
            let beforeOpen = try peer.requests()
            #expect(beforeOpen.prefix(4).map { $0["method"] } == [
                "resources/subscribe", "resources/subscribe", "resources/subscribe", "resources/unsubscribe",
            ])
            #expect(beforeOpen[3]["params"]?["uri"] == "file:///a")
            await release.value
            let second = try await opening.value
            #expect(second.confirmedFilter == filter)
            await second.cancel()
            let frames = try peer.requests()
            #expect(peer.uris(for: "resources/unsubscribe", in: frames).sorted() == [
                "file:///a", "file:///b", "file:///c",
            ])
        }
    }

    @Test func rejectionReturnsTheFirstRequestedErrorAndAllowsRetry() async throws {
        try await withLegacyPeer(script: #"""
            rejected_first=no
            while receive; do
                case "$method" in
                    resources/subscribe)
                        case "$(extract params.uri)" in
                            file:///first)
                                if [ "$rejected_first" = no ]; then
                                    rejected_first=yes
                                    reject -32042 first
                                else reply "$id" '{}'; fi
                                ;;
                            file:///second) reject -32043 second ;;
                        esac
                        ;;
                    resources/unsubscribe) reply "$id" '{}' ;;
                esac
            done
            """#) { client, peer in
            await #expect(throws: MCPError(code: -32042, message: "first")) {
                try await client.subscribe(filter: .init(
                    resourceSubscriptions: ["file:///first", "file:///second", "file:///first"]
                ), timeout: .seconds(2))
            }
            let filter = ClientSubscriptionFilter(resourceSubscriptions: ["file:///first"])
            let retry = try await client.subscribe(filter: filter, timeout: .seconds(2))
            #expect(retry.confirmedFilter == filter)
            await retry.cancel()
            let frames = try peer.requests()
            #expect(peer.uris(for: "resources/subscribe", in: frames).sorted() == [
                "file:///first", "file:///first", "file:///second",
            ])
            #expect(peer.uris(for: "resources/unsubscribe", in: frames) == ["file:///first"])
        }
    }

    @Test(arguments: [false, true])
    func terminationWithAnActiveSubscriptionAbnormalAtEOF(abnormal: Bool) async throws {
        try await withLegacyPeer(script: #"""
            while receive; do
                case "$method" in
                    resources/subscribe) reply "$id" '{}' ;;
                    tools/call) exit 0 ;;
                esac
            done
            """#) { client, _ in
            let subscription = try await client.subscribe(
                filter: .init(resourceSubscriptions: ["file:///active"]), timeout: .seconds(2)
            )
            var iterator = subscription.makeAsyncIterator()
            if abnormal {
                let trigger = Task { try await legacyBarrier(client) }
                defer { trigger.cancel() }
                await #expect(throws: ClientError.connectionLost(.unknown)) { try await iterator.next() }
                _ = try? await trigger.value
            } else {
                await client.close()
                #expect(try await iterator.next() == nil)
            }
        }
    }
}

private func collectResourceEvents(
    until marker: ClientSubscriptionEvent,
    from iterator: inout ClientSubscription.AsyncIterator
) async throws -> [ClientSubscriptionEvent] {
    var events: [ClientSubscriptionEvent] = []
    for _ in 0..<3 {
        let event = try #require(try await iterator.next())
        if event == marker { return events }
        events.append(event)
    }
    Issue.record("Expected list-change marker after at most two resource events")
    return events
}

private func legacyBarrier(_ client: Client, name: String = "barrier") async throws {
    let result = try await client.callTool(name, options: .init(timeout: .seconds(3)))
    #expect(result.value.content == [.text("barrier")])
}

private struct LegacySubscriptionPeer {
    let transcript: URL

    func requestLines() throws -> [Substring] {
        let contents = try String(contentsOf: transcript, encoding: .utf8)
        return Array(contents.split(separator: "\n", omittingEmptySubsequences: false).dropLast())
    }

    func requests() throws -> [JSONValue] {
        try requestLines().map { try JSON.parse(String($0)) }
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

    func uris(for method: String, in requests: [JSONValue]) -> [String] {
        requests.filter { $0["method"]?.stringValue == method }.compactMap { $0["params"]?["uri"]?.stringValue }
    }

    static let preamble = #"""
        extract() { printf '%s\n' "$frame" | /usr/bin/plutil -extract "$1" raw -o - -; }
        read_frame() {
            IFS= read -r frame || return 1
            method=$(extract method)
            case "$(printf '%s\n' "$frame" | /usr/bin/plutil -type id - 2>/dev/null || :)" in
                string) id=$(printf '"%s"' "$(extract id)") ;;
                integer) id=$(extract id) ;;
                *) id='' ;;
            esac
        }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        reject() { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$id" "$1" "$2"; }
        notify() { printf '{"jsonrpc":"2.0","method":"%s"}\n' "$1"; }
        updated() {
            printf '{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"%s"}}\n' "$1"
        }
        tool_result() { reply "$id" '{"content":[{"type":"text","text":"barrier"}]}'; }
        transcript=$1
        version=$2
        capabilities=$3
        read_frame
        [ "$method" = server/discover ]
        reject -32601 'method not found'
        read_frame
        [ "$method" = initialize ]
        reply "$id" "$(printf '{"protocolVersion":"%s","serverInfo":{"name":"legacy-subscription-peer","version":"1"},"capabilities":%s}' "$version" "$capabilities")"
        read_frame
        [ "$method" = notifications/initialized ]
        receive() {
            read_frame || return 1
            printf '%s\n' "$frame" >> "$transcript"
        }
        """#
}

private func withLegacyPeer(
    version: String = "2025-11-25",
    capabilities: String = #"{"tools":{},"resources":{"subscribe":true}}"#,
    maxFrameBytes: Int = 8 * 1024 * 1024,
    maxPending: Int = 8,
    script: String,
    _ body: (Client, LegacySubscriptionPeer) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-legacy-subscription-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = directory.appendingPathComponent("requests")
    try Data().write(to: transcript)
    let client = try await Client.connect(
        stdio: .init(
            executable: "/bin/sh",
            arguments: ["-ec", LegacySubscriptionPeer.preamble + "\n" + script,
                        "legacy-subscription-peer", transcript.path, version, capabilities]
        ),
        options: .init(
            timeout: .seconds(5), discoveryTimeout: .seconds(1), maxFrameBytes: maxFrameBytes, maxPending: maxPending
        )
    )
    do {
        try await body(client, LegacySubscriptionPeer(transcript: transcript))
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}
#endif
