import Foundation
import SQLite3
import Security

struct TextingVoiceProfile: Codable, Equatable {
  struct LengthStats: Codable, Equatable {
    let median: Int
    let p25: Int
    let p75: Int
    let pct_under_20: Double
  }

  struct CapitalizationStats: Codable, Equatable {
    let pct_lowercase_start: Double
    let pct_all_lowercase: Double
  }

  struct PunctuationStats: Codable, Equatable {
    let pct_ending_period: Double
    let pct_ending_exclaim: Double
    let pct_ending_question: Double
    let pct_ending_none: Double
  }

  struct TokenCount: Codable, Equatable {
    let token: String
    let count: Int
  }

  struct EmojiStats: Codable, Equatable {
    let pct_messages_with_emoji: Double
    let top: [TokenCount]
  }

  struct BurstStats: Codable, Equatable {
    let burst_definition_minutes: Int
    let median_messages_per_burst: Int
    let p75_messages_per_burst: Int
  }

  let kind: String
  let profile_id: String
  let display_name: String
  let participant_handles: [String]?
  let scope: String
  let generated_at: String
  let sample_size: Int
  let window_start: String
  let window_end: String
  let source: String
  let privacy: String
  let length: LengthStats
  let capitalization: CapitalizationStats
  let punctuation: PunctuationStats
  let emoji: EmojiStats
  let abbreviations: [TokenCount]
  let openers: [TokenCount]
  let closers: [TokenCount]
  let bursts: BurstStats
  let warnings: [String]
}

struct TextingVoiceProfileSummary: Identifiable, Equatable {
  let id: String
  let displayName: String
  let scope: String
  let sampleSize: Int
  let windowStart: String
  let windowEnd: String
  let medianLength: Int
}

struct TextingVoiceModelOption: Identifiable, Hashable {
  let id: String
  let label: String
  let detail: String
}

enum TextingVoiceProvider: String, CaseIterable, Identifiable {
  case openAI = "openai"
  case anthropic = "anthropic"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .openAI: return "ChatGPT"
    case .anthropic: return "Claude"
    }
  }

  var settingsLabel: String {
    switch self {
    case .openAI: return "ChatGPT API key"
    case .anthropic: return "Claude API key"
    }
  }

  var defaultVoiceModelDisplayName: String {
    switch self {
    case .openAI: return "GPT-5.5"
    case .anthropic: return "Claude Opus 4.8"
    }
  }

  var defaultVoiceModelID: String {
    switch self {
    case .openAI: return "gpt-5.5"
    case .anthropic: return "claude-opus-4-8"
    }
  }

  var voiceModelOptions: [TextingVoiceModelOption] {
    switch self {
    case .openAI:
      return [
        .init(id: "gpt-5.5", label: "GPT-5.5", detail: "Quality default"),
        .init(id: "gpt-5.5-pro", label: "GPT-5.5 pro", detail: "Highest quality, slower"),
        .init(id: "gpt-5.4-mini", label: "GPT-5.4 mini", detail: "Faster, lower cost")
      ]
    case .anthropic:
      return [
        .init(id: "claude-opus-4-8", label: "Claude Opus 4.8", detail: "Quality default"),
        .init(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", detail: "Balanced quality and cost"),
        .init(id: "claude-haiku-4-5", label: "Claude Haiku 4.5", detail: "Faster, lower cost")
      ]
    }
  }

  static func infer(from apiKey: String) -> TextingVoiceProvider? {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("sk-ant-") { return .anthropic }
    if trimmed.hasPrefix("sk-") { return .openAI }
    return nil
  }
}

@MainActor
final class TextingVoiceController: ObservableObject {
  enum Status: Equatable {
    case idle
    case loading
    case enhancing(String)
    case ready(Date)
    case failed(String)

    var label: String {
      switch self {
      case .idle: return "Not generated yet"
      case .loading: return "Refreshing..."
      case .enhancing(let message): return message
      case .ready(let date): return "Updated \(TextingVoicePaths.relative(date))"
      case .failed(let message): return message
      }
    }
  }

  @Published private(set) var profile: TextingVoiceProfile?
  @Published private(set) var specificProfiles: [TextingVoiceProfileSummary] = []
  @Published private(set) var typeProfiles: [TextingVoiceProfileSummary] = []
  @Published private(set) var guides: [String: String] = [:]
  @Published private(set) var status: Status = .idle
  @Published private(set) var generationLog: [String] = []
  @Published var apiKeyInput: String = ""
  @Published var openAIKeyInput: String = ""
  @Published var anthropicKeyInput: String = ""
  @Published var openAIModelInput: String = ""
  @Published var anthropicModelInput: String = ""
  @Published private(set) var openAIModelOptions: [TextingVoiceModelOption] = []
  @Published private(set) var anthropicModelOptions: [TextingVoiceModelOption] = []
  @Published private(set) var loadingModelsProvider: TextingVoiceProvider?
  @Published private(set) var modelListError: String?
  @Published var includeIdentityHints: Bool {
    didSet { UserDefaults.standard.set(includeIdentityHints, forKey: Self.identityHintsDefaultsKey) }
  }
  @Published var selectedProvider: TextingVoiceProvider {
    didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "textingVoice.provider") }
  }
  @Published private(set) var hasOpenAIKey: Bool = TextingVoiceKeychain.hasAPIKey(.openAI)
  @Published private(set) var hasAnthropicKey: Bool = TextingVoiceKeychain.hasAPIKey(.anthropic)

  var canGenerateWithSelectedProvider: Bool {
    hasAPIKey(for: selectedProvider(for: .textingStyle) ?? selectedProvider)
  }

  var hasAnyAPIKey: Bool {
    hasOpenAIKey || hasAnthropicKey
  }

  /// Meters Texting Style's AI calls (issue #145); injected by AppDelegate.
  var usageLedger: AIUsageLedger?

  static var baseDirectory: URL {
    TextingVoicePaths.baseDirectory
  }

  static var fingerprintURL: URL {
    TextingVoicePaths.fingerprintURL
  }

  static var voiceURL: URL {
    TextingVoicePaths.voiceURL
  }

  init(usageLedger: AIUsageLedger? = nil) {
    self.usageLedger = usageLedger
    selectedProvider = TextingVoiceProvider(
      rawValue: UserDefaults.standard.string(forKey: "textingVoice.provider") ?? ""
    ) ?? .openAI
    includeIdentityHints = UserDefaults.standard.bool(forKey: Self.identityHintsDefaultsKey)
    openAIModelInput = UserDefaults.standard.string(forKey: Self.modelDefaultsKey(for: .openAI)) ?? ""
    anthropicModelInput = UserDefaults.standard.string(forKey: Self.modelDefaultsKey(for: .anthropic)) ?? ""
    loadExisting()
  }

  func loadExisting() {
    let loaded = TextingVoiceBuilder.loadProfilesFromDisk()
    profile = loaded.base
    specificProfiles = loaded.specific
    typeProfiles = loaded.types
    guides = loaded.guides
    if loaded.base != nil {
      status = .ready(loaded.modifiedAt ?? Date())
    } else {
      status = .idle
    }
    generationLog = []
  }

  func refresh() {
    status = .loading
    generationLog = ["Scanning sent messages locally...", "Writing aggregate fingerprints..."]
    Task.detached(priority: .userInitiated) {
      do {
        let result = try TextingVoiceBuilder.buildAndWrite()
        await MainActor.run {
          self.profile = result.profile
          self.specificProfiles = result.specific
          self.typeProfiles = result.types
          self.guides = result.guides
          self.status = .ready(result.writtenAt)
          self.generationLog = []
        }
      } catch {
        await MainActor.run {
          self.status = .failed(TextingVoiceBuilder.userFacingError(error))
          self.generationLog.append("Failed: \(TextingVoiceBuilder.userFacingError(error))")
        }
      }
    }
  }

  func saveAPIKey(for provider: TextingVoiceProvider) {
    let trimmed = keyInput(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try TextingVoiceKeychain.saveAPIKey(trimmed, provider: provider)
      setKeyInput("", for: provider)
      refreshKeyState()
      refreshAvailableModels(for: provider)
    } catch {
      status = .failed("Couldn't save API key.")
    }
  }

  func saveInferredAPIKey() {
    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let provider = TextingVoiceProvider.infer(from: trimmed) else {
      status = .failed("That doesn't look like a Claude or ChatGPT API key.")
      return
    }
    do {
      try TextingVoiceKeychain.saveAPIKey(trimmed, provider: provider)
      selectedProvider = provider
      apiKeyInput = ""
      refreshKeyState()
      refreshAvailableModels(for: provider)
      status = .idle
    } catch {
      status = .failed("Couldn't save API key.")
    }
  }

  func clearAPIKey(for provider: TextingVoiceProvider) {
    TextingVoiceKeychain.deleteAPIKey(provider)
    setModelOptions([], for: provider)
    setKeyInput("", for: provider)
    apiKeyInput = ""
    refreshKeyState()
    if selectedProvider == provider {
      switch provider {
      case .openAI where hasAnthropicKey:
        selectedProvider = .anthropic
      case .anthropic where hasOpenAIKey:
        selectedProvider = .openAI
      default:
        break
      }
    }
  }

  func hasAPIKey(for provider: TextingVoiceProvider) -> Bool {
    switch provider {
    case .openAI: return hasOpenAIKey
    case .anthropic: return hasAnthropicKey
    }
  }

  func effectiveModelID(for provider: TextingVoiceProvider) -> String {
    let trimmed = modelInput(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
    let options = availableModelOptions(for: provider)
    if options.contains(where: { $0.id == trimmed }) {
      return trimmed
    }
    return options.first?.id ?? provider.defaultVoiceModelID
  }

  func modelDisplayName(for provider: TextingVoiceProvider) -> String {
    let modelID = effectiveModelID(for: provider)
    return availableModelOptions(for: provider).first(where: { $0.id == modelID })?.label
      ?? provider.defaultVoiceModelDisplayName
  }

  func modelSelection(for provider: TextingVoiceProvider) -> String {
    effectiveModelID(for: provider)
  }

  func setModelSelection(_ modelID: String, for provider: TextingVoiceProvider) {
    let options = availableModelOptions(for: provider)
    let selected = options.contains(where: { $0.id == modelID })
      ? modelID
      : (options.first?.id ?? provider.defaultVoiceModelID)
    UserDefaults.standard.set(selected, forKey: Self.modelDefaultsKey(for: provider))
    setModelInput(selected, for: provider)
  }

  func availableModelOptions(for provider: TextingVoiceProvider) -> [TextingVoiceModelOption] {
    let loaded: [TextingVoiceModelOption] = {
      switch provider {
      case .openAI: return openAIModelOptions
      case .anthropic: return anthropicModelOptions
      }
    }()
    return loaded.isEmpty ? provider.voiceModelOptions : loaded
  }

  var savedProviders: [TextingVoiceProvider] {
    TextingVoiceProvider.allCases.filter { hasAPIKey(for: $0) }
  }

  func selectedProvider(for lab: AILab) -> TextingVoiceProvider? {
    LabModelPreferences.selectedProvider(for: lab, savedProviders: savedProviders)
  }

  func setSelectedProvider(_ provider: TextingVoiceProvider, for lab: AILab) {
    LabModelPreferences.setProvider(provider, for: lab)
    if lab == .textingStyle {
      selectedProvider = provider
    }
    if availableModelOptions(for: provider) == provider.voiceModelOptions {
      refreshAvailableModels(for: provider)
    }
    objectWillChange.send()
  }

  func modelSelection(for lab: AILab, provider: TextingVoiceProvider) -> String {
    LabModelPreferences.modelID(for: lab, provider: provider, options: availableModelOptions(for: provider))
  }

  func setModelSelection(_ modelID: String, for lab: AILab, provider: TextingVoiceProvider) {
    let options = availableModelOptions(for: provider)
    let selected = options.contains(where: { $0.id == modelID })
      ? modelID
      : (options.first?.id ?? lab.recommendedModelID(for: provider))
    LabModelPreferences.setModelID(selected, for: lab, provider: provider)
    if lab == .textingStyle {
      setModelInput(selected, for: provider)
    }
    objectWillChange.send()
  }

  func modelDisplayName(for lab: AILab, provider: TextingVoiceProvider) -> String {
    let modelID = modelSelection(for: lab, provider: provider)
    return availableModelOptions(for: provider).first(where: { $0.id == modelID })?.label
      ?? modelID
  }

  func modelCostLabel(for lab: AILab, provider: TextingVoiceProvider) -> String {
    AIUsageEstimate.label(
      for: lab,
      provider: provider,
      modelID: modelSelection(for: lab, provider: provider)
    )
  }

  func setSelectedProvider(_ provider: TextingVoiceProvider) {
    selectedProvider = provider
    if availableModelOptions(for: provider) == provider.voiceModelOptions {
      refreshAvailableModels(for: provider)
    }
  }

  func refreshAvailableModelsForSavedProviders() {
    for provider in savedProviders {
      refreshAvailableModels(for: provider)
    }
  }

  func refreshAvailableModels(for provider: TextingVoiceProvider) {
    guard let apiKey = TextingVoiceKeychain.loadAPIKey(provider) else { return }
    loadingModelsProvider = provider
    modelListError = nil
    Task.detached(priority: .utility) {
      do {
        let options = try await TextingVoiceModelCatalog.fetch(provider: provider, apiKey: apiKey)
        await MainActor.run {
          self.setModelOptions(options, for: provider)
          LabModelPreferences.storeLiveModels(options.map(\.id), provider: provider)
          if self.loadingModelsProvider == provider { self.loadingModelsProvider = nil }
          let selection = self.modelSelection(for: provider)
          let live = self.availableModelOptions(for: provider)
          if !live.contains(where: { $0.id == selection }) {
            // Prefer the provider's recommended default when the stored
            // selection was retired; fall back to the first live model.
            let recommended = provider.defaultVoiceModelID
            let next = live.contains(where: { $0.id == recommended })
              ? recommended
              : (live.first?.id ?? recommended)
            self.setModelSelection(next, for: provider)
          }
        }
      } catch {
        await MainActor.run {
          if self.loadingModelsProvider == provider { self.loadingModelsProvider = nil }
          self.modelListError = "Couldn't load \(provider.label) models. Showing defaults."
        }
      }
    }
  }

  func generateVoice() {
    guard let selection = LabModelPreferences.clientSelection(for: .textingStyle) else {
      status = .failed("Add a Claude or ChatGPT API key first.")
      return
    }
    guard AIBudgetPrecheck.allow(lab: .textingStyle, ledger: usageLedger) else {
      status = .failed(AIBudgetPrecheck.blockedMessage)
      return
    }
    startGeneration("Preparing local scan...")
    let provider = selection.provider
    let apiKey = selection.apiKey
    let modelID = selection.modelID
    let modelDisplayName = modelDisplayName(for: .textingStyle, provider: provider)
    let includeIdentityHints = includeIdentityHints
    let recorder = usageLedger
    let runID = UUID()
    let startedAt = Date()
    AnalyticsClient.shared.safeCapture(.labScanStarted, properties: [
      .lab: .string(AnalyticsLab.textingStyle.rawValue)
    ])
    Task.detached(priority: .userInitiated) {
      do {
        await self.markGeneration("Scanning sent messages locally...")
        _ = try TextingVoiceBuilder.buildAndWrite()
        await self.markGeneration("Writing aggregate fingerprints...")
        let loaded = TextingVoiceBuilder.loadFullProfilesFromDisk()
        guard !loaded.isEmpty else { throw TextingVoiceLLMError.noProfiles }
        await self.markGeneration("Sending privacy-scrubbed fingerprints to \(modelDisplayName)...")
        let guides = try await TextingVoiceLLMClient(
          provider: provider,
          apiKey: apiKey,
          modelID: modelID,
          includeIdentityHints: includeIdentityHints,
          recorder: recorder,
          runID: runID
        )
          .generateGuides(for: loaded) { batch, total in
            await self.markGeneration("Generating style guides \(batch) of \(total) with \(modelDisplayName)...")
          }
        await self.markGeneration("Saving editable guides locally...")
        try TextingVoiceBuilder.writeGuides(guides)
        let refreshed = TextingVoiceBuilder.loadProfilesFromDisk()
        await MainActor.run {
          self.profile = refreshed.base
          self.specificProfiles = refreshed.specific
          self.typeProfiles = refreshed.types
          self.guides = refreshed.guides
          self.status = .ready(Date())
          self.generationLog.append("Done.")
          AnalyticsClient.shared.safeCapture(.labScanCompleted, properties: [
            .lab: .string(AnalyticsLab.textingStyle.rawValue),
            .resultCountBucket: .string(AnalyticsClient.resultCountBucket(refreshed.specific.count + refreshed.types.count + (refreshed.base == nil ? 0 : 1))),
            .durationBucket: .string(AnalyticsClient.durationBucket(ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
          ])
        }
      } catch {
        await MainActor.run {
          let message = TextingVoiceLLMClient.userFacingError(error)
          self.status = .failed(message)
          self.generationLog.append("Failed: \(message)")
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.textingStyle.rawValue),
            .errorCategory: .string(AnalyticsClient.errorCategory(error).rawValue)
          ])
        }
      }
    }
  }

  func enhanceWithLLM() {
    generateVoice()
  }

  func reviseGuide(
    profileID: String,
    title: String,
    currentMarkdown: String,
    instruction: String
  ) async -> String? {
    let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let selection = LabModelPreferences.clientSelection(for: .textingStyle) else {
      status = .failed("Add a Claude or ChatGPT API key first.")
      return nil
    }
    guard AIBudgetPrecheck.allow(lab: .textingStyle, ledger: usageLedger) else {
      status = .failed(AIBudgetPrecheck.blockedMessage)
      return nil
    }
    let provider = selection.provider
    let apiKey = selection.apiKey
    let modelID = selection.modelID
    status = .enhancing("Revising guide with \(modelDisplayName(for: .textingStyle, provider: provider))...")
    do {
      let revised = try await TextingVoiceLLMClient(
        provider: provider,
        apiKey: apiKey,
        modelID: modelID,
        includeIdentityHints: includeIdentityHints,
        recorder: usageLedger,
        runID: UUID()
      )
        .reviseGuide(profileID: profileID, title: title, currentMarkdown: currentMarkdown, instruction: trimmed)
      status = .ready(Date())
      return revised
    } catch {
      status = .failed(TextingVoiceLLMClient.userFacingError(error))
      return nil
    }
  }

  func guideText(for profileID: String) -> String {
    guides[profileID] ?? ""
  }

  func saveGuide(profileID: String, markdown: String) {
    do {
      try TextingVoiceBuilder.writeGuide(profileID: profileID, markdown: markdown)
      loadExisting()
    } catch {
      status = .failed(TextingVoiceBuilder.userFacingError(error))
    }
  }

  private func refreshKeyState() {
    hasOpenAIKey = TextingVoiceKeychain.hasAPIKey(.openAI)
    hasAnthropicKey = TextingVoiceKeychain.hasAPIKey(.anthropic)
  }

  private func keyInput(for provider: TextingVoiceProvider) -> String {
    switch provider {
    case .openAI: return openAIKeyInput
    case .anthropic: return anthropicKeyInput
    }
  }

  private func setKeyInput(_ value: String, for provider: TextingVoiceProvider) {
    switch provider {
    case .openAI: openAIKeyInput = value
    case .anthropic: anthropicKeyInput = value
    }
  }

  private func modelInput(for provider: TextingVoiceProvider) -> String {
    switch provider {
    case .openAI: return openAIModelInput
    case .anthropic: return anthropicModelInput
    }
  }

  private func setModelInput(_ value: String, for provider: TextingVoiceProvider) {
    switch provider {
    case .openAI: openAIModelInput = value
    case .anthropic: anthropicModelInput = value
    }
  }

  private func setModelOptions(_ options: [TextingVoiceModelOption], for provider: TextingVoiceProvider) {
    switch provider {
    case .openAI: openAIModelOptions = options
    case .anthropic: anthropicModelOptions = options
    }
  }

  private static func modelDefaultsKey(for provider: TextingVoiceProvider) -> String {
    "textingVoice.modelOverride.\(provider.rawValue)"
  }

  private static let identityHintsDefaultsKey = "textingVoice.includeIdentityHints"

  private func startGeneration(_ message: String) {
    status = .enhancing(message)
    generationLog = [message]
  }

  private func markGeneration(_ message: String) {
    status = .enhancing(message)
    generationLog.append(message)
  }
}

enum TextingVoicePaths {
  static var baseDirectory: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("voice")
      .appendingPathComponent("base")
  }

  static var voiceRoot: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("voice")
  }

  static var fingerprintURL: URL {
    baseDirectory.appendingPathComponent("fingerprint.json")
  }

  static var voiceURL: URL {
    baseDirectory.appendingPathComponent("VOICE.md")
  }

  static func directory(for profileID: String) -> URL {
    profileID == "base" ? baseDirectory : voiceRoot.appendingPathComponent(profileID)
  }

  static func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
  }
}

enum TextingVoiceError: Error {
  case chatDbMissing(String)
  case sqliteOpen(String)
  case sqlitePrepare(String)
  case insufficientSample(Int)
  case writeFailed(String)
}

private struct VoiceMessage {
  let date: Date
  let text: String
  let chatID: Int64
  let displayName: String
  let participantHandles: [String]
  let participantCount: Int
}

private struct ContactNameResolver {
  private let handles: [String: String]

  static func load() -> ContactNameResolver {
    let url = AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("contacts-cache.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawHandles = json["handles"] as? [String: String] else {
      return ContactNameResolver(handles: [:])
    }
    return ContactNameResolver(handles: rawHandles)
  }

  func resolveHandle(_ handle: String) -> String? {
    let key = Self.canonicalHandle(handle)
    guard !key.isEmpty,
          let name = handles[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else {
      return nil
    }
    return name
  }

  func resolvedLabels(for participantHandles: [String]) -> [String] {
    var seen = Set<String>()
    var labels: [String] = []
    for handle in participantHandles {
      let label = resolveHandle(handle) ?? handle.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !label.isEmpty else { continue }
      let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      if seen.insert(key).inserted {
        labels.append(label)
      }
    }
    return labels
  }

  func resolveProfileDisplayName(_ displayName: String, participantHandles: [String] = []) -> String {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, !Self.looksLikeHandle(trimmed), !trimmed.hasPrefix("Conversation ") {
      return trimmed
    }

    let labels = resolvedLabels(for: participantHandles)
    let contactLabels = labels.filter { !Self.looksLikeHandle($0) }
    if !contactLabels.isEmpty {
      return compactLabel(contactLabels, maxVisible: 2)
    }

    let rawParts = trimmed
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let resolvedParts = rawParts.compactMap(resolveHandle)
    if !resolvedParts.isEmpty {
      return compactLabel(resolvedParts, maxVisible: 2)
    }

    return trimmed.isEmpty ? "Conversation" : trimmed
  }

  func promptSafeDisplayName(_ profile: TextingVoiceProfile, fallback: String) -> String {
    let label = resolveProfileDisplayName(
      profile.display_name,
      participantHandles: profile.participant_handles ?? []
    )
    guard !label.isEmpty, !Self.looksLikeHandle(label) else { return fallback }
    return label
  }

  func compactLabel(_ labels: [String], maxVisible: Int) -> String {
    let visible = Array(labels.prefix(maxVisible))
    guard !visible.isEmpty else { return "" }
    let overflow = labels.count - visible.count
    if overflow > 0 {
      return "\(visible.joined(separator: ", ")) +\(overflow)"
    }
    return visible.joined(separator: ", ")
  }

  static func canonicalHandle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("@s.whatsapp.net"), let at = trimmed.firstIndex(of: "@") {
      let digits = trimmed[..<at].filter(\.isNumber)
      return String(digits.suffix(10))
    }
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter(\.isNumber)
    if digits.count >= 10 { return String(digits.suffix(10)) }
    return digits
  }

  static func looksLikeHandle(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return true }
    if trimmed.hasPrefix("+") { return true }
    return trimmed.filter(\.isNumber).count >= 5
  }
}

enum TextingVoiceBuilder {
  struct BuildResult {
    let profile: TextingVoiceProfile
    let specific: [TextingVoiceProfileSummary]
    let types: [TextingVoiceProfileSummary]
    let guides: [String: String]
    let writtenAt: Date
  }

  struct LoadedProfiles {
    let base: TextingVoiceProfile?
    let specific: [TextingVoiceProfileSummary]
    let types: [TextingVoiceProfileSummary]
    let guides: [String: String]
    let modifiedAt: Date?
  }

  static func buildAndWrite() throws -> BuildResult {
    let messages = try loadRecentOutboundMessages(limit: 10_000)
    let substantive = messages.filter { isSubstantive($0.text) }
    guard substantive.count >= 30 else {
      throw TextingVoiceError.insufficientSample(substantive.count)
    }

    let profile = buildProfile(
      from: substantive,
      profileID: "base",
      displayName: "Base texting style",
      scope: "all-outbound-imessage"
    )
    let voice = renderVoice(profile)
    try write(profile: profile, voice: voice, directory: TextingVoicePaths.baseDirectory)

    let specificProfiles = try buildSpecificProfiles(from: substantive)
    let typeProfiles = try buildTypeProfiles(from: substantive)
    let loaded = loadProfilesFromDisk()
    return BuildResult(
      profile: profile,
      specific: specificProfiles,
      types: typeProfiles,
      guides: loaded.guides,
      writtenAt: Date()
    )
  }

  static func loadProfilesFromDisk() -> LoadedProfiles {
    let decoder = JSONDecoder()
    let fm = FileManager.default
    var base: TextingVoiceProfile?
    var specific: [TextingVoiceProfileSummary] = []
    var types: [TextingVoiceProfileSummary] = []
    var guides: [String: String] = [:]
    var newest: Date?

    guard let dirs = try? fm.contentsOfDirectory(
      at: TextingVoicePaths.voiceRoot,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return LoadedProfiles(base: nil, specific: [], types: [], guides: [:], modifiedAt: nil)
    }

    for dir in dirs {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
      let fingerprint = dir.appendingPathComponent("fingerprint.json")
      guard let data = try? Data(contentsOf: fingerprint),
            let profile = try? decoder.decode(TextingVoiceProfile.self, from: data) else { continue }

      if let attrs = try? fm.attributesOfItem(atPath: fingerprint.path),
         let modified = attrs[.modificationDate] as? Date,
         newest == nil || modified > newest! {
        newest = modified
      }

      if profile.profile_id == "base" {
        base = profile
      } else if profile.profile_id.hasPrefix("type-") {
        types.append(summary(profile))
      } else {
        specific.append(summary(profile))
      }

      let guideURL = dir.appendingPathComponent("GUIDE.md")
      if let guide = try? String(contentsOf: guideURL, encoding: .utf8) {
        guides[profile.profile_id] = guide
      } else if let voice = try? String(contentsOf: dir.appendingPathComponent("VOICE.md"), encoding: .utf8) {
        guides[profile.profile_id] = voice
      }
    }

    specific.sort {
      if $0.sampleSize == $1.sampleSize { return $0.displayName < $1.displayName }
      return $0.sampleSize > $1.sampleSize
    }
    types.sort {
      if $0.sampleSize == $1.sampleSize { return $0.displayName < $1.displayName }
      return $0.sampleSize > $1.sampleSize
    }
    return LoadedProfiles(base: base, specific: specific, types: types, guides: guides, modifiedAt: newest)
  }

  static func loadFullProfilesFromDisk() -> [TextingVoiceProfile] {
    let decoder = JSONDecoder()
    let fm = FileManager.default
    guard let dirs = try? fm.contentsOfDirectory(
      at: TextingVoicePaths.voiceRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var profiles: [TextingVoiceProfile] = []
    for dir in dirs {
      let fingerprint = dir.appendingPathComponent("fingerprint.json")
      guard let data = try? Data(contentsOf: fingerprint),
            let profile = try? decoder.decode(TextingVoiceProfile.self, from: data) else { continue }
      profiles.append(profile)
    }
    return profiles.sorted {
      if $0.profile_id == "base" { return true }
      if $1.profile_id == "base" { return false }
      if $0.sample_size == $1.sample_size { return $0.display_name < $1.display_name }
      return $0.sample_size > $1.sample_size
    }
  }

  static func userFacingError(_ error: Error) -> String {
    switch error {
    case TextingVoiceError.chatDbMissing:
      return "Messages database not found."
    case TextingVoiceError.sqliteOpen(let message):
      return "Couldn't read Messages. Check Full Disk Access. \(message)"
    case TextingVoiceError.sqlitePrepare(let message):
      return "Couldn't scan Messages. \(message)"
    case TextingVoiceError.insufficientSample(let count):
      return "Needs at least 30 sent messages; found \(count)."
    case TextingVoiceError.writeFailed(let message):
      return "Couldn't save voice files. \(message)"
    default:
      return error.localizedDescription
    }
  }

  private static func loadRecentOutboundMessages(limit: Int32) throws -> [VoiceMessage] {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      throw TextingVoiceError.chatDbMissing(dbURL.path)
    }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
      if let db { sqlite3_close(db) }
      throw TextingVoiceError.sqliteOpen(message)
    }
    defer { sqlite3_close(db) }
    let contactResolver = ContactNameResolver.load()

    let sql = """
      SELECT m.date,
             m.text,
             m.attributedBody,
             cmj.chat_id,
             c.display_name,
             GROUP_CONCAT(h.id, ', '),
             COUNT(DISTINCT h.id)
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      LEFT JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
      LEFT JOIN handle h ON h.ROWID = chj.handle_id
      WHERE m.is_from_me = 1
        AND (
          (m.text IS NOT NULL AND length(trim(m.text)) > 0)
          OR m.attributedBody IS NOT NULL
        )
      GROUP BY m.ROWID, cmj.chat_id
      ORDER BY m.date DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      let message = String(cString: sqlite3_errmsg(db))
      throw TextingVoiceError.sqlitePrepare(message)
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_int(stmt, 1, limit)

    var rows: [VoiceMessage] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let rawDate = sqlite3_column_int64(stmt, 0)
      let textCol = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
      let attributed: Data? = {
        guard let blob = sqlite3_column_blob(stmt, 2) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 2))
        guard count > 0 else { return nil }
        return Data(bytes: blob, count: count)
      }()
      let text = bestMessageBody(textCol: textCol, attributedBody: attributed)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let chatID = sqlite3_column_int64(stmt, 3)
      let chatName = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
      let participantHandles = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
      let handles = splitHandles(participantHandles)
      let participantCount = max(1, Int(sqlite3_column_int(stmt, 6)))
      let displayName = bestDisplayName(
        chatName: chatName,
        participantHandles: handles,
        chatID: chatID,
        resolver: contactResolver
      )
      rows.append(
        VoiceMessage(
          date: imessageDate(rawDate),
          text: text,
          chatID: chatID,
          displayName: displayName,
          participantHandles: handles,
          participantCount: participantCount
        )
      )
    }
    return rows
  }

  private static func buildSpecificProfiles(from messages: [VoiceMessage]) throws -> [TextingVoiceProfileSummary] {
    let grouped = Dictionary(grouping: messages, by: \.chatID)
    let eligible = grouped
      .filter { $0.value.count >= 30 }
      .sorted { lhs, rhs in
        if lhs.value.count == rhs.value.count {
          return (lhs.value.map(\.date).max() ?? .distantPast) > (rhs.value.map(\.date).max() ?? .distantPast)
        }
        return lhs.value.count > rhs.value.count
      }
      .prefix(12)

    var summaries: [TextingVoiceProfileSummary] = []
    for (chatID, chatMessages) in eligible {
      let displayName = chatMessages.first?.displayName ?? "Conversation \(chatID)"
      let profile = buildProfile(
        from: chatMessages,
        profileID: "chat-\(chatID)",
        displayName: displayName,
        scope: "conversation-outbound-imessage"
      )
      let directory = TextingVoicePaths.voiceRoot.appendingPathComponent(profile.profile_id)
      try write(profile: profile, voice: renderVoice(profile), directory: directory)
      summaries.append(summary(profile))
    }
    return summaries.sorted {
      if $0.sampleSize == $1.sampleSize { return $0.displayName < $1.displayName }
      return $0.sampleSize > $1.sampleSize
    }
  }

  private static func buildTypeProfiles(from messages: [VoiceMessage]) throws -> [TextingVoiceProfileSummary] {
    let grouped = Dictionary(grouping: messages, by: \.chatID)
    let eligibleChats = grouped.filter { $0.value.count >= 30 }
    let chatStats = eligibleChats.mapValues { chatMessages -> (medianLength: Int, participantCount: Int, newest: Date) in
      let lengths = chatMessages.map { $0.text.count }.sorted()
      return (
        medianLength: Int(round(percentile(lengths, 0.50))),
        participantCount: chatMessages.map(\.participantCount).max() ?? 1,
        newest: chatMessages.map(\.date).max() ?? .distantPast
      )
    }

    var buckets: [(id: String, name: String, messages: [VoiceMessage])] = []

    let closeChatIDs = eligibleChats
      .filter { chatStats[$0.key]?.participantCount == 1 }
      .sorted {
        if $0.value.count == $1.value.count {
          return (chatStats[$0.key]?.newest ?? .distantPast) > (chatStats[$1.key]?.newest ?? .distantPast)
        }
        return $0.value.count > $1.value.count
      }
      .prefix(8)
      .map(\.key)
    let close = messages.filter { closeChatIDs.contains($0.chatID) }
    if close.count >= 30 {
      buckets.append(("type-close-contacts", "Close-contact voice", close))
    }

    let groups = messages.filter { $0.participantCount > 1 }
    if groups.count >= 30 {
      buckets.append(("type-group-chats", "Group-chat voice", groups))
    }

    let quickIDs = chatStats.filter { $0.value.medianLength <= 35 }.map(\.key)
    let quick = messages.filter { quickIDs.contains($0.chatID) }
    if quick.count >= 30 {
      buckets.append(("type-quick-checkins", "Quick-check-in voice", quick))
    }

    let longerIDs = chatStats.filter { $0.value.medianLength >= 80 }.map(\.key)
    let longer = messages.filter { longerIDs.contains($0.chatID) }
    if longer.count >= 30 {
      buckets.append(("type-longer-updates", "Longer-update voice", longer))
    }

    var summaries: [TextingVoiceProfileSummary] = []
    for bucket in buckets {
      let profile = buildProfile(
        from: bucket.messages,
        profileID: bucket.id,
        displayName: bucket.name,
        scope: "person-type-outbound-imessage"
      )
      let directory = TextingVoicePaths.voiceRoot.appendingPathComponent(profile.profile_id)
      try write(profile: profile, voice: renderVoice(profile), directory: directory)
      summaries.append(summary(profile))
    }
    return summaries
  }

  private static func buildProfile(
    from messages: [VoiceMessage],
    profileID: String,
    displayName: String,
    scope: String
  ) -> TextingVoiceProfile {
    let sorted = messages.sorted { $0.date < $1.date }
    let lengths = messages.map { $0.text.count }.sorted()
    let pctUnder20 = percent(messages.filter { $0.text.count < 20 }.count, messages.count)

    let lowerStart = messages.filter { startsLowercase($0.text) }.count
    let allLower = messages.filter { isAllLowercaseWhereRelevant($0.text) }.count
    let punctuation = punctuationCounts(messages.map(\.text))
    let emoji = emojiStats(messages.map(\.text))
    let abbreviations = topCounts(countAbbreviations(messages.map(\.text)), limit: 12)
    let openers = topCounts(countSafeEdgeWords(messages.map(\.text), edge: .first), limit: 8)
    let closers = topCounts(countSafeEdgeWords(messages.map(\.text), edge: .last), limit: 8)
    let bursts = burstSizes(sorted)
    let warnings: [String] = messages.count < 100
      ? ["Small sample; treat as a starting point and tune manually."]
      : []

    return TextingVoiceProfile(
      kind: profileID == "base"
        ? "base-texting-voice"
        : (profileID.hasPrefix("type-") ? "person-type-texting-voice" : "conversation-texting-voice"),
      profile_id: profileID,
      display_name: displayName,
      participant_handles: uniqueParticipantHandles(messages),
      scope: scope,
      generated_at: iso(Date()),
      sample_size: messages.count,
      window_start: iso(sorted.first?.date ?? Date()),
      window_end: iso(sorted.last?.date ?? Date()),
      source: "local-imessage-outbound",
      privacy: "aggregate-only; no raw message bodies stored",
      length: .init(
        median: Int(round(percentile(lengths, 0.50))),
        p25: Int(round(percentile(lengths, 0.25))),
        p75: Int(round(percentile(lengths, 0.75))),
        pct_under_20: round2(pctUnder20)
      ),
      capitalization: .init(
        pct_lowercase_start: round2(percent(lowerStart, messages.count)),
        pct_all_lowercase: round2(percent(allLower, messages.count))
      ),
      punctuation: .init(
        pct_ending_period: round2(percent(punctuation.period, messages.count)),
        pct_ending_exclaim: round2(percent(punctuation.exclaim, messages.count)),
        pct_ending_question: round2(percent(punctuation.question, messages.count)),
        pct_ending_none: round2(percent(punctuation.none, messages.count))
      ),
      emoji: emoji,
      abbreviations: abbreviations,
      openers: openers,
      closers: closers,
      bursts: .init(
        burst_definition_minutes: 2,
        median_messages_per_burst: Int(round(percentile(bursts, 0.50))),
        p75_messages_per_burst: Int(round(percentile(bursts, 0.75)))
      ),
      warnings: warnings
    )
  }

  private static func renderVoice(_ profile: TextingVoiceProfile) -> String {
    var lines: [String] = []
    lines.append("# \(profile.display_name)")
    lines.append("")
    lines.append("- Generated: \(profile.generated_at)")
    lines.append("- Sample: \(profile.sample_size) sent iMessages, \(profile.window_start) to \(profile.window_end)")
    lines.append("- Privacy: aggregate-only; no raw message bodies are stored here.")
    if !profile.warnings.isEmpty {
      lines.append("- Caveat: \(profile.warnings.joined(separator: " "))")
    }
    lines.append("")
    lines.append("## Voice fingerprint")
    lines.append("")
    lines.append("- Typical message length: median \(profile.length.median) chars (middle range \(profile.length.p25)-\(profile.length.p75)).")
    lines.append("- Short messages under 20 chars: \(percentLabel(profile.length.pct_under_20)).")
    lines.append("- Lowercase starts: \(percentLabel(profile.capitalization.pct_lowercase_start)); all-lowercase messages: \(percentLabel(profile.capitalization.pct_all_lowercase)).")
    lines.append("- Endings: no punctuation \(percentLabel(profile.punctuation.pct_ending_none)), periods \(percentLabel(profile.punctuation.pct_ending_period)), questions \(percentLabel(profile.punctuation.pct_ending_question)), exclamation \(percentLabel(profile.punctuation.pct_ending_exclaim)).")
    lines.append("- Emoji appears in \(percentLabel(profile.emoji.pct_messages_with_emoji)) of messages\(tokenList(profile.emoji.top, prefix: "; common emoji: ")).")
    lines.append("- Common shorthand\(tokenList(profile.abbreviations, prefix: ": ")).")
    lines.append("- Common safe openers\(tokenList(profile.openers, prefix: ": ")).")
    lines.append("- Common safe closers\(tokenList(profile.closers, prefix: ": ")).")
    lines.append("- Burst pattern: median \(profile.bursts.median_messages_per_burst) message(s), p75 \(profile.bursts.p75_messages_per_burst), grouped within \(profile.bursts.burst_definition_minutes) minutes.")
    lines.append("")
    lines.append("## Drafting defaults")
    lines.append("")
    lines.append("- Use this profile as style guidance; fresh thread context should override it.")
    lines.append("- Aim near \(profile.length.median) characters unless the conversation calls for more.")
    if profile.capitalization.pct_lowercase_start >= 0.50 {
      lines.append("- Lowercase openings are normal for this user; do not over-polish capitalization.")
    }
    if profile.punctuation.pct_ending_none >= 0.50 {
      lines.append("- Prefer no terminal punctuation for casual drafts.")
    } else if profile.punctuation.pct_ending_period >= 0.50 {
      lines.append("- Period endings are normal for this user.")
    }
    if profile.emoji.pct_messages_with_emoji < 0.10 {
      lines.append("- Use emoji rarely unless the thread already uses it.")
    } else if profile.emoji.pct_messages_with_emoji >= 0.30 {
      lines.append("- Emoji is part of the voice; use lightly and match the thread.")
    }
    lines.append("- Never send automatically. Stage a draft for user approval.")
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private static func write(profile: TextingVoiceProfile, voice: String, directory: URL) throws {
    do {
      let fm = FileManager.default
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(profile)
      let fingerprintURL = directory.appendingPathComponent("fingerprint.json")
      let voiceURL = directory.appendingPathComponent("VOICE.md")
      try data.write(to: fingerprintURL, options: .atomic)
      try voice.data(using: .utf8)?.write(to: voiceURL, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fingerprintURL.path)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: voiceURL.path)
    } catch {
      throw TextingVoiceError.writeFailed(error.localizedDescription)
    }
  }

  static func writeGuides(_ guides: [String: String]) throws {
    for (profileID, markdown) in guides {
      try writeGuide(profileID: profileID, markdown: markdown)
    }
  }

  static func writeGuide(profileID: String, markdown: String) throws {
    do {
      let directory = TextingVoicePaths.directory(for: profileID)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("GUIDE.md")
      try markdown.data(using: .utf8)?.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      throw TextingVoiceError.writeFailed(error.localizedDescription)
    }
  }

  private static func summary(_ profile: TextingVoiceProfile) -> TextingVoiceProfileSummary {
    let resolver = ContactNameResolver.load()
    return TextingVoiceProfileSummary(
      id: profile.profile_id,
      displayName: resolver.resolveProfileDisplayName(
        profile.display_name,
        participantHandles: profile.participant_handles ?? []
      ),
      scope: profile.scope,
      sampleSize: profile.sample_size,
      windowStart: profile.window_start,
      windowEnd: profile.window_end,
      medianLength: profile.length.median
    )
  }

  private static func bestMessageBody(textCol: String?, attributedBody: Data?) -> String {
    if let textCol, !textCol.isEmpty { return textCol }
    return decodeAttributedBody(attributedBody) ?? ""
  }

  private static func decodeAttributedBody(_ data: Data?) -> String? {
    guard let data, !data.isEmpty else { return nil }
    let bytes = [UInt8](data)
    let marker = Array("NSString".utf8)
    guard let markerIdx = bytes.firstRange(of: marker)?.lowerBound else { return nil }

    var cursor = markerIdx + marker.count
    while cursor < bytes.count - 1 {
      if bytes[cursor] == 0x01 && bytes[cursor + 1] == 0x2b {
        cursor += 2
        break
      }
      cursor += 1
    }
    guard cursor < bytes.count else { return nil }

    let first = bytes[cursor]
    cursor += 1
    let length: Int
    if first < 0x80 {
      length = Int(first)
    } else if first == 0x81 {
      guard cursor + 2 <= bytes.count else { return nil }
      length = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
      cursor += 2
    } else if first == 0x82 {
      guard cursor + 4 <= bytes.count else { return nil }
      length = Int(bytes[cursor])
        | (Int(bytes[cursor + 1]) << 8)
        | (Int(bytes[cursor + 2]) << 16)
        | (Int(bytes[cursor + 3]) << 24)
      cursor += 4
    } else {
      return nil
    }

    guard length > 0, cursor + length <= bytes.count else { return nil }
    let bodyData = Data(bytes[cursor..<(cursor + length)])
    return String(data: bodyData, encoding: .utf8)?
      .trimmingCharacters(in: controlBoundaryCharacters)
  }

  private static var controlBoundaryCharacters: CharacterSet {
    var set = CharacterSet()
    set.insert(charactersIn: UnicodeScalar(0x00)!...UnicodeScalar(0x08)!)
    set.insert(UnicodeScalar(0x0B)!)
    set.insert(UnicodeScalar(0x0C)!)
    set.insert(charactersIn: UnicodeScalar(0x0E)!...UnicodeScalar(0x1F)!)
    return set
  }

  private static func splitHandles(_ participantHandles: String?) -> [String] {
    guard let participantHandles = participantHandles?.trimmingCharacters(in: .whitespacesAndNewlines),
          !participantHandles.isEmpty else {
      return []
    }
    return participantHandles
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func bestDisplayName(
    chatName: String?,
    participantHandles: [String],
    chatID: Int64,
    resolver: ContactNameResolver
  ) -> String {
    if let chatName = chatName?.trimmingCharacters(in: .whitespacesAndNewlines), !chatName.isEmpty {
      return chatName
    }
    let resolved = resolver.resolvedLabels(for: participantHandles)
    if !resolved.isEmpty {
      return resolver.compactLabel(resolved, maxVisible: 2)
    }
    if !participantHandles.isEmpty {
      return participantHandles.prefix(2).joined(separator: ", ")
    }
    return "Conversation \(chatID)"
  }

  private static func uniqueParticipantHandles(_ messages: [VoiceMessage]) -> [String] {
    var seen = Set<String>()
    var handles: [String] = []
    for handle in messages.flatMap(\.participantHandles) {
      let key = ContactNameResolver.canonicalHandle(handle)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      handles.append(handle)
    }
    return handles
  }

  private static func imessageDate(_ raw: Int64) -> Date {
    let seconds: Double
    if abs(raw) > 10_000_000_000_000 {
      seconds = Double(raw) / 1_000_000_000.0 + 978_307_200.0
    } else if abs(raw) > 100_000_000 {
      seconds = Double(raw) + 978_307_200.0
    } else {
      seconds = Double(raw)
    }
    return Date(timeIntervalSince1970: seconds)
  }

  private static func isSubstantive(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return false }
    let reactionPrefixes = [
      "Loved \"", "Liked \"", "Disliked \"", "Laughed at \"", "Emphasized \"", "Questioned \"", "Removed \"",
      "Loved “", "Liked “", "Disliked “", "Laughed at “", "Emphasized “", "Questioned “", "Removed “",
    ]
    return !reactionPrefixes.contains { trimmed.hasPrefix($0) }
  }

  private static func startsLowercase(_ text: String) -> Bool {
    guard let scalar = text.unicodeScalars.first(where: CharacterSet.letters.contains) else { return false }
    return CharacterSet.lowercaseLetters.contains(scalar)
  }

  private static func isAllLowercaseWhereRelevant(_ text: String) -> Bool {
    var sawLetter = false
    for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
      sawLetter = true
      if CharacterSet.uppercaseLetters.contains(scalar) { return false }
    }
    return sawLetter
  }

  private static func punctuationCounts(_ texts: [String]) -> (period: Int, exclaim: Int, question: Int, none: Int) {
    var period = 0
    var exclaim = 0
    var question = 0
    var none = 0
    for text in texts {
      var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      while let last = trimmed.last, characterContainsEmoji(last) {
        trimmed.removeLast()
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      switch trimmed.last {
      case ".": period += 1
      case "!": exclaim += 1
      case "?": question += 1
      default: none += 1
      }
    }
    return (period, exclaim, question, none)
  }

  private static func emojiStats(_ texts: [String]) -> TextingVoiceProfile.EmojiStats {
    var withEmoji = 0
    var counts: [String: Int] = [:]
    for text in texts {
      var found = false
      for character in text where characterContainsEmoji(character) {
        found = true
        counts[String(character), default: 0] += 1
      }
      if found { withEmoji += 1 }
    }
    return .init(
      pct_messages_with_emoji: round2(percent(withEmoji, texts.count)),
      top: topCounts(counts, limit: 8)
    )
  }

  private static func characterContainsEmoji(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      let v = scalar.value
      return (v >= 0x1F300 && v <= 0x1FAFF) || (v >= 0x2600 && v <= 0x27BF)
    }
  }

  private static func countAbbreviations(_ texts: [String]) -> [String: Int] {
    let allowed: Set<String> = [
      "lol", "lmao", "haha", "hahaha", "omg", "tbh", "imo", "idk", "rn", "tmrw",
      "wyd", "wya", "brb", "btw", "fwiw", "thx", "ty", "np", "ok", "kk", "ya",
      "nah", "yep", "yup", "gm", "gn",
    ]
    var counts: [String: Int] = [:]
    for token in wordTokens(texts.joined(separator: " ")) where allowed.contains(token) {
      counts[token, default: 0] += 1
    }
    return counts
  }

  private enum Edge { case first, last }

  private static func countSafeEdgeWords(_ texts: [String], edge: Edge) -> [String: Int] {
    let safe: Set<String> = [
      "hey", "hi", "hello", "yo", "ok", "okay", "lol", "haha", "thanks", "thank",
      "yes", "yeah", "yep", "no", "nah", "sure", "totally", "perfect", "cool",
      "great", "awesome", "sorry", "soon", "later", "tonight", "tomorrow",
    ]
    var counts: [String: Int] = [:]
    for text in texts {
      let tokens = wordTokens(text)
      guard let token = edge == .first ? tokens.first : tokens.last, safe.contains(token) else { continue }
      counts[token, default: 0] += 1
    }
    return counts
  }

  private static func wordTokens(_ text: String) -> [String] {
    let lowered = text.lowercased()
    var current = ""
    var tokens: [String] = []
    for scalar in lowered.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  private static func burstSizes(_ messages: [VoiceMessage]) -> [Int] {
    guard !messages.isEmpty else { return [1] }
    var sizes: [Int] = []
    var previous = messages[0]
    var currentSize = 1
    for message in messages.dropFirst() {
      let sameChat = message.chatID == previous.chatID
      let gap = message.date.timeIntervalSince(previous.date)
      if sameChat && gap >= 0 && gap <= 120 {
        currentSize += 1
      } else {
        sizes.append(currentSize)
        currentSize = 1
      }
      previous = message
    }
    sizes.append(currentSize)
    return sizes.sorted()
  }

  private static func percentile(_ sortedValues: [Int], _ p: Double) -> Double {
    guard !sortedValues.isEmpty else { return 0 }
    if sortedValues.count == 1 { return Double(sortedValues[0]) }
    let position = p * Double(sortedValues.count - 1)
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    if lower == upper { return Double(sortedValues[lower]) }
    let weight = position - Double(lower)
    return Double(sortedValues[lower]) * (1 - weight) + Double(sortedValues[upper]) * weight
  }

  private static func percent(_ numerator: Int, _ denominator: Int) -> Double {
    guard denominator > 0 else { return 0 }
    return Double(numerator) / Double(denominator)
  }

  private static func round2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
  }

  private static func percentLabel(_ value: Double) -> String {
    "\(Int(round(value * 100)))%"
  }

  private static func topCounts(_ counts: [String: Int], limit: Int) -> [TextingVoiceProfile.TokenCount] {
    counts
      .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
      .prefix(limit)
      .map { .init(token: $0.key, count: $0.value) }
  }

  private static func tokenList(_ tokens: [TextingVoiceProfile.TokenCount], prefix: String) -> String {
    guard !tokens.isEmpty else { return "." }
    return prefix + tokens.map { "\($0.token) (\($0.count))" }.joined(separator: ", ") + "."
  }

  private static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}

enum TextingVoiceKeychain {
  private static let service = "com.sunriselabs.messages-for-ai.texting-voice"
  private static let account = "texting-voice-api-key"

  static func hasAPIKey(_ provider: TextingVoiceProvider) -> Bool {
    loadAPIKey(provider) != nil
  }

  static func loadAPIKey(_ provider: TextingVoiceProvider) -> String? {
    var query = baseQuery(provider)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func saveAPIKey(_ key: String, provider: TextingVoiceProvider) throws {
    deleteAPIKey(provider)
    var query = baseQuery(provider)
    query[kSecValueData as String] = Data(key.utf8)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw TextingVoiceError.writeFailed("Keychain status \(status)") }
  }

  static func deleteAPIKey(_ provider: TextingVoiceProvider) {
    SecItemDelete(baseQuery(provider) as CFDictionary)
  }

  private static func baseQuery(_ provider: TextingVoiceProvider) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "\(account)-\(provider.rawValue)"
    ]
  }
}

private enum TextingVoiceLLMError: Error {
  case invalidResponse
  case apiError(String)
  case noGuides
  case noProfiles
}

private enum TextingVoiceModelCatalog {
  static func fetch(provider: TextingVoiceProvider, apiKey: String) async throws -> [TextingVoiceModelOption] {
    switch provider {
    case .openAI:
      return try await fetchOpenAI(apiKey: apiKey)
    case .anthropic:
      return try await fetchAnthropic(apiKey: apiKey)
    }
  }

  private static func fetchOpenAI(apiKey: String) async throws -> [TextingVoiceModelOption] {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw TextingVoiceLLMError.invalidResponse
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["data"] as? [[String: Any]] else {
      throw TextingVoiceLLMError.invalidResponse
    }
    let options = rows.compactMap { row -> TextingVoiceModelOption? in
      guard let id = row["id"] as? String, isOpenAITextModel(id) else { return nil }
      return .init(id: id, label: displayName(forModelID: id), detail: id)
    }
    return sortModelOptions(options)
  }

  private static func fetchAnthropic(apiKey: String) async throws -> [TextingVoiceModelOption] {
    var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
    components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw TextingVoiceLLMError.invalidResponse
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["data"] as? [[String: Any]] else {
      throw TextingVoiceLLMError.invalidResponse
    }
    let options = rows.compactMap { row -> TextingVoiceModelOption? in
      guard let id = row["id"] as? String else { return nil }
      let label = (row["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return .init(id: id, label: label?.isEmpty == false ? label! : displayName(forModelID: id), detail: id)
    }
    return sortModelOptions(options)
  }

  private static func isOpenAITextModel(_ id: String) -> Bool {
    let lowered = id.lowercased()
    if lowered.contains("image")
      || lowered.contains("audio")
      || lowered.contains("realtime")
      || lowered.contains("transcribe")
      || lowered.contains("tts")
      || lowered.contains("embedding")
      || lowered.contains("moderation")
      || lowered.contains("whisper")
      || lowered.contains("sora") {
      return false
    }
    return lowered.hasPrefix("gpt-")
      || lowered.hasPrefix("chatgpt-")
      || lowered.range(of: #"^o\d"#, options: .regularExpression) != nil
  }

  private static func sortModelOptions(_ options: [TextingVoiceModelOption]) -> [TextingVoiceModelOption] {
    var seen = Set<String>()
    return options
      .filter { seen.insert($0.id).inserted }
      .sorted { lhs, rhs in
        let l = qualityRank(lhs.id)
        let r = qualityRank(rhs.id)
        if l != r { return l < r }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
      }
  }

  private static func qualityRank(_ id: String) -> Int {
    let lowered = id.lowercased()
    if lowered.contains("opus") || lowered.contains("pro") { return 0 }
    if lowered.contains("5.") { return 1 }
    if lowered.contains("sonnet") || lowered.contains("gpt-5") { return 2 }
    if lowered.contains("gpt-4") || lowered.hasPrefix("o") { return 3 }
    if lowered.contains("haiku") || lowered.contains("mini") || lowered.contains("nano") { return 4 }
    return 5
  }

  private static func displayName(forModelID id: String) -> String {
    id
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { part in
        let raw = String(part)
        if raw.lowercased() == "gpt" { return "GPT" }
        return raw.prefix(1).uppercased() + raw.dropFirst()
      }
      .joined(separator: " ")
  }
}

private struct TextingVoiceLLMClient {
  let provider: TextingVoiceProvider
  let apiKey: String
  let modelID: String
  let includeIdentityHints: Bool
  /// Usage metering (issue #145); all chunk calls in one generation share runID.
  var recorder: (any AIUsageRecording)? = nil
  var runID: UUID? = nil
  private let generationChunkSize = 4
  private static let requestTimeout: TimeInterval = 300
  private static let resourceTimeout: TimeInterval = 900
  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = requestTimeout
    config.timeoutIntervalForResource = resourceTimeout
    return URLSession(configuration: config)
  }()

  func generateGuides(
    for profiles: [TextingVoiceProfile],
    progress: ((Int, Int) async -> Void)? = nil
  ) async throws -> [String: String] {
    let chunks = generationChunks(for: profiles)
    var merged: [String: String] = [:]
    for (idx, chunk) in chunks.enumerated() {
      if let progress {
        await progress(idx + 1, chunks.count)
      }
      let guides = try await generateGuidesForChunk(chunk.payload, targetProfileIDs: chunk.targetProfileIDs)
      merged.merge(guides) { _, new in new }
    }
    guard !merged.isEmpty else { throw TextingVoiceLLMError.noGuides }
    return merged
  }

  private func generateGuidesForChunk(
    _ profiles: [TextingVoiceProfile],
    targetProfileIDs: [String]
  ) async throws -> [String: String] {
    switch provider {
    case .openAI:
      return try await generateOpenAIGuides(for: profiles, targetProfileIDs: targetProfileIDs)
    case .anthropic:
      return try await generateAnthropicGuides(for: profiles, targetProfileIDs: targetProfileIDs)
    }
  }

  private func generationChunks(for profiles: [TextingVoiceProfile]) -> [(payload: [TextingVoiceProfile], targetProfileIDs: [String])] {
    let capped = Array(profiles.prefix(18))
    guard !capped.isEmpty else { return [] }

    let base = capped.first { $0.profile_id == "base" }
    let nonBaseProfiles = capped.filter { $0.profile_id != "base" }
    var chunks: [(payload: [TextingVoiceProfile], targetProfileIDs: [String])] = []

    if let base {
      chunks.append((payload: [base], targetProfileIDs: [base.profile_id]))
    }

    var idx = 0
    while idx < nonBaseProfiles.count {
      let end = min(idx + generationChunkSize, nonBaseProfiles.count)
      let batch = Array(nonBaseProfiles[idx..<end])
      let payload = base.map { [$0] + batch } ?? batch
      chunks.append((payload: payload, targetProfileIDs: batch.map(\.profile_id)))
      idx = end
    }

    if chunks.isEmpty {
      return [(payload: capped, targetProfileIDs: capped.map(\.profile_id))]
    }
    return chunks
  }

  func reviseGuide(
    profileID: String,
    title: String,
    currentMarkdown: String,
    instruction: String
  ) async throws -> String {
    let safeTitle = Self.safeProfileTitle(profileID: profileID)
    let sanitizedMarkdown = Self.sanitizeGuideForLLM(currentMarkdown, profileID: profileID)
    let prompt = """
    Revise this local texting style guide using the user's instruction.

    Privacy constraints:
    - You are not receiving message bodies.
    - You are not receiving contact names, phone numbers, emails, or raw recipient labels.
    - Do not ask for message bodies.
    - Do not invent specific events, memories, opinions, or relationships.
    - Preserve the guide's practical drafting value.
    - Keep the final privacy note.

    Return strict JSON only:
    {
      "profile_id": "\(profileID)",
      "markdown": "# ...\\n..."
    }

    Profile: \(safeTitle)

    User instruction:
    \(instruction)

    Current guide:
    \(sanitizedMarkdown)
    """

    let text: String
    switch provider {
    case .openAI:
      text = try await openAIText(prompt: prompt, maxTokens: nil)
    case .anthropic:
      text = try await anthropicText(prompt: prompt, maxTokens: 2500)
    }
    guard let parsed = Self.parseSingleGuide(text, expectedProfileID: profileID) else {
      throw TextingVoiceLLMError.noGuides
    }
    return parsed
  }

  private func generateOpenAIGuides(
    for profiles: [TextingVoiceProfile],
    targetProfileIDs: [String]
  ) async throws -> [String: String] {
    let text = try await openAIText(prompt: prompt(for: profiles, targetProfileIDs: targetProfileIDs), maxTokens: 3500)
    guard let parsed = Self.parseGuides(text), !parsed.isEmpty else {
      throw TextingVoiceLLMError.noGuides
    }
    return parsed
  }

  private func generateAnthropicGuides(
    for profiles: [TextingVoiceProfile],
    targetProfileIDs: [String]
  ) async throws -> [String: String] {
    let text = try await anthropicText(prompt: prompt(for: profiles, targetProfileIDs: targetProfileIDs), maxTokens: 5000)
    guard let parsed = Self.parseGuides(text), !parsed.isEmpty else {
      throw TextingVoiceLLMError.noGuides
    }
    return parsed
  }

  private func openAIText(prompt: String, maxTokens: Int?) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Self.requestTimeout
    var body = openAIRequestBody(prompt: prompt)
    if let maxTokens { body["max_output_tokens"] = maxTokens }
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await Self.session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw TextingVoiceLLMError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let message = Self.errorMessage(from: data, providerName: "OpenAI", statusCode: http.statusCode)
      throw TextingVoiceLLMError.apiError(message)
    }

    if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      AIUsageReporter.report(recorder, lab: .textingStyle, provider: provider, modelID: modelID, responseRoot: root, runID: runID)
    }
    return try Self.extractOutputText(from: data)
  }

  private func anthropicText(prompt: String, maxTokens: Int) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = Self.requestTimeout
    request.httpBody = try JSONSerialization.data(
      withJSONObject: anthropicRequestBody(prompt: prompt, maxTokens: maxTokens),
      options: []
    )

    let (data, response) = try await Self.session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw TextingVoiceLLMError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let message = Self.anthropicErrorMessage(from: data, statusCode: http.statusCode)
      throw TextingVoiceLLMError.apiError(message)
    }

    if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      AIUsageReporter.report(recorder, lab: .textingStyle, provider: provider, modelID: modelID, responseRoot: root, runID: runID)
    }
    return try Self.extractAnthropicText(from: data)
  }

  static func userFacingError(_ error: Error) -> String {
    if let urlError = error as? URLError, urlError.code == .timedOut {
      return "The model request timed out. Try again; Texting Style now generates in smaller batches."
    }
    switch error {
    case TextingVoiceLLMError.apiError(let message):
      return message
    case TextingVoiceLLMError.noGuides:
      return "The model response did not include a usable style guide."
    case TextingVoiceLLMError.noProfiles:
      return "Build the local style first."
    case TextingVoiceLLMError.invalidResponse:
      return "The model returned an unreadable response."
    default:
      return error.localizedDescription
    }
  }

  private func openAIRequestBody(prompt: String) -> [String: Any] {
    [
      "model": modelID,
      "input": [
        [
          "role": "developer",
          "content": "You write practical style guides for drafting text messages. Return JSON only."
        ],
        [
          "role": "user",
          "content": prompt
        ]
      ]
    ]
  }

  private func anthropicRequestBody(prompt: String, maxTokens: Int) -> [String: Any] {
    [
      "model": modelID,
      "max_tokens": maxTokens,
      "system": "You write practical style guides for drafting text messages. Return JSON only.",
      "messages": [
        [
          "role": "user",
          "content": prompt
        ]
      ]
    ]
  }

  private static func safeProfileTitle(profileID: String) -> String {
    if profileID == "base" { return "Base texting style" }
    if profileID.hasPrefix("type-") { return "People-type style" }
    return "Frequent conversation style"
  }

  private static func sanitizeGuideForLLM(_ markdown: String, profileID: String) -> String {
    var text = markdown
    text = text.replacingOccurrences(
      of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
      with: "[redacted email]",
      options: [.regularExpression, .caseInsensitive]
    )
    text = text.replacingOccurrences(
      of: #"\+?\d[\d\s().-]{6,}\d"#,
      with: "[redacted phone]",
      options: .regularExpression
    )
    if let range = text.range(of: #"^# .*$"#, options: .regularExpression) {
      text.replaceSubrange(range, with: "# \(safeProfileTitle(profileID: profileID))")
    }
    return text
  }

  private func prompt(for profiles: [TextingVoiceProfile], targetProfileIDs: [String]) -> String {
    let payloadProfiles = profiles.prefix(18).enumerated().map { idx, profile in
      profilePayload(profile, index: idx)
    }
    return """
    Build concise, inspectable texting style guides from privacy-scrubbed aggregate texting fingerprints only.

    Privacy constraints:
    - You are not receiving message bodies.
    - You are not receiving phone numbers, emails, or raw recipient labels.
    - Profile display names are pseudonyms unless identity hints are enabled, in which case they may be contact-resolved labels with phone numbers, emails, and raw handles removed.
    - If identity_hint appears, use it only to infer broad tone context such as likely gender, group/family/work shape, or relationship formality. Do not quote it outside the guide title.
    - Do not ask for message bodies.
    - Do not invent specific events, memories, opinions, or relationships.
    - Convert the aggregate data into useful drafting judgment: warmth, brevity, punctuation, when to mirror context, and what to avoid.

    Return strict JSON only:
    {
      "guides": [
        {
          "profile_id": "base",
          "markdown": "# ...\\n..."
        }
      ]
    }

    Target profile IDs:
    \(Self.jsonString(targetProfileIDs))

    Return one guide for each target profile ID only. Use any base profile in the payload as reference context, but do not return an extra base guide unless "base" is a target profile ID.

    Each markdown guide should have:
    - a one-paragraph voice summary
    - "Draft like this" bullets
    - "Avoid" bullets
    - "When context should override this" bullets
    - for people-specific and people-type profiles, how this differs from the base voice
    - a final privacy note saying it was generated from privacy-scrubbed aggregate metadata, not stored message bodies, phone numbers, or emails

    Profiles:
    \(Self.jsonString(payloadProfiles))
    """
  }

  private func profilePayload(_ profile: TextingVoiceProfile, index: Int) -> [String: Any] {
    let scrubbedName = Self.scrubbedDisplayName(for: profile, index: index)
    var payload: [String: Any] = [
      "profile_id": profile.profile_id,
      "display_name": includeIdentityHints
        ? Self.promptDisplayName(for: profile, fallback: scrubbedName)
        : scrubbedName,
      "kind": profile.kind,
      "scope_kind": Self.scrubbedScopeKind(for: profile),
      "sample_size": profile.sample_size,
      "window_start": profile.window_start,
      "window_end": profile.window_end,
      "length": [
        "median": profile.length.median,
        "p25": profile.length.p25,
        "p75": profile.length.p75,
        "pct_under_20": profile.length.pct_under_20
      ],
      "capitalization": [
        "pct_lowercase_start": profile.capitalization.pct_lowercase_start,
        "pct_all_lowercase": profile.capitalization.pct_all_lowercase
      ],
      "punctuation": [
        "pct_ending_period": profile.punctuation.pct_ending_period,
        "pct_ending_exclaim": profile.punctuation.pct_ending_exclaim,
        "pct_ending_question": profile.punctuation.pct_ending_question,
        "pct_ending_none": profile.punctuation.pct_ending_none
      ],
      "emoji": [
        "pct_messages_with_emoji": profile.emoji.pct_messages_with_emoji,
        "top": profile.emoji.top.map { ["token": $0.token, "count": $0.count] }
      ],
      "abbreviations": profile.abbreviations.map { ["token": $0.token, "count": $0.count] },
      "openers": profile.openers.map { ["token": $0.token, "count": $0.count] },
      "closers": profile.closers.map { ["token": $0.token, "count": $0.count] },
      "bursts": [
        "median_messages_per_burst": profile.bursts.median_messages_per_burst,
        "p75_messages_per_burst": profile.bursts.p75_messages_per_burst
      ],
      "warnings": profile.warnings
    ]
    if includeIdentityHints, let hint = Self.identityHint(for: profile) {
      payload["identity_hint"] = hint
    }
    return payload
  }

  private static func scrubbedDisplayName(for profile: TextingVoiceProfile, index: Int) -> String {
    if profile.profile_id == "base" { return "Base texting style" }
    if profile.profile_id.hasPrefix("type-") { return "People-type style \(index + 1)" }
    return "Frequent conversation style \(index + 1)"
  }

  private static func scrubbedScopeKind(for profile: TextingVoiceProfile) -> String {
    if profile.profile_id == "base" { return "base" }
    if profile.profile_id.hasPrefix("type-") { return "people_type" }
    return "person_specific"
  }

  private static func promptDisplayName(for profile: TextingVoiceProfile, fallback: String) -> String {
    ContactNameResolver.load().promptSafeDisplayName(profile, fallback: fallback)
  }

  private static func identityHint(for profile: TextingVoiceProfile) -> String? {
    guard profile.profile_id != "base" else { return nil }
    let label = ContactNameResolver.load()
      .promptSafeDisplayName(profile, fallback: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }
    if ContactNameResolver.looksLikeHandle(label) { return nil }

    let words = label
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty && !looksLikeHandle($0) }
      .prefix(4)
    guard !words.isEmpty else { return nil }

    let kind = profile.profile_id.hasPrefix("type-") || profile.scope.contains("type")
      ? "conversation label"
      : "possible first name"
    return "\(kind): \(words.joined(separator: " "))"
  }

  private static func looksLikeHandle(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return true }
    let digits = trimmed.filter(\.isNumber).count
    if digits >= 5 { return true }
    if trimmed.hasPrefix("+") { return true }
    return false
  }

  private static func jsonString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
      return "[]"
    }
    return string
  }

  private static func extractOutputText(from data: Data) throws -> String {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TextingVoiceLLMError.invalidResponse
    }
    if let outputText = root["output_text"] as? String, !outputText.isEmpty {
      return outputText
    }
    if let output = root["output"] as? [[String: Any]] {
      let parts = output.flatMap { item -> [String] in
        guard let content = item["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { $0["text"] as? String }
      }
      if !parts.isEmpty { return parts.joined(separator: "\n") }
    }
    throw TextingVoiceLLMError.invalidResponse
  }

  private static func extractAnthropicText(from data: Data) throws -> String {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = root["content"] as? [[String: Any]] else {
      throw TextingVoiceLLMError.invalidResponse
    }
    let parts = content.compactMap { item -> String? in
      guard item["type"] as? String == "text" else { return nil }
      return item["text"] as? String
    }
    guard !parts.isEmpty else { throw TextingVoiceLLMError.invalidResponse }
    return parts.joined(separator: "\n")
  }

  private static func parseGuides(_ text: String) -> [String: String]? {
    let cleaned = stripCodeFence(text)
    guard let data = cleaned.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let guides = root["guides"] as? [[String: Any]] else {
      return nil
    }
    var out: [String: String] = [:]
    for guide in guides {
      guard let id = guide["profile_id"] as? String,
            isSafeProfileID(id),
            let markdown = guide["markdown"] as? String,
            !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      out[id] = markdown
    }
    return out
  }

  private static func parseSingleGuide(_ text: String, expectedProfileID: String) -> String? {
    let cleaned = stripCodeFence(text)
    guard let data = cleaned.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = root["profile_id"] as? String,
          id == expectedProfileID,
          let markdown = root["markdown"] as? String,
          !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return markdown
  }

  private static func stripCodeFence(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else { return trimmed }
    var lines = trimmed.components(separatedBy: .newlines)
    if !lines.isEmpty { lines.removeFirst() }
    if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isSafeProfileID(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 80 else { return false }
    return id.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }
  }

  private static func errorMessage(from data: Data, providerName: String, statusCode: Int) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = root["error"] as? [String: Any] else {
      return "\(providerName) returned HTTP \(statusCode)."
    }
    let type = error["type"] as? String
    let message = error["message"] as? String
    return [providerName, "HTTP \(statusCode)", type, message]
      .compactMap { $0 }
      .joined(separator: ": ")
  }

  private static func anthropicErrorMessage(from data: Data, statusCode: Int) -> String {
    errorMessage(from: data, providerName: "Claude", statusCode: statusCode)
  }
}
