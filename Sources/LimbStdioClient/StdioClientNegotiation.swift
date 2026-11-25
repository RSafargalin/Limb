#if os(macOS)
public import LimbClient
public import LimbCore

/// A trusted executable to launch directly as an MCP server.
public struct StdioServer: Sendable {
    let configuration: StdioProcessConfiguration

    public init(
        executable: String, arguments: [String] = [], workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        configuration = StdioProcessConfiguration(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
    }
}

/// Relaunch the server once after an unexpected disconnect and re-open active subscriptions.
public struct StdioRecoveryOptions: Sendable {
    public var backoff: Duration

    public init(backoff: Duration = .milliseconds(100)) { self.backoff = backoff }
}

public struct StdioClientOptions: Sendable {
    public var clientInfo: Implementation
    /// The overall budget, including process launch, probes, and the legacy ready notification.
    public var timeout: Duration
    /// How long silence on the first discovery probe is allowed to defer legacy initialization.
    public var discoveryTimeout: Duration
    public var maxFrameBytes: Int
    public var maxPending: Int
    /// Handles server requests for input. Legacy capabilities are negotiated at initialization.
    /// In MCP 2026-07-28 an empty collection enables state-only continuations, and `nil`
    /// surfaces input-required results as `ClientResponseError.inputRequired`.
    public var inputHandlers: ClientInputHandlers?
    /// Start directly with `initialize` and require this exact legacy revision.
    /// The default discovers the era and accepts supported legacy counteroffers.
    public var legacyVersion: ProtocolVersion?
    /// The local deadline for each incoming legacy request for input.
    public var legacyInputTimeout: Duration
    /// Enable recovery with the original launch configuration and the same negotiated revision.
    public var recovery: StdioRecoveryOptions?

    public init(
        clientInfo: Implementation = .init(name: "Limb", version: "0.0.1"),
        timeout: Duration = .seconds(15), discoveryTimeout: Duration = .seconds(5),
        maxFrameBytes: Int = 8 * 1024 * 1024, maxPending: Int = 128,
        inputHandlers: ClientInputHandlers? = nil, legacyVersion: ProtocolVersion? = nil,
        legacyInputTimeout: Duration = .seconds(60), recovery: StdioRecoveryOptions? = nil
    ) {
        self.clientInfo = clientInfo
        self.timeout = timeout
        self.discoveryTimeout = discoveryTimeout
        self.maxFrameBytes = maxFrameBytes
        self.maxPending = maxPending
        self.inputHandlers = inputHandlers
        self.legacyVersion = legacyVersion
        self.legacyInputTimeout = legacyInputTimeout
        self.recovery = recovery
    }
}

public enum StdioNegotiationError: Error, Equatable, Sendable {
    case invalidConfiguration
    case timedOut
    case recoveryTimedOut(original: MCPError?)
    case connectionLost
    case malformedResponse
    case unsupportedVersions([String])
    case frameTooLarge
    case cleanupPending
}

extension Client {
    /// Launch an MCP server and agree on the protocol version before returning the client.
    public static func connect(stdio: StdioServer, options: StdioClientOptions = .init()) async throws -> Client {
        try await connectStdio(stdio.configuration, options: options)
    }

    package static func connectStdio(
        _ configuration: StdioProcessConfiguration,
        options: StdioClientOptions
    ) async throws -> Client {
        if let recovery = options.recovery, recovery.backoff < .zero || recovery.backoff > .seconds(Int32.max) {
            throw StdioNegotiationError.invalidConfiguration
        }
        let quotas = options.recovery.map { _ in ClientExecutionQuotas(limit: options.maxPending) }
        let session = try await connectStdioSession(configuration, options: options, executionQuotas: quotas, waitForCleanupOnFailure: false)
        guard let recovery = options.recovery else { return session }
        return try await withStdioRecovery(session, limit: options.maxPending, backoff: recovery.backoff) { floor in
            try await connectStdioSession(
                configuration, options: options, executionQuotas: quotas, waitForCleanupOnFailure: true, requestIDFloor: floor)
        }
    }

    private static func connectStdioSession(
        _ configuration: StdioProcessConfiguration, options: StdioClientOptions,
        executionQuotas: ClientExecutionQuotas?, waitForCleanupOnFailure: Bool, requestIDFloor: Int = 0
    ) async throws -> Client {
        guard options.timeout > .zero, options.timeout <= .seconds(Int32.max),
              options.discoveryTimeout > .zero, options.maxFrameBytes > 0, options.maxPending > 0,
              options.inputHandlers?.hasValidLimits != false,
              options.legacyInputTimeout > .zero, options.legacyInputTimeout <= .seconds(Int32.max),
              options.legacyVersion.map({ RevisionProfile.profile(for: $0)?.hasInitialize == true }) != false,
              !options.clientInfo.name.isEmpty, !options.clientInfo.version.isEmpty else {
            throw StdioNegotiationError.invalidConfiguration
        }
        let deadline = ContinuousClock.now + options.timeout
        var retryModern: RevisionProfile?
        var original: MCPError?
        var requestIDFloor = requestIDFloor
        do {
            while true {
                try Task.checkCancellation()
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw StdioNegotiationError.timedOut }
                guard requestIDFloor < Int.max else { throw ClientError.requestIDsExhausted }
                let inbox = StdioBootstrapInbox(maxFrameBytes: options.maxFrameBytes, lastID: requestIDFloor)
                let startup = StdioProcessStartup(configuration, bootstrap: inbox)
                let process: StdioProcess
                do {
                    process = try await startup.launch(timeout: remaining)
                } catch {
                    if waitForCleanupOnFailure { await startup.waitForCleanup() }
                    if case StdioProcessError.cleanupPending = error { throw StdioNegotiationError.cleanupPending }
                    throw error
                }
                let transport = StdioClientTransport(
                    process: process, startup: startup, profile: retryModern ?? .r2026_07_28,
                    maxFrameBytes: options.maxFrameBytes, controlLimit: options.maxPending, bootstrap: inbox,
                    serverIdentity: configuration.executable, executionQuotas: executionQuotas)
                do {
                    let outcome = try await transport.negotiate(options: options, deadline: deadline, modernOnly: retryModern)
                    try Task.checkCancellation()
                    switch outcome {
                    case .ready(let client):
                        return client
                    case .restart(let profile, let rejection):
                        retryModern = profile
                        original = rejection
                        if options.recovery != nil { requestIDFloor = inbox.lastID }
                        _ = await transport.beginShutdown()
                        try await startup.waitForCleanup(until: deadline)
                    }
                } catch {
                    _ = await transport.beginShutdown()
                    if waitForCleanupOnFailure { await transport.close() }
                    throw error
                }
            }
        } catch {
            try Task.checkCancellation()
            if let original, let negotiation = error as? StdioNegotiationError,
               negotiation == .timedOut || negotiation == .cleanupPending {
                throw StdioNegotiationError.recoveryTimedOut(original: original)
            }
            throw error
        }
    }
}

struct StdioPeer: Sendable {
    let profile: RevisionProfile
    let capabilities: JSONObject
    let info: Implementation?
}

enum StdioNegotiationOutcome: Sendable {
    case ready(Client)
    case restart(RevisionProfile, original: MCPError? = nil)
}

enum StdioBootstrapWrite: Equatable {
    case complete
    case withheld
    case partial
}

enum StdioDiscovery {
    case found(StdioPeer)
    case retry(RevisionProfile)
    case legacy

    var modernProfile: RevisionProfile? {
        switch self {
        case .found(let peer): peer.profile
        case .retry(let profile): profile
        case .legacy: nil
        }
    }

    init(_ result: Result<JSONValue, MCPError>, offered: RevisionProfile) throws {
        switch result {
        case .success(let body):
            guard body["resultType"] == "complete", case .number(let ttl) = body["ttlMs"],
                  ttl.isInteger, ttl >= JSONNumber(0),
                  body["cacheScope"] == "public" || body["cacheScope"] == "private" else {
                throw StdioNegotiationError.malformedResponse
            }
            let profile = try Self.sharedModern(body["supportedVersions"])
            let capabilities = try StdioCapabilities.decode(body["capabilities"], profile: profile)
            try Self.validateResultMetadata(body)
            let identity = try body["_meta"]?[MetaKey.serverInfo].map { try Self.identity($0, profile: profile) }
            self = .found(StdioPeer(profile: profile, capabilities: capabilities, info: identity))

        case .failure(let error):
            switch error.code {
            case MCPError.Code.unsupportedProtocolVersion:
                guard error.data?["requested"]?.stringValue == offered.version.rawValue else {
                    throw StdioNegotiationError.malformedResponse
                }
                self = .retry(try Self.sharedModern(error.data?["supported"]))
            case MCPError.Code.headerMismatch, MCPError.Code.missingRequiredClientCapability:
                throw error
            default:
                self = .legacy
            }
        }
    }

    private static func sharedModern(_ value: JSONValue?) throws -> RevisionProfile {
        guard let array = value?.arrayValue, !array.isEmpty else { throw StdioNegotiationError.malformedResponse }
        let versions = try array.map { element in
            guard let version = element.stringValue, !version.isEmpty else {
                throw StdioNegotiationError.malformedResponse
            }
            return version
        }
        let offered = Set(versions)
        guard let profile = RevisionProfile.all.first(where: {
            $0.hasDiscover && offered.contains($0.version.rawValue)
        }) else { throw StdioNegotiationError.unsupportedVersions(versions) }
        return profile
    }

    static func validateResultMetadata(_ body: JSONValue) throws(StdioNegotiationError) {
        if let instructions = body["instructions"], instructions.stringValue == nil { throw .malformedResponse }
        if let metadata = body["_meta"], metadata.objectValue == nil { throw .malformedResponse }
    }

    static func identity(_ value: JSONValue, profile: RevisionProfile) throws(StdioNegotiationError) -> Implementation {
        guard value["name"]?.stringValue != nil, value["version"]?.stringValue != nil else { throw .malformedResponse }
        var info = Implementation(lenient: value)
        if profile.structuredOutput { _ = try optionalString(value["title"]) }
        if profile.implementationDetails {
            _ = try optionalString(value["description"])
            _ = try optionalString(value["websiteUrl"])
        }
        if profile.icons, let icons = value["icons"] {
            guard let entries = icons.arrayValue else { throw .malformedResponse }
            do {
                for entry in entries { info.icons.append(try Icon(wire: entry)) }
            } catch {
                throw .malformedResponse
            }
        }
        return info
    }

    private static func optionalString(_ value: JSONValue?) throws(StdioNegotiationError) -> String? {
        guard let value else { return nil }
        guard let string = value.stringValue else { throw .malformedResponse }
        return string
    }
}

extension StdioClientTransport {
    func negotiate(
        options: StdioClientOptions, deadline: ContinuousClock.Instant, modernOnly: RevisionProfile?
    ) async throws -> StdioNegotiationOutcome {
        if options.legacyVersion != nil {
            return try await legacy(watching: nil, options: options, until: deadline)
        }
        let offered = modernOnly ?? .r2026_07_28
        let now = ContinuousClock.now
        let probeLimit = modernOnly == nil ? now + min(now.duration(to: deadline), options.discoveryTimeout) : deadline
        let probe = try await discover(offered, clientInfo: options.clientInfo, until: probeLimit)
        let reply: StdioBootstrapReply
        do {
            reply = try await bootstrapReply(matching: [probe], until: probeLimit)
        } catch StdioNegotiationError.timedOut where modernOnly == nil {
            return try await legacy(watching: probe, options: options, until: deadline)
        }
        let evidence = try StdioDiscovery(reply.result, offered: offered)
        switch evidence {
        case .legacy:
            if modernOnly == nil { return try await legacy(watching: nil, options: options, until: deadline) }
            _ = try reply.result.get() // Preserve the peer's rejection on the modern-only attempt.
            throw StdioNegotiationError.malformedResponse
        case .found(let peer):
            return .ready(try install(peer, options: options, until: deadline))
        case .retry(let next):
            let peer = try await confirmModern(next, clientInfo: options.clientInfo, until: deadline)
            return .ready(try install(peer, options: options, until: deadline))
        }
    }

    private func discover(
        _ profile: RevisionProfile, clientInfo: Implementation, until deadline: ContinuousClock.Instant
    ) async throws -> RequestID {
        let info = try stdioIdentity(clientInfo, profile: profile)
        let params = stdioRequestParams([:], profile: profile, clientIdentity: info)
        return try await bootRequest("server/discover", params: params, until: deadline)
    }

    private func confirmModern(
        _ profile: RevisionProfile, clientInfo: Implementation, until deadline: ContinuousClock.Instant
    ) async throws -> StdioPeer {
        let id = try await discover(profile, clientInfo: clientInfo, until: deadline)
        let reply = try await bootstrapReply(matching: [id], until: deadline)
        let evidence = try StdioDiscovery(reply.result, offered: profile)
        if case .found(let peer) = evidence { return peer }
        _ = try reply.result.get()
        throw StdioNegotiationError.malformedResponse
    }

    private func legacy(
        watching probe: RequestID?, options: StdioClientOptions, until deadline: ContinuousClock.Instant
    ) async throws -> StdioNegotiationOutcome {
        let offer = options.legacyVersion.flatMap { RevisionProfile.profile(for: $0) } ?? .r2025_11_25
        let advertised = options.inputHandlers?.legacyCapabilities(offer: offer, pinned: options.legacyVersion != nil) ?? [:]
        let info = try stdioIdentity(options.clientInfo, profile: offer)
        let params: JSONObject = [
            "protocolVersion": .string(offer.version.rawValue), "capabilities": .object(advertised), "clientInfo": info,
        ]
        let inbox = try checkBootstrap(until: deadline)
        inbox.allowLegacyPings(limit: options.maxPending)
        let id = try inbox.issueID()
        let initialize = Frame.request(id: id, method: "initialize") { $0.write(params) }
        let write = try await writeBootstrapFrame(initialize, watching: probe, until: deadline)
        if write != .complete {
            guard let evidence = try takeLateDiscovery(probe, until: deadline),
                  let modern = evidence.modernProfile else { throw StdioNegotiationError.connectionLost }
            if write == .withheld {
                return try await enterModern(evidence, options: options, until: deadline)
            }
            return .restart(modern)
        }
        var watching = probe.map { [id, $0] } ?? [id]
        var late = probe
        while true {
            let reply = try await bootstrapReply(matching: watching, watching: late, until: deadline)
            if reply.id == late {
                let evidence = try StdioDiscovery(reply.result, offered: .r2026_07_28)
                if let modern = evidence.modernProfile {
                    var rejection: MCPError?
                    if let initialization = try takeBootstrapReply(matching: id, until: deadline),
                       case .failure(let original) = try initialization.result { rejection = original }
                    return .restart(modern, original: rejection)
                }
                watching = [id]
                late = nil
                continue
            }

            let body: JSONValue
            switch try reply.result {
            case .success(let result):
                body = result
            case .failure(let rejection):
                if let late, let modern = try await lateModernProfile(late, until: deadline) {
                    return .restart(modern, original: rejection)
                }
                throw rejection
            }
            guard let version = body["protocolVersion"]?.stringValue,
                  let identity = body["serverInfo"] else {
                throw StdioNegotiationError.malformedResponse
            }
            guard let profile = RevisionProfile.profile(for: ProtocolVersion(rawValue: version)), profile.hasInitialize else {
                throw StdioNegotiationError.unsupportedVersions([version])
            }
            if let pinned = options.legacyVersion, profile.version != pinned {
                throw StdioNegotiationError.unsupportedVersions([version])
            }
            try inbox.validateBatchPolicy(acceptsBatch: profile.acceptsBatch)
            try StdioDiscovery.validateResultMetadata(body)
            let server = try StdioDiscovery.identity(identity, profile: profile)
            let caps = try StdioCapabilities.decode(body["capabilities"], profile: profile)
            let initialized = Frame.notification(method: "notifications/initialized")
            while try await writeBootstrapFrame(initialized, watching: late, ready: true, until: deadline) != .complete {
                if let modern = try takeLateDiscovery(late, until: deadline)?.modernProfile { return .restart(modern) }
                guard let ping = inbox.takePing() else { throw StdioNegotiationError.connectionLost }
                if try await writeBootstrapPong(ping, watching: late, until: deadline) != .complete {
                    guard let modern = try takeLateDiscovery(late, until: deadline)?.modernProfile else {
                        throw StdioNegotiationError.connectionLost
                    }
                    return .restart(modern)
                }
            }
            return .ready(try install(StdioPeer(profile: profile, capabilities: caps, info: server),
                                      options: options, legacyCapabilities: advertised, until: deadline))
        }
    }

    private func lateModernProfile(
        _ id: RequestID, until deadline: ContinuousClock.Instant
    ) async throws -> RevisionProfile? {
        // A dual-era peer can reject initialize before sending its original discovery reply.
        do {
            let reply = try await bootstrapReply(matching: [id], watching: id, until: deadline)
            return try StdioDiscovery(reply.result, offered: .r2026_07_28).modernProfile
        } catch StdioNegotiationError.timedOut {
            try Task.checkCancellation()
            return nil
        } catch StdioNegotiationError.connectionLost {
            try Task.checkCancellation()
            return nil
        }
    }

    private func takeLateDiscovery(
        _ id: RequestID?, until deadline: ContinuousClock.Instant
    ) throws -> StdioDiscovery? {
        _ = try checkBootstrap(until: deadline)
        guard let id, let reply = try takeBootstrapReply(matching: id, until: deadline) else { return nil }
        let evidence = try StdioDiscovery(reply.result, offered: .r2026_07_28)
        return evidence.modernProfile == nil ? nil : evidence
    }

    private func enterModern(
        _ evidence: StdioDiscovery, options: StdioClientOptions, until deadline: ContinuousClock.Instant
    ) async throws -> StdioNegotiationOutcome {
        let peer: StdioPeer
        switch evidence {
        case .found(let found): peer = found
        case .retry(let next): peer = try await confirmModern(next, clientInfo: options.clientInfo, until: deadline)
        case .legacy: throw StdioNegotiationError.malformedResponse
        }
        return .ready(try install(peer, options: options, until: deadline))
    }
}

func stdioIdentity(_ info: Implementation, profile: RevisionProfile) throws -> JSONValue {
    var writer = JSONWriter()
    info.encode(to: &writer, profile: profile)
    return try JSON.parseStrict(writer.bytes.span)
}

func stdioRequestParams(
    _ params: JSONObject, profile: RevisionProfile, clientIdentity: JSONValue?
) -> JSONObject {
    guard profile.era == .modern else { return params }
    var params = params
    var metadata = params["_meta"]?.objectValue ?? [:]
    metadata[MetaKey.protocolVersion] = .string(profile.version.rawValue)
    if let clientIdentity {
        metadata[MetaKey.clientInfo] = clientIdentity
        if metadata[MetaKey.clientCapabilities] == nil {
            metadata[MetaKey.clientCapabilities] = .object([:])
        }
    }
    params["_meta"] = .object(metadata)
    return params
}
#endif
