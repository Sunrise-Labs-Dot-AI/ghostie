import Foundation

/// One thread-priority entry as persisted by the MCP priority tools (and by
/// user actions in the Messages tab). Mirrors the on-disk contract in
/// `mcps/*/src/storage/priorities.ts` — that shape is load-bearing and shared
/// across the TypeScript and Swift sides:
///
///     {
///       "schema_version": 1,
///       "priorities": {
///         "<key>": { "level": 1, "reason": "…", "set_at": "…", "set_by": "agent" }
///       }
///     }
///
/// iMessage entries are keyed by `String(chat.ROWID)` (the MCP's `thread_id`);
/// WhatsApp entries are keyed by `thread_jid`.
struct ThreadPriorityEntry: Codable, Equatable {
  let level: Int
  let reason: String?
  let setAt: String?
  let setBy: String?

  enum CodingKeys: String, CodingKey {
    case level
    case reason
    case setAt = "set_at"
    case setBy = "set_by"
  }
}

/// Provenance markers shared with the TS stores via the on-disk `set_by` field.
/// Keep in sync with `ThreadPrioritySource` in `mcps/*/src/storage/priorities.ts`.
/// The TS reader now PRESERVES these (it used to rewrite everything to "agent"),
/// which is what lets Keep Tabs safely co-exist with agent/user priorities.
enum ThreadPrioritySource {
  static let agent = "agent"
  static let keepTabs = "keep-tabs"
  static let user = "user"
}

/// Priority levels, Linear-style: lower number = more urgent.
enum ThreadPriorityLevel: Int, CaseIterable, Identifiable {
  case urgent = 1
  case high = 2
  case elevated = 3

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .urgent: return "Urgent"
    case .high: return "High"
    case .elevated: return "Elevated"
    }
  }

  var shortLabel: String { "P\(rawValue)" }
}

struct ThreadPrioritiesFile: Codable {
  var schemaVersion: Int
  var priorities: [String: ThreadPriorityEntry]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case priorities
  }
}

/// Pure parsing + ordering rules, separated from the store for testability.
enum ThreadPriorityPolicy {
  static let schemaVersion = 1

  /// Decode a priorities file, tolerating a missing/corrupt file (empty) and
  /// dropping individually malformed entries — same posture as the TS reader.
  static func parse(_ data: Data?) -> [String: ThreadPriorityEntry] {
    guard let data, !data.isEmpty else { return [:] }
    guard let file = try? JSONDecoder().decode(ThreadPrioritiesFile.self, from: data),
          file.schemaVersion == schemaVersion else {
      return [:]
    }
    return file.priorities.filter { ThreadPriorityLevel(rawValue: $0.value.level) != nil }
  }

  /// Split conversations into the priority queue (sorted by level, then
  /// recency) and the remainder (left in their incoming recency order).
  static func partition(
    _ conversations: [MessageConversation],
    priorityFor: (MessageConversation) -> ThreadPriorityEntry?
  ) -> (priority: [MessageConversation], rest: [MessageConversation]) {
    var priority: [(conversation: MessageConversation, entry: ThreadPriorityEntry)] = []
    var rest: [MessageConversation] = []
    for conversation in conversations {
      if let entry = priorityFor(conversation) {
        priority.append((conversation, entry))
      } else {
        rest.append(conversation)
      }
    }
    let sorted = priority.sorted { lhs, rhs in
      if lhs.entry.level != rhs.entry.level {
        return lhs.entry.level < rhs.entry.level
      }
      let left = lhs.conversation.lastMessageDate ?? .distantPast
      let right = rhs.conversation.lastMessageDate ?? .distantPast
      if left != right { return left > right }
      return lhs.conversation.title.localizedCaseInsensitiveCompare(rhs.conversation.title) == .orderedAscending
    }
    return (sorted.map(\.conversation), rest)
  }
}

/// Watches `~/.messages-mcp/thread-priorities.json` and
/// `~/.whatsapp-mcp/thread-priorities.json` (written by the MCP priority
/// tools) and exposes the merged priority map to the Messages tab. User
/// actions in the UI (set/clear from a conversation's context menu) write the
/// same files, so agents and the user share one queue.
@MainActor
final class ThreadPriorityStore: ObservableObject {
  @Published private(set) var imessage: [String: ThreadPriorityEntry] = [:]
  @Published private(set) var whatsapp: [String: ThreadPriorityEntry] = [:]

  private var sources: [DispatchSourceFileSystemObject] = []
  private var pendingRefresh: Task<Void, Never>?

  private var imessageFile: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("thread-priorities.json")
  }

  private var whatsappFile: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".whatsapp-mcp")
      .appendingPathComponent("thread-priorities.json")
  }

  init(startWatching: Bool = true) {
    reload()
    if startWatching {
      watchParentDirectories()
    }
  }

  deinit {
    for source in sources { source.cancel() }
  }

  var isEmpty: Bool { imessage.isEmpty && whatsapp.isEmpty }

  /// A consolidated row answers for every member: an agent-set priority keyed
  /// on a folded-away sibling (the MCP keys on that sibling's chat ROWID)
  /// must still float the merged row. The most urgent member entry wins.
  func priority(for recent: RecentComposeThread) -> ThreadPriorityEntry? {
    ([recent] + recent.consolidatedSiblings)
      .compactMap(memberPriority)
      .min { $0.level < $1.level }
  }

  private func memberPriority(_ recent: RecentComposeThread) -> ThreadPriorityEntry? {
    switch recent.platform {
    case .imessage:
      guard let threadID = recent.threadID else { return nil }
      return imessage[String(threadID)]
    case .whatsapp:
      return whatsapp[recent.handle]
    }
  }

  func setPriority(_ level: ThreadPriorityLevel, for recent: RecentComposeThread) {
    setPriority(
      level,
      platform: recent.platform,
      threadID: recent.threadID,
      handle: recent.handle,
      reason: nil,
      setBy: "user"
    )
  }

  /// Keyed variant for callers that aren't holding a RecentComposeThread
  /// (Don't Ghost suggestions, future labs). iMessage keys on the chat
  /// ROWID; WhatsApp keys on the jid.
  func setPriority(
    _ level: ThreadPriorityLevel,
    platform: Platform,
    threadID: Int?,
    handle: String,
    reason: String? = nil,
    setBy: String = "user"
  ) {
    guard let key = storageKey(platform: platform, threadID: threadID, handle: handle) else { return }
    let entry = ThreadPriorityEntry(
      level: level.rawValue,
      reason: reason,
      setAt: ISO8601DateFormatter().string(from: Date()),
      setBy: setBy
    )
    mutateFile(for: platform) { priorities in
      priorities[key] = entry
    }
  }

  func clearPriority(for recent: RecentComposeThread) {
    let keys = ([recent] + recent.consolidatedSiblings).compactMap { storageKey(for: $0) }
    guard !keys.isEmpty else { return }
    mutateFile(for: recent.platform) { priorities in
      for key in keys { priorities.removeValue(forKey: key) }
    }
  }

  func priority(platform: Platform, threadID: Int?, handle: String) -> ThreadPriorityEntry? {
    guard let key = storageKey(platform: platform, threadID: threadID, handle: handle) else { return nil }
    return platform == .whatsapp ? whatsapp[key] : imessage[key]
  }

  func clearPriority(platform: Platform, threadID: Int?, handle: String) {
    guard let key = storageKey(platform: platform, threadID: threadID, handle: handle) else { return }
    mutateFile(for: platform) { priorities in
      priorities.removeValue(forKey: key)
    }
  }

  func reload() {
    imessage = ThreadPriorityPolicy.parse(safeRead(imessageFile))
    whatsapp = ThreadPriorityPolicy.parse(safeRead(whatsappFile))
  }

  // MARK: - Persistence

  private func storageKey(for recent: RecentComposeThread) -> String? {
    storageKey(platform: recent.platform, threadID: recent.threadID, handle: recent.handle)
  }

  private func storageKey(platform: Platform, threadID: Int?, handle: String) -> String? {
    switch platform {
    case .imessage:
      return threadID.map(String.init)
    case .whatsapp:
      return handle.isEmpty ? nil : handle
    }
  }

  private func file(for platform: Platform) -> URL {
    platform == .whatsapp ? whatsappFile : imessageFile
  }

  /// Read-modify-write against the freshest on-disk state so a concurrent MCP
  /// write between our load and save isn't clobbered wholesale.
  private func mutateFile(for platform: Platform, _ mutate: (inout [String: ThreadPriorityEntry]) -> Void) {
    let url = file(for: platform)
    var priorities = ThreadPriorityPolicy.parse(safeRead(url))
    mutate(&priorities)
    do {
      try atomicWrite(priorities: priorities, to: url)
    } catch {
      DiagnosticsStore.shared.log(
        "thread_priorities_write_failed",
        metadata: ["error": error.localizedDescription]
      )
    }
    reload()
  }

  private func safeRead(_ url: URL) -> Data? {
    // Same symlink posture as the MCP stores: a symlinked priorities file is
    // an attack shape, not a corruption shape — refuse to read it.
    if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
       values.isSymbolicLink == true {
      return nil
    }
    return try? Data(contentsOf: url)
  }

  private func atomicWrite(priorities: [String: ThreadPriorityEntry], to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
       values.isSymbolicLink == true {
      throw CocoaError(.fileWriteUnknown)
    }
    let payload = ThreadPrioritiesFile(
      schemaVersion: ThreadPriorityPolicy.schemaVersion,
      priorities: priorities
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // MARK: - Watching

  private func watchParentDirectories() {
    for dir in [imessageFile.deletingLastPathComponent(), whatsappFile.deletingLastPathComponent()] {
      let handle = open(dir.path, O_EVTONLY)
      guard handle >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: handle,
        eventMask: [.write, .delete, .extend, .attrib, .rename],
        queue: .main
      )
      source.setEventHandler { [weak self] in
        self?.scheduleRefresh()
      }
      // macOS 26 guards fds owned by DispatchSourceFileSystemObject — do not
      // call close() in the cancel handler; GCD manages the fd lifecycle.
      source.resume()
      sources.append(source)
    }
  }

  private func scheduleRefresh() {
    pendingRefresh?.cancel()
    pendingRefresh = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      self?.reload()
    }
  }
}
