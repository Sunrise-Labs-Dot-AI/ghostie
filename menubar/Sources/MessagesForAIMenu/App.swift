import SwiftUI
import AppKit
import Combine

/// Window identifiers used with @Environment(\.openWindow) / dismissWindow. Kept
/// in one place so callers don't typo a string.
enum WindowID {
  static let main = "main"
  static let onboarding = "onboarding"
  static let settings = "settings"
  static let whatsappPairing = "whatsapp-pairing"
  static let setupWalkthrough = "setup-walkthrough"
}

/// Window titles, hoisted so the focus helper can match a window by title.
enum WindowTitle {
  static let main = "Ghostie"
  static let settings = "Ghostie Settings"
}

/// Reliably bring a SwiftUI `Window(id:)` to the foreground. `openWindow` alone
/// does NOT always refocus a window that's already open on another Space/display
/// — the app may not be frontmost and the window stays put. This activates the
/// app and pulls the window to the active Space.
enum WindowFocus {
  /// Pure window-match predicate (extracted for unit coverage). Three ways a
  /// SwiftUI `Window(id:)` can present:
  ///   - identifier exactly equal to the scene id (observed on some macOS
  ///     builds),
  ///   - identifier of the form "<id>-AppWindow-<n>" (what SwiftUI actually
  ///     assigns to scene windows on macOS 14/15),
  ///   - matching title — but ONLY when the window has a non-empty title.
  ///     ConsoleWindowChrome sets `window.title = ""` for the hidden-titlebar
  ///     look, so an empty-title comparison would never help and a naive
  ///     `title == title` match could grab the wrong chrome-less window.
  static func matches(identifier: String?, windowTitle: String, id: String, title: String) -> Bool {
    if let identifier {
      if identifier == id || identifier.hasPrefix("\(id)-") { return true }
    }
    return !windowTitle.isEmpty && windowTitle == title
  }

  static func bringToFront(id: String, title: String) {
    // Defer one runloop tick so this runs after openWindow has surfaced (or
    // created) the window.
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      guard let window = NSApp.windows.first(where: {
        matches(identifier: $0.identifier?.rawValue, windowTitle: $0.title, id: id, title: title)
      }) else { return }
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.collectionBehavior.insert(.moveToActiveSpace)
      window.makeKeyAndOrderFront(nil)
      // Force the window above the frontmost app. A status-item click doesn't
      // reliably grant our app key-window activation, so makeKeyAndOrderFront
      // alone can leave the console behind whatever app was in front (the
      // reported bug). orderFrontRegardless bypasses that.
      window.orderFrontRegardless()
    }
  }
}

@main
struct MessagesForAIMenuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // The first-tier desktop console — THE primary UI now that the popover is
    // gone. Declared FIRST so SwiftUI presents it at launch (Wispr-Flow style:
    // the app opens its window when launched). The menu-bar icon is a
    // hand-managed NSStatusItem (AppDelegate.statusController) that re-opens /
    // focuses this window (on the Drafts tab) after it's closed. A real SwiftUI
    // scene, so the openWindow/dismissWindow calls inside it (Settings →
    // walkthrough / pairing) keep working. `captureWindowActions`
    // hands openWindow to the status item.
    Window(WindowTitle.main, id: WindowID.main) {
      ConsoleView()
        .environmentObject(appDelegate.store)
        .environmentObject(appDelegate.settings)
        .environmentObject(appDelegate.loginItem)
        .environmentObject(appDelegate.contactsExporter)
        .environmentObject(appDelegate.whatsappDaemon)
        .environmentObject(appDelegate.imessageDaemon)
        .environmentObject(appDelegate.nav)
        .environmentObject(appDelegate.automationStore)
        .environmentObject(appDelegate.settingsFocus)
        .environmentObject(appDelegate.birthdayGenerator)
        .environmentObject(appDelegate.textingVoice)
        .environmentObject(appDelegate.workPersonal)
        .environmentObject(appDelegate.messagesViewState)
        .environmentObject(appDelegate.threadPriorities)
        .environmentObject(appDelegate.keepTabsStore)
        .environmentObject(appDelegate.keepTabsController)
        .environmentObject(appDelegate.contactAvatars)
        .environmentObject(appDelegate.entitlements)
        .environmentObject(appDelegate.messageNotifications)
        .environmentObject(appDelegate.updater)
        .environmentObject(appDelegate.controlManifest)
        .environmentObject(appDelegate.featureFlags)
        .environmentObject(appDelegate.aiUsageLedger)
        .captureWindowActions()
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1240, height: 820)
    .windowResizability(.contentSize)

    // Onboarding / Settings / WhatsApp pairing / walkthrough — secondary
    // windows, opened via openWindow from the console / each other. They
    // reference the controllers AppDelegate owns.
    Window("Welcome to Ghostie", id: WindowID.onboarding) {
      OnboardingView()
        .environmentObject(appDelegate.settings)
        .environmentObject(appDelegate.whatsappDaemon)
        .environmentObject(appDelegate.imessageDaemon)
        .environmentObject(appDelegate.nav)
        // featureFlags gates the choosable-tool grid (babysitter etc.). Missing
        // here → OnboardingView.availableChoosableToolIDs hits EnvironmentObject
        // .error() and SIGTRAPs on first-run / Terms-bump onboarding (the only
        // times this window presents — which is why it hid until a fresh machine).
        .environmentObject(appDelegate.featureFlags)
        .frame(width: 560)
        .fixedSize()
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)

    Window(WindowTitle.settings, id: WindowID.settings) {
      SettingsView()
        .environmentObject(appDelegate.entitlements)
        .environmentObject(appDelegate.settings)
        .environmentObject(appDelegate.loginItem)
        .environmentObject(appDelegate.whatsappDaemon)
        .environmentObject(appDelegate.imessageDaemon)
        .environmentObject(appDelegate.textingVoice)
        .environmentObject(appDelegate.settingsFocus)
        .environmentObject(appDelegate.messagesViewState)
        .environmentObject(appDelegate.messageNotifications)
        .environmentObject(appDelegate.updater)
        .environmentObject(appDelegate.featureFlags)
        .environmentObject(appDelegate.aiUsageLedger)
        .frame(width: 480)
        .frame(minHeight: 360)
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)

    Window("Connect WhatsApp", id: WindowID.whatsappPairing) {
      WhatsAppPairingView()
        .environmentObject(appDelegate.whatsappDaemon)
        .environmentObject(appDelegate.settings)
        .frame(width: 380, height: 480)
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)

    Window("Setup Walkthrough", id: WindowID.setupWalkthrough) {
      SetupWalkthroughView()
        .environmentObject(appDelegate.settings)
        .environmentObject(appDelegate.whatsappDaemon)
        .environmentObject(appDelegate.imessageDaemon)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 540, idealHeight: 640)
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)
  }
}

/// Lifecycle hooks for SwiftUI windows. Tracks whether a visible window is open
/// so Dock / Spotlight relaunch can restore the console when all windows are
/// closed but the menu-bar process is still running.
private struct TrackWindowLifecycle: ViewModifier {
  let appDelegate: AppDelegate
  func body(content: Content) -> some View {
    content
      .onAppear { appDelegate.windowDidOpen() }
      .onDisappear { appDelegate.windowDidClose() }
  }
}

private extension View {
  func trackWindowLifecycle(appDelegate: AppDelegate) -> some View {
    modifier(TrackWindowLifecycle(appDelegate: appDelegate))
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme == "messagesforai" && url.host == "auth" {
      guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty else { continue }
      Task { await entitlements.activate(withSessionToken: token) }
    }
  }

  // App-wide controllers. Owned here (not as App @StateObjects) so startup, the
  // status item, and the badge are driven from applicationDidFinishLaunching —
  // deterministic, not gated on a SwiftUI view appearing.
  let store = DraftStore()
  let settings = SettingsStore()
  let loginItem = LoginItemController()
  let contactsExporter = ContactsExporter()
  let whatsappDaemon = WhatsAppDaemonController()
  let imessageDaemon = IMessageDaemonController()
  let nav = ConsoleNavigation()
  let automationStore = AutomationStore()
  let settingsFocus = SettingsFocusController()
  let statusController = MenuBarStatusController()
  // Owned app-level (not a per-view @StateObject) so its loaded list + signals
  // survive tab switches — reopening the Birthday tab is instant instead of
  // re-spawning the engine each time. (WrappedGeneratorController still has the
  // per-view bug; tracked separately.)
  let birthdayGenerator = BirthdayGeneratorController()
  // BYOK AI usage ledger (issue #145): metadata-only token/cost log + budget
  // caps, shared across every AI lab. Injected into the app-level controllers
  // here and into the view-owned ones (DontGhost/EQ/DeepRead) via the environment.
  let aiUsageLedger = AIUsageLedger()
  lazy var textingVoice = TextingVoiceController(usageLedger: aiUsageLedger)
  lazy var workPersonal = WorkPersonalStore(usageLedger: aiUsageLedger)
  let messagesViewState = MessagesViewState()
  // Agent-set thread priorities (MCP set_thread_priority et al.) + the user's
  // own pins from the Messages tab. Watches the shared JSON files.
  let threadPriorities = ThreadPriorityStore()
  // Keep Tabs watchlist (~/.messages-mcp/keep-tabs.json) + its controller, owned
  // app-level so the recommend scan + overdue state survive tab switches. The
  // controller writes "keep-tabs"-provenance priorities into `threadPriorities`.
  let keepTabsStore = KeepTabsStore()
  lazy var keepTabsController = KeepTabsController(store: keepTabsStore, priorities: threadPriorities)
  // Contact photos for the Messages tab (in-memory only).
  let contactAvatars = ContactAvatarStore()
  // Premium entitlement (subscription state cached from the account site;
  // bring-your-own-key bypasses it entirely).
  let entitlements = EntitlementStore()
  // Sparkle auto-update. Created here so the background update scheduler starts at
  // launch; reads SUFeedURL + SUPublicEDKey from Info.plist (stamped by the build
  // scripts). Nothing auto-installs — the user approves each update.
  let updater = UpdaterController()
  // Signed control manifest: remote kill switch + forced-upgrade floor (issue #76).
  let controlManifest = ControlManifestController()
  // PostHog-backed client flags. lazy so the privacy gate can capture
  // `settings` — remote fetches only ever happen while product analytics
  // are opted in.
  lazy var featureFlags = FeatureFlagStore(
    analyticsEnabled: { [weak self] in self?.settings.productAnalyticsEnabled ?? false }
  )
  lazy var scheduledSend = ScheduledSendController(store: store, settings: settings)
  lazy var automationController = AutomationController(
    automationStore: automationStore,
    draftStore: store,
    settings: settings
  )
  lazy var messageNotifications = MessageNotificationController(
    settings: settings,
    messagesViewState: messagesViewState,
    workPersonal: workPersonal,
    onOpenConversation: { [weak self] conversationID in
      self?.showConsole(selecting: .messages)
      self?.messagesViewState.selectedConversationID = conversationID
    }
  )

  /// Captured by BootstrapView at launch so AppKit can drive the SwiftUI
  /// console Window scene.
  var openWindowAction: ((String) -> Void)?
  var dismissWindowAction: ((String) -> Void)?

  /// Visible non-throwaway windows (console + secondary). The app stays regular
  /// even at zero so it remains available via Spotlight, Dock, and app switcher.
  private var visibleWindows = 0
  private var fullExperienceServicesStarted = false
  private var cancellables: Set<AnyCancellable> = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    AnalyticsClient.shared.configure(userEnabled: settings.productAnalyticsEnabled)
    AnalyticsClient.shared.safeCapture(.appLaunched)
    AnalyticsClient.shared.safeCapture(.appVersionSeen)
    featureFlags.refreshOnLaunch()
    DiagnosticsStore.shared.log("app_launch")
    NSApp.setActivationPolicy(.regular)

    // A successful send from ANY surface retires that thread's priority flag.
    // DraftSender broadcasts `.ghostieDidSendMessage` on every successful send
    // (inline composer, draft approval, Don't Ghost, scheduler, "Send now"), so
    // one observer here keeps the behavior uniform instead of each UI remembering
    // to clear. Keyed clear; clearing a thread with no priority is a no-op. (The
    // inline composer additionally clears consolidated siblings at its call site.)
    NotificationCenter.default.addObserver(
      forName: .ghostieDidSendMessage, object: nil, queue: .main
    ) { [weak self] note in
      guard let self else { return }
      let info = note.userInfo ?? [:]
      guard let raw = info["platform"] as? String, let platform = Platform(rawValue: raw) else { return }
      let threadID = info["threadID"] as? Int
      let handle = info["handle"] as? String ?? ""
      MainActor.assumeIsolated {
        self.threadPriorities.clearPriority(platform: platform, threadID: threadID, handle: handle)
      }
    }

    // Menu-bar icon: left-click opens the console (Messages), right-click → menu.
    statusController.onActivate = { [weak self] item in self?.showConsole(selecting: item) }
    statusController.onQuit = { NSApp.terminate(nil) }
    statusController.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
    statusController.install()
    statusController.observe(store: store)

    guard !AppStoragePaths.isUsingHomeOverride else {
      DiagnosticsStore.shared.log("demo_home_override_launch")
      return
    }

    // One-shot rename migration (Messages for AI → Ghostie). Sparkle updates
    // install IN PLACE at the old bundle path while fresh installs land at
    // the new one — either way the Claude Desktop config and the ~/bin compat
    // symlink can point at a bundle root that isn't the one running. Rewrite
    // them to THIS bundle before any health check or walkthrough reads them.
    // Gated on a real .app wrapper so `swift run` dev builds (whose
    // bundle-binary prefix is a fallback constant) never touch a user config.
    if Bundle.main.bundleURL.pathExtension == "app" {
      let migratedKeys = ClaudeConfigMigrator.runAtLaunch()
      if !migratedKeys.isEmpty {
        DiagnosticsStore.shared.log(
          "claude_config_migrated",
          metadata: ["keys": migratedKeys.joined(separator: ",")]
        )
      }
      let refreshedLinks = ClaudeConfigMigrator.refreshCompatSymlinks()
      if !refreshedLinks.isEmpty {
        DiagnosticsStore.shared.log(
          "compat_symlink_refreshed",
          metadata: ["links": refreshedLinks.joined(separator: ",")]
        )
      }
    }

    // Control manifest (issue #76): wire enforcement + apply the CACHED manifest
    // immediately, BEFORE the daemons start, so a previously-seen kill survives a
    // relaunch and the suppressed daemon never even spawns. The daemon controllers
    // consult `daemonSuppressed` before (re)launching.
    controlManifest.configure(
      imessageDaemon: imessageDaemon,
      whatsappDaemon: whatsappDaemon,
      updater: updater,
      settings: settings
    )
    imessageDaemon.isSuppressed = { [weak self] in self?.controlManifest.daemonSuppressed(.imessage) ?? false }
    whatsappDaemon.isSuppressed = { [weak self] in self?.controlManifest.daemonSuppressed(.whatsapp) ?? false }
    controlManifest.start()

    // Full messaging services start only after onboarding + current Terms are
    // complete. Texting Wrapped-only mode skips the MCP daemons and background
    // messaging loops until the user continues full setup.
    observeFullExperienceReadiness()
    startFullExperienceServicesIfNeeded()

    // Start Sparkle's background update scheduler now that the app has finished
    // launching (Sparkle warns against starting it earlier).
    updater.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    DiagnosticsStore.shared.log("app_terminate")
    imessageDaemon.stopBlocking()
    whatsappDaemon.stopBlocking()
    messagesViewState.clearCache()
  }

  /// Keep the process (menu-bar app) alive when the last window closes.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      showConsole(selecting: nav.selection ?? .messages)
    }
    return true
  }

  /// Open (or refocus) the console window, landing on `item`, and bring it to
  /// the foreground. `activate` is called SYNCHRONOUSLY here (inside the status
  /// item's click-handler context) — deferring it can lose the user-event
  /// context macOS requires to honor a cross-app activation. The deferred
  /// `bringToFront` then handles window ordering after openWindow surfaces it.
  func showConsole(selecting item: ConsoleItem) {
    DiagnosticsStore.shared.log("console_open", metadata: ["tab": String(describing: item)])
    nav.selection = ConsoleView.normalizedSelection(item, experienceMode: settings.appExperienceMode)
    NSApp.activate(ignoringOtherApps: true)
    openWindowAction?(WindowID.main)
    WindowFocus.bringToFront(id: WindowID.main, title: WindowTitle.main)
  }

  // MARK: - Window-count bookkeeping

  func windowDidOpen() {
    visibleWindows += 1
  }

  func windowDidClose() {
    visibleWindows = max(0, visibleWindows - 1)
  }

  private func observeFullExperienceReadiness() {
    settings.objectWillChange
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.startFullExperienceServicesIfNeeded()
        }
      }
      .store(in: &cancellables)
  }

  private func startFullExperienceServicesIfNeeded() {
    guard settings.shouldRunFullExperienceServices else { return }

    if settings.imessageEnabled {
      imessageDaemon.start()
    }
    if settings.whatsappEnabled {
      whatsappDaemon.start()
    }
    Task {
      await contactsExporter.bootstrap()
    }

    guard !fullExperienceServicesStarted else { return }
    fullExperienceServicesStarted = true
    scheduledSend.start()
    automationController.start()
    messageNotifications.start()

    // Warm the Messages list cache in the background so the first console open
    // renders from a list instead of flashing the empty state during a cold
    // chat.db read. reloadConversations consumes the warm cache on first open.
    messagesViewState.warmRecentThreadsCache(includeWhatsApp: settings.whatsappEnabled)
  }
}
