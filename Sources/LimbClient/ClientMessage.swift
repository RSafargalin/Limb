package import LimbCore

/// One peer envelope, before the selected MCP revision and exchange source are applied.
package enum ClientMessage: Sendable {
    case request(id: RequestID, method: String, params: JSONObject)
    case notification(method: String, params: JSONObject)
    case response(id: RequestID, outcome: Result<JSONValue, MCPError>)
    /// Correlation is left to the transport. On a shared channel there is no usable ID.
    case uncorrelatedError(MCPError)

    package static func decode(
        _ bytes: Span<UInt8>, options: JSONParseOptions = .default
    ) throws(ClientMessageError) -> Self {
        var options = options
        options.rejectDuplicateKeys = true
        let value: JSONValue
        do {
            value = try JSON.parseStrict(bytes, options: options)
        } catch {
            throw .invalidJSON(error)
        }
        return try classify(value)
    }

    /// Classify one element from a strictly parsed frame, including elements of a legacy batch.
    package static func classify(_ value: JSONValue) throws(ClientMessageError) -> Self {
        guard case .object(let fields) = value, fields["jsonrpc"] == "2.0" else {
            throw .invalidEnvelope
        }

        let rawID = fields["id"]
        let id = rawID.flatMap(RequestID.init(json:))
        let result = fields["result"]
        let error = fields["error"]

        if let rawMethod = fields["method"] {
            guard let method = rawMethod.stringValue, result == nil, error == nil else {
                throw .invalidEnvelope
            }
            let params: JSONObject
            switch fields["params"] {
            case nil: params = [:]
            case .object(let object): params = object
            default:
                if let id { throw .invalidRequestParameters(id, method: method) }
                throw .invalidEnvelope
            }
            if let id { return .request(id: id, method: method, params: params) }
            guard rawID == nil else { throw .invalidEnvelope }
            return .notification(method: method, params: params)
        }

        guard result != nil || error != nil else { throw .invalidEnvelope }
        if let id {
            if let result, case .object = result, error == nil {
                return .response(id: id, outcome: .success(result))
            }
            if result == nil, let peerError = decodeError(error) {
                return .response(id: id, outcome: .failure(peerError))
            }
            throw .malformedResponse(id)
        }

        guard rawID == nil || rawID?.isNull == true, result == nil, let peerError = decodeError(error) else {
            throw .invalidEnvelope
        }
        return .uncorrelatedError(peerError)
    }

    private static func decodeError(_ value: JSONValue?) -> MCPError? {
        guard case .object(let fields) = value,
              let code = fields["code"]?.intValue, let message = fields["message"]?.stringValue else {
            return nil
        }
        return MCPError(code: code, message: message, data: fields["data"])
    }
}

package enum ClientMessageError: Error, Equatable, Sendable {
    case invalidJSON(JSONParseError)
    case invalidEnvelope
    case invalidRequestParameters(RequestID, method: String)
    /// The response shape and ID are known. The transport still verifies its source.
    case malformedResponse(RequestID)
}
