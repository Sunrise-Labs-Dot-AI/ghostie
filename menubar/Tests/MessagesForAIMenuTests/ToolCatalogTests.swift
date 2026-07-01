import XCTest
@testable import MessagesForAIMenu

/// Covers the pure tool-selection derivations behind the onboarding picker:
/// experience-mode mapping, the Texting Voice ↔ Messages coupling, the lazy
/// minimum-permission summary, and the catalog's agreement with ToolRegistry.
final class ToolCatalogTests: XCTestCase {
    func test_catalogIDsMatchToolRegistry() {
        // Every choosable ID must exist in ToolRegistry — the picker sources
        // titles/icons from the registry, so a drifted ID would silently drop
        // a card.
        let registryIDs = Set(ToolRegistry.all.map(\.id))
        for id in ToolCatalog.choosableToolIDs {
            XCTAssertTrue(registryIDs.contains(id), "\(id) missing from ToolRegistry")
        }
        // And the catalog's "all" set covers the registry, so the
        // everything-enabled back-compat default hides nothing.
        XCTAssertTrue(ToolCatalog.allToolIDs.isSuperset(of: registryIDs))
    }

    func test_experienceMode_wrappedOnlySelectionMapsToWrappedOnlyMode() {
        XCTAssertEqual(
            ToolCatalog.experienceMode(forChosen: [ToolCatalog.wrapped]),
            .textingWrappedOnly
        )
        XCTAssertEqual(
            ToolCatalog.experienceMode(forChosen: [ToolCatalog.wrapped, ToolCatalog.eq]),
            .full
        )
        XCTAssertEqual(
            ToolCatalog.experienceMode(forChosen: ToolCatalog.recommendedToolIDs),
            .full
        )
    }

    func test_persistedTools_bindsTextingVoiceToMessages() {
        XCTAssertTrue(
            ToolCatalog.persistedTools(forChosen: [ToolCatalog.messages])
                .contains(ToolCatalog.textingVoice)
        )
        XCTAssertFalse(
            ToolCatalog.persistedTools(forChosen: [ToolCatalog.wrapped, ToolCatalog.eq])
                .contains(ToolCatalog.textingVoice)
        )
    }

    func test_recommendedPreset_isMessagesWrappedBirthdays() {
        XCTAssertEqual(
            ToolCatalog.recommendedToolIDs,
            [ToolCatalog.messages, ToolCatalog.wrapped, ToolCatalog.birthdays]
        )
    }

    func test_permissionNeeds_deriveMinimumFromSelection() {
        // Every picker card reads chat.db → FDA flagged for any selection.
        let wrappedOnly = ToolCatalog.permissionNeeds(
            forChosen: [ToolCatalog.wrapped], whatsappToggled: false
        )
        XCTAssertTrue(wrappedOnly.fullDiskAccess)
        XCTAssertFalse(wrappedOnly.contactsOptional)
        XCTAssertFalse(wrappedOnly.whatsappPairing)

        // Contacts is surfaced (as optional) only when a tool benefits.
        let birthdays = ToolCatalog.permissionNeeds(
            forChosen: [ToolCatalog.birthdays], whatsappToggled: false
        )
        XCTAssertTrue(birthdays.contactsOptional)

        // WhatsApp pairing requires Messages chosen AND the toggle.
        let messagesNoWA = ToolCatalog.permissionNeeds(
            forChosen: [ToolCatalog.messages], whatsappToggled: false
        )
        XCTAssertFalse(messagesNoWA.whatsappPairing)
        let messagesWA = ToolCatalog.permissionNeeds(
            forChosen: [ToolCatalog.messages], whatsappToggled: true
        )
        XCTAssertTrue(messagesWA.whatsappPairing)
        // Toggle without Messages chosen is inert.
        let labsWA = ToolCatalog.permissionNeeds(
            forChosen: [ToolCatalog.eq], whatsappToggled: true
        )
        XCTAssertFalse(labsWA.whatsappPairing)

        let nothing = ToolCatalog.permissionNeeds(forChosen: [], whatsappToggled: false)
        XCTAssertFalse(nothing.fullDiskAccess)
    }

    func test_permissionsFootnote_statesLazyAskAndOptionalContacts() {
        let needs = ToolCatalog.permissionNeeds(
            forChosen: ToolCatalog.recommendedToolIDs, whatsappToggled: true
        )
        let text = OnboardingView.permissionsFootnoteText(for: needs)
        XCTAssertTrue(text.contains("first time"))
        XCTAssertTrue(text.contains("optional"))
        XCTAssertTrue(text.contains("WhatsApp"))

        let none = OnboardingView.permissionsFootnoteText(
            for: ToolCatalog.PermissionNeeds()
        )
        XCTAssertFalse(none.isEmpty)
    }
}
