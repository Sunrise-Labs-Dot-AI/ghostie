import XCTest
@testable import MessagesForAIMenu

final class DiagnosticsStoreTests: XCTestCase {
  func testLogDropsSensitiveMetadataKeys() throws {
    let root = tempDir()
    let store = DiagnosticsStore(rootDirectory: root, diagnosticReportsDirectories: [])

    store.log("dont ghost scan", metadata: [
      "result_count": 4,
      "message_body": "secret body should not be logged",
      "recipient_name": "Taylor",
      "duration_ms": 120
    ])

    let raw = try String(contentsOf: store.eventLogURL)
    XCTAssertTrue(raw.contains("result_count"))
    XCTAssertTrue(raw.contains("duration_ms"))
    XCTAssertFalse(raw.contains("secret body should not be logged"))
    XCTAssertFalse(raw.contains("Taylor"))
    XCTAssertFalse(raw.contains("message_body"))
    XCTAssertFalse(raw.contains("recipient_name"))

    try? FileManager.default.removeItem(at: root)
  }

  func testCrashReportsFindsMessagesForAIReports() throws {
    let root = tempDir()
    let reports = tempDir()
    let crash = reports.appendingPathComponent("MessagesForAIMenu-2026-06-05-120000.ips")
    try "fake crash".write(to: crash, atomically: true, encoding: .utf8)
    let other = reports.appendingPathComponent("OtherApp-2026-06-05-120000.ips")
    try "ignore".write(to: other, atomically: true, encoding: .utf8)
    let store = DiagnosticsStore(rootDirectory: root, diagnosticReportsDirectories: [reports])

    let found = store.crashReports()

    XCTAssertEqual(found.map { $0.url.lastPathComponent }, ["MessagesForAIMenu-2026-06-05-120000.ips"])

    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: reports)
  }

  func testExportBundleCreatesZip() throws {
    let root = tempDir()
    let reports = tempDir()
    let store = DiagnosticsStore(
      rootDirectory: root,
      diagnosticReportsDirectories: [reports],
      processInfoProvider: { ["app_version": "test", "build": "abc123"] }
    )
    store.log("app_launch", metadata: ["result_count": 1])
    try "daemon output".write(
      to: store.logsDirectoryURL.appendingPathComponent("imessage-daemon.log"),
      atomically: true,
      encoding: .utf8
    )
    try "fake crash".write(
      to: reports.appendingPathComponent("MessagesForAIMenu-2026-06-05-120000.ips"),
      atomically: true,
      encoding: .utf8
    )

    let zip = try store.exportBundle(now: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
    XCTAssertEqual(zip.pathExtension, "zip")

    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: reports)
  }

  func testExportBundleRespectsIncludeOptions() throws {
    let root = tempDir()
    let reports = tempDir()
    let store = DiagnosticsStore(
      rootDirectory: root,
      diagnosticReportsDirectories: [reports],
      processInfoProvider: { ["app_version": "test", "build": "abc123"] }
    )
    store.log("app_launch", metadata: ["result_count": 1])
    try "daemon output".write(
      to: store.logsDirectoryURL.appendingPathComponent("imessage-daemon.log"),
      atomically: true,
      encoding: .utf8
    )
    try "fake crash".write(
      to: reports.appendingPathComponent("MessagesForAIMenu-2026-06-05-120000.ips"),
      atomically: true,
      encoding: .utf8
    )

    let zip = try store.exportBundle(
      now: Date(timeIntervalSince1970: 1_800_000_000),
      includeLocalEvents: false,
      includeDaemonLogs: false,
      includeCrashReports: false
    )
    let entries = try zipEntries(zip)

    XCTAssertTrue(entries.contains { $0.hasSuffix("app-info.json") })
    XCTAssertFalse(entries.contains { $0.hasSuffix("menubar-events.jsonl") })
    XCTAssertFalse(entries.contains { $0.contains("daemon-logs/") })
    XCTAssertFalse(entries.contains { $0.contains("crash-reports/") })

    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: reports)
  }

  private func zipEntries(_ zip: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z", "-1", zip.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: "\n").map(String.init)
  }

  private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("messages-ai-diagnostics-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
