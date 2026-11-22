import Limb
import LimbTesting
import Synchronization
import Testing

private typealias ICWire = IndependentConcurrencyWire
private typealias ICGate = IndependentConcurrencyGate
private typealias ICMeter = IndependentConcurrencyMeter
private typealias ICBox = IndependentConcurrencyBox

private func connect(_ server: Server, _ version: ProtocolVersion) async throws -> ICWire {
    if version == .latest { return ICWire(server) }
    let wire = ICWire(server, modern: false)
    try await wire.initialize(version: version)
    return wire
}

@Suite(.timeLimit(.minutes(3)))
struct IndependentConcurrencyCancellationTests {
    // MARK: Before the handler starts

    @Test func requestCancelledWhileQueuedNeverRuns() async throws {
        let gate = ICGate()
        let ran = ICMeter()
        let server = independentConcurrencyServer { $0.budgets.maxConcurrentHandlers = 1 }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        try server.register(tool: ToolDefinition(name: "count")) { _, _ in
            ran.enter()
            return .text("ran")
        }
        let wire = ICWire(server)
        let first = wire.call("hold")
        let queued = wire.call("count")
        let after = wire.call("count")
        wire.cancel(queued)
        gate.open()
        let one = try await wire.next()
        let two = try await wire.next()
        #expect(Set([one["id"], two["id"]]) == Set([first.json, after.json]))
        #expect(await wire.isSilent())
        // The cancelled request's handler was never invoked: only `after` ran `count`.
        #expect(ran.total == 1)
        #expect(wire.framesSent(for: queued).isEmpty)
    }

    @Test func cancellationRightBehindTheRequestReachesTheHandler() async throws {
        let observed = ICMeter()
        let rounds = 300
        let server = independentConcurrencyServer { $0.budgets.maxConcurrentHandlers = rounds + 10 }
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            do {
                try await Task.sleep(for: .seconds(120))
            } catch {
                observed.enter()
                throw error
            }
            return .text("woke")
        }
        var wires: [ICWire] = []
        for _ in 0..<rounds {
            let wire = ICWire(server)
            let id = wire.call("sleep")
            wire.cancel(id)
            wires.append(wire)
        }
        #expect(await independentConcurrencyEventually(timeout: .seconds(30)) { observed.total == rounds })
        #expect(observed.total == rounds)
        try? await Task.sleep(for: .milliseconds(50))
        for wire in wires { #expect(wire.sink.sent.isEmpty) }
    }

    @Test func cancellationRightBehindTheRequestIsNotLostAtTheGate() async throws {
        let started = ICMeter()
        let observed = ICMeter()
        let completed = ICMeter()
        let holding = ICMeter()
        let gate = ICGate()
        let limit = 4
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = limit
            configuration.budgets.maxQueuedRequests = 1000
        }
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            started.enter()
            do {
                try await Task.sleep(for: .seconds(120))
            } catch {
                observed.enter()
                throw error
            }
            completed.enter()
            return .text("woke")
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gate.wait()
            return .text("held")
        }
        let rounds = 400
        var wires: [ICWire] = []
        for round in 0..<rounds {
            let wire = round % 3 == 0 || wires.isEmpty ? ICWire(server) : wires[wires.count - 1]
            if round % 3 == 0 || wires.isEmpty { wires.append(wire) }
            let id = wire.call("sleep")
            wire.cancel(id)
        }
        #expect(await independentConcurrencyEventually(timeout: .seconds(30)) { started.total == observed.total })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(started.total == observed.total, "\(started.total - observed.total) handlers started and never saw their cancellation")
        #expect(completed.total == 0)
        for wire in wires { #expect(wire.sink.sent.isEmpty) }
        // Nothing was left behind at the gate: all slots are free.
        let probe = ICWire(server)
        for _ in 0..<limit { probe.call("hold") }
        #expect(await independentConcurrencyEventually { holding.total == limit }, "only \(holding.total) of \(limit) slots are free")
        gate.open()
    }

    // MARK: While it runs

    @Test(arguments: ProtocolVersion.all)
    func cancelledRunningRequestGetsNothingInAnyRevision(_ version: ProtocolVersion) async throws {
        let gate = ICGate()
        let running = ICMeter()
        let sawCancellation = ICBox<Bool?>(nil)
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "stubborn")) { _, context in
            running.enter()
            context.progress(1)
            await gate.wait()
            sawCancellation.set(Task.isCancelled && context.isCancelled)
            // Ignores the cancellation and answers anyway.
            context.progress(2)
            context.log(.error, "late")
            return .text("too late")
        }
        let wire = try await connect(server, version)
        let id = wire.call("stubborn", meta: ["progressToken": "p", MetaKey.logLevel: "debug"])
        #expect(await independentConcurrencyEventually { running.total == 1 })
        #expect(try await wire.next()["method"] == "notifications/progress")
        wire.cancel(id)
        let mark = wire.sink.mark
        gate.open()
        #expect(await independentConcurrencyEventually { sawCancellation.value != nil })
        // The handler was told (cooperatively) that it is cancelled.
        #expect(sawCancellation.value == true)
        // Neither a response, nor an error, nor notifications: "Not send a response for the
        // cancelled request" (both eras), "MUST NOT send any further messages for it" (stdio, modern).
        #expect(await wire.isSilent(for: .milliseconds(150)))
        #expect(wire.framesSent(for: id, progressToken: "p", from: mark).isEmpty)
        #expect(wire.sink.history.count == mark)
    }

    @Test func handlerThatReturnsAnErrorAfterCancellationIsAlsoSilent() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "fails")) { _, _ in
            await gate.wait()
            throw MCPError.internalError("after cancellation")
        }
        try server.register(tool: ToolDefinition(name: "toolError")) { _, _ in
            await gate.wait()
            throw ToolError("after cancellation")
        }
        let wire = ICWire(server)
        let first = wire.call("fails")
        let second = wire.call("toolError")
        wire.cancel(first)
        wire.cancel(second)
        gate.open()
        #expect(await wire.isSilent(for: .milliseconds(150)))
        #expect(wire.sink.history.isEmpty)
    }

    // MARK: Right as it finishes

    /// Once the engine has processed a cancellation, it queues nothing more for that request,
    /// whichever side of the race the handler was on.
    @Test func cancellationRacingCompletionNeverAddsFramesAfterIt() async throws {
        let finished = ICMeter()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 8
            configuration.budgets.maxQueuedRequests = 100_000
        }
        try server.register(tool: ToolDefinition(name: "quick")) { _, context in
            context.progress(1)
            await Task.yield()
            context.progress(2)
            finished.enter()
            return .text("done")
        }
        let wire = ICWire(server)
        let rounds = 3000
        var marks: [(id: RequestID, token: JSONValue, mark: Int)] = []
        for round in 0..<rounds {
            let token = JSONValue.string("t\(round)")
            let id = wire.call("quick", id: RequestID(round), meta: ["progressToken": token])
            for _ in 0..<(round % 5) { await Task.yield() }
            wire.cancel(id)
            marks.append((id, token, wire.sink.mark))
        }
        // Let every handler that was started run to its end.
        _ = try await wire.request("server/discover")
        try? await Task.sleep(for: .milliseconds(200))
        let sent = wire.sink.sent
        var responses: [RequestID: Int] = [:]
        var lateFrames = 0
        var byToken: [JSONValue: Int] = [:]
        for (index, entry) in marks.enumerated() { byToken[entry.token] = index }
        for record in sent {
            guard let message = record.json else { continue }
            var owner: Int?
            if message["method"] == nil, let id = message["id"]?.intValue, id < rounds {
                owner = id
                responses[RequestID(id), default: 0] += 1
            } else if let token = message["params"]?["progressToken"] {
                owner = byToken[token]
            }
            if let owner, record.index >= marks[owner].mark { lateFrames += 1 }
        }
        #expect(lateFrames == 0, "frames queued for a request after its cancellation was processed")
        #expect(responses.values.allSatisfy { $0 == 1 }, "a request was answered more than once")
        // The connection is healthy afterwards and its handler slots are free again.
        #expect(try await wire.request("tools/call", ["name": "quick"]).independentConcurrencyText == "done")
    }

    // MARK: After it finished, unknown ids, malformed notifications

    @Test func lateUnknownAndMalformedCancellationsAreIgnored() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        let wire = ICWire(server)
        let done = try await wire.request("tools/call", ["name": "echo"], id: 7)
        #expect(done.independentConcurrencyText == "ok")
        wire.cancel(7)  // late
        wire.cancel(404)  // unknown
        wire.cancel("never-issued")
        wire.notify("notifications/cancelled", [:])
        wire.notify("notifications/cancelled", ["requestId": .null])
        wire.notify("notifications/cancelled", ["requestId": ["a": 1]])
        wire.notify("notifications/cancelled", ["requestId": true])
        wire.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5}}"#)
        wire.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#)
        // "Invalid cancellation notifications SHOULD be ignored": no error frames, no effect.
        #expect(await wire.isSilent(for: .milliseconds(100)))
        // No tombstone: the id of a finished request can be used again (2026-07-28 allows it).
        #expect(try await wire.request("tools/call", ["name": "echo"], id: 7).independentConcurrencyText == "ok")
    }

    @Test func stringAndNumberIdsAreDifferentRequests() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "hold")) { arguments, _ in
            await gate.wait()
            return .text(arguments["tag"]?.stringValue ?? "?")
        }
        let wire = ICWire(server)
        wire.call("hold", ["tag": "number"], id: 5)
        wire.call("hold", ["tag": "string"], id: "5")
        // Both are in flight: neither is a duplicate of the other.
        #expect(await wire.isSilent(for: .milliseconds(50)))
        wire.cancel("5")
        gate.open()
        let answer = try await wire.next()
        #expect(answer["id"] == 5)
        #expect(answer["id"] != "5")
        #expect(answer.independentConcurrencyText == "number")
        #expect(await wire.isSilent())
    }

    // MARK: Reused ids

    @Test func outputOfACancelledHandlerNeverReachesANewRequestWithTheSameId() async throws {
        let oldGate = ICGate()
        let newGate = ICGate()
        let oldDone = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "old")) { _, context in
            await oldGate.wait()
            context.progress(50)
            context.log(.error, "from the old request")
            oldDone.enter()
            return .text("old")
        }
        try server.register(tool: ToolDefinition(name: "new")) { _, context in
            context.progress(1)
            await newGate.wait()
            return .text("new")
        }
        let wire = ICWire(server)
        wire.call("old", id: 7, meta: ["progressToken": "old-token", MetaKey.logLevel: "debug"])
        wire.cancel(7)
        wire.call("new", id: 7, meta: ["progressToken": "new-token", MetaKey.logLevel: "debug"])
        let progress = try await wire.next()
        #expect(progress["params"]?["progressToken"] == "new-token")
        // The old handler, which ignored its cancellation, now reports and returns.
        oldGate.open()
        #expect(await independentConcurrencyEventually { oldDone.total == 1 })
        #expect(await wire.isSilent(for: .milliseconds(150)))
        newGate.open()
        let response = try await wire.next()
        #expect(response["id"] == 7)
        #expect(response.independentConcurrencyText == "new")
        #expect(await wire.isSilent())
        let all = wire.sink.history.compactMap(\.json)
        #expect(!all.contains { $0["params"]?["progressToken"] == "old-token" })
        #expect(!all.contains { $0["method"] == "notifications/message" })
    }

    @Test func oldHandlerFinishingLastDoesNotAnswerTwice() async throws {
        let oldGate = ICGate()
        let oldDone = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "old")) { _, _ in
            await oldGate.wait()
            oldDone.enter()
            return .text("old")
        }
        try server.register(tool: ToolDefinition(name: "new")) { _, _ in .text("new") }
        let wire = ICWire(server)
        wire.call("old", id: "same")
        wire.cancel("same")
        #expect(try await wire.request("tools/call", ["name": "new"], id: "same").independentConcurrencyText == "new")
        oldGate.open()
        #expect(await independentConcurrencyEventually { oldDone.total == 1 })
        #expect(await wire.isSilent(for: .milliseconds(150)))
        #expect(wire.sink.history.count == 1)
    }

    // MARK: Frames already queued

    @Test func framesQueuedForACancelledRequestAreWithdrawn() async throws {
        let gate = ICGate()
        let reached = ICMeter()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "chatty")) { _, context in
            context.progress(1)
            context.log(.warning, "queued")
            context.progress(2)
            reached.enter()
            await gate.wait()
            return .text("done")
        }
        let wire = ICWire(server)
        let other = wire.call("chatty", meta: ["progressToken": "keep", MetaKey.logLevel: "debug"])
        let id = wire.call("chatty", meta: ["progressToken": "drop", MetaKey.logLevel: "debug"])
        #expect(await independentConcurrencyEventually { reached.total == 2 })
        // Nothing has been read yet: six frames wait in the writer's queue.
        #expect(wire.sink.history.count == 6)
        wire.cancel(id)
        let remaining = wire.sink.sent.compactMap(\.json)
        #expect(remaining.count == 3)
        #expect(!remaining.contains { $0["params"]?["progressToken"] == "drop" })
        #expect(wire.sink.discards == [id])
        gate.open()
        #expect(try await wire.response(to: other).independentConcurrencyText == "done")
        #expect(await wire.isSilent())
    }

    // MARK: Many at once

    @Test func manyCancellationsAtOnceLeaveNoTraceAndFreeEverySlot() async throws {
        let sleeping = ICMeter()
        let holding = ICMeter()
        let gate = ICGate()
        let server = independentConcurrencyServer { configuration in
            configuration.budgets.maxConcurrentHandlers = 4
            configuration.budgets.maxQueuedRequests = 60
        }
        try server.register(tool: ToolDefinition(name: "sleep")) { _, _ in
            sleeping.enter()
            defer { sleeping.leave() }
            try await Task.sleep(for: .seconds(120))
            return .text("woke")
        }
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            holding.enter()
            await gate.wait()
            return .text("held")
        }
        let wire = ICWire(server)
        var ids: [RequestID] = []
        for _ in 0..<64 { ids.append(wire.call("sleep")) }
        #expect(wire.sink.history.isEmpty, "all 64 fit: 4 running and 60 queued")
        for id in ids.shuffled() { wire.cancel(id) }
        #expect(await independentConcurrencyEventually { sleeping.current == 0 })
        #expect(await wire.isSilent(for: .milliseconds(100)))
        #expect(wire.sink.history.isEmpty)

        // Every handler slot and every queue slot is free again: exactly 4 + 60 fit once more.
        for _ in 0..<4 { wire.call("hold") }
        #expect(await independentConcurrencyEventually { holding.total == 4 }, "the four handler slots were not all released")
        var queued: [RequestID] = []
        for _ in 0..<60 { queued.append(wire.call("hold")) }
        #expect(wire.sink.history.isEmpty, "a queue slot was not released by cancellation")
        let extra = wire.call("hold")
        let refused = try await wire.next()
        #expect(refused["id"] == extra.json)
        #expect(refused.independentConcurrencyErrorCode == MCPError.Code.overloaded)
        gate.open()
        var answered = 0
        for _ in 0..<64 {
            let message = try await wire.next()
            if message.independentConcurrencyText == "held" { answered += 1 }
        }
        #expect(answered == 64)
        #expect(await wire.isSilent())
    }

    // MARK: A handler that ignores cancellation

    /// `.serial` promises handlers one at a time. A cancelled handler that is still running is
    /// still user code in progress, so the next handler must not start beside it.
    @Test func serialModeDoesNotOverlapACancelledHandlerThatIsStillRunning() async throws {
        let gate = ICGate()
        let active = ICMeter()
        let server = independentConcurrencyServer { $0.execution = .serial }
        try server.register(tool: ToolDefinition(name: "stubborn")) { _, _ in
            active.enter()
            await gate.wait()
            active.leave()
            return .text("late")
        }
        try server.register(tool: ToolDefinition(name: "next")) { _, _ in
            active.enter()
            active.leave()
            return .text("next")
        }
        let wire = ICWire(server)
        let first = wire.call("stubborn")
        #expect(await independentConcurrencyEventually { active.current == 1 })
        wire.cancel(first)
        let second = wire.call("next")
        #expect(await wire.isSilent(for: .milliseconds(100)))
        #expect(active.peak == 1)
        gate.open()
        #expect(try await wire.response(to: second).independentConcurrencyText == "next")
        #expect(active.peak == 1)
        #expect(await wire.isSilent())
        #expect(wire.framesSent(for: first).isEmpty)
    }

    // MARK: Requests that cannot be cancelled

    /// Legacy: "The `initialize` request MUST NOT be cancelled by clients". A client that does it
    /// anyway must not damage the session.
    @Test func cancellingInitializeChangesNothing() async throws {
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "echo")) { _, _ in .text("ok") }
        let wire = ICWire(server, modern: false)
        let response = try await wire.request(
            "initialize",
            ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "c", "version": "1"]], id: 1)
        #expect(response["result"]?["protocolVersion"] == "2025-11-25")
        wire.cancel(1)
        wire.notify("notifications/initialized")
        wire.cancel(1)
        #expect(await wire.isSilent(for: .milliseconds(50)))
        #expect(try await wire.request("tools/call", ["name": "echo"]).independentConcurrencyText == "ok")
        #expect(try await wire.request("ping").independentConcurrencyErrorCode == nil)
    }

    // MARK: Batches (2025-03-26)

    @Test func cancelledBatchMemberIsLeftOutOfTheReply() async throws {
        let slow = ICGate()
        let fast = ICGate()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "slow")) { _, _ in
            await slow.wait()
            return .text("slow")
        }
        try server.register(tool: ToolDefinition(name: "fast")) { _, _ in
            await fast.wait()
            return .text("fast")
        }
        let wire = try await connect(server, .v2025_03_26)
        func batch(_ first: Int, _ second: Int) {
            wire.send([
                ["jsonrpc": "2.0", "id": JSONValue(first), "method": "tools/call", "params": ["name": "slow"]],
                ["jsonrpc": "2.0", "id": JSONValue(second), "method": "tools/call", "params": ["name": "fast"]],
            ])
        }
        // Cancelled before the other member finishes.
        batch(1, 2)
        wire.cancel(1)
        #expect(await wire.isSilent(for: .milliseconds(50)))
        fast.open()
        let reply = try await wire.next()
        #expect(reply.arrayValue?.count == 1)
        #expect(reply[0]?["id"] == 2)
        #expect(reply[0]?.independentConcurrencyText == "fast")

        // Cancelled after the other member finished: the reply is completed by the cancellation.
        batch(3, 4)
        #expect(await wire.isSilent(for: .milliseconds(100)))
        wire.cancel(3)
        let second = try await wire.next()
        #expect(second.arrayValue?.count == 1)
        #expect(second[0]?["id"] == 4)
        slow.open()
        #expect(await wire.isSilent(for: .milliseconds(150)))
    }

    /// JSON-RPC 2.0 §6: with no response objects to send, "the server MUST NOT return an empty
    /// Array and should return nothing at all".
    @Test func batchWhoseEveryMemberIsCancelledGetsNoReply() async throws {
        let gate = ICGate()
        let server = independentConcurrencyServer()
        try server.register(tool: ToolDefinition(name: "hold")) { _, _ in
            await gate.wait()
            return .text("held")
        }
        let wire = try await connect(server, .v2025_03_26)
        let mark = wire.sink.mark
        wire.send([
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "hold"]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "hold"]],
            ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]],
        ])
        wire.cancel(2)
        gate.open()
        #expect(await wire.isSilent(for: .milliseconds(150)))
        #expect(wire.sink.history.count == mark)
    }
}
