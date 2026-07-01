import Foundation

enum BabysitterRequestStatus: String, Codable, Equatable, CaseIterable {
  case draft
  case waiting
  case needsUser = "needs_user"
  case confirmed
  case exhausted
  case cancelled

  var isActive: Bool {
    switch self {
    case .draft, .waiting, .needsUser: return true
    case .confirmed, .exhausted, .cancelled: return false
    }
  }
}

enum BabysitterOutcome: String, Codable, Equatable, CaseIterable {
  case asked
  case accepted
  case declined
  case timedOut = "timed_out"
  case cancelled
  case needsUser = "needs_user"

  var isResolvedAsk: Bool {
    switch self {
    case .accepted, .declined, .timedOut: return true
    case .asked, .cancelled, .needsUser: return false
    }
  }
}

enum BabysitterOutreachStatus: String, Codable, Equatable {
  case staged
  case waiting
  case accepted
  case declined
  case timedOut = "timed_out"
  case needsUser = "needs_user"
  case cancelled
}

struct BabysitterContactSnapshot: Codable, Equatable, Identifiable {
  var id: String { canonicalKey }
  var canonicalKey: String
  var name: String
  var bestHandle: String
  var handles: [String]
  var addedAt: String
  var updatedAt: String

  static func make(match: ContactMatch, handle: String? = nil, now: Date = Date()) throws -> BabysitterContactSnapshot {
    let selectedHandle = (handle ?? match.bestHandle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selectedHandle.isEmpty else { throw BabysitterStoreError.missingHandle }
    guard let key = ContactAvatarStore.canonicalKey(selectedHandle) else { throw BabysitterStoreError.invalidHandle }
    let handles = ([selectedHandle] + match.handles)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let uniqueHandles = Self.unique(handles)
    let iso = BabysitterStore.iso(now)
    return BabysitterContactSnapshot(
      canonicalKey: key,
      name: match.name.trimmingCharacters(in: .whitespacesAndNewlines),
      bestHandle: selectedHandle,
      handles: uniqueHandles,
      addedAt: iso,
      updatedAt: iso
    )
  }

  private static func unique(_ handles: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for handle in handles {
      let key = ContactAvatarStore.canonicalKey(handle) ?? handle.lowercased()
      guard seen.insert(key).inserted else { continue }
      out.append(handle)
    }
    return out
  }
}

struct BabysitterOutcomeRecord: Codable, Equatable, Identifiable {
  var id: String
  var requestID: String
  var outreachID: String?
  var outcome: BabysitterOutcome
  var askedAt: String?
  var resolvedAt: String?
  var responseSeconds: Double?
  var recordedAt: String
}

struct BabysitterStats: Codable, Equatable {
  var asksSent: Int = 0
  var accepts: Int = 0
  var declines: Int = 0
  var timeouts: Int = 0
  var cancellations: Int = 0
  var responseTimesSeconds: [Double] = []
  var lastAskedAt: String?
  var lastAcceptedAt: String?
  var recentOutcomes: [BabysitterOutcomeRecord] = []

  var resolvedAsks: Int { accepts + declines + timeouts }
  var acceptanceRate: Double? {
    let resolved = resolvedAsks
    guard resolved > 0 else { return nil }
    return Double(accepts) / Double(resolved)
  }
  var averageResponseSeconds: Double? {
    guard !responseTimesSeconds.isEmpty else { return nil }
    return responseTimesSeconds.reduce(0, +) / Double(responseTimesSeconds.count)
  }
  var medianResponseSeconds: Double? {
    guard !responseTimesSeconds.isEmpty else { return nil }
    let sorted = responseTimesSeconds.sorted()
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
      return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
  }

  mutating func record(_ record: BabysitterOutcomeRecord, maxRecent: Int = 20) {
    switch record.outcome {
    case .asked:
      asksSent += 1
      lastAskedAt = record.askedAt ?? record.recordedAt
    case .accepted:
      accepts += 1
      lastAcceptedAt = record.resolvedAt ?? record.recordedAt
      appendResponseTime(record.responseSeconds)
    case .declined:
      declines += 1
      appendResponseTime(record.responseSeconds)
    case .timedOut:
      timeouts += 1
    case .cancelled:
      cancellations += 1
    case .needsUser:
      break
    }
    recentOutcomes.insert(record, at: 0)
    if recentOutcomes.count > maxRecent {
      recentOutcomes = Array(recentOutcomes.prefix(maxRecent))
    }
  }

  mutating func rebuild(from records: [BabysitterOutcomeRecord], maxRecent: Int = 20) {
    self = BabysitterStats()
    for outcomeRecord in records.sorted(by: { $0.recordedAt < $1.recordedAt }) {
      record(outcomeRecord, maxRecent: maxRecent)
    }
  }

  private mutating func appendResponseTime(_ seconds: Double?) {
    guard let seconds, seconds >= 0 else { return }
    responseTimesSeconds.append(seconds)
    if responseTimesSeconds.count > 50 {
      responseTimesSeconds = Array(responseTimesSeconds.suffix(50))
    }
  }
}

struct BabysitterProfile: Codable, Equatable, Identifiable {
  var id: String { contact.canonicalKey }
  var contact: BabysitterContactSnapshot
  var rate: String
  var tags: [String]
  var notes: String
  var preferredHandle: String?
  var defaultRank: Int
  var isActive: Bool
  var stats: BabysitterStats
  var createdAt: String
  var updatedAt: String

  var displayHandle: String { preferredHandle?.nilIfEmpty ?? contact.bestHandle }

  static func make(contact: BabysitterContactSnapshot, rank: Int, now: Date = Date()) -> BabysitterProfile {
    let iso = BabysitterStore.iso(now)
    return BabysitterProfile(
      contact: contact,
      rate: "",
      tags: [],
      notes: "",
      preferredHandle: contact.bestHandle,
      defaultRank: rank,
      isActive: true,
      stats: BabysitterStats(),
      createdAt: iso,
      updatedAt: iso
    )
  }
}

struct BabysitterMessageTarget: Codable, Equatable {
  var sitterID: String
  var sitterHandle: String
  var partner: BabysitterContactSnapshot?
  var imessageGroup: IMessageGroupDraftTarget?

  var isGroup: Bool { imessageGroup != nil }
}

struct BabysitterOutreach: Codable, Equatable, Identifiable {
  var id: String
  var sitterID: String
  var status: BabysitterOutreachStatus
  var target: BabysitterMessageTarget?
  var draftID: String?
  var stagedAt: String?
  var sentAt: String?
  var deadlineAt: String?
  var resolvedAt: String?
  var responseSeconds: Double?
  var outcome: BabysitterOutcome?
}

struct BabysitterRequest: Codable, Equatable, Identifiable {
  var id: String
  var status: BabysitterRequestStatus
  var startsAt: String
  var endsAt: String
  var note: String
  var partner: BabysitterContactSnapshot?
  var orderedSitterIDs: [String]
  var currentIndex: Int
  var replyTimeoutMinutes: Int
  var outreaches: [BabysitterOutreach]
  var createdAt: String
  var updatedAt: String

  var activeSitterID: String? {
    guard orderedSitterIDs.indices.contains(currentIndex) else { return nil }
    return orderedSitterIDs[currentIndex]
  }
}

struct BabysitterDatabase: Codable, Equatable {
  var schemaVersion: Int = 1
  var profiles: [BabysitterProfile] = []
  var requests: [BabysitterRequest] = []
}

enum BabysitterReplyIntent: Equatable {
  case accept
  case decline
  case ambiguous
}

enum BabysitterReplyClassifier {
  private static let acceptWords = [
    "yes", "yep", "yeah", "sure", "available", "can do", "i can", "works", "sounds good", "i'm free", "im free"
  ]
  private static let declineWords = [
    "no", "nope", "sorry", "can't", "cant", "cannot", "not available", "busy", "won't", "wont", "out of town"
  ]

  static func classify(_ text: String) -> BabysitterReplyIntent {
    let normalized = text.lowercased()
      .replacingOccurrences(of: "’", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return .ambiguous }
    let declineRanges = declineWords.flatMap { termRanges(in: normalized, term: $0) }
    let acceptRanges = acceptWords
      .flatMap { termRanges(in: normalized, term: $0) }
      .filter { acceptRange in
        !declineRanges.contains { declineRange in
          acceptRange.location >= declineRange.location &&
            NSMaxRange(acceptRange) <= NSMaxRange(declineRange)
        }
      }
    let accept = !acceptRanges.isEmpty
    let decline = !declineRanges.isEmpty
    switch (accept, decline) {
    case (true, false): return .accept
    case (false, true): return .decline
    default: return .ambiguous
    }
  }

  private static func termRanges(in normalized: String, term: String) -> [NSRange] {
    let escaped = NSRegularExpression.escapedPattern(for: term)
    let pattern = "(?<![a-z0-9'])\(escaped)(?![a-z0-9'])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    return regex.matches(in: normalized, range: range).map(\.range)
  }
}

enum BabysitterMessageTemplate {
  static func invitation(
    sitterName: String,
    startsAt: Date,
    endsAt: Date,
    note: String,
    partnerIncluded: Bool,
    calendar: Calendar = .current
  ) -> String {
    let day = Self.dayFormatter.string(from: startsAt)
    let start = Self.timeFormatter.string(from: startsAt)
    let end = Self.timeFormatter.string(from: endsAt)
    let firstName = sitterName.split(separator: " ").first.map(String.init) ?? sitterName
    var parts = [
      "Hi \(firstName), are you available to babysit \(day) from \(start) to \(end)?"
    ]
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedNote.isEmpty {
      parts.append(trimmedNote)
    }
    parts.append(partnerIncluded ? "Reply here when you can, and we'll confirm details." : "Reply when you can, and I'll confirm details.")
    return parts.joined(separator: " ")
  }

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
  }()

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
  }()
}

enum BabysitterStoreError: Error, CustomStringConvertible, Equatable {
  case missingHandle
  case invalidHandle
  case duplicateContact
  case profileNotFound
  case activeRequestExists
  case invalidDateRange
  case noActiveSitters
  case partnerMatchesSitter
  case requestNotFound
  case outreachNotFound
  case noRemainingSitters
  case unsafeGroupTarget(String)

  var description: String {
    switch self {
    case .missingHandle: return "Choose a contact with a phone number or email."
    case .invalidHandle: return "That contact handle cannot be used for Messages."
    case .duplicateContact: return "That babysitter is already in your roster."
    case .profileNotFound: return "Babysitter not found."
    case .activeRequestExists: return "Finish or cancel the current request before starting another."
    case .invalidDateRange: return "End time must be after start time."
    case .noActiveSitters: return "Choose at least one active babysitter."
    case .partnerMatchesSitter: return "Partner and babysitter must be different contacts."
    case .requestNotFound: return "Request not found."
    case .outreachNotFound: return "Outreach not found."
    case .noRemainingSitters: return "No remaining babysitters in this request."
    case .unsafeGroupTarget(let reason): return reason
    }
  }
}

@MainActor
final class BabysitterStore: ObservableObject {
  @Published private(set) var database = BabysitterDatabase()
  @Published private(set) var lastError: String?

  private let fileURL: URL
  private var fileSignature: String?

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("babysitter.json")
    load()
  }

  var profiles: [BabysitterProfile] {
    database.profiles.sorted {
      if $0.defaultRank != $1.defaultRank { return $0.defaultRank < $1.defaultRank }
      return $0.contact.name.localizedCaseInsensitiveCompare($1.contact.name) == .orderedAscending
    }
  }

  var activeProfiles: [BabysitterProfile] {
    profiles.filter(\.isActive)
  }

  var activeRequest: BabysitterRequest? {
    database.requests.first(where: { $0.status.isActive })
  }

  func load() {
    do {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        database = BabysitterDatabase()
        fileSignature = nil
        lastError = nil
        return
      }
      let data = try Data(contentsOf: fileURL)
      database = try JSONDecoder().decode(BabysitterDatabase.self, from: data)
      normalizeRanks()
      fileSignature = currentFileSignature()
      lastError = nil
    } catch {
      // A file that won't read/decode is set aside, NOT left in place: if we
      // silently reset to an empty database, the next persist() would clobber
      // the user's roster and history for good. Moving it preserves the bytes
      // for recovery and lets the store start fresh safely.
      let quarantined = quarantineCorruptFile()
      database = BabysitterDatabase()
      fileSignature = currentFileSignature()
      if let quarantined {
        NSLog("[babysitter] failed to load %@ (%@); moved corrupt file to %@", fileURL.path, error.localizedDescription, quarantined.lastPathComponent)
        lastError = "Couldn't read your babysitter data (\(error.localizedDescription)). The old file was saved as \(quarantined.lastPathComponent) and a fresh one was started."
      } else {
        NSLog("[babysitter] failed to load %@ (%@); could not move corrupt file aside", fileURL.path, error.localizedDescription)
        lastError = error.localizedDescription
      }
    }
  }

  /// Move an unreadable babysitter.json aside as
  /// `babysitter.json.corrupt-<timestamp>` so persist() can't overwrite it.
  /// Returns the destination URL on success, nil if the move failed.
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

  @discardableResult
  func addContact(_ match: ContactMatch, handle: String? = nil, now: Date = Date()) throws -> BabysitterProfile {
    let contact = try BabysitterContactSnapshot.make(match: match, handle: handle, now: now)
    guard !database.profiles.contains(where: { $0.id == contact.canonicalKey }) else {
      throw BabysitterStoreError.duplicateContact
    }
    let rank = (database.profiles.map(\.defaultRank).max() ?? -1) + 1
    let profile = BabysitterProfile.make(contact: contact, rank: rank, now: now)
    database.profiles.append(profile)
    persist()
    return profile
  }

  func updateProfile(
    id: String,
    rate: String,
    tags: [String],
    notes: String,
    preferredHandle: String?,
    isActive: Bool,
    now: Date = Date()
  ) throws {
    guard let idx = database.profiles.firstIndex(where: { $0.id == id }) else {
      throw BabysitterStoreError.profileNotFound
    }
    let trimmedPreferred = preferredHandle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    if let trimmedPreferred, ContactAvatarStore.canonicalKey(trimmedPreferred) == nil {
      throw BabysitterStoreError.invalidHandle
    }
    database.profiles[idx].rate = rate.trimmingCharacters(in: .whitespacesAndNewlines)
    database.profiles[idx].tags = Self.normalizedTags(tags)
    database.profiles[idx].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    database.profiles[idx].preferredHandle = trimmedPreferred
    database.profiles[idx].isActive = isActive
    database.profiles[idx].updatedAt = Self.iso(now)
    persist()
  }

  func removeProfile(id: String) throws {
    guard let idx = database.profiles.firstIndex(where: { $0.id == id }) else {
      throw BabysitterStoreError.profileNotFound
    }
    database.profiles.remove(at: idx)
    normalizeRanks()
    persist()
  }

  func reorderProfiles(from source: IndexSet, to destination: Int) {
    var ordered = profiles
    ordered.move(fromOffsets: source, toOffset: destination)
    for idx in ordered.indices {
      ordered[idx].defaultRank = idx
      ordered[idx].updatedAt = Self.iso(Date())
    }
    database.profiles = ordered
    persist()
  }

  @discardableResult
  func createRequest(
    startsAt: Date,
    endsAt: Date,
    note: String,
    partner: BabysitterContactSnapshot?,
    orderedSitterIDs: [String],
    now: Date = Date()
  ) throws -> BabysitterRequest {
    guard activeRequest == nil else { throw BabysitterStoreError.activeRequestExists }
    guard endsAt > startsAt else { throw BabysitterStoreError.invalidDateRange }
    let ids = orderedSitterIDs.filter { id in
      database.profiles.contains(where: { $0.id == id && $0.isActive })
    }
    guard !ids.isEmpty else { throw BabysitterStoreError.noActiveSitters }
    if let partner {
      for id in ids {
        if partner.canonicalKey == id { throw BabysitterStoreError.partnerMatchesSitter }
      }
    }
    let iso = Self.iso(now)
    let request = BabysitterRequest(
      id: UUID().uuidString.lowercased(),
      status: .draft,
      startsAt: Self.iso(startsAt),
      endsAt: Self.iso(endsAt),
      note: note.trimmingCharacters(in: .whitespacesAndNewlines),
      partner: partner,
      orderedSitterIDs: ids,
      currentIndex: 0,
      replyTimeoutMinutes: Self.defaultTimeoutMinutes(startsAt: startsAt, now: now),
      outreaches: [],
      createdAt: iso,
      updatedAt: iso
    )
    database.requests.insert(request, at: 0)
    persist()
    return request
  }

  func cancelActiveRequest(now: Date = Date()) throws {
    guard let idx = database.requests.firstIndex(where: { $0.status.isActive }) else {
      throw BabysitterStoreError.requestNotFound
    }
    database.requests[idx].status = .cancelled
    database.requests[idx].updatedAt = Self.iso(now)
    if let outreachIdx = database.requests[idx].outreaches.lastIndex(where: { $0.status == .waiting || $0.status == .staged || $0.status == .needsUser }) {
      database.requests[idx].outreaches[outreachIdx].status = .cancelled
      database.requests[idx].outreaches[outreachIdx].outcome = .cancelled
      recordStats(sitterID: database.requests[idx].outreaches[outreachIdx].sitterID, record: outcomeRecord(for: database.requests[idx], outreach: database.requests[idx].outreaches[outreachIdx], outcome: .cancelled, now: now))
    }
    persist()
  }

  func prepareNextOutreach(now: Date = Date()) throws -> (request: BabysitterRequest, outreach: BabysitterOutreach, profile: BabysitterProfile) {
    guard let requestIdx = database.requests.firstIndex(where: { $0.status.isActive }) else {
      throw BabysitterStoreError.requestNotFound
    }
    var request = database.requests[requestIdx]
    guard let sitterID = request.activeSitterID else { throw BabysitterStoreError.noRemainingSitters }
    guard let profile = database.profiles.first(where: { $0.id == sitterID && $0.isActive }) else {
      throw BabysitterStoreError.profileNotFound
    }
    if let existing = request.outreaches.last(where: { $0.sitterID == sitterID && ($0.status == .staged || $0.status == .waiting || $0.status == .needsUser) }) {
      return (request, existing, profile)
    }
    let outreach = BabysitterOutreach(
      id: UUID().uuidString.lowercased(),
      sitterID: sitterID,
      status: .staged,
      target: nil,
      draftID: nil,
      stagedAt: Self.iso(now),
      sentAt: nil,
      deadlineAt: nil,
      resolvedAt: nil,
      responseSeconds: nil,
      outcome: .asked
    )
    request.outreaches.append(outreach)
    request.updatedAt = Self.iso(now)
    database.requests[requestIdx] = request
    persist()
    return (request, outreach, profile)
  }

  func recordDraft(
    requestID: String,
    outreachID: String,
    draftID: String,
    target: BabysitterMessageTarget,
    now: Date = Date()
  ) throws {
    guard let requestIdx = database.requests.firstIndex(where: { $0.id == requestID }) else {
      throw BabysitterStoreError.requestNotFound
    }
    guard let outreachIdx = database.requests[requestIdx].outreaches.firstIndex(where: { $0.id == outreachID }) else {
      throw BabysitterStoreError.outreachNotFound
    }
    // Re-staging the same outreach (discard + Stage Ask again, draft edits,
    // …) must not inflate asksSent: count .asked only the FIRST time this
    // outreach gets a draft. rebuildStats() mirrors the same rule (one .asked
    // per outreach that ever had a draft).
    let isFirstDraftForOutreach = database.requests[requestIdx].outreaches[outreachIdx].draftID == nil
    database.requests[requestIdx].outreaches[outreachIdx].draftID = draftID
    database.requests[requestIdx].outreaches[outreachIdx].target = target
    database.requests[requestIdx].outreaches[outreachIdx].stagedAt = Self.iso(now)
    database.requests[requestIdx].outreaches[outreachIdx].status = .staged
    database.requests[requestIdx].status = .waiting
    database.requests[requestIdx].updatedAt = Self.iso(now)
    if isFirstDraftForOutreach {
      let record = outcomeRecord(
        for: database.requests[requestIdx],
        outreach: database.requests[requestIdx].outreaches[outreachIdx],
        outcome: .asked,
        now: now
      )
      recordStats(sitterID: database.requests[requestIdx].outreaches[outreachIdx].sitterID, record: record)
    }
    persist()
  }

  func markOutreachSent(draftID: String, sentAt: Date, now: Date = Date()) {
    guard let requestIdx = database.requests.firstIndex(where: { request in
      request.outreaches.contains(where: { $0.draftID == draftID })
    }),
    let outreachIdx = database.requests[requestIdx].outreaches.firstIndex(where: { $0.draftID == draftID }) else {
      return
    }
    database.requests[requestIdx].outreaches[outreachIdx].status = .waiting
    database.requests[requestIdx].outreaches[outreachIdx].sentAt = Self.iso(sentAt)
    database.requests[requestIdx].outreaches[outreachIdx].deadlineAt = Self.iso(sentAt.addingTimeInterval(Double(database.requests[requestIdx].replyTimeoutMinutes) * 60))
    database.requests[requestIdx].status = .waiting
    database.requests[requestIdx].updatedAt = Self.iso(now)
    persist()
  }

  func recordOutcome(
    requestID: String,
    outreachID: String,
    outcome: BabysitterOutcome,
    resolvedAt: Date = Date()
  ) throws {
    guard let requestIdx = database.requests.firstIndex(where: { $0.id == requestID }) else {
      throw BabysitterStoreError.requestNotFound
    }
    guard let outreachIdx = database.requests[requestIdx].outreaches.firstIndex(where: { $0.id == outreachID }) else {
      throw BabysitterStoreError.outreachNotFound
    }
    var outreach = database.requests[requestIdx].outreaches[outreachIdx]
    outreach.outcome = outcome
    outreach.resolvedAt = Self.iso(resolvedAt)
    if let sent = outreach.sentAt.flatMap(Self.parseISO) {
      outreach.responseSeconds = max(0, resolvedAt.timeIntervalSince(sent)).rounded()
    }
    switch outcome {
    case .accepted:
      outreach.status = .accepted
      database.requests[requestIdx].status = .confirmed
    case .declined:
      outreach.status = .declined
      advanceRequestAfterNonAccept(requestIdx: requestIdx, now: resolvedAt)
    case .timedOut:
      outreach.status = .timedOut
      advanceRequestAfterNonAccept(requestIdx: requestIdx, now: resolvedAt)
    case .needsUser:
      outreach.status = .needsUser
      database.requests[requestIdx].status = .needsUser
    case .cancelled:
      outreach.status = .cancelled
      database.requests[requestIdx].status = .cancelled
    case .asked:
      outreach.status = .waiting
      database.requests[requestIdx].status = .waiting
    }
    database.requests[requestIdx].outreaches[outreachIdx] = outreach
    database.requests[requestIdx].updatedAt = Self.iso(resolvedAt)
    let record = outcomeRecord(for: database.requests[requestIdx], outreach: outreach, outcome: outcome, now: resolvedAt)
    recordStats(sitterID: outreach.sitterID, record: record)
    persist()
  }

  /// Recompute every profile's stats from the outreach ledger. Mirrors live
  /// accumulation exactly: one .asked per outreach that ever had a draft
  /// staged (recordDraft's first-draft rule), plus the resolution record once
  /// the outreach moved past .asked. recordedAt is reconstructed from
  /// stagedAt/resolvedAt — the same instants live records carried — so the
  /// chronological replay in `BabysitterStats.rebuild` matches.
  func rebuildStats() {
    let fallbackNow = Self.iso(Date())
    var recordsBySitter: [String: [BabysitterOutcomeRecord]] = [:]
    for request in database.requests {
      for outreach in request.outreaches {
        if outreach.draftID != nil {
          let askedAt = outreach.stagedAt ?? outreach.sentAt
          recordsBySitter[outreach.sitterID, default: []].append(BabysitterOutcomeRecord(
            id: UUID().uuidString.lowercased(),
            requestID: request.id,
            outreachID: outreach.id,
            outcome: .asked,
            askedAt: askedAt,
            resolvedAt: nil,
            responseSeconds: nil,
            recordedAt: askedAt ?? fallbackNow
          ))
        }
        guard let outcome = outreach.outcome, outcome != .asked else { continue }
        recordsBySitter[outreach.sitterID, default: []].append(BabysitterOutcomeRecord(
          id: UUID().uuidString.lowercased(),
          requestID: request.id,
          outreachID: outreach.id,
          outcome: outcome,
          askedAt: outreach.sentAt ?? outreach.stagedAt,
          resolvedAt: outreach.resolvedAt,
          responseSeconds: outreach.responseSeconds,
          recordedAt: outreach.resolvedAt ?? fallbackNow
        ))
      }
    }
    for idx in database.profiles.indices {
      let records = recordsBySitter[database.profiles[idx].id] ?? []
      database.profiles[idx].stats.rebuild(from: records)
    }
    persist()
  }

  func profile(id: String) -> BabysitterProfile? {
    database.profiles.first(where: { $0.id == id })
  }

  func persist() {
    normalizeRanks()
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(database)
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      fileSignature = currentFileSignature()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  static func defaultTimeoutMinutes(startsAt: Date, now: Date = Date()) -> Int {
    let seconds = startsAt.timeIntervalSince(now)
    if seconds <= 24 * 60 * 60 { return 30 }
    if seconds <= 7 * 24 * 60 * 60 { return 120 }
    return 240
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

  private func advanceRequestAfterNonAccept(requestIdx: Int, now: Date) {
    let next = database.requests[requestIdx].currentIndex + 1
    if next < database.requests[requestIdx].orderedSitterIDs.count {
      database.requests[requestIdx].currentIndex = next
      database.requests[requestIdx].status = .draft
    } else {
      database.requests[requestIdx].status = .exhausted
    }
    database.requests[requestIdx].updatedAt = Self.iso(now)
  }

  private func recordStats(sitterID: String, record: BabysitterOutcomeRecord) {
    guard let profileIdx = database.profiles.firstIndex(where: { $0.id == sitterID }) else { return }
    database.profiles[profileIdx].stats.record(record)
    database.profiles[profileIdx].updatedAt = record.recordedAt
  }

  private func outcomeRecord(
    for request: BabysitterRequest,
    outreach: BabysitterOutreach,
    outcome: BabysitterOutcome,
    now: Date
  ) -> BabysitterOutcomeRecord {
    BabysitterOutcomeRecord(
      id: UUID().uuidString.lowercased(),
      requestID: request.id,
      outreachID: outreach.id,
      outcome: outcome,
      askedAt: outreach.sentAt ?? outreach.stagedAt,
      resolvedAt: outreach.resolvedAt,
      responseSeconds: outreach.responseSeconds,
      recordedAt: Self.iso(now)
    )
  }

  private func normalizeRanks() {
    let ordered = database.profiles.sorted {
      if $0.defaultRank != $1.defaultRank { return $0.defaultRank < $1.defaultRank }
      return $0.contact.name.localizedCaseInsensitiveCompare($1.contact.name) == .orderedAscending
    }
    for profile in ordered.enumerated() {
      if let idx = database.profiles.firstIndex(where: { $0.id == profile.element.id }) {
        database.profiles[idx].defaultRank = profile.offset
      }
    }
  }

  private static func normalizedTags(_ tags: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for raw in tags {
      let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !tag.isEmpty else { continue }
      let key = tag.lowercased()
      guard seen.insert(key).inserted else { continue }
      out.append(tag)
      if out.count >= 12 { break }
    }
    return out
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

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
