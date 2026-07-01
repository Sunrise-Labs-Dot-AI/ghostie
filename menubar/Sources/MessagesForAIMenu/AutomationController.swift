import Foundation

@MainActor
final class AutomationController {
  private let automationStore: AutomationStore
  private let draftStore: DraftStore
  private let settings: SettingsStore
  private var timer: Timer?

  init(automationStore: AutomationStore, draftStore: DraftStore, settings: SettingsStore) {
    self.automationStore = automationStore
    self.draftStore = draftStore
    self.settings = settings
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.materializeDueAutomations() }
    }
    materializeDueAutomations()
  }

  deinit {
    timer?.invalidate()
  }

  func materializeDueAutomations(now: Date = Date(), calendar: Calendar = .current) {
    // Send gate (issue #77): `isAuthenticallyApproved` requires status==.approved
    // AND either a GUI approval THIS session or a valid per-install HMAC tag.
    // A hand-written automations.json that flips approvalStatus=approved without
    // a valid tag fails this check and never materializes a draft.
    for automation in automationStore.automations where automation.isEnabled && automation.isAuthenticallyApproved {
      guard let dueAt = automation.nextRunDate, dueAt <= now else { continue }
      do {
        let draft = try createDraft(for: automation, dueAt: dueAt)
        let nextRun = automation.nextFutureRun(after: dueAt, now: now, calendar: calendar)
        try automationStore.recordGenerated(
          id: automation.id,
          draftID: draft.id,
          generatedAt: now,
          dueAt: dueAt,
          nextRunAt: nextRun
        )
      } catch {
        try? automationStore.recordFailure(id: automation.id, note: error.localizedDescription)
      }
    }
  }

  private func createDraft(for automation: MessageAutomation, dueAt: Date) throws -> Draft {
    let source = "Automation: \(automation.displayTitle)"
    switch automation.platform {
    case .imessage:
      return try draftStore.createIMessageDraft(
        toHandle: automation.toHandle,
        toHandleName: automation.toHandleName,
        body: automation.body,
        scheduledAt: dueAt,
        approveScheduledDraft: true,
        contextMessages: nil,
        inReplyToThreadID: nil,
        source: source
      )
    case .whatsapp:
      guard settings.whatsappEnabled else {
        throw AutomationError.whatsappDisabled
      }
      guard let jid = whatsappJID(for: automation.toHandle) else {
        throw AutomationError.invalidWhatsAppRecipient
      }
      return try draftStore.createWhatsAppDraft(
        toHandle: jid,
        toHandleName: automation.toHandleName,
        body: automation.body,
        scheduledAt: dueAt,
        approveScheduledDraft: true,
        contextMessages: nil,
        source: source
      )
    }
  }

  private func whatsappJID(for handle: String) -> String? {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("@s.whatsapp.net") || trimmed.hasSuffix("@g.us") || trimmed.hasSuffix("@lid") {
      return trimmed
    }
    guard !trimmed.contains("@") else { return nil }
    var digits = trimmed.filter(\.isNumber)
    guard digits.count >= 10 else { return nil }
    if digits.count == 10 { digits = "1" + digits }
    return "\(digits)@s.whatsapp.net"
  }
}

enum AutomationError: Error, LocalizedError {
  case whatsappDisabled
  case invalidWhatsAppRecipient

  var errorDescription: String? {
    switch self {
    case .whatsappDisabled:
      return "Turn on WhatsApp in Settings before running this automation."
    case .invalidWhatsAppRecipient:
      return "WhatsApp automations need a phone number or WhatsApp contact."
    }
  }
}
