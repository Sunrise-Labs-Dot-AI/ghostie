import SwiftUI

// Layout primitives — the reusable building blocks every surface composes from,
// so panes stop hand-assembling rows/sections/headers with ad-hoc padding (the
// root of the "weird spacing" feel). Each bakes in the brand's semantic spacing.

/// Small uppercase section label (the brand "eyebrow").
struct DSLabel: View {
  let text: String
  @Environment(\.colorScheme) private var scheme
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(DS.Font.sectionLabel)
      .tracking(0.7)
      .textCase(.uppercase)
      .foregroundStyle(DS.Color.ink3(scheme))
  }
}

/// Standard pane header: title (+ optional icon/subtitle) on the left, optional
/// trailing actions on the right. Replaces each pane's hand-rolled header HStack.
struct DSPaneHeader<Trailing: View>: View {
  let title: String
  var subtitle: String?
  var systemImage: String?
  @ViewBuilder var trailing: () -> Trailing

  @Environment(\.colorScheme) private var scheme

  init(
    _ title: String,
    subtitle: String? = nil,
    systemImage: String? = nil,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.trailing = trailing
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
      VStack(alignment: .leading, spacing: DS.Space.titleGap) {
        titleView
        if let subtitle {
          Text(subtitle)
            .font(DS.Font.readingBody)
            .foregroundStyle(DS.Color.ink3(scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: DS.Space.m)
      trailing()
    }
  }

  @ViewBuilder private var titleView: some View {
    if let systemImage {
      Label(title, systemImage: systemImage)
        .font(DS.Font.paneTitle)
        .foregroundStyle(DS.Color.ink(scheme))
    } else {
      Text(title)
        .font(DS.Font.paneTitle)
        .foregroundStyle(DS.Color.ink(scheme))
    }
  }
}

extension DSPaneHeader where Trailing == EmptyView {
  init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
    self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
  }
}

/// A titled section: optional uppercase label + content with consistent spacing.
struct DSSection<Content: View>: View {
  let title: String?
  @ViewBuilder var content: () -> Content

  init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.inlineGap) {
      if let title { DSLabel(title) }
      content()
    }
  }
}

/// A settings/form row: label (+ optional subtitle) on the left, a control on the
/// right. Consistent label sizing + row padding everywhere.
struct DSFormRow<Control: View>: View {
  let label: String
  var subtitle: String?
  var systemImage: String?
  @ViewBuilder var control: () -> Control

  @Environment(\.colorScheme) private var scheme

  init(
    _ label: String,
    subtitle: String? = nil,
    systemImage: String? = nil,
    @ViewBuilder control: @escaping () -> Control
  ) {
    self.label = label
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.control = control
  }

  var body: some View {
    HStack(alignment: .center, spacing: DS.Space.m) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 15))
          .foregroundStyle(DS.Color.ink3(scheme))
          .frame(width: 24)
      }
      VStack(alignment: .leading, spacing: DS.Space.titleGap) {
        Text(label)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(scheme))
        if let subtitle {
          Text(subtitle)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: DS.Space.m)
      control()
    }
    .padding(.horizontal, DS.Space.rowPaddingH)
    .padding(.vertical, DS.Space.rowPaddingV)
  }
}

/// A consistent empty state: icon + title + guidance + optional action. Replaces
/// the ad-hoc empty-state stacks (e.g. ScheduledPane/DraftsPane).
struct DSEmptyState<Action: View>: View {
  let systemImage: String
  let title: String
  var message: String?
  @ViewBuilder var action: () -> Action

  @Environment(\.colorScheme) private var scheme

  init(
    systemImage: String,
    title: String,
    message: String? = nil,
    @ViewBuilder action: @escaping () -> Action
  ) {
    self.systemImage = systemImage
    self.title = title
    self.message = message
    self.action = action
  }

  var body: some View {
    VStack(spacing: DS.Space.s) {
      Image(systemName: systemImage)
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(DS.Color.ink4(scheme))
      Text(title)
        .font(DS.Font.settingsTitle)
        .foregroundStyle(DS.Color.ink(scheme))
      if let message {
        Text(message)
          .font(DS.Font.readingBody)
          .foregroundStyle(DS.Color.ink3(scheme))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 360)
      }
      action().padding(.top, DS.Space.xs)
    }
    .frame(maxWidth: .infinity, minHeight: 220)
    .padding(DS.Space.xxl)
  }
}

extension DSEmptyState where Action == EmptyView {
  init(systemImage: String, title: String, message: String? = nil) {
    self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
  }
}

/// A small pill/badge — the brand "eyebrow" chip (e.g. "Coming soon", a count,
/// a status tag). Neutral by default; pass a tint for an accent pill.
struct DSPill: View {
  let text: String
  var systemImage: String?
  var tint: Color?

  @Environment(\.colorScheme) private var scheme

  init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
    self.text = text
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
      }
      Text(text)
        .font(DS.Font.sectionLabel)
        .tracking(0.4)
        .textCase(.uppercase)
    }
    .padding(.horizontal, DS.Space.s)
    .padding(.vertical, 3)
    .foregroundStyle(tint ?? DS.Color.ink2(scheme))
    .background(
      Capsule(style: .continuous)
        .fill(tint.map { $0.opacity(0.12) } ?? DS.Color.g160(scheme))
    )
    .overlay(
      Capsule(style: .continuous)
        .strokeBorder((tint ?? DS.Color.lineStrong(scheme)).opacity(tint == nil ? 1 : 0.4), lineWidth: 1)
    )
  }
}

// MARK: - Card variants

/// Semantic card variants so surfaces stop passing raw fill colors to `.dsCard`.
enum DSCardVariant {
  case plain     // default in-pane grouping (flat, hairline)
  case raised    // lifts off the canvas (paper fill + low elevation)
  case inset     // recessed within a card (g080)
}

extension View {
  /// Variant-based card. `.plain` = flat grouped container; `.raised` = elevated
  /// (sheets / emphasis); `.inset` = recessed sub-panel.
  func dsCard(_ scheme: ColorScheme, variant: DSCardVariant, radius: CGFloat = DS.Radius.card) -> some View {
    modifier(DSVariantCard(scheme: scheme, variant: variant, radius: radius))
  }
}

private struct DSVariantCard: ViewModifier {
  let scheme: ColorScheme
  let variant: DSCardVariant
  let radius: CGFloat

  func body(content: Content) -> some View {
    let fill: Color = {
      switch variant {
      case .plain: return DS.Color.g130(scheme)
      case .raised: return DS.Color.g100(scheme)
      case .inset: return DS.Color.g080(scheme)
      }
    }()
    return content
      .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
      .dsHairline(scheme, variant == .inset ? DS.Color.lineFaint : DS.Color.line, radius: radius)
      .modifier(DSConditionalElevation(on: variant == .raised))
  }
}

private struct DSConditionalElevation: ViewModifier {
  let on: Bool
  func body(content: Content) -> some View {
    if on { content.dsElevation(.low) } else { content }
  }
}
