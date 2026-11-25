#if os(macOS)
import Darwin
import Foundation
import Limb
import Testing

private let fixtureCapabilities: JSONObject = [
    "tools": ["listChanged": true, "example.test/detail": ["limit": 4]],
    "resources": ["listChanged": false, "subscribe": true],
    "example.test/capability": ["ready": false],
]

@Suite(.timeLimit(.minutes(1)))
struct StdioNegotiationTests {
    @Test func modernDiscoveryExposesServerDetailsAndKeepsTheConnection() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            probe=$frame
            discover "$(wire_id "$probe")"
            receive
            report_frames "$(wire_id "$frame")" "[$probe,$frame]"
            drain
            """#)
        let client = try await fixture.connect()
        let version = client.protocolVersion.rawValue
        let serverName = client.serverInfo?.name
        let serverVersion = client.serverInfo?.version
        let serverCapabilities = client.serverCapabilities
        let frames = try await inspectAndClose(client)
        #expect(version == "2026-07-28")
        #expect(serverName == "negotiation-fixture")
        #expect(serverVersion == "2.3.4")
        #expect(serverCapabilities == fixtureCapabilities)
        try #require(frames.count == 2)
        expectModernRequest(frames[0], method: "server/discover")
        expectModernRequest(frames[1], method: "fixture/inspect")
        try expectDistinctIDs(frames)
        #expect(try fixture.pids().count == 1)
    }

    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25"], [false, true])
    func rejectionAndSilenceAcceptEachLegacyCounteroffer(version: String, silent: Bool) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            probe=$frame
            if [ "$3" = "reject" ]; then
                reject "$(wire_id "$probe")" '{"code":-32042,"message":"method refused"}'
            fi
            receive
            initialization=$frame
            initialize "$(wire_id "$initialization")" "$2"
            receive
            initialized=$frame
            receive
            report_frames "$(wire_id "$frame")" "[$probe,$initialization,$initialized,$frame]"
            drain
            """#, arguments: [version, silent ? "silent" : "reject"])

        let client = try await fixture.connect()
        let actualVersion = client.protocolVersion.rawValue
        let serverName = client.serverInfo?.name
        let serverCapabilities = client.serverCapabilities
        let frames = try await inspectAndClose(client)

        #expect(actualVersion == version)
        #expect(serverName == "negotiation-fixture")
        #expect(serverCapabilities == fixtureCapabilities)
        try #require(frames.count == 4)
        expectModernRequest(frames[0], method: "server/discover")
        expectLegacyInitialize(frames[1])
        #expect(frames[2]["jsonrpc"] == "2.0")
        #expect(frames[2]["method"] == "notifications/initialized")
        #expect(frames[2]["id"] == nil)
        #expect(frames[3]["method"] == "fixture/inspect")
        #expect(frames[3]["params"]?["_meta"]?[MetaKey.protocolVersion] == nil)
        try expectDistinctIDs([frames[0], frames[1], frames[3]])
        #expect(try fixture.pids().count == 1)
    }

    @Test func supportedVersionErrorRetriesModernOnceOnTheSameConnection() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            first=$frame
            reject "$(wire_id "$first")" '{"code":-32022,"message":"version","data":{"requested":"2026-07-28","supported":["2025-11-25","2026-07-28"]}}'
            receive
            retry=$frame
            discover "$(wire_id "$retry")"
            receive
            report_frames "$(wire_id "$frame")" "[$first,$retry,$frame]"
            drain
            """#)
        let client = try await fixture.connect()
        let version = client.protocolVersion.rawValue
        let frames = try await inspectAndClose(client)
        #expect(version == "2026-07-28")
        try #require(frames.count == 3)
        expectModernRequest(frames[0], method: "server/discover")
        expectModernRequest(frames[1], method: "server/discover")
        expectModernRequest(frames[2], method: "fixture/inspect")
        try expectDistinctIDs(frames)
        #expect(try fixture.pids().count == 1)
    }

    @Test(arguments: ["2025-03-26", "2025-06-18", "2025-11-25"])
    func answersServerPingBeforeInitializeResultAndAfterReady(version: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
            receive
            initialization=$frame
            printf '%s\n' '{"jsonrpc":"2.0","id":"bootstrap-ping","method":"ping"}'
            receive
            hello_pong=$frame
            initialize "$(wire_id "$initialization")" "$2"
            receive
            initialized=$frame
            printf '%s\n' '{"jsonrpc":"2.0","id":"ready-ping","method":"ping"}'
            receive
            first=$frame
            receive
            second=$frame
            if [ "$(wire_id "$first")" = '"ready-ping"' ]; then
                pong=$first
                app=$second
            else
                pong=$second
                app=$first
            fi
            report_frames "$(wire_id "$app")" "[$initialization,$hello_pong,$initialized,$pong,$app]"
            drain
            """#, arguments: [version], timeout: .seconds(3))
        let client = try await fixture.connect()
        #expect(client.protocolVersion.rawValue == version)
        let frames = try await inspectAndClose(client)
        try #require(frames.count == 5)
        expectLegacyInitialize(frames[0])
        #expect(frames[1] == ["jsonrpc": "2.0", "id": "bootstrap-ping", "result": [:]])
        #expect(frames[2]["method"] == "notifications/initialized")
        #expect(frames[3] == ["jsonrpc": "2.0", "id": "ready-ping", "result": [:]])
        #expect(frames[4]["method"] == "fixture/inspect")
        #expect(try fixture.pids().count == 1)
    }

    @Test(arguments: ["2025-03-26", "2025-11-25"])
    func bootstrapPingBatchRequiresABatchCapableNegotiatedVersion(version: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
            receive
            initialization=$frame
            printf '%s\n' '[{"jsonrpc":"2.0","id":"batch-ping","method":"ping"},{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"fixture"}},{"jsonrpc":"2.0","id":173,"method":"ping"}]'
            receive
            initialize "$(wire_id "$initialization")" "$2"
            drain
            """#, arguments: [version], timeout: .seconds(3))

        if version == "2025-03-26" {
            let client = try await fixture.connect()
            #expect(client.protocolVersion.rawValue == version)
            await client.close()
        } else {
            await expectFailure(.malformedResponse, from: fixture)
        }

        try await fixture.waitUntilReaped()
        #expect(try fixture.pids().count == 1)
        let frames = try fixture.frames()
        try #require(frames.count == (version == "2025-03-26" ? 4 : 3))
        expectModernRequest(frames[0], method: "server/discover")
        expectLegacyInitialize(frames[1])
        let pongs = try #require(frames[2].arrayValue)
        let expected: Set<JSONValue> = [
            ["jsonrpc": "2.0", "id": "batch-ping", "result": [:]],
            ["jsonrpc": "2.0", "id": 173, "result": [:]],
        ]
        #expect(pongs.count == 2)
        #expect(Set(pongs) == expected)
        if version == "2025-03-26" {
            #expect(frames[3]["method"] == "notifications/initialized")
            #expect(frames[3]["id"] == nil)
        }
    }

    @Test func coalescedBootstrapPingsEachFitTheFrameLimitAndPrecedeInitialized() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
            receive
            legacy_result=$(reply "$(wire_id "$frame")" '{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}')
            first_ping=$(printf '{"jsonrpc":"2.0","id":"%0300d","method":"ping"}' 1)
            second_ping=$(printf '{"jsonrpc":"2.0","id":"%0300d","method":"ping"}' 2)
            coalesce "$legacy_result" "$first_ping" "$second_ping"

            while receive; do
                case "$frame" in
                    *'"fixture/inspect"'*)
                        report_frames "$(wire_id "$frame")" '[]'
                        drain
                        break
                        ;;
                esac
            done
            """#, maxFrameBytes: 512)

        let client = try await fixture.connect()
        #expect(client.protocolVersion.rawValue == "2025-11-25")
        #expect(try await inspectAndClose(client).isEmpty)
        let frames = try fixture.frames()
        try #require(frames.count == 6)
        expectModernRequest(frames[0], method: "server/discover")
        expectLegacyInitialize(frames[1])
        let pongs: Set<JSONValue> = Set(["1", "2"].map { trailer in
            let id = String(repeating: "0", count: 299) + trailer
            return ["jsonrpc": "2.0", "id": .string(id), "result": [:]]
        })
        #expect(Set(frames[2...3]) == pongs)
        #expect(frames[4]["method"] == "notifications/initialized")
        #expect(frames[4]["id"] == nil)
        #expect(frames[5]["method"] == "fixture/inspect")
    }

    @Test(arguments: [
        #"reply "$(wire_id "$frame")" '{"resultType":"complete","supportedVersions":["2025-11-25","2025-06-18"],"capabilities":{},"ttlMs":0,"cacheScope":"public"}'"#,
        #"reject "$(wire_id "$frame")" '{"code":-32022,"message":"version","data":{"requested":"2026-07-28","supported":["2025-11-25","2025-06-18"]}}'"#,
    ])
    func legacyVersionsInModernResponseAreIncompatible(response: String) async throws {
        let fixture = try NegotiationFixture(script: "receive\n" + response + "\ndrain")
        await expectFailure(.unsupportedVersions(["2025-11-25", "2025-06-18"]), from: fixture)
        try await expectOnlyDiscovery(fixture)
    }

    @Test(arguments: [
        #"reply "$(wire_id "$frame")" '{"resultType":"complete","supportedVersions":["2026-07-28",17],"capabilities":{},"ttlMs":0,"cacheScope":"public"}'"#,
        #"reply "$(wire_id "$frame")" '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":[],"ttlMs":0,"cacheScope":"public"}'"#,
        #"reject "$(wire_id "$frame")" '{"code":-32022,"message":"version","data":{"requested":"2025-11-25","supported":["2026-07-28"]}}'"#,
        #"reject "$(wire_id "$frame")" '{"code":-32022,"message":"version","data":{"requested":"2026-07-28","supported":"2026-07-28"}}'"#,
    ])
    func malformedModernResponsesNeverFallback(response: String) async throws {
        let fixture = try NegotiationFixture(script: "receive\n" + response + "\ndrain")
        await expectFailure(.malformedResponse, from: fixture)
        try await expectOnlyDiscovery(fixture)
    }

    @Test(arguments: [
        #""cacheScope":"public""#,
        #""ttlMs":0"#,
        #""ttlMs":-1,"cacheScope":"public""#,
        #""ttlMs":0.5,"cacheScope":"public""#,
        #""ttlMs":"0","cacheScope":"public""#,
        #""ttlMs":0,"cacheScope":"Public""#,
        #""ttlMs":0,"cacheScope":false"#,
    ])
    func malformedDiscoveryCacheFieldsNeverFallback(cacheFields: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            result=$(printf '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},%s}' "$2")
            reply "$(wire_id "$frame")" "$result"
            drain
            """#, arguments: [cacheFields])
        await expectFailure(.malformedResponse, from: fixture)
        try await expectOnlyDiscovery(fixture)
    }

    @Test(arguments: ["120", "1.2e2"])
    func discoveryAcceptsPositiveTTLWithPrivateCacheScope(ttl: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            result=$(printf '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":%s,"cacheScope":"private"}' "$2")
            reply "$(wire_id "$frame")" "$result"
            drain
            """#, arguments: [ttl])
        let client = try await fixture.connect()
        #expect(client.protocolVersion.rawValue == "2026-07-28")
        await client.close()
        try await expectOnlyDiscovery(fixture)
    }

    @Test(arguments: [
        #"{"tools":true}"#,
        #"{"prompts":{"listChanged":"false"}}"#,
        #"{"resources":{"listChanged":1}}"#,
        #"{"resources":{"subscribe":null}}"#,
        #"{"logging":[]}"#,
    ], [false, true])
    func malformedKnownCapabilitiesFailInBothEras(capabilities: String, legacy: Bool) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            if [ "$3" = "legacy" ]; then
                reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
                receive
                result=$(printf '{"protocolVersion":"2025-11-25","serverInfo":{"name":"fixture","version":"1"},"capabilities":%s}' "$2")
            else
                result=$(printf '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":%s,"ttlMs":0,"cacheScope":"public"}' "$2")
            fi
            reply "$(wire_id "$frame")" "$result"
            drain
            """#, arguments: [capabilities, legacy ? "legacy" : "modern"])
        await expectFailure(.malformedResponse, from: fixture)
        try await fixture.waitUntilReaped()
        let frames = try fixture.frames()
        try #require(frames.count == (legacy ? 2 : 1))
        expectModernRequest(frames[0], method: "server/discover")
        if legacy { expectLegacyInitialize(frames[1]) }
    }

    @Test(arguments: [
        #""instructions":17"#,
        #""instructions":null"#,
        #""_meta":[]"#,
        #""_meta":null"#,
    ], [false, true])
    func malformedOptionalEnvelopeFieldsFailInBothEras(fields: String, legacy: Bool) async throws {
        let fixture = try fixtureWithBootstrapFields(fields, legacy: legacy)
        await expectFailure(.malformedResponse, from: fixture)
        try await fixture.waitUntilReaped()
        let frames = try fixture.frames()
        try #require(frames.count == (legacy ? 2 : 1))
        expectModernRequest(frames[0], method: "server/discover")
        if legacy { expectLegacyInitialize(frames[1]) }
    }

    @Test(arguments: [
        "null",
        "[]",
        #"{"version":"1"}"#,
        #"{"name":"fixture","version":1}"#,
    ])
    func malformedOptionalModernServerInfoNeverFallsBack(serverInfo: String) async throws {
        let fixture = try fixtureWithBootstrapFields(
            #""_meta":{"io.modelcontextprotocol/serverInfo":\#(serverInfo)}"#, legacy: false
        )
        await expectFailure(.malformedResponse, from: fixture)
        try await expectOnlyDiscovery(fixture)
    }

    @Test(arguments: [false, true])
    func serverInfoPreservesIcons(legacy: Bool) async throws {
        let fixture = try fixtureWithServerIcons(
            #"""
            [
              {"src":"https://example.test/dark.png","mimeType":"image/png","sizes":["48x48","96x96"],"theme":"dark"},
              {"src":"https://example.test/light.svg","theme":"light"},
              {"src":"https://example.test/icon.svg"}
            ]
            """#, legacy: legacy
        )
        let client = try await fixture.connect()
        let icons = client.serverInfo?.icons
        #expect(client.protocolVersion.rawValue == (legacy ? "2025-11-25" : "2026-07-28"))
        await client.close()
        let actual = try #require(icons)
        try #require(actual.count == 3)
        #expect(actual[0].src == "https://example.test/dark.png")
        #expect(actual[0].mimeType == "image/png")
        #expect(actual[0].sizes == ["48x48", "96x96"])
        #expect(actual[0].theme == .dark)
        #expect(actual[1].src == "https://example.test/light.svg")
        #expect(actual[1].theme == .light)
        #expect(actual[2].src == "https://example.test/icon.svg")
    }

    @Test(arguments: [
        "{}",
        "[null]",
        #"[{"mimeType":"image/png"}]"#,
        #"[{"src":42}]"#,
        #"[{"src":"https://example.test/icon.png","mimeType":false}]"#,
        #"[{"src":"https://example.test/icon.png","sizes":[48]}]"#,
        #"[{"src":"https://example.test/icon.png","theme":"Dark"}]"#,
    ], [false, true])
    func malformedServerIconsFailNegotiation(icons: String, legacy: Bool) async throws {
        let fixture = try fixtureWithServerIcons(icons, legacy: legacy)
        await expectFailure(.malformedResponse, from: fixture)
        try await fixture.waitUntilReaped()
        let frames = try fixture.frames()
        try #require(frames.count == (legacy ? 2 : 1))
        expectModernRequest(frames[0], method: "server/discover")
        if legacy { expectLegacyInitialize(frames[1]) }
    }

    private func fixtureWithServerIcons(_ icons: String, legacy: Bool) throws -> NegotiationFixture {
        try NegotiationFixture(script: #"""
            receive
            info=$(printf '{"name":"fixture","version":"1","icons":%s}' "$2")
            if [ "$3" = "legacy" ]; then
                reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
                receive
                result=$(printf '{"protocolVersion":"2025-11-25","serverInfo":%s,"capabilities":{}}' "$info")
            else
                result=$(printf '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"public","_meta":{"io.modelcontextprotocol/serverInfo":%s}}' "$info")
            fi
            reply "$(wire_id "$frame")" "$result"
            drain
            """#, arguments: [icons.replacingOccurrences(of: "\n", with: ""), legacy ? "legacy" : "modern"])
    }

    private func fixtureWithBootstrapFields(_ fields: String, legacy: Bool) throws -> NegotiationFixture {
        try NegotiationFixture(script: #"""
            receive
            if [ "$3" = "legacy" ]; then
                reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
                receive
                result=$(printf '{"protocolVersion":"2025-11-25","serverInfo":{"name":"fixture","version":"1"},"capabilities":{},%s}' "$2")
            else
                result=$(printf '{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"public",%s}' "$2")
            fi
            reply "$(wire_id "$frame")" "$result"
            drain
            """#, arguments: [fields, legacy ? "legacy" : "modern"])
    }

    @Test(arguments: ["-32020", "-32021"])
    func recognizedProtocolErrorNeverFallsBack(code: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            reject "$(wire_id "$frame")" "$(printf '{"code":%s,"message":"refused"}' "$2")"
            drain
            """#, arguments: [code])
        do {
            let client = try await fixture.connect()
            await client.close()
            Issue.record("A recognized protocol error unexpectedly completed negotiation")
        } catch let error as MCPError {
            #expect(String(error.code) == code)
        }
        try await expectOnlyDiscovery(fixture)
    }

    @Test func childEOFNeverFallsBack() async throws {
        let fixture = try NegotiationFixture(script: "receive")
        await expectFailure(.connectionLost, from: fixture)
        try await expectOnlyDiscovery(fixture)
    }

    @Test func discoveryFromSurvivingDescendantDoesNotMakeExitedServerReady() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            proof=$(discover "$(wire_id "$frame")")
            /usr/bin/perl -e '
                my ($server, $proof, $marker) = @ARGV;
                for (1..100) {
                    if (getppid() != $server) {
                        select(undef, undef, undef, 0.07);
                        open(my $file, ">", $marker) or exit 2;
                        close($file) or exit 2;
                        syswrite(STDOUT, "$proof\n");
                        exit 0;
                    }
                    select(undef, undef, undef, 0.002);
                }
                exit 1;
            ' "$$" "$proof" "$1/descendant-proof" &
            exit 0
            """#)
        await expectFailure(.connectionLost, from: fixture)
        let marker = fixture.directory.appendingPathComponent("descendant-proof")
        try await waitForNegotiationEvent("descendant attempts a reply after the server exits") {
            FileManager.default.fileExists(atPath: marker.path)
        }
        try await expectOnlyDiscovery(fixture)
    }

    @Test func oversizedUnterminatedFrameFailsBeforeDiscoveryTimeout() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            printf '%1025s' ''
            drain
            """#, timeout: .seconds(6), discoveryTimeout: .seconds(3), maxFrameBytes: 1024)
        let started = ContinuousClock.now
        await expectFailure(.frameTooLarge, from: fixture)
        #expect(started.duration(to: .now) < .seconds(3))
        try await expectOnlyDiscovery(fixture)
    }

    @Test(arguments: [
        #"{"protocolVersion":"2025-11-25","serverInfo":{"name":"fixture"},"capabilities":{}}"#,
        #"{"protocolVersion":"2025-11-25","serverInfo":{"name":"fixture","version":"1"},"capabilities":[]}"#,
    ])
    func invalidLegacyResultPreventsInitialized(result: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
            receive
            reply "$(wire_id "$frame")" "$2"
            drain
            """#, arguments: [result])
        await expectFailure(.malformedResponse, from: fixture)
        try await fixture.waitUntilReaped()
        let frames = try fixture.frames()
        try #require(frames.count == 2)
        expectLegacyInitialize(frames[1])
    }

    @Test(arguments: ["2026-07-28", "2024-11-05"])
    func legacyInitializeRejectsAnUnsupportedCounteroffer(version: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
            receive
            initialize "$(wire_id "$frame")" "$2"
            drain
            """#, arguments: [version])
        await expectFailure(.unsupportedVersions([version]), from: fixture)
        try await fixture.waitUntilReaped()
        let frames = try fixture.frames()
        try #require(frames.count == 2)
        expectLegacyInitialize(frames[1])
    }

    @Test(arguments: ["no-initialize-reply", "initialize-error", "coalesced-initialize-result"])
    func validLateDiscoverAfterInitializeRequiresAFreshProcess(initialReply: String) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            probe=$frame
            if [ ! -f "$1/initialized-attempt" ]; then
                receive
                : > "$1/initialized-attempt"
                probe_id=$(wire_id "$probe")
                initialize_id=$(wire_id "$frame")
                case "$2" in
                    initialize-error)
                        reject "$initialize_id" '{"code":-32603,"message":"initialize failed"}'
                        /bin/sleep 0.05
                        discover "$probe_id"
                        ;;
                    coalesced-initialize-result)
                        legacy_result=$(initialize "$initialize_id" "2025-11-25")
                        modern_result=$(discover "$probe_id")
                        coalesce "$legacy_result" "$modern_result"
                        ;;
                    *)
                        discover "$probe_id"
                        ;;
                esac
                drain
            else
                IFS= read -r previous_pid < "$1/pids"
                if kill -0 "$previous_pid" 2>/dev/null; then
                    exit 9
                fi
                discover "$(wire_id "$probe")"
                receive
                report_frames "$(wire_id "$frame")" "[$probe,$frame]"
                drain
            fi
            """#, arguments: [initialReply])

        let client = try await fixture.connect()
        let version = client.protocolVersion.rawValue
        let frames = try await inspectAndClose(client)
        #expect(version == "2026-07-28")
        try #require(frames.count == 2)
        expectModernRequest(frames[0], method: "server/discover")
        expectModernRequest(frames[1], method: "fixture/inspect")
        try expectDistinctIDs(frames)

        let pids = try fixture.pids()
        try #require(pids.count == 2)
        #expect(pids[0] != pids[1])
        try await fixture.waitUntilReaped()
        let received = try fixture.frames()
        try #require(received.count == 4)
        expectModernRequest(received[0], method: "server/discover")
        expectLegacyInitialize(received[1])
        expectModernRequest(received[2], method: "server/discover")
        expectModernRequest(received[3], method: "fixture/inspect")
        try expectDistinctIDs([received[0], received[1]])
    }

    @Test(arguments: [false, true])
    func lateDiscoverAfterInitializedKeepsLegacyConnection(malformed: Bool) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            probe=$frame
            receive
            initialization=$frame
            initialize "$(wire_id "$initialization")" "2025-06-18"
            # Wait for the full notifications/initialized frame before replying to the probe.
            receive
            initialized=$frame
            if [ "$2" = "malformed" ]; then
                reply "$(wire_id "$probe")" '[]'
            else
                discover "$(wire_id "$probe")"
            fi
            receive
            report_frames "$(wire_id "$frame")" "[$probe,$initialization,$initialized,$frame]"
            drain
            """#, arguments: [malformed ? "malformed" : "valid"])

        let client = try await fixture.connect()
        let frames = try await inspectAndClose(client)
        #expect(client.protocolVersion.rawValue == "2025-06-18")
        try #require(frames.count == 4)
        expectModernRequest(frames[0], method: "server/discover")
        expectLegacyInitialize(frames[1])
        #expect(frames[2]["jsonrpc"] == "2.0")
        #expect(frames[2]["method"] == "notifications/initialized")
        #expect(frames[2]["id"] == nil)
        #expect(frames[3]["method"] == "fixture/inspect")
        #expect(frames[3]["params"]?["_meta"]?[MetaKey.protocolVersion] == nil)
        #expect(try fixture.pids().count == 1)
        try #require(try fixture.frames().count == 4)
    }

    @Test func silentReplacementDoesNotFallbackAndUsesTheOriginalDeadline() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            probe=$frame
            if [ ! -f "$1/initialized-attempt" ]; then
                receive
                : > "$1/initialized-attempt"
                /bin/sleep 0.5
                discover "$(wire_id "$probe")"
            fi
            drain
            """#, timeout: .milliseconds(3_200), discoveryTimeout: .seconds(2))

        let started = ContinuousClock.now
        await expectFailure(.timedOut, from: fixture)
        #expect(started.duration(to: .now) < .seconds(4))
        try await fixture.waitUntilReaped()
        #expect(try fixture.pids().count == 2)
        let frames = try fixture.frames()
        try #require(frames.count == 3)
        expectModernRequest(frames[0], method: "server/discover")
        expectLegacyInitialize(frames[1])
        expectModernRequest(frames[2], method: "server/discover")
    }

    @Test func lateDiscoveryStopsAPartiallyWrittenInitializeAndKeepsTheOriginalDeadline() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            probe=$frame
            if [ ! -f "$1/initialize-prefix" ]; then
                /bin/dd bs=1 count=1 of="$1/initialize-prefix" 2>/dev/null
                /bin/sleep 0.4
                discover "$(wire_id "$probe")"
                exec /bin/sleep 15
            fi
            IFS= read -r previous_pid < "$1/pids"
            if kill -0 "$previous_pid" 2>/dev/null; then
                exit 9
            fi
            drain
            """#, timeout: .seconds(4), discoveryTimeout: .seconds(2),
            clientInfo: .init(name: "independent-client", version: String(repeating: "x", count: 2 * 1024 * 1024)))
        let started = ContinuousClock.now
        await expectFailure(.timedOut, from: fixture)
        #expect(started.duration(to: .now) < .milliseconds(4_500))
        try await fixture.waitUntilReaped()
        #expect(try fixture.pids().count == 2)
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("initialize-prefix")) == Data("{".utf8))
        let frames = try fixture.frames()
        try #require(frames.count == 2)
        for frame in frames {
            #expect(frame["method"] == "server/discover")
            #expect(frame["params"]?["_meta"]?[MetaKey.protocolVersion] == "2026-07-28")
        }
    }

    @Test(arguments: [false, true])
    func silentReplacementReportsOriginalInitializeError(proofFirst: Bool) async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            probe=$frame
            if [ ! -f "$1/initialized-attempt" ]; then
                receive
                : > "$1/initialized-attempt"
                failure=$(reject "$(wire_id "$frame")" '{"code":-32057,"message":"legacy policy refused initialization","data":{"fixture":true}}')
                proof=$(discover "$(wire_id "$probe")")
                if [ "$2" = "proof-first" ]; then
                    coalesce "$proof" "$failure"
                else
                    printf '%s\n' "$failure"
                    /bin/sleep 0.05
                    printf '%s\n' "$proof"
                fi
            fi
            drain
            """#, arguments: [proofFirst ? "proof-first" : "error-first"],
            timeout: .milliseconds(1_800), discoveryTimeout: .seconds(1))

        let original = MCPError(
            code: -32057,
            message: "legacy policy refused initialization",
            data: ["fixture": true]
        )
        await expectFailure(.recoveryTimedOut(original: original), from: fixture)
        try await fixture.waitUntilReaped()
        #expect(try fixture.pids().count == 2)
        let frames = try fixture.frames()
        try #require(frames.count == 3)
        expectModernRequest(frames[0], method: "server/discover")
        expectLegacyInitialize(frames[1])
        expectModernRequest(frames[2], method: "server/discover")
    }

    @Test func cancellationDuringInitializeReapsTheChildWithoutCancellationNotification() async throws {
        let fixture = try NegotiationFixture(script: #"""
            receive
            reject "$(wire_id "$frame")" '{"code":-32601,"message":"unknown method"}'
            receive
            : > "$1/awaiting-initialize-result"
            drain
            """#, timeout: .seconds(12))
        let launch = Task { try await fixture.connect() }
        defer { launch.cancel() }

        try await waitForNegotiationEvent("child reads initialize") {
            FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("awaiting-initialize-result").path)
        }
        let pid = try #require(try fixture.pids().first)
        #expect(Darwin.kill(pid, 0) == 0)
        let cancelled = ContinuousClock.now
        launch.cancel()
        do {
            let client = try await launch.value
            await client.close()
            Issue.record("Cancelled negotiation completed")
        } catch is CancellationError {
        }
        #expect(cancelled.duration(to: .now) < .seconds(4))
        try await fixture.waitUntilReaped()
        let frames = try fixture.frames()
        try #require(frames.count == 2)
        expectModernRequest(frames[0], method: "server/discover")
        expectLegacyInitialize(frames[1])
    }

    private func inspectAndClose(_ client: Client) async throws -> [JSONValue] {
        do {
            let result = try await client.request("fixture/inspect", timeout: .seconds(3))
            await client.close()
            return try #require(result["frames"]?.arrayValue)
        } catch {
            await client.close()
            throw error
        }
    }

    private func expectFailure(_ expected: StdioNegotiationError, from fixture: NegotiationFixture) async {
        do {
            let client = try await fixture.connect()
            await client.close()
            Issue.record("Expected negotiation to fail with \(expected)")
        } catch {
            #expect(error as? StdioNegotiationError == expected)
        }
    }

    private func expectOnlyDiscovery(_ fixture: NegotiationFixture) async throws {
        try await fixture.waitUntilReaped()
        #expect(try fixture.pids().count == 1)
        let frames = try fixture.frames()
        try #require(frames.count == 1)
        expectModernRequest(frames[0], method: "server/discover")
    }

    private func expectModernRequest(_ frame: JSONValue, method: String) {
        #expect(frame["jsonrpc"] == "2.0")
        #expect(frame["method"] == .string(method))
        let metadata = frame["params"]?["_meta"]
        #expect(metadata?[MetaKey.protocolVersion] == "2026-07-28")
        #expect(metadata?[MetaKey.clientCapabilities] == [:])
        #expect(metadata?[MetaKey.clientInfo] == ["name": "independent-client", "version": "5.6.7"])
    }

    private func expectLegacyInitialize(_ frame: JSONValue) {
        #expect(frame["jsonrpc"] == "2.0")
        #expect(frame["method"] == "initialize")
        let params = frame["params"]
        #expect(params?["protocolVersion"] == "2025-11-25")
        #expect(params?["capabilities"] == [:])
        #expect(params?["clientInfo"] == ["name": "independent-client", "version": "5.6.7"])
    }

    private func expectDistinctIDs(_ frames: [JSONValue]) throws {
        let ids = try frames.map { try #require($0["id"]) }
        #expect(Set(ids).count == frames.count)
    }
}

private final class NegotiationFixture: Sendable {
    let directory: URL
    private let server: StdioServer
    private let options: StdioClientOptions

    init(
        script: String,
        arguments: [String] = [],
        timeout: Duration = .seconds(6),
        discoveryTimeout: Duration = .seconds(1),
        maxFrameBytes: Int = 8 * 1024 * 1024,
        clientInfo: Implementation = .init(name: "independent-client", version: "5.6.7")
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("limb-negotiation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        server = StdioServer(
            executable: "/bin/sh",
            arguments: ["-ec", Self.helpers + "\n" + script, "fixture", directory.path] + arguments
        )
        options = StdioClientOptions(
            clientInfo: clientInfo,
            timeout: timeout,
            discoveryTimeout: discoveryTimeout,
            maxFrameBytes: maxFrameBytes
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func connect() async throws -> Client {
        try await Client.connect(stdio: server, options: options)
    }

    func pids() throws -> [Int32] {
        let lines = try String(contentsOf: directory.appendingPathComponent("pids"), encoding: .utf8).split(separator: "\n")
        return try lines.map { try #require(Int32($0)) }
    }

    func frames() throws -> [JSONValue] {
        let lines = try String(contentsOf: directory.appendingPathComponent("frames"), encoding: .utf8).split(separator: "\n")
        return try lines.map { try JSON.parse(String($0)) }
    }

    func waitUntilReaped() async throws {
        let pids = try pids()
        try #require(!pids.isEmpty)
        try await waitForNegotiationEvent("all fixture processes are reaped") {
            pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH }
        }
    }

    private static let helpers = #"""
        printf '%s\n' "$$" >> "$1/pids"
        transcript="$1/frames"
        receive() {
            IFS= read -r frame || return 1
            printf '%s\n' "$frame" >> "$transcript"
        }
        drain() { while receive; do :; done; }
        wire_id() {
            case "$(printf '%s\n' "$1" | /usr/bin/plutil -type id -)" in
                string) printf '"%s"' "$(printf '%s\n' "$1" | /usr/bin/plutil -extract id raw -o - -)" ;;
                integer) printf '%s\n' "$1" | /usr/bin/plutil -extract id raw -o - - ;;
                *) return 1 ;;
            esac
        }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        report_frames() { reply "$1" "$(printf '{"frames":%s}' "$2")"; }
        coalesce() {
            /usr/bin/perl -e '
                my $frames = join("\n", @ARGV) . "\n";
                syswrite(STDOUT, $frames) == length($frames) or exit 1;
            ' "$@"
        }
        reject() { printf '{"jsonrpc":"2.0","id":%s,"error":%s}\n' "$1" "$2"; }
        capabilities='{"tools":{"listChanged":true,"example.test/detail":{"limit":4}},"resources":{"listChanged":false,"subscribe":true},"example.test/capability":{"ready":false}}'
        discover() {
            reply "$1" "$(printf '{"resultType":"complete","supportedVersions":["2025-11-25","2026-07-28"],"capabilities":%s,"ttlMs":0,"cacheScope":"public","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"negotiation-fixture","version":"2.3.4"}}}' "$capabilities")"
        }
        initialize() {
            reply "$1" "$(printf '{"protocolVersion":"%s","serverInfo":{"name":"negotiation-fixture","version":"2.3.4"},"capabilities":%s}' "$2" "$capabilities")"
        }
        """#
}

private func waitForNegotiationEvent(_ event: String, condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for \(event)")
        try await Task.sleep(for: .milliseconds(10))
    }
}
#endif
