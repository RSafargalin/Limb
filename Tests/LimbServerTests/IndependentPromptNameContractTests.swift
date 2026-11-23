import Limb
import LimbTesting
import Testing

@Suite struct IndependentPromptNameContractTests {
    @Test(arguments: IndependentProtocolRevision.allCases)
    func promptArgumentsMustBeRepresentableByTheHandlerDictionary(_ revision: IndependentProtocolRevision) async throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        try #require(composed == decomposed)
        try #require(!composed.utf8.elementsEqual(decomposed.utf8))

        let server = Server(name: "prompt-arguments", version: "1")
        try server.register(prompt: PromptDefinition(name: "ordinary", arguments: [PromptArgument(name: "topic", required: true)])) { arguments, _ in
            PromptResult(messages: [.user(arguments["topic"] ?? "missing")])
        }
        try server.register(prompt: PromptDefinition(name: "single", arguments: [PromptArgument(name: composed, required: true)])) { arguments, _ in
            PromptResult(messages: [.user(arguments[composed] ?? "missing")])
        }

        #expect(throws: RegistrationError.self) {
            try server.register(
                prompt: PromptDefinition(name: "collision", arguments: [PromptArgument(name: composed), PromptArgument(name: decomposed)])
            ) { _, _ in
                PromptResult(messages: [])
            }
        }

        let client = try await IndependentProtocol.client(server, revision)
        let listed = try await client.request("prompts/list")
        let prompts = try #require(listed["result"]?["prompts"]?.arrayValue)
        #expect(Set(prompts.compactMap { $0["name"]?.stringValue }) == ["ordinary", "single"])

        let unavailable = try await client.request("prompts/get", ["name": "collision"])
        #expect(unavailable["error"]?["code"] == -32602, "\(unavailable)")

        for (name, argument) in [("ordinary", "topic"), ("single", composed)] {
            let reply = try await client.request("prompts/get", ["name": .string(name), "arguments": .object([argument: "supplied"])])
            #expect(reply["result"]?["messages"]?[0]?["content"]?["text"] == "supplied", "\(reply)")
        }
    }
}
