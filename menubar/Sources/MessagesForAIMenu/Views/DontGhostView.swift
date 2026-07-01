import SwiftUI

struct DontGhostView: View {
  @EnvironmentObject private var store: DraftStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var controller = DontGhostController()
  @EnvironmentObject private var aiUsageLedger: AIUsageLedger
  @State private var expandedSuggestionID: String?
  @State private var visibleLimit = initialVisibleLimit
  // Shares the exact UserDefaults key the controller reads at scan time.
  @AppStorage(LabModelPreferences.dontGhostAIBoostKey) private var aiBoostEnabled = true

  private static let initialVisibleLimit = 25
  private static let visibleBatchSize = 25

  private var visibleSuggestions: [DontGhostSuggestion] {
    Array(controller.suggestions.prefix(visibleLimit))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
          .fullDiskAccessGate(toolName: "Don't Ghost")
        statusCard
        if controller.suggestions.isEmpty {
          emptyState
        } else {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(visibleSuggestions) { suggestion in
              DontGhostSuggestionCard(
                suggestion: suggestion,
                isExpanded: expandedSuggestionID == suggestion.id,
                onToggle: { toggleExpanded(suggestion.id) },
                onDraftChanged: { controller.updateDraftText(threadID: suggestion.threadID, text: $0) },
                onSendNow: { existingDraft in
                  await controller.sendNow(suggestion, existingDraft: existingDraft, store: store)
                },
                onSchedule: { date in controller.scheduleDraft(suggestion, scheduledAt: date, store: store) },
                onDismiss: { controller.dismiss(suggestion) },
                onReplied: { controller.markReplied(suggestion) }
              )
              // Dismissal reads as the ghost fading out (reduce-motion safe via
              // the dsAnimation on the container below).
              .transition(.opacity)
            }

            if controller.suggestions.count > visibleSuggestions.count {
              Button {
                visibleLimit += Self.visibleBatchSize
              } label: {
                Label("Show more", systemImage: "chevron.down")
              }
              .casperButton(.secondary, compact: true)
              .padding(.top, 2)
            }
          }
          .dsAnimation(.easeOut(duration: 0.35), value: controller.suggestions.map(\.id))
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(
      LinearGradient(
        colors: [Casper.canvasTop(colorScheme), Casper.canvasBottom(colorScheme)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
    // Tint the console rail + titlebar strip to match this lab's canvas.
    .consoleChromeBackground(Casper.canvasTop(colorScheme))
    .onAppear {
      controller.usageLedger = aiUsageLedger
      controller.suppressPendingWork(from: store.drafts)
    }
    .onChange(of: store.drafts) { _, drafts in
      controller.suppressPendingWork(from: drafts)
    }
  }

  private func toggleExpanded(_ suggestionID: String) {
    withAnimation(DS.motion(reduceMotion, .spring(response: 0.28, dampingFraction: 0.86))) {
      if expandedSuggestionID == suggestionID {
        expandedSuggestionID = nil
      } else {
        expandedSuggestionID = suggestionID
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Don't Ghost")
          .font(Casper.title)
          .foregroundStyle(Casper.ink(colorScheme))
        Text("Find 1:1 iMessage and WhatsApp threads worth a nudge: replies you still owe, plus quiet conversations where you wrote last and a check-in would feel natural. AI reviews recent excerpts only when a saved API key is available; dismissals store thread metadata, not message bodies.")
          .font(Casper.caption)
          .foregroundStyle(Casper.ink3(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button {
        visibleLimit = Self.initialVisibleLimit
        expandedSuggestionID = nil
        controller.refresh(store: store)
      } label: {
        Label("Look for ghosts", systemImage: "magnifyingglass")
      }
      .casperButton(.primary)
      .disabled(controller.isBusy)
    }
  }

  private var statusCard: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      if controller.isBusy || controller.isLoadingCache {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: controller.hasAnyAPIKey ? "sparkles" : "exclamationmark.triangle.fill")
          .foregroundStyle(controller.hasAnyAPIKey ? Casper.spectral(colorScheme) : DS.Color.amber(colorScheme))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(controller.status.label)
          .font(Casper.label)
          .foregroundStyle(Casper.ink(colorScheme))
        Text(statusSubtitle)
          .font(Casper.caption)
          .foregroundStyle(Casper.ink3(colorScheme))
        if let costLine {
          Text(costLine)
            .font(DS.Font.monoMicro)
            .foregroundStyle(Casper.ink3(colorScheme))
        }
      }
      Spacer()
      if controller.hasAnyAPIKey {
        Toggle("AI boost", isOn: $aiBoostEnabled)
          .toggleStyle(.switch)
          .controlSize(.small)
          .font(Casper.caption)
          .fixedSize()
          .help("On: an LLM refines which threads surface (uses your API key). Off: ranking is fully on-device, no key or cost.")
          .onChange(of: aiBoostEnabled) { _, _ in
            // Re-scan in the new mode, but only if a scan already ran (don't kick
            // a cold scan just from flipping the switch).
            if controller.status != .idle { controller.refresh() }
          }
      }
    }
    .padding(16)
    .casperCard()
  }

  private var statusSubtitle: String {
    guard controller.hasAnyAPIKey else {
      return "Ranking on-device — no API key needed. Add a Claude or ChatGPT key in Settings to enable AI boost."
    }
    return aiBoostEnabled
      ? "AI boost on — the LLM refines which threads surface. The score is a priority signal, not a certainty."
      : "AI boost off — ranking is fully on-device. Toggle it on to let the LLM refine the picks."
  }

  private var costLine: String? {
    // Only an estimate when AI boost is actually running.
    guard aiBoostEnabled, let selection = LabModelPreferences.clientSelection(for: .dontGhost) else { return nil }
    return "\(selection.provider.label) \(selection.modelID). \(AIUsageEstimate.label(for: .dontGhost, provider: selection.provider, modelID: selection.modelID))."
  }

  @ViewBuilder
  private var emptyState: some View {
    let hasRun = controller.status != .idle
    let busy = controller.isBusy || controller.isLoadingCache
    VStack(spacing: 12) {
      if busy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(controller.isLoadingCache ? "Loading cached results..." : "Looking for ghosts...")
            .font(Casper.label)
            .foregroundStyle(Casper.ink(colorScheme))
        }
      } else {
        // The hero moment: the friendly ghost, gently bobbing (static under
        // Reduce Motion). Decorative; the text carries the meaning.
        CasperGhostView(size: 58)
          .casperFloating(amplitude: 4)
          .padding(.bottom, 2)
        Text(hasRun ? "No ghosts here. You're all caught up." : "Ready when you are")
          .font(Casper.label)
          .foregroundStyle(Casper.ink(colorScheme))
      }
      Text(emptyMessage(hasRun: hasRun))
        .font(Casper.body)
        .foregroundStyle(Casper.ink3(colorScheme))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 30)
    .padding(.horizontal, 24)
    .frame(maxWidth: 620)
    .casperCard()
  }

  private func emptyMessage(hasRun: Bool) -> String {
    if controller.isLoadingCache {
      return "Reopening the last scan and checking whether any cached threads now have a newer reply from you."
    }
    if controller.isBusy {
      return "Looking for replies you still owe and quiet threads where a check-in would feel natural."
    }
    if hasRun {
      return "You can scan again later. Dismissed threads stay hidden until a new inbound message arrives."
    }
    return "Press Look for ghosts to scan and rank recent threads on-device. Nothing runs in the background."
  }
}

private struct DontGhostSuggestionCard: View {
  let suggestion: DontGhostSuggestion
  let isExpanded: Bool
  let onToggle: () -> Void
  let onDraftChanged: (String) -> Void
  let onSendNow: (Draft?) async -> Draft?
  let onSchedule: (Date) -> Void
  let onDismiss: () -> Void
  let onReplied: () -> Void

  @EnvironmentObject private var store: DraftStore
  @EnvironmentObject private var threadPriorities: ThreadPriorityStore
  @Environment(\.colorScheme) private var colorScheme
  @State private var draftText: String = ""
  @State private var showingSchedule = false
  @State private var scheduleDate = Date().addingTimeInterval(3600)
  @State private var inlineDraftID: String?
  @State private var sendingNow = false

  /// This thread's unsent composer auto-save draft, if any — so a half-written
  /// reconnect reply survives quit and shows in the Drafts pane like any draft.
  private var composerAutosaveDraft: Draft? {
    ComposerAutosavePolicy.existingDraft(
      in: store.drafts, platform: suggestion.platform, handle: suggestion.handle,
      canonicalize: ContactAvatarStore.canonicalKey
    )
  }

  /// Persist (or clear) the in-progress reply as this thread's auto-save draft.
  /// Fires on navigate-away (the card leaving the view), never while typing.
  private func runComposerAutosave() {
    switch ComposerAutosavePolicy.action(forBody: draftText, existing: composerAutosaveDraft) {
    case .none:
      return
    case .discard(let id):
      try? store.discard(id: id)
    case .update(let id, let body):
      _ = try? store.updateBody(id: id, body: body)
    case .create(let body):
      _ = try? store.createIMessageDraft(
        toHandle: suggestion.handle, toHandleName: suggestion.displayName, body: body,
        inReplyToThreadID: suggestion.threadID, source: ComposerAutosavePolicy.source
      )
    }
  }

  private func restoreComposerDraft() {
    guard draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let draft = composerAutosaveDraft else { return }
    draftText = draft.body
    onDraftChanged(draft.body)
  }

  private func discardComposerAutosave() {
    if let draft = composerAutosaveDraft { try? store.discard(id: draft.id) }
  }

  private var isFlaggedPriority: Bool {
    threadPriorities.priority(
      platform: suggestion.platform,
      threadID: suggestion.threadID,
      handle: suggestion.handle
    ) != nil
  }

  private var inlineDraft: Draft? {
    guard let inlineDraftID else { return nil }
    return store.drafts.first { $0.id == inlineDraftID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      summaryRow

      if isExpanded {
        expandedContent
          .transition(.opacity.combined(with: .move(edge: .top)))
      } else if let status = suggestion.status {
        Text(status)
          .font(Casper.caption)
          .foregroundStyle(Casper.ink3(colorScheme))
      }
    }
    .padding(16)
    .casperCard()
    .onAppear {
      draftText = suggestion.draftText
      restoreComposerDraft()
    }
    .onChange(of: suggestion.draftText) { _, value in
      if draftText != value { draftText = value }
    }
    .onDisappear {
      // Navigated away (left Don't Ghost, or this suggestion scrolled/cleared
      // out) — persist the unsent reply. A sent reply already cleared draftText,
      // so this is a no-op then.
      runComposerAutosave()
    }
  }

  private var summaryRow: some View {
    HStack(alignment: .center, spacing: 10) {
      Button(action: onToggle) {
        HStack(alignment: .center, spacing: 10) {
          Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
            .foregroundStyle(Casper.spectral(colorScheme))
            .font(.title3)
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              Text(suggestion.displayName)
                .font(Casper.label)
                .foregroundStyle(Casper.ink(colorScheme))
              CasperKindBadge(kind: suggestion.kind)
              Text(activityLabel(for: suggestion))
                .font(Casper.micro)
                .foregroundStyle(Casper.ink3(colorScheme))
            }
            Text(suggestion.reason)
              .font(Casper.body)
              .foregroundStyle(Casper.ink2(colorScheme))
              .lineLimit(isExpanded ? nil : 2)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        if isFlaggedPriority {
          threadPriorities.clearPriority(
            platform: suggestion.platform,
            threadID: suggestion.threadID,
            handle: suggestion.handle
          )
        } else {
          threadPriorities.setPriority(
            .high,
            platform: suggestion.platform,
            threadID: suggestion.threadID,
            handle: suggestion.handle,
            reason: suggestion.kind == .owedReply
              ? "Don't Ghost: they're waiting on a reply"
              : "Don't Ghost: worth a check-in",
            setBy: "dont_ghost"
          )
        }
      } label: {
        Label(
          isFlaggedPriority ? "In priority queue" : "Add to priority",
          systemImage: isFlaggedPriority ? "flag.fill" : "flag"
        )
      }
      .casperButton(.ghost, compact: true)
      .help(
        isFlaggedPriority
          ? "Remove from the Messages priority queue."
          : "Pin this conversation to the top of the Messages tab until you clear it."
      )
      .accessibilityLabel(
        isFlaggedPriority
          ? "Remove \(suggestion.displayName) from priority queue"
          : "Add \(suggestion.displayName) to priority queue"
      )

      Button(role: .destructive) {
        onDismiss()
      } label: {
        Label("Dismiss", systemImage: "xmark.circle")
      }
      .casperButton(.ghost, compact: true)
      .help("Dismiss until a new inbound message arrives.")
      .accessibilityLabel("Dismiss \(suggestion.displayName)")

      CasperConfidenceChip(confidence: suggestion.confidence)
        .help("Reply-priority signal. AI uses the recent context to estimate whether the conversation still deserves a response.")
    }
  }

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      conversationPreview
      replyComposer
      scheduleControls
      statusLine
    }
  }

  private var conversationPreview: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(suggestion.messages.suffix(10).enumerated()), id: \.element.id) { idx, message in
        let visible = Array(suggestion.messages.suffix(10))
        let previous = idx > 0 ? visible[idx - 1] : nil
        ContextBubbleView(
          message: message.contextMessage,
          showSender: !message.fromMe && previous?.fromMe != false,
          platform: suggestion.platform
        )
      }

      if !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        HStack(alignment: .bottom, spacing: 0) {
          Spacer(minLength: 30)
          VStack(alignment: .trailing, spacing: 2) {
            Text(draftText)
              .font(.system(size: 12))
              .foregroundStyle(Casper.ink(colorScheme))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                  .foregroundStyle(Casper.spectral(colorScheme))
              )
            Text("Prepared reply")
              .font(Casper.micro)
              .foregroundStyle(Casper.ink3(colorScheme))
              .padding(.horizontal, 8)
          }
        }
      }

      if let inlineDraft {
        PendingMessageBubble(draft: inlineDraft, onSent: onReplied)
          .padding(.top, 4)
      }
    }
    .padding(12)
    .casperCard(fill: { Casper.paperDeep($0) }, radius: Casper.innerRadius, glow: false)
  }

  private var replyComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Write a reply...", text: $draftText, axis: .vertical)
        .casperInput(colorScheme, minHeight: 70)
        .lineLimit(2...5)
        .onChange(of: draftText) { _, value in
          onDraftChanged(value)
        }

      HStack(spacing: 8) {
        Button {
          guard !sendingNow else { return }
          sendingNow = true
          Task { @MainActor in
            let remainingDraft = await onSendNow(inlineDraft)
            inlineDraftID = remainingDraft?.id
            // The reply was sent — its auto-save twin is no longer unsent, and
            // clearing the box keeps the on-leave save from re-creating it.
            if remainingDraft == nil {
              discardComposerAutosave()
              draftText = ""
            }
            sendingNow = false
          }
        } label: {
          Label(sendingNow ? "Sending..." : "Send Now", systemImage: "paperplane.fill")
        }
        .casperButton(.primary, compact: true)
        .disabled(sendingNow || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inlineDraft?.isSent == true)

        Button {
          showingSchedule.toggle()
        } label: {
          Label("Schedule", systemImage: "clock")
        }
        .casperButton(.secondary, compact: true)
        .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button(role: .destructive) {
          onDismiss()
        } label: {
          Label("Dismiss", systemImage: "xmark.circle")
        }
        .casperButton(.ghost, compact: true)

        Spacer()
      }
    }
  }

  @ViewBuilder
  private var scheduleControls: some View {
    if showingSchedule {
      HStack(spacing: 10) {
        DSDateTimeField(title: "Send on", selection: $scheduleDate, displayedComponents: [.date, .hourAndMinute])
          .frame(width: 230)
        Button {
          onSchedule(scheduleDate)
          showingSchedule = false
        } label: {
          Label("Queue Schedule", systemImage: "calendar.badge.clock")
        }
        .casperButton(.secondary, compact: true)
      }
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    if let status = suggestion.status {
      Text(status)
        .font(Casper.caption)
        .foregroundStyle((status.contains("queued") || status.contains("ready")) ? DS.Color.green(colorScheme) : Casper.ink3(colorScheme))
    }
  }

  private func activityLabel(for suggestion: DontGhostSuggestion) -> String {
    switch suggestion.kind {
    case .owedReply:
      return "Last from them \(relative(suggestion.lastInboundAt))"
    case .followUp:
      return "You wrote last \(relative(suggestion.lastMessageAt))"
    }
  }

  private func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Casper kit (file-private — Don't Ghost only)
//
// Don't Ghost is the ONE surface allowed to break from "calm native precision"
// into a Casper-the-Friendly-Ghost feel: a soft night-sky-at-dusk palette
// (pale spectral blues/lavenders on light, deeper twilight on dark), extra-round
// corners, diffuse glows instead of hard shadows, rounded type, and a cute
// little ghost mascot drawn in pure SwiftUI. Friendly and a bit supernatural,
// never spooky. Deliberately NOT in DesignSystem/ — this aesthetic must not
// leak into the rest of the app. Severity still reads through non-color signals
// (warning triangle, checkmark, progress spinners), never color alone.

private enum Casper {
  // Spectral accent: the dusk-glow periwinkle.
  static func spectral(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xA89DFF) : DS.Color.hex(0x6C5CE7) }
  static func spectralDeep(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xBCB3FF) : DS.Color.hex(0x5747D6) }
  static func spectralDim(_ s: ColorScheme) -> Color { spectral(s).opacity(s == .dark ? 0.22 : 0.12) }

  // Night sky at dusk: pale lavender-blue paper in light, deep twilight in dark.
  static func canvasTop(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x10122A) : DS.Color.hex(0xEAEDFB) }
  static func canvasBottom(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x1A1733) : DS.Color.hex(0xF4F1FC) }
  static func paper(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x1F2240) : DS.Color.hex(0xFBFBFF) }
  static func paperDeep(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x171A31) : DS.Color.hex(0xEFF0FB) }
  static func ink(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xECEDFD) : DS.Color.hex(0x2A2D4A) }
  static func ink2(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xC0C3E6) : DS.Color.hex(0x4C5074) }
  static func ink3(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0x8C90BE) : DS.Color.hex(0x7B7FA4) }
  static func line(_ s: ColorScheme) -> Color { spectral(s).opacity(s == .dark ? 0.30 : 0.22) }
  /// Soft diffuse glow — used everywhere a hard shadow would normally go.
  static func glow(_ s: ColorScheme) -> Color { spectral(s).opacity(s == .dark ? 0.22 : 0.16) }

  // The ghost itself: white-ish and faintly luminous in both schemes.
  static func ghostBody(_ s: ColorScheme) -> Color { s == .dark ? DS.Color.hex(0xE9EAFB) : DS.Color.hex(0xFFFFFF) }
  static func ghostEye(_ s: ColorScheme) -> Color { DS.Color.hex(0x2A2D4A) }

  // Extra-round: cards noticeably rounder than the app's 12.
  static let cardRadius: CGFloat = 22
  static let innerRadius: CGFloat = 18
  static let controlRadius: CGFloat = 14

  // Rounded type: friendly, a little floaty.
  static let title = Font.system(size: 25, weight: .heavy, design: .rounded)
  static let label = Font.system(size: 13, weight: .semibold, design: .rounded)
  static let body = Font.system(size: 12.5, weight: .regular, design: .rounded)
  static let caption = Font.system(size: 11.5, weight: .medium, design: .rounded)
  static let button = Font.system(size: 12.5, weight: .bold, design: .rounded)
  static let buttonSmall = Font.system(size: 11, weight: .bold, design: .rounded)
  static let chip = Font.system(size: 10.5, weight: .bold, design: .rounded)
  static let micro = Font.system(size: 10, weight: .semibold, design: .rounded)
}

// MARK: Casper ghost mascot

/// A cute rounded ghost: a dome with a wavy hem, drawn in pure SwiftUI.
private struct CasperGhostShape: Shape {
  var waves: Int = 3

  func path(in rect: CGRect) -> Path {
    var p = Path()
    let hem = rect.height * 0.14
    let hemY = rect.maxY - hem
    let domeR = rect.width / 2

    p.move(to: CGPoint(x: rect.minX, y: hemY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + domeR))
    p.addArc(
      center: CGPoint(x: rect.midX, y: rect.minY + domeR),
      radius: domeR,
      startAngle: .degrees(180),
      endAngle: .degrees(0),
      clockwise: false
    )
    p.addLine(to: CGPoint(x: rect.maxX, y: hemY))

    // Wavy hem, right to left: each segment dips down then lifts back up.
    let seg = rect.width / CGFloat(max(waves, 1))
    for i in 0..<max(waves, 1) {
      let x0 = rect.maxX - seg * CGFloat(i)
      let mid = x0 - seg / 2
      let end = x0 - seg
      p.addQuadCurve(
        to: CGPoint(x: mid, y: hemY),
        control: CGPoint(x: x0 - seg * 0.25, y: rect.maxY)
      )
      p.addQuadCurve(
        to: CGPoint(x: end, y: hemY),
        control: CGPoint(x: mid - seg * 0.25, y: hemY - hem)
      )
    }
    p.closeSubpath()
    return p
  }
}

/// The mascot: ghost body + two dot eyes + a soft glow. Decorative only —
/// always hidden from VoiceOver. `bodyOpacity` drives the "ghost-opacity gauge"
/// (more transparent = more ghosted).
private struct CasperGhostView: View {
  var size: CGFloat = 44
  var bodyOpacity: Double = 1
  var glow = true
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack {
      CasperGhostShape()
        .fill(Casper.ghostBody(scheme).opacity(bodyOpacity))
        .overlay(
          CasperGhostShape()
            .stroke(Casper.spectral(scheme).opacity(0.45 * bodyOpacity), lineWidth: max(1, size * 0.03))
        )
        .shadow(color: glow ? Casper.glow(scheme) : .clear, radius: size * 0.20, y: size * 0.06)
      HStack(spacing: size * 0.14) {
        eye
        eye
      }
      .offset(y: -size * 0.10)
    }
    .frame(width: size, height: size * 1.06)
    .accessibilityHidden(true)
  }

  private var eye: some View {
    Ellipse()
      .fill(Casper.ghostEye(scheme).opacity(min(1, bodyOpacity + 0.15)))
      .frame(width: size * 0.10, height: size * 0.16)
  }
}

/// Gentle 3-4pt vertical bob, slow ease-in-out. Static under Reduce Motion.
private struct CasperFloating: ViewModifier {
  var amplitude: CGFloat = 3.5
  var period: Double = 2.8
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var up = false

  func body(content: Content) -> some View {
    content
      .offset(y: up ? -amplitude : 0)
      .onAppear {
        guard !reduceMotion, !up else { return }
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
          up = true
        }
      }
  }
}

// MARK: Casper card + input

private struct CasperCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  var fill: ((ColorScheme) -> Color)?
  var radius: CGFloat = Casper.cardRadius
  var glow = true

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(fill?(scheme) ?? Casper.paper(scheme))
          .shadow(color: glow ? Casper.glow(scheme) : .clear, radius: 18, y: 8)
          .shadow(color: glow ? Casper.glow(scheme).opacity(0.6) : .clear, radius: 4, y: 2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(Casper.line(scheme), lineWidth: 1)
      )
  }
}

private extension View {
  /// Extra-round card that floats on a soft diffuse glow (no hard shadows).
  func casperCard(
    fill: ((ColorScheme) -> Color)? = nil,
    radius: CGFloat = Casper.cardRadius,
    glow: Bool = true
  ) -> some View {
    modifier(CasperCardModifier(fill: fill, radius: radius, glow: glow))
  }

  /// Text input on the dusk surface — same metrics as `dsInput`, rounder chrome.
  func casperInput(_ scheme: ColorScheme, minHeight: CGFloat? = nil) -> some View {
    textFieldStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(minHeight: minHeight)
      .background(
        RoundedRectangle(cornerRadius: Casper.controlRadius, style: .continuous)
          .fill(Casper.paperDeep(scheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Casper.controlRadius, style: .continuous)
          .strokeBorder(Casper.line(scheme), lineWidth: 1)
      )
  }

  func casperFloating(amplitude: CGFloat = 3.5) -> some View {
    modifier(CasperFloating(amplitude: amplitude))
  }

  func casperButton(_ variant: CasperButtonVariant = .primary, compact: Bool = false) -> some View {
    buttonStyle(CasperButtonStyle(variant: variant, compact: compact))
  }
}

// MARK: Casper buttons

private enum CasperButtonVariant {
  case primary    // spectral fill, soft glow — the friendly CTA
  case secondary  // paper capsule + lavender hairline
  case ghost      // text-only, faint spectral wash on hover
}

private struct CasperButtonStyle: ButtonStyle {
  var variant: CasperButtonVariant = .primary
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    CasperButtonBody(configuration: configuration, variant: variant, compact: compact)
  }
}

private struct CasperButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let variant: CasperButtonVariant
  let compact: Bool

  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  var body: some View {
    let pressed = configuration.isPressed && isEnabled

    configuration.label
      .font(compact ? Casper.buttonSmall : Casper.button)
      .labelStyle(CasperButtonLabelStyle(compact: compact))
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, compact ? 10 : 14)
      .padding(.vertical, compact ? 5 : 7)
      .frame(minHeight: compact ? 24 : 30)
      .background(backgroundShape)
      .scaleEffect(pressed ? 0.97 : 1)
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Capsule())
      .dsAnimation(.easeOut(duration: 0.12), value: pressed)
      .onHover { hovering = $0 }
  }

  @ViewBuilder private var backgroundShape: some View {
    switch variant {
    case .primary:
      Capsule()
        .fill(hovering && isEnabled ? Casper.spectralDeep(scheme) : Casper.spectral(scheme))
        .shadow(color: Casper.spectral(scheme).opacity(isEnabled ? 0.40 : 0), radius: 9, y: 3)
    case .secondary:
      Capsule()
        .fill(hovering && isEnabled ? Casper.spectralDim(scheme) : Casper.paper(scheme))
        .overlay(Capsule().strokeBorder(Casper.line(scheme), lineWidth: 1))
        .shadow(color: Casper.glow(scheme).opacity(isEnabled ? 0.7 : 0), radius: 6, y: 2)
    case .ghost:
      Capsule()
        .fill(hovering && isEnabled ? Casper.spectral(scheme).opacity(0.10) : Color.clear)
    }
  }

  private var foreground: Color {
    switch variant {
    case .primary:
      // The spectral fill flips light/dark, so the label ink flips with it.
      return scheme == .dark ? DS.Color.hex(0x222448) : .white
    case .secondary:
      return Casper.ink(scheme)
    case .ghost:
      return hovering && isEnabled ? Casper.ink(scheme) : Casper.ink2(scheme)
    }
  }
}

/// Keeps a casper button's leading SF Symbol sized + spaced with its title.
private struct CasperButtonLabelStyle: LabelStyle {
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: compact ? 4 : 6) {
      configuration.icon.font(.system(size: compact ? 9.5 : 11, weight: .bold))
      configuration.title
    }
  }
}

// MARK: Casper chips

private struct CasperChip: View {
  let text: String
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Text(text)
      .font(Casper.chip)
      .foregroundStyle(Casper.spectralDeep(scheme))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(Casper.spectralDim(scheme)))
      .overlay(Capsule().strokeBorder(Casper.line(scheme), lineWidth: 1))
  }
}

/// Small label that tells the two Don't Ghost kinds apart at a glance.
/// "Waiting on you" = the ball is in your court (owed reply). "Reach out" = you
/// wrote last and it's gone quiet (follow-up). Warm copy, never scolding.
private struct CasperKindBadge: View {
  let kind: DontGhostKind
  @Environment(\.colorScheme) private var scheme

  private var text: String {
    switch kind {
    case .owedReply: return "Waiting on you"
    case .followUp: return "Reach out"
    }
  }

  private var icon: String {
    switch kind {
    case .owedReply: return "arrowshape.turn.up.left.fill"
    case .followUp: return "hand.wave.fill"
    }
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 8.5, weight: .bold))
      Text(text)
        .font(Casper.chip)
    }
    .foregroundStyle(Casper.spectralDeep(scheme))
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(Capsule().fill(Casper.spectralDim(scheme)))
    .overlay(Capsule().strokeBorder(Casper.line(scheme), lineWidth: 1))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind == .owedReply ? "Waiting on you" : "Reach out")
  }
}

/// The reply-confidence chip as a ghost-opacity gauge: the mini ghost fades as
/// the score rises (more transparent = more ghosted). The "Reply NN%" text is
/// always kept so the number stays readable and accessible.
private struct CasperConfidenceChip: View {
  let confidence: Double
  @Environment(\.colorScheme) private var scheme

  private var ghostOpacity: Double {
    let clamped = min(max(confidence, 0), 1)
    return max(0.25, 1.0 - 0.75 * clamped)
  }

  var body: some View {
    HStack(spacing: 5) {
      CasperGhostView(size: 13, bodyOpacity: ghostOpacity, glow: false)
      Text("Reply \(Int(round(confidence * 100)))%")
        .font(Casper.chip)
        .foregroundStyle(Casper.spectralDeep(scheme))
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .background(Capsule().fill(Casper.spectralDim(scheme)))
    .overlay(Capsule().strokeBorder(Casper.line(scheme), lineWidth: 1))
  }
}

// MARK: - First-open intro (registered in ToolRegistry)

extension DontGhostView {
  /// Registry hook for the first-open intro sheet. The Casper kit stays
  /// file-private; only an opaque AnyView crosses the file boundary.
  static func makeIntro(_ actions: LabIntroActions) -> AnyView {
    AnyView(DontGhostIntroView(actions: actions))
  }
}

/// Dusk-glow landing page: the floating ghost over the twilight canvas,
/// rounded friendly type, and the lab's spectral CTAs.
private struct DontGhostIntroView: View {
  let actions: LabIntroActions
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Casper.canvasTop(scheme), Casper.canvasBottom(scheme)],
        startPoint: .top,
        endPoint: .bottom
      )
      VStack(spacing: 0) {
        CasperGhostView(size: 72)
          .casperFloating()
          .padding(.top, 6)

        Text("See who's waiting on you.")
          .font(Casper.title)
          .foregroundStyle(Casper.ink(scheme))
          .multilineTextAlignment(.center)
          .padding(.top, 18)

        Text("Everyone ghosts a little. Ghostie finds your open loops before they go cold.")
          .font(Casper.body)
          .foregroundStyle(Casper.ink2(scheme))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)

        VStack(alignment: .leading, spacing: 12) {
          benefit("magnifyingglass", "Surfaces replies you still owe, plus quiet threads worth a check-in.")
          benefit("bolt.horizontal", "Ranks them on-device — no API key needed. You write the reply, staged, never sent for you.")
          benefit("checkmark.circle", "Clear one loop and the ghost gets a little more solid.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .casperCard()
        .padding(.top, 22)

        Spacer(minLength: 16)

        Text("Suggestions stay staged on this Mac — nothing sends itself")
          .font(Casper.micro)
          .foregroundStyle(Casper.ink3(scheme))

        HStack(spacing: 12) {
          Button("Not now") { actions.onCancel() }
            .casperButton(.ghost)
            .accessibilityLabel("Not now")
          Button {
            actions.onContinue()
          } label: {
            Label("Find my open loops", systemImage: "arrowshape.turn.up.left.fill")
          }
          .casperButton(.primary)
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("Continue to Don't Ghost")
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
        .foregroundStyle(Casper.spectral(scheme))
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(text)
        .font(Casper.label)
        .foregroundStyle(Casper.ink2(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
