public import LimbCore

/// A decoded MCP result, with the complete result object as sent by the peer.
public struct ClientResult<Value: Sendable>: Sendable {
    public let value: Value
    public let raw: JSONObject
    public var metadata: JSONObject? { raw["_meta"]?.objectValue }
    /// Cache hints the application can use. For MRTR continuation results, the wire hints are
    /// preserved in `raw` and this property is `nil`.
    public let cache: ClientCacheHints?
}

public struct ClientCacheHints: Sendable, Equatable {
    public enum Scope: String, Sendable {
        case `public`, `private`
    }

    public let ttlMilliseconds: JSONNumber
    public let scope: Scope
}

/// One page of a remote collection. Pass the opaque cursor to the same list method.
public struct ClientPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextCursor: String?
}

/// Extract JSON from a tool reply that has no structured content.
public typealias ToolOutputExtractor = @Sendable (ToolResult) throws(JSONDecodingError) -> JSONValue

public struct TypedToolResult<Output: Sendable>: Sendable {
    public let result: ToolResult
    /// Absent when the tool reports an execution error.
    public let output: Output?
}

public enum ClientCompletionReference: Sendable, Equatable {
    case prompt(name: String)
    case resource(uri: String)

    fileprivate var wire: JSONObject {
        switch self {
        case .prompt(let name): ["type": "ref/prompt", "name": .string(name)]
        case .resource(let uri): ["type": "ref/resource", "uri": .string(uri)]
        }
    }
}

/// Local validation errors from the public operations. The peer's JSON-RPC errors are `MCPError`.
public enum ClientResponseError: Error, Sendable, Equatable {
    case invalidResult(method: String, error: JSONDecodingError)
    /// A modern operation requires additional input. The unmodified result includes its requests and state.
    case inputRequired(method: String, result: JSONObject)
    case invalidToolArguments(JSONDecodingError)
    case invalidToolOutput(JSONDecodingError)
    /// A reply was received, but its output failed the tool's declared schema.
    case toolOutputSchemaViolation(SchemaViolation)
    case invalidToolSchema(JSONSchemaError)
    case unsupportedMethod(String)
}

private struct StartedClientOperation {
    let options: ClientRequestOptions
    let permit: ClientWorkPermit

    func run<Value: Sendable>(
        delivery: ClientDelivery, _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await permit.run(until: options.deadline, delivery: delivery, body)
    }
}

private enum ClientOperationRound<Value: Sendable>: Sendable {
    case complete(ClientResult<Value>)
    case input(ClientInputRound)
}

extension Client {
    /// Validate remote schemas with Limb's bounded JSON Schema compiler. The default is
    /// 2020-12, with draft-07 support for the same keywords. References resolve locally.
    public nonisolated func listTools(
        cursor: String? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<ClientPage<ToolDefinition>> {
        try await page("tools/list", "tools", cursor: cursor, options: options, decode: ClientWire.tool)
    }

    /// Invoke a tool by name with a JSON object. A tool execution error is returned as
    /// `value.isError`. Pass a `ToolDefinition` to validate the output against its schema.
    public nonisolated func callTool(
        _ name: String, arguments: JSONObject? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<ToolResult> {
        if let recovery { return try await recovery.session().callTool(name, arguments: arguments, options: options) }
        var params: JSONObject = ["name": .string(name)]
        if let arguments { params["arguments"] = .object(arguments) }
        return try await operation("tools/call", params, options: options, acceptsInput: true) { [profile] body throws(JSONDecodingError) in
            try ClientWire.toolResult(body, profile: profile)
        }
    }

    /// Encode arguments as an object and decode a successful result as `Output`. If the peer
    /// omits structured content, use the supplied extractor or a single text block containing JSON.
    public nonisolated func callTool<Arguments: JSONEncodable & Sendable, Output: JSONDecodable & Sendable>(
        _ name: String, arguments: Arguments, decoding: Output.Type,
        extracting: ToolOutputExtractor? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<TypedToolResult<Output>> {
        if let recovery {
            return try await recovery.session().callTool(
                name, arguments: arguments, decoding: decoding, extracting: extracting, options: options)
        }
        let operation = try await startOperation("tools/call", options)
        let params = try await operation.run(delivery: .notSent) {
            try Self.toolArguments(arguments)
        }
        let result = try await callTool(name, arguments: params, options: operation.options)
        return try await operation.run(delivery: .unknown) {
            try Self.typedResult(result, decoding: decoding, extracting: extracting)
        }
    }

    /// Invoke a catalog tool and validate its successful output against its advertised output schema.
    /// A missing structured result can be read from a single text block containing JSON.
    public nonisolated func callTool(
        _ tool: ToolDefinition, arguments: JSONObject? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<ToolResult> {
        try await callValidatedTool(tool, arguments: arguments, options: options).result
    }

    /// Validate the catalog tool's output and decode it as `Output` on success.
    public nonisolated func callTool<Arguments: JSONEncodable & Sendable, Output: JSONDecodable & Sendable>(
        _ tool: ToolDefinition, arguments: Arguments, decoding: Output.Type,
        extracting: ToolOutputExtractor? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<TypedToolResult<Output>> {
        if let recovery {
            return try await recovery.session().callTool(
                tool, arguments: arguments, decoding: decoding, extracting: extracting, options: options)
        }
        let operation = try await startOperation("tools/call", options)
        let params = try await operation.run(delivery: .notSent) {
            try Self.toolArguments(arguments)
        }
        let (result, validatedValue) = try await callValidatedTool(
            tool, arguments: params, extracting: extracting, options: operation.options)
        return try await operation.run(delivery: .unknown) {
            try Self.typedResult(result, decoding: decoding, extracting: extracting, validatedValue: validatedValue)
        }
    }

    private nonisolated func callValidatedTool(
        _ tool: ToolDefinition, arguments: JSONObject?, extracting: ToolOutputExtractor? = nil,
        options: ClientRequestOptions
    ) async throws -> (result: ClientResult<ToolResult>, validatedValue: JSONValue?) {
        if let recovery {
            return try await recovery.session().callValidatedTool(
                tool, arguments: arguments, extracting: extracting, options: options)
        }
        let operation = try await startOperation("tools/call", options)
        var schema: JSONSchema?
        if let output = tool.outputSchema {
            schema = try await operation.run(delivery: .notSent) {
                do throws(JSONSchemaError) { return try JSONSchema(.object(output)) }
                catch { throw ClientResponseError.invalidToolSchema(error) }
            }
        }
        let result = try await callTool(tool.name, arguments: arguments, options: operation.options)
        guard let schema, !result.value.isError else { return (result, nil) }
        let output = try await operation.run(delivery: .unknown) {
            let output: JSONValue
            do throws(JSONDecodingError) {
                output = try ClientWire.toolOutput(result.value, extracting: extracting)
            } catch {
                throw ClientResponseError.invalidToolOutput(error)
            }
            if let violation = schema.validate(output) {
                throw ClientResponseError.toolOutputSchemaViolation(violation)
            }
            return output
        }
        return (result, output)
    }

    public nonisolated func listResources(
        cursor: String? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<ClientPage<ResourceDefinition>> {
        try await page("resources/list", "resources", cursor: cursor, options: options, decode: ClientWire.resource)
    }

    public nonisolated func listResourceTemplates(
        cursor: String? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<ClientPage<ResourceTemplateDefinition>> {
        try await page("resources/templates/list", "resourceTemplates", cursor: cursor,
                       options: options, decode: ClientWire.template)
    }

    /// Ask the connected peer to read a URI. No local URI resolution is performed.
    public nonisolated func readResource(
        _ uri: String, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<[ResourceContents]> {
        if let recovery { return try await recovery.session().readResource(uri, options: options) }
        return try await operation("resources/read", ["uri": .string(uri)], options: options,
                            cacheable: true, acceptsInput: true) { [profile] body throws(JSONDecodingError) in
            try ClientWire.elements(body, "contents") { item throws(JSONDecodingError) in
                try ClientWire.resourceContents(item, profile: profile)
            }
        }
    }

    public nonisolated func listPrompts(
        cursor: String? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<ClientPage<PromptDefinition>> {
        try await page("prompts/list", "prompts", cursor: cursor, options: options, decode: ClientWire.prompt)
    }

    public nonisolated func getPrompt(
        _ name: String, arguments: [String: String]? = nil, options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<PromptResult> {
        if let recovery { return try await recovery.session().getPrompt(name, arguments: arguments, options: options) }
        let operation = try await startOperation("prompts/get", options)
        var params: JSONObject = ["name": .string(name)]
        if let arguments {
            let fields = try await operation.run(delivery: .notSent) {
                Self.stringFields(arguments)
            }
            params["arguments"] = .object(fields)
        }
        return try await self.operation("prompts/get", params, options: operation.options, acceptsInput: true) { [profile] body throws(JSONDecodingError) in
            try ClientWire.promptResult(body, profile: profile)
        }
    }

    /// Request suggestions for an argument. Context is supported from MCP 2025-06-18 onward.
    public nonisolated func complete(
        _ reference: ClientCompletionReference, argument: String, value: String,
        context: [String: String] = [:], options: ClientRequestOptions = .init()
    ) async throws -> ClientResult<CompletionResult> {
        if let recovery {
            return try await recovery.session().complete(reference, argument: argument, value: value, context: context, options: options)
        }
        let operation = try await startOperation("completion/complete", options)
        var params: JSONObject = [
            "ref": .object(reference.wire), "argument": ["name": .string(argument), "value": .string(value)],
        ]
        if profile.version >= .v2025_06_18, !context.isEmpty {
            let fields = try await operation.run(delivery: .notSent) {
                Self.stringFields(context)
            }
            params["context"] = ["arguments": .object(fields)]
        }
        return try await self.operation("completion/complete", params, options: operation.options, decode: ClientWire.completion)
    }

    /// Change the session log level for legacy MCP. Modern requests use `ClientRequestOptions.logLevel`.
    public nonisolated func setLogLevel(_ level: LoggingLevel, options: ClientRequestOptions = .init()) async throws {
        if let recovery { return try await recovery.session().setLogLevel(level, options: options) }
        let method = "logging/setLevel"
        let operation = try await startOperation(method, options)
        _ = try await self.operation(method, ["level": .string(level.rawValue)], options: operation.options) { _ in () }
    }

    private nonisolated func page<Item: Sendable>(
        _ method: String, _ key: String, cursor: String?, options: ClientRequestOptions,
        decode: @escaping @Sendable (JSONValue, RevisionProfile) throws(JSONDecodingError) -> Item
    ) async throws -> ClientResult<ClientPage<Item>> {
        if let recovery {
            return try await recovery.session().page(method, key, cursor: cursor, options: options, decode: decode)
        }
        var params: JSONObject = [:]
        if let cursor { params["cursor"] = .string(cursor) }
        return try await operation(method, params, options: options, cacheable: true) { [profile] body throws(JSONDecodingError) in
            let items = try ClientWire.elements(body, key) { item throws(JSONDecodingError) in try decode(item, profile) }
            return ClientPage(items: items, nextCursor: try body.wireOptional("nextCursor"))
        }
    }

    private nonisolated func operation<Value: Sendable>(
        _ method: String, _ params: JSONObject, options: ClientRequestOptions, cacheable: Bool = false,
        acceptsInput: Bool = false, decode: @escaping @Sendable (JSONObject) throws(JSONDecodingError) -> Value
    ) async throws -> ClientResult<Value> {
        let operation = try await startOperation(method, options)
        let handlers = profile.multiRoundTrip && acceptsInput ? inputHandlers : nil
        // Own the progress delivery for the logical operation. Each exchange still gets a
        // fresh token, with its own ordering and correlation checks.
        let progress = handlers == nil ? nil : try options.onProgress.map(reserveProgress)
        var discardProgress = true
        defer { progress?.finish(discardPending: discardProgress) }
        var original = params
        if let handlers {
            var metadata = params["_meta"]?.objectValue ?? [:]
            metadata[MetaKey.clientCapabilities] = .object(handlers.capabilities)
            original["_meta"] = .object(metadata)
        }
        var outgoing = original
        var round = 1
        while true {
            let exchange: ClientExchangeResult
            do {
                exchange = try await self.exchange(method, params: outgoing, options: operation.options, progress: progress)
            } catch let error as MCPError {
                discardProgress = false
                throw error
            } catch let error as ClientError where round > 1 {
                throw await errorAfterInputRound(error)
            }
            let current = round
            let result: ClientOperationRound<Value> = try await operation.run(delivery: .unknown) { [profile] in
                do {
                    let body = try JSONObject(json: exchange.value)
                    _ = try body.wireOptional("_meta", as: JSONObject.self)
                    if profile.resultTypeRequired {
                        let resultType: String = try body.required("resultType")
                        if acceptsInput, resultType == "input_required" {
                            if let handlers {
                                return .input(try ClientInputRound(body, handlers: handlers, round: current, profile: profile))
                            }
                            try ClientWire.validateInputRequired(body)
                            throw ClientResponseError.inputRequired(method: method, result: body)
                        }
                        guard resultType == "complete" else {
                            throw JSONDecodingError("unexpected result type", path: ["resultType"])
                        }
                    }
                    let hints = profile.cacheHints && cacheable ? try ClientWire.cacheHints(body) : nil
                    // Completed reads carry wire hints on every round. Only the initial exchange may be cached.
                    let cache = current == 1 ? hints : nil
                    return .complete(ClientResult(value: try decode(body), raw: body, cache: cache))
                } catch let error as JSONDecodingError {
                    throw ClientResponseError.invalidResult(method: method, error: error)
                }
            }
            switch result {
            case .complete(let result):
                discardProgress = false
                return result
            case .input(let input):
                if let retirement = exchange.retirement {
                    try await operation.permit.runHandler(until: operation.options.deadline) {
                        await retirement.value
                    }
                }
                outgoing = original
                if let state = input.state { outgoing["requestState"] = .string(state) }
                if let jobs = input.jobs {
                    var responses: JSONObject = [:]
                    for job in jobs {
                        let context = ClientInputContext(
                            protocolVersion: protocolVersion, serverIdentity: serverIdentity, serverInfo: serverInfo,
                            method: job.method,
                            legacyRequestID: nil, requestKey: job.key,
                            round: current, deadline: operation.options.deadline)
                        responses[job.key] = try await operation.permit.runHandler(until: context.deadline) {
                            try await job.respond(context)
                        }
                    }
                    outgoing["inputResponses"] = .object(responses)
                }
                round += 1
            }
        }
    }

    private nonisolated func errorAfterInputRound(_ error: ClientError) async -> any Error {
        switch error {
        case .cancelled: return ClientError.cancelled(.unknown)
        case .timedOut: return ClientError.timedOut(.unknown)
        case .exchangeLost: return ClientError.exchangeLost(.unknown)
        case .connectionLost: return ClientError.connectionLost(.unknown)
        case .protocolViolation: return ClientError.protocolViolation(.unknown)
        case .httpRejected(let status, _): return ClientError.httpRejected(status: status, delivery: .unknown)
        case .closedDuringRequest: return ClientError.closedDuringRequest(.unknown)
        case .closed: return await continuationClosedError()
        case .workOverloaded: return ClientError.workOverloaded(.unknown)
        case .overloaded, .requestTooLarge, .requestIDsExhausted, .recovering: return ClientInputError.continuationFailed(error)
        }
    }

    private nonisolated static func toolArguments<T: JSONEncodable>(_ arguments: T) throws(ClientResponseError) -> JSONObject {
        var writer = JSONWriter()
        arguments.encode(to: &writer)
        do {
            return try JSONObject(json: ClientWire.parse(writer.bytes.span))
        } catch {
            throw .invalidToolArguments(error)
        }
    }

    private nonisolated static func typedResult<Output: JSONDecodable & Sendable>(
        _ result: ClientResult<ToolResult>, decoding: Output.Type, extracting: ToolOutputExtractor?,
        validatedValue: JSONValue? = nil
    ) throws(ClientResponseError) -> ClientResult<TypedToolResult<Output>> {
        var output: Output?
        if !result.value.isError {
            do throws(JSONDecodingError) {
                let value: JSONValue
                if let validatedValue { value = validatedValue }
                else { value = try ClientWire.toolOutput(result.value, extracting: extracting) }
                output = .some(try Output(json: value))
            } catch {
                throw .invalidToolOutput(error)
            }
        }
        return ClientResult(
            value: TypedToolResult(result: result.value, output: output), raw: result.raw, cache: result.cache)
    }

    private nonisolated func startOperation(
        _ method: String, _ options: ClientRequestOptions
    ) async throws -> StartedClientOperation {
        // Typed overloads prepare the same operation once and forward its reservation.
        if let permit = options.workPermit { return StartedClientOperation(options: options, permit: permit) }
        var options = options.timed
        try await ensureOpen()
        if Task.isCancelled { throw ClientError.cancelled(.notSent) }
        guard ContinuousClock.now < options.deadline else { throw ClientError.timedOut(.notSent) }
        if method == "logging/setLevel", !profile.hasLoggingSetLevel {
            throw ClientResponseError.unsupportedMethod(method)
        }
        if profile.hasInitialize, let serverCapabilities {
            let family = method.prefix { $0 != "/" }
            let capability = family == "completion" ? "completions" : String(family)
            guard serverCapabilities[capability]?.objectValue != nil else {
                throw ClientResponseError.unsupportedMethod(method)
            }
        }
        let permit = try work.reserve()
        options.workPermit = permit
        return StartedClientOperation(options: options, permit: permit)
    }

    private static func stringFields(_ strings: [String: String]) -> JSONObject {
        var object = JSONObject()
        for key in strings.keys.sorted() { object[key] = strings[key].map(JSONValue.string) }
        return object
    }
}
