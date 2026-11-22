/// A JSON value with no "magic": a string stays a string, numbers keep their source text.
///
/// Objects preserve member order, so everything Limb emits is deterministic.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - JSONNumber

/// A JSON number that round-trips its lexical form.
///
/// `1.0` stays `1.0`, integers beyond 2⁵³ are not rounded, and `1e400` is representable even
/// though it does not fit a `Double`. Conversion to a machine type happens only on request.
///
/// Equality, ordering, hashing and the integer test are exact: a number is the decimal value
/// its text spells, never a rounded `Double`. `1`, `1.0` and `10e-1` are equal;
/// `100000000000000000001` and `1e20` are not; `1e400` is an integer and `1e-400` is not zero.
/// A number made from a `Double` is the decimal it is written as. The one approximation keeps
/// the arithmetic in 64 bits: numbers too large or too small to write out in a quintillion
/// digits merge. Written in scientific notation, d.ddd × 10^E, every number with E ≥ 10¹⁸ equals
/// every other of its sign and lies beyond all other numbers of that sign; every nonzero number
/// with E ≤ −(10¹⁸ + 2) equals every other of its sign and lies nearer to zero than all other
/// nonzero numbers. (In the form 0.ddd × 10^e the bounds are e > 10¹⁸ and e < −10¹⁸.) Equality
/// stays an equivalence and the order stays consistent with the true values. `doubleValue` is
/// the correctly rounded `Double` for a text of any length.
public struct JSONNumber: Sendable, CustomStringConvertible {
    @usableFromInline
    enum Storage: Sendable {
        case int(Int64)
        /// Always finite.
        case double(Double)
        /// Validated JSON number text that is not a canonical `Int64`.
        case lexeme(String)
    }

    @usableFromInline let storage: Storage

    @inlinable public init(_ value: Int64) { storage = .int(value) }
    @inlinable public init(_ value: Int) { storage = .int(Int64(value)) }

    /// Fails for NaN and infinities, which JSON cannot express.
    public init?(_ value: Double) {
        guard value.isFinite else { return nil }
        storage = .double(value)
    }

    /// Wraps number text. Fails if `lexeme` is not a valid JSON number.
    public init?(lexeme: String) {
        guard JSONNumber.isValidLexeme(lexeme) else { return nil }
        self.init(validatedLexeme: lexeme)
    }

    @usableFromInline
    init(validatedLexeme: String) {
        storage = .lexeme(validatedLexeme)
    }

    /// The exact text this number is written as.
    public var lexeme: String {
        switch storage {
        case .int(let value): return String(value)
        case .double(let value): return JSONNumber.format(value)
        case .lexeme(let text): return text
        }
    }

    public var description: String { lexeme }

    /// The value as an integer, if it is one exactly and fits (`1`, `1.0` and `1e2` are; `1.5`
    /// and `1.0000000000000000001` are not).
    public var int64Value: Int64? {
        switch storage {
        case .int(let value): return value
        case .double(let value) where value.magnitude < 0x1p53:
            // Below 2⁵³ a double is written with every digit it has, so its text and its binary
            // value agree. Above, they may not (2⁶⁰ is written 1.152921504606847e+18), and the
            // text is what every reader sees.
            return Int64(exactly: value)
        case .double, .lexeme: return decimal.int64Value
        }
    }

    public var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    /// The nearest `Double`; infinite if the number is out of range, zero if it is too small.
    public var doubleValue: Double {
        switch storage {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .lexeme(let text):
            // `Double(String)` rounds correctly, out-of-range values to ±∞ or ±0, but returns
            // nil for any text longer than 16,384 bytes, however valid. Such texts, and any
            // other it should refuse, go the long way.
            if text.utf8.count <= 16_384, let value = Double(text) { return value }
            return decimal.nearestDouble(negativeZero: text.utf8.first == 0x2D)
        }
    }

    /// Whether the value is mathematically an integer (JSON Schema's `integer`), however large.
    public var isInteger: Bool {
        switch storage {
        case .int: return true
        case .double(let value) where value.magnitude < 0x1p53: return value.rounded(.towardZero) == value
        case .double, .lexeme: return decimal.isInteger
        }
    }

    /// The exact value, for comparison and arithmetic.
    var decimal: ExactDecimal {
        switch storage {
        case .int(let value): return ExactDecimal(value)
        case .double: return ExactDecimal(validated: lexeme)
        case .lexeme(let text): return ExactDecimal(validated: text)
        }
    }

    static func format(_ value: Double) -> String {
        // Swift prints the shortest text that round-trips; "5.0" and "1e+100" are both valid JSON.
        value.description
    }

    static func isValidLexeme(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var i = 0
        let n = bytes.count
        func digits() -> Bool {
            let start = i
            while i < n, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            return i > start
        }
        if i < n, bytes[i] == 0x2D { i += 1 }
        guard i < n else { return false }
        if bytes[i] == 0x30 { i += 1 } else if !digits() { return false }
        if i < n, bytes[i] == 0x2E {
            i += 1
            if !digits() { return false }
        }
        if i < n, bytes[i] == 0x65 || bytes[i] == 0x45 {
            i += 1
            if i < n, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            if !digits() { return false }
        }
        return i == n
    }
}

extension JSONNumber: Hashable, Comparable {
    /// Numeric equality on the exact decimal value: `1`, `1.0` and `1e0` are equal, and so are
    /// `-0` and `0`.
    public static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.int(let a), .int(let b)): a == b
        // Distinct doubles are written differently, and equal ones alike (both zeros are zero).
        case (.double(let a), .double(let b)): a == b
        default: lhs.decimal == rhs.decimal
        }
    }

    public static func < (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        if case .int(let a) = lhs.storage, case .int(let b) = rhs.storage { return a < b }
        return ExactDecimal.compare(lhs.decimal, rhs.decimal) < 0
    }

    public func hash(into hasher: inout Hasher) {
        // An integer that fits hashes as that integer, which spares the common case the exact
        // form; every number equal to it is that same integer, so it hashes the same way.
        if case .int(let value) = storage {
            hasher.combine(value)
            return
        }
        let exact = decimal
        if let value = exact.int64Value {
            hasher.combine(value)
        } else {
            hasher.combine(exact)
        }
    }
}

extension JSONNumber: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int64) { self.init(value) }

    /// A literal too large for a `Double` (`1e400`) arrives here as infinity, which JSON cannot
    /// express: that is a programming error, not a value. Write it with `init(lexeme:)`.
    public init(floatLiteral value: Double) {
        precondition(value.isFinite, "JSONNumber: \(value) cannot be written as JSON; use JSONNumber(lexeme:)")
        storage = .double(value)
    }
}

/// A number as the decimal its text spells: `±0.d₁d₂…dₙ × 10^exponent`, without leading or
/// trailing zero digits. Zero has no digits and is never negative, so equal values have equal
/// representations and the synthesized `==` and `hash(into:)` are numeric.
struct ExactDecimal: Hashable {
    var negative = false
    /// Digit values, 0 through 9.
    var digits: [UInt8] = []
    var exponent: Int64 = 0

    /// Exponents beyond this, either way, are merged; see `JSONNumber`.
    static let exponentBound: Int64 = 1_000_000_000_000_000_000
    /// Where reading a written exponent stops counting: far beyond the bound, and far enough
    /// from `Int64.max` that adding the position of the point cannot overflow.
    static let writtenCeiling: Int64 = 4 * exponentBound

    init(_ value: Int64) {
        guard value != 0 else { return }
        negative = value < 0
        var magnitude = value.magnitude
        while magnitude > 0 {
            digits.append(UInt8(magnitude % 10))
            magnitude /= 10
        }
        exponent = Int64(digits.count)
        digits.reverse()
        while digits.last == 0 { digits.removeLast() }
    }

    /// Reads number text that is already known to be valid JSON.
    init(validated text: String) {
        // Position of the decimal point relative to the first significant digit.
        var point: Int64 = 0
        var inFraction = false
        var inExponent = false
        var exponentNegative = false
        var written: Int64 = 0
        for byte in text.utf8 {
            switch byte {
            case 0x2D:
                if inExponent { exponentNegative = true } else { negative = true }
            case 0x2B:
                break
            case 0x2E:
                inFraction = true
            case 0x45, 0x65:
                inExponent = true
            default:
                let digit = byte &- 0x30
                if inExponent {
                    // Saturates: an exponent of any length is untrusted input.
                    written = written > ExactDecimal.writtenCeiling / 10
                        ? ExactDecimal.writtenCeiling : min(written * 10 + Int64(digit), ExactDecimal.writtenCeiling)
                } else if digits.isEmpty && digit == 0 {
                    // A leading zero: before the point it is nothing, after it a shift.
                    if inFraction { point -= 1 }
                } else {
                    digits.append(digit)
                    if !inFraction { point += 1 }
                }
            }
        }
        while digits.last == 0 { digits.removeLast() }
        if digits.isEmpty {
            negative = false
            return
        }
        // `point` is bounded by the length of the text, far below 2⁶², so this cannot overflow.
        exponent = point + (exponentNegative ? -written : written)
        // The clamp applies to the value's exponent, so that it is monotone: everything beyond
        // the bound becomes one value just past it.
        if exponent > ExactDecimal.exponentBound {
            digits = [1]
            exponent = ExactDecimal.exponentBound + 1
        } else if exponent < -ExactDecimal.exponentBound {
            digits = [1]
            exponent = -ExactDecimal.exponentBound - 1
        }
    }

    /// Zero has no digits and exponent 0, so it is an integer too.
    var isInteger: Bool { Int64(digits.count) <= exponent }

    var int64Value: Int64? {
        guard !digits.isEmpty else { return 0 }
        guard isInteger, exponent <= 19 else { return nil }
        var magnitude: UInt64 = 0
        for index in 0..<Int(exponent) {
            let digit = index < digits.count ? UInt64(digits[index]) : 0
            let (shifted, overflow) = magnitude.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            let (sum, carry) = shifted.addingReportingOverflow(digit)
            guard !carry else { return nil }
            magnitude = sum
        }
        if negative {
            guard magnitude <= Int64.min.magnitude else { return nil }
            return magnitude == Int64.min.magnitude ? .min : -Int64(magnitude)
        }
        return Int64(exactly: magnitude)
    }

    /// The correctly rounded `Double`, for any number of digits.
    ///
    /// How a decimal rounds to binary64 depends only on how it compares with the doubles and
    /// the midpoints between them, and none of those has more than 767 significant decimal
    /// digits. The first 800 digits, followed by one more nonzero digit if anything was dropped
    /// (the digits end in a nonzero digit, so anything dropped is nonzero), lie on the same side
    /// of every one of them as the full value — so they round the same way, and are short
    /// enough for `Double(String)`.
    ///
    /// - Parameter negativeZero: the sign to give zero, which the exact form does not keep.
    func nearestDouble(negativeZero: Bool) -> Double {
        guard !digits.isEmpty else { return negativeZero ? -0.0 : 0.0 }
        var text = negative ? "-0." : "0."
        for digit in digits.prefix(800) { text.unicodeScalars.append(Unicode.Scalar(0x30 + digit)) }
        if digits.count > 800 { text += "1" }
        text += "e\(exponent)"
        // At most 826 bytes of valid number text (the exponent is clamped to 19 digits), which
        // `Double(String)` always reads.
        return Double(text)!
    }

    /// -1, 0 or 1 as `lhs` is less than, equal to or greater than `rhs`.
    static func compare(_ lhs: ExactDecimal, _ rhs: ExactDecimal) -> Int {
        let leftSign = lhs.digits.isEmpty ? 0 : lhs.negative ? -1 : 1
        let rightSign = rhs.digits.isEmpty ? 0 : rhs.negative ? -1 : 1
        guard leftSign == rightSign else { return leftSign < rightSign ? -1 : 1 }
        guard leftSign != 0 else { return 0 }
        // With a nonzero leading digit, a larger exponent is a larger magnitude.
        if lhs.exponent != rhs.exponent { return lhs.exponent < rhs.exponent ? -leftSign : leftSign }
        for (left, right) in zip(lhs.digits, rhs.digits) where left != right {
            return left < right ? -leftSign : leftSign
        }
        if lhs.digits.count == rhs.digits.count { return 0 }
        return lhs.digits.count < rhs.digits.count ? -leftSign : leftSign
    }

    /// The value as `significand × 10^scale` with an integer significand, if that fits 64 bits.
    var integerSignificand: (significand: UInt64, scale: Int64)? {
        guard digits.count <= 19 else { return nil }
        var significand: UInt64 = 0
        for digit in digits { significand = significand * 10 + UInt64(digit) }
        return (significand, exponent - Int64(digits.count))
    }

    /// Whether the value divided by `divisor × 10^scale` is an integer, computed exactly.
    func isMultiple(of divisor: UInt64, scale: Int64) -> Bool {
        if digits.isEmpty { return true }
        // The value is A × 10^k with an integer A that does not end in zero. For k below the
        // divisor's scale the quotient keeps a factor 1/10 that no integer divisor can cancel.
        let shift = exponent - Int64(digits.count) - scale
        guard shift >= 0 else { return false }
        func multiply(_ a: UInt64, _ b: UInt64) -> UInt64 {
            divisor.dividingFullWidth(a.multipliedFullWidth(by: b)).remainder
        }
        var remainder: UInt64 = 0
        for digit in digits {
            let (high, low) = remainder.multipliedFullWidth(by: 10)
            let (sum, carry) = low.addingReportingOverflow(UInt64(digit))
            remainder = divisor.dividingFullWidth((high + (carry ? 1 : 0), sum)).remainder
        }
        // remainder × 10^shift, modulo the divisor, by repeated squaring.
        var power = 10 % divisor
        var exponent = shift
        while exponent > 0, remainder != 0 {
            if exponent & 1 == 1 { remainder = multiply(remainder, power) }
            power = multiply(power, power)
            exponent >>= 1
        }
        return remainder == 0
    }
}

// MARK: - JSONObject

/// An ordered JSON object.
///
/// Small objects are a pair of dense arrays searched by a linear scan: protocol objects have a
/// handful of members, and a scan beats hashing at that size. Past `indexThreshold` members the
/// object also keeps the position of every key, so that lookup, insertion, `merging` and `==`
/// stay linear in the size of the object as a whole — objects that large come from untrusted
/// input, and a scan per key would make them quadratic. Member order is the insertion order.
public struct JSONObject: Sendable {
    @usableFromInline var keys: [String]
    @usableFromInline var values: [JSONValue]
    /// Position of each key by its exact bytes. Present whenever there are more than
    /// `indexThreshold` members; it may stay after removals bring the count back down.
    @usableFromInline var positions: [ExactString: Int]?

    /// The most members an object is searched by scanning alone.
    @usableFromInline static let indexThreshold = 24

    @inlinable public init() {
        keys = []
        values = []
    }

    @inlinable
    public init(minimumCapacity: Int) {
        keys = []
        values = []
        keys.reserveCapacity(minimumCapacity)
        values.reserveCapacity(minimumCapacity)
    }

    /// Builds an object from pairs; a repeated key keeps its first position and takes the last value.
    public init(_ members: some Sequence<(String, JSONValue)>) {
        self.init()
        for (key, value) in members { self[key] = value }
    }

    /// For the parser, which has already checked the keys and, past the threshold, built the index.
    init(uniqueKeys keys: [String], values: [JSONValue], positions: [ExactString: Int]?) {
        self.keys = keys
        self.values = values
        self.positions = positions
        if positions == nil, keys.count > JSONObject.indexThreshold { buildPositions() }
    }

    @inlinable public var count: Int { keys.count }
    @inlinable public var isEmpty: Bool { keys.isEmpty }

    @inlinable
    func index(of key: String) -> Int? {
        if let positions { return positions[ExactString(key)] }
        for index in keys.indices where keys[index].isBytewiseEqual(to: key) { return index }
        return nil
    }

    @inlinable
    public subscript(key: String) -> JSONValue? {
        get { index(of: key).map { values[$0] } }
        set {
            if let index = index(of: key) {
                if let newValue {
                    values[index] = newValue
                } else {
                    remove(at: index)
                }
            } else if let newValue {
                appendUnchecked(key, newValue)
            }
        }
    }

    public func contains(_ key: String) -> Bool { index(of: key) != nil }

    /// Appends without checking for an existing key. The caller guarantees uniqueness.
    @inlinable
    public mutating func appendUnchecked(_ key: String, _ value: JSONValue) {
        keys.append(key)
        values.append(value)
        if positions != nil {
            // Present, checked on the line above; mutated in place rather than copied out.
            positions![ExactString(key)] = keys.count - 1
        } else if keys.count > JSONObject.indexThreshold {
            buildPositions()
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let index = index(of: key) else { return nil }
        let value = values[index]
        remove(at: index)
        return value
    }

    @usableFromInline
    mutating func remove(at index: Int) {
        let key = keys.remove(at: index)
        values.remove(at: index)
        guard positions != nil else { return }
        // Linear, like the removal from the arrays: every later member moves down by one.
        // `positions` is present (the guard above), and `index` was a valid position before
        // the removal, so `index..<keys.count` after it is a valid, possibly empty, range.
        positions!.removeValue(forKey: ExactString(key))
        for position in index..<keys.count { positions![ExactString(keys[position])] = position }
    }

    @usableFromInline
    mutating func buildPositions() {
        var positions: [ExactString: Int] = [:]
        positions.reserveCapacity(keys.count * 2)
        for (position, key) in keys.enumerated() { positions[ExactString(key)] = position }
        self.positions = positions
    }

    /// Returns a copy with `other`'s members written over this object's.
    public func merging(_ other: JSONObject) -> JSONObject {
        var result = self
        for (key, value) in other { result[key] = value }
        return result
    }
}

extension JSONObject: RandomAccessCollection {
    public typealias Element = (key: String, value: JSONValue)
    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { keys.count }
    @inlinable public subscript(position: Int) -> Element { (keys[position], values[position]) }
}

extension JSONObject: Hashable {
    /// Member order does not affect equality. Linear in the number of members: a large `rhs`
    /// is searched through its index.
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.keys.indices {
            guard let other = rhs[lhs.keys[index]], other == lhs.values[index] else { return false }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hash(into: &hasher, depth: 0)
    }

    func hash(into hasher: inout Hasher, depth: Int) {
        hasher.combine(count)
        guard depth < JSONValue.hashedDepth else { return }
        var combined = 0
        for index in keys.indices {
            var member = Hasher()
            member.combine(keys[index])
            values[index].hash(into: &member, depth: depth + 1)
            combined ^= member.finalize()
        }
        hasher.combine(combined)
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }
}

// MARK: - JSONValue conveniences

extension JSONValue: Hashable {
    /// JSON equality: numbers compare by value, objects ignore member order, and strings compare
    /// code point by code point.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a.isBytewiseEqual(to: b)
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hash(into: &hasher, depth: 0)
    }

    /// How many levels of nesting take part in a hash: as many as a parsed value can have.
    ///
    /// Below this depth a container contributes only its size, which bounds the recursion for
    /// values built in code to any depth. It must not be smaller than what the parser accepts:
    /// values that differ only below the hashed depth all collide, and a set of them degrades
    /// to comparing every element with every other.
    static let hashedDepth = JSONParseOptions.depthCeiling

    /// Levels of containers in this value: 0 for a scalar, 1 for a container of scalars.
    /// Does not recurse, so it is safe to ask before an operation that does.
    var nestingDepth: Int {
        guard isContainer else { return 0 }
        var deepest = 0
        var pending: [(value: JSONValue, depth: Int)] = [(self, 1)]
        while let (value, depth) = pending.popLast() {
            if depth > deepest { deepest = depth }
            switch value {
            case .array(let items):
                for item in items where item.isContainer { pending.append((item, depth + 1)) }
            case .object(let object):
                for item in object.values where item.isContainer { pending.append((item, depth + 1)) }
            default:
                break
            }
        }
        return deepest
    }

    var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }

    func hash(into hasher: inout Hasher, depth: Int) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .number(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .array(let value):
            hasher.combine(value.count)
            guard depth < JSONValue.hashedDepth else { return }
            for element in value { element.hash(into: &hasher, depth: depth + 1) }
        case .object(let value): value.hash(into: &hasher, depth: depth)
        }
    }
}

/// A string that is equal only to the same sequence of bytes, for use as a dictionary key.
///
/// `String` hashes and compares by canonical equivalence, which is not what a protocol means
/// by "the same name": "é" as one code point and "e" with a combining accent are different
/// keys, different tool names and different URIs.
public struct ExactString: Hashable, Sendable {
    public let text: String

    @inlinable public init(_ text: String) { self.text = text }

    public static func == (lhs: ExactString, rhs: ExactString) -> Bool { lhs.text.isBytewiseEqual(to: rhs.text) }

    public func hash(into hasher: inout Hasher) {
        text.utf8Span.span.withUnsafeBufferPointer { buffer in
            unsafe hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
        }
    }
}

extension String {
    /// Whether two strings are the same sequence of code points.
    ///
    /// Swift's `==` treats canonically equivalent strings as equal ("é" as one code point equals
    /// "e" followed by a combining accent). JSON does not: those are different strings and
    /// different object keys, and treating them as one would let two members collapse into one.
    @inlinable
    public func isBytewiseEqual(to other: String) -> Bool {
        let left = utf8Span.span
        let right = other.utf8Span.span
        let count = left.count
        guard count == right.count else { return false }
        var index = 0
        while index < count {
            if left[index] != right[index] { return false }
            index &+= 1
        }
        return true
    }
}

extension JSONValue {
    @inlinable public var isNull: Bool { if case .null = self { true } else { false } }
    @inlinable public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    @inlinable public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    @inlinable public var numberValue: JSONNumber? { if case .number(let value) = self { value } else { nil } }
    @inlinable public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    @inlinable public var objectValue: JSONObject? { if case .object(let value) = self { value } else { nil } }
    public var intValue: Int? { numberValue?.intValue }
    public var doubleValue: Double? { numberValue?.doubleValue }

    /// Member of an object; `nil` for other kinds and for missing keys.
    @inlinable
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    /// Element of an array; `nil` for other kinds and out-of-range indices.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// The JSON Schema name of this value's type.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number(let number): number.isInteger ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    public init(_ value: Int) { self = .number(JSONNumber(value)) }
    public init(_ value: String) { self = .string(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: JSONObject) { self = .object(value) }
    public init(_ value: [JSONValue]) { self = .array(value) }
    /// Non-finite doubles become `null`, as JSON has no way to write them.
    public init(_ value: Double) { self = JSONNumber(value).map(JSONValue.number) ?? .null }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .number(JSONNumber(value)) }
    public init(floatLiteral value: Double) { self = .number(JSONNumber(floatLiteral: value)) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

extension JSONValue: CustomStringConvertible {
    /// Compact JSON text.
    public var description: String {
        var writer = JSONWriter()
        writer.write(self)
        return String(decoding: writer.bytes, as: UTF8.self)
    }
}
