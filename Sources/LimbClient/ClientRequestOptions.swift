public import LimbCore
import Dispatch

public struct ClientRequestOptions: Sendable {
    /// The overall budget for the operation, including queuing, input handlers and result decoding.
    public var timeout: Duration
    var absoluteDeadline: ContinuousClock.Instant?
    var workPermit: ClientWorkPermit?
    /// Requests MCP logging for this modern exchange. For a legacy session use `Client.setLogLevel`.
    public var logLevel: LoggingLevel?
    /// Progress arrives in order, from a bounded buffer on a separate task. A slow callback
    /// may miss intermediate updates. Its slot remains occupied until the callback returns,
    /// even if the operation already ended.
    public var onProgress: (@Sendable (ClientProgress) -> Void)?

    public init(
        timeout: Duration = .seconds(60), logLevel: LoggingLevel? = nil,
        onProgress: (@Sendable (ClientProgress) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.logLevel = logLevel
        self.onProgress = onProgress
    }

    var timed: Self {
        guard absoluteDeadline == nil else { return self }
        var options = self
        options.absoluteDeadline = .now + timeout
        return options
    }

    var deadline: ContinuousClock.Instant {
        // Operation entry points set the deadline once, before starting the work.
        absoluteDeadline ?? .now + timeout
    }
}

public struct ClientProgress: Sendable, Equatable {
    public let progress: Double
    public let total: Double?
    public let message: String?
}

public struct ClientLogMessage: Sendable, Equatable {
    public let level: LoggingLevel
    public let logger: String?
    public let data: JSONValue
    public let metadata: JSONObject?

    init(_ params: JSONObject) throws(JSONDecodingError) {
        let level: String = try params.required("level")
        guard let known = LoggingLevel(rawValue: level) else {
            throw JSONDecodingError("unknown log level", path: ["level"])
        }
        self.level = known
        logger = try params.wireOptional("logger")
        data = try params.required("data")
        metadata = try params.wireOptional("_meta")
    }
}

struct ClientProgressDelivery: Sendable {
    let continuation: AsyncStream<ClientProgress>.Continuation
    private let task: Task<Void, Never>

    init?(_ callback: @escaping @Sendable (ClientProgress) -> Void, quota: ClientWorkQuota) {
        guard quota.reserve() else { return nil }
        let (stream, continuation) = AsyncStream<ClientProgress>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.continuation = continuation
        task = Task.detached {
            defer { quota.release() }
            for await progress in stream {
                guard !Task.isCancelled else { break }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        callback(progress)
                        done.resume()
                    }
                }
            }
        }
    }

    func finish(discardPending: Bool) {
        if discardPending { task.cancel() }
        continuation.finish()
    }
}
