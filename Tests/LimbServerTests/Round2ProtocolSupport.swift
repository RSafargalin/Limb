import Foundation
import Limb
import LimbTesting
import Synchronization
import Testing


/// Collects what a server reports through `ServerConfiguration.diagnostics`.
final class R2PDiagnostics: Sendable {
    private let lines = Mutex<[String]>([])
    func record(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
    func clear() { lines.withLock { $0 = [] } }
}

enum R2P {
    /// A server whose diagnostics go to `diagnostics` instead of stderr.
    static func server(
        diagnostics: R2PDiagnostics = R2PDiagnostics(), configure: (inout ServerConfiguration) -> Void = { _ in }
    ) -> Server {
        var configuration = ServerConfiguration(info: Implementation(name: "r2p", version: "1.0.0"))
        configuration.diagnostics = { diagnostics.record($0) }
        configure(&configuration)
        return Server(configuration: configuration)
    }

    /// A client speaking `revision`, after `initialize` for legacy revisions.
    static func client(
        _ server: Server, _ revision: IndependentProtocolRevision, capabilities: JSONObject = [:]
    ) async throws -> TestClient {
        try await IndependentProtocol.client(server, revision, capabilities: capabilities)
    }

    /// The next message, which must be a request or notification named `method`.
    static func expectMessage(
        _ client: TestClient, _ method: String, timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> JSONValue {
        let message = try await client.next(timeout: timeout)
        try #require(message["method"]?.stringValue == method, "expected \(method), got \(message)", sourceLocation: sourceLocation)
        return message
    }

    /// Answers a request from the server with `result`.
    static func answer(_ client: TestClient, _ request: JSONValue, _ result: JSONValue) {
        client.send(["jsonrpc": "2.0", "id": request["id"] ?? .null, "result": result])
    }

    /// Everything the server sends until the response to `id`, which comes last.
    static func collect(_ client: TestClient, until id: RequestID, timeout: Duration = .seconds(10)) async throws -> [JSONValue] {
        var seen: [JSONValue] = []
        while true {
            let message = try await client.next(timeout: timeout)
            seen.append(message)
            if message["method"] == nil, message["id"] == id.json { return seen }
        }
    }

    static func keys(_ value: JSONValue?) -> Set<String> {
        Set((value?.objectValue ?? JSONObject()).map(\.key))
    }

    static let formSchema: JSONObject = [
        "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
    ]

    static let samplingReply: JSONValue = ["role": "assistant", "content": ["type": "text", "text": "ok"], "model": "m"]
}

extension JSONValue {
    var r2pCode: Int? { self["error"]?["code"]?.intValue }
    var r2pText: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
    var r2pIsToolError: Bool { self["result"]?["isError"] == true }
}

/// A value shared between a handler and the test.
final class R2PBox<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { state.withLock { body(&$0) } }
    var value: Value { state.withLock { $0 } }
}

/// A one-shot flag a test raises for a handler to see.
final class R2PSignal: Sendable {
    static let shared = R2PSignal()
    private let raised = Mutex(false)
    func fire() { raised.withLock { $0 = true } }
    /// Whether the flag was raised; lowers it.
    func take() -> Bool? { raised.withLock { flag in defer { flag = false }; return flag ? true : nil } }
}
