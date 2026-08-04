import XCTest
@testable import MessagesForAIMenu

/// Guards the v0.13.0 move from `messagesfor.ai` to `ghostie.app`.
///
/// The host used to be hardcoded in ten places across Swift, shell and HTML.
/// Two of those — the Sparkle feed and the control manifest — are how the app
/// receives updates and how a bad build gets remotely disabled. A single missed
/// or reverted string there is invisible in normal use and only shows up when
/// you need it most, so pin them.
final class SiteURLTests: XCTestCase {

  func testCanonicalHostIsGhostie() {
    XCTAssertEqual(SiteURLs.host, "ghostie.app")
    XCTAssertEqual(SiteURLs.base.absoluteString, "https://ghostie.app")
  }

  func testUpdateAndKillSwitchEndpoints() {
    XCTAssertEqual(SiteURLs.appcast, "https://ghostie.app/appcast.xml")
    XCTAssertEqual(SiteURLs.controlManifest.absoluteString, "https://ghostie.app/control.json")
    XCTAssertEqual(SiteURLs.controlSignature.absoluteString, "https://ghostie.app/control.json.sig")
  }

  func testPageBuildsMarketingURLs() {
    XCTAssertEqual(SiteURLs.page("terms.html").absoluteString, "https://ghostie.app/terms.html")
    XCTAssertEqual(SiteURLs.page("account.html").absoluteString, "https://ghostie.app/account.html")
  }

  /// Everything host-derived must actually route through `SiteURLs`, or the
  /// next migration is another repo-wide grep.
  func testLegalLinksUseTheCanonicalHost() {
    XCTAssertEqual(Legal.termsURL.host, SiteURLs.host)
    XCTAssertEqual(Legal.privacyURL.host, SiteURLs.host)
  }

  func testEverythingIsHTTPS() {
    for url in [SiteURLs.base, SiteURLs.controlManifest, SiteURLs.controlSignature,
                Legal.termsURL, Legal.privacyURL, SiteURLs.page("x.html")] {
      XCTAssertEqual(url.scheme, "https", "\(url) must be https — these carry signed update metadata")
    }
    XCTAssertTrue(SiteURLs.appcast.hasPrefix("https://"))
  }

  /// The build scripts stamp `SUFeedURL` into Info.plist as a literal string,
  /// because shell can't import Swift. If that literal and `SiteURLs.appcast`
  /// drift, builds ship pointing at one feed while the runtime pin uses another
  /// — a split update channel that no unit test would otherwise notice.
  func testBuildScriptsStampTheSameFeedURL() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // MessagesForAIMenuTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // menubar
      .deletingLastPathComponent()  // repo root

    for script in ["scripts/build-release.sh", "menubar/scripts/dev-install.sh"] {
      let url = repoRoot.appendingPathComponent(script)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw XCTSkip("\(script) not readable from the test environment")
      }
      XCTAssertTrue(
        text.contains(SiteURLs.appcast),
        "\(script) must stamp SUFeedURL as \(SiteURLs.appcast)"
      )
      XCTAssertFalse(
        text.contains("messagesfor.ai/appcast.xml"),
        "\(script) still stamps the retired appcast host"
      )
    }
  }
}
