import XCTest
@testable import MessagesForAIMenu

/// Regression: WhatsApp message bodies are encrypted at rest (#81). The Don't
/// Ghost scan used to read the `body` column straight from SQLite and surface
/// the AES-256-GCM ciphertext as text, producing byte-garbage candidates (the
/// `whatsapp:-734457180` / `whatsapp:-545430735` threads in the real-data eval
/// showed bodies like "����OQϛE v\dTT�DM…").
///
/// The fix routes bodies through the daemon's decrypt-on-read RPC, and
/// `sanitizedWhatsAppBody` / `looksUndecodable` are the belt-and-suspenders
/// guard: if anything still reads as raw bytes, drop it instead of letting it
/// reach a Don't Ghost candidate. These tests pin that guard deterministically
/// (no daemon, no Keychain) — real text/emoji/non-Latin survives, ciphertext
/// garbage is skipped.
final class DontGhostWhatsAppDecodeTests: XCTestCase {

  // MARK: - Garbage is rejected

  func testCiphertextGarbageFromBugReportIsSkipped() {
    // The exact shape from the bug report: replacement chars + random bytes.
    let garbage = "����OQϛE v\\dTT�DM"
    XCTAssertTrue(DontGhostScanner.looksUndecodable(garbage))
    XCTAssertNil(DontGhostScanner.sanitizedWhatsAppBody(garbage))
  }

  func testRandomCiphertextBytesReadAsUtf8AreSkipped() {
    // Simulate reading an AES-GCM blob (nonce|tag|ciphertext) as UTF-8: high
    // bytes that don't form valid sequences become U+FFFD, low control bytes
    // leak through — a run dominated by "bad" scalars.
    let bytes: [UInt8] = [
      0x8a, 0x2f, 0xc1, 0xff, 0x90, 0x12, 0xe7, 0xbb,
      0x04, 0xd3, 0x77, 0x9c, 0xa0, 0x5e, 0xf1, 0x88,
      0x21, 0xcc, 0xb4, 0x6d, 0x9f, 0x80, 0xfe, 0x13,
    ]
    let misread = String(decoding: bytes, as: UTF8.self)
    XCTAssertTrue(DontGhostScanner.looksUndecodable(misread),
                  "ciphertext misread as UTF-8 should be flagged as undecodable")
    XCTAssertNil(DontGhostScanner.sanitizedWhatsAppBody(misread))
  }

  func testNilAndEmptyBodiesAreSkipped() {
    XCTAssertNil(DontGhostScanner.sanitizedWhatsAppBody(nil))
    XCTAssertNil(DontGhostScanner.sanitizedWhatsAppBody(""))
    XCTAssertNil(DontGhostScanner.sanitizedWhatsAppBody("   \n  "))
  }

  func testLoneAttachmentMarkerIsSkipped() {
    // Object-replacement char alone (an inline attachment, no caption) → nothing
    // worth surfacing as a reply-nudge candidate.
    XCTAssertNil(DontGhostScanner.sanitizedWhatsAppBody("\u{fffc}"))
  }

  // MARK: - Real messages survive

  func testPlainTextSurvives() {
    let body = "hey! are we still on for friday?"
    XCTAssertFalse(DontGhostScanner.looksUndecodable(body))
    XCTAssertEqual(DontGhostScanner.sanitizedWhatsAppBody(body), body)
  }

  func testEmojiOnlyMessageSurvives() {
    let body = "😂😂🎉👍🏽"
    XCTAssertFalse(DontGhostScanner.looksUndecodable(body))
    XCTAssertEqual(DontGhostScanner.sanitizedWhatsAppBody(body), body)
  }

  func testNonLatinTextSurvives() {
    // Valid multi-byte UTF-8 must NOT be mistaken for garbage.
    let body = "¿Cómo estás? 你好,最近怎么样 مرحبا"
    XCTAssertFalse(DontGhostScanner.looksUndecodable(body))
    XCTAssertEqual(DontGhostScanner.sanitizedWhatsAppBody(body), body)
  }

  func testAttachmentMarkerIsStrippedButCaptionKept() {
    // WhatsApp inline-attachment marker is removed; the caption text is kept.
    let body = "\u{fffc}Check out this photo"
    XCTAssertEqual(DontGhostScanner.sanitizedWhatsAppBody(body), "Check out this photo")
  }

  // MARK: - Daemon-unavailable classification

  func testDaemonUnavailableErrorsAreClassified() {
    XCTAssertTrue(WhatsAppRPCClient.RPCError.daemonNotInstalled.isDaemonUnavailable)
    XCTAssertTrue(WhatsAppRPCClient.RPCError.daemonNotRunning.isDaemonUnavailable)
    XCTAssertTrue(WhatsAppRPCClient.RPCError.peerAuthRejected.isDaemonUnavailable)
    XCTAssertTrue(WhatsAppRPCClient.RPCError.timeout.isDaemonUnavailable)
    XCTAssertFalse(WhatsAppRPCClient.RPCError.invalidResponse("x").isDaemonUnavailable)
    XCTAssertFalse(WhatsAppRPCClient.RPCError.rpcError(code: -32010, message: "x").isDaemonUnavailable)
  }
}
