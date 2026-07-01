import Foundation
import XCTest
@testable import MessagesForAIMenu

final class SendSchedulerTests: XCTestCase {
  // Use a fixed UTC calendar so minute-of-day math is deterministic in CI.
  private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  private func at(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
  }

  // MARK: QuietHours.contains

  func test_quietHours_overnightWindow() {
    let q = QuietHours(enabled: true, startMinute: 21 * 60, endMinute: 8 * 60)
    XCTAssertTrue(q.contains(minuteOfDay: 22 * 60))  // 10pm
    XCTAssertTrue(q.contains(minuteOfDay: 2 * 60))   // 2am
    XCTAssertTrue(q.contains(minuteOfDay: 21 * 60))  // 9pm inclusive
    XCTAssertFalse(q.contains(minuteOfDay: 8 * 60))  // 8am exclusive (window open)
    XCTAssertFalse(q.contains(minuteOfDay: 12 * 60)) // noon
  }

  func test_quietHours_disabled_neverContains() {
    let q = QuietHours(enabled: false, startMinute: 21 * 60, endMinute: 8 * 60)
    XCTAssertFalse(q.contains(minuteOfDay: 23 * 60))
  }

  // MARK: decide

  func test_decide_notDueYet_waits() {
    let d = SendScheduler.decide(now: at("2026-06-04T08:00:00Z"), scheduledAt: at("2026-06-04T09:00:00Z"),
                                 quiet: .default, override: false, cal: cal)
    XCTAssertEqual(d, .wait)
  }

  func test_decide_dueAndAllowedHours_sends() {
    let d = SendScheduler.decide(now: at("2026-06-04T09:00:00Z"), scheduledAt: at("2026-06-04T09:00:00Z"),
                                 quiet: .default, override: false, cal: cal)
    XCTAssertEqual(d, .send)
  }

  func test_decide_overdueButStillSameDay_inQuietHours_holds() {
    // The canonical case: scheduled 9am, Mac opened 10pm (quiet hours started 9pm).
    let d = SendScheduler.decide(now: at("2026-06-04T22:00:00Z"), scheduledAt: at("2026-06-04T09:00:00Z"),
                                 quiet: .default, override: false, cal: cal)
    XCTAssertEqual(d, .hold(reason: "quiet_hours"))
  }

  func test_decide_overrideSendsEvenInQuietHours() {
    let d = SendScheduler.decide(now: at("2026-06-04T22:00:00Z"), scheduledAt: at("2026-06-04T09:00:00Z"),
                                 quiet: .default, override: true, cal: cal)
    XCTAssertEqual(d, .send)
  }

  func test_decide_tooLate_holdsStale() {
    // > 36h overdue → a day-late birthday text is held, not auto-sent.
    let d = SendScheduler.decide(now: at("2026-06-06T09:00:00Z"), scheduledAt: at("2026-06-04T09:00:00Z"),
                                 quiet: .default, override: false, cal: cal)
    XCTAssertEqual(d, .hold(reason: "stale"))
  }

  func test_decide_overdueNextMorning_allowedHours_sends() {
    // Held overnight, now 8am next day, within stale cap, outside quiet → send.
    let d = SendScheduler.decide(now: at("2026-06-05T08:30:00Z"), scheduledAt: at("2026-06-04T09:00:00Z"),
                                 quiet: .default, override: false, cal: cal)
    XCTAssertEqual(d, .send)
  }

  // MARK: fireInstant

  func test_fireInstant_defaultTimeOutsideQuiet() {
    let day = at("2026-06-04T00:00:00Z")
    let fire = SendScheduler.fireInstant(onLocalDay: day, defaultMinute: 9 * 60, quiet: .default, cal: cal)
    XCTAssertEqual(SendScheduler.minuteOfDay(fire, cal), 9 * 60)
    XCTAssertEqual(cal.component(.day, from: fire), 4)
  }

  func test_fireInstant_defaultInsideQuiet_pushedToWindowOpenSameDay() {
    // Default 11pm is inside quiet hours → pushed to 8am the quiet window opens,
    // and crucially still ON the birthday (day 4), not the day after.
    let day = at("2026-06-04T00:00:00Z")
    let fire = SendScheduler.fireInstant(onLocalDay: day, defaultMinute: 23 * 60, quiet: .default, cal: cal)
    XCTAssertEqual(SendScheduler.minuteOfDay(fire, cal), 8 * 60)
    XCTAssertEqual(cal.component(.day, from: fire), 4)
  }
}
