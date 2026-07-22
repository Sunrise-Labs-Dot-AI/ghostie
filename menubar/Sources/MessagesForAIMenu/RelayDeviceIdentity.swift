import Foundation
import CryptoKit
import Security

/// This device's signing identity for the cross-device relay (SUN-613).
///
/// Phase 0 gave each machine a non-secret `device_id` (`DeviceIdentity`) that says WHICH machine
/// owns a draft. This is the other half: the key that lets a device prove it is the one saying so.
/// Phase 1 only mints and stores it. Pairing, which turns a local keypair into a mutual trust
/// relationship, lives in phase 2 where there is a transport to run a ceremony over.
///
/// ## Why the Secure Enclave, and not an Ed25519 key in the Keychain
///
/// The first design stored a raw `Curve25519.Signing.PrivateKey` in the Keychain. Three measured
/// facts killed it:
///
///  - The **data-protection keychain**, which is the only macOS keychain that honors
///    `kSecAttrAccessible`, returns `errSecMissingEntitlement` (-34018) without a
///    keychain-access-group entitlement. That entitlement needs a provisioning profile, which is
///    precisely the fleet-wide launch dependency this whole design exists to avoid (see the
///    CloudKit rejection in `docs/plans/cross-device-draft-sync-spec.md`).
///  - The **legacy file-based keychain** accepts the write and then reports `synchronizable = nil`
///    and `accessible = nil` on readback. The attributes are simply not recorded, so the
///    "never syncs, never leaves this Mac" property could be asserted but never verified. An
///    unverifiable guarantee is not a guarantee, and this key is a send-authority boundary.
///  - Ghostie signs every inner Mach-O with ONE codesign identifier, deliberately, because daemon
///    peer-auth depends on it. So a keychain item is reachable by the bundled MCP binaries too,
///    and separating them would need that same entitlement.
///
/// The Secure Enclave dissolves all three. Verified on this hardware: `isAvailable == true`,
/// create/sign/verify works in an unsigned binary with no entitlement, and the 284-byte opaque
/// blob restores to an identical public key. The private key is **non-extractable**: what we
/// persist is a wrapped blob that is useless on any other machine and useless to any process that
/// reads the file, which is a stronger property than the Keychain could have given us.
///
/// P-256 also happens to be the curve WebCrypto supports most universally, so the phase 3 phone
/// client gets easier rather than harder.
///
/// Accepted cost: this requires Apple silicon or a T2. Both target Macs qualify. On hardware
/// without an enclave the relay refuses to enroll with a clear message rather than silently
/// falling back to a weaker store.
enum RelayIdentityError: Error, Equatable {
  /// No Secure Enclave on this Mac. We refuse rather than fall back: a silent downgrade to an
  /// extractable key would quietly weaken the send-authority boundary.
  case secureEnclaveUnavailable
  /// The enclave refused to create or restore the key.
  case keyUnavailable(String)
  /// The persisted blob exists but is not a usable enclave key: truncated, corrupt, or minted by
  /// a different machine. Never silently re-minted, because that would let anyone who can delete
  /// a file rotate this device's identity out from under an existing pairing.
  case malformedStoredKey
}

/// Seam for tests. The only production implementation is `SecureEnclaveRelayKeyStore`.
protocol RelayKeyStore {
  func loadKey() throws -> SecureEnclave.P256.Signing.PrivateKey?
  func storeKey(_ key: SecureEnclave.P256.Signing.PrivateKey) throws
  var isEnclaveAvailable: Bool { get }
}

/// Persists the enclave's wrapped key blob at `~/.messages-mcp/relay/device-key.blob`.
///
/// File hardening here buys AVAILABILITY, not secrecy: the blob is worthless off this machine and
/// worthless without the enclave, so an attacker who reads it gains nothing, and one who tampers
/// with it only causes a restore failure. That is a deliberately different security posture from
/// `ApprovalAuthenticator`, where the stored bytes ARE the secret.
struct SecureEnclaveRelayKeyStore: RelayKeyStore {
  var isEnclaveAvailable: Bool { SecureEnclave.isAvailable }

  private var directory: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp", isDirectory: true)
      .appendingPathComponent("relay", isDirectory: true)
  }

  private var blobURL: URL { directory.appendingPathComponent("device-key.blob") }

  func loadKey() throws -> SecureEnclave.P256.Signing.PrivateKey? {
    // O_NOFOLLOW + fstat, matching the discipline phase 0 established for device.json.
    let fd = open(blobURL.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
      return nil
    }
    guard let blob = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
          !blob.isEmpty
    else { return nil }

    do {
      return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
    } catch {
      // A present-but-unusable blob is an error, never an invitation to mint a replacement.
      throw RelayIdentityError.malformedStoredKey
    }
  }

  func storeKey(_ key: SecureEnclave.P256.Signing.PrivateKey) throws {
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let payload = key.dataRepresentation
    let tempPath = directory.appendingPathComponent(".device-key.\(getpid()).\(UUID().uuidString).tmp").path

    let fd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { throw RelayIdentityError.keyUnavailable("could not create \(tempPath)") }

    var ok = true
    payload.withUnsafeBytes { buf in
      guard var base = buf.baseAddress else { ok = false; return }
      var remaining = buf.count
      while remaining > 0 {
        let n = write(fd, base, remaining)
        if n <= 0 { ok = false; return }
        remaining -= n
        base = base.advanced(by: n)
      }
    }
    if ok { ok = (fsync(fd) == 0) }
    close(fd)
    guard ok else {
      unlink(tempPath)
      throw RelayIdentityError.keyUnavailable("short write persisting the device key")
    }
    // link(2) is atomic and fails if the name exists, so a racing mint loses safely.
    guard link(tempPath, blobURL.path) == 0 else {
      unlink(tempPath)
      throw RelayIdentityError.keyUnavailable("another process published a device key first")
    }
    unlink(tempPath)
  }
}

struct RelayDeviceIdentity {
  private let store: RelayKeyStore

  init(store: RelayKeyStore = SecureEnclaveRelayKeyStore()) {
    self.store = store
  }

  /// This device's public key, or nil when no identity has been minted. Never mints as a side
  /// effect of being asked: a read must not create key material on a machine where the relay is
  /// switched off.
  func publicKey() throws -> P256.Signing.PublicKey? {
    try store.loadKey()?.publicKey
  }

  /// Base64 of the X9.63 public key, the form the pairing transcript and peer trust store carry
  /// from phase 2 onward.
  func publicKeyBase64() throws -> String? {
    try publicKey()?.x963Representation.base64EncodedString()
  }

  /// Mint the identity if absent, and return the public key. **Enrollment calls this. Nothing
  /// else does.**
  @discardableResult
  func ensureKeyPair() throws -> P256.Signing.PublicKey {
    if let existing = try store.loadKey() { return existing.publicKey }
    guard store.isEnclaveAvailable else { throw RelayIdentityError.secureEnclaveUnavailable }
    do {
      let key = try SecureEnclave.P256.Signing.PrivateKey()
      try store.storeKey(key)
      return key.publicKey
    } catch let error as RelayIdentityError {
      throw error
    } catch {
      throw RelayIdentityError.keyUnavailable(String(describing: error))
    }
  }

  /// Sign with the device identity. Returns nil when no identity exists, so a caller can never
  /// cause one to be minted by trying to sign.
  func sign(_ payload: Data) throws -> Data? {
    guard let key = try store.loadKey() else { return nil }
    return try key.signature(for: payload).rawRepresentation
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
