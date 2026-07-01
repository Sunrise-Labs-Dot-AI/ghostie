import XCTest
import SQLite3
@testable import MessagesForAIMenu

/// Builds a tiny chat.db-shaped fixture (handle + message tables) so the
/// post-send confirmer's query + bounce detection are tested for real, with no
/// dependency on the user's actual Messages database.
final class IMessageDeliveryConfirmerTests: XCTestCase {
  private var dbURL: URL!

  override func setUpWithError() throws {
    dbURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("confirmer-\(UUID().uuidString).db")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY, handle_id INTEGER, service TEXT,
        error INTEGER, is_delivered INTEGER, is_sent INTEGER,
        is_from_me INTEGER, date INTEGER
      );
      INSERT INTO handle (ROWID, id) VALUES (1, '+16505550159');
      """
    XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dbURL)
  }

  private func insertOutbound(service: String, error: Int, delivered: Int, at date: Date) {
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return XCTFail("open") }
    defer { sqlite3_close(db) }
    let nanos = IMessageDeliveryConfirmer.appleNanoseconds(date)
    let sql = """
      INSERT INTO message (handle_id, service, error, is_delivered, is_sent, is_from_me, date)
      VALUES (1, '\(service)', \(error), \(delivered), 1, 1, \(nanos));
      """
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
  }

  private func confirmer() -> IMessageDeliveryConfirmer {
    var c = IMessageDeliveryConfirmer()
    c.dbURL = dbURL
    return c
  }

  func testDetectsBounce() async {
    let since = Date(timeIntervalSinceReferenceDate: 1000)
    insertOutbound(service: "iMessage", error: 25, delivered: 0, at: since.addingTimeInterval(1))
    let outcome = await confirmer().confirm(handle: "+16505550159", since: since, attempts: 1, delaySeconds: 0)
    XCTAssertEqual(outcome?.error, 25)
    XCTAssertEqual(outcome?.service, "iMessage")
    XCTAssertTrue(IMessageDeliveryConfirmer.isBounce(XCTUnwrap_(outcome)))
  }

  func testHealthyRCSSendIsNotABounce() async {
    let since = Date(timeIntervalSinceReferenceDate: 2000)
    insertOutbound(service: "RCS", error: 0, delivered: 1, at: since.addingTimeInterval(1))
    let outcome = await confirmer().confirm(handle: "+16505550159", since: since, attempts: 1, delaySeconds: 0)
    XCTAssertEqual(outcome?.service, "RCS")
    XCTAssertFalse(IMessageDeliveryConfirmer.isBounce(XCTUnwrap_(outcome)))
  }

  func testIgnoresMessagesBeforeSendTime() async {
    let since = Date(timeIntervalSinceReferenceDate: 3000)
    insertOutbound(service: "iMessage", error: 99, delivered: 0, at: since.addingTimeInterval(-10))
    let outcome = await confirmer().confirm(handle: "+16505550159", since: since, attempts: 1, delaySeconds: 0)
    XCTAssertNil(outcome, "a message older than the send time must not be picked up")
  }

  /// Non-throwing unwrap helper for use inside async tests.
  private func XCTUnwrap_(_ outcome: IMessageDeliveryConfirmer.Outcome?) -> IMessageDeliveryConfirmer.Outcome {
    outcome ?? IMessageDeliveryConfirmer.Outcome(service: nil, error: -1, isDelivered: false, isSent: false)
  }
}
