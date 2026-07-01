import XCTest
@testable import MessagesForAIMenu

/// Issues #83 (log symlink confused-deputy) and #84 (QR session frame cap).
final class SecurityHardeningTests: XCTestCase {

  // MARK: - #84: QR session inbound frame cap

  func testOversizedNoNewlineFrameIsRejected() {
    let cap = WhatsAppQRSession.maxFrameBytes
    // Over cap with no newline → reject.
    XCTAssertTrue(WhatsAppQRSession.shouldRejectOversizedFrame(bufferedBytes: cap + 1, hasNewline: false))
    // Under cap with no newline → keep buffering.
    XCTAssertFalse(WhatsAppQRSession.shouldRejectOversizedFrame(bufferedBytes: cap - 1, hasNewline: false))
    // Over cap but a complete frame is present → don't reject (we have a full frame).
    XCTAssertFalse(WhatsAppQRSession.shouldRejectOversizedFrame(bufferedBytes: cap + 1, hasNewline: true))
    // Mirrors the iMessage daemon's 1 MB per-connection cap.
    XCTAssertEqual(cap, 1_000_000)
  }

  // MARK: - #83: log writes refuse to follow symlinks

  func testSafeLogFileRefusesSymlink() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("safelog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // The "protected target" a malicious symlink would point at.
    let target = dir.appendingPathComponent("protected-target.txt")
    try Data("ORIGINAL".utf8).write(to: target)

    // Plant a symlink at the log path → SafeLogFile must refuse to open it, so the
    // target is never written through the symlink.
    let logPath = dir.appendingPathComponent("daemon.log")
    try FileManager.default.createSymbolicLink(at: logPath, withDestinationURL: target)

    let handle = SafeLogFile.openForAppending(at: logPath)
    XCTAssertNil(handle, "opening a symlinked log path must fail (O_NOFOLLOW)")

    let ok = SafeLogFile.append(Data("INJECTED".utf8), to: logPath)
    XCTAssertFalse(ok, "append via a symlink path must fail")

    // The protected target must be untouched.
    let after = try String(contentsOf: target, encoding: .utf8)
    XCTAssertEqual(after, "ORIGINAL", "the FDA app must not have written through the symlink")
  }

  func testSafeLogFileAppendsToRealFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("safelog-ok-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let logPath = dir.appendingPathComponent("daemon.log")

    XCTAssertTrue(SafeLogFile.append(Data("line1\n".utf8), to: logPath))
    XCTAssertTrue(SafeLogFile.append(Data("line2\n".utf8), to: logPath))
    let contents = try String(contentsOf: logPath, encoding: .utf8)
    XCTAssertEqual(contents, "line1\nline2\n")

    // The created file is 0600.
    let attrs = try FileManager.default.attributesOfItem(atPath: logPath.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
    XCTAssertEqual(perms, 0o600)
  }
}
