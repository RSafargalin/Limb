import Limb
import LimbTesting
import Synchronization
import Testing


/// `_meta` of a `2026-07-28` request, as raw JSON members.
let round2EngineModernMeta =
    #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

/// A server with no registrations and diagnostics collected in `lines` (if given).
func round2EngineServer(
    lines: IndependentConcurrencyBox<[String]>? = nil, _ configure: (inout ServerConfiguration) -> Void = { _ in }
) -> Server {
    Server(name: "round2-engine", version: "0.0.1") { configuration in
        if let lines {
            configuration.diagnostics = { line in lines.update { $0.append(line) } }
        } else {
            configuration.diagnostics = { _ in }
        }
        configure(&configuration)
    }
}

/// Registers `blob`: returns a text of `size` bytes (argument `size`, default 10).
func round2EngineRegisterBlob(_ server: Server, name: String = "blob") throws {
    try server.register(tool: ToolDefinition(name: name)) { arguments, _ in
        .text(String(repeating: "x", count: arguments["size"]?.intValue ?? 10))
    }
}

/// Registers `count` tools whose definitions take about `descriptionBytes` bytes each.
func round2EngineRegisterManyTools(_ server: Server, count: Int, descriptionBytes: Int = 400) throws {
    let description = String(repeating: "d", count: descriptionBytes)
    for index in 0..<count {
        try server.register(tool: ToolDefinition(name: "t\(index)", description: description)) { _, _ in .text("") }
    }
}

/// A connection on a real `OutboundQueue` that only the test drains.
final class Round2EngineQueueClient: @unchecked Sendable, CustomTestStringConvertible {
    let queue: OutboundQueue
    let connection: Connection

    init(_ server: Server, budget: Int, reserve: Int = 1 << 20) {
        queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: reserve)
        connection = server.connect(to: queue)
    }

    func send(_ frame: String) { connection.receive(Array(frame.utf8)) }

    var overflowed: Bool { connection.hasOverflowed }
    var testDescription: String { "queue client" }

    /// A `2026-07-28` request with raw params members (without braces), `_meta` added.
    func post(_ method: String, id: String, params: String = "") {
        let members = params.isEmpty ? round2EngineModernMeta : params + "," + round2EngineModernMeta
        send(#"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(method)","params":{\#(members)}}"#)
    }

    /// The `initialize` handshake of a legacy revision; drains its answer.
    func initializeLegacy(_ version: ProtocolVersion) throws {
        send(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(version.rawValue)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        )
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let answer = Self.parse(drain())
        guard answer.first?["result"] != nil else { throw IndependentConcurrencyError("initialize failed: \(answer)") }
    }

    /// Takes and "writes" everything queued.
    @discardableResult func drain() -> [[UInt8]] {
        let frames = queue.takeAvailable()
        queue.didWrite()
        return frames
    }

    static func parse(_ frames: [[UInt8]]) -> [JSONValue] { frames.compactMap { try? JSON.parse($0) } }
}

/// Counts how many of its instances were deallocated.
final class Round2EnginePayload: Sendable {
    let released: IndependentConcurrencyBox<Int>
    init(_ released: IndependentConcurrencyBox<Int>) { self.released = released }
    deinit { released.update { $0 += 1 } }
    func touch() -> Int { 1 }
}

/// Runs `body` with a time limit; a hang fails the test instead of stalling the suite.
func round2EngineWithin(_ limit: Duration = .seconds(30), _ body: @escaping @Sendable () async throws -> Void) async {
    let outcome: Result<Void, any Error>? = await independentConcurrencyValue(within: limit) {
        do {
            try await body()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    switch outcome {
    case .none: Issue.record("timed out after \(limit): the server is probably deadlocked")
    case .failure(let error): Issue.record(error)
    case .success: break
    }
}

extension JSONValue {
    var round2EngineCode: Int? { self["error"]?["code"]?.intValue }
    var round2EngineMessage: String? { self["error"]?["message"]?.stringValue }
}

/// The response to `id`, also if it was already read while waiting for another one.
func round2EngineResponse(_ wire: IndependentConcurrencyWire, to id: RequestID) async throws -> JSONValue {
    if let earlier = wire.others.first(where: { $0["method"] == nil && $0["id"] == id.json }) { return earlier }
    return try await wire.response(to: id, timeout: .seconds(30))
}
