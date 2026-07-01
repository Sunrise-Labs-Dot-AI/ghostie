import SwiftUI

extension DS {
  enum Font {
    static let pageTitle = SwiftUI.Font.system(size: 26, weight: .bold)
    static let paneTitle = SwiftUI.Font.system(size: 24, weight: .bold)
    static let threadListTitle = SwiftUI.Font.system(size: 21, weight: .semibold)
    static let settingsTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
    static let rowTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
    static let detailName = SwiftUI.Font.system(size: 14, weight: .semibold)
    static let bubbleBody = SwiftUI.Font.system(size: 13.5)
    static let settingsLabel = SwiftUI.Font.system(size: 13, weight: .medium)
    static let settingsCaption = SwiftUI.Font.system(size: 11)
    static let caption = SwiftUI.Font.system(size: 11.5)
    static let button = SwiftUI.Font.system(size: 11.5, weight: .medium)
    static let navLabel = SwiftUI.Font.system(size: 12.5)
    static let wordmark = SwiftUI.Font.system(size: 12.5, weight: .semibold)

    // DS v2 additions — large stat numbers (rounded, consumer not monospaced),
    // a reading body for report copy, section title + uppercase section label.
    static let statNumber = SwiftUI.Font.system(size: 28, weight: .bold, design: .rounded)
    static let statNumberSmall = SwiftUI.Font.system(size: 20, weight: .bold, design: .rounded)
    static let readingBody = SwiftUI.Font.system(size: 13.5)
    static let sectionTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
    static let sectionLabel = SwiftUI.Font.system(size: 10.5, weight: .semibold)

    // Ghostie shell typography — the brand chrome of the console + Settings.
    static let brandWordmark = SwiftUI.Font.system(size: 24, weight: .bold, design: .rounded)
    static let brandTagline = SwiftUI.Font.system(size: 11, weight: .medium)
    static let displayTitle = SwiftUI.Font.system(size: 34, weight: .bold, design: .rounded)
    static let monoKicker = SwiftUI.Font.system(size: 10, weight: .bold, design: .monospaced)

    static let groupLabel = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let monoValue = SwiftUI.Font.system(size: 11, design: .monospaced)
    static let monoMicro = SwiftUI.Font.system(size: 10, design: .monospaced)
    static let chip = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let pill = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let approvalTag = SwiftUI.Font.system(size: 9, design: .monospaced)
    static let sidebarFoot = SwiftUI.Font.system(size: 9.5, design: .monospaced)
  }
}
