import SwiftUI

/// Compact, in-context alert at the top of the Drafts list when a messaging
/// daemon needs attention — mirrors the Settings repair card so the user can
/// recover (Restart) without hunting in Settings. Renders nothing when healthy.
struct DaemonAttentionBanner: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var imessageDaemon: IMessageDaemonController
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openWindow) private var openWindow

  private var imessageDown: Bool {
    settings.imessageEnabled && imessageDaemon.status.needsUserAttention
  }
  private var whatsappDown: Bool {
    settings.whatsappEnabled && whatsappDaemon.needsUserAttention
  }

  var body: some View {
    if imessageDown || whatsappDown {
      VStack(alignment: .leading, spacing: 10) {
        if imessageDown {
          row(
            title: "iMessage sender stopped",
            detail: "Drafts can't send until it's running again.",
            action: "Restart",
            run: { imessageDaemon.start() }
          )
        }
        if whatsappDown {
          // A parked daemon is running deliberately, so start() does nothing —
          // the banner used to offer a button that visibly failed. Send those
          // cases to the pairing window, which owns the wipe + re-pair flow.
          let reconnect = whatsappDaemon.needsReconnect
          row(
            title: reconnect ? "WhatsApp needs to reconnect" : "WhatsApp disconnected",
            detail: reconnect
              ? "Scan a new QR code to send WhatsApp drafts again."
              : "Drafts can't send until it reconnects.",
            action: reconnect ? "Reconnect" : "Restart",
            run: {
              if reconnect { openWindow(id: WindowID.whatsappPairing) }
              else { whatsappDaemon.start() }
            }
          )
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
          .fill(DS.Color.amberDim(colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
          .strokeBorder(DS.Color.amber(colorScheme).opacity(0.35), lineWidth: DS.Stroke.regular)
      )
      .padding(.horizontal, 24)
      .padding(.bottom, 8)
      .accessibilityElement(children: .contain)
    }
  }

  private func row(title: String, detail: String, action: String, run: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(DS.Color.amber(colorScheme))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text(detail)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button(action, action: run)
        .dsButton(.secondary, size: .small)
        .accessibilityLabel("\(action) \(title)")
    }
  }
}
