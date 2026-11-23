import Foundation

/// A schema could not be compiled: it is malformed, uses an unsupported dialect or keyword,
/// references something outside itself, or exceeds the resource bounds.
public struct JSONSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    public var reason: String
    /// JSON pointer to the offending part of the schema.
    public var pointer: String

    public var description: String { pointer.isEmpty ? reason : "\(reason) (at \(pointer))" }
}

/// An instance does not satisfy a schema.
public struct SchemaViolation: Error, Sendable, Equatable, CustomStringConvertible {
    /// Path to the offending value, outermost first; empty for the root.
    public var path: [String]
    public var reason: String

    public var description: String {
        path.isEmpty ? reason : "\(path.joined(separator: ".")): \(reason)"
    }
}

/// A compiled JSON Schema using the supported keywords of 2020-12 or draft-07.
///
/// Compilation happens once, when a tool is registered; validation walks the compiled form.
/// Per the MCP specification:
/// - References resolve to schema locations in the document, embedded resources, and the
///   documents explicitly registered by URI. An unresolved reference fails compilation.
///   URI resolution performs no network fetches.
/// - composition is bounded (`Limits`): schema depth, number of subschemas and validation
///   recursion are limited, and one `validate` call takes at most `maxEvaluations` subschema
///   evaluations and value visits for comparisons, plus `maxPatternSteps` pattern steps (twice that if the first attempt runs out
///   of stack and is repeated on a large one). Together these bound the time of a call
///   whatever the schema and the instance: with the defaults, under a second in an optimized
///   build, two at most when the stack runs out. A call that would need more fails with a message that says so; it never
///   passes a value it could not finish checking.
///
/// What the validator cannot enforce exactly, it refuses to compile, so nothing is silently
/// unchecked: the legacy 2019-09 keywords `$recursiveRef` and `$recursiveAnchor`;
/// `additionalItems` outside draft-07; `$schema` outside a schema resource root;
/// a keyword whose value has the wrong type (`"uniqueItems": "true"`,
/// an empty `type` list, array-form `items` outside draft-07); and patterns outside the dialect
/// below. Definitions under `$defs` and `definitions`, and `then` / `else` without `if`, are
/// compiled and checked even when nothing uses them. `format` is an annotation, as 2020-12
/// specifies by default.
///
/// Numbers used in schema comparisons need a normalized decimal exponent in −10¹⁸…10¹⁸.
/// Within that range they are compared exactly, as the decimals their text spells:
/// `"minimum": 9007199254740993` rejects 9007199254740992, and `multipleOf` is an exact
/// remainder (its value may have at most 19 significant digits).
///
/// `pattern` and `patternProperties` use ECMA 262 syntax as with the `u` flag, matched by
/// Unicode code point — the unit `minLength` counts — as a search (anchor with `^…$`). `.`, `\d`,
/// `\w`, `\s` and `\b` mean what ECMA 262 says: `\d` and `\w` are ASCII, `\s` is ECMA's white
/// space and line terminators. Valid ECMA 262 that is refused rather than matched differently:
/// back-references, lookahead and lookbehind; modifiers such as `(?i:…)`; `\p{…}` with anything
/// but a general category (`\p{L}`, `\p{Lu}`, `\p{gc=Letter}`; the categories are those of
/// the Unicode version of the Swift standard library, which may differ from a JavaScript
/// engine's); group names with ID_Continue characters other than ASCII digits (combining marks,
/// other digits, ZWJ) or with `\u` escapes; repetition counts above 100,000, whatever the
/// limits.
/// Matching does not backtrack, so `^(a+)+$` is as fast as `^a+$`: it takes at most one step
/// per state of the automaton (`maxPatternStates`) per character of the string, and all the
/// matching in one `validate` call at most `maxPatternSteps` steps.
public struct JSONSchema: Sendable {
    public struct Limits: Sendable {
        /// Nesting of subschemas, where following a `$ref` counts as a level too. Real tool
        /// schemas nest a handful of levels. Raising it far is not supported: compiling takes
        /// time that grows with the square of the depth, and the large stack compilation falls
        /// back to holds about 2,800 levels in an unoptimized build and about 70,000 in an
        /// optimized one, so with this raised the two builds can disagree about deep schemas.
        public var maxDepth = 32
        public var maxSubschemas = 10_000
        /// Nested subschema evaluations, roughly two per level of instance nesting. Deeper
        /// instances are reported as invalid. Stack use is bounded separately and never makes
        /// the answer depend on the build: a run that runs out of stack is repeated on a thread
        /// with a large one.
        public var maxValidationRecursion = 4096
        /// Subschema evaluations and values visited for structural comparisons in one `validate` call.
        /// A schema whose alternatives refer to
        /// each other can take time exponential in its size; past this many steps the value is
        /// reported as not checkable rather than checked for as long as it takes. In an
        /// optimized build ten million steps take about half a second. A message the server
        /// accepts holds at most about a million values, so the default allows some ten
        /// evaluations per value of the largest instance; a schema that needs more on instances
        /// that large needs this raised. A call whose first attempt runs out of stack starts over
        /// on a large stack with the full budget, so it can take up to twice this many.
        public var maxEvaluations = 10_000_000
        /// Size of the automaton one `pattern` compiles to, not counting its final state:
        /// roughly one state per character of the pattern, with counted repetition expanded
        /// (`a{1,100}` is about 200). Matching a string takes at most this many steps per
        /// character.
        public var maxPatternStates = 10_000
        /// Pattern steps in one `validate` call, over every `pattern` and `patternProperties`
        /// match: a step is one state of an automaton visited at one character. Simple patterns
        /// take a step or two per character, so the default covers megabytes of text; the worst
        /// automaton allowed by `maxPatternStates` takes ten thousand, and is cut off after a
        /// few kilobytes. In an optimized build a hundred million steps take about a fifth of a
        /// second. An unanchored counted pattern such as `[a-z.]{1,64}@[a-z.]{1,253}` keeps a
        /// few hundred states live on long text, so a few hundred kilobytes of free text can
        /// exhaust the default although the pattern matches: anchor such a pattern (`^…$`),
        /// bound the text with `maxLength`, or raise this limit. A call whose first attempt runs
        /// out of stack starts over on a large stack with the full budget, so it can take up to
        /// twice this many.
        public var maxPatternSteps = 100_000_000
        public init() {}
    }

    let nodes: [Node]
    let root: Int
    let limits: Limits
    private let dynamicAnchors: [ExactString: [ExactString: Int]]

    public init(_ schema: JSONValue, limits: Limits = Limits()) throws(JSONSchemaError) {
        try self.init(schema, registeredSchemas: [:], limits: limits)
    }

    /// Compiles against schema documents supplied in memory at absolute retrieval URIs.
    public init(
        _ schema: JSONValue, registeredSchemas: [String: JSONValue], limits: Limits = Limits()
    ) throws(JSONSchemaError) {
        let isDraft7 = schema["$schema"]?.stringValue.map { JSONSchema.supportedDialects.contains($0) && $0.contains("draft-07") } ?? false
        // Compilation recurses once per level of the schema. A schema within `maxDepth` can
        // still need more stack than an unoptimized build leaves a handler, and whether it
        // compiles must not depend on the build: such a run is repeated on a large stack.
        var outcome = Compiler.run(schema, registeredSchemas, isDraft7: isDraft7, limits: limits, stack: StackGuard())
        if outcome.exhausted {
            outcome = onLargeStack(bytes: JSONSchema.largeStackBytes) {
                Compiler.run(
                    schema, registeredSchemas, isDraft7: isDraft7, limits: limits,
                    stack: StackGuard(budget: JSONSchema.largeStackBytes - (1 << 20)))
            }
            if outcome.exhausted {
                throw JSONSchemaError(reason: "the schema is nested too deeply to compile", pointer: "")
            }
        }
        let compiled = try outcome.result.get()
        root = compiled.root
        nodes = compiled.nodes
        dynamicAnchors = compiled.dynamicAnchors
        self.limits = limits
    }

    static let supportedDialects: Set<String> = [
        "https://json-schema.org/draft/2020-12/schema",
        "http://json-schema.org/draft-07/schema#",
        "http://json-schema.org/draft-07/schema",
    ]

    /// Returns the first violation, or `nil` when `instance` is valid.
    ///
    /// Validation recurses with the schema and the instance. A value nested as deep as the
    /// parser allows, checked against a schema that refers to itself, does not fit the stack a
    /// handler runs on — in an unoptimized build not by far. Running out of stack must not look
    /// like "invalid", so that run is abandoned and repeated on a thread with a large stack.
    public func validate(_ instance: JSONValue) -> SchemaViolation? {
        var run = Evaluation(stack: StackGuard(), limits: limits)
        var violation = check(root, instance, 0, 0, run)
        // Until the stack runs out, this run is step for step the one a large stack would make,
        // budgets included. Once it has run out, nothing of it is kept: the retry starts afresh,
        // with full budgets, its own scratch and no cuts, so the verdict is the large-stack one
        // whatever stack the caller is on. The price is that such a call can cost twice the limits.
        if run.stack.wasExhausted {
            let retry = onLargeStack(bytes: JSONSchema.largeStackBytes) {
                let run = Evaluation(stack: StackGuard(budget: JSONSchema.largeStackBytes - (1 << 20)), limits: limits)
                return (check(root, instance, 0, 0, run), run)
            }
            (violation, run) = retry
            // Out of stack even there (or no thread could be had and the retry ran right here):
            // whatever came back may be a branch that was cut short and read as "no match".
            // The only safe answer is that the value could not be checked.
            if run.stack.wasExhausted { return fail("nested deeper than the validator allows") }
        }
        // The same for the budgets and for cuts under `not`: `anyOf` and `not` read a cut-short
        // branch as an answer.
        if run.isOverBudget {
            return fail("checking this value takes more than \(limits.maxEvaluations) steps of the schema")
        }
        if run.isOverPatternBudget {
            return fail("matching patterns against this value takes more than \(limits.maxPatternSteps) steps")
        }
        if run.comparedUnsupportedNumber { return fail(Self.exponentRangeError) }
        if let cut = run.cut { return fail(cut) }
        violation?.path.reverse()
        return violation
    }

    static let largeStackBytes = 64 << 20
    static let exponentRangeError = "number has a normalized exponent outside the exact decimal range"
}

/// The state of one validation run, shared by every level of it.
final class Evaluation {
    let stack: StackGuard
    private var remaining: Int
    /// Pattern steps left; see `Limits.maxPatternSteps`.
    private var patternBudget: Int
    private var patternScratch = PatternScratch()
    private(set) var isOverBudget = false
    private(set) var isOverPatternBudget = false
    private(set) var comparedUnsupportedNumber = false
    var dynamicScope: [ExactString] = []
    /// How many keywords that can turn a failure into a success (`not`, `oneOf`, `if`, and
    /// `contains` with a maximum) enclose the subschema being checked.
    var inversions = 0
    /// Why a branch was cut short where the cut could have become an answer. Such a run gives
    /// no answer about the value; this reason is the result instead.
    private(set) var cut: String?

    init(stack: StackGuard, limits: JSONSchema.Limits) {
        self.stack = stack
        remaining = max(0, limits.maxEvaluations)
        patternBudget = max(0, limits.maxPatternSteps)
    }

    /// Takes one step; `false` once the budget is spent.
    func step() -> Bool {
        charge(1)
    }

    func charge(_ steps: Int) -> Bool {
        guard remaining >= steps else {
            isOverBudget = true
            return false
        }
        remaining -= steps
        return true
    }

    func accepts(_ number: JSONNumber) -> Bool {
        guard number.isWithinExactDecimalRange else {
            comparedUnsupportedNumber = true
            return false
        }
        return true
    }

    /// Compare only the value pairs examined, stopping as soon as one differs.
    func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        guard step(), !stack.isExhausted else { return false }
        switch (lhs, rhs) {
        case (.array(let left), .array(let right)):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { equal($0.0, $0.1) }
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            return left.allSatisfy { entry in right[entry.key].map { equal(entry.value, $0) } ?? false }
        case (.number(let left), .number(let right)):
            return accepts(left) && accepts(right) && left == right
        default: return lhs == rhs
        }
    }

    /// Hashing a value for `uniqueItems` visits every member, even if the set is empty.
    func chargeHash(of value: JSONValue) -> Bool {
        guard step(), !stack.isExhausted else { return false }
        switch value {
        case .array(let values): return values.allSatisfy(chargeHash)
        case .object(let object): return object.allSatisfy { chargeHash(of: $0.value) }
        case .number(let number): return accepts(number)
        default: return true
        }
    }

    /// Whether `pattern` matches `string`; `nil` once the pattern budget is spent.
    func matches(_ pattern: Pattern, _ string: String) -> Bool? {
        guard !isOverPatternBudget, let found = pattern.matches(string, scratch: &patternScratch, budget: &patternBudget) else {
            isOverPatternBudget = true
            return nil
        }
        return found
    }

    /// A branch that cannot be finished (too much recursion, a schema that refers to itself
    /// without consuming input). Where nothing encloses it that turns failure into success,
    /// the cut is an ordinary failure and can only make the answer stricter; under `not` and
    /// the like it would become a success, so it decides the run instead.
    func cutShort(_ reason: String) -> SchemaViolation {
        if inversions > 0, cut == nil { cut = reason }
        return SchemaViolation(path: [], reason: reason)
    }

    /// Checks `body` where a failure can turn into a success.
    func inverting<T>(_ body: () -> T) -> T {
        inversions += 1
        defer { inversions -= 1 }
        return body()
    }
}

/// Annotations at a single instance location. Each successful subschema contributes its own
/// set, so an unsuccessful alternative cannot mark properties or items as evaluated.
private final class EvaluatedLocations {
    var properties: Set<ExactString> = []
    var items: Set<Int> = []

    func merge(_ child: EvaluatedLocations, run: Evaluation) {
        guard run.charge(child.properties.count + child.items.count) else { return }
        properties.formUnion(child.properties)
        items.formUnion(child.items)
    }
}

// MARK: - Compiled form

struct TypeSet: OptionSet, Sendable {
    let rawValue: UInt8
    static let null = TypeSet(rawValue: 1)
    static let boolean = TypeSet(rawValue: 2)
    static let integer = TypeSet(rawValue: 4)
    static let number = TypeSet(rawValue: 8)
    static let string = TypeSet(rawValue: 16)
    static let array = TypeSet(rawValue: 32)
    static let object = TypeSet(rawValue: 64)

    static func named(_ name: String) -> TypeSet? {
        switch name {
        case "null": .null
        case "boolean": .boolean
        case "integer": .integer
        case "number": .number
        case "string": .string
        case "array": .array
        case "object": .object
        default: nil
        }
    }

    var names: String {
        var result: [String] = []
        if contains(.null) { result.append("null") }
        if contains(.boolean) { result.append("boolean") }
        if contains(.integer) { result.append("integer") }
        if contains(.number) { result.append("number") }
        if contains(.string) { result.append("string") }
        if contains(.array) { result.append("array") }
        if contains(.object) { result.append("object") }
        return result.joined(separator: " or ")
    }
}

/// One compiled subschema. A class so that validation, which recurses once per level of
/// nesting, keeps a pointer on the stack instead of a copy of every keyword. Nodes are written
/// only while compiling and are immutable once the `JSONSchema` exists.
final class Node: @unchecked Sendable {
    var always: Bool?
    var ref: Int?
    var dynamicRef: (fallback: Int, anchor: ExactString?)?
    var resource: ExactString?
    var types: TypeSet?
    var enumeration: [JSONValue]?
    var const: JSONValue?

    var minimum: JSONNumber?
    var maximum: JSONNumber?
    var exclusiveMinimum: JSONNumber?
    var exclusiveMaximum: JSONNumber?
    /// The divisor as written, and as `significand × 10^scale` for the exact remainder.
    var multipleOf: (number: JSONNumber, significand: UInt64, scale: Int64)?

    var minLength: Int?
    var maxLength: Int?
    var pattern: Pattern?

    var prefixItems: [Int] = []
    var items: Int?
    var unevaluatedItems: Int?
    var contains: Int?
    var minContains: Int?
    var maxContains: Int?
    var minItems: Int?
    var maxItems: Int?
    var uniqueItems = false

    var properties: [ExactString: Int] = [:]
    var patternProperties: [(pattern: Pattern, node: Int)] = []
    var additionalProperties: Int?
    var unevaluatedProperties: Int?
    var propertyNames: Int?
    var required: [String] = []
    var minProperties: Int?
    var maxProperties: Int?
    var dependentRequired: [(name: String, needs: [String])] = []
    var dependentSchemas: [(name: String, node: Int)] = []

    var allOf: [Int] = []
    var anyOf: [Int] = []
    var oneOf: [Int] = []
    var not: Int?
    var ifNode: Int?
    var thenNode: Int?
    var elseNode: Int?
}

// MARK: - Compiler

private struct Compiler {
    private enum Vocabulary: String {
        case core, applicator, unevaluated, validation, metadata = "meta-data", format = "format-annotation", content
    }

    private struct Dialect {
        var isDraft7: Bool
        // The built-in dialects have fixed keyword sets handled by the compiler.
        var vocabularies: Set<Vocabulary>? = nil

        func uses(_ keyword: String) -> Bool {
            guard let vocabularies, let vocabulary = Compiler.keywordVocabulary[keyword] else { return true }
            return vocabularies.contains(vocabulary)
        }
    }

    private struct Location {
        var schema: JSONValue
        var resource: ExactString
        var dialect: Dialect
    }

    private struct Anchor {
        var pointer: String
        var dynamic: Bool
    }

    let document: JSONValue
    let registeredSchemas: [String: JSONValue]
    let limits: JSONSchema.Limits
    /// In draft-07 a `$ref` replaces its sibling keywords; from 2019-09 on it is applied alongside them.
    let isDraft7: Bool
    let stack: StackGuard
    var nodes: [Node] = []
    /// Pointer of an already compiled (or in-progress) subschema to its node, so recursive
    /// references terminate.
    var byPointer: [ExactString: Int] = [:]
    private var locations: [ExactString: Location] = [:]
    private var resources: [ExactString: String] = [:]
    private var anchors: [ExactString: [ExactString: Anchor]] = [:]
    private var neededResources: Set<ExactString> = []

    struct Compiled {
        var root: Int
        var nodes: [Node]
        var dynamicAnchors: [ExactString: [ExactString: Int]]
    }

    /// Compiles a whole document. Whether it ran out of stack is reported apart from the
    /// result, which is not to be trusted then.
    static func run(
        _ schema: JSONValue, _ registeredSchemas: [String: JSONValue], isDraft7: Bool, limits: JSONSchema.Limits, stack: StackGuard
    ) -> (result: Result<Compiled, JSONSchemaError>, exhausted: Bool) {
        var compiler = Compiler(document: schema, registeredSchemas: registeredSchemas, limits: limits, isDraft7: isDraft7, stack: stack)
        do throws(JSONSchemaError) {
            try compiler.indexLocations()
            let root = try compiler.compile(schema, pointer: "", depth: 0)
            while let resource = compiler.neededResources.popFirst() {
                guard let pointer = compiler.resources[resource], compiler.byPointer[ExactString(pointer)] == nil,
                    let location = compiler.locations[ExactString(pointer)] else { continue }
                _ = try compiler.compile(location.schema, pointer: pointer, depth: 0)
            }
            let dynamicAnchors = compiler.anchors.compactMapValues { named -> [ExactString: Int]? in
                let compiled = named.compactMapValues { $0.dynamic ? compiler.byPointer[ExactString($0.pointer)] : nil }
                return compiled.isEmpty ? nil : compiled
            }
            return (.success(Compiled(root: root, nodes: compiler.nodes, dynamicAnchors: dynamicAnchors)), stack.wasExhausted)
        } catch {
            return (.failure(error), stack.wasExhausted)
        }
    }

    /// Keywords whose value is one schema.
    static let schemaKeywords: Set<String> = [
        "items", "additionalItems", "contains", "additionalProperties", "propertyNames", "not", "if", "then", "else",
        "unevaluatedItems", "unevaluatedProperties",
    ]
    /// Keywords whose value is an object of schemas.
    static let schemaMapKeywords: Set<String> = ["properties", "patternProperties", "dependentSchemas", "$defs", "definitions"]
    /// Keywords whose value is an array of schemas.
    static let schemaListKeywords: Set<String> = ["allOf", "anyOf", "oneOf", "prefixItems"]

    private static let vocabularyBase = "https://json-schema.org/draft/2020-12/vocab/"

    private static let keywordVocabulary: [String: Vocabulary] = {
        let groups: [(Vocabulary, [String])] = [
            (.applicator, ["prefixItems", "items", "contains", "additionalProperties", "properties", "patternProperties",
                "dependentSchemas", "propertyNames", "if", "then", "else", "allOf", "anyOf", "oneOf", "not"]),
            (.unevaluated, ["unevaluatedItems", "unevaluatedProperties"]),
            (.validation, ["type", "enum", "const", "multipleOf", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
                "minLength", "maxLength", "pattern", "maxItems", "minItems", "uniqueItems", "minContains", "maxContains",
                "minProperties", "maxProperties", "required", "dependentRequired"]),
            (.metadata, ["title", "description", "default", "deprecated", "readOnly", "writeOnly", "examples"]),
            (.format, ["format"]),
            (.content, ["contentMediaType", "contentEncoding", "contentSchema"]),
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { vocabulary, keys in keys.map { ($0, vocabulary) } })
    }()

    private func dialect(at uri: String) -> Dialect? {
        if JSONSchema.supportedDialects.contains(uri) { return Dialect(isDraft7: uri.contains("draft-07")) }
        guard let meta = registeredSchemas[uri], meta["$schema"] == "https://json-schema.org/draft/2020-12/schema",
            let declaration = meta["$vocabulary"]?.objectValue else { return nil }
        var active: Set<Vocabulary> = [.core]
        for (name, requirement) in declaration {
            guard let required = requirement.boolValue else { return nil }
            if name.hasPrefix(Self.vocabularyBase), let known = Vocabulary(rawValue: String(name.dropFirst(Self.vocabularyBase.count))) {
                active.insert(known)
            } else if required {
                return nil
            }
        }
        return Dialect(isDraft7: false, vocabularies: active)
    }

    /// Indexes schema positions and named resources before references are followed. IDs are
    /// parsed for identity and relative resolution only. No URI is fetched.
    private mutating func indexLocations() throws(JSONSchemaError) {
        let initial = URL(fileURLWithPath: "/.__limb_schema__/document")
        let defaultDialect = Dialect(isDraft7: isDraft7)
        var pending: [(schema: JSONValue, pointer: String, base: URL, dialect: Dialect, depth: Int)] = []
        for (index, entry) in registeredSchemas.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let base = URL(string: entry.key, encodingInvalidCharacters: false), base.scheme != nil, base.fragment == nil else {
                throw JSONSchemaError(reason: "registered schema URI must be absolute and fragment-free", pointer: "")
            }
            pending.append((entry.value, "registered:\(index)", base, defaultDialect, 0))
        }
        pending.append((document, "", initial, defaultDialect, 0))
        while let (schema, pointer, inheritedBase, inheritedDialect, depth) = pending.popLast() {
            guard depth <= limits.maxDepth else {
                throw JSONSchemaError(reason: "schema nesting deeper than \(limits.maxDepth)", pointer: pointer)
            }
            guard locations.count < limits.maxSubschemas else {
                throw JSONSchemaError(reason: "more than \(limits.maxSubschemas) subschemas", pointer: pointer)
            }
            let object = schema.objectValue
            var base = inheritedBase
            var dialect = inheritedDialect
            if let declaration = object?["$schema"] {
                guard depth == 0 || object?.contains("$id") == true, let uri = declaration.stringValue, let selected = self.dialect(at: uri) else {
                    throw JSONSchemaError(reason: "unsupported JSON Schema dialect \(declaration)", pointer: pointer + "/$schema")
                }
                dialect = selected
            }
            let draft7 = dialect.isDraft7
            let identifier = draft7 && object?.contains("$ref") == true ? nil : object?["$id"]
            var oldAnchor: String?
            if let identifier {
                guard let id = identifier.stringValue, let parsed = uriReference(id, against: inheritedBase) else {
                    throw JSONSchemaError(reason: "\"$id\" must be a valid URI-reference", pointer: pointer + "/$id")
                }
                if let fragment = parsed.fragment, !fragment.isEmpty {
                    guard draft7 else {
                        throw JSONSchemaError(reason: "\"$id\" must not contain a nonempty fragment", pointer: pointer + "/$id")
                    }
                    oldAnchor = fragment
                }
                base = parsed.base
            }
            let resource = ExactString(base.absoluteString)
            if depth == 0 || (identifier != nil && oldAnchor == nil) {
                if let existing = resources[resource], !existing.isBytewiseEqual(to: pointer) {
                    throw JSONSchemaError(reason: "duplicate schema resource \(resource.text)", pointer: pointer + "/$id")
                }
                resources[resource] = pointer
            }
            if depth == 0, !pointer.isEmpty {
                let retrieval = ExactString(inheritedBase.absoluteString)
                if let existing = resources[retrieval], !existing.isBytewiseEqual(to: pointer) {
                    throw JSONSchemaError(reason: "duplicate registered schema URI \(retrieval.text)", pointer: "")
                }
                resources[retrieval] = pointer
            }
            locations[ExactString(pointer)] = Location(schema: schema, resource: resource, dialect: dialect)
            if let oldAnchor {
                try addAnchor(oldAnchor, dynamic: false, resource: resource, pointer: pointer, keyword: "$id")
            }
            guard let object else { continue }
            if !draft7 {
                for (keyword, dynamic) in [("$anchor", false), ("$dynamicAnchor", true)] {
                    guard let value = object[keyword] else { continue }
                    guard let name = value.stringValue, isAnchorName(name) else {
                        throw JSONSchemaError(reason: "invalid anchor name", pointer: pointer + "/" + keyword)
                    }
                    try addAnchor(name, dynamic: dynamic, resource: resource, pointer: pointer, keyword: keyword)
                }
            }
            for (keyword, value) in object.reversed() {
                guard dialect.uses(keyword) else { continue }
                let child = pointer + "/" + escape(keyword)
                if Self.schemaKeywords.contains(keyword) {
                    if !draft7 && keyword == "additionalItems" || draft7 && keyword.hasPrefix("unevaluated") { continue }
                    if draft7, keyword == "items", let list = value.arrayValue {
                        for i in list.indices.reversed() { pending.append((list[i], child + "/\(i)", base, dialect, depth + 1)) }
                    } else {
                        pending.append((value, child, base, dialect, depth + 1))
                    }
                } else if Self.schemaMapKeywords.contains(keyword) || keyword == "dependencies" {
                    if draft7 && keyword == "dependentSchemas" { continue }
                    for (name, entry) in (value.objectValue ?? [:]).reversed() {
                        if keyword == "dependencies", entry.arrayValue != nil { continue }
                        pending.append((entry, child + "/" + escape(name), base, dialect, depth + 1))
                    }
                } else if Self.schemaListKeywords.contains(keyword), keyword != "prefixItems" || !draft7,
                    let list = value.arrayValue
                {
                    for i in list.indices.reversed() { pending.append((list[i], child + "/\(i)", base, dialect, depth + 1)) }
                }
            }
        }
    }

    private mutating func addAnchor(
        _ name: String, dynamic: Bool, resource: ExactString, pointer: String, keyword: String
    ) throws(JSONSchemaError) {
        let key = ExactString(name)
        guard anchors[resource]?[key] == nil else {
            throw JSONSchemaError(reason: "duplicate schema anchor \(name)", pointer: pointer + "/" + keyword)
        }
        anchors[resource, default: [:]][key] = Anchor(pointer: pointer, dynamic: dynamic)
    }

    private func isAnchorName(_ name: String) -> Bool {
        func initial(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
        guard let first = name.utf8.first, initial(first) else { return false }
        return name.utf8.dropFirst().allSatisfy { initial($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }

    private func uriReference(_ reference: String, against base: URL) -> (base: URL, fragment: String?)? {
        let pieces = reference.utf8.split(separator: 0x23, maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(decoding: pieces.first ?? reference.utf8[...], as: UTF8.self)
        guard !head.utf8.contains(where: { $0 <= 0x20 || $0 >= 0x7F }),
            head.removingPercentEncoding != nil,
            let resolved = head.isEmpty ? base : URL(string: head, relativeTo: base)?.absoluteURL,
            resolved.scheme != nil else { return nil }
        guard pieces.count == 2 else { return (resolved, nil) }
        guard let fragment = decodeFragment(pieces[1]) else { return nil }
        return (resolved, fragment)
    }

    mutating func compile(_ schema: JSONValue, pointer: String, depth: Int) throws(JSONSchemaError) -> Int {
        let key = ExactString(pointer)
        if let existing = byPointer[key] { return existing }
        guard depth <= limits.maxDepth else {
            throw JSONSchemaError(reason: "schema nesting deeper than \(limits.maxDepth)", pointer: pointer)
        }
        guard !stack.isExhausted else {
            // Not the final word: `JSONSchema.init` sees the guard tripped and tries again with more stack.
            throw JSONSchemaError(reason: "out of stack", pointer: pointer)
        }
        guard nodes.count < limits.maxSubschemas else {
            throw JSONSchemaError(reason: "more than \(limits.maxSubschemas) subschemas", pointer: pointer)
        }
        let index = nodes.count
        nodes.append(Node())
        byPointer[key] = index

        switch schema {
        case .bool(let value):
            nodes[index].always = value
            nodes[index].resource = locations[key]?.resource
            return index
        case .object(let object):
            nodes[index] = try compileObject(object, pointer: pointer, depth: depth)
            return index
        default:
            throw JSONSchemaError(reason: "a schema must be an object or a boolean", pointer: pointer)
        }
    }

    mutating func compileObject(_ schema: JSONObject, pointer: String, depth: Int) throws(JSONSchemaError) -> Node {
        let node = Node()
        let location = locations[ExactString(pointer)]
        let dialect = location?.dialect ?? Dialect(isDraft7: self.isDraft7)
        let isDraft7 = dialect.isDraft7
        let object = dialect.vocabularies == nil ? schema : JSONObject(schema.filter { dialect.uses($0.key) })
        node.resource = location?.resource
        for keyword in ["$recursiveRef", "$recursiveAnchor"] where !isDraft7 && object.contains(keyword) {
            throw JSONSchemaError(reason: "unsupported keyword \"\(keyword)\"", pointer: pointer)
        }

        func sub(_ key: String) -> String { "\(pointer)/\(escape(key))" }
        try validateAnnotations(object, at: pointer)

        // Definitions are checked whether or not anything refers to them: a malformed one is a
        // mistake even while unused. Each costs a node toward `maxSubschemas`.
        for keyword in ["$defs", "definitions"] {
            if let definitions = object[keyword] { _ = try compileMap(definitions, pointer: sub(keyword), depth: depth) }
        }

        if let ref = object["$ref"] {
            guard let target = ref.stringValue else {
                throw JSONSchemaError(reason: "\"$ref\" must be a string", pointer: sub("$ref"))
            }
            node.ref = try resolve(target, from: pointer, depth: depth).node
            if isDraft7 { return node }
        }
        if !isDraft7, let ref = object["$dynamicRef"] {
            guard let target = ref.stringValue else {
                throw JSONSchemaError(reason: "\"$dynamicRef\" must be a string", pointer: sub("$dynamicRef"))
            }
            let resolved = try resolve(target, from: pointer, depth: depth)
            node.dynamicRef = (resolved.node, resolved.dynamicAnchor)
        }

        if let type = object["type"] {
            var set: TypeSet = []
            let names: [JSONValue]
            if case .array(let list) = type {
                guard !list.isEmpty else {
                    throw JSONSchemaError(reason: "\"type\" must not be an empty array", pointer: sub("type"))
                }
                names = list
            } else {
                names = [type]
            }
            for name in names {
                guard let text = name.stringValue, let member = TypeSet.named(text) else {
                    throw JSONSchemaError(reason: "unknown type \(name)", pointer: sub("type"))
                }
                set.insert(member)
            }
            node.types = set
        }
        if let values = object["enum"] {
            guard case .array(let list) = values else {
                throw JSONSchemaError(reason: "\"enum\" must be an array", pointer: sub("enum"))
            }
            try validateNumericOperands(values, at: sub("enum"))
            node.enumeration = list
        }
        if let constant = object["const"] {
            try validateNumericOperands(constant, at: sub("const"))
            node.const = constant
        }

        node.minimum = try number(object, "minimum", pointer)
        node.maximum = try number(object, "maximum", pointer)
        if let divisor = try number(object, "multipleOf", pointer) {
            guard divisor > JSONNumber(0) else {
                throw JSONSchemaError(reason: "\"multipleOf\" must be greater than 0", pointer: sub("multipleOf"))
            }
            guard let exact = divisor.decimal.integerSignificand else {
                throw JSONSchemaError(
                    reason: "\"multipleOf\" with more than 19 significant digits is not supported", pointer: sub("multipleOf"))
            }
            node.multipleOf = (divisor, exact.significand, exact.scale)
        }
        // draft-04 style boolean exclusive bounds are not part of draft-07 or 2020-12.
        node.exclusiveMinimum = try number(object, "exclusiveMinimum", pointer)
        node.exclusiveMaximum = try number(object, "exclusiveMaximum", pointer)

        node.minLength = try count(object, "minLength", pointer)
        node.maxLength = try count(object, "maxLength", pointer)
        if let pattern = object["pattern"] {
            node.pattern = try compilePattern(pattern, pointer: sub("pattern"))
        }

        node.minItems = try count(object, "minItems", pointer)
        node.maxItems = try count(object, "maxItems", pointer)
        if !isDraft7 {
            node.minContains = try count(object, "minContains", pointer)
            node.maxContains = try count(object, "maxContains", pointer)
            if let prefix = object["prefixItems"] {
                node.prefixItems = try compileList(prefix, pointer: sub("prefixItems"), depth: depth)
            }
        }
        if let unique = object["uniqueItems"] {
            guard let flag = unique.boolValue else {
                throw JSONSchemaError(reason: "\"uniqueItems\" must be a boolean", pointer: sub("uniqueItems"))
            }
            node.uniqueItems = flag
        }
        // Draft-07 applies `additionalItems` only after array-form `items`, but checks it always;
        // 2020-12 has no such keyword, and a schema that relies on it would go unenforced.
        var additionalItems: Int?
        if let additional = object["additionalItems"] {
            guard isDraft7 else {
                throw JSONSchemaError(
                    reason: "\"additionalItems\" is not a 2020-12 keyword: write \"items\" after \"prefixItems\"",
                    pointer: sub("additionalItems"))
            }
            additionalItems = try compile(additional, pointer: sub("additionalItems"), depth: depth + 1)
        }
        if let items = object["items"] {
            if case .array = items {
                // The draft-07 tuple form; 2020-12 spells it `prefixItems` and requires a schema here.
                guard isDraft7 else {
                    throw JSONSchemaError(
                        reason: "\"items\" must be a schema; an array of schemas is \"prefixItems\" in 2020-12", pointer: sub("items"))
                }
                node.prefixItems = try compileList(items, pointer: sub("items"), depth: depth)
                node.items = additionalItems
            } else {
                node.items = try compile(items, pointer: sub("items"), depth: depth + 1)
            }
        }
        if let contains = object["contains"] {
            node.contains = try compile(contains, pointer: sub("contains"), depth: depth + 1)
        }
        if !isDraft7, let items = object["unevaluatedItems"] {
            node.unevaluatedItems = try compile(items, pointer: sub("unevaluatedItems"), depth: depth + 1)
        }

        if let properties = object["properties"] {
            let compiled = try compileMap(properties, pointer: sub("properties"), depth: depth)
            node.properties = Dictionary(uniqueKeysWithValues: compiled.map { (ExactString($0.name), $0.node) })
        }
        if let patterns = object["patternProperties"] {
            guard case .object(let map) = patterns else {
                throw JSONSchemaError(reason: "\"patternProperties\" must be an object", pointer: sub("patternProperties"))
            }
            for (source, schema) in map {
                let base = sub("patternProperties")
                let pattern = try compilePattern(.string(source), pointer: base)
                let child = try compile(schema, pointer: "\(base)/\(escape(source))", depth: depth + 1)
                node.patternProperties.append((pattern, child))
            }
        }
        if let additional = object["additionalProperties"] {
            node.additionalProperties = try compile(additional, pointer: sub("additionalProperties"), depth: depth + 1)
        }
        if !isDraft7, let properties = object["unevaluatedProperties"] {
            node.unevaluatedProperties = try compile(properties, pointer: sub("unevaluatedProperties"), depth: depth + 1)
        }
        if let names = object["propertyNames"] {
            node.propertyNames = try compile(names, pointer: sub("propertyNames"), depth: depth + 1)
        }
        if let required = object["required"] {
            node.required = try strings(required, pointer: sub("required"))
        }
        node.minProperties = try count(object, "minProperties", pointer)
        node.maxProperties = try count(object, "maxProperties", pointer)
        if !isDraft7, let dependent = object["dependentRequired"] {
            guard case .object(let map) = dependent else {
                throw JSONSchemaError(reason: "\"dependentRequired\" must be an object", pointer: sub("dependentRequired"))
            }
            for (name, needs) in map {
                node.dependentRequired.append((name, try strings(needs, pointer: "\(sub("dependentRequired"))/\(escape(name))")))
            }
        }
        if !isDraft7, let dependent = object["dependentSchemas"] {
            node.dependentSchemas = try compileMap(dependent, pointer: sub("dependentSchemas"), depth: depth)
        }
        if let dependencies = object["dependencies"] {
            // Both meta-schemas describe this legacy shape. Only draft-07 applies it.
            guard case .object(let map) = dependencies else {
                throw JSONSchemaError(reason: "\"dependencies\" must be an object", pointer: sub("dependencies"))
            }
            for (name, value) in map {
                let location = "\(sub("dependencies"))/\(escape(name))"
                if case .array = value {
                    let required = try strings(value, pointer: location)
                    if isDraft7 { node.dependentRequired.append((name, required)) }
                } else {
                    let dependent = try compile(value, pointer: location, depth: depth + 1)
                    if isDraft7 { node.dependentSchemas.append((name, dependent)) }
                }
            }
        }

        if let all = object["allOf"] { node.allOf = try compileList(all, pointer: sub("allOf"), depth: depth, nonEmpty: true) }
        if let any = object["anyOf"] { node.anyOf = try compileList(any, pointer: sub("anyOf"), depth: depth, nonEmpty: true) }
        if let one = object["oneOf"] { node.oneOf = try compileList(one, pointer: sub("oneOf"), depth: depth, nonEmpty: true) }
        if let not = object["not"] { node.not = try compile(not, pointer: sub("not"), depth: depth + 1) }
        // `then` and `else` mean nothing without `if`, but are checked all the same.
        let then = try object["then"].map { schema throws(JSONSchemaError) in try compile(schema, pointer: sub("then"), depth: depth + 1) }
        let otherwise = try object["else"].map { schema throws(JSONSchemaError) in try compile(schema, pointer: sub("else"), depth: depth + 1) }
        if let condition = object["if"] {
            node.ifNode = try compile(condition, pointer: sub("if"), depth: depth + 1)
            node.thenNode = then
            node.elseNode = otherwise
        }
        return node
    }

    /// - Parameter nonEmpty: `allOf`, `anyOf` and `oneOf` must have at least one member.
    mutating func compileList(
        _ value: JSONValue, pointer: String, depth: Int, nonEmpty: Bool = false
    ) throws(JSONSchemaError) -> [Int] {
        guard case .array(let list) = value, !(nonEmpty && list.isEmpty) else {
            throw JSONSchemaError(reason: nonEmpty ? "expected a non-empty array of schemas" : "expected an array of schemas", pointer: pointer)
        }
        var result: [Int] = []
        for (index, schema) in list.enumerated() {
            result.append(try compile(schema, pointer: "\(pointer)/\(index)", depth: depth + 1))
        }
        return result
    }

    mutating func compileMap(
        _ value: JSONValue, pointer: String, depth: Int
    ) throws(JSONSchemaError) -> [(name: String, node: Int)] {
        guard case .object(let map) = value else {
            throw JSONSchemaError(reason: "expected an object of schemas", pointer: pointer)
        }
        var result: [(name: String, node: Int)] = []
        for (name, schema) in map {
            result.append((name, try compile(schema, pointer: "\(pointer)/\(escape(name))", depth: depth + 1)))
        }
        return result
    }

    func compilePattern(_ value: JSONValue, pointer: String) throws(JSONSchemaError) -> Pattern {
        guard let source = value.stringValue else {
            throw JSONSchemaError(reason: "a pattern must be a string", pointer: pointer)
        }
        do {
            return try Pattern(source, maxStates: limits.maxPatternStates)
        } catch {
            throw JSONSchemaError(reason: "unsupported regular expression \"\(source)\": \(error.reason)", pointer: pointer)
        }
    }

    func number(_ object: JSONObject, _ key: String, _ pointer: String) throws(JSONSchemaError) -> JSONNumber? {
        guard let value = object[key] else { return nil }
        guard let number = value.numberValue else {
            throw JSONSchemaError(reason: "\"\(key)\" must be a number", pointer: "\(pointer)/\(key)")
        }
        guard number.isWithinExactDecimalRange else {
            throw JSONSchemaError(reason: JSONSchema.exponentRangeError, pointer: "\(pointer)/\(key)")
        }
        return number
    }

    private func validateNumericOperands(_ value: JSONValue, at pointer: String) throws(JSONSchemaError) {
        var pending = [value]
        while let next = pending.popLast() {
            switch next {
            case .array(let values): pending.append(contentsOf: values)
            case .object(let object): pending.append(contentsOf: object.lazy.map(\.value))
            case .number(let number) where !number.isWithinExactDecimalRange:
                throw JSONSchemaError(reason: JSONSchema.exponentRangeError, pointer: pointer)
            default: break
            }
        }
    }

    func count(_ object: JSONObject, _ key: String, _ pointer: String) throws(JSONSchemaError) -> Int? {
        guard let value = object[key] else { return nil }
        guard let number = value.numberValue, number.isInteger, number >= JSONNumber(0) else {
            throw JSONSchemaError(reason: "\"\(key)\" must be a non-negative integer", pointer: "\(pointer)/\(key)")
        }
        // A count beyond `Int` bounds nothing a value can reach, and means the same as `Int.max`.
        return number.intValue ?? .max
    }

    func strings(_ value: JSONValue, pointer: String) throws(JSONSchemaError) -> [String] {
        guard case .array(let list) = value else {
            throw JSONSchemaError(reason: "expected an array of strings", pointer: pointer)
        }
        var result: [String] = []
        var seen: Set<ExactString> = []
        for element in list {
            guard let text = element.stringValue else {
                throw JSONSchemaError(reason: "expected an array of strings", pointer: pointer)
            }
            guard seen.insert(ExactString(text)).inserted else {
                throw JSONSchemaError(reason: "array members must be unique", pointer: pointer)
            }
            result.append(text)
        }
        return result
    }

    private func validateAnnotations(_ object: JSONObject, at pointer: String) throws(JSONSchemaError) {
        for key in ["title", "description", "$comment", "format", "contentEncoding", "contentMediaType"] {
            if let value = object[key], value.stringValue == nil {
                throw JSONSchemaError(reason: "\"\(key)\" must be a string", pointer: "\(pointer)/\(key)")
            }
        }
        let booleans = isDraft7 ? ["readOnly", "writeOnly"] : ["readOnly", "writeOnly", "deprecated"]
        for key in booleans {
            if let value = object[key], value.boolValue == nil {
                throw JSONSchemaError(reason: "\"\(key)\" must be a boolean", pointer: "\(pointer)/\(key)")
            }
        }
        if let examples = object["examples"], examples.arrayValue == nil {
            throw JSONSchemaError(reason: "\"examples\" must be an array", pointer: "\(pointer)/examples")
        }
    }

    /// A reference can only land at an indexed schema position inside the document.
    mutating func resolve(
        _ reference: String, from pointer: String, depth: Int
    ) throws(JSONSchemaError) -> (node: Int, dynamicAnchor: ExactString?) {
        func unresolved(_ why: String) -> JSONSchemaError {
            JSONSchemaError(reason: "schema reference \"\(reference)\" \(why)", pointer: pointer)
        }
        guard let location = locations[ExactString(pointer)], let base = URL(string: location.resource.text),
            let referenceURI = uriReference(reference, against: base)
        else { throw unresolved("is not a well-formed URI-reference or JSON pointer fragment") }
        let requestedResource = ExactString(referenceURI.base.absoluteString)
        guard let documentPointer = resources[requestedResource], let resource = locations[ExactString(documentPointer)]?.resource else {
            throw unresolved("points outside the schema; external references are not dereferenced")
        }
        neededResources.insert(resource)
        let fragment = referenceURI.fragment ?? ""
        let pointer: String
        var dynamicAnchor: ExactString?
        if fragment.isEmpty {
            pointer = documentPointer
        } else if fragment.utf8.first == 0x2F {
            var canonical = documentPointer
            for raw in fragment.utf8.split(separator: 0x2F, omittingEmptySubsequences: false).dropFirst() {
                guard let token = unescape(String(decoding: raw, as: UTF8.self)) else {
                    throw unresolved("is not a well-formed JSON pointer fragment")
                }
                canonical += "/" + escape(token)
            }
            pointer = canonical
        } else {
            let name = ExactString(fragment)
            guard let anchor = anchors[resource]?[name] else { throw unresolved("does not resolve to a named anchor") }
            dynamicAnchor = anchor.dynamic ? name : nil
            pointer = anchor.pointer
        }
        guard let schema = locations[ExactString(pointer)]?.schema else { throw unresolved("does not point to a schema") }
        return (try compile(schema, pointer: pointer, depth: depth + 1), dynamicAnchor)
    }

    func escape(_ token: String) -> String {
        guard token.utf8.contains(where: { $0 == 0x7E || $0 == 0x2F }) else { return token }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(token.utf8.count)
        for byte in token.utf8 {
            switch byte {
            case 0x7E: bytes.append(contentsOf: [0x7E, 0x30])
            case 0x2F: bytes.append(contentsOf: [0x7E, 0x31])
            default: bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Percent-decode the entire URI fragment before reading the JSON Pointer it represents.
    private func decodeFragment(_ fragment: String.UTF8View.SubSequence) -> String? {
        if !fragment.contains(0x25) { return String(decoding: fragment, as: UTF8.self) }
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(fragment.count)
        var iterator = fragment.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x25 {
                guard let high = iterator.next().flatMap(hex), let low = iterator.next().flatMap(hex) else { return nil }
                bytes.append(high << 4 | low)
            } else {
                bytes.append(byte)
            }
        }
        return String(validating: bytes, as: UTF8.self)
    }

    /// Within a JSON Pointer token, a tilde must be escaped as `~0` and a slash as `~1`.
    func unescape(_ token: String) -> String? {
        guard token.utf8.contains(0x7E) else { return token }
        var result = ""
        var scalars = token.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "~" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            switch scalars.next() {
            case "0": result.append("~")
            case "1": result.append("/")
            default: return nil
            }
        }
        return result
    }
}

// MARK: - Validation

extension JSONSchema {
    private func fail(_ reason: String) -> SchemaViolation { SchemaViolation(path: [], reason: reason) }

    private func nested(_ violation: SchemaViolation, _ component: String) -> SchemaViolation {
        var violation = violation
        violation.path.append(component)
        return violation
    }

    /// Returns a violation whose path is innermost-first; `validate` reverses it once.
    ///
    /// `hops` counts consecutive steps between subschemas that did not descend into the
    /// instance. More of them than there are subschemas means the schema refers to itself
    /// without consuming input, which would otherwise never end.
    private func check(
        _ index: Int, _ instance: JSONValue, _ recursion: Int, _ hops: Int, _ run: Evaluation,
        contributingTo parent: EvaluatedLocations? = nil
    ) -> SchemaViolation? {
        guard recursion < limits.maxValidationRecursion, !run.stack.isExhausted else {
            return run.cutShort("nested deeper than the validator allows")
        }
        guard run.step() else { return fail("the schema takes too many steps") }
        guard hops <= nodes.count else {
            return run.cutShort("the schema refers to itself without consuming input")
        }
        let node = nodes[index]
        if let always = node.always { return always ? nil : fail("no value is allowed here") }
        var enteredResource = false
        if !dynamicAnchors.isEmpty, let resource = node.resource, run.dynamicScope.last != resource {
            enteredResource = true
            run.dynamicScope.append(resource)
        }
        defer { if enteredResource { run.dynamicScope.removeLast() } }
        let track = instance.isContainer && (parent != nil || node.unevaluatedItems != nil || node.unevaluatedProperties != nil)
        let locations = track ? EvaluatedLocations() : nil
        func sibling(_ child: Int) -> SchemaViolation? {
            check(child, instance, recursion + 1, hops + 1, run, contributingTo: locations)
        }
        if let ref = node.ref, let violation = sibling(ref) { return violation }
        if let reference = node.dynamicRef {
            var target = reference.fallback
            if let anchor = reference.anchor {
                for resource in run.dynamicScope {
                    guard run.step() else { return fail("the schema takes too many steps") }
                    if let candidate = dynamicAnchors[resource]?[anchor] {
                        target = candidate
                        break
                    }
                }
            }
            if let violation = sibling(target) { return violation }
        }

        if let types = node.types, !matches(types, instance) {
            if instance.isNull, !types.isDisjoint(with: [.number, .integer]) {
                // What a non-finite `Double` becomes, as JSON has no way to write it.
                return fail("expected \(types.names), got null (a Double that is NaN or infinite is written as null)")
            }
            return fail("expected \(types.names), got \(instance.typeName)")
        }
        if let enumeration = node.enumeration, !enumeration.contains(where: { run.equal(instance, $0) }) {
            let allowed = enumeration.prefix(12).map(brief).joined(separator: ", ")
            return fail("must be one of: \(allowed)")
        }
        if let const = node.const, !run.equal(instance, const) { return fail("must be \(brief(const))") }

        switch instance {
        case .number(let number):
            if let violation = checkNumber(node, number, run) { return violation }
        case .string(let string):
            if let violation = checkString(node, string, run) { return violation }
        case .array(let array):
            if let violation = checkArray(node, array, recursion, run, locations) { return violation }
        case .object(let object):
            if let violation = checkObject(node, object, recursion, hops, run, locations) { return violation }
        default: break
        }

        for child in node.allOf {
            if let violation = sibling(child) { return violation }
        }
        if !node.anyOf.isEmpty {
            var found = false
            for child in node.anyOf where sibling(child) == nil {
                found = true
                if locations == nil { break }
            }
            if !found { return fail("does not match any of the allowed alternatives") }
        }
        if !node.oneOf.isEmpty {
            let matching = run.inverting { node.oneOf.count { sibling($0) == nil } }
            if matching != 1 {
                return fail(matching == 0 ? "does not match any of the allowed alternatives" : "matches more than one alternative")
            }
        }
        if let not = node.not, run.inverting({ check(not, instance, recursion + 1, hops + 1, run) }) == nil {
            return fail("matches a schema it must not match")
        }
        if let condition = node.ifNode {
            if run.inverting({ sibling(condition) }) == nil {
                if let then = node.thenNode, let violation = sibling(then) { return violation }
            } else if let otherwise = node.elseNode, let violation = sibling(otherwise) {
                return violation
            }
        }
        if let locations {
            if let unevaluated = node.unevaluatedItems, case .array(let array) = instance {
                for (offset, item) in array.enumerated() where !locations.items.contains(offset) {
                    if let violation = check(unevaluated, item, recursion + 1, 0, run) { return nested(violation, "[\(offset)]") }
                    locations.items.insert(offset)
                }
            }
            if let unevaluated = node.unevaluatedProperties, case .object(let object) = instance {
                for (name, value) in object where !locations.properties.contains(ExactString(name)) {
                    if let violation = check(unevaluated, value, recursion + 1, 0, run) { return nested(violation, name) }
                    locations.properties.insert(ExactString(name))
                }
            }
            parent?.merge(locations, run: run)
        }
        return nil
    }

    private func matches(_ types: TypeSet, _ instance: JSONValue) -> Bool {
        switch instance {
        case .null: types.contains(.null)
        case .bool: types.contains(.boolean)
        case .number(let number): types.contains(.number) || (types.contains(.integer) && number.isInteger)
        case .string: types.contains(.string)
        case .array: types.contains(.array)
        case .object: types.contains(.object)
        }
    }

    private func checkNumber(_ node: Node, _ number: JSONNumber, _ run: Evaluation) -> SchemaViolation? {
        guard node.minimum != nil || node.maximum != nil || node.exclusiveMinimum != nil || node.exclusiveMaximum != nil
            || node.multipleOf != nil else { return nil }
        guard run.accepts(number) else { return fail(Self.exponentRangeError) }
        if let minimum = node.minimum, number < minimum { return fail("must be at least \(minimum)") }
        if let maximum = node.maximum, number > maximum { return fail("must be at most \(maximum)") }
        if let bound = node.exclusiveMinimum, number <= bound { return fail("must be greater than \(bound)") }
        if let bound = node.exclusiveMaximum, number >= bound { return fail("must be less than \(bound)") }
        if let divisor = node.multipleOf, !number.decimal.isMultiple(of: divisor.significand, scale: divisor.scale) {
            return fail("must be a multiple of \(divisor.number)")
        }
        return nil
    }

    private func checkString(_ node: Node, _ string: String, _ run: Evaluation) -> SchemaViolation? {
        if node.minLength != nil || node.maxLength != nil {
            let length = string.unicodeScalars.count
            if let minimum = node.minLength, length < minimum { return fail("must be at least \(minimum) characters long") }
            if let maximum = node.maxLength, length > maximum { return fail("must be at most \(maximum) characters long") }
        }
        if let pattern = node.pattern {
            guard let found = run.matches(pattern, string) else { return fail("too many pattern steps") }
            if !found { return fail("must match the pattern \(pattern.source)") }
        }
        return nil
    }

    /// How a schema's own constant is quoted in a message.
    ///
    /// Writing a value out recurses once per level, and a message is built on whatever stack is
    /// left — so a deeply nested constant is named rather than written.
    private func brief(_ value: JSONValue) -> String {
        let depth = value.nestingDepth
        return depth <= 8 ? value.description : "a value nested \(depth) levels deep"
    }

    /// Whether the stack that is left can hold a comparison or a hash of `value`.
    ///
    /// Both recurse once per level of the value, and nothing inside them can stop: `==` and
    /// `hash(into:)` have no way to fail. So the depth is measured first (without recursion) and
    /// a value too deep for the remaining stack is reported as a violation instead of crashing.
    /// The cost per level is the largest observed in an unoptimized build, rounded up.
    private func canCompare(_ value: JSONValue) -> Bool {
        guard value.isContainer, let remaining = StackGuard.remaining else { return true }
        return value.nestingDepth * 1536 + 16 * 1024 <= remaining
    }

    private func checkArray(
        _ node: Node, _ array: [JSONValue], _ recursion: Int, _ run: Evaluation, _ locations: EvaluatedLocations?
    ) -> SchemaViolation? {
        if let minimum = node.minItems, array.count < minimum { return fail("must have at least \(minimum) items") }
        if let maximum = node.maxItems, array.count > maximum { return fail("must have at most \(maximum) items") }
        for (index, element) in array.enumerated() {
            let schema: Int?
            if index < node.prefixItems.count { schema = node.prefixItems[index] } else { schema = node.items }
            if let schema {
                if let violation = check(schema, element, recursion + 1, 0, run) { return nested(violation, "[\(index)]") }
                locations?.items.insert(index)
            }
        }
        if let contains = node.contains {
            // With a maximum, an item cut short and so not counted could let the array through.
            func matchingItems() -> Int {
                var matching = 0
                for (index, item) in array.enumerated() where check(contains, item, recursion + 1, 0, run) == nil {
                    matching += 1
                    locations?.items.insert(index)
                }
                return matching
            }
            let matching = node.maxContains == nil && locations == nil ? matchingItems() : run.inverting(matchingItems)
            let minimum = node.minContains ?? 1
            if matching < minimum { return fail("must contain at least \(minimum) matching items") }
            if let maximum = node.maxContains, matching > maximum {
                return fail("must contain at most \(maximum) matching items")
            }
        }
        if node.uniqueItems {
            guard array.allSatisfy(run.chargeHash) else { return fail("the schema could not compare all array items") }
            guard canCompare(.array(array)) else {
                run.stack.noteExhausted()
                return fail("nested too deeply to compare on the stack that is left")
            }
            if Set(array).count != array.count { return fail("items must be unique") }
        }
        return nil
    }

    private func checkObject(
        _ node: Node, _ object: JSONObject, _ recursion: Int, _ hops: Int, _ run: Evaluation, _ locations: EvaluatedLocations?
    ) -> SchemaViolation? {
        for name in node.required where !object.contains(name) {
            return SchemaViolation(path: [name], reason: "missing required field")
        }
        if let minimum = node.minProperties, object.count < minimum { return fail("must have at least \(minimum) properties") }
        if let maximum = node.maxProperties, object.count > maximum { return fail("must have at most \(maximum) properties") }

        for (name, value) in object {
            var evaluated = false
            if let property = node.properties[ExactString(name)] {
                evaluated = true
                if let violation = check(property, value, recursion + 1, 0, run) { return nested(violation, name) }
            }
            for entry in node.patternProperties {
                guard let found = run.matches(entry.pattern, name) else { return fail("too many pattern steps") }
                guard found else { continue }
                evaluated = true
                if let violation = check(entry.node, value, recursion + 1, 0, run) { return nested(violation, name) }
            }
            if !evaluated, let additional = node.additionalProperties {
                if nodes[additional].always == false { return nested(fail("unknown field"), name) }
                if let violation = check(additional, value, recursion + 1, 0, run) { return nested(violation, name) }
                evaluated = true
            }
            if evaluated { locations?.properties.insert(ExactString(name)) }
            if let names = node.propertyNames, let violation = check(names, .string(name), recursion + 1, 0, run) {
                return nested(SchemaViolation(path: [], reason: "invalid field name: \(violation.reason)"), name)
            }
        }
        for entry in node.dependentRequired where object.contains(entry.name) {
            for needed in entry.needs where !object.contains(needed) {
                return SchemaViolation(path: [needed], reason: "required when \"\(entry.name)\" is present")
            }
        }
        for entry in node.dependentSchemas where object.contains(entry.name) {
            // The same instance again: a step that consumes nothing.
            if let violation = check(entry.node, .object(object), recursion + 1, hops + 1, run, contributingTo: locations) { return violation }
        }
        return nil
    }
}
