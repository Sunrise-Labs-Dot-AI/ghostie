import XCTest
@testable import MessagesForAIMenu

final class HistoryFeedTests: XCTestCase {
  func testHistoryIncludesSentDraftsAndMCPActivity() throws {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let messagesDir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
    try """
    {"transport":"imessage","tool":"list_threads","ts":"2026-06-01T13:00:00.000Z","pid":123,"writer_path":"/app/imessage"}

    """.write(to: messagesDir.appendingPathComponent("mcp-activity.jsonl"), atomically: true, encoding: .utf8)

    let sent = try draft(
      id: "sent1",
      body: "Already reviewed",
      stagedAt: "2026-06-01T12:00:00.000Z",
      sentAt: "2026-06-01T12:30:00.000Z"
    )

    let items = HistoryFeedLoader.load(home: home, drafts: [sent])

    XCTAssertTrue(items.contains { $0.id == "sent-draft-sent1" && $0.preview == "Already reviewed" })
    XCTAssertTrue(items.contains { $0.kind == .mcpActivity && $0.title == "iMessage MCP: List Threads" })
  }

  func testHistorySuppressesAuditRowWhenSentDraftStillExists() throws {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let messagesDir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
    try """
    {"ts":"2026-06-01T12:30:00.000Z","draft_id":"sent1","to_handle":"+14045550100","body_sha256":"abcdef123456","service":"iMessage"}
    {"ts":"2026-06-01T12:40:00.000Z","draft_id":"swept1","to_handle":"+14045550200","body_sha256":"123456abcdef","service":"SMS"}

    """.write(to: messagesDir.appendingPathComponent("send-audit.log"), atomically: true, encoding: .utf8)
    let sent = try draft(
      id: "sent1",
      stagedAt: "2026-06-01T12:00:00.000Z",
      sentAt: "2026-06-01T12:30:00.000Z"
    )

    let items = HistoryFeedLoader.load(home: home, drafts: [sent])

    XCTAssertFalse(items.contains { $0.id.hasPrefix("imessage-audit-sent1") })
    XCTAssertTrue(items.contains { $0.id.hasPrefix("imessage-audit-swept1") })
  }

  func testHistoryDoesNotDedupWitnessFallbackBySubstringToolMatch() throws {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let messagesDir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
    try """
    {"transport":"imessage","tool":"list_threads_extended","ts":"2026-06-01T13:00:00.000Z","pid":123,"writer_path":"/app/imessage"}

    """.write(to: messagesDir.appendingPathComponent("mcp-activity.jsonl"), atomically: true, encoding: .utf8)
    try """
    {"tool":"list_threads","ts":"2026-06-01T13:00:01.000Z","pid":124,"writer_path":"/app/imessage"}
    """.write(to: messagesDir.appendingPathComponent("last_invocation_imessage.json"), atomically: true, encoding: .utf8)

    let items = HistoryFeedLoader.load(home: home, drafts: [])

    XCTAssertTrue(items.contains { $0.id == "mcp-imessage-list_threads_extended-2026-06-01T13:00:00.000Z" })
    XCTAssertTrue(items.contains { $0.id == "latest-witness-imessage-list_threads-2026-06-01T13:00:01.000Z" })
  }

  private func draft(
    id: String,
    body: String = "hello",
    stagedAt: String,
    sentAt: String?
  ) throws -> Draft {
    let sentField = sentAt.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "id": "\(id)",
      "to_handle": "+14045550100",
      "to_handle_name": "Allie",
      "body": "\(body)",
      "in_reply_to_thread_id": null,
      "staged_at": "\(stagedAt)",
      "sent_at": \(sentField),
      "send_service": "iMessage",
      "source": "test",
      "context_messages": [],
      "context_diagnostic": null,
      "scheduled_send_at": null,
      "schedule_approved": null
    }
    """
    return try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
  }

  private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("messages-ai-history-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
