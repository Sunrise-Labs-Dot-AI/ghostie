import AppKit
import Contacts

/// On-demand contact photos for the Messages tab, keyed by handle (phone,
/// email, or WhatsApp jid). Lookups hit CNContactStore once per handle on a
/// background task and publish into an in-memory cache; rows render the
/// monogram fallback until (unless) a photo arrives. No photo bytes are ever
/// written to disk.
@MainActor
final class ContactAvatarStore: ObservableObject {
  @Published private(set) var images: [String: NSImage] = [:]
  private var attempted: Set<String> = []
  private let contactStore = CNContactStore()

  /// Returns the cached photo for a handle, kicking off a one-time background
  /// fetch on first sight. Group jids never resolve to a person.
  func avatar(for handle: String) -> NSImage? {
    guard let key = Self.canonicalKey(handle) else { return nil }
    if let image = images[key] { return image }
    if !attempted.contains(key) {
      attempted.insert(key)
      fetch(handle: handle, key: key)
    }
    return nil
  }

  private func fetch(handle: String, key: String) {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
    guard let predicate = Self.predicate(for: handle) else { return }
    let store = contactStore
    Task.detached(priority: .utility) { [weak self] in
      let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
      let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
      guard let data = contacts.first(where: { $0.thumbnailImageData != nil })?.thumbnailImageData,
            let image = NSImage(data: data) else { return }
      await MainActor.run { [weak self] in
        self?.images[key] = image
      }
    }
  }

  /// Handle → CNContact lookup predicate. Pure (nonisolated) and shared with
  /// ContactIdentityStore so avatars and identity resolution can never
  /// disagree about which contact a handle reaches.
  nonisolated static func predicate(for handle: String) -> NSPredicate? {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasSuffix("@g.us") else { return nil }
    if trimmed.hasSuffix("@s.whatsapp.net"), let at = trimmed.firstIndex(of: "@") {
      let digits = trimmed[..<at].filter(\.isNumber)
      guard !digits.isEmpty else { return nil }
      return CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: "+\(digits)"))
    }
    if trimmed.contains("@") {
      return CNContact.predicateForContacts(matchingEmailAddress: trimmed)
    }
    let digits = trimmed.filter(\.isNumber)
    guard !digits.isEmpty else { return nil }
    return CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: trimmed))
  }

  /// Same canonicalization as ContactNameResolver so phone formatting
  /// variants share one cache slot. Pure — nonisolated so non-MainActor
  /// helpers (ConversationHandleMatcher) and tests can call it.
  nonisolated static func canonicalKey(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasSuffix("@g.us") else { return nil }
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
