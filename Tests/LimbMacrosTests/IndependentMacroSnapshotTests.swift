import Testing


@Suite struct IndependentMacroSnapshotTests {
    @Test func schemaStruct() {
        IndependentMacroAssertExpansion(
            #"""
            /// A weather forecast.
            @Schema
            struct Forecast {
                /// Temperature in the requested units.
                var temperature: Double
                let conditions: String
                /// Chance of rain, 0 to 1.
                var rain: Double?
                var tags: [String] = []
                var units: Units
                static let version = 1
                var summary: String { conditions }
            }
            """#,
            expands: #"""
            /// A weather forecast.
            struct Forecast {
                /// Temperature in the requested units.
                var temperature: Double
                let conditions: String
                /// Chance of rain, 0 to 1.
                var rain: Double?
                var tags: [String] = []
                var units: Units
                static let version = 1
                var summary: String { conditions }
            }

            extension Forecast: LimbCore.SchemaRepresentable {
                static func jsonSchema(in __limbOuter: inout LimbCore.SchemaBuilder) -> LimbCore.JSONObject {
                    __limbOuter.named(Self.self) { __limbBuilder in
                        var __limbFields = LimbCore.SchemaSupport.Fields()
                        __limbFields.add("temperature", \Self.temperature, description: "Temperature in the requested units.", hasDefault: false, in: &__limbBuilder)
                        __limbFields.add("conditions", \Self.conditions, description: nil, hasDefault: false, in: &__limbBuilder)
                        __limbFields.add("rain", \Self.rain, description: "Chance of rain, 0 to 1.", hasDefault: false, in: &__limbBuilder)
                        __limbFields.add("tags", \Self.tags, description: nil, hasDefault: true, in: &__limbBuilder)
                        __limbFields.add("units", \Self.units, description: nil, hasDefault: false, in: &__limbBuilder)
                        return __limbFields.schema(description: "A weather forecast.")
                    }
                }

                init(json __limbJSON: LimbCore.JSONValue) throws(LimbCore.JSONDecodingError) {
                    let __limbObject = try LimbCore.JSONObject(json: __limbJSON)
                    self.temperature = try LimbCore.SchemaSupport.decode(__limbObject, "temperature")
                    self.conditions = try LimbCore.SchemaSupport.decode(__limbObject, "conditions")
                    self.rain = try LimbCore.SchemaSupport.decode(__limbObject, "rain")
                    if let __limbValue = try LimbCore.SchemaSupport.decodeIfPresent(__limbObject, "tags", for: \Self.tags) {
                        self.tags = __limbValue
                    }
                    self.units = try LimbCore.SchemaSupport.decode(__limbObject, "units")
                }

                var jsonValue: LimbCore.JSONValue {
                    var __limbObject = LimbCore.JSONObject(minimumCapacity: 5)
                    LimbCore.SchemaSupport.set(&__limbObject, "temperature", self.temperature)
                    LimbCore.SchemaSupport.set(&__limbObject, "conditions", self.conditions)
                    LimbCore.SchemaSupport.set(&__limbObject, "rain", self.rain)
                    LimbCore.SchemaSupport.set(&__limbObject, "tags", self.tags, includeNil: true)
                    LimbCore.SchemaSupport.set(&__limbObject, "units", self.units)
                    return .object(__limbObject)
                }

                func jsonValue(maxDepth __limbDepth: Swift.Int) throws(LimbCore.JSONEncodingDepthError) -> LimbCore.JSONValue {
                    guard __limbDepth > 0 else {
                        throw LimbCore.JSONEncodingDepthError()
                    }
                    var __limbObject = LimbCore.JSONObject(minimumCapacity: 5)
                    try LimbCore.SchemaSupport.set(&__limbObject, "temperature", self.temperature, maxDepth: __limbDepth - 1)
                    try LimbCore.SchemaSupport.set(&__limbObject, "conditions", self.conditions, maxDepth: __limbDepth - 1)
                    try LimbCore.SchemaSupport.set(&__limbObject, "rain", self.rain, maxDepth: __limbDepth - 1)
                    try LimbCore.SchemaSupport.set(&__limbObject, "tags", self.tags, includeNil: true, maxDepth: __limbDepth - 1)
                    try LimbCore.SchemaSupport.set(&__limbObject, "units", self.units, maxDepth: __limbDepth - 1)
                    return .object(__limbObject)
                }
            }
            """#)
    }

    @Test func publicSchemaEnum() {
        IndependentMacroAssertExpansion(
            #"""
            /// Units of measurement.
            @Schema
            public enum Units: String {
                case metric
                case imperial = "us", `default`
            }
            """#,
            expands: #"""
            /// Units of measurement.
            public enum Units: String {
                case metric
                case imperial = "us", `default`
            }

            extension Units: LimbCore.SchemaRepresentable {
                public static func jsonSchema(in __limbBuilder: inout LimbCore.SchemaBuilder) -> LimbCore.JSONObject {
                    var __limbSchema: LimbCore.JSONObject = ["type": "string", "enum": ["metric", "us", "default"]]
                    __limbSchema["description"] = .string("Units of measurement.")
                    return __limbSchema
                }

                public init(json __limbJSON: LimbCore.JSONValue) throws(LimbCore.JSONDecodingError) {
                    // `init(rawValue:)` compares by canonical equivalence; JSON strings are equal
                    // only when they are the same bytes.
                    guard case .string(let __limbRaw) = __limbJSON, let __limbValue = Self(rawValue: __limbRaw),
                        __limbValue.rawValue.isBytewiseEqual(to: __limbRaw)
                    else {
                        throw LimbCore.JSONDecodingError("expected one of: metric, us, default")
                    }
                    self = __limbValue
                }

                public var jsonValue: LimbCore.JSONValue {
                    .string(self.rawValue)
                }
            }
            """#)
    }

    @Test func toolWithEverything() {
        IndependentMacroAssertExpansion(
            #"""
            /// Current weather for a location.
            ///
            /// Uses the nearest station.
            @Tool(readOnly: true, openWorld: true)
            struct WeatherLookup {
                let service: WeatherService

                /// - Parameters:
                ///   - location: City name or coordinates.
                ///   - units: Units of measurement.
                func call(location: String, units: Units = .metric, days: Int? = nil, context: ToolContext) async throws -> Forecast {
                    try await service.forecast(for: location, units: units)
                }
            }
            """#,
            expands: #"""
            /// Current weather for a location.
            ///
            /// Uses the nearest station.
            struct WeatherLookup {
                let service: WeatherService

                /// - Parameters:
                ///   - location: City name or coordinates.
                ///   - units: Units of measurement.
                func call(location: String, units: Units = .metric, days: Int? = nil, context: ToolContext) async throws -> Forecast {
                    try await service.forecast(for: location, units: units)
                }

                static var definition: LimbCore.ToolDefinition {
                    var __limbBuilder = LimbCore.SchemaBuilder()
                    var __limbFields = LimbCore.SchemaSupport.Fields()
                    __limbFields.add("location", (String).self, description: "City name or coordinates.", hasDefault: false, in: &__limbBuilder)
                    __limbFields.add("units", (Units).self, description: "Units of measurement.", hasDefault: true, in: &__limbBuilder)
                    __limbFields.add("days", (Int?).self, description: nil, hasDefault: true, in: &__limbBuilder)
                    return LimbCore.ToolDefinition(
                        name: "weather_lookup",
                        title: nil,
                        description: "Current weather for a location.\n\nUses the nearest station.",
                        inputSchema: __limbBuilder.finish(__limbFields.schema(description: nil)),
                        outputSchema: LimbServer.ToolSupport.outputSchema((Forecast).self),
                        annotations: LimbCore.ToolAnnotations(readOnlyHint: true, openWorldHint: true))
                }

                func call(
                    arguments __limbArguments: LimbCore.JSONObject, context __limbContext: LimbServer.RequestContext
                ) async throws -> LimbCore.ToolResult {
                    let __limbArgument0: String
                    let __limbArgument1: Units
                    let __limbArgument2: Int?
                    do throws(LimbCore.JSONDecodingError) {
                        __limbArgument0 = try LimbCore.SchemaSupport.decode(__limbArguments, "location")
                    __limbArgument1 = try LimbCore.SchemaSupport.decode(__limbArguments, "units", default: Self.__macro_local_11limbDefaultfMu_())
                    __limbArgument2 = try LimbCore.SchemaSupport.decode(__limbArguments, "days", default: Self.__macro_local_11limbDefaultfMu0_())
                    } catch {
                        throw LimbServer.ToolSupport.invalidArguments(error)
                    }
                    return try LimbServer.ToolSupport.result(await self.call(location: __limbArgument0, units: __limbArgument1, days: __limbArgument2, context: __limbContext), context: __limbContext)
                }

                private static func __macro_local_11limbDefaultfMu_() -> Units {
                    (.metric)
                }

                private static func __macro_local_11limbDefaultfMu0_() -> Int? {
                    (nil)
                }
            }

            extension WeatherLookup: LimbServer.MCPTool {
            }
            """#)
    }

    @Test func toolWithoutArguments() {
        IndependentMacroAssertExpansion(
            #"""
            /// Answers.
            @Tool
            struct Ping {
                func call() {}
            }
            """#,
            expands: #"""
            /// Answers.
            struct Ping {
                func call() {}

                static var definition: LimbCore.ToolDefinition {

                    return LimbCore.ToolDefinition(
                        name: "ping",
                        title: nil,
                        description: "Answers.",
                        inputSchema: LimbCore.SchemaSupport.Fields().schema(description: nil),
                        outputSchema: nil,
                        annotations: nil)
                }

                func call(
                    arguments __limbArguments: LimbCore.JSONObject, context __limbContext: LimbServer.RequestContext
                ) async throws -> LimbCore.ToolResult {

                    self.call()
                    return LimbCore.ToolResult()
                }
            }

            extension Ping: LimbServer.MCPTool {
            }
            """#)
    }

    @Test func publicToolWithExplicitNameAndUnlabeledParameter() {
        IndependentMacroAssertExpansion(
            #"""
            @Tool("shout", title: "Shout", destructive: false, idempotent: true)
            public struct Uppercase {
                /// Upper-cases "text".
                /// - Parameter text: What to shout.
                public func call(_ text: String, times count: Int = 1) -> String {
                    text.uppercased()
                }
            }
            """#,
            expands: #"""
            public struct Uppercase {
                /// Upper-cases "text".
                /// - Parameter text: What to shout.
                public func call(_ text: String, times count: Int = 1) -> String {
                    text.uppercased()
                }

                public static var definition: LimbCore.ToolDefinition {
                    var __limbBuilder = LimbCore.SchemaBuilder()
                    var __limbFields = LimbCore.SchemaSupport.Fields()
                    __limbFields.add("text", (String).self, description: "What to shout.", hasDefault: false, in: &__limbBuilder)
                    __limbFields.add("times", (Int).self, description: nil, hasDefault: true, in: &__limbBuilder)
                    return LimbCore.ToolDefinition(
                        name: "shout",
                        title: "Shout",
                        description: "Upper-cases \"text\".",
                        inputSchema: __limbBuilder.finish(__limbFields.schema(description: nil)),
                        outputSchema: LimbServer.ToolSupport.outputSchema((String).self),
                        annotations: LimbCore.ToolAnnotations(destructiveHint: false, idempotentHint: true))
                }

                public func call(
                    arguments __limbArguments: LimbCore.JSONObject, context __limbContext: LimbServer.RequestContext
                ) async throws -> LimbCore.ToolResult {
                    let __limbArgument0: String
                    let __limbArgument1: Int
                    do throws(LimbCore.JSONDecodingError) {
                        __limbArgument0 = try LimbCore.SchemaSupport.decode(__limbArguments, "text")
                    __limbArgument1 = try LimbCore.SchemaSupport.decode(__limbArguments, "times", default: Self.__macro_local_11limbDefaultfMu_())
                    } catch {
                        throw LimbServer.ToolSupport.invalidArguments(error)
                    }
                    return try LimbServer.ToolSupport.result(self.call(__limbArgument0, times: __limbArgument1), context: __limbContext)
                }

                private static func __macro_local_11limbDefaultfMu_() -> Int {
                    (1)
                }
            }

            extension Uppercase: LimbServer.MCPTool {
            }
            """#)
    }

    @Test func emptyPublicSchemaStruct() {
        IndependentMacroAssertExpansion(
            #"""
            @Schema
            public struct Empty {
            }
            """#,
            expands: #"""
            public struct Empty {
            }

            extension Empty: LimbCore.SchemaRepresentable {
                public static func jsonSchema(in __limbOuter: inout LimbCore.SchemaBuilder) -> LimbCore.JSONObject {
                    __limbOuter.named(Self.self) { __limbBuilder in
                        let __limbFields = LimbCore.SchemaSupport.Fields()

                        return __limbFields.schema(description: nil)
                    }
                }

                public init(json __limbJSON: LimbCore.JSONValue) throws(LimbCore.JSONDecodingError) {
                    _ = try LimbCore.JSONObject(json: __limbJSON)

                }

                public var jsonValue: LimbCore.JSONValue {
                    let __limbObject = LimbCore.JSONObject(minimumCapacity: 0)

                    return .object(__limbObject)
                }

                public func jsonValue(maxDepth __limbDepth: Swift.Int) throws(LimbCore.JSONEncodingDepthError) -> LimbCore.JSONValue {
                    guard __limbDepth > 0 else {
                        throw LimbCore.JSONEncodingDepthError()
                    }
                    let __limbObject = LimbCore.JSONObject(minimumCapacity: 0)

                    return .object(__limbObject)
                }
            }
            """#)
    }

    @Test func schemaStructWithKeywordSharedAnnotationAndObserver() {
        IndependentMacroAssertExpansion(
            #"""
            @Schema
            struct Keyword {
                var `default`: Int
                var a, b: String?
                var watched: Int = 0 {
                    didSet {}
                }
            }
            """#,
            expands: #"""
            struct Keyword {
                var `default`: Int
                var a, b: String?
                var watched: Int = 0 {
                    didSet {}
                }
            }

            extension Keyword: LimbCore.SchemaRepresentable {
                static func jsonSchema(in __limbOuter: inout LimbCore.SchemaBuilder) -> LimbCore.JSONObject {
                    __limbOuter.named(Self.self) { __limbBuilder in
                        var __limbFields = LimbCore.SchemaSupport.Fields()
                        __limbFields.add("default", \Self.`default`, description: nil, hasDefault: false, in: &__limbBuilder)
                        __limbFields.add("a", \Self.a, description: nil, hasDefault: false, in: &__limbBuilder)
                        __limbFields.add("b", \Self.b, description: nil, hasDefault: false, in: &__limbBuilder)
                        __limbFields.add("watched", \Self.watched, description: nil, hasDefault: true, in: &__limbBuilder)
                        return __limbFields.schema(description: nil)
                    }
                }

                init(json __limbJSON: LimbCore.JSONValue) throws(LimbCore.JSONDecodingError) {
                    let __limbObject = try LimbCore.JSONObject(json: __limbJSON)
                    self.`default` = try LimbCore.SchemaSupport.decode(__limbObject, "default")
                    self.a = try LimbCore.SchemaSupport.decode(__limbObject, "a")
                    self.b = try LimbCore.SchemaSupport.decode(__limbObject, "b")
                    if let __limbValue = try LimbCore.SchemaSupport.decodeIfPresent(__limbObject, "watched", for: \Self.watched) {
                        self.watched = __limbValue
                    }
                }

                var jsonValue: LimbCore.JSONValue {
                    var __limbObject = LimbCore.JSONObject(minimumCapacity: 4)
                    LimbCore.SchemaSupport.set(&__limbObject, "default", self.`default`)
                    LimbCore.SchemaSupport.set(&__limbObject, "a", self.a)
                    LimbCore.SchemaSupport.set(&__limbObject, "b", self.b)
                    LimbCore.SchemaSupport.set(&__limbObject, "watched", self.watched, includeNil: true)
                    return .object(__limbObject)
                }

                func jsonValue(maxDepth __limbDepth: Swift.Int) throws(LimbCore.JSONEncodingDepthError) -> LimbCore.JSONValue {
                    guard __limbDepth > 0 else {
                        throw LimbCore.JSONEncodingDepthError()
                    }
                    var __limbObject = LimbCore.JSONObject(minimumCapacity: 4)
                    try LimbCore.SchemaSupport.set(&__limbObject, "default", self.`default`, maxDepth: __limbDepth - 1)
                    try LimbCore.SchemaSupport.set(&__limbObject, "a", self.a, maxDepth: __limbDepth - 1)
                    try LimbCore.SchemaSupport.set(&__limbObject, "b", self.b, maxDepth: __limbDepth - 1)
                    try LimbCore.SchemaSupport.set(&__limbObject, "watched", self.watched, includeNil: true, maxDepth: __limbDepth - 1)
                    return .object(__limbObject)
                }
            }
            """#)
    }

    @Test func actorToolWithKeywordLabelsStaticDefaultAndOptionalContext() {
        IndependentMacroAssertExpansion(
            #"""
            /// Counts.
            @Tool
            actor Counter {
                static let step = 2
                var total = 0
                func call(`in` place: String, by _: Int = step + 1, `inout`: Bool = false, context: ToolContext?) -> Swift.Void {}
            }
            """#,
            expands: #"""
            /// Counts.
            actor Counter {
                static let step = 2
                var total = 0
                func call(`in` place: String, by _: Int = step + 1, `inout`: Bool = false, context: ToolContext?) -> Swift.Void {}

                static var definition: LimbCore.ToolDefinition {
                    var __limbBuilder = LimbCore.SchemaBuilder()
                    var __limbFields = LimbCore.SchemaSupport.Fields()
                    __limbFields.add("in", (String).self, description: nil, hasDefault: false, in: &__limbBuilder)
                    __limbFields.add("by", (Int).self, description: nil, hasDefault: true, in: &__limbBuilder)
                    __limbFields.add("inout", (Bool).self, description: nil, hasDefault: true, in: &__limbBuilder)
                    return LimbCore.ToolDefinition(
                        name: "counter",
                        title: nil,
                        description: "Counts.",
                        inputSchema: __limbBuilder.finish(__limbFields.schema(description: nil)),
                        outputSchema: nil,
                        annotations: nil)
                }

                func call(
                    arguments __limbArguments: LimbCore.JSONObject, context __limbContext: LimbServer.RequestContext
                ) async throws -> LimbCore.ToolResult {
                    let __limbArgument0: String
                    let __limbArgument1: Int
                    let __limbArgument2: Bool
                    do throws(LimbCore.JSONDecodingError) {
                        __limbArgument0 = try LimbCore.SchemaSupport.decode(__limbArguments, "in")
                    __limbArgument1 = try LimbCore.SchemaSupport.decode(__limbArguments, "by", default: Self.__macro_local_11limbDefaultfMu_())
                    __limbArgument2 = try LimbCore.SchemaSupport.decode(__limbArguments, "inout", default: Self.__macro_local_11limbDefaultfMu0_())
                    } catch {
                        throw LimbServer.ToolSupport.invalidArguments(error)
                    }
                    self.call(in: __limbArgument0, by: __limbArgument1, `inout`: __limbArgument2, context: __limbContext)
                    return LimbCore.ToolResult()
                }

                private static func __macro_local_11limbDefaultfMu_() -> Int {
                    (step + 1)
                }

                private static func __macro_local_11limbDefaultfMu0_() -> Bool {
                    (false)
                }
            }

            extension Counter: LimbServer.MCPTool {
            }
            """#)
    }
}
