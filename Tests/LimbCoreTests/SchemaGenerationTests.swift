import LimbCore
import Testing

// Schema generation without macros: conformances written by hand, the way generated code
// writes them, for types that contain themselves — directly, through each other, and through
// optionals, arrays and dictionaries. What is checked is the document the builder assembles
// (which types become definitions, what they are called, what the root looks like) and that
// every such document compiles and accepts exactly the values the type writes.

// MARK: - Fixtures

/// Contains itself through an array.
private struct Tree: SchemaRepresentable, Equatable {
    var label: String
    var children: [Tree] = []

    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Tree.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("label", String.self, description: nil, hasDefault: false, in: &builder)
            fields.add("children", [Tree].self, description: "Sub-trees.", hasDefault: true, in: &builder)
            return fields.schema(description: "A tree.")
        }
    }

    init(_ label: String, _ children: [Tree] = []) {
        self.label = label
        self.children = children
    }

    init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        label = try SchemaSupport.decode(object, "label")
        children = try SchemaSupport.decode(object, "children", default: [])
    }

    var jsonValue: JSONValue {
        var object = JSONObject()
        SchemaSupport.set(&object, "label", label)
        SchemaSupport.set(&object, "children", children)
        return .object(object)
    }
}

/// Contains itself through an optional: a class, since a struct cannot hold itself directly.
private final class Chain: SchemaRepresentable {
    let value: Int
    let next: Chain?

    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Chain.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("value", Int.self, description: nil, hasDefault: false, in: &builder)
            fields.add("next", Chain?.self, description: nil, hasDefault: false, in: &builder)
            return fields.schema(description: nil)
        }
    }

    init(_ value: Int, _ next: Chain? = nil) {
        self.value = value
        self.next = next
    }

    init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        value = try SchemaSupport.decode(object, "value")
        next = try SchemaSupport.decode(object, "next")
    }

    var jsonValue: JSONValue {
        var object = JSONObject()
        SchemaSupport.set(&object, "value", value)
        SchemaSupport.set(&object, "next", next)
        return .object(object)
    }

    var values: [Int] { [value] + (next?.values ?? []) }
}

/// Contains itself through a dictionary.
private struct Folder: SchemaRepresentable, Equatable {
    var folders: [String: Folder] = [:]
    var files: [String] = []

    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Folder.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("folders", [String: Folder].self, description: nil, hasDefault: false, in: &builder)
            fields.add("files", [String].self, description: nil, hasDefault: false, in: &builder)
            return fields.schema(description: nil)
        }
    }

    init(folders: [String: Folder] = [:], files: [String] = []) {
        self.folders = folders
        self.files = files
    }

    init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        folders = try SchemaSupport.decode(object, "folders")
        files = try SchemaSupport.decode(object, "files")
    }

    var jsonValue: JSONValue {
        var object = JSONObject()
        SchemaSupport.set(&object, "folders", folders)
        SchemaSupport.set(&object, "files", files)
        return .object(object)
    }
}

/// Two types that contain each other.
private struct Author: SchemaRepresentable, Equatable {
    var name: String
    var books: [Book] = []

    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Author.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("name", String.self, description: nil, hasDefault: false, in: &builder)
            fields.add("books", [Book].self, description: nil, hasDefault: false, in: &builder)
            return fields.schema(description: nil)
        }
    }

    init(name: String, books: [Book] = []) {
        self.name = name
        self.books = books
    }

    init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        name = try SchemaSupport.decode(object, "name")
        books = try SchemaSupport.decode(object, "books")
    }

    var jsonValue: JSONValue {
        var object = JSONObject()
        SchemaSupport.set(&object, "name", name)
        SchemaSupport.set(&object, "books", books)
        return .object(object)
    }
}

private struct Book: SchemaRepresentable, Equatable {
    var title: String
    var coauthors: [Author]? = nil

    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Book.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("title", String.self, description: nil, hasDefault: false, in: &builder)
            fields.add("coauthors", [Author]?.self, description: nil, hasDefault: false, in: &builder)
            return fields.schema(description: nil)
        }
    }

    init(title: String, coauthors: [Author]? = nil) {
        self.title = title
        self.coauthors = coauthors
    }

    init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        title = try SchemaSupport.decode(object, "title")
        coauthors = try SchemaSupport.decode(object, "coauthors")
    }

    var jsonValue: JSONValue {
        var object = JSONObject()
        SchemaSupport.set(&object, "title", title)
        SchemaSupport.set(&object, "coauthors", coauthors)
        return .object(object)
    }
}

/// Does not contain itself, but holds types that do — one of them twice.
private struct Library: SchemaRepresentable, Equatable {
    var index: Tree
    var appendix: Tree?
    var shelves: [String: [Tree]] = [:]
    var root: Folder
    var count: Int = 0

    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Library.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("index", Tree.self, description: "The main tree.", hasDefault: false, in: &builder)
            fields.add("appendix", Tree?.self, description: nil, hasDefault: false, in: &builder)
            fields.add("shelves", [String: [Tree]].self, description: nil, hasDefault: true, in: &builder)
            fields.add("root", Folder.self, description: nil, hasDefault: false, in: &builder)
            fields.add("count", \Library.count, description: nil, hasDefault: true, in: &builder)
            return fields.schema(description: nil)
        }
    }

    init(index: Tree, appendix: Tree? = nil, shelves: [String: [Tree]] = [:], root: Folder = Folder(), count: Int = 0) {
        self.index = index
        self.appendix = appendix
        self.shelves = shelves
        self.root = root
        self.count = count
    }

    init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        index = try SchemaSupport.decode(object, "index")
        appendix = try SchemaSupport.decode(object, "appendix")
        shelves = try SchemaSupport.decode(object, "shelves", default: [:])
        root = try SchemaSupport.decode(object, "root")
        if let count = try SchemaSupport.decodeIfPresent(object, "count", for: \Library.count) { self.count = count }
    }

    var jsonValue: JSONValue {
        var object = JSONObject()
        SchemaSupport.set(&object, "index", index)
        SchemaSupport.set(&object, "appendix", appendix)
        SchemaSupport.set(&object, "shelves", shelves)
        SchemaSupport.set(&object, "root", root)
        SchemaSupport.set(&object, "count", count)
        return .object(object)
    }
}

/// Types that share a name: told apart by identity, numbered in the document.
private enum First {
    struct Item: SchemaRepresentable {
        var parts: [Item]
        static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
            builder.named(Item.self) { builder in ["type": "object", "properties": ["parts": .object([Item].jsonSchema(in: &builder))], "required": ["parts"]] }
        }
        init(json: JSONValue) throws(JSONDecodingError) { parts = try JSONObject(json: json).required("parts") }
        var jsonValue: JSONValue { ["parts": .array(parts.map(\.jsonValue))] }
    }
}

private enum Second {
    struct Item: SchemaRepresentable {
        var inner: [String: Item]
        static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
            builder.named(Item.self) { builder in ["type": "object", "properties": ["inner": .object([String: Item].jsonSchema(in: &builder))], "required": ["inner"]] }
        }
        init(json: JSONValue) throws(JSONDecodingError) { inner = try JSONObject(json: json).required("inner") }
        var jsonValue: JSONValue { ["inner": .object(JSONObject(inner.keys.sorted().map { ($0, inner[$0]!.jsonValue) }))] }
    }
}

/// A type whose own name is the one the builder would give the second `Item`.
private struct Item_2: SchemaRepresentable {
    var again: [Item_2]
    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Item_2.self) { builder in ["type": "object", "properties": ["again": .object([Item_2].jsonSchema(in: &builder))]] }
    }
    init(json: JSONValue) throws(JSONDecodingError) { again = try JSONObject(json: json).optional("again") ?? [] }
    var jsonValue: JSONValue { ["again": .array(again.map(\.jsonValue))] }
}

/// A generic type: each instantiation is a type of its own, with a name that needs cleaning.
private struct Nest<Payload: SchemaRepresentable>: SchemaRepresentable {
    var payload: Payload
    var more: [Nest<Payload>]
    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Nest<Payload>.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("payload", Payload.self, description: nil, hasDefault: false, in: &builder)
            fields.add("more", [Nest<Payload>].self, description: nil, hasDefault: false, in: &builder)
            return fields.schema(description: nil)
        }
    }
    init(json: JSONValue) throws(JSONDecodingError) {
        let object = try JSONObject(json: json)
        payload = try SchemaSupport.decode(object, "payload")
        more = try SchemaSupport.decode(object, "more")
    }
    var jsonValue: JSONValue { ["payload": payload.jsonValue, "more": .array(more.map(\.jsonValue))] }
}

/// Holds every one of the above, so that all of them meet in one document.
private struct Everything: SchemaRepresentable {
    static func jsonSchema(in builder: inout SchemaBuilder) -> JSONObject {
        builder.named(Everything.self) { builder in
            var fields = SchemaSupport.Fields()
            fields.add("a", First.Item.self, description: nil, hasDefault: false, in: &builder)
            fields.add("b", Second.Item.self, description: nil, hasDefault: false, in: &builder)
            fields.add("c", Item_2.self, description: nil, hasDefault: false, in: &builder)
            fields.add("d", Nest<Int>.self, description: nil, hasDefault: false, in: &builder)
            fields.add("e", Nest<[String: Bool?]>.self, description: nil, hasDefault: false, in: &builder)
            fields.add("f", [First.Item].self, description: nil, hasDefault: false, in: &builder)
            return fields.schema(description: nil)
        }
    }
    init(json: JSONValue) throws(JSONDecodingError) {}
    var jsonValue: JSONValue { [:] }
}

/// Every `$ref` in a document, wherever it is.
private func references(in value: JSONValue) -> [String] {
    switch value {
    case .array(let items): return items.flatMap(references)
    case .object(let object):
        return object.flatMap { member -> [String] in
            if member.key == "$ref", let target = member.value.stringValue { return [target] }
            return references(in: member.value)
        }
    default: return []
    }
}

private func compiled<T: SchemaRepresentable>(_ type: T.Type) throws -> JSONSchema {
    try JSONSchema(.object(T.jsonSchema))
}

// MARK: - Tests

@Suite struct SchemaGenerationTests {
    static let treeBody: JSONValue = [
        "type": "object", "description": "A tree.",
        "properties": ["label": ["type": "string"], "children": ["type": "array", "items": ["$ref": "#/$defs/Tree"], "description": "Sub-trees."]],
        "required": ["label"],
    ]

    @Test func aTypeThatContainsItselfBecomesADefinition() throws {
        // As a part of something larger it is a reference …
        var builder = SchemaBuilder()
        let part = Tree.jsonSchema(in: &builder)
        #expect(JSONValue.object(part) == ["$ref": "#/$defs/Tree"])
        // … and as a document of its own the root says what it is, with the definition beside it.
        var expected = try #require(Self.treeBody.objectValue)
        expected["$defs"] = ["Tree": Self.treeBody]
        #expect(JSONValue.object(Tree.jsonSchema) == .object(expected))
        #expect(Tree.jsonSchema["type"] == "object")
        #expect(Tree.jsonSchema["$ref"] == nil)
        // The same document every time it is asked for.
        #expect(JSONValue.object(Tree.jsonSchema).description == JSONValue.object(Tree.jsonSchema).description)
        // Asked for twice in one builder, it is defined once and referred to twice.
        let again = Tree.jsonSchema(in: &builder)
        #expect(part == again)
        #expect(builder.finish(["type": "array", "items": .object(again)])["$defs"]?.objectValue?.count == 1)
    }

    @Test func throughAnOptionalADictionaryAndEachOther() throws {
        // Optional: the member may be the type or null, and need not be there.
        let chain = JSONValue.object(Chain.jsonSchema)
        #expect(chain["properties"]?["next"] == ["anyOf": [["$ref": "#/$defs/Chain"], ["type": "null"]]])
        #expect(chain["required"] == ["value"])
        #expect(chain["$defs"]?.objectValue?.map(\.key) == ["Chain"])
        // Dictionary.
        let folder = JSONValue.object(Folder.jsonSchema)
        #expect(folder["properties"]?["folders"] == ["type": "object", "additionalProperties": ["$ref": "#/$defs/Folder"]])
        #expect(folder["$defs"]?.objectValue?.map(\.key) == ["Folder"])
        // Each other: whichever is the root is the definition; the other is written inside it.
        let author = JSONValue.object(Author.jsonSchema)
        #expect(author["$defs"]?.objectValue?.map(\.key) == ["Author"])
        #expect(author["properties"]?["books"]?["items"]?["properties"]?["coauthors"] == ["anyOf": [["type": "array", "items": ["$ref": "#/$defs/Author"]], ["type": "null"]]])
        #expect(author["properties"]?["books"]?["items"]?["required"] == ["title"])
        let book = JSONValue.object(Book.jsonSchema)
        #expect(book["$defs"]?.objectValue?.map(\.key) == ["Book"])
        #expect(book["properties"]?["coauthors"]?["anyOf"]?[0]?["items"]?["properties"]?["books"] == ["type": "array", "items": ["$ref": "#/$defs/Book"]])
        // In one builder, asked in either order, both end up consistent: every reference has a definition.
        for order in [[0, 1], [1, 0]] {
            var builder = SchemaBuilder()
            var parts: [JSONValue] = []
            for index in order { parts.append(.object(index == 0 ? Author.jsonSchema(in: &builder) : Book.jsonSchema(in: &builder))) }
            let document = JSONValue.object(builder.finish(["prefixItems": .array(parts)]))
            let defined = Set(document["$defs"]?.objectValue?.map { "#/$defs/" + $0.key } ?? [])
            #expect(Set(references(in: document)).isSubset(of: defined), "order \(order)")
            #expect(throws: Never.self) { try JSONSchema(document) }
        }
    }

    @Test func containerRootsKeepTheirShape() throws {
        #expect(JSONValue.object([Tree].jsonSchema) == ["type": "array", "items": ["$ref": "#/$defs/Tree"], "$defs": ["Tree": Self.treeBody]])
        #expect(JSONValue.object(Tree?.jsonSchema) == ["anyOf": [["$ref": "#/$defs/Tree"], ["type": "null"]], "$defs": ["Tree": Self.treeBody]])
        #expect(
            JSONValue.object([String: Tree?].jsonSchema)
                == ["type": "object", "additionalProperties": ["anyOf": [["$ref": "#/$defs/Tree"], ["type": "null"]]], "$defs": ["Tree": Self.treeBody]])
        // Types that do not contain themselves need no definitions at all.
        #expect(JSONValue.object([Int?].jsonSchema) == ["type": "array", "items": ["anyOf": [["type": "integer"], ["type": "null"]]]])
        #expect(JSONValue.object(Int??.jsonSchema) == ["anyOf": [["anyOf": [["type": "integer"], ["type": "null"]]], ["type": "null"]]])
        #expect(JSONValue.object([String: [Double]].jsonSchema) == ["type": "object", "additionalProperties": ["type": "array", "items": ["type": "number"]]])
        #expect(JSONValue.object(String.jsonSchema) == ["type": "string"])
        #expect(JSONValue.object(Bool.jsonSchema) == ["type": "boolean"])
        #expect(JSONValue.object(Int64.jsonSchema) == ["type": "integer"])
        #expect(JSONValue.object(JSONValue.jsonSchema) == [:])
    }

    @Test func aTypeThatOnlyHoldsRecursiveTypesStaysInPlace() throws {
        let library = JSONValue.object(Library.jsonSchema)
        // Itself written at the root; the two it holds defined once each, however often used.
        #expect(library["type"] == "object")
        #expect(library["$defs"]?.objectValue?.map(\.key) == ["Tree", "Folder"])
        #expect(library["$defs"]?["Tree"] == Self.treeBody)
        #expect(library["properties"]?["index"] == ["$ref": "#/$defs/Tree", "description": "The main tree."])
        #expect(library["properties"]?["appendix"] == ["anyOf": [["$ref": "#/$defs/Tree"], ["type": "null"]]])
        #expect(library["properties"]?["shelves"] == ["type": "object", "additionalProperties": ["type": "array", "items": ["$ref": "#/$defs/Tree"]]])
        #expect(library["properties"]?["root"] == ["$ref": "#/$defs/Folder"])
        #expect(library["properties"]?["count"] == ["type": "integer"])
        // Required: no default and not optional.
        #expect(library["required"] == ["index", "root"])
        #expect(library["properties"]?.objectValue?.map(\.key) == ["index", "appendix", "shelves", "root", "count"])
    }

    @Test func definitionsAreNamedAndNumbered() throws {
        let document = JSONValue.object(Everything.jsonSchema)
        let names = try #require(document["$defs"]?.objectValue?.map(\.key))
        // In the order they were first met; a name taken is numbered, a number taken is numbered again.
        #expect(names == ["Item", "Item_2", "Item_2_2", "Nest_Int_", "Nest_Dictionary_String__Optional_Bool___"])
        #expect(document["properties"]?["a"] == ["$ref": "#/$defs/Item"])
        #expect(document["properties"]?["b"] == ["$ref": "#/$defs/Item_2"])
        #expect(document["properties"]?["c"] == ["$ref": "#/$defs/Item_2_2"])
        #expect(document["properties"]?["d"] == ["$ref": "#/$defs/Nest_Int_"])
        #expect(document["properties"]?["f"] == ["type": "array", "items": ["$ref": "#/$defs/Item"]])
        // Each definition refers to itself, not to its namesake.
        #expect(references(in: document["$defs"]?["Item"] ?? .null) == ["#/$defs/Item"])
        #expect(references(in: document["$defs"]?["Item_2"] ?? .null) == ["#/$defs/Item_2"])
        #expect(references(in: document["$defs"]?["Item_2_2"] ?? .null) == ["#/$defs/Item_2_2"])
        #expect(document["$defs"]?["Item"]?["properties"]?["parts"] != nil)
        #expect(document["$defs"]?["Item_2"]?["properties"]?["inner"] != nil)
        #expect(document["$defs"]?["Item_2_2"]?["properties"]?["again"] != nil)
        // Names need no escaping in a JSON pointer or a URI fragment.
        for name in names {
            #expect(name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "._-".unicodeScalars.contains($0)) }, "\(name)")
        }
        // Every reference has a definition, and the whole compiles.
        #expect(Set(references(in: document)) == Set(names.map { "#/$defs/" + $0 }))
        #expect(throws: Never.self) { try JSONSchema(document) }
        // The numbering follows the order of first use, and is the same on every run of it.
        #expect(JSONValue.object(Everything.jsonSchema).description == document.description)
        #expect(JSONValue.object(Second.Item.jsonSchema)["$defs"]?.objectValue?.map(\.key) == ["Item"])
        var builder = SchemaBuilder()
        _ = Item_2.jsonSchema(in: &builder)
        _ = Second.Item.jsonSchema(in: &builder)
        _ = First.Item.jsonSchema(in: &builder)
        #expect(builder.finish(["type": "null"])["$defs"]?.objectValue?.map(\.key) == ["Item_2", "Item", "Item_3"])
    }

    @Test func finishingADocument() throws {
        var builder = SchemaBuilder()
        // Nothing defined: the schema comes back as it is.
        #expect(builder.finish(["type": "string"]) == ["type": "string"])
        #expect(builder.finish(["$ref": "#/$defs/Nothing"]) == ["$ref": "#/$defs/Nothing"])
        #expect(builder.finish([:]) == [:])
        let reference = Tree.jsonSchema(in: &builder)
        // A root that is nothing but a reference is replaced by what it refers to.
        let finished = JSONValue.object(builder.finish(reference))
        #expect(finished["$ref"] == nil)
        #expect(finished["type"] == "object")
        #expect(finished["$defs"] == ["Tree": Self.treeBody])
        // A root that says more than the reference keeps the reference.
        let described = JSONValue.object(builder.finish(["$ref": "#/$defs/Tree", "description": "The whole tree."]))
        #expect(described == ["$ref": "#/$defs/Tree", "description": "The whole tree.", "$defs": ["Tree": Self.treeBody]])
        #expect(throws: Never.self) { try JSONSchema(described) }
        // A reference to something this builder never defined is left alone.
        let foreign = JSONValue.object(builder.finish(["$ref": "#/$defs/Elsewhere"]))
        #expect(foreign == ["$ref": "#/$defs/Elsewhere", "$defs": ["Tree": Self.treeBody]])
        // Finishing does not use the builder up.
        #expect(JSONValue.object(builder.finish(reference)) == finished)
    }

    @Test func everyDocumentCompilesAndTellsRightFromWrong() throws {
        // Tree.
        let tree = try compiled(Tree.self)
        let sample = Tree("root", [Tree("a", [Tree("a1"), Tree("a2", [Tree("deep")])]), Tree("b")])
        #expect(tree.validate(sample.jsonValue) == nil)
        #expect(try Tree(json: sample.jsonValue) == sample)
        #expect(try Tree(json: ["label": "alone"]) == Tree("alone"))
        #expect(tree.validate(["label": "alone"]) == nil)
        #expect(tree.validate(["children": []])?.description == "label: missing required field")
        #expect(tree.validate(["label": "r", "children": [["label": "a", "children": [["label": 5]]]]])?.description == "children.[0].children.[0].label: expected string, got integer")
        #expect(tree.validate(["label": "r", "children": [["children": []]]])?.description == "children.[0].label: missing required field")
        #expect(tree.validate(["label": "r", "children": "none"]) != nil)
        #expect(tree.validate([sample.jsonValue]) != nil)
        // In containers.
        #expect(try compiled([Tree].self).validate([sample.jsonValue, Tree("x").jsonValue]) == nil)
        #expect(try compiled([Tree].self).validate([sample.jsonValue, ["children": []]])?.description == "[1].label: missing required field")
        #expect(try compiled(Tree?.self).validate(.null) == nil)
        #expect(try compiled(Tree?.self).validate(sample.jsonValue) == nil)
        #expect(try compiled(Tree?.self).validate(["label": 1]) != nil)
        #expect(try compiled([String: Tree?].self).validate(["a": sample.jsonValue, "b": nil]) == nil)
        #expect(try compiled([String: Tree?].self).validate(["a": ["label": []]]) != nil)

        // Chain.
        let chain = try compiled(Chain.self)
        let links = Chain(1, Chain(2, Chain(3)))
        #expect(links.jsonValue == ["value": 1, "next": ["value": 2, "next": ["value": 3]]])
        #expect(chain.validate(links.jsonValue) == nil)
        #expect(try Chain(json: links.jsonValue).values == [1, 2, 3])
        #expect(chain.validate(["value": 1, "next": nil]) == nil)
        #expect(try Chain(json: ["value": 1, "next": nil]).values == [1])
        #expect(chain.validate(["value": 1, "next": ["value": 2, "next": ["value": "three"]]]) != nil)
        #expect(chain.validate(["next": nil]) != nil)
        #expect(chain.validate(["value": 1.5]) != nil)

        // Folder.
        let folder = try compiled(Folder.self)
        let disk = Folder(folders: ["etc": Folder(files: ["hosts"]), "usr": Folder(folders: ["bin": Folder(files: ["swift", "sh"])])], files: ["README"])
        #expect(folder.validate(disk.jsonValue) == nil)
        #expect(try Folder(json: disk.jsonValue) == disk)
        #expect(folder.validate(["folders": ["x": ["folders": [:], "files": [1]]], "files": []])?.description == "folders.x.files.[0]: expected string, got integer")
        #expect(folder.validate(["folders": ["x": "not a folder"], "files": []]) != nil)
        #expect(folder.validate(["files": []]) != nil)

        // Author and Book, each as the root.
        let rowling = Author(name: "A", books: [Book(title: "One"), Book(title: "Two", coauthors: [Author(name: "B", books: [Book(title: "Solo")])])])
        #expect(try compiled(Author.self).validate(rowling.jsonValue) == nil)
        #expect(try Author(json: rowling.jsonValue) == rowling)
        #expect(try compiled(Book.self).validate(rowling.books[1].jsonValue) == nil)
        #expect(try compiled(Author.self).validate(["name": "A", "books": [["title": "T", "coauthors": [["name": "B", "books": [["coauthors": nil]]]]]]])?.description
            == "books.[0].coauthors: does not match any of the allowed alternatives")
        #expect(try compiled(Book.self).validate(["title": "T", "coauthors": [["name": "B"]]])?.description != nil)

        // Library: what holds them.
        let library = try compiled(Library.self)
        let stocked = Library(index: sample, appendix: Tree("extra"), shelves: ["north": [Tree("n1"), Tree("n2")]], root: disk, count: 3)
        #expect(library.validate(stocked.jsonValue) == nil)
        #expect(try Library(json: stocked.jsonValue) == stocked)
        let bare = Library(index: Tree("only"))
        #expect(library.validate(bare.jsonValue) == nil)
        #expect(bare.jsonValue.objectValue?.map(\.key) == ["index", "shelves", "root", "count"])
        #expect(try Library(json: ["index": ["label": "only"], "root": ["folders": [:], "files": []]]) == bare)
        #expect(library.validate(["index": ["label": "only"], "root": ["folders": [:], "files": []]]) == nil)
        #expect(library.validate(["index": ["label": "only"], "root": ["folders": [:], "files": []], "shelves": ["s": [["label": 1]]]])?.description == "shelves.s.[0].label: expected string, got integer")
        #expect(library.validate(["index": ["label": "only"]])?.description == "root: missing required field")
        #expect(library.validate(["index": ["label": "only"], "root": ["folders": [:], "files": []], "appendix": 5]) != nil)

        // The rest only has to compile and take what its types write.
        #expect(try compiled(Nest<Int>.self).validate(["payload": 1, "more": [["payload": 2, "more": []]]]) == nil)
        #expect(try compiled(Nest<Int>.self).validate(["payload": 1, "more": [["payload": "two", "more": []]]]) != nil)
        #expect(try compiled(Nest<[String: Bool?]>.self).validate(["payload": ["a": true, "b": nil], "more": []]) == nil)
        #expect(try compiled(First.Item.self).validate(["parts": [["parts": []]]]) == nil)
        #expect(try compiled(Second.Item.self).validate(["inner": ["k": ["inner": [:]]]]) == nil)
        #expect(try compiled(Second.Item.self).validate(["inner": ["k": ["parts": []]]]) != nil)
    }

    /// A value much deeper than a handler's stack allows in one go: generated schemas refer to
    /// themselves, so this is where the validator's retry on a large stack earns its keep.
    @Test func aDeepValueOfARecursiveType() throws {
        var deep = Tree("leaf")
        for level in 0..<100 { deep = Tree("level \(level)", [Tree("side"), deep]) }
        let schema = try compiled(Tree.self)
        #expect(schema.validate(deep.jsonValue) == nil)
        #expect(try Tree(json: deep.jsonValue) == deep)
        var spoiled: JSONValue = ["label": 7]
        for _ in 0..<100 { spoiled = ["label": "x", "children": [["label": "side"], spoiled]] }
        let violation = try #require(schema.validate(spoiled))
        #expect(violation.reason == "expected string, got integer")
        #expect(violation.path.count == 201)
        #expect(violation.path.suffix(3) == ["children", "[1]", "label"])
    }

    @Test func optionalsNullAndAbsence() throws {
        // The schema of an optional is the type or null.
        #expect(JSONValue.object(Int?.jsonSchema) == ["anyOf": [["type": "integer"], ["type": "null"]]])
        let optional = try compiled(Int?.self)
        #expect(optional.validate(1) == nil)
        #expect(optional.validate(.null) == nil)
        #expect(optional.validate("x") != nil)
        #expect(try compiled([Int?].self).validate([1, nil, 2]) == nil)
        #expect(try compiled([Int?].self).validate([1, "x"]) != nil)
        // What an optional writes, wherever a value has to be written.
        #expect(Int?.none.jsonValue == .null)
        #expect(Int?.some(3).jsonValue == 3)
        #expect([Int?]([1, nil, 3]).jsonValue == [1, nil, 3])
        #expect((["a": 1, "b": nil] as [String: Int?]).jsonValue == ["a": 1, "b": nil])
        #expect(try [Int?](json: [1, nil, 3]) == [1, nil, 3])
        // As a member: absent when nil, and nil when absent or null.
        var object = JSONObject()
        SchemaSupport.set(&object, "present", Int?.some(1))
        SchemaSupport.set(&object, "absent", Int?.none)
        SchemaSupport.set(&object, "plain", "text")
        SchemaSupport.set(&object, "list", [Int?]([nil]))
        SchemaSupport.set(&object, "inner nil", Int??.some(nil))
        SchemaSupport.set(&object, "outer nil", Int??.none)
        #expect(JSONValue.object(object) == ["present": 1, "plain": "text", "list": [nil], "inner nil": nil])
        #expect(object.map(\.key) == ["present", "plain", "list", "inner nil"])
        let absent: Int? = try SchemaSupport.decode(object, "absent")
        let present: Int? = try SchemaSupport.decode(object, "present")
        let null: Int? = try SchemaSupport.decode(["k": nil], "k")
        #expect(absent == nil && present == 1 && null == nil)
        let nested: [String]?? = try SchemaSupport.decode([:], "k")
        #expect(nested == nil)
    }

    @Test func decodingMembers() throws {
        let object: JSONObject = ["name": "n", "count": 3, "ratio": 1.5, "flag": true, "tags": ["a", "b"], "null": nil, "big": 1e300, "nested": ["list": [1, "two"]]]
        // Required.
        #expect(try SchemaSupport.decode(object, "name") as String == "n")
        #expect(try SchemaSupport.decode(object, "count") as Int == 3)
        #expect(try SchemaSupport.decode(object, "count") as Double == 3)
        #expect(try SchemaSupport.decode(object, "tags") as [String] == ["a", "b"])
        #expect(try SchemaSupport.decode(object, "nested") as JSONValue == ["list": [1, "two"]])
        func failure<T: JSONDecodable>(_ key: String, as type: T.Type) -> String? {
            do {
                let _: T = try SchemaSupport.decode(object, key)
                return nil
            } catch {
                return error.description
            }
        }
        #expect(failure("missing", as: String.self) == "missing: missing required field")
        #expect(failure("null", as: String.self) == "null: expected string, got null")
        #expect(failure("name", as: Int.self) == "name: expected integer, got string")
        #expect(failure("ratio", as: Int.self) == "ratio: expected integer, got number")
        #expect(failure("big", as: Int.self) == "big: integer is out of range: it must fit in 64 bits")
        #expect(failure("tags", as: [Int].self) == "tags.[0]: expected integer, got string")
        #expect(failure("nested", as: [String: [Int]].self) == "nested.list.[1]: expected integer, got string")
        #expect(failure("count", as: Bool.self) == "count: expected boolean, got integer")
        // With a default: absent and null both yield it; a wrong type is still an error.
        #expect(try SchemaSupport.decode(object, "missing", default: 7) == 7)
        #expect(try SchemaSupport.decode(object, "null", default: 7) == 7)
        #expect(try SchemaSupport.decode(object, "count", default: 7) == 3)
        #expect(try SchemaSupport.decode(object, "missing", default: ["x"]) == ["x"])
        #expect(throws: JSONDecodingError("expected integer, got string", path: ["name"])) { try SchemaSupport.decode(object, "name", default: 7) }
        // The default is not evaluated when it is not needed.
        var evaluated = 0
        func counted() -> Int {
            evaluated += 1
            return 9
        }
        #expect(try SchemaSupport.decode(object, "count", default: counted()) == 3)
        #expect(evaluated == 0)
        #expect(try SchemaSupport.decode(object, "missing", default: counted()) == 9)
        #expect(evaluated == 1)
        // If present.
        #expect(try SchemaSupport.decodeIfPresent(object, "count", for: \Library.count) == 3)
        #expect(try SchemaSupport.decodeIfPresent(object, "missing", for: \Library.count) == nil)
        #expect(try SchemaSupport.decodeIfPresent(object, "null", for: \Library.count) == nil)
        #expect(throws: JSONDecodingError("expected integer, got string", path: ["name"])) {
            try SchemaSupport.decodeIfPresent(object, "name", for: \Library.count)
        }
    }

    @Test func fieldsOfAnObjectSchema() {
        var builder = SchemaBuilder()
        var fields = SchemaSupport.Fields()
        #expect(JSONValue.object(fields.schema(description: nil)) == ["type": "object", "properties": [:], "required": []])
        fields.add("required", String.self, description: "Must be there.", hasDefault: false, in: &builder)
        fields.add("defaulted", Int.self, description: nil, hasDefault: true, in: &builder)
        fields.add("optional", Bool?.self, description: "May be missing.", hasDefault: false, in: &builder)
        fields.add("optional with a default", Double?.self, description: nil, hasDefault: true, in: &builder)
        fields.add("list", [String?].self, description: nil, hasDefault: false, in: &builder)
        fields.add("by key path", \Library.count, description: "Spelled by its key path.", hasDefault: false, in: &builder)
        fields.add("anything", JSONValue.self, description: nil, hasDefault: false, in: &builder)
        let schema = JSONValue.object(fields.schema(description: "All kinds of members."))
        #expect(
            schema == [
                "type": "object", "description": "All kinds of members.",
                "properties": [
                    "required": ["type": "string", "description": "Must be there."],
                    "defaulted": ["type": "integer"],
                    "optional": ["anyOf": [["type": "boolean"], ["type": "null"]], "description": "May be missing."],
                    "optional with a default": ["anyOf": [["type": "number"], ["type": "null"]]],
                    "list": ["type": "array", "items": ["anyOf": [["type": "string"], ["type": "null"]]]],
                    "by key path": ["type": "integer", "description": "Spelled by its key path."],
                    "anything": [:],
                ],
                "required": ["required", "list", "by key path", "anything"],
            ])
        // Members and the order of keys are those of the declaration.
        #expect(schema.objectValue?.map(\.key) == ["type", "description", "properties", "required"])
        #expect(schema["properties"]?.objectValue?.map(\.key) == ["required", "defaulted", "optional", "optional with a default", "list", "by key path", "anything"])
    }

    @Test func integersOutOfRange() throws {
        func failure<T: JSONDecodable>(_ text: String, as type: T.Type) -> String? {
            do {
                _ = try T(json: JSON.parse(text))
                return nil
            } catch let error as JSONDecodingError {
                return error.description
            } catch {
                return "parse error: \(error)"
            }
        }
        let outOfRange = "integer is out of range: it must fit in 64 bits"
        // Integers that fit.
        #expect(try Int(json: JSON.parse("9223372036854775807")) == .max)
        #expect(try Int64(json: JSON.parse("-9223372036854775808")) == .min)
        #expect(try Int(json: JSON.parse("1.0")) == 1)
        #expect(try Int(json: JSON.parse("1e2")) == 100)
        #expect(try Int(json: JSON.parse("-0")) == 0)
        #expect(try Int64(json: JSON.parse("-0.0")) == 0)
        let tooLarge = [
            "9223372036854775808", "18446744073709551615", "18446744073709551616", "1e19", "-1e19", "1e300", "123456789012345678901234567890",
            "-9223372036854777856", "-9223372036854775809", "-9223372036854776000",
        ]
        for text in tooLarge {
            #expect(failure(text, as: Int.self) == outOfRange, "\(text)")
            #expect(failure(text, as: Int64.self) == outOfRange, "\(text)")
            #expect(failure("[\(text)]", as: [Int].self) == "[0]: " + outOfRange, "\(text)")
            #expect(failure("{\"n\":\(text)}", as: [String: Int64].self) == "n: " + outOfRange, "\(text)")
            #expect(failure(text, as: Int?.self) == outOfRange, "\(text)")
        }
        // Not integers at all.
        for text in ["1.5", "-0.5", "1e-1", "0.1"] {
            #expect(failure(text, as: Int.self) == "expected integer, got number", "\(text)")
            #expect(failure(text, as: Int64.self) == "expected integer, got number", "\(text)")
        }
        #expect(failure("\"1\"", as: Int.self) == "expected integer, got string")
        #expect(failure("true", as: Int.self) == "expected integer, got boolean")
        #expect(failure("null", as: Int.self) == "expected integer, got null")
        #expect(failure("[1]", as: Int64.self) == "expected integer, got array")
        // A double has its own range.
        #expect(try Double(json: JSON.parse("1e300")) == 1e300)
        #expect(try Double(json: JSON.parse("18446744073709551616")) == 18446744073709551616.0)
        // The schema validator and the decoder agree on what an integer is.
        let integer = try JSONSchema(["type": "integer"])
        #expect(integer.validate(try JSON.parse("9223372036854775808")) == nil)
        #expect(integer.validate(try JSON.parse("1.0")) == nil)
        #expect(integer.validate(try JSON.parse("1.5"))?.reason == "expected integer, got number")
    }
}
