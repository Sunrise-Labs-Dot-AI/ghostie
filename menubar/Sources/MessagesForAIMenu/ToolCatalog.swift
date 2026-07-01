import Foundation

/// Pure model of the user-choosable tools and what each choice implies:
/// which experience mode to run, which tool IDs to persist, and the
/// minimum permission set the selection needs.
///
/// Tool IDs are the `ToolRegistry` IDs (ConsoleView.swift) — the sidebar,
/// the onboarding picker, and `SettingsStore.enabledToolIDs` all speak the
/// same identifiers. Kept here (not in ConsoleView) so SettingsStore and
/// the onboarding flow can reason about tools without touching view code,
/// and so the derivations have plain unit-test coverage.
enum ToolCatalog {
  // MARK: - Identity

  static let messages = "messages"
  static let wrapped = "wrapped"
  static let dontGhost = "dontGhost"
  static let birthdays = "birthdays"
  static let keepTabs = "keepTabs"
  static let workPersonal = "workPersonal"
  static let eq = "eq"
  static let textingAnalytics = "textingAnalytics"
  static let textingVoice = "textingVoice"
  static let babysitter = "babysitter"

  /// Every tool ID the app knows about. Used as the backward-compatible
  /// default when a settings file predates granular tools: existing users
  /// keep everything enabled.
  static let allToolIDs: Set<String> = [
    messages, wrapped, dontGhost, birthdays, keepTabs, workPersonal, eq,
    textingAnalytics, textingVoice, babysitter,
  ]

  /// The tools offered as cards in onboarding, in display order.
  /// `textingVoice` is deliberately not a card — it's drafting
  /// infrastructure that rides along with Messages (see
  /// `persistedTools(forChosen:)`).
  static let choosableToolIDs: [String] = [
    wrapped, messages, birthdays, keepTabs, dontGhost, eq, textingAnalytics,
    workPersonal, babysitter,
  ]

  /// The "Recommended" preset: the core approve-and-send loop plus the two
  /// most broadly useful extras.
  static let recommendedToolIDs: Set<String> = [messages, wrapped, birthdays]

  /// The "Just Texting Wrapped" quick path.
  static let wrappedOnlyToolIDs: Set<String> = [wrapped]

  // MARK: - Derivations

  /// Choosing exactly Wrapped maps to the existing lightweight experience
  /// mode (no daemons, no background messaging loops). Anything broader
  /// runs the full experience so navigation and services behave.
  static func experienceMode(forChosen chosen: Set<String>) -> AppExperienceMode {
    chosen == wrappedOnlyToolIDs ? .textingWrappedOnly : .full
  }

  /// The tool set persisted to settings for a picker selection. Texting
  /// Voice is bound to Messages: it exists to steer drafts written into
  /// the inbox, so it follows the Messages choice rather than being its
  /// own card.
  static func persistedTools(forChosen chosen: Set<String>) -> Set<String> {
    var tools = chosen
    if chosen.contains(messages) {
      tools.insert(textingVoice)
    } else {
      tools.remove(textingVoice)
    }
    return tools
  }

  // MARK: - Lazy permissions

  /// Tools that read the Messages database (`~/Library/Messages/chat.db`)
  /// and therefore need Full Disk Access *when first used*. Everything the
  /// picker offers reads chat.db; Work/Personal reads conversations through
  /// the Messages surface it filters.
  static let chatDbToolIDs: Set<String> = [
    messages, wrapped, dontGhost, birthdays, keepTabs, workPersonal, eq,
    textingAnalytics, textingVoice, babysitter,
  ]

  /// The minimum permission surface a selection implies. Used by onboarding
  /// to explain what will be asked for (and when) — the asks themselves are
  /// deferred to first use of each tool.
  struct PermissionNeeds: Equatable {
    /// At least one chosen tool reads the Messages database. Granted via
    /// Full Disk Access in System Settings, requested in-pane at first use.
    var fullDiskAccess: Bool = false
    /// Contacts is never required — it only improves names and birthdays.
    /// True when a chosen tool benefits, so onboarding can say so.
    var contactsOptional: Bool = false
    /// WhatsApp was toggled on, so QR pairing runs right after onboarding.
    var whatsappPairing: Bool = false
  }

  static func permissionNeeds(
    forChosen chosen: Set<String>,
    whatsappToggled: Bool
  ) -> PermissionNeeds {
    PermissionNeeds(
      fullDiskAccess: !chosen.isDisjoint(with: chatDbToolIDs),
      contactsOptional: !chosen.isDisjoint(with: [messages, birthdays, keepTabs, dontGhost, eq, babysitter]),
      whatsappPairing: chosen.contains(messages) && whatsappToggled
    )
  }
}
