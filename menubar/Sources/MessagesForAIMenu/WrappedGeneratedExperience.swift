import Foundation

struct WrappedGeneratedExperience: Equatable {
  let url: URL
  let readAccessDirectory: URL
  let includeNames: Bool
}

enum WrappedPreviewTelemetryAction: String, CaseIterable {
  case loaded
  case advance
  case share
  case shareAll = "share_all"
  case toggleWindow = "toggle_window"
}

enum WrappedPreviewNavigationDecision: Equatable {
  case allowInPreview
  case openExternally(URL)
  case cancel
}

struct WrappedPreviewNavigationPolicy: Equatable {
  let readAccessDirectory: URL

  func decision(for url: URL?) -> WrappedPreviewNavigationDecision {
    guard let url else { return .cancel }

    if url.isFileURL {
      return isAllowedFile(url) ? .allowInPreview : .cancel
    }

    switch url.scheme?.lowercased() {
    case "http", "https":
      return .openExternally(url)
    case "about":
      return .allowInPreview
    default:
      return .cancel
    }
  }

  private func isAllowedFile(_ url: URL) -> Bool {
    let root = readAccessDirectory.standardizedFileURL.path
    let candidate = url.standardizedFileURL.path
    return candidate == root || candidate.hasPrefix(root + "/")
  }
}
