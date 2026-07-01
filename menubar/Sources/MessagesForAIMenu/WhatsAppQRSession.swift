import Foundation
import Darwin

/// Streaming JSON-RPC session over the WhatsApp daemon's Unix socket
/// for the pairing flow. Maintains ONE persistent connection (unlike
/// `WhatsAppRPCClient`, which is request/response one-shot) and emits
/// the daemon's pushed `qr.update` and `state.update` notifications as
/// an `AsyncStream` the SwiftUI view consumes with `.task { for await
/// event in ... }`.
///
/// Protocol exchange:
///   →  {"jsonrpc":"2.0","id":"<uuid>","method":"subscribe",
///       "params":{"channel":"qr"}}
///   ←  {"jsonrpc":"2.0","id":"<uuid>","result":{"subscription_id":"..."}}
///   ←  {"jsonrpc":"2.0","method":"qr.update","params":{"qr":"..."}}      (repeated)
///   ←  {"jsonrpc":"2.0","method":"state.update","params":{"state":"connected"}}
///
/// The daemon also subscribes us implicitly to `state` if we ask for
/// `qr` — it broadcasts state transitions on every channel so a paired
/// session emits `state.update: connected` even if the client only
/// asked for QR codes. The view dismisses on that event.
///
/// Cancellation: the AsyncStream's `onTermination` closes the socket.
/// In SwiftUI: a `.task { }` modifier that runs the consumer loop
/// cancels automatically when the view disappears, terminating the
/// stream, which closes the socket. No explicit teardown call needed.
final class WhatsAppQRSession {
  enum Event: Sendable {
    /// Subscription confirmed by daemon. The view enters "waiting for
    /// QR" state on this — the daemon pushes the actual QR shortly
    /// after (or immediately if it already had one cached).
    case subscribed(subscriptionId: String)
    /// New QR code payload from the daemon. The payload is the
    /// WhatsApp-formatted scan string (NOT a rendered image); the
    /// view runs it through CIFilter.qrCodeGenerator to display.
    case qrUpdate(qr: String)
    /// Connection state transition. The view auto-dismisses when this
    /// hits `"connected"`.
    case stateUpdate(state: String)
    /// Socket was closed cleanly by the daemon (e.g., it observed
    /// `logged_out` and exited; or the user killed the daemon). The
    /// view should drop back to an error state.
    case closed
    /// Transport or RPC error. The view drops to the error state with
    /// the message rendered.
    case error(String)
  }

  private static let timeoutSeconds: TimeInterval = 30  // longer than oneshot — pairing flow waits for the user

  private var fd: Int32 = -1
  private let socketPath: String

  init() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    self.socketPath = "\(home)/.whatsapp-mcp/daemon.sock"
  }

  /// Open the socket + send `subscribe({channel: "qr"})` + emit events
  /// as they arrive. Stream finishes on socket close, on error, or
  /// when the consumer cancels (e.g., view disappears).
  func eventStream() -> AsyncStream<Event> {
    AsyncStream(Event.self) { continuation in
      // Capture self weakly so the task doesn't keep the session alive
      // past the consumer's lifetime.
      let session = self
      DispatchQueue.global(qos: .userInitiated).async {
        session.run(continuation: continuation)
      }
      continuation.onTermination = { [weak self] _ in
        self?.closeSocket()
      }
    }
  }

  private func run(continuation: AsyncStream<Event>.Continuation) {
    // Poll for the daemon's Unix socket to appear. The menubar may
    // have JUST spawned the daemon (Settings toggle on, or Get Started
    // with WhatsApp checked), and Bun's compiled-binary cold-start
    // through Baileys / Keychain / sqlite typically takes 1–3s before
    // the socket bind completes. Without this poll the QRSession
    // races the daemon and emits a "WhatsApp isn't running" error
    // before the daemon's even had a chance.
    let deadline = Date().addingTimeInterval(8)
    while !FileManager.default.fileExists(atPath: socketPath) {
      if Date() > deadline {
        continuation.yield(.error("WhatsApp didn't finish starting up. Open Settings and toggle WhatsApp off, then back on."))
        continuation.finish()
        return
      }
      Thread.sleep(forTimeInterval: 0.15)
    }

    do {
      try openAndConnect()
    } catch let e as WhatsAppRPCClient.RPCError {
      continuation.yield(.error(e.description))
      continuation.finish()
      return
    } catch {
      continuation.yield(.error(error.localizedDescription))
      continuation.finish()
      return
    }

    // Send the subscribe request.
    let requestId = UUID().uuidString
    let request: [String: Any] = [
      "jsonrpc": "2.0",
      "id": requestId,
      "method": "subscribe",
      "params": ["channel": "qr"],
    ]
    do {
      let body = try JSONSerialization.data(withJSONObject: request, options: [])
      var frame = body
      frame.append(0x0a)
      try writeAll(frame)
    } catch {
      continuation.yield(.error("subscribe send failed: \(error.localizedDescription)"))
      continuation.finish()
      closeSocket()
      return
    }

    // Read frames in a loop. Each call to `readOneFrame` returns one
    // newline-terminated JSON-RPC message (or nil on EOF / error).
    while true {
      guard let frame = readOneFrame() else {
        // EOF or read error
        continuation.yield(.closed)
        continuation.finish()
        closeSocket()
        return
      }
      handleFrame(frame, requestId: requestId, continuation: continuation)
    }
  }

  /// Decode one frame and yield the appropriate event. Frames can be
  /// either responses (with `result`/`error` + `id`) or notifications
  /// (with `method` + `params`).
  private func handleFrame(
    _ data: Data,
    requestId: String,
    continuation: AsyncStream<Event>.Continuation
  ) {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      continuation.yield(.error("daemon sent a malformed frame: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")"))
      return
    }
    // Error response?
    if let id = obj["id"], let err = obj["error"] as? [String: Any] {
      let code = (err["code"] as? Int) ?? -1
      let message = (err["message"] as? String) ?? "unknown error"
      // id != null → this is a response to OUR subscribe call → fatal
      // id == null → daemon-initiated error notification → fatal too
      _ = id
      continuation.yield(.error("daemon RPC error \(code): \(message)"))
      return
    }
    // Subscribe response?
    if let id = obj["id"] as? String, id == requestId,
       let result = obj["result"] as? [String: Any] {
      let subId = (result["subscription_id"] as? String) ?? "(unknown)"
      continuation.yield(.subscribed(subscriptionId: subId))
      return
    }
    // Notification (qr.update / state.update)
    if let method = obj["method"] as? String, let params = obj["params"] as? [String: Any] {
      switch method {
      case "qr.update":
        if let qr = params["qr"] as? String {
          continuation.yield(.qrUpdate(qr: qr))
        }
      case "state.update":
        if let state = params["state"] as? String {
          continuation.yield(.stateUpdate(state: state))
        }
      default:
        // Unknown notification — ignore. The daemon may add channels.
        break
      }
      return
    }
    // Anything else: ignore silently. The daemon's protocol is small;
    // an unexpected frame is more likely a future schema extension
    // than a bug.
  }

  // MARK: - BSD socket plumbing
  //
  // Could share with WhatsAppRPCClient via an extracted helper, but the
  // streaming case has different lifecycle (non-blocking read loop, no
  // single timeout-then-close) so a small amount of duplication is
  // simpler than a parameterized abstraction.

  private func openAndConnect() throws {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
      throw WhatsAppRPCClient.RPCError.socketError(errno: errno, op: "socket()")
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw WhatsAppRPCClient.RPCError.socketError(errno: ENAMETOOLONG, op: "path too long")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (i, b) in pathBytes.enumerated() { dest[i] = b }
      }
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let res = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, addrLen)
      }
    }
    if res < 0 {
      let e = errno
      Darwin.close(fd)
      fd = -1
      switch e {
      case ECONNREFUSED, ENOENT:
        throw WhatsAppRPCClient.RPCError.daemonNotRunning
      default:
        throw WhatsAppRPCClient.RPCError.socketError(errno: e, op: "connect()")
      }
    }

    // Long send/recv timeouts — the pairing flow legitimately waits for
    // the user to scan a QR code. Reads will block until the next QR
    // refresh (usually <20 s) or state event.
    var tv = timeval(tv_sec: Int(Self.timeoutSeconds), tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  }

  private func writeAll(_ data: Data) throws {
    var written = 0
    try data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
      let base = rawBuf.baseAddress!
      while written < data.count {
        let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
        if n <= 0 {
          throw WhatsAppRPCClient.RPCError.socketError(errno: errno, op: "write()")
        }
        written += n
      }
    }
  }

  /// Block until one newline-terminated frame arrives. Returns nil on
  /// EOF or a read error (the caller treats both as "stream closed").
  /// The buffer is local to one call — we don't carry partial frames
  /// across calls because the daemon sends one complete JSON per write.
  /// On rare splits, the loop below assembles them.
  private var carryOver = Data()  // any bytes read past a newline last time

  /// Per-connection inbound frame cap (issue #84), mirroring the iMessage daemon's
  /// 1 MB limit. A peer (or one past the peer-auth race) that streams bytes with no
  /// newline would otherwise grow `carryOver` until the UI runs out of memory.
  /// Legitimate frames here are small JSON-RPC notifications well under this.
  static let maxFrameBytes = 1_000_000

  /// Pure helper for issue #84's cap, exposed for testing: given the current
  /// buffered byte count and whether a complete (newline-terminated) frame is
  /// present, return true when the connection should be dropped for an oversized
  /// no-newline frame.
  static func shouldRejectOversizedFrame(bufferedBytes: Int, hasNewline: Bool) -> Bool {
    !hasNewline && bufferedBytes > maxFrameBytes
  }

  private func readOneFrame() -> Data? {
    // First, see if `carryOver` already has a newline.
    if let nl = carryOver.firstIndex(of: 0x0a) {
      let frame = carryOver.prefix(upTo: nl)
      carryOver = Data(carryOver.suffix(from: carryOver.index(after: nl)))
      return Data(frame)
    }
    // A no-newline backlog already over the cap → reject (treat as stream closed).
    if carryOver.count > Self.maxFrameBytes {
      closeSocket()
      return nil
    }

    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = chunk.withUnsafeMutableBufferPointer { ptr in
        Darwin.read(fd, ptr.baseAddress, 4096)
      }
      if n == 0 { return nil }  // EOF
      if n < 0 { return nil }   // error or timeout
      carryOver.append(chunk, count: n)
      if let nl = carryOver.firstIndex(of: 0x0a) {
        let frame = carryOver.prefix(upTo: nl)
        carryOver = Data(carryOver.suffix(from: carryOver.index(after: nl)))
        return Data(frame)
      }
      // No newline yet and the buffer has blown past the cap: an oversized frame.
      // Drop the connection rather than buffering unbounded.
      if carryOver.count > Self.maxFrameBytes {
        closeSocket()
        return nil
      }
      // else: more data needed, loop
    }
  }

  private func closeSocket() {
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
    }
  }

  // MARK: - Convenience: read the LOGGED_OUT sentinel
  //
  // Checked at sheet-open time so the view can show a "Reconnect?"
  // prompt before trying to subscribe to QR codes (which would fail
  // because the daemon refuses to start while the sentinel exists).
  static var loggedOutSentinelExists: Bool {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".whatsapp-mcp/LOGGED_OUT").path
    return FileManager.default.fileExists(atPath: path)
  }
}
