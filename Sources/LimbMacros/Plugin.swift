import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct LimbMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [ToolMacro.self, SchemaMacro.self]
}
