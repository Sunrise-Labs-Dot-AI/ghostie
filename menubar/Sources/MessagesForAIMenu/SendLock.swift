import Foundation

// Cross-process advisory send lock — the Swift half of issue #88.
//
// The iMessage duplicate-send guard (read sent_at==null → check cap → fire
// AppleScript → mark sent) is a non-atomic read-modify-write shared between the
// Node MCP server and this menu-bar app (hold-to-fire). Two concurrent sends of
// the SAME draft can both fire → duplicate delivery. The MCP closes the MCP-vs-
// MCP race with an O_CREAT|O_EXCL lockfile (`mcps/imessage-drafts/src/storage/
// send-lock.ts`). This file mirrors that EXACT path + format so the menu bar and
// the MCP interlock across processes.
//
// Canonical contract (must match send-lock.ts):
//   dir   : <home>/.messages-mcp/locks   (0700 created by recursive mkdir)
//   file  : <draftId-sanitized>.lock     ([^A-Za-z0-9._-] → '_')
//   body  : {"pid":<int>,"acquired_at":<epoch-ms>}
//   stale : readable → holder PID dead OR acquired_at age > 60s; unreadable/
//           corrupt/empty → only when file mtime age > 60s (NOT on sight, to
//           avoid stealing a just-created lock mid create→write)
//   open  : O_CREAT|O_EXCL|O_WRONLY, 0600
//   free  : unlink only if the file is still ours (pid + acquired_at match)
//
// Held window: covers the AppleScript fire AND the on-disk `sent_at` persist for
// iMessage. DraftSender writes `sent_at` to the draft JSON BEFORE releasing this
// lock (issue #88, round 2), so the MCP — which reads `sent_at` from that file
// inside its own lock — can never acquire the lock and see `sent_at == null` in
// the window between our send and the caller's later (idempotent) markSent. The
// earlier residual window is now closed for iMessage; WhatsApp is handled by the
// daemon writing `sent_at` itself under the WhatsApp MCP's lock.
struct SendLock {
  private let path: String
  private let pid: Int32
  private let acquiredAtMs: Int
  private var released = false

  private static let lockTTLms = 60_000

  private static func lockDir() -> URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp", isDirectory: true)
      .appendingPathComponent("locks", isDirectory: true)
  }

  private static func lockPath(for key: String) -> String {
    // Match the TS sanitizer exactly: ASCII [A-Za-z0-9._-], everything else → '_',
    // so the two processes compute byte-identical lock filenames.
    let safe = String(key.map { c -> Character in
      let isAllowed = c.isASCII && (("a"..."z").contains(c) || ("A"..."Z").contains(c)
        || ("0"..."9").contains(c) || c == "." || c == "_" || c == "-")
      return isAllowed ? c : "_"
    })
    return lockDir().appendingPathComponent(safe + ".lock").path
  }

  private static func pidAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM // exists but not signalable by us
  }

  private static func readMeta(_ path: String) -> (pid: Int32, acquiredAt: Int)? {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pid = (obj["pid"] as? NSNumber)?.int32Value,
          let acquired = (obj["acquired_at"] as? NSNumber)?.intValue
    else { return nil }
    return (pid, acquired)
  }

  /// File mtime age in ms, or nil if the file's mtime can't be read.
  private static func fileAgeMs(_ path: String) -> Int? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let modified = attrs[.modificationDate] as? Date else { return nil }
    return Int(Date().timeIntervalSince(modified) * 1000)
  }

  /// Reclaim a stale lock. Returns true if the existing lock was removed (retry
  /// the O_EXCL create), false if it's genuinely held.
  ///
  /// #88 (round 2): an unreadable/corrupt/EMPTY lockfile is NOT treated as
  /// immediately stale. There is a window between another acquirer's
  /// O_CREAT|O_EXCL open and its metadata write where the file exists but is
  /// empty; reclaiming it on sight would let a contender steal a just-created
  /// lock and re-open the duplicate-send hole. So an unreadable lock is reclaimed
  /// ONLY when its file mtime age exceeds the TTL — long past any create→write
  /// window. A readable lock is reclaimed when its holder PID is dead or its
  /// acquired_at is older than the TTL. (Mirrors send-lock.ts.)
  private static func tryReclaim(_ path: String) -> Bool {
    let stale: Bool
    if let meta = readMeta(path) {
      let nowMs = Int(Date().timeIntervalSince1970 * 1000)
      stale = !pidAlive(meta.pid) || (nowMs - meta.acquiredAt) > lockTTLms
    } else {
      // Unreadable / corrupt / empty: respect it unless it's mtime-old (or its
      // mtime is unreadable, in which case fall back to reclaiming — it's already
      // unreadable, so treating it as stale doesn't lose information).
      let ageMs = fileAgeMs(path)
      stale = (ageMs ?? (lockTTLms + 1)) > lockTTLms
    }
    guard stale else { return false }
    return (try? FileManager.default.removeItem(atPath: path)) != nil
  }

  /// Non-blocking acquire. nil ⇒ a live holder has it (a concurrent send is in
  /// flight for this draft).
  static func acquire(for key: String) -> SendLock? {
    try? FileManager.default.createDirectory(at: lockDir(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = lockPath(for: key)
    let pid = Int32(ProcessInfo.processInfo.processIdentifier)

    for attempt in 0..<2 {
      let acquiredAtMs = Int(Date().timeIntervalSince1970 * 1000)
      let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
      if fd == -1 {
        if errno == EEXIST {
          if attempt == 0 && tryReclaim(path) { continue }
          return nil
        }
        return nil // unexpected error: fail closed (refuse rather than risk a double send)
      }
      let body = "{\"pid\":\(pid),\"acquired_at\":\(acquiredAtMs)}"
      _ = body.withCString { write(fd, $0, strlen($0)) }
      close(fd)
      return SendLock(path: path, pid: pid, acquiredAtMs: acquiredAtMs)
    }
    return nil
  }

  /// Release if the lock is still ours.
  mutating func release() {
    guard !released else { return }
    released = true
    if let cur = SendLock.readMeta(path), cur.pid == pid, cur.acquiredAt == acquiredAtMs {
      try? FileManager.default.removeItem(atPath: path)
    } else if SendLock.readMeta(path) == nil, FileManager.default.fileExists(atPath: path) {
      // unreadable but present — best-effort remove
      try? FileManager.default.removeItem(atPath: path)
    }
  }
}
