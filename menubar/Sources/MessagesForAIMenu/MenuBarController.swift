import SwiftUI
import AppKit
import Combine

/// Drives which console pane is shown. Lifted out of ConsoleView's @State so the
/// menu-bar status item can open the console straight to a tab — Messages on a
/// left-click, Settings from the right-click menu.
final class ConsoleNavigation: ObservableObject {
  @Published var selection: ConsoleItem? = .messages
}

enum SettingsSection: String, Hashable {
  case messaging
  case scheduling
  case ai
  case app
  case diagnostics
}

final class SettingsFocusController: ObservableObject {
  @Published var target: SettingsSection?
}

/// Owns the menu-bar `NSStatusItem`: the icon, the pending-draft count badge, and
/// the click behavior — left-click opens the console on Messages, right-click (or
/// control-click) shows a small Open / Settings / Quit menu.
///
/// Replaces SwiftUI's `MenuBarExtra`, which is structurally a popover (no
/// "click the icon → open a real window" hook). Created and retained by
/// `AppDelegate`, which wires the click closures + the quit handler.
@MainActor
final class MenuBarStatusController: NSObject {
  /// Called on left-click and the "Open"/"Settings" menu items, with the tab to
  /// land on. Set by AppDelegate.
  var onActivate: ((ConsoleItem) -> Void)?
  /// Called by the "Quit" menu item. Set by AppDelegate.
  var onQuit: (() -> Void)?
  /// Called by the "Check for Updates…" menu item — triggers a user-initiated
  /// Sparkle check (shows the update window or "You're up to date"). Set by AppDelegate.
  var onCheckForUpdates: (() -> Void)?

  private var statusItem: NSStatusItem?
  private var badgeCancellable: AnyCancellable?

  /// The pixel-Ghostie menu-bar glyph, loaded once and reused. A monochrome
  /// black silhouette with punched-out eyes + alpha, marked `isTemplate` so
  /// macOS auto-recolors it for light/dark menu bars and the selected
  /// (highlighted) state. Sized to 18pt tall, the standard menu-bar glyph
  /// height. Falls back to the SF Symbol if the bundled asset is missing.
  private static let glyphImage: NSImage = {
    if let image = loadGhostieTemplate() { return image }
    let fallback = NSImage(systemSymbolName: "message", accessibilityDescription: "Ghostie")
    fallback?.isTemplate = true
    return fallback ?? NSImage()
  }()

  /// Builds the menu-bar template NSImage from the bundled @1x/@2x PNGs. The
  /// sprite is 18×22 @1x; we set the logical point size from the @1x pixel
  /// dimensions so the image scales to ~18pt tall and AppKit picks the @2x rep
  /// on Retina. Returns nil if the asset isn't bundled.
  private static func loadGhostieTemplate() -> NSImage? {
    guard
      let url1x = Bundle.main.url(forResource: "menubar-template@1x", withExtension: "png", subdirectory: "Ghostie"),
      let rep1x = NSImageRep(contentsOf: url1x)
    else { return nil }
    let image = NSImage()
    image.addRepresentation(rep1x)
    if let url2x = Bundle.main.url(forResource: "menubar-template@2x", withExtension: "png", subdirectory: "Ghostie"),
       let rep2x = NSImageRep(contentsOf: url2x) {
      image.addRepresentation(rep2x)
    }
    // Logical size = @1x pixel size in points → glyph renders at its native
    // 18×22pt, matching the menu-bar glyph height (taller than wide because the
    // ghost silhouette is taller than a square).
    image.size = NSSize(width: rep1x.pixelsWide, height: rep1x.pixelsHigh)
    image.isTemplate = true
    return image
  }

  func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.target = self
      button.action = #selector(handleClick)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.toolTip = "Ghostie"
    }
    statusItem = item
    renderBadge(pending: 0)
  }

  /// Subscribe the badge to the live pending-draft count.
  func observe(store: DraftStore) {
    badgeCancellable = store.$drafts
      .map { drafts in drafts.filter { !$0.isSent }.count }
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] count in
        MainActor.assumeIsolated { self?.renderBadge(pending: count) }
      }
  }

  private func renderBadge(pending: Int) {
    guard let button = statusItem?.button else { return }
    // Base glyph is the pixel Ghostie template (auto-recolored by macOS for
    // light/dark + highlighted). The pending-draft count rides alongside as the
    // button title, same as before — the glyph stays constant; the count is the
    // unread signal.
    button.image = Self.glyphImage
    button.imagePosition = .imageLeading
    button.title = pending == 0 ? "" : " \(pending)"
  }

  // MARK: - Click handling

  @objc private func handleClick() {
    let isRightClick = NSApp.currentEvent.map {
      $0.type == .rightMouseUp || $0.modifierFlags.contains(.control)
    } ?? false
    if isRightClick {
      showMenu()
    } else {
      onActivate?(.messages)
    }
  }

  private func showMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Open Ghostie", #selector(menuOpen)))
    menu.addItem(menuItem("Settings…", #selector(menuSettings), key: ","))
    menu.addItem(menuItem("Check for Updates…", #selector(menuCheckForUpdates)))
    menu.addItem(.separator())
    menu.addItem(menuItem("Quit Ghostie", #selector(menuQuit), key: "q"))
    // Temporarily attach the menu so a programmatic click pops it, then clear it
    // so the next plain left-click runs `handleClick` (the action) instead of
    // re-showing the menu. Standard NSStatusItem "action + on-demand menu"
    // pattern — performClick blocks until the menu is dismissed.
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }

  private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  @objc private func menuOpen() { onActivate?(.messages) }
  @objc private func menuSettings() { onActivate?(.settings) }
  @objc private func menuCheckForUpdates() { onCheckForUpdates?() }
  @objc private func menuQuit() { onQuit?() }
}

/// Captures SwiftUI's `openWindow`/`dismissWindow` into AppDelegate so the AppKit
/// status item can open the console `Window` scene. Applied to the console scene
/// content; since the console is the FIRST scene it presents at launch, so the
/// capture happens immediately and is available before the user clicks the icon
/// to re-open after closing.
struct CaptureWindowActions: ViewModifier {
  func body(content: Content) -> some View {
    content.modifier(CaptureWindowActionsInner())
  }
}

private struct CaptureWindowActionsInner: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  func body(content: Content) -> some View {
    content.onAppear {
      guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
      appDelegate.openWindowAction = { id in openWindow(id: id) }
      appDelegate.dismissWindowAction = { id in dismissWindow(id: id) }
    }
  }
}

extension View {
  /// Capture openWindow/dismissWindow for the AppKit status item (see above).
  func captureWindowActions() -> some View { modifier(CaptureWindowActions()) }
}
