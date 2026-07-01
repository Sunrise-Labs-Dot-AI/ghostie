import XCTest
@testable import MessagesForAIMenu

/// Pure-logic tests only — no IDS.framework dependency, so these are
/// deterministic in CI (where there's no iMessage account). The live dynamic
/// call is exercised by hand on a real machine, never asserted here.
final class IDSCapabilityTests: XCTestCase {
  func testVerdictMapping() {
    XCTAssertEqual(IDSCapability.verdict(fromStatus: 1), .iMessage)
    XCTAssertEqual(IDSCapability.verdict(fromStatus: 2), .notIMessage)
    XCTAssertEqual(IDSCapability.verdict(fromStatus: 0), .unknown)
    XCTAssertEqual(IDSCapability.verdict(fromStatus: 3), .unknown)
    XCTAssertEqual(IDSCapability.verdict(fromStatus: -1), .unknown)
  }

  func testDestinationURI() {
    XCTAssertEqual(IDSCapability.destinationURI(for: "+16505550159"), "tel:+16505550159")
    XCTAssertEqual(IDSCapability.destinationURI(for: "jane@example.com"), "mailto:jane@example.com")
    XCTAssertEqual(IDSCapability.destinationURI(for: "  +14155550158 "), "tel:+14155550158")
    XCTAssertEqual(IDSCapability.destinationURI(for: "tel:+1555"), "tel:+1555")
    XCTAssertEqual(IDSCapability.destinationURI(for: "mailto:x@y.com"), "mailto:x@y.com")
  }

  func testVerdictsKeyedByOriginalHandle() {
    let raw = ["tel:+16505550159": 2, "tel:+14155550158": 1]
    let verdicts = IDSCapability.verdicts(from: raw, handles: ["+16505550159", "+14155550158", "+19999999999"])
    XCTAssertEqual(verdicts["+16505550159"], .notIMessage)
    XCTAssertEqual(verdicts["+14155550158"], .iMessage)
    XCTAssertEqual(verdicts["+19999999999"], .unknown) // absent from result → unknown
  }

  func testStatusUsesOverrideSeam() async {
    var cap = IDSCapability()
    cap.rawLookupOverride = { _ in ["tel:+16505550159": 2] }
    let verdicts = await cap.status(for: ["+16505550159"])
    XCTAssertEqual(verdicts["+16505550159"], .notIMessage)
  }

  func testStatusFallsBackToUnknownWhenLookupFails() async {
    var cap = IDSCapability()
    cap.rawLookupOverride = { _ in nil } // simulate framework-absent / total failure
    let verdicts = await cap.status(for: ["+1555", "a@b.com"])
    XCTAssertEqual(verdicts["+1555"], .unknown)
    XCTAssertEqual(verdicts["a@b.com"], .unknown)
  }

  func testStatusEmptyHandles() async {
    let verdicts = await IDSCapability().status(for: [])
    XCTAssertTrue(verdicts.isEmpty)
  }
}
