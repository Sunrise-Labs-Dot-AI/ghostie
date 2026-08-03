import XCTest
@testable import MessagesForAIMenu

/// Cover for the WhatsApp disconnect / re-authenticate flow.
///
/// The two things that must not regress:
///   1. The local wipe deletes the session and NOTHING else. It runs in the
///      same directory as the user's message history, so an over-broad rule
///      here is silent, permanent data loss.
///   2. The recovery sentinel parses compatibly in both directions, since the
///      daemon and this app ship independently and can be different versions.
final class WhatsAppSessionResetTests: XCTestCase {

  // MARK: - Wipe allowlist

  func testWipeTargetsOnlyTheSessionDatabaseAndItsSidecars() {
    XCTAssertEqual(
      Set(WhatsAppSessionReset.sessionFileNames),
      ["session.db", "session.db-wal", "session.db-shm"]
    )
  }

  /// The invariant that matters. `messages.db` is in the same directory, and
  /// (because content is wrapped with the same key as the session) it is
  /// genuinely irrecoverable if destroyed.
  func testWipeNeverTargetsUserData() {
    for preserved in WhatsAppSessionReset.preservedFileNames {
      XCTAssertFalse(
        WhatsAppSessionReset.sessionFileNames.contains(preserved),
        "\(preserved) is user data and must never be in the wipe allowlist"
      )
    }
  }

  func testMessageHistoryIsExplicitlyProtected() {
    XCTAssertTrue(WhatsAppSessionReset.preservedFileNames.contains("messages.db"))
    XCTAssertTrue(WhatsAppSessionReset.preservedFileNames.contains("drafts"))
  }

  /// The sentinel is the parked-gate. Clearing it while a broken session is
  /// still on disk restarts the crash-loop, so it must not be lumped in with
  /// the session files (which are removed first).
  func testSentinelIsSeparateFromTheSessionFiles() {
    XCTAssertFalse(WhatsAppSessionReset.sessionFileNames.contains(WhatsAppSessionReset.sentinelFileName))
    XCTAssertEqual(WhatsAppSessionReset.sentinelFileName, "LOGGED_OUT")
  }

  /// No wildcards, no directory names — an exact-filename allowlist only.
  func testWipeListContainsNoGlobsOrDirectories() {
    for name in WhatsAppSessionReset.sessionFileNames {
      XCTAssertFalse(name.contains("*"), "\(name) looks like a glob")
      XCTAssertFalse(name.hasSuffix("/"), "\(name) looks like a directory")
      XCTAssertTrue(name.hasPrefix("session.db"), "\(name) is not part of the session database")
    }
  }

  // MARK: - Recovery sentinel parsing

  func testParsesSessionUnreadableReason() {
    let state = WhatsAppRecoveryState.parse(
      "2026-08-03T04:35:31.000Z\nreason=session_unreadable\ndetail=6398 rows failed\n"
    )
    XCTAssertEqual(state.reason, .sessionUnreadable)
    XCTAssertEqual(state.detail, "6398 rows failed")
  }

  func testParsesLoggedOutReason() {
    let state = WhatsAppRecoveryState.parse("2026-08-03T04:35:31.000Z\nreason=logged_out\n")
    XCTAssertEqual(state.reason, .loggedOut)
  }

  /// Older daemons wrote a bare timestamp and this app must still recognise it
  /// as "parked", or a downgrade strands the user with no recovery route.
  func testLegacyTimestampOnlySentinelReadsAsLoggedOut() {
    let state = WhatsAppRecoveryState.parse("2026-07-20T19:45:00.000Z\n")
    XCTAssertEqual(state.reason, .loggedOut)
    XCTAssertEqual(state.detail, "")
  }

  func testUnknownReasonFallsBackToLoggedOutRatherThanFailing() {
    let state = WhatsAppRecoveryState.parse("2026-08-03T04:35:31.000Z\nreason=something_new\n")
    XCTAssertEqual(state.reason, .loggedOut)
  }

  func testEmptySentinelStillCountsAsParked() {
    XCTAssertEqual(WhatsAppRecoveryState.parse("").reason, .loggedOut)
  }

  func testDetailCarryingAnEqualsSignSurvivesIntact() {
    let state = WhatsAppRecoveryState.parse("ts\nreason=session_unreadable\ndetail=key=value pairs\n")
    XCTAssertEqual(state.detail, "key=value pairs")
  }

  // MARK: - Outcome reporting

  func testFailureOutcomeCarriesAUserFacingMessage() {
    let outcome = WhatsAppSessionReset.Outcome.failed("could not stop the service")
    guard case .failed(let message) = outcome else {
      return XCTFail("expected .failed")
    }
    XCTAssertFalse(message.isEmpty)
  }

  func testSuccessOutcomesAreDistinguishable() {
    XCTAssertNotEqual(WhatsAppSessionReset.Outcome.viaDaemon, .viaLocalWipe)
  }
}
