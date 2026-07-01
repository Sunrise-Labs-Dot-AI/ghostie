import AppKit
import Foundation

enum NotificationPreviewStyle: String, CaseIterable, Identifiable, Codable {
  case shortPreview = "short_preview"
  case threadOnly = "thread_only"
  case countOnly = "count_only"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .shortPreview: return "Short preview"
    case .threadOnly: return "Thread only"
    case .countOnly: return "Count only"
    }
  }
}

struct ThreadPreloadPolicy {
  static let defaultLimit = 8
  static let maxCacheEntries = 16
  static let ttl: TimeInterval = 10 * 60
  // Recent-window size for the transcript. Kept modest on purpose: a LazyVStack
  // bottom-snap estimates the height of every OFF-screen row, so a large window
  // makes the open land at the wrong point (the blank scrollback) and renders
  // slowly. Older messages page in on scroll-up (loadOlderMessages). Was 220.
  static let initialPageLimit = 60

  static func candidates(
    _ conversations: [MessageConversation],
    cache: [String: ThreadMessageCacheEntry],
    inFlight: Set<String>,
    now: Date = Date(),
    limit: Int = defaultLimit
  ) -> [MessageConversation] {
    conversations
      .prefix(limit)
      .filter { conversation in
        guard !inFlight.contains(conversation.id) else { return false }
        guard let cached = cache[conversation.id] else { return true }
        return !ThreadMessageCachePolicy.shouldReuse(
          platform: conversation.platform,
          cachedMessages: cached.messages,
          cachedLastMessageDate: cached.lastMessageDate,
          currentLastMessageDate: conversation.recent.lastMessageDate
        ) || cached.isExpired(now: now)
      }
  }
}

struct MessageCachePruningPolicy {
  static func pruned(
    _ cache: [String: ThreadMessageCacheEntry],
    now: Date = Date(),
    maxEntries: Int = ThreadPreloadPolicy.maxCacheEntries
  ) -> [String: ThreadMessageCacheEntry] {
    let fresh = cache.filter { !$0.value.isExpired(now: now) }
    guard fresh.count > maxEntries else { return fresh }
    return Dictionary(
      uniqueKeysWithValues: fresh
        .sorted { lhs, rhs in lhs.value.lastAccessedAt > rhs.value.lastAccessedAt }
        .prefix(maxEntries)
        .map { ($0.key, $0.value) }
    )
  }
}

struct TranscriptScrollPolicy {
  static func shouldTriggerTopHistoryLoader(initialBottomSnapCompleted: Bool) -> Bool {
    initialBottomSnapCompleted
  }

  static func restoreAnchorAfterPrepend(previousOldestVisibleID: String?) -> String? {
    previousOldestVisibleID
  }

  static func shouldSnapAfterDirectSendReconciliation(
    optimisticRemoved: Bool,
    messagesChanged: Bool
  ) -> Bool {
    optimisticRemoved || messagesChanged
  }
}

struct MessageNotificationPolicy {
  static let freshnessWindow: TimeInterval = 5 * 60

  static func shouldNotify(
    appIsActive: Bool,
    notificationsEnabled: Bool,
    message: ContextMessage,
    baselineDate: Date?,
    now: Date = Date()
  ) -> Bool {
    guard !appIsActive, notificationsEnabled, !message.from_me, let sentDate = message.sentDate else {
      return false
    }
    if let baselineDate, sentDate <= baselineDate { return false }
    return now.timeIntervalSince(sentDate) <= freshnessWindow
  }

  static func preview(
    style: NotificationPreviewStyle,
    conversationTitle: String,
    platform: Platform,
    messages: [ContextMessage]
  ) -> (title: String, body: String) {
    let platformLabel = platform.displayName
    switch style {
    case .shortPreview:
      let body = messages.first?.body?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (conversationTitle, body?.isEmpty == false ? body! : "New \(platformLabel) message")
    case .threadOnly:
      return (conversationTitle, "New \(platformLabel) message")
    case .countOnly:
      let count = max(messages.count, 1)
      return ("Ghostie", "\(count) new \(platformLabel) \(count == 1 ? "message" : "messages")")
    }
  }

  static func visibleForWorkPersonal(
    enabled: Bool,
    filter: WorkPersonalFilter,
    personLabel: WorkPersonalLabel?
  ) -> Bool {
    guard enabled else { return true }
    return WorkPersonalVisibility.conversationVisible(
      personLabel: personLabel ?? .unknown,
      messageLabels: [],
      filter: filter,
      proEnabled: false
    )
  }
}

/// App-level cache of the SQLite-loaded thread list — every page the user
/// has scrolled in, not just the first — so re-opening the Messages tab is an
/// in-memory merge that keeps the scroll depth instead of a fresh chat.db +
/// messages.db scan. `fingerprint` is a cheap staleness probe
/// (MAX(ROWID) / MAX(last_message_ts)) checked before any reload; a stale
/// cache refreshes the first page only and keeps the appended pages
/// (see ConversationPagingPolicy.refreshedThreads).
struct RecentThreadsCache {
  let threads: [RecentComposeThread]
  let fingerprint: String
  let includedWhatsApp: Bool
  let loadedAt: Date
}

/// One-shot deep link into the Messages tab's compose sheet, posted by another
/// pane (the Birthday lab's "Draft a scheduled text"). Consumed by MessagesPane,
/// which opens the compose sheet with the recipient preselected; a non-nil
/// `scheduledAt` selects Scheduled mode with that fire instant prefilled. The
/// body always starts EMPTY — the user writes the message themselves.
struct PendingComposeRequest: Equatable {
  let recipientHandle: String
  let recipientName: String?
  let scheduledAt: Date?
}

/// Conversation-list ordering for the Messages tab. Priority-first is the
/// default (agent/user-pinned threads float in a queue above recency);
/// recent is the pure Messages.app ordering.
enum MessagesSortOrder: String, CaseIterable, Identifiable {
  case priorityFirst
  case recent

  var id: String { rawValue }

  var title: String {
    switch self {
    case .priorityFirst: return "Priority"
    case .recent: return "Recent"
    }
  }
}

/// The pure rule behind the sort picker: priority-first floats the
/// ThreadPriorityPolicy queue (level, then recency) above the recency list;
/// recent is the untouched Messages.app ordering — priorities never float,
/// even when entries exist.
enum ConversationListOrderPolicy {
  static func ordered(
    _ conversations: [MessageConversation],
    sortOrder: MessagesSortOrder,
    priorityFor: (MessageConversation) -> ThreadPriorityEntry?
  ) -> [MessageConversation] {
    switch sortOrder {
    case .priorityFirst:
      let split = ThreadPriorityPolicy.partition(conversations, priorityFor: priorityFor)
      return split.priority + split.rest
    case .recent:
      return conversations
    }
  }
}

@MainActor
final class MessagesViewState: ObservableObject {
  @Published var lookback: MessageLookback = .sevenDays
  @Published var workPersonalFilter: WorkPersonalFilter = .all
  @Published var sortOrder: MessagesSortOrder = .priorityFirst
  @Published var selectedConversationID: String?

  /// One-shot deep link: select the conversation whose handle canonicalizes to
  /// one of these (the Birthday lab's "Open conversation"). Consumed by
  /// MessagesPane once its conversation list is loaded; a request that matches
  /// nobody is dropped (the person may simply have no recent thread).
  @Published var pendingConversationHandles: [String]?

  /// One-shot compose deep link (see `PendingComposeRequest`).
  @Published var pendingCompose: PendingComposeRequest?

  /// One-shot trigger for the blank "new message" composer (the sidebar compose
  /// shortcut next to Messages). MessagesPane consumes it and resets to false.
  @Published var pendingComposeNew = false

  @Published private(set) var messageCache: [String: ThreadMessageCacheEntry] = [:]
  @Published private(set) var inFlightPreloads: Set<String> = []

  /// In-app read state (see ConversationReadLedger): loaded once, saved on
  /// every mark — the file is a few KB and marks happen at human cadence.
  @Published private(set) var readLedger: ConversationReadLedger

  private var readLedgerFile: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("messages-read-state.json")
  }

  init() {
    if let data = try? Data(contentsOf: AppStoragePaths.homeDirectory
        .appendingPathComponent(".messages-mcp")
        .appendingPathComponent("messages-read-state.json")),
       let decoded = try? JSONDecoder().decode(ConversationReadLedger.self, from: data) {
      readLedger = decoded
    } else {
      readLedger = ConversationReadLedger()
    }
  }

  /// Marks the conversation — and every folded sibling — seen up to its
  /// newest message and persists. No-ops (no publish, no write) when the
  /// ledger already covers all of them.
  func markSeen(thread: RecentComposeThread) {
    let next = readLedger.markingSeen(thread: thread)
    guard next != readLedger else { return }
    readLedger = next
    persistReadLedger()
  }

  private func persistReadLedger() {
    let file = readLedgerFile
    guard let data = try? JSONEncoder().encode(readLedger) else { return }
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: file, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// Survives tab switches (this object is app-level), so re-opening the
  /// Messages tab renders instantly from the last loaded list while a
  /// freshness check runs in the background.
  var recentThreadsCache: RecentThreadsCache?

  /// Seed `recentThreadsCache` once at launch (background) so the first Messages
  /// open renders from a warm list instead of flashing the empty state during a
  /// cold chat.db read. No-op if a cache already exists (a live open beat us to
  /// it). Builds the SAME shape `reloadConversations` expects, so the first
  /// reload sees a hit and its fingerprint guard skips the redundant requery.
  func warmRecentThreadsCache(includeWhatsApp: Bool) {
    guard recentThreadsCache == nil else { return }
    Task.detached(priority: .utility) { [weak self] in
      let fingerprint = RecentComposeThread.dataFingerprint(includeWhatsApp: includeWhatsApp)
      let firstPage = RecentComposeThread.loadPage(before: nil, includeWhatsApp: includeWhatsApp)
      let threads = ConversationPagingPolicy.refreshedThreads(
        freshFirstPage: firstPage.threads,
        previous: []
      )
      await MainActor.run {
        guard let self, self.recentThreadsCache == nil else { return }
        self.recentThreadsCache = RecentThreadsCache(
          threads: threads,
          fingerprint: fingerprint,
          includedWhatsApp: includeWhatsApp,
          loadedAt: Date()
        )
      }
    }
  }

  func cachedMessages(for conversationID: String) -> ThreadMessageCacheEntry? {
    guard let entry = messageCache[conversationID], !entry.isExpired() else { return nil }
    return entry
  }

  func storeMessages(
    _ messages: [ContextMessage],
    for conversation: MessageConversation,
    loadedAllAvailableHistory: Bool
  ) {
    if ThreadMessageCachePolicy.shouldStore(platform: conversation.platform, messages: messages) {
      messageCache[conversation.id] = ThreadMessageCacheEntry(
        messages: messages,
        lastMessageDate: conversation.recent.lastMessageDate,
        hasLoadedAllAvailableHistory: loadedAllAvailableHistory,
        cachedAt: Date(),
        lastAccessedAt: Date()
      )
      pruneCache()
    } else {
      messageCache.removeValue(forKey: conversation.id)
    }
  }

  func removeCache(for conversationID: String) {
    messageCache.removeValue(forKey: conversationID)
  }

  func pruneCache(now: Date = Date()) {
    messageCache = MessageCachePruningPolicy.pruned(messageCache, now: now)
  }

  func preload(_ conversations: [MessageConversation]) {
    pruneCache()
    let targets = ThreadPreloadPolicy.candidates(
      conversations,
      cache: messageCache,
      inFlight: inFlightPreloads
    )
    guard !targets.isEmpty else { return }
    Task { [weak self] in
      await self?.preloadBatch(targets)
    }
  }

  private func preloadBatch(_ conversations: [MessageConversation]) async {
    for conversation in conversations {
      guard !inFlightPreloads.contains(conversation.id) else { continue }
      inFlightPreloads.insert(conversation.id)
      // Same loader the detail pane uses — a consolidated row's warm cache
      // must already be the cross-member union or the open thread would
      // flash a partial transcript.
      let loaded = (try? await conversation.recent.loadConsolidatedContext(
        limit: ThreadPreloadPolicy.initialPageLimit
      )) ?? []
      inFlightPreloads.remove(conversation.id)
      storeMessages(
        loaded,
        for: conversation,
        loadedAllAvailableHistory: loaded.count < ThreadPreloadPolicy.initialPageLimit
      )
    }
  }

  func clearCache() {
    messageCache.removeAll()
    inFlightPreloads.removeAll()
  }
}
