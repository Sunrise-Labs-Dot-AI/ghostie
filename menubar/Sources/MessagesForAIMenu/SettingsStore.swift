import Foundation
import Combine

enum AppExperienceMode: String, CaseIterable {
  case textingWrappedOnly = "texting_wrapped_only"
  case full = "full"

  var isFullExperience: Bool {
    self == .full
  }
}

// Reads + writes ~/.messages-mcp/settings.json. The iMessage MCP server
// reads the same file on every send_draft call (no caching), so toggling
// here takes effect immediately for the next send attempt.
//
// v0.3.0 introduced schema v2: nested transports.{imessage,whatsapp} +
// first_run_complete sentinel. The legacy flat `require_approval` key is
// mirrored at the root so v0.2.x MCP server processes still in flight
// (Claude Desktop hasn't been restarted yet) keep seeing the right value.
@MainActor
final class SettingsStore: ObservableObject {
  @Published var requireApproval: Bool {
    didSet { persist() }
  }
  @Published var firstRunComplete: Bool {
    didSet { persist() }
  }
  @Published var appExperienceMode: AppExperienceMode {
    didSet { persist() }
  }
  /// Granular layer under `appExperienceMode`: which tools the user chose in
  /// onboarding (or later in Settings → Tools). The sidebar hides labs whose
  /// ID isn't in this set. Backward compatible: a settings file that predates
  /// the key loads as "everything enabled", so existing users see no change.
  @Published var enabledToolIDs: Set<String> {
    didSet { persist() }
  }
  @Published var acknowledgedLabIntroIDs: Set<String> {
    didSet { persist() }
  }
  /// The `Legal.termsVersion` the user accepted, or "" if they never have.
  /// Acceptance must precede any permission grant / data access — see
  /// `termsAccepted` + `shouldPresentOnboarding`. Recorded by
  /// `applyOnboardingChoices` when "Get Started" is tapped.
  @Published var termsAcceptedVersion: String {
    didSet { persist() }
  }
  /// Epoch seconds at which the user accepted the current Terms (0 if never).
  @Published var termsAcceptedAt: Double {
    didSet { persist() }
  }
  /// Legacy one-time WhatsApp risk acknowledgment. Preserved for settings-file
  /// compatibility; pairing no longer gates on this value.
  @Published var whatsappRiskAcknowledged: Bool {
    didSet { persist() }
  }
  @Published var imessageEnabled: Bool {
    didSet { persist() }
  }
  @Published var whatsappEnabled: Bool {
    didSet { persist() }
  }
  /// WhatsApp's own require_approval. Persisted to ~/.messages-mcp/
  /// settings.json under transports.whatsapp.require_approval AND
  /// mirrored into ~/.whatsapp-mcp/settings.json so the WhatsApp MCP +
  /// daemon (which read from THAT file on every send) see the toggle
  /// immediately. We only touch the one field on the daemon's file,
  /// preserving rate limits / TTLs / other knobs that live there.
  @Published var whatsappRequireApproval: Bool {
    didSet {
      persist()
      mirrorIntoWhatsAppMcpSettings()
    }
  }
  /// True once the user has confirmed Claude can see this app's MCPs via
  /// the setup walkthrough. Existing v0.3.0/v0.3.1 users see the
  /// walkthrough once after upgrade (the discoverability bug PR #14 fixed
  /// made the upgrade-time confirmation valuable); absence in the on-disk
  /// file defaults to false. Set by SetupWalkthroughView's "All set"
  /// button.
  @Published var walkthroughComplete: Bool {
    didSet { persist() }
  }
  /// True once the user has explicitly skipped the walkthrough. Suppresses
  /// the auto-open on launch but Settings → Status still surfaces unverified
  /// state. Set by SetupWalkthroughView's "Skip for now" button.
  @Published var walkthroughSkipped: Bool {
    didSet { persist() }
  }

  // ── Schedule-send (birthday approve-now/send-later) ─────────────────────────
  /// Default fire time for a scheduled birthday text, as local minutes from
  /// midnight (default 9:00am = 540).
  @Published var birthdayDefaultSendMinute: Int {
    didSet { persist() }
  }
  /// Which Claude Desktop surface "Draft with Claude" opens (Cowork vs a plain
  /// new chat). Used only by the menu-bar deep-link; MCP processes ignore it.
  @Published var birthdayClaudeTarget: ClaudeTarget {
    didSet { persist() }
  }
  /// Quiet hours: a scheduled send that comes due inside this window is held +
  /// the user is notified, never silently sent. Local minutes from midnight;
  /// start > end means an overnight window (the default 21:00→08:00).
  @Published var quietHoursEnabled: Bool {
    didSet { persist() }
  }
  @Published var quietStartMinute: Int {
    didSet { persist() }
  }
  @Published var quietEndMinute: Int {
    didSet { persist() }
  }
  /// Product analytics is privacy-gated by AnalyticsClient's allowlisted
  /// capture boundary. Fresh installs start with no capture until the
  /// user completes onboarding, where the toggle is presented on and can
  /// be turned off before analytics is enabled.
  @Published var productAnalyticsEnabled: Bool {
    didSet {
      guard oldValue != productAnalyticsEnabled else {
        persist()
        return
      }
      productAnalyticsPreferenceRecorded = true
      if productAnalyticsEnabled {
        AnalyticsClient.shared.setUserEnabled(true)
        AnalyticsClient.shared.safeCapture(.telemetryEnabled)
      } else {
        AnalyticsClient.shared.setUserEnabled(false)
      }
      persist()
    }
  }
  /// False only for a fresh/migrated settings file that has not yet
  /// recorded a deliberate telemetry choice. This lets onboarding default
  /// the visible toggle on without treating the stored pre-consent false
  /// as an opt-out that must be preserved forever.
  @Published private(set) var productAnalyticsPreferenceRecorded: Bool
  /// Diagnostics exports are local bundles created only when the user clicks
  /// Export. These toggles control what categories are included.
  @Published var diagnosticsIncludeLocalEvents: Bool {
    didSet { persist() }
  }
  @Published var diagnosticsIncludeDaemonLogs: Bool {
    didSet { persist() }
  }
  @Published var diagnosticsIncludeCrashReports: Bool {
    didSet { persist() }
  }
  @Published var newMessageNotificationsEnabled: Bool {
    didSet { persist() }
  }
  @Published var newMessageNotificationPreviewStyle: NotificationPreviewStyle {
    didSet { persist() }
  }
  /// Opt-in: render rich, network-touching media previews in the transcript
  /// (YouTube/Vimeo thumbnails + inline embedded playback). Off by default so
  /// the app makes no outbound requests for link cards; off → cards stay
  /// offline and tapping opens the system browser. See VideoLinkCardView.
  @Published var embeddedMediaPreviews: Bool {
    didSet { persist() }
  }

  /// Convenience: the quiet-hours config as the value type the scheduler uses.
  var quietHours: QuietHours {
    QuietHours(enabled: quietHoursEnabled, startMinute: quietStartMinute, endMinute: quietEndMinute)
  }

  /// True once the user has accepted the CURRENT Terms/Privacy version.
  /// Flips back to false on a `Legal.termsVersion` bump (stored version no
  /// longer matches), which re-presents the acceptance gate.
  var termsAccepted: Bool {
    termsAcceptedVersion == Legal.termsVersion
  }

  /// Fail-safe onboarding gate: present onboarding on a true first run OR
  /// whenever the current Terms haven't been accepted (fresh install or a
  /// version bump). Keeping the acceptance gate in onboarding means terms
  /// acceptance always precedes any permission grant / data access.
  var shouldPresentOnboarding: Bool {
    Self.shouldPresentOnboarding(firstRunComplete: firstRunComplete, termsAccepted: termsAccepted)
  }

  var isTextingWrappedOnly: Bool {
    appExperienceMode == .textingWrappedOnly
  }

  var shouldRunFullExperienceServices: Bool {
    Self.shouldRunFullExperienceServices(
      experienceMode: appExperienceMode,
      firstRunComplete: firstRunComplete,
      termsAccepted: termsAccepted
    )
  }

  /// Pure helper for `shouldPresentOnboarding`, exposed for tests.
  static func shouldPresentOnboarding(firstRunComplete: Bool, termsAccepted: Bool) -> Bool {
    !firstRunComplete || !termsAccepted
  }

  static func shouldRunFullExperienceServices(
    experienceMode: AppExperienceMode,
    firstRunComplete: Bool,
    termsAccepted: Bool
  ) -> Bool {
    experienceMode.isFullExperience && firstRunComplete && termsAccepted
  }

  @Published private(set) var lastError: String?

  private let file: URL
  private let whatsappMcpFile: URL

  init(homeOverride: URL? = nil) {
    // homeOverride is the test seam — points at a tmpdir that mimics the
    // real $HOME structure (./.messages-mcp/, ./.whatsapp-mcp/). Production
    // callers omit it and get the real home directory.
    let home = homeOverride ?? AppStoragePaths.homeDirectory
    let dir = home.appendingPathComponent(".messages-mcp")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.file = dir.appendingPathComponent("settings.json")
    self.whatsappMcpFile = home
      .appendingPathComponent(".whatsapp-mcp")
      .appendingPathComponent("settings.json")

    let loaded = Self.load(from: file, whatsappMcp: whatsappMcpFile)
    self.requireApproval = loaded.requireApproval
    self.firstRunComplete = loaded.firstRunComplete
    self.appExperienceMode = loaded.appExperienceMode
    self.enabledToolIDs = loaded.enabledToolIDs
    self.acknowledgedLabIntroIDs = loaded.acknowledgedLabIntroIDs
    self.termsAcceptedVersion = loaded.termsAcceptedVersion
    self.termsAcceptedAt = loaded.termsAcceptedAt
    self.whatsappRiskAcknowledged = loaded.whatsappRiskAcknowledged
    self.imessageEnabled = loaded.imessageEnabled
    self.whatsappEnabled = loaded.whatsappEnabled
    self.whatsappRequireApproval = loaded.whatsappRequireApproval
    self.walkthroughComplete = loaded.walkthroughComplete
    self.walkthroughSkipped = loaded.walkthroughSkipped
    self.birthdayDefaultSendMinute = loaded.birthdayDefaultSendMinute
    self.birthdayClaudeTarget = loaded.birthdayClaudeTarget
    self.quietHoursEnabled = loaded.quietHoursEnabled
    self.quietStartMinute = loaded.quietStartMinute
    self.quietEndMinute = loaded.quietEndMinute
    self.productAnalyticsEnabled = loaded.productAnalyticsEnabled
    self.productAnalyticsPreferenceRecorded = loaded.productAnalyticsPreferenceRecorded
    self.diagnosticsIncludeLocalEvents = loaded.diagnosticsIncludeLocalEvents
    self.diagnosticsIncludeDaemonLogs = loaded.diagnosticsIncludeDaemonLogs
    self.diagnosticsIncludeCrashReports = loaded.diagnosticsIncludeCrashReports
    self.newMessageNotificationsEnabled = loaded.newMessageNotificationsEnabled
    self.newMessageNotificationPreviewStyle = loaded.newMessageNotificationPreviewStyle
    self.embeddedMediaPreviews = loaded.embeddedMediaPreviews

    if loaded.requiresMigrationWrite {
      // First run, or v1→v2 migration: write the canonical v2 schema
      // back to disk so the MCP server has a file to read and so we
      // don't repeat the migration on every launch.
      persistInit()
    }
  }

  // MARK: - Load + migrate

  fileprivate struct LoadedState {
    let requireApproval: Bool
    let firstRunComplete: Bool
    let appExperienceMode: AppExperienceMode
    let enabledToolIDs: Set<String>
    let acknowledgedLabIntroIDs: Set<String>
    let termsAcceptedVersion: String
    let termsAcceptedAt: Double
    let whatsappRiskAcknowledged: Bool
    let imessageEnabled: Bool
    let whatsappEnabled: Bool
    let whatsappRequireApproval: Bool
    let walkthroughComplete: Bool
    let walkthroughSkipped: Bool
    let birthdayDefaultSendMinute: Int
    let birthdayClaudeTarget: ClaudeTarget
    let quietHoursEnabled: Bool
    let quietStartMinute: Int
    let quietEndMinute: Int
    let productAnalyticsEnabled: Bool
    let productAnalyticsPreferenceRecorded: Bool
    let diagnosticsIncludeLocalEvents: Bool
    let diagnosticsIncludeDaemonLogs: Bool
    let diagnosticsIncludeCrashReports: Bool
    let newMessageNotificationsEnabled: Bool
    let newMessageNotificationPreviewStyle: NotificationPreviewStyle
    let embeddedMediaPreviews: Bool
    /// True when the on-disk file is missing or was v1; tells init() to
    /// write the canonical v2 schema immediately.
    let requiresMigrationWrite: Bool
  }

  // Schedule-send defaults (local minutes from midnight).
  private static let defaultSendMinute = 9 * 60     // 9:00am
  private static let defaultQuietStart = 21 * 60    // 9:00pm
  private static let defaultQuietEnd = 8 * 60       // 8:00am
  // "Draft with Claude" opens a plain new chat by default — the lightest fit for
  // "write me a birthday text." Switchable to a Cowork session in Settings for
  // anyone who prefers that surface.
  private static let defaultClaudeTarget: ClaudeTarget = .chat

  private static func load(from file: URL, whatsappMcp: URL) -> LoadedState {
    // WhatsApp's own settings.json is the source of truth for the
    // daemon's behavior. If our menubar copy and the daemon's disagree,
    // trust the daemon's — it's what the send path actually checks.
    let whatsappMcpApproval = loadWhatsAppMcpApproval(from: whatsappMcp)

    guard FileManager.default.fileExists(atPath: file.path),
          let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      // Fresh install: defaults, will write canonical schema on init.
      // All tools enabled until onboarding records an actual choice.
      return LoadedState(
        requireApproval: true,
        firstRunComplete: false,
        appExperienceMode: .full,
        enabledToolIDs: ToolCatalog.allToolIDs,
        acknowledgedLabIntroIDs: [],
        termsAcceptedVersion: "",
        termsAcceptedAt: 0,
        whatsappRiskAcknowledged: false,
        imessageEnabled: true,
        whatsappEnabled: false,
        whatsappRequireApproval: whatsappMcpApproval ?? true,
        walkthroughComplete: false,
        walkthroughSkipped: false,
        birthdayDefaultSendMinute: defaultSendMinute,
        birthdayClaudeTarget: defaultClaudeTarget,
        quietHoursEnabled: true,
        quietStartMinute: defaultQuietStart,
        quietEndMinute: defaultQuietEnd,
        // MUST stay false: launch-time analytics capture is configured
        // before onboarding, so fresh installs must not capture until the
        // user commits the visible onboarding choice.
        productAnalyticsEnabled: false,
        productAnalyticsPreferenceRecorded: false,
        diagnosticsIncludeLocalEvents: true,
        diagnosticsIncludeDaemonLogs: false,
        diagnosticsIncludeCrashReports: true,
        newMessageNotificationsEnabled: true,
        newMessageNotificationPreviewStyle: .shortPreview,
        embeddedMediaPreviews: false,
        requiresMigrationWrite: true
      )
    }

    let schemaVersion = json["schema_version"] as? Int ?? 1

    if schemaVersion >= 2 {
      // v2 reader. Tolerate missing fields with safe defaults.
      let transports = json["transports"] as? [String: Any] ?? [:]
      let imessage = transports["imessage"] as? [String: Any] ?? [:]
      let whatsapp = transports["whatsapp"] as? [String: Any] ?? [:]
      // Prefer the daemon's view if present; otherwise fall back to
      // the menubar's mirror; otherwise default-on.
      let whatsappApproval = whatsappMcpApproval
        ?? (whatsapp["require_approval"] as? Bool)
        ?? true
      let legal = json["legal"] as? [String: Any] ?? [:]
      let experience = json["experience"] as? [String: Any] ?? [:]
      let labs = json["labs"] as? [String: Any] ?? [:]
      // Granular tools (additive). Key absence — any settings file written
      // before the tool picker existed — means everything stays enabled, so
      // upgrading users lose nothing.
      let enabledTools: Set<String>
      if let rawTools = experience["enabled_tools"] as? [String] {
        enabledTools = Set(rawTools)
      } else {
        enabledTools = ToolCatalog.allToolIDs
      }
      return LoadedState(
        requireApproval: imessage["require_approval"] as? Bool ?? true,
        firstRunComplete: json["first_run_complete"] as? Bool ?? false,
        appExperienceMode: AppExperienceMode(rawValue: experience["mode"] as? String ?? "") ?? .full,
        enabledToolIDs: enabledTools,
        acknowledgedLabIntroIDs: Set(labs["acknowledged_intro_ids"] as? [String] ?? []),
        // Additive (absence → not-accepted/false), so older v2 files that
        // predate the Terms gate re-present onboarding until accepted.
        termsAcceptedVersion: legal["terms_accepted_version"] as? String ?? "",
        termsAcceptedAt: legal["terms_accepted_at"] as? Double ?? 0,
        whatsappRiskAcknowledged: legal["whatsapp_risk_acknowledged"] as? Bool ?? false,
        imessageEnabled: imessage["enabled"] as? Bool ?? true,
        whatsappEnabled: whatsapp["enabled"] as? Bool ?? false,
        whatsappRequireApproval: whatsappApproval,
        // Absence == false. Existing v0.3.0/v0.3.1 users get the
        // walkthrough on upgrade — exactly the cohort hit by the
        // discoverability bug PR #14 fixed. Per the resolved Open
        // Question #1 in the v0.3.2 plan.
        walkthroughComplete: json["walkthrough_complete"] as? Bool ?? false,
        walkthroughSkipped: json["walkthrough_skipped"] as? Bool ?? false,
        birthdayDefaultSendMinute: (json["birthday"] as? [String: Any])?["default_send_minute"] as? Int ?? defaultSendMinute,
        birthdayClaudeTarget: ClaudeTarget(rawValue: (json["birthday"] as? [String: Any])?["claude_target"] as? String ?? "") ?? defaultClaudeTarget,
        quietHoursEnabled: (json["quiet_hours"] as? [String: Any])?["enabled"] as? Bool ?? true,
        quietStartMinute: (json["quiet_hours"] as? [String: Any])?["start_minute"] as? Int ?? defaultQuietStart,
        quietEndMinute: (json["quiet_hours"] as? [String: Any])?["end_minute"] as? Int ?? defaultQuietEnd,
        productAnalyticsEnabled: (json["telemetry"] as? [String: Any])?["product_analytics_enabled"] as? Bool ?? false,
        productAnalyticsPreferenceRecorded: (json["telemetry"] as? [String: Any])?["product_analytics_preference_recorded"] as? Bool ?? false,
        diagnosticsIncludeLocalEvents: (json["diagnostics"] as? [String: Any])?["include_local_events"] as? Bool ?? true,
        diagnosticsIncludeDaemonLogs: (json["diagnostics"] as? [String: Any])?["include_daemon_logs"] as? Bool ?? false,
        diagnosticsIncludeCrashReports: (json["diagnostics"] as? [String: Any])?["include_crash_reports"] as? Bool ?? true,
        newMessageNotificationsEnabled: (json["notifications"] as? [String: Any])?["new_messages_enabled"] as? Bool ?? true,
        newMessageNotificationPreviewStyle: NotificationPreviewStyle(
          rawValue: (json["notifications"] as? [String: Any])?["preview_style"] as? String ?? ""
        ) ?? .shortPreview,
        embeddedMediaPreviews: (json["media"] as? [String: Any])?["embedded_previews"] as? Bool ?? false,
        requiresMigrationWrite: false
      )
    }

    // v1 → v2 migration. The user has been running v0.1.x or v0.2.x,
    // so first_run_complete should be true (they've already used the
    // app). iMessage is enabled by definition (it was the only transport).
    // WhatsApp defaults to off — the user opts in via the Settings UI.
    return LoadedState(
      requireApproval: json["require_approval"] as? Bool ?? true,
      firstRunComplete: true,
      appExperienceMode: .full,
      enabledToolIDs: ToolCatalog.allToolIDs,
      acknowledgedLabIntroIDs: [],
      // Pre-Terms-gate users have never accepted; the gate re-presents
      // onboarding on next launch so they accept the current version.
      termsAcceptedVersion: "",
      termsAcceptedAt: 0,
      whatsappRiskAcknowledged: false,
      imessageEnabled: true,
      whatsappEnabled: false,
      whatsappRequireApproval: whatsappMcpApproval ?? true,
      walkthroughComplete: false,
      walkthroughSkipped: false,
      birthdayDefaultSendMinute: defaultSendMinute,
      birthdayClaudeTarget: defaultClaudeTarget,
      quietHoursEnabled: true,
      quietStartMinute: defaultQuietStart,
      quietEndMinute: defaultQuietEnd,
      productAnalyticsEnabled: false,
      productAnalyticsPreferenceRecorded: false,
      diagnosticsIncludeLocalEvents: true,
      diagnosticsIncludeDaemonLogs: false,
      diagnosticsIncludeCrashReports: true,
      newMessageNotificationsEnabled: true,
      newMessageNotificationPreviewStyle: .shortPreview,
      embeddedMediaPreviews: false,
      requiresMigrationWrite: true
    )
  }

  /// Read just the `require_approval` field from ~/.whatsapp-mcp/
  /// settings.json. Returns nil if the file doesn't exist or the
  /// field is missing — caller decides the default.
  private static func loadWhatsAppMcpApproval(from file: URL) -> Bool? {
    guard FileManager.default.fileExists(atPath: file.path),
          let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["require_approval"] as? Bool
  }

  // MARK: - Write

  private func persistInit() {
    // Same as persist() but doesn't go through didSet (which would fire
    // during init before self is fully constructed).
    write()
  }

  private func persist() {
    write()
  }

  func applyOnboardingChoices(
    experienceMode: AppExperienceMode = .full,
    imessage: Bool,
    whatsapp: Bool,
    productAnalytics: Bool,
    termsAcceptedAt: Double,
    enabledTools: Set<String>? = nil
  ) {
    // Record Terms acceptance alongside the choice writes. The acceptance
    // gate in OnboardingView is what enables the "Get Started" button, so by
    // the time we reach here the user has affirmatively accepted the current
    // version — stamp it so the gate doesn't re-fire next launch.
    appExperienceMode = experienceMode
    if let enabledTools {
      enabledToolIDs = enabledTools
    }
    termsAcceptedVersion = Legal.termsVersion
    self.termsAcceptedAt = termsAcceptedAt
    imessageEnabled = imessage
    whatsappEnabled = whatsapp
    if experienceMode == .textingWrappedOnly {
      walkthroughComplete = false
      walkthroughSkipped = true
    } else {
      walkthroughSkipped = false
    }
    productAnalyticsPreferenceRecorded = true
    productAnalyticsEnabled = productAnalytics
    AnalyticsClient.shared.safeCapture(.onboardingCompleted, properties: [
      .experienceMode: .string(experienceMode.rawValue)
    ])
    if imessage {
      AnalyticsClient.shared.safeCapture(.transportEnabled, properties: [
        .transport: .string(AnalyticsTransportName.imessage.rawValue)
      ])
    }
    if whatsapp {
      AnalyticsClient.shared.safeCapture(.transportEnabled, properties: [
        .transport: .string(AnalyticsTransportName.whatsapp.rawValue)
      ])
    }
    firstRunComplete = true
  }

  // MARK: - Granular tools

  func isToolEnabled(_ id: String) -> Bool {
    enabledToolIDs.contains(id)
  }

  /// Toggle a tool from Settings → Tools. Two couplings, both documented in
  /// `ToolCatalog`: Style follows Messages (it steers drafts written
  /// into the inbox), and enabling Messages with no transport configured
  /// turns iMessage on so the inbox has a source.
  func setToolEnabled(_ id: String, _ enabled: Bool) {
    if enabled {
      enabledToolIDs.insert(id)
      if id == ToolCatalog.messages {
        enabledToolIDs.insert(ToolCatalog.textingVoice)
        if !imessageEnabled && !whatsappEnabled {
          imessageEnabled = true
        }
      }
    } else {
      enabledToolIDs.remove(id)
      if id == ToolCatalog.messages {
        enabledToolIDs.remove(ToolCatalog.textingVoice)
      }
    }
  }

  func hasAcknowledgedLabIntro(_ id: String) -> Bool {
    acknowledgedLabIntroIDs.contains(id)
  }

  func acknowledgeLabIntro(_ id: String) {
    guard !acknowledgedLabIntroIDs.contains(id) else { return }
    acknowledgedLabIntroIDs.insert(id)
  }

  /// Legacy writer kept so older UI/test paths can round-trip the persisted
  /// setting. New pairing flows do not call this.
  func acknowledgeWhatsAppRisk() {
    whatsappRiskAcknowledged = true
  }

  private func write() {
    do {
      let data = try JSONSerialization.data(
        withJSONObject: currentDocument(),
        options: [.prettyPrinted, .sortedKeys]
      )
      try data.write(to: file, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      lastError = nil
    } catch {
      lastError = "couldn't write settings.json: \(error.localizedDescription)"
    }
  }

  private func currentDocument() -> [String: Any] {
    [
      "schema_version": 2,
      "first_run_complete": firstRunComplete,
      // Additive fields for v0.3.2; absence defaults to false on read so
      // upgrading users see the walkthrough once. Not bumping schema_version
      // because the additive shape is back-compat for v0.3.x readers.
      "walkthrough_complete": walkthroughComplete,
      "walkthrough_skipped": walkthroughSkipped,
      "experience": [
        "mode": appExperienceMode.rawValue,
        // Additive; absence on read → all tools enabled (pre-picker files).
        "enabled_tools": enabledToolIDs.sorted()
      ],
      "labs": [
        "acknowledged_intro_ids": acknowledgedLabIntroIDs.sorted()
      ],
      // Schedule-send (additive; absence → defaults on read).
      "birthday": [
        "default_send_minute": birthdayDefaultSendMinute,
        "claude_target": birthdayClaudeTarget.rawValue
      ],
      "quiet_hours": [
        "enabled": quietHoursEnabled,
        "start_minute": quietStartMinute,
        "end_minute": quietEndMinute
      ],
      // Terms/Privacy acceptance + legacy WhatsApp risk ack. Additive;
      // absence on read defaults to not-accepted/false.
      "legal": [
        "terms_accepted_version": termsAcceptedVersion,
        "terms_accepted_at": termsAcceptedAt,
        "whatsapp_risk_acknowledged": whatsappRiskAcknowledged
      ],
      "telemetry": [
        "product_analytics_enabled": productAnalyticsEnabled,
        "product_analytics_preference_recorded": productAnalyticsPreferenceRecorded
      ],
      "diagnostics": [
        "include_local_events": diagnosticsIncludeLocalEvents,
        "include_daemon_logs": diagnosticsIncludeDaemonLogs,
        "include_crash_reports": diagnosticsIncludeCrashReports
      ],
      "notifications": [
        "new_messages_enabled": newMessageNotificationsEnabled,
        "preview_style": newMessageNotificationPreviewStyle.rawValue
      ],
      "media": [
        "embedded_previews": embeddedMediaPreviews
      ],
      // Legacy flat key, mirrored from transports.imessage.require_approval.
      // Lets v0.2.x MCP server processes still running in this Claude
      // Desktop session keep seeing the toggle until next restart.
      "require_approval": requireApproval,
      "transports": [
        "imessage": [
          "enabled": imessageEnabled,
          "require_approval": requireApproval
        ],
        "whatsapp": [
          "enabled": whatsappEnabled,
          "require_approval": whatsappRequireApproval
        ]
      ]
    ]
  }

  /// Update ~/.whatsapp-mcp/settings.json so the WhatsApp MCP + daemon
  /// see the same require_approval value the user just toggled. We
  /// read-then-write (only touching `require_approval`) to preserve
  /// every other field the daemon owns there — daily_cap,
  /// min_staged_age_ms, draft_ttl_days, message_retention_days, the
  /// rate-limit knobs, etc. Clobbering those would reset the user's
  /// rate-limit posture every time they toggle a single switch.
  private func mirrorIntoWhatsAppMcpSettings() {
    let dir = whatsappMcpFile.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var doc: [String: Any]
    if FileManager.default.fileExists(atPath: whatsappMcpFile.path),
       let data = try? Data(contentsOf: whatsappMcpFile),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      doc = existing
    } else {
      // Daemon hasn't run yet (or its file is corrupt). Write a doc
      // with JUST require_approval; the daemon's Zod schema will fill
      // every other field with its default on next read.
      doc = [:]
    }
    doc["require_approval"] = whatsappRequireApproval

    do {
      let data = try JSONSerialization.data(
        withJSONObject: doc,
        options: [.prettyPrinted, .sortedKeys]
      )
      try data.write(to: whatsappMcpFile, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: whatsappMcpFile.path)
    } catch {
      lastError = "couldn't update WhatsApp daemon settings: \(error.localizedDescription)"
    }
  }
}
