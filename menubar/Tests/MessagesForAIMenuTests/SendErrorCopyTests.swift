import XCTest
@testable import MessagesForAIMenu

final class SendErrorCopyTests: XCTestCase {
  func test_emptyOrNilError_genericCopy() {
    XCTAssertEqual(SendErrorCopy.user(for: nil, platform: .imessage), "Couldn't send. Please try again.")
    XCTAssertEqual(SendErrorCopy.user(for: "   ", platform: .imessage), "Couldn't send. Please try again.")
  }

  func test_daemonDown_pointsToSettings_withService() {
    let msg = SendErrorCopy.user(for: "connect ECONNREFUSED /Users/x/.messages-mcp/daemon.sock", platform: .imessage)
    XCTAssertTrue(msg.contains("isn't running"), msg)
    XCTAssertTrue(msg.contains("Settings"), msg)
    XCTAssertTrue(msg.contains("iMessage"), msg)
  }

  func test_permission_mentionsPermission() {
    let msg = SendErrorCopy.user(for: "permission denied reading chat.db", platform: .imessage)
    XCTAssertTrue(msg.lowercased().contains("permission"), msg)
  }

  func test_whatsappLoggedOut_reconnect() {
    let msg = SendErrorCopy.user(for: "session logged out", platform: .whatsapp)
    XCTAssertTrue(msg.contains("disconnected") || msg.contains("Reconnect"), msg)
  }

  func test_imessageDisconnected_neverShowsWhatsAppCopy() {
    // "disconnected" must not leak WhatsApp copy onto an iMessage error — it
    // falls through to the daemon-down branch instead.
    let msg = SendErrorCopy.user(for: "IPC connection disconnected", platform: .imessage)
    XCTAssertFalse(msg.contains("WhatsApp"), msg)
    XCTAssertTrue(msg.contains("isn't running"), msg)
    XCTAssertTrue(msg.contains("iMessage"), msg)
  }

  func test_timeout_isNetworkCopy_withService() {
    let msg = SendErrorCopy.user(for: "request timed out", platform: .whatsapp)
    XCTAssertTrue(msg.contains("Network"), msg)
    XCTAssertTrue(msg.contains("WhatsApp"), msg)
  }

  func test_unknownError_passesThroughRawDetail() {
    let raw = "weird gremlin error 0x42"
    XCTAssertEqual(SendErrorCopy.user(for: raw, platform: .imessage), raw)
  }
}
