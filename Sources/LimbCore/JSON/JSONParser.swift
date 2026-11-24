/// Why a JSON text was rejected, and where.
public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case invalidUTF8
        case unexpectedEnd
        case unexpectedByte(UInt8)
        case invalidNumber
        case invalidEscape
        case invalidUnicodeEscape
        case controlCharacterInString
        case duplicateKey(String)
        case trailingData
        case depthLimitExceeded(Int)
        case nodeLimitExceeded(Int)
        /// Rejected without a more specific reason. Only the Foundation fallback codec reports
        /// this: `JSONSerialization` says neither what is wrong nor where. It also covers the
        /// few valid texts that codec refuses because it could not return them unchanged.
        case malformed
    }

    public var kind: Kind
    /// Byte offset of the problem in the input. For invalid UTF-8 it is the first byte that is
    /// not valid, whichever codec runs (the check comes before either). Other errors from the
    /// Foundation fallback codec do not say where the problem is and report 0.
    public var offset: Int

    public var description: String {
        let what: String
        switch kind {
        case .invalidUTF8: what = "input is not valid UTF-8"
        case .unexpectedEnd: what = "unexpected end of input"
        case .unexpectedByte(let byte): what = "unexpected byte 0x" + String(byte, radix: 16)
        case .invalidNumber: what = "malformed number"
        case .invalidEscape: what = "invalid escape sequence"
        case .invalidUnicodeEscape: what = "invalid \\u escape or unpaired surrogate"
        case .controlCharacterInString: what = "unescaped control character in string"
        case .duplicateKey(let key): what = "duplicate object key \"\(key)\""
        case .trailingData: what = "unexpected data after the JSON value"
        case .depthLimitExceeded(let limit): what = "nesting deeper than \(limit)"
        case .nodeLimitExceeded(let limit): what = "more than \(limit) values"
        case .malformed: return "input is not valid JSON, or the Foundation codec cannot represent it"
        }
        return "\(what) at byte \(offset)"
    }
}

/// Limits and strictness for parsing. Every parser is attack surface, so the limits are on by default.
public struct JSONParseOptions: Sendable {
    /// Maximum nesting of arrays and objects. Negative values become zero.
    /// Values above `depthCeiling` have no effect.
    public var maxDepth: Int {
        didSet { if maxDepth < 0 { maxDepth = 0 } }
    }
    /// The deepest nesting any parse accepts, whatever `maxDepth` says.
    ///
    /// The parser itself could go deeper — it does not recurse. The value it returns cannot:
    /// destroying, comparing, hashing and encoding a `JSONValue` all recurse once per level, so
    /// a few thousand levels of `[` would parse and then overflow the stack when the value is
    /// dropped. At this depth those operations fit the smallest stack Swift tasks run on with
    /// room to spare, in unoptimized builds too.
    public static let depthCeiling = 256
    /// Maximum number of values in the whole document. Bounds memory amplification:
    /// `[0,0,0,…]` costs two input bytes but a full `JSONValue` per element.
    /// Negative values become zero.
    public var maxNodes: Int {
        didSet { if maxNodes < 0 { maxNodes = 0 } }
    }
    /// Reject objects that repeat a key. Parsers disagree on which duplicate wins, which is
    /// a known way to smuggle a value past one component and into another.
    public var rejectDuplicateKeys: Bool

    public init(maxDepth: Int = 128, maxNodes: Int = 1_000_000, rejectDuplicateKeys: Bool = true) {
        self.maxDepth = max(0, maxDepth)
        self.maxNodes = max(0, maxNodes)
        self.rejectDuplicateKeys = rejectDuplicateKeys
    }

    public static let `default` = JSONParseOptions()
}

/// A strict RFC 8259 parser: one pass, no recovery, no extensions.
///
/// Rejects what lenient parsers let through (`[1,]`, `{"a":1,}`, leading zeros, unpaired
/// surrogates, raw control characters) and accepts what they wrongly refuse (`1e400`).
public enum JSON {
    /// Which implementation parses input and escapes strings in this build.
    public enum Codec: String, Sendable {
        /// Limb's own strict parser and encoder. The default.
        case limb
        /// `JSONSerialization`, selected by the package trait `FoundationJSON`. A fallback:
        /// it is slower and accepts duplicate keys and trailing commas.
        case foundation
    }

    /// Fixed at build time by the package trait `FoundationJSON`.
    public static var codec: Codec {
        #if FoundationJSON
        .foundation
        #else
        .limb
        #endif
    }

    /// Parses a complete JSON text from UTF-8 bytes.
    public static func parse(
        _ bytes: Span<UInt8>, options: JSONParseOptions = .default
    ) throws(JSONParseError) -> JSONValue {
        do {
            _ = try UTF8Span(validating: bytes)
        } catch {
            throw JSONParseError(kind: .invalidUTF8, offset: error.byteOffsets.lowerBound)
        }
        #if FoundationJSON
        return try FoundationJSON.parse(bytes, options: options)
        #else
        return try parseValidated(bytes, options: options)
        #endif
    }

    public static func parse(
        _ bytes: [UInt8], options: JSONParseOptions = .default
    ) throws(JSONParseError) -> JSONValue {
        try parse(bytes.span, options: options)
    }

    public static func parse(
        _ text: String, options: JSONParseOptions = .default
    ) throws(JSONParseError) -> JSONValue {
        // A String is valid UTF-8 by construction.
        #if FoundationJSON
        try FoundationJSON.parse(text.utf8Span.span, options: options)
        #else
        try parseValidated(text.utf8Span.span, options: options)
        #endif
    }

    static func parseStrict(_ text: String) throws(JSONParseError) -> JSONValue {
        try parseValidated(text.utf8Span.span, options: .default)
    }

    static func parseValidated(
        _ bytes: Span<UInt8>, options: JSONParseOptions
    ) throws(JSONParseError) -> JSONValue {
        var state = ParserState(options: options)
        var index = 0
        skipWhitespace(bytes, &index)
        let value = try parseValue(bytes, &index, &state)
        skipWhitespace(bytes, &index)
        guard index == bytes.count else { throw JSONParseError(kind: .trailingData, offset: index) }
        return value
    }
}

struct ParserState {
    let options: JSONParseOptions
    var nodes = 0
    var scratch: [UInt8] = []
}

@inline(__always)
private func skipWhitespace(_ bytes: Span<UInt8>, _ index: inout Int) {
    let count = bytes.count
    while index < count {
        let byte = bytes[index]
        guard byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 else { return }
        index &+= 1
    }
}

/// A container whose members are still being read.
private struct OpenContainer {
    let isObject: Bool
    /// Array elements, or the values of an object in member order.
    var values: [JSONValue] = []
    var keys: [String] = []
    /// Where each key is, once there are enough members for a linear search to matter: without
    /// it, finding a repeated key is quadratic in attacker-controlled input. The finished object
    /// keeps it.
    var index: [ExactString: Int]? = nil
    /// The name the value being read will be stored under.
    var key = ""

    /// The finished container as a value.
    consuming func finish() -> JSONValue {
        isObject ? .object(JSONObject(uniqueKeys: keys, values: values, positions: index)) : .array(values)
    }
}

/// Parses one value. Nesting is kept in an array rather than in the call stack, so the depth a
/// document may have is a count and nothing else: it does not depend on how much stack the
/// thread has left or on how large the frames of this build happen to be.
private func parseValue(
    _ bytes: Span<UInt8>, _ index: inout Int, _ state: inout ParserState
) throws(JSONParseError) -> JSONValue {
    // The container being filled lives in a local; only its ancestors are in the array. Most
    // values are added to the innermost container, and this keeps that path free of the
    // array's bounds and uniqueness checks.
    var current = OpenContainer(isObject: false)
    var ancestors: [OpenContainer] = []
    var depth = 0
    let count = bytes.count
    let maxDepth = min(state.options.maxDepth, JSONParseOptions.depthCeiling)
    while true {
        guard index < count else { throw JSONParseError(kind: .unexpectedEnd, offset: index) }
        state.nodes &+= 1
        if state.nodes > state.options.maxNodes {
            throw JSONParseError(kind: .nodeLimitExceeded(state.options.maxNodes), offset: index)
        }
        let byte = bytes[index]
        var value: JSONValue
        switch byte {
        case 0x22:
            value = .string(try parseString(bytes, &index, &state))
        case 0x7B, 0x5B:
            let isObject = byte == 0x7B
            guard depth < maxDepth else {
                throw JSONParseError(kind: .depthLimitExceeded(maxDepth), offset: index)
            }
            index &+= 1
            skipWhitespace(bytes, &index)
            guard index < count else { throw JSONParseError(kind: .unexpectedEnd, offset: index) }
            if bytes[index] == (isObject ? 0x7D : 0x5D) {
                index &+= 1
                value = isObject ? .object(JSONObject()) : .array([])
            } else {
                // Moved, not copied: a copy would retain and release every buffer it holds.
                if depth > 0 { ancestors.append(consume current) }
                current = OpenContainer(isObject: isObject)
                depth &+= 1
                if isObject { try parseKey(bytes, &index, &state, &current) }
                continue
            }
        case 0x2D, 0x30...0x39:
            value = .number(try parseNumber(bytes, &index))
        case 0x74:
            try expectLiteral(bytes, &index, 0x74, 0x72, 0x75, 0x65)
            value = .bool(true)
        case 0x66:
            guard index &+ 4 < count, bytes[index &+ 4] == 0x65 else {
                throw JSONParseError(kind: index &+ 4 < count ? .unexpectedByte(byte) : .unexpectedEnd, offset: index)
            }
            try expectLiteral(bytes, &index, 0x66, 0x61, 0x6C, 0x73)
            index &+= 1
            value = .bool(false)
        case 0x6E:
            try expectLiteral(bytes, &index, 0x6E, 0x75, 0x6C, 0x6C)
            value = .null
        default:
            throw JSONParseError(kind: .unexpectedByte(byte), offset: index)
        }

        // Hand the finished value to the container it belongs to. A container that closes here
        // becomes the value for the one above it.
        while true {
            guard depth > 0 else { return value }
            let isObject = current.isObject
            if isObject {
                var existing: Int? = nil
                if !state.options.rejectDuplicateKeys {
                    if let index = current.index {
                        existing = index[ExactString(current.key)]
                    } else {
                        let key = current.key
                        existing = current.keys.firstIndex(where: { $0.isBytewiseEqual(to: key) })
                    }
                }
                if let existing {
                    current.values[existing] = value
                } else {
                    if current.index != nil { current.index![ExactString(current.key)] = current.keys.count }
                    current.keys.append(current.key)
                    current.values.append(value)
                }
            } else {
                current.values.append(value)
            }
            skipWhitespace(bytes, &index)
            guard index < count else { throw JSONParseError(kind: .unexpectedEnd, offset: index) }
            let next = bytes[index]
            index &+= 1
            if next == 0x2C {
                skipWhitespace(bytes, &index)
                if isObject { try parseKey(bytes, &index, &state, &current) }
                break
            }
            guard next == (isObject ? 0x7D : 0x5D) else {
                throw JSONParseError(kind: .unexpectedByte(next), offset: index &- 1)
            }
            value = (consume current).finish()
            depth &-= 1
            current = depth > 0 ? ancestors.removeLast() : OpenContainer(isObject: false)
        }
    }
}

/// Reads a member name and the colon after it, leaving `index` at the member's value.
private func parseKey(
    _ bytes: Span<UInt8>, _ index: inout Int, _ state: inout ParserState, _ container: inout OpenContainer
) throws(JSONParseError) {
    guard index < bytes.count else { throw JSONParseError(kind: .unexpectedEnd, offset: index) }
    guard bytes[index] == 0x22 else {
        throw JSONParseError(kind: .unexpectedByte(bytes[index]), offset: index)
    }
    let keyOffset = index
    let key = try parseString(bytes, &index, &state)
    if container.index == nil, container.keys.count >= JSONObject.indexThreshold {
        var index: [ExactString: Int] = [:]
        index.reserveCapacity(container.keys.count * 2)
        for (position, existing) in container.keys.enumerated() { index[ExactString(existing)] = position }
        container.index = index
    }
    if state.options.rejectDuplicateKeys {
        if let index = container.index {
            if index[ExactString(key)] != nil {
                throw JSONParseError(kind: .duplicateKey(key), offset: keyOffset)
            }
        } else {
            for existing in container.keys where existing.isBytewiseEqual(to: key) {
                throw JSONParseError(kind: .duplicateKey(key), offset: keyOffset)
            }
        }
    }
    skipWhitespace(bytes, &index)
    guard index < bytes.count else { throw JSONParseError(kind: .unexpectedEnd, offset: index) }
    guard bytes[index] == 0x3A else {
        throw JSONParseError(kind: .unexpectedByte(bytes[index]), offset: index)
    }
    index &+= 1
    skipWhitespace(bytes, &index)
    container.key = key
}

@inline(__always)
private func expectLiteral(
    _ bytes: Span<UInt8>, _ index: inout Int, _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8
) throws(JSONParseError) {
    guard index &+ 3 < bytes.count else { throw JSONParseError(kind: .unexpectedEnd, offset: index) }
    guard bytes[index] == a, bytes[index &+ 1] == b, bytes[index &+ 2] == c, bytes[index &+ 3] == d else {
        throw JSONParseError(kind: .unexpectedByte(bytes[index]), offset: index)
    }
    index &+= 4
}

func parseNumber(_ bytes: Span<UInt8>, _ index: inout Int) throws(JSONParseError) -> JSONNumber {
    let start = index
    let count = bytes.count
    var cursor = index
    var negative = false
    if bytes[cursor] == 0x2D {
        negative = true
        cursor &+= 1
        guard cursor < count else { throw JSONParseError(kind: .unexpectedEnd, offset: cursor) }
    }
    var magnitude: UInt64 = 0
    var digits = 0
    var isInteger = true
    let lead = bytes[cursor]
    if lead == 0x30 {
        cursor &+= 1
        digits = 1
        // A leading zero may not be followed by another digit.
        if cursor < count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            throw JSONParseError(kind: .invalidNumber, offset: cursor)
        }
    } else if lead >= 0x31, lead <= 0x39 {
        while cursor < count {
            let digit = bytes[cursor] &- 0x30
            guard digit <= 9 else { break }
            magnitude = magnitude &* 10 &+ UInt64(digit)
            digits &+= 1
            cursor &+= 1
        }
    } else {
        throw JSONParseError(kind: .invalidNumber, offset: cursor)
    }
    if cursor < count, bytes[cursor] == 0x2E {
        isInteger = false
        cursor &+= 1
        let fractionStart = cursor
        while cursor < count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 { cursor &+= 1 }
        guard cursor > fractionStart else {
            throw JSONParseError(kind: cursor < count ? .invalidNumber : .unexpectedEnd, offset: cursor)
        }
    }
    if cursor < count, bytes[cursor] == 0x65 || bytes[cursor] == 0x45 {
        isInteger = false
        cursor &+= 1
        if cursor < count, bytes[cursor] == 0x2B || bytes[cursor] == 0x2D { cursor &+= 1 }
        let exponentStart = cursor
        while cursor < count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 { cursor &+= 1 }
        guard cursor > exponentStart else {
            throw JSONParseError(kind: cursor < count ? .invalidNumber : .unexpectedEnd, offset: cursor)
        }
    }
    index = cursor
    // 18 digits always fit Int64. "-0" keeps its text: it is not the integer 0 lexically.
    if isInteger, digits <= 18, !(negative && magnitude == 0) {
        let value = Int64(bitPattern: magnitude)
        return JSONNumber(negative ? -value : value)
    }
    return JSONNumber(validatedLexeme: makeString(bytes, start, cursor))
}

/// The input was validated as UTF-8 up front and both bounds sit on ASCII bytes, so the slice
/// is valid UTF-8 and needs no second validation.
@inline(__always)
private func makeString(_ bytes: Span<UInt8>, _ start: Int, _ end: Int) -> String {
    if start == end { return "" }
    let slice = unsafe UTF8Span(unchecked: bytes.extracting(start..<end))
    return String(copying: slice)
}

private func parseString(
    _ bytes: Span<UInt8>, _ index: inout Int, _ state: inout ParserState
) throws(JSONParseError) -> String {
    let count = bytes.count
    let start = index &+ 1
    var cursor = start
    let raw = bytes.bytes
    // Fast path: no escapes. Skip eight clean bytes at a time.
    while true {
        while cursor &+ 8 <= count {
            let word = unsafe raw.unsafeLoadUnaligned(fromByteOffset: cursor, as: UInt64.self)
            if JSONWriter.needsEscape(word) { break }
            cursor &+= 8
        }
        guard cursor < count else { throw JSONParseError(kind: .unexpectedEnd, offset: cursor) }
        let byte = bytes[cursor]
        if byte == 0x22 {
            index = cursor &+ 1
            return makeString(bytes, start, cursor)
        }
        if byte == 0x5C { break }
        if byte < 0x20 { throw JSONParseError(kind: .controlCharacterInString, offset: cursor) }
        cursor &+= 1
    }

    // Slow path: unescape into the scratch buffer.
    state.scratch.removeAll(keepingCapacity: true)
    appendSlice(bytes, start, cursor, to: &state.scratch)
    while true {
        guard cursor < count else { throw JSONParseError(kind: .unexpectedEnd, offset: cursor) }
        let byte = bytes[cursor]
        if byte == 0x22 {
            index = cursor &+ 1
            // Escapes can only produce scalars we encoded ourselves, so this is valid UTF-8.
            return String(decoding: state.scratch, as: UTF8.self)
        }
        if byte < 0x20 { throw JSONParseError(kind: .controlCharacterInString, offset: cursor) }
        if byte != 0x5C {
            let runStart = cursor
            cursor &+= 1
            while cursor < count {
                let next = bytes[cursor]
                if next == 0x22 || next == 0x5C || next < 0x20 { break }
                cursor &+= 1
            }
            appendSlice(bytes, runStart, cursor, to: &state.scratch)
            continue
        }
        cursor &+= 1
        guard cursor < count else { throw JSONParseError(kind: .unexpectedEnd, offset: cursor) }
        let escape = bytes[cursor]
        cursor &+= 1
        switch escape {
        case 0x22: state.scratch.append(0x22)
        case 0x5C: state.scratch.append(0x5C)
        case 0x2F: state.scratch.append(0x2F)
        case 0x62: state.scratch.append(0x08)
        case 0x66: state.scratch.append(0x0C)
        case 0x6E: state.scratch.append(0x0A)
        case 0x72: state.scratch.append(0x0D)
        case 0x74: state.scratch.append(0x09)
        case 0x75:
            let first = try parseHex4(bytes, &cursor)
            var scalarValue = UInt32(first)
            if first >= 0xD800, first <= 0xDBFF {
                guard cursor &+ 1 < count, bytes[cursor] == 0x5C, bytes[cursor &+ 1] == 0x75 else {
                    throw JSONParseError(kind: .invalidUnicodeEscape, offset: cursor)
                }
                cursor &+= 2
                let second = try parseHex4(bytes, &cursor)
                guard second >= 0xDC00, second <= 0xDFFF else {
                    throw JSONParseError(kind: .invalidUnicodeEscape, offset: cursor)
                }
                scalarValue = 0x10000 &+ ((UInt32(first) &- 0xD800) << 10) &+ (UInt32(second) &- 0xDC00)
            } else if first >= 0xDC00, first <= 0xDFFF {
                throw JSONParseError(kind: .invalidUnicodeEscape, offset: cursor)
            }
            guard let scalar = Unicode.Scalar(scalarValue) else {
                throw JSONParseError(kind: .invalidUnicodeEscape, offset: cursor)
            }
            if let encoded = UTF8.encode(scalar) { state.scratch.append(contentsOf: encoded) }
        default:
            throw JSONParseError(kind: .invalidEscape, offset: cursor &- 1)
        }
    }
}

@inline(__always)
private func appendSlice(_ bytes: Span<UInt8>, _ start: Int, _ end: Int, to buffer: inout [UInt8]) {
    guard end > start else { return }
    bytes.extracting(start..<end).withUnsafeBufferPointer { pointer in
        unsafe buffer.append(contentsOf: pointer)
    }
}

private func parseHex4(_ bytes: Span<UInt8>, _ cursor: inout Int) throws(JSONParseError) -> UInt16 {
    guard cursor &+ 4 <= bytes.count else { throw JSONParseError(kind: .unexpectedEnd, offset: cursor) }
    var value: UInt16 = 0
    for offset in 0..<4 {
        let byte = bytes[cursor &+ offset]
        let digit: UInt8
        switch byte {
        case 0x30...0x39: digit = byte &- 0x30
        case 0x41...0x46: digit = byte &- 0x41 &+ 10
        case 0x61...0x66: digit = byte &- 0x61 &+ 10
        default: throw JSONParseError(kind: .invalidUnicodeEscape, offset: cursor &+ offset)
        }
        value = value << 4 | UInt16(digit)
    }
    cursor &+= 4
    return value
}
