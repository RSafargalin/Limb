import Limb
import LimbTesting
import Synchronization
import Testing

// S3: listings and `server/discover` go out as ordinary output; while ordinary output is over
// budget the answer is -31001; `maxResponseBytes` applies (-31002); the connection is marked
// overflowed only when the urgent reserve refuses AND ordinary output is over budget.

private typealias ICBox = IndependentConcurrencyBox

private enum Kind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case tools, resources, templates, prompts

    var method: String {
        switch self {
        case .tools: "tools/list"
        case .resources: "resources/list"
        case .templates: "resources/templates/list"
        case .prompts: "prompts/list"
        }
    }

    var member: String {
        switch self {
        case .tools: "tools"
        case .resources: "resources"
        case .templates: "resourceTemplates"
        case .prompts: "prompts"
        }
    }

    var testDescription: String { rawValue }
}

/// About 1.3 MB of definitions of each kind: more than the 1 MiB urgent reserve.
private let itemCount = 2800
private let descriptionBytes = 450

private func register(_ kind: Kind, on server: Server, count: Int = itemCount) throws {
    let description = String(repeating: "d", count: descriptionBytes)
    for index in 0..<count {
        switch kind {
        case .tools:
            try server.register(tool: ToolDefinition(name: "t\(index)", description: description)) { _, _ in .text("") }
        case .resources:
            try server.register(resource: ResourceDefinition(uri: "r2://r/\(index)", name: "r\(index)", description: description)) {
                request, _ in [.text(uri: request.uri, text: "")]
            }
        case .templates:
            try server.register(
                resourceTemplate: ResourceTemplateDefinition(uriTemplate: "r2://m\(index)/{x}", name: "m\(index)", description: description)
            ) { request, _ in [.text(uri: request.uri, text: "")] }
        case .prompts:
            try server.register(prompt: PromptDefinition(name: "p\(index)", description: description)) { _, _ in
                PromptResult(messages: [])
            }
        }
    }
}

/// One server per kind, built once: registering thousands of items is the slow part.
private let largeServers: [Kind: Server] = {
    var servers: [Kind: Server] = [:]
    for kind in Kind.allCases {
        let server = round2EngineServer()
        try! register(kind, on: server)
        servers[kind] = server
    }
    return servers
}()

private func client(_ server: Server, version: ProtocolVersion) async throws -> TestClient {
    if version == .v2026_07_28 { return TestClient(server) }
    let client = TestClient(server, modern: false)
    try await client.initialize(version: version)
    return client
}

private let allVersions: [ProtocolVersion] = [.v2026_07_28, .v2025_11_25, .v2025_06_18, .v2025_03_26]

@Suite(.timeLimit(.minutes(3)))
struct Round2EngineListingTests {
    // MARK: Large listings are served

    @Test(arguments: Kind.allCases, allVersions)
    private func aListingLargerThanTheReserveIsServed(kind: Kind, version: ProtocolVersion) async throws {
        let client = try await client(largeServers[kind]!, version: version)
        let response = try await client.request(kind.method)
        #expect(response["result"]?[kind.member]?.arrayValue?.count == itemCount)
    }

    @Test(arguments: Kind.allCases)
    private func aLargeListingThroughARealQueueNeitherOverflowsNorUsesTheReserve(kind: Kind) async throws {
        let client = Round2EngineQueueClient(largeServers[kind]!, budget: 64 << 20)
        client.post(kind.method, id: "l")
        #expect(!client.overflowed)
        #expect(client.queue.usage.urgentBytes == 0)
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.count == 1)
        #expect(frames.first?["result"]?[kind.member]?.arrayValue?.count == itemCount)
        #expect((client.queue.usage.ordinaryBytes, client.queue.usage.urgentBytes) == (0, 0))
    }

    @Test func aLargeDiscoveryIsServed() async throws {
        let instructions = String(repeating: "i", count: 1_500_000)
        let server = round2EngineServer { $0.instructions = instructions }
        let client = Round2EngineQueueClient(server, budget: 64 << 20)
        client.post("server/discover", id: "d")
        #expect(!client.overflowed)
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.first?["result"]?["instructions"]?.stringValue?.utf8.count == 1_500_000)
    }

    @Test func aListingInsideABatchLargerThanTheReserveIsServed() async throws {
        let server = round2EngineServer()
        try register(.tools, on: server, count: 2500)
        try register(.prompts, on: server, count: 2500)
        let client = TestClient(server, modern: false)
        try await client.initialize(version: .v2025_03_26)
        client.send(
            #"[{"jsonrpc":"2.0","id":"t","method":"tools/list"},{"jsonrpc":"2.0","id":"p","method":"prompts/list"},{"jsonrpc":"2.0","id":"x","method":"ping"}]"#
        )
        let reply = try #require(try await client.next().arrayValue)
        #expect(reply.map { $0["id"]?.stringValue } == ["t", "p", "x"])
        #expect(reply[0]["result"]?["tools"]?.arrayValue?.count == 2500)
        #expect(reply[1]["result"]?["prompts"]?.arrayValue?.count == 2500)
    }

    // MARK: maxResponseBytes

    @Test(arguments: Kind.allCases, allVersions)
    private func aListingLargerThanMaxResponseBytesIsRefused(kind: Kind, version: ProtocolVersion) async throws {
        let server = round2EngineServer { $0.budgets.maxResponseBytes = 100_000 }
        try register(kind, on: server, count: 300)
        let client = try await client(server, version: version)
        let response = try await client.request(kind.method)
        #expect(response.round2EngineCode == -31002)
        // The connection is fine afterwards (2026-07-28 has no ping).
        #expect(try await client.request(version == .v2026_07_28 ? "server/discover" : "ping")["result"] != nil)
    }

    @Test func aDiscoveryLargerThanMaxResponseBytesIsRefused() async throws {
        let server = round2EngineServer { configuration in
            configuration.budgets.maxResponseBytes = 100_000
            configuration.instructions = String(repeating: "i", count: 100_000)
        }
        let response = try await TestClient(server).request("server/discover")
        #expect(response.round2EngineCode == -31002)
    }

    @Test func aListingExactlyAtMaxResponseBytesIsServed() async throws {
        // Measure the frame, then serve it with exactly that limit and one byte less.
        let roomy = round2EngineServer()
        try register(.tools, on: roomy, count: 50)
        let probe = Round2EngineQueueClient(roomy, budget: 64 << 20)
        probe.post("tools/list", id: "l")
        let size = probe.drain()[0].count

        for (limit, served) in [(size, true), (size - 1, false)] {
            let server = round2EngineServer { $0.budgets.maxResponseBytes = limit }
            try register(.tools, on: server, count: 50)
            let client = Round2EngineQueueClient(server, budget: 64 << 20)
            client.post("tools/list", id: "l")
            let frame = Round2EngineQueueClient.parse(client.drain())[0]
            #expect((frame["result"] != nil) == served, "limit \(limit), frame \(size)")
            if !served { #expect(frame.round2EngineCode == -31002) }
        }
    }

    // MARK: Pagination

    @Test(arguments: [ProtocolVersion.v2026_07_28, .v2025_03_26])
    func pagesOfALargeListAreEachSmall(version: ProtocolVersion) async throws {
        let server = round2EngineServer { configuration in
            configuration.pageSize = 1000
            configuration.budgets.maxResponseBytes = 600_000
        }
        try register(.tools, on: server)
        let client = try await client(server, version: version)
        var names: [String] = []
        var cursor: JSONValue?
        var pages = 0
        repeat {
            var params: JSONObject = [:]
            if let cursor { params["cursor"] = cursor }
            let response = try await client.request("tools/list", params)
            let tools = try #require(response["result"]?["tools"]?.arrayValue, "\(response)")
            names += tools.compactMap { $0["name"]?.stringValue }
            cursor = response["result"]?["nextCursor"]
            pages += 1
        } while cursor != nil && pages < 10
        #expect(pages == 3)
        #expect(names == (0..<itemCount).map { "t\($0)" })
    }

    // MARK: A peer that does not read

    @Test func overBudgetAListingIsRefusedWithOverloadAndTheConnectionStaysUsable() async throws {
        let client = Round2EngineQueueClient(largeServers[.tools]!, budget: 256 << 10, reserve: 32 << 10)
        client.post("tools/list", id: "l1")
        // The first listing is queued although it is larger than the budget: the queue was
        // under budget when it arrived. Now it is over.
        #expect(client.queue.isOverBudget)
        client.post("tools/list", id: "l2")
        client.post("server/discover", id: "d")
        client.post("no/such/method", id: "p")
        let overflowed = client.overflowed
        #expect(!overflowed)
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.map { $0["id"]?.stringValue } == ["l1", "l2", "d", "p"])
        #expect(frames[0]["result"]?["tools"]?.arrayValue?.count == itemCount)
        #expect(frames[1].round2EngineCode == -31001)
        // A small discovery (at most 64 KiB) is answered from the reserve as before.
        #expect(frames[2]["result"]?["supportedVersions"] != nil)
        #expect(frames[3].round2EngineCode == -32601)
        // Once the peer has read, listings are served again.
        client.post("tools/list", id: "l3")
        #expect(Round2EngineQueueClient.parse(client.drain()).first?["result"]?["tools"]?.arrayValue?.count == itemCount)
    }

    @Test func aDeadPeerAskingForListingsIsDetectedAndMemoryStaysBounded() async throws {
        let budget = 256 << 10
        let reserve = 32 << 10
        let client = Round2EngineQueueClient(largeServers[.tools]!, budget: budget, reserve: reserve)
        client.post("tools/list", id: "first")
        let listing = client.queue.usage.ordinaryBytes
        #expect(listing > 1 << 20)
        var sent = 0
        var peak = (ordinary: 0, urgent: 0)
        while !client.overflowed, sent < 20_000 {
            client.post("tools/list", id: "l\(sent)")
            sent += 1
            let usage = client.queue.usage
            peak = (max(peak.ordinary, usage.ordinaryBytes), max(peak.urgent, usage.urgentBytes))
        }
        #expect(client.overflowed, "never marked overflowed after \(sent) listings")
        // One listing, then refusals in the reserve: the refusals of about 100 bytes each fill
        // 32 KiB after a few hundred requests.
        #expect(sent < 2000)
        #expect(peak.urgent <= reserve)
        #expect(peak.ordinary == listing)
    }

    @Test func aDeadPeerSendingPingsIsDetectedAndMemoryStaysBounded() async throws {
        let budget = 64 << 10
        let reserve = 16 << 10
        let client = Round2EngineQueueClient(round2EngineServer(), budget: budget, reserve: reserve)
        var sent = 0
        while !client.overflowed, sent < 50_000 {
            client.post("ping", id: "p\(sent)")
            sent += 1
        }
        #expect(client.overflowed)
        let usage = client.queue.usage
        #expect(usage.urgentBytes <= reserve)
        // Pings overflow from the reserve into ordinary output until that is over budget.
        #expect(usage.ordinaryBytes <= budget + 200)
        #expect(usage.ordinaryBytes > budget)
    }

    @Test func aReadingPeerIsNotCutOffWhenOnlyTheReserveIsFull() async throws {
        // A burst of small answers larger than the reserve, while ordinary output is well within
        // its budget: the peer is reading (it just has not got round to it), not dead.
        let client = Round2EngineQueueClient(round2EngineServer(), budget: 1 << 20, reserve: 1 << 10)
        for index in 0..<200 { client.post("ping", id: "p\(index)") }
        #expect(!client.overflowed)
        let ids = Round2EngineQueueClient.parse(client.drain()).compactMap { $0["id"]?.stringValue }
        #expect(ids == (0..<200).map { "p\($0)" })
    }

    @Test func aSmallListingBehindALargeToolResultWhileOverBudget() async throws {
        // What a peer that reads slowly sees: a small listing that arrives while a large result
        // waits to be written is answered at once from the reserve.
        let server = round2EngineServer()
        try round2EngineRegisterBlob(server)
        let client = Round2EngineQueueClient(server, budget: 64 << 10)
        client.post("tools/call", id: "big", params: #""name":"blob","arguments":{"size":100000}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        client.post("tools/list", id: "l")
        client.post("ping", id: "p")
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.map { $0["id"]?.stringValue } == ["big", "l", "p"])
        #expect(frames[1]["result"]?["tools"]?.arrayValue?.count == 1)
        #expect(frames[0]["result"] != nil)
        #expect(!client.overflowed)
    }

    @Test func aListingMemberOfABatchWhileOverBudgetIsRefusedAlone() async throws {
        let server = round2EngineServer()
        try round2EngineRegisterBlob(server)
        let client = Round2EngineQueueClient(server, budget: 64 << 10)
        client.send(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        )
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        client.drain()
        client.send(#"{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"blob","arguments":{"size":100000}}}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        client.send(#"[{"jsonrpc":"2.0","id":"l","method":"tools/list"},{"jsonrpc":"2.0","id":"p","method":"ping"}]"#)
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.count == 2)
        let reply = try #require(frames.last?.arrayValue)
        #expect(reply.map { $0["id"]?.stringValue } == ["l", "p"])
        // Small: answered.
        #expect(reply[0]["result"]?["tools"]?.arrayValue?.count == 1)
        #expect(reply[1]["result"] != nil)
    }

    @Test func aLargeListingMemberOfABatchWhileOverBudgetIsRefusedAlone() async throws {
        let server = round2EngineServer()
        try round2EngineRegisterBlob(server)
        try register(.tools, on: server, count: 300)
        let client = Round2EngineQueueClient(server, budget: 64 << 10)
        try client.initializeLegacy(.v2025_03_26)
        client.send(#"{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"blob","arguments":{"size":100000}}}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        client.send(#"[{"jsonrpc":"2.0","id":"l","method":"tools/list"},{"jsonrpc":"2.0","id":"p","method":"ping"}]"#)
        let frames = Round2EngineQueueClient.parse(client.drain())
        let reply = try #require(frames.last?.arrayValue)
        #expect(reply.map { $0["id"]?.stringValue } == ["l", "p"])
        #expect(reply[0].round2EngineCode == -31001)
        #expect(reply[1]["result"] != nil)
    }

    // MARK: Order

    @Test func smallListingsKeepTheirPlaceAmongReaderAnswers() async throws {
        let server = round2EngineServer()
        try register(.tools, on: server, count: 3)
        let client = Round2EngineQueueClient(server, budget: 1 << 20)
        client.post("tools/list", id: "1")
        client.post("ping", id: "2")
        client.post("server/discover", id: "3")
        client.post("nonexistent/method", id: "4")
        client.post("tools/list", id: "5")
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.map { $0["id"]?.stringValue } == ["1", "2", "3", "4", "5"])
        #expect(frames[0]["result"]?["tools"]?.arrayValue?.count == 3)
    }

    // MARK: Frames larger than the small bound while over budget

    /// An error answer that is not small (an id of 6000 characters against a 16 KiB reserve,
    /// whose small bound is 4 KiB) while ordinary output is over budget: replaced by -31001 under
    /// the same id. Every request is answered, none twice; the connection lives on.
    @Test func aLargeErrorWhileOverBudgetIsReplacedByOverloadUnderItsOwnID() async throws {
        let server = round2EngineServer()
        try round2EngineRegisterBlob(server)
        let client = Round2EngineQueueClient(server, budget: 64 << 10, reserve: 16 << 10)
        client.post("tools/call", id: "big", params: #""name":"blob","arguments":{"size":100000}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        let ids = (0..<2).map { "\($0)" + String(repeating: "i", count: 6000) }
        for id in ids { client.post("no/such/method", id: id) }
        #expect(!client.overflowed)
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.map { $0["id"]?.stringValue } == ["big"] + ids)
        #expect(frames.dropFirst().allSatisfy { $0.round2EngineCode == -31001 })
        client.post("server/discover", id: "d")
        #expect(Round2EngineQueueClient.parse(client.drain()).first?["id"] == "d")
    }

    // MARK: The 64 KiB rule for results built on the reader

    /// A server whose `tools/list` frame (id "l", 2026-07-28) is exactly `size` bytes.
    private static func listingServer(frameBytes size: Int) throws -> Server {
        func make(_ description: Int) throws -> Server {
            let server = round2EngineServer()
            try round2EngineRegisterBlob(server)
            try server.register(tool: ToolDefinition(name: "t", description: String(repeating: "d", count: description))) { _, _ in .text("") }
            return server
        }
        let probe = Round2EngineQueueClient(try make(1000), budget: 64 << 20)
        probe.post("tools/list", id: "l")
        let measured = probe.drain()[0].count
        let server = try make(1000 + size - measured)
        let check = Round2EngineQueueClient(server, budget: 64 << 20)
        check.post("tools/list", id: "l")
        let frame = check.drain()[0].count
        guard frame == size else { throw IndependentConcurrencyError("built a \(frame)-byte listing, wanted \(size)") }
        return server
    }

    @Test(arguments: [(65_536, true), (65_537, false)])
    func theSmallResultBoundaryIsExactWhileOverBudget(size: Int, answered: Bool) async throws {
        let server = try Self.listingServer(frameBytes: size)
        let client = Round2EngineQueueClient(server, budget: 64 << 10)
        client.post("tools/call", id: "big", params: #""name":"blob","arguments":{"size":100000}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        client.post("tools/list", id: "l")
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.map { $0["id"]?.stringValue } == ["big", "l"])
        if answered {
            #expect(frames.last?["result"] != nil)
        } else {
            #expect(frames.last?.round2EngineCode == -31001)
        }
        #expect(!client.overflowed)
    }

    /// With a reserve smaller than 64 KiB, a "small" listing that does not fit the reserve
    /// arrives while ordinary output is over budget. The peer must get an answer: the listing
    /// or the overload error, as a larger listing would.
    @Test func aSmallListingLargerThanAConfiguredSmallReserveIsAnsweredWhileOverBudget() async throws {
        let lines = IndependentConcurrencyBox<[String]>([])
        let server = round2EngineServer(lines: lines)
        try round2EngineRegisterBlob(server)
        try register(.tools, on: server, count: 60)
        let client = Round2EngineQueueClient(server, budget: 64 << 10, reserve: 16 << 10)
        // Not over budget: served (as ordinary output).
        client.post("tools/list", id: "first")
        let first = Round2EngineQueueClient.parse(client.drain())
        #expect(first.first?["result"]?["tools"]?.arrayValue?.count == 61)
        // Over budget.
        client.post("tools/call", id: "big", params: #""name":"blob","arguments":{"size":100000}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        client.post("tools/list", id: "l")
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.map { $0["id"]?.stringValue } == ["big", "l"], "lines: \(lines.value)")
        #expect(frames.last?.round2EngineCode == -31001)
        #expect(!client.overflowed)
    }

    /// A batch of small listings whose joined reply is larger than the (default, 1 MiB)
    /// reserve, while a large result waits to be written: the batch must be answered.
    @Test func aBatchOfSmallListingsLargerThanTheReserveIsAnsweredWhileOverBudget() async throws {
        let lines = IndependentConcurrencyBox<[String]>([])
        let server = round2EngineServer(lines: lines)
        try round2EngineRegisterBlob(server)
        try register(.tools, on: server, count: 110)  // about 60 kB: a small result
        let client = Round2EngineQueueClient(server, budget: 64 << 10)
        try client.initializeLegacy(.v2025_03_26)
        client.send(#"{"jsonrpc":"2.0","id":"probe","method":"tools/list"}"#)
        let listing = client.drain()[0].count
        #expect(listing <= 65_536 && listing > 50_000, "\(listing)")
        client.send(#"{"jsonrpc":"2.0","id":"big","method":"tools/call","params":{"name":"blob","arguments":{"size":100000}}}"#)
        #expect(await independentConcurrencyEventually { client.queue.usage.queuedFrames == 1 })
        let members = (0..<20).map { #"{"jsonrpc":"2.0","id":"l\#($0)","method":"tools/list"}"# }
        client.send("[" + members.joined(separator: ",") + "]")
        let frames = Round2EngineQueueClient.parse(client.drain())
        #expect(frames.count == 2, "lines: \(lines.value)")
        let reply = try #require(frames.last?.arrayValue)
        #expect(reply.map { $0["id"]?.stringValue } == (0..<20).map { "l\($0)" })
        // Each listing is replaced only until the reply is small (64 KiB): one may stay.
        #expect(reply.filter { $0.round2EngineCode == -31001 }.count >= 19)
        #expect(!client.overflowed)
    }

    @Test func aDeadPeerAskingForSmallListingsIsDetectedAndMemoryStaysBounded() async throws {
        let server = round2EngineServer()
        try register(.tools, on: server, count: 110)
        let budget = 256 << 10
        let reserve = 1 << 20
        let client = Round2EngineQueueClient(server, budget: budget, reserve: reserve)
        var sent = 0
        var peak = (ordinary: 0, urgent: 0)
        while !client.overflowed, sent < 5000 {
            client.post("tools/list", id: "l\(sent)")
            sent += 1
            let usage = client.queue.usage
            peak = (max(peak.ordinary, usage.ordinaryBytes), max(peak.urgent, usage.urgentBytes))
        }
        #expect(client.overflowed, "never detected after \(sent) listings")
        #expect(peak.urgent <= reserve)
        #expect(peak.ordinary <= budget + 70_000)
        // Reserve (about 17 listings) plus budget (about 5) and one more.
        #expect(sent < 40)
    }

    @Test func aDeadPeerAgainstASmallReserveIsDetectedOrAtLeastBounded() async throws {
        // Listings of about 33 kB against a 16 KiB reserve: none ever fits the reserve.
        let lines = IndependentConcurrencyBox<[String]>([])
        let server = round2EngineServer(lines: lines)
        try register(.tools, on: server, count: 60)
        let client = Round2EngineQueueClient(server, budget: 64 << 10, reserve: 16 << 10)
        client.post("tools/list", id: "probe")
        let listing = client.queue.usage.ordinaryBytes
        var peak = 0
        var sent = 0
        while !client.overflowed, sent < 5000 {
            client.post("tools/list", id: "l\(sent)")
            sent += 1
            peak = max(peak, client.queue.usage.ordinaryBytes + client.queue.usage.urgentBytes)
        }
        #expect(client.overflowed, "never detected after \(sent) listings")
        // Budget, plus the one listing that arrived while just under it, plus the reserve.
        #expect(peak <= (64 << 10) + listing + (16 << 10), "peak \(peak), listing \(listing)")
    }

    @Test func aLargeInitializeIsBoundedByMaxResponseBytes() async throws {
        let server = round2EngineServer { configuration in
            configuration.budgets.maxResponseBytes = 100_000
            configuration.instructions = String(repeating: "i", count: 150_000)
        }
        let client = Round2EngineQueueClient(server, budget: 64 << 20)
        client.send(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        )
        let answer = Round2EngineQueueClient.parse(client.drain())
        #expect(answer.first?.round2EngineCode == -31002)
        // The client was told initialize failed; does the server think a session exists?
        client.send(#"{"jsonrpc":"2.0","id":1,"method":"logging/setLevel","params":{"level":"info"}}"#)
        let after = Round2EngineQueueClient.parse(client.drain())
        #expect(after.first?["result"] == nil, "\(after)")
        #expect(after.first?.round2EngineCode == -32602)
    }
}
