import Foundation
import XCTest
@testable import MessagesForAIMenu

final class ThreadPriorityTests: XCTestCase {
  // MARK: - Parsing (the on-disk contract shared with the MCP stores)

  func test_parseDecodesContractShape() throws {
    let json = """
      {
        "schema_version": 1,
        "priorities": {
          "42": { "level": 1, "reason": "deadline tonight", "set_at": "2026-06-09T22:00:00.000Z", "set_by": "agent" },
          "7": { "level": 3, "set_at": "2026-06-09T21:00:00.000Z", "set_by": "agent" }
        }
      }
      """
    let parsed = ThreadPriorityPolicy.parse(Data(json.utf8))
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed["42"]?.level, 1)
    XCTAssertEqual(parsed["42"]?.reason, "deadline tonight")
    XCTAssertNil(parsed["7"]?.reason)
  }

  func test_parseToleratesMissingCorruptAndWrongVersion() {
    XCTAssertTrue(ThreadPriorityPolicy.parse(nil).isEmpty)
    XCTAssertTrue(ThreadPriorityPolicy.parse(Data()).isEmpty)
    XCTAssertTrue(ThreadPriorityPolicy.parse(Data("not json".utf8)).isEmpty)
    let wrongVersion = """
      { "schema_version": 2, "priorities": { "1": { "level": 1, "set_at": "x", "set_by": "agent" } } }
      """
    XCTAssertTrue(ThreadPriorityPolicy.parse(Data(wrongVersion.utf8)).isEmpty)
  }

  func test_parseDropsOutOfRangeLevels() {
    let json = """
      {
        "schema_version": 1,
        "priorities": {
          "1": { "level": 0, "set_at": "2026-06-09T22:00:00.000Z", "set_by": "agent" },
          "2": { "level": 4, "set_at": "2026-06-09T22:00:00.000Z", "set_by": "agent" },
          "3": { "level": 2, "set_at": "2026-06-09T22:00:00.000Z", "set_by": "agent" }
        }
      }
      """
    let parsed = ThreadPriorityPolicy.parse(Data(json.utf8))
    XCTAssertEqual(Array(parsed.keys), ["3"])
  }

  // MARK: - Queue ordering

  func test_partitionSortsByLevelThenRecency() {
    let conversations = [
      conversation(threadID: 1, title: "Old urgent", lastMessage: date(hoursAgo: 30)),
      conversation(threadID: 2, title: "Recent plain", lastMessage: date(hoursAgo: 1)),
      conversation(threadID: 3, title: "Fresh urgent", lastMessage: date(hoursAgo: 2)),
      conversation(threadID: 4, title: "High", lastMessage: date(hoursAgo: 1)),
    ]
    let entries: [String: ThreadPriorityEntry] = [
      "1": entry(level: 1),
      "3": entry(level: 1),
      "4": entry(level: 2),
    ]
    let split = ThreadPriorityPolicy.partition(conversations) { conversation in
      conversation.recent.threadID.flatMap { entries[String($0)] }
    }
    XCTAssertEqual(split.priority.map(\.title), ["Fresh urgent", "Old urgent", "High"])
    XCTAssertEqual(split.rest.map(\.title), ["Recent plain"])
  }

  func test_partitionWithNoPrioritiesLeavesOrderUntouched() {
    let conversations = [
      conversation(threadID: 1, title: "A", lastMessage: date(hoursAgo: 1)),
      conversation(threadID: 2, title: "B", lastMessage: date(hoursAgo: 2)),
    ]
    let split = ThreadPriorityPolicy.partition(conversations) { _ in nil }
    XCTAssertTrue(split.priority.isEmpty)
    XCTAssertEqual(split.rest.map(\.title), ["A", "B"])
  }

  // MARK: - Store round-trip (user set/clear writes the shared file)

  @MainActor
  func test_storeWriteIsReadableByContractParser() throws {
    // Point the store at a scratch HOME so we don't touch the real files.
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("thread-priority-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    setenv("MESSAGES_FOR_AI_HOME", scratch.path, 1)
    defer {
      unsetenv("MESSAGES_FOR_AI_HOME")
      try? FileManager.default.removeItem(at: scratch)
    }

    let store = ThreadPriorityStore(startWatching: false)
    let recent = RecentComposeThread(
      id: "imessage-42",
      platform: .imessage,
      handle: "+14045550100",
      title: "Allie",
      subtitle: "",
      threadID: 42,
      lastMessageDate: Date()
    )

    store.setPriority(.urgent, for: recent)
    XCTAssertEqual(store.priority(for: recent)?.level, 1)

    let file = scratch
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("thread-priorities.json")
    let reparsed = ThreadPriorityPolicy.parse(try Data(contentsOf: file))
    XCTAssertEqual(reparsed["42"]?.level, 1)
    XCTAssertEqual(reparsed["42"]?.setBy, "user")

    store.clearPriority(for: recent)
    XCTAssertNil(store.priority(for: recent))
    let cleared = ThreadPriorityPolicy.parse(try Data(contentsOf: file))
    XCTAssertTrue(cleared.isEmpty)
  }

  // MARK: - Helpers

  private func conversation(threadID: Int, title: String, lastMessage: Date) -> MessageConversation {
    MessageConversation(
      recent: RecentComposeThread(
        id: "imessage-\(threadID)",
        platform: .imessage,
        handle: "+1404555\(String(format: "%04d", threadID))",
        title: title,
        subtitle: "",
        threadID: threadID,
        lastMessageDate: lastMessage
      ),
      draftThread: nil
    )
  }

  private func entry(level: Int) -> ThreadPriorityEntry {
    ThreadPriorityEntry(level: level, reason: nil, setAt: "2026-06-09T22:00:00.000Z", setBy: "agent")
  }

  private func date(hoursAgo: Double) -> Date {
    Date(timeIntervalSinceNow: -hoursAgo * 3600)
  }
}
