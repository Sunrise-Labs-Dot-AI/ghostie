import Foundation
import AppKit
import UserNotifications

// Runtime for approve-now/send-later. The decision (send / hold / wait) is
// delegated to the pure, tested SendScheduler; this type is the side-effecting
// glue: a minute timer + a wake observer drive checkDue(), which sends due
// drafts via DraftSender, holds the ones that fall in quiet hours / went stale
// (notifying the user instead of silently sending), and honors an override.
//
// Platform-aware: iMessage sends through Messages.app, WhatsApp sends through the
// WhatsApp daemon. The approval gate is satisfied only when the user approves the
// scheduled message in the GUI.
@MainActor
final class ScheduledSendController {
  private let store: DraftStore
  private let settings: SettingsStore
  private var timer: Timer?
  private var wakeObserver: NSObjectProtocol?
  /// Sends in flight, so a fast timer tick can't double-fire the same draft
  /// before markSent lands on disk.
  private var inFlight: Set<String> = []
  /// Consecutive send failures per draft, to back off + surface after N.
  private var failureCounts: [String: Int] = [:]
  private let maxFailuresBeforeHold = 3

  /// Durable record of draft ids the scheduler has already sent, written the
  /// instant AppleScript reports success — BEFORE markSent. This is the
  /// belt-and-suspenders against a duplicate send if the app crashes or the
  /// sent_at write fails between sending and persisting (in-memory inFlight
  /// alone wouldn't survive a relaunch). Pruned to ids that still exist on disk.
  private let markersURL: URL
  private var sentMarkers: Set<String> = []

  init(store: DraftStore, settings: SettingsStore) {
    self.store = store
    self.settings = settings
    self.markersURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".messages-mcp/scheduled-sent.json")
    self.sentMarkers = Self.loadMarkers(markersURL)
  }

  func start() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.checkDue() }
    }
    // A minute cadence is plenty - scheduled sends are not latency-sensitive, and
    // the wake observer covers the lid-closed gap.
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkDue() }
    }
    checkDue()
  }

  deinit {
    timer?.invalidate()
    if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
  }

  func checkDue(now: Date = Date()) {
    let quiet = settings.quietHours
    for draft in store.drafts {
      guard draft.isScheduled, !draft.isSent else { continue }
      guard let scheduledAt = draft.scheduledDate else { continue }
      if inFlight.contains(draft.id) { continue }
      if sentMarkers.contains(draft.id) { continue } // already sent (durable guard)

      // Approval gate (fail closed + AUTHENTICATED — issue #77): only a scheduled
      // draft whose GUI approval is provable auto-sends. `isScheduleAuthenticallyApproved`
      // requires `schedule_approved == true` AND either an in-session GUI approval
      // or a valid per-install HMAC tag bound to this draft's id/recipient/body.
      // A draft written to disk by another process that merely flips
      // `schedule_approved` or `override_send` has no valid tag and is held.
      guard draft.isScheduleAuthenticallyApproved else {
        if draft.schedule_hold_reason != "needs_approval" {
          try? store.updateScheduling(id: draft.id, holdReason: .some("needs_approval"))
          notifyHold(draft: draft, reason: "needs_approval")
        }
        continue
      }

      // `override` (the quiet-hours bypass) is only honored once the draft has
      // cleared the authenticated approval gate above, so a forged `override_send`
      // bit can't bypass quiet hours either.
      let override = draft.override_send == true

      switch SendScheduler.decide(now: now, scheduledAt: scheduledAt, quiet: quiet, override: override) {
      case .wait:
        continue
      case .hold(let reason):
        // Only write + notify on a NEW hold reason — don't re-notify each tick.
        if draft.schedule_hold_reason != reason {
          try? store.updateScheduling(id: draft.id, holdReason: .some(reason))
          notifyHold(draft: draft, reason: reason)
        }
      case .send:
        fire(draft)
      }
    }
  }

  private func fire(_ draft: Draft) {
    inFlight.insert(draft.id)
    Task {
      let result = await DraftSender.send(draft: draft)
      if result.ok {
        // Record the durable sent-marker FIRST so a crash / failed sent_at write
        // can never cause a re-send. Then persist sent_at + consume the override.
        recordSent(draft.id)
        do {
          if draft.effectivePlatform == .imessage {
            try store.markSent(id: draft.id, sentAt: Date(), service: result.service ?? "iMessage")
            try? store.updateScheduling(id: draft.id, overrideSend: .some(false))
          } else {
            store.refresh()
          }
        } catch {
          // Sent on the wire; the marker already prevents a re-send. Retry the
          // sent_at write once for iMessage so the row doesn't linger as scheduled.
          if draft.effectivePlatform == .imessage {
            try? store.markSent(id: draft.id, sentAt: Date(), service: result.service ?? "iMessage")
          }
        }
        failureCounts[draft.id] = nil
        inFlight.remove(draft.id)
        notifySent(draft)
      } else {
        inFlight.remove(draft.id)
        let n = (failureCounts[draft.id] ?? 0) + 1
        failureCounts[draft.id] = n
        // Retry on the next tick; after repeated failures, hold + surface rather
        // than silently looping every minute.
        if n >= maxFailuresBeforeHold, draft.schedule_hold_reason != "send_failed" {
          try? store.updateScheduling(id: draft.id, holdReason: .some("send_failed"))
          notifyHold(draft: draft, reason: "send_failed")
        }
      }
    }
  }

  // MARK: - durable sent markers

  private func recordSent(_ id: String) {
    sentMarkers.insert(id)
    // Prune to ids that still have a draft file so the set can't grow forever.
    let live = Set(store.drafts.map(\.id))
    sentMarkers.formIntersection(live.union([id]))
    if let data = try? JSONEncoder().encode(Array(sentMarkers)) {
      try? data.write(to: markersURL, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markersURL.path)
    }
  }

  private static func loadMarkers(_ url: URL) -> Set<String> {
    guard let data = try? Data(contentsOf: url),
          let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(arr)
  }

  // MARK: - notifications (best-effort; the Scheduled view is the durable surface)

  private func notifyHold(draft: Draft, reason: String) {
    let why: String
    switch reason {
    case "quiet_hours": why = "It's quiet hours — it wasn't sent."
    case "stale": why = "The scheduled time is too far in the past — it wasn't sent."
    case "needs_approval": why = "It needs your approval before sending."
    case "send_failed": why = "Sending kept failing."
    default: why = "It wasn't sent."
    }
    post(
      title: "Scheduled message held",
      body: "\(draft.recipientDisplayName): \(why) Open Ghostie to send it now or reschedule.",
      id: "hold-\(draft.id)-\(reason)"
    )
  }

  private func notifySent(_ draft: Draft) {
    post(
      title: "Scheduled message sent",
      body: "Sent to \(draft.recipientDisplayName).",
      id: "sent-\(draft.id)"
    )
  }

  private func post(title: String, body: String, id: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req)
  }
}
