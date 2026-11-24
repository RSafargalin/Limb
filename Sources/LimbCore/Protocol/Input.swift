/// Input a server may ask the client for while handling a request: user input (elicitation),
/// a model completion (sampling) or the client's workspace roots.
///
/// How the request travels depends on the revision: a JSON-RPC request in legacy revisions,
/// an entry of `InputRequiredResult.inputRequests` in modern ones. The types are the same.
public enum InputRequest: Sendable, Hashable {
    case elicit(ElicitRequest)
    case sample(SamplingRequest)
    case roots

    public var method: String {
        switch self {
        case .elicit: "elicitation/create"
        case .sample: "sampling/createMessage"
        case .roots: "roots/list"
        }
    }

    /// Writes the request's `params` object.
    public func encodeParams(to writer: inout JSONWriter, profile: RevisionProfile) {
        switch self {
        case .elicit(let request): request.encode(to: &writer, profile: profile)
        case .sample(let request): writer.write(request.params)
        case .roots:
            writer.beginObject()
            writer.endObject()
        }
    }
}

/// A request for input from the user.
public struct ElicitRequest: Sendable, Hashable, WireEncodable {
    public enum Mode: Sendable, Hashable {
        /// A form described by a flat JSON Schema of primitive properties.
        case form(requestedSchema: JSONObject)
        /// An out-of-band interaction at a URL (`2025-11-25` and later).
        case url(String)
    }

    public var message: String
    public var mode: Mode
    /// Names a URL-mode elicitation in `2025-11-25`, which requires it: a later
    /// `notifications/elicitation/complete` (see `RequestContext.notifyElicitationComplete`)
    /// refers to it, and a server typically puts it into the URL to recognize the user's visit.
    /// It must be unique within the server; the client treats it as opaque. Not sent in other
    /// revisions, nor in form mode.
    public var elicitationID: String

    public init(message: String, requestedSchema: JSONObject) {
        self.message = message
        mode = .form(requestedSchema: requestedSchema)
        elicitationID = ""
    }

    /// - Parameter elicitationID: `nil` makes a random one (128 bits, hexadecimal).
    public init(message: String, url: String, elicitationID: String? = nil) {
        self.message = message
        mode = .url(url)
        self.elicitationID = elicitationID ?? Self.randomID()
    }

    private static func randomID() -> String {
        var generator = SystemRandomNumberGenerator()
        let high = String(generator.next() as UInt64, radix: 16)
        let low = String(generator.next() as UInt64, radix: 16)
        return String(repeating: "0", count: 16 - high.count) + high + String(repeating: "0", count: 16 - low.count) + low
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        switch mode {
        case .form(var requestedSchema):
            if profile.urlElicitation { writer.field("mode", "form") }
            if requestedSchema["properties"] == nil { requestedSchema["properties"] = [:] }
            writer.field("message", message)
            writer.field("requestedSchema", requestedSchema)
        case .url(let url):
            writer.field("mode", "url")
            writer.field("message", message)
            if profile.elicitationCompletion { writer.field("elicitationId", elicitationID) }
            writer.field("url", url)
        }
        writer.endObject()
    }
}

/// The user's answer to an elicitation.
public struct ElicitResult: Sendable, Hashable, JSONDecodable {
    public enum Action: String, Sendable, Hashable { case accept, decline, cancel }

    public var action: Action
    /// The submitted form values: present only when `action` is `accept` for a form, and
    /// `nil` otherwise, whatever the client sent.
    public var content: JSONObject?

    public init(action: Action, content: JSONObject? = nil) {
        self.action = action
        self.content = content
    }

    public init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        let actionName = try object.required("action", as: String.self)
        guard let action = Action(rawValue: actionName) else {
            throw JSONDecodingError("unknown elicitation action \"\(actionName)\"", path: ["action"])
        }
        self.action = action
        content = try object.optional("content")
    }
}

/// A request for a model completion from the client (`sampling/createMessage`).
///
/// Sampling is deprecated as of `2026-07-28`; it stays available through the deprecation window.
public struct SamplingRequest: Sendable, Hashable {
    /// The complete `params` object.
    public var params: JSONObject

    public init(params: JSONObject) { self.params = params }

    /// A single-turn text request.
    public init(prompt: String, systemPrompt: String? = nil, maxTokens: Int, temperature: Double? = nil) {
        var params: JSONObject = [
            "messages": [["role": "user", "content": ["type": "text", "text": .string(prompt)]]]
        ]
        if let systemPrompt { params["systemPrompt"] = .string(systemPrompt) }
        if let temperature { params["temperature"] = JSONValue(temperature) }
        params["maxTokens"] = JSONValue(maxTokens)
        self.params = params
    }
}

/// The model's reply to a sampling request.
public struct SamplingResult: Sendable, Hashable, JSONDecodable {
    public var role: Role
    /// One content block, or an array of them.
    public var content: JSONValue
    public var model: String
    public var stopReason: String?

    public init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        let roleName = try object.required("role", as: String.self)
        guard let role = Role(rawValue: roleName) else {
            throw JSONDecodingError("unknown role \"\(roleName)\"", path: ["role"])
        }
        self.role = role
        content = try object.required("content")
        model = try object.required("model")
        stopReason = try object.optional("stopReason")
    }

    /// The text of the reply, joined across text blocks.
    public var text: String? {
        let blocks: [JSONValue]
        if case .array(let array) = content { blocks = array } else { blocks = [content] }
        let texts = blocks.compactMap { block in
            block["type"] == "text" ? block["text"]?.stringValue : nil
        }
        return texts.isEmpty ? nil : texts.joined()
    }
}

/// A workspace root the client exposes. Deprecated as of `2026-07-28`.
public struct Root: Sendable, Hashable, JSONDecodable {
    public var uri: String
    public var name: String?

    public init(uri: String, name: String? = nil) {
        self.uri = uri
        self.name = name
    }

    public init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        uri = try object.required("uri")
        name = try object.optional("name")
    }
}

/// The client's answer to an `InputRequest`.
public enum InputResponse: Sendable, Hashable {
    case elicit(ElicitResult)
    case sample(SamplingResult)
    case roots([Root])

    /// Decodes the answer to `request` from the client's result object.
    public init(json: JSONValue, for request: InputRequest) throws(JSONDecodingError) {
        switch request {
        case .elicit(let request):
            var result = try ElicitResult(json: json)
            // Content belongs to an accepted form answer only; anything else a client attaches
            // is not an answer to the question asked.
            if case .url = request.mode { result.content = nil }
            if result.action != .accept { result.content = nil }
            self = .elicit(result)
        case .sample: self = .sample(try SamplingResult(json: json))
        case .roots: self = .roots(try JSONObject(json: json).required("roots"))
        }
    }
}
