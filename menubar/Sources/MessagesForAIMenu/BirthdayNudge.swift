import Foundation

/// Picks the one birthday worth nudging about at the top of the Messages tab:
/// today's (or tomorrow's) birthday for someone who isn't muted, hasn't been
/// wished this occurrence, and whose nudge wasn't dismissed. Ties break
/// toward today, then pinned, then the person you text most.
enum BirthdayNudgePolicy {
  /// Dismissals are per-occurrence: dismissing this year's nudge must not
  /// suppress next year's.
  static func occurrenceID(_ birthday: UpcomingBirthday) -> String {
    "\(birthday.id)|\(birthday.nextOccurrence)"
  }

  static func wishedThisOccurrence(_ birthday: UpcomingBirthday) -> Bool {
    guard let year = Int(birthday.nextOccurrence.prefix(4)) else { return false }
    return birthday.wishedYears.contains(year)
  }

  /// All birthdays worth nudging about right now (today's, then tomorrow's),
  /// stacked. Excludes muted, already-wished, dismissed, and resolved (you've
  /// messaged them) occurrences. Sorted today-first, then pinned, then closeness.
  static func picks(
    _ upcoming: [UpcomingBirthday],
    dismissedIDs: Set<String> = [],
    resolvedIDs: Set<String> = []
  ) -> [UpcomingBirthday] {
    upcoming
      .filter { $0.daysUntil >= 0 && $0.daysUntil <= 1 }
      .filter { !$0.muted }
      .filter { !wishedThisOccurrence($0) }
      .filter { !dismissedIDs.contains(occurrenceID($0)) }
      .filter { !resolvedIDs.contains(occurrenceID($0)) }
      .sorted { lhs, rhs in
        if lhs.daysUntil != rhs.daysUntil { return lhs.daysUntil < rhs.daysUntil }
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        return lhs.outCount > rhs.outCount
      }
  }

  static func pick(_ upcoming: [UpcomingBirthday], dismissedID: String?) -> UpcomingBirthday? {
    picks(upcoming, dismissedIDs: dismissedID.map { [$0] } ?? []).first
  }

  static func headline(_ birthday: UpcomingBirthday) -> String {
    let possessive = birthday.name.hasSuffix("s") ? "\(birthday.name)'" : "\(birthday.name)'s"
    if birthday.daysUntil == 0 {
      return "\(possessive) birthday is today"
    }
    return "\(possessive) birthday is tomorrow"
  }
}
