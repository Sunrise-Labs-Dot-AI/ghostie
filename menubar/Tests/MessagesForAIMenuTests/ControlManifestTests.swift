import XCTest
import CryptoKit
@testable import MessagesForAIMenu

/// Issue #76: signed control manifest — signature verification (valid/invalid),
/// rollback rejection, version-floor comparison, and that a kill blocks the send
/// path via SendGate.
final class ControlManifestTests: XCTestCase {

  override func tearDown() {
    SendGate.shared.resetForTesting()
    super.tearDown()
  }

  // MARK: - Banner chrome

  func testCriticalControlBannerIsNotDismissible() {
    XCTAssertTrue(ControlManifestBannerChrome.isDismissible(.info))
    XCTAssertTrue(ControlManifestBannerChrome.isDismissible(.warning))
    XCTAssertFalse(ControlManifestBannerChrome.isDismissible(.critical))
  }

  func testControlBannerSeverityLabelsAreExplicit() {
    XCTAssertEqual(ControlManifestBannerChrome.severityLabel(for: .info), "Notice")
    XCTAssertEqual(ControlManifestBannerChrome.severityLabel(for: .warning), "Warning")
    XCTAssertEqual(ControlManifestBannerChrome.severityLabel(for: .critical), "Critical")
  }

  // MARK: - Signature verification

  func testValidSignatureVerifies() {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let manifestData = Data("""
    {"schema":1,"min_supported_version":"0.6.0","kill":{"scope":"none"},"banner":null,"issued_at":"2026-06-07T00:00:00Z"}
    """.utf8)
    let sig = try! key.signature(for: manifestData).base64EncodedString()
    XCTAssertTrue(ControlManifestVerifier.verify(manifestData: manifestData, signatureBase64: sig, publicKeyBase64: pub))
  }

  func testInvalidSignatureRejected() {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let manifestData = Data("{\"schema\":1,\"issued_at\":\"2026-06-07T00:00:00Z\"}".utf8)
    let sig = try! key.signature(for: manifestData).base64EncodedString()

    // Tamper the bytes after signing → signature no longer matches.
    var tampered = manifestData
    tampered.append(Data(" ".utf8))
    XCTAssertFalse(ControlManifestVerifier.verify(manifestData: tampered, signatureBase64: sig, publicKeyBase64: pub))

    // Wrong key → reject.
    let otherPub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    XCTAssertFalse(ControlManifestVerifier.verify(manifestData: manifestData, signatureBase64: sig, publicKeyBase64: otherPub))

    // Garbage inputs → reject (fail closed).
    XCTAssertFalse(ControlManifestVerifier.verify(manifestData: manifestData, signatureBase64: "!!!notbase64", publicKeyBase64: pub))
    XCTAssertFalse(ControlManifestVerifier.verify(manifestData: manifestData, signatureBase64: sig, publicKeyBase64: ""))
  }

  // MARK: - Rollback rejection

  func testRollbackRejected() {
    let newer = manifest(issuedAt: "2026-06-07T12:00:00Z", killScope: .send)
    let older = manifest(issuedAt: "2026-06-01T00:00:00Z", killScope: .none)
    let unparseable = manifest(issuedAt: "not-a-date", killScope: .all)

    // No current → accept the first.
    XCTAssertTrue(ControlManifestController.shouldAccept(candidate: newer, current: nil))
    // Older than current → reject (rollback).
    XCTAssertFalse(ControlManifestController.shouldAccept(candidate: older, current: newer))
    // Same issued_at → reject (not strictly newer).
    XCTAssertFalse(ControlManifestController.shouldAccept(candidate: newer, current: newer))
    // Strictly newer → accept.
    XCTAssertTrue(ControlManifestController.shouldAccept(candidate: newer, current: older))
    // Unparseable issued_at → reject.
    XCTAssertFalse(ControlManifestController.shouldAccept(candidate: unparseable, current: nil))
  }

  // MARK: - Version floor

  func testVersionFloorComparison() {
    XCTAssertTrue(VersionCompare.isLess("0.5.1", than: "0.6.0"))
    XCTAssertFalse(VersionCompare.isLess("0.6.0", than: "0.6.0"))
    XCTAssertFalse(VersionCompare.isLess("0.6.1", than: "0.6.0"))
    XCTAssertTrue(VersionCompare.isLess("0.6", than: "0.6.1"))
    XCTAssertFalse(VersionCompare.isLess("1.0.0", than: "0.9.9"))
  }

  // MARK: - Enforcement → SendGate

  @MainActor
  func testKillAllBlocksSendPath() {
    let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let controller = ControlManifestController(homeOverride: tmpHome(), publicKeyBase64: pub, currentVersion: "1.0.0")
    controller.apply(manifest(issuedAt: "2026-06-07T00:00:00Z", killScope: .all), persist: false)
    XCTAssertTrue(SendGate.shared.isAllBlocked)
    XCTAssertTrue(SendGate.shared.isBlocked(for: .imessage))
    XCTAssertTrue(SendGate.shared.isBlocked(for: .whatsapp))
  }

  @MainActor
  func testKillWhatsappBlocksOnlyWhatsapp() {
    let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let controller = ControlManifestController(homeOverride: tmpHome(), publicKeyBase64: pub, currentVersion: "1.0.0")
    controller.apply(manifest(issuedAt: "2026-06-07T00:00:00Z", killScope: .whatsapp), persist: false)
    XCTAssertFalse(SendGate.shared.isAllBlocked)
    XCTAssertTrue(SendGate.shared.isBlocked(for: .whatsapp))
    XCTAssertFalse(SendGate.shared.isBlocked(for: .imessage))
    XCTAssertTrue(controller.daemonSuppressed(.whatsapp))
    XCTAssertFalse(controller.daemonSuppressed(.imessage))
  }

  @MainActor
  func testForcedUpgradeBlocksAllSends() {
    let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let controller = ControlManifestController(homeOverride: tmpHome(), publicKeyBase64: pub, currentVersion: "0.5.0")
    var m = manifest(issuedAt: "2026-06-07T00:00:00Z", killScope: .none)
    m = ControlManifest(schema: 1, min_supported_version: "0.6.0", kill: m.kill, banner: nil, issued_at: m.issued_at)
    controller.apply(m, persist: false)
    XCTAssertTrue(controller.updateRequired)
    XCTAssertTrue(SendGate.shared.isAllBlocked)
  }

  // MARK: - Cache signature verification (round 2, #76)

  /// A tampered cached manifest (valid JSON, but the .sig doesn't verify) must be
  /// rejected on load — never applied. Otherwise a local tamper could plant
  /// kill.scope=none with a far-future issued_at and disable the kill switch.
  @MainActor
  func testTamperedCachedManifestRejectedOnLoad() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let dir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Plant a valid-looking manifest but a BOGUS signature (not for these bytes).
    let manifestBytes = Data("""
    {"schema":1,"min_supported_version":null,"kill":{"scope":"none","reason":null},"banner":null,"issued_at":"2099-01-01T00:00:00Z"}
    """.utf8)
    try manifestBytes.write(to: dir.appendingPathComponent("control-manifest.json"))
    try Data("not-a-real-signature".utf8).write(to: dir.appendingPathComponent("control-manifest.json.sig"))

    let controller = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0")
    XCTAssertFalse(controller.applyCachedManifest(), "a cache with a bad signature must not be applied")
    XCTAssertNil(controller.manifest, "no manifest should be applied from an invalid cache")
    XCTAssertEqual(controller.killScope, .none)
  }

  /// An empty .sig must also be rejected (fail closed) and not applied.
  @MainActor
  func testEmptySignatureCacheRejected() throws {
    let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let dir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("""
    {"schema":1,"kill":{"scope":"send","reason":null},"issued_at":"2099-01-01T00:00:00Z"}
    """.utf8).write(to: dir.appendingPathComponent("control-manifest.json"))
    try Data("".utf8).write(to: dir.appendingPathComponent("control-manifest.json.sig"))

    let controller = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0")
    XCTAssertFalse(controller.applyCachedManifest(), "an empty signature must fail closed")
    XCTAssertNil(controller.manifest)
  }

  /// A properly-signed cache loads and applies — including its kill scope.
  @MainActor
  func testValidlySignedCacheLoadsAndAppliesKill() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let dir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let manifestBytes = Data("""
    {"schema":1,"min_supported_version":null,"kill":{"scope":"all","reason":"halt"},"banner":null,"issued_at":"2026-06-07T00:00:00Z"}
    """.utf8)
    let sig = try key.signature(for: manifestBytes).base64EncodedString()
    try manifestBytes.write(to: dir.appendingPathComponent("control-manifest.json"))
    try Data(sig.utf8).write(to: dir.appendingPathComponent("control-manifest.json.sig"))

    let controller = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0")
    XCTAssertTrue(controller.applyCachedManifest(), "a validly-signed cache must be applied")
    XCTAssertEqual(controller.killScope, .all)
    XCTAssertTrue(SendGate.shared.isAllBlocked)
  }

  /// Persisted cache must be the EXACT verified bytes + the base64 sig, at the
  /// paths the MCPs read. A re-encode would break the MCPs' own signature check.
  @MainActor
  func testPersistedCacheIsByteIdenticalAndSignaturePresent() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let controller = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0")

    // Note the unusual key order / spacing: if apply() re-encoded the model, these
    // bytes would change and the round-trip below would fail.
    let manifestBytes = Data("""
    {"kill":{"reason":null,"scope":"send"},"schema":1,"issued_at":"2026-06-07T00:00:00Z","banner":null,"min_supported_version":null}
    """.utf8)
    let sig = try key.signature(for: manifestBytes).base64EncodedString()
    let fetched = try JSONDecoder().decode(ControlManifest.self, from: manifestBytes)

    controller.apply(fetched, persist: true, rawData: manifestBytes, signatureBase64: sig)

    let dir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    let cachedBytes = try Data(contentsOf: dir.appendingPathComponent("control-manifest.json"))
    XCTAssertEqual(cachedBytes, manifestBytes, "cache must be byte-identical to the verified fetch")
    let cachedSig = try String(contentsOf: dir.appendingPathComponent("control-manifest.json.sig"), encoding: .utf8)
    XCTAssertEqual(cachedSig, sig, "cache .sig must be the base64 detached signature")
    // And it must re-verify against the same key the MCPs use.
    XCTAssertTrue(ControlManifestVerifier.verify(manifestData: cachedBytes, signatureBase64: cachedSig, publicKeyBase64: pub))
  }

  // MARK: - Persisted anti-rollback high-water (launch/cache path, Codex gap)

  /// (a) A validly-signed cached `kill:none` whose issued_at is OLDER than a
  /// persisted high-water KILL must NOT lift the kill on launch — it's a
  /// rollback/replay. The high-water scope is enforced instead. This is the gap
  /// Codex flagged: the cache-load path had no anti-rollback anchor.
  @MainActor
  func testOlderCachedNoneDoesNotLiftPersistedKillOnLaunch() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // Persist a high-water KILL at a later issued_at than the cache will carry.
    defaults.set(Double(ms("2026-06-07T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.all.rawValue, forKey: "controlManifest.highWater.killScope")

    // Plant a validly-signed OLDER `kill:none` cache (the rollback an attacker wants).
    writeSignedCache(
      in: home, key: key,
      json: #"{"schema":1,"min_supported_version":null,"kill":{"scope":"none","reason":null},"banner":null,"issued_at":"2026-06-01T00:00:00Z"}"#
    )

    let controller = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0", defaults: defaults)
    XCTAssertTrue(controller.applyCachedManifest())
    XCTAssertEqual(controller.killScope, .all, "older cached none must not lift the high-water kill")
    XCTAssertTrue(SendGate.shared.isAllBlocked)
    XCTAssertTrue(controller.daemonSuppressed(.imessage))
    XCTAssertTrue(controller.daemonSuppressed(.whatsapp))
    // The anchor must NOT advance off a rolled-back replay.
    XCTAssertEqual(Int64(defaults.double(forKey: "controlManifest.highWater.issuedAtMs")), ms("2026-06-07T00:00:00Z"))
  }

  /// (b) A validly-signed cached KILL is applied on launch even if its issued_at
  /// is OLDER than the persisted high-water — present kill always wins (fail safe).
  @MainActor
  func testOlderCachedKillStillAppliedOnLaunch() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // High-water recorded at a LATER time, but with NO kill (scope none).
    defaults.set(Double(ms("2026-06-07T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.none.rawValue, forKey: "controlManifest.highWater.killScope")

    // Older cached manifest that DOES declare a kill.
    writeSignedCache(
      in: home, key: key,
      json: #"{"schema":1,"min_supported_version":null,"kill":{"scope":"send","reason":"halt"},"banner":null,"issued_at":"2026-06-01T00:00:00Z"}"#
    )

    let controller = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0", defaults: defaults)
    XCTAssertTrue(controller.applyCachedManifest())
    XCTAssertEqual(controller.killScope, .send, "a present kill wins even when older than the high-water")
    XCTAssertTrue(SendGate.shared.isAllBlocked)
  }

  /// (c) A cached `none` that is NEWER than the persisted high-water kill DOES
  /// lift the kill normally (not a rollback) and advances the anchor.
  @MainActor
  func testNewerCachedNoneLiftsKillNormally() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // High-water kill at an EARLIER time than the cache will carry.
    defaults.set(Double(ms("2026-06-01T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.all.rawValue, forKey: "controlManifest.highWater.killScope")

    writeSignedCache(
      in: home, key: key,
      json: #"{"schema":1,"min_supported_version":null,"kill":{"scope":"none","reason":null},"banner":null,"issued_at":"2026-06-07T00:00:00Z"}"#
    )

    let controller = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0", defaults: defaults)
    XCTAssertTrue(controller.applyCachedManifest())
    XCTAssertEqual(controller.killScope, .none, "a newer none must lift the kill")
    XCTAssertFalse(SendGate.shared.isAllBlocked)
    // Anchor advances to the lift, recording scope none.
    XCTAssertEqual(Int64(defaults.double(forKey: "controlManifest.highWater.issuedAtMs")), ms("2026-06-07T00:00:00Z"))
    XCTAssertEqual(defaults.string(forKey: "controlManifest.highWater.killScope"), ControlManifest.KillScope.none.rawValue)
  }

  /// (d) The high-water ratchets UPWARD on apply() and SURVIVES a simulated
  /// relaunch — a fresh controller reading the same defaults sees it and uses it
  /// to reject a stale cached lift.
  @MainActor
  func testHighWaterRatchetsAndSurvivesRelaunch() throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // Session 1: apply a KILL (e.g. arriving via a fetch). This ratchets the anchor.
    let controller1 = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0", defaults: defaults)
    controller1.apply(manifest(issuedAt: "2026-06-07T00:00:00Z", killScope: .all), persist: false)
    XCTAssertEqual(Int64(defaults.double(forKey: "controlManifest.highWater.issuedAtMs")), ms("2026-06-07T00:00:00Z"))
    XCTAssertEqual(defaults.string(forKey: "controlManifest.highWater.killScope"), ControlManifest.KillScope.all.rawValue)

    // An older apply must NOT lower the anchor.
    controller1.apply(manifest(issuedAt: "2026-05-01T00:00:00Z", killScope: .none), persist: false)
    XCTAssertEqual(Int64(defaults.double(forKey: "controlManifest.highWater.issuedAtMs")), ms("2026-06-07T00:00:00Z"),
                   "high-water must only ratchet upward")

    // Simulated relaunch: NEW controller instance, SAME defaults + a planted older
    // `none` cache. The persisted anchor must make it reject the stale lift.
    writeSignedCache(
      in: home, key: key,
      json: #"{"schema":1,"min_supported_version":null,"kill":{"scope":"none","reason":null},"banner":null,"issued_at":"2026-06-02T00:00:00Z"}"#
    )
    let controller2 = ControlManifestController(homeOverride: home, publicKeyBase64: pub, currentVersion: "1.0.0", defaults: defaults)
    XCTAssertTrue(controller2.applyCachedManifest())
    XCTAssertEqual(controller2.killScope, .all, "the persisted anchor must survive relaunch and block the rollback")
    XCTAssertTrue(SendGate.shared.isAllBlocked)
  }

  // MARK: - Fail-safe UNION reconciliation on the LIVE (checkNow) fetch path
  //
  // Adversarial-review gap: the live fetch path used `shouldAccept(strictly-newer)`
  // and applied the raw incoming manifest, so a post-launch fetch of an OLDER
  // validly-signed manifest could lift or downgrade a high-water kill. The fix runs
  // the SAME fail-safe UNION reconciliation against the persisted high-water on BOTH
  // the launch (cache) and live (fetch) paths.

  /// (a) Post-launch, a `checkNow` fetch of an OLDER signed `none` must NOT lift a
  /// persisted high-water kill. (The older `none` is newer than the cached file but
  /// older than the high-water — the exact replay the finding describes.)
  @MainActor
  func testCheckNowOlderSignedNoneDoesNotLiftHighWaterKill() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // Launch enforced an `all` kill at a LATER issued_at than the fetch will carry.
    defaults.set(Double(ms("2026-06-07T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.all.rawValue, forKey: "controlManifest.highWater.killScope")

    // The server now serves an OLDER validly-signed `kill:none` (the rollback).
    let json = #"{"schema":1,"min_supported_version":null,"kill":{"scope":"none","reason":null},"banner":null,"issued_at":"2026-06-01T00:00:00Z"}"#
    let controller = checkNowController(home: home, key: key, pub: pub, defaults: defaults, json: json)

    await controller.checkNow()

    XCTAssertEqual(controller.killScope, .all, "an older fetched none must NOT lift the high-water kill")
    XCTAssertTrue(SendGate.shared.isAllBlocked)
    XCTAssertTrue(controller.daemonSuppressed(.imessage))
    XCTAssertTrue(controller.daemonSuppressed(.whatsapp))
    // Anchor must NOT regress off the rolled-back replay.
    XCTAssertEqual(Int64(defaults.double(forKey: "controlManifest.highWater.issuedAtMs")), ms("2026-06-07T00:00:00Z"))
  }

  /// (b) Post-launch, a `checkNow` fetch of an OLDER signed `whatsapp`-scope kill
  /// must NOT unblock iMessage when the high-water is `all` (narrow rollback can't
  /// downgrade a broader recorded kill). The effective scope stays `all`.
  @MainActor
  func testCheckNowOlderNarrowKillDoesNotDowngradeBroaderHighWater() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // High-water `all` kill recorded at a LATER issued_at.
    defaults.set(Double(ms("2026-06-07T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.all.rawValue, forKey: "controlManifest.highWater.killScope")

    // Server serves an OLDER validly-signed narrow `whatsapp` kill.
    let json = #"{"schema":1,"min_supported_version":null,"kill":{"scope":"whatsapp","reason":"narrow"},"banner":null,"issued_at":"2026-06-01T00:00:00Z"}"#
    let controller = checkNowController(home: home, key: key, pub: pub, defaults: defaults, json: json)

    await controller.checkNow()

    XCTAssertEqual(controller.killScope, .all, "an older narrow kill must NOT downgrade the broader high-water kill")
    XCTAssertTrue(SendGate.shared.isBlocked(for: .imessage), "iMessage must stay blocked under the all high-water")
    XCTAssertTrue(SendGate.shared.isBlocked(for: .whatsapp))
    XCTAssertTrue(controller.daemonSuppressed(.imessage))
  }

  /// (c) A genuinely NEWER signed `none` fetched by `checkNow` DOES lift the
  /// high-water kill and advances the anchor (not a rollback).
  @MainActor
  func testCheckNowNewerSignedNoneLiftsKill() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // High-water kill recorded EARLIER than the fetch will carry.
    defaults.set(Double(ms("2026-06-01T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.all.rawValue, forKey: "controlManifest.highWater.killScope")

    let json = #"{"schema":1,"min_supported_version":null,"kill":{"scope":"none","reason":null},"banner":null,"issued_at":"2026-06-07T00:00:00Z"}"#
    let controller = checkNowController(home: home, key: key, pub: pub, defaults: defaults, json: json)

    await controller.checkNow()

    XCTAssertEqual(controller.killScope, .none, "a genuinely newer none must lift the kill")
    XCTAssertFalse(SendGate.shared.isAllBlocked)
    XCTAssertFalse(controller.daemonSuppressed(.imessage))
    // Anchor advances to the lift, recording scope none.
    XCTAssertEqual(Int64(defaults.double(forKey: "controlManifest.highWater.issuedAtMs")), ms("2026-06-07T00:00:00Z"))
    XCTAssertEqual(defaults.string(forKey: "controlManifest.highWater.killScope"), ControlManifest.KillScope.none.rawValue)
  }

  /// (d) A NEWER signed kill fetched by `checkNow` applies (and ratchets the
  /// anchor) — the normal forward path still works.
  @MainActor
  func testCheckNowNewerKillApplies() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // No high-water yet; a fresh kill arrives.
    let json = #"{"schema":1,"min_supported_version":null,"kill":{"scope":"send","reason":"halt"},"banner":null,"issued_at":"2026-06-07T00:00:00Z"}"#
    let controller = checkNowController(home: home, key: key, pub: pub, defaults: defaults, json: json)

    await controller.checkNow()

    XCTAssertEqual(controller.killScope, .send)
    XCTAssertTrue(SendGate.shared.isAllBlocked, "scope send blocks all sends")
    // `.send` gates sends but does not suppress the daemons.
    XCTAssertFalse(controller.daemonSuppressed(.imessage))
    XCTAssertEqual(Int64(defaults.double(forKey: "controlManifest.highWater.issuedAtMs")), ms("2026-06-07T00:00:00Z"))
    XCTAssertEqual(defaults.string(forKey: "controlManifest.highWater.killScope"), ControlManifest.KillScope.send.rawValue)
  }

  /// imessage + whatsapp high-water union → all. An older `imessage` kill fetched
  /// when the high-water is `whatsapp` must block BOTH transports (the union of two
  /// single-platform kills is `all`).
  @MainActor
  func testCheckNowSinglePlatformKillsUnionToAll() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // High-water `whatsapp` kill at a LATER issued_at.
    defaults.set(Double(ms("2026-06-07T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.whatsapp.rawValue, forKey: "controlManifest.highWater.killScope")

    // Older `imessage` kill fetched.
    let json = #"{"schema":1,"min_supported_version":null,"kill":{"scope":"imessage","reason":"x"},"banner":null,"issued_at":"2026-06-01T00:00:00Z"}"#
    let controller = checkNowController(home: home, key: key, pub: pub, defaults: defaults, json: json)

    await controller.checkNow()

    XCTAssertEqual(controller.killScope, .all, "imessage ∪ whatsapp must combine to all")
    XCTAssertTrue(SendGate.shared.isBlocked(for: .imessage))
    XCTAssertTrue(SendGate.shared.isBlocked(for: .whatsapp))
    XCTAssertTrue(controller.daemonSuppressed(.imessage))
    XCTAssertTrue(controller.daemonSuppressed(.whatsapp))
  }

  /// An older fetched `none` cannot drop a high-water forced-upgrade floor either:
  /// the effective floor is the UNION (max-semver) of incoming and high-water min.
  @MainActor
  func testCheckNowOlderNoneDoesNotDropHighWaterUpgradeFloor() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let home = tmpHome()
    let defaults = tmpDefaults()

    // High-water recorded a forced-upgrade floor at a LATER issued_at.
    defaults.set(Double(ms("2026-06-07T00:00:00Z")), forKey: "controlManifest.highWater.issuedAtMs")
    defaults.set(ControlManifest.KillScope.none.rawValue, forKey: "controlManifest.highWater.killScope")
    defaults.set("0.6.0", forKey: "controlManifest.highWater.minVersion")

    // Older `none` with no floor — must not drop the recorded floor.
    let json = #"{"schema":1,"min_supported_version":null,"kill":{"scope":"none","reason":null},"banner":null,"issued_at":"2026-06-01T00:00:00Z"}"#
    let controller = checkNowController(home: home, key: key, pub: pub, defaults: defaults, json: json, currentVersion: "0.5.0")

    await controller.checkNow()

    XCTAssertTrue(controller.updateRequired, "an older none must not drop the high-water forced-upgrade floor")
    XCTAssertTrue(SendGate.shared.isAllBlocked)
  }

  // MARK: - Helpers

  /// Sign `json` with `key` and write it (plus its base64 detached sig) to the
  /// cache paths the controller reads. Mirrors how the production cache is laid out.
  private func writeSignedCache(in home: URL, key: Curve25519.Signing.PrivateKey, json: String) {
    let dir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bytes = Data(json.utf8)
    let sig = (try? key.signature(for: bytes).base64EncodedString()) ?? ""
    try? bytes.write(to: dir.appendingPathComponent("control-manifest.json"))
    try? Data(sig.utf8).write(to: dir.appendingPathComponent("control-manifest.json.sig"))
  }

  /// Build a controller whose URLSession serves `json` (and its detached Ed25519
  /// sig, signed with `key`) from the manifest + sig URLs `checkNow` fetches —
  /// driving the LIVE fetch path through the reconciliation under test.
  @MainActor
  private func checkNowController(
    home: URL,
    key: Curve25519.Signing.PrivateKey,
    pub: String,
    defaults: UserDefaults,
    json: String,
    currentVersion: String = "1.0.0"
  ) -> ControlManifestController {
    let manifestURL = URL(string: "https://test.invalid/control.json")!
    let sigURL = URL(string: "https://test.invalid/control.json.sig")!
    let bytes = Data(json.utf8)
    let sig = try! key.signature(for: bytes).base64EncodedString()

    StubURLProtocol.responses = [
      manifestURL: bytes,
      sigURL: Data(sig.utf8),
    ]

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)

    return ControlManifestController(
      homeOverride: home,
      manifestURL: manifestURL,
      signatureURL: sigURL,
      publicKeyBase64: pub,
      currentVersion: currentVersion,
      session: session,
      defaults: defaults
    )
  }

  /// epoch ms for an ISO-8601 string, matching ControlManifest.issuedAtMs.
  private func ms(_ iso: String) -> Int64 {
    ControlManifest(schema: 1, min_supported_version: nil, kill: nil, banner: nil, issued_at: iso).issuedAtMs ?? 0
  }

  /// A throwaway, isolated UserDefaults suite so the persisted high-water mark in
  /// one test never leaks into another (and a "relaunch" reuses the SAME suite).
  private func tmpDefaults() -> UserDefaults {
    let name = "control-manifest-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  private func manifest(issuedAt: String, killScope: ControlManifest.KillScope) -> ControlManifest {
    ControlManifest(
      schema: 1, min_supported_version: nil,
      kill: ControlManifest.Kill(scope: killScope, reason: "test"),
      banner: nil, issued_at: issuedAt
    )
  }

  private func tmpHome() -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("control-manifest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }
}

/// In-memory `URLProtocol` stub: serves a fixed byte body per absolute URL so the
/// `checkNow` fetch path (manifest + detached sig) can be driven offline. A 404 is
/// returned for any unregistered URL.
final class StubURLProtocol: URLProtocol {
  /// URL → response body. Set per-test before driving `checkNow`.
  nonisolated(unsafe) static var responses: [URL: Data] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let body = StubURLProtocol.responses[url] else {
      let resp = HTTPURLResponse(url: request.url ?? URL(string: "https://test.invalid/")!,
                                 statusCode: 404, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
