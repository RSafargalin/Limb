@testable import LimbClient
import LimbCore
import Testing

private func decodeMessage(
    _ text: String, options: JSONParseOptions = .default
) throws(ClientMessageError) -> ClientMessage {
    let bytes = Array(text.utf8)
    return try ClientMessage.decode(bytes.span, options: options)
}

@Suite
struct ClientMessageTests {
    @Test func requestsAndNotificationsPreserveTheirFields() throws {
        let request = try decodeMessage(#"{"jsonrpc":"2.0","method":"sampling/createMessage","id":1e3,"params":{"limit":2}}"#)
        guard case .request(let id, let method, let params) = request else {
            Issue.record("Expected a request")
            return
        }
        #expect(id == RequestID(1000))
        #expect(method == "sampling/createMessage")
        #expect(params == ["limit": 2])

        let requestWithoutParams = try decodeMessage(#"{"jsonrpc":"2.0","method":"ping","id":"1000"}"#)
        guard case .request(let stringID, _, let emptyParams) = requestWithoutParams else {
            Issue.record("Expected a request without params")
            return
        }
        #expect(stringID == RequestID("1000"))
        #expect(emptyParams == [:])

        let notification = try decodeMessage(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#)
        guard case .notification(let notificationMethod, let notificationParams) = notification else {
            Issue.record("Expected a notification without params")
            return
        }
        #expect(notificationMethod == "notifications/cancelled")
        #expect(notificationParams == [:])
    }

    @Test func successfulResponsePreservesExactNumericPayloadWithoutResultType() throws {
        let response = try decodeMessage(
            #"{"jsonrpc":"2.0","id":9007199254740993,"result":{"count":9007199254740993,"rate":1.2300e+10}}"#)
        guard case .response(let id, .success(.object(let result))) = response else {
            Issue.record("Expected a successful object response")
            return
        }
        #expect(id == RequestID(9_007_199_254_740_993))
        #expect(result["count"]?.numberValue?.description == "9007199254740993")
        #expect(result["rate"]?.numberValue?.description == "1.2300e+10")
    }

    @Test func errorResponsePreservesDataAndRequiresAnIntegralCode() throws {
        let response = try decodeMessage(
            #"{"jsonrpc":"2.0","id":"task","error":{"code":-32602.0,"message":"Invalid params","data":{"fraction":1e-12345,"missing":null}}}"#)
        guard case .response(let id, .failure(let error)) = response else {
            Issue.record("Expected a correlated error response")
            return
        }
        #expect(id == RequestID("task"))
        #expect(error.code == -32602)
        #expect(error.message == "Invalid params")
        guard case .object(let data)? = error.data else {
            Issue.record("Expected object error data")
            return
        }
        #expect(data["fraction"]?.numberValue?.description == "1e-12345")
        #expect(data["missing"] == .null)
    }

    @Test(arguments: ["", #""id":null,"#])
    func uncorrelatedErrorDistinguishesNullAndOmittedData(idField: String) throws {
        let explicitNull = try decodeMessage(
            #"{"jsonrpc":"2.0",\#(idField)"error":{"code":-32700,"message":"Parse error","data":null}}"#)
        let omitted = try decodeMessage(
            #"{"jsonrpc":"2.0",\#(idField)"error":{"code":-32700,"message":"Parse error"}}"#)
        guard case .uncorrelatedError(let withNull) = explicitNull,
            case .uncorrelatedError(let withoutData) = omitted
        else {
            Issue.record("Expected two uncorrelated errors")
            return
        }
        #expect(withNull.code == -32700)
        #expect(withNull.message == "Parse error")
        #expect(withNull.data == .null)
        #expect(withoutData.data == nil)
    }

    @Test(arguments: [
        #"null"#,
        #"[{"jsonrpc":"2.0","id":1,"result":{}}]"#,
        #"{"id":7,"result":{}}"#,
        #"{"jsonrpc":"1.0","id":7,"result":{}}"#,
        #"{"jsonrpc":2.0,"id":7,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":7}"#,
        #"{"jsonrpc":"2.0","id":7,"method":"ping","result":{}}"#,
        #"{"jsonrpc":"2.0","id":7,"method":null,"error":null}"#,
        #"{"jsonrpc":"2.0","method":7}"#,
        #"{"jsonrpc":"2.0","method":"ping","params":null}"#,
        #"{"jsonrpc":"2.0","method":"ping","params":[]}"#,
        #"{"jsonrpc":"2.0","method":"ping","id":null}"#,
        #"{"jsonrpc":"2.0","method":"ping","id":1e-1}"#,
        #"{"jsonrpc":"2.0","id":9007199254740992.5,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":true,"error":{"code":-32700,"message":"Parse error"}}"#,
        #"{"jsonrpc":"2.0","result":{}}"#,
        #"{"jsonrpc":"2.0","id":null,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700}}"#,
        #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"},"result":null}"#,
    ])
    func invalidEnvelopeDoesNotAttributeFailureToARequest(text: String) {
        #expect(throws: ClientMessageError.invalidEnvelope) { try decodeMessage(text) }
    }

    @Test(arguments: [
        #""result":null"#,
        #""result":[]"#,
        #""result":42"#,
        #""result":{},"error":null"#,
        #""error":null"#,
        #""error":[]"#,
        #""error":{"code":1e-1,"message":"error"}"#,
        #""error":{"code":9223372036854775808,"message":"error"}"#,
        #""error":{"code":"-32602","message":"error"}"#,
        #""error":{"code":-32602}"#,
        #""error":{"message":"error"}"#,
        #""error":{"code":-32602,"message":null}"#,
    ])
    func malformedResponseRetainsItsUsableID(outcome: String) {
        let text = #"{"jsonrpc":"2.0","id":7.0,\#(outcome)}"#
        #expect(throws: ClientMessageError.malformedResponse(RequestID(7))) {
            try decodeMessage(text)
        }
    }

    @Test(arguments: [
        (#"{"jsonrpc":"2.0","id":7,"\u0069d":8,"result":{}}"#, "id"),
        (#"{"jsonrpc":"2.0","id":7,"result":{"values":[{"n":1,"n":2}]}}"#, "n"),
        (#"{"jsonrpc":"2.0","error":{"code":1,"message":"","data":{"a":1,"a":2}}}"#, "a"),
        (#"{"jsonrpc":"2.0","method":"ping","params":{"a":1,"a":2}}"#, "a"),
    ])
    func duplicateKeysFailEvenWhenParseOptionsPermitThem(text: String, key: String) {
        do {
            _ = try decodeMessage(text, options: JSONParseOptions(rejectDuplicateKeys: false))
            Issue.record("Decoded a duplicate key")
        } catch {
            guard case .invalidJSON(let parseError) = error else {
                Issue.record("Expected a JSON parsing error, got \(error)")
                return
            }
            #expect(parseError.kind == .duplicateKey(key))
        }
    }

    @Test func malformedUTF8IsRejectedBeforeEnvelopeClassification() {
        let prefix = Array(#"{"jsonrpc":"2.0","method":""#.utf8)
        let bytes = prefix + [0xC0, 0xAF] + Array(#""}"#.utf8)
        do {
            _ = try ClientMessage.decode(bytes.span)
            Issue.record("Decoded invalid UTF-8")
        } catch {
            guard case .invalidJSON(let parseError) = error else {
                Issue.record("Expected a JSON parsing error, got \(error)")
                return
            }
            #expect(parseError.kind == .invalidUTF8)
        }
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","method":"ping",}"#,
        #"{"jsonrpc":"2.0","method":"ping"} {}"#,
        #"{"jsonrpc":"2.0","method":"\uD800"}"#,
    ])
    func malformedJSONIsDistinguishedFromAnInvalidEnvelope(text: String) {
        do {
            _ = try decodeMessage(text)
            Issue.record("Decoded malformed JSON")
        } catch {
            guard case .invalidJSON = error else {
                Issue.record("Expected a JSON parsing error, got \(error)")
                return
            }
        }
    }

    @Test func resourceLimitsReachTheStrictParser() throws {
        let text = #"{"jsonrpc":"2.0","id":7,"result":{"value":{}}}"#
        _ = try decodeMessage(text, options: JSONParseOptions(maxDepth: 3, maxNodes: 5))

        let limits: [(JSONParseOptions, JSONParseError.Kind)] = [
            (JSONParseOptions(maxDepth: 2), .depthLimitExceeded(2)),
            (JSONParseOptions(maxNodes: 4), .nodeLimitExceeded(4)),
        ]
        for (options, kind) in limits {
            do {
                _ = try decodeMessage(text, options: options)
                Issue.record("Decoded JSON beyond the configured resource limit")
            } catch {
                guard case .invalidJSON(let parseError) = error else {
                    Issue.record("Expected a JSON parsing error, got \(error)")
                    continue
                }
                #expect(parseError.kind == kind)
            }
        }
    }

    @Test func classifiesIndividualParsedLegacyBatchElements() throws {
        let batch: [JSONValue] = [
            ["jsonrpc": "2.0", "method": "notifications/example", "params": ["active": true]],
            ["jsonrpc": "2.0", "id": "legacy", "result": ["items": []]],
            ["jsonrpc": "2.0", "id": "bad", "error": ["message": "missing code"]],
        ]
        #expect(throws: ClientMessageError.invalidEnvelope) {
            try ClientMessage.classify(.array(batch))
        }
        guard case .notification(let method, let params) = try ClientMessage.classify(batch[0]),
            case .response(let id, .success(let result)) = try ClientMessage.classify(batch[1])
        else {
            Issue.record("Expected a notification followed by a successful response")
            return
        }
        #expect(method == "notifications/example")
        #expect(params == ["active": true])
        #expect(id == RequestID("legacy"))
        #expect(result == ["items": []])
        #expect(throws: ClientMessageError.malformedResponse(RequestID("bad"))) {
            try ClientMessage.classify(batch[2])
        }
    }
}
