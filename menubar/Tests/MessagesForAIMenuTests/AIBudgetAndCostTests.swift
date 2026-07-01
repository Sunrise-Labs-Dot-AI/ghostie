import Foundation
import XCTest
@testable import MessagesForAIMenu

final class AIBudgetGateTests: XCTestCase {
  private func budget(cap: Double?, enforce: Bool = true) -> AIUsageBudget {
    AIUsageBudget(monthlyCapUSD: cap, warnThresholds: [0.5, 0.8, 1.0], enforce: enforce)
  }

  func test_noCapAlwaysAllows() {
    let d = AIBudgetGate.evaluate(monthToDateUSD: 9_999, estimatedNextCallUSD: 100, budget: budget(cap: nil))
    XCTAssertEqual(d, .allow)
  }

  func test_wellUnderCapAllows() {
    let d = AIBudgetGate.evaluate(monthToDateUSD: 2, estimatedNextCallUSD: 1, budget: budget(cap: 10))
    XCTAssertEqual(d, .allow)
  }

  func test_approachingCapWarns() {
    let d = AIBudgetGate.evaluate(monthToDateUSD: 4, estimatedNextCallUSD: 2, budget: budget(cap: 10))
    guard case .warn(let pct) = d else { return XCTFail("expected warn, got \(d)") }
    XCTAssertEqual(pct, 0.6, accuracy: 0.0001)
  }

  func test_atCapBlocksWhenEnforced() {
    let d = AIBudgetGate.evaluate(monthToDateUSD: 10, estimatedNextCallUSD: 1, budget: budget(cap: 10))
    guard case .block(let remaining) = d else { return XCTFail("expected block, got \(d)") }
    XCTAssertEqual(remaining, 0, accuracy: 0.0001)
  }

  func test_callThatWouldExceedCapBlocks() {
    let d = AIBudgetGate.evaluate(monthToDateUSD: 9, estimatedNextCallUSD: 2, budget: budget(cap: 10))
    guard case .block(let remaining) = d else { return XCTFail("expected block, got \(d)") }
    XCTAssertEqual(remaining, 1, accuracy: 0.0001)
  }

  func test_enforceOffNeverBlocksOnlyWarns() {
    let d = AIBudgetGate.evaluate(monthToDateUSD: 9, estimatedNextCallUSD: 5, budget: budget(cap: 10, enforce: false))
    guard case .warn = d else { return XCTFail("expected warn, got \(d)") }
  }
}

final class AIUsageEstimateCostTests: XCTestCase {
  func test_exactCostFromTokens() {
    let (usd, basis) = AIUsageEstimate.costUSD(provider: .anthropic, modelID: "claude-sonnet-4-6", inputTokens: 1_000_000, outputTokens: 1_000_000)
    XCTAssertEqual(basis, .exact)
    XCTAssertEqual(usd ?? 0, 18.0, accuracy: 0.001) // 3 + 15
  }

  func test_missingTokensYieldEstimatedBasis() {
    let (usd, basis) = AIUsageEstimate.costUSD(provider: .anthropic, modelID: "claude-opus-4-8", inputTokens: nil, outputTokens: 10)
    XCTAssertEqual(basis, .estimated)
    XCTAssertNil(usd)
  }

  func test_unknownModelYieldsUnknownPrice() {
    let (usd, basis) = AIUsageEstimate.costUSD(provider: .openAI, modelID: "totally-made-up", inputTokens: 1, outputTokens: 1)
    XCTAssertEqual(basis, .unknownPrice)
    XCTAssertNil(usd)
  }

  func test_resolvedCostFallsBackToEstimateWhenTokensMissing() {
    let (usd, basis) = AIUsageEstimate.resolvedCostUSD(lab: .deepRead, provider: .anthropic, modelID: "claude-sonnet-4-6", inputTokens: nil, outputTokens: nil)
    XCTAssertEqual(basis, .estimated)
    XCTAssertNotNil(usd)
  }

  func test_cheaperAlternativeSuggestsRecommendedWhenPricierSelected() {
    // Severance recommends Haiku; if the user picked Opus, that's a clear downgrade.
    let alt = AIUsageEstimate.cheaperAlternative(for: .workPersonal, provider: .anthropic, currentModelID: "claude-opus-4-8")
    XCTAssertEqual(alt?.modelID, "claude-haiku-4-5")
    XCTAssertGreaterThan(alt?.savingsPct ?? 0, 50)
  }

  func test_cheaperAlternativeNilWhenAlreadyRecommended() {
    let alt = AIUsageEstimate.cheaperAlternative(for: .workPersonal, provider: .anthropic, currentModelID: "claude-haiku-4-5")
    XCTAssertNil(alt)
  }

  func test_cheaperAlternativeNilWhenCurrentIsAlreadyCheaper() {
    // Texting Style recommends Opus; a user on Haiku should NOT be told to "upgrade".
    let alt = AIUsageEstimate.cheaperAlternative(for: .textingStyle, provider: .anthropic, currentModelID: "claude-haiku-4-5")
    XCTAssertNil(alt)
  }
}

final class AITokenUsageParserTests: XCTestCase {
  func test_extractsAnthropicAndOpenAIShape() {
    let root: [String: Any] = ["usage": ["input_tokens": 120, "output_tokens": 34]]
    let (input, output) = AITokenUsageParser.tokens(fromResponseRoot: root)
    XCTAssertEqual(input, 120)
    XCTAssertEqual(output, 34)
  }

  func test_promptCompletionFallback() {
    let root: [String: Any] = ["usage": ["prompt_tokens": 7, "completion_tokens": 9]]
    let (input, output) = AITokenUsageParser.tokens(fromResponseRoot: root)
    XCTAssertEqual(input, 7)
    XCTAssertEqual(output, 9)
  }

  func test_missingUsageReturnsNils() {
    let (input, output) = AITokenUsageParser.tokens(fromResponseRoot: ["content": []])
    XCTAssertNil(input)
    XCTAssertNil(output)
  }

  /// JSONSerialization yields NSNumber for integers — the parser must bridge it.
  func test_handlesJSONSerializationNSNumber() throws {
    let json = #"{"usage":{"input_tokens":500,"output_tokens":250},"content":[]}"#
    let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    let (input, output) = AITokenUsageParser.tokens(fromResponseRoot: root)
    XCTAssertEqual(input, 500)
    XCTAssertEqual(output, 250)
  }
}
