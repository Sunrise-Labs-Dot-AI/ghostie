import Foundation
import AppKit
import Contacts
import Combine
import os.log

// ContactsExporter is the bridge between the macOS Contacts framework
// (CNContactStore, which sees iCloud-synced contacts + has a real
// native consent prompt) and the imessage-drafts-mcp binary (which is a Bun
// process and can't call CoreFoundation APIs directly).
//
// On launch we:
//   1. Check NSContacts authorization status.
//   2. If undetermined, fire requestAccess(for: .contacts) — this is
//      what pops the "Ghostie would like to access your
//      Contacts" system dialog.
//   3. On granted, enumerate every CNContact and build a canonical
//      handle → display name map.
//   4. Atomically write it to ~/.messages-mcp/contacts-cache.json.
//   5. Subscribe to CNContactStoreDidChangeNotification so the sidecar
//      tracks edits made in Contacts.app (no polling timer — see init).
//      The Birthday pane additionally re-exports on pane-open behind
//      BirthdayContactsRefreshPolicy's staleness gate, covering a missed
//      notification.
//
// The TS side (src/storage/contacts-cache.ts) reads this file as the
// PRIMARY source of contact names and falls back to AddressBook
// SQLite only when the sidecar is missing or empty.
//
// Canonicalization MUST mirror canonHandle in src/chatdb/contacts.ts:
//   - Strings containing '@' → lowercased (emails)
//   - Otherwise → digits-only, last 10 (phone numbers, US-style)
// A divergence here silently breaks contact resolution for affected
// handles. If you change one side, change the other in the same PR.

/// One Contacts hit for the Birthday tool's "add a birthday" search. Carries the
/// display name, the dispatchable best handle (for staging/sending — NOT
/// canonicalized), canonical handles (for the signals join), and any saved
/// birthday the card already carries. Metadata only.
struct ContactMatch: Identifiable, Equatable {
  let name: String
  let bestHandle: String?
  let handles: [String]
  let savedBirthday: String?
  // Two cards can share a handle; include the name so distinct people don't
  // collide in a ForEach (mirrors UpcomingBirthday.id).
  var id: String { "\(bestHandle ?? "")|\(name)" }
}

@MainActor
final class ContactsExporter: ObservableObject {
  @Published private(set) var authorizationStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
  @Published private(set) var lastExportAt: Date?
  @Published private(set) var lastExportCount: Int = 0
  @Published private(set) var lastError: String?

  private let store = CNContactStore()
  private var changeObserver: NSObjectProtocol?
  // Subsystem string follows the Info.plist CFBundleIdentifier. Keep
  // them in lockstep so `log stream --predicate 'subsystem == "..."'`
  // matches the running app.
  private let logger = Logger(subsystem: "com.sunriselabs.messages-for-ai", category: "contacts")

  // Concurrency guards for exportNow.
  //
  // The class is @MainActor, but exportNow() awaits store.enumerateContacts
  // (1-5s on a large AddressBook). During that await the main actor is
  // free, and the .CNContactStoreDidChange observer or a manual refresh
  // tap can call exportNow() again. Two concurrent runs would both
  // JSONSerialization + Data.write(.atomic), with no ordering guarantee
  // on the renames — the loser's snapshot silently lands and could be
  // missing contacts that the winner had picked up.
  //
  // isExporting + pendingExport collapse overlapping calls: the second
  // caller sets pendingExport and returns immediately; whoever holds
  // isExporting re-fires after their defer block runs. Safe because all
  // reads/writes are main-actor-serialized.
  private var isExporting = false
  private var pendingExport = false

  // Schema version must match `CONTACTS_CACHE_SCHEMA_VERSION` in
  // src/storage/contacts-cache.ts. Bumping breaks the read path on
  // older MCP binaries — coordinate the change.
  private let schemaVersion = 1

  // Schema version for the separate birthdays sidecar (read only by the
  // birthday-generator binary). Versioned independently of `schemaVersion`
  // so the two caches evolve without coupling. Must match
  // BIRTHDAYS_CACHE_SCHEMA_VERSION in mcps/birthday-generator/src/store.ts.
  private let birthdaysCacheSchemaVersion = 1

  init() {
    // Observe live Contacts edits so a contact added/renamed in
    // Contacts.app — or arriving via iCloud sync — refreshes the
    // sidecar within seconds. This notification is documented as
    // reliable for both local mutations and CloudKit-driven changes,
    // so we rely on it as the sole refresh trigger after the
    // app-launch bootstrap. No polling timer.
    changeObserver = NotificationCenter.default.addObserver(
      forName: .CNContactStoreDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.logger.info("CNContactStoreDidChange fired, refreshing sidecar")
      Task { await self?.exportNow() }
    }
  }

  deinit {
    if let obs = changeObserver { NotificationCenter.default.removeObserver(obs) }
  }

  // Kick off the initial sync at app launch. Safe to call repeatedly —
  // each call refreshes the sidecar atomically.
  //
  // Deliberately NON-prompting (lazy permissions): Contacts is optional —
  // it only improves names and birthdays — so the native consent dialog
  // must come from an explicit user action (ContactsPermissionBanner's
  // "Allow…" button → `requestAccessAndExport()`), not ambushing the user
  // at launch before they've touched a feature that benefits. While status
  // is `.notDetermined` we leave it untouched; every pane that benefits
  // shows the banner with the one-click grant.
  func bootstrap() async {
    let initial = CNContactStore.authorizationStatus(for: .contacts)
    authorizationStatus = initial
    logger.info("bootstrap: contacts auth status = \(initial.rawValue) (\(Self.statusDescription(initial), privacy: .public))")

    if initial == .notDetermined {
      // No prompt at launch — first use of a Contacts-enhanced surface asks.
      return
    }
    await exportNow()
  }

  // Force a re-prompt or re-export. Called from the
  // ContactsPermissionBanner's "Allow…" / "Recheck" buttons — the lazy
  // first-use path; `bootstrap()` never prompts.
  //
  // requestAccess only shows the system dialog when status is
  // `.notDetermined`. For `.denied`/`.restricted`, the call is a
  // no-op — the user has to flip the toggle in System Settings (or
  // run `tccutil reset Contacts com.local.messages-for-ai` if the
  // denial was due to an earlier build missing `NSContactsUsageDescription`).
  func requestAccessAndExport() async {
    let current = CNContactStore.authorizationStatus(for: .contacts)
    logger.info("requestAccessAndExport: status before request = \(Self.statusDescription(current), privacy: .public)")
    if current == .notDetermined {
      do {
        let granted = try await store.requestAccess(for: .contacts)
        let after = CNContactStore.authorizationStatus(for: .contacts)
        authorizationStatus = after
        logger.info("requestAccessAndExport: granted=\(granted), status after request = \(Self.statusDescription(after), privacy: .public)")
        if !granted {
          // The user declined the system dialog. Write a sidecar with
          // permission_status: "denied" so the MCP can fall back to
          // SQLite (or surface a clear error) instead of silently
          // reading a stale-or-empty file.
          await writeEmptySidecar(status: "denied")
          return
        }
      } catch {
        lastError = "requestAccess failed: \(error.localizedDescription)"
        logger.error("requestAccess threw: \(error.localizedDescription, privacy: .public)")
        return
      }
    }
    await exportNow()
  }

  // The core export path. Safe to call from the change observer /
  // explicit refresh button. Concurrent calls collapse — the second
  // caller queues a re-run and returns immediately.
  func exportNow() async {
    if isExporting {
      pendingExport = true
      logger.info("exportNow: in-flight; queued re-run")
      return
    }
    isExporting = true
    defer {
      isExporting = false
      // If a CNContactStoreDidChange fired while we were enumerating,
      // catch up now. Use Task so we don't recurse on the same await
      // chain and risk unbounded stack growth under a notification
      // storm.
      if pendingExport {
        pendingExport = false
        Task { await self.exportNow() }
      }
    }

    let status = CNContactStore.authorizationStatus(for: .contacts)
    authorizationStatus = status
    logger.info("exportNow: status=\(Self.statusDescription(status), privacy: .public)")

    let statusString: String
    switch status {
    case .authorized: statusString = "granted"
    case .denied:     statusString = "denied"
    case .restricted: statusString = "restricted"
    case .notDetermined: statusString = "not_determined"
    @unknown default: statusString = "unknown"
    }

    if status != .authorized {
      // macOS 14 added .limitedAccess; treat unknown future cases as
      // "not granted" — they're rare in practice and the user will
      // see the banner asking them to fix it.
      await writeEmptySidecar(status: statusString)
      return
    }

    // Enumeration is synchronous and takes 1-5s on a large address book, so
    // it runs on a detached task (its own short-lived CNContactStore — fetches
    // are thread-safe) instead of blocking the main actor. Callers now include
    // pane-opens, not just launch, so a beachball here would be user-visible.
    let snapshot: ContactsSnapshot
    do {
      snapshot = try await Task.detached(priority: .userInitiated) {
        try Self.enumerateSnapshot()
      }.value
    } catch {
      lastError = "enumerateContacts failed: \(error.localizedDescription)"
      logger.error("\(error.localizedDescription)")
      return
    }

    let payload: [String: Any] = [
      "version": schemaVersion,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "source": "menubar-cnContactStore",
      "permission_status": "granted",
      "count": snapshot.handles.count,
      "handles": snapshot.handles,
    ]
    await writeSidecar(payload: payload)

    let birthdays: [[String: Any]] = snapshot.birthdays.map {
      [
        "name": $0.name,
        "birthday": $0.birthday,
        "handles": $0.handles,
        "best_handle": $0.bestHandle as Any,
      ]
    }
    let birthdaysPayload: [String: Any] = [
      "version": birthdaysCacheSchemaVersion,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "source": "menubar-cnContactStore",
      "permission_status": "granted",
      "count": birthdays.count,
      "birthdays": birthdays,
    ]
    await writeBirthdaysSidecar(payload: birthdaysPayload)

    lastExportAt = Date()
    lastExportCount = snapshot.handles.count
    lastError = nil
    logger.info("exported \(snapshot.handles.count) contact handles (\(birthdays.count) birthdays) to sidecar")
  }

  /// One contact's birthday record bound for the birthdays sidecar. Sendable
  /// so the off-main enumeration can hand results back to the main actor.
  struct BirthdayRecord: Sendable {
    let name: String
    let birthday: String
    let handles: [String]
    let bestHandle: String?
  }

  struct ContactsSnapshot: Sendable {
    let handles: [String: String]
    let birthdays: [BirthdayRecord]
  }

  /// Enumerate every contact. Keys are the minimum set we need for the
  /// name → handle map, plus the birthday fields for the birthdays sidecar:
  /// the dedicated Gregorian birthday, the non-Gregorian birthday (cards saved
  /// with a Hebrew/Chinese/Islamic calendar), and the custom dates list
  /// (synced sources sometimes land a birthday as a "Birthday"-labeled date
  /// instead of the dedicated field).
  nonisolated private static func enumerateSnapshot() throws -> ContactsSnapshot {
    let keysToFetch: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
      CNContactBirthdayKey as CNKeyDescriptor,
      CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
      CNContactDatesKey as CNKeyDescriptor,
    ]
    let request = CNContactFetchRequest(keysToFetch: keysToFetch)
    // Unifying merges contacts that span sources (e.g. an iCloud + a
    // local copy of the same person) — matches what Contacts.app shows.
    request.unifyResults = true

    var handles: [String: String] = [:]
    // Contact-level birthday records (only contacts with a usable birthday).
    var birthdays: [BirthdayRecord] = []

    try CNContactStore().enumerateContacts(with: request) { contact, _ in
      let display = Self.displayName(for: contact)
      guard !display.isEmpty else { return }
      // Collect canonical handles (for the recency/frequency join) and the
      // dispatchable best handle (for staging/sending — NOT canonicalized,
      // since a last-10-digits form isn't routable by Messages).
      var canonHandles: [String] = []
      for phone in contact.phoneNumbers {
        let canon = Self.canonHandle(phone.value.stringValue)
        if !canon.isEmpty {
          // Last-write-wins. The order CNContactStore enumerates in
          // is stable per fetch but not documented as deterministic
          // across runs; this matches the existing TS loader's
          // last-write-wins behavior.
          handles[canon] = display
          if !canonHandles.contains(canon) { canonHandles.append(canon) }
        }
      }
      for email in contact.emailAddresses {
        let canon = Self.canonHandle(email.value as String)
        if !canon.isEmpty {
          handles[canon] = display
          if !canonHandles.contains(canon) { canonHandles.append(canon) }
        }
      }

      // Birthday: only contacts whose card has a usable month+day. Emit
      // "YYYY-MM-DD" when a year is present, else "MM-DD" (matches the
      // birthdays.json schema the skill + binary parse).
      if let bday = Self.birthdayString(for: contact) {
        birthdays.append(BirthdayRecord(
          name: display,
          birthday: bday,
          handles: canonHandles,
          bestHandle: Self.bestHandle(for: contact)
        ))
      }
    }
    return ContactsSnapshot(handles: handles, birthdays: birthdays)
  }

  // MARK: - Contacts search (the Birthday tool's "add a birthday" flow)

  /// Live name search over Contacts: the user types a name, picks a match, and
  /// gives a birthday — that's how a NEW person gets onto the birthday list (we
  /// no longer auto-rank a "who to text" list from volume). Returns matches (name
  /// + dispatchable best handle + canonical handles), `[]` when not authorized or
  /// on error. Queries `CNContactStore` live (always fresh — no sidecar), using
  /// the indexed name predicate. Capped so a broad query can't flood the UI.
  ///
  /// `nonisolated static` so callers can run it OFF the main actor: a unification
  /// fetch can take 1-5s on a large address book (see exportNow's comment), and
  /// the caller (a debounced `.task`) must not block the UI thread. It creates its
  /// own short-lived `CNContactStore` (queries are thread-safe) rather than
  /// touching the @MainActor instance's store.
  nonisolated static func searchContacts(_ query: String, limit: Int = 20) -> [ContactMatch] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    // 1 character matches almost everyone; require 2 so the result set is useful.
    guard q.count >= 2 else { return [] }
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }

    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
      CNContactBirthdayKey as CNKeyDescriptor,
      CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
      CNContactDatesKey as CNKeyDescriptor,
    ]
    let found: [CNContact]
    do {
      found = try CNContactStore().unifiedContacts(
        matching: CNContact.predicateForContacts(matchingName: q), keysToFetch: keys
      )
    } catch {
      return []
    }

    var seen = Set<String>()
    var out: [ContactMatch] = []
    for c in found {
      guard let match = contactMatch(for: c) else { continue }
      if seen.insert(match.id).inserted {
        out.append(match)
        if out.count >= limit { break }
      }
    }
    return out
  }

  nonisolated static func contactMatch(for c: CNContact) -> ContactMatch? {
    let name = Self.displayName(for: c)
    guard !name.isEmpty else { return nil }
    var canon: [String] = []
    for p in c.phoneNumbers {
      let h = Self.canonHandle(p.value.stringValue)
      if !h.isEmpty && !canon.contains(h) { canon.append(h) }
    }
    for e in c.emailAddresses {
      let h = Self.canonHandle(e.value as String)
      if !h.isEmpty && !canon.contains(h) { canon.append(h) }
    }
    return ContactMatch(
      name: name,
      bestHandle: Self.bestHandle(for: c),
      handles: canon,
      savedBirthday: Self.birthdayString(for: c)
    )
  }

  // MARK: - Sidecar I/O

  private static let sidecarDirURL: URL = {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".messages-mcp", isDirectory: true)
  }()
  private static let sidecarURL: URL = sidecarDirURL.appendingPathComponent("contacts-cache.json")
  private static let birthdaysSidecarURL: URL = sidecarDirURL.appendingPathComponent("birthdays-cache.json")

  private func writeBirthdaysSidecar(payload: [String: Any]) async {
    do {
      try FileManager.default.createDirectory(at: Self.sidecarDirURL, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: Self.birthdaysSidecarURL, options: [.atomic])
      // 0600 — contains contact names + handles + birthdays.
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: Self.birthdaysSidecarURL.path
      )
    } catch {
      lastError = "birthdays sidecar write failed: \(error.localizedDescription)"
      logger.error("birthdays sidecar write failed: \(error.localizedDescription)")
    }
  }

  private func writeSidecar(payload: [String: Any]) async {
    do {
      try FileManager.default.createDirectory(at: Self.sidecarDirURL, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      // Atomic write via FoundationKit's options: writes to a temp
      // file in the same directory then renames. Avoids the MCP
      // reading half-written JSON.
      try data.write(to: Self.sidecarURL, options: [.atomic])
      // 0600 — the file contains every contact name + handle on the
      // machine, treat it like the drafts dir.
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: Self.sidecarURL.path
      )
    } catch {
      lastError = "sidecar write failed: \(error.localizedDescription)"
      logger.error("sidecar write failed: \(error.localizedDescription)")
    }
  }

  private func writeEmptySidecar(status: String) async {
    let payload: [String: Any] = [
      "version": schemaVersion,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "source": "menubar-cnContactStore",
      "permission_status": status,
      "count": 0,
      "handles": [String: String](),
    ]
    await writeSidecar(payload: payload)
    let birthdaysPayload: [String: Any] = [
      "version": birthdaysCacheSchemaVersion,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "source": "menubar-cnContactStore",
      "permission_status": status,
      "count": 0,
      "birthdays": [[String: Any]](),
    ]
    await writeBirthdaysSidecar(payload: birthdaysPayload)
    lastExportCount = 0
    lastExportAt = Date()
  }

  // Human-readable label for `CNAuthorizationStatus`. The framework
  // returns an int from a Swift-side enum but `.rawValue` alone isn't
  // useful in logs. New cases (e.g. `.limited` added in macOS 14) hit
  // the @unknown default and log as "future_<n>".
  private static func statusDescription(_ s: CNAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted:    return "restricted"
    case .denied:        return "denied"
    case .authorized:    return "authorized"
    @unknown default:    return "future_\(s.rawValue)"
    }
  }

  // MARK: - Canonicalization (must mirror canonHandle in TS)

  nonisolated static func canonHandle(_ s: String) -> String {
    if s.contains("@") { return s.lowercased() }
    let digits = s.filter { $0.isNumber }
    if digits.count >= 10 { return String(digits.suffix(10)) }
    return digits
  }

  // Format a contact's birthday as "YYYY-MM-DD" (when a year is recorded) or
  // "MM-DD" (year-less cards). Sources, in priority order:
  //   1. The dedicated `birthday` field (Gregorian).
  //   2. The `nonGregorianBirthday` field, converted to Gregorian — only when a
  //      full date (incl. year) is present; a year-less non-Gregorian month/day
  //      maps to a different Gregorian day every year, so it is skipped rather
  //      than mis-converted.
  //   3. A "Birthday"-labeled entry in the custom `dates` list (how some synced
  //      sources — Exchange, Google — store a birthday).
  // Returns nil when none of those yields a usable month+day. Guarded by
  // isKeyAvailable so a caller that fetched fewer keys degrades to the fields
  // it did fetch instead of crashing.
  nonisolated static func birthdayString(for c: CNContact) -> String? {
    if c.isKeyAvailable(CNContactBirthdayKey), let s = gregorianBirthdayString(c.birthday) {
      return s
    }
    if c.isKeyAvailable(CNContactNonGregorianBirthdayKey),
       let s = convertedNonGregorianBirthdayString(c.nonGregorianBirthday) {
      return s
    }
    if c.isKeyAvailable(CNContactDatesKey) {
      for labeled in c.dates where isBirthdayLabel(labeled.label) {
        if let s = gregorianBirthdayString(labeled.value as DateComponents) { return s }
      }
    }
    return nil
  }

  // "YYYY-MM-DD" / "MM-DD" from Gregorian date components. Components that
  // carry a non-Gregorian calendar are routed through the conversion instead of
  // being read positionally (month 7 in the Hebrew calendar is not July).
  nonisolated private static func gregorianBirthdayString(_ comps: DateComponents?) -> String? {
    guard let comps else { return nil }
    if let cal = comps.calendar, cal.identifier != .gregorian {
      return convertedNonGregorianBirthdayString(comps)
    }
    guard let m = comps.month, let d = comps.day,
          m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
    let mm = String(format: "%02d", m)
    let dd = String(format: "%02d", d)
    if let y = comps.year, y > 0 {
      return String(format: "%04d-%@-%@", y, mm, dd)
    }
    return "\(mm)-\(dd)"
  }

  // Convert a non-Gregorian birthday (components + their source calendar) to a
  // Gregorian "YYYY-MM-DD". Requires a full date: without a year there is no
  // stable Gregorian equivalent. Both calendars are pinned to the same fixed
  // time zone so the round-trip can't straddle a DST boundary.
  nonisolated private static func convertedNonGregorianBirthdayString(_ comps: DateComponents?) -> String? {
    guard let comps, var sourceCal = comps.calendar,
          comps.month != nil, comps.day != nil,
          let year = comps.year, year > 0 else { return nil }
    let tz = TimeZone(secondsFromGMT: 0) ?? .current
    sourceCal.timeZone = tz
    var anchored = comps
    anchored.calendar = nil
    anchored.timeZone = nil
    guard let date = sourceCal.date(from: anchored) else { return nil }
    var greg = Calendar(identifier: .gregorian)
    greg.timeZone = tz
    let g = greg.dateComponents([.year, .month, .day], from: date)
    guard let gy = g.year, let gm = g.month, let gd = g.day else { return nil }
    return String(format: "%04d-%02d-%02d", gy, gm, gd)
  }

  // True for a dates-list label that means "birthday": standard labels arrive
  // wrapped ("_$!<Anniversary>!$_"), custom labels are raw strings.
  nonisolated static func isBirthdayLabel(_ label: String?) -> Bool {
    guard let label else { return false }
    let cleaned = label
      .replacingOccurrences(of: "_$!<", with: "")
      .replacingOccurrences(of: ">!$_", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return cleaned == "birthday"
  }

  // The dispatchable handle used when staging a draft: the original
  // (NOT canonicalized) phone or email Messages can route to. Prefer a phone
  // labeled mobile/iPhone, then any phone, then the first email.
  nonisolated static func bestHandle(for c: CNContact) -> String? {
    func phoneLabeled(_ wanted: String) -> String? {
      for p in c.phoneNumbers where (p.label ?? "") == wanted {
        let v = p.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { return v }
      }
      return nil
    }
    if let m = phoneLabeled(CNLabelPhoneNumberMobile) { return m }
    if let m = phoneLabeled(CNLabelPhoneNumberiPhone) { return m }
    if let p = c.phoneNumbers.first {
      let v = p.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !v.isEmpty { return v }
    }
    if let e = c.emailAddresses.first {
      let v = (e.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
      if !v.isEmpty { return v }
    }
    return nil
  }

  nonisolated private static func displayName(for c: CNContact) -> String {
    let first = c.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
    let last = c.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
    let org = c.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
    if !name.isEmpty { return name }
    return org
  }

  // MARK: - Deep-link helpers for the permission banner

  static func openContactsSettings() {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }
}

/// Whether a Birthday-pane open should re-read Contacts (exportNow). The
/// sidecar normally tracks card edits via CNContactStoreDidChange, but a
/// missed notification (app asleep through an iCloud sync, coalescing) has no
/// recovery short of relaunch — so pane-opens re-read behind a coarse
/// staleness gate. Pure so the gate is unit-testable.
enum BirthdayContactsRefreshPolicy {
  /// Coarse enough that tab-flipping never re-enumerates a large address book.
  static let minInterval: TimeInterval = 15 * 60

  static func shouldRefresh(
    authorized: Bool,
    lastExportAt: Date?,
    now: Date,
    minInterval: TimeInterval = BirthdayContactsRefreshPolicy.minInterval
  ) -> Bool {
    guard authorized else { return false }
    // No successful export this launch (bootstrap skipped or failed) — refresh.
    guard let lastExportAt else { return true }
    return now.timeIntervalSince(lastExportAt) >= minInterval
  }
}
