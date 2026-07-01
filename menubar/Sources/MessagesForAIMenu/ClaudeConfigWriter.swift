import Foundation

/// Outcome of attempting to wire this app's MCP servers into
/// ~/Library/Application Support/Claude/claude_desktop_config.json.
enum ClaudeConfigWriteResult: Equatable {
    /// Added these mcpServers keys to the config. Pre-existing config
    /// content was preserved.
    case wrote(addedKeys: [String])
    /// All requested entries were already present and pointed at the
    /// correct commands. No write happened.
    case alreadyWired
    /// One or more entries exist under our key names but point at
    /// different commands. We refused to overwrite — the user might
    /// have a custom version they care about.
    case conflict(keys: [String])
    /// Config file exists but isn't valid JSON. We won't blindly
    /// overwrite — the user has unrelated content to preserve.
    case parseError
    /// Read/write failed (permissions, disk full, etc).
    case ioError(String)
}

/// Writes Ghostie's MCP server entries into Claude Desktop's
/// config. The menubar is unsandboxed and has FDA, so this works
/// without the Cowork-sandbox restrictions that block Claude Desktop's
/// agent mode from editing its own config directly. The button this
/// backs in the walkthrough replaces the "paste a prompt into Cowork"
/// flow, which is fragile under Cowork's current capabilities.
struct ClaudeConfigWriter {
    /// Canonical config location for Claude Desktop on macOS.
    static let configPath: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

    /// Wire the given enabled transports into the config. Preserves
    /// every other top-level key in the document. Uses atomic temp+
    /// rename so a partial write can never corrupt the user's existing
    /// config.
    ///
    /// `forceOverwrite=true` overrides the conflict check — used when
    /// the user explicitly opts in via a second click.
    static func wire(
        transports: [Platform],
        bundlePrefix: String = HealthChecks.defaultBundleBinaryPrefix,
        forceOverwrite: Bool = false
    ) -> ClaudeConfigWriteResult {
        // What we want to add.
        var wanted: [(key: String, command: String)] = []
        wanted.append(("ghostie", bundlePrefix + "ghostie-mcp"))
        if transports.contains(.imessage) {
            wanted.append(("imessage-drafts", bundlePrefix + "imessage-drafts-mcp"))
        }
        if transports.contains(.whatsapp) {
            wanted.append(("whatsapp-drafts", bundlePrefix + "whatsapp-drafts-mcp"))
        }

        // Read the existing doc (or treat as empty if absent).
        var doc: [String: Any] = [:]
        let fileExisted = FileManager.default.fileExists(atPath: configPath.path)
        if fileExisted {
            guard let data = try? Data(contentsOf: configPath) else {
                return .ioError("Couldn't read \(configPath.path)")
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .parseError
            }
            doc = parsed
        }

        var servers = (doc["mcpServers"] as? [String: Any]) ?? [:]
        var added: [String] = []
        var conflicts: [String] = []

        for (key, command) in wanted {
            if let existing = servers[key] as? [String: Any] {
                if existing["command"] as? String == command {
                    continue
                } else if forceOverwrite {
                    servers[key] = ["command": command]
                    added.append(key)
                } else {
                    conflicts.append(key)
                    continue
                }
            } else {
                servers[key] = ["command": command]
                added.append(key)
            }
        }

        if !conflicts.isEmpty {
            return .conflict(keys: conflicts)
        }
        if added.isEmpty {
            return .alreadyWired
        }

        doc["mcpServers"] = servers

        do {
            try writeDocument(doc, to: configPath, replacingExisting: fileExisted)
            return .wrote(addedKeys: added)
        } catch {
            return .ioError(error.localizedDescription)
        }
    }

    /// Atomic config write shared by `wire` and `ClaudeConfigMigrator`:
    /// create the directory if needed, write to a sibling temp file, then
    /// rename. Set 0600 perms so the (potentially-sensitive) config keys
    /// stay user-only-readable.
    static func writeDocument(
        _ doc: [String: Any],
        to configPath: URL,
        replacingExisting fileExisted: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: configPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: doc,
            options: [.prettyPrinted, .sortedKeys]
        )
        let tmpPath = configPath.deletingLastPathComponent()
            .appendingPathComponent(".\(configPath.lastPathComponent).tmp.\(getpid())")
        try data.write(to: tmpPath, options: .atomic)
        if fileExisted {
            _ = try FileManager.default.replaceItemAt(configPath, withItemAt: tmpPath)
        } else {
            try FileManager.default.moveItem(at: tmpPath, to: configPath)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configPath.path
        )
    }
}
