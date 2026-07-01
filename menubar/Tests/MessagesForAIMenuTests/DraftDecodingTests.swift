import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Decoding coverage for the reply-draft fields (`quoted_message_id` +
/// `quoted_preview`) added for "reply to a specific message". Confirms the
/// WhatsApp reply shape populates and that iMessage / ordinary WhatsApp
/// drafts decode the new optional fields as nil (back-compat).
final class DraftDecodingTests: XCTestCase {
  private func decode(_ json: String) throws -> Draft {
    try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
  }

  func test_scheduledDraft_decodesSchedulingFields() throws {
    let json = """
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "to_handle": "+14045550147",
      "to_handle_name": "Allie",
      "body": "Happy birthday!",
      "in_reply_to_thread_id": null,
      "staged_at": "2026-06-01T12:00:00.000Z",
      "sent_at": null,
      "send_service": null,
      "source": "Messages for AI / Birthdays",
      "context_messages": null,
      "context_diagnostic": null,
      "scheduled_send_at": "2026-06-04T16:00:00.000Z",
      "schedule_hold_reason": null,
      "override_send": null
    }
    """
    let d = try decode(json)
    XCTAssertTrue(d.isScheduled)
    XCTAssertFalse(d.isHeld)
    XCTAssertNotNil(d.scheduledDate)
    XCTAssertEqual(d.effectivePlatform, .imessage)
  }

  func test_heldDraft_isHeld() throws {
    let json = """
    {
      "id": "33333333-3333-3333-3333-333333333333",
      "to_handle": "+14045550147", "to_handle_name": "Allie", "body": "Happy birthday!",
      "in_reply_to_thread_id": null, "staged_at": "2026-06-01T12:00:00.000Z",
      "sent_at": null, "send_service": null, "source": null,
      "context_messages": null, "context_diagnostic": null,
      "scheduled_send_at": "2026-06-04T16:00:00.000Z",
      "schedule_hold_reason": "quiet_hours", "override_send": null
    }
    """
    let d = try decode(json)
    XCTAssertTrue(d.isHeld)
    XCTAssertEqual(d.schedule_hold_reason, "quiet_hours")
  }

  func test_legacyDraft_hasNilSchedulingFields() throws {
    // A pre-schedule-send draft (fields absent) must decode with nil scheduling.
    let json = """
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "to_handle": "+14045550147", "to_handle_name": null, "body": "hi",
      "in_reply_to_thread_id": null, "staged_at": "2026-06-01T12:00:00.000Z",
      "sent_at": null, "send_service": null, "source": null,
      "context_messages": null, "context_diagnostic": null
    }
    """
    let d = try decode(json)
    XCTAssertFalse(d.isScheduled)
    XCTAssertNil(d.scheduled_send_at)
  }

  func test_whatsappReplyDraft_decodesQuotedFields() throws {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "schema_version": 1,
      "platform": "whatsapp",
      "approval_state": "pending",
      "to_handle": "12025550001@s.whatsapp.net",
      "to_handle_name": "Alice",
      "body": "yes!",
      "staged_at": "2026-05-26T12:00:00.000Z",
      "sent_at": null,
      "source": "claude-desktop",
      "context_messages": [],
      "context_diagnostic": null,
      "induced_by_unknown_contact": false,
      "quoted_message_id": "orig-1",
      "quoted_preview": {
        "message_id": "orig-1",
        "body": "are we still on for 3?",
        "from_me": false,
        "sender_name": "Alice"
      }
    }
    """
    let d = try decode(json)
    XCTAssertEqual(d.effectivePlatform, .whatsapp)
    XCTAssertEqual(d.quoted_message_id, "orig-1")
    XCTAssertNotNil(d.quoted_preview)
    XCTAssertEqual(d.quoted_preview?.body, "are we still on for 3?")
    XCTAssertEqual(d.quoted_preview?.from_me, false)
    XCTAssertEqual(d.quoted_preview?.displayName, "Alice")
  }

  func test_imessageDraft_withoutQuotedFields_decodesNil() throws {
    let json = """
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "to_handle": "+14155551234",
      "to_handle_name": null,
      "body": "hello",
      "in_reply_to_thread_id": 42,
      "staged_at": "2026-05-26T12:00:00.000Z",
      "sent_at": null,
      "send_service": null,
      "source": "Claude Code",
      "context_messages": null,
      "context_diagnostic": null
    }
    """
    let d = try decode(json)
    XCTAssertEqual(d.effectivePlatform, .imessage)
    XCTAssertNil(d.quoted_message_id)
    XCTAssertNil(d.quoted_preview)
  }

  func test_whatsappOrdinaryDraft_hasNilQuotedFields() throws {
    let json = """
    {
      "id": "33333333-3333-3333-3333-333333333333",
      "schema_version": 1,
      "platform": "whatsapp",
      "approval_state": "pending",
      "to_handle": "12025550001@s.whatsapp.net",
      "to_handle_name": "Bob",
      "body": "hi",
      "staged_at": "2026-05-26T12:00:00.000Z",
      "sent_at": null,
      "source": "claude-desktop",
      "context_messages": [],
      "context_diagnostic": null,
      "induced_by_unknown_contact": false
    }
    """
    let d = try decode(json)
    XCTAssertNil(d.quoted_message_id)
    XCTAssertNil(d.quoted_preview)
  }

  func test_quotedPreview_fromMe_displayNameIsYou() throws {
    let json = """
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "schema_version": 1,
      "platform": "whatsapp",
      "approval_state": "pending",
      "to_handle": "12025550001@s.whatsapp.net",
      "to_handle_name": "Alice",
      "body": "following up",
      "staged_at": "2026-05-26T12:00:00.000Z",
      "sent_at": null,
      "source": "claude-desktop",
      "context_messages": [],
      "context_diagnostic": null,
      "induced_by_unknown_contact": false,
      "quoted_message_id": "self-1",
      "quoted_preview": { "message_id": "self-1", "body": "my earlier msg", "from_me": true, "sender_name": null }
    }
    """
    let d = try decode(json)
    XCTAssertEqual(d.quoted_preview?.displayName, "You")
  }
}
