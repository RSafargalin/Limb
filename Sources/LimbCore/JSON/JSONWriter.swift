/// A type that writes itself as JSON directly into a byte buffer.
///
/// This is the encoding path for everything Limb sends: no `Encoder`, no keyed containers,
/// no intermediate tree.
public protocol JSONEncodable {
    func encode(to writer: inout JSONWriter)
}

/// An append-only JSON serializer over a byte buffer.
///
/// The writer inserts commas itself; callers describe structure with `beginObject` / `key` /
/// `endObject` and never emit separators. Output is compact (no insignificant whitespace) and
/// contains no raw newlines, which is what newline-delimited framing requires.
public struct JSONWriter: Sendable {
    public var bytes: [UInt8]
    @usableFromInline var first = true
    @usableFromInline var afterKey = false

    @inlinable
    public init(capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    // MARK: Structure

    @inlinable
    mutating func separate() {
        if afterKey {
            afterKey = false
        } else {
            if !first { bytes.append(0x2C) }
            first = false
        }
    }

    @inlinable
    public mutating func beginObject() {
        separate()
        bytes.append(0x7B)
        first = true
    }

    @inlinable
    public mutating func endObject() {
        bytes.append(0x7D)
        first = false
    }

    @inlinable
    public mutating func beginArray() {
        separate()
        bytes.append(0x5B)
        first = true
    }

    @inlinable
    public mutating func endArray() {
        bytes.append(0x5D)
        first = false
    }

    /// Writes a member name. The next value written becomes the member's value.
    @inlinable
    public mutating func key(_ name: String) {
        if !first { bytes.append(0x2C) }
        first = false
        appendQuoted(name)
        bytes.append(0x3A)
        afterKey = true
    }

    // MARK: Scalars

    @inlinable
    public mutating func writeNull() {
        separate()
        bytes.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C] as [UInt8])
    }

    @inlinable
    public mutating func write(_ value: Bool) {
        separate()
        if value {
            bytes.append(contentsOf: [0x74, 0x72, 0x75, 0x65] as [UInt8])
        } else {
            bytes.append(contentsOf: [0x66, 0x61, 0x6C, 0x73, 0x65] as [UInt8])
        }
    }

    @inlinable
    public mutating func write(_ value: Int) {
        separate()
        appendInteger(Int64(value))
    }

    @inlinable
    public mutating func write(_ value: Int64) {
        separate()
        appendInteger(value)
    }

    /// Non-finite values are written as `null`: JSON has no spelling for them.
    public mutating func write(_ value: Double) {
        separate()
        if value.isFinite {
            bytes.append(contentsOf: JSONNumber.format(value).utf8)
        } else {
            bytes.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C] as [UInt8])
        }
    }

    @inlinable
    public mutating func write(_ value: String) {
        separate()
        appendQuoted(value)
    }

    public mutating func write(_ value: JSONNumber) {
        separate()
        switch value.storage {
        case .int(let integer): appendInteger(integer)
        case .double(let double): bytes.append(contentsOf: JSONNumber.format(double).utf8)
        case .lexeme(let text): bytes.append(contentsOf: text.utf8)
        }
    }

    public mutating func write(_ value: JSONValue) {
        switch value {
        case .null: writeNull()
        case .bool(let bool): write(bool)
        case .number(let number): write(number)
        case .string(let string): write(string)
        case .array(let array):
            beginArray()
            for element in array { write(element) }
            endArray()
        case .object(let object): write(object)
        }
    }

    public mutating func write(_ object: JSONObject) {
        beginObject()
        for index in object.keys.indices {
            key(object.keys[index])
            write(object.values[index])
        }
        endObject()
    }

    /// Splices already-encoded JSON text for one complete value.
    @inlinable
    public mutating func writeRaw(_ json: [UInt8]) {
        separate()
        bytes.append(contentsOf: json)
    }

    /// Splices already-encoded object members (`"key":value` pairs, comma-separated) into the
    /// object being written.
    @inlinable
    public mutating func writeRawMembers(_ members: [UInt8]) {
        guard !members.isEmpty else { return }
        if !first { bytes.append(0x2C) }
        first = false
        bytes.append(contentsOf: members)
    }

    @inlinable
    public mutating func write<T: JSONEncodable>(_ value: T) {
        value.encode(to: &self)
    }

    // MARK: Members

    @inlinable
    public mutating func field<T: JSONEncodable>(_ name: String, _ value: T) {
        key(name)
        value.encode(to: &self)
    }

    /// Writes the member only when `value` is present.
    @inlinable
    public mutating func field<T: JSONEncodable>(_ name: String, _ value: T?) {
        guard let value else { return }
        key(name)
        value.encode(to: &self)
    }

    /// Writes the member only when the array is non-empty.
    @inlinable
    public mutating func field<T: JSONEncodable>(_ name: String, nonEmpty value: [T]) {
        guard !value.isEmpty else { return }
        key(name)
        value.encode(to: &self)
    }

    @inlinable
    public mutating func rawField(_ name: String, _ json: [UInt8]) {
        key(name)
        writeRaw(json)
    }

    // MARK: Internals

    @usableFromInline
    mutating func appendInteger(_ value: Int64) {
        if value >= 0, value < 10 {
            bytes.append(0x30 &+ UInt8(truncatingIfNeeded: value))
            return
        }
        var magnitude = value.magnitude
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var position = 20
        repeat {
            position -= 1
            digits[position] = 0x30 &+ UInt8(truncatingIfNeeded: magnitude % 10)
            magnitude /= 10
        } while magnitude != 0
        if value < 0 { bytes.append(0x2D) }
        for index in position..<20 { bytes.append(digits[index]) }
    }

    /// Writes `string` in quotes, escaping only what JSON requires.
    ///
    /// The scan runs eight bytes at a time and copies clean runs in one block; MCP results are
    /// dominated by long text, so this loop is the server's hot path for large responses.
    @usableFromInline
    mutating func appendQuoted(_ string: String) {
        #if FoundationJSON
        if FoundationJSON.appendQuoted(string, to: &bytes) { return }
        #endif
        bytes.append(0x22)
        let span = string.utf8Span.span
        let count = span.count
        var runStart = 0
        var index = 0
        let raw = span.bytes
        while index < count {
            while index &+ 8 <= count {
                let word = unsafe raw.unsafeLoadUnaligned(fromByteOffset: index, as: UInt64.self)
                if JSONWriter.needsEscape(word) { break }
                index &+= 8
            }
            guard index < count else { break }
            let byte = span[index]
            if byte >= 0x20 && byte != 0x22 && byte != 0x5C {
                index &+= 1
                continue
            }
            appendRun(span, runStart, index)
            appendEscape(byte)
            index &+= 1
            runStart = index
        }
        appendRun(span, runStart, count)
        bytes.append(0x22)
    }

    @inline(__always)
    @usableFromInline
    static func needsEscape(_ word: UInt64) -> Bool {
        let ones: UInt64 = 0x0101_0101_0101_0101
        let highs: UInt64 = 0x8080_8080_8080_8080
        let control = (word &- ones &* 0x20) & ~word
        let quote = word ^ (ones &* 0x22)
        let backslash = word ^ (ones &* 0x5C)
        let hasQuote = (quote &- ones) & ~quote
        let hasBackslash = (backslash &- ones) & ~backslash
        return (control | hasQuote | hasBackslash) & highs != 0
    }

    @inline(__always)
    @usableFromInline
    mutating func appendRun(_ span: Span<UInt8>, _ start: Int, _ end: Int) {
        guard end > start else { return }
        span.extracting(start..<end).withUnsafeBufferPointer { buffer in
            unsafe bytes.append(contentsOf: buffer)
        }
    }

    @usableFromInline
    mutating func appendEscape(_ byte: UInt8) {
        bytes.append(0x5C)
        switch byte {
        case 0x22: bytes.append(0x22)
        case 0x5C: bytes.append(0x5C)
        case 0x0A: bytes.append(0x6E)
        case 0x0D: bytes.append(0x72)
        case 0x09: bytes.append(0x74)
        case 0x08: bytes.append(0x62)
        case 0x0C: bytes.append(0x66)
        default:
            let hex: StaticString = "0123456789abcdef"
            bytes.append(0x75)
            bytes.append(0x30)
            bytes.append(0x30)
            // Both indices are below 16, the length of `hex`.
            bytes.append(unsafe hex.utf8Start[Int(byte >> 4)])
            bytes.append(unsafe hex.utf8Start[Int(byte & 0x0F)])
        }
    }
}

// MARK: - Standard conformances

extension JSONValue: JSONEncodable {
    public func encode(to writer: inout JSONWriter) { writer.write(self) }

    /// Compact JSON bytes.
    public func encoded() -> [UInt8] {
        var writer = JSONWriter()
        writer.write(self)
        return writer.bytes
    }
}

extension JSONObject: JSONEncodable {
    public func encode(to writer: inout JSONWriter) { writer.write(self) }
}

extension JSONNumber: JSONEncodable {
    public func encode(to writer: inout JSONWriter) { writer.write(self) }
}

extension String: JSONEncodable {
    @inlinable public func encode(to writer: inout JSONWriter) { writer.write(self) }
}

extension Bool: JSONEncodable {
    @inlinable public func encode(to writer: inout JSONWriter) { writer.write(self) }
}

extension Int: JSONEncodable {
    @inlinable public func encode(to writer: inout JSONWriter) { writer.write(self) }
}

extension Int64: JSONEncodable {
    @inlinable public func encode(to writer: inout JSONWriter) { writer.write(self) }
}

extension Double: JSONEncodable {
    public func encode(to writer: inout JSONWriter) { writer.write(self) }
}

extension Array: JSONEncodable where Element: JSONEncodable {
    @inlinable
    public func encode(to writer: inout JSONWriter) {
        writer.beginArray()
        for element in self { element.encode(to: &writer) }
        writer.endArray()
    }
}

extension Optional: JSONEncodable where Wrapped: JSONEncodable {
    @inlinable
    public func encode(to writer: inout JSONWriter) {
        if let self { self.encode(to: &writer) } else { writer.writeNull() }
    }
}
