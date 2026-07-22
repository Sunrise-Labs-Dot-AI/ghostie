import XCTest
import CryptoKit
import Security
@testable import MessagesForAIMenu

/// SUN-613 phase 1. The property under test is that a device signing key is minted only when
/// asked, and is stored somewhere an Apple ID compromise or a restored keychain cannot reach.
final class RelayIdentityTests: XCTestCase {

  // MARK: - Query attributes
  //
  // These assert we ASKED for the right thing. Necessary, not sufficient: the live round-trip
  // below is what proves macOS honored it.

  func testEveryQuerySelectsTheDataProtectionKeychain() {
    // The finding that motivated this test: on macOS `kSecAttrAccessible` is only honored when
    // `kSecUseDataProtectionKeychain` is true. Omit it and the item lands in the legacy
    // file-based keychain with the ThisDeviceOnly class silently NOT applied, so a restored
    // keychain hands the raw signing key to another Mac.
    for query in [
      RelayKeychain.baseQuery(),
      RelayKeychain.addQuery(keyData: Data(repeating: 7, count: 32)),
      RelayKeychain.readQuery(),
      RelayKeychain.synchronizedProbeQuery()
    ] {
      XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }
  }

  func testAddAndReadPinSynchronizableFalse() {
    // If this key reached the iCloud Keychain, compromising the Apple ID would grant send
    // authority, which is exactly what the relay design claims it cannot.
    XCTAssertEqual(RelayKeychain.baseQuery()[kSecAttrSynchronizable as String] as? Bool, false)
    XCTAssertEqual(
      RelayKeychain.addQuery(keyData: Data(repeating: 7, count: 32))[kSecAttrSynchronizable as String] as? Bool,
      false
    )
    XCTAssertEqual(RelayKeychain.readQuery()[kSecAttrSynchronizable as String] as? Bool, false)
  }

  func testAddUsesWhenUnlockedThisDeviceOnly() {
    let accessible = RelayKeychain.addQuery(keyData: Data(repeating: 7, count: 32))[
      kSecAttrAccessible as String
    ]
    XCTAssertEqual(accessible as! CFString, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
  }

  func testSynchronizedProbeOverridesTheFalsePin() {
    // The one query that must be able to SEE a synced record, or the collision check is blind.
    let probe = RelayKeychain.synchronizedProbeQuery()
    XCTAssertEqual(probe[kSecAttrSynchronizable as String] as? String, kSecAttrSynchronizableAny as String)
  }

  // MARK: - Mint discipline

  func testReadPathsNeverMint() {
    // "Flag off means no key material" is only true if asking for the key cannot create one.
    let store = SpyKeyStore()
    let identity = RelayDeviceIdentity(store: store)

    XCTAssertNil(try? identity.publicKey() ?? nil)
    XCTAssertNil(try? identity.publicKeyBase64() ?? nil)
    XCTAssertNil(try? identity.sign(Data("x".utf8)) ?? nil)
    XCTAssertEqual(store.storeCallCount, 0, "a read path minted a key")
  }

  func testEnsureKeyPairMintsOnceThenReuses() {
    let store = SpyKeyStore()
    let identity = RelayDeviceIdentity(store: store)

    let first = try? identity.ensureKeyPair()
    let second = try? identity.ensureKeyPair()
    XCTAssertNotNil(first)
    XCTAssertEqual(first?.rawRepresentation, second?.rawRepresentation)
    XCTAssertEqual(store.storeCallCount, 1, "a second call re-minted instead of reusing")
  }

  func testEnsureKeyPairRefusesWhenASynchronizedItemShadowsIt() {
    // Synchronizability is part of a generic password's composite primary key, so a synced record
    // and a local one can coexist under the same service/account. Minting a local key while a
    // synced one exists leaves two identities and a later query regression could revive the synced
    // credential. Refuse, and do NOT delete: deleting a synchronized item propagates that delete
    // to the user's other devices.
    let store = SpyKeyStore()
    store.synchronizedShadow = true
    let identity = RelayDeviceIdentity(store: store)

    XCTAssertThrowsError(try identity.ensureKeyPair()) { error in
      XCTAssertEqual(error as? RelayIdentityError, .synchronizedKeyPresent)
    }
    XCTAssertEqual(store.storeCallCount, 0)
  }

  func testSigningProducesAVerifiableSignature() {
    let store = SpyKeyStore()
    let identity = RelayDeviceIdentity(store: store)
    let publicKey = try? identity.ensureKeyPair()

    let payload = Data("ghostie-relay-test".utf8)
    guard let signature = try? identity.sign(payload), let publicKey else {
      return XCTFail("expected a signature")
    }
    XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
    XCTAssertFalse(publicKey.isValidSignature(signature, for: Data("tampered".utf8)))
  }

  func testNoEnvironmentVariableCanSubstituteAKey() {
    // ApprovalAuthenticator has an env seam for its HMAC secret; extending that to a SIGNING key
    // would be a key-injection backdoor. A same-user process could launch Ghostie with a key it
    // knows, let the human pair against that apparently normal instance, and forge approvals
    // forever. Injection is via RelayKeyStore, which no environment can reach.
    setenv("MFA_TEST_RELAY_DEVICE_KEY", String(repeating: "a", count: 64), 1)
    defer { unsetenv("MFA_TEST_RELAY_DEVICE_KEY") }

    let store = SpyKeyStore()
    let identity = RelayDeviceIdentity(store: store)
    let minted = try? identity.ensureKeyPair()
    XCTAssertNotNil(minted)
    XCTAssertNotEqual(
      minted?.rawRepresentation,
      Data(repeating: 0xAA, count: 32),
      "the environment influenced key material"
    )
  }

  // MARK: - Live round-trip
  //
  // Asserting on our own query dictionaries is self-fulfilling. This is the test that proves macOS
  // actually honored what we asked for, by reading back the attributes the Keychain returns.

  func testLiveKeychainRoundTripReportsLocalOnlyStorage() throws {
    let service = "com.sunriselabs.messages-for-ai.relay-device-key.test-\(UUID().uuidString)"
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: RelayKeychain.account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: Curve25519.Signing.PrivateKey().rawRepresentation
    ]
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw XCTSkip("Keychain unavailable in this environment (OSStatus \(addStatus))")
    }
    defer {
      var delete = add
      delete.removeValue(forKey: kSecValueData as String)
      delete.removeValue(forKey: kSecAttrAccessible as String)
      SecItemDelete(delete as CFDictionary)
    }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: RelayKeychain.account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecReturnAttributes as String: true,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
    XCTAssertEqual(readStatus, errSecSuccess)
    guard let attributes = item as? [String: Any] else { return XCTFail("no attributes returned") }

    // The assertions that matter: what the Keychain says it stored, not what we asked for.
    XCTAssertEqual(
      attributes[kSecAttrSynchronizable as String] as? Bool, false,
      "the stored item is synchronizable; an Apple ID compromise would reach this signing key"
    )
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
      "the accessibility class was not honored, which is the symptom of landing in the legacy keychain"
    )
    XCTAssertEqual((attributes[kSecValueData as String] as? Data)?.count, 32)
  }
}

/// In-memory `RelayKeyStore`, so mint discipline is provable without a Keychain.
private final class SpyKeyStore: RelayKeyStore {
  private var key: Curve25519.Signing.PrivateKey?
  private(set) var storeCallCount = 0
  var synchronizedShadow = false

  func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey? { key }

  func storePrivateKey(_ key: Curve25519.Signing.PrivateKey) throws {
    self.key = key
    storeCallCount += 1
  }

  func synchronizedItemExists() -> Bool { synchronizedShadow }
}
