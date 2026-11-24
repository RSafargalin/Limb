public import LimbCore
import Synchronization

/// The protocol engine for one connection: a stdio process, a socket, or one HTTP exchange.
///
/// A transport feeds it complete frames, in order, from a single reader, and the engine puts
/// complete frames into the sink. Three properties hold by construction rather than by care:
///
/// - **A request is registered before the next frame is read.** `receive` is synchronous and
///   registers the request (and creates its task) before returning, so a cancellation that
///   follows a request on the wire always finds it.
/// - **User code never runs on the reader.** Handlers run in their own tasks, and so does
///   everything whose cost depends on what the user registered: argument validation against a
///   tool's schema, opening `requestState`. Cancellation, discovery and listings are answered
///   directly from `receive` and never wait behind them. The one exception is
///   `ServerConfiguration.diagnostics`, which must return quickly.
/// - **Every request is answered, or the connection is closed as overflowed.** An answer is
///   never dropped while the connection lives. Handlers' results go out as ordinary output.
///   The reader's answers are sent by one rule (`sendFromReader`): a frame small next to the
///   urgent reserve draws on it; a larger one goes out as ordinary output, or, while the peer
///   is behind, is replaced by a small overload error. Ids are bounded (`maxRequestIDBytes`),
///   so every error is small, and a small frame that finds both the reserve and the budget
///   full means the peer has stopped reading.
/// - **Nothing is sent for a cancelled request.** Every frame that belongs to a request is
///   queued under the same lock that cancellation takes, and queued frames are withdrawn.
public final class Connection: Sendable {
    let server: Server
    let sink: any FrameSink
    private let configuration: ServerConfiguration
    private let authenticatedPrincipal: String?
    private let state = Mutex(State())

    init(server: Server, sink: any FrameSink, authenticatedPrincipal: String?) {
        self.server = server
        self.sink = sink
        configuration = server.configuration
        self.authenticatedPrincipal = authenticatedPrincipal
    }


    static let builtinMethods: Set<String> = [
        "initialize", "ping", "server/discover", "tools/list", "tools/call", "resources/list",
        "resources/templates/list", "resources/read", "resources/subscribe", "resources/unsubscribe",
        "prompts/list", "prompts/get", "completion/complete", "logging/setLevel", "subscriptions/listen",
    ]

    // MARK: State

    private struct LegacySession: Sendable {
        let identity = LegacySessionIdentity()
        var profile: RevisionProfile
        var capabilities: ClientCapabilities
        var clientInfo: Implementation
        var initialized = false
        var logLevel: LoggingLevel?
        var resourceSubscriptions: Set<ExactString> = []
        /// The capabilities the `initialize` result announced. They hold for the whole session:
        /// a client that negotiated tools may ask for the list after the last tool is gone.
        let negotiated: Set<ServerCapability>
    }

    private enum Responder {
        case direct
        /// The response becomes one element of a JSON-RPC batch reply.
        case batch(BatchCollector, Int)
    }

    private struct Reply: Sendable {
        let frame: [UInt8]
        /// Installed only when this initialize result, rather than a replacement error, is queued.
        var session: LegacySession? = nil
    }

    private struct Inflight {
        /// Distinguishes this request from an earlier one that used the same id.
        let serial: UInt64
        var task: Task<Void, Never>?
        let responder: Responder
        var lastProgress: Double?
        var isSubscription = false
    }

    /// A request this side sent to the client and the call it was sent for.
    private struct ClientRequest {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let callerSerial: UInt64
    }

    private struct Subscription {
        var tools = false
        var prompts = false
        var resources = false
        var uris: Set<ExactString> = []
    }

    private struct State {
        var legacy: LegacySession?
        var inflight: [RequestID: Inflight] = [:]
        var nextSerial: UInt64 = 1
        /// Requests of this connection that were admitted and whose handler has not ended:
        /// running, or waiting for a slot at the server's gate.
        var pending = 0
        /// Requests holding one of this connection's places: running, or done with a response
        /// that waits for the peer to read.
        var active = 0
        var subscriptions: [RequestID: Subscription] = [:]
        var clientRequests: [Int: ClientRequest] = [:]
        var nextClientRequest = 1
        var closing = false
        var idleWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
        /// Waits whose timeout fired before the waiter was registered.
        var expiredIdleWaiters: Set<Int> = []
        var nextIdleWaiter = 0
        /// The peer is gone: a grace period, under way or to come, is over.
        var graceEnded = false
        /// The wait of `close` for requests in flight, which `endGracePeriod` cuts short.
        var graceWaiters: Set<Int> = []
        var oversizedFrames = 0
        var overflowed = false
        var reportedDroppedLogs = false
        /// Diagnostics this connection caused, by kind; past `reportLimit` they are only counted.
        var reports: [DiagnosticKind: Int] = [:]
        /// Resource URIs subscribed to, in the session and in all streams, each with the number
        /// of those that hold it: a URI counts once against the budget however many hold it.
        var subscribedResources: [ExactString: Int] = [:]
        /// The bytes of the URIs in `subscribedResources`, each counted once.
        var subscribedResourceBytes = 0
        /// Events that arrived while the peer was not reading. Each is kept once and sent when
        /// there is room again: "the list changed" said once is as good as said a thousand times.
        var deferredEvents: [DeferredEvent?] = []
        var deferredHead = 0
        var deferredIndices: [EventKey: Int] = [:]
        var activeDelivery: EventDelivery?
        var flushTask: Task<Void, Never>?
    }

    // MARK: Receiving

    /// Handles one frame. Call from a single reader, in arrival order; returns before any
    /// handler has run.
    public func receive(_ frame: Span<UInt8>) {
        guard frame.count <= configuration.budgets.maxFrameBytes else {
            _ = receivedOversizedFrame()
            return
        }
        let value: JSONValue
        do {
            value = try JSON.parse(frame, options: configuration.parseOptions)
        } catch {
            sendFromReader(Frame.error(id: nil, .parseError(error.description)))
            return
        }
        if case .array(let items) = value {
            receiveBatch(items)
        } else {
            dispatch(value, responder: .direct, bytes: frame.count)
        }
    }

    public func receive(_ frame: [UInt8]) {
        receive(frame.span)
    }

    /// The transport saw a frame larger than the budget. Returns `false` when the connection
    /// should be dropped: a second oversized frame is not an accident.
    public func receivedOversizedFrame() -> Bool {
        let count = state.withLock { state in
            state.oversizedFrames = min(2, state.oversizedFrames + 1)
            return state.oversizedFrames
        }
        sendFromReader(
            Frame.error(id: nil, .invalidRequest("message exceeds the \(configuration.budgets.maxFrameBytes)-byte frame limit")))
        return count < 2
    }

    /// Whether the outgoing queue overflowed with frames that could not wait. The transport
    /// should stop reading and close.
    public var hasOverflowed: Bool { state.withLock { $0.overflowed } }

    private func receiveBatch(_ items: [JSONValue]) {
        // Batches exist only in 2025-03-26, which makes them mandatory; later revisions removed them.
        guard let legacy = state.withLock({ $0.legacy }), legacy.profile.acceptsBatch else {
            sendFromReader(Frame.error(id: nil, .invalidRequest("JSON-RPC batches are not supported by this protocol revision")))
            return
        }
        guard !items.isEmpty else {
            sendFromReader(Frame.error(id: nil, .invalidRequest("empty batch")))
            return
        }
        guard items.count <= configuration.budgets.maxBatchItems else {
            sendFromReader(
                Frame.error(id: nil, .invalidRequest("batch has more than \(configuration.budgets.maxBatchItems) items")))
            return
        }
        // Requests and malformed items produce a response; notifications and responses do not.
        var expecting: [Bool] = []
        for item in items {
            do {
                switch try IncomingMessage.classify(item) {
                case .notification, .response: expecting.append(false)
                case .request: expecting.append(true)
                }
            } catch {
                // A malformed notification is still a notification: nothing is sent for it.
                expecting.append(!error.isNotification)
            }
        }
        guard expecting.contains(true) else {
            // Nothing in the batch calls for an answer, so there is no reply at all.
            for item in items { dispatch(item, responder: .direct, bytes: 0) }
            return
        }
        let collector = BatchCollector(slots: expecting.count { $0 }, budget: server.batchReplyBudget)
        var slot = 0
        for (index, item) in items.enumerated() {
            if expecting[index] {
                // The scheduler retains this member independently of its siblings.
                var writer = JSONWriter()
                writer.write(item)
                dispatch(item, responder: .batch(collector, slot), bytes: writer.bytes.count)
                slot += 1
            } else {
                dispatch(item, responder: .direct, bytes: 0)
            }
        }
    }

    private func dispatch(_ value: JSONValue, responder: Responder, bytes: Int) {
        let message: IncomingMessage
        do {
            message = try IncomingMessage.classify(value)
        } catch {
            if error.isNotification {
                report(.malformedNotification, "ignored a malformed notification: \(error.error.message)")
            } else if error.isReply {
                // A reply is never answered, however broken: its id is one of this side's, or
                // nobody's. If it names a pending request, that request has failed.
                if let id = error.id { _ = failClientRequest(id, .internalError("the peer sent a malformed response")) }
                report(.malformedReply, "ignored a malformed reply: \(error.error.message)")
                respondWithNothing(responder)
            } else if error.isAmbiguous, let id = error.id,
                failClientRequest(id, .internalError("the peer sent a malformed response"))
            {
                // The id names a request this side sent, so the message is a reply to it, however
                // broken. Answering it would put a stray response under one of the peer's own ids.
                report(.malformedReply, "ignored a malformed reply to request \(peerText(id.description)): \(error.error.message)")
                respondWithNothing(responder)
            } else {
                // A message with an id and nothing else could be a broken request or a broken
                // reply. Its id may be one of the peer's own in-flight ids, so the error does
                // not claim it.
                let id = error.isAmbiguous ? nil : withinIDLimit(error.id)
                respond(Frame.error(id: id, error.error), id: id, responder)
            }
            return
        }
        switch message {
        case .request(let id, _, _) where withinIDLimit(id) == nil:
            // Every answer echoes the id; bounding it keeps every error the reader builds small.
            let limit = configuration.budgets.maxRequestIDBytes
            respond(Frame.error(id: nil, .invalidRequest("the request id exceeds the \(limit)-byte limit after JSON encoding")), id: nil, responder)
        case .request(let id, let method, let params):
            handleRequest(id: id, method: method, params: params, responder: responder, bytes: bytes)
        case .notification(let method, let params):
            handleNotification(method: method, params: params)
        case .response(let id, let outcome):
            handleClientResponse(id: id, outcome: outcome)
        }
    }

    // MARK: Era and version

    /// Decides how to serve a request from how it presents itself: per-request metadata means
    /// modern; otherwise the connection's `initialize` session, if there is one.
    private func resolvePeer(method: String, meta: JSONObject) throws(MCPError) -> Peer {
        if method == "server/discover", !configuration.legacyVersions.isEmpty,
            !configuration.supportedVersions.contains(where: { RevisionProfile.profile(for: $0)?.hasDiscover == true })
        {
            // A dual-era stdio client falls back to initialize on an unrecognized discovery method.
            throw .methodNotFound(method)
        }
        if let versionValue = meta[MetaKey.protocolVersion] {
            guard let requested = versionValue.stringValue else {
                throw .invalidParams("_meta[\"\(MetaKey.protocolVersion)\"] must be a string")
            }
            let version = ProtocolVersion(rawValue: requested)
            guard configuration.supportedVersions.contains(version),
                let profile = RevisionProfile.profile(for: version), profile.era == .modern
            else {
                throw .unsupportedProtocolVersion(requested: requested, supported: configuration.supportedVersions)
            }
            guard case .object(let capabilities) = meta[MetaKey.clientCapabilities] else {
                throw .invalidParams("missing required _meta field \"\(MetaKey.clientCapabilities)\"")
            }
            var logLevel: LoggingLevel?
            if let levelValue = meta[MetaKey.logLevel] {
                guard let name = levelValue.stringValue, let level = LoggingLevel(rawValue: name) else {
                    throw .invalidParams("_meta[\"\(MetaKey.logLevel)\"] is not a recognized log level")
                }
                logLevel = level
            }
            return Peer(
                profile: profile, capabilities: ClientCapabilities(raw: capabilities),
                clientInfo: meta[MetaKey.clientInfo].map { Implementation(lenient: $0) }, logLevel: logLevel)
        }
        if let legacy = state.withLock({ $0.legacy }) {
            return Peer(
                profile: legacy.profile, capabilities: legacy.capabilities, clientInfo: legacy.clientInfo,
                logLevel: nil, negotiatedServerCapabilities: legacy.negotiated, legacySession: legacy.identity)
        }
        if method == "ping", let version = configuration.legacyVersions.max(),
            let profile = RevisionProfile.profile(for: version)
        {
            // Legacy revisions allow a ping before initialization.
            return Peer(profile: profile, capabilities: ClientCapabilities(), clientInfo: nil, logLevel: nil)
        }
        let versions = configuration.supportedVersions.map(\.rawValue)
        throw .invalidParams(
            "the request does not state a protocol version. Send \"\(MetaKey.protocolVersion)\" and "
                + "\"\(MetaKey.clientCapabilities)\" in params._meta, or begin with \"initialize\". "
                + "Supported versions: \(versions.joined(separator: ", "))",
            data: ["supported": .array(versions.map(JSONValue.string))])
    }

    private func initialize(id: RequestID, params: JSONObject, responder: Responder) {
        let offered = configuration.legacyVersions
        guard let newest = offered.max() else {
            let versions = configuration.supportedVersions.map(\.rawValue)
            let error = MCPError.invalidRequest(
                "this server does not support the initialize handshake; supported protocol versions: "
                    + versions.joined(separator: ", "))
            respond(Frame.error(id: id, error), id: id, responder)
            return
        }
        guard let requested = params["protocolVersion"]?.stringValue else {
            respond(Frame.error(id: id, .invalidParams("protocolVersion: missing required field")), id: id, responder)
            return
        }
        // Legacy negotiation: echo the client's version if we speak it, otherwise offer our newest.
        let asked = ProtocolVersion(rawValue: requested)
        let version = offered.contains(asked) ? asked : newest
        let profile = RevisionProfile.profile(for: version)!
        let negotiated = server.snapshot.legacyCapabilities
        let session = LegacySession(
            profile: profile,
            capabilities: ClientCapabilities(raw: params["capabilities"]?.objectValue ?? JSONObject()),
            clientInfo: Implementation(lenient: params["clientInfo"]), negotiated: negotiated)
        let frame = Frame.result(id: id) { writer in
            writer.beginObject()
            writer.field("protocolVersion", version.rawValue)
            writer.key("capabilities")
            writeCapabilities(to: &writer, capabilities: negotiated)
            writer.field("serverInfo", configuration.info, profile)
            writer.field("instructions", configuration.instructions)
            writer.endObject()
        }
        // An initialize answered with an error leaves the connection as it was: the session is
        // stored only once it is certain that the result itself goes out.
        let limit = configuration.budgets.maxResponseBytes
        if frame.count > limit {
            report(
                .invalidResult,
                "the initialize result (\(frame.count) bytes, of which instructions \(configuration.instructions?.utf8.count ?? 0)) "
                    + "exceeds maxResponseBytes (\(limit)); every initialize fails")
            respond(Frame.error(id: id, .responseTooLarge(bytes: frame.count, limit: limit)), id: id, responder)
            return
        }
        respond(frame, id: id, responder, session: session)
    }

    private func installLegacySessionLocked(_ session: LegacySession, _ state: inout State) {
        guard !state.closing else { return }
        // A successful repeated initialize renegotiates and releases the old subscriptions.
        releaseResourcesLocked(state.legacy?.resourceSubscriptions ?? [], &state)
        state.legacy = session
        dropUnwantedEventsLocked(&state)
    }

    private func writeCapabilities(to writer: inout JSONWriter, capabilities: Set<ServerCapability>) {
        writer.beginObject()
        if capabilities.contains(.tools) {
            writer.key("tools")
            writer.beginObject()
            writer.field("listChanged", true)
            writer.endObject()
        }
        if capabilities.contains(.resources) {
            writer.key("resources")
            writer.beginObject()
            writer.field("subscribe", true)
            writer.field("listChanged", true)
            writer.endObject()
        }
        if capabilities.contains(.prompts) {
            writer.key("prompts")
            writer.beginObject()
            writer.field("listChanged", true)
            writer.endObject()
        }
        writer.key("logging")
        writer.beginObject()
        writer.endObject()
        if capabilities.contains(.completions) {
            writer.key("completions")
            writer.beginObject()
            writer.endObject()
        }
        writer.endObject()
    }

    // MARK: Requests

    private func handleRequest(id: RequestID, method: String, params: JSONObject, responder: Responder, bytes: Int) {
        if state.withLock({ $0.closing }) {
            respondWithNothing(responder)
            return
        }
        if method == "initialize" {
            if case .batch = responder {
                respond(Frame.error(id: id, .invalidRequest("initialize must be sent on its own")), id: id, responder)
                return
            }
            initialize(id: id, params: params, responder: responder)
            return
        }
        let meta = params["_meta"]?.objectValue ?? JSONObject()
        let peer: Peer
        do {
            peer = try resolvePeer(method: method, meta: meta)
        } catch {
            respond(Frame.error(id: id, error), id: id, responder)
            return
        }
        let profile = peer.profile
        do {
            if case .batch = responder, !profile.acceptsBatch {
                // The batch itself belongs to the 2025-03-26 session on this connection; a member
                // that states another revision in its metadata asks for something that revision
                // does not have.
                throw MCPError.invalidRequest(
                    "JSON-RPC batches are not part of protocol revision \(profile.version.rawValue)")
            }
            try requireCapability(for: method, peer: peer)
            switch method {
            case "ping":
                guard profile.hasPing else { throw MCPError.methodNotFound(method) }
                respond(resultFrame(id: id, peer: peer) { _ in }, id: id, responder)
            case "server/discover":
                guard profile.hasDiscover else { throw MCPError.methodNotFound(method) }
                discover(id: id, peer: peer, responder: responder)
            case "tools/list":
                try list(.tools, id: id, params: params, peer: peer, responder: responder)
            case "resources/list":
                try list(.resources, id: id, params: params, peer: peer, responder: responder)
            case "resources/templates/list":
                try list(.templates, id: id, params: params, peer: peer, responder: responder)
            case "prompts/list":
                try list(.prompts, id: id, params: params, peer: peer, responder: responder)
            case "tools/call":
                try callTool(id: id, params: params, meta: meta, peer: peer, responder: responder, bytes: bytes)
            case "resources/read":
                try readResource(id: id, params: params, meta: meta, peer: peer, responder: responder, bytes: bytes)
            case "prompts/get":
                try getPrompt(id: id, params: params, meta: meta, peer: peer, responder: responder, bytes: bytes)
            case "completion/complete":
                try complete(id: id, params: params, meta: meta, peer: peer, responder: responder, bytes: bytes)
            case "logging/setLevel":
                guard profile.hasLoggingSetLevel else { throw MCPError.methodNotFound(method) }
                guard let name = params["level"]?.stringValue, let level = LoggingLevel(rawValue: name) else {
                    throw MCPError.invalidParams("level: not a recognized log level")
                }
                state.withLock { $0.legacy?.logLevel = level }
                respond(resultFrame(id: id, peer: peer) { _ in }, id: id, responder)
            case "resources/subscribe", "resources/unsubscribe":
                guard profile.legacySubscriptions else { throw MCPError.methodNotFound(method) }
                let uri: String
                do { uri = try params.required("uri") } catch { throw MCPError.invalidParams(error) }
                let budgets = configuration.budgets
                let refusal: MCPError? = state.withLock { state in
                    guard state.legacy?.negotiated.contains(.resources) == true else { return .methodNotFound(method) }
                    let key = ExactString(uri)
                    if method == "resources/unsubscribe" {
                        if state.legacy?.resourceSubscriptions.remove(key) != nil {
                            releaseResourcesLocked([key], &state)
                            dropUnwantedEventsLocked(&state)
                        }
                        return nil
                    }
                    if state.legacy?.resourceSubscriptions.contains(key) == true { return nil }
                    guard resourcesFitLocked([key], state, budgets) else {
                        return .overloaded("too many resource subscriptions on this connection")
                    }
                    state.legacy?.resourceSubscriptions.insert(key)
                    retainResourcesLocked([key], &state)
                    return nil
                }
                if let refusal { throw refusal }
                respond(resultFrame(id: id, peer: peer) { _ in }, id: id, responder)
            case "subscriptions/listen":
                guard profile.hasSubscriptionsListen else { throw MCPError.methodNotFound(method) }
                try listen(id: id, params: params, responder: responder)
            default:
                guard let handler = server.snapshot.contents.methods[ExactString(method)] else {
                    throw MCPError.methodNotFound(method)
                }
                admit(id: id, method: method, bytes: bytes, responder: responder) { [self] serial in
                    let context = RequestContext(
                        requestID: id, method: method, peer: peer, meta: meta, connection: self, serial: serial,
                        inputState: .unavailable)
                    do {
                        var result = try await handler(params, context)
                        let userMeta = result.removeValue(forKey: "_meta")?.objectValue
                        if peer.profile.resultTypeRequired, let type = result.removeValue(forKey: "resultType"),
                            type != .string("complete")
                        {
                            report(.handlerFailed, "\(peerText(method)) #\(peerText(id.description)) returned an unsupported resultType")
                            return Frame.error(id: id, .internalError())
                        }
                        return resultFrame(id: id, peer: peer, userMeta: userMeta) { writer in
                            for (key, value) in result {
                                writer.key(key)
                                writer.write(value)
                            }
                        }
                    } catch {
                        return failureFrame(id: id, error, peer: peer, context: context, isTool: false)
                    }
                }
            }
        } catch {
            respond(Frame.error(id: id, error as? MCPError ?? .internalError()), id: id, responder)
        }
    }

    private func discover(id: RequestID, peer: Peer, responder: Responder) {
        let capabilities = server.snapshot.modernCapabilities
        let frame = resultFrame(id: id, peer: peer, cache: configuration.listCache) { writer in
            writer.field("supportedVersions", configuration.supportedVersions.map(\.rawValue))
            writer.key("capabilities")
            writeCapabilities(to: &writer, capabilities: capabilities)
            writer.field("instructions", configuration.instructions)
        }
        respond(frame, id: id, responder)
    }

    private func list(_ kind: ListKind, id: RequestID, params: JSONObject, peer: Peer, responder: Responder) throws {
        let registry = server.snapshot
        let total = registry.count(of: kind)
        var offset = 0
        if let cursor = params["cursor"], !cursor.isNull {
            guard let pageSize = configuration.pageSize, let text = cursor.stringValue,
                let value = Self.offset(fromCursor: text, for: kind),
                value < total, value % max(1, pageSize) == 0
            else { throw MCPError.invalidParams("cursor: not a cursor this server issued") }
            offset = value
        }
        guard let pageSize = configuration.pageSize else {
            // The common case: the whole list, encoded once per revision and reused.
            let encoded = registry.encodedList(kind, profile: peer.profile) {
                encodeList(kind, registry: registry, range: 0..<total, nextCursor: nil, profile: peer.profile)
            }
            respond(Frame.result(id: id, encodedResult: encoded), id: id, responder)
            return
        }
        let end = min(offset + max(1, pageSize), total)
        let encoded = encodeList(
            kind, registry: registry, range: offset..<end,
            nextCursor: end < total ? Self.cursor(for: kind, offset: end) : nil,
            profile: peer.profile)
        respond(Frame.result(id: id, encodedResult: encoded), id: id, responder)
    }

    /// A cursor names the list it belongs to and the position of the next page, in exactly one
    /// spelling. Only strings this server could have issued for this list are accepted back.
    private static func cursor(for kind: ListKind, offset: Int) -> String {
        cursorPrefix(kind) + String(offset)
    }

    private static func offset(fromCursor text: String, for kind: ListKind) -> Int? {
        let prefix = cursorPrefix(kind)
        guard text.utf8.starts(with: prefix.utf8) else { return nil }
        let digits = text.utf8.dropFirst(prefix.utf8.count)
        // Canonical decimal only: no sign, no leading zero, and never the first page.
        guard let first = digits.first, first >= 0x31, first <= 0x39,
            digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private static func cursorPrefix(_ kind: ListKind) -> String {
        switch kind {
        case .tools: "t"
        case .resources: "r"
        case .templates: "m"
        case .prompts: "p"
        }
    }

    /// Methods of a capability the server does not advertise do not exist for the client: the
    /// specification answers them with "method not found", the same as an unknown method.
    ///
    /// Legacy sessions use the set announced at initialize. Modern clients can refresh any
    /// list the server has offered, including one that has since become empty.
    private func requireCapability(for method: String, peer: Peer) throws(MCPError) {
        let capability: ServerCapability
        switch method {
        case "tools/list", "tools/call": capability = .tools
        case "resources/list", "resources/templates/list", "resources/read", "resources/subscribe",
            "resources/unsubscribe":
            capability = .resources
        case "prompts/list", "prompts/get": capability = .prompts
        case "completion/complete": capability = .completions
        default: return
        }
        let advertised = peer.profile.era == .legacy ? peer.negotiatedServerCapabilities : server.snapshot.modernCapabilities
        guard advertised.contains(capability) else { throw .methodNotFound(method) }
    }

    private func encodeList(
        _ kind: ListKind, registry: RegistrySnapshot, range: Range<Int>, nextCursor: String?,
        profile: RevisionProfile
    ) -> [UInt8] {
        let contents = registry.contents
        var writer = JSONWriter(capacity: 1024)
        writer.beginObject()
        switch kind {
        case .tools: writer.field("tools", contents.tools[range].map(\.definition), profile)
        case .resources: writer.field("resources", contents.resources[range].map(\.definition), profile)
        case .templates: writer.field("resourceTemplates", contents.templates[range].map(\.definition), profile)
        case .prompts: writer.field("prompts", contents.prompts[range].map(\.definition), profile)
        }
        writer.field("nextCursor", nextCursor)
        finishResult(&writer, profile: profile, cache: configuration.listCache, userMeta: nil, resultType: "complete")
        writer.endObject()
        return writer.bytes
    }

    private func callTool(
        id: RequestID, params: JSONObject, meta: JSONObject, peer: Peer, responder: Responder, bytes: Int
    ) throws {
        let name: String
        do { name = try params.required("name") } catch { throw MCPError.invalidParams(error) }
        // An unknown tool is a protocol error, not a tool execution error.
        guard let tool = server.snapshot.tool(named: name) else {
            throw MCPError.invalidParams("unknown tool \"\(name)\"")
        }
        let arguments: JSONObject
        switch params["arguments"] {
        case .none, .some(.null): arguments = JSONObject()
        case .some(.object(let object)): arguments = object
        case .some(let other): throw MCPError.invalidParams("arguments: expected object, got \(other.typeName)")
        }
        admit(id: id, method: "tools/call", detail: name, bytes: bytes, responder: responder) { [self] serial in
            // Validation runs here, in the request's own task, not on the reader: its cost
            // depends on the tool's schema (a `pattern` can backtrack) and on the arguments, and
            // the reader must never wait behind either. It holds a slot like the handler does,
            // for a bounded time: the validator gives up past its own per-call budgets.
            if let violation = tool.input.validate(.object(arguments)) {
                let message = "Invalid arguments for tool \"\(name)\": \(violation)"
                guard peer.profile.argumentErrorsAreToolErrors else { return Frame.error(id: id, .invalidParams(message)) }
                // From 2025-11-25 input validation failures are execution errors, so the model can
                // read the reason and correct its call.
                let result = ToolResult.error(message)
                return resultFrame(id: id, peer: peer) { result.encodeMembers(to: &$0, profile: peer.profile) }
            }
            let input: InputState
            do throws(MCPError) {
                input = try makeInputState(method: "tools/call", target: name, arguments: .object(arguments), params: params, peer: peer)
            } catch {
                return Frame.error(id: id, error)
            }
            let context = RequestContext(
                requestID: id, method: "tools/call", peer: peer, meta: meta, connection: self, serial: serial,
                inputState: input)
            let outcome: Result<ToolResult, any Error>
            do {
                outcome = .success(try await tool.handler(arguments, context))
            } catch {
                outcome = .failure(error)
            }
            if let frame = inputRequiredFrame(
                id: id, peer: peer, context: context, target: "tool \"\(name)\"", endedBy: outcome.thrownError, isTool: true)
            { return frame }
            switch outcome {
            case .failure(let error):
                return failureFrame(id: id, error, peer: peer, context: context, isTool: true)
            case .success(let result):
                if let output = tool.output, !result.isError {
                    // The specification requires structured results to conform to the declared schema.
                    guard let structured = result.structuredContent else {
                        report(.invalidResult, "tool \"\(name)\" declares an output schema but returned no structured content")
                        return Frame.error(id: id, .internalError("Tool returned no structured content"))
                    }
                    if let violation = output.validate(structured) {
                        report(.invalidResult, "tool \"\(name)\" returned structured content that violates its output schema: \(violation)")
                        return Frame.error(id: id, .internalError("Tool returned structured content that does not match its output schema"))
                    }
                }
                return resultFrame(id: id, peer: peer, userMeta: result.meta, capacity: 512) { writer in
                    result.encodeMembers(to: &writer, profile: peer.profile)
                }
            }
        }
    }

    private func readResource(
        id: RequestID, params: JSONObject, meta: JSONObject, peer: Peer, responder: Responder, bytes: Int
    ) throws {
        let uri: String
        do { uri = try params.required("uri") } catch { throw MCPError.invalidParams(error) }
        let registry = server.snapshot
        let isContinuation = peer.profile.multiRoundTrip && (params.contains("requestState") || params.contains("inputResponses"))
        admit(id: id, method: "resources/read", detail: uri, bytes: bytes, responder: responder) { [self] serial in
            let read: ResourceReader
            let variables: [String: String]
            let cache: CachePolicy?
            if let resource = registry.resource(uri: uri) {
                read = resource.read
                cache = resource.cache
                variables = [:]
            } else {
                do throws(MCPError) {
                    guard let (template, matches) = try matchTemplate(uri, in: registry.contents.templates) else {
                        return Frame.error(id: id, MCPError(
                            code: peer.profile.resourceNotFoundCode, message: "Resource not found", data: ["uri": .string(uri)]))
                    }
                    read = template.read
                    cache = template.cache
                    variables = matches
                } catch {
                    return Frame.error(id: id, error)
                }
            }
            let request = ResourceRequest(uri: uri, variables: variables)
            let policy = isContinuation ? CachePolicy(ttlMilliseconds: 0, scope: .private) : cache ?? configuration.resourceCache
            let input: InputState
            do throws(MCPError) {
                input = try makeInputState(method: "resources/read", target: uri, arguments: .null, params: params, peer: peer)
            } catch {
                return Frame.error(id: id, error)
            }
            let context = RequestContext(
                requestID: id, method: "resources/read", peer: peer, meta: meta, connection: self, serial: serial,
                inputState: input)
            let outcome: Result<[ResourceContents], any Error>
            do {
                outcome = .success(try await read(request, context))
            } catch {
                outcome = .failure(error)
            }
            if let frame = inputRequiredFrame(
                id: id, peer: peer, context: context, target: "resource \"\(peerText(uri))\"", endedBy: outcome.thrownError, isTool: false)
            { return frame }
            switch outcome {
            case .failure(let error):
                return failureFrame(id: id, error, peer: peer, context: context, isTool: false)
            case .success(let contents):
                return resultFrame(id: id, peer: peer, cache: policy, capacity: 512) { writer in
                    writer.field("contents", contents, peer.profile)
                }
            }
        }
    }

    private func matchTemplate(
        _ uri: String, in templates: [TemplateEntry], preferExactName: Bool = false
    ) throws(MCPError) -> (TemplateEntry, [String: String])? {
        guard uri.utf8.count <= URITemplate.maxURIBytes else { return nil }
        var budget = URITemplate.matchingWorkLimit
        if preferExactName {
            let uriCount = uri.utf8.count
            for template in templates {
                let name = template.definition.uriTemplate
                budget -= 1 + min(uriCount, name.utf8.count)
                guard budget >= 0 else { throw MCPError.overloaded("resource template matching work limit exceeded") }
                if name.isBytewiseEqual(to: uri) { return (template, [:]) }
            }
        }
        let bytes = Array(uri.utf8)
        for template in templates {
            if let variables = try template.template.match(bytes, budget: &budget) { return (template, variables) }
        }
        return nil
    }

    private func getPrompt(
        id: RequestID, params: JSONObject, meta: JSONObject, peer: Peer, responder: Responder, bytes: Int
    ) throws {
        let name: String
        do { name = try params.required("name") } catch { throw MCPError.invalidParams(error) }
        guard let prompt = server.snapshot.prompt(named: name) else {
            throw MCPError.invalidParams("unknown prompt \"\(name)\"")
        }
        var arguments: [String: String] = [:]
        switch params["arguments"] {
        case .none, .some(.null):
            break
        case .some(.object(let object)):
            for (key, value) in object {
                guard value.stringValue != nil else {
                    throw MCPError.invalidParams("arguments.\(key): expected string, got \(value.typeName)")
                }
            }
            // Declared arguments are looked up by their exact name (`JSONObject` compares
            // bytes). The handler's dictionary compares by canonical equivalence, so a member
            // that merely looks like a declared name must not land on it.
            let declared = prompt.definition.arguments.map(\.name)
            for name in declared {
                if let text = object[name]?.stringValue { arguments[name] = text }
            }
            for (key, value) in object where arguments[key] == nil {
                // Equal to a declared name for `String` but not the same bytes: a look-alike.
                // It is not that argument, and it cannot be told apart from it in the dictionary.
                if declared.contains(where: { $0 == key && !$0.isBytewiseEqual(to: key) }) { continue }
                arguments[key] = value.stringValue
            }
        case .some(let other):
            throw MCPError.invalidParams("arguments: expected object, got \(other.typeName)")
        }
        let provided = params["arguments"]?.objectValue ?? JSONObject()
        for argument in prompt.definition.arguments where argument.required && provided[argument.name] == nil {
            throw MCPError.invalidParams("arguments.\(argument.name): missing required argument")
        }
        let resolved = arguments
        admit(id: id, method: "prompts/get", detail: name, bytes: bytes, responder: responder) { [self] serial in
            let input: InputState
            do throws(MCPError) {
                input = try makeInputState(
                    method: "prompts/get", target: name, arguments: params["arguments"] ?? .null, params: params, peer: peer)
            } catch {
                return Frame.error(id: id, error)
            }
            let context = RequestContext(
                requestID: id, method: "prompts/get", peer: peer, meta: meta, connection: self, serial: serial,
                inputState: input)
            let outcome: Result<PromptResult, any Error>
            do {
                outcome = .success(try await prompt.handler(resolved, context))
            } catch {
                outcome = .failure(error)
            }
            if let frame = inputRequiredFrame(
                id: id, peer: peer, context: context, target: "prompt \"\(name)\"", endedBy: outcome.thrownError, isTool: false)
            { return frame }
            switch outcome {
            case .failure(let error):
                return failureFrame(id: id, error, peer: peer, context: context, isTool: false)
            case .success(let result):
                return resultFrame(id: id, peer: peer, capacity: 512) { writer in
                    writer.field("description", result.description)
                    writer.field("messages", result.messages, peer.profile)
                }
            }
        }
    }

    private func complete(
        id: RequestID, params: JSONObject, meta: JSONObject, peer: Peer, responder: Responder, bytes: Int
    ) throws {
        guard let reference = params["ref"]?.objectValue, let kind = reference["type"]?.stringValue else {
            throw MCPError.invalidParams("ref: missing required field")
        }
        guard let argument = params["argument"]?.objectValue, let argumentName = argument["name"]?.stringValue,
            let value = argument["value"]?.stringValue
        else { throw MCPError.invalidParams("argument: expected an object with string \"name\" and \"value\"") }
        let registry = server.snapshot
        let target: String
        switch kind {
        case "ref/prompt":
            guard let name = reference["name"]?.stringValue, let prompt = registry.prompt(named: name) else {
                throw MCPError.invalidParams("ref: unknown prompt")
            }
            if prompt.complete == nil {
                // There is no user code to schedule for this answer.
                respond(completionFrame(id: id, peer: peer, CompletionResult(hasMore: false)), id: id, responder)
                return
            }
            target = name
        case "ref/resource":
            guard let uri = reference["uri"]?.stringValue else { throw MCPError.invalidParams("ref.uri: missing required field") }
            target = uri
        default:
            throw MCPError.invalidParams("ref.type: expected \"ref/prompt\" or \"ref/resource\"")
        }
        var resolved: [String: String] = [:]
        if case .object(let object) = params["context"]?["arguments"] {
            for (key, value) in object { resolved[key] = value.stringValue }
        }
        let request = CompletionRequest(argumentName: argumentName, value: value, resolvedArguments: resolved)
        admit(id: id, method: "completion/complete", detail: argumentName, bytes: bytes, responder: responder) { [self] serial in
            let handler: CompletionHandler?
            if kind == "ref/prompt" {
                handler = registry.prompt(named: target)?.complete
            } else {
                do throws(MCPError) {
                    guard let (template, _) = try matchTemplate(target, in: registry.contents.templates, preferExactName: true) else {
                        return Frame.error(id: id, .invalidParams("ref: unknown resource template"))
                    }
                    handler = template.complete
                } catch {
                    return Frame.error(id: id, error)
                }
            }
            let context = RequestContext(
                requestID: id, method: "completion/complete", peer: peer, meta: meta, connection: self,
                serial: serial, inputState: .unavailable)
            do {
                let result = try await handler?(request, context) ?? CompletionResult(hasMore: false)
                return completionFrame(id: id, peer: peer, result)
            } catch {
                return failureFrame(id: id, error, peer: peer, context: context, isTool: false)
            }
        }
    }

    private func completionFrame(id: RequestID, peer: Peer, _ result: CompletionResult) -> [UInt8] {
        resultFrame(id: id, peer: peer) { writer in
            writer.key("completion")
            writer.beginObject()
            // The specification caps a completion at 100 values.
            writer.field("values", Array(result.values.prefix(100)))
            writer.field("total", result.total)
            writer.field("hasMore", result.values.count > 100 ? true : result.hasMore)
            writer.endObject()
        }
    }

    // MARK: Results

    private func resultFrame(
        id: RequestID, peer: Peer, cache: CachePolicy? = nil, userMeta: JSONObject? = nil,
        resultType: String = "complete", capacity: Int = 256, _ members: (inout JSONWriter) -> Void
    ) -> [UInt8] {
        Frame.result(id: id, capacity: capacity) { writer in
            writer.beginObject()
            members(&writer)
            finishResult(&writer, profile: peer.profile, cache: cache, userMeta: userMeta, resultType: resultType)
            writer.endObject()
        }
    }

    /// Adds what the revision requires on every result: `resultType`, cache hints, `serverInfo`.
    private func finishResult(
        _ writer: inout JSONWriter, profile: RevisionProfile, cache: CachePolicy?, userMeta: JSONObject?,
        resultType: String
    ) {
        if profile.resultTypeRequired { writer.field("resultType", resultType) }
        if profile.cacheHints, let cache {
            writer.field("ttlMs", cache.ttlMilliseconds)
            writer.field("cacheScope", cache.scope.rawValue)
        }
        let hasUserMeta = userMeta.map { !$0.isEmpty } ?? false
        guard profile.serverInfoInResults || hasUserMeta else { return }
        writer.key("_meta")
        writer.beginObject()
        if let userMeta {
            for (key, value) in userMeta where key != MetaKey.serverInfo {
                writer.key(key)
                writer.write(value)
            }
        }
        if profile.serverInfoInResults { writer.writeRawMembers(server.serverInfoMember) }
        writer.endObject()
    }

    /// Maps a handler's error to a response. `nil` means "send nothing".
    private func failureFrame(id: RequestID, _ error: any Error, peer: Peer, context: RequestContext, isTool: Bool) -> [UInt8]? {
        switch error {
        case let error as MCPError where error.code == MCPError.Code.legacyURLElicitationRequired:
            // Only 2025-11-25 has this error, and only a client that does URL elicitation can act on it.
            let reason: String? =
                if !peer.profile.elicitationCompletion { "protocol revision \(peer.profile.version) does not have it" }
                else if !peer.capabilities.supportsURLElicitation { "the client does not support URL elicitation" }
                else if !error.isValidURLElicitationRequired { "it does not list URL-mode elicitations with an elicitationId" }
                else { nil }
            if let reason {
                report(.handlerFailed, "\(peerText(context.method)) #\(peerText(id.description)) threw URLElicitationRequiredError: \(reason)")
                return Frame.error(id: id, .internalError())
            }
            return Frame.error(id: id, error)
        case let error as MCPError:
            if peer.profile.era == .modern,
                error.code == MCPError.Code.legacyResourceNotFound || (-32099 ... -32020).contains(error.code),
                !context.inputState.reportedMissingCapability(error)
            {
                report(.handlerFailed, "\(peerText(context.method)) #\(peerText(id.description)) threw an inapplicable MCP error code \(error.code)")
                return Frame.error(id: id, .internalError())
            }
            return Frame.error(id: id, error)
        case is CancellationError:
            return Task.isCancelled ? nil : Frame.error(id: id, .internalError("Request was cancelled internally"))
        case let error as InvalidToolArguments where isTool:
            let message = "Invalid arguments: \(error.message)"
            guard peer.profile.argumentErrorsAreToolErrors else { return Frame.error(id: id, .invalidParams(message)) }
            let result = ToolResult.error(message)
            return resultFrame(id: id, peer: peer) { result.encodeMembers(to: &$0, profile: peer.profile) }
        case let error as ToolError where isTool:
            let result = ToolResult.error(error.message)
            return resultFrame(id: id, peer: peer, userMeta: error.meta) { result.encodeMembers(to: &$0, profile: peer.profile) }
        case let error as InputUnavailable:
            if isTool {
                let result = ToolResult.error("This tool needs \(error.capability), which the client does not support.")
                return resultFrame(id: id, peer: peer) { result.encodeMembers(to: &$0, profile: peer.profile) }
            }
            return Frame.error(id: id, .invalidRequest("this request needs \(error.capability), which the client does not support"))
        default:
            // Details of an unexpected failure go to the operator, not to the peer.
            report(.handlerFailed, "\(peerText(context.method)) #\(peerText(id.description)) failed: \(error)")
            return Frame.error(id: id, .internalError())
        }
    }

    // MARK: Multi round-trip requests

    /// Runs in the request's task, after admission: opening the state calls the configured
    /// `RequestStateSealer`, and the fingerprint and the answers cost in proportion to the
    /// request.
    private func makeInputState(
        method: String, target: String, arguments: JSONValue, params: JSONObject, peer: Peer
    ) throws(MCPError) -> InputState {
        guard peer.profile.multiRoundTrip else { return InputState(allowed: true) }
        var journal = JSONObject()
        // Checked before anything is merged: only the keys the handler asks for matter, and a
        // handler asks for a handful.
        let limit = configuration.budgets.maxInputResponses
        if case .object(let responses) = params["inputResponses"], responses.count > limit {
            throw MCPError.invalidParams("inputResponses: more than \(limit) entries")
        }
        let version: RequestStatePayload.Version = authenticatedPrincipal == nil ? .exact : .principalBound
        let fingerprint = requestFingerprint(method: method, target: target, arguments: arguments, version: version,
            principal: authenticatedPrincipal)
        if let stateValue = params["requestState"] {
            // The state came back through the client: verify before anything reads it.
            guard let sealed = stateValue.stringValue else { throw MCPError.invalidParams("requestState: expected string") }
            guard let opened = try? server.sealer.open(sealed), let payload = RequestStatePayload(opened) else {
                throw MCPError.invalidParams("requestState: failed verification")
            }
            guard payload.expires > unixTime() else { throw MCPError.invalidParams("requestState: expired") }
            guard (payload.version == .principalBound) == (version == .principalBound) else {
                throw MCPError.invalidParams("requestState: issued for a different request")
            }
            let expected = payload.version == .legacy
                ? requestFingerprint(method: method, target: target, arguments: arguments, version: .legacy)
                : fingerprint
            guard payload.fingerprint == expected else {
                throw MCPError.invalidParams("requestState: issued for a different request")
            }
            journal = payload.journal
        }
        var answers = journal
        switch params["inputResponses"] {
        case .none: break
        case .some(.object(let responses)):
            for (key, answer) in responses where answers[key] == nil { answers[key] = answer }
        case .some(let other): throw MCPError.invalidParams("inputResponses: expected object, got \(other.typeName)")
        }
        return InputState(allowed: true, answers: answers, journal: journal, fingerprint: fingerprint, version: version)
    }

    /// If the run asked for input it did not have, the response is an `InputRequiredResult`,
    /// whatever the handler returned or threw afterwards.
    private func inputRequiredFrame(
        id: RequestID, peer: Peer, context: RequestContext, target: String, endedBy error: (any Error)?, isTool: Bool
    ) -> [UInt8]? {
        guard let outstanding = context.inputState.outstanding() else { return nil }
        if !(error is InputRequiredSignal) {
            // The handler caught the error that ends the run, or ignored it with `try?`, and
            // went on. What it produced after that point is discarded; say so, by name.
            report(
                .handlerFailed,
                "\(target) went on after an input point that had no answer yet; what it returned was discarded. "
                    + "Do not catch the error thrown by input(), elicit(), sample() or roots()")
        }
        // A lifetime too long to add is as good as for ever.
        let (expires, overflow) = unixTime().addingReportingOverflow(configuration.requestStateLifetimeSeconds)
        let payload = RequestStatePayload(
            expires: overflow ? .max : expires,
            fingerprint: context.inputState.fingerprint, journal: outstanding.journal, version: context.inputState.version)
        let plaintext = payload.encoded()
        guard plaintext.count <= configuration.maxRequestStateBytes else {
            // Earlier answers travel in the state; past the limit they are not carried further.
            let message =
                "the input collected so far (\(plaintext.count) bytes) is too large to carry between rounds; "
                + "the limit is \(configuration.maxRequestStateBytes) bytes"
            guard isTool else { return Frame.error(id: id, .invalidRequest(message)) }
            let result = ToolResult.error(message)
            return resultFrame(id: id, peer: peer) { result.encodeMembers(to: &$0, profile: peer.profile) }
        }
        guard let sealed = try? server.sealer.seal(plaintext) else {
            report(.handlerFailed, "could not seal requestState for \(peerText(context.method)) #\(peerText(id.description))")
            return Frame.error(id: id, .internalError())
        }
        return resultFrame(id: id, peer: peer, resultType: "input_required", capacity: 512) { writer in
            writer.key("inputRequests")
            writer.beginObject()
            for (key, request) in outstanding.requests {
                writer.key(key)
                writer.beginObject()
                writer.field("method", request.method)
                writer.key("params")
                request.encodeParams(to: &writer, profile: peer.profile)
                writer.endObject()
            }
            writer.endObject()
            writer.field("requestState", sealed)
        }
    }

    /// Sends a request to a legacy client and suspends until it answers.
    ///
    /// `caller` is the request on whose behalf this is sent. Once that request is cancelled or
    /// answered nothing goes out for it — also not from a task the handler detached and left behind.
    /// A request the client leaves unanswered for `clientRequestTimeoutSeconds` is withdrawn,
    /// as the specification recommends, and the call throws `MCPError.requestTimedOut`.
    func requestClient(
        _ request: InputRequest, profile: RevisionProfile, legacySession: LegacySessionIdentity?,
        caller: (id: RequestID, serial: UInt64)
    ) async throws -> JSONValue {
        let number = state.withLock { state in
            defer { state.nextClientRequest += 1 }
            return state.nextClientRequest
        }
        let id = RequestID(number)
        let frame = Frame.request(id: id, method: request.method) { writer in
            request.encodeParams(to: &writer, profile: profile)
        }
        let seconds = configuration.clientRequestTimeoutSeconds
        let limit = timeLimit(seconds: seconds)
        // A limit of zero (or less, or NaN) disables requests to the client: nothing is sent.
        if limit == .zero { throw MCPError.requestTimedOut(method: request.method, seconds: seconds) }
        // Started once the request is registered, so that it always finds the request there,
        // unless the request is over already.
        let timeout = Mutex<Task<Void, Never>?>(nil)
        defer { timeout.withLock { $0?.cancel() } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                state.withLock { state in
                    // Registered and sent under one lock, so the reply cannot arrive unexpected;
                    // the cancellation check closes the gap with a cancellation that came first.
                    if state.closing || Task.isCancelled || state.inflight[caller.id]?.serial != caller.serial {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard state.legacy?.identity === legacySession, state.legacy?.initialized == true else {
                        continuation.resume(throwing: MCPError.invalidRequest("the legacy client session is not ready"))
                        return
                    }
                    state.clientRequests[number] = ClientRequest(continuation: continuation, callerSerial: caller.serial)
                    guard sink.enqueue(frame) else {
                        state.clientRequests[number] = nil
                        continuation.resume(throwing: MCPError.requestDeliveryFailed(method: request.method))
                        return
                    }
                    guard let limit else { return }
                    timeout.withLock { timer in
                        timer = Task { [self] in
                            guard (try? await Task.sleep(for: limit)) != nil else { return }
                            let pending: ClientRequest? = self.state.withLock { state in
                                guard let pending = state.clientRequests.removeValue(forKey: number) else { return nil }
                                // Queued before the handler learns of it, so the withdrawal
                                // precedes whatever the handler answers.
                                sink.enqueue(Self.cancellationNotice(forClientRequest: number))
                                return pending
                            }
                            pending?.continuation.resume(throwing: MCPError.requestTimedOut(method: request.method, seconds: seconds))
                        }
                    }
                }
            }
        } onCancel: {
            let request: ClientRequest? = state.withLock { state in
                guard let request = state.clientRequests.removeValue(forKey: number) else { return nil }
                sink.enqueue(Self.cancellationNotice(forClientRequest: number))
                return request
            }
            request?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Sends `notifications/elicitation/complete` to the session on this connection, if its
    /// revision has it (`2025-11-25`) and the client does URL elicitation. Returns whether it
    /// was sent. Any id is sent as given: the connection does not know which ids it issued, so
    /// naming one of this session's elicitations is the caller's part.
    @discardableResult
    public func notifyElicitationComplete(_ elicitationID: String) -> Bool {
        let frame = Frame.notification(method: "notifications/elicitation/complete") { writer in
            writer.beginObject()
            writer.field("elicitationId", elicitationID)
            writer.endObject()
        }
        return state.withLock { state in
            guard !state.closing, let legacy = state.legacy, legacy.profile.elicitationCompletion,
                legacy.capabilities.supportsURLElicitation
            else { return false }
            return sink.enqueue(frame)
        }
    }

    private static func cancellationNotice(forClientRequest number: Int) -> [UInt8] {
        Frame.notification(method: "notifications/cancelled") { writer in
            writer.beginObject()
            writer.field("requestId", RequestID(number))
            writer.endObject()
        }
    }

    /// Withdraws the requests to the client that were sent for a call that is now over —
    /// cancelled or answered. Those the handler itself awaited are gone already; this catches
    /// the ones a task it detached is still waiting on. Call with the state locked; resume the
    /// returned continuations after unlocking.
    private func withdrawClientRequestsLocked(
        _ state: inout State, callerSerial: UInt64
    ) -> [CheckedContinuation<JSONValue, any Error>] {
        var withdrawn: [CheckedContinuation<JSONValue, any Error>] = []
        for (number, request) in state.clientRequests where request.callerSerial == callerSerial {
            state.clientRequests[number] = nil
            withdrawn.append(request.continuation)
            sink.enqueue(Self.cancellationNotice(forClientRequest: number))
        }
        return withdrawn
    }

    /// Fails a pending request to the client. Returns `false` if `id` does not name one.
    private func failClientRequest(_ id: RequestID, _ error: MCPError) -> Bool {
        guard case .number(let number) = id, let key = number.intValue else { return false }
        guard let request = state.withLock({ $0.clientRequests.removeValue(forKey: key) }) else { return false }
        request.continuation.resume(throwing: error)
        return true
    }

    private func handleClientResponse(id: RequestID, outcome: Result<JSONValue, MCPError>) {
        guard case .number(let number) = id, let key = number.intValue else { return }
        let request = state.withLock { $0.clientRequests.removeValue(forKey: key) }
        switch outcome {
        case .success(let value): request?.continuation.resume(returning: value)
        case .failure(let error): request?.continuation.resume(throwing: error)
        }
    }

    // MARK: Admission and cancellation

    private enum Admission {
        case accepted
        case duplicate
        case closing
    }

    /// Registers a request and starts or queues its handler. Runs on the reader, so the request
    /// is known to cancellation before the next frame is looked at.
    ///
    /// There are two limits, and a request passes both before its handler runs:
    ///
    /// - **A handler slot of the server.** Held only while the handler runs, and shared by all
    ///   connections; requests wait for one in a single queue, in arrival order.
    /// - **A place on this connection.** A request holds one from the moment its handler starts
    ///   until its response is queued — including while the response waits for the peer to
    ///   read. That is the backpressure: a peer that does not read ends up with all its places
    ///   taken by waiting responses, and its further requests wait in the queue without taking
    ///   handler slots from anyone. Nothing is dropped and memory is bounded.
    private func admit(
        id: RequestID, method: String, detail: String = "", bytes: Int, responder: Responder,
        _ work: @escaping @Sendable (_ serial: UInt64) async -> [UInt8]?
    ) {
        configuration.beforeAdmission?(id)
        let name = detail.isEmpty ? "\(method)#\(id)" : "\(method)#\(id) \(detail)"
        var serial: UInt64 = 0
        let admission: Admission = state.withLock { state in
            if state.closing { return .closing }
            if state.inflight[id] != nil { return .duplicate }
            serial = state.nextSerial
            state.nextSerial += 1
            state.inflight[id] = Inflight(serial: serial, task: nil, responder: responder)
            state.pending += 1
            return .accepted
        }
        switch admission {
        case .closing:
            respondWithNothing(responder)
            return
        case .duplicate:
            respond(Frame.error(id: id, .invalidRequest("request id \(id) is already in use by a request in progress")), id: id, responder)
            return
        case .accepted:
            break
        }
        let admitted = serial
        let entry = Server.GateEntry(
            owner: ObjectIdentifier(self), serial: admitted, bytes: bytes,
            start: { [self] in start(id: id, serial: admitted, name: name, work) },
            peerIsBehind: { [sink] in sink.isOverBudget })
        switch server.acquireSlot(entry) {
        case .started, .gone:
            break
        case .queued:
            // Closing or cancellation may have withdrawn the request before the gate queued it.
            if state.withLock({ $0.inflight[id]?.serial != admitted }) {
                server.withdraw(owner: ObjectIdentifier(self), serials: [admitted])
            }
        case .overloaded:
            let idle: [CheckedContinuation<Void, Never>]? = state.withLock { state in
                // Only if it is still registered: a `close` that ran meanwhile has already
                // dropped it and counted it out.
                guard state.inflight[id]?.serial == admitted else { return nil }
                state.inflight[id] = nil
                state.pending -= 1
                return takeIdleWaitersLocked(&state)
            }
            guard let idle else { return }
            for waiter in idle { waiter.resume() }
            respond(Frame.error(id: id, .overloaded("too many requests in progress; retry later")), id: id, responder)
        }
    }

    /// Starts the handler of an admitted request, if it is still wanted and this connection
    /// has a place for it. Called by the server's gate when it has a slot to give.
    private func start(
        id: RequestID, serial: UInt64, name: String, _ work: @escaping @Sendable (_ serial: UInt64) async -> [UInt8]?
    ) -> Server.StartOutcome {
        let limit = configuration.handlerLimit
        return state.withLock { state in
            guard state.inflight[id]?.serial == serial else { return .gone }
            guard state.active < limit else { return .busy }
            state.active += 1
            state.inflight[id]?.task = Task(name: name) {
                let frame = await work(serial)
                await self.finish(id: id, serial: serial, frame: frame)
            }
            return .started
        }
    }

    private func finish(id: RequestID, serial: UInt64, frame: [UInt8]?) async {
        var frame = frame
        if let built = frame, built.count > configuration.budgets.maxResponseBytes {
            // Never truncate a successful result silently: say that it did not fit.
            frame = Frame.error(id: id, .responseTooLarge(bytes: built.count, limit: configuration.budgets.maxResponseBytes))
        }
        // The handler is done. If its response has to wait for the peer to read, it waits
        // without the handler slot: slots belong to the whole server, and one connection that
        // does not read must not take them from the others. The wait ends early if the request
        // is cancelled meanwhile.
        var releasedSlot = false
        if frame != nil, sink.isOverBudget, state.withLock({ $0.inflight[id]?.serial == serial }) {
            server.releaseSlot()
            releasedSlot = true
            await sink.waitForCapacity()
        }
        var withdrawn: [CheckedContinuation<JSONValue, any Error>] = []
        let idle: [CheckedContinuation<Void, Never>] = state.withLock { state in
            if let entry = state.inflight[id], entry.serial == serial {
                state.inflight[id] = nil
                if let frame {
                    deliverLocked(frame, entry.responder, key: id, &state)
                } else {
                    // Ended by cancellation (by `close`, say): no response, but the batch it
                    // belongs to still has to be completed.
                    settleBatchSlotLocked(entry.responder, &state)
                }
            }
            withdrawn = withdrawClientRequestsLocked(&state, callerSerial: serial)
            state.pending -= 1
            // The response is queued (or will never be): the place on this connection is free.
            state.active -= 1
            return takeIdleWaitersLocked(&state)
        }
        for continuation in withdrawn { continuation.resume(throwing: CancellationError()) }
        for waiter in idle { waiter.resume() }
        // Either way the gate looks at its queue again: with a slot back, or — if the slot was
        // returned before the wait — because this connection can take a request again.
        let owner = ObjectIdentifier(self)
        if releasedSlot { server.placeFreed(owner: owner) } else { server.releaseSlot(owner: owner) }
    }

    private func takeIdleWaitersLocked(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        guard state.pending == 0, !state.idleWaiters.isEmpty else { return [] }
        let waiters = Array(state.idleWaiters.values)
        state.idleWaiters = [:]
        return waiters
    }

    private func cancel(_ id: RequestID) {
        var withdrawn: Set<UInt64> = []
        var idle: [CheckedContinuation<Void, Never>] = []
        var abandoned: [CheckedContinuation<JSONValue, any Error>] = []
        let task: Task<Void, Never>? = state.withLock { state in
            // An unknown id is a late cancellation and is ignored. No tombstone is kept: an id
            // may be reused once its response is sent, and a tombstone would kill the new request.
            guard let entry = state.inflight.removeValue(forKey: id) else { return nil }
            abandoned = withdrawClientRequestsLocked(&state, callerSerial: entry.serial)
            if entry.isSubscription {
                if let subscription = state.subscriptions.removeValue(forKey: id) {
                    releaseResourcesLocked(subscription.uris, &state)
                    dropUnwantedEventsLocked(&state)
                }
            } else if entry.task == nil {
                // Still waiting at the server's gate: it will never start, so it is no longer pending.
                withdrawn.insert(entry.serial)
                state.pending -= 1
                idle = takeIdleWaitersLocked(&state)
            }
            // After cancellation nothing may be sent for the request, including what is already queued.
            sink.discard(key: id)
            settleBatchSlotLocked(entry.responder, &state)
            return entry.task
        }
        server.withdraw(owner: ObjectIdentifier(self), serials: withdrawn)
        for continuation in abandoned { continuation.resume(throwing: CancellationError()) }
        for waiter in idle { waiter.resume() }
        task?.cancel()
    }

    // MARK: Notifications

    private func handleNotification(method: String, params: JSONObject) {
        switch method {
        case "notifications/cancelled":
            guard let id = params["requestId"].flatMap(RequestID.init(json:)) else { return }
            cancel(id)
        case "notifications/initialized":
            state.withLock { $0.legacy?.initialized = true }
        default:
            // Unknown notifications are ignored, as JSON-RPC requires.
            break
        }
    }

    /// Queues a frame that belongs to a running request, unless the request is gone.
    ///
    /// Progress and log messages are worth less than the memory they take: when the peer is not
    /// reading and ordinary output is over its budget, a log message is dropped and progress
    /// only replaces a value that is already queued.
    func emit(_ frame: [UInt8], for id: RequestID, serial: UInt64, progress: Double?) {
        let firstDrop: Bool = state.withLock { state in
            guard var entry = state.inflight[id], entry.serial == serial else { return false }
            if progress == nil, sink.isOverBudget {
                defer { state.reportedDroppedLogs = true }
                return !state.reportedDroppedLogs
            }
            if let progress {
                if let last = entry.lastProgress, progress <= last { return false }
                entry.lastProgress = progress
                state.inflight[id] = entry
            }
            sink.enqueue(frame, key: id, urgent: false, replacesProgress: progress != nil)
            return false
        }
        // Outside the lock: the closure is the operator's, and may block or call back in.
        if firstDrop { configuration.diagnostics("the peer is not reading: log messages from handlers are being dropped") }
    }

    /// Cancels the handler of a request that reached an input point without an answer. The
    /// request stays registered: its response — the `InputRequiredResult` — is still to come.
    func haltHandler(for id: RequestID, serial: UInt64) {
        let task = state.withLock { state in
            state.inflight[id]?.serial == serial ? state.inflight[id]?.task : nil
        }
        task?.cancel()
    }

    func logThreshold(for context: RequestContext) -> LoggingLevel? {
        if context.profile.era == .modern { return context.logLevel }
        // Legacy: the session's level; until the client sets one, informational and above.
        return state.withLock { $0.legacy?.logLevel } ?? .info
    }

    // MARK: Subscriptions

    private func listen(id: RequestID, params: JSONObject, responder: Responder) throws {
        guard case .object(let filter) = params["notifications"] else {
            throw MCPError.invalidParams("notifications: missing required field")
        }
        func flag(_ key: String) throws(MCPError) -> Bool {
            guard let value = filter[key] else { return false }
            guard let boolean = value.boolValue else {
                throw MCPError.invalidParams("notifications.\(key): expected boolean")
            }
            return boolean
        }
        var subscription = Subscription()
        subscription.tools = try flag("toolsListChanged")
        subscription.prompts = try flag("promptsListChanged")
        subscription.resources = try flag("resourcesListChanged")
        var uris: [String] = []
        let budgets = configuration.budgets
        if let value = filter["resourceSubscriptions"] {
            guard case .array(let list) = value else {
                throw MCPError.invalidParams("notifications.resourceSubscriptions: expected array of strings")
            }
            for member in list {
                guard let uri = member.stringValue else {
                    throw MCPError.invalidParams("notifications.resourceSubscriptions: expected array of strings")
                }
                uris.append(uri)
            }
            // The list is echoed in the acknowledgment, so it is bounded as given, repeats included.
            guard uris.count <= budgets.maxSubscribedResources,
                uris.reduce(0, { $0 + $1.utf8.count }) <= budgets.maxSubscribedResourceBytes
            else { throw MCPError.overloaded("too many resource subscriptions on this connection") }
            subscription.uris = Set(uris.map(ExactString.init))
        }
        let accepted = subscription
        // Queue the acknowledgment before registering the subscription under the same lock.
        // That keeps it ahead of any events and leaves no subscription on refusal.
        let refusal: MCPError? = state.withLock { state in
            // A stream opened while the connection closes is simply not served.
            if state.closing { return nil }
            if state.inflight[id] != nil {
                return MCPError.invalidRequest("request id \(id) is already in use by a request in progress")
            }
            guard state.subscriptions.count < budgets.maxSubscriptions else {
                return MCPError.overloaded("too many subscriptions on this connection")
            }
            guard resourcesFitLocked(accepted.uris, state, budgets) else {
                return MCPError.overloaded("too many resource subscriptions on this connection")
            }
            guard !sink.isOverBudget else { return Self.outputBackpressureError }
            let acknowledgment = Frame.notification(method: "notifications/subscriptions/acknowledged") { writer in
                writer.beginObject()
                writer.key("_meta")
                writer.beginObject()
                writer.field(MetaKey.subscriptionID, id)
                writer.endObject()
                writer.key("notifications")
                writer.beginObject()
                if accepted.tools { writer.field("toolsListChanged", true) }
                if accepted.prompts { writer.field("promptsListChanged", true) }
                if accepted.resources { writer.field("resourcesListChanged", true) }
                if filter["resourceSubscriptions"] != nil { writer.field("resourceSubscriptions", uris) }
                writer.endObject()
                writer.endObject()
            }
            guard acknowledgment.count <= budgets.maxResponseBytes else {
                return MCPError.responseTooLarge(bytes: acknowledgment.count, limit: budgets.maxResponseBytes)
            }
            guard sink.enqueue(acknowledgment, key: id) else { return Self.outputBackpressureError }
            retainResourcesLocked(accepted.uris, &state)
            let serial = state.nextSerial
            state.nextSerial += 1
            state.inflight[id] = Inflight(serial: serial, task: nil, responder: responder, isSubscription: true)
            state.subscriptions[id] = accepted
            return nil
        }
        if let refusal { throw refusal }
    }

    /// Whether `uris` fit the subscription budget on top of what the connection holds. A URI
    /// the connection already holds, in its session or another stream, costs nothing more.
    private func resourcesFitLocked(_ uris: some Collection<ExactString>, _ state: State, _ budgets: ServerBudgets) -> Bool {
        var count = state.subscribedResources.count
        var bytes = state.subscribedResourceBytes
        for uri in uris where state.subscribedResources[uri] == nil {
            count += 1
            bytes += uri.text.utf8.count
        }
        return count <= budgets.maxSubscribedResources && bytes <= budgets.maxSubscribedResourceBytes
    }

    /// `uris` hold no repeats: they come from one session's or one stream's set.
    private func retainResourcesLocked(_ uris: some Collection<ExactString>, _ state: inout State) {
        for uri in uris {
            if state.subscribedResources[uri] == nil { state.subscribedResourceBytes += uri.text.utf8.count }
            state.subscribedResources[uri, default: 0] += 1
        }
    }

    private func releaseResourcesLocked(_ uris: some Collection<ExactString>, _ state: inout State) {
        for uri in uris {
            guard let holders = state.subscribedResources[uri] else { continue }
            if holders > 1 {
                state.subscribedResources[uri] = holders - 1
            } else {
                state.subscribedResources[uri] = nil
                state.subscribedResourceBytes -= uri.text.utf8.count
            }
        }
    }

    /// Forgets deferred events nobody here wants any more, so that the set of waiting events
    /// stays within what the connection is subscribed to.
    private func dropUnwantedEventsLocked(_ state: inout State) {
        guard !state.deferredEvents.isEmpty else { return }
        let snapshot = state
        state.deferredEvents.removeAll { pending in pending.map { !wantsLocked($0.event, snapshot) } ?? true }
        state.deferredHead = 0
        reindexDeferredEventsLocked(&state)
    }

    private func reindexDeferredEventsLocked(_ state: inout State) {
        state.deferredIndices = Dictionary(uniqueKeysWithValues: state.deferredEvents.enumerated().compactMap { index, pending in
            pending.map { (Self.key(of: $0.event), index) }
        })
    }

    private struct DeferredEvent {
        let event: ServerEvent
        let cutoff: UInt64
        let legacy: LegacySessionIdentity?
    }

    private enum EventRecipient {
        case modern(RequestID, UInt64)
        case legacy(LegacySessionIdentity)
    }

    private struct EventDelivery {
        let event: ServerEvent
        let recipients: [EventRecipient]
        var next = 0
    }

    /// Delivers in order. Backpressure pauses before the next recipient, and repeated pending
    /// events for a URI or list are coalesced. A sink that declines an event while reporting
    /// capacity drops that recipient's event, with a diagnostic.
    func deliver(_ event: ServerEvent) {
        let refused: Bool = state.withLock { state in
            guard !state.closing, wantsLocked(event, state) else { return false }
            let key = Self.key(of: event)
            let pending = DeferredEvent(event: event, cutoff: state.nextSerial,
                legacy: legacyWants(event, state) ? state.legacy?.identity : nil)
            if let existing = state.deferredIndices[key] {
                state.deferredEvents[existing] = pending
            } else {
                state.deferredIndices[key] = state.deferredEvents.count
                state.deferredEvents.append(pending)
            }
            let (_, refused) = drainEventsLocked(&state)
            if state.flushTask == nil, state.activeDelivery != nil || state.deferredHead < state.deferredEvents.count {
                state.flushTask = Task { [self] in await flushEvents() }
            }
            return refused
        }
        if refused { report(.refusedSubscriptionEvent, "the transport declined a subscription notification") }
    }

    private func flushEvents() async {
        while !Task.isCancelled {
            await sink.waitForCapacity()
            let (finished, progressed, refused) = state.withLock { state in
                guard !state.closing else { return (true, false, false) }
                let (progressed, refused) = drainEventsLocked(&state)
                let finished = state.activeDelivery == nil && state.deferredHead == state.deferredEvents.count
                if finished { state.flushTask = nil }
                return (finished, progressed, refused)
            }
            if refused { report(.refusedSubscriptionEvent, "the transport declined a subscription notification") }
            if finished { return }
            // Capacity can disappear before the next frame is offered, or a custom sink may
            // return from its wait while still full. Back off only when this round did no work.
            if !progressed { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    private func drainEventsLocked(_ state: inout State) -> (progressed: Bool, refused: Bool) {
        var progressed = false
        var refused = false
        while !sink.isOverBudget {
            if state.activeDelivery == nil {
                guard state.deferredHead < state.deferredEvents.count,
                    let pending = state.deferredEvents[state.deferredHead] else { break }
                state.deferredEvents[state.deferredHead] = nil
                state.deferredHead += 1
                progressed = true
                state.deferredIndices.removeValue(forKey: Self.key(of: pending.event))
                if state.deferredHead >= 64, state.deferredHead >= state.deferredEvents.count - state.deferredHead {
                    state.deferredEvents.removeFirst(state.deferredHead)
                    state.deferredHead = 0
                    reindexDeferredEventsLocked(&state)
                }
                let modern = state.subscriptions.compactMap { id, subscription -> (RequestID, UInt64)? in
                    guard wants(subscription, pending.event), let serial = state.inflight[id]?.serial, serial < pending.cutoff else { return nil }
                    return (id, serial)
                }.sorted { $0.1 < $1.1 }
                var recipients = modern.map { EventRecipient.modern($0.0, $0.1) }
                if let legacy = pending.legacy { recipients.append(.legacy(legacy)) }
                state.activeDelivery = EventDelivery(event: pending.event, recipients: recipients)
            }
            guard var delivery = state.activeDelivery else { break }
            guard delivery.next < delivery.recipients.count else {
                state.activeDelivery = nil
                continue
            }
            let recipient = delivery.recipients[delivery.next]
            let frameKey: RequestID?
            let stillSubscribed: Bool
            switch recipient {
            case .modern(let id, let serial):
                frameKey = id
                stillSubscribed = state.inflight[id]?.serial == serial && state.subscriptions[id] != nil
            case .legacy(let identity):
                frameKey = nil
                stillSubscribed = state.legacy?.identity === identity && legacyWants(delivery.event, state)
            }
            if stillSubscribed, !sink.enqueue(eventFrame(delivery.event, subscriptionID: frameKey), key: frameKey) {
                if sink.isOverBudget { break }
                refused = true
            }
            delivery.next += 1
            state.activeDelivery = delivery
            progressed = true
        }
        return (progressed, refused)
    }

    /// What makes two events the same event: the kind, and for a resource its URI, byte for byte.
    private enum EventKey: Hashable {
        case listChanged(ListKind)
        case resourceUpdated(ExactString)
    }

    private static func key(of event: ServerEvent) -> EventKey {
        switch event {
        case .listChanged(let kind): .listChanged(kind)
        case .resourceUpdated(let uri): .resourceUpdated(ExactString(uri))
        }
    }

    private func wants(_ subscription: Subscription, _ event: ServerEvent) -> Bool {
        switch event {
        case .listChanged(.tools): subscription.tools
        case .listChanged(.prompts): subscription.prompts
        case .listChanged(.resources), .listChanged(.templates): subscription.resources
        case .resourceUpdated(let updated): subscription.uris.contains(ExactString(updated))
        }
    }

    /// Whether a legacy session on this connection is to be told about `event`.
    private func legacyWants(_ event: ServerEvent, _ state: State) -> Bool {
        // Legacy sessions get unsolicited notifications once the handshake is complete.
        guard let legacy = state.legacy, legacy.initialized else { return false }
        return switch event {
        case .listChanged(let kind): legacy.negotiated.contains(kind.capability)
        case .resourceUpdated(let uri): legacy.resourceSubscriptions.contains(ExactString(uri))
        }
    }

    private func wantsLocked(_ event: ServerEvent, _ state: State) -> Bool {
        legacyWants(event, state) || state.subscriptions.values.contains { wants($0, event) }
    }

    private func eventFrame(_ event: ServerEvent, subscriptionID: RequestID?) -> [UInt8] {
        let method: String
        var uri: String?
        switch event {
        case .listChanged(.tools): method = "notifications/tools/list_changed"
        case .listChanged(.prompts): method = "notifications/prompts/list_changed"
        case .listChanged(.resources), .listChanged(.templates): method = "notifications/resources/list_changed"
        case .resourceUpdated(let updated):
            method = "notifications/resources/updated"
            uri = updated
        }
        guard subscriptionID != nil || uri != nil else { return Frame.notification(method: method) }
        return Frame.notification(method: method) { writer in
            writer.beginObject()
            if let subscriptionID {
                writer.key("_meta")
                writer.beginObject()
                writer.field(MetaKey.subscriptionID, subscriptionID)
                writer.endObject()
            }
            writer.field("uri", uri)
            writer.endObject()
        }
    }

    // MARK: Diagnostics

    /// What a diagnostic is about. A connection reports each kind at most `reportLimit` times;
    /// beyond that the reports are counted, and the count is reported when it closes.
    enum DiagnosticKind: Hashable, CustomStringConvertible {
        case malformedNotification, malformedReply, handlerFailed, invalidResult, refusedSubscriptionEvent

        var description: String {
            switch self {
            case .malformedNotification: "malformed notifications"
            case .malformedReply: "malformed replies"
            case .handlerFailed: "failed requests"
            case .invalidResult: "invalid tool results"
            case .refusedSubscriptionEvent: "refused subscription notifications"
            }
        }
    }

    static let reportLimit = 100

    /// Reports through `configuration.diagnostics`, outside every lock, with control characters
    /// escaped and the line shortened: the text may carry what a peer sent.
    private func report(_ kind: DiagnosticKind, _ message: @autoclosure () -> String) {
        let count: Int = state.withLock { state in
            state.reports[kind, default: 0] += 1
            return state.reports[kind]!
        }
        if count <= Self.reportLimit {
            configuration.diagnostics(diagnosticLine(message()))
        } else if count == Self.reportLimit + 1 {
            configuration.diagnostics("further \(kind.description) of this connection are counted, not reported")
        }
    }

    // MARK: Sending

    /// The urgent reserve of the sink: how much reader answers may queue beyond the budget.
    /// Only `OutboundQueue` says; any other sink is taken to take every urgent frame.
    private var reserveBytes: Int { (sink as? OutboundQueue)?.urgentReserveBytes ?? .max }

    /// Whether a reader answer may draw on the reserve: a sixteenth of it, so that a burst of
    /// such answers cannot use it up alone (64 KiB for the default reserve of 1 MiB) — but at
    /// least 4 KiB, or all of a smaller reserve, so that ordinary errors always count as small.
    private func isSmall(_ frame: [UInt8]) -> Bool {
        let reserve = reserveBytes
        return frame.count <= min(reserve, max(reserve / 16, 4096))
    }

    private static let outputBackpressureError = MCPError.overloaded("the client is not reading responses; retry later")

    /// The answer the reader sends instead of a frame that is not small while the peer is
    /// behind. Small by construction: a constant text and an id within `maxRequestIDBytes`.
    private func overloadAnswer(id: RequestID?) -> [UInt8] {
        Frame.error(id: id, Self.outputBackpressureError)
    }

    /// Sends a frame from the reader, which must not wait. Every frame given here is sent as
    /// it is, or replaced by `overloadAnswer`, or the connection is marked overflowed — never
    /// dropped while the connection lives:
    ///
    /// - A small frame draws on the urgent reserve, or, with the reserve full, goes out as
    ///   ordinary output while that is within its budget. When both are full, the reserve is
    ///   exhausted by frames that fit it: the peer is not reading, and the connection is marked
    ///   for closing instead of growing without bound.
    /// - A frame that is not small goes out as ordinary output while that is within its
    ///   budget; otherwise `substitute`, which is small, is sent instead, as above.
    private func sendFromReader(_ frame: [UInt8], substitute: @autoclosure () -> [UInt8]) {
        sendFromReader(Reply(frame: frame), substitute: Reply(frame: substitute()))
    }

    private func sendFromReader(_ reply: Reply, substitute: @autoclosure () -> Reply) {
        let small = isSmall(reply.frame)
        if enqueueReaderReply(reply, urgent: small) { return }
        if !small, enqueueReaderReply(substitute(), urgent: true) { return }
        state.withLock { $0.overflowed = true }
    }

    private func enqueueReaderFrame(_ frame: [UInt8], urgent: Bool) -> Bool {
        if urgent, sink.enqueue(frame, key: nil, urgent: true) { return true }
        return !sink.isOverBudget && sink.enqueue(frame, key: nil)
    }

    private func enqueueReaderReply(_ reply: Reply, urgent: Bool) -> Bool {
        guard let session = reply.session else { return enqueueReaderFrame(reply.frame, urgent: urgent) }
        return state.withLock { state in
            guard enqueueReaderFrame(reply.frame, urgent: urgent) else { return false }
            installLegacySessionLocked(session, &state)
            return true
        }
    }

    /// Sends a frame with no request to answer (a parse error, say).
    private func sendFromReader(_ frame: [UInt8]) {
        sendFromReader(frame, substitute: self.overloadAnswer(id: nil))
    }

    /// Answers a request from the reader, directly or as a member of a batch.
    /// `maxResponseBytes` applies as it does to handlers' results.
    private func respond(_ frame: [UInt8], id: RequestID?, _ responder: Responder, session: LegacySession? = nil) {
        let limit = configuration.budgets.maxResponseBytes
        var reply = Reply(frame: frame, session: session)
        if frame.count > limit, let id {
            reply = Reply(frame: Frame.error(id: id, .responseTooLarge(bytes: frame.count, limit: limit)))
        }
        switch responder {
        case .direct: sendFromReader(reply, substitute: Reply(frame: self.overloadAnswer(id: id)))
        case .batch(let collector, let slot):
            if let batch = collector.fill(slot, BatchCollector.Member(reply: reply, id: id, fromReader: true)) {
                sendBatchFromReader(batch)
            }
        }
    }

    /// A completed batch, from the reader. The rule is the one for single answers, applied to
    /// the joined reply: while the peer is behind, a reply that is not small has the answers
    /// the reader built replaced by `overloadAnswer`, largest first, until it is small. Handlers' results stay: they were
    /// admitted and computed, and they are bounded by the batch size and `maxResponseBytes`;
    /// a reply that is still not small goes out as ordinary output.
    private func sendBatchFromReader(_ batch: BatchCollector.Completed) {
        defer { withExtendedLifetime(batch) {} }
        let members = batch.members
        guard let reply = BatchCollector.join(members, maxBytes: configuration.budgets.maxResponseBytes) else { return }
        if isSmall(reply.frame) || !sink.isOverBudget {
            sendFromReader(reply, substitute: reply)
            return
        }
        // The largest of the reader's answers first, and only until the reply is small: a ping
        // next to a large listing keeps its result.
        var replaced = members
        var shorter = reply
        let order = members.indices.filter { members[$0].fromReader }.sorted {
            members[$0].reply.frame.count > members[$1].reply.frame.count
        }
        for index in order where !isSmall(shorter.frame) {
            replaced[index].reply = Reply(frame: overloadAnswer(id: members[index].id))
            guard let joined = BatchCollector.join(replaced, maxBytes: configuration.budgets.maxResponseBytes) else { return }
            shorter = joined
        }
        if isSmall(shorter.frame) {
            sendFromReader(shorter, substitute: shorter)
        } else {
            state.withLock { state in enqueueBatchLocked(shorter, &state) }
        }
    }

    /// A batch member that gets no response settles its slot all the same, or the reply would
    /// never be complete.
    private func respondWithNothing(_ responder: Responder) {
        if case .batch(let collector, let slot) = responder, let batch = collector.fill(slot, nil) {
            sendBatchFromReader(batch)
        }
    }

    /// An id within `maxRequestIDBytes`, or `nil`: an answer never echoes a longer one.
    private func withinIDLimit(_ id: RequestID?) -> RequestID? {
        guard let id, id.fitsEncodedByteLimit(configuration.budgets.maxRequestIDBytes) else { return nil }
        return id
    }

    private func deliverLocked(_ frame: [UInt8], _ responder: Responder, key: RequestID, _ state: inout State) {
        switch responder {
        case .direct: sink.enqueue(frame, key: key)
        case .batch(let collector, let slot):
            if let batch = collector.fill(slot, BatchCollector.Member(reply: Reply(frame: frame), id: key, fromReader: false)) {
                deliverBatchLocked(batch, &state)
            }
        }
    }

    private func deliverBatchLocked(_ batch: BatchCollector.Completed, _ state: inout State) {
        defer { withExtendedLifetime(batch) {} }
        if let reply = BatchCollector.join(batch.members, maxBytes: configuration.budgets.maxResponseBytes) {
            enqueueBatchLocked(reply, &state)
        }
    }

    private func enqueueBatchLocked(_ reply: Reply, _ state: inout State) {
        if sink.enqueue(reply.frame), let session = reply.session {
            installLegacySessionLocked(session, &state)
        }
    }

    // MARK: Closing

    /// Shuts the connection down after its input ended.
    ///
    /// Subscriptions end at once. Requests in flight get `graceSeconds` to finish and have their
    /// responses written (a client that pipes requests in and closes stdin still wants answers);
    /// what is still running after that is cancelled. Zero, a negative value or NaN cancels
    /// them at once; infinity waits for them however long they take. `endGracePeriod` cuts the
    /// wait short.
    public func close(graceSeconds: Double? = nil) async {
        let grace = graceSeconds ?? configuration.shutdownGraceSeconds
        let (abandoned, flushTask) = state.withLock { state in
            state.closing = true
            let flushTask = state.flushTask
            state.flushTask = nil
            state.activeDelivery = nil
            state.deferredEvents.removeAll()
            state.deferredHead = 0
            state.deferredIndices.removeAll()
            for id in state.subscriptions.keys {
                // The server is tearing the stream down: the specification requires a cancellation
                // notice and recommends completing the request so the client sees a graceful end.
                sink.enqueue(
                    Frame.notification(method: "notifications/cancelled") { writer in
                        writer.beginObject()
                        writer.field("requestId", id)
                        writer.field("reason", "server is shutting down")
                        writer.endObject()
                    })
                sink.enqueue(
                    Frame.result(id: id) { writer in
                        writer.beginObject()
                        writer.field("resultType", "complete")
                        writer.key("_meta")
                        writer.beginObject()
                        writer.field(MetaKey.subscriptionID, id)
                        writer.writeRawMembers(server.serverInfoMember)
                        writer.endObject()
                        writer.endObject()
                    })
                state.inflight[id] = nil
            }
            for subscription in state.subscriptions.values { releaseResourcesLocked(subscription.uris, &state) }
            state.subscriptions = [:]
            let abandoned = state.clientRequests.values.map(\.continuation)
            state.clientRequests = [:]
            return (abandoned, flushTask)
        }
        flushTask?.cancel()
        for continuation in abandoned { continuation.resume(throwing: CancellationError()) }

        if await !waitUntilIdle(seconds: grace, isGracePeriod: true) {
            var withdrawn: Set<UInt64> = []
            let tasks: [Task<Void, Never>] = state.withLock { state in
                var running: [Task<Void, Never>] = []
                for (id, entry) in state.inflight {
                    if let task = entry.task {
                        running.append(task)
                    } else if !entry.isSubscription {
                        // Never started: drop it without running it.
                        withdrawn.insert(entry.serial)
                        state.inflight[id] = nil
                        state.pending -= 1
                        settleBatchSlotLocked(entry.responder, &state)
                    }
                }
                return running
            }
            server.withdraw(owner: ObjectIdentifier(self), serials: withdrawn)
            for task in tasks { task.cancel() }
            // A handler that ignores cancellation must not keep the process alive.
            _ = await waitUntilIdle(seconds: 1)
        }
        // Whatever is still running was told to stop and did not. From here on it is not a
        // request any more: nothing it reports or returns is sent.
        let suppressed: [(DiagnosticKind, Int)] = state.withLock { state in
            for entry in state.inflight.values { settleBatchSlotLocked(entry.responder, &state) }
            state.inflight = [:]
            return state.reports.compactMap { kind, count in count > Self.reportLimit ? (kind, count - Self.reportLimit) : nil }
        }
        for (kind, count) in suppressed {
            configuration.diagnostics("\(count) more diagnostics of this connection were not reported: \(kind.description)")
        }
        server.forget(self)
    }

    /// A batch member cut off by `close` gets no response, but the members that finished
    /// still get theirs: the slot is settled so that the reply can be complete.
    private func settleBatchSlotLocked(_ responder: Responder, _ state: inout State) {
        if case .batch(let collector, let slot) = responder, let batch = collector.fill(slot, nil) {
            deliverBatchLocked(batch, &state)
        }
    }

    /// The peer is gone, so there is nobody left to finish requests for: ends the grace period
    /// of a `close` under way, and makes that of a later one zero. The transport calls this
    /// whenever it finds out, which may be before or after the input ended.
    package func endGracePeriod() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.graceEnded = true
            defer { state.graceWaiters.removeAll() }
            return state.graceWaiters.compactMap { state.idleWaiters.removeValue(forKey: $0) }
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until no handler is running. Returns `false` on timeout, or when the grace period
    /// it waits out (`isGracePeriod`) is ended.
    private func waitUntilIdle(seconds: Double, isGracePeriod: Bool = false) async -> Bool {
        let limit = timeLimit(seconds: seconds)
        let token: Int? = state.withLock { state in
            if state.pending == 0 || limit == .zero || (isGracePeriod && state.graceEnded) { return nil }
            state.nextIdleWaiter += 1
            if isGracePeriod { state.graceWaiters.insert(state.nextIdleWaiter) }
            return state.nextIdleWaiter
        }
        guard let token else { return state.withLock { $0.pending == 0 } }
        let timeout = limit.map { limit in
            Task { [self] in
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
                    if let waiter = state.idleWaiters.removeValue(forKey: token) { return waiter }
                    // The timer won the race with the registration below: leave word, or the
                    // waiter would register after its only wake-up had already come and gone.
                    state.expiredIdleWaiters.insert(token)
                    return nil
                }
                waiter?.resume()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.pending == 0 || state.expiredIdleWaiters.remove(token) != nil { return true }
                if isGracePeriod && state.graceEnded { return true }
                state.idleWaiters[token] = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        timeout?.cancel()
        return state.withLock { state in
            state.expiredIdleWaiters.remove(token)
            state.graceWaiters.remove(token)
            return state.pending == 0
        }
    }

    // MARK: Batch collection

    /// Gathers the responses of a JSON-RPC batch; the last one completes it.
    private final class BatchCollector: Sendable {
        struct Member: Sendable {
            var reply: Reply
            /// The id the response carries.
            let id: RequestID?
            /// Built on the reader (a listing, an error), not by a handler.
            let fromReader: Bool
        }

        /// Holds the reservation through the handoff to the sink, including size replacements.
        final class Completed: Sendable {
            let members: [Member]
            private let budget: BatchReplyBudget
            private let reservedBytes: Int

            init(members: [Member], budget: BatchReplyBudget, reservedBytes: Int) {
                self.members = members
                self.budget = budget
                self.reservedBytes = reservedBytes
            }

            deinit { budget.release(reservedBytes) }
        }

        private enum RetainedMember {
            case reply(Member)
            case overloaded(RequestID?, fromReader: Bool)

            var response: Member {
                switch self {
                case .reply(let member): member
                case .overloaded(let id, let fromReader):
                    Member(reply: Reply(frame: Frame.error(id: id, .overloaded("too many bytes waiting for legacy batch replies"))),
                           id: id, fromReader: fromReader)
                }
            }
        }

        private struct Slots {
            var members: [RetainedMember?]
            var settled: [Bool]
            var remaining: Int
            var reservedBytes = 0
        }

        private let budget: BatchReplyBudget
        private let slots: Mutex<Slots>

        init(slots count: Int, budget: BatchReplyBudget) {
            self.budget = budget
            slots = Mutex(Slots(members: Array(repeating: nil, count: count), settled: Array(repeating: false, count: count), remaining: count))
        }

        deinit { budget.release(slots.withLock { $0.reservedBytes }) }

        /// Holds ordinary replies only while they wait for another slot. Once the last slot
        /// settles, moves them and their reservation to the code sending the batch.
        func fill(_ slot: Int, _ member: Member?) -> Completed? {
            let completed: (members: [RetainedMember?], reservedBytes: Int)? = slots.withLock { slots in
                guard !slots.settled[slot] else { return nil }
                slots.settled[slot] = true
                slots.remaining -= 1
                if let member {
                    let bytes = member.reply.frame.count
                    if slots.remaining == 0 {
                        slots.members[slot] = .reply(member)
                    } else if budget.reserve(bytes) {
                        slots.members[slot] = .reply(member)
                        slots.reservedBytes += bytes
                    } else {
                        slots.members[slot] = .overloaded(member.id, fromReader: member.fromReader)
                    }
                }
                guard slots.remaining == 0 else { return nil }
                defer {
                    slots.members = []
                    slots.reservedBytes = 0
                }
                return (slots.members, slots.reservedBytes)
            }
            guard let completed else { return nil }
            let members = completed.members.compactMap { $0?.response }
            guard !members.isEmpty else { return nil }
            return Completed(members: members, budget: budget, reservedBytes: completed.reservedBytes)
        }

        /// Replaces the largest members with size errors until the batch fits. If that fails,
        /// every member gets a size error under its own id. Only the last surviving initialize
        /// result can change the session when the batch is queued.
        static func join(_ members: [Member], maxBytes: Int) -> Reply? {
            guard !members.isEmpty else { return nil }
            var members = members
            // Brackets and commas.
            var total = members.reduce(1) { $0 + $1.reply.frame.count + 1 }
            func tooLarge(_ member: Member) -> Member {
                let error = Frame.error(
                    id: member.id, .responseTooLarge(bytes: member.reply.frame.count, limit: maxBytes, inBatch: true))
                return Member(reply: Reply(frame: error), id: member.id, fromReader: member.fromReader)
            }
            while total > maxBytes,
                let largest = members.indices.max(by: { members[$0].reply.frame.count < members[$1].reply.frame.count })
            {
                let error = tooLarge(members[largest])
                guard error.reply.frame.count < members[largest].reply.frame.count else { break }
                total -= members[largest].reply.frame.count - error.reply.frame.count
                members[largest] = error
            }
            if total > maxBytes { members = members.map(tooLarge) }
            var batch: [UInt8] = [0x5B]
            batch.reserveCapacity(total)
            for (index, member) in members.enumerated() {
                if index > 0 { batch.append(0x2C) }
                batch.append(contentsOf: member.reply.frame)
            }
            batch.append(0x5D)
            let session = members.last(where: { $0.reply.session != nil })?.reply.session
            return Reply(frame: batch, session: session)
        }
    }
}

extension Result {
    /// The error of a failed result.
    fileprivate var thrownError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
