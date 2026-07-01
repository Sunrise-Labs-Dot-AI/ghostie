import SwiftUI

// Per-platform display attributes — colors, symbols, labels — kept in
// one file so the menubar's WhatsApp green doesn't get sprinkled across
// every view that paints a bubble or a badge. Adding a sibling platform
// (Signal, Slack, …) is a one-extension change here plus an enum case
// in Draft.swift.
//
// Color values match the platforms' canonical brand palettes:
// - iMessage: macOS `.accentColor` (system blue / user-themed accent —
//   the same color iMessage.app paints outgoing bubbles in)
// - WhatsApp: #25D366 — WhatsApp's official primary green
extension Platform {
  /// Color used for badges and the from-me bubble fill.
  var accentColor: Color {
    switch self {
    case .imessage: return DS.Color.blue
    case .whatsapp: return Color(red: 0x25 / 255.0, green: 0xD3 / 255.0, blue: 0x66 / 255.0)
    }
  }

  /// Human-readable label for badges and accessibility text.
  var displayName: String {
    switch self {
    case .imessage: return "iMessage"
    case .whatsapp: return "WhatsApp"
    }
  }

  /// SF Symbol name for the platform badge. iMessage uses the system
  /// message symbol; WhatsApp falls back to a generic filled circle
  /// (the official WhatsApp logo isn't an SF Symbol). A bundled asset
  /// could replace `circle.fill` if/when we add brand artwork.
  var sfSymbol: String {
    switch self {
    case .imessage: return "message.fill"
    case .whatsapp: return "circle.fill"
    }
  }
}

/// Small inline pill that labels a draft's transport. Rendered with a
/// pale tint of the platform's accent color and the platform's symbol +
/// name. Use sparingly — by default we only show this for non-iMessage
/// drafts (iMessage is the unmarked default, matching Apple's UI of
/// labeling only non-iMessage threads with "SMS").
struct PlatformBadge: View {
  let platform: Platform
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: platform.sfSymbol)
        .font(.system(size: 8.5, weight: .semibold))
      Text(platform.displayName)
        .font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(badgeColor)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(Capsule(style: .continuous).fill(DS.Color.g130(colorScheme)))
    .accessibilityLabel("\(platform.displayName) draft")
  }

  private var badgeColor: Color {
    switch platform {
    case .imessage: return DS.Color.blue
    case .whatsapp: return DS.Color.green(colorScheme)
    }
  }

  private var badgeBorder: Color {
    switch platform {
    case .imessage: return DS.Color.blueDim
    case .whatsapp: return DS.Color.greenDim(colorScheme)
    }
  }
}

/// Tiny green "SMS" pill for a conversation row whose chat is on the SMS (or
/// RCS) transport rather than iMessage. iMessage stays unmarked (blue is the
/// default), matching Apple's convention of labeling only non-iMessage threads.
/// Driven by `RecentComposeThread.serviceName` (chat.db `chat.service_name`).
struct ServiceBadge: View {
  /// chat.db `service_name` — "SMS" / "RCS" render a pill; anything else
  /// (iMessage, nil) renders nothing.
  let serviceName: String?
  @Environment(\.colorScheme) private var colorScheme

  private var label: String? {
    switch serviceName?.uppercased() {
    case "SMS": return "SMS"
    case "RCS": return "RCS"
    default: return nil
    }
  }

  var body: some View {
    if let label {
      Text(label)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(DS.Color.green(colorScheme))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(DS.Color.greenDim(colorScheme)))
        .accessibilityLabel("\(label) conversation")
    }
  }
}
