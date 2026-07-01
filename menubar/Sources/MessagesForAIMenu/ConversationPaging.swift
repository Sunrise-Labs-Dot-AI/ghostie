import Foundation

/// Pure pagination policy for the Messages tab's all-time conversation list.
/// Pages are fetched from three independent recency-ordered sources (iMessage
/// 1:1, iMessage groups, WhatsApp); these functions own cursor computation,
/// page assembly, merge/dedupe, and the infinite-scroll trigger so the SQL
/// loaders and the view stay dumb.
enum ConversationPagingPolicy {
  static let pageSize = 120
  /// Rows from the end of the rendered list at which the next page starts
  /// loading — enough runway that a steady scroll never hits the bottom.
  static let sentinelDistanceFromEnd = 10

  /// Cursor for the next page: the oldest loaded conversation's last-message
  /// date (the next fetch reads rows strictly older). Rows without a date
  /// can't anchor a cursor and are ignored.
  static func nextCursor(loadedThreads: [RecentComposeThread]) -> Date? {
    loadedThreads.compactMap(\.lastMessageDate).min()
  }

  /// Assemble one page from per-source candidate fetches (each already
  /// limited to `pageSize` rows older than the shared cursor): newest first,
  /// keep the top `pageSize`. Keeping only the top slice is what makes one
  /// cursor correct across three sources — every discarded candidate is older
  /// than every kept row, so the next strictly-older fetch re-reads it.
  /// Candidates that TIE the boundary date ride along (a strictly-older fetch
  /// could never reach an equal-dated discard).
  static func assemblePage(
    candidates: [RecentComposeThread],
    pageSize: Int = pageSize
  ) -> (page: [RecentComposeThread], hasMore: Bool) {
    let sorted = candidates.sorted {
      ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast)
    }
    var page = Array(sorted.prefix(pageSize))
    if let boundary = page.last?.lastMessageDate {
      page.append(contentsOf: sorted.dropFirst(page.count).prefix { $0.lastMessageDate == boundary })
    }
    // A short combined fetch means every source under-filled its limit —
    // nothing older remains. A full page may end exactly at the data's edge;
    // the single empty fetch that detects it is harmless.
    return (page, sorted.count >= pageSize)
  }

  /// Append a fetched page to the loaded set. Existing rows win the dedupe
  /// (boundary re-reads are expected); appended rows keep their recency
  /// order below the already-loaded slice so the scroll anchor never moves.
  static func appendingPage(
    _ page: [RecentComposeThread],
    to loadedThreads: [RecentComposeThread]
  ) -> [RecentComposeThread] {
    var seen = Set(loadedThreads.map(\.id))
    return loadedThreads + page.filter { seen.insert($0.id).inserted }
  }

  /// Live-refresh strategy: re-fetch ONLY the first page and union it over
  /// everything already loaded, fresh rows winning the dedupe. New activity
  /// lands in page-one territory by definition (recency ordering), so the
  /// union is gap-free; rows beyond the first page keep their last-loaded
  /// snapshot until re-fetched. Chosen over re-walking every appended page
  /// because it's one fetch and never disturbs the user's scroll depth.
  static func refreshedThreads(
    freshFirstPage: [RecentComposeThread],
    previous: [RecentComposeThread]
  ) -> [RecentComposeThread] {
    var seen = Set(freshFirstPage.map(\.id))
    let kept = previous.filter { seen.insert($0.id).inserted }
    return (freshFirstPage + kept).sorted {
      ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast)
    }
  }

  /// Infinite-scroll trigger: fires when a row inside the sentinel window
  /// renders. Searching suppresses paging — the DB-wide search already covers
  /// conversations the pager hasn't reached.
  static func shouldLoadNextPage(
    appearedIndex: Int,
    totalCount: Int,
    isLoading: Bool,
    hasMore: Bool,
    isSearching: Bool,
    sentinelDistance: Int = sentinelDistanceFromEnd
  ) -> Bool {
    guard hasMore, !isLoading, !isSearching, totalCount > 0 else { return false }
    return appearedIndex >= max(0, totalCount - sentinelDistance)
  }
}

/// Pure merge policy for conversation search: typed queries always filter the
/// loaded rows in memory, and (at >= 2 chars, debounced) also hit the
/// databases across ALL conversations so threads not yet paged in are
/// findable.
enum ConversationSearchMergePolicy {
  static let minDatabaseQueryLength = 2
  static let debounceNanoseconds: UInt64 = 250_000_000

  static func shouldSearchDatabase(query: String) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minDatabaseQueryLength
  }

  /// Loaded matches keep their identity (drafts, previews, priority); DB hits
  /// only add conversations the pager hasn't reached. The union is re-sorted
  /// by recency so ordering is coherent regardless of source. Dedupe spans
  /// folded sibling ids — a DB hit for a thread already consolidated into a
  /// loaded row must not resurface as a second row.
  static func merge(
    loadedMatches: [MessageConversation],
    databaseMatches: [RecentComposeThread]
  ) -> [MessageConversation] {
    var seen = Set(loadedMatches.flatMap { [$0.id] + $0.recent.consolidatedSiblings.map(\.id) })
    let extras = databaseMatches
      .filter { seen.insert($0.id).inserted }
      .map { MessageConversation(recent: $0, draftThread: nil) }
    return (loadedMatches + extras).sorted { lhs, rhs in
      let left = lhs.lastMessageDate ?? .distantPast
      let right = rhs.lastMessageDate ?? .distantPast
      if left == right {
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
      return left > right
    }
  }
}
