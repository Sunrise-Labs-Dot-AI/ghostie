import XCTest
@testable import MessagesForAIMenu

final class ConversationReadLedgerTests: XCTestCase {
  private let noon = Date(timeIntervalSince1970: 1_900_000_000)

  func testDBUnreadShowsWhenNeverSeenInApp() {
    let ledger = ConversationReadLedger()
    XCTAssertTrue(ledger.isUnread(conversationID: "c1", unreadCount: 3, lastMessageDate: noon))
  }

  func testDBReadNeverShowsDot() {
    let ledger = ConversationReadLedger()
    XCTAssertFalse(ledger.isUnread(conversationID: "c1", unreadCount: 0, lastMessageDate: noon))
  }

  func testOpeningThreadClearsDotEvenThoughDBStillSaysUnread() {
    let ledger = ConversationReadLedger()
      .markingSeen(conversationID: "c1", lastMessageDate: noon)
    XCTAssertFalse(ledger.isUnread(conversationID: "c1", unreadCount: 3, lastMessageDate: noon))
  }

  func testNewerMessageResurfacesDotAfterSeen() {
    let ledger = ConversationReadLedger()
      .markingSeen(conversationID: "c1", lastMessageDate: noon)
    let later = noon.addingTimeInterval(60)
    XCTAssertTrue(ledger.isUnread(conversationID: "c1", unreadCount: 1, lastMessageDate: later))
  }

  func testMarkSeenIsMonotonic() {
    let later = noon.addingTimeInterval(60)
    let ledger = ConversationReadLedger()
      .markingSeen(conversationID: "c1", lastMessageDate: later)
      .markingSeen(conversationID: "c1", lastMessageDate: noon) // stale mark must not regress
    XCTAssertFalse(ledger.isUnread(conversationID: "c1", unreadCount: 1, lastMessageDate: later))
  }

  func testNilLastMessageDateFallsBackToDBSignal() {
    let ledger = ConversationReadLedger()
      .markingSeen(conversationID: "c1", lastMessageDate: noon)
    XCTAssertTrue(ledger.isUnread(conversationID: "c1", unreadCount: 1, lastMessageDate: nil))
  }

  func testPruneCapsEntriesKeepingNewest() {
    var ledger = ConversationReadLedger()
    for index in 0..<(ConversationReadLedger.maxEntries + 50) {
      ledger = ledger.markingSeen(
        conversationID: "c\(index)",
        lastMessageDate: noon.addingTimeInterval(TimeInterval(index))
      )
    }
    XCTAssertEqual(ledger.seen.count, ConversationReadLedger.maxEntries)
    XCTAssertNotNil(ledger.seen["c\(ConversationReadLedger.maxEntries + 49)"]) // newest kept
    XCTAssertNil(ledger.seen["c0"]) // oldest dropped
  }

  func testRoundTripsThroughJSON() throws {
    let ledger = ConversationReadLedger().markingSeen(conversationID: "c1", lastMessageDate: noon)
    let decoded = try JSONDecoder().decode(
      ConversationReadLedger.self,
      from: JSONEncoder().encode(ledger)
    )
    XCTAssertEqual(decoded, ledger)
  }
}
