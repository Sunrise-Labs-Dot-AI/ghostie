import Foundation
import Sparkle

/// Pins the appcast feed URL. Sparkle reads `SUFeedURL` from the host's user
/// defaults *before* Info.plist, so a stray `defaults write
/// com.sunriselabs.messages-for-ai SUFeedURL …` (or another local process) could
/// otherwise repoint this FDA-holding app's update channel. Returning the
/// canonical URL from the delegate takes precedence and ignores that override.
/// (A malicious feed still can't ship code — EdDSA + Developer ID gate that — but
/// this prevents an update-suppression / repoint attack.) Plain NSObject (not
/// @MainActor): Sparkle may call it off the main thread, and it only returns a
/// constant.
private final class FeedURLPin: NSObject, SPUUpdaterDelegate {
  static let feedURL = "https://messagesfor.ai/appcast.xml"
  var didFindUpdate: (@Sendable (String?) -> Void)?
  var didNotFindUpdate: (@Sendable () -> Void)?

  func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    didFindUpdate?(item.displayVersionString)
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    didNotFindUpdate?()
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    didNotFindUpdate?()
  }
}

/// Wraps Sparkle's standard updater for the menu-bar app.
///
/// The app checks `messagesfor.ai/appcast.xml` (pinned via `FeedURLPin`) on
/// Sparkle's schedule; when a newer build exists Sparkle shows its own "Update
/// available" window and the USER clicks Install — **nothing auto-installs**
/// (`SUAutomaticallyUpdate` is left off). Sparkle verifies every update (EdDSA
/// signature + Developer ID + Apple notarization) before it runs, and a
/// same-Developer-ID/same-bundle-ID swap preserves the Full Disk Access grant.
///
/// `@MainActor` because the Sparkle controller + its UI are main-thread; owned by
/// `AppDelegate` and injected as an `environmentObject` for the Settings UI.
/// `start()` is called from `applicationDidFinishLaunching` (Sparkle warns against
/// starting the scheduler before the app finishes launching).
@MainActor
final class UpdaterController: ObservableObject {
  private let controller: SPUStandardUpdaterController
  private let feedPin = FeedURLPin()

  /// Mirrors `updater.canCheckForUpdates` so the menu item / Settings button can
  /// disable while a check is already in flight.
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var updateAvailable = false
  @Published private(set) var availableUpdateVersion: String?

  /// Mirror of Sparkle's automatic-check setting so the Settings toggle stays in
  /// sync even when Sparkle changes it (e.g. its first-run permission prompt).
  /// Two-way: the `didSet` writes through to Sparkle; a KVO observer reflects
  /// Sparkle's own changes back. Both sides guard on inequality so there's no loop.
  @Published var automaticallyChecksForUpdates = true {
    didSet {
      if controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
        controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
      }
    }
  }

  private var canCheckObs: NSKeyValueObservation?
  private var autoCheckObs: NSKeyValueObservation?

  init() {
    // startingUpdater:false — the scheduler is started in start() after launch.
    // The feed URL is pinned via the delegate (authoritative over Info.plist + the
    // user-defaults override).
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: feedPin, userDriverDelegate: nil
    )
    feedPin.didFindUpdate = { [weak self] displayVersionString in
      Task { @MainActor in
        self?.markUpdateAvailable(displayVersionString)
      }
    }
    feedPin.didNotFindUpdate = { [weak self] in
      Task { @MainActor in
        self?.clearAvailableUpdate()
      }
    }
  }

  /// Start the background update scheduler. Call once, from
  /// `applicationDidFinishLaunching`.
  func start() {
    controller.startUpdater()
    let u = controller.updater
    if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
      u.automaticallyChecksForUpdates = true
    }
    canCheckForUpdates = u.canCheckForUpdates
    automaticallyChecksForUpdates = u.automaticallyChecksForUpdates
    // Read the changed values ON the main actor (these SPUUpdater properties are
    // documented main-thread-only); the KVO callback may fire off-main.
    canCheckObs = u.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in
        guard let self else { return }
        self.canCheckForUpdates = self.controller.updater.canCheckForUpdates
      }
    }
    autoCheckObs = u.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in
        guard let self else { return }
        let v = self.controller.updater.automaticallyChecksForUpdates
        if self.automaticallyChecksForUpdates != v { self.automaticallyChecksForUpdates = v }
      }
    }
  }

  /// When Sparkle last checked the feed (nil if never) — for a Settings status line.
  var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

  /// User-initiated check. Shows Sparkle's UI: the update window if one is
  /// available, otherwise "You're up to date". Never sends, never auto-installs.
  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }

  private func markUpdateAvailable(_ displayVersionString: String?) {
    updateAvailable = true
    availableUpdateVersion = displayVersionString
  }

  private func clearAvailableUpdate() {
    updateAvailable = false
    availableUpdateVersion = nil
  }
}
