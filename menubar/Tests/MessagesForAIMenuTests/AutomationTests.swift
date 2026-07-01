import XCTest
@testable import MessagesForAIMenu

final class AutomationTests: XCTestCase {
  func testCadenceAdvancesToFutureRun() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = date("2026-06-01T09:00:00Z")
    let now = date("2026-06-20T09:00:00Z")

    let next = AutomationCadence.weekly.nextFutureRun(after: start, now: now, calendar: calendar)

    XCTAssertEqual(next, date("2026-06-22T09:00:00Z"))
  }

  @MainActor
  func testStorePersistsAndRecordsGeneratedDraft() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("automation-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("automations.json")
    let store = AutomationStore(fileURL: url)

    let automation = try store.create(
      title: "Weekly check-in",
      platform: .imessage,
      toHandle: "215-555-0129",
      toHandleName: "James",
      body: "Hope your week is going well",
      cadence: .weekly,
      nextRunAt: date("2026-06-05T17:00:00Z")
    )
    try store.recordGenerated(
      id: automation.id,
      draftID: "draft-1",
      generatedAt: date("2026-06-05T17:01:00Z"),
      dueAt: date("2026-06-05T17:00:00Z"),
      nextRunAt: date("2026-06-12T17:00:00Z")
    )

    let reloaded = AutomationStore(fileURL: url)
    let saved = try XCTUnwrap(reloaded.automations.first)
    XCTAssertEqual(saved.lastGeneratedDraftID, "draft-1")
    XCTAssertEqual(saved.nextRunDate, date("2026-06-12T17:00:00Z"))
    XCTAssertEqual(saved.runHistory?.first?.draftID, "draft-1")
    XCTAssertEqual(saved.runHistory?.first?.dueDate, date("2026-06-05T17:00:00Z"))
    XCTAssertNil(saved.failureNote)
  }

  func testWeeklyCadenceSupportsMultipleWeekdaysAndInterval() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let anchor = date("2026-06-01T09:00:00Z") // Monday
    let monday = 2
    let wednesday = 4
    let friday = 6

    let nextSameWeek = AutomationCadence.weekly.nextFutureRun(
      after: anchor,
      now: date("2026-06-01T09:01:00Z"),
      calendar: calendar,
      interval: 2,
      weekdays: [monday, wednesday, friday],
      anchor: anchor
    )
    XCTAssertEqual(nextSameWeek, date("2026-06-03T09:00:00Z"))

    let nextIntervalWeek = AutomationCadence.weekly.nextFutureRun(
      after: date("2026-06-05T09:00:00Z"),
      now: date("2026-06-05T09:01:00Z"),
      calendar: calendar,
      interval: 2,
      weekdays: [monday, wednesday, friday],
      anchor: anchor
    )
    XCTAssertEqual(nextIntervalWeek, date("2026-06-15T09:00:00Z"))
  }

  @MainActor
  func testControllerMaterializesDueAutomationOnceAsApprovedScheduledDraft() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("automation-controller-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let automationURL = home
      .appendingPathComponent(".messages-mcp", isDirectory: true)
      .appendingPathComponent("automations.json")
    let automationStore = AutomationStore(fileURL: automationURL)
    let draftStore = DraftStore(homeOverride: home)
    let settings = SettingsStore(homeOverride: home)
    let controller = AutomationController(
      automationStore: automationStore,
      draftStore: draftStore,
      settings: settings
    )
    let dueAt = date("2026-06-05T17:00:00Z")
    let now = date("2026-06-05T17:01:00Z")

    try automationStore.create(
      title: "Weekly Ryan",
      platform: .imessage,
      toHandle: "+12155550121",
      toHandleName: "Ryan",
      body: "Hope your Friday is good",
      cadence: .weekly,
      nextRunAt: dueAt
    )

    controller.materializeDueAutomations(now: now, calendar: utcCalendar())
    controller.materializeDueAutomations(now: now, calendar: utcCalendar())

    XCTAssertEqual(draftStore.drafts.count, 1)
    let draft = try XCTUnwrap(draftStore.drafts.first)
    XCTAssertEqual(draft.to_handle, "+12155550121")
    XCTAssertEqual(draft.body, "Hope your Friday is good")
    XCTAssertEqual(draft.source, "Automation: Weekly Ryan")
    XCTAssertEqual(draft.scheduledDate, dueAt)
    XCTAssertEqual(draft.schedule_approved, true)
    let saved = try XCTUnwrap(automationStore.automations.first)
    XCTAssertEqual(saved.lastGeneratedDraftID, draft.id)
    XCTAssertEqual(saved.nextRunDate, date("2026-06-12T17:00:00Z"))
  }

  @MainActor
  func testControllerIgnoresPendingAutomationProposalUntilApproved() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("automation-pending-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let automationURL = home
      .appendingPathComponent(".messages-mcp", isDirectory: true)
      .appendingPathComponent("automations.json")
    let automationStore = AutomationStore(fileURL: automationURL)
    let draftStore = DraftStore(homeOverride: home)
    let settings = SettingsStore(homeOverride: home)
    let controller = AutomationController(
      automationStore: automationStore,
      draftStore: draftStore,
      settings: settings
    )
    let dueAt = date("2026-06-05T17:00:00Z")
    let now = date("2026-06-05T17:01:00Z")

    var proposal = try automationStore.create(
      title: "MCP proposal",
      platform: .imessage,
      toHandle: "+12155550121",
      toHandleName: "Ryan",
      body: "Hope your Friday is good",
      cadence: .weekly,
      nextRunAt: dueAt,
      isEnabled: false
    )
    proposal.approvalStatus = .pending
    proposal.proposedBy = "MCP"
    try automationStore.update(proposal)

    controller.materializeDueAutomations(now: now, calendar: utcCalendar())
    XCTAssertEqual(draftStore.drafts.count, 0)

    try automationStore.approve(id: proposal.id)
    controller.materializeDueAutomations(now: now, calendar: utcCalendar())

    XCTAssertEqual(draftStore.drafts.count, 1)
    XCTAssertEqual(draftStore.drafts.first?.schedule_approved, true)
  }

  private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }

  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}
