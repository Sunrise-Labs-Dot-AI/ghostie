import Foundation

/// Builds the "Build my birthday list" handoff prompt: a metadata-only seed of who
/// the user is in regular contact with (the engine's `--seed`), INLINE in the
/// prompt, plus a pointer to the full seed file as supplementary detail.
///
/// Why inline the roster (not just a file pointer): the Build action opens Claude
/// Desktop's Cowork (it has the birthday-reminder skill + the read-only iMessage
/// tools a plain chat lacks), and Cowork's sandbox can't read `~/.messages-mcp/` —
/// so a bare seed-file path is invisible to it even though the file exists. The
/// inline roster is the reliable carrier that works in every surface; the file
/// path rides along for non-sandboxed assistants (Codex / Claude Code) that can
/// pull the full seed. (Same lesson that drove BirthdayReviewPrompt to inline.)
///
/// The roster is METADATA ONLY: name, an affinity hint (text/call counts +
/// recency, from the seed's `reason`), and any saved/inferred birthday. No message
/// bodies. The inferred dates come from the date of a past "happy birthday" text,
/// so the prompt asks the assistant to confirm them. No em dashes (house style).
///
/// Pure (Foundation only, no AppKit / UI) so it's unit-testable without an app.
enum BirthdayBuildPrompt {
  /// Cap the inline roster so a long seed can't blow the `claude://…?q=` ~14k
  /// limit. The seed is the candidate POOL the skill narrows, so the cap is higher
  /// than the plan-outreach roster; beyond it, the prompt points at the file.
  static let defaultCap = 60

  /// The build prompt. `contacts` is the seed (inlined as the roster); `path` is
  /// the seed-file path (a bonus for non-sandboxed assistants). Returns "" only
  /// when there's nothing to act on (no contacts AND no path) so the caller gates.
  static func prompt(forSeedFile path: String, roster contacts: [SeedContact], cap: Int = defaultCap) -> String {
    let shown = Array(contacts.prefix(max(0, cap)))
    let cleanPath = BirthdayReviewPrompt.sanitize(path)
    guard !shown.isEmpty || !cleanPath.isEmpty else { return "" }

    var body = ""
    if shown.isEmpty {
      body = "Ghostie wrote a seed of who I'm in regular contact with to this file:\n\n\(cleanPath)"
    } else {
      body = "Here are the people I'm in regular contact with:\n\n" + shown.map(line(for:)).joined(separator: "\n")
      let extra = contacts.count - shown.count
      if extra > 0 { body += "\n(\(extra) more not shown.)" }
      if !cleanPath.isEmpty {
        body += "\n\nThe full seed (JSON, if you can read local files) is at:\n\(cleanPath)"
      }
    }

    return """
    Help me build my birthday list. \(body)

    Use the birthday-reminder skill. For each person, confirm or source their \
    birthday: check my saved Contacts first, use the inferred dates above where \
    present (they come from the date I last texted them happy birthday, so confirm \
    them), and read my threads read-only with the iMessage tools only when you need \
    to. Batch your questions for anyone you cannot resolve (ask me in one go, not \
    one at a time), and focus on the people closest to me. Only the birthday date \
    is stored, never my message text.

    When the list is ready, get it back to me: if you can write local files, save it \
    to ~/.messages-mcp/birthdays.json (or run the birthday engine with --import); \
    otherwise give me a JSON array I can paste into the Import field in Ghostie. \
    Each entry looks like { "name", "contact_handle", "birthday" (MM-DD or \
    YYYY-MM-DD), "relationship", "notes" }. Nothing sends automatically.
    """
  }

  /// One roster line, e.g.
  /// `- Sam Sample, no birthday yet, 863 texts, last 4d ago`
  /// `- Jane Doe, birthday Mar 14, 200 texts; 5 calls`
  /// `- Bob, maybe Jun 2 (from a past birthday text), 40 texts`.
  /// Saved date wins over inferred; the affinity hint (`reason`) trails. Commas,
  /// no em dash (house style).
  private static func line(for c: SeedContact) -> String {
    var s = "- \(BirthdayReviewPrompt.sanitize(c.name))"
    if let saved = c.savedBirthday?.trimmingCharacters(in: .whitespaces), !saved.isEmpty {
      s += ", birthday \(monthDayLabel(saved))"
    } else if let inferred = c.inferredBirthday?.trimmingCharacters(in: .whitespaces), !inferred.isEmpty {
      s += ", maybe \(monthDayLabel(inferred)) (from a past birthday text)"
    } else {
      s += ", no birthday yet"
    }
    let reason = c.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if !reason.isEmpty { s += ", \(BirthdayReviewPrompt.sanitize(reason))" }
    return s
  }

  /// "MMM d" from `MM-DD` or `YYYY-MM-DD`; falls back to the raw (sanitized) string
  /// for anything unparseable. POSIX month names (locale-stable). Internal so the
  /// formatting is unit-testable.
  static func monthDayLabel(_ s: String) -> String {
    let parts = s.split(separator: "-").map(String.init)
    let month: Int?
    let day: Int?
    if parts.count == 3 { month = Int(parts[1]); day = Int(parts[2]) }
    else if parts.count == 2 { month = Int(parts[0]); day = Int(parts[1]) }
    else { month = nil; day = nil }
    guard let m = month, let d = day, (1...12).contains(m), (1...31).contains(d) else {
      return BirthdayReviewPrompt.sanitize(s)
    }
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return "\(months[m - 1]) \(d)"
  }
}
