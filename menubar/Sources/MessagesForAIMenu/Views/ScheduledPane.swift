import SwiftUI
import AppKit

/// The "Scheduled" console tab: approved-but-unsent (and held) messages awaiting
/// their send time. Each can be sent now (override quiet hours), reverted to a
/// plain draft, or discarded. The minute-timer scheduler fires them
/// automatically; this is the human surface to see and steer the queue.
struct ScheduledPane: View {
  @EnvironmentObject var store: DraftStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var sendingIds: Set<String> = []
  @State private var errorText: String?

  private var scheduled: [Draft] {
    store.drafts
      .filter { $0.isScheduled && !$0.isSent }
      .sorted { ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if scheduled.isEmpty {
          emptyState
        } else {
          ForEach(scheduled) { draft in
            row(draft)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
        if let errorText {
          Text(errorText).font(.caption).foregroundStyle(.orange)
        }
        Spacer(minLength: 0)
      }
      .padding(28)
      .frame(maxWidth: 680, alignment: .leading)
      .animation(DS.motion(reduceMotion, .easeInOut(duration: 0.25)), value: scheduled.map(\.id))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.Color.ghostieShellContent(colorScheme))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Scheduled", systemImage: "clock")
        .font(DS.Font.paneTitle)
        .foregroundStyle(DS.Color.ghostieShellInk(colorScheme))
        .labelStyle(.titleAndIcon)
      Text("Messages you've approved to send later. They send automatically at their time (held during quiet hours). Send one now, send it back to Drafts, or remove it.")
        .font(DS.Font.caption).foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var emptyState: some View {
    Text("Nothing scheduled. Approved scheduled drafts appear here.")
      .font(DS.Font.caption).foregroundStyle(DS.Color.ink3(colorScheme))
      .fixedSize(horizontal: false, vertical: true)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .dsCard(colorScheme, fill: DS.Color.ghostieShellCardStrong(colorScheme))
  }

  @ViewBuilder
  private func row(_ draft: Draft) -> some View {
    let busy = sendingIds.contains(draft.id)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(draft.recipientDisplayName)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Spacer()
        statusBadge(draft)
      }
      Text(draft.body).font(DS.Font.caption).foregroundStyle(DS.Color.ink2(colorScheme))
        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Button {
          sendNow(draft)
        } label: {
          if busy { ProgressView().controlSize(.small) } else { Label("Send now", systemImage: "paperplane") }
        }
        .dsButton(.primary).disabled(busy)
        .help("Send immediately, overriding quiet hours")

        Button("Back to draft") { revert(draft) }
          .dsButton(.secondary).disabled(busy)
          .help("Cancel the schedule and keep it as an editable draft")

        Spacer()
        Button(role: .destructive) { discard(draft) } label: { Image(systemName: "trash") }
          .dsButton(.destructive).disabled(busy)
          .accessibilityLabel("Discard scheduled message to \(draft.recipientDisplayName)")
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dsCard(colorScheme, fill: DS.Color.ghostieShellCardStrong(colorScheme))
  }

  @ViewBuilder
  private func statusBadge(_ draft: Draft) -> some View {
    if let reason = draft.schedule_hold_reason {
      Text(holdLabel(reason))
        .font(DS.Font.monoMicro)
        .tracking(0.6)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(
          RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .fill(DS.Color.amberDim(colorScheme))
        )
        .overlay(
          RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(DS.Color.amberDim(colorScheme), lineWidth: 1)
        )
        .foregroundStyle(DS.Color.amber(colorScheme))
    } else if let d = draft.scheduledDate {
      Text(scheduledText(d))
        .font(DS.Font.monoValue)
        .monospacedDigit()
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
  }

  private func holdLabel(_ reason: String) -> String {
    switch reason {
    case "quiet_hours": return "Held · quiet hours"
    case "stale": return "Held · past date"
    case "needs_approval": return "Needs approval"
    case "send_failed": return "Held · send failed"
    default: return "Held"
    }
  }

  private func scheduledText(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d, h:mma"
    return "Sends \(f.string(from: d))"
  }

  // MARK: - actions

  private func sendNow(_ draft: Draft) {
    sendingIds.insert(draft.id)
    errorText = nil
    Task {
      let result = await DraftSender.send(draft: draft)
      sendingIds.remove(draft.id)
      if result.ok {
        try? store.markSent(id: draft.id, sentAt: Date(), service: result.service ?? "iMessage")
      } else {
        errorText = "\(draft.recipientDisplayName): \(SendErrorCopy.user(for: result.error, platform: draft.effectivePlatform))"
      }
    }
  }

  private func revert(_ draft: Draft) {
    // Clear the schedule + any hold → it becomes a plain draft in the Drafts tab.
    try? store.updateScheduling(id: draft.id, scheduledSendAt: .some(nil), holdReason: .some(nil), overrideSend: false)
  }

  private func discard(_ draft: Draft) {
    try? store.discard(id: draft.id)
  }
}
