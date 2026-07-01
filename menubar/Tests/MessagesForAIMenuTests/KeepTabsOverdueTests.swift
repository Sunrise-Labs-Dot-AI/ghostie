import Foundation
import XCTest
@testable import MessagesForAIMenu

final class KeepTabsOverdueTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_780_000_000)

  // MARK: - lastContactedDays (call credit)

  func test_lastContactedTakesMoreRecentAxis() {
    XCTAssertEqual(KeepTabsOverdue.lastContactedDays(textDays: 10, callDays: 3), 3)
    XCTAssertEqual(KeepTabsOverdue.lastContactedDays(textDays: 3, callDays: 10), 3)
    XCTAssertEqual(KeepTabsOverdue.lastContactedDays(textDays: nil, callDays: 4), 4)
    XCTAssertEqual(KeepTabsOverdue.lastContactedDays(textDays: 8, callDays: nil), 8)
    XCTAssertNil(KeepTabsOverdue.lastContactedDays(textDays: nil, callDays: nil))
  }

  // MARK: - isOverdue

  func test_overdueWhenPastCadence() {
    XCTAssertTrue(KeepTabsOverdue.isOverdue(lastContactedDays: 10, targetFrequencyDays: 7, snoozedUntil: nil, now: now))
    XCTAssertFalse(KeepTabsOverdue.isOverdue(lastContactedDays: 5, targetFrequencyDays: 7, snoozedUntil: nil, now: now))
    XCTAssertFalse(KeepTabsOverdue.isOverdue(lastContactedDays: 7, targetFrequencyDays: 7, snoozedUntil: nil, now: now)) // exactly at cadence = not yet
  }

  func test_neverContactedIsOverdue() {
    XCTAssertTrue(KeepTabsOverdue.isOverdue(lastContactedDays: nil, targetFrequencyDays: 7, snoozedUntil: nil, now: now))
  }

  func test_snoozeSuppressesOverdue() {
    let future = now.addingTimeInterval(3 * 86_400)
    XCTAssertFalse(KeepTabsOverdue.isOverdue(lastContactedDays: 99, targetFrequencyDays: 7, snoozedUntil: future, now: now))
    // Once the snooze elapses, overdue returns.
    let past = now.addingTimeInterval(-86_400)
    XCTAssertTrue(KeepTabsOverdue.isOverdue(lastContactedDays: 99, targetFrequencyDays: 7, snoozedUntil: past, now: now))
  }

  func test_recentCallPreventsOverdueEvenWhenTextsAreStale() {
    // Texted 40 days ago, but called 2 days ago → not overdue at a weekly cadence.
    let last = KeepTabsOverdue.lastContactedDays(textDays: 40, callDays: 2)
    XCTAssertFalse(KeepTabsOverdue.isOverdue(lastContactedDays: last, targetFrequencyDays: 7, snoozedUntil: nil, now: now))
  }

  // MARK: - quietLabel

  func test_quietLabelFormatsWeeksDaysAndNone() {
    XCTAssertEqual(KeepTabsOverdue.quietLabel(lastContactedDays: nil), "no recent contact")
    XCTAssertEqual(KeepTabsOverdue.quietLabel(lastContactedDays: 3), "3 days")
    XCTAssertEqual(KeepTabsOverdue.quietLabel(lastContactedDays: 1), "1 day")
    XCTAssertEqual(KeepTabsOverdue.quietLabel(lastContactedDays: 21), "3 weeks")
    XCTAssertEqual(KeepTabsOverdue.quietLabel(lastContactedDays: 14), "2 weeks")
  }

  // MARK: - severity (green / yellow / red)

  func test_severityGreenWithinCadence() {
    XCTAssertEqual(KeepTabsOverdue.severity(lastContactedDays: 5, targetFrequencyDays: 7), .onTrack)
    XCTAssertEqual(KeepTabsOverdue.severity(lastContactedDays: 7, targetFrequencyDays: 7), .onTrack) // at cadence
  }

  func test_severityYellowUpToTwiceCadence() {
    XCTAssertEqual(KeepTabsOverdue.severity(lastContactedDays: 8, targetFrequencyDays: 7), .overdue)
    XCTAssertEqual(KeepTabsOverdue.severity(lastContactedDays: 14, targetFrequencyDays: 7), .overdue) // exactly 2×
  }

  func test_severityRedWellPastCadenceOrNever() {
    XCTAssertEqual(KeepTabsOverdue.severity(lastContactedDays: 15, targetFrequencyDays: 7), .veryOverdue) // >2×
    XCTAssertEqual(KeepTabsOverdue.severity(lastContactedDays: nil, targetFrequencyDays: 7), .veryOverdue) // never contacted
  }

  // MARK: - lastContactChannel (text vs call)

  func test_channelPicksMoreRecentAndTiesToText() {
    XCTAssertEqual(KeepTabsOverdue.lastContactChannel(textDays: 3, callDays: 10), .text(days: 3))
    XCTAssertEqual(KeepTabsOverdue.lastContactChannel(textDays: 10, callDays: 3), .call(days: 3))
    XCTAssertEqual(KeepTabsOverdue.lastContactChannel(textDays: 5, callDays: 5), .text(days: 5)) // tie → text
    XCTAssertEqual(KeepTabsOverdue.lastContactChannel(textDays: nil, callDays: 4), .call(days: 4))
    XCTAssertEqual(KeepTabsOverdue.lastContactChannel(textDays: 8, callDays: nil), .text(days: 8))
    XCTAssertEqual(KeepTabsOverdue.lastContactChannel(textDays: nil, callDays: nil), .none)
  }

  // MARK: - terseAgo

  func test_terseAgoFormats() {
    XCTAssertEqual(KeepTabsOverdue.terseAgo(0), "today")
    XCTAssertEqual(KeepTabsOverdue.terseAgo(1), "yesterday")
    XCTAssertEqual(KeepTabsOverdue.terseAgo(5), "5d ago")
    XCTAssertEqual(KeepTabsOverdue.terseAgo(21), "3w ago")
    XCTAssertEqual(KeepTabsOverdue.terseAgo(90), "3mo ago")
    XCTAssertEqual(KeepTabsOverdue.terseAgo(400), "1y ago")
  }
}
