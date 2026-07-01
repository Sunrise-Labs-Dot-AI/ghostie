import XCTest
@testable import MessagesForAIMenu

final class BirthdayNudgeTests: XCTestCase {
  func test_pickPrefersTodayThenPinnedThenTextFrequency() {
    let tomorrow = birthday(name: "Tomorrow Tina", daysUntil: 1, outCount: 900)
    let todayQuiet = birthday(name: "Quiet Quinn", daysUntil: 0, outCount: 5)
    let todayBestie = birthday(name: "Bestie Bea", daysUntil: 0, outCount: 500)
    let picked = BirthdayNudgePolicy.pick([tomorrow, todayQuiet, todayBestie], dismissedID: nil)
    XCTAssertEqual(picked?.name, "Bestie Bea")
  }

  func test_pickSkipsMutedWishedDismissedAndFarOff() {
    let muted = birthday(name: "Muted Max", daysUntil: 0, muted: true)
    let wished = birthday(name: "Wished Wen", daysUntil: 0, wishedYears: [2026])
    let farOff = birthday(name: "Later Lou", daysUntil: 3)
    let dismissed = birthday(name: "Dismissed Dee", daysUntil: 0)
    let dismissedID = BirthdayNudgePolicy.occurrenceID(dismissed)
    XCTAssertNil(BirthdayNudgePolicy.pick([muted, wished, farOff, dismissed], dismissedID: dismissedID))
  }

  func test_dismissalIsPerOccurrence() {
    let person = birthday(name: "Annual Anna", daysUntil: 0)
    let lastYearID = "\(person.id)|2025-06-10"
    XCTAssertNotNil(BirthdayNudgePolicy.pick([person], dismissedID: lastYearID))
  }

  func test_picksStacksEveryQualifyingBirthdayTodayFirst() {
    let tomorrow = birthday(name: "Tomorrow Tina", daysUntil: 1, outCount: 900)
    let todayQuiet = birthday(name: "Quiet Quinn", daysUntil: 0, outCount: 5)
    let todayBestie = birthday(name: "Bestie Bea", daysUntil: 0, outCount: 500)
    let farOff = birthday(name: "Later Lou", daysUntil: 3)
    let picks = BirthdayNudgePolicy.picks([tomorrow, todayQuiet, todayBestie, farOff])
    XCTAssertEqual(picks.map(\.name), ["Bestie Bea", "Quiet Quinn", "Tomorrow Tina"])
  }

  func test_picksDropsResolvedOccurrence() {
    let messaged = birthday(name: "Messaged Mara", daysUntil: 0)
    let pending = birthday(name: "Pending Pat", daysUntil: 0)
    let resolvedID = BirthdayNudgePolicy.occurrenceID(messaged)
    let picks = BirthdayNudgePolicy.picks([messaged, pending], resolvedIDs: [resolvedID])
    XCTAssertEqual(picks.map(\.name), ["Pending Pat"])
  }

  func test_headlinePossessive() {
    XCTAssertEqual(
      BirthdayNudgePolicy.headline(birthday(name: "James", daysUntil: 0)),
      "James' birthday is today"
    )
    XCTAssertEqual(
      BirthdayNudgePolicy.headline(birthday(name: "Maya", daysUntil: 1)),
      "Maya's birthday is tomorrow"
    )
  }

  private func birthday(
    name: String,
    daysUntil: Int,
    muted: Bool = false,
    pinned: Bool = false,
    outCount: Int = 10,
    wishedYears: [Int] = []
  ) -> UpcomingBirthday {
    UpcomingBirthday(
      name: name,
      birthday: "06-10",
      nextOccurrence: "2026-06-10",
      daysUntil: daysUntil,
      weekday: "Wednesday",
      ageTurning: nil,
      relationship: nil,
      notes: nil,
      bestHandle: "+14045550100",
      handles: ["+14045550100"],
      source: "manual",
      pinned: pinned,
      muted: muted,
      outCount: outCount,
      textRank: nil,
      callCount: 0,
      callRank: nil,
      wishedBefore: false,
      wishedYears: wishedYears,
      suggested: false,
      reasons: [],
      suggestedMessage: ""
    )
  }
}
