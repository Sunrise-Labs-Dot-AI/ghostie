import Foundation

/// Launch-time migration for the Messages for AI → Ghostie rename.
///
/// Why this exists: the .app's on-disk path is not stable across the rename.
/// Sparkle 2 installs updates at the EXISTING bundle path
/// (Autoupdate/SUInstaller.m resolves `installationPath` to `host.bundlePath`;
/// SPARKLE_NORMALIZE_INSTALLED_APPLICATION_NAME ships as 0), so an auto-updated
/// user keeps "/Applications/Messages for AI.app" with Ghostie contents
/// inside. A user who reinstalls from the new dmg instead moves to
/// "/Applications/Ghostie.app" while their Claude Desktop config still points
/// at the old root. Either way, mcpServers `command` paths and the
/// ~/bin/imessage-drafts-mcp backward-compat symlink can reference a bundle
/// root that is NOT the one currently running, and every health check (and
/// every Claude tool call through the stale path) breaks.
///
/// What it does, conservatively:
///   1. Rewrites mcpServers entries whose `command` sits under a KNOWN
///      previous install root AND names one of OUR MCP binaries, pointing
///      them at the running bundle's Contents/MacOS — but only when the
///      replacement binary actually exists. Foreign entries are never
///      touched.
///   2. Re-points the ~/bin compat symlinks the install scripts create when
///      they dangle or aim at a known stale root. It never creates new
///      symlinks (fresh installs get them from install.sh).
///
/// The rewrite core is a pure function (config JSON in → JSON out) so the
/// migration logic has unit coverage without filesystem fixtures.
enum ClaudeConfigMigrator {
    /// Our MCP binary basenames — the only commands we will ever rewrite.
    /// Includes the generalized facade (`ghostie-mcp`, Claude config key
    /// "ghostie") alongside the transport MCPs.
    static let managedBinaryNames: Set<String> = [
        "ghostie-mcp",
        "imessage-drafts-mcp",
        "whatsapp-drafts-mcp",
    ]

    /// Every bundle-binary root an installer or release has ever written:
    /// both app names (pre/post rename) under both supported install roots
    /// (/Applications and ~/Applications, per scripts/install-release.sh and
    /// menubar/scripts/dev-install.sh's INSTALL_ROOT override).
    static func knownBundleBinaryPrefixes(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let appNames = ["Messages for AI.app", "Ghostie.app"]
        let roots = ["/Applications", home.appendingPathComponent("Applications").path]
        return roots.flatMap { root in
            appNames.map { "\(root)/\($0)/Contents/MacOS/" }
        }
    }

    // MARK: - Pure rewrite core

    /// Rewrite stale mcpServers commands to `currentPrefix`. Pure: document
    /// in → migrated document + changed keys out; nil when nothing needed
    /// migration.
    ///
    /// An entry is rewritten iff ALL of:
    ///   - its `command` starts with one of `stalePrefixes` (exact string
    ///     prefix — look-alike roots like "/tmp/Messages for AI.app/..."
    ///     never match),
    ///   - it is NOT already under `currentPrefix`,
    ///   - its basename is one of `managedBinaryNames` (foreign servers are
    ///     never touched, whatever their key is named),
    ///   - the replacement `currentPrefix + basename` passes `targetExists`
    ///     (we never write a path we can't prove — that's the exact failure
    ///     mode this migration repairs).
    /// All other fields of the entry (args, env, ...) are preserved.
    static func migrate(
        document: [String: Any],
        currentPrefix: String,
        stalePrefixes: [String],
        targetExists: (String) -> Bool
    ) -> (document: [String: Any], migratedKeys: [String])? {
        guard let servers = document["mcpServers"] as? [String: Any] else { return nil }

        var newServers = servers
        var migratedKeys: [String] = []

        for (key, value) in servers {
            guard var entry = value as? [String: Any],
                  let command = entry["command"] as? String
            else { continue }
            guard !command.hasPrefix(currentPrefix) else { continue }
            guard stalePrefixes.contains(where: { command.hasPrefix($0) }) else { continue }

            let basename = (command as NSString).lastPathComponent
            guard managedBinaryNames.contains(basename) else { continue }

            let replacement = currentPrefix + basename
            guard targetExists(replacement) else { continue }

            entry["command"] = replacement
            newServers[key] = entry
            migratedKeys.append(key)
        }

        guard !migratedKeys.isEmpty else { return nil }
        var newDocument = document
        newDocument["mcpServers"] = newServers
        return (newDocument, migratedKeys.sorted())
    }

    /// Pure decision for the symlink refresh: should a compat symlink whose
    /// current destination is `destination` be re-pointed at `target`?
    /// Yes when it isn't already correct AND it is provably ours-and-stale:
    /// either it aims under a known previous install root, or it dangles.
    /// A symlink the user pointed somewhere else that still resolves is left
    /// alone.
    static func shouldRetarget(
        destination: String,
        target: String,
        stalePrefixes: [String],
        destinationExists: Bool
    ) -> Bool {
        guard destination != target else { return false }
        if stalePrefixes.contains(where: { destination.hasPrefix($0) }) { return true }
        return !destinationExists
    }

    // MARK: - Launch entry points

    /// Run the config rewrite against the live Claude Desktop config.
    /// Returns the migrated mcpServers keys ([] when nothing changed or the
    /// config is absent/unreadable — migration is best-effort and must never
    /// block launch).
    @discardableResult
    static func runAtLaunch(
        configPath: URL = ClaudeConfigWriter.configPath,
        currentPrefix: String = HealthChecks.defaultBundleBinaryPrefix,
        knownPrefixes: [String]? = nil
    ) -> [String] {
        let stalePrefixes = (knownPrefixes ?? knownBundleBinaryPrefixes())
            .filter { $0 != currentPrefix }

        guard let data = try? Data(contentsOf: configPath),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let document = raw as? [String: Any]
        else { return [] }

        guard let (migrated, keys) = migrate(
            document: document,
            currentPrefix: currentPrefix,
            stalePrefixes: stalePrefixes,
            targetExists: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else { return [] }

        do {
            try ClaudeConfigWriter.writeDocument(migrated, to: configPath, replacingExisting: true)
            return keys
        } catch {
            return []
        }
    }

    /// Re-point the ~/bin symlinks the install scripts create
    /// (~/bin/ghostie-mcp + the backward-compat ~/bin/imessage-drafts-mcp)
    /// at the running bundle when they dangle or aim at a stale install
    /// root. Returns the names re-pointed.
    @discardableResult
    static func refreshCompatSymlinks(
        binDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin"),
        currentPrefix: String = HealthChecks.defaultBundleBinaryPrefix,
        knownPrefixes: [String]? = nil
    ) -> [String] {
        let stalePrefixes = (knownPrefixes ?? knownBundleBinaryPrefixes())
            .filter { $0 != currentPrefix }
        let fm = FileManager.default
        var refreshed: [String] = []

        for name in managedBinaryNames.sorted() {
            let linkURL = binDirectory.appendingPathComponent(name)
            // destinationOfSymbolicLink throws for anything that isn't a
            // symlink — regular files (or nothing) at the path are left alone.
            guard var destination = try? fm.destinationOfSymbolicLink(atPath: linkURL.path)
            else { continue }
            // Installers write absolute destinations; resolve a relative one
            // against the link's directory so the existence check is honest.
            if !destination.hasPrefix("/") {
                destination = binDirectory.appendingPathComponent(destination).path
            }

            let target = currentPrefix + name
            guard shouldRetarget(
                destination: destination,
                target: target,
                stalePrefixes: stalePrefixes,
                destinationExists: fm.fileExists(atPath: destination)
            ) else { continue }
            // Only swing the link if the replacement is real.
            guard fm.isExecutableFile(atPath: target) else { continue }

            do {
                try fm.removeItem(at: linkURL)
                try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
                refreshed.append(name)
            } catch {
                continue
            }
        }
        return refreshed
    }
}
