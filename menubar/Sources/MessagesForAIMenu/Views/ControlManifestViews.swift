import SwiftUI

/// A banner driven by the signed control manifest (issue #76). Shown at the
/// top of the console when the manifest carries a `banner`, styled by level.
/// Info/warning banners can be dismissed; critical banners stay pinned.
struct ControlManifestBannerView: View {
  @EnvironmentObject var control: ControlManifestController
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if let banner = control.activeBanner {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: icon(for: banner.level))
          .foregroundStyle(tint(for: banner.level))
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 4) {
          Text(ControlManifestBannerChrome.severityLabel(for: banner.level))
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text(banner.text)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink2(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
          if let urlString = banner.url, let url = URL(string: urlString) {
            Link("Learn more", destination: url)
              .font(DS.Font.settingsLabel)
          }
        }
        Spacer(minLength: 8)
        if ControlManifestBannerChrome.isDismissible(banner.level) {
          Button {
            control.dismissBanner()
          } label: {
            Image(systemName: "xmark")
              .font(.caption.weight(.bold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .accessibilityLabel("Dismiss")
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(fill(for: banner.level))
      .overlay(Rectangle().frame(height: 1).foregroundStyle(tint(for: banner.level).opacity(borderOpacity(for: banner.level))), alignment: .bottom)
      .accessibilityElement(children: .contain)
    }
  }

  private func icon(for level: ControlManifest.BannerLevel) -> String {
    switch level {
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .critical: return "exclamationmark.octagon.fill"
    }
  }

  private func tint(for level: ControlManifest.BannerLevel) -> Color {
    switch level {
    case .info: return DS.Color.accentTeal(colorScheme)
    case .warning: return DS.Color.amber(colorScheme)
    case .critical: return DS.Color.red
    }
  }

  private func fill(for level: ControlManifest.BannerLevel) -> Color {
    switch level {
    case .info: return DS.Color.accentTeal(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12)
    case .warning: return DS.Color.amberDim(colorScheme)
    case .critical: return DS.Color.red.opacity(colorScheme == .dark ? 0.22 : 0.14)
    }
  }

  private func borderOpacity(for level: ControlManifest.BannerLevel) -> Double {
    level == .critical ? 0.45 : 0.25
  }
}

enum ControlManifestBannerChrome {
  static func isDismissible(_ level: ControlManifest.BannerLevel) -> Bool {
    level != .critical
  }

  static func severityLabel(for level: ControlManifest.BannerLevel) -> String {
    switch level {
    case .info: return "Notice"
    case .warning: return "Warning"
    case .critical: return "Critical"
    }
  }
}

/// Full-window blocking screen shown when the control manifest's
/// `min_supported_version` floor exceeds this build (issue #76). All sending is
/// already blocked by SendGate; this surface drives the user to update via Sparkle.
struct UpdateRequiredView: View {
  @EnvironmentObject var control: ControlManifestController
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "arrow.down.circle.fill")
        .font(.system(size: 52))
        .foregroundStyle(DS.Color.amber(colorScheme))
      Text("Update required")
        .font(DS.Font.paneTitle)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text(reasonText)
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink2(colorScheme))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      Button {
        control.triggerUpdate()
      } label: {
        Text("Check for update")
          .font(.headline)
          .padding(.horizontal, 18)
          .padding(.vertical, 8)
      }
      .dsButton(.primary)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DS.Color.g100(colorScheme))
  }

  private var reasonText: String {
    let base = "This version of Ghostie can no longer send messages. Install the latest update to continue."
    if let reason = control.manifest?.kill?.reason, !reason.isEmpty {
      return reason
    }
    return base
  }
}
