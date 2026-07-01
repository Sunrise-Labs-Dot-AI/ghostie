import Foundation
import Security

/// Result of inspecting the Claude Desktop MCP config for one of our binaries.
/// Raw extracted command strings are NEVER surfaced to the UI — the enum case
/// is the only thing callers see. Reason: claude_desktop_config.json is
/// writable by any local process / Claude Desktop plugin; a crafted entry's
/// `command` value could be malicious, so we expose only the boolean
/// did-we-find-our-prefix outcome.
enum ClaudeConfigState: Equatable {
    /// File parses and at least one mcpServers entry's `command` is under the
    /// expected `.app` bundle prefix.
    case found
    /// File parses but no entry references our bundle.
    case notFound
    /// `~/Library/Application Support/Claude/claude_desktop_config.json` does
    /// not exist (Claude Desktop not installed, or never opened, or moved).
    case fileAbsent
    /// File exists but JSON parse failed.
    case parseError
}

/// Result of probing whether this process can read the Messages database
/// at `~/Library/Messages/chat.db`.
///
/// Why the menu bar can stand in for the iMessage MCP: every inner Mach-O
/// (this app + `imessage-drafts-mcp`) is signed with the same codesign
/// Identifier `com.sunriselabs.messages-for-ai`, and macOS keys Full Disk
/// Access grants by codesign Identifier — so the menu bar's own ability to
/// open `chat.db` is a faithful proxy for whether the MCP has FDA, without
/// having to spawn the stdio MCP and call its `health_check` tool.
enum ChatDbAccessState: Equatable {
    /// `chat.db` opened read-only — Full Disk Access is granted.
    case ok
    /// `open()` failed with EPERM/EACCES — Full Disk Access is missing.
    case permissionDenied
    /// `chat.db` is genuinely absent (Messages never set up). Not an FDA gap.
    case notFound
    /// `open()` failed for some other reason (rare).
    case unknown
}

/// Pure health-check primitives used by the SetupWalkthrough + Status pane.
/// All functions are deterministic given filesystem state; testable via the
/// injectable `bundleBinaryPrefix` + `claudeDesktopConfigPath` fields.
struct HealthChecks {
    /// Where the RUNNING .app keeps its inner Mach-Os. Derived from
    /// `Bundle.main` instead of hardcoding the install path, because the
    /// bundle's on-disk name is not stable across the Messages for AI →
    /// Ghostie rename: Sparkle 2 installs updates at the EXISTING bundle
    /// path (Autoupdate/SUInstaller.m resolves `installationPath` to
    /// `host.bundlePath`; the rename-following alternative is gated behind
    /// SPARKLE_NORMALIZE_INSTALLED_APPLICATION_NAME, which ships as 0 in the
    /// prebuilt framework — verified at the pinned 2.9.2 revision). So a
    /// pre-rename user auto-updates IN PLACE at
    /// "/Applications/Messages for AI.app" with Ghostie contents inside.
    /// A hardcoded Ghostie.app prefix would brand that user's working MCP
    /// config as foreign and "repair" it to a nonexistent path.
    static let defaultBundleBinaryPrefix: String = {
        let bundleURL = Bundle.main.bundleURL
        // `swift test` / `swift run` execute outside a .app wrapper —
        // Bundle.main points at a bare build directory. Fall back to the
        // production install path so dev tooling keeps a sane constant.
        guard bundleURL.pathExtension == "app" else {
            return HealthChecks.fallbackBundleBinaryPrefix
        }
        return bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .path + "/"
    }()

    /// Production install path. Used only when the process isn't running
    /// from a real .app bundle (unit tests, `swift run`).
    static let fallbackBundleBinaryPrefix = "/Applications/Ghostie.app/Contents/MacOS/"

    /// The codesign Identifier every inner Mach-O shares (set by
    /// dev-install.sh / build-release.sh — see SECURITY.md).
    static let expectedSigningIdentifier = "com.sunriselabs.messages-for-ai"

    /// Expected prefix for binary paths. Tests inject a tmpdir prefix.
    var bundleBinaryPrefix: String = HealthChecks.defaultBundleBinaryPrefix

    /// Override the Claude Desktop config location for tests. Nil = system path.
    var claudeDesktopConfigPath: URL? = nil

    /// Default Messages database path. Mirrors the iMessage MCP's
    /// `CHAT_DB_PATH` (mcps/imessage-drafts/src/chatdb/open.ts).
    static let defaultChatDbPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db").path

    /// Path probed by `chatDbAccessState()`. Injectable so tests can point
    /// at a tmp file (→ .ok) or a missing path (→ .notFound) without FDA.
    var chatDbPath: String = HealthChecks.defaultChatDbPath

    // MARK: - Binary presence + codesign

    /// True iff a regular file exists at `path`, the canonicalized (symlink-
    /// resolved) path lies under `bundleBinaryPrefix`, and the path component
    /// after the prefix doesn't traverse outside the bundle (no "../" escape).
    /// Symlink-substitution defense: an attacker replacing
    /// `/Applications/Ghostie.app/Contents/MacOS/imessage-drafts-mcp`
    /// with a symlink to `~/evil` causes this to return false.
    func binaryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue
        else { return false }

        let canonical = (path as NSString).resolvingSymlinksInPath
        return canonical.hasPrefix(bundleBinaryPrefix)
    }

    /// Returns the codesign Identifier for the binary at `path`, or nil if:
    /// - the canonical path escapes `bundleBinaryPrefix` (symlink defense),
    /// - SecStaticCodeCreateWithPath fails,
    /// - SecStaticCodeCheckValidity fails (modified-in-place binary —
    ///   Gatekeeper would refuse to launch it),
    /// - SecCodeCopySigningInformation fails or returns no Identifier.
    ///
    /// The validity gate is essential. Without it, SecCodeCopySigningInformation
    /// returns the identifier embedded in the on-disk signature blob even when
    /// the binary's text has been tampered with — that would make this function
    /// a paper diagnostic rather than a real one.
    func codesignIdentifier(of path: String) -> String? {
        // Symlink/canonical-path defense.
        let canonical = (path as NSString).resolvingSymlinksInPath
        guard canonical.hasPrefix(bundleBinaryPrefix) else { return nil }

        let url = URL(fileURLWithPath: canonical) as CFURL
        var staticCodeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCodeRef) == errSecSuccess,
              let staticCode = staticCodeRef
        else { return nil }

        // Validity gate BEFORE reading signing info.
        let strictFlags = UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures)
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: strictFlags),
            nil
        )
        guard validityStatus == errSecSuccess else { return nil }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any]
        else { return nil }

        return info[kSecCodeInfoIdentifier as String] as? String
    }

    // MARK: - Running-process identity

    /// True iff the process with the given pid is signed with the expected
    /// codesign Identifier. Used by LastInvocationStore to verify a witness
    /// file's `pid` field references a trusted writer.
    ///
    /// Returns false if the pid has already exited, if SecCode lookup fails,
    /// or if the running process's identifier doesn't match.
    static func verifyRunningPid(
        _ pid: pid_t,
        expectedIdentifier: String = HealthChecks.expectedSigningIdentifier
    ) -> Bool {
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var codeRef: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef
        else { return false }

        // SecCodeCopySigningInformation's Swift overload requires SecStaticCode;
        // convert from the live SecCode via SecCodeCopyStaticCode. Same
        // underlying CFTypeRef in C, but the Swift bridge is strict.
        var staticCodeRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCodeRef) == errSecSuccess,
              let staticCode = staticCodeRef
        else { return false }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String
        else { return false }

        return identifier == expectedIdentifier
    }

    // MARK: - Full Disk Access (chat.db readability)

    /// Probe-open `chat.db` read-only and classify the outcome. TCC denies
    /// the `open()` syscall on this protected path (errno EPERM) for any
    /// process lacking Full Disk Access; a genuinely-missing database
    /// reports ENOENT. We open and immediately close a raw fd rather than
    /// going through SQLite — all we need to know is whether the kernel
    /// lets us read the bytes at all.
    func chatDbAccessState() -> ChatDbAccessState {
        let fd = open(chatDbPath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .ok
        }
        switch errno {
        case EPERM, EACCES: return .permissionDenied
        case ENOENT:        return .notFound
        default:            return .unknown
        }
    }

    // MARK: - Claude Desktop config inspection

    /// Inspect Claude Desktop's MCP config to see whether it registers any
    /// of our binaries. Returns an enum so the UI can distinguish
    /// "Claude Desktop not installed" from "config exists but doesn't
    /// reference us" from "JSON parse failed" — only the case, never raw
    /// command strings.
    func claudeDesktopConfigState() -> ClaudeConfigState {
        let configURL = claudeDesktopConfigPath ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

        guard let data = try? Data(contentsOf: configURL) else {
            return .fileAbsent
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any]
        else {
            return .parseError
        }
        guard let servers = obj["mcpServers"] as? [String: Any] else {
            return .notFound
        }
        for (_, value) in servers {
            guard let entry = value as? [String: Any],
                  let command = entry["command"] as? String
            else { continue }
            if command.hasPrefix(bundleBinaryPrefix) {
                return .found
            }
        }
        return .notFound
    }
}
