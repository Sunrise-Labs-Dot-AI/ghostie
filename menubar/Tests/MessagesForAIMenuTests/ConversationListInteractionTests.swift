import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Cross-feature seams in the Messages tab list: consolidation × read ledger,
/// consolidation × paging, consolidation × thread priority, and the sort
/// picker × priority float. Each policy is unit-tested alone elsewhere; these
/// tests pin the contracts BETWEEN them, which is where the live regressions
/// were possible.
final class ConversationListInteractionTests: XCTestCase {
  private func thread(
    _ id: String,
    handle: String,
    daysAgo: Double = 0,
    threadID: Int? = nil,
    unread: Int = 0
  ) -> RecentComposeThread {
    var thread = RecentComposeThread(
      id: id,
      platform: .imessage,
      handle: handle,
      title: id,
      subtitle: handle,
      threadID: threadID,
      lastMessageDate: Date(timeIntervalSince1970: 2_000_000 - daysAgo * 86_400)
    )
    thread.unreadCount = unread
    return thread
  }

  private let samIdentity = ["+14045550100": "sam", "sam@example.com": "sam"]

  private func mergeSam(_ threads: [RecentComposeThread]) -> [RecentComposeThread] {
    ConversationConsolidationPolicy.merge(threads: threads) { self.samIdentity[$0.handle] }
  }

  // MARK: - Consolidation × read ledger

  func test_markSeenOnMergedRow_clearsTheAggregateDot() {
    // The dot reads the AGGREGATE unread (sibling carries the 3); marking
    // the merged row seen must clear it even though the row's own unread is 0.
    let merged = mergeSam([
      thread("sam-phone", handle: "+14045550100", daysAgo: 0, unread: 0),
      thread("sam-email", handle: "sam@example.com", daysAgo: 2, unread: 3),
    ])[0]
    XCTAssertEqual(merged.aggregateUnreadCount, 3)

    let ledger = ConversationReadLedger().markingSeen(thread: merged)
    XCTAssertFalse(
      ledger.isUnread(
        conversationID: merged.id,
        unreadCount: merged.aggregateUnreadCount,
        lastMessageDate: merged.lastMessageDate
      )
    )
  }

  func test_markSeenOnMergedRow_coversSiblingsThroughAnUnfold() {
    // Identity resolution is async and cache-backed: after a relaunch the
    // same threads can render UNFOLDED until Contacts answers. The sibling's
    // own id must already carry a seen mark, or the dot the user just
    // cleared comes back.
    let phone = thread("sam-phone", handle: "+14045550100", daysAgo: 0, unread: 0)
    let email = thread("sam-email", handle: "sam@example.com", daysAgo: 2, unread: 3)
    let merged = mergeSam([phone, email])[0]

    let ledger = ConversationReadLedger().markingSeen(thread: merged)

    XCTAssertFalse(
      ledger.isUnread(
        conversationID: email.id,
        unreadCount: email.unreadCount,
        lastMessageDate: email.lastMessageDate
      ),
      "unfolded sibling resurfaced a dot the user already cleared"
    )
  }

  func test_newSiblingMessageAfterMarkSeen_resurfacesTheDotOnTheFlippedRow() {
    // After a live refresh hands the SIBLING the newest message, the merged
    // row's identity flips onto the sibling. The earlier seen marks are all
    // older than the new message, so the dot must come back.
    let phone = thread("sam-phone", handle: "+14045550100", daysAgo: 1, unread: 0)
    let email = thread("sam-email", handle: "sam@example.com", daysAgo: 2, unread: 0)
    let ledger = ConversationReadLedger().markingSeen(thread: mergeSam([phone, email])[0])

    var freshEmail = thread("sam-email", handle: "sam@example.com", daysAgo: 0, unread: 1)
    freshEmail.lastMessagePreview = "new message"
    let refreshed = ConversationPagingPolicy.refreshedThreads(
      freshFirstPage: [freshEmail],
      previous: [phone, email]
    )
    let refolded = mergeSam(refreshed)[0]

    XCTAssertEqual(refolded.id, "sam-email", "newest member keeps the row identity")
    XCTAssertTrue(
      ledger.isUnread(
        conversationID: refolded.id,
        unreadCount: refolded.aggregateUnreadCount,
        lastMessageDate: refolded.lastMessageDate
      ),
      "a genuinely new message must re-dot the merged row"
    )
  }

  // MARK: - Consolidation × paging

  func test_foldingAfterPageAppend_foldsRenderedListButCursorStaysOnRawRows() {
    // Page 2 brings in an older thread of an already-loaded person. The
    // rendered list folds it away; the pager's cursor must keep anchoring on
    // the RAW row set, or the next fetch would skip everything between the
    // merged row's (new) date and the folded sibling's (old) date.
    let pageOne = [
      thread("sam-phone", handle: "+14045550100", daysAgo: 0),
      thread("pam", handle: "+14045550199", daysAgo: 1),
    ]
    let pageTwo = [
      thread("sam-email", handle: "sam@example.com", daysAgo: 5),
      thread("quinn", handle: "+14045550177", daysAgo: 6),
    ]

    let raw = ConversationPagingPolicy.appendingPage(pageTwo, to: pageOne)
    let rendered = mergeSam(raw)

    XCTAssertEqual(rendered.map(\.id), ["sam-phone", "pam", "quinn"])
    XCTAssertEqual(rendered[0].consolidatedSiblings.map(\.id), ["sam-email"])
    // Cursor from the raw rows reaches the data's true frontier (quinn),
    // unaffected by the fold.
    XCTAssertEqual(
      ConversationPagingPolicy.nextCursor(loadedThreads: raw),
      thread("quinn", handle: "+14045550177", daysAgo: 6).lastMessageDate
    )
    // Folding the rendered list must never feed the cursor: the merged set
    // has lost sam-email as a row, but the raw set still carries its date.
    XCTAssertNotEqual(
      ConversationPagingPolicy.nextCursor(loadedThreads: raw),
      ConversationPagingPolicy.nextCursor(loadedThreads: [rendered[0], rendered[1]])
    )
  }

  // MARK: - Consolidation × thread priority

  @MainActor
  func test_priorityOnFoldedSiblingStillFloatsTheMergedRow() throws {
    // The MCP keys iMessage priorities on the chat ROWID. When that chat is
    // folded away as a sibling, the merged row must still answer for it —
    // and the most urgent member must win.
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("priority-consolidation-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    setenv("MESSAGES_FOR_AI_HOME", scratch.path, 1)
    defer {
      unsetenv("MESSAGES_FOR_AI_HOME")
      try? FileManager.default.removeItem(at: scratch)
    }

    let store = ThreadPriorityStore(startWatching: false)
    let phone = thread("sam-phone", handle: "+14045550100", daysAgo: 0, threadID: 1)
    let email = thread("sam-email", handle: "sam@example.com", daysAgo: 2, threadID: 2)

    store.setPriority(.urgent, for: email)
    let merged = mergeSam([phone, email])[0]
    XCTAssertEqual(merged.id, "sam-phone")
    XCTAssertEqual(store.priority(for: merged)?.level, 1)

    // Most urgent member wins when both carry an entry.
    store.setPriority(.elevated, for: phone)
    XCTAssertEqual(store.priority(for: merged)?.level, 1)

    // Un-merged rows are unaffected by the sibling walk.
    XCTAssertEqual(store.priority(for: phone)?.level, 3)
  }

  // MARK: - Sort order × priority partition

  func test_sortOrderPolicy_priorityFirstFloatsAndRecentNeverDoes() {
    let conversations = [
      MessageConversation(recent: thread("recent-plain", handle: "+14045550101", daysAgo: 0), draftThread: nil),
      MessageConversation(recent: thread("older-urgent", handle: "+14045550102", daysAgo: 3), draftThread: nil),
    ]
    let entries: [String: ThreadPriorityEntry] = [
      "older-urgent": ThreadPriorityEntry(level: 1, reason: nil, setAt: nil, setBy: "agent")
    ]
    let priorityFor: (MessageConversation) -> ThreadPriorityEntry? = { entries[$0.id] }

    XCTAssertEqual(
      ConversationListOrderPolicy.ordered(conversations, sortOrder: .priorityFirst, priorityFor: priorityFor)
        .map(\.id),
      ["older-urgent", "recent-plain"]
    )
    // Recent is the pure Messages.app ordering — priorities exist but must
    // not float.
    XCTAssertEqual(
      ConversationListOrderPolicy.ordered(conversations, sortOrder: .recent, priorityFor: priorityFor)
        .map(\.id),
      ["recent-plain", "older-urgent"]
    )
  }
}
