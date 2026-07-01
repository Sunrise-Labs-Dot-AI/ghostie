import Foundation
import XCTest
@testable import MessagesForAIMenu

/// FeatureFlagStore contract: override > remote > builtin default, /decide v3
/// parsing, the disk cache that makes launches instant, the no-network privacy
/// gate, and the LockedLabCopy policy the gated surfaces render from.
final class FeatureFlagTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("feature-flag-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private var fileURL: URL {
    tempDir.appendingPathComponent("feature-flags.json")
  }

  private var configuredConfig: AnalyticsClientConfig {
    AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://example.com")!)
  }

  // MARK: - Resolution precedence

  func testBuiltinDefaultsMatchShipPolicy() {
    // Flags graduated to shipped-on (validated live; the flag stays as a kill-switch).
    // Everything ELSE must still default off, so a newly-added flag ships hidden until
    // it's deliberately graduated here.
    let shippedOn: Set<MFAFeatureFlag> = [.draftSafetyStates, .transcriptSnapFix]
    for flag in MFAFeatureFlag.allCases {
      if shippedOn.contains(flag) {
        XCTAssertTrue(flag.builtinDefault, "\(flag.rawValue) is shipped on")
      } else {
        XCTAssertFalse(flag.builtinDefault, "\(flag.rawValue) must default off")
      }
    }
  }

  func testOverrideBeatsRemoteBeatsDefault() {
    let flag = MFAFeatureFlag.wrappedDeepRead

    XCTAssertFalse(FeatureFlagResolution.resolved(flag, overrides: [:], remote: [:]))
    XCTAssertEqual(FeatureFlagResolution.source(flag, overrides: [:], remote: [:]), .default)

    XCTAssertTrue(FeatureFlagResolution.resolved(flag, overrides: [:], remote: [flag.rawValue: true]))
    XCTAssertEqual(FeatureFlagResolution.source(flag, overrides: [:], remote: [flag.rawValue: true]), .remote)

    // A false override must beat a true remote — the override wins on
    // presence, not value.
    XCTAssertFalse(FeatureFlagResolution.resolved(
      flag, overrides: [flag.rawValue: false], remote: [flag.rawValue: true]
    ))
    XCTAssertEqual(
      FeatureFlagResolution.source(flag, overrides: [flag.rawValue: false], remote: [flag.rawValue: true]),
      .override
    )
  }

  func testRemoteForOneFlagDoesNotLeakToAnother() {
    let remote = [MFAFeatureFlag.wrappedDeepRead.rawValue: true]
    XCTAssertFalse(FeatureFlagResolution.resolved(.premiumMessaging, overrides: [:], remote: remote))
    XCTAssertEqual(FeatureFlagResolution.source(.premiumMessaging, overrides: [:], remote: remote), .default)
  }

  // MARK: - /decide v3 parsing

  func testParseDecideBooleansVariantsAndUnknownTypes() throws {
    let json = """
      {
        "featureFlags": {
          "wrapped-deep-read": true,
          "premium-messaging": false,
          "imessage-ax-tapbacks": true,
          "some-multivariate": "test-group",
          "garbage-shape": [1, 2]
        },
        "featureFlagPayloads": {}
      }
      """
    let parsed = try XCTUnwrap(FeatureFlagStore.parseDecideResponse(Data(json.utf8)))
    XCTAssertEqual(parsed["wrapped-deep-read"], true)
    XCTAssertEqual(parsed["premium-messaging"], false)
    XCTAssertEqual(parsed["imessage-ax-tapbacks"], true)
    // A variant string means the flag is on.
    XCTAssertEqual(parsed["some-multivariate"], true)
    XCTAssertNil(parsed["garbage-shape"])
    // Flags missing from the response stay missing (resolution falls through).
    XCTAssertNil(parsed["never-mentioned"])
  }

  func testParseDecideMalformedPayloadsReturnNil() {
    XCTAssertNil(FeatureFlagStore.parseDecideResponse(Data("not json".utf8)))
    XCTAssertNil(FeatureFlagStore.parseDecideResponse(Data("{\"status\": \"ok\"}".utf8)))
    XCTAssertNil(FeatureFlagStore.parseDecideResponse(Data("{\"featureFlags\": [1, 2]}".utf8)))
    XCTAssertNil(FeatureFlagStore.parseDecideResponse(Data()))
  }

  // MARK: - Refresh + cache

  @MainActor
  func testRefreshFetchesParsesAndCachesToDisk() async throws {
    let store = FeatureFlagStore(
      fileURL: fileURL,
      config: configuredConfig,
      analyticsEnabled: { true },
      transport: { request in
        // Pins the decide wire contract: POST {host}/decide/?v=3 with
        // api_key + distinct_id only — no event payload, no person data.
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/decide/?v=3")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["api_key"] as? String, "phc_test")
        XCTAssertFalse((json["distinct_id"] as? String ?? "").isEmpty)
        XCTAssertEqual(json.count, 2)
        return Data("""
          {"featureFlags": {"wrapped-deep-read": true, "premium-messaging": false}}
          """.utf8)
      }
    )

    await store.refresh()

    XCTAssertTrue(store.resolved(.wrappedDeepRead))
    XCTAssertEqual(store.source(.wrappedDeepRead), .remote)
    XCTAssertFalse(store.resolved(.premiumMessaging))
    if case .fetched = store.fetchState {} else {
      XCTFail("expected .fetched, got \(store.fetchState)")
    }

    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
  }

  @MainActor
  func testCacheRoundTripRestoresRemoteAndOverridesWithoutNetwork() async throws {
    let first = FeatureFlagStore(
      fileURL: fileURL,
      config: configuredConfig,
      analyticsEnabled: { true },
      transport: { _ in
        Data("""
          {"featureFlags": {"wrapped-deep-read": true}}
          """.utf8)
      }
    )
    await first.refresh()
    first.setOverride(.premiumMessaging, to: true)

    // Fresh process, analytics now off: cached remote + persisted override
    // must resolve instantly and the transport must never run.
    let reloaded = FeatureFlagStore(
      fileURL: fileURL,
      config: configuredConfig,
      analyticsEnabled: { false },
      transport: { _ in
        XCTFail("no network with analytics off")
        throw URLError(.notConnectedToInternet)
      }
    )
    XCTAssertTrue(reloaded.resolved(.wrappedDeepRead))
    XCTAssertEqual(reloaded.source(.wrappedDeepRead), .remote)
    XCTAssertTrue(reloaded.resolved(.premiumMessaging))
    XCTAssertEqual(reloaded.source(.premiumMessaging), .override)
    XCTAssertNotNil(reloaded.lastFetchedAt)

    await reloaded.refresh()
    XCTAssertEqual(reloaded.fetchState, .skippedAnalyticsOff)

    // Clearing the override falls back to remote, then default.
    reloaded.setOverride(.premiumMessaging, to: nil)
    XCTAssertFalse(reloaded.resolved(.premiumMessaging))
    XCTAssertEqual(reloaded.source(.premiumMessaging), .default)
  }

  @MainActor
  func testRefreshSkipsSilentlyWithoutAToken() async {
    // Dev builds carry an empty token; remote must be a silent no-op.
    let store = FeatureFlagStore(
      fileURL: fileURL,
      config: AnalyticsClientConfig(projectToken: "", host: URL(string: "https://example.com")!),
      analyticsEnabled: { true },
      transport: { _ in
        XCTFail("no network without a token")
        throw URLError(.cancelled)
      }
    )
    await store.refresh()
    XCTAssertEqual(store.fetchState, .skippedNoToken)
  }

  @MainActor
  func testMalformedRemotePayloadKeepsLastKnownValues() async {
    let good = FeatureFlagStore(
      fileURL: fileURL,
      config: configuredConfig,
      analyticsEnabled: { true },
      transport: { _ in
        Data("""
          {"featureFlags": {"wrapped-deep-read": true}}
          """.utf8)
      }
    )
    await good.refresh()

    let degraded = FeatureFlagStore(
      fileURL: fileURL,
      config: configuredConfig,
      analyticsEnabled: { true },
      transport: { _ in Data("oops".utf8) }
    )
    await degraded.refresh()
    XCTAssertEqual(degraded.fetchState, .failed("unexpected response shape"))
    XCTAssertTrue(degraded.resolved(.wrappedDeepRead), "cache must survive a bad fetch")
  }

  func testInstallationIDSharedStorageIsStable() {
    let a = AnalyticsClient.installationID(rootDirectory: tempDir)
    let b = AnalyticsClient.installationID(rootDirectory: tempDir)
    XCTAssertFalse(a.isEmpty)
    XCTAssertEqual(a, b, "distinct_id must not churn between reads")
  }

  // MARK: - LockedLabCopy policy

  func testLockedCopyIsPureBYOKWhenPremiumMessagingOff() {
    // Flag off wins even with subscriptions live — no premium pitch at all.
    for live in [true, false] {
      let copy = LockedLabCopy.select(
        lead: "EQ uses AI on your messages",
        premiumMessagingEnabled: false,
        subscriptionsLive: live
      )
      XCTAssertEqual(copy.badge, "Bring your own key")
      XCTAssertEqual(copy.badgeSystemImage, "key")
      XCTAssertFalse(copy.showsSubscribe)
      XCTAssertEqual(
        copy.body,
        "EQ uses AI on your messages. Add your own Claude or ChatGPT API key in Settings and everything unlocks — free."
      )
      XCTAssertFalse(copy.body.lowercased().contains("premium"))
      XCTAssertFalse(copy.body.lowercased().contains("subscri"))
    }
  }

  func testLockedCopyPitchesSubscribeWhenFlagOnAndLive() {
    let copy = LockedLabCopy.select(
      lead: "EQ uses AI on your messages",
      premiumMessagingEnabled: true,
      subscriptionsLive: true
    )
    XCTAssertEqual(copy.badge, "Premium feature")
    XCTAssertTrue(copy.showsSubscribe)
    XCTAssertTrue(copy.body.contains("Subscribe to unlock it"))
  }

  func testLockedCopySaysComingSoonWhenFlagOnButNotLive() {
    let copy = LockedLabCopy.select(
      lead: "Deep Read uses AI on your aggregate stats",
      premiumMessagingEnabled: true,
      subscriptionsLive: false
    )
    XCTAssertEqual(copy.badge, "Premium — coming soon")
    XCTAssertFalse(copy.showsSubscribe)
    XCTAssertTrue(copy.body.contains("Premium subscriptions are coming soon"))
    XCTAssertTrue(copy.body.hasPrefix("Deep Read uses AI on your aggregate stats."))
  }
}
