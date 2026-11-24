import LimbCore
import Testing

struct IndependentResponseEnvelopeContractTests {
    @Test(arguments: [#"{"accepted":true}"#, "null"])
    func validResultIsClassifiedAsSuccess(_ result: String) throws {
        let value = try JSON.parse(result)
        let reply: JSONValue = ["jsonrpc": "2.0", "id": 7, "result": value]
        guard case .response(let id, .success(let payload)) = try IncomingMessage.classify(reply) else {
            Issue.record("Expected a success response for \(reply)")
            return
        }
        #expect(id == RequestID(7))
        #expect(payload == value)
    }

    @Test
    func validErrorIsClassifiedAsFailureWithData() throws {
        let reply: JSONValue = [
            "jsonrpc": "2.0", "id": "peer-reply",
            "error": ["code": -32603, "message": "Example failure", "data": ["detail": 12]],
        ]
        guard case .response(let id, .failure(let error)) = try IncomingMessage.classify(reply) else {
            Issue.record("Expected an error response for \(reply)")
            return
        }
        #expect(id == RequestID("peer-reply"))
        #expect(error.code == -32603)
        #expect(error.message == "Example failure")
        #expect(error.data == ["detail": 12])
    }

    @Test(arguments: [
        #""result":null,"error":{"code":-32603,"message":"Example failure"}"#,
        #""result":{},"error":null"#,
        #""error":null"#,
        #""error":"Example failure""#,
        #""error":[]"#,
        #""error":{"message":"Missing code"}"#,
        #""error":{"code":"-32603","message":"String code"}"#,
        #""error":{"code":1.5,"message":"Fractional code"}"#,
        #""error":{"code":-32603}"#,
        #""error":{"code":-32603,"message":null}"#,
        #""error":{"code":-32603,"message":12}"#,
    ])
    func invalidResponseIsIdentifiedAsReplyWithoutYieldingPayload(_ fields: String) throws {
        let value = try JSON.parse(#"{"jsonrpc":"2.0","id":"peer-reply",\#(fields)}"#)
        do {
            let classified = try IncomingMessage.classify(value)
            Issue.record("Invalid response yielded a message: \(classified)")
        } catch {
            #expect(error.isReply)
            #expect(!error.isNotification)
        }
    }
}
