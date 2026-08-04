import Foundation

/// The one place the product's web host is written down.
///
/// Before this existed the host was hardcoded in ten separate places — the
/// Sparkle feed pin, the control-manifest URLs, the account/premium base, the
/// legal links, and four in-app menu items. Moving from `messagesfor.ai` to
/// `ghostie.app` meant grepping the whole repo and hoping, which is exactly the
/// kind of migration that leaves one stale endpoint pointing at a domain nobody
/// renews. Route new host-derived URLs through here.
///
/// NOT covered by this type, because they are shell and can't import Swift:
/// the `SUFeedURL` string stamped into Info.plist by `scripts/build-release.sh`
/// and `menubar/scripts/dev-install.sh`. Those must be kept in step with
/// `appcast` below — `SiteURLTests` pins the expectation so a mismatch surfaces
/// as a failing test rather than a silent update channel split. In practice the
/// runtime pin wins anyway (see `UpdaterController`'s `FeedURLPin`, which
/// overrides both Info.plist and any local `defaults write`).
enum SiteURLs {

  /// Canonical host as of v0.13.0.
  ///
  /// `messagesfor.ai` remains a live alias of the same Vercel project and MUST
  /// keep serving `appcast.xml`, `control.json` and `control.json.sig`: v0.12.0
  /// installs have the old host baked in and poll it for updates and for the
  /// kill switch. Retiring that domain strands them. See CLAUDE.md → rebrand
  /// invariants for why the feed URL stopped being an invariant.
  static let host = "ghostie.app"

  static let base = URL(string: "https://\(host)")!

  /// Sparkle appcast. Must match the `SUFeedURL` stamped by the build scripts.
  static let appcast = "https://\(host)/appcast.xml"

  /// Signed remote kill-switch / minimum-version manifest, and its detached
  /// signature. Both are verified against the Sparkle EdDSA public key.
  static let controlManifest = URL(string: "https://\(host)/control.json")!
  static let controlSignature = URL(string: "https://\(host)/control.json.sig")!

  /// A static page on the marketing site, e.g. `page("terms.html")`.
  static func page(_ name: String) -> URL {
    base.appendingPathComponent(name)
  }
}
