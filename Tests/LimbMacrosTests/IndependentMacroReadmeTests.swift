import Limb
import LimbTesting
import Synchronization
import Testing


private enum IMReadme {
    final class WeatherService: Sendable {
        let calls = Mutex(0)
        func forecast(for location: String, units: Units) async throws -> Forecast {
            calls.withLock { $0 += 1 }
            return Forecast(temperature: units == .metric ? 21.5 : 70.7, conditions: "Ясно, \(location)")
        }
    }

    /// Единицы измерения.
    @Schema
    enum Units: String { case metric, imperial }

    /// Прогноз погоды.
    @Schema
    struct Forecast {
        /// Температура в запрошенных единицах.
        var temperature: Double
        var conditions: String
    }

    /// Текущая погода в указанном месте.
    @Tool(readOnly: true, openWorld: true)
    struct Weather {
        let service: WeatherService            // зависимость инструмента, а не аргумент

        /// - Parameters:
        ///   - location: Город или координаты.
        ///   - units: Единицы измерения.
        func call(location: String, units: Units = .metric, context: ToolContext) async throws -> Forecast {
            try await service.forecast(for: location, units: units)
        }
    }
}

@Suite struct IndependentMacroReadmeTests {
    /// "Из одного объявления выводятся имя `weather`, описание из `///`, входная и выходная
    /// JSON-схемы".
    @Test func everythingIsDerivedFromTheOneDeclaration() async throws {
        let server = try Server(name: "weather", version: "1.0.0") {
            IMReadme.Weather(service: IMReadme.WeatherService())
        }
        let client = TestClient(server)
        let tools = try await client.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool["name"] == "weather")
        #expect(tool["description"] == "Текущая погода в указанном месте.")
        #expect(
            tool["inputSchema"]
                == [
                    "type": "object",
                    "properties": [
                        "location": ["type": "string", "description": "Город или координаты."],
                        "units": ["type": "string", "enum": ["metric", "imperial"], "description": "Единицы измерения."],
                    ],
                    "required": ["location"],
                ])
        #expect(
            tool["outputSchema"]
                == [
                    "type": "object",
                    "description": "Прогноз погоды.",
                    "properties": [
                        "temperature": ["type": "number", "description": "Температура в запрошенных единицах."],
                        "conditions": ["type": "string"],
                    ],
                    "required": ["temperature", "conditions"],
                ])
        #expect(tool["annotations"] == ["readOnlyHint": true, "openWorldHint": true])
        if let schema = tool["inputSchema"]?.objectValue { IndependentMacroCheckSchema(schema) }
        if let schema = tool["outputSchema"]?.objectValue { IndependentMacroCheckSchema(schema) }
    }

    /// "…декодирование аргументов и кодирование результата."
    @Test func argumentsAreDecodedAndTheResultEncoded() async throws {
        let service = IMReadme.WeatherService()
        let server = try Server(name: "weather", version: "1.0.0") {
            IMReadme.Weather(service: service)
        }
        let client = TestClient(server)
        let metric = try await client.request("tools/call", ["name": "weather", "arguments": ["location": "Осло"]])
        #expect(metric["result"]?["structuredContent"] == ["temperature": 21.5, "conditions": "Ясно, Осло"])
        #expect(metric["result"]?["isError"] == false)
        let imperial = try await client.request("tools/call", ["name": "weather", "arguments": ["location": "Oslo", "units": "imperial"]])
        #expect(imperial["result"]?["structuredContent"] == ["temperature": 70.7, "conditions": "Ясно, Oslo"])
        #expect(service.calls.withLock { $0 } == 2)
    }

    /// "Аргументы проверяются по схеме до вызова обработчика".
    @Test func argumentsAreValidatedBeforeTheHandlerRuns() async throws {
        let service = IMReadme.WeatherService()
        let server = try Server(name: "weather", version: "1.0.0") {
            IMReadme.Weather(service: service)
        }
        let client = TestClient(server)
        let bad: [JSONValue] = [
            [:], ["units": "metric"], ["location": 1], ["location": nil], ["location": "Oslo", "units": "kelvin"],
            ["location": "Oslo", "units": 1], ["location": ["Oslo"]],
        ]
        for arguments in bad {
            let response = try await client.request("tools/call", ["name": "weather", "arguments": arguments])
            #expect(response["result"]?["isError"] == true, "\(arguments): \(response)")
            let text = response.independentMacroFirstText ?? ""
            #expect(text.contains("location") || text.contains("units"), "\(arguments): \(text)")
        }
        #expect(service.calls.withLock { $0 } == 0, "the handler ran for invalid arguments")
    }
}
