import SwiftUI
import SQLite3
import UniformTypeIdentifiers

enum InlineComposerNewlineAction {
  case submit
  case insertNewline

  static func action(shiftPressed: Bool) -> InlineComposerNewlineAction {
    shiftPressed ? .insertNewline : .submit
  }
}

enum InlineFailedDraftPolicy {
  static func reusableDraft(id: String?, drafts: [Draft], conversation: RecentComposeThread) -> Draft? {
    guard let id else { return nil }
    return drafts.first { draft in
      draft.id == id
        && !draft.isSent
        && !draft.isScheduled
        && matches(draft: draft, conversation: conversation)
    }
  }

  static func matches(draft: Draft, conversation: RecentComposeThread) -> Bool {
    guard draft.effectivePlatform == conversation.platform else { return false }
    switch conversation.platform {
    case .imessage:
      if let threadID = conversation.threadID {
        return draft.in_reply_to_thread_id == threadID
      }
      return canonicalHandle(draft.to_handle) == canonicalHandle(conversation.handle)
    case .whatsapp:
      return draft.to_handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == conversation.handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
  }

  private static func canonicalHandle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter(\.isNumber)
    return digits.isEmpty ? trimmed.lowercased() : String(digits.suffix(10))
  }
}

/// Drag payloads the conversation pane can turn into a composer attachment.
/// File URLs arrive first-class from Finder; raster data arrives from drags
/// with no on-disk file behind them (e.g. an image dragged out of a browser).
enum ComposerDropPayload: Equatable {
  case fileURL(URL)
  case imageData(Data)
}

enum ComposerDropPolicy {
  /// The composer holds a single attachment, so the first attachable payload
  /// wins. Web links (non-file URLs), folders, and empty data blobs can't be
  /// sent as files and never win.
  static func firstAttachable(in payloads: [ComposerDropPayload]) -> ComposerDropPayload? {
    payloads.first { payload in
      switch payload {
      case .fileURL(let url):
        return url.isFileURL && !url.hasDirectoryPath
      case .imageData(let data):
        return !data.isEmpty
      }
    }
  }

  /// loadDataRepresentation needs an identifier the drag source actually
  /// registered; PNG is preferred so the materialized .png temp file keeps an
  /// honest extension without a re-encode.
  static func imageTypeIdentifier(fromRegistered identifiers: [String]) -> String? {
    let imageTypes = identifiers.filter { UTType($0)?.conforms(to: .image) == true }
    return imageTypes.first { UTType($0)?.conforms(to: .png) == true } ?? imageTypes.first
  }
}

enum DroppedImageFile {
  static let directoryName = "messages-for-ai-drops"

  /// PNG signature sniff — already-PNG data skips the decode/re-encode pass.
  static func isPNG(_ data: Data) -> Bool {
    data.starts(with: [0x89, 0x50, 0x4E, 0x47])
  }

  /// The send path attaches by file URL only, so image DATA dragged from
  /// another app must be materialized as a real .png on disk first.
  static func write(_ data: Data) -> URL? {
    let pngData: Data
    if isPNG(data) {
      pngData = data
    } else if let bitmap = NSBitmapImageRep(data: data),
              let encoded = bitmap.representation(using: .png, properties: [:]) {
      pngData = encoded
    } else {
      return nil
    }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(directoryName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let fileURL = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
      try pngData.write(to: fileURL, options: .atomic)
      return fileURL
    } catch {
      return nil
    }
  }
}

/// Index-slotted, lock-guarded accumulator — NSItemProvider completion
/// handlers land on arbitrary queues and must not reorder the drag's items.
private final class DropPayloadCollector: @unchecked Sendable {
  private var slots: [ComposerDropPayload?]
  private let lock = NSLock()

  init(count: Int) {
    slots = Array(repeating: nil, count: count)
  }

  func store(_ payload: ComposerDropPayload, at index: Int) {
    lock.lock()
    slots[index] = payload
    lock.unlock()
  }

  func ordered() -> [ComposerDropPayload] {
    lock.lock()
    defer { lock.unlock() }
    return slots.compactMap { $0 }
  }
}

private enum MessageFormatters {
  static let relative: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  /// Messages.app's list-row date tiering: time today, "Yesterday", weekday
  /// inside a week, short date beyond.
  static func conversationRowDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(date) {
      let formatter = DateFormatter()
      formatter.timeStyle = .short
      formatter.dateStyle = .none
      return formatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let formatter = DateFormatter()
    if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
       date >= weekAgo {
      formatter.dateFormat = "EEEE"
    } else {
      formatter.dateStyle = .short
      formatter.timeStyle = .none
    }
    return formatter.string(from: date)
  }
}

enum MessageLookback: String, CaseIterable, Hashable, Identifiable {
  case threeDays
  case sevenDays
  case thirtyDays
  case ninetyDays
  case allTime

  var id: String { rawValue }

  var label: String {
    switch self {
    case .threeDays: return "3d"
    case .sevenDays: return "7d"
    case .thirtyDays: return "30d"
    case .ninetyDays: return "90d"
    case .allTime: return "All"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .threeDays: return "3 days"
    case .sevenDays: return "7 days"
    case .thirtyDays: return "30 days"
    case .ninetyDays: return "90 days"
    case .allTime: return "All time"
    }
  }

  var days: Int? {
    switch self {
    case .threeDays: return 3
    case .sevenDays: return 7
    case .thirtyDays: return 30
    case .ninetyDays: return 90
    case .allTime: return nil
    }
  }

  var cutoff: Date? {
    days.map { Date().addingTimeInterval(Double(-$0) * 86_400) }
  }
}

enum SenderLabelPolicy {
  static func shouldShowSender(
    isGroupConversation: Bool,
    message: ContextMessage,
    previous: ContextMessage?
  ) -> Bool {
    guard isGroupConversation, !message.from_me else { return false }
    return previous?.sender_handle != message.sender_handle
  }
}

struct ThreadMessageCacheEntry {
  let messages: [ContextMessage]
  let lastMessageDate: Date?
  let hasLoadedAllAvailableHistory: Bool
  let cachedAt: Date
  let lastAccessedAt: Date

  init(
    messages: [ContextMessage],
    lastMessageDate: Date?,
    hasLoadedAllAvailableHistory: Bool,
    cachedAt: Date = Date(),
    lastAccessedAt: Date = Date()
  ) {
    self.messages = messages
    self.lastMessageDate = lastMessageDate
    self.hasLoadedAllAvailableHistory = hasLoadedAllAvailableHistory
    self.cachedAt = cachedAt
    self.lastAccessedAt = lastAccessedAt
  }

  func isExpired(now: Date = Date(), ttl: TimeInterval = ThreadPreloadPolicy.ttl) -> Bool {
    now.timeIntervalSince(cachedAt) > ttl
  }

  func touch(now: Date = Date()) -> ThreadMessageCacheEntry {
    ThreadMessageCacheEntry(
      messages: messages,
      lastMessageDate: lastMessageDate,
      hasLoadedAllAvailableHistory: hasLoadedAllAvailableHistory,
      cachedAt: cachedAt,
      lastAccessedAt: now
    )
  }
}

enum ThreadMessageCachePolicy {
  static func shouldReuse(
    platform: Platform,
    cachedMessages: [ContextMessage],
    cachedLastMessageDate: Date?,
    currentLastMessageDate: Date?
  ) -> Bool {
    guard cachedLastMessageDate == currentLastMessageDate else { return false }
    if platform == .whatsapp, cachedMessages.isEmpty { return false }
    return true
  }

  static func shouldStore(platform: Platform, messages: [ContextMessage]) -> Bool {
    platform != .whatsapp || !messages.isEmpty
  }
}

enum ConversationSearchPolicy {
  static func filtered(_ conversations: [MessageConversation], query: String) -> [MessageConversation] {
    let terms = searchableText(query)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !terms.isEmpty else { return conversations }
    return conversations.filter { conversation in
      // Folded sibling handles stay searchable — typing the merged-away
      // email must still surface the consolidated row.
      let haystack = ([
        conversation.title,
        conversation.subtitle,
        conversation.recent.handle,
        conversation.recent.id,
        conversation.platform.displayName
      ] + conversation.recent.consolidatedSiblings.flatMap { [$0.handle, $0.id] })
        .joined(separator: " ")
      let searchable = searchableText(haystack)
      let compactSearchable = searchable.filter { !$0.isWhitespace }
      return terms.allSatisfy { term in
        searchable.contains(term) || compactSearchable.contains(term)
      }
    }
  }

  private static func searchableText(_ raw: String) -> String {
    raw
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .map { character in
        character.isLetter || character.isNumber || character.isWhitespace ? character : " "
      }
      .map(String.init)
      .joined()
  }
}

struct MessageConversation: Identifiable {
  let recent: RecentComposeThread
  let draftThread: DraftThread?

  var id: String { recent.id }
  var title: String { recent.title }
  var subtitle: String { recent.subtitle }
  var platform: Platform { recent.platform }
  var lastMessageDate: Date? { recent.lastMessageDate }
  var draftCount: Int { draftThread?.draftCount ?? 0 }
  var scheduledCount: Int { draftThread?.scheduledCount ?? 0 }
  var pendingCount: Int { draftCount + scheduledCount }

  static func load(lookback: MessageLookback, drafts: [Draft], includeWhatsApp: Bool) -> [MessageConversation] {
    let draftThreads = DraftThread.group(drafts.filter { !$0.isSent })
    let recents = RecentComposeThread.loadAll(includeWhatsApp: includeWhatsApp)
    return merge(lookback: lookback, draftThreads: draftThreads, recents: recents)
  }

  static func merge(
    lookback: MessageLookback,
    draftThreads: [DraftThread],
    recents: [RecentComposeThread],
    cutoff: Date? = nil
  ) -> [MessageConversation] {
    let cutoff = cutoff ?? lookback.cutoff
    let draftsByThreadKey = Dictionary(uniqueKeysWithValues: draftThreads.map { (messageKey(for: $0), $0) })
    let draftsByHandleKey = Dictionary(grouping: draftThreads, by: handleKey(for:))
      .compactMapValues { threads in
        threads.max { DraftThread.draftSortDate($0.newestDraft) < DraftThread.draftSortDate($1.newestDraft) }
      }
    var seen = Set<String>()
    var matchedDraftThreadIDs = Set<String>()

    let conversations = recents.compactMap { recent -> MessageConversation? in
      if let cutoff, (recent.lastMessageDate ?? .distantPast) < cutoff {
        return nil
      }
      let key = messageKey(for: recent)
      guard seen.insert(key).inserted else { return nil }
      // A consolidated row also claims drafts staged against any folded
      // sibling handle/thread, so an old-handle draft can't orphan into a
      // duplicate row.
      let draftThread = draftsByThreadKey[key]
        ?? draftsByHandleKey[handleKey(for: recent)]
        ?? recent.consolidatedSiblings.lazy.compactMap {
          draftsByThreadKey[messageKey(for: $0)] ?? draftsByHandleKey[handleKey(for: $0)]
        }.first
      if let draftThread {
        matchedDraftThreadIDs.insert(draftThread.id)
      }
      return MessageConversation(recent: recent, draftThread: draftThread)
    }

    let recentKeys = Set(conversations.flatMap { conversation in
      [messageKey(for: conversation.recent)]
        + conversation.recent.consolidatedSiblings.map { messageKey(for: $0) }
    })
    let orphanDraftConversations = draftThreads.compactMap { draftThread -> MessageConversation? in
      let key = messageKey(for: draftThread)
      guard !recentKeys.contains(key), !matchedDraftThreadIDs.contains(draftThread.id) else { return nil }
      let recent = RecentComposeThread(
        id: "draft-\(draftThread.id)",
        platform: draftThread.platform,
        handle: draftThread.toHandle,
        title: draftThread.displayName,
        subtitle: draftThread.subtitle,
        threadID: draftThread.newestDraft.in_reply_to_thread_id,
        lastMessageDate: draftThread.newestDraft.stagedDate
      )
      return MessageConversation(recent: recent, draftThread: draftThread)
    }

    let allConversations = conversations + orphanDraftConversations
    return allConversations.sorted { lhs, rhs in
      let left = lhs.lastMessageDate ?? Date.distantPast
      let right = rhs.lastMessageDate ?? Date.distantPast
      if left == right {
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
      return left > right
    }
  }

  private static func messageKey(for recent: RecentComposeThread) -> String {
    let threadPart = recent.threadID.map(String.init) ?? recent.handle.lowercased()
    return "\(recent.platform.rawValue)|\(threadPart)"
  }

  private static func messageKey(for thread: DraftThread) -> String {
    DraftThread.threadKey(thread.newestDraft)
  }

  private static func handleKey(for recent: RecentComposeThread) -> String {
    "\(recent.platform.rawValue)|\(recent.handle.lowercased())"
  }

  private static func handleKey(for thread: DraftThread) -> String {
    "\(thread.platform.rawValue)|\(thread.toHandle.lowercased())"
  }
}

struct MessageSendTarget: Equatable {
  let conversationID: String
  let platform: Platform
  let handle: String
  let displayName: String
  let recipientName: String?
  let threadID: Int?
  /// iMessage group chat id ("iMessage;+;chat…") — when set, direct sends
  /// target the chat instead of a single buddy.
  let imessageChatGUID: String?

  init(conversation: MessageConversation) {
    // For a consolidated row this is the NEWEST member's recipient — sends
    // go to the newest handle's thread, the one the row represents, never
    // to a folded sibling.
    let recipient = conversation.recent.recipient
    self.conversationID = conversation.id
    self.platform = conversation.platform
    self.handle = recipient.handle
    self.displayName = recipient.title
    self.recipientName = recipient.name
    self.threadID = recipient.threadID
    // Group OR 1:1: the chat GUID's prefix encodes the service (iMessage/SMS/RCS),
    // so direct sends target `chat id` and route through the thread's real
    // transport — guessing iMessage via buddy targeting silently fails for
    // SMS-only contacts.
    self.imessageChatGUID = conversation.recent.platform == .imessage
      ? conversation.recent.chatGUID
      : nil
  }

  func isCurrent(conversationID currentConversationID: String) -> Bool {
    conversationID == currentConversationID
  }
}

enum OptimisticDirectMessageState: Equatable {
  case sending
  case sent
  case failed
}

struct OptimisticDirectMessage: Identifiable, Equatable {
  let id: String
  let target: MessageSendTarget
  let body: String
  let createdAt: Date
  var state: OptimisticDirectMessageState
  var errorMessage: String?
}

enum OptimisticDirectMessageReconciler {
  static func transcriptContains(_ optimistic: OptimisticDirectMessage, transcript: [ContextMessage]) -> Bool {
    let body = optimistic.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return false }
    let earliestLikelySendTime = optimistic.createdAt.addingTimeInterval(-120)
    return transcript.contains { message in
      guard message.from_me,
            message.body?.trimmingCharacters(in: .whitespacesAndNewlines) == body else {
        return false
      }
      guard let sentDate = message.sentDate else { return true }
      return sentDate >= earliestLikelySendTime
    }
  }

  static func unreconciled(
    optimisticMessages: [OptimisticDirectMessage],
    transcript: [ContextMessage]
  ) -> [OptimisticDirectMessage] {
    optimisticMessages.filter { !transcriptContains($0, transcript: transcript) }
  }
}

enum DirectSendTranscriptReconciler {
  struct Result: Equatable {
    let shouldApply: Bool
    let messages: [ContextMessage]
    let optimisticMessages: [OptimisticDirectMessage]
    let isSettled: Bool
    let shouldSnapToBottom: Bool
  }

  static func reconcile(
    currentMessages: [ContextMessage],
    optimisticMessages: [OptimisticDirectMessage],
    loadedMessages: [ContextMessage],
    optimisticID: String
  ) -> Result {
    guard !loadedMessages.isEmpty,
          let optimistic = optimisticMessages.first(where: { $0.id == optimisticID }),
          shouldApply(
            currentMessages: currentMessages,
            loadedMessages: loadedMessages,
            optimistic: optimistic
          ) else {
      return Result(
        shouldApply: false,
        messages: currentMessages,
        optimisticMessages: optimisticMessages,
        isSettled: false,
        shouldSnapToBottom: false
      )
    }

    let merged = mergeChronologicalMessages(currentMessages + loadedMessages)
    let nextOptimisticMessages = OptimisticDirectMessageReconciler.unreconciled(
      optimisticMessages: optimisticMessages,
      transcript: merged
    )
    let optimisticRemoved = optimisticMessages.contains(where: { $0.id == optimisticID })
      && !nextOptimisticMessages.contains(where: { $0.id == optimisticID })
    let messagesChanged = merged.map(\.transcriptStableID) != currentMessages.map(\.transcriptStableID)
    return Result(
      shouldApply: true,
      messages: merged,
      optimisticMessages: nextOptimisticMessages,
      isSettled: optimisticRemoved,
      shouldSnapToBottom: TranscriptScrollPolicy.shouldSnapAfterDirectSendReconciliation(
        optimisticRemoved: optimisticRemoved,
        messagesChanged: messagesChanged
      )
    )
  }

  static func mergeChronologicalMessages(_ source: [ContextMessage]) -> [ContextMessage] {
    var seen = Set<String>()
    return source
      .sorted { lhs, rhs in
        (lhs.sentDate ?? .distantPast) < (rhs.sentDate ?? .distantPast)
      }
      .filter { message in
        seen.insert(message.transcriptStableID).inserted
      }
  }

  private static func shouldApply(
    currentMessages: [ContextMessage],
    loadedMessages: [ContextMessage],
    optimistic: OptimisticDirectMessage
  ) -> Bool {
    if OptimisticDirectMessageReconciler.transcriptContains(optimistic, transcript: loadedMessages) {
      return true
    }
    guard let loadedNewest = newestDate(in: loadedMessages) else { return false }
    guard let currentNewest = newestDate(in: currentMessages) else { return true }
    return loadedNewest > currentNewest
  }

  private static func newestDate(in messages: [ContextMessage]) -> Date? {
    messages.compactMap(\.sentDate).max()
  }
}

/// Decides which message (if any) shows a delivery receipt — Messages.app
/// shows "Delivered" / "Read 2:14 PM" under the most recent outgoing
/// iMessage; WhatsApp shows its ticks under the most recent outgoing message.
enum TranscriptReceiptPolicy {
  static func receipt(
    messages: [ContextMessage],
    platform: Platform
  ) -> (id: String, receipt: BubbleReceipt)? {
    guard let last = messages.last(where: { $0.from_me }) else { return nil }
    switch platform {
    case .whatsapp:
      return (last.transcriptStableID, .whatsappTicks)
    case .imessage:
      if let readAt = last.readAt {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(readAt) ? .none : .short
        return (last.transcriptStableID, .text("Read \(formatter.string(from: readAt))"))
      }
      if last.deliveredAt != nil {
        return (last.transcriptStableID, .text("Delivered"))
      }
      return nil
    }
  }
}

/// Canonical-handle conversation matching, shared by the Messages tab's
/// BirthdayNudge row and the Birthday lab's "Open conversation" deep link:
/// a birthday person's handles → the first conversation whose handle
/// canonicalizes to one of them.
enum ConversationHandleMatcher {
  static func match(handles: [String], in conversations: [MessageConversation]) -> MessageConversation? {
    let keys = Set(handles.compactMap(ContactAvatarStore.canonicalKey))
    guard !keys.isEmpty else { return nil }
    // Member handles, not just the row's own — a deep link by the
    // merged-away handle must land on the consolidated row.
    return conversations.first { conversation in
      !keys.isDisjoint(with: conversation.recent.canonicalHandleKeys)
    }
  }

  /// Same match against raw threads (the all-time database sweep) — used when
  /// a deep-linked person isn't in the loaded pages.
  static func matchThread(handles: [String], in threads: [RecentComposeThread]) -> RecentComposeThread? {
    let keys = Set(handles.compactMap(ContactAvatarStore.canonicalKey))
    guard !keys.isEmpty else { return nil }
    return threads.first { !keys.isDisjoint(with: $0.canonicalHandleKeys) }
  }
}

/// Console > Messages. A read-only conversation surface that follows the shape
/// of Messages.app: recent conversations on the left, a transcript on the right.
/// The list is ALL-TIME — it pages in older conversations as the user scrolls,
/// and search reaches the databases for threads not yet paged in.
struct MessagesPane: View {
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var workPersonal: WorkPersonalStore
  @EnvironmentObject var messagesViewState: MessagesViewState
  @EnvironmentObject var threadPriorities: ThreadPriorityStore
  @EnvironmentObject var birthdayGenerator: BirthdayGeneratorController
  @EnvironmentObject var nav: ConsoleNavigation
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var conversations: [MessageConversation] = []
  /// False until the first conversation load (cache or chat.db) lands — drives a
  /// cold-start list skeleton instead of flashing the empty state on a true cold
  /// open (no warm cache). Warm cache flips it ~instantly, so the skeleton only
  /// shows when there's a real wait.
  @State private var conversationsEverLoaded = false
  /// Prioritized threads (Keep Tabs / Don't Ghost) that have drifted out of the
  /// recent window — loaded by chat ROWID so the priority queue can float them
  /// even when they're not in the recent page. Merged into the base list below.
  @State private var pinnedPriorityConversations: [MessageConversation] = []
  @State private var showingCompose = false
  // Initial state for a deep-linked compose (the Birthday lab's "Draft a
  // scheduled text"); the staging composer opens preconfigured, separate
  // from the iMessage-parity recipient picker on showingCompose.
  @State private var showingScheduledCompose = false
  @State private var composeInitialRecipient: ComposeRecipient?
  @State private var composeInitialMode: ComposeMode = .draft
  @State private var composeInitialDate: Date?
  @State private var conversationLoadToken = UUID()
  @State private var conversationSearch = ""
  /// Pager frontier. `hasMore` starts true (the safe default after a tab
  /// re-entry restores a cached page set); one empty fetch corrects it.
  @State private var hasMoreConversationPages = true
  @State private var isLoadingNextConversationPage = false
  /// Debounced DB-wide search hits — threads matching the query that the
  /// pager hasn't loaded yet. Empty whenever the query is under the minimum.
  @State private var databaseSearchResults: [RecentComposeThread] = []
  @State private var databaseSearchTask: Task<Void, Never>?
  @StateObject private var liveRefresh = MessagesLiveRefresh()
  /// Handle → unified-contact map driving same-person row consolidation;
  /// resolutions land asynchronously and re-fold the list via onChange.
  @StateObject private var contactIdentities = ContactIdentityStore()
  /// Per-occurrence dismissals, comma-separated occurrence IDs (multiple
  /// birthdays can be open at once, so this is a set, not a single id).
  @AppStorage("messagesBirthdayNudgeDismissed") private var dismissedBirthdayNudgeCSV = ""
  @AppStorage("messagesHideBusinessThreads") private var hideBusinessThreads = false
  @AppStorage("messagesCompact") private var compactMode = false
  @FocusState private var searchFocused: Bool
  /// A just-composed thread that doesn't exist in chat.db yet: pinned to the
  /// top until the first send makes it real (live refresh then swaps the
  /// selection onto the real conversation by handle).
  @State private var pendingNewThread: RecentComposeThread?
  @State private var showingShortcuts = false

  private var selectedConversation: MessageConversation? {
    let id = messagesViewState.selectedConversationID ?? displayedConversations.first?.id
    return displayedConversations.first(where: { $0.id == id }) ?? displayedConversations.first
  }

  /// Loaded rows filtered by the typed query, unioned with the debounced
  /// DB-wide search hits (threads the pager hasn't reached), recency-ordered.
  private var searchedConversations: [MessageConversation] {
    let filtered = ConversationSearchPolicy.filtered(businessFilteredConversations, query: conversationSearch)
    guard isSearchingConversations, !databaseSearchResults.isEmpty else { return filtered }
    // DB hits fold the same way the loaded list does, so a search can't
    // resurrect a person's threads as separate rows.
    let visibleExtras = ConversationConsolidationPolicy.merge(
      threads: databaseSearchResults,
      identities: contactIdentities.identifiers
    ).filter { thread in
      if workPersonal.enabled, !WorkPersonalVisibility.conversationVisible(
        personLabel: workPersonal.personLabel(for: thread),
        messageLabels: [],
        filter: messagesViewState.workPersonalFilter,
        proEnabled: false
      ) { return false }
      if hideBusinessThreads, BusinessFilter.looksLikeBusiness(handle: thread.handle, name: thread.title) {
        return false
      }
      return true
    }
    return ConversationSearchMergePolicy.merge(loadedMatches: filtered, databaseMatches: visibleExtras)
  }

  /// Priority-tagged conversations (agent- or user-set) float to a queue above
  /// the recency list, ordered by level then recency.
  private var priorityPartition: (priority: [MessageConversation], rest: [MessageConversation]) {
    ThreadPriorityPolicy.partition(searchedConversations) { threadPriorities.priority(for: $0.recent) }
  }

  private var displayedConversations: [MessageConversation] {
    var list = ConversationListOrderPolicy.ordered(
      searchedConversations,
      sortOrder: messagesViewState.sortOrder,
      priorityFor: { threadPriorities.priority(for: $0.recent) }
    )
    if let pendingNewThread,
       !list.contains(where: { $0.recent.sharesHandle(with: pendingNewThread) }) {
      list.insert(MessageConversation(recent: pendingNewThread, draftThread: nil), at: 0)
    }
    return list
  }

  /// The loaded recent conversations plus any prioritized-but-drifted threads
  /// (deduped by id), so the priority queue surfaces them even when they're old.
  /// Only in Priority mode — Recent is pure recency of the loaded page and must
  /// not pull in old prioritized threads.
  private var baseConversations: [MessageConversation] {
    guard messagesViewState.sortOrder == .priorityFirst,
          !pinnedPriorityConversations.isEmpty else { return conversations }
    let present = Set(conversations.map(\.id))
    return conversations + pinnedPriorityConversations.filter { !present.contains($0.id) }
  }

  private var workPersonalFilteredConversations: [MessageConversation] {
    guard workPersonal.enabled else { return baseConversations }
    return baseConversations.filter { conversation in
      WorkPersonalVisibility.conversationVisible(
        personLabel: workPersonal.personLabel(for: conversation.recent),
        messageLabels: [],
        filter: messagesViewState.workPersonalFilter,
        proEnabled: false
      )
    }
  }

  private var businessFilteredConversations: [MessageConversation] {
    guard hideBusinessThreads else { return workPersonalFilteredConversations }
    return workPersonalFilteredConversations.filter { conversation in
      !BusinessFilter.looksLikeBusiness(
        handle: conversation.recent.handle,
        name: conversation.recent.title
      )
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      conversationColumn
        .frame(minWidth: 300, idealWidth: 348, maxWidth: 380)

      Rectangle()
        .fill(DS.Color.line(colorScheme))
        .frame(width: 1)

      if let conversation = selectedConversation {
        MessageConversationDetail(
          conversation: conversation,
          workPersonalFilter: workPersonal.enabled ? messagesViewState.workPersonalFilter : .all,
          cachedMessages: messagesViewState.cachedMessages(for: conversation.id),
          onMessagesLoaded: { messages, loadedAllAvailableHistory in
            messagesViewState.storeMessages(messages, for: conversation, loadedAllAvailableHistory: loadedAllAvailableHistory)
          }
        )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .id(conversation.id)
      } else {
        ScrollView {
          emptyState
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(DS.Color.g100(colorScheme))
    .sheet(isPresented: $showingCompose) {
      MessagesComposePicker(
        conversations: conversations,
        onPick: { pick in
          showingCompose = false
          handleComposePick(pick)
        }
      )
      .frame(width: 420, height: 480)
    }
    // Scheduled-compose deep link (Birthday lab → "Draft a scheduled text"):
    // the staging composer, preconfigured, with an EMPTY body.
    .sheet(isPresented: $showingScheduledCompose, onDismiss: { resetComposeDeepLink() }) {
      GlobalComposeSheet(
        activeThreads: DraftThread.group(store.drafts.filter { !$0.isSent }),
        initialRecipient: composeInitialRecipient,
        initialMode: composeInitialMode,
        initialDate: composeInitialDate
      ) { draft in
        messagesViewState.selectedConversationID = "draft-\(DraftThread.threadKey(draft))"
        reloadConversations()
      }
        .environmentObject(store)
        .environmentObject(settings)
        .frame(width: 560, height: 640)
    }
    .sheet(isPresented: $showingShortcuts) {
      MessagesShortcutsOverlay()
        .frame(width: 380)
    }
    .background(messagesShortcutHandlers)
    .onAppear {
      reloadConversations()
      liveRefresh.onChange = { reloadConversations() }
      liveRefresh.start(includeWhatsApp: settings.whatsappEnabled)
      birthdayGenerator.loadIfNeeded(windowDays: 7)
      consumePendingCompose()
      consumePendingComposeNew()
      refreshPinnedPriorities()
    }
    .onChange(of: prioritizedIMessageKey) { _, _ in
      refreshPinnedPriorities()
    }
    .onDisappear {
      liveRefresh.stop()
      databaseSearchTask?.cancel()
    }
    // Displaying a thread reads it: clear the in-app unread dot for the
    // selection, and again whenever the open thread's newest message moves
    // (it's on screen — the user is looking at it).
    .onChange(of: messagesViewState.selectedConversationID) { _, _ in
      markSelectedConversationSeen()
    }
    .onChange(of: selectedConversation?.recent.lastMessageDate) { _, _ in
      markSelectedConversationSeen()
    }
    .onChange(of: messagesViewState.pendingCompose) { _, _ in
      consumePendingCompose()
    }
    .onChange(of: messagesViewState.pendingComposeNew) { _, _ in
      consumePendingComposeNew()
    }
    .onChange(of: messagesViewState.pendingConversationHandles) { _, _ in
      consumePendingConversationSelection()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      reloadConversations()
    }
    .onChange(of: conversationSearch) { _, query in
      ensureSelectedConversationVisible()
      messagesViewState.preload(displayedConversations)
      scheduleDatabaseSearch(query)
    }
    .onChange(of: settings.whatsappEnabled) { _, _ in
      liveRefresh.start(includeWhatsApp: settings.whatsappEnabled)
      reloadConversations()
    }
    .onChange(of: store.drafts.map { "\($0.id)-\($0.sent_at ?? "")-\($0.scheduled_send_at ?? "")" }) { _, _ in
      reloadConversations()
    }
    // A freshly resolved contact identity can fold rows that were separate
    // a moment ago — re-fold the loaded list in memory, no database reads.
    .onChange(of: contactIdentities.identifiers) { _, _ in
      reapplyConsolidation()
    }
  }

  private var conversationColumn: some View {
    VStack(spacing: 0) {
      header
        .fullDiskAccessGate(toolName: "Messages")
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)

      ContactsPermissionBanner()
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

      let nudges = currentBirthdayNudges
      if !nudges.isEmpty {
        VStack(spacing: 6) {
          ForEach(nudges) { nudge in
            BirthdayNudgeRow(
              birthday: nudge,
              onOpen: { openBirthdayConversation(nudge) },
              onDismiss: {
                animate(.easeInOut(duration: 0.14)) {
                  dismissBirthdayNudge(nudge)
                }
              }
            )
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
      }

      Rectangle()
        .fill(DS.Color.line(colorScheme))
        .frame(height: 1)

      if displayedConversations.isEmpty {
        if !conversationsEverLoaded && !isSearchingConversations {
          conversationListSkeleton
        } else {
          ScrollView {
            emptyState
              .padding(24)
          }
        }
      } else {
        conversationList
      }
    }
    .background(DS.Color.g080(colorScheme))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Messages")
            .font(DS.Font.paneTitle)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text("Active conversations from your message history.")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        Spacer()
        Button {
          showingCompose = true
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .dsIconButton(.secondary)
        .help("Compose")
        .accessibilityLabel("Compose")
      }

      HStack(spacing: 6) {
        MessageFilterChip(
          title: messagesViewState.sortOrder.title,
          systemImage: "arrow.up.arrow.down",
          accessibilityLabel: "Sort conversations"
        ) {
          ForEach(MessagesSortOrder.allCases) { option in
            Button {
              messagesViewState.sortOrder = option
            } label: {
              if messagesViewState.sortOrder == option {
                Label(option.title, systemImage: "checkmark")
              } else {
                Text(option.title)
              }
            }
          }
        }

        if workPersonal.enabled {
          MessageFilterChip(
            title: messagesViewState.workPersonalFilter.title,
            // The severed self: innie on one side, outie on the other.
            systemImage: "circle.lefthalf.filled",
            accessibilityLabel: "Severance filter"
          ) {
            ForEach(WorkPersonalFilter.allCases) { option in
              Button {
                messagesViewState.workPersonalFilter = option
              } label: {
                if messagesViewState.workPersonalFilter == option {
                  Label(option.title, systemImage: "checkmark")
                } else {
                  Text(option.title)
                }
              }
            }
          }
        }

        FilterToggleChip(
          systemImage: "briefcase",
          isOn: hideBusinessThreads,
          isSlashed: hideBusinessThreads
        ) { hideBusinessThreads.toggle() }
        .help(hideBusinessThreads ? "Hiding business threads — click to show all" : "Hide business threads")
        .accessibilityLabel("Business filter")
        .accessibilityValue(hideBusinessThreads ? "On" : "Off")

        FilterToggleChip(
          label: "Compact",
          systemImage: compactMode ? "list.bullet" : "list.dash",
          isOn: compactMode
        ) { compactMode.toggle() }
        .help(compactMode ? "Compact view — click to expand" : "Expand view — click to compact")
        .accessibilityLabel("Compact mode")
        .accessibilityValue(compactMode ? "On" : "Off")

        Spacer(minLength: 0)
      }

      conversationSearchField
    }
  }

  private var conversationSearchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DS.Color.ink3(colorScheme))
      TextField("Search", text: $conversationSearch)
        .textFieldStyle(.plain)
        .font(DS.Font.navLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
        .focused($searchFocused)
      if !conversationSearch.isEmpty {
        Button {
          conversationSearch = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear conversation search")
      }
    }
    .padding(.horizontal, DS.Space.s)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .fill(DS.Color.g050(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .strokeBorder(searchFocused ? DS.Color.line2(colorScheme) : .clear, lineWidth: 1)
    )
  }

  // Cold-start placeholder: greyed rows so a true cold open (no warm cache) shows
  // list structure instead of the empty state while chat.db is read.
  private var conversationListSkeleton: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(0..<7, id: \.self) { _ in
          HStack(spacing: 10) {
            Circle()
              .fill(DS.Color.line(colorScheme))
              .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 6) {
              RoundedRectangle(cornerRadius: 4)
                .fill(DS.Color.line(colorScheme))
                .frame(width: 150, height: 11)
              RoundedRectangle(cornerRadius: 4)
                .fill(DS.Color.line(colorScheme).opacity(0.7))
                .frame(width: 210, height: 9)
            }
            Spacer(minLength: 0)
          }
          .padding(.vertical, 8)
          .padding(.horizontal, 10)
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 12)
    }
    // Collapse the placeholder shapes into one element so VoiceOver lands on the
    // "Loading conversations" label instead of navigating the skeleton circles.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading conversations")
  }

  private var conversationList: some View {
    // Recent mode is a flat recency list — no floated priority section. Priority
    // mode splits into the PRIORITY queue + the rest.
    let split: (priority: [MessageConversation], rest: [MessageConversation]) =
      messagesViewState.sortOrder == .priorityFirst
        ? priorityPartition
        : (priority: [], rest: displayedConversations)
    // LazyVStack is load-bearing: row .onAppear is the infinite-scroll
    // sentinel, so rows must materialize only as they scroll into view.
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if !split.priority.isEmpty {
          conversationSectionLabel("PRIORITY", topPadding: 12)
          ForEach(split.priority) { conversation in
            conversationRowButton(conversation)
          }
        }
        if !split.rest.isEmpty {
          conversationSectionLabel(
            split.priority.isEmpty ? "ACTIVE" : "RECENT",
            topPadding: split.priority.isEmpty ? 12 : 18
          )
          ForEach(split.rest) { conversation in
            conversationRowButton(conversation)
          }
        }
        if isLoadingNextConversationPage {
          conversationPageLoadingRow
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 16)
    }
  }

  private var conversationPageLoadingRow: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading older conversations…")
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .accessibilityLabel("Loading older conversations")
  }

  private func conversationSectionLabel(_ title: String, topPadding: CGFloat) -> some View {
    Text(title)
      .font(DS.Font.sectionLabel)
      .tracking(0.6)
      .foregroundStyle(DS.Color.ink3(colorScheme))
      .padding(.horizontal, 10)
      .padding(.top, topPadding)
      .padding(.bottom, 6)
  }

  private func conversationRowButton(_ conversation: MessageConversation) -> some View {
    let currentPriority = threadPriorities.priority(for: conversation.recent)
    return Button {
      animate(.easeInOut(duration: 0.14)) {
        messagesViewState.selectedConversationID = conversation.id
      }
    } label: {
      MessageConversationRow(
        conversation: conversation,
        selected: selectedConversation?.id == conversation.id,
        isUnread: isUnread(conversation),
        label: workPersonal.enabled ? workPersonal.personLabel(for: conversation.recent) : nil,
        priority: currentPriority,
        compact: compactMode
      )
    }
    .buttonStyle(.plain)
    .onAppear { handleConversationRowAppear(conversation) }
    .contextMenu {
      Menu("Priority") {
        ForEach(ThreadPriorityLevel.allCases) { level in
          Button {
            threadPriorities.setPriority(level, for: conversation.recent)
          } label: {
            if currentPriority?.level == level.rawValue {
              Label(level.title, systemImage: "checkmark")
            } else {
              Text(level.title)
            }
          }
        }
        if currentPriority != nil {
          Divider()
          Button("Clear Priority") {
            threadPriorities.clearPriority(for: conversation.recent)
          }
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 34))
        .foregroundStyle(.tertiary)
      Text(isSearchingConversations ? "No matching conversations" : "No active conversations")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text(isSearchingConversations ? "Try a name, number, group, or service." : "Start a new draft to begin a conversation.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.center)
      Button {
        showingCompose = true
      } label: {
        Label("Compose", systemImage: "square.and.pencil")
      }
      .dsButton(.primary, size: .small)
    }
    .frame(maxWidth: .infinity, minHeight: 320)
  }

  private var isSearchingConversations: Bool {
    !conversationSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Two-tier reload: render instantly from the app-level thread cache (an
  /// in-memory merge with the current drafts), then verify freshness in the
  /// background with a cheap fingerprint probe. When something changed, only
  /// the FIRST page is re-read and unioned over the already-loaded pages
  /// (fresh rows win the dedupe) — appended pages survive a live refresh
  /// without a re-scan, and the scroll position never jumps. Draft changes
  /// never touch the database.
  /// Stable signature of the prioritized iMessage thread set — drives the pinned
  /// reload when a lab (Keep Tabs / Don't Ghost) adds or clears a priority.
  private var prioritizedIMessageKey: String {
    threadPriorities.imessage.keys.sorted().joined(separator: ",")
  }

  /// Load the prioritized iMessage threads by ROWID so the priority queue can
  /// float them even when they've drifted out of the recent window (the whole
  /// point of Keep Tabs: resurface people you've gone quiet with). The recent
  /// page already carries any that are recent; `baseConversations` dedupes.
  private func refreshPinnedPriorities() {
    let ids = threadPriorities.imessage.keys.compactMap(Int.init)
    guard !ids.isEmpty else {
      if !pinnedPriorityConversations.isEmpty { pinnedPriorityConversations = [] }
      return
    }
    let identities = contactIdentities.identifiers
    DispatchQueue.global(qos: .userInitiated).async {
      let threads = RecentComposeThread.loadIMessageThreads(chatIDs: ids)
      let consolidated = ConversationConsolidationPolicy.merge(threads: threads, identities: identities)
      let convos = consolidated.map { MessageConversation(recent: $0, draftThread: nil) }
      DispatchQueue.main.async {
        pinnedPriorityConversations = convos
      }
    }
  }

  private func reloadConversations(forceRefresh: Bool = false) {
    let token = UUID()
    conversationLoadToken = token
    let draftThreads = DraftThread.group(store.drafts.filter { !$0.isSent })
    let includeWhatsApp = settings.whatsappEnabled

    // Snapshot for the background block: consolidation off-main works from
    // a value copy, never the MainActor store.
    let identities = contactIdentities.identifiers

    let cache = messagesViewState.recentThreadsCache
    let usableCache = cache?.includedWhatsApp == includeWhatsApp ? cache : nil
    if let usableCache {
      applyConversations(
        MessageConversation.merge(
          lookback: .allTime,
          draftThreads: draftThreads,
          recents: ConversationConsolidationPolicy.merge(threads: usableCache.threads, identities: identities)
        )
      )
    }
    let cachedFingerprint = usableCache?.fingerprint
    let previousThreads = usableCache?.threads ?? []

    DispatchQueue.global(qos: .userInitiated).async {
      let fingerprint = RecentComposeThread.dataFingerprint(includeWhatsApp: includeWhatsApp)
      if !forceRefresh, let cachedFingerprint, cachedFingerprint == fingerprint {
        return
      }
      let firstPage = RecentComposeThread.loadPage(before: nil, includeWhatsApp: includeWhatsApp)
      let threads = ConversationPagingPolicy.refreshedThreads(
        freshFirstPage: firstPage.threads,
        previous: previousThreads
      )
      // Consolidate AFTER page assembly, rendered list only — the cache
      // keeps the raw rows so pagination cursors stay correct.
      let merged = MessageConversation.merge(
        lookback: .allTime,
        draftThreads: draftThreads,
        recents: ConversationConsolidationPolicy.merge(threads: threads, identities: identities)
      )
      DispatchQueue.main.async {
        guard conversationLoadToken == token else { return }
        messagesViewState.recentThreadsCache = RecentThreadsCache(
          threads: threads,
          fingerprint: fingerprint,
          includedWhatsApp: includeWhatsApp,
          loadedAt: Date()
        )
        // The first page's frontier only stands when nothing has been
        // appended yet; afterwards the pager's own state is authoritative.
        if previousThreads.count <= ConversationPagingPolicy.pageSize {
          hasMoreConversationPages = firstPage.hasMore
        }
        applyConversations(merged)
      }
    }
  }

  /// Fetch the page strictly older than the oldest loaded conversation and
  /// append it (existing rows win the dedupe). The appended set becomes the
  /// new cached thread list, so tab re-entry keeps the scroll depth.
  private func loadNextConversationPage() {
    guard !isLoadingNextConversationPage, hasMoreConversationPages else { return }
    // Pagination anchors on the SQLite-loaded thread set, never the merged
    // conversation list — orphan draft rows carry staged dates that would
    // poison the cursor. No cache yet means the first load hasn't landed.
    guard let cache = messagesViewState.recentThreadsCache,
          cache.includedWhatsApp == settings.whatsappEnabled else { return }
    let loaded = cache.threads
    guard let cursor = ConversationPagingPolicy.nextCursor(loadedThreads: loaded) else { return }
    isLoadingNextConversationPage = true
    let includeWhatsApp = settings.whatsappEnabled
    let draftThreads = DraftThread.group(store.drafts.filter { !$0.isSent })
    let identities = contactIdentities.identifiers
    DispatchQueue.global(qos: .userInitiated).async {
      let page = RecentComposeThread.loadPage(before: cursor, includeWhatsApp: includeWhatsApp)
      DispatchQueue.main.async {
        isLoadingNextConversationPage = false
        hasMoreConversationPages = page.hasMore
        // Re-read the cache at completion: a live refresh may have replaced
        // the first page while this fetch was in flight.
        let current = messagesViewState.recentThreadsCache
        let base = (current?.includedWhatsApp == includeWhatsApp ? current?.threads : nil) ?? loaded
        let threads = ConversationPagingPolicy.appendingPage(page.threads, to: base)
        messagesViewState.recentThreadsCache = RecentThreadsCache(
          threads: threads,
          fingerprint: current?.fingerprint ?? "",
          includedWhatsApp: includeWhatsApp,
          loadedAt: current?.loadedAt ?? Date()
        )
        applyConversations(
          MessageConversation.merge(
            lookback: .allTime,
            draftThreads: draftThreads,
            recents: ConversationConsolidationPolicy.merge(threads: threads, identities: identities)
          )
        )
      }
    }
  }

  /// Re-fold the already-loaded thread list when identity resolutions land —
  /// pure in-memory pass, never a database read.
  private func reapplyConsolidation() {
    guard let cache = messagesViewState.recentThreadsCache,
          cache.includedWhatsApp == settings.whatsappEnabled else { return }
    applyConversations(
      MessageConversation.merge(
        lookback: .allTime,
        draftThreads: DraftThread.group(store.drafts.filter { !$0.isSent }),
        recents: ConversationConsolidationPolicy.merge(
          threads: cache.threads,
          identities: contactIdentities.identifiers
        )
      )
    )
  }

  private func handleConversationRowAppear(_ conversation: MessageConversation) {
    let list = displayedConversations
    guard let index = list.firstIndex(where: { $0.id == conversation.id }) else { return }
    guard ConversationPagingPolicy.shouldLoadNextPage(
      appearedIndex: index,
      totalCount: list.count,
      isLoading: isLoadingNextConversationPage,
      hasMore: hasMoreConversationPages,
      isSearching: isSearchingConversations
    ) else { return }
    loadNextConversationPage()
  }

  /// Debounced (~250ms) DB-wide search: at >= 2 chars, load every
  /// conversation's identity row (no previews — search only needs identity +
  /// recency) and apply the SAME match semantics as the in-memory filter, so
  /// resolved contact names, handles, and group display names all hit even
  /// for threads the pager hasn't reached.
  private func scheduleDatabaseSearch(_ query: String) {
    databaseSearchTask?.cancel()
    guard ConversationSearchMergePolicy.shouldSearchDatabase(query: query) else {
      databaseSearchResults = []
      return
    }
    let includeWhatsApp = settings.whatsappEnabled
    databaseSearchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: ConversationSearchMergePolicy.debounceNanoseconds)
      guard !Task.isCancelled else { return }
      DispatchQueue.global(qos: .userInitiated).async {
        let threads = RecentComposeThread.searchAllTime(includeWhatsApp: includeWhatsApp)
        let wrapped = threads.map { MessageConversation(recent: $0, draftThread: nil) }
        let matches = ConversationSearchPolicy.filtered(wrapped, query: query).map(\.recent)
        DispatchQueue.main.async {
          guard conversationSearch == query else { return }
          databaseSearchResults = matches
          // Hits beyond the loaded pages haven't been identity-resolved yet;
          // register them so same-person hits fold once Contacts answers.
          contactIdentities.register(
            matches.filter { !$0.isGroupConversation }.map(\.handle)
          )
        }
      }
    }
  }

  private func applyConversations(_ merged: [MessageConversation]) {
    conversations = merged
    conversationsEverLoaded = true
    // Seed identity resolution for every member handle on screen; resolved
    // contacts arrive via onChange and re-fold the list.
    contactIdentities.register(
      merged.filter { !$0.recent.isGroupConversation }
        .flatMap { [$0.recent.handle] + $0.recent.consolidatedSiblings.map(\.handle) }
    )
    // A new-thread placeholder becomes real after the first send — move the
    // selection onto the real conversation and drop the placeholder.
    if let pending = pendingNewThread,
       messagesViewState.selectedConversationID == pending.id,
       let real = merged.first(where: { $0.recent.sharesHandle(with: pending) }) {
      pendingNewThread = nil
      messagesViewState.selectedConversationID = real.id
    }
    // The selected row may have just been folded into a same-person sibling
    // (its contact resolved between applies) — follow the selection onto the
    // merged row instead of snapping to the top of the list.
    if let selectedID = messagesViewState.selectedConversationID,
       !merged.contains(where: { $0.id == selectedID }),
       let owner = merged.first(where: { conversation in
         conversation.recent.consolidatedSiblings.contains { $0.id == selectedID }
       }) {
      messagesViewState.selectedConversationID = owner.id
    }
    consumePendingConversationSelection()
    if let selectedConversationID = messagesViewState.selectedConversationID,
       displayedConversations.contains(where: { $0.id == selectedConversationID }) {
      messagesViewState.preload(displayedConversations)
      return
    }
    messagesViewState.selectedConversationID = displayedConversations.first?.id
    messagesViewState.preload(displayedConversations)
    // First load lands with a selection already on screen — read it.
    markSelectedConversationSeen()
  }

  private func isUnread(_ conversation: MessageConversation) -> Bool {
    // Aggregate across folded siblings: a merged row is unread when ANY
    // member thread is. Marking seen at the row's (newest) lastMessageDate
    // covers every member — sibling messages are older by construction.
    messagesViewState.readLedger.isUnread(
      conversationID: conversation.id,
      unreadCount: conversation.recent.aggregateUnreadCount,
      lastMessageDate: conversation.recent.lastMessageDate
    )
  }

  private func markSelectedConversationSeen() {
    guard let conversation = selectedConversation else { return }
    // The thread overload also marks folded siblings, so a later un-fold
    // can't resurface dots for messages already seen in the merged transcript.
    messagesViewState.markSeen(thread: conversation.recent)
  }

  private func handleComposePick(_ pick: MessagesComposePick) {
    switch pick {
    case .conversation(let id):
      animate(.easeInOut(duration: 0.14)) {
        messagesViewState.selectedConversationID = id
      }
    case .newContact(let name, let handle):
      if let key = ContactAvatarStore.canonicalKey(handle),
         let existing = conversations.first(where: { $0.recent.canonicalHandleKeys.contains(key) }) {
        messagesViewState.selectedConversationID = existing.id
        return
      }
      let thread = RecentComposeThread(
        id: "new-\(handle.lowercased())",
        platform: .imessage,
        handle: handle,
        title: name,
        subtitle: handle,
        threadID: nil,
        lastMessageDate: Date()
      )
      pendingNewThread = thread
      messagesViewState.selectedConversationID = thread.id
    }
  }

  // MARK: - Keyboard shortcuts (Messages tab)

  /// Hidden buttons carrying the tab's shortcuts: ⌘N compose, ⌘F search,
  /// ⌘E emoji, ⌥⌘↑/↓ conversation switching, ⌘/ this list.
  private var messagesShortcutHandlers: some View {
    Group {
      Button("") { showingCompose = true }
        .keyboardShortcut("n", modifiers: [.command])
      Button("") { searchFocused = true }
        .keyboardShortcut("f", modifiers: [.command])
      Button("") { NSApp.orderFrontCharacterPalette(nil) }
        .keyboardShortcut("e", modifiers: [.command])
      Button("") { stepConversation(-1) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
      Button("") { stepConversation(1) }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      Button("") { showingShortcuts = true }
        .keyboardShortcut("/", modifiers: [.command])
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func stepConversation(_ delta: Int) {
    let list = displayedConversations
    guard !list.isEmpty else { return }
    let currentIndex = list.firstIndex(where: { $0.id == messagesViewState.selectedConversationID }) ?? 0
    let next = min(max(currentIndex + delta, 0), list.count - 1)
    animate(.easeInOut(duration: 0.14)) {
      messagesViewState.selectedConversationID = list[next].id
    }
  }

  // MARK: - Deep links (Birthday lab → Messages tab)

  /// Consume a pending "open this person's conversation" deep link once the
  /// conversation list is loaded. A request that matches nobody is dropped
  /// rather than retried forever — the person may have no recent thread.
  private func consumePendingConversationSelection() {
    guard let handles = messagesViewState.pendingConversationHandles else { return }
    guard !conversations.isEmpty else { return } // wait for the load to land
    messagesViewState.pendingConversationHandles = nil
    resolveAndOpenConversation(handles: handles, displayName: nil)
  }

  /// Deep-link landing that always reaches the person (P0): the all-time
  /// pager loads ~one page, so most people are NOT in `conversations` —
  /// sweep the full database before giving up, and even then land on a
  /// ready-to-send placeholder thread instead of silently staying put.
  private func resolveAndOpenConversation(handles: [String], displayName: String?) {
    if let match = ConversationHandleMatcher.match(handles: handles, in: conversations) {
      animate(.easeInOut(duration: 0.14)) {
        messagesViewState.selectedConversationID = match.id
      }
      return
    }
    let includeWhatsApp = settings.whatsappEnabled
    Task {
      let all = await Task.detached(priority: .userInitiated) {
        RecentComposeThread.searchAllTime(includeWhatsApp: includeWhatsApp)
      }.value
      await MainActor.run {
        if let thread = ConversationHandleMatcher.matchThread(handles: handles, in: all) {
          // The placeholder machinery pins the row until its page loads;
          // ids are stable across searchAllTime and loadPage, so the
          // selection survives the swap to the real row.
          pendingNewThread = thread
          animate(.easeInOut(duration: 0.14)) {
            messagesViewState.selectedConversationID = thread.id
          }
        } else if let handle = handles.first(where: { ContactAvatarStore.canonicalKey($0) != nil }) {
          let thread = RecentComposeThread(
            id: "new-\(handle.lowercased())",
            platform: .imessage,
            handle: handle,
            title: displayName ?? handle,
            subtitle: handle,
            threadID: nil,
            lastMessageDate: Date()
          )
          pendingNewThread = thread
          animate(.easeInOut(duration: 0.14)) {
            messagesViewState.selectedConversationID = thread.id
          }
        }
      }
    }
  }

  /// Consume a pending compose deep link: preselect the recipient, switch to
  /// Scheduled mode when a fire date rides along, and open the sheet with an
  /// EMPTY body (the user writes the message).
  /// The sidebar compose shortcut: open the blank new-message picker.
  private func consumePendingComposeNew() {
    guard messagesViewState.pendingComposeNew else { return }
    messagesViewState.pendingComposeNew = false
    showingCompose = true
  }

  private func consumePendingCompose() {
    guard let request = messagesViewState.pendingCompose else { return }
    messagesViewState.pendingCompose = nil
    let handle = request.recipientHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !handle.isEmpty else { return }
    composeInitialRecipient = ComposeRecipient(
      id: "deeplink-\(handle.lowercased())",
      title: request.recipientName ?? handle,
      subtitle: request.recipientName == nil ? "" : handle,
      handle: handle,
      name: request.recipientName,
      platform: nil,
      threadID: nil,
      contextMessages: nil
    )
    composeInitialMode = request.scheduledAt != nil ? .scheduled : .draft
    composeInitialDate = request.scheduledAt
    showingScheduledCompose = true
  }

  /// Clear deep-link compose state after the sheet closes so a later plain
  /// Compose-button open starts from scratch.
  private func resetComposeDeepLink() {
    composeInitialRecipient = nil
    composeInitialMode = .draft
    composeInitialDate = nil
  }

  private func ensureSelectedConversationVisible() {
    if let selectedConversationID = messagesViewState.selectedConversationID,
       displayedConversations.contains(where: { $0.id == selectedConversationID }) {
      return
    }
    messagesViewState.selectedConversationID = displayedConversations.first?.id
  }

  // MARK: - Birthday nudge

  private var dismissedBirthdayOccurrenceIDs: Set<String> {
    Set(dismissedBirthdayNudgeCSV.split(separator: ",").map(String.init))
  }

  /// Birthdays you've already reached out to today resolve themselves — once the
  /// person's thread shows an outbound message from today, drop the nudge
  /// (no waiting on a re-scan to detect the wish).
  private var birthdayResolvedOccurrenceIDs: Set<String> {
    guard case .loaded(let result) = birthdayGenerator.state else { return [] }
    var messagedTodayCanons: Set<String> = []
    for conversation in baseConversations {
      for thread in [conversation.recent] + conversation.recent.consolidatedSiblings {
        guard thread.lastMessageFromMe,
              let date = thread.lastMessageDate,
              Calendar.current.isDateInToday(date),
              let canon = ContactAvatarStore.canonicalKey(thread.handle) else { continue }
        messagedTodayCanons.insert(canon)
      }
    }
    guard !messagedTodayCanons.isEmpty else { return [] }
    return Set(result.upcoming.compactMap { birthday in
      let canons = ([birthday.bestHandle].compactMap { $0 } + birthday.handles)
        .compactMap { ContactAvatarStore.canonicalKey($0) }
      return canons.contains(where: { messagedTodayCanons.contains($0) })
        ? BirthdayNudgePolicy.occurrenceID(birthday)
        : nil
    })
  }

  /// All birthdays worth nudging about, stacked (today's first, then tomorrow's).
  private var currentBirthdayNudges: [UpcomingBirthday] {
    guard case .loaded(let result) = birthdayGenerator.state else { return [] }
    return BirthdayNudgePolicy.picks(
      result.upcoming,
      dismissedIDs: dismissedBirthdayOccurrenceIDs,
      resolvedIDs: birthdayResolvedOccurrenceIDs
    )
  }

  /// Open the conversation with the birthday person; if none exists in the
  /// loaded list, hand off to the Birthday Texts lab.
  private func dismissBirthdayNudge(_ birthday: UpcomingBirthday) {
    var ids = dismissedBirthdayOccurrenceIDs
    ids.insert(BirthdayNudgePolicy.occurrenceID(birthday))
    dismissedBirthdayNudgeCSV = ids.sorted().joined(separator: ",")
  }

  private func openBirthdayConversation(_ birthday: UpcomingBirthday) {
    // "Send them a message" must land IN the thread (P0) — resolving past
    // the loaded page, with a compose-ready placeholder as the worst case.
    // Bouncing to the Birthday tab is never the answer here.
    let handles = ([birthday.bestHandle].compactMap { $0 } + birthday.handles)
    resolveAndOpenConversation(handles: handles, displayName: birthday.name)
  }

  private func animate(_ animation: Animation, _ body: @escaping () -> Void) {
    if reduceMotion {
      body()
    } else {
      withAnimation(animation, body)
    }
  }
}

/// The in-place birthday reminder at the top of the Messages tab: one calm,
/// tappable row ("Maya's birthday is today — open the conversation") with a
/// per-occurrence dismiss. The cake is the one warm accent on this surface.
struct BirthdayNudgeRow: View {
  let birthday: UpcomingBirthday
  let onOpen: () -> Void
  let onDismiss: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 9) {
      Button(action: onOpen) {
        HStack(spacing: 9) {
          Image(systemName: "birthday.cake.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.Color.amber(colorScheme))
          VStack(alignment: .leading, spacing: 1) {
            Text(BirthdayNudgePolicy.headline(birthday))
              .font(DS.Font.settingsLabel)
              .foregroundStyle(DS.Color.ink(colorScheme))
              .lineLimit(1)
            Text("Send them a message")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
          Spacer(minLength: 4)
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(BirthdayNudgePolicy.headline(birthday)). Open conversation")

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss birthday reminder")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .fill(isHovering ? DS.Color.g160(colorScheme) : DS.Color.g130(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        .strokeBorder(DS.Color.line2(colorScheme), lineWidth: 1)
    )
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.14)) { isHovering = hovering }
    }
  }
}

enum MessagesComposePick {
  case conversation(String)
  case newContact(name: String, handle: String)
}

/// iMessage-parity compose: pick a person or thread and drop straight into
/// the conversation. No drafting controls here — staging/scheduling live in
/// the Drafts and Scheduled tabs.
private struct MessagesComposePicker: View {
  let conversations: [MessageConversation]
  let onPick: (MessagesComposePick) -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @FocusState private var fieldFocused: Bool

  private var matchingConversations: [MessageConversation] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Array(conversations.prefix(10)) }
    return Array(ConversationSearchPolicy.filtered(conversations, query: trimmed).prefix(8))
  }

  private var contactMatches: [ContactMatch] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return [] }
    let conversationKeys = Set(conversations.compactMap { ContactAvatarStore.canonicalKey($0.recent.handle) })
    return ContactsExporter.searchContacts(trimmed, limit: 12).filter { match in
      guard let handle = match.bestHandle, let key = ContactAvatarStore.canonicalKey(handle) else { return false }
      return !conversationKeys.contains(key)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("To:")
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink3(colorScheme))
        TextField("Name, phone, or email", text: $query)
          .textFieldStyle(.plain)
          .font(DS.Font.detailName)
          .foregroundStyle(DS.Color.ink(colorScheme))
          .focused($fieldFocused)
          .onSubmit { submitFirstResult() }
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel("Close compose")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      Rectangle().fill(DS.Color.line(colorScheme)).frame(height: 1)

      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if !matchingConversations.isEmpty {
            pickerSectionLabel("Conversations")
            ForEach(matchingConversations) { conversation in
              pickerRow(
                title: conversation.title,
                subtitle: conversation.recent.lastMessagePreview.isEmpty
                  ? conversation.subtitle
                  : conversation.recent.lastMessagePreview,
                handle: conversation.recent.handle,
                isGroup: conversation.recent.isGroupConversation,
                platform: conversation.platform
              ) {
                onPick(.conversation(conversation.id))
              }
            }
          }
          let contacts = contactMatches
          if !contacts.isEmpty {
            pickerSectionLabel("Contacts")
            ForEach(contacts) { match in
              if let handle = match.bestHandle {
                pickerRow(
                  title: match.name,
                  subtitle: handle,
                  handle: handle,
                  isGroup: false,
                  platform: .imessage
                ) {
                  onPick(.newContact(name: match.name, handle: handle))
                }
              }
            }
          }
          if matchingConversations.isEmpty && contacts.isEmpty {
            Text(query.count < 2 ? "Type a name, number, or email." : "No matches.")
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .padding(14)
          }
        }
        .padding(10)
      }
    }
    .background(DS.Color.g100(colorScheme))
    .onAppear { fieldFocused = true }
  }

  private func submitFirstResult() {
    if let first = matchingConversations.first {
      onPick(.conversation(first.id))
    } else if let first = contactMatches.first, let handle = first.bestHandle {
      onPick(.newContact(name: first.name, handle: handle))
    }
  }

  private func pickerSectionLabel(_ title: String) -> some View {
    Text(title)
      .font(DS.Font.sectionLabel)
      .tracking(0.6)
      .foregroundStyle(DS.Color.ink3(colorScheme))
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 4)
  }

  private func pickerRow(
    title: String,
    subtitle: String,
    handle: String,
    isGroup: Bool,
    platform: Platform,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        ContactAvatarView(handle: handle, title: title, isGroup: isGroup, platform: platform, size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(DS.Font.rowTitle)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
          if !subtitle.isEmpty {
            Text(subtitle)
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(8)
      .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

/// ⌘/ — the Messages tab's shortcut reference.
private struct MessagesShortcutsOverlay: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss

  private let rows: [(String, String)] = [
    ("⌘N", "New message"),
    ("⌘F", "Search conversations"),
    ("⌘E", "Insert emoji"),
    ("⌥⌘↑ / ⌥⌘↓", "Previous / next conversation"),
    ("⏎", "Send message"),
    ("⌘/", "Show these shortcuts"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Keyboard shortcuts")
          .font(DS.Font.settingsTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel("Close shortcuts")
      }
      VStack(spacing: 8) {
        ForEach(rows, id: \.0) { keys, label in
          HStack {
            Text(keys)
              .font(DS.Font.monoValue)
              .foregroundStyle(DS.Color.ink(colorScheme))
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                  .fill(DS.Color.g130(colorScheme))
              )
            Spacer()
            Text(label)
              .font(DS.Font.settingsCaption)
              .foregroundStyle(DS.Color.ink2(colorScheme))
          }
        }
      }
    }
    .padding(20)
    .background(DS.Color.g100(colorScheme))
  }
}

private struct FilterToggleChip: View {
  var label: String? = nil
  let systemImage: String
  let isOn: Bool
  /// When true, a hand-drawn diagonal slash is overlaid on the icon to read as
  /// "filtering active". We draw it ourselves instead of using the `.slash` SF
  /// Symbol variant, which renders unreliably at this 12pt size.
  var isSlashed: Bool = false
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var iconColor: Color {
    isOn ? DS.Color.accentTeal(colorScheme) : DS.Color.ink(colorScheme)
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        iconView
        if let label {
          Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(iconColor)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(isOn ? DS.Color.accentTeal(colorScheme).opacity(0.12) : DS.Color.g130(colorScheme))
      )
      .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
    .buttonStyle(.plain)
    .fixedSize()
  }

  /// Base SF Symbol, plus (when `isSlashed`) a forward-slash drawn from two
  /// rotated capsules: a wider surface-colored "knockout" behind a thin
  /// icon-colored line, so the slash reads as cutting through the glyph rather
  /// than merging into it.
  @ViewBuilder private var iconView: some View {
    let size: CGFloat = 12
    Image(systemName: systemImage)
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(iconColor)
      .overlay {
        if isSlashed {
          ZStack {
            Capsule(style: .continuous)
              .fill(DS.Color.ghostieShellContent(colorScheme))
              .frame(width: size * 1.55, height: 3.6)
            Capsule(style: .continuous)
              .fill(iconColor)
              .frame(width: size * 1.55, height: 1.8)
          }
          .rotationEffect(.degrees(-45))
        }
      }
  }
}

private struct MessageFilterChip<Content: View>: View {
  let title: String
  let systemImage: String
  let accessibilityLabel: String
  @ViewBuilder let content: () -> Content

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Menu {
      content()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DS.Color.ink3(colorScheme))
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(DS.Color.ink(colorScheme))
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(DS.Color.g130(colorScheme))
      )
      .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .buttonStyle(.plain)
    .fixedSize()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(title)
  }
}

struct MessageConversationRow: View {
  let conversation: MessageConversation
  let selected: Bool
  /// DB-unread minus the in-app read ledger (computed by the pane —
  /// chat.db's is_read alone can't know what was read HERE).
  var isUnread: Bool = false
  let label: WorkPersonalLabel?
  var priority: ThreadPriorityEntry?
  var compact: Bool = false
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovering = false

  /// chat.db `service_name` for the row's thread — drives the green SMS/RCS pill
  /// (iMessage stays unmarked). Group rows don't carry a single service.
  private var serviceName: String? {
    conversation.recent.isGroupConversation ? nil : conversation.recent.serviceName
  }

  var body: some View {
    Group {
      if compact {
        compactContent
      } else {
        normalContent
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, compact ? 4 : 9)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .fill(rowFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(selected ? DS.Color.line(colorScheme) : .clear, lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.14)) { isHovering = hovering }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder
  private var compactContent: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(isUnread ? DS.Color.accentTeal(colorScheme) : .clear)
        .frame(width: 5, height: 5)
        .accessibilityHidden(true)
      Text(conversation.title)
        .font(DS.Font.rowTitle)
        .foregroundStyle(DS.Color.ink(colorScheme))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      if let priority, let level = ThreadPriorityLevel(rawValue: priority.level) {
        PriorityChip(level: level, reason: priority.reason)
      }
      if conversation.draftCount > 0 {
        CountChip(count: conversation.draftCount, systemImage: "pencil", tone: .draft)
      }
      if conversation.scheduledCount > 0 {
        CountChip(count: conversation.scheduledCount, systemImage: "clock", tone: .scheduled)
      }
      ServiceBadge(serviceName: serviceName)
      Text(rowDate)
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .monospacedDigit()
    }
  }

  @ViewBuilder
  private var normalContent: some View {
    HStack(spacing: 9) {
      // Fixed unread gutter so titles align whether or not a dot renders —
      // Messages.app reserves this slot left of the avatar.
      Circle()
        .fill(isUnread ? DS.Color.accentTeal(colorScheme) : .clear)
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
      avatar
      VStack(alignment: .leading, spacing: 3) {
        Text(conversation.title)
          .font(DS.Font.rowTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
          .lineLimit(1)
          .truncationMode(.tail)
        if !secondaryLine.isEmpty {
          Text(secondaryLine)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 5) {
        Text(rowDate)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .monospacedDigit()
        HStack(spacing: 5) {
          ServiceBadge(serviceName: serviceName)
          if let priority, let level = ThreadPriorityLevel(rawValue: priority.level) {
            PriorityChip(level: level, reason: priority.reason)
          }
          if conversation.draftCount > 0 {
            CountChip(count: conversation.draftCount, systemImage: "pencil", tone: .draft)
          }
          if conversation.scheduledCount > 0 {
            CountChip(count: conversation.scheduledCount, systemImage: "clock", tone: .scheduled)
          }
          if let label, label != .unknown {
            Image(systemName: label.systemImage)
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
        }
      }
    }
  }

  private var avatar: some View {
    ContactAvatarView(
      handle: conversation.recent.handle,
      title: conversation.title,
      isGroup: conversation.recent.isGroupConversation,
      platform: conversation.platform,
      size: 34
    )
  }

  /// Messages.app shows the newest message under the name; we fall back to
  /// the handle when no snippet is available (encrypted WhatsApp bodies).
  private var secondaryLine: String {
    let preview = conversation.recent.lastMessagePreview
    if !preview.isEmpty { return preview }
    return conversation.subtitle
  }

  private var rowDate: String {
    guard let date = conversation.lastMessageDate else { return "" }
    return MessageFormatters.conversationRowDate(date)
  }

  private var relativeDate: String {
    guard let date = conversation.lastMessageDate else { return "" }
    return MessageFormatters.relative.localizedString(for: date, relativeTo: Date())
  }

  private var rowFill: Color {
    if selected { return DS.Color.g160(colorScheme) }
    if isHovering { return DS.Color.g130(colorScheme) }
    return .clear
  }

  private var accessibilityLabel: String {
    var parts = [conversation.title]
    if isUnread {
      parts.append("unread")
    }
    if let priority, let level = ThreadPriorityLevel(rawValue: priority.level) {
      parts.append("\(level.title) priority")
    }
    if conversation.draftCount > 0 {
      parts.append("\(conversation.draftCount) \(conversation.draftCount == 1 ? "draft" : "drafts")")
    }
    if conversation.scheduledCount > 0 {
      parts.append("\(conversation.scheduledCount) scheduled")
    }
    if !relativeDate.isEmpty {
      parts.append(relativeDate)
    }
    return parts.joined(separator: ", ")
  }
}

/// Applies `.defaultScrollAnchor(.bottom)` only when `active`. Flag-on disables it so
/// the explicit near-bottom-gated scroll owns positioning (the native anchor would
/// otherwise pin the bottom on every append and defeat the gate). The `active` value
/// only flips when the feature flag is toggled, so the branch-identity change is a
/// rare, testing-only remount.
private struct ConditionalBottomAnchor: ViewModifier {
  let active: Bool
  func body(content: Content) -> some View {
    if active {
      content.defaultScrollAnchor(.bottom)
    } else {
      content
    }
  }
}

private struct MessageConversationDetail: View {
  let conversation: MessageConversation
  let workPersonalFilter: WorkPersonalFilter
  let cachedMessages: ThreadMessageCacheEntry?
  let onMessagesLoaded: ([ContextMessage], Bool) -> Void
  @EnvironmentObject private var nav: ConsoleNavigation
  @EnvironmentObject private var store: DraftStore
  @EnvironmentObject private var settings: SettingsStore
  @EnvironmentObject private var featureFlags: FeatureFlagStore
  @EnvironmentObject private var workPersonal: WorkPersonalStore
  @EnvironmentObject private var threadPriorities: ThreadPriorityStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var messages: [ContextMessage] = []
  @State private var messageLoadToken = UUID()
  @State private var isLoadingOlderMessages = false
  @State private var hasLoadedAllAvailableHistory = false
  /// Drives the transcript skeleton vs. the genuine "no messages" empty state:
  /// `.loading` on a cold open, `.reconnecting` while a WhatsApp cold read is
  /// retrying, `.idle` once content (or a confirmed-empty result) lands.
  private enum TranscriptLoadPhase { case idle, loading, reconnecting }
  @State private var transcriptLoadPhase: TranscriptLoadPhase = .idle
  @State private var skeletonPulse = false
  @State private var suppressNextAutoScroll = false
  @State private var initialBottomSnapCompleted = false
  @State private var pendingRestoreAnchorID: String?
  @State private var composeBody = ""
  @State private var composeAttachment: URL?
  @State private var composeError: String?
  @State private var isSending = false
  /// The thread whose unsent text the composer currently owns. Tracked so a
  /// navigate-away (thread switch / view teardown) can auto-save the text to
  /// the thread it was typed in — not the one being switched *to*. Auto-save
  /// fires only on leave, never while typing.
  @State private var autosaveOwner: MessageConversation?
  @State private var showingScheduleControls = false
  @State private var scheduleDate = Date().addingTimeInterval(3600)
  @State private var failedInlineDraftID: String?
  @State private var optimisticMessages: [OptimisticDirectMessage] = []
  @State private var pendingDirectSendBottomSnap = false
  // transcript-snap-fix (flag-on) scroll state. `forceScrollOnNextBottomChange` is
  // a one-shot armed by every direct-send path so the user's own send ALWAYS
  // advances to the new message. `nearBottom` tracks whether the bottom is in view
  // (via the tail sentinel) so inbound/non-forced changes only follow when the user
  // is already at the bottom — never yanking someone who scrolled up to read history.
  @State private var forceScrollOnNextBottomChange = false
  @State private var nearBottom = true
  @State private var isDropTargeted = false
  @State private var showingIMessageReactionUnavailable = false
  @State private var showingCustomIMessageReaction = false
  @State private var customIMessageReactionText = ""
  @State private var customIMessageReactionMessage: ContextMessage?
  @AppStorage("messages.iMessageReactionUnavailableExplained") private var iMessageReactionUnavailableExplained = false
  private var bottomAnchorID: String { "message-bottom-\(conversation.id)" }
  private var sendTarget: MessageSendTarget { MessageSendTarget(conversation: conversation) }
  // The composer's own auto-save draft is edited live in the composer below, so
  // it must not also render as a pending bubble in this same thread. It still
  // counts toward the row's draft badge and appears in the Drafts pane.
  private var inlineDrafts: [Draft] {
    (conversation.draftThread?.pendingDrafts ?? []).filter { $0.source != ComposerAutosavePolicy.source }
  }
  /// This thread's unsent composer auto-save draft, if any.
  private var composerAutosaveDraft: Draft? {
    ComposerAutosavePolicy.existingDraft(
      in: store.drafts,
      platform: conversation.platform,
      handle: conversation.recent.recipient.handle,
      canonicalize: ContactAvatarStore.canonicalKey
    )
  }
  private static let reactionChoices = ["❤️", "👍", "👎", "😂", "‼️", "❓", "🔥", "🎉"]
  private var reusableFailedDraft: Draft? {
    InlineFailedDraftPolicy.reusableDraft(
      id: failedInlineDraftID,
      drafts: store.drafts,
      conversation: conversation.recent
    )
  }

  private var visibleMessages: [ContextMessage] {
    guard workPersonal.enabled else { return messages }
    let personLabel = workPersonal.personLabel(for: conversation.recent)
    return messages.filter { message in
      WorkPersonalVisibility.messageVisible(
        messageLabel: nil,
        personLabel: personLabel,
        filter: workPersonalFilter,
        proEnabled: false
      )
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      threadHeader
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
      Divider()
        .overlay(DS.Color.line(colorScheme))
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            topHistoryLoader
            if visibleMessages.isEmpty && inlineDrafts.isEmpty && optimisticMessages.isEmpty {
              if transcriptLoadPhase == .idle {
                transcriptEmptyState
              } else {
                transcriptLoadingState(reconnecting: transcriptLoadPhase == .reconnecting)
              }
            } else {
              transcript
            }
            Color.clear
              .frame(height: 1)
              .id(bottomAnchorID)
              // Near-bottom sentinel: in a LazyVStack this 1pt tail row is only
              // rendered when the viewport is at/near the end, so its appear/disappear
              // tracks "is the user at the bottom" — the gate the flag-on path uses to
              // decide whether a non-forced (inbound/reconcile) change should follow.
              .onAppear { nearBottom = true }
              .onDisappear { nearBottom = false }
          }
          .frame(maxWidth: .infinity, minHeight: 560, alignment: .leading)
          .padding(.horizontal, 28)
          .padding(.vertical, 18)
        }
        // Flag-off keeps .defaultScrollAnchor(.bottom). Flag-on REMOVES it: it pins the
        // bottom on every content-size change, which would defeat the near-bottom gate
        // (yanking a user who scrolled up). With it gone the flag-on path owns all
        // positioning via the single explicit scroll below.
        .modifier(ConditionalBottomAnchor(active: !featureFlags.resolved(.transcriptSnapFix)))
        .onAppear {
          if featureFlags.resolved(.transcriptSnapFix) {
            scrollToLastRow(proxy, animated: false)
            // Arm the top-history loader once layout settles (the old multi-pass
            // snap used to set this in its final pass).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { initialBottomSnapCompleted = true }
          } else {
            scrollToBottom(proxy, animated: false)
          }
        }
        // Flag-off: the original multi-pass snap, keyed off transcriptRenderIDs.
        .onChange(of: transcriptRenderIDs) { _, _ in
          guard !featureFlags.resolved(.transcriptSnapFix) else { return }
          if let anchor = pendingRestoreAnchorID {
            pendingRestoreAnchorID = nil
            scrollToAnchor(anchor, proxy: proxy)
            return
          }
          if suppressNextAutoScroll {
            suppressNextAutoScroll = false
            return
          }
          if pendingDirectSendBottomSnap {
            pendingDirectSendBottomSnap = false
            scrollToBottom(proxy, animated: true)
            return
          }
          scrollToBottom(proxy, animated: false)
        }
        // Flag-on: ONE scroll per bottom-row change, and only when the user sent
        // (forced) or was already at the bottom (nearBottom). History-prepend restore
        // stays first. bottomRowKey excludes per-row state/body, so .sending→.sent,
        // edits, and tapbacks don't move the scroll.
        .onChange(of: bottomRowKey) { _, _ in
          guard featureFlags.resolved(.transcriptSnapFix) else { return }
          if let anchor = pendingRestoreAnchorID {
            pendingRestoreAnchorID = nil
            scrollToAnchor(anchor, proxy: proxy)
            return
          }
          let shouldScroll = forceScrollOnNextBottomChange || nearBottom
          forceScrollOnNextBottomChange = false
          suppressNextAutoScroll = false
          pendingDirectSendBottomSnap = false
          guard shouldScroll else { return }
          // Initial load snaps instantly (no top→bottom animation on open); later
          // changes (sends, inbound) get a gentle single scroll.
          scrollToLastRow(proxy, animated: initialBottomSnapCompleted)
        }
      }
      Divider()
        .overlay(DS.Color.line(colorScheme))
      let target = sendTarget
      InlineThreadComposer(
        messageBody: $composeBody,
        error: composeError,
        isSending: isSending,
        showingScheduleControls: $showingScheduleControls,
        scheduleDate: $scheduleDate,
        // Group chats send live via the chat id; staging/scheduling stay
        // single-recipient for now.
        allowsDrafting: !(conversation.platform == .imessage && conversation.recent.isGroupConversation),
        attachment: $composeAttachment,
        onSend: { Task { await sendTypedMessage(target: target) } },
        onStageDraft: { stageTypedMessage(target: target, scheduledAt: nil) },
        onSchedule: { stageTypedMessage(target: target, scheduledAt: scheduleDate) }
      )
      .id(conversation.id)
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
    .onAppear {
      loadMessages()
      restoreComposerDraft()
      autosaveOwner = conversation
    }
    .onChange(of: conversation.id) { _, _ in
      // Navigated to a different thread — persist the text we were holding for
      // the OLD thread (composeBody/autosaveOwner are still the old values here)
      // before swapping in the new thread's draft.
      if let owner = autosaveOwner {
        saveComposerDraft(owner: owner, body: composeBody, contextMessages: [])
      }
      resetInlineComposer()
      autosaveOwner = conversation
      restoreComposerDraft()
      loadMessages()
    }
    .onDisappear {
      // Navigated away from Messages entirely (tab switch / window close) —
      // persist the open thread's unsent text. The view is reused across thread
      // switches, so onDisappear fires only on a real leave, not on switch.
      if let owner = autosaveOwner {
        saveComposerDraft(
          owner: owner,
          body: composeBody,
          contextMessages: visibleMessages.isEmpty ? messages : visibleMessages
        )
      }
    }
    // Live refresh bumps the open conversation's lastMessageDate without
    // changing the selection — re-pull the transcript so the thread shows
    // the new message, not just its list row. loadMessages keeps the
    // current bubbles on screen while the fresh page loads (no flicker),
    // and the stale cache fails shouldReuse so this always refetches.
    .onChange(of: conversation.recent.lastMessageDate) { _, _ in
      loadMessages()
    }
    .onChange(of: cachedMessages?.messages.map(\.transcriptStableID) ?? []) { _, _ in
      adoptWarmCacheIfUseful()
    }
    // The whole detail pane (header, transcript, composer) is one drop
    // target; isTargeted only toggles for drag sessions, never plain mouse
    // movement, and the overlay is hit-test-off so it can't perturb the drop.
    .overlay {
      if isDropTargeted {
        attachmentDropOverlay
      }
    }
    .alert("Native iMessage reactions are not available", isPresented: $showingIMessageReactionUnavailable) {
      Button("Got it") {}
    } message: {
      Text("Ghostie can display Tapbacks, but Apple does not provide a safe public API for adding a reaction to a specific iMessage. We will not inject code into Messages.app or write to chat.db.")
    }
    .alert("Custom Emoji Reaction", isPresented: $showingCustomIMessageReaction) {
      TextField("Emoji", text: $customIMessageReactionText)
      Button("React") {
        let emoji = customIMessageReactionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = customIMessageReactionMessage
        customIMessageReactionText = ""
        customIMessageReactionMessage = nil
        guard !emoji.isEmpty, let message else { return }
        Task { await sendIMessageReaction(message: message, emoji: emoji) }
      }
      Button("Cancel", role: .cancel) {
        customIMessageReactionText = ""
        customIMessageReactionMessage = nil
      }
    } message: {
      Text("Enter the emoji to use as the Tapback.")
    }
    .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
      handleAttachmentDrop(providers)
    }
  }

  private var threadHeader: some View {
    HStack(spacing: 12) {
      ContactAvatarView(
        handle: conversation.recent.handle,
        title: conversation.title,
        isGroup: conversation.recent.isGroupConversation,
        platform: conversation.platform,
        size: 32
      )
      VStack(alignment: .leading, spacing: 2) {
        Text(conversation.title)
          .font(DS.Font.detailName)
          .foregroundStyle(DS.Color.ink(colorScheme))
          .lineLimit(1)
          .truncationMode(.tail)
        if !conversation.subtitle.isEmpty {
          Text(conversation.subtitle)
            .font(DS.Font.caption)
            .monospacedDigit()
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer()
      // iMessage is the unmarked default (Apple only labels non-iMessage
      // transports); a blue IMESSAGE pill on every thread is accent inflation.
      if conversation.platform == .whatsapp {
        PlatformBadge(platform: conversation.platform)
      }
    }
  }

  /// Drop-hover affordance. Hit-testing stays off so the drop itself lands on
  /// the pane underneath; the label sits on a solid card because the dimmed
  /// wash alone isn't readable over transcript bubbles in either scheme.
  private var attachmentDropOverlay: some View {
    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
      .fill(DS.Color.accentTeal(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12))
      .overlay(
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
          .strokeBorder(DS.Color.accentTeal(colorScheme), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
      )
      .overlay(
        VStack(spacing: DS.Space.xs) {
          Image(systemName: "paperclip")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(DS.Color.accentTeal(colorScheme))
          Text("Drop to attach")
            .font(DS.Font.sectionTitle)
            .foregroundStyle(DS.Color.ink(colorScheme))
          Text("First file becomes the attachment")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
        .background(
          RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .fill(DS.Color.g050(colorScheme))
        )
        .overlay(
          RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Color.line2(colorScheme), lineWidth: 1)
        )
      )
      .padding(DS.Space.m)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var transcript: some View {
    let receipt = TranscriptReceiptPolicy.receipt(messages: visibleMessages, platform: conversation.platform)
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(visibleMessages.enumerated()), id: \.element.transcriptStableID) { pair in
        let previous = pair.offset > 0 ? visibleMessages[pair.offset - 1] : nil
        let message = pair.element
        let showSender = SenderLabelPolicy.shouldShowSender(
          isGroupConversation: conversation.recent.isGroupConversation,
          message: message,
          previous: previous
        )
        let showsSeparator = TranscriptSeparatorPolicy.shouldInsertSeparator(previous: previous, message: message)
        if showsSeparator, let date = message.sentDate {
          TranscriptDateSeparator(date: date)
        }
        ContextBubbleView(
          message: message,
          showSender: showSender,
          platform: conversation.platform,
          showTimestamp: false,
          receipt: receipt?.id == message.transcriptStableID ? receipt?.receipt : nil,
          contextMenuItems: reactionContextMenuItems(for: message),
          embeddedMediaPreviews: settings.embeddedMediaPreviews
        )
          .padding(
            .top,
            (pair.offset == 0 || showsSeparator)
              ? 0
              : (TranscriptSeparatorPolicy.isFollowOn(previous: previous, message: message) ? 2 : 10)
          )
          .id(message.transcriptStableID)
      }
      ForEach(inlineDrafts) { draft in
        PendingMessageBubble(draft: draft) {
          loadMessages()
        }
        .padding(.top, 10)
        .id("draft-\(draft.id)")
      }
      ForEach(optimisticMessages) { optimistic in
        OptimisticDirectMessageBubble(message: optimistic, platform: conversation.platform)
          .padding(.top, 10)
          // State-free identity: the same just-sent message keeps one identity as it
          // goes .sending→.sent (no remove+insert churn), and it's the stable target
          // the flag-on scroll aims at (`lastRowID`).
          .id("optimistic-\(optimistic.id)")
      }
    }
  }

  private func reactionContextMenuItems(for message: ContextMessage) -> [BubbleContextMenuItem] {
    switch conversation.platform {
    case .whatsapp:
      let canReact = message.message_id != nil
      return Self.reactionChoices.map { emoji in
        reactionMenuItem(emoji: emoji, enabled: canReact) {
          Task { await sendReaction(message: message, emoji: emoji) }
        }
      } + [
        .separator(id: "remove-separator-\(message.transcriptStableID)"),
        BubbleContextMenuItem(
          id: "remove-\(message.transcriptStableID)",
          title: "Remove Reaction",
          icon: .system("xmark.circle"),
          isEnabled: canReact
        ) {
          Task { await sendReaction(message: message, emoji: "") }
        }
      ]
    case .imessage:
      if featureFlags.resolved(.imessageAXTapbacks) {
        let hasBody = !(message.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let canReact = hasBody && !conversation.recent.isGroupConversation
        return IMessageTapbackAutomation.standardChoices.map { emoji in
          reactionMenuItem(emoji: emoji, enabled: canReact) {
            Task { await sendIMessageReaction(message: message, emoji: emoji) }
          }
        } + [
          .separator(id: "custom-separator-\(message.transcriptStableID)"),
          BubbleContextMenuItem(
            id: "custom-\(message.transcriptStableID)",
            title: "Custom Emoji...",
            icon: .system("face.smiling"),
            isEnabled: canReact
          ) {
            beginCustomIMessageReaction(message)
          }
        ]
      }

      if iMessageReactionUnavailableExplained {
        return [
          BubbleContextMenuItem(
            id: "imessage-unavailable-\(message.transcriptStableID)",
            title: "Native iMessage reactions unavailable",
            isEnabled: false,
            perform: {}
          )
        ]
      }

      return [
        BubbleContextMenuItem(
          id: "imessage-explain-\(message.transcriptStableID)",
          title: "Add Reaction...",
          icon: .system("face.smiling")
        ) {
          iMessageReactionUnavailableExplained = true
          showingIMessageReactionUnavailable = true
        }
      ]
    }
  }

  private func reactionMenuItem(
    emoji: String,
    enabled: Bool,
    perform: @escaping () -> Void
  ) -> BubbleContextMenuItem {
    BubbleContextMenuItem(
      id: "reaction-\(emoji)",
      title: reactionTitle(for: emoji),
      icon: .emoji(emoji),
      isEnabled: enabled,
      perform: perform
    )
  }

  private func beginCustomIMessageReaction(_ message: ContextMessage) {
    customIMessageReactionMessage = message
    customIMessageReactionText = ""
    showingCustomIMessageReaction = true
  }

  private func reactionTitle(for emoji: String) -> String {
    switch emoji {
    case "❤️": return "Heart"
    case "👍": return "Thumbs up"
    case "👎": return "Thumbs down"
    case "😂": return "Laugh"
    case "‼️": return "Emphasize"
    case "❓": return "Question"
    case "🔥": return "Fire"
    case "🎉": return "Celebrate"
    default: return "React with \(emoji)"
    }
  }

  @ViewBuilder
  private var topHistoryLoader: some View {
    if TranscriptScrollPolicy.shouldTriggerTopHistoryLoader(initialBottomSnapCompleted: initialBottomSnapCompleted),
       !messages.isEmpty,
       !hasLoadedAllAvailableHistory {
      HStack {
        Spacer()
        if isLoadingOlderMessages {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Loading older messages…")
              .font(DS.Font.caption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
          .accessibilityLabel("Loading older messages")
        } else {
          Color.clear
            .frame(width: 1, height: 1)
        }
        Spacer()
      }
      // Height stays 1pt so the loader never reserves layout space — the
      // spinner+label overflow into the transcript's top padding exactly like
      // the original spinner did, avoiding a transient scroll shift when
      // pagination begins (isLoadingOlderMessages flips before the prepend).
      .frame(height: 1)
      .onAppear {
        loadOlderMessages()
      }
    }
  }

  private var transcriptEmptyState: some View {
    HStack(spacing: 8) {
      Image(systemName: "text.bubble")
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Text("No readable messages in this thread.")
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
  }

  /// Skeleton transcript shown during a cold load so the pane reads as "loading"
  /// rather than flashing the empty state. A gentle opacity pulse (gated on
  /// Reduce Motion) keeps it alive; the reconnecting variant adds a WhatsApp
  /// retry hint.
  private func transcriptLoadingState(reconnecting: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      skeletonBubble(width: 180, outgoing: false)
      skeletonBubble(width: 232, outgoing: true)
      skeletonBubble(width: 148, outgoing: false)
      skeletonBubble(width: 206, outgoing: true)
      if reconnecting {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading… WhatsApp may be reconnecting")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ink3(colorScheme))
        }
        .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(reconnecting
      ? "Loading messages, WhatsApp may be reconnecting"
      : "Loading messages")
    .onAppear {
      // Under Reduce Motion, leave skeletonPulse false: the pulse animation is
      // suppressed anyway, so flipping it true would just snap the bubble opacity
      // 0.6 → 0.35 once (a flash). Static 0.6 is the correct still state.
      if !reduceMotion {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          skeletonPulse = true
        }
      }
    }
    .onDisappear { skeletonPulse = false }
  }

  private func skeletonBubble(width: CGFloat, outgoing: Bool) -> some View {
    HStack(spacing: 0) {
      if outgoing { Spacer(minLength: 48) }
      RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        .fill(DS.Color.line(colorScheme))
        .opacity(skeletonPulse ? 0.35 : 0.6)
        .frame(width: width, height: 34)
      if !outgoing { Spacer(minLength: 48) }
    }
  }

  private func loadMessages(retryCount: Int = 0, bypassCache: Bool = false) {
    // This invocation owns the phase; the empty-content check below re-arms the
    // skeleton only if there's genuinely nothing to show yet (so switching to a
    // cached-empty thread doesn't inherit a prior thread's loading skeleton).
    transcriptLoadPhase = .idle
    if !bypassCache,
       let cachedMessages,
       ThreadMessageCachePolicy.shouldReuse(
        platform: conversation.platform,
        cachedMessages: cachedMessages.messages,
        cachedLastMessageDate: cachedMessages.lastMessageDate,
        currentLastMessageDate: conversation.recent.lastMessageDate
       ) {
      messages = cachedMessages.messages
      hasLoadedAllAvailableHistory = cachedMessages.hasLoadedAllAvailableHistory
      return
    }
    if let cachedMessages, !cachedMessages.messages.isEmpty {
      messages = cachedMessages.messages
      hasLoadedAllAvailableHistory = cachedMessages.hasLoadedAllAvailableHistory
    }
    // Nothing to show yet → drive the skeleton (first attempt) or the
    // reconnecting skeleton (WhatsApp retry) instead of the empty state.
    if messages.isEmpty {
      transcriptLoadPhase = retryCount == 0 ? .loading : .reconnecting
    }
    let token = UUID()
    messageLoadToken = token
    // Consolidated rows union the transcript across every member thread;
    // sends still go only to the newest handle's thread (the row's own).
    let recent = conversation.recent
    Task {
      let loaded: [ContextMessage]
      do {
        loaded = try await recent.loadConsolidatedContext(limit: ThreadPreloadPolicy.initialPageLimit)
      } catch {
        if conversation.platform == .whatsapp, retryCount < 3 {
          try? await Task.sleep(nanoseconds: 700_000_000)
          await MainActor.run {
            guard messageLoadToken == token else { return }
            loadMessages(retryCount: retryCount + 1, bypassCache: bypassCache)
          }
          return
        }
        loaded = []
      }
      if conversation.platform == .whatsapp, loaded.isEmpty, retryCount < 3 {
        try? await Task.sleep(nanoseconds: 700_000_000)
        await MainActor.run {
          guard messageLoadToken == token else { return }
          loadMessages(retryCount: retryCount + 1, bypassCache: bypassCache)
        }
        return
      }
      await MainActor.run {
        guard messageLoadToken == token else { return }
        transcriptLoadPhase = .idle
        messages = loaded
        hasLoadedAllAvailableHistory = loaded.count < ThreadPreloadPolicy.initialPageLimit
        reconcileOptimisticMessages(with: loaded)
        onMessagesLoaded(messages, hasLoadedAllAvailableHistory)
      }
    }
  }

  // Canonical id of the last rendered transcript row, MATCHING its `.id(...)` in the
  // render order (messages → inline drafts → optimistic). State-free, so it stays
  // stable across an optimistic row's .sending→.sent. nil when the transcript is empty.
  private var lastRowID: String? {
    if let last = optimisticMessages.last { return "optimistic-\(last.id)" }
    if let last = inlineDrafts.last { return "draft-\(last.id)" }
    if let last = visibleMessages.last { return last.transcriptStableID }
    return nil
  }

  // Auto-scroll trigger for the flag-on path. Changes only when the BOTTOM row
  // identity changes or the transcript grows/shrinks — never on per-row state/body
  // churn — so `.sending→.sent`, body edits, and tapbacks don't move the scroll.
  private var bottomRowKey: String {
    "\(lastRowID ?? "none")#\(visibleMessages.count)-\(inlineDrafts.count)-\(optimisticMessages.count)"
  }

  // Flag-on single scroll: one next-runloop `scrollTo` to the real last row (not the
  // 0-height spacer), no multi-pass re-assert. Firing exactly once is the point — it's
  // what stops the estimate races from moving the view twice as content settles.
  private func scrollToLastRow(_ proxy: ScrollViewProxy, animated: Bool) {
    guard let target = lastRowID else { return }
    DispatchQueue.main.async {
      if animated && !reduceMotion {
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .bottom) }
      } else {
        proxy.scrollTo(target, anchor: .bottom)
      }
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    let target = bottomAnchorID
    let performScroll = {
      if animated, !reduceMotion {
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(target, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(target, anchor: .bottom)
      }
    }
    let isInitialSnap = !initialBottomSnapCompleted
    DispatchQueue.main.async {
      performScroll()
      DispatchQueue.main.async {
        performScroll()
        guard isInitialSnap else { return }
        // The first snap races lazy layout and late-arriving attachment
        // thumbnails — re-assert it as content settles, and only then arm
        // the top history loader (arming early while the view sat near the
        // top used to trigger an older-page load whose anchor restore
        // stranded the transcript at the top).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          performScroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
          performScroll()
          initialBottomSnapCompleted = true
        }
      }
    }
  }

  private func scrollToAnchor(_ anchor: String, proxy: ScrollViewProxy) {
    DispatchQueue.main.async {
      proxy.scrollTo(anchor, anchor: .top)
    }
  }

  private func transcriptID(_ message: ContextMessage) -> String {
    message.transcriptStableID
  }

  private var transcriptRenderIDs: [String] {
    visibleMessages.map(transcriptID)
      + inlineDrafts.map { "draft-\($0.id)-\($0.body)-\($0.sent_at ?? "pending")" }
      + optimisticMessages.map { "optimistic-\($0.id)-\($0.state)-\($0.body)" }
  }

  private func stageTypedMessage(target: MessageSendTarget, scheduledAt: Date?) {
    let body = composeBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    do {
      try validateCurrentTarget(target)
      _ = try createDraft(target: target, body: body, scheduledAt: scheduledAt)
      composeBody = ""
      composeError = nil
      failedInlineDraftID = nil
      showingScheduleControls = false
    } catch {
      composeError = error.localizedDescription
    }
  }

  private func sendTypedMessage(target: MessageSendTarget) async {
    let body = composeBody.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachment = composeAttachment
    guard !body.isEmpty || attachment != nil, !isSending else { return }
    // Attachment-only or attachment+text: file goes first (so the text reads
    // as the caption under it), each through the gated/locked send path.
    if let attachment {
      isSending = true
      let fileResult = await DraftSender.sendDirectAttachment(target: target, fileURL: attachment)
      isSending = false
      guard fileResult.ok else {
        composeError = fileResult.error ?? "Couldn't send the attachment."
        return
      }
      composeAttachment = nil
      if body.isEmpty {
        // Attachment-only sends have no optimistic row; the new content arrives via
        // this reload. Arm the force-scroll so the thread still advances to it.
        forceScrollOnNextBottomChange = true
        loadMessages(bypassCache: true)
        return
      }
    }
    guard !body.isEmpty, !isSending else { return }
    isSending = true
    let optimisticID = UUID().uuidString.lowercased()
    let optimistic = OptimisticDirectMessage(
      id: optimisticID,
      target: target,
      body: body,
      createdAt: Date(),
      state: .sending,
      errorMessage: nil
    )
    do {
      try validateCurrentTarget(target)
      // Own send always advances to the new message, even if the user had scrolled up.
      forceScrollOnNextBottomChange = true
      optimisticMessages.append(optimistic)
      composeBody = ""
      composeError = nil
      failedInlineDraftID = nil
      let result = await DraftSender.sendDirect(target: target, body: body)
      guard target.isCurrent(conversationID: conversation.id) else {
        isSending = false
        return
      }
      if result.ok {
        markOptimisticMessage(optimisticID, state: .sent, error: nil)
        composeError = nil
        discardComposerDraft()
        if threadPriorities.priority(for: conversation.recent) != nil {
          threadPriorities.clearPriority(for: conversation.recent)
        }
        pollForDirectSendReconciliation(target: target, body: body, optimisticID: optimisticID)
      } else {
        let message = SendErrorCopy.user(for: result.error, platform: conversation.platform)
        markOptimisticMessage(optimisticID, state: .failed, error: message)
        composeBody = body
        composeError = message
      }
    } catch {
      optimisticMessages.removeAll { $0.id == optimisticID }
      composeBody = body
      composeError = error.localizedDescription
    }
    isSending = false
  }

  private func sendReaction(message: ContextMessage, emoji: String) async {
    guard conversation.platform == .whatsapp else { return }
    guard let messageID = message.message_id else {
      composeError = "That message cannot be reacted to yet."
      return
    }
    let target = sendTarget
    do {
      try validateCurrentTarget(target)
      let result = try await WhatsAppRPCClient.sendReaction(
        threadJID: target.handle,
        messageID: messageID,
        emoji: emoji
      )
      guard result.ok else {
        composeError = "That reaction didn't go through. Try again."
        return
      }
      composeError = nil
      loadMessages(bypassCache: true)
    } catch let e as WhatsAppRPCClient.RPCError {
      composeError = e.userFacingMessage(for: .reaction)
    } catch {
      composeError = error.localizedDescription
    }
  }

  private func sendIMessageReaction(message: ContextMessage, emoji: String) async {
    guard conversation.platform == .imessage else { return }
    let target = sendTarget
    do {
      try validateCurrentTarget(target)
      try await IMessageTapbackAutomation.sendReaction(
        handle: target.handle,
        displayName: target.recipientName ?? target.displayName,
        message: message,
        emoji: emoji,
        isGroupConversation: conversation.recent.isGroupConversation
      )
      guard target.isCurrent(conversationID: conversation.id) else { return }
      composeError = nil
      loadMessages(bypassCache: true)
    } catch {
      composeError = error.localizedDescription
    }
  }

  private func resetInlineComposer() {
    composeBody = ""
    // A picked/dropped attachment is thread-scoped state like the body text;
    // it must not follow the selection onto another conversation.
    composeAttachment = nil
    composeError = nil
    isSending = false
    showingScheduleControls = false
    scheduleDate = Date().addingTimeInterval(3600)
    failedInlineDraftID = nil
    optimisticMessages = []
    isLoadingOlderMessages = false
    hasLoadedAllAvailableHistory = false
    suppressNextAutoScroll = false
    initialBottomSnapCompleted = false
    pendingRestoreAnchorID = nil
    pendingDirectSendBottomSnap = false
    forceScrollOnNextBottomChange = false
    nearBottom = true
  }

  // MARK: - Composer auto-save (unsent text persists as a draft once you leave)

  /// Persist (or clear) `body` as `owner`'s auto-save draft. Called on
  /// navigate-away — a thread switch (owner = the thread we left, with empty
  /// context since its transcript is no longer loaded) or a view teardown
  /// (owner = the open thread, with its live transcript). Owner-explicit so it
  /// bypasses the current-thread guard in `createDraft`: on a switch the
  /// conversation has already advanced to the new thread. The reserved source
  /// keeps it distinct from AI/MCP drafts. WhatsApp text only auto-saves when
  /// WhatsApp is on (the create path requires it).
  private func saveComposerDraft(owner: MessageConversation, body: String, contextMessages: [ContextMessage]) {
    let existing = ComposerAutosavePolicy.existingDraft(
      in: store.drafts,
      platform: owner.platform,
      handle: owner.recent.recipient.handle,
      canonicalize: ContactAvatarStore.canonicalKey
    )
    switch ComposerAutosavePolicy.action(forBody: body, existing: existing) {
    case .none:
      return
    case .discard(let id):
      try? store.discard(id: id)
    case .update(let id, let newBody):
      _ = try? store.updateBody(id: id, body: newBody)
    case .create(let newBody):
      let target = MessageSendTarget(conversation: owner)
      switch target.platform {
      case .imessage:
        _ = try? store.createIMessageDraft(
          toHandle: target.handle,
          toHandleName: target.recipientName,
          body: newBody,
          scheduledAt: nil,
          approveScheduledDraft: false,
          contextMessages: contextMessages,
          inReplyToThreadID: target.threadID,
          source: ComposerAutosavePolicy.source
        )
      case .whatsapp:
        guard settings.whatsappEnabled else { return }
        _ = try? store.createWhatsAppDraft(
          toHandle: target.handle,
          toHandleName: target.recipientName ?? target.displayName,
          body: newBody,
          scheduledAt: nil,
          approveScheduledDraft: false,
          contextMessages: contextMessages,
          source: ComposerAutosavePolicy.source
        )
      }
    }
  }

  /// On opening a thread, pull any unsent composer draft back into the box.
  private func restoreComposerDraft() {
    guard composeBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let draft = composerAutosaveDraft else { return }
    composeBody = draft.body
  }

  /// The composer text was sent — drop its auto-save draft (no longer unsent).
  private func discardComposerDraft() {
    if let draft = composerAutosaveDraft { try? store.discard(id: draft.id) }
  }

  /// A drop only fills the composer's attachment slot — the same binding the
  /// NSOpenPanel picker writes — so sending still flows through
  /// sendTypedMessage → sendDirectAttachment (which routes group chats via
  /// their chat GUID).
  private func handleAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
    let candidates = providers.filter { provider in
      provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }
    guard !candidates.isEmpty else { return false }
    let droppedOnConversationID = conversation.id
    loadDropPayloads(from: candidates) { payloads in
      // Provider loading is async; the user may have switched threads first.
      guard conversation.id == droppedOnConversationID else { return }
      switch ComposerDropPolicy.firstAttachable(in: payloads) {
      case .fileURL(let url):
        composeAttachment = url
        composeError = nil
      case .imageData(let data):
        if let url = DroppedImageFile.write(data) {
          composeAttachment = url
          composeError = nil
        } else {
          composeError = "Couldn't read the dropped image."
        }
      case nil:
        break
      }
    }
    return true
  }

  /// At most one payload per dragged item — file URL preferred over raster
  /// data — with the drag's own item order preserved, because the selection
  /// policy's "first attachable wins" is defined over that order.
  private func loadDropPayloads(
    from providers: [NSItemProvider],
    completion: @escaping ([ComposerDropPayload]) -> Void
  ) {
    let group = DispatchGroup()
    let collector = DropPayloadCollector(count: providers.count)
    for (index, provider) in providers.enumerated() {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          if let url {
            collector.store(.fileURL(url), at: index)
          }
          group.leave()
        }
      } else if let typeID = ComposerDropPolicy.imageTypeIdentifier(
        fromRegistered: provider.registeredTypeIdentifiers
      ) {
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
          if let data {
            collector.store(.imageData(data), at: index)
          }
          group.leave()
        }
      }
    }
    group.notify(queue: .main) {
      completion(collector.ordered())
    }
  }

  private func loadOlderMessages() {
    guard !isLoadingOlderMessages,
          !hasLoadedAllAvailableHistory,
          let oldest = messages.first,
          let before = oldest.paginationCursor(platform: conversation.platform) else {
      return
    }
    isLoadingOlderMessages = true
    let restoreAnchorID = visibleMessages.first?.transcriptStableID ?? oldest.transcriptStableID
    let token = messageLoadToken
    // The shared cursor is a message date, valid across every member thread.
    let recent = conversation.recent
    Task {
      let older: [ContextMessage]
      do {
        older = try await recent.loadConsolidatedContext(limit: 120, before: before)
      } catch {
        await MainActor.run {
          guard messageLoadToken == token else { return }
          isLoadingOlderMessages = false
        }
        return
      }
      await MainActor.run {
        guard messageLoadToken == token else { return }
        suppressNextAutoScroll = true
        pendingRestoreAnchorID = TranscriptScrollPolicy.restoreAnchorAfterPrepend(previousOldestVisibleID: restoreAnchorID)
        messages = mergeChronologicalMessages(older + messages)
        hasLoadedAllAvailableHistory = older.count < 120
        isLoadingOlderMessages = false
        onMessagesLoaded(messages, hasLoadedAllAvailableHistory)
      }
    }
  }

  private func adoptWarmCacheIfUseful() {
    guard messages.isEmpty,
          let cachedMessages,
          ThreadMessageCachePolicy.shouldReuse(
            platform: conversation.platform,
            cachedMessages: cachedMessages.messages,
            cachedLastMessageDate: cachedMessages.lastMessageDate,
            currentLastMessageDate: conversation.recent.lastMessageDate
          ) else {
      return
    }
    messages = cachedMessages.messages
    hasLoadedAllAvailableHistory = cachedMessages.hasLoadedAllAvailableHistory
  }

  private func markOptimisticMessage(_ id: String, state: OptimisticDirectMessageState, error: String?) {
    guard let index = optimisticMessages.firstIndex(where: { $0.id == id }) else { return }
    optimisticMessages[index].state = state
    optimisticMessages[index].errorMessage = error
  }

  private func reconcileOptimisticMessages(with loaded: [ContextMessage]) {
    optimisticMessages = OptimisticDirectMessageReconciler.unreconciled(
      optimisticMessages: optimisticMessages,
      transcript: loaded
    )
  }

  private func pollForDirectSendReconciliation(target: MessageSendTarget, body: String, optimisticID: String) {
    let recent = conversation.recent
    Task {
      for attempt in 0..<6 {
        let delay = UInt64(450_000_000 + (attempt * 250_000_000))
        try? await Task.sleep(nanoseconds: delay)
        let loaded = try? await recent.loadConsolidatedContext(limit: 160)
        var settled = false
        await MainActor.run {
          guard target.isCurrent(conversationID: conversation.id),
                optimisticMessages.contains(where: { $0.id == optimisticID }) else {
            settled = true
            return
          }
          guard let loaded else { return }
          let result = DirectSendTranscriptReconciler.reconcile(
            currentMessages: messages,
            optimisticMessages: optimisticMessages,
            loadedMessages: loaded,
            optimisticID: optimisticID
          )
          guard result.shouldApply else { return }
          messages = result.messages
          optimisticMessages = result.optimisticMessages
          hasLoadedAllAvailableHistory = loaded.count < 160
          if result.shouldSnapToBottom {
            pendingDirectSendBottomSnap = true
          }
          onMessagesLoaded(result.messages, hasLoadedAllAvailableHistory)
          settled = result.isSettled
        }
        if settled { break }
      }
    }
  }

  @discardableResult
  private func createDraft(
    target: MessageSendTarget,
    body: String,
    scheduledAt: Date?,
    source: String = "Ghostie UI"
  ) throws -> Draft {
    try validateCurrentTarget(target)
    switch target.platform {
    case .imessage:
      return try store.createIMessageDraft(
        toHandle: target.handle,
        toHandleName: target.recipientName,
        body: body,
        scheduledAt: scheduledAt,
        approveScheduledDraft: scheduledAt != nil,
        contextMessages: visibleMessages.isEmpty ? messages : visibleMessages,
        inReplyToThreadID: target.threadID,
        source: source
      )
    case .whatsapp:
      guard settings.whatsappEnabled else {
        throw NSError(
          domain: "MessagesForAI.WorkPersonal",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Turn on WhatsApp in Settings before sending a WhatsApp message."]
        )
      }
      return try store.createWhatsAppDraft(
        toHandle: target.handle,
        toHandleName: target.recipientName ?? target.displayName,
        body: body,
        scheduledAt: scheduledAt,
        approveScheduledDraft: scheduledAt != nil,
        contextMessages: visibleMessages.isEmpty ? messages : visibleMessages,
        source: source
      )
    }
  }

  private func mergeChronologicalMessages(_ source: [ContextMessage]) -> [ContextMessage] {
    DirectSendTranscriptReconciler.mergeChronologicalMessages(source)
  }

  private func validateCurrentTarget(_ target: MessageSendTarget) throws {
    guard target.isCurrent(conversationID: conversation.id) else {
      throw NSError(
        domain: "MessagesForAI.InlineComposer",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Conversation changed. Try again."]
      )
    }
  }
}

private struct InlineThreadComposer: View {
  @Binding var messageBody: String
  let error: String?
  let isSending: Bool
  @Binding var showingScheduleControls: Bool
  @Binding var scheduleDate: Date
  /// Staging/scheduling route through single-recipient drafts; group chats
  /// support live sends only, so the composer hides those actions there.
  var allowsDrafting: Bool = true
  @Binding var attachment: URL?
  let onSend: () -> Void
  let onStageDraft: () -> Void
  let onSchedule: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var inputHeight: CGFloat = InlineComposerLayoutMetrics.textMinHeight

  var bodyViewIsEmpty: Bool {
    messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil
  }

  private func pickAttachment() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a photo or file to send"
    if panel.runModal() == .OK, let url = panel.url {
      attachment = url
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let attachment {
        HStack(spacing: 6) {
          Image(systemName: "paperclip")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.Color.ink3(colorScheme))
          Text(attachment.lastPathComponent)
            .font(DS.Font.settingsCaption)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
          Button {
            self.attachment = nil
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(DS.Color.ink3(colorScheme))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(DS.Color.g130(colorScheme)))
      }
      HStack(alignment: .center, spacing: InlineComposerLayoutMetrics.rowSpacing) {
        Menu {
          Button {
            pickAttachment()
          } label: {
            Label("Attach Photo or File…", systemImage: "paperclip")
          }
          if allowsDrafting {
          Button {
            onStageDraft()
          } label: {
            Label("Stage Draft", systemImage: "pencil")
          }
          Button {
            showingScheduleControls.toggle()
          } label: {
            Label("Schedule", systemImage: "clock")
          }
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: InlineComposerLayoutMetrics.secondaryIconSize, weight: .semibold))
            .foregroundStyle(DS.Color.ink2(colorScheme))
            .frame(
              width: InlineComposerLayoutMetrics.controlSize,
              height: InlineComposerLayoutMetrics.controlSize
            )
            .background(Circle().fill(DS.Color.g160(colorScheme)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("More message actions")
        .accessibilityLabel("More message actions")

        ZStack(alignment: .topLeading) {
          EnterSendingTextView(
            text: $messageBody,
            measuredHeight: $inputHeight,
            onSubmit: onSend
          )
          .frame(height: inputHeight)
          .padding(.horizontal, InlineComposerLayoutMetrics.textHorizontalPadding)
          .padding(.vertical, InlineComposerLayoutMetrics.textVerticalPadding)
          .background(DS.Color.g050(colorScheme))
          .clipShape(RoundedRectangle(cornerRadius: InlineComposerLayoutMetrics.cornerRadius, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: InlineComposerLayoutMetrics.cornerRadius, style: .continuous)
              .strokeBorder(DS.Color.line2(colorScheme), lineWidth: 1)
          )
          if messageBody.isEmpty {
            Text("Message")
              .font(DS.Font.bubbleBody)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .padding(.horizontal, InlineComposerLayoutMetrics.textHorizontalPadding)
              .padding(.vertical, InlineComposerLayoutMetrics.placeholderVerticalPadding)
              .allowsHitTesting(false)
          }
        }

        Button {
          onSend()
        } label: {
          Image(systemName: isSending ? "circle.dotted" : "arrow.up")
            .font(.system(size: InlineComposerLayoutMetrics.primaryIconSize, weight: .bold))
            .foregroundStyle(sendIconColor)
            .frame(
              width: InlineComposerLayoutMetrics.controlSize,
              height: InlineComposerLayoutMetrics.controlSize
            )
            .background(Circle().fill(sendFill))
        }
        .buttonStyle(.plain)
        .disabled(bodyViewIsEmpty || isSending)
        .help("Send")
        .accessibilityLabel("Send")
      }

      if showingScheduleControls {
        HStack(spacing: 8) {
          Color.clear
            .frame(width: InlineComposerLayoutMetrics.controlSize, height: 1)
          DSDateTimeField(title: "Send after", selection: $scheduleDate, displayedComponents: [.date, .hourAndMinute])
            .frame(maxWidth: 280)
          Button {
            onSchedule()
          } label: {
            Label("Schedule", systemImage: "clock")
          }
          .disabled(bodyViewIsEmpty)
        }
      }

      if let error {
        Text(error)
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.red)
      }
    }
  }

  private var sendFill: Color {
    if bodyViewIsEmpty || isSending {
      return DS.Color.g160(colorScheme)
    }
    return DS.Color.accentTeal(colorScheme)
  }

  private var sendIconColor: Color {
    if bodyViewIsEmpty || isSending {
      return DS.Color.ink3(colorScheme)
    }
    return .white
  }
}

enum InlineComposerLayoutMetrics {
  static let controlSize: CGFloat = 30
  static let rowSpacing: CGFloat = 8
  static let textHorizontalPadding: CGFloat = 12
  static let textVerticalPadding: CGFloat = 5
  static let textMinHeight: CGFloat = controlSize - (textVerticalPadding * 2)
  static let placeholderVerticalPadding: CGFloat = textVerticalPadding + 1
  static let primaryIconSize: CGFloat = 14
  static let secondaryIconSize: CGFloat = 15
  static let maxHeight: CGFloat = 96
  static let cornerRadius: CGFloat = controlSize / 2
}

struct EnterSendingTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var measuredHeight: CGFloat
  let onSubmit: () -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.delegate = context.coordinator
    // Match DS.Font.bubbleBody (13.5) so text doesn't jump size between the
    // placeholder, the editor, and the sent bubble.
    textView.font = NSFont.systemFont(ofSize: 13.5)
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.textContainerInset = NSSize(width: 0, height: 0)
    textView.textContainer?.lineFragmentPadding = 0
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    // NSTextView registers for file drags by default (it would insert the
    // path as text); only plain-text drops may stay local so file/image
    // drags fall through to the pane-level attachment drop target.
    textView.unregisterDraggedTypes()
    textView.registerForDraggedTypes([.string])
    context.coordinator.updateMeasuredHeight(scrollView)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    if textView.string != text {
      textView.string = text
    }
    context.coordinator.update(onSubmit: onSubmit)
    context.coordinator.updateMeasuredHeight(nsView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, measuredHeight: $measuredHeight, onSubmit: onSubmit)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    private var onSubmit: () -> Void

    init(text: Binding<String>, measuredHeight: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
      self._text = text
      self._measuredHeight = measuredHeight
      self.onSubmit = onSubmit
    }

    func update(onSubmit: @escaping () -> Void) {
      self.onSubmit = onSubmit
    }

    func submit() {
      onSubmit()
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
      if let scrollView = textView.enclosingScrollView {
        updateMeasuredHeight(scrollView)
      }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
      switch InlineComposerNewlineAction.action(
        shiftPressed: NSApp.currentEvent?.modifierFlags.contains(.shift) == true
      ) {
      case .insertNewline:
        textView.insertNewlineIgnoringFieldEditor(nil)
      case .submit:
        submit()
      }
      return true
    }

    func updateMeasuredHeight(_ scrollView: NSScrollView) {
      DispatchQueue.main.async { [weak scrollView, weak self] in
        guard let self,
              let scrollView,
              let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let width = max(scrollView.contentSize.width, scrollView.bounds.width)
        guard width > 0 else { return }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        let nextHeight = min(
          max(usedHeight, InlineComposerLayoutMetrics.textMinHeight),
          InlineComposerLayoutMetrics.maxHeight
        )
        if abs(self.measuredHeight - nextHeight) > 0.5 {
          self.measuredHeight = nextHeight
        }
      }
    }
  }
}

extension ContextMessage {
  var transcriptStableID: String {
    [
      guid ?? "",
      from_me ? "me" : "them",
      sender_handle ?? "",
      sender_name ?? "",
      sent_at ?? "",
      body ?? "",
      reactions.map(\.id).joined(separator: "|")
    ].joined(separator: "\u{1F}")
  }

  func paginationCursor(platform: Platform) -> Int64? {
    guard let sentDate else { return nil }
    switch platform {
    case .imessage:
      return Int64((sentDate.timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
    case .whatsapp:
      return Int64(sentDate.timeIntervalSince1970 * 1000)
    }
  }
}

/// Console > Drafts. A thread-first review surface for the "AI proposes, you
/// approve" loop: pick a conversation, read the attached context, then hold to
/// send each staged draft in order. Scheduled messages live in the Scheduled
/// tab so an unsent item is only actionable in one queue.
struct DraftsPane: View {
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var contactsExporter: ContactsExporter
  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedThreadID: String?
  @State private var showingCompose = false

  private var visibleDrafts: [Draft] {
    DraftThread.queueDrafts(store.drafts, scope: .plainDrafts)
  }

  private var threads: [DraftThread] { DraftThread.group(visibleDrafts) }

  private var selectedThread: DraftThread? {
    let id = selectedThreadID ?? threads.first?.id
    return threads.first(where: { $0.id == id }) ?? threads.first
  }

  var body: some View {
    HStack(spacing: 0) {
      conversationColumn
        .frame(minWidth: 300, idealWidth: 348, maxWidth: 380)

      Rectangle()
        .fill(DS.Color.ghostieShellLine(colorScheme))
        .frame(width: 1)

      if let thread = selectedThread {
        DraftThreadDetail(thread: thread)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          emptyState
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(DS.Color.ghostieShellContent(colorScheme))
    .sheet(isPresented: $showingCompose) {
      GlobalComposeSheet(activeThreads: threads) { draft in
        selectedThreadID = DraftThread.group([draft]).first?.id
      }
        .environmentObject(store)
        .environmentObject(settings)
        .frame(width: 560, height: 640)
    }
    .onAppear { syncSelection() }
    .onChange(of: threads.map(\.id)) { syncSelection() }
  }

  private var conversationColumn: some View {
    VStack(spacing: 0) {
      header
        .padding(.top, 28)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)

      if let err = store.lastRefreshError {
        Label(err, systemImage: "exclamationmark.triangle.fill")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24)
          .padding(.bottom, 8)
      }

      DaemonAttentionBanner()

      ContactsPermissionBanner()
        .padding(.horizontal, 24)
        .padding(.bottom, 12)

      Rectangle()
        .fill(DS.Color.ghostieShellLine(colorScheme))
        .frame(height: 1)

      if threads.isEmpty {
        ScrollView {
          emptyState
            .padding(24)
        }
      } else {
        threadList
      }
    }
    .background(DS.Color.ghostieShellRail(colorScheme))
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Drafts")
          .font(DS.Font.paneTitle)
          .foregroundStyle(DS.Color.ghostieShellInk(colorScheme))
        Text("Review staged drafts by conversation. Scheduled messages live in Scheduled.")
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.ghostieShellMuted(colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button {
        showingCompose = true
      } label: {
        Image(systemName: "square.and.pencil")
      }
      .dsIconButton(.secondary)
      .help("Compose")
      .accessibilityLabel("Compose")
    }
  }

  private var threadList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        Text("CONVERSATIONS")
          .font(DS.Font.groupLabel)
          .tracking(2)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .padding(.horizontal, 10)
          .padding(.top, 12)
          .padding(.bottom, 6)
        ForEach(threads) { thread in
          Button {
            withAnimation(.easeInOut(duration: 0.14)) {
              selectedThreadID = thread.id
            }
          } label: {
            DraftThreadRow(thread: thread, selected: selectedThread?.id == thread.id)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 16)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 34))
        .foregroundStyle(.tertiary)
      Text("No drafts waiting")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("When Claude stages an unscheduled message, it shows up here for your approval.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.center)
      Button {
        showingCompose = true
      } label: {
        Label("Compose", systemImage: "square.and.pencil")
      }
      .dsButton(.primary, size: .small)
    }
    .frame(maxWidth: .infinity, minHeight: 320)
  }

  private func syncSelection() {
    guard !threads.isEmpty else {
      selectedThreadID = nil
      return
    }
    if let selectedThreadID, threads.contains(where: { $0.id == selectedThreadID }) {
      return
    }
    selectedThreadID = threads.first?.id
  }
}

struct DraftThread: Identifiable {
  let id: String
  let platform: Platform
  let displayName: String
  let subtitle: String
  let drafts: [Draft]

  var pendingCount: Int { pendingDrafts.count }
  var sentDrafts: [Draft] { drafts.filter(\.isSent).sorted { Self.draftSortDate($0) < Self.draftSortDate($1) } }
  var pendingDrafts: [Draft] { drafts.filter { !$0.isSent }.sorted { Self.draftSortDate($0) < Self.draftSortDate($1) } }
  var scheduledCount: Int { pendingDrafts.filter(\.isScheduled).count }
  var draftCount: Int { pendingDrafts.filter { !$0.isScheduled }.count }
  var sentCount: Int { sentDrafts.count }
  var actionableCount: Int { draftCount + scheduledCount }
  var newestDraft: Draft { drafts.max(by: { Self.draftSortDate($0) < Self.draftSortDate($1) }) ?? drafts[0] }
  var oldestFirstDrafts: [Draft] { pendingDrafts }
  var toHandle: String { newestDraft.to_handle }
  var toHandleName: String? { newestDraft.to_handle_name }
  var isGroupConversation: Bool {
    platform == .whatsapp && toHandle.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("@g.us")
  }

  var contextMessages: [ContextMessage] {
    var seen = Set<String>()
    var merged: [ContextMessage] = []
    for draft in drafts {
      for message in draft.context_messages ?? [] {
        let key = [
          message.from_me ? "me" : "them",
          message.sender_handle ?? "",
          message.sender_name ?? "",
          message.sent_at ?? "",
          message.body ?? ""
        ].joined(separator: "\u{1F}")
        if seen.insert(key).inserted {
          merged.append(message)
        }
      }
    }
    return merged.sorted {
      switch ($0.sentDate, $1.sentDate) {
      case let (a?, b?): return a < b
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return false
      }
    }
  }

  static func group(_ drafts: [Draft]) -> [DraftThread] {
    let grouped = Dictionary(grouping: drafts, by: threadKey)
    return grouped.values.map { groupDrafts in
      let sorted = groupDrafts.sorted { draftSortDate($0) < draftSortDate($1) }
      let sample = sorted.last ?? groupDrafts[0]
      return DraftThread(
        id: threadKey(sample),
        platform: sample.effectivePlatform,
        displayName: sample.recipientDisplayName,
        subtitle: sample.recipientSubtitle ?? "",
        drafts: sorted
      )
    }
    .sorted {
      if draftSortDate($0.newestDraft) == draftSortDate($1.newestDraft) {
        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
      return draftSortDate($0.newestDraft) > draftSortDate($1.newestDraft)
    }
  }

  enum QueueScope {
    case allPending
    case plainDrafts
  }

  static func queueDrafts(_ drafts: [Draft], now: Date = Date(), scope: QueueScope = .allPending) -> [Draft] {
    let isInScope: (Draft) -> Bool = { draft in
      switch scope {
      case .allPending:
        return !draft.isSent
      case .plainDrafts:
        return !draft.isSent && !draft.isScheduled
      }
    }
    let activeDrafts = drafts.filter(isInScope)
    let activeThreadKeys = Set(activeDrafts.map(threadKey))
    guard !activeThreadKeys.isEmpty else { return [] }

    let cutoff = now.addingTimeInterval(-7 * 86_400)
    return drafts.filter { draft in
      if !draft.isSent { return isInScope(draft) }
      return activeThreadKeys.contains(threadKey(draft))
        && (draft.sentDate ?? .distantPast) > cutoff
    }
  }

  static func draftSortDate(_ draft: Draft) -> Date {
    draft.sentDate ?? draft.stagedDate ?? .distantPast
  }

  static func threadKey(_ draft: Draft) -> String {
    let threadPart = draft.in_reply_to_thread_id.map(String.init) ?? draft.to_handle.lowercased()
    return "\(draft.effectivePlatform.rawValue)|\(threadPart)"
  }
}

private struct DraftThreadRow: View {
  let thread: DraftThread
  let selected: Bool
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 11) {
      avatar
      VStack(alignment: .leading, spacing: 3) {
        Text(thread.displayName)
          .font(DS.Font.rowTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
          .lineLimit(1)
          .truncationMode(.tail)
        if !thread.subtitle.isEmpty {
          Text(thread.subtitle)
            .font(DS.Font.monoValue)
            .monospacedDigit()
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 5) {
        HStack(spacing: 5) {
          if thread.draftCount > 0 {
            CountChip(count: thread.draftCount, systemImage: "pencil", tone: .draft)
          }
          if thread.scheduledCount > 0 {
            CountChip(count: thread.scheduledCount, systemImage: "clock", tone: .scheduled)
          }
          if thread.sentCount > 0 {
            CountChip(count: thread.sentCount, systemImage: "checkmark", tone: .sent)
          }
        }
        if thread.platform != .imessage {
          PlatformBadge(platform: thread.platform)
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .fill(rowFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(selected ? DS.Color.line(colorScheme) : .clear, lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.14)) { isHovering = hovering }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var avatar: some View {
    Text(monogram)
      .font(.system(size: 11, weight: .semibold, design: .monospaced))
      .foregroundStyle(thread.platform == .whatsapp ? DS.Color.green(colorScheme) : DS.Color.ink2(colorScheme))
      .frame(width: 34, height: 34)
      .background(
        RoundedRectangle(cornerRadius: DS.Radius.avatar, style: .continuous)
          .fill(DS.Color.g200(colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DS.Radius.avatar, style: .continuous)
          .strokeBorder(thread.platform == .whatsapp ? DS.Color.greenDim(colorScheme) : DS.Color.line2(colorScheme), lineWidth: 1)
      )
      .accessibilityHidden(true)
  }

  private var monogram: String {
    let parts = thread.displayName
      .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
      .compactMap { $0.first }
    let initials = parts.prefix(2).map { String($0).uppercased() }.joined()
    if !initials.isEmpty { return initials }
    return String(thread.displayName.prefix(2)).uppercased()
  }

  private var rowFill: Color {
    if selected { return DS.Color.ghostieShellSelectedStrong(colorScheme) }
    if isHovering { return DS.Color.ghostieShellHover(colorScheme) }
    return .clear
  }

  private var accessibilityLabel: String {
    var parts = [thread.displayName]
    if thread.draftCount > 0 {
      parts.append("\(thread.draftCount) \(thread.draftCount == 1 ? "draft" : "drafts")")
    }
    if thread.scheduledCount > 0 {
      parts.append("\(thread.scheduledCount) scheduled")
    }
    if thread.sentCount > 0 {
      parts.append("\(thread.sentCount) sent")
    }
    return parts.joined(separator: ", ")
  }
}

private enum CountChipTone {
  case draft
  case scheduled
  case sent
}

/// Priority marker for tagged conversations: one tinted flag, no chrome —
/// urgency reads through color weight (amber, blue, neutral) and the level
/// name plus any agent reason live in the tooltip.
private struct PriorityChip: View {
  let level: ThreadPriorityLevel
  let reason: String?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Image(systemName: "flag.fill")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(tint)
      .frame(height: 18)
      .help(helpText)
      .accessibilityLabel("Priority: \(level.title)")
  }

  private var tint: Color {
    switch level {
    case .urgent: return DS.Color.amber(colorScheme)
    case .high: return DS.Color.accentTeal(colorScheme)
    case .elevated: return DS.Color.ink3(colorScheme)
    }
  }

  private var helpText: String {
    if let reason, !reason.isEmpty {
      return "\(level.title) priority: \(reason)"
    }
    return "\(level.title) priority"
  }
}

private struct CountChip: View {
  let count: Int
  let systemImage: String
  let tone: CountChipTone
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: systemImage)
        .font(.system(size: 10, weight: .semibold))
      Text("\(count)")
        .font(.system(size: 10, weight: .semibold))
        .monospacedDigit()
    }
    .padding(.horizontal, 7)
    .frame(height: 18)
    .foregroundStyle(tint)
    .background(Capsule(style: .continuous).fill(fill))
    .accessibilityLabel(accessibilityLabel)
  }

  private var tint: Color {
    switch tone {
    case .draft: return DS.Color.accentTeal(colorScheme)
    case .scheduled: return DS.Color.amber(colorScheme)
    case .sent: return DS.Color.green(colorScheme)
    }
  }

  private var fill: Color {
    switch tone {
    case .draft: return DS.Color.accentTeal(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12)
    case .scheduled: return DS.Color.amberDim(colorScheme)
    case .sent: return DS.Color.greenDim(colorScheme)
    }
  }

  private var accessibilityLabel: String {
    switch tone {
    case .draft:
      return "\(count) \(count == 1 ? "draft" : "drafts")"
    case .scheduled:
      return "\(count) scheduled"
    case .sent:
      return "\(count) sent"
    }
  }
}

private struct DraftThreadDetail: View {
  let thread: DraftThread
  @EnvironmentObject var store: DraftStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      threadHeader
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
      Divider()
        .overlay(DS.Color.ghostieShellLine(colorScheme))
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            if thread.contextMessages.isEmpty {
              contextEmptyState
            } else {
              contextTranscript
            }

            if !thread.sentDrafts.isEmpty {
              ForEach(thread.sentDrafts) { draft in
                ConfirmedMessageBubble(draft: draft)
                  .id("sent-\(draft.id)")
                  .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
              }
            }

            if !thread.pendingDrafts.isEmpty && (!thread.contextMessages.isEmpty || !thread.sentDrafts.isEmpty) {
              activeDivider
            }

            ForEach(thread.pendingDrafts) { draft in
              HStack {
                Spacer(minLength: 0)
                PendingMessageBubble(draft: draft)
              }
              .frame(maxWidth: .infinity, alignment: .trailing)
              .id(draft.id)
              .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 28)
          .padding(.vertical, 18)
          .animation(.spring(response: 0.32, dampingFraction: 0.86), value: thread.drafts.map { "\($0.id)-\($0.sent_at ?? "pending")" })
        }
        .onAppear { scrollToLastDraft(proxy) }
        .onChange(of: thread.pendingDrafts.map(\.id)) { scrollToLastDraft(proxy) }
      }
    }
  }

  private var threadHeader: some View {
    HStack(spacing: 12) {
      Image(systemName: thread.platform == .imessage ? "message.fill" : "phone.bubble.left.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(thread.platform == .imessage ? DS.Color.blue : DS.Color.green(colorScheme))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(thread.displayName)
          .font(DS.Font.detailName)
          .foregroundStyle(DS.Color.ink(colorScheme))
          .lineLimit(1)
          .truncationMode(.tail)
        if !thread.subtitle.isEmpty {
          Text(thread.subtitle)
            .font(DS.Font.monoValue)
            .monospacedDigit()
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer()
      Text(threadLabel)
        .font(DS.Font.pill)
        .tracking(0.6)
        .textCase(.uppercase)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(DS.Color.g080(colorScheme)))
        .foregroundStyle(DS.Color.ink2(colorScheme))
        .overlay(Capsule().strokeBorder(DS.Color.line(colorScheme), lineWidth: 1))
    }
  }

  private var contextTranscript: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(thread.contextMessages.enumerated()), id: \.offset) { idx, message in
        let previous = idx > 0 ? thread.contextMessages[idx - 1] : nil
        let showSender = SenderLabelPolicy.shouldShowSender(
          isGroupConversation: thread.isGroupConversation,
          message: message,
          previous: previous
        )
        ContextBubbleView(message: message, showSender: showSender, platform: thread.platform)
      }
    }
  }

  private var contextEmptyState: some View {
    HStack(spacing: 8) {
      Image(systemName: "text.bubble")
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Text(contextEmptyReason)
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
  }

  private var activeDivider: some View {
    HStack(spacing: 10) {
      Rectangle()
        .fill(DS.Color.line(colorScheme))
        .frame(height: 1)
      Text("Pending messages")
        .font(DS.Font.groupLabel)
        .tracking(2)
        .textCase(.uppercase)
        .foregroundStyle(DS.Color.ink3(colorScheme))
      Rectangle()
        .fill(DS.Color.line(colorScheme))
        .frame(height: 1)
    }
    .padding(.vertical, 8)
  }

  private var threadLabel: String {
    switch (thread.draftCount, thread.scheduledCount) {
    case (0, 0) where thread.sentCount > 0:
      return thread.sentCount == 1 ? "1 confirmed" : "\(thread.sentCount) confirmed"
    case (let drafts, 0):
      return drafts == 1 ? "1 draft" : "\(drafts) drafts"
    case (0, let scheduled):
      return scheduled == 1 ? "1 scheduled" : "\(scheduled) scheduled"
    case (let drafts, let scheduled):
      return "\(drafts) draft\(drafts == 1 ? "" : "s") · \(scheduled) scheduled"
    }
  }

  private var contextEmptyReason: String {
    if let diag = thread.oldestFirstDrafts.compactMap(\.context_diagnostic).first {
      return diag.humanExplanation
    }
    return "No prior thread context is attached to these drafts."
  }

  private func scrollToLastDraft(_ proxy: ScrollViewProxy) {
    let targetID: String?
    if let last = thread.pendingDrafts.last {
      targetID = last.id
    } else if let last = thread.sentDrafts.last {
      targetID = "sent-\(last.id)"
    } else {
      targetID = nil
    }
    guard let targetID else { return }
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo(targetID, anchor: .bottom)
      }
    }
  }

}

private enum ComposeMode: String, Hashable {
  case draft
  case scheduled
}

private struct ConfirmedMessageBubble: View {
  let draft: Draft
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .trailing, spacing: 5) {
      Text(draft.body)
        .font(DS.Font.bubbleBody)
        .foregroundStyle(outgoingTextColor)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 13)
        .padding(.trailing, 17)
        .padding(.vertical, 8)
        .background(outgoingBubbleBackground)
        .frame(maxWidth: 390, alignment: .trailing)

      HStack(spacing: 5) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(DS.Color.green(colorScheme))
        Text(sentLabel)
        if draft.effectivePlatform == .whatsapp {
          WhatsAppTicks()
            .foregroundStyle(DS.Color.waTick(colorScheme))
        }
        if draft.effectivePlatform != .imessage {
          PlatformBadge(platform: draft.effectivePlatform)
        }
      }
      .font(DS.Font.monoMicro)
      .monospacedDigit()
      .foregroundStyle(DS.Color.ink3(colorScheme))
      .help(absoluteSent)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.vertical, 2)
    .transition(.asymmetric(
      insertion: .move(edge: .bottom).combined(with: .opacity),
      removal: .move(edge: .top).combined(with: .opacity)
    ))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Sent message. \(draft.body)")
  }

  @ViewBuilder
  private var outgoingBubbleBackground: some View {
    let shape = DSBubbleShape(tail: .outgoing)
    if draft.effectivePlatform == .imessage {
      shape.fill(
        LinearGradient(
          colors: [DS.Color.imsgBlueTop, DS.Color.imsgBlueBottom],
          startPoint: .top,
          endPoint: .bottom
        )
      )
    } else {
      shape.fill(DS.Color.waOutBg(colorScheme))
    }
  }

  private var outgoingTextColor: Color {
    draft.effectivePlatform == .imessage ? DS.Color.imsgOutText : DS.Color.waOutText(colorScheme)
  }

  private var sentLabel: String {
    guard let sent = draft.sentDate else { return "Sent" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return "Sent \(f.localizedString(for: sent, relativeTo: Date()))"
  }

  private var absoluteSent: String {
    guard let sent = draft.sentDate else { return "" }
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: sent)
  }
}

private struct OptimisticDirectMessageBubble: View {
  let message: OptimisticDirectMessage
  let platform: Platform
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .trailing, spacing: 3) {
      ContextBubbleView(
        message: ContextMessage(
          from_me: true,
          sender_handle: nil,
          sender_name: nil,
          body: message.body,
          sent_at: iso(message.createdAt)
        ),
        showSender: false,
        platform: platform
      )
      HStack(spacing: 5) {
        Image(systemName: statusIcon)
        Text(statusText)
      }
      .font(DS.Font.monoMicro)
      .monospacedDigit()
      .foregroundStyle(statusColor)
      .padding(.trailing, 8)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(statusText)
  }

  private var statusIcon: String {
    switch message.state {
    case .sending: return "paperplane"
    case .sent: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.circle.fill"
    }
  }

  private var statusText: String {
    switch message.state {
    case .sending: return "Sending"
    case .sent: return "Sent"
    case .failed: return message.errorMessage ?? "Failed"
    }
  }

  private var statusColor: Color {
    switch message.state {
    case .failed: return DS.Color.red
    case .sent: return DS.Color.green(colorScheme)
    case .sending: return DS.Color.ink3(colorScheme)
    }
  }

  private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

struct ComposeRecipient: Identifiable, Hashable {
  let id: String
  let title: String
  let subtitle: String
  let handle: String
  let name: String?
  let platform: Platform?
  let threadID: Int?
  let contextMessages: [ContextMessage]?
  var isGroupConversation: Bool {
    platform == .whatsapp && handle.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("@g.us")
  }

  static func from(thread: DraftThread) -> ComposeRecipient? {
    return ComposeRecipient(
      id: "active-\(thread.id)",
      title: thread.displayName,
      subtitle: thread.subtitle,
      handle: thread.toHandle,
      name: thread.toHandleName,
      platform: thread.platform,
      threadID: thread.newestDraft.in_reply_to_thread_id,
      contextMessages: thread.contextMessages.isEmpty ? nil : thread.contextMessages
    )
  }
}

enum WhatsAppMentionFormatter {
  static func render(_ body: String, namesByJIDPrefix: [String: String]) -> String {
    guard !namesByJIDPrefix.isEmpty else { return body }
    let pattern = #"@([0-9]{5,})(?![0-9A-Za-z_@.])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return body }
    var rendered = body as NSString
    let matches = regex.matches(in: body, range: NSRange(location: 0, length: rendered.length))
    for match in matches.reversed() {
      guard match.numberOfRanges > 1 else { continue }
      let jidRange = match.range(at: 1)
      guard jidRange.location != NSNotFound else { continue }
      let jidPrefix = rendered.substring(with: jidRange)
      guard let name = namesByJIDPrefix[jidPrefix]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else { continue }
      rendered = rendered.replacingCharacters(
        in: match.range,
        with: "@\(name.replacingOccurrences(of: "\n", with: " "))"
      ) as NSString
    }
    return rendered as String
  }
}

struct RecentComposeThread: Identifiable, Hashable {
  let id: String
  let platform: Platform
  let handle: String
  let title: String
  let subtitle: String
  let threadID: Int?
  let lastMessageDate: Date?
  var unreadCount: Int = 0
  /// True for iMessage group chats (set by the group loader). WhatsApp
  /// groups are detected by jid suffix.
  var isGroup: Bool = false
  /// AppleScript chat id for the thread — for iMessage groups ("iMessage;+;chat…")
  /// AND, since the SMS-routing fix, for 1:1 chats too ("iMessage;-;+1555…" /
  /// "SMS;-;+1555…"). The GUID prefix encodes the chat's service, so sending to
  /// `chat id` routes through the right transport instead of guessing iMessage.
  var chatGUID: String? = nil
  /// The chat's service, from chat.db `chat.service_name`: "iMessage" | "SMS" |
  /// "RCS". Drives the SMS row badge and lets sends honor the thread's transport.
  /// nil when unknown (older rows, WhatsApp).
  var serviceName: String? = nil
  /// Snippet of the newest message, Messages.app-style. Empty when the
  /// platform can't provide one cheaply (encrypted WhatsApp bodies).
  var lastMessagePreview: String = ""
  /// True when the newest message in the thread is outbound (from me). Lets
  /// surfaces like the birthday nudge resolve once you've actually replied/sent.
  var lastMessageFromMe: Bool = false
  /// Older 1:1 threads folded into this row by
  /// ConversationConsolidationPolicy — the same Contacts person reached on
  /// other handles (phone vs. iCloud email). Always empty on raw SQL rows
  /// and on every sibling. The row keeps the NEWEST member's identity, so
  /// everything keyed off `id`/`handle`/`threadID` (read ledger, priority
  /// entries, send target) follows the newest thread; outbound sends go to
  /// the newest handle's thread — the one this row represents.
  var consolidatedSiblings: [RecentComposeThread] = []
  var isGroupConversation: Bool {
    isGroup || (platform == .whatsapp && handle.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("@g.us"))
  }

  /// Canonical keys across every member handle (row + folded siblings):
  /// selection, deep links, and compose dedupe must keep matching a person
  /// reached via a handle that was merged away.
  var canonicalHandleKeys: Set<String> {
    Set(([handle] + consolidatedSiblings.map(\.handle)).compactMap(ContactAvatarStore.canonicalKey))
  }

  /// True when any member handle canonicalizes onto one of `other`'s.
  func sharesHandle(with other: RecentComposeThread) -> Bool {
    !canonicalHandleKeys.isDisjoint(with: other.canonicalHandleKeys)
  }

  /// DB unread across every member thread — a merged row shows the dot when
  /// ANY member has unread messages.
  var aggregateUnreadCount: Int {
    consolidatedSiblings.reduce(unreadCount) { $0 + $1.unreadCount }
  }

  /// Transcript page for the row: a plain fetch for unmerged rows; for a
  /// consolidated row, loadContext per member thread (shared limit + cursor)
  /// unioned chronologically and deduped by guid, capped by
  /// ConversationConsolidationPolicy.unionTranscriptPage so older-page
  /// cursors stay gap-free. Sends are NOT unioned: they target the newest
  /// handle's thread — the one this row's handle/threadID represent.
  func loadConsolidatedContext(limit: Int, before: Int64? = nil) async throws -> [ContextMessage] {
    guard !consolidatedSiblings.isEmpty else {
      return try await Self.loadContextAsyncThrowing(for: recipient, limit: limit, before: before)
    }
    // The row thread's failure propagates (callers retry on it); a sibling
    // failure degrades to a partial union rather than blanking the thread.
    var fetches = [try await Self.loadContextAsyncThrowing(for: recipient, limit: limit, before: before)]
    for sibling in consolidatedSiblings {
      fetches.append(
        (try? await Self.loadContextAsyncThrowing(for: sibling.recipient, limit: limit, before: before)) ?? []
      )
    }
    return ConversationConsolidationPolicy.unionTranscriptPage(fetches, limit: limit)
  }

  /// One recency page across all sources, strictly older than `before`
  /// (nil = the newest page). Each source fetches its own top `pageSize`
  /// older than the shared cursor; ConversationPagingPolicy.assemblePage
  /// keeps the global top slice so one cursor stays correct across three
  /// independent sources.
  static func loadPage(
    before: Date?,
    pageSize: Int = ConversationPagingPolicy.pageSize,
    includeWhatsApp: Bool
  ) -> (threads: [RecentComposeThread], hasMore: Bool) {
    var imessage: [RecentComposeThread] = []
    var imessageGroups: [RecentComposeThread] = []
    var whatsapp: [RecentComposeThread] = []
    var previews: [Int: String] = [:]
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      imessage = loadIMessage(limit: pageSize, before: before)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      imessageGroups = loadIMessageGroups(limit: pageSize, before: before)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      previews = loadIMessagePreviews()
      group.leave()
    }
    if includeWhatsApp {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        whatsapp = loadWhatsApp(limit: pageSize, before: before)
        group.leave()
      }
    }
    group.wait()
    let withPreviews = (imessage + imessageGroups).map { thread -> RecentComposeThread in
      guard let chatID = thread.threadID, let preview = previews[chatID], !preview.isEmpty else {
        return thread
      }
      var copy = thread
      copy.lastMessagePreview = preview
      return copy
    }
    let assembled = ConversationPagingPolicy.assemblePage(
      candidates: withPreviews + whatsapp,
      pageSize: pageSize
    )
    return (assembled.page, assembled.hasMore)
  }

  /// Whole-history identity fetch for conversation search (no previews —
  /// search only needs identity + recency). Bounded high rather than
  /// unbounded so a pathological database can't make the debounced search
  /// allocate forever.
  static func searchAllTime(includeWhatsApp: Bool, limit: Int = 4000) -> [RecentComposeThread] {
    var imessage: [RecentComposeThread] = []
    var imessageGroups: [RecentComposeThread] = []
    var whatsapp: [RecentComposeThread] = []
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      imessage = loadIMessage(limit: limit)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      imessageGroups = loadIMessageGroups(limit: limit)
      group.leave()
    }
    if includeWhatsApp {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        whatsapp = loadWhatsApp(limit: limit)
        group.leave()
      }
    }
    group.wait()
    return imessage + imessageGroups + whatsapp
  }

  /// Load both platforms' thread lists concurrently, all-time, with the
  /// legacy per-source limits. The Messages tab pages via `loadPage`; this
  /// bulk loader remains for `MessageConversation.load` consumers (the
  /// notification poller).
  static func loadAll(includeWhatsApp: Bool) -> [RecentComposeThread] {
    var imessage: [RecentComposeThread] = []
    var imessageGroups: [RecentComposeThread] = []
    var whatsapp: [RecentComposeThread] = []
    var previews: [Int: String] = [:]
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      imessage = loadIMessage(limit: 260)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      imessageGroups = loadIMessageGroups(limit: 80)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      previews = loadIMessagePreviews()
      group.leave()
    }
    if includeWhatsApp {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        whatsapp = loadWhatsApp(limit: 160)
        group.leave()
      }
    }
    group.wait()
    let withPreviews = (imessage + imessageGroups).map { thread -> RecentComposeThread in
      guard let chatID = thread.threadID, let preview = previews[chatID], !preview.isEmpty else {
        return thread
      }
      var copy = thread
      copy.lastMessagePreview = preview
      return copy
    }
    return withPreviews + whatsapp
  }

  /// Newest-message snippet per chat in one pass. Uses SQLite's bare-column
  /// guarantee: with MAX(date) as the only aggregate, the bare columns come
  /// from that newest row.
  private static func loadIMessagePreviews() -> [Int: String] {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return [:] }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return [:]
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT cmj.chat_id,
             MAX(m.date),
             m.text,
             m.attributedBody,
             m.associated_message_type,
             m.cache_has_attachments
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE (m.text IS NOT NULL AND length(trim(m.text)) > 0)
         OR m.attributedBody IS NOT NULL
         OR m.cache_has_attachments = 1
         OR (m.associated_message_type >= 2000 AND m.associated_message_type <= 3999)
      GROUP BY cmj.chat_id
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
    defer { sqlite3_finalize(stmt) }

    var previews: [Int: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      let textCol = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
      let attributed: Data? = {
        guard let blob = sqlite3_column_blob(stmt, 3) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 3))
        guard count > 0 else { return nil }
        return Data(bytes: blob, count: count)
      }()
      let associatedType = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
      let hasAttachments = sqlite3_column_int(stmt, 5) == 1
      var preview = displayBody(
        textCol: textCol,
        attributedBody: attributed,
        associatedMessageType: associatedType
      )
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if preview.isEmpty, hasAttachments {
        preview = "Attachment"
      }
      if !preview.isEmpty {
        previews[chatID] = preview
      }
    }
    return previews
  }

  /// Cheap change probe for the cached thread list: bumps when any message
  /// arrives (MAX(ROWID) / MAX(last_message_ts)) or read state shifts. Runs
  /// on a background queue; never blocks the UI.
  static func dataFingerprint(includeWhatsApp: Bool) -> String {
    var parts = ["im:\(imessageFingerprint())"]
    if includeWhatsApp {
      parts.append("wa:\(whatsappFingerprint())")
    }
    return parts.joined(separator: "|")
  }

  private static func imessageFingerprint() -> String {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return "none" }
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return "err"
    }
    defer { sqlite3_close(db) }
    let sql = """
      SELECT MAX(ROWID),
             (SELECT COUNT(*) FROM message WHERE is_read = 0 AND is_from_me = 0)
      FROM message
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return "err" }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return "err" }
    return "\(sqlite3_column_int64(stmt, 0)):\(sqlite3_column_int64(stmt, 1))"
  }

  private static func whatsappFingerprint() -> String {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent(".whatsapp-mcp")
      .appendingPathComponent("messages.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return "none" }
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return "err"
    }
    defer { sqlite3_close(db) }
    let sql = "SELECT MAX(last_message_ts), MAX(COALESCE(last_seen_at, 0)) FROM threads"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return "err" }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return "err" }
    return "\(sqlite3_column_int64(stmt, 0)):\(sqlite3_column_int64(stmt, 1))"
  }

  var recipient: ComposeRecipient {
    ComposeRecipient(
      id: "recent-\(id)",
      title: title,
      subtitle: subtitle,
      handle: handle,
      name: title == handle ? nil : title,
      platform: platform,
      threadID: threadID,
      contextMessages: nil
    )
  }

  static func loadIMessage(limit: Int = 40, before: Date? = nil) -> [RecentComposeThread] {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT c.ROWID,
             c.display_name,
             h.id,
             MAX(m.date),
             SUM(CASE WHEN m.is_read = 0 AND m.is_from_me = 0 THEN 1 ELSE 0 END),
             MAX(CASE WHEN m.is_from_me = 1 THEN m.date END),
             c.guid,
             c.service_name
      FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      JOIN handle h ON h.ROWID = chj.handle_id
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE (
        SELECT COUNT(*)
        FROM chat_handle_join one_to_one
        WHERE one_to_one.chat_id = c.ROWID
      ) = 1
      GROUP BY c.ROWID, h.id, c.guid, c.service_name
      HAVING (? IS NULL OR MAX(m.date) < ?)
      ORDER BY MAX(m.date) DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    if let before {
      let raw = imessageRawDate(before)
      sqlite3_bind_int64(stmt, 1, raw)
      sqlite3_bind_int64(stmt, 2, raw)
    } else {
      sqlite3_bind_null(stmt, 1)
      sqlite3_bind_null(stmt, 2)
    }
    sqlite3_bind_int(stmt, 3, Int32(limit))

    let resolver = ContactNameResolver.load()
    var rows: [RecentComposeThread] = []
    var seenHandles = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      let chatName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let handlePtr = sqlite3_column_text(stmt, 2) else { continue }
      let handle = String(cString: handlePtr).trimmingCharacters(in: .whitespacesAndNewlines)
      let lastDateRaw = sqlite3_column_int64(stmt, 3)
      let lastMessageDate = imessageDate(lastDateRaw)
      let unreadCount = Int(sqlite3_column_int64(stmt, 4))
      let lastFromMe = sqlite3_column_type(stmt, 5) != SQLITE_NULL && sqlite3_column_int64(stmt, 5) == lastDateRaw
      let chatGUID = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
      let serviceName = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
      guard !handle.isEmpty, seenHandles.insert(handle.lowercased()).inserted else { continue }
      let resolvedName = resolver.name(for: handle)
      let title = preferredDisplayTitle(
        chatName: chatName,
        resolvedName: resolvedName,
        fallback: handle
      )
      rows.append(
        RecentComposeThread(
          id: "imessage-\(chatID)",
          platform: .imessage,
          handle: handle,
          title: title,
          subtitle: resolvedName == nil ? handle : "",
          threadID: chatID,
          lastMessageDate: lastMessageDate,
          unreadCount: max(0, unreadCount),
          chatGUID: chatGUID,
          serviceName: serviceName,
          lastMessageFromMe: lastFromMe
        )
      )
    }
    return rows
  }

  /// Load specific iMessage 1:1 threads by chat ROWID, regardless of recency.
  /// Used to surface prioritized threads (Keep Tabs / Don't Ghost) that have
  /// drifted out of the recent window so the Messages priority queue can still
  /// float them. Same row shape as `loadIMessage`.
  static func loadIMessageThreads(chatIDs: [Int]) -> [RecentComposeThread] {
    guard !chatIDs.isEmpty else { return [] }
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }

    let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
    let sql = """
      SELECT c.ROWID,
             c.display_name,
             h.id,
             MAX(m.date),
             SUM(CASE WHEN m.is_read = 0 AND m.is_from_me = 0 THEN 1 ELSE 0 END),
             MAX(CASE WHEN m.is_from_me = 1 THEN m.date END),
             c.guid,
             c.service_name
      FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      JOIN handle h ON h.ROWID = chj.handle_id
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE c.ROWID IN (\(placeholders))
        AND (
          SELECT COUNT(*)
          FROM chat_handle_join one_to_one
          WHERE one_to_one.chat_id = c.ROWID
        ) = 1
      GROUP BY c.ROWID, h.id, c.guid, c.service_name
      ORDER BY MAX(m.date) DESC
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    for (index, id) in chatIDs.enumerated() {
      sqlite3_bind_int64(stmt, Int32(index + 1), Int64(id))
    }

    let resolver = ContactNameResolver.load()
    var rows: [RecentComposeThread] = []
    var seenHandles = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      let chatName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let handlePtr = sqlite3_column_text(stmt, 2) else { continue }
      let handle = String(cString: handlePtr).trimmingCharacters(in: .whitespacesAndNewlines)
      let lastDateRaw = sqlite3_column_int64(stmt, 3)
      let lastMessageDate = imessageDate(lastDateRaw)
      let unreadCount = Int(sqlite3_column_int64(stmt, 4))
      let lastFromMe = sqlite3_column_type(stmt, 5) != SQLITE_NULL && sqlite3_column_int64(stmt, 5) == lastDateRaw
      let chatGUID = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
      let serviceName = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
      guard !handle.isEmpty, seenHandles.insert(handle.lowercased()).inserted else { continue }
      let resolvedName = resolver.name(for: handle)
      let title = preferredDisplayTitle(chatName: chatName, resolvedName: resolvedName, fallback: handle)
      rows.append(
        RecentComposeThread(
          id: "imessage-\(chatID)",
          platform: .imessage,
          handle: handle,
          title: title,
          subtitle: resolvedName == nil ? handle : "",
          threadID: chatID,
          lastMessageDate: lastMessageDate,
          unreadCount: max(0, unreadCount),
          chatGUID: chatGUID,
          serviceName: serviceName,
          lastMessageFromMe: lastFromMe
        )
      )
    }
    return rows
  }

  /// iMessage group chats (>1 participant). Read-only in the Messages tab —
  /// the send path is single-buddy AppleScript, so the composer is hidden for
  /// these — but parity demands they exist in the list at all.
  static func loadIMessageGroups(limit: Int = 80, before: Date? = nil) -> [RecentComposeThread] {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT c.ROWID,
             c.display_name,
             c.chat_identifier,
             MAX(m.date),
             SUM(CASE WHEN m.is_read = 0 AND m.is_from_me = 0 THEN 1 ELSE 0 END),
             (SELECT GROUP_CONCAT(h2.id, ',')
              FROM chat_handle_join chj2
              JOIN handle h2 ON h2.ROWID = chj2.handle_id
              WHERE chj2.chat_id = c.ROWID),
             c.guid
      FROM chat c
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE (
        SELECT COUNT(*)
        FROM chat_handle_join members
        WHERE members.chat_id = c.ROWID
      ) > 1
      GROUP BY c.ROWID
      HAVING (? IS NULL OR MAX(m.date) < ?)
      ORDER BY MAX(m.date) DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    if let before {
      let raw = imessageRawDate(before)
      sqlite3_bind_int64(stmt, 1, raw)
      sqlite3_bind_int64(stmt, 2, raw)
    } else {
      sqlite3_bind_null(stmt, 1)
      sqlite3_bind_null(stmt, 2)
    }
    sqlite3_bind_int(stmt, 3, Int32(limit))

    let resolver = ContactNameResolver.load()
    var rows: [RecentComposeThread] = []
    // chat.db keeps separate chat rows for the same group across service
    // transitions (SMS↔iMessage); dedup on the participant set, keeping the
    // most recent (rows arrive date-desc).
    var seenParticipantSets = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      let chatName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let chatIdentifier = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "group-\(chatID)"
      let lastMessageDate = imessageDate(sqlite3_column_int64(stmt, 3))
      let unreadCount = Int(sqlite3_column_int64(stmt, 4))
      let participantsRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
      let chatGUID = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
      let participants = participantsRaw
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      guard participants.count > 1 else { continue }
      let participantKey = participants.map { $0.lowercased() }.sorted().joined(separator: "|")
      guard seenParticipantSets.insert(participantKey).inserted else { continue }

      let title: String
      if let chatName, !chatName.isEmpty {
        title = chatName
      } else {
        title = Self.groupTitle(participants: participants, resolver: resolver)
      }
      rows.append(
        RecentComposeThread(
          id: "imessage-\(chatID)",
          platform: .imessage,
          handle: chatIdentifier,
          title: title,
          subtitle: "\(participants.count + 1) people",
          threadID: chatID,
          lastMessageDate: lastMessageDate,
          unreadCount: max(0, unreadCount),
          isGroup: true,
          chatGUID: chatGUID
        )
      )
    }
    return rows
  }

  /// Messages.app-style fallback name: first names of the first few members.
  fileprivate static func groupTitle(participants: [String], resolver: ContactNameResolver) -> String {
    let names = participants.map { handle -> String in
      guard let full = resolver.name(for: handle) else { return handle }
      return full.split(separator: " ").first.map(String.init) ?? full
    }
    let shown = names.prefix(3)
    let remainder = names.count - shown.count
    var title = shown.joined(separator: ", ")
    if remainder > 0 {
      title += " +\(remainder)"
    }
    return title
  }

  static func loadWhatsApp(limit: Int = 30, before: Date? = nil) -> [RecentComposeThread] {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent(".whatsapp-mcp")
      .appendingPathComponent("messages.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT threads.thread_jid,
             COALESCE(threads.display_name, contacts.display_name, contacts.push_name) AS display_name,
             threads.last_message_ts,
             CASE WHEN threads.last_seen_at IS NULL THEN 0 ELSE (
               SELECT COUNT(*) FROM messages mm
               WHERE mm.thread_jid = threads.thread_jid
                 AND mm.from_me = 0
                 AND mm.ts > threads.last_seen_at
             ) END
      FROM threads
      LEFT JOIN contacts ON contacts.jid = threads.thread_jid
      WHERE EXISTS (
        SELECT 1 FROM messages WHERE messages.thread_jid = threads.thread_jid
      )
        AND (? IS NULL OR threads.last_message_ts < ?)
      ORDER BY threads.last_message_ts DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    if let before {
      // threads.last_message_ts is epoch milliseconds.
      let raw = Int64(before.timeIntervalSince1970 * 1000.0)
      sqlite3_bind_int64(stmt, 1, raw)
      sqlite3_bind_int64(stmt, 2, raw)
    } else {
      sqlite3_bind_null(stmt, 1)
      sqlite3_bind_null(stmt, 2)
    }
    sqlite3_bind_int(stmt, 3, Int32(limit))

    let resolver = ContactNameResolver.load()
    var rows: [RecentComposeThread] = []
    var seenJids = Set<String>()
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let jidPtr = sqlite3_column_text(stmt, 0) else { continue }
      let jid = String(cString: jidPtr).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !jid.isEmpty, seenJids.insert(jid.lowercased()).inserted else { continue }
      let dbName = sqlite3_column_text(stmt, 1).map { String(cString: $0) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let lastMessageDate = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000)
      let subtitle = Self.prettyWhatsAppHandle(jid)
      let resolvedName = resolver.name(for: jid)
      let title: String
      let hasDisplayName: Bool
      if jid.hasSuffix("@g.us") {
        title = (dbName?.isEmpty == false ? dbName : nil)
          ?? resolvedName
          ?? subtitle
        hasDisplayName = dbName?.isEmpty == false || resolvedName != nil
      } else {
        title = preferredDisplayTitle(
          chatName: dbName,
          resolvedName: resolvedName,
          fallback: subtitle
        )
        hasDisplayName = resolvedName != nil
      }
      rows.append(
        RecentComposeThread(
          id: "whatsapp-\(jid)",
          platform: .whatsapp,
          handle: jid,
          title: title,
          subtitle: hasDisplayName ? "" : subtitle,
          threadID: nil,
          lastMessageDate: lastMessageDate,
          unreadCount: max(0, Int(sqlite3_column_int64(stmt, 3)))
        )
      )
    }
    return rows
  }

  static func loadContext(for recipient: ComposeRecipient, limit: Int = 10, before: Int64? = nil) -> [ContextMessage] {
    switch recipient.platform {
    case .imessage:
      guard let threadID = recipient.threadID else { return [] }
      return loadIMessageContext(chatID: threadID, limit: limit, before: before)
    case .whatsapp:
      return []
    case nil:
      return []
    }
  }

  static func loadContextAsync(for recipient: ComposeRecipient, limit: Int = 10) async -> [ContextMessage] {
    (try? await loadContextAsyncThrowing(for: recipient, limit: limit)) ?? []
  }

  static func loadContextAsyncThrowing(
    for recipient: ComposeRecipient,
    limit: Int = 10,
    before: Int64? = nil
  ) async throws -> [ContextMessage] {
    switch recipient.platform {
    case .whatsapp:
      return try await WhatsAppRPCClient.getThread(threadJID: recipient.handle, limit: limit, beforeTimestamp: before)
    case .imessage, nil:
      return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(returning: loadContext(for: recipient, limit: limit, before: before))
        }
      }
    }
  }

  private static func loadIMessageContext(chatID: Int, limit: Int, before: Int64? = nil) -> [ContextMessage] {
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Library")
      .appendingPathComponent("Messages")
      .appendingPathComponent("chat.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT m.guid, m.date, m.is_from_me, h.id, m.text, m.attributedBody, m.associated_message_type,
             m.date_delivered, m.date_read, m.ROWID, m.cache_has_attachments
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE cmj.chat_id = ?
        AND (? IS NULL OR m.date < ?)
        AND (
          (m.text IS NOT NULL AND length(trim(m.text)) > 0)
          OR m.attributedBody IS NOT NULL
          OR m.cache_has_attachments = 1
          OR (m.associated_message_type >= 2000 AND m.associated_message_type <= 3999)
        )
      ORDER BY m.date DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(chatID))
    if let before {
      sqlite3_bind_int64(stmt, 2, before)
      sqlite3_bind_int64(stmt, 3, before)
    } else {
      sqlite3_bind_null(stmt, 2)
      sqlite3_bind_null(stmt, 3)
    }
    sqlite3_bind_int(stmt, 4, Int32(limit))

    let resolver = ContactNameResolver.load()
    var rows: [ContextMessage] = []
    var rowIndexByMessageRowID: [Int64: Int] = [:]
    var attachmentMessageRowIDs: [Int64] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let guid = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
      let sentAt = imessageDate(sqlite3_column_int64(stmt, 1))
      let fromMe = sqlite3_column_int(stmt, 2) == 1
      let handle = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
      let textCol = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
      let attributed: Data? = {
        guard let blob = sqlite3_column_blob(stmt, 5) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 5))
        guard count > 0 else { return nil }
        return Data(bytes: blob, count: count)
      }()
      let associatedType = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
      // Tapback rows never render as standalone bubbles — skip them here.
      // They are NOT collected from this page scan either: after the visible
      // rows are known, loadTapbackEventsForTargets queries every tapback
      // aimed at those rows (in-page or not), which fully covers the in-page
      // ones. Collecting them here too would double-count.
      if let associatedType, isTapback(associatedType) {
        continue
      }
      let body = displayBody(
        textCol: textCol,
        attributedBody: attributed,
        associatedMessageType: associatedType
      )
        .replacingOccurrences(of: "\u{FFFC}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let messageRowID = sqlite3_column_int64(stmt, 9)
      let hasAttachments = sqlite3_column_int(stmt, 10) == 1
      guard !body.isEmpty || hasAttachments else { continue }
      var message = ContextMessage(
        guid: guid,
        from_me: fromMe,
        sender_handle: fromMe ? nil : handle,
        sender_name: fromMe ? nil : handle.flatMap { resolver.name(for: $0) },
        body: body.isEmpty ? nil : body,
        sent_at: iso(sentAt)
      )
      if fromMe {
        let deliveredRaw = sqlite3_column_int64(stmt, 7)
        let readRaw = sqlite3_column_int64(stmt, 8)
        if deliveredRaw > 0 { message.deliveredAt = imessageDate(deliveredRaw) }
        if readRaw > 0 { message.readAt = imessageDate(readRaw) }
      }
      rows.append(message)
      if hasAttachments {
        rowIndexByMessageRowID[messageRowID] = rows.count - 1
        attachmentMessageRowIDs.append(messageRowID)
      }
    }
    if !attachmentMessageRowIDs.isEmpty {
      let attachmentsByRowID = loadAttachmentRefs(db: db, messageRowIDs: attachmentMessageRowIDs)
      for (messageRowID, attachments) in attachmentsByRowID {
        if let index = rowIndexByMessageRowID[messageRowID] {
          rows[index].attachments = attachments
        }
      }
      // A message that flagged attachments but resolved none (hidden link
      // previews, expired transfers) and has no text renders as nothing —
      // drop it rather than show an empty bubble.
      rows = rows.filter { $0.body != nil || !$0.attachments.isEmpty }
    }
    let targetGUIDs = rows.compactMap(\.guid)
    let tapbackEvents = loadTapbackEventsForTargets(
      db: db,
      chatID: chatID,
      targetGUIDs: targetGUIDs,
      resolver: resolver
    )
    let reactionsByMessageGUID = foldTapbacks(tapbackEvents)
    return rows
      .reversed()
      .map { message in
        guard let guid = message.guid,
              let reactions = reactionsByMessageGUID[guid],
              !reactions.isEmpty else {
          return message
        }
        return message.attachingReactions(sortedReactions(reactions))
      }
  }

  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
  }

  private static func escapeLikePattern(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  /// Load tapback rows that target the visible messages, even when the
  /// tapback event itself is newer than / outside the current transcript page.
  private static func loadTapbackEventsForTargets(
    db: OpaquePointer,
    chatID: Int,
    targetGUIDs: [String],
    resolver: ContactNameResolver
  ) -> [TapbackEvent] {
    guard hasColumn(db, table: "message", column: "associated_message_guid") else { return [] }
    let uniqueGUIDs = Array(Set(targetGUIDs.filter { !$0.isEmpty })).sorted()
    guard !uniqueGUIDs.isEmpty else { return [] }
    let hasAssociatedMessageEmoji = hasColumn(db, table: "message", column: "associated_message_emoji")
    let associatedEmojiSelect = hasAssociatedMessageEmoji ? "m.associated_message_emoji" : "NULL"
    let clauses = uniqueGUIDs
      .map { _ in "(m.associated_message_guid = ? OR m.associated_message_guid = ? OR m.associated_message_guid LIKE ? ESCAPE '\\')" }
      .joined(separator: " OR ")
    let sql = """
      SELECT m.associated_message_type, m.associated_message_guid, m.date, m.is_from_me, h.id, \(associatedEmojiSelect)
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE cmj.chat_id = ?
        AND m.associated_message_type >= 2000
        AND m.associated_message_type <= 3999
        AND (\(clauses))
      ORDER BY m.date DESC
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(chatID))
    var bindIndex: Int32 = 2
    for guid in uniqueGUIDs {
      bindText(stmt, bindIndex, guid)
      bindIndex += 1
      bindText(stmt, bindIndex, "bp:\(guid)")
      bindIndex += 1
      bindText(stmt, bindIndex, "p:%/\(escapeLikePattern(guid))")
      bindIndex += 1
    }

    var events: [TapbackEvent] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let associatedType = Int(sqlite3_column_int(stmt, 0))
      guard let targetGUID = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) else { continue }
      let sentAt = imessageDate(sqlite3_column_int64(stmt, 2))
      let fromMe = sqlite3_column_int(stmt, 3) == 1
      let handle = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
      let emoji = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
      events.append(
        TapbackEvent(
          associatedMessageType: associatedType,
          targetGUID: targetGUID,
          fromMe: fromMe,
          senderHandle: fromMe ? nil : handle,
          senderName: fromMe ? nil : handle.flatMap { resolver.name(for: $0) },
          sentAt: sentAt,
          emoji: emoji
        )
      )
    }
    return events
  }

  /// Resolve the attachment rows for a window of messages in one IN query.
  private static func loadAttachmentRefs(
    db: OpaquePointer,
    messageRowIDs: [Int64]
  ) -> [Int64: [MessageAttachmentRef]] {
    guard !messageRowIDs.isEmpty else { return [:] }
    let hideClause = hasColumn(db, table: "attachment", column: "hide_attachment")
      ? "AND COALESCE(a.hide_attachment, 0) = 0"
      : ""
    let placeholders = Array(repeating: "?", count: messageRowIDs.count).joined(separator: ",")
    let sql = """
      SELECT maj.message_id, a.filename, a.mime_type, a.transfer_name, a.total_bytes
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id IN (\(placeholders)) \(hideClause)
      ORDER BY maj.message_id, a.ROWID
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
    defer { sqlite3_finalize(stmt) }
    for (offset, rowID) in messageRowIDs.enumerated() {
      sqlite3_bind_int64(stmt, Int32(offset + 1), rowID)
    }
    var result: [Int64: [MessageAttachmentRef]] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      let messageRowID = sqlite3_column_int64(stmt, 0)
      let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
      let mimeType = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
      let name = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
      let bytes = Int(sqlite3_column_int64(stmt, 4))
      result[messageRowID, default: []].append(
        MessageAttachmentRef(path: path, mimeType: mimeType, name: name, byteCount: max(0, bytes))
      )
    }
    return result
  }

  private static func loadWhatsAppContext(threadJID: String, limit: Int) -> [ContextMessage] {
    // WhatsApp message bodies are encrypted at rest in v0.5.3+. UI reads must
    // go through WhatsAppRPCClient.getThread so the daemon decrypts them.
    return []
#if false
    let dbURL = AppStoragePaths.homeDirectory
      .appendingPathComponent(".whatsapp-mcp")
      .appendingPathComponent("messages.db")
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }

    let mentionNames = loadWhatsAppMentionNames(db: db)
    let sql = """
      SELECT m.ts,
             m.from_me,
             m.sender_jid,
             COALESCE(c.display_name, c.push_name) AS sender_name,
             m.body,
             m.body_full
      FROM messages m
      LEFT JOIN contacts c ON c.jid = m.sender_jid
      WHERE m.thread_jid = ?
        AND (
          (m.body IS NOT NULL AND length(trim(m.body)) > 0)
          OR m.body_full IS NOT NULL
        )
      ORDER BY m.ts DESC
      LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, threadJID, -1, transient)
    sqlite3_bind_int(stmt, 2, Int32(limit))

    var rows: [ContextMessage] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let ts = sqlite3_column_int64(stmt, 0)
      let fromMe = sqlite3_column_int(stmt, 1) == 1
      let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
      let senderName = sqlite3_column_text(stmt, 3).map { String(cString: $0) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let bodyCol = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
      let bodyFull: String? = {
        guard let blob = sqlite3_column_blob(stmt, 5) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 5))
        guard count > 0 else { return nil }
        return String(data: Data(bytes: blob, count: count), encoding: .utf8)
      }()
      let rawBody = (bodyFull ?? bodyCol ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let body = WhatsAppMentionFormatter.render(rawBody, namesByJIDPrefix: mentionNames)
      guard !body.isEmpty else { continue }
      rows.append(
        ContextMessage(
          from_me: fromMe,
          sender_handle: fromMe ? nil : sender,
          sender_name: fromMe ? nil : (senderName?.isEmpty == false ? senderName : nil),
          body: body,
          sent_at: iso(Date(timeIntervalSince1970: Double(ts) / 1000))
        )
      )
    }
    return rows.reversed()
#endif
  }

  private static func loadWhatsAppMentionNames(db: OpaquePointer) -> [String: String] {
    let sql = """
      SELECT jid,
             COALESCE(NULLIF(TRIM(display_name), ''), NULLIF(TRIM(push_name), '')) AS name
      FROM contacts
      WHERE jid IS NOT NULL
        AND COALESCE(NULLIF(TRIM(display_name), ''), NULLIF(TRIM(push_name), '')) IS NOT NULL
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
    defer { sqlite3_finalize(stmt) }

    var names: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let jidPtr = sqlite3_column_text(stmt, 0),
            let namePtr = sqlite3_column_text(stmt, 1) else { continue }
      let jid = String(cString: jidPtr)
      let name = String(cString: namePtr).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, let at = jid.firstIndex(of: "@") else { continue }
      let prefix = String(jid[..<at])
      if names[prefix] == nil {
        names[prefix] = name
      }
    }
    return names
  }

  private static func prettyWhatsAppHandle(_ jid: String) -> String {
    guard let at = jid.firstIndex(of: "@") else { return jid }
    let suffix = jid[at...]
    if suffix == "@g.us" { return jid }
    let digits = jid[..<at].filter(\.isNumber)
    guard !digits.isEmpty else { return jid }
    if digits.count == 11, digits.hasPrefix("1") {
      let local = String(digits.dropFirst())
      return "+1 \(local.prefix(3))-\(local.dropFirst(3).prefix(3))-\(local.suffix(4))"
    }
    return "+\(digits)"
  }

  static func preferredDisplayTitle(chatName: String?, resolvedName: String?, fallback: String) -> String {
    let chat = cleanDisplayName(chatName)
    let resolved = cleanDisplayName(resolvedName)
    if let chat, let resolved, shouldPreferResolvedName(chatName: chat, resolvedName: resolved) {
      return resolved
    }
    return chat ?? resolved ?? fallback
  }

  private static func shouldPreferResolvedName(chatName: String, resolvedName: String) -> Bool {
    let chatParts = nameParts(chatName)
    let resolvedParts = nameParts(resolvedName)
    guard chatParts.count < resolvedParts.count, let firstChatPart = chatParts.first else {
      return false
    }
    let normalizedChat = normalizedName(chatName)
    let normalizedResolved = normalizedName(resolvedName)
    if normalizedResolved.hasPrefix("\(normalizedChat) ") {
      return true
    }
    return normalizedName(String(firstChatPart)) == normalizedName(String(resolvedParts[0]))
  }

  private static func cleanDisplayName(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func nameParts(_ value: String) -> [Substring] {
    value.split { character in
      character.isWhitespace || character == "-" || character == "_"
    }
  }

  private static func normalizedName(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func imessageDate(_ raw: Int64) -> Date {
    if abs(raw) > 10_000_000_000_000 {
      return Date(timeIntervalSince1970: Double(raw) / 1_000_000_000.0 + 978_307_200.0)
    }
    if abs(raw) > 100_000_000 {
      return Date(timeIntervalSince1970: Double(raw) + 978_307_200.0)
    }
    return Date(timeIntervalSince1970: Double(raw))
  }

  /// Inverse of `imessageDate` for page-cursor binds, assuming the modern
  /// Apple-epoch-nanoseconds storage (every macOS this app supports). Double
  /// round-tripping costs ~100ns of precision at this magnitude; strict-`<`
  /// paging absorbs the boundary via dedupe-by-id.
  private static func imessageRawDate(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 - 978_307_200.0) * 1_000_000_000.0)
  }

  private static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func bestMessageBody(textCol: String?, attributedBody: Data?) -> String {
    if let textCol, !textCol.isEmpty { return textCol }
    return decodeAttributedBody(attributedBody) ?? ""
  }

  private static func displayBody(textCol: String?, attributedBody: Data?, associatedMessageType: Int?) -> String {
    let raw = bestMessageBody(textCol: textCol, attributedBody: attributedBody)
      .replacingOccurrences(of: "\u{fffc}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !raw.isEmpty { return raw }
    return tapbackFallback(associatedMessageType) ?? ""
  }

  private static func tapbackFallback(_ associatedMessageType: Int?) -> String? {
    guard let associatedMessageType,
          associatedMessageType >= 2000,
          associatedMessageType <= 3999 else { return nil }
    let removed = associatedMessageType >= 3000
    let base = removed ? associatedMessageType - 1000 : associatedMessageType
    let label: String
    switch base {
    case 2000: label = "Loved"
    case 2001: label = "Liked"
    case 2002: label = "Disliked"
    case 2003: label = "Laughed at"
    case 2004: label = "Emphasized"
    case 2005: label = "Questioned"
    case 2006: label = "Reacted with emoji"
    default: label = "Reacted"
    }
    return removed ? "Removed \(label.lowercased()) reaction" : "\(label) a message"
  }

  private static func hasColumn(_ db: OpaquePointer, table: String, column: String) -> Bool {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
          let stmt else { return false }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let namePtr = sqlite3_column_text(stmt, 1) else { continue }
      if String(cString: namePtr) == column {
        return true
      }
    }
    return false
  }

  static func attachTapbacksForTesting(
    messages: [ContextMessage],
    reactionsByMessageGUID: [String: [MessageReaction]]
  ) -> [ContextMessage] {
    messages.map { message in
      guard let guid = message.guid,
            let reactions = reactionsByMessageGUID[guid],
            !reactions.isEmpty else {
        return message
      }
      return message.attachingReactions(sortedReactions(reactions))
    }
  }

  /// One associated-message row scanned from chat.db, before folding onto its
  /// target. `targetGUID` is raw — still carrying the part prefix chat.db
  /// writes into associated_message_guid.
  struct TapbackEvent {
    let associatedMessageType: Int
    let targetGUID: String
    let fromMe: Bool
    let senderHandle: String?
    let senderName: String?
    let sentAt: Date
    let emoji: String?
  }

  /// chat.db prefixes associated_message_guid with the message part the
  /// tapback landed on — "p:0/<GUID>" (part index) or "bp:<GUID>" (whole
  /// bubble) — while message.guid carries no prefix, so the two never match
  /// until the prefix is stripped.
  static func tapbackTargetGUID(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("bp:") {
      let guid = String(trimmed.dropFirst(3))
      return guid.isEmpty ? nil : guid
    }
    if trimmed.hasPrefix("p:"), let slash = trimmed.firstIndex(of: "/") {
      let guid = String(trimmed[trimmed.index(after: slash)...])
      return guid.isEmpty ? nil : guid
    }
    return trimmed
  }

  /// Folds tapback rows onto their target messages. A reactor holds at most
  /// one live tapback per (message, kind): the newest add (2xxx) / remove
  /// (3xxx) event for that triple wins, so a remove cancels an earlier add
  /// and a re-add after a remove survives. Timestamp ties go to the remove —
  /// it always refers to an already-delivered add. Rows whose type is
  /// outside the tapback range are ignored.
  static func foldTapbacks(_ events: [TapbackEvent]) -> [String: [MessageReaction]] {
    struct ReactionKey: Hashable {
      let target: String
      let reactor: String
      let kind: MessageReaction.Kind
    }
    var latest: [ReactionKey: TapbackEvent] = [:]
    for event in events {
      guard let kind = tapbackKind(event.associatedMessageType),
            let target = tapbackTargetGUID(event.targetGUID) else { continue }
      let reactor = event.fromMe ? "me" : (event.senderHandle ?? event.senderName ?? "")
      let key = ReactionKey(target: target, reactor: reactor, kind: kind)
      if let current = latest[key] {
        let later = event.sentAt > current.sentAt
        let tieGoesToRemove = event.sentAt == current.sentAt
          && isRemovedTapback(event.associatedMessageType)
        guard later || tieGoesToRemove else { continue }
      }
      latest[key] = event
    }
    var result: [String: [MessageReaction]] = [:]
    for (key, event) in latest where !isRemovedTapback(event.associatedMessageType) {
      result[key.target, default: []].append(
        MessageReaction(
          kind: key.kind,
          from_me: event.fromMe,
          sender_handle: event.fromMe ? nil : event.senderHandle,
          sender_name: event.fromMe ? nil : event.senderName,
          sent_at: iso(event.sentAt),
          emoji: event.emoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? event.emoji
            : nil
        )
      )
    }
    return result.mapValues(sortedReactions)
  }

  static func tapbackKindForTesting(_ associatedMessageType: Int) -> MessageReaction.Kind? {
    tapbackKind(associatedMessageType)
  }

  static func isTapbackForTesting(_ associatedMessageType: Int) -> Bool {
    isTapback(associatedMessageType)
  }

  private static func isTapback(_ associatedMessageType: Int) -> Bool {
    associatedMessageType >= 2000 && associatedMessageType <= 3999
  }

  private static func isRemovedTapback(_ associatedMessageType: Int) -> Bool {
    associatedMessageType >= 3000 && associatedMessageType <= 3999
  }

  private static func tapbackKind(_ associatedMessageType: Int) -> MessageReaction.Kind? {
    guard isTapback(associatedMessageType) else { return nil }
    let base = isRemovedTapback(associatedMessageType) ? associatedMessageType - 1000 : associatedMessageType
    switch base {
    case 2000: return .loved
    case 2001: return .liked
    case 2002: return .disliked
    case 2003: return .laughed
    case 2004: return .emphasized
    case 2005: return .questioned
    case 2006: return .emoji
    default: return .reacted
    }
  }

  private static func sortedReactions(_ reactions: [MessageReaction]) -> [MessageReaction] {
    reactions.sorted { lhs, rhs in
      let left = [lhs.sent_at ?? "", lhs.kind.rawValue, lhs.emoji ?? "", lhs.sender_handle ?? "", lhs.sender_name ?? ""]
      let right = [rhs.sent_at ?? "", rhs.kind.rawValue, rhs.emoji ?? "", rhs.sender_handle ?? "", rhs.sender_name ?? ""]
      return left.lexicographicallyPrecedes(right)
    }
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
    return String(data: Data(bytes[cursor..<(cursor + length)]), encoding: .utf8)?
      .trimmingCharacters(in: .controlCharacters)
  }
}

private struct ContactNameResolver {
  private let handles: [String: String]

  static func load() -> ContactNameResolver {
    let url = AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("contacts-cache.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawHandles = json["handles"] as? [String: String]
    else {
      return ContactNameResolver(handles: [:])
    }
    return ContactNameResolver(handles: rawHandles)
  }

  func name(for handle: String) -> String? {
    Self.canonicalHandle(handle).flatMap { handles[$0] }
  }

  private static func canonicalHandle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasSuffix("@s.whatsapp.net"), let at = trimmed.firstIndex(of: "@") {
      let digits = trimmed[..<at].filter(\.isNumber)
      return digits.isEmpty ? nil : String(digits.suffix(10))
    }
    if trimmed.contains("@") {
      return trimmed.lowercased()
    }
    let digits = trimmed.filter(\.isNumber)
    guard !digits.isEmpty else { return nil }
    return String(digits.suffix(10))
  }
}

private struct GlobalComposeSheet: View {
  let activeThreads: [DraftThread]
  let onCreated: (Draft) -> Void
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var settings: SettingsStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  @State private var recipientQuery = ""
  @State private var contactMatches: [ContactMatch] = []
  /// Contact lookup feedback: `inFlight` is the truth, `visible` is the delayed
  /// (>0.5s) spinner reveal so fast local lookups don't flash one.
  @State private var contactSearchInFlight = false
  @State private var contactSearchVisible = false
  @State private var recentIMessageThreads: [RecentComposeThread] = []
  @State private var recentWhatsAppThreads: [RecentComposeThread] = []
  @State private var selectedRecipient: ComposeRecipient?
  @State private var selectedPlatform: Platform = .imessage
  @State private var composeContext: [ContextMessage] = []
  @State private var isLoadingContext = false
  @State private var composeBody = ""
  @State private var composeMode: ComposeMode = .draft
  @State private var composeDate = Date().addingTimeInterval(3600)
  @State private var composeError: String?
  /// The recipient whose unsent text the composer currently holds. Tracked so a
  /// recipient switch (or sheet dismissal) auto-saves the text to the recipient
  /// it was typed for. Auto-save fires only on leave, never while typing.
  @State private var autosaveOwner: ComposeRecipient?

  /// `initialRecipient`/`initialMode`/`initialDate` preconfigure the sheet for
  /// deep links (the Birthday lab's "Draft a scheduled text"); all default so
  /// existing call sites are untouched. The body is never prefilled.
  init(
    activeThreads: [DraftThread],
    initialRecipient: ComposeRecipient? = nil,
    initialMode: ComposeMode = .draft,
    initialDate: Date? = nil,
    onCreated: @escaping (Draft) -> Void
  ) {
    self.activeThreads = activeThreads
    self.onCreated = onCreated
    _selectedRecipient = State(initialValue: initialRecipient)
    _composeMode = State(initialValue: initialMode)
    _composeDate = State(initialValue: initialDate ?? Date().addingTimeInterval(3600))
  }

  private var activeRecipients: [ComposeRecipient] {
    activeThreads.compactMap(ComposeRecipient.from)
  }

  private var trimmedQuery: String {
    recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var manualRecipient: ComposeRecipient? {
    guard looksLikeHandle(trimmedQuery) else { return nil }
    return ComposeRecipient(
      id: "manual-\(trimmedQuery.lowercased())",
      title: trimmedQuery,
      subtitle: "Typed recipient",
      handle: trimmedQuery,
      name: nil,
      platform: nil,
      threadID: nil,
      contextMessages: nil
    )
  }

  private var effectiveRecipient: ComposeRecipient? {
    selectedRecipient ?? manualRecipient
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          recipientPicker
          if effectiveRecipient != nil {
            messageComposer
          }
        }
        .padding(18)
      }
      Divider()
      footer
    }
    .onAppear {
      recentIMessageThreads = RecentComposeThread.loadIMessage()
      recentWhatsAppThreads = RecentComposeThread.loadWhatsApp()
      // A deep-linked recipient arrives preselected, so the onChange below
      // never fires for it — load its conversation context here.
      if let selectedRecipient {
        loadComposeContext(for: selectedRecipient)
      }
      autosaveOwner = effectiveRecipient
    }
    .onChange(of: recipientQuery) { _, _ in
      refreshContacts()
    }
    .onChange(of: selectedRecipient) { _, recipient in
      // Switched recipients — persist the text we held for the previous one
      // before swapping in the new recipient's draft.
      if let owner = autosaveOwner, owner.id != recipient?.id {
        saveComposerDraft(owner: owner, body: composeBody, contextMessages: [])
        composeBody = ""
      }
      loadComposeContext(for: recipient)
      autosaveOwner = recipient
      restoreComposerDraft()
    }
    .onDisappear {
      // Sheet dismissed — persist whatever's unsent for the current recipient.
      // A staged/sent draft already cleared composeBody, so this is a no-op then.
      if let owner = effectiveRecipient {
        saveComposerDraft(owner: owner, body: composeBody, contextMessages: composeContext)
      }
    }
  }

  // MARK: - Composer auto-save (unsent compose text persists once you leave)

  /// (platform, recipient handle) `recipient`'s compose text would be saved/sent
  /// to. WhatsApp normalizes to the jid the draft is keyed by, matching
  /// `createDraft`.
  private func autosaveTarget(for recipient: ComposeRecipient) -> (platform: Platform, handle: String)? {
    let platform = recipient.platform ?? selectedPlatform
    switch platform {
    case .imessage: return (.imessage, recipient.handle)
    case .whatsapp: return whatsappJID(for: recipient.handle).map { (.whatsapp, $0) }
    }
  }

  private var composerAutosaveDraft: Draft? {
    guard let recipient = effectiveRecipient, let target = autosaveTarget(for: recipient) else { return nil }
    return ComposerAutosavePolicy.existingDraft(
      in: store.drafts, platform: target.platform, handle: target.handle,
      canonicalize: ContactAvatarStore.canonicalKey
    )
  }

  /// Persist (or clear) `body` as `owner`'s auto-save draft. Called on
  /// navigate-away (recipient switch or sheet dismissal) — owner-explicit so a
  /// switch saves to the recipient we left, not the one we moved to. The
  /// reserved source keeps it distinct from AI/MCP drafts.
  private func saveComposerDraft(owner: ComposeRecipient, body: String, contextMessages: [ContextMessage]) {
    guard let target = autosaveTarget(for: owner) else { return }
    let existing = ComposerAutosavePolicy.existingDraft(
      in: store.drafts, platform: target.platform, handle: target.handle,
      canonicalize: ContactAvatarStore.canonicalKey
    )
    switch ComposerAutosavePolicy.action(forBody: body, existing: existing) {
    case .none:
      return
    case .discard(let id):
      try? store.discard(id: id)
    case .update(let id, let newBody):
      _ = try? store.updateBody(id: id, body: newBody)
    case .create(let newBody):
      switch target.platform {
      case .imessage:
        _ = try? store.createIMessageDraft(
          toHandle: target.handle, toHandleName: owner.name, body: newBody,
          contextMessages: contextMessages, inReplyToThreadID: owner.threadID,
          source: ComposerAutosavePolicy.source
        )
      case .whatsapp:
        guard settings.whatsappEnabled else { return }
        _ = try? store.createWhatsAppDraft(
          toHandle: target.handle, toHandleName: owner.name ?? owner.title,
          body: newBody, contextMessages: contextMessages, source: ComposerAutosavePolicy.source
        )
      }
    }
  }

  /// When a recipient is (re)selected, pull any unsent compose draft for them
  /// back into the box so closing/reopening the sheet never loses typed text.
  private func restoreComposerDraft() {
    guard composeBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let draft = composerAutosaveDraft else { return }
    composeBody = draft.body
  }

  /// The compose text was explicitly staged — drop its auto-save twin so the
  /// staged draft is the only one left.
  private func discardComposerAutosave() {
    if let draft = composerAutosaveDraft { try? store.discard(id: draft.id) }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text("Compose")
          .font(DS.Font.settingsTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
        Text("Pick a recent thread, choose a contact, or type a phone/email.")
          .font(DS.Font.settingsCaption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      Spacer()
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .dsButton(.ghost, size: .small)
      .help("Close")
    }
    .padding(18)
  }

  private var recipientPicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Recipient")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))

      if let selectedRecipient {
        selectedRecipientPill(selectedRecipient)
      } else {
        TextField("Search contacts or type a phone/email", text: $recipientQuery)
          .dsInput(colorScheme)

        if let manualRecipient {
          selectedRecipientPill(manualRecipient)
        }

        if contactSearchVisible && contactMatches.isEmpty {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Searching contacts…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
          .accessibilityLabel("Searching contacts")
        }

        if !contactMatches.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Contacts")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(contactMatches.prefix(8)) { match in
              if let handle = match.bestHandle {
                recipientButton(
                  ComposeRecipient(
                    id: "contact-\(match.id)",
                    title: match.name,
                    subtitle: "",
                    handle: handle,
                    name: match.name,
                    platform: nil,
                    threadID: nil,
                    contextMessages: nil
                  ),
                  systemImage: "person"
                )
              }
            }
          }
        }

        if !activeRecipients.isEmpty {
          recipientSection("Open review threads", recipients: activeRecipients, systemImage: "tray.full")
        }

        if !recentIMessageThreads.isEmpty {
          recipientSection("Recent iMessage threads", recipients: recentIMessageThreads.map(\.recipient), systemImage: "clock")
        }

        if !recentWhatsAppThreads.isEmpty {
          recipientSection("Recent WhatsApp threads", recipients: recentWhatsAppThreads.map(\.recipient), systemImage: "phone.bubble.left")
        }
      }
    }
  }

  private var messageComposer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Message")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      DSSegmentedControl([ComposeMode.draft, .scheduled], selection: $composeMode) { mode in
        switch mode {
        case .draft: return "Draft"
        case .scheduled: return "Scheduled"
        }
      } icon: { mode in
        switch mode {
        case .draft: return "pencil"
        case .scheduled: return "clock"
        }
      }
      .frame(width: 260)

      transportPicker
      conversationPreview

      ZStack(alignment: .topLeading) {
        TextEditor(text: $composeBody)
          .font(DS.Font.bubbleBody)
          .frame(minHeight: 130, idealHeight: 160)
          .padding(6)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(DS.Color.line2(colorScheme), lineWidth: 1)
          )
        if composeBody.isEmpty {
          Text("Write a draft...")
            .font(DS.Font.bubbleBody)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .padding(.top, 14)
            .padding(.leading, 12)
            .allowsHitTesting(false)
        }
      }

      if composeMode == .scheduled {
        DSDateTimeField(title: "Send after", selection: $composeDate, displayedComponents: [.date, .hourAndMinute])
          .frame(maxWidth: 280)
      }

      if let composeError {
        Text(composeError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private var conversationPreview: some View {
    if isLoadingContext {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading recent conversation...")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    } else if let recipient = effectiveRecipient, !composeContext.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("Recent conversation", systemImage: "text.bubble")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(composeContext.suffix(6).enumerated()), id: \.offset) { idx, message in
            let messages = Array(composeContext.suffix(6))
            let previous = idx > 0 ? messages[idx - 1] : nil
            let showSender = SenderLabelPolicy.shouldShowSender(
              isGroupConversation: recipient.isGroupConversation,
              message: message,
              previous: previous
            )
            ContextBubbleView(
              message: message,
              showSender: showSender,
              platform: recipient.platform ?? selectedPlatform
            )
          }
        }
      }
      .padding(10)
      .dsCard(colorScheme, fill: DS.Color.g080(colorScheme), radius: DS.Radius.row)
    }
  }

  private var transportPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      DSSegmentedControl([Platform.imessage, .whatsapp], selection: $selectedPlatform) { $0.displayName } icon: { platform in
        platform == .imessage ? Platform.imessage.sfSymbol : "phone.bubble.left.fill"
      }
      .frame(width: 260)
      .disabled(effectiveRecipient?.platform != nil)

      if let platform = effectiveRecipient?.platform {
        Text("This existing thread uses \(platform.displayName).")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if selectedPlatform == .whatsapp && !settings.whatsappEnabled {
        Text("Turn on WhatsApp in Settings before staging WhatsApp drafts.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Cancel") { dismiss() }
        .dsButton(.secondary)
      Button(composeMode == .scheduled ? "Stage Scheduled Draft" : "Stage Draft") {
        createDraft()
      }
      .dsButton(.primary)
      .disabled(effectiveRecipient == nil || composeBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(18)
  }

  private func selectedRecipientPill(_ recipient: ComposeRecipient) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.green)
      VStack(alignment: .leading, spacing: 1) {
        Text(recipient.title)
          .font(DS.Font.settingsLabel)
          .foregroundStyle(DS.Color.ink(colorScheme))
        if !recipient.subtitle.isEmpty {
          Text(recipient.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if let platform = recipient.platform {
        PlatformBadge(platform: platform)
      } else {
        PlatformBadge(platform: selectedPlatform)
      }
      Spacer()
      Button("Change") {
        selectedRecipient = nil
        composeContext = []
        if recipient.id.hasPrefix("manual-") {
          recipientQuery = ""
        }
      }
      .dsButton(.ghost, size: .small)
    }
    .padding(10)
    .background(Color.green.opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func recipientSection(_ title: String, recipients: [ComposeRecipient], systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(recipients.prefix(8)) { recipient in
        recipientButton(recipient, systemImage: systemImage)
      }
    }
  }

  private func recipientButton(_ recipient: ComposeRecipient, systemImage: String) -> some View {
    Button {
      selectedRecipient = recipient
      if let platform = recipient.platform {
        selectedPlatform = platform
      }
      recipientQuery = recipient.handle
      loadComposeContext(for: recipient)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .frame(width: 18)
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 1) {
          Text(recipient.title)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
          if !recipient.subtitle.isEmpty {
            Text(recipient.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if let platform = recipient.platform {
          PlatformBadge(platform: platform)
        }
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(8)
    .dsCard(colorScheme, fill: DS.Color.g080(colorScheme), radius: DS.Radius.row)
  }

  private func refreshContacts() {
    let query = trimmedQuery
    guard query.count >= 2 else {
      contactMatches = []
      contactSearchInFlight = false
      contactSearchVisible = false
      return
    }
    contactSearchInFlight = true
    contactSearchVisible = false
    // Reveal the spinner only if this lookup is still outstanding after 0.5s.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard trimmedQuery == query, contactSearchInFlight else { return }
      contactSearchVisible = true
    }
    Task.detached(priority: .userInitiated) {
      let matches = ContactsExporter.searchContacts(query, limit: 12)
      await MainActor.run {
        guard self.trimmedQuery == query else { return }
        self.contactMatches = matches
        self.contactSearchInFlight = false
        self.contactSearchVisible = false
      }
    }
  }

  private func loadComposeContext(for recipient: ComposeRecipient?) {
    composeContext = []
    guard let recipient else {
      isLoadingContext = false
      return
    }
    if let existing = recipient.contextMessages, !existing.isEmpty {
      composeContext = existing
      isLoadingContext = false
      return
    }
    isLoadingContext = true
    Task {
      let context = await RecentComposeThread.loadContextAsync(for: recipient, limit: 10)
      await MainActor.run {
        guard self.selectedRecipient?.id == recipient.id else { return }
        self.composeContext = context
        self.isLoadingContext = false
      }
    }
  }

  private func createDraft() {
    guard let recipient = effectiveRecipient else { return }
    let platform = recipient.platform ?? selectedPlatform
    do {
      let draft: Draft
      switch platform {
      case .imessage:
        draft = try store.createIMessageDraft(
          toHandle: recipient.handle,
          toHandleName: recipient.name,
          body: composeBody,
          scheduledAt: composeMode == .scheduled ? composeDate : nil,
          approveScheduledDraft: composeMode == .scheduled,
          contextMessages: composeContext.isEmpty ? recipient.contextMessages : composeContext,
          inReplyToThreadID: recipient.threadID
        )
      case .whatsapp:
        guard settings.whatsappEnabled else {
          composeError = "Turn on WhatsApp in Settings before staging a WhatsApp draft."
          return
        }
        guard let jid = whatsappJID(for: recipient.handle) else {
          composeError = "WhatsApp drafts need a phone number or WhatsApp thread, not an email address."
          return
        }
        draft = try store.createWhatsAppDraft(
          toHandle: jid,
          toHandleName: recipient.name ?? recipient.title,
          body: composeBody,
          scheduledAt: composeMode == .scheduled ? composeDate : nil,
          approveScheduledDraft: composeMode == .scheduled,
          contextMessages: composeContext.isEmpty ? recipient.contextMessages : composeContext
        )
      }
      discardComposerAutosave()
      composeBody = ""
      onCreated(draft)
      dismiss()
    } catch {
      composeError = "compose failed: \(error.localizedDescription)"
    }
  }

  private func whatsappJID(for handle: String) -> String? {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("@s.whatsapp.net") || trimmed.hasSuffix("@g.us") || trimmed.hasSuffix("@lid") {
      return trimmed
    }
    guard !trimmed.contains("@") else { return nil }
    var digits = trimmed.filter(\.isNumber)
    guard digits.count >= 10 else { return nil }
    if digits.count == 10 { digits = "1" + digits }
    return "\(digits)@s.whatsapp.net"
  }

  private func looksLikeHandle(_ value: String) -> Bool {
    if value.contains("@") { return value.contains(".") && value.count >= 5 }
    let digits = value.filter(\.isNumber)
    return digits.count >= 7
  }
}

struct PendingMessageBubble: View {
  let draft: Draft
  var onSent: (() -> Void)? = nil
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var threadPriorities: ThreadPriorityStore
  @EnvironmentObject var featureFlags: FeatureFlagStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var sending = false
  @State private var lastError: String?
  @State private var holding = false
  @State private var progress: Double = 0
  @State private var holdStartedAt: Date?
  @State private var fireTask: Task<Void, Never>?
  @State private var isEditing = false
  @State private var editedBody = ""
  @State private var editedHasSchedule = false
  @State private var scheduleDate = Date().addingTimeInterval(3600)
  @State private var isHovering = false
  @State private var toast: BubbleToast?
  @State private var toastTask: Task<Void, Never>?
  // Deferred-discard (undo) state: the Delete chip doesn't discard immediately;
  // it collapses the bubble to a 3s "Undo" strip and only THEN discards. Nothing
  // is deleted during the window, so Undo is a pure cancel.
  @State private var discardPending = false
  @State private var discardTask: Task<Void, Never>? = nil
  // Keyboard / VoiceOver approval gate: the hold-to-fire is otherwise pointer-only.
  // Return/Space ARMS, a second confirm fires (never a single-press send), and the
  // confirming press only fires once `holdDuration` has elapsed since arming, so the
  // keyboard path honors the same hold the pointer path does (incl. the 2s induced
  // hold). Esc disarms; auto-disarm after 4s.
  @State private var armed = false
  @State private var armedAt: Date? = nil
  @State private var disarmTask: Task<Void, Never>? = nil
  private let bubbleMaxWidth: CGFloat = 390

  private var holdDuration: Double {
    draft.induced_by_unknown_contact == true ? 2.0 : 1.0
  }

  private var reviewState: PendingReviewState {
    if draft.isScheduled {
      return draft.schedule_approved == true ? .queuedScheduled : .scheduledDraft
    }
    return .stagedDraft
  }

  private var actionsVisible: Bool {
    isHovering || isEditing
  }

  private var shouldConstrainBubbleWidth: Bool {
    draft.body.count > 48 || draft.body.contains(where: \.isNewline)
  }

  var body: some View {
    Group {
      if discardPending {
        discardUndoStrip
      } else {
        bubbleStack
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.14)) {
        isHovering = hovering
      }
    }
    .onAppear {
      editedBody = draft.body
      editedHasSchedule = draft.isScheduled
      scheduleDate = draft.scheduledDate ?? defaultScheduleDate
    }
  }

  private var bubbleStack: some View {
    VStack(alignment: .trailing, spacing: 7) {
      if draft.induced_by_unknown_contact == true {
        InducedDraftBadge()
          .frame(maxWidth: 420)
      }

      replyingToCallout

      HStack(alignment: .center, spacing: 8) {
        Spacer(minLength: 0)
        bubbleCluster
      }
      .frame(maxWidth: .infinity, alignment: .trailing)

      if let toast {
        BubbleToastView(toast: toast)
      }

      metadata

      if let lastError {
        Text(lastError)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: 420, alignment: .trailing)
      }
    }
  }

  // Discard isn't immediate: the bubble collapses to a 3s "Undo" strip and only
  // then actually discards. Reinforces "you're in control" and rescues a
  // mis-click — nothing is deleted during the window, so Undo is a pure cancel.
  private var discardUndoStrip: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      Image(systemName: "trash")
        .foregroundStyle(.secondary)
      Text("Discarded draft to \(draft.recipientDisplayName)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Button("Undo") { undoDiscard() }
        .buttonStyle(.borderless)
        .accessibilityLabel("Undo discarding the draft to \(draft.recipientDisplayName)")
    }
    .frame(maxWidth: 420, alignment: .trailing)
  }

  @ViewBuilder
  private var replyingToCallout: some View {
    if let quoted = draft.quoted_preview {
      HStack(alignment: .top, spacing: 6) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(draft.effectivePlatform.accentColor.opacity(0.6))
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.left.fill")
              .font(.caption2)
            Text("Replying to \(quoted.displayName)")
              .font(.caption.weight(.medium))
          }
          .foregroundStyle(DS.Color.ink3(colorScheme))
          if let body = quoted.body, !body.isEmpty {
            Text(body)
              .font(.caption)
              .foregroundStyle(DS.Color.ink3(colorScheme))
              .lineLimit(2)
              .truncationMode(.tail)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: 420, alignment: .leading)
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
      .background(DS.Color.g130(colorScheme))
      .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
      .dsHairline(colorScheme, DS.Color.line, radius: DS.Radius.control)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Replying to \(quoted.displayName): \(quoted.body ?? "")")
    }
  }

  private var bubbleCluster: some View {
    activeBubble
      .overlay(alignment: .leading) {
        if actionsVisible {
          chips
            .offset(x: -76)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .animation(.spring(response: 0.24, dampingFraction: 0.86), value: actionsVisible)
      .layoutPriority(1)
  }

  @ViewBuilder
  private var activeBubble: some View {
    if isEditing {
      editBubble
    } else {
      holdableBubble
    }
  }

  private var chips: some View {
    HStack(spacing: 6) {
      HoverActionButton(title: "Edit", systemImage: "pencil", tint: DS.Color.accentTeal(colorScheme), disabled: sending) {
        editedBody = draft.body
        editedHasSchedule = draft.isScheduled
        scheduleDate = draft.scheduledDate ?? defaultScheduleDate
        withAnimation(.easeInOut(duration: 0.16)) {
          isEditing.toggle()
        }
      }
      .help("Edit")

      HoverActionButton(title: "Delete", systemImage: "trash", tint: DS.Color.red, role: .destructive, disabled: sending) {
        if featureFlags.resolved(.draftSafetyStates) {
          beginDiscard()
        } else {
          do { try store.discard(id: draft.id) }
          catch { lastError = "discard failed: \(error.localizedDescription)" }
        }
      }
      .help("Discard this staged draft")
    }
    .padding(4)
    .background(
      Capsule(style: .continuous)
        .fill(DS.Color.g080(colorScheme).opacity(0.96))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 8, y: 3)
    )
    .overlay(
      Capsule(style: .continuous)
        .strokeBorder(DS.Color.line(colorScheme), lineWidth: 1)
    )
  }

  private var holdableBubble: some View {
    TimelineView(.animation(minimumInterval: reduceMotion ? holdDuration : 1.0 / 30.0)) { context in
      let bubbleProgress = displayedProgress(at: context.date)
      Text(draft.body)
        .font(DS.Font.bubbleBody)
        .foregroundStyle(approvalTextColor)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: !shouldConstrainBubbleWidth, vertical: true)
        .padding(.leading, 13)
        .padding(.trailing, 17)
        .padding(.vertical, 8)
        .background(approvalBubbleBackground(progress: bubbleProgress))
        .frame(maxWidth: shouldConstrainBubbleWidth ? bubbleMaxWidth : nil, alignment: .leading)
        .contentShape(DSBubbleShape(tail: .outgoing))
        .opacity(sending || reviewState == .queuedScheduled ? 0.82 : 1)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { _ in
              guard !sending, !holding, !isEditing, !discardPending else { return }
              beginHold()
            }
            .onEnded { _ in cancelHold() }
        )
        .overlay(
          DSBubbleShape(tail: .outgoing)
            .stroke(approvalStroke, lineWidth: 2)
            .opacity(armed ? 0.9 : 0)
            .allowsHitTesting(false)
        )
        // Keyboard path: the hold-to-fire gate is pointer-only otherwise.
        // Return/Space ARMS ("Press Return again to send"), a second press fires
        // (two-step confirm, never a single-press send), Esc disarms. Focus-scoped
        // so only the focused bubble responds. The VoiceOver action routes through
        // the same gate, so it can't fire on a single activation either.
        .focusable(featureFlags.resolved(.draftSafetyStates) && !sending && !discardPending)
        .onKeyPress(.return) { handleConfirmKey() ? .handled : .ignored }
        .onKeyPress(.space) { handleConfirmKey() ? .handled : .ignored }
        .onKeyPress(.escape) {
          if armed { disarm(); return .handled }
          return .ignored
        }
        .onChange(of: sending) { _, isSending in
          if isSending { disarm() }
        }
        .accessibilityLabel(accessibilitySendLabel)
        .accessibilityValue(armed ? "Armed, ready to send" : "")
        .accessibilityHint(
          featureFlags.resolved(.draftSafetyStates)
            ? (armed ? "Activate again to send" : "Activate twice to send")
            : ""
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(accessibilityActionName)) {
          if featureFlags.resolved(.draftSafetyStates) {
            handleConfirmKey()
          } else {
            Task { @MainActor in await performReviewAction() }
          }
        }
    }
  }

  private func approvalBubbleBackground(progress: Double) -> some View {
    let shape = DSBubbleShape(tail: .outgoing)
    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        approvalBaseFill(shape)
        Rectangle()
          .fill(approvalProgressFill)
          .frame(width: max(0, geo.size.width * CGFloat(progress)))
          .clipShape(shape)
        shape
          .stroke(approvalStroke.opacity(holding ? 0.45 : 0), lineWidth: 1)
      }
    }
  }

  @ViewBuilder
  private func approvalBaseFill(_ shape: DSBubbleShape) -> some View {
    if draft.effectivePlatform == .imessage {
      shape.fill(
        LinearGradient(
          colors: [DS.Color.imsgBlueTop.opacity(0.62), DS.Color.imsgBlueBottom.opacity(0.62)],
          startPoint: .top,
          endPoint: .bottom
        )
      )
    } else {
      shape.fill(DS.Color.waOutBg(colorScheme).opacity(0.62))
    }
  }

  private var approvalProgressFill: AnyShapeStyle {
    if draft.effectivePlatform == .imessage {
      return AnyShapeStyle(
        LinearGradient(
          colors: [DS.Color.imsgBlueTop, DS.Color.imsgBlueBottom],
          startPoint: .top,
          endPoint: .bottom
        )
      )
    }
    return AnyShapeStyle(DS.Color.waOutBg(colorScheme))
  }

  private var approvalTextColor: Color {
    draft.effectivePlatform == .imessage ? DS.Color.imsgOutText : DS.Color.waOutText(colorScheme)
  }

  private var approvalStroke: Color {
    draft.effectivePlatform == .imessage ? DS.Color.blueEdge(colorScheme) : DS.Color.green(colorScheme)
  }

  private var editBubble: some View {
    VStack(alignment: .trailing, spacing: 8) {
      TextEditor(text: $editedBody)
        .font(DS.Font.bubbleBody)
        .frame(maxWidth: .infinity, minHeight: 96, idealHeight: 124, maxHeight: 180)
        .padding(6)
        .background(DS.Color.g100(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(DS.Color.line2(colorScheme), lineWidth: 1)
        )

      HStack(spacing: 8) {
        DSCheckbox(title: "Send later", subtitle: nil, isOn: $editedHasSchedule)
          .frame(width: 140)
        if editedHasSchedule {
          DSDateTimeField(title: "Send after", selection: $scheduleDate, displayedComponents: [.date, .hourAndMinute])
            .frame(width: 230)
        }
        Spacer(minLength: 0)
      }
      .font(DS.Font.caption)

      HStack(spacing: 8) {
        Button("Cancel") {
          editedBody = draft.body
          editedHasSchedule = draft.isScheduled
          scheduleDate = draft.scheduledDate ?? defaultScheduleDate
          isEditing = false
        }
        .dsButton(.secondary, size: .small)

        Button("Save") { saveEdit() }
          .dsButton(.primary, size: .small)
          .disabled(editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
  }

  private var metadata: some View {
    HStack(spacing: 6) {
      if sending {
        ProgressView().controlSize(.small)
      } else if holding {
        Text(holdingInlineLabel)
      } else if draft.isScheduled, let d = draft.scheduledDate {
        Text(scheduleStatus(d))
      } else {
        Text("Drafted \(relativeStagedAt)")
      }
      if let reason = draft.schedule_hold_reason {
        Text(holdLabel(reason))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
              .fill(DS.Color.amberDim(colorScheme))
          )
          .foregroundStyle(DS.Color.amber(colorScheme))
      }
      if draft.effectivePlatform != .imessage {
        PlatformBadge(platform: draft.effectivePlatform)
      }
    }
    .font(DS.Font.monoMicro)
    .monospacedDigit()
    .foregroundStyle(DS.Color.ink3(colorScheme))
    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
    .help(absoluteStagedAt)
  }

  private func displayedProgress(at date: Date) -> Double {
    guard holding, let holdStartedAt else {
      return progress
    }
    return min(1, max(0, date.timeIntervalSince(holdStartedAt) / holdDuration))
  }

  private func elapsedLabel(progress: Double) -> String {
    String(format: "%.2fs", max(0, progress * holdDuration))
  }

  private var holdHint: String {
    if holding { return holdingToastLabel }
    switch reviewState {
    case .stagedDraft:
      return "Press & hold to send"
    case .scheduledDraft:
      return "Press & hold to approve"
    case .queuedScheduled:
      return "Press & hold to send now"
    }
  }

  private var relativeStagedAt: String {
    guard let date = draft.stagedDate else { return draft.staged_at }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private var absoluteStagedAt: String {
    guard let date = draft.stagedDate else { return draft.staged_at }
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private var defaultScheduleDate: Date {
    Date().addingTimeInterval(3600)
  }

  private var accessibilitySendLabel: String {
    switch reviewState {
    case .stagedDraft:
      return "Staged draft. Press and hold to send."
    case .scheduledDraft:
      return "Scheduled draft. Press and hold to approve and queue."
    case .queuedScheduled:
      return "Queued scheduled message. Press and hold to send now."
    }
  }

  private var accessibilityActionName: String {
    switch reviewState {
    case .scheduledDraft: return "Approve"
    case .stagedDraft, .queuedScheduled: return "Send"
    }
  }

  private func scheduleStatus(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d, h:mma"
    switch reviewState {
    case .stagedDraft:
      return "Drafted \(relativeStagedAt)"
    case .scheduledDraft:
      return "Press to approve to send on \(f.string(from: d))"
    case .queuedScheduled:
      return "Sending on \(f.string(from: d))"
    }
  }

  private var holdingInlineLabel: String {
    switch reviewState {
    case .stagedDraft: return "Sending..."
    case .scheduledDraft: return "Approving..."
    case .queuedScheduled: return "Keep holding to send now..."
    }
  }

  private var holdingToastLabel: String {
    switch reviewState {
    case .stagedDraft: return "Keep holding to send..."
    case .scheduledDraft: return "Approving..."
    case .queuedScheduled: return "Keep holding to send..."
    }
  }

  private func holdLabel(_ reason: String) -> String {
    switch reason {
    case "quiet_hours": return "Held: quiet hours"
    case "stale": return "Held: past date"
    case "needs_approval": return "Needs approval"
    case "send_failed": return "Held: send failed"
    default: return "Held"
    }
  }

  private static func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func beginHold() {
    disarm()  // a pointer hold supersedes any keyboard-armed state
    holding = true
    holdStartedAt = Date()
    showToast(holdingToastLabel, tint: DS.Color.accentTeal(colorScheme), autoDismiss: false)
    animate(.linear(duration: holdDuration)) {
      progress = 1
    }
    fireTask?.cancel()
    fireTask = Task { @MainActor in
      let nanos = UInt64(holdDuration * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      guard !Task.isCancelled else { return }
      holding = false
      holdStartedAt = nil
      progress = 0
      fireTask = nil
      await performReviewAction(allowWhileHolding: true)
    }
  }

  private func cancelHold() {
    guard holding || fireTask != nil else { return }
    fireTask?.cancel()
    fireTask = nil
    holding = false
    holdStartedAt = nil
    clearToast()
    animate(.easeOut(duration: 0.12)) {
      progress = 0
    }
  }

  private var armedHint: String {
    switch reviewState {
    case .scheduledDraft: return "Press Return again to approve"
    case .stagedDraft, .queuedScheduled: return "Press Return again to send"
    }
  }

  /// Keyboard / VoiceOver two-step approval. First confirm ARMS; a second confirm
  /// fires, but only once `holdDuration` has elapsed since arming — so the keyboard
  /// path honors the same deliberate hold the pointer path does (including the 2s
  /// induced-draft hold) and can never fire on a single press. An earlier second
  /// press is swallowed (stays armed). Returns true when the key was consumed.
  @discardableResult
  private func handleConfirmKey() -> Bool {
    guard !sending, !isEditing, !discardPending else { return false }
    if armed {
      guard let armedAt, Date().timeIntervalSince(armedAt) >= holdDuration else {
        return true  // swallow: keep armed until the hold elapses
      }
      disarm()
      Task { @MainActor in await performReviewAction() }
    } else {
      armed = true
      armedAt = Date()
      showToast(armedHint, tint: DS.Color.accentTeal(colorScheme), autoDismiss: false)
      disarmTask?.cancel()
      disarmTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        disarm()
      }
    }
    return true
  }

  private func disarm() {
    disarmTask?.cancel()
    disarmTask = nil
    let wasArmed = armed
    armed = false
    armedAt = nil
    if wasArmed { clearToast() }
  }

  // Deferred discard: hold the draft for 3s behind an Undo strip, then actually
  // discard. Nothing is deleted during the window, so Undo is a pure cancel.
  private func beginDiscard() {
    discardTask?.cancel()
    cancelHold()
    disarm()
    discardPending = true
    // Announce the undo window so VoiceOver users know the discard is deferred
    // and recoverable (the strip's Undo button is the only on-screen affordance).
    NSAccessibility.post(
      element: NSApp.mainWindow ?? NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: "Draft to \(draft.recipientDisplayName) will be discarded in 3 seconds. Activate Undo to cancel.",
        .priority: NSAccessibilityPriorityLevel.high.rawValue
      ]
    )
    discardTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled else { return }
      do {
        try store.discard(id: draft.id)
      } catch {
        discardPending = false
        lastError = "Couldn't discard: \(error.localizedDescription)"
      }
    }
  }

  private func undoDiscard() {
    discardTask?.cancel()
    discardTask = nil
    discardPending = false
  }

  private func performReviewAction(allowWhileHolding: Bool = false) async {
    guard !sending, !isEditing, !discardPending else { return }
    guard allowWhileHolding || !holding else { return }
    if reviewState == .scheduledDraft {
      approveSchedule()
    } else {
      await send()
    }
  }

  private func saveEdit() {
    do {
      try store.updateBody(id: draft.id, body: editedBody)
      try store.updateScheduling(
        id: draft.id,
        scheduledSendAt: .some(editedHasSchedule ? Self.isoString(scheduleDate) : nil),
        holdReason: .some(nil),
        overrideSend: .some(nil),
        scheduleApproved: .some(editedHasSchedule ? true : nil)
      )
      isEditing = false
      lastError = nil
    } catch {
      lastError = "edit failed: \(error.localizedDescription)"
    }
  }

  private func approveSchedule() {
    do {
      showToast("Approving...", tint: DS.Color.accentTeal(colorScheme), autoDismiss: false)
      try store.updateScheduling(
        id: draft.id,
        holdReason: .some(nil),
        overrideSend: .some(nil),
        scheduleApproved: .some(true)
      )
      lastError = nil
      showToast("Approved", tint: .green)
    } catch {
      lastError = "approval failed: \(error.localizedDescription)"
      showToast("Approval failed", tint: .red)
    }
  }

  private func send() async {
    sending = true
    lastError = nil
    let result = await DraftSender.send(draft: draft)
    if result.ok, let service = result.service {
      showToast("Sent", tint: .green)
      let draftPlatform = draft.effectivePlatform
      let draftThreadID = draft.in_reply_to_thread_id
      let draftHandle = draft.to_handle
      if threadPriorities.priority(platform: draftPlatform, threadID: draftThreadID, handle: draftHandle) != nil {
        threadPriorities.clearPriority(platform: draftPlatform, threadID: draftThreadID, handle: draftHandle)
      }
      if draftPlatform == .imessage {
        do {
          try store.markSent(id: draft.id, sentAt: Date(), service: service)
          onSent?()
        } catch {
          lastError = "sent ok but failed to update draft file: \(error.localizedDescription)"
        }
      } else {
        store.refresh()
        onSent?()
      }
    } else {
      lastError = featureFlags.resolved(.draftSafetyStates)
        ? SendErrorCopy.user(for: result.error, platform: draft.effectivePlatform)
        : (result.error ?? "unknown error")
      showToast("Send failed", tint: .red)
    }
    sending = false
  }

  private func showToast(_ text: String, tint: Color, autoDismiss: Bool = true) {
    toastTask?.cancel()
    animate(.easeOut(duration: 0.16)) {
      toast = BubbleToast(text: text, tint: tint)
    }
    guard autoDismiss else { return }
    toastTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_350_000_000)
      animate(.easeIn(duration: 0.16)) {
        toast = nil
      }
    }
  }

  private func clearToast() {
    toastTask?.cancel()
    toastTask = nil
    animate(.easeIn(duration: 0.12)) {
      toast = nil
    }
  }

  private func animate(_ animation: Animation, _ updates: () -> Void) {
    if reduceMotion {
      updates()
    } else {
      withAnimation(animation, updates)
    }
  }
}

private struct BubbleToast {
  let id = UUID()
  let text: String
  let tint: Color
}

private struct BubbleToastView: View {
  let toast: BubbleToast
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text(toast.text)
      .font(DS.Font.pill)
      .foregroundStyle(toast.tint)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        Capsule()
          .fill(DS.Color.g130(colorScheme))
          .shadow(color: Color.black.opacity(0.10), radius: 5, y: 2)
      )
      .overlay(
        Capsule()
          .stroke(toast.tint.opacity(0.25), lineWidth: 1)
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .accessibilityLabel(toast.text)
  }
}

private enum PendingReviewState: Equatable {
  case stagedDraft
  case scheduledDraft
  case queuedScheduled
}

private struct HoverActionButton: View {
  let title: String
  let systemImage: String
  let tint: Color
  var role: ButtonRole? = nil
  var disabled = false
  let action: () -> Void
  @State private var isHovering = false
  @State private var showTooltip = false
  @State private var tooltipTask: Task<Void, Never>?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(role: role) { action() } label: {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(disabled ? DS.Color.ink3(colorScheme) : (isHovering ? DS.Color.ink(colorScheme) : tint))
        .frame(width: 30, height: 30)
        .background(
          RoundedRectangle(cornerRadius: DS.Radius.control - 3, style: .continuous)
            .fill(isHovering ? DS.Color.g200(colorScheme) : DS.Color.g100(colorScheme))
        )
        .overlay(
          RoundedRectangle(cornerRadius: DS.Radius.control - 3, style: .continuous)
            .stroke(DS.Color.line2(colorScheme), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control - 3, style: .continuous))
    }
    .buttonStyle(.borderless)
    .disabled(disabled)
    .opacity(disabled ? 0.48 : 1)
    .frame(width: 30, height: 30)
    .accessibilityLabel(title)
    .overlay(alignment: .top) {
      if showTooltip {
        Text(title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(DS.Color.ink(colorScheme))
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            Capsule()
              .fill(DS.Color.g130(colorScheme))
              .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
          )
          .overlay(
            Capsule()
              .stroke(DS.Color.line2(colorScheme), lineWidth: 1)
          )
          .offset(y: -28)
          .transition(.opacity)
          .allowsHitTesting(false)
      }
    }
    .onHover { hovering in
      tooltipTask?.cancel()
      withAnimation(.easeInOut(duration: 0.14)) {
        isHovering = hovering
        if !hovering { showTooltip = false }
      }
      guard hovering, !disabled else { return }
      tooltipTask = Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard isHovering else { return }
          withAnimation(.easeInOut(duration: 0.12)) {
            showTooltip = true
          }
        }
      }
    }
    .onDisappear {
      tooltipTask?.cancel()
      showTooltip = false
      isHovering = false
    }
  }
}


/// Read-only history row for an already-sent draft. Deliberately has NO
/// Send/Discard controls.
private struct SentDraftRow: View {
  let draft: Draft
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(draft.recipientDisplayName)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
          if let service = draft.send_service {
            Text(service)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Spacer(minLength: 8)
          if let sent = draft.sentDate {
            Text(relativeSent(sent))
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .help(absoluteSent(sent))
          }
        }
        Text(draft.body)
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .lineLimit(3)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(12)
    .frame(width: 280, alignment: .leading)
    .dsCard(colorScheme, fill: DS.Color.g080(colorScheme), radius: DS.Radius.row)
  }

  private func relativeSent(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
  }

  private func absoluteSent(_ date: Date) -> String {
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .medium
    f.timeStyle = .short
    return "Sent \(f.string(from: date))"
  }
}
