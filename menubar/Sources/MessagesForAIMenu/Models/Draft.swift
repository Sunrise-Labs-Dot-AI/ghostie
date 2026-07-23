import Foundation
import CryptoKit

/// Which transport this draft targets. Read from the draft JSON's
/// `platform` field; defaults to `.imessage` when the field is absent
/// (back-compat with pre-v0.3.0 drafts in `~/.messages-mcp/drafts/`).
///
/// Encoded as a lowercase string in JSON (`"imessage"` / `"whatsapp"`)
/// to match the TypeScript side's serialization.
enum Platform: String, Codable, Equatable, CaseIterable, Hashable {
  case imessage
  case whatsapp
}

/// Whether a WhatsApp draft has been approved for send by the user in
/// the menubar. iMessage drafts don't carry this field on disk — the
/// approval signal is conveyed entirely by the hold-to-fire UX. For
/// WhatsApp the daemon refuses send until `approval_state == "approved"`.
enum ApprovalState: String, Codable, Equatable {
  case pending
  case approved
}

/// Durable multipart-send checkpoint. A sender advances this only after a part
/// is known to have completed; `ambiguous_part` records the part that may have
/// crossed the transport boundary before a failure was observed.
struct DraftDeliveryProgress: Codable, Equatable {
  let completed_attachment_count: Int
  let body_sent: Bool
  let ambiguous_part: String?
}

/// Post-send reconciliation verdict, written AFTER `sent_at` once chat.db
/// reveals what actually happened on the wire. Messages accepting an enqueue is
/// not delivery: a throttled attachment upload is rejected asynchronously
/// (`message.error != 0`) long after osascript returned ok, so a send can look
/// completely clean and still have dropped most of its photos. Absent on drafts
/// that were never reconciled and on runs where every part landed.
struct DraftDeliveryFailure: Codable, Equatable {
  /// Parts from the reconciled run that chat.db reported as errored.
  let failed_part_count: Int
  /// Parts actually dispatched by that run. NOT the whole manifest: a resumed
  /// send replays only what was still pending, so this is the honest
  /// denominator for "N of M didn't send".
  let dispatched_part_count: Int
  let reconciled_at: String
}

// Mirrors the on-disk JSON written by either MCP server's stage_draft
// tool:
//   - iMessage: `~/.messages-mcp/drafts/{uuid}.json`,
//     TS source `src/storage/drafts.ts` in messages-for-ai repo
//   - WhatsApp: `~/.whatsapp-mcp/drafts/{uuid}.json`,
//     TS source `src/storage/drafts.ts` in whatsapp-mcp repo
//
// Fields present only on one platform are Optional; Swift's synthesized
// `init(from:)` treats absent JSON keys as nil for Optional properties,
// so the same struct decodes both shapes without conditional logic.
struct Draft: Codable, Identifiable, Equatable {
  let id: String
  let to_handle: String
  // Contact name resolved from macOS AddressBook at stage time. Null for
  // unknown handles or when AddressBook was unreadable (FDA not granted).
  // Older drafts that predate this field decode as nil automatically via
  // Swift's synthesized Codable init.
  let to_handle_name: String?
  /// Optional iMessage group target. Babysitter uses this to keep partner-CC
  /// outreach in a thread with exactly one sitter plus the selected partner.
  /// Absent on all legacy and ordinary single-recipient drafts.
  let imessage_group: IMessageGroupDraftTarget?
  let body: String
  /// Files staged to send with this draft (photos/videos/documents). Written
  /// by the MCP `stage_draft` tools; nil/empty on text-only drafts and on
  /// drafts that predate media support. Senders verify the managed manifest
  /// and its content hashes again at fire time.
  let attachments: [DraftAttachment]?
  /// Durable checkpoint for a multipart delivery. Absent on drafts that have
  /// never begun delivery and on legacy text-only drafts.
  let delivery_progress: DraftDeliveryProgress?
  /// What chat.db said actually happened after the send returned. Set only when
  /// reconciliation found errored parts, so a non-nil value always means
  /// "something the user thought was sent did not arrive".
  let delivery_failure: DraftDeliveryFailure?
  let in_reply_to_thread_id: Int?
  let staged_at: String
  let sent_at: String?
  let send_service: String?
  // Free-form provenance label set by the staging agent ("Claude Desktop
  // / morning triage", etc.). Older drafts may not have this field —
  // Swift's synthesized init(from:) treats a missing key as nil for
  // Optional properties (in modern Swift), so this is back-compat safe.
  let source: String?
  // Snapshot of the last few messages in the recipient's thread, captured
  // at stage time by the MCP server. Chronological (oldest first). Null
  // for older drafts or when no matching thread was found.
  let context_messages: [ContextMessage]?
  // Structured breadcrumb of how the context lookup went. Surfaced in
  // the menu bar's Details disclosure so an empty context_messages is
  // self-explaining ("no chat for this handle", "no handle match", etc.).
  let context_diagnostic: ContextDiagnostic?
  // ── Approve-now/send-later (schedule-send) — additive, all Optional ─────────
  /// When set, the menu-bar scheduler fires this draft at/after this instant
  /// instead of waiting for hold-to-fire. Absent on ordinary drafts.
  let scheduled_send_at: String?
  /// Set when the scheduler declined to send a due scheduled draft —
  /// "quiet_hours" or "stale". The Scheduled view lets the user resolve it.
  let schedule_hold_reason: String?
  /// Request to send a held/scheduled draft immediately, bypassing quiet hours.
  let override_send: Bool?
  /// GUI-approval gate: the scheduler only auto-sends a scheduled draft when this
  /// is true (set by the in-app Schedule button). A scheduled draft without it is
  /// held for explicit approval, never silently sent.
  let schedule_approved: Bool?
  /// HMAC tag authenticating that `schedule_approved` / `override_send` were set
  /// by a real GUI action, bound to this draft's complete delivery digest. The
  /// scheduler verifies this (or a same-session GUI approval) before auto-sending
  /// — a file that merely flips `schedule_approved`/`override_send` on disk has no
  /// valid tag and is held. See ApprovalAuthenticator + issue #77.
  let schedule_approval_tag: String?

  // ── WhatsApp-specific fields (Optional for iMessage drafts) ──────────
  /// Written by the WhatsApp MCP's `stage_draft`. Currently always `1`.
  /// Reserved so the menubar can refuse drafts written by a future
  /// daemon version it doesn't understand (forward-compat).
  let schema_version: Int?
  /// Raw transport tag from the JSON `platform` field. Optional because
  /// iMessage drafts predate the field. Callers should usually go
  /// through `effectivePlatform` instead — it returns a non-Optional
  /// `Platform` with `.imessage` as the default for legacy drafts.
  let platform: Platform?
  /// Whether the user has tapped "approve" on the WhatsApp draft in the
  /// menubar. iMessage drafts don't write this field; for those, the
  /// effective state is conveyed by the hold-to-fire interaction itself.
  let approval_state: ApprovalState?
  /// True when the WhatsApp daemon staged this draft within 60 s of an
  /// inbound message from a non-contact sender. The menubar uses this
  /// to raise the hold-to-fire duration from 1 s to 2 s — a safety
  /// nudge against prompt-injection-driven drafts induced by an
  /// unknown sender. Absent / false on iMessage drafts.
  let induced_by_unknown_contact: Bool?
  /// WhatsApp reply-draft: the message id (stanzaId) this draft quotes,
  /// or nil for an ordinary message / iMessage drafts. The daemon
  /// reconstructs the quote from this at send time; the menubar only
  /// displays it.
  let quoted_message_id: String?
  /// Stage-time snapshot of the quoted message, for the "Replying to …"
  /// callout. nil when the draft isn't a reply. Absent on iMessage drafts.
  let quoted_preview: QuotedPreview?

  // ── Cross-device relay (SUN-613) — additive, Optional ──────────────────────
  /// Which machine is permitted to execute this draft, as a `DeviceIdentity`
  /// device id. Absent on every ordinary local draft, which keeps today's
  /// behavior exactly: no stamp means no routing restriction.
  ///
  /// When present, EVERY send path refuses unless it matches the local device
  /// id — the Swift `DraftSender` here, and the `send_draft` /
  /// `send_whatsapp_draft` MCP tools on the TypeScript side. That is the point:
  /// each Mac runs two independent senders, so a gate that only covered this
  /// process would still leave the other Mac's MCP free to fire the same draft.
  ///
  /// Deliberately NOT part of `deliveryPayloadDigest`. It is routing metadata,
  /// not delivery semantics: it changes WHICH MACHINE sends, never WHO receives
  /// WHAT. Binding it into the digest would invalidate every already-minted
  /// schedule-approval tag on upgrade (holding pending scheduled drafts for
  /// re-approval) while adding no protection against the actual threat — a
  /// local process that rewrites this field still cannot forge an approval, and
  /// `DraftSender` re-reads the draft under the send lock so the routing check
  /// runs against on-disk state rather than a reviewed snapshot.
  let relay_executor: String?

  init(
    id: String,
    to_handle: String,
    to_handle_name: String?,
    imessage_group: IMessageGroupDraftTarget? = nil,
    body: String,
    attachments: [DraftAttachment]? = nil,
    delivery_progress: DraftDeliveryProgress? = nil,
    delivery_failure: DraftDeliveryFailure? = nil,
    in_reply_to_thread_id: Int?,
    staged_at: String,
    sent_at: String?,
    send_service: String?,
    source: String?,
    context_messages: [ContextMessage]?,
    context_diagnostic: ContextDiagnostic?,
    scheduled_send_at: String?,
    schedule_hold_reason: String?,
    override_send: Bool?,
    schedule_approved: Bool?,
    schedule_approval_tag: String?,
    schema_version: Int?,
    platform: Platform?,
    approval_state: ApprovalState?,
    induced_by_unknown_contact: Bool?,
    quoted_message_id: String?,
    quoted_preview: QuotedPreview?,
    // Defaulted so the 14 existing call sites keep compiling unchanged. Every
    // site that ROUND-TRIPS an existing draft passes it explicitly — dropping it
    // silently on a rewrite would erase the executor stamp and reopen the
    // duplicate-send hole this field exists to close.
    relay_executor: String? = nil
  ) {
    self.id = id
    self.to_handle = to_handle
    self.to_handle_name = to_handle_name
    self.imessage_group = imessage_group
    self.body = body
    self.attachments = attachments
    self.delivery_progress = delivery_progress
    self.delivery_failure = delivery_failure
    self.in_reply_to_thread_id = in_reply_to_thread_id
    self.staged_at = staged_at
    self.sent_at = sent_at
    self.send_service = send_service
    self.source = source
    self.context_messages = context_messages
    self.context_diagnostic = context_diagnostic
    self.scheduled_send_at = scheduled_send_at
    self.schedule_hold_reason = schedule_hold_reason
    self.override_send = override_send
    self.schedule_approved = schedule_approved
    self.schedule_approval_tag = schedule_approval_tag
    self.schema_version = schema_version
    self.platform = platform
    self.approval_state = approval_state
    self.induced_by_unknown_contact = induced_by_unknown_contact
    self.quoted_message_id = quoted_message_id
    self.quoted_preview = quoted_preview
    self.relay_executor = relay_executor
  }

  /// Effective transport. Returns the stored `platform` if present, or
  /// `.imessage` as the back-compat default for legacy drafts that
  /// predate the field. Always non-nil — call sites can `switch` on
  /// this without an Optional dance.
  var effectivePlatform: Platform { platform ?? .imessage }

  var isSent: Bool { sent_at != nil }

  /// A draft with a future-or-pending scheduled send that hasn't fired yet.
  var isScheduled: Bool { scheduled_send_at != nil && sent_at == nil }
  /// A scheduled draft the scheduler declined to send (quiet hours / stale).
  var isHeld: Bool { isScheduled && (schedule_hold_reason != nil) }
  var scheduledDate: Date? {
    guard let s = scheduled_send_at else { return nil }
    return Self.parseISO(s)
  }

  /// The WhatsApp daemon writes `approval_state: "approved"` on the
  /// draft JSON when the user confirms in the menubar. iMessage drafts
  /// never write this field. This computed flag answers "should the
  /// menubar present this as ready-to-fire?" uniformly across both
  /// platforms.
  var isApproved: Bool { approval_state == .approved }

  /// Scope label bound into a scheduled draft's approval HMAC.
  static let scheduleApprovalScope = "schedule_approved"

  /// Scope actually bound for THIS draft. Unstamped drafts use the bare label,
  /// so every approval tag minted before the relay existed stays valid — that
  /// back-compat is the whole reason `relay_executor` is not in
  /// `deliveryPayloadDigest`.
  ///
  /// A STAMPED draft binds its executor here instead. Without this, a valid
  /// approval survives an executor change, and the tag does not have to be
  /// forged to be abused — it already exists. Concretely: the relay assigns a
  /// scheduled draft to Mac B, a stale or hostile local writer flips
  /// `relay_executor` back to A, A's scheduler still verifies the old tag and
  /// auto-sends without a new review, and B may send too. Binding the executor
  /// into the scope makes any reassignment invalidate the approval, which is
  /// the fail-closed direction. (Second-lane review, finding 4.)
  var scheduleApprovalScopeForDraft: String {
    guard let raw = relay_executor else { return Self.scheduleApprovalScope }
    let executor = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executor.isEmpty else { return Self.scheduleApprovalScope }
    return "\(Self.scheduleApprovalScope)|executor=\(executor)"
  }

  /// Canonical message the schedule-approval tag must cover for THIS draft.
  var scheduleApprovalCanonicalMessage: String {
    ApprovalAuthenticator.canonicalMessage(
      id: id,
      recipient: approvalRecipientBinding,
      body: deliveryPayloadDigest,
      scope: scheduleApprovalScopeForDraft
    )
  }

  var approvalRecipientBinding: String {
    imessage_group?.canonicalRecipient ?? to_handle
  }

  /// SHA-256 over the complete ordered delivery semantics. Each component is
  /// UTF-8 length-prefixed before joining, so delimiters and multi-byte text
  /// cannot produce an ambiguous representation.
  var deliveryPayloadDigest: String {
    var components = [
      "ghostie-draft-payload-v1",
      id,
      effectivePlatform.rawValue,
      approvalRecipientBinding,
      body,
      quoted_message_id ?? "",
      scheduled_send_at ?? "",
      String(attachments?.count ?? 0)
    ]
    for attachment in attachments ?? [] {
      components.append(contentsOf: [
        attachment.asset_id ?? "",
        attachment.path,
        attachment.filename ?? "",
        attachment.mime_type ?? "",
        String(attachment.byte_count ?? -1),
        attachment.sha256 ?? ""
      ])
    }
    let canonical = components
      .map { "\($0.utf8.count):\($0)" }
      .joined(separator: "|")
    return SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /// A non-nil result means the media manifest predates managed immutable
  /// snapshots, or is malformed, and must be re-staged before approval. Legacy
  /// text-only drafts remain valid.
  var attachmentReviewIssue: String? {
    guard let attachments, !attachments.isEmpty else { return nil }
    let maximumAttachmentCount = 10
    let maximumAttachmentBytes = 100 * 1024 * 1024
    let maximumDraftAttachmentBytes = 250 * 1024 * 1024
    guard attachments.count <= maximumAttachmentCount else {
      return "This draft has more than 10 attachments. Re-stage it with fewer files before sending."
    }
    guard !id.isEmpty, id != ".", id != "..", !id.contains("/") else {
      return "This draft has an invalid attachment owner. Re-stage it before sending."
    }

    let storageRoot = effectivePlatform == .imessage ? ".messages-mcp" : ".whatsapp-mcp"
    let expectedDirectory = AppStoragePaths.homeDirectory
      .appendingPathComponent(storageRoot, isDirectory: true)
      .appendingPathComponent("draft-attachments", isDirectory: true)
      .appendingPathComponent(id, isDirectory: true)
      .standardizedFileURL
    var aggregateBytes = 0
    for (index, attachment) in attachments.enumerated() {
      let number = index + 1
      guard let assetID = attachment.asset_id,
            assetID.range(
              of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$",
              options: .regularExpression
            ) != nil
      else {
        return "Attachment \(number) is missing its managed asset ID. Re-stage this draft before sending."
      }
      guard let sha256 = attachment.sha256,
            sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
      else {
        return "Attachment \(number) is missing a valid SHA-256 fingerprint. Re-stage this draft before sending."
      }
      guard let byteCount = attachment.byte_count, byteCount >= 0 else {
        return "Attachment \(number) is missing a valid byte count. Re-stage this draft before sending."
      }
      guard byteCount <= maximumAttachmentBytes else {
        return "Attachment \(number) exceeds the 100 MB limit. Re-stage it with a smaller file."
      }
      let (newAggregate, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
      guard !overflow, newAggregate <= maximumDraftAttachmentBytes else {
        return "This draft's attachments exceed the 250 MB limit. Re-stage it with fewer or smaller files."
      }
      aggregateBytes = newAggregate
      let expandedPath = (attachment.path as NSString).expandingTildeInPath
      let standardizedURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
      let managedName = standardizedURL.lastPathComponent
      let managedExtension = managedName.hasPrefix("\(assetID).")
        ? String(managedName.dropFirst(assetID.count + 1))
        : ""
      let validManagedName = managedName == assetID || (
        managedExtension.range(of: "^[a-z0-9]{1,12}$", options: .regularExpression) != nil
      )
      guard expandedPath.hasPrefix("/"),
            standardizedURL.deletingLastPathComponent() == expectedDirectory,
            validManagedName
      else {
        return "Attachment \(number) is outside this draft's managed storage. Re-stage it before sending."
      }
    }
    return nil
  }

  /// Why this machine may not execute this draft, or nil when it may.
  ///
  /// Pure so both the fast pre-lock check and the authoritative under-lock
  /// re-check in `DraftSender` share one rule, and so the three cases below can
  /// be pinned by tests without touching the filesystem.
  ///
  ///   - no stamp            → allowed (every draft that exists today)
  ///   - stamp, id unreadable → REFUSED, fail closed. "I cannot prove I am the
  ///     executor" must never resolve to "so I'll send it."
  ///   - stamp != local id   → REFUSED, this draft belongs to another Mac.
  /// Case table, mirrored EXACTLY by `executorRefusal` in
  /// `mcps/shared/src/device-id.ts`. A divergence between the two is a
  /// duplicate send.
  ///
  ///   absent / JSON null   → allowed (every draft that exists today)
  ///   present but unusable → REFUSED. Empty, whitespace, or outside the
  ///     device-id alphabet. Routing data we cannot parse is a reason to stop,
  ///     not to guess. (An earlier version trimmed-then-treated-as-unstamped,
  ///     which failed OPEN on a whitespace stamp. Second-lane review, finding 6.)
  ///   local id unreadable  → REFUSED, fail closed.
  ///   stamp != local id    → REFUSED, belongs to another Mac.
  func executorRefusal(localDeviceID: String?) -> String? {
    guard let raw = relay_executor else { return nil }
    let executor = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executor.isEmpty, DeviceIdentity.isValidDeviceID(executor) else {
      return "This draft's Mac assignment is unreadable, so Ghostie won't send it from here. Re-stage it."
    }
    guard let localDeviceID, DeviceIdentity.isValidDeviceID(localDeviceID) else {
      return "Ghostie can't confirm which Mac this draft belongs to, so it won't send it from here."
    }
    guard executor == localDeviceID else {
      return "This draft sends from another Mac. Approve it there, or on your phone, and that Mac will deliver it."
    }
    return nil
  }

  /// Copy used when a trusted GUI action authenticates the current payload.
  /// The approval tag is not part of `deliveryPayloadDigest`.
  func replacingScheduleApprovalTag(_ tag: String?) -> Draft {
    Draft(
      id: id,
      to_handle: to_handle,
      to_handle_name: to_handle_name,
      imessage_group: imessage_group,
      body: body,
      attachments: attachments,
      delivery_progress: delivery_progress,
      delivery_failure: delivery_failure,
      in_reply_to_thread_id: in_reply_to_thread_id,
      staged_at: staged_at,
      sent_at: sent_at,
      send_service: send_service,
      source: source,
      context_messages: context_messages,
      context_diagnostic: context_diagnostic,
      scheduled_send_at: scheduled_send_at,
      schedule_hold_reason: schedule_hold_reason,
      override_send: override_send,
      schedule_approved: schedule_approved,
      schedule_approval_tag: tag,
      schema_version: schema_version,
      platform: platform,
      approval_state: approval_state,
      induced_by_unknown_contact: induced_by_unknown_contact,
      quoted_message_id: quoted_message_id,
      quoted_preview: quoted_preview,
      relay_executor: relay_executor
    )
  }

  /// The scheduler's send gate for an approve-now/send-later draft (issue #77):
  /// the draft must be GUI-approved (`schedule_approved == true`) AND that
  /// approval must be authenticated — either approved in the GUI this session,
  /// or carrying a valid HMAC tag bound to every delivery-semantic field. A scheduled
  /// draft written by another process that merely sets `schedule_approved` or
  /// `override_send` has no valid tag and returns false (held for approval).
  var isScheduleAuthenticallyApproved: Bool {
    guard schedule_approved == true else { return false }
    // Recompute the canonical tag from the draft's CURRENT fields. A session
    // approval only matches when the payload digest/scope are unchanged, so
    // swapping any delivery field on disk invalidates the session gate too, not just
    // the persisted tag. (Issue #77, round 2.)
    let canonical = scheduleApprovalCanonicalMessage
    if ApprovalAuthenticator.hasSessionApproval(canonicalMessage: canonical) { return true }
    return ApprovalAuthenticator.verify(tag: schedule_approval_tag, message: canonical)
  }

  var stagedDate: Date? { Self.parseISO(staged_at) }
  var sentDate: Date? {
    guard let s = sent_at else { return nil }
    return Self.parseISO(s)
  }

  // Be tolerant of two ISO-8601 shapes we see in the wild:
  //   1. With fractional seconds:    "2026-05-14T21:46:41.064Z"   (what TS .toISOString() produces)
  //   2. Without fractional seconds: "2026-05-14T21:46:41Z"        (older drafts / hand-written test fixtures)
  // ISO8601DateFormatter rejects (2) when configured for (1) and vice
  // versa, so we try both rather than picking one and silently failing
  // half the draft files.
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
  private static func parseISO(_ s: String) -> Date? {
    withFractional.date(from: s) ?? withoutFractional.date(from: s)
  }

  static func parseISOPublic(_ s: String) -> Date? {
    parseISO(s)
  }
}

// One message in the recipient's thread, captured at stage time and
// embedded in the draft JSON. Mirrors `DraftContextMessage` on the
// TypeScript side. Identifiable for ForEach — we synthesize a stable id
// from index + sent_at since chat.db's ROWID isn't shipped.
//
// Dual-key decoding: v0.3.0/v0.3.1 WhatsApp daemons wrote `sender_jid`
// (a JID) + `ts` (unix-ms number) instead of `sender_handle` + `sent_at`
// (the names the iMessage path has always used and the menubar's Codable
// expects). v0.3.2 daemons emit the new names; the decoder below accepts
// either shape so in-flight drafts staged on the old daemon still render
// context correctly after upgrade.
//
// REMOVE after v0.3.3 ships — by then any in-flight v0.3.0/v0.3.1 WhatsApp
// drafts will have been swept by sweepDrafts() (24h sent / 7-day TTL).
// Tracked: v0.3.3 plan item "delete dual-key compat in ContextMessage."
struct MessageReaction: Codable, Hashable, Identifiable {
  enum Kind: String, Codable, CaseIterable {
    case loved
    case liked
    case disliked
    case laughed
    case emphasized
    case questioned
    case emoji
    case reacted
  }

  let kind: Kind
  let from_me: Bool
  let sender_handle: String?
  let sender_name: String?
  let sent_at: String?
  /// Custom emoji payload for iMessage 2006/3006 tapbacks or WhatsApp
  /// reactions. Standard iMessage tapbacks leave this nil and render from kind.
  let emoji: String?

  init(
    kind: Kind,
    from_me: Bool,
    sender_handle: String?,
    sender_name: String?,
    sent_at: String?,
    emoji: String? = nil
  ) {
    self.kind = kind
    self.from_me = from_me
    self.sender_handle = sender_handle
    self.sender_name = sender_name
    self.sent_at = sent_at
    self.emoji = emoji
  }

  var id: String {
    [
      kind.rawValue,
      emoji ?? "",
      from_me ? "me" : "them",
      sender_handle ?? "",
      sender_name ?? "",
      sent_at ?? ""
    ].joined(separator: "\u{1F}")
  }
}

struct ContextMessage: Codable, Hashable {
  let guid: String?
  /// Platform message identifier used for user actions in the Messages tab.
  /// For iMessage this mirrors `guid`; for WhatsApp this is the stanza id.
  let message_id: String?
  let from_me: Bool
  let sender_handle: String?
  let sender_name: String?
  let body: String?
  let sent_at: String?
  let reaction: MessageReaction?
  let reactions: [MessageReaction]
  /// Delivery/read receipts for outgoing iMessages, populated only by the
  /// local chat.db transcript loader. Deliberately NOT in CodingKeys: drafts
  /// JSON is a contract shared with the MCPs, so these never hit disk.
  var deliveredAt: Date? = nil
  var readAt: Date? = nil
  /// Attachments (photos, files) on this message — also loader-only and
  /// excluded from the Codable contract.
  var attachments: [MessageAttachmentRef] = []

  enum CodingKeys: String, CodingKey {
    case guid
    case message_id
    case from_me
    case sender_handle
    case sender_name
    case body
    case sent_at
    case reaction
    case reactions
    // Legacy v0.3.0/v0.3.1 WhatsApp keys — accept but never emit.
    case sender_jid
    case ts
  }

  init(
    guid: String? = nil,
    message_id: String? = nil,
    from_me: Bool,
    sender_handle: String?,
    sender_name: String?,
    body: String?,
    sent_at: String?,
    reaction: MessageReaction? = nil,
    reactions: [MessageReaction] = []
  ) {
    self.guid = guid
    self.message_id = message_id ?? guid
    self.from_me = from_me
    self.sender_handle = sender_handle
    self.sender_name = sender_name
    self.body = body
    self.sent_at = sent_at
    self.reaction = reaction
    self.reactions = reactions
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let decodedGuid = try c.decodeIfPresent(String.self, forKey: .guid)
    self.guid = decodedGuid
    self.message_id = try c.decodeIfPresent(String.self, forKey: .message_id) ?? decodedGuid
    self.from_me = try c.decode(Bool.self, forKey: .from_me)
    // Prefer the new key; fall back to the legacy one if the new one
    // is absent. Both keys present (shouldn't happen) → new wins.
    self.sender_handle = try (c.decodeIfPresent(String.self, forKey: .sender_handle)
      ?? c.decodeIfPresent(String.self, forKey: .sender_jid))
    self.sender_name = try c.decodeIfPresent(String.self, forKey: .sender_name)
    self.body = try c.decodeIfPresent(String.self, forKey: .body)
    if let isoString = try c.decodeIfPresent(String.self, forKey: .sent_at) {
      self.sent_at = isoString
    } else if let unixMs = try c.decodeIfPresent(Double.self, forKey: .ts) {
      // Legacy daemons wrote ts as unix-ms number; convert to the ISO
      // string the menubar expects. The conversion is one-way — encode
      // below always emits sent_at.
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      self.sent_at = f.string(from: Date(timeIntervalSince1970: unixMs / 1000))
    } else {
      self.sent_at = nil
    }
    self.reaction = try c.decodeIfPresent(MessageReaction.self, forKey: .reaction)
    self.reactions = try c.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(guid, forKey: .guid)
    try c.encodeIfPresent(message_id, forKey: .message_id)
    try c.encode(from_me, forKey: .from_me)
    try c.encodeIfPresent(sender_handle, forKey: .sender_handle)
    try c.encodeIfPresent(sender_name, forKey: .sender_name)
    try c.encodeIfPresent(body, forKey: .body)
    try c.encodeIfPresent(sent_at, forKey: .sent_at)
    try c.encodeIfPresent(reaction, forKey: .reaction)
    if !reactions.isEmpty {
      try c.encode(reactions, forKey: .reactions)
    }
  }

  var displayName: String {
    if from_me { return "You" }
    return sender_name ?? sender_handle ?? "Unknown"
  }

  var sentDate: Date? {
    guard let s = sent_at else { return nil }
    return Draft.parseISOPublic(s)
  }

  func attachingReactions(_ nextReactions: [MessageReaction]) -> ContextMessage {
    var copy = ContextMessage(
      guid: guid,
      message_id: message_id,
      from_me: from_me,
      sender_handle: sender_handle,
      sender_name: sender_name,
      body: body,
      sent_at: sent_at,
      reaction: reaction,
      reactions: nextReactions
    )
    copy.deliveredAt = deliveredAt
    copy.readAt = readAt
    copy.attachments = attachments
    return copy
  }
}

/// A file staged to send with an outbound draft, decoded from the draft JSON's
/// `attachments` array (written by the MCP `stage_draft` tools). Mirrors the
/// TypeScript `DraftAttachment`; the send path verifies the managed snapshot at
/// fire time.
struct DraftAttachment: Codable, Equatable, Hashable {
  let path: String
  let filename: String?
  let mime_type: String?
  let byte_count: Int?
  let asset_id: String?
  let sha256: String?

  init(
    path: String,
    filename: String?,
    mime_type: String?,
    byte_count: Int?,
    asset_id: String? = nil,
    sha256: String? = nil
  ) {
    self.path = path
    self.filename = filename
    self.mime_type = mime_type
    self.byte_count = byte_count
    self.asset_id = asset_id
    self.sha256 = sha256
  }

  /// Bridge to the read-side attachment type so staged-draft media renders
  /// through the same AttachmentBubbleView as incoming-message media.
  var asRef: MessageAttachmentRef {
    MessageAttachmentRef(path: path, mimeType: mime_type, name: filename, byteCount: byte_count ?? 0)
  }
}

/// One attachment on a chat.db message, resolved by the local transcript
/// loader. Never serialized — display-only.
struct MessageAttachmentRef: Hashable {
  let path: String?
  let mimeType: String?
  let name: String?
  let byteCount: Int
  // WhatsApp media isn't on disk until the user opens it — the daemon holds
  // the encrypted descriptor and downloads on demand. When these are set and
  // `path` is nil, the bubble shows a tap-to-load card that calls
  // WhatsAppRPCClient.downloadMedia, then renders/plays the resulting file.
  var whatsappThreadJID: String? = nil
  var whatsappMessageID: String? = nil

  /// True for a WhatsApp media attachment whose payload hasn't been fetched
  /// yet (no local `path`, but we have the coordinates to download it).
  var isDownloadableWhatsAppMedia: Bool {
    path == nil && whatsappThreadJID != nil && whatsappMessageID != nil
  }

  var isImage: Bool {
    if let mimeType, mimeType.hasPrefix("image/") { return true }
    guard let path else { return false }
    let ext = (path as NSString).pathExtension.lowercased()
    return ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"].contains(ext)
  }

  /// A video the transcript can render with a poster frame + inline player.
  /// AVFoundation-decodable container types only (the same ones Messages
  /// attaches); anything exotic falls through to the file chip.
  var isVideo: Bool {
    if let mimeType, mimeType.hasPrefix("video/") { return true }
    guard let path else { return false }
    let ext = (path as NSString).pathExtension.lowercased()
    return ["mov", "mp4", "m4v", "3gp", "avi", "mpg", "mpeg", "mkv"].contains(ext)
  }

  var resolvedURL: URL? {
    guard let path, !path.isEmpty else { return nil }
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else { return nil }
    return URL(fileURLWithPath: expanded)
  }

  var displayName: String {
    if let name, !name.isEmpty { return name }
    if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
    return "Attachment"
  }
}

extension Draft {
  // Stable per-row identity for ForEach over context_messages.
  func contextRowIdentity(at index: Int, message: ContextMessage) -> String {
    "\(id)#\(index)#\(message.sent_at ?? "")"
  }
}

// MARK: - Recipient display (group-aware)

extension Draft {
  /// True for iMessage group drafts — including the degenerate case where the
  /// structured `imessage_group` target was lost (e.g. an older process
  /// rewrote the JSON) and only the canonical binding survives in `to_handle`.
  var isIMessageGroupDraft: Bool {
    imessage_group != nil || to_handle.hasPrefix("imessage-group")
  }

  /// User-facing recipient title. Group drafts get an explicit group marker
  /// ("Group thread with Maya & Alex"); the raw canonical binding
  /// ("imessage-group-pending:+1...|+1...") never reaches the UI.
  var recipientDisplayName: String {
    if let group = imessage_group {
      return group.groupDisplayLabel
    }
    if to_handle.hasPrefix("imessage-group") {
      if let name = to_handle_name, !name.isEmpty {
        return "Group thread with \(name)"
      }
      return "Group thread"
    }
    return to_handle_name ?? to_handle
  }

  /// Secondary line under the title (the raw handle for unnamed 1:1 drafts).
  /// nil for group drafts — their binding is machine-facing, not a handle.
  var recipientSubtitle: String? {
    if isIMessageGroupDraft { return nil }
    return to_handle_name == nil ? to_handle : nil
  }
}

// Snapshot of the message a WhatsApp reply-draft quotes, embedded in the
// draft JSON at stage time so the menubar can render a "Replying to …"
// callout without a daemon lookup. Mirrors `QuotedPreview` on the
// TypeScript side. Bodies are written raw to the draft file (the MCP's
// <untrusted_content> wrapping is applied only at the LLM-facing tool
// boundary, never on disk), so they're display-ready here.
struct QuotedPreview: Codable, Hashable {
  let message_id: String?
  let body: String?
  let from_me: Bool
  let sender_name: String?

  var displayName: String {
    if from_me { return "You" }
    return sender_name ?? "Unknown"
  }
}

// Accepts the structured iMessage diagnostic and the compact WhatsApp status.
// The decoded wire shape is retained so app-side draft rewrites do not change
// the format expected by either transport.
struct ContextDiagnostic: Codable, Hashable {
  let status: String
  let canonical_recipient: String?
  let matched_handle_ids: [Int]
  let chat_id: Int?
  let message_count: Int
  let error: String?

  private let wireShape: WireShape

  private enum WireShape: Hashable {
    case structured
    case compact
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case canonical_recipient
    case matched_handle_ids
    case chat_id
    case message_count
    case error
  }

  init(
    status: String,
    canonical_recipient: String?,
    matched_handle_ids: [Int],
    chat_id: Int?,
    message_count: Int,
    error: String?
  ) {
    self.init(
      status: status,
      canonical_recipient: canonical_recipient,
      matched_handle_ids: matched_handle_ids,
      chat_id: chat_id,
      message_count: message_count,
      error: error,
      wireShape: .structured
    )
  }

  private init(
    status: String,
    canonical_recipient: String?,
    matched_handle_ids: [Int],
    chat_id: Int?,
    message_count: Int,
    error: String?,
    wireShape: WireShape
  ) {
    self.status = status
    self.canonical_recipient = canonical_recipient
    self.matched_handle_ids = matched_handle_ids
    self.chat_id = chat_id
    self.message_count = message_count
    self.error = error
    self.wireShape = wireShape
  }

  init(from decoder: Decoder) throws {
    let singleValue = try decoder.singleValueContainer()
    if let compactStatus = try? singleValue.decode(String.self) {
      self.init(
        status: compactStatus,
        canonical_recipient: nil,
        matched_handle_ids: [],
        chat_id: nil,
        message_count: 0,
        error: nil,
        wireShape: .compact
      )
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      status: try container.decode(String.self, forKey: .status),
      canonical_recipient: try container.decodeIfPresent(String.self, forKey: .canonical_recipient),
      matched_handle_ids: try container.decode([Int].self, forKey: .matched_handle_ids),
      chat_id: try container.decodeIfPresent(Int.self, forKey: .chat_id),
      message_count: try container.decode(Int.self, forKey: .message_count),
      error: try container.decodeIfPresent(String.self, forKey: .error),
      wireShape: .structured
    )
  }

  func encode(to encoder: Encoder) throws {
    if wireShape == .compact {
      var container = encoder.singleValueContainer()
      try container.encode(status)
      return
    }

    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(canonical_recipient, forKey: .canonical_recipient)
    try container.encode(matched_handle_ids, forKey: .matched_handle_ids)
    try container.encodeIfPresent(chat_id, forKey: .chat_id)
    try container.encode(message_count, forKey: .message_count)
    try container.encodeIfPresent(error, forKey: .error)
  }

  // Human-readable explanation suitable for showing in the Details disclosure.
  var humanExplanation: String {
    switch status {
    case "ok":
      return "Context lookup ok."
    case "no_input":
      return "Lookup not attempted (no recipient handle and no thread id)."
    case "no_handle_match":
      let canon = canonical_recipient ?? "?"
      return "No matching handle in chat.db for canonical form '\(canon)'. The recipient may never have been part of an iMessage thread, or the canonical form differs."
    case "no_chat_for_handle":
      let n = matched_handle_ids.count
      let canon = canonical_recipient ?? "?"
      return "Found \(n) handle row\(n == 1 ? "" : "s") matching '\(canon)' but no chat contains them. (Self-messages and SMS-only handles sometimes look like this.)"
    case "empty_thread":
      return "Chat \(chat_id.map(String.init) ?? "?") was found but contains zero messages."
    case "no_thread_match":
      return "No matching WhatsApp thread was found for this recipient."
    case "thread_empty":
      return "The WhatsApp thread contains no cached messages."
    case "not_found":
      return "No cached WhatsApp thread context was found for this recipient."
    case "error":
      return "Lookup threw: \(error ?? "unknown error")"
    default:
      return "Unknown diagnostic status: \(status)"
    }
  }
}
