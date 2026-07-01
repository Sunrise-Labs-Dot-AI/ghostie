import XCTest
@testable import MessagesForAIMenu

final class TransportRoutingTests: XCTestCase {
  // MARK: - Route decision

  func testNotIMessageVerdictReordersCascade() {
    XCTAssertEqual(DraftSender.noChatSendStrategy(verdict: .notIMessage), .nonIMessageFirst)
  }

  func testIMessageAndUnknownKeepCurrentBehavior() {
    XCTAssertEqual(DraftSender.noChatSendStrategy(verdict: .iMessage), .buddyCascade)
    XCTAssertEqual(DraftSender.noChatSendStrategy(verdict: .unknown), .buddyCascade)
  }

  // MARK: - Failure log format

  func testFailureEntryRoundTrips() throws {
    let entry = SendFailureLog.makeEntry(
      platform: "imessage",
      handle: "+16505550159",
      route: "non-imessage-first",
      error: "ERROR: RCS=… (errNum=-1728)",
      durationMs: 1234,
      source: "swift-direct",
      now: Date(timeIntervalSince1970: 0)
    )
    XCTAssertEqual(entry.ts, "1970-01-01T00:00:00.000Z")
    let line = try XCTUnwrap(SendFailureLog.encodeLine(entry))
    XCTAssertFalse(line.contains("\n"), "log line must be single-line JSONL")
    // The on-disk key is snake_case so the TS side reads the same shape.
    XCTAssertTrue(line.contains("\"duration_ms\":1234"))
    let decoded = try JSONDecoder().decode(SendFailureLog.Entry.self, from: Data(line.utf8))
    XCTAssertEqual(decoded, entry)
  }

  // MARK: - Flag disk read (the seam the off-main-actor send path uses)

  func testResolvedFromDiskReadsOverride() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("ff-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let state = FeatureFlagFileState(
      schemaVersion: 1, remote: [:],
      overrides: ["babysitter": true], fetchedAt: nil
    )
    try JSONEncoder().encode(state).write(to: tmp)
    XCTAssertTrue(FeatureFlagStore.resolvedFromDisk(.babysitter, fileURL: tmp))
  }

  func testResolvedFromDiskMissingFileFallsToBuiltinDefault() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
    // builtinDefault is false → a missing/torn cache can only DISABLE the gate.
    XCTAssertFalse(FeatureFlagStore.resolvedFromDisk(.babysitter, fileURL: missing))
  }
}
