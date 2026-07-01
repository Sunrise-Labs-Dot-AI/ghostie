import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Validates the engine↔Swift JSON contract for the Phase 2 Import + Build seed
/// (the shapes `--import` and `--seed` emit), and the import error-message mapping
/// — all without spawning the binary.
@MainActor
final class BirthdayImportTests: XCTestCase {
  private func snakeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }

  func testBirthdayDateInputNormalizesValidDates() {
    XCTAssertEqual(BirthdayDateInput.normalized("6-5"), "06-05")
    XCTAssertEqual(BirthdayDateInput.normalized("1992-06-15"), "1992-06-15")
    XCTAssertEqual(BirthdayDateInput.normalized(" 02-29 "), "02-29")
  }

  func testBirthdayDateInputRejectsInvalidDates() {
    XCTAssertNil(BirthdayDateInput.normalized("not-a-date"))
    XCTAssertNil(BirthdayDateInput.normalized("13-01"))
    XCTAssertNil(BirthdayDateInput.normalized("06-31"))
    XCTAssertNil(BirthdayDateInput.normalized("2025-02-29"))
    XCTAssertNil(BirthdayDateInput.normalized("99-99"))
  }

  // The engine's `--import` stdout (note the extra `status` + `skipped_detail`
  // keys, which ImportResult ignores).
  func testDecodesImportResult() throws {
    let json = """
    {"status":"ok","created":3,"updated":1,"skipped":2,
     "skipped_detail":[{"index":4,"reason":"missing birthday for X"}]}
    """.data(using: .utf8)!
    let r = try snakeDecoder().decode(ImportResult.self, from: json)
    XCTAssertEqual(r.created, 3)
    XCTAssertEqual(r.updated, 1)
    XCTAssertEqual(r.skipped, 2)
  }

  // The engine's `--seed` stdout: snake_case fields map onto SeedContact, and a
  // null best_handle / saved_birthday / inferred_birthday decode as nil.
  func testDecodesSeedResult() throws {
    let json = """
    {"contacts_available":true,"signals_available":true,"count":2,
     "contacts":[
       {"name":"Jane","best_handle":"+15555550100","saved_birthday":"03-14",
        "inferred_birthday":null,"out_count":200,"call_count":5,
        "last_texted_days":3,"last_call_days":10,"reason":"200 texts; 5 calls"},
       {"name":"Sam","best_handle":null,"saved_birthday":null,
        "inferred_birthday":"06-02","out_count":40,"call_count":0,
        "last_texted_days":12,"last_call_days":null,"reason":"40 texts, last 12d ago"}
     ]}
    """.data(using: .utf8)!
    let r = try snakeDecoder().decode(SeedResult.self, from: json)
    XCTAssertTrue(r.signalsAvailable)
    XCTAssertEqual(r.contacts.count, 2)
    XCTAssertEqual(r.contacts[0].savedBirthday, "03-14")
    XCTAssertNil(r.contacts[0].inferredBirthday)
    XCTAssertNil(r.contacts[1].bestHandle)
    XCTAssertEqual(r.contacts[1].inferredBirthday, "06-02")
    XCTAssertNil(r.contacts[1].lastCallDays)
  }

  // The engine reports signals_available:false (no Full Disk Access) but still
  // exits 0 with an empty seed — decodes cleanly.
  func testDecodesSeedResultNoFDA() throws {
    let json = """
    {"contacts_available":false,"signals_available":false,"count":0,"contacts":[]}
    """.data(using: .utf8)!
    let r = try snakeDecoder().decode(SeedResult.self, from: json)
    XCTAssertFalse(r.signalsAvailable)
    XCTAssertTrue(r.contacts.isEmpty)
  }

  // Error mapping: the engine prefixes import failures with "--import:" — strip it,
  // take the first stderr line, and never return an empty string.
  func testImportErrorMessageStripsPrefixAndTakesFirstLine() {
    let msg = BirthdayGeneratorController.importErrorMessage(
      from: "--import: /tmp/x.json is not valid JSON (SyntaxError)\nmore noise\n", status: 2)
    XCTAssertEqual(msg, "/tmp/x.json is not valid JSON (SyntaxError)")
  }

  func testImportErrorMessageEmptyStderrFallsBackToCode() {
    let msg = BirthdayGeneratorController.importErrorMessage(from: "   \n", status: 2)
    XCTAssertEqual(msg, "The import failed (code 2).")
  }
}
