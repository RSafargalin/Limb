import Limb
import LimbTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct IndependentLifecycleBoundaryTests {
    private let timeout: Duration = .seconds(3)

    @Test(arguments: IndependentProtocolRevision.legacy)
    func legacyRootsWaitForInitialized(_ revision: IndependentProtocolRevision) async throws {
        let server = Server(name: "Lifecycle fixture", version: "1")
        try server.register(tool: ToolDefinition(name: "read-roots")) { _, context in
            .text(try await context.roots("roots").map(\.uri).joined(separator: ","))
        }
        let client = TestClient(server, modern: false)
        client.send(initializeFrame(id: "initialize", revision: revision, capabilities: #"{"roots":{}}"#))
        let initialization = try await client.next(timeout: timeout)
        try #require(initialization["id"] == "initialize")
        try #require(initialization["result"]?["protocolVersion"] == .string(revision.rawValue))

        let early = client.post("tools/call", ["name": "read-roots"], id: "early")
        let terminal = try await client.next(timeout: timeout)
        try #require(terminal["method"] == nil, "Application request before initialized: \(terminal)")
        try #require(terminal["id"] == early.json)
        #expect(terminal["result"] != nil || terminal["error"] != nil)

        client.notify("notifications/initialized", [:])
        let ready = client.post("tools/call", ["name": "read-roots"], id: "ready")
        let roots = try await client.next(timeout: timeout)
        try #require(roots["method"] == "roots/list")
        let rootsID = try #require(roots["id"])
        try #require(RequestID(json: rootsID) != nil)
        client.send(["jsonrpc": "2.0", "id": rootsID, "result": ["roots": [["uri": "file:///fixture"]]]])
        let completed = try await client.next(timeout: timeout)
        #expect(completed["id"] == ready.json)
        #expect(completed["result"]?["content"]?[0]?["text"] == "file:///fixture")
    }

    @Test
    func initializeInsideLegacyBatchPreservesSessionAndSiblingReplies() async throws {
        let server = Server(name: "Lifecycle fixture", version: "1")
        try server.register(tool: ToolDefinition(name: "has-roots")) { _, context in
            .text(context.clientCapabilities.supportsRoots ? "present" : "absent")
        }
        let client = TestClient(server, modern: false)
        client.send(initializeFrame(id: "standalone", revision: .r2025_03_26, capabilities: #"{"roots":{}}"#))
        let initialization = try await client.next(timeout: timeout)
        try #require(initialization["id"] == "standalone")
        try #require(initialization["result"]?["protocolVersion"] == "2025-03-26")
        client.notify("notifications/initialized", [:])

        let before = #"{"jsonrpc":"2.0","id":"before","method":"ping"}"#
        let initialize = initializeFrame(id: "batched", revision: .r2025_06_18)
        let after = #"{"jsonrpc":"2.0","id":"after","method":"tools/list"}"#
        client.send("[\(before),\(initialize),\(after)]")
        let batch = try await client.next(timeout: timeout)
        let replies = try #require(batch.arrayValue)
        try #require(replies.count == 3)
        let rejected = try #require(replies.first { $0["id"] == "batched" })
        #expect(rejected["error"]?["code"]?.intValue == -32600)
        #expect(rejected["result"] == nil)
        #expect(replies.first { $0["id"] == "before" }?["result"] != nil)
        #expect(replies.first { $0["id"] == "after" }?["result"]?["tools"]?[0]?["name"] == "has-roots")

        let check = #"{"jsonrpc":"2.0","id":"check","method":"tools/call","params":{"name":"has-roots"}}"#
        client.send("[\(check)]")
        let followup = try await client.next(timeout: timeout)
        let followupReplies = try #require(followup.arrayValue)
        #expect(followupReplies.count == 1)
        #expect(followupReplies.first?["id"] == "check")
        #expect(followupReplies.first?["result"]?["content"]?[0]?["text"] == "present")
    }

    @Test
    func requestIDAcceptsOnlyIntegralNumbersAndStrings() throws {
        for (spelling, integer) in [("1e2", 100), ("1.0", 1)] {
            let value = try JSON.parse(Array(spelling.utf8))
            let id = try #require(RequestID(json: value))
            #expect(id.json.doubleValue == Double(integer))
            #expect(id.json.stringValue == nil)
        }
        for spelling in ["1.5", "-1.25", "1e-2"] {
            let value = try JSON.parse(Array(spelling.utf8))
            #expect(RequestID(json: value) == nil, "Accepted fractional ID \(spelling)")
        }
        let string = try #require(RequestID(json: "100"))
        #expect(string == RequestID("100"))
        #expect(string != RequestID(100))
        #expect(string.json == "100")
    }

    @Test(arguments: IndependentProtocolRevision.allCases)
    func wireRepliesPreserveIntegralAndStringIDsAndRejectFractions(
        _ revision: IndependentProtocolRevision
    ) async throws {
        let server = Server(name: "Lifecycle fixture", version: "1")
        let client = try await IndependentProtocol.client(server, revision)
        let method = revision.isModern ? "server/discover" : "ping"
        let params = revision.isModern ? "{\(IndependentProtocol.modernMetaText)}" : "{}"
        let ids: [(String, JSONValue)] = [("1e2", 100), ("1.0", 1), (#""100""#, "100")]
        for (spelling, expectedID) in ids {
            client.send(#"{"jsonrpc":"2.0","id":\#(spelling),"method":"\#(method)","params":\#(params)}"#)
            let reply = try await client.next(timeout: timeout)
            if let number = expectedID.doubleValue {
                #expect(reply["id"]?.doubleValue == number, "Response to raw ID \(spelling)")
                #expect(reply["id"]?.stringValue == nil, "Numeric ID changed type")
            } else {
                #expect(reply["id"] == expectedID, "Response to raw ID \(spelling)")
            }
            #expect(reply["result"] != nil, "Response to raw ID \(spelling)")
        }

        client.send(#"{"jsonrpc":"2.0","id":1.5,"method":"\#(method)","params":\#(params)}"#)
        let rejected = try await client.next(timeout: timeout)
        #expect(rejected["result"] == nil)
        #expect(rejected["error"]?["code"]?.intValue != nil)
        #expect(rejected["id"] == .null)
    }

    @Test(arguments: IndependentProtocolRevision.allCases)
    func fractionalCancellationLeavesWholeRequestRunning(
        _ revision: IndependentProtocolRevision
    ) async throws {
        let server = Server(name: "Lifecycle fixture", version: "1")
        let gate = IndependentConcurrencyGate()
        defer { gate.open() }
        try server.register(tool: ToolDefinition(name: "gated")) { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return .text("completed")
        }
        let client = try await IndependentProtocol.client(server, revision)
        let running = client.post("tools/call", ["name": "gated"], id: RequestID(1))
        let started = await independentConcurrencyEventually(timeout: timeout) { gate.waiting == 1 }
        try #require(started)

        let meta = revision.isModern ? ",\(IndependentProtocol.modernMetaText)" : ""
        client.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5\#(meta)}}"#)
        let sentinel = client.post(revision.isModern ? "server/discover" : "ping", id: "after-cancellation")
        let observed = try await client.next(timeout: timeout)
        try #require(observed["id"] == sentinel.json)
        try #require(observed["result"] != nil)

        gate.open()
        let completed = try await client.next(timeout: timeout)
        #expect(completed["id"] == running.json)
        #expect(completed["result"]?["content"]?[0]?["text"] == "completed")
    }

    private func initializeFrame(
        id: String, revision: IndependentProtocolRevision, capabilities: String = "{}"
    ) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","method":"initialize","params":{"protocolVersion":"\#(revision.rawValue)","capabilities":\#(capabilities),"clientInfo":{"name":"fixture","version":"1"}}}"#
    }
}
