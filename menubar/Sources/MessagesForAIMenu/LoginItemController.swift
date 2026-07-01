import Foundation
import ServiceManagement

// Controls "open at login" via the modern ServiceManagement API
// (macOS 13+). The older approach — writing a launch agent plist into
// ~/Library/LaunchAgents or calling SMLoginItemSetEnabled — is deprecated.
//
// First-launch behavior is opt-out, not opt-in: the very first time the
// app runs, we register the app as a login item AND persist a sentinel
// in UserDefaults so we don't re-register on every launch (which would
// override a user who toggled it back off). Subsequent launches just
// reflect whatever SMAppService.status reports.
//
// SMAppService.register() can throw if the app isn't in a normal
// location or the signature can't be evaluated. ad-hoc-signed bundles
// in ~/Applications work in practice; we surface any error to the UI
// rather than swallowing it.

@MainActor
final class LoginItemController: ObservableObject {
  @Published private(set) var isEnabled: Bool
  @Published private(set) var lastError: String?

  private let service: SMAppService
  private static let initializedKey = "messages-for-ai.loginItem.initialized"

  init() {
    let svc = SMAppService.mainApp
    self.service = svc
    self.isEnabled = (svc.status == .enabled)

    if !UserDefaults.standard.bool(forKey: Self.initializedKey) {
      // First-ever launch: default the user into open-at-login.
      do {
        try svc.register()
        self.isEnabled = (svc.status == .enabled)
        UserDefaults.standard.set(true, forKey: Self.initializedKey)
      } catch {
        // Don't mark initialized — let the next launch retry. The user
        // can also flip the toggle manually to retry.
        self.lastError = "open-at-login first-launch register failed: \(error.localizedDescription)"
      }
    } else if svc.status == .notFound {
      // Already-initialized install whose registration the system can no
      // longer resolve. This is the rename/move case: the login item was
      // registered from "/Applications/Messages for AI.app", the installer
      // replaced that bundle with "/Applications/Ghostie.app" (same bundle
      // id), and the stale registration now points at a removed path.
      // .notFound is distinct from .notRegistered (the user toggling
      // open-at-login OFF lands there), so re-registering here only ever
      // repairs a grant the user previously had — it can't override an
      // explicit opt-out.
      do {
        try svc.register()
        self.isEnabled = (svc.status == .enabled)
      } catch {
        self.lastError = "open-at-login re-register after app move failed: \(error.localizedDescription)"
      }
    }
  }

  func setEnabled(_ enabled: Bool) {
    lastError = nil
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      lastError = "open-at-login update failed: \(error.localizedDescription)"
    }
    // Always re-read status from the system rather than trusting the
    // requested value — register/unregister can succeed but land the
    // service in `requiresApproval` (the user needs to approve in
    // System Settings) rather than `enabled`.
    isEnabled = (service.status == .enabled)
  }

  // Human-readable rendering of the current SMAppService.Status. Used
  // only when there's something useful to tell the user (e.g.
  // requires-approval) — the happy path doesn't surface this.
  var statusDescription: String? {
    switch service.status {
    case .enabled: return nil
    case .notRegistered: return nil
    case .requiresApproval:
      return "Open at Login is set but requires approval in System Settings → General → Login Items."
    case .notFound:
      return "macOS can't locate this app for login-item registration."
    @unknown default:
      return nil
    }
  }
}
