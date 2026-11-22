/// A compiled `pattern`: ECMA 262 regular expression syntax, matched by Unicode scalar in time
/// linear in the length of the string.
///
/// JSON Schema patterns are ECMA 262 expressions, and Swift's `Regex` is a different dialect:
/// it matches by grapheme cluster, its `\d`, `\w` and `\s` are Unicode-aware, it reads `\h`,
/// `\Z` or `(?i)` as syntax, and it backtracks, so `^(a+)+$` takes exponential time. This is a
/// small engine of its own instead. The syntax is ECMA 262's with the `u` flag (a code point is
/// one character, as `minLength` counts them); the pattern is compiled to an automaton and run
/// by keeping the set of states it can be in, which answers "is there a match" without
/// backtracking — at most `program.count` steps per character, whatever the pattern.
///
/// What it cannot match exactly as ECMA 262 does, it refuses to compile: back-references,
/// lookahead and lookbehind, and `\p{…}` for anything but a general category (`\p{L}`,
/// `\p{Lu}`, `\p{Letter}`; the categories are those of the Unicode version Swift ships).
/// Captures, named groups and lazy quantifiers compile and mean what they mean for a yes-or-no
/// match.
struct Pattern: Sendable {
    let source: String
    private let program: [Instruction]
    /// The pattern starts with `^` outside any alternation, so only position 0 can start a match.
    private let anchored: Bool
    /// Some set contains a general category, so each character's category has to be known.
    private let usesCategories: Bool

    /// - Parameter maxStates: the most instructions the automaton may have besides the final
    ///   one. Counted repetition is expanded, so `a{2,5}` costs as much as `aaa?a?a?`.
    init(_ source: String, maxStates: Int) throws(PatternError) {
        var parser = PatternParser(source)
        let tree = try parser.parse()
        var compiler = PatternCompiler(limit: maxStates)
        try compiler.emit(tree)
        compiler.append(.match)
        self.source = source
        self.program = compiler.program
        if case .start = compiler.program[0] { anchored = true } else { anchored = false }
        usesCategories = compiler.program.contains {
            if case .scalar(let set) = $0 { set.hasCategories } else { false }
        }
    }

    /// Whether the pattern matches somewhere in `string`, or `nil` when finding out would take
    /// more than `budget` steps. A step is one state of the automaton visited at one position;
    /// the steps taken are subtracted from `budget`, which is shared by every match of one
    /// validation.
    func matches(_ string: String, scratch: inout PatternScratch, budget: inout Int) -> Bool? {
        scratch.current.prepare(capacity: program.count)
        scratch.next.prepare(capacity: program.count)
        var scalars = string.unicodeScalars.makeIterator()
        var previous: Unicode.Scalar? = nil
        var scalar = scalars.next()
        var position = 0
        while true {
            // A match may start at any position: the search is not anchored unless `^` says so.
            if !anchored || position == 0 {
                if follow(0, into: &scratch.current, &scratch.pending, &budget, previous, scalar) { return true }
            } else if scratch.current.isEmpty {
                return false
            }
            guard budget >= 0 else { return nil }
            guard let character = scalar else { return false }
            let following = scalars.next()
            let category = usesCategories ? GeneralCategoryMask.of(character.value) : 0
            scratch.next.removeAll()
            budget -= scratch.current.members.count
            for state in scratch.current.members {
                guard case .scalar(let set) = program[state], set.contains(character.value, category: category) else {
                    continue
                }
                if follow(state + 1, into: &scratch.next, &scratch.pending, &budget, character, following) { return true }
            }
            swap(&scratch.current, &scratch.next)
            previous = character
            scalar = following
            position += 1
        }
    }

    /// Adds `state` and every state reachable from it without consuming a character, at a
    /// position between `previous` and `next`, one step of `budget` each. Returns whether that
    /// reaches the end of the pattern, which settles the answer.
    private func follow(
        _ state: Int, into set: inout StateSet, _ pending: inout [Int], _ budget: inout Int,
        _ previous: Unicode.Scalar?, _ next: Unicode.Scalar?
    ) -> Bool {
        pending.append(state)
        while let state = pending.popLast() {
            guard set.insert(state) else { continue }
            budget -= 1
            switch program[state] {
            case .match:
                pending.removeAll(keepingCapacity: true)
                return true
            case .scalar: break
            case .jump(let target): pending.append(target)
            case .split(let first, let second):
                pending.append(second)
                pending.append(first)
            case .start: if previous == nil { pending.append(state + 1) }
            case .end: if next == nil { pending.append(state + 1) }
            case .wordBoundary(let negated):
                if (Pattern.isWord(previous) != Pattern.isWord(next)) != negated { pending.append(state + 1) }
            }
        }
        return false
    }

    /// ECMA 262's word characters for `\b`: ASCII letters, digits and `_`.
    private static func isWord(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return ScalarSet.word.contains(value, category: 0)
    }
}

struct PatternError: Error {
    let reason: String
}

/// Working memory for matching, kept for the whole of one validation: a match then costs time
/// in proportion to the states it visits, not to the size of the automaton, which matters when
/// a large `patternProperties` automaton meets many short keys.
struct PatternScratch {
    fileprivate var current = StateSet()
    fileprivate var next = StateSet()
    fileprivate var pending: [Int] = []

    init() {}
}

private enum Instruction: Sendable {
    /// Consume one character from the set.
    case scalar(ScalarSet)
    case split(Int, Int)
    case jump(Int)
    /// Assertions: `^`, `$`, `\b` and `\B`.
    case start
    case end
    case wordBoundary(negated: Bool)
    case match
}

/// The states of the automaton that are live at one position, in insertion order. A state is
/// present when its stamp is the current generation, so emptying the set costs nothing however
/// many states the automaton has.
private struct StateSet {
    private(set) var members: [Int] = []
    private var stamps: [UInt32] = []
    private var generation: UInt32 = 1

    var isEmpty: Bool { members.isEmpty }

    /// Empties the set and makes room for states below `capacity`.
    mutating func prepare(capacity: Int) {
        if stamps.count < capacity { stamps += repeatElement(0, count: capacity - stamps.count) }
        removeAll()
    }

    mutating func insert(_ state: Int) -> Bool {
        guard stamps[state] != generation else { return false }
        stamps[state] = generation
        members.append(state)
        return true
    }

    mutating func removeAll() {
        members.removeAll(keepingCapacity: true)
        if generation == .max {
            for index in stamps.indices { stamps[index] = 0 }
            generation = 1
        } else {
            generation += 1
        }
    }
}

/// A set of Unicode code points: sorted, disjoint, non-adjacent closed ranges, together with
/// whole general categories (from `\p{…}`).
struct ScalarSet: Sendable {
    /// Flattened pairs: lower bound, upper bound, lower bound, …
    private var bounds: [UInt32] = []
    /// General categories in the set, one bit each (`GeneralCategoryMask`).
    private var categories: UInt32 = 0
    /// The set is the complement of what the other two fields describe. Only a negated class
    /// that contains a category is kept this way; every other complement is computed.
    private var isComplement = false

    static let maximum: UInt32 = 0x10FFFF

    init() {}

    /// The union of `ranges` and `categories`. Sorting first makes this O(n log n) in the number
    /// of ranges, which a character class of many single characters needs.
    init(_ ranges: [ClosedRange<UInt32>], categories: UInt32 = 0) {
        self.categories = categories
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = bounds.last, range.lowerBound <= last &+ 1 {
                bounds[bounds.count - 1] = max(last, range.upperBound)
            } else {
                bounds += [range.lowerBound, range.upperBound]
            }
        }
    }

    static let digit = ScalarSet([0x30...0x39])
    static let word = ScalarSet([0x30...0x39, 0x41...0x5A, 0x5F...0x5F, 0x61...0x7A])
    /// ECMA 262's WhiteSpace and LineTerminator: not Unicode's White_Space, which has U+0085
    /// and lacks U+FEFF.
    static let space = ScalarSet([
        0x09...0x0D, 0x20...0x20, 0xA0...0xA0, 0x1680...0x1680, 0x2000...0x200A, 0x2028...0x2029,
        0x202F...0x202F, 0x205F...0x205F, 0x3000...0x3000, 0xFEFF...0xFEFF,
    ])
    /// What `.` matches: everything but the line terminators.
    static let dot = ScalarSet([0x0A...0x0A, 0x0D...0x0D, 0x2028...0x2029]).inverted

    /// - Parameter category: `GeneralCategoryMask.of(value)`, looked up once per character by
    ///   the caller; it is read only by sets that contain categories.
    func contains(_ value: UInt32, category: UInt32) -> Bool {
        isComplement != (rangesContain(value) || category & categories != 0)
    }

    var hasCategories: Bool { categories != 0 }


    private func rangesContain(_ value: UInt32) -> Bool {
        // Binary search over the ranges for the last one starting at or below `value`.
        var low = 0
        var high = bounds.count / 2
        while low < high {
            let middle = (low + high) / 2
            if bounds[middle * 2] <= value { low = middle + 1 } else { high = middle }
        }
        return low > 0 && value <= bounds[low * 2 - 1]
    }

    init(categories: UInt32) { self.categories = categories }

    /// The ranges and categories, for building a union. Never asked of a complement: the
    /// members of a class are characters, `\d`-style sets (computed outright) and categories.
    var parts: (ranges: [ClosedRange<UInt32>], categories: UInt32) {
        var ranges: [ClosedRange<UInt32>] = []
        var index = 0
        while index < bounds.count {
            ranges.append(bounds[index]...bounds[index + 1])
            index += 2
        }
        return (ranges, categories)
    }

    var inverted: ScalarSet {
        if categories != 0 {
            var result = self
            result.isComplement.toggle()
            return result
        }
        var result = ScalarSet()
        var next: UInt32 = 0
        var index = 0
        while index < bounds.count {
            if bounds[index] > next { result.bounds += [next, bounds[index] - 1] }
            next = bounds[index + 1] + 1
            index += 2
        }
        if next <= ScalarSet.maximum { result.bounds += [next, ScalarSet.maximum] }
        return result
    }
}

/// A parsed pattern.
private indirect enum PatternNode {
    case empty
    case scalar(ScalarSet)
    case start
    case end
    case wordBoundary(negated: Bool)
    case sequence([PatternNode])
    case alternation([PatternNode])
    case repetition(PatternNode, min: Int, max: Int?)
}

/// Reads ECMA 262 pattern syntax as with the `u` flag, which is the stricter grammar: a `{`,
/// `}` or `]` that is not syntax, or an escape of a letter with no meaning, is an error rather
/// than a literal.
private struct PatternParser {
    let scalars: [Unicode.Scalar]
    var index = 0
    var depth = 0
    /// Names of the groups that can take part in a match together with the one being read.
    var live: Set<String> = []
    /// The members of `live` in the order they were defined, so that a disjunction can take
    /// back what one of its alternatives defined.
    var defined: [String] = []

    /// Groups nested deeper than this are refused; parsing and compiling recurse once per level.
    static let maxDepth = 64
    /// Repetition bounds above this are refused; the automaton's size limit would refuse them anyway.
    static let maxCount = 100_000

    init(_ source: String) { scalars = Array(source.unicodeScalars) }

    var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    func error(_ reason: String) -> PatternError { PatternError(reason: reason) }

    mutating func parse() throws(PatternError) -> PatternNode {
        let tree = try disjunction()
        if index < scalars.count { throw error("unmatched ')'") }
        return tree
    }

    mutating func disjunction() throws(PatternError) -> PatternNode {
        // Names defined by an alternative leave `live` when the next alternative starts and all
        // come back at the end. Each `|` costs as much as the names its alternative defined, so
        // the bookkeeping is linear in the pattern.
        let mark = defined.count
        var finished: [String] = []
        var alternatives = [try alternative()]
        while peek == "|" {
            index += 1
            for name in defined[mark...] { live.remove(name) }
            finished += defined[mark...]
            defined.removeSubrange(mark...)
            alternatives.append(try alternative())
        }
        for name in finished where live.insert(name).inserted { defined.append(name) }
        return alternatives.count == 1 ? alternatives[0] : .alternation(alternatives)
    }

    mutating func alternative() throws(PatternError) -> PatternNode {
        var terms: [PatternNode] = []
        while let scalar = peek, scalar != "|", scalar != ")" {
            terms.append(try term())
        }
        switch terms.count {
        case 0: return .empty
        case 1: return terms[0]
        default: return .sequence(terms)
        }
    }

    mutating func term() throws(PatternError) -> PatternNode {
        let scalar = scalars[index]
        index += 1
        let atom: PatternNode
        switch scalar {
        case "^": return try assertion(.start)
        case "$": return try assertion(.end)
        case "\\" where peek == "b" || peek == "B":
            let negated = peek == "B"
            index += 1
            return try assertion(.wordBoundary(negated: negated))
        case "\\": atom = .scalar(try escape(inClass: false))
        case ".": atom = .scalar(.dot)
        case "[": atom = .scalar(try characterClass())
        case "(": atom = try group()
        case "*", "+", "?", "{": throw error("nothing to repeat before '\(scalar)'")
        case "}", "]": throw error("unescaped '\(scalar)'")
        default: atom = .scalar(ScalarSet([scalar.value...scalar.value]))
        }
        return try quantified(atom)
    }

    /// An assertion takes no quantifier under the `u` flag.
    mutating func assertion(_ node: PatternNode) throws(PatternError) -> PatternNode {
        if let next = peek, next == "*" || next == "+" || next == "?" || next == "{" {
            throw error("an assertion cannot be repeated")
        }
        return node
    }

    mutating func quantified(_ atom: PatternNode) throws(PatternError) -> PatternNode {
        let minimum: Int
        let maximum: Int?
        switch peek {
        case "*": (minimum, maximum) = (0, nil)
        case "+": (minimum, maximum) = (1, nil)
        case "?": (minimum, maximum) = (0, 1)
        case "{":
            index += 1
            minimum = try count()
            if peek == "," {
                index += 1
                maximum = peek == "}" ? nil : try count()
            } else {
                maximum = minimum
            }
            guard peek == "}" else { throw error("malformed repetition '{…}'") }
            if let maximum, maximum < minimum { throw error("repetition bounds out of order") }
        default: return atom
        }
        index += 1
        // A lazy quantifier matches the same strings; only which match is found differs.
        if peek == "?" { index += 1 }
        return .repetition(atom, min: minimum, max: maximum)
    }

    mutating func count() throws(PatternError) -> Int {
        var value = 0
        var digits = 0
        while let scalar = peek, let digit = asciiDigit(scalar) {
            value = min(value * 10 + digit, PatternParser.maxCount + 1)
            digits += 1
            index += 1
        }
        guard digits > 0 else { throw error("malformed repetition '{…}'") }
        guard value <= PatternParser.maxCount else { throw error("repetition count above \(PatternParser.maxCount)") }
        return value
    }

    func asciiDigit(_ scalar: Unicode.Scalar) -> Int? {
        scalar.value >= 0x30 && scalar.value <= 0x39 ? Int(scalar.value - 0x30) : nil
    }

    mutating func group() throws(PatternError) -> PatternNode {
        depth += 1
        defer { depth -= 1 }
        guard depth <= PatternParser.maxDepth else { throw error("groups nested deeper than \(PatternParser.maxDepth)") }
        if peek == "?" {
            index += 1
            switch peek {
            case ":":
                index += 1
            case "=", "!":
                throw error("lookahead is not supported")
            case "<" where index + 1 < scalars.count && (scalars[index + 1] == "=" || scalars[index + 1] == "!"):
                throw error("lookbehind is not supported")
            case "<":
                // A named group. The name matters only to captures, which a yes-or-no match has
                // none of, but it has to be valid. ECMA 262 allows ID_Start characters, `$` and
                // `_`, then ID_Continue characters too, and `\u` escapes of any of them. Accepted
                // here: ID_Start, `$` and `_` anywhere and ASCII digits after the first. Other
                // ID_Continue characters (combining marks, other digits, ZWJ) and escapes are
                // refused: failing closed on a rare name costs less than tables to get it right.
                index += 1
                var name = ""
                while let scalar = peek, scalar == "_" || scalar == "$" || scalar.properties.isIDStart
                    || (!name.isEmpty && asciiDigit(scalar) != nil)
                {
                    name.unicodeScalars.append(scalar)
                    index += 1
                }
                guard !name.isEmpty, peek == ">" else {
                    throw error("malformed or unsupported group name (letters, '$', '_' and ASCII digits are supported)")
                }
                index += 1
                // Two groups may share a name only in different alternatives, where they cannot
                // both take part in one match.
                guard live.insert(name).inserted else { throw error("duplicate group name '\(name)'") }
                defined.append(name)
            default:
                throw error("unsupported group syntax '(?'")
            }
        }
        let body = try disjunction()
        guard peek == ")" else { throw error("unterminated group") }
        index += 1
        return body
    }

    /// `[…]` as one set of characters.
    mutating func characterClass() throws(PatternError) -> ScalarSet {
        var negated = false
        if peek == "^" {
            negated = true
            index += 1
        }
        var ranges: [ClosedRange<UInt32>] = []
        var categories: UInt32 = 0
        while true {
            guard let scalar = peek else { throw error("unterminated character class") }
            if scalar == "]" {
                index += 1
                break
            }
            let left = try classAtom()
            if peek == "-", index + 1 < scalars.count, scalars[index + 1] != "]" {
                index += 1
                let right = try classAtom()
                guard let low = left.single, let high = right.single else {
                    throw error("a range in a character class needs a single character at each end")
                }
                guard low <= high else { throw error("character class range out of order") }
                ranges.append(low...high)
            } else {
                let parts = left.set.parts
                ranges += parts.ranges
                categories |= parts.categories
            }
        }
        let set = ScalarSet(ranges, categories: categories)
        return negated ? set.inverted : set
    }

    /// One member of a class: a character, or a set such as `\d`.
    mutating func classAtom() throws(PatternError) -> (set: ScalarSet, single: UInt32?) {
        let scalar = scalars[index]
        index += 1
        guard scalar == "\\" else { return (ScalarSet([scalar.value...scalar.value]), scalar.value) }
        if peek == "b" {
            index += 1
            return (ScalarSet([0x08...0x08]), 0x08)
        }
        if peek == "-" {
            index += 1
            return (ScalarSet([0x2D...0x2D]), 0x2D)
        }
        let isSet = peek.map { "dDwWsSpP".unicodeScalars.contains($0) } ?? false
        let set = try escape(inClass: true)
        return (set, isSet ? nil : set.single)
    }

    /// The character or set an escape stands for; the backslash is already consumed.
    mutating func escape(inClass: Bool) throws(PatternError) -> ScalarSet {
        guard let scalar = peek else { throw error("pattern ends with '\\'") }
        index += 1
        func single(_ value: UInt32) -> ScalarSet { ScalarSet([value...value]) }
        switch scalar {
        case "d": return .digit
        case "D": return ScalarSet.digit.inverted
        case "w": return .word
        case "W": return ScalarSet.word.inverted
        case "s": return .space
        case "S": return ScalarSet.space.inverted
        case "f": return single(0x0C)
        case "n": return single(0x0A)
        case "r": return single(0x0D)
        case "t": return single(0x09)
        case "v": return single(0x0B)
        case "0":
            if let next = peek, asciiDigit(next) != nil { throw error("back-references and octal escapes are not supported") }
            return single(0)
        case "1"..."9", "k":
            throw error("back-references are not supported")
        case "p", "P":
            let mask = try property()
            return ScalarSet(categories: scalar == "p" ? mask : GeneralCategoryMask.all & ~mask)
        case "c":
            guard let letter = peek, (0x41...0x5A).contains(letter.value) || (0x61...0x7A).contains(letter.value) else {
                throw error("'\\c' must be followed by an ASCII letter")
            }
            index += 1
            return single(letter.value % 32)
        case "x":
            return single(try hex(digits: 2))
        case "u":
            return single(try unicodeEscape())
        case "^", "$", "\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "/":
            return single(scalar.value)
        default:
            throw error("invalid escape '\\\(scalar)'\(inClass ? " in a character class" : "")")
        }
    }

    /// The `{…}` after `\p`: a General_Category value, alone or as `gc=` or `General_Category=`.
    /// Scripts and binary properties are not supported.
    mutating func property() throws(PatternError) -> UInt32 {
        guard peek == "{" else { throw error("malformed '\\p{…}' escape") }
        index += 1
        var name = ""
        while let scalar = peek, scalar != "}" {
            name.unicodeScalars.append(scalar)
            index += 1
        }
        guard peek == "}" else { throw error("malformed '\\p{…}' escape") }
        index += 1
        var value = Substring(name)
        if value.hasPrefix("General_Category=") {
            value = value.dropFirst("General_Category=".count)
        } else if value.hasPrefix("gc=") {
            value = value.dropFirst("gc=".count)
        }
        guard let mask = GeneralCategoryMask.named[String(value)] else {
            throw error("'\\p{\(name)}' is not supported: only General_Category values are")
        }
        return mask
    }

    mutating func hex(digits: Int) throws(PatternError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<digits {
            guard let scalar = peek, let digit = hexDigit(scalar) else { throw error("malformed hexadecimal escape") }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    func hexDigit(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39: scalar.value - 0x30
        case 0x41...0x46: scalar.value - 0x41 + 10
        case 0x61...0x66: scalar.value - 0x61 + 10
        default: nil
        }
    }

    /// `\uXXXX`, a surrogate pair of two such escapes, or `\u{X…}`.
    mutating func unicodeEscape() throws(PatternError) -> UInt32 {
        if peek == "{" {
            index += 1
            var value: UInt32 = 0
            var digits = 0
            while let scalar = peek, let digit = hexDigit(scalar) {
                value = value << 4 | digit
                digits += 1
                index += 1
                guard value <= ScalarSet.maximum else { throw error("code point above U+10FFFF") }
            }
            guard digits > 0, peek == "}" else { throw error("malformed '\\u{…}' escape") }
            index += 1
            return value
        }
        let first = try hex(digits: 4)
        if (0xD800...0xDBFF).contains(first), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
            let saved = index
            index += 2
            if let second = try? hex(digits: 4), (0xDC00...0xDFFF).contains(second) {
                return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            }
            index = saved
        }
        // A lone surrogate is a code point no Swift string contains: it never matches.
        return first
    }
}

extension ScalarSet {
    /// The only member, if there is exactly one.
    fileprivate var single: UInt32? {
        categories == 0 && !isComplement && bounds.count == 2 && bounds[0] == bounds[1] ? bounds[0] : nil
    }
}

/// Turns a parsed pattern into instructions (Thompson's construction).
private struct PatternCompiler {
    let limit: Int
    var program: [Instruction] = []
    /// Nodes visited, bounded like the program: a repetition of something empty emits nothing,
    /// and `((a{0}){1000}){1000}` would otherwise take long to emit it.
    var work = 0

    init(limit: Int) { self.limit = limit }

    @discardableResult
    mutating func append(_ instruction: Instruction) -> Int {
        program.append(instruction)
        return program.count - 1
    }

    mutating func emit(_ node: PatternNode) throws(PatternError) {
        work += 1
        guard program.count <= limit, work / 4 <= limit else {
            throw PatternError(reason: "the pattern needs more than \(limit) states")
        }
        switch node {
        case .empty: break
        case .scalar(let set): append(.scalar(set))
        case .start: append(.start)
        case .end: append(.end)
        case .wordBoundary(let negated): append(.wordBoundary(negated: negated))
        case .sequence(let nodes):
            for node in nodes { try emit(node) }
        case .alternation(let alternatives):
            var exits: [Int] = []
            for (position, alternative) in alternatives.enumerated() {
                if position == alternatives.count - 1 {
                    try emit(alternative)
                } else {
                    let split = append(.split(0, 0))
                    try emit(alternative)
                    exits.append(append(.jump(0)))
                    program[split] = .split(split + 1, program.count)
                }
            }
            for exit in exits { program[exit] = .jump(program.count) }
        case .repetition(let body, let minimum, let maximum):
            for _ in 0..<minimum { try emit(body) }
            if let maximum {
                // Each optional copy may be skipped, which skips the rest too.
                var skips: [Int] = []
                for _ in minimum..<maximum {
                    skips.append(append(.split(0, 0)))
                    try emit(body)
                }
                for skip in skips { program[skip] = .split(skip + 1, program.count) }
            } else {
                let loop = append(.split(0, 0))
                try emit(body)
                append(.jump(loop))
                program[loop] = .split(loop + 1, program.count)
            }
        }
        guard program.count <= limit else { throw PatternError(reason: "the pattern needs more than \(limit) states") }
    }
}

/// General categories as bits, and their names as `\p{…}` spells them (Unicode's
/// PropertyValueAliases, which ECMA 262 uses).
private enum GeneralCategoryMask {
    static let order: [(short: String, long: String)] = [
        ("Lu", "Uppercase_Letter"), ("Ll", "Lowercase_Letter"), ("Lt", "Titlecase_Letter"),
        ("Lm", "Modifier_Letter"), ("Lo", "Other_Letter"), ("Mn", "Nonspacing_Mark"), ("Mc", "Spacing_Mark"),
        ("Me", "Enclosing_Mark"), ("Nd", "Decimal_Number"), ("Nl", "Letter_Number"), ("No", "Other_Number"),
        ("Pc", "Connector_Punctuation"), ("Pd", "Dash_Punctuation"), ("Ps", "Open_Punctuation"),
        ("Pe", "Close_Punctuation"), ("Pi", "Initial_Punctuation"), ("Pf", "Final_Punctuation"),
        ("Po", "Other_Punctuation"), ("Sm", "Math_Symbol"), ("Sc", "Currency_Symbol"), ("Sk", "Modifier_Symbol"),
        ("So", "Other_Symbol"), ("Zs", "Space_Separator"), ("Zl", "Line_Separator"), ("Zp", "Paragraph_Separator"),
        ("Cc", "Control"), ("Cf", "Format"), ("Cs", "Surrogate"), ("Co", "Private_Use"), ("Cn", "Unassigned"),
    ]

    static let all: UInt32 = (1 << UInt32(order.count)) - 1

    static let named: [String: UInt32] = {
        var names: [String: UInt32] = [:]
        for (bit, category) in order.enumerated() {
            names[category.short] = 1 << UInt32(bit)
            names[category.long] = 1 << UInt32(bit)
        }
        // Groups, by the first letter of the short names; LC is the cased letters.
        let groups: [(String, String, String)] = [
            ("L", "Letter", "L"), ("M", "Mark", "M"), ("N", "Number", "N"), ("P", "Punctuation", "P"),
            ("S", "Symbol", "S"), ("Z", "Separator", "Z"), ("C", "Other", "C"),
        ]
        for (short, long, initial) in groups {
            var mask: UInt32 = 0
            for (bit, category) in order.enumerated() where category.short.hasPrefix(initial) { mask |= 1 << UInt32(bit) }
            names[short] = mask
            names[long] = mask
        }
        names["Combining_Mark"] = names["M"]
        names["digit"] = names["Nd"]
        names["punct"] = names["P"]
        names["cntrl"] = names["Cc"]
        // All three were added from `order` above.
        let cased = names["Lu"]! | names["Ll"]! | names["Lt"]!
        names["LC"] = cased
        names["Cased_Letter"] = cased
        return names
    }()

    static func of(_ value: UInt32) -> UInt32 {
        // Surrogate code points are not scalars; no string contains one.
        guard let scalar = Unicode.Scalar(value) else { return 1 << 27 }
        let bit: Int
        switch scalar.properties.generalCategory {
        case .uppercaseLetter: bit = 0
        case .lowercaseLetter: bit = 1
        case .titlecaseLetter: bit = 2
        case .modifierLetter: bit = 3
        case .otherLetter: bit = 4
        case .nonspacingMark: bit = 5
        case .spacingMark: bit = 6
        case .enclosingMark: bit = 7
        case .decimalNumber: bit = 8
        case .letterNumber: bit = 9
        case .otherNumber: bit = 10
        case .connectorPunctuation: bit = 11
        case .dashPunctuation: bit = 12
        case .openPunctuation: bit = 13
        case .closePunctuation: bit = 14
        case .initialPunctuation: bit = 15
        case .finalPunctuation: bit = 16
        case .otherPunctuation: bit = 17
        case .mathSymbol: bit = 18
        case .currencySymbol: bit = 19
        case .modifierSymbol: bit = 20
        case .otherSymbol: bit = 21
        case .spaceSeparator: bit = 22
        case .lineSeparator: bit = 23
        case .paragraphSeparator: bit = 24
        case .control: bit = 25
        case .format: bit = 26
        case .surrogate: bit = 27
        case .privateUse: bit = 28
        case .unassigned: bit = 29
        @unknown default: bit = 29
        }
        return 1 << UInt32(bit)
    }
}
