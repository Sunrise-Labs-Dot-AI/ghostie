import XCTest
@testable import MessagesForAIMenu

/// SUN-613 phase 2a. `DraftStore` silently dropped unreadable and malformed draft files while
/// reporting no error, so "no error" did not mean "complete list". That is harmless for the UI but
/// wrong for the cross-device relay, where a reader treats an absent draft as DELETED: one malformed
/// file on the origin Mac would look like a deletion on the other device.
///
/// These tests pin the fixed contract: a listing is `complete` only when enumeration succeeded AND
/// every eligible file parsed, and the list is published together with its own completeness so the
/// two can never be mismatched.
@MainActor
final class DraftStoreCompletenessTests: XCTestCase {

  private var home: URL!

  override func setUp() async throws {
    try await super.setUp()
    home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ghostie-draftstore-complete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".messages-mcp/drafts", isDirectory: true),
      withIntermediateDirectories: true
    )
    setenv("MESSAGES_FOR_AI_HOME", home.path, 1)
  }

  override func tearDown() async throws {
    unsetenv("MESSAGES_FOR_AI_HOME")
    try? FileManager.default.removeItem(at: home)
    home = nil
    try await super.tearDown()
  }

  private var draftsDir: URL {
    home.appendingPathComponent(".messages-mcp/drafts", isDirectory: true)
  }

  private func writeDraft(id: String, body: String = "hi") throws {
    let json = """
    {"id":"\(id)","to_handle":"+14155551234","to_handle_name":null,"body":"\(body)",
     "in_reply_to_thread_id":null,"staged_at":"2026-07-20T00:00:00Z","sent_at":null,
     "send_service":null,"source":null,"context_messages":null,"context_diagnostic":null}
    """
    try Data(json.utf8).write(to: draftsDir.appendingPathComponent("\(id).json"))
  }

  func testAllGoodFilesYieldACompleteListing() throws {
    try writeDraft(id: "11111111-1111-4111-8111-111111111111")
    try writeDraft(id: "22222222-2222-4222-8222-222222222222")

    let store = DraftStore()
    store.refresh()

    XCTAssertEqual(store.refreshSnapshot.drafts.count, 2)
    XCTAssertTrue(store.refreshSnapshot.complete)
    XCTAssertEqual(store.refreshSnapshot.skippedCount, 0)
  }

  func testOneMalformedFileMakesTheListingIncomplete() throws {
    // The exact failure the relay cares about: the good draft still loads, but the listing must NOT
    // claim to be authoritative, or a remote reader would delete what it can no longer see.
    try writeDraft(id: "11111111-1111-4111-8111-111111111111")
    try Data("{ not valid json".utf8).write(to: draftsDir.appendingPathComponent("broken.json"))

    let store = DraftStore()
    store.refresh()

    XCTAssertEqual(store.refreshSnapshot.drafts.count, 1, "the readable draft should still load")
    XCTAssertFalse(store.refreshSnapshot.complete, "a skipped file must make the listing incomplete")
    XCTAssertEqual(store.refreshSnapshot.skippedCount, 1)
    // The legacy surface stays quiet, which is exactly why `complete` had to be its own signal:
    // lastRefreshError only ever covered directory-level failures.
    XCTAssertNil(store.lastRefreshError)
  }

  func testAFileThatIsValidJSONButNotADraftIsCountedAsSkipped() throws {
    try writeDraft(id: "11111111-1111-4111-8111-111111111111")
    try Data(#"{"unrelated":true}"#.utf8).write(to: draftsDir.appendingPathComponent("other.json"))

    let store = DraftStore()
    store.refresh()

    XCTAssertEqual(store.refreshSnapshot.drafts.count, 1)
    XCTAssertFalse(store.refreshSnapshot.complete)
  }

  func testSnapshotPairsItsOwnListWithItsOwnCompleteness() throws {
    // Atomicity: the published snapshot must always be self-consistent, never a new list carrying a
    // previous refresh's completeness.
    try writeDraft(id: "11111111-1111-4111-8111-111111111111")
    let store = DraftStore()
    store.refresh()
    XCTAssertTrue(store.refreshSnapshot.complete)
    let firstGeneration = store.refreshSnapshot.generation

    try Data("{ broken".utf8).write(to: draftsDir.appendingPathComponent("broken.json"))
    store.refresh()

    XCTAssertFalse(store.refreshSnapshot.complete)
    XCTAssertGreaterThan(store.refreshSnapshot.generation, firstGeneration,
                         "generation must advance so a reader can order observations")
    XCTAssertEqual(store.refreshSnapshot.drafts.count, 1)
  }

  func testGenerationIsMonotonicAndObservedAtIsSet() throws {
    try writeDraft(id: "11111111-1111-4111-8111-111111111111")
    let store = DraftStore()
    store.refresh()
    let first = store.refreshSnapshot
    store.refresh()
    let second = store.refreshSnapshot

    XCTAssertGreaterThan(second.generation, first.generation)
    XCTAssertGreaterThan(second.observedAt, Date.distantPast)
  }
}
