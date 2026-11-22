/// Splits a byte stream into newline-delimited frames without copying them.
///
/// The framing the specification defines for stdio; the stdio transport also uses it over
/// any other stream it is given (a Unix socket, a TCP connection), for which the specification
/// defines no framing of its own. Input is read straight into the framer's buffer and frames
/// are handed out as ranges of that buffer.
public struct LineFramer: Sendable {
    public enum Event: Sendable, Equatable {
        /// A complete frame at this range of `buffer`, without its line terminator.
        case frame(Range<Int>)
        /// A frame exceeded the size limit. Its bytes are discarded up to the next newline.
        case oversized
    }

    /// The bytes received so far. Valid ranges come from `next()`.
    public private(set) var buffer: [UInt8]
    public let maxFrameBytes: Int
    private var frameStart = 0
    private var scanned = 0
    private var end = 0
    private var discarding = false

    public init(maxFrameBytes: Int, initialCapacity: Int = 64 * 1024) {
        self.maxFrameBytes = maxFrameBytes
        buffer = [UInt8](repeating: 0, count: Swift.max(4096, Swift.min(initialCapacity, LineFramer.sum(maxFrameBytes, 1))))
    }

    /// Addition that stops at `Int.max`: a limit of `Int.max` means "no limit", not a trap.
    private static func sum(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : result
    }

    /// Whether a partial frame is waiting for more input.
    public var hasPartialFrame: Bool { end > frameStart && !discarding }

    /// Whether every buffered byte has been examined, i.e. `next()` has returned `nil`.
    private var isDrained: Bool { scanned == end }

    /// Lets `body` write new input at the end of the buffer; it returns how many bytes it wrote.
    /// A result of zero or less (end of stream, error) adds no input and is returned as is.
    /// Room is made before `body` runs, whatever it returns: the unfinished frame may have
    /// moved to the front, the buffer may have grown, or an oversized frame may have been
    /// dropped.
    ///
    /// Frames are handed out as ranges of the buffer, and making room moves its contents, so
    /// this may only be called once `next()` has returned `nil`.
    public mutating func receive(_ body: (UnsafeMutableRawBufferPointer) -> Int) -> Int {
        precondition(isDrained, "LineFramer.receive called before next() returned nil")
        makeRoom()
        let start = end
        let written = buffer.withUnsafeMutableBytes { raw in
            body(UnsafeMutableRawBufferPointer(rebasing: raw[start...]))
        }
        guard written > 0 else { return written }
        precondition(written <= buffer.count - start)
        end += written
        return written
    }

    /// Copies as much of `chunk` as fits and returns how many bytes were taken.
    ///
    /// Returns 0 while complete frames are still waiting: drain `next()` and call again.
    public mutating func append(_ chunk: some Collection<UInt8>) -> Int {
        guard isDrained, !chunk.isEmpty else { return 0 }
        makeRoom()
        let count = Swift.min(buffer.count - end, chunk.count)
        buffer.replaceSubrange(end..<end + count, with: chunk.prefix(count))
        end += count
        return count
    }

    private mutating func makeRoom() {
        if frameStart > 0 {
            // Slide the unfinished frame to the front.
            let pending = end - frameStart
            if pending > 0 {
                buffer.withUnsafeMutableBytes { raw in
                    raw.baseAddress!.copyMemory(from: raw.baseAddress! + frameStart, byteCount: pending)
                }
            }
            scanned -= frameStart
            end = pending
            frameStart = 0
        }
        guard end == buffer.count else { return }
        let target = Swift.min(Swift.max(LineFramer.sum(buffer.count, buffer.count), 4096), LineFramer.sum(maxFrameBytes, 4096))
        if target > buffer.count {
            buffer.append(contentsOf: repeatElement(0, count: target - buffer.count))
        } else {
            // The frame cannot grow further: drop what is buffered and skip to the next newline.
            discarding = true
            end = 0
            scanned = 0
        }
    }

    /// The next complete frame, or `nil` when more input is needed. Blank lines are skipped.
    public mutating func next() -> Event? {
        while scanned < end {
            guard let newline = buffer[scanned..<end].firstIndex(of: 0x0A) else {
                scanned = end
                break
            }
            scanned = newline + 1
            if discarding {
                discarding = false
                frameStart = scanned
                return .oversized
            }
            var frameEnd = newline
            if frameEnd > frameStart, buffer[frameEnd - 1] == 0x0D { frameEnd -= 1 }
            let range = frameStart..<frameEnd
            frameStart = scanned
            if range.count > maxFrameBytes { return .oversized }
            if range.isEmpty { continue }
            return .frame(range)
        }
        // A frame of exactly the limit may be followed by "\r\n": the "\r" is not part of the
        // frame, so one such byte beyond the limit is not yet too much.
        let partial = end - frameStart
        let allowance = LineFramer.sum(maxFrameBytes, 1)
        if !discarding, partial > allowance || (partial == allowance && partial > maxFrameBytes && buffer[end - 1] != 0x0D) {
            discarding = true
            frameStart = end
            scanned = end
        }
        if discarding {
            // Nothing of the oversized frame is worth keeping.
            frameStart = end
        }
        return nil
    }
}
