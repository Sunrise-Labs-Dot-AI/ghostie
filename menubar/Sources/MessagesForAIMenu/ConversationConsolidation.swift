import Contacts
import Foundation

/// Folds duplicate 1:1 threads that reach the SAME Contacts person over
/// different handles (a phone number and an iCloud email, say) into one
/// conversation row, the way Messages.app presents them.
///
/// Identity is strictly the CNContact *unified contact* identifier — a phone
/// and an email merge only when one contact card carries both. Display-name
/// equality is deliberately NOT a merge key (two different "Sam"s must never
/// fold). Group chats never merge, and platforms never merge across each
/// other. Folding runs AFTER page assembly (ConversationPagingPolicy) and
/// only on the rendered list — the raw thread cache stays unmerged so
/// pagination cursors keep anchoring on real per-source rows.
enum ConversationConsolidationPolicy {
  /// One row per (platform, contact): the NEWEST thread keeps the row
  /// identity — id, lastMessageDate, preview, and the send target — and the
  /// rest ride along as `consolidatedSiblings` so the transcript, drafts,
  /// search, and deep links can still reach every member handle. Threads
  /// without a resolved contact pass through untouched. Idempotent: merged
  /// input is flattened back to members before refolding.
  static func merge(
    threads: [RecentComposeThread],
    contactKey: (RecentComposeThread) -> String?
  ) -> [RecentComposeThread] {
    let flat = threads.flatMap { thread -> [RecentComposeThread] in
      guard !thread.consolidatedSiblings.isEmpty else { return [thread] }
      var bare = thread
      bare.consolidatedSiblings = []
      return [bare] + thread.consolidatedSiblings
    }
    var keys: [String?] = []
    var groups: [String: [RecentComposeThread]] = [:]
    for thread in flat {
      let key: String? = thread.isGroupConversation
        ? nil
        : contactKey(thread).map { "\(thread.platform.rawValue)|\($0)" }
      keys.append(key)
      if let key { groups[key, default: []].append(thread) }
    }
    // Emit at the first member's position — input is recency-ordered, so
    // the merged row sits where its newest member already was.
    var emitted = Set<String>()
    var result: [RecentComposeThread] = []
    for (thread, key) in zip(flat, keys) {
      guard let key else {
        result.append(thread)
        continue
      }
      guard emitted.insert(key).inserted else { continue }
      let members = groups[key] ?? [thread]
      guard members.count > 1 else {
        result.append(thread)
        continue
      }
      let ordered = members.sorted { lhs, rhs in
        let left = lhs.lastMessageDate ?? .distantPast
        let right = rhs.lastMessageDate ?? .distantPast
        if left != right { return left > right }
        return lhs.id < rhs.id
      }
      var merged = ordered[0]
      merged.consolidatedSiblings = Array(ordered.dropFirst())
      result.append(merged)
    }
    return result
  }

  /// Convenience over a canonical-handle → contact-id snapshot
  /// (ContactIdentityStore.identifiers), so background list assembly works
  /// from a value copy instead of touching the MainActor store.
  static func merge(
    threads: [RecentComposeThread],
    identities: [String: String]
  ) -> [RecentComposeThread] {
    merge(threads: threads) { thread in
      ContactAvatarStore.canonicalKey(thread.handle).flatMap { identities[$0] }
    }
  }

  /// One transcript page for a merged row: per-member fetches (same limit,
  /// same before-cursor) unioned chronologically, deduped by guid, capped to
  /// the newest `limit` messages. The cap keeps the shared cursor honest —
  /// every discarded message is older than every kept one, so the next
  /// strictly-older fetch re-reads it (same discipline as
  /// ConversationPagingPolicy.assemblePage); boundary-date ties ride along
  /// because a strictly-older fetch could never reach them again. A result
  /// under `limit` therefore still means "every member exhausted", which is
  /// the contract the `hasLoadedAllAvailableHistory` checks rely on.
  static func unionTranscriptPage(
    _ fetches: [[ContextMessage]],
    limit: Int
  ) -> [ContextMessage] {
    let merged = DirectSendTranscriptReconciler.mergeChronologicalMessages(fetches.flatMap { $0 })
    guard merged.count > limit else { return merged }
    var cut = merged.count - limit
    if let boundary = merged[cut].sentDate {
      while cut > 0, merged[cut - 1].sentDate == boundary { cut -= 1 }
    }
    return Array(merged[cut...])
  }
}

/// Background-resolved map from canonical handle to CNContact *unified
/// contact* identifier, mirroring ContactAvatarStore's lookup discipline:
/// one CNContactStore hit per handle, in-memory cache only, nothing written
/// to disk. The Messages tab feeds the map to
/// ConversationConsolidationPolicy — two handles fold only when Contacts
/// says they are the same person.
@MainActor
final class ContactIdentityStore: ObservableObject {
  /// ContactAvatarStore.canonicalKey(handle) → CNContact.identifier.
  /// Resolutions publish in batches (one flush per settle window) so a
  /// fresh page of rows doesn't trigger a list re-fold per contact.
  @Published private(set) var identifiers: [String: String] = [:]
  private var attempted: Set<String> = []
  private var staged: [String: String] = [:]
  private var flushTask: Task<Void, Never>?
  private let contactStore = CNContactStore()

  /// Kicks off a one-time background resolve for every handle not yet
  /// tried. Group jids and unparseable handles are skipped at the
  /// canonical-key gate.
  func register(_ handles: [String]) {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
    for handle in handles {
      guard let key = ContactAvatarStore.canonicalKey(handle),
            attempted.insert(key).inserted,
            let predicate = ContactAvatarStore.predicate(for: handle) else { continue }
      let store = contactStore
      Task.detached(priority: .utility) { [weak self] in
        let keys = [CNContactIdentifierKey as CNKeyDescriptor]
        guard let contact = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.first
        else { return }
        await self?.stage(key: key, identifier: contact.identifier)
      }
    }
  }

  private func stage(key: String, identifier: String) {
    staged[key] = identifier
    flushTask?.cancel()
    flushTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  private func flush() {
    guard !staged.isEmpty else { return }
    identifiers.merge(staged) { _, new in new }
    staged = [:]
  }
}
