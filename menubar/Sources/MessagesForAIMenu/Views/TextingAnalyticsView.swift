import SwiftUI
import AppKit

// Labs › Texting Analytics — "Mixpanel x Minority Report" exception surface.
// The rest of the app follows .impeccable.md (calm native precision); this lab
// deliberately reads as a precision analytics HUD with a precognitive edge:
// dark-glass chart panels (in BOTH color schemes), luminous cyan/ice data
// accents with one violet secondary, hairline grid/scanlines, glowing stat
// numbers, and "analyzing" sweeps for progress. The entire theme kit is
// file-private (`Precog*`) so nothing leaks outside this view.
struct TextingAnalyticsView: View {
  @StateObject private var controller = TextingAnalyticsController()
  @State private var windowKind: TextingAnalyticsWindow.Kind = .pastYear
  @State private var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
  @State private var customEndDate = Date()
  @State private var includeNames = true
  @State private var threadFilter = ""
  @State private var comparePrevious = false
  @State private var didRequestInitialDashboard = false
  @State private var dashboardRefreshTask: Task<Void, Never>?
  @Environment(\.colorScheme) private var colorScheme
  private let detailCardHeight: CGFloat = 360

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        filtersNav
          .frame(maxWidth: 1180, alignment: .leading)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, PrecogLayout.pageMargin)
      .padding(.top, 16)
      .padding(.bottom, 12)
      .background(DS.Color.g100(colorScheme))
      .overlay(alignment: .bottom) {
        ZStack {
          Rectangle()
            .fill(DS.Color.line(colorScheme))
          LinearGradient(
            colors: [.clear, Precog.chromeAccent(colorScheme).opacity(0.55), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
        }
        .frame(height: 1)
        .accessibilityHidden(true)
      }
      .zIndex(10)

      ScrollView {
        // Lazy so offscreen report sections are not built/laid out during scroll.
        LazyVStack(alignment: .leading, spacing: PrecogLayout.sectionGap) {
          header
            .fullDiskAccessGate(toolName: "Texting Analytics")
          result
        }
        .padding(.horizontal, PrecogLayout.pageMargin)
        .padding(.top, 18)
        .padding(.bottom, PrecogLayout.pageMargin)
        .frame(maxWidth: 1180, alignment: .leading)
      }
      .overlay(alignment: .top) {
        scrollTopScrim
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.Color.g100(colorScheme))
    .onAppear {
      guard !didRequestInitialDashboard else { return }
      didRequestInitialDashboard = true
      loadDashboardFromCacheOrGenerate()
    }
    .onChange(of: windowKind) { _, _ in
      if windowKind == .allTime {
        comparePrevious = false
      }
      scheduleDashboardRefresh()
    }
    .onChange(of: includeNames) { _, _ in
      scheduleDashboardRefresh()
    }
    .onChange(of: threadFilter) { _, _ in
      scheduleDashboardRefresh()
    }
    .onChange(of: comparePrevious) { _, _ in
      scheduleDashboardRefresh()
    }
    .onChange(of: customStartDate) { _, _ in
      if windowKind == .custom { scheduleDashboardRefresh() }
    }
    .onChange(of: customEndDate) { _, _ in
      if windowKind == .custom { scheduleDashboardRefresh() }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Local telemetry")
        .font(Precog.telemetry)
        .tracking(1.8)
        .textCase(.uppercase)
        .foregroundStyle(Precog.chromeAccent(colorScheme))
      Label("Texting Analytics", systemImage: "chart.xyaxis.line")
        .font(DS.Font.paneTitle)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("The analytics workbench behind Texting Wrapped: reply speed, ball-in-court, group presence, your top threads, talk/listen balance, and style signals. Generated locally; no message bodies are saved or transmitted.")
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var scrollTopScrim: some View {
    VStack(spacing: 0) {
      DS.Color.g100(colorScheme)
        .frame(height: 6)
      LinearGradient(
        colors: [
          DS.Color.g100(colorScheme),
          DS.Color.g100(colorScheme).opacity(0)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 18)
    }
    .allowsHitTesting(false)
  }

  private var filtersNav: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
          .font(Precog.telemetry)
          .textCase(.uppercase)
          .foregroundStyle(Precog.chromeAccent(colorScheme))
        Text(filterSummary)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
        Spacer()
        Button {
          controller.generate(
            window: selectedWindow,
            includeNames: includeNames,
            threadFilter: threadFilter,
            comparePrevious: effectiveComparePrevious
          )
        } label: {
          Label(isGenerating ? "Updating..." : "Refresh", systemImage: "arrow.clockwise")
        }
        .dsButton(.primary, size: .small)
        .disabled(isGenerating)
      }

      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Time horizon")
            .font(Precog.micro)
            .tracking(1.1)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .textCase(.uppercase)
          DSSegmentedControl(TextingAnalyticsWindow.Kind.allCases, selection: $windowKind) { $0.rawValue }
          .frame(width: 380)
        }

        VStack(alignment: .leading, spacing: 5) {
          Text("Person or thread")
            .font(Precog.micro)
            .tracking(1.1)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .textCase(.uppercase)
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(DS.Color.ink3(colorScheme))
            TextField("All conversations", text: $threadFilter)
              .textFieldStyle(.plain)
            if !threadFilter.isEmpty {
              Button {
                threadFilter = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.plain)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .help("Clear filter")
            }
          }
          .padding(.horizontal, 10)
          .frame(height: 28)
          .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Color.g080(colorScheme)))
          .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Color.line(colorScheme), lineWidth: 1))
          .frame(minWidth: 220, maxWidth: 320)
        }

        VStack(alignment: .leading, spacing: 5) {
          Text("Options")
            .font(Precog.micro)
            .tracking(1.1)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .textCase(.uppercase)
          HStack(spacing: 14) {
            Toggle("Compare previous", isOn: $comparePrevious)
              .toggleStyle(.checkbox)
              .disabled(windowKind == .allTime)
              .help(windowKind == .allTime ? "All time cannot be compared to a previous period." : "Compare against the prior matching time window.")
            Toggle("Names", isOn: $includeNames)
              .toggleStyle(.checkbox)
          }
          .frame(height: 28, alignment: .leading)
        }

        Spacer(minLength: 0)
      }

      if windowKind == .custom {
        HStack(spacing: 14) {
          DSDateTimeField(title: "Start", selection: $customStartDate, displayedComponents: .date)
          DSDateTimeField(title: "End", selection: $customEndDate, displayedComponents: .date)
          Text("Reports include the full selected days.")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
      }

      if isGenerating {
        HStack(spacing: 10) {
          PrecogSweep()
            .frame(width: 150)
          Text("Analyzing local message telemetry...")
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
      }
    }
    .padding(PrecogLayout.cardPadding)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        .fill(DS.Color.g130(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        .strokeBorder(Precog.chromeAccent(colorScheme).opacity(0.45), lineWidth: 1)
    )
    .shadow(color: Precog.chromeAccent(colorScheme).opacity(0.10), radius: 8, y: 0)
  }

  private var selectedWindow: TextingAnalyticsWindow {
    TextingAnalyticsWindow(kind: windowKind, startDate: customStartDate, endDate: customEndDate)
  }

  private func loadDashboardFromCacheOrGenerate() {
    controller.loadOrGenerate(
      window: selectedWindow,
      includeNames: includeNames,
      threadFilter: threadFilter,
      comparePrevious: effectiveComparePrevious
    )
  }

  private func scheduleDashboardRefresh() {
    dashboardRefreshTask?.cancel()
    let window = selectedWindow
    let shouldIncludeNames = includeNames
    let filter = threadFilter
    let compare = effectiveComparePrevious
    dashboardRefreshTask = Task {
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        controller.loadOrGenerate(
          window: window,
          includeNames: shouldIncludeNames,
          threadFilter: filter,
          comparePrevious: compare
        )
      }
    }
  }

  private var effectiveComparePrevious: Bool {
    comparePrevious && windowKind != .allTime
  }

  private var filterSummary: String {
    var parts = [windowKind.rawValue]
    let trimmed = threadFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      parts.append("matching \(trimmed)")
    }
    if effectiveComparePrevious {
      parts.append("compared")
    }
    return parts.joined(separator: " / ")
  }

  private var isGenerating: Bool {
    if case .generating = controller.state { return true }
    return false
  }

  @ViewBuilder
  private var result: some View {
    switch controller.state {
    case .idle:
      emptyState
    case .generating:
      generatingState
    case .failed(let reason, let fdaMissing):
      failure(reason: reason, fdaMissing: fdaMissing)
    case .done(let report, let jsonURL):
      reportView(report, jsonURL: jsonURL)
    }
  }

  private var generatingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.large)
      Text("Reading your messages…")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
    .accessibilityLabel("Analyzing your messages")
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Image(systemName: "waveform.path.ecg")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Precog.cyan)
          .shadow(color: Precog.cyan.opacity(0.6), radius: 2)
        Text("Preparing dashboard")
          .font(Precog.telemetry)
          .tracking(1.4)
          .textCase(.uppercase)
          .foregroundStyle(Precog.headerInk)
      }
      Text("Texting Analytics runs locally and opens automatically from the latest cached data when available.")
        .font(.system(size: 11))
        .foregroundStyle(Precog.textSecondary)
    }
    .padding(PrecogLayout.cardPadding)
    .frame(maxWidth: 560, alignment: .leading)
    .modifier(PrecogPanelBackground())
    .environment(\.colorScheme, .dark)
  }

  private func failure(reason: String, fdaMissing: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Color.amber(colorScheme))
        Text(reason)
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.ink(colorScheme))
      }
      if fdaMissing {
        Button("Open Full Disk Access settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
          }
        }
        .dsButton(.secondary)
      }
    }
    .padding(PrecogLayout.cardPadding)
    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Color.amberDim(colorScheme)))
    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Color.amber(colorScheme), lineWidth: 1))
  }

  private func reportView(_ report: TextingAnalyticsReport, jsonURL: URL) -> some View {
    VStack(alignment: .leading, spacing: PrecogLayout.sectionGap) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          Text(report.windowLabel ?? "Texting analytics")
            .font(DS.Font.settingsTitle)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text(generatedText(report))
            .font(Precog.micro)
            .tracking(0.6)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([jsonURL])
        } label: {
          Label("Reveal JSON", systemImage: "doc.text.magnifyingglass")
        }
        .dsButton(.secondary)
      }

      metricsGrid(report)

      if let archetype = report.archetype {
        archetypeBlock(archetype)
      }

      if let comparison = report.comparison {
        comparisonBlock(comparison)
      }

      analyticsExplorerIntro
      detailCharts(report)
    }
  }

  private var dashboardColumns: [GridItem] {
    [
      GridItem(.flexible(minimum: 260), spacing: PrecogLayout.cardGap),
      GridItem(.flexible(minimum: 260), spacing: PrecogLayout.cardGap)
    ]
  }

  private func metricsGrid(_ report: TextingAnalyticsReport) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: PrecogLayout.cardGap)], spacing: PrecogLayout.cardGap) {
      PrecogMetricTile(title: "Sent", value: compactNumber(report.totalSent ?? 0), icon: "paperplane.fill", tint: Precog.cyan)
      PrecogMetricTile(title: "Median reply", value: minutesText(report.latency?.medianMinutes), icon: "timer", tint: Precog.ice)
      PrecogMetricTile(title: "Ball in court", value: percentText(report.ballInCourt?.pctBallInCourt), icon: "arrowshape.turn.up.left.fill", tint: Precog.violet)
      PrecogMetricTile(title: "Top thread", value: compactNumber(report.topPeople?.first?.count ?? 0), icon: "person.text.rectangle", tint: Precog.cyan)
    }
  }

  private var analyticsExplorerIntro: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "rectangle.and.text.magnifyingglass")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Precog.chromeAccent(colorScheme))
      Text("Detailed charts")
        .font(Precog.telemetry)
        .tracking(1.6)
        .textCase(.uppercase)
        .foregroundStyle(Precog.chromeAccent(colorScheme))
      Spacer()
    }
    .padding(.top, 2)
  }

  @ViewBuilder
  private func detailCharts(_ report: TextingAnalyticsReport) -> some View {
    LazyVGrid(columns: dashboardColumns, spacing: PrecogLayout.cardGap) {
      // Trend + rhythm own their selection state so tapping a bar or cell
      // re-renders only that panel, not the entire dashboard.
      PrecogTrendPanel(granularity: report.activityTrend?.granularity, rows: report.activityTrend?.rows ?? [])
        .equatable()
        .frame(height: detailCardHeight)
        .gridCellColumns(2)
      replyDistributionBlock(report.latency)
        .frame(height: detailCardHeight)
      ballBlock(report.ballInCourt)
        .frame(height: detailCardHeight)
      PrecogRhythmPanel(buckets: report.rhythm?.buckets ?? [], peakSent: report.rhythm?.peakSent)
        .equatable()
        .frame(height: detailCardHeight)
        .gridCellColumns(2)
      if let hours = report.hours, !(hours.buckets ?? []).isEmpty {
        PrecogHoursPanel(buckets: hours.buckets ?? [], nightOwlPct: hours.nightOwlPct, peakHour: hours.peakHour)
          .equatable()
          .frame(height: detailCardHeight)
          .gridCellColumns(2)
      }
      conversationMixBlock(report.conversationMix)
        .frame(height: detailCardHeight)
      topThreadsChart(
        "Most messages",
        people: report.topPeople ?? [],
        value: { Double($0.count ?? 0) },
        label: { "\($0.count ?? 0) sent" }
      )
      .frame(height: detailCardHeight)
      topThreadsChart(
        "Most words",
        people: report.topPeopleByChars ?? [],
        value: { Double($0.chars ?? 0) },
        label: { compactNumber($0.chars ?? 0) + " chars" }
      )
      .frame(height: detailCardHeight)
      if let talkListen = report.talkListen {
        talkListenBlock(talkListen)
          .frame(height: detailCardHeight)
      } else {
        PrecogPanel(title: "Talk / Listen", icon: "bubble.left.and.bubble.right") {
          unavailableDetail("No talk/listen data is available for this report.")
        }
        .frame(height: detailCardHeight)
      }
      groupBlock(report.groupContribution)
        .frame(height: detailCardHeight)
      styleSignalsBlock(report)
        .frame(height: detailCardHeight)
      if let initiators = report.initiators {
        initiatorsBlock(initiators)
          .frame(height: detailCardHeight)
      }
      if let doubleTexts = report.doubleTexts {
        doubleTextsBlock(doubleTexts)
          .frame(height: detailCardHeight)
      }
      if let topShare = report.topShare {
        topShareBlock(topShare)
          .frame(height: detailCardHeight)
      }
      if report.busiestDay != nil || report.streaks?.best != nil {
        recordsBlock(busiest: report.busiestDay, streaks: report.streaks)
          .frame(height: detailCardHeight)
      }
      if !(report.topPeopleL30 ?? []).isEmpty {
          topThreadsChart(
            "Recent momentum",
            people: report.topPeopleL30 ?? [],
            value: { Double($0.count ?? 0) },
            label: { "\($0.count ?? 0) sent in last 30 days" }
          )
          .frame(height: detailCardHeight)
      }
    }
  }

  private func initiatorsBlock(_ initiators: TextingAnalyticsReport.Initiators) -> some View {
    PrecogPanel(title: "Who Texts First", icon: "arrow.up.right.circle") {
      VStack(alignment: .leading, spacing: 12) {
        if (initiators.conversations ?? 0) == 0 {
          unavailableDetail("No conversation starts were detected in this window.")
        } else {
          HStack(spacing: 16) {
            PrecogBigNumber(value: percentText(initiators.pctYouStart), label: "conversations you start")
            VStack(alignment: .leading, spacing: 3) {
              Text("\(compactNumber(initiators.youStarted ?? 0)) started by you")
              Text("\(compactNumber(initiators.theyStarted ?? 0)) started by them")
            }
            .font(.system(size: 11))
            .foregroundStyle(Precog.textSecondary)
            Spacer()
          }
          PrecogRatioBar(value: initiators.pctYouStart ?? 0, leadingLabel: "You first", trailingLabel: "They first")
          ForEach(Array((initiators.perContact ?? []).prefix(4))) { contact in
            PrecogValueRow(
              label: contact.name ?? "Unknown",
              valueLabel: "\(percentText(contact.pctYouStart)) of \(contact.conversations ?? 0)",
              value: contact.pctYouStart ?? 0,
              maxValue: 100,
              tint: Precog.cyan
            )
          }
          if (initiators.perContact ?? []).isEmpty, !includeNames {
            Text("Contact names are hidden for this report.")
              .font(.system(size: 11))
              .foregroundStyle(Precog.textSecondary)
          }
          Text("A text after 16+ hours of thread silence starts a conversation.")
            .font(.caption2)
            .foregroundStyle(Precog.textTertiary)
        }
      }
    }
  }

  private func doubleTextsBlock(_ doubles: TextingAnalyticsReport.DoubleTexts) -> some View {
    PrecogPanel(title: "Double Texts", icon: "plus.bubble") {
      VStack(alignment: .leading, spacing: 12) {
        if (doubles.outboundMessages ?? 0) == 0 {
          unavailableDetail("No outbound 1:1 messages in this window.")
        } else {
          HStack(spacing: 18) {
            PrecogBigNumber(value: percentText(doubles.ratePct), label: "of your texts double-text")
            PrecogBigNumber(value: compactNumber(doubles.doubleTexts ?? 0), label: "double texts sent")
            Spacer()
          }
          let rows = Array((doubles.perContact ?? []).prefix(4))
          let maxCount = Double(max(1, rows.map { $0.doubleTexts ?? 0 }.max() ?? 1))
          ForEach(rows) { contact in
            PrecogValueRow(
              label: contact.name ?? "Unknown",
              valueLabel: "\(contact.doubleTexts ?? 0) · \(percentText(contact.ratePct))",
              value: Double(contact.doubleTexts ?? 0),
              maxValue: maxCount,
              tint: Precog.violet
            )
          }
          if rows.isEmpty, !includeNames {
            Text("Contact names are hidden for this report.")
              .font(.system(size: 11))
              .foregroundStyle(Precog.textSecondary)
          }
          Text("A follow-up 10+ minutes after your own last message, with no reply in between.")
            .font(.caption2)
            .foregroundStyle(Precog.textTertiary)
        }
      }
    }
  }

  private func topShareBlock(_ share: TextingAnalyticsReport.TopShare) -> some View {
    PrecogPanel(title: "Share Of Volume", icon: "chart.pie") {
      VStack(alignment: .leading, spacing: 12) {
        let people = share.people ?? []
        if people.isEmpty {
          Text(includeNames ? "No 1:1 traffic in this window yet." : "Contact names are hidden for this report.")
            .font(.system(size: 11))
            .foregroundStyle(Precog.textSecondary)
        } else {
          let topPct = people.reduce(0.0) { $0 + ($1.pct ?? 0) }
          HStack(spacing: 16) {
            PrecogBigNumber(value: percentText(topPct), label: "of 1:1 traffic is your top \(people.count)")
            PrecogBigNumber(value: compactNumber(share.total ?? 0), label: "1:1 messages total")
            Spacer()
          }
          let maxPct = max(people.first?.pct ?? 1, share.othersPct ?? 0)
          ForEach(people) { person in
            PrecogValueRow(
              label: person.name ?? "Unknown",
              valueLabel: "\(percentText(person.pct)) · \(compactNumber(person.count ?? 0))",
              value: person.pct ?? 0,
              maxValue: maxPct,
              tint: Precog.cyan
            )
          }
          if (share.othersCount ?? 0) > 0 {
            PrecogValueRow(
              label: "Everyone else",
              valueLabel: "\(percentText(share.othersPct)) · \(compactNumber(share.othersCount ?? 0))",
              value: share.othersPct ?? 0,
              maxValue: maxPct,
              tint: Precog.dimData
            )
          }
        }
      }
    }
  }

  private func recordsBlock(busiest: TextingAnalyticsReport.BusiestDay?, streaks: TextingAnalyticsReport.Streaks?) -> some View {
    PrecogPanel(title: "Records", icon: "trophy") {
      VStack(alignment: .leading, spacing: 14) {
        if let busiest {
          HStack(spacing: 18) {
            PrecogBigNumber(value: compactNumber(busiest.total ?? 0), label: "messages on \(busiestDayText(busiest.date))")
            Spacer()
          }
          Text("\(compactNumber(busiest.sent ?? 0)) sent · \(compactNumber(busiest.received ?? 0)) received")
            .font(.system(size: 11))
            .foregroundStyle(Precog.textSecondary)
        }
        if let best = streaks?.best {
          HStack(spacing: 18) {
            PrecogBigNumber(value: "\(best.days ?? 0) days", label: "longest streak · \(best.name ?? "Unknown")")
            Spacer()
          }
          let rows = Array((streaks?.perContact ?? []).prefix(4))
          let maxDays = Double(max(1, rows.map { $0.days ?? 0 }.max() ?? 1))
          ForEach(rows) { entry in
            PrecogValueRow(
              label: entry.name ?? "Unknown",
              valueLabel: "\(entry.days ?? 0) days",
              value: Double(entry.days ?? 0),
              maxValue: maxDays,
              tint: Precog.ice
            )
          }
        } else if !includeNames {
          Text("Streaks need contact names; they're hidden for this report.")
            .font(.system(size: 11))
            .foregroundStyle(Precog.textSecondary)
        }
      }
    }
  }

  private func busiestDayText(_ raw: String?) -> String {
    guard let raw else { return "your busiest day" }
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    guard let date = parser.date(from: raw) else { return raw }
    let out = DateFormatter()
    out.dateStyle = .medium
    return out.string(from: date)
  }

  private func archetypeBlock(_ archetype: TextingAnalyticsReport.Archetype) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Image(systemName: "sparkle")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Precog.violet)
          .shadow(color: Precog.violet.opacity(0.7), radius: 2)
        Text(archetype.name ?? "Texting archetype")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Precog.textPrimary)
          .shadow(color: Precog.violet.opacity(0.35), radius: 2.5)
      }
      if let verdict = archetype.verdict {
        Text(verdict)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Precog.textPrimary.opacity(0.92))
      }
      if let why = archetype.why {
        Text(why)
          .font(.system(size: 11))
          .foregroundStyle(Precog.textSecondary)
      }
    }
    .padding(PrecogLayout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(PrecogPanelBackground(accent: Precog.violet))
    .environment(\.colorScheme, .dark)
  }

  private func comparisonBlock(_ comparison: TextingAnalyticsReport.Comparison) -> some View {
    PrecogPanel(title: "Compared With Previous Period", icon: "arrow.left.arrow.right") {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.Space.m)], spacing: DS.Space.m) {
        ForEach(comparison.metrics ?? []) { metric in
          VStack(alignment: .leading, spacing: 6) {
            Text(metric.label ?? "Metric")
              .font(Precog.micro)
              .tracking(0.7)
              .textCase(.uppercase)
              .foregroundStyle(Precog.textTertiary)
              .lineLimit(1)
            Text(compareValue(metric.current, unit: metric.unit))
              .font(.system(size: 18, weight: .bold).monospacedDigit())
              .foregroundStyle(Precog.textPrimary)
              .shadow(color: Precog.cyan.opacity(0.45), radius: 2.5)
              .lineLimit(1)
              .minimumScaleFactor(0.75)
            HStack(spacing: 4) {
              Image(systemName: (metric.delta ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.weight(.bold))
              Text(compareDelta(metric.delta, unit: metric.unit))
                .font(.caption2.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(compareTint(metric.delta))
            Text("was \(compareValue(metric.previous, unit: metric.unit))")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(Precog.textTertiary)
              .lineLimit(1)
          }
          .padding(DS.Space.m)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Precog.cyan.opacity(0.14)))
        }
      }
    }
  }

  private func conversationMixBlock(_ mix: TextingAnalyticsReport.ConversationMix?) -> some View {
    PrecogPanel(title: "Conversation Mix", icon: "square.grid.2x2") {
      VStack(alignment: .leading, spacing: 12) {
        let oneToOneSent = mix?.oneToOne?.sent ?? 0
        let groupSent = mix?.groups?.sent ?? 0
        let sentTotal = oneToOneSent + groupSent
        let oneToOneReceived = mix?.oneToOne?.received ?? 0
        let groupReceived = mix?.groups?.received ?? 0
        let receivedTotal = oneToOneReceived + groupReceived

        HStack(spacing: 16) {
          PrecogBigNumber(value: percentText(outboundOneToOnePct(mix)), label: "sent messages in 1:1s")
          PrecogBigNumber(value: compactNumber(sentTotal), label: "sent total")
          PrecogBigNumber(value: compactNumber(receivedTotal), label: "received total")
          Spacer()
        }

        PrecogValueRow(
          label: "Sent to 1:1 threads",
          valueLabel: compactNumber(oneToOneSent),
          value: Double(oneToOneSent),
          maxValue: Double(max(1, sentTotal)),
          tint: Precog.cyan
        )
        PrecogValueRow(
          label: "Sent to groups",
          valueLabel: compactNumber(groupSent),
          value: Double(groupSent),
          maxValue: Double(max(1, sentTotal)),
          tint: Precog.violet
        )
        PrecogValueRow(
          label: "Received from 1:1 threads",
          valueLabel: compactNumber(oneToOneReceived),
          value: Double(oneToOneReceived),
          maxValue: Double(max(1, receivedTotal)),
          tint: Precog.ice
        )
        PrecogValueRow(
          label: "Received from groups",
          valueLabel: compactNumber(groupReceived),
          value: Double(groupReceived),
          maxValue: Double(max(1, receivedTotal)),
          tint: Precog.dimData
        )

        if let kinds = mix?.kinds {
          Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .accessibilityHidden(true)
          ForEach(Array(kinds.keys.sorted().prefix(3)), id: \.self) { kind in
            let sent = kinds[kind]?.sent ?? 0
            let received = kinds[kind]?.received ?? 0
            PrecogValueRow(
              label: kind.capitalized,
              valueLabel: "\(compactNumber(sent)) sent / \(compactNumber(received)) received",
              value: Double(sent + received),
              maxValue: Double(max(1, kinds.values.map { ($0.sent ?? 0) + ($0.received ?? 0) }.max() ?? 1)),
              tint: kind == "reaction" ? Precog.violet : Precog.cyan
            )
          }
        }
      }
    }
  }

  private func replyDistributionBlock(_ latency: TextingAnalyticsReport.Latency?) -> some View {
    PrecogPanel(title: "Reply Speed Distribution", icon: "timer") {
      VStack(alignment: .leading, spacing: 14) {
        PrecogDistributionBars(rows: replyDistributionRows(latency))
          .frame(height: 150)
        HStack(spacing: 20) {
          PrecogBigNumber(value: minutesText(latency?.medianMinutes), label: "median reply")
          PrecogBigNumber(value: minutesText(latency?.meanMinutes), label: "mean reply")
          Spacer()
        }
        Text("\(latency?.totalReplyPairs ?? 0) reply pairs across \(latency?.threadCount ?? 0) threads")
          .font(.system(size: 11))
          .foregroundStyle(Precog.textSecondary)
      }
    }
  }

  private func replyDistributionRows(_ latency: TextingAnalyticsReport.Latency?) -> [PrecogDistributionRow] {
    let p5 = clamp(latency?.pctWithin5Min ?? 0)
    let p30 = clamp(latency?.pctWithin30Min ?? 0)
    let p60 = clamp(latency?.pctWithin1Hr ?? 0)
    let p240 = clamp(latency?.pctWithin4Hr ?? 0)
    return [
      PrecogDistributionRow(label: "<5m", value: p5, tint: Precog.cyan),
      PrecogDistributionRow(label: "5-30m", value: max(0, p30 - p5), tint: Precog.ice),
      PrecogDistributionRow(label: "30-60m", value: max(0, p60 - p30), tint: Precog.violet),
      PrecogDistributionRow(label: "1-4h", value: max(0, p240 - p60), tint: Precog.amber),
      PrecogDistributionRow(label: ">4h", value: max(0, 100 - p240), tint: Precog.red)
    ]
  }

  private func ballBlock(_ ball: TextingAnalyticsReport.BallInCourt?) -> some View {
    PrecogPanel(title: "Ball In Court", icon: "arrowshape.turn.up.left.circle") {
      VStack(alignment: .leading, spacing: 20) {
        PrecogGauge(value: ball?.pctBallInCourt ?? 0, tint: Precog.violet)
        HStack(spacing: 18) {
          PrecogBigNumber(value: compactNumber(ball?.threadsWithBallInCourt ?? 0), label: "threads waiting")
          PrecogBigNumber(value: compactNumber(ball?.totalThreadsSampled ?? 0), label: "sampled threads")
          PrecogBigNumber(value: compactNumber(ball?.liveConversationsEstimate ?? 0), label: "live conversations")
          Spacer()
        }
      }
    }
  }

  private func groupBlock(_ group: TextingAnalyticsReport.GroupContribution?) -> some View {
    PrecogPanel(title: "Group Presence", icon: "person.3") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 16) {
          PrecogBigNumber(value: percentText(group?.userContributionPct), label: "your share")
          VStack(alignment: .leading, spacing: 3) {
            Text("\(group?.totalGroupsAnalyzed ?? 0) groups analyzed")
            Text("\(group?.groupsWhereUserSilent ?? 0) silent groups")
            Text("\(group?.groupsMostlyReactions ?? 0) mostly reactions")
          }
          .font(.system(size: 11))
          .foregroundStyle(Precog.textSecondary)
        }
        ForEach(Array((group?.perThread ?? []).prefix(4))) { thread in
          PrecogValueRow(
            label: thread.threadLabel ?? "Group",
            valueLabel: percentText(thread.userPct),
            value: thread.userPct ?? 0,
            maxValue: 100,
            tint: Precog.ice
          )
        }
      }
    }
  }

  private func talkListenBlock(_ talkListen: TextingAnalyticsReport.TalkListen) -> some View {
    PrecogPanel(title: "Talk / Listen", icon: "bubble.left.and.bubble.right") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 16) {
          PrecogBigNumber(value: percentText(talkListen.yourSharePct), label: "your share of words")
          VStack(alignment: .leading, spacing: 3) {
            Text("\(compactNumber(talkListen.youWords ?? 0)) words from you")
            Text("\(compactNumber(talkListen.themWords ?? 0)) words from others")
          }
          .font(.system(size: 11))
          .foregroundStyle(Precog.textSecondary)
        }
        PrecogRatioBar(value: talkListen.yourSharePct ?? 0, leadingLabel: "You", trailingLabel: "Them")
        ForEach(Array((talkListen.perThread ?? []).prefix(4))) { person in
          PrecogValueRow(
            label: person.name ?? "Unknown",
            valueLabel: percentText(person.yourSharePct),
            value: person.yourSharePct ?? 0,
            maxValue: 100,
            tint: Precog.cyan
          )
        }
      }
    }
  }

  private func topThreadsChart(
    _ title: String,
    people: [TextingAnalyticsReport.PersonCount],
    value: @escaping (TextingAnalyticsReport.PersonCount) -> Double,
    label: @escaping (TextingAnalyticsReport.PersonCount) -> String
  ) -> some View {
    PrecogPanel(title: title, icon: "person.text.rectangle") {
      let rows = Array(people.prefix(6))
      let maxValue = rows.map(value).max() ?? 1
      VStack(alignment: .leading, spacing: 10) {
        if rows.isEmpty {
          Text(includeNames ? "No thread data yet." : "Contact names are hidden for this report.")
            .font(.system(size: 11))
            .foregroundStyle(Precog.textSecondary)
        } else {
          ForEach(rows) { person in
            PrecogValueRow(
              label: person.name ?? "Unknown",
              valueLabel: label(person),
              value: value(person),
              maxValue: maxValue,
              tint: Precog.cyan
            )
          }
        }
      }
    }
  }

  private func styleSignalsBlock(_ report: TextingAnalyticsReport) -> some View {
    PrecogPanel(title: "Style Signals", icon: "waveform") {
      VStack(alignment: .leading, spacing: 12) {
        PrecogValueRow(
          label: "No terminal punctuation",
          valueLabel: percentText(report.style?.pctNoTerminalPunct),
          value: report.style?.pctNoTerminalPunct ?? 0,
          maxValue: 100,
          tint: Precog.cyan
        )
        PrecogValueRow(
          label: "Messages with emoji",
          valueLabel: percentText(report.emoji?.pctMessagesWithEmoji),
          value: report.emoji?.pctMessagesWithEmoji ?? 0,
          maxValue: 100,
          tint: Precog.violet
        )
        HStack {
          if let emoji = report.emoji?.topEmoji, !emoji.isEmpty {
            Text(emoji.prefix(5).joined(separator: " "))
              .font(.system(size: 24))
              .lineLimit(1)
          } else {
            Text("No top emoji for this report.")
              .font(.system(size: 11))
              .foregroundStyle(Precog.textSecondary)
          }
          Spacer()
        }
      }
    }
  }

  private func generatedText(_ report: TextingAnalyticsReport) -> String {
    guard let ms = report.generatedAtMs else { return "Generated locally" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return "Generated \(f.localizedString(for: date, relativeTo: Date()))"
  }

  private func outboundOneToOnePct(_ mix: TextingAnalyticsReport.ConversationMix?) -> Double? {
    let oneToOne = mix?.oneToOne?.sent ?? 0
    let groups = mix?.groups?.sent ?? 0
    let total = oneToOne + groups
    guard total > 0 else { return nil }
    return Double(oneToOne) * 100 / Double(total)
  }

  private func percentText(_ value: Double?) -> String {
    PrecogFormat.percentText(value)
  }

  private func compareValue(_ value: Double?, unit: String?) -> String {
    guard let value else { return "0" }
    switch unit {
    case "percent":
      return "\(trim(value))%"
    case "minutes":
      return minutesText(value)
    case "count":
      return compactNumber(Int(value.rounded()))
    default:
      return trim(value)
    }
  }

  private func compareDelta(_ value: Double?, unit: String?) -> String {
    let delta = value ?? 0
    let sign = delta > 0 ? "+" : ""
    switch unit {
    case "percent":
      return "\(sign)\(trim(delta)) pts"
    case "minutes":
      return "\(sign)\(minutesText(delta))"
    case "count":
      return "\(sign)\(compactNumber(Int(delta.rounded())))"
    default:
      return "\(sign)\(trim(delta))"
    }
  }

  private func compareTint(_ value: Double?) -> Color {
    let delta = value ?? 0
    if abs(delta) < 0.05 { return Precog.textTertiary }
    return delta > 0 ? Precog.cyan : Precog.violet
  }

  private func minutesText(_ value: Double?) -> String {
    guard let value else { return "0 min" }
    let absValue = abs(value)
    let sign = value < 0 ? "-" : ""
    if absValue >= 60 {
      return "\(sign)\(trim(absValue / 60)) hr"
    }
    return "\(sign)\(trim(absValue)) min"
  }

  private func charsText(_ value: Double?) -> String {
    guard let value else { return "0 chars" }
    return "\(trim(value)) chars"
  }

  private func unavailableDetail(_ message: String) -> some View {
    Text(message)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(Precog.textSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(DS.Space.m)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
  }

  private func clamp(_ value: Double) -> Double {
    max(0, min(value, 100))
  }

  private func compactNumber(_ value: Int) -> String {
    PrecogFormat.compactNumber(value)
  }

  private func trim(_ value: Double) -> String {
    PrecogFormat.trim(value)
  }
}

// MARK: - Layout tokens (file-private)

/// One inner padding, one inter-card gap, one page margin — every card and grid
/// in this lab uses these three so spacing stays consistent panel-to-panel.
private enum PrecogLayout {
  static let cardPadding: CGFloat = DS.Space.l       // 16 — inner padding of every card/panel
  static let cardGap: CGFloat = 14                   // gap between cards in every grid
  static let pageMargin: CGFloat = DS.Space.xxxl     // 28 — horizontal page margin
  static let sectionGap: CGFloat = DS.Space.sectionGap // 22 — gap between page sections
}

// MARK: - Shared formatting (file-private)

private enum PrecogFormat {
  static func compactNumber(_ value: Int) -> String {
    if value >= 1_000_000 {
      let n = Double(value) / 1_000_000
      return "\(trim(n))M"
    }
    if value >= 10_000 {
      let n = Double(value) / 1_000
      return "\(trim(n))K"
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  static func trim(_ value: Double) -> String {
    if abs(value.rounded() - value) < 0.05 {
      return "\(Int(value.rounded()))"
    }
    return String(format: "%.1f", value)
  }

  static func percentText(_ value: Double?) -> String {
    guard let value else { return "0%" }
    return "\(trim(value))%"
  }

  static func weekdayName(_ weekday: Int?) -> String {
    let symbols = Calendar.current.shortWeekdaySymbols
    let idx = max(0, min(weekday ?? 0, symbols.count - 1))
    return symbols[idx]
  }

  static func hourText(_ hour: Int?) -> String {
    let h = max(0, min(hour ?? 0, 23))
    let date = Calendar.current.date(from: DateComponents(hour: h, minute: 0)) ?? Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "ha"
    return formatter.string(from: date).lowercased()
  }
}

// MARK: - Precog theme kit (file-private — must not leak outside this lab)

/// Palette + type for the precision-HUD theme. Chart panels are dark glass in
/// BOTH schemes, so every in-panel color below is fixed (scheme-independent);
/// only the `chrome*` helpers adapt to the window's light/dark scheme.
private enum Precog {
  // Luminous data accents.
  static let cyan = DS.Color.hex(0x59E0FF)
  static let ice = DS.Color.hex(0xA9D6FF)
  static let violet = DS.Color.hex(0xA78BFA)
  static let amber = DS.Color.hex(0xE8B45A)
  static let red = DS.Color.hex(0xFF6B63)
  static let dimData = DS.Color.hex(0x8FA6BA)

  // Dark-glass panel paper — deep ink with a blue cast and subtle translucency.
  static let panelTop = SwiftUI.Color(.sRGB, red: 0.078, green: 0.110, blue: 0.157, opacity: 0.96)
  static let panelBottom = SwiftUI.Color(.sRGB, red: 0.039, green: 0.063, blue: 0.102, opacity: 0.97)

  // In-panel ink (fixed: panels are always dark).
  static let textPrimary = DS.Color.hex(0xEAF4FF)
  static let textSecondary = DS.Color.hex(0x9FB6C9)
  static let textTertiary = DS.Color.hex(0x66809B)
  static let headerInk = DS.Color.hex(0x7FAECB)

  // Hairline grid / scanlines inside panels (very low contrast).
  static let scanline = cyan.opacity(0.045)
  static let gridline = cyan.opacity(0.035)
  static let track = SwiftUI.Color.white.opacity(0.08)
  static let trackEdge = SwiftUI.Color.white.opacity(0.05)

  /// Theme accent for light-mode-aware chrome (headers, hairlines) outside the
  /// dark-glass panels — deep teal in light so it stays legible on paper.
  static func chromeAccent(_ scheme: ColorScheme) -> SwiftUI.Color {
    scheme == .dark ? cyan : DS.Color.hex(0x0E7FA8)
  }

  // Type — system font throughout (premium telemetry, not terminal).
  static let telemetry = SwiftUI.Font.system(size: 10.5, weight: .semibold)
  static let micro = SwiftUI.Font.system(size: 9.5, weight: .medium)
  static let statBig = SwiftUI.Font.system(size: 28, weight: .bold).monospacedDigit()
  static let statHuge = SwiftUI.Font.system(size: 42, weight: .bold).monospacedDigit()
  static let statSmall = SwiftUI.Font.system(size: 22, weight: .bold).monospacedDigit()
}

/// Hairline scanlines + faint vertical grid drawn into a panel background.
/// Purely decorative.
private struct PrecogGridLines: View {
  var body: some View {
    Canvas { ctx, size in
      var horizontal = Path()
      var y: CGFloat = 8
      while y < size.height {
        horizontal.move(to: CGPoint(x: 0, y: y))
        horizontal.addLine(to: CGPoint(x: size.width, y: y))
        y += 7
      }
      ctx.stroke(horizontal, with: .color(Precog.scanline), lineWidth: 0.5)
      var vertical = Path()
      var x: CGFloat = 36
      while x < size.width {
        vertical.move(to: CGPoint(x: x, y: 0))
        vertical.addLine(to: CGPoint(x: x, y: size.height))
        x += 44
      }
      ctx.stroke(vertical, with: .color(Precog.gridline), lineWidth: 0.5)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Small HUD corner brackets along a panel's edge. Purely decorative.
private struct PrecogCornerBrackets: View {
  var accent: Color = Precog.cyan

  var body: some View {
    GeometryReader { geo in
      let inset: CGFloat = 5
      let arm: CGFloat = 9
      let w = geo.size.width
      let h = geo.size.height
      Path { p in
        // Top-left
        p.move(to: CGPoint(x: inset, y: inset + arm))
        p.addLine(to: CGPoint(x: inset, y: inset))
        p.addLine(to: CGPoint(x: inset + arm, y: inset))
        // Top-right
        p.move(to: CGPoint(x: w - inset - arm, y: inset))
        p.addLine(to: CGPoint(x: w - inset, y: inset))
        p.addLine(to: CGPoint(x: w - inset, y: inset + arm))
        // Bottom-right
        p.move(to: CGPoint(x: w - inset, y: h - inset - arm))
        p.addLine(to: CGPoint(x: w - inset, y: h - inset))
        p.addLine(to: CGPoint(x: w - inset - arm, y: h - inset))
        // Bottom-left
        p.move(to: CGPoint(x: inset + arm, y: h - inset))
        p.addLine(to: CGPoint(x: inset, y: h - inset))
        p.addLine(to: CGPoint(x: inset, y: h - inset - arm))
      }
      .stroke(accent.opacity(0.40), lineWidth: 1)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Dark-glass panel paper: ink gradient + scanlines + precise 1px luminous
/// border + a faint accent halo. Used by every chart surface in this lab.
private struct PrecogPanelBackground: ViewModifier {
  var accent: Color = Precog.cyan
  var radius: CGFloat = 10
  var brackets: Bool = true

  func body(content: Content) -> some View {
    content
      .background(
        ZStack {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
              LinearGradient(
                colors: [Precog.panelTop, Precog.panelBottom],
                startPoint: .top,
                endPoint: .bottom
              )
            )
          PrecogGridLines()
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        // Rasterize the static decoration (gradient + ~80 hairline strokes)
        // into one Metal layer; scrolling then translates a cached texture
        // instead of re-stroking every scanline per panel per frame.
        .drawingGroup()
        .accessibilityHidden(true)
      )
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(accent.opacity(0.38), lineWidth: 1)
          .accessibilityHidden(true)
      )
      .overlay {
        if brackets {
          PrecogCornerBrackets(accent: accent)
        }
      }
      // One shadow pass per panel (was two — the accent halo cost a second
      // full-panel blur every frame during scroll; the luminous border carries
      // the accent now).
      .shadow(color: Color.black.opacity(0.22), radius: 8, y: 5)
  }
}

/// Chart panel: telemetry header (small uppercase system-font label + glowing
/// icon) over content on dark-glass paper. The content environment is forced
/// dark so any scheme-following sub-styles resolve legibly in light mode too.
private struct PrecogPanel<Content: View>: View {
  let title: String
  let icon: String
  let content: Content

  init(title: String, icon: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.icon = icon
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 7) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Precog.cyan)
          .shadow(color: Precog.cyan.opacity(0.6), radius: 2)
        Text(title)
          .font(Precog.telemetry)
          .tracking(1.4)
          .textCase(.uppercase)
          .foregroundStyle(Precog.headerInk)
        Spacer(minLength: 0)
        Circle()
          .fill(Precog.cyan)
          .frame(width: 4, height: 4)
          .shadow(color: Precog.cyan.opacity(0.85), radius: 2)
          .accessibilityHidden(true)
      }
      content
    }
    .padding(PrecogLayout.cardPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .modifier(PrecogPanelBackground())
    .environment(\.colorScheme, .dark)
  }
}

/// Headline metric tile: glowing stat number + telemetry caption + a decorative
/// mini sparkline, on its own piece of dark glass.
private struct PrecogMetricTile: View {
  let title: String
  let value: String
  let icon: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(tint)
          .shadow(color: tint.opacity(0.6), radius: 2)
        Spacer()
        PrecogSparkline(tint: tint)
          .frame(width: 34, height: 10)
      }
      Text(value)
        .font(Precog.statSmall)
        .foregroundStyle(Precog.textPrimary)
        .shadow(color: Precog.cyan.opacity(0.5), radius: 2.5)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(title)
        .font(Precog.micro)
        .tracking(0.9)
        .textCase(.uppercase)
        .foregroundStyle(Precog.textTertiary)
    }
    .padding(PrecogLayout.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(PrecogPanelBackground(radius: 9, brackets: false))
    .environment(\.colorScheme, .dark)
  }
}

/// Static decorative sparkline accent (no data semantics).
private struct PrecogSparkline: View {
  let tint: Color

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      Path { p in
        p.move(to: CGPoint(x: 0, y: h * 0.75))
        p.addLine(to: CGPoint(x: w * 0.2, y: h * 0.45))
        p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.65))
        p.addLine(to: CGPoint(x: w * 0.58, y: h * 0.25))
        p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.5))
        p.addLine(to: CGPoint(x: w, y: h * 0.1))
      }
      .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// "Analyzing" sweep — a luminous segment traversing a hairline track.
/// Reduce-Motion renders a calm static fill instead of the animation.
private struct PrecogSweep: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var phase: CGFloat = -0.35

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
        Capsule()
          .fill(
            LinearGradient(
              colors: [Precog.cyan.opacity(0), Precog.cyan, Precog.cyan.opacity(0)],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: geo.size.width * 0.35)
          .offset(x: geo.size.width * phase)
          .shadow(color: Precog.cyan.opacity(0.7), radius: 2.5)
      }
      .clipShape(Capsule())
    }
    .frame(height: 3)
    .onAppear {
      if reduceMotion {
        phase = 0.325
      } else {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
          phase = 1.0
        }
      }
    }
    .accessibilityHidden(true)
  }
}

private struct PrecogDistributionRow: Identifiable {
  let label: String
  let value: Double
  let tint: Color

  var id: String { label }
}

private struct PrecogDistributionBars: View {
  let rows: [PrecogDistributionRow]

  var body: some View {
    GeometryReader { geo in
      HStack(alignment: .bottom, spacing: 10) {
        ForEach(rows) { row in
          VStack(spacing: 6) {
            Text("\(Int(row.value.rounded()))%")
              .font(Precog.micro.monospacedDigit())
              .foregroundStyle(Precog.textSecondary)
            ZStack(alignment: .bottom) {
              RoundedRectangle(cornerRadius: 4)
                .fill(Precog.track)
              RoundedRectangle(cornerRadius: 4)
                .fill(
                  LinearGradient(
                    colors: [row.tint, row.tint.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                  )
                )
                .frame(height: max(3, geo.size.height * 0.58 * CGFloat(max(0, min(row.value, 100)) / 100)))
            }
            .frame(maxWidth: .infinity)
            Text(row.label)
              .font(Precog.micro)
              .foregroundStyle(Precog.textTertiary)
              .lineLimit(1)
          }
        }
      }
    }
  }
}

/// Ball-in-court gauge: glowing headline %, luminous fill on a ticked track,
/// with the same balanced/value markers as before (non-color signals stay).
private struct PrecogGauge: View {
  let value: Double
  let tint: Color

  var body: some View {
    let clamped = max(0, min(value, 100))
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(Int(clamped.rounded()))%")
          .font(Precog.statHuge)
          .foregroundStyle(Precog.textPrimary)
          .shadow(color: Precog.cyan.opacity(0.55), radius: 3)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text("waiting on you")
          .font(.system(size: 11))
          .foregroundStyle(Precog.textSecondary)
        Spacer()
      }

      VStack(alignment: .leading, spacing: 8) {
        GeometryReader { proxy in
          let fillWidth = proxy.size.width * CGFloat(clamped / 100)
          ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(Precog.track)
            // Decorative tick ruler under the fill.
            Canvas { ctx, size in
              var ticks = Path()
              for i in 1..<10 {
                let x = size.width * CGFloat(i) / 10
                ticks.move(to: CGPoint(x: x, y: size.height - 5))
                ticks.addLine(to: CGPoint(x: x, y: size.height))
              }
              ctx.stroke(ticks, with: .color(Color.white.opacity(0.14)), lineWidth: 1)
            }
            .accessibilityHidden(true)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [Precog.cyan, tint],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(width: fillWidth)
              .shadow(color: Precog.cyan.opacity(0.5), radius: 2)
            Rectangle()
              .fill(Precog.ice.opacity(0.58))
              .frame(width: 1.5, height: 14)
              .offset(x: proxy.size.width * 0.5)
            Rectangle()
              .fill(Precog.textPrimary)
              .frame(width: 2, height: 16)
              .offset(x: max(0, min(proxy.size.width - 2, fillWidth)))
              .shadow(color: Precog.cyan.opacity(0.8), radius: 2)
          }
          .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 16)

        HStack(spacing: 0) {
          Text("clear")
            .frame(maxWidth: .infinity, alignment: .leading)
          Text("balanced")
            .frame(maxWidth: .infinity, alignment: .center)
          Text("waiting")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Precog.micro)
        .foregroundStyle(Precog.textTertiary)
        .frame(height: 12)
      }
    }
  }
}

private struct PrecogValueRow: View {
  let label: String
  let valueLabel: String
  let value: Double
  let maxValue: Double
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(label)
          .font(.system(size: 11))
          .foregroundStyle(Precog.textPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        Text(valueLabel)
          .font(Precog.micro.monospacedDigit())
          .foregroundStyle(Precog.textSecondary)
          .lineLimit(1)
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Precog.track)
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Precog.trackEdge, lineWidth: 0.5)
            .accessibilityHidden(true)
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
              LinearGradient(
                colors: [tint, tint.opacity(0.6)],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: geo.size.width * CGFloat(ratio))
        }
      }
      .frame(height: 7)
    }
  }

  private var ratio: Double {
    guard maxValue > 0 else { return 0 }
    return max(0.03, min(value / maxValue, 1))
  }
}

private struct PrecogRatioBar: View {
  let value: Double
  let leadingLabel: String
  let trailingLabel: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geo in
        let clamped = max(0, min(value, 100))
        HStack(spacing: 0) {
          Rectangle()
            .fill(
              LinearGradient(
                colors: [Precog.cyan, Precog.ice],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: geo.size.width * CGFloat(clamped / 100))
          Rectangle()
            .fill(Precog.track)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      }
      .frame(height: 10)
      HStack {
        Text(leadingLabel)
        Spacer()
        Text(trailingLabel)
      }
      .font(.caption2)
      .foregroundStyle(Precog.textSecondary)
    }
  }
}

private struct PrecogBigNumber: View {
  let value: String
  let label: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(Precog.statBig)
        .foregroundStyle(Precog.textPrimary)
        .shadow(color: Precog.cyan.opacity(0.5), radius: 2.5)
      Text(label)
        .font(Precog.micro)
        .tracking(0.7)
        .textCase(.uppercase)
        .foregroundStyle(Precog.textTertiary)
    }
  }
}

private struct PrecogLegendDot: View {
  let label: String
  let tint: Color

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
        .shadow(color: tint.opacity(0.7), radius: 2)
      Text(label)
        .font(.caption2)
        .foregroundStyle(Precog.textSecondary)
    }
  }
}

private struct PrecogTrendChart: View {
  let rows: [TextingAnalyticsReport.ActivityTrend.Row]
  @Binding var selected: TextingAnalyticsReport.ActivityTrend.Row?

  private var visibleRows: [TextingAnalyticsReport.ActivityTrend.Row] {
    rows.count > 72 ? Array(rows.suffix(72)) : rows
  }

  private var maxTotal: Double {
    Double(max(1, visibleRows.map { ($0.sent ?? 0) + ($0.received ?? 0) }.max() ?? 1))
  }

  var body: some View {
    GeometryReader { geo in
      let chartHeight = max(44, geo.size.height - 22)
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
          Button {
            selected = row
          } label: {
            VStack(spacing: 4) {
              ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.white.opacity(0.05))
                VStack(spacing: 1) {
                  Spacer(minLength: 0)
                  Rectangle()
                    .fill(
                      LinearGradient(
                        colors: [Precog.cyan, Precog.cyan.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                      )
                    )
                    .frame(height: barHeight(row.sent ?? 0, chartHeight: chartHeight))
                  Rectangle()
                    .fill(Precog.violet.opacity(0.75))
                    .frame(height: barHeight(row.received ?? 0, chartHeight: chartHeight))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
              }
              .overlay {
                // Glow only exists on the selected bar — a per-bar shadow
                // effect (even with .clear color) costs a blur node for all
                // ~72 bars during scroll.
                if selected == row {
                  RoundedRectangle(cornerRadius: 4)
                    .stroke(Precog.cyan, lineWidth: 1.5)
                    .shadow(color: Precog.cyan.opacity(0.7), radius: 2.5)
                }
              }
              .frame(maxWidth: .infinity)
              .frame(height: chartHeight)

              if shouldLabel(index) {
                Text(shortLabel(row))
                  .font(.caption2)
                  .foregroundStyle(Precog.textTertiary)
                  .lineLimit(1)
                  .minimumScaleFactor(0.65)
              } else {
                Color.clear.frame(height: 10)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func barHeight(_ value: Int, chartHeight: CGFloat) -> CGFloat {
    max(value == 0 ? 0 : 3, chartHeight * CGFloat(Double(value) / maxTotal))
  }

  private func shouldLabel(_ index: Int) -> Bool {
    let step = max(1, visibleRows.count / 6)
    return index == 0 || index == visibleRows.count - 1 || index % step == 0
  }

  private func shortLabel(_ row: TextingAnalyticsReport.ActivityTrend.Row) -> String {
    let raw = row.label ?? row.period ?? ""
    if raw.count <= 7 { return raw }
    return String(raw.suffix(5))
  }
}

private struct PrecogRhythmHeatmap: View {
  let buckets: [TextingAnalyticsReport.Rhythm.Bucket]
  @Binding var selected: TextingAnalyticsReport.Rhythm.Bucket?
  // weekday*24+hour → bucket, built once. The previous `buckets.first { … }`
  // linear scan ran 168×168 comparisons on every render of the heatmap.
  private let bucketByCell: [Int: TextingAnalyticsReport.Rhythm.Bucket]
  private let maxSent: Double

  init(buckets: [TextingAnalyticsReport.Rhythm.Bucket], selected: Binding<TextingAnalyticsReport.Rhythm.Bucket?>) {
    self.buckets = buckets
    self._selected = selected
    var byCell = [Int: TextingAnalyticsReport.Rhythm.Bucket](minimumCapacity: buckets.count)
    for bucket in buckets {
      byCell[(bucket.weekday ?? 0) * 24 + (bucket.hour ?? 0)] = bucket
    }
    self.bucketByCell = byCell
    self.maxSent = Double(max(1, buckets.map { $0.sent ?? 0 }.max() ?? 1))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Color.clear.frame(width: 32, height: 1)
        ForEach(0..<24, id: \.self) { hour in
          Text(hourLabel(hour))
            .font(.system(size: 8))
            .foregroundStyle(Precog.textTertiary)
            .frame(maxWidth: .infinity)
            .opacity(hour % 6 == 0 ? 1 : 0)
        }
      }

      ForEach(0..<7, id: \.self) { weekday in
        HStack(spacing: 4) {
          Text(weekdayLabel(weekday))
            .font(.caption2)
            .foregroundStyle(Precog.textTertiary)
            .frame(width: 32, alignment: .trailing)
          ForEach(0..<24, id: \.self) { hour in
            let bucket = bucketAt(weekday: weekday, hour: hour)
            Button {
              selected = bucket
            } label: {
              RoundedRectangle(cornerRadius: 3)
                .fill(Precog.cyan.opacity(opacity(for: bucket)))
                .overlay {
                  // Selection glow only on the one selected cell — a shadow
                  // node on all 168 cells (even .clear) is a real scroll cost.
                  if selected == bucket {
                    RoundedRectangle(cornerRadius: 3)
                      .stroke(Precog.cyan, lineWidth: 1.5)
                      .shadow(color: Precog.cyan.opacity(0.7), radius: 2)
                  } else {
                    RoundedRectangle(cornerRadius: 3)
                      .stroke(Color.white.opacity(0.06), lineWidth: 1)
                  }
                }
                .frame(maxWidth: .infinity, minHeight: 13)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func bucketAt(weekday: Int, hour: Int) -> TextingAnalyticsReport.Rhythm.Bucket {
    bucketByCell[weekday * 24 + hour]
      ?? TextingAnalyticsReport.Rhythm.Bucket(weekday: weekday, hour: hour, sent: 0, received: 0, total: 0)
  }

  private func opacity(for bucket: TextingAnalyticsReport.Rhythm.Bucket) -> Double {
    let ratio = Double(bucket.sent ?? 0) / maxSent
    return max(0.06, 0.18 + ratio * 0.68)
  }

  private func weekdayLabel(_ weekday: Int) -> String {
    let symbols = Calendar.current.shortWeekdaySymbols
    let idx = max(0, min(weekday, symbols.count - 1))
    return symbols[idx]
  }

  private func hourLabel(_ hour: Int) -> String {
    switch hour {
    case 0: return "12a"
    case 6: return "6a"
    case 12: return "12p"
    case 18: return "6p"
    default: return ""
    }
  }
}

// MARK: - Self-contained chart panels
//
// These own their selection @State and conform to Equatable (used via
// `.equatable()`), so tapping a bar/cell re-renders one panel — and a parent
// re-render skips them entirely when the report data hasn't changed.

private struct PrecogTrendPanel: View, Equatable {
  let granularity: String?
  let rows: [TextingAnalyticsReport.ActivityTrend.Row]
  @State private var selected: TextingAnalyticsReport.ActivityTrend.Row?

  static func == (lhs: PrecogTrendPanel, rhs: PrecogTrendPanel) -> Bool {
    lhs.granularity == rhs.granularity && lhs.rows == rhs.rows
  }

  var body: some View {
    PrecogPanel(title: "Activity Trend", icon: "chart.line.uptrend.xyaxis") {
      VStack(alignment: .leading, spacing: 12) {
        if rows.isEmpty {
          Text("No activity trend is available for this report yet.")
            .font(.caption)
            .foregroundStyle(Precog.textSecondary)
        } else {
          PrecogTrendChart(rows: rows, selected: $selected)
            .frame(height: 190)
          HStack(spacing: 16) {
            PrecogLegendDot(label: "Sent", tint: Precog.cyan)
            PrecogLegendDot(label: "Received", tint: Precog.violet.opacity(0.8))
            Spacer()
            Text("Grouped by \(granularity ?? "period")")
              .font(.caption2)
              .foregroundStyle(Precog.textTertiary)
          }
          if let selected {
            HStack(spacing: 18) {
              PrecogBigNumber(value: PrecogFormat.compactNumber(selected.sent ?? 0), label: "sent \(selected.label ?? selected.period ?? "")")
              PrecogBigNumber(value: PrecogFormat.compactNumber(selected.received ?? 0), label: "received")
              Spacer()
            }
          }
        }
      }
    }
    .onChange(of: rows) { _, _ in
      selected = nil
    }
  }
}

private struct PrecogRhythmPanel: View, Equatable {
  let buckets: [TextingAnalyticsReport.Rhythm.Bucket]
  let peakSent: TextingAnalyticsReport.Rhythm.Bucket?
  @State private var selected: TextingAnalyticsReport.Rhythm.Bucket?

  static func == (lhs: PrecogRhythmPanel, rhs: PrecogRhythmPanel) -> Bool {
    lhs.buckets == rhs.buckets && lhs.peakSent == rhs.peakSent
  }

  var body: some View {
    PrecogPanel(title: "Texting Rhythm", icon: "calendar.day.timeline.left") {
      VStack(alignment: .leading, spacing: 12) {
        if buckets.isEmpty {
          Text("No rhythm data is available for this report yet.")
            .font(.caption)
            .foregroundStyle(Precog.textSecondary)
        } else {
          PrecogRhythmHeatmap(buckets: buckets, selected: $selected)
            .frame(minHeight: 188)
          HStack(spacing: 16) {
            PrecogLegendDot(label: "Quieter", tint: Precog.cyan.opacity(0.25))
            PrecogLegendDot(label: "Busier", tint: Precog.cyan)
            Spacer()
            Text("Tap a cell for the exact count.")
              .font(.caption2)
              .foregroundStyle(Precog.textTertiary)
          }
          if let bucket = selected ?? peakSent {
            HStack(spacing: 18) {
              PrecogBigNumber(value: PrecogFormat.compactNumber(bucket.sent ?? 0), label: "\(PrecogFormat.weekdayName(bucket.weekday)) at \(PrecogFormat.hourText(bucket.hour)) sent")
              PrecogBigNumber(value: PrecogFormat.compactNumber(bucket.received ?? 0), label: "received then")
              Spacer()
            }
          }
        }
      }
    }
    .onChange(of: buckets) { _, _ in
      selected = nil
    }
  }
}

private struct PrecogHoursPanel: View, Equatable {
  let buckets: [TextingAnalyticsReport.Hours.Bucket]
  let nightOwlPct: Double?
  let peakHour: Int?
  @State private var selected: TextingAnalyticsReport.Hours.Bucket?

  static func == (lhs: PrecogHoursPanel, rhs: PrecogHoursPanel) -> Bool {
    lhs.buckets == rhs.buckets && lhs.nightOwlPct == rhs.nightOwlPct && lhs.peakHour == rhs.peakHour
  }

  var body: some View {
    PrecogPanel(title: "Hour Of Day", icon: "moon.stars") {
      VStack(alignment: .leading, spacing: 12) {
        PrecogHourChart(buckets: buckets, selected: $selected)
          .frame(height: 170)
        HStack(spacing: 16) {
          PrecogLegendDot(label: "Sent", tint: Precog.cyan)
          PrecogLegendDot(label: "Received", tint: Precog.violet.opacity(0.8))
          Spacer()
          Text("Tap an hour for the exact counts.")
            .font(.caption2)
            .foregroundStyle(Precog.textTertiary)
        }
        HStack(spacing: 18) {
          PrecogBigNumber(value: PrecogFormat.percentText(nightOwlPct), label: "night owl · sent 12am–4am")
          if let selected {
            PrecogBigNumber(value: PrecogFormat.compactNumber(selected.sent ?? 0), label: "sent at \(PrecogFormat.hourText(selected.hour))")
            PrecogBigNumber(value: PrecogFormat.compactNumber(selected.received ?? 0), label: "received then")
          } else if let peakHour {
            PrecogBigNumber(value: PrecogFormat.hourText(peakHour), label: "busiest hour")
          }
          Spacer()
        }
      }
    }
    .onChange(of: buckets) { _, _ in
      selected = nil
    }
  }
}

private struct PrecogHourChart: View {
  let buckets: [TextingAnalyticsReport.Hours.Bucket]
  @Binding var selected: TextingAnalyticsReport.Hours.Bucket?

  private var maxTotal: Double {
    Double(max(1, buckets.map { ($0.sent ?? 0) + ($0.received ?? 0) }.max() ?? 1))
  }

  var body: some View {
    GeometryReader { geo in
      let chartHeight = max(44, geo.size.height - 16)
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(buckets) { bucket in
          Button {
            selected = bucket
          } label: {
            VStack(spacing: 4) {
              ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.white.opacity(0.05))
                VStack(spacing: 1) {
                  Spacer(minLength: 0)
                  Rectangle()
                    .fill(
                      LinearGradient(
                        colors: [Precog.cyan, Precog.cyan.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                      )
                    )
                    .frame(height: barHeight(bucket.sent ?? 0, chartHeight: chartHeight))
                  Rectangle()
                    .fill(Precog.violet.opacity(0.75))
                    .frame(height: barHeight(bucket.received ?? 0, chartHeight: chartHeight))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
              }
              .overlay {
                if selected == bucket {
                  RoundedRectangle(cornerRadius: 4)
                    .stroke(Precog.cyan, lineWidth: 1.5)
                    .shadow(color: Precog.cyan.opacity(0.7), radius: 2.5)
                }
              }
              .frame(maxWidth: .infinity)
              .frame(height: chartHeight)

              Text(hourTick(bucket.hour ?? 0))
                .font(.system(size: 8))
                .foregroundStyle(Precog.textTertiary)
                .frame(height: 10)
                .opacity((bucket.hour ?? 0) % 6 == 0 ? 1 : 0)
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func barHeight(_ value: Int, chartHeight: CGFloat) -> CGFloat {
    max(value == 0 ? 0 : 3, chartHeight * CGFloat(Double(value) / maxTotal))
  }

  private func hourTick(_ hour: Int) -> String {
    switch hour {
    case 0: return "12a"
    case 6: return "6a"
    case 12: return "12p"
    case 18: return "6p"
    default: return ""
    }
  }
}

// MARK: - First-open intro (registered in ToolRegistry)

extension TextingAnalyticsView {
  /// Registry hook for the first-open intro sheet. The Precog kit stays
  /// file-private; only an opaque AnyView crosses the file boundary.
  static func makeIntro(_ actions: LabIntroActions) -> AnyView {
    AnyView(TextingAnalyticsIntroView(actions: actions))
  }
}

/// Dashboard-flavored landing page: one full-bleed piece of dark glass with
/// the HUD's scanlines, brackets, and luminous accents. Forced dark like
/// every Precog panel so it reads identically in both window schemes.
private struct TextingAnalyticsIntroView: View {
  let actions: LabIntroActions

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Precog.panelTop, Precog.panelBottom],
        startPoint: .top,
        endPoint: .bottom
      )
      PrecogGridLines()
      PrecogCornerBrackets()
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 7) {
          Image(systemName: "chart.xyaxis.line")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Precog.cyan)
            .shadow(color: Precog.cyan.opacity(0.6), radius: 2)
            .accessibilityHidden(true)
          Text("Texting Analytics · Personal telemetry")
            .font(Precog.telemetry)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(Precog.headerInk)
        }

        Text("Your texting,\nquantified.")
          .font(.system(size: 36, weight: .bold))
          .foregroundStyle(Precog.textPrimary)
          .shadow(color: Precog.cyan.opacity(0.4), radius: 3)
          .padding(.top, 18)
          .accessibilityLabel("Your texting, quantified")

        VStack(alignment: .leading, spacing: 14) {
          metric("bolt.fill", Precog.cyan, "Volume, timing, and streaks across every thread.")
          metric("person.2.fill", Precog.violet, "Who you talk to most — and who's fading out.")
          metric("clock.fill", Precog.amber, "Your reply-time distribution, hour by hour.")
        }
        .padding(.top, 26)

        Spacer(minLength: 16)

        Text("computed on-device · metadata only · no message bodies")
          .font(Precog.micro)
          .tracking(1.1)
          .textCase(.uppercase)
          .foregroundStyle(Precog.textTertiary)

        HStack(spacing: 12) {
          Button("Not now") { actions.onCancel() }
            .buttonStyle(PrecogIntroButtonStyle(prominent: false))
            .accessibilityLabel("Not now")
          Button("Run the numbers") { actions.onContinue() }
            .buttonStyle(PrecogIntroButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Continue to Texting Analytics")
        }
        .padding(.top, 14)
      }
      .padding(38)
    }
    .environment(\.colorScheme, .dark)
  }

  private func metric(_ icon: String, _ tint: Color, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .shadow(color: tint.opacity(0.6), radius: 2)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(text)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Precog.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// HUD buttons for the intro only — luminous cyan plate (prominent) or a
/// hairline ghost. The dashboard itself keeps DS controls for its chrome.
private struct PrecogIntroButtonStyle: ButtonStyle {
  var prominent: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return configuration.label
      .font(.system(size: 12, weight: .bold))
      .tracking(0.4)
      .lineLimit(1)
      .foregroundStyle(prominent ? Color(.sRGB, red: 0.02, green: 0.07, blue: 0.10) : Precog.textSecondary)
      .padding(.horizontal, 16)
      .frame(height: 32)
      .background(shape.fill(prominent ? Precog.cyan : Color.white.opacity(0.05)))
      .overlay(shape.strokeBorder(prominent ? Color.clear : Precog.track, lineWidth: 1))
      .shadow(color: prominent ? Precog.cyan.opacity(pressed ? 0.2 : 0.45) : .clear, radius: pressed ? 3 : 7, y: 2)
      .offset(y: pressed ? 1 : 0)
      .opacity(pressed ? 0.92 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
  }
}
