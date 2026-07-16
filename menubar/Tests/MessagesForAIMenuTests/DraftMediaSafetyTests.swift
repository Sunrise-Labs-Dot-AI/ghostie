import Foundation
import Darwin
import XCTest
@testable import MessagesForAIMenu

final class DraftMediaSafetyTests: XCTestCase {
  private var modelHome: URL!

  override func setUp() {
    super.setUp()
    modelHome = temporaryHome()
    setenv("MESSAGES_FOR_AI_HOME", modelHome.path, 1)
    setenv("MFA_TEST_APPROVAL_SECRET", "unit-test-fixed-secret", 1)
    try? FileManager.default.createDirectory(
      at: modelHome.appendingPathComponent("Library/Messages", isDirectory: true),
      withIntermediateDirectories: true
    )
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
  }

  override func tearDown() {
    unsetenv("MESSAGES_FOR_AI_HOME")
    try? FileManager.default.removeItem(at: modelHome)
    super.tearDown()
  }

  func testDeliveryPayloadDigestMatchesSharedUnicodeVector() {
    let attachments = [
      DraftAttachment(
        path: "/tmp/.whatsapp-mcp/draft-attachments/draft-🌅-42/photo one.jpg",
        filename: "photo one.jpg",
        mime_type: "image/jpeg",
        byte_count: 12_345,
        asset_id: "asset-α",
        sha256: String(repeating: "a", count: 64)
      ),
      DraftAttachment(
        path: "/tmp/.whatsapp-mcp/draft-attachments/draft-🌅-42/résumé.pdf",
        filename: nil,
        mime_type: "application/pdf",
        byte_count: nil,
        asset_id: "asset-2",
        sha256: String(repeating: "b", count: 64)
      )
    ]
    let draft = makeDraft(
      id: "draft-🌅-42",
      platform: .whatsapp,
      toHandle: "12025550123@s.whatsapp.net",
      body: "Photo 👻 | café",
      quotedMessageID: "quote-π",
      scheduledSendAt: "2026-07-16T18:30:00Z",
      attachments: attachments
    )

    // Shared with the TypeScript transport tests. This independently fixes the
    // UTF-8 byte lengths, delimiter handling, nil byte-count sentinel, order,
    // and lowercase SHA-256 output.
    XCTAssertEqual(
      draft.deliveryPayloadDigest,
      "9c4c23978c28f9cbcf0310ff3711aec1ef6fb3925eca797f556d06121922207f"
    )
  }

  func testScheduledApprovalRejectsEveryDeliverySemanticMutation() throws {
    let first = managedAttachment(
      id: "draft-1", assetID: "asset-1", filename: "one.png",
      mimeType: "image/png", byteCount: 101, sha256: String(repeating: "1", count: 64)
    )
    let second = managedAttachment(
      id: "draft-1", assetID: "asset-2", filename: "two.jpg",
      mimeType: "image/jpeg", byteCount: 202, sha256: String(repeating: "2", count: 64)
    )
    let unsigned = makeDraft(attachments: [first, second])
    let tag = try XCTUnwrap(ApprovalAuthenticator.tag(for: unsigned.scheduleApprovalCanonicalMessage))
    let approved = makeDraft(attachments: [first, second], tag: tag)
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
    XCTAssertTrue(approved.isScheduleAuthenticallyApproved)

    let firstAssetChanged = DraftAttachment(
      path: first.path, filename: first.filename, mime_type: first.mime_type,
      byte_count: first.byte_count, asset_id: "asset-changed", sha256: first.sha256
    )
    let firstPathChanged = DraftAttachment(
      path: "/tmp/.whatsapp-mcp/draft-attachments/draft-1/changed.png",
      filename: first.filename, mime_type: first.mime_type,
      byte_count: first.byte_count, asset_id: first.asset_id, sha256: first.sha256
    )
    let firstFilenameChanged = DraftAttachment(
      path: first.path, filename: "changed.png", mime_type: first.mime_type,
      byte_count: first.byte_count, asset_id: first.asset_id, sha256: first.sha256
    )
    let firstMIMEChanged = DraftAttachment(
      path: first.path, filename: first.filename, mime_type: "image/jpeg",
      byte_count: first.byte_count, asset_id: first.asset_id, sha256: first.sha256
    )
    let firstByteCountChanged = DraftAttachment(
      path: first.path, filename: first.filename, mime_type: first.mime_type,
      byte_count: 102, asset_id: first.asset_id, sha256: first.sha256
    )
    let firstHashChanged = DraftAttachment(
      path: first.path, filename: first.filename, mime_type: first.mime_type,
      byte_count: first.byte_count, asset_id: first.asset_id,
      sha256: String(repeating: "f", count: 64)
    )

    let mutations: [(String, Draft)] = [
      ("id", makeDraft(id: "draft-2", attachments: [first, second], tag: tag)),
      ("platform", makeDraft(platform: .imessage, attachments: [first, second], tag: tag)),
      ("recipient", makeDraft(toHandle: "+15550000000", attachments: [first, second], tag: tag)),
      ("body", makeDraft(body: "changed", attachments: [first, second], tag: tag)),
      ("quote", makeDraft(quotedMessageID: "quote-2", attachments: [first, second], tag: tag)),
      ("schedule", makeDraft(scheduledSendAt: "2026-07-17T18:30:00Z", attachments: [first, second], tag: tag)),
      ("attachment count", makeDraft(attachments: [first], tag: tag)),
      ("attachment order", makeDraft(attachments: [second, first], tag: tag)),
      ("asset id", makeDraft(attachments: [firstAssetChanged, second], tag: tag)),
      ("asset path", makeDraft(attachments: [firstPathChanged, second], tag: tag)),
      ("filename", makeDraft(attachments: [firstFilenameChanged, second], tag: tag)),
      ("MIME type", makeDraft(attachments: [firstMIMEChanged, second], tag: tag)),
      ("byte count", makeDraft(attachments: [firstByteCountChanged, second], tag: tag)),
      ("SHA-256", makeDraft(attachments: [firstHashChanged, second], tag: tag))
    ]

    for (field, mutated) in mutations {
      XCTAssertNotEqual(mutated.deliveryPayloadDigest, approved.deliveryPayloadDigest, field)
      XCTAssertFalse(mutated.isScheduleAuthenticallyApproved, field)
    }
  }

  func testLegacyTextOnlyDraftIsSafeButLegacyOrMalformedMediaFailsClosed() throws {
    let textOnlyJSON = """
    {
      "id": "legacy-text",
      "to_handle": "+15551234567",
      "to_handle_name": null,
      "body": "hello",
      "in_reply_to_thread_id": null,
      "staged_at": "2026-07-16T00:00:00Z",
      "sent_at": null,
      "send_service": "iMessage",
      "source": null,
      "context_messages": null,
      "context_diagnostic": null
    }
    """
    let textOnly = try JSONDecoder().decode(Draft.self, from: Data(textOnlyJSON.utf8))
    XCTAssertNil(textOnly.attachments)
    XCTAssertNil(textOnly.delivery_progress)
    XCTAssertNil(textOnly.attachmentReviewIssue)

    let legacyMediaJSON = """
    {
      "id": "legacy-media",
      "to_handle": "+15551234567",
      "to_handle_name": null,
      "body": "photo",
      "attachments": [{
        "path": "/tmp/photo.png",
        "filename": "photo.png",
        "mime_type": "image/png",
        "byte_count": 12
      }],
      "delivery_progress": {
        "completed_attachment_count": 1,
        "body_sent": false,
        "ambiguous_part": "attachment:0+body"
      },
      "in_reply_to_thread_id": null,
      "staged_at": "2026-07-16T00:00:00Z",
      "sent_at": null,
      "send_service": "iMessage",
      "source": null,
      "context_messages": null,
      "context_diagnostic": null
    }
    """
    let legacyMedia = try JSONDecoder().decode(Draft.self, from: Data(legacyMediaJSON.utf8))
    XCTAssertEqual(
      legacyMedia.delivery_progress,
      DraftDeliveryProgress(
        completed_attachment_count: 1,
        body_sent: false,
        ambiguous_part: "attachment:0+body"
      )
    )
    XCTAssertNotNil(legacyMedia.attachmentReviewIssue)

    let safe = managedAttachment(id: "draft-1")
    XCTAssertNil(makeDraft(attachments: [safe]).attachmentReviewIssue)
    let malformed = [
      DraftAttachment(
        path: safe.path, filename: safe.filename, mime_type: safe.mime_type,
        byte_count: safe.byte_count, asset_id: nil, sha256: safe.sha256
      ),
      DraftAttachment(
        path: safe.path, filename: safe.filename, mime_type: safe.mime_type,
        byte_count: safe.byte_count, asset_id: safe.asset_id, sha256: String(repeating: "A", count: 64)
      ),
      DraftAttachment(
        path: safe.path, filename: safe.filename, mime_type: safe.mime_type,
        byte_count: nil, asset_id: safe.asset_id, sha256: safe.sha256
      ),
      DraftAttachment(
        path: safe.path, filename: safe.filename, mime_type: safe.mime_type,
        byte_count: -1, asset_id: safe.asset_id, sha256: safe.sha256
      ),
      DraftAttachment(
        path: "/tmp/unmanaged.png", filename: safe.filename, mime_type: safe.mime_type,
        byte_count: safe.byte_count, asset_id: safe.asset_id, sha256: safe.sha256
      ),
      DraftAttachment(
        path: "/tmp/.whatsapp-mcp/draft-attachments/draft-1/../other.png",
        filename: safe.filename, mime_type: safe.mime_type,
        byte_count: safe.byte_count, asset_id: safe.asset_id, sha256: safe.sha256
      )
    ]
    for attachment in malformed {
      XCTAssertNotNil(makeDraft(attachments: [attachment]).attachmentReviewIssue)
    }
  }

  func testTraversalShapedDraftIdentifierCannotReachSendStorage() async {
    let draft = makeDraft(id: "../../Library/Messages/forged", platform: .imessage, attachments: nil)
    let result = await DraftSender.send(draft: draft)
    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.error, "This draft has an invalid identifier and cannot be sent.")
  }

  @MainActor
  func testStoreRewritesPreserveManifestAndProgressAndRemintApproval() throws {
    let home = temporaryHome()
    let id = "rewrite-draft"
    let path = home
      .appendingPathComponent(".messages-mcp/draft-attachments/\(id)/photo.png")
      .path
    let attachment = DraftAttachment(
      path: path,
      filename: "photo.png",
      mime_type: "image/png",
      byte_count: 10,
      asset_id: "asset-1",
      sha256: String(repeating: "a", count: 64)
    )
    let progress = DraftDeliveryProgress(
      completed_attachment_count: 0,
      body_sent: false,
      ambiguous_part: "attachment:0"
    )
    let unsigned = makeDraft(
      id: id,
      platform: .imessage,
      body: "caption",
      attachments: [attachment],
      progress: progress
    )
    let originalTag = try XCTUnwrap(ApprovalAuthenticator.tag(for: unsigned.scheduleApprovalCanonicalMessage))
    let stored = makeDraft(
      id: id,
      platform: .imessage,
      body: "caption",
      attachments: [attachment],
      progress: progress,
      tag: originalTag
    )
    try writeDraft(stored, home: home)
    let store = DraftStore(homeOverride: home)

    // Simulate DraftSender advancing the journal directly on disk before the
    // directory watcher publishes that change to DraftStore.drafts.
    let newestProgress = DraftDeliveryProgress(
      completed_attachment_count: 1,
      body_sent: false,
      ambiguous_part: "body"
    )
    let newestOnDisk = makeDraft(
      id: id,
      platform: .imessage,
      body: "caption",
      attachments: [attachment],
      progress: newestProgress,
      tag: originalTag
    )
    try writeDraft(newestOnDisk, home: home)

    let bodyUpdated = try store.updateBody(id: id, body: "   ")
    XCTAssertEqual(bodyUpdated.body, "", "an attachment-only draft may remove its caption")
    XCTAssertEqual(bodyUpdated.attachments, [attachment])
    XCTAssertEqual(bodyUpdated.delivery_progress, newestProgress)
    XCTAssertNotEqual(bodyUpdated.schedule_approval_tag, originalTag)
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
    XCTAssertTrue(bodyUpdated.isScheduleAuthenticallyApproved)

    let schedulingUpdated = try store.updateScheduling(
      id: id,
      scheduledSendAt: .some("2026-07-17T18:30:00Z"),
      holdReason: .some(nil),
      scheduleApproved: .some(true)
    )
    XCTAssertEqual(schedulingUpdated.attachments, [attachment])
    XCTAssertEqual(schedulingUpdated.delivery_progress, newestProgress)
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
    XCTAssertTrue(schedulingUpdated.isScheduleAuthenticallyApproved)

    try store.markSent(id: id, sentAt: Date(), service: "iMessage")
    let sent = try XCTUnwrap(store.drafts.first(where: { $0.id == id }))
    XCTAssertEqual(sent.attachments, [attachment])
    XCTAssertEqual(sent.delivery_progress, newestProgress)
    ApprovalAuthenticator.resetSessionApprovalsForTesting()
    XCTAssertTrue(sent.isScheduleAuthenticallyApproved)
  }

  @MainActor
  func testUpdateBodyStillRejectsEmptyTextOnlyDraft() throws {
    let home = temporaryHome()
    let draft = makeDraft(id: "text-only", platform: .imessage, attachments: nil)
    try writeDraft(draft, home: home)
    let store = DraftStore(homeOverride: home)
    XCTAssertThrowsError(try store.updateBody(id: draft.id, body: "   "))
  }

  @MainActor
  func testDiscardRemovesAttachmentSnapshotsForBothPlatforms() throws {
    for platform in [Platform.imessage, .whatsapp] {
      let home = temporaryHome()
      let id = UUID().uuidString.lowercased()
      let snapshot = attachmentDirectory(home: home, platform: platform, id: id)
      try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
      let file = snapshot.appendingPathComponent("\(UUID().uuidString.lowercased()).bin")
      try Data("asset".utf8).write(to: file)
      XCTAssertEqual(Darwin.chflags(file.path, UInt32(UF_IMMUTABLE)), 0)
      let draft = makeDraft(id: id, platform: platform, attachments: nil)
      try writeDraft(draft, home: home)

      let store = DraftStore(homeOverride: home)
      try store.discard(id: id)

      XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path), platform.rawValue)
      XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL(home: home, draft: draft).path), platform.rawValue)
    }
  }

  @MainActor
  func testSweepRemovesAttachmentSnapshotWithExpiredDraft() throws {
    let home = temporaryHome()
    let id = UUID().uuidString.lowercased()
    let snapshot = attachmentDirectory(home: home, platform: .imessage, id: id)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    let file = snapshot.appendingPathComponent("\(UUID().uuidString.lowercased()).bin")
    try Data("asset".utf8).write(to: file)
    XCTAssertEqual(Darwin.chflags(file.path, UInt32(UF_IMMUTABLE)), 0)
    let draft = makeDraft(
      id: id,
      platform: .imessage,
      attachments: nil,
      sentAt: "2000-01-01T00:00:00Z"
    )
    try writeDraft(draft, home: home)

    _ = DraftStore(homeOverride: home)

    XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL(home: home, draft: draft).path))
  }

  @MainActor
  func testSweepCannotTraverseForgedSymlinkedSnapshotRoot() throws {
    let home = temporaryHome()
    let protected = home.appendingPathComponent("protected-target", isDirectory: true)
    let forgedDirectory = protected.appendingPathComponent("Attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: forgedDirectory, withIntermediateDirectories: true)
    let protectedFile = forgedDirectory.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: protectedFile)

    let transport = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: transport, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: transport.appendingPathComponent("draft-attachments", isDirectory: true),
      withDestinationURL: protected
    )
    let forged = makeDraft(
      id: "Attachments",
      platform: .imessage,
      attachments: nil,
      sentAt: "2000-01-01T00:00:00Z"
    )
    try writeDraft(forged, home: home)

    _ = DraftStore(homeOverride: home)

    XCTAssertEqual(try Data(contentsOf: protectedFile), Data("keep".utf8))
  }

  @MainActor
  func testDiscardCannotTraverseSymlinkedSnapshotRootForValidDraft() throws {
    let home = temporaryHome()
    let id = UUID().uuidString.lowercased()
    let assetName = "\(UUID().uuidString.lowercased()).bin"
    let protected = home.appendingPathComponent("protected-discard-target", isDirectory: true)
    let protectedDraft = protected.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: protectedDraft, withIntermediateDirectories: true)
    let protectedFile = protectedDraft.appendingPathComponent(assetName)
    try Data("keep".utf8).write(to: protectedFile)

    let transport = home.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: transport, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: transport.appendingPathComponent("draft-attachments", isDirectory: true),
      withDestinationURL: protected
    )
    let draft = makeDraft(id: id, platform: .imessage, attachments: nil)
    try writeDraft(draft, home: home)

    let store = DraftStore(homeOverride: home)
    try store.discard(id: id)

    XCTAssertEqual(try Data(contentsOf: protectedFile), Data("keep".utf8))
  }

  func testIMessagePreparationCopiesReviewedBytesIntoProtectedSpool() throws {
    let id = "pinned-draft"
    let sourceDirectory = attachmentDirectory(home: modelHome, platform: .imessage, id: id)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let assetID = UUID().uuidString.lowercased()
    let source = sourceDirectory.appendingPathComponent("\(assetID).jpg")
    let reviewed = Data([0xff, 0xd8, 0xff, 0x77])
    try reviewed.write(to: source)
    let hash = try XCTUnwrap(DraftSender.fileSHA256(atPath: source.path))
    let attachment = DraftAttachment(
      path: source.path,
      filename: "photo.jpg",
      mime_type: "image/jpeg",
      byte_count: reviewed.count,
      asset_id: assetID,
      sha256: hash
    )

    let prepared = try DraftSender.prepareIMessageAttachment(attachment, draftId: id)
    XCTAssertTrue(prepared.fileURL.path.hasPrefix("/.vol/"))
    XCTAssertEqual(try Data(contentsOf: prepared.fileURL), reviewed)
    XCTAssertThrowsError(try Data("replacement".utf8).write(to: prepared.fileURL))
    try Data("changed source after preparation".utf8).write(to: source)
    XCTAssertEqual(try Data(contentsOf: prepared.fileURL), reviewed)

    DraftSender.cleanupIMessageAttachment(prepared)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertThrowsError(try Data(contentsOf: prepared.fileURL))
    let spoolRoot = modelHome.appendingPathComponent("Library/Messages/GhostieSendSpool", isDirectory: true)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spoolRoot.path), [])
  }

  func testIMessagePreparationRejectsChangedReviewedBytesBeforeWireAttempt() throws {
    let id = "spool-tamper"
    let sourceDirectory = attachmentDirectory(home: modelHome, platform: .imessage, id: id)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let assetID = UUID().uuidString.lowercased()
    let source = sourceDirectory.appendingPathComponent("\(assetID).jpg")
    try Data([0xff, 0xd8, 0xff, 0x11]).write(to: source)
    let attachment = DraftAttachment(
      path: source.path,
      filename: "photo.jpg",
      mime_type: "image/jpeg",
      byte_count: 4,
      asset_id: assetID,
      sha256: String(repeating: "0", count: 64)
    )

    XCTAssertThrowsError(try DraftSender.prepareIMessageAttachment(attachment, draftId: id))
  }

  func testIMessageCleanupRemovesCrashLeftLegacySpoolsAfterOneHour() throws {
    let abandoned = modelHome
      .appendingPathComponent(".messages-mcp/send-spool/old-send", isDirectory: true)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: abandoned.appendingPathComponent("copy.jpg"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)],
      ofItemAtPath: abandoned.path
    )

    XCTAssertEqual(DraftSender.cleanupStaleIMessageAttachmentSpools(), 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
  }

  func testIMessageCleanupClearsImmutableProtectedCrashSpool() throws {
    let abandoned = modelHome
      .appendingPathComponent("Library/Messages/GhostieSendSpool/old-send", isDirectory: true)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    let file = abandoned.appendingPathComponent("copy.jpg")
    try Data("old".utf8).write(to: file)
    XCTAssertEqual(Darwin.chflags(file.path, UInt32(UF_IMMUTABLE)), 0)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)],
      ofItemAtPath: abandoned.path
    )

    XCTAssertEqual(DraftSender.cleanupStaleIMessageAttachmentSpools(), 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
  }

  func testIMessageCleanupNeverTraversesASymlinkedSpoolRoot() throws {
    let protected = modelHome.appendingPathComponent("protected-target", isDirectory: true)
    let oldData = protected.appendingPathComponent("old-data", isDirectory: true)
    try FileManager.default.createDirectory(at: oldData, withIntermediateDirectories: true)
    let protectedFile = oldData.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: protectedFile)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)],
      ofItemAtPath: oldData.path
    )
    let transport = modelHome.appendingPathComponent(".messages-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: transport, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: transport.appendingPathComponent("send-spool"),
      withDestinationURL: protected
    )

    XCTAssertEqual(DraftSender.cleanupStaleIMessageAttachmentSpools(), 0)
    XCTAssertEqual(try Data(contentsOf: protectedFile), Data("keep".utf8))
  }

  func testIMessageCleanupNeverTraversesSymlinkedProtectedSpoolRoot() throws {
    let protected = modelHome.appendingPathComponent("protected-messages-target", isDirectory: true)
    let oldData = protected.appendingPathComponent("old-data", isDirectory: true)
    try FileManager.default.createDirectory(at: oldData, withIntermediateDirectories: true)
    let protectedFile = oldData.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: protectedFile)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)],
      ofItemAtPath: oldData.path
    )
    let messages = modelHome.appendingPathComponent("Library/Messages", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: messages.appendingPathComponent("GhostieSendSpool", isDirectory: true),
      withDestinationURL: protected
    )

    XCTAssertEqual(DraftSender.cleanupStaleIMessageAttachmentSpools(), 0)
    XCTAssertEqual(try Data(contentsOf: protectedFile), Data("keep".utf8))
  }

  func testIMessagePreparationRejectsSymlinkedManagedDraftDirectory() throws {
    let id = "linked-draft"
    let target = modelHome.appendingPathComponent("protected-attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let assetID = UUID().uuidString.lowercased()
    let targetFile = target.appendingPathComponent("\(assetID).jpg")
    let bytes = Data([0xff, 0xd8, 0xff, 0x33])
    try bytes.write(to: targetFile)
    let draftRoot = attachmentDirectory(home: modelHome, platform: .imessage, id: id)
    try FileManager.default.createDirectory(at: draftRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: draftRoot, withDestinationURL: target)
    let attachment = DraftAttachment(
      path: draftRoot.appendingPathComponent("\(assetID).jpg").path,
      filename: "photo.jpg",
      mime_type: "image/jpeg",
      byte_count: bytes.count,
      asset_id: assetID,
      sha256: try XCTUnwrap(DraftSender.fileSHA256(atPath: targetFile.path))
    )

    XCTAssertThrowsError(try DraftSender.prepareIMessageAttachment(attachment, draftId: id))
    XCTAssertEqual(try Data(contentsOf: targetFile), bytes)
  }

  func testReviewReenforcesAttachmentCountAndSizeLimits() {
    let oversized = managedAttachment(
      id: "draft-1",
      byteCount: 100 * 1024 * 1024 + 1
    )
    XCTAssertNotNil(makeDraft(attachments: [oversized]).attachmentReviewIssue)

    let tooMany = (0...10).map { index in
      managedAttachment(id: "draft-1", assetID: "asset-\(index)", byteCount: 1)
    }
    XCTAssertNotNil(makeDraft(attachments: tooMany).attachmentReviewIssue)

    let aggregate = (0..<3).map { index in
      managedAttachment(id: "draft-1", assetID: "asset-\(index)", byteCount: 90 * 1024 * 1024)
    }
    XCTAssertNotNil(makeDraft(attachments: aggregate).attachmentReviewIssue)
  }

  // MARK: - Helpers

  private func makeDraft(
    id: String = "draft-1",
    platform: Platform = .whatsapp,
    toHandle: String = "12025550123@s.whatsapp.net",
    body: String = "caption",
    quotedMessageID: String? = "quote-1",
    scheduledSendAt: String? = "2026-07-16T18:30:00Z",
    attachments: [DraftAttachment]? = nil,
    progress: DraftDeliveryProgress? = nil,
    tag: String? = nil,
    sentAt: String? = nil
  ) -> Draft {
    Draft(
      id: id,
      to_handle: toHandle,
      to_handle_name: nil,
      body: body,
      attachments: attachments,
      delivery_progress: progress,
      in_reply_to_thread_id: nil,
      staged_at: "2026-07-16T00:00:00Z",
      sent_at: sentAt,
      send_service: platform == .imessage ? "iMessage" : nil,
      source: "test",
      context_messages: nil,
      context_diagnostic: nil,
      scheduled_send_at: scheduledSendAt,
      schedule_hold_reason: nil,
      override_send: nil,
      schedule_approved: true,
      schedule_approval_tag: tag,
      schema_version: platform == .whatsapp ? 1 : nil,
      platform: platform,
      approval_state: platform == .whatsapp ? .pending : nil,
      induced_by_unknown_contact: nil,
      quoted_message_id: quotedMessageID,
      quoted_preview: nil
    )
  }

  private func managedAttachment(
    id: String,
    assetID: String = "550e8400-e29b-41d4-a716-446655440000",
    filename: String = "photo.png",
    mimeType: String = "image/png",
    byteCount: Int = 10,
    sha256: String = String(repeating: "a", count: 64)
  ) -> DraftAttachment {
    let pathExtension = (filename as NSString).pathExtension.lowercased()
    let managedName = pathExtension.isEmpty ? assetID : "\(assetID).\(pathExtension)"
    return DraftAttachment(
      path: modelHome
        .appendingPathComponent(".whatsapp-mcp/draft-attachments/\(id)/\(managedName)")
        .path,
      filename: filename,
      mime_type: mimeType,
      byte_count: byteCount,
      asset_id: assetID,
      sha256: sha256
    )
  }

  private func temporaryHome() -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("draft-media-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  private func writeDraft(_ draft: Draft, home: URL) throws {
    let url = draftURL(home: home, draft: draft)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(draft).write(to: url)
  }

  private func draftURL(home: URL, draft: Draft) -> URL {
    let root = draft.effectivePlatform == .imessage ? ".messages-mcp" : ".whatsapp-mcp"
    return home.appendingPathComponent("\(root)/drafts/\(draft.id).json")
  }

  private func attachmentDirectory(home: URL, platform: Platform, id: String) -> URL {
    let root = platform == .imessage ? ".messages-mcp" : ".whatsapp-mcp"
    return home.appendingPathComponent("\(root)/draft-attachments/\(id)", isDirectory: true)
  }
}
