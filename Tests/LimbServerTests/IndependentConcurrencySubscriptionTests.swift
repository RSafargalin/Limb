import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private func subscriptionID(_ message: JSONValue) -> JSONValue? {
    message["params"]?["_meta"]?[MetaKey.subscriptionID] ?? message["result"]?["_meta"]?[MetaKey.subscriptionID]
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencySubscriptionTests {
    /// "The server MUST send `notifications/subscriptions/acknowledged` as the first message …
    /// and MUST NOT send any notification on the subscription before it." Checked while events
    /// are being published from other threads.
    @Test func acknowledgmentIsFirstEvenWhileEventsPourIn() async throws {
        let subscriptions = 24
        let server = independentConcurrencyServer { $0.budgets.maxSubscriptions = subscriptions }
        let stop = ICBox(false)
        let publishers = ICMeter()
        for publisher in 0..<3 {
            publishers.enter()
            Thread.detachNewThread {
                var round = 0
                // Bounded, so a stalled test cannot pile up an unbounded history.
                while !stop.value, round < 1500 {
                    server.notifyResourceUpdated(uri: "ic://hot")
                    if round % 8 == 0 {
                        try? server.register(tool: ToolDefinition(name: "t-\(publisher)-\(round)")) { _, _ in .text("") }
                        server.removeTool(named: "t-\(publisher)-\(round)")
                    }
                    round += 1
                    usleep(200)
                }
                publishers.leave()
            }
        }
        let wire = ICWire(server)
        var marks: [(id: RequestID, cancelledAt: Int)] = []
        for index in 0..<subscriptions {
            let id = wire.post(
                "subscriptions/listen", ["notifications": ["toolsListChanged": true, "resourceSubscriptions": ["ic://hot"]]],
                id: index % 2 == 0 ? RequestID(index) : RequestID("sub-\(index)"))
            marks.append((id, 0))
        }
        try? await Task.sleep(for: .milliseconds(50))
        for index in marks.indices {
            wire.cancel(marks[index].id)
            marks[index].cancelledAt = wire.sink.mark
        }
        stop.set(true)
        #expect(await independentConcurrencyEventually { publishers.current == 0 })

        // One pass over everything that was queued: the messages of each stream, in order.
        var streams: [JSONValue: [(index: Int, method: String)]] = [:]
        var untagged = 0
        for record in wire.sink.history {
            guard let message = record.json, let id = subscriptionID(message) else {
                untagged += 1
                continue
            }
            streams[id, default: []].append((record.index, message["method"]?.stringValue ?? ""))
        }
        for (id, cancelledAt) in marks {
            let stream = streams[id.json] ?? []
            #expect(stream.first?.method == "notifications/subscriptions/acknowledged", "subscription \(id)")
            #expect(stream.filter { $0.method == "notifications/subscriptions/acknowledged" }.count == 1)
            #expect(stream.count > 1, "subscription \(id) received no events: the test did not exercise the race")
            #expect(!stream.contains { $0.index >= cancelledAt }, "subscription \(id) got a message after its cancellation")
            #expect(stream.allSatisfy { entry in
                ["notifications/subscriptions/acknowledged", "notifications/tools/list_changed", "notifications/resources/updated"]
                    .contains(entry.method)
            })
        }
        // Every message of this modern connection belongs to some subscription.
        #expect(untagged == 0)
    }

    /// "The server MUST NOT send notification types the client has not explicitly requested."
    @Test func eachSubscriptionReceivesExactlyWhatItAskedFor() async throws {
        let server = independentConcurrencyServer()
        let wire = ICWire(server)
        let filters: [(RequestID, JSONObject)] = [
            ("tools", ["toolsListChanged": true, "promptsListChanged": false]),
            ("prompts", ["promptsListChanged": true]),
            ("resources", ["resourcesListChanged": true]),
            ("uris", ["resourceSubscriptions": ["ic://a", "ic://b"]]),
            ("nothing", [:]),
            ("everything", [
                "toolsListChanged": true, "promptsListChanged": true, "resourcesListChanged": true,
                "resourceSubscriptions": ["ic://a"],
            ]),
        ]
        for (id, filter) in filters {
            wire.post("subscriptions/listen", ["notifications": .object(filter)], id: id)
            let acknowledgment = try await wire.next()
            #expect(acknowledgment["method"] == "notifications/subscriptions/acknowledged")
            #expect(subscriptionID(acknowledgment) == id.json)
            // The acknowledgment reflects the accepted subset and never grants more than was asked.
            let accepted = try #require(acknowledgment["params"]?["notifications"]?.objectValue)
            for key in ["toolsListChanged", "promptsListChanged", "resourcesListChanged"] {
                #expect((accepted[key] == true) == (filter[key] == true), "\(id): \(key)")
            }
            #expect((accepted["resourceSubscriptions"] ?? []) == (filter["resourceSubscriptions"] ?? []), "\(id)")
        }

        func received() async -> [String: Set<String>] {
            var seen: [String: Set<String>] = [:]
            while let record = await wire.sink.next(timeout: .milliseconds(60)) {
                guard let message = record.json, let id = subscriptionID(message)?.stringValue else {
                    seen["?", default: []].insert(record.text)
                    continue
                }
                let uri = message["params"]?["uri"]?.stringValue.map { " \($0)" } ?? ""
                seen[id, default: []].insert((message["method"]?.stringValue ?? "?") + uri)
            }
            return seen
        }

        try server.register(tool: ToolDefinition(name: "t")) { _, _ in .text("") }
        #expect(await received() == [
            "tools": ["notifications/tools/list_changed"], "everything": ["notifications/tools/list_changed"],
        ])
        try server.register(prompt: PromptDefinition(name: "p")) { _, _ in PromptResult(messages: []) }
        #expect(await received() == [
            "prompts": ["notifications/prompts/list_changed"], "everything": ["notifications/prompts/list_changed"],
        ])
        try server.register(resource: ResourceDefinition(uri: "ic://a", name: "a")) { _, _ in [] }
        #expect(await received() == [
            "resources": ["notifications/resources/list_changed"], "everything": ["notifications/resources/list_changed"],
        ])
        server.notifyResourceUpdated(uri: "ic://a")
        #expect(await received() == [
            "uris": ["notifications/resources/updated ic://a"], "everything": ["notifications/resources/updated ic://a"],
        ])
        server.notifyResourceUpdated(uri: "ic://b")
        #expect(await received() == ["uris": ["notifications/resources/updated ic://b"]])
        server.notifyResourceUpdated(uri: "ic://c")
        server.notifyResourceUpdated(uri: "ic://A")
        #expect(await received() == [:])
        server.removeTool(named: "t")
        #expect(await received() == [
            "tools": ["notifications/tools/list_changed"], "everything": ["notifications/tools/list_changed"],
        ])
    }

    @Test func changesBeforeTheSubscriptionAreNotReplayedAndLaterOnesAreVisibleWhenAnnounced() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "before")) { _, _ in .text("") }
        let wire = ICWire(server)
        let id = wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        #expect(try await wire.next()["method"] == "notifications/subscriptions/acknowledged")
        #expect(await wire.isSilent(for: .milliseconds(50)))

        // A notification is an invitation to re-read the list: by the time it is on the wire,
        // the change it announces must be visible to `tools/list`.
        let total = 150
        let publisher = Task.detached {
            for index in 0..<total {
                try? server.register(tool: ToolDefinition(name: "late-\(index)")) { _, _ in .text("") }
            }
        }
        var announced = 0
        var pending: [JSONValue: Int] = [:]
        var checked = 0
        while checked < total {
            let message = try await wire.next()
            if message["method"] == "notifications/tools/list_changed" {
                #expect(subscriptionID(message) == id.json)
                announced += 1
                // Answered synchronously by the reader: the list as it is right now.
                pending[wire.post("tools/list").json] = announced
            } else if let responseID = message["id"], let needed = pending[responseID] {
                let count = message["result"]?["tools"]?.arrayValue?.count ?? 0
                #expect(count >= needed + 1, "announcement \(needed) arrived before its change was visible (\(count) tools)")
                checked += 1
            } else {
                Issue.record("unexpected message \(message)")
            }
        }
        #expect(announced == total)
        await publisher.value
        #expect(await wire.isSilent())
    }

    @Test func clientCancellationEndsTheStreamSilentlyAndFreesItsBudgetSlot() async throws {
        let server = independentConcurrencyServer { $0.budgets.maxSubscriptions = 2 }
        let wire = ICWire(server)
        let first = wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]], id: "first")
        let second = wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]], id: "second")
        _ = try await wire.next()
        _ = try await wire.next()
        let refused = try await wire.request("subscriptions/listen", ["notifications": ["toolsListChanged": true]], id: "third")
        #expect(refused["id"] == "third")
        #expect(refused.independentConcurrencyErrorCode == -31001)

        // An event is queued for both streams and not read yet; then the first stream is cancelled.
        try server.register(tool: ToolDefinition(name: "one")) { _, _ in .text("") }
        wire.cancel(first)
        let afterCancel = try await wire.next()
        #expect(subscriptionID(afterCancel) == second.json, "a queued notification of the cancelled stream was not withdrawn")
        // No response to the cancelled listen request, no notification about it.
        #expect(await wire.isSilent(for: .milliseconds(80)))

        // The slot is free again.
        let fourth = wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]], id: "fourth")
        let acknowledgment = try await wire.next()
        #expect(acknowledgment["method"] == "notifications/subscriptions/acknowledged")
        #expect(subscriptionID(acknowledgment) == fourth.json)
        try server.register(tool: ToolDefinition(name: "two")) { _, _ in .text("") }
        let one = try await wire.next()
        let two = try await wire.next()
        #expect(Set([subscriptionID(one), subscriptionID(two)]) == Set([second.json, fourth.json]))
        #expect(await wire.isSilent())
        // The id of the cancelled stream can be used for a new one.
        wire.cancel(second)
        wire.post("subscriptions/listen", ["notifications": [:]], id: "first")
        #expect(try await wire.next()["method"] == "notifications/subscriptions/acknowledged")
    }

    @Test func serverTeardownSignalsEachSubscriptionAndThenStaysSilent() async throws {
        let server = independentConcurrencyServer()
        let wire = ICWire(server)
        var ids: [RequestID] = []
        for index in 0..<5 {
            ids.append(
                wire.post(
                    "subscriptions/listen", ["notifications": ["toolsListChanged": true]],
                    id: index % 2 == 0 ? RequestID(index) : RequestID("s\(index)")))
            _ = try await wire.next()
        }
        let connection = wire.connection
        #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: 0.5) })
        var messages: [JSONValue] = []
        while let record = await wire.sink.next(timeout: .milliseconds(80)) { messages.append(try #require(record.json)) }
        #expect(messages.count == 10)
        for id in ids {
            let cancelledAt = messages.firstIndex { $0["method"] == "notifications/cancelled" && $0["params"]?["requestId"] == id.json }
            let resultAt = messages.firstIndex { $0["method"] == nil && $0["id"] == id.json }
            #expect(cancelledAt != nil, "no notifications/cancelled for subscription \(id)")
            #expect(resultAt != nil, "no closing result for subscription \(id)")
            if let cancelledAt, let resultAt {
                #expect(cancelledAt < resultAt)
                #expect(messages[resultAt]["result"]?["resultType"] == "complete")
                #expect(subscriptionID(messages[resultAt]) == id.json)
            }
        }
        // The streams are gone: events are not delivered any more.
        try server.register(tool: ToolDefinition(name: "after-close")) { _, _ in .text("") }
        server.notifyResourceUpdated(uri: "ic://a")
        #expect(await wire.isSilent(for: .milliseconds(80)))
    }

    /// "Servers MUST NOT send `notifications/cancelled` for any other purpose" (2026-07-28).
    @Test func modernServerNeverSendsCancelledForOrdinaryRequests() async throws {
        let gate = ICGate()
        let started = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            started.enter()
            try await Task.sleep(for: .seconds(120))
            return .text("woke")
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            started.enter()
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server)
        let listen = wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        wire.call("sleep")
        wire.call("hold")
        let cancelled = wire.call("sleep")
        #expect(await independentConcurrencyEventually { started.total == 3 })
        wire.cancel(cancelled)
        let connection = wire.connection
        #expect(await independentConcurrencyFinishes(within: .seconds(20)) { await connection.close(graceSeconds: 0.1) })
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        let notices = wire.sink.history.compactMap(\.json).filter { $0["method"] == "notifications/cancelled" }
        #expect(notices.count == 1)
        #expect(notices.allSatisfy { $0["params"]?["requestId"] == listen.json })
    }

    @Test func aSubscriptionDoesNotOccupyAHandlerSlot() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.execution = .serial
            configuration.budgets.maxQueuedRequests = 0
        }
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server)
        for _ in 0..<5 {
            wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
            #expect(try await wire.next()["method"] == "notifications/subscriptions/acknowledged")
        }
        // Five open streams, one handler slot, no queue: a call still runs.
        #expect(try await wire.request("tools/call", ["name": "echo"]).independentConcurrencyText == "ok")
        // And a busy handler does not delay a new stream.
        let held = wire.call("hold")
        wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        #expect(try await wire.next()["method"] == "notifications/subscriptions/acknowledged")
        gate.open()
        #expect(try await wire.response(to: held).independentConcurrencyText == "held")
    }

    // MARK: Who gets nothing

    @Test func nothingIsPushedToAClientThatDidNotAsk() async throws {
        let server = independentConcurrencyServer()
        try server.register(resource: ResourceDefinition(uri: "ic://r", name: "r")) { _, _ in [] }
        try server.register(tool: ToolDefinition(name: "first")) { _, _ in .text("") }
        // A modern client without a subscription.
        let modern = ICWire(server)
        _ = try await modern.request("tools/list")
        // A modern client whose subscription asks for something else.
        let other = ICWire(server)
        other.post("subscriptions/listen", ["notifications": ["promptsListChanged": true]])
        _ = try await other.next()
        // A legacy client that has not finished its handshake.
        let halfOpen = ICWire(server, modern: false)
        _ = try await halfOpen.request(
            "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "c", "version": "1"]])
        // A connection that has said nothing at all.
        let silent = ICWire(server)
        // A legacy client that subscribed to another resource.
        let legacy = ICWire(server, modern: false)
        try await legacy.initialize()
        #expect(try await legacy.request("resources/subscribe", ["uri": "ic://other"])["result"] != nil)

        try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("") }
        server.notifyResourceUpdated(uri: "ic://r")

        #expect(await modern.isSilent(for: .milliseconds(60)))
        #expect(await other.isSilent(for: .milliseconds(20)))
        #expect(await halfOpen.isSilent(for: .milliseconds(20)))
        #expect(await silent.isSilent(for: .milliseconds(20)))
        // The initialized legacy client gets the list change (it is unsolicited in its era) but
        // not the update of a resource it did not subscribe to.
        let change = try await legacy.next()
        #expect(change["method"] == "notifications/tools/list_changed")
        #expect(change["params"]?["_meta"] == nil)
        #expect(await legacy.isSilent(for: .milliseconds(20)))
    }

    @Test func legacyResourceSubscriptionsFollowSubscribeAndUnsubscribe() async throws {
        let server = independentConcurrencyServer()
        try server.register(resource: ResourceDefinition(uri: "ic://r", name: "r")) { _, _ in [] }
        let wire = ICWire(server, modern: false)
        try await wire.initialize()
        server.notifyResourceUpdated(uri: "ic://r")
        #expect(await wire.isSilent(for: .milliseconds(40)))
        _ = try await wire.request("resources/subscribe", ["uri": "ic://r"])
        _ = try await wire.request("resources/subscribe", ["uri": "ic://r"])
        server.notifyResourceUpdated(uri: "ic://r")
        let update = try await wire.next()
        #expect(update["method"] == "notifications/resources/updated")
        #expect(update["params"]?["uri"] == "ic://r")
        // Subscribing twice does not double the notifications.
        #expect(await wire.isSilent(for: .milliseconds(40)))
        _ = try await wire.request("resources/unsubscribe", ["uri": "ic://r"])
        server.notifyResourceUpdated(uri: "ic://r")
        #expect(await wire.isSilent(for: .milliseconds(40)))
    }

    @Test func oneRegistryEventReachesBothErasOnOneConnectionOnceEach() async throws {
        let server = independentConcurrencyServer()
        // A server without resources does not offer `resources/subscribe` (-32601), and a legacy
        // session keeps the capabilities announced at `initialize`: offer both kinds up front.
        try server.register(resource: ResourceDefinition(uri: "ic://r", name: "r")) { _, _ in [] }
        try server.register(tool: ToolDefinition(name: "first")) { _, _ in .text("") }
        let wire = ICWire(server, modern: false)
        try await wire.initialize()
        #expect(try await wire.request("resources/subscribe", ["uri": "ic://r"])["result"] != nil)
        let listen = wire.post(
            "subscriptions/listen",
            [
                "notifications": ["toolsListChanged": true, "resourceSubscriptions": ["ic://r"]],
                "_meta": [MetaKey.protocolVersion: "2026-07-28", MetaKey.clientCapabilities: [:]],
            ])
        _ = try await wire.next()
        try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("") }
        var messages = [try await wire.next(), try await wire.next()]
        #expect(messages.allSatisfy { $0["method"] == "notifications/tools/list_changed" })
        #expect(messages.filter { subscriptionID($0) == listen.json }.count == 1)
        #expect(messages.filter { subscriptionID($0) == nil }.count == 1)
        server.notifyResourceUpdated(uri: "ic://r")
        messages = [try await wire.next(), try await wire.next()]
        #expect(messages.allSatisfy { $0["method"] == "notifications/resources/updated" && $0["params"]?["uri"] == "ic://r" })
        #expect(messages.filter { subscriptionID($0) == listen.json }.count == 1)
        #expect(await wire.isSilent())
    }

    // MARK: Events that are not changes

    /// `notifications/tools/list_changed` announces that "the list of available tools changes".
    /// Removing something that is not registered changes nothing.
    @Test func removingWhatIsNotRegisteredAnnouncesNothing() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "kept")) { _, _ in .text("") }
        let wire = ICWire(server)
        wire.post(
            "subscriptions/listen",
            ["notifications": ["toolsListChanged": true, "promptsListChanged": true, "resourcesListChanged": true]])
        _ = try await wire.next()
        let legacy = ICWire(server, modern: false)
        try await legacy.initialize()

        server.removeTool(named: "never-registered")
        server.removePrompt(named: "never-registered")
        server.removeResource(uri: "ic://never-registered")
        #expect(await wire.isSilent(for: .milliseconds(80)), "list_changed was sent although no list changed")
        #expect(await legacy.isSilent(for: .milliseconds(20)), "list_changed was sent although no list changed")
        #expect(wire.others.map { $0["method"]?.stringValue } == [])
    }

    @Test func refusedRegistrationAnnouncesNothing() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "kept")) { _, _ in .text("") }
        let wire = ICWire(server)
        wire.post("subscriptions/listen", ["notifications": ["toolsListChanged": true]])
        _ = try await wire.next()
        #expect(throws: RegistrationError.self) {
            try server.register(tool: ToolDefinition(name: "kept")) { _, _ in .text("") }
        }
        #expect(throws: RegistrationError.self) {
            try server.register(tool: ToolDefinition(name: "bad name")) { _, _ in .text("") }
        }
        #expect(await wire.isSilent(for: .milliseconds(80)))
    }
}
