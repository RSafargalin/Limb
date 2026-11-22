import SwiftSyntax
import SwiftSyntaxMacros

/// `@Schema`: derives `SchemaRepresentable` for a struct of schema-representable properties or
/// for an enum with string raw values.
///
/// The generated code never spells a property's type: it names properties by key path and lets
/// the compiler infer the rest. An extension does not see the names its type is nested among,
/// so a spelled-out sibling type would not resolve; and what is optional or required is decided
/// by the real type, which also holds for type aliases the macro cannot see through.
public struct SchemaMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Already conforming (the user wrote `: SchemaRepresentable`): add members, not a second conformance.
        let conformance = protocols.isEmpty ? "" : ": LimbCore.SchemaRepresentable"
        if let structure = declaration.as(StructDeclSyntax.self) {
            return [try expand(structure: structure, type: type, conformance: conformance)]
        }
        if let enumeration = declaration.as(EnumDeclSyntax.self) {
            return [try expand(enumeration: enumeration, type: type, conformance: conformance)]
        }
        throw failure("@Schema can be applied to a struct or to an enum with String raw values", at: introducer(of: declaration))
    }

    struct Property {
        /// The name as written in source, with backticks if it has them.
        var reference: String
        /// The JSON member name.
        var key: String
        var description: String?
        var hasDefault: Bool
    }

    static func properties(of structure: StructDeclSyntax) throws -> [Property] {
        var result: [Property] = []
        for member in structure.memberBlock.members {
            if let conditional = member.decl.as(IfConfigDeclSyntax.self),
                containsMember(conditional, where: { isStoredInstanceProperty($0) })
            {
                throw failure(
                    "@Schema does not support stored properties inside '#if': the schema, the decoder and the encoder would leave them out",
                    at: conditional.clauses.first!.poundKeyword)
            }
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isStatic = variable.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if isStatic { continue }
            if let lazy = variable.modifiers.first(where: { $0.name.tokenKind == .keyword(.lazy) }) {
                throw failure("@Schema does not support lazy properties: a lazy property is not part of the value's data", at: lazy)
            }
            let isConstant = variable.bindingSpecifier.tokenKind == .keyword(.let)
            let documentation = Documentation(variable.leadingTrivia)
            for (index, binding) in variable.bindings.enumerated() {
                if isComputed(binding) { continue }
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
                    throw failure("@Schema supports only simple property declarations, one name per binding", at: binding.pattern)
                }
                let hasDefault = binding.initializer != nil
                if isConstant && hasDefault { continue }  // a constant, not part of the data
                // `var a, b: Int` gives both the type written after the last name.
                let annotated = variable.bindings.dropFirst(index).first { $0.typeAnnotation != nil }
                guard let type = annotated?.typeAnnotation?.type else {
                    throw failure("@Schema needs an explicit type for property '\(identifier.text)'", at: binding)
                }
                if type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
                    throw failure("@Schema does not support implicitly unwrapped optionals: write '?' instead of '!'", at: type)
                }
                result.append(
                    Property(
                        reference: identifier.text, key: identifier.text.withoutBackticks,
                        description: documentation.summary, hasDefault: hasDefault))
            }
        }
        return result
    }

    /// Whether a declaration under any branch of `conditional`, however nested, satisfies `test`.
    ///
    /// The macro sees every branch and cannot know which one the build compiles, so members
    /// under `#if` cannot be described faithfully; they are refused rather than left out.
    static func containsMember(_ conditional: IfConfigDeclSyntax, where test: (DeclSyntax) -> Bool) -> Bool {
        conditional.clauses.contains { clause in
            guard case .decls(let members) = clause.elements else { return false }
            return members.contains { member in
                if let nested = member.decl.as(IfConfigDeclSyntax.self) { return containsMember(nested, where: test) }
                return test(member.decl)
            }
        }
    }

    /// Whether the declaration has a property that would be part of the schema: a stored
    /// instance property, but not a constant with an initializer, which `properties(of:)` leaves
    /// out wherever it is.
    static func isStoredInstanceProperty(_ declaration: DeclSyntax) -> Bool {
        guard let variable = declaration.as(VariableDeclSyntax.self) else { return false }
        let isStatic = variable.modifiers.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
        let isConstant = variable.bindingSpecifier.tokenKind == .keyword(.let)
        return !isStatic && variable.bindings.contains { !isComputed($0) && !(isConstant && $0.initializer != nil) }
    }

    /// A binding with a getter is computed; one with only `willSet` / `didSet` is stored.
    static func isComputed(_ binding: PatternBindingSyntax) -> Bool {
        guard let block = binding.accessorBlock else { return false }
        switch block.accessors {
        case .getter:
            return true
        case .accessors(let accessors):
            return !accessors.allSatisfy {
                $0.accessorSpecifier.tokenKind == .keyword(.willSet) || $0.accessorSpecifier.tokenKind == .keyword(.didSet)
            }
        }
    }

    static func expand(
        structure: StructDeclSyntax, type: some TypeSyntaxProtocol, conformance: String
    ) throws -> ExtensionDeclSyntax {
        let access = accessPrefix(of: structure)
        let properties = try properties(of: structure)
        let description = Documentation(structure.leadingTrivia).summary

        var fields: [String] = []
        var decode: [String] = []
        var encode: [String] = []
        for property in properties {
            let key = property.key.literal
            let reference = property.reference
            fields.append(
                "__limbFields.add(\(key), \\Self.\(reference), description: \(property.description.literalOrNil), hasDefault: \(property.hasDefault), in: &__limbBuilder)")
            if property.hasDefault {
                // The declared default stays unless the member is present.
                decode.append(
                    "if let __limbValue = try LimbCore.SchemaSupport.decodeIfPresent(__limbObject, \(key), for: \\Self.\(reference)) { self.\(reference) = __limbValue }")
            } else {
                decode.append("self.\(reference) = try LimbCore.SchemaSupport.decode(__limbObject, \(key))")
            }
            encode.append("LimbCore.SchemaSupport.set(&__limbObject, \(key), self.\(reference))")
        }
        let source = """
            extension \(type.trimmed)\(conformance) {
                \(access)static func jsonSchema(in __limbOuter: inout LimbCore.SchemaBuilder) -> LimbCore.JSONObject {
                    __limbOuter.named(Self.self) { __limbBuilder in
                        \(properties.isEmpty ? "let" : "var") __limbFields = LimbCore.SchemaSupport.Fields()
                        \(fields.joined(separator: "\n"))
                        return __limbFields.schema(description: \(description.literalOrNil))
                    }
                }

                \(access)init(json __limbJSON: LimbCore.JSONValue) throws(LimbCore.JSONDecodingError) {
                    \(properties.isEmpty ? "_" : "let __limbObject") = try LimbCore.JSONObject(json: __limbJSON)
                    \(decode.joined(separator: "\n"))
                }

                \(access)var jsonValue: LimbCore.JSONValue {
                    \(properties.isEmpty ? "let" : "var") __limbObject = LimbCore.JSONObject(minimumCapacity: \(properties.count))
                    \(encode.joined(separator: "\n"))
                    return .object(__limbObject)
                }
            }
            """
        return try ExtensionDeclSyntax("\(raw: source)")
    }

    static func expand(
        enumeration: EnumDeclSyntax, type: some TypeSyntaxProtocol, conformance: String
    ) throws -> ExtensionDeclSyntax {
        let access = accessPrefix(of: enumeration)
        var values: [String] = []
        for member in enumeration.memberBlock.members {
            if let conditional = member.decl.as(IfConfigDeclSyntax.self),
                containsMember(conditional, where: { $0.is(EnumCaseDeclSyntax.self) })
            {
                throw failure(
                    "@Schema does not support enum cases inside '#if': the schema and the decoder would disagree about them",
                    at: conditional.clauses.first!.poundKeyword)
            }
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in cases.elements {
                if let associated = element.parameterClause {
                    throw failure(
                        "@Schema does not support enum cases with associated values: an enum becomes a JSON string, which cannot carry them",
                        at: associated)
                }
                if let raw = element.rawValue?.value.as(StringLiteralExprSyntax.self)?.representedLiteralValue {
                    values.append(raw)
                } else {
                    values.append(element.name.text.withoutBackticks)
                }
            }
        }
        let isStringBacked = enumeration.inheritanceClause?.inheritedTypes.contains {
            let name = $0.type.trimmedDescription
            return name == "String" || name == "Swift.String"
        } ?? false
        guard isStringBacked else {
            throw failure(
                "@Schema on an enum requires String raw values: declare it as 'enum \(enumeration.name.text): String'",
                at: introducer(of: enumeration))
        }
        let description = Documentation(enumeration.leadingTrivia).summary
        let list = values.map(\.literal).joined(separator: ", ")
        let descriptionLine = description.map { "__limbSchema[\"description\"] = .string(\($0.literal))" } ?? ""
        let source = """
            extension \(type.trimmed)\(conformance) {
                \(access)static func jsonSchema(in __limbBuilder: inout LimbCore.SchemaBuilder) -> LimbCore.JSONObject {
                    \(description == nil ? "let" : "var") __limbSchema: LimbCore.JSONObject = ["type": "string", "enum": [\(list)]]
                    \(descriptionLine)
                    return __limbSchema
                }

                \(access)init(json __limbJSON: LimbCore.JSONValue) throws(LimbCore.JSONDecodingError) {
                    // `init(rawValue:)` compares by canonical equivalence; JSON strings are equal
                    // only when they are the same bytes.
                    guard case .string(let __limbRaw) = __limbJSON, let __limbValue = Self(rawValue: __limbRaw),
                        __limbValue.rawValue.isBytewiseEqual(to: __limbRaw)
                    else {
                        throw LimbCore.JSONDecodingError(\(("expected one of: " + values.joined(separator: ", ")).literal))
                    }
                    self = __limbValue
                }

                \(access)var jsonValue: LimbCore.JSONValue { .string(self.rawValue) }
            }
            """
        return try ExtensionDeclSyntax("\(raw: source)")
    }
}
