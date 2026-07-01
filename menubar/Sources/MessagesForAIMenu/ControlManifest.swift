import Foundation
import CryptoKit

/// A signed, cloud-controlled control manifest: the forced-upgrade floor + remote
/// kill switch + an optional in-app banner. (Issue #76.)
///
/// Hosted as a tiny static `control.json` on `messagesfor.ai` (CDN-fronted) with a
/// detached `control.json.sig` next to it. The client verifies the signature with
/// Ed25519 (CryptoKit) over the EXACT raw bytes of control.json before honoring
/// anything, reusing the Sparkle EdDSA public key already embedded in the bundle
/// as `SUPublicEDKey`. A site/CDN compromise or MITM therefore can't brick or
/// hijack the fleet — only the holder of the matching private key can.
struct ControlManifest: Codable, Equatable {
  enum KillScope: String, Codable, Equatable {
    case none
    case all
    case send
    case whatsapp
    case imessage

    /// Does this kill scope block a send on `platform`? Mirrors the MCP gates'
    /// `killBlocksIMessage` / `killBlocksWhatsApp`: `.all` and `.send` block BOTH
    /// platforms; `.imessage` / `.whatsapp` block only their own; `.none` blocks
    /// nothing.
    func blocks(_ platform: Platform) -> Bool {
      switch self {
      case .all, .send: return true
      case .imessage: return platform == .imessage
      case .whatsapp: return platform == .whatsapp
      case .none: return false
      }
    }

    /// The most-restrictive UNION of two kill scopes (fail-safe combine). Used to
    /// fold an incoming manifest's scope with the persisted high-water scope so a
    /// rolled-back narrow kill can't downgrade a broader recorded one:
    ///   - `.all` wins over everything.
    ///   - `.send` + any single-platform scope → `.send` (both platforms blocked).
    ///   - `.imessage` + `.whatsapp` → `.all` (both platforms + both daemons down).
    ///   - any scope combined with `.none` (or itself) → preserved unchanged.
    func combined(with other: KillScope) -> KillScope {
      if self == other { return self }
      if self == .none { return other }
      if other == .none { return self }
      if self == .all || other == .all { return .all }
      // From here both are non-none, non-all, and different.
      let pair: Set<KillScope> = [self, other]
      // send + (imessage|whatsapp) → send blocks both send paths already.
      if pair.contains(.send) { return .send }
      // imessage + whatsapp → both transports down ⇒ all.
      if pair == [.imessage, .whatsapp] { return .all }
      // Fallback (unreachable given the cases above): be conservative.
      return .all
    }
  }

  enum BannerLevel: String, Codable, Equatable {
    case info
    case warning
    case critical
  }

  struct Kill: Codable, Equatable {
    let scope: KillScope
    let reason: String?
  }

  struct Banner: Codable, Equatable {
    let level: BannerLevel
    let text: String
    let url: String?
  }

  let schema: Int
  let min_supported_version: String?
  let kill: Kill?
  let banner: Banner?
  /// ISO-8601 UTC. Monotonic anti-rollback anchor: the client rejects any manifest
  /// whose `issued_at` is not strictly newer than the last one it accepted.
  let issued_at: String

  var killScope: KillScope { kill?.scope ?? .none }

  var issuedAtDate: Date? { ControlManifest.parseISO(issued_at) }

  /// `issued_at` as epoch milliseconds, or nil when unparseable. Used as the
  /// anti-rollback high-water comparison key (mirrors the MCP gates' `issuedAtMs`).
  var issuedAtMs: Int64? {
    guard let d = issuedAtDate else { return nil }
    return Int64((d.timeIntervalSince1970 * 1000).rounded())
  }

  static func parseISO(_ s: String) -> Date? {
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
  }
}

/// Ed25519 verification of the detached control.json signature. Pure + testable.
enum ControlManifestVerifier {
  /// Verify `signatureBase64` (the contents of control.json.sig, base64 of the raw
  /// 64-byte Ed25519 signature) over the EXACT raw bytes of control.json, using a
  /// base64-encoded 32-byte Ed25519 public key (the bundle's `SUPublicEDKey`).
  /// Returns false on any malformed input — fail closed.
  static func verify(manifestData: Data, signatureBase64: String, publicKeyBase64: String) -> Bool {
    let sigStr = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyStr = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sigStr.isEmpty, !keyStr.isEmpty,
          let sigData = Data(base64Encoded: sigStr),
          let keyData = Data(base64Encoded: keyStr),
          keyData.count == 32
    else { return false }
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
      return false
    }
    return key.isValidSignature(sigData, for: manifestData)
  }
}

/// Process-wide, thread-safe gate the send paths consult. `DraftSender.send`
/// (the single chokepoint for every iMessage + WhatsApp send) checks this before
/// doing anything, so a kill directive or a forced-upgrade floor blocks ALL sends
/// — scheduler, manual "send now", automation-materialized drafts, Don't-Ghost —
/// with one check. Updated by ControlManifestController on the main actor; read
/// from arbitrary contexts, hence the lock.
final class SendGate: @unchecked Sendable {
  static let shared = SendGate()

  private let lock = NSLock()
  private var _blocked = false
  private var _blockedPlatforms = Set<Platform>()
  private var _reason: String?

  /// All sending blocked (kill scope `all`/`send`, or a forced-upgrade floor).
  var isAllBlocked: Bool {
    lock.lock(); defer { lock.unlock() }
    return _blocked
  }

  func isBlocked(for platform: Platform) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return _blocked || _blockedPlatforms.contains(platform)
  }

  var reason: String? {
    lock.lock(); defer { lock.unlock() }
    return _reason
  }

  func update(allBlocked: Bool, blockedPlatforms: Set<Platform>, reason: String?) {
    lock.lock(); defer { lock.unlock() }
    _blocked = allBlocked
    _blockedPlatforms = blockedPlatforms
    _reason = reason
  }

  /// Test seam.
  func resetForTesting() {
    update(allBlocked: false, blockedPlatforms: [], reason: nil)
  }
}

/// Semantic-version comparison good enough for `min_supported_version` (dotted
/// numeric components, e.g. "0.6.0"). Non-numeric / missing components are treated
/// as 0 so "0.6" and "0.6.0" compare equal. Returns true when `lhs < rhs`.
enum VersionCompare {
  static func isLess(_ lhs: String, than rhs: String) -> Bool {
    order(lhs, rhs) == .orderedAscending
  }

  static func order(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let a = components(lhs)
    let b = components(rhs)
    let count = max(a.count, b.count)
    for i in 0..<count {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x < y { return .orderedAscending }
      if x > y { return .orderedDescending }
    }
    return .orderedSame
  }

  private static func components(_ v: String) -> [Int] {
    v.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
  }
}
