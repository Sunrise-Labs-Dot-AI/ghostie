import Foundation
import Combine

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
@MainActor
final class DraftStore: ObservableObject {
  @Published private(set) var drafts: [Draft] = []
  @Published private(set) var lastRefreshError: String?

  private let imessageDir: URL
  private let whatsappDir: URL
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
      quoted_preview: existing.quoted_preview
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
    guard let existing = readDraft(id: id) else { throw DraftStoreError.draftNotFound(id) }
    let newScheduleApproved = scheduleApproved == nil ? existing.schedule_approved : scheduleApproved!
    let newOverrideSend = overrideSend == nil ? existing.override_send : overrideSend!

    // Authenticate a GUI approval (issue #77). Setting `schedule_approved=true`
    // or `override_send=true` through this API is an explicit in-app action
    // ("Schedule" / "Send now"), so mint a per-install HMAC tag bound to this
    // draft and remember it for the session. The scheduler only ever PASSES
    // `overrideSend=.some(false)` / holdReason here, so its internal rewrites
    // never mint a tag from untrusted on-disk state.
    var newTag = existing.schedule_approval_tag
    if (scheduleApproved == .some(true)) || (overrideSend == .some(true)) {
      ApprovalAuthenticator.recordSessionApproval(canonicalMessage: existing.scheduleApprovalCanonicalMessage)
      newTag = ApprovalAuthenticator.tag(for: existing.scheduleApprovalCanonicalMessage)
    } else if newScheduleApproved != true {
      // Approval was cleared (e.g. revert) — drop any stale tag.
      newTag = nil
    }

    let updated = Draft(
      id: existing.id,
      to_handle: existing.to_handle,
      to_handle_name: existing.to_handle_name,
      imessage_group: existing.imessage_group,
      body: existing.body,
      in_reply_to_thread_id: existing.in_reply_to_thread_id,
      staged_at: existing.staged_at,
      sent_at: existing.sent_at,
      send_service: existing.send_service,
      source: existing.source,
      context_messages: existing.context_messages,
      context_diagnostic: existing.context_diagnostic,
      // Double-optional on every field: .some(value)/.some(nil) writes, nil
      // (the default) leaves the field unchanged.
      scheduled_send_at: scheduledSendAt == nil ? existing.scheduled_send_at : scheduledSendAt!,
      schedule_hold_reason: holdReason == nil ? existing.schedule_hold_reason : holdReason!,
      override_send: newOverrideSend,
      schedule_approved: newScheduleApproved,
      schedule_approval_tag: newTag,
      schema_version: existing.schema_version,
      platform: existing.platform,
      approval_state: existing.approval_state,
      induced_by_unknown_contact: existing.induced_by_unknown_contact,
      quoted_message_id: existing.quoted_message_id,
      quoted_preview: existing.quoted_preview
    )
    try writeDraft(updated)
    refresh()
    return updated
  }

  /// Rewrite a draft's body atomically. Used by the threaded Drafts view's inline
  /// editor. The send path still routes through the platform daemon/automation.
  @discardableResult
  func updateBody(id: String, body: String) throws -> Draft {
    guard let existing = readDraft(id: id) else { throw DraftStoreError.draftNotFound(id) }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw DraftStoreError.emptyBody(id) }
    // Editing the body via the inline GUI editor is a human action. The approval
    // tag binds the body, so a changed body invalidates the old tag — re-mint it
    // (and record the session approval) when the draft was already approved, so a
    // legitimate edit doesn't silently strand the scheduled draft as un-sendable.
    // (Issue #77.)
    var newTag = existing.schedule_approval_tag
    if existing.schedule_approved == true {
      let canonical = ApprovalAuthenticator.canonicalMessage(
        id: existing.id, recipient: existing.approvalRecipientBinding, body: trimmed, scope: Draft.scheduleApprovalScope
      )
      ApprovalAuthenticator.recordSessionApproval(canonicalMessage: canonical)
      newTag = ApprovalAuthenticator.tag(for: canonical)
    }
    let updated = Draft(
      id: existing.id,
      to_handle: existing.to_handle,
      to_handle_name: existing.to_handle_name,
      imessage_group: existing.imessage_group,
      body: trimmed,
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
      schedule_approval_tag: newTag,
      schema_version: existing.schema_version,
      platform: existing.platform,
      approval_state: existing.approval_state,
      induced_by_unknown_contact: existing.induced_by_unknown_contact,
      quoted_message_id: existing.quoted_message_id,
      quoted_preview: existing.quoted_preview
    )
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
    let approvalTag = Self.mintScheduleApprovalTagIfNeeded(
      approved: scheduleApproved == true, id: id, recipient: trimmedHandle, body: trimmedBody
    )
    let draft = Draft(
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
      schedule_approval_tag: approvalTag,
      schema_version: nil,
      platform: nil,
      approval_state: nil,
      induced_by_unknown_contact: nil,
      quoted_message_id: nil,
      quoted_preview: nil
    )
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
    let approvalTag = Self.mintScheduleApprovalTagIfNeeded(
      approved: scheduleApproved == true, id: id, recipient: targetBinding, body: trimmedBody
    )
    let draft = Draft(
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
      schedule_approval_tag: approvalTag,
      schema_version: nil,
      platform: nil,
      approval_state: nil,
      induced_by_unknown_contact: nil,
      quoted_message_id: nil,
      quoted_preview: nil
    )
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
    let approvalTag = Self.mintScheduleApprovalTagIfNeeded(
      approved: scheduleApproved == true, id: id, recipient: trimmedHandle, body: trimmedBody
    )
    let draft = Draft(
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
      schedule_approval_tag: approvalTag,
      schema_version: 1,
      platform: .whatsapp,
      approval_state: .pending,
      induced_by_unknown_contact: false,
      quoted_message_id: nil,
      quoted_preview: nil
    )
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
    guard let existing = readDraft(id: id) else {
      throw DraftStoreError.draftNotFound(id)
    }
    try FileManager.default.removeItem(at: draftURL(id: id, platform: existing.effectivePlatform))
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
      if (try? fm.removeItem(at: url)) != nil { removed += 1 }
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

  /// Look up a draft from the in-memory list. Cheaper than re-reading
  /// disk and avoids the race where a watcher fires mid-edit.
  private func readDraft(id: String) -> Draft? {
    drafts.first(where: { $0.id == id })
  }

  /// Read + decode all `*.json` files in a single directory. Errors are
  /// collected (not thrown) so a single broken draft doesn't blank out
  /// the entire list.
  private nonisolated static func loadDraftDirs(
    imessageDir: URL,
    whatsappDir: URL,
    whatsappEnabled: Bool
  ) -> (drafts: [Draft], error: String?) {
    var errors: [String] = []
    var parsed: [Draft] = []
    parsed.append(contentsOf: loadDir(imessageDir, errors: &errors))
    if whatsappEnabled {
      parsed.append(contentsOf: loadDir(whatsappDir, errors: &errors))
    }
    // Newest staged first; sent drafts trail behind. Both platforms
    // share the same `staged_at` ISO-8601 timestamp shape so the
    // string-comparison sort is total-order-correct across platforms.
    parsed.sort { $0.staged_at > $1.staged_at }
    return (parsed, errors.isEmpty ? nil : errors.joined(separator: "; "))
  }

  private func applyRefresh(_ result: (drafts: [Draft], error: String?)) {
    self.drafts = result.drafts
    self.lastRefreshError = result.error
  }

  private nonisolated static func loadDir(_ dir: URL, errors: inout [String]) -> [Draft] {
    let urls: [URL]
    do {
      urls = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      errors.append("\(dir.lastPathComponent): \(error.localizedDescription)")
      return []
    }
    let decoder = JSONDecoder()
    return urls
      .filter { $0.pathExtension == "json" }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Draft.self, from: data)
      }
  }

  private static func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  /// Record an in-session approval and mint the schedule-approval HMAC tag for a
  /// freshly-created, pre-approved scheduled draft. Returns nil when the draft
  /// isn't pre-approved. (Issue #77.)
  private static func mintScheduleApprovalTagIfNeeded(
    approved: Bool, id: String, recipient: String, body: String
  ) -> String? {
    guard approved else { return nil }
    let canonical = ApprovalAuthenticator.canonicalMessage(
      id: id, recipient: recipient, body: body, scope: Draft.scheduleApprovalScope
    )
    ApprovalAuthenticator.recordSessionApproval(canonicalMessage: canonical)
    return ApprovalAuthenticator.tag(for: canonical)
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
