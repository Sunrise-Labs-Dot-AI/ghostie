import Foundation
import XCTest
@testable import MessagesForAIMenu

final class ConversationConsolidationTests: XCTestCase {
  private func thread(
    _ id: String,
    handle: String,
    daysAgo: Double? = 0,
    platform: Platform = .imessage,
    threadID: Int? = nil,
    unread: Int = 0,
    isGroup: Bool = false,
    preview: String = ""
  ) -> RecentComposeThread {
    var thread = RecentComposeThread(
      id: id,
      platform: platform,
      handle: handle,
      title: id,
      subtitle: handle,
      threadID: threadID,
      lastMessageDate: daysAgo.map { Date(timeIntervalSince1970: 1_000_000 - $0 * 86_400) }
    )
    thread.unreadCount = unread
    thread.isGroup = isGroup
    thread.lastMessagePreview = preview
    return thread
  }

  /// contactKey from a fixed handle → person map (nil = unresolved).
  private func contactKey(_ map: [String: String]) -> (RecentComposeThread) -> String? {
    { map[$0.handle] }
  }

  private func message(_ guid: String, minute: Int, fromMe: Bool = false) -> ContextMessage {
    ContextMessage(
      guid: guid,
      from_me: fromMe,
      sender_handle: fromMe ? nil : "+14045550100",
      sender_name: nil,
      body: guid,
      sent_at: String(format: "2026-06-01T10:%02d:00Z", minute)
    )
  }

  // MARK: - Same-contact merge

  func test_merge_sameContactFoldsToOneRow_newestWinsIdentity() {
    let phone = thread("im-1", handle: "+14045550100", daysAgo: 0, threadID: 1, preview: "newest")
    let email = thread("im-2", handle: "sam@example.com", daysAgo: 3, threadID: 2, preview: "older")
    let merged = ConversationConsolidationPolicy.merge(
      threads: [phone, email],
      contactKey: contactKey(["+14045550100": "sam", "sam@example.com": "sam"])
    )

    XCTAssertEqual(merged.count, 1)
    let row = merged[0]
    XCTAssertEqual(row.id, "im-1")
    XCTAssertEqual(row.handle, "+14045550100")
    XCTAssertEqual(row.threadID, 1)
    XCTAssertEqual(row.lastMessageDate, phone.lastMessageDate)
    XCTAssertEqual(row.lastMessagePreview, "newest")
    XCTAssertEqual(row.consolidatedSiblings.map(\.id), ["im-2"])
    XCTAssertEqual(row.canonicalHandleKeys, ["4045550100", "sam@example.com"])
  }

  func test_merge_newestWinsRegardlessOfInputOrder() {
    let older = thread("a", handle: "sam@example.com", daysAgo: 5)
    let newer = thread("b", handle: "+14045550100", daysAgo: 1)
    let merged = ConversationConsolidationPolicy.merge(
      threads: [older, newer],
      contactKey: contactKey(["sam@example.com": "sam", "+14045550100": "sam"])
    )
    XCTAssertEqual(merged.map(\.id), ["b"])
    XCTAssertEqual(merged[0].consolidatedSiblings.map(\.id), ["a"])
  }

  // MARK: - No-merge cases

  func test_merge_differentContactsStaySeparate() {
    let sam = thread("a", handle: "+14045550100")
    let pam = thread("b", handle: "+14045550101", daysAgo: 1)
    let merged = ConversationConsolidationPolicy.merge(
      threads: [sam, pam],
      contactKey: contactKey(["+14045550100": "sam", "+14045550101": "pam"])
    )
    XCTAssertEqual(merged.map(\.id), ["a", "b"])
    XCTAssertTrue(merged.allSatisfy { $0.consolidatedSiblings.isEmpty })
  }

  func test_merge_unresolvedContactNeverMerges() {
    // Same display name is NOT a merge key — without a contact id, nothing folds.
    let merged = ConversationConsolidationPolicy.merge(
      threads: [thread("a", handle: "+14045550100"), thread("b", handle: "sam@example.com", daysAgo: 1)],
      contactKey: { _ in nil }
    )
    XCTAssertEqual(merged.map(\.id), ["a", "b"])
  }

  func test_merge_groupChatsNeverMerge() {
    let group = thread("g", handle: "+14045550100", daysAgo: 0, isGroup: true)
    let direct = thread("d", handle: "+14045550100", daysAgo: 1)
    let merged = ConversationConsolidationPolicy.merge(
      threads: [group, direct],
      contactKey: contactKey(["+14045550100": "sam"])
    )
    XCTAssertEqual(merged.map(\.id), ["g", "d"])
    XCTAssertTrue(merged.allSatisfy { $0.consolidatedSiblings.isEmpty })
  }

  func test_merge_platformsNeverMergeAcrossEachOther() {
    let imessage = thread("im", handle: "+14045550100")
    let whatsapp = thread("wa", handle: "14045550100@s.whatsapp.net", daysAgo: 1, platform: .whatsapp)
    let merged = ConversationConsolidationPolicy.merge(
      threads: [imessage, whatsapp],
      contactKey: { _ in "sam" }
    )
    XCTAssertEqual(merged.map(\.id), ["im", "wa"])
  }

  // MARK: - Unread aggregation

  func test_merge_unreadAggregatesAcrossMembers() {
    let phone = thread("a", handle: "+14045550100", daysAgo: 0, unread: 0)
    let email = thread("b", handle: "sam@example.com", daysAgo: 2, unread: 3)
    let merged = ConversationConsolidationPolicy.merge(
      threads: [phone, email],
      contactKey: contactKey(["+14045550100": "sam", "sam@example.com": "sam"])
    )
    // The row's own count stays the newest member's (lossless refolds);
    // the dot reads the aggregate.
    XCTAssertEqual(merged[0].unreadCount, 0)
    XCTAssertEqual(merged[0].aggregateUnreadCount, 3)
    XCTAssertTrue(
      ConversationReadLedger().isUnread(
        conversationID: merged[0].id,
        unreadCount: merged[0].aggregateUnreadCount,
        lastMessageDate: merged[0].lastMessageDate
      )
    )
  }

  // MARK: - Shape invariants

  func test_merge_isIdempotent() {
    let threads = [
      thread("a", handle: "+14045550100", daysAgo: 0, unread: 1),
      thread("b", handle: "sam@example.com", daysAgo: 2, unread: 2),
      thread("c", handle: "+14045550199", daysAgo: 1)
    ]
    let key = contactKey(["+14045550100": "sam", "sam@example.com": "sam", "+14045550199": "pam"])
    let once = ConversationConsolidationPolicy.merge(threads: threads, contactKey: key)
    let twice = ConversationConsolidationPolicy.merge(threads: once, contactKey: key)
    XCTAssertEqual(once, twice)
    XCTAssertEqual(twice.first?.aggregateUnreadCount, 3)
  }

  func test_merge_keepsRecencyPositionOfNewestMember() {
    let threads = [
      thread("sam-new", handle: "+14045550100", daysAgo: 0),
      thread("pam", handle: "+14045550199", daysAgo: 1),
      thread("sam-old", handle: "sam@example.com", daysAgo: 2)
    ]
    let merged = ConversationConsolidationPolicy.merge(
      threads: threads,
      contactKey: contactKey(["+14045550100": "sam", "sam@example.com": "sam", "+14045550199": "pam"])
    )
    XCTAssertEqual(merged.map(\.id), ["sam-new", "pam"])
  }

  // MARK: - Transcript union

  func test_unionTranscriptPage_unionsChronologicallyAndDedupesByGuid() {
    let page = ConversationConsolidationPolicy.unionTranscriptPage(
      [
        [message("m1", minute: 1), message("m3", minute: 3)],
        [message("m2", minute: 2), message("m3", minute: 3)]
      ],
      limit: 10
    )
    XCTAssertEqual(page.map(\.guid), ["m1", "m2", "m3"])
  }

  func test_unionTranscriptPage_capsToNewestLimit_discardsAreStrictlyOlder() {
    // Same cursor discipline as page assembly: everything cut must be older
    // than everything kept, so the next strictly-older fetch re-reads it.
    let page = ConversationConsolidationPolicy.unionTranscriptPage(
      [
        [message("a1", minute: 1), message("a3", minute: 3)],
        [message("b2", minute: 2), message("b4", minute: 4)]
      ],
      limit: 2
    )
    XCTAssertEqual(page.map(\.guid), ["a3", "b4"])
  }

  func test_unionTranscriptPage_boundaryTimestampTiesRideAlong() {
    let page = ConversationConsolidationPolicy.unionTranscriptPage(
      [
        [message("a2", minute: 2), message("a5", minute: 5)],
        [message("b2", minute: 2), message("b1", minute: 1)]
      ],
      limit: 2
    )
    XCTAssertEqual(page.map(\.guid), ["a2", "b2", "a5"])
  }

  func test_unionTranscriptPage_underLimitMeansEveryMemberExhausted() {
    let page = ConversationConsolidationPolicy.unionTranscriptPage(
      [[message("m1", minute: 1)], [message("m2", minute: 2)]],
      limit: 10
    )
    // count < limit is the hasLoadedAllAvailableHistory contract.
    XCTAssertEqual(page.count, 2)
  }

  // MARK: - Surrounding policies honor folded members

  func test_searchMerge_dropsDatabaseHitAlreadyFoldedIntoLoadedRow() {
    var row = thread("sam-new", handle: "+14045550100", daysAgo: 0)
    row.consolidatedSiblings = [thread("sam-old", handle: "sam@example.com", daysAgo: 2)]
    let merged = ConversationSearchMergePolicy.merge(
      loadedMatches: [MessageConversation(recent: row, draftThread: nil)],
      databaseMatches: [thread("sam-old", handle: "sam@example.com", daysAgo: 2)]
    )
    XCTAssertEqual(merged.map(\.id), ["sam-new"])
  }

  func test_handleMatcher_reachesRowViaFoldedSiblingHandle() {
    var row = thread("sam-new", handle: "+14045550100", daysAgo: 0)
    row.consolidatedSiblings = [thread("sam-old", handle: "sam@example.com", daysAgo: 2)]
    let match = ConversationHandleMatcher.match(
      handles: ["sam@example.com"],
      in: [MessageConversation(recent: row, draftThread: nil)]
    )
    XCTAssertEqual(match?.id, "sam-new")
  }
}
