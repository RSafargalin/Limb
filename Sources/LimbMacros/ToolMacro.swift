import SwiftSyntax
import SwiftSyntaxMacros

/// `@Tool`: turns a type with a `call` method into an MCP tool.
///
/// The method's parameters are the tool's arguments; the type's stored properties are its
/// dependencies. Name, description, input schema, output schema, argument decoding and result
/// encoding are all derived from that one declaration.
///
/// The members are generated inside the type, not in an extension: they name the argument types
/// and copy default-value expressions, and those must resolve exactly as they do where the user
/// wrote them — including names of types declared next to the tool in the same namespace.
public struct ToolMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Errors are reported once, by the member role. A declaration it rejects gets no
        // conformance either: "does not conform to MCPTool" on top of the real error is noise.
        guard !protocols.isEmpty,
            (try? members(of: node, in: declaration, context: context, reportsWarnings: false)) != nil
        else { return [] }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): LimbServer.MCPTool {}")]
    }

    static func toolName(of declaration: some DeclGroupSyntax) throws -> TokenSyntax {
        if let structure = declaration.as(StructDeclSyntax.self) { return structure.name }
        if let actor = declaration.as(ActorDeclSyntax.self) { return actor.name }
        if let klass = declaration.as(ClassDeclSyntax.self) { return klass.name }
        throw failure("@Tool can be applied to a struct, a final class or an actor", at: introducer(of: declaration))
    }

    public static func expansion(
        of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try members(of: node, in: declaration, context: context, reportsWarnings: true)
    }

    static func members(
        of node: AttributeSyntax, in declaration: some DeclGroupSyntax, context: some MacroExpansionContext,
        reportsWarnings: Bool
    ) throws -> [DeclSyntax] {
        let typeName = try toolName(of: declaration)

        let candidates = declaration.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }.filter {
            $0.name.text == "call"
        }
        guard let function = candidates.first else {
            throw failure("@Tool needs a method named 'call' whose parameters are the tool's arguments", at: introducer(of: declaration))
        }
        guard candidates.count == 1 else {
            throw failure("@Tool found several 'call' methods; a tool has exactly one", at: candidates[1].name)
        }
        for modifier in function.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.static), .keyword(.class):
                throw failure("a tool's 'call' method must be an instance method", at: modifier)
            case .keyword(.mutating):
                throw failure("a tool's 'call' method cannot be mutating: one tool value serves many calls at once", at: modifier)
            default:
                continue
            }
        }
        if let generics = function.genericParameterClause {
            throw failure("a tool's 'call' method cannot be generic: its arguments need concrete types with a JSON Schema", at: generics)
        }

        // Attribute arguments.
        var name = typeName.text.withoutBackticks.snakeCased
        var nameNode = Syntax(typeName)
        var title = "nil"
        var hints: [String] = []
        if let arguments = node.arguments?.as(LabeledExprListSyntax.self) {
            for argument in arguments {
                let expression = argument.expression.trimmedDescription
                switch argument.label?.text {
                case nil:
                    guard let literal = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue else {
                        throw failure("the tool name must be a string literal", at: argument.expression)
                    }
                    name = literal
                    nameNode = Syntax(argument.expression)
                case "title": title = expression
                case "readOnly": hints.append("readOnlyHint: \(expression)")
                case "destructive": hints.append("destructiveHint: \(expression)")
                case "idempotent": hints.append("idempotentHint: \(expression)")
                case "openWorld": hints.append("openWorldHint: \(expression)")
                case .some(let label): throw failure("unknown @Tool argument '\(label)'", at: argument)
                }
            }
        }
        guard !name.isEmpty, name.utf8.count <= 128,
            name.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D || $0 == 0x2E })
        else {
            throw failure("tool name '\(name)' must be 1–128 characters of A–Z, a–z, 0–9, '_', '-' and '.'", at: nameNode)
        }

        let toolDocumentation = Documentation(declaration.leadingTrivia)
        let callDocumentation = Documentation(function.leadingTrivia)
        let description = toolDocumentation.summary ?? callDocumentation.summary
        if description == nil, reportsWarnings {
            warn(
                "tool '\(name)' has no description: add a '///' comment saying what it does, so that the model knows when to call it",
                at: typeName, in: context)
        }

        var fields: [String] = []
        var declarations: [String] = []
        var decode: [String] = []
        var callArguments: [String] = []
        var defaults: [String] = []
        var seen: Set<String> = []
        var isOwnSignature = true
        for (index, parameter) in function.signature.parameterClause.parameters.enumerated() {
            let label = parameter.firstName.text
            let local = (parameter.secondName ?? parameter.firstName).text
            let argumentName = (label == "_" ? local : label).withoutBackticks
            // At a call site a keyword needs no backticks as a label — except `inout`.
            let callLabel = label == "`inout`" ? label : label.withoutBackticks
            let prefix = label == "_" ? "" : "\(callLabel): "

            var bare = parameter.type
            if let optional = bare.as(OptionalTypeSyntax.self) { bare = optional.wrappedType }
            let base = baseName(of: bare)
            if base == "ToolContext" || base == "RequestContext" {
                callArguments.append("\(prefix)__limbContext")
                if !(index == 1 && label == "context") { isOwnSignature = false }
                continue
            }
            if !(index == 0 && label == "arguments" && base == "JSONObject") { isOwnSignature = false }

            if parameter.ellipsis != nil {
                throw failure("@Tool does not support variadic parameters ('\(argumentName)'): declare an array", at: parameter.type)
            }
            if let reason = unsupportedReason(for: parameter.type) {
                throw failure("'\(argumentName)' cannot be a tool argument: \(reason)", at: parameter.type)
            }
            guard argumentName != "_" else {
                throw failure("a tool argument needs a name: it is the key the client sends", at: parameter)
            }
            guard seen.insert(argumentName).inserted else {
                throw failure("two tool arguments are named '\(argumentName)'", at: parameter)
            }
            let typeText = parameter.type.trimmedDescription
            let parameterDescription =
                callDocumentation.parameters[argumentName] ?? callDocumentation.parameters[local.withoutBackticks]
            let hasDefault = parameter.defaultValue != nil
            fields.append(
                "__limbFields.add(\(argumentName.literal), (\(typeText)).self, description: \(parameterDescription.literalOrNil), hasDefault: \(hasDefault), in: &__limbBuilder)")
            let variable = "__limbArgument\(index)"
            declarations.append("let \(variable): \(typeText)")
            if let defaultValue = parameter.defaultValue?.value {
                // The default is evaluated in a static method of its own, where it means exactly
                // what it means in the signature: it may name the type's static members with or
                // without `Self.`, and it is one expression whatever operators it contains.
                defaults.append(
                    "case \(index): let __limbDefault: \(typeText) = (\(defaultValue.trimmedDescription)); return __limbDefault as! __LimbValue")
                decode.append(
                    "\(variable) = try LimbCore.SchemaSupport.decode(__limbArguments, \(argumentName.literal), default: Self.__limbDefault(__limbArgument: \(index) as Swift.Int))")
            } else {
                decode.append("\(variable) = try LimbCore.SchemaSupport.decode(__limbArguments, \(argumentName.literal))")
            }
            callArguments.append("\(prefix)\(variable)")
        }
        if isOwnSignature, function.signature.parameterClause.parameters.count == 2 {
            throw failure(
                "@Tool generates 'call(arguments:context:)' itself; give this method the tool's arguments as parameters, or drop @Tool and conform to MCPTool by hand",
                at: function.name)
        }

        let effects = function.signature.effectSpecifiers
        let invocationPrefix = (effects?.throwsClause != nil ? "try " : "") + (effects?.asyncSpecifier != nil ? "await " : "")
        let invocation = "\(invocationPrefix)self.call(\(callArguments.joined(separator: ", ")))"
        let returnType = function.signature.returnClause?.type.trimmedDescription
        let returnsNothing = returnType == nil || returnType == "Void" || returnType == "Swift.Void" || returnType == "()"
        let outputSchema = returnsNothing ? "nil" : "LimbServer.ToolSupport.outputSchema((\(returnType!)).self)"
        let body =
            returnsNothing
            ? "\(invocation)\nreturn LimbCore.ToolResult()" : "return LimbServer.ToolSupport.result(\(invocation))"
        let annotations = hints.isEmpty ? "nil" : "LimbCore.ToolAnnotations(\(hints.joined(separator: ", ")))"
        let access = accessPrefix(of: declaration)
        // `MCPTool` is nonisolated, and its `definition` is synchronous: on a type isolated to
        // a global actor it has to opt out of that isolation, or the conformance would cross
        // into it. (It only builds the schema from the argument types.) `call(arguments:context:)`
        // may stay isolated: an async requirement can be met across actors.
        let definitionIsolation = mayBeGlobalActorIsolated(declaration) ? "nonisolated " : ""
        let decoding =
            declarations.isEmpty
            ? ""
            : """
                \(declarations.joined(separator: "\n"))
                do throws(LimbCore.JSONDecodingError) {
                    \(decode.joined(separator: "\n"))
                } catch {
                    throw LimbServer.ToolSupport.invalidArguments(error)
                }
                """

        // Declared only when there is something to add, so that a tool without arguments does not
        // produce "never mutated" warnings in the user's build.
        let schemaSetup =
            fields.isEmpty
            ? ""
            : """
                var __limbBuilder = LimbCore.SchemaBuilder()
                var __limbFields = LimbCore.SchemaSupport.Fields()
                \(fields.joined(separator: "\n"))
                """
        let inputSchema =
            fields.isEmpty
            ? "LimbCore.SchemaSupport.Fields().schema(description: nil)"
            : "__limbBuilder.finish(__limbFields.schema(description: nil))"
        // Computed, not stored: a stored static property is not allowed in a generic type.
        let definition: DeclSyntax = """
            \(raw: access)\(raw: definitionIsolation)static var definition: LimbCore.ToolDefinition {
                \(raw: schemaSetup)
                return LimbCore.ToolDefinition(
                    name: \(raw: name.literal),
                    title: \(raw: title),
                    description: \(raw: description.literalOrNil),
                    inputSchema: \(raw: inputSchema),
                    outputSchema: \(raw: outputSchema),
                    annotations: \(raw: annotations))
            }
            """
        let call: DeclSyntax = """
            \(raw: access)func call(
                arguments __limbArguments: LimbCore.JSONObject, context __limbContext: LimbServer.RequestContext
            ) async throws -> LimbCore.ToolResult {
                \(raw: decoding)
                \(raw: body)
            }
            """
        guard !defaults.isEmpty else { return [definition, call] }
        let defaultValues: DeclSyntax = """
            private static func __limbDefault<__LimbValue>(__limbArgument __limbIndex: Swift.Int) -> __LimbValue {
                switch __limbIndex {
                \(raw: defaults.joined(separator: "\n"))
                default: fatalError("no default for argument \\(__limbIndex)")
                }
            }
            """
        return [definition, call, defaultValues]
    }

    /// Whether the type carries an attribute that may be a global actor: `@MainActor`, or any
    /// other capitalized attribute but `@Tool` itself. A macro cannot tell a global actor from,
    /// say, another macro by its name; it does not need to, as `nonisolated` on `definition`
    /// changes nothing on a type that is not isolated.
    static func mayBeGlobalActorIsolated(_ declaration: some DeclGroupSyntax) -> Bool {
        declaration.attributes.contains {
            guard let name = $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription else { return false }
            let last = name.split(separator: ".").last.map(String.init) ?? name
            return last != "Tool" && last.first?.isUppercase == true
        }
    }

    /// Why a parameter of this type cannot be read from JSON, or `nil` if the macro cannot tell
    /// (whether a named type has a schema is for the type checker to say).
    static func unsupportedReason(for type: TypeSyntax) -> String? {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            let text = attributed.trimmedDescription
            if text.hasPrefix("inout ") { return "an 'inout' parameter has nothing to write back to" }
            if text.hasPrefix("borrowing ") || text.hasPrefix("consuming ") || text.hasPrefix("__owned ")
                || text.hasPrefix("__shared ") || text.hasPrefix("sending ")
            {
                return "ownership modifiers are not supported on tool arguments"
            }
            return unsupportedReason(for: attributed.baseType) ?? "attributes are not supported on tool arguments"
        }
        if type.is(FunctionTypeSyntax.self) { return "a closure cannot be sent as JSON" }
        if let tuple = type.as(TupleTypeSyntax.self) {
            if tuple.elements.count == 1, let only = tuple.elements.first { return unsupportedReason(for: only.type) }
            return "a tuple has no JSON Schema; declare a @Schema struct"
        }
        if type.is(SomeOrAnyTypeSyntax.self) { return "an existential or opaque type has no JSON Schema" }
        if type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return "write '?' instead of '!'" }
        if let name = baseName(of: type), name == "Any" || name == "AnyObject" {
            return "'\(name)' has no JSON Schema; use JSONValue for arbitrary JSON"
        }
        if let optional = type.as(OptionalTypeSyntax.self) { return unsupportedReason(for: optional.wrappedType) }
        return nil
    }
}
