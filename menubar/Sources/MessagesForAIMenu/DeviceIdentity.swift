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

  /// Read the id through a verified descriptor rather than a path.
  ///
  /// `device.json` decides which drafts this machine may send, so a local
  /// process that swaps it for a symlink to attacker-controlled JSON could make
  /// this Mac answer to another Mac's id and duplicate-send its drafts.
  /// Path-following reads walk that symlink happily. So: O_NOFOLLOW, then fstat
  /// the descriptor we actually opened and require a regular file owned by us
  /// with no group/other access. The parent gets the same treatment, mirroring
  /// the existing symlink guard in the iMessage drafts storage.
  /// (Second-lane review, finding 7.)
  private static func readExisting() -> String? {
    let dir = AppStoragePaths.homeDirectory.appendingPathComponent(".messages-mcp", isDirectory: true)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path),
       (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
      return nil
    }

    let fd = open(deviceFileURL().path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0 else { return nil }
    guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    guard st.st_uid == getuid() else { return nil }
    guard (st.st_mode & 0o077) == 0 else { return nil }

    guard let handle = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
          let obj = try? JSONSerialization.jsonObject(with: handle) as? [String: Any],
          (obj["schema_version"] as? NSNumber)?.intValue == schemaVersion,
          let id = obj["device_id"] as? String,
          isValidDeviceID(id)
    else { return nil }
    return id
  }

  /// Create `device.json` by write-then-publish, not create-then-fill.
  ///
  /// `O_CREAT|O_EXCL` alone stops two successful creates, but it publishes the
  /// final path BEFORE the contents exist: a racing reader sees an empty file,
  /// and a crash mid-write leaves a permanently empty `device.json` that every
  /// future create refuses to replace, wedging stamped sends forever. So build a
  /// complete, fsynced private file first, then publish with `link(2)`, which is
  /// atomic and fails if the name exists. The loser unlinks its temp and reads
  /// the winner's file. (Second-lane review, finding 8.)
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

    let finalPath = deviceFileURL().path
    let tempPath = dir.appendingPathComponent(".device.json.\(getpid()).\(UUID().uuidString).tmp").path

    let fd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { return nil }

    var ok = true
    payload.withUnsafeBytes { buf in
      guard var base = buf.baseAddress else { ok = false; return }
      var remaining = buf.count
      while remaining > 0 {
        // Short writes are legal; ignoring the count can publish a truncated
        // identity that parses as valid-looking garbage.
        let n = write(fd, base, remaining)
        if n <= 0 { ok = false; return }
        remaining -= n
        base = base.advanced(by: n)
      }
    }
    if ok { ok = (fsync(fd) == 0) }
    close(fd)
    guard ok else {
      unlink(tempPath)
      return nil
    }

    // link(2) is atomic and fails with EEXIST if another process already
    // published, which is exactly the race we want to lose safely.
    guard link(tempPath, finalPath) == 0 else {
      unlink(tempPath)
      return readExisting()
    }
    unlink(tempPath)
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
