import SwiftUI

struct WorkPersonalView: View {
  @EnvironmentObject private var workPersonal: WorkPersonalStore
  @EnvironmentObject private var settings: SettingsStore
  @Environment(\.colorScheme) private var colorScheme

  @State private var recents: [RecentComposeThread] = []
  @State private var sortState: WorkPersonalSortState?
  @State private var isSortingPresented = false
  @State private var isRunningAIFirstPass = false
  @State private var isProfessionPresented = false
  @State private var runAfterProfession = false
  @State private var query = ""

  private var filteredRecents: [RecentComposeThread] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return recents }
    return recents.filter {
      $0.title.lowercased().contains(q) ||
        $0.subtitle.lowercased().contains(q) ||
        $0.handle.lowercased().contains(q)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        scheduleCard
        sortingCard
        contactsCard
        footer
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Lumon.canvas(colorScheme))
    // Tint the console rail + titlebar strip to match this lab's canvas.
    .consoleChromeBackground(Lumon.canvas(colorScheme))
    .onAppear {
      workPersonal.mode = .basic
      reload()
    }
    .onChange(of: settings.whatsappEnabled) { _, _ in reload() }
    .sheet(isPresented: $isSortingPresented) {
      WorkPersonalSortingModal(sortState: $sortState, isPresented: $isSortingPresented)
        .environmentObject(workPersonal)
        // Refinement happens in the innie world: the terminal is ALWAYS the
        // dark CRT, whatever the outie's system theme says. The lab's main
        // pane (this view) stays daylight paper — crossing the sheet
        // threshold is the elevator.
        .environment(\.colorScheme, .dark)
        .frame(width: 760, height: 640)
    }
    .sheet(isPresented: $isProfessionPresented) {
      WorkPersonalProfessionModal(isPresented: $isProfessionPresented) {
        if runAfterProfession {
          runAfterProfession = false
          runAIFirstPass()
        }
      }
      .environmentObject(workPersonal)
      .frame(width: 760, height: 560)
    }
  }

  private var header: some View {
    VStack(spacing: 14) {
      HStack(alignment: .center, spacing: 16) {
        LumonEmblem()
        VStack(alignment: .leading, spacing: 6) {
          Text("Dept. of Work–Life Separation")
            .font(Lumon.eyebrow)
            .tracking(2.6)
            .textCase(.uppercase)
            .foregroundStyle(Lumon.mintText(colorScheme))
          HStack(spacing: 9) {
            Image(systemName: "briefcase.fill")
              .font(.system(size: 13, weight: .light))
              .foregroundStyle(Lumon.ink(colorScheme))
              .accessibilityHidden(true)
            Text("Severance")
              .font(Lumon.display)
              .tracking(3.5)
              .textCase(.uppercase)
              .foregroundStyle(Lumon.ink(colorScheme))
          }
          .accessibilityElement(children: .combine)
          Text("Separate your Messages view by work and personal context.")
            .font(Lumon.caption)
            .foregroundStyle(Lumon.ink3(colorScheme))
        }
        Spacer(minLength: 12)
        severanceSwitch
      }
      LumonDoubleRule()
    }
  }

  /// The Enabled control, presented as a deliberate, ceremonial switch.
  private var severanceSwitch: some View {
    LumonCeremonialSwitch(
      eyebrow: "Procedure",
      toggleLabel: "Enabled",
      isOn: $workPersonal.enabled,
      stampOn: "In effect",
      stampOff: "Suspended"
    )
  }

  /// On-a-schedule controls: pick weekdays + a window and the feature turns
  /// itself on and off at the boundaries (manual toggles win in between).
  private var scheduleCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      LumonFormHeader(number: "01", title: "Schedule of operation")
      HStack(alignment: .center) {
        Text("Turn Severance on and off automatically.")
          .font(Lumon.caption)
          .foregroundStyle(Lumon.ink3(colorScheme))
        Spacer()
        LumonCeremonialSwitch(
          eyebrow: "Schedule",
          toggleLabel: "On a schedule",
          isOn: $workPersonal.schedule.isOn,
          stampOn: "Observed",
          stampOff: "Suspended"
        )
      }

      if workPersonal.schedule.isOn {
        HStack(spacing: 5) {
          ForEach(Array(zip(1...7, ["S", "M", "T", "W", "T", "F", "S"])), id: \.0) { weekday, letter in
            weekdayToggle(weekday, letter: letter)
          }
        }

        HStack(spacing: 12) {
          scheduleTimePicker("From", minutes: $workPersonal.schedule.startMinutes)
          scheduleTimePicker("Until", minutes: $workPersonal.schedule.endMinutes)
          Spacer()
          LumonStamp(
            text: workPersonal.schedule.isActive() ? "Active now" : "Off right now",
            active: workPersonal.schedule.isActive()
          )
        }
      }
    }
    .padding(16)
    .lumonPanel()
  }

  private func weekdayToggle(_ weekday: Int, letter: String) -> some View {
    let isOn = workPersonal.schedule.weekdays.contains(weekday)
    return Button {
      if isOn {
        workPersonal.schedule.weekdays.remove(weekday)
      } else {
        workPersonal.schedule.weekdays.insert(weekday)
      }
    } label: {
      Text(letter)
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .frame(width: 26, height: 26)
        .background(
          Circle().fill(isOn ? Lumon.mintDeep : Lumon.well(colorScheme))
        )
        .overlay(
          Circle().strokeBorder(
            isOn ? Lumon.mintDeep : Lumon.line(colorScheme),
            lineWidth: 1
          )
        )
        .foregroundStyle(isOn ? Lumon.inkOnMint : Lumon.ink3(colorScheme))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  private func scheduleTimePicker(_ label: String, minutes: Binding<Int>) -> some View {
    HStack(spacing: 6) {
      Text(label)
        .font(Lumon.eyebrow)
        .tracking(1.8)
        .textCase(.uppercase)
        .foregroundStyle(Lumon.ink3(colorScheme))
      DatePicker(
        label,
        selection: Binding(
          get: {
            Calendar.current.date(
              bySettingHour: minutes.wrappedValue / 60,
              minute: minutes.wrappedValue % 60,
              second: 0,
              of: Date()
            ) ?? Date()
          },
          set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (components.hour ?? 9) * 60 + (components.minute ?? 0)
          }
        ),
        displayedComponents: .hourAndMinute
      )
      .labelsHidden()
      .datePickerStyle(.field)
      .fixedSize()
    }
  }

  private var sortingCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      LumonFormHeader(number: "02", title: "Macrodata refinement")
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sort recent conversations")
            .font(Lumon.name)
            .foregroundStyle(Lumon.ink(colorScheme))
          Text("Left = Work, Right = Personal, Up = Both, Down = Neither, Tab = Business, X = Spam.")
            .font(Lumon.caption)
            .foregroundStyle(Lumon.ink3(colorScheme))
        }
        Spacer()
        Button {
          sortState = WorkPersonalSortState.make(from: recents, store: workPersonal)
          isSortingPresented = true
        } label: {
          Label("Start", systemImage: "play.fill")
        }
        .lumonButton(.primary)
      }

      if canRunAIFirstPass {
        HStack(spacing: 10) {
          Button {
            requestAIFirstPass()
          } label: {
            Label(
              isRunningAIFirstPass ? "Pre-refinement in progress…" : "Request AI pre-refinement",
              systemImage: "wand.and.stars"
            )
          }
          .lumonButton(.secondary, size: .small)
          .disabled(isRunningAIFirstPass)
          Text("AI sorts the confident calls; you handle the rest.")
            .font(Lumon.caption)
            .foregroundStyle(Lumon.ink3(colorScheme))
          Spacer(minLength: 0)
          if !WorkPersonalProfessionGate.shouldPresent(workDescription: workPersonal.workDescription) {
            Button {
              runAfterProfession = false
              isProfessionPresented = true
            } label: {
              Label("Edit profession", systemImage: "pencil.line")
            }
            .lumonButton(.ghost, size: .small)
            .accessibilityHint("Edit the work description used by AI pre-refinement.")
          }
        }
      }

      Text(sortingStatusLine)
        .font(Lumon.caption)
        .foregroundStyle(Lumon.ink3(colorScheme))
    }
    .padding(16)
    .lumonPanel()
  }

  /// Premium affordance: present whenever an AI key is configured (bring-
  /// your-own-key unlocks every premium feature).
  private var canRunAIFirstPass: Bool {
    LabModelPreferences.clientSelection(for: .workPersonal) != nil
  }

  private var sortingStatusLine: String {
    if isRunningAIFirstPass { return workPersonal.status }
    if sortState?.isComplete == true { return "Sorting complete." }
    return workPersonal.status.hasPrefix("AI sorted")
      ? workPersonal.status
      : "Start a focused sorting session for recent unsorted conversations."
  }

  /// Pre-refinement entry point: routes through the "state your profession"
  /// declaration whenever no work description is on file.
  private func requestAIFirstPass() {
    if WorkPersonalProfessionGate.shouldPresent(workDescription: workPersonal.workDescription) {
      runAfterProfession = true
      isProfessionPresented = true
    } else {
      runAIFirstPass()
    }
  }

  private func runAIFirstPass() {
    isRunningAIFirstPass = true
    let candidates = recents
    Task {
      await workPersonal.runAIFirstPass(candidates: candidates) { thread in
        await RecentComposeThread.loadContextAsync(for: thread.recipient, limit: 4)
      }
      isRunningAIFirstPass = false
    }
  }

  private var contactsCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      LumonFormHeader(number: "03", title: "Reassignment")
      TextField("Search contacts or conversations", text: $query)
        .lumonInput(colorScheme)
      LazyVStack(alignment: .leading, spacing: 6) {
        ForEach(filteredRecents.prefix(80)) { recent in
          HStack(spacing: 10) {
            avatar(recent)
            VStack(alignment: .leading, spacing: 2) {
              Text(recent.title)
                .font(Lumon.name)
                .foregroundStyle(Lumon.ink(colorScheme))
              if !recent.subtitle.isEmpty {
                Text(recent.subtitle)
                  .font(Lumon.mono)
                  .foregroundStyle(Lumon.ink3(colorScheme))
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }
            Spacer()
            Picker("", selection: Binding(
              get: { workPersonal.personLabel(for: recent) },
              set: { workPersonal.setPersonLabel($0, for: recent) }
            )) {
              ForEach(WorkPersonalLabel.allCases) { label in
                Label(label.title, systemImage: label.systemImage).tag(label)
              }
            }
            .labelsHidden()
            .frame(width: 150)
          }
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
              .fill(Lumon.well(colorScheme))
          )
          .overlay(
            RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
              .strokeBorder(Lumon.line(colorScheme).opacity(0.7), lineWidth: 1)
          )
        }
      }
    }
    .padding(16)
    .lumonPanel()
  }

  private var footer: some View {
    VStack(spacing: 10) {
      LumonDoubleRule()
        .frame(maxWidth: 220)
      Text("Please enjoy each conversation equally.")
        .font(Lumon.caption)
        .tracking(0.6)
        .foregroundStyle(Lumon.ink3(colorScheme))
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 6)
  }

  private func avatar(_ recent: RecentComposeThread) -> some View {
    LumonBadge(
      text: monogram(recent.title),
      tint: recent.platform == .whatsapp ? DS.Color.green(colorScheme) : Lumon.ink2(colorScheme),
      size: 34
    )
  }

  private func reload() {
    let includeWhatsApp = settings.whatsappEnabled
    DispatchQueue.global(qos: .userInitiated).async {
      var loaded = RecentComposeThread.loadIMessage(limit: 220)
      if includeWhatsApp {
        loaded.append(contentsOf: RecentComposeThread.loadWhatsApp(limit: 120))
      }
      loaded.sort {
        ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast)
      }
      DispatchQueue.main.async {
        recents = loaded
        // Auto-bin obvious businesses (deterministic, no API key) so they never
        // land in the manual sort queue.
        workPersonal.autoTagObviousBusinesses(loaded)
        sortState = nil
      }
    }
  }

  private func monogram(_ title: String) -> String {
    let initials = title
      .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
      .compactMap { $0.first }
      .prefix(2)
      .map { String($0).uppercased() }
      .joined()
    return initials.isEmpty ? String(title.prefix(2)).uppercased() : initials
  }
}

private struct WorkPersonalSortingModal: View {
  @EnvironmentObject private var workPersonal: WorkPersonalStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @Binding var sortState: WorkPersonalSortState?
  @Binding var isPresented: Bool
  @State private var feedback: SortingFeedback?
  /// The innie drop: descent sweep → boot readout → live console. Reduce
  /// Motion (and any click/keypress during the intro) goes straight to live.
  @State private var introDone = false

  private var currentAIHint: WorkPersonalAISuggestion? {
    guard let current = sortState?.current else { return nil }
    return workPersonal.aiSuggestion(for: current)
  }
  @State private var contextByID: [String: [ContextMessage]] = [:]
  @State private var loadingContextIDs = Set<String>()

  /// Lumon-style file codename for this refinement session, derived from the
  /// queue so a session keeps its name across re-renders.
  private var fileCodename: String {
    LumonRefinementCodename.codename(for: (sortState?.queue ?? []).map(\.id))
  }

  var body: some View {
    ZStack {
      terminal
        .opacity(introDone ? 1 : 0)
      if !introDone {
        LumonTerminalIntro(codename: fileCodename) {
          withAnimation(reduceMotion ? nil : .easeIn(duration: 0.3)) {
            introDone = true
          }
        }
        .transition(.opacity)
      }
    }
    .background(Lumon.canvas(colorScheme))
    .lumonCRT()
    .onAppear {
      if reduceMotion { introDone = true }
      loadCurrentContext()
    }
    .onChange(of: sortState?.current?.id) { _, _ in
      loadCurrentContext()
    }
  }

  private var terminal: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Macrodata refinement")
            .font(Lumon.eyebrow)
            .tracking(2.6)
            .textCase(.uppercase)
            .foregroundStyle(Lumon.mintText(colorScheme))
          Text(fileCodename)
            .font(Lumon.display)
            .tracking(3)
            .textCase(.uppercase)
            .foregroundStyle(Lumon.ink(colorScheme))
          Text("Label recent conversations. Use arrow keys, or click a choice.")
            .font(Lumon.caption)
            .foregroundStyle(Lumon.ink3(colorScheme))
          if let hint = currentAIHint {
            HStack(spacing: 6) {
              Image(systemName: "wand.and.stars")
                .font(.system(size: 10, weight: .medium))
              Text("AI suspects \(hint.label.title) (\(Int((hint.confidence * 100).rounded()))%)\(hint.reason.map { " — \($0)" } ?? "")")
                .font(Lumon.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .foregroundStyle(Lumon.mintText(colorScheme))
            .padding(.top, 2)
            .accessibilityLabel("AI suggestion: \(hint.label.title), \(Int((hint.confidence * 100).rounded())) percent confident")
          }
        }
        Spacer()
        Button {
          isPresented = false
        } label: {
          Label("Exit", systemImage: "xmark.circle")
        }
        .lumonButton(.ghost)
      }

      // Reserved status slot: the flash banner appears here without shifting
      // the layout below (keeps the fixed-height sheet arithmetic stable).
      ZStack(alignment: .leading) {
        if let feedback {
          Label(feedback.title, systemImage: feedback.systemImage)
            .font(Lumon.label)
            .foregroundStyle(feedback.tint(colorScheme))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
              RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
                .fill(feedback.tint(colorScheme).opacity(0.10))
            )
            .overlay(
              RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
                .strokeBorder(feedback.tint(colorScheme).opacity(0.4), lineWidth: 1)
            )
            .transition(.opacity)
        }
      }
      .frame(height: 30, alignment: .leading)

      if let state = sortState, let current = state.current {
        HStack(alignment: .top, spacing: 16) {
          // The card is keyed per conversation: a sort "files" it — the card
          // shrinks toward the console (the bins) and the next file drops in
          // from the top, over the drifting macrodata field.
          currentConversationCard(
            current,
            state: state,
            context: contextByID[current.id] ?? [],
            isLoadingContext: loadingContextIDs.contains(current.id)
          )
          .id(current.id)
          .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .scale(scale: 0.05, anchor: .bottomTrailing).combined(with: .opacity)
          ))
          SortingKeyPanel(
            canGoBack: !state.history.isEmpty,
            onApply: { label in
              apply(label)
            },
            onBack: {
              goBack()
            },
            onSkip: {
              skip()
            },
            onStop: {
              isPresented = false
            }
          )
        }
        .background(
          LumonDigitField(seed: fileCodename.hashValue, isStatic: reduceMotion)
            .padding(-10)
            .opacity(0.5)
        )

      } else {
        VStack(alignment: .center, spacing: 12) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(Lumon.mintText(colorScheme))
          LumonStamp(text: "100% complete", active: true)
          Text("Sorting complete.")
            .font(Lumon.name)
            .foregroundStyle(Lumon.ink(colorScheme))
          Text("You can reopen the sorter later if more unknown conversations appear.")
            .font(Lumon.caption)
            .foregroundStyle(Lumon.ink3(colorScheme))
          Button("Done") {
            isPresented = false
          }
          .lumonButton(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      // Terminal readout strip: real identifiers as hex, the way the screen
      // signs its work. Decorative but truthful.
      HStack {
        Text(LumonRefinementCodename.hexReadout(fileCodename))
          .font(Lumon.mono)
          .foregroundStyle(Lumon.ink3(colorScheme).opacity(0.7))
        Spacer()
        if let current = sortState?.current {
          Text(LumonRefinementCodename.hexReadout(current.id))
            .font(Lumon.mono)
            .foregroundStyle(Lumon.ink3(colorScheme).opacity(0.7))
        }
      }
      .accessibilityHidden(true)
    }
    .padding(26)
  }

  private func currentConversationCard(
    _ recent: RecentComposeThread,
    state: WorkPersonalSortState,
    context: [ContextMessage],
    isLoadingContext: Bool
  ) -> some View {
    let total = state.queue.count
    let percent = total == 0 ? 100 : Int((Double(min(state.currentIndex, total)) / Double(total)) * 100)
    return VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("FILE \(min(state.currentIndex + 1, total)) / \(total)")
          .font(Lumon.mono)
          .foregroundStyle(Lumon.ink3(colorScheme))
        Spacer()
        Text("\(percent)% COMPLETE")
          .font(Lumon.mono)
          .foregroundStyle(Lumon.mintText(colorScheme))
          .accessibilityHidden(true)
      }

      HStack(spacing: 14) {
        LumonBadge(
          text: monogram(recent.title),
          tint: recent.platform == .whatsapp ? DS.Color.green(colorScheme) : Lumon.ink2(colorScheme),
          size: 44
        )

        VStack(alignment: .leading, spacing: 4) {
          Text(recent.title)
            .font(Lumon.name)
            .foregroundStyle(Lumon.ink(colorScheme))
            .lineLimit(2)
          if !recent.subtitle.isEmpty {
            Text(recent.subtitle)
              .font(Lumon.mono)
              .foregroundStyle(Lumon.ink3(colorScheme))
              .lineLimit(2)
              .truncationMode(.middle)
          }
        }
      }

      LumonDoubleRule()

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "text.bubble")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Lumon.ink3(colorScheme))
          Text("Recent messages")
            .font(Lumon.eyebrow)
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(Lumon.ink3(colorScheme))
        }

        if isLoadingContext {
          ProgressView()
            .controlSize(.small)
            .tint(Lumon.mintText(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if context.isEmpty {
          Text("No recent readable context.")
            .font(Lumon.caption)
            .foregroundStyle(Lumon.ink3(colorScheme))
        } else {
          ForEach(Array(context.suffix(4).enumerated()), id: \.offset) { _, message in
            contextRow(message)
          }
        }
      }

      Spacer(minLength: 0)
    }
    .padding(18)
    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
    .lumonPanel()
  }

  private func contextRow(_ message: ContextMessage) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(message.displayName)
        .font(Lumon.mono)
        .foregroundStyle(Lumon.ink3(colorScheme))
        .lineLimit(1)
      Text(message.body ?? "")
        .font(Lumon.caption)
        .foregroundStyle(Lumon.ink2(colorScheme))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
        .fill(Lumon.paperDeep(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
        .strokeBorder(Lumon.line(colorScheme).opacity(0.6), lineWidth: 1)
    )
  }

  private func apply(_ label: WorkPersonalLabel) {
    guard let state = sortState else { return }
    advance { sortState = state.applying(label: label, store: workPersonal) }
    flash("Marked \(label.title)", systemImage: label.systemImage, label: label)
  }

  private func skip() {
    guard let state = sortState else { return }
    advance { sortState = state.skipping() }
    flash("Skipped", systemImage: "forward", label: nil)
  }

  private func goBack() {
    guard let state = sortState else { return }
    advance { sortState = state.undo(store: workPersonal) }
    flash("Back", systemImage: "arrow.uturn.backward", label: nil)
  }

  /// Animates the file-the-card / next-file-drops-in transition (the card's
  /// per-id .transition does the visual work). Plain assignment under
  /// Reduce Motion.
  private func advance(_ mutate: () -> Void) {
    if reduceMotion {
      mutate()
    } else {
      withAnimation(.easeInOut(duration: 0.26)) {
        mutate()
      }
    }
  }

  private func flash(_ title: String, systemImage: String, label: WorkPersonalLabel?) {
    let next = SortingFeedback(title: title, systemImage: systemImage, label: label)
    if reduceMotion {
      feedback = next
    } else {
      withAnimation(.easeOut(duration: 0.12)) {
        feedback = next
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      guard feedback?.id == next.id else { return }
      if reduceMotion {
        feedback = nil
      } else {
        withAnimation(.easeIn(duration: 0.16)) {
          feedback = nil
        }
      }
    }
  }

  private func loadCurrentContext() {
    guard let recent = sortState?.current, contextByID[recent.id] == nil else { return }
    guard !loadingContextIDs.contains(recent.id) else { return }
    loadingContextIDs.insert(recent.id)
    Task {
      let context = await RecentComposeThread.loadContextAsync(for: recent.recipient, limit: 4)
      await MainActor.run {
        contextByID[recent.id] = context
        loadingContextIDs.remove(recent.id)
      }
    }
  }

  private func monogram(_ title: String) -> String {
    let initials = title
      .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
      .compactMap { $0.first }
      .prefix(2)
      .map { String($0).uppercased() }
      .joined()
    return initials.isEmpty ? String(title.prefix(2)).uppercased() : initials
  }
}

/// The "STATE YOUR PROFESSION" declaration: a full-sheet Lumon form that
/// collects the user's work description before the first AI pre-refinement
/// run (and whenever the description is empty). Saves to
/// `workPersonal.workDescription`; `onSubmit` fires after a successful save.
private struct WorkPersonalProfessionModal: View {
  @EnvironmentObject private var workPersonal: WorkPersonalStore
  @Environment(\.colorScheme) private var colorScheme

  @Binding var isPresented: Bool
  var onSubmit: () -> Void = {}

  @State private var draft = ""
  @FocusState private var editorFocused: Bool

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 16)

      VStack(spacing: 18) {
        LumonEmblem()

        VStack(spacing: 7) {
          Text("Dept. of Work–Life Separation")
            .font(Lumon.eyebrow)
            .tracking(2.6)
            .textCase(.uppercase)
            .foregroundStyle(Lumon.mintText(colorScheme))
          Text("State your profession")
            .font(Lumon.display)
            .tracking(3.5)
            .textCase(.uppercase)
            .foregroundStyle(Lumon.ink(colorScheme))
          LumonDoubleRule()
            .frame(maxWidth: 220)
        }

        Text("Form No. 04 — Occupational declaration")
          .font(Lumon.eyebrow)
          .tracking(2.2)
          .textCase(.uppercase)
          .foregroundStyle(Lumon.mintText(colorScheme))

        Text("Describe what you do for work. Refinement treats a conversation as work only when it matches this declaration.")
          .font(Lumon.caption)
          .foregroundStyle(Lumon.ink3(colorScheme))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 440)

        ZStack(alignment: .topLeading) {
          TextEditor(text: $draft)
            .font(Lumon.label)
            .foregroundStyle(Lumon.ink(colorScheme))
            .scrollContentBackground(.hidden)
            .padding(8)
            .focused($editorFocused)
            .accessibilityLabel("Work description")
          if draft.isEmpty {
            Text("e.g. I'm a freelance product designer; clients and studio partners text me about projects.")
              .font(Lumon.caption)
              .foregroundStyle(Lumon.ink3(colorScheme).opacity(0.8))
              .padding(.horizontal, 13)
              .padding(.vertical, 16)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .frame(maxWidth: 480)
        .frame(height: 110)
        .background(
          RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
            .fill(Lumon.paperDeep(colorScheme))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
            .strokeBorder(Lumon.line(colorScheme), lineWidth: 1)
        )

        HStack(spacing: 10) {
          Button("Cancel") {
            isPresented = false
          }
          .lumonButton(.ghost)
          .keyboardShortcut(.escape, modifiers: [])

          Button {
            submit()
          } label: {
            Label("Submit declaration", systemImage: "checkmark.seal")
          }
          .lumonButton(.primary)
          .disabled(trimmedDraft.isEmpty)
        }

        LumonStamp(
          text: trimmedDraft.isEmpty ? "Declaration required" : "Ready to file",
          active: !trimmedDraft.isEmpty
        )
      }

      Spacer(minLength: 16)

      Text("Your declaration is stored locally and only included in classification requests you start.")
        .font(Lumon.caption)
        .foregroundStyle(Lumon.ink3(colorScheme))
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Lumon.canvas(colorScheme))
    .onAppear {
      draft = workPersonal.workDescription
      editorFocused = true
    }
  }

  private func submit() {
    let declaration = trimmedDraft
    guard !declaration.isEmpty else { return }
    workPersonal.workDescription = declaration
    isPresented = false
    onSubmit()
  }
}

private struct SortingFeedback: Identifiable, Equatable {
  let id = UUID()
  let title: String
  let systemImage: String
  let label: WorkPersonalLabel?

  func tint(_ colorScheme: ColorScheme) -> Color {
    switch label {
    case .work: return Lumon.azure(colorScheme)
    case .personal: return Lumon.mintText(colorScheme)
    case .both: return Lumon.azure(colorScheme)
    case .neither: return Lumon.ink3(colorScheme)
    case .business: return DS.Color.amber(colorScheme)
    case .spam: return DS.Color.red
    case .unknown, nil: return Lumon.ink2(colorScheme)
    }
  }
}

private struct SortingKeyPanel: View {
  @Environment(\.colorScheme) private var colorScheme
  let canGoBack: Bool
  let onApply: (WorkPersonalLabel) -> Void
  let onBack: () -> Void
  let onSkip: () -> Void
  let onStop: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Refinement console")
          .font(Lumon.eyebrow)
          .tracking(2.4)
          .textCase(.uppercase)
          .foregroundStyle(Lumon.mintText(colorScheme))
        Text("Keyboard")
          .font(Lumon.name)
          .foregroundStyle(Lumon.ink(colorScheme))
        Text("Use shortcuts or click a choice.")
          .font(Lumon.caption)
          .foregroundStyle(Lumon.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 7) {
        actionRow(key: "←", label: .work)
        actionRow(key: "→", label: .personal)
        actionRow(key: "↑", label: .both)
        actionRow(key: "↓", label: .neither)
        actionRow(key: "Tab", label: .business)
        actionRow(key: "X", label: .spam)
        skipRow()
      }

      // Back/Exit live INSIDE the console panel, directly below the rows, so
      // they can never be pushed past the sheet's bottom edge. The spacer
      // only absorbs extra room; under compression it collapses to 8pt.
      Spacer(minLength: 8)

      HStack(spacing: 8) {
        Button {
          onBack()
        } label: {
          Label("Back", systemImage: "arrow.uturn.backward")
        }
        .lumonButton(.secondary, size: .small)
        .disabled(!canGoBack)
        .keyboardShortcut(.delete, modifiers: [])

        Button {
          onStop()
        } label: {
          Label("Exit", systemImage: "xmark.circle")
        }
        .lumonButton(.ghost, size: .small)
        .keyboardShortcut(.escape, modifiers: [])
      }
    }
    .padding(18)
    .frame(width: 260, alignment: .topLeading)
    .lumonPanel()
  }

  private func skipRow() -> some View {
    Button {
      onSkip()
    } label: {
      HStack(spacing: 10) {
        keyCap("Space", width: 58)
        Label("Skip", systemImage: "forward")
          .font(Lumon.label)
          .foregroundStyle(Lumon.ink(colorScheme))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .fill(Lumon.well(colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .strokeBorder(Lumon.line(colorScheme).opacity(0.7), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.space, modifiers: [])
  }

  private func actionRow(key: String, label: WorkPersonalLabel) -> some View {
    Button {
      onApply(label)
    } label: {
      HStack(spacing: 10) {
        keyCap(key, width: key.count > 1 ? 42 : 28)
        Label(label.title, systemImage: label.systemImage)
          .font(Lumon.label)
          .foregroundStyle(Lumon.ink(colorScheme))
        Spacer(minLength: 0)
        Text(binNumber(for: label))
          .font(Lumon.mono)
          .foregroundStyle(Lumon.ink3(colorScheme).opacity(0.8))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .fill(Lumon.well(colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .strokeBorder(Lumon.line(colorScheme).opacity(0.7), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcut(for: label), modifiers: [])
  }

  /// Decorative "bin" numbering — the macrodata-refinement framing.
  private func binNumber(for label: WorkPersonalLabel) -> String {
    switch label {
    case .work: return "BIN 01"
    case .personal: return "BIN 02"
    case .both: return "BIN 03"
    case .neither: return "BIN 04"
    case .business: return "BIN 05"
    case .spam: return "BIN 06"
    case .unknown: return ""
    }
  }

  private func shortcut(for label: WorkPersonalLabel) -> KeyEquivalent {
    switch label {
    case .work: return .leftArrow
    case .personal: return .rightArrow
    case .both: return .upArrow
    case .neither: return .downArrow
    case .business: return .tab
    case .spam: return KeyEquivalent("x")
    case .unknown: return .space
    }
  }

  private func keyCap(_ text: String, width: CGFloat) -> some View {
    Text(text)
      .font(Lumon.keycap)
      .foregroundStyle(Lumon.ink2(colorScheme))
      .frame(width: width, height: 24)
      .background(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .fill(Lumon.paperDeep(colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .strokeBorder(Lumon.line(colorScheme), lineWidth: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .inset(by: 2)
          .strokeBorder(Lumon.line(colorScheme).opacity(0.45), lineWidth: 0.75)
      )
  }
}

// MARK: - Lumon kit (file-private — Severance only)
//
// This lab is the ONE surface allowed to break from "calm native precision"
// into sterile retro-corporate: Lumon-Industries mint/seafoam on institutional
// navy-teal and clean off-white, precise thin rules and double-line borders
// like official forms, centered headings with wide letterspacing, and deadpan
// corporate microcopy. Deliberately NOT in DesignSystem/ — this aesthetic must
// not leak into the rest of the app.

private enum Lumon {
  // The Lumon mint/seafoam + deep institutional navy-teal.
  static let mintDeep = DS.Color.hex(0x4FB69A)
  /// Ink for text sitting ON a mint fill — fixed in both schemes.
  static let inkOnMint = DS.Color.hex(0x06231C)

  /// Mint tuned for TEXT legibility per scheme.
  static func mintText(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x9FE7D2) : DS.Color.hex(0x18705C) }
  static func mintDim(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x9FE7D2).opacity(0.16) : DS.Color.hex(0x4FB69A).opacity(0.14) }
  /// Institutional steel blue, for the Work/Both sorting tints.
  static func azure(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x8FC9E2) : DS.Color.hex(0x205F7E) }

  // Clean off-white paper in light; deep teal-black terminal in dark.
  static func canvas(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x06161B) : DS.Color.hex(0xEFF3F0) }
  static func paper(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x0B2128) : DS.Color.hex(0xFAFBF8) }
  static func paperDeep(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x081B21) : DS.Color.hex(0xFFFFFF) }
  static func well(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x0F2A33) : DS.Color.hex(0xF0F4F1) }
  static func ink(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xD9F2E9) : DS.Color.hex(0x122A33) }
  static func ink2(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xA9C8BF) : DS.Color.hex(0x39565F) }
  static func ink3(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x7FA098) : DS.Color.hex(0x5C757C) }
  static func line(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x9FE7D2).opacity(0.22) : DS.Color.hex(0x122A33).opacity(0.30) }

  /// Near-square corners: official forms, not friendly rounded cards.
  static let radius: CGFloat = 2

  // Clean grotesque (system), light-to-regular weights; wide tracking is
  // applied at the call site (it's a Text modifier) and is ON-theme here.
  static let display = Font.system(size: 19, weight: .light)
  static let formTitle = Font.system(size: 12.5, weight: .regular)
  static let eyebrow = Font.system(size: 9, weight: .medium)
  static let name = Font.system(size: 13, weight: .medium)
  static let label = Font.system(size: 12.5, weight: .regular)
  static let caption = Font.system(size: 11.5, weight: .regular)
  static let button = Font.system(size: 10.5, weight: .medium)
  static let buttonSmall = Font.system(size: 10, weight: .medium)
  static let micro = Font.system(size: 9, weight: .medium)
  // Mono only for real data: handles, counters, keycaps (terminal readouts).
  static let mono = Font.system(size: 10.5, weight: .regular, design: .monospaced)
  static let keycap = Font.system(size: 12, weight: .medium, design: .monospaced)
}

// MARK: Lumon terminal intro (the innie drop)

/// The severance threshold. Starting a refinement session descends into the
/// innie terminal: a floor-light sweep (the elevator), then a deadpan boot
/// readout, then the console. Any click skips straight to the console; the
/// caller skips the whole intro under Reduce Motion.
private struct LumonTerminalIntro: View {
  @Environment(\.colorScheme) private var colorScheme
  let codename: String
  let onFinished: () -> Void

  @State private var sweep: CGFloat = -0.08
  @State private var visibleLines = 0
  @State private var cursorOn = true
  @State private var finished = false

  private var bootLines: [String] {
    [
      "LUMON INDUSTRIES // MACRODATA REFINEMENT",
      "TERMINAL 03 — SESSION GRANTED",
      "FILE ASSIGNED: \(codename.uppercased())",
    ]
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        Lumon.canvas(colorScheme)

        // Elevator descent: a floor light passing top → bottom.
        Rectangle()
          .fill(
            LinearGradient(
              colors: [.clear, Lumon.mintText(colorScheme).opacity(0.55), .clear],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(height: 56)
          .offset(y: sweep * proxy.size.height)
          .opacity(sweep < 1 ? 1 : 0)

        VStack(alignment: .leading, spacing: 10) {
          LumonEmblem()
            .opacity(visibleLines > 0 ? 0.9 : 0)
          ForEach(0..<visibleLines, id: \.self) { index in
            Text(bootLines[index])
              .font(Lumon.mono)
              .foregroundStyle(Lumon.mintText(colorScheme))
          }
          if visibleLines > 0, visibleLines < bootLines.count {
            Rectangle()
              .fill(Lumon.mintText(colorScheme))
              .frame(width: 7, height: 13)
              .opacity(cursorOn ? 1 : 0)
          }
        }
        .padding(34)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { finish() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Entering macrodata refinement")
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Activate to skip the intro")
    .accessibilityAction { finish() }
    .onAppear { run() }
  }

  private func run() {
    withAnimation(.easeInOut(duration: 0.65)) { sweep = 1.05 }
    withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
      cursorOn = false
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 550_000_000)
      for shown in 1...bootLines.count {
        guard !finished else { return }
        withAnimation(.easeOut(duration: 0.12)) { visibleLines = shown }
        try? await Task.sleep(nanoseconds: 380_000_000)
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
      finish()
    }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    onFinished()
  }
}

// MARK: Lumon CRT chrome

/// Scanlines + vignette + a whisper of phosphor: enough to read as a tube,
/// not a costume. Static (no flicker), so it's Reduce-Motion safe.
private struct LumonCRTModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .overlay(
        LumonScanlines()
          .opacity(colorScheme == .dark ? 0.05 : 0.025)
          .allowsHitTesting(false)
      )
      .overlay(
        // Corner vignette — the screen curving away from the light.
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.5 : 0.12), lineWidth: 18)
          .blur(radius: 22)
          .allowsHitTesting(false)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder(Lumon.mintText(colorScheme).opacity(0.10), lineWidth: 1)
          .allowsHitTesting(false)
      )
  }
}

private struct LumonScanlines: View {
  var body: some View {
    Canvas { context, size in
      var y: CGFloat = 0
      while y < size.height {
        context.fill(
          Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
          with: .color(.black)
        )
        y += 3
      }
    }
    .drawingGroup()
  }
}

extension View {
  fileprivate func lumonCRT() -> some View {
    modifier(LumonCRTModifier())
  }
}

// MARK: Lumon macrodata field

/// The drifting digit field behind the work: dim, deterministic, and gently
/// restless (each digit breathes on its own phase). `isStatic` renders one
/// motionless frame for Reduce Motion.
private struct LumonDigitField: View {
  @Environment(\.colorScheme) private var colorScheme
  let seed: Int
  let isStatic: Bool

  private let cell: CGFloat = 44

  var body: some View {
    if isStatic {
      field(at: 0)
    } else {
      TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { timeline in
        field(at: timeline.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  private func field(at time: TimeInterval) -> some View {
    Canvas { context, size in
      let columns = Int(size.width / cell)
      let rows = Int(size.height / cell)
      guard columns > 0, rows > 0 else { return }
      for row in 0...rows {
        for column in 0...columns {
          let cellSeed = LumonRefinementCodename.mix(seed, row &* 73 &+ column)
          let digit = cellSeed % 10
          let phase = Double(cellSeed % 628) / 100.0
          let drift = isStatic ? 0 : sin(time * 0.9 + phase) * 2.2
          let x = CGFloat(column) * cell + cell / 2
          let y = CGFloat(row) * cell + cell / 2 + drift
          context.draw(
            Text(String(digit))
              .font(Lumon.mono)
              .foregroundColor(Lumon.ink3(colorScheme).opacity(0.32)),
            at: CGPoint(x: x, y: y)
          )
        }
      }
    }
    .clipped()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

// MARK: Lumon panel + input

/// Official-form panel: paper fill, precise double-line border, and an
/// extremely restrained CRT-style vignette tint.
private struct LumonPanelModifier: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  var fill: ((ColorScheme) -> Color)?

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Lumon.radius + 1, style: .continuous)
    content
      .background(shape.fill(fill?(scheme) ?? Lumon.paper(scheme)))
      .overlay(
        shape
          .fill(
            RadialGradient(
              colors: [.clear, vignette],
              center: .center,
              startRadius: 80,
              endRadius: 480
            )
          )
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      )
      .overlay(shape.strokeBorder(Lumon.line(scheme), lineWidth: 1))
      .overlay(
        shape
          .inset(by: 3)
          .strokeBorder(Lumon.line(scheme).opacity(0.55), lineWidth: 0.75)
          .allowsHitTesting(false)
      )
  }

  private var vignette: Color {
    scheme == .dark ? Color.black.opacity(0.18) : DS.Color.hex(0x103B47).opacity(0.045)
  }
}

private extension View {
  func lumonPanel(fill: ((ColorScheme) -> Color)? = nil) -> some View {
    modifier(LumonPanelModifier(fill: fill))
  }

  /// Text input on the form surface — same metrics as `dsInput`, official chrome.
  func lumonInput(_ scheme: ColorScheme) -> some View {
    textFieldStyle(.plain)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .fill(Lumon.paperDeep(scheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)
          .strokeBorder(Lumon.line(scheme), lineWidth: 1)
      )
  }

  func lumonButton(_ variant: LumonButtonVariant = .primary, size: LumonButtonSize = .regular) -> some View {
    buttonStyle(LumonButtonStyle(variant: variant, size: size))
  }
}

// MARK: Lumon rules + form header

private struct LumonDoubleRule: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(spacing: 2) {
      Rectangle().fill(Lumon.line(scheme)).frame(height: 1)
      Rectangle().fill(Lumon.line(scheme).opacity(0.6)).frame(height: 1)
    }
    .accessibilityHidden(true)
  }
}

/// Centered, numbered form heading with wide letterspacing — each card reads
/// as an official corporate form.
private struct LumonFormHeader: View {
  let number: String
  let title: String
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: 7) {
      Text("Form No. \(number)")
        .font(Lumon.eyebrow)
        .tracking(2.6)
        .textCase(.uppercase)
        .foregroundStyle(Lumon.mintText(scheme))
      Text(title)
        .font(Lumon.formTitle)
        .tracking(2.2)
        .textCase(.uppercase)
        .foregroundStyle(Lumon.ink(scheme))
      LumonDoubleRule()
        .frame(maxWidth: 220)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: Lumon emblem (decorative)

/// Abstract ringed-globe mark for the pane header — concentric circles and
/// latitude bars, pure SwiftUI, no assets. Decorative; hidden from VoiceOver.
private struct LumonEmblem: View {
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(Lumon.ink(scheme), lineWidth: 1.25)
      Circle()
        .inset(by: 4)
        .strokeBorder(Lumon.ink(scheme).opacity(0.5), lineWidth: 0.75)
      VStack(spacing: 3.5) {
        Capsule().fill(Lumon.mintText(scheme)).frame(width: 16, height: 1.5)
        Capsule().fill(Lumon.ink(scheme).opacity(0.75)).frame(width: 24, height: 1.5)
        Capsule().fill(Lumon.mintText(scheme)).frame(width: 16, height: 1.5)
      }
    }
    .frame(width: 44, height: 44)
    .accessibilityHidden(true)
  }
}

// MARK: Lumon stamp

/// Small bordered status stamp ("IN EFFECT", "ACTIVE NOW"): the state is also
/// carried by the text itself, never color alone.
private struct LumonStamp: View {
  let text: String
  var active = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Text(text)
      .font(Lumon.micro)
      .tracking(1.6)
      .textCase(.uppercase)
      .foregroundStyle(active ? Lumon.mintText(scheme) : Lumon.ink3(scheme))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .overlay(
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .strokeBorder(
            (active ? Lumon.mintText(scheme) : Lumon.ink3(scheme)).opacity(0.65),
            lineWidth: 1
          )
      )
  }
}

// MARK: Lumon ceremonial switch

/// The plaque-and-stamp treatment for a deliberate binary state: an eyebrow
/// caption, the switch itself, and a bordered status stamp underneath. The
/// state is always carried by the stamp text, never color alone.
private struct LumonCeremonialSwitch: View {
  let eyebrow: String
  let toggleLabel: String
  @Binding var isOn: Bool
  let stampOn: String
  let stampOff: String
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: 7) {
      Text(eyebrow)
        .font(Lumon.eyebrow)
        .tracking(2.6)
        .textCase(.uppercase)
        .foregroundStyle(Lumon.mintText(scheme))
      Toggle(toggleLabel, isOn: $isOn)
        .toggleStyle(.switch)
        .tint(Lumon.mintDeep)
        .font(Lumon.label)
        .foregroundStyle(Lumon.ink(scheme))
      LumonStamp(text: isOn ? stampOn : stampOff, active: isOn)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .lumonPanel()
  }
}

// MARK: Lumon badge (avatar)

/// Monogram in a double-ringed circle — the corporate ID-badge portrait.
private struct LumonBadge: View {
  let text: String
  var tint: Color?
  var size: CGFloat = 34
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Text(text)
      .font(.system(size: size * 0.32, weight: .medium, design: .monospaced))
      .foregroundStyle(tint ?? Lumon.ink2(scheme))
      .frame(width: size, height: size)
      .background(Circle().fill(Lumon.well(scheme)))
      .overlay(Circle().strokeBorder(Lumon.line(scheme), lineWidth: 1))
      .overlay(
        Circle()
          .inset(by: 2.5)
          .strokeBorder(Lumon.line(scheme).opacity(0.5), lineWidth: 0.75)
      )
  }
}

// MARK: Lumon buttons

private enum LumonButtonVariant {
  case primary    // deep navy fill, seafoam text (dark mode inverts to mint)
  case secondary  // paper fill, double-line border
  case ghost      // text-only, faint fill on hover
}

private enum LumonButtonSize {
  case regular
  case small
}

private struct LumonButtonStyle: ButtonStyle {
  var variant: LumonButtonVariant = .primary
  var size: LumonButtonSize = .regular

  func makeBody(configuration: Configuration) -> some View {
    LumonButtonBody(configuration: configuration, variant: variant, size: size)
  }
}

private struct LumonButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let variant: LumonButtonVariant
  let size: LumonButtonSize

  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  var body: some View {
    let pressed = configuration.isPressed && isEnabled
    let shape = RoundedRectangle(cornerRadius: Lumon.radius, style: .continuous)

    configuration.label
      .font(size == .small ? Lumon.buttonSmall : Lumon.button)
      .textCase(.uppercase)
      .labelStyle(LumonButtonLabelStyle())
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, size == .small ? 10 : 13)
      .frame(height: size == .small ? 24 : 28)
      .background(
        ZStack {
          shape.fill(fill(pressed: pressed))
          if variant != .ghost {
            shape.strokeBorder(border, lineWidth: 1)
            shape
              .inset(by: 2)
              .strokeBorder(innerBorder, lineWidth: 0.75)
          }
        }
      )
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.45)
      .dsAnimation(.easeOut(duration: 0.1), value: pressed)
      .onHover { hovering = $0 }
  }

  private var foreground: Color {
    switch variant {
    case .primary:
      return scheme == .dark ? Lumon.inkOnMint : DS.Color.hex(0xC9EFE3)
    case .secondary:
      return Lumon.ink(scheme)
    case .ghost:
      return hovering && isEnabled ? Lumon.ink(scheme) : Lumon.ink2(scheme)
    }
  }

  private func fill(pressed: Bool) -> Color {
    switch variant {
    case .primary:
      if scheme == .dark {
        if pressed { return DS.Color.hex(0x6FC9B1) }
        return hovering && isEnabled ? DS.Color.hex(0x9FE7D2) : DS.Color.hex(0x8FE0CB)
      } else {
        if pressed { return DS.Color.hex(0x092630) }
        return hovering && isEnabled ? DS.Color.hex(0x0D323C) : DS.Color.hex(0x103B47)
      }
    case .secondary:
      if pressed { return Lumon.well(scheme) }
      return hovering && isEnabled ? Lumon.well(scheme) : Lumon.paperDeep(scheme)
    case .ghost:
      if pressed { return Lumon.ink(scheme).opacity(0.10) }
      return hovering && isEnabled ? Lumon.ink(scheme).opacity(0.06) : .clear
    }
  }

  private var border: Color {
    switch variant {
    case .primary:
      return scheme == .dark ? DS.Color.hex(0x8FE0CB).opacity(0.9) : DS.Color.hex(0x103B47)
    case .secondary, .ghost:
      return Lumon.line(scheme)
    }
  }

  private var innerBorder: Color {
    switch variant {
    case .primary:
      return scheme == .dark ? Lumon.inkOnMint.opacity(0.3) : DS.Color.hex(0xC9EFE3).opacity(0.35)
    case .secondary, .ghost:
      return Lumon.line(scheme).opacity(0.45)
    }
  }
}

/// Keeps a Lumon button's leading SF Symbol sized + spaced with its title.
private struct LumonButtonLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: 10, weight: .medium))
      configuration.title
    }
  }
}

// MARK: - First-open intro (registered in ToolRegistry)

extension WorkPersonalView {
  /// Registry hook for the first-open intro sheet. The Lumon kit stays
  /// file-private; only an opaque AnyView crosses the file boundary.
  static func makeIntro(_ actions: LabIntroActions) -> AnyView {
    AnyView(SeveranceIntroView(actions: actions))
  }
}

/// Orientation paperwork: the intro reads as an official Lumon form —
/// emblem, wide-tracked title, double rules, deadpan clauses, stamp-square
/// buttons. The drama is in the restraint.
private struct SeveranceIntroView: View {
  let actions: LabIntroActions
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack {
      Lumon.canvas(scheme)
      VStack(spacing: 0) {
        LumonEmblem()

        Text("Form No. 7-C — Orientation")
          .font(Lumon.eyebrow)
          .tracking(2.6)
          .textCase(.uppercase)
          .foregroundStyle(Lumon.mintText(scheme))
          .padding(.top, 16)

        Text("Macrodata Refinement")
          .font(Lumon.display)
          .tracking(3.5)
          .textCase(.uppercase)
          .foregroundStyle(Lumon.ink(scheme))
          .padding(.top, 8)

        LumonDoubleRule()
          .frame(maxWidth: 280)
          .padding(.top, 14)

        Text("Your conversations are mysterious and important. Sort them.")
          .font(Lumon.label)
          .foregroundStyle(Lumon.ink2(scheme))
          .multilineTextAlignment(.center)
          .padding(.top, 18)

        VStack(alignment: .leading, spacing: 12) {
          clause("01", "Assign each conversation to Work or Personal. Once is sufficient.")
          clause("02", "Messages thereafter filters strictly: All, Work, or Personal.")
          clause("03", "A schedule may sever and rejoin you at the appointed hours.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumonPanel()
        .padding(.top, 22)

        Spacer(minLength: 16)

        LumonDoubleRule()
          .frame(maxWidth: 280)

        Text("All records remain on this Mac. The Board cannot read them.")
          .font(Lumon.micro)
          .tracking(1.4)
          .textCase(.uppercase)
          .foregroundStyle(Lumon.ink3(scheme))
          .padding(.top, 12)

        HStack(spacing: 12) {
          Button("Return to lobby") { actions.onCancel() }
            .lumonButton(.ghost)
            .accessibilityLabel("Return to lobby")
          Button("Enter the terminal") { actions.onContinue() }
            .lumonButton(.primary)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue to Severance")
        }
        .padding(.top, 16)
      }
      .padding(36)
    }
  }

  private func clause(_ number: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(number)
        .font(Lumon.mono)
        .foregroundStyle(Lumon.mintText(scheme))
      Text(text)
        .font(Lumon.caption)
        .foregroundStyle(Lumon.ink2(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
