import SwiftUI

// MARK: - DS v2: motion + elevation

extension DS {
  /// Returns `animation` unless Reduce Motion is on (then nil). For imperative
  /// `withAnimation(DS.motion(reduceMotion)) { … }` sites.
  static func motion(
    _ reduceMotion: Bool,
    _ animation: Animation = .easeInOut(duration: 0.2)
  ) -> Animation? {
    reduceMotion ? nil : animation
  }
}

/// Brand-accurate elevation — soft, ink-tinted depth (stronger in dark), layered
/// as an ambient + key shadow pair for a natural falloff.
enum DSElevation {
  case low, medium, high
  var params: (ambientR: CGFloat, ambientY: CGFloat, ambientO: Double, keyR: CGFloat, keyY: CGFloat, keyO: Double) {
    switch self {
    case .low:    return (3, 1, 0.05, 10, 4, 0.06)
    case .medium: return (6, 2, 0.06, 26, 12, 0.12)
    case .high:   return (14, 6, 0.07, 60, 24, 0.14)
    }
  }
}

extension View {
  func dsElevation(_ level: DSElevation = .low) -> some View {
    modifier(DSElevationModifier(level: level))
  }

  /// Reduce-Motion-aware drop-in for `.animation(_:value:)`.
  func dsAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
    modifier(DSReduceMotionAnimation(animation: animation, value: value))
  }
}

private struct DSElevationModifier: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  let level: DSElevation
  func body(content: Content) -> some View {
    let p = level.params
    return content
      .shadow(color: tint(p.ambientO), radius: p.ambientR, x: 0, y: p.ambientY)
      .shadow(color: tint(p.keyO), radius: p.keyR, x: 0, y: p.keyY)
  }
  private func tint(_ opacity: Double) -> Color {
    scheme == .dark
      ? Color.black.opacity(opacity * 2.2)
      : Color(red: 18 / 255, green: 24 / 255, blue: 34 / 255).opacity(opacity)
  }
}

private struct DSReduceMotionAnimation<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let animation: Animation?
  let value: V
  func body(content: Content) -> some View {
    content.animation(reduceMotion ? nil : animation, value: value)
  }
}

extension View {
  func dsHairline(
    _ scheme: ColorScheme,
    _ color: @escaping (ColorScheme) -> SwiftUI.Color = DS.Color.line,
    radius: CGFloat = DS.Radius.card,
    width: CGFloat = 1
  ) -> some View {
    overlay(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(color(scheme), lineWidth: width)
    )
  }

  func dsCard(
    _ scheme: ColorScheme,
    fill: SwiftUI.Color? = nil,
    radius: CGFloat = DS.Radius.card
  ) -> some View {
    background(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(fill ?? DS.Color.g130(scheme))
    )
    .dsHairline(scheme, DS.Color.line, radius: radius)
  }

  func dsInput(
    _ scheme: ColorScheme,
    minHeight: CGFloat? = nil,
    radius: CGFloat = DS.Radius.control
  ) -> some View {
    textFieldStyle(.plain)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(minHeight: minHeight)
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(DS.Color.g050(scheme))
      )
      .dsHairline(scheme, DS.Color.lineStrong, radius: radius)
  }
}

enum DSBubbleTail {
  case incoming
  case outgoing
  case none
}

struct DSBubbleShape: Shape {
  var tail: DSBubbleTail
  var radius: CGFloat = DS.Radius.bubble

  func path(in rect: CGRect) -> Path {
    let tailWidth: CGFloat = tail == .none ? 0 : 6
    let bodyRect: CGRect
    switch tail {
    case .incoming:
      bodyRect = CGRect(
        x: rect.minX + tailWidth,
        y: rect.minY,
        width: max(0, rect.width - tailWidth),
        height: rect.height
      )
    case .outgoing:
      bodyRect = CGRect(
        x: rect.minX,
        y: rect.minY,
        width: max(0, rect.width - tailWidth),
        height: rect.height
      )
    case .none:
      bodyRect = rect
    }

    let r = min(radius, bodyRect.width / 2, bodyRect.height / 2)
    guard tail != .none else {
      return Path(roundedRect: bodyRect, cornerRadius: r)
    }
    let tailHeight = min(bodyRect.height * 0.45, 8)
    let tailInset = min(bodyRect.height * 0.35, 7)
    let tailJoin: CGFloat = 10

    var path = Path()
    switch tail {
    case .incoming:
      path.move(to: CGPoint(x: bodyRect.minX + r, y: bodyRect.minY))
      path.addLine(to: CGPoint(x: bodyRect.maxX - r, y: bodyRect.minY))
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + r),
        control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
      )
      path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - r))
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.maxX - r, y: bodyRect.maxY),
        control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
      )
      path.addLine(to: CGPoint(x: bodyRect.minX + tailJoin, y: bodyRect.maxY))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX + 1, y: bodyRect.maxY - 2),
        control: CGPoint(x: bodyRect.minX + 4, y: bodyRect.maxY)
      )
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - tailInset - tailHeight),
        control: CGPoint(x: bodyRect.minX - 2, y: bodyRect.maxY - tailInset)
      )
      path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + r))
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.minX + r, y: bodyRect.minY),
        control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
      )
      path.closeSubpath()
    case .outgoing:
      path.move(to: CGPoint(x: bodyRect.minX + r, y: bodyRect.minY))
      path.addLine(to: CGPoint(x: bodyRect.maxX - r, y: bodyRect.minY))
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + r),
        control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
      )
      path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - tailInset - tailHeight))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX - 1, y: bodyRect.maxY - 2),
        control: CGPoint(x: bodyRect.maxX + 2, y: bodyRect.maxY - tailInset)
      )
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.maxX - tailJoin, y: bodyRect.maxY),
        control: CGPoint(x: bodyRect.maxX - 4, y: bodyRect.maxY)
      )
      path.addLine(to: CGPoint(x: bodyRect.minX + r, y: bodyRect.maxY))
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - r),
        control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
      )
      path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + r))
      path.addQuadCurve(
        to: CGPoint(x: bodyRect.minX + r, y: bodyRect.minY),
        control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
      )
      path.closeSubpath()
    case .none:
      break
    }
    return path
  }
}
