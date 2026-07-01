import Foundation

/// Builds the headline "Plan my outreach" handoff prompt: a metadata-only roster
/// of the upcoming birthdays INLINE in the prompt, plus a pointer to the full JSON
/// list file as supplementary detail.
///
/// Why inline the roster (not just a file pointer): the primary target is Claude
/// Desktop's Cowork, whose sandbox can't read `~/.messages-mcp/` — so a bare file
/// path is invisible to it even though the file exists. The inline roster is the
/// reliable carrier that works in EVERY surface (Cowork, a new chat, Codex). The
/// file path is kept as a "fuller data here, if you can read local files" line for
/// the non-sandboxed surfaces (Codex / Claude Code), which can pull richer detail.
///
/// The roster is METADATA ONLY (name, relationship label, date, age) — no message
/// bodies. Claude reads the actual threads itself under the user's gated read-only
/// iMessage tools. No em dashes (house style).
///
/// Pure (Foundation only, no AppKit / UI) so it's unit-testable without an app.
enum BirthdayReviewPrompt {
  /// Cap the inline roster so a long window can't blow the `claude://…?q=` ~14k
  /// limit. Beyond the cap, the prompt tells the assistant to consult the file.
  static let defaultCap = 40

  /// Collapse newlines + control characters to single spaces. Names + relationship
  /// labels are user/Contacts-controlled free text and the path is app-generated;
  /// both flow into a prompt handed to an assistant that can read message threads,
  /// so a multi-line / instruction-shaped value must not be able to start a second
  /// instruction block or break the one-line-per-person roster.
  static func sanitize(_ s: String) -> String {
    let scalars = s.unicodeScalars.map { scalar -> Character in
      (CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar))
        ? " " : Character(scalar)
    }
    // omittingEmptySubsequences collapses runs of spaces and trims the ends.
    return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
  }

  /// The headline prompt. `rows` is the upcoming list (inlined as the roster);
  /// `path` is the optional list-file path (a bonus for non-sandboxed assistants).
  /// Returns "" only when there's nothing to act on (no rows AND no path).
  static func prompt(forListFile path: String, roster rows: [UpcomingBirthday], cap: Int = defaultCap) -> String {
    // Curation first (pinned), then soonest, then name. Dismissed excluded.
    let eligible = rows.filter { !$0.muted }.sorted { a, b in
      if a.pinned != b.pinned { return a.pinned }
      if a.daysUntil != b.daysUntil { return a.daysUntil < b.daysUntil }
      return a.name < b.name
    }
    let shown = Array(eligible.prefix(max(0, cap)))
    let cleanPath = sanitize(path)
    guard !shown.isEmpty || !cleanPath.isEmpty else { return "" }

    var body = ""
    if shown.isEmpty {
      body = "Ghostie generated my upcoming birthday list as JSON at this file:\n\n\(cleanPath)"
    } else {
      body = "Here's my upcoming birthday list:\n\n" + shown.map(line(for:)).joined(separator: "\n")
      let extra = eligible.count - shown.count
      if extra > 0 { body += "\n(\(extra) more not shown.)" }
      if !cleanPath.isEmpty {
        body += "\n\nFuller data (JSON, if you can read local files) is at:\n\(cleanPath)"
      }
    }

    return """
    Help me plan my birthday outreach. \(body)

    Using my message history with each person (read my threads read-only with the \
    iMessage tools), tell me who I should prioritize reaching out to and why: close \
    family or friends, someone going through something, anyone I clearly care about \
    even if I rarely text them. Draft a short birthday message for each person you'd \
    prioritize, in my voice, and skip the ones that don't matter. I'll add the people \
    you flag to my list and approve any drafts myself. Nothing sends automatically.
    """
  }

  /// One roster line, e.g. `- Jane Doe (sister), Mar 14 (in 6 days), turns 30`.
  /// Relationship + age clauses omitted when absent. Comma/paren separators, no
  /// em dash (house style).
  private static func line(for row: UpcomingBirthday) -> String {
    var s = "- \(sanitize(row.name))"
    let rel = (row.relationship ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !rel.isEmpty { s += " (\(sanitize(rel)))" }
    s += ", \(dateLabel(row.nextOccurrence)) (\(whenClause(row.daysUntil)))"
    if let age = row.ageTurning { s += ", turns \(age)" }
    return s
  }

  /// "today" / "tomorrow" / "in N days".
  private static func whenClause(_ daysUntil: Int) -> String {
    switch daysUntil {
    case 0: return "today"
    case 1: return "tomorrow"
    default: return "in \(daysUntil) days"
    }
  }

  /// "MMM d" from an ISO `yyyy-MM-dd`; falls back to the raw string if unparseable.
  /// POSIX locale so month abbreviations are stable across the user's locale.
  private static func dateLabel(_ iso: String) -> String {
    let inFmt = DateFormatter()
    inFmt.calendar = Calendar(identifier: .gregorian)
    inFmt.locale = Locale(identifier: "en_US_POSIX")
    inFmt.timeZone = .current
    inFmt.dateFormat = "yyyy-MM-dd"
    guard let d = inFmt.date(from: iso) else { return sanitize(iso) }
    let outFmt = DateFormatter()
    outFmt.locale = Locale(identifier: "en_US_POSIX")
    outFmt.timeZone = .current
    outFmt.dateFormat = "MMM d"
    return outFmt.string(from: d)
  }
}
