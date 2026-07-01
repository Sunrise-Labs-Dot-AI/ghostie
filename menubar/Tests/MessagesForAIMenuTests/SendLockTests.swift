import XCTest
@testable import MessagesForAIMenu

/// Issue #88 (Swift half): the cross-process send lock that interlocks with the
/// MCP's `send-lock.ts` so the menu bar and the MCP can't both fire the same draft.
final class SendLockTests: XCTestCase {
  private var tmpHome: URL!

  override func setUp() {
    super.setUp()
    tmpHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("mfa-sendlock-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
    setenv("MESSAGES_FOR_AI_HOME", tmpHome.path, 1)
  }

  override func tearDown() {
    unsetenv("MESSAGES_FOR_AI_HOME")
    try? FileManager.default.removeItem(at: tmpHome)
    super.tearDown()
  }

  func testHeldLockRefusesConcurrentAcquire() {
    guard var first = SendLock.acquire(for: "draft-abc") else {
      return XCTFail("first acquire should succeed")
    }
    // A second acquire of the same key while held must fail (refuse a concurrent send).
    XCTAssertNil(SendLock.acquire(for: "draft-abc"), "second acquire should be refused while held")
    // A different draft is independent.
    if var other = SendLock.acquire(for: "draft-xyz") { other.release() } else {
      XCTFail("a different draft id should not be serialized")
    }
    // After release, the key is acquirable again.
    first.release()
    guard var again = SendLock.acquire(for: "draft-abc") else {
      return XCTFail("acquire should succeed after release")
    }
    again.release()
  }

  func testStaleLockFromDeadHolderIsReclaimed() throws {
    // Forge a lockfile owned by a PID that cannot be alive, with an old timestamp.
    let dir = tmpHome.appendingPathComponent(".messages-mcp/locks", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lock = dir.appendingPathComponent("draft-stale.lock")
    let oldMs = Int(Date().timeIntervalSince1970 * 1000) - 120_000 // 2 min old
    try "{\"pid\":2147480000,\"acquired_at\":\(oldMs)}".write(to: lock, atomically: true, encoding: .utf8)

    // Acquire should reclaim the stale lock and succeed.
    guard var acquired = SendLock.acquire(for: "draft-stale") else {
      return XCTFail("a stale lock should be reclaimable")
    }
    acquired.release()
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path), "lock file removed after release")
  }

  func testFreshEmptyLockfileIsNotReclaimed() throws {
    // #88 (round 2): an empty lockfile with a RECENT mtime simulates a contender
    // mid create→write (O_CREAT|O_EXCL succeeded, metadata not yet written). It
    // must NOT be reclaimable on sight — otherwise a second acquirer could steal
    // the just-created lock and both sends fire.
    let dir = tmpHome.appendingPathComponent(".messages-mcp/locks", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lock = dir.appendingPathComponent("draft-fresh-empty.lock")
    FileManager.default.createFile(atPath: lock.path, contents: Data()) // empty, mtime = now

    XCTAssertNil(
      SendLock.acquire(for: "draft-fresh-empty"),
      "a freshly-created empty lock (recent mtime) must be respected, not reclaimed"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "the contender's lock must survive")
  }

  func testOldEmptyLockfileIsReclaimed() throws {
    // An empty lockfile whose mtime is well past the 60s TTL is genuinely stale
    // (a crashed acquirer that never wrote metadata) and SHOULD be reclaimable.
    let dir = tmpHome.appendingPathComponent(".messages-mcp/locks", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lock = dir.appendingPathComponent("draft-old-empty.lock")
    FileManager.default.createFile(atPath: lock.path, contents: Data())
    // Backdate the mtime well beyond the TTL.
    let old = Date().addingTimeInterval(-120)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lock.path)

    guard var acquired = SendLock.acquire(for: "draft-old-empty") else {
      return XCTFail("an mtime-old empty lock should be reclaimable")
    }
    acquired.release()
  }

  func testLockFilenameMatchesMcpSanitization() {
    // The TS side maps [^A-Za-z0-9._-] → '_'; a fresh acquire should create that file.
    guard var l = SendLock.acquire(for: "weird/id:with*chars") else { return XCTFail("acquire") }
    let expected = tmpHome.appendingPathComponent(".messages-mcp/locks/weird_id_with_chars.lock")
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path), "filename must match the MCP sanitizer")
    l.release()
  }

  func testPayloadFormatMatchesMcpContract() throws {
    // The Node MCP servers (send-lock.ts) read this exact shape:
    //   {"pid":<int>,"acquired_at":<epoch-ms>}
    // A drift here re-opens the duplicate-send hole, so pin it from the Swift side.
    guard var l = SendLock.acquire(for: "draft-fmt") else { return XCTFail("acquire") }
    defer { l.release() }
    let file = tmpHome.appendingPathComponent(".messages-mcp/locks/draft-fmt.lock")
    let data = try Data(contentsOf: file)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(obj.keys), ["pid", "acquired_at"], "lockfile must carry exactly pid + acquired_at")
    XCTAssertEqual((obj["pid"] as? NSNumber)?.int32Value, ProcessInfo.processInfo.processIdentifier)
    let acquiredAt = try XCTUnwrap((obj["acquired_at"] as? NSNumber)?.intValue)
    // acquired_at is epoch MILLISECONDS — sanity-bound it well above an epoch-seconds value.
    XCTAssertGreaterThan(acquiredAt, 1_000_000_000_000)
  }
}
