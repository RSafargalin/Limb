import Limb
import LimbTesting
import Testing


/// A fixture.
@Tool private struct IMRegAlpha { func call() -> String { "alpha" } }
/// A fixture.
@Tool private struct IMRegBeta { func call() -> String { "beta" } }
/// A fixture.
@Tool("im_reg_alpha") private struct IMRegAlphaImpostor { func call() -> String { "impostor" } }
/// A fixture.
@Tool("shared-name") private struct IMRegSharedOne { func call() -> String { "one" } }
/// A fixture.
@Tool("shared-name") private struct IMRegSharedTwo { func call() -> String { "two" } }
/// A fixture.
@Tool("IM_REG_ALPHA") private struct IMRegAlphaUppercase { func call() -> String { "upper" } }

/// A hand-written tool, as §8.1 allows ("Без макросов тоже можно").
private struct IMRegManual: MCPTool {
    static let definition = ToolDefinition(name: "im_reg_alpha", inputSchema: ["type": "object"])
    func call(arguments: JSONObject, context: RequestContext) async throws -> ToolResult { .text("manual") }
}

/// The error `body` throws, which has to be a `RegistrationError`; `nil` if it does not throw.
private func registrationError(_ body: () throws -> Server) -> RegistrationError? {
    do {
        _ = try body()
        return nil
    } catch let error as RegistrationError {
        return error
    } catch {
        Issue.record("expected a RegistrationError, got \(error)")
        return nil
    }
}

@Suite struct IndependentMacroRegistrationTests {
    @Test func theSameToolTwiceIsRefusedWhenTheServerIsBuilt() {
        let error = registrationError {
            try Server(name: "dup", version: "1") {
                IMRegAlpha()
                IMRegBeta()
                IMRegAlpha()
            }
        }
        #expect(error != nil, "a duplicate tool name was accepted")
        // A message a user can act on: it names the tool and says what is wrong.
        #expect(error?.description.contains("im_reg_alpha") == true)
        #expect(error?.description.lowercased().contains("already") == true || error?.description.lowercased().contains("duplicate") == true)
    }

    @Test func twoTypesWithOneNameAreRefused() {
        #expect(
            registrationError {
                try Server(name: "dup", version: "1") {
                    IMRegSharedOne()
                    IMRegSharedTwo()
                }
            }?.description.contains("shared-name") == true)
        #expect(
            registrationError {
                try Server(name: "dup", version: "1") {
                    IMRegAlpha()
                    IMRegAlphaImpostor()
                }
            }?.description.contains("im_reg_alpha") == true)
        // A hand-written tool collides with a macro one just the same.
        #expect(
            registrationError {
                try Server(name: "dup", version: "1") {
                    IMRegManual()
                    IMRegAlpha()
                }
            } != nil)
    }

    /// tools.mdx: "Tool names SHOULD be considered case-sensitive."
    @Test func namesThatDifferOnlyInCaseAreDifferentTools() async throws {
        let server = try Server(name: "case", version: "1") {
            IMRegAlpha()
            IMRegAlphaUppercase()
        }
        let client = TestClient(server)
        #expect(try await client.independentMacroCall("im_reg_alpha").independentMacroFirstText == "alpha")
        #expect(try await client.independentMacroCall("IM_REG_ALPHA").independentMacroFirstText == "upper")
    }

    @Test func registeringLaterReportsTheDuplicateToo() throws {
        let server = try Server(name: "later", version: "1") { IMRegAlpha() }
        #expect(throws: RegistrationError.self) { try server.register(IMRegAlphaImpostor()) }
        try server.register(IMRegBeta())
        #expect(throws: RegistrationError.self) { try server.register(IMRegBeta()) }
    }

    @Test func aRefusedDuplicateLeavesTheFirstToolInPlace() async throws {
        let server = try Server(name: "later", version: "1") { IMRegAlpha() }
        #expect(throws: RegistrationError.self) { try server.register(IMRegAlphaImpostor()) }
        let client = TestClient(server)
        #expect(try await client.independentMacroCall("im_reg_alpha").independentMacroFirstText == "alpha")
        #expect(try await client.request("tools/list")["result"]?["tools"]?.arrayValue?.count == 1)
    }

    @Test func theBuilderSupportsControlFlow() async throws {
        let includeBeta = true
        let excluded = false
        let server = try Server(name: "flow", version: "1") {
            IMRegAlpha()
            if includeBeta { IMRegBeta() }
            if excluded { IMRegSharedOne() } else { IMRegSharedTwo() }
            for _ in 0..<0 { IMRegAlphaUppercase() }
            if #available(macOS 26, *) { IMRegAlphaUppercase() }
        }
        let client = TestClient(server)
        let names = try await client.request("tools/list")["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["im_reg_alpha", "im_reg_beta", "shared-name", "IM_REG_ALPHA"])
        #expect(try await client.independentMacroCall("shared-name").independentMacroFirstText == "two")
    }

    /// An empty builder compiles and gives a server that offers no tools. Since the second
    /// round such a server does not advertise the `tools` capability, and the methods of a
    /// capability that is not advertised do not exist (`-32601`).
    @Test func anEmptyBuilderIsAServerWithoutTools() async throws {
        let server = try Server(name: "empty", version: "1") {}
        let client = TestClient(server)
        let listing = try await client.request("tools/list")
        #expect(listing["result"] == nil)
        #expect(listing["error"]?["code"] == -32601)
        #expect(try await client.independentMacroCall("im_reg_alpha")["error"]?["code"] == -32601)

        // The first tool registered later brings the capability with it.
        try server.register(IMRegAlpha())
        let later = TestClient(server)
        #expect(try await later.request("tools/list")["result"]?["tools"]?.arrayValue?.count == 1)
        #expect(try await later.independentMacroCall("im_reg_alpha").independentMacroFirstText == "alpha")
    }

    @Test func aLoopThatRepeatsAToolIsADuplicate() {
        #expect(
            registrationError {
                try Server(name: "loop", version: "1") {
                    for _ in 0..<2 { IMRegBeta() }
                }
            }?.description.contains("im_reg_beta") == true)
    }
}
