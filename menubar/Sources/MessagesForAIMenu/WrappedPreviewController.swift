import AppKit
import Foundation
import WebKit

enum WrappedPreviewNativeAction: String, CaseIterable, Equatable {
  case exit
  case shareCard
  case exportPNG
  case revealInFinder
  case openInBrowser

  var title: String {
    switch self {
    case .exit: return "Exit"
    case .shareCard: return "Share"
    case .exportPNG: return "Export"
    case .revealInFinder: return "Show in Finder"
    case .openInBrowser: return "Open in Browser"
    }
  }
}

enum WrappedPreviewNativeStatus: Equatable {
  case idle
  case working(String)
  case success(String)
  case failed(String)

  var text: String? {
    switch self {
    case .idle:
      return nil
    case .working(let text), .success(let text), .failed(let text):
      return text
    }
  }
}

enum WrappedPreviewNativeError: Error, Equatable {
  case missingWebView
  case missingSnapshotAPI
  case invalidMetadata
  case invalidRect
  case snapshotFailed
  case pngEncodingFailed
  case noShareableCards
  case writeFailed

  var userFacingMessage: String {
    switch self {
    case .missingWebView:
      return "Preview is still loading."
    case .missingSnapshotAPI:
      return "Regenerate Wrapped to enable export."
    case .invalidMetadata, .invalidRect:
      return "Could not read the current card."
    case .snapshotFailed:
      return "Could not capture this card."
    case .pngEncodingFailed:
      return "Could not create the PNG."
    case .noShareableCards:
      return "No shareable cards found."
    case .writeFailed:
      return "Could not save the PNG."
    }
  }
}

struct WrappedPreviewSnapshotMetadata: Equatable {
  struct Rect: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var cgRect: CGRect {
      CGRect(x: x, y: y, width: width, height: height)
    }
  }

  let index: Int
  let key: String
  let filename: String
  let rect: Rect

  init(messageBody: Any) throws {
    guard let payload = messageBody as? [String: Any],
          let key = payload["key"] as? String,
          let filename = payload["filename"] as? String,
          WrappedPreviewFilePayload.isSafePNGFilename(filename),
          let rawRect = payload["rect"] as? [String: Any]
    else {
      throw WrappedPreviewNativeError.invalidMetadata
    }
    let index = try Self.intValue(payload["index"])
    let rect = try Rect(rawRect)
    guard rect.width > 0, rect.height > 0 else {
      throw WrappedPreviewNativeError.invalidRect
    }
    self.index = index
    self.key = key
    self.filename = filename
    self.rect = rect
  }

  private static func intValue(_ value: Any?) throws -> Int {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    throw WrappedPreviewNativeError.invalidMetadata
  }
}

extension WrappedPreviewSnapshotMetadata.Rect {
  init(_ payload: [String: Any]) throws {
    func number(_ key: String) throws -> CGFloat {
      if let value = payload[key] as? NSNumber {
        return CGFloat(truncating: value)
      }
      if let value = payload[key] as? Double {
        return CGFloat(value)
      }
      if let value = payload[key] as? CGFloat {
        return value
      }
      throw WrappedPreviewNativeError.invalidRect
    }
    self.x = try number("x")
    self.y = try number("y")
    self.width = try number("width")
    self.height = try number("height")
  }
}

@MainActor
final class WrappedPreviewController: ObservableObject {
  @Published private(set) var status: WrappedPreviewNativeStatus = .idle

  weak var webView: WKWebView?

  func register(webView: WKWebView) {
    self.webView = webView
  }

  func exportCurrentCard(using exportController: WrappedPreviewExportController) async {
    await performCurrentCard(action: .exportCard, exportController: exportController)
  }

  func shareCurrentCard(using exportController: WrappedPreviewExportController) async {
    await performCurrentCard(action: .shareCard, exportController: exportController)
  }

  func exportAllCards(using exportController: WrappedPreviewExportController) async {
    await performAllCards(action: .exportAll, exportController: exportController)
  }

  func shareAllCards(using exportController: WrappedPreviewExportController) async {
    await performAllCards(action: .shareAll, exportController: exportController)
  }

  private func performCurrentCard(
    action: WrappedPreviewFileAction,
    exportController: WrappedPreviewExportController
  ) async {
    guard status.isIdle else { return }
    status = .working(action.isShare ? "Preparing share..." : "Exporting PNG...")
    do {
      let webView = try requireWebView()
      let metadata = try await currentMetadata()
      let image = try await snapshot(metadata.rect.cgRect, in: webView)
      let data = try pngData(from: image)
      let payload = try WrappedPreviewFilePayload(action: action, filename: metadata.filename, data: data)
      try exportController.handle(payload, presentingFrom: webView)
      status = .success(action.isShare ? "Share sheet opened." : "Saved to Downloads.")
    } catch {
      status = .failed(userFacingMessage(for: error))
    }
    resetSoon()
  }

  private func performAllCards(
    action: WrappedPreviewFileAction,
    exportController: WrappedPreviewExportController
  ) async {
    guard status.isIdle else { return }
    status = .working(action.isShare ? "Preparing cards..." : "Exporting cards...")
    do {
      let webView = try requireWebView()
      let indices = try await shareableIndices()
      guard !indices.isEmpty else { throw WrappedPreviewNativeError.noShareableCards }
      var images: [NSImage] = []
      for (offset, index) in indices.enumerated() {
        status = .working("Rendering \(offset + 1)/\(indices.count)...")
        _ = try await evaluate("__messagesForAIWrappedSnapshot.setIndex(\(index));")
        try await Task.sleep(nanoseconds: 850_000_000)
        let metadata = try await currentMetadata()
        let image = try await snapshot(metadata.rect.cgRect, in: webView)
        images.append(image)
      }
      let composite = try compositeImage(images)
      let data = try pngData(from: composite)
      let filename = try await allCardsFilename()
      let payload = try WrappedPreviewFilePayload(action: action, filename: filename, data: data)
      try exportController.handle(payload, presentingFrom: webView)
      status = .success(action.isShare ? "Share sheet opened." : "Saved all cards.")
    } catch {
      status = .failed(userFacingMessage(for: error))
    }
    resetSoon()
  }

  private func requireWebView() throws -> WKWebView {
    guard let webView else { throw WrappedPreviewNativeError.missingWebView }
    return webView
  }

  private func currentMetadata() async throws -> WrappedPreviewSnapshotMetadata {
    let result = try await evaluate("__messagesForAIWrappedSnapshot.current();")
    return try WrappedPreviewSnapshotMetadata(messageBody: result)
  }

  private func shareableIndices() async throws -> [Int] {
    let result = try await evaluate("__messagesForAIWrappedSnapshot.shareableIndices();")
    guard let raw = result as? [Any] else {
      throw WrappedPreviewNativeError.invalidMetadata
    }
    return try raw.map { value in
      if let value = value as? Int { return value }
      if let value = value as? NSNumber { return value.intValue }
      throw WrappedPreviewNativeError.invalidMetadata
    }
  }

  private func allCardsFilename() async throws -> String {
    let result = try await evaluate("__messagesForAIWrappedSnapshot.allCardsFilename();")
    guard let filename = result as? String,
          WrappedPreviewFilePayload.isSafePNGFilename(filename)
    else {
      throw WrappedPreviewNativeError.invalidMetadata
    }
    return filename
  }

  private func evaluate(_ script: String) async throws -> Any {
    let webView = try requireWebView()
    return try await withCheckedThrowingContinuation { continuation in
      webView.evaluateJavaScript(script) { result, error in
        if let error {
          if script.contains("__messagesForAIWrappedSnapshot") {
            continuation.resume(throwing: WrappedPreviewNativeError.missingSnapshotAPI)
          } else {
            continuation.resume(throwing: error)
          }
          return
        }
        guard let result else {
          continuation.resume(throwing: WrappedPreviewNativeError.invalidMetadata)
          return
        }
        continuation.resume(returning: result)
      }
    }
  }

  private func snapshot(_ rect: CGRect, in webView: WKWebView) async throws -> NSImage {
    guard rect.width > 0, rect.height > 0 else {
      throw WrappedPreviewNativeError.invalidRect
    }
    let config = WKSnapshotConfiguration()
    config.rect = rect.integral
    config.afterScreenUpdates = true
    return try await withCheckedThrowingContinuation { continuation in
      webView.takeSnapshot(with: config) { image, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: WrappedPreviewNativeError.snapshotFailed)
        }
      }
    }
  }

  private func pngData(from image: NSImage) throws -> Data {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
    else {
      throw WrappedPreviewNativeError.pngEncodingFailed
    }
    return data
  }

  private func compositeImage(_ images: [NSImage]) throws -> NSImage {
    guard let first = images.first else {
      throw WrappedPreviewNativeError.noShareableCards
    }
    let columns = images.count <= 4 ? 2 : 3
    let rows = Int(ceil(Double(images.count) / Double(columns)))
    let targetWidth: CGFloat = 360
    let scale = targetWidth / max(first.size.width, 1)
    let targetHeight = max(first.size.height * scale, 1)
    let gap: CGFloat = 18
    let padding: CGFloat = 28
    let canvasSize = NSSize(
      width: padding * 2 + CGFloat(columns) * targetWidth + CGFloat(columns - 1) * gap,
      height: padding * 2 + CGFloat(rows) * targetHeight + CGFloat(rows - 1) * gap
    )
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    for (index, card) in images.enumerated() {
      let col = index % columns
      let row = index / columns
      let x = padding + CGFloat(col) * (targetWidth + gap)
      let y = canvasSize.height - padding - CGFloat(row + 1) * targetHeight - CGFloat(row) * gap
      card.draw(in: NSRect(x: x, y: y, width: targetWidth, height: targetHeight))
    }
    image.unlockFocus()
    return image
  }

  private func userFacingMessage(for error: Error) -> String {
    if let error = error as? WrappedPreviewNativeError {
      return error.userFacingMessage
    }
    if error is WrappedPreviewFileError {
      return WrappedPreviewNativeError.writeFailed.userFacingMessage
    }
    return "Export failed."
  }

  private func resetSoon() {
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      await MainActor.run {
        guard case .idle = self?.status else {
          self?.status = .idle
          return
        }
      }
    }
  }
}

extension WrappedPreviewNativeStatus {
  var isIdle: Bool {
    if case .idle = self { return true }
    return false
  }
}
