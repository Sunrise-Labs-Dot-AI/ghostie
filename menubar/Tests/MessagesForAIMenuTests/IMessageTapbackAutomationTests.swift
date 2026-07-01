import XCTest
@testable import MessagesForAIMenu

final class IMessageTapbackAutomationTests: XCTestCase {
  func testStandardEmojiMapToMessagesAccessibilityActions() {
    XCTAssertEqual(IMessageTapbackAutomation.actionName(forEmoji: "❤️"), "Heart")
    XCTAssertEqual(IMessageTapbackAutomation.actionName(forEmoji: "👍"), "Thumbs up")
    XCTAssertEqual(IMessageTapbackAutomation.actionName(forEmoji: "👎"), "Thumbs down")
    XCTAssertEqual(IMessageTapbackAutomation.actionName(forEmoji: "😂"), "Ha ha!")
    XCTAssertEqual(IMessageTapbackAutomation.actionName(forEmoji: "‼️"), "Exclamation mark")
    XCTAssertEqual(IMessageTapbackAutomation.actionName(forEmoji: "❓"), "Question mark")
  }

  func testCustomEmojiPassesThroughWhenNonEmpty() {
    XCTAssertEqual(IMessageTapbackAutomation.actionName(forEmoji: "🥷"), "🥷")
    XCTAssertNil(IMessageTapbackAutomation.actionName(forEmoji: "  "))
  }

  func testMatchesMessagesCustomActionNames() {
    let actions = [
      "AXPress",
      "Name:Heart\nTarget:0x0\nSelector:(null)",
      "Name:Question mark\nTarget:0x0\nSelector:(null)"
    ]

    XCTAssertEqual(
      IMessageTapbackAutomation.actionName(actions, matching: "Heart"),
      "Name:Heart\nTarget:0x0\nSelector:(null)"
    )
    XCTAssertEqual(
      IMessageTapbackAutomation.actionName(actions, matching: "Question mark"),
      "Name:Question mark\nTarget:0x0\nSelector:(null)"
    )
    XCTAssertNil(IMessageTapbackAutomation.actionName(actions, matching: "Thumbs up"))
  }

  func testConversationURLUsesMessagesScheme() throws {
    let phone = try XCTUnwrap(IMessageTapbackAutomation.conversationURL(for: "+12155550172"))
    XCTAssertEqual(phone.scheme, "imessage")
    XCTAssertTrue(phone.absoluteString.contains("+12155550172"))

    let email = try XCTUnwrap(IMessageTapbackAutomation.conversationURL(for: "james@example.com"))
    XCTAssertEqual(email.scheme, "imessage")
    XCTAssertTrue(email.absoluteString.contains("james@example.com"))
  }

  // MARK: - Conversation verification (wrong-thread protection)

  func testWindowTitleMatchesContactDisplayName() {
    XCTAssertTrue(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "Jane Doe",
      displayName: "Jane Doe",
      handle: "+12155550172"
    ))
    // Case + diacritic tolerant: AX titles can fold differently than chat.db.
    XCTAssertTrue(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "  RENÉE doe ",
      displayName: "Renee Doe",
      handle: "+12155550172"
    ))
  }

  func testWindowTitleMatchesFormattedPhoneHandle() {
    XCTAssertTrue(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "+1 (215) 555-0172",
      displayName: nil,
      handle: "+12155550172"
    ))
    // Country-code tolerance: digit suffix match, 7+ digits required.
    XCTAssertTrue(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "(215) 555-0172",
      displayName: nil,
      handle: "+12155550172"
    ))
  }

  func testWindowTitleMatchesEmailHandleCaseInsensitively() {
    XCTAssertTrue(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "James@Example.com",
      displayName: nil,
      handle: "james@example.com"
    ))
  }

  func testWindowTitleForAnotherConversationDoesNotMatch() {
    // The wrong-thread scenario from the review: a different open thread
    // must never be verified as the target conversation.
    XCTAssertFalse(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "Mom",
      displayName: "Jane Doe",
      handle: "+12155550172"
    ))
    XCTAssertFalse(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "+1 (415) 555-0100",
      displayName: "Jane Doe",
      handle: "+12155550172"
    ))
  }

  func testUnverifiableTitlesFailClosed() {
    XCTAssertFalse(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "",
      displayName: "Jane Doe",
      handle: "+12155550172"
    ))
    XCTAssertFalse(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "Messages",
      displayName: "Jane Doe",
      handle: "+12155550172"
    ))
    // Short digit fragments can never positively identify a conversation.
    XCTAssertFalse(IMessageTapbackAutomation.conversationTitleMatchesTarget(
      title: "0172",
      displayName: nil,
      handle: "+12155550172"
    ))
  }
}
