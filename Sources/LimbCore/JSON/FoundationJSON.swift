// The fallback codec: the same `JSON.parse` and `JSONWriter` surface on top of Foundation.
//
// Enable the package trait `FoundationJSON` to use Foundation for parsing and string escaping.
#if FoundationJSON
import Foundation

enum FoundationJSON {
    /// Parses with `JSONSerialization` and converts the result to `JSONValue`.
    ///
    /// The input scan checks nesting and protects number text before Foundation sees it.
    /// `maxNodes` is applied while converting, that is
    /// after Foundation has already built its own tree: it bounds what Limb keeps, not what
    /// Foundation allocates. `rejectDuplicateKeys` cannot be honoured — Foundation keeps one of
    /// the duplicates silently.
    static func parse(_ bytes: Span<UInt8>, options: JSONParseOptions) throws(JSONParseError) -> JSONValue {
        let stack = StackGuard.remaining
        let ceiling = stack == nil ? blindDepthCeiling : depthCeiling
        let limit = min(options.maxDepth, ceiling)
        let prepared = try prepare(bytes, maxDepth: limit)
        if let stack, prepared.deepest * stackPerLevel + stackReserve > stack {
            throw JSONParseError(kind: .depthLimitExceeded(limit), offset: 0)
        }
        let data = Data(prepared.bytes)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONParseError(kind: .malformed, offset: 0)
        }
        var conversion = Conversion(options: options, protectedStrings: prepared.strings)
        return try conversion.convert(object)
    }

    /// The deepest nesting ever handed to Foundation, whatever `maxDepth` says.
    ///
    /// `JSONSerialization` recurses and has no usable limit of its own: 512 nested objects
    /// overflow a 512 KiB thread stack — the size handlers run on — and the process dies with
    /// SIGBUS. So nesting is counted here first.
    static let depthCeiling = 128
    /// The ceiling on a platform that does not report how much stack the thread has left.
    static let blindDepthCeiling = 64
    /// Stack reserved per level of nesting before handing input to Foundation.
    static let stackPerLevel = 2048
    static let stackReserve = 32 * 1024

    private struct Prepared {
        var bytes: [UInt8] = []
        var strings: [String] = []
        var deepest = 0
    }

    /// Tags strings and numbers before Foundation's structural parse. Object keys use ASCII
    /// handles so bridging through Swift dictionaries preserves byte-distinct names. Strings
    /// containing an interior U+FEFF use handles too because Foundation may drop that scalar.
    private static func prepare(_ bytes: Span<UInt8>, maxDepth: Int) throws(JSONParseError) -> Prepared {
        guard !startsWithByteOrderMark(bytes, at: 0) else {
            throw JSONParseError(kind: .unexpectedByte(0xEF), offset: 0)
        }
        var prepared = Prepared()
        prepared.bytes.reserveCapacity(bytes.count)
        var keys: [ExactString: Int] = [:]
        var depth = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0 { throw JSONParseError(kind: .unexpectedByte(0), offset: index) }
            if byte == 0x22 {
                let start = index
                guard !startsWithByteOrderMark(bytes, at: start + 1) else {
                    throw JSONParseError(kind: .malformed, offset: start)
                }
                var hasInnerBOM = false
                index += 1
                while index < bytes.count, bytes[index] != 0x22 {
                    if bytes[index] == 0 { throw JSONParseError(kind: .unexpectedByte(0), offset: index) }
                    if !hasInnerBOM, bytes[index] == 0xEF || bytes[index] == 0x5C {
                        hasInnerBOM = startsWithByteOrderMark(bytes, at: index)
                    }
                    index += bytes[index] == 0x5C ? 2 : 1
                }
                guard index < bytes.count else { throw JSONParseError(kind: .malformed, offset: 0) }
                let closing = index
                index += 1

                var next = index
                while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
                let isKey = next < bytes.count && bytes[next] == 0x3A
                prepared.bytes.append(0x22)
                if isKey || hasInnerBOM {
                    guard let decoded = try? JSON.parseValidated(bytes.extracting(start..<index), options: .default),
                        let string = decoded.stringValue else { throw JSONParseError(kind: .malformed, offset: 0) }

                    let key = ExactString(string)
                    let position: Int
                    if isKey, let existing = keys[key] {
                        position = existing
                    } else {
                        position = prepared.strings.count
                        prepared.strings.append(string)
                        if isKey { keys[key] = position }
                    }
                    prepared.bytes.append(isKey ? 0x6B : 0x76) // key or protected value.
                    prepared.bytes.append(contentsOf: String(position).utf8)
                } else {
                    prepared.bytes.append(0x73) // Unprotected string.
                    bytes.extracting((start + 1)..<closing).withUnsafeBufferPointer { pointer in
                        unsafe prepared.bytes.append(contentsOf: pointer)
                    }
                }
                prepared.bytes.append(0x22)
            } else if byte == 0x2D || (0x30...0x39).contains(byte) {
                let start = index
                do {
                    _ = try parseNumber(bytes, &index)
                } catch {
                    throw JSONParseError(kind: .malformed, offset: 0)
                }
                prepared.bytes.append(0x22)
                prepared.bytes.append(0x6E) // Exact number text.
                bytes.extracting(start..<index).withUnsafeBufferPointer { pointer in
                    unsafe prepared.bytes.append(contentsOf: pointer)
                }
                prepared.bytes.append(0x22)
            } else {
                prepared.bytes.append(byte)
                if byte == 0x5B || byte == 0x7B {
                    depth += 1
                    if depth > maxDepth {
                        throw JSONParseError(kind: .depthLimitExceeded(maxDepth), offset: index)
                    }
                    prepared.deepest = max(depth, prepared.deepest)
                } else if (byte == 0x5D || byte == 0x7D), depth > 0 {
                    depth -= 1
                }
                index += 1
            }
        }
        return prepared
    }

    /// Whether U+FEFF starts at `index`, as the bytes `EF BB BF` or as the escape `\uFEFF`.
    private static func startsWithByteOrderMark(_ bytes: Span<UInt8>, at index: Int) -> Bool {
        let count = bytes.count
        if index + 3 <= count, bytes[index] == 0xEF, bytes[index + 1] == 0xBB, bytes[index + 2] == 0xBF {
            return true
        }
        guard index + 6 <= count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else { return false }
        func isHex(_ byte: UInt8, _ digit: UInt8) -> Bool { byte | 0x20 == digit }
        return isHex(bytes[index + 2], 0x66) && isHex(bytes[index + 3], 0x65)
            && isHex(bytes[index + 4], 0x66) && isHex(bytes[index + 5], 0x66)
    }

    /// Appends `string` as a quoted JSON string, escaped by Foundation.
    static func appendQuoted(_ string: String, to bytes: inout [UInt8]) -> Bool {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: string as NSString, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        else { return false }
        bytes.append(contentsOf: data)
        return true
    }

    /// Turns Foundation's tree into a `JSONValue` without recursion: the nesting lives in an
    /// array, so converting costs no stack however deep the value is.
    private struct Conversion {
        let options: JSONParseOptions
        var nodes = 0
        let protectedStrings: [String]

        /// A container that is being filled.
        private struct Frame {
            var array: NSArray?
            var dictionary: NSDictionary?
            var keys: [Any] = []
            /// Index of the next child to convert.
            var next = 0
            var items: [JSONValue] = []
            var objectKeys: [String] = []
            /// The name the child being converted will be stored under.
            var key = ""
        }

        mutating func convert(_ root: Any) throws(JSONParseError) -> JSONValue {
            var frames: [Frame] = []
            var pending = root
            while true {
                nodes += 1
                guard nodes <= options.maxNodes else {
                    throw JSONParseError(kind: .nodeLimitExceeded(options.maxNodes), offset: 0)
                }
                var value: JSONValue
                if let string = pending as? String {
                    let text = String(decoding: string.utf8.dropFirst(), as: UTF8.self)
                    switch string.utf8.first {
                    case 0x73:
                        value = .string(text)
                    case 0x6E:
                        value = .number(JSONNumber(validatedLexeme: text))
                    case 0x76:
                        guard let position = Int(text), protectedStrings.indices.contains(position) else {
                            throw JSONParseError(kind: .malformed, offset: 0)
                        }
                        value = .string(protectedStrings[position])
                    default:
                        throw JSONParseError(kind: .malformed, offset: 0)
                    }
                } else if let number = pending as? NSNumber {
                    // All JSON numbers were tagged as strings before the Foundation parse.
                    value = .bool(number.boolValue)
                } else if pending is NSNull {
                    value = .null
                } else if let array = pending as? NSArray {
                    // The Foundation collections are walked as they are: bridging a dictionary to
                    // `[String: Any]` would compare keys by canonical equivalence and merge
                    // distinct ones.
                    if array.count > 0 {
                        try descend(frames.count)
                        var frame = Frame(array: array, next: 1)
                        frame.items.reserveCapacity(array.count)
                        frames.append(frame)
                        pending = array[0]
                        continue
                    }
                    value = .array([])
                } else if let dictionary = pending as? NSDictionary {
                    if dictionary.count > 0 {
                        try descend(frames.count)
                        var frame = Frame(dictionary: dictionary, keys: dictionary.allKeys, next: 1)
                        frame.objectKeys.reserveCapacity(dictionary.count)
                        frame.items.reserveCapacity(dictionary.count)
                        (frame.key, pending) = try member(of: dictionary, named: frame.keys[0])
                        frames.append(frame)
                        continue
                    }
                    value = .object(JSONObject())
                } else {
                    throw JSONParseError(kind: .malformed, offset: 0)
                }

                // Hand the finished value to its container; a container that is now complete
                // becomes the value for the one above it.
                while true {
                    guard !frames.isEmpty else { return value }
                    let top = frames.count - 1
                    let next = frames[top].next
                    if let array = frames[top].array {
                        frames[top].items.append(value)
                        if next < array.count {
                            frames[top].next = next + 1
                            pending = array[next]
                            break
                        }
                        value = .array(frames.removeLast().items)
                    } else if let dictionary = frames[top].dictionary {
                        // Collect unique decoded keys and build the lookup index once. Updating
                        // an indexed object inside the conversion stack can copy its dictionary
                        // on every insertion on Swift 6.2.
                        let key = frames[top].key
                        frames[top].objectKeys.append(key)
                        frames[top].items.append(value)
                        if next < frames[top].keys.count {
                            frames[top].next = next + 1
                            (frames[top].key, pending) = try member(of: dictionary, named: frames[top].keys[next])
                            break
                        }
                        let finished = frames.removeLast()
                        value = .object(JSONObject(uniqueKeys: finished.objectKeys, values: finished.items, positions: nil))
                    } else {
                        throw JSONParseError(kind: .malformed, offset: 0)
                    }
                }
            }
        }

        private func member(of dictionary: NSDictionary, named key: Any) throws(JSONParseError) -> (String, Any) {
            guard let name = key as? String, name.utf8.first == 0x6B,
                let position = Int(name.dropFirst()), protectedStrings.indices.contains(position),
                let value = dictionary.object(forKey: key) else {
                throw JSONParseError(kind: .malformed, offset: 0)
            }
            return (protectedStrings[position], value)
        }

        private func descend(_ depth: Int) throws(JSONParseError) {
            guard depth < options.maxDepth else {
                throw JSONParseError(kind: .depthLimitExceeded(options.maxDepth), offset: 0)
            }
        }

    }
}
#endif
