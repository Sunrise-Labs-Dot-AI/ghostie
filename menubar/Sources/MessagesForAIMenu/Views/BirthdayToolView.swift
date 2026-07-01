import SwiftUI
import AppKit

/// Labs › Birthday Texts. A small approved list of people you'd actually text,
/// plus a suggestion inbox and manual add. The pane never drafts a message
/// itself: a birthday TODAY deep-links to that person's thread in the Messages
/// tab; a FUTURE birthday deep-links into the scheduled-text composer with the
/// recipient and the birthday morning prefilled and an EMPTY body.
struct BirthdayToolView: View {
  enum WindowChoice: Int, CaseIterable, Identifiable {
    case month = 30
    case quarter = 90
    case year = 366
    var id: Int { rawValue }
    var label: String {
      switch self {
      case .month: return "Next 30 days"
      case .quarter: return "Next 90 days"
      case .year: return "All year"
      }
    }
  }

  enum ViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case calendar = "Calendar"
    var id: String { rawValue }
  }

  @State private var windowChoice: WindowChoice = .month
  @State private var viewMode: ViewMode = .list
  @State private var monthOffset = 0 // months from the current month, for calendar nav
  @State private var showDismissed = false
  @State private var showManualAdd = false
  @State private var snoozedSuggestionIDs: Set<String> = []
  @State private var snoozedGapIDs: Set<String> = []
  @State private var dismissedGapIDs: Set<String> = []
  // Contacts search ("add a birthday"): live query → matches → per-match date.
  @State private var contactQuery = ""
  @State private var contactMatches: [ContactMatch] = []
  @State private var matchBirthday: [String: String] = [:]
  @State private var gapBirthday: [String: String] = [:]
  @EnvironmentObject private var settings: SettingsStore
  @EnvironmentObject private var nav: ConsoleNavigation
  @EnvironmentObject private var messagesViewState: MessagesViewState
  // Source of the birthdays the engine merges: the Contacts sidecar this
  // exporter writes. The pane re-reads Contacts on open (staleness-gated) and
  // on Refresh so a card edited in Contacts.app shows up without a relaunch.
  @EnvironmentObject private var contactsExporter: ContactsExporter
  @Environment(\.colorScheme) private var colorScheme
  // Owned by AppDelegate and injected on the console window, so it persists
  // across tab switches (no re-spawn / spinner on every reopen).
  @EnvironmentObject private var controller: BirthdayGeneratorController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
          .fullDiskAccessGate(toolName: "Birthday Texts")
        controlBar
        content
        manualAddSection
        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Pixel.canvas(colorScheme))
    // Tint the console rail + titlebar strip to match this lab's canvas.
    .consoleChromeBackground(Pixel.canvas(colorScheme))
    .onAppear {
      dismissedGapIDs = BirthdayGapDismissalStore.load()
      controller.loadIfNeeded(windowDays: windowChoice.rawValue)
      refreshContactsIfStale()
    }
    .onChange(of: viewMode) { _, mode in
      // Calendar defaults to the full year so months are not sparse, while still
      // leaving the visible filter under the user's control.
      let next = BirthdayWindowPolicy.choiceAfterModeChange(mode, current: windowChoice)
      if next == windowChoice {
        controller.load(windowDays: next.rawValue)
      } else {
        windowChoice = next
      }
    }
  }

  // MARK: - row CTAs (deep links — the pane itself never drafts)

  /// Birthday today → open that person's thread in the Messages tab. The
  /// canonical-handle match happens in MessagesPane (which owns the loaded
  /// conversation list) via the pending-selection deep link.
  private func openConversation(_ row: UpcomingBirthday) {
    let handles = ([row.bestHandle].compactMap { $0 } + row.handles)
    messagesViewState.pendingConversationHandles = handles
    nav.selection = .messages
  }

  /// Future birthday → the scheduled-text composer: recipient preselected,
  /// Scheduled mode, fire time prefilled to the birthday morning (the user's
  /// default send time, 9am unless changed, nudged out of quiet hours by the
  /// tested SendScheduler). Body EMPTY — the user writes the text.
  private func draftScheduledText(_ row: UpcomingBirthday) {
    guard let handle = row.bestHandle, !handle.isEmpty else { return }
    messagesViewState.pendingCompose = PendingComposeRequest(
      recipientHandle: handle,
      recipientName: row.name,
      scheduledAt: Self.scheduledFireDate(
        nextOccurrence: row.nextOccurrence,
        defaultMinute: settings.birthdayDefaultSendMinute,
        quiet: settings.quietHours
      )
    )
    nav.selection = .messages
  }

  /// The birthday-morning instant for the compose prefill: the engine's
  /// "yyyy-MM-dd" next occurrence at the default send minute, pushed out of
  /// quiet hours by SendScheduler. Nil when the date string is malformed (the
  /// composer then falls back to its own default). nonisolated: pure, and
  /// unit-tested off the main actor.
  nonisolated static func scheduledFireDate(nextOccurrence: String, defaultMinute: Int, quiet: QuietHours) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    guard let day = f.date(from: nextOccurrence) else { return nil }
    return SendScheduler.fireInstant(onLocalDay: day, defaultMinute: defaultMinute, quiet: quiet)
  }

  // MARK: - Contacts re-read (keep the birthdays sidecar fresh)

  /// Pane-open re-read, gated by the staleness policy so tab-flips stay free
  /// (the exporter's CNContactStoreDidChange observer covers live edits; this
  /// covers a missed notification). Reloads the list + gaps afterward so an
  /// edited card shows up without touching Refresh.
  private func refreshContactsIfStale() {
    guard BirthdayContactsRefreshPolicy.shouldRefresh(
      authorized: contactsExporter.authorizationStatus == .authorized,
      lastExportAt: contactsExporter.lastExportAt,
      now: Date()
    ) else { return }
    Task {
      await contactsExporter.exportNow()
      controller.reload()
      controller.loadGaps()
    }
  }

  /// The Refresh button: re-read Contacts cards FIRST (so a birthday edited in
  /// Contacts.app lands in the sidecar before the engine merges it), then
  /// force the signals recompute + reload.
  private func refreshAll() {
    Task {
      if contactsExporter.authorizationStatus == .authorized {
        await contactsExporter.exportNow()
      }
      controller.refresh()
      controller.loadGaps()
    }
  }

  private var modeToggle: some View {
    PixelSegmented(ViewMode.allCases, selection: $viewMode) { $0.rawValue } icon: { mode in
      switch mode {
      case .list: return "list.bullet"
      case .calendar: return "calendar"
      }
    }
    .frame(maxWidth: 220)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      PixelCakeBadge()
      VStack(alignment: .leading, spacing: 6) {
        Text("Birthday Texts")
          .font(Pixel.title)
          .foregroundStyle(Pixel.ink(colorScheme))
        PixelSprinkleRule()
        Text("A small list of people you'd actually text. Suggestions stay in review until you approve them, and nothing sends on its own.")
          .font(DS.Font.caption)
          .foregroundStyle(Pixel.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
    }
  }

  // MARK: - calendar

  private var calendarView: some View {
    let cal = Calendar.current
    let base = cal.date(byAdding: .month, value: monthOffset, to: startOfThisMonth(cal)) ?? Date()
    let comps = cal.dateComponents([.year, .month], from: base)
    let month = comps.month ?? 1
    let year = comps.year ?? cal.component(.year, from: Date())
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
          .pixelIconButton(.secondary).accessibilityLabel("Previous month")
        Spacer()
        Text(monthTitle(base))
          .font(Pixel.sectionTitle)
          .foregroundStyle(Pixel.ink(colorScheme))
        Spacer()
        Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
          .pixelIconButton(.secondary).accessibilityLabel("Next month")
      }
      .frame(maxWidth: 480)
      MonthGrid(year: year, month: month, byDay: birthdaysByDay(month: month))
        .frame(maxWidth: 480)
      if case .loading = controller.state {
        ProgressView().controlSize(.small)
      }
    }
    .padding(16)
    .pixelCard()
  }

  private func startOfThisMonth(_ cal: Calendar) -> Date {
    cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
  }

  private func monthTitle(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "LLLL yyyy"
    return f.string(from: d)
  }

  // day-of-month → names, for birthdays whose month matches the displayed month.
  // The curated list only ("On your list" = pinned) — the people you've chosen, not
  // every contact, so the calendar stays the list you built rather than a wall.
  private func birthdaysByDay(month: Int) -> [Int: [String]] {
    guard case .loaded(let result) = controller.state else { return [:] }
    var out: [Int: [String]] = [:]
    for b in result.upcoming where b.pinned && !b.muted {
      let parts = b.birthday.split(separator: "-").map(String.init)
      let md: (Int, Int)?
      if parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]) { md = (m, d) }
      else if parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) { md = (m, d) }
      else { md = nil }
      if let (m, d) = md, m == month {
        out[d, default: []].append(b.name)
      }
    }
    return out
  }

  private var controlBar: some View {
    HStack(spacing: 10) {
      PixelSegmented(WindowChoice.allCases, selection: $windowChoice) { $0.label }
        .frame(width: 360)
        .onChange(of: windowChoice) { _, new in controller.load(windowDays: new.rawValue) }

      modeToggle

      if case .loading = controller.state {
        ProgressView().controlSize(.small)
      } else {
        // Refresh re-reads Contacts cards + forces a recompute of the
        // starting-point signals (normal loads serve the long-TTL cache so the
        // list is instant).
        Button { refreshAll() } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 30)
        }
          .pixelIconButton(.secondary)
          .help("Refresh (re-read Contacts and recompute suggestions)")
          .accessibilityLabel("Refresh birthdays: re-read Contacts and recompute suggestions")
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch controller.state {
    case .idle, .loading:
      if case .loading = controller.state {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading your birthdays…")
            .font(Pixel.label).foregroundStyle(Pixel.ink3(colorScheme))
        }
        .padding(.top, 8)
      } else {
        EmptyView()
      }

    case .failed(let reason):
      errorCard(reason)

    case .loaded(let result):
      loadedList(result)
    }
  }

  @ViewBuilder
  private func loadedList(_ result: BirthdayListResult) -> some View {
    // The working list is deliberately small: people only become draftable after
    // you approve them. Engine suggestions stay in the inbox until then.
    let approved = BirthdayInboxPolicy.approved(result.upcoming)
    let suggestions = BirthdayInboxPolicy.suggestions(result.upcoming, snoozedIDs: snoozedSuggestionIDs)
    let otherUpcoming = BirthdayInboxPolicy.otherUpcoming(result.upcoming)
    let dismissed = BirthdayInboxPolicy.dismissed(result.upcoming)

    VStack(alignment: .leading, spacing: 20) {
      // Signals feed suggestions and the missing-birthday inbox, so surface the
      // missing-FDA fix-it.
      if !result.signalsAvailable {
        signalsUnavailableBanner
      }
      if viewMode == .calendar {
        calendarView
      } else {
        if approved.isEmpty {
          listEmptyState
        } else {
          section("People I'd text", subtitle: "Approved people only. Open today's conversation, or set up a scheduled text ahead of time.", rows: approved)
        }
        suggestionsInbox(rows: suggestions)
        otherUpcomingSection(rows: otherUpcoming)
        missingBirthdaysInbox
        if snoozedSuggestionIDs.count + snoozedGapIDs.count + dismissedGapIDs.count > 0 {
          Button { withAnimation {
            snoozedSuggestionIDs.removeAll()
            snoozedGapIDs.removeAll()
            dismissedGapIDs.removeAll()
            BirthdayGapDismissalStore.save(dismissedGapIDs)
          } } label: {
            Label("Show reminders again", systemImage: "arrow.uturn.backward")
          }
          .pixelButton(.secondary)
        }
        if !dismissed.isEmpty {
          if showDismissed {
            tailSection("Not someone I'd text", subtitle: "You dismissed these. Bring one back if you change your mind.", rows: dismissed)
            Button { withAnimation { showDismissed = false } } label: { Label("Hide", systemImage: "chevron.up") }
              .pixelButton(.ghost)
          } else {
            Button { withAnimation { showDismissed = true } } label: { Label("Show \(dismissed.count) dismissed", systemImage: "chevron.down") }
            .pixelButton(.ghost)
          }
        }
      }
    }
  }

  /// Shown when nothing is on the list yet (no pinned people in this window).
  private var listEmptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Your list is empty for this window.", systemImage: "tray")
        .font(Pixel.label)
        .foregroundStyle(Pixel.ink(colorScheme))
      Text("Approve someone from Suggestions, or add one person manually.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Pixel.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard()
  }

  @ViewBuilder
  private func tailSection(_ title: String, subtitle: String, rows: [UpcomingBirthday], eyebrow: String = "ARCHIVE") -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(title, subtitle: subtitle, eyebrow: eyebrow)
      ForEach(rows) { row in
        TailRowView(row: row, controller: controller)
      }
    }
  }

  @ViewBuilder
  private func suggestionsInbox(rows: [UpcomingBirthday]) -> some View {
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        sectionHeader(
          "Suggestions",
          subtitle: "Quick triage. Nobody here gets a draft until you add them to your list.",
          eyebrow: "REVIEW"
        )
        ForEach(rows) { row in
          BirthdaySuggestionRowView(
            row: row,
            isBusy: controller.busy.contains(row.id),
            onAdd: { controller.setPinned(row: row, true) },
            onDismiss: { controller.setMuted(row: row, true) },
            onLater: { withAnimation { _ = snoozedSuggestionIDs.insert(row.id) } }
          )
        }
      }
    }
  }

  @ViewBuilder
  private func otherUpcomingSection(rows: [UpcomingBirthday]) -> some View {
    if !rows.isEmpty {
      tailSection(
        "Other upcoming birthdays",
        subtitle: "Saved in Contacts and not on your birthday-text list yet. Add or dismiss as you go.",
        rows: rows,
        eyebrow: "CONTACTS"
      )
    }
  }

  @ViewBuilder
  private var manualAddSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          showManualAdd.toggle()
        }
      } label: {
        HStack(spacing: 10) {
          Image(systemName: showManualAdd ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Pixel.ink3(colorScheme))
            .frame(width: 16)
          Image(systemName: "person.badge.plus")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Pixel.blueText(colorScheme))
          Text("Add someone manually")
            .font(Pixel.label)
            .foregroundStyle(Pixel.ink(colorScheme))
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(showManualAdd ? "Hide manual birthday add" : "Show manual birthday add")

      if showManualAdd {
        contactSearchSection
          .padding(.top, 2)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(14)
    .pixelCard()
  }

  // MARK: - Contacts search (add a birthday)

  // Search Contacts and add someone's birthday — the way to put a NEW person on
  // your list (we no longer auto-rank a "who to text" list from volume). Pins the
  // person so they land under "On your list".
  @ViewBuilder
  private var contactSearchSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader("Add a birthday", subtitle: "Search your Contacts by name and add their birthday to your list.", eyebrow: "CONTACTS")
      TextField("Search contacts by name", text: $contactQuery)
        .pixelInput(colorScheme)
        .font(Pixel.label)
        .frame(maxWidth: 360)
        .accessibilityLabel("Search contacts by name to add a birthday")
        // Debounced + off-main: a unification fetch can take 1-5s on a large
        // address book, so we wait for a typing pause (cancellation coalesces
        // keystrokes) and run the query on a detached task, never the UI thread.
        .task(id: contactQuery) {
          let q = contactQuery.trimmingCharacters(in: .whitespacesAndNewlines)
          guard q.count >= 2 else { contactMatches = []; return }
          try? await Task.sleep(nanoseconds: 250_000_000)
          if Task.isCancelled { return }
          let results = await Task.detached { ContactsExporter.searchContacts(q) }.value
          if Task.isCancelled { return }
          contactMatches = results
          AccessibilityNotification.Announcement(
            results.isEmpty ? "No matching contacts" : "\(results.count) matching contacts"
          ).post()
        }
      ForEach(contactMatches) { match in
        contactMatchRow(match)
      }
    }
  }

  @ViewBuilder
  private func contactMatchRow(_ match: ContactMatch) -> some View {
    let bday = Binding(get: { matchBirthday[match.id] ?? match.savedBirthday ?? "" }, set: { matchBirthday[match.id] = $0 })
    let trimmed = bday.wrappedValue.trimmingCharacters(in: .whitespaces)
    let normalized = BirthdayDateInput.normalized(trimmed)
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(match.name)
          .font(Pixel.label)
          .foregroundStyle(Pixel.ink(colorScheme))
        if match.bestHandle == nil {
          Text("No phone or email on this contact")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(Pixel.ink3(colorScheme))
        }
      }
      Spacer()
      if controller.busy.contains(match.id) { ProgressView().controlSize(.small) }
      PixelDateEntryField(text: bday, accessibilityLabel: "Birthday for \(match.name)")
      Button("Add") {
        guard let normalized else { return }
        controller.addMatch(match, birthday: normalized)
        contactQuery = ""
        contactMatches = []
      }
      .disabled(normalized == nil || controller.busy.contains(match.id))
      .pixelButton(.primary)
      .accessibilityLabel("Add \(match.name) to my list")
      .accessibilityHint(trimmed.isEmpty ? "Enter a birthday date to enable" : "")
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard(fill: { Pixel.paperDeep($0) })
    // NOT .combine — the row has two interactive controls (date field + Add); a
    // combined element would flatten the text field out of the control hierarchy
    // and make every "Add" read the same. Each control carries its own per-contact
    // label above.
  }

  private var signalsUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "info.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Pixel.orangeText(colorScheme))
        Text("Couldn't read your message history. Grant Full Disk Access so suggestions can see who you're in regular contact with and find birthday hints. Your list itself still works without it.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Pixel.ink2(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Open Full Disk Access settings") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
          NSWorkspace.shared.open(url)
        }
      }
      .pixelButton(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard(fill: { Pixel.yellowDim($0) })
  }

  @ViewBuilder
  private func section(_ title: String, subtitle: String?, rows: [UpcomingBirthday]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader(title, subtitle: subtitle, eyebrow: "APPROVED")
      ForEach(rows) { row in
        BirthdayRowView(
          row: row,
          controller: controller,
          onOpenConversation: { openConversation(row) },
          onDraftScheduled: { draftScheduledText(row) }
        )
      }
    }
  }

  @ViewBuilder
  private var emptyCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No birthdays in this window.")
        .font(Pixel.label)
        .foregroundStyle(Pixel.ink(colorScheme))
      Text("Approve someone from Suggestions, add someone manually, or widen the window to 90 days.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Pixel.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard()
  }

  @ViewBuilder
  private func errorCard(_ reason: String) -> some View {
    // Genuine failures only (binary not bundled, decode error). Missing FDA is
    // NOT a failure here — it degrades and shows signalsUnavailableBanner.
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Pixel.orangeText(colorScheme))
      Text(reason)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Pixel.ink2(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard(fill: { Pixel.yellowDim($0) })
  }

  // People you clearly care about (high text/call affinity) with no birthday on
  // file. They live in the same review model: no list entry and no draft until
  // the user confirms a birthday.
  @ViewBuilder
  private var missingBirthdaysInbox: some View {
    let visibleGaps = controller.gaps.filter { !snoozedGapIDs.contains($0.id) && !dismissedGapIDs.contains($0.id) }
    if !visibleGaps.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        sectionHeader(
          "Suggestions without birthdays",
          subtitle: "People you talk to often, but no birthday is saved. Add a date before they can join the list.",
          eyebrow: "MISSING DATES"
        )
        ForEach(visibleGaps) { gap in
          gapRow(gap)
        }
      }
    }
  }

  @ViewBuilder
  private func gapRow(_ gap: GapContact) -> some View {
    let bday = Binding(get: { gapBirthday[gap.id] ?? "" }, set: { gapBirthday[gap.id] = $0 })
    let rawBirthday = bday.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedBirthday = BirthdayDateInput.normalized(rawBirthday)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        BirthdayAvatar(name: gap.name, systemImage: "person.crop.circle.badge.questionmark")
        VStack(alignment: .leading, spacing: 4) {
          Text(gap.name)
            .font(Pixel.name)
            .foregroundStyle(Pixel.ink(colorScheme))
          if !gap.reasons.isEmpty {
            Text(gap.reasons.joined(separator: " · "))
              .font(DS.Font.settingsCaption)
              .foregroundStyle(Pixel.ink3(colorScheme))
          }
        }
        Spacer()
        if controller.busy.contains(gap.id) { ProgressView().controlSize(.small) }
      }
      HStack(alignment: .top, spacing: 8) {
        PixelDateEntryField(text: bday, accessibilityLabel: "Birthday for \(gap.name)")
        Button("Add to list") {
          guard let normalizedBirthday else { return }
          controller.addBirthday(gap: gap, birthday: normalizedBirthday)
        }
          .disabled(normalizedBirthday == nil || controller.busy.contains(gap.id))
          .pixelButton(.primary)
        Spacer(minLength: 0)
      }
      HStack(spacing: 12) {
        Button("Not someone I'd text") {
          withAnimation {
            _ = dismissedGapIDs.insert(gap.id)
            BirthdayGapDismissalStore.save(dismissedGapIDs)
          }
        }
        .pixelButton(.ghost)
        Button("Remind me later") { withAnimation { _ = snoozedGapIDs.insert(gap.id) } }
          .pixelButton(.ghost)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard()
  }

  @ViewBuilder
  private func sectionHeader(_ title: String, subtitle: String?, eyebrow: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      PixelChip(text: eyebrow, tone: eyebrowTone(eyebrow))
      Text(title)
        .font(Pixel.sectionTitle)
        .foregroundStyle(Pixel.ink(colorScheme))
      if let subtitle {
        Text(subtitle)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Pixel.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Eyebrow → chip tone, keeping each inbox recognizable at a glance (the
  /// eyebrow TEXT stays the non-color signal; the tone is reinforcement only).
  private func eyebrowTone(_ eyebrow: String) -> PixelChip.Tone {
    switch eyebrow {
    case "APPROVED": return .yellow
    case "REVIEW": return .blue
    case "MISSING DATES": return .orange
    default: return .neutral
    }
  }

}

enum BirthdayInboxPolicy {
  static func approved(_ rows: [UpcomingBirthday]) -> [UpcomingBirthday] {
    rows.filter { $0.pinned && !$0.muted }
  }

  static func suggestions(_ rows: [UpcomingBirthday], snoozedIDs: Set<String>) -> [UpcomingBirthday] {
    rows.filter { !$0.pinned && !$0.muted && $0.suggested && !snoozedIDs.contains($0.id) }
  }

  static func otherUpcoming(_ rows: [UpcomingBirthday]) -> [UpcomingBirthday] {
    rows.filter { !$0.pinned && !$0.muted && !$0.suggested }
  }

  static func dismissed(_ rows: [UpcomingBirthday]) -> [UpcomingBirthday] {
    rows.filter { $0.muted }
  }
}

enum BirthdayWindowPolicy {
  static func choiceAfterModeChange(
    _ mode: BirthdayToolView.ViewMode,
    current: BirthdayToolView.WindowChoice
  ) -> BirthdayToolView.WindowChoice {
    mode == .calendar ? .year : current
  }
}

private enum BirthdayGapDismissalStore {
  private static var url: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("birthday-gap-dismissals.json")
  }

  static func load() -> Set<String> {
    guard let data = try? Data(contentsOf: url),
          let rows = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return Set(rows)
  }

  static func save(_ ids: Set<String>) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(Array(ids).sorted())
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Best effort. A failed preference write should not break the lab.
    }
  }
}

/// Date entry for the manual-add flows: a free-text field that accepts the
/// human formats BirthdayDateParser understands, with a live "→ June 14, 1990"
/// interpretation line (or a gentle format nudge), plus a calendar button that
/// opens a graphical picker prefilled from whatever parsed. Year-unknown entry
/// stays first-class: omit the year in text, or leave the picker's
/// "I know the year" toggle off. The picker writes the normalized storage
/// string back into the field — the text stays the single source of truth.
private struct PixelDateEntryField: View {
  @Binding var text: String
  let accessibilityLabel: String

  @State private var showPicker = false
  @State private var pickerDate = Date()
  @State private var includeYear = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        TextField("June 14 or 6/14/1990", text: $text)
          .pixelInput(colorScheme)
          .font(Pixel.label)
          .frame(width: 168)
          .accessibilityLabel(accessibilityLabel)
          .accessibilityHint("Type a date like June 14, 6 slash 14 slash 90, or 1990-06-14")
        Button { presentPicker() } label: {
          Image(systemName: "calendar")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 30)
        }
        .pixelIconButton(.secondary)
        .help("Pick the date on a calendar")
        .accessibilityLabel("Pick \(accessibilityLabel) on a calendar")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) { pickerPopover }
      }
      interpretation
    }
  }

  @ViewBuilder private var interpretation: some View {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      if let parsed = BirthdayDateParser.parse(trimmed) {
        Text("→ \(parsed.displayText)")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Pixel.blueText(colorScheme))
          .accessibilityLabel("Will save as \(parsed.displayText)")
      } else {
        Text("Try June 14, 6/14/90, or 1990-06-14.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Pixel.orangeText(colorScheme))
      }
    }
  }

  private var pickerPopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      DatePicker("Birthday", selection: $pickerDate, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .labelsHidden()
        .frame(width: 240)
      Toggle("I know the year", isOn: $includeYear)
        .toggleStyle(.checkbox)
        .font(Pixel.label)
        .help("Off saves just the month and day")
      HStack {
        Spacer()
        Button("Done") { showPicker = false }
          .pixelButton(.primary)
      }
    }
    .padding(14)
    .onChange(of: pickerDate) { _, _ in writeBack() }
    .onChange(of: includeYear) { _, _ in writeBack() }
  }

  /// Prefill from whatever the user already typed. Year-less values display a
  /// recent year but keep the toggle off so the year isn't saved.
  private func presentPicker() {
    if let parsed = BirthdayDateParser.parse(text) {
      pickerDate = Self.prefillDate(month: parsed.month, day: parsed.day, year: parsed.year)
      includeYear = parsed.year != nil
    } else {
      pickerDate = Date()
      includeYear = false
    }
    showPicker = true
  }

  /// A concrete Date for the picker. Year-less month/day picks the most recent
  /// year where it's a real, past date (Feb 29 lands on the latest leap year
  /// instead of lenient-Calendar rolling into Mar 1).
  private static func prefillDate(month: Int, day: Int, year: Int?) -> Date {
    let cal = Calendar(identifier: .gregorian)
    let nowYear = cal.component(.year, from: Date())
    let candidates = year.map { [$0] } ?? (0...4).map { nowYear - $0 }
    for y in candidates {
      guard let date = cal.date(from: DateComponents(year: y, month: month, day: day)) else { continue }
      let roundTrip = cal.dateComponents([.month, .day], from: date)
      guard roundTrip.month == month, roundTrip.day == day else { continue }
      if year != nil || date <= Date() { return date }
    }
    return Date()
  }

  /// Picking writes the normalized storage string straight back into the
  /// field, which re-parses it for the feedback line — one source of truth.
  private func writeBack() {
    let comps = Calendar.current.dateComponents([.year, .month, .day], from: pickerDate)
    guard let y = comps.year, let m = comps.month, let d = comps.day else { return }
    text = includeYear
      ? String(format: "%04d-%02d-%02d", y, m, d)
      : String(format: "%02d-%02d", m, d)
  }
}

/// Square pixel avatar: flat tinted fill (stable per name), chunky 2px border,
/// mono initials. The gap inbox passes a `systemImage` placeholder instead.
private struct BirthdayAvatar: View {
  let name: String
  var systemImage: String?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      Rectangle()
        .fill(fill)
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Pixel.ink2(colorScheme))
      } else {
        Text(initials)
          .font(Pixel.chip)
          .foregroundStyle(Pixel.ink(colorScheme))
      }
    }
    .frame(width: 34, height: 34)
    .overlay(Rectangle().strokeBorder(Pixel.border(colorScheme), lineWidth: 2))
  }

  /// Deterministic per-name accent so the list reads like a sprite sheet, not a
  /// uniform gray column. Placeholder (questionmark) avatars stay neutral.
  private var fill: Color {
    guard systemImage == nil else { return Pixel.paperDeep(colorScheme) }
    let palette: [Color] = [
      Pixel.yellowDim(colorScheme), Pixel.blueDim(colorScheme), Pixel.orangeDim(colorScheme),
    ]
    var hash = 0
    for scalar in name.unicodeScalars { hash = hash &* 31 &+ Int(scalar.value) }
    return palette[abs(hash) % palette.count]
  }

  private var initials: String {
    let parts = name.split(separator: " ").prefix(2)
    let letters = parts.compactMap { $0.first }.map(String.init).joined()
    return letters.isEmpty ? "?" : letters.uppercased()
  }
}

private struct ReasonChips: View {
  let reasons: [String]
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], alignment: .leading, spacing: 6) {
      ForEach(reasons, id: \.self) { reason in
        Text(reason)
          .font(Pixel.chip)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(chipFill(reason))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .strokeBorder(Pixel.border(colorScheme).opacity(0.55), lineWidth: 1.5)
          )
          .foregroundStyle(chipText(reason))
      }
    }
  }

  private func chipFill(_ reason: String) -> Color {
    let lower = reason.lowercased()
    if lower.contains("on your list") { return Pixel.blueDim(colorScheme) }
    if lower.contains("wished") { return Pixel.yellowDim(colorScheme) }
    return Pixel.paperDeep(colorScheme)
  }

  private func chipText(_ reason: String) -> Color {
    let lower = reason.lowercased()
    if lower.contains("on your list") { return Pixel.blueText(colorScheme) }
    if lower.contains("wished") { return Pixel.ink(colorScheme) }
    return Pixel.ink2(colorScheme)
  }
}

/// Lightweight review row for people the engine/assistant thinks may belong on
/// the list. The only ways forward are explicit human choices.
private struct BirthdaySuggestionRowView: View {
  let row: UpcomingBirthday
  let isBusy: Bool
  let onAdd: () -> Void
  let onDismiss: () -> Void
  let onLater: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        BirthdayAvatar(name: row.name)
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
              .font(Pixel.name)
              .foregroundStyle(Pixel.ink(colorScheme))
            Text(whenText)
              .font(Pixel.micro)
              .foregroundStyle(Pixel.ink3(colorScheme))
          }
          if let age = row.ageTurning {
            Text("turns \(age)")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(Pixel.ink3(colorScheme))
          }
          if !row.reasons.isEmpty {
            ReasonChips(reasons: Array(row.reasons.prefix(3)))
          }
        }
        Spacer()
        if isBusy {
          ProgressView().controlSize(.small)
        }
      }
      if !isBusy {
        HStack(spacing: 8) {
          Button { onAdd() } label: { Label("Add to list", systemImage: "plus.circle") }
            .pixelButton(.primary)
          Button("Not someone I'd text") { onDismiss() }
            .pixelButton(.secondary)
          Button("Remind me later") { onLater() }
            .pixelButton(.ghost)
          Spacer()
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard()
    .accessibilityElement(children: .contain)
  }

  private var whenText: String {
    switch row.daysUntil {
    case 0: return "today"
    case 1: return "tomorrow"
    default: return "in \(row.daysUntil) days"
    }
  }
}

/// "JUN" / "14" hero parts from the engine's "yyyy-MM-dd" next occurrence.
/// Internal (not view-private) so the parse is unit-testable; `locale` is
/// injectable for deterministic tests and defaults to the user's.
enum BirthdayHeroDate {
  static func parts(nextOccurrence: String, locale: Locale = .current) -> (month: String, day: String)? {
    guard let date = parseDay(nextOccurrence) else { return nil }
    let month = DateFormatter()
    month.calendar = Calendar(identifier: .gregorian)
    month.timeZone = .current
    month.locale = locale
    month.dateFormat = "MMM"
    let day = Calendar(identifier: .gregorian).component(.day, from: date)
    return (month.string(from: date).uppercased(with: locale), String(day))
  }

  /// Spoken form for VoiceOver ("June 14"); falls back to the raw string.
  static func spoken(nextOccurrence: String, locale: Locale = .current) -> String {
    guard let date = parseDay(nextOccurrence) else { return nextOccurrence }
    let out = DateFormatter()
    out.calendar = Calendar(identifier: .gregorian)
    out.timeZone = .current
    out.locale = locale
    out.dateFormat = "MMMM d"
    return out.string(from: date)
  }

  private static func parseDay(_ s: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = .current
    f.locale = Locale(identifier: "en_US_POSIX") // fixed-format parse
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
  }
}

/// One birthday card. The DATE is the hero (a pixel calendar tile + "turns N"
/// when the age is known); the name is secondary, relationship/notes tertiary.
/// No in-app drafting: today → "Open conversation" (Messages tab deep link);
/// future → "Draft a scheduled text" (compose sheet deep link, empty body).
private struct BirthdayRowView: View {
  let row: UpcomingBirthday
  @ObservedObject var controller: BirthdayGeneratorController
  let onOpenConversation: () -> Void
  let onDraftScheduled: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  private var isBusy: Bool { controller.busy.contains(row.id) }
  private var isToday: Bool { row.daysUntil == 0 }
  /// "Draft a scheduled text" needs a dispatchable handle to preselect.
  private var canCompose: Bool { !(row.bestHandle ?? "").isEmpty }
  /// "Open conversation" matches by ANY known handle, so it works even when
  /// there's no dispatchable best handle.
  private var canOpen: Bool { !(row.bestHandle ?? "").isEmpty || !row.handles.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        PixelDateTile(nextOccurrence: row.nextOccurrence, highlighted: isToday)
        VStack(alignment: .leading, spacing: 3) {
          // Hierarchy: the PERSON is the hero, then their birthday, then the
          // age they're turning (when known).
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
              .font(Pixel.heroTurns)
              .foregroundStyle(Pixel.ink(colorScheme))
            if row.muted {
              PixelChip(text: "Dismissed", tone: .neutral)
            }
          }
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(BirthdayHeroDate.spoken(nextOccurrence: row.nextOccurrence))
              .font(Pixel.name)
              .foregroundStyle(Pixel.ink2(colorScheme))
            if let age = row.ageTurning {
              Text("· turns \(age)")
                .font(Pixel.name)
                .foregroundStyle(Pixel.ink3(colorScheme))
            }
          }
          if !tertiaryText.isEmpty {
            Text(tertiaryText)
              .font(DS.Font.settingsCaption)
              .foregroundStyle(Pixel.ink3(colorScheme))
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
        PixelChip(text: whenText, tone: isToday ? .orange : .yellow)
      }
      // Read as one coherent phrase ("June 14, turns 32, Jane Doe, today")
      // rather than disconnected fragments (review A5).
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilitySummary)

      HStack(spacing: 8) {
        if isToday {
          Button { onOpenConversation() } label: {
            Label("Open conversation", systemImage: "bubble.left.and.bubble.right")
          }
          .pixelButton(.primary)
          .disabled(!canOpen || isBusy)
          .help(canOpen ? "Open your thread with \(row.name) in the Messages tab" : "No phone or email on this contact")
          .accessibilityLabel("Open conversation with \(row.name)")
        } else {
          Button { onDraftScheduled() } label: {
            Label("Draft a scheduled text", systemImage: "calendar.badge.clock")
          }
          .pixelButton(.primary)
          .disabled(!canCompose || isBusy)
          .help(canCompose ? "Open the composer with \(row.name) preselected and the birthday morning prefilled — you write the text" : "No phone or email on this contact")
          .accessibilityLabel("Draft a scheduled text to \(row.name)")
          .accessibilityHint("Opens the scheduled-text composer. Nothing sends until you approve it.")
        }

        Spacer()

        Menu {
          if row.pinned {
            Button("Remove from my list") { controller.setPinned(row: row, false) }
          } else {
            Button("Add to my list") { controller.setPinned(row: row, true) }
          }
          if row.muted {
            Button("Un-dismiss") { controller.setMuted(row: row, false) }
          } else {
            Button("Dismiss") { controller.setMuted(row: row, true) }
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .bold))
            .frame(width: 28, height: 28)
        }
        .pixelIconButton(.secondary)
        .fixedSize()
        .disabled(isBusy)
        .accessibilityLabel("More actions for \(row.name)")
      }

      if isToday ? !canOpen : !canCompose {
        Text("No phone or email on this contact. Add one to text them.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Pixel.ink3(colorScheme))
      }
    }
    .padding(16)
    .pixelCard()
    .opacity(row.muted ? 0.6 : 1)
  }

  private var whenText: String {
    switch row.daysUntil {
    case 0: return "Today"
    case 1: return "Tomorrow"
    default: return "in \(row.daysUntil) days · \(row.weekday)"
    }
  }

  /// Relationship/notes, tertiary under the name.
  private var tertiaryText: String {
    [row.relationship, row.notes]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
  }

  private var accessibilitySummary: String {
    // Same order as the visual hierarchy: person, birthday, age.
    var parts: [String] = [row.name]
    parts.append(BirthdayHeroDate.spoken(nextOccurrence: row.nextOccurrence))
    if let age = row.ageTurning { parts.append("turns \(age)") }
    if row.muted { parts.append("Dismissed") }
    parts.append(whenText.lowercased())
    if !tertiaryText.isEmpty { parts.append(tertiaryText) }
    return parts.joined(separator: ", ")
  }
}

/// The hero calendar tile: month band over a big day number, pixel chrome.
/// Decorative (the combined row label carries the spoken date).
private struct PixelDateTile: View {
  let nextOccurrence: String
  var highlighted = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let parts = BirthdayHeroDate.parts(nextOccurrence: nextOccurrence)
    VStack(spacing: 0) {
      Text(parts?.month ?? "—")
        .font(Pixel.chip)
        .foregroundStyle(DS.Color.hex(0x151515))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(Rectangle().fill(highlighted ? Pixel.yellowDeep : Pixel.yellow))
      Text(parts?.day ?? "?")
        .font(Pixel.heroDay)
        .foregroundStyle(Pixel.ink(colorScheme))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Rectangle().fill(Pixel.paperDeep(colorScheme)))
    }
    .frame(width: 58)
    .overlay(Rectangle().strokeBorder(Pixel.border(colorScheme), lineWidth: 2))
    .accessibilityHidden(true)
  }
}

/// Read-only awareness row for the non-suggested tail: name + date, plus explicit
/// add/dismiss choices. No opener, no Stage/Schedule — the tool does not prepare
/// a draft for these people until you promote one.
private struct TailRowView: View {
  let row: UpcomingBirthday
  @ObservedObject var controller: BirthdayGeneratorController
  @Environment(\.colorScheme) private var colorScheme
  private var isBusy: Bool { controller.busy.contains(row.id) }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      BirthdayAvatar(name: row.name)
      VStack(alignment: .leading, spacing: 3) {
        Text(row.name)
          .font(Pixel.label)
          .foregroundStyle(Pixel.ink(colorScheme))
        Text(subtitle)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Pixel.ink3(colorScheme))
      }
      Spacer()
      if isBusy {
        ProgressView().controlSize(.small)
      } else if row.muted {
        // Dismissed rows offer un-dismiss, not "add" — bringing one back to the list.
        Button { controller.setMuted(row: row, false) } label: {
          Label("Un-dismiss", systemImage: "arrow.uturn.backward")
        }
        .pixelButton(.secondary)
        .help("Bring this person back to your upcoming list")
        // Name the action per-row so VoiceOver's combined row + actions rotor
        // don't read "Un-dismiss" identically for every dismissed person.
        .accessibilityLabel("Un-dismiss \(row.name)")
      } else {
        HStack(spacing: 8) {
          Button { controller.setPinned(row: row, true) } label: {
            Label("Add to my list", systemImage: "plus.circle")
          }
          .pixelButton(.secondary)
          .help("Add to your list so you can draft, schedule, or send for them")
          .accessibilityLabel("Add \(row.name) to my list")

          Button { controller.setMuted(row: row, true) } label: {
            Label("Dismiss", systemImage: "xmark.circle")
          }
          .pixelButton(.ghost)
          .help("Hide \(row.name) from future birthday suggestions")
          .accessibilityLabel("Dismiss \(row.name) from birthday suggestions")
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pixelCard()
    .opacity(row.muted ? 0.6 : 1)
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String {
    var parts: [String] = []
    switch row.daysUntil {
    case 0: parts.append("today")
    case 1: parts.append("tomorrow")
    default: parts.append("in \(row.daysUntil) days · \(row.weekday)")
    }
    if let age = row.ageTurning { parts.append("turns \(age)") }
    return parts.joined(separator: " · ")
  }
}

/// A simple month grid: weekday header + day cells, birthdays marked on their day.
private struct MonthGrid: View {
  let year: Int
  let month: Int
  let byDay: [Int: [String]]
  @Environment(\.colorScheme) private var colorScheme

  private let weekdays = ["S", "M", "T", "W", "T", "F", "S"]

  var body: some View {
    let cal = Calendar.current
    let first = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 30
    let leading = cal.component(.weekday, from: first) - 1 // 1=Sun → 0 leading blanks
    let cells: [Int?] = Array(repeating: nil, count: leading) + (1...daysInMonth).map { Optional($0) }
    let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    return VStack(spacing: 6) {
      HStack(spacing: 4) {
        ForEach(0..<7, id: \.self) { i in
          Text(weekdays[i])
            .font(Pixel.micro)
            .foregroundStyle(Pixel.ink3(colorScheme))
            .frame(maxWidth: .infinity)
        }
      }
      LazyVGrid(columns: cols, spacing: 4) {
        ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
          if let day {
            dayCell(day)
          } else {
            Color.clear.frame(height: 52)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func dayCell(_ day: Int) -> some View {
    let names = byDay[day] ?? []
    let has = !names.isEmpty
    VStack(spacing: 2) {
      Text("\(day)")
        .font(Pixel.micro.weight(has ? .heavy : .regular))
        .foregroundStyle(has ? Pixel.orangeText(colorScheme) : Pixel.ink3(colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
      if has {
        Text(names.count == 1 ? firstName(names[0]) : "\(names.count) 🎂")
          .font(Pixel.micro)
          .foregroundStyle(Pixel.ink(colorScheme))
          .lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 0)
    }
    .padding(4)
    .frame(height: 52)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(has ? Pixel.yellowDim(colorScheme) : Pixel.paperDeep(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .strokeBorder(
          has ? Pixel.border(colorScheme) : Pixel.border(colorScheme).opacity(0.25),
          lineWidth: has ? 2 : 1
        )
    )
    .help(has ? names.joined(separator: ", ") : "")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(has ? "\(day): \(names.joined(separator: ", "))" : "\(day)")
  }

  private func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
  }
}

// MARK: - Pixel kit (file-private — Birthday Texts only)
//
// Birthday Texts is the ONE surface allowed to break from "calm native
// precision" into a playful, pixelated PostHog-like feel: chunky 2px borders,
// hard offset shadows that visibly depress on press, flat warm colors, mono
// type, and a little pixel-art cake. Deliberately NOT in DesignSystem/ — this
// aesthetic must not leak into the rest of the app.

private enum Pixel {
  // PostHog-ish palette: warm yellow, red-orange, deep blue on warm paper.
  static let yellow = DS.Color.hex(0xF9BD2B)
  static let yellowDeep = DS.Color.hex(0xF1A82C)
  static let orange = DS.Color.hex(0xF54E00)
  static let blue = DS.Color.hex(0x1D4AFF)

  /// Accents tuned for TEXT legibility per scheme (the raw fills stay flat).
  static func blueText(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x8EA2FF) : blue }
  static func orangeText(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xFF7A3D) : DS.Color.hex(0xD94500) }

  // Warm paper neutrals; dark mode gets its own near-black paper so the view
  // stays legible in both appearances.
  static func canvas(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x17181D) : DS.Color.hex(0xEEEFE9) }
  static func paper(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x22242C) : DS.Color.hex(0xF7F6F1) }
  static func paperDeep(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x1B1D24) : DS.Color.hex(0xFFFEFA) }
  static func ink(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xEEEFE9) : DS.Color.hex(0x151515) }
  static func ink2(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xBFC2CC) : DS.Color.hex(0x40413B) }
  static func ink3(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x8E919D) : DS.Color.hex(0x6B6C63) }
  static func border(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x4A4E5C) : DS.Color.hex(0x151515) }
  static func shadow(_ s: ColorScheme) -> Color { s == .dark ? Color.black.opacity(0.85) : DS.Color.hex(0x151515) }

  // Flat tints for chips/avatars/day-cells.
  static func yellowDim(_ s: ColorScheme) -> Color { yellow.opacity(s == .dark ? 0.24 : 0.34) }
  static func blueDim(_ s: ColorScheme) -> Color { blue.opacity(s == .dark ? 0.28 : 0.12) }
  static func orangeDim(_ s: ColorScheme) -> Color { orange.opacity(s == .dark ? 0.26 : 0.13) }

  /// Nearly-square corners: pixel-art, not rounded-rect-with-drop-shadow.
  static let radius: CGFloat = 3

  // Pixel type. Mono-as-chrome is banned app-wide ("technical vibe"); this lab
  // surface is the sanctioned exception — 8-bit flavor is the point.
  static let title = Font.system(size: 25, weight: .heavy, design: .monospaced)
  static let sectionTitle = Font.system(size: 15, weight: .bold, design: .monospaced)
  // Hero row type: the calendar tile's big day number and the "turns N" line.
  static let heroDay = Font.system(size: 21, weight: .heavy, design: .monospaced)
  static let heroTurns = Font.system(size: 16, weight: .heavy, design: .monospaced)
  static let name = Font.system(size: 13.5, weight: .bold, design: .monospaced)
  static let label = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
  static let button = Font.system(size: 11.5, weight: .bold, design: .monospaced)
  static let chip = Font.system(size: 10, weight: .bold, design: .monospaced)
  static let micro = Font.system(size: 10, weight: .semibold, design: .monospaced)
}

// MARK: Pixel card + input

private struct PixelCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  var fill: ((ColorScheme) -> Color)?
  var shadowOffset: CGFloat = 3

  func body(content: Content) -> some View {
    content
      .background(
        ZStack {
          RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
            .fill(Pixel.shadow(scheme))
            .offset(x: shadowOffset, y: shadowOffset)
          RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
            .fill(fill?(scheme) ?? Pixel.paper(scheme))
          RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
            .strokeBorder(Pixel.border(scheme), lineWidth: 2)
        }
      )
  }
}

private extension View {
  /// Thick 2px border + hard offset shadow + paper fill: the retro card.
  func pixelCard(
    fill: ((ColorScheme) -> Color)? = nil,
    shadowOffset: CGFloat = 3
  ) -> some View {
    modifier(PixelCardModifier(fill: fill, shadowOffset: shadowOffset))
  }

  /// Text input on the pixel surface — same metrics as `dsInput`, retro chrome.
  func pixelInput(_ scheme: ColorScheme, minHeight: CGFloat? = nil) -> some View {
    textFieldStyle(.plain)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(minHeight: minHeight)
      .background(
        RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
          .fill(Pixel.paperDeep(scheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
          .strokeBorder(Pixel.border(scheme), lineWidth: 2)
      )
  }

  func pixelButton(_ variant: PixelButtonVariant = .primary) -> some View {
    buttonStyle(PixelButtonStyle(variant: variant))
  }

  /// Square icon-only pixel button (month nav, refresh, the row ⋯ menu).
  func pixelIconButton(_ variant: PixelButtonVariant = .secondary) -> some View {
    buttonStyle(PixelButtonStyle(variant: variant, iconOnly: true))
  }
}

// MARK: Pixel buttons

private enum PixelButtonVariant {
  case primary    // warm yellow fill, near-black text — the chunky CTA
  case secondary  // paper fill + border + shadow
  case ghost      // text-only, subtle fill on hover, no shadow
}

private struct PixelButtonStyle: ButtonStyle {
  var variant: PixelButtonVariant = .primary
  var iconOnly = false

  func makeBody(configuration: Configuration) -> some View {
    PixelButtonBody(configuration: configuration, variant: variant, iconOnly: iconOnly)
  }
}

private struct PixelButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let variant: PixelButtonVariant
  let iconOnly: Bool

  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  private var shadowOffset: CGFloat { variant == .ghost ? 0 : 2.5 }

  var body: some View {
    // The signature move: pressing collapses the hard shadow — the face slides
    // down-right INTO the shadow's spot, like an 8-bit button depressing.
    let pressed = configuration.isPressed && isEnabled

    styledLabel
      .foregroundStyle(foreground)
      .padding(.horizontal, iconOnly ? 0 : 12)
      .padding(.vertical, iconOnly ? 0 : 6)
      .frame(width: iconOnly ? 30 : nil, height: iconOnly ? 30 : nil)
      .frame(minHeight: iconOnly ? nil : 28)
      .background(
        ZStack {
          if variant != .ghost {
            RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
              .fill(Pixel.shadow(scheme))
              .offset(x: pressed ? 0 : shadowOffset, y: pressed ? 0 : shadowOffset)
            RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
              .fill(fill)
            RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
              .strokeBorder(Pixel.border(scheme), lineWidth: 2)
          } else if hovering && isEnabled {
            RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
              .fill(Pixel.ink(scheme).opacity(0.08))
          }
        }
      )
      .offset(x: pressed ? shadowOffset : 0, y: pressed ? shadowOffset : 0)
      .contentShape(RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous))
      .opacity(isEnabled ? 1 : 0.45)
      .dsAnimation(.easeOut(duration: 0.08), value: pressed)
      .onHover { hovering = $0 }
  }

  @ViewBuilder private var styledLabel: some View {
    if iconOnly {
      configuration.label
        .font(.system(size: 13, weight: .bold))
        .lineLimit(1)
    } else {
      configuration.label
        .font(Pixel.button)
        .lineLimit(1)
        .labelStyle(PixelButtonLabelStyle())
    }
  }

  private var foreground: Color {
    switch variant {
    case .primary: return DS.Color.hex(0x151515)  // ink-on-yellow in both schemes
    case .secondary: return Pixel.ink(scheme)
    case .ghost: return hovering && isEnabled ? Pixel.ink(scheme) : Pixel.ink2(scheme)
    }
  }

  private var fill: Color {
    switch variant {
    case .primary: return hovering && isEnabled ? Pixel.yellowDeep : Pixel.yellow
    case .secondary: return hovering && isEnabled ? Pixel.paperDeep(scheme) : Pixel.paper(scheme)
    case .ghost: return .clear
    }
  }
}

/// Keeps a pixel button's leading SF Symbol sized + spaced with its mono title.
private struct PixelButtonLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: 11, weight: .bold))
      configuration.title
    }
  }
}

// MARK: Pixel chip

private struct PixelChip: View {
  enum Tone { case yellow, blue, orange, neutral }

  let text: String
  var tone: Tone = .neutral
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Text(text)
      .font(Pixel.chip)
      .foregroundStyle(foreground)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(background))
      .overlay(
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .strokeBorder(Pixel.border(scheme).opacity(0.75), lineWidth: 1.5)
      )
  }

  private var background: Color {
    switch tone {
    case .yellow: return Pixel.yellowDim(scheme)
    case .blue: return Pixel.blueDim(scheme)
    case .orange: return Pixel.orangeDim(scheme)
    case .neutral: return Pixel.paperDeep(scheme)
    }
  }

  private var foreground: Color {
    switch tone {
    case .yellow: return Pixel.ink(scheme)
    case .blue: return Pixel.blueText(scheme)
    case .orange: return Pixel.orangeText(scheme)
    case .neutral: return Pixel.ink2(scheme)
    }
  }
}

// MARK: Pixel segmented control

/// Pixel twin of `DSSegmentedControl` — same API, same accessibility contract
/// (per-segment label, "Selected" value, `.isSelected` trait), retro chrome.
private struct PixelSegmented<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  let label: (Option) -> String
  let icon: (Option) -> String?

  @Environment(\.colorScheme) private var scheme

  init(
    _ options: [Option],
    selection: Binding<Option>,
    label: @escaping (Option) -> String,
    icon: @escaping (Option) -> String? = { _ in nil }
  ) {
    self.options = options
    self._selection = selection
    self.label = label
    self.icon = icon
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.element) { index, option in
        let selected = option == selection
        Button {
          withAnimation(.easeInOut(duration: 0.12)) {
            selection = option
          }
        } label: {
          HStack(spacing: 5) {
            if let icon = icon(option) {
              Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            }
            Text(label(option))
              .lineLimit(1)
              .minimumScaleFactor(0.82)
          }
          .font(Pixel.chip)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 8)
          .padding(.vertical, 7)
          .background(Rectangle().fill(selected ? Pixel.yellow : Pixel.paper(scheme)))
          .foregroundStyle(selected ? DS.Color.hex(0x151515) : Pixel.ink3(scheme))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(option))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        if index < options.count - 1 {
          Rectangle()
            .fill(Pixel.border(scheme))
            .frame(width: 2)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
        .fill(Pixel.shadow(scheme))
        .offset(x: 2.5, y: 2.5)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous)
        .strokeBorder(Pixel.border(scheme), lineWidth: 2)
    )
  }
}

// MARK: Pixel-art cake + confetti

/// The pane mascot: an 8-bit birthday cake drawn from a character grid of small
/// `Rectangle`s — pure SwiftUI, no assets. Decorative; hidden from VoiceOver.
private struct PixelCake: View {
  var cell: CGFloat = 3
  @Environment(\.colorScheme) private var scheme

  // 12×12. Legend: "." transparent, "o" flame tip, "y" flame, "c" candle,
  // "w" icing, "d" icing drip, "k" cake, "j" jam stripe, "p" plate.
  private static let art: [String] = [
    ".....oo.....",
    ".....yy.....",
    ".....cc.....",
    ".....cc.....",
    ".wwwwwwwwww.",
    "wwwwwwwwwwww",
    "wdwwdwwdwwdw",
    "kkkkkkkkkkkk",
    "jjjjjjjjjjjj",
    "kkkkkkkkkkkk",
    "kkkkkkkkkkkk",
    ".pppppppppp.",
  ]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(Self.art.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 0) {
          ForEach(Array(row.enumerated()), id: \.offset) { _, ch in
            Rectangle()
              .fill(color(ch))
              .frame(width: cell, height: cell)
          }
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func color(_ ch: Character) -> Color {
    switch ch {
    case "o": return Pixel.orange
    case "y": return Pixel.yellow
    case "c": return Pixel.blue
    case "w": return scheme == .dark ? DS.Color.hex(0xF1EFE6) : DS.Color.hex(0xFFFDF6)
    case "d", "j": return Pixel.orange
    case "k": return Pixel.yellowDeep
    case "p": return Pixel.border(scheme)
    default: return .clear
    }
  }
}

/// The header tile: the cake on a warm pixel card.
private struct PixelCakeBadge: View {
  var body: some View {
    PixelCake(cell: 3)
      .padding(6)
      .pixelCard(fill: { Pixel.yellowDim($0) })
      .accessibilityHidden(true)
  }
}

/// Confetti underline for the pane title: a row of tiny palette squares that
/// twinkle gently out of phase. Static when Reduce Motion is on.
private struct PixelSprinkleRule: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var phase = false

  private static let pattern: [Int] = [0, 1, 2, 0, 2, 1, 0, 1, 2, 0, 1, 2, 0, 2, 1, 0]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(Self.pattern.enumerated()), id: \.offset) { index, colorIndex in
        Rectangle()
          .fill(color(colorIndex))
          .frame(width: 5, height: 5)
          .opacity(phase == (index % 2 == 0) ? 1 : 0.35)
      }
    }
    .accessibilityHidden(true)
    .onAppear {
      guard !reduceMotion, !phase else { return }
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        phase = true
      }
    }
  }

  private func color(_ index: Int) -> Color {
    [Pixel.yellow, Pixel.orange, Pixel.blue][index % 3]
  }
}

// MARK: - First-open intro (registered in ToolRegistry)

extension BirthdayToolView {
  /// Registry hook for the first-open intro sheet. The pixel kit stays
  /// file-private; only an opaque AnyView crosses the file boundary.
  static func makeIntro(_ actions: LabIntroActions) -> AnyView {
    AnyView(BirthdayIntroView(actions: actions))
  }
}

/// 8-bit landing page: a pixel calendar tile as the hero, chunky mono type,
/// and the lab's hard-shadow buttons for the CTAs.
private struct BirthdayIntroView: View {
  let actions: LabIntroActions
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack {
      Pixel.canvas(scheme)
      VStack(alignment: .leading, spacing: 0) {
        calendarTile

        Text("Never miss the people\nwho matter.")
          .font(Pixel.title)
          .foregroundStyle(Pixel.ink(scheme))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 22)
          .accessibilityLabel("Never miss the people who matter")

        VStack(alignment: .leading, spacing: 12) {
          benefit("gift.fill", "One list of the birthdays you'd actually text.")
          benefit("calendar.badge.clock", "Upcoming dates surface before the day sneaks up.")
          benefit("paperplane.fill", "Today's birthday jumps straight into that thread.")
        }
        .padding(.top, 24)

        Spacer(minLength: 16)

        Text("Your list lives on this Mac · texts only send with your approval")
          .font(Pixel.micro)
          .foregroundStyle(Pixel.ink3(scheme))

        HStack(spacing: 12) {
          Button("Not now") { actions.onCancel() }
            .pixelButton(.ghost)
            .accessibilityLabel("Not now")
          Button {
            actions.onContinue()
          } label: {
            Label("Build my list", systemImage: "birthday.cake")
          }
          .pixelButton(.primary)
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("Continue to Birthday Texts")
        }
        .padding(.top, 14)
      }
      .padding(36)
    }
  }

  /// Decorative hero: a calendar page tile in the lab's pixel-card chrome.
  private var calendarTile: some View {
    VStack(spacing: 0) {
      Text("JUN")
        .font(Pixel.chip)
        .foregroundStyle(DS.Color.hex(0x151515))
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .background(Pixel.yellow)
      Text("11")
        .font(Pixel.heroDay)
        .foregroundStyle(Pixel.ink(scheme))
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Pixel.paperDeep(scheme))
    }
    .frame(width: 74)
    .clipShape(RoundedRectangle(cornerRadius: Pixel.radius, style: .continuous))
    .pixelCard(shadowOffset: 4)
    .accessibilityHidden(true)
  }

  private func benefit(_ icon: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Pixel.orangeText(scheme))
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(text)
        .font(Pixel.label)
        .foregroundStyle(Pixel.ink2(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
