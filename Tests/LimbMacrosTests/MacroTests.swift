import Limb
import LimbTesting
import Testing

/// Units of measurement.
@Schema
enum Units: String {
    case metric
    case imperial = "us"
}

/// A weather forecast.
@Schema
struct Forecast {
    /// Temperature in the requested units.
    var temperature: Double
    var conditions: String
    /// Chance of rain, 0 to 1.
    var rain: Double?
    var tags: [String] = []
    var units: Units
    static let version = 1
    var summary: String { "\(conditions), \(temperature)" }
}

struct WeatherService: Sendable {
    func forecast(for location: String, units: Units) -> Forecast {
        Forecast(temperature: units == .metric ? 21.5 : 70.7, conditions: "Clear in \(location)", rain: nil, tags: ["calm"], units: units)
    }
}

/// Current weather for a location.
///
/// Uses the nearest station.
@Tool(readOnly: true, openWorld: true)
struct Weather {
    let service: WeatherService

    /// - Parameters:
    ///   - location: City name or coordinates.
    ///   - units: Units of measurement.
    ///   - days: How many days ahead.
    func call(location: String, units: Units = .metric, days: Int? = nil, context: ToolContext) async throws -> Forecast {
        context.progress(1, total: 1)
        return service.forecast(for: location, units: units)
    }
}

@Tool("shout", title: "Shout")
struct Uppercase {
    /// Upper-cases text.
    /// - Parameter text: What to shout.
    func call(_ text: String) -> String {
        text.uppercased()
    }
}

@Tool
struct Ping {
    func call() {}
}

@Tool
struct Tally {
    func call(values: [Int], labels: [String: String] = [:]) throws -> [ContentBlock] {
        guard !values.isEmpty else { throw ToolError("nothing to add") }
        return [.text("\(values.reduce(0, +))"), .text(labels.keys.sorted().joined(separator: ","))]
    }
}

@Suite struct MacroTests {
    @Test func schemaIsDerivedFromTheDeclaration() {
        let schema = Forecast.jsonSchema
        #expect(schema["type"] == "object")
        #expect(schema["description"] == "A weather forecast.")
        #expect(schema["required"] == ["temperature", "conditions", "units"])
        let properties = schema["properties"]
        #expect(properties?.objectValue?.map(\.key) == ["temperature", "conditions", "rain", "tags", "units"])
        #expect(properties?["temperature"] == ["type": "number", "description": "Temperature in the requested units."])
        #expect(properties?["rain"]?["description"] == "Chance of rain, 0 to 1.")
        #expect(properties?["tags"] == ["type": "array", "items": ["type": "string"]])
        #expect(properties?["units"] == ["type": "string", "enum": ["metric", "us"], "description": "Units of measurement."])
    }

    @Test func schemaTypesRoundTrip() throws {
        let forecast = try Forecast(json: ["temperature": 3, "conditions": "Snow", "units": "us"])
        #expect(forecast.temperature == 3)
        #expect(forecast.rain == nil)
        #expect(forecast.tags == [])
        #expect(forecast.units == .imperial)
        #expect(forecast.jsonValue == ["temperature": 3.0, "conditions": "Snow", "tags": [], "units": "us"])
        #expect(try JSONSchema(.object(Forecast.jsonSchema)).validate(forecast.jsonValue) == nil)
        #expect(throws: JSONDecodingError.self) { try Forecast(json: ["temperature": "warm", "conditions": "x", "units": "metric"]) }
        #expect(throws: JSONDecodingError.self) { try Units(json: "kelvin") }
    }

    @Test func toolDefinitionIsDerivedFromTheDeclaration() {
        let definition = Weather.definition
        #expect(definition.name == "weather")
        #expect(definition.description == "Current weather for a location.\n\nUses the nearest station.")
        #expect(definition.annotations == ToolAnnotations(readOnlyHint: true, openWorldHint: true))
        #expect(definition.inputSchema["required"] == ["location"])
        let properties = definition.inputSchema["properties"]
        #expect(properties?.objectValue?.map(\.key) == ["location", "units", "days"])
        #expect(properties?["location"] == ["type": "string", "description": "City name or coordinates."])
        #expect(properties?["days"] == ["anyOf": [["type": "integer"], ["type": "null"]], "description": "How many days ahead."])
        #expect(definition.outputSchema == Forecast.jsonSchema)

        #expect(Uppercase.definition.name == "shout")
        #expect(Uppercase.definition.title == "Shout")
        #expect(Uppercase.definition.description == "Upper-cases text.")
        #expect(Uppercase.definition.inputSchema["properties"]?["text"]?["description"] == "What to shout.")
        #expect(Uppercase.definition.outputSchema == nil)
        #expect(Ping.definition.name == "ping")
        #expect(Tally.definition.inputSchema["properties"]?["labels"] == ["type": "object", "additionalProperties": ["type": "string"]])
    }

    @Test func toolsRunThroughTheServer() async throws {
        let server = try Server(name: "macro-fixture", version: "1.0.0") {
            Weather(service: WeatherService())
            Uppercase()
            Ping()
            Tally()
        }
        let client = TestClient(server)
        let names = try await client.request("tools/list").result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["weather", "shout", "ping", "tally"])

        let weather = try #require(
            try await client.request("tools/call", ["name": "weather", "arguments": ["location": "Oslo", "units": "us"]]).result)
        #expect(weather["structuredContent"] == ["temperature": 70.7, "conditions": "Clear in Oslo", "tags": ["calm"], "units": "us"])
        #expect(weather["isError"] == false)

        let defaulted = try await client.request("tools/call", ["name": "weather", "arguments": ["location": "Oslo"]])
        #expect(defaulted.result?["structuredContent"]?["units"] == "metric")

        // Arguments are checked against the derived schema before the tool runs.
        let invalid = try await client.request("tools/call", ["name": "weather", "arguments": ["location": "Oslo", "units": "kelvin"]])
        #expect(invalid.result?["isError"] == true)
        #expect(invalid.firstText?.contains("units") == true)
        let missing = try await client.request("tools/call", ["name": "weather", "arguments": [:]])
        #expect(missing.firstText?.contains("location: missing required field") == true)

        #expect(try await client.request("tools/call", ["name": "shout", "arguments": ["text": "hey"]]).firstText == "HEY")
        #expect(try await client.request("tools/call", ["name": "ping"]).result?["content"] == [])
        let tally = try await client.request("tools/call", ["name": "tally", "arguments": ["values": [1, 2, 3], "labels": ["b": "x", "a": "y"]]])
        #expect(tally.result?["content"]?[0]?["text"] == "6")
        #expect(tally.result?["content"]?[1]?["text"] == "a,b")
        let empty = try await client.request("tools/call", ["name": "tally", "arguments": ["values": []]])
        #expect(empty.result?["isError"] == true)
        #expect(empty.firstText == "nothing to add")
    }
}

extension JSONValue {
    var result: JSONValue? { self["result"] }
    var firstText: String? { self["result"]?["content"]?[0]?["text"]?.stringValue }
}
