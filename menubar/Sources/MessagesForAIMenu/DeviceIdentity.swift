import Foundation

/// Stable per-machine identity for the cross-device relay (SUN-613).
///
/// Ghostie runs on more than one Mac, and every Mac runs TWO independent send
/// paths: this app's `DraftSender` and the TypeScript MCP `send_draft` /
/// `send_whatsapp_draft` tools. Across two Macs that is four executor processes
/// which today interlock only through the per-HOST advisory lock in
/// `~/.messages-mcp/locks/` — nothing stops the M1's MCP and the M4's menu bar
/// from both firing the same draft.
///
/// The relay fixes one machine as the executor for a given draft by stamping
/// `relay_executor` on the draft JSON. Every send path compares that value to
/// the id read from here and refuses when it doesn't match. For the comparison
/// to mean anything, the id must be:
///
///   - **stable** across launches and app updates (so a restarted Mac doesn't
///     forfeit drafts it owns), which is why it lives on disk rather than being
///     derived from something volatile;
///   - **identical for every process on the machine**, which is why it lives in
///     `~/.messages-mcp/` alongside `settings.json` — the TypeScript side reads
///     the exact same file (`mcps/shared/src/device-id.ts`) and this contract is
///     what makes the Swift and TS gates agree.
///
/// It is deliberately NOT a secret and NOT an authorization token: it says which
/// machine a draft belongs to, not that anyone approved it. Approval provenance
/// stays with `ApprovalAuthenticator` and its Keychain-held secret. A local
/// process that rewrites this file can make a Mac claim drafts it shouldn't, but
/// it still cannot mint an approval, and `DraftSender` re-reads the draft under
/// the send lock so the routing decision is made against on-disk state rather
/// than a stale snapshot.
enum DeviceIdentity {

  /// Canonical contract, mirrored byte-for-byte by `mcps/shared/src/device-id.ts`:
  ///   dir   : <home>/.messages-mcp
  ///   file  : device.json  (0600)
  ///   body  : {"schema_version":1,"device_id":"<uuid>","label":"<host>"}
  ///   id     : [A-Za-z0-9-]{8,64}
  static let schemaVersion = 1

  private static let cacheLock = NSLock()
  private static var cachedID: String?

  private static func deviceFileURL() -> URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp", isDirectory: true)
      .appendingPathComponent("device.json")
  }

  /// Shape-check an id read off disk. Anything outside this alphabet is treated
  /// as corrupt rather than coerced, because the value is compared against a
  /// field an MCP wrote and is surfaced in error copy.
  static func isValidDeviceID(_ value: String) -> Bool {
    guard value.count >= 8, value.count <= 64 else { return false }
    return value.allSatisfy { c in
      c.isASCII && (("a"..."z").contains(c) || ("A"..."Z").contains(c)
        || ("0"..."9").contains(c) || c == "-")
    }
  }

  /// This machine's device id, creating `device.json` on first use.
  ///
  /// Returns nil when the id can neither be read nor created. Callers MUST treat
  /// nil as "cannot prove I am the executor" and fail closed — see
  /// `Draft.executorRefusal(localDeviceID:)`.
  static func localDeviceID() -> String? {
    cacheLock.lock()
    if let cached = cachedID {
      cacheLock.unlock()
      return cached
    }
    cacheLock.unlock()

    let resolved = readExisting() ?? createIfAbsent()
    if let resolved {
      cacheLock.lock()
      cachedID = resolved
      cacheLock.unlock()
    }
    return resolved
  }

  private static func readExisting() -> String? {
    guard let data = FileManager.default.contents(atPath: deviceFileURL().path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = obj["device_id"] as? String,
          isValidDeviceID(id)
    else { return nil }
    return id
  }

  /// Create `device.json` with O_CREAT|O_EXCL so two processes racing on first
  /// launch cannot end up with two different ids for one machine: the loser's
  /// create fails and it re-reads the winner's file.
  private static func createIfAbsent() -> String? {
    let dir = AppStoragePaths.homeDirectory.appendingPathComponent(".messages-mcp", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let id = UUID().uuidString
    let document: [String: Any] = [
      "schema_version": schemaVersion,
      "device_id": id,
      "label": Host.current().localizedName ?? "Mac"
    ]
    guard let payload = try? JSONSerialization.data(
      withJSONObject: document,
      options: [.prettyPrinted, .sortedKeys]
    ) else { return nil }

    let path = deviceFileURL().path
    let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    if fd < 0 {
      // Lost the race (EEXIST) or genuinely can't write. Either way the only
      // correct answer is whatever is on disk now.
      return readExisting()
    }
    defer { close(fd) }
    let written = payload.withUnsafeBytes { buf -> Int in
      guard let base = buf.baseAddress else { return -1 }
      return write(fd, base, buf.count)
    }
    guard written == payload.count else {
      try? FileManager.default.removeItem(atPath: path)
      return nil
    }
    return id
  }

  /// Test seam: drop the memoized id so a case can point `MESSAGES_FOR_AI_HOME`
  /// at a fresh directory and observe creation.
  static func resetCacheForTesting() {
    cacheLock.lock()
    cachedID = nil
    cacheLock.unlock()
  }
}
