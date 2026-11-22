/// An MCP specification revision, e.g. `2026-07-28`.
public struct ProtocolVersion: RawRepresentable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let v2025_03_26 = ProtocolVersion(rawValue: "2025-03-26")
    public static let v2025_06_18 = ProtocolVersion(rawValue: "2025-06-18")
    public static let v2025_11_25 = ProtocolVersion(rawValue: "2025-11-25")
    public static let v2026_07_28 = ProtocolVersion(rawValue: "2026-07-28")

    /// Every revision Limb implements, newest first.
    public static let all: [ProtocolVersion] = [.v2026_07_28, .v2025_11_25, .v2025_06_18, .v2025_03_26]
    public static let latest = ProtocolVersion.v2026_07_28
    /// The newest revision that negotiates through `initialize`.
    public static let latestLegacy = ProtocolVersion.v2025_11_25

    /// Revisions are dated, so they order lexically.
    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// How a peer conveys version, identity and capabilities.
public enum Era: Sendable, Hashable {
    /// `initialize` handshake establishes a session (`2025-11-25` and earlier).
    case legacy
    /// Every request carries its own metadata (`2026-07-28` and later).
    case modern
}

/// The capabilities and wire behavior associated with an MCP revision.
public struct RevisionProfile: Sendable, Hashable {
    public let version: ProtocolVersion
    public let era: Era

    // Lifecycle
    /// `initialize` / `notifications/initialized`. Modern revisions have no handshake.
    public let hasInitialize: Bool
    /// `server/discover`; mandatory in modern revisions.
    public let hasDiscover: Bool
    /// JSON-RPC batches: required by `2025-03-26`, removed afterwards.
    public let acceptsBatch: Bool
    public let hasPing: Bool

    // Result shape
    /// Every result carries `resultType`.
    public let resultTypeRequired: Bool
    /// Results identify the server in `_meta["io.modelcontextprotocol/serverInfo"]`.
    public let serverInfoInResults: Bool
    /// `ttlMs` and `cacheScope` on list, read and discover results.
    public let cacheHints: Bool

    // Server-to-client
    /// Sampling and roots as JSON-RPC requests from the server.
    public let serverInitiatedRequests: Bool
    /// `elicitation/create` as a JSON-RPC request from the server.
    public let elicitationRequests: Bool
    /// Additional input is requested with `InputRequiredResult` (multi round-trip requests).
    public let multiRoundTrip: Bool
    public let urlElicitation: Bool
    /// `notifications/elicitation/complete`, `elicitationId` and error `-32042`.
    public let elicitationCompletion: Bool
    /// `tools` and `toolChoice` in a sampling request, for a client that declares `sampling.tools`.
    public let samplingTools: Bool

    // Notifications and subscriptions
    public let hasLoggingSetLevel: Bool
    /// `resources/subscribe` and unsolicited `list_changed`; modern revisions use `subscriptions/listen`.
    public let legacySubscriptions: Bool
    public let hasSubscriptionsListen: Bool

    // Errors
    public let resourceNotFoundCode: Int
    /// Tool input validation failures are tool execution errors (`isError: true`), not `-32602` (SEP-1303).
    public let argumentErrorsAreToolErrors: Bool

    // Field availability
    /// `title`, `outputSchema`, `structuredContent`, `resource_link`, `_meta` on content.
    public let structuredOutput: Bool
    /// `structuredContent` may be any JSON value, not only an object.
    public let anyStructuredContent: Bool
    public let icons: Bool
    /// `description` and `websiteUrl` on `Implementation`.
    public let implementationDetails: Bool

    /// `lastModified` in annotations; it arrived in `2025-06-18` together with structured output.
    public var annotationLastModified: Bool { structuredOutput }

    public static let r2025_03_26 = RevisionProfile(
        version: .v2025_03_26, era: .legacy, hasInitialize: true, hasDiscover: false, acceptsBatch: true,
        hasPing: true, resultTypeRequired: false, serverInfoInResults: false, cacheHints: false,
        serverInitiatedRequests: true, elicitationRequests: false, multiRoundTrip: false,
        urlElicitation: false, elicitationCompletion: false, samplingTools: false, hasLoggingSetLevel: true,
        legacySubscriptions: true, hasSubscriptionsListen: false,
        resourceNotFoundCode: MCPError.Code.legacyResourceNotFound, argumentErrorsAreToolErrors: false,
        structuredOutput: false, anyStructuredContent: false, icons: false, implementationDetails: false)

    public static let r2025_06_18 = RevisionProfile(
        version: .v2025_06_18, era: .legacy, hasInitialize: true, hasDiscover: false, acceptsBatch: false,
        hasPing: true, resultTypeRequired: false, serverInfoInResults: false, cacheHints: false,
        serverInitiatedRequests: true, elicitationRequests: true, multiRoundTrip: false,
        urlElicitation: false, elicitationCompletion: false, samplingTools: false, hasLoggingSetLevel: true,
        legacySubscriptions: true, hasSubscriptionsListen: false,
        resourceNotFoundCode: MCPError.Code.legacyResourceNotFound, argumentErrorsAreToolErrors: false,
        structuredOutput: true, anyStructuredContent: false, icons: false, implementationDetails: false)

    public static let r2025_11_25 = RevisionProfile(
        version: .v2025_11_25, era: .legacy, hasInitialize: true, hasDiscover: false, acceptsBatch: false,
        hasPing: true, resultTypeRequired: false, serverInfoInResults: false, cacheHints: false,
        serverInitiatedRequests: true, elicitationRequests: true, multiRoundTrip: false,
        urlElicitation: true, elicitationCompletion: true, samplingTools: true, hasLoggingSetLevel: true,
        legacySubscriptions: true, hasSubscriptionsListen: false,
        resourceNotFoundCode: MCPError.Code.legacyResourceNotFound, argumentErrorsAreToolErrors: true,
        structuredOutput: true, anyStructuredContent: false, icons: true, implementationDetails: true)

    public static let r2026_07_28 = RevisionProfile(
        version: .v2026_07_28, era: .modern, hasInitialize: false, hasDiscover: true, acceptsBatch: false,
        hasPing: false, resultTypeRequired: true, serverInfoInResults: true, cacheHints: true,
        serverInitiatedRequests: false, elicitationRequests: false, multiRoundTrip: true,
        urlElicitation: true, elicitationCompletion: false, samplingTools: true, hasLoggingSetLevel: false,
        legacySubscriptions: false, hasSubscriptionsListen: true,
        resourceNotFoundCode: MCPError.Code.invalidParams, argumentErrorsAreToolErrors: true,
        structuredOutput: true, anyStructuredContent: true, icons: true, implementationDetails: true)

    /// All profiles, newest first.
    public static let all: [RevisionProfile] = [.r2026_07_28, .r2025_11_25, .r2025_06_18, .r2025_03_26]

    /// The profile for a revision Limb implements; `nil` otherwise.
    public static func profile(for version: ProtocolVersion) -> RevisionProfile? {
        all.first { $0.version == version }
    }

    /// Index into per-profile caches.
    public var index: Int {
        switch version {
        case .v2026_07_28: 0
        case .v2025_11_25: 1
        case .v2025_06_18: 2
        default: 3
        }
    }
}

/// Reserved `_meta` keys.
public enum MetaKey {
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let logLevel = "io.modelcontextprotocol/logLevel"
    public static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    public static let progressToken = "progressToken"
}
