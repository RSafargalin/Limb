public import LimbCore
import Synchronization

/// Notifications to request from the server. The server can confirm a subset of this filter.
public struct ClientSubscriptionFilter: Sendable, Equatable {
    public var toolsListChanged: Bool
    public var promptsListChanged: Bool
    public var resourcesListChanged: Bool
    public var resourceSubscriptions: [String]

    public init(
        toolsListChanged: Bool = false, promptsListChanged: Bool = false,
        resourcesListChanged: Bool = false, resourceSubscriptions: [String] = []
    ) {
        self.toolsListChanged = toolsListChanged
        self.promptsListChanged = promptsListChanged
        self.resourcesListChanged = resourcesListChanged
        self.resourceSubscriptions = resourceSubscriptions
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.toolsListChanged == rhs.toolsListChanged && lhs.promptsListChanged == rhs.promptsListChanged
            && lhs.resourcesListChanged == rhs.resourcesListChanged
            && lhs.resourceSubscriptions.elementsEqual(rhs.resourceSubscriptions, by: { $0.isBytewiseEqual(to: $1) })
    }

    init(wire: JSONObject) throws(JSONDecodingError) {
        try self.init(
            toolsListChanged: wire.wireOptional("toolsListChanged") ?? false,
            promptsListChanged: wire.wireOptional("promptsListChanged") ?? false,
            resourcesListChanged: wire.wireOptional("resourcesListChanged") ?? false,
            resourceSubscriptions: wire.wireOptional("resourceSubscriptions") ?? [])
    }

    var wire: JSONObject {
        var filter: JSONObject = [:]
        if toolsListChanged { filter["toolsListChanged"] = true }
        if promptsListChanged { filter["promptsListChanged"] = true }
        if resourcesListChanged { filter["resourcesListChanged"] = true }
        if !resourceSubscriptions.isEmpty {
            filter["resourceSubscriptions"] = .array(resourceSubscriptions.map(JSONValue.string))
        }
        return filter
    }

    func contains(_ confirmed: Self) -> Bool {
        guard (!confirmed.toolsListChanged || toolsListChanged),
              (!confirmed.promptsListChanged || promptsListChanged),
              (!confirmed.resourcesListChanged || resourcesListChanged) else { return false }
        let uris = Set(resourceSubscriptions.map(ExactString.init))
        return confirmed.resourceSubscriptions.allSatisfy { uris.contains(ExactString($0)) }
    }

    func event(method: String, params: JSONObject) -> ClientSubscriptionEvent? {
        switch method {
        case "notifications/tools/list_changed" where toolsListChanged: .toolsListChanged
        case "notifications/prompts/list_changed" where promptsListChanged: .promptsListChanged
        case "notifications/resources/list_changed" where resourcesListChanged: .resourcesListChanged
        case "notifications/resources/updated" where !resourceSubscriptions.isEmpty:
            params["uri"]?.stringValue.map { .resourceUpdated(uri: $0) }
        default: nil
        }
    }
}

public enum ClientSubscriptionEvent: Sendable, Equatable {
    /// The stdio connection ended unexpectedly. Events may be missed before reconnection.
    case interrupted
    /// The subscription is active on a new process with this accepted filter.
    case resubscribed(confirmedFilter: ClientSubscriptionFilter)
    case toolsListChanged
    case promptsListChanged
    case resourcesListChanged
    /// The changed URI can be a child of a URI in the confirmed filter.
    case resourceUpdated(uri: String)
    /// A legacy update could affect this watched URI, but the peer did not identify its parent.
    case resourceInvalidated(uri: String)
}

public enum ClientSubscriptionError: Error, Sendable, Equatable {
    case incompatibleRevision(expected: ProtocolVersion, actual: ProtocolVersion)
    case unsupportedVersion(ProtocolVersion)
    case invalidOptions
    case alreadyIterating
    /// A legacy resource registration cannot be established in the current session.
    case legacyResourceStateUnknown(uri: String)
    /// The receiver fell behind. The buffered prefix is delivered before this error.
    case bufferOverflow
}

/// One acknowledged notification stream. Use a single iterator and call `cancel()` to
/// stop an early exit from iteration. Cancelling a waiting task also ends the subscription.
public final class ClientSubscription: AsyncSequence, Sendable {
    public typealias Element = ClientSubscriptionEvent
    typealias Stream = AsyncThrowingStream<Element, any Error>

    /// The initial accepted filter. Later confirmations are delivered as stream events.
    public let confirmedFilter: ClientSubscriptionFilter
    private let stream: Stream
    private let retirement: Task<Void, Never>
    private let stop: @Sendable () async -> Void
    private let iterating = Mutex(false)

    init(
        confirmedFilter: ClientSubscriptionFilter, stream: Stream, retirement: Task<Void, Never>,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.confirmedFilter = confirmedFilter
        self.stream = stream
        self.retirement = retirement
        self.stop = stop
    }

    public func cancel() async {
        await stop()
        await retirement.value
    }

    public func makeAsyncIterator() -> Iterator {
        let available = iterating.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
        return Iterator(owner: self, base: available ? stream.makeAsyncIterator() : nil)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let owner: ClientSubscription
        var base: Stream.Iterator?

        public mutating func next() async throws -> Element? {
            try await next(isolation: nil)
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Element? {
            guard var base else { throw ClientSubscriptionError.alreadyIterating }
            if Task.isCancelled {
                await owner.cancel()
                throw CancellationError()
            }
            let event: Element?
            do {
                event = try await base.next(isolation: actor)
            } catch {
                if Task.isCancelled {
                    await owner.cancel()
                    throw CancellationError()
                }
                await owner.retirement.value
                throw error
            }
            self.base = base
            if Task.isCancelled {
                await owner.cancel()
                throw CancellationError()
            }
            // Publish the terminal only after the adapter has cleared its send slot.
            if event == nil { await owner.retirement.value }
            return event
        }
    }

    deinit {
        let stop = self.stop
        Task { await stop() }
    }
}

package enum ClientSubscriptionWire {
    package static func cancellationID(_ params: JSONObject) -> RequestID? {
        if let reason = params["reason"], reason.stringValue == nil { return nil }
        guard let id = params["requestId"].flatMap(RequestID.init(json:)) else { return nil }
        if let value = params["_meta"] {
            guard let meta = value.objectValue else { return nil }
            if let subscriptionID = meta[MetaKey.subscriptionID], RequestID(json: subscriptionID) != id {
                return nil
            }
        }
        return id
    }
}
