import Foundation

/// Maps a raw send-failure string (from DraftSender / the daemons) to short,
/// actionable user-facing copy. Pure + testable. Unknown errors fall back to the
/// raw message so detail is never hidden; an empty error yields a generic line.
enum SendErrorCopy {
  static func user(for rawError: String?, platform: Platform) -> String {
    let raw = (rawError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()
    let service = platform == .whatsapp ? "WhatsApp" : "iMessage"

    if raw.isEmpty {
      return "Couldn't send. Please try again."
    }
    // WhatsApp-only: a logged-out / unpaired / disconnected session needs a
    // reconnect, not a restart. Guarded by platform AND checked before the
    // daemon-down branch so an iMessage error containing "disconnected" never
    // gets WhatsApp copy — for iMessage these terms fall through to daemon-down.
    if platform == .whatsapp,
       lower.contains("logged out") || lower.contains("not paired")
        || lower.contains("unpaired") || lower.contains("disconnected") {
      return "WhatsApp is disconnected. Reconnect it in Settings, then try again."
    }
    if lower.contains("not running") || lower.contains("daemon") || lower.contains("connection refused")
        || lower.contains("econnrefused") || lower.contains("socket") || lower.contains("could not connect")
        || lower.contains("no such file") || lower.contains("disconnected")
        || lower.contains("logged out") || lower.contains("not paired") || lower.contains("unpaired") {
      return "The \(service) sender isn't running. Restart it in Settings, then try again."
    }
    if lower.contains("permission") || lower.contains("not authorized")
        || lower.contains("denied") || lower.contains("full disk") {
      return "Ghostie doesn't have permission to send \(service). Check Settings, then try again."
    }
    if lower.contains("timeout") || lower.contains("timed out") || lower.contains("network")
        || lower.contains("offline") || lower.contains("unreachable") || lower.contains("no internet") {
      return "Network problem reaching \(service). Check your connection and try again."
    }
    // Unknown — surface the raw detail rather than hide it.
    return raw
  }
}
