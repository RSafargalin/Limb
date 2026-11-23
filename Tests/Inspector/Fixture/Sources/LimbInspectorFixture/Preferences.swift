import Limb
import Synchronization

private final class Preferences: Sendable {
    private let state = Mutex((count: 0, text: "0:unset"))

    var text: String { state.withLock { $0.text } }

    func save(name: String, color: String) -> String {
        state.withLock {
            $0.count += 1
            $0.text = "\($0.count):\(name):\(color)"
            return $0.text
        }
    }
}

func registerPreferences(on server: Server) throws {
    let preferences = Preferences()
    let mimeType = "text/plain"
    try server.register(resource: .init(
        uri: "limb-fixture://state/preferences", name: "preferences", mimeType: mimeType
    )) { request, _ in
        [.text(uri: request.uri, mimeType: mimeType, text: preferences.text)]
    }
    try server.register(tool: .init(
        name: "collect_preferences", description: "Collects a name and favorite color in two forms."
    )) { _, context in
        let nameAnswer: ElicitResult
        do {
            nameAnswer = try await context.elicit("name", message: "What name should we use?", schema: [
                "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
            ])
        } catch is InputUnavailable {
            return .text("elicitation unavailable")
        }
        guard nameAnswer.action == .accept else { return .text("\(nameAnswer.action.rawValue):name") }
        guard let name = try nameAnswer.content?.required("name", as: String.self) else {
            throw ToolError("Accepted name form has no content.")
        }

        let colorAnswer = try await context.elicit("color", message: "Which color should we use for \(name)?", schema: [
            "type": "object", "properties": ["color": ["type": "string", "enum": ["blue", "green"]]],
            "required": ["color"],
        ])
        guard colorAnswer.action == .accept else { return .text("\(colorAnswer.action.rawValue):color") }
        guard let color = try colorAnswer.content?.required("color", as: String.self) else {
            throw ToolError("Accepted color form has no content.")
        }
        return .text(preferences.save(name: name, color: color))
    }
}
