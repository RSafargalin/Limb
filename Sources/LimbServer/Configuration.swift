public import LimbCore

/// Resource budgets. They are on by default: overload must produce a clear error, not unbounded
/// memory or an endless wait.
public struct ServerBudgets: Sendable {
    /// Handlers running at once; further requests wait in the admission queue.
    public var maxConcurrentHandlers: Int
    /// Requests waiting for a handler slot, by count and by total frame bytes. A connection whose
    /// peer is behind on reading has the same limits to itself, apart from everyone else.
    public var maxQueuedRequests: Int
    public var maxQueuedBytes: Int
    /// Largest incoming frame.
    public var maxFrameBytes: Int
    /// Largest outgoing response. A successful result is never truncated; exceeding this is an error.
    ///
    /// A `2025-03-26` batch reply is held to it as a whole: its largest members are replaced by
    /// that error. When even that cannot make it fit, every member gets the error under its own
    /// id, and the reply may then exceed a very small limit — it is bounded by the ids the
    /// client sent (see `maxRequestIDBytes`) and a constant per member.
    public var maxResponseBytes: Int
    /// Largest JSON-RPC batch (`2025-03-26` only).
    public var maxBatchItems: Int
    /// Bytes waiting to be written before handlers feel backpressure.
    public var maxOutboundBytes: Int
    /// Concurrent `subscriptions/listen` streams per connection.
    public var maxSubscriptions: Int
    /// Resource URIs one connection may be subscribed to at once, by count and by total bytes:
    /// `resources/subscribe` in a session, and `resourceSubscriptions` across all its
    /// `subscriptions/listen` streams. A subscription beyond them is refused.
    public var maxSubscribedResources: Int
    public var maxSubscribedResourceBytes: Int
    /// Entries in a request's `inputResponses` (`2026-07-28`). A handler asks for a handful;
    /// a request with more is refused with `-32602`.
    public var maxInputResponses: Int
    /// Longest request id, in bytes of its text. Every answer echoes the id, so this is what
    /// keeps every error small; a request with a longer id is refused with `-32600` and a null
    /// id. Keep it well below a sixteenth of the transport's urgent reserve.
    public var maxRequestIDBytes: Int

    public init(
        maxConcurrentHandlers: Int, maxQueuedRequests: Int, maxQueuedBytes: Int, maxFrameBytes: Int,
        maxResponseBytes: Int, maxBatchItems: Int, maxOutboundBytes: Int, maxSubscriptions: Int,
        maxSubscribedResources: Int = 10_000, maxSubscribedResourceBytes: Int = 1 << 20, maxInputResponses: Int = 64,
        maxRequestIDBytes: Int = 8 * 1024
    ) {
        self.maxConcurrentHandlers = maxConcurrentHandlers
        self.maxQueuedRequests = maxQueuedRequests
        self.maxQueuedBytes = maxQueuedBytes
        self.maxFrameBytes = maxFrameBytes
        self.maxResponseBytes = maxResponseBytes
        self.maxBatchItems = maxBatchItems
        self.maxOutboundBytes = maxOutboundBytes
        self.maxSubscriptions = maxSubscriptions
        self.maxSubscribedResources = maxSubscribedResources
        self.maxSubscribedResourceBytes = maxSubscribedResourceBytes
        self.maxInputResponses = maxInputResponses
        self.maxRequestIDBytes = maxRequestIDBytes
    }

    /// One trusted local client over stdio.
    public static let local = ServerBudgets(
        maxConcurrentHandlers: 32, maxQueuedRequests: 64, maxQueuedBytes: 64 << 20, maxFrameBytes: 16 << 20,
        maxResponseBytes: 16 << 20, maxBatchItems: 64, maxOutboundBytes: 64 << 20, maxSubscriptions: 16)

    /// Many untrusted clients over a network transport.
    public static let network = ServerBudgets(
        maxConcurrentHandlers: 64, maxQueuedRequests: 256, maxQueuedBytes: 128 << 20, maxFrameBytes: 4 << 20,
        maxResponseBytes: 16 << 20, maxBatchItems: 32, maxOutboundBytes: 32 << 20, maxSubscriptions: 16)
}

/// How handlers are scheduled.
public enum ExecutionMode: Sendable {
    /// Up to `maxConcurrentHandlers` at once.
    case concurrent
    /// One at a time, in arrival order: for code that is not safe to run concurrently.
    /// Cancellation, discovery and listings still answer immediately.
    case serial
}

/// Who may cache a result (`cacheScope`, `2026-07-28`).
public enum CacheScope: String, Sendable {
    case `public`
    case `private`
}

/// Freshness hints attached to cacheable results in revisions that define them.
public struct CachePolicy: Sendable {
    /// How long, in milliseconds, a client may treat the result as fresh. 0 means "always re-fetch".
    /// Never negative: a negative value is stored as 0.
    public var ttlMilliseconds: Int {
        didSet { if ttlMilliseconds < 0 { ttlMilliseconds = 0 } }
    }
    public var scope: CacheScope

    public init(ttlMilliseconds: Int, scope: CacheScope) {
        self.ttlMilliseconds = max(0, ttlMilliseconds)
        self.scope = scope
    }
}

public struct ServerConfiguration: Sendable {
    public var info: Implementation
    /// Guidance for the model on how to use this server.
    public var instructions: String?
    /// Revisions this server speaks. Defaults to all four; drop the legacy ones for a modern-only server.
    public var supportedVersions: [ProtocolVersion] = ProtocolVersion.all
    /// `.local` unless set, for every connection: also for one a custom transport opens with
    /// `Server.connect(to:)`. A transport that serves untrusted peers should set `.network`.
    public var budgets: ServerBudgets = .local
    public var execution: ExecutionMode = .concurrent
    /// Cache hints for `server/discover` and the list operations.
    public var listCache = CachePolicy(ttlMilliseconds: 0, scope: .public)
    /// Default cache hints for `resources/read`; a resource can override them.
    public var resourceCache = CachePolicy(ttlMilliseconds: 0, scope: .private)
    /// Items per page of a list result; `nil` returns everything in one page.
    public var pageSize: Int?
    public var parseOptions = JSONParseOptions()
    /// How long `requestState` stays valid. Elicitation waits for a person, hence minutes.
    public var requestStateLifetimeSeconds = 900
    /// The most a `requestState` may hold before sealing. Answers from earlier rounds travel in
    /// it, so this bounds what one request can make the client carry back and forth.
    public var maxRequestStateBytes = 1 << 20
    /// Protects `requestState`. `nil` uses a random key that lives as long as the process, which
    /// is right for stdio; a server behind a load balancer must supply a shared key.
    public var requestStateSealer: (any RequestStateSealer)?
    /// How long a request to the client (`elicitation/create`, `sampling/createMessage`,
    /// `roots/list` in revisions before `2026-07-28`) may go unanswered. Then it is withdrawn
    /// with `notifications/cancelled`, and the handler's call throws `MCPError.requestTimedOut`.
    /// Elicitation waits for a person, hence minutes. Zero, negative values and NaN disable
    /// requests to the client: nothing is sent, and the call throws `requestTimedOut` at once.
    /// `.infinity` waits as long as it takes. The handler keeps its slot while it waits.
    public var clientRequestTimeoutSeconds: Double = 900
    /// After the input closes: how long in-flight requests may finish before they are cancelled.
    /// Zero, negative values and NaN cancel them at once; `.infinity` waits as long as they take.
    /// A peer found to be gone ends the wait early.
    public var shutdownGraceSeconds: Double = 5
    /// After the input ended and handlers are done: how long the writer may write nothing before
    /// the peer is given up on. A peer that keeps its end open without reading must not keep the
    /// server alive; one that takes at least a kilobyte per this interval is still reading.
    /// That is approximate where room appears in larger steps: on Linux a pipe frees space a
    /// 4 KiB page at a time, so a peer reading less than that per interval may be given up on.
    /// Zero, negative values and NaN do not wait for a peer that is not reading; `.infinity`
    /// waits as long as it takes.
    public var outputDrainSeconds: Double = 5
    /// Receives diagnostics that must not go to the protocol stream. Defaults to stderr.
    ///
    /// It may be called on a connection's reader and from handler tasks, never with a lock
    /// held. It should return quickly: while it runs, that connection reads nothing. Text a peer
    /// sent reaches it escaped and shortened, and a connection reports each kind of peer
    /// misbehaviour a limited number of times.
    public var diagnostics: @Sendable (String) -> Void = ServerConfiguration.standardErrorDiagnostics

    public init(info: Implementation) {
        self.info = info
    }

    var handlerLimit: Int { execution == .serial ? 1 : max(1, budgets.maxConcurrentHandlers) }
    var legacyVersions: [ProtocolVersion] {
        supportedVersions.filter { RevisionProfile.profile(for: $0)?.hasInitialize == true }
    }
}
