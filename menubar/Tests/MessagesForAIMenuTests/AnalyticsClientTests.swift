import XCTest
@testable import MessagesForAIMenu

final class AnalyticsClientTests: XCTestCase {
  func testDisallowedKeysAreRejected() throws {
    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .draftStaged, properties: [
      "message_body": "hello",
      "transport": "imessage",
      "source": "ui"
    ])) { error in
      XCTAssertEqual(error as? AnalyticsValidationError, .forbiddenProperty("message_body"))
    }
  }

  func testUnknownEventAndPropertyAreRejected() throws {
    XCTAssertThrowsError(try AnalyticsClient.payload(
      eventName: "raw_prompt_sent",
      properties: [:],
      distinctID: "install-id"
    )) { error in
      XCTAssertEqual(error as? AnalyticsValidationError, .eventNotAllowed("raw_prompt_sent"))
    }

    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .draftSent, properties: [
      "transport": "imessage",
      "result": "success",
      "duration_ms": 250
    ])) { error in
      XCTAssertEqual(
        error as? AnalyticsValidationError,
        .propertyNotAllowed(event: AnalyticsEvent.draftSent.rawValue, property: "duration_ms")
      )
    }
  }

  func testSensitiveStringValuesAreRejectedEvenOnAllowedKeys() throws {
    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .labScanFailed, properties: [
      "lab": "eq",
      "error_category": "james@example.com"
    ])) { error in
      XCTAssertEqual(error as? AnalyticsValidationError, .invalidValue(property: "error_category"))
    }
  }

  func testAllowedPayloadContainsOnlySafeDefaultProperties() throws {
    let payload = try AnalyticsClient.payload(
      eventName: AnalyticsEvent.draftStaged.rawValue,
      properties: [
        "transport": "imessage",
        "source": "ui"
      ],
      distinctID: "installation-123"
    )

    XCTAssertEqual(payload["event"] as? String, AnalyticsEvent.draftStaged.rawValue)
    let properties = try XCTUnwrap(payload["properties"] as? [String: Any])
    XCTAssertEqual(properties["transport"] as? String, "imessage")
    XCTAssertEqual(properties["source"] as? String, "ui")
    XCTAssertEqual(properties["distinct_id"] as? String, "installation-123")
    XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
    XCTAssertNotNil(properties["$insert_id"] as? String)

    let forbiddenFragments = [
      "message_body", "draft_text", "prompt", "response_text", "recipient",
      "contact_name", "phone", "email", "apple_id", "whatsapp_id", "chat_id",
      "message_id", "thread_id", "handle", "raw_identifier", "api_key",
      "access_token", "file_path", "calendar_event_title"
    ]
    for key in properties.keys {
      for fragment in forbiddenFragments {
        XCTAssertFalse(key.localizedCaseInsensitiveContains(fragment), "\(key) should not contain \(fragment)")
      }
    }
  }

  func testTelemetryDisabledMeansNoOutboundCapture() throws {
    let transport = RecordingAnalyticsTransport()
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: false,
      rootDirectory: tempDir(),
      transport: transport
    )

    client.safeCapture(.appLaunched)
    waitBriefly()

    XCTAssertTrue(transport.sentBatches.isEmpty)
  }

  func testTelemetryEnabledSendsAllowlistedEvent() throws {
    let transport = RecordingAnalyticsTransport()
    let sent = expectation(description: "sent")
    transport.onSend = { sent.fulfill() }
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: true,
      rootDirectory: tempDir(),
      transport: transport
    )

    client.safeCapture(.featureViewed, properties: [.feature: .string(AnalyticsFeature.settings.rawValue)])

    wait(for: [sent], timeout: 1)
    XCTAssertEqual(transport.sentBatches.count, 1)
    let event = try XCTUnwrap(transport.sentBatches.first?.first)
    XCTAssertEqual(event["event"] as? String, AnalyticsEvent.featureViewed.rawValue)
  }

  func testEnvironmentKillSwitchBlocksCapture() throws {
    let transport = RecordingAnalyticsTransport()
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: true,
      rootDirectory: tempDir(),
      transport: transport,
      environmentProvider: { ["MESSAGES_FOR_AI_ANALYTICS_DISABLED": "1"] }
    )

    client.safeCapture(.appLaunched)
    waitBriefly()

    XCTAssertTrue(transport.sentBatches.isEmpty)
  }

  func testSentinelKillSwitchBlocksCapture() throws {
    let transport = RecordingAnalyticsTransport()
    let root = tempDir()
    try Data().write(to: root.appendingPathComponent("analytics.disabled"))
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: true,
      rootDirectory: root,
      transport: transport
    )

    client.safeCapture(.appLaunched)
    waitBriefly()

    XCTAssertTrue(transport.sentBatches.isEmpty)
  }

  func testDiagnosticsExportUsesSplitBooleanProperties() throws {
    let sanitized = try AnalyticsClient.sanitize(event: .diagnosticsExportCreated, properties: [
      "included_crash_reports": true,
      "included_local_events": true,
      "included_daemon_logs": false
    ])

    XCTAssertEqual(sanitized["included_crash_reports"] as? Bool, true)
    XCTAssertEqual(sanitized["included_local_events"] as? Bool, true)
    XCTAssertEqual(sanitized["included_daemon_logs"] as? Bool, false)
    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .diagnosticsExportCreated, properties: [
      "included_logs": true
    ]))
  }

  func testFounderPulseEventsAcceptProductionEmitterShapes() throws {
    let cases: [(AnalyticsEvent, [String: Any])] = [
      (.appLaunched, [:]),
      (.appVersionSeen, [:]),
      (.onboardingCompleted, [
        "experience_mode": AppExperienceMode.textingWrappedOnly.rawValue
      ]),
      (.transportEnabled, [
        "transport": AnalyticsTransportName.imessage.rawValue
      ]),
      (.setupWalkthroughCompleted, [:]),
      (.setupWalkthroughSkipped, [:]),
      (.settingsOpened, [:]),
      (.telemetryEnabled, [:]),
      (.featureViewed, [
        "feature": AnalyticsFeature.messages.rawValue
      ]),
      (.featureViewed, [
        "feature": AnalyticsFeature.dontGhost.rawValue
      ]),
      (.featureViewed, [
        "feature": AnalyticsFeature.wrapped.rawValue
      ]),
      (.featureViewed, [
        "feature": AnalyticsFeature.eq.rawValue
      ]),
      (.featureViewed, [
        "feature": AnalyticsFeature.birthdayTexts.rawValue
      ]),
      (.fdaGranted, [:]),
      (.mcpVerified, [
        "transport": AnalyticsTransportName.imessage.rawValue
      ]),
      (.firstAha, [
        "feature": AnalyticsFeature.wrapped.rawValue,
        "time_to_aha_bucket": "lt_1h"
      ]),
      (.draftDiscarded, [
        "transport": AnalyticsTransportName.imessage.rawValue,
        "source": AnalyticsDraftSource.assistant.rawValue
      ]),
      (.draftStaged, [
        "transport": AnalyticsTransportName.imessage.rawValue,
        "source": AnalyticsDraftSource.assistant.rawValue
      ]),
      (.draftSent, [
        "transport": AnalyticsTransportName.whatsapp.rawValue,
        "result": AnalyticsResult.success.rawValue
      ]),
      (.draftSent, [
        "transport": AnalyticsTransportName.imessage.rawValue,
        "result": AnalyticsResult.failure.rawValue,
        "source": AnalyticsDraftSource.firstPartyDirect.rawValue,
        "edit_magnitude": AnalyticsEditMagnitude.light.rawValue
      ]),
      (.scheduledMessageCreated, [
        "cadence": AnalyticsCadence.oneTime.rawValue,
        "scheduled_delay_bucket": "1h_24h"
      ]),
      (.labScanStarted, [
        "lab": AnalyticsLab.wrapped.rawValue
      ]),
      (.labScanCompleted, [
        "lab": AnalyticsLab.textingAnalytics.rawValue,
        "result_count_bucket": "6_20",
        "duration_bucket": "5s_30s"
      ]),
      (.labScanFailed, [
        "lab": AnalyticsLab.eq.rawValue,
        "error_category": AnalyticsErrorCategory.timeout.rawValue
      ]),
      (.wrappedPreviewInteraction, [
        "lab": AnalyticsLab.wrapped.rawValue,
        "action": WrappedPreviewTelemetryAction.share.rawValue
      ]),
      (.diagnosticsExportCreated, [
        "included_crash_reports": true,
        "included_local_events": true,
        "included_daemon_logs": false
      ])
    ]

    for (event, properties) in cases {
      XCTAssertNoThrow(
        try AnalyticsClient.sanitize(event: event, properties: properties),
        "\(event.rawValue) should accept \(properties)"
      )
    }
  }

  func testAhaFeatureKeysStayStableAndRejectAliases() throws {
    XCTAssertEqual(AnalyticsFeature.dontGhost.rawValue, "dont_ghost")
    XCTAssertEqual(AnalyticsFeature.wrapped.rawValue, "wrapped")
    XCTAssertEqual(AnalyticsFeature.eq.rawValue, "eq")
    XCTAssertEqual(AnalyticsFeature.birthdayTexts.rawValue, "birthday_texts")
    XCTAssertTrue(AnalyticsFeature.dontGhost.isAha)
    XCTAssertTrue(AnalyticsFeature.wrapped.isAha)
    XCTAssertTrue(AnalyticsFeature.eq.isAha)
    XCTAssertTrue(AnalyticsFeature.birthdayTexts.isAha)
    XCTAssertFalse(AnalyticsFeature.messages.isAha)

    XCTAssertEqual(ConsoleView.analyticsFeature(for: .tool("dontGhost")), .dontGhost)
    XCTAssertEqual(ConsoleView.analyticsFeature(for: .tool("wrapped")), .wrapped)
    XCTAssertEqual(ConsoleView.analyticsFeature(for: .tool("eq")), .eq)
    XCTAssertEqual(ConsoleView.analyticsFeature(for: .tool("birthdays")), .birthdayTexts)

    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .featureViewed, properties: [
      "feature": "birthdays"
    ]))
    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .firstAha, properties: [
      "feature": AnalyticsFeature.wrapped.rawValue,
      "time_to_aha_bucket": "12 minutes"
    ]))
    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .draftSent, properties: [
      "transport": AnalyticsTransportName.imessage.rawValue,
      "result": AnalyticsResult.success.rawValue,
      "tip_amount": "8.67"
    ]))
  }

  func testTimeToAhaAndEditMagnitudeAreCoarseBuckets() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertEqual(AnalyticsClient.timeToAhaBucket(from: start, to: start.addingTimeInterval(60)), "lt_1h")
    XCTAssertEqual(AnalyticsClient.timeToAhaBucket(from: start, to: start.addingTimeInterval(8_000)), "1h_24h")
    XCTAssertEqual(AnalyticsClient.timeToAhaBucket(from: start, to: start.addingTimeInterval(200_000)), "1d_7d")
    XCTAssertEqual(AnalyticsClient.timeToAhaBucket(from: start, to: start.addingTimeInterval(800_000)), "gt_7d")

    XCTAssertEqual(AnalyticsClient.editMagnitude(originalLength: 80, currentLength: 80, unchanged: true), .none)
    XCTAssertEqual(AnalyticsClient.editMagnitude(originalLength: 80, currentLength: 90, unchanged: false), .light)
    XCTAssertEqual(AnalyticsClient.editMagnitude(originalLength: 80, currentLength: 200, unchanged: false), .heavy)
  }

  func testActivationCheckpointsFireOnceAndSkipWhenDisabled() throws {
    let transport = RecordingAnalyticsTransport()
    let root = tempDir()
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: true,
      rootDirectory: root,
      transport: transport
    )

    client.observeFDAGranted(true)
    client.observeFDAGranted(true)
    client.observeMCPVerified(.imessage)
    client.observeMCPVerified(.imessage)
    client.trackFeatureViewed(.wrapped)
    client.trackFeatureViewed(.eq)
    waitBriefly()

    let events = transport.sentBatches.flatMap { $0 }.compactMap { $0["event"] as? String }
    XCTAssertEqual(events.filter { $0 == AnalyticsEvent.fdaGranted.rawValue }.count, 1)
    XCTAssertEqual(events.filter { $0 == AnalyticsEvent.mcpVerified.rawValue }.count, 1)
    XCTAssertEqual(events.filter { $0 == AnalyticsEvent.firstAha.rawValue }.count, 1)
    XCTAssertEqual(events.filter { $0 == AnalyticsEvent.featureViewed.rawValue }.count, 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("analytics-fda-granted").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("analytics-first-aha").path))
  }

  func testStagedDraftFingerprintNeverLeavesTheDevice() throws {
    let root = tempDir()
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: true,
      rootDirectory: root,
      transport: RecordingAnalyticsTransport()
    )
    let draftID = "11111111-1111-1111-1111-111111111111"
    client.rememberStagedDraft(id: draftID, body: "hello there")
    XCTAssertEqual(
      client.consumeEditMagnitude(id: draftID, currentBody: "hello there"),
      AnalyticsEditMagnitude.none
    )
    client.rememberStagedDraft(id: draftID, body: "hello there")
    XCTAssertEqual(
      client.consumeEditMagnitude(id: draftID, currentBody: "hello there, friend"),
      .light
    )
    client.rememberStagedDraft(id: draftID, body: "short")
    XCTAssertEqual(
      client.consumeEditMagnitude(id: draftID, currentBody: String(repeating: "x", count: 80)),
      .heavy
    )
    XCTAssertNil(client.consumeEditMagnitude(id: draftID, currentBody: "gone"))
  }

  func testTelemetryDisabledRemainsAllowlistedButNotReportPrimary() throws {
    XCTAssertNoThrow(try AnalyticsClient.sanitize(event: .telemetryDisabled, properties: [:]))
  }

  func testCorruptQueueIsQuarantinedBeforeNewCapture() throws {
    let transport = RecordingAnalyticsTransport()
    let root = tempDir()
    let queueURL = root.appendingPathComponent("analytics-queue.json")
    try Data("{".utf8).write(to: queueURL)
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: true,
      rootDirectory: root,
      transport: transport
    )

    client.safeCapture(.appLaunched)
    waitBriefly()

    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    XCTAssertTrue(files.contains { file in
      file.lastPathComponent.hasPrefix("analytics-queue.")
        && file.lastPathComponent.hasSuffix(".corrupt.json")
    })
  }

  func testQueueKeepsNewEventsWhenInFlightBatchWasEvictedByCap() throws {
    let root = tempDir()
    let initialQueue = try (0..<50).map { index in
      try AnalyticsClient.payload(
        eventName: AnalyticsEvent.appLaunched.rawValue,
        properties: [:],
        distinctID: "installation-\(index)"
      )
    }
    try writeQueue(initialQueue, root: root)

    let transport = BlockingAnalyticsTransport()
    let firstBatchSent = expectation(description: "first batch sent")
    let secondBatchSent = expectation(description: "second batch sent")
    transport.onSend = { index, batch in
      if index == 1 {
        XCTAssertEqual(batch.count, 50)
        firstBatchSent.fulfill()
      } else if index == 2 {
        secondBatchSent.fulfill()
      }
    }
    let client = AnalyticsClient(
      config: AnalyticsClientConfig(projectToken: "phc_test", host: URL(string: "https://us.i.posthog.com")!),
      userEnabled: false,
      rootDirectory: root,
      transport: transport
    )

    client.setUserEnabled(true)
    wait(for: [firstBatchSent], timeout: 1)
    for _ in 0..<10 {
      client.safeCapture(.settingsOpened)
    }
    waitBriefly()
    transport.completeNext(success: true)
    wait(for: [secondBatchSent], timeout: 1)

    let secondBatch = try XCTUnwrap(transport.sentBatches.dropFirst().first)
    XCTAssertEqual(secondBatch.count, 10)
    XCTAssertEqual(secondBatch.compactMap { $0["event"] as? String }, Array(repeating: AnalyticsEvent.settingsOpened.rawValue, count: 10))
    transport.completeNext(success: true)
  }

  private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("messages-ai-analytics-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeQueue(_ items: [[String: Any]], root: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("analytics-queue.json"), options: .atomic)
  }

  private func waitBriefly() {
    let exp = expectation(description: "wait")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
    wait(for: [exp], timeout: 1)
  }
}

private final class RecordingAnalyticsTransport: AnalyticsTransport {
  private let lock = NSLock()
  private var storedBatches: [[[String: Any]]] = []
  var onSend: (() -> Void)?

  var sentBatches: [[[String: Any]]] {
    lock.lock()
    defer { lock.unlock() }
    return storedBatches
  }

  func send(batch: [[String: Any]], config: AnalyticsClientConfig, completion: @escaping (Bool) -> Void) {
    lock.lock()
    storedBatches.append(batch)
    let callback = onSend
    lock.unlock()
    callback?()
    completion(true)
  }
}

private final class BlockingAnalyticsTransport: AnalyticsTransport {
  private let lock = NSLock()
  private var storedBatches: [[[String: Any]]] = []
  private var completions: [((Bool) -> Void)] = []
  var onSend: ((Int, [[String: Any]]) -> Void)?

  var sentBatches: [[[String: Any]]] {
    lock.lock()
    defer { lock.unlock() }
    return storedBatches
  }

  func send(batch: [[String: Any]], config: AnalyticsClientConfig, completion: @escaping (Bool) -> Void) {
    lock.lock()
    storedBatches.append(batch)
    completions.append(completion)
    let index = storedBatches.count
    let callback = onSend
    lock.unlock()
    callback?(index, batch)
  }

  func completeNext(success: Bool) {
    lock.lock()
    let completion = completions.isEmpty ? nil : completions.removeFirst()
    lock.unlock()
    completion?(success)
  }
}
