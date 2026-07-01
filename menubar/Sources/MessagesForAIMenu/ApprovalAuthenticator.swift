import Foundation
import CryptoKit
import Security

/// Authenticates the approval gate so that an on-disk JSON file cannot, by
/// itself, assert "the human approved this — send it." (Issue #77.)
///
/// Threat model: any process running as the user can write
/// `~/.messages-mcp/automations.json` or a draft JSON with `approvalStatus =
/// approved` / `schedule_approved = true` / `override_send = true` and the
/// scheduler would auto-send within ~60s. The product's whole promise ("AI
/// proposes, you approve") is only as strong as that bit's provenance.
///
/// Two independent gates, either of which is sufficient to honor an approval:
///
///  1. **Session approvals (in-memory).** When the user approves in the GUI this
///     session, we remember the CANONICAL TAG (the HMAC over id+recipient+body+
///     scope) in RAM — NOT the bare id. A forged file can't fake this — RAM isn't
///     on disk. Keying by the canonical tag (not the id) is load-bearing: if we
///     keyed by id, a legitimate session approval of id X would let an attacker
///     keep id X but swap the recipient/body on disk and still pass the session
///     gate, bypassing the HMAC binding entirely (issue #77, round 2). Cleared on
///     relaunch (which is the safe direction).
///
///  2. **HMAC tags (cross-session, persisted).** On a GUI approval we compute an
///     HMAC-SHA256 over a canonical string binding the approval to the specific
///     record (id + recipient + body + the approval bits) using a per-install
///     secret stored in the login Keychain. The tag is written alongside the
///     record. Before honoring any approval bit read from disk we recompute and
///     compare in constant time. A process that can write the JSON still can't
///     forge the tag without the Keychain secret (which is access-controlled to
///     this app's identity).
///
/// Fail-closed: if the secret can't be read, or the tag is missing/invalid, the
/// record is treated as NOT approved.
///
/// `MFA_TEST_APPROVAL_SECRET` lets tests inject a deterministic secret without a
/// Keychain round-trip (the Keychain is unavailable in CI / sandboxed test runs).
enum ApprovalAuthenticator {

  // MARK: - Session (in-memory) approvals

  /// Canonical TAGS (HMAC over id+recipient+body+scope) the user approved via the
  /// GUI in THIS process lifetime. Keyed by the tag — NOT the bare id — so that
  /// mutating any bound field (recipient/body/scope) on disk produces a different
  /// canonical message, hence a different tag, hence NOT a session match. A forged
  /// on-disk file cannot populate this. Guarded by `lock` because the scheduler
  /// and the UI both touch it from the main actor, but tests may not be.
  private static var sessionApprovedTags = Set<String>()
  private static let lock = NSLock()

  /// Record a GUI approval for the record identified by this canonical message.
  /// We store the canonical message's HMAC tag so a later check over the record's
  /// CURRENT fields only matches when those fields are unchanged.
  static func recordSessionApproval(canonicalMessage: String) {
    guard let tag = tag(for: canonicalMessage) else { return }
    lock.lock(); defer { lock.unlock() }
    sessionApprovedTags.insert(tag)
  }

  /// True when the canonical message (recomputed from the record's CURRENT
  /// fields) was approved in the GUI this session. Swapping any bound field
  /// changes the canonical message → changes the tag → no match.
  static func hasSessionApproval(canonicalMessage: String) -> Bool {
    guard let tag = tag(for: canonicalMessage) else { return false }
    lock.lock(); defer { lock.unlock() }
    return sessionApprovedTags.contains(tag)
  }

  /// Test seam: drop all in-memory approvals so cases don't bleed into each other.
  static func resetSessionApprovalsForTesting() {
    lock.lock(); defer { lock.unlock() }
    sessionApprovedTags.removeAll()
  }

  // MARK: - HMAC tags (persisted)

  /// Canonical, order-stable string bound by the tag. Any field that, if forged,
  /// would change WHO gets WHAT must appear here so a tag minted for one record
  /// can't be replayed onto another.
  static func canonicalMessage(
    id: String,
    recipient: String,
    body: String,
    scope: String
  ) -> String {
    // Length-prefix each component so concatenation is unambiguous (no
    // "a" + "bc" == "ab" + "c" collision).
    let parts = [id, recipient, body, scope]
    return parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }

  /// Compute the base64 HMAC-SHA256 tag for a canonical message. Returns nil
  /// (fail-closed) if the per-install secret is unavailable.
  static func tag(for message: String) -> String? {
    guard let key = secret() else { return nil }
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return Data(mac).base64EncodedString()
  }

  /// Constant-time verify of a stored tag against the expected canonical message.
  /// Fail-closed on a missing secret or a missing/garbled tag.
  static func verify(tag stored: String?, message: String) -> Bool {
    guard let stored, let expected = tag(for: message) else { return false }
    // Constant-time compare over the raw bytes.
    guard let a = Data(base64Encoded: stored), let b = Data(base64Encoded: expected) else {
      return false
    }
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
  }

  // MARK: - Per-install secret (Keychain)

  private static let keychainService = "com.sunriselabs.messages-for-ai.approval-hmac"
  private static let keychainAccount = "approval-hmac-secret-v1"

  /// Load (or lazily mint) the per-install HMAC secret. The first call after a
  /// fresh install generates 32 random bytes and stores them in the login
  /// Keychain (this-device-only, after-first-unlock). Returns nil only if the
  /// Keychain is genuinely unavailable — callers then fail closed.
  private static func secret() -> SymmetricKey? {
    if let override = ProcessInfo.processInfo.environment["MFA_TEST_APPROVAL_SECRET"],
       let data = override.data(using: .utf8) {
      return SymmetricKey(data: SHA256.hash(data: data))
    }
    if let existing = loadSecret() {
      return SymmetricKey(data: existing)
    }
    // Mint + persist.
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return nil
    }
    let data = Data(bytes)
    if storeSecret(data) {
      return SymmetricKey(data: data)
    }
    // Couldn't persist (Keychain locked / denied). Fail closed rather than
    // returning a secret that won't survive relaunch — a tag minted now would
    // never verify later, which is the safe direction.
    return nil
  }

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount
    ]
  }

  private static func loadSecret() -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
    return data
  }

  @discardableResult
  private static func storeSecret(_ data: Data) -> Bool {
    SecItemDelete(baseQuery() as CFDictionary)
    var query = baseQuery()
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }
}
