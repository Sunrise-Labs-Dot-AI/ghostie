import Foundation
import CryptoKit

enum WorkPersonalLabel: String, Codable, CaseIterable, Identifiable, Hashable {
  case work
  case personal
  case both
  case neither
  /// Legitimate transactional senders — airlines, clinics, banks, delivery,
  /// verification codes. Distinct from spam so the filter can keep them.
  case business
  /// Unsolicited junk: marketing blasts, scams, political texts.
  case spam
  case unknown

  /// Tolerate the pre-split persisted value ("spam_business") by mapping it
  /// to .business — the closer of the two new bins for most old labels.
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    if raw == "spam_business" {
      self = .business
    } else {
      self = WorkPersonalLabel(rawValue: raw) ?? .unknown
    }
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .work: return "Work"
    case .personal: return "Personal"
    case .both: return "Both"
    case .neither: return "Neither"
    case .business: return "Business"
    case .spam: return "Spam"
    case .unknown: return "Unknown"
    }
  }

  var systemImage: String {
    switch self {
    case .work: return "briefcase"
    case .personal: return "person"
    case .both: return "arrow.left.and.right"
    case .neither: return "minus.circle"
    case .business: return "storefront"
    case .spam: return "xmark.bin"
    case .unknown: return "questionmark.circle"
    }
  }
}

enum WorkPersonalMode: String, Codable, CaseIterable, Identifiable {
  case basic
  case pro

  var id: String { rawValue }
  var title: String { self == .basic ? "Basic" : "Pro" }
}

enum WorkPersonalFilter: String, CaseIterable, Identifiable {
  case all
  case work
  case personal

  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: return "All"
    case .work: return "Work"
    case .personal: return "Personal"
    }
  }
}

struct WorkPersonalPersonLabel: Codable, Equatable {
  let label: WorkPersonalLabel
  let updatedAt: String
  let source: String
}

struct WorkPersonalMessageLabel: Codable, Equatable {
  let label: WorkPersonalLabel
  let confidence: Double?
  let reason: String?
  let provider: String?
  let modelID: String?
  let classifiedAt: String
}

/// A below-threshold AI guess from the first-pass sort: shown as a hint in
/// the refinement mini-game rather than applied automatically.
struct WorkPersonalAISuggestion: Codable, Equatable {
  let label: WorkPersonalLabel
  let confidence: Double
  let reason: String?
  let suggestedAt: String
}

/// Pure decision rule for the premium AI first pass: confident calls are
/// applied (source "ai"), uncertain ones become hints for the human pass.
enum WorkPersonalAIFirstPass {
  static let autoApplyConfidence = 0.8

  struct PersonDecision: Equatable {
    let personKey: String
    let label: WorkPersonalLabel
    let confidence: Double
    let reason: String?
  }

  static func partition(
    _ decisions: [PersonDecision]
  ) -> (apply: [PersonDecision], suggest: [PersonDecision]) {
    var apply: [PersonDecision] = []
    var suggest: [PersonDecision] = []
    for decision in decisions where decision.label != .unknown {
      if decision.confidence >= autoApplyConfidence {
        apply.append(decision)
      } else {
        suggest.append(decision)
      }
    }
    return (apply, suggest)
  }

  static func prompt(people: [[String: Any]], workDescription: String) -> String {
    let payload: [String: Any] = ["work_description": workDescription, "people": people]
    let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return """
    Classify each PERSON (a texting thread) as work, personal, both, neither, business, or spam.

    Use the user's work description as the main definition of work: content counts as "work" ONLY when it matches that description.
    Each person's "name" field is a strong signal on its own. Saved contact or group names like "Dads", "Mom", "Book Club", or a school, team, church, or family name → personal. Airline, clinic, pharmacy, bank, store, or brand names → business.
    Scheduling and logistics ("can you do 3pm", "running late", "see you there") do NOT imply work by themselves — friends and family coordinate constantly. Treat them as work only when the content matches the work description.
    "business" = legitimate automated or transactional senders the user wants to keep: airlines, clinics, pharmacies, banks, deliveries, appointment and verification messages (e.g. United, One Medical).
    "spam" = unsolicited junk: marketing blasts, scams, political fundraising. Short-code senders (5-6 digit numbers) are usually business or spam, never personal.
    Confidence is YOUR certainty for that person. When the evidence is ambiguous, return a LOWER confidence (below 0.8) instead of guessing — never guess "work" on thin evidence.

    Return JSON only in this shape:
    {"people":[{"key":"...","label":"work|personal|both|neither|business|spam","confidence":0.0,"reason":"short phrase"}]}

    Input:
    \(json)
    """
  }
}

struct WorkPersonalLastRun: Codable, Equatable {
  let status: String
  let message: String
  let provider: String?
  let modelID: String?
  let classifiedAt: String
  let itemCount: Int
}

struct WorkPersonalSortStep: Equatable {
  let personKey: String
  let appliedLabel: Bool
}

struct WorkPersonalSortState: Equatable {
  let queue: [RecentComposeThread]
  let currentIndex: Int
  let history: [WorkPersonalSortStep]

  var current: RecentComposeThread? {
    guard currentIndex >= 0, currentIndex < queue.count else { return nil }
    return queue[currentIndex]
  }

  var isComplete: Bool { current == nil }

  @MainActor
  static func make(from conversations: [RecentComposeThread], store: WorkPersonalStore) -> WorkPersonalSortState {
    WorkPersonalSortState(
      queue: conversations.filter { store.personLabel(for: $0) == .unknown },
      currentIndex: 0,
      history: []
    )
  }

  @MainActor
  func applying(label: WorkPersonalLabel, store: WorkPersonalStore) -> WorkPersonalSortState {
    guard let current else { return self }
    store.setPersonLabel(label, for: current, source: "manual")
    return WorkPersonalSortState(
      queue: queue,
      currentIndex: currentIndex + 1,
      history: history + [
        WorkPersonalSortStep(personKey: WorkPersonalKeys.personKey(for: current), appliedLabel: true)
      ]
    )
  }

  @MainActor
  func skipping() -> WorkPersonalSortState {
    guard let current else { return self }
    return WorkPersonalSortState(
      queue: queue,
      currentIndex: currentIndex + 1,
      history: history + [
        WorkPersonalSortStep(personKey: WorkPersonalKeys.personKey(for: current), appliedLabel: false)
      ]
    )
  }

  @MainActor
  func undo(store: WorkPersonalStore) -> WorkPersonalSortState {
    guard let last = history.last else { return self }
    if last.appliedLabel {
      store.clearPersonLabel(key: last.personKey)
    }
    return WorkPersonalSortState(
      queue: queue,
      currentIndex: max(0, currentIndex - 1),
      history: Array(history.dropLast())
    )
  }
}

enum WorkPersonalVisibility {
  static func strictFilter(_ label: WorkPersonalLabel, filter: WorkPersonalFilter) -> Bool {
    switch filter {
    case .all:
      return true
    case .work:
      return label == .work || label == .both
    case .personal:
      return label == .personal || label == .both
    }
  }

  static func messageVisible(
    messageLabel: WorkPersonalLabel?,
    personLabel: WorkPersonalLabel,
    filter: WorkPersonalFilter,
    proEnabled: Bool
  ) -> Bool {
    guard filter != .all else { return true }
    let effective = proEnabled ? (messageLabel ?? personLabel) : personLabel
    return strictFilter(effective, filter: filter)
  }

  static func conversationVisible(
    personLabel: WorkPersonalLabel,
    messageLabels: [WorkPersonalLabel],
    filter: WorkPersonalFilter,
    proEnabled: Bool
  ) -> Bool {
    guard filter != .all else { return true }
    if proEnabled, !messageLabels.isEmpty {
      return messageLabels.contains { strictFilter($0, filter: filter) }
    }
    return strictFilter(personLabel, filter: filter)
  }
}

enum WorkPersonalModeGate {
  static func shouldOpenSettings(requestedMode: WorkPersonalMode, hasAPIKey: Bool) -> Bool {
    requestedMode == .pro && !hasAPIKey
  }
}

/// The "state your profession" gate: AI pre-refinement needs a work
/// description to define "work", so the first run — and any run after the
/// description is cleared — routes through the declaration form.
enum WorkPersonalProfessionGate {
  static func shouldPresent(workDescription: String) -> Bool {
    workDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

enum WorkPersonalKeys {
  static func personKey(platform: Platform, handle: String) -> String {
    "person|\(platform.rawValue)|\(handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
  }

  static func personKey(for recent: RecentComposeThread) -> String {
    personKey(platform: recent.platform, handle: recent.handle)
  }

  static func conversationKey(for recent: RecentComposeThread) -> String {
    let threadPart = recent.threadID.map(String.init) ?? recent.handle.lowercased()
    return "conversation|\(recent.platform.rawValue)|\(threadPart)"
  }

  static func messageKey(conversationKey: String, message: ContextMessage) -> String {
    let raw = [
      conversationKey,
      message.from_me ? "me" : "them",
      message.sender_handle ?? "",
      message.sent_at ?? "",
      message.body ?? ""
    ].joined(separator: "\u{1F}")
    let digest = SHA256.hash(data: Data(raw.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "message|\(conversationKey)|\(digest)"
  }

  static func messagePrefix(conversationKey: String) -> String {
    "message|\(conversationKey)|"
  }
}

struct WorkPersonalClassificationItem: Encodable {
  let id: String
  let personLabel: String
  let sender: String?
  let sentAt: String?
  let body: String
}

struct WorkPersonalClassificationBatch: Encodable {
  let workDescription: String
  let items: [WorkPersonalClassificationItem]
}

enum WorkPersonalClassifierBatcher {
  @MainActor
  static func classificationBatch(
    conversations: [(RecentComposeThread, [ContextMessage])],
    store: WorkPersonalStore,
    limit: Int = 80
  ) -> WorkPersonalClassificationBatch {
    var items: [WorkPersonalClassificationItem] = []
    for (recent, messages) in conversations {
      let conversationKey = WorkPersonalKeys.conversationKey(for: recent)
      let personLabel = store.personLabel(for: recent)
      for message in messages where !(message.body ?? "").isEmpty {
        let id = WorkPersonalKeys.messageKey(conversationKey: conversationKey, message: message)
        guard store.messageLabels[id] == nil else { continue }
        items.append(
          WorkPersonalClassificationItem(
            id: id,
            personLabel: personLabel.rawValue,
            sender: message.from_me ? "me" : (message.sender_name ?? message.sender_handle),
            sentAt: message.sent_at,
            body: String((message.body ?? "").prefix(1200))
          )
        )
        if items.count >= limit {
          return WorkPersonalClassificationBatch(workDescription: store.workDescription, items: items)
        }
      }
    }
    return WorkPersonalClassificationBatch(workDescription: store.workDescription, items: items)
  }
}

/// When Severance turns itself on/off. Edge-triggered: the store
/// flips `enabled` only when a window boundary is crossed, so a manual toggle
/// mid-window sticks until the next boundary.
struct WorkPersonalSchedule: Codable, Equatable {
  var isOn: Bool
  /// Calendar weekday components (1 = Sunday … 7 = Saturday).
  var weekdays: Set<Int>
  /// Minutes from midnight, local time.
  var startMinutes: Int
  var endMinutes: Int

  static let weekdaysDefault = WorkPersonalSchedule(
    isOn: false,
    weekdays: [2, 3, 4, 5, 6],
    startMinutes: 9 * 60,
    endMinutes: 17 * 60
  )

  func isActive(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard isOn else { return false }
    let weekday = calendar.component(.weekday, from: date)
    guard weekdays.contains(weekday) else { return false }
    let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    if startMinutes <= endMinutes {
      return minutes >= startMinutes && minutes < endMinutes
    }
    // Overnight window (e.g. 22:00–06:00).
    return minutes >= startMinutes || minutes < endMinutes
  }
}

@MainActor
final class WorkPersonalStore: ObservableObject {
  @Published var enabled: Bool { didSet { persist() } }
  @Published var mode: WorkPersonalMode { didSet { persist() } }
  @Published var workDescription: String { didSet { persist() } }
  @Published private(set) var personLabels: [String: WorkPersonalPersonLabel]
  @Published private(set) var messageLabels: [String: WorkPersonalMessageLabel]
  @Published private(set) var lastRun: WorkPersonalLastRun?
  @Published private(set) var aiSuggestions: [String: WorkPersonalAISuggestion]
  @Published private(set) var status: String = "Ready"
  @Published var schedule: WorkPersonalSchedule {
    didSet {
      persist()
      syncScheduleTimer()
    }
  }

  private let file: URL
  private var scheduleTimer: Timer?
  private var lastScheduleState: Bool?
  /// Meters Severance's AI classification calls (issue #145); nil → no metering.
  var usageLedger: AIUsageLedger?

  init(homeOverride: URL? = nil, usageLedger: AIUsageLedger? = nil) {
    self.usageLedger = usageLedger
    let home = homeOverride ?? AppStoragePaths.homeDirectory
    let dir = home.appendingPathComponent(".messages-mcp")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.file = dir.appendingPathComponent("work-personal.json")
    let loaded = Self.load(from: file)
    self.enabled = loaded.enabled
    self.mode = loaded.mode
    self.workDescription = loaded.workDescription
    self.personLabels = loaded.personLabels
    self.messageLabels = loaded.messageLabels
    self.lastRun = loaded.lastRun
    self.aiSuggestions = loaded.aiSuggestions
    self.schedule = loaded.schedule
    if loaded.requiresWrite { persist() }
    syncScheduleTimer()
  }

  // MARK: - Premium AI first pass

  /// Classify up to `cap` unlabeled people so the human refinement pass only
  /// has to handle the low-confidence remainder. Confident calls are applied
  /// with source "ai"; uncertain ones land in `aiSuggestions` as hints.
  /// `contextLoader` supplies a few recent messages per person (the same
  /// excerpt-based consent model the message classifier already uses).
  func runAIFirstPass(
    candidates: [RecentComposeThread],
    cap: Int = 60,
    contextLoader: (RecentComposeThread) async -> [ContextMessage]
  ) async {
    guard let selection = LabModelPreferences.clientSelection(for: .workPersonal) else {
      status = "Add an API key in Settings to use AI refinement."
      return
    }
    guard AIBudgetPrecheck.allow(lab: .workPersonal, ledger: usageLedger) else {
      status = AIBudgetPrecheck.blockedMessage
      return
    }
    let unlabeled = candidates
      .filter { personLabel(for: $0) == .unknown && !$0.isGroupConversation }
      .prefix(cap)
    guard !unlabeled.isEmpty else {
      status = "Nothing to refine — every conversation is already sorted."
      return
    }
    status = "AI refinement in progress…"
    var people: [[String: Any]] = []
    var keyToThread: [String: RecentComposeThread] = [:]
    for thread in unlabeled {
      let key = WorkPersonalKeys.personKey(for: thread)
      keyToThread[key] = thread
      let context = await contextLoader(thread)
      let snippets = context
        .filter { !$0.from_me }
        .suffix(3)
        .compactMap { $0.body.map { body in String(body.prefix(280)) } }
      let digits = thread.handle.filter(\.isNumber)
      let kind: String
      if thread.handle.contains("@") {
        kind = "email"
      } else if digits.count <= 6 && !digits.isEmpty {
        kind = "shortcode"
      } else {
        kind = "phone"
      }
      people.append([
        "key": key,
        "name": thread.title,
        "handle_kind": kind,
        "recent_inbound": snippets,
      ])
    }
    do {
      let prompt = WorkPersonalAIFirstPass.prompt(people: people, workDescription: workDescription)
      let decisions = try await WorkPersonalClassifier.classifyPeople(prompt: prompt, selection: selection, recorder: usageLedger, runID: UUID())
      let split = WorkPersonalAIFirstPass.partition(decisions)
      for decision in split.apply where keyToThread[decision.personKey] != nil {
        setPersonLabel(decision.label, key: decision.personKey, source: "ai")
      }
      let now = WorkPersonalStore.iso(Date())
      for decision in split.suggest where keyToThread[decision.personKey] != nil {
        aiSuggestions[decision.personKey] = WorkPersonalAISuggestion(
          label: decision.label,
          confidence: decision.confidence,
          reason: decision.reason,
          suggestedAt: now
        )
      }
      persist()
      status = "AI sorted \(split.apply.count) of \(people.count); \(split.suggest.count) left for you."
    } catch {
      status = (error as? WorkPersonalClassifierError)?.errorDescription
        ?? "AI refinement failed: \(error.localizedDescription)"
    }
  }

  /// Deterministic, no-API-key first pass: auto-bin conversations whose handle or
  /// saved name is an obvious business as `.business` (source "auto-business"), so
  /// they never reach the manual sort queue — the user shouldn't have to hand-tag
  /// DoorDash or a pharmacy. Uses the shared `BusinessFilter` (the same one Don't
  /// Ghost / Keep Tabs / Birthdays use). Conservative: only still-unknown, 1:1
  /// threads are touched, so a manual or AI label always wins, and a person whose
  /// surname merely resembles a token ("Banks", "Healey") is never mis-binned.
  /// Returns how many it tagged.
  @discardableResult
  func autoTagObviousBusinesses(_ candidates: [RecentComposeThread]) -> Int {
    let now = Self.iso(Date())
    var tagged = 0
    for thread in candidates where !thread.isGroupConversation {
      guard personLabel(for: thread) == .unknown else { continue }
      guard BusinessFilter.looksLikeBusiness(handle: thread.handle, name: thread.title) else { continue }
      personLabels[WorkPersonalKeys.personKey(for: thread)] =
        WorkPersonalPersonLabel(label: .business, updatedAt: now, source: "auto-business")
      tagged += 1
    }
    if tagged > 0 { persist() }
    return tagged
  }

  func aiSuggestion(for recent: RecentComposeThread) -> WorkPersonalAISuggestion? {
    aiSuggestions[WorkPersonalKeys.personKey(for: recent)]
  }

  func clearAISuggestion(key: String) {
    guard aiSuggestions.removeValue(forKey: key) != nil else { return }
    persist()
  }

  /// Edge-triggered schedule enforcement: at a window boundary the feature
  /// follows the schedule; between boundaries the user's manual toggle wins.
  func applyScheduleTick(now: Date = Date()) {
    guard schedule.isOn else { return }
    let active = schedule.isActive(at: now)
    if lastScheduleState == nil {
      // First observation after launch/toggle: adopt the scheduled state.
      lastScheduleState = active
      if enabled != active { enabled = active }
      return
    }
    if lastScheduleState != active {
      lastScheduleState = active
      if enabled != active { enabled = active }
    }
  }

  private func syncScheduleTimer() {
    scheduleTimer?.invalidate()
    scheduleTimer = nil
    lastScheduleState = nil
    guard schedule.isOn else { return }
    applyScheduleTick()
    let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      DispatchQueue.main.async { self?.applyScheduleTick() }
    }
    timer.tolerance = 10
    RunLoop.main.add(timer, forMode: .common)
    scheduleTimer = timer
  }

  func personLabel(for recent: RecentComposeThread) -> WorkPersonalLabel {
    personLabels[WorkPersonalKeys.personKey(for: recent)]?.label ?? .unknown
  }

  func setPersonLabel(_ label: WorkPersonalLabel, for recent: RecentComposeThread, source: String = "manual") {
    setPersonLabel(label, key: WorkPersonalKeys.personKey(for: recent), source: source)
  }

  func setPersonLabel(_ label: WorkPersonalLabel, key: String, source: String = "manual") {
    personLabels[key] = WorkPersonalPersonLabel(label: label, updatedAt: Self.iso(Date()), source: source)
    // A human decision supersedes any pending AI hint for this person.
    if source == "manual" {
      aiSuggestions.removeValue(forKey: key)
    }
    persist()
  }

  func clearPersonLabel(key: String) {
    personLabels.removeValue(forKey: key)
    persist()
  }

  func messageLabel(conversation: RecentComposeThread, message: ContextMessage) -> WorkPersonalLabel? {
    let conversationKey = WorkPersonalKeys.conversationKey(for: conversation)
    return messageLabels[WorkPersonalKeys.messageKey(conversationKey: conversationKey, message: message)]?.label
  }

  func messageLabels(for conversation: RecentComposeThread) -> [WorkPersonalLabel] {
    let prefix = WorkPersonalKeys.messagePrefix(conversationKey: WorkPersonalKeys.conversationKey(for: conversation))
    return messageLabels.compactMap { key, value in key.hasPrefix(prefix) ? value.label : nil }
  }

  func upsertMessageLabels(
    _ labels: [String: WorkPersonalMessageLabel],
    provider: TextingVoiceProvider,
    modelID: String
  ) {
    for (key, value) in labels {
      messageLabels[key] = value
    }
    lastRun = WorkPersonalLastRun(
      status: "ok",
      message: "Classified \(labels.count) messages.",
      provider: provider.rawValue,
      modelID: modelID,
      classifiedAt: Self.iso(Date()),
      itemCount: labels.count
    )
    status = lastRun?.message ?? "Classified messages."
    persist()
  }

  func setRunFailure(_ message: String) {
    lastRun = WorkPersonalLastRun(
      status: "failed",
      message: message,
      provider: nil,
      modelID: nil,
      classifiedAt: Self.iso(Date()),
      itemCount: 0
    )
    status = message
    persist()
  }

  private struct Stored: Codable {
    var schemaVersion: Int
    var enabled: Bool
    var mode: WorkPersonalMode
    var workDescription: String
    var personLabels: [String: WorkPersonalPersonLabel]
    var messageLabels: [String: WorkPersonalMessageLabel]
    var lastRun: WorkPersonalLastRun?
    var schedule: WorkPersonalSchedule?
    var aiSuggestions: [String: WorkPersonalAISuggestion]?
  }

  private struct Loaded {
    let enabled: Bool
    let mode: WorkPersonalMode
    let workDescription: String
    let personLabels: [String: WorkPersonalPersonLabel]
    let messageLabels: [String: WorkPersonalMessageLabel]
    let lastRun: WorkPersonalLastRun?
    let schedule: WorkPersonalSchedule
    let aiSuggestions: [String: WorkPersonalAISuggestion]
    let requiresWrite: Bool
  }

  private static func load(from file: URL) -> Loaded {
    guard FileManager.default.fileExists(atPath: file.path),
          let data = try? Data(contentsOf: file),
          let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      return Loaded(
        enabled: false,
        mode: .basic,
        workDescription: "",
        personLabels: [:],
        messageLabels: [:],
        lastRun: nil,
        schedule: .weekdaysDefault,
        aiSuggestions: [:],
        requiresWrite: true
      )
    }
    return Loaded(
      enabled: stored.enabled,
      mode: stored.mode,
      workDescription: stored.workDescription,
      personLabels: stored.personLabels,
      messageLabels: stored.messageLabels,
      lastRun: stored.lastRun,
      schedule: stored.schedule ?? .weekdaysDefault,
      aiSuggestions: stored.aiSuggestions ?? [:],
      requiresWrite: stored.schemaVersion < 1
    )
  }

  private func persist() {
    let stored = Stored(
      schemaVersion: 1,
      enabled: enabled,
      mode: mode,
      workDescription: workDescription,
      personLabels: personLabels,
      messageLabels: messageLabels,
      lastRun: lastRun,
      schedule: schedule,
      aiSuggestions: aiSuggestions
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(stored)
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      status = "Couldn't save Severance settings."
    }
  }

  nonisolated static func iso(_ date: Date) -> String {
    let key = "MessagesForAI.WorkPersonalStore.isoFormatter"
    if let formatter = Thread.current.threadDictionary[key] as? ISO8601DateFormatter {
      return formatter.string(from: date)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    Thread.current.threadDictionary[key] = formatter
    return formatter.string(from: date)
  }
}

enum WorkPersonalClassifierError: LocalizedError {
  case missingAPIKey
  case missingWorkDescription
  case emptyBatch
  case invalidResponse
  case api(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: return "Add a Claude or ChatGPT API key in Settings first."
    case .missingWorkDescription: return "Describe what counts as work first."
    case .emptyBatch: return "No new messages to classify."
    case .invalidResponse: return "The classifier response could not be read."
    case .api(let message): return message
    }
  }
}

enum WorkPersonalClassifier {
  struct Result {
    let labels: [String: WorkPersonalMessageLabel]
    let provider: TextingVoiceProvider
    let modelID: String
  }

  @MainActor
  static func classify(
    batch: WorkPersonalClassificationBatch,
    recorder: (any AIUsageRecording)? = nil,
    runID: UUID? = nil
  ) async throws -> Result {
    guard !batch.workDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkPersonalClassifierError.missingWorkDescription
    }
    guard !batch.items.isEmpty else { throw WorkPersonalClassifierError.emptyBatch }
    guard let selection = LabModelPreferences.clientSelection(for: .workPersonal) else {
      throw WorkPersonalClassifierError.missingAPIKey
    }
    let prompt = try makePrompt(batch: batch)
    let raw: String
    switch selection.provider {
    case .anthropic:
      raw = try await anthropic(prompt: prompt, selection: selection, recorder: recorder, runID: runID)
    case .openAI:
      raw = try await openAI(prompt: prompt, selection: selection, recorder: recorder, runID: runID)
    }
    return Result(
      labels: try parse(raw, provider: selection.provider, modelID: selection.modelID),
      provider: selection.provider,
      modelID: selection.modelID
    )
  }

  static func makePrompt(batch: WorkPersonalClassificationBatch) throws -> String {
    let data = try JSONEncoder().encode(batch)
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return """
    Classify each message as work, personal, both, neither, business, or spam.

    Use the user's work description as the main definition of work: content counts as "work" ONLY when it matches that description. Person labels are hints only; message content wins when it clearly differs.
    Sender and conversation names are real signals: names like "Dads", "Mom", "Book Club", or a school, team, church, or family name suggest personal; airline, clinic, pharmacy, bank, or brand names suggest business.
    Scheduling and logistics ("can you do 3pm", "running late") do NOT imply work by themselves — treat a message as work only when the content matches the work description.
    "business" = legitimate automated or transactional senders the user wants to keep: airlines, clinics, pharmacies, banks, deliveries, appointment and verification messages.
    "spam" = unsolicited junk: marketing blasts, scams, political fundraising, anything the user never opted into.
    When a message is ambiguous, return a lower confidence rather than guessing work.

    Return JSON only in this shape:
    {"labels":[{"id":"...","label":"work|personal|both|neither|business|spam","confidence":0.0,"reason":"short phrase"}]}

    Do not include message text in the output.

    Input:
    \(json)
    """
  }

  private static func anthropic(
    prompt: String,
    selection: LabModelSelection,
    recorder: (any AIUsageRecording)? = nil,
    runID: UUID? = nil
  ) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(selection.apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": selection.modelID,
      "max_tokens": 4000,
      "system": "Return JSON only. You classify local text-message excerpts for a user-controlled Work/Personal filter. Never draft or send messages.",
      "messages": [["role": "user", "content": prompt]]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw WorkPersonalClassifierError.api(errorMessage(data: data, fallback: "Claude request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = root["content"] as? [[String: Any]] else {
      throw WorkPersonalClassifierError.invalidResponse
    }
    AIUsageReporter.report(recorder, lab: .workPersonal, provider: selection.provider, modelID: selection.modelID, responseRoot: root, runID: runID)
    return content.compactMap { $0["text"] as? String }.joined()
  }

  private static func openAI(
    prompt: String,
    selection: LabModelSelection,
    recorder: (any AIUsageRecording)? = nil,
    runID: UUID? = nil
  ) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(selection.apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": selection.modelID,
      "max_output_tokens": 4000,
      "input": [
        ["role": "developer", "content": "Return JSON only. You classify local text-message excerpts for a user-controlled Work/Personal filter. Never draft or send messages."],
        ["role": "user", "content": prompt]
      ]
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw WorkPersonalClassifierError.api(errorMessage(data: data, fallback: "ChatGPT request failed."))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw WorkPersonalClassifierError.invalidResponse
    }
    AIUsageReporter.report(recorder, lab: .workPersonal, provider: selection.provider, modelID: selection.modelID, responseRoot: root, runID: runID)
    if let text = root["output_text"] as? String { return text }
    if let output = root["output"] as? [[String: Any]] {
      return output.compactMap { item -> String? in
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { $0["text"] as? String }.joined()
      }.joined()
    }
    throw WorkPersonalClassifierError.invalidResponse
  }

  static func parse(
    _ raw: String,
    provider: TextingVoiceProvider,
    modelID: String,
    now: Date = Date()
  ) throws -> [String: WorkPersonalMessageLabel] {
    let trimmed = extractJSONObject(raw)
    guard let data = trimmed.data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["labels"] as? [[String: Any]] else {
      throw WorkPersonalClassifierError.invalidResponse
    }
    var out: [String: WorkPersonalMessageLabel] = [:]
    for row in rows {
      guard let id = row["id"] as? String,
            let rawLabel = row["label"] as? String,
            let label = WorkPersonalLabel(rawValue: rawLabel),
            label != .unknown else { continue }
      out[id] = WorkPersonalMessageLabel(
        label: label,
        confidence: row["confidence"] as? Double,
        reason: row["reason"] as? String,
        provider: provider.rawValue,
        modelID: modelID,
        classifiedAt: WorkPersonalStore.iso(now)
      )
    }
    return out
  }

  /// People-level first-pass call: same providers, "people" response shape.
  static func classifyPeople(
    prompt: String,
    selection: LabModelSelection,
    recorder: (any AIUsageRecording)? = nil,
    runID: UUID? = nil
  ) async throws -> [WorkPersonalAIFirstPass.PersonDecision] {
    let raw: String
    switch selection.provider {
    case .anthropic: raw = try await anthropic(prompt: prompt, selection: selection, recorder: recorder, runID: runID)
    case .openAI: raw = try await openAI(prompt: prompt, selection: selection, recorder: recorder, runID: runID)
    }
    return try parsePeople(raw)
  }

  static func parsePeople(_ raw: String) throws -> [WorkPersonalAIFirstPass.PersonDecision] {
    let trimmed = extractJSONObject(raw)
    guard let data = trimmed.data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["people"] as? [[String: Any]] else {
      throw WorkPersonalClassifierError.invalidResponse
    }
    return rows.compactMap { row in
      guard let key = row["key"] as? String,
            let rawLabel = row["label"] as? String,
            let label = WorkPersonalLabel(rawValue: rawLabel) else { return nil }
      return WorkPersonalAIFirstPass.PersonDecision(
        personKey: key,
        label: label,
        confidence: (row["confidence"] as? Double) ?? 0,
        reason: row["reason"] as? String
      )
    }
  }

  private static func extractJSONObject(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
      return trimmed
    }
    return String(trimmed[start...end])
  }

  private static func errorMessage(data: Data, fallback: String) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
    if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    return fallback
  }
}

/// Lumon-style file codenames for refinement sessions (the Severance lab's
/// MDR terminal). Deterministic over the session's queue so the name is
/// stable across re-renders, and different queues usually get different
/// files. Pure logic — the terminal UI lives in WorkPersonalView.
enum LumonRefinementCodename {
  /// Show-flavored file names: places, deadpan and municipal.
  static let files = [
    "Allentown", "Cairns", "Cold Harbor", "Coleman", "Culpepper",
    "Dranesville", "Eminence", "Jesup", "Kingsport", "Labrador",
    "Le Mars", "Longbranch", "Minsk", "Moonbeam", "Nanning",
    "Ocula", "Pacoima", "Siena", "Sopchoppy", "Sunset Park",
    "Tan An", "Tumwater", "Waynesboro", "Wellington", "Yakima",
  ]

  /// Stable FNV-1a over the queue ids — Hashable.hashValue is seeded per
  /// process, which would rename the file every launch.
  static func codename(for ids: [String]) -> String {
    let digest = ids.reduce(into: UInt64(0xcbf29ce484222325)) { hash, id in
      for byte in id.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100000001b3
      }
      hash = (hash ^ 0x1f) &* 0x100000001b3
    }
    return files[Int(digest % UInt64(files.count))]
  }

  /// Mono hex readout for the terminal footer ("0x157EC6" style) — real
  /// identifiers, decoratively rendered.
  static func hexReadout(_ value: String) -> String {
    var hash: UInt32 = 0x811c9dc5
    for byte in value.utf8 {
      hash = (hash ^ UInt32(byte)) &* 0x01000193
    }
    return String(format: "0x%06X", hash & 0xFFFFFF)
  }

  /// Small deterministic mixer for the digit-field cells.
  static func mix(_ seed: Int, _ cell: Int) -> Int {
    var value = UInt64(bitPattern: Int64(seed)) &+ UInt64(bitPattern: Int64(cell)) &* 0x9E3779B97F4A7C15
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
    return Int((value ^ (value >> 31)) % UInt64(Int32.max))
  }
}
