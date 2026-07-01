import SwiftUI

/// Semantic severity shared by every banner, callout card, and status badge, so
/// info / success / warning / critical render from ONE source of truth — tint,
/// fill, icon, and a non-color weight signal that escalates with severity.
///
/// The non-color signal (`word` + heavier border/fill for `.critical`) is the
/// fix for the app-wide "severity by hue alone" accessibility gap: a colorblind
/// or fast-scanning user reads the severity word and the heavier frame, not just
/// the color.
enum DSSeverity {
  case info
  case success
  case warning
  case critical

  func tint(_ scheme: ColorScheme) -> Color {
    switch self {
    case .info: return DS.Color.accentTeal(scheme)
    case .success: return DS.Color.green(scheme)
    case .warning: return DS.Color.amber(scheme)
    case .critical: return DS.Color.red
    }
  }

  func fill(_ scheme: ColorScheme) -> Color {
    switch self {
    case .info: return DS.Color.accentTeal(scheme).opacity(scheme == .dark ? 0.18 : 0.12)
    case .success: return DS.Color.greenDim(scheme)
    case .warning: return DS.Color.amberDim(scheme)
    case .critical:
      return scheme == .dark
        ? Color(red: 255 / 255, green: 95 / 255, blue: 87 / 255, opacity: 0.22)
        : Color(red: 255 / 255, green: 95 / 255, blue: 87 / 255, opacity: 0.14)
    }
  }

  var icon: String {
    switch self {
    case .info: return "info.circle.fill"
    case .success: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .critical: return "exclamationmark.octagon.fill"
    }
  }

  /// Severity word surfaced as a visible title prefix so severity survives without
  /// color. `nil` for info/success, which don't need a warning prefix.
  var word: String? {
    switch self {
    case .info, .success: return nil
    case .warning: return "Caution"
    case .critical: return "Critical"
    }
  }

  /// Critical/warning read heavier than info — a stronger border carries severity
  /// without relying on hue.
  var bordered: Bool { self == .critical || self == .warning }
  var borderWidth: CGFloat { self == .critical ? 1.5 : 1 }
}

/// The single callout/alert card used across the app: the contacts-permission
/// banner, the settings repair card, the kill-switch banner, and any inline
/// "here's a thing you should know" surface. Replaces the hand-rolled
/// `Color.blue.opacity(0.10)` / `.orange` / `cornerRadius: 8` one-offs.
struct DSCalloutCard<Actions: View>: View {
  let severity: DSSeverity
  let title: String
  let message: String?
  let prefixSeverityWord: Bool
  /// Optional contextual glyph; severity still drives the color. Defaults to the
  /// severity's own icon so callouts stay visually consistent unless a surface
  /// has a more communicative symbol (e.g. a contacts glyph).
  let icon: String?
  @ViewBuilder var actions: () -> Actions

  @Environment(\.colorScheme) private var colorScheme

  init(
    severity: DSSeverity,
    title: String,
    message: String? = nil,
    icon: String? = nil,
    prefixSeverityWord: Bool = true,
    @ViewBuilder actions: @escaping () -> Actions
  ) {
    self.severity = severity
    self.title = title
    self.message = message
    self.icon = icon
    self.prefixSeverityWord = prefixSeverityWord
    self.actions = actions
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon ?? severity.icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(severity.tint(colorScheme))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        // Title + message combine into one VoiceOver element; the action
        // buttons stay individually focusable (don't combine the whole card).
        VStack(alignment: .leading, spacing: 4) {
          Text(titleText)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
          if let message {
            Text(message)
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)

        actions()
          .padding(.top, 2)
      }
      Spacer(minLength: 0)
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .fill(severity.fill(colorScheme))
    )
    .dsHairline(
      colorScheme,
      { _ in severity.tint(colorScheme).opacity(severity.bordered ? 0.55 : 0.32) },
      radius: DS.Radius.control,
      width: severity.borderWidth
    )
  }

  private var titleText: String {
    if prefixSeverityWord, let word = severity.word { return "\(word): \(title)" }
    return title
  }
}

extension DSCalloutCard where Actions == EmptyView {
  init(
    severity: DSSeverity,
    title: String,
    message: String? = nil,
    icon: String? = nil,
    prefixSeverityWord: Bool = true
  ) {
    self.init(
      severity: severity,
      title: title,
      message: message,
      icon: icon,
      prefixSeverityWord: prefixSeverityWord
    ) { EmptyView() }
  }
}

/// A status indicator that pairs a colored dot with a glyph so pass/fail/pending
/// reads without relying on hue alone. Replaces the raw `.green/.red/.secondary`
/// `Circle()`s in the walkthrough and settings status rows.
struct DSStatusDot: View {
  enum Status {
    case ok
    case attention
    case failed
    case pending
    case idle

    var severity: DSSeverity {
      switch self {
      case .ok: return .success
      case .attention, .pending: return .warning
      case .failed: return .critical
      case .idle: return .info
      }
    }

    var glyph: String {
      switch self {
      case .ok: return "checkmark"
      case .attention: return "exclamationmark"
      case .failed: return "xmark"
      case .pending: return "ellipsis"
      case .idle: return "minus"
      }
    }

    var accessibilityWord: String {
      switch self {
      case .ok: return "OK"
      case .attention: return "Needs attention"
      case .failed: return "Failed"
      case .pending: return "Pending"
      case .idle: return "Not started"
      }
    }
  }

  let status: Status
  var size: CGFloat = 16

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      Circle()
        .fill(status.severity.tint(colorScheme))
      Image(systemName: status.glyph)
        .font(.system(size: size * 0.55, weight: .bold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
    .accessibilityElement()
    .accessibilityLabel(status.accessibilityWord)
  }
}
