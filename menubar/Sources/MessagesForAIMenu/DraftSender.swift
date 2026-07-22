import CryptoKit
import Darwin
import Foundation

// Platform-aware send dispatch. Holds the iMessage AppleScript path
// AND the WhatsApp daemon-socket path. Routes by the draft's
// `effectivePlatform`:
//
//   .imessage → osascript → Messages.app (existing path, unchanged)
//   .whatsapp → ~/.whatsapp-mcp/daemon.sock JSON-RPC →
//               approveDraft + sendDraft → Baileys → WhatsApp servers
//
// iMessage notes carry over from v0.2.x:
// - The duplication of AppleScript here vs the MCP's send_draft tool is
//   ~30 lines; preferable to inventing an IPC channel between the menu
//   bar app and the (stdio-only) MCP server.
// - First call from this app triggers a macOS prompt asking the user
//   to allow "Ghostie.app" to control "Messages.app". That
//   permission is independent from the MCP server's grant — same TCC
//   service ("Automation"), separate per-app entry.
//
// WhatsApp notes:
// - The daemon is the source of truth for the sent state. On success
//   it writes `sent_at` to the draft JSON; the menubar's DraftStore FS
//   watcher then refreshes within ~100 ms. The menubar must NOT call
//   `store.markSent(...)` for WhatsApp drafts (markSent throws
//   `platformMismatch` if it's called with a WhatsApp draft).
// - Approval is a separate daemon call that precedes send. The
//   approveDraft → sendDraft sequence is intentional: a corrupted
//   approve step blocks the send rather than silently sending an
//   unapproved draft. The daemon also re-checks approval_state inside
//   sendDraft as a belt-and-suspenders gate.

/// Result of a send call. `service` is platform-specific:
/// - iMessage: "iMessage" | "SMS" (which transport Messages.app used)
/// - WhatsApp: "WhatsApp"
/// - nil on failure
struct SendResult {
  let ok: Bool
  let service: String?
  let error: String?
  let durationMs: Int
  /// For WhatsApp sends: the daemon's `message_id` for the delivered
  /// message. iMessage sends don't get a message_id back from
  /// AppleScript. nil otherwise.
  let messageId: String?

  init(ok: Bool, service: String?, error: String?, durationMs: Int, messageId: String? = nil) {
    self.ok = ok
    self.service = service
    self.error = error
    self.durationMs = durationMs
    self.messageId = messageId
  }
}

extension Notification.Name {
  /// Posted after a message is successfully delivered — ANY platform, ANY UI
  /// surface (inline composer, draft approval, Don't Ghost, scheduler, "Send
  /// now"). App-level observers react uniformly; today the only observer clears
  /// the thread's priority flag, so a send always retires the flag regardless of
  /// which UI sent it. userInfo: "platform" (Platform.rawValue String),
  /// "threadID" (Int, omitted when nil), "handle" (String).
  static let ghostieDidSendMessage = Notification.Name("ghostieDidSendMessage")
}

enum DraftSender {
  private static let timeoutSeconds: TimeInterval = 20

  /// Fire-and-forget broadcast that a send succeeded, carrying the thread key so
  /// observers don't re-derive it. Safe to call from any thread (the send path
  /// resumes off the main actor); observers hop to their own queue.
  private static func broadcastDidSend(platform: Platform, threadID: Int?, handle: String) {
    var info: [AnyHashable: Any] = ["platform": platform.rawValue, "handle": handle]
    if let threadID { info["threadID"] = threadID }
    NotificationCenter.default.post(name: .ghostieDidSendMessage, object: nil, userInfo: info)
  }

  // MARK: - Platform dispatch

  /// Top-level send entrypoint. Routes to the correct platform-specific
  /// path based on the draft's `effectivePlatform`.
  ///
  /// For iMessage: synchronous-ish (we await the osascript exit).
  /// Returns SendResult with `service` of "iMessage" or "SMS"; caller
  /// (PendingMessageBubble) is responsible for calling
  /// `store.markSent(id:sentAt:service:)` to persist sent_at.
  ///
  /// For WhatsApp: makes two daemon RPC calls (approveDraft + sendDraft);
  /// the daemon writes sent_at to disk itself. Caller MUST NOT call
  /// markSent — DraftStore's FS watcher picks up the change.
  static func send(draft: Draft) async -> SendResult {
    guard isSafeDraftID(draft.id) else {
      return SendResult(
        ok: false,
        service: nil,
        error: "This draft has an invalid identifier and cannot be sent.",
        durationMs: 0
      )
    }
    // Remote kill switch / forced-upgrade floor (issue #76). This is the single
    // chokepoint every send (scheduler, manual, automation, Don't-Ghost) routes
    // through, so one check blocks them all when a verified kill directive or a
    // min-version floor is active.
    if SendGate.shared.isBlocked(for: draft.effectivePlatform) {
      return SendResult(
        ok: false,
        service: nil,
        error: SendGate.shared.reason ?? "Sending is disabled.",
        durationMs: 0
      )
    }

    // SUN-613: cross-device executor gate, fast path. A draft stamped with
    // another Mac's `relay_executor` does not belong to this process. Checked
    // here for a quick, clear refusal; re-checked authoritatively against the
    // ON-DISK draft under the send lock below, because this `draft` is the
    // snapshot the UI captured and the stamp may have changed since.
    if let refusal = draft.executorRefusal(localDeviceID: DeviceIdentity.localDeviceID()) {
      return SendResult(ok: false, service: nil, error: refusal, durationMs: 0)
    }

    // #88: take the cross-process send lock (the SAME lockfile the MCP servers
    // use, ~/.messages-mcp/locks/<draft-id>.lock) BEFORE either platform path,
    // so a menu-bar hold-to-fire and an MCP send of the SAME draft can't both
    // fire → duplicate delivery. This must cover BOTH transports:
    //   - iMessage fires AppleScript in THIS process while the iMessage MCP's
    //     send_draft can fire it from its own process.
    //   - WhatsApp routes through the daemon, but the WhatsApp MCP's
    //     send_whatsapp_draft tool takes this same lock in its process before
    //     calling the daemon, so the daemon stays a lock-free chokepoint and we
    //     interlock here — guarding only iMessage would leave the WhatsApp
    //     MCP-vs-menubar race open.
    // "Held" means another send for this draft is already in flight; we refuse
    // rather than double-send. The lock is released in a defer after the send
    // (and the daemon round-trip for WhatsApp) completes.
    guard var lock = SendLock.acquire(for: draft.id) else {
      return SendResult(
        ok: false,
        service: nil,
        error: "A send for this draft is already in progress.",
        durationMs: 0
      )
    }
    defer { lock.release() }

    if let issue = draft.attachmentReviewIssue {
      return SendResult(ok: false, service: nil, error: issue, durationMs: 0)
    }

    let result: SendResult
    switch draft.effectivePlatform {
    case .imessage:
      // The bubble is a snapshot of what the user reviewed. Re-read the draft
      // under the cross-process send lock and compare the complete delivery
      // digest before touching Messages.app. A same-user process that changes
      // the JSON after it was rendered cannot change what gets sent.
      guard let current = Self.readIMessageDraft(draftId: draft.id) else {
        return SendResult(ok: false, service: nil, error: "The staged draft is no longer available.", durationMs: 0)
      }
      guard current.deliveryPayloadDigest == draft.deliveryPayloadDigest else {
        return SendResult(
          ok: false,
          service: nil,
          error: "This draft changed after you reviewed it. Review the updated draft before sending.",
          durationMs: 0
        )
      }
      // SUN-613: authoritative executor check, against the file rather than the
      // snapshot. `relay_executor` is intentionally outside the delivery digest
      // (it is routing, not delivery semantics), so the guard above does NOT
      // cover it — this is the check that actually holds.
      if let refusal = current.executorRefusal(localDeviceID: DeviceIdentity.localDeviceID()) {
        return SendResult(ok: false, service: nil, error: refusal, durationMs: 0)
      }
      if let ambiguous = current.delivery_progress?.ambiguous_part {
        return SendResult(
          ok: false,
          service: nil,
          error: Self.ambiguousDeliveryMessage(part: ambiguous),
          durationMs: 0
        )
      }
      result = await sendIMessageDraft(current)
      // #88 (round 2): persist `sent_at` to the draft JSON on disk BEFORE the
      // `defer` releases the lock. The MCP's duplicate-send guard reads `sent_at`
      // from that file inside ITS lock; if we released the lock first and only the
      // caller's later `markSent` wrote `sent_at`, the MCP could acquire the lock
      // in that window, see `sent_at == null`, and send again. Persisting here
      // closes the window. The caller's `markSent` stays (in-memory/UI state) and
      // is idempotent — it no-ops when `sent_at` is already on disk.
      if result.ok {
        Self.persistIMessageSentAt(draftId: draft.id, service: result.service ?? "iMessage")
      }
    case .whatsapp:
      // SUN-613: same authoritative executor check as the iMessage branch. The
      // daemon compares the delivery digest, but `relay_executor` is outside
      // that digest by design, so the routing decision has to be re-read here
      // under the lock. A missing file is not a licence to send.
      guard let currentWhatsApp = Self.readWhatsAppDraft(draftId: draft.id) else {
        return SendResult(ok: false, service: nil, error: "The staged draft is no longer available.", durationMs: 0)
      }
      if let refusal = currentWhatsApp.executorRefusal(localDeviceID: DeviceIdentity.localDeviceID()) {
        return SendResult(ok: false, service: nil, error: refusal, durationMs: 0)
      }
      // The daemon compares this digest to its current on-disk draft before it
      // records the approval, then checks it again immediately before sending.
      result = await sendWhatsApp(draft: draft)
    }
    if !result.ok {
      SendFailureLog.record(
        platform: draft.effectivePlatform.rawValue,
        handle: draft.to_handle,
        route: draft.imessage_group != nil || draft.to_handle.hasPrefix("imessage-group") ? "group" : "direct",
        error: result.error ?? "unknown",
        durationMs: result.durationMs,
        source: "swift-draft"
      )
    }
    AnalyticsClient.shared.safeCapture(.draftSent, properties: [
      .transport: .string(draft.effectivePlatform.analyticsTransport.rawValue),
      .result: .string(result.ok ? AnalyticsResult.success.rawValue : AnalyticsResult.failure.rawValue)
    ])
    if result.ok {
      broadcastDidSend(
        platform: draft.effectivePlatform,
        threadID: draft.in_reply_to_thread_id,
        handle: draft.to_handle
      )
    }
    return result
  }

  enum IMessageDraftPart: Equatable {
    case attachment(index: Int, attachment: DraftAttachment)
    case body(String)

    var marker: String {
      switch self {
      case .attachment(let index, _):
        return "attachment:\(index)"
      case .body:
        return "body"
      }
    }
  }

  struct PreparedIMessageAttachment {
    let fileURL: URL
    let fileFD: Int32
    let directoryFD: Int32
    let spoolRootFD: Int32
    let fileName: String
    let directoryName: String
  }

  enum IMessageAttachmentPreparationError: LocalizedError {
    case invalidSnapshot
    case changedSnapshot
    case spoolUnavailable

    var errorDescription: String? {
      switch self {
      case .invalidSnapshot:
        return "The staged attachment is missing or is no longer a regular managed file. Discard and stage it again."
      case .changedSnapshot:
        return "The staged attachment no longer matches the image you reviewed. Discard and stage it again."
      case .spoolUnavailable:
        return "Ghostie could not create a protected attachment handoff, so nothing was sent."
      }
    }
  }

  /// Pure delivery-plan builder used by the wire path and regression tests.
  /// Confirmed parts are omitted, so an ordinary retry resumes after the last
  /// durable success instead of replaying media that already reached Messages.
  static func pendingIMessageParts(for draft: Draft) -> [IMessageDraftPart] {
    let attachments = draft.attachments ?? []
    let progress = draft.delivery_progress
    let completed = min(max(progress?.completed_attachment_count ?? 0, 0), attachments.count)
    var parts: [IMessageDraftPart] = attachments.enumerated().compactMap { index, attachment -> IMessageDraftPart? in
      index >= completed ? .attachment(index: index, attachment: attachment) : nil
    }
    if progress?.body_sent != true, !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(.body(draft.body))
    }
    return parts
  }

  private static func ambiguousDeliveryMessage(part: String) -> String {
    "Ghostie cannot safely retry \(part) because its delivery status is unclear. Check the conversation, then discard this draft and restage only what is missing."
  }

  /// Deliver a staged iMessage manifest in review order: managed snapshots
  /// first, then text. Every wire operation is bracketed by durable progress.
  /// A crash or ambiguous transport failure leaves an `ambiguous_part` marker,
  /// which blocks an ordinary retry instead of risking a duplicate.
  private static func sendIMessageDraft(_ draft: Draft) async -> SendResult {
    typealias SendAttachment = (DraftAttachment) async -> SendResult
    typealias SendBody = (String) async -> SendResult

    let sendAttachment: SendAttachment
    let sendBody: SendBody

    if let group = draft.imessage_group {
      do {
        try IMessageGroupTargetPolicy.validateTwoParticipantTarget(group.participant_handles)
      } catch {
        return SendResult(ok: false, service: nil, error: error.localizedDescription, durationMs: 0)
      }
      let storedGUID = group.chat_guid?.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolvedGUID = IMessageGroupResolver()
        .resolveExactGroup(participantHandles: group.participant_handles)?.chatGUID
      guard let chatGUID = [storedGUID, resolvedGUID]
        .compactMap({ $0 })
        .first(where: { !$0.isEmpty }) else {
        if draft.attachments?.isEmpty == false {
          return SendResult(
            ok: false,
            service: nil,
            error: "Messages needs an existing group thread before Ghostie can send an attachment. Send one message to this group in Messages, then review the draft again.",
            durationMs: 0
          )
        }
        return await sendIMessageGroup(group: group, body: draft.body)
      }
      sendAttachment = { attachment in
        let raw = await runOSAScript(groupFileScript, args: [chatGUID, attachment.path])
        guard raw.ok else { return raw }
        return SendResult(
          ok: true,
          service: serviceFromChatGUID(chatGUID),
          error: nil,
          durationMs: raw.durationMs
        )
      }
      sendBody = { body in
        let raw = await runOSAScript(groupScript, args: [chatGUID, body])
        guard raw.ok else { return raw }
        return SendResult(
          ok: true,
          service: serviceFromChatGUID(chatGUID),
          error: nil,
          durationMs: raw.durationMs
        )
      }
    } else if let chatGUID = Self.groupChatGUID(from: draft.to_handle) {
      sendAttachment = { attachment in
        let raw = await runOSAScript(groupFileScript, args: [chatGUID, attachment.path])
        guard raw.ok else { return raw }
        return SendResult(ok: true, service: serviceFromChatGUID(chatGUID), error: nil, durationMs: raw.durationMs)
      }
      sendBody = { body in
        let raw = await runOSAScript(groupScript, args: [chatGUID, body])
        guard raw.ok else { return raw }
        return SendResult(ok: true, service: serviceFromChatGUID(chatGUID), error: nil, durationMs: raw.durationMs)
      }
    } else if draft.to_handle.hasPrefix("imessage-group") {
      return SendResult(
        ok: false,
        service: nil,
        error: "Can't send: this group draft's target was not resolved. Stage a new ask from the Babysitter feature.",
        durationMs: 0
      )
    } else if let resolved = IMessageDirectChatResolver().resolveDirectChat(handle: draft.to_handle),
              IMessageDirectChatResolver.isAddressableChatGUID(resolved.chatGUID) {
      let chatGUID = resolved.chatGUID
      sendAttachment = { attachment in
        let raw = await runOSAScript(groupFileScript, args: [chatGUID, attachment.path])
        guard raw.ok else { return raw }
        return SendResult(ok: true, service: serviceFromChatGUID(chatGUID), error: nil, durationMs: raw.durationMs)
      }
      sendBody = { body in
        let raw = await runOSAScript(groupScript, args: [chatGUID, body])
        guard raw.ok else { return raw }
        return SendResult(ok: true, service: serviceFromChatGUID(chatGUID), error: nil, durationMs: raw.durationMs)
      }
    } else {
      sendAttachment = { attachment in
        await runOSAScript(buddyFileScript, args: [draft.to_handle, attachment.path])
      }
      sendBody = { body in
        await sendIMessageDirect(toHandle: draft.to_handle, body: body)
      }
    }

    var completed = min(
      max(draft.delivery_progress?.completed_attachment_count ?? 0, 0),
      draft.attachments?.count ?? 0
    )
    var bodySent = draft.delivery_progress?.body_sent ?? false
    var totalDuration = 0
    var lastService: String?
    let parts = pendingIMessageParts(for: draft)

    for part in parts {
      guard persistIMessageDeliveryProgress(
        draftId: draft.id,
        completedAttachmentCount: completed,
        bodySent: bodySent,
        ambiguousPart: part.marker
      ) else {
        return SendResult(
          ok: false,
          service: nil,
          error: "Ghostie could not record duplicate-send protection, so nothing was sent.",
          durationMs: totalDuration
        )
      }

      let wireResult: SendResult
      switch part {
      case .attachment(let index, let attachment):
        let prepared: PreparedIMessageAttachment
        do {
          prepared = try prepareIMessageAttachment(attachment, draftId: draft.id)
        } catch {
          _ = persistIMessageDeliveryProgress(
            draftId: draft.id,
            completedAttachmentCount: completed,
            bodySent: bodySent,
            ambiguousPart: nil
          )
          return SendResult(
            ok: false,
            service: nil,
            error: error.localizedDescription,
            durationMs: totalDuration
          )
        }
        let sendCopy = DraftAttachment(
          path: prepared.fileURL.path,
          filename: attachment.filename,
          mime_type: attachment.mime_type,
          byte_count: attachment.byte_count,
          asset_id: attachment.asset_id,
          sha256: attachment.sha256
        )
        wireResult = await sendAttachment(sendCopy)
        cleanupIMessageAttachment(prepared)
        if wireResult.ok { completed = index + 1 }
      case .body(let body):
        wireResult = await sendBody(body)
        if wireResult.ok { bodySent = true }
      }
      totalDuration += wireResult.durationMs
      guard wireResult.ok else {
        return SendResult(
          ok: false,
          service: nil,
          error: "\(wireResult.error ?? "The send failed.") \(ambiguousDeliveryMessage(part: part.marker))",
          durationMs: totalDuration
        )
      }
      lastService = wireResult.service ?? lastService

      guard persistIMessageDeliveryProgress(
        draftId: draft.id,
        completedAttachmentCount: completed,
        bodySent: bodySent,
        ambiguousPart: nil
      ) else {
        return SendResult(
          ok: false,
          service: nil,
          error: ambiguousDeliveryMessage(part: part.marker),
          durationMs: totalDuration
        )
      }
    }

    return SendResult(
      ok: true,
      service: lastService ?? "iMessage",
      error: nil,
      durationMs: totalDuration
    )
  }

  /// First-party typed send entrypoint for the Messages inline composer.
  ///
  /// This deliberately bypasses DraftStore: human-typed text in the app should
  /// behave like a normal send, while AI/MCP-authored messages still travel
  /// through the staged-draft approval system via `send(draft:)`.
  static func sendDirect(target: MessageSendTarget, body: String) async -> SendResult {
    let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      return SendResult(ok: false, service: nil, error: "Message is empty.", durationMs: 0)
    }
    if SendGate.shared.isBlocked(for: target.platform) {
      return SendResult(
        ok: false,
        service: nil,
        error: SendGate.shared.reason ?? "Sending is disabled.",
        durationMs: 0
      )
    }

    let sendID = "direct-\(UUID().uuidString.lowercased())"
    guard var lock = SendLock.acquire(for: sendID) else {
      return SendResult(
        ok: false,
        service: nil,
        error: "A send is already in progress.",
        durationMs: 0
      )
    }
    defer { lock.release() }

    let sendStartedAt = Date()
    let result: SendResult
    switch target.platform {
    case .imessage:
      if let chatGUID = target.imessageChatGUID, !chatGUID.isEmpty,
         IMessageDirectChatResolver.isAddressableChatGUID(chatGUID) {
        // chat-id send routes by the chat's own service; groupScript always
        // reports "iMessage", so recover the real transport from the GUID prefix.
        // Unaddressable guids (an unbound "any;-;…" chat) fall through to the
        // resolver path so we don't hard-fail with -1728.
        let raw = await runOSAScript(groupScript, args: [chatGUID, body])
        result = raw.ok
          ? SendResult(ok: true, service: serviceFromChatGUID(chatGUID), error: nil, durationMs: raw.durationMs, messageId: raw.messageId)
          : raw
      } else {
        result = await sendIMessageDirect(toHandle: target.handle, body: body)
      }
      if result.ok {
        appendIMessageSendAudit(sendID: sendID, target: target, body: body, service: result.service ?? "iMessage")
        confirmDeliveryInBackground(handle: target.handle, sentAt: sendStartedAt, source: "swift-direct")
      }
    case .whatsapp:
      result = await sendWhatsAppDirect(threadJID: target.handle, body: body)
    }

    if !result.ok {
      SendFailureLog.record(
        platform: target.platform.rawValue,
        handle: target.handle,
        route: target.imessageChatGUID?.isEmpty == false ? "chat-id" : "direct",
        error: result.error ?? "unknown",
        durationMs: result.durationMs,
        source: "swift-direct"
      )
    }

    AnalyticsClient.shared.safeCapture(.draftSent, properties: [
      .transport: .string(target.platform.analyticsTransport.rawValue),
      .result: .string(result.ok ? AnalyticsResult.success.rawValue : AnalyticsResult.failure.rawValue),
      .source: .string("first_party_direct")
    ])
    if result.ok {
      broadcastDidSend(platform: target.platform, threadID: target.threadID, handle: target.handle)
    }
    return result
  }

  /// First-party attachment send from the inline composer (iMessage only).
  /// Runs under the same gate + lock as text sends; the file must already
  /// exist at a user-chosen path (NSOpenPanel grants sandbox-free access in
  /// this non-sandboxed app).
  static func sendDirectAttachment(target: MessageSendTarget, fileURL: URL) async -> SendResult {
    guard target.platform == .imessage else {
      return SendResult(ok: false, service: nil, error: "Attachments are iMessage-only for now.", durationMs: 0)
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return SendResult(ok: false, service: nil, error: "That file is no longer there.", durationMs: 0)
    }
    if SendGate.shared.isBlocked(for: target.platform) {
      return SendResult(ok: false, service: nil, error: SendGate.shared.reason ?? "Sending is disabled.", durationMs: 0)
    }
    let sendID = "direct-file-\(UUID().uuidString.lowercased())"
    guard var lock = SendLock.acquire(for: sendID) else {
      return SendResult(ok: false, service: nil, error: "A send is already in progress.", durationMs: 0)
    }
    defer { lock.release() }
    let result: SendResult
    if let chatGUID = target.imessageChatGUID, !chatGUID.isEmpty,
       IMessageDirectChatResolver.isAddressableChatGUID(chatGUID) {
      result = await runOSAScript(groupFileScript, args: [chatGUID, fileURL.path])
    } else {
      result = await runOSAScript(buddyFileScript, args: [target.handle, fileURL.path])
    }
    if result.ok {
      appendIMessageSendAudit(
        sendID: sendID, target: target,
        body: "[attachment] \(fileURL.lastPathComponent)",
        service: result.service ?? "iMessage"
      )
    }
    AnalyticsClient.shared.safeCapture(.draftSent, properties: [
      .transport: .string(target.platform.analyticsTransport.rawValue),
      .result: .string(result.ok ? AnalyticsResult.success.rawValue : AnalyticsResult.failure.rawValue),
      .source: .string("first_party_direct_attachment")
    ])
    if result.ok {
      broadcastDidSend(platform: target.platform, threadID: target.threadID, handle: target.handle)
    }
    return result
  }

  // MARK: - sent_at persistence (held inside the send lock)

  private static func iMessageDraftURL(draftId: String) -> URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp/drafts", isDirectory: true)
      .appendingPathComponent("\(draftId).json")
  }

  static func readIMessageDraft(draftId: String) -> Draft? {
    guard isSafeDraftID(draftId) else { return nil }
    guard let data = try? Data(contentsOf: iMessageDraftURL(draftId: draftId)) else { return nil }
    return try? JSONDecoder().decode(Draft.self, from: data)
  }

  static func whatsAppDraftURL(draftId: String) -> URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".whatsapp-mcp/drafts", isDirectory: true)
      .appendingPathComponent("\(draftId).json")
  }

  /// WhatsApp counterpart to `readIMessageDraft`. Added for the SUN-613 executor
  /// check, which has to read the file rather than trust the reviewed snapshot.
  static func readWhatsAppDraft(draftId: String) -> Draft? {
    guard isSafeDraftID(draftId) else { return nil }
    guard let data = try? Data(contentsOf: whatsAppDraftURL(draftId: draftId)) else { return nil }
    return try? JSONDecoder().decode(Draft.self, from: data)
  }

  /// Atomically mutate one iMessage draft JSON file. The caller already holds
  /// the cross-process send lock, so this is also the durable multipart journal.
  private static func mutateIMessageDraftJSON(
    draftId: String,
    _ mutation: (inout [String: Any]) -> Bool
  ) -> Bool {
    guard isSafeDraftID(draftId) else { return false }
    let url = iMessageDraftURL(draftId: draftId)
    guard let data = try? Data(contentsOf: url),
          var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return false }
    guard mutation(&obj) else { return true }
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else {
      return false
    }
    do {
      try out.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  static func persistIMessageDeliveryProgress(
    draftId: String,
    completedAttachmentCount: Int,
    bodySent: Bool,
    ambiguousPart: String?
  ) -> Bool {
    mutateIMessageDraftJSON(draftId: draftId) { obj in
      let ambiguousValue: Any = ambiguousPart ?? NSNull()
      obj["delivery_progress"] = [
        "completed_attachment_count": max(0, completedAttachmentCount),
        "body_sent": bodySent,
        "ambiguous_part": ambiguousValue
      ]
      return true
    }
  }

  static func fileSHA256(atPath path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Open every managed directory with O_NOFOLLOW, copy the reviewed bytes
  /// into Ghostie's short-lived spool inside TCC-protected Messages storage,
  /// then hand Messages a stable APFS file-id path. The protected file remains
  /// open and user-immutable until osascript returns. The staging MCP does not
  /// have Full Disk Access, so it cannot rewrite this final handoff.
  static func prepareIMessageAttachment(
    _ attachment: DraftAttachment,
    draftId: String
  ) throws -> PreparedIMessageAttachment {
    guard let expectedBytes = attachment.byte_count,
          expectedBytes >= 0,
          expectedBytes <= 100 * 1024 * 1024,
          let expectedSHA = attachment.sha256?.lowercased(),
          expectedSHA.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else {
      throw IMessageAttachmentPreparationError.invalidSnapshot
    }

    guard draftId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
      throw IMessageAttachmentPreparationError.invalidSnapshot
    }
    let expandedPath = (attachment.path as NSString).expandingTildeInPath
    let standardizedURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
    let expectedDirectory = AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp", isDirectory: true)
      .appendingPathComponent("draft-attachments", isDirectory: true)
      .appendingPathComponent(draftId, isDirectory: true)
      .standardizedFileURL
    guard expandedPath.hasPrefix("/"),
          standardizedURL.deletingLastPathComponent() == expectedDirectory,
          let assetID = attachment.asset_id,
          isManagedAssetName(standardizedURL.lastPathComponent, assetID: assetID)
    else {
      throw IMessageAttachmentPreparationError.invalidSnapshot
    }

    let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    let homeFD = Darwin.open(AppStoragePaths.homeDirectory.path, directoryFlags)
    guard homeFD >= 0 else { throw IMessageAttachmentPreparationError.invalidSnapshot }
    defer { Darwin.close(homeFD) }
    let transportFD = Darwin.openat(homeFD, ".messages-mcp", directoryFlags)
    guard transportFD >= 0 else { throw IMessageAttachmentPreparationError.invalidSnapshot }
    defer { Darwin.close(transportFD) }
    let attachmentsFD = Darwin.openat(transportFD, "draft-attachments", directoryFlags)
    guard attachmentsFD >= 0 else { throw IMessageAttachmentPreparationError.invalidSnapshot }
    defer { Darwin.close(attachmentsFD) }
    let draftFD = Darwin.openat(attachmentsFD, draftId, directoryFlags)
    guard draftFD >= 0 else { throw IMessageAttachmentPreparationError.invalidSnapshot }
    defer { Darwin.close(draftFD) }
    let sourceFD = Darwin.openat(draftFD, standardizedURL.lastPathComponent, O_RDONLY | O_NOFOLLOW)
    guard sourceFD >= 0 else { throw IMessageAttachmentPreparationError.invalidSnapshot }
    defer { Darwin.close(sourceFD) }

    var sourceStat = stat()
    guard fstat(sourceFD, &sourceStat) == 0,
          (sourceStat.st_mode & S_IFMT) == S_IFREG,
          sourceStat.st_size == expectedBytes
    else {
      throw IMessageAttachmentPreparationError.changedSnapshot
    }

    _ = cleanupStaleIMessageAttachmentSpools()

    let libraryFD = Darwin.openat(homeFD, "Library", directoryFlags)
    guard libraryFD >= 0 else { throw IMessageAttachmentPreparationError.spoolUnavailable }
    defer { Darwin.close(libraryFD) }
    let messagesFD = Darwin.openat(libraryFD, "Messages", directoryFlags)
    guard messagesFD >= 0 else { throw IMessageAttachmentPreparationError.spoolUnavailable }
    defer { Darwin.close(messagesFD) }

    if Darwin.mkdirat(messagesFD, "GhostieSendSpool", mode_t(0o700)) != 0 && errno != EEXIST {
      throw IMessageAttachmentPreparationError.spoolUnavailable
    }
    let spoolRootFD = Darwin.openat(messagesFD, "GhostieSendSpool", directoryFlags)
    guard spoolRootFD >= 0 else { throw IMessageAttachmentPreparationError.spoolUnavailable }
    _ = Darwin.fchmod(spoolRootFD, mode_t(0o700))

    let directoryName = UUID().uuidString.lowercased()
    guard Darwin.mkdirat(spoolRootFD, directoryName, mode_t(0o700)) == 0 else {
      Darwin.close(spoolRootFD)
      throw IMessageAttachmentPreparationError.spoolUnavailable
    }
    let directoryFD = Darwin.openat(spoolRootFD, directoryName, directoryFlags)
    guard directoryFD >= 0 else {
      _ = Darwin.unlinkat(spoolRootFD, directoryName, AT_REMOVEDIR)
      Darwin.close(spoolRootFD)
      throw IMessageAttachmentPreparationError.spoolUnavailable
    }

    let pathExtension = standardizedURL.pathExtension.lowercased()
    let safeExtension = pathExtension.range(of: "^[a-z0-9]{1,12}$", options: .regularExpression) != nil
      ? ".\(pathExtension)"
      : ""
    let fileName = "\(UUID().uuidString.lowercased())\(safeExtension)"
    let fileFD = Darwin.openat(
      directoryFD,
      fileName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW,
      mode_t(0o400)
    )
    guard fileFD >= 0 else {
      Darwin.close(directoryFD)
      _ = Darwin.unlinkat(spoolRootFD, directoryName, AT_REMOVEDIR)
      Darwin.close(spoolRootFD)
      throw IMessageAttachmentPreparationError.spoolUnavailable
    }

    var ownsSpool = true
    defer {
      if ownsSpool {
        _ = Darwin.fchflags(fileFD, 0)
        Darwin.close(fileFD)
        _ = Darwin.unlinkat(directoryFD, fileName, 0)
        Darwin.close(directoryFD)
        _ = Darwin.unlinkat(spoolRootFD, directoryName, AT_REMOVEDIR)
        Darwin.close(spoolRootFD)
      }
    }

    guard Darwin.lseek(sourceFD, 0, SEEK_SET) == 0 else {
      throw IMessageAttachmentPreparationError.changedSnapshot
    }
    var hasher = SHA256()
    var total = 0
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      let count = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(sourceFD, rawBuffer.baseAddress, rawBuffer.count)
      }
      guard count >= 0 else {
        throw IMessageAttachmentPreparationError.changedSnapshot
      }
      if count == 0 { break }
      total += count
      guard total <= expectedBytes else {
        throw IMessageAttachmentPreparationError.changedSnapshot
      }
      hasher.update(data: Data(buffer[0..<count]))
      var written = 0
      while written < count {
        let writeCount = buffer.withUnsafeBytes { rawBuffer in
          Darwin.write(fileFD, rawBuffer.baseAddress?.advanced(by: written), count - written)
        }
        guard writeCount > 0 else {
          throw IMessageAttachmentPreparationError.spoolUnavailable
        }
        written += writeCount
      }
    }
    let actualSHA = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard total == expectedBytes, actualSHA == expectedSHA else {
      throw IMessageAttachmentPreparationError.changedSnapshot
    }

    guard Darwin.fsync(fileFD) == 0,
          Darwin.fchmod(fileFD, mode_t(0o400)) == 0,
          Darwin.fchflags(fileFD, UInt32(UF_IMMUTABLE)) == 0
    else {
      throw IMessageAttachmentPreparationError.spoolUnavailable
    }
    var spoolStat = stat()
    guard fstat(fileFD, &spoolStat) == 0,
          (spoolStat.st_mode & S_IFMT) == S_IFREG,
          spoolStat.st_size == expectedBytes
    else {
      throw IMessageAttachmentPreparationError.spoolUnavailable
    }

    let fileIDPath = "/.vol/\(spoolStat.st_dev)/\(spoolStat.st_ino)"
    ownsSpool = false
    return PreparedIMessageAttachment(
      fileURL: URL(fileURLWithPath: fileIDPath),
      fileFD: fileFD,
      directoryFD: directoryFD,
      spoolRootFD: spoolRootFD,
      fileName: fileName,
      directoryName: directoryName
    )
  }

  static func cleanupIMessageAttachment(_ prepared: PreparedIMessageAttachment) {
    _ = Darwin.fchflags(prepared.fileFD, 0)
    Darwin.close(prepared.fileFD)
    _ = Darwin.unlinkat(prepared.directoryFD, prepared.fileName, 0)
    Darwin.close(prepared.directoryFD)
    _ = Darwin.unlinkat(prepared.spoolRootFD, prepared.directoryName, AT_REMOVEDIR)
    Darwin.close(prepared.spoolRootFD)
  }

  @discardableResult
  static func cleanupStaleIMessageAttachmentSpools(now: Date = Date()) -> Int {
    let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    let homeFD = Darwin.open(AppStoragePaths.homeDirectory.path, directoryFlags)
    guard homeFD >= 0 else { return 0 }
    defer { Darwin.close(homeFD) }
    var removed = 0
    let transportFD = Darwin.openat(homeFD, ".messages-mcp", directoryFlags)
    if transportFD >= 0 {
      removed += cleanupStaleSpool(parentFD: transportFD, rootName: "send-spool", now: now)
      Darwin.close(transportFD)
    }
    let libraryFD = Darwin.openat(homeFD, "Library", directoryFlags)
    if libraryFD >= 0 {
      let messagesFD = Darwin.openat(libraryFD, "Messages", directoryFlags)
      if messagesFD >= 0 {
        removed += cleanupStaleSpool(parentFD: messagesFD, rootName: "GhostieSendSpool", now: now)
        Darwin.close(messagesFD)
      }
      Darwin.close(libraryFD)
    }
    return removed
  }

  private static func isManagedAssetName(_ fileName: String, assetID: String) -> Bool {
    if fileName == assetID { return true }
    guard fileName.hasPrefix("\(assetID).") else { return false }
    let suffix = String(fileName.dropFirst(assetID.count + 1))
    return suffix.range(of: "^[a-z0-9]{1,12}$", options: .regularExpression) != nil
  }

  private static func isSafeDraftID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.range(
      of: "^[A-Za-z0-9_-]+$",
      options: .regularExpression
    ) != nil
  }

  private static func cleanupStaleSpool(parentFD: Int32, rootName: String, now: Date) -> Int {
    let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    let rootFD = Darwin.openat(parentFD, rootName, directoryFlags)
    guard rootFD >= 0 else { return 0 }
    defer { Darwin.close(rootFD) }
    var rootStat = stat()
    guard fstat(rootFD, &rootStat) == 0 else { return 0 }
    let stableRoot = "/.vol/\(rootStat.st_dev)/\(rootStat.st_ino)"
    guard let directories = try? FileManager.default.contentsOfDirectory(atPath: stableRoot) else { return 0 }

    let cutoff = now.timeIntervalSince1970 - 3600
    var removed = 0
    for directoryName in directories where directoryName != "." && directoryName != ".." {
      let directoryFD = Darwin.openat(rootFD, directoryName, directoryFlags)
      guard directoryFD >= 0 else { continue }
      var directoryStat = stat()
      guard fstat(directoryFD, &directoryStat) == 0,
            Double(directoryStat.st_mtimespec.tv_sec) < cutoff
      else {
        Darwin.close(directoryFD)
        continue
      }
      let stableDirectory = "/.vol/\(directoryStat.st_dev)/\(directoryStat.st_ino)"
      let files = (try? FileManager.default.contentsOfDirectory(atPath: stableDirectory)) ?? []
      for fileName in files where fileName != "." && fileName != ".." {
        let fileFD = Darwin.openat(directoryFD, fileName, O_RDONLY | O_NOFOLLOW)
        if fileFD >= 0 {
          _ = Darwin.fchflags(fileFD, 0)
          Darwin.close(fileFD)
        }
        _ = Darwin.unlinkat(directoryFD, fileName, 0)
      }
      Darwin.close(directoryFD)
      if Darwin.unlinkat(rootFD, directoryName, AT_REMOVEDIR) == 0 {
        removed += 1
      }
    }
    return removed
  }

  /// Write `sent_at` (+ `send_service`) into the iMessage draft's JSON on disk,
  /// matching DraftStore's path + format (`<home>/.messages-mcp/drafts/<id>.json`,
  /// atomic, 0600). Idempotent: if `sent_at` is already set, leaves the file
  /// untouched. Best-effort — the caller's `markSent` and the scheduler's durable
  /// marker remain as backstops — but on the happy path this is what closes the
  /// MCP-vs-menubar re-send window (#88), so it runs while the lock is still held.
  /// Internal (not private) so the lock-ordering test can drive it directly without
  /// spawning osascript.
  static func persistIMessageSentAt(draftId: String, service: String) {
    _ = mutateIMessageDraftJSON(draftId: draftId) { obj in
      // Already sent on disk means idempotent no-op. Keep the first service.
      if let existing = obj["sent_at"] as? String, !existing.isEmpty { return false }
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      obj["sent_at"] = f.string(from: Date())
      obj["send_service"] = service
      return true
    }
  }

  /// Extracts the chat GUID from a group draft's canonical `to_handle` binding
  /// ("imessage-group:<guid>"), or nil for pending bindings or non-group handles.
  /// Used to recover the send target when `imessage_group` failed to decode.
  static func groupChatGUID(from handle: String) -> String? {
    let prefix = "imessage-group:"
    guard handle.hasPrefix(prefix) else { return nil }
    let guid = String(handle.dropFirst(prefix.count))
    return guid.isEmpty ? nil : guid
  }

  static func bodySHA256(_ body: String) -> String {
    SHA256.hash(data: Data(body.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func appendIMessageSendAudit(
    sendID: String,
    target: MessageSendTarget,
    body: String,
    service: String
  ) {
    let root = AppStoragePaths.homeDirectory.appendingPathComponent(".messages-mcp", isDirectory: true)
    let url = root.appendingPathComponent("send-audit.log")
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let entry: [String: Any] = [
        "ts": Int(Date().timeIntervalSince1970 * 1000),
        "draft_id": sendID,
        "to_handle": target.handle,
        "body_sha256": bodySHA256(body),
        "service": service
      ]
      let data = try JSONSerialization.data(withJSONObject: entry, options: [])
      var line = data
      line.append(0x0a)
      if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      } else {
        try line.write(to: url, options: .atomic)
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Best-effort metadata audit only. Never block a successful platform send
      // because the sidecar log could not be appended.
    }
  }

  private static let script = """
  on run argv
    set theAddress to item 1 of argv
    set theMessage to item 2 of argv
    tell application "Messages"
      try
        set theService to first service whose service type is iMessage
        set theBuddy to buddy theAddress of theService
        send theMessage to theBuddy
        return "iMessage"
      on error errMsg number errNum
        try
          set rcsService to first service whose service type is RCS
          set rcsBuddy to buddy theAddress of rcsService
          send theMessage to rcsBuddy
          return "RCS"
        on error rcsErr number rcsNum
          try
            set smsService to first service whose service type is SMS
            set smsBuddy to buddy theAddress of smsService
            send theMessage to smsBuddy
            return "SMS"
          on error smsErr number smsNum
            return "ERROR: iMessage=" & errMsg & " (errNum=" & errNum & "); RCS=" & rcsErr & " (errNum=" & rcsNum & "); SMS=" & smsErr & " (errNum=" & smsNum & ")"
          end try
        end try
      end try
    end tell
  end run
  """

  /// Non-iMessage-first buddy cascade: RCS → SMS → iMessage. Used only when
  /// Apple's identity service (IDS) says the recipient is NOT on iMessage and
  /// there's no existing addressable chat to send into (e.g. an `any;-;<handle>`
  /// thread, which `chat id` can't target). Strictly additive vs. the default
  /// `script`: the same three transports are tried, just led by the one IDS says
  /// is correct, with the iMessage attempt kept LAST as the macOS auto-route
  /// safety net (that path is what delivers the no-IDS case today).
  private static let nonIMessageFirstScript = """
  on run argv
    set theAddress to item 1 of argv
    set theMessage to item 2 of argv
    tell application "Messages"
      try
        set rcsService to first service whose service type is RCS
        set rcsBuddy to buddy theAddress of rcsService
        send theMessage to rcsBuddy
        return "RCS"
      on error rcsErr number rcsNum
        try
          set smsService to first service whose service type is SMS
          set smsBuddy to buddy theAddress of smsService
          send theMessage to smsBuddy
          return "SMS"
        on error smsErr number smsNum
          try
            set imService to first service whose service type is iMessage
            set imBuddy to buddy theAddress of imService
            send theMessage to imBuddy
            return "iMessage"
          on error imErr number imNum
            return "ERROR: RCS=" & rcsErr & " (errNum=" & rcsNum & "); SMS=" & smsErr & " (errNum=" & smsNum & "); iMessage=" & imErr & " (errNum=" & imNum & ")"
          end try
        end try
      end try
    end tell
  end run
  """

  /// Group sends target the chat itself ("iMessage;+;chat…") — Messages.app
  /// resolves existing multi-party threads by chat id where buddy targeting
  /// can't. No SMS fallback: group MMS via Continuity routes through the
  /// same chat id.
  private static let groupScript = """
  on run argv
    set theChatId to item 1 of argv
    set theMessage to item 2 of argv
    tell application "Messages"
      try
        send theMessage to chat id theChatId
        return "iMessage"
      on error errMsg number errNum
        return "ERROR: chat send=" & errMsg & " (errNum=" & errNum & ")"
      end try
    end tell
  end run
  """

  /// Creates a brand-new group chat (no pre-existing chat id) and sends into
  /// it. The service is dispatched as a STRING and branched to per-service
  /// `whose service type is …` clauses INSIDE the `tell application "Messages"`
  /// block: Messages' enum terminology (iMessage/RCS/SMS) only resolves inside
  /// a tell block, so referencing the bare enums from `on run` raises
  /// ERR -2753 ("The variable iMessage is not defined") at hold-to-fire time.
  private static let groupCreateScript = """
  on splitLines(theText)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to linefeed
    set theItems to text items of theText
    set AppleScript's text item delimiters to oldDelimiters
    return theItems
  end splitLines

  on sendGroupWithService(serviceName, rawRecipients, theMessage)
    tell application "Messages"
      if serviceName is "iMessage" then
        set theService to first service whose service type is iMessage
      else if serviceName is "RCS" then
        set theService to first service whose service type is RCS
      else
        set theService to first service whose service type is SMS
      end if
      set theParticipants to {}
      repeat with theAddress in my splitLines(rawRecipients)
        set trimmedAddress to theAddress as text
        if trimmedAddress is not "" then
          copy (buddy trimmedAddress of theService) to end of theParticipants
        end if
      end repeat
      if (count of theParticipants) is not 2 then error "expected exactly two participants"
      set theChat to make new chat with properties {account:theService, participants:theParticipants}
      send theMessage to theChat
      return true
    end tell
  end sendGroupWithService

  on run argv
    set rawRecipients to item 1 of argv
    set theMessage to item 2 of argv
    try
      my sendGroupWithService("iMessage", rawRecipients, theMessage)
      return "iMessage"
    on error imErr number imNum
      try
        my sendGroupWithService("RCS", rawRecipients, theMessage)
        return "RCS"
      on error rcsErr number rcsNum
        try
          my sendGroupWithService("SMS", rawRecipients, theMessage)
          return "SMS"
        on error smsErr number smsNum
          return "ERROR: group iMessage=" & imErr & " (errNum=" & imNum & "); RCS=" & rcsErr & " (errNum=" & rcsNum & "); SMS=" & smsErr & " (errNum=" & smsNum & ")"
        end try
      end try
    end try
  end run
  """

  private static let buddyFileScript = """
  on run argv
    set theAddress to item 1 of argv
    set theFile to POSIX file (item 2 of argv) as alias
    tell application "Messages"
      try
        set theService to first service whose service type is iMessage
        set theBuddy to buddy theAddress of theService
        send theFile to theBuddy
        return "iMessage"
      on error errMsg number errNum
        try
          set rcsService to first service whose service type is RCS
          set rcsBuddy to buddy theAddress of rcsService
          send theFile to rcsBuddy
          return "RCS"
        on error rcsErr number rcsNum
          try
            set smsService to first service whose service type is SMS
            set smsBuddy to buddy theAddress of smsService
            send theFile to smsBuddy
            return "SMS"
          on error smsErr number smsNum
            return "ERROR: iMessage=" & errMsg & " (errNum=" & errNum & "); RCS=" & rcsErr & " (errNum=" & rcsNum & "); SMS=" & smsErr & " (errNum=" & smsNum & ")"
          end try
        end try
      end try
    end tell
  end run
  """

  private static let groupFileScript = """
  on run argv
    set theChatId to item 1 of argv
    set theFile to POSIX file (item 2 of argv) as alias
    tell application "Messages"
      try
        send theFile to chat id theChatId
        return "iMessage"
      on error errMsg number errNum
        return "ERROR: chat file send=" & errMsg & " (errNum=" & errNum & ")"
      end try
    end tell
  end run
  """

  // MARK: - WhatsApp path

  /// Approve + send via the WhatsApp daemon over its Unix socket. The
  /// daemon persists the resulting `sent_at` to the draft JSON; we
  /// don't write to disk here. Caller (PendingMessageBubble) MUST NOT call
  /// `store.markSent(...)` after a successful WhatsApp send — the FS
  /// watcher takes care of it. (Calling markSent on a WhatsApp draft
  /// would throw `platformMismatch` regardless.)
  private static func sendWhatsApp(draft: Draft) async -> SendResult {
    let started = Date()
    do {
      _ = try await WhatsAppRPCClient.approveDraft(
        id: draft.id,
        expectedPayloadDigest: draft.deliveryPayloadDigest
      )
      let result = try await WhatsAppRPCClient.sendDraft(id: draft.id)
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      if result.ok {
        return SendResult(ok: true, service: "WhatsApp", error: nil, durationMs: elapsed, messageId: result.message_id)
      } else {
        return SendResult(ok: false, service: nil, error: "daemon returned ok=false", durationMs: elapsed)
      }
    } catch let e as WhatsAppRPCClient.RPCError {
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      return SendResult(ok: false, service: nil, error: e.userFacingMessage, durationMs: elapsed)
    } catch {
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      return SendResult(ok: false, service: nil, error: error.localizedDescription, durationMs: elapsed)
    }
  }

  private static func sendWhatsAppDirect(threadJID: String, body: String) async -> SendResult {
    let started = Date()
    do {
      let result = try await WhatsAppRPCClient.sendDirectMessage(threadJID: threadJID, body: body)
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      if result.ok {
        return SendResult(ok: true, service: "WhatsApp", error: nil, durationMs: elapsed, messageId: result.message_id)
      } else {
        return SendResult(ok: false, service: nil, error: "daemon returned ok=false", durationMs: elapsed)
      }
    } catch let e as WhatsAppRPCClient.RPCError {
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      return SendResult(ok: false, service: nil, error: e.userFacingMessage, durationMs: elapsed)
    } catch {
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      return SendResult(ok: false, service: nil, error: error.localizedDescription, durationMs: elapsed)
    }
  }

  // MARK: - iMessage path

  /// Preferred 1:1 send: resolve the existing chat for this handle and send
  /// into it by `chat id`, so the chat's own service (iMessage/SMS/RCS) routes
  /// the message — the same reliable path group sends use. Falls back to the
  /// buddy cascade only when no chat exists yet (a brand-new conversation, where
  /// there's no thread/service to honor). This is the SMS-routing fix: buddy
  /// targeting on the iMessage service silently fails to deliver to SMS-only
  /// contacts (the buddy lookup doesn't error, so the SMS fallback never fires).
  private static func sendIMessageDirect(toHandle: String, body: String) async -> SendResult {
    if let resolved = IMessageDirectChatResolver().resolveDirectChat(handle: toHandle),
       IMessageDirectChatResolver.isAddressableChatGUID(resolved.chatGUID) {
      let raw = await runOSAScript(groupScript, args: [resolved.chatGUID, body])
      guard raw.ok else { return raw }
      return SendResult(
        ok: true,
        service: serviceFromChatGUID(resolved.chatGUID),
        error: nil,
        durationMs: raw.durationMs,
        messageId: raw.messageId
      )
    }
    // No addressable chat to send into (a brand-new conversation, or an unbound
    // `any;-;<handle>` thread that `chat id` can't target — the case that
    // silently fails for non-iMessage contacts like an RCS-only number). Default
    // stays the iMessage-first buddy cascade. Transport-aware routing is always
    // on: ask IDS who is actually on iMessage and, for a confident not-iMessage
    // verdict, lead with RCS/SMS instead (iMessage remains the last attempt, so
    // this can only add a better-ordered try, never remove the current one).
    //
    // Cap the IDS lookup at 2s (vs. the 8s default): this is an inline lookup on
    // the send the user is actively waiting for, and a timeout returns `.unknown`,
    // which falls through to the iMessage-first buddy cascade below — so a slow or
    // hung IDS query degrades to today's behavior instead of stalling the send.
    var ids = IDSCapability()
    ids.timeout = 2
    let verdict = (await ids.status(for: [toHandle]))[toHandle] ?? .unknown
    if noChatSendStrategy(verdict: verdict) == .nonIMessageFirst {
      return await runOSAScript(nonIMessageFirstScript, args: [toHandle, body])
    }
    return await sendIMessage(toHandle: toHandle, body: body)
  }

  /// Pure routing decision for the no-existing-chat case (unit-tested). Only a
  /// confident "not on iMessage" verdict reorders the cascade; `.iMessage` and
  /// `.unknown` keep today's iMessage-first behavior.
  enum NoChatStrategy: Equatable { case buddyCascade, nonIMessageFirst }
  static func noChatSendStrategy(verdict: IDSVerdict) -> NoChatStrategy {
    verdict == .notIMessage ? .nonIMessageFirst : .buddyCascade
  }

  /// Non-blocking post-send check. A short while after a send returns ok, read
  /// chat.db to see whether the message actually went through. If it errored —
  /// a silent bounce, where the AppleScript send "succeeded" but Messages
  /// couldn't deliver — record it so the failure is no longer invisible.
  /// Detached so it never delays the send the user sees.
  private static func confirmDeliveryInBackground(handle: String, sentAt: Date, source: String) {
    Task.detached(priority: .utility) {
      guard let outcome = await IMessageDeliveryConfirmer().confirm(handle: handle, since: sentAt),
            IMessageDeliveryConfirmer.isBounce(outcome) else { return }
      SendFailureLog.record(
        platform: "imessage",
        handle: handle,
        route: "silent-bounce",
        error: "chat.db error=\(outcome.error) service=\(outcome.service ?? "?") delivered=\(outcome.isDelivered)",
        durationMs: 0,
        source: "\(source)-confirm"
      )
    }
  }

  /// Buddy-targeted send (legacy v0.2.x path). Tries iMessage → RCS → SMS. Now
  /// only the brand-new-conversation fallback for `sendIMessageDirect`, since
  /// for existing threads chat-id routing is more reliable.
  private static func sendIMessage(toHandle: String, body: String) async -> SendResult {
    await runOSAScript(script, args: [toHandle, body])
  }

  /// "iMessage" | "SMS" | "RCS" parsed from a chat GUID's service prefix
  /// ("SMS;-;+1555…", "iMessage;-;…", "iMessage;+;chat…"). Defaults to
  /// "iMessage" when the prefix is missing or unrecognized.
  static func serviceFromChatGUID(_ guid: String) -> String {
    let prefix = guid.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? ""
    switch prefix.uppercased() {
    case "SMS": return "SMS"
    case "RCS": return "RCS"
    default: return "iMessage"
    }
  }

  private static func sendIMessageGroup(group: IMessageGroupDraftTarget, body: String) async -> SendResult {
    do {
      try IMessageGroupTargetPolicy.validateTwoParticipantTarget(group.participant_handles)
    } catch {
      return SendResult(ok: false, service: nil, error: error.localizedDescription, durationMs: 0)
    }
    if let chatGUID = group.chat_guid?.trimmingCharacters(in: .whitespacesAndNewlines),
       !chatGUID.isEmpty {
      return await runOSAScript(groupScript, args: [chatGUID, body])
    }
    // No chat id was known at stage time. Re-resolve against chat.db right
    // before sending — the user may have started the thread since staging,
    // and sending into an existing chat by id is far more reliable than
    // `make new chat`. (We're already off the main actor here.)
    if let resolved = IMessageGroupResolver().resolveExactGroup(participantHandles: group.participant_handles) {
      return await runOSAScript(groupScript, args: [resolved.chatGUID, body])
    }
    let result = await runOSAScript(groupCreateScript, args: [group.participant_handles.joined(separator: "\n"), body])
    if result.ok { return result }
    // Graceful degrade: modern Messages builds sometimes refuse `make new
    // chat` entirely. Tell the user the one reliable path instead of
    // surfacing raw AppleScript errors.
    let people = group.displayName
    let who = people.isEmpty ? "this group" : people
    let detail = result.error.map { " (\($0))" } ?? ""
    return SendResult(
      ok: false,
      service: nil,
      error: "Messages couldn't start a new group thread with \(who). Send one quick message to that group from the Messages app first, then come back and approve this draft. It will find the existing thread and send right in.\(detail)",
      durationMs: result.durationMs
    )
  }

  /// Shared osascript runner for every Messages.app send variant (buddy or
  /// chat id, text or file). Same timeout + output contract as the original
  /// single-buddy path.
  fileprivate static func runOSAScript(_ scriptSource: String, args: [String]) async -> SendResult {
    let started = Date()
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", scriptSource] + args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let timeoutWork = DispatchWorkItem {
          if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

        do {
          try process.run()
          process.waitUntilExit()
          timeoutWork.cancel()
        } catch {
          let elapsed = Int(Date().timeIntervalSince(started) * 1000)
          continuation.resume(returning: SendResult(
            ok: false, service: nil,
            error: "osascript spawn failed: \(error.localizedDescription)",
            durationMs: elapsed
          ))
          return
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        if process.terminationStatus != 0 {
          continuation.resume(returning: SendResult(
            ok: false, service: nil,
            error: stderr.isEmpty ? "osascript exited with code \(process.terminationStatus)" : stderr,
            durationMs: elapsed
          ))
          return
        }

        if stdout == "iMessage" || stdout == "RCS" || stdout == "SMS" {
          continuation.resume(returning: SendResult(
            ok: true, service: stdout, error: nil, durationMs: elapsed
          ))
          return
        }

        continuation.resume(returning: SendResult(
          ok: false, service: nil,
          error: stdout.isEmpty ? "unknown osascript output" : stdout,
          durationMs: elapsed
        ))
      }
    }
  }
}
