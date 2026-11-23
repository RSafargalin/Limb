public import LimbCore
import Synchronization

/// An MCP server: a registry of tools, resources and prompts, and the protocol engine that
/// serves them to any number of connections.
///
/// The engine is stateless at its core, as `2026-07-28` requires: a request carries its own
/// version and capabilities. The `initialize` handshake of earlier revisions is an adapter kept
/// per connection. One process can serve both kinds of client at once.
/// Modern discovery keeps a list capability after its first successful registration, even if
/// the list becomes empty. A legacy connection uses the capabilities advertised at initialize.
///
/// ```swift
/// let server = Server(name: "weather", version: "1.0.0")
/// try server.register(tool: ToolDefinition(name: "echo", inputSchema: [
///     "type": "object", "properties": ["text": ["type": "string"]], "required": ["text"],
/// ])) { arguments, _ in
///     .text(arguments["text"]?.stringValue ?? "")
/// }
/// ```
public final class Server: Sendable {
    public let configuration: ServerConfiguration
    let sealer: any RequestStateSealer
    private let registry: Mutex<RegistrySnapshot>
    private let connections = Mutex(ConnectionTable())
    /// `{"io.modelcontextprotocol/serverInfo":{…}}` members, ready to splice into a result's `_meta`.
    let serverInfoMember: [UInt8]

    public init(configuration: ServerConfiguration) {
        let configuration = configuration.normalized()
        self.configuration = configuration
        sealer = configuration.requestStateSealer ?? AEADRequestStateSealer.ephemeral()
        registry = Mutex(RegistrySnapshot())
        var writer = JSONWriter()
        writer.field(MetaKey.serverInfo, configuration.info, .r2026_07_28)
        serverInfoMember = writer.bytes
        // The server's own data: said once here rather than only at every failing request.
        let ownBytes = (configuration.instructions?.utf8.count ?? 0) + serverInfoMember.count
        if ownBytes > configuration.budgets.maxResponseBytes {
            configuration.diagnostics(
                "the instructions and server info (\(ownBytes) bytes) exceed maxResponseBytes "
                    + "(\(configuration.budgets.maxResponseBytes)): initialize and server/discover will fail")
        }
    }

    public convenience init(
        name: String, version: String, title: String? = nil, instructions: String? = nil,
        configure: (inout ServerConfiguration) -> Void = { _ in }
    ) {
        var configuration = ServerConfiguration(info: Implementation(name: name, title: title, version: version))
        configuration.instructions = instructions
        configure(&configuration)
        self.init(configuration: configuration)
    }

    var snapshot: RegistrySnapshot { registry.withLock { $0 } }

    /// The snapshot a change replaces is handed back and released here, after unlocking: if it
    /// was the last reference, user closures are destroyed with it, and a `deinit` that touches
    /// the registry must not find it locked.
    private func mutate(_ change: ListKind, _ body: (inout RegistryContents) throws(RegistrationError) -> Void) throws(RegistrationError) {
        var failure: RegistrationError?
        let replaced: RegistrySnapshot? = registry.withLock { current in
            var contents = current.contents
            do throws(RegistrationError) {
                try body(&contents)
                contents.modernListCapabilities.insert(change.capability)
                defer { current = RegistrySnapshot(contents) }
                return current
            } catch {
                failure = error
                return nil
            }
        }
        withExtendedLifetime(replaced) {}
        if let failure { throw failure }
        broadcast(.listChanged(change))
    }

    // MARK: Tools

    /// Registers a tool. Its schemas are compiled now, so a schema Limb cannot enforce is an
    /// error here rather than an unchecked call later.
    public func register(tool definition: ToolDefinition, handler: @escaping ToolHandler) throws(RegistrationError) {
        guard Server.isValidToolName(definition.name) else {
            throw RegistrationError(
                reason: "tool name \"\(definition.name)\" must be 1–128 characters of A–Z, a–z, 0–9, '_', '-' and '.'")
        }
        guard definition.inputSchema["type"] == "object" else {
            throw RegistrationError(reason: "tool \"\(definition.name)\": inputSchema must have \"type\": \"object\"")
        }
        let input: JSONSchema
        var output: JSONSchema?
        do {
            input = try JSONSchema(.object(definition.inputSchema), registeredSchemas: configuration.schemaResources)
            if let outputSchema = definition.outputSchema {
                output = try JSONSchema(.object(outputSchema), registeredSchemas: configuration.schemaResources)
            }
        } catch {
            throw RegistrationError(reason: "tool \"\(definition.name)\": \(error)")
        }
        let entry = ToolEntry(definition: definition, input: input, output: output, handler: handler)
        try mutate(.tools) { contents throws(RegistrationError) in
            guard contents.toolIndex[ExactString(definition.name)] == nil else {
                throw RegistrationError(reason: "a tool named \"\(definition.name)\" is already registered")
            }
            contents.toolIndex[ExactString(definition.name)] = contents.tools.count
            contents.tools.append(entry)
        }
    }

    public func register<T: MCPTool>(_ tool: T) throws(RegistrationError) {
        try register(tool: T.definition) { arguments, context in
            try await tool.call(arguments: arguments, context: context)
        }
    }

    public func removeTool(named name: String) {
        remove(.tools) { contents in
            guard let index = contents.toolIndex[ExactString(name)] else { return false }
            contents.tools.remove(at: index)
            contents.reindex()
            return true
        }
    }

    /// Applies a removal and announces it — but only if something was there to remove.
    private func remove(_ change: ListKind, _ body: (inout RegistryContents) -> Bool) {
        // Released after unlocking, as in `mutate`.
        let replaced: RegistrySnapshot? = registry.withLock { current in
            var contents = current.contents
            guard body(&contents) else { return nil }
            defer { current = RegistrySnapshot(contents) }
            return current
        }
        guard replaced != nil else { return }
        broadcast(.listChanged(change))
    }

    static func isValidToolName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x5F || byte == 0x2D || byte == 0x2E
        }
    }

    // MARK: Resources

    /// Registers a fixed resource.
    public func register(
        resource definition: ResourceDefinition, cache: CachePolicy? = nil, read: @escaping ResourceReader
    ) throws(RegistrationError) {
        let entry = ResourceEntry(definition: definition, cache: cache, read: read)
        try mutate(.resources) { contents throws(RegistrationError) in
            guard contents.resourceIndex[ExactString(definition.uri)] == nil else {
                throw RegistrationError(reason: "a resource with URI \"\(definition.uri)\" is already registered")
            }
            contents.resourceIndex[ExactString(definition.uri)] = contents.resources.count
            contents.resources.append(entry)
        }
    }

    /// Registers a family of resources addressed by a URI template such as `file:///{path}`.
    ///
    /// Limb supports `{name}` and `{+name}`, with dotted names (`{user.id}`). Repeated variables
    /// and templates over 4 KiB are refused. Reverse matching prefers the longest nonempty
    /// captures and falls back to empty captures when necessary. A simple variable cannot
    /// consume a raw slash. Both operators decode percent-encoded values. Matching URIs up to
    /// 64 KiB uses a shared budget of four million byte comparisons and matching-table steps
    /// for all candidates in a single request.
    public func register(
        resourceTemplate definition: ResourceTemplateDefinition, cache: CachePolicy? = nil,
        complete: CompletionHandler? = nil, read: @escaping ResourceReader
    ) throws(RegistrationError) {
        guard let template = URITemplate(definition.uriTemplate) else {
            throw RegistrationError(reason: "unsupported URI template \"\(definition.uriTemplate)\"")
        }
        let entry = TemplateEntry(definition: definition, template: template, cache: cache, complete: complete, read: read)
        try mutate(.templates) { contents throws(RegistrationError) in
            guard !contents.templates.contains(where: { $0.definition.uriTemplate.isBytewiseEqual(to: definition.uriTemplate) }) else {
                throw RegistrationError(reason: "the template \"\(definition.uriTemplate)\" is already registered")
            }
            contents.templates.append(entry)
        }
    }

    public func removeResource(uri: String) {
        remove(.resources) { contents in
            guard let index = contents.resourceIndex[ExactString(uri)] else { return false }
            contents.resources.remove(at: index)
            contents.reindex()
            return true
        }
    }

    /// Tells subscribed clients that a resource's contents changed.
    public func notifyResourceUpdated(uri: String) {
        broadcast(.resourceUpdated(uri))
    }

    // MARK: Prompts

    public func register(
        prompt definition: PromptDefinition, complete: CompletionHandler? = nil, handler: @escaping PromptHandler
    ) throws(RegistrationError) {
        guard Set(definition.arguments.map(\.name)).count == definition.arguments.count else {
            throw RegistrationError(reason: "prompt \"\(definition.name)\" declares duplicate or canonically equivalent argument names")
        }
        let entry = PromptEntry(definition: definition, complete: complete, handler: handler)
        try mutate(.prompts) { contents throws(RegistrationError) in
            guard contents.promptIndex[ExactString(definition.name)] == nil else {
                throw RegistrationError(reason: "a prompt named \"\(definition.name)\" is already registered")
            }
            contents.promptIndex[ExactString(definition.name)] = contents.prompts.count
            contents.prompts.append(entry)
        }
    }

    public func removePrompt(named name: String) {
        remove(.prompts) { contents in
            guard let index = contents.promptIndex[ExactString(name)] else { return false }
            contents.prompts.remove(at: index)
            contents.reindex()
            return true
        }
    }

    // MARK: Escape hatch

    /// Handles a method the typed API does not cover. Protocol methods cannot be overridden.
    public func register(method: String, handler: @escaping MethodHandler) throws(RegistrationError) {
        guard !Connection.builtinMethods.contains(method) else {
            throw RegistrationError(reason: "\"\(method)\" is a protocol method and cannot be overridden")
        }
        // The replaced snapshot is released after unlocking, as in `mutate`.
        let replaced: RegistrySnapshot? = registry.withLock { current in
            var contents = current.contents
            guard contents.methods[ExactString(method)] == nil else { return nil }
            contents.methods[ExactString(method)] = handler
            defer { current = RegistrySnapshot(contents) }
            return current
        }
        // The same rule as for tools, prompts and resources: a name is registered once.
        guard replaced != nil else { throw RegistrationError(reason: "a method named \"\(method)\" is already registered") }
    }

    // MARK: Connections

    /// Creates the protocol engine for one connection. Transports call this; `sink` receives
    /// every outgoing frame.
    public func connect(to sink: any FrameSink) -> Connection {
        connect(to: sink, authenticatedPrincipal: nil)
    }

    /// Connects a transport that has already authenticated a principal. The transport supplies
    /// its stable principal identifier for the lifetime of the connection. Multi-round request
    /// state is then bound to that principal across reconnections and workers using the same key.
    public func connect(to sink: any FrameSink, authenticatedPrincipal: String?) -> Connection {
        let connection = Connection(server: self, sink: sink, authenticatedPrincipal: authenticatedPrincipal)
        connections.withLock { $0.insert(connection) }
        return connection
    }

    func forget(_ connection: Connection) {
        _ = connections.withLock { $0.entries.removeValue(forKey: ObjectIdentifier(connection)) }
        gateForget(owner: ObjectIdentifier(connection))
    }

    private func broadcast(_ event: ServerEvent) {
        let live = connections.withLock { table in
            table.prune()
            return table.entries.values.compactMap(\.connection)
        }
        for connection in live { connection.deliver(event) }
    }

    // MARK: Admission

    /// A request waiting for a handler slot.
    struct GateEntry: Sendable {
        let owner: ObjectIdentifier
        /// Increases with every request of `owner`: a connection's requests come from a single
        /// reader, so they reach the gate in this order.
        let serial: UInt64
        let bytes: Int
        /// Tries to start the handler. Called with the gate locked; it takes the connection's lock.
        let start: @Sendable () -> StartOutcome
        /// Whether `owner`'s peer is behind on reading: its output is over budget. Called with
        /// the gate locked.
        let peerIsBehind: @Sendable () -> Bool
    }

    enum StartOutcome {
        case started
        /// The request was cancelled while it waited. It leaves the queue.
        case gone
        /// Its connection has no free place right now (see `Connection.admit`). It keeps its
        /// position in the queue and is tried again when a place frees.
        case busy
    }

    enum GateDecision { case started, queued, gone, overloaded }

    /// The requests of one connection that wait at the gate, oldest first.
    ///
    /// A withdrawn request is only marked and skipped later: rebuilding the queue on every
    /// cancellation would make cancelling a long backlog quadratic, under the server-wide lock.
    private struct OwnerQueue {
        /// A request, or the tombstone of one that left. A tombstone keeps only what the binary
        /// search needs: the entry, whose closure holds the request's parsed payload, goes as
        /// soon as the request is withdrawn or taken.
        private struct Item {
            let serial: UInt64
            let sequence: UInt64
            var entry: GateEntry?
        }

        /// Sorted by serial, which is what lets a withdrawal find its request by binary search.
        private var items: [Item] = []
        /// Index of the oldest request still waiting; everything before it has left. Never
        /// points at a tombstone.
        private var head = 0
        /// Tombstones at or after `head`.
        private var withdrawnCount = 0
        private(set) var count = 0
        private(set) var bytes = 0
        let peerIsBehind: @Sendable () -> Bool

        init(peerIsBehind: @escaping @Sendable () -> Bool) { self.peerIsBehind = peerIsBehind }

        var isEmpty: Bool { count == 0 }
        var first: (entry: GateEntry, sequence: UInt64)? { isEmpty ? nil : (items[head].entry!, items[head].sequence) }

        mutating func append(_ entry: GateEntry, sequence: UInt64) {
            items.append(Item(serial: entry.serial, sequence: sequence, entry: entry))
            count += 1
            bytes += entry.bytes
        }

        mutating func removeFirst() {
            count -= 1
            bytes -= items[head].entry!.bytes
            items[head].entry = nil
            head += 1
            skipWithdrawn()
        }

        mutating func remove(serials: Set<UInt64>) {
            for serial in serials {
                var low = head
                var high = items.count
                while low < high {
                    let middle = (low + high) / 2
                    if items[middle].serial < serial { low = middle + 1 } else { high = middle }
                }
                guard low < items.count, items[low].serial == serial, let entry = items[low].entry else { continue }
                items[low].entry = nil
                withdrawnCount += 1
                count -= 1
                bytes -= entry.bytes
            }
            skipWithdrawn()
        }

        private mutating func skipWithdrawn() {
            while head < items.count, items[head].entry == nil {
                head += 1
                withdrawnCount -= 1
            }
            // Compact now and then, so that tombstones cost little on average.
            let dead = head + withdrawnCount
            if dead >= 64, dead * 2 >= items.count {
                items = items[head...].filter { $0.entry != nil }
                head = 0
                withdrawnCount = 0
            }
        }
    }

    private struct Gate {
        var running = 0
        var queues: [ObjectIdentifier: OwnerQueue] = [:]
        /// Connections known to have no free place. Their requests are passed over without
        /// asking again until the connection reports a place.
        var saturated: Set<ObjectIdentifier> = []
        var nextSequence: UInt64 = 0
    }

    /// One gate for the whole server, not one per connection: the limit on concurrent handlers
    /// protects the process, and `.serial` promises user code that it never runs twice at once —
    /// neither would mean much if every connection had its own count. Requests leave it in
    /// arrival order, except that a request whose own connection has no place for it waits
    /// without holding up the others.
    ///
    /// Lock order: the gate's lock, then a connection's. A connection never calls the gate
    /// while holding its own lock.
    private let gate = Mutex(Gate())

    /// Starts `entry` if a slot is free and its connection has a place, queues it otherwise, or
    /// refuses it when the queue is full.
    ///
    /// The queue limits count two kinds of waiting apart. The waiting requests of a connection
    /// whose peer is behind on reading (its output is over budget) are counted against that
    /// connection alone: whatever of them runs only adds to what waits for that peer. The
    /// waiting requests of all other connections share the limit across the server. So a peer
    /// that does not read cannot crowd the others out of the queue, and its own backlog is
    /// still bounded. Every connection with waiting requests is asked on each arrival rather
    /// than remembered as saturated: its peer may start or stop reading at any moment, and a
    /// full connection is otherwise noticed only when a free slot lets the gate try it.
    func acquireSlot(_ entry: GateEntry) -> GateDecision {
        let limit = configuration.handlerLimit
        let budgets = configuration.budgets
        let owner = entry.owner
        return gate.withLock { gate in
            // Whoever waited first goes first: a slot or a place may have come free a moment ago.
            fillSlotsLocked(&gate)
            if gate.running < limit, gate.queues[owner] == nil, !gate.saturated.contains(owner) {
                switch entry.start() {
                case .started:
                    gate.running += 1
                    return .started
                case .gone:
                    return .gone
                case .busy:
                    gate.saturated.insert(owner)
                }
            }
            var count = 0
            var bytes = 0
            if entry.peerIsBehind() {
                count = gate.queues[owner]?.count ?? 0
                bytes = gate.queues[owner]?.bytes ?? 0
            } else {
                // The owner's own queue counts by the answer just given, not by a second one.
                for (other, queue) in gate.queues where other == owner || !queue.peerIsBehind() {
                    guard queue.count <= budgets.maxQueuedRequests - count,
                        queue.bytes <= budgets.maxQueuedBytes - bytes else { return .overloaded }
                    count += queue.count
                    bytes += queue.bytes
                }
            }
            guard count < budgets.maxQueuedRequests, entry.bytes <= budgets.maxQueuedBytes - bytes else {
                return .overloaded
            }
            gate.queues[owner, default: OwnerQueue(peerIsBehind: entry.peerIsBehind)].append(entry, sequence: gate.nextSequence)
            gate.nextSequence += 1
            return .queued
        }
    }

    /// A handler of `owner` ended and its response is queued: a slot and a place are free.
    func releaseSlot(owner: ObjectIdentifier) {
        gate.withLock { gate in
            gate.running -= 1
            gate.saturated.remove(owner)
            fillSlotsLocked(&gate)
        }
    }

    /// Returns a slot while its request keeps its place: the handler is done and its response
    /// is waiting for the peer to read.
    func releaseSlot() {
        gate.withLock { gate in
            gate.running -= 1
            fillSlotsLocked(&gate)
        }
    }

    /// `owner` got a free place while its slot had been returned already: its requests that
    /// were passed over may run now.
    func placeFreed(owner: ObjectIdentifier) {
        gate.withLock { gate in
            gate.saturated.remove(owner)
            fillSlotsLocked(&gate)
        }
    }

    /// Gives free slots to the oldest requests whose connections can take them. The cost is one
    /// look at each connection that has requests waiting, not at each request.
    private func fillSlotsLocked(_ gate: inout Gate) {
        let limit = configuration.handlerLimit
        while gate.running < limit {
            var oldest: (owner: ObjectIdentifier, sequence: UInt64)?
            for (owner, queue) in gate.queues where !gate.saturated.contains(owner) {
                guard let first = queue.first else { continue }
                if oldest == nil || first.sequence < oldest!.sequence { oldest = (owner, first.sequence) }
            }
            guard let oldest, let first = gate.queues[oldest.owner]?.first else { return }
            switch first.entry.start() {
            case .started:
                gate.running += 1
                popLocked(&gate, oldest.owner)
            case .gone:
                popLocked(&gate, oldest.owner)
            case .busy:
                gate.saturated.insert(oldest.owner)
            }
        }
    }

    private func popLocked(_ gate: inout Gate, _ owner: ObjectIdentifier) {
        gate.queues[owner]?.removeFirst()
        if gate.queues[owner]?.isEmpty == true { gate.queues[owner] = nil }
    }

    /// Removes queued requests of a connection that were cancelled or abandoned.
    func withdraw(owner: ObjectIdentifier, serials: Set<UInt64>) {
        guard !serials.isEmpty else { return }
        gate.withLock { gate in
            gate.queues[owner]?.remove(serials: serials)
            if gate.queues[owner]?.isEmpty == true { gate.queues[owner] = nil }
        }
    }

    /// Forgets everything about a connection that is gone. Its identifier may be given to a
    /// new connection, which must not inherit the old one's state.
    func gateForget(owner: ObjectIdentifier) {
        gate.withLock { gate in
            gate.queues[owner] = nil
            gate.saturated.remove(owner)
            fillSlotsLocked(&gate)
        }
    }
}

enum ListKind: Int, Sendable, CaseIterable {
    case tools, resources, templates, prompts

    var capability: ServerCapability {
        switch self {
        case .tools: .tools
        case .resources, .templates: .resources
        case .prompts: .prompts
        }
    }
}

enum ServerCapability: Sendable, Hashable {
    case tools, resources, prompts, completions
}

enum ServerEvent: Sendable, Hashable {
    case listChanged(ListKind)
    case resourceUpdated(String)
}

struct WeakConnection: Sendable {
    weak var connection: Connection?
    init(_ connection: Connection) { self.connection = connection }
}

/// The server's connections, for broadcasting events. A connection dropped without `close()`
/// leaves an empty entry behind; those are cleared at each broadcast, and whenever the table
/// has doubled since it was last cleared, so a server that broadcasts nothing does not keep
/// one entry per connection it ever had.
struct ConnectionTable {
    var entries: [ObjectIdentifier: WeakConnection] = [:]
    private var pruneAt = 64

    mutating func insert(_ connection: Connection) {
        entries[ObjectIdentifier(connection)] = WeakConnection(connection)
        if entries.count >= pruneAt { prune() }
    }

    mutating func prune() {
        entries = entries.filter { $0.value.connection != nil }
        pruneAt = max(64, entries.count * 2)
    }
}

// MARK: - Registry

struct ToolEntry: Sendable {
    let definition: ToolDefinition
    let input: JSONSchema
    let output: JSONSchema?
    let handler: ToolHandler
}

struct ResourceEntry: Sendable {
    let definition: ResourceDefinition
    let cache: CachePolicy?
    let read: ResourceReader
}

struct TemplateEntry: Sendable {
    let definition: ResourceTemplateDefinition
    let template: URITemplate
    let cache: CachePolicy?
    let complete: CompletionHandler?
    let read: ResourceReader
}

struct PromptEntry: Sendable {
    let definition: PromptDefinition
    let complete: CompletionHandler?
    let handler: PromptHandler
}

struct RegistryContents: Sendable {
    /// A modern client can refresh a list after its last entry was removed.
    var modernListCapabilities: Set<ServerCapability> = []
    var tools: [ToolEntry] = []
    var toolIndex: [ExactString: Int] = [:]
    var resources: [ResourceEntry] = []
    var resourceIndex: [ExactString: Int] = [:]
    var templates: [TemplateEntry] = []
    var prompts: [PromptEntry] = []
    var promptIndex: [ExactString: Int] = [:]
    var methods: [ExactString: MethodHandler] = [:]

    mutating func reindex() {
        toolIndex = Dictionary(uniqueKeysWithValues: tools.enumerated().map { (ExactString($1.definition.name), $0) })
        resourceIndex = Dictionary(uniqueKeysWithValues: resources.enumerated().map { (ExactString($1.definition.uri), $0) })
        promptIndex = Dictionary(uniqueKeysWithValues: prompts.enumerated().map { (ExactString($1.definition.name), $0) })
    }
}

/// An immutable view of the registry. Requests read one snapshot from start to finish, so a
/// registration in the middle of a request cannot produce a mixed view; listings are encoded
/// once per revision and reused until the registry changes.
final class RegistrySnapshot: Sendable {
    let contents: RegistryContents
    let legacyCapabilities: Set<ServerCapability>
    let modernCapabilities: Set<ServerCapability>
    /// Encoded list results, indexed by `ListKind` then by revision profile.
    private let encodedLists = Mutex<[[UInt8]?]>(Array(repeating: nil, count: ListKind.allCases.count * 4))

    init(_ contents: RegistryContents = RegistryContents()) {
        self.contents = contents
        var capabilities: Set<ServerCapability> = []
        if !contents.tools.isEmpty { capabilities.insert(.tools) }
        if !contents.resources.isEmpty || !contents.templates.isEmpty { capabilities.insert(.resources) }
        if !contents.prompts.isEmpty { capabilities.insert(.prompts) }
        if contents.prompts.contains(where: { $0.complete != nil }) || contents.templates.contains(where: { $0.complete != nil }) {
            capabilities.insert(.completions)
        }
        legacyCapabilities = capabilities
        modernCapabilities = capabilities.union(contents.modernListCapabilities)
    }

    func tool(named name: String) -> ToolEntry? { contents.toolIndex[ExactString(name)].map { contents.tools[$0] } }
    func prompt(named name: String) -> PromptEntry? { contents.promptIndex[ExactString(name)].map { contents.prompts[$0] } }
    func resource(uri: String) -> ResourceEntry? { contents.resourceIndex[ExactString(uri)].map { contents.resources[$0] } }

    func count(of kind: ListKind) -> Int {
        switch kind {
        case .tools: contents.tools.count
        case .resources: contents.resources.count
        case .templates: contents.templates.count
        case .prompts: contents.prompts.count
        }
    }

    /// The encoded, unpaginated result for a list, built on first use.
    func encodedList(_ kind: ListKind, profile: RevisionProfile, build: () -> [UInt8]) -> [UInt8] {
        let slot = kind.rawValue * 4 + profile.index
        if let cached = encodedLists.withLock({ $0[slot] }) { return cached }
        let encoded = build()
        encodedLists.withLock { $0[slot] = encoded }
        return encoded
    }
}
