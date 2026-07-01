import SwiftUI

struct AutomationsView: View {
  @EnvironmentObject private var automationStore: AutomationStore
  @EnvironmentObject private var draftStore: DraftStore
  @EnvironmentObject private var settings: SettingsStore
  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedID: String?
  @State private var title = ""
  @State private var recipientName = ""
  @State private var recipientHandle = ""
  @State private var recipientQuery = ""
  @State private var contactMatches: [ContactMatch] = []
  @State private var bodyText = ""
  @State private var platform: Platform = .imessage
  @State private var cadence: AutomationCadence = .weekly
  @State private var recurrenceInterval = 1
  @State private var selectedWeekdays: Set<Int> = []
  @State private var nextRunAt = Date().addingTimeInterval(3600)
  @State private var formError: String?

  private var selectedAutomation: MessageAutomation? {
    guard let selectedID else { return nil }
    return automationStore.automations.first { $0.id == selectedID }
  }

  private var isEditing: Bool { selectedAutomation != nil }

  var body: some View {
    HSplitView {
      automationList
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
      editor
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.ghostieShellContent(colorScheme))
    }
    .onAppear {
      if selectedID == nil {
        selectedID = automationStore.automations.first?.id
        loadSelected()
      }
    }
    .onChange(of: selectedID) { loadSelected() }
    .onChange(of: recipientQuery) { _, _ in refreshContacts() }
    .onChange(of: cadence) { _, newValue in
      if newValue == .weekly || newValue == .biweekly {
        if selectedWeekdays.isEmpty {
          selectedWeekdays = [Calendar.current.component(.weekday, from: nextRunAt)]
        }
        if newValue == .biweekly && recurrenceInterval < 2 {
          recurrenceInterval = 2
        }
      } else {
        selectedWeekdays = []
        if recurrenceInterval < 1 { recurrenceInterval = 1 }
      }
    }
  }

  private var automationList: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
      Rectangle()
        .fill(DS.Color.ghostieShellLine(colorScheme))
        .frame(height: 1)
      if automationStore.automations.isEmpty {
        emptyList
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(automationStore.automations) { automation in
              Button {
                withAnimation(.easeInOut(duration: 0.14)) {
                  selectedID = automation.id
                }
              } label: {
                AutomationRow(automation: automation, selected: selectedID == automation.id)
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button(automation.isEnabled ? "Pause" : "Resume") {
                  try? automationStore.setEnabled(id: automation.id, !automation.isEnabled)
                }
                Button("Delete", role: .destructive) {
                  delete(automation)
                }
              }
              .accessibilityLabel(automation.displayTitle)
            }
          }
          .padding(8)
        }
      }
      if let error = automationStore.lastError {
        Rectangle()
          .fill(DS.Color.ghostieShellLine(colorScheme))
          .frame(height: 1)
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.amber(colorScheme))
          .padding(12)
      }
    }
    .background(DS.Color.ghostieShellRail(colorScheme))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Automations")
            .font(DS.Font.threadListTitle)
            .foregroundStyle(DS.Color.ghostieShellInk(colorScheme))
          Text("Recurring texts that create scheduled messages on your cadence.")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
        }
        Spacer()
        Button {
          startNew()
        } label: {
          Label("New", systemImage: "plus")
        }
        .dsButton(.primary, size: .small)
      }
      Label("Each run stages an approved scheduled message, then the normal Messages queue handles sending, quiet hours, and failures.", systemImage: "checkmark.shield.fill")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      if automationStore.pendingApprovalCount > 0 {
        Label("\(automationStore.pendingApprovalCount) proposal\(automationStore.pendingApprovalCount == 1 ? "" : "s") need approval.", systemImage: "hand.raised.fill")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.amber(colorScheme))
      }
    }
  }

  private var emptyList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: "repeat.circle.fill")
        .font(.system(size: 32))
        .foregroundStyle(DS.Color.accentTeal(colorScheme))
      Text("No automations yet")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ghostieShellInk(colorScheme))
      Text("Create a recurring text for a habit, reminder, or check-in. It will appear in Messages as a scheduled message before it sends.")
        .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
      Button {
        startNew()
      } label: {
        Label("Create Automation", systemImage: "plus")
      }
      .dsButton(.primary)
      .padding(.top, 6)
    }
    .padding(22)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var editor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        editorHeader
        recipientSection
        messageSection
        cadenceSection
        sendPolicySection
        historySection
        actionsSection
      }
      .padding(28)
      .frame(maxWidth: 760, alignment: .leading)
    }
  }

  private var editorHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text(isEditing ? "Edit automation" : "New automation")
            .font(DS.Font.paneTitle)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text("Set the recipient, message, transport, and cadence.")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
        if let selectedAutomation {
          StatusPill(automation: selectedAutomation)
        }
      }
      if let selectedAutomation, selectedAutomation.needsApproval {
        Label("Proposed by \(selectedAutomation.proposedBy ?? "an MCP tool"). Review and approve before it can run.", systemImage: "hand.raised.fill")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.amber(colorScheme))
      }
      TextField("Automation name, optional", text: $title)
        .dsInput(colorScheme)
    }
  }

  private var recipientSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionTitle("Recipient", systemImage: "person.crop.circle")
      if !recipientHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        selectedRecipientPill
      } else {
        TextField("Search Contacts", text: $recipientQuery)
          .dsInput(colorScheme)
        if contactMatches.isEmpty {
          Text(recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 ? "Type at least two letters to search Contacts." : "No matching contacts.")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        } else {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(contactMatches.prefix(8)) { match in
              if let handle = match.bestHandle {
                contactButton(match: match, handle: handle)
              }
            }
          }
        }
      }
      DSSegmentedControl([Platform.imessage, .whatsapp], selection: $platform) { $0.displayName } icon: { platform in
        platform == .imessage ? Platform.imessage.sfSymbol : "phone.bubble.left.fill"
      }
      if platform == .whatsapp && !recipientHandle.isEmpty && whatsappJID(for: recipientHandle) == nil {
        Label("WhatsApp automations need a phone number or WhatsApp contact, not an email address.", systemImage: "exclamationmark.triangle.fill")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.amber(colorScheme))
      }
      if platform == .whatsapp && !settings.whatsappEnabled {
        Label("Turn on WhatsApp in Settings before this automation can run.", systemImage: "exclamationmark.triangle.fill")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.amber(colorScheme))
      }
    }
  }

  private var selectedRecipientPill: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(DS.Color.green(colorScheme))
      VStack(alignment: .leading, spacing: 1) {
        Text(recipientName.isEmpty ? recipientHandle : recipientName)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        if recipientName.isEmpty {
          Text(recipientHandle)
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
      }
      Spacer()
      Button("Change") {
        recipientName = ""
        recipientHandle = ""
        recipientQuery = ""
        contactMatches = []
      }
      .dsButton(.ghost, size: .small)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .fill(DS.Color.greenDim(colorScheme))
    )
    .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.row)
  }

  private func contactButton(match: ContactMatch, handle: String) -> some View {
    Button {
      recipientName = match.name
      recipientHandle = handle
      recipientQuery = ""
      contactMatches = []
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "person")
          .frame(width: 18)
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
        VStack(alignment: .leading, spacing: 1) {
          Text(match.name)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
        }
        Spacer()
      }
      .contentShape(Rectangle())
      .padding(8)
      .dsCard(colorScheme, fill: DS.Color.ghostieShellCardStrong(colorScheme), radius: DS.Radius.row)
    }
    .buttonStyle(.plain)
  }

  private var messageSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionTitle("Message", systemImage: "text.bubble")
      TextEditor(text: $bodyText)
        .font(.body)
        .frame(minHeight: 120)
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(DS.Color.g050(colorScheme))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(DS.Color.line(colorScheme))
        )
      Text("Message bodies for automations are stored locally because they are the content to send.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
  }

  private var cadenceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Cadence", systemImage: "calendar")
      HStack(spacing: 12) {
        DSStepperField(title: "Every", value: $recurrenceInterval, range: 1...52, suffix: cadenceUnitLabel)
        .frame(width: 220, alignment: .leading)
        DSSegmentedControl(
          [
            AutomationCadence.daily,
            .weekly,
            .monthly,
            .quarterly,
            .yearly
          ],
          selection: $cadence
        ) { cadence in
          switch cadence {
          case .daily: return "Day"
          case .weekly, .biweekly: return "Week"
          case .monthly: return "Month"
          case .quarterly: return "Quarter"
          case .yearly: return "Year"
          }
        }
      }
      if cadence == .weekly || cadence == .biweekly {
        weekdayPicker
      }
      DSDateTimeField(title: "First send", selection: $nextRunAt, displayedComponents: [.date, .hourAndMinute])
        .frame(maxWidth: 300)
      Text(recurrenceSummary)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
  }

  private var cadenceUnitLabel: String {
    switch cadence {
    case .daily: return recurrenceInterval == 1 ? "day" : "days"
    case .weekly, .biweekly: return recurrenceInterval == 1 ? "week" : "weeks"
    case .monthly: return recurrenceInterval == 1 ? "month" : "months"
    case .quarterly: return recurrenceInterval == 1 ? "quarter" : "quarters"
    case .yearly: return recurrenceInterval == 1 ? "year" : "years"
    }
  }

  private var recurrenceSummary: String {
    let days = weekdayLabel(Array(selectedWeekdays).sorted())
    if cadence == .weekly || cadence == .biweekly {
      let prefix = recurrenceInterval == 1 ? "Repeats weekly" : "Repeats every \(recurrenceInterval) weeks"
      return days.isEmpty ? "\(prefix). After each run, the next occurrence advances automatically." : "\(prefix) on \(days). After each run, the next occurrence advances automatically."
    }
    return "After each run, the next occurrence advances automatically."
  }

  private var weekdayPicker: some View {
    HStack(spacing: 6) {
      ForEach(1...7, id: \.self) { weekday in
        Button {
          if selectedWeekdays.contains(weekday), selectedWeekdays.count > 1 {
            selectedWeekdays.remove(weekday)
          } else {
            selectedWeekdays.insert(weekday)
          }
        } label: {
          Text(Self.shortWeekdaySymbols[weekday - 1])
            .font(.caption.weight(.semibold))
            .frame(width: 34, height: 26)
            .background(
              RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(selectedWeekdays.contains(weekday) ? DS.Color.accentTeal(colorScheme) : DS.Color.g160(colorScheme))
            )
            .foregroundStyle(selectedWeekdays.contains(weekday) ? Color.white : DS.Color.ink3(colorScheme))
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var sendPolicySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionTitle("Send policy", systemImage: "checkmark.shield")
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "clock.badge.checkmark")
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
        VStack(alignment: .leading, spacing: 4) {
          Text("Runs create approved scheduled messages")
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text("Quiet Hours and stale-send protection still apply. If a send is held or fails, it stays visible in Messages.")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.Color.accentTeal(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12)))
      .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.row)
    }
  }

  private var actionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let formError {
        Label(formError, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(DS.Color.amber(colorScheme))
          .font(DS.Font.settingsCaption)
      }
      HStack {
        if let selectedAutomation, selectedAutomation.needsApproval || selectedAutomation.needsReapproval {
          Button(selectedAutomation.needsReapproval ? "Re-approve Automation" : "Approve Automation") {
            approve(selectedAutomation)
          }
          .dsButton(.primary)
          .disabled(!canSave)
        }

        if selectedAutomation?.needsApproval == true {
          Button("Save Changes") {
            save()
          }
          .dsButton(.secondary)
          .disabled(!canSave)
        } else {
          Button(isEditing ? "Save Changes" : "Create Automation") {
            save()
          }
          .dsButton(.primary)
          .disabled(!canSave)
        }

        if let selectedAutomation {
          Button(selectedAutomation.isEnabled ? "Pause" : "Resume") {
            toggle(selectedAutomation)
          }
          .dsButton(.secondary)
          .disabled(selectedAutomation.needsApproval)
          Button("Delete", role: .destructive) {
            delete(selectedAutomation)
          }
          .dsButton(.destructive)
        }
      }
    }
  }

  @ViewBuilder
  private var historySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionTitle("Send history", systemImage: "clock.arrow.circlepath")
      if let selectedAutomation {
        let history = selectedAutomation.runHistory ?? []
        if history.isEmpty {
          Text("No sends yet. The first run appears here after this automation creates an approved scheduled message.")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        } else {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(history.prefix(8)) { run in
              historyRow(run)
            }
          }
        }
      } else {
        Text("No send history yet.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
    }
  }

  private func historyRow(_ run: AutomationRunRecord) -> some View {
    let draft = draftStore.drafts.first { $0.id == run.draftID }
    let status = historyStatus(for: draft)
    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: status.symbol)
        .foregroundStyle(status.color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(status.label)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text("Scheduled for \(run.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? "unknown time")")
          .font(DS.Font.monoMicro)
          .foregroundStyle(DS.Color.ink3(colorScheme))
        if let generated = run.generatedDate {
          Text("Created \(Self.relative(generated))")
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
      }
      Spacer()
    }
    .padding(10)
    .dsCard(colorScheme, fill: DS.Color.ghostieShellCardStrong(colorScheme), radius: DS.Radius.row)
  }

  private var canSave: Bool {
    !recipientHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      (platform != .whatsapp || whatsappJID(for: recipientHandle) != nil)
  }

  private func startNew() {
    selectedID = nil
    title = ""
    recipientName = ""
    recipientHandle = ""
    recipientQuery = ""
    contactMatches = []
    bodyText = ""
    platform = .imessage
    cadence = .weekly
    nextRunAt = Date().addingTimeInterval(3600)
    recurrenceInterval = 1
    selectedWeekdays = [Calendar.current.component(.weekday, from: nextRunAt)]
    formError = nil
  }

  private func loadSelected() {
    guard let automation = selectedAutomation else {
      if automationStore.automations.isEmpty { startNew() }
      return
    }
    title = automation.title
    recipientName = automation.toHandleName ?? ""
    recipientHandle = automation.toHandle
    bodyText = automation.body
    platform = automation.platform
    cadence = automation.cadence == .biweekly ? .weekly : automation.cadence
    nextRunAt = automation.nextRunDate ?? Date().addingTimeInterval(3600)
    recurrenceInterval = automation.normalizedInterval
    selectedWeekdays = Set(automation.normalizedWeekdays)
    if (cadence == .weekly || cadence == .biweekly), selectedWeekdays.isEmpty {
      selectedWeekdays = [Calendar.current.component(.weekday, from: nextRunAt)]
    }
    recipientQuery = ""
    contactMatches = []
    formError = nil
  }

  private func save() {
    formError = nil
    let normalizedNextRunAt = max(nextRunAt, Date())
    do {
      if var existing = selectedAutomation {
        existing.title = title
        existing.toHandleName = recipientName
        existing.toHandle = recipientHandle
        existing.body = bodyText
        existing.platform = platform
        existing.cadence = cadence
        existing.nextRunAt = MessageAutomation.isoString(normalizedNextRunAt)
        existing.recurrenceInterval = normalizedRecurrenceInterval
        existing.weekdays = normalizedWeekdays
        existing.recurrenceAnchorAt = MessageAutomation.isoString(normalizedNextRunAt)
        try automationStore.update(existing)
        selectedID = existing.id
      } else {
        let created = try automationStore.create(
          title: title,
          platform: platform,
          toHandle: recipientHandle,
          toHandleName: recipientName,
          body: bodyText,
          cadence: cadence,
          nextRunAt: normalizedNextRunAt,
          recurrenceInterval: normalizedRecurrenceInterval,
          weekdays: normalizedWeekdays
        )
        selectedID = created.id
      }
      loadSelected()
    } catch {
      if let storeError = error as? AutomationStoreError {
        formError = storeError.description
      } else {
        formError = error.localizedDescription
      }
    }
  }

  private func toggle(_ automation: MessageAutomation) {
    try? automationStore.setEnabled(id: automation.id, !automation.isEnabled)
    loadSelected()
  }

  private func approve(_ automation: MessageAutomation) {
    save()
    try? automationStore.approve(id: automation.id)
    selectedID = automation.id
    loadSelected()
  }

  private func delete(_ automation: MessageAutomation) {
    try? automationStore.delete(id: automation.id)
    if selectedID == automation.id {
      selectedID = automationStore.automations.first?.id
      if selectedID == nil { startNew() } else { loadSelected() }
    }
  }

  private var normalizedRecurrenceInterval: Int {
    min(52, max(1, recurrenceInterval))
  }

  private var normalizedWeekdays: [Int]? {
    guard cadence == .weekly || cadence == .biweekly else { return nil }
    let days = Array(selectedWeekdays).filter { (1...7).contains($0) }.sorted()
    return days.isEmpty ? [Calendar.current.component(.weekday, from: nextRunAt)] : days
  }

  private func refreshContacts() {
    let query = recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else {
      contactMatches = []
      return
    }
    Task.detached(priority: .userInitiated) {
      let matches = ContactsExporter.searchContacts(query, limit: 12)
      await MainActor.run {
        if self.recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query {
          self.contactMatches = matches
        }
      }
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

  private func historyStatus(for draft: Draft?) -> (label: String, symbol: String, color: Color) {
    guard let draft else { return ("Created scheduled message", "calendar.badge.clock", DS.Color.ink3(colorScheme)) }
    if draft.isSent { return ("Sent", "checkmark.circle.fill", DS.Color.green(colorScheme)) }
    if draft.isHeld { return ("Held in Messages", "pause.circle.fill", DS.Color.amber(colorScheme)) }
    if draft.isScheduled { return ("Queued in Messages", "clock.badge.checkmark", DS.Color.accentTeal(colorScheme)) }
    return ("Drafted in Messages", "pencil.circle.fill", DS.Color.accentTeal(colorScheme))
  }

  private func weekdayLabel(_ values: [Int]) -> String {
    values.map { Self.shortWeekdaySymbols[max(0, min(6, $0 - 1))] }.joined(separator: ", ")
  }

  private static let shortWeekdaySymbols = ["S", "M", "T", "W", "Th", "F", "S"]

  private static func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
  }
}

private struct AutomationRow: View {
  let automation: MessageAutomation
  let selected: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: needsAttention ? "hand.raised.fill" : (automation.isEnabled ? "repeat" : "pause.circle"))
            .foregroundStyle(rowTint)
          Text(automation.displayTitle)
            .font(DS.Font.rowTitle)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
          Spacer()
          PlatformBadge(platform: automation.platform)
        }
        Text(automation.body)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .lineLimit(2)
        HStack {
          Text(automation.recurrenceLabel.uppercased())
          Text("·")
          Text(Self.nextRunText(automation.nextRunDate).uppercased())
        }
        .font(DS.Font.monoMicro)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        if automation.needsApproval {
          Label("Needs approval", systemImage: "hand.raised.fill")
            .font(DS.Font.chip)
            .foregroundStyle(DS.Color.amber(colorScheme))
        } else if automation.needsReapproval {
          Label("Re-approve to keep sending", systemImage: "hand.raised.fill")
            .font(DS.Font.chip)
            .foregroundStyle(DS.Color.amber(colorScheme))
        } else if let failure = automation.failureNote {
          Label(failure, systemImage: "exclamationmark.triangle.fill")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.amber(colorScheme))
            .lineLimit(2)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
    }
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .fill(selected ? DS.Color.ghostieShellSelectedStrong(colorScheme) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(selected ? DS.Color.ghostieShellSelectionStroke(colorScheme).opacity(0.24) : Color.clear, lineWidth: 1)
    )
  }

  private var rowTint: Color {
    if needsAttention {
      return DS.Color.amber(colorScheme)
    }
    if automation.isEnabled {
      return automation.platform == .imessage ? DS.Color.blue : Platform.whatsapp.accentColor
    }
    return DS.Color.ink3(colorScheme)
  }

  private var needsAttention: Bool { automation.needsApproval || automation.needsReapproval }

  private static func nextRunText(_ date: Date?) -> String {
    guard let date else { return "No next run" }
    return "Next \(date.formatted(date: .abbreviated, time: .shortened))"
  }
}

private struct StatusPill: View {
  let automation: MessageAutomation
  @Environment(\.colorScheme) private var colorScheme

  private var needsAttention: Bool { automation.needsApproval || automation.needsReapproval }

  private var label: String {
    if automation.needsApproval { return "Needs approval" }
    if automation.needsReapproval { return "Re-approve" }
    return automation.isEnabled ? "Active" : "Paused"
  }

  var body: some View {
    Text(label)
      .font(DS.Font.chip)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
          .fill(statusTint.opacity(0.14))
      )
      .foregroundStyle(statusTint)
  }

  private var statusTint: Color {
    if needsAttention { return DS.Color.amber(colorScheme) }
    if automation.isEnabled { return DS.Color.green(colorScheme) }
    return DS.Color.ink3(colorScheme)
  }
}

private struct SectionTitle: View {
  let title: String
  let systemImage: String
  @Environment(\.colorScheme) private var colorScheme

  init(_ title: String, systemImage: String) {
    self.title = title
    self.systemImage = systemImage
  }

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(DS.Font.settingsLabel)
      .foregroundStyle(DS.Color.ink(colorScheme))
  }
}
