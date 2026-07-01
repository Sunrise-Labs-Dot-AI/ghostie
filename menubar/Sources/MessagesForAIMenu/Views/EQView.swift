import SwiftUI
import AppKit

struct EQView: View {
  @StateObject private var controller = EQController()
  @State private var selectedPersonID: Int?
  @State private var relationshipType: EQRelationshipType = .friend
  @State private var customRelationship = ""
  @State private var contextDepth: EQContextDepth = .threadArc
  @State private var selectedPresetID = EQPreset.all[0].id
  @State private var presetCategory: EQPresetCategory = EQPreset.all[0].category
  @State private var search = ""
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var aiUsageLedger: AIUsageLedger

  private var selectedPerson: EQPerson? {
    controller.people.first { $0.id == selectedPersonID }
  }

  private var selectedPreset: EQPreset {
    EQPreset.all.first { $0.id == selectedPresetID } ?? EQPreset.all[0]
  }

  // Preset prompts only — a free-text prompt let users (or pasted text)
  // steer the model's relationship analysis arbitrarily, which is an
  // injection surface on a feature that reads private conversations.
  private var effectivePrompt: String {
    let raw = selectedPreset.prompt
    guard let selectedPerson else { return raw }
    return raw.replacingOccurrences(of: "{person}", with: selectedPerson.displayName)
  }

  private var effectiveRelationship: String {
    switch relationshipType {
    case .other:
      let custom = customRelationship.trimmingCharacters(in: .whitespacesAndNewlines)
      return custom.isEmpty ? "Other" : custom
    default:
      return relationshipType.rawValue
    }
  }

  private var filteredPeople: [EQPerson] {
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return controller.people }
    return controller.people.filter {
      $0.displayName.lowercased().contains(q) || $0.handle.lowercased().contains(q)
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      peoplePane
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        .background(Office.bookPaper(colorScheme))
      Rectangle()
        .fill(Office.line(colorScheme))
        .frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          header
            .fullDiskAccessGate(toolName: "EQ")
          privacyNote
          promptControls
          preview
          report
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(officeWall)
    }
    // Tint the console rail + titlebar strip to match this lab's canvas.
    .consoleChromeBackground(Office.canvasTop(colorScheme))
    .onAppear {
      controller.usageLedger = aiUsageLedger
      if controller.people.isEmpty {
        controller.loadPeople()
      }
    }
    .onChange(of: selectedPersonID) { _, _ in
      controller.preview(selectedPerson)
      controller.clearReport()
    }
    .onChange(of: selectedPresetID) { _, _ in
      controller.clearReport()
    }
  }

  /// The room itself: warm cream falling into linen, with a soft lamp glow
  /// pooling in from the upper corner. Decorative only.
  private var officeWall: some View {
    ZStack {
      LinearGradient(
        colors: [Office.canvasTop(colorScheme), Office.canvasBottom(colorScheme)],
        startPoint: .top,
        endPoint: .bottom
      )
      RadialGradient(
        colors: [Office.lampGlow(colorScheme), Color.clear],
        center: .topTrailing,
        startRadius: 40,
        endRadius: 520
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }

  // MARK: Appointment book (people pane)

  private var peoplePane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Appointment Book")
        .font(Office.bookLabel)
        .tracking(2.2)
        .textCase(.uppercase)
        .foregroundStyle(Office.walnut(colorScheme))
        .padding(.horizontal, 18)
        .padding(.top, 18)

      TextField("Search people", text: $search)
        .officeInput(colorScheme)
        .padding(.horizontal, 16)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 3) {
          ForEach(filteredPeople) { person in
            Button {
              withAnimation(DS.motion(reduceMotion, .easeInOut(duration: 0.28))) {
                selectedPersonID = person.id
              }
            } label: {
              personRow(person)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(person.displayName)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }

      if controller.isBusy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Working...")
            .font(Office.caption)
            .foregroundStyle(Office.ink3(colorScheme))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
      }
    }
  }

  private func personRow(_ person: EQPerson) -> some View {
    let selected = selectedPersonID == person.id
    return HStack(spacing: 0) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(selected ? Office.sage(colorScheme) : Color.clear)
        .frame(width: 3)
        .padding(.vertical, 8)
      VStack(alignment: .leading, spacing: 4) {
        Text(person.displayName)
          .font(Office.rowTitle)
          .foregroundStyle(selected ? Office.ink(colorScheme) : Office.ink2(colorScheme))
          .lineLimit(1)
        HStack(spacing: 6) {
          Text("\(person.messageCount) MSG")
          Text("·")
          Text(relative(person.lastMessageAt).uppercased())
        }
        .font(Office.micro)
        .tracking(0.6)
        // ink3 lands ~3.2:1 on the sage-tinted selected fill in dark, so the
        // meta line steps up to ink2 (≥5:1) when the row is selected.
        .foregroundStyle(selected ? Office.ink2(colorScheme) : Office.ink3(colorScheme))
        .lineLimit(1)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Office.rowRadius, style: .continuous)
        .fill(selected ? Office.sageDim(colorScheme) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Office.rowRadius, style: .continuous)
        .strokeBorder(selected ? Office.sageRail(colorScheme) : Color.clear, lineWidth: 1)
    )
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .top, spacing: 16) {
      OfficePlantView(size: 48)
        .officeSway()
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 5) {
        Text("EQ")
          .font(Office.title)
          .foregroundStyle(Office.ink(colorScheme))
        Text("Pick a person, choose the relationship context, and generate a private reflection report that looks for bids, care, repair, and blind spots.")
          .font(Office.caption)
          .foregroundStyle(Office.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button {
        controller.loadPeople()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .officeButton(.secondary)
      .disabled(controller.isBusy)
    }
  }

  private var privacyNote: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: controller.hasAnyAPIKey ? "sparkles" : "exclamationmark.triangle.fill")
        .foregroundStyle(controller.hasAnyAPIKey ? Office.sage(colorScheme) : DS.Color.amber(colorScheme))
      VStack(alignment: .leading, spacing: 4) {
        Text(controller.status.label)
          .font(Office.label)
          .foregroundStyle(Office.ink(colorScheme))
        Text(controller.hasAnyAPIKey
          ? "EQ sends selected raw excerpts from the chosen iMessage thread to your Claude or ChatGPT model. Reports are sampled reflections, not verdicts or diagnoses; AI can miss context or make mistakes. It stores the generated report only in this app session."
          : "Add a Claude or ChatGPT API key in Settings to generate EQ reports.")
          .font(Office.caption)
          .foregroundStyle(Office.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .officeCard(colorScheme)
  }

  // MARK: Session setup

  private var promptControls: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Label(selectedPerson?.displayName ?? "Choose a person", systemImage: "person.crop.circle")
          .font(Office.label)
          .foregroundStyle(Office.ink(colorScheme))
        Spacer()
        Button {
          controller.generate(
            person: selectedPerson,
            relationship: effectiveRelationship,
            contextDepth: contextDepth,
            prompt: effectivePrompt
          )
        } label: {
          Label(controller.isBusy ? "Generating..." : "Generate Report", systemImage: "wand.and.stars")
        }
        .officeButton(.primary)
        .disabled(controller.isBusy || selectedPerson == nil || !controller.hasAnyAPIKey)
      }

      HStack(alignment: .firstTextBaseline, spacing: 12) {
        OfficeMenuPicker(
          title: "Relationship",
          options: EQRelationshipType.allCases,
          selection: $relationshipType
        ) { $0.rawValue }
        .frame(width: 220)

        if relationshipType == .other {
          TextField("Type relationship", text: $customRelationship)
            .officeInput(colorScheme)
            .frame(maxWidth: 260)
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: 12) {
        OfficeSegmentedControl(EQContextDepth.allCases, selection: $contextDepth) { $0.rawValue }
        .frame(maxWidth: 360)
      }

      Text(contextDepth.helper)
        .font(Office.micro)
        .foregroundStyle(Office.ink3(colorScheme))

      if let eqCostLine {
        Text(eqCostLine)
          .font(Office.micro)
          .foregroundStyle(Office.ink3(colorScheme))
      }

      Rectangle()
        .fill(Office.line(colorScheme))
        .frame(height: 1)
        .padding(.vertical, 2)
        .accessibilityHidden(true)

      presetBrowser

      Text(effectivePrompt)
        .font(Office.caption)
        .foregroundStyle(Office.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)

      Text("Context: \(effectiveRelationship)")
        .font(Office.micro)
        .foregroundStyle(Office.ink3(colorScheme))

      HStack(spacing: 6) {
        ForEach(["Bids", "Responsiveness", "Reciprocity", "Care", "Repair"], id: \.self) { lens in
          Text(lens)
            .font(Office.chip)
            .foregroundStyle(Office.sageDeep(colorScheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Office.sageDim(colorScheme)))
        }
      }
    }
    .padding(18)
    .officeCard(colorScheme)
  }

  /// The expanded preset library, browsed by category — like flipping to the
  /// right tab of a well-worn notebook. Selecting a question keeps the same
  /// single `selectedPresetID` binding the old segmented control drove.
  private var presetBrowser: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(selectedPerson.map { "What's on your mind about \($0.displayName)?" } ?? "What's on your mind?")
        .font(Office.sectionSerif)
        .foregroundStyle(Office.ink(colorScheme))

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(EQPresetCategory.allCases) { category in
            categoryTab(category)
          }
        }
        .padding(.vertical, 1)
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(EQPreset.presets(in: presetCategory)) { preset in
          presetRow(preset)
        }
      }
      .dsAnimation(.easeOut(duration: 0.3), value: presetCategory)
    }
  }

  private func categoryTab(_ category: EQPresetCategory) -> some View {
    let selected = presetCategory == category
    return Button {
      withAnimation(DS.motion(reduceMotion, .easeInOut(duration: 0.26))) {
        presetCategory = category
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: category.icon)
          .font(.system(size: 10, weight: .semibold))
        Text(category.rawValue)
          .lineLimit(1)
      }
      .font(Office.chip)
      .foregroundStyle(selected ? Office.tabSelectedText(colorScheme) : Office.ink2(colorScheme))
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .fill(selected ? Office.sage(colorScheme) : Office.paperDeep(colorScheme))
      )
      .overlay(
        Capsule()
          .strokeBorder(selected ? Color.clear : Office.line(colorScheme), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(category.rawValue)
    .accessibilityValue(selected ? "Selected" : "")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func presetRow(_ preset: EQPreset) -> some View {
    let selected = selectedPresetID == preset.id
    return Button {
      withAnimation(DS.motion(reduceMotion, .easeInOut(duration: 0.26))) {
        selectedPresetID = preset.id
      }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(selected ? Office.sage(colorScheme) : Office.line(colorScheme))
          .frame(width: 3)
          .padding(.vertical, 2)
        VStack(alignment: .leading, spacing: 3) {
          Text(preset.title)
            .font(Office.rowTitle)
            .foregroundStyle(selected ? Office.ink(colorScheme) : Office.ink2(colorScheme))
          Text(preset.prompt.replacingOccurrences(of: "{person}", with: selectedPerson?.displayName ?? "them"))
            .font(Office.caption)
            // Same selected-fill legibility rule as the person rows: ink2 on
            // the sage-tinted fill, ink3 on plain paper.
            .foregroundStyle(selected ? Office.ink2(colorScheme) : Office.ink3(colorScheme))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(selected ? Office.sage(colorScheme) : Office.ink3(colorScheme).opacity(0.65))
          .padding(.top, 1)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Office.rowRadius, style: .continuous)
          .fill(selected ? Office.sageDim(colorScheme) : Office.paperDeep(colorScheme).opacity(0.55))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Office.rowRadius, style: .continuous)
          .strokeBorder(selected ? Office.sageRail(colorScheme) : Office.line(colorScheme).opacity(0.7), lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: Office.rowRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(preset.title)
    .accessibilityValue(selected ? "Selected" : "")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var eqCostLine: String? {
    guard let selection = LabModelPreferences.clientSelection(for: .eq) else { return nil }
    return "\(selection.provider.label) \(selection.modelID). \(AIUsageEstimate.eqLabel(provider: selection.provider, modelID: selection.modelID, depth: contextDepth))."
  }

  // MARK: Thread preview

  @ViewBuilder
  private var preview: some View {
    if let selectedPerson {
      VStack(alignment: .leading, spacing: 10) {
        Label("Recent thread preview", systemImage: "text.bubble")
          .font(Office.label)
          .foregroundStyle(Office.ink(colorScheme))
        if controller.messages.isEmpty {
          Text("Select a person to load recent readable messages.")
            .font(Office.body)
            .foregroundStyle(Office.ink3(colorScheme))
        } else {
          ForEach(controller.messages.suffix(6)) { message in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(message.fromMe ? "You" : selectedPerson.displayName)
                .font(Office.chip)
                .foregroundStyle(message.fromMe ? Office.sageDeep(colorScheme) : Office.ink3(colorScheme))
                .frame(width: 96, alignment: .leading)
              Text(message.body)
                .font(Office.caption)
                .foregroundStyle(Office.ink3(colorScheme))
                .lineLimit(2)
            }
          }
        }
      }
      .padding(18)
      .officeCard(colorScheme)
    }
  }

  // MARK: Session notes (report)

  @ViewBuilder
  private var report: some View {
    if controller.report.isEmpty {
      HStack(alignment: .top, spacing: 14) {
        OfficePlantView(size: 36)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 8) {
          Label("No session notes yet", systemImage: "doc.text.magnifyingglass")
            .font(Office.label)
            .foregroundStyle(Office.ink(colorScheme))
          Text("Choose a person and generate an EQ report. The output is meant for reflection, not a diagnosis, and AI can miss context or make mistakes.")
            .font(Office.body)
            .foregroundStyle(Office.ink3(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .officeCard(colorScheme)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("Session notes", systemImage: "heart.text.square")
            .font(Office.label)
            .foregroundStyle(Office.ink(colorScheme))
          Spacer()
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.report, forType: .string)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .officeButton(.secondary)
        }
        Text(.init(controller.report))
          .font(.body)
          .foregroundStyle(Office.ink(colorScheme))
          .textSelection(.enabled)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 34)
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .officeLegalPad(colorScheme)
      .dsAnimation(.easeOut(duration: 0.35), value: controller.report)
    }
  }

  private func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Office kit (file-private — EQ only)
//
// EQ is the ONE surface allowed to feel like a therapist's office: warm
// cream-and-linen paper, sage green and walnut brown accents, a soft lamp-glow
// pooling at the top of the room, serif display type for the titles (body copy
// stays system sans for legibility), upholstered-soft rounded cards, a little
// potted plant drawn in pure SwiftUI, and session notes on a ruled legal pad.
// Calm and unhurried — transitions a beat slower than the rest of the app,
// always Reduce-Motion safe. Deliberately NOT in DesignSystem/ — this aesthetic
// must not leak into other surfaces. Severity still reads through non-color
// signals (warning triangle, spinners), never color alone.

private enum Office {
  // Warm paper: cream falling into linen (light), an evening study lit well
  // enough to read in (dark). The dark palette is deliberately lifted: the
  // first pass was muddy brown-on-brown (card-vs-canvas 1.12:1, hairlines at
  // 10% white) and illegible on real displays. Ratios below are WCAG contrast
  // against the dark card paper 0x382D20 unless noted.
  //
  // Dark canvas drops darker (0x1B140C → 0x130E08) while the card paper
  // rises, so cards separate at 1.36:1 by surface alone, then a 16%-white
  // hairline (1.67:1 vs paper) and a deeper shadow carry the edge.
  static func canvasTop(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x1B140C) : DS.Color.hex(0xF7F1E6) }
  static func canvasBottom(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x130E08) : DS.Color.hex(0xF1E8D8) }
  static func paper(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x382D20) : DS.Color.hex(0xFCF8EF) }
  static func paperDeep(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x2E251A) : DS.Color.hex(0xF2EADA) }
  /// Hover/pressed surface for paper buttons: in the dark office a hover must
  /// BRIGHTEN (paperDeep would sink it into the wall); in light it deepens.
  static func paperRaise(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x44382A) : DS.Color.hex(0xF2EADA) }
  /// The appointment book's own paper — a shade deeper than the room.
  static func bookPaper(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x231B12) : DS.Color.hex(0xF4EDDF) }

  // Dark inks vs card paper 0x382D20: ink 11.7:1, ink2 8.7:1, ink3 5.6:1
  // (and 7.1:1 on the darker book paper) — all clear of the 4.5:1 AA bar
  // for body text.
  static func ink(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xF6EEE0) : DS.Color.hex(0x383026) }
  static func ink2(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xDCCFB9) : DS.Color.hex(0x5C5244) }
  static func ink3(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xB5A68E) : DS.Color.hex(0x857867) }

  // Sage green accent — brightened in the dark office: sage 7.1:1 and
  // sageDeep 8.8:1 on card paper (the old 0x93AC8B sat at 6.1:1 and read
  // gray-brown next to the mud). sageDim/sageRail step up so the selected
  // preset/person fill separates at 1.74:1 vs plain paper with a 60% rail.
  static func sage(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xA9C49C) : DS.Color.hex(0x5F7D5B) }
  static func sageDeep(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xC2D8B6) : DS.Color.hex(0x4A6647) }
  static func sageDim(_ s: ColorScheme) -> Color { sage(s).opacity(s == .dark ? 0.26 : 0.13) }
  static func sageRail(_ s: ColorScheme) -> Color { sage(s).opacity(s == .dark ? 0.60 : 0.40) }
  /// Label ink on a sage fill (the fill flips light/dark, so this flips too).
  /// Dark: 0x1B2317 on sage 0xA9C49C = 8.5:1.
  static func tabSelectedText(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x1B2317) : DS.Color.hex(0xFBF7ED) }

  // Walnut brown accent. Dark: 6.9:1 on the book paper it labels.
  static func walnut(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xC99C71) : DS.Color.hex(0x7A5A40) }

  static func line(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.16) : DS.Color.hex(0xE3D8C4) }
  /// Lamp-glow: warm amber, used as a diffuse shadow and a room highlight.
  static func lampGlow(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xE2B36B).opacity(0.10) : DS.Color.hex(0xDFAE63).opacity(0.16) }
  static func cardShadow(_ s: ColorScheme) -> Color { s == .dark ? Color.black.opacity(0.50) : DS.Color.hex(0xB99B62).opacity(0.20) }

  // Legal pad (session notes). Dark pad lifts with the cards: ink 10.1:1 and
  // ink3 4.9:1 on 0x42371F; rules/margin brighten to stay visible on it.
  static func padPaper(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x42371F) : DS.Color.hex(0xFBF2CC) }
  static func padRule(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x6B5B34).opacity(0.8) : DS.Color.hex(0xD9C48E).opacity(0.55) }
  static func padMargin(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x9C665C).opacity(0.75) : DS.Color.hex(0xD89A93).opacity(0.7) }
  static func padBinding(_ s: ColorScheme) -> Color { walnut(s).opacity(s == .dark ? 0.30 : 0.18) }

  // The plant.
  static func pot(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x96573C) : DS.Color.hex(0xB0694B) }
  static func potRim(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x7C4731) : DS.Color.hex(0x9A593E) }

  // Upholstered-soft corners.
  static let cardRadius: CGFloat = 18
  static let controlRadius: CGFloat = 11
  static let rowRadius: CGFloat = 10

  // Serif display for titles ONLY; body copy stays system sans for legibility.
  static let title = Font.system(size: 27, weight: .semibold, design: .serif)
  static let sectionSerif = Font.system(size: 16, weight: .medium, design: .serif).italic()
  static let bookLabel = Font.system(size: 10, weight: .semibold)
  static let label = Font.system(size: 13, weight: .medium)
  static let rowTitle = Font.system(size: 13, weight: .semibold)
  static let body = Font.system(size: 12.5)
  static let caption = Font.system(size: 11.5)
  static let chip = Font.system(size: 10.5, weight: .semibold)
  static let micro = Font.system(size: 10, weight: .medium)
  static let button = Font.system(size: 12.5, weight: .semibold)
}

// MARK: Potted plant motif

/// A small potted plant in pure SwiftUI: terracotta pot, sage leaves fanned
/// from the soil line. Decorative only — always hidden from VoiceOver.
private struct OfficePlantView: View {
  var size: CGFloat = 44
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack(alignment: .bottom) {
      leaves
        .offset(y: -size * 0.30)
      pot
    }
    .frame(width: size, height: size * 1.05, alignment: .bottom)
    .accessibilityHidden(true)
  }

  private var leaves: some View {
    ZStack(alignment: .bottom) {
      leaf(angle: -44, length: 0.52, opacity: 0.78)
      leaf(angle: 44, length: 0.52, opacity: 0.78)
      leaf(angle: -22, length: 0.62, opacity: 0.9)
      leaf(angle: 22, length: 0.62, opacity: 0.9)
      leaf(angle: 0, length: 0.70, opacity: 1)
    }
  }

  private func leaf(angle: Double, length: CGFloat, opacity: Double) -> some View {
    Ellipse()
      .fill(Office.sage(scheme).opacity(opacity))
      .frame(width: size * 0.17, height: size * length)
      .offset(y: -size * length / 2)
      .rotationEffect(.degrees(angle), anchor: .bottom)
  }

  private var pot: some View {
    VStack(spacing: 0) {
      RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
        .fill(Office.potRim(scheme))
        .frame(width: size * 0.58, height: size * 0.09)
      OfficePotShape()
        .fill(Office.pot(scheme))
        .frame(width: size * 0.50, height: size * 0.30)
    }
  }
}

/// The pot body: a gently tapered trapezoid with a soft rounded base.
private struct OfficePotShape: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    let inset = rect.width * 0.14
    let r = rect.height * 0.22
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - r))
    p.addQuadCurve(
      to: CGPoint(x: rect.maxX - inset - r, y: rect.maxY),
      control: CGPoint(x: rect.maxX - inset, y: rect.maxY)
    )
    p.addLine(to: CGPoint(x: rect.minX + inset + r, y: rect.maxY))
    p.addQuadCurve(
      to: CGPoint(x: rect.minX + inset, y: rect.maxY - r),
      control: CGPoint(x: rect.minX + inset, y: rect.maxY)
    )
    p.closeSubpath()
    return p
  }
}

/// A slow, barely-there sway — the plant breathing in the lamp light.
/// Static under Reduce Motion.
private struct OfficeSway: ViewModifier {
  var degrees: Double = 1.6
  var period: Double = 3.8
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var leaning = false

  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(leaning ? degrees : -degrees), anchor: .bottom)
      .onAppear {
        guard !reduceMotion, !leaning else { return }
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
          leaning = true
        }
      }
  }
}

// MARK: Office card, input, legal pad

private struct OfficeCardModifier: ViewModifier {
  let scheme: ColorScheme
  var fill: Color?

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: Office.cardRadius, style: .continuous)
          .fill(fill ?? Office.paper(scheme))
          .shadow(color: Office.cardShadow(scheme), radius: 14, y: 6)
          .shadow(color: Office.lampGlow(scheme), radius: 3, y: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Office.cardRadius, style: .continuous)
          .strokeBorder(Office.line(scheme), lineWidth: 1)
      )
  }
}

/// The legal pad: warm yellow paper, faint ruled lines, a soft red margin
/// line, and a walnut binding strip across the top. The rules are drawn at low
/// opacity so the markdown stays the focus.
private struct OfficeLegalPadModifier: ViewModifier {
  let scheme: ColorScheme

  private let ruleSpacing: CGFloat = 26
  private let rulesTopInset: CGFloat = 56
  private let marginX: CGFloat = 44

  func body(content: Content) -> some View {
    content
      .background(
        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: Office.cardRadius, style: .continuous)
            .fill(Office.padPaper(scheme))
            .shadow(color: Office.cardShadow(scheme), radius: 14, y: 6)
          rules
            .clipShape(RoundedRectangle(cornerRadius: Office.cardRadius, style: .continuous))
          UnevenRoundedRectangle(
            topLeadingRadius: Office.cardRadius,
            topTrailingRadius: Office.cardRadius
          )
          .fill(Office.padBinding(scheme))
          .frame(height: 9)
        }
        .accessibilityHidden(true)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Office.cardRadius, style: .continuous)
          .strokeBorder(Office.padRule(scheme).opacity(0.8), lineWidth: 1)
      )
  }

  private var rules: some View {
    Canvas { context, size in
      var y = rulesTopInset
      while y < size.height - 12 {
        var line = Path()
        line.move(to: CGPoint(x: 14, y: y))
        line.addLine(to: CGPoint(x: size.width - 14, y: y))
        context.stroke(line, with: .color(Office.padRule(scheme)), lineWidth: 1)
        y += ruleSpacing
      }
      var margin = Path()
      margin.move(to: CGPoint(x: marginX, y: 14))
      margin.addLine(to: CGPoint(x: marginX, y: size.height - 14))
      context.stroke(margin, with: .color(Office.padMargin(scheme)), lineWidth: 1)
    }
  }
}

private extension View {
  /// Soft, upholstered card resting in the lamp light.
  func officeCard(_ scheme: ColorScheme, fill: Color? = nil) -> some View {
    modifier(OfficeCardModifier(scheme: scheme, fill: fill))
  }

  /// Session notes on a ruled legal pad.
  func officeLegalPad(_ scheme: ColorScheme) -> some View {
    modifier(OfficeLegalPadModifier(scheme: scheme))
  }

  /// Text input on warm paper — same metrics as `dsInput`, warmer chrome.
  func officeInput(_ scheme: ColorScheme, minHeight: CGFloat? = nil) -> some View {
    textFieldStyle(.plain)
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .frame(minHeight: minHeight)
      .background(
        RoundedRectangle(cornerRadius: Office.controlRadius, style: .continuous)
          .fill(Office.paper(scheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Office.controlRadius, style: .continuous)
          .strokeBorder(Office.line(scheme), lineWidth: 1)
      )
  }

  func officeSway() -> some View {
    modifier(OfficeSway())
  }

  func officeButton(_ variant: OfficeButtonVariant = .primary) -> some View {
    buttonStyle(OfficeButtonStyle(variant: variant))
  }
}

// MARK: Office buttons

private enum OfficeButtonVariant {
  case primary    // sage fill, cream text, soft lamp-glow shadow
  case secondary  // paper capsule + walnut-tinted hairline
}

private struct OfficeButtonStyle: ButtonStyle {
  var variant: OfficeButtonVariant = .primary

  func makeBody(configuration: Configuration) -> some View {
    OfficeButtonBody(configuration: configuration, variant: variant)
  }
}

private struct OfficeButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let variant: OfficeButtonVariant

  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  var body: some View {
    let pressed = configuration.isPressed && isEnabled

    configuration.label
      .font(Office.button)
      .labelStyle(OfficeButtonLabelStyle())
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .frame(minHeight: 30)
      .background(background(pressed: pressed))
      .scaleEffect(pressed ? 0.98 : 1)
      // Disabled buttons dim less in dark — at 0.45 the already-dark chrome
      // vanished into the wall entirely.
      .opacity(isEnabled ? 1 : (scheme == .dark ? 0.55 : 0.45))
      .contentShape(Capsule())
      .dsAnimation(.easeOut(duration: 0.16), value: pressed)
      .onHover { hovering = $0 }
  }

  @ViewBuilder private func background(pressed: Bool) -> some View {
    let active = (hovering || pressed) && isEnabled
    switch variant {
    case .primary:
      // sageDeep is lighter than sage in dark and darker in light, so hover
      // and press read as a lift in both schemes.
      Capsule()
        .fill(active ? Office.sageDeep(scheme) : Office.sage(scheme))
        .shadow(color: Office.sage(scheme).opacity(isEnabled ? 0.35 : 0), radius: pressed ? 4 : 8, y: pressed ? 1 : 3)
    case .secondary:
      Capsule()
        .fill(active ? Office.paperRaise(scheme) : Office.paper(scheme))
        .overlay(Capsule().strokeBorder(Office.line(scheme), lineWidth: 1))
        .shadow(color: Office.cardShadow(scheme).opacity(isEnabled ? 0.6 : 0), radius: pressed ? 2 : 5, y: pressed ? 1 : 2)
    }
  }

  private var foreground: Color {
    switch variant {
    case .primary:
      // The sage fill flips light/dark, so the label ink flips with it.
      return Office.tabSelectedText(scheme)
    case .secondary:
      return Office.ink(scheme)
    }
  }
}

/// Keeps an office button's leading SF Symbol sized + spaced with its title.
private struct OfficeButtonLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: 11, weight: .semibold))
      configuration.title
    }
  }
}

// MARK: Office controls (DS replacements)
//
// EQ's last two controls still on the shared DS kit — the Relationship menu
// picker and the context-depth segmented control — rendered as cool-gray
// pills with the system-blue accent, jarring against the warm office. These
// are the same controls on the Office chrome: warm paper wells, walnut
// labels, sage selection. Bindings + accessibility mirror the DS originals.

private struct OfficeMenuPicker<Option: Hashable>: View {
  let title: String
  let options: [Option]
  @Binding var selection: Option
  let label: (Option) -> String

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button {
          selection = option
        } label: {
          if option == selection {
            Label(label(option), systemImage: "checkmark")
          } else {
            Text(label(option))
          }
        }
      }
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(Office.micro)
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Office.walnut(scheme))
          Text(label(selection))
            .font(Office.label)
            .foregroundStyle(Office.ink(scheme))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Office.ink3(scheme))
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: Office.controlRadius, style: .continuous)
          .fill(Office.paperDeep(scheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Office.controlRadius, style: .continuous)
          .strokeBorder(Office.line(scheme), lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: Office.controlRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(label(selection))
  }
}

private struct OfficeSegmentedControl<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  let label: (Option) -> String

  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    _ options: [Option],
    selection: Binding<Option>,
    label: @escaping (Option) -> String
  ) {
    self.options = options
    self._selection = selection
    self.label = label
  }

  var body: some View {
    HStack(spacing: 3) {
      ForEach(options, id: \.self) { option in
        let selected = selection == option
        Button {
          withAnimation(DS.motion(reduceMotion, .easeInOut(duration: 0.18))) {
            selection = option
          }
        } label: {
          Text(label(option))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .font(Office.chip)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
              RoundedRectangle(cornerRadius: Office.controlRadius - 3, style: .continuous)
                .fill(selected ? Office.sage(scheme) : Color.clear)
            )
            // Selected: tabSelectedText on sage (8.5:1 dark). Unselected:
            // ink2 so the resting options stay readable in the dark office.
            .foregroundStyle(selected ? Office.tabSelectedText(scheme) : Office.ink2(scheme))
            .contentShape(RoundedRectangle(cornerRadius: Office.controlRadius - 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(option))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: Office.controlRadius, style: .continuous)
        .fill(Office.paperDeep(scheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Office.controlRadius, style: .continuous)
        .strokeBorder(Office.line(scheme), lineWidth: 1)
    )
  }
}

// MARK: - First-open intro (registered in ToolRegistry)

extension EQView {
  /// Registry hook for the first-open intro sheet. The office kit stays
  /// file-private; only an opaque AnyView crosses the file boundary.
  static func makeIntro(_ actions: LabIntroActions) -> AnyView {
    AnyView(EQIntroView(actions: actions))
  }
}

/// The office before the first session: lamp-lit paper, the plant, a serif
/// welcome, and the session notes already on the legal pad.
private struct EQIntroView: View {
  let actions: LabIntroActions
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Office.canvasTop(scheme), Office.canvasBottom(scheme)],
        startPoint: .top,
        endPoint: .bottom
      )
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .bottom) {
          Text("EQ · Session notes")
            .font(Office.bookLabel)
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Office.walnut(scheme))
          Spacer()
          OfficePlantView(size: 48)
            .officeSway()
        }

        Text("A second read on every hard conversation.")
          .font(Office.title)
          .foregroundStyle(Office.ink(scheme))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 14)

        VStack(alignment: .leading, spacing: 14) {
          note("Pick the person and the moment — EQ reads the room first.")
          note("Tone, subtext, and what they might actually mean, on paper.")
          note("You leave with guidance, not a script. The reply stays yours.")
        }
        .padding(20)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .officeLegalPad(scheme)
        .padding(.top, 24)

        Spacer(minLength: 16)

        Text("Runs with your own key · guidance never sends a message")
          .font(Office.micro)
          .foregroundStyle(Office.ink3(scheme))

        HStack(spacing: 12) {
          Button("Not today") { actions.onCancel() }
            .officeButton(.secondary)
            .accessibilityLabel("Not today")
          Button("Begin the session") { actions.onContinue() }
            .officeButton(.primary)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue to EQ")
        }
        .padding(.top, 14)
      }
      .padding(36)
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(Office.sectionSerif)
      .foregroundStyle(Office.ink2(scheme))
      .fixedSize(horizontal: false, vertical: true)
  }
}
