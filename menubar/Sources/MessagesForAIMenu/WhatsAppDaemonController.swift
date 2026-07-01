import Foundation
import Combine
import Darwin

/// Spawns + monitors the `whatsapp-drafts-daemon` binary that ships inside
/// the Ghostie .app bundle. The daemon listens on a Unix socket
/// at `~/.whatsapp-mcp/daemon.sock` (see WhatsAppRPCClient); without it
/// running, every approve/send call from the menubar would hit
/// `RPCError.daemonNotRunning`. The menubar owns the daemon's lifecycle
/// so the end-user never has to touch a CLI.
///
/// Lifecycle responsibilities:
/// - On app launch (when the user has enabled WhatsApp), start the daemon.
/// - Inherit the .app's code-signing identity — peer-auth on the daemon
///   side is satisfied by a runtime self-identity check (see commit 11).
/// - Pipe stdout+stderr to `~/.messages-mcp/logs/whatsapp-daemon.log`
///   with size-capped rotation (10 MB → roll to `.1`, keep up to `.3`).
/// - On unclean exit, exponential-backoff respawn (1s, 2s, 4s, 8s, 16s,
///   capped at 60s). After 5 consecutive crashes inside a short window,
///   stop respawning and surface a `.crashLooping` status; the user can
///   trigger a fresh `start()` from the UI.
/// - On `NSApplicationWillTerminate`, `SIGTERM`; wait up to 5s for a
///   clean exit; then `SIGKILL`.
@MainActor
final class WhatsAppDaemonController: ObservableObject {
  enum Status: Equatable {
    case idle              // never started this session, or stopped cleanly
    case starting          // Process launched; haven't yet seen it stay up
    case running(pid: Int32)
    case backingOff(nextAttemptIn: TimeInterval, consecutiveCrashes: Int)
    case crashLooping(consecutiveCrashes: Int)
    case stopped           // explicitly stopped by user (toggle off)
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var lastError: String?
  /// Last-known Baileys connection state from the daemon's
  /// `getConnectionStatus` RPC. nil until the first poll lands or while
  /// the daemon process isn't running. The Settings status label
  /// prefers this over the coarser `status` field above when present.
  /// Values mirror connection.ts's ConnectionState: "connecting" |
  /// "connected" | "reconnecting" | "logged_out".
  @Published private(set) var baileysState: String?

  /// Tunables — exposed for tests / future settings UI but never written.
  private let maxConsecutiveCrashes = 5
  private let stableRunSeconds: TimeInterval = 30   // resets crash counter
  private let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
  private let logRotateBytes: Int = 10 * 1024 * 1024
  private let logRotateKeep = 3
  private let baileysStatePollSeconds: TimeInterval = 5

  private var process: Process?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var logHandle: FileHandle?
  private var consecutiveCrashes = 0
  private var lastStartAt: Date?
  private var pendingRespawn: Task<Void, Never>?
  private var baileysStatePoller: Task<Void, Never>?

  // MARK: - Public API

  /// Spawn the daemon. Idempotent: a no-op if already running. Cancels
  /// any pending backoff respawn (lets the user click "Start" from the
  /// crash-loop banner without waiting out the backoff).
  /// Set by ControlManifestController: returns true while a kill directive demands
  /// this daemon stay down. When true, `start()` and respawns are refused. (Issue #76.)
  var isSuppressed: (() -> Bool)?

  func start() {
    // Refuse to start under an active kill (issue #76).
    if isSuppressed?() == true {
      status = .stopped
      lastError = "WhatsApp is disabled by the developer (kill switch active)."
      return
    }
    pendingRespawn?.cancel()
    pendingRespawn = nil

    switch status {
    case .running, .starting:
      return
    case .idle, .stopped, .backingOff, .crashLooping:
      consecutiveCrashes = 0
      lastError = nil
      launch()
    }
  }

  /// Stop the daemon. SIGTERM, wait up to 5s, SIGKILL. After this returns,
  /// status is `.stopped`; the controller will NOT auto-respawn.
  func stop() async {
    pendingRespawn?.cancel()
    pendingRespawn = nil
    stopBaileysStatePoller()

    guard let proc = process, proc.isRunning else {
      status = .stopped
      return
    }

    let pid = proc.processIdentifier
    kill(pid, SIGTERM)

    // Poll up to 5s.
    let deadline = Date().addingTimeInterval(5)
    while proc.isRunning && Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if proc.isRunning {
      kill(pid, SIGKILL)
      // Best-effort wait so terminationHandler fires before we return.
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    status = .stopped
  }

  /// Convenience for the user-quit path in App.swift.
  ///
  /// `NSApplicationWillTerminate` fires on the main thread and is synchronous,
  /// so we tear down INLINE here — NOT a Task+semaphore, which deadlocked (the
  /// main-actor task couldn't run while the main thread was parked in sem.wait,
  /// so it always burned the full 6s timeout). See the matching note in
  /// IMessageDaemonController.stopBlocking. `kill` is instant and
  /// `Process.isRunning` updates off the main thread, so the bounded poll works.
  func stopBlocking() {
    pendingRespawn?.cancel()
    pendingRespawn = nil
    stopBaileysStatePoller()
    guard let proc = process, proc.isRunning else { status = .stopped; return }
    let pid = proc.processIdentifier
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(2)
    while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if proc.isRunning {
      kill(pid, SIGKILL)
      Thread.sleep(forTimeInterval: 0.1)
    }
    status = .stopped
  }

  /// Kill any whatsapp-drafts-daemon process holding the PID lock at
  /// ~/.whatsapp-mcp/daemon.pid. No-op if the file is missing or the
  /// PID is dead. SIGTERM first, then a short wait, then SIGKILL if it
  /// hasn't exited. Also deletes the .pid + .sock so the new daemon
  /// starts clean. Used exclusively by `launch()` before spawning so
  /// orphaned daemons from previous menubar processes don't trap the
  /// new controller in a respawn loop.
  private func reapStaleDaemonIfNeeded() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pidFile = home.appendingPathComponent(".whatsapp-mcp/daemon.pid")
    let sockFile = home.appendingPathComponent(".whatsapp-mcp/daemon.sock")
    guard let pidStr = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
    let trimmed = pidStr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let stalePid = pid_t(trimmed), stalePid > 0 else { return }
    // Only reap if it's actually alive — otherwise the daemon's own
    // acquirePidLock will treat the file as stale and overwrite it.
    if kill(stalePid, 0) != 0 { return }

    appendLogLine("[controller] reaping stale daemon at PID \(stalePid) before launch")
    kill(stalePid, SIGTERM)
    // Give it a beat to release the socket cleanly. 2s is well over
    // observed SIGTERM-to-exit times (Baileys's ws teardown is <500ms)
    // but bounded so the new launch doesn't hang on this.
    let deadline = Date().addingTimeInterval(2)
    while kill(stalePid, 0) == 0 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    if kill(stalePid, 0) == 0 {
      appendLogLine("[controller] stale daemon \(stalePid) ignored SIGTERM, sending SIGKILL")
      kill(stalePid, SIGKILL)
      Thread.sleep(forTimeInterval: 0.2)
    }
    // Defense in depth: even after the process is gone, the .sock and
    // .pid files may linger if the daemon was force-killed before its
    // cleanup ran. The new daemon's startup handles stale-sock cleanup,
    // but stale .pid here would re-trigger the same crash-loop, so
    // remove it explicitly.
    try? FileManager.default.removeItem(at: pidFile)
    try? FileManager.default.removeItem(at: sockFile)
  }

  // MARK: - Baileys state polling
  //
  // Every `baileysStatePollSeconds` while the daemon process is up, ask
  // the daemon for its current Baileys connection state. The Settings
  // status row reads `baileysState` to render finer-grained UI than
  // "is the process alive" — Connected vs Connecting vs Reconnecting vs
  // logged-out. RPC failures during polling are silently swallowed; if
  // the daemon goes down, the terminationHandler will null the state.

  private func startBaileysStatePoller() {
    baileysStatePoller?.cancel()
    let interval = baileysStatePollSeconds
    baileysStatePoller = Task { @MainActor [weak self] in
      // Fire one poll immediately so the UI doesn't show "Connecting…"
      // for the full interval after the daemon comes up.
      await self?.refreshBaileysState()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        if Task.isCancelled { return }
        await self?.refreshBaileysState()
      }
    }
  }

  private func stopBaileysStatePoller() {
    baileysStatePoller?.cancel()
    baileysStatePoller = nil
    baileysState = nil
  }

  private func refreshBaileysState() async {
    guard case .running = status else { return }
    do {
      let s = try await WhatsAppRPCClient.getConnectionStatus()
      baileysState = s.state
    } catch {
      // Swallow — most common case during normal use is the brief
      // window after the daemon re-spawns where the socket isn't quite
      // ready. The next tick recovers.
    }
  }

  // MARK: - Internal: launch + monitor

  private func launch() {
    // Final gate: never spawn under an active kill (issue #76).
    if isSuppressed?() == true {
      status = .stopped
      return
    }
    // Resolve daemon binary path inside the .app bundle. On `swift run`
    // (no .app wrapper), Bundle.main points at the binary itself; fall
    // back to a sibling path so dev workflows can still spawn.
    guard let binURL = resolveDaemonBinary() else {
      status = .idle
      lastError = "could not locate whatsapp-drafts-daemon binary"
      return
    }

    // Reap any stale daemon left over from a previous menubar process.
    // macOS doesn't auto-kill a child process when the parent dies, so
    // a `pkill -f MessagesForAIMenu` (dev cycle) or a force-quit leaves
    // the daemon orphaned. When we spawn a new one it hits the
    // ~/.whatsapp-mcp/daemon.pid lock and exits — the controller then
    // crash-loop respawns into the same wall. The orphan also keeps a
    // stale binary in memory (old code / old credentials). Easiest fix:
    // SIGTERM whatever's holding the lock, give it a beat, and only
    // then launch our own daemon (which we can actually track).
    reapStaleDaemonIfNeeded()

    let proc = Process()
    proc.executableURL = binURL
    // No arguments — daemon reads everything from env + ~/.whatsapp-mcp/.
    proc.arguments = []

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    let logFile = ensureLogFileOpen()
    self.logHandle = logFile

    // Route both streams into the rotating log file. Read-side ends of
    // the pipes are non-blocking; the handler closure runs on a
    // background queue (hence @Sendable + the MainActor hop).
    let writeLog: @Sendable (FileHandle) -> Void = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in
        self?.appendToLog(data)
      }
    }
    outPipe.fileHandleForReading.readabilityHandler = writeLog
    errPipe.fileHandleForReading.readabilityHandler = writeLog
    self.stdoutPipe = outPipe
    self.stderrPipe = errPipe

    proc.terminationHandler = { [weak self] terminated in
      // Hops to the MainActor — terminationHandler fires on Process's
      // own queue, but our state is @MainActor-isolated.
      let status = terminated.terminationStatus
      let reason = terminated.terminationReason
      Task { @MainActor in
        self?.handleTermination(exitStatus: status, reason: reason)
      }
    }

    do {
      try proc.run()
    } catch {
      lastError = "failed to launch daemon: \(error.localizedDescription)"
      status = .idle
      return
    }

    self.process = proc
    self.lastStartAt = Date()
    status = .starting

    // Wait for the daemon to bind its Unix socket before promoting
    // to .running. The 250ms heuristic this replaces was too eager —
    // Bun's compiled-binary cold start through Baileys + sqlite +
    // Keychain typically takes 1–3s before socket bind. UI consumers
    // (the pairing window, RPC client) treat .running as "you can
    // connect now"; firing it before the socket exists makes them
    // race the daemon and fail with a spurious "not running" error.
    Task { @MainActor [weak self] in
      let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whatsapp-mcp")
        .appendingPathComponent("daemon.sock")
        .path
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let self = self else { return }
        // Bail out if the process died or our state changed under us.
        guard let p = self.process, p.isRunning else { return }
        guard case .starting = self.status else { return }
        if FileManager.default.fileExists(atPath: socketPath) {
          self.status = .running(pid: p.processIdentifier)
          self.startBaileysStatePoller()
          return
        }
      }
      // Socket never appeared — fall through; terminationHandler
      // will eventually fire with a crash, or the daemon is stuck
      // and the user can hit the Restart action. Leave status at
      // .starting so the UI shows "Connecting…" not "Connected".
    }
  }

  private func handleTermination(exitStatus: Int32, reason: Process.TerminationReason) {
    // Close pipes so the readability handlers stop firing.
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    stdoutPipe = nil
    stderrPipe = nil
    process = nil
    stopBaileysStatePoller()

    // If we were explicitly stopped, don't respawn.
    if case .stopped = status { return }

    let ranFor = lastStartAt.map { Date().timeIntervalSince($0) } ?? 0
    if ranFor >= stableRunSeconds {
      // The daemon was alive long enough that this exit isn't a
      // crash-loop signal — reset the counter before backing off again.
      consecutiveCrashes = 0
    }
    consecutiveCrashes += 1

    appendLogLine("[daemon] exited status=\(exitStatus) reason=\(reason.rawValue) ranFor=\(Int(ranFor))s consecutiveCrashes=\(consecutiveCrashes)")

    if consecutiveCrashes >= maxConsecutiveCrashes {
      status = .crashLooping(consecutiveCrashes: consecutiveCrashes)
      lastError = "WhatsApp daemon crashed \(consecutiveCrashes) times in a row. Tap Start to retry."
      return
    }

    let idx = min(consecutiveCrashes - 1, backoffSchedule.count - 1)
    let delay = backoffSchedule[idx]
    status = .backingOff(nextAttemptIn: delay, consecutiveCrashes: consecutiveCrashes)

    pendingRespawn = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self = self, !Task.isCancelled else { return }
      // Don't respawn if the user toggled WhatsApp off during backoff.
      switch self.status {
      case .stopped, .running, .starting: return
      default: break
      }
      self.launch()
    }
  }

  // MARK: - Internal: binary resolution

  private func resolveDaemonBinary() -> URL? {
    let binaryName = "whatsapp-drafts-daemon"
    let bundle = Bundle.main.bundleURL

    // Production: /Applications/Ghostie.app/Contents/MacOS/whatsapp-drafts-daemon
    let inBundle = bundle
      .appendingPathComponent("Contents/MacOS")
      .appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: inBundle.path) {
      return inBundle
    }

    // `swift run` from menubar/: Bundle.main is the unwrapped binary
    // itself. Look for a sibling.
    let sibling = bundle.deletingLastPathComponent().appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: sibling.path) {
      return sibling
    }

    return nil
  }

  // MARK: - Internal: log rotation

  private func logFileURL() -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("whatsapp-daemon.log")
  }

  private func ensureLogFileOpen() -> FileHandle? {
    let url = logFileURL()
    rotateIfNeeded(at: url)
    // Open with O_NOFOLLOW + owner/symlink checks (issue #83): this FDA-holding
    // process must never follow a symlink planted at the log path.
    return SafeLogFile.openForAppending(at: url)
  }

  private func rotateIfNeeded(at url: URL) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int,
          size >= logRotateBytes
    else { return }
    let fm = FileManager.default
    // Drop oldest, shift names, primary → .1.
    let oldest = url.appendingPathExtension("\(logRotateKeep)")
    try? fm.removeItem(at: oldest)
    for i in stride(from: logRotateKeep - 1, through: 1, by: -1) {
      let src = url.appendingPathExtension("\(i)")
      let dst = url.appendingPathExtension("\(i + 1)")
      if fm.fileExists(atPath: src.path) {
        try? fm.moveItem(at: src, to: dst)
      }
    }
    try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
  }

  private func appendToLog(_ data: Data) {
    guard let handle = logHandle else { return }
    _ = try? handle.seekToEnd()
    handle.write(data)
  }

  private func appendLogLine(_ line: String) {
    let timestamped = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
    if let data = timestamped.data(using: .utf8) {
      appendToLog(data)
    }
  }
}
