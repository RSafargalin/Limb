import LimbCore
import Testing


private enum Ev: Equatable, CustomStringConvertible {
    case frame([UInt8])
    case oversized

    var description: String {
        switch self {
        case .frame(let bytes): bytes.count <= 24 ? "frame(\(bytes))" : "frame(\(bytes.count) bytes)"
        case .oversized: "oversized"
        }
    }
}

private func oracle(_ stream: [UInt8], max: Int) -> [Ev] {
    var events: [Ev] = []
    var start = 0
    for (index, byte) in stream.enumerated() where byte == 0x0A {
        var end = index
        if end > start, stream[end - 1] == 0x0D { end -= 1 }
        if end - start > max {
            events.append(.oversized)
        } else if end > start {
            events.append(.frame(Array(stream[start..<end])))
        }
        start = index + 1
    }
    return events
}

private struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

private struct Outcome {
    var events: [Ev] = []
    var largestBuffer = 0
    /// The framer made no progress although it was drained and input remained.
    var stalled = false
    /// `receive` offered a zero-length buffer. A transport passes that to `read`, gets 0 back
    /// and takes it for end of input.
    var offeredNoRoom = false
}

/// Feeds `stream` through `append`, `chunk()` bytes at a time.
private func driveAppend(_ stream: [UInt8], max: Int, capacity: Int = 64 * 1024, chunk: () -> Int) -> Outcome {
    var framer = LineFramer(maxFrameBytes: max, initialCapacity: capacity)
    var outcome = Outcome()
    func drain(_ framer: inout LineFramer, _ outcome: inout Outcome) {
        while let event = framer.next() {
            switch event {
            case .frame(let range): outcome.events.append(.frame(Array(framer.buffer[range])))
            case .oversized: outcome.events.append(.oversized)
            }
        }
    }
    var offset = 0
    while offset < stream.count {
        drain(&framer, &outcome)
        let size = Swift.max(1, Swift.min(chunk(), stream.count - offset))
        let taken = framer.append(stream[offset..<offset + size])
        outcome.largestBuffer = Swift.max(outcome.largestBuffer, framer.buffer.count)
        if taken <= 0 || taken > size {
            outcome.stalled = true
            return outcome
        }
        offset += taken
    }
    drain(&framer, &outcome)
    return outcome
}

/// Feeds `stream` through `receive`, the way the transport's `read` does: the body is given
/// the free room and takes at most `chunk()` bytes of it.
private func driveReceive(_ stream: [UInt8], max: Int, capacity: Int = 64 * 1024, chunk: () -> Int) -> Outcome {
    var framer = LineFramer(maxFrameBytes: max, initialCapacity: capacity)
    var outcome = Outcome()
    var offset = 0
    while true {
        while let event = framer.next() {
            switch event {
            case .frame(let range): outcome.events.append(.frame(Array(framer.buffer[range])))
            case .oversized: outcome.events.append(.oversized)
            }
        }
        if offset == stream.count { break }
        let want = Swift.max(1, chunk())
        var noRoom = false
        let got = framer.receive { room in
            if room.count == 0 {
                noRoom = true
                return 0
            }
            let size = Swift.min(want, room.count, stream.count - offset)
            stream.withUnsafeBytes { source in
                room.baseAddress!.copyMemory(from: source.baseAddress! + offset, byteCount: size)
            }
            return size
        }
        outcome.largestBuffer = Swift.max(outcome.largestBuffer, framer.buffer.count)
        if noRoom {
            outcome.offeredNoRoom = true
            return outcome
        }
        if got <= 0 {
            outcome.stalled = true
            return outcome
        }
        offset += got
    }
    return outcome
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func line(_ length: Int, fill: UInt8 = 0x61) -> [UInt8] { [UInt8](repeating: fill, count: length) }

@Suite struct IndependentStdioLineFramerTests {
    // MARK: Splitting

    @Test func aMessageSplitAtEveryBytePositionIsTheSameMessage() {
        let stream = bytes(
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\r\n"
                + "\n\r\n" + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n")
        let expected = oracle(stream, max: 1 << 20)
        #expect(expected.count == 3)
        for cut in 0...stream.count {
            var sizes = [cut, stream.count - cut].filter { $0 > 0 }.makeIterator()
            let appended = driveAppend(stream, max: 1 << 20) { sizes.next() ?? 1 }
            #expect(appended.events == expected, "append, cut at \(cut)")
            #expect(!appended.stalled)
            var again = [cut, stream.count - cut].filter { $0 > 0 }.makeIterator()
            let received = driveReceive(stream, max: 1 << 20) { again.next() ?? 1 }
            #expect(received.events == expected, "receive, cut at \(cut)")
            #expect(!received.stalled && !received.offeredNoRoom)
        }
    }

    @Test func oneByteAtATime() {
        let stream = bytes("first\nsecond\r\n\n\r\nthird\n")
        let expected: [Ev] = [.frame(bytes("first")), .frame(bytes("second")), .frame(bytes("third"))]
        #expect(driveAppend(stream, max: 100) { 1 }.events == expected)
        #expect(driveReceive(stream, max: 100) { 1 }.events == expected)
    }

    @Test func manyMessagesInOneRead() {
        var stream: [UInt8] = []
        var expected: [Ev] = []
        for index in 0..<5000 {
            let message = bytes(#"{"jsonrpc":"2.0","id":\#(index),"method":"ping"}"#)
            stream += message + [0x0A]
            expected.append(.frame(message))
        }
        let outcome = driveReceive(stream, max: 1 << 20, capacity: 1 << 20) { .max }
        #expect(outcome.events == expected)
    }

    // MARK: Line terminators

    @Test func carriageReturnBeforeNewlineIsNotPartOfTheFrame() {
        #expect(driveAppend(bytes("abc\r\n"), max: 100) { .max }.events == [.frame(bytes("abc"))])
        // Only one is cut: the rest is content (JSON treats a carriage return as whitespace).
        #expect(driveAppend(bytes("abc\r\r\n"), max: 100) { .max }.events == [.frame(bytes("abc\r"))])
    }

    @Test func aLoneCarriageReturnDoesNotEndAFrame() {
        // The specification names the newline as the delimiter; a bare CR is ordinary content.
        #expect(driveAppend(bytes("a\rb\n"), max: 100) { .max }.events == [.frame(bytes("a\rb"))])
        #expect(driveAppend(bytes("\ra\n"), max: 100) { .max }.events == [.frame(bytes("\ra"))])
        #expect(driveAppend(bytes("a\rb"), max: 100) { .max }.events == [])
    }

    @Test func emptyLinesAreSkipped() {
        #expect(driveAppend(bytes("\n\n\r\n\n"), max: 100) { .max }.events == [])
        #expect(driveAppend(bytes("\n\na\n\n\r\nb\r\n\n"), max: 100) { .max }.events == [.frame(bytes("a")), .frame(bytes("b"))])
    }

    @Test func whitespaceOnlyLinesAreFramesObservedUnspecified() {
        #expect(driveAppend(bytes(" \n\t\n \r\n"), max: 100) { .max }.events == [.frame(bytes(" ")), .frame(bytes("\t")), .frame(bytes(" "))])
    }

    @Test func zeroBytesAndInvalidUTF8PassThroughUntouched() {
        let content: [UInt8] = [0x00, 0xFF, 0xFE, 0x00, 0xC0, 0x80, 0x0D, 0x00]
        #expect(driveAppend(content + [0x0A], max: 100) { 3 }.events == [.frame(content)])
        #expect(driveReceive([0x00, 0x0A, 0x00, 0x00, 0x0D, 0x0A], max: 100) { 1 }.events == [.frame([0x00]), .frame([0x00, 0x00])])
    }

    @Test func anUnterminatedTailIsNotAFrame() {
        var framer = LineFramer(maxFrameBytes: 100)
        #expect(framer.append(bytes("done\ntail")) == 9)
        #expect(framer.next() == .frame(0..<4))
        #expect(framer.next() == nil)
        #expect(framer.hasPartialFrame)
        #expect(framer.append(bytes("\n")) == 1)
        guard case .frame(let range)? = framer.next() else {
            Issue.record("the tail did not become a frame once its newline arrived")
            return
        }
        #expect(Array(framer.buffer[range]) == bytes("tail"))
        #expect(framer.next() == nil)
        #expect(!framer.hasPartialFrame)
    }

    // MARK: The size limit

    @Test(arguments: [1, 2, 7, 100, 4095, 4096, 4097, 8192, 65535, 65536, 65537, 100_000])
    func framesAtTheLimitPassAndOneByteOverIsOversized(max: Int) {
        let tail: [UInt8] = [0x62]
        let exact = line(max) + [0x0A] + tail + [0x0A]
        for chunk in [1, 4096, Int.max] where chunk > 1 || max < 10_000 {
            #expect(driveAppend(exact, max: max) { chunk }.events == [.frame(line(max)), .frame(tail)], "exact, chunk \(chunk)")
            #expect(driveReceive(exact, max: max) { chunk }.events == [.frame(line(max)), .frame(tail)], "exact, chunk \(chunk)")
        }
        for terminator in [bytes("\n"), bytes("\r\n")] {
            let over = line(max + 1) + terminator + tail + [0x0A]
            #expect(driveAppend(over, max: max) { .max }.events == [.oversized, .frame(tail)], "one over, one chunk")
            #expect(driveReceive(over, max: max) { 1000 }.events == [.oversized, .frame(tail)], "one over, chunks of 1000")
            if max > 1 {
                let under = line(max - 1) + terminator + tail + [0x0A]
                #expect(driveAppend(under, max: max) { .max }.events == [.frame(line(max - 1)), .frame(tail)], "one under, one chunk")
                #expect(driveReceive(under, max: max) { 1000 }.events == [.frame(line(max - 1)), .frame(tail)], "one under, chunks of 1000")
            }
        }
    }

    @Test(arguments: [1, 100, 4095, 4096, 8192, 65535, 65536, 100_000])
    func aFrameAtTheLimitWithCRLFDoesNotDependOnWhereTheReadsFall(max: Int) {
        let tail: [UInt8] = [0x62]
        let stream = line(max) + bytes("\r\n") + tail + [0x0A]
        let expected: [Ev] = [.frame(line(max)), .frame(tail)]
        #expect(oracle(stream, max: max) == expected)
        // The read ends right after the carriage return: the newline arrives in the next one.
        var sizes = [max + 1, stream.count].makeIterator()
        #expect(driveAppend(stream, max: max) { sizes.next() ?? 1 }.events == expected, "append, split between CR and LF")
        var again = [max + 1, stream.count].makeIterator()
        #expect(driveReceive(stream, max: max) { again.next() ?? 1 }.events == expected, "receive, split between CR and LF")
        if max < 10_000 {
            #expect(driveReceive(stream, max: max) { 1 }.events == expected, "receive, one byte at a time")
        }
        // What a transport does: read as much as the framer offers.
        #expect(driveReceive(stream, max: max) { .max }.events == expected, "receive, as much as fits")
        #expect(driveAppend(stream, max: max) { .max }.events == expected, "append, as much as fits")
    }

    @Test(arguments: [2, 64, 4096, 8192])
    func theStreamResynchronisesAfterAnOversizedFrame(max: Int) {
        let good = line(Swift.min(max - 1, 5), fill: 0x62)
        for excess in [1, 2, max, 3 * max + 1, 70_000, 300_000] {
            for terminator in [bytes("\n"), bytes("\r\n")] {
                let oversized = line(max + excess)
                let segments: [[UInt8]] = [
                    good, [0x0A], oversized, terminator, good, terminator,
                    oversized, terminator, good, [0x0A],
                ]
                let stream = Array(segments.joined())
                let expected: [Ev] = [.frame(good), .oversized, .frame(good), .oversized, .frame(good)]
                #expect(oracle(stream, max: max) == expected)
                for chunk in [1, 3, 4096, 65536, Int.max] where chunk > 1 || stream.count < 200_000 {
                    #expect(driveAppend(stream, max: max) { chunk }.events == expected, "append: excess \(excess), chunk \(chunk)")
                    let received = driveReceive(stream, max: max) { chunk }
                    #expect(received.events == expected, "receive: excess \(excess), chunk \(chunk)")
                    #expect(!received.offeredNoRoom && !received.stalled)
                }
            }
        }
    }

    @Test func aVastlyOversizedFrameIsDiscardedInBoundedMemory() {
        let max = 4096
        var framer = LineFramer(maxFrameBytes: max)
        var events: [Ev] = []
        var largest = 0
        let block = line(64 * 1024)
        var fed = 0
        // 256 MiB without a newline.
        while fed < 256 << 20 {
            while let event = framer.next() { events.append(event == .oversized ? .oversized : .frame([])) }
            let got = framer.receive { room in
                let size = Swift.min(room.count, block.count)
                block.withUnsafeBytes { room.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: size) }
                return size
            }
            #expect(got > 0)
            if got <= 0 { return }
            fed += got
            largest = Swift.max(largest, framer.buffer.count)
        }
        #expect(events == [])
        #expect(!framer.hasPartialFrame)
        #expect(largest <= 4 * (max + 4096), "buffer grew to \(largest) bytes")
        while framer.next() != nil {}
        #expect(framer.append(bytes("x\nok\n")) == 5)
        #expect(framer.next() == .oversized)
        guard case .frame(let range)? = framer.next() else {
            Issue.record("no frame after the oversized one")
            return
        }
        #expect(Array(framer.buffer[range]) == bytes("ok"))
    }

    @Test func theBufferStaysBoundedForFramesWithinTheLimit() {
        let max = 100_000
        var rng = Rng(7)
        var stream: [UInt8] = []
        for _ in 0..<60 { stream += line(rng.below(max) + 1) + [0x0A] }
        let outcome = driveReceive(stream, max: max, capacity: 4096) { rng.below(30_000) + 1 }
        #expect(outcome.events == oracle(stream, max: max))
        #expect(outcome.largestBuffer <= 2 * (max + 4096), "buffer grew to \(outcome.largestBuffer) bytes")
    }

    // MARK: Contract of `append` and `receive`

    @Test func appendTakesNothingUntilTheBufferIsDrainedAndLosesNothing() {
        var framer = LineFramer(maxFrameBytes: 100)
        #expect(framer.append(bytes("one\ntwo\n")) == 8)
        #expect(framer.append(bytes("three\n")) == 0)
        #expect(framer.next() == .frame(0..<3))
        #expect(framer.append(bytes("three\n")) == 0)
        guard case .frame(let second)? = framer.next() else {
            Issue.record("second frame lost")
            return
        }
        #expect(Array(framer.buffer[second]) == bytes("two"))
        #expect(framer.next() == nil)
        #expect(framer.append(bytes("three\n")) == 6)
        guard case .frame(let third)? = framer.next() else {
            Issue.record("third frame lost")
            return
        }
        #expect(Array(framer.buffer[third]) == bytes("three"))
    }

    @Test func appendOfNothingTakesNothing() {
        var framer = LineFramer(maxFrameBytes: 100)
        #expect(framer.append([UInt8]()) == 0)
        #expect(framer.next() == nil)
        #expect(!framer.hasPartialFrame)
    }

    @Test func appendReportsHowMuchItTookWhenTheChunkDoesNotFit() {
        // A chunk far larger than the buffer: `append` may take only part, and says how much.
        let max = 1000
        var stream: [UInt8] = []
        for _ in 0..<400 { stream += line(900) + [0x0A] }
        var framer = LineFramer(maxFrameBytes: max, initialCapacity: 4096)
        var offset = 0
        var frames = 0
        var rounds = 0
        while offset < stream.count, rounds < 100_000 {
            rounds += 1
            while let event = framer.next() {
                if case .frame(let range) = event, range.count == 900 { frames += 1 }
            }
            let taken = framer.append(stream[offset...])
            #expect(taken > 0 && taken <= stream.count - offset)
            if taken <= 0 { return }
            offset += taken
        }
        while let event = framer.next() {
            if case .frame(let range) = event, range.count == 900 { frames += 1 }
        }
        #expect(offset == stream.count)
        #expect(frames == 400)
    }

    @Test func receiveReturnsEndOfStreamAndErrorsUnchangedAndKeepsItsState() {
        var framer = LineFramer(maxFrameBytes: 100)
        #expect(framer.append(bytes("par")) == 3)
        #expect(framer.next() == nil)
        #expect(framer.receive { _ in 0 } == 0)
        #expect(framer.receive { _ in -1 } == -1)
        #expect(framer.receive { _ in -7 } == -7)
        #expect(framer.hasPartialFrame)
        #expect(framer.append(bytes("tial\n")) == 5)
        guard case .frame(let range)? = framer.next() else {
            Issue.record("frame lost after an empty receive")
            return
        }
        #expect(Array(framer.buffer[range]) == bytes("partial"))
    }

    /// `receive` hands its room to `read`. If the room were ever empty, `read` would return 0
    /// and the transport would take that for end of input.
    @Test(arguments: [0, 1, 2, 100, 4095, 4096, 4097, 8191, 8192, 8193, 70_000])
    func receiveAlwaysOffersRoom(max: Int) {
        var rng = Rng(UInt64(max) &+ 99)
        for capacity in [0, 1, 4096, 8192, 64 * 1024] {
            var stream: [UInt8] = []
            for _ in 0..<40 {
                let pick = rng.below(6)
                let length = [0, 1, Swift.max(0, max - 1), max, max + 1, 3 * max + 4097][pick]
                stream += line(length) + (rng.chance(50) ? [0x0A] : [0x0D, 0x0A])
            }
            for chunk in [1, 4096, Int.max] where chunk > 1 || stream.count < 100_000 {
                let outcome = driveReceive(stream, max: max, capacity: capacity) { chunk }
                #expect(!outcome.offeredNoRoom, "max \(max), capacity \(capacity), chunk \(chunk)")
                #expect(!outcome.stalled)
            }
        }
    }

    @Test func hasPartialFrameFollowsTheInput() {
        var framer = LineFramer(maxFrameBytes: 10)
        #expect(!framer.hasPartialFrame)
        _ = framer.append(bytes("abc"))
        _ = framer.next()
        #expect(framer.hasPartialFrame)
        _ = framer.append(bytes("\n"))
        #expect(framer.next() == .frame(0..<3))
        #expect(framer.next() == nil)
        #expect(!framer.hasPartialFrame)
        // An oversized frame in progress is not a partial frame: nothing of it will be delivered.
        _ = framer.append(bytes("0123456789ABCDEF"))
        #expect(framer.next() == nil)
        #expect(!framer.hasPartialFrame)
    }

    // MARK: Generated inputs against the oracle

    /// `crlfAtLimit: false` leaves out the one input the framer is known to get wrong (see
    /// `aFrameAtTheLimitWithCRLFDoesNotDependOnWhereTheReadsFall`): a line of `max` bytes, or of
    /// `max` bytes ending in a carriage return, followed by CR LF.
    private static func generate(_ rng: inout Rng, max: Int, crlfAtLimit: Bool) -> [UInt8] {
        var stream: [UInt8] = []
        let lines = rng.below(30) + 1
        for _ in 0..<lines {
            let length: Int
            switch rng.below(12) {
            case 0: length = 0
            case 1: length = 1
            case 2: length = Swift.max(0, max - 1)
            case 3: length = max
            case 4: length = max + 1
            case 5: length = max + 2
            case 6: length = 2 * max + rng.below(50)
            case 7: length = rng.below(3 * max + 2)
            default: length = rng.below(Swift.min(max, 40) + 1)
            }
            for _ in 0..<length {
                // Any byte but the delimiter; carriage returns, zeros and high bytes included.
                let byte: UInt8
                switch rng.below(10) {
                case 0: byte = 0x0D
                case 1: byte = 0x00
                case 2: byte = UInt8(0x80 + rng.below(0x80))
                default: byte = UInt8(0x20 + rng.below(0x5F))
                }
                stream.append(byte)
            }
            switch rng.below(10) {
            case 0...5: stream.append(0x0A)
            case 6...8: stream += [0x0D, 0x0A]
            default: stream += [0x0D, 0x0D, 0x0A]
            }
            // The line as the oracle sees it: up to the newline, less one carriage return.
            let endsInCRLF = stream.count >= 2 && stream[stream.count - 2] == 0x0D
            let lineStart = (stream.dropLast().lastIndex(of: 0x0A) ?? -1) + 1
            if !crlfAtLimit, endsInCRLF, stream.count - 2 - lineStart == max {
                // Exactly the limit, then CR LF: make it one byte longer instead.
                stream[stream.count - 2] = 0x78
            }
        }
        if rng.chance(30) {
            // An unterminated tail.
            for _ in 0..<rng.below(max + 3) { stream.append(0x41) }
        }
        return stream
    }

    private func compareGenerated(max: Int, crlfAtLimit: Bool) {
        var rng = Rng(UInt64(max) &* 1_000_003 &+ (crlfAtLimit ? 1 : 0))
        var mismatches = 0
        let rounds = max >= 4096 ? 150 : 600
        for round in 0..<rounds {
            let stream = Self.generate(&rng, max: max, crlfAtLimit: crlfAtLimit)
            let expected = oracle(stream, max: max)
            let capacity = [0, 4096, 64 * 1024][rng.below(3)]
            let style = rng.below(4)
            let fixed = rng.below(Swift.max(2, max * 2)) + 1
            var chunkRng = Rng(rng.next())
            let chunk: () -> Int = {
                switch style {
                case 0: 1
                case 1: fixed
                case 2: chunkRng.below(max + 3) + 1
                default: Int.max
                }
            }
            let outcome = round % 2 == 0
                ? driveAppend(stream, max: max, capacity: capacity, chunk: chunk)
                : driveReceive(stream, max: max, capacity: capacity, chunk: chunk)
            if outcome.events != expected || outcome.stalled || outcome.offeredNoRoom {
                mismatches += 1
                if mismatches <= 2 {
                    Issue.record(
                        """
                        max \(max), round \(round), \(round % 2 == 0 ? "append" : "receive"), chunk style \(style) (fixed \(fixed)), \
                        capacity \(capacity), stream of \(stream.count) bytes: stalled \(outcome.stalled), \
                        no room \(outcome.offeredNoRoom)
                        expected \(expected)
                        got      \(outcome.events)
                        """)
                }
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(rounds) generated streams differ from the oracle")
    }

    @Test(arguments: [1, 2, 3, 8, 33, 500, 4096, 5000])
    func generatedStreamsMatchTheOracleForEveryChunking(max: Int) {
        compareGenerated(max: max, crlfAtLimit: false)
    }

    @Test(arguments: [1, 2, 3, 8, 33, 500, 4096, 5000])
    func generatedStreamsWithCRLFAtTheLimitMatchTheOracle(max: Int) {
        compareGenerated(max: max, crlfAtLimit: true)
    }

    // MARK: Cost

    @Test func aHugeBurstOfTinyFramesIsLinear() {
        let count = 300_000
        var stream: [UInt8] = []
        stream.reserveCapacity(count * 3)
        for _ in 0..<count { stream += [0x7B, 0x7D, 0x0A] }
        let clock = ContinuousClock()
        var frames = 0
        let elapsed = clock.measure {
            var framer = LineFramer(maxFrameBytes: 1 << 20)
            var offset = 0
            while true {
                while let event = framer.next() {
                    if case .frame(let range) = event, range.count == 2 { frames += 1 }
                }
                if offset == stream.count { break }
                offset += framer.receive { room in
                    let size = Swift.min(room.count, stream.count - offset)
                    stream.withUnsafeBytes { room.baseAddress!.copyMemory(from: $0.baseAddress! + offset, byteCount: size) }
                    return size
                }
            }
        }
        #expect(frames == count)
        // Generous: three other test processes share the machine. A quadratic framer takes minutes.
        #expect(elapsed < .seconds(20), "took \(elapsed)")
    }

    @Test func oneLargeFrameArrivingInSmallReadsIsLinear() {
        let size = 2 << 20
        let content = line(size)
        let stream = content + [0x0A]
        let clock = ContinuousClock()
        var delivered = 0
        let elapsed = clock.measure {
            var framer = LineFramer(maxFrameBytes: 4 << 20, initialCapacity: 4096)
            var offset = 0
            while true {
                while let event = framer.next() {
                    if case .frame(let range) = event { delivered = range.count }
                }
                if offset == stream.count { break }
                offset += framer.receive { room in
                    let size = Swift.min(room.count, 512, stream.count - offset)
                    stream.withUnsafeBytes { room.baseAddress!.copyMemory(from: $0.baseAddress! + offset, byteCount: size) }
                    return size
                }
            }
        }
        #expect(delivered == size)
        #expect(elapsed < .seconds(20), "took \(elapsed)")
    }

    @Test func theLargestLimitDoesNotTrap() {
        for capacity in [0, 4096, 64 * 1024] {
            var framer = LineFramer(maxFrameBytes: .max, initialCapacity: capacity)
            #expect(framer.append(bytes("a\n")) == 2)
            #expect(framer.next() == .frame(0..<1))
            #expect(framer.next() == nil)
        }
        // Growth with no limit: a frame much larger than the first buffer, in small reads.
        let stream = line(600_000) + bytes("\r\n") + bytes("tail\n")
        let expected: [Ev] = [.frame(line(600_000)), .frame(bytes("tail"))]
        #expect(driveReceive(stream, max: .max, capacity: 4096) { 3000 }.events == expected)
        #expect(driveAppend(stream, max: .max, capacity: 0) { .max }.events == expected)
        #expect(driveReceive(stream, max: .max - 1) { .max }.events == expected)
    }

    /// The smallest limits: everything but an empty line is oversized at 0.
    @Test func aLimitOfZeroRejectsEveryNonEmptyFrame() {
        let stream = bytes("\n\r\na\n\nbc\r\n\r\r\n") + line(10_000) + bytes("\n\n")
        #expect(oracle(stream, max: 0) == [.oversized, .oversized, .oversized, .oversized])
        for chunk in [1, 2, 4096, Int.max] {
            #expect(driveAppend(stream, max: 0) { chunk }.events == oracle(stream, max: 0), "append, chunk \(chunk)")
            let received = driveReceive(stream, max: 0) { chunk }
            #expect(received.events == oracle(stream, max: 0), "receive, chunk \(chunk)")
            #expect(!received.offeredNoRoom && !received.stalled)
        }
    }
}
