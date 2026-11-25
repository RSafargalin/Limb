import Foundation
import LimbCore

struct ClientInputRound: Sendable {
    let state: String?
    /// A missing map differs on the wire from an explicitly empty map.
    let jobs: [Job]?

    struct Job: Sendable {
        let key: String
        let method: String
        let respond: @Sendable (ClientInputContext) async throws -> JSONValue
    }

    init(_ body: JSONObject, handlers: ClientInputHandlers, round: Int, profile: RevisionProfile) throws {
        guard round <= handlers.maxInputRounds else {
            throw ClientInputError.roundLimitExceeded(limit: handlers.maxInputRounds)
        }
        state = try body.wireOptional("requestState")
        if let inputs: JSONObject = try body.wireOptional("inputRequests") {
            guard inputs.count <= handlers.maxInputsPerRound else {
                throw ClientInputError.inputLimitExceeded(round: round, limit: handlers.maxInputsPerRound)
            }
            let capabilities = ClientCapabilities(raw: handlers.capabilities)
            jobs = try inputs.map { key, value in
                do {
                    let request = try JSONObject(json: value)
                    return try Self.job(
                        method: request.required("method"), params: request.wireOptional("params"), key: key,
                        handlers: handlers, capabilities: capabilities, round: round, profile: profile)
                } catch let error as JSONDecodingError {
                    throw error.nested(in: key).nested(in: "inputRequests")
                }
            }
        } else {
            guard state != nil else {
                throw JSONDecodingError("expected inputRequests or requestState")
            }
            jobs = nil
        }
    }

    static func job(
        method: String, params: JSONObject?, key: String, handlers: ClientInputHandlers,
        capabilities: ClientCapabilities, round: Int, profile: RevisionProfile
    ) throws -> Job {
        let unavailable = ClientInputError.unavailableHandler(round: round, key: key, method: method)
        let invalidResponse = ClientInputError.invalidResponse(round: round, key: key)
        do {
            _ = try params?.wireOptional("_meta", as: JSONObject.self)
            switch method {
            case "elicitation/create":
                guard profile.elicitationRequests || profile.multiRoundTrip else { throw unavailable }
                guard let params else { throw JSONDecodingError("missing required field") }
                let mode: String = try params.wireOptional("mode") ?? "form"
                switch mode {
                case "form":
                    guard capabilities.supportsElicitation, let handler = handlers.elicitForm else { throw unavailable }
                    let message: String = try params.required("message")
                    let schema: JSONObject = try params.required("requestedSchema")
                    let validator = try formValidator(schema, profile: profile)
                    let elicitation = ElicitRequest(message: message, requestedSchema: schema)
                    return Job(key: key, method: method) { context in
                        let answer = try await handler(elicitation, context)
                        var result: JSONObject = ["action": .string(answer.action.rawValue)]
                        if answer.action == .accept {
                            guard let content = answer.content, ElicitationForm.hasSupportedValues(content, profile: profile),
                                  validator.validate(.object(content)) == nil else { throw invalidResponse }
                            result["content"] = .object(content)
                        }
                        return .object(result)
                    }
                case "url":
                    guard profile.urlElicitation, capabilities.supportsURLElicitation,
                          let handler = handlers.elicitURL else { throw unavailable }
                    return try urlJob(decodeURL(params, profile: profile), key: key, handler: handler)
                default:
                    throw JSONDecodingError("unknown elicitation mode", path: ["mode"])
                }
            case "sampling/createMessage":
                guard capabilities.supportsSampling, let handler = handlers.sample else { throw unavailable }
                guard let params else { throw JSONDecodingError("missing required field") }
                let context: String? = try params.wireOptional("includeContext")
                if let context, !["none", "thisServer", "allServers"].contains(context) {
                    throw JSONDecodingError("unknown sampling context", path: ["includeContext"])
                }
                guard params["tools"] == nil, params["toolChoice"] == nil else { throw unavailable }
                if profile.multiRoundTrip, let context, context != "none" { throw unavailable }
                try validateSampling(params, profile: profile)
                return Job(key: key, method: method) { context in
                    let answer = try await handler(SamplingRequest(params: params), context)
                    do { try validateSamplingContent(answer.content, profile: profile) }
                    catch { throw invalidResponse }
                    guard answer.stopReason != "toolUse" else { throw invalidResponse }
                    var result: JSONObject = [
                        "role": .string(answer.role.rawValue), "content": answer.content, "model": .string(answer.model),
                    ]
                    if let stopReason = answer.stopReason { result["stopReason"] = .string(stopReason) }
                    return .object(result)
                }
            case "roots/list":
                guard capabilities.supportsRoots, let handler = handlers.roots else { throw unavailable }
                return Job(key: key, method: method) { context in
                    let roots = try await handler(context)
                    return try ["roots": .array(roots.map { root in
                        guard isFileRoot(root.uri) else { throw invalidResponse }
                        var result: JSONObject = ["uri": .string(root.uri)]
                        if let name = root.name { result["name"] = .string(name) }
                        return .object(result)
                    })]
                }
            default:
                throw ClientInputError.unsupportedMethod(round: round, key: key, method: method)
            }
        } catch let error as JSONDecodingError {
            throw error.nested(in: "params")
        }
    }

    private static func formValidator(_ schema: JSONObject, profile: RevisionProfile) throws(JSONDecodingError) -> JSONSchema {
        guard schema["properties"]?.objectValue != nil else {
            throw JSONDecodingError("expected a properties object", path: ["requestedSchema", "properties"])
        }
        guard ElicitationForm.isSupported(schema, profile: profile) else {
            throw JSONDecodingError("expected a flat elicitation form", path: ["requestedSchema"])
        }
        do { return try JSONSchema(.object(schema)) }
        catch { throw JSONDecodingError(error.description, path: ["requestedSchema"]) }
    }

    private static func validateSampling(_ params: JSONObject, profile: RevisionProfile) throws(JSONDecodingError) {
        _ = try ClientWire.elements(params, "messages") { value throws(JSONDecodingError) in
            let fields = try JSONObject(json: value)
            let role: String = try fields.required("role")
            guard Role(rawValue: role) != nil else {
                throw JSONDecodingError("unknown sampling role", path: ["role"])
            }
            let content: JSONValue = try fields.required("content")
            do throws(JSONDecodingError) { try validateSamplingContent(content, profile: profile) }
            catch { throw error.nested(in: "content") }
        }
        guard let maxTokens = params["maxTokens"]?.numberValue, maxTokens.isInteger else {
            throw JSONDecodingError("expected an integer", path: ["maxTokens"])
        }
        _ = try params.wireOptional("systemPrompt", as: String.self)
        _ = try params.wireOptional("temperature", as: Double.self)
        _ = try params.wireOptional("stopSequences", as: [String].self)
        _ = try params.wireOptional("metadata", as: JSONObject.self)
        if let preferences: JSONObject = try params.wireOptional("modelPreferences") {
            do throws(JSONDecodingError) {
                for key in ["costPriority", "speedPriority", "intelligencePriority"] {
                    if let priority: Double = try preferences.wireOptional(key), !(0...1).contains(priority) {
                        throw JSONDecodingError("expected a priority from 0 to 1", path: [key])
                    }
                }
                if let hints: [JSONObject] = try preferences.wireOptional("hints") {
                    for (index, hint) in hints.enumerated() {
                        do throws(JSONDecodingError) { _ = try hint.wireOptional("name", as: String.self) }
                        catch { throw error.nested(in: "[\(index)]").nested(in: "hints") }
                    }
                }
            } catch {
                throw error.nested(in: "modelPreferences")
            }
        }
    }

    private static func validateSamplingContent(_ content: JSONValue, profile: RevisionProfile) throws(JSONDecodingError) {
        func validate(_ value: JSONValue) throws(JSONDecodingError) {
            guard let type = value["type"]?.stringValue, ["text", "image", "audio"].contains(type) else {
                throw JSONDecodingError("expected text, image or audio sampling content", path: ["type"])
            }
            switch try ClientWire.content(value, profile: profile) {
            case .image(let data, _, _, _), .audio(let data, _, _, _):
                guard Data(base64Encoded: data) != nil else {
                    throw JSONDecodingError("expected base64-encoded data", path: ["data"])
                }
            default: break
            }
        }
        if let blocks = content.arrayValue {
            guard profile.samplingTools else { throw JSONDecodingError("expected a single content block") }
            guard !blocks.isEmpty else { throw JSONDecodingError("expected at least one content block") }
            for (index, block) in blocks.enumerated() {
                do { try validate(block) }
                catch { throw error.nested(in: "[\(index)]") }
            }
        } else {
            try validate(content)
        }
    }

    static func decodeURL(_ params: JSONObject, profile: RevisionProfile) throws(JSONDecodingError) -> ElicitRequest {
        _ = try params.wireOptional("_meta", as: JSONObject.self)
        let message: String = try params.required("message")
        let url: String = try params.required("url")
        guard isAbsoluteURL(url) else {
            throw JSONDecodingError("expected an absolute URL", path: ["url"])
        }
        let id: String = profile.elicitationCompletion ? try params.required("elicitationId") : ""
        return ElicitRequest(message: message, url: url, elicitationID: id)
    }

    static func urlJob(
        _ request: ElicitRequest, key: String,
        handler: @escaping @Sendable (ElicitRequest, ClientInputContext) async throws -> ElicitResult
    ) -> Job {
        Job(key: key, method: "elicitation/create") { context in
            let answer = try await handler(request, context)
            guard answer.content == nil else {
                throw ClientInputError.invalidResponse(round: context.round, key: key)
            }
            return ["action": .string(answer.action.rawValue)]
        }
    }

    static func isAbsoluteURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url, encodingInvalidCharacters: false), let scheme = parsed.scheme else {
            return false
        }
        return !["http", "https"].contains(scheme.lowercased()) || parsed.host?.isEmpty == false
    }

    private static func isFileRoot(_ uri: String) -> Bool {
        guard uri.lowercased().hasPrefix("file://"),
              let parts = URLComponents(string: uri, encodingInvalidCharacters: false),
              parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.hasPrefix("/"), !parts.path.utf8.contains(0) else { return false }
        return !parts.path.split(separator: "/").contains("..")
    }
}
