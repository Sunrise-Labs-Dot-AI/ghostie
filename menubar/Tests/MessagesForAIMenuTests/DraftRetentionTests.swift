import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Covers the pure sweep predicate behind DraftStore.sweepSentDrafts: sent
/// iMessage drafts age out after the TTL; pending drafts are never swept.
final class DraftRetentionTests: XCTestCase {
  private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)!
  }

  private func imessageDraft(sentAt: String?) throws -> Draft {
    let sentField = sentAt.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "to_handle": "a@b.com",
      "to_handle_name": null,
      "body": "hi",
      "in_reply_to_thread_id": null,
      "staged_at": "2026-05-20T12:00:00.000Z",
      "sent_at": \(sentField),
      "send_service": "iMessage",
      "source": "test",
      "context_messages": null,
      "context_diagnostic": null
    }
    """
    return try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
  }

  private let now = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
  private var ttl: TimeInterval { DraftStore.sentDraftTTL } // 7 days

  func test_sentDraftOlderThanTTL_isExpired() throws {
    let d = try imessageDraft(sentAt: "2026-05-24T00:00:00.000Z") // 8 days before now
    XCTAssertTrue(DraftStore.isExpiredSentDraft(d, now: now, ttl: ttl))
  }

  func test_recentlySentDraft_isNotExpired() throws {
    let d = try imessageDraft(sentAt: "2026-05-31T00:00:00.000Z") // 1 day before now
    XCTAssertFalse(DraftStore.isExpiredSentDraft(d, now: now, ttl: ttl))
  }

  func test_justInsideTTL_isNotExpired() throws {
    // 6 days 23h before now — still inside the 7-day window.
    let d = try imessageDraft(sentAt: "2026-05-25T01:00:00.000Z")
    XCTAssertFalse(DraftStore.isExpiredSentDraft(d, now: now, ttl: ttl))
  }

  func test_pendingDraft_isNeverExpired() throws {
    let d = try imessageDraft(sentAt: nil) // never sent
    XCTAssertFalse(d.isSent)
    XCTAssertFalse(DraftStore.isExpiredSentDraft(d, now: now, ttl: ttl))
  }
}
