/// The restricted JSON Schema profile used by elicitation forms.
package enum ElicitationForm {
    package static func isSupported(_ schema: JSONObject, profile: RevisionProfile) -> Bool {
        guard schema["type"] == "object",
              schema.allSatisfy({ ["$schema", "type", "title", "description", "properties", "required"].contains($0.key) }),
              let fields = (schema["properties"] ?? [:]).objectValue,
              (schema["required"]?.arrayValue ?? []).allSatisfy({ $0.stringValue.map(fields.contains) == true })
        else { return false }
        return fields.allSatisfy { entry in
            guard let field = entry.value.objectValue else { return false }
            return isElicitationField(field, profile: profile)
        }
    }

    package static func hasSupportedValues(_ content: JSONObject, profile: RevisionProfile) -> Bool {
        content.allSatisfy { _, value in
            switch value {
            case .string, .number, .bool: true
            case .array(let values) where profile.urlElicitation: values.allSatisfy { $0.stringValue != nil }
            default: false
            }
        }
    }

    private static func isElicitationField(_ field: JSONObject, profile: RevisionProfile) -> Bool {
        func uses(_ object: JSONObject, _ keywords: Set<String>) -> Bool {
            object.allSatisfy { keywords.contains($0.key) }
        }
        func strings(_ value: JSONValue?) -> Bool {
            guard let choices = value?.arrayValue, !choices.isEmpty else { return false }
            return choices.allSatisfy { $0.stringValue != nil }
        }
        if let value = field["default"] {
            let matches: Bool
            switch (field["type"]?.stringValue, value) {
            case ("string", .string), ("number", .number), ("boolean", .bool): matches = true
            case ("integer", .number(let number)): matches = number.isInteger
            case ("array", .array(let values)): matches = values.allSatisfy { $0.stringValue != nil }
            default: matches = false
            }
            guard matches else { return false }
        }
        func titledChoices(_ value: JSONValue?) -> Bool {
            guard let choices = value?.arrayValue, !choices.isEmpty else { return false }
            return choices.allSatisfy {
                guard let choice = $0.objectValue, uses(choice, ["const", "title"]) else { return false }
                return choice["const"]?.stringValue != nil && choice["title"]?.stringValue != nil
            }
        }
        let common: Set<String> = ["type", "title", "description", "default"]
        switch field["type"]?.stringValue {
        case "string":
            if let format = field["format"], !["email", "uri", "date", "date-time"].contains(format.stringValue ?? "") { return false }
            if let choices = field["oneOf"] {
                return profile.urlElicitation && uses(field, common.union(["oneOf"])) && titledChoices(choices)
            }
            if let choices = field["enum"] {
                return uses(field, common.union(["enum", "enumNames"])) && strings(choices)
                    && (field["enumNames"] == nil || strings(field["enumNames"]))
            }
            return uses(field, common.union(["minLength", "maxLength", "format"]))
        case "number", "integer": return uses(field, common.union(["minimum", "maximum"]))
        case "boolean": return uses(field, common)
        case "array":
            guard profile.urlElicitation, uses(field, common.union(["items", "minItems", "maxItems"])),
                let items = field["items"]?.objectValue else { return false }
            if items["type"] == "string" { return uses(items, ["type", "enum"]) && strings(items["enum"]) }
            return uses(items, ["anyOf"]) && titledChoices(items["anyOf"])
        default: return false
        }
    }
}
