import Foundation

struct DiagnosticsEvent: Codable, Equatable {
  let timestamp: String
  let name: String
  let metadata: [String: String]
}

struct DiagnosticCrashReport: Identifiable, Equatable {
  let url: URL
  let date: Date

  var id: String { url.path }
}

struct DiagnosticsSummary: Equatable {
  let eventCount: Int
  let latestCrashReport: DiagnosticCrashReport?
  let eventLogURL: URL
  let logsDirectoryURL: URL
}

struct DiagnosticsStore {
  enum ExportError: Error {
    case zipFailed(String)
  }

  static let shared = DiagnosticsStore()

  let rootDirectory: URL
  let diagnosticReportsDirectories: [URL]
  let processInfoProvider: () -> [String: String]

  init(
    rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".messages-mcp"),
    diagnosticReportsDirectories: [URL] = [
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports/Retired")
    ],
    processInfoProvider: @escaping () -> [String: String] = DiagnosticsStore.defaultProcessInfo
  ) {
    self.rootDirectory = rootDirectory
    self.diagnosticReportsDirectories = diagnosticReportsDirectories
    self.processInfoProvider = processInfoProvider
  }

  var logsDirectoryURL: URL {
    rootDirectory.appendingPathComponent("logs", isDirectory: true)
  }

  var eventLogURL: URL {
    logsDirectoryURL.appendingPathComponent("menubar-events.jsonl")
  }

  var exportsDirectoryURL: URL {
    rootDirectory.appendingPathComponent("diagnostics", isDirectory: true)
  }

  func log(_ name: String, metadata: [String: CustomStringConvertible] = [:]) {
    do {
      try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
      let event = DiagnosticsEvent(
        timestamp: Self.iso(Date()),
        name: sanitizeToken(name, fallback: "event"),
        metadata: sanitized(metadata)
      )
      var data = try JSONEncoder().encode(event)
      data.append(Data("\n".utf8))
      // Append WITHOUT following symlinks (issue #83): the menu-bar app holds FDA,
      // so a same-user process must not be able to point menubar-events.jsonl at a
      // protected file and have us write to it. SafeLogFile opens O_NOFOLLOW and
      // rejects a symlink / wrong-owner path + parent.
      _ = SafeLogFile.append(data, to: eventLogURL)
    } catch {
      // Best effort only. Diagnostics must never affect product behavior.
    }
  }

  func summary() -> DiagnosticsSummary {
    DiagnosticsSummary(
      eventCount: eventCount(),
      latestCrashReport: crashReports(limit: 1).first,
      eventLogURL: eventLogURL,
      logsDirectoryURL: logsDirectoryURL
    )
  }

  func crashReports(limit: Int = 5) -> [DiagnosticCrashReport] {
    let names = ["MessagesForAIMenu", "Messages for AI", "messages-for-ai"]
    let extensions = Set(["ips", "crash", "diag"])
    let reports = diagnosticReportsDirectories.flatMap { directory -> [DiagnosticCrashReport] in
      guard let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ) else {
        return []
      }
      return urls.compactMap { url in
        guard extensions.contains(url.pathExtension.lowercased()),
              names.contains(where: { url.lastPathComponent.localizedCaseInsensitiveContains($0) }) else {
          return nil
        }
        return DiagnosticCrashReport(url: url, date: fileDate(url))
      }
    }
    return Array(reports.sorted { $0.date > $1.date }.prefix(limit))
  }

  func exportBundle(
    now: Date = Date(),
    includeLocalEvents: Bool = true,
    includeDaemonLogs: Bool = true,
    includeCrashReports: Bool = true
  ) throws -> URL {
    try FileManager.default.createDirectory(at: exportsDirectoryURL, withIntermediateDirectories: true)
    let stamp = Self.filenameStamp(now)
    let workDir = exportsDirectoryURL.appendingPathComponent("MessagesForAI-Diagnostics-\(stamp)", isDirectory: true)
    let zipURL = exportsDirectoryURL.appendingPathComponent("MessagesForAI-Diagnostics-\(stamp).zip")
    try? FileManager.default.removeItem(at: workDir)
    try? FileManager.default.removeItem(at: zipURL)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

    try writeInfo(to: workDir.appendingPathComponent("app-info.json"), now: now)
    if includeLocalEvents {
      try copyIfPresent(eventLogURL, to: workDir.appendingPathComponent("menubar-events.jsonl"))
    }

    if includeDaemonLogs {
      let logsOut = workDir.appendingPathComponent("daemon-logs", isDirectory: true)
      try FileManager.default.createDirectory(at: logsOut, withIntermediateDirectories: true)
      try copyIfPresent(logsDirectoryURL.appendingPathComponent("imessage-daemon.log"), to: logsOut.appendingPathComponent("imessage-daemon.log"))
      try copyIfPresent(logsDirectoryURL.appendingPathComponent("whatsapp-daemon.log"), to: logsOut.appendingPathComponent("whatsapp-daemon.log"))
    }

    let crashes = includeCrashReports ? crashReports(limit: 5) : []
    if includeCrashReports, !crashes.isEmpty {
      let crashesOut = workDir.appendingPathComponent("crash-reports", isDirectory: true)
      try FileManager.default.createDirectory(at: crashesOut, withIntermediateDirectories: true)
      for report in crashes {
        try copyIfPresent(report.url, to: crashesOut.appendingPathComponent(report.url.lastPathComponent))
      }
    }

    try zip(directory: workDir, output: zipURL)
    try? FileManager.default.removeItem(at: workDir)
    return zipURL
  }

  private func eventCount() -> Int {
    guard let data = try? Data(contentsOf: eventLogURL),
          let text = String(data: data, encoding: .utf8),
          !text.isEmpty else {
      return 0
    }
    return text.split(separator: "\n").count
  }

  private func writeInfo(to url: URL, now: Date) throws {
    var info = processInfoProvider()
    info["exported_at"] = Self.iso(now)
    info["event_count"] = "\(eventCount())"
    info["latest_crash_report"] = crashReports(limit: 1).first.map { $0.url.lastPathComponent } ?? "none"
    let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: Data.WritingOptions.atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func copyIfPresent(_ source: URL, to destination: URL) throws {
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  private func zip(directory: URL, output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = directory.deletingLastPathComponent()
    process.arguments = ["-qry", output.path, directory.lastPathComponent]
    let pipe = Pipe()
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "zip failed"
      throw ExportError.zipFailed(message)
    }
  }

  private func sanitized(_ metadata: [String: CustomStringConvertible]) -> [String: String] {
    metadata.reduce(into: [String: String]()) { result, pair in
      let key = sanitizeToken(pair.key, fallback: "field")
      guard !Self.forbiddenMetadataKeyFragments.contains(where: { key.localizedCaseInsensitiveContains($0) }) else {
        return
      }
      let value = String(describing: pair.value)
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      result[key] = String(value.prefix(120))
    }
  }

  private func sanitizeToken(_ value: String, fallback: String) -> String {
    let allowed = value.map { char -> Character in
      if char.isLetter || char.isNumber || char == "_" || char == "-" || char == "." {
        return char
      }
      return "_"
    }
    let token = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_-."))
    return token.isEmpty ? fallback : String(token.prefix(64))
  }

  private func fileDate(_ url: URL) -> Date {
    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
  }

  private static let forbiddenMetadataKeyFragments = [
    "body", "message", "prompt", "recipient", "handle", "phone", "email", "name", "text"
  ]

  private static func defaultProcessInfo() -> [String: String] {
    [
      "app_version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev",
      "build": (Bundle.main.object(forInfoDictionaryKey: "MFABuildSHA") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        ?? "unknown",
      "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
      "os": ProcessInfo.processInfo.operatingSystemVersionString
    ]
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func filenameStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}
