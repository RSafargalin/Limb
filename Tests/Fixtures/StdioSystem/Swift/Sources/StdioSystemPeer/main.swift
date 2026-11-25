import Foundation
import Limb
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let environment = ProcessInfo.processInfo.environment

func setting(_ name: String, _ fallback: Int) -> Int {
    guard let value = environment["LIMB_SYSTEM_" + name], let integer = Int(value), integer >= 0 else {
        return fallback
    }
    return integer
}

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}

func runServer() async throws {
    let server = Server(name: "limb-system", version: "1") { configuration in
        configuration.budgets.maxFrameBytes = setting("FRAME_LIMIT", 2 << 20)
    }
    try server.register(tool: ToolDefinition(
        name: "system_echo",
        inputSchema: [
            "type": "object", "required": ["token"],
            "properties": ["token": ["type": "string"], "responseBytes": ["type": "integer"]],
        ]
    )) { arguments, _ in
        let count = arguments["responseBytes"]?.intValue
        return .text(count.map { String(repeating: "x", count: min(3_000_000, max(0, $0))) }
            ?? arguments["token"]?.stringValue ?? "")
    }
    let state = HoldState()
    try server.register(tool: ToolDefinition(name: "system_state")) { _, _ in
        .text("\(getpid()) \(await state.summary)")
    }
    try server.register(tool: ToolDefinition(name: "system_hold")) { _, _ in
        await state.enter()
        do {
            try await Task.sleep(for: .seconds(180))
            return .text("finished")
        } catch {
            await state.cancel()
            throw error
        }
    }
    for stream in ["alpha", "beta"] {
        let uri = "fixture://system/" + stream
        try server.register(resource: .init(uri: uri, name: stream)) { request, _ in
            [.text(uri: request.uri, mimeType: "text/plain", text: stream)]
        }
    }
    try server.register(tool: ToolDefinition(name: "system_publish", inputSchema: [
        "type": "object", "required": ["stream", "count", "spacingMicros"],
        "properties": ["stream": ["enum": ["alpha", "beta"]], "count": ["type": "integer"],
                       "spacingMicros": ["type": "integer"]],
    ])) { [weak server] arguments, context in
        let stream = arguments["stream"]?.stringValue ?? ""
        let count = max(0, min(100_000, arguments["count"]?.intValue ?? 0))
        let spacing = max(0, min(1_000_000, arguments["spacingMicros"]?.intValue ?? 0))
        for i in 0..<count {
            try Task.checkCancellation()
            server?.notifyResourceUpdated(uri: "fixture://system/" + stream)
            context.progress(Double(i + 1), total: Double(count), message: "\(stream)/\(i + 1)")
            if spacing > 0 { try await Task.sleep(for: .microseconds(spacing)) }
        }
        return .text(String(count))
    }
    await server.run()
}

actor HoldState {
    private var count = 0
    private var cancelled = 0
    var summary: String { "\(count) \(cancelled)" }
    func enter() { count += 1 }
    func cancel() { cancelled += 1 }
}

#if os(macOS)
let clock = ContinuousClock()

func microseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    return Int(parts.seconds) * 1_000_000 + Int(parts.attoseconds / 1_000_000_000_000)
}

func verify(
    _ client: Client, token: String, response: String? = nil, responseBytes: Int? = nil
) async throws {
    var arguments: JSONObject = ["token": .string(token)]
    if let responseBytes { arguments["responseBytes"] = JSONValue(responseBytes) }
    let reply = try await client.callTool("system_echo", arguments: arguments, options: .init(timeout: .seconds(10)))
    guard !reply.value.isError, reply.value.content.count == 1,
        case let .text(text, _, _)? = reply.value.content.first, text == (response ?? token)
    else { throw ProbeError.invalidReply }
}

enum ProbeError: Error { case invalidReply, invalidArguments, wrongRevision }

struct Counts: Sendable {
    var completed = 0
    var bytes = 0
    var histogram: [Int: Int] = [:]
    var errors: [String: Int] = [:]
    var maximum = 0

    mutating func record(_ us: Int, bytes: Int) {
        completed += 1
        self.bytes += bytes
        maximum = max(maximum, us)
        // Integer microsecond buckets, grouped into deciles below the leading digit.
        var unit = 1
        while us / unit >= 100 { unit *= 10 }
        histogram[us / unit * unit, default: 0] += 1
    }

    mutating func merge(_ other: Counts) {
        completed += other.completed
        bytes += other.bytes
        maximum = max(maximum, other.maximum)
        histogram.merge(other.histogram, uniquingKeysWith: +)
        errors.merge(other.errors, uniquingKeysWith: +)
    }
}

func makeClient(_ executable: String, _ arguments: [String], expected: String, recovery: Bool = false) async throws -> Client {
    let legacy: ProtocolVersion?
    switch expected {
    case "2025-03-26": legacy = .v2025_03_26
    case "2025-06-18": legacy = .v2025_06_18
    case "2025-11-25": legacy = .v2025_11_25
    case "2026-07-28", "auto": legacy = nil
    default: throw ProbeError.invalidArguments
    }
    let client = try await Client.connect(
        stdio: .init(executable: executable, arguments: arguments),
        options: .init(
            timeout: .seconds(8), discoveryTimeout: .seconds(2),
            maxFrameBytes: setting("CLIENT_FRAME_LIMIT", 2 << 20),
            maxPending: max(1, setting("MAX_PENDING", 256)), legacyVersion: legacy,
            recovery: recovery ? .init(backoff: .milliseconds(50)) : nil)
    )
    guard expected == "auto" || client.protocolVersion.rawValue == expected else {
        await client.close()
        throw ProbeError.wrongRevision
    }
    return client
}

func runClient(_ executable: String, _ arguments: [String]) async throws -> Bool {
    let expected = environment["LIMB_SYSTEM_REVISION"] ?? "2026-07-28"
    let mode = environment["LIMB_SYSTEM_MODE"] ?? "steady"
    switch mode {
    case "fault": return try await faultCase(executable, arguments, expected: expected)
    case "boundary": return try await boundaryCase(executable, arguments, expected: expected)
    case "churn": return try await churn(executable, arguments, expected: expected)
    case "recovery": return try await liveRecovery(executable, arguments, expected: expected)
    case "mixed-lifecycle": return try await mixedLifecycle(executable, arguments, expected: expected)
    default: break
    }
    let workers = max(1, setting("WORKERS", 32))
    let epochs = max(1, setting("EPOCHS", 1))
    let duration = max(1, setting("SECONDS", 3))
    let operations = setting("OPERATIONS", 0)
    let connectStart = clock.now
    let client = try await makeClient(executable, arguments, expected: expected)
    try emit(["event": "connected", "revision": client.protocolVersion.rawValue,
              "pid": getpid(), "connection_us": microseconds(connectStart.duration(to: clock.now))])
    if mode == "idle" {
        try await Task.sleep(for: .seconds(duration))
        try await verify(client, token: "after idle")
        await client.close()
        return true
    }
    if mode == "offered" {
        let passed = try await offered(client, concurrency: workers, seconds: duration)
        await client.close()
        return passed
    }
    if mode == "stream" || mode == "stream-slow" {
        let passed = try await stream(client, slow: mode == "stream-slow")
        await client.close()
        return passed
    }
    if mode == "cancel" {
        let passed = try await cancellation(client)
        await client.close()
        return passed
    }
    var clean = true
    for epoch in 0..<epochs {
        let started = clock.now
        let deadline = started + .seconds(duration)
        let counts = await withTaskGroup(of: Counts.self, returning: Counts.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    let mixed = mode == "mixed" || mode == "large"
                    let medium = mixed ? String(repeating: "y", count: 65_536) : ""
                    let large = mixed ? String(repeating: "z", count: 1_048_576) : ""
                    let answer = mixed ? String(repeating: "x", count: 1_048_576) : ""
                    var count = Counts()
                    var sequence = worker
                    while operations > 0 ? sequence < operations : clock.now < deadline {
                        let prefix = "\(epoch)/\(worker)/\(sequence)/é\\n"
                        let shape = sequence % 1024
                        let big = (mode == "mixed" && shape < 2) || mode == "large"
                        let mediumRequest = mode == "mixed" && shape % 128 == 2
                        let largeReply = big && shape % 2 == 0
                        let token = largeReply ? prefix : big ? prefix + large : mediumRequest ? prefix + medium : prefix
                        let begin = clock.now
                        do {
                            try await verify(client, token: token,
                                             response: largeReply ? answer : nil,
                                             responseBytes: largeReply ? answer.utf8.count : nil)
                            count.record(microseconds(begin.duration(to: clock.now)),
                                         bytes: token.utf8.count + (largeReply ? answer.utf8.count : token.utf8.count))
                        } catch {
                            let description = String(String(describing: error).prefix(220))
                            count.errors[description, default: 0] += 1
                            // A failed operation still consumes its assigned sequence.
                            if operations == 0 && count.errors.values.reduce(0, +) >= 4 { break }
                        }
                        sequence += workers
                    }
                    return count
                }
            }
            var total = Counts()
            for await count in group { total.merge(count) }
            return total
        }
        let durationUs = microseconds(started.duration(to: clock.now))
        try emit(["event": "epoch", "epoch": epoch, "duration_us": durationUs,
                  "completed": counts.completed, "errors": counts.errors, "payload_bytes": counts.bytes,
                  "histogram_us": Dictionary(uniqueKeysWithValues: counts.histogram.map { (String($0.key), $0.value) }),
                  "max_us": counts.maximum])
        if !counts.errors.isEmpty || counts.completed == 0 {
            clean = false
            break
        }
    }
    await client.close()
    return clean
}
#endif

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--codec" {
        #if SYSTEM_FOUNDATION_JSON
        print("foundation")
        #else
        print("default")
        #endif
    } else if arguments.first == "client" {
        #if os(macOS)
        guard arguments.count >= 2 else { throw ProbeError.invalidArguments }
        if try await !runClient(arguments[1], Array(arguments.dropFirst(2))) { exit(1) }
        #else
        exit(2)
        #endif
    } else {
        try await runServer()
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data((String(describing: error) + "\n").utf8))
    exit(1)
}
