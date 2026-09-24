import Foundation
import SQLite3

/// Post-send read of chat.db to recover what ACTUALLY happened to a 1:1 send.
/// Two facts the AppleScript layer can't give us: the real transport macOS
/// routed through (an auto-routed RCS send still returns "iMessage" from the
/// scripting bridge), and whether the message errored. Used to make a silently
/// bounced send visible — otherwise it's `ok == true` with no trace anywhere.
/// Read-only; the same chat.db the chat resolvers read.
struct IMessageDeliveryConfirmer {
  struct Outcome: Equatable {
    let service: String?
    let error: Int
    let isDelivered: Bool
    let isSent: Bool
  }

  var dbURL: URL = AppStoragePaths.homeDirectory
    .appendingPathComponent("Library")
    .appendingPathComponent("Messages")
    .appendingPathComponent("chat.db")

  /// chat.db `message.date` is nanoseconds since 2001-01-01 — exactly
  /// `Date.timeIntervalSinceReferenceDate` expressed in seconds.
  static func appleNanoseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
  }

  /// A non-zero `message.error` is the reliable bounce signal. `is_delivered == 0`
  /// alone is NOT (read receipts off, RCS/SMS receipt semantics), so we never
  /// flag on it — that would cry wolf on healthy sends.
  static func isBounce(_ outcome: Outcome) -> Bool { outcome.error != 0 }

  /// Poll for the most-recent outbound message to `handle` at/after `since`. The
  /// row lands a beat after osascript returns, so we retry briefly. Returns nil
  /// if no matching row appears (chat.db unreadable, handle never matched, etc.).
  func confirm(
    handle: String,
    since: Date,
    attempts: Int = 6,
    delaySeconds: TimeInterval = 0.5
  ) async -> Outcome? {
    let sinceNanos = Self.appleNanoseconds(since)
    let total = max(1, attempts)
    for attempt in 0..<total {
      if let outcome = latestOutbound(handle: handle, sinceNanos: sinceNanos) { return outcome }
      if attempt < total - 1 {
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
      }
    }
    return nil
  }

  /// Aggregate outcome of every outbound row one send run produced.
  struct Reconciliation: Equatable {
    /// Rows matched for this handle at/after the send start.
    let observed: Int
    /// Of those, rows carrying a non-zero `message.error` — the same signal
    /// `isBounce` uses, counted per part instead of only for the newest row.
    let failed: Int
  }

  /// Reconcile what a MULTIPART send actually did. `latestOutbound` answers
  /// "did the newest message bounce?", which is blind to a partial failure: a
  /// burst of attachment uploads can have the first rows land clean and later
  /// ones rejected, and the newest row alone can report either. Polls until
  /// `expected` rows are visible — a rejected transfer still writes its row,
  /// carrying `error != 0`, so the count converges on success and failure
  /// alike — then reports the tallies. Returns the last snapshot it managed to
  /// read if the rows never all appear, and nil if chat.db never became
  /// readable. Read-only.
  func reconcileOutbound(
    handle: String,
    since: Date,
    expected: Int,
    attempts: Int = 12,
    delaySeconds: TimeInterval = 1.0
  ) async -> Reconciliation? {
    let sinceNanos = Self.appleNanoseconds(since)
    let total = max(1, attempts)
    var latest: Reconciliation?
    for attempt in 0..<total {
      if let snapshot = outboundCounts(handle: handle, sinceNanos: sinceNanos) {
        latest = snapshot
        if snapshot.observed >= expected { return snapshot }
      }
      if attempt < total - 1 {
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
      }
    }
    return latest
  }

  /// Tally outbound rows to `handle` at/after `sinceNanos`. Bounded scan: the
  /// window starts at the send, and a draft carries at most a handful of parts,
  /// so the cap only guards against a pathological burst from other threads.
  func outboundCounts(handle: String, sinceNanos: Int64) -> Reconciliation? {
    guard let targetKey = ContactAvatarStore.canonicalKey(handle) else { return nil }
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return nil
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT h.id, m.error
      FROM message m
      JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.is_from_me = 1 AND m.date >= ?
      ORDER BY m.date DESC
      LIMIT 200
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, sinceNanos)

    var observed = 0
    var failed = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
      let rawHandle = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
      guard ContactAvatarStore.canonicalKey(rawHandle) == targetKey else { continue }
      observed += 1
      if sqlite3_column_int64(stmt, 1) != 0 { failed += 1 }
    }
    return Reconciliation(observed: observed, failed: failed)
  }

  /// Most-recent outbound message to `handle` whose date >= `sinceNanos`. Scans
  /// the newest 25 outbound rows and canonical-matches the handle (formats vary:
  /// "+1650…" vs "(650)…"), the same matching the resolvers use.
  func latestOutbound(handle: String, sinceNanos: Int64) -> Outcome? {
    guard let targetKey = ContactAvatarStore.canonicalKey(handle) else { return nil }
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return nil
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT h.id, m.service, m.error, m.is_delivered, m.is_sent
      FROM message m
      JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.is_from_me = 1 AND m.date >= ?
      ORDER BY m.date DESC
      LIMIT 25
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, sinceNanos)

    while sqlite3_step(stmt) == SQLITE_ROW {
      let rawHandle = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
      guard ContactAvatarStore.canonicalKey(rawHandle) == targetKey else { continue }
      let service = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
      return Outcome(
        service: service,
        error: Int(sqlite3_column_int64(stmt, 2)),
        isDelivered: sqlite3_column_int64(stmt, 3) != 0,
        isSent: sqlite3_column_int64(stmt, 4) != 0
      )
    }
    return nil
  }
}
