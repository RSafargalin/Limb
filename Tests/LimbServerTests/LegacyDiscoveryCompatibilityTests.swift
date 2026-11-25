import Limb
import LimbTesting
import Testing

@Suite struct LegacyDiscoveryCompatibilityTests {
    @Test(arguments: [
        ProtocolVersion.v2025_03_26,
        .v2025_06_18,
        .v2025_11_25,
    ])
    func legacyOnlyServerAllowsInitializationAfterMethodNotFoundForDiscovery(version: ProtocolVersion) async throws {
        var configuration = ServerConfiguration(info: .init(name: "legacy-only", version: "1"))
        configuration.supportedVersions = [version]
        let client = TestClient(Server(configuration: configuration), modern: false)

        let discover = try await client.request(
            "server/discover",
            meta: [MetaKey.protocolVersion: "2026-07-28", MetaKey.clientCapabilities: [:]]
        )
        #expect(discover["error"]?["code"]?.intValue == -32601)
        #expect(discover["result"] == nil)

        let initialize = try await client.initialize(version: .v2025_11_25)
        #expect(initialize["result"]?["protocolVersion"] == .string(version.rawValue))
        #expect(initialize["result"]?["serverInfo"]?["name"] == "legacy-only")
        #expect(try await client.request("ping")["result"] == [:])
    }
}
