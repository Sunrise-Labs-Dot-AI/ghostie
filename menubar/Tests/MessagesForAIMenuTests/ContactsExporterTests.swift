import Foundation
import XCTest
import Contacts
@testable import MessagesForAIMenu

/// Covers the pure producing-side helpers of the Contacts → birthdays-cache.json
/// bridge. canonHandle MUST agree with the unified TS `canonHandle`
/// (mcps/imessage-drafts/src/chatdb/canon.ts + canon.test.ts) — these vectors
/// are the Swift half of that cross-language contract (ROOT_CAUSE #1).
final class ContactsExporterTests: XCTestCase {

  // Same vectors as canon.test.ts. If you change the canon rule on one side,
  // change both in the same PR and update both vector sets.
  func test_canonHandle_matchesTSVectors() {
    let cases: [(String, String)] = [
      ("+1 (404) 555-0147", "4045550147"),
      ("+14045550147", "4045550147"),
      ("14045550147", "4045550147"),
      ("4045550147", "4045550147"),
      ("(404) 555-0147", "4045550147"),
      ("911", "911"),
      ("12345", "12345"),
      ("Avery@Example.COM", "avery@example.com"),
      ("jose+tag@Example.com", "jose+tag@example.com"),
      ("plain@domain.io", "plain@domain.io"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(ContactsExporter.canonHandle(input), expected, "canonHandle(\(input))")
    }
  }

  func test_birthdayString_withYear() {
    let c = CNMutableContact()
    c.birthday = DateComponents(year: 1990, month: 6, day: 4)
    XCTAssertEqual(ContactsExporter.birthdayString(for: c), "1990-06-04")
  }

  func test_birthdayString_withoutYear_padsMonthDay() {
    let c = CNMutableContact()
    c.birthday = DateComponents(month: 7, day: 2)
    XCTAssertEqual(ContactsExporter.birthdayString(for: c), "07-02")
  }

  func test_birthdayString_leapDay() {
    let c = CNMutableContact()
    c.birthday = DateComponents(month: 2, day: 29)
    XCTAssertEqual(ContactsExporter.birthdayString(for: c), "02-29")
  }

  func test_birthdayString_nilWhenNoBirthday() {
    XCTAssertNil(ContactsExporter.birthdayString(for: CNMutableContact()))
  }

  func test_birthdayString_nilWhenPartial_yearOnly() {
    let c = CNMutableContact()
    c.birthday = DateComponents(year: 1990) // no month/day → not usable
    XCTAssertNil(ContactsExporter.birthdayString(for: c))
  }

  // MARK: birthday sources beyond the dedicated Gregorian field
  // (Contacts-fetch audit: year-less cards, "Birthday"-labeled custom dates,
  // and non-Gregorian birthdays must all land in the birthdays sidecar — the
  // engine merges that sidecar into the list with source: "contacts";
  // mcps/birthday-generator/src/store.test.ts covers that attribution.)

  func test_birthdayString_datesLabeledBirthday_fallback_monthDay() {
    let c = CNMutableContact()
    let comps = NSDateComponents()
    comps.month = 3
    comps.day = 14
    c.dates = [CNLabeledValue(label: "Birthday", value: comps)]
    XCTAssertEqual(ContactsExporter.birthdayString(for: c), "03-14")
  }

  func test_birthdayString_datesLabeledBirthday_fallback_withYear() {
    let c = CNMutableContact()
    let comps = NSDateComponents()
    comps.year = 1988
    comps.month = 3
    comps.day = 14
    c.dates = [CNLabeledValue(label: "birthday", value: comps)] // case-insensitive
    XCTAssertEqual(ContactsExporter.birthdayString(for: c), "1988-03-14")
  }

  func test_birthdayString_dedicatedFieldWinsOverDatesEntry() {
    let c = CNMutableContact()
    c.birthday = DateComponents(month: 6, day: 4)
    let comps = NSDateComponents()
    comps.month = 12
    comps.day = 25
    c.dates = [CNLabeledValue(label: "Birthday", value: comps)]
    XCTAssertEqual(ContactsExporter.birthdayString(for: c), "06-04")
  }

  func test_birthdayString_anniversaryDateEntry_ignored() {
    let c = CNMutableContact()
    let comps = NSDateComponents()
    comps.month = 9
    comps.day = 9
    c.dates = [CNLabeledValue(label: CNLabelDateAnniversary, value: comps)]
    XCTAssertNil(ContactsExporter.birthdayString(for: c))
  }

  func test_isBirthdayLabel_vectors() {
    XCTAssertTrue(ContactsExporter.isBirthdayLabel("Birthday"))
    XCTAssertTrue(ContactsExporter.isBirthdayLabel("birthday"))
    XCTAssertTrue(ContactsExporter.isBirthdayLabel("_$!<Birthday>!$_")) // wrapped standard form
    XCTAssertFalse(ContactsExporter.isBirthdayLabel(CNLabelDateAnniversary))
    XCTAssertFalse(ContactsExporter.isBirthdayLabel("anniversary"))
    XCTAssertFalse(ContactsExporter.isBirthdayLabel(nil))
  }

  func test_birthdayString_nonGregorian_withYear_convertsToGregorian() {
    // 15 Nisan 5750 (Hebrew) — compute the expected Gregorian date with the
    // same calendar APIs the exporter uses, then assert the exporter agrees.
    let c = CNMutableContact()
    var hebrew = DateComponents()
    hebrew.calendar = Calendar(identifier: .hebrew)
    hebrew.year = 5750
    hebrew.month = 8 // Nisan in the Hebrew calendar's numbering
    hebrew.day = 15
    c.nonGregorianBirthday = hebrew

    let tz = TimeZone(secondsFromGMT: 0)!
    var sourceCal = Calendar(identifier: .hebrew)
    sourceCal.timeZone = tz
    var anchored = hebrew
    anchored.calendar = nil
    let date = sourceCal.date(from: anchored)!
    var greg = Calendar(identifier: .gregorian)
    greg.timeZone = tz
    let g = greg.dateComponents([.year, .month, .day], from: date)
    let expected = String(format: "%04d-%02d-%02d", g.year!, g.month!, g.day!)

    XCTAssertEqual(ContactsExporter.birthdayString(for: c), expected)
  }

  func test_birthdayString_nonGregorian_yearless_skipped() {
    // A year-less non-Gregorian month/day has no stable Gregorian equivalent —
    // it must be skipped, not mis-converted.
    let c = CNMutableContact()
    var hebrew = DateComponents()
    hebrew.calendar = Calendar(identifier: .hebrew)
    hebrew.month = 8
    hebrew.day = 15
    c.nonGregorianBirthday = hebrew
    XCTAssertNil(ContactsExporter.birthdayString(for: c))
  }

  func test_birthdayString_gregorianFieldWins_overNonGregorian() {
    let c = CNMutableContact()
    c.birthday = DateComponents(month: 7, day: 2)
    var hebrew = DateComponents()
    hebrew.calendar = Calendar(identifier: .hebrew)
    hebrew.year = 5750
    hebrew.month = 8
    hebrew.day = 15
    c.nonGregorianBirthday = hebrew
    XCTAssertEqual(ContactsExporter.birthdayString(for: c), "07-02")
  }

  func test_bestHandle_prefersMobileOverOtherPhones() {
    let c = CNMutableContact()
    c.phoneNumbers = [
      CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "+1 (212) 000-0000")),
      CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+14045550147")),
    ]
    XCTAssertEqual(ContactsExporter.bestHandle(for: c), "+14045550147")
  }

  func test_bestHandle_fallsBackToEmailWhenNoPhone() {
    let c = CNMutableContact()
    c.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "mom@example.com" as NSString)]
    XCTAssertEqual(ContactsExporter.bestHandle(for: c), "mom@example.com")
  }

  func test_bestHandle_nilWhenNoContactMethods() {
    XCTAssertNil(ContactsExporter.bestHandle(for: CNMutableContact()))
  }

  func test_bestHandle_isDispatchable_notCanonicalized() {
    // Regression: best_handle must stay the original E.164/email (routable),
    // NOT the last-10-digits canonical form (review S/plan invariant).
    let c = CNMutableContact()
    c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+14045550147"))]
    XCTAssertEqual(ContactsExporter.bestHandle(for: c), "+14045550147")
    XCTAssertNotEqual(ContactsExporter.bestHandle(for: c), "4045550147")
  }

  func test_contactMatchCarriesSavedBirthday() {
    let c = CNMutableContact()
    c.givenName = "Harper"
    c.familyName = "Example"
    c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "(206) 555-0182"))]
    c.birthday = DateComponents(year: 1984, month: 6, day: 19)

    let match = ContactsExporter.contactMatch(for: c)

    XCTAssertEqual(match?.name, "Harper Example")
    XCTAssertEqual(match?.bestHandle, "(206) 555-0182")
    XCTAssertEqual(match?.handles, ["2065550182"])
    XCTAssertEqual(match?.savedBirthday, "1984-06-19")
  }
}
