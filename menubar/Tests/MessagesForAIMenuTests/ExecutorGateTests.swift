import XCTest
@testable import MessagesForAIMenu

/// SUN-613 phase 0. The property under test is narrow and load-bearing: a draft
/// stamped for one Mac must not be sendable from another, and "I can't tell"
/// must resolve to "don't send" rather than "send anyway".
final class ExecutorGateTests: XCTestCase {

  private var home: URL!

  override func setUp() {
    super.setUp()
    home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ghostie-executor-gate-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    setenv("MESSAGES_FOR_AI_HOME", home.path, 1)
    DeviceIdentity.resetCacheForTesting()
  }

  override func tearDown() {
    unsetenv("MESSAGES_FOR_AI_HOME")
    DeviceIdentity.resetCacheForTesting()
    try? FileManager.default.removeItem(at: home)
    home = nil
    super.tearDown()
  }

  // MARK: - The rule

  func testUnstampedDraftIsAllowed() {
    // Every draft that exists today. No stamp means no routing restriction, so
    // phase 0 is a no-op for anyone not using the relay.
    let draft = makeDraft(relayExecutor: nil)
    XCTAssertNil(draft.executorRefusal(localDeviceID: "device-aaaaaaaa"))
  }

  func testEmptyStampIsTreatedAsUnstamped() {
    // A whitespace-only value is a malformed writer, not an assignment to the
    // empty device. Treat it as absent rather than refusing every send.
    XCTAssertNil(makeDraft(relayExecutor: "").executorRefusal(localDeviceID: "device-aaaaaaaa"))
    XCTAssertNil(makeDraft(relayExecutor: "   ").executorRefusal(localDeviceID: "device-aaaaaaaa"))
  }

  func testMatchingStampIsAllowed() {
    let draft = makeDraft(relayExecutor: "device-aaaaaaaa")
    XCTAssertNil(draft.executorRefusal(localDeviceID: "device-aaaaaaaa"))
  }

  func testForeignStampIsRefused() {
    let draft = makeDraft(relayExecutor: "device-bbbbbbbb")
    XCTAssertNotNil(draft.executorRefusal(localDeviceID: "device-aaaaaaaa"))
  }

  func testUnreadableLocalIDFailsClosed() {
    // The whole point: not being able to prove ownership must never resolve to
    // "send it anyway".
    let draft = makeDraft(relayExecutor: "device-bbbbbbbb")
    XCTAssertNotNil(draft.executorRefusal(localDeviceID: nil))
  }

  func testMalformedLocalIDFailsClosed() {
    // A corrupt device.json must not accidentally match a corrupt stamp.
    let draft = makeDraft(relayExecutor: "../../etc/passwd")
    XCTAssertNotNil(draft.executorRefusal(localDeviceID: "../../etc/passwd"))
  }

  // MARK: - Device identity

  func testDeviceIDIsCreatedAndStable() {
    guard let first = DeviceIdentity.localDeviceID() else {
      return XCTFail("expected a device id to be created")
    }
    XCTAssertTrue(DeviceIdentity.isValidDeviceID(first))

    // A second process (cache cleared) must read the SAME id off disk, or the
    // two Macs' gates would disagree about who owns a draft after a relaunch.
    DeviceIdentity.resetCacheForTesting()
    XCTAssertEqual(DeviceIdentity.localDeviceID(), first)

    let path = home.appendingPathComponent(".messages-mcp/device.json").path
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber
    XCTAssertEqual(mode?.int16Value, 0o600, "device.json must not be world-readable")
  }

  func testCorruptDeviceFileDoesNotYieldAnID() {
    let dir = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data("{ not json".utf8).write(to: dir.appendingPathComponent("device.json"))
    DeviceIdentity.resetCacheForTesting()
    // Creation is refused because the file already exists (O_EXCL), and the
    // existing bytes don't parse — so there is no id, and every stamped draft
    // fails closed rather than being attributed to this machine.
    XCTAssertNil(DeviceIdentity.localDeviceID())
  }

  func testIDValidationRejectsPathsAndPunctuation() {
    XCTAssertTrue(DeviceIdentity.isValidDeviceID("A1B2C3D4-0000-1111-2222-333344445555"))
    XCTAssertFalse(DeviceIdentity.isValidDeviceID("short"))
    XCTAssertFalse(DeviceIdentity.isValidDeviceID("../../etc/passwd"))
    XCTAssertFalse(DeviceIdentity.isValidDeviceID("device id with spaces"))
    XCTAssertFalse(DeviceIdentity.isValidDeviceID(String(repeating: "a", count: 65)))
  }

  // MARK: - The stamp survives a rewrite

  func testStampIsNotPartOfTheDeliveryDigest() {
    // relay_executor is routing, not delivery semantics. Binding it into the
    // digest would invalidate every already-minted schedule-approval tag on
    // upgrade for no gain, so this asymmetry is deliberate and pinned here.
    let unstamped = makeDraft(relayExecutor: nil)
    let stamped = makeDraft(relayExecutor: "device-aaaaaaaa")
    XCTAssertEqual(unstamped.deliveryPayloadDigest, stamped.deliveryPayloadDigest)
  }

  func testApprovalTagRoundTripPreservesTheStamp() {
    // replacingScheduleApprovalTag rebuilds the whole struct. If it dropped the
    // stamp, approving a scheduled draft would silently un-route it and hand a
    // second Mac permission to send.
    let stamped = makeDraft(relayExecutor: "device-aaaaaaaa")
    XCTAssertEqual(stamped.replacingScheduleApprovalTag("tag").relay_executor, "device-aaaaaaaa")
  }

  func testJSONRoundTripPreservesTheStamp() throws {
    let stamped = makeDraft(relayExecutor: "device-aaaaaaaa")
    let data = try JSONEncoder().encode(stamped)
    let decoded = try JSONDecoder().decode(Draft.self, from: data)
    XCTAssertEqual(decoded.relay_executor, "device-aaaaaaaa")
  }

  func testLegacyDraftJSONWithoutTheFieldStillDecodes() throws {
    // Back-compat: drafts written before this field exists must keep working.
    let legacy = """
    {"id":"abc","to_handle":"+14155551234","body":"hi","staged_at":"2026-05-15T00:00:00Z",
     "sent_at":null,"send_service":null,"source":null,"in_reply_to_thread_id":null}
    """
    let decoded = try JSONDecoder().decode(Draft.self, from: Data(legacy.utf8))
    XCTAssertNil(decoded.relay_executor)
    XCTAssertNil(decoded.executorRefusal(localDeviceID: "device-aaaaaaaa"))
  }

  // MARK: - Fixture

  private func makeDraft(relayExecutor: String?) -> Draft {
    Draft(
      id: "d-1",
      to_handle: "+14155551234",
      to_handle_name: nil,
      body: "hi",
      in_reply_to_thread_id: nil,
      staged_at: "2026-05-15T00:00:00Z",
      sent_at: nil,
      send_service: nil,
      source: nil,
      context_messages: nil,
      context_diagnostic: nil,
      scheduled_send_at: nil,
      schedule_hold_reason: nil,
      override_send: nil,
      schedule_approved: nil,
      schedule_approval_tag: nil,
      schema_version: nil,
      platform: nil,
      approval_state: nil,
      induced_by_unknown_contact: nil,
      quoted_message_id: nil,
      quoted_preview: nil,
      relay_executor: relayExecutor
    )
  }
}
