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
/// structurally possible: a group is detected via the structured target OR either canonical raw
/// group binding in `to_handle` (which an older writer can leave behind after dropping the struct),
/// so a group-shaped `to_handle` never leaks its guid or handles through the direct path; a context
/// sender or group participant whose stored "name" is actually handle- or binding-shaped is
/// pseudonymised or counted rather than printed; and all identity trimming is newline-safe so a
/// whitespace-only "name" is treated as absent.
///
/// Nothing here writes to disk or reads identity. `project(from:originDeviceID:)` is pure and takes
/// the device id as a parameter. Storage, transport, the manifest, and the feature flag are phase 2.
///
/// ## Untrusted text and bidi
///
/// Every textual field is UNTRUSTED. `body` and context bodies are message content and are carried
/// verbatim; the phase-3 web client MUST render them via `textContent` under a strict CSP, and must
/// bidi-isolate them, because `textContent` stops scripts but NOT Unicode direction overrides.
/// Short IDENTITY labels (recipient label, `sender_display`), where an invisible-character spoof is
/// most dangerous and the text is not content the user needs verbatim, have ALL invisible
/// format/control scalars stripped here (by Unicode category, see `sanitizeIdentity`) so a hidden
/// character cannot make a classifier see a different string than what ships.
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
  /// Strip every invisible formatting/control scalar from a short IDENTITY label, by Unicode
  /// CATEGORY rather than a hand-listed set.
  ///
  /// A hand-listed denylist of "dangerous" characters is whack-a-mole: successive reviews found the
  /// bidi overrides (202x), then the isolates (206x), then the left-to-right MARK (200E), and there
  /// are more (200F, 061C, the zero-widths 200B-200D, the BOM FEFF). All of them share one property:
  /// they are invisible, and they can make a classifier's `hasPrefix`/digit-density check see a
  /// different string than what is emitted, so a `chat_guid` or a phone number rides out inside an
  /// "allowed" label. Removing everything in the control (Cc), format (Cf), and default-ignorable
  /// categories is complete by construction: there is no invisible scalar left to smuggle. This is
  /// applied ONLY to identity labels, never to message bodies (which are content, carried verbatim).
  static func sanitizeIdentity(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
      if scalar.properties.isDefaultIgnorableCodePoint { return false }
      switch scalar.properties.generalCategory {
      case .control, .format: return false
      default: return true
      }
    }))
  }

  /// True when a string looks like a raw contact handle (phone or email) or a group-binding string
  /// rather than a display name, so an identifier stuffed into a "name" field is not shown as if it
  /// were one.
  static func looksLikeHandle(_ s: String) -> Bool {
    // Sanitize (strip invisible format/control scalars) first as defence in depth, so this
    // predicate is correct even if a caller forgets to normalize before calling it.
    let t = sanitizeIdentity(s).trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return false }
    if t.contains("@") { return true }                              // email
    if t.lowercased().contains("imessage-group") { return true }    // a group binding, never a name
    // Strip common phone punctuation and separators, then judge digit density. A pipe-joined handle
    // list (`+1555...|+1555...`) collapses to all digits and is caught here; a name like "Room 101"
    // is not.
    let stripped = t.filter { !"+()-. |;,".contains($0) }
    guard !stripped.isEmpty else { return false }
    let digits = stripped.filter { $0.isNumber }.count
    return digits >= 7 && Double(digits) / Double(stripped.count) > 0.7
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
    // Normalize `to_handle` (strip bidi + trim) BEFORE any decision or emission. The invariant that
    // keeps this safe: any string we both classify AND bidi-strip before emitting must be normalized
    // first, or the classifier sees a different string than what ships. A bidi char in the group
    // prefix (`imessage\u{202E}-group:...`) would otherwise fail `hasPrefix`, be treated as direct,
    // then be bidi-stripped into the label, leaking the chat_guid (final-verify finding).
    let handle = RelayText.sanitizeIdentity(draft.to_handle).trimmingCharacters(in: .whitespacesAndNewlines)

    // Group detection is transport-aware. iMessage: the structured target OR a canonical
    // colon-delimited binding. WhatsApp: a JID ending in `@g.us`, the stable group-thread id and the
    // WhatsApp equivalent of `chat_guid` (`@lid` is a privacy-group address, likewise not a person).
    // Matching the iMessage colon forms exactly avoids the `imessage-groupie@example.com` false
    // positive; a WhatsApp 1:1 JID ends `@s.whatsapp.net` and is not caught here. Missing the
    // WhatsApp case would emit the raw group JID as a "direct" label, a structural leak.
    let isGroup = draft.imessage_group != nil
      || handle.hasPrefix("imessage-group:")
      || handle.hasPrefix("imessage-group-pending:")
      || handle.hasSuffix("@g.us")
      || handle.hasSuffix("@lid")
    if isGroup {
      // Prefer the iMessage participant label; then a WhatsApp group subject resolved into
      // to_handle_name; then a generic label. Never the raw JID or binding.
      let name = RelayText.sanitizeIdentity(draft.to_handle_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let label = draft.imessage_group.map(safeGroupLabel)
        ?? (name.isEmpty || RelayText.looksLikeHandle(name) ? "Group thread" : name)
      return RelayRecipient(kind: .group, label: RelayText.sanitizeIdentity(label))
    }
    // Same handle-suppression as every other name path (context senders, group participants): if
    // the resolved "name" is itself handle-shaped, fall back to the actual recipient handle rather
    // than showing a stray number as the label. Keeps identity handling uniform across all labels.
    let name = RelayText.sanitizeIdentity(draft.to_handle_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let showName = !name.isEmpty && !RelayText.looksLikeHandle(name)
    return RelayRecipient(kind: .direct, label: showName ? name : handle)
  }

  /// Group label safe to publish. Never the guid, never a raw handle. Names that are themselves
  /// handle-shaped or blank are counted, not printed.
  static func safeGroupLabel(_ group: IMessageGroupDraftTarget) -> String {
    // Normalize (strip bidi controls) BEFORE classifying, so a binding string with interspersed
    // direction controls cannot evade `looksLikeHandle` and then print (final-verify finding).
    let names = group.participant_names
      .map { RelayText.sanitizeIdentity($0).trimmingCharacters(in: .whitespacesAndNewlines) }
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
    // Normalize (strip bidi controls) BEFORE classifying, so bidi controls cannot hide a
    // handle/binding shape from `looksLikeHandle` and then print (final-verify finding).
    let clean = message.sender_name
      .map { RelayText.sanitizeIdentity($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    if message.from_me {
      display = "you"
    } else if let name = clean, !name.isEmpty, !RelayText.looksLikeHandle(name) {
      display = name
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
