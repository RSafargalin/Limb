/// One decoded JSON-RPC message, classified by shape.
public enum IncomingMessage: Sendable {
    case request(id: RequestID, method: String, params: JSONObject)
    case notification(method: String, params: JSONObject)
    /// A reply to a request this side sent (legacy server-to-client requests).
    case response(id: RequestID, outcome: Result<JSONValue, MCPError>)
}

/// A message that is not valid JSON-RPC, with the id to answer under when it could be read.
public struct InvalidMessage: Error, Sendable {
    public var id: RequestID?
    public var error: MCPError
    /// The message was a notification: it has a method and no id. A notification is never
    /// answered, not even to say that it is malformed.
    public var isNotification = false
    /// The message has an id but neither a method nor a result nor an error, so it cannot be
    /// told whether it was meant as a request or as a reply.
    public var isAmbiguous = false
    /// The message has no method but a result or an error: it is a reply, whatever else is
    /// wrong with it. A reply is never answered; its id belongs to the sender of the request.
    public var isReply = false
}

extension IncomingMessage {
    /// Classifies a parsed JSON value as a request, notification or response.
    ///
    /// `params` is normalized to an object: MCP defines no positional parameters, and an absent
    /// `params` is equivalent to an empty one.
    public static func classify(_ value: JSONValue) throws(InvalidMessage) -> IncomingMessage {
        guard case .object(let object) = value else {
            throw InvalidMessage(id: nil, error: .invalidRequest("message must be a JSON object"))
        }
        let rawID = object["id"]
        let id = rawID.flatMap(RequestID.init(json:))
        // Decided before anything is checked: what kind of message this was meant to be says
        // whether it may be answered and under which id. Every refusal below carries it.
        let hasMethod = object["method"] != nil
        let isReply = !hasMethod && (object["result"] != nil || object["error"] != nil)
        let isAmbiguous = !hasMethod && !isReply
        let isNotification = hasMethod && rawID == nil
        func invalid(_ error: MCPError, id: RequestID?) -> InvalidMessage {
            InvalidMessage(id: id, error: error, isNotification: isNotification, isAmbiguous: isAmbiguous, isReply: isReply)
        }

        guard object["jsonrpc"] == "2.0" else {
            throw invalid(.invalidRequest("\"jsonrpc\" must be \"2.0\""), id: id)
        }
        if let rawID, id == nil {
            throw invalid(.invalidRequest("\"id\" must be a string or an integer, got \(rawID.typeName)"), id: nil)
        }

        if let methodValue = object["method"] {
            guard case .string(let method) = methodValue else {
                throw invalid(.invalidRequest("\"method\" must be a string"), id: id)
            }
            let params: JSONObject
            switch object["params"] {
            case .none: params = JSONObject()
            case .object(let value): params = value
            case .some(let other):
                throw invalid(.invalidParams("\"params\" must be an object, got \(other.typeName)"), id: id)
            }
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        guard let id else {
            throw invalid(.invalidRequest("message has neither \"method\" nor \"id\""), id: nil)
        }
        if let result = object["result"] {
            guard object["error"] == nil else {
                throw invalid(.invalidRequest("a response must have exactly one of \"result\" and \"error\""), id: id)
            }
            return .response(id: id, outcome: .success(result))
        }
        if let error = object["error"] {
            guard case .object(let errorObject) = error, let code = errorObject["code"]?.intValue,
                let message = errorObject["message"]?.stringValue
            else {
                throw invalid(.invalidRequest("an error response requires an integer code and a string message"), id: id)
            }
            return .response(id: id, outcome: .failure(MCPError(code: code, message: message, data: errorObject["data"])))
        }
        throw invalid(.invalidRequest("message has no \"method\", \"result\" or \"error\""), id: id)
    }
}

/// Builders for outgoing JSON-RPC frames. Each returns one complete message without a trailing newline.
public enum Frame {
    /// A result response around an already-encoded result object.
    public static func result(id: RequestID, encodedResult: [UInt8]) -> [UInt8] {
        var writer = JSONWriter(capacity: encodedResult.count + 48)
        writer.beginObject()
        writer.field("jsonrpc", "2.0")
        writer.field("id", id)
        writer.rawField("result", encodedResult)
        writer.endObject()
        return writer.bytes
    }

    /// A result response whose body is written by `body` straight into the frame.
    public static func result(id: RequestID, capacity: Int = 256, _ body: (inout JSONWriter) -> Void) -> [UInt8] {
        var writer = JSONWriter(capacity: capacity)
        writer.beginObject()
        writer.field("jsonrpc", "2.0")
        writer.field("id", id)
        writer.key("result")
        body(&writer)
        writer.endObject()
        return writer.bytes
    }

    /// An error response. `id` is `null` when the request's id could not be read.
    public static func error(id: RequestID?, _ error: MCPError) -> [UInt8] {
        var writer = JSONWriter(capacity: 128)
        writer.beginObject()
        writer.field("jsonrpc", "2.0")
        writer.key("id")
        if let id { writer.write(id) } else { writer.writeNull() }
        writer.field("error", error)
        writer.endObject()
        return writer.bytes
    }

    public static func notification(method: String, _ params: ((inout JSONWriter) -> Void)? = nil) -> [UInt8] {
        var writer = JSONWriter(capacity: 128)
        writer.beginObject()
        writer.field("jsonrpc", "2.0")
        writer.field("method", method)
        if let params {
            writer.key("params")
            params(&writer)
        }
        writer.endObject()
        return writer.bytes
    }

    public static func request(id: RequestID, method: String, _ params: ((inout JSONWriter) -> Void)? = nil) -> [UInt8] {
        var writer = JSONWriter(capacity: 256)
        writer.beginObject()
        writer.field("jsonrpc", "2.0")
        writer.field("id", id)
        writer.field("method", method)
        if let params {
            writer.key("params")
            params(&writer)
        }
        writer.endObject()
        return writer.bytes
    }
}
