import Foundation
import Limb
import LimbTesting
import Testing

private extension JSONValue {
    var code: Int? { self["error"]?["code"]?.intValue }
    var readText: String? { self["result"]?["contents"]?[0]?["text"]?.stringValue }
}

/// A server whose templates report what they matched: `"<template name>|k=v&k=v"`, keys sorted.
private func templateServer(_ templates: [String], resources: [String] = []) throws -> Server {
    let server = Server(name: "templates", version: "1") { $0.diagnostics = { _ in } }
    for uri in resources {
        try server.register(resource: ResourceDefinition(uri: uri, name: "fixed \(uri)")) { request, _ in
            [.text(uri: request.uri, text: "fixed:\(uri)|\(request.variables.isEmpty ? "" : "unexpected variables")")]
        }
    }
    for template in templates {
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: template)) { request, _ in
            let variables = request.variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            return [.text(uri: request.uri, text: "\(template)|\(variables)")]
        }
    }
    return server
}

@Suite struct IndependentProtocolResourcesTests {
    // MARK: Matching

    private struct Match: Sendable, CustomTestStringConvertible {
        let template: String
        let uri: String
        /// `"k=v&k=v"` for a match, `nil` for "no such resource".
        let variables: String?
        var testDescription: String { "\(template) ← \(uri)" }
    }

    /// `{var}` stands for one path segment or less: it never contains "/". `{+var}` may contain
    /// reserved characters, "/" included (RFC 6570 §3.2.2 and §3.2.3). Values reach the handler
    /// percent-decoded (doc comment of `ResourceRequest.variables`).
    private static let matches: [Match] = [
        Match(template: "t://items/{id}", uri: "t://items/42", variables: "id=42"),
        Match(template: "t://items/{id}", uri: "t://items/a-b_c.d~e", variables: "id=a-b_c.d~e"),
        Match(template: "t://items/{id}", uri: "t://items/a%20b", variables: "id=a b"),
        Match(template: "t://items/{id}", uri: "t://items/caf%C3%A9", variables: "id=café"),
        Match(template: "t://items/{id}", uri: "t://items/caf%c3%a9", variables: "id=café"),
        Match(template: "t://items/{id}", uri: "t://items/%E2%82%AC", variables: "id=€"),
        Match(template: "t://items/{id}", uri: "t://items/%F0%9F%98%80", variables: "id=😀"),
        Match(template: "t://items/{id}", uri: "t://items/a%2Fb", variables: "id=a/b"),
        Match(template: "t://items/{id}", uri: "t://items/100%25", variables: "id=100%"),
        Match(template: "t://items/{id}", uri: "t://items/a%2Bb", variables: "id=a+b"),
        Match(template: "t://items/{id}", uri: "t://items/a+b", variables: "id=a+b"),
        Match(template: "t://items/{id}", uri: "t://items/naïve", variables: "id=naïve"),
        Match(template: "t://items/{id}", uri: "t://items/a/b", variables: nil),
        Match(template: "t://items/{id}", uri: "t://items/a/", variables: nil),
        Match(template: "t://items/{id}", uri: "t://items", variables: nil),
        Match(template: "t://items/{id}", uri: "t://item/42", variables: nil),
        Match(template: "t://items/{id}", uri: "T://items/42", variables: nil),
        Match(template: "t://items/{id}", uri: "t://items/42 ", variables: "id=42 "),
        Match(template: "t://items/{id}", uri: "xt://items/42", variables: nil),
        Match(template: "t://items/{id}", uri: " t://items/42", variables: nil),
        // A literal after the variable.
        Match(template: "t://items/{id}/details", uri: "t://items/42/details", variables: "id=42"),
        Match(template: "t://items/{id}/details", uri: "t://items/42", variables: nil),
        Match(template: "t://items/{id}/details", uri: "t://items/42/details/more", variables: nil),
        Match(template: "t://items/{id}/details", uri: "t://items/a/b/details", variables: nil),
        Match(template: "t://files/{name}.json", uri: "t://files/report.json", variables: "name=report"),
        Match(template: "t://files/{name}.json", uri: "t://files/a.b.json", variables: "name=a.b"),
        Match(template: "t://files/{name}.json", uri: "t://files/report.json.json", variables: "name=report.json"),
        Match(template: "t://files/{name}.json", uri: "t://files/report.txt", variables: nil),
        Match(template: "t://files/{name}.json", uri: "t://files/dir/report.json", variables: nil),
        // Several variables.
        Match(template: "db://{table}/{id}", uri: "db://users/42", variables: "id=42&table=users"),
        Match(template: "db://{table}/{id}", uri: "db://users/42/x", variables: nil),
        Match(template: "db://{table}/{id}", uri: "db://users", variables: nil),
        Match(template: "t://{a}-{b}", uri: "t://x-y", variables: "a=x&b=y"),
        Match(template: "t://{a}-{b}", uri: "t://xy", variables: nil),
        Match(template: "t://{owner}/{repo}/issues/{number}", uri: "t://o/r/issues/7", variables: "number=7&owner=o&repo=r"),
        Match(template: "t://{owner}/{repo}/issues/{number}", uri: "t://o/r/pulls/7", variables: nil),
        // Reserved expansion.
        Match(template: "file:///{+path}", uri: "file:///a/b/c.txt", variables: "path=a/b/c.txt"),
        Match(template: "file:///{+path}", uri: "file:///a", variables: "path=a"),
        Match(template: "file:///{+path}", uri: "file:///a/b/", variables: "path=a/b/"),
        Match(template: "file:///{+path}", uri: "file:///a?b=c#d", variables: "path=a?b=c#d"),
        Match(template: "file:///{+path}", uri: "file://a/b", variables: nil),
        Match(template: "t://{+path}/meta", uri: "t://a/b/c/meta", variables: "path=a/b/c"),
        Match(template: "t://{+path}/meta", uri: "t://a/b/c", variables: nil),
        Match(template: "t://{+path}/meta", uri: "t://meta/meta/meta", variables: "path=meta/meta"),
        Match(template: "t://{bucket}/{+key}", uri: "t://b/k/e/y", variables: "bucket=b&key=k/e/y"),
        // No variables at all: a template that is one URI.
        Match(template: "t://only", uri: "t://only", variables: ""),
        Match(template: "t://only", uri: "t://only/", variables: nil),
        // Characters that mean something to a pattern language but nothing here.
        Match(template: "t://x.y/{id}", uri: "t://xzy/1", variables: nil),
        Match(template: "t://a*b/{id}", uri: "t://aaab/1", variables: nil),
        Match(template: "t://a*b/{id}", uri: "t://a*b/1", variables: "id=1"),
        Match(template: "t://(a|b)/{id}", uri: "t://a/1", variables: nil),
        Match(template: "t://q?x=1&y={id}", uri: "t://q?x=1&y=2", variables: "id=2"),
        Match(template: "t://[v6]/{id}", uri: "t://[v6]/1", variables: "id=1"),
        Match(template: "t://$^\\/{id}", uri: "t://$^\\/1", variables: "id=1"),
    ]

    @Test(arguments: matches)
    private func templatesMatchByTheirRules(_ match: Match) async throws {
        let client = TestClient(try templateServer([match.template]))
        let response = try await client.request("resources/read", ["uri": .string(match.uri)])
        if let variables = match.variables {
            #expect(response.readText == "\(match.template)|\(variables)", "\(response)")
            // The request's own URI is passed on and echoed untouched.
            #expect(response["result"]?["contents"]?[0]?["uri"] == .string(match.uri))
        } else {
            #expect(response.code == -32602, "expected no match: \(response)")
        }
    }

    /// "%" that does not start a percent-encoded octet is not an escape (RFC 3986 §2.1:
    /// `pct-encoded = "%" HEXDIG HEXDIG`). Such a URI may be refused or its text passed through
    /// as it is; what cannot happen is that characters of the URI disappear or change.
    @Test(arguments: ["%", "%zz", "%2", "%g0", "%0g", "50%off", "a%", "a%2", "%+f", "%-1", "% 1", "%%41", "%4%41", "x%zzy", "%u00e9"])
    func malformedPercentEscapesAreNotRewritten(_ value: String) async throws {
        for template in ["t://items/{id}", "t://files/{+id}"] {
            let client = TestClient(try templateServer([template]))
            let uri = String(template.prefix { $0 != "{" }) + value
            let response = try await client.request("resources/read", ["uri": .string(uri)])
            if response["result"] != nil {
                // "%%41" and "%4%41" contain one real escape, "%41" = "A".
                let acceptable: Set<String> = [value, value.replacingOccurrences(of: "%41", with: "A")]
                let seen = String((response.readText ?? "").dropFirst("\(template)|id=".count))
                #expect(acceptable.contains(seen), "\(uri) reached the handler as \(seen.debugDescription)")
            } else {
                #expect(response.code == -32602, "\(response)")
            }
        }
    }

    /// A resource that is listed is the one that is read: an exact URI wins over a template that
    /// also matches it, whichever was registered first.
    @Test func aFixedResourceWinsOverAMatchingTemplate() async throws {
        for templateFirst in [true, false] {
            let server = Server(name: "precedence", version: "1")
            let registerTemplate = {
                try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "t://items/{id}", name: "template")) { request, _ in
                    [.text(uri: request.uri, text: "template \(request.variables["id"] ?? "")")]
                }
            }
            if templateFirst { try registerTemplate() }
            try server.register(resource: ResourceDefinition(uri: "t://items/special", name: "special")) { request, _ in
                [.text(uri: request.uri, text: "the fixed resource")]
            }
            if !templateFirst { try registerTemplate() }
            let client = TestClient(server)
            #expect(try await client.request("resources/read", ["uri": "t://items/special"]).readText == "the fixed resource")
            #expect(try await client.request("resources/read", ["uri": "t://items/other"]).readText == "template other")
            // Listed where it belongs: the fixed one among resources, the template among templates.
            #expect(try await client.request("resources/list")["result"]?["resources"]?.arrayValue?.map { $0["uri"] } == ["t://items/special"])
            #expect(try await client.request("resources/templates/list")["result"]?["resourceTemplates"]?.arrayValue?.map { $0["uriTemplate"] } == ["t://items/{id}"])
        }
    }

    /// Observed, unspecified: when two templates match one URI the specification does not say
    /// which is read. Limb takes the one registered first; the test pins that it is at least
    /// deterministic and independent of the request order.
    @Test func overlappingTemplatesResolveDeterministically() async throws {
        let server = try templateServer(["t://{kind}/{id}", "t://items/{id}", "t://{+rest}"])
        let client = TestClient(server)
        var seen: Set<String> = []
        for _ in 0..<5 {
            seen.insert(try #require(try await client.request("resources/read", ["uri": "t://items/7"]).readText))
            _ = try await client.request("resources/read", ["uri": "t://a/b/c"])
        }
        #expect(seen == ["t://{kind}/{id}|id=7&kind=items"])
        #expect(try await client.request("resources/read", ["uri": "t://a/b/c"]).readText == "t://{+rest}|rest=a/b/c")
    }

    // MARK: Registration

    /// Only `{name}` and `{+name}` are implemented; a template using anything else of RFC 6570
    /// is refused at registration rather than silently matched as something it is not.
    @Test func unsupportedTemplatesAreRefusedAtRegistration() throws {
        let unsupported = [
            "t://{", "t://{}", "t://{+}", "t://{id", "t://{{id}}", "t://{?query}", "t://{&more}", "t://{#fragment}", "t://{/path}", "t://{.ext}",
            "t://{;params}", "t://{a,b}", "t://{id*}", "t://{id:3}", "t://{i d}", "t://{i-d}", "t://{+a,b}", "t://{=x}", "t://{!x}", "t://{|x}",
        ]
        for template in unsupported {
            let server = Server(name: "templates", version: "1")
            let error = #expect(throws: RegistrationError.self, "\(template) was accepted") {
                try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: "x")) { _, _ in [] }
            }
            #expect(error?.description.contains(template) == true, "\(String(describing: error))")
        }
        let supported = ["t://{id}", "t://{+path}", "t://{a}/{b}", "t://{a_b}", "t://{A1}", "t://literal", "{scheme}://x", "t://{id}.json"]
        for template in supported {
            let server = Server(name: "templates", version: "1")
            #expect(throws: Never.self, "\(template) was refused") {
                try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: "x")) { _, _ in [] }
            }
        }
    }

    @Test func duplicatesAreRefusedAndChangeNothing() async throws {
        let server = try templateServer(["t://items/{id}"], resources: ["t://fixed"])
        let client = try await IndependentProtocol.client(server, .r2025_11_25)
        _ = try await IndependentProtocol.drain(client)
        let resourceError = #expect(throws: RegistrationError.self) {
            try server.register(resource: ResourceDefinition(uri: "t://fixed", name: "again")) { request, _ in [.text(uri: request.uri, text: "impostor")] }
        }
        #expect(resourceError?.description.contains("t://fixed") == true)
        let templateError = #expect(throws: RegistrationError.self) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: "t://items/{id}", name: "again")) { request, _ in
                [.text(uri: request.uri, text: "impostor")]
            }
        }
        #expect(templateError?.description.contains("t://items/{id}") == true)
        // The originals still answer, the listings are unchanged, and no list_changed went out.
        #expect(try await client.request("resources/read", ["uri": "t://fixed"]).readText == "fixed:t://fixed|")
        #expect(try await client.request("resources/read", ["uri": "t://items/1"]).readText == "t://items/{id}|id=1")
        #expect(try await client.request("resources/list")["result"]?["resources"]?.arrayValue?.count == 1)
        #expect(try await client.request("resources/templates/list")["result"]?["resourceTemplates"]?.arrayValue?.count == 1)
        #expect(client.received.isEmpty, "\(client.received)")
    }

    // MARK: resources/read: the request and the result

    @Test(arguments: IndependentProtocolRevision.allCases)
    func malformedReadsAreInvalidParams(_ revision: IndependentProtocolRevision) async throws {
        let recorder = IndependentProtocolRecorder()
        let client = try await IndependentProtocol.client(try IndependentProtocolRich.server(recorder: recorder), revision)
        let meta = revision.isModern ? IndependentProtocol.modernMetaText : ""
        for body in ["", #""uri":5"#, #""uri":null"#, #""uri":["rich://static"]"#, #""uri":{"uri":"rich://static"}"#, #""uri":true"#, #""URI":"rich://static""#, #""name":"static""#] {
            let params = [meta, body].filter { !$0.isEmpty }.joined(separator: ",")
            let reply = try await IndependentProtocol.reply(client, #"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{\#(params)}}"#)
            #expect(reply.code == -32602, "\(revision.rawValue) {\(body)}: \(reply)")
        }
        #expect(recorder.entries.isEmpty)
    }

    /// Text and binary contents, several per result, each with or without a MIME type; the bytes
    /// of a blob come back as the same bytes.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func textAndBlobContents(_ revision: IndependentProtocolRevision) async throws {
        let samples: [[UInt8]] = [[], [0x00], [0xFF, 0xFE], [1, 2, 3], Array(0...255), Array(repeating: 7, count: 4097)]
        let server = Server(name: "contents", version: "1")
        try server.register(resource: ResourceDefinition(uri: "c://mixed", name: "mixed")) { request, _ in
            var contents: [ResourceContents] = [
                .text(uri: request.uri, mimeType: "text/markdown", text: "# Title\n\nBody with \"quotes\" and \u{2028}."),
                .text(uri: request.uri + "#no-type", text: ""),
            ]
            for sample in samples {
                contents.append(.blob(uri: "c://blob/\(sample.count)", mimeType: "application/octet-stream", bytes: sample))
            }
            contents.append(.blob(uri: "c://blob/untyped", base64: "aGk="))
            return contents
        }
        let client = try await IndependentProtocol.client(server, revision)
        let response = try await client.request("resources/read", ["uri": "c://mixed"])
        let violations = IndependentProtocol.responseViolations(response, to: "resources/read", in: revision)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        let contents = try #require(response["result"]?["contents"]?.arrayValue)
        #expect(contents.count == samples.count + 3)
        #expect(contents[0].independentKeys == ["mimeType", "text", "uri"])
        #expect(contents[0]["text"] == "# Title\n\nBody with \"quotes\" and \u{2028}.")
        #expect(contents[0]["mimeType"] == "text/markdown")
        // No MIME type given: the member is absent, not null or empty. An empty text is still a text.
        #expect(contents[1].independentKeys == ["text", "uri"])
        #expect(contents[1]["text"] == "")
        for (index, sample) in samples.enumerated() {
            let item = contents[index + 2]
            #expect(item.independentKeys == ["blob", "mimeType", "uri"], "\(item)")
            let encoded = try #require(item["blob"]?.stringValue)
            #expect(Data(base64Encoded: encoded) == Data(sample), "\(sample.count) bytes")
            #expect(item["uri"] == .string("c://blob/\(sample.count)"))
        }
        #expect(contents[samples.count + 2].independentKeys == ["blob", "uri"])
        #expect(contents[samples.count + 2]["blob"] == "aGk=")
    }

    /// A fixed resource has no variables; a template's variables do not leak into the next read.
    @Test func variablesBelongToOneRead() async throws {
        let server = try templateServer(["t://{a}/{b}", "t://{only}"], resources: ["t://fixed"])
        let client = TestClient(server)
        #expect(try await client.request("resources/read", ["uri": "t://x/y"]).readText == "t://{a}/{b}|a=x&b=y")
        #expect(try await client.request("resources/read", ["uri": "t://fixed"]).readText == "fixed:t://fixed|")
        #expect(try await client.request("resources/read", ["uri": "t://z"]).readText == "t://{only}|only=z")
        #expect(try await client.request("resources/read", ["uri": "t://p/q"]).readText == "t://{a}/{b}|a=p&b=q")
    }

    /// The listings contain what was registered and nothing else: fixed resources in one,
    /// templates in the other, each in registration order.
    @Test(arguments: IndependentProtocolRevision.allCases)
    func listingsSeparateResourcesFromTemplates(_ revision: IndependentProtocolRevision) async throws {
        let server = try templateServer(["t://b/{x}", "t://a/{x}", "t://{+c}"], resources: ["t://z", "t://y", "t://x"])
        let client = try await IndependentProtocol.client(server, revision)
        let resources = try #require(try await client.request("resources/list")["result"])
        #expect(resources["resources"]?.arrayValue?.map { $0["uri"] } == ["t://z", "t://y", "t://x"])
        #expect(resources["resourceTemplates"] == nil)
        let templates = try #require(try await client.request("resources/templates/list")["result"])
        #expect(templates["resourceTemplates"]?.arrayValue?.map { $0["uriTemplate"] } == ["t://b/{x}", "t://a/{x}", "t://{+c}"])
        #expect(templates["resources"] == nil)
    }
}

private extension JSONValue {
    var independentKeys: [String] { objectValue?.map(\.key).sorted() ?? [] }
}
