import Foundation
import Combine
import Darwin

/// Reads draft JSON from BOTH `~/.messages-mcp/drafts/` and
/// `~/.whatsapp-mcp/drafts/` and surfaces them as one merged
/// `@Published` list. Each directory is watched separately via
/// `DispatchSourceFileSystemObject` so new drafts staged by either MCP
/// server appear in the menu bar within ~100 ms.
///
/// The WhatsApp directory is **feature-flagged on its presence** at launch: if
/// `~/.whatsapp-mcp/drafts/` does not exist, the menubar starts iMessage-only.
/// Global compose may create it later when the user explicitly stages a
/// WhatsApp draft, then installs the watcher on demand.
/// One refresh's result, published as a single value.
///
/// `drafts` and `lastRefreshError` are separate `@Published` properties, so an observer can
/// interleave and pair a new draft list with the PREVIOUS error state. That is harmless for the UI
/// but not for the cross-device relay (SUN-613), where a reader treats an absent draft as deleted:
/// pairing a truncated list with a stale "no error" would look like a deletion. This struct carries
/// the list and its own completeness together, in one assignment, so they can never be mismatched.
struct DraftRefreshSnapshot: Sendable, Equatable {
  let drafts: [Draft]
  /// True only when directory enumeration succeeded AND every eligible file parsed. A relay may
  /// treat absence as deletion ONLY when this is true.
  let complete: Bool
  /// Files that could not be read or decoded this pass. Non-zero implies `complete == false`.
  let skippedCount: Int
  /// Which source directories this pass actually scanned. The set can change during a process's
  /// life (the WhatsApp daemon may create its drafts directory after launch), and a pass that
  /// scanned a different set than the previous one is not comparable to it, so the change itself
  /// forces `complete == false` for that pass.
  let scannedSources: Set<String>
  /// Monotonic within one process lifetime. Meaningless across restarts, which is why the relay
  /// envelope also carries a per-process server instance id.
  let generation: UInt64
  /// When this state was OBSERVED, not when it was later served.
  let observedAt: Date

  /// Pre-refresh state. **`complete` is false**, deliberately: before any scan has run we know
  /// nothing, and a reader that treats absence as deletion must never act on this. Fail closed.
  static let empty = DraftRefreshSnapshot(
    drafts: [], complete: false, skippedCount: 0, scannedSources: [],
    generation: 0, observedAt: .distantPast
  )
}

@MainActor
final class DraftStore: ObservableObject {
  @Published private(set) var drafts: [Draft] = []
  @Published private(set) var lastRefreshError: String?
  /// Atomic view of the last refresh: list + completeness + generation, always mutually consistent.
  /// The relay reads ONLY this.
  @Published private(set) var refreshSnapshot: DraftRefreshSnapshot = .empty
  private var refreshGeneration: UInt64 = 0

  private let imessageDir: URL
  private let whatsappDir: URL
  private let storageHome: URL
  private var whatsappEnabled: Bool

  private var imessageSource: DispatchSourceFileSystemObject?
  private var imessageHandle: Int32 = -1
  private var whatsappSource: DispatchSourceFileSystemObject?
  private var whatsappHandle: Int32 = -1
  private var sweepTimer: Timer?
  private var pendingWatchRefresh: Task<Void, Never>?

  /// How long a SENT iMessage draft lingers on disk before the sweep removes
  /// it. Matches the console's "Recently sent" window (DraftsPane), so the
  /// displayed history is always backed by real files. The permanent record
  /// lives in ~/.messages-mcp/send-audit.log, so removing the JSON is safe.
  nonisolated static let sentDraftTTL: TimeInterval = 7 * 86_400

  init(homeOverride: URL? = nil) {
    let home = homeOverride ?? AppStoragePaths.homeDirectory
    storageHome = home
    imessageDir = home.appendingPathComponent(".messages-mcp/drafts")
    whatsappDir = home.appendingPathComponent(".whatsapp-mcp/drafts")
    // Create the iMessage dir if it doesn't exist — this app IS the
    // iMessage menubar surface, so creating it here is fine and matches
    // pre-v0.3.0 behavior. The WhatsApp dir is NOT created here; see
    // class doc comment for rationale.
    try? FileManager.default.createDirectory(at: imessageDir, withIntermediateDirectories: true)
    whatsappEnabled = FileManager.default.fileExists(atPath: whatsappDir.path)
    refresh()
    startWatching()
    // iMessage drafts have no daemon-side cleanup (the WhatsApp daemon sweeps
    // its own), so sweep stale sent ones here: once at launch, then on a slow
    // timer for long-running sessions.
    sweepSentDrafts()
    sweepTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sweepSentDrafts() }
    }
  }

  deinit {
    imessageSource?.cancel()
    if imessageHandle >= 0 { close(imessageHandle) }
    whatsappSource?.cancel()
    if whatsappHandle >= 0 { close(whatsappHandle) }
    sweepTimer?.invalidate()
    pendingWatchRefresh?.cancel()
  }

  // MARK: - Public API

  func refresh() {
    applyRefresh(Self.loadDraftDirs(
      imessageDir: imessageDir,
      whatsappDir: whatsappDir,
      whatsappEnabled: whatsappEnabled
    ))
  }

  /// Marks an **iMessage** draft as sent. WhatsApp drafts are marked
  /// sent by the WhatsApp daemon over the Unix socket — the menubar
  /// never edits WhatsApp draft JSON directly. Calling this with a
  /// WhatsApp draft id is a programmer error and throws.
  func markSent(id: String, sentAt: Date, service: String) throws {
    guard Self.isSafeDraftID(id) else { throw DraftStoreError.invalidDraftID(id) }
    guard var mutationLock = SendLock.acquire(for: id) else {
      throw DraftStoreError.draftBusy(id)
    }
    defer { mutationLock.release() }
    guard let existing = readDraft(id: id) else {
      throw DraftStoreError.draftNotFound(id)
    }
    guard existing.effectivePlatform == .imessage else {
      // Fail loudly — see method doc.
      throw DraftStoreError.platformMismatch(
        id: id,
        actualPlatform: existing.effectivePlatform,
        operation: "markSent(iMessage-only)"
      )
    }
    guard !existing.isSent else { return } // already sent — be idempotent
    let updated = Draft(
      id: existing.id,
      to_handle: existing.to_handle,
      to_handle_name: existing.to_handle_name,
      imessage_group: existing.imessage_group,
      body: existing.body,
      attachments: existing.attachments,
      delivery_progress: existing.delivery_progress,
      in_reply_to_thread_id: existing.in_reply_to_thread_id,
      staged_at: existing.staged_at,
      sent_at: Self.isoString(sentAt),
      send_service: service,
      source: existing.source,
      context_messages: existing.context_messages,
      context_diagnostic: existing.context_diagnostic,
      // Carry schedule-send fields through unchanged on send (declaration order).
      scheduled_send_at: existing.scheduled_send_at,
      schedule_hold_reason: existing.schedule_hold_reason,
      override_send: existing.override_send,
      schedule_approved: existing.schedule_approved,
      schedule_approval_tag: existing.schedule_approval_tag,
      schema_version: existing.schema_version,
      // Don't write platform back to disk for iMessage drafts —
      // keeps the on-disk JSON shape stable for v0.2.x menubars
      // that might read this file before they're upgraded.
      platform: nil,
      approval_state: existing.approval_state,
      induced_by_unknown_contact: existing.induced_by_unknown_contact,
      // iMessage-only path (guarded above) — these are always nil here,
      // but carry them through so the round-trip stays lossless.
      quoted_message_id: existing.quoted_message_id,
      quoted_preview: existing.quoted_preview,
      // Carry the relay stamp through every rewrite. Dropping it here would
      // silently un-route the draft and let a second Mac execute it (SUN-613).
      relay_executor: existing.relay_executor
    )
    try writeIMessageDraft(updated)
    refresh()
  }

  /// Rewrite a draft's schedule-send fields atomically. Used by the
  /// scheduler (hold), the Scheduled view (revert / send-now), and rescheduling.
  /// Returns the updated draft. Scheduling fields are owned by the menu-bar app,
  /// so they can be carried on either platform's draft JSON.
  @discardableResult
  func updateScheduling(
    id: String,
    scheduledSendAt: String?? = nil,
    holdReason: String?? = nil,
    overrideSend: Bool?? = nil,
    scheduleApproved: Bool?? = nil
  ) throws -> Draft {
    guard Self.isSafeDraftID(id) else { throw DraftStoreError.invalidDraftID(id) }
    guard var mutationLock = SendLock.acquire(for: id) else {
      throw DraftStoreError.draftBusy(id)
    }
    defer { mutationLock.release() }
    guard let existing = readDraft(id: id) else { throw DraftStoreError.draftNotFound(id) }
    let newScheduleApproved = scheduleApproved == nil ? existing.schedule_approved : scheduleApproved!
    let newOverrideSend = overrideSend == nil ? existing.override_send : overrideSend!

    let nextScheduledSendAt = scheduledSendAt == nil ? existing.scheduled_send_at : scheduledSendAt!
    let scheduleChanged = nextScheduledSendAt != existing.scheduled_send_at
    var updated = Draft(
      id: existing.id,
      to_handle: existing.to_handle,
      to_handle_name: existing.to_handle_name,
      imessage_group: existing.imessage_group,
      body: existing.body,
      attachments: existing.attachments,
      delivery_progress: existing.delivery_progress,
      in_reply_to_thread_id: existing.in_reply_to_thread_id,
      staged_at: existing.staged_at,
      sent_at: existing.sent_at,
      send_service: existing.send_service,
      source: existing.source,
      context_messages: existing.context_messages,
      context_diagnostic: existing.context_diagnostic,
      // Double-optional on every field: .some(value)/.some(nil) writes, nil
      // (the default) leaves the field unchanged.
      scheduled_send_at: nextScheduledSendAt,
      schedule_hold_reason: holdReason == nil ? existing.schedule_hold_reason : holdReason!,
      override_send: newOverrideSend,
      schedule_approved: newScheduleApproved,
      schedule_approval_tag: existing.schedule_approval_tag,
      schema_version: existing.schema_version,
      platform: existing.platform,
      approval_state: existing.approval_state,
      induced_by_unknown_contact: existing.induced_by_unknown_contact,
      quoted_message_id: existing.quoted_message_id,
      quoted_preview: existing.quoted_preview,
      // Carry the relay stamp through every rewrite. Dropping it here would
      // silently un-route the draft and let a second Mac execute it (SUN-613).
      relay_executor: existing.relay_executor
    )
    // Setting schedule_approved/override_send, or changing an already-approved
    // schedule, is a trusted in-app action. Authenticate the resulting payload,
    // including its new scheduled time, not the pre-edit draft. Scheduler-only
    // hold rewrites do not meet these conditions and never mint approval.
    if (scheduleApproved == .some(true))
        || (overrideSend == .some(true))
        || (scheduleChanged && newScheduleApproved == true) {
      updated = Self.authenticatingScheduleApproval(updated)
    } else if newScheduleApproved != true {
      updated = updated.replacingScheduleApprovalTag(nil)
    }
    try writeDraft(updated)
    refresh()
    return updated
  }

  /// Rewrite a draft's body atomically. Used by the threaded Drafts view's inline
  /// editor. The send path still routes through the platform daemon/automation.
  @discardableResult
  func updateBody(id: String, body: String) throws -> Draft {
    guard Self.isSafeDraftID(id) else { throw DraftStoreError.invalidDraftID(id) }
    guard var mutationLock = SendLock.acquire(for: id) else {
      throw DraftStoreError.draftBusy(id)
    }
    defer { mutationLock.release() }
    guard let existing = readDraft(id: id) else { throw DraftStoreError.draftNotFound(id) }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || existing.attachments?.isEmpty == false else {
      throw DraftStoreError.emptyBody(id)
    }
    // Editing the body via the inline GUI editor is a human action. The approval
    // tag binds the body, so a changed body invalidates the old tag — re-mint it
    // (and record the session approval) when the draft was already approved, so a
    // legitimate edit doesn't silently strand the scheduled draft as un-sendable.
    // (Issue #77.)
    var updated = Draft(
      id: existing.id,
      to_handle: existing.to_handle,
      to_handle_name: existing.to_handle_name,
      imessage_group: existing.imessage_group,
      body: trimmed,
      attachments: existing.attachments,
      delivery_progress: existing.delivery_progress,
      in_reply_to_thread_id: existing.in_reply_to_thread_id,
      staged_at: existing.staged_at,
      sent_at: existing.sent_at,
      send_service: existing.send_service,
      source: existing.source,
      context_messages: existing.context_messages,
      context_diagnostic: existing.context_diagnostic,
      scheduled_send_at: existing.scheduled_send_at,
      schedule_hold_reason: existing.schedule_hold_reason,
      override_send: existing.override_send,
      schedule_approved: existing.schedule_approved,
      schedule_approval_tag: existing.schedule_approval_tag,
      schema_version: existing.schema_version,
      platform: existing.platform,
      approval_state: existing.approval_state,
      induced_by_unknown_contact: existing.induced_by_unknown_contact,
      quoted_message_id: existing.quoted_message_id,
      quoted_preview: existing.quoted_preview,
      // Carry the relay stamp through every rewrite. Dropping it here would
      // silently un-route the draft and let a second Mac execute it (SUN-613).
      relay_executor: existing.relay_executor
    )
    if existing.schedule_approved == true {
      updated = Self.authenticatingScheduleApproval(updated)
    }
    try writeDraft(updated)
    refresh()
    return updated
  }

  /// Create a local iMessage draft from the menu-bar UI. Scheduled drafts are
  /// only pre-approved when the direct in-app composer explicitly requests it;
  /// assistant-authored scheduled drafts still pass false/nil and require the
  /// inline hold-to-approve step.
  @discardableResult
  func createIMessageDraft(
    toHandle: String,
    toHandleName: String?,
    body: String,
    scheduledAt: Date? = nil,
    approveScheduledDraft: Bool = false,
    contextMessages: [ContextMessage]? = nil,
    inReplyToThreadID: Int? = nil,
    source: String = "Ghostie UI"
  ) throws -> Draft {
    let trimmedHandle = toHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedHandle.isEmpty else { throw DraftStoreError.emptyRecipient }
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else { throw DraftStoreError.emptyBody("new") }
    let now = Date()
    let id = UUID().uuidString.lowercased()
    // These create* methods are reached ONLY from in-process trusted callers
    // (the in-app composer, the AutomationController — itself gated on an
    // authenticated automation — and Don't-Ghost). The forged-file attack writes
    // JSON directly to the drafts dir and never lands here. So when a scheduled
    // draft is pre-approved we authenticate it: record the session approval and
    // mint a per-install HMAC tag bound to this draft. (Issue #77.)
    let scheduleApproved = scheduledAt == nil ? nil : (approveScheduledDraft ? true : nil)
    let unsignedDraft = Draft(
      id: id,
      to_handle: trimmedHandle,
      to_handle_name: toHandleName,
      imessage_group: nil,
      body: trimmedBody,
      in_reply_to_thread_id: inReplyToThreadID,
      staged_at: Self.isoString(now),
      sent_at: nil,
      send_service: "iMessage",
      source: source,
      context_messages: contextMessages,
      context_diagnostic: ContextDiagnostic(
        status: "ok",
        canonical_recipient: trimmedHandle,
        matched_handle_ids: [],
        chat_id: inReplyToThreadID,
        message_count: contextMessages?.count ?? 0,
        error: nil
      ),
      scheduled_send_at: scheduledAt.map(Self.isoString),
      schedule_hold_reason: nil,
      override_send: nil,
      schedule_approved: scheduleApproved,
      schedule_approval_tag: nil,
      schema_version: nil,
      platform: nil,
      approval_state: nil,
      induced_by_unknown_contact: nil,
      quoted_message_id: nil,
      quoted_preview: nil
    )
    let draft = scheduleApproved == true
      ? Self.authenticatingScheduleApproval(unsignedDraft)
      : unsignedDraft
    try writeIMessageDraft(draft)
    trackDraftStaged(draft, scheduledAt: scheduledAt)
    refresh()
    return draft
  }

  /// Create a local iMessage group draft from trusted menu-bar UI.
  /// Used by Babysitter partner-CC outreach: the draft target carries exactly
  /// one sitter plus the selected partner, and still requires hold-to-fire.
  @discardableResult
  func createIMessageGroupDraft(
    group: IMessageGroupDraftTarget,
    body: String,
    scheduledAt: Date? = nil,
    approveScheduledDraft: Bool = false,
    contextMessages: [ContextMessage]? = nil,
    source: String = "Ghostie Babysitter"
  ) throws -> Draft {
    try IMessageGroupTargetPolicy.validateTwoParticipantTarget(group.participant_handles)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else { throw DraftStoreError.emptyBody("new") }
    let now = Date()
    let id = UUID().uuidString.lowercased()
    let targetBinding = group.canonicalRecipient
    let scheduleApproved = scheduledAt == nil ? nil : (approveScheduledDraft ? true : nil)
    let unsignedDraft = Draft(
      id: id,
      to_handle: targetBinding,
      to_handle_name: group.displayName,
      imessage_group: group,
      body: trimmedBody,
      in_reply_to_thread_id: nil,
      staged_at: Self.isoString(now),
      sent_at: nil,
      send_service: "iMessage",
      source: source,
      context_messages: contextMessages,
      context_diagnostic: ContextDiagnostic(
        status: "ok",
        canonical_recipient: targetBinding,
        matched_handle_ids: [],
        chat_id: nil,
        message_count: contextMessages?.count ?? 0,
        error: nil
      ),
      scheduled_send_at: scheduledAt.map(Self.isoString),
      schedule_hold_reason: nil,
      override_send: nil,
      schedule_approved: scheduleApproved,
      schedule_approval_tag: nil,
      schema_version: nil,
      platform: nil,
      approval_state: nil,
      induced_by_unknown_contact: nil,
      quoted_message_id: nil,
      quoted_preview: nil
    )
    let draft = scheduleApproved == true
      ? Self.authenticatingScheduleApproval(unsignedDraft)
      : unsignedDraft
    try writeIMessageDraft(draft)
    trackDraftStaged(draft, scheduledAt: scheduledAt)
    refresh()
    return draft
  }

  /// Create a local WhatsApp draft from the menu-bar UI. Like the MCP path, this
  /// only stages a draft; hold-to-fire approval still happens in the GUI.
  @discardableResult
  func createWhatsAppDraft(
    toHandle: String,
    toHandleName: String?,
    body: String,
    scheduledAt: Date? = nil,
    approveScheduledDraft: Bool = false,
    contextMessages: [ContextMessage]? = nil,
    source: String = "Ghostie UI"
  ) throws -> Draft {
    try ensureWhatsAppWatching()
    let trimmedHandle = toHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedHandle.isEmpty else { throw DraftStoreError.emptyRecipient }
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else { throw DraftStoreError.emptyBody("new") }
    let now = Date()
    let id = UUID().uuidString.lowercased()
    // See createIMessageDraft: in-process trusted caller, so authenticate a
    // pre-approved scheduled draft. (Issue #77.)
    let scheduleApproved = scheduledAt == nil ? nil : (approveScheduledDraft ? true : nil)
    let unsignedDraft = Draft(
      id: id,
      to_handle: trimmedHandle,
      to_handle_name: toHandleName,
      imessage_group: nil,
      body: trimmedBody,
      in_reply_to_thread_id: nil,
      staged_at: Self.isoString(now),
      sent_at: nil,
      send_service: nil,
      source: source,
      context_messages: contextMessages,
      context_diagnostic: ContextDiagnostic(
        status: contextMessages?.isEmpty == false ? "ok" : "not_found",
        canonical_recipient: trimmedHandle,
        matched_handle_ids: [],
        chat_id: nil,
        message_count: contextMessages?.count ?? 0,
        error: nil
      ),
      scheduled_send_at: scheduledAt.map(Self.isoString),
      schedule_hold_reason: nil,
      override_send: nil,
      schedule_approved: scheduleApproved,
      schedule_approval_tag: nil,
      schema_version: 1,
      platform: .whatsapp,
      approval_state: .pending,
      induced_by_unknown_contact: false,
      quoted_message_id: nil,
      quoted_preview: nil
    )
    let draft = scheduleApproved == true
      ? Self.authenticatingScheduleApproval(unsignedDraft)
      : unsignedDraft
    try writeDraft(draft)
    trackDraftStaged(draft, scheduledAt: scheduledAt)
    refresh()
    return draft
  }

  private func writeIMessageDraft(_ draft: Draft) throws {
    try writeDraft(draft)
  }

  private func writeDraft(_ draft: Draft) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let encoded = try encoder.encode(draft)
    let platform = draft.effectivePlatform
    if platform == .whatsapp { try ensureWhatsAppWatching() }
    let url = draftURL(id: draft.id, platform: platform)
    try encoded.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func trackDraftStaged(_ draft: Draft, scheduledAt: Date?) {
    AnalyticsClient.shared.safeCapture(.draftStaged, properties: [
      .transport: .string(draft.effectivePlatform.analyticsTransport.rawValue),
      .source: .string(AnalyticsClient.draftSource(draft.source).rawValue)
    ])
    if let scheduledAt {
      AnalyticsClient.shared.safeCapture(.scheduledMessageCreated, properties: [
        .cadence: .string(AnalyticsCadence.oneTime.rawValue),
        .scheduledDelayBucket: .string(AnalyticsClient.scheduledDelayBucket(to: scheduledAt))
      ])
    }
  }

  /// Removes a draft file. Routes by the draft's platform; if no draft
  /// with that id exists in either watched directory, throws.
  func discard(id: String) throws {
    guard Self.isSafeDraftID(id) else { throw DraftStoreError.invalidDraftID(id) }
    guard var mutationLock = SendLock.acquire(for: id) else {
      throw DraftStoreError.draftBusy(id)
    }
    defer { mutationLock.release() }
    guard let existing = readDraft(id: id) else {
      throw DraftStoreError.draftNotFound(id)
    }
    try FileManager.default.removeItem(at: draftURL(id: id, platform: existing.effectivePlatform))
    try removeAttachmentSnapshot(id: id, platform: existing.effectivePlatform)
    refresh()
  }

  /// Remove SENT iMessage drafts older than `sentDraftTTL`. Pending drafts and
  /// WhatsApp drafts (swept by their own daemon) are never touched. Best-effort:
  /// unreadable / non-draft files are skipped. Refreshes if anything was removed.
  func sweepSentDrafts(now: Date = Date()) {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: imessageDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return }
    let decoder = JSONDecoder()
    var removed = 0
    for url in urls where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
            let draft = try? decoder.decode(Draft.self, from: data),
            Self.isExpiredSentDraft(draft, now: now, ttl: Self.sentDraftTTL)
      else { continue }
      if (try? fm.removeItem(at: url)) != nil {
        // This sweep only enumerates the iMessage drafts directory. Use that
        // storage root even if a malformed file forges its `platform` field.
        try? removeAttachmentSnapshot(id: draft.id, platform: .imessage)
        removed += 1
      }
    }
    if removed > 0 { refresh() }
  }

  /// A draft is sweepable once it has been SENT and its sent time is older than
  /// `ttl`. Pending drafts (no `sent_at`) are never swept. Pure for testability.
  nonisolated static func isExpiredSentDraft(_ draft: Draft, now: Date, ttl: TimeInterval) -> Bool {
    guard let sent = draft.sentDate else { return false }
    return now.timeIntervalSince(sent) > ttl
  }

  // MARK: - Internals

  enum DraftStoreError: Error, CustomStringConvertible {
    case draftNotFound(String)
    case platformMismatch(id: String, actualPlatform: Platform, operation: String)
    case emptyBody(String)
    case emptyRecipient
    case draftBusy(String)
    case invalidDraftID(String)

    var description: String {
      switch self {
      case .draftNotFound(let id):
        return "Draft \(id) not found in either watched directory"
      case .platformMismatch(let id, let p, let op):
        return "Draft \(id) is a \(p.rawValue) draft; cannot perform \(op)"
      case .emptyBody(let id):
        return "Draft \(id) body cannot be empty"
      case .emptyRecipient:
        return "Recipient cannot be empty"
      case .draftBusy(let id):
        return "Draft \(id) is being sent or changed; try again after it finishes"
      case .invalidDraftID:
        return "Draft has an invalid identifier and cannot be changed"
      }
    }
  }

  /// Resolve the JSON path for a given draft id + platform. Used by
  /// markSent/discard so we never write to the wrong directory.
  private func draftURL(id: String, platform: Platform) -> URL {
    let base: URL
    switch platform {
    case .imessage: base = imessageDir
    case .whatsapp: base = whatsappDir
    }
    return base.appendingPathComponent("\(id).json")
  }

  private func removeAttachmentSnapshot(id: String, platform: Platform) throws {
    // Production draft and asset IDs are UUIDs. Refuse historical or forged
    // identifiers here rather than letting cleanup derive arbitrary path names
    // from untrusted JSON. Such a draft can still be removed from the UI; only
    // its unrecognized snapshot directory is retained for manual inspection.
    guard Self.isUUID(id) else { return }

    let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    let homeFD = Darwin.open(storageHome.path, directoryFlags)
    guard homeFD >= 0 else { return }
    defer { Darwin.close(homeFD) }
    let transportName = platform == .imessage ? ".messages-mcp" : ".whatsapp-mcp"
    let transportFD = Darwin.openat(homeFD, transportName, directoryFlags)
    guard transportFD >= 0 else { return }
    defer { Darwin.close(transportFD) }
    let attachmentsFD = Darwin.openat(transportFD, "draft-attachments", directoryFlags)
    guard attachmentsFD >= 0 else { return }
    defer { Darwin.close(attachmentsFD) }
    let draftFD = Darwin.openat(attachmentsFD, id, directoryFlags)
    guard draftFD >= 0 else { return }
    defer { Darwin.close(draftFD) }

    var draftStat = stat()
    guard fstat(draftFD, &draftStat) == 0 else { return }
    let stableDirectory = "/.vol/\(draftStat.st_dev)/\(draftStat.st_ino)"
    guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: stableDirectory) else { return }
    for fileName in fileNames where Self.isManagedSnapshotFileName(fileName) {
      let fileFD = Darwin.openat(draftFD, fileName, O_RDONLY | O_NOFOLLOW)
      guard fileFD >= 0 else { continue }
      var fileStat = stat()
      let regular = fstat(fileFD, &fileStat) == 0 && (fileStat.st_mode & S_IFMT) == S_IFREG
      if regular { _ = Darwin.fchflags(fileFD, 0) }
      Darwin.close(fileFD)
      if regular { _ = Darwin.unlinkat(draftFD, fileName, 0) }
    }
    _ = Darwin.unlinkat(attachmentsFD, id, AT_REMOVEDIR)
  }

  private nonisolated static func isUUID(_ value: String) -> Bool {
    value.range(
      of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$",
      options: .regularExpression
    ) != nil
  }

  private nonisolated static func isSafeDraftID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.range(
      of: "^[A-Za-z0-9_-]+$",
      options: .regularExpression
    ) != nil
  }

  private nonisolated static func isManagedSnapshotFileName(_ value: String) -> Bool {
    value.range(
      of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}(\\.[a-z0-9]{1,12})?$",
      options: .regularExpression
    ) != nil
  }

  /// Re-read the current JSON before every mutation. DraftSender persists its
  /// multipart journal directly on disk while the directory watcher is
  /// asynchronous, so using the published array here could erase a newer
  /// checkpoint and make an ordinary retry duplicate a delivered attachment.
  private func readDraft(id: String) -> Draft? {
    guard Self.isSafeDraftID(id) else { return nil }
    let decoder = JSONDecoder()
    for platform in [Platform.imessage, .whatsapp] {
      let url = draftURL(id: id, platform: platform)
      guard let data = try? Data(contentsOf: url),
            let draft = try? decoder.decode(Draft.self, from: data)
      else { continue }
      return draft
    }
    return nil
  }

  /// Read + decode all `*.json` files in a single directory. Errors are
  /// collected (not thrown) so a single broken draft doesn't blank out
  /// the entire list.
  private nonisolated static func loadDraftDirs(
    imessageDir: URL,
    whatsappDir: URL,
    whatsappEnabled: Bool
  ) -> (drafts: [Draft], error: String?, skipped: Int, sources: Set<String>) {
    var errors: [String] = []
    var skipped = 0
    var parsed: [Draft] = []
    var sources: Set<String> = ["imessage"]
    parsed.append(contentsOf: loadDir(imessageDir, errors: &errors, skipped: &skipped))
    if whatsappEnabled {
      sources.insert("whatsapp")
      parsed.append(contentsOf: loadDir(whatsappDir, errors: &errors, skipped: &skipped))
    }
    // Newest staged first; sent drafts trail behind. Both platforms
    // share the same `staged_at` ISO-8601 timestamp shape so the
    // string-comparison sort is total-order-correct across platforms.
    parsed.sort { $0.staged_at > $1.staged_at }
    return (parsed, errors.isEmpty ? nil : errors.joined(separator: "; "), skipped, sources)
  }

  private func applyRefresh(_ result: (drafts: [Draft], error: String?, skipped: Int, sources: Set<String>)) {
    refreshGeneration &+= 1
    // A pass that scanned a different set of sources than the previous pass is not comparable to
    // it: the WhatsApp daemon can create its drafts directory after launch, so a queue that "gained"
    // a source is not evidence that anything was deleted. Force incomplete for that pass.
    let sourceSetChanged = refreshGeneration > 1 && result.sources != refreshSnapshot.scannedSources
    // Publish the atomic snapshot FIRST, so a relay observer never sees a new list paired with a
    // stale completeness. `complete` needs: no directory error, no skipped file, stable source set.
    self.refreshSnapshot = DraftRefreshSnapshot(
      drafts: result.drafts,
      complete: result.error == nil && result.skipped == 0 && !sourceSetChanged,
      skippedCount: result.skipped,
      scannedSources: result.sources,
      generation: refreshGeneration,
      observedAt: Date()
    )
    self.drafts = result.drafts
    self.lastRefreshError = result.error
  }

  /// Read + decode all `*.json` files in one directory.
  ///
  /// `skipped` counts files that could not be read or decoded. This matters beyond diagnostics: the
  /// cross-device relay (SUN-613) must be able to say whether a listing is COMPLETE, because a
  /// remote reader treats an absent draft as deleted. Silently dropping an unreadable file while
  /// reporting no error would make one malformed draft look like a deletion on another device, so a
  /// per-file failure is counted here rather than swallowed.
  private nonisolated static func loadDir(
    _ dir: URL,
    errors: inout [String],
    skipped: inout Int
  ) -> [Draft] {
    let urls: [URL]
    do {
      urls = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      errors.append("\(dir.lastPathComponent): \(error.localizedDescription)")
      // Enumeration failed, so this directory contributed an unknown number of drafts. Count it so
      // the empty result cannot read as an authoritative "no drafts here".
      skipped += 1
      return []
    }
    let decoder = JSONDecoder()
    var out: [Draft] = []
    for url in urls where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
            let draft = try? decoder.decode(Draft.self, from: data)
      else {
        skipped += 1
        continue
      }
      out.append(draft)
    }
    return out
  }

  private static func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  /// Record an in-session approval and mint the schedule-approval HMAC tag over
  /// the complete current delivery payload. (Issue #77.)
  private static func authenticatingScheduleApproval(_ draft: Draft) -> Draft {
    let canonical = draft.scheduleApprovalCanonicalMessage
    ApprovalAuthenticator.recordSessionApproval(canonicalMessage: canonical)
    return draft.replacingScheduleApprovalTag(ApprovalAuthenticator.tag(for: canonical))
  }

  private func startWatching() {
    imessageSource = watch(dir: imessageDir, handleStore: { [weak self] in self?.imessageHandle = $0 })
    if whatsappEnabled {
      whatsappSource = watch(dir: whatsappDir, handleStore: { [weak self] in self?.whatsappHandle = $0 })
    }
  }

  private func scheduleWatchRefresh() {
    pendingWatchRefresh?.cancel()
    let imessageDir = self.imessageDir
    let whatsappDir = self.whatsappDir
    let whatsappEnabled = self.whatsappEnabled
    pendingWatchRefresh = Task.detached { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 150_000_000)
      } catch {
        return
      }
      let result = DraftStore.loadDraftDirs(
        imessageDir: imessageDir,
        whatsappDir: whatsappDir,
        whatsappEnabled: whatsappEnabled
      )
      await self?.applyRefresh(result)
    }
  }

  private func ensureWhatsAppWatching() throws {
    guard !whatsappEnabled || whatsappSource == nil else { return }
    try FileManager.default.createDirectory(at: whatsappDir, withIntermediateDirectories: true)
    whatsappEnabled = true
    whatsappSource = watch(dir: whatsappDir, handleStore: { [weak self] in self?.whatsappHandle = $0 })
  }

  /// Install a directory watcher. `handleStore` is called on the main
  /// queue with the open fd so the caller can stash it for the cancel
  /// path — avoids reaching into class state from the closure.
  private func watch(
    dir: URL,
    handleStore: @MainActor @escaping (Int32) -> Void
  ) -> DispatchSourceFileSystemObject? {
    let handle = open(dir.path, O_EVTONLY)
    guard handle >= 0 else { return nil }
    handleStore(handle)
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: handle,
      eventMask: [.write, .delete, .extend, .attrib, .rename, .funlock],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      // Coalesce bursts: macOS may fire multiple events for a single
      // write. Decode off the main actor so large context payloads don't
      // hitch the menu bar during a staging burst.
      self?.scheduleWatchRefresh()
    }
    source.setCancelHandler {
      close(handle)
    }
    source.resume()
    return source
  }
}
