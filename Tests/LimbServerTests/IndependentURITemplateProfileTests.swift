import Limb
@testable import LimbServer
import LimbTesting
import Testing

@Suite struct IndependentURITemplateProfileTests {
    private static func client(for template: String) throws -> TestClient {
        let server = Server(name: "URI template profile", version: "1")
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: "example")) { request, _ in
            let variables = request.variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return [.text(uri: request.uri, text: variables.joined(separator: "|"))]
        }
        return TestClient(server, modern: true)
    }

    private static func expectRead(_ client: TestClient, uri: String, variables: String) async throws {
        let response = try await client.request("resources/read", ["uri": .string(uri)])
        let content = try #require(response["result"]?["contents"]?[0], "\(uri): \(response)")
        #expect(content["uri"] == .string(uri))
        #expect(content["text"] == .string(variables))
    }

    // Fixed examples from RFC 6570 sections 3.2.2 and 3.2.3, with an absolute URI prefix.
    @Test(arguments: [
        ("/{var}", "/value", "var=value"),
        ("/{hello}", "/Hello%20World%21", "hello=Hello World!"),
        ("/{+hello}", "/Hello%20World!", "hello=Hello World!"),
        ("{+path}/here", "/foo/bar/here", "path=/foo/bar"),
    ])
    func readsThePublishedExpansionExamples(_ template: String, _ expansion: String, _ variables: String) async throws {
        let prefix = "example://docs"
        let client = try Self.client(for: prefix + template)
        try await Self.expectRead(client, uri: prefix + expansion, variables: variables)
    }

    // Controls for the simple and reserved expressions in RFC 6570 sections 3.2.2 and 3.2.3.
    @Test func simpleExpressionDecodesAnEncodedSegmentBetweenLiterals() async throws {
        let client = try Self.client(for: "example://docs/archive-{title}.txt")
        try await Self.expectRead(client, uri: "example://docs/archive-caf%C3%A9%2Fmenu.txt", variables: "title=café/menu")

        for uri in ["example://docs/archive-cafe/menu.txt", "example://docs/archive-cafe.txt.bak"] {
            let response = try await client.request("resources/read", ["uri": .string(uri)])
            #expect(response["error"]?["code"]?.intValue == -32602, "\(uri): \(response)")
        }
    }

    @Test func reservedExpressionIncludesPathSeparators() async throws {
        let client = try Self.client(for: "example://docs/{+path}/index")
        try await Self.expectRead(client, uri: "example://docs/summer/caf%c3%a9/index", variables: "path=summer/café")
    }

    @Test func multipleNonemptySplitsKeepTheGreedyMatch() async throws {
        let client = try Self.client(for: "example://docs/{series}-{edition}")
        try await Self.expectRead(client, uri: "example://docs/travel-north-2", variables: "edition=2|series=travel-north")
    }

    @Test func adjacentExpressionsKeepTheGreedyMatch() async throws {
        let client = try Self.client(for: "example://docs/revision-{major}{minor}")
        try await Self.expectRead(client, uri: "example://docs/revision-123", variables: "major=12|minor=3")
    }

    // RFC 6570 section 2.3 permits dots between name characters.
    @Test func dottedNamesReachTheHandlerUnderTheirFullName() async throws {
        let template = "example://docs/{book.ID}/{+edition.path}"
        let client = try Self.client(for: template)
        let listed = try await client.request("resources/templates/list")
        #expect(listed["result"]?["resourceTemplates"]?[0]?["uriTemplate"] == .string(template))
        try await Self.expectRead(client, uri: "example://docs/42/first/print", variables: "book.ID=42|edition.path=first/print")
    }

    // RFC 6570 section 2.3 distinguishes defined empty strings from undefined values.
    // The inverse mapping binds a defined empty string when the literals require that capture.
    @Test(arguments: ["example://docs/O{empty}X", "example://docs/O{+empty}X"])
    func uniquelyEmptyCaptureReachesTheHandler(_ template: String) async throws {
        let client = try Self.client(for: template)
        try await Self.expectRead(client, uri: "example://docs/OX", variables: "empty=")
    }

    @Test func delimitersDetermineAnEmptyCaptureAmongSeveralVariables() async throws {
        let client = try Self.client(for: "example://docs/{series}/{edition}/index")
        try await Self.expectRead(client, uri: "example://docs/travel//index", variables: "edition=|series=travel")
    }

    @Test func emptyCaptureDoesNotReplaceAnAvailableNonemptySplit() async throws {
        let client = try Self.client(for: "example://docs/{series}-{edition}")
        try await Self.expectRead(client, uri: "example://docs/travel-2-", variables: "edition=2-|series=travel")
    }

    @Test func interiorLiteralsUseOrderedNonoverlappingMatches() async throws {
        let client = try Self.client(for: "example://docs/{left}aba{middle}bab{right}")
        try await Self.expectRead(client, uri: "example://docs/ababab", variables: "left=|middle=|right=")
    }

    @Test func localMatchBudgetAllowsTheExactWork() throws {
        let template = try #require(URITemplate("example://docs/{title}.txt"))
        let bytes = Array("example://docs/guide.txt".utf8)
        let initialBudget = 4_096
        var remaining = initialBudget
        let reference = try template.match(bytes, budget: &remaining)
        #expect(reference == ["title": "guide"])
        let consumed = initialBudget - remaining
        try #require(consumed > 0)

        var exactBudget = consumed
        let exact = try template.match(bytes, budget: &exactBudget)
        #expect(exact == reference)
        #expect(exactBudget == 0)

        var insufficientBudget = consumed - 1
        do {
            _ = try template.match(bytes, budget: &insufficientBudget)
            Issue.record("Matching succeeded with one work unit below the required budget.")
        } catch {
            #expect(error.code == MCPError.Code.overloaded)
        }
    }

    @Test(arguments: ["{?query}", "{name:3}", "{first,last}", "{book..id}", "{book.}"])
    func expressionsOutsideTheProfileFailRegistration(_ expression: String) {
        let server = Server(name: "URI template registration", version: "1")
        let template = "example://docs/" + expression
        #expect(throws: RegistrationError.self) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: template, name: "example")) { _, _ in [] }
        }
    }

    @Test func registrationEnforcesTheTemplateByteLimit() throws {
        let server = Server(name: "URI template registration", version: "1")
        let prefix = "example://docs/"
        let maximum = prefix + String(repeating: "a", count: 4_096 - prefix.utf8.count)
        try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: maximum, name: "maximum")) { _, _ in [] }
        #expect(throws: RegistrationError.self) {
            try server.register(resourceTemplate: ResourceTemplateDefinition(uriTemplate: maximum + "a", name: "over limit")) { _, _ in [] }
        }
    }
}
