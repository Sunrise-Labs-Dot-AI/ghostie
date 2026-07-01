import XCTest
@testable import MessagesForAIMenu

final class DontGhostTests: XCTestCase {
  func testDismissalHidesSameLastMessageOnly() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dont-ghost-\(UUID().uuidString).json")
    let store = DontGhostDismissalStore(url: url)

    XCTAssertTrue(store.shouldShow(threadID: 42, lastMessageKey: "2026-06-04T10:00:00Z"))

    store.dismiss(threadID: 42, lastMessageKey: "2026-06-04T10:00:00Z")

    XCTAssertFalse(store.shouldShow(threadID: 42, lastMessageKey: "2026-06-04T10:00:00Z"))
    XCTAssertTrue(store.shouldShow(threadID: 42, lastMessageKey: "2026-06-04T11:00:00Z"))
    XCTAssertTrue(store.shouldShow(threadID: 43, lastMessageKey: "2026-06-04T10:00:00Z"))

    try? FileManager.default.removeItem(at: url)
  }

  // A dismissal file written by an older build stored `iso(lastInboundAt)` as
  // the value. For owed-reply threads `lastMessageAt == lastInboundAt`, so the
  // stored key still matches and the thread stays suppressed. The format is the
  // same `{threadID: isoTimestamp}` map; only the meaning of the value widened.
  func testLegacyDismissalFileStillSuppressesOwedReply() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dont-ghost-legacy-\(UUID().uuidString).json")
    // Simulate an old dismissal file (value == last inbound ISO).
    let legacy = ["42": "2026-06-04T10:00:00Z"]
    try JSONEncoder().encode(legacy).write(to: url)

    let store = DontGhostDismissalStore(url: url)
    // For an owed-reply thread, lastMessageKey == the old inbound key.
    XCTAssertFalse(store.shouldShow(threadID: 42, lastMessageKey: "2026-06-04T10:00:00Z"))
    // A new message moves the anchor and re-surfaces the thread.
    XCTAssertTrue(store.shouldShow(threadID: 42, lastMessageKey: "2026-06-05T09:00:00Z"))

    try? FileManager.default.removeItem(at: url)
  }

  func testCacheStoresSuggestionMetadataWithoutMessageBodies() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dont-ghost-cache-\(UUID().uuidString).json")
    let store = DontGhostCacheStore(url: url)
    let now = Date()
    let suggestion = DontGhostSuggestion(
      threadID: 42,
      platform: .imessage,
      displayName: "Taylor",
      handle: "+15555550123",
      lastInboundAt: now,
      lastMessageAt: now,
      messages: [
        DontGhostMessage(
          id: 1,
          fromMe: false,
          senderName: "Taylor",
          body: "secret message body should not be cached",
          sentAt: now
        )
      ],
      reason: "They asked a question.",
      confidence: 0.8,
      draftText: "I'll reply soon."
    )

    store.save([suggestion])

    let raw = try String(contentsOf: url)
    XCTAssertFalse(raw.contains("secret message body should not be cached"))
    XCTAssertTrue(raw.contains("They asked a question."))
    XCTAssertTrue(raw.contains("I'll reply soon."))

    let loaded = store.load()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.threadID, 42)
    XCTAssertEqual(loaded.first?.draftText, "I'll reply soon.")

    try? FileManager.default.removeItem(at: url)
  }

  func testCacheRemoveDropsDismissedThread() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dont-ghost-cache-\(UUID().uuidString).json")
    let store = DontGhostCacheStore(url: url)
    let now = Date()
    let suggestions = [
      DontGhostSuggestion(
        threadID: 1,
        platform: .imessage,
        displayName: "A",
        handle: "+1",
        lastInboundAt: now,
        lastMessageAt: now,
        messages: [],
        reason: "One",
        confidence: 0.7
      ),
      DontGhostSuggestion(
        threadID: 2,
        platform: .imessage,
        displayName: "B",
        handle: "+2",
        lastInboundAt: now,
        lastMessageAt: now,
        messages: [],
        reason: "Two",
        confidence: 0.8
      )
    ]

    store.save(suggestions)
    store.remove(threadID: 1)

    XCTAssertEqual(store.load().map(\.threadID), [2])

    try? FileManager.default.removeItem(at: url)
  }

  func testPendingDraftSuppressesMatchingThread() {
    let now = Date()
    let suggestions = [
      DontGhostSuggestion(
        threadID: 80,
        platform: .imessage,
        displayName: "Ryan",
        handle: "+12155550121",
        lastInboundAt: now,
        lastMessageAt: now,
        messages: [],
        reason: "Needs reply",
        confidence: 0.7
      ),
      DontGhostSuggestion(
        threadID: 111,
        platform: .imessage,
        displayName: "Maggie",
        handle: "+12155550176",
        lastInboundAt: now,
        lastMessageAt: now,
        messages: [],
        reason: "Needs reply",
        confidence: 0.8
      )
    ]
    let draft = Draft(
      id: "draft-1",
      to_handle: "+1 (215) 555-0121",
      to_handle_name: "Ryan",
      body: "queued",
      in_reply_to_thread_id: 80,
      staged_at: "2026-06-05T00:00:00Z",
      sent_at: nil,
      send_service: nil,
      source: nil,
      context_messages: nil,
      context_diagnostic: nil,
      scheduled_send_at: "2026-06-05T13:00:00Z",
      schedule_hold_reason: nil,
      override_send: nil,
      schedule_approved: true,
      schedule_approval_tag: nil,
      schema_version: nil,
      platform: .imessage,
      approval_state: nil,
      induced_by_unknown_contact: nil,
      quoted_message_id: nil,
      quoted_preview: nil
    )

    let visible = DontGhostController.suggestionsExcludingPendingWork(suggestions, drafts: [draft])

    XCTAssertEqual(visible.map(\.threadID), [111])
  }

  func testStaleIdentityActivityDropsOlderThreadForSameResolvedPerson() {
    let oldInbound = Date(timeIntervalSince1970: 1_000)
    let laterActivity = Date(timeIntervalSince1970: 2_000)
    let suggestions = [
      DontGhostSuggestion(
        threadID: 194,
        platform: .imessage,
        displayName: "Sam Sample",
        handle: "+16095550162",
        lastInboundAt: oldInbound,
        lastMessageAt: oldInbound,
        messages: [],
        reason: "Needs reply",
        confidence: 0.6
      )
    ]

    let visible = DontGhostController.suggestionsExcludingStaleIdentityActivity(
      suggestions,
      latestActivityByIdentity: [
        DontGhostController.contactIdentityKey(displayName: "Sam Sample", handle: "samsample@example.com"): laterActivity
      ]
    )

    XCTAssertTrue(visible.isEmpty)
  }

  func testStaleIdentityActivityDeduplicatesMultipleHandlesForSameResolvedPerson() {
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let suggestions = [
      DontGhostSuggestion(
        threadID: 1,
        platform: .imessage,
        displayName: "Sam Sample",
        handle: "+16095550162",
        lastInboundAt: older,
        lastMessageAt: older,
        messages: [],
        reason: "Older",
        confidence: 0.4
      ),
      DontGhostSuggestion(
        threadID: 2,
        platform: .imessage,
        displayName: "Sam Sample",
        handle: "samsample@example.com",
        lastInboundAt: newer,
        lastMessageAt: newer,
        messages: [],
        reason: "Newer",
        confidence: 0.7
      )
    ]

    let visible = DontGhostController.suggestionsExcludingStaleIdentityActivity(
      suggestions,
      latestActivityByIdentity: [
        DontGhostController.contactIdentityKey(displayName: "Sam Sample", handle: "+16095550162"): newer
      ]
    )

    XCTAssertEqual(visible.map(\.threadID), [2])
  }

  func testRelationshipGateKeepsSavedContacts() {
    let messages = [
      DontGhostMessage(id: 1, fromMe: false, senderName: "Taylor", body: "Are you around?", sentAt: Date())
    ]

    XCTAssertTrue(DontGhostController.passesRelationshipGate(isSavedContact: true, messages: messages))
  }

  func testRelationshipGateRejectsUnsavedOneWayThreads() {
    let messages = [
      DontGhostMessage(id: 1, fromMe: false, senderName: nil, body: "Your code is 123456", sentAt: Date()),
      DontGhostMessage(id: 2, fromMe: false, senderName: nil, body: "Reply STOP to opt out", sentAt: Date())
    ]

    XCTAssertFalse(DontGhostController.passesRelationshipGate(isSavedContact: false, messages: messages))
  }

  func testRelationshipGateAllowsUnsavedRealBackAndForth() {
    let now = Date()
    let messages = [
      DontGhostMessage(id: 1, fromMe: false, senderName: nil, body: "hey are you coming tonight", sentAt: now),
      DontGhostMessage(id: 2, fromMe: true, senderName: "You", body: "yes what time", sentAt: now),
      DontGhostMessage(id: 3, fromMe: false, senderName: nil, body: "probably 8", sentAt: now),
      DontGhostMessage(id: 4, fromMe: true, senderName: "You", body: "cool see you then", sentAt: now),
      DontGhostMessage(id: 5, fromMe: false, senderName: nil, body: "bring beer?", sentAt: now)
    ]

    XCTAssertTrue(DontGhostController.passesRelationshipGate(isSavedContact: false, messages: messages))
  }

  func testRelationshipGateDoesNotCountTapbacksAsDepth() {
    let now = Date()
    let messages = [
      DontGhostMessage(id: 1, fromMe: false, senderName: nil, body: "Liked a message", sentAt: now),
      DontGhostMessage(id: 2, fromMe: true, senderName: "You", body: "Loved a message", sentAt: now),
      DontGhostMessage(id: 3, fromMe: false, senderName: nil, body: "Reacted with emoji a message", sentAt: now),
      DontGhostMessage(id: 4, fromMe: true, senderName: "You", body: "ok", sentAt: now),
      DontGhostMessage(id: 5, fromMe: false, senderName: nil, body: "cool", sentAt: now)
    ]

    XCTAssertFalse(DontGhostController.passesRelationshipGate(isSavedContact: false, messages: messages))
  }

  func testLLMParserAcceptsStrictThreadDecisionJSON() throws {
    let rows = try XCTUnwrap(DontGhostLLMResponseParser.parseThreadDecisions("""
    {"threads":[{"id":42,"should_reply":true,"reason":"Question still open.","confidence":0.91}]}
    """))

    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].id, 42)
    XCTAssertTrue(rows[0].shouldReply)
    XCTAssertEqual(rows[0].reason, "Question still open.")
    XCTAssertEqual(rows[0].confidence, 0.91)
  }

  func testLLMParserAcceptsFencedAndProseWrappedJSON() throws {
    let rows = try XCTUnwrap(DontGhostLLMResponseParser.parseThreadDecisions("""
    Here is the JSON:
    ```json
    {"threads":[{"id":7,"should_reply":false,"confidence":0.2}]}
    ```
    """))

    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].id, 7)
    XCTAssertFalse(rows[0].shouldReply)
    XCTAssertEqual(rows[0].reason, "Needs a reply.")
  }

  func testLLMParserRejectsMalformedThreadDecisionJSON() {
    XCTAssertNil(DontGhostLLMResponseParser.parseThreadDecisions("""
    {"threads":[{"id":"not-an-int","should_reply":true}]}
    """))
    XCTAssertNil(DontGhostLLMResponseParser.parseThreadDecisions("no json here"))
  }

  func testLLMParserKeepsValidRowsWhenOneRowIsMalformed() throws {
    // A single flaky row from a nondeterministic model must not discard the
    // whole batch — the good rows survive, the bad row is dropped.
    let rows = try XCTUnwrap(DontGhostLLMResponseParser.parseThreadDecisions("""
    {"threads":[
      {"id":1,"should_reply":true,"reason":"Open question.","confidence":0.9},
      {"id":"oops","should_reply":true},
      {"id":3,"should_reply":false,"confidence":0.1}
    ]}
    """))

    XCTAssertEqual(rows.map { $0.id }, [1, 3])
    XCTAssertTrue(rows[0].shouldReply)
    XCTAssertFalse(rows[1].shouldReply)
  }

  func testLLMParserTreatsEmptyThreadsArrayAsValidReplyToNone() throws {
    // An empty array is a legitimate "none of these need a reply" answer and
    // must not be treated as an invalid response.
    let rows = try XCTUnwrap(DontGhostLLMResponseParser.parseThreadDecisions("{\"threads\":[]}"))
    XCTAssertTrue(rows.isEmpty)
  }

  func testLLMParserAcceptsNewShouldSurfaceKey() throws {
    let rows = try XCTUnwrap(DontGhostLLMResponseParser.parseThreadDecisions("""
    {"threads":[{"id":9,"should_surface":true,"reason":"Worth reconnecting.","confidence":0.8}]}
    """))
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(rows[0].shouldSurface)
    XCTAssertEqual(rows[0].reason, "Worth reconnecting.")
  }

  // MARK: - Business-name filter (parity with business.ts)

  func testIsObviousBusinessName() {
    // Caught — brands and business nouns (incl. the health / One Medical class).
    for name in ["DoorDash", "Amazon", "One Medical", "Walgreens Pharmacy",
                 "Wells Fargo", "Bright Smiles Dental", "Appointment Reminders",
                 "Chase", "Verizon"] {
      XCTAssertTrue(BusinessFilter.looksLikeBusinessName(name), "\(name) should be a business")
    }
    // Kept — real people whose names CONTAIN a token substring (word boundaries
    // stop "Banks" → "bank", "Healey" → "health").
    for name in ["Tyler Banks", "Dana Healey", "Priya Healey", "Robin Sample",
                 "Alex Sample", "Jordan Fixture", "Kim Sample", "Casey Fixture"] {
      XCTAssertFalse(BusinessFilter.looksLikeBusinessName(name), "\(name) should NOT be a business")
    }
  }

  func testBusinessFilterHandles() {
    for handle in ["21525", "+18332612950", "no-reply@onemedical.com",
                   "partiful_mxmphj70_agent@rbm.goog", "google@rbm.goog"] {
      XCTAssertTrue(BusinessFilter.looksLikeBusinessHandle(handle), "\(handle) should be a business")
    }
    for handle in ["+12015550163", "jane.doe@example.com", "+14045550100"] {
      XCTAssertFalse(BusinessFilter.looksLikeBusinessHandle(handle), "\(handle) should NOT be a business")
    }
  }

  // MARK: - Transactional / automation content filter

  /// Table-driven coverage for the content-based automated/transactional
  /// detector added to `looksLikeTransactionalThread`. The One Medical sample
  /// (an appointment reminder from a plain 415 number with no saved business
  /// name) must be filtered; normal personal threads must NOT be. The filter is
  /// precision-tuned because the user is recall-favoring: a false positive
  /// silently hides a real conversation, so subject mentions alone (an
  /// "appointment", a "verification code") are never enough without a templated
  /// automation instruction, a decisive footer, or a repeated template.
  func testLooksLikeTransactionalThreadTable() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func inb(_ body: String) -> DontGhostMessage {
      DontGhostMessage(id: 1, fromMe: false, senderName: nil, body: body, sentAt: base)
    }
    func out(_ body: String) -> DontGhostMessage {
      DontGhostMessage(id: 2, fromMe: true, senderName: "You", body: body, sentAt: base)
    }

    struct Case { let name: String; let messages: [DontGhostMessage]; let expected: Bool }

    let cases: [Case] = [
      // --- SHOULD be filtered: automated / transactional ---
      Case(
        name: "One Medical appointment reminder on a plain number",
        messages: [
          inb("Hi James, you have an appointment over Zoom today at 9:40 AM PDT. To Confirm: Reply Y / To Reschedule: https://onemedical.com/r/abc"),
          out("Y")
        ],
        expected: true
      ),
      Case(
        name: "decisive: automated-message footer",
        messages: [inb("This is an automated message from your clinic.")],
        expected: true
      ),
      Case(
        name: "decisive: Reply STOP opt-out (single keyword the legacy count misses)",
        messages: [inb("Your refill is ready. Reply STOP to end.")],
        expected: true
      ),
      Case(
        name: "instruction + subject in one body",
        messages: [inb("Reminder: confirm or reschedule your appointment for tomorrow.")],
        expected: true
      ),
      Case(
        name: "near-identical repeated templated reminder (subject only, no instruction)",
        messages: [
          inb("Your visit is scheduled for today at 9:40 AM. See the front desk when you arrive."),
          out("ok"),
          inb("Your visit is scheduled for today at 10:15 AM. See the front desk when you arrive.")
        ],
        expected: true
      ),
      // --- should NOT be filtered: real people ---
      Case(
        name: "normal personal back-and-forth",
        messages: [
          inb("hey are you coming tonight"), out("yes what time"),
          inb("probably 8"), out("cool see you then"), inb("bring beer?")
        ],
        expected: false
      ),
      Case(
        name: "real person mentions an appointment (subject, no instruction)",
        messages: [inb("ugh I have a dentist appointment tomorrow at 3, can we push our coffee?")],
        expected: false
      ),
      Case(
        name: "real person wants to reschedule (no templated instruction)",
        messages: [inb("hey something came up, can we reschedule dinner? lmk what works")],
        expected: false
      ),
      Case(
        name: "real person asks for a verification code (subject alone is not enough)",
        messages: [inb("what's the verification code you just got? need it for the netflix login")],
        expected: false
      ),
      Case(
        name: "no false 'reply Y' match inside 'reply your'",
        messages: [inb("can you reply your availability for the dog walk next week?")],
        expected: false
      ),
      Case(
        name: "dog walker service update from a real person",
        messages: [inb("Hi! Walked Biscuit for 30 min, he did great. See you tomorrow!"), out("thank you!!")],
        expected: false
      )
    ]

    for c in cases {
      XCTAssertEqual(
        DontGhostScanner.looksLikeTransactionalThread(c.messages),
        c.expected,
        "transactional filter mismatch for case: \(c.name)"
      )
    }
  }

  // MARK: - Follow-up candidate selection + gates

  private func msg(_ id: Int64, fromMe: Bool, _ body: String, at date: Date) -> DontGhostMessage {
    DontGhostMessage(id: id, fromMe: fromMe, senderName: fromMe ? "You" : "Them", body: body, sentAt: date)
  }

  /// A real back-and-forth where THEY sent last, past the 1-day silence floor:
  /// owed reply. (Owed replies only surface after a full day so we don't nag
  /// mid-conversation — see SelectionGate.minInboundAge.)
  func testCandidateSelectionOwedReplyWhenTheySentLast() throws {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    let theirLast = now.addingTimeInterval(-2 * 86_400) // 2 days ago
    let messages = [
      msg(1, fromMe: true, "you around tonight?", at: now.addingTimeInterval(-2 * 86_400 - 3600)),
      msg(2, fromMe: false, "yeah what's up", at: theirLast)
    ]
    let sel = try XCTUnwrap(DontGhostController.candidateSelection(
      messages: messages, aiEnabled: true, isSavedContact: true, now: now
    ))
    XCTAssertEqual(sel.kind, .owedReply)
    XCTAssertEqual(sel.lastInboundAt, theirLast)
    XCTAssertEqual(sel.lastMessageAt, theirLast)
    XCTAssertEqual(sel.reason, DontGhostController.owedReplyReason)
  }

  /// They sent last but only 12h ago — below the 1-day floor, not a candidate.
  /// (Guards the floor specifically: the old 2h floor would have surfaced this.)
  func testCandidateSelectionOwedReplyRejectsTooFresh() {
    let now = Date()
    let messages = [
      msg(1, fromMe: true, "hey", at: now.addingTimeInterval(-13 * 3600)),
      msg(2, fromMe: false, "hi", at: now.addingTimeInterval(-12 * 3600)) // 12h ago
    ]
    XCTAssertNil(DontGhostController.candidateSelection(
      messages: messages, aiEnabled: true, isSavedContact: true, now: now
    ))
  }

  /// You sent last and it's been 6 days: follow-up (with AI).
  func testCandidateSelectionFollowUpWhenYouSentLast() throws {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    let yourLast = now.addingTimeInterval(-6 * 86_400)
    let theirLast = now.addingTimeInterval(-7 * 86_400)
    let messages = [
      msg(1, fromMe: false, "miss you, let's catch up soon", at: theirLast),
      msg(2, fromMe: true, "yes! i'll text you", at: yourLast)
    ]
    let sel = try XCTUnwrap(DontGhostController.candidateSelection(
      messages: messages, aiEnabled: true, isSavedContact: true, now: now
    ))
    XCTAssertEqual(sel.kind, .followUp)
    XCTAssertEqual(sel.lastMessageAt, yourLast)
    XCTAssertEqual(sel.lastInboundAt, theirLast)
    XCTAssertEqual(sel.reason, DontGhostController.followUpReason)
  }

  /// You sent last but only 2 days ago — below the 4-day follow-up floor. We do
  /// NOT nag about a text they simply haven't gotten to yet.
  func testCandidateSelectionFollowUpRejectsRecentUnanswered() {
    let now = Date()
    let messages = [
      msg(1, fromMe: false, "what's the plan", at: now.addingTimeInterval(-3 * 86_400)),
      msg(2, fromMe: true, "thinking saturday", at: now.addingTimeInterval(-2 * 86_400)) // 2d ago
    ]
    XCTAssertNil(DontGhostController.candidateSelection(
      messages: messages, aiEnabled: true, isSavedContact: true, now: now
    ))
  }

  /// You sent last, no prior inbound at all (one-way blast) — not a follow-up.
  func testCandidateSelectionFollowUpRequiresPriorInbound() {
    let now = Date()
    let messages = [
      msg(1, fromMe: true, "hey!", at: now.addingTimeInterval(-10 * 86_400)),
      msg(2, fromMe: true, "you there?", at: now.addingTimeInterval(-9 * 86_400))
    ]
    XCTAssertNil(DontGhostController.candidateSelection(
      messages: messages, aiEnabled: true, isSavedContact: true, now: now
    ))
  }

  /// candidateSelection no longer hard-restricts follow-ups by saved-status in
  /// no-AI mode — an unsaved contact within the window IS a candidate; the
  /// deterministic SCORER (relationship strength + cadence) decides what actually
  /// surfaces (see the scorer tests below).
  func testCandidateSelectionFollowUpAcceptsUnsavedContact() throws {
    let now = Date()
    let messages = [
      msg(1, fromMe: false, "great seeing you", at: now.addingTimeInterval(-11 * 86_400)),
      msg(2, fromMe: true, "likewise, let's do it again", at: now.addingTimeInterval(-10 * 86_400))
    ]
    let sel = try XCTUnwrap(DontGhostController.candidateSelection(
      messages: messages, aiEnabled: false, isSavedContact: false, now: now
    ))
    XCTAssertEqual(sel.kind, .followUp)
  }

  /// Deterministic mode: a SAVED contact within the conservative window IS a
  /// follow-up.
  func testCandidateSelectionDeterministicFollowUpAllowsSavedContactInWindow() throws {
    let now = Date()
    let messages = [
      msg(1, fromMe: false, "great seeing you", at: now.addingTimeInterval(-11 * 86_400)),
      msg(2, fromMe: true, "likewise, let's do it again", at: now.addingTimeInterval(-10 * 86_400))
    ]
    let sel = try XCTUnwrap(DontGhostController.candidateSelection(
      messages: messages, aiEnabled: false, isSavedContact: true, now: now
    ))
    XCTAssertEqual(sel.kind, .followUp)
  }

  /// There's no longer a ~90-day deterministic cutoff: a thread within the 1-year
  /// follow-up window is a candidate in BOTH modes (the scorer governs surfacing).
  /// The shared 1-year maximum still applies.
  func testCandidateSelectionFollowUpAllowedBeyondNinetyDaysWithinYear() throws {
    let now = Date()
    let messages = [
      msg(1, fromMe: false, "hey", at: now.addingTimeInterval(-200 * 86_400)),
      msg(2, fromMe: true, "let's catch up", at: now.addingTimeInterval(-180 * 86_400)) // ~180d
    ]
    XCTAssertEqual(
      DontGhostController.candidateSelection(messages: messages, aiEnabled: false, isSavedContact: true, now: now)?.kind,
      .followUp
    )
    XCTAssertEqual(
      DontGhostController.candidateSelection(messages: messages, aiEnabled: true, isSavedContact: true, now: now)?.kind,
      .followUp
    )
    // Past the 1-year max, still suppressed in both modes.
    let stale = [
      msg(1, fromMe: false, "hey", at: now.addingTimeInterval(-500 * 86_400)),
      msg(2, fromMe: true, "let's catch up", at: now.addingTimeInterval(-400 * 86_400)) // >1y
    ]
    XCTAssertNil(DontGhostController.candidateSelection(messages: stale, aiEnabled: false, isSavedContact: true, now: now))
  }

  // MARK: - Deterministic scorer

  private let scoreNow = Date(timeIntervalSince1970: 1_000_000_000)

  /// Build an owed-reply thread: one outbound, then `trailing` inbound messages
  /// ending in `lastInbound`, the last aged `ageDays`.
  private func owedScore(_ lastInbound: String, trailing: Int = 1, ageDays: Double = 1) -> DontGhostController.DontGhostScore {
    var messages = [msg(1, fromMe: true, "earlier", at: scoreNow.addingTimeInterval(-12 * 86_400))]
    for i in 0..<trailing {
      let isLast = i == trailing - 1
      messages.append(msg(Int64(100 + i), fromMe: false, isLast ? lastInbound : "you up?", at: scoreNow.addingTimeInterval(-ageDays * 86_400)))
    }
    return DontGhostController.scoreCandidate(kind: .owedReply, messages: messages, isSavedContact: true, now: scoreNow)
  }

  func testScoreOwedReplyQuestionSurfaces() {
    let s = owedScore("you around this weekend?")
    XCTAssertTrue(s.surfaced)
    XCTAssertGreaterThan(s.value, 0.5)
    XCTAssertEqual(s.reason, "They asked you something and it's still open.")
  }

  func testScoreOwedReplyInterrogativeWithoutQuestionMarkSurfaces() {
    XCTAssertTrue(owedScore("what time works for you").surfaced)
  }

  func testScoreOwedReplyExplicitAskSurfaces() {
    XCTAssertTrue(owedScore("let me know the address").surfaced)
  }

  func testScoreOwedReplyInvitationSurfaces() {
    let s = owedScore("wanna grab dinner friday")
    XCTAssertTrue(s.surfaced)
    XCTAssertEqual(s.reason, "They floated a plan — worth a quick yes or no.")
  }

  func testScoreOwedReplyEmotionalBidSurfaces() {
    XCTAssertTrue(owedScore("miss you, how've you been").surfaced)
  }

  func testScoreOwedReplyMultipleUnansweredBoostsScore() {
    // "you there" carries no cue; the extra unanswered inbound is what raises it.
    let single = owedScore("you there", trailing: 1)
    let multi = owedScore("you there", trailing: 2)
    XCTAssertTrue(single.surfaced) // base == threshold: a plain owed reply still surfaces
    XCTAssertGreaterThan(multi.value, single.value)
  }

  func testScoreOwedReplyPureAckSuppressed() {
    XCTAssertFalse(owedScore("ok").surfaced)
    XCTAssertFalse(owedScore("sounds good, see you then").surfaced)
    XCTAssertFalse(owedScore("thanks 🙏").surfaced)
    XCTAssertFalse(owedScore("👍").surfaced)
  }

  func testScoreOwedReplyTapbackSuppressed() {
    XCTAssertFalse(owedScore("Loved an image").surfaced)
    XCTAssertFalse(owedScore("👍 to “Excellent - thank you”").surfaced) // verb-less emoji tapback
    XCTAssertFalse(owedScore("❤️ to \"see you then\"").surfaced)
    // Must NOT suppress a real message that merely contains "to":
    XCTAssertTrue(owedScore("can we still go to the thing?").surfaced)
  }

  func testScoreOwedReplyRecentQuestionOutranksOldQuestion() {
    let recent = owedScore("what's the plan?", ageDays: 2)
    let old = owedScore("what's the plan?", ageDays: 300)
    XCTAssertTrue(recent.surfaced)
    XCTAssertGreaterThan(recent.value, old.value)
  }

  /// A close, balanced thread that's gone quiet relative to its rhythm surfaces —
  /// and does so even for an UNSAVED contact (the old saved-only gate is gone).
  func testScoreFollowUpCloseBalancedQuietSurfacesEvenUnsaved() {
    var messages: [DontGhostMessage] = []
    for i in 0..<12 {
      // ~3.3-day cadence over 40 days, alternating direction.
      messages.append(msg(Int64(i + 1), fromMe: i % 2 == 0, "chatting \(i)", at: scoreNow.addingTimeInterval(-Double(40 - i * 3) * 86_400)))
    }
    messages.append(msg(99, fromMe: true, "talk soon", at: scoreNow.addingTimeInterval(-25 * 86_400))) // you sent last, 25d quiet
    let s = DontGhostController.scoreCandidate(kind: .followUp, messages: messages, isSavedContact: false, now: scoreNow)
    XCTAssertTrue(s.surfaced)
  }

  /// A thin, one-way thread does NOT surface as a follow-up even when very quiet.
  func testScoreFollowUpWeakOneWayThreadFilteredEvenWhenQuiet() {
    let messages = [
      msg(1, fromMe: false, "hey", at: scoreNow.addingTimeInterval(-60 * 86_400)),
      msg(2, fromMe: true, "hi", at: scoreNow.addingTimeInterval(-59 * 86_400)),
      msg(3, fromMe: true, "you there", at: scoreNow.addingTimeInterval(-58 * 86_400)),
      msg(4, fromMe: true, "hello", at: scoreNow.addingTimeInterval(-57 * 86_400))
    ]
    XCTAssertFalse(DontGhostController.scoreCandidate(kind: .followUp, messages: messages, isSavedContact: false, now: scoreNow).surfaced)
  }

  /// Cadence-awareness: with comparable relationships, a chatty pair surfaces at a
  /// silence where a sparse pair does not.
  func testScoreFollowUpCadenceAwareChattyPairSurfacesSooner() {
    func thread(spacingDays: Double) -> [DontGhostMessage] {
      var messages: [DontGhostMessage] = []
      for i in 0..<10 {
        messages.append(msg(Int64(i + 1), fromMe: i % 2 == 0, "msg \(i)", at: scoreNow.addingTimeInterval(-Double(8) * 86_400 - Double(10 - i) * spacingDays * 86_400)))
      }
      messages.append(msg(99, fromMe: true, "later", at: scoreNow.addingTimeInterval(-8 * 86_400))) // both 8d quiet
      return messages
    }
    let chatty = DontGhostController.scoreCandidate(kind: .followUp, messages: thread(spacingDays: 1), isSavedContact: true, now: scoreNow)
    let sparse = DontGhostController.scoreCandidate(kind: .followUp, messages: thread(spacingDays: 33), isSavedContact: true, now: scoreNow)
    XCTAssertTrue(chatty.surfaced)
    XCTAssertGreaterThan(chatty.value, sparse.value)
  }

  func testFollowUpThresholdIsHigherThanOwedReply() {
    XCTAssertGreaterThan(DontGhostController.ScoreThreshold.followUp, DontGhostController.ScoreThreshold.owedReply)
  }

  func testScoreOwedReplyNoCueFallsBackToGenericReason() {
    XCTAssertEqual(owedScore("i went to the store today").reason, DontGhostController.owedReplyReason)
  }

  // MARK: - Cache backward compatibility (kind)

  func testCacheDecodeDefaultsMissingKindToOwedReply() throws {
    // An old cache row has no "kind" field. It must decode as .owedReply.
    let json = """
    [{"threadID":42,"platform":"imessage","displayName":"Taylor","handle":"+15555550123",
      "lastInboundKey":"2026-06-04T10:00:00Z","lastMessageKey":"2026-06-04T10:00:00Z",
      "reason":"They asked a question.","confidence":0.8,"draftText":"","cachedAt":"2026-06-04T11:00:00Z"}]
    """
    let rows = try JSONDecoder().decode([DontGhostCachedSuggestion].self, from: Data(json.utf8))
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].kind, .owedReply)
  }

  func testCacheRoundTripsFollowUpKind() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dont-ghost-cache-\(UUID().uuidString).json")
    let store = DontGhostCacheStore(url: url)
    let now = Date()
    let suggestion = DontGhostSuggestion(
      threadID: 7,
      platform: .imessage,
      displayName: "Jordan",
      handle: "+15555550199",
      lastInboundAt: now.addingTimeInterval(-7 * 86_400),
      lastMessageAt: now.addingTimeInterval(-6 * 86_400),
      messages: [],
      kind: .followUp,
      reason: DontGhostController.followUpReason,
      confidence: 0.7
    )
    store.save([suggestion])
    let loaded = store.load()
    XCTAssertEqual(loaded.first?.kind, .followUp)
    // The cache anchor is the last MESSAGE timestamp, not the inbound one.
    XCTAssertEqual(loaded.first?.lastMessageKey, DontGhostController.iso(now.addingTimeInterval(-6 * 86_400)))

    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Sort + draft-prompt routing

  func testByRecencySortsByLastMessageInterleavingKinds() {
    let base = Date(timeIntervalSince1970: 1_000_000_000)
    func sug(_ id: Int, kind: DontGhostKind, last: TimeInterval) -> DontGhostSuggestion {
      DontGhostSuggestion(
        threadID: id, platform: .imessage, displayName: "P\(id)", handle: "+\(id)",
        lastInboundAt: base, lastMessageAt: base.addingTimeInterval(last),
        messages: [], kind: kind, reason: "", confidence: 0.5
      )
    }
    let followUpNewest = sug(1, kind: .followUp, last: 100)
    let owedMiddle = sug(2, kind: .owedReply, last: 50)
    let owedOldest = sug(3, kind: .owedReply, last: 10)
    let sorted = [owedOldest, owedMiddle, followUpNewest].sorted(by: DontGhostController.byRecency)
    // Most-recent activity first, regardless of kind.
    XCTAssertEqual(sorted.map(\.threadID), [1, 2, 3])
  }

  func testByRecencyTieBreaksOwedReplyAheadOfFollowUp() {
    let t = Date(timeIntervalSince1970: 1_000_000_000)
    func sug(_ id: Int, kind: DontGhostKind) -> DontGhostSuggestion {
      DontGhostSuggestion(
        threadID: id, platform: .imessage, displayName: "P\(id)", handle: "+\(id)",
        lastInboundAt: t, lastMessageAt: t, messages: [], kind: kind, reason: "", confidence: 0.5
      )
    }
    let sorted = [sug(1, kind: .followUp), sug(2, kind: .owedReply)].sorted(by: DontGhostController.byRecency)
    XCTAssertEqual(sorted.map(\.kind), [.owedReply, .followUp])
  }
}
