import Foundation

enum AnalyticsEvent: String, CaseIterable {
  case appLaunched = "app_launched"
  case appVersionSeen = "app_version_seen"
  case onboardingCompleted = "onboarding_completed"
  case transportEnabled = "transport_enabled"
  case setupWalkthroughCompleted = "setup_walkthrough_completed"
  case setupWalkthroughSkipped = "setup_walkthrough_skipped"
  case settingsOpened = "settings_opened"
  case telemetryEnabled = "telemetry_enabled"
  case telemetryDisabled = "telemetry_disabled"
  case featureViewed = "feature_viewed"
  case draftStaged = "draft_staged"
  case draftSent = "draft_sent"
  case scheduledMessageCreated = "scheduled_message_created"
  case labScanStarted = "lab_scan_started"
  case labScanCompleted = "lab_scan_completed"
  case labScanFailed = "lab_scan_failed"
  case wrappedPreviewInteraction = "wrapped_preview_interaction"
  case diagnosticsExportCreated = "diagnostics_export_created"
}

enum AnalyticsProperty: String, CaseIterable {
  case analyticsSchemaVersion = "analytics_schema_version"
  case appPlatform = "app_platform"
  case appVersion = "app_version"
  case build = "build"
  case osVersion = "os_version"
  case processPersonProfile = "$process_person_profile"
  case feature
  case transport
  case source
  case result
  case experienceMode = "experience_mode"
  case cadence
  case scheduledDelayBucket = "scheduled_delay_bucket"
  case lab
  case resultCountBucket = "result_count_bucket"
  case durationBucket = "duration_bucket"
  case errorCategory = "error_category"
  case action
  case includedCrashReports = "included_crash_reports"
  case includedLocalEvents = "included_local_events"
  case includedDaemonLogs = "included_daemon_logs"
  case insertID = "$insert_id"
}

enum AnalyticsValue: Equatable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case double(Double)

  var jsonValue: Any {
    switch self {
    case .string(let value): return value
    case .int(let value): return value
    case .bool(let value): return value
    case .double(let value): return value
    }
  }
}

enum AnalyticsFeature: String {
  case messages
  case automations
  case settings
  case textingStyle = "texting_style"
  case dontGhost = "dont_ghost"
  case eq
  case textingAnalytics = "texting_analytics"
  case wrapped
  case birthdayTexts = "birthday_texts"
}

enum AnalyticsLab: String {
  case textingStyle = "texting_style"
  case dontGhost = "dont_ghost"
  case eq
  case textingAnalytics = "texting_analytics"
  case wrapped
  case wrappedDeepRead = "wrapped_deep_read"
  case birthdayTexts = "birthday_texts"
}

enum AnalyticsTransportName: String {
  case imessage
  case whatsapp
}

enum AnalyticsDraftSource: String {
  case ui
  case firstPartyDirect = "first_party_direct"
  case assistant
  case lab
  case unknown
}

enum AnalyticsResult: String {
  case success
  case failure
}

enum AnalyticsCadence: String {
  case oneTime = "one_time"
}

enum AnalyticsErrorCategory: String {
  case missingBinary = "missing_binary"
  case fullDiskAccess = "full_disk_access"
  case missingAPIKey = "missing_api_key"
  case timeout
  case network
  case localIO = "local_io"
  case invalidResponse = "invalid_response"
  case unknown
}

extension Platform {
  var analyticsTransport: AnalyticsTransportName {
    switch self {
    case .imessage: return .imessage
    case .whatsapp: return .whatsapp
    }
  }
}

enum AnalyticsValidationError: Error, Equatable {
  case eventNotAllowed(String)
  case propertyNotAllowed(event: String, property: String)
  case forbiddenProperty(String)
  case forbiddenString(property: String)
  case invalidValue(property: String)
}

struct AnalyticsClientConfig: Equatable {
  let projectToken: String
  let host: URL

  var isConfigured: Bool {
    !projectToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func fromBundle(
    bundle: Bundle = .main,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> AnalyticsClientConfig {
    let token = environment["POSTHOG_PROJECT_TOKEN"]
      ?? (bundle.object(forInfoDictionaryKey: "MFAPostHogProjectToken") as? String)
      ?? ""
    let hostValue = environment["POSTHOG_HOST"]
      ?? (bundle.object(forInfoDictionaryKey: "MFAPostHogHost") as? String)
      ?? "https://us.i.posthog.com"
    return AnalyticsClientConfig(
      projectToken: token,
      host: URL(string: hostValue) ?? URL(string: "https://us.i.posthog.com")!
    )
  }
}

protocol AnalyticsTransport {
  func send(batch: [[String: Any]], config: AnalyticsClientConfig, completion: @escaping (Bool) -> Void)
}

final class PostHogHTTPTransport: AnalyticsTransport {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func send(batch: [[String: Any]], config: AnalyticsClientConfig, completion: @escaping (Bool) -> Void) {
    guard config.isConfigured else {
      completion(false)
      return
    }
    let endpoint = config.host.appendingPathComponent("batch")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "api_key": config.projectToken,
        "historical_migration": false,
        "batch": batch
      ])
    } catch {
      completion(false)
      return
    }
    session.dataTask(with: request) { _, response, error in
      guard error == nil, let http = response as? HTTPURLResponse else {
        completion(false)
        return
      }
      completion((200..<300).contains(http.statusCode))
    }.resume()
  }
}

final class AnalyticsClient {
  static let shared = AnalyticsClient()

  private let queue = DispatchQueue(label: "com.sunriselabs.messages-for-ai.analytics")
  private var config: AnalyticsClientConfig
  private let transport: AnalyticsTransport
  private let rootDirectory: URL
  private let environmentProvider: () -> [String: String]
  private var userEnabled: Bool
  private var isFlushing = false
  private var flushToken: UUID?

  init(
    config: AnalyticsClientConfig = .fromBundle(),
    userEnabled: Bool = false,
    rootDirectory: URL = AppStoragePaths.homeDirectory.appendingPathComponent(".messages-mcp"),
    transport: AnalyticsTransport = PostHogHTTPTransport(),
    environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }
  ) {
    self.config = config
    self.userEnabled = userEnabled
    self.rootDirectory = rootDirectory
    self.transport = transport
    self.environmentProvider = environmentProvider
  }

  var queueURL: URL {
    rootDirectory.appendingPathComponent("analytics-queue.json")
  }

  func configure(config: AnalyticsClientConfig = .fromBundle(), userEnabled: Bool) {
    queue.async {
      self.config = config
      self.userEnabled = userEnabled
      if !userEnabled {
        self.clearQueue()
      } else {
        self.flushLocked()
      }
    }
  }

  func setUserEnabled(_ enabled: Bool) {
    queue.async {
      self.userEnabled = enabled
      if !enabled {
        self.clearQueue()
      } else {
        self.flushLocked()
      }
    }
  }

  func safeCapture(_ event: AnalyticsEvent, properties: [AnalyticsProperty: AnalyticsValue] = [:]) {
    let raw = Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value.jsonValue) })
    safeCapture(eventName: event.rawValue, properties: raw)
  }

  private func safeCapture(eventName: String, properties: [String: Any]) {
    queue.async {
      guard self.captureAllowedLocked() else { return }
      guard let payload = try? Self.payload(
        eventName: eventName,
        properties: properties,
        distinctID: self.distinctIDLocked(),
        now: Date()
      ) else {
        return
      }
      self.enqueueLocked(payload)
      self.flushLocked()
    }
  }

  private func captureAllowedLocked() -> Bool {
    guard userEnabled, config.isConfigured else { return false }
    if environmentProvider()["MESSAGES_FOR_AI_ANALYTICS_DISABLED"] == "1" {
      return false
    }
    if FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent("analytics.disabled").path) {
      return false
    }
    return true
  }

  private func enqueueLocked(_ payload: [String: Any]) {
    var queued = readQueue()
    queued.append(payload)
    if queued.count > 50 {
      queued = Array(queued.suffix(50))
    }
    writeQueue(queued)
  }

  private func flushLocked() {
    guard !isFlushing, captureAllowedLocked() else { return }
    let batch = readQueue()
    guard !batch.isEmpty else { return }
    let sentIDs = Set(batch.compactMap(Self.insertID))
    let token = UUID()
    isFlushing = true
    flushToken = token
    queue.asyncAfter(deadline: .now() + 15) {
      guard self.flushToken == token else { return }
      self.isFlushing = false
      self.flushToken = nil
      self.flushLocked()
    }
    transport.send(batch: batch, config: config) { ok in
      self.queue.async {
        guard self.flushToken == token else { return }
        self.isFlushing = false
        self.flushToken = nil
        if ok {
          self.removeSentEvents(ids: sentIDs)
          self.flushLocked()
        }
      }
    }
  }

  private func readQueue() -> [[String: Any]] {
    guard let data = try? Data(contentsOf: queueURL) else { return [] }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      quarantineCorruptQueue()
      return []
    }
    return json
  }

  private func quarantineCorruptQueue() {
    let destination = rootDirectory.appendingPathComponent("analytics-queue.\(Self.filenameStamp()).corrupt.json")
    do {
      try FileManager.default.moveItem(at: queueURL, to: destination)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch {
      try? FileManager.default.removeItem(at: queueURL)
    }
  }

  private func writeQueue(_ items: [[String: Any]]) {
    do {
      try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: queueURL, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: queueURL.path)
    } catch {
      // Best effort. Product behavior must not depend on analytics persistence.
    }
  }

  private func clearQueue() {
    try? FileManager.default.removeItem(at: queueURL)
  }

  private func removeSentEvents(ids: Set<String>) {
    guard !ids.isEmpty else { return }
    let remaining = readQueue().filter { payload in
      guard let id = Self.insertID(payload) else { return true }
      return !ids.contains(id)
    }
    if remaining.isEmpty {
      clearQueue()
    } else {
      writeQueue(remaining)
    }
  }

  private func distinctIDLocked() -> String {
    Self.installationID(rootDirectory: rootDirectory)
  }

  /// The anonymous installation id (also the PostHog distinct_id). Shared with
  /// FeatureFlagStore so /decide and /batch identify the same install — do not
  /// fork the storage.
  static func installationID(rootDirectory: URL) -> String {
    let url = rootDirectory.appendingPathComponent("analytics-installation-id")
    if let existing = try? String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !existing.isEmpty {
      return existing
    }
    let created = UUID().uuidString.lowercased()
    do {
      try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
      try created.write(to: url, atomically: true, encoding: .utf8)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Fall back to this process's ID. If it can't persist, privacy still wins.
    }
    return created
  }

  static func payload(
    eventName: String,
    properties: [String: Any],
    distinctID: String,
    now: Date = Date()
  ) throws -> [String: Any] {
    guard let event = AnalyticsEvent(rawValue: eventName) else {
      throw AnalyticsValidationError.eventNotAllowed(eventName)
    }
    var sanitized = try sanitize(event: event, properties: properties)
    sanitized[AnalyticsProperty.analyticsSchemaVersion.rawValue] = 1
    sanitized[AnalyticsProperty.appPlatform.rawValue] = "macos"
    sanitized[AnalyticsProperty.appVersion.rawValue] = appVersion
    sanitized[AnalyticsProperty.build.rawValue] = build
    sanitized[AnalyticsProperty.osVersion.rawValue] = ProcessInfo.processInfo.operatingSystemVersionString
    sanitized[AnalyticsProperty.processPersonProfile.rawValue] = false
    sanitized["distinct_id"] = distinctID
    sanitized[AnalyticsProperty.insertID.rawValue] = UUID().uuidString.lowercased()
    return [
      "event": event.rawValue,
      "properties": sanitized,
      "timestamp": iso(now)
    ]
  }

  static func sanitize(event: AnalyticsEvent, properties: [String: Any]) throws -> [String: Any] {
    let allowed = allowedProperties[event] ?? []
    var out: [String: Any] = [:]
    for (key, value) in properties {
      guard !isForbiddenKey(key) else {
        throw AnalyticsValidationError.forbiddenProperty(key)
      }
      guard let property = AnalyticsProperty(rawValue: key),
            allowed.contains(property)
      else {
        throw AnalyticsValidationError.propertyNotAllowed(event: event.rawValue, property: key)
      }
      guard valueIsAllowed(value, for: property) else {
        throw AnalyticsValidationError.invalidValue(property: key)
      }
      if case .stringValue(let string) = valueKind(value), looksSensitive(string) {
        throw AnalyticsValidationError.forbiddenString(property: key)
      }
      out[key] = value
    }
    return out
  }

  static func resultCountBucket(_ count: Int) -> String {
    switch count {
    case ..<0: return "unknown"
    case 0: return "0"
    case 1...5: return "1_5"
    case 6...20: return "6_20"
    case 21...50: return "21_50"
    default: return "51_plus"
    }
  }

  static func durationBucket(ms: Int) -> String {
    switch ms {
    case ..<0: return "unknown"
    case 0..<1_000: return "lt_1s"
    case 1_000..<5_000: return "1s_5s"
    case 5_000..<30_000: return "5s_30s"
    case 30_000..<120_000: return "30s_2m"
    default: return "gt_2m"
    }
  }

  static func scheduledDelayBucket(from now: Date = Date(), to scheduledAt: Date) -> String {
    let seconds = scheduledAt.timeIntervalSince(now)
    switch seconds {
    case ..<0: return "past"
    case 0..<3_600: return "lt_1h"
    case 3_600..<86_400: return "1h_24h"
    case 86_400..<(7 * 86_400): return "1d_7d"
    default: return "gt_7d"
    }
  }

  static func draftSource(_ source: String?) -> AnalyticsDraftSource {
    let lower = (source ?? "").lowercased()
    if lower.contains("messages for ai ui") { return .ui }
    if lower.contains("birthday") || lower.contains("ghost") || lower.contains("lab") { return .lab }
    if lower.contains("claude") || lower.contains("chatgpt") || lower.contains("assistant") { return .assistant }
    return .unknown
  }

  static func errorCategory(_ error: Error) -> AnalyticsErrorCategory {
    let text = String(describing: error).lowercased()
    if text.contains("full disk") || text.contains("chatdb_open_failed") { return .fullDiskAccess }
    if text.contains("api key") { return .missingAPIKey }
    if text.contains("timed out") || text.contains("timeout") { return .timeout }
    if text.contains("network") || text.contains("url") { return .network }
    if text.contains("decode") || text.contains("invalid") { return .invalidResponse }
    return .unknown
  }

  private static let allowedProperties: [AnalyticsEvent: Set<AnalyticsProperty>] = [
    .appLaunched: [],
    .appVersionSeen: [],
    .onboardingCompleted: [.experienceMode],
    .transportEnabled: [.transport],
    .setupWalkthroughCompleted: [],
    .setupWalkthroughSkipped: [],
    .settingsOpened: [],
    .telemetryEnabled: [],
    .telemetryDisabled: [],
    .featureViewed: [.feature],
    .draftStaged: [.transport, .source],
    .draftSent: [.transport, .result, .source],
    .scheduledMessageCreated: [.cadence, .scheduledDelayBucket],
    .labScanStarted: [.lab],
    .labScanCompleted: [.lab, .resultCountBucket, .durationBucket],
    .labScanFailed: [.lab, .errorCategory],
    .wrappedPreviewInteraction: [.lab, .action],
    .diagnosticsExportCreated: [.includedCrashReports, .includedLocalEvents, .includedDaemonLogs]
  ]

  private static let forbiddenKeyFragments = [
    "message_body", "draft_text", "prompt", "response_text", "recipient",
    "contact_name", "phone", "email", "apple_id", "whatsapp_id", "chat_id",
    "message_id", "thread_id", "handle", "raw_identifier", "api_key",
    "access_token", "file_path", "calendar_event_title", "body", "text"
  ]

  private static func isForbiddenKey(_ key: String) -> Bool {
    let lower = key.lowercased()
    return forbiddenKeyFragments.contains { lower.contains($0) }
  }

  private enum ValueKind {
    case stringValue(String)
    case boolValue
    case numberValue
    case unsupported
  }

  private static func valueKind(_ value: Any) -> ValueKind {
    switch value {
    case let value as String: return .stringValue(value)
    case is Bool: return .boolValue
    case is Int, is Double, is Float: return .numberValue
    default: return .unsupported
    }
  }

  private static func valueIsAllowed(_ value: Any, for property: AnalyticsProperty) -> Bool {
    switch (property, valueKind(value)) {
    case (.feature, .stringValue(let value)):
      return AnalyticsFeature(rawValue: value) != nil
    case (.transport, .stringValue(let value)):
      return AnalyticsTransportName(rawValue: value) != nil
    case (.source, .stringValue(let value)):
      return AnalyticsDraftSource(rawValue: value) != nil
    case (.result, .stringValue(let value)):
      return AnalyticsResult(rawValue: value) != nil
    case (.experienceMode, .stringValue(let value)):
      return AppExperienceMode(rawValue: value) != nil
    case (.cadence, .stringValue(let value)):
      return AnalyticsCadence(rawValue: value) != nil
    case (.scheduledDelayBucket, .stringValue(let value)):
      return ["past", "lt_1h", "1h_24h", "1d_7d", "gt_7d"].contains(value)
    case (.lab, .stringValue(let value)):
      return AnalyticsLab(rawValue: value) != nil
    case (.resultCountBucket, .stringValue(let value)):
      return ["unknown", "0", "1_5", "6_20", "21_50", "51_plus"].contains(value)
    case (.durationBucket, .stringValue(let value)):
      return ["unknown", "lt_1s", "1s_5s", "5s_30s", "30s_2m", "gt_2m"].contains(value)
    case (.errorCategory, .stringValue(let value)):
      return AnalyticsErrorCategory(rawValue: value) != nil
    case (.action, .stringValue(let value)):
      return WrappedPreviewTelemetryAction(rawValue: value) != nil
    case (.includedCrashReports, .boolValue), (.includedLocalEvents, .boolValue), (.includedDaemonLogs, .boolValue):
      return true
    default:
      return false
    }
  }

  private static func looksSensitive(_ value: String) -> Bool {
    let lower = value.lowercased()
    if lower.contains("phc_") || lower.contains("sk-") { return true }
    if lower.contains("@") { return true }
    if value.range(of: #"\+?\d[\d\s().-]{6,}\d"#, options: .regularExpression) != nil { return true }
    return false
  }

  private static var appVersion: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
  }

  private static var build: String {
    (Bundle.main.object(forInfoDictionaryKey: "MFABuildSHA") as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
      ?? "unknown"
  }

  private static func insertID(_ payload: [String: Any]) -> String? {
    guard let properties = payload["properties"] as? [String: Any] else { return nil }
    return properties[AnalyticsProperty.insertID.rawValue] as? String
  }

  private static func filenameStamp(_ date: Date = Date()) -> String {
    "\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
  }

  private static let isoFormatter = ISO8601DateFormatter()

  private static func iso(_ date: Date) -> String {
    isoFormatter.string(from: date)
  }
}
