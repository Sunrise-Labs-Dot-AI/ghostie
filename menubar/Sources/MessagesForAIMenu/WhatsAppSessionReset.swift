import Foundation
import Darwin

/// Revoking the WhatsApp link and re-pairing, from the menu bar.
///
/// The daemon already exposes an `unlinkAndReset` RPC, and that remains the
/// preferred path — it can quiesce its own Baileys socket before wiping, which
/// nothing out here can do. But routing recovery ONLY through that RPC is
/// exactly how a user gets stranded: the situation that most needs a reset is a
/// daemon that cannot start, and a daemon that cannot start has no socket to
/// answer on. Restarting just replays the same failure.
///
/// So this type is RPC-first with a local fallback: if the daemon can't be
/// reached, the menu bar removes the session state itself. It owns those files
/// (it's the process that launches the daemon), so it can always make progress.
///
/// The local path is deliberately paranoid about ordering, because a half-done
/// wipe is worse than no wipe:
///
///   1. Stop the daemon and CONFIRM it is dead. SQLite here is WAL-mode and the
///      daemon holds an open handle; deleting files under a live writer risks
///      it recreating or rewriting them behind us.
///   2. Remove the session database and its -wal/-shm sidecars. Removing the
///      main file but leaving a WAL behind can resurrect old auth rows.
///   3. Only once those are confirmed gone, clear the recovery sentinel.
///      The sentinel is the gate that keeps the daemon parked; dropping it
///      while the broken session is still on disk puts the daemon straight back
///      into the crash-loop this exists to escape.
///
/// Any failure aborts WITHOUT restarting the daemon and reports why. Staying
/// parked is recoverable; a daemon spun up against half-deleted state is not.
enum WhatsAppSessionReset {

  // MARK: - What gets deleted, and what must not

  /// Exact filenames removed by the local wipe, relative to `~/.whatsapp-mcp/`.
  ///
  /// An explicit allowlist rather than a directory sweep or a glob: everything
  /// else in that directory is user data we promise to keep, and a wildcard is
  /// one typo away from deleting message history.
  static let sessionFileNames = ["session.db", "session.db-wal", "session.db-shm"]

  /// Cleared last, and only after `sessionFileNames` are confirmed gone.
  static let sentinelFileName = "LOGGED_OUT"

  /// Files in `~/.whatsapp-mcp/` the reset must never touch. Not consulted at
  /// runtime (the allowlist above is what executes) — this is the invariant the
  /// tests assert against, so a future edit to `sessionFileNames` that reaches
  /// into user data fails CI instead of shipping.
  static let preservedFileNames = [
    "messages.db", "messages.db-wal", "messages.db-shm",   // message history
    "audit.db", "audit.db-wal", "audit.db-shm",            // send audit trail
    "settings.json",
    "thread-priorities.json",
    "drafts",
    "draft-attachments",
    "media",
  ]

  // MARK: - Outcome

  enum Outcome: Equatable {
    /// The daemon performed the reset itself. It is already re-pairing.
    case viaDaemon
    /// The daemon was unreachable; the menu bar wiped the session on disk.
    case viaLocalWipe
    /// Nothing was changed, or the wipe stopped partway. Message is user-facing.
    case failed(String)
  }

  // MARK: - Entry point

  /// Revoke the current link so a fresh QR pairing can start.
  ///
  /// Returns `.viaDaemon` or `.viaLocalWipe` on success. The caller is
  /// responsible for opening the pairing window; on `.viaLocalWipe` the daemon
  /// has been restarted and will emit a QR once it binds.
  @MainActor
  static func perform(daemon: WhatsAppDaemonController) async -> Outcome {
    // Preferred: let the daemon do it. It can detach its own creds.update
    // handler first, which we cannot.
    do {
      try await WhatsAppRPCClient.unlinkAndReset()
      daemon.noteSessionReset()
      return .viaDaemon
    } catch {
      // Fall through. Any RPC failure — not running, refused, timed out,
      // parked, peer-auth — lands here, which is the point: this path exists
      // precisely for the cases where the daemon can't help.
      NSLog("WhatsApp reset: daemon RPC failed (\(error.localizedDescription)); falling back to local wipe")
    }

    return await localWipe(daemon: daemon)
  }

  // MARK: - Local fallback

  @MainActor
  private static func localWipe(daemon: WhatsAppDaemonController) async -> Outcome {
    // 1. Quiesce. An RPC timeout does NOT mean the daemon is gone — it may have
    //    accepted the request and still be running with the DB open.
    let dead = await daemon.stopAndConfirmDead()
    guard dead else {
      return .failed(
        "Couldn't stop the WhatsApp background service, so its session files were left alone. "
        + "Quit and reopen Ghostie, then try Disconnect again."
      )
    }

    // 2. Remove the session DB and its sidecars.
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".whatsapp-mcp")
    for name in sessionFileNames {
      let url = dir.appendingPathComponent(name)
      do {
        try removeIfPresent(at: url)
      } catch {
        return .failed(
          "Couldn't remove \(name): \(error.localizedDescription). "
          + "WhatsApp was left disconnected; no message history was touched."
        )
      }
    }

    // 3. Verify before un-gating. If something recreated a file under us
    //    (a daemon we failed to notice), stay parked rather than starting.
    for name in sessionFileNames where FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
      return .failed(
        "\(name) reappeared while resetting, so WhatsApp was left disconnected. "
        + "Quit and reopen Ghostie, then try Disconnect again."
      )
    }

    // 4. Now, and only now, drop the gate.
    do {
      try removeIfPresent(at: dir.appendingPathComponent(sentinelFileName))
    } catch {
      return .failed(
        "The session was cleared but the recovery marker couldn't be removed "
        + "(\(error.localizedDescription)). Quit and reopen Ghostie to finish."
      )
    }

    daemon.noteSessionReset()
    daemon.start()
    return .viaLocalWipe
  }

  /// `removeItem` throws when the path doesn't exist; for a wipe that's success,
  /// not failure. Every other error is real and must surface.
  private static func removeIfPresent(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

// MARK: - Recovery sentinel

/// Why the daemon is parked, read from `~/.whatsapp-mcp/LOGGED_OUT`.
///
/// Mirrors `mcps/whatsapp-drafts/src/daemon/recovery.ts`. The file's first line
/// is an ISO timestamp (the legacy shape, which older builds wrote and which
/// older builds still only test for existence); optional `key=value` lines
/// follow. A file with no `reason=` line means `loggedOut`, since that is what
/// every pre-existing build wrote.
enum WhatsAppRecoveryReason: String, Equatable {
  /// Unlinked from the phone's Linked Devices list.
  case loggedOut = "logged_out"
  /// Stored credentials no longer decrypt — needs a wipe and re-pair.
  case sessionUnreadable = "session_unreadable"
}

struct WhatsAppRecoveryState: Equatable {
  let reason: WhatsAppRecoveryReason
  /// Daemon-supplied elaboration. Empty for a legacy sentinel.
  let detail: String

  static var sentinelURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".whatsapp-mcp")
      .appendingPathComponent(WhatsAppSessionReset.sentinelFileName)
  }

  /// Parse the sentinel, or nil when the daemon is not parked.
  static func current() -> WhatsAppRecoveryState? {
    let url = sentinelURL
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
      // Present but unreadable: still parked. Assume the legacy meaning rather
      // than reporting a healthy session.
      return WhatsAppRecoveryState(reason: .loggedOut, detail: "")
    }
    return parse(raw)
  }

  /// Pure parser, exposed for tests.
  static func parse(_ raw: String) -> WhatsAppRecoveryState {
    var reason: WhatsAppRecoveryReason = .loggedOut
    var detail = ""
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if key == "reason", let parsed = WhatsAppRecoveryReason(rawValue: value) {
        reason = parsed
      } else if key == "detail" {
        detail = value
      }
    }
    return WhatsAppRecoveryState(reason: reason, detail: detail)
  }
}
