import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sidebar selection. Messages is the default first-tier surface for the
/// ongoing "AI proposes, you approve" loop.
enum ConsoleItem: Hashable {
  case messages
  case drafts
  case automations
  case textingVoice
  case scheduled
  case history
  case tool(String)
  case settings
}

/// Callbacks a themed intro view must wire to its own CTAs — continue
/// acknowledges the intro and enters the lab; cancel returns to the previous
/// selection. The host owns the acknowledgment plumbing either way.
struct LabIntroActions {
  let onContinue: () -> Void
  let onCancel: () -> Void
}

/// A pluggable console lab. New labs (Birthday Texts, etc.) register by
/// adding a `ConsoleTool` to `ToolRegistry.all` — the sidebar and detail pane
/// pick them up automatically. `makeView` is a builder so each tool owns its
/// own view + controller without the registry needing to know the type.
/// `makeIntroView` (optional) supplies a themed first-open intro rendered
/// full-bleed inside the intro sheet; the view must provide its own CTAs via
/// the passed `LabIntroActions`. The themed kits stay file-private to each
/// lab's view file — only an opaque AnyView crosses the file boundary.
struct ConsoleTool: Identifiable {
  let id: String
  let title: String
  /// Short name for the sidebar rail — the full `title` still heads the
  /// detail pane. Defaults to `title`; tools with long names declare one.
  let sidebarTitle: String
  let systemImage: String
  let item: ConsoleItem
  let requiresAPIKey: Bool
  let featureFlag: MFAFeatureFlag?
  let introSummary: String
  let introHowItWorks: String
  let introPrivacyNote: String
  let makeIntroView: ((LabIntroActions) -> AnyView)?
  let makeView: () -> AnyView

  init(
    id: String,
    title: String,
    sidebarTitle: String? = nil,
    systemImage: String,
    item: ConsoleItem? = nil,
    requiresAPIKey: Bool = false,
    featureFlag: MFAFeatureFlag? = nil,
    introSummary: String,
    introHowItWorks: String,
    introPrivacyNote: String,
    makeIntroView: ((LabIntroActions) -> AnyView)? = nil,
    makeView: @escaping () -> AnyView
  ) {
    self.id = id
    self.title = title
    self.sidebarTitle = sidebarTitle ?? title
    self.systemImage = systemImage
    self.item = item ?? .tool(id)
    self.requiresAPIKey = requiresAPIKey
    self.featureFlag = featureFlag
    self.introSummary = introSummary
    self.introHowItWorks = introHowItWorks
    self.introPrivacyNote = introPrivacyNote
    self.makeIntroView = makeIntroView
    self.makeView = makeView
  }
}

enum ToolRegistry {
  static let all: [ConsoleTool] = [
    ConsoleTool(
      id: "messages",
      title: "Messages",
      systemImage: "bubble.left.and.bubble.right",
      item: .messages,
      introSummary: "Read recent iMessage and WhatsApp threads in one focused place.",
      introHowItWorks: "Messages filters conversations by recent activity, lets you search and open a thread, and keeps typed sends bound to the visible conversation.",
      introPrivacyNote: "Message history is read locally. Filters and previews stay inside Ghostie unless you explicitly use another feature.",
      makeView: { AnyView(MessagesPane()) }
    ),
    ConsoleTool(
      id: "wrapped",
      title: "Texting Wrapped",
      sidebarTitle: "Wrapped",
      systemImage: "sparkles",
      introSummary: "Generate a shareable, Wrapped-style story from your message history.",
      introHowItWorks: "The report scans local message metadata and renders the finished story inside the app, with export and sharing controls.",
      introPrivacyNote: "Generation runs on-device. Product analytics never include message bodies, handles, names, or file paths.",
      makeIntroView: WrappedToolView.makeIntro,
      makeView: { AnyView(WrappedToolView()) }
    ),
    ConsoleTool(
      id: "dontGhost",
      title: "Don't Ghost",
      systemImage: "arrowshape.turn.up.left.circle",
      introSummary: "Find conversations that may deserve a reply or a follow-up.",
      introHowItWorks: "Ghostie scans recent 1:1 threads on-device and ranks the ones most worth a nudge — replies you still owe, and quiet threads worth a check-in. No API key required. Add a Claude or ChatGPT key in Settings and it runs an optional AI pass to refine the picks. You write the reply.",
      introPrivacyNote: "Scanning and ranking run on-device with no key. An API key only adds an optional AI refinement. Nothing sends without your approval.",
      makeIntroView: DontGhostView.makeIntro,
      makeView: { AnyView(DontGhostView()) }
    ),
    ConsoleTool(
      id: "birthdays",
      title: "Birthday Texts",
      sidebarTitle: "Birthdays",
      systemImage: "birthday.cake",
      introSummary: "Keep track of birthdays so the right text goes out on the right day.",
      introHowItWorks: "Ghostie builds a local birthday list and surfaces upcoming dates. A birthday today opens that conversation in Messages; a future one deep-links into the scheduled-text composer — you write the message.",
      introPrivacyNote: "Birthday data is stored locally. Scheduled sends still require explicit approval before they can fire.",
      makeIntroView: BirthdayToolView.makeIntro,
      makeView: { AnyView(BirthdayToolView()) }
    ),
    ConsoleTool(
      id: "keepTabs",
      title: "Orbit",
      systemImage: "atom",
      introSummary: "Keep the people you care about in orbit.",
      introHowItWorks: "Pick the people you want to stay close to and how often to reach out, anywhere from every few days to once a year. When someone slips past that cadence by text or call, Orbit lights them up in your priority queue so they do not quietly drift. Recommendations come from who you actually text and call, with businesses filtered out.",
      introPrivacyNote: "Your orbit is stored locally. Recommendations read message and call metadata on-device: counts and dates, never message contents.",
      makeIntroView: KeepTabsView.makeIntro,
      makeView: { AnyView(KeepTabsView()) }
    ),
    ConsoleTool(
      id: "workPersonal",
      title: "Severance",
      systemImage: "briefcase.fill",
      introSummary: "Separate your Messages view into work and personal conversations.",
      introHowItWorks: "The lab lets you label conversations manually, then Messages can filter strictly by All, Work, or Personal.",
      introPrivacyNote: "Labels and your work description are stored locally. The lab starts disabled and does not change Messages until enabled.",
      makeIntroView: WorkPersonalView.makeIntro,
      makeView: { AnyView(WorkPersonalView()) }
    ),
    ConsoleTool(
      id: "eq",
      title: "EQ",
      systemImage: "heart.text.square",
      requiresAPIKey: true,
      introSummary: "Get a second read on tone and emotional context before replying.",
      introHowItWorks: "EQ uses your selected model to inspect a local thread sample and produce guidance for the conversation.",
      introPrivacyNote: "Model use requires your API key. The output is guidance only; it does not send messages.",
      makeIntroView: EQView.makeIntro,
      makeView: { AnyView(EQView()) }
    ),
    ConsoleTool(
      id: "textingAnalytics",
      title: "Texting Analytics",
      sidebarTitle: "Analytics",
      systemImage: "chart.xyaxis.line",
      introSummary: "Explore aggregate patterns in your texting behavior.",
      introHowItWorks: "Ghostie summarizes local message metadata into charts and counts so you can understand volume, timing, and relationship patterns.",
      introPrivacyNote: "Analytics are local and aggregate-oriented; product telemetry stays metadata-only.",
      makeIntroView: TextingAnalyticsView.makeIntro,
      makeView: { AnyView(TextingAnalyticsView()) }
    ),
    ConsoleTool(
      id: "textingVoice",
      title: "Style",
      sidebarTitle: "Style",
      systemImage: "waveform",
      item: .textingVoice,
      requiresAPIKey: true,
      introSummary: "Build an editable guide for how you text.",
      introHowItWorks: "Ghostie scans local aggregate texting patterns and can use your selected model to turn those into drafting guidance.",
      introPrivacyNote: "Raw message bodies are not sent for the style guide. Assistants still stage drafts for your approval.",
      makeView: { AnyView(TextingVoiceView()) }
    ),
    ConsoleTool(
      id: "babysitter",
      title: "Babysitter",
      systemImage: "figure.and.child.holdinghands",
      requiresAPIKey: true,
      featureFlag: .babysitter,
      introSummary: "Coordinate babysitting asks through your own Messages account.",
      introHowItWorks: "Curate a roster from Contacts, rank sitters for a request, and stage one ask at a time. Partner CC uses a group thread with exactly one sitter.",
      introPrivacyNote: "Roster details and stats stay local. Babysitter never sends without your approval and never creates multi-sitter blasts.",
      makeIntroView: BabysitterView.makeIntro,
      makeView: { AnyView(BabysitterView()) }
    ),
    // Future labs slot in here.
  ]

  static func visibleTools(
    from tools: [ConsoleTool] = all,
    resolved: (MFAFeatureFlag) -> Bool
  ) -> [ConsoleTool] {
    tools.filter { tool in
      guard let flag = tool.featureFlag else { return true }
      return resolved(flag)
    }
  }

  static func visibleChoosableToolIDs(resolved: (MFAFeatureFlag) -> Bool) -> [String] {
    let visibleIDs = Set(visibleTools(resolved: resolved).map(\.id))
    return ToolCatalog.choosableToolIDs.filter { visibleIDs.contains($0) }
  }
}

enum OperatorAppearance: String, CaseIterable {
  case system
  case light
  case dark

  var label: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  var systemImage: String {
    switch self {
    case .system: return "circle.lefthalf.filled"
    case .light: return "sun.max"
    case .dark: return "moon"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

private enum GhostieShellMetric {
  static let sidebarWidth: CGFloat = 246
  static let brandMarkSize: CGFloat = 68
  /// Rail brand mark: compact when collapsed, hero when expanded. The rail
  /// reserves the EXPANDED footprint at all times (see `railGhostMark`) so the
  /// menu rows below never shift when the ghost grows.
  static let railBrandCollapsed: CGFloat = 56
  static let railBrandExpanded: CGFloat = 112
  /// Rail widths. The content reserves only the collapsed width as a gutter; the
  /// expanded rail floats over the content (see `consoleLayout`).
  static let railCollapsedWidth: CGFloat = 60
  static let railExpandedWidth: CGFloat = 230
}

/// Decoded brand images for the rail, memoized by resource name.
///
/// `railGhostMark` re-evaluates on every frame of the expand/collapse animation;
/// before this cache it called `NSImage(contentsOf:)` — a synchronous disk read
/// + PNG decode — each of those frames, which blocked the main thread and made
/// the drawer open visibly stutter. Loading once and reusing the decoded image
/// removes that per-frame I/O. Main-actor isolated since it's only touched from
/// view bodies.
@MainActor
private enum RailBrandImageStore {
  private static var cache: [String: NSImage] = [:]

  static func image(named resourceName: String) -> NSImage? {
    if let cached = cache[resourceName] { return cached }
    guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png", subdirectory: "Ghostie"),
          let image = NSImage(contentsOf: url) else { return nil }
    cache[resourceName] = image
    return image
  }
}

/// The first-tier desktop window — THE primary UI, opened by tapping the
/// menu-bar icon. Selection lives in the shared `ConsoleNavigation` (not local
/// @State) so the status item can open the console straight to a tab — Drafts on
/// a left-click, Settings from the right-click menu.
struct ConsoleView: View {
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var automations: AutomationStore
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var imessageDaemon: IMessageDaemonController
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController
  @EnvironmentObject var updater: UpdaterController
  @EnvironmentObject var textingVoice: TextingVoiceController
  @EnvironmentObject var entitlements: EntitlementStore
  @EnvironmentObject var featureFlags: FeatureFlagStore
  @EnvironmentObject private var control: ControlManifestController
  @EnvironmentObject private var nav: ConsoleNavigation
  @EnvironmentObject private var messagesViewState: MessagesViewState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openWindow) private var openWindow
  @AppStorage("operatorAppearance") private var operatorAppearance: OperatorAppearance = .system
  /// Main IA: the labs are the product; the AI-connector surfaces
  /// (drafts staged by assistants, automations, scheduled sends, history,
  /// Texting Voice) live in a section that is hidden until enabled. Defaults
  /// on so existing users keep their workflow; fresh onboarding flips it.
  @AppStorage("aiConnectorEnabled") private var aiConnectorEnabled = true
  /// Hidden toggle: Option-clicking the footer version string flips this.
  /// Gates the Settings → Developer group (feature-flag overrides).
  @AppStorage("developerModeEnabled") private var developerModeEnabled = false
  @State private var devModeNotice: String?
  @State private var devModeNoticeToken = UUID()
  /// Sidebar edit mode: toggle tools on/off + drag-to-reorder inline (replaces
  /// the Settings → Tools toggles). Entered via the pencil in the footer.
  @State private var sidebarEditing = false
  /// The tool ID currently being dragged in edit mode (drives the reorder).
  @State private var draggingToolID: String?
  /// User's custom Human-Tools order, persisted as a CSV of tool IDs. Empty =
  /// fall back to the built-in `labSidebarOrder`. UI-only preference, so it
  /// lives in AppStorage rather than the settings JSON.
  @AppStorage("labToolOrder") private var labToolOrderRaw = ""
  private var labToolOrder: [String] {
    labToolOrderRaw.split(separator: ",").map(String.init)
  }
  @State private var isRailHovered = false
  @State private var railHoverTask: Task<Void, Never>? = nil
  @State private var hoveredRailItem: ConsoleItem? = nil
  /// The rail shows labels (and full width) while hovered OR while editing —
  /// edit mode needs the room for the show/hide toggle and drag handle, and must
  /// not collapse out from under the user when the pointer drifts off the rail.
  private var railExpanded: Bool { isRailHovered || sidebarEditing }
  /// The active detail pane's background, published up via `DetailBackgroundKey`.
  /// Themed labs (Keep Tabs, Don't Ghost, …) paint their own full-bleed paper; we
  /// adopt it for the rail + the under-titlebar strip so the whole window reads as
  /// one surface. nil → the neutral shell content color.
  @State private var detailBackground: Color?
  private var effectiveScheme: ColorScheme { preferredAppearance ?? colorScheme }
  /// Fill shared by the rail and the under-titlebar strip: the active pane's color,
  /// or the shell content color for unthemed tools. The rail is set apart by depth
  /// (the seam shadow), not hue.
  private var railFill: Color { detailBackground ?? DS.Color.ghostieShellContent(effectiveScheme) }

  /// The solid title bar behind the traffic-light buttons. Fixed to the app
  /// shell color (and the app's resolved scheme, never a pane's forced scheme)
  /// so it reads identically no matter which tab — including fixed-dark Orbit —
  /// is selected. ~28pt is the standard macOS title-bar height.
  private var consoleTopBar: some View {
    DS.Color.ghostieShellContent(effectiveScheme)
      .frame(height: 28)
      .overlay(alignment: .bottom) {
        DS.Color.ghostieShellLine(effectiveScheme).frame(height: 1)
      }
  }

  private var effectiveSidebarWidth: CGFloat {
    railExpanded ? GhostieShellMetric.railExpandedWidth : GhostieShellMetric.railCollapsedWidth
  }
  /// Experience-mode + feature-flag filtered, but NOT enabled-filtered: the full
  /// set of tools the user *could* turn on. Edit mode shows these (greying out
  /// the off ones); ordering is computed from this base.
  private var experienceFlagTools: [ConsoleTool] {
    ToolRegistry.visibleTools(
      from: Self.toolsForExperienceMode(settings.appExperienceMode),
      resolved: { featureFlags.resolved($0) }
    )
  }

  private var visibleTools: [ConsoleTool] {
    // The user's chosen (enabled) tools. Settings files that predate the picker
    // load with every tool enabled, so existing users see no change.
    experienceFlagTools.filter { settings.isToolEnabled($0.id) }
  }

  /// Every choosable Human-Tools lab in display order (enabled AND disabled) —
  /// what edit mode renders. Messages is first-tier and Texting Voice lives in
  /// the AI-connector section, so both are excluded here.
  private var orderedLabTools: [ConsoleTool] {
    Self.orderLabTools(
      experienceFlagTools.filter { $0.item != .messages && $0.item != .textingVoice },
      saved: labToolOrder
    )
  }

  /// Enabled labs only — the normal (non-editing) sidebar list.
  private var labTools: [ConsoleTool] {
    orderedLabTools.filter { settings.isToolEnabled($0.id) }
  }

  /// Sort the lab tools by the user's saved order (CSV of IDs), falling back to
  /// the built-in `labSidebarOrder` rank then title for any tool the saved list
  /// doesn't mention (so a newly-shipped lab slots in at its default rank).
  static func orderLabTools(_ tools: [ConsoleTool], saved: [String]) -> [ConsoleTool] {
    tools.sorted { lhs, rhs in
      let li = saved.firstIndex(of: lhs.id)
      let ri = saved.firstIndex(of: rhs.id)
      switch (li, ri) {
      case let (l?, r?): return l < r
      case (.some, .none): return true
      case (.none, .some): return false
      case (.none, .none):
        let lhsRank = labSidebarOrder[lhs.id] ?? Int.max
        let rhsRank = labSidebarOrder[rhs.id] ?? Int.max
        if lhsRank == rhsRank {
          return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhsRank < rhsRank
      }
    }
  }

  /// Reorder `dragged` to sit where `target` is, then persist the full order.
  private func moveLabTool(_ dragged: String, before target: String) {
    guard dragged != target else { return }
    var ids = orderedLabTools.map(\.id)
    guard let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target) else { return }
    ids.remove(at: from)
    ids.insert(dragged, at: to)
    labToolOrderRaw = ids.joined(separator: ",")
  }

  private func setToolEnabled(_ tool: ConsoleTool, _ enabled: Bool) {
    settings.setToolEnabled(tool.id, enabled)
    // Don't strand the detail pane on a tool the user just hid.
    if !enabled, nav.selection == tool.item {
      nav.selection = .messages
    }
  }

  private var styleTool: ConsoleTool? {
    Self.toolsForExperienceMode(settings.appExperienceMode)
      .first { $0.item == .textingVoice }
  }

  private static let labSidebarOrder: [String: Int] = [
    "dontGhost": 0,
    "eq": 1,
    "birthdays": 2,
    "keepTabs": 3,
    "wrapped": 4,
    "workPersonal": 5,
    "textingAnalytics": 6,
  ]

  private var activeDraftCount: Int { store.drafts.filter { !$0.isSent && !$0.isScheduled }.count }
  private var scheduledDraftCount: Int { store.drafts.filter { !$0.isSent && $0.isScheduled }.count }
  private var activeAutomationCount: Int { automations.enabledCount }
  private var automationAttentionCount: Int { activeAutomationCount + automations.pendingApprovalCount }
  private var settingsNeedsAttention: Bool {
    (settings.imessageEnabled && imessageDaemon.status.needsUserAttention) ||
      (settings.whatsappEnabled && whatsappDaemon.needsUserAttention)
  }

  var body: some View {
    VStack(spacing: 0) {
      // A solid title bar that owns the area behind the traffic-light buttons.
      // The window is fullSizeContentView + transparent-titlebar, so without this
      // the detail pane fills up behind the buttons — fine for light panes, but a
      // fixed-dark pane like Orbit bleeds black up there. A fixed shell-colored
      // bar (NOT the pane-adopted railFill) keeps it solid + identical on every tab.
      consoleTopBar
      // Control-manifest banner (issue #76): shown above everything when present.
      ControlManifestBannerView()
      splitView
    }
    .onPreferenceChange(DetailBackgroundKey.self) { detailBackground = $0 }
    .background(ConsoleWindowChrome())
    // Paint an opaque fill behind everything, extending under the hidden title
    // bar. The rail/detail backgrounds only cover the area BELOW the title-bar
    // safe area, so without this the strip behind the traffic lights stays
    // transparent and shows whatever's behind the window. Uses the same fill as
    // the rail so the whole top reads as one surface; clipped to the window's
    // rounded corners by AppKit, so the frameless look is unchanged.
    .background(railFill.ignoresSafeArea())
    // A 1px inset stroke at the window edge gives users a clear visual target
    // for the resize cursor. Without it the transparent/frameless window blends
    // into the desktop, making the 3px resize zone nearly impossible to find.
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: DS.Stroke.regular)
        .allowsHitTesting(false)
    }
    // Forced-upgrade floor (issue #76): a blocking screen over the whole console
    // while the current build is below min_supported_version. Sending is already
    // blocked by SendGate; this drives the Sparkle update.
    .overlay {
      if control.updateRequired {
        UpdateRequiredView()
      }
    }
  }

  private var splitView: some View {
    consoleLayout
    .preferredColorScheme(preferredAppearance)
    .frame(minWidth: 1040, idealWidth: 1240, minHeight: 680, idealHeight: 820)
    .onAppear {
      // Fail-safe Terms/Privacy gate: present onboarding on a true first run
      // OR whenever the current Terms haven't been accepted (fresh install or
      // a Legal.termsVersion bump). Acceptance always precedes any permission
      // grant / data access. The onboarding window owns recording acceptance.
      if settings.shouldPresentOnboarding {
        openWindow(id: WindowID.onboarding)
      }
      normalizeSelectionForCurrentMode()
    }
    .onChange(of: settings.appExperienceMode) { _, _ in
      normalizeSelectionForCurrentMode()
    }
    .onChange(of: nav.selection) { oldValue, newValue in
      normalizeSelectionForCurrentMode()
      if let feature = Self.analyticsFeature(for: newValue) {
        AnalyticsClient.shared.safeCapture(.featureViewed, properties: [
          .feature: .string(feature.rawValue)
        ])
      }
    }
  }

  /// The console body. The icon rail is the shipping UI (no longer flagged): it's
  /// laid out manually in an HStack rather than a NavigationSplitView column
  /// because at 60px macOS collapses (hides) a split-view sidebar entirely, which
  /// would take the expand toggle with it and strand the user. A plain HStack
  /// keeps the rail width fully ours and always on screen.
  @ViewBuilder
  private var consoleLayout: some View {
    // Overlay rail: the content reserves only the COLLAPSED width as a gutter and
    // keeps a fixed frame, so expanding the rail never reflows the Messages list
    // or the transcript — only the rail's own width animates, floating over the
    // content's left edge. (Compare the push version on fix/rail-open-animation.)
    HStack(spacing: 0) {
      Color.clear
        .frame(width: GhostieShellMetric.railCollapsedWidth)
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.ghostieShellContent(colorScheme))
    }
    .overlay(alignment: .leading) {
      iconRailSidebar
        .frame(width: effectiveSidebarWidth)
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      brandBlock
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 16)

      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if !settings.isTextingWrappedOnly {
            // Messages is the hero surface: first tier, first position. A compose
            // shortcut sits at its trailing edge.
            HStack(spacing: 2) {
              sidebarRow("Messages", systemImage: "bubble.left.and.bubble.right", item: .messages)
              composeShortcutButton
            }
          }

          // Messaging queues only exist when assistants can stage work for
          // approval, but they still live in Ghostie's app-owned shell.
          if aiConnectorEnabled && !settings.isTextingWrappedOnly {
            sidebarSectionHeader("Messaging Tools")
            sidebarRow("Drafts", systemImage: "pencil", item: .drafts, badge: activeDraftCount)
            sidebarRow("Scheduled", systemImage: "clock", item: .scheduled, badge: scheduledDraftCount)
            sidebarRow(
              "Automations",
              systemImage: "repeat",
              item: .automations,
              badge: automationAttentionCount,
              badgeTone: automations.pendingApprovalCount > 0 ? .amber : .neutral
            )
          }

          sidebarSectionHeader(sidebarEditing ? "Human Tools — drag to reorder" : "Human Tools", divider: true)
          if sidebarEditing {
            ForEach(orderedLabTools) { tool in
              labEditRow(tool)
            }
          } else {
            ForEach(labTools) { tool in
              labSidebarRow(tool)
              .help(labLocked(tool) ? "Add a Claude or ChatGPT API key in Settings to use \(tool.title)." : tool.title)
            }
          }

          // What assistants use when drafting, hidden with the connector.
          if !sidebarEditing, aiConnectorEnabled && !settings.isTextingWrappedOnly, let voiceTool = styleTool {
            sidebarSectionHeader("AI Tools", divider: true)
            labSidebarRow(voiceTool)
            sidebarRow("History", systemImage: "clock.arrow.circlepath", item: .history)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
      }
      .background(railFill)

      sidebarFoot
    }
    .background(railFill)
    .overlay(alignment: .trailing) { railDepthEdge }
  }

  // MARK: - Icon rail sidebar (flagged: icon-rail)

  /// The slim icon rail: the same destinations as the classic sidebar, rendered
  /// icon-only with hairline-separated groups, a sticky pin toggle that expands
  /// to a labeled drawer, and Settings + help pinned at the bottom. Inline
  /// tool-reorder (the classic edit mode) is intentionally not carried over yet.
  private var iconRailSidebar: some View {
    VStack(spacing: 0) {
      railBrand
      ScrollView {
        VStack(spacing: 2) {
          railRow(item: .messages, title: "Messages", systemImage: "bubble.left.and.bubble.right")
          if aiConnectorEnabled && !settings.isTextingWrappedOnly {
            railSeparator
            railRow(item: .drafts, title: "Drafts", systemImage: "pencil", badge: activeDraftCount)
            railRow(item: .scheduled, title: "Scheduled", systemImage: "clock", badge: scheduledDraftCount)
            railRow(
              item: .automations,
              title: "Automations",
              systemImage: "repeat",
              badge: automationAttentionCount,
              badgeTone: automations.pendingApprovalCount > 0 ? .amber : .neutral
            )
          }
          railSeparator
          if sidebarEditing {
            // Edit mode (always expanded): every choosable lab with a show/hide
            // toggle and a drag handle — the same rows the classic sidebar uses.
            ForEach(orderedLabTools) { tool in
              labEditRow(tool)
            }
          } else {
            ForEach(labTools) { tool in
              railRow(
                item: tool.item,
                title: tool.sidebarTitle,
                systemImage: tool.systemImage,
                disabled: labLocked(tool),
                onSelect: { selectLab(tool) }
              )
              .help(labLocked(tool) ? "Add a Claude or ChatGPT API key in Settings to use \(tool.title)." : tool.title)
            }
            if aiConnectorEnabled && !settings.isTextingWrappedOnly, let voiceTool = styleTool {
              railSeparator
              railRow(
                item: voiceTool.item,
                title: voiceTool.sidebarTitle,
                systemImage: voiceTool.systemImage,
                disabled: labLocked(voiceTool),
                onSelect: { selectLab(voiceTool) }
              )
              railRow(item: .history, title: "History", systemImage: "clock.arrow.circlepath")
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
      }
      Spacer(minLength: 0)
      railSeparator
      Group {
        if railExpanded {
          // Expanded: one row, never stacked — Settings stays left-aligned and
          // flexible while the edit-tools pencil and help menu pin to the
          // trailing edge (mirrors the classic sidebar footer).
          HStack(spacing: 6) {
            railRow(item: .settings, title: "Settings", systemImage: "gearshape", attention: settingsNeedsAttention)
            sidebarEditButton
            helpMenuButton
          }
        } else {
          // Collapsed: just the Settings icon, centered like the other rail rows.
          railRow(item: .settings, title: "Settings", systemImage: "gearshape", attention: settingsNeedsAttention)
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 9)
      .padding(.top, 2)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(railFill)
    // Clip to the animating width so row labels wipe in/out cleanly under the
    // edge instead of raggedly truncating mid-transition.
    .clipped()
    // The rail floats ABOVE the content (z +1): now that it overlays the Messages
    // list it casts a soft shadow onto the content at its right edge, rather than
    // recessing into a seam (the old behind-the-UI, z -1 look). Constant so it
    // reads as a raised panel whether collapsed or expanded.
    .shadow(
      color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.18),
      radius: 11,
      x: 3,
      y: 0
    )
    .onHover { hovered in
      railHoverTask?.cancel()
      if hovered {
        // Dwell-intent: expand only if the cursor lingers ~0.35s, so a quick pass
        // along the left edge doesn't pop the full nav open — the labeled nav is
        // there when you reach for it, not on every graze. Collapse immediately on
        // leave. One transaction drives width + brand-mark + labels; `animate`
        // snaps it under Reduce Motion.
        railHoverTask = Task { @MainActor in
          try? await Task.sleep(nanoseconds: 350_000_000)
          guard !Task.isCancelled else { return }
          animate(.easeOut(duration: 0.2)) { isRailHovered = true }
        }
      } else {
        animate(.easeOut(duration: 0.2)) { isRailHovered = false }
      }
    }
  }

  /// The rail shares the content's fill, so it's differentiated by DEPTH, not
  /// hue: a soft shadow the content "casts" onto the rail at the seam makes the
  /// rail read as sitting slightly behind the main UI. Replaces the old 1px
  /// hairline divider.
  private var railDepthEdge: some View {
    LinearGradient(
      colors: [Color.clear, Color.black.opacity(colorScheme == .dark ? 0.26 : 0.07)],
      startPoint: .leading,
      endPoint: .trailing
    )
    .frame(width: 12)
    .allowsHitTesting(false)
  }

  private var railBrand: some View {
    // The wordmark moved to the title bar — the rail shows just the character,
    // centered, and it grows when the rail is expanded (more room without the
    // wordmark beside it).
    railGhostMark
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.top, 30)
      .padding(.bottom, 12)
  }

  private var railGhostMark: some View {
    // The active tab's feature illustration takes the brand-mark spot (replacing
    // the plain ghost) when the tab has one; every other tab keeps the plain
    // ghost as the home/brand default. Feature illustrations are the only assets
    // whose name carries "-transparent".
    let asset = GhostieSidebarAsset.forSelection(
      Self.normalizedSelection(nav.selection, experienceMode: settings.appExperienceMode)
    )
    let isFeatureArt = asset.rawValue.contains("-transparent")
    let resourceName = isFeatureArt ? asset.rawValue : "ghostie-plain"
    // Larger hero when the rail is expanded; compact when collapsed. Rendered at
    // the native current size so it stays crisp at both ends (the plain ghost is
    // pixel art at integer-2x; the 512px feature art downsamples cleanly).
    let size: CGFloat = railExpanded ? GhostieShellMetric.railBrandExpanded : GhostieShellMetric.railBrandCollapsed
    return Group {
      if let nsImage = RailBrandImageStore.image(named: resourceName) {
        Image(nsImage: nsImage)
          .resizable()
          // Pixel-crisp for the low-res plain ghost; smooth for the downscaled
          // 512px feature illustrations.
          .interpolation(isFeatureArt ? .high : .none)
          .scaledToFit()
          .frame(width: size, height: size)
      } else {
        GhostieSidebarMark(asset: .shellClassic, size: size, role: .brand)
      }
    }
    // Reserve the EXPANDED height at all times and center the mark in it: the
    // ghost grows about its own vertical center inside this fixed slot, so the
    // menu rows below never move when the rail opens. Height only — width stays
    // flexible so the 56pt mark still fits the 60pt collapsed rail.
    .frame(height: GhostieShellMetric.railBrandExpanded, alignment: .center)
    .id(resourceName)
    .accessibilityHidden(true)
  }

  private var railComposeButton: some View {
    Button {
      animate(.easeInOut(duration: 0.22)) { nav.selection = .messages }
      messagesViewState.pendingComposeNew = true
    } label: {
      railRowLabel(title: "New message", systemImage: "square.and.pencil", selected: false, badge: 0, badgeTone: .neutral, attention: false, disabled: false)
    }
    .buttonStyle(.plain)
    .help("New message")
    .accessibilityLabel("Compose new message")
  }

  private var railSeparator: some View {
    Rectangle()
      .fill(DS.Color.ghostieShellLine(colorScheme))
      .frame(height: 1)
      .padding(.horizontal, railExpanded ? 11 : 13)
      .padding(.vertical, 4)
  }

  /// One destination in the rail. Adapts between icon-only (collapsed) and
  /// icon + label + trailing badge (pinned). Selection paints a teal-tint pill
  /// with a teal leading bar; the title is always the hover tooltip.
  private func railRow(
    item: ConsoleItem,
    title: String,
    systemImage: String,
    badge: Int = 0,
    badgeTone: OperatorSidebarBadgeTone = .neutral,
    attention: Bool = false,
    disabled: Bool = false,
    onSelect: (() -> Void)? = nil
  ) -> some View {
    Button {
      guard !disabled else { return }
      if let onSelect {
        onSelect()
      } else {
        animate(.easeInOut(duration: 0.22)) { nav.selection = item }
      }
    } label: {
      railRowLabel(
        title: title,
        systemImage: systemImage,
        selected: nav.selection == item,
        isHovering: hoveredRailItem == item,
        badge: badge,
        badgeTone: badgeTone,
        attention: attention,
        disabled: disabled
      )
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .help(title)
    .accessibilityLabel(title)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        hoveredRailItem = hovering ? item : nil
      }
    }
  }

  private func railRowLabel(
    title: String,
    systemImage: String,
    selected: Bool,
    isHovering: Bool = false,
    badge: Int,
    badgeTone: OperatorSidebarBadgeTone,
    attention: Bool,
    disabled: Bool
  ) -> some View {
    HStack(spacing: 11) {
      ZStack(alignment: .topTrailing) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 22, height: 22)
        if !railExpanded && (badge > 0 || attention) {
          Circle()
            .fill(attention ? DS.Color.red : DS.Color.accentTeal(colorScheme))
            .frame(width: 7, height: 7)
            .offset(x: 3, y: -2)
        }
      }
      if railExpanded {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 4)
        if badge > 0 {
          Text("\(badge)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(DS.motion(reduceMotion, .easeInOut(duration: 0.2)), value: badge)
            .foregroundStyle(badgeTone == .amber ? DS.Color.amber(colorScheme) : DS.Color.ghostieShellMuted(colorScheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(DS.Color.ghostieShellControl(colorScheme)))
        } else if attention {
          Circle().fill(DS.Color.red).frame(width: 6, height: 6)
        }
      }
    }
    .foregroundStyle(selected ? DS.Color.ghostieShellInk(colorScheme) : DS.Color.ghostieShellInk2(colorScheme))
    .frame(maxWidth: .infinity, alignment: railExpanded ? .leading : .center)
    .padding(.horizontal, railExpanded ? 9 : 0)
    .frame(height: 32)
    .background {
      ZStack {
        if selected {
          RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(DS.Color.ghostieShellSelectionShadow(colorScheme))
            .offset(x: 3, y: 3)
        }
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(
            selected ? DS.Color.ghostieShellSelectedStrong(colorScheme) :
            isHovering ? DS.Color.ghostieShellHover(colorScheme) : Color.clear
          )
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .strokeBorder(selected ? DS.Color.ghostieShellSelectionStroke(colorScheme) : Color.clear, lineWidth: 1)
    }
    .opacity(disabled ? 0.5 : 1)
    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
  }

  private var brandBlock: some View {
    let asset = GhostieSidebarAsset.forSelection(
      Self.normalizedSelection(nav.selection, experienceMode: settings.appExperienceMode)
    )
    return HStack(spacing: 9) {
      GhostieSidebarMark(asset: asset, size: GhostieShellMetric.brandMarkSize, role: .brand)
      VStack(alignment: .leading, spacing: 3) {
        Text("Ghostie")
          .font(DS.Font.brandWordmark)
          .foregroundStyle(DS.Color.ghostieShellInk(colorScheme))
          .lineLimit(1)
        Text("Local texting companion")
          .font(DS.Font.brandTagline)
          .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
          .lineLimit(1)
          .minimumScaleFactor(0.88)
      }
      Spacer(minLength: 0)
    }
  }

  // The sidebar appearance toggle was removed in the footer rework — the
  // appearance picker lives in Settings → Appearance now (same @AppStorage
  // key, see SettingsView). `preferredAppearance` below still drives
  // .preferredColorScheme for the whole console.
  private var preferredAppearance: ColorScheme? {
    operatorAppearance.colorScheme
  }

  private var sidebarFoot: some View {
    VStack(alignment: .leading, spacing: 8) {
      updateFooter
      // One compact row: Settings, then the edit-tools pencil and the help menu
      // at the trailing edge. (Option-click the strip toggles developer mode.)
      HStack(spacing: 6) {
        Button {
          animate(.easeInOut(duration: 0.14)) {
            nav.selection = .settings
          }
        } label: {
          OperatorSidebarRow(
            title: "Settings",
            systemImage: "gearshape",
            selected: nav.selection == .settings,
            badge: 0,
            badgeTone: .neutral,
            attention: settingsNeedsAttention,
            disabled: false
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settingsNeedsAttention ? "Settings - attention required" : "Settings")

        sidebarEditButton
        helpMenuButton
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 9)
    .contentShape(Rectangle())
    .onTapGesture {
      // Option-click only — a plain click on the quiet footer stays inert.
      guard NSEvent.modifierFlags.contains(.option) else { return }
      toggleDeveloperMode()
    }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(DS.Color.ghostieShellLine(colorScheme))
        .frame(height: 1)
    }
  }

  /// Compose shortcut beside Messages — jumps to Messages and opens the blank
  /// new-message composer (the compose box / square.and.pencil).
  private var composeShortcutButton: some View {
    Button {
      animate(.easeInOut(duration: 0.22)) { nav.selection = .messages }
      messagesViewState.pendingComposeNew = true
    } label: {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .help("New message")
    .accessibilityLabel("Compose new message")
  }

  /// Toggle sidebar edit mode (show/hide + reorder tools inline). Quiet by
  /// default; turns teal while active and flips to a checkmark "Done".
  private var sidebarEditButton: some View {
    Button {
      animate(.easeInOut(duration: 0.16)) { sidebarEditing.toggle() }
    } label: {
      Image(systemName: sidebarEditing ? "checkmark.circle.fill" : "pencil")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(sidebarEditing ? DS.Color.accentTeal(colorScheme) : DS.Color.ghostieShellMuted(colorScheme))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .help(sidebarEditing ? "Done editing tools" : "Edit tools — show, hide, and reorder")
    .accessibilityLabel(sidebarEditing ? "Done editing tools" : "Edit tools")
  }

  /// Support cluster: one quiet menu. Help opens the site; feedback and bug
  /// reports go to the support inbox with the version pre-filled; About shows
  /// the standard panel.
  private var helpMenuButton: some View {
    Menu {
      Button("Help & Support") {
        if let url = URL(string: "https://messagesfor.ai/support.html") {
          NSWorkspace.shared.open(url)
        }
      }
      Button("Send Feedback") {
        openSupportEmail(subject: "Ghostie feedback")
      }
      Button("Report a Bug") {
        openSupportEmail(subject: "Ghostie bug report (\(SettingsView.appVersion))")
      }
      Divider()
      Button("About Ghostie") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
      }
    } label: {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
        .frame(width: 24, height: 24)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
    .help("Help, feedback, and bug reports")
    .accessibilityLabel("Help and support")
  }

  private func openSupportEmail(subject: String) {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = "support@sunriselabs.ai"
    components.queryItems = [URLQueryItem(name: "subject", value: subject)]
    if let url = components.url {
      NSWorkspace.shared.open(url)
    }
  }


  private var settingsGearButton: some View {
    Button {
      animate(.easeInOut(duration: 0.14)) {
        nav.selection = .settings
      }
    } label: {
      ZStack(alignment: .topTrailing) {
        Image(systemName: "gearshape")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(nav.selection == .settings ? DS.Color.accentTeal(colorScheme) : DS.Color.ghostieShellMuted(colorScheme))
          .frame(width: 24, height: 24)
        if settingsNeedsAttention {
          Circle()
            .fill(DS.Color.red)
            .frame(width: 6, height: 6)
            .offset(x: 1, y: -1)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(nav.selection == .settings ? DS.Color.ghostieShellSelected(colorScheme) : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .help(settingsNeedsAttention ? "Settings - attention required" : "Settings")
    .accessibilityLabel(settingsNeedsAttention ? "Settings - attention required" : "Settings")
  }

  @ViewBuilder
  private var updateFooter: some View {
    if updater.updateAvailable {
      Button {
        updater.checkForUpdates()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 13, weight: .semibold))
          Text(updateButtonTitle)
            .font(DS.Font.chip)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .foregroundStyle(DS.Color.g050(colorScheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(DS.Color.accentTeal(colorScheme))
        )
      }
      .buttonStyle(.plain)
      .disabled(!updater.canCheckForUpdates)
      .help("Download and install the available update")
      .accessibilityLabel(updateButtonTitle)
    }
  }

  private var updateButtonTitle: String {
    if let version = updater.availableUpdateVersion {
      return "Install \(version)"
    }
    return "Install update"
  }

  /// The token invalidates the revert task on a rapid re-toggle, so the
  /// notice never gets cleared by a stale timer.
  private func toggleDeveloperMode() {
    developerModeEnabled.toggle()
    devModeNotice = developerModeEnabled ? "developer mode on" : "developer mode off"
    let token = UUID()
    devModeNoticeToken = token
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard devModeNoticeToken == token else { return }
      devModeNotice = nil
    }
  }

  /// Same gate as the detail pane (PremiumGate): a subscriber without an
  /// API key must not see labs disabled in the sidebar while the detail
  /// view would happily render them.
  private func labLocked(_ tool: ConsoleTool) -> Bool {
    tool.requiresAPIKey
      && !PremiumGate.unlocked(
        subscriptionActive: entitlements.subscriptionActive,
        hasAPIKey: textingVoice.hasAnyAPIKey
      )
  }

  private func labSidebarRow(_ tool: ConsoleTool) -> some View {
    sidebarRow(
      tool.sidebarTitle,
      systemImage: tool.systemImage,
      item: tool.item,
      disabled: labLocked(tool),
      onSelect: {
        selectLab(tool)
      }
    )
  }

  /// One row in sidebar edit mode: an on/off toggle, the tool, and a drag handle.
  /// Tapping the toggle (or the row) flips visibility; the handle drag reorders.
  private func labEditRow(_ tool: ConsoleTool) -> some View {
    let enabled = settings.isToolEnabled(tool.id)
    return HStack(spacing: 10) {
      Button {
        animate(.easeInOut(duration: 0.16)) { setToolEnabled(tool, !enabled) }
      } label: {
        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(enabled ? DS.Color.accentTeal(colorScheme) : DS.Color.ghostieShellMuted(colorScheme))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(enabled ? "Hide \(tool.title)" : "Show \(tool.title)")

      Image(systemName: tool.systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
        .frame(width: 22)
      Text(tool.sidebarTitle)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.Color.ghostieShellInk2(colorScheme))
        .lineLimit(1)
      Spacer(minLength: 6)
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
    }
    .frame(minHeight: 31)
    .padding(.horizontal, 9)
    .opacity(enabled ? 1 : 0.5)
    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .fill(draggingToolID == tool.id ? DS.Color.ghostieShellHover(colorScheme) : .clear)
    )
    .onTapGesture {
      animate(.easeInOut(duration: 0.16)) { setToolEnabled(tool, !enabled) }
    }
    .onDrag {
      draggingToolID = tool.id
      return NSItemProvider(object: tool.id as NSString)
    }
    .onDrop(
      of: [.text],
      delegate: LabReorderDropDelegate(
        target: tool.id,
        dragging: $draggingToolID,
        move: { dragged in
          animate(.easeInOut(duration: 0.16)) { moveLabTool(dragged, before: tool.id) }
        }
      )
    )
  }

  /// `divider: true` draws a hairline above the header so the tool groups
  /// (Messaging / Human / AI) read as distinct sections.
  private func sidebarSectionHeader(_ title: String, divider: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if divider {
        Rectangle()
          .fill(DS.Color.ghostieShellLine(colorScheme))
          .frame(height: 1)
          .padding(.horizontal, 9)
          .padding(.top, 10)
      }
      Text(title)
        .font(DS.Font.monoKicker)
        .tracking(0.4)
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
        .textCase(.uppercase)
        .padding(.horizontal, 9)
        .padding(.top, divider ? 8 : 12)
        .padding(.bottom, 5)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sidebarRow(
    _ title: String,
    systemImage: String,
    item: ConsoleItem,
    badge: Int = 0,
    badgeTone: OperatorSidebarBadgeTone = .neutral,
    attention: Bool = false,
    disabled: Bool = false,
    onSelect: (() -> Void)? = nil
  ) -> some View {
    Button {
      guard !disabled else { return }
      if let onSelect {
        onSelect()
      } else {
        animate(.easeInOut(duration: 0.14)) {
          nav.selection = item
        }
      }
    } label: {
      OperatorSidebarRow(
        title: title,
        systemImage: systemImage,
        selected: nav.selection == item,
        badge: badge,
        badgeTone: badgeTone,
        attention: attention,
        disabled: disabled
      )
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityLabel(title)
  }

  @ViewBuilder
  private var detail: some View {
    // Lab intros were removed — selecting a tool goes straight to its content.
    // .id + opacity transition cross-fades the detail on selection change (the
    // selection mutations already run inside the reduce-motion-gated animate()),
    // so panes no longer hard-cut between Messages / Drafts / Settings.
    let selection = Self.normalizedSelection(nav.selection, experienceMode: settings.appExperienceMode)
    detailContent(for: selection)
      .id(selection)
      .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
  }

  @ViewBuilder
  private func detailContent(for selection: ConsoleItem) -> some View {
    switch selection {
    case .messages:
      MessagesPane()
    case .drafts:
      DraftsPane()
    case .scheduled:
      ScheduledPane()
    case .history:
      HistoryPane()
    case .automations:
      AutomationsView()
    case .textingVoice:
      TextingVoiceView()
    case .tool(let id):
      if let tool = visibleTools.first(where: { $0.id == id }) {
        if tool.requiresAPIKey,
           !PremiumGate.unlocked(
             subscriptionActive: entitlements.subscriptionActive,
             hasAPIKey: textingVoice.hasAnyAPIKey
           ) {
          DisabledLabView(title: tool.title, systemImage: tool.systemImage)
        } else {
          tool.makeView()
        }
      } else {
        DraftsPane()
      }
    case .settings:
      // Reuse the existing settings surface inside the console pane.
      SettingsView()
    }
  }

  private func animate(_ animation: Animation, _ updates: () -> Void) {
    if reduceMotion {
      updates()
    } else {
      withAnimation(animation, updates)
    }
  }

  private func normalizeSelectionForCurrentMode() {
    let normalized = Self.normalizedSelection(nav.selection, experienceMode: settings.appExperienceMode)
    if nav.selection != normalized {
      nav.selection = normalized
    }
  }

  private func selectLab(_ tool: ConsoleTool) {
    animate(.easeInOut(duration: 0.14)) {
      nav.selection = tool.item
    }
  }

  private func labTool(for item: ConsoleItem?) -> ConsoleTool? {
    Self.labTool(for: item, tools: visibleTools)
  }

  static func labTool(for item: ConsoleItem?, tools: [ConsoleTool] = ToolRegistry.all) -> ConsoleTool? {
    guard let item else { return nil }
    return tools.first { $0.item == item }
  }

  static func toolsForExperienceMode(_ experienceMode: AppExperienceMode) -> [ConsoleTool] {
    experienceMode == .textingWrappedOnly ? ToolRegistry.all.filter { $0.id == "wrapped" } : ToolRegistry.all
  }

  static func normalizedSelection(_ item: ConsoleItem?, experienceMode: AppExperienceMode) -> ConsoleItem {
    let fallback: ConsoleItem = experienceMode == .textingWrappedOnly ? .tool("wrapped") : .messages
    guard let item else { return fallback }
    return isSelectionAllowed(item, experienceMode: experienceMode) ? item : fallback
  }

  static func isSelectionAllowed(_ item: ConsoleItem, experienceMode: AppExperienceMode) -> Bool {
    guard experienceMode == .textingWrappedOnly else { return true }
    switch item {
    case .tool("wrapped"), .settings:
      return true
    default:
      return false
    }
  }

  private static func analyticsFeature(for item: ConsoleItem?) -> AnalyticsFeature? {
    switch item {
    case .messages, .drafts, .scheduled, .history:
      return .messages
    case .automations:
      return .automations
    case .settings:
      return .settings
    case .textingVoice:
      return .textingStyle
    case .tool(let id):
      switch id {
      case "textingVoice": return .textingStyle
      case "dontGhost": return .dontGhost
      case "eq": return .eq
      case "textingAnalytics": return .textingAnalytics
      case "wrapped": return .wrapped
      case "birthdays": return .birthdayTexts
      case "workPersonal": return .messages
      default: return nil
      }
    case .none:
      return nil
    }
  }
}

private enum GhostieSidebarAsset: String {
  case shellClassic = "ghostie-shell-mark-polished-v4"
  case classic = "ghostie-macos-icon-classic-clean-v3"
  case classicBubble = "ghostie-macos-icon-classic-bubble-v3"
  case utility = "ghostie-macos-icon-classic-utility-v3"
  // Scheduled tab → transparent feature illustration (was the v2 approval mark).
  case approval = "ghostie-feature-scheduled-transparent"
  // The lighthouse-keeper scene (not the old orange-beanie pixel mark) — shown
  // full-bleed in the rounded brand card (no "-feature-" → needsInset == false).
  case keepTabs = "ghostie-keep-tabs-scene"
  case automations = "ghostie-feature-automations-v2"
  case birthday = "ghostie-feature-birthday-texts-transparent"
  case dontGhost = "ghostie-feature-dont-ghost-transparent"
  case drafts = "ghostie-feature-drafts-transparent"
  case textingVoice = "ghostie-feature-texting-voice-v2"
  // EQ tab → transparent feature illustration (was the v2 tone-check mark).
  case toneCheck = "ghostie-feature-eq-transparent"
  case wrapped = "ghostie-feature-wrapped-v2"
  // Severance (Work/Personal) tab → transparent feature illustration.
  case office = "ghostie-feature-severance-transparent"
  case analytics = "ghostie-feature-analytics-transparent"

  static func forSelection(_ item: ConsoleItem) -> GhostieSidebarAsset {
    switch item {
    case .messages:
      return .shellClassic
    case .drafts:
      return .drafts
    case .scheduled:
      return .approval
    case .history:
      return .utility
    case .automations:
      return .automations
    case .textingVoice:
      return .textingVoice
    case .settings:
      return .utility
    case .tool(let id):
      switch id {
      case "dontGhost":
        return .dontGhost
      case "keepTabs":
        return .keepTabs
      case "birthdays":
        return .birthday
      case "workPersonal":
        return .office
      case "eq":
        return .toneCheck
      case "textingAnalytics":
        return .analytics
      case "wrapped":
        return .wrapped
      case "textingVoice":
        return .textingVoice
      default:
        return .classic
      }
    }
  }

  var image: NSImage {
    let resourceSubdirectory = "Ghostie"
    if let url = Bundle.main.url(forResource: rawValue, withExtension: "png", subdirectory: resourceSubdirectory),
       let image = NSImage(contentsOf: url) {
      return image
    }
    return NSApplication.shared.applicationIconImage
  }

  var needsInset: Bool {
    rawValue.contains("-feature-")
  }
}

private struct GhostieSidebarMark: View {
  enum Role {
    case brand
    case compact
  }

  let asset: GhostieSidebarAsset
  var size: CGFloat = 38
  var role: Role = .compact
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Image(nsImage: asset.image)
      .resizable()
      .interpolation(role == .brand ? .high : .none)
      .scaledToFit()
      .padding(imageInset)
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(DS.Color.ghostieShellCardStrong(colorScheme))
      )
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(DS.Color.ghostieShellLine(colorScheme), lineWidth: 1)
      }
      .id(asset.rawValue)
      .transition(.opacity.combined(with: .scale(scale: 0.96)))
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: asset.rawValue)
      .accessibilityHidden(true)
  }

  private var cornerRadius: CGFloat {
    role == .brand ? 16 : min(14, size * 0.25)
  }

  private var imageInset: CGFloat {
    guard asset.needsInset else { return 0 }
    return role == .brand ? size * 0.035 : size * 0.1
  }
}

private struct OperatorSidebarRow: View {
  let title: String
  let systemImage: String
  let selected: Bool
  let badge: Int
  let badgeTone: OperatorSidebarBadgeTone
  let attention: Bool
  let disabled: Bool

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(selected ? DS.Color.ghostieShellInk(colorScheme) : DS.Color.ghostieShellMuted(colorScheme))
        .frame(width: 22)

      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(selected ? DS.Color.ghostieShellInk(colorScheme) : DS.Color.ghostieShellInk2(colorScheme))
        .lineLimit(1)

      Spacer(minLength: 6)

      if badge > 0 {
        Text("\(badge)")
          .font(DS.Font.chip)
          .monospacedDigit()
          .contentTransition(.numericText())
          .animation(DS.motion(reduceMotion, .easeInOut(duration: 0.2)), value: badge)
          .foregroundStyle(badgeForeground)
          .frame(minWidth: 18, minHeight: 16)
          .padding(.horizontal, 5)
          .background(Capsule().fill(badgeBackground))
      }

      if attention {
        Circle()
          .fill(DS.Color.red)
          .frame(width: 6, height: 6)
          .accessibilityLabel("Needs attention")
      }

      if disabled {
        Image(systemName: "lock.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
      }
    }
    .frame(minHeight: 31)
    .padding(.horizontal, 9)
    .background {
      ZStack {
        if selected {
          RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(DS.Color.ghostieShellSelectionShadow(colorScheme))
            .offset(x: 3, y: 3)
        }
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(rowFill)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .strokeBorder(rowStroke, lineWidth: selected ? 1 : 0)
    }
    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.14)) {
        isHovering = hovering
      }
    }
    .opacity(disabled ? 0.56 : 1)
  }

  private var rowFill: Color {
    if disabled { return .clear }
    if selected { return DS.Color.ghostieShellSelectedStrong(colorScheme) }
    if isHovering { return DS.Color.ghostieShellHover(colorScheme) }
    return .clear
  }

  private var rowStroke: Color {
    selected ? DS.Color.ghostieShellSelectionStroke(colorScheme) : .clear
  }

  private var badgeForeground: Color {
    badgeTone.text(colorScheme)
  }

  private var badgeBackground: Color {
    badgeTone.background(colorScheme)
  }
}

/// A themed detail pane publishes its full-bleed background color so the console
/// chrome (rail + under-titlebar strip) can adopt it. Unthemed panes publish
/// nothing, leaving the neutral shell color.
struct DetailBackgroundKey: PreferenceKey {
  static let defaultValue: Color? = nil
  static func reduce(value: inout Color?, nextValue: () -> Color?) {
    if let next = nextValue() { value = next }
  }
}

extension View {
  /// Adopt this view's background as the console chrome color (rail + titlebar
  /// strip), so a themed lab tints the whole window as one surface.
  func consoleChromeBackground(_ color: Color) -> some View {
    preference(key: DetailBackgroundKey.self, value: color)
  }
}

private struct ConsoleWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { apply(to: view.window) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { apply(to: view.window) }
  }

  private func apply(to window: NSWindow?) {
    guard let window else { return }
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    // The "Ghostie" wordmark now lives in the title bar as plain system text
    // (the SwiftUI scene title is already "Ghostie"); the rail just shows the
    // character mark. Keep the title visible over our solid title-bar fill.
    window.titleVisibility = .visible
    window.title = WindowTitle.main
    window.toolbar?.isVisible = false
    if #available(macOS 11.0, *) {
      window.titlebarSeparatorStyle = .none
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      window.titleVisibility = .visible
      window.title = WindowTitle.main
    }
  }
}

/// Drag-to-reorder for sidebar edit mode: while a tool is dragged, hovering over
/// another row moves it there live, so the list reorders under the cursor.
private struct LabReorderDropDelegate: DropDelegate {
  let target: String
  @Binding var dragging: String?
  let move: (String) -> Void

  func dropEntered(info: DropInfo) {
    guard let dragging, dragging != target else { return }
    move(dragging)
  }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    dragging = nil
    return true
  }
}

enum OperatorSidebarBadgeTone {
  case neutral
  case amber

  func background(_ scheme: ColorScheme) -> Color {
    switch self {
    case .neutral:
      // Inverted ink chip: shell ink as the fill, inverse ink as the text.
      return DS.Color.ghostieShellInk(scheme)
    case .amber:
      return DS.Color.amber(scheme)
    }
  }

  func text(_ scheme: ColorScheme) -> Color {
    switch self {
    case .neutral:
      return scheme == .dark ? DS.Color.hex(0x111111) : DS.Color.hex(0xFFFFFF)
    case .amber:
      return DS.Color.hex(0x111111)
    }
  }
}

private struct DisabledLabView: View {
  let title: String
  let systemImage: String

  @EnvironmentObject private var nav: ConsoleNavigation
  @EnvironmentObject private var settingsFocus: SettingsFocusController
  @EnvironmentObject private var featureFlags: FeatureFlagStore
  @Environment(\.colorScheme) private var colorScheme

  private var copy: LockedLabCopy {
    LockedLabCopy.select(
      lead: "\(title) uses AI on your messages",
      premiumMessagingEnabled: featureFlags.resolved(.premiumMessaging),
      subscriptionsLive: PremiumFlags.subscriptionsLive
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(title, systemImage: systemImage)
        .font(DS.Font.paneTitle)
        .foregroundStyle(DS.Color.ink(colorScheme))
      VStack(alignment: .leading, spacing: 12) {
        Label(copy.badge, systemImage: copy.badgeSystemImage)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text(copy.body)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          if copy.showsSubscribe {
            Button {
              if let url = URL(string: "https://messagesfor.ai/account.html") {
                NSWorkspace.shared.open(url)
              }
            } label: {
              Label("Subscribe", systemImage: "person.crop.circle.badge.checkmark")
            }
            .dsButton(.primary)
            Button {
              settingsFocus.target = .ai
              nav.selection = .settings
            } label: {
              Label("Use my own key", systemImage: "key")
            }
            .dsButton(.secondary)
          } else {
            Button {
              settingsFocus.target = .ai
              nav.selection = .settings
            } label: {
              Label("Add my API key", systemImage: "key")
            }
            .dsButton(.primary)
          }
        }
      }
      .padding(18)
      .frame(maxWidth: 520, alignment: .leading)
      .dsCard(colorScheme)
      Spacer()
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DS.Color.g100(colorScheme))
  }
}
