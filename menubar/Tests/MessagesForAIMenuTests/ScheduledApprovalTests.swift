import XCTest
@testable import MessagesForAIMenu

/// Issue #77 for scheduled drafts: a draft file that merely sets `schedule_approved`
/// or `override_send` on disk must not auto-send; only a GUI-authenticated approval
/// (session or valid HMAC tag) clears the gate.
final class ScheduledApprovalTests: XCTestCase {

  override func setUp() {
    super.setUp()
    setenv("MFA_TEST_APPROVAL_SECRET", "unit-test-fixed-secret", 1)
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
  }

  func testForgedScheduleApprovedFlagIsNotAuthenticated() {
    let forged = makeDraft(scheduleApproved: true, overrideSend: nil, tag: nil)
    XCTAssertEqual(forged.schedule_approved, true)
    XCTAssertFalse(forged.isScheduleAuthenticallyApproved, "schedule_approved=true with no tag must not authenticate")
  }

  func testForgedOverrideSendIsNotAuthenticated() {
    // override_send=true without schedule_approved/tag must NOT bypass the gate.
    let forged = makeDraft(scheduleApproved: nil, overrideSend: true, tag: nil)
    XCTAssertFalse(forged.isScheduleAuthenticallyApproved)
  }

  @MainActor
  func testGuiCreatedScheduledDraftIsAuthenticated() throws {
    let home = tmpHome()
    let store = DraftStore(homeOverride: home)
    let draft = try store.createIMessageDraft(
      toHandle: "+12155550121", toHandleName: "Ryan", body: "hi",
      scheduledAt: Date().addingTimeInterval(-60), approveScheduledDraft: true
    )
    XCTAssertEqual(draft.schedule_approved, true)
    XCTAssertNotNil(draft.schedule_approval_tag)
    XCTAssertTrue(draft.isScheduleAuthenticallyApproved)
  }

  @MainActor
  func testGuiTagSurvivesRelaunch() throws {
    let home = tmpHome()
    let store = DraftStore(homeOverride: home)
    let draft = try store.createIMessageDraft(
      toHandle: "+12155550121", toHandleName: "Ryan", body: "hi",
      scheduledAt: Date().addingTimeInterval(-60), approveScheduledDraft: true
    )
    // Relaunch: drop session approvals; reload from disk.
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
    let reloaded = DraftStore(homeOverride: home)
    let again = try XCTUnwrap(reloaded.drafts.first(where: { $0.id == draft.id }))
    XCTAssertFalse(ApprovalAuthenticator.hasSessionApproval(canonicalMessage: again.scheduleApprovalCanonicalMessage))
    XCTAssertTrue(again.isScheduleAuthenticallyApproved, "persisted tag still authenticates after relaunch")
  }

  @MainActor
  func testForgedDraftWithApprovedFlagOnDiskDoesNotAuthenticate() throws {
    // Write a draft JSON file directly (simulating another process), with
    // schedule_approved=true and a bogus tag, then load it via DraftStore.
    let home = tmpHome()
    let draftsDir = home.appendingPathComponent(".messages-mcp/drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true)
    let id = "forged-draft-1"
    let json = """
    {
      "id": "\(id)",
      "to_handle": "+15551234567",
      "to_handle_name": null,
      "body": "attacker text",
      "in_reply_to_thread_id": null,
      "staged_at": "2026-06-05T00:00:00Z",
      "sent_at": null,
      "send_service": "iMessage",
      "source": null,
      "context_messages": null,
      "context_diagnostic": null,
      "scheduled_send_at": "2020-01-01T00:00:00Z",
      "schedule_hold_reason": null,
      "override_send": true,
      "schedule_approved": true,
      "schedule_approval_tag": "bogusTagAAAA",
      "schema_version": null,
      "platform": "imessage",
      "approval_state": null,
      "induced_by_unknown_contact": null,
      "quoted_message_id": null,
      "quoted_preview": null
    }
    """
    try json.data(using: .utf8)!.write(to: draftsDir.appendingPathComponent("\(id).json"))

    let store = DraftStore(homeOverride: home)
    let loaded = try XCTUnwrap(store.drafts.first(where: { $0.id == id }))
    XCTAssertFalse(loaded.isScheduleAuthenticallyApproved, "forged draft file must not authenticate its own approval")
  }

  // MARK: - Helpers

  private func makeDraft(scheduleApproved: Bool?, overrideSend: Bool?, tag: String?) -> Draft {
    Draft(
      id: "d-1", to_handle: "+1", to_handle_name: nil, body: "b", in_reply_to_thread_id: nil,
      staged_at: "2026-06-05T00:00:00Z", sent_at: nil, send_service: "iMessage", source: nil,
      context_messages: nil, context_diagnostic: nil,
      scheduled_send_at: "2020-01-01T00:00:00Z", schedule_hold_reason: nil,
      override_send: overrideSend, schedule_approved: scheduleApproved,
      schedule_approval_tag: tag, schema_version: nil, platform: .imessage,
      approval_state: nil, induced_by_unknown_contact: nil,
      quoted_message_id: nil, quoted_preview: nil
    )
  }

  private func tmpHome() -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("sched-approval-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }
}
