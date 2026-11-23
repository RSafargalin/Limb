import Limb
import LimbTesting
import Testing

@Schema
private struct DepthContractNode {
    var value: Int
    var children: [DepthContractNode]?
}

/// Returns a small tree with an optional empty array at the leaf.
@Tool
private struct DepthContractTree {
    func call(includeLeafArray: Bool, shallow: Bool = false) -> DepthContractNode {
        let leaf = DepthContractNode(value: 3, children: includeLeafArray ? [] : nil)
        if shallow { return leaf }
        return DepthContractNode(value: 1, children: [DepthContractNode(value: 2, children: [leaf])])
    }
}

@Suite struct IndependentMacroOutputDepthContractTests {
    private func makeClient() throws -> TestClient {
        var configuration = ServerConfiguration(info: Implementation(name: "output-depth-contract", version: "1"))
        configuration.maxToolOutputDepth = 5
        let server = Server(configuration: configuration)
        try server.register(DepthContractTree())
        return TestClient(server)
    }

    @Test func acceptsStructuredOutputAtTheContainerLimit() async throws {
        let client = try makeClient()
        let response = try await client.independentMacroCall("depth_contract_tree", ["includeLeafArray": false])
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"] == false)
        // The path to the scalar value contains three objects and two arrays.
        #expect(
            response["result"]?["structuredContent"] == [
                "value": 1,
                "children": [["value": 2, "children": [["value": 3]]]],
            ])
    }

    @Test func returnsAToolErrorAboveTheLimitAndAcceptsTheNextCall() async throws {
        let client = try makeClient()
        // The empty array adds a sixth container to the same path.
        let response = try await client.independentMacroCall("depth_contract_tree", ["includeLeafArray": true])
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"] == true)
        let message = try #require(response.independentMacroFirstText)
        #expect(message.lowercased().contains("depth"))

        let next = try await client.independentMacroCall("depth_contract_tree", ["includeLeafArray": true, "shallow": true])
        #expect(next["error"] == nil)
        #expect(next["result"]?["isError"] == false)
        #expect(next["result"]?["structuredContent"] == ["value": 3, "children": []])
    }
}
