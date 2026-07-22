import Foundation

/// Client feature flags, keyed to the PostHog project flags of the same name.
/// Builtin defaults are the shipped behavior when PostHog is unreachable or
/// analytics are off: everything flag-gated stays hidden.
enum MFAFeatureFlag: String, CaseIterable {
  case wrappedDeepRead = "wrapped-deep-read"
  case premiumMessaging = "premium-messaging"
  case babysitter = "babysitter"
  case imessageAXTapbacks = "imessage-ax-tapbacks"
  case aiUsage = "ai-usage"
  case draftSafetyStates = "draft-safety-states"
  case transcriptSnapFix = "transcript-snap-fix"
  case deviceRelay = "device-relay"

  var builtinDefault: Bool {
    switch self {
    // Shipped on in v0.11.2 after live validation (the graduation missed the v0.11.1
    // release — it landed on the staging branch, not the release branch). The flag
    // stays as a kill-switch (Developer settings toggle Off → the prior behavior) and
    // lets a remote rollback flip it without a code change.
    case .draftSafetyStates, .transcriptSnapFix: return true
    default: return false
    }
  }

  var displayName: String {
    switch self {
    case .wrappedDeepRead: return "Wrapped Deep Read"
    case .premiumMessaging: return "Premium messaging"
    case .babysitter: return "Babysitter"
    case .imessageAXTapbacks: return "iMessage tapback sending"
    case .aiUsage: return "AI Usage & Costs"
    case .draftSafetyStates: return "Draft safety states"
    case .transcriptSnapFix: return "Transcript snap fix"
    case .deviceRelay: return "Cross-device relay"
    }
  }

  var blurb: String {
    switch self {
    case .wrappedDeepRead:
      return "The AI insights strip under the Texting Wrapped story: voice signature, ghosting profile, vibe, severance score."
    case .premiumMessaging:
      return "Subscription and account surfaces. Off is the pure bring-your-own-key experience."
    case .babysitter:
      return "Premium babysitter coordination: local roster, request waterfall, and partner-CC group asks."
    case .imessageAXTapbacks:
      return "Experimental tapback sending through Messages.app Accessibility actions. Requires Accessibility permission and a visible, unambiguous bubble."
    case .aiUsage:
      return "AI Usage & Costs: a metadata-only ledger of your bring-your-own-key AI spend by feature, monthly budget caps, and model-downgrade suggestions. Shown only when a BYOK key is set. Off ships it hidden while it bakes."
    case .draftSafetyStates:
      return "Reversible discard (the Delete button collapses to a 3s Undo strip before it actually discards), a keyboard/VoiceOver-driveable hold-to-send (two-step arm→fire that still honors the hold), and plain-language send-failure copy on the approval bubble. Off keeps today's immediate discard + pointer-only send + raw error text."
    case .deviceRelay:
      return "Cross-device draft relay between your Macs and your phone (SUN-613). Off ships it inert: no listener binds, no device keys are generated, and drafts behave exactly as they do today. Personal-scale and unfinished, keep it off unless you are working on it."
    case .transcriptSnapFix:
      return "Rebuilds transcript auto-scroll: one scroll per new message — always on your own send, and on an incoming message only when you're already at the bottom — instead of the multi-pass snap that jumped after a send. Off keeps today's snap."
    }
  }
}

/// Which tier won the resolution. Surfaced in the developer UI only.
enum FeatureFlagSource: String, Equatable {
  case override
  case remote
  case `default`
}

/// Resolution precedence is the one rule of the system: local developer
/// override beats remote (PostHog) beats builtin default. Pure so the
/// precedence is testable without MainActor or disk.
enum FeatureFlagResolution {
  static func resolved(
    _ flag: MFAFeatureFlag,
    overrides: [String: Bool],
    remote: [String: Bool]
  ) -> Bool {
    if let value = overrides[flag.rawValue] { return value }
    if let value = remote[flag.rawValue] { return value }
    return flag.builtinDefault
  }

  static func source(
    _ flag: MFAFeatureFlag,
    overrides: [String: Bool],
    remote: [String: Bool]
  ) -> FeatureFlagSource {
    if overrides[flag.rawValue] != nil { return .override }
    if remote[flag.rawValue] != nil { return .remote }
    return .default
  }
}

/// On-disk cache (~/.messages-mcp/feature-flags.json, 0600) so launches
/// resolve instantly from last-known remote values, and developer overrides
/// survive restarts.
struct FeatureFlagFileState: Codable, Equatable {
  var schemaVersion: Int
  var remote: [String: Bool]
  var overrides: [String: Bool]
  var fetchedAt: String?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case remote
    case overrides
    case fetchedAt = "fetched_at"
  }
}

@MainActor
final class FeatureFlagStore: ObservableObject {
  enum FetchState: Equatable {
    case idle
    case fetching
    case fetched(Date)
    case skippedAnalyticsOff
    case skippedNoToken
    case failed(String)
  }

  @Published private(set) var remoteValues: [String: Bool] = [:]
  @Published private(set) var overrides: [String: Bool] = [:]
  @Published private(set) var fetchState: FetchState = .idle
  /// Survives restarts (cached in the JSON file) so the dev UI can say
  /// "cached from <when>" even before the first fetch of this session.
  @Published private(set) var lastFetchedAt: Date?

  private let fileURL: URL
  private let config: AnalyticsClientConfig
  /// PRIVACY GATE: remote flags ride the same opt-in as product analytics.
  /// When this returns false the store does NO network — resolution is
  /// override > cached-last-known > builtin default.
  private let analyticsEnabled: () -> Bool
  private let transport: (URLRequest) async throws -> Data

  init(
    fileURL: URL = AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("feature-flags.json"),
    config: AnalyticsClientConfig = .fromBundle(),
    analyticsEnabled: @escaping () -> Bool = { false },
    transport: ((URLRequest) async throws -> Data)? = nil
  ) {
    self.fileURL = fileURL
    self.config = config
    self.analyticsEnabled = analyticsEnabled
    self.transport = transport ?? { request in
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      return data
    }
    loadFromDisk()
  }

  // MARK: - Resolution

  func resolved(_ flag: MFAFeatureFlag) -> Bool {
    FeatureFlagResolution.resolved(flag, overrides: overrides, remote: remoteValues)
  }

  func source(_ flag: MFAFeatureFlag) -> FeatureFlagSource {
    FeatureFlagResolution.source(flag, overrides: overrides, remote: remoteValues)
  }

  func override(for flag: MFAFeatureFlag) -> Bool? {
    overrides[flag.rawValue]
  }

  /// nil clears the override (back to remote/default).
  func setOverride(_ flag: MFAFeatureFlag, to value: Bool?) {
    if let value {
      overrides[flag.rawValue] = value
    } else {
      overrides.removeValue(forKey: flag.rawValue)
    }
    persist()
  }

  /// Nonisolated point-read of a flag straight from the on-disk cache, for code
  /// running off the main actor (e.g. the send path, which is a static async
  /// func with no `FeatureFlagStore` instance). Mirrors `loadFromDisk` +
  /// `FeatureFlagResolution`. Falls back to the builtin default if the cache is
  /// missing or unreadable, so a torn/absent file can only DISABLE a gated
  /// feature, never silently enable one.
  nonisolated static func resolvedFromDisk(
    _ flag: MFAFeatureFlag,
    fileURL: URL = AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("feature-flags.json")
  ) -> Bool {
    guard let data = try? Data(contentsOf: fileURL),
          let state = try? JSONDecoder().decode(FeatureFlagFileState.self, from: data),
          state.schemaVersion == 1 else {
      return flag.builtinDefault
    }
    return FeatureFlagResolution.resolved(flag, overrides: state.overrides, remote: state.remote)
  }

  // MARK: - Remote (PostHog /decide v3)

  /// Fire-and-forget launch refresh. Cached values are already loaded, so
  /// the UI never waits on this.
  func refreshOnLaunch() {
    Task { await self.refresh() }
  }

  func refresh() async {
    guard analyticsEnabled() else {
      fetchState = .skippedAnalyticsOff
      return
    }
    // Dev builds carry no token; skip silently rather than erroring.
    guard config.isConfigured else {
      fetchState = .skippedNoToken
      return
    }
    guard let request = makeDecideRequest() else {
      fetchState = .failed("bad decide URL")
      return
    }
    fetchState = .fetching
    do {
      let data = try await transport(request)
      guard let flags = Self.parseDecideResponse(data) else {
        fetchState = .failed("unexpected response shape")
        return
      }
      remoteValues = flags
      let now = Date()
      lastFetchedAt = now
      fetchState = .fetched(now)
      persist()
    } catch {
      fetchState = .failed(error.localizedDescription)
    }
  }

  private func makeDecideRequest() -> URLRequest? {
    guard var components = URLComponents(
      url: config.host.appendingPathComponent("decide"),
      resolvingAgainstBaseURL: false
    ) else { return nil }
    components.path += "/"
    components.queryItems = [URLQueryItem(name: "v", value: "3")]
    guard let url = components.url else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10
    let distinctID = AnalyticsClient.installationID(rootDirectory: fileURL.deletingLastPathComponent())
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "api_key": config.projectToken,
      "distinct_id": distinctID
    ])
    return request
  }

  /// /decide v3 returns {"featureFlags": {key: Bool | variant-String}}.
  /// Booleans pass through; a variant string means the flag is on; anything
  /// else is dropped. nil = malformed payload (caller keeps the cache).
  nonisolated static func parseDecideResponse(_ data: Data) -> [String: Bool]? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let flags = json["featureFlags"] as? [String: Any] else {
      return nil
    }
    var out: [String: Bool] = [:]
    for (key, value) in flags {
      if let string = value as? String {
        out[key] = !string.isEmpty
      } else if let bool = value as? Bool {
        out[key] = bool
      }
    }
    return out
  }

  // MARK: - Dev UI status line

  var lastFetchDescription: String {
    switch fetchState {
    case .idle:
      if let lastFetchedAt {
        return "Cached from \(Self.relative(lastFetchedAt))"
      }
      return "Never fetched"
    case .fetching:
      return "Fetching…"
    case .fetched(let date):
      return "Fetched \(Self.relative(date))"
    case .skippedAnalyticsOff:
      return "Skipped — product analytics are off"
    case .skippedNoToken:
      return "Skipped — no analytics token in this build"
    case .failed(let reason):
      return "Failed: \(reason)"
    }
  }

  private static func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  // MARK: - Disk cache

  private func loadFromDisk() {
    guard let data = try? Data(contentsOf: fileURL),
          let state = try? JSONDecoder().decode(FeatureFlagFileState.self, from: data),
          state.schemaVersion == 1 else {
      return
    }
    remoteValues = state.remote
    overrides = state.overrides
    lastFetchedAt = state.fetchedAt.flatMap { Self.isoFormatter.date(from: $0) }
  }

  private func persist() {
    let state = FeatureFlagFileState(
      schemaVersion: 1,
      remote: remoteValues,
      overrides: overrides,
      fetchedAt: lastFetchedAt.map { Self.isoFormatter.string(from: $0) }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(state) else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      // Best effort. Flags still resolve from memory this session.
    }
  }

  private static let isoFormatter = ISO8601DateFormatter()
}
