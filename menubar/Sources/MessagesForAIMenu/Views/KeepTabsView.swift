import SwiftUI
import AppKit
import Contacts

/// A small per-lab vector-arcade theme for Orbit. The Ghostie shell/sidebar
/// stays untouched; this pane intentionally forces the sparse black-canvas look
/// because the reference depends on classic vector linework.
private enum Arcade {
  static let background = DS.Color.hex(0x030405)
  static let panel = DS.Color.hex(0x070A0C)
  static let panelRaised = DS.Color.hex(0x0B1013)
  static let control = DS.Color.hex(0x0E1518)
  static let text = DS.Color.hex(0xF5F7F2)
  static let text2 = DS.Color.hex(0xC9D0CC)
  static let text3 = DS.Color.hex(0x7E8888)
  static let vector = Color.white.opacity(0.88)
  static let vectorDim = Color.white.opacity(0.34)
  static let vectorFaint = Color.white.opacity(0.15)
  static let teal = DS.Color.hex(0x5DE0CC)
  static let tealDim = DS.Color.hex(0x193B39)
  static let coral = DS.Color.hex(0xFF6B63)
  static let coralDim = DS.Color.hex(0x381818)
  static let amber = DS.Color.hex(0xF3C75F)
  static let amberDim = DS.Color.hex(0x332910)
  static let muted = DS.Color.hex(0x4E5858)
}

private enum ArcadeOrbitStatus {
  case due
  case inTouch
  case snoozed
  case candidate
  case unknown

  var color: Color {
    switch self {
    case .due: return Arcade.coral
    case .inTouch: return Arcade.teal
    case .snoozed: return Arcade.text3
    case .candidate: return Arcade.amber
    case .unknown: return Arcade.vectorDim
    }
  }

  var dashed: Bool {
    switch self {
    case .snoozed, .candidate: return true
    case .due, .inTouch, .unknown: return false
    }
  }
}

private struct ArcadeOrbitMarker: Identifiable, Equatable {
  let id: String
  let label: String
  let status: ArcadeOrbitStatus
  let shape: Int
  let seed: Double
}

/// Labs > Orbit. A list of people to stay in touch with, each at a
/// target cadence. Overdue watched people (by text OR call) are pushed into the
/// shared priority queue by KeepTabsController; this pane is where you curate
/// the list, see who's gone quiet, and add recommended contacts.
struct KeepTabsView: View {
  @EnvironmentObject private var controller: KeepTabsController
  @EnvironmentObject private var store: KeepTabsStore
  @EnvironmentObject private var nav: ConsoleNavigation
  @EnvironmentObject private var messagesViewState: MessagesViewState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var contactQuery = ""
  @State private var contactMatches: [ContactMatch] = []
  /// The search result the user picked — once set, we show their recommended
  /// cadence and the Add controls instead of the result list.
  @State private var selectedMatch: ContactMatch?
  /// The "In touch" group is collapsed by default so the overdue people lead.
  @State private var showInTouch = false
  /// How the in-touch group is ordered once expanded.
  @State private var inTouchSort: InTouchSort = .alphabetical

  enum InTouchSort: CaseIterable { case alphabetical, frequency }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        hero
          .arcadeFullDiskAccessGate(toolName: "Orbit")
        autoPrioritizeRow
        if !controller.signalsAvailable {
          signalsUnavailableBanner
        }
        watchlistSection
        recommendationsSection
        manualAddSection
        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: 940, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Arcade.background)
    .environment(\.colorScheme, .dark)
    .onAppear { controller.loadIfNeeded() }
  }

  // MARK: - hero

  private var hero: some View {
    let ranked = rankedWatchlist()
    return ArcadeOrbitHero(
      markers: heroMarkers(from: ranked),
      dueCount: ranked.attention.count,
      orbitCount: store.watchlist.count,
      recommendedCount: freshRecommendationCount,
      reduceMotion: reduceMotion,
      onRefresh: { controller.refresh() }
    )
  }

  private var autoPrioritizeRow: some View {
    Toggle(isOn: Binding(
      get: { store.autoPrioritize },
      set: { controller.setAutoPrioritize($0) }
    )) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Add overdue people to my priority queue")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(Arcade.text)
        Text("When off, Orbit still shows who's gone quiet here, but won't touch the Messages priority section.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Arcade.text3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.switch)
    .tint(Arcade.teal)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(Arcade.vectorDim, lineWidth: 1)
    }
  }

  private var signalsUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "info.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Arcade.amber)
        Text("Couldn't read your message history, so Orbit can't tell who's gone quiet. Grant Full Disk Access to enable recommendations and overdue nudges. Your orbit still saves without it.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Arcade.text2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Open Full Disk Access settings") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
          NSWorkspace.shared.open(url)
        }
      }
      .arcadeButton(.secondary, size: .small)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.amberDim.opacity(0.72)))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(Arcade.amber.opacity(0.45), lineWidth: 1)
    }
  }

  // MARK: - watchlist

  private var watchlistSection: some View {
    let ranked = rankedWatchlist()
    return VStack(alignment: .leading, spacing: 10) {
      sectionLabel("YOUR ORBIT", count: store.watchlist.count)
      if store.watchlist.isEmpty {
        emptyWatchlistCard
      } else {
        // Overdue people lead, stack-ranked by how far past their cadence.
        ForEach(ranked.attention) { entry in watchRow(entry) }
        if ranked.attention.isEmpty && !ranked.inTouch.isEmpty {
          allCaughtUpCard
        }
        // Everyone you're in touch with collapses into one expandable group.
        if !ranked.inTouch.isEmpty {
          inTouchDisclosure(ranked.inTouch)
        }
      }
    }
  }

  /// Watched people split into overdue (needs a nudge) and in-touch, each sorted
  /// by how overdue the catch-up is — days past their cadence deadline, most
  /// overdue first. This is cadence-aware (a weekly friend 3 weeks quiet outranks
  /// a yearly one 3 weeks quiet) yet tracks the visible "N weeks" pills. Never
  /// contacted = most overdue; snoozed people read as in-touch (negative = early).
  private func rankedWatchlist() -> (attention: [KeepTabsEntry], inTouch: [KeepTabsEntry]) {
    func daysPastDue(_ entry: KeepTabsEntry) -> Double {
      guard let days = controller.overdue[entry.canonicalKey]?.lastContactedDays else { return .infinity }
      return Double(days - entry.targetFrequencyDays)
    }
    var attention: [KeepTabsEntry] = []
    var inTouch: [KeepTabsEntry] = []
    for entry in store.watchlist {
      if controller.overdue[entry.canonicalKey]?.isOverdue == true {
        attention.append(entry)
      } else {
        inTouch.append(entry)
      }
    }
    attention.sort { daysPastDue($0) > daysPastDue($1) }
    inTouch.sort { daysPastDue($0) > daysPastDue($1) }
    return (attention, inTouch)
  }

  private func watchRow(_ entry: KeepTabsEntry) -> some View {
    KeepTabsWatchlistRow(
      entry: entry,
      info: controller.overdue[entry.canonicalKey],
      snoozed: entry.snoozedUntil.flatMap(KeepTabsStore.parseISO).map { $0 > Date() } ?? false,
      onSetFrequency: { controller.setFrequency(entry, days: $0) },
      onOpen: { openConversation(entry) },
      onSnooze: { controller.snooze(entry, until: Date().addingTimeInterval(7 * 86_400)) },
      onUnsnooze: { controller.clearSnooze(entry) },
      onRemove: { controller.unwatch(entry) }
    )
  }

  private var allCaughtUpCard: some View {
    HStack(spacing: 8) {
      ArcadeStatusGlyph(status: .inTouch, shape: 2)
      Text("You're all caught up. Everyone's within their cadence.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Arcade.text2)
    }
    .padding(.vertical, 6)
  }

  private func inTouchDisclosure(_ entries: [KeepTabsEntry]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) { showInTouch.toggle() }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Arcade.text3)
            .rotationEffect(.degrees(showInTouch ? 90 : 0))
          Text("In touch")
            .font(DS.Font.settingsLabel)
            .foregroundStyle(Arcade.text2)
          Text("\(entries.count)")
            .font(DS.Font.chip)
            .monospacedDigit()
            .foregroundStyle(Arcade.text3)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Arcade.control))
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(showInTouch ? "Hide the people you're in touch with" : "Show the people you're in touch with")

      if showInTouch {
        HStack(spacing: 6) {
          Text("SORT")
            .font(DS.Font.monoMicro)
            .foregroundStyle(Arcade.text3)
          sortChip("A–Z", .alphabetical)
          sortChip("Frequency", .frequency)
          Spacer()
        }
        .padding(.leading, 2)
        ForEach(sortedInTouch(entries)) { entry in watchRow(entry) }
      }
    }
  }

  private func sortChip(_ title: String, _ mode: InTouchSort) -> some View {
    let selected = inTouchSort == mode
    return Button {
      withAnimation(.easeInOut(duration: 0.14)) { inTouchSort = mode }
    } label: {
      Text(title)
        .font(DS.Font.chip)
        .foregroundStyle(selected ? Arcade.background : Arcade.text2)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(selected ? Arcade.teal : Arcade.control))
    }
    .buttonStyle(.plain)
    .help(mode == .alphabetical ? "Sort A–Z by name" : "Sort by how often you reach out")
  }

  /// In-touch ordering: name A–Z, or by cadence (most frequent first). Both fall
  /// back to name so the order is stable.
  private func sortedInTouch(_ entries: [KeepTabsEntry]) -> [KeepTabsEntry] {
    switch inTouchSort {
    case .alphabetical:
      return entries.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    case .frequency:
      return entries.sorted {
        if $0.targetFrequencyDays != $1.targetFrequencyDays {
          return $0.targetFrequencyDays < $1.targetFrequencyDays
        }
        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
    }
  }

  private var emptyWatchlistCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No one in your orbit yet.")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(Arcade.text)
      Text("Add someone from the recommendations below, or search your Contacts.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Arcade.text3)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(Arcade.vectorDim, lineWidth: 1)
    }
  }

  // MARK: - recommendations

  @ViewBuilder
  private var recommendationsSection: some View {
    switch controller.recommendState {
    case .idle, .loading:
      VStack(alignment: .leading, spacing: 10) {
        sectionLabel("RECOMMENDED TO ADD", count: nil)
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
            .tint(Arcade.teal)
          Text("Finding people you text and call the most…")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(Arcade.text3)
        }
        .padding(14)
      }
    case .failed(let reason):
      // Don't surface the bundling/decoding error as a scary banner when the real
      // cause is usually no Full Disk Access (already covered by the banner above).
      if controller.signalsAvailable {
        VStack(alignment: .leading, spacing: 10) {
          sectionLabel("RECOMMENDED TO ADD", count: nil)
          Text(reason)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(Arcade.text3)
        }
      }
    case .loaded(let result):
      let fresh = result.recommendations.filter { rec in
        guard let handle = rec.bestHandle, let canon = KeepTabsStore.canon(for: handle) else { return false }
        return !store.isWatched(canon: canon) && !store.isDismissed(canon: canon)
      }
      if !fresh.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          sectionLabel("RECOMMENDED TO ADD", count: fresh.count)
          ForEach(fresh) { rec in
            KeepTabsRecommendationRow(
              rec: rec,
              onAdd: { controller.add(recommendation: rec, frequencyDays: $0) },
              onDismiss: { controller.dismissRecommendation(rec) }
            )
          }
        }
      }
    }
  }

  // MARK: - manual add (Contacts search)

  private var manualAddSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionLabel("ADD SOMEONE BY NAME", count: nil)
      ArcadeContactsPermissionBanner()
      if let match = selectedMatch {
        manualSelectedPanel(match)
      } else {
        TextField("Search Contacts by name", text: $contactQuery)
          .textFieldStyle(.plain)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(Arcade.text)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Arcade.control))
          .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
              .strokeBorder(Arcade.vectorDim, lineWidth: 1)
          }
          .frame(maxWidth: 320)
          .task(id: contactQuery) {
            let q = contactQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 2 else { contactMatches = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let results = await Task.detached { ContactsExporter.searchContacts(q, limit: 8) }.value
            if Task.isCancelled { return }
            contactMatches = results
          }
        ForEach(contactMatches) { match in
          manualMatchRow(match)
        }
        if contactQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 && contactMatches.isEmpty {
          Text("No matching contacts.")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(Arcade.text3)
        }
      }
    }
  }

  /// A search result, tappable to select. Selecting kicks off a cadence lookup so
  /// the Add panel can default to this person's real text+call rhythm.
  @ViewBuilder
  private func manualMatchRow(_ match: ContactMatch) -> some View {
    let alreadyWatched = KeepTabsStore.canon(for: match.bestHandle ?? "").map { store.isWatched(canon: $0) } ?? false
    Button {
      controller.loadCadence(for: match)
      withAnimation(.easeInOut(duration: 0.18)) { selectedMatch = match }
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(match.name)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(Arcade.text)
          if let handle = match.bestHandle {
            Text(handle)
              .font(DS.Font.settingsCaption)
              .foregroundStyle(Arcade.text3)
          } else {
            Text("No phone or email on this contact")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(Arcade.text3)
          }
        }
        Spacer()
        if alreadyWatched {
          Text("On your list")
            .font(DS.Font.chip)
            .foregroundStyle(Arcade.text3)
        } else {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Arcade.text3)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
      .overlay {
        RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
          .strokeBorder(Arcade.vectorDim, lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(match.bestHandle == nil || alreadyWatched)
  }

  /// The selected contact: their recommended cadence (once read from history) and
  /// the Add controls, with a Back affordance to return to the result list.
  @ViewBuilder
  private func manualSelectedPanel(_ match: ContactMatch) -> some View {
    let resolving = controller.manualCadenceLoading.contains(match.id) && controller.manualCadence[match.id] == nil
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) { selectedMatch = nil }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
          Text("Back to results")
        }
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Arcade.text3)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      VStack(alignment: .leading, spacing: 2) {
        Text(match.name)
          .font(DS.Font.rowTitle)
          .foregroundStyle(Arcade.text)
        if let handle = match.bestHandle {
          Text(handle)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(Arcade.text3)
        }
      }

      if resolving {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
            .tint(Arcade.teal)
          Text("Reading your history with \(match.name)…")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(Arcade.text3)
        }
      } else {
        // Mounts only after the cadence resolves, so the picker's initial value
        // reflects the suggestion (a SwiftUI @State default is set once, on first
        // appearance — gating here avoids it locking in before the value lands).
        let row = controller.manualCadence[match.id]
        KeepTabsManualAddControls(match: match, suggestedDays: row?.suggestedFrequencyDays, lastContactedDays: row?.lastContactedDays) { days in
          if controller.add(match: match, frequencyDays: days) {
            withAnimation(.easeInOut(duration: 0.22)) {
              selectedMatch = nil
              contactQuery = ""
              contactMatches = []
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(Arcade.vectorDim, lineWidth: 1)
    }
  }

  // MARK: - helpers

  private func sectionLabel(_ text: String, count: Int?) -> some View {
    ArcadeSectionLabel(text: text, count: count)
  }

  private func openConversation(_ entry: KeepTabsEntry) {
    messagesViewState.pendingConversationHandles = [entry.handle]
    nav.selection = .messages
  }

  private var freshRecommendationCount: Int {
    guard case .loaded(let result) = controller.recommendState else { return 0 }
    return freshRecommendations(from: result).count
  }

  private func freshRecommendations(from result: KeepTabsRecommendResult) -> [KeepTabsRecommendation] {
    result.recommendations.filter { rec in
      guard let handle = rec.bestHandle, let canon = KeepTabsStore.canon(for: handle) else { return false }
      return !store.isWatched(canon: canon) && !store.isDismissed(canon: canon)
    }
  }

  private func heroMarkers(from ranked: (attention: [KeepTabsEntry], inTouch: [KeepTabsEntry])) -> [ArcadeOrbitMarker] {
    // Everyone in the watchlist gets a node, overdue first. Nodes are small and
    // label-less by default (see ArcadeOrbitMarkerView) so a dense orbit stays
    // legible; the label is revealed on hover. position() spreads them evenly
    // across the rings regardless of count.
    let entries = ranked.attention + ranked.inTouch
    if !entries.isEmpty {
      return entries.enumerated().map { index, entry in
        ArcadeOrbitMarker(
          id: entry.canonicalKey,
          label: arcadeLabel(entry.displayName),
          status: arcadeStatus(for: entry),
          shape: index,
          seed: Double(index) * 0.71
        )
      }
    }

    if case .loaded(let result) = controller.recommendState {
      let recs = Array(freshRecommendations(from: result).prefix(6))
      if !recs.isEmpty {
        return recs.enumerated().map { index, rec in
          ArcadeOrbitMarker(
            id: rec.id,
            label: arcadeLabel(rec.name),
            status: .candidate,
            shape: index + 2,
            seed: Double(index) * 0.83
          )
        }
      }
    }

    return [
      ArcadeOrbitMarker(id: "add-signal", label: "ADD", status: .candidate, shape: 0, seed: 0.1),
      ArcadeOrbitMarker(id: "set-cadence", label: "SET", status: .unknown, shape: 3, seed: 1.1),
      ArcadeOrbitMarker(id: "orbit", label: "ORBIT", status: .unknown, shape: 5, seed: 2.1),
    ]
  }

  private func arcadeStatus(for entry: KeepTabsEntry) -> ArcadeOrbitStatus {
    if entry.snoozedUntil.flatMap(KeepTabsStore.parseISO).map({ $0 > Date() }) ?? false {
      return .snoozed
    }
    if controller.overdue[entry.canonicalKey]?.isOverdue == true {
      return .due
    }
    return .inTouch
  }

  private func arcadeLabel(_ name: String) -> String {
    let token = name
      .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "-" })
      .first
      .map(String.init) ?? name
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    return String((trimmed.isEmpty ? "SIGNAL" : trimmed).prefix(8)).uppercased()
  }
}

// MARK: - watchlist row

/// A compact watched-person row: name, a clear "Texted/Called N ago" line, and a
/// green/yellow/red status pill. Hovering reveals the controls (cadence, snooze,
/// remove); clicking the row opens the conversation. A right-click menu mirrors
/// the controls for discoverability + keyboard/VoiceOver users.
private struct KeepTabsWatchlistRow: View {
  let entry: KeepTabsEntry
  let info: KeepTabsOverdueInfo?
  let snoozed: Bool
  let onSetFrequency: (Int) -> Void
  let onOpen: () -> Void
  let onSnooze: () -> Void
  let onUnsnooze: () -> Void
  let onRemove: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 12) {
      ArcadeStatusGlyph(status: visualStatus, shape: abs(entry.canonicalKey.hashValue) % 6)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.displayName)
          .font(DS.Font.rowTitle)
          .foregroundStyle(Arcade.text)
          .lineLimit(1)
        Text(lastTouchLabel)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Arcade.text3)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      // At rest: status. On hover: the action cluster (keeps the row compact).
      if isHovering {
        hoverControls
      } else {
        statusPill
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(signalColor.opacity(visualStatus == .due ? 0.85 : 0.42), lineWidth: visualStatus == .due ? 1.25 : 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
    .onTapGesture { onOpen() }
    .onHover { hovering in withAnimation(.easeInOut(duration: 0.14)) { isHovering = hovering } }
    .help("Open conversation with \(entry.displayName)")
    .contextMenu {
      Button("Open conversation") { onOpen() }
      Menu("Cadence") {
        ForEach(KeepTabsFrequency.allCases) { freq in
          Button(freq.title) { onSetFrequency(freq.rawValue) }
        }
      }
      if snoozed {
        Button("Unsnooze") { withAnimation(.easeInOut(duration: 0.22)) { onUnsnooze() } }
      } else if info?.isOverdue == true {
        Button("Snooze 1 week") { withAnimation(.easeInOut(duration: 0.22)) { onSnooze() } }
      }
      Divider()
      Button("Remove from orbit", role: .destructive) {
        withAnimation(.easeInOut(duration: 0.22)) { onRemove() }
      }
    }
  }

  private var lastTouchLabel: String {
    switch KeepTabsOverdue.lastContactChannel(textDays: info?.lastTextedDays, callDays: info?.lastCallDays) {
    case .text(let days): return "Texted \(KeepTabsOverdue.terseAgo(days))"
    case .call(let days): return "Called \(KeepTabsOverdue.terseAgo(days))"
    case .none: return "No texts or calls yet"
    }
  }

  @ViewBuilder
  private var statusPill: some View {
    if snoozed {
      pill("Snoozed", Arcade.text3)
    } else if let info {
      let quiet = KeepTabsOverdue.quietLabel(lastContactedDays: info.lastContactedDays)
      let isOnTrack = KeepTabsOverdue.severity(lastContactedDays: info.lastContactedDays, targetFrequencyDays: entry.targetFrequencyDays) == .onTrack
      pill(isOnTrack ? "In touch" : "Overdue · \(quiet)", signalColor)
    }
  }

  private var visualStatus: ArcadeOrbitStatus {
    if snoozed { return .snoozed }
    guard let info else { return .unknown }
    switch KeepTabsOverdue.severity(lastContactedDays: info.lastContactedDays, targetFrequencyDays: entry.targetFrequencyDays) {
    case .onTrack: return .inTouch
    case .overdue, .veryOverdue: return .due
    }
  }

  private var signalColor: Color {
    if snoozed { return Arcade.text3 }
    guard let info else { return Arcade.vectorDim }
    switch KeepTabsOverdue.severity(lastContactedDays: info.lastContactedDays, targetFrequencyDays: entry.targetFrequencyDays) {
    case .onTrack: return Arcade.teal
    case .overdue, .veryOverdue: return Arcade.coral
    }
  }

  private func pill(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(DS.Font.chip)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(color.opacity(0.12)))
      .overlay {
        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
          .strokeBorder(color.opacity(0.55), lineWidth: 1)
      }
      .foregroundStyle(color)
  }

  private var hoverControls: some View {
    HStack(spacing: 6) {
      Menu {
        ForEach(KeepTabsFrequency.allCases) { freq in
          Button(freq.title) { onSetFrequency(freq.rawValue) }
        }
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold))
          Text(KeepTabsFrequency.nearest(toDays: entry.targetFrequencyDays).shortTitle).font(DS.Font.chip)
        }
        .foregroundStyle(Arcade.text2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(Arcade.control))
        .overlay {
          RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(Arcade.vectorDim, lineWidth: 1)
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Change cadence")

      if snoozed {
        iconButton("bell.slash", "Unsnooze") { withAnimation(.easeInOut(duration: 0.22)) { onUnsnooze() } }
      } else if info?.isOverdue == true {
        iconButton("bell.badge", "Snooze 1 week") { withAnimation(.easeInOut(duration: 0.22)) { onSnooze() } }
      }
      iconButton("minus.circle", "Remove \(entry.displayName) from Orbit") {
        withAnimation(.easeInOut(duration: 0.22)) { onRemove() }
      }
    }
    .transition(.opacity)
  }

  private func iconButton(_ systemImage: String, _ help: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Arcade.text2)
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

// MARK: - recommendation row

/// One "recommended to add" row: name + why, a frequency dropdown (seeded from
/// the engine's median-cadence suggestion, the user can change it), a separate
/// Add button, and a dismiss (×) that suppresses the person forever.
private struct KeepTabsRecommendationRow: View {
  let rec: KeepTabsRecommendation
  let onAdd: (Int) -> Void
  let onDismiss: () -> Void
  @State private var frequency: KeepTabsFrequency

  init(rec: KeepTabsRecommendation, onAdd: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
    self.rec = rec
    self.onAdd = onAdd
    self.onDismiss = onDismiss
    _frequency = State(initialValue: KeepTabsFrequency.nearest(toDays: rec.suggestedFrequencyDays))
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text(rec.name)
          .font(DS.Font.rowTitle)
          .foregroundStyle(Arcade.text)
        Text(rec.why)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Arcade.text3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Picker("", selection: $frequency) {
        ForEach(KeepTabsFrequency.allCases) { freq in
          Text(freq.title).tag(freq)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .frame(width: 144)
      Button("Add") { withAnimation(.easeInOut(duration: 0.22)) { onAdd(frequency.rawValue) } }
        .arcadeButton(.primary, size: .small)
        .disabled(rec.bestHandle == nil)
      Button("Dismiss") { withAnimation(.easeInOut(duration: 0.22)) { onDismiss() } }
        .arcadeButton(.secondary, size: .small)
        .help("Do not add \(rec.name) to Orbit")
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(Arcade.vectorDim, lineWidth: 1)
    }
  }
}

// MARK: - manual-add controls (cadence + frequency picker + Add)

/// Shown once a searched contact's cadence has resolved. Defaults the frequency
/// picker to the recency-tempered suggested cadence (the user can change it), and
/// states the relationship honestly — their rhythm if you're in touch, or how long
/// it's actually been if you've gone quiet — instead of claiming a present cadence
/// the silence contradicts.
private struct KeepTabsManualAddControls: View {
  let match: ContactMatch
  let suggestedDays: Int?
  let lastContactedDays: Int?
  let onAdd: (Int) -> Void
  @State private var frequency: KeepTabsFrequency

  init(match: ContactMatch, suggestedDays: Int?, lastContactedDays: Int?, onAdd: @escaping (Int) -> Void) {
    self.match = match
    self.suggestedDays = suggestedDays
    self.lastContactedDays = lastContactedDays
    self.onAdd = onAdd
    _frequency = State(initialValue: suggestedDays.map { KeepTabsFrequency.nearest(toDays: $0) } ?? .weekly)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(contextLine)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Arcade.text2)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Picker("", selection: $frequency) {
          ForEach(KeepTabsFrequency.allCases) { freq in
            Text(freq.title).tag(freq)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 144)
        Button("Add") { onAdd(frequency.rawValue) }
          .arcadeButton(.primary, size: .small)
          .disabled(match.bestHandle == nil)
      }
    }
  }

  /// Honest one-liner: their rhythm if you're within it, otherwise how long it's
  /// actually been. The picker is already pre-defaulted to the suggested cadence.
  private var contextLine: String {
    guard let n = suggestedDays else {
      return "Not enough history to suggest a cadence. Pick one below."
    }
    guard let l = lastContactedDays else {
      return "No texts or calls on record. Pick a cadence below."
    }
    if l <= n {
      return "You're usually in touch about every \(n) day\(n == 1 ? "" : "s")."
    }
    return "Last in touch \(Self.humanizedAgo(l)). Pick a cadence to stay in touch."
  }

  static func humanizedAgo(_ days: Int) -> String {
    if days <= 1 { return "yesterday" }
    if days < 14 { return "\(days) days ago" }
    if days < 60 { return "about \(Int((Double(days) / 7).rounded())) weeks ago" }
    if days < 365 { return "about \(Int((Double(days) / 30).rounded())) months ago" }
    let years = Double(days) / 365
    return years < 1.5 ? "about a year ago" : "about \(Int(years.rounded())) years ago"
  }
}

// MARK: - Arcade components

private struct ArcadeOrbitHero: View {
  let markers: [ArcadeOrbitMarker]
  let dueCount: Int
  let orbitCount: Int
  let recommendedCount: Int
  let reduceMotion: Bool
  let onRefresh: () -> Void
  @StateObject private var game = ArcadeAsteroidsModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Text("ORBIT")
            .font(.system(size: 34, weight: .semibold, design: .monospaced))
            .tracking(2.5)
            .foregroundStyle(Arcade.vector)
          Text("Follow up on the cadence you choose.")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(Arcade.text3)
        }
        Spacer(minLength: 12)
        HStack(spacing: 10) {
          score("DUE", dueCount, color: dueCount > 0 ? Arcade.coral : Arcade.teal)
          score("IN ORBIT", orbitCount, color: Arcade.teal)
          score("RECOMMENDED", recommendedCount, color: Arcade.amber)
        }
        Button {
          onRefresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .arcadeButton(.secondary, size: .small)
        .help("Rescan for who's gone quiet")
      }

      GeometryReader { geometry in
        ZStack {
          ArcadeOrbitField(game: game, markerCount: markers.count)
          ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
            ArcadeOrbitMarkerView(marker: marker, pulsePhase: game.clock + marker.seed)
              .position(game.friendPosition(at: index, total: markers.count, in: geometry.size))
          }
        }
        .onAppear {
          game.reduceMotion = reduceMotion
          game.setFriends(markers)
          game.start(size: geometry.size)
        }
        .onChange(of: geometry.size) { _, newSize in game.resize(newSize) }
        .onChange(of: markers) { _, newMarkers in game.setFriends(newMarkers) }
        .onChange(of: reduceMotion) { _, newValue in game.reduceMotion = newValue }
        .onDisappear { game.stop() }
      }
      .frame(height: 286)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Arcade.vectorDim, lineWidth: 1)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Arcade.panelRaised)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Arcade.vectorDim, lineWidth: 1)
    }
  }

  private func score(_ label: String, _ value: Int, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(value)")
        .font(.system(size: 18, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(color)
      Text(label)
        .font(DS.Font.monoMicro)
        .foregroundStyle(Arcade.text3)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Arcade.control))
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(color.opacity(0.42), lineWidth: 1)
    }
  }

}

/// The little ship + asteroids in the Orbit field are a hidden, consequence-free
/// game. By default the ship sits dead-center and the asteroids drift (the
/// ambient arcade look). Click the field to take control: ←/→ steer, ↑ thrusts,
/// Space fires. A shot that hits an asteroid just respawns it from an edge —
/// no score, no lives, no game over. Pure easter egg.
@MainActor
private final class ArcadeAsteroidsModel: ObservableObject {
  struct Rock: Identifiable, Equatable {
    let id = UUID()
    var pos: CGPoint
    var vel: CGVector
    var radius: CGFloat
    var seed: Int
    var rotation: Double
    var spin: Double
  }
  struct Shot: Identifiable, Equatable {
    let id = UUID()
    var pos: CGPoint
    var vel: CGVector
    var life: Double
  }
  /// A short-lived line fragment thrown off when an asteroid is hit — the
  /// vector-arcade "explosion".
  struct Particle: Identifiable, Equatable {
    let id = UUID()
    var pos: CGPoint
    var vel: CGVector
    var life: Double
    let maxLife: Double
  }
  /// A floating "+1" / "-1" that rises and fades where a point was scored or lost.
  struct ScorePop: Identifiable, Equatable {
    let id = UUID()
    var pos: CGPoint
    let text: String
    let positive: Bool
    var life: Double
    let maxLife: Double
  }
  enum Control { case left, right, thrust }

  @Published var shipPos: CGPoint = .zero
  @Published var shipAngle: Double = -.pi / 2 // pointing up
  @Published var thrusting = false
  @Published var invulnerable = false
  @Published var rocks: [Rock] = []
  @Published var shots: [Shot] = []
  @Published var debris: [Particle] = []
  @Published var pops: [ScorePop] = []
  @Published var clock: TimeInterval = 0
  @Published private(set) var score = 0
  @Published private(set) var highScore = 0

  /// Friend nodes share the game's clock so bullets can actually collide with
  /// them: the view renders them (ArcadeOrbitMarkerView) and the model collides
  /// against them using the same `friendPosition` formula.
  private(set) var friends: [ArcadeOrbitMarker] = []
  var reduceMotion = false

  private var shipVel = CGVector.zero
  private var held: Set<Control> = []
  private var size = CGSize(width: 360, height: 286)
  private var timer: Timer?
  private var spawnClock: TimeInterval = 0
  private var invulnUntil: TimeInterval = 0
  private var targetRocks = 4
  private var speedScale: CGFloat = 1.0

  private let highScoreKey = "orbit.asteroids.highScore"
  private let scoreKey = "orbit.asteroids.score"

  init() {
    highScore = UserDefaults.standard.integer(forKey: highScoreKey)
    score = UserDefaults.standard.integer(forKey: scoreKey)
  }

  func setFriends(_ f: [ArcadeOrbitMarker]) { friends = f }

  func start(size: CGSize) {
    if size.width > 0, size.height > 0 { self.size = size }
    if shipPos == .zero { centerShip() }
    refillRocks()
    guard timer == nil else { return }
    let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func resize(_ newSize: CGSize) {
    guard newSize.width > 0, newSize.height > 0 else { return }
    size = newSize
    // Re-center only while idle (never yanked the ship out from under the player).
    if shipVel == .zero, held.isEmpty { centerShip() }
  }

  func centerShip() {
    shipPos = CGPoint(x: size.width / 2, y: size.height / 2)
    shipVel = .zero
    shipAngle = -.pi / 2
  }

  func press(_ c: Control) { held.insert(c) }
  func release(_ c: Control) { held.remove(c) }

  func fire() {
    let tip = CGPoint(x: shipPos.x + cos(shipAngle) * 16, y: shipPos.y + sin(shipAngle) * 16)
    let speed: CGFloat = 360
    shots.append(Shot(pos: tip, vel: CGVector(dx: CGFloat(cos(shipAngle)) * speed, dy: CGFloat(sin(shipAngle)) * speed), life: 0.9))
    if shots.count > 24 { shots.removeFirst(shots.count - 24) }
  }

  /// Position of a friend node on its orbit ring at the current clock. Shared by
  /// the renderer and the bullet-collision check so they always agree.
  func friendPosition(at index: Int, total: Int, in size: CGSize) -> CGPoint {
    let center = CGPoint(x: size.width * 0.47, y: size.height * 0.51)
    let orbits: [(rx: CGFloat, ry: CGFloat, speed: Double)] = [
      (size.width * 0.24, size.height * 0.28, 0.18),
      (size.width * 0.33, size.height * 0.36, -0.13),
      (size.width * 0.42, size.height * 0.43, 0.10),
    ]
    let ringCount = orbits.count
    let ring = index % ringCount
    let orbit = orbits[ring]
    let onThisRing = max(1, (total - ring + ringCount - 1) / ringCount)
    let slot = index / ringCount
    let evenAngle = (Double(slot) / Double(onThisRing)) * 2 * .pi
    let seed = friends.indices.contains(index) ? friends[index].seed : 0
    let spin = reduceMotion ? 0 : clock * orbit.speed
    let angle = evenAngle + spin + seed * 0.12
    return CGPoint(x: center.x + orbit.rx * CGFloat(cos(angle)), y: center.y + orbit.ry * CGFloat(sin(angle)))
  }

  private func refillRocks() {
    while rocks.count < targetRocks { rocks.append(spawnRock(fromEdge: !rocks.isEmpty)) }
  }

  private func spawnRock(fromEdge: Bool, radius: CGFloat? = nil, at origin: CGPoint? = nil) -> Rock {
    let r = radius ?? CGFloat.random(in: 16...28)
    let pos: CGPoint
    if let origin {
      pos = origin
    } else if fromEdge {
      if Bool.random() {
        pos = CGPoint(x: Bool.random() ? -r : size.width + r, y: .random(in: 0...max(1, size.height)))
      } else {
        pos = CGPoint(x: .random(in: 0...max(1, size.width)), y: Bool.random() ? -r : size.height + r)
      }
    } else {
      pos = CGPoint(x: .random(in: 0...max(1, size.width)), y: .random(in: 0...max(1, size.height)))
    }
    let speed = CGFloat.random(in: 16...44) * speedScale
    let dir = Double.random(in: 0..<(2 * .pi))
    return Rock(
      pos: pos,
      vel: CGVector(dx: CGFloat(cos(dir)) * speed, dy: CGFloat(sin(dir)) * speed),
      radius: r,
      seed: Int.random(in: 0...6),
      rotation: .random(in: 0..<(2 * .pi)),
      spin: .random(in: -0.9...0.9)
    )
  }

  private func step() {
    let dt = 1.0 / 60.0
    clock += dt

    // Difficulty ramp: every ~10s add an asteroid (to a cap) and speed everything up.
    spawnClock += dt
    if spawnClock >= 10 {
      spawnClock = 0
      targetRocks = min(targetRocks + 1, 16)
      speedScale = min(speedScale + 0.12, 2.6)
    }

    // ship
    if held.contains(.left) { shipAngle -= 3.4 * dt }
    if held.contains(.right) { shipAngle += 3.4 * dt }
    thrusting = held.contains(.thrust)
    if thrusting {
      shipVel.dx += CGFloat(cos(shipAngle)) * 320 * dt
      shipVel.dy += CGFloat(sin(shipAngle)) * 320 * dt
    }
    shipVel.dx *= 0.99
    shipVel.dy *= 0.99
    let maxV: CGFloat = 260
    let v = (shipVel.dx * shipVel.dx + shipVel.dy * shipVel.dy).squareRoot()
    if v > maxV { shipVel.dx *= maxV / v; shipVel.dy *= maxV / v }
    shipPos.x += shipVel.dx * dt
    shipPos.y += shipVel.dy * dt
    wrap(&shipPos)
    invulnerable = clock < invulnUntil

    // rocks
    for i in rocks.indices {
      rocks[i].pos.x += rocks[i].vel.dx * dt
      rocks[i].pos.y += rocks[i].vel.dy * dt
      rocks[i].rotation += rocks[i].spin * dt
      wrap(&rocks[i].pos)
    }

    // shots
    for i in shots.indices {
      shots[i].pos.x += shots[i].vel.dx * dt
      shots[i].pos.y += shots[i].vel.dy * dt
      shots[i].life -= dt
    }
    shots.removeAll { $0.life <= 0 }

    // explosion fragments
    for i in debris.indices {
      debris[i].pos.x += debris[i].vel.dx * dt
      debris[i].pos.y += debris[i].vel.dy * dt
      debris[i].vel.dx *= 0.95
      debris[i].vel.dy *= 0.95
      debris[i].life -= dt
    }
    debris.removeAll { $0.life <= 0 }

    // score popups rise and fade
    for i in pops.indices {
      pops[i].pos.y -= 26 * dt
      pops[i].life -= dt
    }
    pops.removeAll { $0.life <= 0 }

    // ship vs rock → you die: a burst at the wreck, the score resets to zero
    // (the high score stands), and you respawn dead-center with a brief grace
    // period so you don't instantly die again on the same rock.
    if !invulnerable {
      for rock in rocks {
        let dx = shipPos.x - rock.pos.x
        let dy = shipPos.y - rock.pos.y
        if (dx * dx + dy * dy).squareRoot() < rock.radius + 8 {
          explode(at: shipPos, radius: 22)
          if score != 0 {
            score = 0
            UserDefaults.standard.set(0, forKey: scoreKey)
          }
          centerShip()
          invulnUntil = clock + 1.6
          break
        }
      }
    }

    resolveShots()
    refillRocks()
  }

  /// Bullets shatter asteroids (+1) and ding you for tagging a friend node (-1).
  private func resolveShots() {
    guard !shots.isEmpty else { return }
    var deadShots = Set<UUID>()
    var shatterRockIDs: [UUID] = []
    let total = friends.count

    for shot in shots {
      var consumed = false
      for rock in rocks {
        let dx = shot.pos.x - rock.pos.x
        let dy = shot.pos.y - rock.pos.y
        if (dx * dx + dy * dy).squareRoot() < rock.radius {
          shatterRockIDs.append(rock.id)
          deadShots.insert(shot.id)
          consumed = true
          break
        }
      }
      if consumed { continue }
      for index in friends.indices {
        let fp = friendPosition(at: index, total: total, in: size)
        let dx = shot.pos.x - fp.x
        let dy = shot.pos.y - fp.y
        if (dx * dx + dy * dy).squareRoot() < 11 {
          deadShots.insert(shot.id)
          adjustScore(-1, at: fp)
          break
        }
      }
    }

    if !deadShots.isEmpty { shots.removeAll { deadShots.contains($0.id) } }
    for rid in shatterRockIDs {
      guard let idx = rocks.firstIndex(where: { $0.id == rid }) else { continue }
      shatter(at: idx)
    }
  }

  /// Big rocks break into two smaller, faster ones; small ones are destroyed.
  /// The refill spawner brings the field back to target over time.
  private func shatter(at index: Int) {
    let rock = rocks[index]
    adjustScore(1, at: rock.pos)
    explode(at: rock.pos, radius: rock.radius)
    rocks.remove(at: index)
    if rock.radius > 13 {
      for _ in 0..<2 {
        rocks.append(spawnRock(fromEdge: false, radius: rock.radius * 0.58, at: rock.pos))
      }
    }
    if rocks.count > 30 { rocks.removeFirst(rocks.count - 30) }
  }

  private func adjustScore(_ delta: Int, at point: CGPoint) {
    score += delta
    UserDefaults.standard.set(score, forKey: scoreKey)
    if score > highScore {
      highScore = score
      UserDefaults.standard.set(highScore, forKey: highScoreKey)
    }
    pops.append(ScorePop(
      pos: point,
      text: delta > 0 ? "+\(delta)" : "\(delta)",
      positive: delta > 0,
      life: 0.75,
      maxLife: 0.75
    ))
    if pops.count > 16 { pops.removeFirst(pops.count - 16) }
  }

  private func explode(at point: CGPoint, radius: CGFloat) {
    let count = Int.random(in: 8...13)
    for _ in 0..<count {
      let dir = Double.random(in: 0..<(2 * .pi))
      let speed = CGFloat.random(in: 50...150) * (radius > 18 ? 1.2 : 1.0)
      let life = Double.random(in: 0.3...0.6)
      debris.append(Particle(
        pos: point,
        vel: CGVector(dx: CGFloat(cos(dir)) * speed, dy: CGFloat(sin(dir)) * speed),
        life: life,
        maxLife: life
      ))
    }
    if debris.count > 220 { debris.removeFirst(debris.count - 220) }
  }

  private func wrap(_ p: inout CGPoint) {
    if p.x < 0 { p.x += size.width } else if p.x > size.width { p.x -= size.width }
    if p.y < 0 { p.y += size.height } else if p.y > size.height { p.y -= size.height }
  }
}

private struct ArcadeOrbitField: View {
  @ObservedObject var game: ArcadeAsteroidsModel
  let markerCount: Int
  @FocusState private var focused: Bool
  /// Brief flash of the SCORE readout when it changes (teal up, coral down).
  @State private var scoreFlash = false
  @State private var scoreWentUp = true

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width * 0.47, y: size.height * 0.51)
      let orbitRects = [
        CGRect(x: center.x - size.width * 0.24, y: center.y - size.height * 0.28, width: size.width * 0.48, height: size.height * 0.56),
        CGRect(x: center.x - size.width * 0.33, y: center.y - size.height * 0.36, width: size.width * 0.66, height: size.height * 0.72),
        CGRect(x: center.x - size.width * 0.42, y: center.y - size.height * 0.43, width: size.width * 0.84, height: size.height * 0.86),
      ]
      for (index, rect) in orbitRects.enumerated() {
        context.stroke(
          Path(ellipseIn: rect),
          with: .color(index == 2 ? Arcade.vectorFaint : Arcade.vectorDim.opacity(0.72)),
          style: StrokeStyle(lineWidth: 1, dash: index == 2 ? [5, 9] : [])
        )
      }

      for rock in game.rocks {
        drawAsteroid(in: &context, at: rock.pos, radius: rock.radius, seed: rock.seed, rotation: rock.rotation)
      }
      for shot in game.shots {
        let r: CGFloat = 1.7
        context.fill(
          Path(ellipseIn: CGRect(x: shot.pos.x - r, y: shot.pos.y - r, width: r * 2, height: r * 2)),
          with: .color(Arcade.coral)
        )
      }
      for p in game.debris {
        let frac = max(0, p.life / p.maxLife) // 1 → 0
        let speed = (p.vel.dx * p.vel.dx + p.vel.dy * p.vel.dy).squareRoot()
        let ux = speed > 0 ? p.vel.dx / speed : 1
        let uy = speed > 0 ? p.vel.dy / speed : 0
        let len = 3 + 4 * CGFloat(frac)
        var seg = Path()
        seg.move(to: CGPoint(x: p.pos.x - ux * len / 2, y: p.pos.y - uy * len / 2))
        seg.addLine(to: CGPoint(x: p.pos.x + ux * len / 2, y: p.pos.y + uy * len / 2))
        context.stroke(seg, with: .color(Arcade.coral.opacity(frac)), lineWidth: 1.3)
      }
      for pop in game.pops {
        let frac = max(0, pop.life / pop.maxLife)
        let text = Text(pop.text)
          .font(.system(size: 12, weight: .bold, design: .monospaced))
          .foregroundColor((pop.positive ? Arcade.teal : Arcade.coral).opacity(frac))
        context.draw(text, at: pop.pos)
      }
      // Ship blinks while it has post-respawn grace.
      let blink = game.clock.truncatingRemainder(dividingBy: 0.26) < 0.13
      let shipAlpha = game.invulnerable ? (blink ? 0.25 : 0.85) : 0.9
      drawShip(in: &context, at: game.shipPos, angle: game.shipAngle, thrusting: game.thrusting, alpha: shipAlpha)

      if markerCount == 0 {
        let empty = Text("ADD SIGNAL")
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundColor(Arcade.vectorDim)
        context.draw(empty, at: center)
      }
    }
    .background(
      Arcade.background.overlay(
        LinearGradient(
          colors: [Color.white.opacity(0.035), Color.clear, Color.white.opacity(0.025)],
          startPoint: .top,
          endPoint: .bottom
        )
      )
    )
    .contentShape(Rectangle())
    .focusable()
    .focused($focused)
    .onTapGesture { focused = true }
    .onKeyPress(phases: [.down, .up]) { press in
      let releasing = press.phase == .up
      switch press.key {
      case .leftArrow: releasing ? game.release(.left) : game.press(.left); return .handled
      case .rightArrow: releasing ? game.release(.right) : game.press(.right); return .handled
      case .upArrow: releasing ? game.release(.thrust) : game.press(.thrust); return .handled
      case .space:
        if !releasing { game.fire() }
        return .handled
      default: return .ignored
      }
    }
    .overlay(alignment: .topTrailing) {
      VStack(alignment: .trailing, spacing: 1) {
        Text("SCORE \(game.score)")
          .foregroundStyle(scoreFlash ? (scoreWentUp ? Arcade.teal : Arcade.coral) : Arcade.text2)
          .scaleEffect(scoreFlash ? 1.16 : 1.0, anchor: .trailing)
        Text("HI \(game.highScore)").foregroundStyle(Arcade.text3)
      }
      .font(.system(size: 9, weight: .semibold, design: .monospaced))
      .padding(.top, 12)
      .padding(.trailing, 14)
      .allowsHitTesting(false)
      .onChange(of: game.score) { oldValue, newValue in
        scoreWentUp = newValue > oldValue
        withAnimation(.easeOut(duration: 0.1)) { scoreFlash = true }
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 240_000_000)
          withAnimation(.easeIn(duration: 0.25)) { scoreFlash = false }
        }
      }
    }
    .overlay(alignment: .topLeading) {
      // Idle invitation. Hit-testing off so the tap reaches the field beneath it.
      if !focused {
        Text("tap to play")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .foregroundStyle(Arcade.text3)
          .padding(.top, 14)
          .padding(.leading, 16)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .overlay(alignment: .bottomLeading) {
      if focused {
        Text("◀ ▶ steer   ▲ thrust   SPACE fire")
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(Arcade.text3)
          .padding(.bottom, 12)
          .padding(.leading, 14)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .overlay {
      if focused {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Arcade.teal.opacity(0.5), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: focused)
  }

  private func drawShip(in context: inout GraphicsContext, at p: CGPoint, angle: Double, thrusting: Bool, alpha: Double) {
    let c = CGFloat(cos(angle))
    let s = CGFloat(sin(angle))
    func tx(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: p.x + x * c - y * s, y: p.y + x * s + y * c)
    }
    var ship = Path()
    ship.move(to: tx(15, 0))
    ship.addLine(to: tx(-10, -9))
    ship.addLine(to: tx(-4, 0))
    ship.addLine(to: tx(-10, 9))
    ship.closeSubpath()
    context.stroke(ship, with: .color(Arcade.vector.opacity(alpha)), lineWidth: 1.5)

    if thrusting {
      var flame = Path()
      flame.move(to: tx(-4, 0))
      flame.addLine(to: tx(-17, 0))
      context.stroke(flame, with: .color(Arcade.coral.opacity(alpha)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
    }
  }

  private func drawAsteroid(in context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, seed: Int, rotation: Double) {
    let points = 8
    var path = Path()
    for i in 0..<points {
      let wobble = CGFloat(((i + seed) % 3)) * 0.13
      let r = radius * (0.78 + wobble)
      let angle = Double(i) / Double(points) * .pi * 2 + Double(seed) * 0.17 + rotation
      let p = CGPoint(x: point.x + CGFloat(cos(angle)) * r, y: point.y + CGFloat(sin(angle)) * r)
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    context.stroke(path, with: .color(Arcade.vectorDim), lineWidth: 1.1)
  }
}

private struct ArcadeOrbitMarkerView: View {
  let marker: ArcadeOrbitMarker
  let pulsePhase: TimeInterval

  @State private var isHovering = false

  var body: some View {
    let pulse = marker.status == .due ? 1 + sin(pulsePhase * 5) * 0.055 : 1
    // Default: just a small node so a dense orbit reads cleanly. The label is
    // revealed on hover (orbit drift is slow enough to target a node), floated
    // below as an overlay so it never shifts the node's own center/position.
    ArcadeMarkerShape(kind: marker.shape)
      .stroke(marker.status.color, style: StrokeStyle(lineWidth: 1.35, dash: marker.status.dashed ? [3, 3] : []))
      .frame(width: 16, height: 16)
      .overlay {
        if marker.status == .due {
          Circle()
            .stroke(marker.status.color.opacity(0.26), lineWidth: 1)
            .frame(width: 24, height: 24)
        }
      }
      .padding(6) // larger hit area so the slowly-drifting node is easy to hover
      .contentShape(Rectangle())
      .scaleEffect(isHovering ? 1.3 : pulse)
      .overlay(alignment: .top) {
        if isHovering {
          Text(marker.label)
            .font(DS.Font.monoMicro)
            .foregroundStyle(marker.status == .unknown ? Arcade.text3 : Arcade.text2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Arcade.background.opacity(0.92)))
            .overlay { Capsule().strokeBorder(marker.status.color.opacity(0.55), lineWidth: 1) }
            .offset(y: -16)
            .transition(.opacity)
            .zIndex(1)
        }
      }
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
      }
  }
}

private struct ArcadeStatusGlyph: View {
  let status: ArcadeOrbitStatus
  var shape = 0

  var body: some View {
    ArcadeMarkerShape(kind: shape)
      .stroke(status.color, style: StrokeStyle(lineWidth: 1.35, dash: status.dashed ? [3, 3] : []))
      .frame(width: 20, height: 20)
      .padding(3)
      .background(Circle().fill(status.color.opacity(0.08)))
      .overlay {
        Circle().strokeBorder(status.color.opacity(0.38), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }
}

private struct ArcadeMarkerShape: Shape {
  let kind: Int

  func path(in rect: CGRect) -> Path {
    let inset = rect.insetBy(dx: 2, dy: 2)
    let cx = inset.midX
    let cy = inset.midY
    let w = inset.width
    let h = inset.height
    var path = Path()

    switch abs(kind) % 6 {
    case 0:
      path.move(to: CGPoint(x: cx, y: inset.minY))
      path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
      path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + h * 0.86))
      path.closeSubpath()
    case 1:
      path.move(to: CGPoint(x: cx, y: inset.minY))
      path.addLine(to: CGPoint(x: inset.maxX, y: cy))
      path.addLine(to: CGPoint(x: cx, y: inset.maxY))
      path.addLine(to: CGPoint(x: inset.minX, y: cy))
      path.closeSubpath()
    case 2:
      path.addEllipse(in: inset)
    case 3:
      path.move(to: CGPoint(x: cx, y: inset.minY))
      path.addLine(to: CGPoint(x: inset.maxX, y: cy - h * 0.1))
      path.addLine(to: CGPoint(x: inset.maxX - w * 0.18, y: inset.maxY))
      path.addLine(to: CGPoint(x: inset.minX + w * 0.15, y: inset.maxY))
      path.addLine(to: CGPoint(x: inset.minX, y: cy - h * 0.1))
      path.closeSubpath()
    case 4:
      path.move(to: CGPoint(x: inset.minX, y: cy))
      path.addLine(to: CGPoint(x: inset.maxX, y: cy))
      path.move(to: CGPoint(x: cx, y: inset.minY))
      path.addLine(to: CGPoint(x: cx, y: inset.maxY))
      path.addEllipse(in: CGRect(x: cx - w * 0.24, y: cy - h * 0.24, width: w * 0.48, height: h * 0.48))
    default:
      path.move(to: CGPoint(x: inset.minX + w * 0.2, y: inset.minY))
      path.addLine(to: CGPoint(x: inset.maxX - w * 0.08, y: inset.minY + h * 0.22))
      path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY - h * 0.28))
      path.addLine(to: CGPoint(x: inset.minX + w * 0.38, y: inset.maxY))
      path.addLine(to: CGPoint(x: inset.minX, y: cy))
      path.closeSubpath()
    }
    return path
  }
}

private struct ArcadeSectionLabel: View {
  let text: String
  let count: Int?

  var body: some View {
    HStack(spacing: 8) {
      Text(text)
        .font(DS.Font.sectionLabel)
        .tracking(1.1)
        .foregroundStyle(Arcade.teal)
      if let count {
        Text("\(count)")
          .font(DS.Font.sectionLabel)
          .monospacedDigit()
          .foregroundStyle(Arcade.teal.opacity(0.72))
      }
      Rectangle()
        .fill(Arcade.vectorFaint)
        .frame(height: 1)
    }
  }
}

private enum ArcadeButtonVariant {
  case primary
  case secondary
}

private struct ArcadeButtonStyle: ButtonStyle {
  let variant: ArcadeButtonVariant
  let size: DSButtonSize

  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let color = variant == .primary ? Arcade.teal : Arcade.vector
    configuration.label
      .font(size.font)
      .labelStyle(DSButtonLabelStyleProxy(iconSize: size.iconSize))
      .lineLimit(1)
      .foregroundStyle(variant == .primary ? Arcade.background : color)
      .padding(.horizontal, size.hPad)
      .padding(.vertical, size.vPad)
      .frame(minHeight: size.minHeight)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(variant == .primary ? color.opacity(isEnabled ? 0.96 : 0.34) : (hovering ? Arcade.control : Color.clear))
      )
      .overlay {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .strokeBorder(color.opacity(isEnabled ? 0.78 : 0.28), lineWidth: 1)
      }
      .opacity(configuration.isPressed ? 0.72 : (isEnabled ? 1 : 0.46))
      .onHover { hovering = $0 }
  }
}

private struct DSButtonLabelStyleProxy: LabelStyle {
  let iconSize: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: iconSize, weight: .semibold))
      configuration.title
    }
  }
}

private extension View {
  func arcadeButton(_ variant: ArcadeButtonVariant = .primary, size: DSButtonSize = .regular) -> some View {
    buttonStyle(ArcadeButtonStyle(variant: variant, size: size))
  }

  func arcadeFullDiskAccessGate(toolName: String, spacing: CGFloat = 14) -> some View {
    modifier(ArcadeFullDiskAccessGate(toolName: toolName, spacing: spacing))
  }
}

private struct ArcadeFullDiskAccessGate: ViewModifier {
  let toolName: String
  let spacing: CGFloat

  @State private var access: ChatDbAccessState = .unknown

  private static let settingsDeepLink =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: spacing) {
      content
      if access == .permissionDenied {
        permissionCard
      }
    }
    .onAppear { refresh() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refresh()
    }
  }

  private var permissionCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ArcadeStatusGlyph(status: .candidate, shape: 4)
        Text("ALLOW MESSAGE ACCESS")
          .font(DS.Font.sectionLabel)
          .tracking(1.1)
          .foregroundStyle(Arcade.amber)
      }
      Text("\(toolName) reads your Messages history locally, on this Mac. Grant Full Disk Access to Ghostie in System Settings, then come back. This updates on its own.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(Arcade.text2)
        .fixedSize(horizontal: false, vertical: true)

      Button("Open System Settings") {
        if let url = URL(string: Self.settingsDeepLink) {
          NSWorkspace.shared.open(url)
        }
      }
      .arcadeButton(.secondary, size: .small)
    }
    .padding(DS.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
    .overlay {
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(Arcade.amber.opacity(0.45), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(toolName) needs Full Disk Access to read your Messages history. Open System Settings to grant it.")
  }

  private func refresh() {
    access = HealthChecks().chatDbAccessState()
  }
}

private struct ArcadeContactsPermissionBanner: View {
  @EnvironmentObject var exporter: ContactsExporter

  var body: some View {
    if exporter.authorizationStatus != .authorized {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          ArcadeStatusGlyph(status: .candidate, shape: 1)
          Text(headlineText.uppercased())
            .font(DS.Font.sectionLabel)
            .tracking(1.1)
            .foregroundStyle(Arcade.amber)
        }
        Text(bodyText)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Arcade.text2)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button(actionLabel) {
            Task { await primaryAction() }
          }
          .arcadeButton(.primary, size: .small)
          if exporter.authorizationStatus == .denied || exporter.authorizationStatus == .restricted {
            Button("Recheck") {
              Task { await exporter.exportNow() }
            }
            .arcadeButton(.secondary, size: .small)
          }
        }
      }
      .padding(DS.Space.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(Arcade.panel))
      .overlay {
        RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
          .strokeBorder(Arcade.amber.opacity(0.45), lineWidth: 1)
      }
    }
  }

  private var headlineText: String {
    switch exporter.authorizationStatus {
    case .notDetermined: return "Allow Contacts access"
    case .denied:        return "Contacts access denied"
    case .restricted:    return "Contacts access restricted by policy"
    default:             return "Contacts access unavailable"
    }
  }

  private var bodyText: String {
    switch exporter.authorizationStatus {
    case .notDetermined:
      return "Ghostie uses Contacts to resolve recipient names. This is the same data Messages.app sees, including iCloud-synced contacts."
    case .denied:
      return "Open System Settings -> Privacy & Security -> Contacts and turn on Ghostie. Then click Recheck."
    case .restricted:
      return "Your organization's device policy disallows Contacts access. Names will fall back to the local address book and may miss iCloud-only contacts."
    default:
      return "An unexpected Contacts authorization status was reported."
    }
  }

  private var actionLabel: String {
    switch exporter.authorizationStatus {
    case .notDetermined: return "Allow..."
    default:             return "Open Settings"
    }
  }

  private func primaryAction() async {
    switch exporter.authorizationStatus {
    case .notDetermined:
      await exporter.requestAccessAndExport()
    default:
      ContactsExporter.openContactsSettings()
    }
  }
}

// MARK: - First-open intro (registered in ToolRegistry)

extension KeepTabsView {
  static func makeIntro(_ actions: LabIntroActions) -> AnyView {
    AnyView(KeepTabsIntroView(actions: actions))
  }
}

private struct KeepTabsIntroView: View {
  let actions: LabIntroActions

  var body: some View {
    ZStack {
      Arcade.background
      ArcadeIntroField()
        .opacity(0.82)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        ArcadeStatusGlyph(status: .candidate, shape: 0)
          .scaleEffect(1.28)

        Text("Keep people in\nOrbit.")
          .font(DS.Font.displayTitle)
          .foregroundStyle(Arcade.text)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 22)

        VStack(alignment: .leading, spacing: 12) {
          benefit("person.2.fill", "Pick people and a cadence, from every few days to once a year.")
          benefit("phone.fill", "Calls count too, so a quick catch-up keeps the light on.")
          benefit("bell.badge.fill", "Drift too far and they light up in your priority queue.")
        }
        .padding(.top, 24)

        Spacer(minLength: 16)

        Text("Your orbit lives on this Mac · recommendations use on-device metadata only")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(Arcade.text3)

        HStack(spacing: 12) {
          Button("Not now") { actions.onCancel() }
            .arcadeButton(.secondary)
          Button {
            actions.onContinue()
          } label: {
            Label("Build my orbit", systemImage: "light.beacon.max.fill")
          }
          .arcadeButton(.primary)
          .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 14)
      }
      .padding(36)
    }
  }

  private func benefit(_ icon: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Arcade.teal)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(text)
        .font(DS.Font.settingsLabel)
        .foregroundStyle(Arcade.text2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ArcadeIntroField: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.addEllipse(in: CGRect(x: size.width * 0.38, y: size.height * 0.14, width: size.width * 0.62, height: size.height * 0.46))
      context.stroke(path, with: .color(Arcade.vectorFaint), style: StrokeStyle(lineWidth: 1, dash: [6, 9]))

      drawAsteroid(in: &context, at: CGPoint(x: size.width * 0.76, y: size.height * 0.24), radius: 28, seed: 2)
      drawAsteroid(in: &context, at: CGPoint(x: size.width * 0.89, y: size.height * 0.66), radius: 19, seed: 4)
      drawShip(in: &context, at: CGPoint(x: size.width * 0.62, y: size.height * 0.48))
    }
  }

  private func drawShip(in context: inout GraphicsContext, at point: CGPoint) {
    var ship = Path()
    ship.move(to: CGPoint(x: point.x + 30, y: point.y))
    ship.addLine(to: CGPoint(x: point.x - 18, y: point.y - 18))
    ship.addLine(to: CGPoint(x: point.x - 7, y: point.y))
    ship.addLine(to: CGPoint(x: point.x - 18, y: point.y + 18))
    ship.closeSubpath()
    context.stroke(ship, with: .color(Arcade.vector.opacity(0.68)), lineWidth: 1.4)
  }

  private func drawAsteroid(in context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, seed: Int) {
    let points = 8
    var path = Path()
    for i in 0..<points {
      let r = radius * (0.76 + CGFloat((i + seed) % 3) * 0.13)
      let angle = Double(i) / Double(points) * .pi * 2 + Double(seed) * 0.2
      let p = CGPoint(x: point.x + CGFloat(cos(angle)) * r, y: point.y + CGFloat(sin(angle)) * r)
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    context.stroke(path, with: .color(Arcade.vectorDim), lineWidth: 1.1)
  }
}
