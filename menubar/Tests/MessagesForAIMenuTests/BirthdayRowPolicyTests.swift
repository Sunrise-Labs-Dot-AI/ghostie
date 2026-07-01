import XCTest
@testable import MessagesForAIMenu

/// Pure policy behind the Birthday pane's hero rows and CTAs: the hero date
/// parse and the "Draft a scheduled text" fire-instant prefill.
final class BirthdayRowPolicyTests: XCTestCase {
  private let en = Locale(identifier: "en_US_POSIX")

  // MARK: hero date

  func test_heroParts_monthUppercased_dayUnpadded() {
    let parts = BirthdayHeroDate.parts(nextOccurrence: "2026-06-14", locale: en)
    XCTAssertEqual(parts?.month, "JUN")
    XCTAssertEqual(parts?.day, "14")
  }

  func test_heroParts_singleDigitDay() {
    let parts = BirthdayHeroDate.parts(nextOccurrence: "2026-12-01", locale: en)
    XCTAssertEqual(parts?.month, "DEC")
    XCTAssertEqual(parts?.day, "1")
  }

  func test_heroParts_nilOnGarbage() {
    XCTAssertNil(BirthdayHeroDate.parts(nextOccurrence: "not-a-date", locale: en))
    XCTAssertNil(BirthdayHeroDate.parts(nextOccurrence: "06-14", locale: en)) // engine always emits yyyy-MM-dd
    XCTAssertNil(BirthdayHeroDate.parts(nextOccurrence: "", locale: en))
  }

  func test_heroSpoken_fullMonth() {
    XCTAssertEqual(BirthdayHeroDate.spoken(nextOccurrence: "2026-06-14", locale: en), "June 14")
  }

  func test_heroSpoken_fallsBackToRawOnGarbage() {
    XCTAssertEqual(BirthdayHeroDate.spoken(nextOccurrence: "??", locale: en), "??")
  }

  // MARK: scheduled-compose prefill

  func test_scheduledFireDate_birthdayMorningAtDefaultMinute() {
    let quiet = QuietHours(enabled: true, startMinute: 21 * 60, endMinute: 8 * 60)
    let fire = BirthdayToolView.scheduledFireDate(
      nextOccurrence: "2026-06-14", defaultMinute: 9 * 60, quiet: quiet
    )
    let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire!)
    XCTAssertEqual(comps.year, 2026)
    XCTAssertEqual(comps.month, 6)
    XCTAssertEqual(comps.day, 14)
    XCTAssertEqual(comps.hour, 9)
    XCTAssertEqual(comps.minute, 0)
  }

  func test_scheduledFireDate_pushedOutOfQuietHours() {
    // Default minute inside the quiet window → fires when the window opens.
    let quiet = QuietHours(enabled: true, startMinute: 8 * 60, endMinute: 10 * 60)
    let fire = BirthdayToolView.scheduledFireDate(
      nextOccurrence: "2026-06-14", defaultMinute: 9 * 60, quiet: quiet
    )
    let comps = Calendar.current.dateComponents([.hour, .minute], from: fire!)
    XCTAssertEqual(comps.hour, 10)
    XCTAssertEqual(comps.minute, 0)
  }

  func test_scheduledFireDate_nilOnMalformedDay() {
    XCTAssertNil(BirthdayToolView.scheduledFireDate(
      nextOccurrence: "garbage", defaultMinute: 9 * 60, quiet: .default
    ))
  }

  // MARK: window filter

  func test_windowChoicesReplaceWeekWithAllYear() {
    XCTAssertEqual(
      BirthdayToolView.WindowChoice.allCases.map(\.label),
      ["Next 30 days", "Next 90 days", "All year"]
    )
    XCTAssertEqual(BirthdayToolView.WindowChoice.year.rawValue, 366)
  }

  func test_calendarModeDefaultsToAllYearFilter() {
    XCTAssertEqual(
      BirthdayWindowPolicy.choiceAfterModeChange(.calendar, current: .month),
      .year
    )
    XCTAssertEqual(
      BirthdayWindowPolicy.choiceAfterModeChange(.list, current: .quarter),
      .quarter
    )
  }
}
