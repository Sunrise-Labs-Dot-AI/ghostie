import Foundation
import CryptoKit
import Security

/// This device's Ed25519 signing identity for the cross-device relay (SUN-613).
///
/// Phase 0 gave each machine a non-secret `device_id` (`DeviceIdentity`) that says WHICH machine
/// owns a draft. This is the other half: the key that will let a device prove it is the one that
/// says so. Phase 1 only mints and stores it. Pairing, which is what turns a local keypair into a
/// mutual trust relationship, lives in phase 2 where there is a transport to run a ceremony over.
///
/// Three properties are load-bearing, and each was wrong in the first draft of the plan:
///
///  1. **Data-protection keychain, explicitly.** On macOS `kSecAttrAccessible` is only honored when
///     `kSecUseDataProtectionKeychain` is true. Omit it and the item silently lands in the legacy
///     file-based login keychain, where the `ThisDeviceOnly` class is simply not applied, and a
///     restored keychain hands the raw signing key to another Mac.
///  2. **Never synchronizable.** If this key reached the iCloud Keychain, compromising the Apple ID
///     would grant send authority, which is precisely what the relay design claims an iCloud
///     account alone cannot do. Set false on add AND on every query.
///  3. **Minted explicitly, never lazily.** Read paths return nil when the key is absent. Only
///     `ensureKeyPair()` creates one, and only enrollment calls it. That is what makes "the feature
///     flag is off, so no key material exists" a fact rather than an intention.
///
/// There is deliberately NO environment-variable override. `ApprovalAuthenticator` has one for its
/// HMAC secret, but extending that pattern to a signing key would be a production key-injection
/// backdoor: a same-user process could launch Ghostie with a key it knows, let the human complete
/// pairing against that apparently normal instance, and forge approvals indefinitely. Tests inject
/// through `RelayKeyStore` instead.
enum RelayIdentityError: Error, Equatable {
  /// The Keychain refused. Callers fail closed rather than proceeding keyless.
  case keychainUnavailable(OSStatus)
  /// A synchronizable item already exists under the same service/account. Synchronizability is
  /// part of a generic password's composite primary key, so a synced record and a local one can
  /// coexist and a local-only query would silently ignore the synced one. We refuse instead of
  /// deleting: deleting a synchronized item propagates the delete to the user's other devices.
  case synchronizedKeyPresent
  case malformedStoredKey
}

/// Seam for tests. The only production implementation is `KeychainRelayKeyStore`.
protocol RelayKeyStore {
  func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey?
  func storePrivateKey(_ key: Curve25519.Signing.PrivateKey) throws
  /// True when a SYNCHRONIZED item shadows this service/account.
  func synchronizedItemExists() -> Bool
}

/// Keychain query construction, split out so the attributes can be asserted directly.
///
/// Asserting on these dictionaries is necessary but NOT sufficient: it proves we asked for the
/// right thing, not that macOS honored it. `RelayIdentityTests` therefore also performs a live
/// round-trip and asserts on the attributes the Keychain hands BACK.
enum RelayKeychain {
  static let service = "com.sunriselabs.messages-for-ai.relay-device-key"
  static let account = "relay-ed25519-v1"

  /// Shared by every operation. `kSecUseDataProtectionKeychain` must appear on add, read, update
  /// AND delete: mixing keychains between operations means the delete misses the item the add
  /// created.
  static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false
    ]
  }

  static func addQuery(keyData: Data) -> [String: Any] {
    var query = baseQuery()
    query[kSecValueData as String] = keyData
    // Signing is interactive, so the key has no reason to be readable behind a locked screen.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return query
  }

  static func readQuery() -> [String: Any] {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return query
  }

  /// Probe for a synchronized shadow. `kSecAttrSynchronizableAny` deliberately overrides the false
  /// in `baseQuery`, so this is the one query that can see a synced record.
  static func synchronizedProbeQuery() -> [String: Any] {
    var query = baseQuery()
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    return query
  }
}

struct KeychainRelayKeyStore: RelayKeyStore {
  func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey? {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(RelayKeychain.readQuery() as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw RelayIdentityError.keychainUnavailable(status) }
    guard let data = item as? Data else { throw RelayIdentityError.malformedStoredKey }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
      throw RelayIdentityError.malformedStoredKey
    }
    return key
  }

  func storePrivateKey(_ key: Curve25519.Signing.PrivateKey) throws {
    let status = SecItemAdd(RelayKeychain.addQuery(keyData: key.rawRepresentation) as CFDictionary, nil)
    guard status == errSecSuccess else { throw RelayIdentityError.keychainUnavailable(status) }
  }

  func synchronizedItemExists() -> Bool {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(RelayKeychain.synchronizedProbeQuery() as CFDictionary, &item)
    guard status == errSecSuccess, let rows = item as? [[String: Any]] else { return false }
    return rows.contains { ($0[kSecAttrSynchronizable as String] as? Bool) == true }
  }
}

struct RelayDeviceIdentity {
  private let store: RelayKeyStore

  init(store: RelayKeyStore = KeychainRelayKeyStore()) {
    self.store = store
  }

  /// This device's public key, or nil when no identity has been minted. Never mints as a side
  /// effect of being asked: a read must not create key material on a machine where the relay is
  /// switched off.
  func publicKey() throws -> Curve25519.Signing.PublicKey? {
    try store.loadPrivateKey()?.publicKey
  }

  /// Base64 of the raw 32-byte public key, the form the pairing transcript and the peer trust
  /// store will carry in phase 2. Mirrors how `ControlManifest` already handles Ed25519 keys.
  func publicKeyBase64() throws -> String? {
    try publicKey()?.rawRepresentation.base64EncodedString()
  }

  /// Mint the identity if absent, and return the public key. **Enrollment calls this. Nothing
  /// else does.**
  @discardableResult
  func ensureKeyPair() throws -> Curve25519.Signing.PublicKey {
    if let existing = try store.loadPrivateKey() { return existing.publicKey }
    guard !store.synchronizedItemExists() else { throw RelayIdentityError.synchronizedKeyPresent }
    let key = Curve25519.Signing.PrivateKey()
    try store.storePrivateKey(key)
    return key.publicKey
  }

  /// Sign with the device identity. Returns nil when no identity exists, so a caller can never
  /// accidentally cause one to be minted by trying to sign.
  func sign(_ payload: Data) throws -> Data? {
    guard let key = try store.loadPrivateKey() else { return nil }
    return try key.signature(for: payload)
  }
}

/// Relay wire-protocol version, carried in the pairing record from phase 2 onward.
///
/// Note what this is NOT: evidence that a machine has no stale executors. It is a self-report by
/// the currently running app and says nothing about an old MCP binary that a stale Claude config
/// is still launching. Rollout safety comes from single-homing the draft file so old executors
/// never see a relayed draft (see `docs/plans/cross-device-draft-sync-spec.md`), not from this
/// number.
enum RelayProtocolVersion {
  static let current = 1
  static let minimumSupported = 1
}
