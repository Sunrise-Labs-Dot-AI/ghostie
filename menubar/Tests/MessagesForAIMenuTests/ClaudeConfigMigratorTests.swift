import Foundation
import XCTest
@testable import MessagesForAIMenu

/// Covers the rename-migration logic (Messages for AI → Ghostie):
/// the pure config rewrite (JSON document in → JSON document out), the
/// symlink-retarget decision, and the filesystem entry points against a
/// tmpdir. Mirrors the HealthChecksTests injectable-path style.
final class ClaudeConfigMigratorTests: XCTestCase {
    var tmpDir: URL!

    let currentPrefix = "/Applications/Ghostie.app/Contents/MacOS/"
    let oldPrefix = "/Applications/Messages for AI.app/Contents/MacOS/"
    let homeOldPrefix = "/Users/u/Applications/Messages for AI.app/Contents/MacOS/"

    var stalePrefixes: [String] { [oldPrefix, homeOldPrefix] }

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-migrator-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmpDir = tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - migrate (pure)

    func test_migrate_rewritesStaleIMessageEntry() throws {
        let document: [String: Any] = [
            "mcpServers": [
                "imessage-drafts": ["command": oldPrefix + "imessage-drafts-mcp"],
            ],
        ]

        let result = ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        )

        let migrated = try XCTUnwrap(result)
        XCTAssertEqual(migrated.migratedKeys, ["imessage-drafts"])
        let servers = try XCTUnwrap(migrated.document["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["imessage-drafts"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, currentPrefix + "imessage-drafts-mcp")
    }

    func test_migrate_rewritesBothManagedEntries_acrossInstallRoots() throws {
        let document: [String: Any] = [
            "mcpServers": [
                "imessage-drafts": ["command": oldPrefix + "imessage-drafts-mcp"],
                "whatsapp-drafts": ["command": homeOldPrefix + "whatsapp-drafts-mcp"],
            ],
        ]

        let result = try XCTUnwrap(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))

        XCTAssertEqual(result.migratedKeys, ["imessage-drafts", "whatsapp-drafts"])
        let servers = try XCTUnwrap(result.document["mcpServers"] as? [String: Any])
        XCTAssertEqual(
            (servers["whatsapp-drafts"] as? [String: Any])?["command"] as? String,
            currentPrefix + "whatsapp-drafts-mcp"
        )
    }

    func test_migrate_rewritesStaleGhostieFacadeEntry() throws {
        let document: [String: Any] = [
            "mcpServers": [
                "ghostie": ["command": oldPrefix + "ghostie-mcp"],
            ],
        ]

        let result = try XCTUnwrap(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))

        XCTAssertEqual(result.migratedKeys, ["ghostie"])
        let servers = try XCTUnwrap(result.document["mcpServers"] as? [String: Any])
        XCTAssertEqual(
            (servers["ghostie"] as? [String: Any])?["command"] as? String,
            currentPrefix + "ghostie-mcp"
        )
    }

    func test_migrate_returnsNilWhenAlreadyCurrent() {
        let document: [String: Any] = [
            "mcpServers": [
                "imessage-drafts": ["command": currentPrefix + "imessage-drafts-mcp"],
            ],
        ]

        XCTAssertNil(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))
    }

    func test_migrate_neverTouchesForeignServers() {
        // Foreign command paths — even ones that LOOK like ours but sit
        // under a non-install root — must survive untouched.
        let document: [String: Any] = [
            "mcpServers": [
                "other-tool": ["command": "/usr/local/bin/other-mcp"],
                "look-alike": ["command": "/tmp/Messages for AI.app/Contents/MacOS/imessage-drafts-mcp"],
            ],
        ]

        XCTAssertNil(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))
    }

    func test_migrate_skipsForeignBinaryUnderStaleRoot() {
        // A command under our old root whose basename is NOT one of our MCP
        // binaries (e.g. someone pointed a server at the daemon or at a
        // custom tool inside the bundle) is left alone.
        let document: [String: Any] = [
            "mcpServers": [
                "weird": ["command": oldPrefix + "some-other-binary"],
            ],
        ]

        XCTAssertNil(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))
    }

    func test_migrate_skipsWhenReplacementBinaryMissing() {
        // Never write a path we can't prove exists — that is the exact
        // failure mode this migration repairs.
        let document: [String: Any] = [
            "mcpServers": [
                "imessage-drafts": ["command": oldPrefix + "imessage-drafts-mcp"],
            ],
        ]

        XCTAssertNil(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in false }
        ))
    }

    func test_migrate_rewritesCustomKeyNamesPointingAtOurBinary() throws {
        // The user renamed the server key but the command is unmistakably
        // ours (old install root + our basename) — still migrated.
        let document: [String: Any] = [
            "mcpServers": [
                "my-imessages": ["command": oldPrefix + "imessage-drafts-mcp"],
            ],
        ]

        let result = try XCTUnwrap(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))
        XCTAssertEqual(result.migratedKeys, ["my-imessages"])
    }

    func test_migrate_preservesEntrySiblingFieldsAndOtherTopLevelKeys() throws {
        let document: [String: Any] = [
            "mcpServers": [
                "imessage-drafts": [
                    "command": oldPrefix + "imessage-drafts-mcp",
                    "args": ["--verbose"],
                    "env": ["FOO": "bar"],
                ],
            ],
            "globalShortcut": "Cmd+Shift+Space",
        ]

        let result = try XCTUnwrap(ClaudeConfigMigrator.migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))

        XCTAssertEqual(result.document["globalShortcut"] as? String, "Cmd+Shift+Space")
        let servers = try XCTUnwrap(result.document["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["imessage-drafts"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, currentPrefix + "imessage-drafts-mcp")
        XCTAssertEqual(entry["args"] as? [String], ["--verbose"])
        XCTAssertEqual(entry["env"] as? [String: String], ["FOO": "bar"])
    }

    func test_migrate_returnsNilWithoutMcpServersKey() {
        XCTAssertNil(ClaudeConfigMigrator.migrate(
            document: ["someOtherKey": true],
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { _ in true }
        ))
    }

    // MARK: - shouldRetarget (pure)

    func test_shouldRetarget_falseWhenAlreadyCorrect() {
        XCTAssertFalse(ClaudeConfigMigrator.shouldRetarget(
            destination: currentPrefix + "imessage-drafts-mcp",
            target: currentPrefix + "imessage-drafts-mcp",
            stalePrefixes: stalePrefixes,
            destinationExists: true
        ))
    }

    func test_shouldRetarget_trueForStaleRootEvenIfTargetStillExists() {
        // Old bundle still on disk (e.g. both bundles present) — the running
        // bundle is canonical, retarget anyway.
        XCTAssertTrue(ClaudeConfigMigrator.shouldRetarget(
            destination: oldPrefix + "imessage-drafts-mcp",
            target: currentPrefix + "imessage-drafts-mcp",
            stalePrefixes: stalePrefixes,
            destinationExists: true
        ))
    }

    func test_shouldRetarget_trueForDanglingDestination() {
        XCTAssertTrue(ClaudeConfigMigrator.shouldRetarget(
            destination: "/somewhere/else/imessage-drafts-mcp",
            target: currentPrefix + "imessage-drafts-mcp",
            stalePrefixes: stalePrefixes,
            destinationExists: false
        ))
    }

    func test_shouldRetarget_falseForUserCustomLinkThatResolves() {
        // The user pointed the symlink at their own working binary — not
        // ours to rewrite.
        XCTAssertFalse(ClaudeConfigMigrator.shouldRetarget(
            destination: "/opt/custom/imessage-drafts-mcp",
            target: currentPrefix + "imessage-drafts-mcp",
            stalePrefixes: stalePrefixes,
            destinationExists: true
        ))
    }

    // MARK: - runAtLaunch (filesystem)

    func test_runAtLaunch_rewritesConfigFileOnDisk() throws {
        // Fake current bundle with an executable MCP binary.
        let bundleBin = tmpDir.appendingPathComponent("Ghostie.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bundleBin, withIntermediateDirectories: true)
        let prefix = bundleBin.path + "/"
        let mcp = bundleBin.appendingPathComponent("imessage-drafts-mcp")
        FileManager.default.createFile(
            atPath: mcp.path,
            contents: Data([0x01]),
            attributes: [.posixPermissions: 0o755]
        )

        let configPath = tmpDir.appendingPathComponent("claude_desktop_config.json")
        let document: [String: Any] = [
            "mcpServers": [
                "imessage-drafts": ["command": oldPrefix + "imessage-drafts-mcp"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: configPath)

        let keys = ClaudeConfigMigrator.runAtLaunch(
            configPath: configPath,
            currentPrefix: prefix,
            knownPrefixes: [oldPrefix, prefix]
        )

        XCTAssertEqual(keys, ["imessage-drafts"])
        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configPath)
        ) as? [String: Any]
        let servers = try XCTUnwrap(written?["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["imessage-drafts"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, prefix + "imessage-drafts-mcp")
    }

    func test_runAtLaunch_noopWhenConfigAbsent() {
        let keys = ClaudeConfigMigrator.runAtLaunch(
            configPath: tmpDir.appendingPathComponent("nonexistent.json"),
            currentPrefix: currentPrefix,
            knownPrefixes: [oldPrefix]
        )
        XCTAssertEqual(keys, [])
    }

    func test_runAtLaunch_noopOnUnparseableConfig() throws {
        let configPath = tmpDir.appendingPathComponent("config.json")
        try "{not json".write(to: configPath, atomically: true, encoding: .utf8)
        let keys = ClaudeConfigMigrator.runAtLaunch(
            configPath: configPath,
            currentPrefix: currentPrefix,
            knownPrefixes: [oldPrefix]
        )
        XCTAssertEqual(keys, [])
        // And the malformed file is left byte-identical for the user to fix.
        XCTAssertEqual(try String(contentsOf: configPath, encoding: .utf8), "{not json")
    }

    // MARK: - refreshCompatSymlinks (filesystem)

    func test_refreshCompatSymlinks_repointsDanglingLink() throws {
        let binDir = tmpDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let bundleBin = tmpDir.appendingPathComponent("Ghostie.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bundleBin, withIntermediateDirectories: true)
        let prefix = bundleBin.path + "/"
        FileManager.default.createFile(
            atPath: prefix + "imessage-drafts-mcp",
            contents: Data([0x01]),
            attributes: [.posixPermissions: 0o755]
        )

        // Symlink pointing at the removed old bundle (dangling).
        let link = binDir.appendingPathComponent("imessage-drafts-mcp")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: oldPrefix + "imessage-drafts-mcp"
        )

        let refreshed = ClaudeConfigMigrator.refreshCompatSymlinks(
            binDirectory: binDir,
            currentPrefix: prefix,
            knownPrefixes: [oldPrefix, prefix]
        )

        XCTAssertEqual(refreshed, ["imessage-drafts-mcp"])
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            prefix + "imessage-drafts-mcp"
        )
    }

    func test_refreshCompatSymlinks_createsNothingWhenLinkAbsent() throws {
        let binDir = tmpDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let refreshed = ClaudeConfigMigrator.refreshCompatSymlinks(
            binDirectory: binDir,
            currentPrefix: currentPrefix,
            knownPrefixes: [oldPrefix]
        )

        XCTAssertEqual(refreshed, [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: binDir.appendingPathComponent("imessage-drafts-mcp").path
        ))
    }

    func test_refreshCompatSymlinks_leavesRegularFileAlone() throws {
        let binDir = tmpDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let file = binDir.appendingPathComponent("imessage-drafts-mcp")
        FileManager.default.createFile(atPath: file.path, contents: Data([0xAB]))

        let refreshed = ClaudeConfigMigrator.refreshCompatSymlinks(
            binDirectory: binDir,
            currentPrefix: currentPrefix,
            knownPrefixes: [oldPrefix]
        )

        XCTAssertEqual(refreshed, [])
        XCTAssertEqual(try Data(contentsOf: file), Data([0xAB]))
    }
}
