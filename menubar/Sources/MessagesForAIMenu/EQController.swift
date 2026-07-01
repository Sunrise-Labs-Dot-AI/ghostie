import Foundation
import SQLite3

struct EQPerson: Identifiable, Equatable {
  let id: Int
  let displayName: String
  let handle: String
  let messageCount: Int
  let lastMessageAt: Date
}

struct EQMessage: Identifiable, Equatable {
  let id: Int64
  let fromMe: Bool
  let body: String
  let sentAt: Date
}

enum EQPresetCategory: String, CaseIterable, Identifiable {
  case connection = "Connection"
  case conflictRepair = "Conflict & Repair"
  case support = "Support"
  case boundaries = "Boundaries"
  case celebration = "Celebration & Play"
  case growth = "Growth"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .connection: return "person.2"
    case .conflictRepair: return "arrow.triangle.2.circlepath"
    case .support: return "heart"
    case .boundaries: return "shield"
    case .celebration: return "party.popper"
    case .growth: return "leaf"
    }
  }
}

// Vetted preset prompts only — there is deliberately NO free-text prompt.
// A free-text prompt let users (or pasted text) steer the model's
// relationship analysis arbitrarily, which is an injection surface on a
// feature that reads private conversations. New questions are added here,
// reviewed, and stay in the reflective-coaching register: specific,
// non-leading, no diagnosis, no clinical claims.
struct EQPreset: Identifiable, Hashable {
  let id: String
  let title: String
  let prompt: String
  let category: EQPresetCategory

  static func presets(in category: EQPresetCategory) -> [EQPreset] {
    all.filter { $0.category == category }
  }

  static let all: [EQPreset] = [
    // Connection
    .init(
      id: "better-friend",
      title: "Better to them",
      prompt: "How could I be better to {person}, given the kind of relationship we actually seem to have?",
      category: .connection
    ),
    .init(
      id: "bids",
      title: "Bids I miss",
      prompt: "Where is {person} making bids for attention, support, play, repair, or help, and how am I responding?",
      category: .connection
    ),
    .init(
      id: "closeness-moments",
      title: "What brings us close",
      prompt: "Which exchanges with {person} seem to bring us closest, and what made those moments work?",
      category: .connection
    ),
    .init(
      id: "who-reaches-out",
      title: "Who reaches out",
      prompt: "How balanced is the reaching-out between {person} and me, and what does that pattern suggest about how each of us starts connection?",
      category: .connection
    ),

    // Conflict & Repair
    .init(
      id: "repair",
      title: "Repair",
      prompt: "Where might my relationship with {person} benefit from repair, reassurance, or a warmer follow-up from me?",
      category: .conflictRepair
    ),
    .init(
      id: "friction-points",
      title: "Friction points",
      prompt: "Where do {person} and I tend to talk past each other, and what seems to be happening right before those moments?",
      category: .conflictRepair
    ),
    .init(
      id: "after-tension",
      title: "After tension",
      prompt: "When tension shows up between {person} and me, how does each of us move back toward the other, and what tends to be left unsaid?",
      category: .conflictRepair
    ),

    // Support
    .init(
      id: "care",
      title: "Care map",
      prompt: "What seems to make {person} feel cared for, and what small actions would likely matter most?",
      category: .support
    ),
    .init(
      id: "showing-up",
      title: "Showing up",
      prompt: "When {person} seems stressed or low, how do I tend to respond, and what kind of support do they appear to receive best?",
      category: .support
    ),
    .init(
      id: "checking-in",
      title: "Checking in",
      prompt: "Who tends to do the emotional checking-in between {person} and me, and how does each of us respond when the other does it?",
      category: .support
    ),

    // Boundaries
    .init(
      id: "asks-and-nos",
      title: "Asks and nos",
      prompt: "How do {person} and I each handle asking for things and declining them, and what happens in the thread after a no?",
      category: .boundaries
    ),
    .init(
      id: "overcommitting",
      title: "Overcommitting",
      prompt: "Where in my thread with {person} do I commit to things beyond my capacity, and how does that show up later?",
      category: .boundaries
    ),
    .init(
      id: "space-and-pace",
      title: "Space and pace",
      prompt: "What does the rhythm of replies between {person} and me suggest about the pace of contact each of us is comfortable with?",
      category: .boundaries
    ),

    // Celebration & Play
    .init(
      id: "celebrating-them",
      title: "Celebrating them",
      prompt: "How do I respond when {person} shares good news, and where could I make more of their wins?",
      category: .celebration
    ),
    .init(
      id: "play-and-humor",
      title: "Play and humor",
      prompt: "Where do play, humor, or shared silliness show up between {person} and me, and what keeps those exchanges going?",
      category: .celebration
    ),
    .init(
      id: "our-rituals",
      title: "Our rituals",
      prompt: "What small traditions, running jokes, or recurring check-ins do {person} and I keep alive, and which seem to matter most to them?",
      category: .celebration
    ),

    // Growth
    .init(
      id: "patterns",
      title: "Patterns",
      prompt: "What patterns and blind spots do you see in how {person} and I communicate?",
      category: .growth
    ),
    .init(
      id: "how-weve-changed",
      title: "How we've changed",
      prompt: "How has the way {person} and I talk changed over time, and what might that shift reflect?",
      category: .growth
    ),
    .init(
      id: "their-side",
      title: "Their side of it",
      prompt: "What might {person} experience on their end of our conversations that I may not be noticing from mine?",
      category: .growth
    )
  ]
}

enum EQRelationshipType: String, CaseIterable, Identifiable {
  case closeFriend = "Close friend"
  case friend = "Friend"
  case romanticPartner = "Romantic partner"
  case spousePartner = "Spouse / partner"
  case family = "Family"
  case parent = "Parent"
  case sibling = "Sibling"
  case coworker = "Coworker"
  case acquaintance = "Acquaintance"
  case other = "Other"

  var id: String { rawValue }
}

enum EQContextDepth: String, CaseIterable, Identifiable {
  case recent = "Recent"
  case pastYear = "Past year"
  case threadArc = "Thread arc"

  var id: String { rawValue }

  var maxPromptMessages: Int {
    switch self {
    case .recent: return 80
    case .pastYear: return 220
    case .threadArc: return 260
    }
  }

  var sourceSinceDate: Date? {
    switch self {
    case .recent, .threadArc:
      return nil
    case .pastYear:
      return Calendar.current.date(byAdding: .year, value: -1, to: Date())
    }
  }

  var helper: String {
    switch self {
    case .recent:
      return "Uses the latest 80 readable messages. Best for a recent moment or unresolved exchange."
    case .pastYear:
      return "Samples up to 220 messages from the past year. Best for current patterns."
    case .threadArc:
      return "Samples older, middle, and recent messages from the full thread. Best for long relationships, but still an excerpt."
    }
  }
}

enum EQError: Error {
  case chatDbMissing
  case sqliteOpen(String)
  case sqlitePrepare(String)
  case noAPIKey
  case noPerson
  case noMessages
  case invalidResponse
}

@MainActor
final class EQController: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading(String)
    case ready(Date)
    case failed(String)

    var label: String {
      switch self {
      case .idle: return "Ready"
      case .loading(let message): return message
      case .ready(let date): return "Updated \(TextingVoicePaths.relative(date))"
      case .failed(let message): return message
      }
    }
  }

  @Published private(set) var people: [EQPerson] = []
  @Published private(set) var messages: [EQMessage] = []
  @Published private(set) var report: String = ""
  @Published private(set) var status: Status = .idle
  @Published private(set) var isBusy = false

  /// Set by EQView from the environment so each report is metered (issue #145).
  var usageLedger: AIUsageLedger?

  var hasAnyAPIKey: Bool {
    TextingVoiceKeychain.hasAPIKey(.anthropic) || TextingVoiceKeychain.hasAPIKey(.openAI)
  }

  func loadPeople() {
    status = .loading("Loading recent people...")
    Task.detached(priority: .userInitiated) {
      do {
        let rows = try EQScanner.loadPeople()
        await MainActor.run {
          self.people = rows
          self.status = .idle
        }
      } catch {
        await MainActor.run {
          self.status = .failed(Self.userFacingError(error))
        }
      }
    }
  }

  func preview(_ person: EQPerson?) {
    guard let person else {
      messages = []
      return
    }
    Task.detached(priority: .userInitiated) {
      let rows = (try? EQScanner.loadMessages(chatID: person.id, limit: 8)) ?? []
      await MainActor.run {
        self.messages = rows
      }
    }
  }

  func generate(person: EQPerson?, relationship: String, contextDepth: EQContextDepth, prompt: String) {
    guard let person else {
      status = .failed(Self.userFacingError(EQError.noPerson))
      return
    }
    guard let client = EQLLMClient.available(recorder: usageLedger) else {
      status = .failed(Self.userFacingError(EQError.noAPIKey))
      return
    }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      status = .failed("Choose a prompt or write your own.")
      return
    }
    guard AIBudgetPrecheck.allow(lab: .eq, ledger: usageLedger) else {
      status = .failed(AIBudgetPrecheck.blockedMessage)
      return
    }
    let relationship = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
    let relationshipContext = relationship.isEmpty ? "Unspecified" : relationship

    isBusy = true
    report = ""
    status = .loading("Reading \(contextDepth.rawValue.lowercased()) context with \(person.displayName)...")
    let startedAt = Date()
    AnalyticsClient.shared.safeCapture(.labScanStarted, properties: [
      .lab: .string(AnalyticsLab.eq.rawValue)
    ])

    Task.detached(priority: .userInitiated) {
      do {
        let context = try EQScanner.loadContextMessages(chatID: person.id, depth: contextDepth)
        guard !context.isEmpty else { throw EQError.noMessages }
        await MainActor.run {
          self.messages = Array(context.suffix(8))
          self.status = .loading("Asking AI for an EQ report...")
        }
        let report = try await client.generateReport(
          person: person,
          relationship: relationshipContext,
          contextDepth: contextDepth,
          prompt: trimmedPrompt,
          totalThreadMessages: person.messageCount,
          messages: context
        )
        await MainActor.run {
          self.report = report
          self.status = .ready(Date())
          self.isBusy = false
          AnalyticsClient.shared.safeCapture(.labScanCompleted, properties: [
            .lab: .string(AnalyticsLab.eq.rawValue),
            .resultCountBucket: .string(AnalyticsClient.resultCountBucket(1)),
            .durationBucket: .string(AnalyticsClient.durationBucket(ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
          ])
        }
      } catch {
        await MainActor.run {
          self.status = .failed(Self.userFacingError(error))
          self.isBusy = false
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.eq.rawValue),
            .errorCategory: .string(AnalyticsClient.errorCategory(error).rawValue)
          ])
        }
      }
    }
  }

  func clearReport() {
    report = ""
    status = .idle
  }

  nonisolated static func userFacingError(_ error: Error) -> String {
    switch error {
    case EQError.chatDbMissing:
      return "Messages database not found."
    case EQError.sqliteOpen(let message):
      return "Could not read Messages. Check Full Disk Access. \(message)"
    case EQError.sqlitePrepare(let message):
      return "Could not scan Messages. \(message)"
    case EQError.noAPIKey:
      return "Add a Claude or ChatGPT API key in Settings first."
    case EQError.noPerson:
      return "Choose a person first."
    case EQError.noMessages:
      return "No readable messages found for that thread."
    case EQError.invalidResponse:
      return "The model returned an unreadable response."
    case let llm as EQLLMClient.APIError:
      return llm.message
    default:
      return error.localizedDescription
    }
  }
}

private enum EQScanner {
  static func loadPeople(limit: Int = 80) throws -> [EQPerson] {
    let dbURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { throw EQError.chatDbMissing }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let db { sqlite3_close(db) }
      throw EQError.sqliteOpen(message)
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT c.ROWID,
             c.display_name,
             h.id,
             COUNT(m.ROWID) AS message_count,
             MAX(m.date) AS last_date
      FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      JOIN handle h ON h.ROWID = chj.handle_id
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE (
        SELECT COUNT(*)
        FROM chat_handle_join one_to_one
        WHERE one_to_one.chat_id = c.ROWID
      ) = 1
        AND (
          (m.text IS NOT NULL AND length(trim(m.text)) > 0)
          OR m.attributedBody IS NOT NULL
        )
      GROUP BY c.ROWID, c.display_name, h.id
      HAVING COUNT(m.ROWID) >= 8
      ORDER BY MAX(m.date) DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw EQError.sqlitePrepare(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(limit))

    let resolver = EQContactResolver.load()
    var rows: [EQPerson] = []
    var seenHandles = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      let chatName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let handlePtr = sqlite3_column_text(stmt, 2) else { continue }
      let handle = String(cString: handlePtr).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !handle.isEmpty, seenHandles.insert(handle.lowercased()).inserted else { continue }
      let messageCount = Int(sqlite3_column_int(stmt, 3))
      let lastDate = imessageDate(sqlite3_column_int64(stmt, 4))
      let displayName = (chatName?.isEmpty == false ? chatName : nil)
        ?? resolver.resolve(handle)
        ?? handle
      rows.append(EQPerson(id: chatID, displayName: displayName, handle: handle, messageCount: messageCount, lastMessageAt: lastDate))
    }
    return rows
  }

  static func loadMessages(chatID: Int, limit: Int) throws -> [EQMessage] {
    try loadMessages(chatID: chatID, limit: limit, sinceDate: nil)
  }

  static func loadContextMessages(chatID: Int, depth: EQContextDepth) throws -> [EQMessage] {
    let source = try loadMessages(chatID: chatID, limit: nil, sinceDate: depth.sourceSinceDate)
    return sampleForReport(source, maxCount: depth.maxPromptMessages)
  }

  private static func loadMessages(chatID: Int, limit: Int?, sinceDate: Date?) throws -> [EQMessage] {
    let dbURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { throw EQError.chatDbMissing }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let db { sqlite3_close(db) }
      throw EQError.sqliteOpen(message)
    }
    defer { sqlite3_close(db) }

    var sql = """
      SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE cmj.chat_id = ?
        AND (
          (m.text IS NOT NULL AND length(trim(m.text)) > 0)
          OR m.attributedBody IS NOT NULL
        )
      """
    if sinceDate != nil {
      sql += "\n        AND m.date >= ?"
    }
    sql += "\n      ORDER BY m.date DESC"
    if limit != nil {
      sql += "\n      LIMIT ?"
    }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw EQError.sqlitePrepare(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    var bindIndex: Int32 = 1
    sqlite3_bind_int(stmt, bindIndex, Int32(chatID))
    bindIndex += 1
    if let sinceDate {
      sqlite3_bind_int64(stmt, bindIndex, dateToAppleNanoseconds(sinceDate))
      bindIndex += 1
    }
    if let limit {
      sqlite3_bind_int(stmt, bindIndex, Int32(limit))
    }

    var rows: [EQMessage] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let id = sqlite3_column_int64(stmt, 0)
      let sentAt = imessageDate(sqlite3_column_int64(stmt, 1))
      let fromMe = sqlite3_column_int(stmt, 2) == 1
      let textCol = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
      let attributed: Data? = {
        guard let blob = sqlite3_column_blob(stmt, 4) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 4))
        guard count > 0 else { return nil }
        return Data(bytes: blob, count: count)
      }()
      let body = bestMessageBody(textCol: textCol, attributedBody: attributed)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }
      rows.append(EQMessage(id: id, fromMe: fromMe, body: body, sentAt: sentAt))
    }
    return rows.reversed()
  }

  private static func sampleForReport(_ messages: [EQMessage], maxCount: Int) -> [EQMessage] {
    guard messages.count > maxCount else { return messages }
    let oldestCount = min(36, max(12, maxCount / 7))
    let recentCount = min(96, max(40, maxCount / 3))
    let middleCount = max(0, maxCount - oldestCount - recentCount)

    let oldest = Array(messages.prefix(oldestCount))
    let recent = Array(messages.suffix(recentCount))
    let middleStart = min(oldestCount, messages.count)
    let middleEnd = max(middleStart, messages.count - recentCount)
    let middle = Array(messages[middleStart..<middleEnd])

    var sampled = oldest
    sampled.append(contentsOf: evenlySample(middle, count: middleCount))
    sampled.append(contentsOf: recent)

    var seen = Set<Int64>()
    return sampled
      .filter { seen.insert($0.id).inserted }
      .sorted { $0.sentAt < $1.sentAt }
  }

  private static func evenlySample(_ messages: [EQMessage], count: Int) -> [EQMessage] {
    guard count > 0, !messages.isEmpty else { return [] }
    guard messages.count > count else { return messages }
    if count == 1 { return [messages[messages.count / 2]] }
    let step = Double(messages.count - 1) / Double(count - 1)
    return (0..<count).map { messages[Int((Double($0) * step).rounded())] }
  }

  static func imessageDate(_ raw: Int64) -> Date {
    if abs(raw) > 10_000_000_000_000 {
      return Date(timeIntervalSince1970: Double(raw) / 1_000_000_000.0 + 978_307_200.0)
    }
    if abs(raw) > 100_000_000 {
      return Date(timeIntervalSince1970: Double(raw) + 978_307_200.0)
    }
    return Date(timeIntervalSince1970: Double(raw))
  }

  private static func dateToAppleNanoseconds(_ date: Date) -> Int64 {
    Int64(((date.timeIntervalSince1970 - 978_307_200.0) * 1_000_000_000.0).rounded())
  }

  private static func bestMessageBody(textCol: String?, attributedBody: Data?) -> String {
    if let textCol, !textCol.isEmpty { return textCol }
    return decodeAttributedBody(attributedBody) ?? ""
  }

  private static func decodeAttributedBody(_ data: Data?) -> String? {
    guard let data, !data.isEmpty else { return nil }
    let bytes = [UInt8](data)
    let marker = Array("NSString".utf8)
    guard let markerIdx = bytes.firstRange(of: marker)?.lowerBound else { return nil }
    var cursor = markerIdx + marker.count
    while cursor < bytes.count - 1 {
      if bytes[cursor] == 0x01 && bytes[cursor + 1] == 0x2b {
        cursor += 2
        break
      }
      cursor += 1
    }
    guard cursor < bytes.count else { return nil }
    let first = bytes[cursor]
    cursor += 1
    let length: Int
    if first < 0x80 {
      length = Int(first)
    } else if first == 0x81 {
      guard cursor + 2 <= bytes.count else { return nil }
      length = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
      cursor += 2
    } else if first == 0x82 {
      guard cursor + 4 <= bytes.count else { return nil }
      length = Int(bytes[cursor])
        | (Int(bytes[cursor + 1]) << 8)
        | (Int(bytes[cursor + 2]) << 16)
        | (Int(bytes[cursor + 3]) << 24)
      cursor += 4
    } else {
      return nil
    }
    guard length > 0, cursor + length <= bytes.count else { return nil }
    return String(data: Data(bytes[cursor..<(cursor + length)]), encoding: .utf8)?
      .trimmingCharacters(in: .controlCharacters)
  }
}

private struct EQContactResolver {
  private let handles: [String: String]

  static func load() -> EQContactResolver {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".messages-mcp/contacts-cache.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let handles = json["handles"] as? [String: String] else {
      return EQContactResolver(handles: [:])
    }
    return EQContactResolver(handles: handles)
  }

  func resolve(_ handle: String) -> String? {
    let key = canonical(handle)
    guard !key.isEmpty,
          let name = handles[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else { return nil }
    return name
  }

  private func canonical(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter(\.isNumber)
    if digits.count >= 10 { return String(digits.suffix(10)) }
    return digits
  }
}

struct EQLLMClient {
  struct APIError: Error {
    let message: String
  }

  let provider: TextingVoiceProvider
  let apiKey: String
  let modelID: String
  var recorder: (any AIUsageRecording)? = nil

  static func available(recorder: (any AIUsageRecording)? = nil) -> EQLLMClient? {
    guard let selection = LabModelPreferences.clientSelection(for: .eq) else { return nil }
    return EQLLMClient(provider: selection.provider, apiKey: selection.apiKey, modelID: selection.modelID, recorder: recorder)
  }

  func generateReport(
    person: EQPerson,
    relationship: String,
    contextDepth: EQContextDepth,
    prompt: String,
    totalThreadMessages: Int,
    messages: [EQMessage]
  ) async throws -> String {
    let finalPrompt = EQReportPrompt.make(
      person: person,
      relationship: relationship,
      contextDepth: contextDepth,
      prompt: prompt,
      totalThreadMessages: totalThreadMessages,
      messages: messages
    )
    let report = try await complete(prompt: finalPrompt, maxTokens: 3000)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !report.isEmpty else { throw EQError.invalidResponse }
    return report
  }

  private func complete(prompt: String, maxTokens: Int) async throws -> String {
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
      "system": "You write relationship reflection reports from selected text excerpts. You never send messages.",
      "messages": [["role": "user", "content": prompt]]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw APIError(message: errorMessage(data: data, fallback: "Claude request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = root["content"] as? [[String: Any]] else { throw EQError.invalidResponse }
    AIUsageReporter.report(recorder, lab: .eq, provider: provider, modelID: modelID, responseRoot: root, runID: nil)
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
        ["role": "developer", "content": "You write relationship reflection reports from selected text excerpts. You never send messages."],
        ["role": "user", "content": prompt]
      ]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw APIError(message: errorMessage(data: data, fallback: "ChatGPT request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EQError.invalidResponse
    }
    AIUsageReporter.report(recorder, lab: .eq, provider: provider, modelID: modelID, responseRoot: root, runID: nil)
    if let text = root["output_text"] as? String { return text }
    if let output = root["output"] as? [[String: Any]] {
      return output.compactMap { item -> String? in
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { $0["text"] as? String }.joined()
      }.joined()
    }
    throw EQError.invalidResponse
  }

  private func errorMessage(data: Data, fallback: String) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
    if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    return fallback
  }
}

struct EQReportPrompt {
  static func make(
    person: EQPerson,
    relationship: String,
    contextDepth: EQContextDepth,
    prompt: String,
    totalThreadMessages: Int,
    messages: [EQMessage]
  ) -> String {
    let resolvedQuestion = prompt.replacingOccurrences(of: "{person}", with: person.displayName)
    let payload: [String: Any] = [
      "person": person.displayName,
      "relationship_to_user": relationship,
      "context_depth": contextDepth.rawValue,
      "context_depth_note": contextDepth.helper,
      "total_readable_thread_messages": totalThreadMessages,
      "excerpt_messages_sent_to_model": messages.count,
      "sample_summary": sampleSummary(messages: messages, totalThreadMessages: totalThreadMessages),
      "question": resolvedQuestion,
      "messages": messages.map {
        [
          "from": $0.fromMe ? "me" : person.displayName,
          "sent_at": iso($0.sentAt),
          "body": String($0.body.prefix(600))
        ]
      }
    ]

    return """
    You are helping the user reflect on a private text thread with emotional intelligence, humility, and practical care.

    The goal is not to diagnose the relationship. The goal is to help the user notice concrete patterns and choose a thoughtful next move.

    Use these BetterFriend research lenses:
    - Closeness is built through chosen time, reciprocal disclosure, responsiveness, and mutual care.
    - Volume is not closeness. Logistics, parenting, errands, and reminders can be care, but they are not the whole relationship.
    - A text thread is a lower-bound slice of the relationship. In-person time, shared life, phone calls, calendar events, and other channels may be invisible.
    - Relationship type matters. For a spouse, partner, family member, or co-parent, do not overread silence, logistics, or short messages as decay because much of the relationship can happen off-channel.
    - Look for bids: attempts to get attention, support, play, reassurance, repair, help, appreciation, or shared meaning.
    - Look for responsiveness: whether each person answers the emotional content, not only the factual request.
    - Compare older, middle, and recent excerpts when the sample allows it. If the evidence is thin or skewed, say so plainly.
    - Do not infer loneliness, attachment style, gender norms, culture, intent, or mental health. Do not shame either person.

    Write a concise markdown report with exactly these sections:

    # Short Read
    2-4 sentences answering the user's question directly.

    ## Evidence Quality
    Say what the sample can and cannot show. Mention if this is a sampled excerpt rather than the full relationship.

    ## What Seems To Matter To \(person.displayName)
    Name the recurring needs, values, stressors, delights, or care languages visible in the thread. Stay grounded.

    ## Bids And Responsiveness
    Identify bids from \(person.displayName), bids from the user, and whether the response tends to meet the emotional need or only the logistical need.

    ## Reciprocity, Care, And Repair
    Discuss initiation, disclosure, practical support, appreciation, tension, apologies, warmth, and repair opportunities. Only include what the evidence supports.

    ## What The User Might Be Missing
    3-5 specific blind spots or opportunities, phrased kindly.

    ## 3 Thoughtful Moves
    Three concrete actions. At least one should be non-text if a richer channel or in-person care seems more appropriate.

    Return markdown only. Do not include hidden reasoning.

    Data:
    \(json(payload))
    """
  }

  private static func sampleSummary(messages: [EQMessage], totalThreadMessages: Int) -> [String: Any] {
    let fromMe = messages.filter(\.fromMe).count
    let other = messages.count - fromMe
    let lengths = messages.map { $0.body.count }.sorted()
    let medianLength: Int = {
      guard !lengths.isEmpty else { return 0 }
      return lengths[lengths.count / 2]
    }()
    return [
      "sample_message_count": messages.count,
      "total_readable_thread_messages": totalThreadMessages,
      "sample_is_excerpt": messages.count < totalThreadMessages,
      "sample_first_at": messages.first.map { iso($0.sentAt) } ?? "",
      "sample_last_at": messages.last.map { iso($0.sentAt) } ?? "",
      "sample_from_user_count": fromMe,
      "sample_from_other_count": other,
      "sample_median_body_chars": medianLength
    ]
  }

  private static func json(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
