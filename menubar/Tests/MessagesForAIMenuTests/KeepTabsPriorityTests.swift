import Foundation
import XCTest
@testable import MessagesForAIMenu

final class KeepTabsPriorityTests: XCTestCase {
  private func entry(level: Int, reason: String?, setBy: String) -> ThreadPriorityEntry {
    ThreadPriorityEntry(level: level, reason: reason, setAt: "2026-06-10T00:00:00.000Z", setBy: setBy)
  }

  // MARK: - decide() non-clobber matrix

  func test_setsWhenNoExistingEntry() {
    let d = KeepTabsPriority.decide(wantPrioritized: true, existing: nil, desiredReason: "quiet 3 weeks", desiredLevel: .elevated)
    XCTAssertEqual(d, .set(reason: "quiet 3 weeks"))
  }

  func test_refreshesOwnEntryOnlyWhenChanged() {
    let same = entry(level: 3, reason: "quiet 3 weeks", setBy: ThreadPrioritySource.keepTabs)
    XCTAssertEqual(
      KeepTabsPriority.decide(wantPrioritized: true, existing: same, desiredReason: "quiet 3 weeks", desiredLevel: .elevated),
      .leave // identical → no rewrite (idempotent, prevents file churn)
    )
    let stale = entry(level: 3, reason: "quiet 2 weeks", setBy: ThreadPrioritySource.keepTabs)
    XCTAssertEqual(
      KeepTabsPriority.decide(wantPrioritized: true, existing: stale, desiredReason: "quiet 3 weeks", desiredLevel: .elevated),
      .set(reason: "quiet 3 weeks")
    )
  }

  func test_neverClobbersAgentOrUserPriority() {
    let agent = entry(level: 1, reason: "boss waiting", setBy: ThreadPrioritySource.agent)
    XCTAssertEqual(
      KeepTabsPriority.decide(wantPrioritized: true, existing: agent, desiredReason: "quiet 3 weeks", desiredLevel: .elevated),
      .leave
    )
    let user = entry(level: 2, reason: nil, setBy: ThreadPrioritySource.user)
    XCTAssertEqual(
      KeepTabsPriority.decide(wantPrioritized: true, existing: user, desiredReason: "quiet 3 weeks", desiredLevel: .elevated),
      .leave
    )
  }

  func test_clearsOnlyOwnEntryWhenNoLongerWanted() {
    let mine = entry(level: 3, reason: "quiet 3 weeks", setBy: ThreadPrioritySource.keepTabs)
    XCTAssertEqual(
      KeepTabsPriority.decide(wantPrioritized: false, existing: mine, desiredReason: "", desiredLevel: .elevated),
      .clear
    )
    let agent = entry(level: 1, reason: "boss", setBy: ThreadPrioritySource.agent)
    XCTAssertEqual(
      KeepTabsPriority.decide(wantPrioritized: false, existing: agent, desiredReason: "", desiredLevel: .elevated),
      .leave
    )
    XCTAssertEqual(
      KeepTabsPriority.decide(wantPrioritized: false, existing: nil, desiredReason: "", desiredLevel: .elevated),
      .leave
    )
  }

  // MARK: - reconcile round-trip against the real ThreadPriorityStore

  @MainActor
  func test_reconcileInjectsClearsAndNeverClobbersAgent() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("keep-tabs-priority-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    setenv("MESSAGES_FOR_AI_HOME", scratch.path, 1)
    defer {
      unsetenv("MESSAGES_FOR_AI_HOME")
      try? FileManager.default.removeItem(at: scratch)
    }

    let priorities = ThreadPriorityStore(startWatching: false)
    let ktStore = KeepTabsStore(fileURL: scratch.appendingPathComponent("keep-tabs.json"))
    let controller = KeepTabsController(store: ktStore, priorities: priorities)

    // Seed: thread 50 already has an AGENT P1. Keep Tabs must never touch it.
    priorities.setPriority(.urgent, platform: .imessage, threadID: 50, handle: "", reason: "boss waiting", setBy: ThreadPrioritySource.agent)

    // Reconcile: 50 desired (but agent-owned) + 60 desired (fresh).
    controller.reconcileKeepTabsPriorities(desired: [
      50: "Keeping tabs — quiet 3 weeks",
      60: "Keeping tabs — quiet 2 weeks",
    ])

    XCTAssertEqual(priorities.priority(platform: .imessage, threadID: 50, handle: "")?.setBy, ThreadPrioritySource.agent)
    XCTAssertEqual(priorities.priority(platform: .imessage, threadID: 50, handle: "")?.level, 1, "agent priority must be untouched")
    XCTAssertEqual(priorities.priority(platform: .imessage, threadID: 60, handle: "")?.setBy, ThreadPrioritySource.keepTabs)
    XCTAssertEqual(priorities.priority(platform: .imessage, threadID: 60, handle: "")?.level, ThreadPriorityLevel.elevated.rawValue)

    // Now nothing is desired (e.g. everyone replied, or auto-prioritize turned off).
    controller.reconcileKeepTabsPriorities(desired: [:])

    XCTAssertNil(priorities.priority(platform: .imessage, threadID: 60, handle: ""), "keep-tabs entry cleared once no longer desired")
    XCTAssertEqual(priorities.priority(platform: .imessage, threadID: 50, handle: "")?.setBy, ThreadPrioritySource.agent, "agent priority still untouched")
  }
}
