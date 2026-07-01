import Foundation

/// Human date parsing for the Birthday Texts manual-add fields. Accepts the
/// formats people actually type ("June 14", "Jun 14 1990", "6/14", "6/14/90",
/// "1990-06-14", "14 June") and normalizes to the storage format shared with
/// the engine + the birthday-reminder skill (birthdays.json /
/// birthdays-cache.json): "MM-DD" when the year is unknown, "YYYY-MM-DD" when
/// it's known. Pure — no clock reads beyond the injectable `currentYear`.
///
/// Disambiguation rules (load-bearing, mirrored by the tests):
/// - Numeric forms are US month-first, STRICTLY: "6/14" is June 14, and
///   "14/6" is rejected rather than silently flipped — on a US-convention
///   field a likely typo reads better as a gentle error than a guess. This
///   also preserves the long-standing "13-01 is invalid" contract.
/// - Month-NAME forms accept either order ("June 14", "14 June") — the name
///   makes them unambiguous. English names + 3-letter abbreviations
///   (+ "Sept"); ordinal day suffixes tolerated ("June 14th").
/// - Two-digit years pivot on the current year: 26 → 2026 but 27 → 1927
///   (a birthday is never in the future).
/// - Four-digit years must be 1900...currentYear.
/// - Year-less dates validate in a leap reference year so 02-29 stays a real
///   birthday; year-bearing dates validate in their own year (1990-02-29 is
///   rejected — 1990 wasn't a leap year).
enum BirthdayDateParser {
  struct Parsed: Equatable {
    let month: Int
    let day: Int
    let year: Int?

    /// The storage format: "MM-DD" / "YYYY-MM-DD".
    var normalized: String {
      if let year { return String(format: "%04d-%02d-%02d", year, month, day) }
      return String(format: "%02d-%02d", month, day)
    }

    /// What the live-feedback line renders: "June 14, 1990" / "June 14".
    /// `String(year)` (not interpolation through a formatter) so the year can
    /// never pick up grouping separators.
    var displayText: String {
      let name = BirthdayDateParser.monthNames[month - 1]
      if let year { return "\(name) \(day), \(String(year))" }
      return "\(name) \(day)"
    }
  }

  static let monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  ]

  /// Lowercased month token → 1-based month. Full names + 3-letter forms;
  /// "sept" is the one common 4-letter abbreviation.
  private static let monthLookup: [String: Int] = {
    var map: [String: Int] = [:]
    for (i, name) in monthNames.enumerated() {
      let lower = name.lowercased()
      map[lower] = i + 1
      map[String(lower.prefix(3))] = i + 1
    }
    map["sept"] = 9
    return map
  }()

  static func parse(
    _ raw: String,
    currentYear: Int = Calendar.current.component(.year, from: Date())
  ) -> Parsed? {
    // Commas/periods are punctuation people sprinkle in ("June 14, 1990",
    // "Jun. 14") — fold them into whitespace before tokenizing.
    let cleaned = raw
      .lowercased()
      .replacingOccurrences(of: ",", with: " ")
      .replacingOccurrences(of: ".", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }

    if cleaned.contains(where: { $0.isLetter }) {
      return parseWordForm(cleaned, currentYear: currentYear)
    }
    return parseNumericForm(cleaned, currentYear: currentYear)
  }

  // MARK: - word form ("june 14", "14 june 1990", "june-14")

  private static func parseWordForm(_ s: String, currentYear: Int) -> Parsed? {
    // "-"/"/" also separate word forms ("june-14") — no numeric ambiguity here.
    let tokens = s
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "/", with: " ")
      .split(separator: " ", omittingEmptySubsequences: true)
      .map(String.init)
    guard tokens.count == 2 || tokens.count == 3 else { return nil }

    // The month name can lead ("June 14") or trail the day ("14 June").
    let month: Int
    let dayToken: String
    if let m = monthLookup[tokens[0]] {
      month = m
      dayToken = tokens[1]
    } else if let m = monthLookup[tokens[1]] {
      month = m
      dayToken = tokens[0]
    } else {
      return nil
    }
    guard let day = dayNumber(dayToken) else { return nil }

    var year: Int?
    if tokens.count == 3 {
      guard let y = yearNumber(tokens[2], currentYear: currentYear) else { return nil }
      year = y
    }
    return validated(month: month, day: day, year: year)
  }

  // MARK: - numeric form ("6/14", "6/14/90", "1990-06-14", "06-14")

  private static func parseNumericForm(_ s: String, currentYear: Int) -> Parsed? {
    let parts = s
      .split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == " " })
      .map(String.init)
    guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }

    switch parts.count {
    case 2:
      // Month-first only — see the header rule.
      guard let m = Int(parts[0]), let d = Int(parts[1]) else { return nil }
      return validated(month: m, day: d, year: nil)
    case 3:
      // A leading 4-digit token is ISO year-first; otherwise US month-first
      // with a trailing 2- or 4-digit year.
      if parts[0].count == 4 {
        guard let y = yearNumber(parts[0], currentYear: currentYear),
              let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return validated(month: m, day: d, year: y)
      }
      guard let m = Int(parts[0]), let d = Int(parts[1]),
            let y = yearNumber(parts[2], currentYear: currentYear) else { return nil }
      return validated(month: m, day: d, year: y)
    default:
      return nil
    }
  }

  // MARK: - token helpers

  /// Day token → Int, tolerating an ordinal suffix ("14th" → 14). Capped at
  /// two digits so a year can never be mistaken for a day.
  private static func dayNumber(_ token: String) -> Int? {
    var t = token
    for suffix in ["st", "nd", "rd", "th"] where t.hasSuffix(suffix) && t.count > suffix.count {
      t = String(t.dropLast(suffix.count))
      break
    }
    guard !t.isEmpty, t.count <= 2, t.allSatisfy(\.isNumber) else { return nil }
    return Int(t)
  }

  /// Year token → full year. 4-digit years must land in 1900...currentYear
  /// (birthdays are never in the future, and pre-1900 is garbage); 2-digit
  /// years pivot on the current year (26 → 2026, 27 → 1927 when currentYear
  /// is 2026). Anything else (3 digits, 5 digits) is rejected.
  private static func yearNumber(_ token: String, currentYear: Int) -> Int? {
    guard token.allSatisfy(\.isNumber) else { return nil }
    if token.count == 4 {
      guard let y = Int(token), (1900...currentYear).contains(y) else { return nil }
      return y
    }
    if token.count == 2, let yy = Int(token) {
      let candidate = 2000 + yy
      return candidate <= currentYear ? candidate : 1900 + yy
    }
    return nil
  }

  /// Real-calendar check via component round-trip (a lenient Calendar rolls
  /// June 31 into July 1; the round-trip catches it). Year-less dates validate
  /// in a fixed leap reference year so 02-29 passes.
  private static func validated(month: Int, day: Int, year: Int?) -> Parsed? {
    guard (1...12).contains(month), day >= 1 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let refYear = year ?? 2024
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = refYear
    components.month = month
    components.day = day
    guard let date = calendar.date(from: components) else { return nil }
    let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
    guard roundTrip.year == refYear, roundTrip.month == month, roundTrip.day == day else { return nil }
    return Parsed(month: month, day: day, year: year)
  }
}
