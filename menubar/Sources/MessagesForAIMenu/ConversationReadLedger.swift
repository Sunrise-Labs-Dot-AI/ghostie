import Foundation

/// App-side read state for the Messages tab.
///
/// chat.db's `is_read` only flips when Messages.app itself displays a thread —
/// this app is strictly read-only on Apple's database, so opening a thread
/// HERE can never clear the database's unread flag. The ledger layers our own
/// "last seen" instant per conversation over the DB signal: a row shows the
/// unread dot only when the database says unread AND the user hasn't seen the
/// conversation's newest message in this app.
///
/// Pure value type — persistence lives in MessagesViewState.
struct ConversationReadLedger: Codable, Equatable {
  /// conversation.id → the lastMessageDate the user has seen (monotonic).
  private(set) var seen: [String: Date] = [:]

  /// Keep the file small: drop the oldest entries past this cap. 500 covers
  /// every conversation a human plausibly cycles through.
  static let maxEntries = 500

  /// The row-dot rule: DB-unread, minus anything seen in-app at or after the
  /// newest message. A nil lastMessageDate can't be compared, so the DB wins.
  func isUnread(conversationID: String, unreadCount: Int, lastMessageDate: Date?) -> Bool {
    guard unreadCount > 0 else { return false }
    guard let lastMessageDate, let seenDate = seen[conversationID] else { return true }
    return lastMessageDate > seenDate
  }

  /// Marks a consolidated row seen: the row itself plus every folded sibling,
  /// each at its own newest message. Sibling marks must persist under the
  /// siblings' OWN ids — if the row later un-folds (identity cache reset,
  /// Contacts permission revoked), the standalone sibling row must not
  /// resurface a dot for messages the user already saw in the merged
  /// transcript. A sibling that receives a NEW message still re-dots: its
  /// mark is its old lastMessageDate, which the new message exceeds.
  func markingSeen(thread: RecentComposeThread, now: Date = Date()) -> ConversationReadLedger {
    var next = markingSeen(conversationID: thread.id, lastMessageDate: thread.lastMessageDate, now: now)
    for sibling in thread.consolidatedSiblings {
      next = next.markingSeen(conversationID: sibling.id, lastMessageDate: sibling.lastMessageDate, now: now)
    }
    return next
  }

  /// Marks a conversation seen up to `lastMessageDate` (or now, when the row
  /// has no date). Never regresses an existing newer mark.
  func markingSeen(conversationID: String, lastMessageDate: Date?, now: Date = Date()) -> ConversationReadLedger {
    let mark = lastMessageDate ?? now
    var next = self
    if let existing = next.seen[conversationID], existing >= mark { return self }
    next.seen[conversationID] = mark
    if next.seen.count > Self.maxEntries {
      let keep = next.seen.sorted { $0.value > $1.value }.prefix(Self.maxEntries)
      next.seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
    return next
  }
}
