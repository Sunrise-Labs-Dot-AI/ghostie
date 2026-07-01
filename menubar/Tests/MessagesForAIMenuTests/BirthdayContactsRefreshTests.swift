import XCTest
@testable import MessagesForAIMenu

/// BirthdayContactsRefreshPolicy: the staleness gate behind the Birthday
/// pane's open-time Contacts re-read (the CNContactStoreDidChange observer
/// covers live edits; this covers a missed notification).
final class BirthdayContactsRefreshTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_750_000_000)

  func testNotAuthorizedNeverRefreshes() {
    XCTAssertFalse(BirthdayContactsRefreshPolicy.shouldRefresh(
      authorized: false, lastExportAt: nil, now: now))
    XCTAssertFalse(BirthdayContactsRefreshPolicy.shouldRefresh(
      authorized: false, lastExportAt: now.addingTimeInterval(-86_400), now: now))
  }

  func testNoPriorExportRefreshes() {
    // Launch export skipped (e.g. authorized between launch and pane open) or
    // failed — the pane open is the recovery point.
    XCTAssertTrue(BirthdayContactsRefreshPolicy.shouldRefresh(
      authorized: true, lastExportAt: nil, now: now))
  }

  func testFreshExportSkips() {
    XCTAssertFalse(BirthdayContactsRefreshPolicy.shouldRefresh(
      authorized: true, lastExportAt: now.addingTimeInterval(-60), now: now))
  }

  func testJustUnderIntervalSkips() {
    XCTAssertFalse(BirthdayContactsRefreshPolicy.shouldRefresh(
      authorized: true,
      lastExportAt: now.addingTimeInterval(-BirthdayContactsRefreshPolicy.minInterval + 1),
      now: now))
  }

  func testStaleExportRefreshes() {
    XCTAssertTrue(BirthdayContactsRefreshPolicy.shouldRefresh(
      authorized: true,
      lastExportAt: now.addingTimeInterval(-BirthdayContactsRefreshPolicy.minInterval),
      now: now))
  }
}
