import XCTest
@testable import MessagesForAIMenu

/// Issue #88 (round 2): the iMessage `sent_at` must be persisted to the draft JSON
/// on disk WHILE the send lock is still held, so the MCP — which reads `sent_at`
/// from that file inside its own lock — can never see `sent_at == null` and
/// re-send in the window between our send and the caller's later markSent.
final class DraftSenderTests: XCTestCase {
  private var tmpHome: URL!

  override func setUp() {
    super.setUp()
    tmpHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("mfa-draftsender-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
    // Both DraftSender.persistIMessageSentAt and SendLock resolve their paths via
    // AppStoragePaths.homeDirectory, which honors this env var.
    setenv("MESSAGES_FOR_AI_HOME", tmpHome.path, 1)
  }

  override func tearDown() {
    unsetenv("MESSAGES_FOR_AI_HOME")
    try? FileManager.default.removeItem(at: tmpHome)
    super.tearDown()
  }

  /// The persist runs inside the locked region: while the lock for a draft is
  /// held, persisting sent_at must land on disk. We drive the helper directly
  /// (the real send path can't spawn osascript in CI) and assert the on-disk
  /// `sent_at` is present BEFORE the lock is released — the ordering the fix
  /// guarantees in DraftSender.send.
  @MainActor
  func testSentAtPersistedOnDiskWhileLockHeld() throws {
    let store = DraftStore(homeOverride: tmpHome)
    let draft = try store.createIMessageDraft(
      toHandle: "+12155550121", toHandleName: "Ryan", body: "hi"
    )
    let url = tmpHome
      .appendingPathComponent(".messages-mcp/drafts", isDirectory: true)
      .appendingPathComponent("\(draft.id).json")

    // Sanity: freshly staged → no sent_at on disk yet.
    XCTAssertNil(try diskSentAt(url), "a freshly staged draft has no sent_at")

    // Take the SAME lock DraftSender takes, then persist sent_at — mirroring the
    // locked region. The on-disk sent_at must be set BEFORE we release.
    guard var lock = SendLock.acquire(for: draft.id) else {
      return XCTFail("lock acquire should succeed")
    }
    DraftSender.persistIMessageSentAt(draftId: draft.id, service: "iMessage")
    let sentAtWhileHeld = try diskSentAt(url)
    XCTAssertNotNil(sentAtWhileHeld, "sent_at must be on disk before the lock is released")
    lock.release()

    // The full draft is preserved (not blanked) and now carries sent_at + service.
    let reloaded = try XCTUnwrap(reload(url))
    XCTAssertNotNil(reloaded.sent_at)
    XCTAssertEqual(reloaded.send_service, "iMessage")
    XCTAssertEqual(reloaded.body, "hi", "other fields must survive the in-place rewrite")
    XCTAssertEqual(reloaded.to_handle, "+12155550121")
  }

  /// Idempotent: a second persist must not overwrite the first sent_at, so a
  /// re-entrant call (or the caller's later markSent) can't clobber the record.
  @MainActor
  func testPersistSentAtIsIdempotent() throws {
    let store = DraftStore(homeOverride: tmpHome)
    let draft = try store.createIMessageDraft(
      toHandle: "+12155550121", toHandleName: "Ryan", body: "hi"
    )
    let url = tmpHome
      .appendingPathComponent(".messages-mcp/drafts", isDirectory: true)
      .appendingPathComponent("\(draft.id).json")

    DraftSender.persistIMessageSentAt(draftId: draft.id, service: "iMessage")
    let first = try XCTUnwrap(try diskSentAt(url))
    // Second call with a different service must be a no-op (already sent).
    DraftSender.persistIMessageSentAt(draftId: draft.id, service: "SMS")
    let second = try XCTUnwrap(try diskSentAt(url))
    XCTAssertEqual(first, second, "sent_at must not be overwritten by a second persist")
    XCTAssertEqual(try XCTUnwrap(reload(url)).send_service, "iMessage", "service of the first send is kept")
  }

  // MARK: - Chat-GUID addressability (Change 3: the any;-; send fix)

  /// Only iMessage/SMS/RCS chat GUIDs can be addressed by AppleScript `chat id`.
  /// An unbound/aggregate `any;-;…` guid must be rejected so the send falls back
  /// to the buddy cascade instead of hard-failing with -1728.
  func testIsAddressableChatGUID() {
    XCTAssertTrue(IMessageDirectChatResolver.isAddressableChatGUID("iMessage;-;+14155550142"))
    XCTAssertTrue(IMessageDirectChatResolver.isAddressableChatGUID("SMS;-;+14155550142"))
    XCTAssertTrue(IMessageDirectChatResolver.isAddressableChatGUID("RCS;-;+14155550142"))
    XCTAssertTrue(IMessageDirectChatResolver.isAddressableChatGUID("iMessage;+;chat123"))
    // case-insensitive on the service prefix
    XCTAssertTrue(IMessageDirectChatResolver.isAddressableChatGUID("imessage;-;foo@bar.com"))
    // the reported failure: unbound/aggregate chat — NOT addressable
    XCTAssertFalse(IMessageDirectChatResolver.isAddressableChatGUID("any;-;+14155550142"))
    XCTAssertFalse(IMessageDirectChatResolver.isAddressableChatGUID(""))
    XCTAssertFalse(IMessageDirectChatResolver.isAddressableChatGUID("+14155550142"))
  }

  /// The send-result service label is derived from the guid prefix; unknown
  /// prefixes default to iMessage (this is the LABEL, separate from the strict
  /// addressability gate above — they must not be conflated).
  func testServiceFromChatGUID() {
    XCTAssertEqual(DraftSender.serviceFromChatGUID("SMS;-;+1"), "SMS")
    XCTAssertEqual(DraftSender.serviceFromChatGUID("RCS;-;+1"), "RCS")
    XCTAssertEqual(DraftSender.serviceFromChatGUID("iMessage;-;+1"), "iMessage")
    XCTAssertEqual(DraftSender.serviceFromChatGUID("any;-;+1"), "iMessage")
  }

  // MARK: - Group chat GUID extraction (degraded group draft recovery)

  /// When imessage_group decodes as nil but to_handle still encodes the GUID
  /// ("imessage-group:<guid>"), the send path extracts the GUID to route via
  /// `chat id` instead of falling through to the buddy cascade (which fails).
  func testGroupChatGUIDExtraction() {
    // Standard iMessage group chat GUID
    XCTAssertEqual(
      DraftSender.groupChatGUID(from: "imessage-group:iMessage;+;chat123456789"),
      "iMessage;+;chat123456789"
    )
    // GUID containing colons (should not be truncated — only first colon is the delimiter)
    XCTAssertEqual(
      DraftSender.groupChatGUID(from: "imessage-group:iMessage;+;chat:with:colons"),
      "iMessage;+;chat:with:colons"
    )
    // Pending binding — no GUID available
    XCTAssertNil(DraftSender.groupChatGUID(from: "imessage-group-pending:+1555|+1666"))
    // 1:1 handles — must not be treated as group targets
    XCTAssertNil(DraftSender.groupChatGUID(from: "+14155550142"))
    XCTAssertNil(DraftSender.groupChatGUID(from: "user@example.com"))
    XCTAssertNil(DraftSender.groupChatGUID(from: ""))
    // Empty GUID after prefix — treat as nil (no addressable target)
    XCTAssertNil(DraftSender.groupChatGUID(from: "imessage-group:"))
  }

  // MARK: - Helpers

  private func diskSentAt(_ url: URL) throws -> String? {
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return obj?["sent_at"] as? String
  }

  private func reload(_ url: URL) -> Draft? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Draft.self, from: data)
  }
}
