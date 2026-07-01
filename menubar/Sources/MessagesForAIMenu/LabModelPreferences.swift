import Foundation

enum AILab: String, CaseIterable, Identifiable {
  case textingStyle
  case dontGhost
  case eq
  case workPersonal
  case deepRead

  var id: String { rawValue }

  var label: String {
    switch self {
    case .textingStyle: return "Texting Style"
    case .dontGhost: return "Don't Ghost"
    case .eq: return "EQ"
    case .workPersonal: return "Severance"
    case .deepRead: return "Wrapped Deep Read"
    }
  }

  var recommendation: String {
    switch self {
    case .textingStyle:
      return "Highest-quality style writing."
    case .dontGhost:
      return "Balanced scan model for many threads."
    case .eq:
      return "Highest-quality reflection."
    case .workPersonal:
      return "Fast message labeling."
    case .deepRead:
      return "Short reasoning over aggregate stats."
    }
  }

  // Defaults selected by the 2026-06-10 model eval: Haiku 4.5 matched or beat the larger
  // models on the JSON triage/classification tasks at 1/5 the cost; Opus 4.8
  // won the blind-judged reflection task.
  //
  // Don't Ghost UPDATED 2026-06-13: after the "worth a nudge" prompt rewrite, a
  // real-data eval (60 threads) showed Sonnet judged relationship nuance markedly
  // better than Haiku — it surfaced the warm follow-ups the user wanted while
  // still pruning acks/logistics/reactions/transactional noise, whereas Haiku got
  // sloppier (re-surfaced logistics/reactions) under the lean-surface rubric. The
  // boost is opt-in, so the extra cost only applies when the user turns it on.
  func recommendedModelID(for provider: TextingVoiceProvider) -> String {
    switch (self, provider) {
    case (.dontGhost, .anthropic):
      return "claude-sonnet-4-6"
    case (.dontGhost, .openAI):
      return "gpt-5.5"
    case (.workPersonal, .anthropic):
      return "claude-haiku-4-5"
    case (.workPersonal, .openAI):
      return "gpt-5.4-mini"
    // Not part of that eval: Deep Read reasons over a compact aggregate
    // payload, so the mid tier carries it without the Opus price.
    case (.deepRead, .anthropic):
      return "claude-sonnet-4-6"
    case (_, .anthropic):
      return "claude-opus-4-8"
    case (_, .openAI):
      return "gpt-5.5"
    }
  }

  func recommendedProvider(from savedProviders: [TextingVoiceProvider]) -> TextingVoiceProvider? {
    if savedProviders.contains(.anthropic) { return .anthropic }
    return savedProviders.first
  }
}

struct LabModelSelection {
  let provider: TextingVoiceProvider
  let apiKey: String
  let modelID: String
}

enum LabModelPreferences {
  private static func providerKey(_ lab: AILab) -> String {
    "aiLab.\(lab.rawValue).provider"
  }

  private static func modelKey(_ lab: AILab, provider: TextingVoiceProvider) -> String {
    "aiLab.\(lab.rawValue).model.\(provider.rawValue)"
  }

  static func selectedProvider(for lab: AILab, savedProviders: [TextingVoiceProvider]) -> TextingVoiceProvider? {
    if let raw = UserDefaults.standard.string(forKey: providerKey(lab)),
       let provider = TextingVoiceProvider(rawValue: raw),
       savedProviders.contains(provider) {
      return provider
    }

    if lab == .textingStyle,
       let raw = UserDefaults.standard.string(forKey: "textingVoice.provider"),
       let provider = TextingVoiceProvider(rawValue: raw),
       savedProviders.contains(provider) {
      return provider
    }

    return lab.recommendedProvider(from: savedProviders)
  }

  static func setProvider(_ provider: TextingVoiceProvider, for lab: AILab) {
    UserDefaults.standard.set(provider.rawValue, forKey: providerKey(lab))
    if lab == .textingStyle {
      UserDefaults.standard.set(provider.rawValue, forKey: "textingVoice.provider")
    }
  }

  static func modelID(
    for lab: AILab,
    provider: TextingVoiceProvider,
    options: [TextingVoiceModelOption]
  ) -> String {
    let saved = UserDefaults.standard.string(forKey: modelKey(lab, provider: provider))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    if let saved, options.contains(where: { $0.id == saved }) {
      return saved
    }

    if lab == .textingStyle,
       let legacy = UserDefaults.standard.string(forKey: "textingVoice.modelOverride.\(provider.rawValue)")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty,
       options.contains(where: { $0.id == legacy }) {
      return legacy
    }

    let recommended = lab.recommendedModelID(for: provider)
    if options.contains(where: { $0.id == recommended }) {
      return recommended
    }
    return options.first?.id ?? recommended
  }

  static func modelIDWithoutOptions(for lab: AILab, provider: TextingVoiceProvider) -> String {
    let saved = UserDefaults.standard.string(forKey: modelKey(lab, provider: provider))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    if let saved { return saved }
    if lab == .textingStyle,
       let legacy = UserDefaults.standard.string(forKey: "textingVoice.modelOverride.\(provider.rawValue)")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty {
      return legacy
    }
    return lab.recommendedModelID(for: provider)
  }

  static func setModelID(_ modelID: String, for lab: AILab, provider: TextingVoiceProvider) {
    UserDefaults.standard.set(modelID, forKey: modelKey(lab, provider: provider))
    if lab == .textingStyle {
      UserDefaults.standard.set(modelID, forKey: "textingVoice.modelOverride.\(provider.rawValue)")
    }
  }

  /// "AI boost" for Don't Ghost: when on (default) AND a key is present, the LLM
  /// refines which threads surface; when off, surfacing is fully deterministic
  /// (on-device, no key/cost). Keyed in UserDefaults so the view's @AppStorage
  /// and the controller read the same value. Default true preserves prior
  /// behavior for users who already have a key configured.
  static let dontGhostAIBoostKey = "aiLab.dontGhost.boostEnabled"
  static var dontGhostAIBoostEnabled: Bool {
    get { UserDefaults.standard.object(forKey: dontGhostAIBoostKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: dontGhostAIBoostKey) }
  }

  static func clientSelection(for lab: AILab) -> LabModelSelection? {
    let savedProviders = TextingVoiceProvider.allCases.filter { TextingVoiceKeychain.hasAPIKey($0) }
    guard let provider = selectedProvider(for: lab, savedProviders: savedProviders),
          let apiKey = TextingVoiceKeychain.loadAPIKey(provider) else { return nil }
    let stored = modelIDWithoutOptions(for: lab, provider: provider)
    return LabModelSelection(
      provider: provider,
      apiKey: apiKey,
      modelID: validatedModelID(stored, lab: lab, provider: provider)
    )
  }

  // MARK: - Deprecation resilience

  /// The live model catalog (written whenever a provider's /models endpoint
  /// is fetched). Lets every lab call-site survive model retirements: a
  /// stored selection that no longer exists falls back to the lab's
  /// recommended model, then to the first live model.
  static func liveModelsKey(_ provider: TextingVoiceProvider) -> String {
    "aiLab.liveModels.\(provider.rawValue)"
  }

  static func storeLiveModels(_ ids: [String], provider: TextingVoiceProvider) {
    guard !ids.isEmpty else { return }
    UserDefaults.standard.set(ids, forKey: liveModelsKey(provider))
  }

  static func liveModels(for provider: TextingVoiceProvider) -> [String]? {
    let ids = UserDefaults.standard.stringArray(forKey: liveModelsKey(provider))
    return (ids?.isEmpty == false) ? ids : nil
  }

  static func validatedModelID(_ stored: String, lab: AILab, provider: TextingVoiceProvider) -> String {
    guard let live = liveModels(for: provider), !live.contains(stored) else { return stored }
    let recommended = lab.recommendedModelID(for: provider)
    if live.contains(recommended) { return recommended }
    // Recommended is gone too (very stale defaults) — take the closest
    // live model rather than guaranteeing a 404.
    return live.first ?? recommended
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

enum AIUsageEstimate {
  /// Rough token consumption for a typical run of each feature — the basis for
  /// the static "Est. $X" labels AND the fallback cost when a provider response
  /// omits real `usage` counts. Single source of truth.
  static func perFeatureTokens(_ lab: AILab) -> (input: Int, output: Int) {
    switch lab {
    case .textingStyle: return (120_000, 12_000)
    case .dontGhost:    return (80_000, 6_000)
    case .eq:           return (90_000, 3_000)
    case .workPersonal: return (50_000, 4_000)
    case .deepRead:     return (9_000, 1_200)
    }
  }

  private static func actionSuffix(_ lab: AILab) -> String {
    switch lab {
    case .textingStyle: return "per regeneration"
    case .dontGhost:    return "per scan"
    case .eq:           return "per report"
    case .workPersonal: return "per classification run"
    case .deepRead:     return "per read"
    }
  }

  static func label(for lab: AILab, provider: TextingVoiceProvider, modelID: String) -> String {
    let tokens = perFeatureTokens(lab)
    return "Est. \(range(provider: provider, modelID: modelID, inputTokens: tokens.input, outputTokens: tokens.output)) \(actionSuffix(lab))"
  }

  static func eqLabel(provider: TextingVoiceProvider, modelID: String, depth: EQContextDepth) -> String {
    let input: Int
    switch depth {
    case .recent: input = 35_000
    case .pastYear: input = 80_000
    case .threadArc: input = 95_000
    }
    return "Estimated cost: \(range(provider: provider, modelID: modelID, inputTokens: input, outputTokens: 3_000))"
  }

  private static func range(provider: TextingVoiceProvider, modelID: String, inputTokens: Int, outputTokens: Int) -> String {
    guard let pricing = pricing(provider: provider, modelID: modelID) else { return "varies by model" }
    let estimate = (Double(inputTokens) / 1_000_000.0 * pricing.inputPerMillion)
      + (Double(outputTokens) / 1_000_000.0 * pricing.outputPerMillion)
    if estimate < 0.01 { return "<$0.01" }
    let lower = max(0.01, estimate * 0.7)
    let upper = max(lower, estimate * 1.35)
    return "$\(money(lower))-$\(money(upper))"
  }

  private static func money(_ value: Double) -> String {
    if value < 1 {
      return String(format: "%.2f", value)
    }
    return String(format: "%.2f", value)
  }

  private static func pricing(provider: TextingVoiceProvider, modelID: String) -> (inputPerMillion: Double, outputPerMillion: Double)? {
    let lowered = modelID.lowercased()
    switch provider {
    case .anthropic:
      if lowered.contains("haiku") { return (0.80, 4.0) }
      if lowered.contains("sonnet") { return (3.0, 15.0) }
      if lowered.contains("opus") { return (15.0, 75.0) }
    case .openAI:
      if lowered.contains("mini") { return (0.25, 2.0) }
      if lowered.contains("pro") { return (30.0, 180.0) }
      if lowered.contains("gpt-5") { return (5.0, 30.0) }
    }
    return nil
  }

  // MARK: - actual-cost helpers (issue #145 — BYOK cost tracking)

  /// Exact cost from real token counts. Returns `(nil, .estimated)` when the
  /// provider omitted token counts (caller falls back to `estimatedCostUSD`), and
  /// `(nil, .unknownPrice)` when the model isn't in the price table — never a
  /// fabricated or silently-zero figure.
  static func costUSD(
    provider: TextingVoiceProvider,
    modelID: String,
    inputTokens: Int?,
    outputTokens: Int?
  ) -> (usd: Double?, basis: AICostBasis) {
    guard let pricing = pricing(provider: provider, modelID: modelID) else { return (nil, .unknownPrice) }
    guard let input = inputTokens, let output = outputTokens else { return (nil, .estimated) }
    let usd = (Double(input) / 1_000_000.0 * pricing.inputPerMillion)
      + (Double(output) / 1_000_000.0 * pricing.outputPerMillion)
    return (usd, .exact)
  }

  /// Per-feature estimated cost (used when real token counts are unavailable).
  static func estimatedCostUSD(lab: AILab, provider: TextingVoiceProvider, modelID: String) -> Double? {
    guard let pricing = pricing(provider: provider, modelID: modelID) else { return nil }
    let tokens = perFeatureTokens(lab)
    return (Double(tokens.input) / 1_000_000.0 * pricing.inputPerMillion)
      + (Double(tokens.output) / 1_000_000.0 * pricing.outputPerMillion)
  }

  /// The cost to record for an event: exact when tokens + price are known, the
  /// per-feature estimate when only the price is known, else nil (price unknown).
  static func resolvedCostUSD(
    lab: AILab,
    provider: TextingVoiceProvider,
    modelID: String,
    inputTokens: Int?,
    outputTokens: Int?
  ) -> (Double?, AICostBasis) {
    let exact = costUSD(provider: provider, modelID: modelID, inputTokens: inputTokens, outputTokens: outputTokens)
    switch exact.basis {
    case .exact: return (exact.usd, .exact)
    case .estimated: return (estimatedCostUSD(lab: lab, provider: provider, modelID: modelID), .estimated)
    case .unknownPrice: return (nil, .unknownPrice)
    }
  }

  /// A cheaper model likely good enough for this feature (the lab's eval-chosen
  /// recommendation) plus the approximate % saved on a typical run. nil when the
  /// user's current model already is the recommendation or is no pricier.
  static func cheaperAlternative(
    for lab: AILab,
    provider: TextingVoiceProvider,
    currentModelID: String
  ) -> (modelID: String, savingsPct: Int)? {
    let recommended = lab.recommendedModelID(for: provider)
    guard recommended.lowercased() != currentModelID.lowercased() else { return nil }
    guard let current = pricing(provider: provider, modelID: currentModelID),
          let rec = pricing(provider: provider, modelID: recommended) else { return nil }
    let tokens = perFeatureTokens(lab)
    func blended(_ p: (inputPerMillion: Double, outputPerMillion: Double)) -> Double {
      (Double(tokens.input) / 1_000_000.0 * p.inputPerMillion)
        + (Double(tokens.output) / 1_000_000.0 * p.outputPerMillion)
    }
    let currentCost = blended(current)
    let recommendedCost = blended(rec)
    guard currentCost > 0, recommendedCost < currentCost else { return nil }
    let pct = Int((((currentCost - recommendedCost) / currentCost) * 100).rounded())
    guard pct >= 1 else { return nil }
    return (recommended, pct)
  }
}
