import SwiftUI
import AppKit

extension View {
  /// Lazy-permission gate for panes that read the Messages database — the
  /// Full Disk Access counterpart to `ContactsPermissionBanner`. Attach to a
  /// pane's header: while macOS is actively denying chat.db reads, a calm
  /// grant card appears directly below the modified view; once granted (or
  /// when no Messages database exists at all) it renders nothing and adds
  /// zero layout.
  ///
  /// FDA has no programmatic prompt API, so "requesting" it means
  /// deep-linking to the System Settings pane. The card re-probes when the
  /// app regains focus, so flipping the toggle and switching back clears it
  /// on its own.
  ///
  /// - Parameters:
  ///   - toolName: plain-language name of the surface asking ("Texting
  ///     Wrapped", "Messages"…), so the ask is tied to what the user opened.
  ///   - spacing: gap between the modified view and the card when shown.
  func fullDiskAccessGate(toolName: String, spacing: CGFloat = 14) -> some View {
    modifier(FullDiskAccessGate(toolName: toolName, spacing: spacing))
  }
}

struct FullDiskAccessGate: ViewModifier {
  let toolName: String
  let spacing: CGFloat

  @State private var access: ChatDbAccessState = .unknown
  @Environment(\.colorScheme) private var colorScheme

  private static let settingsDeepLink =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: spacing) {
      content
      // Shown only on a live denial — .notFound (Messages never set up on
      // this Mac) and .unknown are not permission gaps, so no nag.
      if access == .permissionDenied {
        card
      }
    }
    .onAppear { refresh() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refresh()
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "lock.shield")
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
        Text("Allow access to your messages")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
      }
      Text("\(toolName) reads your Messages history locally, on this Mac. Grant Full Disk Access to Ghostie in System Settings (the row may still say Messages for AI if you granted it before the rename), then come back. This updates on its own.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)

      Button("Open System Settings") {
        if let url = URL(string: Self.settingsDeepLink) {
          NSWorkspace.shared.open(url)
        }
      }
      .dsButton(.primary, size: .small)
    }
    .padding(DS.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        .fill(DS.Color.g130(colorScheme))
    )
    .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.card)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(toolName) needs Full Disk Access to read your Messages history. Open System Settings to grant it.")
  }

  private func refresh() {
    access = HealthChecks().chatDbAccessState()
  }
}
