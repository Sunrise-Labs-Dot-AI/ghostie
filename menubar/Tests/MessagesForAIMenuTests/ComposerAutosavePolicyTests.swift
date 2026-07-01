import XCTest
@testable import MessagesForAIMenu

final class ComposerAutosavePolicyTests: XCTestCase {
  // A simple stand-in for ContactAvatarStore.canonicalKey so the pure policy is
  // testable without Contacts: phone digits (last 10) or a lowercased email.
  private func canon(_ h: String) -> String? {
    if h.contains("@") { return h.lowercased() }
    let digits = h.filter(\.isNumber)
    return digits.isEmpty ? nil : String(digits.suffix(10))
  }

  private func draft(
    id: String, to: String, body: String, source: String?, sent: Bool = false, platform: Platform? = nil
  ) -> Draft {
    Draft(
      id: id, to_handle: to, to_handle_name: nil, imessage_group: nil, body: body,
      in_reply_to_thread_id: nil, staged_at: "2026-01-01T00:00:00Z",
      sent_at: sent ? "2026-01-02T00:00:00Z" : nil, send_service: nil, source: source,
      context_messages: nil, context_diagnostic: nil, scheduled_send_at: nil,
      schedule_hold_reason: nil, override_send: nil, schedule_approved: nil,
      schedule_approval_tag: nil, schema_version: nil, platform: platform,
      approval_state: nil, induced_by_unknown_contact: nil, quoted_message_id: nil,
      quoted_preview: nil
    )
  }

  func testExistingDraftMatchesOwnSourceAndRecipient() {
    let drafts = [
      draft(id: "ai", to: "+14155550123", body: "AI proposed", source: "Claude Desktop"),
      draft(id: "mine", to: "+1 (415) 555-0123", body: "my unsent text", source: ComposerAutosavePolicy.source),
      draft(id: "other", to: "+14155559999", body: "other person", source: ComposerAutosavePolicy.source),
    ]
    let found = ComposerAutosavePolicy.existingDraft(
      in: drafts, platform: .imessage, handle: "+14155550123", canonicalize: canon
    )
    XCTAssertEqual(found?.id, "mine", "matches our composer draft for this recipient, never the AI draft")
  }

  func testExistingDraftIgnoresSentAndWrongPlatform() {
    let drafts = [
      draft(id: "sent", to: "+14155550123", body: "already sent", source: ComposerAutosavePolicy.source, sent: true),
      draft(id: "wa", to: "+14155550123", body: "whatsapp", source: ComposerAutosavePolicy.source, platform: .whatsapp),
    ]
    XCTAssertNil(ComposerAutosavePolicy.existingDraft(
      in: drafts, platform: .imessage, handle: "+14155550123", canonicalize: canon
    ))
  }

  func testActionCreateUpdateDiscardNone() {
    let existing = draft(id: "x", to: "+14155550123", body: "hello", source: ComposerAutosavePolicy.source)
    // No draft yet + text typed → create
    XCTAssertEqual(ComposerAutosavePolicy.action(forBody: "  hi ", existing: nil), .create(body: "hi"))
    // Existing draft + changed text → update
    XCTAssertEqual(
      ComposerAutosavePolicy.action(forBody: "hello there", existing: existing),
      .update(id: "x", body: "hello there")
    )
    // Existing draft + identical text → none (churn guard for restore)
    XCTAssertEqual(ComposerAutosavePolicy.action(forBody: "hello", existing: existing), .none)
    // Text emptied + existing draft → discard
    XCTAssertEqual(ComposerAutosavePolicy.action(forBody: "   ", existing: existing), .discard(id: "x"))
    // Empty + no draft → none
    XCTAssertEqual(ComposerAutosavePolicy.action(forBody: "", existing: nil), .none)
  }
}
