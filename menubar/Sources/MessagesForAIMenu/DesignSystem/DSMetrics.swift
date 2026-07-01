import SwiftUI

extension DS {
  enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 28
    static let xxxxl: CGFloat = 36

    // Semantic spacing (DS v2) — components bake these in so surfaces stop using
    // ad-hoc literals; encodes the brand's tight-within / generous-between cadence.
    static let windowPadding: CGFloat = 24
    static let sectionGap: CGFloat = 22
    static let cardPadding: CGFloat = 14
    static let rowPaddingH: CGFloat = 14
    static let rowPaddingV: CGFloat = 11
    static let fieldGap: CGFloat = 12
    static let inlineGap: CGFloat = 8
    static let tightGap: CGFloat = 6
    static let titleGap: CGFloat = 3
  }

  enum Radius {
    static let card: CGFloat = 12
    static let button: CGFloat = 8
    static let control: CGFloat = 6
    static let chip: CGFloat = 2
    static let bubble: CGFloat = 18
    static let avatar: CGFloat = 8
    static let row: CGFloat = 8
    /// Matches the AppKit window corner on the hidden-titlebar console window —
    /// the edge stroke uses this so the inset frame tracks the real corner.
    static let window: CGFloat = 10
  }

  /// Stroke widths. `hairline` for a 1px-feel separator on retina, `regular` for
  /// standard borders, `thick` for emphasis. Named so border widths stop being
  /// scattered magic numbers.
  enum Stroke {
    static let hairline: CGFloat = 0.5
    static let regular: CGFloat = 1
    static let thick: CGFloat = 1.5
  }
}
