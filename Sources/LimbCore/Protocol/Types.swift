/// A protocol type whose wire form depends on the negotiated revision.
///
/// The public types are the same for every revision; this is the one place where their
/// differences live. Fields a revision does not define are not sent to peers speaking it.
public protocol WireEncodable {
    func encode(to writer: inout JSONWriter, profile: RevisionProfile)
}

extension JSONWriter {
    @inlinable
    public mutating func field<T: WireEncodable>(_ name: String, _ value: T, _ profile: RevisionProfile) {
        key(name)
        value.encode(to: &self, profile: profile)
    }

    @inlinable
    public mutating func field<T: WireEncodable>(_ name: String, _ value: T?, _ profile: RevisionProfile) {
        guard let value else { return }
        key(name)
        value.encode(to: &self, profile: profile)
    }

    @inlinable
    public mutating func field<T: WireEncodable>(_ name: String, _ values: [T], _ profile: RevisionProfile) {
        key(name)
        beginArray()
        for value in values { value.encode(to: &self, profile: profile) }
        endArray()
    }

    @inlinable
    public mutating func field<T: WireEncodable>(_ name: String, nonEmpty values: [T], _ profile: RevisionProfile) {
        guard !values.isEmpty else { return }
        field(name, values, profile)
    }
}

// MARK: - Identity

public enum Role: String, Sendable, Hashable {
    case user
    case assistant
}

/// An icon for a server, tool, prompt or resource.
public struct Icon: Sendable, Hashable, JSONEncodable {
    public enum Theme: String, Sendable, Hashable { case light, dark }

    public var src: String
    public var mimeType: String?
    public var sizes: [String]?
    public var theme: Theme?

    public init(src: String, mimeType: String? = nil, sizes: [String]? = nil, theme: Theme? = nil) {
        self.src = src
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }

    public func encode(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("src", src)
        writer.field("mimeType", mimeType)
        writer.field("sizes", sizes)
        writer.field("theme", theme?.rawValue)
        writer.endObject()
    }
}

/// Name and version of a client or server.
public struct Implementation: Sendable, Hashable, WireEncodable {
    public var name: String
    public var title: String?
    public var version: String
    public var description: String?
    public var websiteURL: String?
    public var icons: [Icon]

    public init(
        name: String, title: String? = nil, version: String, description: String? = nil,
        websiteURL: String? = nil, icons: [Icon] = []
    ) {
        self.name = name
        self.title = title
        self.version = version
        self.description = description
        self.websiteURL = websiteURL
        self.icons = icons
    }

    /// Reads a peer's self-description. Tolerant by design: it is display data, and real clients
    /// send incomplete or extended objects.
    public init(lenient json: JSONValue?) {
        let object = json?.objectValue ?? JSONObject()
        name = object["name"]?.stringValue ?? ""
        title = object["title"]?.stringValue
        version = object["version"]?.stringValue ?? ""
        description = object["description"]?.stringValue
        websiteURL = object["websiteUrl"]?.stringValue
        icons = []
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        writer.field("name", name)
        if profile.structuredOutput { writer.field("title", title) }
        writer.field("version", version)
        if profile.implementationDetails {
            writer.field("description", description)
            writer.field("websiteUrl", websiteURL)
        }
        if profile.icons { writer.field("icons", nonEmpty: icons) }
        writer.endObject()
    }
}

/// Capabilities a client declared, kept as sent so unknown ones survive.
public struct ClientCapabilities: Sendable, Hashable {
    public var raw: JSONObject

    public init(raw: JSONObject = JSONObject()) { self.raw = raw }

    public var supportsRoots: Bool { raw["roots"]?.objectValue != nil }
    public var supportsSampling: Bool { raw["sampling"]?.objectValue != nil }
    public var supportsSamplingTools: Bool { raw["sampling"]?["tools"]?.objectValue != nil }

    /// Form elicitation. An empty `elicitation` object means form mode, for backward compatibility.
    public var supportsElicitation: Bool {
        guard let elicitation = raw["elicitation"]?.objectValue else { return false }
        return elicitation["form"] != nil || elicitation["url"] == nil
    }

    public var supportsURLElicitation: Bool { raw["elicitation"]?["url"]?.objectValue != nil }

    public func supportsExtension(_ identifier: String) -> Bool { raw["extensions"]?[identifier] != nil }
}

/// Syslog severities, least severe first.
public enum LoggingLevel: String, Sendable, Hashable, Comparable, CaseIterable {
    case debug, info, notice, warning, error, critical, alert, emergency

    private var rank: Int { LoggingLevel.allCases.firstIndex(of: self)! }
    public static func < (lhs: LoggingLevel, rhs: LoggingLevel) -> Bool { lhs.rank < rhs.rank }
}

// MARK: - Content

/// Display hints attached to content and resources.
public struct Annotations: Sendable, Hashable, WireEncodable {
    public var audience: [Role]?
    public var priority: Double?
    public var lastModified: String?

    public init(audience: [Role]? = nil, priority: Double? = nil, lastModified: String? = nil) {
        self.audience = audience
        self.priority = priority
        self.lastModified = lastModified
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        writer.field("audience", audience?.map(\.rawValue))
        writer.field("priority", priority)
        if profile.annotationLastModified { writer.field("lastModified", lastModified) }
        writer.endObject()
    }
}

/// The contents of a resource: text, or binary data as base64.
public enum ResourceContents: Sendable, Hashable, WireEncodable {
    case text(uri: String, mimeType: String? = nil, text: String, meta: JSONObject? = nil)
    case blob(uri: String, mimeType: String? = nil, base64: String, meta: JSONObject? = nil)

    public static func blob(uri: String, mimeType: String? = nil, bytes: some Collection<UInt8>) -> ResourceContents {
        .blob(uri: uri, mimeType: mimeType, base64: Base64.encode(bytes))
    }

    public var uri: String {
        switch self {
        case .text(let uri, _, _, _), .blob(let uri, _, _, _): uri
        }
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        switch self {
        case .text(let uri, let mimeType, let text, let meta):
            writer.field("uri", uri)
            writer.field("mimeType", mimeType)
            writer.field("text", text)
            if profile.structuredOutput { writer.field("_meta", meta) }
        case .blob(let uri, let mimeType, let base64, let meta):
            writer.field("uri", uri)
            writer.field("mimeType", mimeType)
            writer.field("blob", base64)
            if profile.structuredOutput { writer.field("_meta", meta) }
        }
        writer.endObject()
    }
}

/// One block of a tool result or prompt message.
public enum ContentBlock: Sendable, Hashable, WireEncodable {
    case text(String, annotations: Annotations? = nil, meta: JSONObject? = nil)
    /// An image; `data` is base64.
    case image(data: String, mimeType: String, annotations: Annotations? = nil, meta: JSONObject? = nil)
    /// Audio; `data` is base64.
    case audio(data: String, mimeType: String, annotations: Annotations? = nil, meta: JSONObject? = nil)
    /// A pointer to a resource the client can read.
    case resourceLink(ResourceDefinition)
    /// A resource embedded in the message.
    case resource(ResourceContents, annotations: Annotations? = nil, meta: JSONObject? = nil)

    public static func image(bytes: some Collection<UInt8>, mimeType: String) -> ContentBlock {
        .image(data: Base64.encode(bytes), mimeType: mimeType)
    }

    public static func audio(bytes: some Collection<UInt8>, mimeType: String) -> ContentBlock {
        .audio(data: Base64.encode(bytes), mimeType: mimeType)
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        switch self {
        case .text(let text, let annotations, let meta):
            writer.field("type", "text")
            writer.field("text", text)
            writer.field("annotations", annotations, profile)
            if profile.structuredOutput { writer.field("_meta", meta) }
        case .image(let data, let mimeType, let annotations, let meta):
            writer.field("type", "image")
            writer.field("data", data)
            writer.field("mimeType", mimeType)
            writer.field("annotations", annotations, profile)
            if profile.structuredOutput { writer.field("_meta", meta) }
        case .audio(let data, let mimeType, let annotations, let meta):
            writer.field("type", "audio")
            writer.field("data", data)
            writer.field("mimeType", mimeType)
            writer.field("annotations", annotations, profile)
            if profile.structuredOutput { writer.field("_meta", meta) }
        case .resourceLink(let resource):
            if profile.structuredOutput {
                writer.field("type", "resource_link")
                resource.encodeMembers(to: &writer, profile: profile)
            } else {
                // `resource_link` does not exist before 2025-06-18; the closest faithful form is text.
                writer.field("type", "text")
                writer.field("text", resource.uri)
            }
        case .resource(let contents, let annotations, let meta):
            writer.field("type", "resource")
            writer.field("resource", contents, profile)
            writer.field("annotations", annotations, profile)
            if profile.structuredOutput { writer.field("_meta", meta) }
        }
        writer.endObject()
    }
}

// MARK: - Tools

/// Behavior hints for a tool. Clients treat them as untrusted unless the server is trusted.
public struct ToolAnnotations: Sendable, Hashable, JSONEncodable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil, openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    var isEmpty: Bool {
        title == nil && readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil && openWorldHint == nil
    }

    public func encode(to writer: inout JSONWriter) {
        writer.beginObject()
        writer.field("title", title)
        writer.field("readOnlyHint", readOnlyHint)
        writer.field("destructiveHint", destructiveHint)
        writer.field("idempotentHint", idempotentHint)
        writer.field("openWorldHint", openWorldHint)
        writer.endObject()
    }
}

/// What a tool is called, what it accepts and what it returns.
public struct ToolDefinition: Sendable, Hashable, WireEncodable {
    public var name: String
    public var title: String?
    public var description: String?
    /// JSON Schema for the arguments; its root type is `object`.
    public var inputSchema: JSONObject
    /// JSON Schema for `structuredContent`, if the tool returns structured results.
    public var outputSchema: JSONObject?
    public var annotations: ToolAnnotations?
    public var icons: [Icon]
    public var meta: JSONObject?

    public init(
        name: String, title: String? = nil, description: String? = nil,
        inputSchema: JSONObject = ["type": "object"], outputSchema: JSONObject? = nil,
        annotations: ToolAnnotations? = nil, icons: [Icon] = [], meta: JSONObject? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.icons = icons
        self.meta = meta
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        writer.field("name", name)
        var annotations = self.annotations
        if profile.structuredOutput {
            writer.field("title", title)
        } else if let title, annotations?.title == nil {
            // Before 2025-06-18 a tool's display name lives only in its annotations.
            annotations = annotations ?? ToolAnnotations()
            annotations?.title = title
        }
        writer.field("description", description)
        writer.field("inputSchema", inputSchema)
        // Before 2026-07-28 an output schema must describe an object, and structured content
        // must be one. A schema of any other kind is not offered to those revisions: advertising
        // it while withholding the content would promise a result the server will not send.
        if profile.structuredOutput, let outputSchema,
            profile.anyStructuredContent || outputSchema["type"] == "object"
        {
            writer.field("outputSchema", outputSchema)
        }
        if let annotations, !annotations.isEmpty { writer.field("annotations", annotations) }
        if profile.icons { writer.field("icons", nonEmpty: icons) }
        if profile.structuredOutput { writer.field("_meta", meta) }
        writer.endObject()
    }
}

/// What a tool call produced.
public struct ToolResult: Sendable, Hashable, WireEncodable {
    public var content: [ContentBlock]
    /// Machine-readable result; must conform to the tool's `outputSchema` when it declares one.
    public var structuredContent: JSONValue?
    /// The tool ran and failed. The model sees the content and can correct its call.
    public var isError: Bool
    public var meta: JSONObject?

    public init(
        content: [ContentBlock] = [], structuredContent: JSONValue? = nil, isError: Bool = false,
        meta: JSONObject? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self.meta = meta
    }

    public static func text(_ text: String) -> ToolResult { ToolResult(content: [.text(text)]) }

    /// A tool execution error: reported inside the result so the model can see and react to it.
    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: [.text(message)], isError: true)
    }

    /// A structured result. Its JSON text is added as a text block for clients that predate
    /// `structuredContent`.
    public static func structured(_ value: JSONValue) -> ToolResult {
        ToolResult(structuredContent: value)
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        encodeMembers(to: &writer, profile: profile)
        if let meta, !meta.isEmpty { writer.field("_meta", meta) }
        writer.endObject()
    }

    /// Writes the members without the enclosing braces and without `meta`, so the caller can
    /// write the result's `_meta` together with what the revision adds to it.
    public func encodeMembers(to writer: inout JSONWriter, profile: RevisionProfile) {
        var sendsStructured = false
        if let structuredContent, profile.structuredOutput {
            // Before 2026-07-28 structured content must be an object.
            sendsStructured = profile.anyStructuredContent || structuredContent.objectValue != nil
        }
        writer.key("content")
        writer.beginArray()
        for block in content { block.encode(to: &writer, profile: profile) }
        if content.isEmpty, let structuredContent {
            // The serialized JSON as text: the only form older clients can read, and the
            // backward-compatible duplicate the specification asks for otherwise.
            ContentBlock.text(structuredContent.description).encode(to: &writer, profile: profile)
        }
        writer.endArray()
        if sendsStructured { writer.field("structuredContent", structuredContent) }
        writer.field("isError", isError)
    }
}

// MARK: - Resources

/// A resource the server exposes.
public struct ResourceDefinition: Sendable, Hashable, WireEncodable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var annotations: Annotations?
    public var size: Int?
    public var icons: [Icon]
    public var meta: JSONObject?

    public init(
        uri: String, name: String, title: String? = nil, description: String? = nil,
        mimeType: String? = nil, annotations: Annotations? = nil, size: Int? = nil,
        icons: [Icon] = [], meta: JSONObject? = nil
    ) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
        self.size = size
        self.icons = icons
        self.meta = meta
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        encodeMembers(to: &writer, profile: profile)
        writer.endObject()
    }

    func encodeMembers(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.field("uri", uri)
        writer.field("name", name)
        if profile.structuredOutput { writer.field("title", title) }
        writer.field("description", description)
        writer.field("mimeType", mimeType)
        writer.field("annotations", annotations, profile)
        writer.field("size", size)
        if profile.icons { writer.field("icons", nonEmpty: icons) }
        if profile.structuredOutput { writer.field("_meta", meta) }
    }
}

/// A family of resources addressed by an RFC 6570 URI template.
///
/// The server accepts `{name}` and `{+name}` expressions, each variable named once; see
/// `Server.register(resourceTemplate:cache:complete:read:)`.
public struct ResourceTemplateDefinition: Sendable, Hashable, WireEncodable {
    public var uriTemplate: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var annotations: Annotations?
    public var icons: [Icon]
    public var meta: JSONObject?

    public init(
        uriTemplate: String, name: String, title: String? = nil, description: String? = nil,
        mimeType: String? = nil, annotations: Annotations? = nil, icons: [Icon] = [], meta: JSONObject? = nil
    ) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
        self.icons = icons
        self.meta = meta
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        writer.field("uriTemplate", uriTemplate)
        writer.field("name", name)
        if profile.structuredOutput { writer.field("title", title) }
        writer.field("description", description)
        writer.field("mimeType", mimeType)
        writer.field("annotations", annotations, profile)
        if profile.icons { writer.field("icons", nonEmpty: icons) }
        if profile.structuredOutput { writer.field("_meta", meta) }
        writer.endObject()
    }
}

// MARK: - Prompts

public struct PromptArgument: Sendable, Hashable, WireEncodable {
    public var name: String
    public var title: String?
    public var description: String?
    public var required: Bool

    public init(name: String, title: String? = nil, description: String? = nil, required: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        writer.field("name", name)
        if profile.structuredOutput { writer.field("title", title) }
        writer.field("description", description)
        writer.field("required", required)
        writer.endObject()
    }
}

/// A prompt template the server offers.
public struct PromptDefinition: Sendable, Hashable, WireEncodable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [PromptArgument]
    public var icons: [Icon]
    public var meta: JSONObject?

    public init(
        name: String, title: String? = nil, description: String? = nil,
        arguments: [PromptArgument] = [], icons: [Icon] = [], meta: JSONObject? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.icons = icons
        self.meta = meta
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        writer.field("name", name)
        if profile.structuredOutput { writer.field("title", title) }
        writer.field("description", description)
        writer.field("arguments", nonEmpty: arguments, profile)
        if profile.icons { writer.field("icons", nonEmpty: icons) }
        if profile.structuredOutput { writer.field("_meta", meta) }
        writer.endObject()
    }
}

public struct PromptMessage: Sendable, Hashable, WireEncodable {
    public var role: Role
    public var content: ContentBlock

    public init(role: Role, content: ContentBlock) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> PromptMessage { PromptMessage(role: .user, content: .text(text)) }
    public static func assistant(_ text: String) -> PromptMessage {
        PromptMessage(role: .assistant, content: .text(text))
    }

    public func encode(to writer: inout JSONWriter, profile: RevisionProfile) {
        writer.beginObject()
        writer.field("role", role.rawValue)
        writer.field("content", content, profile)
        writer.endObject()
    }
}

/// The messages a prompt expands to.
public struct PromptResult: Sendable, Hashable {
    public var description: String?
    public var messages: [PromptMessage]

    public init(description: String? = nil, messages: [PromptMessage]) {
        self.description = description
        self.messages = messages
    }
}

/// Suggested values for a prompt or resource-template argument.
public struct CompletionResult: Sendable, Hashable {
    /// At most 100 values are sent, as the specification requires.
    public var values: [String]
    public var total: Int?
    public var hasMore: Bool?

    public init(values: [String] = [], total: Int? = nil, hasMore: Bool? = nil) {
        self.values = values
        self.total = total
        self.hasMore = hasMore
    }
}
