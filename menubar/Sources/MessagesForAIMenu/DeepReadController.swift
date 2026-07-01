import Foundation
import SQLite3

/// Runs the Deep Read pipeline: scan chat.db into metadata aggregates
/// (DeepRead.swift, pure), send ONE completion on the user's own key
/// (LabModelPreferences → .deepRead), parse the structured answer, and cache
/// it to disk so re-opening Wrapped never re-spends tokens. Regeneration is
/// explicit (`generate(force: true)`).
@MainActor
final class DeepReadController: ObservableObject {
  enum State: Equatable {
    case idle
    case loading(String)
    case ready(DeepReadInsights)
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var isBusy = false

  private let cacheURL: URL
  private let scanner: @Sendable () throws -> DeepReadStats
  private let completer: @Sendable (DeepReadStats, (any AIUsageRecording)?) async throws -> (text: String, modelID: String)
  /// Set by the owning view from the environment so each AI call is metered
  /// (issue #145). nil → no metering / no budget gate.
  var usageLedger: AIUsageLedger?

  init(
    cacheURL: URL = DeepReadController.defaultCacheURL,
    scanner: @escaping @Sendable () throws -> DeepReadStats = { try DeepReadScanner.scan() },
    completer: (@Sendable (DeepReadStats, (any AIUsageRecording)?) async throws -> (text: String, modelID: String))? = nil
  ) {
    self.cacheURL = cacheURL
    self.scanner = scanner
    self.completer = completer ?? { stats, recorder in
      guard let client = DeepReadLLMClient.available(recorder: recorder) else { throw DeepReadError.noAPIKey }
      let text = try await client.complete(prompt: DeepReadPrompt.make(stats: stats))
      return (text, client.modelID)
    }
    if let cached = Self.loadCache(from: cacheURL) {
      state = .ready(cached)
    }
  }

  nonisolated static var defaultCacheURL: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("wrapped-deep-read.json")
  }

  var insights: DeepReadInsights? {
    if case .ready(let insights) = state { return insights }
    return nil
  }

  func generate(force: Bool = false) {
    guard !isBusy else { return }
    if !force, case .ready = state { return }

    guard AIBudgetPrecheck.allow(lab: .deepRead, ledger: usageLedger) else {
      state = .failed(AIBudgetPrecheck.blockedMessage)
      return
    }

    isBusy = true
    state = .loading("Reading a year of texting metadata…")
    let startedAt = Date()
    AnalyticsClient.shared.safeCapture(.labScanStarted, properties: [
      .lab: .string(AnalyticsLab.wrappedDeepRead.rawValue)
    ])

    let scanner = self.scanner
    let completer = self.completer
    let cacheURL = self.cacheURL
    let recorder = self.usageLedger
    Task.detached(priority: .userInitiated) {
      do {
        let stats = try scanner()
        guard stats.totalMessages >= 25 else { throw DeepReadError.notEnoughHistory }
        await MainActor.run {
          self.state = .loading("Asking your model for the deep read…")
        }
        let (text, modelID) = try await completer(stats, recorder)
        let insights = try DeepReadParser.parse(text, modelID: modelID)
        Self.storeCache(insights, to: cacheURL)
        await MainActor.run {
          self.state = .ready(insights)
          self.isBusy = false
          AnalyticsClient.shared.safeCapture(.labScanCompleted, properties: [
            .lab: .string(AnalyticsLab.wrappedDeepRead.rawValue),
            .resultCountBucket: .string(AnalyticsClient.resultCountBucket(1)),
            .durationBucket: .string(AnalyticsClient.durationBucket(ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
          ])
        }
      } catch {
        await MainActor.run {
          self.state = .failed(Self.userFacingError(error))
          self.isBusy = false
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.wrappedDeepRead.rawValue),
            .errorCategory: .string(AnalyticsClient.errorCategory(error).rawValue)
          ])
        }
      }
    }
  }

  nonisolated static func userFacingError(_ error: Error) -> String {
    switch error {
    case DeepReadError.chatDbMissing:
      return "Messages database not found."
    case DeepReadError.sqliteOpen(let message):
      return "Could not read Messages. Check Full Disk Access. \(message)"
    case DeepReadError.sqlitePrepare(let message):
      return "Could not scan Messages. \(message)"
    case DeepReadError.noAPIKey:
      return "Add a Claude or ChatGPT API key in Settings first."
    case DeepReadError.notEnoughHistory:
      return "Not enough message history for a deep read yet."
    case DeepReadError.invalidResponse:
      return "The model returned an unreadable response. Try regenerating."
    case let api as DeepReadLLMClient.APIError:
      return api.message
    default:
      return error.localizedDescription
    }
  }

  // MARK: - Disk cache

  nonisolated static func loadCache(from url: URL) -> DeepReadInsights? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(DeepReadInsights.self, from: data)
  }

  nonisolated static func storeCache(_ insights: DeepReadInsights, to url: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(insights) else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

// MARK: - chat.db scan (metadata aggregates only; mirrors EQScanner's access)

enum DeepReadScanner {
  /// One read-only pass over the past year of 1:1 threads. Bodies are
  /// reduced to style booleans row-by-row (`DeepReadStyleProbe`) and the
  /// strings dropped before aggregation.
  static func scan(windowDays: Int = 365, now: Date = Date()) throws -> DeepReadStats {
    let dbURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { throw DeepReadError.chatDbMissing }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let db { sqlite3_close(db) }
      throw DeepReadError.sqliteOpen(message)
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT cmj.chat_id, m.date, m.is_from_me, m.text
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE m.date >= ?
        AND (
          SELECT COUNT(*)
          FROM chat_handle_join chj
          WHERE chj.chat_id = cmj.chat_id
        ) = 1
      ORDER BY cmj.chat_id, m.date
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw DeepReadError.sqlitePrepare(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    let windowStart = now.addingTimeInterval(-Double(windowDays) * 86_400)
    sqlite3_bind_int64(stmt, 1, appleNanoseconds(windowStart))

    var rows: [DeepReadRawMessage] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      let sentAt = appleDate(sqlite3_column_int64(stmt, 1))
      let fromMe = sqlite3_column_int(stmt, 2) == 1
      let body = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
      rows.append(DeepReadStyleProbe.probe(chatID: chatID, sentAt: sentAt, fromMe: fromMe, body: body))
    }
    return DeepReadAggregator.aggregate(rows, now: now, windowDays: windowDays)
  }

  private static func appleDate(_ raw: Int64) -> Date {
    if abs(raw) > 10_000_000_000_000 {
      return Date(timeIntervalSince1970: Double(raw) / 1_000_000_000.0 + 978_307_200.0)
    }
    if abs(raw) > 100_000_000 {
      return Date(timeIntervalSince1970: Double(raw) + 978_307_200.0)
    }
    return Date(timeIntervalSince1970: Double(raw))
  }

  private static func appleNanoseconds(_ date: Date) -> Int64 {
    Int64(((date.timeIntervalSince1970 - 978_307_200.0) * 1_000_000_000.0).rounded())
  }
}

// MARK: - Model call (BYOK; same shape as EQLLMClient)

struct DeepReadLLMClient {
  struct APIError: Error {
    let message: String
  }

  let provider: TextingVoiceProvider
  let apiKey: String
  let modelID: String
  var recorder: (any AIUsageRecording)? = nil

  static func available(recorder: (any AIUsageRecording)? = nil) -> DeepReadLLMClient? {
    guard let selection = LabModelPreferences.clientSelection(for: .deepRead) else { return nil }
    return DeepReadLLMClient(
      provider: selection.provider,
      apiKey: selection.apiKey,
      modelID: selection.modelID,
      recorder: recorder
    )
  }

  private static let system =
    "You turn aggregate texting statistics into short, playful personality reads. You never see message bodies. Return JSON only."

  func complete(prompt: String, maxTokens: Int = 1500) async throws -> String {
    switch provider {
    case .anthropic:
      return try await anthropic(prompt: prompt, maxTokens: maxTokens)
    case .openAI:
      return try await openAI(prompt: prompt, maxTokens: maxTokens)
    }
  }

  private func anthropic(prompt: String, maxTokens: Int) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = 180
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "max_tokens": maxTokens,
      "system": Self.system,
      "messages": [["role": "user", "content": prompt]]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw APIError(message: errorMessage(data: data, fallback: "Claude request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = root["content"] as? [[String: Any]] else { throw DeepReadError.invalidResponse }
    AIUsageReporter.report(recorder, lab: .deepRead, provider: provider, modelID: modelID, responseRoot: root, runID: nil)
    return content.compactMap { $0["text"] as? String }.joined()
  }

  private func openAI(prompt: String, maxTokens: Int) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 180
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": modelID,
      "max_output_tokens": maxTokens,
      "input": [
        ["role": "developer", "content": Self.system],
        ["role": "user", "content": prompt]
      ]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw APIError(message: errorMessage(data: data, fallback: "ChatGPT request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DeepReadError.invalidResponse
    }
    AIUsageReporter.report(recorder, lab: .deepRead, provider: provider, modelID: modelID, responseRoot: root, runID: nil)
    if let text = root["output_text"] as? String { return text }
    if let output = root["output"] as? [[String: Any]] {
      return output.compactMap { item -> String? in
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { $0["text"] as? String }.joined()
      }.joined()
    }
    throw DeepReadError.invalidResponse
  }

  private func errorMessage(data: Data, fallback: String) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
    if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    return fallback
  }
}
