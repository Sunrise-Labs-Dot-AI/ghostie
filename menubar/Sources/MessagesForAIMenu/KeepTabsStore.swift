import Foundation

/// The Keep Tabs watchlist: people the user wants to stay in touch with, each
/// with a target contact cadence. When a watched person goes quiet past their
/// cadence (KeepTabsController checks texts AND calls), their thread is pushed
/// into the shared priority queue. This store owns `~/.messages-mcp/keep-tabs.json`
/// — the menu bar is the single writer; the MCP doesn't touch it in v1.
///
/// Keyed by the canonical handle (phone last-10 / lowercased email) — the same
/// stable ref the TS engine's canonHandle produces — so a person is watched once
/// regardless of how their number is formatted.

/// Target contact-cadence presets. The stored value is always a day count
/// (`targetFrequencyDays`); these are the named buckets the UI offers, plus a
/// free custom value.
enum KeepTabsFrequency: Int, CaseIterable, Identifiable {
  case fewDays = 3
  case weekly = 7
  case biweekly = 14
  case monthly = 30
  case quarterly = 90
  case semiannual = 180
  case yearly = 365

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .fewDays: return "Every few days"
    case .weekly: return "Weekly"
    case .biweekly: return "Biweekly"
    case .monthly: return "Monthly"
    case .quarterly: return "Quarterly"
    case .semiannual: return "Every 6 months"
    case .yearly: return "Yearly"
    }
  }

  /// Terse label for the compact cadence chip (e.g. the watchlist row).
  var shortTitle: String {
    switch self {
    case .fewDays: return "3d"
    case .weekly: return "1w"
    case .biweekly: return "2w"
    case .monthly: return "1mo"
    case .quarterly: return "3mo"
    case .semiannual: return "6mo"
    case .yearly: return "1y"
    }
  }

  /// The preset matching an exact day count, or nil for a custom cadence.
  static func preset(forDays days: Int) -> KeepTabsFrequency? {
    KeepTabsFrequency(rawValue: days)
  }

  /// The preset closest to an arbitrary day count — used to seed the dropdown
  /// from the engine's median-cadence suggestion (e.g. a 9-day median → Weekly).
  static func nearest(toDays days: Int) -> KeepTabsFrequency {
    allCases.min(by: { abs($0.rawValue - days) < abs($1.rawValue - days) }) ?? .weekly
  }
}

/// One watched person. `transport` is `.imessage` in v1 (the recommend/status
/// engine reads chat.db + CallHistory only); the field exists so a future
/// WhatsApp pass can route correctly. `snoozedUntil` suppresses overdue until
/// that instant.
struct KeepTabsEntry: Codable, Equatable, Identifiable {
  var id: String { canonicalKey }
  var canonicalKey: String
  var handle: String
  var displayName: String
  var transport: Platform
  var targetFrequencyDays: Int
  var addedAt: String
  var snoozedUntil: String?

  enum CodingKeys: String, CodingKey {
    case canonicalKey = "canon_handle"
    case handle
    case displayName = "display_name"
    case transport
    case targetFrequencyDays = "target_frequency_days"
    case addedAt = "added_at"
    case snoozedUntil = "snoozed_until"
  }

  // Tolerant decode: a future field addition (or a hand-edit) shouldn't drop the
  // whole entry. `transport` defaults to iMessage; frequency is clamped.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    canonicalKey = try c.decode(String.self, forKey: .canonicalKey)
    handle = try c.decode(String.self, forKey: .handle)
    displayName = (try? c.decode(String.self, forKey: .displayName)) ?? handle
    transport = (try? c.decode(Platform.self, forKey: .transport)) ?? .imessage
    targetFrequencyDays = KeepTabsStore.clampFrequency((try? c.decode(Int.self, forKey: .targetFrequencyDays)) ?? KeepTabsFrequency.weekly.rawValue)
    addedAt = (try? c.decode(String.self, forKey: .addedAt)) ?? ""
    snoozedUntil = try? c.decodeIfPresent(String.self, forKey: .snoozedUntil)
  }

  init(
    canonicalKey: String,
    handle: String,
    displayName: String,
    transport: Platform,
    targetFrequencyDays: Int,
    addedAt: String,
    snoozedUntil: String? = nil
  ) {
    self.canonicalKey = canonicalKey
    self.handle = handle
    self.displayName = displayName
    self.transport = transport
    self.targetFrequencyDays = targetFrequencyDays
    self.addedAt = addedAt
    self.snoozedUntil = snoozedUntil
  }
}

struct KeepTabsDatabase: Codable, Equatable {
  var schemaVersion: Int
  /// When true, overdue watched people are written into the shared priority
  /// queue. When false, Keep Tabs still shows who's overdue in its own surface
  /// but never touches the queue (and clears any keep-tabs flags it had set).
  var autoPrioritize: Bool
  var watchlist: [String: KeepTabsEntry]
  /// Canon handles the user dismissed from the recommendation list — kept out of
  /// recommendations in perpetuity (canon → ISO dismissed-at). Adding someone to
  /// the watchlist later still works; this only suppresses re-recommending them.
  var dismissed: [String: String]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case autoPrioritize = "auto_prioritize"
    case watchlist
    case dismissed
  }

  init(schemaVersion: Int = KeepTabsStore.schemaVersion, autoPrioritize: Bool = true, watchlist: [String: KeepTabsEntry] = [:], dismissed: [String: String] = [:]) {
    self.schemaVersion = schemaVersion
    self.autoPrioritize = autoPrioritize
    self.watchlist = watchlist
    self.dismissed = dismissed
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? KeepTabsStore.schemaVersion
    autoPrioritize = (try? c.decode(Bool.self, forKey: .autoPrioritize)) ?? true
    watchlist = (try? c.decode([String: KeepTabsEntry].self, forKey: .watchlist)) ?? [:]
    dismissed = (try? c.decode([String: String].self, forKey: .dismissed)) ?? [:]
  }
}

enum KeepTabsStoreError: Error, CustomStringConvertible, Equatable {
  case missingHandle
  case invalidHandle
  case duplicateContact
  case notFound

  var description: String {
    switch self {
    case .missingHandle: return "Choose a contact with a phone number or email."
    case .invalidHandle: return "That contact handle can't be used for Messages."
    case .duplicateContact: return "That person is already in Orbit."
    case .notFound: return "That person isn't in Orbit."
    }
  }
}

@MainActor
final class KeepTabsStore: ObservableObject {
  static let schemaVersion = 1
  static let minFrequencyDays = 1
  static let maxFrequencyDays = 365

  @Published private(set) var database = KeepTabsDatabase()
  @Published private(set) var lastError: String?

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("keep-tabs.json")
    load()
  }

  // MARK: - reads

  var autoPrioritize: Bool { database.autoPrioritize }

  /// The watchlist, ordered by display name (case-insensitive).
  var watchlist: [KeepTabsEntry] {
    database.watchlist.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  var isEmpty: Bool { database.watchlist.isEmpty }

  func isWatched(canon: String) -> Bool { database.watchlist[canon] != nil }

  /// Canon handles permanently dismissed from recommendations.
  var dismissedCanons: Set<String> { Set(database.dismissed.keys) }
  func isDismissed(canon: String) -> Bool { database.dismissed[canon] != nil }

  /// Canonical key for a handle, when one can be derived. Surfaced so the view
  /// can pre-check whether a recommendation/contact is already watched.
  static func canon(for handle: String) -> String? {
    ContactAvatarStore.canonicalKey(handle)
  }

  // MARK: - mutations

  @discardableResult
  func add(
    name: String,
    handle: String,
    transport: Platform = .imessage,
    frequencyDays: Int,
    now: Date = Date()
  ) throws -> KeepTabsEntry {
    let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedHandle.isEmpty else { throw KeepTabsStoreError.missingHandle }
    guard let canon = ContactAvatarStore.canonicalKey(trimmedHandle) else { throw KeepTabsStoreError.invalidHandle }
    guard database.watchlist[canon] == nil else { throw KeepTabsStoreError.duplicateContact }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let entry = KeepTabsEntry(
      canonicalKey: canon,
      handle: trimmedHandle,
      displayName: trimmedName.isEmpty ? trimmedHandle : trimmedName,
      transport: transport,
      targetFrequencyDays: Self.clampFrequency(frequencyDays),
      addedAt: Self.iso(now)
    )
    database.watchlist[canon] = entry
    persist()
    return entry
  }

  /// Add from a Contacts search hit (manual add). Uses the match's best handle
  /// unless an explicit one is given.
  @discardableResult
  func add(match: ContactMatch, handle: String? = nil, frequencyDays: Int, now: Date = Date()) throws -> KeepTabsEntry {
    let selected = (handle ?? match.bestHandle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return try add(name: match.name, handle: selected, frequencyDays: frequencyDays, now: now)
  }

  func remove(canon: String) {
    guard database.watchlist[canon] != nil else { return }
    database.watchlist[canon] = nil
    persist()
  }

  func setFrequency(canon: String, days: Int) {
    guard database.watchlist[canon] != nil else { return }
    database.watchlist[canon]?.targetFrequencyDays = Self.clampFrequency(days)
    persist()
  }

  func snooze(canon: String, until: Date) {
    guard database.watchlist[canon] != nil else { return }
    database.watchlist[canon]?.snoozedUntil = Self.iso(until)
    persist()
  }

  func clearSnooze(canon: String) {
    guard database.watchlist[canon]?.snoozedUntil != nil else { return }
    database.watchlist[canon]?.snoozedUntil = nil
    persist()
  }

  func setAutoPrioritize(_ on: Bool) {
    guard database.autoPrioritize != on else { return }
    database.autoPrioritize = on
    persist()
  }

  /// Permanently dismiss a recommended person so they're never suggested again.
  func dismiss(canon: String, now: Date = Date()) {
    guard database.dismissed[canon] == nil else { return }
    database.dismissed[canon] = Self.iso(now)
    persist()
  }

  nonisolated static func clampFrequency(_ days: Int) -> Int {
    min(max(days, minFrequencyDays), maxFrequencyDays)
  }

  // MARK: - persistence (mirrors BabysitterStore: 0600, atomic, corrupt-quarantine)

  func load() {
    do {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        database = KeepTabsDatabase()
        lastError = nil
        return
      }
      let data = try Data(contentsOf: fileURL)
      database = try JSONDecoder().decode(KeepTabsDatabase.self, from: data)
      lastError = nil
    } catch {
      // A file that won't read/decode is set aside, NOT left in place: a silent
      // reset would let the next persist() clobber the user's watchlist. Moving
      // it preserves the bytes for recovery and starts fresh safely.
      let quarantined = quarantineCorruptFile()
      database = KeepTabsDatabase()
      if let quarantined {
        NSLog("[keep-tabs] failed to load %@ (%@); moved corrupt file to %@", fileURL.path, error.localizedDescription, quarantined.lastPathComponent)
        lastError = "Couldn't read your Orbit list (\(error.localizedDescription)). The old file was saved as \(quarantined.lastPathComponent) and a fresh one was started."
      } else {
        NSLog("[keep-tabs] failed to load %@ (%@); could not move corrupt file aside", fileURL.path, error.localizedDescription)
        lastError = error.localizedDescription
      }
    }
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
