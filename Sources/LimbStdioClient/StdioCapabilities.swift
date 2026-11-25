#if os(macOS)
import LimbCore

enum StdioCapabilities {
    static func decode(_ value: JSONValue?, profile: RevisionProfile) throws(StdioNegotiationError) -> JSONObject {
        guard let capabilities = value?.objectValue else { throw .malformedResponse }
        for key in ["logging", "completions"] {
            _ = try object(capabilities[key])
        }
        for key in ["prompts", "resources", "tools"] {
            let entry = try object(capabilities[key])
            try boolean(entry?["listChanged"])
            if key == "resources" { try boolean(entry?["subscribe"]) }
        }
        try settings(capabilities["experimental"])
        if profile.hasDiscover { try settings(capabilities["extensions"]) }
        if profile.version == .v2025_11_25 {
            let tasks = try object(capabilities["tasks"])
            _ = try object(tasks?["list"])
            _ = try object(tasks?["cancel"])
            let requests = try object(tasks?["requests"])
            let tools = try object(requests?["tools"])
            _ = try object(tools?["call"])
        }
        return capabilities
    }

    private static func object(_ value: JSONValue?) throws(StdioNegotiationError) -> JSONObject? {
        guard let value else { return nil }
        guard let object = value.objectValue else { throw .malformedResponse }
        return object
    }

    private static func boolean(_ value: JSONValue?) throws(StdioNegotiationError) {
        if let value, case .bool = value { return }
        if value != nil { throw .malformedResponse }
    }

    private static func settings(_ value: JSONValue?) throws(StdioNegotiationError) {
        guard let entries = try object(value) else { return }
        for (_, settings) in entries {
            _ = try object(settings)
        }
    }
}
#endif
