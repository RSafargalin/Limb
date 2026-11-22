// The fallback codec: the same `JSON.parse` and `JSONWriter` surface on top of Foundation.
//
// Enable the package trait `FoundationJSON` to use Foundation for parsing and string escaping.
#if FoundationJSON
import Foundation

enum FoundationJSON {
    /// Parses with `JSONSerialization` and converts the result to `JSONValue`.
    ///
    /// Everything that could make Foundation crash or silently change the data is refused before
    /// Foundation sees the input (`precheck`). `maxNodes` is applied while converting, that is
    /// after Foundation has already built its own tree: it bounds what Limb keeps, not what
    /// Foundation allocates. `rejectDuplicateKeys` cannot be honoured — Foundation keeps one of
    /// the duplicates silently.
    static func parse(_ bytes: Span<UInt8>, options: JSONParseOptions) throws(JSONParseError) -> JSONValue {
        let stack = StackGuard.remaining
        let ceiling = stack == nil ? blindDepthCeiling : depthCeiling
        let limit = min(options.maxDepth, ceiling)
        let deepest = try precheck(bytes, maxDepth: limit)
        if let stack, deepest * stackPerLevel + stackReserve > stack {
            throw JSONParseError(kind: .depthLimitExceeded(limit), offset: 0)
        }
        let data = bytes.withUnsafeBufferPointer { unsafe Data(buffer: $0) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONParseError(kind: .malformed, offset: 0)
        }
        var conversion = Conversion(options: options)
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

    /// Refuses input Foundation must not see and returns the deepest nesting found.
    ///
    /// This is a scan for brackets outside strings, not a parser. It follows the same rule for
    /// where a string ends as any JSON lexer, so on the prefix Foundation reads before its first
    /// error the two agree on depth.
    ///
    /// Refused:
    /// - zero bytes: Foundation sniffs UTF-16 and UTF-32, and a UTF-8 JSON text never has one;
    /// - a byte order mark before the text: Foundation skips it, RFC 8259 forbids sending it;
    /// - a string that starts with U+FEFF, raw or escaped: Foundation drops that character, so
    ///   `"\uFEFFa"` would come back as `"a"` and two different keys would become one. The
    ///   text is valid JSON; it is refused because this codec cannot return it unchanged;
    /// - nesting beyond `maxDepth`.
    private static func precheck(_ bytes: Span<UInt8>, maxDepth: Int) throws(JSONParseError) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var index = 0
        let count = bytes.count
        if startsWithByteOrderMark(bytes, at: 0) {
            throw JSONParseError(kind: .unexpectedByte(0xEF), offset: 0)
        }
        while index < count {
            let byte = bytes[index]
            if byte == 0 { throw JSONParseError(kind: .unexpectedByte(0), offset: index) }
            if inString {
                if byte == 0x5C {
                    index += 1
                } else if byte == 0x22 {
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
                if startsWithByteOrderMark(bytes, at: index + 1) {
                    throw JSONParseError(kind: .malformed, offset: index)
                }
            } else if byte == 0x5B || byte == 0x7B {
                depth += 1
                if depth > maxDepth {
                    throw JSONParseError(kind: .depthLimitExceeded(maxDepth), offset: index)
                }
                if depth > deepest { deepest = depth }
            } else if byte == 0x5D || byte == 0x7D {
                if depth > 0 { depth -= 1 }
            }
            index += 1
        }
        return deepest
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
        /// `true` and `false` come back as a private subclass of `NSNumber`; its class is the only
        /// thing that tells them from the numbers 1 and 0.
        let booleanClass: AnyClass = type(of: NSNumber(value: true))

        /// A container that is being filled.
        private struct Frame {
            var array: NSArray?
            var dictionary: NSDictionary?
            var keys: [Any] = []
            /// Index of the next child to convert.
            var next = 0
            var items: [JSONValue] = []
            var object = JSONObject()
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
                    value = .string(string)
                } else if let number = pending as? NSNumber {
                    value = try convert(number)
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
                        frame.object = JSONObject(minimumCapacity: dictionary.count)
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
                        frames[top].object.appendUnchecked(frames[top].key, value)
                        if next < frames[top].keys.count {
                            frames[top].next = next + 1
                            (frames[top].key, pending) = try member(of: dictionary, named: frames[top].keys[next])
                            break
                        }
                        value = .object(frames.removeLast().object)
                    } else {
                        throw JSONParseError(kind: .malformed, offset: 0)
                    }
                }
            }
        }

        private func member(of dictionary: NSDictionary, named key: Any) throws(JSONParseError) -> (String, Any) {
            guard let name = key as? String, let value = dictionary.object(forKey: key) else {
                throw JSONParseError(kind: .malformed, offset: 0)
            }
            return (name, value)
        }

        private func descend(_ depth: Int) throws(JSONParseError) {
            guard depth < options.maxDepth else {
                throw JSONParseError(kind: .depthLimitExceeded(options.maxDepth), offset: 0)
            }
        }

        /// Integers that fit `Int64` or `UInt64` are exact; every other number is a `Double`.
        ///
        /// Foundation returns an `NSDecimalNumber` for numbers a `Double` cannot hold exactly, and
        /// its text looks exact — but it keeps 38 digits and drops the rest without a trace, so
        /// a 39-digit integer comes back as a different integer. Nothing in the result tells a
        /// truncated value from a whole one, so the text is never trusted: such a number becomes
        /// a `Double`, which is at least visibly approximate when written back.
        private func convert(_ number: NSNumber) throws(JSONParseError) -> JSONValue {
            if type(of: number) == booleanClass { return .bool(number.boolValue) }
            if !(number is NSDecimalNumber) {
                switch unsafe number.objCType.pointee {
                case 0x64, 0x66:  // 'd', 'f'
                    break
                case 0x51:  // 'Q': above Int64.max the text is the only exact form
                    let value = number.uint64Value
                    if let small = Int64(exactly: value) { return .number(JSONNumber(small)) }
                    if let exact = JSONNumber(lexeme: String(value)) { return .number(exact) }
                default:
                    return .number(JSONNumber(number.int64Value))
                }
            }
            // `NSDecimalNumber.doubleValue` is not correctly rounded (`1e30` written out in full
            // comes back as 9.999999999999999e+29), so the decimal's text is read by Swift instead.
            let double = number is NSDecimalNumber ? Double(number.stringValue) ?? number.doubleValue : number.doubleValue
            guard let value = JSONNumber(double) else {
                throw JSONParseError(kind: .invalidNumber, offset: 0)
            }
            return .number(value)
        }
    }
}
#endif
