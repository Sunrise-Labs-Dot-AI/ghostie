import Foundation
import XCTest
@testable import MessagesForAIMenu

final class ConversationPagingTests: XCTestCase {
  private func thread(
    _ id: String,
    daysAgo: Double? = 0,
    title: String? = nil,
    date: Date? = nil
  ) -> RecentComposeThread {
    RecentComposeThread(
      id: id,
      platform: .imessage,
      handle: "+1404555\(abs(id.hashValue % 10_000))",
      title: title ?? id,
      subtitle: "",
      threadID: nil,
      lastMessageDate: date ?? daysAgo.map { Date(timeIntervalSince1970: 1_000_000 - $0 * 86_400) }
    )
  }

  // MARK: - Cursor

  func test_nextCursor_isOldestLoadedLastMessageDate() {
    let threads = [thread("a", daysAgo: 1), thread("b", daysAgo: 9), thread("c", daysAgo: 4)]
    XCTAssertEqual(
      ConversationPagingPolicy.nextCursor(loadedThreads: threads),
      threads[1].lastMessageDate
    )
  }

  func test_nextCursor_ignoresDatelessRowsAndIsNilWhenNoneRemain() {
    let dated = thread("a", daysAgo: 2)
    XCTAssertEqual(
      ConversationPagingPolicy.nextCursor(loadedThreads: [dated, thread("b", daysAgo: nil)]),
      dated.lastMessageDate
    )
    XCTAssertNil(ConversationPagingPolicy.nextCursor(loadedThreads: [thread("b", daysAgo: nil)]))
    XCTAssertNil(ConversationPagingPolicy.nextCursor(loadedThreads: []))
  }

  // MARK: - Page assembly

  func test_assemblePage_keepsNewestPageSizeAcrossSourcesAndReportsMore() {
    // Two interleaved "sources" — assembly must take the global top slice.
    let older = (0..<4).map { thread("wa-\($0)", daysAgo: Double($0) * 2 + 1) }
    let newer = (0..<4).map { thread("im-\($0)", daysAgo: Double($0) * 2) }
    let result = ConversationPagingPolicy.assemblePage(candidates: older + newer, pageSize: 4)

    XCTAssertEqual(result.page.map(\.id), ["im-0", "wa-0", "im-1", "wa-1"])
    XCTAssertTrue(result.hasMore)
  }

  func test_assemblePage_shortCombinedFetchMeansExhausted() {
    let result = ConversationPagingPolicy.assemblePage(
      candidates: [thread("a", daysAgo: 1), thread("b", daysAgo: 2)],
      pageSize: 4
    )
    XCTAssertEqual(result.page.count, 2)
    XCTAssertFalse(result.hasMore)
  }

  func test_assemblePage_boundaryDateTiesRideAlong() {
    // A strictly-older next fetch could never reach an equal-dated discard,
    // so ties with the kept page's oldest row must be included now.
    let shared = Date(timeIntervalSince1970: 500_000)
    let candidates = [
      thread("a", daysAgo: 0),
      thread("b", date: shared),
      thread("c", date: shared),
      thread("d", daysAgo: 30)
    ]
    let result = ConversationPagingPolicy.assemblePage(candidates: candidates, pageSize: 2)
    XCTAssertEqual(Set(result.page.map(\.id)), ["a", "b", "c"])
    XCTAssertTrue(result.hasMore)
  }

  // MARK: - Append / dedupe

  func test_appendingPage_dedupesByIdKeepingExistingRowAndOrder() {
    var existing = thread("a", daysAgo: 1)
    existing.lastMessagePreview = "kept"
    let loaded = [existing, thread("b", daysAgo: 2)]
    let page = [thread("a", daysAgo: 1), thread("c", daysAgo: 3), thread("d", daysAgo: 4)]

    let merged = ConversationPagingPolicy.appendingPage(page, to: loaded)

    XCTAssertEqual(merged.map(\.id), ["a", "b", "c", "d"])
    XCTAssertEqual(merged.first?.lastMessagePreview, "kept")
  }

  // MARK: - Live refresh

  func test_refreshedThreads_freshFirstPageWinsAndAppendedPagesSurvive() {
    var stale = thread("a", daysAgo: 5)
    stale.unreadCount = 0
    var fresh = thread("a", daysAgo: 0)
    fresh.unreadCount = 2
    let appended = [thread("old-1", daysAgo: 40), thread("old-2", daysAgo: 50)]

    let refreshed = ConversationPagingPolicy.refreshedThreads(
      freshFirstPage: [fresh, thread("new", daysAgo: 1)],
      previous: [stale, thread("b", daysAgo: 6)] + appended
    )

    XCTAssertEqual(refreshed.map(\.id), ["a", "new", "b", "old-1", "old-2"])
    XCTAssertEqual(refreshed.first?.unreadCount, 2)
  }

  // MARK: - Infinite-scroll sentinel

  func test_shouldLoadNextPage_firesOnlyInsideSentinelWindow() {
    func fires(at index: Int) -> Bool {
      ConversationPagingPolicy.shouldLoadNextPage(
        appearedIndex: index,
        totalCount: 120,
        isLoading: false,
        hasMore: true,
        isSearching: false
      )
    }
    XCTAssertFalse(fires(at: 0))
    XCTAssertFalse(fires(at: 109))
    XCTAssertTrue(fires(at: 110))
    XCTAssertTrue(fires(at: 119))
  }

  func test_shouldLoadNextPage_suppressedWhileLoadingExhaustedOrSearching() {
    func fires(isLoading: Bool = false, hasMore: Bool = true, isSearching: Bool = false) -> Bool {
      ConversationPagingPolicy.shouldLoadNextPage(
        appearedIndex: 119,
        totalCount: 120,
        isLoading: isLoading,
        hasMore: hasMore,
        isSearching: isSearching
      )
    }
    XCTAssertTrue(fires())
    XCTAssertFalse(fires(isLoading: true))
    XCTAssertFalse(fires(hasMore: false))
    XCTAssertFalse(fires(isSearching: true))
  }

  func test_shouldLoadNextPage_shortListFiresFromAnyRowButNeverOnEmpty() {
    XCTAssertTrue(
      ConversationPagingPolicy.shouldLoadNextPage(
        appearedIndex: 0, totalCount: 5, isLoading: false, hasMore: true, isSearching: false
      )
    )
    XCTAssertFalse(
      ConversationPagingPolicy.shouldLoadNextPage(
        appearedIndex: 0, totalCount: 0, isLoading: false, hasMore: true, isSearching: false
      )
    )
  }

  // MARK: - Search merge

  func test_searchMerge_dedupesByIdPrefersLoadedRowAndOrdersByRecency() {
    let loadedMatch = MessageConversation(recent: thread("a", daysAgo: 3), draftThread: nil)
    let duplicate = thread("a", daysAgo: 3)
    let newer = thread("db-new", daysAgo: 1)
    let older = thread("db-old", daysAgo: 9)

    let merged = ConversationSearchMergePolicy.merge(
      loadedMatches: [loadedMatch],
      databaseMatches: [older, duplicate, newer]
    )

    XCTAssertEqual(merged.map(\.id), ["db-new", "a", "db-old"])
  }

  func test_searchMerge_equalDatesTieBreakOnTitle() {
    let date = Date(timeIntervalSince1970: 700_000)
    let merged = ConversationSearchMergePolicy.merge(
      loadedMatches: [MessageConversation(recent: thread("1", title: "Zoe", date: date), draftThread: nil)],
      databaseMatches: [thread("2", title: "Allie", date: date)]
    )
    XCTAssertEqual(merged.map(\.title), ["Allie", "Zoe"])
  }

  func test_shouldSearchDatabase_requiresTwoNonWhitespaceBoundedChars() {
    XCTAssertFalse(ConversationSearchMergePolicy.shouldSearchDatabase(query: ""))
    XCTAssertFalse(ConversationSearchMergePolicy.shouldSearchDatabase(query: " a "))
    XCTAssertTrue(ConversationSearchMergePolicy.shouldSearchDatabase(query: "al"))
    XCTAssertTrue(ConversationSearchMergePolicy.shouldSearchDatabase(query: "  al  "))
  }
}
