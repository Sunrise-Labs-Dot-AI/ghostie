import AppKit
import ApplicationServices
import Foundation

/// Experimental, UI-driven iMessage Tapback sender.
///
/// This deliberately stays outside private Messages frameworks and never writes
/// chat.db. It opens the normal Messages.app conversation, verifies the
/// displayed conversation actually matches the target contact, finds the
/// visible message bubble in that conversation's Accessibility subtree, and
/// invokes the same secondary action a user would choose from Messages.app's
/// context menu. If the target conversation can't be positively verified the
/// automation refuses (targetNotVisible) instead of guessing — a Tapback in
/// the wrong thread would break the "you approve exactly this send" stance.
enum IMessageTapbackAutomation {
  enum AutomationError: LocalizedError, Equatable {
    case unsupportedGroup
    case missingBody
    case unsupportedEmoji(String)
    case badConversationURL
    case accessibilityPermissionRequired
    case messagesDidNotLaunch
    case targetNotVisible
    case ambiguousTarget
    case actionUnavailable(String)
    case actionFailed(Int32)

    var errorDescription: String? {
      switch self {
      case .unsupportedGroup:
        return "Experimental iMessage reactions only support 1:1 conversations for now."
      case .missingBody:
        return "That message does not expose readable text for the prototype to target."
      case .unsupportedEmoji(let emoji):
        return "Messages did not expose \(emoji) as a Tapback action for that bubble."
      case .badConversationURL:
        return "Could not open that conversation in Messages.app."
      case .accessibilityPermissionRequired:
        return "Turn on Accessibility access for Ghostie, then try the reaction again."
      case .messagesDidNotLaunch:
        return "Messages.app did not become available."
      case .targetNotVisible:
        return "Couldn't confirm Messages.app was showing that conversation and message, so no reaction was sent. Open the thread near the message and try again."
      case .ambiguousTarget:
        return "Messages.app showed multiple matching bubbles, so the prototype refused to guess."
      case .actionUnavailable(let action):
        return "Messages.app did not expose the \(action) Tapback for that bubble."
      case .actionFailed:
        return "Messages.app rejected the Tapback action."
      }
    }
  }

  static let standardChoices = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
  static let experimentalChoices = standardChoices + ["🔥", "🎉"]

  @MainActor
  static func sendReaction(
    handle: String,
    displayName: String?,
    message: ContextMessage,
    emoji: String,
    isGroupConversation: Bool
  ) async throws {
    guard !isGroupConversation else { throw AutomationError.unsupportedGroup }
    guard let body = message.body?.trimmingCharacters(in: .whitespacesAndNewlines),
          !body.isEmpty else {
      throw AutomationError.missingBody
    }
    guard let requestedAction = actionName(forEmoji: emoji) else {
      throw AutomationError.unsupportedEmoji(emoji)
    }
    guard isAccessibilityTrusted(prompt: true) else {
      throw AutomationError.accessibilityPermissionRequired
    }
    guard let url = conversationURL(for: handle) else {
      throw AutomationError.badConversationURL
    }

    // Wrong-conversation protection: NEVER act on whatever conversation
    // Messages.app happens to be showing. A common one-word body ("ok",
    // "lol") in another open thread would silently receive the Tapback —
    // a P0 violation of "you approve exactly this send". So we always
    // (re)navigate to the target conversation first, then refuse to perform
    // the action until the displayed conversation verifiably matches the
    // target handle/contact (see verifiedConversationWindow).
    try await openConversationInBackground(url)
    try await waitForMessagesApp()
    try await waitForVerifiedActionAndPerform(
      handle: handle,
      displayName: displayName,
      body: body,
      fromMe: message.from_me,
      requestedAction: requestedAction
    )
  }

  static func actionName(forEmoji emoji: String) -> String? {
    switch emoji {
    case "❤️": return "Heart"
    case "👍": return "Thumbs up"
    case "👎": return "Thumbs down"
    case "😂": return "Ha ha!"
    case "‼️": return "Exclamation mark"
    case "❓": return "Question mark"
    default:
      let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  static func actionName(_ actions: [String], matching requestedAction: String) -> String? {
    actions.first { action in
      action == requestedAction || action.hasPrefix("Name:\(requestedAction)\n")
    }
  }

  static func conversationURL(for handle: String) -> URL? {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: "imessage:\(trimmed)") {
      return url
    }
    var allowed = CharacterSet.urlPathAllowed
    allowed.insert(charactersIn: "+@")
    guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return URL(string: "imessage:\(encoded)")
  }

  static func isAccessibilityTrusted(prompt: Bool) -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  @MainActor
  private static func openConversationInBackground(_ url: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.addsToRecentItems = false
      NSWorkspace.shared.open(url, configuration: configuration) { _, error in
        if error != nil {
          continuation.resume(throwing: AutomationError.badConversationURL)
        } else {
          continuation.resume()
        }
      }
    }
  }

  @MainActor
  private static func waitForMessagesApp() async throws {
    for _ in 0..<20 {
      if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }) {
        return
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw AutomationError.messagesDidNotLaunch
  }

  /// Poll until the target conversation is verifiably displayed AND the target
  /// bubble is found inside it, then perform the Tapback action. Every attempt
  /// re-resolves the window from scratch: navigation may still be in flight,
  /// and a stale element must never receive the action. If the displayed
  /// conversation can never be positively verified, this refuses with
  /// `targetNotVisible` — it never falls back to acting on an unverified view.
  private static func waitForVerifiedActionAndPerform(
    handle: String,
    displayName: String?,
    body: String,
    fromMe: Bool,
    requestedAction: String,
    attempts: Int = 24
  ) async throws {
    for attempt in 0..<attempts {
      if attempt > 0 {
        try await Task.sleep(nanoseconds: 250_000_000)
      }
      guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }),
            let window = verifiedConversationWindow(
              appElement: AXUIElementCreateApplication(app.processIdentifier),
              handle: handle,
              displayName: displayName
            ) else {
        continue
      }
      switch findTarget(in: window, body: body, fromMe: fromMe) {
      case .found(let element):
        let actions = actionNames(element)
        guard let action = actionName(actions, matching: requestedAction) else {
          throw AutomationError.actionUnavailable(requestedAction)
        }
        let err = AXUIElementPerformAction(element, action as CFString)
        guard err == .success else { throw AutomationError.actionFailed(err.rawValue) }
        return
      case .ambiguous:
        // Two identical bubbles inside the verified conversation — refuse
        // rather than guess which one the user meant.
        throw AutomationError.ambiguousTarget
      case .notFound:
        continue
      }
    }
    throw AutomationError.targetNotVisible
  }

  private enum FindResult {
    case found(AXUIElement)
    case ambiguous
    case notFound
  }

  /// Return the Messages window that is verifiably displaying the target
  /// conversation, or nil when no window can be positively matched.
  ///
  /// Messages.app titles a chat window with the conversation's display name
  /// (the contact's name, or a formatted handle when no contact exists), so
  /// the window title is keyed to the *displayed* conversation — unlike the
  /// sidebar, which lists every conversation regardless of which one is open.
  private static func verifiedConversationWindow(
    appElement: AXUIElement,
    handle: String,
    displayName: String?
  ) -> AXUIElement? {
    for window in windows(of: appElement) {
      guard let title = attrString(window, kAXTitleAttribute) else { continue }
      if conversationTitleMatchesTarget(title: title, displayName: displayName, handle: handle) {
        return window
      }
    }
    return nil
  }

  /// Positive identification of the displayed conversation. Matching is
  /// deliberately conservative: an unknown title format must FAIL
  /// verification (no Tapback) rather than pass it.
  static func conversationTitleMatchesTarget(
    title: String,
    displayName: String?,
    handle: String
  ) -> Bool {
    let normalizedTitle = normalizedIdentity(title)
    guard !normalizedTitle.isEmpty else { return false }
    if let displayName {
      let normalizedName = normalizedIdentity(displayName)
      if !normalizedName.isEmpty, normalizedTitle == normalizedName { return true }
    }
    let normalizedHandle = normalizedIdentity(handle)
    if !normalizedHandle.isEmpty, normalizedTitle == normalizedHandle { return true }
    // Phone handles render with locale formatting ("+1 (215) 555-0172"), so
    // compare digit strings. Require a full match or a 7+ digit suffix match
    // (country-code tolerance); short fragments can never pass verification.
    let titleDigits = digits(of: title)
    let handleDigits = digits(of: handle)
    guard titleDigits.count >= 7, handleDigits.count >= 7 else { return false }
    return titleDigits == handleDigits
      || titleDigits.hasSuffix(handleDigits)
      || handleDigits.hasSuffix(titleDigits)
  }

  private static func normalizedIdentity(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  private static func digits(of value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init))
  }

  /// Search for the target bubble inside ONE verified conversation window —
  /// never across Messages.app's entire AX tree, where a matching body in a
  /// different open thread could be picked up. CKBalloonTextView elements only
  /// exist in the transcript subtree, so window scoping plus the identifier
  /// check confines matches to the displayed conversation's transcript.
  private static func findTarget(in window: AXUIElement, body: String, fromMe: Bool) -> FindResult {
    var matches: [AXUIElement] = []
    walk(window, visited: &matches) { element in
      isTargetBubble(element, body: body, fromMe: fromMe)
    }
    if matches.count == 1 { return .found(matches[0]) }
    if matches.count > 1 { return .ambiguous }
    return .notFound
  }

  private static func windows(of appElement: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
      return []
    }
    return windows
  }

  private static func walk(
    _ element: AXUIElement,
    visited matches: inout [AXUIElement],
    maxNodes: Int = 8000,
    predicate: (AXUIElement) -> Bool
  ) {
    var remaining = maxNodes
    func visit(_ element: AXUIElement) {
      guard remaining > 0 else { return }
      remaining -= 1
      if predicate(element) {
        matches.append(element)
      }
      for child in children(element) {
        visit(child)
      }
    }
    visit(element)
  }

  private static func isTargetBubble(_ element: AXUIElement, body: String, fromMe: Bool) -> Bool {
    guard attrString(element, kAXRoleAttribute) == "AXTextArea",
          attrString(element, kAXIdentifierAttribute) == "CKBalloonTextView",
          attrString(element, kAXValueAttribute) == body else {
      return false
    }
    let descriptions = ancestorDescriptions(element, maxDepth: 3)
    let isFromMeInMessages = descriptions.contains { $0.hasPrefix("Your iMessage") }
    return fromMe ? isFromMeInMessages : !isFromMeInMessages
  }

  private static func ancestorDescriptions(_ element: AXUIElement, maxDepth: Int) -> [String] {
    var out: [String] = []
    var current: AXUIElement? = element
    for _ in 0..<maxDepth {
      guard let parent = parent(of: current) else { break }
      if let description = attrString(parent, kAXDescriptionAttribute), !description.isEmpty {
        out.append(description)
      }
      current = parent
    }
    return out
  }

  private static func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else {
      return []
    }
    return children
  }

  private static func parent(of element: AXUIElement?) -> AXUIElement? {
    guard let element else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private static func attrString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == CFStringGetTypeID() else {
      return nil
    }
    return value as? String
  }

  private static func actionNames(_ element: AXUIElement) -> [String] {
    var actions: CFArray?
    guard AXUIElementCopyActionNames(element, &actions) == .success else { return [] }
    return (actions as? [String]) ?? []
  }
}
