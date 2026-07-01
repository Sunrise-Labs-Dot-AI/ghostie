import XCTest
@testable import MessagesForAIMenu

/// Issue #77: the approval gate must be un-forgeable by an on-disk file, and the
/// defaults must fail closed (missing status = not approved; corrupt JSON = closed).
final class ApprovalAuthenticatorTests: XCTestCase {

  override func setUp() {
    super.setUp()
    // Deterministic secret so the HMAC path works without the Keychain (which is
    // unavailable in the test runner). Set in the process env before any tag mint.
    setenv("MFA_TEST_APPROVAL_SECRET", "unit-test-fixed-secret", 1)
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
  }

  // MARK: - Automations

  @MainActor
  func testForgedApprovedAutomationFileDoesNotSend() throws {
    let home = tmpHome()
    let automationURL = home.appendingPathComponent(".messages-mcp/automations.json")
    try FileManager.default.createDirectory(
      at: automationURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )

    // A file an attacker process could drop: approvalStatus=approved, enabled, due
    // in the past, but NO valid HMAC tag and NO in-session GUI approval.
    let forged = """
    [{
      "id": "forged-1",
      "title": "Pwn",
      "platform": "imessage",
      "toHandle": "+15551234567",
      "body": "attacker chosen text",
      "cadence": "daily",
      "nextRunAt": "2020-01-01T00:00:00Z",
      "isEnabled": true,
      "createdAt": "2020-01-01T00:00:00Z",
      "updatedAt": "2020-01-01T00:00:00Z",
      "approvalStatus": "approved"
    }]
    """
    try forged.data(using: .utf8)!.write(to: automationURL)

    let store = AutomationStore(fileURL: automationURL)
    let draftStore = DraftStore(homeOverride: home)
    let settings = SettingsStore(homeOverride: home)
    let controller = AutomationController(automationStore: store, draftStore: draftStore, settings: settings)

    let loaded = try XCTUnwrap(store.automations.first)
    XCTAssertTrue(loaded.isApproved, "status field is approved")
    XCTAssertFalse(loaded.isAuthenticallyApproved, "but it has no valid tag / session approval")

    controller.materializeDueAutomations(now: Date())
    XCTAssertEqual(draftStore.drafts.count, 0, "a forged approved automation must NOT materialize a draft")
  }

  @MainActor
  func testGuiApprovedAutomationSends() throws {
    let home = tmpHome()
    let url = home.appendingPathComponent(".messages-mcp/automations.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = AutomationStore(fileURL: url)
    let draftStore = DraftStore(homeOverride: home)
    let settings = SettingsStore(homeOverride: home)
    let controller = AutomationController(automationStore: store, draftStore: draftStore, settings: settings)

    let due = iso("2026-06-05T17:00:00Z")
    try store.create(
      title: "Weekly", platform: .imessage, toHandle: "+12155550121",
      toHandleName: "Ryan", body: "hi", cadence: .weekly, nextRunAt: due
    )
    let made = try XCTUnwrap(store.automations.first)
    XCTAssertTrue(made.isAuthenticallyApproved, "create() is a GUI action → authenticated")

    controller.materializeDueAutomations(now: iso("2026-06-05T17:01:00Z"), calendar: utc())
    XCTAssertEqual(draftStore.drafts.count, 1)
  }

  @MainActor
  func testGuiTagSurvivesRelaunchWithoutSessionApproval() throws {
    let home = tmpHome()
    let url = home.appendingPathComponent(".messages-mcp/automations.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = AutomationStore(fileURL: url)
    try store.create(
      title: "Weekly", platform: .imessage, toHandle: "+12155550121",
      toHandleName: "Ryan", body: "hi", cadence: .weekly, nextRunAt: iso("2026-06-05T17:00:00Z")
    )

    // Simulate a relaunch: fresh stores, clear the in-memory session approvals.
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
    let reloaded = AutomationStore(fileURL: url)
    let a = try XCTUnwrap(reloaded.automations.first)
    XCTAssertFalse(ApprovalAuthenticator.hasSessionApproval(canonicalMessage: a.approvalCanonicalMessage), "no session approval after relaunch")
    XCTAssertTrue(a.isAuthenticallyApproved, "but the persisted HMAC tag still authenticates it")
  }

  @MainActor
  func testTamperedBodyInvalidatesTag() throws {
    let home = tmpHome()
    let url = home.appendingPathComponent(".messages-mcp/automations.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = AutomationStore(fileURL: url)
    try store.create(
      title: "Weekly", platform: .imessage, toHandle: "+12155550121",
      toHandleName: "Ryan", body: "original", cadence: .weekly, nextRunAt: iso("2026-06-05T17:00:00Z")
    )
    let approved = try XCTUnwrap(store.automations.first)
    let tag = try XCTUnwrap(approved.approvalTag)

    // Attacker keeps the (valid-for-original) tag but swaps the body → tag binds
    // the body, so verification must now fail. Clear session approval first so the
    // tag is the only thing that could authorize it.
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
    var tampered = approved
    tampered = MessageAutomation(
      id: approved.id, title: approved.title, platform: approved.platform,
      toHandle: approved.toHandle, toHandleName: approved.toHandleName,
      body: "ATTACKER REPLACED BODY", cadence: approved.cadence, nextRunAt: approved.nextRunAt,
      recurrenceInterval: approved.recurrenceInterval, weekdays: approved.weekdays,
      recurrenceAnchorAt: approved.recurrenceAnchorAt, isEnabled: true,
      createdAt: approved.createdAt, updatedAt: approved.updatedAt,
      approvalStatus: .approved, approvalTag: tag, proposedBy: nil,
      lastGeneratedAt: nil, lastGeneratedDraftID: nil, runHistory: nil, failureNote: nil
    )
    XCTAssertFalse(tampered.isAuthenticallyApproved, "a tag minted for a different body must not verify")
  }

  /// Round 2 (#77): the session-approval set is keyed by the CANONICAL TAG, not
  /// the bare id. After a legitimate GUI approval in THIS session, editing the
  /// on-disk JSON to keep the id but swap the recipient/body must NOT pass — the
  /// session gate is no longer replayable by id. (Previously `hasSessionApproval(id:)`
  /// returned true for the swapped record, bypassing the HMAC binding.)
  @MainActor
  func testSessionApprovalIsNotReplayableByIdAfterDiskMutation() throws {
    let home = tmpHome()
    let url = home.appendingPathComponent(".messages-mcp/automations.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = AutomationStore(fileURL: url)
    // GUI approval THIS session (create() records the session approval + mints a tag).
    try store.create(
      title: "Weekly", platform: .imessage, toHandle: "+12155550121",
      toHandleName: "Ryan", body: "original", cadence: .weekly, nextRunAt: iso("2026-06-05T17:00:00Z")
    )
    let approved = try XCTUnwrap(store.automations.first)
    XCTAssertTrue(approved.isAuthenticallyApproved, "the GUI-approved record authenticates this session")

    // Attacker mutates the on-disk record: SAME id (so a stale id-keyed session
    // set would match), but a swapped recipient AND body — and KEEP the old tag
    // (minted for the original). Both the session gate and the tag must reject it.
    let swapped = MessageAutomation(
      id: approved.id, title: approved.title, platform: approved.platform,
      toHandle: "+15550000000", toHandleName: approved.toHandleName,
      body: "ATTACKER REPLACED BODY", cadence: approved.cadence, nextRunAt: approved.nextRunAt,
      recurrenceInterval: approved.recurrenceInterval, weekdays: approved.weekdays,
      recurrenceAnchorAt: approved.recurrenceAnchorAt, isEnabled: true,
      createdAt: approved.createdAt, updatedAt: approved.updatedAt,
      approvalStatus: .approved, approvalTag: approved.approvalTag, proposedBy: nil,
      lastGeneratedAt: nil, lastGeneratedDraftID: nil, runHistory: nil, failureNote: nil
    )
    XCTAssertFalse(
      ApprovalAuthenticator.hasSessionApproval(canonicalMessage: swapped.approvalCanonicalMessage),
      "the swapped record's canonical message was never approved this session"
    )
    XCTAssertFalse(swapped.isAuthenticallyApproved, "swapping recipient/body on disk must invalidate the approval")
  }

  /// Same replay vector on the scheduled-draft path: a GUI-approved scheduled
  /// draft's session approval must not authorize a same-id, swapped-body draft.
  @MainActor
  func testScheduledSessionApprovalIsNotReplayableAfterBodySwap() throws {
    let home = tmpHome()
    let store = DraftStore(homeOverride: home)
    let draft = try store.createIMessageDraft(
      toHandle: "+12155550121", toHandleName: "Ryan", body: "original",
      scheduledAt: iso("2026-06-05T17:00:00Z"), approveScheduledDraft: true
    )
    XCTAssertTrue(draft.isScheduleAuthenticallyApproved, "GUI-created scheduled draft authenticates this session")

    // Same id, swapped body, keep the (original) tag.
    let swapped = Draft(
      id: draft.id, to_handle: draft.to_handle, to_handle_name: draft.to_handle_name,
      body: "ATTACKER REPLACED BODY", in_reply_to_thread_id: nil,
      staged_at: draft.staged_at, sent_at: nil, send_service: draft.send_service, source: draft.source,
      context_messages: nil, context_diagnostic: nil,
      scheduled_send_at: draft.scheduled_send_at, schedule_hold_reason: nil,
      override_send: nil, schedule_approved: true,
      schedule_approval_tag: draft.schedule_approval_tag, schema_version: nil, platform: .imessage,
      approval_state: nil, induced_by_unknown_contact: nil,
      quoted_message_id: nil, quoted_preview: nil
    )
    XCTAssertFalse(
      ApprovalAuthenticator.hasSessionApproval(canonicalMessage: swapped.scheduleApprovalCanonicalMessage),
      "the swapped draft's canonical message was never approved this session"
    )
    XCTAssertFalse(swapped.isScheduleAuthenticallyApproved, "swapping body on disk must invalidate the scheduled approval")
  }

  // MARK: - Fail-closed defaults

  func testMissingStatusReadsAsNotApproved() {
    let a = makeAutomation(approvalStatus: nil)
    XCTAssertFalse(a.isApproved)
    XCTAssertTrue(a.needsApproval)
    XCTAssertFalse(a.isAuthenticallyApproved)
  }

  func testPendingStatusReadsAsNotApproved() {
    let a = makeAutomation(approvalStatus: .pending)
    XCTAssertFalse(a.isApproved)
    XCTAssertFalse(a.isAuthenticallyApproved)
  }

  @MainActor
  func testCorruptJsonFailsClosed() throws {
    let home = tmpHome()
    let url = home.appendingPathComponent(".messages-mcp/automations.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    // First write a valid, GUI-approved automation and confirm it loads.
    let store = AutomationStore(fileURL: url)
    try store.create(
      title: "Weekly", platform: .imessage, toHandle: "+12155550121",
      toHandleName: "Ryan", body: "hi", cadence: .weekly, nextRunAt: iso("2026-06-05T17:00:00Z")
    )
    XCTAssertEqual(store.automations.count, 1)

    // Now corrupt the file on disk and reload → the in-memory list must be cleared
    // (fail closed), NOT retain the stale approved automation.
    try "{ this is not valid json".data(using: .utf8)!.write(to: url)
    store.load()
    XCTAssertEqual(store.automations.count, 0, "corrupt JSON must disable affected automations")
    XCTAssertNotNil(store.lastError)
  }

  // MARK: - HMAC primitive

  func testHmacVerifyRejectsWrongTag() {
    let msg = ApprovalAuthenticator.canonicalMessage(id: "x", recipient: "r", body: "b", scope: "s")
    let good = ApprovalAuthenticator.tag(for: msg)
    XCTAssertNotNil(good)
    XCTAssertTrue(ApprovalAuthenticator.verify(tag: good, message: msg))
    XCTAssertFalse(ApprovalAuthenticator.verify(tag: "AAAA", message: msg))
    XCTAssertFalse(ApprovalAuthenticator.verify(tag: nil, message: msg))
    let otherMsg = ApprovalAuthenticator.canonicalMessage(id: "y", recipient: "r", body: "b", scope: "s")
    XCTAssertFalse(ApprovalAuthenticator.verify(tag: good, message: otherMsg), "tag must not replay onto a different record")
  }

  // MARK: - Helpers

  private func makeAutomation(approvalStatus: AutomationApprovalStatus?) -> MessageAutomation {
    MessageAutomation(
      id: "id-1", title: "t", platform: .imessage, toHandle: "+1", toHandleName: nil,
      body: "b", cadence: .daily, nextRunAt: "2026-01-01T00:00:00Z", recurrenceInterval: 1,
      weekdays: nil, recurrenceAnchorAt: nil, isEnabled: true,
      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
      approvalStatus: approvalStatus, approvalTag: nil, proposedBy: nil,
      lastGeneratedAt: nil, lastGeneratedDraftID: nil, runHistory: nil, failureNote: nil
    )
  }

  private func tmpHome() -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("approval-auth-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
  }

  private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
  }
}
