#if os(macOS)
import Foundation
import Limb
import Testing

@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["LIMB_RMCP_COUNTER_STDIO"] != nil,
        "Set LIMB_RMCP_COUNTER_STDIO to the absolute path of the rmcp-v3.11.0 servers_counter_stdio binary"
    ),
    .timeLimit(.minutes(1))
)
struct StdioClientRMCPInteropTests {
    @Test(arguments: [ProtocolVersion.v2025_03_26, .v2025_06_18, .v2025_11_25])
    func pinnedLegacyCounter(_ version: ProtocolVersion) async throws {
        try await exerciseCounter(expectedVersion: version, legacyVersion: version)
    }

    @Test("Automatically negotiated 2026-07-28")
    func automaticModernCounter() async throws {
        try await exerciseCounter(expectedVersion: .v2026_07_28, legacyVersion: nil)
    }

    private func exerciseCounter(expectedVersion: ProtocolVersion, legacyVersion: ProtocolVersion?) async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["LIMB_RMCP_COUNTER_STDIO"])
        try #require(executable.hasPrefix("/"), "LIMB_RMCP_COUNTER_STDIO must be an absolute path")

        let url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey])
        try #require(
            attributes.isRegularFile == true && FileManager.default.isExecutableFile(atPath: url.path),
            "LIMB_RMCP_COUNTER_STDIO must point to an executable file"
        )

        let client = try await Client.connect(
            stdio: .init(executable: executable),
            options: .init(timeout: .seconds(5), discoveryTimeout: .seconds(2), legacyVersion: legacyVersion)
        )
        do {
            try #require(client.protocolVersion.rawValue == expectedVersion.rawValue)
            #expect(client.serverInfo?.name == "rmcp")
            #expect(client.serverInfo?.version == "3.11.0")

            let options = ClientRequestOptions(timeout: .seconds(5))
            let tools = try await client.listTools(options: options)
            let names = Set(tools.value.items.map(\.name))
            #expect(names.isSuperset(of: ["get_value", "increment", "decrement", "say_hello", "echo", "sum"]))

            for (name, expectedValue) in [
                ("get_value", "0"), ("increment", "1"), ("increment", "2"), ("get_value", "2"),
            ] {
                let response = try await client.callTool(name, options: options)
                #expect(response.value.isError == false, "Tool \(name) returned an error")
                #expect(response.value.content == [.text(expectedValue)], "Unexpected result from \(name)")
            }
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }
}
#endif
