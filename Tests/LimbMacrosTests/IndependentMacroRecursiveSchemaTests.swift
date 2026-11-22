#if canImport(Darwin)
import Darwin
#endif
import Limb
import LimbTesting
import Testing


// MARK: - Fixtures (internal on purpose: the definition names are then predictable)

@Schema
struct IndependentMacroTree: Equatable {
    var value: Int
    var children: [IndependentMacroTree]
}

/// A.
@Schema
struct IndependentMacroAuthor: Equatable {
    var name: String
    var books: [IndependentMacroBook] = []
}

/// B.
@Schema
struct IndependentMacroBook: Equatable {
    var title: String
    var authors: [IndependentMacroAuthor]
    var sequels: [String: IndependentMacroBook]?
}

/// Every way a struct can reach itself.
@Schema
struct IndependentMacroShapes: Equatable {
    var name: String
    var maybeList: [IndependentMacroShapes]?
    var listOfMaybe: [IndependentMacroShapes?]
    var nested: [[IndependentMacroShapes]]
    var map: [String: IndependentMacroShapes]
    var maybeMap: [String: [IndependentMacroShapes?]]?
}

enum IndependentMacroRecursionA {
    @Schema
    struct Node: Equatable {
        var number: Int
        var next: [Node]
    }
}

enum IndependentMacroRecursionB {
    @Schema
    struct Node: Equatable {
        var text: String
        var next: [Node]
    }
}

enum IndependentMacroRecursionC {
    /// A type that really is called what a second `Node` would be numbered.
    @Schema
    struct Node_2: Equatable {
        var flag: Bool
        var next: [Node_2]
    }
}

/// The two `Node`s, asked for in the other order.
@Schema
struct IndependentMacroTwoNodesReversed: Equatable {
    var b: IndependentMacroRecursionB.Node
    var a: IndependentMacroRecursionA.Node
}

@Schema
struct IndependentMacroThreeNodes: Equatable {
    var a: IndependentMacroRecursionA.Node
    var b: IndependentMacroRecursionB.Node
    var c: IndependentMacroRecursionC.Node_2
}

@Schema
struct IndependentMacroThreeNodesReversed: Equatable {
    var c: IndependentMacroRecursionC.Node_2
    var a: IndependentMacroRecursionA.Node
    var b: IndependentMacroRecursionB.Node
}

/// Takes one `Node` of each kind and returns the first kind.
@Tool
struct IndependentMacroSwapNodes {
    func call(b: IndependentMacroRecursionB.Node, a: IndependentMacroRecursionA.Node) -> IndependentMacroRecursionA.Node { a }
}

/// Two different recursive types with the same short name, and one of them used three times.
@Schema
struct IndependentMacroTwoNodes: Equatable {
    var a: IndependentMacroRecursionA.Node
    var b: IndependentMacroRecursionB.Node
    var again: IndependentMacroRecursionA.Node?
    var list: [IndependentMacroRecursionA.Node?]
}

@Schema
struct IndependentMacroGenericTree<Value: SchemaRepresentable & Equatable>: Equatable {
    var value: Value
    var children: [IndependentMacroGenericTree<Value>]
}

@Schema
struct IndependentMacroTwoGenericTrees: Equatable {
    var ints: IndependentMacroGenericTree<Int>
    var strings: IndependentMacroGenericTree<String>
}

/// Two specializations whose printed names are the same: both are `…GenericTree<Node>`.
@Schema
struct IndependentMacroTwoTreesOfNodes: Equatable {
    var a: IndependentMacroGenericTree<IndependentMacroRecursionA.Node>
    var b: IndependentMacroGenericTree<IndependentMacroRecursionB.Node>
}

// Two recursive types whose names differ only in characters outside ASCII.
@Schema
struct IndependentMacroУзел: Equatable {
    var число: Int
    var дети: [IndependentMacroУзел]
}

@Schema
struct IndependentMacroЛист: Equatable {
    var текст: String
    var дети: [IndependentMacroЛист]
}

@Schema
struct IndependentMacroCyrillicPair: Equatable {
    var узел: IndependentMacroУзел
    var лист: IndependentMacroЛист
}

@Schema
struct IndependentMacroPlain: Equatable {
    var x: Int
}

/// A holder.
@Schema
struct IndependentMacroHolder: Equatable {
    /// The root.
    var root: IndependentMacroTree
    var roots: [IndependentMacroTree] = []
    var plain: IndependentMacroPlain
    var plainAgain: IndependentMacroPlain
}

/// A recursive type nobody outside this file can name.
@Schema
private struct IMPrivateTree: Equatable {
    var value: Int
    var children: [IMPrivateTree]
}

/// Grafts one tree onto another.
@Tool
struct IndependentMacroGraft {
    /// - Parameters:
    ///   - tree: The tree to extend.
    ///   - other: A tree to add as the last child.
    func call(tree: IndependentMacroTree, other: IndependentMacroTree?, forest: [IndependentMacroTree] = []) -> IndependentMacroTree {
        IndependentMacroTree(value: tree.value, children: tree.children + (other.map { [$0] } ?? []) + forest)
    }
}

/// Adds an author to a book.
@Tool
struct IndependentMacroCredit {
    func call(book: IndependentMacroBook, author: IndependentMacroAuthor) -> IndependentMacroBook {
        IndependentMacroBook(title: book.title, authors: book.authors + [author], sequels: book.sequels)
    }
}

/// The children of a tree.
@Tool
struct IndependentMacroChildren {
    func call(tree: IndependentMacroTree) -> [IndependentMacroTree] { tree.children }
}

/// The first child, if any.
@Tool
struct IndependentMacroFirstChild {
    func call(tree: IndependentMacroTree) -> IndependentMacroTree? { tree.children.first }
}

/// Builds a chain of the given depth.
@Tool
struct IndependentMacroGrow {
    func call(depth: Int) -> IndependentMacroTree {
        var result = IndependentMacroTree(value: 0, children: [])
        for level in 1..<max(depth, 1) { result = IndependentMacroTree(value: level, children: [result]) }
        return result
    }
}

// MARK: - Helpers

private let treeName = "IndependentMacroTree"
private func reference(_ name: String) -> JSONValue { ["$ref": .string("#/$defs/" + name)] }
private func nullable(_ wrapped: JSONValue) -> JSONValue { ["anyOf": [wrapped, ["type": "null"]]] }

private func tree(_ value: Int, _ children: IndependentMacroTree...) -> IndependentMacroTree {
    IndependentMacroTree(value: value, children: children)
}

/// The schema and the decoder both accept every instance in `accepted` and both reject every
/// instance in `rejected`.
private func expectAgreement<T: SchemaRepresentable>(
    _ type: T.Type, accepts accepted: [JSONValue], rejects rejected: [JSONValue],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let schema = IndependentMacroCheckSchema(T.jsonSchema, sourceLocation: sourceLocation) else { return }
    for instance in accepted {
        let violation = schema.validate(instance)
        #expect(violation == nil, "the schema rejects \(instance)", sourceLocation: sourceLocation)
        #expect((try? T(json: instance)) != nil, "the decoder rejects \(instance)", sourceLocation: sourceLocation)
    }
    for instance in rejected {
        #expect(schema.validate(instance) != nil, "the schema accepts \(instance)", sourceLocation: sourceLocation)
        #expect((try? T(json: instance)) == nil, "the decoder accepts \(instance)", sourceLocation: sourceLocation)
    }
}

// MARK: - Schemas

@Suite struct IndependentMacroRecursiveSchemaTests {
    @Test func aSelfRecursiveTypeIsDefinedOnceAndReferenced() {
        let schema = IndependentMacroTree.jsonSchema
        // The root says what it is…
        #expect(schema["type"] == "object")
        #expect(schema["required"] == ["value", "children"])
        #expect(schema["properties"]?["value"] == ["type": "integer"])
        // …the recursion is a reference…
        #expect(schema["properties"]?["children"] == ["type": "array", "items": reference(treeName)])
        // …to the one definition, which has the same body.
        #expect(schema["$defs"]?.objectValue?.map(\.key) == [treeName])
        #expect(schema["$defs"]?[treeName]?["type"] == "object")
        #expect(schema["$defs"]?[treeName]?["properties"] == schema["properties"])
        #expect(schema["$defs"]?[treeName]?["required"] == schema["required"])
        // No `$defs` inside the definition: references resolve against the root.
        #expect(schema["$defs"]?[treeName]?["$defs"] == nil)

        expectAgreement(
            IndependentMacroTree.self,
            accepts: [
                ["value": 1, "children": []],
                ["value": 1, "children": [["value": 2, "children": [["value": 3, "children": []]]]]],
            ],
            rejects: [
                ["value": 1],
                ["value": 1, "children": [["value": "two", "children": []]]],
                ["value": 1, "children": [["value": 2, "children": [["value": 3]]]]],
                ["value": 1, "children": [["value": 2, "children": [["value": 3, "children": [nil]]]]]],
                ["value": 1, "children": [["value": 2, "children": [["value": 3, "children": [["value": 4.5, "children": []]]]]]]],
            ])
        IndependentMacroCheckRoundTrip(tree(1, tree(2), tree(3, tree(4, tree(5)))))
    }

    @Test func theSchemaIsTheSameEveryTime() {
        #expect(IndependentMacroTree.jsonSchema == IndependentMacroTree.jsonSchema)
        #expect(JSONValue.object(IndependentMacroBook.jsonSchema).encoded() == JSONValue.object(IndependentMacroBook.jsonSchema).encoded())
    }

    /// A value of a recursive type can be as deep as the data is. The parser accepts 128
    /// levels of JSON by default and the generated decoder follows; a tree 30 levels deep is
    /// 60 levels of JSON. The validator has to accept what the type's own encoder produced —
    /// in every build configuration: it gives up on stack usage, and frames are several times
    /// larger in a debug build.
    @Test(arguments: [5, 12, 13, 14, 20, 30, 60, 100])
    func aDeepValueValidates(depth: Int) throws {
        var deep = tree(0)
        for level in 1..<depth { deep = tree(level, deep) }
        #expect(try IndependentMacroTree(json: deep.jsonValue) == deep)
        let schema = try JSONSchema(.object(IndependentMacroTree.jsonSchema))
        let violation = schema.validate(deep.jsonValue)
        #expect(violation == nil, "a tree \(depth) levels deep: \(violation?.reason ?? "")")
    }

    @Test func mutualRecursionFromEitherEnd() {
        let author: JSONValue = ["name": "a", "books": [["title": "t", "authors": [["name": "b"]]]]]
        let book: JSONValue = ["title": "t", "authors": [["name": "a", "books": [["title": "u", "authors": []]]]], "sequels": ["next": ["title": "v", "authors": []]]]
        expectAgreement(
            IndependentMacroAuthor.self,
            accepts: [["name": "a"], author, ["name": "a", "books": [book]]],
            rejects: [
                ["name": 1],
                ["name": "a", "books": [["title": "t"]]],
                ["name": "a", "books": [["title": "t", "authors": [["name": 2]]]]],
                ["name": "a", "books": [["title": "t", "authors": [["name": "b", "books": [["authors": []]]]]]]],
                ["name": "a", "books": [["title": "t", "authors": [], "sequels": ["x": ["title": 1, "authors": []]]]]],
            ])
        expectAgreement(
            IndependentMacroBook.self,
            accepts: [["title": "t", "authors": []], book, ["title": "t", "authors": [author], "sequels": nil]],
            rejects: [
                ["title": "t"],
                ["title": "t", "authors": [["name": "a", "books": [["title": 1, "authors": []]]]]],
                ["title": "t", "authors": [], "sequels": ["x": ["title": "u"]]],
                ["title": "t", "authors": [], "sequels": ["x": ["title": "u", "authors": [["books": []]]]]],
                ["title": "t", "authors": [], "sequels": [["title": "u", "authors": []]]],
            ])
        // Both documents are rooted in an object, whichever type they start from.
        #expect(IndependentMacroAuthor.jsonSchema["type"] == "object")
        #expect(IndependentMacroBook.jsonSchema["type"] == "object")
        #expect(IndependentMacroAuthor.jsonSchema["description"] == "A.")
        #expect(IndependentMacroBook.jsonSchema["description"] == "B.")
        IndependentMacroCheckRoundTrip(
            IndependentMacroBook(
                title: "t", authors: [IndependentMacroAuthor(name: "a", books: [IndependentMacroBook(title: "u", authors: [], sequels: nil)])],
                sequels: ["n": IndependentMacroBook(title: "v", authors: [], sequels: [:])]))
    }

    @Test func recursionThroughOptionalsArraysAndDictionaries() {
        let leaf: JSONValue = ["name": "leaf", "listOfMaybe": [], "nested": [], "map": [:]]
        let full: JSONValue = [
            "name": "root", "maybeList": [leaf], "listOfMaybe": [leaf, nil], "nested": [[leaf], []], "map": ["k": leaf],
            "maybeMap": ["k": [nil, leaf]],
        ]
        func broken(_ change: (inout JSONObject) -> Void) -> JSONValue {
            var object = full.objectValue ?? [:]
            change(&object)
            return .object(object)
        }
        let badLeaf: JSONValue = ["name": 1, "listOfMaybe": [], "nested": [], "map": [:]]
        expectAgreement(
            IndependentMacroShapes.self,
            accepts: [leaf, full, broken { $0["maybeList"] = nil }, broken { $0["maybeMap"] = nil }],
            rejects: [
                broken { $0["maybeList"] = [badLeaf] },
                broken { $0["maybeList"] = [nil] },
                broken { $0["listOfMaybe"] = [badLeaf] },
                broken { $0["listOfMaybe"] = nil },
                broken { $0["nested"] = [[badLeaf]] },
                broken { $0["nested"] = [leaf] },
                broken { $0["map"] = ["k": badLeaf] },
                broken { $0["map"] = ["k": nil] },
                broken { $0["maybeMap"] = ["k": [badLeaf]] },
                broken { $0["maybeMap"] = ["k": badLeaf] },
            ])
        let schema = IndependentMacroShapes.jsonSchema
        let name = "IndependentMacroShapes"
        #expect(schema["$defs"]?.objectValue?.map(\.key) == [name])
        #expect(schema["properties"]?["maybeList"] == nullable(["type": "array", "items": reference(name)]))
        #expect(schema["properties"]?["listOfMaybe"] == ["type": "array", "items": nullable(reference(name))])
        #expect(schema["properties"]?["nested"] == ["type": "array", "items": ["type": "array", "items": reference(name)]])
        #expect(schema["properties"]?["map"] == ["type": "object", "additionalProperties": reference(name)])
        #expect(schema["required"] == ["name", "listOfMaybe", "nested", "map"])
        #expect(schema["description"] == "Every way a struct can reach itself.")
        let value = IndependentMacroShapes(name: "v", maybeList: nil, listOfMaybe: [nil], nested: [[]], map: [:], maybeMap: ["k": [nil]])
        IndependentMacroCheckRoundTrip(IndependentMacroShapes(name: "r", maybeList: [value], listOfMaybe: [value, nil], nested: [[value]], map: ["m": value], maybeMap: nil))
    }

    /// A type that merely contains a recursive type is written in place; the recursive one is
    /// a reference; a type that is not recursive is repeated in place and gets no definition.
    @Test func aHolderOfARecursiveType() {
        let schema = IndependentMacroHolder.jsonSchema
        #expect(schema["type"] == "object")
        #expect(schema["description"] == "A holder.")
        #expect(schema["$defs"]?.objectValue?.map(\.key) == [treeName])
        // The property's own description sits next to the reference (allowed since 2019-09).
        #expect(schema["properties"]?["root"] == ["$ref": .string("#/$defs/" + treeName), "description": "The root."])
        #expect(schema["properties"]?["roots"] == ["type": "array", "items": reference(treeName)])
        #expect(schema["properties"]?["plain"] == .object(IndependentMacroPlain.jsonSchema))
        #expect(schema["properties"]?["plainAgain"] == .object(IndependentMacroPlain.jsonSchema))
        #expect(IndependentMacroPlain.jsonSchema["$defs"] == nil)
        expectAgreement(
            IndependentMacroHolder.self,
            accepts: [["root": ["value": 1, "children": []], "plain": ["x": 1], "plainAgain": ["x": 2]]],
            rejects: [
                ["root": ["value": 1], "plain": ["x": 1], "plainAgain": ["x": 2]],
                ["root": ["value": 1, "children": [["value": true, "children": []]]], "plain": ["x": 1], "plainAgain": ["x": 2]],
                ["root": ["value": 1, "children": []], "roots": [["children": []]], "plain": ["x": 1], "plainAgain": ["x": 2]],
                ["root": ["value": 1, "children": []], "plain": ["x": 1], "plainAgain": ["x": "2"]],
            ])
    }

    /// The same through every kind of container, at a depth where an unoptimized build needs
    /// the large stack: each chain is 40 levels of the type.
    @Test func deepValuesThroughOptionalsArraysAndDictionaries() throws {
        func leaf(_ name: String) -> IndependentMacroShapes {
            IndependentMacroShapes(name: name, maybeList: nil, listOfMaybe: [], nested: [], map: [:], maybeMap: nil)
        }
        func chain(_ wrap: (IndependentMacroShapes, Int) -> IndependentMacroShapes) -> IndependentMacroShapes {
            var value = leaf("0")
            for level in 1..<40 { value = wrap(value, level) }
            return value
        }
        let chains: [(String, IndependentMacroShapes)] = [
            ("optional array", chain { inner, level in var outer = leaf("\(level)"); outer.maybeList = [inner]; return outer }),
            ("array of optionals", chain { inner, level in var outer = leaf("\(level)"); outer.listOfMaybe = [nil, inner]; return outer }),
            ("dictionary", chain { inner, level in var outer = leaf("\(level)"); outer.map = ["k": inner]; return outer }),
            ("optional dictionary of arrays", chain { inner, level in var outer = leaf("\(level)"); outer.maybeMap = ["k": [inner, nil]]; return outer }),
        ]
        let schema = try JSONSchema(.object(IndependentMacroShapes.jsonSchema))
        for (name, value) in chains {
            let json = value.jsonValue
            let violation = schema.validate(json)
            #expect(violation == nil, "\(name): \(violation?.reason ?? "")")
            #expect(try IndependentMacroShapes(json: json) == value, "\(name)")
        }
        // Arrays of arrays cost three levels of JSON per level of the type: 30 levels are 90.
        var nested = leaf("0")
        for level in 1..<30 { var outer = leaf("\(level)"); outer.nested = [[], [nested]]; nested = outer }
        #expect(schema.validate(nested.jsonValue) == nil)
        #expect(try IndependentMacroShapes(json: nested.jsonValue) == nested)

        // A violation at the very bottom is still found, and found where it is.
        var broken: JSONValue = ["name": 1, "listOfMaybe": [], "nested": [], "map": [:]]
        for level in 1..<40 { broken = ["name": .string("\(level)"), "listOfMaybe": [], "nested": [], "map": ["k": broken]] }
        let violation = schema.validate(broken)
        #expect(violation != nil)
        #expect(violation?.path.count == 39 * 2 + 1)
        #expect(violation?.path.last == "name")
        #expect(violation?.reason.contains("string") == true, "\(violation?.reason ?? "")")
        #expect((try? IndependentMacroShapes(json: broken)) == nil)
    }

    #if canImport(Darwin)
    /// When the validator runs out of stack it repeats the run on a thread of its own. That
    /// thread has to be gone afterwards: thousands of deep values in a row, and many at once,
    /// must leave the process with the threads it had.
    @Test func deepValidationsLeaveNoThreadsBehind() async throws {
        func threadCount() -> Int {
            var threads: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
            return Int(count)
        }
        let schema = try JSONSchema(.object(IndependentMacroTree.jsonSchema))
        var deep = tree(0)
        for level in 1..<40 { deep = tree(level, deep) }
        let value = deep.jsonValue
        // Warm up: the concurrency runtime starts its own threads on demand.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { _ = schema.validate(value) } }
        }
        let before = threadCount()
        for _ in 0..<3000 { #expect(schema.validate(value) == nil) }
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    var valid = true
                    for _ in 0..<20 where schema.validate(value) != nil { valid = false }
                    return valid
                }
            }
            for await valid in group { #expect(valid) }
        }
        let after = threadCount()
        #expect(before > 0)
        // Slack for threads the runtime itself may add; 4280 leaked threads would not fit.
        #expect(after <= before + 16, "threads: \(before) before, \(after) after")
    }
    #endif

    /// `NS.A.Node` and `NS.B.Node` are different types with different members. Both are called
    /// `Node`; the second one met in a document is numbered.
    @Test func sameShortNameInDifferentNamespaces() {
        let schema = IndependentMacroTwoNodes.jsonSchema
        #expect(schema["$defs"]?.objectValue?.map(\.key) == ["Node", "Node_2"])
        #expect(schema["properties"]?["a"] == reference("Node"))
        #expect(schema["properties"]?["b"] == reference("Node_2"))
        #expect(schema["properties"]?["again"] == nullable(reference("Node")))
        #expect(schema["properties"]?["list"] == ["type": "array", "items": nullable(reference("Node"))])
        #expect(schema["$defs"]?["Node"]?["properties"]?.objectValue?.map(\.key) == ["number", "next"])
        #expect(schema["$defs"]?["Node"]?["properties"]?["next"] == ["type": "array", "items": reference("Node")])
        #expect(schema["$defs"]?["Node_2"]?["properties"]?.objectValue?.map(\.key) == ["text", "next"])
        #expect(schema["$defs"]?["Node_2"]?["properties"]?["next"] == ["type": "array", "items": reference("Node_2")])
        let a: JSONValue = ["number": 1, "next": [["number": 2, "next": []]]]
        let b: JSONValue = ["text": "t", "next": [["text": "u", "next": []]]]
        expectAgreement(
            IndependentMacroTwoNodes.self,
            accepts: [["a": a, "b": b, "list": []], ["a": a, "b": b, "again": a, "list": [a, nil]], ["a": a, "b": b, "again": nil, "list": [nil]]],
            rejects: [
                ["a": b, "b": b, "list": []],
                ["a": a, "b": a, "list": []],
                ["a": a, "b": b, "again": b, "list": []],
                ["a": a, "b": b, "list": [b]],
                ["a": ["number": 1, "next": [["text": "u", "next": []]]], "b": b, "list": []],
                ["a": a, "b": ["text": "t", "next": [["number": 2, "next": []]]], "list": []],
            ])
    }

    // observed: the number a type gets depends on the order in which the document meets the
    // types, so one type can go by different names in different documents — here `A.Node` is
    // `Node` in one schema and `Node_2` in the other, and in a tool's input and output schemas.
    // Each document is consistent in itself, and the same on every launch: nothing in a name
    // comes from the process (the expected texts are literals).
    @Test func numberingFollowsTheOrderOfFirstUse() {
        let reversed = IndependentMacroTwoNodesReversed.jsonSchema
        #expect(reversed["$defs"]?.objectValue?.map(\.key) == ["Node", "Node_2"])
        #expect(reversed["properties"]?["b"] == reference("Node"))
        #expect(reversed["properties"]?["a"] == reference("Node_2"))
        #expect(reversed["$defs"]?["Node"]?["properties"]?.objectValue?.map(\.key) == ["text", "next"])
        #expect(reversed["$defs"]?["Node_2"]?["properties"]?.objectValue?.map(\.key) == ["number", "next"])
        let a: JSONValue = ["number": 1, "next": [["number": 2, "next": []]]]
        let b: JSONValue = ["text": "t", "next": [["text": "u", "next": []]]]
        expectAgreement(
            IndependentMacroTwoNodesReversed.self, accepts: [["a": a, "b": b]],
            rejects: [["a": b, "b": b], ["a": a, "b": a], ["a": b, "b": a]])

        let definition = IndependentMacroSwapNodes.definition
        IndependentMacroCheckSchema(definition.inputSchema)
        #expect(definition.inputSchema["properties"]?["b"] == reference("Node"))
        #expect(definition.inputSchema["properties"]?["a"] == reference("Node_2"))
        #expect(definition.outputSchema?["$defs"]?.objectValue?.map(\.key) == ["Node"])
        #expect(definition.outputSchema?["properties"]?.objectValue?.map(\.key) == ["number", "next"])
        if let output = definition.outputSchema { IndependentMacroCheckSchema(output) }

        // The whole text, as a client would cache it.
        #expect(
            "\(JSONValue.object(reversed))"
                == ##"{"type":"object","description":"The two `Node`s, asked for in the other order.","properties":{"b":{"$ref":"#/$defs/Node"},"a":{"$ref":"#/$defs/Node_2"}},"required":["b","a"],"$defs":{"Node":{"type":"object","properties":{"text":{"type":"string"},"next":{"type":"array","items":{"$ref":"#/$defs/Node"}}},"required":["text","next"]},"Node_2":{"type":"object","properties":{"number":{"type":"integer"},"next":{"type":"array","items":{"$ref":"#/$defs/Node_2"}}},"required":["number","next"]}}}"##)
    }

    /// A number must not run into a type that really has that name: with `A.Node`, `B.Node`
    /// and `C.Node_2` in one document there are three definitions, in whatever order.
    @Test func aNumberedNameDoesNotCollideWithARealOne() {
        let a: JSONValue = ["number": 1, "next": [["number": 2, "next": []]]]
        let b: JSONValue = ["text": "t", "next": [["text": "u", "next": []]]]
        let c: JSONValue = ["flag": true, "next": [["flag": false, "next": []]]]
        let forward = IndependentMacroThreeNodes.jsonSchema
        #expect(forward["$defs"]?.objectValue?.map(\.key) == ["Node", "Node_2", "Node_2_2"])
        #expect(forward["properties"]?["c"] == reference("Node_2_2"))
        expectAgreement(
            IndependentMacroThreeNodes.self, accepts: [["a": a, "b": b, "c": c]],
            rejects: [["a": a, "b": c, "c": c], ["a": a, "b": b, "c": b], ["a": c, "b": b, "c": c], ["a": b, "b": a, "c": c]])
        let backward = IndependentMacroThreeNodesReversed.jsonSchema
        #expect(backward["$defs"]?.objectValue?.map(\.key) == ["Node_2", "Node", "Node_3"])
        #expect(backward["properties"]?["c"] == reference("Node_2"))
        #expect(backward["properties"]?["a"] == reference("Node"))
        #expect(backward["properties"]?["b"] == reference("Node_3"))
        expectAgreement(
            IndependentMacroThreeNodesReversed.self, accepts: [["a": a, "b": b, "c": c]],
            rejects: [["a": a, "b": c, "c": c], ["a": a, "b": b, "c": b], ["a": c, "b": b, "c": c], ["a": b, "b": a, "c": c]])
    }

    @Test func specializationsWithTheSamePrintedNameAreToldApart() {
        let a: JSONValue = ["value": ["number": 1, "next": []], "children": [["value": ["number": 2, "next": [["number": 3, "next": []]]], "children": []]]]
        let b: JSONValue = ["value": ["text": "t", "next": []], "children": [["value": ["text": "u", "next": [["text": "v", "next": []]]], "children": []]]]
        let schema = IndependentMacroTwoTreesOfNodes.jsonSchema
        #expect(
            schema["$defs"]?.objectValue?.map(\.key).sorted()
                == ["IndependentMacroGenericTree_Node_", "IndependentMacroGenericTree_Node__2", "Node", "Node_2"])
        expectAgreement(
            IndependentMacroTwoTreesOfNodes.self, accepts: [["a": a, "b": b]],
            rejects: [
                ["a": b, "b": b], ["a": a, "b": a], ["a": b, "b": a],
                ["a": ["value": ["number": 1, "next": []], "children": [["value": ["text": "u", "next": []], "children": []]]], "b": b],
                ["a": a, "b": ["value": ["text": "t", "next": [["number": 1, "next": []]]], "children": []]],
            ])
    }

    @Test func aGenericRecursiveTypeIsDefinedPerSpecialization() {
        let ints: JSONValue = ["value": 1, "children": [["value": 2, "children": []]]]
        let strings: JSONValue = ["value": "a", "children": [["value": "b", "children": []]]]
        expectAgreement(
            IndependentMacroGenericTree<Int>.self, accepts: [ints], rejects: [strings, ["value": 1, "children": [["value": "b", "children": []]]]])
        expectAgreement(
            IndependentMacroGenericTree<String>.self, accepts: [strings], rejects: [ints, ["value": "a", "children": [["value": 2, "children": []]]]])
        expectAgreement(
            IndependentMacroGenericTree<[Int?]>.self,
            accepts: [["value": [1, nil], "children": [["value": [], "children": []]]]],
            rejects: [["value": [1], "children": [["value": ["x"], "children": []]]]])
        expectAgreement(
            IndependentMacroTwoGenericTrees.self,
            accepts: [["ints": ints, "strings": strings]],
            rejects: [
                ["ints": strings, "strings": strings],
                ["ints": ints, "strings": ints],
                ["ints": ["value": 1, "children": [["value": "b", "children": []]]], "strings": strings],
                ["ints": ints, "strings": ["value": "a", "children": [["value": 2, "children": []]]]],
            ])
        #expect(IndependentMacroTwoGenericTrees.jsonSchema["$defs"]?.objectValue?.count == 2)
        IndependentMacroCheckRoundTrip(
            IndependentMacroTwoGenericTrees(
                ints: .init(value: 1, children: [.init(value: 2, children: [])]), strings: .init(value: "a", children: [])))
    }

    /// Definition names are derived from type names by replacing every character outside
    /// `A–Z a–z 0–9 . -` with `_`. Two types whose names differ only in such characters must
    /// still get definitions of their own.
    @Test func typesWithNamesOutsideASCIIGetTheirOwnDefinitions() {
        let узел: JSONValue = ["число": 1, "дети": [["число": 2, "дети": []]]]
        let лист: JSONValue = ["текст": "t", "дети": [["текст": "u", "дети": []]]]
        expectAgreement(IndependentMacroУзел.self, accepts: [узел], rejects: [лист])
        expectAgreement(IndependentMacroЛист.self, accepts: [лист], rejects: [узел])
        #expect(IndependentMacroCyrillicPair.jsonSchema["$defs"]?.objectValue?.map(\.key) == ["IndependentMacro____", "IndependentMacro_____2"])
        expectAgreement(
            IndependentMacroCyrillicPair.self,
            accepts: [["узел": узел, "лист": лист]],
            rejects: [["узел": узел, "лист": узел], ["узел": лист, "лист": лист]])
        IndependentMacroCheckRoundTrip(
            IndependentMacroCyrillicPair(
                узел: .init(число: 1, дети: [.init(число: 2, дети: [])]), лист: .init(текст: "t", дети: [.init(текст: "u", дети: [])])))
    }

    @Test func definitionNamesOfPrivateTypesAreStable() {
        let schema = IMPrivateTree.jsonSchema
        IndependentMacroCheckSchema(schema)
        let names = schema["$defs"]?.objectValue?.map(\.key) ?? []
        #expect(names == ["IMPrivateTree"])
        for name in names {
            #expect(!name.contains("unknown_context"), "the definition is named after a memory address: \(name)")
        }
        expectAgreement(
            IMPrivateTree.self, accepts: [["value": 1, "children": [["value": 2, "children": []]]]],
            rejects: [["value": 1, "children": [["value": "2", "children": []]]]])
    }
}

// MARK: - Tools

@Suite struct IndependentMacroRecursiveToolTests {
    private func makeServer() throws -> Server {
        try Server(name: "recursive", version: "1") {
            IndependentMacroGraft()
            IndependentMacroCredit()
            IndependentMacroChildren()
            IndependentMacroFirstChild()
            IndependentMacroGrow()
        }
    }

    /// One recursive type used three times as an argument and once as the result: each schema
    /// document carries its own single definition.
    @Test func aRecursiveTypeAsArgumentsAndResult() async throws {
        let definition = IndependentMacroGraft.definition
        let input = definition.inputSchema
        IndependentMacroCheckSchema(input)
        #expect(input["type"] == "object")
        #expect(input["$defs"]?.objectValue?.map(\.key) == [treeName])
        #expect(input["properties"]?["tree"] == ["$ref": .string("#/$defs/" + treeName), "description": "The tree to extend."])
        #expect(input["properties"]?["other"] == ["anyOf": [reference(treeName), ["type": "null"]], "description": "A tree to add as the last child."])
        #expect(input["properties"]?["forest"] == ["type": "array", "items": reference(treeName)])
        #expect(input["required"] == ["tree"])

        let output = try #require(definition.outputSchema)
        IndependentMacroCheckSchema(output)
        #expect(output["type"] == "object")
        #expect(output == IndependentMacroTree.jsonSchema)

        let client = TestClient(try makeServer())
        let listed = try #require(try await client.independentMacroListed("independent_macro_graft"))
        #expect(listed["inputSchema"] == .object(input))
        #expect(listed["outputSchema"] == .object(output))
    }

    @Test func callingWithRecursiveArguments() async throws {
        let client = TestClient(try makeServer())
        let one = tree(1, tree(2, tree(3)))
        let other = tree(4, tree(5))
        let response = try await client.independentMacroCall(
            "independent_macro_graft", ["tree": one.jsonValue, "other": other.jsonValue, "forest": [tree(6).jsonValue]])
        #expect(response["result"]?["isError"] == false, "\(response)")
        #expect(response["result"]?["structuredContent"] == tree(1, tree(2, tree(3)), tree(4, tree(5)), tree(6)).jsonValue)

        // `other` is optional: absent and `null` both mean "none".
        for arguments: JSONValue in [["tree": one.jsonValue], ["tree": one.jsonValue, "other": nil]] {
            let plain = try await client.independentMacroCall("independent_macro_graft", arguments)
            #expect(plain["result"]?["structuredContent"] == one.jsonValue, "\(arguments)")
        }
    }

    @Test func violationsDeepInsideRecursiveArgumentsAreToolErrors() async throws {
        let client = TestClient(try makeServer())
        let bad: [JSONValue] = [
            ["tree": ["value": 1]],
            ["tree": ["value": 1, "children": [["value": 2, "children": [["value": "three", "children": []]]]]]],
            ["tree": ["value": 1, "children": []], "other": ["value": 1, "children": [["children": []]]]],
            ["tree": ["value": 1, "children": []], "forest": [["value": 1, "children": [nil]]]],
            ["tree": nil],
        ]
        for arguments in bad {
            let response = try await client.independentMacroCall("independent_macro_graft", arguments)
            #expect(response["error"] == nil, "\(arguments): \(response)")
            #expect(response["result"]?["isError"] == true, "\(arguments): \(response)")
        }
        // The message says where.
        let deep = try await client.independentMacroCall(
            "independent_macro_graft", ["tree": ["value": 1, "children": [["value": 2, "children": [["value": "three", "children": []]]]]]])
        let text = deep.independentMacroFirstText ?? ""
        #expect(text.contains("tree") && text.contains("children") && text.contains("value"), "\(text)")
    }

    @Test func mutuallyRecursiveArgumentsAndResult() async throws {
        let definition = IndependentMacroCredit.definition
        IndependentMacroCheckSchema(definition.inputSchema)
        // observed: one definition is enough — the type that closes the cycle; the other is
        // written in place wherever it occurs.
        #expect(definition.inputSchema["$defs"]?.objectValue?.isEmpty == false)
        let output = try #require(definition.outputSchema)
        IndependentMacroCheckSchema(output)
        #expect(output["type"] == "object")

        let client = TestClient(try makeServer())
        let book = IndependentMacroBook(title: "t", authors: [], sequels: ["n": IndependentMacroBook(title: "u", authors: [], sequels: nil)])
        let author = IndependentMacroAuthor(name: "a", books: [book])
        let response = try await client.independentMacroCall("independent_macro_credit", ["book": book.jsonValue, "author": author.jsonValue])
        #expect(response["result"]?["isError"] == false, "\(response)")
        #expect(
            response["result"]?["structuredContent"]
                == IndependentMacroBook(title: "t", authors: [author], sequels: book.sequels).jsonValue)
        let bad = try await client.independentMacroCall(
            "independent_macro_credit", ["book": book.jsonValue, "author": ["name": "a", "books": [["title": "x", "authors": [["books": []]]]]]])
        #expect(bad["result"]?["isError"] == true, "\(bad)")
    }

    /// A recursive argument as deep as the data is: 24 levels of tree are about 50 levels of
    /// JSON, well inside what the parser accepts (128) and the decoder decodes.
    @Test(arguments: [4, 8, 11, 12, 13, 16, 24, 61])
    func deepRecursiveArguments(depth: Int) async throws {
        var deep = tree(0)
        for level in 1..<depth { deep = tree(level, deep) }
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("independent_macro_children", ["tree": tree(-1, deep).jsonValue])
        #expect(response["error"] == nil, "depth \(depth): \(response["error"] ?? .null)")
        #expect(response["result"]?["isError"] == false, "depth \(depth): \(response.independentMacroFirstText?.suffix(90) ?? "")")
        if response["result"]?["isError"] == false {
            #expect(response["result"]?["structuredContent"] == [deep.jsonValue])
        }
    }

    /// A tool that is given valid arguments and returns a value of its declared type must get
    /// its answer through (§8.1: for a `@Schema` type conformance to the output schema holds
    /// "по построению"). The server checks the result against the output schema; if the
    /// validator gives up on depth, a correct result is answered with `-32603`.
    @Test(arguments: [4, 8, 12, 14, 16, 24, 40, 63])
    func deepRecursiveResults(depth: Int) async throws {
        let client = TestClient(try makeServer())
        let response = try await client.independentMacroCall("independent_macro_grow", ["depth": .number(JSONNumber(depth))])
        #expect(response["error"] == nil, "depth \(depth): \(response["error"] ?? .null)")
        #expect(response["result"]?["isError"] == false)
        var expected = tree(0)
        for level in 1..<depth { expected = tree(level, expected) }
        #expect(response["result"]?["structuredContent"] == expected.jsonValue)
    }

    @Test(.disabled("known limitation: a result nested hundreds of levels deep overflows the handler's stack in the generated jsonValue"))
    func aVeryDeepResultDoesNotCrashTheServer() async {
        await #expect(processExitsWith: .success) {
            guard let server = try? Server(name: "deep", version: "1", tools: { IndependentMacroGrow() }) else { fatalError("setup") }
            let client = TestClient(server)
            client.post("tools/call", ["name": "independent_macro_grow", "arguments": ["depth": 2000]])
            _ = try? await client.next(timeout: .seconds(20))
        }
    }

    /// Results that are not objects declare no output schema (documented on
    /// `ToolSupport.outputSchema`), recursive or not; they still have to arrive.
    @Test func recursiveResultsThatAreNotObjects() async throws {
        #expect(IndependentMacroChildren.definition.outputSchema == nil)
        #expect(IndependentMacroFirstChild.definition.outputSchema == nil)
        let client = TestClient(try makeServer())
        let children = try await client.independentMacroCall("independent_macro_children", ["tree": tree(1, tree(2), tree(3)).jsonValue])
        #expect(children["result"]?["structuredContent"] == [tree(2).jsonValue, tree(3).jsonValue])
        let first = try await client.independentMacroCall("independent_macro_first_child", ["tree": tree(1, tree(2)).jsonValue])
        #expect(first["result"]?["structuredContent"] == tree(2).jsonValue)
        let none = try await client.independentMacroCall("independent_macro_first_child", ["tree": tree(1).jsonValue])
        #expect(none["error"] == nil, "\(none)")
        #expect(none["result"]?["isError"] == false)
        #expect(none["result"]?["structuredContent"] == .null)
    }

    /// Older revisions get the same `$defs` / `$ref` schemas and the same validation.
    @Test func legacyClientsSeeTheSameSchemas() async throws {
        for version in [ProtocolVersion.v2025_11_25, .v2025_06_18, .v2025_03_26] {
            let client = TestClient(try makeServer(), modern: false)
            try await client.initialize(version: version)
            let listed = try #require(try await client.independentMacroListed("independent_macro_graft"), "\(version)")
            #expect(listed["inputSchema"] == .object(IndependentMacroGraft.definition.inputSchema), "\(version)")
            let good = try await client.independentMacroCall("independent_macro_graft", ["tree": tree(1, tree(2)).jsonValue])
            #expect(good["error"] == nil, "\(version): \(good)")
            let text = try #require(good.independentMacroFirstText, "\(version)")
            #expect(try JSON.parse(Array(text.utf8)) == tree(1, tree(2)).jsonValue, "\(version)")
            let bad = try await client.independentMacroCall("independent_macro_graft", ["tree": ["value": 1, "children": [["value": "x", "children": []]]]])
            if version < .v2025_11_25 {
                #expect(bad["error"]?["code"] == -32602, "\(version): \(bad)")
            } else {
                #expect(bad["result"]?["isError"] == true, "\(version): \(bad)")
            }
        }
    }
}
