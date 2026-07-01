import Foundation
import Combine

enum AutomationCadence: String, Codable, CaseIterable, Identifiable {
  case daily
  case weekly
  case biweekly
  case monthly
  case quarterly
  case yearly

  var id: String { rawValue }

  var label: String {
    switch self {
    case .daily: return "Daily"
    case .weekly: return "Weekly"
    case .biweekly: return "Every 2 weeks"
    case .monthly: return "Monthly"
    case .quarterly: return "Quarterly"
    case .yearly: return "Yearly"
    }
  }

  private var componentStep: (Calendar.Component, Int) {
    switch self {
    case .daily: return (.day, 1)
    case .weekly: return (.day, 7)
    case .biweekly: return (.day, 14)
    case .monthly: return (.month, 1)
    case .quarterly: return (.month, 3)
    case .yearly: return (.year, 1)
    }
  }

  func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
    let (component, value) = componentStep
    return calendar.date(byAdding: component, value: value, to: date) ?? date.addingTimeInterval(86_400)
  }

  func nextFutureRun(
    after date: Date,
    now: Date = Date(),
    calendar: Calendar = .current,
    interval: Int = 1,
    weekdays: [Int] = [],
    anchor: Date? = nil
  ) -> Date {
    if self == .weekly || self == .biweekly {
      return Self.nextWeeklyRun(
        after: date,
        now: now,
        calendar: calendar,
        interval: self == .biweekly ? max(2, interval) : max(1, interval),
        weekdays: weekdays,
        anchor: anchor ?? date
      )
    }

    var candidate = nextRun(after: date, calendar: calendar)
    if interval > 1 {
      let (component, step) = componentStep
      candidate = calendar.date(byAdding: component, value: step * (max(1, interval) - 1), to: candidate) ?? candidate
    }
    var guardCount = 0
    while candidate <= now && guardCount < 36 {
      candidate = nextRun(after: candidate, calendar: calendar)
      if interval > 1 {
        let (component, step) = componentStep
        candidate = calendar.date(byAdding: component, value: step * (max(1, interval) - 1), to: candidate) ?? candidate
      }
      guardCount += 1
    }
    return candidate
  }

  private static func nextWeeklyRun(
    after date: Date,
    now: Date,
    calendar: Calendar,
    interval: Int,
    weekdays: [Int],
    anchor: Date
  ) -> Date {
    let selectedWeekdays = Set(weekdays.filter { (1...7).contains($0) })
    let fallbackWeekday = calendar.component(.weekday, from: date)
    let allowed = selectedWeekdays.isEmpty ? Set([fallbackWeekday]) : selectedWeekdays
    let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
    var probe = calendar.startOfDay(for: date)
    let lowerBound = max(now, date)

    for _ in 0..<420 {
      let weekday = calendar.component(.weekday, from: probe)
      if allowed.contains(weekday),
         let week = calendar.dateInterval(of: .weekOfYear, for: probe)?.start,
         let weekDelta = calendar.dateComponents([.weekOfYear], from: anchorWeek, to: week).weekOfYear,
         weekDelta >= 0,
         weekDelta % max(1, interval) == 0 {
        var components = calendar.dateComponents([.year, .month, .day], from: probe)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        components.nanosecond = time.nanosecond
        if let candidate = calendar.date(from: components), candidate > lowerBound {
          return candidate
        }
      }
      probe = calendar.date(byAdding: .day, value: 1, to: probe) ?? probe.addingTimeInterval(86_400)
    }

    return calendar.date(byAdding: .day, value: 7 * max(1, interval), to: date) ?? date.addingTimeInterval(Double(604_800 * max(1, interval)))
  }
}

enum AutomationApprovalStatus: String, Codable {
  case approved
  case pending
}

struct AutomationRunRecord: Codable, Identifiable, Equatable {
  let id: String
  let draftID: String
  let generatedAt: String
  let dueAt: String

  var generatedDate: Date? { MessageAutomation.parseISO(generatedAt) }
  var dueDate: Date? { MessageAutomation.parseISO(dueAt) }
}

struct MessageAutomation: Codable, Identifiable, Equatable {
  let id: String
  var title: String
  var platform: Platform
  var toHandle: String
  var toHandleName: String?
  var body: String
  var cadence: AutomationCadence
  var nextRunAt: String
  var recurrenceInterval: Int?
  var weekdays: [Int]?
  var recurrenceAnchorAt: String?
  var isEnabled: Bool
  var createdAt: String
  var updatedAt: String
  var approvalStatus: AutomationApprovalStatus?
  /// HMAC tag binding a GUI approval to this exact record (id + recipient +
  /// body). Written by AutomationStore.approve/create; verified before the
  /// controller will ever materialize a draft. A hand-written file that sets
  /// `approvalStatus = approved` without a valid tag is NOT honored. See
  /// ApprovalAuthenticator + issue #77.
  var approvalTag: String?
  var proposedBy: String?
  var lastGeneratedAt: String?
  var lastGeneratedDraftID: String?
  var runHistory: [AutomationRunRecord]?
  var failureNote: String?

  var nextRunDate: Date? { Self.parseISO(nextRunAt) }
  var recurrenceAnchorDate: Date? {
    guard let recurrenceAnchorAt else { return nil }
    return Self.parseISO(recurrenceAnchorAt)
  }
  var updatedDate: Date? { Self.parseISO(updatedAt) }
  var lastGeneratedDate: Date? {
    guard let lastGeneratedAt else { return nil }
    return Self.parseISO(lastGeneratedAt)
  }
  /// Fail-closed status read: ONLY an explicit `.approved` counts. A missing or
  /// unknown `approvalStatus` (e.g. a forged file that omits the field, or a
  /// future enum case) reads as NOT approved. (Issue #77 — previously this was
  /// `!= .pending`, which treated absence as approved.)
  var isApproved: Bool { approvalStatus == .approved }
  var needsApproval: Bool { approvalStatus != .approved }

  /// The scope label bound into this record's approval HMAC.
  static let approvalScope = "automation_approved"

  /// Canonical message the approval tag must cover for THIS record.
  var approvalCanonicalMessage: String {
    ApprovalAuthenticator.canonicalMessage(
      id: id,
      recipient: toHandle,
      body: body,
      scope: Self.approvalScope
    )
  }

  /// The send gate: status is `.approved` AND the approval is authenticated —
  /// either approved in the GUI this session, or carrying a valid HMAC tag that
  /// binds the approval to this id/recipient/body. A file written by another
  /// process (no session approval, no valid tag) returns false and is held.
  var isAuthenticallyApproved: Bool {
    guard isApproved else { return false }
    // Recompute the canonical tag from the record's CURRENT fields. A session
    // approval only matches when id/recipient/body/scope are unchanged, so
    // swapping any of them on disk invalidates the session gate too — not just
    // the persisted tag. (Issue #77, round 2.)
    let canonical = approvalCanonicalMessage
    if ApprovalAuthenticator.hasSessionApproval(canonicalMessage: canonical) { return true }
    return ApprovalAuthenticator.verify(tag: approvalTag, message: canonical)
  }

  /// Status says approved but the approval can't be authenticated (no valid tag,
  /// no session approval). Two ways to land here: an automation approved by an
  /// older app build that predates the HMAC tag, or a forged file. Either way the
  /// UI prompts the user to (re-)approve in the GUI before it will fire — it never
  /// silently sends. (Issue #77.)
  var needsReapproval: Bool { isApproved && !isAuthenticallyApproved }
  var normalizedInterval: Int {
    let fallback = cadence == .biweekly ? 2 : 1
    return min(52, max(1, recurrenceInterval ?? fallback))
  }
  var normalizedWeekdays: [Int] {
    Array(Set((weekdays ?? []).filter { (1...7).contains($0) })).sorted()
  }
  var recurrenceLabel: String {
    let interval = normalizedInterval
    switch cadence {
    case .weekly, .biweekly:
      let dayLabel = weekdayLabel(normalizedWeekdays)
      if interval == 1 { return dayLabel.isEmpty ? "Weekly" : "Weekly on \(dayLabel)" }
      return dayLabel.isEmpty ? "Every \(interval) weeks" : "Every \(interval) weeks on \(dayLabel)"
    case .daily:
      return interval == 1 ? "Daily" : "Every \(interval) days"
    case .monthly:
      return interval == 1 ? "Monthly" : "Every \(interval) months"
    case .quarterly:
      return interval == 1 ? "Quarterly" : "Every \(interval * 3) months"
    case .yearly:
      return interval == 1 ? "Yearly" : "Every \(interval) years"
    }
  }

  var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    return toHandleName ?? toHandle
  }

  func nextFutureRun(after date: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
    cadence.nextFutureRun(
      after: date,
      now: now,
      calendar: calendar,
      interval: normalizedInterval,
      weekdays: normalizedWeekdays,
      anchor: recurrenceAnchorDate ?? nextRunDate ?? date
    )
  }

  static func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  private static let withFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let withoutFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  static func parseISO(_ value: String) -> Date? {
    withFractional.date(from: value) ?? withoutFractional.date(from: value)
  }

  private func weekdayLabel(_ values: [Int]) -> String {
    guard !values.isEmpty else { return "" }
    let symbols = Calendar.current.shortWeekdaySymbols
    return values.map { symbols[max(0, min(6, $0 - 1))] }.joined(separator: ", ")
  }
}

@MainActor
final class AutomationStore: ObservableObject {
  @Published private(set) var automations: [MessageAutomation] = []
  @Published private(set) var lastError: String?

  private let fileURL: URL
  private var fileSignature: String?
  private var reloadTimer: Timer?

  init(fileURL: URL? = nil) {
    let defaultURL = AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp/automations.json")
    self.fileURL = fileURL ?? defaultURL
    load()
    reloadTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reloadIfChangedExternally() }
    }
  }

  deinit {
    reloadTimer?.invalidate()
  }

  var enabledCount: Int {
    automations.filter { $0.isEnabled && $0.isApproved }.count
  }

  var pendingApprovalCount: Int {
    // Counts both never-approved proposals AND approved-but-unauthenticated
    // automations (e.g. approved by a pre-HMAC build) — both need a GUI approval
    // before they'll fire. (Issue #77.)
    automations.filter { $0.needsApproval || $0.needsReapproval }.count
  }

  func load() {
    do {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        automations = []
        fileSignature = nil
        lastError = nil
        return
      }
      let data = try Data(contentsOf: fileURL)
      automations = try JSONDecoder().decode([MessageAutomation].self, from: data)
        .sorted { lhs, rhs in
          (lhs.nextRunDate ?? .distantFuture) < (rhs.nextRunDate ?? .distantFuture)
        }
      fileSignature = currentFileSignature()
      lastError = nil
    } catch {
      // Fail CLOSED (issue #77): a corrupt / undecodable automations.json must
      // NOT leave stale, already-approved automations in memory still firing.
      // Drop the in-memory list so nothing materializes until the file decodes
      // cleanly again. (Previously this retained stale approved state, so a
      // deleted/disabled automation kept generating drafts.)
      automations = []
      fileSignature = currentFileSignature()
      lastError = error.localizedDescription
    }
  }

  private func reloadIfChangedExternally() {
    let signature = currentFileSignature()
    guard signature != fileSignature else { return }
    load()
  }

  @discardableResult
  func create(
    title: String,
    platform: Platform,
    toHandle: String,
    toHandleName: String?,
    body: String,
    cadence: AutomationCadence,
    nextRunAt: Date,
    recurrenceInterval: Int? = nil,
    weekdays: [Int]? = nil,
    isEnabled: Bool = true
  ) throws -> MessageAutomation {
    let trimmedHandle = toHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedHandle.isEmpty else { throw AutomationStoreError.emptyRecipient }
    guard !trimmedBody.isEmpty else { throw AutomationStoreError.emptyBody }
    let now = Date()
    let id = UUID().uuidString.lowercased()
    var automation = MessageAutomation(
      id: id,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      platform: platform,
      toHandle: trimmedHandle,
      toHandleName: toHandleName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      body: trimmedBody,
      cadence: cadence,
      nextRunAt: MessageAutomation.isoString(nextRunAt),
      recurrenceInterval: min(52, max(1, recurrenceInterval ?? (cadence == .biweekly ? 2 : 1))),
      weekdays: cadence == .weekly || cadence == .biweekly
        ? Array(Set((weekdays ?? [Calendar.current.component(.weekday, from: nextRunAt)]).filter { (1...7).contains($0) })).sorted()
        : nil,
      recurrenceAnchorAt: MessageAutomation.isoString(nextRunAt),
      isEnabled: isEnabled,
      createdAt: MessageAutomation.isoString(now),
      updatedAt: MessageAutomation.isoString(now),
      approvalStatus: .approved,
      approvalTag: nil,
      proposedBy: nil,
      lastGeneratedAt: nil,
      lastGeneratedDraftID: nil,
      runHistory: nil,
      failureNote: nil
    )
    // This is the in-app composer — an explicit human action. Authenticate the
    // approval so it survives relaunch (tag) and is honored this session.
    ApprovalAuthenticator.recordSessionApproval(canonicalMessage: automation.approvalCanonicalMessage)
    automation.approvalTag = ApprovalAuthenticator.tag(for: automation.approvalCanonicalMessage)
    automations.append(automation)
    sortAndPersist()
    return automation
  }

  func update(_ automation: MessageAutomation) throws {
    guard let idx = automations.firstIndex(where: { $0.id == automation.id }) else {
      throw AutomationStoreError.notFound
    }
    var updated = automation
    updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.toHandle = updated.toHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.toHandleName = updated.toHandleName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    updated.body = updated.body.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.proposedBy = updated.proposedBy?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    updated.recurrenceInterval = min(52, max(1, updated.recurrenceInterval ?? (updated.cadence == .biweekly ? 2 : 1)))
    updated.weekdays = updated.weekdays.map { days in
      Array(Set(days.filter { day in (1...7).contains(day) })).sorted()
    }
    if updated.cadence == .weekly || updated.cadence == .biweekly {
      if updated.weekdays?.isEmpty != false {
        updated.weekdays = [Calendar.current.component(.weekday, from: updated.nextRunDate ?? Date())]
      }
    } else {
      updated.weekdays = nil
    }
    updated.recurrenceAnchorAt = updated.recurrenceAnchorAt ?? updated.nextRunAt
    guard !updated.toHandle.isEmpty else { throw AutomationStoreError.emptyRecipient }
    guard !updated.body.isEmpty else { throw AutomationStoreError.emptyBody }
    updated.updatedAt = MessageAutomation.isoString(Date())
    // An edit via the GUI is a human action on an existing record. If it's
    // approved, re-authenticate: the recipient/body may have changed, which
    // would invalidate any prior tag — re-mint it and record the session
    // approval so the editing user's intent is honored. A pending record gets
    // no tag (it still needs explicit approval). (Issue #77.)
    if updated.approvalStatus == .approved {
      ApprovalAuthenticator.recordSessionApproval(canonicalMessage: updated.approvalCanonicalMessage)
      updated.approvalTag = ApprovalAuthenticator.tag(for: updated.approvalCanonicalMessage)
    } else {
      updated.approvalTag = nil
    }
    automations[idx] = updated
    sortAndPersist()
  }

  func approve(id: String) throws {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else {
      throw AutomationStoreError.notFound
    }
    automations[idx].approvalStatus = .approved
    automations[idx].isEnabled = true
    automations[idx].updatedAt = MessageAutomation.isoString(Date())
    automations[idx].failureNote = nil
    // Authenticate this GUI approval (issue #77): remember it for the session and
    // mint an HMAC tag bound to this record so it survives relaunch. A forged
    // file that sets approvalStatus=approved without this tag is never honored.
    ApprovalAuthenticator.recordSessionApproval(canonicalMessage: automations[idx].approvalCanonicalMessage)
    automations[idx].approvalTag = ApprovalAuthenticator.tag(for: automations[idx].approvalCanonicalMessage)
    sortAndPersist()
  }

  func setEnabled(id: String, _ enabled: Bool) throws {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else {
      throw AutomationStoreError.notFound
    }
    automations[idx].isEnabled = enabled
    automations[idx].updatedAt = MessageAutomation.isoString(Date())
    automations[idx].failureNote = nil
    sortAndPersist()
  }

  func delete(id: String) throws {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else {
      throw AutomationStoreError.notFound
    }
    automations.remove(at: idx)
    sortAndPersist()
  }

  func recordGenerated(id: String, draftID: String, generatedAt: Date, dueAt: Date, nextRunAt: Date) throws {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else {
      throw AutomationStoreError.notFound
    }
    automations[idx].lastGeneratedAt = MessageAutomation.isoString(generatedAt)
    automations[idx].lastGeneratedDraftID = draftID
    automations[idx].nextRunAt = MessageAutomation.isoString(nextRunAt)
    automations[idx].updatedAt = MessageAutomation.isoString(generatedAt)
    let record = AutomationRunRecord(
      id: UUID().uuidString.lowercased(),
      draftID: draftID,
      generatedAt: MessageAutomation.isoString(generatedAt),
      dueAt: MessageAutomation.isoString(dueAt)
    )
    var history = automations[idx].runHistory ?? []
    history.insert(record, at: 0)
    automations[idx].runHistory = Array(history.prefix(50))
    automations[idx].failureNote = nil
    sortAndPersist()
  }

  func recordFailure(id: String, note: String) throws {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else {
      throw AutomationStoreError.notFound
    }
    automations[idx].failureNote = note
    automations[idx].updatedAt = MessageAutomation.isoString(Date())
    sortAndPersist()
  }

  private func sortAndPersist() {
    automations.sort {
      if $0.isEnabled != $1.isEnabled { return $0.isEnabled && !$1.isEnabled }
      return ($0.nextRunDate ?? .distantFuture) < ($1.nextRunDate ?? .distantFuture)
    }
    persist()
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(automations)
      try data.write(to: fileURL, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      fileSignature = currentFileSignature()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func currentFileSignature() -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
      return nil
    }
    let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = attrs[.size] as? NSNumber
    let fileNumber = attrs[.systemFileNumber] as? NSNumber
    return "\(modified):\(size?.int64Value ?? 0):\(fileNumber?.int64Value ?? 0)"
  }
}

enum AutomationStoreError: Error, CustomStringConvertible {
  case emptyRecipient
  case emptyBody
  case notFound

  var description: String {
    switch self {
    case .emptyRecipient: return "Recipient cannot be empty."
    case .emptyBody: return "Message cannot be empty."
    case .notFound: return "Automation not found."
    }
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
