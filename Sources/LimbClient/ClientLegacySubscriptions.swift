import LimbCore

/// Legacy resource registrations belong to the session. Each caller owns a local lease.
/// The client actor processes wire replies and notifications against this state in frame order.
struct ClientLegacySubscriptions {
    enum Operation: String {
        case subscribe = "resources/subscribe"
        case unsubscribe = "resources/unsubscribe"
    }

    enum Registration {
        case unregistered
        case registered
        /// An attempted release never reached the peer. The confirmed registration can still be shared.
        case retained
        case transitioning(Operation, RequestID)
        case unknown
    }

    struct Resource {
        var registration: Registration = .unregistered
        var owners: Set<UInt64> = []

        var needsRetirement: Bool {
            switch registration {
            case .transitioning(.unsubscribe, _): true
            case .registered, .transitioning(.subscribe, _): owners.isEmpty
            case .unknown, .unregistered, .retained: false
            }
        }
    }

    struct Transition {
        let key: ExactString
        let operation: Operation
        let timer: Task<Void, Never>?
        var settled = false
    }

    struct Opened: Sendable {
        let handle: ClientSubscription
        let delivery: ClientDelivery
    }

    struct Opening {
        let stream: ClientSubscription.Stream
        let continuation: CheckedContinuation<Opened, any Error>
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
        var delivery: ClientDelivery = .notSent
        var errors: [ExactString: any Error] = [:]
    }

    struct Lease {
        let keys: [ExactString]
        let events: ClientSubscription.Stream.Continuation
        let retired: AsyncStream<Void>.Continuation
        let retirement: Task<Void, Never>
        let filter: ClientSubscriptionFilter
        var opening: Opening?
        var awaiting: Set<ExactString>
        var confirmed: Set<ExactString> = []
    }

    struct Release {
        var keys: Set<ExactString>
        let retired: AsyncStream<Void>.Continuation
    }

    var lastLeaseID: UInt64 = 0
    var leases: [UInt64: Lease] = [:]
    var releases: [UInt64: Release] = [:]
    var transitions: [RequestID: Transition] = [:]
    var retiring: [ExactString: RequestID] = [:]
    var resources: [ExactString: Resource] = [:]
    var order: [ExactString] = []
    private var resourceBytes = 0

    static func filter(_ requested: ClientSubscriptionFilter, capabilities: JSONObject?) -> ClientSubscriptionFilter {
        ClientSubscriptionFilter(
            toolsListChanged: requested.toolsListChanged && capabilities?["tools"]?["listChanged"]?.boolValue == true,
            promptsListChanged: requested.promptsListChanged && capabilities?["prompts"]?["listChanged"]?.boolValue == true,
            resourcesListChanged: requested.resourcesListChanged && capabilities?["resources"]?["listChanged"]?.boolValue == true)
    }

    static func hasValidMetadata(_ fields: JSONObject) -> Bool {
        guard let metadata = fields["_meta"] else { return true }
        return metadata.objectValue != nil
    }

    mutating func addOwner(_ owner: UInt64, keys: [ExactString]) {
        for key in keys {
            if resources[key] == nil {
                order.append(key)
                resourceBytes += key.text.utf8.count
                resources[key] = Resource()
            }
            if case .retained = resources[key]?.registration { resources[key]?.registration = .registered }
            resources[key]?.owners.insert(owner)
        }
    }

    func admittedKeys(_ uris: [String]) throws(ClientError) -> [ExactString] {
        var distinct: Set<ExactString> = []
        var keys: [ExactString] = []
        var count = resources.count
        var bytes = resourceBytes
        // Include unknown registrations in the budget for this session.
        for uri in uris {
            let key = ExactString(uri)
            guard distinct.insert(key).inserted else { continue }
            if resources[key] == nil {
                guard count < 1_024, uri.utf8.count <= (1 << 20) - bytes else { throw .overloaded }
                count += 1
                bytes += uri.utf8.count
            }
            keys.append(key)
        }
        return keys
    }

    mutating func discardIfUnowned(_ key: ExactString) {
        guard let resource = resources[key], case .unregistered = resource.registration, resource.owners.isEmpty else { return }
        resources.removeValue(forKey: key)
        order.removeAll { $0 == key }
        resourceBytes -= key.text.utf8.count
    }

    func nextTransition(canSubscribe: Bool, canUnsubscribe: Bool) -> (ExactString, Operation)? {
        // Send last-owner releases ahead of new registrations.
        if canUnsubscribe {
            for key in order {
                if retiring[key] == nil, let resource = resources[key],
                   case .registered = resource.registration, resource.owners.isEmpty {
                    return (key, .unsubscribe)
                }
            }
        }
        guard canSubscribe else { return nil }
        for key in order {
            if retiring[key] == nil, let resource = resources[key],
               case .unregistered = resource.registration, !resource.owners.isEmpty {
                return (key, .subscribe)
            }
        }
        return nil
    }
}
