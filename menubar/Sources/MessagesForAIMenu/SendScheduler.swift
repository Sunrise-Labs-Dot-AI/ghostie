import Foundation

// Pure scheduling logic for approve-now/send-later messages. Kept
// free of timers, I/O, and AppKit so the safety-critical decisions - when to
// fire, when to HOLD instead of silently sending late or during quiet hours -
// are exhaustively unit-testable. The runtime wiring (timer, wake observer,
// notifications, the actual send) lives in ScheduledSendController.

/// Quiet hours expressed as local minutes-from-midnight. An "overnight" window
/// (e.g. 21:00→08:00) is represented with start > end.
struct QuietHours: Equatable {
  var enabled: Bool
  var startMinute: Int // inclusive
  var endMinute: Int   // exclusive

  static let `default` = QuietHours(enabled: true, startMinute: 21 * 60, endMinute: 8 * 60)

  /// Is a given local minute-of-day inside the quiet window?
  func contains(minuteOfDay m: Int) -> Bool {
    guard enabled, startMinute != endMinute else { return false }
    if startMinute < endMinute {
      return m >= startMinute && m < endMinute // same-day window
    }
    return m >= startMinute || m < endMinute // overnight window
  }
}

enum SendDecision: Equatable {
  case wait                  // not due yet
  case send                  // fire now
  case hold(reason: String)  // defer + notify; reason ∈ {"quiet_hours","stale"}
}

enum SendScheduler {
  /// A scheduled message more than this many hours late is no longer auto-sent;
  /// it is held for the user to decide.
  static let staleCapHours: Double = 36

  static func minuteOfDay(_ date: Date, _ cal: Calendar) -> Int {
    let c = cal.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
  }

  /// Decide what to do with a scheduled draft at `now`.
  ///
  /// Order is deliberate: an explicit override always sends (the user asked);
  /// otherwise not-yet-due waits, a too-late one holds as "stale", a due one in
  /// quiet hours holds as "quiet_hours", and anything else sends. A held draft
  /// is never silently sent — the caller notifies and the user resolves it.
  static func decide(
    now: Date,
    scheduledAt: Date,
    quiet: QuietHours,
    override: Bool,
    cal: Calendar = .current
  ) -> SendDecision {
    if override { return .send }
    if now < scheduledAt { return .wait }
    let overdueHours = now.timeIntervalSince(scheduledAt) / 3600
    if overdueHours > staleCapHours { return .hold(reason: "stale") }
    if quiet.contains(minuteOfDay: minuteOfDay(now, cal)) { return .hold(reason: "quiet_hours") }
    return .send
  }

  /// The instant a message scheduled for `localDay` should fire: that day
  /// at `defaultMinute` (local). If that lands inside quiet hours, push to when
  /// the quiet window next opens (its end), so we never schedule INTO quiet hours.
  static func fireInstant(
    onLocalDay localDay: Date,
    defaultMinute: Int,
    quiet: QuietHours,
    cal: Calendar = .current
  ) -> Date {
    let startOfDay = cal.startOfDay(for: localDay)
    let target = cal.date(byAdding: .minute, value: defaultMinute, to: startOfDay) ?? startOfDay
    guard quiet.contains(minuteOfDay: defaultMinute) else { return target }
    // Default time is inside quiet hours (unusual). Fire when the quiet window
    // next opens on the same local day (quiet.endMinute is the first non-quiet
    // minute), not the day after.
    return cal.date(byAdding: .minute, value: quiet.endMinute, to: startOfDay) ?? startOfDay
  }
}
