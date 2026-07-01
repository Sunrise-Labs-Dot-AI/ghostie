import Foundation
import XCTest
@testable import MessagesForAIMenu

@MainActor
final class AIUsageLedgerTests: XCTestCase {
  private var dir: URL!
  private var fileURL: URL!

  override func setUp() {
    super.setUp()
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    fileURL = dir.appendingPathComponent("ai-usage.json")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
    super.tearDown()
  }

  func test_recordRoundTripsThroughDisk() {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.record(lab: .deepRead, provider: .anthropic, modelID: "claude-sonnet-4-6",
                  inputTokens: 9_000, outputTokens: 1_200, status: .ok, runID: nil)
    XCTAssertEqual(ledger.eventsNewestFirst.count, 1)

    let reloaded = AIUsageLedger(fileURL: fileURL)
    XCTAssertEqual(reloaded.eventsNewestFirst.count, 1)
    let event = reloaded.eventsNewestFirst.first!
    XCTAssertEqual(event.aiLab, .deepRead)
    XCTAssertEqual(event.aiProvider, .anthropic)
    XCTAssertEqual(event.inputTokens, 9_000)
    XCTAssertEqual(event.costBasis, .exact)
    // Sonnet: 9k in * $3/M + 1.2k out * $15/M = 0.027 + 0.018 = 0.045
    XCTAssertEqual(event.costUSD ?? 0, 0.045, accuracy: 0.0001)
  }

  func test_missingTokensRecordAsEstimated() {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.record(lab: .dontGhost, provider: .anthropic, modelID: "claude-sonnet-4-6",
                  inputTokens: nil, outputTokens: nil, status: .ok, runID: nil)
    let event = ledger.eventsNewestFirst.first!
    XCTAssertEqual(event.costBasis, .estimated)
    // Falls back to the per-feature estimate, not a fabricated exact number.
    let expected = AIUsageEstimate.estimatedCostUSD(lab: .dontGhost, provider: .anthropic, modelID: "claude-sonnet-4-6")
    XCTAssertEqual(event.costUSD, expected)
    XCTAssertNotNil(event.costUSD)
  }

  func test_unknownModelPriceRecordsUnknownBasisNotZero() {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.record(lab: .eq, provider: .anthropic, modelID: "claude-zeta-9000",
                  inputTokens: 1000, outputTokens: 1000, status: .ok, runID: nil)
    let event = ledger.eventsNewestFirst.first!
    XCTAssertEqual(event.costBasis, .unknownPrice)
    XCTAssertNil(event.costUSD)
  }

  func test_summaryGroupsByFeatureAndSumsThisMonth() {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.record(lab: .deepRead, provider: .anthropic, modelID: "claude-sonnet-4-6", inputTokens: 1_000_000, outputTokens: 0, status: .ok, runID: nil) // $3
    ledger.record(lab: .deepRead, provider: .anthropic, modelID: "claude-sonnet-4-6", inputTokens: 1_000_000, outputTokens: 0, status: .ok, runID: nil) // $3
    ledger.record(lab: .eq, provider: .anthropic, modelID: "claude-opus-4-8", inputTokens: 1_000_000, outputTokens: 0, status: .ok, runID: nil) // $15
    let summary = ledger.summary()
    XCTAssertEqual(summary.callCount, 3)
    XCTAssertEqual(summary.totalUSD, 21.0, accuracy: 0.001)
    XCTAssertEqual(summary.byFeature.count, 2)
    // Sorted by cost descending: EQ ($15) before Deep Read ($6).
    XCTAssertEqual(summary.byFeature.first?.lab, .eq)
    XCTAssertEqual(summary.byFeature.first?.calls, 1)
  }

  func test_blockedEventsAreCountedButCarryNoSpend() {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.record(lab: .textingStyle, provider: .anthropic, modelID: "claude-opus-4-8",
                  inputTokens: nil, outputTokens: nil, status: .blockedByBudget, runID: nil)
    let summary = ledger.summary()
    XCTAssertEqual(summary.blockedCount, 1)
    XCTAssertEqual(summary.callCount, 0)
    XCTAssertEqual(summary.totalUSD, 0)
  }

  func test_budgetMutatorsPersist() {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.setMonthlyCap(25)
    ledger.setEnforce(false)
    let reloaded = AIUsageLedger(fileURL: fileURL)
    XCTAssertEqual(reloaded.budget.monthlyCapUSD, 25)
    XCTAssertFalse(reloaded.budget.enforce)
    // Removing the cap round-trips too.
    reloaded.setMonthlyCap(nil)
    XCTAssertNil(AIUsageLedger(fileURL: fileURL).budget.monthlyCapUSD)
  }

  func test_corruptFileIsQuarantinedNotOverwritten() throws {
    try "{ this is not json".data(using: .utf8)!.write(to: fileURL)
    let ledger = AIUsageLedger(fileURL: fileURL)
    XCTAssertTrue(ledger.eventsNewestFirst.isEmpty)
    XCTAssertNotNil(ledger.lastError)
    // The bytes were preserved under a .corrupt-* sibling, not clobbered.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertTrue(siblings.contains { $0.contains("ai-usage.json.corrupt-") })
  }

  func test_clearHistoryEmptiesButKeepsBudget() {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.setMonthlyCap(10)
    ledger.record(lab: .eq, provider: .anthropic, modelID: "claude-opus-4-8", inputTokens: 1, outputTokens: 1, status: .ok, runID: nil)
    ledger.clearHistory()
    XCTAssertTrue(ledger.eventsNewestFirst.isEmpty)
    XCTAssertEqual(ledger.budget.monthlyCapUSD, 10)
  }

  /// Privacy invariant: the on-disk event must contain only metadata keys —
  /// never a message body, prompt, or completion.
  func test_persistedEventContainsNoMessageText() throws {
    let ledger = AIUsageLedger(fileURL: fileURL)
    ledger.record(lab: .eq, provider: .anthropic, modelID: "claude-opus-4-8", inputTokens: 5, outputTokens: 5, status: .ok, runID: nil)
    let raw = try String(contentsOf: fileURL, encoding: .utf8).lowercased()
    for forbidden in ["body", "prompt", "completion", "message", "content", "text"] {
      XCTAssertFalse(raw.contains(forbidden), "usage ledger leaked a '\(forbidden)' field")
    }
  }
}
