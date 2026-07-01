import XCTest
@testable import MessagesForAIMenu

@MainActor
final class WorkPersonalTests: XCTestCase {
  func test_defaultsStartDisabledForExistingUsers() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }

    let store = WorkPersonalStore(homeOverride: home)

    XCTAssertFalse(store.enabled)
    XCTAssertEqual(store.mode, .basic)
    XCTAssertTrue(store.personLabels.isEmpty)
    XCTAssertTrue(store.messageLabels.isEmpty)
  }

  func test_personLabelsPersistRoundTrip() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let recent = recent(handle: "+14045550100")

    let first = WorkPersonalStore(homeOverride: home)
    first.enabled = true
    first.mode = .pro
    first.workDescription = "I run a design agency."
    first.setPersonLabel(.work, for: recent)

    let second = WorkPersonalStore(homeOverride: home)

    XCTAssertTrue(second.enabled)
    XCTAssertEqual(second.mode, .pro)
    XCTAssertEqual(second.workDescription, "I run a design agency.")
    XCTAssertEqual(second.personLabel(for: recent), .work)
  }

  func test_strictFilterBehavior() {
    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.work, filter: .work))
    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.both, filter: .work))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.personal, filter: .work))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.neither, filter: .work))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.business, filter: .work))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.spam, filter: .work))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.unknown, filter: .work))

    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.personal, filter: .personal))
    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.both, filter: .personal))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.work, filter: .personal))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.business, filter: .personal))
    XCTAssertFalse(WorkPersonalVisibility.strictFilter(.spam, filter: .personal))
    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.neither, filter: .all))
    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.business, filter: .all))
    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.spam, filter: .all))
    XCTAssertTrue(WorkPersonalVisibility.strictFilter(.unknown, filter: .all))
  }

  func test_basicConversationFilteringUsesPersonLabel() {
    XCTAssertTrue(
      WorkPersonalVisibility.conversationVisible(
        personLabel: .work,
        messageLabels: [],
        filter: .work,
        proEnabled: false
      )
    )
    XCTAssertFalse(
      WorkPersonalVisibility.conversationVisible(
        personLabel: .personal,
        messageLabels: [],
        filter: .work,
        proEnabled: false
      )
    )
  }

  func test_proMessageFilteringUsesMessageLabelsThenPersonFallback() {
    XCTAssertTrue(
      WorkPersonalVisibility.conversationVisible(
        personLabel: .personal,
        messageLabels: [.work],
        filter: .work,
        proEnabled: true
      )
    )
    XCTAssertFalse(
      WorkPersonalVisibility.messageVisible(
        messageLabel: .personal,
        personLabel: .work,
        filter: .work,
        proEnabled: true
      )
    )
    XCTAssertTrue(
      WorkPersonalVisibility.messageVisible(
        messageLabel: nil,
        personLabel: .work,
        filter: .work,
        proEnabled: true
      )
    )
  }

  func test_proModeWithoutAPIKeyRequestsSettings() {
    XCTAssertTrue(
      WorkPersonalModeGate.shouldOpenSettings(requestedMode: .pro, hasAPIKey: false)
    )
    XCTAssertFalse(
      WorkPersonalModeGate.shouldOpenSettings(requestedMode: .pro, hasAPIKey: true)
    )
    XCTAssertFalse(
      WorkPersonalModeGate.shouldOpenSettings(requestedMode: .basic, hasAPIKey: false)
    )
  }

  func test_sortingGameApplyAndUndo() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = WorkPersonalStore(homeOverride: home)
    let allie = recent(handle: "+14045550100", title: "Allie")
    let bob = recent(handle: "+14045550200", title: "Bob")

    let state = WorkPersonalSortState.make(from: [allie, bob], store: store)
    let advanced = state.applying(label: .work, store: store)

    XCTAssertEqual(store.personLabel(for: allie), .work)
    XCTAssertEqual(advanced.current?.title, "Bob")

    let undone = advanced.undo(store: store)

    XCTAssertEqual(store.personLabel(for: allie), .unknown)
    XCTAssertEqual(undone.current?.title, "Allie")
  }

  func test_sortingGameSkipAndUndoDoesNotAssignLabel() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = WorkPersonalStore(homeOverride: home)
    let allie = recent(handle: "+14045550100", title: "Allie")
    let bob = recent(handle: "+14045550200", title: "Bob")

    let state = WorkPersonalSortState.make(from: [allie, bob], store: store)
    let skipped = state.skipping()

    XCTAssertEqual(store.personLabel(for: allie), .unknown)
    XCTAssertEqual(skipped.current?.title, "Bob")

    let undone = skipped.undo(store: store)

    XCTAssertEqual(store.personLabel(for: allie), .unknown)
    XCTAssertEqual(undone.current?.title, "Allie")
  }

  func test_sortingGameUndoWithEmptyHistoryIsNoOp() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = WorkPersonalStore(homeOverride: home)
    let allie = recent(handle: "+14045550100", title: "Allie")

    let state = WorkPersonalSortState.make(from: [allie], store: store)
    let undone = state.undo(store: store)

    XCTAssertEqual(undone.current?.title, "Allie")
    XCTAssertEqual(undone.history.count, 0)
    XCTAssertEqual(store.personLabel(for: allie), .unknown)
  }

  func test_spamBusinessPersistsAsPersonLabel() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = WorkPersonalStore(homeOverride: home)
    let recent = recent(handle: "+18444478629", title: "+18444478629")

    store.setPersonLabel(.business, for: recent)

    XCTAssertEqual(store.personLabel(for: recent), .business)
  }

  func test_classificationBatchDoesNotStoreBodies() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = WorkPersonalStore(homeOverride: home)
    store.workDescription = "My work is consulting."
    let recent = recent(handle: "+14045550100")
    let message = ContextMessage(
      from_me: false,
      sender_handle: "+14045550100",
      sender_name: "Allie",
      body: "Can you review the deck before the client call?",
      sent_at: "2026-06-01T12:00:00.000Z"
    )

    let batch = WorkPersonalClassifierBatcher.classificationBatch(
      conversations: [(recent, [message])],
      store: store
    )
    let parsed = try! WorkPersonalClassifier.parse(
      #"{"labels":[{"id":"\#(batch.items[0].id)","label":"work","confidence":0.9,"reason":"client call"}]}"#,
      provider: .openAI,
      modelID: "gpt-5-mini"
    )
    store.upsertMessageLabels(parsed, provider: .openAI, modelID: "gpt-5-mini")

    let data = try! Data(contentsOf: home.appendingPathComponent(".messages-mcp/work-personal.json"))
    let raw = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(raw.contains("client call?"))
    XCTAssertFalse(raw.contains("review the deck"))
    XCTAssertTrue(raw.contains("client call"))
  }

  func test_inlineComposerNewlineBehavior() {
    XCTAssertEqual(InlineComposerNewlineAction.action(shiftPressed: false), .submit)
    XCTAssertEqual(InlineComposerNewlineAction.action(shiftPressed: true), .insertNewline)
  }

  func test_professionGatePresentsOnlyWhenWorkDescriptionIsEmpty() {
    XCTAssertTrue(WorkPersonalProfessionGate.shouldPresent(workDescription: ""))
    XCTAssertTrue(WorkPersonalProfessionGate.shouldPresent(workDescription: "  \n "))
    XCTAssertFalse(WorkPersonalProfessionGate.shouldPresent(workDescription: "I run a design agency."))
  }

  func test_peoplePromptCarriesNameSchedulingAndAmbiguityGuidance() {
    let prompt = WorkPersonalAIFirstPass.prompt(
      people: [["key": "person|imessage|+1404", "name": "Dads", "handle_kind": "phone", "recent_inbound": []]],
      workDescription: "I run a design agency."
    )
    XCTAssertTrue(prompt.contains("\"name\" field is a strong signal"))
    XCTAssertTrue(prompt.contains("Scheduling and logistics"))
    XCTAssertTrue(prompt.contains("do NOT imply work"))
    XCTAssertTrue(prompt.contains("LOWER confidence"))
    XCTAssertTrue(prompt.contains("never guess \"work\""))
    XCTAssertTrue(prompt.contains("Dads"))
    XCTAssertTrue(prompt.contains("I run a design agency."))
  }

  func test_messagePromptCarriesNameAndSchedulingGuidance() throws {
    let batch = WorkPersonalClassificationBatch(
      workDescription: "I run a design agency.",
      items: [
        WorkPersonalClassificationItem(
          id: "message|conversation|abc",
          personLabel: "unknown",
          sender: "Allie",
          sentAt: "2026-06-01T12:00:00.000Z",
          body: "Can you do 3pm?"
        )
      ]
    )
    let prompt = try WorkPersonalClassifier.makePrompt(batch: batch)
    XCTAssertTrue(prompt.contains("Sender and conversation names are real signals"))
    XCTAssertTrue(prompt.contains("Scheduling and logistics"))
    XCTAssertTrue(prompt.contains("do NOT imply work"))
    XCTAssertTrue(prompt.contains("lower confidence rather than guessing work"))
    XCTAssertTrue(prompt.contains("I run a design agency."))
  }

  func test_autoTagsObviousBusinessesLeavesPeopleAndManualLabels() {
    let home = tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = WorkPersonalStore(homeOverride: home)

    let pharmacy = recent(handle: "+14045559000", title: "Acme Pharmacy") // name → business
    let shortcode = recent(handle: "262966", title: "Amazon")             // handle → business
    let friend = recent(handle: "+14045550100", title: "Tyler Banks")     // 'Banks' ≠ 'bank'
    let colleague = recent(handle: "+14045550200", title: "Dana Cole")

    // A manual label must NOT be overwritten by the auto pass.
    store.setPersonLabel(.personal, for: shortcode)

    let tagged = store.autoTagObviousBusinesses([pharmacy, shortcode, friend, colleague])

    XCTAssertEqual(tagged, 1) // only the pharmacy — shortcode was already labeled
    XCTAssertEqual(store.personLabel(for: pharmacy), .business)
    XCTAssertEqual(store.personLabel(for: shortcode), .personal) // manual wins
    XCTAssertEqual(store.personLabel(for: friend), .unknown)     // surname look-alike kept
    XCTAssertEqual(store.personLabel(for: colleague), .unknown)

    // The auto label persists across a reload.
    let reloaded = WorkPersonalStore(homeOverride: home)
    XCTAssertEqual(reloaded.personLabel(for: pharmacy), .business)
  }

  private func recent(
    handle: String,
    title: String = "Allie",
    platform: Platform = .imessage
  ) -> RecentComposeThread {
    RecentComposeThread(
      id: "\(platform.rawValue)-\(handle)",
      platform: platform,
      handle: handle,
      title: title,
      subtitle: handle,
      threadID: platform == .imessage ? 42 : nil,
      lastMessageDate: Date()
    )
  }

  private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("messages-ai-work-personal-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

final class WorkPersonalScheduleTests: XCTestCase {
  private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
    // 2026-06-07 is a Sunday (weekday 1); offset to the target weekday.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let sunday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 7, hour: hour, minute: minute))!
    return calendar.date(byAdding: .day, value: weekday - 1, to: sunday)!
  }

  func test_activeInsideWeekdayWindow() {
    let schedule = WorkPersonalSchedule(isOn: true, weekdays: [2, 3, 4, 5, 6], startMinutes: 9 * 60, endMinutes: 17 * 60)
    XCTAssertTrue(schedule.isActive(at: date(weekday: 2, hour: 10)))   // Monday 10:00
    XCTAssertFalse(schedule.isActive(at: date(weekday: 2, hour: 18)))  // Monday 18:00
    XCTAssertFalse(schedule.isActive(at: date(weekday: 1, hour: 10)))  // Sunday 10:00
    XCTAssertFalse(schedule.isActive(at: date(weekday: 2, hour: 8, minute: 59)))
    XCTAssertTrue(schedule.isActive(at: date(weekday: 2, hour: 9)))
  }

  func test_overnightWindowWraps() {
    let schedule = WorkPersonalSchedule(isOn: true, weekdays: [2], startMinutes: 22 * 60, endMinutes: 6 * 60)
    XCTAssertTrue(schedule.isActive(at: date(weekday: 2, hour: 23)))
    XCTAssertTrue(schedule.isActive(at: date(weekday: 2, hour: 5)))
    XCTAssertFalse(schedule.isActive(at: date(weekday: 2, hour: 12)))
  }

  func test_offScheduleNeverActive() {
    let schedule = WorkPersonalSchedule(isOn: false, weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 24 * 60)
    XCTAssertFalse(schedule.isActive(at: date(weekday: 2, hour: 10)))
  }

  @MainActor
  func test_edgeTriggeredEnforcementRespectsManualOverride() {
    let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wp-schedule-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpHome) }
    let store = WorkPersonalStore(homeOverride: tmpHome)
    store.schedule = WorkPersonalSchedule(isOn: true, weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60)

    // Boundary crossing into the window enables.
    store.applyScheduleTick(now: date(weekday: 2, hour: 8))
    XCTAssertFalse(store.enabled)
    store.applyScheduleTick(now: date(weekday: 2, hour: 9))
    XCTAssertTrue(store.enabled)

    // Manual off mid-window sticks until the next boundary.
    store.enabled = false
    store.applyScheduleTick(now: date(weekday: 2, hour: 10))
    XCTAssertFalse(store.enabled)
    store.applyScheduleTick(now: date(weekday: 2, hour: 17))
    XCTAssertFalse(store.enabled)
    store.applyScheduleTick(now: date(weekday: 2, hour: 9, minute: 30))
    XCTAssertTrue(store.enabled)
  }
}


final class WorkPersonalTaxonomyTests: XCTestCase {
  func test_legacySpamBusinessDecodesToBusiness() throws {
    let decoded = try JSONDecoder().decode(WorkPersonalLabel.self, from: Data("\"spam_business\"".utf8))
    XCTAssertEqual(decoded, .business)
    let spam = try JSONDecoder().decode(WorkPersonalLabel.self, from: Data("\"spam\"".utf8))
    XCTAssertEqual(spam, .spam)
    let junk = try JSONDecoder().decode(WorkPersonalLabel.self, from: Data("\"mystery\"".utf8))
    XCTAssertEqual(junk, .unknown)
  }

  func test_firstPassPartitionAppliesOnlyConfidentCalls() {
    let decisions = [
      WorkPersonalAIFirstPass.PersonDecision(personKey: "a", label: .business, confidence: 0.95, reason: "airline"),
      WorkPersonalAIFirstPass.PersonDecision(personKey: "b", label: .personal, confidence: 0.6, reason: nil),
      WorkPersonalAIFirstPass.PersonDecision(personKey: "c", label: .unknown, confidence: 0.99, reason: nil),
      WorkPersonalAIFirstPass.PersonDecision(personKey: "d", label: .spam, confidence: 0.8, reason: "shortcode blast"),
    ]
    let split = WorkPersonalAIFirstPass.partition(decisions)
    XCTAssertEqual(split.apply.map(\.personKey), ["a", "d"])
    XCTAssertEqual(split.suggest.map(\.personKey), ["b"])
  }

  func test_parsePeopleReadsDecisions() throws {
    let raw = """
    {"people":[{"key":"imessage|+1404","label":"spam","confidence":0.91,"reason":"political blast"}]}
    """
    let parsed = try WorkPersonalClassifier.parsePeople(raw)
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed[0].label, .spam)
    XCTAssertEqual(parsed[0].confidence, 0.91, accuracy: 0.001)
  }
}

final class LumonRefinementCodenameTests: XCTestCase {
  func testCodenameIsDeterministicForSameQueue() {
    let ids = ["chat-1", "chat-2", "chat-3"]
    XCTAssertEqual(
      LumonRefinementCodename.codename(for: ids),
      LumonRefinementCodename.codename(for: ids)
    )
  }

  func testCodenameComesFromTheFileList() {
    XCTAssertTrue(LumonRefinementCodename.files.contains(LumonRefinementCodename.codename(for: [])))
    XCTAssertTrue(LumonRefinementCodename.files.contains(LumonRefinementCodename.codename(for: ["a", "b"])))
  }

  func testCodenameVariesAcrossQueues() {
    // Not guaranteed for any single pair, but across many distinct queues
    // at least two file names must appear or the seeding is broken.
    let names = Set((0..<40).map { LumonRefinementCodename.codename(for: ["queue-\($0)"]) })
    XCTAssertGreaterThan(names.count, 1)
  }

  func testHexReadoutShapeAndDeterminism() {
    let readout = LumonRefinementCodename.hexReadout("iMessage;-;+15555550123")
    XCTAssertTrue(readout.hasPrefix("0x"))
    XCTAssertEqual(readout.count, 8)
    XCTAssertEqual(readout, LumonRefinementCodename.hexReadout("iMessage;-;+15555550123"))
  }

  func testMixIsDeterministicAndNonNegative() {
    XCTAssertEqual(LumonRefinementCodename.mix(7, 13), LumonRefinementCodename.mix(7, 13))
    XCTAssertGreaterThanOrEqual(LumonRefinementCodename.mix(-5, 0), 0)
  }
}
