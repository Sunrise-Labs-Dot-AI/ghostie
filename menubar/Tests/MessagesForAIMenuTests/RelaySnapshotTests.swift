import XCTest
@testable import MessagesForAIMenu

/// SUN-613 phase 1 (read-only). The property under test is that projecting a `Draft` into a
/// `RelaySnapshot` cannot leak local execution detail or a third party's identity, no matter what
/// the source draft contains. Redaction is proven by asserting the EXACT encoded key set of each
/// projection type, not by spot-checking that a few fields are absent.
final class RelaySnapshotTests: XCTestCase {

  private var home: URL!

  override func setUp() {
    super.setUp()
    home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ghostie-relay-snapshot-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    setenv("MESSAGES_FOR_AI_HOME", home.path, 1)
  }

  override func tearDown() {
    unsetenv("MESSAGES_FOR_AI_HOME")
    try? FileManager.default.removeItem(at: home)
    home = nil
    super.tearDown()
  }

  // MARK: - Exact key-set allowlist (finding 1)

  func testSnapshotEncodesExactlyItsAllowlistedKeys() throws {
    let snapshot = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    XCTAssertEqual(
      try encodedKeySet(snapshot),
      ["schema_version", "snapshot_id", "origin_device_id", "platform",
       "recipient", "body", "context", "staged_at", "lifecycle", "has_attachments", "snapshot_digest"]
    )
  }

  func testRecipientEncodesExactlyItsAllowlistedKeys() throws {
    let recipient = RelayRecipient.project(from: fullyLoadedDraft())
    XCTAssertEqual(try encodedKeySet(recipient), ["kind", "label"])
  }

  func testContextMessageEncodesExactlyItsAllowlistedKeys() throws {
    let projected = RelayContextMessage.project(from: hostileContextMessage())
    XCTAssertEqual(try encodedKeySet(projected), ["from_me", "sender_display", "body", "sent_at"])
  }

  // MARK: - Nothing sensitive survives, whatever the draft carries (finding 1, 2)

  func testNoSensitiveValueAppearsAnywhereInTheEncodedSnapshot() throws {
    let snapshot = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    let json = try String(data: JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""

    // Local execution detail and third-party identity that must never cross the wire.
    for forbidden in [
      "/Users/jamesheath/Library",          // attachment file path
      "sha256-of-the-attachment",           // attachment hash
      "iMessage;+;chat999000",              // chat_guid
      "+15559990001",                        // a group participant handle
      "+15557778888",                        // a context sender's raw handle
      "p:ABC-STANZA-42",                     // a context message id / guid
      "reaction-author-handle",              // a reaction author identity
      "hmac-approval-tag-secret",            // schedule approval tag
      "device-executor-xyz"                  // relay_executor
    ] {
      XCTAssertFalse(json.contains(forbidden), "leaked '\(forbidden)' into the published snapshot")
    }
  }

  func testUnnamedGroupProjectsToACountNeverHandlesOrGuid() {
    let group = IMessageGroupDraftTarget(
      chat_guid: "iMessage;+;chat999000",
      participant_handles: ["+15559990001", "+15559990002", "+15559990003"],
      participant_names: []
    )
    let label = RelayRecipient.safeGroupLabel(group)
    XCTAssertEqual(label, "Group thread (3 people)")
    XCTAssertFalse(label.contains("+1555"))
    XCTAssertFalse(label.contains("chat999000"))
  }

  func testPartlyNamedGroupCountsTheUnnamedRestRatherThanExposingThem() {
    let group = IMessageGroupDraftTarget(
      chat_guid: "iMessage;+;chat1",
      participant_handles: ["+15559990001", "+15559990002", "+15559990003"],
      participant_names: ["Maya"]
    )
    let label = RelayRecipient.safeGroupLabel(group)
    XCTAssertEqual(label, "Group thread with Maya and 2 more")
    XCTAssertFalse(label.contains("+1555"))
  }

  func testContextSenderWithoutANameBecomesAPseudonymNotAHandle() {
    let projected = RelayContextMessage.project(from: ContextMessage(
      guid: "g", message_id: "m", from_me: false,
      sender_handle: "+15557778888", sender_name: nil, body: "hi", sent_at: "t",
      reaction: nil, reactions: []
    ))
    XCTAssertEqual(projected.sender_display, "them")
    XCTAssertFalse(projected.sender_display.contains("+1555"))
  }

  // MARK: - has_attachments without the paths (finding, criterion 4)

  func testHasAttachmentsIsTrueAndPathsAreAbsent() throws {
    let snapshot = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    XCTAssertTrue(snapshot.has_attachments)
    let json = try String(data: JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("/Users/"))
  }

  // MARK: - Purity (finding 8)

  func testProjectionCreatesNoFile() throws {
    // The device id is injected, so the projection must never call DeviceIdentity (which can create
    // device.json). Point HOME at an empty dir and confirm nothing is written.
    _ = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    let mcpDir = home.appendingPathComponent(".messages-mcp")
    XCTAssertFalse(FileManager.default.fileExists(atPath: mcpDir.path),
                   "the pure projection created state on disk")
  }

  func testProjectionIsDeterministic() {
    let draft = fullyLoadedDraft()
    let a = RelaySnapshot.project(from: draft, originDeviceID: "device-aaaaaaaa")
    let b = RelaySnapshot.project(from: draft, originDeviceID: "device-aaaaaaaa")
    XCTAssertEqual(a, b)
    XCTAssertFalse(a.snapshot_digest.isEmpty)
  }

  func testDigestChangesWhenDisplayedContentChanges() {
    let base = RelaySnapshot.project(from: draft(body: "one"), originDeviceID: "device-aaaaaaaa")
    let edited = RelaySnapshot.project(from: draft(body: "two"), originDeviceID: "device-aaaaaaaa")
    XCTAssertNotEqual(base.snapshot_digest, edited.snapshot_digest)
  }

  // MARK: - Untrusted text (finding 12)

  func testUntrustedTextIsDeclared() {
    XCTAssertTrue(RelaySnapshot.textIsUntrusted)
  }

  func testScriptAndBidiShapedTextSurvivesInertInEveryTextField() throws {
    let nasty = "<script>steal()</script>\u{202E}evil onload=x"
    let d = draft(body: nasty, contactName: nasty, contextBody: nasty, contextName: nasty)
    let snapshot = RelaySnapshot.project(from: d, originDeviceID: "device-aaaaaaaa")

    // The projection stores it verbatim as DATA. It performs no escaping and no execution; the
    // rendering contract (textContent + CSP, phase 3) is what makes it safe to display. The point
    // here is that the value is carried inert, not interpreted.
    XCTAssertEqual(snapshot.body, nasty)
    XCTAssertEqual(snapshot.recipient.label, nasty)
    XCTAssertEqual(snapshot.context.first?.body, nasty)
    XCTAssertEqual(snapshot.context.first?.sender_display, nasty)

    // And it round-trips through JSON without becoming markup.
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(RelaySnapshot.self, from: data)
    XCTAssertEqual(decoded.body, nasty)
  }

  // MARK: - Lifecycle

  func testLifecycleProjection() {
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x")), .pending)
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x", scheduledAt: "2026-08-01T09:00:00Z")), .scheduled)
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x", scheduledAt: "2026-08-01T09:00:00Z", holdReason: "quiet_hours")), .held)
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x", sentAt: "2026-07-01T00:00:00Z")), .sent)
  }

  // MARK: - Fixtures

  private func encodedKeySet<T: Encodable>(_ value: T) throws -> Set<String> {
    let data = try JSONEncoder().encode(value)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return Set(obj.keys)
  }

  private func hostileContextMessage() -> ContextMessage {
    ContextMessage(
      guid: "iMessage;-;guid-of-another-message",
      message_id: "p:ABC-STANZA-42",
      from_me: false,
      sender_handle: "+15557778888",
      sender_name: "Bystander",
      body: "context body from a third party",
      sent_at: "2026-06-01T00:00:00Z",
      reaction: MessageReaction(kind: .loved, from_me: false, sender_handle: "reaction-author-handle", sender_name: nil, sent_at: nil),
      reactions: [MessageReaction(kind: .loved, from_me: false, sender_handle: "reaction-author-handle", sender_name: nil, sent_at: nil)]
    )
  }

  /// A draft carrying every sensitive field the projection must strip.
  private func fullyLoadedDraft() -> Draft {
    Draft(
      id: "d-full",
      to_handle: "imessage-group:iMessage;+;chat999000",
      to_handle_name: nil,
      imessage_group: IMessageGroupDraftTarget(
        chat_guid: "iMessage;+;chat999000",
        participant_handles: ["+15559990001", "+15559990002"],
        participant_names: ["Maya", "Alex"]
      ),
      body: "the draft body",
      attachments: [DraftAttachment(
        path: "/Users/jamesheath/Library/attachment.jpg",
        filename: "attachment.jpg", mime_type: "image/jpeg", byte_count: 10,
        asset_id: "a1", sha256: "sha256-of-the-attachment"
      )],
      delivery_progress: DraftDeliveryProgress(completed_attachment_count: 0, body_sent: false, ambiguous_part: nil),
      in_reply_to_thread_id: 424242,
      staged_at: "2026-07-20T00:00:00Z",
      sent_at: nil, send_service: "iMessage", source: "test",
      context_messages: [hostileContextMessage()],
      context_diagnostic: nil,
      scheduled_send_at: nil, schedule_hold_reason: nil, override_send: nil,
      schedule_approved: nil, schedule_approval_tag: "hmac-approval-tag-secret",
      schema_version: nil, platform: nil, approval_state: nil,
      induced_by_unknown_contact: nil, quoted_message_id: nil, quoted_preview: nil,
      relay_executor: "device-executor-xyz"
    )
  }

  private func draft(
    body: String,
    contactName: String? = "Recipient Name",
    contextBody: String? = nil,
    contextName: String? = nil,
    scheduledAt: String? = nil,
    holdReason: String? = nil,
    sentAt: String? = nil
  ) -> Draft {
    let context: [ContextMessage]? = contextBody.map { cb in
      [ContextMessage(guid: nil, message_id: nil, from_me: false,
                      sender_handle: "+15550000000", sender_name: contextName,
                      body: cb, sent_at: "t", reaction: nil, reactions: [])]
    }
    return Draft(
      id: "d-1", to_handle: "+14155551234", to_handle_name: contactName,
      imessage_group: nil, body: body, attachments: nil, delivery_progress: nil,
      in_reply_to_thread_id: nil, staged_at: "2026-07-20T00:00:00Z",
      sent_at: sentAt, send_service: nil, source: nil, context_messages: context,
      context_diagnostic: nil, scheduled_send_at: scheduledAt, schedule_hold_reason: holdReason,
      override_send: nil, schedule_approved: nil, schedule_approval_tag: nil, schema_version: nil,
      platform: nil, approval_state: nil, induced_by_unknown_contact: nil,
      quoted_message_id: nil, quoted_preview: nil, relay_executor: nil
    )
  }
}
