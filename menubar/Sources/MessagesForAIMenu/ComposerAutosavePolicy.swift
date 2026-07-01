import Foundation

/// Pure rules for the per-thread "composer auto-save" draft — the text a user has
/// typed into a composer but not yet sent. Unsent text auto-saves as an ordinary
/// `Draft` so it survives closing the popover / quitting and shows up like any
/// other draft ("a draft is a draft, whether AI created it or not"). One such
/// draft per (platform, recipient); it carries a reserved `source` so we can find
/// and replace exactly the composer's own draft without ever clobbering an
/// AI/MCP-proposed draft for the same thread. Kept separate from the view layer
/// so the find / churn-guard logic is unit-testable.
enum ComposerAutosavePolicy {
  /// Reserved `Draft.source` for composer auto-saves. Distinct from "Ghostie UI"
  /// (a deliberately-staged draft) so the two never collide.
  static let source = "Ghostie composer"

  /// The existing auto-save draft for this thread, if any: unsent, our reserved
  /// source, same platform, same recipient. iMessage matches on the canonical
  /// handle; WhatsApp on the jid. `canonicalize` is injected so tests don't need
  /// Contacts (the app passes `ContactAvatarStore.canonicalKey`).
  static func existingDraft(
    in drafts: [Draft],
    platform: Platform,
    handle: String,
    canonicalize: (String) -> String?
  ) -> Draft? {
    let targetKey = canonicalize(handle) ?? handle.lowercased()
    return drafts.first { draft in
      draft.source == source
        && draft.sent_at == nil
        && (draft.platform ?? .imessage) == platform
        && ((canonicalize(draft.to_handle) ?? draft.to_handle.lowercased()) == targetKey)
    }
  }

  /// What the composer should do for the current text given the existing draft:
  /// create a new draft, update the existing one, discard it (text went empty),
  /// or do nothing (unchanged — avoids a write/refresh churn loop when restoring
  /// text back into the composer re-fires the change handler).
  enum Action: Equatable {
    case create(body: String)
    case update(id: String, body: String)
    case discard(id: String)
    case none
  }

  static func action(forBody rawBody: String, existing: Draft?) -> Action {
    let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.isEmpty {
      return existing.map { .discard(id: $0.id) } ?? .none
    }
    guard let existing else { return .create(body: body) }
    return existing.body == body ? .none : .update(id: existing.id, body: body)
  }
}
