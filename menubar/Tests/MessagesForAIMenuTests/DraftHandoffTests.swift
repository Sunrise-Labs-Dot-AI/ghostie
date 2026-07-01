import Foundation
import XCTest
@testable import MessagesForAIMenu

final class DraftHandoffTests: XCTestCase {
  // Pull the `q` / `prompt` value back out of a built URL, percent-decoded.
  private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == name })?
      .value
  }

  func testClaudeCoworkURL() {
    let url = DraftHandoff.claudeURL(prompt: "draft a birthday text to Jane", target: .cowork)
    XCTAssertNotNil(url)
    XCTAssertEqual(url?.scheme, "claude")
    XCTAssertTrue(url!.absoluteString.hasPrefix("claude://cowork/new?q="), url!.absoluteString)
    XCTAssertEqual(queryValue(url!, "q"), "draft a birthday text to Jane")
  }

  func testClaudeChatURL() {
    let url = DraftHandoff.claudeURL(prompt: "hi there", target: .chat)
    XCTAssertTrue(url!.absoluteString.hasPrefix("claude://claude.ai/new?q="), url!.absoluteString)
    XCTAssertEqual(queryValue(url!, "q"), "hi there")
  }

  func testCodexURL() {
    let url = DraftHandoff.codexURL(prompt: "find a birthday")
    XCTAssertEqual(url?.scheme, "codex")
    XCTAssertTrue(url!.absoluteString.hasPrefix("codex://new?prompt="), url!.absoluteString)
    XCTAssertEqual(queryValue(url!, "prompt"), "find a birthday")
  }

  // The reserved chars that would otherwise split the query or corrupt the URL
  // must round-trip intact (spaces, &, =, +, ?, #, /).
  func testReservedCharactersRoundTrip() {
    let prompt = "a & b = c + d ? e # f / g"
    let url = DraftHandoff.claudeURL(prompt: prompt, target: .cowork)
    XCTAssertNotNil(url, "URL should build despite reserved chars")
    XCTAssertFalse(url!.absoluteString.contains(" "), "raw space must not appear in the URL")
    XCTAssertEqual(queryValue(url!, "q"), prompt)
  }

  func testEmptyAndWhitespacePromptYieldsNil() {
    XCTAssertNil(DraftHandoff.claudeURL(prompt: "", target: .cowork))
    XCTAssertNil(DraftHandoff.claudeURL(prompt: "   \n ", target: .cowork))
    XCTAssertNil(DraftHandoff.codexURL(prompt: ""))
  }

  func testOversizePromptYieldsNil() {
    let huge = String(repeating: "x", count: DraftHandoff.maxPromptChars + 1)
    XCTAssertNil(DraftHandoff.claudeURL(prompt: huge, target: .chat))
    // At the cap it still builds.
    let atCap = String(repeating: "y", count: DraftHandoff.maxPromptChars)
    XCTAssertNotNil(DraftHandoff.claudeURL(prompt: atCap, target: .chat))
  }

  func testURLDispatchMapping() {
    let p = "go"
    XCTAssertEqual(
      DraftHandoff.url(for: .claude, prompt: p, claudeTarget: .cowork)?.absoluteString,
      DraftHandoff.claudeURL(prompt: p, target: .cowork)?.absoluteString
    )
    XCTAssertEqual(
      DraftHandoff.url(for: .claude, prompt: p, claudeTarget: .chat)?.absoluteString,
      DraftHandoff.claudeURL(prompt: p, target: .chat)?.absoluteString
    )
    XCTAssertEqual(
      DraftHandoff.url(for: .codex, prompt: p, claudeTarget: .cowork)?.absoluteString,
      DraftHandoff.codexURL(prompt: p)?.absoluteString
    )
  }

  func testClaudeTargetRawValuesStableForPersistence() {
    // SettingsStore persists these rawValues into settings.json; don't rename.
    XCTAssertEqual(ClaudeTarget.cowork.rawValue, "cowork")
    XCTAssertEqual(ClaudeTarget.chat.rawValue, "chat")
    XCTAssertEqual(ClaudeTarget(rawValue: "cowork"), .cowork)
    XCTAssertNil(ClaudeTarget(rawValue: "bogus"))
  }

  // MARK: - handler allowlist (URL-scheme hijack guard)

  // The exact bundle IDs are load-bearing: dispatch refuses to open any handler
  // not in these sets, so a typo here would silently re-open the hijack hole (or
  // break every handoff). Pinned to the IDs confirmed via lsregister +
  // NSWorkspace.urlForApplication.
  func testAllowedBundleIDsArePinned() {
    XCTAssertEqual(DraftAssistant.claude.allowedBundleIDs, ["com.anthropic.claudefordesktop"])
    XCTAssertEqual(DraftAssistant.codex.allowedBundleIDs, ["com.openai.codex"])
  }

  func testTrustedHandlerAcceptsFirstPartyApps() {
    XCTAssertTrue(DraftHandoff.isTrustedHandler("com.anthropic.claudefordesktop", for: .claude))
    XCTAssertTrue(DraftHandoff.isTrustedHandler("com.openai.codex", for: .codex))
  }

  func testTrustedHandlerRejectsImpostorsAndCrossAssistant() {
    // A malicious app that registered the scheme.
    XCTAssertFalse(DraftHandoff.isTrustedHandler("com.evil.hijacker", for: .claude))
    // The other assistant's app must not satisfy this assistant's allowlist.
    XCTAssertFalse(DraftHandoff.isTrustedHandler("com.openai.codex", for: .claude))
    XCTAssertFalse(DraftHandoff.isTrustedHandler("com.anthropic.claudefordesktop", for: .codex))
    // No handler resolved at all.
    XCTAssertFalse(DraftHandoff.isTrustedHandler(nil, for: .claude))
    XCTAssertFalse(DraftHandoff.isTrustedHandler("", for: .codex))
  }

  func testTrustedHandlerIsCaseInsensitive() {
    // Launch Services treats bundle IDs case-insensitively, so a case-variant
    // spoof must not slip past the allowlist.
    XCTAssertTrue(DraftHandoff.isTrustedHandler("COM.Anthropic.ClaudeForDesktop", for: .claude))
    XCTAssertTrue(DraftHandoff.isTrustedHandler("Com.OpenAI.Codex", for: .codex))
  }

  // MARK: - pasteboard guarded clear

  func testShouldClearClipboardOnlyWhenStillOurs() {
    // changeCount unchanged → our prompt is still on the pasteboard → safe to wipe.
    XCTAssertTrue(DraftHandoff.shouldClearClipboard(writtenChangeCount: 7, currentChangeCount: 7))
    // The user copied something else since → we must not clobber it.
    XCTAssertFalse(DraftHandoff.shouldClearClipboard(writtenChangeCount: 7, currentChangeCount: 8))
  }

  // MARK: - outcome messaging

  func testHandoffOutcomeMessaging() {
    XCTAssertFalse(HandoffOutcome.opened.isWarning)
    XCTAssertEqual(HandoffOutcome.opened.message(assistant: .claude), "Opening Claude")

    let benign = HandoffOutcome.clipboardOnly(untrusted: false)
    XCTAssertFalse(benign.isWarning)
    XCTAssertEqual(benign.message(assistant: .codex), "Prompt copied to clipboard")

    // The hijack-blocked case is a warning and names the assistant the user expected.
    let blocked = HandoffOutcome.clipboardOnly(untrusted: true)
    XCTAssertTrue(blocked.isWarning)
    XCTAssertTrue(blocked.message(assistant: .claude).contains("Claude"), blocked.message(assistant: .claude))
    XCTAssertTrue(blocked.message(assistant: .claude).localizedCaseInsensitiveContains("clipboard"))
  }
}
