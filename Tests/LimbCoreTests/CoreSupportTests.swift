import Foundation
import LimbCore
import Testing

// Unit-level checks of the pieces underneath a connection: names compared by their bytes,
// request ids, the outgoing queue's accounting, the line framer at its size limit, and the
// classification of incoming messages.

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Strings Swift considers equal and a protocol must not: one letter under seven combining
/// marks of seven different combining classes, in every order (5040 of them).
private func equivalentSpellings() -> [String] {
    let marks: [Unicode.Scalar] = ["\u{334}", "\u{93C}", "\u{3099}", "\u{327}", "\u{31B}", "\u{316}", "\u{301}"]
    var spellings: [String] = []
    var order = Array(marks.indices)
    func permute(_ start: Int) {
        if start == order.count {
            var text = "a"
            for index in order { text.unicodeScalars.append(marks[index]) }
            spellings.append(text)
            return
        }
        for index in start..<order.count {
            order.swapAt(start, index)
            permute(start + 1)
            order.swapAt(start, index)
        }
    }
    permute(0)
    return spellings
}

// MARK: - ExactString and RequestID

@Suite struct ExactStringAndRequestIDTests {
    @Test func exactStringsCompareAndHashByBytes() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)  // Swift's view
        #expect(ExactString(composed) != ExactString(decomposed))
        #expect(ExactString(composed) == ExactString("caf\u{E9}"))
        #expect(ExactString(composed).hashValue == ExactString("caf" + "\u{E9}").hashValue)
        #expect(ExactString(composed).text == composed)
        #expect(Array(ExactString(decomposed).text.utf8) == Array(decomposed.utf8))
        // Equal bytes, however the string came to be.
        let bridged = NSString(string: "caf\u{E9} \u{1F600}") as String
        var built = ""
        for scalar in "caf\u{E9} \u{1F600}".unicodeScalars { built.unicodeScalars.append(scalar) }
        #expect(ExactString(bridged) == ExactString(built))
        #expect(ExactString(bridged).hashValue == ExactString(built).hashValue)
        #expect(Set([ExactString(bridged), ExactString(built), ExactString("caf\u{E9} \u{1F600}")]).count == 1)
        // Nothing is folded: case, width, compatibility forms, trailing and embedded oddities.
        let distinct = [
            "", " ", "a", "A", "a ", " a", "a\u{0}", "\u{0}a", "\u{0}", "\u{0}\u{0}", "\u{E9}", "e\u{301}", "\u{212B}", "\u{C5}", "A\u{30A}", "\u{FB01}", "fi",
            "\u{FF21}", "\u{FEFF}a", "a\u{FEFF}", "ab", "ba", "a\u{200D}", "\u{1F600}", "\u{1F600}\u{FE0F}",
        ]
        let set = Set(distinct.map(ExactString.init))
        #expect(set.count == distinct.count)
        for text in distinct { #expect(set.contains(ExactString(text)), "\(text.unicodeScalars.map(\.value))") }
        var table: [ExactString: Int] = [:]
        for (index, text) in distinct.enumerated() { table[ExactString(text)] = index }
        for (index, text) in distinct.enumerated() { #expect(table[ExactString(text)] == index) }
    }

    /// Thousands of spellings of one canonically equivalent string are thousands of names, and
    /// looking them up does not degrade into comparing each with every other.
    @Test func manyEquivalentSpellingsStayApartAndCheap() {
        let spellings = equivalentSpellings()
        #expect(Set(spellings).count == 1)
        let clock = ContinuousClock()
        var set = Set<ExactString>()
        let elapsed = clock.measure {
            for round in 0..<20 {
                for text in spellings { set.insert(ExactString(round == 0 ? text : String(text))) }
            }
        }
        #expect(set.count == 5040)
        #expect(spellings.allSatisfy { set.contains(ExactString($0)) })
        #expect(elapsed < .seconds(5), "100,800 insertions took \(elapsed)")
    }

    @Test func requestIDs() {
        let composed = RequestID("caf\u{E9}")
        let decomposed = RequestID("cafe\u{301}")
        // String ids are the same id only when they are the same bytes.
        #expect(composed != decomposed)
        #expect(composed == RequestID("caf\u{E9}"))
        #expect(composed.hashValue == RequestID("caf\u{E9}").hashValue)
        #expect(Set([composed, decomposed, RequestID("caf\u{E9}")]).count == 2)
        var owners: [RequestID: String] = [composed: "first", decomposed: "second"]
        #expect(owners[RequestID("cafe\u{301}")] == "second")
        owners[RequestID("caf\u{E9}")] = nil
        #expect(owners.count == 1 && owners[decomposed] == "second")
        // A string and a number never meet.
        #expect(RequestID("1") != RequestID(1))
        #expect(Set([RequestID("1"), RequestID(1)]).count == 2)
        #expect(RequestID("") != RequestID(0))
        // Numbers compare as numbers, and equal numbers hash alike.
        let one = RequestID(json: 1)
        let onePointZero = RequestID(json: 1.0)
        #expect(one != nil && one == onePointZero && one?.hashValue == onePointZero?.hashValue)
        #expect(RequestID(1) != RequestID(2))
        #expect(RequestID(json: 9007199254740993) != RequestID(json: 9007199254740992))
        // Only strings and numbers are ids.
        for value: JSONValue in [nil, true, [], [:], [1], ["id": 1]] { #expect(RequestID(json: value) == nil) }
        // An id goes back out exactly as it came in.
        for text in ["7", "-7", "0", "\"7\"", "\"\"", "\"caf\u{E9}\"", "\"cafe\u{301}\"", "\"a\\nb\"", "9223372036854775807"] {
            guard let value = try? JSON.parse(text), let id = RequestID(json: value) else {
                Issue.record("\(text) is not an id")
                continue
            }
            #expect(id.json == value)
            var writer = JSONWriter()
            writer.write(id)
            #expect(writer.bytes == value.encoded())
        }
        #expect(RequestID(5).description == "5" && RequestID("five").description == "five")
        let literal: RequestID = 5
        let text: RequestID = "five"
        #expect(literal == RequestID(5) && text == RequestID("five"))
        // Every one of 5040 equivalent spellings is an id of its own.
        let ids = equivalentSpellings().map { RequestID($0) }
        #expect(Set(ids).count == 5040)
    }
}

// MARK: - OutboundQueue

/// The queue's accounting, written down a second time and as plainly as possible.
private struct QueueModel {
    struct Entry {
        var frame: [UInt8]
        var key: Int?
        var isProgress: Bool
        var isUrgent: Bool
    }

    let reserve: Int
    var entries: [Entry] = []
    /// Bytes queued or taken and not yet written, by kind.
    var ordinary = 0
    var urgent = 0
    var takenOrdinary = 0
    var takenUrgent = 0
    var closed = false

    mutating func enqueue(_ frame: [UInt8], key: Int?, urgent isUrgent: Bool, replacesProgress: Bool) -> Bool {
        if closed { return false }
        if isUrgent {
            // Urgent frames answer to the reserve alone.
            guard urgent + frame.count <= reserve else { return false }
            urgent += frame.count
            entries.append(Entry(frame: frame, key: key, isProgress: false, isUrgent: true))
            return true
        }
        if replacesProgress, let key, let index = entries.lastIndex(where: { $0.isProgress && $0.key == key }) {
            // One queued progress frame per request: the newer value takes its place.
            ordinary += frame.count - entries[index].frame.count
            entries[index].frame = frame
            return true
        }
        ordinary += frame.count
        entries.append(Entry(frame: frame, key: key, isProgress: replacesProgress, isUrgent: false))
        return true
    }

    mutating func discard(key: Int) {
        for entry in entries where entry.key == key {
            if entry.isUrgent { urgent -= entry.frame.count } else { ordinary -= entry.frame.count }
        }
        entries.removeAll { $0.key == key }
    }

    mutating func take() -> [[UInt8]] {
        for entry in entries {
            if entry.isUrgent { takenUrgent += entry.frame.count } else { takenOrdinary += entry.frame.count }
        }
        defer { entries = [] }
        return entries.map(\.frame)
    }

    mutating func didWrite() {
        ordinary -= takenOrdinary
        urgent -= takenUrgent
        takenOrdinary = 0
        takenUrgent = 0
    }
}

@Suite struct OutboundQueueTests {
    /// Request keys as the model names them (by position) and as the queue sees them. The
    /// second is the first written another way: the same request. The last two are different
    /// requests that `String` would take for one.
    static let keys: [(model: Int, id: RequestID)] = [
        (0, RequestID(1)), (0, RequestID(json: 1.0)!), (1, RequestID(2)), (2, RequestID("a")), (3, RequestID("1")),
        (4, RequestID("caf\u{E9}")), (5, RequestID("cafe\u{301}")),
    ]

    /// Random interleavings of everything a connection does with its queue, against the model:
    /// the same answers, the same frames in the same order, and the same idea of how many
    /// bytes are outstanding at every step.
    @Test func randomInterleavingsAgreeWithTheModel() {
        var generator = SplitMix64(state: 0x5155_4555)
        for scenario in 0..<300 {
            let budget = Int.random(in: 0...200, using: &generator)
            let reserve = Int.random(in: 0...120, using: &generator)
            let queue = OutboundQueue(budgetBytes: budget, urgentReserveBytes: reserve)
            var model = QueueModel(reserve: reserve)
            var serial: UInt32 = 0
            var problems: [String] = []
            func check(_ step: String) {
                if queue.isOverBudget != (model.ordinary > budget) {
                    problems.append("\(step): over budget \(queue.isOverBudget), model has \(model.ordinary) ordinary bytes against \(budget)")
                }
                let usage = queue.usage
                if usage != (model.ordinary, model.urgent, model.entries.count) {
                    problems.append("\(step): usage \(usage), model \((model.ordinary, model.urgent, model.entries.count))")
                }
            }
            for step in 0..<Int.random(in: 20...400, using: &generator) {
                switch Int.random(in: 0..<20, using: &generator) {
                case 0..<11:
                    // A frame nobody else has: its serial number, then padding.
                    serial += 1
                    let size = Int.random(in: 4...40, using: &generator)
                    let frame = withUnsafeBytes(of: serial) { Array($0) } + [UInt8](repeating: UInt8(truncatingIfNeeded: serial), count: size - 4)
                    let key = Int.random(in: 0..<4, using: &generator) == 0 ? nil : Self.keys.randomElement(using: &generator)
                    let urgent = Int.random(in: 0..<4, using: &generator) == 0
                    let progress = Int.random(in: 0..<3, using: &generator) == 0
                    let accepted = queue.enqueue(frame, key: key?.id, urgent: urgent, replacesProgress: progress)
                    let expected = model.enqueue(frame, key: key?.model, urgent: urgent, replacesProgress: progress)
                    if accepted != expected { problems.append("step \(step): enqueue \(accepted), model \(expected)") }
                case 11..<14:
                    let key = Self.keys.randomElement(using: &generator)!
                    queue.discard(key: key.id)
                    model.discard(key: key.model)
                case 14..<17:
                    let batch = queue.takeAvailable()
                    let expected = model.take()
                    if batch != expected { problems.append("step \(step): took \(batch.count) frames, model \(expected.count)") }
                case 17..<19:
                    queue.didWrite(bytes: 0)
                    model.didWrite()
                default:
                    // The blocking form, when it would not block.
                    if !model.entries.isEmpty, queue.take() != model.take() { problems.append("step \(step): take() disagrees") }
                }
                check("step \(step)")
            }
            // Wind down: everything taken and written, and the books are at zero — exactly.
            if queue.takeAvailable() != model.take() { problems.append("final batch disagrees") }
            queue.didWrite(bytes: 0)
            model.didWrite()
            if model.ordinary != 0 || model.urgent != 0 { problems.append("the model itself is off: \(model.ordinary), \(model.urgent)") }
            if queue.isOverBudget { problems.append("over budget with nothing outstanding") }
            if queue.usage != (0, 0, 0) { problems.append("something is still on the books: \(queue.usage)") }
            if !queue.enqueue([UInt8](repeating: 1, count: budget)) || queue.isOverBudget { problems.append("a frame of the whole budget does not fit an empty queue") }
            if !queue.enqueue([2]) || !queue.isOverBudget { problems.append("one byte beyond the budget went unnoticed") }
            if !queue.enqueue([UInt8](repeating: 3, count: reserve), urgent: true) { problems.append("an urgent frame of the whole reserve was refused") }
            if queue.enqueue([4], urgent: true) { problems.append("an urgent byte beyond the reserve was accepted") }
            // Closed: nothing more goes in, what is queued still comes out, and then nothing.
            queue.close()
            if queue.enqueue([5]) || queue.enqueue([6], urgent: true) { problems.append("a closed queue accepted a frame") }
            if queue.take()?.count != 3 { problems.append("a closed queue did not hand over what it held") }
            if queue.take() != nil { problems.append("a closed, empty queue handed something over") }
            #expect(problems.isEmpty, "scenario \(scenario): \(problems.prefix(4))")
            if !problems.isEmpty { break }
        }
    }

    @Test func urgentFramesAnswerToTheReserveAlone() {
        let queue = OutboundQueue(budgetBytes: 10, urgentReserveBytes: 8)
        // Ordinary output, however far over its budget, takes nothing from the reserve.
        #expect(queue.enqueue([UInt8](repeating: 0, count: 10_000)))
        #expect(queue.isOverBudget)
        #expect(queue.enqueue([1, 2, 3, 4, 5], urgent: true))
        #expect(queue.enqueue([6, 7, 8], urgent: true))
        #expect(!queue.enqueue([9], urgent: true))
        // And urgent output is not what `isOverBudget` is about.
        let other = OutboundQueue(budgetBytes: 4, urgentReserveBytes: 100)
        #expect(other.enqueue([UInt8](repeating: 0, count: 100), urgent: true))
        #expect(!other.isOverBudget)
        // The reserve is given back when the frames are written, not when they are taken.
        #expect(queue.takeAvailable().map(\.count) == [10_000, 5, 3])
        #expect(!queue.enqueue([9], urgent: true))
        #expect(queue.isOverBudget)
        queue.didWrite(bytes: 10_008)
        #expect(!queue.isOverBudget)
        #expect(queue.enqueue([UInt8](repeating: 9, count: 8), urgent: true))
        // A withdrawn urgent frame gives its bytes back at once.
        let third = OutboundQueue(budgetBytes: 4, urgentReserveBytes: 4)
        #expect(third.enqueue([1, 2, 3, 4], key: 7, urgent: true))
        #expect(!third.enqueue([5], urgent: true))
        third.discard(key: 7)
        #expect(third.enqueue([5, 6, 7, 8], urgent: true))
        #expect(third.takeAvailable() == [[5, 6, 7, 8]])
    }

    @Test func oneQueuedProgressFramePerRequest() {
        let queue = OutboundQueue(budgetBytes: 1000)
        let composed = RequestID("caf\u{E9}")
        let decomposed = RequestID("cafe\u{301}")
        #expect(queue.enqueue([1], key: 1))
        for value in 0..<1000 {
            #expect(queue.enqueue([10, UInt8(value % 200)], key: 1, urgent: false, replacesProgress: true))
            #expect(queue.enqueue([20, UInt8(value % 200), 0], key: composed, urgent: false, replacesProgress: true))
            #expect(queue.enqueue([30, UInt8(value % 200), 0, 0], key: decomposed, urgent: false, replacesProgress: true))
        }
        #expect(queue.enqueue([2], key: 1))
        #expect(!queue.isOverBudget)
        // The latest value of each, in the place of the first; ordinary frames untouched.
        #expect(queue.takeAvailable() == [[1], [10, 199], [20, 199, 0], [30, 199, 0, 0], [2]])
        // Once taken, a progress frame is out of reach: the next one queues anew.
        #expect(queue.enqueue([10, 7], key: 1, urgent: false, replacesProgress: true))
        #expect(queue.enqueue([10, 8], key: 1, urgent: false, replacesProgress: true))
        #expect(queue.takeAvailable() == [[10, 8]])
        // Withdrawn with its request, and the next one starts over.
        #expect(queue.enqueue([10, 1], key: 1, urgent: false, replacesProgress: true))
        #expect(queue.enqueue([40], key: 2, urgent: false, replacesProgress: true))
        queue.discard(key: 1)
        #expect(queue.enqueue([10, 2], key: 1, urgent: false, replacesProgress: true))
        #expect(queue.takeAvailable() == [[40], [10, 2]])
        // A longer or shorter replacement moves the byte count by the difference.
        let tight = OutboundQueue(budgetBytes: 10)
        #expect(tight.enqueue([UInt8](repeating: 0, count: 4), key: 1, urgent: false, replacesProgress: true))
        #expect(tight.enqueue([UInt8](repeating: 0, count: 11), key: 1, urgent: false, replacesProgress: true))
        #expect(tight.isOverBudget)
        #expect(tight.enqueue([UInt8](repeating: 0, count: 10), key: 1, urgent: false, replacesProgress: true))
        #expect(!tight.isOverBudget)
        #expect(tight.takeAvailable().map(\.count) == [10])
        // Without a key there is nothing to replace: each is kept.
        #expect(tight.enqueue([1], key: nil, urgent: false, replacesProgress: true))
        #expect(tight.enqueue([2], key: nil, urgent: false, replacesProgress: true))
        #expect(tight.takeAvailable() == [[1], [2]])
    }

    @Test func handlersWaitWhileTheQueueIsOverItsBudget() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var raised = false
            func raise() { lock.withLock { raised = true } }
            var isRaised: Bool { lock.withLock { raised } }
        }
        let queue = OutboundQueue(budgetBytes: 10)
        // Within the budget nobody waits.
        #expect(queue.enqueue([UInt8](repeating: 0, count: 10)))
        await queue.waitForCapacity()
        // Over it, a handler waits until what was written brings the queue back within it.
        #expect(queue.enqueue([1], key: 9))
        let resumed = Flag()
        let waiting = Task {
            await queue.waitForCapacity()
            resumed.raise()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!resumed.isRaised)
        // Taken is not written.
        #expect(queue.takeAvailable().count == 2)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!resumed.isRaised)
        queue.didWrite(bytes: 11)
        await waiting.value
        #expect(resumed.isRaised)
        // Withdrawing a cancelled request's frames frees waiters too.
        #expect(queue.enqueue([UInt8](repeating: 0, count: 8)))
        #expect(queue.enqueue([UInt8](repeating: 0, count: 8), key: 5))
        let second = Flag()
        let waitingAgain = Task {
            await queue.waitForCapacity()
            second.raise()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!second.isRaised)
        queue.discard(key: 5)
        await waitingAgain.value
        // And closing the queue lets everyone go.
        #expect(queue.enqueue([UInt8](repeating: 0, count: 100)))
        let third = Flag()
        let waitingStill = Task {
            await queue.waitForCapacity()
            third.raise()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!third.isRaised)
        queue.close()
        await waitingStill.value
        await queue.waitForCapacity()
        #expect(queue.isClosed)
    }

    /// Producers on many threads and one consumer: every frame arrives once, whole, and in
    /// the order its own producer queued it; afterwards the queue owes nothing.
    @Test func producersAndAConsumer() {
        let queue = OutboundQueue(budgetBytes: 4096, urgentReserveBytes: 1 << 20)
        let producers = 8
        let perProducer = 2000
        let group = DispatchGroup()
        for producer in 0..<producers {
            group.enter()
            Thread.detachNewThread {
                for index in 0..<perProducer {
                    let frame = [UInt8(producer)] + withUnsafeBytes(of: UInt32(index)) { Array($0) } + [UInt8](repeating: UInt8(producer), count: index % 17)
                    _ = queue.enqueue(frame, key: RequestID(producer), urgent: index % 5 == 0)
                }
                group.leave()
            }
        }
        DispatchQueue.global().async {
            group.wait()
            queue.close()
        }
        var next = [Int](repeating: 0, count: producers)
        var damaged = 0
        while let batch = queue.take() {
            var bytes = 0
            for frame in batch {
                bytes += frame.count
                let producer = Int(frame[0])
                let index = Int(frame[1..<5].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                if index != next[producer] || frame.count != 5 + index % 17 || !frame[5...].allSatisfy({ $0 == frame[0] }) { damaged += 1 }
                next[producer] = index + 1
            }
            queue.didWrite(bytes: bytes)
        }
        #expect(damaged == 0)
        #expect(next == [Int](repeating: perProducer, count: producers))
        #expect(!queue.isOverBudget)
        #expect(queue.usage == (0, 0, 0))
    }
}

// MARK: - LineFramer

@Suite struct LineFramerBoundaryTests {
    enum Outcome: Equatable {
        case frame([UInt8])
        case oversized
    }

    /// What a stream means, read off the bytes without any buffering: lines end at a line
    /// feed, one carriage return before it is not part of the line, empty lines are nothing,
    /// and a line longer than the limit is reported and dropped.
    static func reference(_ stream: [UInt8], limit: Int) -> (events: [Outcome], partial: Bool) {
        var events: [Outcome] = []
        var line: [UInt8] = []
        for byte in stream {
            guard byte == 0x0A else {
                line.append(byte)
                continue
            }
            if line.last == 0x0D { line.removeLast() }
            if line.count > limit { events.append(.oversized) } else if !line.isEmpty { events.append(.frame(line)) }
            line = []
        }
        // What is left is a frame in the making unless it has already outgrown the limit; a
        // carriage return in the place just past the limit may still turn out to be a line end.
        let outgrown = line.count > limit + 1 || (line.count == limit + 1 && line[limit] != 0x0D)
        return (events, !line.isEmpty && !outgrown)
    }

    static func drain(_ framer: inout LineFramer, into events: inout [Outcome]) {
        while let event = framer.next() {
            switch event {
            case .frame(let range): events.append(.frame(Array(framer.buffer[range])))
            case .oversized: events.append(.oversized)
            }
        }
    }

    /// Feeds `stream` in the given chunks, through `append` or `receive`.
    static func run(_ stream: [UInt8], limit: Int, chunks: [Int], byReceiving: Bool) -> (events: [Outcome], partial: Bool) {
        var framer = LineFramer(maxFrameBytes: limit, initialCapacity: 16)
        var events: [Outcome] = []
        var offset = 0
        var turn = 0
        while offset < stream.count {
            let size = max(1, chunks[turn % chunks.count])
            turn += 1
            var chunk = stream[offset..<min(offset + size, stream.count)]
            offset += chunk.count
            while !chunk.isEmpty {
                if byReceiving {
                    let written = framer.receive { buffer in
                        let count = min(buffer.count, chunk.count)
                        buffer.copyBytes(from: chunk.prefix(count))
                        return count
                    }
                    chunk = chunk.dropFirst(written)
                } else {
                    chunk = chunk.dropFirst(framer.append(chunk))
                }
                drain(&framer, into: &events)
            }
        }
        return (events, framer.hasPartialFrame)
    }

    /// A frame of exactly the limit is accepted with either line ending, wherever the stream
    /// is cut — in particular between the frame and its carriage return, and between the
    /// carriage return and the line feed.
    @Test func aFrameOfExactlyTheLimitWithEitherLineEnding() {
        for limit in [1, 2, 5, 64, 4095, 4096, 4097] {
            let exact = [UInt8](repeating: 0x61, count: limit)
            for ending in [[0x0A], [0x0D, 0x0A]] as [[UInt8]] {
                // The neighbours are one byte long, so they fit the smallest limit too.
                let segments: [[UInt8]] = [Array("p\n".utf8), exact, ending, Array("q".utf8), ending, exact, ending]
                let stream = Array(segments.joined())
                let expected: [Outcome] = [.frame(Array("p".utf8)), .frame(exact), .frame(Array("q".utf8)), .frame(exact)]
                let around = 2 + limit
                let cuts = limit < 100 ? Array(1..<stream.count) : Array(1...8) + Array((around - 4)...(around + 6)) + Array((stream.count - 4)..<stream.count)
                for cut in cuts {
                    for byReceiving in [false, true] {
                        let found = Self.run(stream, limit: limit, chunks: [cut, stream.count], byReceiving: byReceiving)
                        #expect(found.events == expected, "limit \(limit), ending of \(ending.count), cut at \(cut)")
                        #expect(!found.partial)
                    }
                }
                #expect(Self.run(stream, limit: limit, chunks: [1], byReceiving: false).events == expected, "limit \(limit), byte by byte")
                #expect(Self.run(stream, limit: limit, chunks: [3, 1, 2], byReceiving: true).events == expected, "limit \(limit), in threes, ones and twos")
            }
            // One byte more is too much with either ending, and the stream goes on after it.
            let over = [UInt8](repeating: 0x62, count: limit + 1)
            for ending in [[0x0A], [0x0D, 0x0A]] as [[UInt8]] {
                let stream = over + ending + Array("x".utf8) + [0x0A]
                for chunks in [[1], [limit], [limit + 1], [limit + 2], [stream.count], [2, 3]] {
                    #expect(Self.run(stream, limit: limit, chunks: chunks, byReceiving: false).events == [.oversized, .frame(Array("x".utf8))], "limit \(limit), chunks \(chunks)")
                }
            }
            // A carriage return just past the limit that is not followed by a line feed was not a line end.
            var lingering = exact
            lingering.append(contentsOf: "\rzz\nx\n".utf8)
            for chunks in [[1], [limit + 1, 1], [limit + 1, 100], [lingering.count]] {
                #expect(Self.run(lingering, limit: limit, chunks: chunks, byReceiving: false).events == [.oversized, .frame(Array("x".utf8))], "limit \(limit), chunks \(chunks)")
            }
        }
    }

    /// Random streams of lines sized around the limit, cut at random: the framer reports what
    /// the stream means, whatever the cuts.
    @Test func agreesWithAPlainReadingOfTheStream() {
        var generator = SplitMix64(state: 0x4652_414D)
        var disagreements = 0
        for round in 0..<1500 {
            let limit = [1, 2, 3, 8, 64, 200, 4096].randomElement(using: &generator)!
            var stream: [UInt8] = []
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                let length: Int
                switch Int.random(in: 0..<8, using: &generator) {
                case 0: length = 0
                case 1: length = limit - 1
                case 2: length = limit
                case 3: length = limit + 1
                case 4: length = limit + 2
                case 5: length = limit * 2 + 3
                default: length = Int.random(in: 0...(limit + 3), using: &generator)
                }
                for _ in 0..<length {
                    // Mostly letters, now and then a carriage return anywhere in the line.
                    stream.append(Int.random(in: 0..<12, using: &generator) == 0 ? 0x0D : UInt8.random(in: 0x61...0x7A, using: &generator))
                }
                switch Int.random(in: 0..<6, using: &generator) {
                case 0: stream += [0x0D, 0x0A]
                case 1: stream += [0x0D, 0x0D, 0x0A]
                case 2: break  // run on into the next line
                default: stream.append(0x0A)
                }
            }
            let expected = Self.reference(stream, limit: limit)
            let sizes = [1, 2, 3, limit, limit + 1, limit + 2, 7, 4096, 10_000]
            let chunks = (0..<Int.random(in: 1...5, using: &generator)).map { _ in sizes.randomElement(using: &generator)! }
            for byReceiving in [false, true] {
                let found = Self.run(stream, limit: limit, chunks: chunks, byReceiving: byReceiving)
                if found.events != expected.events || found.partial != expected.partial {
                    disagreements += 1
                    if disagreements <= 5 {
                        Issue.record(
                            "round \(round), limit \(limit), chunks \(chunks), \(byReceiving ? "receive" : "append"): \(found.events.count) events (partial \(found.partial)) for a stream of \(stream.count) bytes that means \(expected.events.count) (partial \(expected.partial))")
                    }
                }
            }
        }
        #expect(disagreements == 0)
    }
}

// MARK: - IncomingMessage

@Suite struct MessageClassificationTests {
    /// What an invalid message was meant to be, as far as that can be told.
    struct Flags: Equatable, CustomStringConvertible {
        var isNotification = false
        var isAmbiguous = false
        var isReply = false

        static let none = Flags()
        static let notification = Flags(isNotification: true)
        static let ambiguous = Flags(isAmbiguous: true)
        static let reply = Flags(isReply: true)

        var description: String {
            let names = [isNotification ? "notification" : nil, isAmbiguous ? "ambiguous" : nil, isReply ? "reply" : nil].compactMap { $0 }
            return names.isEmpty ? "none" : names.joined(separator: "+")
        }
    }

    enum Shape: Equatable {
        case request(RequestID, String, JSONObject)
        case notification(String, JSONObject)
        case result(RequestID, JSONValue)
        case failure(RequestID, MCPError)
        /// Not a message: the id to answer under, the error code, and what it was meant to be.
        case invalid(RequestID?, Int, Flags)
    }

    static func classify(_ text: String) -> Shape {
        guard let value = try? JSON.parse(text) else { return .invalid(nil, 0, .none) }
        do {
            switch try IncomingMessage.classify(value) {
            case .request(let id, let method, let params): return .request(id, method, params)
            case .notification(let method, let params): return .notification(method, params)
            case .response(let id, .success(let result)): return .result(id, result)
            case .response(let id, .failure(let error)): return .failure(id, error)
            }
        } catch {
            return .invalid(
                error.id, error.error.code,
                Flags(isNotification: error.isNotification, isAmbiguous: error.isAmbiguous, isReply: error.isReply))
        }
    }

    @Test func wellFormedMessages() {
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) == .request(1, "ping", [:]))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"x"}}"#) == .request("a", "tools/call", ["name": "x"]))
        #expect(Self.classify(#"{"method":"m","params":{},"id":0,"jsonrpc":"2.0","extra":true}"#) == .request(0, "m", [:]))
        #expect(Self.classify(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == .notification("notifications/initialized", [:]))
        #expect(Self.classify(#"{"jsonrpc":"2.0","method":"n","params":{"a":[1]}}"#) == .notification("n", ["a": [1]]))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#) == .result(7, ["ok": true]))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":7,"result":null}"#) == .result(7, .null))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":"r","result":[1,2]}"#) == .result("r", [1, 2]))
        #expect(
            Self.classify(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"no such method","data":{"m":"x"}}}"#)
                == .failure(7, MCPError(code: -32601, message: "no such method", data: ["m": "x"])))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":7,"error":{"code":5,"message":""}}"#) == .failure(7, MCPError(code: 5, message: "")))
        // A method wins over a result: it is a request.
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":7,"method":"m","result":1}"#) == .request(7, "m", [:]))
    }

    /// Invalid error envelopes retain their reply attribution and correlated ID.
    @Test(arguments: [
        #""boom""#, "null", "5", "[]", "{}", #"{"message":"no code"}"#, #"{"code":"-1","message":"a string for a code"}"#,
        #"{"code":1.5,"message":"a fraction for a code"}"#, #"{"code":null}"#, #"{"code":[1]}"#, "true",
    ])
    func aMalformedErrorIsStillAReply(_ error: String) {
        for id in ["7", "\"r\""] {
            let shape = Self.classify(#"{"jsonrpc":"2.0","id":\#(id),"error":\#(error)}"#)
            guard case .invalid(let found, _, let flags) = shape else {
                Issue.record("error \(error) under id \(id) classified as \(shape)")
                continue
            }
            #expect(found == RequestID(json: try! JSON.parse(id)))
            #expect(flags == .reply)
        }
    }

    /// Messages that are invalid, with what the documentation of each flag says about them.
    @Test func invalidMessagesSayWhatTheyWere() {
        let invalidRequest = MCPError.Code.invalidRequest
        let invalidParams = MCPError.Code.invalidParams
        // A notification with unusable params is still a notification: flagged, so that it is not answered.
        for params in ["[1]", "\"x\"", "5", "null", "true"] {
            #expect(Self.classify(#"{"jsonrpc":"2.0","method":"n","params":\#(params)}"#) == .invalid(nil, invalidParams, .notification), "params \(params)")
            // The same in a request is answered under its id.
            #expect(Self.classify(#"{"jsonrpc":"2.0","id":3,"method":"m","params":\#(params)}"#) == .invalid(3, invalidParams, .none), "params \(params)")
        }
        // A notification stays one when the version is wrong or missing.
        #expect(Self.classify(#"{"jsonrpc":"1.0","method":"n"}"#) == .invalid(nil, invalidRequest, .notification))
        #expect(Self.classify(#"{"method":"n","params":{}}"#) == .invalid(nil, invalidRequest, .notification))
        #expect(Self.classify(#"{"jsonrpc":2.0,"method":"n"}"#) == .invalid(nil, invalidRequest, .notification))
        // With an id it is a request, and is answered under that id.
        #expect(Self.classify(#"{"jsonrpc":"1.0","id":4,"method":"m"}"#) == .invalid(4, invalidRequest, .none))
        #expect(Self.classify(#"{"id":"s","method":"m"}"#) == .invalid("s", invalidRequest, .none))
        // No method, but a result or an error: a reply, whatever else is wrong with it — never answered.
        #expect(Self.classify(#"{"jsonrpc":"1.0","id":4,"result":1}"#) == .invalid(4, invalidRequest, .reply))
        #expect(Self.classify(#"{"id":4,"error":{"code":1,"message":"x"}}"#) == .invalid(4, invalidRequest, .reply))
        #expect(Self.classify(#"{"jsonrpc":"1.0","result":1}"#) == .invalid(nil, invalidRequest, .reply))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":null,"result":1}"#) == .invalid(nil, invalidRequest, .reply))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":{"a":1},"error":"boom"}"#) == .invalid(nil, invalidRequest, .reply))
        // Neither a method nor a result nor an error: it cannot be told what it was meant to be.
        #expect(Self.classify("{}") == .invalid(nil, invalidRequest, .ambiguous))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":4}"#) == .invalid(4, invalidRequest, .ambiguous))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":"s","params":{}}"#) == .invalid("s", invalidRequest, .ambiguous))
        #expect(Self.classify(#"{"jsonrpc":"1.0","id":4}"#) == .invalid(4, invalidRequest, .ambiguous))
        #expect(Self.classify(#"{"id":4,"params":[1]}"#) == .invalid(4, invalidRequest, .ambiguous))
        // Not an object: nothing can be said about it.
        for text in ["[]", "1", "\"text\"", "null", "true", #"[{"jsonrpc":"2.0","id":1,"method":"m"}]"#] {
            #expect(Self.classify(text) == .invalid(nil, invalidRequest, .none), "\(text)")
        }
        // An id that is not an id cannot be answered under, in a request as in anything else.
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":null,"method":"m"}"#) == .invalid(nil, invalidRequest, .none))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":[1],"method":"m"}"#) == .invalid(nil, invalidRequest, .none))
        #expect(Self.classify(#"{"jsonrpc":"2.0","id":4,"method":5}"#) == .invalid(4, invalidRequest, .none))
    }

    /// Classifies every combination of envelope members and checks attribution for rejected messages.
    @Test func flagsFollowTheShapeOfTheMessage() {
        let versions: [String?] = [#""jsonrpc":"2.0""#, #""jsonrpc":"1.0""#, nil]
        let ids: [(text: String?, valid: Bool)] = [(nil, false), (#""id":4"#, true), (#""id":"s""#, true), (#""id":null"#, false), (#""id":true"#, false)]
        let methods: [String?] = [nil, #""method":"m""#]
        let paramsForms: [String?] = [nil, #""params":{}"#, #""params":[1]"#]
        let results: [String?] = [nil, #""result":1"#]
        let errors: [String?] = [nil, #""error":{"code":1,"message":"x"}"#, #""error":"boom""#]
        var mismatches: [String] = []
        var invalid = 0
        var valid = 0
        for version in versions {
            for id in ids {
                for method in methods {
                    for params in paramsForms {
                        for result in results {
                            for error in errors {
                                let members = [version, id.text, method, params, result, error].compactMap { $0 }
                                let text = "{" + members.joined(separator: ",") + "}"
                                let hasMethod = method != nil
                                let isReply = !hasMethod && (result != nil || error != nil)
                                let expected = Flags(isNotification: hasMethod && id.text == nil, isAmbiguous: !hasMethod && !isReply, isReply: isReply)
                                // Valid when the version is right, the id (if any) is an id, and the rest fits its kind.
                                let hasValidReplyPayload = (result != nil && error == nil)
                                    || (result == nil && error == errors[1])
                                let wellFormed = version == versions[0] && (id.text == nil || id.valid)
                                    && (hasMethod ? params != paramsForms[2] : id.valid && hasValidReplyPayload)
                                switch Self.classify(text) {
                                case .invalid(_, _, let flags):
                                    invalid += 1
                                    if wellFormed { mismatches.append("\(text) was refused") } else if flags != expected { mismatches.append("\(text): flagged \(flags), is \(expected)") }
                                default:
                                    valid += 1
                                    if !wellFormed { mismatches.append("\(text) was accepted") }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(valid + invalid == 540 && valid > 0)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(invalid) invalid messages are flagged differently: \(mismatches.prefix(8))")
    }
}
