import Foundation
import SwiftUI

// Backs the Labs › Keep Tabs pane. Spawns the bundled `birthday-generator`
// Mach-O (same FDA-inheriting sibling the Birthday tool uses) in two modes:
//   --keep-tabs-recommend  → who to ADD (ranked, business-filtered)
//   --keep-tabs-status     → live last-contacted for the WATCHED canons
// then reconciles the shared priority queue: overdue watched people get a P3
// "keep-tabs" priority; once they're contacted again (or un-watched, or
// auto-prioritize is off) the keep-tabs flag is cleared — never an agent/user
// one. One-shot process per action, no daemon.

// MARK: - decoded engine output

struct KeepTabsRecommendation: Decodable, Equatable, Identifiable {
  let name: String
  let bestHandle: String?
  let outCount: Int
  let callCount: Int
  let lastTextedDays: Int?
  let lastCallDays: Int?
  let suggestedFrequencyDays: Int
  let why: String

  // Two cards can share a handle; include the name so distinct people don't
  // collide in a ForEach (mirrors UpcomingBirthday.id).
  var id: String { "\(bestHandle ?? "")|\(name)" }
}

struct KeepTabsRecommendResult: Decodable, Equatable {
  let contactsAvailable: Bool
  let signalsAvailable: Bool
  let count: Int
  let recommendations: [KeepTabsRecommendation]
}

struct KeepTabsStatusRow: Decodable, Equatable {
  let canon: String
  let threadId: Int?
  let lastTextedDays: Int?
  let lastCallDays: Int?
}

struct KeepTabsStatusResult: Decodable, Equatable {
  let signalsAvailable: Bool
  let count: Int
  let statuses: [KeepTabsStatusRow]
}

struct KeepTabsCadenceRow: Decodable, Equatable {
  let canon: String
  let suggestedFrequencyDays: Int
  let lastContactedDays: Int?
}

struct KeepTabsCadenceResult: Decodable, Equatable {
  let signalsAvailable: Bool
  let count: Int
  let cadences: [KeepTabsCadenceRow]
}

/// Live overdue info for a watched person, surfaced to the view. Keeps the text
/// and call ages separately so the UI can say which channel the last touch was.
struct KeepTabsOverdueInfo: Equatable {
  let lastContactedDays: Int?
  let lastTextedDays: Int?
  let lastCallDays: Int?
  let isOverdue: Bool
}

/// How far past cadence a watched person is — drives the green/yellow/red status.
enum KeepTabsOverdueSeverity {
  case onTrack    // within cadence
  case overdue    // past cadence, up to 2× it
  case veryOverdue // well past (>2× cadence) or never contacted
}

/// Which channel the most recent touch was, and how long ago.
enum KeepTabsContactChannel: Equatable {
  case text(days: Int)
  case call(days: Int)
  case none
}

// MARK: - pure overdue + priority decisions (unit-tested without a process)

enum KeepTabsOverdue {
  /// Days since last contact of EITHER kind (text or call); nil = none recorded.
  /// Calls count as "credit," exactly the feature's intent.
  static func lastContactedDays(textDays: Int?, callDays: Int?) -> Int? {
    switch (textDays, callDays) {
    case (nil, nil): return nil
    case let (t?, nil): return t
    case let (nil, c?): return c
    case let (t?, c?): return min(t, c)
    }
  }

  /// Overdue when past the target cadence and not snoozed. A watched person with
  /// no recorded contact (nil) reads as overdue — they're as quiet as it gets.
  static func isOverdue(lastContactedDays: Int?, targetFrequencyDays: Int, snoozedUntil: Date?, now: Date) -> Bool {
    if let snoozedUntil, now < snoozedUntil { return false }
    guard let days = lastContactedDays else { return true }
    return days > targetFrequencyDays
  }

  /// Human "quiet N weeks/days" label for the priority reason + the overdue badge.
  static func quietLabel(lastContactedDays days: Int?) -> String {
    guard let days else { return "no recent contact" }
    if days >= 14 {
      let weeks = days / 7
      return "\(weeks) week\(weeks == 1 ? "" : "s")"
    }
    return "\(days) day\(days == 1 ? "" : "s")"
  }

  /// Green when within cadence; yellow when overdue up to 2× the cadence; red
  /// when well past it (>2×) or never contacted. Snooze is handled by the caller
  /// (a snoozed person reads as on-track until the snooze lapses).
  static func severity(lastContactedDays days: Int?, targetFrequencyDays target: Int) -> KeepTabsOverdueSeverity {
    guard let days else { return .veryOverdue } // no contact on record at all
    if days <= target { return .onTrack }
    if days <= target * 2 { return .overdue }
    return .veryOverdue
  }

  /// The most recent touch channel (text vs call) and its age, for the row's
  /// "Texted 3d ago" / "Called 2w ago" line. Ties go to text (the warmer signal).
  static func lastContactChannel(textDays: Int?, callDays: Int?) -> KeepTabsContactChannel {
    switch (textDays, callDays) {
    case (nil, nil): return .none
    case let (t?, nil): return .text(days: t)
    case let (nil, c?): return .call(days: c)
    case let (t?, c?): return t <= c ? .text(days: t) : .call(days: c)
    }
  }

  /// Terse relative age for the compact watchlist row: "today", "3d ago",
  /// "2w ago", "5mo ago", "2y ago".
  static func terseAgo(_ days: Int) -> String {
    if days <= 0 { return "today" }
    if days == 1 { return "yesterday" }
    if days < 14 { return "\(days)d ago" }
    if days < 60 { return "\(Int((Double(days) / 7).rounded()))w ago" }
    if days < 365 { return "\(Int((Double(days) / 30).rounded()))mo ago" }
    return "\(Int((Double(days) / 365).rounded()))y ago"
  }
}

enum KeepTabsPriorityDecision: Equatable {
  case set(reason: String)
  case clear
  case leave
}

enum KeepTabsPriority {
  /// Decide one thread's keep-tabs sync. `wantPrioritized` = this thread is
  /// watched, overdue, and auto-prioritize is on. Never clobbers an agent/user
  /// priority, and only clears entries it set itself. Idempotent: an unchanged
  /// keep-tabs entry returns `.leave` so we don't rewrite the file needlessly.
  static func decide(
    wantPrioritized: Bool,
    existing: ThreadPriorityEntry?,
    desiredReason: String,
    desiredLevel: ThreadPriorityLevel
  ) -> KeepTabsPriorityDecision {
    let isKeepTabs = existing?.setBy == ThreadPrioritySource.keepTabs
    if wantPrioritized {
      if existing == nil { return .set(reason: desiredReason) }
      if isKeepTabs {
        if existing?.level == desiredLevel.rawValue && existing?.reason == desiredReason { return .leave }
        return .set(reason: desiredReason)
      }
      return .leave // an agent or the user owns this thread's priority — don't touch it
    } else {
      return isKeepTabs ? .clear : .leave
    }
  }
}

// MARK: - controller

@MainActor
final class KeepTabsController: ObservableObject {
  enum RecommendState: Equatable {
    case idle
    case loading
    case loaded(KeepTabsRecommendResult)
    case failed(reason: String)
  }

  @Published private(set) var recommendState: RecommendState = .idle
  /// canon → live overdue info for each watched person (drives the watchlist UI).
  @Published private(set) var overdue: [String: KeepTabsOverdueInfo] = [:]
  /// Whether the last status scan could read chat.db (false = no Full Disk Access).
  @Published private(set) var signalsAvailable = true
  /// match.id → cadence row (suggested days + last-contacted) from that person's
  /// text+call history, loaded lazily when a search result is selected in
  /// manual-add so the picker can default to their real rhythm and the copy can
  /// be honest about a lapsed relationship.
  @Published private(set) var manualCadence: [String: KeepTabsCadenceRow] = [:]
  /// match.ids whose cadence is currently being computed (UI shows a brief hint).
  @Published private(set) var manualCadenceLoading: Set<String> = []

  private let store: KeepTabsStore
  private let priorities: ThreadPriorityStore
  private let binaryName = "birthday-generator"
  /// How many recommendations to request — a generous starting list (the view
  /// further filters out anyone already watched/dismissed).
  static let recommendationLimit = 40
  private var recommendLoaded = false
  private var loadGeneration = 0

  init(store: KeepTabsStore, priorities: ThreadPriorityStore) {
    self.store = store
    self.priorities = priorities
  }

  // MARK: - lifecycle

  func loadIfNeeded() {
    if !recommendLoaded { loadRecommendations() }
    recomputeOverdueAndSyncPriorities()
  }

  /// Force a fresh recommend scan AND overdue recompute (the Refresh button).
  func refresh() {
    loadRecommendations(force: true)
    recomputeOverdueAndSyncPriorities()
  }

  // MARK: - recommendations

  func loadRecommendations(force: Bool = false, silent: Bool = false) {
    if case .loading = recommendState { return }
    if !force, case .loaded = recommendState { return }
    guard let binURL = resolveBinary() else {
      recommendState = .failed(reason: "The recommendation engine isn't bundled in this build yet.")
      return
    }
    // Exclude both watched people and anyone permanently dismissed.
    let excluded = store.watchlist.map(\.canonicalKey) + Array(store.dismissedCanons)
    loadGeneration += 1
    let gen = loadGeneration
    // A silent refresh (after add/dismiss) keeps the current list on screen until
    // fresh results arrive — the section never flashes to a spinner.
    if !silent { recommendState = .loading }
    Task.detached(priority: .userInitiated) {
      let result = try? Self.runRecommend(binURL, excludeCanon: excluded, limit: Self.recommendationLimit)
      await MainActor.run {
        guard gen == self.loadGeneration else { return }
        self.recommendLoaded = true
        if let result {
          withAnimation(.easeInOut(duration: 0.22)) { self.recommendState = .loaded(result) }
        } else if !silent {
          self.recommendState = .failed(reason: "Couldn't read the recommendation engine's output.")
        }
      }
    }
  }

  // MARK: - watchlist mutations

  func add(recommendation rec: KeepTabsRecommendation, frequencyDays: Int) {
    guard let handle = rec.bestHandle, !handle.isEmpty else { return }
    try? store.add(name: rec.name, handle: handle, frequencyDays: frequencyDays)
    loadRecommendations(force: true, silent: true) // backfill a fresh row, no spinner flash
    recomputeOverdueAndSyncPriorities()
  }

  /// Permanently dismiss a recommendation so it's never suggested again.
  func dismissRecommendation(_ rec: KeepTabsRecommendation) {
    guard let handle = rec.bestHandle, let canon = KeepTabsStore.canon(for: handle) else { return }
    store.dismiss(canon: canon)
    loadRecommendations(force: true, silent: true) // backfill, no spinner flash
  }

  @discardableResult
  func add(match: ContactMatch, frequencyDays: Int) -> Bool {
    do {
      try store.add(match: match, frequencyDays: frequencyDays)
      loadRecommendations(force: true, silent: true)
      recomputeOverdueAndSyncPriorities()
      return true
    } catch {
      return false
    }
  }

  /// Compute the suggested cadence for a searched contact (manual-add), so the
  /// picker can default to their real text+call rhythm before they're added.
  /// Cached by match id; a no-op if already known or in flight. Best-effort — on
  /// any failure the picker just keeps its current default.
  func loadCadence(for match: ContactMatch) {
    let id = match.id
    guard manualCadence[id] == nil, !manualCadenceLoading.contains(id) else { return }
    guard let handle = match.bestHandle, let canon = KeepTabsStore.canon(for: handle),
          let binURL = resolveBinary() else { return }
    manualCadenceLoading.insert(id)
    Task.detached(priority: .userInitiated) {
      let row = try? Self.runCadence(binURL, canon: [canon]).cadences.first
      await MainActor.run {
        self.manualCadenceLoading.remove(id)
        if let row { self.manualCadence[id] = row }
      }
    }
  }

  func unwatch(_ entry: KeepTabsEntry) {
    store.remove(canon: entry.canonicalKey)
    // The reconcile pass clears the now-orphaned keep-tabs priority (the removed
    // thread is no longer "desired", so decide() returns .clear for it).
    recomputeOverdueAndSyncPriorities()
    loadRecommendations(force: true, silent: true) // a removed person can be recommended again
  }

  func setFrequency(_ entry: KeepTabsEntry, days: Int) {
    store.setFrequency(canon: entry.canonicalKey, days: days)
    recomputeOverdueAndSyncPriorities()
  }

  func snooze(_ entry: KeepTabsEntry, until: Date) {
    store.snooze(canon: entry.canonicalKey, until: until)
    recomputeOverdueAndSyncPriorities()
  }

  func clearSnooze(_ entry: KeepTabsEntry) {
    store.clearSnooze(canon: entry.canonicalKey)
    recomputeOverdueAndSyncPriorities()
  }

  func setAutoPrioritize(_ on: Bool) {
    store.setAutoPrioritize(on)
    // Flipping off should withdraw keep-tabs priorities; flipping on should add
    // them. The reconcile pass does both.
    recomputeOverdueAndSyncPriorities()
  }

  // MARK: - overdue + priority sync

  func recomputeOverdueAndSyncPriorities(now: Date = Date()) {
    let entries = store.watchlist
    guard !entries.isEmpty else {
      overdue = [:]
      // No one watched → withdraw any lingering keep-tabs priorities.
      reconcileKeepTabsPriorities(desired: [:])
      return
    }
    guard let binURL = resolveBinary() else { return }
    let canons = entries.map(\.canonicalKey)
    let autoPrioritize = store.autoPrioritize
    let entryByCanon = Dictionary(entries.map { ($0.canonicalKey, $0) }, uniquingKeysWith: { a, _ in a })
    Task.detached(priority: .utility) {
      let result = try? Self.runStatus(binURL, canon: canons)
      await MainActor.run {
        guard let result else { return }
        self.applyStatuses(
          result.statuses,
          entryByCanon: entryByCanon,
          autoPrioritize: autoPrioritize,
          signalsAvailable: result.signalsAvailable,
          now: now
        )
      }
    }
  }

  private func applyStatuses(
    _ statuses: [KeepTabsStatusRow],
    entryByCanon: [String: KeepTabsEntry],
    autoPrioritize: Bool,
    signalsAvailable: Bool,
    now: Date
  ) {
    self.signalsAvailable = signalsAvailable
    // Without Full Disk Access the status scan can't tell who's actually quiet —
    // everyone would look overdue. Surface the banner instead and don't drive the
    // queue off bad data.
    guard signalsAvailable else {
      overdue = [:]
      return
    }

    let statusByCanon = Dictionary(statuses.map { ($0.canon, $0) }, uniquingKeysWith: { a, _ in a })
    var overdueMap: [String: KeepTabsOverdueInfo] = [:]
    var desired: [Int: String] = [:] // iMessage chat ROWID → keep-tabs reason

    for (canon, entry) in entryByCanon {
      let status = statusByCanon[canon]
      let last = KeepTabsOverdue.lastContactedDays(textDays: status?.lastTextedDays, callDays: status?.lastCallDays)
      let snoozeDate = entry.snoozedUntil.flatMap(KeepTabsStore.parseISO)
      let overdueFlag = KeepTabsOverdue.isOverdue(
        lastContactedDays: last,
        targetFrequencyDays: entry.targetFrequencyDays,
        snoozedUntil: snoozeDate,
        now: now
      )
      overdueMap[canon] = KeepTabsOverdueInfo(
        lastContactedDays: last,
        lastTextedDays: status?.lastTextedDays,
        lastCallDays: status?.lastCallDays,
        isOverdue: overdueFlag
      )

      // Only iMessage threads can be priority-queued (the queue keys on the chat
      // ROWID). A call-only contact has no thread — they still show as overdue in
      // our own surface, just not in the Messages priority section.
      if autoPrioritize, overdueFlag, entry.transport == .imessage, let threadID = status?.threadId {
        desired[threadID] = "Orbit: quiet \(KeepTabsOverdue.quietLabel(lastContactedDays: last))"
      }
    }

    reconcileKeepTabsPriorities(desired: desired)
    overdue = overdueMap
  }

  /// Bring the shared priority queue's keep-tabs entries in line with `desired`
  /// (iMessage chat ROWID → reason). Sets/refreshes desired threads, clears
  /// keep-tabs threads that are no longer desired, and never touches an
  /// agent/user priority. Idempotent. Internal (not private) so the integration
  /// test can drive it without spawning the binary.
  func reconcileKeepTabsPriorities(desired: [Int: String]) {
    var keys = Set<Int>()
    for (key, entry) in priorities.imessage where entry.setBy == ThreadPrioritySource.keepTabs {
      if let tid = Int(key) { keys.insert(tid) }
    }
    for tid in desired.keys { keys.insert(tid) }

    for tid in keys {
      let existing = priorities.priority(platform: .imessage, threadID: tid, handle: "")
      let reason = desired[tid] ?? ""
      let decision = KeepTabsPriority.decide(
        wantPrioritized: desired[tid] != nil,
        existing: existing,
        desiredReason: reason,
        desiredLevel: .elevated
      )
      switch decision {
      case .set(let r):
        priorities.setPriority(.elevated, platform: .imessage, threadID: tid, handle: "", reason: r, setBy: ThreadPrioritySource.keepTabs)
      case .clear:
        priorities.clearPriority(platform: .imessage, threadID: tid, handle: "")
      case .leave:
        break
      }
    }
  }

  // MARK: - process orchestration (mirrors BirthdayGeneratorController)

  private struct GenError: Error { let message: String }

  nonisolated private static func runRecommend(_ binURL: URL, excludeCanon: [String], limit: Int) throws -> KeepTabsRecommendResult {
    var args = ["--keep-tabs-recommend", "--limit", String(limit)]
    if !excludeCanon.isEmpty { args += ["--exclude-canon", excludeCanon.joined(separator: ",")] }
    let (status, out, err) = try capture(binURL, args)
    guard status == 0 else { throw GenError(message: "keep-tabs recommend exited \(status). \(err)") }
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(KeepTabsRecommendResult.self, from: out)
  }

  nonisolated private static func runStatus(_ binURL: URL, canon: [String]) throws -> KeepTabsStatusResult {
    let args = ["--keep-tabs-status", "--canon", canon.joined(separator: ",")]
    let (status, out, err) = try capture(binURL, args)
    guard status == 0 else { throw GenError(message: "keep-tabs status exited \(status). \(err)") }
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(KeepTabsStatusResult.self, from: out)
  }

  nonisolated private static func runCadence(_ binURL: URL, canon: [String]) throws -> KeepTabsCadenceResult {
    let args = ["--keep-tabs-cadence", "--canon", canon.joined(separator: ",")]
    let (status, out, err) = try capture(binURL, args)
    guard status == 0 else { throw GenError(message: "keep-tabs cadence exited \(status). \(err)") }
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(KeepTabsCadenceResult.self, from: out)
  }

  /// Run the binary, capturing (exitStatus, stdout, stderr). Reads stdout to EOF
  /// before waiting so a large JSON payload can't deadlock the pipe.
  nonisolated private static func capture(_ binURL: URL, _ args: [String]) throws -> (Int32, Data, String) {
    let proc = Process()
    proc.executableURL = binURL
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
      try proc.run()
    } catch {
      throw GenError(message: "Couldn't start the recommendation engine: \(error.localizedDescription)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let err = String(data: errData, encoding: .utf8) ?? ""
    return (proc.terminationStatus, outData, err)
  }

  private func resolveBinary() -> URL? {
    let bundle = Bundle.main.bundleURL
    let inBundle = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
    let sibling = bundle.deletingLastPathComponent().appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
    return nil
  }
}
