import Foundation
import XCTest
@testable import MessagesForAIMenu

/// PremiumGate + the Entitlement wire contract with site/api/premium.js.
/// The decode test pins the exact payload `handleEntitlement` emits — if
/// either side renames a key, this is the test that catches it.
final class PremiumEntitlementTests: XCTestCase {
  func testPremiumGateUnlocksOnSubscriptionOrBYOK() {
    XCTAssertFalse(PremiumGate.unlocked(subscriptionActive: false, hasAPIKey: false))
    XCTAssertTrue(PremiumGate.unlocked(subscriptionActive: true, hasAPIKey: false))
    XCTAssertTrue(PremiumGate.unlocked(subscriptionActive: false, hasAPIKey: true))
    XCTAssertTrue(PremiumGate.unlocked(subscriptionActive: true, hasAPIKey: true))
  }

  func testEntitlementDecodesTheSiteWirePayload() throws {
    // Exactly what site/api/premium.js handleEntitlement returns for an
    // active subscriber (token is intentionally never echoed back).
    let subscriber = """
      {
        "schema_version": 1,
        "subscription_active": true,
        "plan": "premium",
        "account_email": "sam@example.com",
        "expires_at": "2026-07-14T00:00:00Z",
        "token": null
      }
      """
    let decoded = try JSONDecoder().decode(Entitlement.self, from: Data(subscriber.utf8))
    XCTAssertEqual(decoded.schemaVersion, 1)
    XCTAssertTrue(decoded.subscriptionActive)
    XCTAssertEqual(decoded.plan, "premium")
    XCTAssertEqual(decoded.accountEmail, "sam@example.com")
    XCTAssertNil(decoded.token)

    // Non-subscriber: plan is JSON null, the grace-horizon expiry persists.
    let free = """
      {
        "schema_version": 1,
        "subscription_active": false,
        "plan": null,
        "account_email": null,
        "expires_at": "2026-06-13T00:00:00Z",
        "token": null
      }
      """
    let freeDecoded = try JSONDecoder().decode(Entitlement.self, from: Data(free.utf8))
    XCTAssertFalse(freeDecoded.subscriptionActive)
    XCTAssertNil(freeDecoded.plan)
    XCTAssertFalse(freeDecoded.isCurrentlyActive())
  }

  func testIsCurrentlyActiveExpiryBoundaries() {
    func entitlement(active: Bool, expiresAt: String?) -> Entitlement {
      Entitlement(
        schemaVersion: 1,
        subscriptionActive: active,
        plan: active ? "premium" : nil,
        accountEmail: nil,
        expiresAt: expiresAt,
        token: nil
      )
    }
    let now = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!

    // Active + future expiry unlocks; the expiry instant itself does not
    // (the horizon is "re-verify by", not "valid through").
    XCTAssertTrue(entitlement(active: true, expiresAt: "2026-06-13T00:00:00Z").isCurrentlyActive(now: now))
    XCTAssertFalse(entitlement(active: true, expiresAt: "2026-06-10T12:00:00Z").isCurrentlyActive(now: now))
    // Lapsed grace horizon stops unlocking even with the flag still true —
    // this is the offline-revocation guarantee.
    XCTAssertFalse(entitlement(active: true, expiresAt: "2026-06-01T00:00:00Z").isCurrentlyActive(now: now))
    // A corrupt expiry can't be compared — fail closed.
    XCTAssertFalse(entitlement(active: true, expiresAt: "not-a-date").isCurrentlyActive(now: now))
    // No expiry at all means nothing to re-verify against — trust the flag.
    XCTAssertTrue(entitlement(active: true, expiresAt: nil).isCurrentlyActive(now: now))
    // The flag gates everything.
    XCTAssertFalse(entitlement(active: false, expiresAt: "2099-01-01T00:00:00Z").isCurrentlyActive(now: now))
  }
}
