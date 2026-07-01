import XCTest
@testable import MessagesForAIMenu

final class ConsoleViewModeTests: XCTestCase {
  func test_wrappedOnlyModeAllowsWrappedAndSettingsOnly() {
    XCTAssertTrue(ConsoleView.isSelectionAllowed(.tool("wrapped"), experienceMode: .textingWrappedOnly))
    XCTAssertTrue(ConsoleView.isSelectionAllowed(.settings, experienceMode: .textingWrappedOnly))
    XCTAssertFalse(ConsoleView.isSelectionAllowed(.messages, experienceMode: .textingWrappedOnly))
    XCTAssertFalse(ConsoleView.isSelectionAllowed(.drafts, experienceMode: .textingWrappedOnly))
    XCTAssertFalse(ConsoleView.isSelectionAllowed(.tool("birthdays"), experienceMode: .textingWrappedOnly))
  }

  func test_wrappedOnlyModeNormalizesHiddenSelectionsToWrapped() {
    XCTAssertEqual(
      ConsoleView.normalizedSelection(.messages, experienceMode: .textingWrappedOnly),
      .tool("wrapped")
    )
    XCTAssertEqual(
      ConsoleView.normalizedSelection(nil, experienceMode: .textingWrappedOnly),
      .tool("wrapped")
    )
    XCTAssertEqual(
      ConsoleView.normalizedSelection(.settings, experienceMode: .textingWrappedOnly),
      .settings
    )
  }

  func test_fullModeAllowsExistingSelections() {
    XCTAssertEqual(ConsoleView.normalizedSelection(.messages, experienceMode: .full), .messages)
    XCTAssertEqual(ConsoleView.normalizedSelection(.drafts, experienceMode: .full), .drafts)
    XCTAssertEqual(ConsoleView.normalizedSelection(.tool("wrapped"), experienceMode: .full), .tool("wrapped"))
    XCTAssertEqual(ConsoleView.normalizedSelection(nil, experienceMode: .full), .messages)
  }

  func test_messagesIsFirstLabInFullMode() {
    let tools = ConsoleView.toolsForExperienceMode(.full)
    XCTAssertEqual(tools.first?.id, "messages")
    XCTAssertEqual(tools.first?.item, .messages)
    XCTAssertEqual(tools.dropFirst().first?.id, "wrapped")
  }

  func test_wrappedOnlyModeHidesMessagesLab() {
    let tools = ConsoleView.toolsForExperienceMode(.textingWrappedOnly)
    XCTAssertEqual(tools.map(\.id), ["wrapped"])
    XCTAssertNil(ConsoleView.labTool(for: .messages, tools: tools))
    XCTAssertNotNil(ConsoleView.labTool(for: .tool("wrapped"), tools: tools))
  }

  func test_labToolLookupMapsMessagesSelectionToMessagesLab() {
    let tool = ConsoleView.labTool(for: .messages)
    XCTAssertEqual(tool?.id, "messages")
    XCTAssertEqual(tool?.title, "Messages")
  }

  func test_themedLabsRegisterCustomIntros() {
    // Registry contract for the themed first-open intros: every lab with a
    // file-private theme kit ships a custom intro factory; Messages and
    // Texting Voice stay on the generic DS sheet (no hero surface to match).
    let themed: Set<String> = ["wrapped", "dontGhost", "birthdays", "keepTabs", "workPersonal", "eq", "textingAnalytics", "babysitter"]
    let actions = LabIntroActions(onContinue: {}, onCancel: {})
    for tool in ToolRegistry.all {
      if themed.contains(tool.id) {
        let makeIntroView = tool.makeIntroView
        XCTAssertNotNil(makeIntroView, "\(tool.id) must register a themed intro")
        // The factory must produce a view, not trap (construction only — no render).
        _ = makeIntroView?(actions)
      } else {
        XCTAssertNil(tool.makeIntroView, "\(tool.id) should use the generic intro sheet")
      }
    }
  }

  func test_mainConsoleInjectionIncludesMessageNotificationController() throws {
    let testFileURL = URL(fileURLWithPath: #filePath)
    let packageRoot = testFileURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = try String(contentsOf: packageRoot.appendingPathComponent("Sources/MessagesForAIMenu/App.swift"))
    let consoleScene = try XCTUnwrap(appSource.range(of: "Window(WindowTitle.main, id: WindowID.main)"))
    let settingsScene = try XCTUnwrap(appSource.range(of: "Window(WindowTitle.settings, id: WindowID.settings)"))
    let mainWindowSource = appSource[consoleScene.lowerBound..<settingsScene.lowerBound]

    XCTAssertTrue(mainWindowSource.contains(".environmentObject(appDelegate.messageNotifications)"))
  }
}
