import Foundation
import AppKit
import SwiftUI

// Spawns the bundled `birthday-generator` Mach-O (a sibling inner binary signed
// with the same identifier, so it inherits Full Disk Access via launcher
// attribution like the daemons + the Wrapped engine). The binary surfaces
// upcoming birthdays + suggestion signals (--list), stages a happy-birthday
// draft (--stage), and persists pin/mute curation (--pin/--mute). One-shot
// process per action — no daemon/socket.
//
// This controller backs the Labs › Birthday Texts pane.

/// One upcoming birthday row, decoded from the binary's --list JSON.
struct UpcomingBirthday: Decodable, Equatable, Identifiable {
  let name: String
  let birthday: String
  let nextOccurrence: String
  let daysUntil: Int
  let weekday: String
  let ageTurning: Int?
  let relationship: String?
  let notes: String?
  let bestHandle: String?
  let handles: [String]
  let source: String
  let pinned: Bool
  let muted: Bool
  let outCount: Int
  let textRank: Int?
  let callCount: Int
  let callRank: Int?
  // Recency (last_texted/last_call days) is no longer emitted by the engine — it
  // was only ever the per-row badge (removed) and could be served TTL-stale to
  // the Claude handoff. Claude reads the real threads for recency itself.
  let wishedBefore: Bool
  let wishedYears: [Int]
  let suggested: Bool
  let reasons: [String]
  let suggestedMessage: String

  // Stable identity for ForEach. Always include the name: two different
  // contacts can share a handle (e.g. a family landline as the only number on
  // both cards), and a bare-handle id would collide — cross-contaminating the
  // busy/staged sets that are keyed by id (review S11).
  var id: String { "\(bestHandle ?? "")|\(name)|\(birthday)" }

  func withCuration(pinned newPinned: Bool? = nil, muted newMuted: Bool? = nil) -> UpcomingBirthday {
    UpcomingBirthday(
      name: name,
      birthday: birthday,
      nextOccurrence: nextOccurrence,
      daysUntil: daysUntil,
      weekday: weekday,
      ageTurning: ageTurning,
      relationship: relationship,
      notes: notes,
      bestHandle: bestHandle,
      handles: handles,
      source: source,
      pinned: newPinned ?? pinned,
      muted: newMuted ?? muted,
      outCount: outCount,
      textRank: textRank,
      callCount: callCount,
      callRank: callRank,
      wishedBefore: wishedBefore,
      wishedYears: wishedYears,
      suggested: suggested,
      reasons: reasons,
      suggestedMessage: suggestedMessage
    )
  }
}

struct BirthdayListResult: Decodable, Equatable {
  let today: String
  let windowDays: Int
  let topN: Int
  let signalsAvailable: Bool
  let count: Int
  let upcoming: [UpcomingBirthday]
}

/// A high-affinity contact with no birthday on file (the "gaps" — people you
/// clearly care about but haven't saved a birthday for).
struct GapContact: Decodable, Equatable, Identifiable {
  let name: String
  let bestHandle: String?
  let outCount: Int
  let callCount: Int
  let reasons: [String]
  var id: String { "\(bestHandle ?? "")|\(name)" }
}

struct GapsResult: Decodable, Equatable {
  let contactsAvailable: Bool
  let count: Int
  let gaps: [GapContact]
}

/// Back-compat name for the historical strict "MM-DD"/"YYYY-MM-DD" entry
/// point, now backed by BirthdayDateParser — every call site (the controller
/// guard, the manual-add rows) accepts the human formats for free.
enum BirthdayDateInput {
  static func normalized(_ raw: String) -> String? {
    BirthdayDateParser.parse(raw)?.normalized
  }
}

/// One contact from the engine's `--seed` output: "who you're in regular contact
/// with" (incl. people with NO saved birthday), with a birthday inferred from a
/// past wish date where possible. Handed to the LLM (the Build action) to source
/// the rest + ask the user about gaps. Metadata only — no message bodies.
struct SeedContact: Decodable, Equatable {
  let name: String
  let bestHandle: String?
  let savedBirthday: String?
  let inferredBirthday: String?
  let outCount: Int
  let callCount: Int
  let lastTextedDays: Int?
  let lastCallDays: Int?
  let reason: String
}

struct SeedResult: Decodable, Equatable {
  let contactsAvailable: Bool
  let signalsAvailable: Bool
  let count: Int
  let contacts: [SeedContact]
}

/// Outcome of a bulk `--import` (the app's paste/file Import of the LLM-built
/// list). Counts only — the engine validates each row and SKIPS bad ones rather
/// than aborting, so a single malformed entry can't lose the rest of the import.
struct ImportResult: Decodable, Equatable {
  let created: Int
  let updated: Int
  let skipped: Int
}

@MainActor
final class BirthdayGeneratorController: ObservableObject {
  enum State: Equatable {
    case idle
    case loading
    case loaded(BirthdayListResult)
    // No fdaMissing case: --list never fails on missing Full Disk Access — the
    // binary degrades gracefully (signals_available:false) and the view surfaces
    // an actionable FDA banner. This .failed is for genuine failures (binary not
    // bundled, decode error, bad args). (review N1)
    case failed(reason: String)
  }

  @Published private(set) var state: State = .idle
  /// Row ids with an in-flight action (stage/pin/mute) — drives per-row spinners.
  @Published private(set) var busy: Set<String> = []
  /// Row ids successfully staged this session — drives the "Staged ✓" confirmation.
  @Published private(set) var staged: Set<String> = []
  /// High-affinity contacts with no birthday on file (the gaps).
  @Published private(set) var gaps: [GapContact] = []

  private let binaryName = "birthday-generator"
  private var currentWindowDays = 30
  private var gapsLoaded = false
  // Monotonic load token: detached loads can finish out of order (rapidly
  // toggling the window picker or list/calendar), so only the newest load is
  // allowed to publish — a slower earlier one is dropped (review: Codex finding).
  private var loadGeneration = 0

  // MARK: - actions

  /// Load the list + gaps only if not already done for this window. The
  /// controller is owned app-level (AppDelegate) and survives tab switches, so
  /// the Birthday view calls this on every `.onAppear` without re-spawning the
  /// binary — the spinner-on-every-reopen this replaces came from the view
  /// owning the controller as a per-view @StateObject (recreated each switch).
  func loadIfNeeded(windowDays: Int) {
    switch state {
    case .loaded(let r) where r.windowDays == windowDays: break // already fresh
    case .loading: break
    default: load(windowDays: windowDays)
    }
    if !gapsLoaded { loadGaps() }
  }

  func load(windowDays: Int, refreshSignals: Bool = false) {
    currentWindowDays = windowDays
    // Reset transient per-row state so a stale "Staged ✓" can't persist across a
    // reload (e.g. after the user discarded the draft) — review S12.
    staged.removeAll()
    busy.removeAll()
    guard let binURL = resolveBinary() else {
      state = .failed(reason: "The birthday engine isn't bundled in this build yet.")
      return
    }
    loadGeneration += 1
    let gen = loadGeneration
    state = .loading
    let startedAt = Date()
    AnalyticsClient.shared.safeCapture(.labScanStarted, properties: [
      .lab: .string(AnalyticsLab.birthdayTexts.rawValue)
    ])
    Task.detached(priority: .userInitiated) {
      do {
        let result = try Self.runList(binURL, windowDays: windowDays, refreshSignals: refreshSignals)
        await MainActor.run {
          if gen == self.loadGeneration {
            self.state = .loaded(result)
            AnalyticsClient.shared.safeCapture(.labScanCompleted, properties: [
              .lab: .string(AnalyticsLab.birthdayTexts.rawValue),
              .resultCountBucket: .string(AnalyticsClient.resultCountBucket(result.count)),
              .durationBucket: .string(AnalyticsClient.durationBucket(ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
            ])
          }
        }
      } catch let e as GenError {
        await MainActor.run {
          if gen == self.loadGeneration {
            self.state = .failed(reason: e.message)
            AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
              .lab: .string(AnalyticsLab.birthdayTexts.rawValue),
              .errorCategory: .string(AnalyticsErrorCategory.unknown.rawValue)
            ])
          }
        }
      } catch {
        await MainActor.run {
          if gen == self.loadGeneration {
            self.state = .failed(reason: error.localizedDescription)
            AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
              .lab: .string(AnalyticsLab.birthdayTexts.rawValue),
              .errorCategory: .string(AnalyticsClient.errorCategory(error).rawValue)
            ])
          }
        }
      }
    }
  }

  func reload() { load(windowDays: currentWindowDays) }

  /// The Refresh button: reload AND force a recompute of the starting-point
  /// signals (the on-device chat.db scan). Normal loads serve the long-TTL cache
  /// so the list is instant; this is the explicit "recompute now" escape hatch.
  func refresh() { load(windowDays: currentWindowDays, refreshSignals: true) }

  /// Load the gaps list (high-affinity contacts with no birthday). Best-effort —
  /// silently leaves gaps empty on failure (it's a secondary surface).
  func loadGaps() {
    guard let binURL = resolveBinary() else { return }
    Task.detached(priority: .utility) {
      let result = try? Self.runGaps(binURL)
      await MainActor.run {
        self.gaps = result?.gaps ?? []
        self.gapsLoaded = true
      }
    }
  }

  /// Add a person + birthday to the list and pin them ("On your list"), then
  /// refresh. The core path behind both the Contacts search ("add a birthday")
  /// and the gaps backfill. `busyId` drives the right row's spinner (a ContactMatch
  /// id or a GapContact id). Pins via `--pin` so the new person lands on the list.
  func addPerson(name: String, handle: String?, birthday: String, busyId: String) {
    guard let birthday = BirthdayDateInput.normalized(birthday) else { return }
    guard let binURL = resolveBinary() else { return }
    busy.insert(busyId)
    Task.detached(priority: .userInitiated) {
      _ = try? Self.runCuration(binURL, flag: "--pin", handle: handle, name: name, birthday: birthday)
      await MainActor.run {
        self.busy.remove(busyId)
        self.reload()
        self.loadGaps()
      }
    }
  }

  /// Backfill a confirmed birthday for a gap contact (the net-new signal).
  func addBirthday(gap: GapContact, birthday: String) {
    addPerson(name: gap.name, handle: gap.bestHandle, birthday: birthday, busyId: gap.id)
  }

  /// Add a birthday for a contact found via the Contacts search.
  func addMatch(_ match: ContactMatch, birthday: String) {
    addPerson(name: match.name, handle: match.bestHandle, birthday: birthday, busyId: match.id)
  }

  /// Absolute path to the generated upcoming-birthday list file handed to
  /// Claude/Codex by the "Plan my outreach" action. Lives alongside the other
  /// ~/.messages-mcp state. Metadata-only (the binary's --list output).
  static var listFilePath: String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".messages-mcp/birthday-list.json")
  }

  /// Write the current upcoming list to `listFilePath` via the binary's
  /// `--list --out`, off the main thread, then call `completion` on the main actor
  /// with the path (nil on failure). Called right before the "Plan my outreach"
  /// handoff so Claude reads the freshest list. Serves the cached signals (no
  /// rescan) — it's fast.
  func writeListFile(windowDays: Int, completion: @escaping (String?) -> Void) {
    guard let binURL = resolveBinary() else { completion(nil); return }
    let path = Self.listFilePath
    Task.detached(priority: .userInitiated) {
      let ok = (try? Self.runListToFile(binURL, windowDays: windowDays, outPath: path)) ?? false
      await MainActor.run { completion(ok ? path : nil) }
    }
  }

  // MARK: - import (paste / file → birthdays.json)

  /// Import the LLM-built finalized list (the Import paste field or file picker).
  /// Writes the JSON text to a 0600 temp file and runs the engine's `--import`,
  /// which validates each row, skips bad ones, and bulk-upserts into birthdays.json
  /// in one atomic rewrite (the same primitive the birthday-reminder skill uses).
  /// Reloads the list on success. The result (created / updated / skipped, or a
  /// user-facing error message) comes back via `completion` on the main actor.
  /// `completion(result, errorMessage)`: exactly one is non-nil — the parsed counts
  /// on success, or a user-facing error message on failure.
  func importList(json: String, completion: @escaping (ImportResult?, String?) -> Void) {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      completion(nil, "Nothing to import. Paste a list or choose a file first.")
      return
    }
    guard let binURL = resolveBinary() else {
      completion(nil, "The birthday engine isn't bundled in this build yet.")
      return
    }
    Task.detached(priority: .userInitiated) {
      var imported: ImportResult?
      var errorMessage: String?
      do {
        let tmp = try Self.writeTempJSON(json)
        defer { try? FileManager.default.removeItem(at: tmp) }
        imported = try Self.runImport(binURL, inPath: tmp.path)
      } catch let e as GenError {
        errorMessage = e.message
      } catch {
        errorMessage = error.localizedDescription
      }
      await MainActor.run {
        // A successful import rewrote birthdays.json — reflect it (and re-check
        // gaps, since an imported birthday closes a gap).
        if imported != nil { self.reload(); self.loadGaps() }
        completion(imported, errorMessage)
      }
    }
  }

  // MARK: - build (seed → LLM handoff)

  /// Where the metadata seed ("who you're in regular contact with") is written for
  /// the Build handoff — alongside the other ~/.messages-mcp state at 0600 (the
  /// engine's own --out write: symlink-refusing, atomic). It's a bonus for
  /// non-sandboxed assistants (Claude Code / Codex) that can read local files;
  /// Cowork's sandbox can't, so the Build prompt also inlines a capped roster.
  static var seedFilePath: String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".messages-mcp/birthday-seed.json")
  }

  /// Run the engine `--seed --out` (the full chat.db scan), then read the written
  /// file back to decode it. Returns (the seed file path or nil if the run failed,
  /// the decoded contacts, signalsAvailable) on the main actor — the view inlines
  /// the roster AND points at the file in the Build prompt, and uses
  /// signalsAvailable to distinguish "no Full Disk Access" (empty + false) from
  /// "FDA present but no recent contacts" (empty + true). The scan is the expensive
  /// part, so callers show a spinner while it runs.
  func buildSeed(completion: @escaping (_ seedPath: String?, _ contacts: [SeedContact], _ signalsAvailable: Bool) -> Void) {
    guard let binURL = resolveBinary() else { completion(nil, [], false); return }
    let path = Self.seedFilePath
    Task.detached(priority: .userInitiated) {
      let result = (try? Self.runSeedToFile(binURL, outPath: path)) ?? nil
      await MainActor.run {
        if let result { completion(path, result.contacts, result.signalsAvailable) }
        else { completion(nil, [], false) }
      }
    }
  }

  /// Stage a birthday draft. It lands in ~/.messages-mcp/drafts and surfaces in
  /// the Drafts pane within ~100ms (DraftStore watcher); never auto-sends.
  func stage(row: UpcomingBirthday, message: String) {
    guard let handle = row.bestHandle, !handle.isEmpty else { return }
    guard let binURL = resolveBinary() else { return }
    let id = row.id
    busy.insert(id)
    Task.detached(priority: .userInitiated) {
      let ok = (try? Self.runStage(binURL, handle: handle, name: row.name, message: message)) ?? false
      await MainActor.run {
        self.busy.remove(id)
        if ok { self.staged.insert(id) }
      }
    }
  }

  /// Schedule a birthday draft (approve-now/send-later): stages it with a
  /// scheduled_send_at; the ScheduledSendController fires it at that instant.
  func schedule(row: UpcomingBirthday, message: String, scheduledAtISO: String) {
    guard let handle = row.bestHandle, !handle.isEmpty else { return }
    guard let binURL = resolveBinary() else { return }
    let id = row.id
    busy.insert(id)
    Task.detached(priority: .userInitiated) {
      let ok = (try? Self.runStage(binURL, handle: handle, name: row.name, message: message, scheduledAtISO: scheduledAtISO)) ?? false
      await MainActor.run {
        self.busy.remove(id)
        if ok { self.staged.insert(id) }
      }
    }
  }

  func setPinned(row: UpcomingBirthday, _ pinned: Bool) {
    curate(row: row, flag: pinned ? "--pin" : "--unpin")
  }

  func setMuted(row: UpcomingBirthday, _ muted: Bool) {
    curate(row: row, flag: muted ? "--mute" : "--unmute")
  }

  private func curate(row: UpcomingBirthday, flag: String) {
    // Pin/mute must work even for a handle-less contact (name + birthday only) —
    // the binary matches by name when no handle is given (review S8).
    guard let binURL = resolveBinary() else { return }
    let id = row.id
    busy.insert(id)
    Task.detached(priority: .userInitiated) {
      let ok = (try? Self.runCuration(binURL, flag: flag, handle: row.bestHandle, name: row.name, birthday: row.birthday)) ?? false
      await MainActor.run {
        self.busy.remove(id)
        if ok {
          self.applyCuration(rowID: id, flag: flag)
        }
      }
    }
  }

  private func applyCuration(rowID: String, flag: String) {
    guard case .loaded(let result) = state else { return }
    let updated = result.upcoming.map { row in
      guard row.id == rowID else { return row }
      switch flag {
      case "--pin": return row.withCuration(pinned: true)
      case "--unpin": return row.withCuration(pinned: false)
      case "--mute": return row.withCuration(muted: true)
      case "--unmute": return row.withCuration(muted: false)
      default: return row
      }
    }
    withAnimation(.easeInOut(duration: 0.16)) {
      state = .loaded(BirthdayListResult(
        today: result.today,
        windowDays: result.windowDays,
        topN: result.topN,
        signalsAvailable: result.signalsAvailable,
        count: result.count,
        upcoming: updated
      ))
    }
  }

  // MARK: - process orchestration

  private struct GenError: Error { let message: String }

  nonisolated private static func runList(_ binURL: URL, windowDays: Int, refreshSignals: Bool) throws -> BirthdayListResult {
    var args = ["--list", "--window-days", String(windowDays)]
    if refreshSignals { args.append("--refresh-signals") }
    let (status, out, err) = try capture(binURL, args)
    guard status == 0 else {
      throw GenError(message: "The birthday engine exited with an error (code \(status)). \(err)")
    }
    do {
      let dec = JSONDecoder()
      dec.keyDecodingStrategy = .convertFromSnakeCase
      return try dec.decode(BirthdayListResult.self, from: out)
    } catch {
      throw GenError(message: "Couldn't read the birthday engine's output: \(error.localizedDescription)")
    }
  }

  nonisolated private static func runGaps(_ binURL: URL) throws -> GapsResult {
    let (status, out, _) = try capture(binURL, ["--gaps"])
    guard status == 0 else { throw GenError(message: "gaps exited \(status)") }
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(GapsResult.self, from: out)
  }

  /// Write the upcoming list to `outPath` (the binary's `--list --out`). Returns
  /// true on a clean exit. Backs the "Plan my outreach" file-pointer handoff.
  nonisolated private static func runListToFile(_ binURL: URL, windowDays: Int, outPath: String) throws -> Bool {
    let (status, _, _) = try capture(binURL, ["--list", "--window-days", String(windowDays), "--out", outPath])
    return status == 0
  }

  /// Bulk-import a finalized list via `--import --in <file>`. Returns the engine's
  /// {created, updated, skipped} on a clean exit; throws a user-facing GenError
  /// otherwise (the engine writes the reason to stderr and exits non-zero on
  /// unreadable/invalid/non-array JSON).
  nonisolated private static func runImport(_ binURL: URL, inPath: String) throws -> ImportResult {
    let (status, out, err) = try capture(binURL, ["--import", "--in", inPath])
    guard status == 0 else { throw GenError(message: importErrorMessage(from: err, status: status)) }
    do {
      let dec = JSONDecoder()
      dec.keyDecodingStrategy = .convertFromSnakeCase
      return try dec.decode(ImportResult.self, from: out)
    } catch {
      throw GenError(message: "Couldn't read the import result: \(error.localizedDescription)")
    }
  }

  /// Translate the engine's stderr (first line) into a user-facing import error.
  /// The engine prefixes its import failures with "--import:" — strip that so the
  /// message reads plainly (e.g. "<file> is not valid JSON …"). nonisolated +
  /// internal so it's callable from the nonisolated `runImport` and unit-testable
  /// without spawning a process.
  nonisolated static func importErrorMessage(from stderr: String, status: Int32) -> String {
    let first = stderr.split(separator: "\n").first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    guard !first.isEmpty else { return "The import failed (code \(status))." }
    return first.replacingOccurrences(of: "--import: ", with: "")
  }

  /// Run `--seed --out <path>` (the engine writes the file at 0600, symlink-safe),
  /// then read it back and decode the contacts. Returns nil if the run failed
  /// (e.g. no Full Disk Access → the engine reports signals_available:false but
  /// still exits 0 with an empty/partial seed; a non-zero exit or unreadable file
  /// is the failure case).
  nonisolated private static func runSeedToFile(_ binURL: URL, outPath: String) throws -> SeedResult? {
    let (status, _, _) = try capture(binURL, ["--seed", "--out", outPath])
    guard status == 0 else { return nil }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: outPath)) else { return nil }
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try? dec.decode(SeedResult.self, from: data)
  }

  /// Write the pasted/loaded import JSON to a private (0600) temp file the engine
  /// reads via `--import --in`. tmp lives in the per-user temp dir; the caller
  /// removes it after the import.
  nonisolated private static func writeTempJSON(_ json: String) throws -> URL {
    guard let data = json.data(using: .utf8) else {
      throw GenError(message: "Couldn't encode the pasted text.")
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bday-import-\(UUID().uuidString).json")
    try data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  nonisolated private static func runStage(
    _ binURL: URL, handle: String, name: String, message: String, scheduledAtISO: String? = nil
  ) throws -> Bool {
    var args = ["--stage", "--handle", handle, "--name", name, "--message", message]
    if let scheduledAtISO {
      // The GUI Schedule click IS the approval — pass --approved so the
      // scheduler will auto-fire it (a bare CLI stage stays unapproved/held).
      args += ["--scheduled-at", scheduledAtISO, "--approved"]
    }
    let (status, _, _) = try capture(binURL, args)
    return status == 0
  }

  nonisolated private static func runCuration(_ binURL: URL, flag: String, handle: String?, name: String, birthday: String) throws -> Bool {
    var args = [flag, "--name", name, "--birthday", birthday]
    if let handle, !handle.isEmpty { args += ["--handle", handle] }
    let (status, _, _) = try capture(binURL, args)
    return status == 0
  }

  /// Run the binary, capturing (exitStatus, stdout, stderr). Reads stdout to EOF
  /// before waiting so a large list JSON can't deadlock the pipe.
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
      throw GenError(message: "Couldn't start the birthday engine: \(error.localizedDescription)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let err = String(data: errData, encoding: .utf8) ?? ""
    return (proc.terminationStatus, outData, err)
  }

  // MARK: - binary resolution (mirrors WrappedGeneratorController)

  private func resolveBinary() -> URL? {
    let bundle = Bundle.main.bundleURL
    let inBundle = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
    let sibling = bundle.deletingLastPathComponent().appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
    return nil
  }
}
