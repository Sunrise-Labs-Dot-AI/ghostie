import Foundation
import CryptoKit

/// The read-only projection of a `Draft` for cross-device visibility (SUN-613, read-only scope).
///
/// ## What this guarantees, stated honestly
///
/// An earlier version of this file claimed it could ensure "no third party's identity crosses the
/// wire, no matter what the draft contains." That is impossible for a feature whose entire purpose
/// is to show you a message you are about to send: a draft body is free text and can contain
/// anyone's phone number, and you need to see the body to review it. A field-name allowlist bounds
/// which FIELDS cross, not what a free-text field's VALUE contains.
///
/// So the real, defensible contract is two-tier:
///
///  - **Structural exclusion (guaranteed).** Local execution detail and stable third-party
///    identifiers are excluded BY CONSTRUCTION, because this type never has a field to carry them:
///    attachment file paths and hashes, `delivery_progress`, `in_reply_to_thread_id`, group
///    `chat_guid` and raw participant handles, context `message_id`/`guid`, reaction authors,
///    receipts, `schedule_approval_tag`, and `relay_executor`. The tests assert the exact encoded
///    key set of every projection type, so none of these can appear even by accident.
///  - **Content passthrough (acknowledged).** Message text (`body`, context bodies) and the
///    recipient label are shown as the user composed or received them. They may contain PII the
///    user themselves put there. That is the product, not a leak.
///
/// On top of the structural guarantee, this projection does the identity hardening that IS
/// structurally possible: a group is detected via `Draft.isIMessageGroupDraft` (not just the
/// `imessage_group` struct, which an older writer can drop while the raw group binding survives in
/// `to_handle`), so a group-shaped `to_handle` never leaks its guid or handles through the direct
/// path; a context sender whose known "name" is actually handle-shaped is pseudonymised rather than
/// shown; and group participant labels count handle-shaped or blank names rather than printing them.
///
/// Nothing here writes to disk or reads identity. `project(from:originDeviceID:)` is pure and takes
/// the device id as a parameter. Storage, transport, the manifest, and the feature flag are phase 2.
///
/// ## Untrusted text and bidi
///
/// Every textual field is UNTRUSTED. `body` and context bodies are message content and are carried
/// verbatim; the phase-3 web client MUST render them via `textContent` under a strict CSP, and must
/// bidi-isolate them, because `textContent` stops scripts but NOT Unicode direction overrides.
/// Short IDENTITY labels (recipient label, `sender_display`), where a bidi spoof is most dangerous
/// and the text is not content the user needs verbatim, have direction-control characters stripped
/// here so a reversed phone number cannot masquerade as a different one.
struct RelaySnapshot: Codable, Equatable {
  let schema_version: Int
  let snapshot_id: String
  let origin_device_id: String
  let platform: Platform
  let recipient: RelayRecipient
  /// Untrusted message content, carried verbatim (see the type doc). May contain PII.
  let body: String
  let context: [RelayContextMessage]
  let staged_at: String
  let lifecycle: RelayLifecycle
  let has_attachments: Bool
  let quoted: RelayQuotedPreview?
  /// Content hash of the projected fields, for change detection only. NOT `deliveryPayloadDigest`.
  let snapshot_digest: String

  static let currentSchemaVersion = 1
  static let textIsUntrusted = true

  enum CodingKeys: String, CodingKey {
    case schema_version, snapshot_id, origin_device_id, platform
    case recipient, body, context, staged_at, lifecycle, has_attachments, quoted, snapshot_digest
  }

  static func project(from draft: Draft, originDeviceID: String) -> RelaySnapshot {
    let snapshot = RelaySnapshot(
      schema_version: currentSchemaVersion,
      snapshot_id: draft.id,
      origin_device_id: originDeviceID,
      platform: draft.effectivePlatform,
      recipient: RelayRecipient.project(from: draft),
      body: draft.body,
      context: (draft.context_messages ?? []).map(RelayContextMessage.project(from:)),
      staged_at: draft.staged_at,
      lifecycle: RelayLifecycle.of(draft),
      has_attachments: (draft.attachments?.isEmpty == false),
      quoted: RelayQuotedPreview.project(from: draft),
      snapshot_digest: ""
    )
    return snapshot.withDigest(snapshot.computeDigest())
  }

  private func withDigest(_ digest: String) -> RelaySnapshot {
    RelaySnapshot(
      schema_version: schema_version, snapshot_id: snapshot_id, origin_device_id: origin_device_id,
      platform: platform, recipient: recipient, body: body, context: context, staged_at: staged_at,
      lifecycle: lifecycle, has_attachments: has_attachments, quoted: quoted, snapshot_digest: digest
    )
  }

  /// Canonical, unambiguous digest input. Every component, at every level, is UTF-8 length-prefixed
  /// (so `"Bob:hello"` and `"Bob","hello"` cannot collide), nil is a distinct marker rather than an
  /// empty string, and `schema_version` is included so a shape bump changes the digest.
  private func computeDigest() -> String {
    var parts: [String] = [
      "ghostie-relay-snapshot-v1",
      String(schema_version),
      snapshot_id, origin_device_id, platform.rawValue,
      recipient.digestComponent, body, staged_at, lifecycle.rawValue,
      has_attachments ? "1" : "0",
      quoted?.digestComponent ?? "\u{0}nil"
    ]
    parts.append(String(context.count))
    for message in context { parts.append(message.digestComponent) }
    let canonical = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Shared identity-text hygiene for the projection.
enum RelayText {
  /// Unicode direction-control characters. Stripped from short identity labels so a right-to-left
  /// override cannot visually reverse a phone number into a different-looking one.
  static let bidiControls = Set<Character>(["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
                                            "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"])

  static func stripBidiControls(_ s: String) -> String {
    String(s.filter { !bidiControls.contains($0) })
  }

  /// True when a string looks like a raw contact handle (phone or email) rather than a display
  /// name, so a handle stuffed into a "name" field is not shown as if it were one.
  static func looksLikeHandle(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.contains("@") { return true }                 // email
    let digits = t.filter { $0.isNumber }
    // Mostly-digits with a plus/paren/dash shape: a phone number, not a name.
    return digits.count >= 7 && Double(digits.count) / Double(max(t.count, 1)) > 0.5
  }
}

enum RelayLifecycle: String, Codable, Equatable {
  case pending, scheduled, held, sent

  /// Uses the same predicates the rest of the app uses (`Draft.isSent` / `isHeld` / `isScheduled`),
  /// with an explicit precedence, so a stale `schedule_hold_reason` on an unscheduled draft cannot
  /// project as held. `.failed` is intentionally absent: `Draft` has no durable failed state to
  /// project from, so advertising one would be a state the producer can never emit.
  static func of(_ draft: Draft) -> RelayLifecycle {
    if draft.isSent { return .sent }
    if draft.isHeld { return .held }        // isHeld already requires isScheduled
    if draft.isScheduled { return .scheduled }
    return .pending
  }
}

struct RelayRecipient: Codable, Equatable {
  enum Kind: String, Codable, Equatable { case direct, group }
  let kind: Kind
  /// Untrusted identity label with bidi controls stripped. Never a chat_guid or a raw handle list.
  let label: String

  enum CodingKeys: String, CodingKey { case kind, label }

  static func project(from draft: Draft) -> RelayRecipient {
    // Detect a group the way the rest of the app does: the structured target OR a surviving raw
    // group binding in to_handle. Using only `imessage_group != nil` would let a draft whose struct
    // was dropped leak its guid/handles through the direct path (review finding 1).
    if draft.isIMessageGroupDraft {
      let label = draft.imessage_group.map(safeGroupLabel) ?? "Group thread"
      return RelayRecipient(kind: .group, label: RelayText.stripBidiControls(label))
    }
    let name = draft.to_handle_name?.trimmingCharacters(in: .whitespaces)
    let label = (name?.isEmpty == false) ? name! : draft.to_handle
    return RelayRecipient(kind: .direct, label: RelayText.stripBidiControls(label))
  }

  /// Group label safe to publish. Never the guid, never a raw handle. Names that are themselves
  /// handle-shaped or blank are counted, not printed.
  static func safeGroupLabel(_ group: IMessageGroupDraftTarget) -> String {
    let names = group.participant_names
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !RelayText.looksLikeHandle($0) }
    let total = max(group.participant_handles.count, names.count)
    let unnamed = max(total - names.count, 0)
    if names.isEmpty {
      let n = max(total, 1)
      return "Group thread (\(n) \(n == 1 ? "person" : "people"))"
    }
    let joined = names.count == 2 && unnamed == 0
      ? names.joined(separator: " & ")
      : names.joined(separator: ", ")
    return unnamed > 0 ? "Group thread with \(joined) and \(unnamed) more" : "Group thread with \(joined)"
  }

  var digestComponent: String { "\(kind.rawValue):\(label)" }
}

struct RelayContextMessage: Codable, Equatable {
  let from_me: Bool
  /// Untrusted identity label, bidi-stripped. A known display name, else a pseudonym. Never a raw
  /// handle, including the case where the stored "name" is itself handle-shaped.
  let sender_display: String
  /// Untrusted message content, carried verbatim.
  let body: String
  let sent_at: String?

  enum CodingKeys: String, CodingKey { case from_me, sender_display, body, sent_at }

  static let unknownSender = "them"

  static func project(from message: ContextMessage) -> RelayContextMessage {
    let display: String
    if message.from_me {
      display = "you"
    } else if let name = message.sender_name?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, !RelayText.looksLikeHandle(name) {
      display = RelayText.stripBidiControls(name)
    } else {
      display = unknownSender
    }
    return RelayContextMessage(
      from_me: message.from_me,
      sender_display: display,
      body: message.body ?? "",
      sent_at: message.sent_at
    )
  }

  /// Distinct nil marker for `sent_at` so "no timestamp" and "" do not collide in the digest.
  var digestComponent: String {
    "\(from_me ? "me" : "them")\u{1F}\(sender_display)\u{1F}\(body)\u{1F}\(sent_at ?? "\u{0}nil")"
  }
}

/// The message a reply-draft quotes, projected for the "replying to..." callout. Carries only
/// whether it was from the user and its text, never the quoted message's id.
struct RelayQuotedPreview: Codable, Equatable {
  let from_me: Bool
  /// Untrusted message content, carried verbatim.
  let body: String

  enum CodingKeys: String, CodingKey { case from_me, body }

  static func project(from draft: Draft) -> RelayQuotedPreview? {
    guard let preview = draft.quoted_preview else { return nil }
    return RelayQuotedPreview(from_me: preview.from_me, body: preview.body ?? "")
  }

  var digestComponent: String { "\(from_me ? "me" : "them")\u{1F}\(body)" }
}
