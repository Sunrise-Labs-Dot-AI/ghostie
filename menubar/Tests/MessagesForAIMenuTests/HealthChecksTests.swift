import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Covers the pure-function HealthChecks primitives the walkthrough +
/// Status pane depend on. SecCode-backed paths (codesignIdentifier,
/// verifyRunningPid) require a real signed binary at runtime; those
/// branches are exercised by manual QA against the dev-installed .app
/// rather than synthetic fixtures here.
final class HealthChecksTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-checks-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmpDir = tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - binaryExists

    func test_binaryExists_returnsTrueForRegularFileUnderBundlePrefix() throws {
        let bundlePrefix = tmpDir.path + "/"
        let binary = tmpDir.appendingPathComponent("test-binary")
        FileManager.default.createFile(atPath: binary.path, contents: Data([0x7F, 0x45, 0x4C, 0x46])) // ELF-ish

        let checks = HealthChecks(bundleBinaryPrefix: bundlePrefix)
        XCTAssertTrue(checks.binaryExists(at: binary.path))
    }

    func test_binaryExists_returnsFalseForMissingFile() {
        let checks = HealthChecks(bundleBinaryPrefix: tmpDir.path + "/")
        XCTAssertFalse(checks.binaryExists(at: tmpDir.appendingPathComponent("nope").path))
    }

    func test_binaryExists_returnsFalseForDirectory() throws {
        let bundlePrefix = tmpDir.path + "/"
        let subdir = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let checks = HealthChecks(bundleBinaryPrefix: bundlePrefix)
        XCTAssertFalse(checks.binaryExists(at: subdir.path))
    }

    func test_binaryExists_rejectsSymlinkEscapingBundle() throws {
        // Outside-bundle target.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("evil-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outside.path, contents: Data([0xFF]))
        defer { try? FileManager.default.removeItem(at: outside) }

        // Symlink inside the bundle pointing at the outside file.
        let bundlePrefix = tmpDir.path + "/"
        let symlinkPath = tmpDir.appendingPathComponent("bait")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)

        let checks = HealthChecks(bundleBinaryPrefix: bundlePrefix)
        // The symlink resolves outside the bundle → reject.
        XCTAssertFalse(checks.binaryExists(at: symlinkPath.path),
                       "symlink targets outside the bundle prefix must not pass")
    }

    func test_binaryExists_allowsSymlinkStayingInsideBundle() throws {
        let bundlePrefix = tmpDir.path + "/"
        let real = tmpDir.appendingPathComponent("real")
        FileManager.default.createFile(atPath: real.path, contents: Data([0x01]))
        let link = tmpDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let checks = HealthChecks(bundleBinaryPrefix: bundlePrefix)
        XCTAssertTrue(checks.binaryExists(at: link.path),
                      "symlink whose target stays under bundlePrefix is fine")
    }

    // MARK: - codesignIdentifier

    func test_codesignIdentifier_rejectsPathOutsideBundle() {
        // Even if the path points at a valid signed binary (like /bin/ls)
        // it must return nil when outside the bundle prefix.
        let checks = HealthChecks(bundleBinaryPrefix: tmpDir.path + "/")
        XCTAssertNil(checks.codesignIdentifier(of: "/bin/ls"))
    }

    func test_codesignIdentifier_returnsNilForMissingFile() {
        let checks = HealthChecks(bundleBinaryPrefix: tmpDir.path + "/")
        XCTAssertNil(checks.codesignIdentifier(of: tmpDir.appendingPathComponent("nope").path))
    }

    func test_codesignIdentifier_returnsNilForUnsignedFile() throws {
        // A random file under the bundle prefix; not codesign-valid.
        // Strict-validate should refuse and we return nil.
        let bundlePrefix = tmpDir.path + "/"
        let file = tmpDir.appendingPathComponent("unsigned-binary")
        FileManager.default.createFile(atPath: file.path, contents: Data(count: 128))

        let checks = HealthChecks(bundleBinaryPrefix: bundlePrefix)
        XCTAssertNil(checks.codesignIdentifier(of: file.path))
    }

    // MARK: - chatDbAccessState

    func test_chatDbAccessState_okWhenFileIsReadable() throws {
        // A readable tmp file stands in for chat.db. open(O_RDONLY)
        // succeeds → .ok. (The permission_denied branch is a TCC outcome
        // that can't be synthesized without Full Disk Access semantics;
        // it's exercised by manual QA against the dev-installed .app.)
        let file = tmpDir.appendingPathComponent("chat.db")
        FileManager.default.createFile(atPath: file.path, contents: Data([0x53, 0x51, 0x4C]))

        let checks = HealthChecks(chatDbPath: file.path)
        XCTAssertEqual(checks.chatDbAccessState(), .ok)
    }

    func test_chatDbAccessState_notFoundWhenFileMissing() {
        let missing = tmpDir.appendingPathComponent("nope/chat.db").path
        let checks = HealthChecks(chatDbPath: missing)
        XCTAssertEqual(checks.chatDbAccessState(), .notFound)
    }

    // MARK: - claudeDesktopConfigState

    func test_claudeDesktopConfigState_fileAbsent() {
        let configPath = tmpDir.appendingPathComponent("nonexistent.json")
        let checks = HealthChecks(claudeDesktopConfigPath: configPath)
        XCTAssertEqual(checks.claudeDesktopConfigState(), .fileAbsent)
    }

    func test_claudeDesktopConfigState_parseError() throws {
        let configPath = tmpDir.appendingPathComponent("config.json")
        try "{this is not json".write(to: configPath, atomically: true, encoding: .utf8)
        let checks = HealthChecks(claudeDesktopConfigPath: configPath)
        XCTAssertEqual(checks.claudeDesktopConfigState(), .parseError)
    }

    func test_claudeDesktopConfigState_notFound_whenNoMcpServersKey() throws {
        let configPath = tmpDir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configPath)
        let checks = HealthChecks(claudeDesktopConfigPath: configPath)
        XCTAssertEqual(checks.claudeDesktopConfigState(), .notFound)
    }

    func test_claudeDesktopConfigState_notFound_whenNoEntryMatchesPrefix() throws {
        let configPath = tmpDir.appendingPathComponent("config.json")
        let doc: [String: Any] = [
            "mcpServers": [
                "some-other-server": ["command": "/usr/local/bin/other-mcp"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: configPath)
        let checks = HealthChecks(claudeDesktopConfigPath: configPath)
        XCTAssertEqual(checks.claudeDesktopConfigState(), .notFound)
    }

    func test_claudeDesktopConfigState_found_whenAnyEntryMatchesPrefix() throws {
        let configPath = tmpDir.appendingPathComponent("config.json")
        let doc: [String: Any] = [
            "mcpServers": [
                "imessage-drafts": [
                    "command": "/Applications/Ghostie.app/Contents/MacOS/imessage-drafts-mcp"
                ],
                "some-other": ["command": "/usr/bin/other"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: configPath)
        let checks = HealthChecks(claudeDesktopConfigPath: configPath)
        XCTAssertEqual(checks.claudeDesktopConfigState(), .found)
    }

    func test_claudeDesktopConfigState_ignoresMaliciouslyCraftedCommandPrefix() throws {
        // An entry whose command STARTS WITH the prefix is legitimate.
        // But an entry whose command is just similar-looking (different
        // prefix) must NOT match — hasPrefix is strict.
        let configPath = tmpDir.appendingPathComponent("config.json")
        let doc: [String: Any] = [
            "mcpServers": [
                "look-alike": ["command": "/tmp/Messages for AI.app/Contents/MacOS/imessage-drafts-mcp"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: configPath)
        let checks = HealthChecks(claudeDesktopConfigPath: configPath)
        XCTAssertEqual(checks.claudeDesktopConfigState(), .notFound,
                       "a command under /tmp/... must not be accepted as a bundle binary")
    }
}
