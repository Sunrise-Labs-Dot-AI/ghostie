import SwiftUI

/// The app's button language. Replaces the ~93 stock SwiftUI buttons
/// (`.borderedProminent`/`.bordered`/`.plain`/`.borderless`) with one designed
/// system, grounded in the brand (`site/index.html`): a monochrome **ink**
/// primary (not the generic blue system button), a paper+hairline secondary, a
/// text-only ghost, and a red destructive — each with a subtle hover lift. Tuned
/// to still read as a refined native-Mac control (sensible heights, focus rings
/// preserved, restrained motion).
///
/// Use via the `.dsButton(_:)` modifier on any `Button`:
/// ```
/// Button("Get Started") { commit() }.dsButton(.primary)
/// Button { … } label: { Label("Delete", systemImage: "trash") }.dsButton(.destructive, size: .small)
/// ```
enum DSButtonVariant {
  case primary       // ink fill, inverted (paper) text — the premium primary CTA
  case secondary     // paper fill + 1px hairline + ink text
  case ghost         // text-only, color-on-hover
  case destructive   // red text on paper — irreversible actions (Delete, etc.)
}

enum DSButtonSize {
  case regular
  case small

  var font: Font { self == .small ? DS.Font.button : SwiftUI.Font.system(size: 13, weight: .semibold) }
  var hPad: CGFloat { self == .small ? 11 : 15 }
  var vPad: CGFloat { self == .small ? 5 : 7 }
  var minHeight: CGFloat { self == .small ? 24 : 30 }
  var radius: CGFloat { self == .small ? DS.Radius.control : DS.Radius.button }
  var iconSize: CGFloat { self == .small ? 10.5 : 12 }
}

struct DSButtonStyle: ButtonStyle {
  var variant: DSButtonVariant = .primary
  var size: DSButtonSize = .regular
  var fullWidth: Bool = false
  /// Icon-only: render the (raw `Image`) label centred in a square, no title.
  var iconOnly: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    DSButtonBody(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth, iconOnly: iconOnly)
  }
}

private struct DSButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let variant: DSButtonVariant
  let size: DSButtonSize
  let fullWidth: Bool
  var iconOnly: Bool = false

  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  var body: some View {
    let pressed = configuration.isPressed
    let lifted = hovering && !pressed && isEnabled

    styledLabel
      .foregroundStyle(foreground)
      .padding(.horizontal, iconOnly ? 0 : size.hPad)
      .padding(.vertical, iconOnly ? 0 : size.vPad)
      .frame(width: iconOnly ? size.minHeight : nil, height: iconOnly ? size.minHeight : nil)
      .frame(minHeight: iconOnly ? nil : size.minHeight)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(
        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
          .fill(fill(pressed: pressed))
      )
      .overlay(
        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
          .strokeBorder(border, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
      // Brand hover-lift: a 1pt rise + faint dim. Reduce-Motion-aware.
      .offset(y: lifted ? -1 : 0)
      .opacity(isEnabled ? (pressed ? 0.82 : 1) : 0.45)
      .dsAnimation(.easeOut(duration: 0.13), value: lifted)
      .dsAnimation(.easeOut(duration: 0.10), value: pressed)
      .onHover { hovering = $0 }
  }

  /// Icon-only buttons pass a raw `Image` as their label (so there's no title to
  /// hide); text buttons get the icon+title `DSButtonLabelStyle`.
  @ViewBuilder private var styledLabel: some View {
    if iconOnly {
      configuration.label
        .font(.system(size: size.iconSize + 3, weight: .semibold))
        .lineLimit(1)
    } else {
      configuration.label
        .font(size.font)
        .lineLimit(1)
        .labelStyle(DSButtonLabelStyle(iconSize: size.iconSize))
    }
  }

  // MARK: - Per-variant styling

  private var foreground: Color {
    switch variant {
    case .primary: return DS.Color.g050(scheme)               // paper, i.e. inverted vs the ink fill
    case .secondary: return DS.Color.ink(scheme)
    case .ghost: return hovering ? DS.Color.ink(scheme) : DS.Color.ink2(scheme)
    case .destructive: return DS.Color.red
    }
  }

  private func fill(pressed: Bool) -> Color {
    switch variant {
    case .primary:
      return DS.Color.ink(scheme)
    case .secondary:
      return DS.Color.g050(scheme)
    case .ghost:
      return hovering && isEnabled ? DS.Color.g160(scheme) : Color.clear
    case .destructive:
      return hovering && isEnabled
        ? (scheme == .dark
            ? Color(red: 255/255, green: 95/255, blue: 87/255, opacity: 0.16)
            : Color(red: 255/255, green: 95/255, blue: 87/255, opacity: 0.10))
        : DS.Color.g050(scheme)
    }
  }

  private var border: Color {
    switch variant {
    case .primary: return Color.clear
    case .secondary: return DS.Color.lineStrong(scheme)
    case .ghost: return Color.clear
    case .destructive: return DS.Color.red.opacity(0.45)
    }
  }
}

/// Keeps a button's leading SF Symbol sized + spaced consistently with its text
/// (so `Label("Send", systemImage:)` buttons don't get oversized glyphs).
private struct DSButtonLabelStyle: LabelStyle {
  let iconSize: CGFloat
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: iconSize, weight: .semibold))
      configuration.title
    }
  }
}

extension View {
  /// Apply the DS button language to a `Button`. See `DSButtonStyle`.
  func dsButton(
    _ variant: DSButtonVariant = .primary,
    size: DSButtonSize = .regular,
    fullWidth: Bool = false
  ) -> some View {
    buttonStyle(DSButtonStyle(variant: variant, size: size, fullWidth: fullWidth))
  }

  /// Icon-only DS button — a square control sized to the variant/size, for
  /// toolbar-style affordances (compose, month nav, refresh…). Pass a raw
  /// `Image(systemName:)` as the button label and add `.accessibilityLabel`,
  /// since there's no visible title. Defaults to `.secondary` (subtle filled
  /// square + hairline), matching the app's other icon controls.
  func dsIconButton(
    _ variant: DSButtonVariant = .secondary,
    size: DSButtonSize = .regular
  ) -> some View {
    buttonStyle(DSButtonStyle(variant: variant, size: size, iconOnly: true))
  }
}
