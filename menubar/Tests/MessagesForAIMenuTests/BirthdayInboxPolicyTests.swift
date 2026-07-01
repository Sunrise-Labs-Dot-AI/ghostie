import XCTest
@testable import MessagesForAIMenu

final class BirthdayInboxPolicyTests: XCTestCase {
  func test_nonSuggestedContactBirthdayHasVisibleBucket() {
    let row = birthday(name: "Harper Example", suggested: false, pinned: false, muted: false)

    XCTAssertTrue(BirthdayInboxPolicy.approved([row]).isEmpty)
    XCTAssertTrue(BirthdayInboxPolicy.suggestions([row], snoozedIDs: []).isEmpty)
    XCTAssertEqual(BirthdayInboxPolicy.otherUpcoming([row]).map(\.name), ["Harper Example"])
  }

  func test_bucketsAreMutuallyExclusiveForPrimaryStates() {
    let pinned = birthday(name: "Pinned", suggested: false, pinned: true)
    let suggested = birthday(name: "Suggested", suggested: true)
    let other = birthday(name: "Other", suggested: false)
    let muted = birthday(name: "Muted", suggested: true, pinned: true, muted: true)
    let rows = [pinned, suggested, other, muted]

    XCTAssertEqual(BirthdayInboxPolicy.approved(rows).map(\.name), ["Pinned"])
    XCTAssertEqual(BirthdayInboxPolicy.suggestions(rows, snoozedIDs: []).map(\.name), ["Suggested"])
    XCTAssertEqual(BirthdayInboxPolicy.otherUpcoming(rows).map(\.name), ["Other"])
    XCTAssertEqual(BirthdayInboxPolicy.dismissed(rows).map(\.name), ["Muted"])
  }

  func test_snoozedSuggestionIsHiddenFromSuggestionsOnly() {
    let suggested = birthday(name: "Later", suggested: true)

    XCTAssertTrue(BirthdayInboxPolicy.suggestions([suggested], snoozedIDs: [suggested.id]).isEmpty)
    XCTAssertTrue(BirthdayInboxPolicy.otherUpcoming([suggested]).isEmpty)
  }

  func test_mutedContactBirthdayLeavesOtherUpcoming() {
    let dismissed = birthday(name: "Dismissed Contact", suggested: false, muted: true)

    XCTAssertTrue(BirthdayInboxPolicy.otherUpcoming([dismissed]).isEmpty)
    XCTAssertEqual(BirthdayInboxPolicy.dismissed([dismissed]).map(\.name), ["Dismissed Contact"])
  }

  private func birthday(
    name: String,
    suggested: Bool,
    pinned: Bool = false,
    muted: Bool = false
  ) -> UpcomingBirthday {
    UpcomingBirthday(
      name: name,
      birthday: "1984-06-19",
      nextOccurrence: "2026-06-19",
      daysUntil: 1,
      weekday: "Friday",
      ageTurning: 42,
      relationship: nil,
      notes: nil,
      bestHandle: "(206) 555-0182",
      handles: ["2065550182"],
      source: "contacts",
      pinned: pinned,
      muted: muted,
      outCount: 0,
      textRank: nil,
      callCount: 0,
      callRank: nil,
      wishedBefore: false,
      wishedYears: [],
      suggested: suggested,
      reasons: [],
      suggestedMessage: ""
    )
  }
}
