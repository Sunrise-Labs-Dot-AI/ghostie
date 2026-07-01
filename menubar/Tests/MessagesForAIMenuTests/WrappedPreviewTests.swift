import AppKit
import XCTest
@testable import MessagesForAIMenu

final class WrappedPreviewTests: XCTestCase {
  func testNavigationPolicyAllowsOnlyGeneratedLocalFilesInPreview() throws {
    let root = URL(fileURLWithPath: "/tmp/texting-wrapped")
    let policy = WrappedPreviewNavigationPolicy(readAccessDirectory: root)

    XCTAssertEqual(
      policy.decision(for: root.appendingPathComponent("texting-wrapped.html")),
      .allowInPreview
    )
    XCTAssertEqual(
      policy.decision(for: root.appendingPathComponent("nested/asset.html")),
      .allowInPreview
    )
    XCTAssertEqual(
      policy.decision(for: URL(fileURLWithPath: "/tmp/other.html")),
      .cancel
    )

    let external = try XCTUnwrap(URL(string: "https://messagesfor.ai"))
    XCTAssertEqual(policy.decision(for: external), .openExternally(external))
  }

  @MainActor
  func testGeneratorCompletesWithPreviewExperience() async throws {
    let binURL = URL(fileURLWithPath: "/tmp/wrapped-generator")
    let outputURL = URL(fileURLWithPath: "/tmp/texting-wrapped/texting-wrapped.html")
    let observedArgs = WrappedRunnerArgumentsBox()
    let controller = WrappedGeneratorController(
      binaryResolver: { binURL },
      jobRunner: { bin, outDir, includeNames in
        observedArgs.set((bin, outDir, includeNames))
        return outputURL
      }
    )

    controller.generate(includeNames: false)
    try await waitForDone(controller)

    guard case .done(let experience) = controller.state else {
      return XCTFail("Expected generated experience")
    }
    XCTAssertEqual(experience.url, outputURL)
    XCTAssertEqual(experience.readAccessDirectory.lastPathComponent, "texting-wrapped")
    XCTAssertFalse(experience.includeNames)
    let args = try XCTUnwrap(observedArgs.value)
    XCTAssertEqual(args.0, binURL)
    XCTAssertEqual(args.2, false)
  }

  func testWrappedPreviewAnalyticsAllowlistRejectsSensitiveProperties() throws {
    let safe = try AnalyticsClient.sanitize(event: .wrappedPreviewInteraction, properties: [
      "lab": "wrapped",
      "action": "loaded"
    ])
    XCTAssertEqual(safe["lab"] as? String, "wrapped")
    XCTAssertEqual(safe["action"] as? String, "loaded")

    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .wrappedPreviewInteraction, properties: [
      "lab": "wrapped",
      "action": "loaded",
      "file_path": "/tmp/texting-wrapped/texting-wrapped.html"
    ])) { error in
      XCTAssertEqual(error as? AnalyticsValidationError, .forbiddenProperty("file_path"))
    }

    XCTAssertThrowsError(try AnalyticsClient.sanitize(event: .wrappedPreviewInteraction, properties: [
      "lab": "wrapped",
      "action": "opened"
    ])) { error in
      XCTAssertEqual(error as? AnalyticsValidationError, .invalidValue(property: "action"))
    }
  }

  func testWrappedFilePayloadAcceptsValidPNGOperations() throws {
    let payload = try WrappedPreviewFilePayload(messageBody: [
      "action": "export_card",
      "requestId": "abc",
      "filename": "texting-wrapped-2026-03-people.png",
      "mimeType": "image/png",
      "base64": Data("png".utf8).base64EncodedString()
    ])

    XCTAssertEqual(payload.action, .exportCard)
    XCTAssertEqual(payload.requestID, "abc")
    XCTAssertEqual(payload.filename, "texting-wrapped-2026-03-people.png")
    XCTAssertEqual(payload.mimeType, "image/png")
    XCTAssertEqual(payload.data, Data("png".utf8))
  }

  func testWrappedFilePayloadAcceptsNativePNGOperations() throws {
    let payload = try WrappedPreviewFilePayload(
      action: .exportCard,
      filename: "texting-wrapped-2026-03-people.png",
      data: Data("png".utf8)
    )

    XCTAssertEqual(payload.action, .exportCard)
    XCTAssertEqual(payload.filename, "texting-wrapped-2026-03-people.png")
    XCTAssertEqual(payload.mimeType, "image/png")
    XCTAssertEqual(payload.data, Data("png".utf8))
  }

  func testWrappedSnapshotMetadataDecodesSafePayload() throws {
    let metadata = try WrappedPreviewSnapshotMetadata(messageBody: [
      "index": NSNumber(value: 4),
      "key": "groups",
      "filename": "texting-wrapped-2026-05-groups.png",
      "rect": [
        "x": NSNumber(value: 120),
        "y": NSNumber(value: 42),
        "width": NSNumber(value: 402),
        "height": NSNumber(value: 874)
      ]
    ])

    XCTAssertEqual(metadata.index, 4)
    XCTAssertEqual(metadata.key, "groups")
    XCTAssertEqual(metadata.filename, "texting-wrapped-2026-05-groups.png")
    XCTAssertEqual(metadata.rect.cgRect, CGRect(x: 120, y: 42, width: 402, height: 874))
  }

  func testWrappedFilePayloadRejectsUnsafeInputs() throws {
    let validBase: [String: Any] = [
      "action": "export_card",
      "requestId": "abc",
      "filename": "texting-wrapped-2026-03-people.png",
      "mimeType": "image/png",
      "base64": Data("png".utf8).base64EncodedString()
    ]

    XCTAssertThrowsError(try WrappedPreviewFilePayload(messageBody: validBase.merging([
      "filename": "../texting-wrapped.png"
    ]) { _, new in new })) { error in
      XCTAssertEqual(error as? WrappedPreviewFileError, .invalidFilename)
    }

    XCTAssertThrowsError(try WrappedPreviewFilePayload(messageBody: validBase.merging([
      "mimeType": "text/html"
    ]) { _, new in new })) { error in
      XCTAssertEqual(error as? WrappedPreviewFileError, .invalidMimeType)
    }

    XCTAssertThrowsError(try WrappedPreviewFilePayload(messageBody: validBase.merging([
      "base64": "not base64"
    ]) { _, new in new })) { error in
      XCTAssertEqual(error as? WrappedPreviewFileError, .invalidBase64)
    }
  }

  @MainActor
  func testWrappedPreviewExportWritesUnderExportDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("wrapped-preview-export-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let exportDir = root.appendingPathComponent("exports", isDirectory: true)
    let controller = WrappedPreviewExportController(
      exportDirectory: exportDir,
      temporaryDirectory: root.appendingPathComponent("share", isDirectory: true),
      sharePresenter: { _, _ in XCTFail("Export should not invoke share presenter") }
    )
    let payload = try WrappedPreviewFilePayload(messageBody: [
      "action": "export_card",
      "filename": "texting-wrapped-2026-01-cover.png",
      "mimeType": "image/png",
      "base64": Data("png".utf8).base64EncodedString()
    ])

    let url = try controller.handle(payload, presentingFrom: NSView())

    XCTAssertEqual(url.deletingLastPathComponent(), exportDir)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try Data(contentsOf: url), Data("png".utf8))
  }

  @MainActor
  func testWrappedPreviewShareWritesTempAndInvokesPresenter() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("wrapped-preview-share-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var sharedURL: URL?
    let controller = WrappedPreviewExportController(
      exportDirectory: root.appendingPathComponent("exports", isDirectory: true),
      temporaryDirectory: root.appendingPathComponent("share", isDirectory: true),
      sharePresenter: { url, _ in sharedURL = url }
    )
    let payload = try WrappedPreviewFilePayload(messageBody: [
      "action": "share_all",
      "filename": "texting-wrapped-2026-all-cards.png",
      "mimeType": "image/png",
      "base64": Data("png".utf8).base64EncodedString()
    ])

    let url = try controller.handle(payload, presentingFrom: NSView())

    XCTAssertEqual(sharedURL, url)
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "share")
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testWrappedToolUsesFocusedPreviewOnlyForDoneState() {
    let experience = WrappedGeneratedExperience(
      url: URL(fileURLWithPath: "/tmp/texting-wrapped.html"),
      readAccessDirectory: URL(fileURLWithPath: "/tmp"),
      includeNames: true
    )
    XCTAssertTrue(WrappedToolView.usesFocusedPreview(for: .done(experience)))
    XCTAssertFalse(WrappedToolView.usesFocusedPreview(for: .idle))
    XCTAssertFalse(WrappedToolView.usesFocusedPreview(for: .generating))
  }

  func testWrappedToolUsesDedicatedTopRowForPreviewControls() {
    let experience = WrappedGeneratedExperience(
      url: URL(fileURLWithPath: "/tmp/texting-wrapped.html"),
      readAccessDirectory: URL(fileURLWithPath: "/tmp"),
      includeNames: true
    )

    XCTAssertEqual(WrappedToolView.previewToolbarPlacement(for: .done(experience)), .dedicatedTopRow)
    XCTAssertEqual(WrappedToolView.previewToolbarPlacement(for: .idle), .hidden)
  }

  func testWrappedToolPreviewToolbarExposesNativeShareAndExportActions() {
    XCTAssertEqual(WrappedToolView.previewToolbarActions, [
      .exit,
      .shareCard,
      .exportPNG,
      .revealInFinder,
      .openInBrowser
    ])
  }

  func testWrappedPreviewFocusPolicyRetriesThenStops() {
    XCTAssertTrue(WrappedPreviewFocusPolicy.shouldRetry(afterAttempt: 0))
    XCTAssertTrue(WrappedPreviewFocusPolicy.shouldRetry(afterAttempt: WrappedPreviewFocusPolicy.maxAttempts - 1))
    XCTAssertFalse(WrappedPreviewFocusPolicy.shouldRetry(afterAttempt: WrappedPreviewFocusPolicy.maxAttempts))
  }

  @MainActor
  private func waitForDone(_ controller: WrappedGeneratorController) async throws {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      if case .done = controller.state { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for Wrapped generation")
  }
}

private final class WrappedRunnerArgumentsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: (URL, URL, Bool)?

  var value: (URL, URL, Bool)? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ value: (URL, URL, Bool)) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}
