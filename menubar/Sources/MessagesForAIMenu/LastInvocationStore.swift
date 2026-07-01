import Combine
import Foundation

/// One row of the witness file written by each MCP after every successful
/// tool call. Mirrors the schema written by
/// `mcps/{imessage,whatsapp}-drafts/src/witness.ts:WitnessRecord`.
///
/// `ts` is parsed as a `Date` at decode time. Records with non-parseable
/// or out-of-window timestamps are dropped (treated as no invocation).
struct WitnessRecord: Equatable {
    let tool: String
    let ts: Date
    let pid: Int32
    let writerPath: String
    /// Live chat.db access of the *Claude-launched* MCP process at write time.
    /// nil when the writing MCP predates this field (no `chatdb_access` key).
    /// This is the authoritative client-FDA signal — distinct from the menu-bar
    /// app's own probe, which can differ because macOS attributes Full Disk
    /// Access to the launching app, not the binary's identity (issue #17).
    let chatDbAccess: ChatDbAccessState?
}

private struct RawWitnessRecord: Decodable {
    let tool: String
    let ts: String
    let pid: Int32
    let writer_path: String
    let chatdb_access: String?
}

/// Watches `~/.messages-mcp/` for atomic-renames of the per-transport
/// witness files (`last_invocation_imessage.json`,
/// `last_invocation_whatsapp.json`) and publishes the latest `WitnessRecord`
/// for each transport.
///
/// **Why parent-dir-only**: `DispatchSourceFileSystemObject` opened on a
/// file's fd becomes invalid the moment the atomic temp+rename swaps the
/// inode. Watching the parent directory catches the structural rename
/// event reliably; we then re-stat both files on every event.
///
/// **Input validation**: a record is published only when `ts` parses as
/// ISO-8601 AND lies within `(now - 10min, now + 5s)`. Future timestamps
/// beyond clock-skew tolerance and stale timestamps are dropped. A
/// malicious or buggy writer that wrote a year-2099 ts cannot bypass the
/// walkthrough's freshness gate via this store.
///
/// Codesign identity of the writer is verified separately by the
/// SetupWalkthroughView using `HealthChecks.verifyRunningPid` — kept out
/// of this layer to keep it pure-FS and easy to unit-test.
@MainActor
final class LastInvocationStore: ObservableObject {
    @Published private(set) var imessage: WitnessRecord?
    @Published private(set) var whatsapp: WitnessRecord?

    /// Tolerance for clocks running slightly ahead. Tighten if we ever
    /// observe legitimate jitter beyond this.
    static let futureSkewTolerance: TimeInterval = 5

    /// Records older than this are treated as no-invocation. The
    /// SetupWalkthroughView additionally enforces its own
    /// `walkthroughStartedAt` gate; this is the outer safety net.
    static let maxStaleness: TimeInterval = 10 * 60

    private let dir: URL
    private let imessagePath: URL
    private let whatsappPath: URL

    /// When true (default), records older than `maxStaleness` are dropped to
    /// nil — the freshness gate the SetupWalkthroughView relies on to prove a
    /// *live* connection during setup. The Settings status pane opts OUT
    /// (`false`) so it reports the real last-seen time ("3 days ago") rather
    /// than collapsing every not-recent call to "no record" — the witness
    /// file persists across reinstalls, so that history shouldn't read as
    /// "never."
    private let applyStalenessGate: Bool

    private var source: DispatchSourceFileSystemObject?
    private var handle: Int32 = -1

    init(homeOverride: URL? = nil, applyStalenessGate: Bool = true) {
        let base = homeOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".messages-mcp")
        self.dir = base
        self.imessagePath = base.appendingPathComponent("last_invocation_imessage.json")
        self.whatsappPath = base.appendingPathComponent("last_invocation_whatsapp.json")
        self.applyStalenessGate = applyStalenessGate
        // Ensure the dir exists so open(O_EVTONLY) succeeds on a fresh install.
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        refresh()
        startWatching()
    }

    deinit {
        source?.cancel()
        if handle >= 0 { close(handle) }
    }

    // MARK: - Public API

    func refresh() {
        imessage = decode(imessagePath)
        whatsapp = decode(whatsappPath)
    }

    // MARK: - Internals

    private func startWatching() {
        let h = open(dir.path, O_EVTONLY)
        guard h >= 0 else { return }
        handle = h
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h,
            // .write fires on add/remove inside the dir; .rename catches
            // atomic temp+rename. We deliberately don't watch the file fds
            // themselves — see class doc.
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            // Coalesce bursts: a single atomic rename produces multiple
            // events; refresh() is cheap (two file reads).
            self?.refresh()
        }
        src.setCancelHandler { [handle = self.handle] in
            close(handle)
        }
        src.resume()
        source = src
    }

    private func decode(_ url: URL) -> WitnessRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let raw = try? JSONDecoder().decode(RawWitnessRecord.self, from: data) else {
            return nil
        }
        guard let parsed = Self.parseTimestamp(raw.ts) else { return nil }

        // Always reject future-skewed / garbage timestamps.
        let now = Date()
        if parsed > now.addingTimeInterval(Self.futureSkewTolerance) { return nil }
        // Staleness drop is opt-in (see `applyStalenessGate`): the walkthrough
        // needs it; the Settings pane keeps old records so it can show a real
        // last-seen time instead of "no record yet."
        if applyStalenessGate && parsed < now.addingTimeInterval(-Self.maxStaleness) { return nil }

        // Map the MCP's chat.db open_status string onto the Swift enum.
        // "error" (rare non-permission failure) → .unknown; absent → nil.
        let chatDbAccess: ChatDbAccessState?
        switch raw.chatdb_access {
        case "ok": chatDbAccess = .ok
        case "permission_denied": chatDbAccess = .permissionDenied
        case "not_found": chatDbAccess = .notFound
        case "error": chatDbAccess = .unknown
        case nil: chatDbAccess = nil
        default: chatDbAccess = .unknown
        }

        return WitnessRecord(
            tool: raw.tool,
            ts: parsed,
            pid: raw.pid,
            writerPath: raw.writer_path,
            chatDbAccess: chatDbAccess
        )
    }

    /// ISO-8601 with optional fractional seconds. Bun's `new Date().toISOString()`
    /// always emits fractional seconds; we accept either form so future
    /// writer changes don't silently break the store.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
