import SwiftUI

/// First-run window. Presented when `SettingsStore.shouldPresentOnboarding`
/// is true (true first run, or a Terms version bump).
///
/// Choose-your-own-adventure: instead of a binary Wrapped-vs-Full pick, the
/// user multi-selects the tools they actually want. Every tool starts
/// selected — the user unchecks what they don't want; "Just Texting Wrapped"
/// is one click. Clicking the primary button writes the choices into
/// `~/.messages-mcp/settings.json` and routes:
///
///   - Wrapped only → the lightweight experience mode, straight to the
///     Wrapped pane.
///   - Messages chosen with WhatsApp toggled → QR pairing window.
///   - Anything else → the console, landed on the first chosen tool.
///
/// Permission prompting is lazy by design: onboarding asks for NOTHING up
/// front. Each tool's pane requests the minimum it needs (Full Disk Access,
/// optional Contacts) the first time it's used. There are deliberately no
/// AI-provider or API-key steps here — AI labs carry their own unlock paths
/// in-pane (Subscribe / bring your own key).
struct OnboardingView: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController
  @EnvironmentObject var imessageDaemon: IMessageDaemonController
  @EnvironmentObject private var featureFlags: FeatureFlagStore
  @EnvironmentObject private var nav: ConsoleNavigation

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  // Local state while the user is making their picks. We don't write to
  // SettingsStore until the primary button — premature writes would surface
  // partial state to the MCP server before the user has confirmed.
  @State private var chosenTools: Set<String> = Set(ToolCatalog.choosableToolIDs)
  @State private var whatsapp: Bool = false
  @State private var productAnalytics: Bool = false
  @State private var loadedInitialState = false
  /// Required Terms/Privacy acceptance. The primary button is disabled until
  /// this is on — acceptance must precede any permission grant / data access.
  @State private var termsAccepted: Bool = false

  /// Compact per-tool captions for the picker cards. Titles and icons come
  /// from `ToolRegistry` so the picker and the sidebar always agree.
  private static let toolCaptions: [String: String] = [
    ToolCatalog.wrapped: "A shareable story from your texting year.",
    ToolCatalog.messages: "iMessage and WhatsApp in one inbox.",
    ToolCatalog.birthdays: "Never miss a birthday text.",
    ToolCatalog.dontGhost: "Catch threads you forgot to answer.",
    ToolCatalog.eq: "A second read on tone before you reply.",
    ToolCatalog.textingAnalytics: "Charts on how you actually text.",
    ToolCatalog.workPersonal: "Keep work and personal separate.",
    ToolCatalog.babysitter: "Coordinate sitter asks one at a time.",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      termsAcceptanceRow

      VStack(alignment: .leading, spacing: 10) {
        presetRow
        toolGrid
      }

      if visibleChosenTools.contains(ToolCatalog.messages) {
        whatsappRow
      }

      settingsRow(
        systemImage: "chart.bar.xaxis",
        title: "Optionally share privacy-safe product analytics",
        subtitle: "Helps improve Ghostie. Sends only allowlisted product events and coarse metadata through PostHog; never message bodies, drafts, prompts, recipients, contact names, IDs, API keys, autocapture, or session replay.",
        isOn: $productAnalytics,
        enabled: true
      )

      permissionsFootnote

      Spacer(minLength: 4)

      HStack {
        Spacer()
        Button(primaryButtonTitle) {
          commit()
        }
        .keyboardShortcut(.defaultAction)
        .dsButton(.primary)
        .disabled(!Self.canCommit(termsAccepted: termsAccepted, chosenTools: visibleChosenTools))
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      guard !loadedInitialState else { return }
      chosenTools = Self.initialChosenTools(
        firstRunComplete: settings.firstRunComplete,
        storedMode: settings.appExperienceMode,
        storedTools: settings.enabledToolIDs,
        choosableToolIDs: availableChoosableToolIDs
      )
      whatsapp = settings.firstRunComplete ? settings.whatsappEnabled : false
      productAnalytics = Self.initialProductAnalyticsValue(
        storedValue: settings.productAnalyticsEnabled,
        preferenceRecorded: settings.productAnalyticsPreferenceRecorded
      )
      termsAccepted = settings.termsAccepted
      loadedInitialState = true
    }
    .onChange(of: availableChoosableToolIDs) { _, available in
      chosenTools = Self.normalizedChosenTools(chosenTools, choosableToolIDs: available)
    }
  }

  private var availableChoosableToolIDs: [String] {
    ToolRegistry.visibleChoosableToolIDs(resolved: { featureFlags.resolved($0) })
  }

  private var visibleChosenTools: Set<String> {
    chosenTools.intersection(Set(availableChoosableToolIDs))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(settings.isTextingWrappedOnly && settings.firstRunComplete ? "Continue setup" : "Welcome")
        .font(.title2.weight(.semibold))
      Text("Pick what you want to use. You can add or remove tools any time in Settings.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var primaryButtonTitle: String {
    if chosenTools == ToolCatalog.wrappedOnlyToolIDs {
      return "Start Texting Wrapped"
    }
    return settings.isTextingWrappedOnly && settings.firstRunComplete ? "Continue Setup" : "Get Started"
  }

  // MARK: - Pure helpers (covered by SettingsStoreTests)

  static func initialProductAnalyticsValue(storedValue: Bool, preferenceRecorded: Bool) -> Bool {
    preferenceRecorded ? storedValue : false
  }

  /// Fresh installs start with every tool selected — the user unchecks what
  /// they don't want. A Wrapped-only user who reopens onboarding ("Continue
  /// setup") likewise sees the full set; a full user re-accepting bumped Terms
  /// sees their current tool set, so re-acceptance never silently rewrites
  /// their choices.
  static func initialChosenTools(
    firstRunComplete: Bool,
    storedMode: AppExperienceMode,
    storedTools: Set<String>,
    choosableToolIDs: [String] = ToolCatalog.choosableToolIDs
  ) -> Set<String> {
    let choosable = Set(choosableToolIDs)
    guard firstRunComplete else {
      return choosable
    }
    if storedMode == .textingWrappedOnly {
      return choosable
    }
    let stored = storedTools.intersection(choosable)
    return stored.isEmpty ? choosable : stored
  }

  static func canCommit(termsAccepted: Bool, chosenTools: Set<String>) -> Bool {
    termsAccepted && !chosenTools.isEmpty
  }

  static func normalizedChosenTools(
    _ chosen: Set<String>,
    choosableToolIDs: [String]
  ) -> Set<String> {
    let choosable = Set(choosableToolIDs)
    let visible = chosen.intersection(choosable)
    if !visible.isEmpty { return visible }
    return choosable
  }

  /// Where the console lands after commit: Messages when chosen, otherwise
  /// the first chosen tool in catalog order.
  static func landingSelection(
    forChosen chosen: Set<String>,
    choosableToolIDs: [String] = ToolCatalog.choosableToolIDs
  ) -> ConsoleItem {
    if chosen.contains(ToolCatalog.messages) { return .messages }
    if let first = choosableToolIDs.first(where: { chosen.contains($0) }) {
      return .tool(first)
    }
    return .messages
  }

  // MARK: - Terms acceptance

  /// Required Terms/Privacy acceptance row, pinned at the top of the screen
  /// above the tool picker. The two phrases are tappable `Link`s; the
  /// switch must be on before the primary button enables.
  private var termsAcceptanceRow: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "checkmark.shield")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(DS.Color.accentTeal(colorScheme))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        // Inline links inside running text. SwiftUI concatenates Text +
        // Link by composing them in an HStack of segments; we lay them out
        // with a wrapping layout so the phrases stay tappable.
        VStack(alignment: .leading, spacing: 0) {
          (
            Text("I have read and agree to the ")
              + Text("[Terms of Service](\(Legal.termsURL.absoluteString))")
              + Text(" and ")
              + Text("[Privacy Policy](\(Legal.privacyURL.absoluteString))")
          )
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
          .tint(DS.Color.accentTeal(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
        }
        Text("Ghostie reads your messages locally and sends only with your approval.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      DSSwitch(label: "Agree to Terms of Service and Privacy Policy", isOn: $termsAccepted, enabled: true)
    }
    .padding(10)
    .dsCard(colorScheme, fill: DS.Color.g080(colorScheme), radius: DS.Radius.card)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("I have read and agree to the Terms of Service and Privacy Policy")
    .accessibilityValue(termsAccepted ? "on" : "off")
  }

  // MARK: - Tool picker

  /// A one-click shortcut above the grid for the lightweight Wrapped-only
  /// path. Every tool is selected by default, so there's no "recommended"
  /// preset — just this escape hatch for people who only want Texting Wrapped.
  /// The grid below stays freely editable after tapping it.
  private var presetRow: some View {
    HStack(spacing: 8) {
      presetButton(
        "Just Texting Wrapped",
        active: chosenTools == ToolCatalog.wrappedOnlyToolIDs
      ) {
        chosenTools = ToolCatalog.wrappedOnlyToolIDs
      }
      Spacer()
    }
  }

  private func presetButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(DS.Font.chip)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          Capsule().fill(active ? DS.Color.accentTeal(colorScheme).opacity(0.14) : DS.Color.g130(colorScheme))
        )
        .overlay(
          Capsule().strokeBorder(active ? DS.Color.accentTeal(colorScheme).opacity(0.5) : DS.Color.line(colorScheme), lineWidth: 1)
        )
        .foregroundStyle(active ? DS.Color.accentTeal(colorScheme) : DS.Color.ink2(colorScheme))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title) preset")
    .accessibilityAddTraits(active ? .isSelected : [])
  }

  private var toolGrid: some View {
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
      alignment: .leading,
      spacing: 10
    ) {
      ForEach(availableChoosableToolIDs, id: \.self) { id in
        if let tool = ToolRegistry.all.first(where: { $0.id == id }) {
          toolCard(tool)
        }
      }
    }
  }

  private func toolCard(_ tool: ConsoleTool) -> some View {
    let selected = chosenTools.contains(tool.id)
    return Button {
      if selected {
        chosenTools.remove(tool.id)
      } else {
        chosenTools.insert(tool.id)
      }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: tool.systemImage)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(selected ? Color.accentColor : .secondary)
          .frame(width: 22)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(tool.title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(Self.toolCaptions[tool.id] ?? tool.introSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 4)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(selected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
      }
      .padding(10)
      .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tool.title)
    .accessibilityValue(selected ? "selected" : "not selected")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// Shown only when Messages is chosen. iMessage comes with Messages;
  /// WhatsApp is the one transport that needs an extra pairing step, so it
  /// stays an explicit opt-in here.
  private var whatsappRow: some View {
    settingsRow(
      systemImage: Platform.whatsapp.sfSymbol,
      title: "Also connect WhatsApp",
      subtitle: "Pair with a QR code right after setup. iMessage is included with Messages automatically.",
      isOn: $whatsapp,
      enabled: true
    )
  }

  /// The lazy-permissions promise, stated once and quietly. The picker never
  /// fires a system prompt; each tool asks at first use.
  private var permissionsFootnote: some View {
    let needs = ToolCatalog.permissionNeeds(forChosen: visibleChosenTools, whatsappToggled: whatsapp)
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: "lock")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .padding(.top, 1)
      Text(Self.permissionsFootnoteText(for: needs))
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  static func permissionsFootnoteText(for needs: ToolCatalog.PermissionNeeds) -> String {
    var parts: [String] = []
    if needs.fullDiskAccess {
      parts.append("Nothing is read up front — each tool asks for access to your Messages history the first time you use it.")
    }
    if needs.contactsOptional {
      parts.append("Contacts stays optional; it only improves names and birthdays.")
    }
    if needs.whatsappPairing {
      parts.append("WhatsApp pairing opens right after this.")
    }
    if parts.isEmpty {
      parts.append("No access is requested up front.")
    }
    return parts.joined(separator: " ")
  }

  private func settingsRow(
    systemImage: String,
    title: String,
    subtitle: String,
    isOn: Binding<Bool>,
    enabled: Bool
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(DS.Color.accentTeal(colorScheme))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text(subtitle)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      // Custom Button-as-switch (DSSwitch): a SwiftUI Toggle inside this
      // window historically leaked its hit-test up to the popover-era
      // window registration; DSSwitch hit-tests cleanly.
      DSSwitch(label: title, isOn: isOn, enabled: enabled)
    }
    .opacity(enabled ? 1.0 : 0.55)
    .padding(10)
    .dsCard(colorScheme, fill: DS.Color.g080(colorScheme), radius: DS.Radius.card)
  }

  // MARK: - Commit

  private func commit() {
    let chosen = chosenTools.intersection(Set(availableChoosableToolIDs))
    guard !chosen.isEmpty else { return }
    let mode = ToolCatalog.experienceMode(forChosen: chosen)
    let messagesChosen = chosen.contains(ToolCatalog.messages)
    let whatsappOn = messagesChosen && whatsapp

    settings.applyOnboardingChoices(
      experienceMode: mode,
      imessage: messagesChosen,
      whatsapp: whatsappOn,
      productAnalytics: productAnalytics,
      // UI action (not a deterministic-test path) — Date() is fine here.
      termsAcceptedAt: Date().timeIntervalSince1970,
      enabledTools: ToolCatalog.persistedTools(forChosen: chosen)
    )

    if mode == .textingWrappedOnly {
      nav.selection = .tool(ToolCatalog.wrapped)
      openWindow(id: WindowID.main)
      dismissWindow(id: WindowID.onboarding)
      return
    }

    if messagesChosen {
      imessageDaemon.start()
    }

    if whatsappOn {
      // Spin up the WhatsApp service so the pairing window finds a live
      // socket. Idempotent — safe even if it's already up. Pairing is the
      // one permission-like step that genuinely can't be deferred (the
      // transport doesn't exist without it).
      whatsappDaemon.start()
      openWindow(id: WindowID.whatsappPairing)
    } else {
      // Land in the console on the first chosen tool. No setup walkthrough
      // here: permissions are requested in-pane at first use, and the
      // Claude verification flow stays available from Settings for anyone
      // wiring up the AI loop.
      nav.selection = Self.landingSelection(
        forChosen: chosen,
        choosableToolIDs: availableChoosableToolIDs
      )
      openWindow(id: WindowID.main)
    }

    dismissWindow(id: WindowID.onboarding)
  }
}
