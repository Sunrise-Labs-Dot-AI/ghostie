import Foundation

enum AppStoragePaths {
  static var homeOverridePath: String? {
    let value = ProcessInfo.processInfo.environment["MESSAGES_FOR_AI_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  static var isUsingHomeOverride: Bool {
    homeOverridePath != nil
  }

  static var homeDirectory: URL {
    if let override = homeOverridePath {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }
}
