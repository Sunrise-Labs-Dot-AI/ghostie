import XCTest
@testable import MessagesForAIMenu

/// Covers the pure window-match predicate behind WindowFocus.bringToFront.
/// Regression for the Ghostie shell: ConsoleWindowChrome sets the console
/// window's title to "" (hidden-titlebar look), and SwiftUI assigns scene
/// windows identifiers like "main-AppWindow-1" — the old exact-id-or-title
/// match found nothing, so the console stopped coming to the front.
final class WindowFocusTests: XCTestCase {
    func test_matches_exactIdentifier() {
        XCTAssertTrue(WindowFocus.matches(
            identifier: "main", windowTitle: "", id: "main", title: "Ghostie"
        ))
    }

    func test_matches_swiftUISceneIdentifierSuffix() {
        // What SwiftUI actually assigns to a `Window(id: "main")` scene.
        XCTAssertTrue(WindowFocus.matches(
            identifier: "main-AppWindow-1", windowTitle: "", id: "main", title: "Ghostie"
        ))
    }

    func test_matches_titleFallbackWhenIdentifierMissing() {
        XCTAssertTrue(WindowFocus.matches(
            identifier: nil, windowTitle: "Ghostie", id: "main", title: "Ghostie"
        ))
    }

    func test_doesNotMatch_emptyTitleAgainstEmptyChromeTitle() {
        // A chrome-stripped window has title "" — that must never count as a
        // title match, even if the expected title were ever empty.
        XCTAssertFalse(WindowFocus.matches(
            identifier: "settings-AppWindow-1", windowTitle: "", id: "main", title: ""
        ))
    }

    func test_doesNotMatch_unrelatedIdentifierOrTitle() {
        XCTAssertFalse(WindowFocus.matches(
            identifier: "settings-AppWindow-1",
            windowTitle: "Ghostie Settings",
            id: "main",
            title: "Ghostie"
        ))
    }

    func test_doesNotMatch_identifierThatMerelySharesAPrefixWithoutSeparator() {
        // "maintenance" must not match id "main" — the suffix rule requires
        // the "<id>-" separator.
        XCTAssertFalse(WindowFocus.matches(
            identifier: "maintenance", windowTitle: "", id: "main", title: "Ghostie"
        ))
    }
}
