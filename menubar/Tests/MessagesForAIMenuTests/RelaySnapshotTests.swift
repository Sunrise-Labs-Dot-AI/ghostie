import XCTest
@testable import MessagesForAIMenu

/// SUN-613 phase 1 (read-only). Two-tier contract under test:
///  - structural exclusion: local execution detail and stable third-party identifiers can never
///    appear, because the projection has no field to carry them (asserted by exact encoded key set
///    AND by a recursive walk of every string in the JSON);
///  - content passthrough: message text is carried verbatim by design (asserted, so the honest
///    scope is pinned rather than silently assumed).
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

  // MARK: - Exact key-set allowlist, fully-populated so it is the strict maximum (finding 1, 3)

  func testSnapshotEncodesExactlyItsAllowlistedKeys() throws {
    let snapshot = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    XCTAssertEqual(
      try encodedKeySet(snapshot),
      ["schema_version", "snapshot_id", "origin_device_id", "platform", "recipient",
       "body", "context", "staged_at", "lifecycle", "has_attachments", "quoted", "snapshot_digest"]
    )
  }

  func testContextMessageKeySetIsStableWhetherOrNotSentAtIsPresent() throws {
    // Synthesized encoding omits a nil optional, so the "exact set" must be checked with the
    // timestamp both present (upper bound) and absent (that a nil does not smuggle a new key).
    let withTs = RelayContextMessage.project(from: contextMessage(sentAt: "2026-06-01T00:00:00Z"))
    XCTAssertEqual(try encodedKeySet(withTs), ["from_me", "sender_display", "body", "sent_at"])
    let withoutTs = RelayContextMessage.project(from: contextMessage(sentAt: nil))
    XCTAssertEqual(try encodedKeySet(withoutTs), ["from_me", "sender_display", "body"])
  }

  func testQuotedPreviewKeySet() throws {
    let quoted = RelayQuotedPreview.project(from: draft(body: "x", quotedBody: "the quote", quotedFromMe: false))
    XCTAssertEqual(try encodedKeySet(quoted!), ["from_me", "body"])
  }

  // MARK: - Structural exclusion, proven by a recursive string walk (finding 2, 5)

  func testNoStructuralIdentifierAppearsInAnyStringOfTheEncodedSnapshot() throws {
    let snapshot = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    let strings = try allStrings(in: snapshot)

    // Structural / third-party identifiers that must NEVER appear as (or inside) any value. This
    // walks decoded scalars, so it is immune to JSON escaping (finding 5).
    let forbiddenSubstrings = [
      "/Users/jamesheath/Library",   // attachment path
      "sha256-of-the-attachment",    // attachment hash
      "chat999000",                  // chat_guid fragment
      "+15559990001",                // group participant handle
      "+15557778888",                // context sender raw handle
      "ABC-STANZA-42",               // context message id
      "guid-of-another-message",     // context guid
      "reaction-author",             // reaction author identity
      "hmac-approval-tag",           // schedule approval tag
      "device-executor-xyz",         // relay_executor
      "424242"                       // in_reply_to_thread_id
    ]
    for needle in forbiddenSubstrings {
      for s in strings {
        XCTAssertFalse(s.contains(needle), "structural identifier '\(needle)' leaked in: \(s)")
      }
    }
  }

  // MARK: - Content passthrough is intentional and pinned (finding 2, honesty)

  func testMessageBodyIsCarriedVerbatimIncludingAnyPIITheUserWrote() {
    // This is the product, not a leak: you are reviewing a message you wrote. Pinned so the honest
    // scope cannot be quietly narrowed or widened.
    let body = "call me at +15551234567 re: the thing"
    let snapshot = RelaySnapshot.project(from: draft(body: body), originDeviceID: "device-aaaaaaaa")
    XCTAssertEqual(snapshot.body, body)
  }

  // MARK: - Group leaks the review found (finding 1)

  func testGroupShapedToHandleWithNoStructNeverLeaksViaTheDirectPath() throws {
    // The degenerate case: an older writer dropped imessage_group but the raw binding survives in
    // to_handle. `isIMessageGroupDraft` catches it; a naive `imessage_group != nil` would not, and
    // the guid/handles would ride out as a "direct" label.
    for handle in [
      "imessage-group:iMessage;+;chat999000",
      "imessage-group-pending:+15559990001|+15559990002"
    ] {
      var d = draft(body: "x")
      d = d.withToHandle(handle, name: nil)
      let recipient = RelayRecipient.project(from: d)
      XCTAssertEqual(recipient.kind, .group)
      XCTAssertEqual(recipient.label, "Group thread")
      XCTAssertFalse(recipient.label.contains("chat999000"))
      XCTAssertFalse(recipient.label.contains("+1555"))
    }
  }

  func testUnnamedGroupProjectsToACount() {
    let group = IMessageGroupDraftTarget(
      chat_guid: "iMessage;+;chat999000",
      participant_handles: ["+15559990001", "+15559990002", "+15559990003"],
      participant_names: []
    )
    XCTAssertEqual(RelayRecipient.safeGroupLabel(group), "Group thread (3 people)")
  }

  func testGroupNamesThatAreHandleShapedAreCountedNotPrinted() {
    // finding 2: a "name" that is actually a phone number must not be printed as a name.
    let group = IMessageGroupDraftTarget(
      chat_guid: "iMessage;+;chat1",
      participant_handles: ["+15559990001", "+15559990002"],
      participant_names: ["Maya", "+15559990002"]
    )
    let label = RelayRecipient.safeGroupLabel(group)
    XCTAssertEqual(label, "Group thread with Maya and 1 more")
    XCTAssertFalse(label.contains("+1555"))
  }

  // MARK: - Context sender identity hardening (finding 2)

  func testContextSenderThatIsHandleShapedBecomesPseudonym() {
    for name in ["+15557778888", "someone@example.com"] {
      let projected = RelayContextMessage.project(from: contextMessage(senderName: name))
      XCTAssertEqual(projected.sender_display, "them", "showed a handle-shaped name: \(name)")
    }
  }

  func testContextSenderWithNoNameBecomesPseudonym() {
    let projected = RelayContextMessage.project(from: contextMessage(senderName: nil, senderHandle: "+15557778888"))
    XCTAssertEqual(projected.sender_display, "them")
  }

  // MARK: - Residual cases the re-verification pass caught

  func testBindingShapedNameIsTreatedAsAHandleNotPrinted() {
    // A sender_name or participant name that is itself a group-binding / pipe-joined handle list
    // must not print. `looksLikeHandle` catches the "imessage-group" substring and the all-digit
    // pipe-joined case.
    XCTAssertTrue(RelayText.looksLikeHandle("imessage-group-pending:+15559990001|+15559990002"))
    XCTAssertTrue(RelayText.looksLikeHandle("+15559990001|+15559990002"))
    let projected = RelayContextMessage.project(from: contextMessage(senderName: "imessage-group-pending:+15559990001|+15559990002"))
    XCTAssertEqual(projected.sender_display, "them")
  }

  func testDirectRecipientWhoseHandleStartsWithImessageGroupIsNotMislabelledAsAGroup() {
    // Only the COLON-delimited canonical bindings are groups. An email that merely begins with
    // "imessage-group" is an ordinary 1:1 recipient and must show as itself, not "Group thread".
    var d = draft(body: "x")
    d = d.withToHandle("imessage-groupie@example.com", name: nil)
    let recipient = RelayRecipient.project(from: d)
    XCTAssertEqual(recipient.kind, .direct)
    XCTAssertEqual(recipient.label, "imessage-groupie@example.com")
  }

  func testWhitespaceOnlyNamesAreTreatedAsAbsent() {
    // Newline-only names must not print; trimming is newline-safe.
    let group = IMessageGroupDraftTarget(
      chat_guid: "iMessage;+;chat1",
      participant_handles: ["+15559990001", "+15559990002"],
      participant_names: ["\n\n", "  \t "]
    )
    XCTAssertEqual(RelayRecipient.safeGroupLabel(group), "Group thread (2 people)")

    let ctx = RelayContextMessage.project(from: contextMessage(senderName: "\n \n"))
    XCTAssertEqual(ctx.sender_display, "them")
  }

  func testBidiObfuscatedBindingNameIsStillSuppressed() {
    // A binding string with an interspersed direction-control char must not evade classification by
    // hiding the "imessage-group" substring. Normalization runs before looksLikeHandle.
    let rlo = "\u{202E}"
    let obfuscated = "imessage\(rlo)-group-pending:+15559990001|+15559990002"
    XCTAssertTrue(RelayText.looksLikeHandle(obfuscated))
    let ctx = RelayContextMessage.project(from: contextMessage(senderName: obfuscated))
    XCTAssertEqual(ctx.sender_display, "them")

    let group = IMessageGroupDraftTarget(
      chat_guid: "iMessage;+;chat1",
      participant_handles: ["+15559990001", "+15559990002"],
      participant_names: [obfuscated, "Maya"]
    )
    let label = RelayRecipient.safeGroupLabel(group)
    XCTAssertEqual(label, "Group thread with Maya and 1 more")
    XCTAssertFalse(label.contains("+1555"))
  }

  func testAKeepsRealNamesWithNumbersReadable() {
    // Guard against over-eager handle classification: a normal name with a small number is a name.
    XCTAssertFalse(RelayText.looksLikeHandle("Room 101"))
    XCTAssertFalse(RelayText.looksLikeHandle("Maya"))
  }

  // MARK: - Bidi hardening on identity labels (finding 7)

  func testBidiControlsAreStrippedFromIdentityLabelsButBodyIsLeftToTheRenderer() {
    let rlo = "\u{202E}"
    // Identity label: stripped here, because a reversed phone number is a spoof and the label is
    // not content the user needs byte-exact.
    let recip = RelayRecipient.project(from: draft(body: "x", contactName: "\(rlo)7778889999"))
    XCTAssertFalse(recip.label.contains(rlo))
    // Body: NOT stripped here; it is message content and the phase-3 renderer bidi-isolates it.
    let snap = RelaySnapshot.project(from: draft(body: "\(rlo)hi"), originDeviceID: "device-aaaaaaaa")
    XCTAssertTrue(snap.body.contains(rlo))
  }

  // MARK: - has_attachments (criterion 4)

  func testHasAttachmentsTrueAndPathsAbsent() throws {
    let snapshot = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    XCTAssertTrue(snapshot.has_attachments)
    XCTAssertFalse(try allStrings(in: snapshot).contains { $0.contains("/Users/") })
  }

  // MARK: - Lifecycle, matching the app's own predicates (finding 9)

  func testLifecycleUsesTheSamePredicatesAsTheApp() {
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x")), .pending)
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x", scheduledAt: "2026-08-01T09:00:00Z")), .scheduled)
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x", scheduledAt: "2026-08-01T09:00:00Z", holdReason: "quiet_hours")), .held)
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x", sentAt: "2026-07-01T00:00:00Z")), .sent)
    // The bug the review named: a hold reason on an UNSCHEDULED draft must NOT read as held.
    XCTAssertEqual(RelayLifecycle.of(draft(body: "x", holdReason: "quiet_hours")), .pending)
  }

  // MARK: - Digest is unambiguous (finding 6)

  func testDigestDistinguishesContentThatAmbiguousConcatenationWouldCollide() {
    // "Bob:hello" vs "Bob","hello" style collision: length-prefixing must keep them distinct.
    let a = RelaySnapshot.project(from: draft(body: "x", contextBody: "Bob:hello", contextName: "Alice"), originDeviceID: "d-11111111")
    let b = RelaySnapshot.project(from: draft(body: "x", contextBody: "hello", contextName: "Alice:Bob"), originDeviceID: "d-11111111")
    XCTAssertNotEqual(a.snapshot_digest, b.snapshot_digest)
  }

  func testDigestChangesWithBodyAndIsDeterministic() {
    let one = RelaySnapshot.project(from: draft(body: "one"), originDeviceID: "device-aaaaaaaa")
    let oneAgain = RelaySnapshot.project(from: draft(body: "one"), originDeviceID: "device-aaaaaaaa")
    let two = RelaySnapshot.project(from: draft(body: "two"), originDeviceID: "device-aaaaaaaa")
    XCTAssertEqual(one.snapshot_digest, oneAgain.snapshot_digest)
    XCTAssertNotEqual(one.snapshot_digest, two.snapshot_digest)
  }

  // MARK: - Purity (finding 8/10, honestly labelled)

  func testProjectionCreatesNoFile() {
    // A necessary check, not a proof of purity: the device id is injected so nothing here calls
    // DeviceIdentity (which can create device.json). If a future helper reads Contacts/Keychain
    // this test would not catch it; the guarantee is maintained by keeping projection value-only.
    _ = RelaySnapshot.project(from: fullyLoadedDraft(), originDeviceID: "device-aaaaaaaa")
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".messages-mcp").path))
  }

  func testUntrustedTextIsDeclared() {
    XCTAssertTrue(RelaySnapshot.textIsUntrusted)
  }

  func testGoldenJSONShape() throws {
    // Locks value TYPES, not just key names (finding 4): enums are strings, has_attachments is a
    // bool, context is an array of objects.
    let snapshot = RelaySnapshot.project(from: draft(body: "hi", contextBody: "yo", contextName: "Pat"), originDeviceID: "device-aaaaaaaa")
    let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
    XCTAssertEqual(obj["platform"] as? String, "imessage")
    XCTAssertEqual(obj["lifecycle"] as? String, "pending")
    XCTAssertEqual((obj["recipient"] as? [String: Any])?["kind"] as? String, "direct")
    XCTAssertEqual(obj["has_attachments"] as? Bool, false)
    XCTAssertNotNil(obj["context"] as? [[String: Any]])
  }

  // MARK: - Helpers

  private func encodedKeySet<T: Encodable>(_ value: T) throws -> Set<String> {
    let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    return Set(obj.keys)
  }

  /// Every string scalar anywhere in the encoded value, so a leak cannot hide in a nested object or
  /// survive JSON escaping.
  private func allStrings<T: Encodable>(in value: T) throws -> [String] {
    let root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    var out: [String] = []
    func walk(_ any: Any) {
      switch any {
      case let s as String: out.append(s)
      case let a as [Any]: a.forEach(walk)
      case let d as [String: Any]:
        for (k, v) in d { out.append(k); walk(v) }
      default: break
      }
    }
    walk(root)
    return out
  }

  // MARK: - Fixtures

  private func contextMessage(
    senderName: String? = "Bystander",
    senderHandle: String? = "+15557778888",
    sentAt: String? = "2026-06-01T00:00:00Z"
  ) -> ContextMessage {
    ContextMessage(
      guid: "iMessage;-;guid-of-another-message", message_id: "p:ABC-STANZA-42",
      from_me: false, sender_handle: senderHandle, sender_name: senderName,
      body: "context body", sent_at: sentAt,
      reaction: MessageReaction(kind: .loved, from_me: false, sender_handle: "reaction-author", sender_name: nil, sent_at: nil),
      reactions: [MessageReaction(kind: .loved, from_me: false, sender_handle: "reaction-author", sender_name: nil, sent_at: nil)]
    )
  }

  private func fullyLoadedDraft() -> Draft {
    Draft(
      id: "d-full", to_handle: "imessage-group:iMessage;+;chat999000", to_handle_name: nil,
      imessage_group: IMessageGroupDraftTarget(
        chat_guid: "iMessage;+;chat999000",
        participant_handles: ["+15559990001", "+15559990002"],
        participant_names: ["Maya", "Alex"]),
      body: "the draft body",
      attachments: [DraftAttachment(
        path: "/Users/jamesheath/Library/attachment.jpg", filename: "attachment.jpg",
        mime_type: "image/jpeg", byte_count: 10, asset_id: "a1", sha256: "sha256-of-the-attachment")],
      delivery_progress: DraftDeliveryProgress(completed_attachment_count: 0, body_sent: false, ambiguous_part: nil),
      in_reply_to_thread_id: 424242, staged_at: "2026-07-20T00:00:00Z",
      sent_at: nil, send_service: "iMessage", source: "test",
      context_messages: [contextMessage()], context_diagnostic: nil,
      scheduled_send_at: nil, schedule_hold_reason: nil, override_send: nil,
      schedule_approved: nil, schedule_approval_tag: "hmac-approval-tag-secret",
      schema_version: nil, platform: nil, approval_state: nil, induced_by_unknown_contact: nil,
      quoted_message_id: "q-id",
      quoted_preview: QuotedPreview(message_id: "q-id", body: "the quoted message", from_me: false, sender_name: "Q"),
      relay_executor: "device-executor-xyz"
    )
  }

  private func draft(
    body: String, contactName: String? = "Recipient Name",
    contextBody: String? = nil, contextName: String? = nil,
    quotedBody: String? = nil, quotedFromMe: Bool = false,
    scheduledAt: String? = nil, holdReason: String? = nil, sentAt: String? = nil
  ) -> Draft {
    let context: [ContextMessage]? = contextBody.map { cb in
      [ContextMessage(guid: nil, message_id: nil, from_me: false, sender_handle: "+15550000000",
                      sender_name: contextName, body: cb, sent_at: "t", reaction: nil, reactions: [])]
    }
    let quoted = quotedBody.map { QuotedPreview(message_id: "q-id", body: $0, from_me: quotedFromMe, sender_name: "Q") }
    return Draft(
      id: "d-1", to_handle: "+14155551234", to_handle_name: contactName, imessage_group: nil,
      body: body, attachments: nil, delivery_progress: nil, in_reply_to_thread_id: nil,
      staged_at: "2026-07-20T00:00:00Z", sent_at: sentAt, send_service: nil, source: nil,
      context_messages: context, context_diagnostic: nil, scheduled_send_at: scheduledAt,
      schedule_hold_reason: holdReason, override_send: nil, schedule_approved: nil,
      schedule_approval_tag: nil, schema_version: nil, platform: nil, approval_state: nil,
      induced_by_unknown_contact: nil, quoted_message_id: quotedBody == nil ? nil : "q-id",
      quoted_preview: quoted, relay_executor: nil
    )
  }
}

private extension Draft {
  /// Rebuild with a different recipient, for the degenerate group-binding cases.
  func withToHandle(_ handle: String, name: String?) -> Draft {
    Draft(
      id: id, to_handle: handle, to_handle_name: name, imessage_group: nil, body: body,
      attachments: attachments, delivery_progress: delivery_progress,
      in_reply_to_thread_id: in_reply_to_thread_id, staged_at: staged_at, sent_at: sent_at,
      send_service: send_service, source: source, context_messages: context_messages,
      context_diagnostic: context_diagnostic, scheduled_send_at: scheduled_send_at,
      schedule_hold_reason: schedule_hold_reason, override_send: override_send,
      schedule_approved: schedule_approved, schedule_approval_tag: schedule_approval_tag,
      schema_version: schema_version, platform: platform, approval_state: approval_state,
      induced_by_unknown_contact: induced_by_unknown_contact, quoted_message_id: quoted_message_id,
      quoted_preview: quoted_preview, relay_executor: relay_executor
    )
  }
}
