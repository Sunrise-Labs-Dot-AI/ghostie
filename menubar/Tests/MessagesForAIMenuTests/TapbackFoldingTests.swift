import Foundation
import XCTest
@testable import MessagesForAIMenu

// Folding semantics for chat.db tapbacks: associated rows (2xxx add / 3xxx
// remove) collapse to per-message reactions, keyed by the TARGET's bare guid
// even though associated_message_guid carries a "p:0/" or "bp:" part prefix.
final class TapbackFoldingTests: XCTestCase {
  private let target = "ABCD-1234-EF"

  private func event(
    type: Int,
    targetGUID: String? = nil,
    fromMe: Bool = false,
    handle: String? = "+14045550100",
    name: String? = "Allie",
    at seconds: TimeInterval = 0,
    emoji: String? = nil
  ) -> RecentComposeThread.TapbackEvent {
    RecentComposeThread.TapbackEvent(
      associatedMessageType: type,
      targetGUID: targetGUID ?? "p:0/\(target)",
      fromMe: fromMe,
      senderHandle: fromMe ? nil : handle,
      senderName: fromMe ? nil : name,
      sentAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
      emoji: emoji
    )
  }

  func test_targetGUIDStripsPartPrefixes() {
    XCTAssertEqual(RecentComposeThread.tapbackTargetGUID("p:0/\(target)"), target)
    XCTAssertEqual(RecentComposeThread.tapbackTargetGUID("p:12/\(target)"), target)
    XCTAssertEqual(RecentComposeThread.tapbackTargetGUID("bp:\(target)"), target)
    XCTAssertEqual(RecentComposeThread.tapbackTargetGUID(target), target)
    XCTAssertNil(RecentComposeThread.tapbackTargetGUID(""))
    XCTAssertNil(RecentComposeThread.tapbackTargetGUID("bp:"))
  }

  func test_addFoldsOntoBareTargetGUID() {
    let folded = RecentComposeThread.foldTapbacks([event(type: 2000)])
    XCTAssertEqual(folded[target]?.map(\.kind), [.loved])
    XCTAssertEqual(folded[target]?.first?.sender_name, "Allie")
    // The prefixed key must NOT survive — the transcript looks up by bare guid.
    XCTAssertNil(folded["p:0/\(target)"])
  }

  func test_removeCancelsEarlierAdd() {
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 2000, at: 0),
      event(type: 3000, at: 10)
    ])
    XCTAssertNil(folded[target])
  }

  func test_reAddAfterRemoveSurvives() {
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 2001, at: 0),
      event(type: 3001, at: 10),
      event(type: 2001, at: 20)
    ])
    XCTAssertEqual(folded[target]?.map(\.kind), [.liked])
  }

  func test_simultaneousAddAndRemoveResolvesToRemoved() {
    // A remove always refers to an already-delivered add, so a timestamp tie
    // goes to the remove regardless of scan order.
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 3000, at: 5),
      event(type: 2000, at: 5)
    ])
    XCTAssertNil(folded[target])
  }

  func test_multipleReactorsEachKeepTheirReaction() {
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 2000, handle: "+14045550100", name: "Allie", at: 0),
      event(type: 2000, handle: "+14045550200", name: "Bob", at: 1),
      event(type: 2003, fromMe: true, at: 2)
    ])
    XCTAssertEqual(folded[target]?.count, 3)
    XCTAssertEqual(
      Set(folded[target]?.map { $0.sender_name ?? "me" } ?? []),
      ["Allie", "Bob", "me"]
    )
  }

  func test_removeOnlyCancelsTheSameReactor() {
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 2000, handle: "+14045550100", name: "Allie", at: 0),
      event(type: 2000, handle: "+14045550200", name: "Bob", at: 1),
      event(type: 3000, handle: "+14045550100", name: "Allie", at: 2)
    ])
    XCTAssertEqual(folded[target]?.map(\.sender_name), ["Bob"])
  }

  func test_unknownAssociationTypesAreIgnored() {
    // 0 = plain message, 2 = edit, 1000 = sticker — none are tapbacks.
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 0),
      event(type: 2),
      event(type: 1000)
    ])
    XCTAssertTrue(folded.isEmpty)
  }

  func test_foldIsScanOrderIndependent() {
    // The loader scans chat.db newest-first; folding must not depend on it.
    let events = [
      event(type: 2000, at: 0),
      event(type: 3000, at: 10),
      event(type: 2001, at: 20)
    ]
    let forward = RecentComposeThread.foldTapbacks(events)
    let reversed = RecentComposeThread.foldTapbacks(events.reversed())
    XCTAssertEqual(forward[target]?.map(\.kind), [.liked])
    XCTAssertEqual(forward[target], reversed[target])
  }

  func test_customEmojiTapbackCarriesEmojiPayload() {
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 2006, emoji: "🔥")
    ])
    XCTAssertEqual(folded[target]?.first?.kind, .emoji)
    XCTAssertEqual(folded[target]?.first?.emoji, "🔥")
  }

  func test_customEmojiRemoveCancelsAdd() {
    let folded = RecentComposeThread.foldTapbacks([
      event(type: 2006, at: 0, emoji: "🔥"),
      event(type: 3006, at: 5, emoji: "🔥")
    ])
    XCTAssertNil(folded[target])
  }
}

// Capsule display policy: per-kind collapse and the VoiceOver phrasing.
final class ReactionBadgePolicyTests: XCTestCase {
  private func reaction(
    _ kind: MessageReaction.Kind,
    fromMe: Bool = false,
    name: String? = "Allie"
  ) -> MessageReaction {
    MessageReaction(
      kind: kind,
      from_me: fromMe,
      sender_handle: fromMe ? nil : "+14045550100",
      sender_name: fromMe ? nil : name,
      sent_at: "2026-06-01T12:00:00.000Z"
    )
  }

  func test_collapseGroupsByKindPreservingFirstSeenOrder() {
    let groups = ReactionBadgePolicy.collapsed([
      reaction(.loved, name: "Allie"),
      reaction(.liked, fromMe: true),
      reaction(.loved, name: "Bob")
    ])
    XCTAssertEqual(groups, [
      ReactionBadgePolicy.Group(kind: .loved, emoji: nil, count: 2),
      ReactionBadgePolicy.Group(kind: .liked, emoji: nil, count: 1)
    ])
  }

  func test_collapseKeepsDifferentCustomEmojiSeparate() {
    let fire = MessageReaction(
      kind: .emoji,
      from_me: false,
      sender_handle: "+14045550100",
      sender_name: "Allie",
      sent_at: "2026-06-01T12:00:00.000Z",
      emoji: "🔥"
    )
    let confetti = MessageReaction(
      kind: .emoji,
      from_me: true,
      sender_handle: nil,
      sender_name: nil,
      sent_at: "2026-06-01T12:00:01.000Z",
      emoji: "🎉"
    )
    XCTAssertEqual(ReactionBadgePolicy.collapsed([fire, confetti]), [
      ReactionBadgePolicy.Group(kind: .emoji, emoji: "🔥", count: 1),
      ReactionBadgePolicy.Group(kind: .emoji, emoji: "🎉", count: 1)
    ])
  }

  func test_displayGlyphUsesAppleEmojiStrings() {
    XCTAssertEqual(ReactionBadgePolicy.displayGlyph(kind: .loved), "❤️")
    XCTAssertEqual(ReactionBadgePolicy.displayGlyph(kind: .liked), "👍")
    XCTAssertEqual(ReactionBadgePolicy.displayGlyph(kind: .emoji, emoji: "🔥"), "🔥")
  }

  func test_accessibilityLabelNamesReactorsPerKind() {
    let label = ReactionBadgePolicy.accessibilityLabel([
      reaction(.loved, name: "Allie"),
      reaction(.loved, name: "Bob"),
      reaction(.liked, fromMe: true)
    ])
    XCTAssertEqual(label, "Loved by Allie and Bob, Liked by You")
  }

  func test_accessibilityLabelFallsBackToHandleThenSomeone() {
    let withHandle = MessageReaction(
      kind: .laughed,
      from_me: false,
      sender_handle: "+14045550100",
      sender_name: nil,
      sent_at: nil
    )
    XCTAssertEqual(
      ReactionBadgePolicy.accessibilityLabel([withHandle]),
      "Laughed at by +14045550100"
    )
    let anonymous = MessageReaction(
      kind: .emphasized,
      from_me: false,
      sender_handle: nil,
      sender_name: nil,
      sent_at: nil
    )
    XCTAssertEqual(
      ReactionBadgePolicy.accessibilityLabel([anonymous]),
      "Emphasized by someone"
    )
  }
}
