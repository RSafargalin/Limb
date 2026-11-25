import LimbCore

enum ClientWire {
    static func elements<T>(
        _ object: JSONObject, _ key: String, decode: (JSONValue) throws(JSONDecodingError) -> T
    ) throws(JSONDecodingError) -> [T] {
        let values: [JSONValue] = try object.required(key)
        var items: [T] = []
        items.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            do {
                items.append(try decode(value))
            } catch {
                throw error.nested(in: "[\(index)]").nested(in: key)
            }
        }
        return items
    }

    static func parse(_ bytes: Span<UInt8>) throws(JSONDecodingError) -> JSONValue {
        do { return try JSON.parseStrict(bytes) }
        catch { throw JSONDecodingError(error.description) }
    }

    static func cacheHints(_ object: JSONObject) throws(JSONDecodingError) -> ClientCacheHints {
        guard let ttl = object["ttlMs"]?.numberValue, ttl.isInteger else {
            throw JSONDecodingError("expected an integer", path: ["ttlMs"])
        }
        let scope: String = try object.required("cacheScope")
        guard let known = ClientCacheHints.Scope(rawValue: scope) else {
            throw JSONDecodingError("expected public or private", path: ["cacheScope"])
        }
        return ClientCacheHints(ttlMilliseconds: max(ttl, JSONNumber(0)), scope: known)
    }

    static func validateInputRequired(_ object: JSONObject) throws(JSONDecodingError) {
        let state: String? = try object.wireOptional("requestState")
        if let requests = try object.wireOptional("inputRequests", as: JSONObject.self) {
            for (key, value) in requests {
                do {
                    let request = try JSONObject(json: value)
                    _ = try request.required("method", as: String.self)
                    _ = try request.wireOptional("params", as: JSONObject.self)
                } catch {
                    throw error.nested(in: key).nested(in: "inputRequests")
                }
            }
        } else if state == nil {
            throw JSONDecodingError("expected inputRequests or requestState")
        }
    }

    static func tool(_ value: JSONValue, profile: RevisionProfile) throws(JSONDecodingError) -> ToolDefinition {
        let fields = try JSONObject(json: value)
        let input: JSONObject = try fields.required("inputSchema")
        guard input["type"] == "object" else {
            throw JSONDecodingError("expected an object schema", path: ["inputSchema", "type"])
        }
        let output: JSONObject? = profile.structuredOutput ? try fields.wireOptional("outputSchema") : nil
        if let output, !profile.anyStructuredContent, output["type"] != "object" {
            throw JSONDecodingError("expected an object schema", path: ["outputSchema", "type"])
        }
        try validateSchema(input, field: "inputSchema")
        if let output { try validateSchema(output, field: "outputSchema") }
        let hints: JSONObject? = try fields.wireOptional("annotations")
        var annotations: ToolAnnotations?
        if let hints {
            do {
                annotations = try ToolAnnotations(
                    title: hints.wireOptional("title"), readOnlyHint: hints.wireOptional("readOnlyHint"),
                    destructiveHint: hints.wireOptional("destructiveHint"), idempotentHint: hints.wireOptional("idempotentHint"),
                    openWorldHint: hints.wireOptional("openWorldHint"))
            } catch { throw error.nested(in: "annotations") }
        }
        return try ToolDefinition(
            name: fields.required("name"), title: title(fields, profile: profile), description: fields.wireOptional("description"),
            inputSchema: input, outputSchema: output, annotations: annotations,
            icons: icons(fields, profile: profile), meta: itemMetadata(fields, profile: profile))
    }

    private static func validateSchema(_ object: JSONObject, field: String) throws(JSONDecodingError) {
        do {
            _ = try JSONSchema(.object(object))
        } catch {
            throw JSONDecodingError(error.description, path: [field])
        }
    }

    static func toolResult(_ fields: JSONObject, profile: RevisionProfile) throws(JSONDecodingError) -> ToolResult {
        let structured = profile.structuredOutput ? fields["structuredContent"] : nil
        if let structured, !profile.anyStructuredContent, structured.objectValue == nil {
            throw JSONDecodingError("expected an object", path: ["structuredContent"])
        }
        return try ToolResult(
            content: elements(fields, "content") { item throws(JSONDecodingError) in
                try content(item, profile: profile)
            },
            structuredContent: structured, isError: fields.wireOptional("isError") ?? false, meta: fields.wireOptional("_meta"))
    }

    static func toolOutput(
        _ result: ToolResult, extracting: ToolOutputExtractor?
    ) throws(JSONDecodingError) -> JSONValue {
        if let structured = result.structuredContent { return structured }
        if let extracting { return try extracting(result) }
        guard result.content.count == 1, case .text(let text, _, _) = result.content[0] else {
            throw JSONDecodingError("expected structured content or one text block containing JSON")
        }
        let bytes = Array(text.utf8)
        do { return try parse(bytes.span) }
        catch { throw error.nested(in: "text").nested(in: "[0]").nested(in: "content") }
    }

    static func resource(_ value: JSONValue, profile: RevisionProfile) throws(JSONDecodingError) -> ResourceDefinition {
        let fields = try JSONObject(json: value)
        return try ResourceDefinition(
            uri: fields.required("uri"), name: fields.required("name"), title: title(fields, profile: profile),
            description: fields.wireOptional("description"), mimeType: fields.wireOptional("mimeType"),
            annotations: annotations(fields, profile: profile), size: fields.wireOptional("size"),
            icons: icons(fields, profile: profile), meta: itemMetadata(fields, profile: profile))
    }

    static func template(
        _ value: JSONValue, profile: RevisionProfile
    ) throws(JSONDecodingError) -> ResourceTemplateDefinition {
        let fields = try JSONObject(json: value)
        return try ResourceTemplateDefinition(
            uriTemplate: fields.required("uriTemplate"), name: fields.required("name"), title: title(fields, profile: profile),
            description: fields.wireOptional("description"), mimeType: fields.wireOptional("mimeType"),
            annotations: annotations(fields, profile: profile),
            icons: icons(fields, profile: profile), meta: itemMetadata(fields, profile: profile))
    }

    static func resourceContents(
        _ value: JSONValue, profile: RevisionProfile
    ) throws(JSONDecodingError) -> ResourceContents {
        let fields = try JSONObject(json: value)
        let uri: String = try fields.required("uri")
        let mimeType: String? = try fields.wireOptional("mimeType")
        let meta = try itemMetadata(fields, profile: profile)
        switch (fields["text"], fields["blob"]) {
        case (.some, nil):
            return try .text(uri: uri, mimeType: mimeType, text: fields.required("text"), meta: meta)
        case (nil, .some):
            return try .blob(uri: uri, mimeType: mimeType, base64: fields.required("blob"), meta: meta)
        default:
            throw JSONDecodingError("expected exactly one of text or blob")
        }
    }

    static func prompt(_ value: JSONValue, profile: RevisionProfile) throws(JSONDecodingError) -> PromptDefinition {
        let fields = try JSONObject(json: value)
        var arguments: [PromptArgument] = []
        if fields["arguments"] != nil {
            arguments = try elements(fields, "arguments") { value throws(JSONDecodingError) in
                let argument = try JSONObject(json: value)
                return try PromptArgument(
                    name: argument.required("name"), title: title(argument, profile: profile),
                    description: argument.wireOptional("description"), required: argument.wireOptional("required") ?? false)
            }
        }
        return try PromptDefinition(
            name: fields.required("name"), title: title(fields, profile: profile),
            description: fields.wireOptional("description"), arguments: arguments,
            icons: icons(fields, profile: profile), meta: itemMetadata(fields, profile: profile))
    }

    static func promptResult(_ fields: JSONObject, profile: RevisionProfile) throws(JSONDecodingError) -> PromptResult {
        let messages = try elements(fields, "messages") { value throws(JSONDecodingError) in
            let message = try JSONObject(json: value)
            let role: String = try message.required("role")
            guard let knownRole = Role(rawValue: role) else {
                throw JSONDecodingError("unknown prompt role", path: ["role"])
            }
            guard let rawContent = message["content"] else {
                throw JSONDecodingError("missing required field", path: ["content"])
            }
            do throws(JSONDecodingError) {
                return try PromptMessage(role: knownRole, content: content(rawContent, profile: profile))
            }
            catch { throw error.nested(in: "content") }
        }
        return try PromptResult(description: fields.wireOptional("description"), messages: messages)
    }

    static func completion(_ fields: JSONObject) throws(JSONDecodingError) -> CompletionResult {
        let fields: JSONObject = try fields.required("completion")
        do throws(JSONDecodingError) {
            let values: [String] = try fields.required("values")
            guard values.count <= 100 else { throw JSONDecodingError("expected at most 100 values", path: ["values"]) }
            let total: Int? = try fields.wireOptional("total")
            if let total, total < 0 { throw JSONDecodingError("expected a nonnegative integer", path: ["total"]) }
            return try CompletionResult(values: values, total: total, hasMore: fields.wireOptional("hasMore"))
        } catch { throw error.nested(in: "completion") }
    }

    static func content(_ value: JSONValue, profile: RevisionProfile) throws(JSONDecodingError) -> ContentBlock {
        let fields = try JSONObject(json: value)
        let type: String = try fields.required("type")
        let hints = try annotations(fields, profile: profile)
        let meta = try itemMetadata(fields, profile: profile)
        switch type {
        case "text": return try .text(fields.required("text"), annotations: hints, meta: meta)
        case "image":
            return try .image(data: fields.required("data"), mimeType: fields.required("mimeType"),
                              annotations: hints, meta: meta)
        case "audio":
            return try .audio(data: fields.required("data"), mimeType: fields.required("mimeType"),
                              annotations: hints, meta: meta)
        case "resource_link" where profile.structuredOutput:
            return try .resourceLink(resource(value, profile: profile))
        case "resource":
            guard let value = fields["resource"] else {
                throw JSONDecodingError("missing required field", path: ["resource"])
            }
            do { return try .resource(resourceContents(value, profile: profile), annotations: hints, meta: meta) }
            catch { throw error.nested(in: "resource") }
        default:
            throw JSONDecodingError("unsupported content type", path: ["type"])
        }
    }

    private static func title(_ fields: JSONObject, profile: RevisionProfile) throws(JSONDecodingError) -> String? {
        profile.structuredOutput ? try fields.wireOptional("title") : nil
    }

    private static func itemMetadata(
        _ fields: JSONObject, profile: RevisionProfile
    ) throws(JSONDecodingError) -> JSONObject? {
        profile.structuredOutput ? try fields.wireOptional("_meta") : fields["_meta"]?.objectValue
    }

    private static func annotations(
        _ fields: JSONObject, profile: RevisionProfile
    ) throws(JSONDecodingError) -> Annotations? {
        guard let hints = try fields.wireOptional("annotations", as: JSONObject.self) else { return nil }
        do throws(JSONDecodingError) {
            var audience: [Role]?
            if hints["audience"] != nil {
                audience = try elements(hints, "audience") { value throws(JSONDecodingError) in
                    let role = try String(json: value)
                    guard let role = Role(rawValue: role) else { throw JSONDecodingError("unknown role") }
                    return role
                }
            }
            let priority: Double? = try hints.wireOptional("priority")
            if let priority, !(0...1).contains(priority) {
                throw JSONDecodingError("expected a number between 0 and 1", path: ["priority"])
            }
            return try Annotations(
                audience: audience, priority: priority,
                lastModified: profile.annotationLastModified ? hints.wireOptional("lastModified") : nil)
        } catch { throw error.nested(in: "annotations") }
    }

    private static func icons(_ fields: JSONObject, profile: RevisionProfile) throws(JSONDecodingError) -> [Icon] {
        guard profile.icons, fields["icons"] != nil else { return [] }
        return try elements(fields, "icons") { value throws(JSONDecodingError) in
            try Icon(wire: value)
        }
    }
}
