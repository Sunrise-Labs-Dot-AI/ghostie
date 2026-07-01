import Foundation
import AppKit

/// Where a "Draft with…" handoff sends a prompt. Claude Desktop and Codex both
/// register custom URL schemes that open a new session with the composer
/// prefilled (the prompt is NOT auto-sent — the user reviews and runs it):
///   - Claude:  claude://cowork/new?q=…   or  claude://claude.ai/new?q=…
///   - Codex:   codex://new?prompt=…
///
/// The URL builders are pure so they can be unit-tested without a UI or the
/// apps installed. Dispatch (the impure open + clipboard fallback) is a thin
/// @MainActor helper layered on top.
enum DraftAssistant: String, CaseIterable {
  case claude
  case codex

  var displayName: String {
    switch self {
    case .claude: return "Claude"
    case .codex: return "Codex"
    }
  }

  /// SF Symbol for the menu item.
  var symbol: String {
    switch self {
    case .claude: return "sparkles"
    case .codex: return "chevron.left.forwardslash.chevron.right"
    }
  }

  /// Bundle identifiers permitted to receive this assistant's deep link.
  /// macOS URL-scheme dispatch is first-registered-wins with NO bundle binding,
  /// so a malicious local app could register `claude://`/`codex://` and silently
  /// receive the prompt (which carries contact names + relationship/recency
  /// metadata). `DraftHandoff.dispatch` resolves the *actual* handler and refuses
  /// to open unless its bundle ID is one of these. Lowercased because Launch
  /// Services treats bundle IDs case-insensitively (so does the trust check).
  /// (Confirmed via lsregister + NSWorkspace.urlForApplication: Claude Desktop is
  /// `com.anthropic.claudefordesktop`, the Codex app is `com.openai.codex`.)
  var allowedBundleIDs: Set<String> {
    switch self {
    case .claude: return ["com.anthropic.claudefordesktop"]
    case .codex: return ["com.openai.codex"]
    }
  }
}

/// The result of a `DraftHandoff.dispatch`. The prompt is ALWAYS on the clipboard
/// afterward (clipboard-first), so every outcome is safe to paste manually; the
/// case tells the caller what to *show*.
enum HandoffOutcome: Equatable {
  /// A verified first-party handler (Claude Desktop / Codex) was resolved and the
  /// deep link was opened at it.
  case opened
  /// The deep link was NOT opened — the prompt is on the clipboard to paste by
  /// hand. `untrusted` distinguishes a possible scheme hijack (a handler resolved
  /// but its bundle ID wasn't in the allowlist) from the benign case (no handler
  /// registered the scheme at all, e.g. the app isn't installed). Callers warn
  /// visibly on the former.
  case clipboardOnly(untrusted: Bool)

  /// User-facing one-liner for the VoiceOver announcement + the inline notice.
  func message(assistant: DraftAssistant) -> String {
    switch self {
    case .opened:
      return "Opening \(assistant.displayName)"
    case .clipboardOnly(untrusted: false):
      return "Prompt copied to clipboard"
    case .clipboardOnly(untrusted: true):
      return "Unrecognized \(assistant.displayName) app — prompt copied to clipboard, not opened"
    }
  }

  /// True when the outcome is a security-relevant fallback that should be shown
  /// as a warning (we refused to hand the roster to an unverified handler).
  var isWarning: Bool {
    self == .clipboardOnly(untrusted: true)
  }
}

/// Which Claude Desktop surface "Draft with Claude" opens (a user setting).
enum ClaudeTarget: String, CaseIterable, Identifiable {
  case cowork
  case chat

  var id: String { rawValue }

  var label: String {
    switch self {
    case .cowork: return "Cowork session"
    case .chat: return "New chat"
    }
  }
}

enum DraftHandoff {
  /// Anthropic documents a ~14k-char cap on the `q` param. Birthday prompts are
  /// tiny; this guards a future large prompt (we fall back to clipboard-only).
  static let maxPromptChars = 14_000

  /// `claude://cowork/new?q=…` or `claude://claude.ai/new?q=…`. nil when the
  /// prompt is empty or exceeds the param cap.
  static func claudeURL(prompt: String, target: ClaudeTarget) -> URL? {
    guard let q = encodedQuery(prompt) else { return nil }
    let path = target == .cowork ? "cowork/new" : "claude.ai/new"
    return URL(string: "claude://\(path)?q=\(q)")
  }

  /// `codex://new?prompt=…` (prefills the composer; does not auto-run).
  static func codexURL(prompt: String) -> URL? {
    guard let q = encodedQuery(prompt) else { return nil }
    return URL(string: "codex://new?prompt=\(q)")
  }

  static func url(for assistant: DraftAssistant, prompt: String, claudeTarget: ClaudeTarget) -> URL? {
    switch assistant {
    case .claude: return claudeURL(prompt: prompt, target: claudeTarget)
    case .codex: return codexURL(prompt: prompt)
    }
  }

  /// Percent-encode a prompt for use as a query VALUE. `.urlQueryAllowed` leaves
  /// `&`, `=`, `+`, `?`, `#`, `/` un-escaped — all of which would corrupt the
  /// value or the URL — so they're removed from the allowed set. Returns nil for
  /// an empty/oversize prompt so the caller falls back to clipboard-only.
  static func encodedQuery(_ prompt: String) -> String? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, prompt.count <= maxPromptChars else { return nil }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+?#/")
    return prompt.addingPercentEncoding(withAllowedCharacters: allowed)
  }

  /// Seconds the roster prompt may linger on the general pasteboard before a
  /// guarded auto-clear wipes it (the macOS password-field pattern). Long enough
  /// to switch apps and paste; short enough that clipboard-history tools and
  /// shoulder-surfers don't retain the contact roster indefinitely.
  static let clipboardClearDelay: TimeInterval = 60

  /// Pure allowlist check: is `bundleID` a handler we trust for `assistant`?
  /// Factored out of `dispatch` so the security-critical comparison is unit
  /// testable without NSWorkspace. A nil bundle ID (no handler resolved) is never
  /// trusted; matching is case-insensitive (Launch Services treats bundle IDs so).
  static func isTrustedHandler(_ bundleID: String?, for assistant: DraftAssistant) -> Bool {
    guard let bundleID = bundleID?.lowercased() else { return false }
    return assistant.allowedBundleIDs.contains(bundleID)
  }

  /// Pure: should the delayed clear actually wipe the pasteboard? Only when our
  /// content is still the current content (changeCount unchanged) — otherwise the
  /// user copied something else since and we must not clobber it.
  static func shouldClearClipboard(writtenChangeCount: Int, currentChangeCount: Int) -> Bool {
    writtenChangeCount == currentChangeCount
  }

  /// Copy the prompt to the clipboard (so it's never lost if the app/scheme is
  /// missing or untrusted), then open the assistant ONLY through a handler whose
  /// bundle ID we recognize. URL schemes are first-registered-wins with no bundle
  /// binding, so we resolve the actual handler, verify it, and open the deep link
  /// *at that verified app* (not by re-resolving the scheme) — closing the
  /// check→open race. Returns the outcome so callers can surface it visibly.
  /// @MainActor: touches NSPasteboard + NSWorkspace.
  @MainActor
  @discardableResult
  static func dispatch(_ assistant: DraftAssistant, prompt: String, claudeTarget: ClaudeTarget) -> HandoffOutcome {
    copyToClipboard(prompt)
    guard let url = url(for: assistant, prompt: prompt, claudeTarget: claudeTarget) else {
      // Empty/oversize prompt — nothing to open, but the clipboard holds it.
      return .clipboardOnly(untrusted: false)
    }
    guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else {
      // Nothing registered the scheme (the app isn't installed) — benign.
      return .clipboardOnly(untrusted: false)
    }
    // Bundle IDs aren't cryptographically bound, so this isn't a defense against
    // an attacker who can also ship an app claiming `com.anthropic.claudefordesktop`
    // (Launch Services then arbitrates which wins) — but it closes the realistic
    // hole: an unrelated app that grabbed the `claude://`/`codex://` scheme first.
    // A Team-ID/code-signature check would be the next rung if that threat grows.
    guard isTrustedHandler(Bundle(url: handler)?.bundleIdentifier, for: assistant) else {
      // A handler IS registered but it isn't first-party — a possible hijack.
      // Refuse to hand it the roster; the prompt stays on the clipboard.
      return .clipboardOnly(untrusted: true)
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.open([url], withApplicationAt: handler, configuration: config, completionHandler: nil)
    return .opened
  }

  /// Put the prompt on the general pasteboard, marked concealed/transient so
  /// well-behaved clipboard managers skip recording the contact roster into their
  /// history (the nspasteboard.org convention), then schedule a guarded clear.
  @MainActor
  private static func copyToClipboard(_ prompt: String) {
    let pb = NSPasteboard.general
    let writtenCount = pb.clearContents()
    pb.setString(prompt, forType: .string)
    pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    pb.setString("", forType: .init("org.nspasteboard.TransientType"))
    scheduleClipboardClear(writtenChangeCount: writtenCount, after: clipboardClearDelay)
  }

  /// Wipe our copy after `delay`, but ONLY if it's still ours (changeCount
  /// unchanged) so we never clobber something the user copied in the meantime.
  @MainActor
  private static func scheduleClipboardClear(writtenChangeCount: Int, after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      let pb = NSPasteboard.general
      if shouldClearClipboard(writtenChangeCount: writtenChangeCount, currentChangeCount: pb.changeCount) {
        pb.clearContents()
      }
    }
  }
}
