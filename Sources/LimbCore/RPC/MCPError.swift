/// A JSON-RPC error object.
///
/// Throw one from a handler to answer with a protocol error instead of a result.
/// On modern MCP, Limb maps reserved codes that do not apply to the operation to internal error.
public struct MCPError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { "MCP error \(code): \(message)" }
}

extension MCPError {
    /// Error codes, by who owns them.
    public enum Code {
        // JSON-RPC 2.0.
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603

        // Reserved for the MCP specification (-32020 … -32099).
        public static let headerMismatch = -32020
        public static let missingRequiredClientCapability = -32021
        public static let unsupportedProtocolVersion = -32022

        // Defined by earlier revisions; sent only to peers speaking those revisions.
        public static let legacyResourceNotFound = -32002
        /// `URLElicitationRequiredError` of `2025-11-25`; see `urlElicitationRequired(_:)`.
        public static let legacyURLElicitationRequired = -32042

        // Limb's own codes. The specification asks implementations to allocate new codes outside
        // the JSON-RPC reserved range (-32768 … -32000); these are part of Limb's stable contract.
        /// The server is at its concurrency and queue budget; retry later.
        public static let overloaded = -31001
        /// The result exceeds the response budget. A successful result is never truncated silently.
        public static let responseTooLarge = -31002
        /// A request this server sent to the client went unanswered for too long.
        public static let requestTimedOut = -31003
        /// The transport refused a request destined for the client.
        public static let requestDeliveryFailed = -31004
    }

    public static func parseError(_ detail: String) -> MCPError {
        MCPError(code: Code.parseError, message: "Parse error: \(detail)")
    }

    public static func invalidRequest(_ detail: String) -> MCPError {
        MCPError(code: Code.invalidRequest, message: "Invalid request: \(detail)")
    }

    public static func methodNotFound(_ method: String) -> MCPError {
        MCPError(code: Code.methodNotFound, message: "Method not found: \(method)")
    }

    public static func invalidParams(_ detail: String, data: JSONValue? = nil) -> MCPError {
        MCPError(code: Code.invalidParams, message: "Invalid params: \(detail)", data: data)
    }

    public static func invalidParams(_ error: JSONDecodingError) -> MCPError {
        invalidParams(error.description)
    }

    public static func internalError(_ detail: String = "Internal error") -> MCPError {
        MCPError(code: Code.internalError, message: detail)
    }

    public static func unsupportedProtocolVersion(requested: String, supported: [ProtocolVersion]) -> MCPError {
        MCPError(
            code: Code.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: [
                "supported": .array(supported.map { .string($0.rawValue) }),
                "requested": .string(requested),
            ])
    }

    public static func missingClientCapability(_ required: JSONObject) -> MCPError {
        MCPError(
            code: Code.missingRequiredClientCapability,
            message: "Missing required client capability: \(required.map(\.key).joined(separator: ", "))",
            data: ["requiredCapabilities": .object(required)])
    }

    public static func overloaded(_ detail: String) -> MCPError {
        MCPError(code: Code.overloaded, message: "Server overloaded: \(detail)")
    }

    public static func responseTooLarge(bytes: Int, limit: Int, inBatch: Bool = false) -> MCPError {
        let what = inBatch ? "batch reply's " : ""
        return MCPError(code: Code.responseTooLarge, message: "Response of \(bytes) bytes exceeds the \(what)\(limit)-byte limit")
    }

    public static func requestTimedOut(method: String, seconds: Double) -> MCPError {
        MCPError(code: Code.requestTimedOut, message: "The client did not answer \(method) within \(seconds) seconds")
    }

    public static func requestDeliveryFailed(method: String) -> MCPError {
        MCPError(code: Code.requestDeliveryFailed, message: "Could not send \(method) to the client")
    }

    /// `URLElicitationRequiredError` (`2025-11-25`): the request cannot be served until the user
    /// has completed these URL-mode elicitations; the client may retry it afterwards. Throw it
    /// from a handler. Each elicitation must be in URL mode, and its `elicitationId` is how a
    /// later `notifications/elicitation/complete` refers to it.
    ///
    /// Only `2025-11-25` has this error, and only for a client that declared URL elicitation;
    /// for any other peer the server answers `-32603` instead and reports the misuse. So does
    /// it for an error with this code that does not list at least one URL-mode elicitation
    /// with an `elicitationId` — one built here from a form-mode request, or built by hand.
    public static func urlElicitationRequired(_ elicitations: [ElicitRequest]) -> MCPError {
        let entries: [JSONValue] = elicitations.map { elicitation in
            switch elicitation.mode {
            case .url(let url):
                [
                    "mode": "url", "message": .string(elicitation.message),
                    "elicitationId": .string(elicitation.elicitationID), "url": .string(url),
                ]
            case .form:
                // Not allowed here; the server refuses to send it (see `isValidURLElicitationRequired`).
                ["mode": "form", "message": .string(elicitation.message)]
            }
        }
        return MCPError(
            code: Code.legacyURLElicitationRequired,
            message: "This request requires more information.",
            data: ["elicitations": .array(entries)])
    }
}

extension MCPError {
    /// Whether this `-32042` error has what `2025-11-25` requires of it: `data.elicitations`, a
    /// non-empty list of URL-mode elicitations, each with a message, an `elicitationId` and a URL.
    package var isValidURLElicitationRequired: Bool {
        guard code == Code.legacyURLElicitationRequired, case .array(let list)? = data?["elicitations"], !list.isEmpty else {
            return false
        }
        return list.allSatisfy { entry in
            entry["mode"] == "url" && entry["message"]?.stringValue != nil && entry["elicitationId"]?.stringValue != nil
                && entry["url"]?.stringValue != nil
        }
    }
}

extension MCPError: JSONEncodable {
    public func encode(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("code", code)
        writer.field("message", message)
        writer.field("data", data)
        writer.endObject()
    }
}
