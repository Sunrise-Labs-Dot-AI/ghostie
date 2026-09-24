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

  // MARK: - Multipart reconciliation (issue #9)

  /// The exact shape of the send that regressed: an 8-photo draft where the
  /// first 3 transfers landed and the throttle rejected the remaining 5 with
  /// `error = 25`. The newest row alone (what `latestOutbound` sees) is an
  /// errored one here, but the old code never even asked — it reported a clean
  /// 8-for-8 send. Reconciliation has to count every part.
  func testReconcileCountsPartialAttachmentFailure() async {
    let since = Date(timeIntervalSinceReferenceDate: 10_000)
    for i in 0..<3 {
      insertOutbound(service: "iMessage", error: 0, delivered: 1, at: since.addingTimeInterval(Double(i) + 1))
    }
    for i in 3..<8 {
      insertOutbound(service: "iMessage", error: 25, delivered: 0, at: since.addingTimeInterval(Double(i) + 1))
    }
    let result = await confirmer().reconcileOutbound(
      handle: "+16505550159", since: since, expected: 8, attempts: 1, delaySeconds: 0
    )
    XCTAssertEqual(result?.observed, 8)
    XCTAssertEqual(result?.failed, 5, "must count every errored part, not just the newest row")
  }

  /// A fully delivered send must stay silent — no false "didn't send" warning.
  func testReconcileReportsNoFailureWhenAllPartsLand() async {
    let since = Date(timeIntervalSinceReferenceDate: 20_000)
    for i in 0..<9 {
      insertOutbound(service: "iMessage", error: 0, delivered: 1, at: since.addingTimeInterval(Double(i) + 1))
    }
    let result = await confirmer().reconcileOutbound(
      handle: "+16505550159", since: since, expected: 9, attempts: 1, delaySeconds: 0
    )
    XCTAssertEqual(result?.observed, 9)
    XCTAssertEqual(result?.failed, 0)
  }

  /// Rows from earlier conversation must not be counted. This is the guard on
  /// the `sent_at`-vs-send-start bug: if the window were stamped after the loop
  /// instead of before it, every real attachment row would fall outside it.
  func testReconcileIgnoresRowsBeforeTheSendWindow() async {
    let since = Date(timeIntervalSinceReferenceDate: 30_000)
    insertOutbound(service: "iMessage", error: 25, delivered: 0, at: since.addingTimeInterval(-30))
    insertOutbound(service: "iMessage", error: 0, delivered: 1, at: since.addingTimeInterval(1))
    let result = await confirmer().reconcileOutbound(
      handle: "+16505550159", since: since, expected: 1, attempts: 1, delaySeconds: 0
    )
    XCTAssertEqual(result?.observed, 1)
    XCTAssertEqual(result?.failed, 0, "a pre-send bounce belongs to an earlier message")
  }

  /// Rows land a beat after osascript returns, so a first look can come up
  /// short. Polling must keep the last snapshot rather than returning nil.
  func testReconcileReturnsLastSnapshotWhenRowsNeverAllArrive() async {
    let since = Date(timeIntervalSinceReferenceDate: 40_000)
    insertOutbound(service: "iMessage", error: 25, delivered: 0, at: since.addingTimeInterval(1))
    let result = await confirmer().reconcileOutbound(
      handle: "+16505550159", since: since, expected: 4, attempts: 2, delaySeconds: 0
    )
    XCTAssertEqual(result?.observed, 1, "partial visibility still beats reporting nothing")
    XCTAssertEqual(result?.failed, 1)
  }

  /// Another conversation's failures must never be attributed to this draft.
  func testReconcileIgnoresOtherHandles() async {
    let since = Date(timeIntervalSinceReferenceDate: 50_000)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    let nanos = IMessageDeliveryConfirmer.appleNanoseconds(since.addingTimeInterval(1))
    XCTAssertEqual(sqlite3_exec(db, """
      INSERT INTO handle (ROWID, id) VALUES (2, '+16505550188');
      INSERT INTO message (handle_id, service, error, is_delivered, is_sent, is_from_me, date)
      VALUES (2, 'iMessage', 25, 0, 0, 1, \(nanos));
      """, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    insertOutbound(service: "iMessage", error: 0, delivered: 1, at: since.addingTimeInterval(2))

    let result = await confirmer().reconcileOutbound(
      handle: "+16505550159", since: since, expected: 1, attempts: 1, delaySeconds: 0
    )
    XCTAssertEqual(result?.observed, 1)
    XCTAssertEqual(result?.failed, 0, "a different thread's throttle must not flag this draft")
  }
}
