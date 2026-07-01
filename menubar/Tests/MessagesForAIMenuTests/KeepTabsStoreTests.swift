import Foundation
import XCTest
@testable import MessagesForAIMenu

@MainActor
final class KeepTabsStoreTests: XCTestCase {
  private var dir: URL!
  private var fileURL: URL!

  override func setUp() {
    super.setUp()
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("keep-tabs-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    fileURL = dir.appendingPathComponent("keep-tabs.json")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
    super.tearDown()
  }

  func test_addRemoveRoundTripsThroughDisk() throws {
    let store = KeepTabsStore(fileURL: fileURL)
    try store.add(name: "Alice", handle: "+1 (404) 555-0001", frequencyDays: 7)
    XCTAssertEqual(store.watchlist.count, 1)
    XCTAssertEqual(store.watchlist.first?.displayName, "Alice")
    XCTAssertEqual(store.watchlist.first?.targetFrequencyDays, 7)

    // Reload from disk into a fresh store.
    let reloaded = KeepTabsStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.watchlist.count, 1)
    let canon = ContactAvatarStore.canonicalKey("+14045550001")!
    XCTAssertTrue(reloaded.isWatched(canon: canon))

    reloaded.remove(canon: canon)
    XCTAssertTrue(reloaded.isEmpty)
    let afterRemove = KeepTabsStore(fileURL: fileURL)
    XCTAssertTrue(afterRemove.isEmpty)
  }

  func test_canonKeyingDedupesFormattingVariants() throws {
    let store = KeepTabsStore(fileURL: fileURL)
    try store.add(name: "Alice", handle: "+14045550001", frequencyDays: 7)
    // A differently-formatted form of the same number is the same person.
    XCTAssertThrowsError(try store.add(name: "Alice (work)", handle: "(404) 555-0001", frequencyDays: 14)) { error in
      XCTAssertEqual(error as? KeepTabsStoreError, .duplicateContact)
    }
    XCTAssertEqual(store.watchlist.count, 1)
  }

  func test_setFrequencyClampsAndPersists() throws {
    let store = KeepTabsStore(fileURL: fileURL)
    let entry = try store.add(name: "Bob", handle: "bob@example.com", frequencyDays: 14)
    store.setFrequency(canon: entry.canonicalKey, days: 9999) // beyond max
    XCTAssertEqual(store.watchlist.first?.targetFrequencyDays, KeepTabsStore.maxFrequencyDays)
    store.setFrequency(canon: entry.canonicalKey, days: 0) // below min
    XCTAssertEqual(store.watchlist.first?.targetFrequencyDays, KeepTabsStore.minFrequencyDays)
  }

  func test_snoozeRoundTrips() throws {
    let store = KeepTabsStore(fileURL: fileURL)
    let entry = try store.add(name: "Carol", handle: "+14045550003", frequencyDays: 7)
    let until = Date().addingTimeInterval(7 * 86_400)
    store.snooze(canon: entry.canonicalKey, until: until)
    XCTAssertNotNil(store.watchlist.first?.snoozedUntil)
    let reloaded = KeepTabsStore(fileURL: fileURL)
    XCTAssertNotNil(reloaded.watchlist.first?.snoozedUntil)
    reloaded.clearSnooze(canon: entry.canonicalKey)
    XCTAssertNil(reloaded.watchlist.first?.snoozedUntil)
  }

  func test_dismissIsPerpetualAndPersists() throws {
    let store = KeepTabsStore(fileURL: fileURL)
    let canon = ContactAvatarStore.canonicalKey("+14045559999")!
    XCTAssertFalse(store.isDismissed(canon: canon))
    store.dismiss(canon: canon)
    XCTAssertTrue(store.isDismissed(canon: canon))
    XCTAssertTrue(store.dismissedCanons.contains(canon))
    // Survives a reload (honored in perpetuity).
    let reloaded = KeepTabsStore(fileURL: fileURL)
    XCTAssertTrue(reloaded.isDismissed(canon: canon))
  }

  func test_frequencyNearestMapsMedianToPreset() {
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 2), .fewDays)
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 5), .fewDays)
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 9), .weekly)
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 18), .biweekly)
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 26), .monthly)
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 75), .quarterly)
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 150), .semiannual)
    XCTAssertEqual(KeepTabsFrequency.nearest(toDays: 365), .yearly)
  }

  func test_autoPrioritizeDefaultsTrueAndPersists() throws {
    let store = KeepTabsStore(fileURL: fileURL)
    XCTAssertTrue(store.autoPrioritize)
    store.setAutoPrioritize(false)
    let reloaded = KeepTabsStore(fileURL: fileURL)
    XCTAssertFalse(reloaded.autoPrioritize)
  }

  func test_corruptFileIsQuarantinedNotClobbered() throws {
    try "{ this is not json".data(using: .utf8)!.write(to: fileURL)
    let store = KeepTabsStore(fileURL: fileURL)
    XCTAssertTrue(store.isEmpty)
    XCTAssertNotNil(store.lastError)
    // A quarantine copy was made and a fresh start is safe to write.
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasPrefix("keep-tabs.json.corrupt-") }
    XCTAssertEqual(quarantined.count, 1)
    try store.add(name: "Dana", handle: "+14045550004", frequencyDays: 30)
    XCTAssertEqual(KeepTabsStore(fileURL: fileURL).watchlist.count, 1)
  }

  func test_missingHandleAndInvalidHandleRejected() {
    let store = KeepTabsStore(fileURL: fileURL)
    XCTAssertThrowsError(try store.add(name: "X", handle: "   ", frequencyDays: 7)) { error in
      XCTAssertEqual(error as? KeepTabsStoreError, .missingHandle)
    }
    XCTAssertThrowsError(try store.add(name: "X", handle: "not-a-handle", frequencyDays: 7)) { error in
      XCTAssertEqual(error as? KeepTabsStoreError, .invalidHandle)
    }
  }
}
