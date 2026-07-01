import XCTest
@testable import MessagesForAIMenu

/// BirthdayDateParser: every accepted human format normalizes to the storage
/// format ("MM-DD" year-unknown / "YYYY-MM-DD"), ambiguous numeric dates
/// follow the documented US month-first rule, and garbage is rejected.
final class BirthdayDateParserTests: XCTestCase {
  // Pin currentYear so the two-digit-year pivot is deterministic.
  private func parse(_ s: String) -> BirthdayDateParser.Parsed? {
    BirthdayDateParser.parse(s, currentYear: 2026)
  }

  func testMonthNameDayFormats() {
    XCTAssertEqual(parse("June 14")?.normalized, "06-14")
    XCTAssertEqual(parse("jun 14")?.normalized, "06-14")
    XCTAssertEqual(parse("June 14th")?.normalized, "06-14")
    XCTAssertEqual(parse("Sept 9")?.normalized, "09-09")
    XCTAssertEqual(parse("june-14")?.normalized, "06-14")
  }

  func testDayMonthNameFormats() {
    XCTAssertEqual(parse("14 June")?.normalized, "06-14")
    XCTAssertEqual(parse("14 jun 1990")?.normalized, "1990-06-14")
  }

  func testMonthNameWithYear() {
    XCTAssertEqual(parse("Jun 14 1990")?.normalized, "1990-06-14")
    XCTAssertEqual(parse("June 14, 1990")?.normalized, "1990-06-14")
    XCTAssertEqual(parse("Jun. 14 1990")?.normalized, "1990-06-14")
  }

  func testSlashFormats() {
    XCTAssertEqual(parse("6/14")?.normalized, "06-14")
    XCTAssertEqual(parse("06/14")?.normalized, "06-14")
    XCTAssertEqual(parse("6/14/90")?.normalized, "1990-06-14")
    XCTAssertEqual(parse("6/14/1990")?.normalized, "1990-06-14")
  }

  func testIsoAndDashFormats() {
    XCTAssertEqual(parse("1990-06-14")?.normalized, "1990-06-14")
    XCTAssertEqual(parse("06-14")?.normalized, "06-14")
    XCTAssertEqual(parse("6-5")?.normalized, "06-05")
    XCTAssertEqual(parse("6-14-90")?.normalized, "1990-06-14")
  }

  func testTwoDigitYearPivot() {
    // ≤ the current 2-digit year → 2000s; above → 1900s (birthdays are never
    // in the future).
    XCTAssertEqual(parse("6/14/26")?.year, 2026)
    XCTAssertEqual(parse("6/14/27")?.year, 1927)
    XCTAssertEqual(parse("6/14/00")?.year, 2000)
    XCTAssertEqual(parse("6/14/90")?.year, 1990)
  }

  func testNumericIsStrictlyMonthFirst() {
    // Documented rule: numeric forms never flip to day-first, even when the
    // month-first reading is impossible — a likely typo gets a gentle error,
    // not a guess.
    XCTAssertNil(parse("14/6"))
    XCTAssertNil(parse("13-01"))
    // Ambiguous both ways stays month-first.
    XCTAssertEqual(parse("6/7")?.normalized, "06-07")
  }

  func testYearUnknownStaysYearless() {
    XCTAssertNil(parse("June 14")?.year)
    XCTAssertEqual(parse("6/14")?.normalized, "06-14")
    XCTAssertEqual(parse("02-29")?.normalized, "02-29") // leap birthdays are real
  }

  func testLeapDayNeedsLeapYearWhenYearGiven() {
    XCTAssertEqual(parse("2024-02-29")?.normalized, "2024-02-29")
    XCTAssertNil(parse("2025-02-29"))
    XCTAssertNil(parse("Feb 29 1990"))
    XCTAssertEqual(parse("Feb 29")?.normalized, "02-29")
  }

  func testRejectsGarbage() {
    XCTAssertNil(parse(""))
    XCTAssertNil(parse("   "))
    XCTAssertNil(parse("hello"))
    XCTAssertNil(parse("June"))
    XCTAssertNil(parse("June 99"))
    XCTAssertNil(parse("99-99"))
    XCTAssertNil(parse("06-31"))
    XCTAssertNil(parse("not-a-date"))
    XCTAssertNil(parse("1990-06-14 extra"))
    XCTAssertNil(parse("6/14/2090")) // future year
    XCTAssertNil(parse("6/14/1850")) // pre-1900
    XCTAssertNil(parse("6/14/990"))  // year must be 2 or 4 digits
    XCTAssertNil(parse("0/5"))
  }

  func testDisplayText() {
    XCTAssertEqual(parse("6/14/90")?.displayText, "June 14, 1990")
    XCTAssertEqual(parse("14 June")?.displayText, "June 14")
  }

  // The legacy strict entry point (controller guard + manual-add rows)
  // delegates to the parser, so call sites accept human formats for free.
  func testBirthdayDateInputDelegatesToParser() {
    XCTAssertEqual(BirthdayDateInput.normalized("June 14"), "06-14")
    XCTAssertEqual(BirthdayDateInput.normalized("1992-06-15"), "1992-06-15")
    XCTAssertNil(BirthdayDateInput.normalized("13-01"))
  }
}
