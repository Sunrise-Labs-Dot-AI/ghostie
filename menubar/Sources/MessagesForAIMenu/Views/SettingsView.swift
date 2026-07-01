import SwiftUI
import AppKit
import UserNotifications

/// Per-transport settings sheet, presented from the popover footer.
/// Adding a transport here is one new section block; the toggle drives
/// SettingsStore + (for WhatsApp) the background service controller.
struct SettingsView: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController
  @EnvironmentObject var imessageDaemon: IMessageDaemonController
  @EnvironmentObject var textingVoice: TextingVoiceController
  @EnvironmentObject var updater: UpdaterController
  @EnvironmentObject var messageNotifications: MessageNotificationController
  @EnvironmentObject private var settingsFocus: SettingsFocusController

  @Environment(\.openWindow) private var openWindow
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("operatorAppearance") private var operatorAppearance: OperatorAppearance = .system
  // Ungated: the Status pane reports the real last-seen call time even when
  // it's older than the walkthrough's 10-minute freshness window, so prior
  // history (which persists in ~/.messages-mcp/ across reinstalls) doesn't
  // read as "never."
  @StateObject private var invocations = LastInvocationStore(applyStalenessGate: false)
  @State private var statusRefreshTick = 0
  @State private var diagnosticsSummary = DiagnosticsStore.shared.summary()
  @State private var diagnosticsExportURL: URL?
  @State private var diagnosticsExportMessage: String?
  @State private var diagnosticsExporting = false
  @State private var showAdvancedAI = false
  @State private var advancedExpanded = false
  @EnvironmentObject private var entitlements: EntitlementStore
  @EnvironmentObject private var featureFlags: FeatureFlagStore
  /// Toggled by Option-clicking the console sidebar's version string.
  @AppStorage("developerModeEnabled") private var developerModeEnabled = false
  @State private var showAdvancedStatus = false

  private let checks = HealthChecks()

  var body: some View {
    // The native macOS title bar (set in App.swift as "Ghostie Settings")
    // is the window's chrome — no in-content header needed.
    // The Window already provides traffic-light controls + drag.
    //
    // Top padding is larger than the other sides so the iMessage section
    // header doesn't crowd the title bar. The Window frame is set in
    // App.swift; don't redeclare it here (conflicting frames let the
    // ScrollView creep up under the title bar in 14.x).
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          settingsPageHeader
          if messagingNeedsAttention {
            messagingRepairCard
          }
          // premium-messaging flag off = pure BYOK app, no account surface —
          // but a user who ALREADY pays must always reach Manage/Sign out.
          if featureFlags.resolved(.premiumMessaging) || entitlements.subscriptionActive {
            settingsGroup("Account", systemImage: "person.crop.circle") {
              accountSection
            }
          }
          // Tool show/hide moved to the sidebar's inline edit mode (the footer
          // pencil), so the Settings → Tools picker was retired to avoid two
          // sources of truth.
          settingsGroup("Messaging", systemImage: "bubble.left.and.bubble.right") {
            imessageSection
            whatsappSection
            aiConnectorRow
            scheduledMessagesSection
              .id(SettingsSection.scheduling)
          }
          .id(SettingsSection.messaging)
          settingsGroup("App", systemImage: "app.badge") {
            if settings.isTextingWrappedOnly {
              fullSetupSection
            }
            appearanceSection
            loginItemRow
            updatesSection
            notificationsSection
            mediaPreviewsSection
            telemetrySection
          }
          .id(SettingsSection.app)
          // Everything technical lives at the bottom, collapsed: BYOK keys,
          // per-lab models, connection status, diagnostics export.
          settingsGroup("Advanced", systemImage: "wrench.and.screwdriver") {
            DisclosureGroup(isExpanded: $advancedExpanded) {
              VStack(alignment: .leading, spacing: 16) {
                sendingApprovalSection
                aiKeysSection
                aiUsageSection
                statusSection
                  .id(SettingsSection.diagnostics)
                diagnosticsSupportSection
              }
              .padding(.top, 10)
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text("Keys, models, and diagnostics")
                  .font(DS.Font.settingsLabel)
                  .foregroundStyle(DS.Color.ink(colorScheme))
                Text("Bring your own AI key, control AI sending approval, choose models per tool, check connections, export diagnostics.")
                  .font(DS.Font.settingsCaption)
                  .foregroundStyle(DS.Color.ink3(colorScheme))
              }
            }
          }
          .id(SettingsSection.ai)
          // Developer group: dev-mode only, deliberately OUTSIDE the Advanced
          // disclosure so flag state is reachable without expanding it.
          if developerModeEnabled {
            settingsGroup("Developer", systemImage: "hammer") {
              developerSection
            }
          }
          versionFooter
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 16)
      }
      .onAppear {
        AnalyticsClient.shared.safeCapture(.settingsOpened)
        diagnosticsSummary = DiagnosticsStore.shared.summary()
        if settingsFocus.target == .ai || settingsFocus.target == .diagnostics { advancedExpanded = true }
        scrollToFocus(proxy)
      }
      .onChange(of: settingsFocus.target) { _, _ in
        if settingsFocus.target == .ai || settingsFocus.target == .diagnostics { advancedExpanded = true }
        scrollToFocus(proxy)
      }
    }
    .background(DS.Color.ghostieShellContent(colorScheme))
  }

  private var settingsPageHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("GHOSTIE")
        .font(DS.Font.monoKicker)
        .tracking(0.4)
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
      Text("Settings")
        .font(DS.Font.displayTitle)
        .foregroundStyle(DS.Color.ghostieShellInk(colorScheme))
      Text("Keep approvals, local services, and messaging tools in good shape.")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 8)
  }

  private var messagingNeedsAttention: Bool {
    (settings.imessageEnabled && imessageDaemon.status.needsUserAttention) ||
      (settings.whatsappEnabled && whatsappDaemon.needsUserAttention)
  }

  private var messagingRepairCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.title3)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 4) {
          Text("Messaging needs attention")
            .font(.headline)
          Text(messagingRepairSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }

      VStack(alignment: .leading, spacing: 6) {
        if settings.imessageEnabled, imessageDaemon.status.needsUserAttention {
          repairIssueRow(
            title: "iMessage reader",
            detail: imessageRepairDetail,
            symbol: "message.fill"
          )
        }
        if settings.whatsappEnabled, whatsappDaemon.needsUserAttention {
          repairIssueRow(
            title: "WhatsApp",
            detail: whatsappRepairDetail,
            symbol: Platform.whatsapp.sfSymbol
          )
        }
      }

      HStack(spacing: 10) {
        if settings.imessageEnabled, imessageDaemon.status.needsUserAttention {
          Button {
            imessageDaemon.start()
            statusRefreshTick += 1
          } label: {
            Label("Restart iMessage Reader", systemImage: "arrow.clockwise")
          }
          .dsButton(.primary, size: .small)
        }

        if settings.whatsappEnabled, whatsappDaemon.needsUserAttention {
          Button {
            if whatsappDaemon.baileysState == "logged_out" {
              openWindow(id: WindowID.whatsappPairing)
            } else {
              whatsappDaemon.start()
            }
            statusRefreshTick += 1
          } label: {
            Label(whatsappDaemon.baileysState == "logged_out" ? "Reconnect WhatsApp" : "Restart WhatsApp", systemImage: "arrow.clockwise")
          }
          .dsButton(.primary, size: .small)
        }

        Button("Re-check") {
          statusRefreshTick += 1
          invocations.refresh()
        }
        .dsButton(.secondary, size: .small)

        Button("Reveal Logs") {
          let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".messages-mcp/logs")
          NSWorkspace.shared.open(url)
        }
        .dsButton(.secondary, size: .small)

        Spacer()
      }
    }
    .padding(DS.Space.cardPadding)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.window)
        .fill(DS.Color.dangerDim(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.window)
        .stroke(DS.Color.red.opacity(0.25), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }

  private var messagingRepairSummary: String {
    var parts: [String] = []
    if settings.imessageEnabled, imessageDaemon.status.needsUserAttention {
      parts.append("iMessage reading and drafting may be unavailable until the reader restarts.")
    }
    if settings.whatsappEnabled, whatsappDaemon.needsUserAttention {
      parts.append("WhatsApp drafting or sending may be unavailable until WhatsApp reconnects.")
    }
    return parts.joined(separator: " ")
  }

  private var imessageRepairDetail: String {
    switch imessageDaemon.status {
    case .crashLooping(let count):
      return "Couldn't start after \(count) attempts. Restart the reader, then re-check."
    case .stopped:
      return "Stopped. Restart the reader to restore iMessage access."
    case .idle:
      return "Not running yet. Start the reader to restore iMessage access."
    case .backingOff(let seconds, _):
      return "Retrying in \(Int(seconds)) seconds."
    case .starting:
      return "Starting..."
    case .running:
      return "Running."
    }
  }

  private var whatsappRepairDetail: String {
    if whatsappDaemon.baileysState == "logged_out" {
      return "Logged out. Reconnect WhatsApp to restore access."
    }
    switch whatsappDaemon.status {
    case .crashLooping(let count):
      return "Couldn't connect after \(count) attempts. Restart WhatsApp, then re-check."
    case .stopped:
      return "Turned off. Restart WhatsApp to restore access."
    case .idle:
      return "Not connected yet. Start WhatsApp to restore access."
    case .backingOff(let seconds, _):
      return "Retrying in \(Int(seconds)) seconds."
    case .starting:
      return "Starting..."
    case .running:
      return connectionLabel
    }
  }

  private func repairIssueRow(title: String, detail: String, symbol: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(.red)
        .frame(width: 18)
      Text(title)
        .font(.caption.weight(.semibold))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title): \(detail)")
  }

  private func scrollToFocus(_ proxy: ScrollViewProxy) {
    guard let target = settingsFocus.target else { return }
    DispatchQueue.main.async {
      withAnimation(.easeInOut(duration: 0.18)) {
        proxy.scrollTo(target, anchor: .top)
      }
      // Consume the request: a focus is one-shot. Leaving it set means a
      // repeat tap of the same target is invisible to onChange (no value
      // change → no re-expand/re-scroll) and every later plain Settings
      // open would auto-jump to the stale target.
      settingsFocus.target = nil
    }
  }

  // MARK: - Texting voice

  private var textingVoiceSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "waveform")
          .foregroundStyle(Color.accentColor)
        Text("Texting voice")
          .font(.headline)
        Spacer()
      }
      Text("A local aggregate profile assistants can use when drafting. No API key, and no message bodies are saved.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let profile = textingVoice.profile {
        infoRow(label: "Sample", value: "\(profile.sample_size) sent messages")
        infoRow(label: "Window", value: "\(shortDate(profile.window_start)) - \(shortDate(profile.window_end))")
        infoRow(label: "Typical length", value: "\(profile.length.median) chars")
      } else {
        Text(textingVoice.status.label)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        Button(textingVoiceButtonTitle) {
          textingVoice.refresh()
        }
        .dsButton(.primary, size: .small)
        .disabled(textingVoiceRefreshing)

        Button("Reveal voice files") {
          NSWorkspace.shared.open(TextingVoiceController.baseDirectory)
        }
        .dsButton(.secondary, size: .small)
        .disabled(textingVoice.profile == nil)

        Spacer()
      }

      if textingVoice.profile != nil || textingVoiceRefreshing {
        Text(textingVoice.status.label)
          .font(.caption2)
          .foregroundStyle(statusColor)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .background(DS.Color.ghostieShellControl(colorScheme).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var textingVoiceRefreshing: Bool {
    if case .loading = textingVoice.status { return true }
    return false
  }

  private var textingVoiceButtonTitle: String {
    textingVoice.profile == nil ? "Build voice" : "Refresh voice"
  }

  private var statusColor: Color {
    if case .failed = textingVoice.status { return .red }
    return .secondary
  }

  private func shortDate(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }

  // MARK: - AI keys

  @AppStorage("aiConnectorEnabled") private var aiConnectorEnabled = true

  /// Shows or hides the assistant-workflow surfaces (Drafts, Automations,
  /// Scheduled, History, Style) in the sidebar.
  private var aiConnectorRow: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Connect your messages to AI tools")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text("Adds Drafts, Automations, Scheduled, History, and Style to the sidebar for assistant-staged messaging.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Toggle("Connect to AI tools", isOn: $aiConnectorEnabled)
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel("Connect your messages to AI tools")
    }
  }

  private var accountSection: some View {
    HStack(spacing: 10) {
      Image(systemName: entitlements.subscriptionActive ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(entitlements.subscriptionActive ? DS.Color.green(colorScheme) : DS.Color.ink3(colorScheme))
      VStack(alignment: .leading, spacing: 2) {
        Text(entitlements.subscriptionActive ? "Premium" : "Free")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text(accountDetailText)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      if entitlements.subscriptionActive || PremiumFlags.subscriptionsLive {
        Button(entitlements.subscriptionActive ? "Manage" : "Sign in") {
          if let url = URL(string: "https://messagesfor.ai/account.html") {
            NSWorkspace.shared.open(url)
          }
        }
        .dsButton(.secondary, size: .small)
      } else {
        Button("Add API key") {
          settingsFocus.target = .ai
        }
        .dsButton(.secondary, size: .small)
      }
      if entitlements.subscriptionActive {
        Button("Sign out") {
          entitlements.signOut()
        }
        .dsButton(.ghost, size: .small)
      }
    }
  }

  private var accountDetailText: String {
    if entitlements.subscriptionActive {
      return entitlements.accountEmail ?? "Subscription active."
    }
    if !PremiumFlags.subscriptionsLive {
      return "Premium subscriptions are coming soon. AI features unlock free with your own API key (Advanced)."
    }
    return "AI features unlock with Premium, or free with your own API key (Advanced)."
  }

  /// BYOK cost tracking (issue #145), nested with the AI key it depends on.
  /// Hidden until the flag is on AND a key exists (no key → no spend to show).
  @ViewBuilder private var aiUsageSection: some View {
    if featureFlags.resolved(.aiUsage), textingVoice.hasAnyAPIKey {
      AIUsageSettingsSection()
    }
  }

  /// Whether the assistant must stage drafts for human approval, or may send via
  /// MCP directly. Relocated from the per-transport messaging cards into the
  /// Advanced (AI) area — it governs AI sending behavior, not a connection.
  private var sendingApprovalSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "hand.raised")
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
        Text("Require approval to send")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
      }
      Text("Ghostie's stance is \u{201C}AI proposes, you approve.\u{201D} When on, the assistant only stages drafts and you send from this app. Turn it off to let the AI send via MCP directly.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      if settings.imessageEnabled {
        labeledSwitchRow(
          title: "iMessage",
          subtitle: settings.requireApproval
            ? "Drafts only — only this app sends."
            : "AI can send via MCP directly (after a brief delay).",
          isOn: $settings.requireApproval,
          enabled: true
        )
      }
      if settings.whatsappEnabled {
        labeledSwitchRow(
          title: "WhatsApp",
          subtitle: settings.whatsappRequireApproval
            ? "Drafts only — hold-to-fire in this app sends."
            : "AI can send via MCP directly (rate-limited).",
          isOn: $settings.whatsappRequireApproval,
          enabled: true
        )
      }
      if !settings.imessageEnabled && !settings.whatsappEnabled {
        Text("Enable iMessage or WhatsApp in Messaging to set sending approval.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  private var aiKeysSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "key")
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
        Text("AI keys")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Spacer()
      }
      Text("Used only by tools that ask an AI model to reason, write, or reflect. Keys are stored locally in Keychain.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        SecureField("Paste a Claude or ChatGPT API key", text: $textingVoice.apiKeyInput)
          .dsInput(colorScheme)
        Button("Save") {
          textingVoice.saveInferredAPIKey()
        }
        .dsButton(.primary, size: .small)
        .disabled(textingVoice.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      HStack(spacing: 12) {
        Link("Create a Claude API key", destination: URL(string: "https://support.claude.com/en/articles/8114521-how-can-i-access-the-anthropic-api/")!)
        Link("Create an OpenAI/Codex API key", destination: URL(string: "https://help.openai.com/en/articles/4936850-how-to-create-and-use-an-api-key")!)
      }
      .font(DS.Font.settingsCaption)

      HStack(spacing: 8) {
        savedKeyChip(provider: .anthropic)
        savedKeyChip(provider: .openAI)
        Spacer()
      }

      DisclosureGroup(isExpanded: $showAdvancedAI) {
        VStack(alignment: .leading, spacing: 12) {
          Rectangle()
            .fill(DS.Color.line(colorScheme))
            .frame(height: 1)

          VStack(alignment: .leading, spacing: 8) {
            Text("Model selection")
              .font(DS.Font.settingsLabel)
              .foregroundStyle(DS.Color.ink(colorScheme))
            Text("Each tool has a recommended default. Override model choices only if you want tighter cost or capability control.")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .fixedSize(horizontal: false, vertical: true)
            modelPreferenceControls
          }

          Rectangle()
            .fill(DS.Color.line(colorScheme))
            .frame(height: 1)

          VStack(alignment: .leading, spacing: 8) {
            DSCheckbox(
              title: "Include sanitized identity hints",
              subtitle: nil,
              isOn: $textingVoice.includeIdentityHints
            )
            Text("Optional for better people-specific voices. Sends first-name or group-label hints when available, but still excludes message bodies, phone numbers, emails, and raw handles.")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.top, 8)
      } label: {
        Text(textingVoice.savedProviders.isEmpty ? "Advanced AI settings" : "Model and privacy details")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
      }
    }
    .padding(14)
    .dsCard(colorScheme)
    .task {
      textingVoice.refreshAvailableModelsForSavedProviders()
    }
  }

  private func savedKeyChip(provider: TextingVoiceProvider) -> some View {
    HStack(spacing: 6) {
      Image(systemName: textingVoice.hasAPIKey(for: provider) ? "checkmark.circle.fill" : "circle.dotted")
        .foregroundStyle(textingVoice.hasAPIKey(for: provider) ? DS.Color.green(colorScheme) : DS.Color.ink3(colorScheme))
      Text(textingVoice.selectedProvider == provider && textingVoice.hasAPIKey(for: provider) ? "Using \(provider.label)" : provider.label)
      if textingVoice.hasAPIKey(for: provider) {
        Button("Clear") {
          textingVoice.clearAPIKey(for: provider)
        }
        .buttonStyle(.borderless)
        .font(.caption2)
      }
    }
    .font(DS.Font.chip)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
        .fill(DS.Color.g160(colorScheme))
    )
    .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.chip)
  }

  @ViewBuilder
  private var modelPreferenceControls: some View {
    let providers = textingVoice.savedProviders
    if providers.isEmpty {
      Text("Add an API key to choose a model.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      if providers.count > 1 {
        Text("Saved providers: \(providers.map(\.label).joined(separator: ", "))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 12) {
        ForEach(AILab.allCases) { lab in
          labModelRow(lab, providers: providers)
          if lab.id != AILab.allCases.last?.id {
            Divider()
          }
        }
      }
      if let error = textingVoice.modelListError {
        Text(error)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }

  private func labModelRow(_ lab: AILab, providers: [TextingVoiceProvider]) -> some View {
    let provider = textingVoice.selectedProvider(for: lab) ?? providers.first ?? .anthropic
    return VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(lab.label)
            .font(.caption.weight(.semibold))
          Text(lab.recommendation)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if providers.count > 1 {
          DSMenuPicker(
            title: "Provider",
            options: providers,
            selection: Binding(
              get: { textingVoice.selectedProvider(for: lab) ?? provider },
              set: { textingVoice.setSelectedProvider($0, for: lab) }
            )
          ) { $0.label }
          .frame(width: 120)
        } else {
          Text(provider.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      modelPicker(for: lab, provider: provider)
      Text(textingVoice.modelCostLabel(for: lab, provider: provider))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func modelPicker(for lab: AILab, provider: TextingVoiceProvider) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        DSMenuPicker(
          title: "Model",
          options: textingVoice.availableModelOptions(for: provider).map(\.id),
          selection: Binding(
            get: { textingVoice.modelSelection(for: lab, provider: provider) },
            set: { textingVoice.setModelSelection($0, for: lab, provider: provider) }
          )
        ) { modelID in
          if let option = textingVoice.availableModelOptions(for: provider).first(where: { $0.id == modelID }) {
            return "\(option.label) - \(option.detail)"
          }
          return modelID
        }
        Button {
          textingVoice.refreshAvailableModels(for: provider)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .dsButton(.secondary, size: .small)
        .disabled(textingVoice.loadingModelsProvider == provider)
        if textingVoice.loadingModelsProvider == provider {
          ProgressView()
            .controlSize(.small)
        }
      }
      Text("Using \(textingVoice.modelSelection(for: lab, provider: provider))")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func apiKeyRow(
    provider: TextingVoiceProvider,
    placeholder: String,
    text: Binding<String>
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(provider.settingsLabel)
          .font(.callout)
        Spacer()
        Text(textingVoice.hasAPIKey(for: provider) ? "Saved" : "Not saved")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(textingVoice.hasAPIKey(for: provider) ? .green : .secondary)
      }
      HStack(spacing: 8) {
        SecureField(placeholder, text: text)
          .dsInput(colorScheme)
        Button("Save") {
          textingVoice.saveAPIKey(for: provider)
        }
        .dsButton(.primary, size: .small)
        .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if textingVoice.hasAPIKey(for: provider) {
          Button("Clear") {
            textingVoice.clearAPIKey(for: provider)
          }
          .dsButton(.secondary, size: .small)
        }
      }
    }
  }

  // MARK: - Scheduled messages

  private var scheduledMessagesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Scheduled messages")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      DSCheckbox(title: "Quiet hours", subtitle: nil, isOn: $settings.quietHoursEnabled)
      if settings.quietHoursEnabled {
        HStack(spacing: 12) {
          DSDateTimeField(title: "From", selection: timeBinding(
            get: { settings.quietStartMinute }, set: { settings.quietStartMinute = $0 }
          ), displayedComponents: .hourAndMinute)
          DSDateTimeField(title: "To", selection: timeBinding(
            get: { settings.quietEndMinute }, set: { settings.quietEndMinute = $0 }
          ), displayedComponents: .hourAndMinute)
        }
        Text("Any scheduled message that comes due during quiet hours is held and you're notified - never sent silently. Times are in your Mac's local time zone.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Rectangle()
        .fill(DS.Color.line(colorScheme))
        .frame(height: 1)
      Text("Birthday Reminders")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      HStack(spacing: 12) {
        DSDateTimeField(
          title: "Default send time",
          selection: timeBinding(
            get: { settings.birthdayDefaultSendMinute },
            set: { settings.birthdayDefaultSendMinute = $0 }
          ),
          displayedComponents: .hourAndMinute
        )
        DSMenuPicker(
          title: "Draft opens",
          options: ClaudeTarget.allCases,
          selection: $settings.birthdayClaudeTarget
        ) { $0.label }
      }
      Text("\"Draft with Claude\" opens Claude Desktop with the prompt prefilled (Codex opens regardless of this setting). Nothing is sent - you review and run it.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  /// Bridge a minutes-from-midnight Int setting to a DatePicker's Date (today
  /// anchored; only the time components are read back).
  private func timeBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
    Binding(
      get: {
        let cal = Calendar.current
        return cal.date(bySettingHour: get() / 60, minute: get() % 60, second: 0, of: Date()) ?? Date()
      },
      set: { d in
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        set((c.hour ?? 0) * 60 + (c.minute ?? 0))
      }
    )
  }

  // MARK: - iMessage

  private var imessageSection: some View {
    transportCard(
      platform: .imessage,
      title: "iMessage",
      enabledBinding: $settings.imessageEnabled
    ) {
      VStack(alignment: .leading, spacing: 10) {
        imessageDaemonRow
        // "Require approval to send" moved to Advanced → AI sending approval
        // (it governs whether the AI/MCP can send directly, not a per-transport
        // connection setting).
        // Drafts-folder path was removed: it's only the iMessage path
        // (WhatsApp uses ~/.whatsapp-mcp/drafts), making it misleading
        // when shown only under the iMessage section. The dir is also
        // a place users could corrupt the staging state by editing
        // JSON files — surfacing it as text invites that. If a future
        // "Open drafts in Finder" button is added, it should be a
        // proper button gated behind a power-user toggle.
      }
    }
  }

  /// Compact status row for the chat.db reader daemon. The daemon is what
  /// actually holds Full Disk Access (it's launched by this menu-bar app);
  /// the Claude-launched MCP is a thin client to it. No remote connection
  /// like WhatsApp — just process liveness.
  private var imessageDaemonRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(imessageDaemonColor)
        .frame(width: 8, height: 8)
      Text(imessageDaemonLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if case .crashLooping = imessageDaemon.status {
        Button("Restart") { imessageDaemon.start() }
          .dsButton(.secondary, size: .small)
      }
    }
  }

  private var imessageDaemonColor: Color {
    switch imessageDaemon.status {
    case .running: return .green
    case .starting, .backingOff: return .orange
    case .crashLooping: return .red
    case .idle, .stopped: return .gray
    }
  }

  private var imessageDaemonLabel: String {
    switch imessageDaemon.status {
    case .idle: return "Reader service: idle"
    case .starting: return "Reader service: starting…"
    case .running: return "Reader service: running"
    case .backingOff(let s, _): return "Reader service: restarting in \(Int(s))s"
    case .crashLooping: return "Reader service: couldn’t start — tap Restart"
    case .stopped: return "Reader service: stopped"
    }
  }

  // MARK: - WhatsApp

  private var whatsappSection: some View {
    transportCard(
      platform: .whatsapp,
      title: "WhatsApp",
      enabledBinding: Binding(
        get: { settings.whatsappEnabled },
        set: { newValue in
          settings.whatsappEnabled = newValue
          if newValue {
            whatsappDaemon.start()
          } else {
            Task { await whatsappDaemon.stop() }
          }
        }
      )
    ) {
      VStack(alignment: .leading, spacing: 10) {
        connectionRow
        // "Require approval to send" moved to Advanced → AI sending approval.
        // Only show a pairing action when one is actually needed:
        //  - "Connect WhatsApp…" if the user has never paired
        //  - "Reconnect WhatsApp…" if the daemon reports logged_out
        // When WhatsApp is healthy (paired + Baileys connected/connecting/
        // reconnecting) the button is clutter, so hide it. A manual
        // re-pair path can move into an overflow menu later.
        if shouldShowPairingButton {
          Button {
            openWindow(id: WindowID.whatsappPairing)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: Platform.whatsapp.sfSymbol)
              Text(isWhatsAppPaired ? "Reconnect WhatsApp…" : "Connect WhatsApp…")
            }
          }
          .dsButton(.secondary, size: .small)
        }
      }
    }
  }

  /// True when the pairing action is meaningful — either first-time
  /// pair (no session) or recovery from a remote unlink (daemon reports
  /// logged_out). Healthy paired sessions hide the button.
  private var shouldShowPairingButton: Bool {
    if !isWhatsAppPaired { return true }
    if whatsappDaemon.baileysState == "logged_out" { return true }
    return false
  }

  /// Single-line status row — replaces the previous "Daemon running
  /// (pid 12345)" jargon with user-facing connection state.
  private var connectionRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(connectionColor)
        .frame(width: 8, height: 8)
      Text(connectionLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if case .crashLooping = whatsappDaemon.status {
        Button("Restart") { whatsappDaemon.start() }
          .dsButton(.secondary, size: .small)
      }
    }
  }

  private var connectionColor: Color {
    // When the daemon's up AND we've polled its Baileys state, prefer
    // the finer-grained color. Otherwise fall back to coarse process-
    // level signals.
    if case .running = whatsappDaemon.status, let bs = whatsappDaemon.baileysState {
      switch bs {
      case "connected":               return .green
      case "connecting", "reconnecting": return .orange
      case "logged_out":              return .red
      default:                        return .gray
      }
    }
    switch whatsappDaemon.status {
    case .running: return .green
    case .starting, .backingOff: return .orange
    case .crashLooping: return .red
    case .idle, .stopped: return .gray
    }
  }

  private var connectionLabel: String {
    // When we have a live Baileys state, that's the source of truth.
    // The daemon process being up doesn't mean WhatsApp is reachable:
    // it can be reconnecting after a network blip or waiting in
    // logged_out after a remote unlink.
    if case .running = whatsappDaemon.status, let bs = whatsappDaemon.baileysState {
      switch bs {
      case "connecting":    return isWhatsAppPaired ? "Connecting…" : "Waiting to pair…"
      case "connected":     return "Connected"
      case "reconnecting":  return "Reconnecting…"
      case "logged_out":    return "Logged out — Reconnect WhatsApp"
      default:              return bs
      }
    }
    switch whatsappDaemon.status {
    case .idle:               return "Not connected"
    case .starting:           return "Starting…"
    case .running:            return "Connecting…"  // no Baileys state yet — first poll hasn't landed
    case .backingOff(let s, _): return "Reconnecting in \(Int(s))s"
    case .crashLooping:       return "Couldn't connect"
    case .stopped:            return "Turned off"
    }
  }

  /// Heuristic: pairing has happened if the Baileys session file exists.
  /// The file is created on first scan and persists across daemon
  /// restarts.
  private var isWhatsAppPaired: Bool {
    FileManager.default.fileExists(atPath:
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whatsapp-mcp")
        .appendingPathComponent("session.db")
        .path
    )
  }

  // MARK: - App-level

  /// Single-line login-item toggle in its own card — visually parallel
  /// to the transport cards but without the on/off header.
  private var loginItemRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      labeledSwitchRow(
        title: "Open at Login",
        subtitle: nil,
        isOn: Binding(
          get: { loginItem.isEnabled },
          set: { loginItem.setEnabled($0) }
        ),
        enabled: true
      )
      if let warning = loginItem.statusDescription {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(12)
    .background(DS.Color.ghostieShellControl(colorScheme).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var appearanceSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Appearance")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("Choose how Ghostie looks.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      DSSegmentedControl(
        OperatorAppearance.allCases,
        selection: $operatorAppearance,
        label: { $0.label },
        icon: { $0.systemImage }
      )
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  // MARK: - Updates (Sparkle)

  /// Auto-update controls. Sparkle checks the appcast on its own schedule; when a
  /// newer build exists it shows its "Update available" window and the user clicks
  /// Install — nothing auto-installs. The toggle controls background checking; the
  /// button forces a check now.
  private var updatesSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Updates")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("Ghostie checks for new versions automatically. When one's ready you'll see what changed and be asked to install. Nothing updates on its own.")
        .font(DS.Font.settingsCaption).foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      labeledSwitchRow(
        title: "Check for updates automatically",
        subtitle: nil,
        isOn: $updater.automaticallyChecksForUpdates,
        enabled: true
      )
      HStack(spacing: 10) {
        Button("Check for Updates") { updater.checkForUpdates() }
          .dsButton(.secondary, size: .small)
          .disabled(!updater.canCheckForUpdates)
        if let last = updater.lastUpdateCheckDate {
          Text("Last checked \(Self.relative(last))")
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
      }
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  private var fullSetupSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "sparkles")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 3) {
          Text("Texting Wrapped mode")
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text("You skipped the full Messages setup. Continue when you want drafts, automations, WhatsApp, and MCP access.")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }

      Button("Continue full setup") {
        openWindow(id: WindowID.onboarding)
      }
      .dsButton(.primary, size: .small)
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  private var notificationsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Notifications")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("New messages can notify you when Ghostie is not focused. Severance filters apply when that tool is enabled and Messages is set to Work or Personal.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      labeledSwitchRow(
        title: "New message notifications",
        subtitle: nil,
        isOn: $settings.newMessageNotificationsEnabled,
        enabled: true
      )
      DSMenuPicker(
        title: "Preview style",
        options: NotificationPreviewStyle.allCases,
        selection: $settings.newMessageNotificationPreviewStyle
      ) { $0.title }
      HStack(spacing: 8) {
        Label(notificationPermissionLabel, systemImage: notificationPermissionIcon)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
        Spacer(minLength: 8)
        Button(notificationPermissionButtonTitle) {
          if messageNotifications.authorizationStatus == .notDetermined {
            messageNotifications.requestAuthorization()
          } else {
            messageNotifications.openSystemNotificationSettings()
          }
        }
        .dsButton(.secondary, size: .small)
      }
    }
    .padding(14)
    .dsCard(colorScheme)
    .onAppear { messageNotifications.refreshAuthorizationStatus() }
  }

  private var mediaPreviewsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Media previews")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("Photos and local videos always preview inline — they stay on your Mac. This setting only affects web links (YouTube, Vimeo). Off keeps Ghostie fully offline for links: a tap opens your browser. On fetches the video's thumbnail and plays it inline in a cookie-free player.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      labeledSwitchRow(
        title: "Rich previews for video links",
        subtitle: "Fetches thumbnails and plays YouTube/Vimeo inline. Off by default.",
        isOn: $settings.embeddedMediaPreviews,
        enabled: true
      )
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  private var notificationPermissionLabel: String {
    switch messageNotifications.authorizationStatus {
    case .authorized, .provisional:
      return "macOS notifications are allowed."
    case .denied:
      return "macOS notifications are off for this app."
    case .notDetermined:
      return "macOS permission has not been requested yet."
    @unknown default:
      return "macOS notification permission is unknown."
    }
  }

  private var notificationPermissionIcon: String {
    switch messageNotifications.authorizationStatus {
    case .authorized, .provisional:
      return "checkmark.circle.fill"
    case .denied:
      return "exclamationmark.triangle.fill"
    case .notDetermined:
      return "bell"
    @unknown default:
      return "questionmark.circle"
    }
  }

  private var notificationPermissionButtonTitle: String {
    messageNotifications.authorizationStatus == .notDetermined ? "Allow" : "Open Settings"
  }

  private var telemetrySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Product analytics")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("Shown during onboarding and adjustable any time. When enabled, Ghostie sends only allowlisted product events and coarse metadata to Sunrise Labs through PostHog. Message bodies, drafts, prompts, recipients, contact names, IDs, API keys, autocapture, and session replay are never sent.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      labeledSwitchRow(
        title: "Share privacy-safe product analytics",
        subtitle: nil,
        isOn: $settings.productAnalyticsEnabled,
        enabled: true
      )
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  // MARK: - Developer

  /// One row per MFAFeatureFlag (resolved value + winning source + a 3-state
  /// override), the remote-refresh control, and the build stamp. Visible only
  /// in developer mode; the override Picker writes through FeatureFlagStore so
  /// overrides persist and beat remote everywhere instantly.
  private var developerSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Feature flags")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      ForEach(MFAFeatureFlag.allCases, id: \.rawValue) { flag in
        featureFlagRow(flag)
      }
      Rectangle()
        .fill(DS.Color.line(colorScheme))
        .frame(height: 1)
      HStack(spacing: 10) {
        Button("Refresh remote flags") {
          Task { await featureFlags.refresh() }
        }
        .dsButton(.secondary, size: .small)
        .disabled(featureFlags.fetchState == .fetching)
        Text(featureFlags.lastFetchDescription)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .lineLimit(2)
        Spacer()
      }
      Text("Ghostie \(Self.appVersion) · \(Self.buildStamp)")
        .font(DS.Font.monoValue)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .textSelection(.enabled)
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  private func featureFlagRow(_ flag: MFAFeatureFlag) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(flag.displayName)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text("\(featureFlags.resolved(flag) ? "on" : "off") · \(featureFlags.source(flag).rawValue)")
            .font(DS.Font.monoValue)
            .foregroundStyle(featureFlags.resolved(flag) ? DS.Color.green(colorScheme) : DS.Color.ink3(colorScheme))
        }
        Text(flag.blurb)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Picker(flag.displayName, selection: overrideBinding(flag)) {
        Text("Default").tag(FlagOverrideChoice.useDefault)
        Text("On").tag(FlagOverrideChoice.on)
        Text("Off").tag(FlagOverrideChoice.off)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 170)
      .accessibilityLabel("\(flag.displayName) override")
    }
  }

  private enum FlagOverrideChoice: Hashable {
    case useDefault
    case on
    case off
  }

  private func overrideBinding(_ flag: MFAFeatureFlag) -> Binding<FlagOverrideChoice> {
    Binding(
      get: {
        switch featureFlags.override(for: flag) {
        case .none: return .useDefault
        case true?: return .on
        case false?: return .off
        }
      },
      set: { choice in
        featureFlags.setOverride(flag, to: choice == .useDefault ? nil : (choice == .on))
      }
    )
  }

  // MARK: - Status

  /// On-demand diagnostics surface — same HealthChecks primitives the
  /// SetupWalkthroughView uses, plus the latest witness timestamp per
  /// transport so the user can answer "is Claude actually using this?"
  /// at a glance. "Re-run setup walkthrough" is the recovery affordance
  /// when something has broken (e.g. Claude Desktop was re-installed
  /// without the MCP config).
  private var statusSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Status")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Spacer()
      }

      statusValueRow(
        label: "iMessage",
        value: imessageDaemonLabel.replacingOccurrences(of: "Reader service: ", with: ""),
        passing: daemonPassing(imessageDaemon.status)
      )
      statusValueRow(
        label: "WhatsApp",
        value: settings.whatsappEnabled ? connectionLabel : "off",
        passing: settings.whatsappEnabled ? daemonPassing(whatsappDaemon.status) : nil
      )

      DisclosureGroup(isExpanded: $showAdvancedStatus) {
        advancedStatusDetails
          .padding(.top, 8)
      } label: {
        Text("Advanced diagnostics")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
      }
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  private var advancedStatusDetails: some View {
    VStack(alignment: .leading, spacing: 10) {
      let imessageBinPath = HealthChecks.defaultBundleBinaryPrefix + "imessage-drafts-mcp"
      let imessageDaemonBinPath = HealthChecks.defaultBundleBinaryPrefix + "imessage-drafts-daemon"
      let whatsappBinPath = HealthChecks.defaultBundleBinaryPrefix + "whatsapp-drafts-mcp"
      let daemonBinPath = HealthChecks.defaultBundleBinaryPrefix + "whatsapp-drafts-daemon"
      let configState = checks.claudeDesktopConfigState()
      let chatDbState = checks.chatDbAccessState()

      Rectangle()
        .fill(DS.Color.line(colorScheme))
        .frame(height: 1)

      statusValueRow(label: "Full Disk Access", value: fdaLabel(chatDbState), passing: fdaPassing(chatDbState))
      statusRow(
        label: "iMessage MCP binary",
        passing: checks.binaryExists(at: imessageBinPath)
          && checks.codesignIdentifier(of: imessageBinPath) == HealthChecks.expectedSigningIdentifier
      )
      statusRow(
        label: "iMessage daemon binary",
        passing: checks.binaryExists(at: imessageDaemonBinPath)
          && checks.codesignIdentifier(of: imessageDaemonBinPath) == HealthChecks.expectedSigningIdentifier
      )
      if settings.whatsappEnabled {
        statusRow(
          label: "WhatsApp MCP binary",
          passing: checks.binaryExists(at: whatsappBinPath)
            && checks.codesignIdentifier(of: whatsappBinPath) == HealthChecks.expectedSigningIdentifier
        )
        statusRow(
          label: "WhatsApp daemon binary",
          passing: checks.binaryExists(at: daemonBinPath)
            && checks.codesignIdentifier(of: daemonBinPath) == HealthChecks.expectedSigningIdentifier
        )
      }

      switch configState {
      case .found:
        statusRow(label: "Claude Desktop config references this app", passing: true)
      case .notFound:
        statusRow(label: "Claude Desktop config doesn't reference this app", passing: false)
      case .fileAbsent:
        statusRow(label: "Claude Desktop not detected", passing: nil)
      case .parseError:
        statusRow(label: "Claude Desktop config can't be parsed", passing: false)
      }

      lastInvocationRow(label: "Last iMessage call from Claude", record: invocations.imessage)
      if settings.imessageEnabled {
        clientFdaRow(record: invocations.imessage)
      }
      if settings.whatsappEnabled {
        lastInvocationRow(label: "Last WhatsApp call from Claude", record: invocations.whatsapp)
      }

      HStack(spacing: 10) {
        Button("Re-run setup walkthrough") {
          openWindow(id: WindowID.setupWalkthrough)
        }
        .dsButton(.secondary, size: .small)
        Button("Re-check") {
          statusRefreshTick += 1
          invocations.refresh()
        }
        .dsButton(.secondary, size: .small)
        Button("Reveal logs") {
          let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".messages-mcp/logs")
          NSWorkspace.shared.open(url)
        }
        .dsButton(.secondary, size: .small)
        Spacer()
      }
      .padding(.top, 4)
    }
  }

  private var diagnosticsSupportSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Support diagnostics")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Spacer()
      }
      Text("Stored locally. Local app events and crash reports exclude message bodies, prompts, drafts, and API keys. Daemon logs may include transport identifiers from the local bridges; leave them off unless support asks for them.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)

      labeledSwitchRow(
        title: "Include local app events",
        subtitle: "Metadata-only events such as launches, status checks, and export actions.",
        isOn: $settings.diagnosticsIncludeLocalEvents,
        enabled: true
      )
      labeledSwitchRow(
        title: "Include daemon logs",
        subtitle: "Reader-service logs from the local bridges. May include recipient or transport identifiers.",
        isOn: $settings.diagnosticsIncludeDaemonLogs,
        enabled: true
      )
      labeledSwitchRow(
        title: "Include crash reports",
        subtitle: "Relevant macOS crash reports for Ghostie.",
        isOn: $settings.diagnosticsIncludeCrashReports,
        enabled: true
      )

      statusValueRow(
        label: "Local app events",
        value: "\(diagnosticsSummary.eventCount)",
        passing: diagnosticsSummary.eventCount > 0 ? true : nil
      )
      statusValueRow(
        label: "Latest crash report",
        value: latestCrashReportLabel,
        passing: diagnosticsSummary.latestCrashReport == nil ? nil : true
      )

      HStack(spacing: 10) {
        Button {
          exportDiagnostics()
        } label: {
          Label(diagnosticsExporting ? "Exporting..." : "Export Diagnostics", systemImage: "square.and.arrow.up")
        }
        .dsButton(.primary, size: .small)
        .disabled(diagnosticsExporting)

        Button("Reveal logs") {
          NSWorkspace.shared.open(diagnosticsSummary.logsDirectoryURL)
        }
        .dsButton(.secondary, size: .small)

        if let diagnosticsExportURL {
          Button("Reveal export") {
            NSWorkspace.shared.activateFileViewerSelecting([diagnosticsExportURL])
          }
          .dsButton(.secondary, size: .small)
        }

        Spacer()
      }

      if let diagnosticsExportMessage {
        Text(diagnosticsExportMessage)
          .font(.caption2)
          .foregroundStyle(diagnosticsExportMessage.hasPrefix("Exported") ? Color.green : Color.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .dsCard(colorScheme)
  }

  private var latestCrashReportLabel: String {
    guard let report = diagnosticsSummary.latestCrashReport else {
      return "none found"
    }
    return "\(Self.relative(report.date))"
  }

  private func exportDiagnostics() {
    diagnosticsExporting = true
    diagnosticsExportMessage = nil
    diagnosticsExportURL = nil
    DiagnosticsStore.shared.log("diagnostics.export_started")
    let includeLocalEvents = settings.diagnosticsIncludeLocalEvents
    let includeDaemonLogs = settings.diagnosticsIncludeDaemonLogs
    let includeCrashReports = settings.diagnosticsIncludeCrashReports
    Task.detached(priority: .userInitiated) {
      do {
        let url = try DiagnosticsStore.shared.exportBundle(
          includeLocalEvents: includeLocalEvents,
          includeDaemonLogs: includeDaemonLogs,
          includeCrashReports: includeCrashReports
        )
        await MainActor.run {
          diagnosticsSummary = DiagnosticsStore.shared.summary()
          diagnosticsExportURL = url
          diagnosticsExportMessage = "Exported \(url.lastPathComponent)"
          diagnosticsExporting = false
          DiagnosticsStore.shared.log("diagnostics.export_completed")
          AnalyticsClient.shared.safeCapture(.diagnosticsExportCreated, properties: [
            .includedCrashReports: .bool(includeCrashReports),
            .includedLocalEvents: .bool(includeLocalEvents),
            .includedDaemonLogs: .bool(includeDaemonLogs)
          ])
        }
      } catch {
        await MainActor.run {
          diagnosticsSummary = DiagnosticsStore.shared.summary()
          diagnosticsExportMessage = "Export failed: \(error.localizedDescription)"
          diagnosticsExporting = false
          DiagnosticsStore.shared.log("diagnostics.export_failed", metadata: [
            "error_type": String(describing: type(of: error))
          ])
        }
      }
    }
  }

  private func statusValueRow(label: String, value: String, passing: Bool?) -> some View {
    HStack(spacing: 8) {
      let (symbol, color): (String, Color) = {
        switch passing {
        case true?: return ("checkmark.circle.fill", DS.Color.green(colorScheme))
        case false?: return ("xmark.circle.fill", DS.Color.red)
        case nil: return ("circle.dotted", DS.Color.ink3(colorScheme))
        }
      }()
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
      Text(label).font(DS.Font.settingsCaption).foregroundStyle(DS.Color.ink(colorScheme))
      Spacer()
      Text(value)
        .font(DS.Font.monoValue)
        .foregroundStyle(passing == true ? DS.Color.green(colorScheme) : DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label): \(value)")
  }

  private func statusRow(label: String, passing: Bool?) -> some View {
    HStack(spacing: 8) {
      let (symbol, color): (String, Color) = {
        switch passing {
        case true?: return ("checkmark.circle.fill", DS.Color.green(colorScheme))
        case false?: return ("xmark.circle.fill", DS.Color.red)
        case nil: return ("circle.dotted", DS.Color.ink3(colorScheme))
        }
      }()
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
      Text(label).font(DS.Font.settingsCaption).foregroundStyle(DS.Color.ink(colorScheme))
      Spacer()
    }
    // Combine icon + label so VoiceOver announces the row as a single
    // sentence instead of reading the SF Symbol name separately.
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label), \(Self.statusWord(for: passing))")
  }

  private func lastInvocationRow(label: String, record: WitnessRecord?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: record == nil ? "circle.dotted" : "clock")
        .foregroundStyle(record == nil ? DS.Color.ink3(colorScheme) : DS.Color.green(colorScheme))
        .accessibilityHidden(true)
      Text(label).font(DS.Font.settingsCaption).foregroundStyle(DS.Color.ink(colorScheme))
      Spacer()
      Text(record.map { Self.relative($0.ts) } ?? "no record yet")
        .font(DS.Font.monoValue)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label): \(record.map { Self.relative($0.ts) } ?? "no record yet")")
  }

  /// Surfaces the Claude-launched iMessage MCP's own chat.db access, read from
  /// the witness record it writes (issue #17). nil record / nil access → we
  /// haven't heard from a witness that reports it yet.
  private func clientFdaRow(record: WitnessRecord?) -> some View {
    let access = record?.chatDbAccess
    let (passing, value): (Bool?, String) = {
      switch access {
      case .ok: return (true, "granted")
      case .permissionDenied: return (false, "denied, enable ‘Ghostie’ in Full Disk Access (the row may still say ‘Messages for AI’)")
      case .notFound: return (nil, "no Messages DB")
      case .unknown: return (nil, "unknown")
      case .none: return (nil, "no record yet")
      }
    }()
    let symbol = passing == true ? "checkmark.circle.fill"
      : (passing == false ? "xmark.circle.fill" : "circle.dotted")
    let color: Color = passing == true ? DS.Color.green(colorScheme) : (passing == false ? DS.Color.red : DS.Color.ink3(colorScheme))
    return HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
      Text("iMessage reader Full Disk Access").font(DS.Font.settingsCaption).foregroundStyle(DS.Color.ink(colorScheme))
      Spacer()
      Text(value)
        .font(DS.Font.monoValue)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("iMessage reader Full Disk Access: \(value)")
  }

  private func fdaLabel(_ state: ChatDbAccessState) -> String {
    switch state {
    case .ok: return "granted"
    case .permissionDenied: return "not granted"
    case .notFound: return "no Messages DB"
    case .unknown: return "unknown"
    }
  }

  private func fdaPassing(_ state: ChatDbAccessState) -> Bool? {
    switch state {
    case .ok: return true
    case .permissionDenied: return false
    case .notFound, .unknown: return nil
    }
  }

  private func daemonPassing(_ status: IMessageDaemonController.Status) -> Bool? {
    switch status {
    case .running: return true
    case .crashLooping, .stopped: return false
    case .idle, .starting, .backingOff: return nil
    }
  }

  private func daemonPassing(_ status: WhatsAppDaemonController.Status) -> Bool? {
    switch status {
    case .running: return true
    case .crashLooping, .stopped: return false
    case .idle, .starting, .backingOff: return nil
    }
  }

  /// Status word used inside combined accessibility labels.
  private static func statusWord(for value: Bool?) -> String {
    switch value {
    case true?: return "passed"
    case false?: return "failed"
    case nil: return "not yet checked"
    }
  }

  private static func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
  }

  // MARK: - Section scaffold

  @ViewBuilder
  private func settingsGroup<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text(title.uppercased())
          .font(DS.Font.groupLabel)
          .tracking(2.2)
          .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
        Rectangle()
          .fill(DS.Color.ghostieShellLine(colorScheme))
          .frame(height: 1)
      }
      content()
    }
  }

  // MARK: - Card scaffold

  @ViewBuilder
  private func transportCard<Content: View>(
    platform: Platform,
    title: String,
    enabledBinding: Binding<Bool>,
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: platform.sfSymbol)
          .foregroundStyle(platform == .imessage ? DS.Color.blue : DS.Color.green(colorScheme))
        Text(title)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Spacer()
        DSSwitch(label: title, isOn: enabledBinding, enabled: true)
      }
      if enabledBinding.wrappedValue {
        content()
      }
    }
    .opacity(enabledBinding.wrappedValue ? 1.0 : 0.6)
    .padding(14)
    .dsCard(colorScheme)
  }

  // MARK: - Row scaffolds

  /// Label (+ optional subtitle) on the left, a DSSwitch on the
  /// right. Switches across rows line up because DSSwitch has
  /// a fixed footprint and the HStack uses Spacer().
  private func labeledSwitchRow(
    title: String,
    subtitle: String?,
    isOn: Binding<Bool>,
    enabled: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        if let subtitle = subtitle {
          Text(subtitle)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
      DSSwitch(label: title, isOn: isOn, enabled: enabled)
    }
  }

  // MARK: - Version footer

  // Bottom-of-page build stamp so a dev install (or a release) can be
  // identified at a glance. Values come from the bundle Info.plist:
  // CFBundleShortVersionString + CFBundleVersion are written by the
  // install scripts. Dev builds also include MFABuildSHA (git short SHA,
  // "-dirty" if the tree had uncommitted changes) and MFABuildTime. Falls
  // back gracefully when run outside a packaged .app (e.g. `swift run` /
  // tests), where the keys are absent.
  private var versionFooter: some View {
    VStack(spacing: 2) {
      Divider().padding(.bottom, 2)
      Text("Ghostie \(Self.appVersion)")
        .font(DS.Font.sidebarFoot)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Text(Self.buildStamp)
        .font(DS.Font.sidebarFoot)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .textSelection(.enabled)
      Text("© 2026 Sunrise Labs. All rights reserved.")
        .font(DS.Font.sidebarFoot)
        .foregroundStyle(DS.Color.ink4(colorScheme))
        .padding(.top, 1)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 2)
  }

  static var appVersion: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
  }

  static var buildStamp: String {
    let sha =
      (Bundle.main.object(forInfoDictionaryKey: "MFABuildSHA") as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
      ?? "—"
    if let t = Bundle.main.object(forInfoDictionaryKey: "MFABuildTime") as? String, !t.isEmpty {
      return "build \(sha) · \(t)"
    }
    return "build \(sha)"
  }

  private func infoRow(label: String, value: String) -> some View {
    HStack {
      Text(label)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Spacer()
      Text(value)
        .font(DS.Font.monoValue)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .textSelection(.enabled)
    }
  }

}

extension IMessageDaemonController.Status {
  var needsUserAttention: Bool {
    switch self {
    case .crashLooping, .stopped:
      return true
    case .idle, .starting, .running, .backingOff:
      return false
    }
  }
}

extension WhatsAppDaemonController {
  var needsUserAttention: Bool {
    if baileysState == "logged_out" { return true }
    switch status {
    case .crashLooping, .stopped:
      return true
    case .idle, .starting, .running, .backingOff:
      return false
    }
  }
}
