import Foundation
import Combine

/// Fetches, verifies, caches, and enforces the signed control manifest (issue #76).
///
/// Lifecycle:
///  - On launch: apply the cached (last-good, already-verified) manifest IMMEDIATELY
///    — a kill directive seen before survives offline/relaunch. Then kick a fetch.
///  - Every 15 minutes + on a manual "check now": fetch control.json + .sig, verify
///    the Ed25519 signature over the raw bytes, reject rollbacks (older issued_at),
///    cache the new good manifest, and apply it.
///
/// Fail behavior:
///  - A verified kill, once applied, STAYS applied even if later fetches fail.
///  - Fail-OPEN (normal operation) only when there is NO cached manifest AND the
///    fetch fails — a clean, genuinely-offline client is not bricked.
///
/// Enforcement (applied via SendGate + the daemon controllers + Sparkle):
///  - min_supported_version > current CFBundleShortVersionString ⇒ block ALL sends
///    and surface "Update required" (drives Sparkle via UpdaterController).
///  - kill.scope all ⇒ block sends + stop BOTH daemons, refuse relaunch while active.
///  - kill.scope send ⇒ block all sends only.
///  - kill.scope whatsapp/imessage ⇒ stop that daemon + block its sends.
///  - banner ⇒ dismissible banner in the popover.
@MainActor
final class ControlManifestController: ObservableObject {
  /// The currently-applied, verified manifest (cached or freshly fetched). nil
  /// until the first one is accepted.
  @Published private(set) var manifest: ControlManifest?
  /// True when the forced-upgrade floor blocks the app (current version < min).
  @Published private(set) var updateRequired = false
  /// The active kill scope (`none` when not killed).
  @Published private(set) var killScope: ControlManifest.KillScope = .none
  /// Banner the UI should show, or nil. The user can dismiss it (per issued_at).
  @Published var activeBanner: ControlManifest.Banner?
  /// Last time a fetch completed (success or failure) — for a Settings status line.
  @Published private(set) var lastCheck: Date?
  @Published private(set) var lastCheckError: String?

  /// On-disk cache of the last-good VERIFIED manifest's exact raw bytes. The two
  /// MCP processes (osascript / daemon send paths) read+verify these exact bytes
  /// to enforce the kill switch on their own sends, so byte-fidelity matters — we
  /// persist the fetched bytes verbatim, never a re-encoded model. (Issue #76.)
  private let cacheURL: URL
  /// The base64 detached Ed25519 signature for `cacheURL`'s bytes, written next to
  /// it. Verified on load (and by the MCPs) against SUPublicEDKey.
  private let cacheSignatureURL: URL
  private let manifestURL: URL
  private let signatureURL: URL
  private let publicKeyBase64: String
  private let currentVersion: String
  private let session: URLSession

  /// Persisted anti-rollback high-water mark, mirroring the MCP gates' sticky
  /// sidecar (`.control-*-state.json`). The in-memory `manifest` anchor is nil at
  /// launch, so the cache-load path has no anchor of its own — this UserDefaults
  /// pair gives it one that survives relaunch. Same local-write trust domain as
  /// the on-disk cache (an attacker who can plant a manifest can also rewrite
  /// these keys), so it raises the bar to match the MCP sticky; it is NOT claimed
  /// tamper-proof. The cache's signature check (`loadCached`) remains the real
  /// gate against a forged manifest.
  private let defaults: UserDefaults
  private static let highWaterIssuedAtKey = "controlManifest.highWater.issuedAtMs"
  private static let highWaterScopeKey = "controlManifest.highWater.killScope"
  private static let highWaterMinVersionKey = "controlManifest.highWater.minVersion"

  // Injected so enforcement can act on real app state. Weak to avoid retain cycles
  // (AppDelegate owns all of these plus this controller).
  private weak var imessageDaemon: IMessageDaemonController?
  private weak var whatsappDaemon: WhatsAppDaemonController?
  private weak var updater: UpdaterController?
  private weak var settings: SettingsStore?

  private var timer: Timer?
  private var dismissedBannerIssuedAt: String?

  static let fetchInterval: TimeInterval = 15 * 60

  init(
    homeOverride: URL? = nil,
    manifestURL: URL = URL(string: "https://messagesfor.ai/control.json")!,
    signatureURL: URL = URL(string: "https://messagesfor.ai/control.json.sig")!,
    publicKeyBase64: String? = nil,
    currentVersion: String? = nil,
    session: URLSession = .shared,
    defaults: UserDefaults = .standard
  ) {
    let home = homeOverride ?? AppStoragePaths.homeDirectory
    let dir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    self.cacheURL = dir.appendingPathComponent("control-manifest.json")
    self.cacheSignatureURL = dir.appendingPathComponent("control-manifest.json.sig")
    self.manifestURL = manifestURL
    self.signatureURL = signatureURL
    // Reuse the Sparkle Ed25519 public key embedded in the bundle. base64 → 32
    // raw bytes, fed to Curve25519.Signing.PublicKey(rawRepresentation:).
    self.publicKeyBase64 = publicKeyBase64
      ?? (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
      ?? ""
    self.currentVersion = currentVersion
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      ?? "0.0.0"
    self.session = session
    self.defaults = defaults
  }

  // MARK: - Wiring

  func configure(
    imessageDaemon: IMessageDaemonController,
    whatsappDaemon: WhatsAppDaemonController,
    updater: UpdaterController,
    settings: SettingsStore
  ) {
    self.imessageDaemon = imessageDaemon
    self.whatsappDaemon = whatsappDaemon
    self.updater = updater
    self.settings = settings
  }

  /// Load + apply the cached (signature-verified) manifest, if any. Returns true
  /// when a valid cached manifest was applied. Exposed for testing the
  /// launch-time cache path without the 15-minute timer / network fetch.
  ///
  /// The in-memory `manifest` anchor is nil at launch, so this path runs the SAME
  /// fail-safe UNION reconciliation against the PERSISTED high-water mark that the
  /// live fetch path (`checkNow`) does — the SAME decision the MCP
  /// `control-gate.ts` gates make against their sticky sidecar. Without this, a
  /// local attacker who plants an OLD but validly-signed `kill:none` manifest into
  /// the cache would lift an active kill at launch (until the next fetch); and an
  /// OLD narrow-scope kill could downgrade a broader recorded kill.
  @discardableResult
  func applyCachedManifest() -> Bool {
    guard let cached = loadCached() else { return false }
    applyReconciled(cached, persist: false)
    return true
  }

  /// Apply the cached manifest immediately, then start the 15-minute fetch loop.
  func start() {
    applyCachedManifest()
    timer = Timer.scheduledTimer(withTimeInterval: Self.fetchInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.checkNow() }
    }
    Task { await checkNow() }
  }

  deinit {
    timer?.invalidate()
  }

  /// True while a kill scope demands the given daemon stay down. The daemon
  /// controllers consult this before (re)launching so they refuse to relaunch
  /// under an active kill.
  func daemonSuppressed(_ platform: Platform) -> Bool {
    switch killScope {
    case .all: return true
    case .whatsapp: return platform == .whatsapp
    case .imessage: return platform == .imessage
    case .none, .send: return false
    }
  }

  // MARK: - Fetch + verify

  /// Pure rollback decision (anti-rollback anchor): accept a candidate only when
  /// its `issued_at` parses AND is strictly newer than the currently-applied one
  /// (or there is none yet). Exposed for testing.
  nonisolated static func shouldAccept(candidate: ControlManifest, current: ControlManifest?) -> Bool {
    guard let newDate = candidate.issuedAtDate else { return false }
    guard let current, let curDate = current.issuedAtDate else { return true }
    return newDate > curDate
  }

  func checkNow() async {
    do {
      let manifestData = try await fetch(manifestURL)
      let sigData = try await fetch(signatureURL)
      let sigString = String(data: sigData, encoding: .utf8) ?? ""

      guard ControlManifestVerifier.verify(
        manifestData: manifestData,
        signatureBase64: sigString,
        publicKeyBase64: publicKeyBase64
      ) else {
        lastCheck = Date()
        lastCheckError = "control manifest signature invalid — ignored"
        return
      }

      let fetched = try JSONDecoder().decode(ControlManifest.self, from: manifestData)

      // An unparseable issued_at can't anchor rollback — ignore it entirely
      // (the high-water / cache still govern enforcement).
      guard fetched.issuedAtDate != nil else {
        lastCheck = Date()
        lastCheckError = "control manifest issued_at unparseable — ignored"
        return
      }

      lastCheck = Date()
      lastCheckError = nil

      // Enforcement ALWAYS runs through the fail-safe UNION reconciliation against
      // the persisted high-water mark — NOT the strictly-newer `shouldAccept`
      // anchor. So an OLDER signed `none` fetched post-launch can no longer lift a
      // recorded kill, and an OLDER narrow-scope kill can no longer downgrade a
      // broader recorded kill. `shouldAccept` only decides whether to RE-PERSIST
      // the on-disk cache so the newest verified bytes back the MCP send paths.
      let refreshCache = Self.shouldAccept(candidate: fetched, current: manifest)
      applyReconciled(
        fetched,
        persist: refreshCache,
        rawData: refreshCache ? manifestData : nil,
        signatureBase64: refreshCache ? sigString : nil
      )
    } catch {
      lastCheck = Date()
      // Fail-open ONLY when there's no cached manifest at all. If we already have
      // one applied, leave its enforcement in place (sticky kill).
      lastCheckError = manifest == nil ? nil : "control manifest fetch failed: \(error.localizedDescription)"
    }
  }

  private func fetch(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  // MARK: - Apply enforcement (fail-safe UNION reconciliation)

  /// The reconciled, EFFECTIVE control state for a single incoming manifest folded
  /// with the persisted high-water mark. Enforcement (send-gate + daemon stop +
  /// forced-upgrade floor + UI/banner) runs off THIS, never the raw incoming
  /// manifest — so a rolled-back lift can't drop a recorded kill and a rolled-back
  /// narrow kill can't downgrade a recorded broader one.
  struct Effective {
    /// The most-restrictive combination of `incoming.scope` and (unless lifted)
    /// the high-water scope.
    let killScope: ControlManifest.KillScope
    /// Forced-upgrade floor: the max-semver of `incoming.min` and (unless lifted)
    /// the high-water min. nil/empty when no floor applies.
    let minVersion: String?
    /// True when `incoming` is a genuine, non-rollback `none` (it lifts the
    /// high-water kill rather than being unioned with it).
    let lifts: Bool
  }

  /// Fold one signature-verified `incoming` manifest with the persisted high-water
  /// mark into the effective control state, ratcheting the high-water UPWARD first.
  /// Pure w.r.t. UI state (only touches UserDefaults via the ratchet); enforcement
  /// is applied by `applyReconciled`. This is the single shared model used by BOTH
  /// the launch (cache) and live (fetch) paths — and it matches the MCP gates'
  /// sticky-sidecar reconciliation in `control-gate.ts`.
  ///
  ///   - ratchet: advance hw when incoming.issued_at >= hw.issued_at (or no hw).
  ///   - lifts := incoming.scope == none AND (no hw OR incomingMs >= hw.issuedAtMs)
  ///   - effective killScope := incoming.scope, unless an unlifted hw kill is
  ///     present, in which case incoming.scope.combined(with: hw.scope).
  ///   - effective floor := max-semver(incoming.min, hw.min unless lifts).
  func reconcile(_ incoming: ControlManifest) -> Effective {
    let hw = highWater()
    let incomingMs = incoming.issuedAtMs

    // Ratchet the persisted anti-rollback high-water mark UPWARD only. Records the
    // incoming scope + min when this manifest is at/after the recorded mark, so a
    // later-planted OLDER cache can't lift or downgrade a kill recorded here.
    ratchetHighWater(with: incoming)

    let hwPresent = hw.issuedAtMs != 0
    // A `none` incoming is a genuine lift only when it is NOT an older replay of
    // the high-water (issued_at >= the recorded mark, or no mark at all).
    let lifts = incoming.killScope == .none
      && (!hwPresent || (incomingMs.map { $0 >= hw.issuedAtMs } ?? false))

    // Effective kill scope: union the incoming scope with the high-water scope
    // UNLESS this is a genuine lift (then the incoming `none` stands alone).
    let effectiveScope: ControlManifest.KillScope
    if lifts || !hwPresent {
      effectiveScope = incoming.killScope
    } else {
      effectiveScope = incoming.killScope.combined(with: hw.scope)
    }

    // Effective forced-upgrade floor: the higher of the incoming min and the
    // high-water min (the latter dropped on a genuine lift).
    let incomingMin = incoming.min_supported_version.flatMap { $0.isEmpty ? nil : $0 }
    let hwMin = lifts ? nil : hw.minVersion.flatMap { $0.isEmpty ? nil : $0 }
    let effectiveMin = maxSemver(incomingMin, hwMin)

    return Effective(killScope: effectiveScope, minVersion: effectiveMin, lifts: lifts)
  }

  /// The single shared enforcement entry point. Folds `incoming` with the
  /// high-water mark (`reconcile`), then drives SendGate + the daemons + the
  /// forced-upgrade floor + the banner off the EFFECTIVE state — used by both
  /// `applyCachedManifest` (launch) and `checkNow` (fetch). `persist` writes the
  /// supplied verified bytes to the on-disk cache (only when they're the newest
  /// verified bytes, per `shouldAccept`); the on-disk byte format is unchanged.
  func applyReconciled(_ incoming: ControlManifest, persist: Bool, rawData: Data? = nil, signatureBase64: String? = nil) {
    let effective = reconcile(incoming)

    manifest = incoming
    killScope = effective.killScope

    // Forced-upgrade floor off the EFFECTIVE min (incoming ∪ high-water).
    if let min = effective.minVersion, !min.isEmpty {
      updateRequired = VersionCompare.isLess(currentVersion, than: min)
    } else {
      updateRequired = false
    }

    // Banner (respect a per-issued_at user dismissal). Banner travels with the
    // incoming manifest; it is not part of the kill/rollback union.
    if let banner = incoming.banner, dismissedBannerIssuedAt != incoming.issued_at {
      activeBanner = banner
    } else {
      activeBanner = nil
    }

    enforceSendGate(reason: incoming.kill?.reason)
    enforceDaemons()

    if updateRequired {
      // Surface the update path. Sparkle shows its own UI; the "Update required"
      // screen in the UI also offers this button.
      DiagnosticsStore.shared.log("forced_upgrade_required", metadata: ["min": effective.minVersion ?? ""])
    }
    if killScope != .none {
      // When the effective scope came from the high-water (a blocked rollback),
      // note it so the diagnostics show why a lift/downgrade was refused.
      if effective.killScope != incoming.killScope {
        DiagnosticsStore.shared.log(
          "control_manifest_rollback_blocked",
          metadata: ["incoming": incoming.killScope.rawValue, "effective": killScope.rawValue]
        )
      }
      DiagnosticsStore.shared.log("kill_switch_applied", metadata: ["scope": killScope.rawValue])
    }

    if persist, let rawData, let signatureBase64 {
      persistCache(rawData: rawData, signatureBase64: signatureBase64)
    }
  }

  /// Direct-apply seam (no high-water union beyond the ratchet). Retained for
  /// callers/tests that apply a manifest as the sole source of truth — it routes
  /// through the same reconciliation, so with an absent/older-or-equal high-water
  /// the effective scope equals the manifest's own scope.
  func apply(_ m: ControlManifest, persist: Bool, rawData: Data? = nil, signatureBase64: String? = nil) {
    applyReconciled(m, persist: persist, rawData: rawData, signatureBase64: signatureBase64)
  }

  private func enforceSendGate(reason killReason: String?) {
    // ALL sends blocked when: forced upgrade, or the effective kill blocks BOTH
    // platforms. Per-platform blocks come from the effective scope's `blocks(_:)`.
    let allBlocked = updateRequired
      || (killScope.blocks(.imessage) && killScope.blocks(.whatsapp))
    var platforms = Set<Platform>()
    if killScope.blocks(.imessage) { platforms.insert(.imessage) }
    if killScope.blocks(.whatsapp) { platforms.insert(.whatsapp) }
    let reason: String?
    if updateRequired {
      reason = "An update is required before you can keep sending."
    } else if killScope != .none {
      reason = killReason ?? "Sending is temporarily disabled by the developer."
    } else {
      reason = nil
    }
    SendGate.shared.update(allBlocked: allBlocked, blockedPlatforms: platforms, reason: reason)
  }

  private func enforceDaemons() {
    // Stop the daemon(s) the EFFECTIVE kill scope targets; they refuse to relaunch
    // while `daemonSuppressed` is true (wired in the daemon controllers). `.send`
    // gates outbound sends but does NOT stop the daemons (mirrors the original
    // `case .none, .send: break`); `.all` and the per-platform scopes do.
    guard killScope != .send else { return }
    if killScope.blocks(.imessage) {
      Task { await imessageDaemon?.stop() }
    }
    if killScope.blocks(.whatsapp) {
      Task { await whatsappDaemon?.stop() }
    }
  }

  func dismissBanner() {
    dismissedBannerIssuedAt = manifest?.issued_at
    activeBanner = nil
  }

  /// Drive the Sparkle update flow from the "Update required" screen.
  func triggerUpdate() {
    updater?.checkForUpdates()
  }

  // MARK: - Persisted anti-rollback high-water mark

  /// The highest `issued_at` (epoch ms) ever applied, plus the kill scope AND
  /// forced-upgrade floor that manifest carried. Mirrors the MCP gates' sticky
  /// sidecar (`{issued_at_ms, kill_scope, min_version}`). `issuedAtMs == 0` (the
  /// default) means "no manifest ever applied" — no anchor yet.
  private func highWater() -> (issuedAtMs: Int64, scope: ControlManifest.KillScope, minVersion: String?) {
    let ms = Int64(defaults.double(forKey: Self.highWaterIssuedAtKey))
    let scope = ControlManifest.KillScope(rawValue: defaults.string(forKey: Self.highWaterScopeKey) ?? "")
      ?? .none
    let min = defaults.string(forKey: Self.highWaterMinVersionKey)
    return (ms, scope, (min?.isEmpty ?? true) ? nil : min)
  }

  /// Advance the high-water mark UPWARD only — when `m.issued_at` is strictly
  /// newer than the recorded mark (or there is none yet). Records the
  /// issued_at(ms), the scope, AND the forced-upgrade floor that manifest carried.
  /// An unparseable issued_at can't anchor rollback, so it's skipped.
  private func ratchetHighWater(with m: ControlManifest) {
    guard let ms = m.issuedAtMs else { return }
    let current = highWater()
    if current.issuedAtMs == 0 || ms > current.issuedAtMs {
      defaults.set(Double(ms), forKey: Self.highWaterIssuedAtKey)
      defaults.set(m.killScope.rawValue, forKey: Self.highWaterScopeKey)
      let min = m.min_supported_version.flatMap { $0.isEmpty ? nil : $0 }
      if let min {
        defaults.set(min, forKey: Self.highWaterMinVersionKey)
      } else {
        defaults.removeObject(forKey: Self.highWaterMinVersionKey)
      }
    }
  }

  /// The higher (more-restrictive) of two `min_supported_version` floors, or nil
  /// when both are absent. Uses the same numeric-component comparison as the
  /// forced-upgrade gate (`VersionCompare`).
  private func maxSemver(_ a: String?, _ b: String?) -> String? {
    switch (a, b) {
    case (nil, nil): return nil
    case let (x?, nil): return x
    case let (nil, y?): return y
    case let (x?, y?): return VersionCompare.order(x, y) == .orderedAscending ? y : x
    }
  }

  // MARK: - Cache (last-good verified manifest + its signature)

  /// Persist the EXACT verified bytes + the base64 detached signature, both atomic
  /// + 0600. The byte-for-byte fidelity is load-bearing: the two MCP processes
  /// re-verify these exact bytes against SUPublicEDKey to enforce the kill switch
  /// on their own (osascript / daemon) send paths — a re-encoded model would fail
  /// their signature check. (Issue #76.)
  private func persistCache(rawData: Data, signatureBase64: String) {
    do {
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try rawData.write(to: cacheURL, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
      let sigBytes = Data(signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
      try sigBytes.write(to: cacheSignatureURL, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheSignatureURL.path)
    } catch {
      // Best effort — enforcement is already live in memory.
    }
  }

  /// Load the cached manifest ONLY IF its detached signature still verifies over
  /// its exact bytes. A local tamper (e.g. planting `kill.scope=none` with a
  /// far-future `issued_at`) leaves the .json valid but breaks the signature, so
  /// it's rejected and never applied. Fail closed: a missing/invalid/unsigned
  /// cache returns nil. (Issue #76, round 2.)
  private func loadCached() -> ControlManifest? {
    guard let data = try? Data(contentsOf: cacheURL),
          let sigData = try? Data(contentsOf: cacheSignatureURL),
          let sigString = String(data: sigData, encoding: .utf8) else {
      return nil
    }
    guard ControlManifestVerifier.verify(
      manifestData: data,
      signatureBase64: sigString,
      publicKeyBase64: publicKeyBase64
    ) else {
      DiagnosticsStore.shared.log("control_manifest_cache_rejected", metadata: ["reason": "signature invalid"])
      return nil
    }
    return try? JSONDecoder().decode(ControlManifest.self, from: data)
  }
}
