import XCTest
import CryptoKit
import Security
@testable import MessagesForAIMenu

/// SUN-613 phase 1. The property under test: a device signing key is minted only when asked, is
/// non-extractable, and a machine without an enclave refuses rather than silently downgrading.
final class RelayIdentityTests: XCTestCase {

  private var home: URL!

  override func setUp() {
    super.setUp()
    home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ghostie-relay-identity-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    setenv("MESSAGES_FOR_AI_HOME", home.path, 1)
  }

  override func tearDown() {
    unsetenv("MESSAGES_FOR_AI_HOME")
    try? FileManager.default.removeItem(at: home)
    home = nil
    super.tearDown()
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

  func testEnsureKeyPairMintsOnceThenReuses() throws {
    try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this host")
    let store = SpyKeyStore()
    let identity = RelayDeviceIdentity(store: store)

    let first = try identity.ensureKeyPair()
    let second = try identity.ensureKeyPair()
    XCTAssertEqual(first.x963Representation, second.x963Representation)
    XCTAssertEqual(store.storeCallCount, 1, "a second call re-minted instead of reusing")
  }

  func testMissingEnclaveRefusesRatherThanDowngrading() {
    // A silent fallback to an extractable key would quietly weaken the send-authority boundary,
    // which is the entire reason this key lives in the enclave.
    let store = SpyKeyStore()
    store.enclaveAvailable = false
    let identity = RelayDeviceIdentity(store: store)

    XCTAssertThrowsError(try identity.ensureKeyPair()) { error in
      XCTAssertEqual(error as? RelayIdentityError, .secureEnclaveUnavailable)
    }
    XCTAssertEqual(store.storeCallCount, 0)
  }

  func testMalformedBlobIsAnErrorNotAReMint() {
    // Silently re-minting on a corrupt blob would let anyone who can damage a file rotate this
    // device's identity out from under an existing pairing.
    let store = SpyKeyStore()
    store.loadFailure = .malformedStoredKey
    let identity = RelayDeviceIdentity(store: store)

    XCTAssertThrowsError(try identity.ensureKeyPair()) { error in
      XCTAssertEqual(error as? RelayIdentityError, .malformedStoredKey)
    }
    XCTAssertEqual(store.storeCallCount, 0, "a corrupt blob caused a replacement key to be minted")
  }

  func testSigningProducesAVerifiableSignature() throws {
    try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this host")
    let store = SpyKeyStore()
    let identity = RelayDeviceIdentity(store: store)
    let publicKey = try identity.ensureKeyPair()

    let payload = Data("ghostie-relay-test".utf8)
    guard let raw = try identity.sign(payload) else { return XCTFail("expected a signature") }
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
    XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
    XCTAssertFalse(publicKey.isValidSignature(signature, for: Data("tampered".utf8)))
  }

  func testNoEnvironmentVariableCanSubstituteAKey() throws {
    try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this host")
    // ApprovalAuthenticator has an env seam for its HMAC secret; extending that to a SIGNING key
    // would be a key-injection backdoor. With the enclave it is not merely disallowed, it is
    // impossible: there is no raw private key to inject.
    setenv("MFA_TEST_RELAY_DEVICE_KEY", String(repeating: "a", count: 64), 1)
    defer { unsetenv("MFA_TEST_RELAY_DEVICE_KEY") }

    let identity = RelayDeviceIdentity(store: SpyKeyStore())
    let a = try identity.ensureKeyPair()
    let b = try RelayDeviceIdentity(store: SpyKeyStore()).ensureKeyPair()
    XCTAssertNotEqual(a.x963Representation, b.x963Representation,
                      "two independent mints produced the same key, so something is deterministic")
  }

  // MARK: - Enclave properties, measured rather than assumed
  //
  // These are the facts the design decision rests on. If any stops holding on future hardware or
  // a future macOS, the phase 1 storage choice needs revisiting, so they are pinned here.

  func testEnclaveKeyIsNonExtractableAndBlobRestoresToTheSameIdentity() throws {
    try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this host")
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    let blob = key.dataRepresentation

    // The persisted artifact is a wrapped handle, not the private scalar. A P-256 private key is
    // 32 bytes; anything meaningfully larger is a wrapped blob.
    XCTAssertGreaterThan(blob.count, 32, "the persisted blob looks like raw key material")

    let restored = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
    XCTAssertEqual(restored.publicKey.x963Representation, key.publicKey.x963Representation)

    let payload = Data("round-trip".utf8)
    let signature = try restored.signature(for: payload)
    XCTAssertTrue(key.publicKey.isValidSignature(signature, for: payload))
  }

  func testEnclaveNeedsNoKeychainEntitlement() throws {
    try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this host")
    // This is the measurement that decided the design. The data-protection keychain returns
    // errSecMissingEntitlement (-34018) for this unsigned binary; the enclave does not care.
    // If this ever starts throwing, the no-entitlement premise is gone and the relay's storage
    // choice has to be re-evaluated before phase 3 leans on it.
    XCTAssertNoThrow(try SecureEnclave.P256.Signing.PrivateKey())
  }

  // MARK: - On-disk blob store

  func testStoredBlobIsOwnerOnlyAndRestores() throws {
    try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this host")
    let store = SecureEnclaveRelayKeyStore()
    let identity = RelayDeviceIdentity(store: store)
    let minted = try identity.ensureKeyPair()

    let path = home.appendingPathComponent(".messages-mcp/relay/device-key.blob").path
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber
    XCTAssertEqual(mode?.int16Value, 0o600)

    // A fresh store reading the same blob must yield the same identity, or a relaunch would
    // silently become a different device to its peers.
    let reread = try RelayDeviceIdentity(store: SecureEnclaveRelayKeyStore()).publicKey()
    XCTAssertEqual(reread?.x963Representation, minted.x963Representation)
  }

  func testNoKeyMaterialExistsUntilEnrollmentAsks() throws {
    // The acceptance criterion behind "flag off means nothing is generated".
    let identity = RelayDeviceIdentity(store: SecureEnclaveRelayKeyStore())
    XCTAssertNil(try identity.publicKey())
    let path = home.appendingPathComponent(".messages-mcp/relay/device-key.blob").path
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }
}

/// In-memory `RelayKeyStore`, so mint discipline is provable without touching the enclave or disk.
private final class SpyKeyStore: RelayKeyStore {
  private var key: SecureEnclave.P256.Signing.PrivateKey?
  private(set) var storeCallCount = 0
  var enclaveAvailable = true
  var loadFailure: RelayIdentityError?

  var isEnclaveAvailable: Bool { enclaveAvailable }

  func loadKey() throws -> SecureEnclave.P256.Signing.PrivateKey? {
    if let loadFailure { throw loadFailure }
    return key
  }

  func storeKey(_ key: SecureEnclave.P256.Signing.PrivateKey) throws {
    self.key = key
    storeCallCount += 1
  }
}
