import Foundation
import AppKit

struct TextingAnalyticsReport: Decodable {
  struct Archetype: Decodable {
    let name: String?
    let short: String?
    let verdict: String?
    let why: String?
  }

  struct Latency: Decodable {
    let totalReplyPairs: Int?
    let pctWithin5Min: Double?
    let pctWithin30Min: Double?
    let pctWithin1Hr: Double?
    let pctWithin4Hr: Double?
    let meanMinutes: Double?
    let medianMinutes: Double?
    let threadCount: Int?

    enum CodingKeys: String, CodingKey {
      case totalReplyPairs = "total_reply_pairs"
      case pctWithin5Min = "pct_within_5min"
      case pctWithin30Min = "pct_within_30min"
      case pctWithin1Hr = "pct_within_1hr"
      case pctWithin4Hr = "pct_within_4hr"
      case meanMinutes = "mean_minutes"
      case medianMinutes = "median_minutes"
      case threadCount = "thread_count"
    }
  }

  struct BallInCourt: Decodable {
    let totalThreadsSampled: Int?
    let threadsWithBallInCourt: Int?
    let pctBallInCourt: Double?
    let liveConversationsEstimate: Int?

    enum CodingKeys: String, CodingKey {
      case totalThreadsSampled = "total_threads_sampled"
      case threadsWithBallInCourt = "threads_with_ball_in_court"
      case pctBallInCourt = "pct_ball_in_court"
      case liveConversationsEstimate = "live_conversations_estimate"
    }
  }

  struct GroupContribution: Decodable {
    struct GroupThread: Decodable, Identifiable {
      let threadLabel: String?
      let participantCount: Int?
      let total: Int?
      let userCount: Int?
      let userPct: Double?
      let fairShareRatio: Double?

      var id: String { "\(threadLabel ?? "group")-\(total ?? 0)-\(userCount ?? 0)" }

      enum CodingKeys: String, CodingKey {
        case threadLabel = "thread_label"
        case participantCount = "participant_count"
        case total
        case userCount = "user_count"
        case userPct = "user_pct"
        case fairShareRatio = "fair_share_ratio"
      }
    }

    let totalGroupsAnalyzed: Int?
    let totalMessagesInGroups: Int?
    let userMessagesInGroups: Int?
    let userContributionPct: Double?
    let userReactionRatePct: Double?
    let groupsWhereUserSilent: Int?
    let groupsMostlyReactions: Int?
    let perThread: [GroupThread]?

    enum CodingKeys: String, CodingKey {
      case totalGroupsAnalyzed = "total_groups_analyzed"
      case totalMessagesInGroups = "total_messages_in_groups"
      case userMessagesInGroups = "user_messages_in_groups"
      case userContributionPct = "user_contribution_pct"
      case userReactionRatePct = "user_reaction_rate_pct"
      case groupsWhereUserSilent = "groups_where_user_silent"
      case groupsMostlyReactions = "groups_mostly_reactions"
      case perThread = "per_thread"
    }
  }

  struct PersonCount: Decodable, Identifiable {
    let name: String?
    let count: Int?
    let chars: Int?

    var id: String { "\(name ?? "person")-\(count ?? chars ?? 0)" }
  }

  struct TalkListen: Decodable {
    struct PersonShare: Decodable, Identifiable {
      let name: String?
      let youWords: Int?
      let themWords: Int?
      let yourSharePct: Double?

      var id: String { "\(name ?? "person")-\(youWords ?? 0)-\(themWords ?? 0)" }

      enum CodingKeys: String, CodingKey {
        case name
        case youWords = "you_words"
        case themWords = "them_words"
        case yourSharePct = "your_share_pct"
      }
    }

    let youWords: Int?
    let themWords: Int?
    let yourSharePct: Double?
    let perThread: [PersonShare]?

    enum CodingKeys: String, CodingKey {
      case youWords = "you_words"
      case themWords = "them_words"
      case yourSharePct = "your_share_pct"
      case perThread = "per_thread"
    }
  }

  struct ActivityTrend: Decodable {
    struct Row: Decodable, Identifiable, Equatable {
      let period: String?
      let label: String?
      let sent: Int?
      let received: Int?
      let oneToOneSent: Int?
      let oneToOneReceived: Int?
      let groupSent: Int?
      let groupReceived: Int?

      var id: String { period ?? label ?? "\(sent ?? 0)-\(received ?? 0)" }

      enum CodingKeys: String, CodingKey {
        case period
        case label
        case sent
        case received
        case oneToOneSent = "one_to_one_sent"
        case oneToOneReceived = "one_to_one_received"
        case groupSent = "group_sent"
        case groupReceived = "group_received"
      }
    }

    let granularity: String?
    let rows: [Row]?
  }

  struct Rhythm: Decodable {
    struct Bucket: Decodable, Identifiable, Equatable {
      let weekday: Int?
      let hour: Int?
      let sent: Int?
      let received: Int?
      let total: Int?

      var id: String { "\(weekday ?? 0)-\(hour ?? 0)" }
    }

    let buckets: [Bucket]?
    let peakSent: Bucket?

    enum CodingKeys: String, CodingKey {
      case buckets
      case peakSent = "peak_sent"
    }
  }

  struct DirectionCounts: Decodable {
    let sent: Int?
    let received: Int?
  }

  struct ConversationMix: Decodable {
    let oneToOne: DirectionCounts?
    let groups: DirectionCounts?
    let kinds: [String: DirectionCounts]?

    enum CodingKeys: String, CodingKey {
      case oneToOne = "one_to_one"
      case groups
      case kinds
    }
  }

  struct Initiators: Decodable {
    struct Contact: Decodable, Identifiable {
      let name: String?
      let conversations: Int?
      let youStarted: Int?
      let theyStarted: Int?
      let pctYouStart: Double?

      var id: String { "\(name ?? "person")-\(conversations ?? 0)" }

      enum CodingKeys: String, CodingKey {
        case name
        case conversations
        case youStarted = "you_started"
        case theyStarted = "they_started"
        case pctYouStart = "pct_you_start"
      }
    }

    let conversations: Int?
    let youStarted: Int?
    let theyStarted: Int?
    let pctYouStart: Double?
    let perContact: [Contact]?

    enum CodingKeys: String, CodingKey {
      case conversations
      case youStarted = "you_started"
      case theyStarted = "they_started"
      case pctYouStart = "pct_you_start"
      case perContact = "per_contact"
    }
  }

  struct Streaks: Decodable {
    struct Entry: Decodable, Identifiable {
      let name: String?
      let days: Int?
      let ended: String?

      var id: String { "\(name ?? "person")-\(days ?? 0)-\(ended ?? "")" }
    }

    let best: Entry?
    let perContact: [Entry]?

    enum CodingKeys: String, CodingKey {
      case best
      case perContact = "per_contact"
    }
  }

  struct DoubleTexts: Decodable {
    struct Contact: Decodable, Identifiable {
      let name: String?
      let doubleTexts: Int?
      let outbound: Int?
      let ratePct: Double?

      var id: String { "\(name ?? "person")-\(doubleTexts ?? 0)" }

      enum CodingKeys: String, CodingKey {
        case name
        case doubleTexts = "double_texts"
        case outbound
        case ratePct = "rate_pct"
      }
    }

    let doubleTexts: Int?
    let outboundMessages: Int?
    let ratePct: Double?
    let perContact: [Contact]?

    enum CodingKeys: String, CodingKey {
      case doubleTexts = "double_texts"
      case outboundMessages = "outbound_messages"
      case ratePct = "rate_pct"
      case perContact = "per_contact"
    }
  }

  struct BusiestDay: Decodable {
    let date: String?
    let total: Int?
    let sent: Int?
    let received: Int?
  }

  struct Hours: Decodable {
    struct Bucket: Decodable, Identifiable, Equatable {
      let hour: Int?
      let sent: Int?
      let received: Int?

      var id: Int { hour ?? 0 }
    }

    let buckets: [Bucket]?
    let nightOwlPct: Double?
    let peakHour: Int?

    enum CodingKeys: String, CodingKey {
      case buckets
      case nightOwlPct = "night_owl_pct"
      case peakHour = "peak_hour"
    }
  }

  struct TopShare: Decodable {
    struct Person: Decodable, Identifiable {
      let name: String?
      let count: Int?
      let pct: Double?

      var id: String { "\(name ?? "person")-\(count ?? 0)" }
    }

    let total: Int?
    let people: [Person]?
    let othersCount: Int?
    let othersPct: Double?

    enum CodingKeys: String, CodingKey {
      case total
      case people
      case othersCount = "others_count"
      case othersPct = "others_pct"
    }
  }

  struct Comparison: Decodable {
    struct Metric: Decodable, Identifiable {
      let key: String?
      let label: String?
      let unit: String?
      let current: Double?
      let previous: Double?
      let delta: Double?

      var id: String { key ?? label ?? UUID().uuidString }
    }

    let mode: String?
    let metrics: [Metric]?
  }

  struct Emoji: Decodable {
    let pctMessagesWithEmoji: Double?
    let topEmoji: [String]?

    enum CodingKeys: String, CodingKey {
      case pctMessagesWithEmoji = "pct_messages_with_emoji"
      case topEmoji = "top_emoji"
      case top
    }

    enum EmojiCountKeys: String, CodingKey {
      case emoji
      case count
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      pctMessagesWithEmoji = try container.decodeIfPresent(Double.self, forKey: .pctMessagesWithEmoji)
      if let values = try? container.decodeIfPresent([String].self, forKey: .topEmoji) {
        topEmoji = values
      } else if var nested = try? container.nestedUnkeyedContainer(forKey: .top) {
        var out: [String] = []
        while !nested.isAtEnd {
          let item = try nested.nestedContainer(keyedBy: EmojiCountKeys.self)
          if let emoji = try item.decodeIfPresent(String.self, forKey: .emoji) {
            out.append(emoji)
          }
        }
        topEmoji = out
      } else {
        topEmoji = nil
      }
    }
  }

  struct Style: Decodable {
    let pctNoTerminalPunct: Double?
    let medianChars: Double?

    enum CodingKeys: String, CodingKey {
      case pctNoTerminalPunct = "pct_no_terminal_punct"
      case medianChars = "median_chars"
      case pctEndPeriod = "pct_end_period"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      medianChars = try container.decodeIfPresent(Double.self, forKey: .medianChars)
      if let value = try container.decodeIfPresent(Double.self, forKey: .pctNoTerminalPunct) {
        pctNoTerminalPunct = value
      } else if let pctEndPeriod = try container.decodeIfPresent(Double.self, forKey: .pctEndPeriod) {
        pctNoTerminalPunct = max(0, min(100, 100 - pctEndPeriod))
      } else {
        pctNoTerminalPunct = nil
      }
    }
  }

  struct Age: Decodable {
    let estimatedAge: Int?
    let confidence: String?

    enum CodingKeys: String, CodingKey {
      case estimatedAge = "estimated_age"
      case confidence
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      estimatedAge = try container.decodeIfPresent(Int.self, forKey: .estimatedAge)
      if let string = try? container.decodeIfPresent(String.self, forKey: .confidence) {
        confidence = string
      } else if let number = try? container.decodeIfPresent(Double.self, forKey: .confidence) {
        confidence = "\(number)"
      } else {
        confidence = nil
      }
    }
  }

  struct Filters: Decodable {
    let excludedBusinessThreads: Int?

    enum CodingKeys: String, CodingKey {
      case excludedBusinessThreads = "excluded_business_1to1_threads"
    }
  }

  let schemaVersion: String?
  let generatedAtMs: Double?
  let windowLabel: String?
  let windowDays: Int?
  let totalSent: Int?
  let archetype: Archetype?
  let latency: Latency?
  let ballInCourt: BallInCourt?
  let groupContribution: GroupContribution?
  let topPeople: [PersonCount]?
  let topPeopleL30: [PersonCount]?
  let topPeopleByChars: [PersonCount]?
  let talkListen: TalkListen?
  let activityTrend: ActivityTrend?
  let rhythm: Rhythm?
  let conversationMix: ConversationMix?
  let comparison: Comparison?
  let initiators: Initiators?
  let streaks: Streaks?
  let doubleTexts: DoubleTexts?
  let busiestDay: BusiestDay?
  let hours: Hours?
  let topShare: TopShare?
  let emoji: Emoji?
  let style: Style?
  let age: Age?
  let filters: Filters?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAtMs = "generated_at_ms"
    case windowLabel = "window_label"
    case windowDays = "window_days"
    case totalSent = "total_sent"
    case archetype
    case latency
    case ballInCourt = "ball_in_court"
    case groupContribution = "group_contribution"
    case topPeople = "top_people"
    case topPeopleL30 = "top_people_l30"
    case topPeopleByChars = "top_people_by_chars"
    case talkListen = "talk_listen"
    case activityTrend = "activity_trend"
    case rhythm
    case conversationMix = "conversation_mix"
    case comparison
    case initiators
    case streaks
    case doubleTexts = "double_texts"
    case busiestDay = "busiest_day"
    case hours
    case topShare = "top_share"
    case emoji
    case style
    case age
    case filters
  }
}

struct TextingAnalyticsWindow: Equatable {
  enum Kind: String, CaseIterable {
    case lastMonth = "Last month"
    case pastYear = "Past year"
    case allTime = "All time"
    case custom = "Custom"
  }

  var kind: Kind
  var startDate: Date?
  var endDate: Date?

  var fileSlug: String {
    switch kind {
    case .lastMonth: return "last-month"
    case .pastYear: return "past-year"
    case .allTime: return "all-time"
    case .custom:
      let start = startDate.map(Self.dateSlug) ?? "start"
      let end = endDate.map(Self.dateSlug) ?? "end"
      return "custom-\(start)-\(end)"
    }
  }

  var normalizedDateBounds: (sinceMs: Int64, untilMs: Int64)? {
    guard kind == .custom, let startDate, let endDate else { return nil }
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: min(startDate, endDate))
    let endDay = calendar.startOfDay(for: max(startDate, endDate))
    let nextDay = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
    let end = nextDay.addingTimeInterval(-0.001)
    return (
      Int64((start.timeIntervalSince1970 * 1000).rounded()),
      Int64((end.timeIntervalSince1970 * 1000).rounded())
    )
  }

  private static func dateSlug(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}

struct TextingAnalyticsCachedReport: Identifiable {
  let id: URL
  let url: URL
  let report: TextingAnalyticsReport
  let modifiedAt: Date

  var title: String { report.windowLabel ?? url.deletingPathExtension().lastPathComponent }

  var detail: String {
    let count = report.totalSent ?? 0
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return "\(Self.decimal(count)) sent · \(formatter.localizedString(for: modifiedAt, relativeTo: Date()))"
  }

  private static func decimal(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }
}

@MainActor
final class TextingAnalyticsController: ObservableObject {
  enum State {
    case idle
    case generating
    case done(report: TextingAnalyticsReport, jsonURL: URL)
    case failed(reason: String, fdaMissing: Bool)
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var cachedReports: [TextingAnalyticsCachedReport] = []

  private let binaryName = "texting-analytics-generator"

  init() {
    loadCache()
  }

  func generate(window: TextingAnalyticsWindow, includeNames: Bool, threadFilter: String = "", comparePrevious: Bool = false) {
    if case .generating = state { return }
    guard let binURL = resolveBinary() else {
      state = .failed(reason: "The analytics engine isn't bundled in this build yet.", fdaMissing: false)
      return
    }

    let outDir = Self.cacheDirectory

    state = .generating
    let startedAt = Date()
    AnalyticsClient.shared.safeCapture(.labScanStarted, properties: [
      .lab: .string(AnalyticsLab.textingAnalytics.rawValue)
    ])
    Task.detached(priority: .userInitiated) {
      do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let timestamp = Self.fileTimestampSlug(Date())
        let namesSlug = includeNames ? "names" : "anonymous"
        let filterSlug = Self.filterSlug(threadFilter)
        let compareSlug = comparePrevious ? "compare" : "single"
        let jsonURL = outDir.appendingPathComponent("texting-analytics-\(window.fileSlug)-\(namesSlug)-\(filterSlug)-\(compareSlug)-\(timestamp).json")
        try Self.run(binURL, args: Self.args(
          window: window,
          includeNames: includeNames,
          threadFilter: threadFilter,
          comparePrevious: comparePrevious,
          jsonURL: jsonURL
        ))
        let data = try Data(contentsOf: jsonURL)
        let report = try JSONDecoder().decode(TextingAnalyticsReport.self, from: data)
        await MainActor.run {
          self.state = .done(report: report, jsonURL: jsonURL)
          self.loadCache()
          AnalyticsClient.shared.safeCapture(.labScanCompleted, properties: [
            .lab: .string(AnalyticsLab.textingAnalytics.rawValue),
            .resultCountBucket: .string(AnalyticsClient.resultCountBucket(report.totalSent ?? 0)),
            .durationBucket: .string(AnalyticsClient.durationBucket(ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
          ])
        }
      } catch let e as GenError {
        await MainActor.run {
          self.state = .failed(reason: e.message, fdaMissing: e.fdaMissing)
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.textingAnalytics.rawValue),
            .errorCategory: .string(e.fdaMissing ? AnalyticsErrorCategory.fullDiskAccess.rawValue : AnalyticsErrorCategory.unknown.rawValue)
          ])
        }
      } catch {
        await MainActor.run {
          self.state = .failed(reason: error.localizedDescription, fdaMissing: false)
          AnalyticsClient.shared.safeCapture(.labScanFailed, properties: [
            .lab: .string(AnalyticsLab.textingAnalytics.rawValue),
            .errorCategory: .string(AnalyticsClient.errorCategory(error).rawValue)
          ])
        }
      }
    }
  }

  func loadOrGenerate(window: TextingAnalyticsWindow, includeNames: Bool, threadFilter: String = "", comparePrevious: Bool = false) {
    loadCache()
    if let cached = cachedReport(window: window, includeNames: includeNames, threadFilter: threadFilter, comparePrevious: comparePrevious) {
      openCached(cached)
    } else {
      generate(window: window, includeNames: includeNames, threadFilter: threadFilter, comparePrevious: comparePrevious)
    }
  }

  func reset() { state = .idle }

  func loadCache() {
    let dir = Self.cacheDirectory
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      cachedReports = []
      return
    }

    let decoder = JSONDecoder()
    cachedReports = urls
      .filter { $0.pathExtension.lowercased() == "json" }
      .compactMap { url -> TextingAnalyticsCachedReport? in
        guard
          let data = try? Data(contentsOf: url),
          let report = try? decoder.decode(TextingAnalyticsReport.self, from: data)
        else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values?.contentModificationDate
          ?? report.generatedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
          ?? .distantPast
        return TextingAnalyticsCachedReport(id: url, url: url, report: report, modifiedAt: modifiedAt)
      }
      .sorted { $0.modifiedAt > $1.modifiedAt }
  }

  func openCached(_ cached: TextingAnalyticsCachedReport) {
    state = .done(report: cached.report, jsonURL: cached.url)
  }

  private func cachedReport(window: TextingAnalyticsWindow, includeNames: Bool, threadFilter: String, comparePrevious: Bool) -> TextingAnalyticsCachedReport? {
    let namesSlug = includeNames ? "names" : "anonymous"
    let prefix = "texting-analytics-\(window.fileSlug)-\(namesSlug)-\(Self.filterSlug(threadFilter))-\(comparePrevious ? "compare" : "single")-"
    return cachedReports.first { $0.url.deletingPathExtension().lastPathComponent.hasPrefix(prefix) }
  }

  private struct GenError: Error { let message: String; let fdaMissing: Bool }

  nonisolated private static func args(
    window: TextingAnalyticsWindow,
    includeNames: Bool,
    threadFilter: String,
    comparePrevious: Bool,
    jsonURL: URL
  ) -> [String] {
    var out = ["--analytics-out", jsonURL.path, "--json-only"]
    switch window.kind {
    case .lastMonth:
      out += ["--window-days", "30"]
    case .pastYear:
      out += ["--window-days", "365"]
    case .allTime:
      out += ["--all-time"]
    case .custom:
      if let bounds = window.normalizedDateBounds {
        out += ["--since-ms", "\(bounds.sinceMs)", "--until-ms", "\(bounds.untilMs)"]
      } else {
        out += ["--window-days", "365"]
      }
    }
    if !includeNames { out.append("--no-people") }
    let trimmedFilter = threadFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedFilter.isEmpty {
      out += ["--thread-filter", trimmedFilter]
    }
    if comparePrevious {
      out.append("--compare-previous")
    }
    return out
  }

  nonisolated private static func filterSlug(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "all" }
    let safe = trimmed.lowercased().map { ch -> Character in
      if ch.isLetter || ch.isNumber { return ch }
      return "-"
    }
    let collapsed = String(safe).split(separator: "-").joined(separator: "-")
    return String(collapsed.prefix(40))
  }

  nonisolated private static func run(_ binURL: URL, args: [String]) throws {
    let proc = Process()
    proc.executableURL = binURL
    proc.arguments = args
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = FileHandle.nullDevice
    do {
      try proc.run()
    } catch {
      throw GenError(message: "Couldn't start the analytics engine: \(error.localizedDescription)", fdaMissing: false)
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      let stderr = String(data: errData, encoding: .utf8) ?? ""
      let fda = proc.terminationStatus == 3 || stderr.contains("chatdb_open_failed")
      let msg = fda
        ? "The analytics engine couldn't read your Messages database. Grant Full Disk Access in Settings, then try again."
        : "The analytics engine exited with an error (code \(proc.terminationStatus))."
      throw GenError(message: msg, fdaMissing: fda)
    }
  }

  private func resolveBinary() -> URL? {
    let bundle = Bundle.main.bundleURL
    let inBundle = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
    let sibling = bundle.deletingLastPathComponent().appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
    return nil
  }

  nonisolated private static var cacheDirectory: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent("Downloads")
      .appendingPathComponent("texting-analytics")
  }

  nonisolated private static func fileTimestampSlug(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d%02d%02d-%02d%02d%02d",
      parts.year ?? 0,
      parts.month ?? 0,
      parts.day ?? 0,
      parts.hour ?? 0,
      parts.minute ?? 0,
      parts.second ?? 0
    )
  }
}
