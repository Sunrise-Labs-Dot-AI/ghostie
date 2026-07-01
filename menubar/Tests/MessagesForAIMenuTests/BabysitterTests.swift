import SQLite3
import XCTest
@testable import MessagesForAIMenu

final class BabysitterTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("babysitter-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  @MainActor
  func testRosterPersistsProfilesAndRejectsDuplicateCanonicalHandle() throws {
    let url = tempDir.appendingPathComponent("babysitter.json")
    let store = BabysitterStore(fileURL: url)
    let match = ContactMatch(name: "Maya Sitter", bestHandle: "+1 (404) 555-0100", handles: ["4045550100"], savedBirthday: nil)

    let profile = try store.addContact(match)
    XCTAssertEqual(profile.contact.name, "Maya Sitter")
    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertThrowsError(try store.addContact(match)) { error in
      XCTAssertEqual(error as? BabysitterStoreError, .duplicateContact)
    }

    try store.updateProfile(
      id: profile.id,
      rate: "$25/hr",
      tags: ["after school", "CPR", "after school"],
      notes: "Great with bedtime",
      preferredHandle: profile.displayHandle,
      isActive: false
    )

    let reloaded = BabysitterStore(fileURL: url)
    XCTAssertEqual(reloaded.profiles.first?.rate, "$25/hr")
    XCTAssertEqual(reloaded.profiles.first?.tags, ["after school", "CPR"])
    XCTAssertEqual(reloaded.profiles.first?.isActive, false)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
  }

  @MainActor
  func testRosterDefaultRankCanBeReorderedAndReloaded() throws {
    let url = tempDir.appendingPathComponent("babysitter.json")
    let store = BabysitterStore(fileURL: url)
    let maya = try store.addContact(ContactMatch(name: "Maya Sitter", bestHandle: "+14045550100", handles: [], savedBirthday: nil))
    let noah = try store.addContact(ContactMatch(name: "Noah Sitter", bestHandle: "+14045550101", handles: [], savedBirthday: nil))
    let zoe = try store.addContact(ContactMatch(name: "Zoe Sitter", bestHandle: "+14045550102", handles: [], savedBirthday: nil))

    XCTAssertEqual(store.profiles.map(\.id), [maya.id, noah.id, zoe.id])

    store.reorderProfiles(from: IndexSet(integer: 2), to: 0)

    XCTAssertEqual(store.profiles.map(\.id), [zoe.id, maya.id, noah.id])
    XCTAssertEqual(store.activeProfiles.map(\.id), [zoe.id, maya.id, noah.id])
    XCTAssertEqual(store.profiles.map(\.defaultRank), [0, 1, 2])

    let reloaded = BabysitterStore(fileURL: url)
    XCTAssertEqual(reloaded.profiles.map(\.id), [zoe.id, maya.id, noah.id])
    XCTAssertEqual(reloaded.profiles.map(\.defaultRank), [0, 1, 2])
  }

  @MainActor
  func testRequestValidationAndStatsExcludePendingAsks() throws {
    let store = BabysitterStore(fileURL: tempDir.appendingPathComponent("babysitter.json"))
    let sitter = try store.addContact(ContactMatch(name: "Maya Sitter", bestHandle: "+14045550100", handles: ["+14045550100"], savedBirthday: nil))
    let partner = try BabysitterContactSnapshot.make(
      match: ContactMatch(name: "Alex Partner", bestHandle: "+14045550200", handles: ["+14045550200"], savedBirthday: nil)
    )
    XCTAssertThrowsError(try store.createRequest(
      startsAt: Date().addingTimeInterval(3600),
      endsAt: Date(),
      note: "",
      partner: nil,
      orderedSitterIDs: [sitter.id]
    )) { error in
      XCTAssertEqual(error as? BabysitterStoreError, .invalidDateRange)
    }
    XCTAssertThrowsError(try store.createRequest(
      startsAt: Date().addingTimeInterval(3600),
      endsAt: Date().addingTimeInterval(7200),
      note: "",
      partner: sitter.contact,
      orderedSitterIDs: [sitter.id]
    )) { error in
      XCTAssertEqual(error as? BabysitterStoreError, .partnerMatchesSitter)
    }

    let start = Date().addingTimeInterval(2 * 3600)
    let request = try store.createRequest(
      startsAt: start,
      endsAt: start.addingTimeInterval(3 * 3600),
      note: "Dinner nearby",
      partner: partner,
      orderedSitterIDs: [sitter.id]
    )
    XCTAssertThrowsError(try store.createRequest(
      startsAt: start,
      endsAt: start.addingTimeInterval(3600),
      note: "",
      partner: nil,
      orderedSitterIDs: [sitter.id]
    )) { error in
      XCTAssertEqual(error as? BabysitterStoreError, .activeRequestExists)
    }

    let prepared = try store.prepareNextOutreach()
    let target = BabysitterMessageTarget(
      sitterID: sitter.id,
      sitterHandle: sitter.displayHandle,
      partner: partner,
      imessageGroup: IMessageGroupDraftTarget(
        chat_guid: nil,
        participant_handles: [sitter.displayHandle, partner.bestHandle],
        participant_names: [sitter.contact.name, partner.name]
      )
    )
    try store.recordDraft(requestID: request.id, outreachID: prepared.outreach.id, draftID: "draft-1", target: target)
    XCTAssertEqual(store.profile(id: sitter.id)?.stats.asksSent, 1)
    XCTAssertNil(store.profile(id: sitter.id)?.stats.acceptanceRate, "pending asks are excluded")

    let sentAt = Date()
    store.markOutreachSent(draftID: "draft-1", sentAt: sentAt)
    try store.recordOutcome(
      requestID: request.id,
      outreachID: prepared.outreach.id,
      outcome: .accepted,
      resolvedAt: sentAt.addingTimeInterval(600)
    )
    let stats = try XCTUnwrap(store.profile(id: sitter.id)?.stats)
    XCTAssertEqual(stats.accepts, 1)
    XCTAssertEqual(stats.acceptanceRate, 1)
    XCTAssertEqual(stats.medianResponseSeconds, 600)
  }

  func testReplyClassifierIsDeterministicAndAmbiguityPauses() {
    XCTAssertEqual(BabysitterReplyClassifier.classify("Yes, I can!"), .accept)
    XCTAssertEqual(BabysitterReplyClassifier.classify("Sorry, I can't that night"), .decline)
    XCTAssertEqual(BabysitterReplyClassifier.classify("What time would you be back?"), .ambiguous)
    XCTAssertEqual(BabysitterReplyClassifier.classify("I can maybe, but probably no"), .ambiguous)
  }

  func testTimeHelpersUseFifteenMinuteSlotsAndThreeHourDefault() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = try XCTUnwrap(calendar.date(from: DateComponents(
      timeZone: calendar.timeZone,
      year: 2026,
      month: 6,
      day: 11,
      hour: 9,
      minute: 7
    )))
    let rounded = BabysitterView.roundedUpToQuarterHour(date, calendar: calendar)

    XCTAssertEqual(BabysitterView.minutesFromMidnight(rounded, calendar: calendar), 9 * 60 + 15)
    XCTAssertEqual(BabysitterView.quarterHourSlots.count, 96)
    XCTAssertEqual(BabysitterView.quarterHourSlots.prefix(4), [0, 15, 30, 45])
    XCTAssertEqual(BabysitterView.defaultDurationSeconds, 3 * 60 * 60)

    let exact = try XCTUnwrap(calendar.date(from: DateComponents(
      timeZone: calendar.timeZone,
      year: 2026,
      month: 6,
      day: 11,
      hour: 21,
      minute: 30
    )))
    XCTAssertEqual(BabysitterView.roundedUpToQuarterHour(exact, calendar: calendar), exact)

    let late = try XCTUnwrap(calendar.date(from: DateComponents(
      timeZone: calendar.timeZone,
      year: 2026,
      month: 6,
      day: 11,
      hour: 23,
      minute: 59
    )))
    let nextDay = BabysitterView.roundedUpToQuarterHour(late, calendar: calendar)
    XCTAssertEqual(BabysitterView.minutesFromMidnight(nextDay, calendar: calendar), 0)
    XCTAssertFalse(calendar.isDate(late, inSameDayAs: nextDay))
  }

  func testPremiumAndFeatureFlagWiring() throws {
    let tool = try XCTUnwrap(ToolRegistry.all.first(where: { $0.id == ToolCatalog.babysitter }))
    XCTAssertTrue(tool.requiresAPIKey)
    XCTAssertEqual(tool.featureFlag, .babysitter)
    XCTAssertNotNil(tool.makeIntroView, "Babysitter registers its themed intro like every other lab")
    XCTAssertFalse(MFAFeatureFlag.babysitter.builtinDefault)
    XCTAssertTrue(ToolCatalog.choosableToolIDs.contains(ToolCatalog.babysitter))
    XCTAssertFalse(ToolRegistry.visibleChoosableToolIDs(resolved: { _ in false }).contains(ToolCatalog.babysitter))
    XCTAssertTrue(ToolRegistry.visibleChoosableToolIDs(resolved: { $0 == .babysitter }).contains(ToolCatalog.babysitter))
    XCTAssertTrue(PremiumGate.unlocked(subscriptionActive: true, hasAPIKey: false))
    XCTAssertTrue(PremiumGate.unlocked(subscriptionActive: false, hasAPIKey: true))
    XCTAssertFalse(PremiumGate.unlocked(subscriptionActive: false, hasAPIKey: false))
  }

  @MainActor
  func testGroupDraftTargetRequiresExactlySitterAndPartner() throws {
    let sitterContact = try BabysitterContactSnapshot.make(
      match: ContactMatch(name: "Maya Sitter", bestHandle: "+14045550100", handles: ["+14045550100"], savedBirthday: nil)
    )
    let partner = try BabysitterContactSnapshot.make(
      match: ContactMatch(name: "Alex Partner", bestHandle: "+14045550200", handles: ["+14045550200"], savedBirthday: nil)
    )
    let sitter = BabysitterProfile.make(contact: sitterContact, rank: 0)
    let resolver = StaticGroupResolver(resolved: IMessageResolvedGroup(chatID: 42, chatGUID: "iMessage;+;chat42"))
    let target = try IMessageGroupTargetPolicy.makeTarget(sitter: sitter, partner: partner, resolver: resolver)
    XCTAssertEqual(target.chat_guid, "iMessage;+;chat42")
    XCTAssertEqual(target.participant_handles, ["+14045550100", "+14045550200"])

    XCTAssertThrowsError(try IMessageGroupTargetPolicy.validateTwoParticipantTarget(["+14045550100"])) { error in
      XCTAssertEqual(error as? IMessageGroupTargetError, .wrongParticipantCount)
    }
    XCTAssertThrowsError(try IMessageGroupTargetPolicy.validateTwoParticipantTarget(["+14045550100", "+1 (404) 555-0100"])) { error in
      XCTAssertEqual(error as? IMessageGroupTargetError, .duplicateParticipants)
    }
  }

  @MainActor
  func testDraftStoreCreatesGroupDraftAndBindsApprovalToGroupTarget() throws {
    let store = DraftStore(homeOverride: tempDir)
    let group = IMessageGroupDraftTarget(
      chat_guid: nil,
      participant_handles: ["+14045550100", "+14045550200"],
      participant_names: ["Maya", "Alex"]
    )
    let scheduled = Date().addingTimeInterval(3600)
    let draft = try store.createIMessageGroupDraft(
      group: group,
      body: "Hi Maya, are you available?",
      scheduledAt: scheduled,
      approveScheduledDraft: true
    )
    XCTAssertEqual(draft.imessage_group, group)
    XCTAssertEqual(draft.to_handle, group.canonicalRecipient)
    XCTAssertTrue(draft.isScheduleAuthenticallyApproved)
    XCTAssertTrue(draft.scheduleApprovalCanonicalMessage.contains(group.canonicalRecipient))

    let url = tempDir
      .appendingPathComponent(".messages-mcp/drafts", isDirectory: true)
      .appendingPathComponent("\(draft.id).json")
    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(Draft.self, from: data)
    XCTAssertEqual(decoded.imessage_group, group)
    XCTAssertEqual(decoded.source, "Ghostie Babysitter")
  }

  @MainActor
  func testCorruptBabysitterFileIsQuarantinedNotClobbered() throws {
    let url = tempDir.appendingPathComponent("babysitter.json")
    let corruptBytes = Data("{ this is not json".utf8)
    try corruptBytes.write(to: url)

    let store = BabysitterStore(fileURL: url)

    XCTAssertTrue(store.profiles.isEmpty, "decode failure starts a fresh database")
    let error = try XCTUnwrap(store.lastError)
    XCTAssertTrue(error.contains("babysitter.json.corrupt-"), "the user is told where their old data went: \(error)")

    let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    let quarantined = try XCTUnwrap(
      siblings.first(where: { $0.hasPrefix("babysitter.json.corrupt-") }),
      "corrupt file is moved aside, not left for persist() to clobber"
    )
    let preserved = try Data(contentsOf: tempDir.appendingPathComponent(quarantined))
    XCTAssertEqual(preserved, corruptBytes, "quarantined bytes are untouched")

    // The next persist() writes a fresh file and must not touch the backup.
    _ = try store.addContact(ContactMatch(name: "Maya Sitter", bestHandle: "+14045550100", handles: [], savedBirthday: nil))
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent(quarantined)), corruptBytes)
    let reloaded = BabysitterStore(fileURL: url)
    XCTAssertEqual(reloaded.profiles.count, 1)
    XCTAssertNil(reloaded.lastError)
  }

  @MainActor
  func testReStagingSameOutreachDoesNotInflateAsksSentAndRebuildMatchesLive() throws {
    let store = BabysitterStore(fileURL: tempDir.appendingPathComponent("babysitter.json"))
    let sitter = try store.addContact(ContactMatch(name: "Maya Sitter", bestHandle: "+14045550100", handles: ["+14045550100"], savedBirthday: nil))
    let start = Date().addingTimeInterval(2 * 3600)
    let request = try store.createRequest(
      startsAt: start,
      endsAt: start.addingTimeInterval(3 * 3600),
      note: "",
      partner: nil,
      orderedSitterIDs: [sitter.id]
    )
    let prepared = try store.prepareNextOutreach()
    let target = BabysitterMessageTarget(
      sitterID: sitter.id,
      sitterHandle: sitter.displayHandle,
      partner: nil,
      imessageGroup: nil
    )

    let stagedAt = Date()
    try store.recordDraft(requestID: request.id, outreachID: prepared.outreach.id, draftID: "draft-1", target: target, now: stagedAt)
    // Discard + Stage Ask again: same outreach, new draft. Must not double-count.
    try store.recordDraft(requestID: request.id, outreachID: prepared.outreach.id, draftID: "draft-2", target: target, now: stagedAt)
    XCTAssertEqual(store.profile(id: sitter.id)?.stats.asksSent, 1, "re-staging the same outreach is one ask")

    let sentAt = Date()
    store.markOutreachSent(draftID: "draft-2", sentAt: sentAt)
    try store.recordOutcome(
      requestID: request.id,
      outreachID: prepared.outreach.id,
      outcome: .accepted,
      resolvedAt: sentAt.addingTimeInterval(300)
    )

    let live = try XCTUnwrap(store.profile(id: sitter.id)?.stats)
    store.rebuildStats()
    let rebuilt = try XCTUnwrap(store.profile(id: sitter.id)?.stats)

    XCTAssertEqual(rebuilt.asksSent, live.asksSent)
    XCTAssertEqual(rebuilt.asksSent, 1)
    XCTAssertEqual(rebuilt.accepts, live.accepts)
    XCTAssertEqual(rebuilt.declines, live.declines)
    XCTAssertEqual(rebuilt.timeouts, live.timeouts)
    XCTAssertEqual(rebuilt.cancellations, live.cancellations)
    XCTAssertEqual(rebuilt.responseTimesSeconds, live.responseTimesSeconds)
    XCTAssertEqual(rebuilt.lastAskedAt, live.lastAskedAt)
    XCTAssertEqual(rebuilt.lastAcceptedAt, live.lastAcceptedAt)
    XCTAssertEqual(rebuilt.acceptanceRate, live.acceptanceRate)
    XCTAssertEqual(
      rebuilt.recentOutcomes.map(\.outcome),
      live.recentOutcomes.map(\.outcome),
      "rebuild replays the same outcome sequence live accumulation produced"
    )
  }

  func testGroupTargetErrorLocalizedDescriptionYieldsPolicyText() {
    let error: Error = IMessageGroupTargetError.wrongParticipantCount
    XCTAssertEqual(
      error.localizedDescription,
      "Babysitter group texts must include exactly one babysitter and one partner."
    )
    XCTAssertEqual(
      (IMessageGroupTargetError.duplicateParticipants as Error).localizedDescription,
      "Babysitter and partner must be different contacts."
    )
    XCTAssertEqual(
      (IMessageGroupTargetError.invalidParticipant as Error).localizedDescription,
      "Every group participant needs a usable Messages handle."
    )
  }

  func testGroupDraftsRenderGroupMarkerAndNeverLeakCanonicalBinding() {
    let group = IMessageGroupDraftTarget(
      chat_guid: nil,
      participant_handles: ["+14045550100", "+14045550200"],
      participant_names: ["Maya", "Alex"]
    )
    let draft = makeDraft(toHandle: group.canonicalRecipient, toHandleName: group.displayName, group: group)
    XCTAssertEqual(draft.recipientDisplayName, "Group thread with Maya & Alex")
    XCTAssertNil(draft.recipientSubtitle, "the canonical binding is machine-facing and never rendered")
    XCTAssertFalse(draft.recipientDisplayName.contains("imessage-group"))

    // Structured target lost (older process rewrote the JSON): still no raw binding.
    let degraded = makeDraft(toHandle: "imessage-group-pending:+14045550100|+14045550200", toHandleName: nil, group: nil)
    XCTAssertEqual(degraded.recipientDisplayName, "Group thread")
    XCTAssertNil(degraded.recipientSubtitle)

    // Ordinary 1:1 drafts are unchanged.
    let plain = makeDraft(toHandle: "+14045550100", toHandleName: nil, group: nil)
    XCTAssertEqual(plain.recipientDisplayName, "+14045550100")
    XCTAssertEqual(plain.recipientSubtitle, "+14045550100")
    let named = makeDraft(toHandle: "+14045550100", toHandleName: "Maya", group: nil)
    XCTAssertEqual(named.recipientDisplayName, "Maya")
    XCTAssertNil(named.recipientSubtitle)
  }

  func testResolverMatchesExactParticipantSetViaChatHandleJoin() throws {
    let dbURL = tempDir.appendingPathComponent("chat.db")
    try makeScratchChatDB(at: dbURL)

    let resolver = IMessageGroupResolver(dbURL: dbURL)
    let resolved = try XCTUnwrap(resolver.resolveExactGroup(participantHandles: ["+14045550100", "+14045550200"]))
    XCTAssertEqual(resolved.chatGUID, "iMessage;+;chat-exact-recent", "most recently used exact match wins; supersets are excluded")

    XCTAssertNil(resolver.resolveExactGroup(participantHandles: ["+14045550100", "+14045550999"]))
    XCTAssertNil(resolver.resolveExactGroup(participantHandles: ["+14045550100"]))
  }

  // MARK: - helpers

  private func makeDraft(toHandle: String, toHandleName: String?, group: IMessageGroupDraftTarget?) -> Draft {
    Draft(
      id: UUID().uuidString.lowercased(),
      to_handle: toHandle,
      to_handle_name: toHandleName,
      imessage_group: group,
      body: "hello",
      in_reply_to_thread_id: nil,
      staged_at: "2026-06-12T10:00:00.000Z",
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
      quoted_preview: nil
    )
  }

  /// Minimal chat.db shape the resolver reads: chat / handle /
  /// chat_handle_join (membership) / chat_message_join (recency). No message
  /// table at all — proving the resolver no longer needs it.
  private func makeScratchChatDB(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
      XCTFail("could not create scratch chat.db")
      return
    }
    defer { sqlite3_close(db) }
    let sql = """
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT);
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
      INSERT INTO handle VALUES (1, '+14045550100'), (2, '+14045550200'), (3, '+14045550300');
      -- Exact match, but stale.
      INSERT INTO chat VALUES (10, 'SMS;+;chat-exact-stale');
      INSERT INTO chat_handle_join VALUES (10, 1), (10, 2);
      INSERT INTO chat_message_join VALUES (10, 900, 100);
      -- Superset (sitter + partner + one more): must be excluded.
      INSERT INTO chat VALUES (11, 'iMessage;+;chat-superset');
      INSERT INTO chat_handle_join VALUES (11, 1), (11, 2), (11, 3);
      INSERT INTO chat_message_join VALUES (11, 901, 500);
      -- Exact match, most recent: the winner.
      INSERT INTO chat VALUES (12, 'iMessage;+;chat-exact-recent');
      INSERT INTO chat_handle_join VALUES (12, 1), (12, 2);
      INSERT INTO chat_message_join VALUES (12, 902, 300);
      -- Two-participant chat with different people: not a match.
      INSERT INTO chat VALUES (13, 'iMessage;+;chat-other-pair');
      INSERT INTO chat_handle_join VALUES (13, 1), (13, 3);
      """
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
  }
}

private struct StaticGroupResolver: IMessageGroupResolving {
  let resolved: IMessageResolvedGroup?

  func resolveExactGroup(participantHandles: [String]) -> IMessageResolvedGroup? {
    resolved
  }
}
