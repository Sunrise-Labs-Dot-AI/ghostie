import SwiftUI

/// BYOK AI spend surface (issue #145), nested in Settings → Advanced alongside
/// the AI key it depends on (no spend without a key). Month-to-date estimated
/// cost, a monthly budget cap with fail-closed enforcement, a per-feature
/// breakdown, model-downgrade suggestions, and a short recent-calls log. All
/// numbers are local estimates — the provider's billing is authoritative. No
/// message text is ever shown or stored.
///
/// Rendered as a plain VStack (Settings owns the ScrollView + card chrome), so
/// it slots in next to `aiKeysSection` without nesting a scroll view.
struct AIUsageSettingsSection: View {
  @EnvironmentObject private var usageLedger: AIUsageLedger
  @EnvironmentObject private var textingVoice: TextingVoiceController
  @Environment(\.colorScheme) private var colorScheme

  @State private var capText: String = ""

  private var summary: AIUsageMonthSummary { usageLedger.summary() }
  private var budget: AIUsageBudget { usageLedger.budget }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      caption
      spendLine
      if let cap = budget.monthlyCapUSD, cap > 0 { capProgress(cap: cap) }
      if summary.estimatedCount > 0 || summary.unknownPriceCount > 0 {
        Text(estimateCaveat)
          .font(DS.Font.monoMicro)
          .foregroundStyle(DS.Color.amber(colorScheme))
      }

      divider
      budgetControls

      if !summary.byFeature.isEmpty {
        divider
        breakdown
      }
      if !downgradeSuggestions.isEmpty {
        divider
        downgrade
      }
      divider
      recentCalls

      Text("Costs are local estimates from a built-in price table; your provider's billing is the source of truth.")
        .font(DS.Font.monoMicro)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
    .onAppear { syncCapText() }
    .onChange(of: budget.monthlyCapUSD) { _, _ in syncCapText() }
  }

  private var divider: some View {
    Rectangle().fill(DS.Color.line(colorScheme)).frame(height: 1)
  }

  // MARK: - header

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        .foregroundStyle(DS.Color.accentTeal(colorScheme))
      Text("AI usage & costs")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Spacer()
      if !usageLedger.eventsNewestFirst.isEmpty {
        Button("Clear") { usageLedger.clearHistory() }
          .dsButton(.ghost, size: .small)
          .help("Clear the local usage log")
      }
    }
  }

  private var caption: some View {
    Text("Estimated spend on your own AI key. Metadata only — no message text is recorded.")
      .font(DS.Font.settingsCaption)
      .foregroundStyle(DS.Color.ink3(colorScheme))
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - month-to-date spend

  private var spendLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("This month")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Spacer()
      Text("\(summary.callCount) call\(summary.callCount == 1 ? "" : "s")")
        .font(DS.Font.monoMicro)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Text(Self.money(summary.totalUSD))
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .foregroundStyle(DS.Color.ink(colorScheme))
        .monospacedDigit()
    }
  }

  private func capProgress(cap: Double) -> some View {
    let fraction = cap > 0 ? min(1.0, summary.totalUSD / cap) : 0
    let over = summary.totalUSD >= cap
    return VStack(alignment: .leading, spacing: 4) {
      ProgressView(value: fraction)
        .tint(over ? DS.Color.amber(colorScheme) : DS.Color.green(colorScheme))
      Text("\(Self.money(summary.totalUSD)) of \(Self.money(cap)) cap\(over ? " — reached" : "")")
        .font(DS.Font.monoMicro)
        .foregroundStyle(over ? DS.Color.amber(colorScheme) : DS.Color.ink3(colorScheme))
    }
  }

  private var estimateCaveat: String {
    var parts: [String] = []
    if summary.estimatedCount > 0 { parts.append("\(summary.estimatedCount) estimated (no token counts returned)") }
    if summary.unknownPriceCount > 0 { parts.append("\(summary.unknownPriceCount) at an unknown model price") }
    return "≈ " + parts.joined(separator: "; ")
  }

  // MARK: - budget cap

  private var budgetControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Monthly budget")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      HStack(spacing: 8) {
        Text("$")
          .font(DS.Font.monoValue)
          .foregroundStyle(DS.Color.ink3(colorScheme))
        TextField("No cap", text: $capText)
          .dsInput(colorScheme)
          .frame(width: 100)
          .onSubmit { commitCap() }
        Button("Set") { commitCap() }
          .dsButton(.secondary, size: .small)
        if budget.monthlyCapUSD != nil {
          Button("Remove") { usageLedger.setMonthlyCap(nil) }
            .dsButton(.ghost, size: .small)
        }
        Spacer()
      }
      Toggle(isOn: Binding(get: { budget.enforce }, set: { usageLedger.setEnforce($0) })) {
        Text("Block AI calls once the cap is reached")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink(colorScheme))
      }
      .toggleStyle(.switch)
      Text(budgetNote)
        .font(DS.Font.monoMicro)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var budgetNote: String {
    guard budget.monthlyCapUSD != nil else {
      return "No cap set — features run freely. Set one to get warnings as you approach it."
    }
    let warns = "Warns at \(thresholdLabel)"
    return budget.enforce
      ? "\(warns); stops new AI calls once the cap is reached until you raise or remove it."
      : "\(warns); never blocks (advisory only)."
  }

  private var thresholdLabel: String {
    budget.warnThresholds.map { "\(Int(($0 * 100).rounded()))%" }.joined(separator: " / ")
  }

  // MARK: - per-feature breakdown

  private var breakdown: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("By feature, this month")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      ForEach(summary.byFeature) { rollup in
        HStack(alignment: .firstTextBaseline) {
          Text(rollup.lab.label)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Spacer()
          Text("\(rollup.calls) · \(Self.compactTokens(rollup.inputTokens + rollup.outputTokens)) tok")
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
          Text(rollup.hasUnknownCost ? "≈ \(Self.money(rollup.costUSD))" : Self.money(rollup.costUSD))
            .font(DS.Font.monoValue)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .monospacedDigit()
            .frame(width: 64, alignment: .trailing)
        }
      }
    }
  }

  // MARK: - downgrade suggestions

  private struct Downgrade: Identifiable {
    let lab: AILab
    let provider: TextingVoiceProvider
    let recommendedModelID: String
    let savingsPct: Int
    var id: String { lab.rawValue }
  }

  private var downgradeSuggestions: [Downgrade] {
    AILab.allCases.compactMap { lab in
      guard let selection = LabModelPreferences.clientSelection(for: lab),
            let alt = AIUsageEstimate.cheaperAlternative(
              for: lab, provider: selection.provider, currentModelID: selection.modelID
            ) else { return nil }
      return Downgrade(lab: lab, provider: selection.provider, recommendedModelID: alt.modelID, savingsPct: alt.savingsPct)
    }
  }

  private var downgrade: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Spend less without losing much")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      ForEach(downgradeSuggestions) { suggestion in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(suggestion.lab.label) usually runs well on \(Self.shortModel(suggestion.recommendedModelID))")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink(colorScheme))
              .fixedSize(horizontal: false, vertical: true)
            Text("~\(suggestion.savingsPct)% less per run")
              .font(DS.Font.monoMicro)
              .foregroundStyle(DS.Color.green(colorScheme))
          }
          Spacer()
          Button("Use it") {
            textingVoice.setModelSelection(suggestion.recommendedModelID, for: suggestion.lab, provider: suggestion.provider)
          }
          .dsButton(.secondary, size: .small)
        }
      }
    }
  }

  // MARK: - recent calls

  private var recentCalls: some View {
    let recent = Array(usageLedger.eventsNewestFirst.prefix(8))
    return VStack(alignment: .leading, spacing: 8) {
      Text("Recent calls")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      if recent.isEmpty {
        Text("No AI calls yet. Run any AI feature and its cost shows up here.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
      } else {
        ForEach(recent) { event in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.aiLab?.label ?? event.lab)
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink(colorScheme))
              .lineLimit(1)
            Text(Self.shortModel(event.modelID))
              .font(DS.Font.monoMicro)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .lineLimit(1)
            if event.status != .ok {
              Text(Self.statusLabel(event.status))
                .font(DS.Font.monoMicro)
                .foregroundStyle(DS.Color.amber(colorScheme))
            }
            Spacer(minLength: 0)
            Text(Self.tokenLabel(event))
              .font(DS.Font.monoMicro)
              .foregroundStyle(DS.Color.ink3(colorScheme))
            Text(Self.costLabel(event))
              .font(DS.Font.monoValue)
              .foregroundStyle(DS.Color.ink(colorScheme))
              .monospacedDigit()
              .frame(width: 60, alignment: .trailing)
          }
        }
      }
    }
  }

  // MARK: - actions / formatting

  private func syncCapText() {
    capText = budget.monthlyCapUSD.map { String(format: $0 == $0.rounded() ? "%.0f" : "%.2f", $0) } ?? ""
  }

  private func commitCap() {
    let trimmed = capText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
    if trimmed.isEmpty {
      usageLedger.setMonthlyCap(nil)
      return
    }
    if let value = Double(trimmed), value > 0 {
      usageLedger.setMonthlyCap(value)
    }
    syncCapText()
  }

  static func money(_ value: Double) -> String {
    if value <= 0 { return "$0.00" }
    if value < 0.01 { return "<$0.01" }
    return String(format: "$%.2f", value)
  }

  static func compactTokens(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
  }

  static func shortModel(_ modelID: String) -> String {
    let lowered = modelID.lowercased()
    if lowered.contains("haiku") { return "Haiku" }
    if lowered.contains("sonnet") { return "Sonnet" }
    if lowered.contains("opus") { return "Opus" }
    if lowered.contains("mini") { return "GPT mini" }
    if lowered.contains("pro") { return "GPT pro" }
    if lowered.contains("gpt-5") { return "GPT-5" }
    return modelID
  }

  static func statusLabel(_ status: AIUsageStatus) -> String {
    switch status {
    case .ok: return ""
    case .error: return "error"
    case .cancelled: return "cancelled"
    case .blockedByBudget: return "blocked"
    }
  }

  static func tokenLabel(_ event: AIUsageEvent) -> String {
    guard let input = event.inputTokens, let output = event.outputTokens else { return "tok n/a" }
    return "\(compactTokens(input + output)) tok"
  }

  static func costLabel(_ event: AIUsageEvent) -> String {
    if event.status == .blockedByBudget { return "—" }
    guard let cost = event.costUSD else { return "n/a" }
    let prefix = event.costBasis == .exact ? "" : "≈ "
    return prefix + money(cost)
  }
}
