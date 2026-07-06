import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Covers SettingsStore's v1→v2 migration, walkthrough field defaults
/// (the v0.3.2 additions), and the daemon-mirror behavior.
///
/// All cases use a tmpdir-backed home so tests never touch the developer's
/// real ~/.messages-mcp/ or ~/.whatsapp-mcp/.
@MainActor
final class SettingsStoreTests: XCTestCase {
    var tmpHome: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("messages-mcp-settings-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tmpHome = base
    }

    override func tearDown() {
        if let tmpHome = tmpHome {
            try? FileManager.default.removeItem(at: tmpHome)
        }
        tmpHome = nil
        super.tearDown()
    }

    // MARK: - Fresh-install defaults

    func test_freshInstall_writesV2Schema() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store.imessageEnabled)
        XCTAssertFalse(store.whatsappEnabled)
        XCTAssertTrue(store.requireApproval)
        XCTAssertFalse(store.firstRunComplete)
        XCTAssertEqual(store.appExperienceMode, .full)
        XCTAssertFalse(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)
        // Schedule-send defaults: 9am send, quiet 9pm→8am.
        XCTAssertEqual(store.birthdayDefaultSendMinute, 9 * 60)
        XCTAssertTrue(store.quietHoursEnabled)
        XCTAssertEqual(store.quietStartMinute, 21 * 60)
        XCTAssertEqual(store.quietEndMinute, 8 * 60)
        // Draft-with-Claude opens a plain new chat by default.
        XCTAssertEqual(store.birthdayClaudeTarget, .chat)
        XCTAssertFalse(store.productAnalyticsEnabled)
        XCTAssertFalse(store.productAnalyticsPreferenceRecorded)
        XCTAssertTrue(store.diagnosticsIncludeLocalEvents)
        XCTAssertFalse(store.diagnosticsIncludeDaemonLogs)
        XCTAssertTrue(store.diagnosticsIncludeCrashReports)
        XCTAssertTrue(store.newMessageNotificationsEnabled)
        XCTAssertEqual(store.newMessageNotificationPreviewStyle, .shortPreview)
        XCTAssertTrue(store.acknowledgedLabIntroIDs.isEmpty)

        // Init wrote the canonical v2 schema back to disk.
        let file = tmpHome.appendingPathComponent(".messages-mcp/settings.json")
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schema_version"] as? Int, 2)
        XCTAssertEqual(json["first_run_complete"] as? Bool, false)
        let experience = json["experience"] as? [String: Any]
        XCTAssertEqual(experience?["mode"] as? String, AppExperienceMode.full.rawValue)
        XCTAssertEqual(json["walkthrough_complete"] as? Bool, false)
        XCTAssertEqual(json["walkthrough_skipped"] as? Bool, false)
        let telemetry = json["telemetry"] as? [String: Any]
        XCTAssertEqual(telemetry?["product_analytics_enabled"] as? Bool, false)
        XCTAssertEqual(telemetry?["product_analytics_preference_recorded"] as? Bool, false)
        let diagnostics = json["diagnostics"] as? [String: Any]
        XCTAssertEqual(diagnostics?["include_local_events"] as? Bool, true)
        XCTAssertEqual(diagnostics?["include_daemon_logs"] as? Bool, false)
        XCTAssertEqual(diagnostics?["include_crash_reports"] as? Bool, true)
        let notifications = json["notifications"] as? [String: Any]
        XCTAssertEqual(notifications?["new_messages_enabled"] as? Bool, true)
        XCTAssertEqual(notifications?["preview_style"] as? String, NotificationPreviewStyle.shortPreview.rawValue)
        let labs = json["labs"] as? [String: Any]
        XCTAssertEqual(labs?["acknowledged_intro_ids"] as? [String], [])
    }

    func test_labIntroAcknowledgementsPersistAndReload() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertFalse(store.hasAcknowledgedLabIntro("messages"))

        store.acknowledgeLabIntro("messages")
        store.acknowledgeLabIntro("wrapped")
        store.acknowledgeLabIntro("messages")

        XCTAssertTrue(store.hasAcknowledgedLabIntro("messages"))
        XCTAssertTrue(store.hasAcknowledgedLabIntro("wrapped"))
        XCTAssertEqual(store.acknowledgedLabIntroIDs.count, 2)

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(reloaded.acknowledgedLabIntroIDs, Set(["messages", "wrapped"]))
    }

    func test_onboardingProductAnalyticsInitialValue_defaultsOffUntilPreferenceRecorded() {
        XCTAssertFalse(OnboardingView.initialProductAnalyticsValue(storedValue: false, preferenceRecorded: false))
        XCTAssertFalse(OnboardingView.initialProductAnalyticsValue(storedValue: false, preferenceRecorded: true))
        XCTAssertTrue(OnboardingView.initialProductAnalyticsValue(storedValue: true, preferenceRecorded: true))
    }

    func test_onboardingInitialChosenTools_freshUsersGetEverythingSelected() {
        // No "recommended" subset any more: a fresh install starts with every
        // choosable tool selected, and the user unchecks what they don't want.
        XCTAssertEqual(
            OnboardingView.initialChosenTools(
                firstRunComplete: false,
                storedMode: .full,
                storedTools: []
            ),
            Set(ToolCatalog.choosableToolIDs)
        )
    }

    func test_onboardingInitialChosenTools_wrappedOnlyContinuationSelectsEverything() {
        // A Wrapped-only user reopening onboarding ("Continue setup") now sees
        // the full set selected, consistent with the default-all model.
        let tools = OnboardingView.initialChosenTools(
            firstRunComplete: true,
            storedMode: .textingWrappedOnly,
            storedTools: [ToolCatalog.wrapped]
        )
        XCTAssertEqual(tools, Set(ToolCatalog.choosableToolIDs))
    }

    func test_onboardingInitialChosenTools_fullUserReacceptingTermsKeepsCurrentChoices() {
        // A full user re-accepting bumped Terms must NOT have their tool set
        // silently rewritten to the Recommended preset.
        let stored: Set<String> = [ToolCatalog.messages, ToolCatalog.eq, ToolCatalog.textingVoice]
        let tools = OnboardingView.initialChosenTools(
            firstRunComplete: true,
            storedMode: .full,
            storedTools: stored
        )
        // textingVoice isn't a picker card; only choosable IDs come back.
        XCTAssertEqual(tools, [ToolCatalog.messages, ToolCatalog.eq])
    }

    func test_onboardingCanCommit_requiresTermsAndAtLeastOneTool() {
        XCTAssertFalse(OnboardingView.canCommit(
            termsAccepted: false,
            chosenTools: [ToolCatalog.messages]
        ))
        XCTAssertFalse(OnboardingView.canCommit(
            termsAccepted: true,
            chosenTools: []
        ))
        XCTAssertTrue(OnboardingView.canCommit(
            termsAccepted: true,
            chosenTools: ToolCatalog.wrappedOnlyToolIDs
        ))
    }

    func test_onboardingLandingSelection_prefersMessagesThenCatalogOrder() {
        XCTAssertEqual(
            OnboardingView.landingSelection(forChosen: [ToolCatalog.messages, ToolCatalog.eq]),
            .messages
        )
        XCTAssertEqual(
            OnboardingView.landingSelection(forChosen: [ToolCatalog.eq, ToolCatalog.birthdays]),
            .tool(ToolCatalog.birthdays)
        )
        XCTAssertEqual(OnboardingView.landingSelection(forChosen: []), .messages)
    }

    func test_onboardingChoices_optInPersistsAnalyticsEnabled() throws {
        let store = SettingsStore(homeOverride: tmpHome)

        store.applyOnboardingChoices(imessage: true, whatsapp: false, productAnalytics: true, termsAcceptedAt: 1_700_000_000)

        XCTAssertTrue(store.firstRunComplete)
        XCTAssertTrue(store.productAnalyticsEnabled)
        XCTAssertTrue(store.productAnalyticsPreferenceRecorded)

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(reloaded.firstRunComplete)
        XCTAssertTrue(reloaded.productAnalyticsEnabled)
        XCTAssertTrue(reloaded.productAnalyticsPreferenceRecorded)
    }

    func test_wrappedOnlyOnboardingDisablesTransportsAndSkipsWalkthrough() throws {
        let store = SettingsStore(homeOverride: tmpHome)

        store.applyOnboardingChoices(
            experienceMode: .textingWrappedOnly,
            imessage: false,
            whatsapp: false,
            productAnalytics: true,
            termsAcceptedAt: 1_700_000_000
        )

        XCTAssertEqual(store.appExperienceMode, .textingWrappedOnly)
        XCTAssertTrue(store.firstRunComplete)
        XCTAssertFalse(store.imessageEnabled)
        XCTAssertFalse(store.whatsappEnabled)
        XCTAssertFalse(store.walkthroughComplete)
        XCTAssertTrue(store.walkthroughSkipped)
        XCTAssertFalse(store.shouldRunFullExperienceServices)

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(reloaded.appExperienceMode, .textingWrappedOnly)
        XCTAssertFalse(reloaded.imessageEnabled)
        XCTAssertFalse(reloaded.whatsappEnabled)
        XCTAssertTrue(reloaded.walkthroughSkipped)
    }

    func test_fullOnboardingClearsWrappedSkipAndCanStartServices() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.applyOnboardingChoices(
            experienceMode: .textingWrappedOnly,
            imessage: false,
            whatsapp: false,
            productAnalytics: true,
            termsAcceptedAt: 1_700_000_000
        )

        store.applyOnboardingChoices(
            experienceMode: .full,
            imessage: true,
            whatsapp: false,
            productAnalytics: true,
            termsAcceptedAt: 1_700_000_100
        )

        XCTAssertEqual(store.appExperienceMode, .full)
        XCTAssertTrue(store.imessageEnabled)
        XCTAssertFalse(store.whatsappEnabled)
        XCTAssertFalse(store.walkthroughSkipped)
        XCTAssertTrue(store.shouldRunFullExperienceServices)
    }

    // MARK: - Granular tools

    func test_freshInstall_enablesAllToolsAndPersistsThem() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(store.enabledToolIDs, ToolCatalog.allToolIDs)

        let file = tmpHome.appendingPathComponent(".messages-mcp/settings.json")
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let experience = json["experience"] as? [String: Any]
        XCTAssertEqual(
            Set(experience?["enabled_tools"] as? [String] ?? []),
            ToolCatalog.allToolIDs
        )
    }

    func test_settingsFileWithoutEnabledTools_loadsEverythingEnabled() throws {
        // Backward compatibility: a v2 file written before the tool picker
        // existed (no experience.enabled_tools key) keeps every tool on.
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "experience": ["mode": "full"],
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": false, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc)
            .write(to: dir.appendingPathComponent("settings.json"))

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(store.enabledToolIDs, ToolCatalog.allToolIDs)
        XCTAssertTrue(store.isToolEnabled(ToolCatalog.eq))
    }

    func test_applyOnboardingChoices_persistsChosenToolsAndReloads() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        let chosen: Set<String> = [ToolCatalog.messages, ToolCatalog.wrapped, ToolCatalog.birthdays]

        store.applyOnboardingChoices(
            experienceMode: .full,
            imessage: true,
            whatsapp: false,
            productAnalytics: false,
            termsAcceptedAt: 1_700_000_000,
            enabledTools: ToolCatalog.persistedTools(forChosen: chosen)
        )

        // Texting Voice rides along with Messages.
        XCTAssertEqual(store.enabledToolIDs, chosen.union([ToolCatalog.textingVoice]))
        XCTAssertFalse(store.isToolEnabled(ToolCatalog.eq))

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(reloaded.enabledToolIDs, chosen.union([ToolCatalog.textingVoice]))
    }

    func test_applyOnboardingChoices_withoutToolsLeavesEnabledSetAlone() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.applyOnboardingChoices(imessage: true, whatsapp: false, productAnalytics: false, termsAcceptedAt: 1_700_000_000)
        XCTAssertEqual(store.enabledToolIDs, ToolCatalog.allToolIDs)
    }

    func test_setToolEnabled_togglesAndCouplesMessagesWithTextingVoice() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.applyOnboardingChoices(
            experienceMode: .full,
            imessage: false,
            whatsapp: false,
            productAnalytics: false,
            termsAcceptedAt: 1_700_000_000,
            enabledTools: [ToolCatalog.wrapped]
        )

        store.setToolEnabled(ToolCatalog.eq, true)
        XCTAssertTrue(store.isToolEnabled(ToolCatalog.eq))

        // Enabling Messages pulls in Texting Voice and turns on a transport
        // (iMessage) when none is configured.
        store.setToolEnabled(ToolCatalog.messages, true)
        XCTAssertTrue(store.isToolEnabled(ToolCatalog.messages))
        XCTAssertTrue(store.isToolEnabled(ToolCatalog.textingVoice))
        XCTAssertTrue(store.imessageEnabled)

        // Disabling Messages removes Texting Voice with it.
        store.setToolEnabled(ToolCatalog.messages, false)
        XCTAssertFalse(store.isToolEnabled(ToolCatalog.messages))
        XCTAssertFalse(store.isToolEnabled(ToolCatalog.textingVoice))

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(reloaded.enabledToolIDs, [ToolCatalog.wrapped, ToolCatalog.eq])
    }

    func test_onboardingChoices_optOutPersistsAnalyticsDisabledAndRecorded() throws {
        let store = SettingsStore(homeOverride: tmpHome)

        store.applyOnboardingChoices(imessage: true, whatsapp: false, productAnalytics: false, termsAcceptedAt: 1_700_000_000)

        XCTAssertTrue(store.firstRunComplete)
        XCTAssertFalse(store.productAnalyticsEnabled)
        XCTAssertTrue(store.productAnalyticsPreferenceRecorded)

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(reloaded.firstRunComplete)
        XCTAssertFalse(reloaded.productAnalyticsEnabled)
        XCTAssertTrue(reloaded.productAnalyticsPreferenceRecorded)
        XCTAssertFalse(OnboardingView.initialProductAnalyticsValue(
            storedValue: reloaded.productAnalyticsEnabled,
            preferenceRecorded: reloaded.productAnalyticsPreferenceRecorded
        ))
    }

    func test_scheduleSendSettings_persistAndReload() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.birthdayDefaultSendMinute = 10 * 60 + 30 // 10:30am
        store.quietHoursEnabled = true
        store.quietStartMinute = 22 * 60
        store.quietEndMinute = 7 * 60
        store.birthdayClaudeTarget = .cowork // override the chat default

        // A fresh store over the same home must read the persisted values.
        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(reloaded.birthdayDefaultSendMinute, 10 * 60 + 30)
        XCTAssertEqual(reloaded.quietStartMinute, 22 * 60)
        XCTAssertEqual(reloaded.quietEndMinute, 7 * 60)
        XCTAssertEqual(reloaded.quietHours, QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60))
        XCTAssertEqual(reloaded.birthdayClaudeTarget, .cowork)
    }

    func test_telemetryAndDiagnosticsSettings_persistAndReload() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.productAnalyticsEnabled = true
        store.diagnosticsIncludeLocalEvents = false
        store.diagnosticsIncludeDaemonLogs = false
        store.diagnosticsIncludeCrashReports = true
        store.newMessageNotificationsEnabled = false
        store.newMessageNotificationPreviewStyle = .threadOnly

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(reloaded.productAnalyticsEnabled)
        XCTAssertTrue(reloaded.productAnalyticsPreferenceRecorded)
        XCTAssertFalse(reloaded.diagnosticsIncludeLocalEvents)
        XCTAssertFalse(reloaded.diagnosticsIncludeDaemonLogs)
        XCTAssertTrue(reloaded.diagnosticsIncludeCrashReports)
        XCTAssertFalse(reloaded.newMessageNotificationsEnabled)
        XCTAssertEqual(reloaded.newMessageNotificationPreviewStyle, .threadOnly)
    }

    // MARK: - v1 → v2 migration

    func test_v1Migration_setsFirstRunCompleteAndDefaults() throws {
        // Seed a v1 settings.json — no schema_version key, only flat
        // require_approval. This is what existing v0.2.x users would
        // have on disk pre-upgrade.
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let v1Doc: [String: Any] = ["require_approval": false]
        try JSONSerialization.data(withJSONObject: v1Doc).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)

        // v1 reader assumes the user has already used the app.
        XCTAssertTrue(store.firstRunComplete)
        XCTAssertTrue(store.imessageEnabled)
        XCTAssertFalse(store.whatsappEnabled)
        XCTAssertFalse(store.requireApproval, "v1 require_approval value preserved")
        // Walkthrough fields default to false — this triggers the
        // upgrade-time walkthrough auto-open in DraftListView.
        XCTAssertFalse(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)
    }

    // MARK: - v2 read path — walkthrough field defaults

    func test_v2Read_absentWalkthroughFields_defaultToFalse() throws {
        // v0.3.0/v0.3.1 settings.json — schema_version=2 but no
        // walkthrough_complete or walkthrough_skipped keys.
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let v2NoWalkthrough: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "require_approval": true,
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": true, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: v2NoWalkthrough).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store.firstRunComplete, "existing user, onboarding done")
        XCTAssertTrue(store.whatsappEnabled)
        // Both new fields absent in on-disk file → default false → walkthrough
        // fires once on next popover render. This is the resolved Open Q #1
        // from the v0.3.2 plan.
        XCTAssertFalse(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)
    }

    func test_v2Read_preservesWalkthroughComplete() throws {
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let doc: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "walkthrough_complete": true,
            "walkthrough_skipped": false,
            "require_approval": true,
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": false, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store.walkthroughComplete)
        XCTAssertFalse(store.walkthroughSkipped)
    }

    // MARK: - Persistence round-trip

    func test_walkthroughCompletePersists() throws {
        let store1 = SettingsStore(homeOverride: tmpHome)
        XCTAssertFalse(store1.walkthroughComplete)
        store1.walkthroughComplete = true

        // New instance reads the persisted value.
        let store2 = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store2.walkthroughComplete)
    }

    func test_walkthroughSkippedPersists() throws {
        let store1 = SettingsStore(homeOverride: tmpHome)
        store1.walkthroughSkipped = true

        let store2 = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store2.walkthroughSkipped)
    }

    // MARK: - Mirror to ~/.whatsapp-mcp/settings.json

    func test_whatsappRequireApprovalMirrorsToDaemonFile() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.whatsappRequireApproval = false

        let daemonFile = tmpHome.appendingPathComponent(".whatsapp-mcp/settings.json")
        let data = try Data(contentsOf: daemonFile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["require_approval"] as? Bool, false)
    }

    func test_whatsappMirrorPreservesUnrelatedKeys() throws {
        // Daemon's own file has rate-limit knobs we mustn't clobber.
        let daemonDir = tmpHome.appendingPathComponent(".whatsapp-mcp")
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        let daemonFile = daemonDir.appendingPathComponent("settings.json")
        let preexisting: [String: Any] = [
            "require_approval": true,
            "daily_cap": 200,
            "min_staged_age_ms": 30000,
            "draft_ttl_days": 7,
        ]
        try JSONSerialization.data(withJSONObject: preexisting).write(to: daemonFile)

        let store = SettingsStore(homeOverride: tmpHome)
        store.whatsappRequireApproval = false

        let data = try Data(contentsOf: daemonFile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["require_approval"] as? Bool, false)
        XCTAssertEqual(json["daily_cap"] as? Int, 200)
        XCTAssertEqual(json["min_staged_age_ms"] as? Int, 30000)
        XCTAssertEqual(json["draft_ttl_days"] as? Int, 7)
    }

    // MARK: - Terms/Privacy acceptance + legacy WhatsApp risk ack

    func test_freshInstall_termsNotAcceptedAndLegacyWhatsAppAckFalse() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        // Absence on a fresh install → not accepted / legacy ack false.
        XCTAssertEqual(store.termsAcceptedVersion, "")
        XCTAssertEqual(store.termsAcceptedAt, 0)
        XCTAssertFalse(store.termsAccepted)
        XCTAssertFalse(store.whatsappRiskAcknowledged)
        // Fresh install must present onboarding (first run AND terms unaccepted).
        XCTAssertTrue(store.shouldPresentOnboarding)

        // Canonical schema persisted the legal block as not-accepted.
        let file = tmpHome.appendingPathComponent(".messages-mcp/settings.json")
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let legal = json["legal"] as? [String: Any]
        XCTAssertEqual(legal?["terms_accepted_version"] as? String, "")
        XCTAssertEqual(legal?["whatsapp_risk_acknowledged"] as? Bool, false)
    }

    func test_applyOnboardingChoices_recordsTermsAcceptanceAndPersists() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        store.applyOnboardingChoices(imessage: true, whatsapp: true, productAnalytics: true, termsAcceptedAt: 1_700_000_123)

        XCTAssertEqual(store.termsAcceptedVersion, Legal.termsVersion)
        XCTAssertEqual(store.termsAcceptedAt, 1_700_000_123)
        XCTAssertTrue(store.termsAccepted)
        // Onboarding done + current terms accepted → no re-present.
        XCTAssertFalse(store.shouldPresentOnboarding)

        // Round-trips through settings.json.
        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(reloaded.termsAcceptedVersion, Legal.termsVersion)
        XCTAssertEqual(reloaded.termsAcceptedAt, 1_700_000_123)
        XCTAssertTrue(reloaded.termsAccepted)
        XCTAssertFalse(reloaded.shouldPresentOnboarding)
    }

    func test_termsAccepted_falseWhenStoredVersionDiffers() throws {
        // Seed a v2 file whose stored terms version is an OLD value — the
        // re-acceptance-on-bump case.
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let doc: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "require_approval": true,
            "legal": [
                "terms_accepted_version": "1999-01-01",
                "terms_accepted_at": 1_700_000_000.0,
                "whatsapp_risk_acknowledged": true,
            ],
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": true, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertEqual(store.termsAcceptedVersion, "1999-01-01")
        // Stored version != current → not accepted → re-present onboarding even
        // though first_run_complete is true.
        XCTAssertFalse(store.termsAccepted)
        XCTAssertTrue(store.shouldPresentOnboarding)
        // Legacy risk ack persisted independently and survived the reload.
        XCTAssertTrue(store.whatsappRiskAcknowledged)
    }

    func test_termsAccepted_trueWhenStoredVersionMatchesCurrent() throws {
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let doc: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "require_approval": true,
            "legal": [
                "terms_accepted_version": Legal.termsVersion,
                "terms_accepted_at": 1_700_000_000.0,
                "whatsapp_risk_acknowledged": false,
            ],
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": false, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(store.termsAccepted)
        XCTAssertFalse(store.shouldPresentOnboarding)
    }

    func test_v2Read_absentLegalBlock_defaultsToNotAccepted() throws {
        // A v2 file predating the Terms gate (no `legal` block) must fail
        // safe: terms unaccepted, legacy ack false, onboarding re-presents.
        let dir = tmpHome.appendingPathComponent(".messages-mcp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let doc: [String: Any] = [
            "schema_version": 2,
            "first_run_complete": true,
            "require_approval": true,
            "transports": [
                "imessage": ["enabled": true, "require_approval": true],
                "whatsapp": ["enabled": false, "require_approval": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: file)

        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertFalse(store.termsAccepted)
        XCTAssertFalse(store.whatsappRiskAcknowledged)
        XCTAssertTrue(store.shouldPresentOnboarding)
    }

    func test_legacyWhatsAppRiskAck_persistsAndReloads() throws {
        let store = SettingsStore(homeOverride: tmpHome)
        XCTAssertFalse(store.whatsappRiskAcknowledged)

        store.acknowledgeWhatsAppRisk()
        XCTAssertTrue(store.whatsappRiskAcknowledged)

        let reloaded = SettingsStore(homeOverride: tmpHome)
        XCTAssertTrue(reloaded.whatsappRiskAcknowledged)
    }

    func test_shouldPresentOnboarding_pureHelper() {
        // Fresh install: not run, not accepted.
        XCTAssertTrue(SettingsStore.shouldPresentOnboarding(firstRunComplete: false, termsAccepted: false))
        // Re-acceptance on bump: run complete, but terms no longer accepted.
        XCTAssertTrue(SettingsStore.shouldPresentOnboarding(firstRunComplete: true, termsAccepted: false))
        // First run somehow not flagged but terms accepted — still present.
        XCTAssertTrue(SettingsStore.shouldPresentOnboarding(firstRunComplete: false, termsAccepted: true))
        // Steady state: onboarding done and current terms accepted.
        XCTAssertFalse(SettingsStore.shouldPresentOnboarding(firstRunComplete: true, termsAccepted: true))
    }
}
