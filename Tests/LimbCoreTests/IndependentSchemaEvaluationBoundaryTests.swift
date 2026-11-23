import LimbCore
import Testing

@Suite struct IndependentSchemaEvaluationBoundaryTests {
    @Test(arguments: ["const", "enum", "uniqueItems"])
    func structuralWorkSharesTheEvaluationBudget(keyword: String) throws {
        let shallow: JSONValue = 1
        let deep = Self.nested(1)
        let shallowCheck = Self.structuralCheck(keyword, value: shallow)
        let deepCheck = Self.structuralCheck(keyword, value: deep)
        let small = try JSONSchema(shallowCheck.schema, limits: Self.limits(8))
        let tight = try JSONSchema(deepCheck.schema, limits: Self.limits(8))
        let generous = try JSONSchema(deepCheck.schema, limits: Self.limits(128))

        #expect(small.validate(shallowCheck.validInstance) == nil)
        #expect(tight.validate(deepCheck.validInstance)?.reason == Self.budgetReason)
        #expect(generous.validate(deepCheck.validInstance) == nil)
        #expect(generous.validate(deepCheck.invalidInstance) != nil)
        #expect(generous.validate(deepCheck.invalidInstance)?.reason != Self.budgetReason)
    }

    @Test(arguments: ["not", "anyOf"])
    func compositionPropagatesStructuralBudgetExhaustion(keyword: String) throws {
        let value = Self.nested(1)
        let exact: JSONValue = ["const": value]
        let schema: JSONValue = keyword == "not" ? ["not": exact] : ["anyOf": [exact, true]]
        let tight = try JSONSchema(schema, limits: Self.limits(8))
        let generous = try JSONSchema(schema, limits: Self.limits(128))

        #expect(tight.validate(value)?.reason == Self.budgetReason)
        #expect((generous.validate(value) == nil) == (keyword == "anyOf"))
    }

    @Test(arguments: [
        ["1e999999999999999999", "0.10e1000000000000000000", "2e999999999999999999"],
        ["-1e-1000000000000000001", "-0.10e-1000000000000000000", "-2e-1000000000000000001"],
        ["9007199254740992", "9007199254740992.00", "9007199254740993"],
    ])
    func schemaEqualityPreservesExactSupportedNumbers(lexemes: [String]) throws {
        let expected = try Self.number(lexemes[0])
        let equivalent = try Self.number(lexemes[1])
        let distinct = try Self.number(lexemes[2])

        let scalar = try JSONSchema(["const": expected])
        #expect(scalar.validate(equivalent) == nil)
        #expect(scalar.validate(distinct) != nil)

        let nestedExpected: JSONValue = ["amount": [expected]]
        let nestedEquivalent: JSONValue = ["amount": [equivalent]]
        let nestedDistinct: JSONValue = ["amount": [distinct]]
        for constraint: JSONValue in [["const": nestedExpected], ["enum": [nestedExpected]]] {
            let schema = try JSONSchema(constraint)
            #expect(schema.validate(nestedEquivalent) == nil)
            #expect(schema.validate(nestedDistinct) != nil)
        }

        let unique = try JSONSchema(["uniqueItems": true])
        #expect(unique.validate([nestedExpected, nestedDistinct]) == nil)
        #expect(unique.validate([nestedExpected, nestedEquivalent])?.reason == "items must be unique")
    }

    @Test func boundsCompareAtBothNormalizedExponentLimits() throws {
        let large = try Self.number("1e999999999999999999")
        let larger = try Self.number("2e999999999999999999")
        let tiny = try Self.number("1e-1000000000000000001")
        let lessTiny = try Self.number("2e-1000000000000000001")
        let maximum = try JSONSchema(["maximum": large])
        let minimum = try JSONSchema(["minimum": lessTiny])

        #expect(maximum.validate(large) == nil)
        #expect(maximum.validate(larger) != nil)
        #expect(minimum.validate(lessTiny) == nil)
        #expect(minimum.validate(tiny) != nil)
    }

    @Test(arguments: ["1e1000000000000000000", "1e-1000000000000000002"])
    func schemaCompilationRejectsUnsupportedNumericOperands(lexeme: String) throws {
        let outside = try Self.number(lexeme)
        let constraints: [JSONValue] = [
            ["minimum": outside],
            ["maximum": outside],
            ["const": outside],
            ["const": ["amount": [outside]]],
            ["enum": [["amount": [outside]]]],
        ]
        for constraint in constraints {
            do {
                _ = try JSONSchema(constraint)
                Issue.record("Expected schema compilation to reject an out-of-domain exponent")
            } catch {
                #expect(error.reason.lowercased().contains("exponent"))
            }
        }
    }

    @Test(arguments: ["1e1000000000000000000", "1e-1000000000000000002"])
    func instanceValidationReportsUnsupportedExponentsBeforeComparison(lexeme: String) throws {
        let outside = try Self.number(lexeme)
        let legal = try Self.number("1e-400")
        let scalar = try JSONSchema(["not": ["const": legal]])
        #expect(scalar.validate(2) == nil)
        #expect(scalar.validate(outside)?.reason.lowercased().contains("exponent") == true)

        let unique = try JSONSchema(["uniqueItems": true])
        let valid: JSONValue = [["amount": [legal]], ["amount": [0]]]
        let invalid: JSONValue = [["amount": [legal]], ["amount": [outside]]]
        #expect(unique.validate(valid) == nil)
        #expect(unique.validate(invalid)?.reason.lowercased().contains("exponent") == true)
    }

    private static let budgetReason = "checking this value takes more than 8 steps of the schema"

    private static func limits(_ steps: Int) -> JSONSchema.Limits {
        var limits = JSONSchema.Limits()
        limits.maxEvaluations = steps
        return limits
    }

    private static func nested(_ leaf: JSONValue) -> JSONValue {
        (0..<12).reduce(leaf) { value, _ in ["value": [value]] }
    }

    private static func structuralCheck(
        _ keyword: String,
        value: JSONValue
    ) -> (schema: JSONValue, validInstance: JSONValue, invalidInstance: JSONValue) {
        if keyword == "uniqueItems" {
            return (["uniqueItems": true], [value, 2], [value, value])
        }
        let operand: JSONValue = keyword == "enum" ? [value] : value
        return ([keyword: operand], value, 2)
    }

    private static func number(_ lexeme: String) throws -> JSONValue {
        .number(try #require(JSONNumber(lexeme: lexeme)))
    }
}
