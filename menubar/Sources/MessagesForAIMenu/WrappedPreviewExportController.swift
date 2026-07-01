import AppKit
import Foundation

enum WrappedPreviewFileAction: String, CaseIterable {
  case shareCard = "share_card"
  case shareAll = "share_all"
  case exportCard = "export_card"
  case exportAll = "export_all"

  var isShare: Bool {
    switch self {
    case .shareCard, .shareAll:
      return true
    case .exportCard, .exportAll:
      return false
    }
  }
}

enum WrappedPreviewFileError: Error, Equatable {
  case invalidAction
  case invalidFilename
  case invalidMimeType
  case invalidBase64
  case payloadTooLarge
  case writeFailed
}

struct WrappedPreviewFilePayload: Equatable {
  static let maxDecodedBytes = 25 * 1024 * 1024

  let action: WrappedPreviewFileAction
  let requestID: String?
  let filename: String
  let mimeType: String
  let data: Data

  init(
    action: WrappedPreviewFileAction,
    requestID: String? = nil,
    filename: String,
    mimeType: String = "image/png",
    data: Data
  ) throws {
    guard Self.isSafePNGFilename(filename) else {
      throw WrappedPreviewFileError.invalidFilename
    }
    guard mimeType == "image/png" else {
      throw WrappedPreviewFileError.invalidMimeType
    }
    guard data.count <= Self.maxDecodedBytes else {
      throw WrappedPreviewFileError.payloadTooLarge
    }
    self.action = action
    self.requestID = requestID
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
  }

  init(messageBody: Any) throws {
    guard let payload = messageBody as? [String: Any],
          let rawAction = payload["action"] as? String,
          let action = WrappedPreviewFileAction(rawValue: rawAction)
    else {
      throw WrappedPreviewFileError.invalidAction
    }
    guard let filename = payload["filename"] as? String,
          Self.isSafePNGFilename(filename)
    else {
      throw WrappedPreviewFileError.invalidFilename
    }
    guard let mimeType = payload["mimeType"] as? String,
          mimeType == "image/png"
    else {
      throw WrappedPreviewFileError.invalidMimeType
    }
    guard let base64 = payload["base64"] as? String,
          let data = Data(base64Encoded: base64)
    else {
      throw WrappedPreviewFileError.invalidBase64
    }
    guard data.count <= Self.maxDecodedBytes else {
      throw WrappedPreviewFileError.payloadTooLarge
    }

    self.action = action
    self.requestID = payload["requestId"] as? String
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
  }

  static func isSafePNGFilename(_ filename: String) -> Bool {
    guard !filename.isEmpty,
          filename.count <= 140,
          filename == (filename as NSString).lastPathComponent,
          !filename.contains(".."),
          filename.lowercased().hasSuffix(".png")
    else { return false }

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return filename.unicodeScalars.allSatisfy { allowed.contains($0) }
  }
}

@MainActor
final class WrappedPreviewExportController {
  typealias SharePresenter = @MainActor (URL, NSView) -> Void

  private let exportDirectory: URL
  private let temporaryDirectory: URL
  private let sharePresenter: SharePresenter

  init(
    exportDirectory: URL = AppStoragePaths.homeDirectory
      .appendingPathComponent("Downloads")
      .appendingPathComponent("texting-wrapped")
      .appendingPathComponent("exports"),
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("messages-for-ai-wrapped-share", isDirectory: true),
    sharePresenter: @escaping SharePresenter = WrappedPreviewExportController.defaultSharePresenter
  ) {
    self.exportDirectory = exportDirectory
    self.temporaryDirectory = temporaryDirectory
    self.sharePresenter = sharePresenter
  }

  @discardableResult
  func handle(_ payload: WrappedPreviewFilePayload, presentingFrom view: NSView) throws -> URL {
    let directory = payload.action.isShare ? temporaryDirectory : exportDirectory
    let url = try write(payload: payload, directory: directory)
    if payload.action.isShare {
      sharePresenter(url, view)
    }
    return url
  }

  func write(payload: WrappedPreviewFilePayload, directory: URL) throws -> URL {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(payload.filename, isDirectory: false)
      try payload.data.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return url
    } catch {
      throw WrappedPreviewFileError.writeFailed
    }
  }

  private static func defaultSharePresenter(url: URL, view: NSView) {
    let picker = NSSharingServicePicker(items: [url])
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
  }
}
