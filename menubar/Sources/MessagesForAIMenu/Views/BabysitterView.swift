import SwiftUI
import UniformTypeIdentifiers

struct BabysitterView: View {
  @StateObject private var store: BabysitterStore
  @StateObject private var controller: BabysitterController

  @EnvironmentObject private var draftStore: DraftStore
  @Environment(\.colorScheme) private var colorScheme

  @State private var contactQuery = ""
  @State private var selectedProfileID: String?
  @State private var editRate = ""
  @State private var editTags = ""
  @State private var editNotes = ""
  @State private var editActive = true

  @State private var startsAt = Date().addingTimeInterval(24 * 60 * 60)
  @State private var endsAt = Date().addingTimeInterval(27 * 60 * 60)
  @State private var requestNote = ""
  @State private var partnerQuery = ""
  @State private var selectedPartner: BabysitterContactSnapshot?
  @State private var requestOrder: [String] = []
  @State private var disabledForRequest = Set<String>()
  @State private var replyText = ""
  @State private var draggedProfileID: String?

  init() {
    let store = BabysitterStore()
    _store = StateObject(wrappedValue: store)
    _controller = StateObject(wrappedValue: BabysitterController(store: store))
  }

  private var contactMatches: [ContactMatch] {
    let query = contactQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else { return [] }
    return ContactsExporter.searchContacts(query, limit: 10)
  }

  private var partnerMatches: [ContactMatch] {
    let query = partnerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else { return [] }
    return ContactsExporter.searchContacts(query, limit: 8)
  }

  private var selectedProfile: BabysitterProfile? {
    guard let selectedProfileID else { return store.profiles.first }
    return store.profile(id: selectedProfileID)
  }

  private var requestDateBinding: Binding<Date> {
    Binding(
      get: { startsAt },
      set: { setRequestDate($0) }
    )
  }

  private var startMinuteBinding: Binding<Int> {
    Binding(
      get: { Self.minutesFromMidnight(startsAt) },
      set: { setStartTime(minutesFromMidnight: $0) }
    )
  }

  private var endMinuteBinding: Binding<Int> {
    Binding(
      get: { Self.minutesFromMidnight(endsAt) },
      set: { setEndTime(minutesFromMidnight: $0) }
    )
  }

  var body: some View {
    HStack(spacing: 0) {
      rosterPane
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 390)
      Rectangle().fill(DS.Color.line(colorScheme)).frame(width: 1)
      requestPane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(DS.Color.g100(colorScheme))
    .onAppear {
      normalizeRequestTimes()
      syncRequestOrder(resetToDefault: true)
      loadSelectedProfileFields()
      controller.reconcileSentDrafts(draftStore.drafts)
      controller.checkTimeouts()
    }
    .onChange(of: store.profiles.map { "\($0.id):\($0.defaultRank):\($0.isActive)" }) { _, _ in
      syncRequestOrder(resetToDefault: true)
    }
    .onChange(of: selectedProfileID) { _, _ in loadSelectedProfileFields() }
    .onChange(of: draftStore.drafts.map { "\($0.id):\($0.sent_at ?? "")" }) { _, _ in
      controller.reconcileSentDrafts(draftStore.drafts)
      controller.checkTimeouts()
    }
  }

  private var rosterPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      header(title: "Babysitters", subtitle: "\(store.profiles.count) saved")

      ContactsPermissionBanner()

      VStack(alignment: .leading, spacing: 8) {
        TextField("Search Contacts", text: $contactQuery)
          .textFieldStyle(.roundedBorder)
        if contactQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
          ForEach(contactMatches) { match in
            if let handle = match.bestHandle {
              contactResult(match: match, handle: handle) {
                addContact(match)
              }
            }
          }
          if contactMatches.isEmpty {
            mutedText("No matching contacts.")
          }
        }
      }

      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
            rosterRow(profile, index: index)
              .onDrag {
                draggedProfileID = profile.id
                return NSItemProvider(object: profile.id as NSString)
              }
              .onDrop(
                of: [UTType.text],
                delegate: BabysitterRosterDropDelegate(
                  targetID: profile.id,
                  draggedProfileID: $draggedProfileID,
                  store: store,
                  onReorder: { syncRequestOrder(resetToDefault: true) }
                )
              )
          }
        }
      }

      if let profile = selectedProfile {
        profileEditor(profile)
      }
    }
    .padding(18)
  }

  private var requestPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header(title: "New Request", subtitle: activeRequestSubtitle)
        if let error = controller.errorMessage ?? store.lastError {
          statusBanner(error, systemImage: "exclamationmark.triangle.fill", color: DS.Color.amber(colorScheme))
        } else if let status = controller.statusMessage {
          statusBanner(status, systemImage: "checkmark.circle.fill", color: DS.Color.green(colorScheme))
        }

        if let request = store.activeRequest {
          activeRequestPanel(request)
        } else {
          newRequestForm
        }

        statsPanel
      }
      .padding(22)
    }
  }

  private var newRequestForm: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionTitle("Details", systemImage: "calendar")
      scheduleControls
      TextField("Optional note", text: $requestNote, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)

      sectionTitle("Partner CC", systemImage: "person.2")
      if let partner = selectedPartner {
        selectedContactPill(name: partner.name, handle: partner.bestHandle) {
          selectedPartner = nil
        }
      } else {
        TextField("Search partner contact", text: $partnerQuery)
          .textFieldStyle(.roundedBorder)
        ForEach(partnerMatches) { match in
          if let handle = match.bestHandle {
            contactResult(match: match, handle: handle) {
              selectedPartner = try? BabysitterContactSnapshot.make(match: match, handle: handle)
              partnerQuery = ""
            }
          }
        }
      }

      sectionTitle("Rank Order", systemImage: "list.number")
      if activeRequestProfiles.isEmpty {
        mutedText("Add active babysitters to the roster first.")
      } else {
        ForEach(Array(requestOrder.enumerated()), id: \.element) { index, id in
          if let profile = store.profile(id: id) {
            requestOrderRow(profile: profile, index: index)
          }
        }
      }

      Button {
        createRequest()
      } label: {
        Label("Create Request", systemImage: "plus.circle.fill")
      }
      .dsButton(.primary)
      .disabled(!canCreateRequest)
    }
    .toolPanel(colorScheme)
  }

  private func activeRequestPanel(_ request: BabysitterRequest) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionTitle("Current Request", systemImage: "figure.and.child.holdinghands")
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(requestWindowText(request))
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text(request.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
        Button("Cancel") { controller.cancelActiveRequest() }
          .dsButton(.secondary, size: .small)
      }

      if let partner = request.partner {
        selectedContactPill(name: partner.name, handle: partner.bestHandle, onClear: nil)
      }

      if let activeID = request.activeSitterID, let profile = store.profile(id: activeID) {
        HStack(spacing: 10) {
          rankBadge(request.currentIndex + 1)
          VStack(alignment: .leading, spacing: 2) {
            Text(profile.contact.name)
              .font(DS.Font.rowTitle)
              .foregroundStyle(DS.Color.ink(colorScheme))
            Text(profile.displayHandle)
              .font(DS.Font.monoMicro)
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
          Spacer()
          Button("Stage Ask") {
            Task { _ = await controller.stageNextAsk(draftStore: draftStore) }
          }
          .dsButton(.primary, size: .small)
          .disabled(request.status == .waiting && request.outreaches.contains(where: { $0.status == .staged || $0.status == .waiting }))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.Color.g080(colorScheme)))
        .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.row)
      }

      outreachList(request)
    }
    .toolPanel(colorScheme)
  }

  private func outreachList(_ request: BabysitterRequest) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if request.outreaches.isEmpty {
        mutedText("No asks staged yet.")
      }
      ForEach(request.outreaches.reversed()) { outreach in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(store.profile(id: outreach.sitterID)?.contact.name ?? "Babysitter")
              .font(DS.Font.settingsLabel)
              .foregroundStyle(DS.Color.ink(colorScheme))
            Spacer()
            Text(outreach.status.rawValue.replacingOccurrences(of: "_", with: " "))
              .font(DS.Font.chip)
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
          if outreach.status == .waiting || outreach.status == .staged || outreach.status == .needsUser {
            HStack(spacing: 8) {
              Button("Yes") { controller.mark(outreach: outreach, outcome: .accepted) }
                .dsButton(.secondary, size: .small)
              Button("No") { controller.mark(outreach: outreach, outcome: .declined) }
                .dsButton(.secondary, size: .small)
              Button("Timeout") { controller.mark(outreach: outreach, outcome: .timedOut) }
                .dsButton(.secondary, size: .small)
            }
            HStack(spacing: 8) {
              TextField("Paste reply to classify", text: $replyText)
                .textFieldStyle(.roundedBorder)
              Button("Classify") {
                classifyReply(outreach)
              }
              .dsButton(.secondary, size: .small)
            }
          }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.Color.g080(colorScheme)))
        .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.row)
      }
    }
  }

  private var statsPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("Roster Stats", systemImage: "chart.bar")
      if store.profiles.isEmpty {
        mutedText("Stats will appear after Babysitter stages asks.")
      } else {
        ForEach(store.profiles) { profile in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(profile.contact.name)
                .font(DS.Font.settingsLabel)
                .foregroundStyle(DS.Color.ink(colorScheme))
              Text(profile.tags.isEmpty ? "No tags" : profile.tags.joined(separator: ", "))
                .font(DS.Font.settingsCaption)
                .foregroundStyle(DS.Color.ink3(colorScheme))
            }
            Spacer()
            metric("\(profile.stats.asksSent)", "asks")
            metric(rateText(profile.stats.acceptanceRate), "accept")
            metric(durationText(profile.stats.medianResponseSeconds), "typical")
          }
          .padding(.vertical, 6)
        }
      }
    }
    .toolPanel(colorScheme)
  }

  private func rosterRow(_ profile: BabysitterProfile, index: Int) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .help("Drag to reorder the default babysitter rank")
      Button {
        selectedProfileID = profile.id
      } label: {
        HStack(spacing: 10) {
          rankBadge(profile.defaultRank + 1)
          VStack(alignment: .leading, spacing: 3) {
            Text(profile.contact.name)
              .font(DS.Font.settingsLabel)
              .foregroundStyle(DS.Color.ink(colorScheme))
              .lineLimit(1)
            Text(profile.rate.isEmpty ? profile.displayHandle : "\(profile.rate) · \(profile.displayHandle)")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .lineLimit(1)
          }
          Spacer()
        }
      }
      .buttonStyle(.plain)

      Button {
        selectedProfileID = profile.id
      } label: {
        Image(systemName: profile.isActive ? "checkmark.circle.fill" : "pause.circle.fill")
          .foregroundStyle(profile.isActive ? DS.Color.green(colorScheme) : DS.Color.ink3(colorScheme))
      }
      .buttonStyle(.plain)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .fill(selectedProfileID == profile.id ? DS.Color.accentTeal(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12) : DS.Color.g080(colorScheme))
    )
    .dsHairline(
      colorScheme,
      selectedProfileID == profile.id ? { scheme in DS.Color.accentTeal(scheme).opacity(0.45) } : DS.Color.line,
      radius: DS.Radius.row
    )
  }

  private var scheduleControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      DatePicker("Date", selection: requestDateBinding, displayedComponents: .date)
        .datePickerStyle(.compact)
      HStack(spacing: 12) {
        Picker("Start", selection: startMinuteBinding) {
          ForEach(Self.quarterHourSlots, id: \.self) { minutes in
            Text(Self.timeSlotLabel(minutes)).tag(minutes)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 150)
        Picker("End", selection: endMinuteBinding) {
          ForEach(Self.quarterHourSlots, id: \.self) { minutes in
            Text(Self.timeSlotLabel(minutes)).tag(minutes)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 150)
        if !Calendar.current.isDate(startsAt, inSameDayAs: endsAt) {
          Text("next day")
            .font(DS.Font.chip)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
      }
    }
  }

  private func profileEditor(_ profile: BabysitterProfile) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("Profile", systemImage: "person.text.rectangle")
      Toggle("Active", isOn: $editActive)
      TextField("Rate", text: $editRate)
        .textFieldStyle(.roundedBorder)
      TextField("Tags, comma separated", text: $editTags)
        .textFieldStyle(.roundedBorder)
      TextField("Notes", text: $editNotes, axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Save") { saveProfile(profile) }
          .dsButton(.primary, size: .small)
        Button("Remove") { removeProfile(profile) }
          .dsButton(.secondary, size: .small)
      }
    }
    .toolPanel(colorScheme)
  }

  private func contactResult(match: ContactMatch, handle: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Image(systemName: "person.crop.circle.badge.plus")
          .foregroundStyle(DS.Color.accentTeal(colorScheme))
        VStack(alignment: .leading, spacing: 2) {
          Text(match.name).font(DS.Font.settingsLabel).foregroundStyle(DS.Color.ink(colorScheme))
          Text(handle).font(DS.Font.monoMicro).foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.Color.g080(colorScheme)))
    }
    .buttonStyle(.plain)
  }

  private func requestOrderRow(profile: BabysitterProfile, index: Int) -> some View {
    HStack(spacing: 10) {
      Toggle("", isOn: Binding(
        get: { !disabledForRequest.contains(profile.id) },
        set: { enabled in
          if enabled { disabledForRequest.remove(profile.id) } else { disabledForRequest.insert(profile.id) }
        }
      ))
      .labelsHidden()
      rankBadge(index + 1)
      Text(profile.contact.name)
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Spacer()
      Button { moveRequestProfile(id: profile.id, delta: -1) } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.plain)
      .disabled(index == 0)
      Button { moveRequestProfile(id: profile.id, delta: 1) } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.plain)
      .disabled(index == requestOrder.count - 1)
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.Color.g080(colorScheme)))
  }

  private func selectedContactPill(name: String, handle: String, onClear: (() -> Void)?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "person.2.fill")
        .foregroundStyle(DS.Color.accentTeal(colorScheme))
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(DS.Font.settingsLabel).foregroundStyle(DS.Color.ink(colorScheme))
        Text(handle).font(DS.Font.monoMicro).foregroundStyle(DS.Color.ink3(colorScheme))
      }
      Spacer()
      if let onClear {
        Button(action: onClear) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.Color.g080(colorScheme)))
    .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.row)
  }

  private func sectionTitle(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: systemImage)
        .foregroundStyle(DS.Color.accentTeal(colorScheme))
      Text(title)
        .font(DS.Font.groupLabel)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Rectangle().fill(DS.Color.line(colorScheme)).frame(height: 1)
    }
  }

  private func header(title: String, subtitle: String) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(DS.Font.paneTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text(subtitle)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      Spacer()
    }
  }

  private func statusBanner(_ text: String, systemImage: String, color: Color) -> some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage).foregroundStyle(color)
      Text(text)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Spacer()
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.Color.g080(colorScheme)))
    .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.row)
  }

  private func rankBadge(_ rank: Int) -> some View {
    Text("\(rank)")
      .font(DS.Font.monoMicro)
      .foregroundStyle(DS.Color.accentTeal(colorScheme))
      .frame(width: 24, height: 24)
      .background(Circle().fill(DS.Color.accentTeal(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12)))
  }

  private func mutedText(_ text: String) -> some View {
    Text(text)
      .font(DS.Font.settingsCaption)
      .foregroundStyle(DS.Color.ink3(colorScheme))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
  }

  private func metric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(value).font(DS.Font.monoValue).foregroundStyle(DS.Color.ink(colorScheme))
      Text(label).font(DS.Font.monoMicro).foregroundStyle(DS.Color.ink3(colorScheme))
    }
    .frame(width: 58, alignment: .trailing)
  }

  private var activeRequestProfiles: [BabysitterProfile] {
    store.activeProfiles
  }

  private var canCreateRequest: Bool {
    endsAt > startsAt && requestOrder.contains { !disabledForRequest.contains($0) }
  }

  private var activeRequestSubtitle: String {
    if let request = store.activeRequest {
      return request.status == .waiting ? "waiting for reply" : request.status.rawValue.replacingOccurrences(of: "_", with: " ")
    }
    return "one active request at a time"
  }

  private func addContact(_ match: ContactMatch) {
    do {
      let profile = try store.addContact(match)
      selectedProfileID = profile.id
      contactQuery = ""
      syncRequestOrder()
    } catch {
      controller.errorMessage = String(describing: error)
    }
  }

  private func loadSelectedProfileFields() {
    guard let profile = selectedProfile else { return }
    selectedProfileID = profile.id
    editRate = profile.rate
    editTags = profile.tags.joined(separator: ", ")
    editNotes = profile.notes
    editActive = profile.isActive
  }

  private func saveProfile(_ profile: BabysitterProfile) {
    do {
      try store.updateProfile(
        id: profile.id,
        rate: editRate,
        tags: editTags.split(separator: ",").map(String.init),
        notes: editNotes,
        preferredHandle: profile.preferredHandle,
        isActive: editActive
      )
      controller.statusMessage = "Saved \(profile.contact.name)."
      syncRequestOrder()
    } catch {
      controller.errorMessage = String(describing: error)
    }
  }

  private func removeProfile(_ profile: BabysitterProfile) {
    do {
      try store.removeProfile(id: profile.id)
      selectedProfileID = store.profiles.first?.id
      syncRequestOrder()
    } catch {
      controller.errorMessage = String(describing: error)
    }
  }

  private func createRequest() {
    do {
      let ids = requestOrder.filter { !disabledForRequest.contains($0) }
      _ = try store.createRequest(
        startsAt: startsAt,
        endsAt: endsAt,
        note: requestNote,
        partner: selectedPartner,
        orderedSitterIDs: ids
      )
      controller.statusMessage = "Request ready. Stage the first ask when you're ready."
      controller.errorMessage = nil
    } catch {
      controller.errorMessage = String(describing: error)
    }
  }

  private func classifyReply(_ outreach: BabysitterOutreach) {
    switch BabysitterReplyClassifier.classify(replyText) {
    case .accept:
      controller.mark(outreach: outreach, outcome: .accepted)
    case .decline:
      controller.mark(outreach: outreach, outcome: .declined)
    case .ambiguous:
      controller.mark(outreach: outreach, outcome: .needsUser)
    }
    replyText = ""
  }

  private func syncRequestOrder(resetToDefault: Bool = false) {
    let activeIDs = store.activeProfiles.map(\.id)
    if resetToDefault {
      requestOrder = activeIDs
      disabledForRequest = disabledForRequest.intersection(Set(activeIDs))
      return
    }
    requestOrder = requestOrder.filter { activeIDs.contains($0) }
    for id in activeIDs where !requestOrder.contains(id) {
      requestOrder.append(id)
    }
    disabledForRequest = disabledForRequest.intersection(Set(activeIDs))
  }

  private func moveRequestProfile(id: String, delta: Int) {
    guard let idx = requestOrder.firstIndex(of: id) else { return }
    let next = idx + delta
    guard requestOrder.indices.contains(next) else { return }
    requestOrder.swapAt(idx, next)
  }

  private func normalizeRequestTimes() {
    let snappedStart = Self.roundedUpToQuarterHour(startsAt)
    startsAt = snappedStart
    endsAt = snappedStart.addingTimeInterval(Self.defaultDurationSeconds)
  }

  private func setRequestDate(_ date: Date) {
    let startMinutes = Self.minutesFromMidnight(startsAt)
    let endMinutes = Self.minutesFromMidnight(endsAt)
    let wasOvernight = !Calendar.current.isDate(startsAt, inSameDayAs: endsAt)
    let newStart = Self.date(onDayOf: date, minutesFromMidnight: startMinutes)
    var newEnd = Self.date(onDayOf: date, minutesFromMidnight: endMinutes)
    if wasOvernight || newEnd <= newStart {
      newEnd = Calendar.current.date(byAdding: .day, value: 1, to: newEnd) ?? newEnd.addingTimeInterval(24 * 60 * 60)
    }
    startsAt = newStart
    endsAt = newEnd
  }

  private func setStartTime(minutesFromMidnight minutes: Int) {
    let newStart = Self.date(onDayOf: startsAt, minutesFromMidnight: minutes)
    startsAt = newStart
    endsAt = newStart.addingTimeInterval(Self.defaultDurationSeconds)
  }

  private func setEndTime(minutesFromMidnight minutes: Int) {
    var newEnd = Self.date(onDayOf: startsAt, minutesFromMidnight: minutes)
    if newEnd <= startsAt {
      newEnd = Calendar.current.date(byAdding: .day, value: 1, to: newEnd) ?? newEnd.addingTimeInterval(24 * 60 * 60)
    }
    endsAt = newEnd
  }

  private func requestWindowText(_ request: BabysitterRequest) -> String {
    guard let start = BabysitterStore.parseISO(request.startsAt),
          let end = BabysitterStore.parseISO(request.endsAt) else {
      return "Request"
    }
    let suffix = Calendar.current.isDate(start, inSameDayAs: end) ? "" : " next day"
    return "\(Self.dayFormatter.string(from: start)) · \(Self.timeFormatter.string(from: start))-\(Self.timeFormatter.string(from: end))\(suffix)"
  }

  private func rateText(_ rate: Double?) -> String {
    guard let rate else { return "-" }
    return "\(Int((rate * 100).rounded()))%"
  }

  private func durationText(_ seconds: Double?) -> String {
    guard let seconds else { return "-" }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h"
  }

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
  }()

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
  }()

  static let defaultDurationSeconds: TimeInterval = 3 * 60 * 60
  static let timeStepMinutes = 15
  static let minutesPerDay = 24 * 60
  static let quarterHourSlots = Array(stride(from: 0, to: minutesPerDay, by: timeStepMinutes))

  static func roundedUpToQuarterHour(_ date: Date, calendar: Calendar = .current) -> Date {
    let minutes = minutesFromMidnight(date, calendar: calendar)
    let remainder = minutes % timeStepMinutes
    let roundedMinutes = remainder == 0 ? minutes : minutes + (timeStepMinutes - remainder)
    let day = calendar.startOfDay(for: date)
    if roundedMinutes >= minutesPerDay {
      return calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(24 * 60 * 60)
    }
    return calendar.date(byAdding: .minute, value: roundedMinutes, to: day) ?? date
  }

  static func minutesFromMidnight(_ date: Date, calendar: Calendar = .current) -> Int {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
  }

  static func date(
    onDayOf day: Date,
    minutesFromMidnight minutes: Int,
    calendar: Calendar = .current
  ) -> Date {
    let startOfDay = calendar.startOfDay(for: day)
    return calendar.date(byAdding: .minute, value: minutes, to: startOfDay) ?? startOfDay
  }

  static func timeSlotLabel(_ minutes: Int) -> String {
    timeFormatter.string(from: date(onDayOf: Date(), minutesFromMidnight: minutes))
  }

  static func makeIntro(_ actions: LabIntroActions) -> AnyView {
    AnyView(BabysitterIntroView(actions: actions))
  }
}

private extension View {
  func toolPanel(_ colorScheme: ColorScheme) -> some View {
    self
      .padding(14)
      .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Color.g130(colorScheme)))
      .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.card)
  }
}

private struct BabysitterRosterDropDelegate: DropDelegate {
  let targetID: String
  @Binding var draggedProfileID: String?
  let store: BabysitterStore
  let onReorder: () -> Void

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func dropEntered(info: DropInfo) {
    guard let draggedProfileID,
          draggedProfileID != targetID,
          let sourceIndex = store.profiles.firstIndex(where: { $0.id == draggedProfileID }),
          let targetIndex = store.profiles.firstIndex(where: { $0.id == targetID }) else {
      return
    }
    store.reorderProfiles(
      from: IndexSet(integer: sourceIndex),
      to: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
    )
    onReorder()
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedProfileID = nil
    return true
  }
}

private struct BabysitterIntroView: View {
  let actions: LabIntroActions
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Spacer()
      Image(systemName: "figure.and.child.holdinghands")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(DS.Color.accentTeal(colorScheme))
      Text("Babysitter")
        .font(.system(size: 36, weight: .bold))
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("A local roster and one-at-a-time request flow for finding babysitting coverage through Messages.")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink2(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Start") { actions.onContinue() }
          .dsButton(.primary)
        Button("Not Now") { actions.onCancel() }
          .dsButton(.secondary)
      }
      Spacer()
    }
    .padding(34)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(DS.Color.g100(colorScheme))
  }
}
