public import LimbCore

/// The peer and protocol details for one request for input.
public struct ClientInputContext: Sendable {
    public let protocolVersion: ProtocolVersion
    /// The locally configured identity of the endpoint. For stdio this is the executable path.
    public let serverIdentity: String?
    /// The server's self-reported implementation details from protocol negotiation.
    public let serverInfo: Implementation?
    public let method: String
    /// The original wire ID of a standalone legacy request.
    public let legacyRequestID: RequestID?
    /// The MRTR input key or the textual representation of a legacy request ID.
    public let requestKey: String
    /// The first MRTR response and a standalone legacy request both use round 1.
    public let round: Int
    /// The deadline of the original MRTR operation or the legacy request.
    public let deadline: ContinuousClock.Instant
}

/// Input provided by the host application. Legacy peers negotiate supported handlers during
/// initialization. Modern clients advertise them per operation. Handlers can run concurrently.
public struct ClientInputHandlers: Sendable {
    /// Present the server identity and let the user review, edit, decline or dismiss the form.
    public var elicitForm: (@Sendable (ElicitRequest, ClientInputContext) async throws -> ElicitResult)?
    /// Show the full URL and obtain user consent before opening it in an isolated browser context.
    /// An accepted answer records consent. The application chooses when its interaction is ready to resume.
    /// Return only an action, with no form content.
    public var elicitURL: (@Sendable (ElicitRequest, ClientInputContext) async throws -> ElicitResult)?
    /// Provide basic sampling subject to the host's permissions and requested token limit.
    /// Sampling is deprecated in MCP 2026-07-28.
    public var sample: (@Sendable (SamplingRequest, ClientInputContext) async throws -> SamplingResult)?
    /// Return file roots the host has authorized the peer to see. Roots are deprecated in MCP 2026-07-28.
    public var roots: (@Sendable (ClientInputContext) async throws -> [Root])?
    /// The maximum number of input-required responses acted on per operation, including state-only rounds.
    public var maxInputRounds: Int
    /// The maximum number of requests accepted in one input-required response.
    public var maxInputsPerRound: Int

    public init(
        elicitForm: (@Sendable (ElicitRequest, ClientInputContext) async throws -> ElicitResult)? = nil,
        elicitURL: (@Sendable (ElicitRequest, ClientInputContext) async throws -> ElicitResult)? = nil,
        sample: (@Sendable (SamplingRequest, ClientInputContext) async throws -> SamplingResult)? = nil,
        roots: (@Sendable (ClientInputContext) async throws -> [Root])? = nil,
        maxInputRounds: Int = 10, maxInputsPerRound: Int = 16
    ) {
        self.elicitForm = elicitForm
        self.elicitURL = elicitURL
        self.sample = sample
        self.roots = roots
        self.maxInputRounds = maxInputRounds
        self.maxInputsPerRound = maxInputsPerRound
    }

    package var hasValidLimits: Bool { maxInputRounds > 0 && maxInputsPerRound > 0 }

    package func legacyCapabilities(offer: RevisionProfile, pinned: Bool) -> JSONObject {
        var result = capabilities
        if !offer.elicitationRequests || (!pinned && elicitForm == nil) {
            result["elicitation"] = nil
        } else if !offer.urlElicitation {
            result["elicitation"] = elicitForm == nil ? nil : [:]
        }
        return result
    }

    var capabilities: JSONObject {
        var capabilities: JSONObject = [:]
        var modes: JSONObject = [:]
        if elicitForm != nil { modes["form"] = [:] }
        if elicitURL != nil { modes["url"] = [:] }
        if !modes.isEmpty { capabilities["elicitation"] = .object(modes) }
        if sample != nil { capabilities["sampling"] = [:] }
        if roots != nil { capabilities["roots"] = [:] }
        return capabilities
    }
}

/// An operation that has already received a request for input could not continue.
/// Handler errors are propagated separately.
public enum ClientInputError: Error, Equatable, Sendable {
    case roundLimitExceeded(limit: Int)
    case inputLimitExceeded(round: Int, limit: Int)
    case unsupportedMethod(round: Int, key: String, method: String)
    case unavailableHandler(round: Int, key: String, method: String)
    case invalidResponse(round: Int, key: String)
    /// A continuation failed locally. The original operation had already reached the peer.
    case continuationFailed(ClientError)
    /// The legacy session reached its URL elicitation tracking budget. The original peer
    /// error still contains the required elicitations.
    case urlElicitationTrackingOverloaded(original: MCPError)
}
