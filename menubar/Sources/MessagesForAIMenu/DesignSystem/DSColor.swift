import SwiftUI

enum DS {}

extension DS {
  enum Color {
    static func g000(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x0C0D0F) : hex(0xEEF1F5) }
    static func g050(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x111316) : hex(0xFFFFFF) }
    static func g080(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x14161A) : hex(0xF6F8FA) }
    static func g100(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x16191D) : hex(0xFFFFFF) }
    static func g130(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x1A1D22) : hex(0xFAFBFC) }
    static func g160(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x1E2127) : hex(0xF1F4F8) }
    static func g200(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x23272E) : hex(0xF3F5F8) }
    static func g260(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x2B2F37) : hex(0xE9EDF2) }

    static func line(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? SwiftUI.Color.white.opacity(0.07) : hex(0xE4E8EE) }
    static func line2(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? SwiftUI.Color.white.opacity(0.10) : hex(0xDFE4EB) }
    static func lineStrong(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? SwiftUI.Color.white.opacity(0.14) : hex(0xCDD4DD) }
    static func lineFaint(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? SwiftUI.Color.white.opacity(0.045) : hex(0xEEF1F5) }

    static func ink(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xECEEF1) : hex(0x111317) }
    static func ink2(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xB6BCC6) : hex(0x3F4751) }
    static func ink3(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x7E858F) : hex(0x6A727D) }
    static func ink4(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x8A929C) : hex(0x767676) }

    static let blue = hex(0x0A7CFF)
    static func blueEdge(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x3A96FF) : hex(0x0A6AE0) }
    static let blueDim = SwiftUI.Color(red: 10 / 255, green: 124 / 255, blue: 255 / 255, opacity: 0.16)
    static let blueRail = SwiftUI.Color(red: 10 / 255, green: 124 / 255, blue: 255 / 255, opacity: 0.45)

    static func green(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x11B981) : hex(0x0F9D6B) }
    static func greenDim(_ scheme: ColorScheme) -> SwiftUI.Color {
      scheme == .dark
        ? SwiftUI.Color(red: 17 / 255, green: 185 / 255, blue: 129 / 255, opacity: 0.16)
        : SwiftUI.Color(red: 15 / 255, green: 157 / 255, blue: 107 / 255, opacity: 0.18)
    }
    static func amber(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xE0A23A) : hex(0xB9791B) }
    static func amberDim(_ scheme: ColorScheme) -> SwiftUI.Color {
      scheme == .dark
        ? SwiftUI.Color(red: 224 / 255, green: 162 / 255, blue: 58 / 255, opacity: 0.16)
        : SwiftUI.Color(red: 185 / 255, green: 121 / 255, blue: 27 / 255, opacity: 0.22)
    }
    static let red = hex(0xFF5F57)
    /// Tinted danger fill for alert/repair cards (mirrors greenDim/amberDim).
    static func dangerDim(_ scheme: ColorScheme) -> SwiftUI.Color {
      scheme == .dark
        ? SwiftUI.Color(red: 255 / 255, green: 95 / 255, blue: 87 / 255, opacity: 0.16)
        : SwiftUI.Color(red: 255 / 255, green: 95 / 255, blue: 87 / 255, opacity: 0.10)
    }

    static func imsgInBg(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x3B3B3D) : hex(0xE9E9EB) }
    static func imsgInText(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xFFFFFF) : hex(0x000000) }
    static let imsgBlueTop = hex(0x1FA2FF)
    static let imsgBlueBottom = hex(0x0A7CFF)
    static let imsgOutText = hex(0xFFFFFF)

    // Ghostie shell — the brand chrome of the console + Settings window.
    // LIGHT: a cool-neutral "paper" system (issue: the old warm sand/plum +
    // teal + stray-blue selection read muddy). A cool-grey rail, faint-cool
    // content, white cards, cool-slate ink, and ONE accent — teal — carried
    // through to the selection tint. This deliberately diverges from the warm
    // brand board (brand/ghostie/tokens.css) in the app chrome while keeping
    // the brand's teal as the single accent. DARK keeps the neutral dark ramp.
    static func accentTeal(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x89E5D3) : hex(0x0B8377) }
    static func ghostieShellRail(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x17181A) : hex(0xEBEEF3) }
    static func ghostieShellContent(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x111316) : hex(0xF8FAFB) }
    static func ghostieShellCard(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x1D2024) : SwiftUI.Color.white.opacity(0.66) }
    static func ghostieShellCardStrong(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x242832) : hex(0xFFFFFF) }
    static func ghostieShellControl(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x202329) : hex(0xEDF0F5) }
    static func ghostieShellSelected(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x252A33) : hex(0xE1F1EC) }
    static func ghostieShellSelectedStrong(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x242832) : hex(0xFFFFFF) }
    static func ghostieShellSelectionStroke(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? SwiftUI.Color.white.opacity(0.34) : hex(0x1E222B) }
    static func ghostieShellSelectionShadow(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? SwiftUI.Color.black.opacity(0.38) : hex(0x1E222B) }
    static func ghostieShellHover(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x20242B) : hex(0xEEF2F7) }
    static func ghostieShellLine(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? SwiftUI.Color.white.opacity(0.09) : hex(0xDCE2EA) }
    static func ghostieShellInk(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xECEEF1) : hex(0x1A1D24) }
    static func ghostieShellInk2(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xBFC4CC) : hex(0x434B56) }
    static func ghostieShellMuted(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x8E95A0) : hex(0x69727E) }

    static func waInBg(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x202C33) : hex(0xFFFFFF) }
    static func waInText(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xE9EDEF) : hex(0x111B21) }
    static func waOutBg(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x005C4B) : hex(0xD9FDD3) }
    static func waOutText(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0xE9EDEF) : hex(0x111B21) }
    static func waTick(_ scheme: ColorScheme) -> SwiftUI.Color { scheme == .dark ? hex(0x53BDEB) : hex(0x34B7F1) }

    static func hex(_ value: UInt) -> SwiftUI.Color {
      SwiftUI.Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255,
        opacity: 1
      )
    }
  }
}
