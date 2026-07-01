import Foundation

/// Local, metadata-only ledger of BYOK (bring-your-own-key) AI calls — the data
/// behind the Usage pane and the budget guardrail (issue #145). Owns
/// `~/.messages-mcp/ai-usage.json` (the menu bar is the single writer).
///
/// PRIVACY INVARIANT: this stores only counts and identifiers — feature, model,
/// token counts, estimated cost, status. It NEVER stores prompts, completions,
/// message bodies, or any conversation text. Token counts come straight from the
/// provider's response `usage` object; cost is an app-side estimate (the
/// provider's billing is authoritative).

/// How a recorded event's cost was derived.
/// - `exact`: real token counts × a known price-table entry.
/// - `estimated`: the provider omitted `usage`, so cost falls back to the
///   per-feature token estimate (`AIUsageEstimate`).
/// - `unknownPrice`: tokens are known but the model isn't in the price table
///   (e.g. a brand-new model) — cost is left nil rather than silently $0.
enum AICostBasis: String, Codable, Equatable {
  case exact
  case estimated
  case unknownPrice = "unknown_price"
}

/// Terminal state of a recorded AI call.
enum AIUsageStatus: String, Codable, Equatable {
  case ok
  case error
  case cancelled
  case blockedByBudget = "blocked_by_budget"
}

/// One recorded AI call. `lab`/`provider` are stored as raw strings so a future
/// enum addition (or a hand-edit) never drops the row on decode.
struct AIUsageEvent: Codable, Identifiable, Equatable {
  var id: String
  var timestamp: String
  var lab: String
  var provider: String
  var modelID: String
  var inputTokens: Int?
  var outputTokens: Int?
  var costUSD: Double?
  var costBasis: AICostBasis
  var status: AIUsageStatus
  var runID: String?

  enum CodingKeys: String, CodingKey {
    case id
    case timestamp
    case lab
    case provider
    case modelID = "model_id"
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case costUSD = "cost_usd"
    case costBasis = "cost_basis"
    case status
    case runID = "run_id"
  }

  init(
    id: String,
    timestamp: String,
    lab: String,
    provider: String,
    modelID: String,
    inputTokens: Int?,
    outputTokens: Int?,
    costUSD: Double?,
    costBasis: AICostBasis,
    status: AIUsageStatus,
    runID: String?
  ) {
    self.id = id
    self.timestamp = timestamp
    self.lab = lab
    self.provider = provider
    self.modelID = modelID
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.costUSD = costUSD
    self.costBasis = costBasis
    self.status = status
    self.runID = runID
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
    timestamp = (try? c.decode(String.self, forKey: .timestamp)) ?? ""
    lab = (try? c.decode(String.self, forKey: .lab)) ?? ""
    provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
    modelID = (try? c.decode(String.self, forKey: .modelID)) ?? ""
    inputTokens = try? c.decodeIfPresent(Int.self, forKey: .inputTokens)
    outputTokens = try? c.decodeIfPresent(Int.self, forKey: .outputTokens)
    costUSD = try? c.decodeIfPresent(Double.self, forKey: .costUSD)
    costBasis = (try? c.decode(AICostBasis.self, forKey: .costBasis)) ?? .estimated
    status = (try? c.decode(AIUsageStatus.self, forKey: .status)) ?? .ok
    runID = try? c.decodeIfPresent(String.self, forKey: .runID)
  }

  var date: Date? { AIUsageLedger.parseISO(timestamp) }
  var aiLab: AILab? { AILab(rawValue: lab) }
  var aiProvider: TextingVoiceProvider? { TextingVoiceProvider(rawValue: provider) }
}

/// A monthly estimated-spend cap. `enforce` makes the cap fail-closed (block
/// further calls); when false the cap is advisory (warnings only).
struct AIUsageBudget: Codable, Equatable {
  var monthlyCapUSD: Double?
  var warnThresholds: [Double]
  var enforce: Bool

  enum CodingKeys: String, CodingKey {
    case monthlyCapUSD = "monthly_cap_usd"
    case warnThresholds = "warn_thresholds"
    case enforce
  }

  static let defaultThresholds: [Double] = [0.5, 0.8, 1.0]

  init(monthlyCapUSD: Double? = nil, warnThresholds: [Double] = defaultThresholds, enforce: Bool = true) {
    self.monthlyCapUSD = monthlyCapUSD
    self.warnThresholds = warnThresholds
    self.enforce = enforce
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    monthlyCapUSD = try? c.decodeIfPresent(Double.self, forKey: .monthlyCapUSD)
    let thresholds = (try? c.decode([Double].self, forKey: .warnThresholds)) ?? Self.defaultThresholds
    warnThresholds = thresholds.isEmpty ? Self.defaultThresholds : thresholds
    enforce = (try? c.decode(Bool.self, forKey: .enforce)) ?? true
  }
}

struct AIUsageDatabase: Codable, Equatable {
  var schemaVersion: Int
  var events: [AIUsageEvent]
  var budget: AIUsageBudget

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case events
    case budget
  }

  init(schemaVersion: Int = AIUsageLedger.schemaVersion, events: [AIUsageEvent] = [], budget: AIUsageBudget = AIUsageBudget()) {
    self.schemaVersion = schemaVersion
    self.events = events
    self.budget = budget
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? AIUsageLedger.schemaVersion
    events = (try? c.decode([AIUsageEvent].self, forKey: .events)) ?? []
    budget = (try? c.decode(AIUsageBudget.self, forKey: .budget)) ?? AIUsageBudget()
  }
}

/// Pulls token counts out of an already-decoded provider response. Anthropic
/// (`/v1/messages`) and the OpenAI Responses API (`/v1/responses`) both nest
/// `usage.input_tokens` / `usage.output_tokens` in the top-level object the text
/// extractor already decoded — so callers pass the parsed `root`, not raw bytes.
/// Returns nil components when a field is absent; NEVER fabricates a count.
enum AITokenUsageParser {
  static func tokens(fromResponseRoot root: [String: Any]) -> (inputTokens: Int?, outputTokens: Int?) {
    guard let usage = root["usage"] as? [String: Any] else { return (nil, nil) }
    let input = intValue(usage["input_tokens"]) ?? intValue(usage["prompt_tokens"])
    let output = intValue(usage["output_tokens"]) ?? intValue(usage["completion_tokens"])
    return (input, output)
  }

  /// JSONSerialization yields NSNumber for numbers; bridge defensively.
  static func intValue(_ any: Any?) -> Int? {
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let d = any as? Double { return Int(d) }
    return nil
  }
}

/// Per-feature rollup for the current month.
struct AIUsageFeatureRollup: Equatable, Identifiable {
  var lab: AILab
  var calls: Int
  var inputTokens: Int
  var outputTokens: Int
  var costUSD: Double
  var hasUnknownCost: Bool

  var id: String { lab.rawValue }
}

struct AIUsageMonthSummary: Equatable {
  var totalUSD: Double
  var byFeature: [AIUsageFeatureRollup]
  var estimatedCount: Int
  var unknownPriceCount: Int
  var blockedCount: Int
  var callCount: Int
}

/// Pure month-to-date aggregation over the ledger — the read-time math behind
/// the Usage pane and the budget gate. Blocked events carry no cost; they're
/// counted separately. Cost sums treat a nil cost (unknown price) as 0 but flag it.
enum AIUsageSummary {
  static func monthToDate(events: [AIUsageEvent], now: Date, calendar: Calendar = .current) -> AIUsageMonthSummary {
    let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
    let inMonth = events.filter { event in
      guard let date = event.date else { return false }
      return date >= monthStart
    }

    var total = 0.0
    var estimated = 0
    var unknownPrice = 0
    var blocked = 0
    var calls = 0
    var perLab: [AILab: AIUsageFeatureRollup] = [:]

    for event in inMonth {
      if event.status == .blockedByBudget { blocked += 1; continue }
      // Only successful calls count toward spend/usage.
      guard event.status == .ok, let lab = event.aiLab else { continue }
      calls += 1
      if event.costBasis == .estimated { estimated += 1 }
      if event.costBasis == .unknownPrice { unknownPrice += 1 }
      let cost = event.costUSD ?? 0
      total += cost
      var rollup = perLab[lab] ?? AIUsageFeatureRollup(lab: lab, calls: 0, inputTokens: 0, outputTokens: 0, costUSD: 0, hasUnknownCost: false)
      rollup.calls += 1
      rollup.inputTokens += event.inputTokens ?? 0
      rollup.outputTokens += event.outputTokens ?? 0
      rollup.costUSD += cost
      if event.costBasis == .unknownPrice { rollup.hasUnknownCost = true }
      perLab[lab] = rollup
    }

    let byFeature = perLab.values.sorted { $0.costUSD > $1.costUSD }
    return AIUsageMonthSummary(
      totalUSD: total,
      byFeature: byFeature,
      estimatedCount: estimated,
      unknownPriceCount: unknownPrice,
      blockedCount: blocked,
      callCount: calls
    )
  }
}

/// Narrow recording surface handed to the AI clients so they can log a call
/// without holding the whole store. `@MainActor` because the ledger persists on
/// the main actor; clients hop with `Task { @MainActor in recorder?.record(...) }`.
@MainActor
protocol AIUsageRecording: AnyObject, Sendable {
  func record(
    lab: AILab,
    provider: TextingVoiceProvider,
    modelID: String,
    inputTokens: Int?,
    outputTokens: Int?,
    status: AIUsageStatus,
    runID: UUID?
  )
}

/// Fire-and-forget bridge so a `nonisolated`/`async` AI transport can log a
/// successful call without awaiting the `@MainActor` ledger. Token counts are
/// extracted synchronously (so the parsed `root` is never captured by the Task)
/// and only the value-type result hops to the main actor. A nil recorder is a
/// no-op, so the no-key/deterministic paths cost nothing.
enum AIUsageReporter {
  static func report(
    _ recorder: (any AIUsageRecording)?,
    lab: AILab,
    provider: TextingVoiceProvider,
    modelID: String,
    responseRoot root: [String: Any],
    runID: UUID?,
    status: AIUsageStatus = .ok
  ) {
    guard let recorder else { return }
    let usage = AITokenUsageParser.tokens(fromResponseRoot: root)
    Task { @MainActor in
      recorder.record(
        lab: lab,
        provider: provider,
        modelID: modelID,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        status: status,
        runID: runID
      )
    }
  }
}

@MainActor
final class AIUsageLedger: ObservableObject, AIUsageRecording {
  nonisolated static let schemaVersion = 1
  /// Hard safety cap on retained rows (in addition to the current+prior-month
  /// window) so a runaway never grows the file unbounded.
  static let maxEvents = 5000

  @Published private(set) var database = AIUsageDatabase()
  @Published private(set) var lastError: String?

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("ai-usage.json")
    load()
  }

  // MARK: - reads

  /// Events newest-first (for the recent-calls list).
  var eventsNewestFirst: [AIUsageEvent] {
    database.events.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
  }

  var budget: AIUsageBudget { database.budget }

  func summary(now: Date = Date()) -> AIUsageMonthSummary {
    AIUsageSummary.monthToDate(events: database.events, now: now)
  }

  /// Estimated spend so far this month — the number the budget gate compares
  /// against the cap.
  func monthToDateUSD(now: Date = Date()) -> Double {
    summary(now: now).totalUSD
  }

  // MARK: - recording

  func record(
    lab: AILab,
    provider: TextingVoiceProvider,
    modelID: String,
    inputTokens: Int?,
    outputTokens: Int?,
    status: AIUsageStatus,
    runID: UUID?
  ) {
    let (cost, basis) = AIUsageEstimate.resolvedCostUSD(
      lab: lab,
      provider: provider,
      modelID: modelID,
      inputTokens: inputTokens,
      outputTokens: outputTokens
    )
    let event = AIUsageEvent(
      id: UUID().uuidString,
      timestamp: Self.iso(Date()),
      lab: lab.rawValue,
      provider: provider.rawValue,
      modelID: modelID,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      costUSD: cost,
      costBasis: basis,
      status: status,
      runID: runID?.uuidString
    )
    database.events.append(event)
    pruneEvents()
    persist()
  }

  // MARK: - budget mutations

  func setMonthlyCap(_ usd: Double?) {
    let normalized = usd.map { max(0, $0) }
    guard database.budget.monthlyCapUSD != normalized else { return }
    database.budget.monthlyCapUSD = normalized
    persist()
  }

  func setEnforce(_ on: Bool) {
    guard database.budget.enforce != on else { return }
    database.budget.enforce = on
    persist()
  }

  func setWarnThresholds(_ thresholds: [Double]) {
    let cleaned = thresholds.filter { $0 > 0 && $0 <= 1 }.sorted()
    let next = cleaned.isEmpty ? AIUsageBudget.defaultThresholds : cleaned
    guard database.budget.warnThresholds != next else { return }
    database.budget.warnThresholds = next
    persist()
  }

  func clearHistory() {
    guard !database.events.isEmpty else { return }
    database.events = []
    persist()
  }

  /// Drop events older than the start of the prior month, then cap the newest
  /// `maxEvents`. Keeping one prior month lets the UI show last-month-vs-this.
  private func pruneEvents(now: Date = Date(), calendar: Calendar = .current) {
    let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
    let priorMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart) ?? thisMonthStart
    var kept = database.events.filter { event in
      guard let date = event.date else { return false }
      return date >= priorMonthStart
    }
    if kept.count > Self.maxEvents {
      kept = Array(kept.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(Self.maxEvents))
    }
    database.events = kept
  }

  // MARK: - persistence (mirrors KeepTabsStore: 0600, atomic, corrupt-quarantine, symlink-refusing)

  func load() {
    do {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        database = AIUsageDatabase()
        lastError = nil
        return
      }
      guard let data = safeRead(fileURL) else {
        database = AIUsageDatabase()
        lastError = "Refused to read \(fileURL.lastPathComponent) (not a regular file)."
        return
      }
      database = try JSONDecoder().decode(AIUsageDatabase.self, from: data)
      lastError = nil
    } catch {
      let quarantined = quarantineCorruptFile()
      database = AIUsageDatabase()
      if let quarantined {
        NSLog("[ai-usage] failed to load %@ (%@); moved corrupt file to %@", fileURL.path, error.localizedDescription, quarantined.lastPathComponent)
        lastError = "Couldn't read your AI usage log (\(error.localizedDescription)). The old file was saved as \(quarantined.lastPathComponent) and a fresh one was started."
      } else {
        NSLog("[ai-usage] failed to load %@ (%@); could not move corrupt file aside", fileURL.path, error.localizedDescription)
        lastError = error.localizedDescription
      }
    }
  }

  /// Refuse to read a symlink — a planted link could redirect the read elsewhere.
  private func safeRead(_ url: URL) -> Data? {
    if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
       values.isSymbolicLink == true {
      return nil
    }
    return try? Data(contentsOf: url)
  }

  private func quarantineCorruptFile(now: Date = Date()) -> URL? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss"
    var stamp = formatter.string(from: now)
    var destination = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
    if FileManager.default.fileExists(atPath: destination.path) {
      stamp += "-\(UUID().uuidString.lowercased().prefix(8))"
      destination = fileURL.deletingLastPathComponent()
        .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
    }
    do {
      try FileManager.default.moveItem(at: fileURL, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  func persist() {
    database.schemaVersion = Self.schemaVersion
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(database)
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  nonisolated static func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  nonisolated static func parseISO(_ raw: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: raw) { return date }
    let withoutFractional = ISO8601DateFormatter()
    withoutFractional.formatOptions = [.withInternetDateTime]
    return withoutFractional.date(from: raw)
  }
}
