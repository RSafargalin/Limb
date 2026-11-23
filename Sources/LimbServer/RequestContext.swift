public import LimbCore
import Foundation
import Synchronization

/// Everything a handler knows about the request it is serving, and its way to talk back
/// while it runs: progress, log messages and requests for additional input.
///
/// One API for every revision. How a call travels (a notification on a session, a message
/// tagged with a subscription, an `InputRequiredResult`) is decided by the negotiated revision.
public final class RequestContext: Sendable {
    public let requestID: RequestID
    public let method: String
    /// The revision this request is served under.
    public let profile: RevisionProfile
    /// The client's self-reported identity. Display data only: never use it for decisions.
    public let clientInfo: Implementation?
    public let clientCapabilities: ClientCapabilities
    /// The request's `_meta`, including keys Limb does not interpret (trace context, extensions).
    public let meta: JSONObject

    let connection: Connection
    let serial: UInt64
    let progressToken: JSONValue?
    let logLevel: LoggingLevel?
    let legacySession: LegacySessionIdentity?
    let inputState: InputState

    init(
        requestID: RequestID, method: String, peer: Peer, meta: JSONObject, connection: Connection,
        serial: UInt64, inputState: InputState
    ) {
        self.requestID = requestID
        self.method = method
        profile = peer.profile
        clientInfo = peer.clientInfo
        clientCapabilities = peer.capabilities
        self.meta = meta
        self.connection = connection
        self.serial = serial
        logLevel = peer.logLevel
        legacySession = peer.legacySession
        self.inputState = inputState
        // A progress token is a string or an integer; anything else is ignored.
        switch meta[MetaKey.progressToken] {
        case .string(let token): progressToken = .string(token)
        case .number(let token) where token.isInteger: progressToken = .number(token)
        default: progressToken = nil
        }
    }

    public var protocolVersion: ProtocolVersion { profile.version }

    /// Whether the client cancelled this request. Long-running handlers should check it, or use
    /// APIs that throw `CancellationError`.
    public var isCancelled: Bool { Task.isCancelled }

    // MARK: Progress and logging

    /// Reports progress, if the client asked for it with a progress token.
    ///
    /// `progress` must increase from call to call; a value that does not is dropped, as the
    /// specification requires. Under backpressure only the latest value is kept.
    public func progress(_ progress: Double, total: Double? = nil, message: String? = nil) {
        guard let progressToken, progress.isFinite, !inputState.isHalted else { return }
        let frame = Frame.notification(method: "notifications/progress") { writer in
            writer.beginObject()
            writer.field("progressToken", progressToken)
            writer.field("progress", progress)
            writer.field("total", total)
            writer.field("message", message)
            writer.endObject()
        }
        connection.emit(frame, for: requestID, serial: serial, progress: progress)
    }

    /// Sends a log message to the client (`notifications/message`).
    ///
    /// In `2026-07-28` a message is sent only if this request asked for a level in its `_meta`;
    /// in earlier revisions the session's `logging/setLevel` applies. Logging is deprecated as of
    /// `2026-07-28`: prefer stderr on stdio, or OpenTelemetry.
    public func log(_ level: LoggingLevel, _ data: JSONValue, logger: String? = nil) {
        guard !inputState.isHalted, let minimum = connection.logThreshold(for: self), level >= minimum else { return }
        let frame = Frame.notification(method: "notifications/message") { writer in
            writer.beginObject()
            writer.field("level", level.rawValue)
            writer.field("logger", logger)
            writer.field("data", data)
            writer.endObject()
        }
        connection.emit(frame, for: requestID, serial: serial, progress: nil)
    }

    // MARK: Additional input

    /// Asks the client for several inputs at once and returns the answers by key.
    ///
    /// The two eras of the protocol do this differently, and Limb keeps each one's own semantics:
    ///
    /// - **Legacy** revisions: each request is sent to the client as a JSON-RPC request and this
    ///   call suspends until all are answered.
    /// - **`2026-07-28`**: the server replies with `InputRequiredResult` and the client retries the
    ///   original request with the answers, so **the handler runs again from the start**. On the
    ///   run where the answers are present this call returns them; on the run where they are not,
    ///   it throws to end the run. Do not catch that error, and produce no side effects before the
    ///   last input point: a handler that follows this rule is correct in both eras.
    ///
    /// Keys must be unique within one call, and stable across runs. A key asked for earlier in
    /// this run of the handler — in an earlier call, or in one running at the same time — cannot
    /// be asked for again: in `2026-07-28` the second question would receive the first one's
    /// answer, so it is an error in every revision. A question that got no answer (one that
    /// timed out) may be asked again.
    ///
    /// In legacy revisions a request the client leaves unanswered for
    /// `ServerConfiguration.clientRequestTimeoutSeconds` is withdrawn, and this call throws
    /// `MCPError.requestTimedOut`.
    public func input(_ requests: KeyValuePairs<String, InputRequest>) async throws -> [String: InputResponse] {
        guard inputState.allowed else {
            throw MCPError.internalError("\(method) cannot request additional input")
        }
        let formValidators = try elicitationValidators(for: requests)
        let keys = requests.map(\.key)
        try inputState.reserve(keys)
        for (_, request) in requests {
            if let missing = missingCapability(for: request) {
                if profile.multiRoundTrip {
                    let error = MCPError.missingClientCapability(missing.required)
                    inputState.release(keys, reporting: error)
                    throw error
                }
                inputState.release(keys)
                throw InputUnavailable(capability: missing.name)
            }
        }
        if profile.multiRoundTrip {
            do {
                return try inputState.resolve(requests) { key, answer throws(MCPError) in
                    try validateFormAnswer(answer, for: key, using: formValidators[key])
                }
            } catch let signal as InputRequiredSignal {
                // The run ends here. Throwing cannot force that — the handler may catch the
                // error — so the handler's task is cancelled as well, and from now on nothing
                // it reports is sent.
                connection.haltHandler(for: requestID, serial: serial)
                throw signal
            }
        }
        return try await withThrowingTaskGroup(of: (String, InputResponse).self) { group in
            for (key, request) in requests {
                group.addTask { [self] in
                    do {
                        let reply = try await connection.requestClient(
                            request, profile: profile, legacySession: legacySession, caller: (id: requestID, serial: serial))
                        let answer: InputResponse
                        do {
                            answer = try InputResponse(json: reply, for: request)
                        } catch {
                            throw MCPError.internalError("the client's reply to \(request.method) is malformed: \(error)")
                        }
                        try validateFormAnswer(answer, for: key, using: formValidators[key])
                        return (key, answer)
                    } catch {
                        // No answer: the question may be asked again.
                        inputState.release([key])
                        throw error
                    }
                }
            }
            var answers: [String: InputResponse] = [:]
            for try await (key, answer) in group { answers[key] = answer }
            return answers
        }
    }

    /// Asks the user to fill in a form. `key` identifies this question within the request.
    ///
    /// The content of an accepted answer comes from the client; it is checked against `schema`
    /// before it is returned, and an answer that does not match is an error, never data.
    public func elicit(_ key: String, message: String, schema: JSONObject) async throws -> ElicitResult {
        let answers = try await input([key: .elicit(ElicitRequest(message: message, requestedSchema: schema))])
        guard case .elicit(let result) = answers[key] else { throw MCPError.internalError("missing answer for \(key)") }
        return result
    }

    /// Asks the user to complete an interaction at a URL (`2025-11-25` and later).
    ///
    /// The answer says only whether the user agreed to go there; the interaction itself
    /// happens out of band. In `2025-11-25` the request carries `elicitationID` (a random one
    /// if `nil`), and the server may report the end of the interaction with
    /// `notifications/elicitation/complete` (`notifyElicitationComplete(_:)`).
    public func elicit(_ key: String, message: String, url: String, elicitationID: String? = nil) async throws -> ElicitResult {
        let request = ElicitRequest(message: message, url: url, elicitationID: elicitationID)
        let answers = try await input([key: .elicit(request)])
        guard case .elicit(let result) = answers[key] else { throw MCPError.internalError("missing answer for \(key)") }
        return result
    }

    /// Tells the client that the out-of-band interaction of a URL-mode elicitation is over
    /// (`notifications/elicitation/complete`, `2025-11-25`). It concerns the session, not this
    /// request, so it may be sent after the request has ended — keep the context, or the
    /// `Connection`, for that. Returns `false`, and sends nothing, when the session's revision
    /// has no such notification or the connection is closed.
    @discardableResult
    public func notifyElicitationComplete(_ elicitationID: String) -> Bool {
        connection.notifyElicitationComplete(elicitationID)
    }

    /// Asks the client's model for a completion. Deprecated as of `2026-07-28`.
    public func sample(_ key: String, _ request: SamplingRequest) async throws -> SamplingResult {
        let answers = try await input([key: .sample(request)])
        guard case .sample(let result) = answers[key] else { throw MCPError.internalError("missing answer for \(key)") }
        return result
    }

    /// Asks the client for its workspace roots. Deprecated as of `2026-07-28`.
    public func roots(_ key: String = "roots") async throws -> [Root] {
        let answers = try await input([key: .roots])
        guard case .roots(let result) = answers[key] else { throw MCPError.internalError("missing answer for \(key)") }
        return result
    }

    private func elicitationValidators(for requests: KeyValuePairs<String, InputRequest>) throws(MCPError) -> [String: JSONSchema] {
        var validators: [String: JSONSchema] = [:]
        for (key, request) in requests {
            guard case .elicit(let elicitation) = request else { continue }
            switch elicitation.mode {
            case .form(let schema):
                guard schema["type"] == "object",
                    let fields = (schema["properties"] ?? [:]).objectValue,
                    fields.allSatisfy({ entry in entry.value.objectValue.map(isElicitationField) == true })
                else {
                    throw .internalError("the requested schema of \"\(key)\" must be a flat elicitation form")
                }
                do {
                    validators[key] = try JSONSchema(.object(schema))
                } catch {
                    throw .internalError("the requested schema of \"\(key)\" cannot be enforced: \(error)")
                }
            case .url(let url):
                guard !url.utf8.contains(where: { $0 <= 0x20 }), URL(string: url)?.scheme != nil else {
                    throw .internalError("the URL for elicitation \"\(key)\" must be absolute")
                }
            }
        }
        return validators
    }

    private func isElicitationField(_ field: JSONObject) -> Bool {
        func strings(_ value: JSONValue?) -> Bool {
            guard let choices = value?.arrayValue, !choices.isEmpty else { return false }
            return choices.allSatisfy { $0.stringValue != nil }
        }
        func titledChoices(_ value: JSONValue?) -> Bool {
            guard let choices = value?.arrayValue, !choices.isEmpty else { return false }
            return choices.allSatisfy { $0["const"]?.stringValue != nil && $0["title"]?.stringValue != nil }
        }
        switch field["type"]?.stringValue {
        case "string":
            if let choices = field["oneOf"] { return profile.urlElicitation && titledChoices(choices) }
            return field["enum"] == nil || strings(field["enum"])
        case "number", "integer", "boolean": return true
        case "array":
            guard profile.urlElicitation, let items = field["items"]?.objectValue else { return false }
            if items["type"] == "string" { return strings(items["enum"]) }
            return titledChoices(items["anyOf"])
        default: return false
        }
    }

    private func validateFormAnswer(_ answer: InputResponse, for key: String, using validator: JSONSchema?) throws(MCPError) {
        guard let validator, case .elicit(let result) = answer, result.action == .accept,
            let violation = validator.validate(.object(result.content ?? JSONObject()))
        else { return }
        let detail = "the client's answer to \"\(key)\" does not match the requested schema: \(violation)"
        throw profile.multiRoundTrip ? .invalidParams(detail) : .internalError(detail)
    }

    /// The capability `request` needs, if the client did not declare it or the revision lacks it.
    private func missingCapability(for request: InputRequest) -> (name: String, required: JSONObject)? {
        switch request {
        case .elicit(let elicit):
            switch elicit.mode {
            case .form:
                let available = (profile.elicitationRequests || profile.multiRoundTrip) && clientCapabilities.supportsElicitation
                return available ? nil : ("elicitation", ["elicitation": ["form": [:]]])
            case .url:
                let available = profile.urlElicitation && clientCapabilities.supportsURLElicitation
                return available ? nil : ("URL elicitation", ["elicitation": ["url": [:]]])
            }
        case .sample(let sampling):
            let available = (profile.serverInitiatedRequests || profile.multiRoundTrip) && clientCapabilities.supportsSampling
            guard available else { return ("sampling", ["sampling": [:]]) }
            // Tools in sampling arrived in 2025-11-25, and a client has to declare them.
            guard sampling.params["tools"] != nil || sampling.params["toolChoice"] != nil else { return nil }
            let withTools = profile.samplingTools && clientCapabilities.supportsSamplingTools
            return withTools ? nil : ("sampling with tools", ["sampling": ["tools": [:]]])
        case .roots:
            let available = (profile.serverInitiatedRequests || profile.multiRoundTrip) && clientCapabilities.supportsRoots
            return available ? nil : ("roots", ["roots": [:]])
        }
    }
}

/// The request context available to tool handlers.
public typealias ToolContext = RequestContext

/// Ends a handler run in `2026-07-28` when input is still missing. The server turns the run
/// into an `InputRequiredResult`; whatever the handler does afterwards is discarded.
struct InputRequiredSignal: Error {}

/// Tracks additional input across the rounds of one request.
final class InputState: Sendable {
    /// Whether the method may ask for input (`tools/call`, `prompts/get`, `resources/read`).
    let allowed: Bool
    /// Answers available to this run: earlier rounds' (from `requestState`) and this round's.
    let answers: JSONObject
    let fingerprint: String

    private struct Progress {
        /// Requests the handler asked for and has no answer to.
        var pending: [(key: String, request: InputRequest)] = []
        /// Answers the handler consumed; they are carried to the next round.
        var journal = JSONObject()
        /// The run reached an input point without an answer and is over.
        var halted = false
        /// Keys this run has asked for and not given up on.
        var reserved: Set<String> = []
        /// The distinct protocol errors generated by actual input capability checks.
        var missingCapabilityErrors: [MCPError] = []
    }

    var isHalted: Bool { progress.withLock { $0.halted } }

    private let progress = Mutex(Progress())

    init(allowed: Bool, answers: JSONObject = JSONObject(), fingerprint: String = "") {
        self.allowed = allowed
        self.answers = answers
        self.fingerprint = fingerprint
    }

    static let unavailable = InputState(allowed: false)

    /// Reserves the keys of one `input` call for the rest of the run, as soon as they are
    /// asked: a second question under a key asked before — concurrently or earlier — would
    /// receive the first one's answer in `2026-07-28`, so it is refused in every revision. Check
    /// and reservation are one step under one lock, so two concurrent calls cannot both pass.
    func reserve(_ keys: [String]) throws(MCPError) {
        let repeated: String? = progress.withLock { progress in
            var seen: Set<String> = []
            guard let repeated = keys.first(where: { !seen.insert($0).inserted || progress.reserved.contains($0) }) else {
                progress.reserved.formUnion(keys)
                return nil
            }
            return repeated
        }
        if let repeated { throw MCPError.internalError("input key \"\(repeated)\" is used twice in one request") }
    }

    /// Gives keys back after their questions got no answer (timed out, failed, not asked).
    func release(_ keys: [String], reporting error: MCPError? = nil) {
        progress.withLock {
            $0.reserved.subtract(keys)
            if let error, !$0.missingCapabilityErrors.contains(error) { $0.missingCapabilityErrors.append(error) }
        }
    }

    func reportedMissingCapability(_ error: MCPError) -> Bool {
        error.code == MCPError.Code.missingRequiredClientCapability && progress.withLock { $0.missingCapabilityErrors.contains(error) }
    }

    func resolve(
        _ requests: KeyValuePairs<String, InputRequest>, validate: (String, InputResponse) throws(MCPError) -> Void
    ) throws -> [String: InputResponse] {
        var resolved: [String: InputResponse] = [:]
        var missing: [(key: String, request: InputRequest)] = []
        for (key, request) in requests {
            guard let raw = answers[key] else {
                missing.append((key, request))
                continue
            }
            let answer: InputResponse
            do {
                answer = try InputResponse(json: raw, for: request)
            } catch {
                throw MCPError.invalidParams("inputResponses.\(key): \(error)")
            }
            try validate(key, answer)
            resolved[key] = answer
        }
        progress.withLock { progress in
            for (key, _) in requests {
                if let raw = answers[key] { progress.journal[key] = raw }
            }
            for entry in missing where !progress.pending.contains(where: { $0.key == entry.key }) {
                progress.pending.append(entry)
            }
            if !missing.isEmpty { progress.halted = true }
        }
        if !missing.isEmpty { throw InputRequiredSignal() }
        return resolved
    }

    /// The outstanding requests and the journal for the next round, if the run needs more input.
    func outstanding() -> (requests: [(key: String, request: InputRequest)], journal: JSONObject)? {
        let snapshot = progress.withLock { $0 }
        guard !snapshot.pending.isEmpty else { return nil }
        return (requests: snapshot.pending, journal: snapshot.journal)
    }
}

/// The era and identity a request is served under.
final class LegacySessionIdentity: Sendable {}

struct Peer: Sendable {
    let profile: RevisionProfile
    let capabilities: ClientCapabilities
    let clientInfo: Implementation?
    /// Minimum level for `notifications/message` on this request; `nil` sends none.
    let logLevel: LoggingLevel?
    var negotiatedServerCapabilities: Set<ServerCapability> = []
    var legacySession: LegacySessionIdentity? = nil
}
