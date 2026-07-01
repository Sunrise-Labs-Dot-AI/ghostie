import XCTest
@testable import MessagesForAIMenu

final class DeepReadTests: XCTestCase {
  // MARK: - Fixtures

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  /// 2026-06-08 was a Monday; hour picks work vs off bucket deterministically.
  private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute))!
  }

  private func message(
    chat: Int,
    sentAt: Date,
    fromMe: Bool,
    chars: Int = 20,
    lowercaseStart: Bool = false,
    endsPeriod: Bool = false,
    hasEmoji: Bool = false
  ) -> DeepReadRawMessage {
    DeepReadRawMessage(
      chatID: chat,
      sentAt: sentAt,
      fromMe: fromMe,
      bodyChars: chars,
      lowercaseStart: lowercaseStart,
      endsPeriod: endsPeriod,
      endsExclaim: false,
      endsQuestion: false,
      hasEmoji: hasEmoji
    )
  }

  private func sampleStats() -> DeepReadStats {
    DeepReadStats(
      windowDays: 365,
      totalMessages: 1200,
      outboundOverall: .init(
        messageCount: 600, medianChars: 24, pctLowercaseStart: 72,
        pctEndingPeriod: 4, pctEndingExclaim: 11, pctEndingQuestion: 18, pctWithEmoji: 9
      ),
      outboundWorkHours: .init(
        messageCount: 220, medianChars: 41, pctLowercaseStart: 18,
        pctEndingPeriod: 36, pctEndingExclaim: 2, pctEndingQuestion: 21, pctWithEmoji: 1
      ),
      outboundOffHours: .init(
        messageCount: 380, medianChars: 16, pctLowercaseStart: 88,
        pctEndingPeriod: 1, pctEndingExclaim: 14, pctEndingQuestion: 15, pctWithEmoji: 13
      ),
      ghosting: .init(
        threadsSampled: 40, threadsAwaitingMyReply: 7, threadsAwaitingTheirReply: 3,
        medianReplyMinutes: 12, p90ReplyMinutes: 540, pctRepliesOver24h: 6
      ),
      sample: [
        .init(contact: "c1", fromMe: true, weekday: 2, hour: 14, chars: 32, hasEmoji: false, replyMinutes: 8)
      ]
    )
  }

  // MARK: - Style probe

  func testStyleProbeReducesBodyToMetadata() {
    let probed = DeepReadStyleProbe.probe(
      chatID: 9,
      sentAt: Date(timeIntervalSince1970: 0),
      fromMe: true,
      body: "lol be right there 🙂"
    )
    XCTAssertEqual(probed.bodyChars, 20)
    XCTAssertTrue(probed.lowercaseStart)
    XCTAssertTrue(probed.hasEmoji)
    XCTAssertFalse(probed.endsPeriod)

    let formal = DeepReadStyleProbe.probe(
      chatID: 9,
      sentAt: Date(timeIntervalSince1970: 0),
      fromMe: true,
      body: "Sounds good, see you then."
    )
    XCTAssertFalse(formal.lowercaseStart)
    XCTAssertTrue(formal.endsPeriod)
    XCTAssertFalse(formal.hasEmoji)
  }

  // MARK: - Aggregator

  func testAggregatorComputesGhostingAndReplyLatencies() {
    let now = date(day: 20, hour: 12)
    let messages = [
      // Chat 1: inbound answered in 30 minutes, then their last word left
      // hanging for 10 days → awaiting my reply.
      message(chat: 1, sentAt: date(day: 8, hour: 10), fromMe: false),
      message(chat: 1, sentAt: date(day: 8, hour: 10, minute: 30), fromMe: true),
      message(chat: 1, sentAt: date(day: 10, hour: 9), fromMe: false),
      // Chat 2: my last word, 12 days stale → awaiting their reply.
      message(chat: 2, sentAt: date(day: 8, hour: 11), fromMe: true),
      // Chat 3: fresh inbound (yesterday) → not hanging yet.
      message(chat: 3, sentAt: date(day: 19, hour: 12), fromMe: false)
    ]

    let stats = DeepReadAggregator.aggregate(messages, now: now, calendar: calendar)

    XCTAssertEqual(stats.totalMessages, 5)
    XCTAssertEqual(stats.ghosting.threadsSampled, 3)
    XCTAssertEqual(stats.ghosting.threadsAwaitingMyReply, 1)
    XCTAssertEqual(stats.ghosting.threadsAwaitingTheirReply, 1)
    XCTAssertEqual(stats.ghosting.medianReplyMinutes, 30)
    XCTAssertEqual(stats.ghosting.pctRepliesOver24h, 0)
  }

  func testAggregatorSplitsWorkAndOffHours() {
    let now = date(day: 20, hour: 12)
    let messages = [
      // Monday 10:00 + 14:00 → work bucket (formal style).
      message(chat: 1, sentAt: date(day: 8, hour: 10), fromMe: true, chars: 60, endsPeriod: true),
      message(chat: 1, sentAt: date(day: 8, hour: 14), fromMe: true, chars: 50, endsPeriod: true),
      // Monday 22:00 + Saturday 13:00 → off bucket (lowercase, emoji).
      message(chat: 1, sentAt: date(day: 8, hour: 22), fromMe: true, chars: 10, lowercaseStart: true, hasEmoji: true),
      message(chat: 1, sentAt: date(day: 13, hour: 13), fromMe: true, chars: 12, lowercaseStart: true),
      // Inbound never lands in the outbound style buckets.
      message(chat: 1, sentAt: date(day: 8, hour: 11), fromMe: false, chars: 400)
    ]

    let stats = DeepReadAggregator.aggregate(messages, now: now, calendar: calendar)

    XCTAssertEqual(stats.outboundOverall.messageCount, 4)
    XCTAssertEqual(stats.outboundWorkHours.messageCount, 2)
    XCTAssertEqual(stats.outboundOffHours.messageCount, 2)
    XCTAssertEqual(stats.outboundWorkHours.pctEndingPeriod, 100)
    XCTAssertEqual(stats.outboundOffHours.pctLowercaseStart, 100)
    XCTAssertEqual(stats.outboundOffHours.pctWithEmoji, 50)
  }

  func testAggregatorCapsMetadataSampleAndPseudonymizesContacts() {
    let base = date(day: 1, hour: 8)
    let messages = (0..<500).map { index in
      message(
        chat: index % 7,
        sentAt: base.addingTimeInterval(Double(index) * 600),
        fromMe: index % 2 == 0
      )
    }

    let stats = DeepReadAggregator.aggregate(messages, now: date(day: 20, hour: 12), calendar: calendar)

    XCTAssertEqual(stats.sample.count, DeepReadAggregator.sampleBudget)
    XCTAssertTrue(stats.sample.allSatisfy { $0.contact.hasPrefix("c") })
    let indices = stats.sample.compactMap { Int($0.contact.dropFirst()) }
    XCTAssertEqual(indices.count, stats.sample.count)
    XCTAssertLessThanOrEqual(indices.max() ?? 0, 7)
  }

  func testAggregatorIgnoresStaleDirectionFlipsAsReplies() {
    // 8 days between her message and my answer — a new conversation, not a
    // reply latency.
    let messages = [
      message(chat: 1, sentAt: date(day: 1, hour: 9), fromMe: false),
      message(chat: 1, sentAt: date(day: 9, hour: 10), fromMe: true)
    ]
    let stats = DeepReadAggregator.aggregate(messages, now: date(day: 10, hour: 9), calendar: calendar)
    XCTAssertNil(stats.ghosting.medianReplyMinutes)
  }

  // MARK: - Prompt

  func testPromptCarriesAggregatesSchemaAndPrivacyContract() {
    let prompt = DeepReadPrompt.make(stats: sampleStats())

    XCTAssertTrue(prompt.contains("Return strict JSON only"))
    XCTAssertTrue(prompt.contains("\"voice_signature\""))
    XCTAssertTrue(prompt.contains("\"severance\""))
    XCTAssertTrue(prompt.contains("not receiving message bodies"))
    // The stats payload rides along in snake_case.
    XCTAssertTrue(prompt.contains("\"outbound_work_hours\""))
    XCTAssertTrue(prompt.contains("\"pct_lowercase_start\""))
    XCTAssertTrue(prompt.contains("\"threads_awaiting_my_reply\" : 7"))
    // Contacts stay pseudonymous.
    XCTAssertTrue(prompt.contains("\"contact\" : \"c1\""))
  }

  // MARK: - Parse

  private let validResponse = """
    {
      "voice_signature": { "traits": ["lowercase loyalist", "burst texter"], "summary": "Fast, casual, allergic to periods." },
      "ghosting": { "headline": "7 threads left on read", "roast": "You reply fast — until you don't." },
      "vibe": { "archetype": "Warm Chaos", "evidence": "11% exclamation endings against a 12-minute median reply." },
      "severance": { "score": 64, "one_liner": "Two different texters share this phone." }
    }
    """

  func testParseAcceptsPlainJSON() throws {
    let insights = try DeepReadParser.parse(validResponse, modelID: "claude-sonnet-4-6")
    XCTAssertEqual(insights.voice.traits, ["lowercase loyalist", "burst texter"])
    XCTAssertEqual(insights.ghosting.headline, "7 threads left on read")
    XCTAssertEqual(insights.vibe.archetype, "Warm Chaos")
    XCTAssertEqual(insights.severance.score, 64)
    XCTAssertEqual(insights.modelID, "claude-sonnet-4-6")
  }

  func testParseToleratesFencesAndProseWrapping() throws {
    let fenced = "Here you go!\n```json\n\(validResponse)\n```\nHope that helps."
    let insights = try DeepReadParser.parse(fenced, modelID: "m")
    XCTAssertEqual(insights.severance.score, 64)
  }

  func testParseToleratesStringScoreAndSingleTrait() throws {
    let raw = """
      {
        "voice_signature": { "traits": "one-trait wonder", "summary": "" },
        "ghosting": { "headline": "h", "roast": "r" },
        "vibe": { "archetype": "a", "evidence": "e" },
        "severance": { "score": "41", "one_liner": "l" }
      }
      """
    let insights = try DeepReadParser.parse(raw, modelID: "m")
    XCTAssertEqual(insights.voice.traits, ["one-trait wonder"])
    XCTAssertEqual(insights.severance.score, 41)
  }

  func testParseClampsSeveranceScore() throws {
    let high = validResponse.replacingOccurrences(of: "\"score\": 64", with: "\"score\": 640")
    XCTAssertEqual(try DeepReadParser.parse(high, modelID: "m").severance.score, 100)

    let low = validResponse.replacingOccurrences(of: "\"score\": 64", with: "\"score\": -12")
    XCTAssertEqual(try DeepReadParser.parse(low, modelID: "m").severance.score, 0)
  }

  func testSeveranceClampIsPure() {
    XCTAssertEqual(DeepReadInsights.Severance.clamped(-5), 0)
    XCTAssertEqual(DeepReadInsights.Severance.clamped(0), 0)
    XCTAssertEqual(DeepReadInsights.Severance.clamped(62), 62)
    XCTAssertEqual(DeepReadInsights.Severance.clamped(100), 100)
    XCTAssertEqual(DeepReadInsights.Severance.clamped(150), 100)
  }

  func testParseRejectsNonFiniteScoreStringsInsteadOfCrashing() {
    // Swift's Double(String) happily parses "NaN"/"inf"; the original path
    // then trapped in Int(score.rounded()). Hostile model output must be a
    // parse failure, never a process crash.
    for hostile in ["NaN", "nan", "inf", "-Infinity"] {
      let raw = validResponse.replacingOccurrences(
        of: "\"score\": 64",
        with: "\"score\": \"\(hostile)\""
      )
      XCTAssertThrowsError(try DeepReadParser.parse(raw, modelID: "m"), "score \(hostile)") { error in
        XCTAssertEqual(error as? DeepReadError, .invalidResponse)
      }
    }
  }

  func testParseClampsAstronomicalScoresWithoutTrapping() throws {
    // Finite but far beyond Int.max — Int(Double) traps without the
    // clamp-before-convert. Both the string and raw-number paths.
    let hugeString = validResponse.replacingOccurrences(of: "\"score\": 64", with: "\"score\": \"1e300\"")
    XCTAssertEqual(try DeepReadParser.parse(hugeString, modelID: "m").severance.score, 100)

    let negativeString = validResponse.replacingOccurrences(of: "\"score\": 64", with: "\"score\": \"-1e300\"")
    XCTAssertEqual(try DeepReadParser.parse(negativeString, modelID: "m").severance.score, 0)

    let hugeNumber = validResponse.replacingOccurrences(of: "\"score\": 64", with: "\"score\": 1e300")
    XCTAssertEqual(try DeepReadParser.parse(hugeNumber, modelID: "m").severance.score, 100)
  }

  func testParseRejectsBooleanScore() {
    let raw = validResponse.replacingOccurrences(of: "\"score\": 64", with: "\"score\": true")
    XCTAssertThrowsError(try DeepReadParser.parse(raw, modelID: "m")) { error in
      XCTAssertEqual(error as? DeepReadError, .invalidResponse)
    }
  }

  func testParseRejectsMissingSectionsAndNonJSON() {
    let missing = """
      { "voice_signature": { "traits": ["t"], "summary": "s" }, "ghosting": { "headline": "h" } }
      """
    XCTAssertThrowsError(try DeepReadParser.parse(missing, modelID: "m")) { error in
      XCTAssertEqual(error as? DeepReadError, .invalidResponse)
    }
    XCTAssertThrowsError(try DeepReadParser.parse("I cannot do that.", modelID: "m")) { error in
      XCTAssertEqual(error as? DeepReadError, .invalidResponse)
    }
  }

  // MARK: - Cache

  func testInsightsCacheRoundTripsThroughDisk() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("deep-read-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("wrapped-deep-read.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let insights = try DeepReadParser.parse(validResponse, modelID: "m", generatedAt: Date(timeIntervalSince1970: 1_000_000))
    DeepReadController.storeCache(insights, to: url)

    XCTAssertEqual(DeepReadController.loadCache(from: url), insights)
  }

  func testCacheLoadToleratesMissingOrCorruptFile() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("deep-read-missing-\(UUID().uuidString).json")
    XCTAssertNil(DeepReadController.loadCache(from: missing))

    let corrupt = FileManager.default.temporaryDirectory
      .appendingPathComponent("deep-read-corrupt-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: corrupt) }
    try? Data("not json".utf8).write(to: corrupt)
    XCTAssertNil(DeepReadController.loadCache(from: corrupt))
  }

  // MARK: - Wrapped landing restore (PART A seam)

  func testExistingExperienceRestoresFromStableFilename() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wrapped-restore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    XCTAssertNil(WrappedGeneratorController.existingExperience(includeNames: true, outputDirectory: dir))

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let html = dir.appendingPathComponent("texting-wrapped.html")
    try Data("<html></html>".utf8).write(to: html)

    let experience = try XCTUnwrap(
      WrappedGeneratorController.existingExperience(includeNames: false, outputDirectory: dir)
    )
    XCTAssertEqual(experience.url, html)
    XCTAssertEqual(experience.readAccessDirectory, dir)
    XCTAssertFalse(experience.includeNames)
  }
}
