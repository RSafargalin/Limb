#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Limb
import Testing

// Random traffic: random chunking and pauses on the client's writing side, random read sizes
// and pauses on its reading side, random cancellations, garbage between the messages. The
// invariants at the end are the ones the specification states for any stdio session:
//
//   * every request that was not cancelled is answered exactly once, with the right content;
//   * a cancelled request is answered at most once ("MUST NOT send any further messages for
//     it" allows an answer that was already on its way), and a request that can only end by
//     being cancelled is never answered;
//   * every line the server wrote is one valid JSON-RPC message;
//   * after end of input the server finishes.

private typealias Client = IndependentStdioClient

private enum Expectation {
    case result                 // ping
    case text(String)
    case neverAnswered          // a `hold` that is cancelled
}

private let awkwardTexts = [
    "plain", "", "line\nbreak", "cr\r\nlf", "tab\t\"quote\" \\ backslash", "\u{2028}\u{2029}", "\u{0}\u{1F}", "\u{1F600}\u{10FFFF}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n", String(repeating: "\n", count: 300), "é\u{301}", "bom\u{FEFF}",
]

extension IndependentStdioTransportTests {
    @Suite struct Stress {
        @Test(arguments: 1...8)
        func randomTrafficKeepsEveryInvariant(seed: Int) throws {
            try randomTraffic(seed: seed)
        }

        /// The same with seeds nobody has run before. A failure names its seed; put it into
        /// the argument list above to replay the script (the timing will still differ).
        @Test func randomTrafficWithFreshSeedsKeepsEveryInvariant() throws {
            for _ in 0..<3 {
                try randomTraffic(seed: Int(UInt32.random(in: 9...UInt32.max)))
            }
        }

        private func randomTraffic(seed: Int) throws {
            var random = IndependentStdioRandom(UInt64(seed) &* 7919)
            let fixture = try independentStdioFixture {
                $0.budgets.maxQueuedRequests = 4096
                $0.shutdownGraceSeconds = 30
                if seed % 3 == 0 { $0.budgets.maxConcurrentHandlers = 3 }
                if seed % 4 == 0 { $0.budgets.maxOutboundBytes = 128 * 1024 }
            }
            let client = Client(fixture.server, channel: seed % 2 == 0 ? .socketpair : .pipes)
            defer { client.tearDown() }
            if seed % 4 >= 2 {
                independentStdioSetNonBlocking(client.serverInput)
                independentStdioSetNonBlocking(client.serverOutput)
            }
            client.start()
            #expect(client.initialize() == "2025-11-25")

            // The script.
            let requests = 260
            var expectations: [Int: Expectation] = [:]
            var cancelled: Set<Int> = []
            var holds: [Int: String] = [:]
            var garbageLines = 0
            var stream: [UInt8] = []
            var dueCancels: [(at: Int, id: Int)] = []
            for id in 1...requests {
                var cancelAfter: Int?
                switch random.below(10) {
                case 0, 1:
                    stream += Array(Client.requestLine(id, "ping").utf8)
                    expectations[id] = .result
                case 2, 3:
                    let text = random.chance(50) ? awkwardTexts[random.below(awkwardTexts.count)] : "echo \(id) " + String(repeating: "e", count: random.below(3000))
                    let arguments = try JSONSerialization.data(withJSONObject: ["text": text])
                    stream += Array(Client.callLine(id, "echo", String(decoding: arguments, as: UTF8.self)).utf8)
                    expectations[id] = .text(text)
                case 4, 5, 6:
                    let size = [0, 10, 2000, 31_000, 34_000, 120_000][random.below(6)] + random.below(500)
                    stream += Array(Client.callLine(id, "blob", #"{"size":\#(size),"seed":\#(id),"delayMs":\#(random.below(15))}"#).utf8)
                    expectations[id] = .text(independentStdioBlob(size: size, seed: id))
                    if random.chance(15) { cancelAfter = random.below(6) }
                case 7, 8:
                    stream += Array(Client.callLine(id, "nap", #"{"ms":\#(random.below(25)),"tag":"nap\#(id)"}"#).utf8)
                    expectations[id] = .text("woke nap\(id)")
                    if random.chance(15) { cancelAfter = random.below(6) }
                default:
                    stream += Array(Client.callLine(id, "hold", #"{"tag":"hold\#(id)"}"#).utf8)
                    expectations[id] = .neverAnswered
                    holds[id] = "hold\(id)"
                    cancelAfter = random.chance(50) ? 0 : random.below(8)
                }
                if let cancelAfter { dueCancels.append((id + cancelAfter, id)) }
                for due in dueCancels where due.at == id {
                    stream += Array(Client.cancelLine(due.id).utf8)
                    cancelled.insert(due.id)
                }
                dueCancels.removeAll { $0.at == id }
                // Noise between the messages.
                switch random.below(25) {
                case 0: stream += Array("\n\r\n".utf8)
                case 1:
                    stream += Array("this is not json\n".utf8)
                    garbageLines += 1
                case 2: stream += Array(#"{"jsonrpc":"2.0","method":"notifications/unknown","params":{}}"#.utf8) + [0x0D, 0x0A]
                case 3: stream += Array(Client.cancelLine(100_000 + id).utf8)  // a late or unknown cancellation
                default: break
                }
            }
            for due in dueCancels {
                stream += Array(Client.cancelLine(due.id).utf8)
                cancelled.insert(due.id)
            }

            // Writing it: random chunks and pauses, reading now and then, sometimes not at all.
            var offset = 0
            var sendFailed = false
            while offset < stream.count {
                let size: Int
                switch random.below(8) {
                case 0: size = 1
                case 1, 2: size = 2 + random.below(60)
                case 3, 4, 5: size = 100 + random.below(5000)
                default: size = 20_000 + random.below(100_000)
                }
                let end = Swift.min(stream.count, offset + size)
                if !client.send(Array(stream[offset..<end]), timeout: 60, absorb: false) {
                    sendFailed = true
                    break
                }
                offset = end
                if random.chance(30) { usleep(useconds_t(random.below(1500))) }
                if random.chance(40) { client.absorb(limit: 1 + random.below(60_000)) }
            }
            #expect(!sendFailed, "seed \(seed): the server stopped taking input at byte \(offset) of \(stream.count)")
            if seed % 2 == 1 { usleep(useconds_t(random.below(200_000))) }
            client.closeInput()

            // Reading everything, in pieces of random size.
            var answers: [Int: [[String: Any]]] = [:]
            var nullErrors = 0
            var strays: [String] = []
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                guard let message = client.readMessage(timeout: 0.3, chunk: 1 + random.below(30_000)) else {
                    if client.hasReturned, !client.outputReadable(within: 0.05) { break }
                    continue
                }
                if random.chance(3) { usleep(useconds_t(random.below(2000))) }
                if message["method"] != nil {
                    strays.append("a message with a method: \(message["method"] ?? "")")
                } else if let id = Client.id(of: message) {
                    answers[id, default: []].append(message)
                } else if Client.isNullID(message), Client.errorCode(of: message) == -32700 {
                    nullErrors += 1
                } else {
                    strays.append("\(message)".prefix(200).description)
                }
            }
            #expect(client.hasReturned, "seed \(seed): run did not return after end of input")

            var problems: [String] = []
            for (id, expectation) in expectations.sorted(by: { $0.key < $1.key }) {
                let got = answers[id] ?? []
                if got.count > 1 { problems.append("\(id): answered \(got.count) times") }
                switch expectation {
                case .neverAnswered:
                    if !got.isEmpty { problems.append("\(id): a cancelled hold was answered") }
                case .result:
                    if got.count != 1 || got[0]["result"] == nil { problems.append("\(id): ping not answered") }
                case .text(let text):
                    if got.isEmpty {
                        if !cancelled.contains(id) { problems.append("\(id): not answered") }
                    } else if cancelled.contains(id), got[0]["error"] != nil {
                        // A cancelled request may have been answered with an error before the
                        // cancellation was seen; unusual but not forbidden.
                    } else if Client.text(of: got[0])?.unicodeScalars.elementsEqual(text.unicodeScalars) != true {
                        problems.append("\(id): wrong content (\(Client.text(of: got[0])?.utf8.count ?? -1) bytes for \(text.utf8.count))")
                    }
                }
            }
            for id in answers.keys where expectations[id] == nil { problems.append("\(id): an answer to a request that was never sent") }
            #expect(problems == [], "seed \(seed): \(problems.count) problems, first: \(problems.prefix(8))")
            #expect(nullErrors == garbageLines, "seed \(seed): \(nullErrors) parse errors for \(garbageLines) garbage lines")
            #expect(strays == [], "seed \(seed)")
            #expect(client.violations == [], "seed \(seed)")
            // Every hold whose handler started saw its cancellation. (One that was cancelled
            // while it still waited for a handler slot, or before its task ran, never starts.)
            let seen = Set(fixture.probe.cancelledTags)
            let begun = Set(fixture.probe.startedTags)
            let lost = holds.values.filter { begun.contains($0) && !seen.contains($0) }.sorted()
            #expect(lost == [], "seed \(seed): cancellations that never reached their request: \(lost)")
            #expect(fixture.log.all == [], "seed \(seed): \(fixture.log.all)")
        }
    }
}
