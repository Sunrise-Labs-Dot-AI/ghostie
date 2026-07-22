import Foundation
import CryptoKit

/// The read-only projection of a `Draft` for cross-device visibility (SUN-613, read-only scope).
///
/// This is the privacy core of the whole feature. A `Draft` is rich with things a REMOTE device
/// must never see: local file paths, chat.db thread ids, group chat GUIDs, the phone numbers and
/// message ids of OTHER people inside `context_messages`, reaction authors, schedule-approval tags,
/// and send-authority fields. The safe way to project it is an **allowlist**: build a brand-new
/// type that names exactly the fields a reviewer may see, so a field added to `Draft` later cannot
/// leak by default. A denylist (copy everything, then delete some) fails open the moment someone
/// adds a field, which is exactly what happens over a codebase's lifetime.
///
/// Every projection type below is therefore hand-built, and its `CodingKeys` are the contract. The
/// tests assert the exact encoded key set of each type, so this file cannot start emitting a new
/// key without a test failing.
///
/// Nothing here writes to disk or reads identity. `project(from:originDeviceID:)` is pure and takes
/// the device id as a parameter, so no "pure" path ever calls `DeviceIdentity.localDeviceID()`
/// (which can create a file). Storage, transport, the manifest, and the feature flag are phase 2.
///
/// ## Untrusted text
///
/// Every textual field here (`body`, `RelayRecipient` labels, `RelayContextMessage.sender_display`
/// and `.body`, `RelayQuotedPreview.body`) originates from message content or the local Contacts
/// database and is attacker-influenceable. It is UNTRUSTED PLAIN TEXT. The phase-3 web client MUST
/// render it via `textContent` (never `innerHTML`) under a strict CSP. `RelaySnapshot.textIsUntrusted`
/// exists so that contract is visible in code and pinned by a test.
struct RelaySnapshot: Codable, Equatable {
  /// Bumped only on a breaking shape change; phase 2's reader rejects unknown versions.
  let schema_version: Int
  /// The draft id. A reviewer references it; it is not a secret.
  let snapshot_id: String
  /// Which machine published this. Injected by the caller, never read here, so the projection does
  /// no I/O.
  let origin_device_id: String
  let platform: Platform
  let recipient: RelayRecipient
  /// Untrusted plain text.
  let body: String
  let context: [RelayContextMessage]
  let staged_at: String
  let lifecycle: RelayLifecycle
  /// Whether the draft carries attachments. The files themselves stay on the origin Mac; only this
  /// bool crosses, so a reviewer knows media is attached without the paths leaking.
  let has_attachments: Bool
  /// Content hash of the already-redacted fields, for "did the displayed content change" only.
  /// Deliberately NOT `deliveryPayloadDigest`: that carries a send-authority meaning this artifact
  /// must never have.
  let snapshot_digest: String

  static let currentSchemaVersion = 1

  /// Marks every textual field as untrusted plain text (see the type doc). A test asserts this is
  /// true so the contract cannot be quietly dropped.
  static let textIsUntrusted = true

  enum CodingKeys: String, CodingKey {
    case schema_version, snapshot_id, origin_device_id, platform
    case recipient, body, context, staged_at, lifecycle, has_attachments, snapshot_digest
  }

  /// Pure projection. `originDeviceID` is injected so this function touches neither the filesystem
  /// nor `DeviceIdentity`. Same input, same output.
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
      snapshot_digest: ""
    )
    // Digest is computed over the projected fields, then folded in, so it hashes exactly what a
    // reader would receive, nothing local.
    return snapshot.withDigest(snapshot.computeDigest())
  }

  private func withDigest(_ digest: String) -> RelaySnapshot {
    RelaySnapshot(
      schema_version: schema_version, snapshot_id: snapshot_id, origin_device_id: origin_device_id,
      platform: platform, recipient: recipient, body: body, context: context, staged_at: staged_at,
      lifecycle: lifecycle, has_attachments: has_attachments, snapshot_digest: digest
    )
  }

  /// Length-prefixed join of the projected fields, matching the codebase's existing digest idiom
  /// (`deliveryPayloadDigest`), so multi-byte text and delimiters cannot produce an ambiguous
  /// representation.
  private func computeDigest() -> String {
    var parts: [String] = [
      "ghostie-relay-snapshot-v1", snapshot_id, origin_device_id, platform.rawValue,
      recipient.digestComponent, body, staged_at, lifecycle.rawValue, has_attachments ? "1" : "0"
    ]
    for message in context { parts.append(message.digestComponent) }
    let canonical = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Lifecycle a remote reviewer needs, projected from the several ways a `Draft` records state.
enum RelayLifecycle: String, Codable, Equatable {
  case pending, scheduled, held, sent, failed

  static func of(_ draft: Draft) -> RelayLifecycle {
    if draft.sent_at != nil { return .sent }
    if draft.schedule_hold_reason != nil { return .held }
    if draft.scheduled_send_at != nil { return .scheduled }
    return .pending
  }
}

/// Group-aware recipient projection. Never emits a raw group binding.
struct RelayRecipient: Codable, Equatable {
  enum Kind: String, Codable, Equatable { case direct, group }
  let kind: Kind
  /// Untrusted plain text: a contact name, a bare handle for an unknown 1:1 (the user's own
  /// contact, intentional PII), or a people-count label for a group. NEVER a chat_guid or a list of
  /// participant handles.
  let label: String

  enum CodingKeys: String, CodingKey { case kind, label }

  static func project(from draft: Draft) -> RelayRecipient {
    if let group = draft.imessage_group {
      return RelayRecipient(kind: .group, label: safeGroupLabel(group))
    }
    // 1:1. Prefer the contact name; fall back to the handle, which identifies the user's own
    // recipient and is intentional. Never a group binding, because imessage_group was nil.
    let label = draft.to_handle_name?.isEmpty == false ? draft.to_handle_name! : draft.to_handle
    return RelayRecipient(kind: .direct, label: label)
  }

  /// Group label that is safe to publish. `IMessageGroupDraftTarget.groupDisplayLabel` cannot be
  /// reused: when no participant names are known it falls back to joining the raw participant
  /// HANDLES (phone numbers of other people), which is finding 2. Here the no-names path emits a
  /// people COUNT instead, and the guid is never touched.
  static func safeGroupLabel(_ group: IMessageGroupDraftTarget) -> String {
    let names = group.participant_names
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if names.isEmpty {
      let count = max(group.participant_handles.count, 1)
      return "Group thread (\(count) \(count == 1 ? "person" : "people"))"
    }
    // If we know some names but fewer than the participant count, still count the unnamed rest
    // rather than exposing their handles.
    let unnamed = max(group.participant_handles.count - names.count, 0)
    let joined = names.count == 2 && unnamed == 0
      ? names.joined(separator: " & ")
      : names.joined(separator: ", ")
    if unnamed > 0 {
      return "Group thread with \(joined) and \(unnamed) more"
    }
    return "Group thread with \(joined)"
  }

  var digestComponent: String { "\(kind.rawValue):\(label)" }
}

/// A projected context message. Carries what a reviewer reads, and NOT the identity of the other
/// person: no raw handle, no message id/guid, no reaction authors, no receipts, no attachments.
struct RelayContextMessage: Codable, Equatable {
  let from_me: Bool
  /// Untrusted plain text. The contact name if known, else a stable non-identifying pseudonym, so a
  /// third party's phone number never crosses the wire.
  let sender_display: String
  /// Untrusted plain text.
  let body: String
  let sent_at: String?

  enum CodingKeys: String, CodingKey { case from_me, sender_display, body, sent_at }

  /// Pseudonym for an inbound sender whose name is not known locally. Never the raw handle.
  static let unknownSender = "them"

  static func project(from message: ContextMessage) -> RelayContextMessage {
    let display: String
    if message.from_me {
      display = "you"
    } else if let name = message.sender_name, !name.isEmpty {
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

  var digestComponent: String { "\(from_me ? "me" : "them"):\(sender_display):\(body):\(sent_at ?? "")" }
}
