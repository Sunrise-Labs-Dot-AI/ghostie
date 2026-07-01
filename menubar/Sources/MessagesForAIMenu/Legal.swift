import Foundation

/// Legal constants for the Terms of Service / Privacy Policy acceptance gate.
///
/// `termsVersion` is the version of the combined Terms + Privacy the user must
/// accept before any permission grant or data access. Bump it (to the new
/// publish date) whenever the Terms or Privacy materially change — that flips
/// `SettingsStore.termsAccepted` back to false for everyone, re-presenting the
/// onboarding acceptance gate until they re-accept the new version.
enum Legal {
  /// Date-stamped Terms/Privacy version. Bump on any material change.
  static let termsVersion = "2026-06-09"
  static let termsURL = URL(string: "https://messagesfor.ai/terms.html")!
  static let privacyURL = URL(string: "https://messagesfor.ai/privacy.html")!
}
