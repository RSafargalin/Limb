#if os(macOS)
import Darwin
import Dispatch
import Foundation
import LimbClient
import LimbCore
@testable import LimbStdioClient
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StdioExchangeTests {
    @Test(arguments: [false, true])
    func interruptedConnectReturnsBeforeHeldCleanup(cancel: Bool) async throws {
        let spawned = Mutex<Int32?>(nil)
        let completed = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let startup = StdioProcessStartup(
            .init(executable: "/bin/sleep", arguments: ["15"]),
            didSpawn: { pid in
                spawned.withLock { $0 = pid }
                _ = gate.wait(timeout: .now() + .seconds(8))
            }
        )

        let launch = Task {
            defer { completed.withLock { $0 = true } }
            return try await Client.connectStdio(startup, profile: .r2026_07_28, launchTimeout: .seconds(1))
        }
        try await waitFor("the launch worker enters the spawn hook") { spawned.withLock { $0 != nil } }
        let pid = try #require(spawned.withLock { $0 })
        if cancel {
            launch.cancel()
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !completed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.withLock { $0 })
        #expect(Darwin.kill(pid, 0) == 0)

        gate.signal()
        if cancel {
            await #expect(throws: CancellationError.self) { try await launch.value }
        } else {
            await #expect(throws: StdioProcessError.cleanupPending) { try await launch.value }
        }
        await startup.waitForCleanup()
        var status: Int32 = 0
        let waited = Darwin.waitpid(pid, &status, WNOHANG)
        let waitError = errno
        #expect(waited == -1 && waitError == ECHILD)
    }

    @Test func fragmentedAndCoalescedRepliesUseWireIDsAndKeepStderrSeparate() async throws {
        try await withChild(script: #"""
            read -r first
            read -r second
            first_id=$(wire_id "$first")
            second_id=$(wire_id "$second")
            first_marker=$(extract "$first" params.marker)
            second_marker=$(extract "$second" params.marker)

            # This would win correlation if stderr were mixed into the frame stream.
            reply "$first_id" '{"value":"stderr"}' >&2
            printf '{"jsonrpc":"2.0","id":%s,"res' "$second_id"
            /bin/sleep 0.05
            printf 'ult":{"marker":"%s","exact":9007199254740993}}\r\n{"jsonrpc":"2.0","id":%s,"result":{"marker":"%s","exact":9007199254740993}}\n' \
                "$second_marker" "$first_id" "$first_marker"
            """#) { client in
            async let first = client.request("example/echo", params: ["marker": "first"], timeout: .seconds(5))
            async let second = client.request("example/echo", params: ["marker": "second"], timeout: .seconds(5))
            let values = try await (first, second)
            #expect(values.0 == ["marker": "first", "exact": 9_007_199_254_740_993])
            #expect(values.1 == ["marker": "second", "exact": 9_007_199_254_740_993])
        }
    }

    @Test func invalidFramesOnlyFailTheCorrelatedMalformedReply() async throws {
        try await withChild(maxFrameBytes: 512, script: #"""
            read -r first
            read -r second
            if [ "$(extract "$first" method)" = "bad" ]; then
                bad=$(wire_id "$first"); good=$(wire_id "$second")
            else
                bad=$(wire_id "$second"); good=$(wire_id "$first")
            fi

            printf 'not JSON\n'
            reply '"unissued-request-id"' '{"value":"wrong ID"}'
            printf '{"jsonrpc":"2.0","error":{"code":-32700,"message":"uncorrelated"}}\n'
            printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"uncorrelated"}}\n'
            printf '{"jsonrpc":"2.0","id":[],"error":{"code":-32700,"message":"invalid ID"}}\n'
            printf '{"jsonrpc":"2.0","id":%s,"result":false}%512s\n' "$good" ''
            printf '{"jsonrpc":"2.0","id":%s,"result":true,"error":{"code":-32603,"message":"both"}}\n' "$bad"
            reply "$good" '{"value":"survived"}'
            """#) { client in
            let malformed = Task { try await client.request("bad", timeout: .seconds(5)) }
            let sibling = Task { try await client.request("good", timeout: .seconds(5)) }
            await #expect(throws: ClientError.protocolViolation(.unknown)) { try await malformed.value }
            let result = try await sibling.value
            #expect(result.objectValue?["value"] == "survived")
        }
    }

    @Test func preservesRemoteError() async throws {
        try await withChild(script: #"""
            read -r line
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32042,"message":"rejected","data":{"why":"fixture"}}}\n' \
                "$(wire_id "$line")"
            """#) { client in
            let expected = MCPError(code: -32042, message: "rejected", data: ["why": "fixture"])
            await #expect(throws: expected) {
                try await client.request("reject", timeout: .seconds(5))
            }
        }
    }

    @Test func deliversTheCompleteFinalFrameAndDropsTheUnterminatedFrame() async throws {
        try await withChild(script: #"""
            read -r first
            read -r second
            if [ "$(extract "$first" method)" = "complete" ]; then
                complete=$(wire_id "$first"); partial=$(wire_id "$second")
            else
                complete=$(wire_id "$second"); partial=$(wire_id "$first")
            fi
            printf '{"jsonrpc":"2.0","id":%s,"result":{"value":"final"}}\n{"jsonrpc":"2.0","id":%s,"result":{"value":"unterminated"}}' \
                "$complete" "$partial"
            """#) { client in
            async let complete = client.request("complete", timeout: .seconds(5))
            let partial = Task { try await client.request("partial", timeout: .seconds(5)) }
            let result = try await complete
            #expect(result.objectValue?["value"] == "final")
            await #expect(throws: ClientError.connectionLost(.unknown)) { try await partial.value }
        }
    }

    @Test func modernRequestSetsProtocolVersionAndPreservesOtherMetadata() async throws {
        try await withChild(script: #"""
            read -r line
            reply "$(wire_id "$line")" "$line"
            """#) { client in
            let response = try await client.request(
                "inspect",
                params: ["argument": true, "_meta": [MetaKey.protocolVersion: "2025-11-25", "example.test/trace": "abc"]],
                timeout: .seconds(5)
            )
            let params = try #require(response.objectValue?["params"]?.objectValue)
            #expect(params["argument"] == true)
            #expect(params["_meta"] == [MetaKey.protocolVersion: "2026-07-28", "example.test/trace": "abc"])
        }
    }

    @Test(arguments: [RevisionProfile.r2025_03_26, .r2025_06_18, .r2025_11_25, .r2026_07_28])
    func onlyMarch2025AcceptsBatchResponses(profile: RevisionProfile) async throws {
        try await withChild(profile: profile, script: #"""
            read -r line
            id=$(wire_id "$line")
            printf '[{"jsonrpc":"2.0","id":%s,"result":{"value":"batch"}}]\n' "$id"
            reply "$id" '{"value":"single"}'
            """#) { client in
            let result = try await client.request("inspect", timeout: .seconds(5))
            #expect(result.objectValue?["value"] == (profile == .r2025_03_26 ? "batch" : "single"))
        }
    }

    @Test(arguments: [RevisionProfile.r2025_03_26, .r2025_11_25])
    func unhandledLegacyRequestsUseTheIncomingIDWithoutCompletingTheClientRequest(
        profile: RevisionProfile
    ) async throws {
        let batch = profile == .r2025_03_26
        try await withChild(profile: profile, arguments: [batch ? "batch" : "single"], script: #"""
            read -r line
            id=$(wire_id "$line")
            if [ "$1" = "batch" ]; then
                printf '[{"jsonrpc":"2.0","id":%s,"method":"fixture/unsupported"},{"jsonrpc":"2.0","id":"reverse-two","method":"fixture/unsupported"}]\n' "$id"
            else
                printf '{"jsonrpc":"2.0","id":%s,"method":"fixture/unsupported"}\n' "$id"
            fi
            read -r reverse
            result=$(printf '{"originalID":%s,"reverse":%s}' "$id" "$reverse")
            reply "$id" "$result"
            """#) { client in
            let value = try await client.request("forward", timeout: .seconds(5))
            let result = try #require(value.objectValue)
            let originalID = try #require(result["originalID"])
            let reverse = try #require(result["reverse"])
            let responses = batch ? try #require(reverse.arrayValue) : [reverse]
            let expectedIDs: [JSONValue] = batch ? [originalID, "reverse-two"] : [originalID]
            try #require(responses.count == expectedIDs.count)
            for (response, expectedID) in zip(responses, expectedIDs) {
                let object = try #require(response.objectValue)
                #expect(object["jsonrpc"] == "2.0")
                #expect(object["id"] == expectedID)
                #expect(object["error"]?.objectValue?["code"] == -32601)
                #expect(object["result"] == nil)
            }
        }
    }

    @Test func queuedTimeoutReleasesCapacityWhileThePipeIsBlocked() async throws {
        try await withTemporaryDirectory { directory in
            let ready = directory.appendingPathComponent("pid")
            try await withChild(maxPending: 2, arguments: [ready.path], script: #"""
                /bin/dd bs=1 count=1 of=/dev/null 2>/dev/null
                printf '%s\n' "$$" > "$1"
                exec /bin/sleep 20
                """#) { client in
                let request = Task {
                    try await client.request(
                        "large", params: ["payload": .string(String(repeating: "x", count: 2 * 1024 * 1024))],
                        timeout: .seconds(5)
                    )
                }
                try await waitFor("child consumes the first byte of the large request") {
                    (try? String(contentsOf: ready, encoding: .utf8))?.hasSuffix("\n") == true
                }
                let contents = try String(contentsOf: ready, encoding: .utf8)
                let pid = try #require(Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
                try #require(pid > 0)

                await #expect(throws: ClientError.timedOut(.notSent)) {
                    try await client.request("queued", timeout: .milliseconds(150))
                }
                await #expect(throws: ClientError.timedOut(.notSent)) {
                    let deadline = ContinuousClock.now + .seconds(1)
                    while true {
                        do {
                            return try await client.request("next", timeout: .milliseconds(150))
                        } catch ClientError.overloaded where ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                }
                #expect(Darwin.kill(pid, 0) == 0)
                await #expect(throws: ClientError.timedOut(.unknown)) { try await request.value }
                try await waitFor("generation closes and reaps the child after the partial write") {
                    Darwin.kill(pid, 0) == -1 && errno == ESRCH
                }
                await #expect(throws: ClientError.closed) {
                    let deadline = ContinuousClock.now + .seconds(2)
                    while true {
                        do {
                            return try await client.request("after-partial-write", timeout: .seconds(1))
                        } catch let error as ClientError where
                            (error == .exchangeLost(.notSent) || error == .connectionLost(.notSent))
                            && ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                }
            }
        }
    }

    @Test func cancellingAPartialWriteFinishesTheFrameBeforeSendingCancellation() async throws {
        try await withTemporaryDirectory { directory in
            let firstByte = directory.appendingPathComponent("first-byte")
            let ready = directory.appendingPathComponent("ready")
            let resume = directory.appendingPathComponent("resume")
            let cancellation = directory.appendingPathComponent("cancellation")
            let extra = directory.appendingPathComponent("extra")
            try await withChild(
                arguments: [firstByte.path, ready.path, resume.path, cancellation.path, extra.path],
                script: #"""
                    /bin/dd bs=1 count=1 of="$1" 2>/dev/null
                    printf 'ready\n' > "$2"
                    while [ ! -f "$3" ]; do /bin/sleep 0.01; done
                    read -r rest
                    original="$(/bin/cat "$1")$rest"
                    [ "$(extract "$original" method)" = "large" ]
                    payload=$(extract "$original" params.payload)
                    read -r notification
                    printf '%s\n' "$notification" > "$4"
                    read -r sibling
                    [ "$(extract "$sibling" method)" = "probe" ]
                    result=$(printf '{"originalID":%s,"payloadLength":%s}' "$(wire_id "$original")" "${#payload}")
                    reply "$(wire_id "$sibling")" "$result"
                    while read -r line; do printf '%s\n' "$line" >> "$5"; done
                    """#
            ) { client in
                let payloadLength = 1024 * 1024
                let request = Task {
                    try await client.request(
                        "large", params: ["payload": .string(String(repeating: "x", count: payloadLength))],
                        timeout: .seconds(10)
                    )
                }
                try await waitFor("the child reads the first byte before blocking") {
                    (try? String(contentsOf: ready, encoding: .utf8)) == "ready\n"
                }
                request.cancel()
                request.cancel()
                try Data().write(to: resume)
                await #expect(throws: ClientError.cancelled(.unknown)) { try await request.value }
                try await waitFor("the child reads the complete cancellation frame") {
                    (try? String(contentsOf: cancellation, encoding: .utf8))?.hasSuffix("\n") == true
                }
                let probe = try await client.request("probe", timeout: .seconds(5))
                let original = try #require(probe.objectValue)
                let expectedLength = try JSON.parse(String(payloadLength))
                #expect(original["payloadLength"] == expectedLength)
                let originalID = try #require(original["originalID"])
                let line = try String(contentsOf: cancellation, encoding: .utf8)
                let notification = try #require(try JSON.parse(line).objectValue)
                #expect(notification["jsonrpc"] == "2.0")
                #expect(notification["method"] == "notifications/cancelled")
                #expect(notification["id"] == nil)
                #expect(notification["params"]?.objectValue?["requestId"] == originalID)

                await client.close()
                #expect(!FileManager.default.fileExists(atPath: extra.path))
            }
        }
    }

    @Test func publishedCancellationSendsOneNotificationAndLeavesSiblingAlive() async throws {
        try await withTemporaryDirectory { directory in
            let received = directory.appendingPathComponent("received")
            let ready = directory.appendingPathComponent("ready")
            try await withChild(profile: .r2025_11_25, arguments: [ready.path, received.path], script: #"""
                read -r cancelled
                printf 'yes\n' > "$1"
                read -r sibling
                printf 'sibling\n' >> "$1"
                read -r notification
                printf '%s\n' "$notification" >> "$2"
                result=$(printf '{"value":%s}' "$(wire_id "$cancelled")")
                reply "$(wire_id "$sibling")" "$result"
                while read -r line; do printf '%s\n' "$line" >> "$2"; done
                """#) { client in
                let cancelled = Task { try await client.request("cancel-me", timeout: .seconds(5)) }
                try await waitFor("child reads first request") {
                    (try? String(contentsOf: ready, encoding: .utf8)) == "yes\n"
                }
                let sibling = Task { try await client.request("sibling", timeout: .seconds(5)) }
                try await waitFor("child reads sibling request") {
                    (try? String(contentsOf: ready, encoding: .utf8)) == "yes\nsibling\n"
                }
                cancelled.cancel()
                cancelled.cancel()
                await #expect(throws: ClientError.cancelled(.unknown)) { try await cancelled.value }
                let result = try await sibling.value
                let cancelledID = try #require(result.objectValue?["value"])
                await client.close()

                let lines = try String(contentsOf: received, encoding: .utf8).split(separator: "\n")
                try #require(lines.count == 1)
                let notification = try #require(try JSON.parse(String(lines[0])).objectValue)
                #expect(notification["jsonrpc"] == "2.0")
                #expect(notification["method"] == "notifications/cancelled")
                #expect(notification["id"] == nil)
                #expect(notification["params"]?.objectValue?["requestId"] == cancelledID)
            }
        }
    }

    @Test func cancellingPublishedLegacyInitializeClosesTheProcessWithoutANotification() async throws {
        try await withTemporaryDirectory { directory in
            let ready = directory.appendingPathComponent("pid")
            let received = directory.appendingPathComponent("received")
            try await withChild(profile: .r2025_11_25, arguments: [ready.path, received.path], script: #"""
                read -r initialize
                printf '%s\n' "$$" > "$1"
                while read -r line; do printf '%s\n' "$line" >> "$2"; done
                """#) { client in
                let initialize = Task { try await client.request("initialize", timeout: .seconds(5)) }
                try await waitFor("child reads initialize") {
                    (try? String(contentsOf: ready, encoding: .utf8))?.hasSuffix("\n") == true
                }
                let contents = try String(contentsOf: ready, encoding: .utf8)
                let pid = try #require(Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
                try #require(pid > 0)
                initialize.cancel()
                await #expect(throws: ClientError.cancelled(.unknown)) { try await initialize.value }
                try await waitFor("legacy bootstrap process is reaped") {
                    Darwin.kill(pid, 0) == -1 && errno == ESRCH
                }
                #expect(!FileManager.default.fileExists(atPath: received.path))
            }
        }
    }

    @Test func outgoingLimitExcludesTheNewlineAndRejectsOversizedRequests() async throws {
        try await withChild(maxFrameBytes: 512, script: #"""
            read -r line
            reply "$(wire_id "$line")" "$(printf '{"value":"%s"}' "${#line}")"
            read -r line
            [ "$(extract "$line" method)" = "measure" ]
            reply "$(wire_id "$line")" "$(printf '{"value":"%s"}' "${#line}")"
            """#) { client in
            let measured = try await client.request("measure", params: ["payload": ""], timeout: .seconds(5))
            let byteCount = try #require(measured.objectValue?["value"]?.stringValue)
            let baseline = try #require(Int(byteCount))
            try #require((1..<512).contains(baseline))
            await #expect(throws: ClientError.exchangeLost(.notSent)) {
                try await client.request(
                    "too-large", params: ["payload": .string(String(repeating: "z", count: 513))],
                    timeout: .seconds(5)
                )
            }
            let result = try await client.request(
                "measure", params: ["payload": .string(String(repeating: "z", count: 512 - baseline))],
                timeout: .seconds(5)
            )
            #expect(result.objectValue?["value"] == "512")
        }
    }

    @Test func closeIsIdempotentAndReapsTheChild() async throws {
        try await withChild(script: #"""
            read -r line
            reply "$(wire_id "$line")" "$(printf '{"value":"%s"}' "$$")"
            while read -r line; do :; done
            """#) { client in
            let response = try await client.request("pid", timeout: .seconds(5))
            let pidText = try #require(response.objectValue?["value"]?.stringValue)
            let pid = try #require(Int32(pidText))
            try #require(pid > 0)
            async let first: Void = client.close()
            async let second: Void = client.close()
            _ = await (first, second)
            await client.close()
            let status = Darwin.kill(pid, 0)
            let lookupError = errno
            #expect(status == -1 && lookupError == ESRCH)
            await #expect(throws: ClientError.closed) {
                try await client.request("after-close", timeout: .seconds(5))
            }
        }
    }
}

private func withChild(
    profile: RevisionProfile = .r2026_07_28,
    maxFrameBytes: Int = 8 * 1024 * 1024,
    maxPending: Int = 128,
    arguments: [String] = [],
    script: String,
    _ body: (Client) async throws -> Void
) async throws {
    let helpers = #"""
        extract() { printf '%s\n' "$1" | /usr/bin/plutil -extract "$2" raw -o - -; }
        wire_id() {
            case "$(printf '%s\n' "$1" | /usr/bin/plutil -type id -)" in
                string) printf '"%s"' "$(extract "$1" id)" ;;
                integer) extract "$1" id ;;
                *) return 1 ;;
            esac
        }
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
        """#
    let client = try await Client.connectStdio(
        .init(executable: "/bin/sh", arguments: ["-ec", helpers + "\n" + script, "fixture"] + arguments),
        profile: profile,
        maxFrameBytes: maxFrameBytes,
        maxPending: maxPending
    )
    do {
        try await body(client)
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}

private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func waitFor(_ event: String, condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for \(event)")
        try await Task.sleep(for: .milliseconds(10))
    }
}
#endif
