import Foundation

/// The one rule for premium access: a subscription unlocks the AI features,
/// and bringing your own API key unlocks everything for free. Central and
/// pure so every gate in the app agrees.
enum PremiumGate {
  static func unlocked(subscriptionActive: Bool, hasAPIKey: Bool) -> Bool {
    subscriptionActive || hasAPIKey
  }
}

/// Launch switches for the paid tier. Until the Clerk/Stripe backend is live
/// (env vars + Stripe price exist), subscriptions
/// can't be purchased, so locked labs and Settings must not pitch Subscribe/
/// Sign in; they say "coming soon" and point at BYOK instead. Flip to true
/// when accounts go live — every coming-soon surface keys off this one value.
enum PremiumFlags {
  static let subscriptionsLive = false
}

/// Copy policy for a locked AI surface (ConsoleView's DisabledLabView and the
/// Deep Read locked strip, which mirrors it). Pure so the three-way branch —
/// premium-messaging flag off (pure BYOK pitch), flag on + subscriptions live
/// (Subscribe), flag on + not live (coming soon) — is pinned by tests.
struct LockedLabCopy: Equatable {
  let badge: String
  let badgeSystemImage: String
  let body: String
  let showsSubscribe: Bool

  /// `lead` is the surface-specific first sentence without trailing
  /// punctuation, e.g. "EQ uses AI on your messages".
  static func select(
    lead: String,
    premiumMessagingEnabled: Bool,
    subscriptionsLive: Bool
  ) -> LockedLabCopy {
    guard premiumMessagingEnabled else {
      return LockedLabCopy(
        badge: "Bring your own key",
        badgeSystemImage: "key",
        body: "\(lead). Add your own Claude or ChatGPT API key in Settings and everything unlocks — free.",
        showsSubscribe: false
      )
    }
    if subscriptionsLive {
      return LockedLabCopy(
        badge: "Premium feature",
        badgeSystemImage: "sparkles",
        body: "\(lead). Subscribe to unlock it, or bring your own Claude or ChatGPT API key and use everything free.",
        showsSubscribe: true
      )
    }
    return LockedLabCopy(
      badge: "Premium — coming soon",
      badgeSystemImage: "sparkles",
      body: "\(lead). Premium subscriptions are coming soon — for now, add your own Claude or ChatGPT API key and everything unlocks free.",
      showsSubscribe: false
    )
  }
}

/// Locally cached account entitlement, written by the sign-in flow after the
/// site (Clerk + Stripe) confirms an active subscription. Shape is shared
/// with site/api/entitlement:
///
///     { "schema_version": 1, "subscription_active": true, "plan": "premium",
///       "account_email": "…", "expires_at": "ISO-8601", "token": "…" }
///
/// `expires_at` is a short re-verification horizon (the subscription period
/// end plus grace), so a revoked card stops unlocking within days even
/// offline. Absent/corrupt file = not subscribed; BYOK still unlocks.
struct Entitlement: Codable, Equatable {
  let schemaVersion: Int
  let subscriptionActive: Bool
  let plan: String?
  let accountEmail: String?
  let expiresAt: String?
  let token: String?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case subscriptionActive = "subscription_active"
    case plan
    case accountEmail = "account_email"
    case expiresAt = "expires_at"
    case token
  }

  func isCurrentlyActive(now: Date = Date()) -> Bool {
    guard subscriptionActive else { return false }
    guard let expiresAt else { return true }
    guard let expiry = ISO8601DateFormatter().date(from: expiresAt) else { return false }
    return expiry > now
  }
}

@MainActor
final class EntitlementStore: ObservableObject {
  @Published private(set) var entitlement: Entitlement?

  private var source: DispatchSourceFileSystemObject?

  private var file: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("entitlement.json")
  }

  var subscriptionActive: Bool {
    entitlement?.isCurrentlyActive() ?? false
  }

  var accountEmail: String? {
    subscriptionActive ? entitlement?.accountEmail : nil
  }

  init(startWatching: Bool = true) {
    reload()
    if startWatching {
      watchDirectory()
    }
  }

  deinit {
    source?.cancel()
  }

  func reload() {
    guard let data = try? Data(contentsOf: file),
          let decoded = try? JSONDecoder().decode(Entitlement.self, from: data),
          decoded.schemaVersion == 1 else {
      entitlement = nil
      return
    }
    entitlement = decoded
  }

  /// Store a fresh entitlement (called by the sign-in callback flow).
  func store(_ entitlement: Entitlement) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(entitlement) else { return }
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: file, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    self.entitlement = entitlement
  }

  /// Sign-in callback: the site hands us a short-lived Clerk session token
  /// via messagesforai://auth?token=…; we fetch the entitlement over HTTPS
  /// ourselves so nothing trusted rides in the URL.
  func activate(withSessionToken token: String) async {
    guard let url = PremiumEndpoints.api(
      "api/premium",
      query: [URLQueryItem(name: "action", value: "entitlement")]
    ) else { return }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
      guard let decoded = try? JSONDecoder().decode(Entitlement.self, from: data),
            decoded.schemaVersion == 1 else { return }
      // Keep the token we authenticated with so the free-trial proxy can
      // reuse it (the server intentionally never echoes tokens back).
      let withToken = Entitlement(
        schemaVersion: decoded.schemaVersion,
        subscriptionActive: decoded.subscriptionActive,
        plan: decoded.plan,
        accountEmail: decoded.accountEmail,
        expiresAt: decoded.expiresAt,
        token: token
      )
      store(withToken)
    } catch {
      // Network failure leaves the previous entitlement (if any) in place.
    }
  }

  func signOut() {
    try? FileManager.default.removeItem(at: file)
    entitlement = nil
  }

  private func watchDirectory() {
    let dir = file.deletingLastPathComponent()
    let handle = open(dir.path, O_EVTONLY)
    guard handle >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: handle,
      eventMask: [.write, .rename, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      self?.reload()
    }
    source.setCancelHandler {
      close(handle)
    }
    source.resume()
    self.source = source
  }
}
