import Foundation
import Darwin

/// Thin JSON-RPC 2.0 client over the WhatsApp daemon's Unix socket at
/// `~/.whatsapp-mcp/daemon.sock`. Speaks newline-delimited frames.
///
/// One connection per call: the menubar's traffic is request/response
/// (approve, send, occasional discard) — there's no benefit to keeping
/// a persistent socket for these. The pairing flow that needs streaming
/// (`subscribe("qr")`) ships in a separate file (`WhatsAppPairingView`)
/// and manages its own long-lived connection.
///
/// Peer authentication is enforced on the daemon side: `~/.whatsapp-mcp/
/// daemon.sock` is reachable by every process running as the user, so
/// the daemon checks each connecting peer's code-signing identity at
/// runtime against its own (commit 11). Since the daemon ships inside
/// the same .app bundle as this menubar binary and both are signed
/// with `com.sunriselabs.messages-for-ai`, peer-auth is automatic in
/// release builds. Dev builds bypass via `WHATSAPP_MCP_DEV=1`. From
/// the client side there's nothing to do — failed peer-auth surfaces
/// as a closed connection / EOF.
enum WhatsAppRPCClient {
  /// Default 10s timeout. Longer than the daemon's own send timeout
  /// (Baileys can take a few seconds) but short enough that a stuck
  /// daemon doesn't hang the menubar UI forever.
  static let timeoutSeconds: TimeInterval = 10

  /// Socket path. Constructed at call time (not cached) so an unset
  /// HOME doesn't crash module load.
  private static var socketPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.whatsapp-mcp/daemon.sock"
  }

  // MARK: - Convenience methods (one per daemon RPC the menubar uses)

  /// Mark a draft `approval_state: "approved"`. The daemon refuses to
  /// `sendDraft` until this returns success. Called by the menubar's
  /// hold-to-fire interaction BEFORE `sendDraft`.
  static func approveDraft(id: String) async throws -> ApproveResult {
    let params = DraftIdParams(draft_id: id)
    let raw = try await call(method: "approveDraft", params: params)
    return try JSONDecoder().decode(ApproveResult.self, from: raw)
  }

  /// Tell the daemon to send a previously-approved draft. The daemon
  /// writes `sent_at` to the draft JSON on success; the menubar's
  /// `DraftStore` FS watcher then refreshes and the row renders as
  /// sent. Menubar must NOT write `sent_at` itself for WhatsApp drafts.
  static func sendDraft(id: String) async throws -> SendResult {
    let params = DraftIdParams(draft_id: id)
    let raw = try await call(method: "sendDraft", params: params)
    return try JSONDecoder().decode(SendResult.self, from: raw)
  }

  /// Send a first-party typed message directly to a WhatsApp thread. This is
  /// only used by the visible Messages composer; AI/MCP messages continue to
  /// use the staged draft approval RPCs above.
  static func sendDirectMessage(threadJID: String, body: String) async throws -> SendResult {
    let params = DirectMessageParams(
      thread_jid: threadJID,
      body: body,
      source: "first_party_inline_composer"
    )
    let raw = try await call(method: "sendDirectMessage", params: params)
    return try JSONDecoder().decode(SendResult.self, from: raw)
  }

  /// Send a first-party reaction from the visible Messages transcript. The
  /// click is the human approval; MCP/agent surfaces do not call this.
  static func sendReaction(threadJID: String, messageID: String, emoji: String) async throws -> SendReactionResult {
    let params = ReactionParams(
      thread_jid: threadJID,
      message_id: messageID,
      emoji: emoji,
      source: "first_party_message_tab"
    )
    let raw = try await call(method: "sendReaction", params: params)
    return try JSONDecoder().decode(SendReactionResult.self, from: raw)
  }

  /// Download a WhatsApp media payload (photo/video/doc/voice) to disk on
  /// demand and return the local file path. The daemon owns the encrypted
  /// media descriptor and the live socket needed to fetch + decrypt the bytes;
  /// idempotent (a cached file is returned without re-fetching). Called when
  /// the user taps a media bubble in the transcript.
  static func downloadMedia(threadJID: String, messageID: String) async throws -> MediaDownloadResult {
    let params = MediaDownloadParams(thread_jid: threadJID, message_id: messageID)
    let raw = try await call(method: "downloadMedia", params: params)
    return try JSONDecoder().decode(MediaDownloadResult.self, from: raw)
  }

  /// Wipe the daemon's Baileys session + remove the LOGGED_OUT
  /// sentinel so the daemon can re-pair on next start. Used by the
  /// pairing sheet's "Reconnect" flow when the user has been remotely
  /// logged out. Destructive — confirm with the user before calling.
  static func unlinkAndReset() async throws {
    // Daemon returns `{ok: true, note: "..."}`; we don't need the body.
    _ = try await call(method: "unlinkAndReset", params: EmptyParams())
  }

  /// Daemon's live Baileys connection state. The Settings status row
  /// polls this so the label reflects what's actually happening with
  /// WhatsApp (connecting / connected / reconnecting / logged_out)
  /// rather than just "is the daemon process alive".
  static func getConnectionStatus() async throws -> ConnectionStatus {
    let raw = try await call(method: "getConnectionStatus", params: EmptyParams())
    return try JSONDecoder().decode(ConnectionStatus.self, from: raw)
  }

  /// Read a WhatsApp thread through the daemon so message bodies pass through
  /// the decrypt-on-read path. The Swift UI must not read `messages.body`
  /// directly from SQLite because v0.5.3 stores those columns encrypted.
  static func getThread(threadJID: String, limit: Int = 160, beforeTimestamp: Int64? = nil) async throws -> [ContextMessage] {
    let params = GetThreadParams(thread_jid: threadJID, before_ts: beforeTimestamp, limit: limit)
    let raw = try await call(method: "getThread", params: params)
    return try decodeThreadMessages(raw)
  }

  static func decodeThreadMessages(_ data: Data) throws -> [ContextMessage] {
    let result = try JSONDecoder().decode(GetThreadResult.self, from: data)
    return result.messages.reversed().compactMap { message in
      let body = message.body?.trimmingCharacters(in: .whitespacesAndNewlines)
      let attachments = message.mediaAttachments()
      // Keep a message when it has visible text OR downloadable media. A
      // caption-less photo/video used to vanish here (empty body → dropped);
      // now it surfaces as a tap-to-load media bubble.
      let hasBody = (body?.isEmpty == false)
      guard hasBody || !attachments.isEmpty else { return nil }
      var msg = ContextMessage(
        guid: message.message_id,
        message_id: message.message_id,
        from_me: message.from_me,
        sender_handle: message.from_me ? nil : message.sender_jid,
        sender_name: message.from_me ? nil : message.cleanSenderName,
        body: hasBody ? body : nil,
        sent_at: iso(Date(timeIntervalSince1970: Double(message.ts) / 1000)),
        reactions: (message.reactions ?? []).map { reaction in
          MessageReaction(
            kind: .emoji,
            from_me: reaction.from_me,
            sender_handle: reaction.from_me ? nil : reaction.sender_jid,
            sender_name: reaction.from_me ? nil : reaction.cleanSenderName,
            sent_at: iso(Date(timeIntervalSince1970: Double(reaction.ts) / 1000)),
            emoji: reaction.emoji
          )
        }
      )
      msg.attachments = attachments
      return msg
    }
  }

  /// Synchronous decrypt-on-read fetch of a thread's most-recent messages.
  ///
  /// Bodies come back DECRYPTED — the daemon owns the at-rest AES-256-GCM key
  /// (#81) and is the only Keychain-trusted binary, so any reader that pulls
  /// `messages.body` straight from SQLite gets ciphertext byte-garbage. Callers
  /// that already run off the main thread (the Don't Ghost scan, which runs in a
  /// detached task) use this rather than the `async` `getThread` so they stay
  /// synchronous. Returns the daemon's `ts DESC` order (most-recent first).
  /// Throws an `RPCError` when the daemon is unreachable — the caller decides
  /// whether that's fatal (see `RPCError.isDaemonUnavailable`).
  static func getThreadMessagesSync(threadJID: String, limit: Int) throws -> [DecryptedThreadMessage] {
    let params = GetThreadParams(thread_jid: threadJID, before_ts: nil, limit: limit)
    let raw = try callSync(method: "getThread", params: params)
    let result = try JSONDecoder().decode(GetThreadResult.self, from: raw)
    return result.messages.map {
      DecryptedThreadMessage(
        messageID: $0.message_id,
        senderJID: $0.sender_jid,
        fromMe: $0.from_me,
        ts: $0.ts,
        body: $0.body
      )
    }
  }

  /// A single decrypted message row, trimmed to the fields the Don't Ghost scan
  /// needs. `body` is plaintext (or nil for non-text / undecodable content).
  struct DecryptedThreadMessage {
    let messageID: String
    let senderJID: String?
    let fromMe: Bool
    let ts: Int64
    let body: String?
  }

  struct ConnectionStatus: Decodable {
    /// "connecting" | "connected" | "reconnecting" | "logged_out"
    let state: String
    let me: Me?
    struct Me: Decodable {
      let jid: String?
      let phone: String?
    }
  }

  private struct EmptyParams: Encodable {}

  private struct GetThreadParams: Encodable {
    let thread_jid: String
    let before_ts: Int64?
    let limit: Int
  }

  private struct DirectMessageParams: Encodable {
    let thread_jid: String
    let body: String
    let source: String
  }

  private struct ReactionParams: Encodable {
    let thread_jid: String
    let message_id: String
    let emoji: String
    let source: String
  }

  private struct MediaDownloadParams: Encodable {
    let thread_jid: String
    let message_id: String
  }

  /// Result of `downloadMedia`: the local file path the daemon wrote (under
  /// `~/.whatsapp-mcp/media/`) and the media's MIME type, if known.
  struct MediaDownloadResult: Decodable {
    let path: String
    let mime: String?
  }

  private struct GetThreadResult: Decodable {
    let messages: [ThreadMessage]
  }

  struct AttachmentMeta: Decodable {
    let caption: String?
    let filename: String?
    let mime: String?
  }

  private struct ThreadMessage: Decodable {
    let message_id: String
    // Optional only to tolerate a momentarily-older daemon mid-upgrade that
    // predates the field; the current daemon always sends it.
    let thread_jid: String?
    let sender_jid: String?
    let sender_name: String?
    let from_me: Bool
    let ts: Int64
    let body: String?
    let message_type: String?
    let attachment_meta: AttachmentMeta?
    let media_downloadable: Bool?
    let reactions: [ThreadReaction]?

    var cleanSenderName: String? {
      let trimmed = sender_name?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// A downloadable WhatsApp media attachment for this message, or [] when it
    /// isn't media or the daemon has no descriptor on file (older rows). The
    /// ref carries no local path yet — the bubble fetches it on tap.
    func mediaAttachments() -> [MessageAttachmentRef] {
      guard media_downloadable == true, let thread_jid else { return [] }
      return [
        MessageAttachmentRef(
          path: nil,
          mimeType: attachment_meta?.mime,
          name: attachment_meta?.filename,
          byteCount: 0,
          whatsappThreadJID: thread_jid,
          whatsappMessageID: message_id
        )
      ]
    }
  }

  private struct ThreadReaction: Decodable {
    let emoji: String
    let sender_jid: String?
    let sender_name: String?
    let from_me: Bool
    let ts: Int64

    var cleanSenderName: String? {
      let trimmed = sender_name?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed?.isEmpty == false ? trimmed : nil
    }
  }

  private static func iso(_ date: Date) -> String {
    let key = "MessagesForAI.WhatsAppRPCClient.isoFormatter"
    if let formatter = Thread.current.threadDictionary[key] as? ISO8601DateFormatter {
      return formatter.string(from: date)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    Thread.current.threadDictionary[key] = formatter
    return formatter.string(from: date)
  }

  // MARK: - Wire types

  struct DraftIdParams: Encodable {
    let draft_id: String
  }

  struct ApproveResult: Decodable {
    // Daemon returns `{ draft: {...full draft after the state mutation...} }`
    // We don't currently use the returned draft (FS watcher re-reads
    // from disk) but decoding it confirms the daemon understood the
    // call. Kept loose (Decodable + no fields) since we just need the
    // success signal.
  }

  struct SendResult: Decodable {
    let ok: Bool
    let draft_id: String?
    let message_id: String?
    let sent_at: String?
  }

  struct SendReactionResult: Decodable {
    let ok: Bool
    let draft_id: String?
    let message_id: String?
    let reacted_to_message_id: String?
    let sent_at: String?
  }

  // MARK: - Errors

  enum RPCError: Error, CustomStringConvertible, LocalizedError {
    case daemonNotInstalled            // socket file does not exist
    case daemonNotRunning              // socket exists but connect refused (ECONNREFUSED)
    case peerAuthRejected              // daemon closed connection after our write — usually peer-auth
    case timeout                       // no response within timeoutSeconds
    case socketError(errno: Int32, op: String)
    case writeError(Error)
    case readError(Error)
    case invalidResponse(String)       // not parseable JSON-RPC 2.0
    case rpcError(code: Int, message: String)

    var errorDescription: String? {
      userFacingMessage
    }

    /// True for the "no working daemon to reach" cases. The Don't Ghost scan
    /// treats these as "no WhatsApp candidates this pass" rather than a hard
    /// failure: iMessage candidates still load, and we must NEVER fall back to
    /// the raw (encrypted) `messages.body` column, so an unreachable daemon just
    /// yields no WhatsApp suggestions.
    var isDaemonUnavailable: Bool {
      switch self {
      case .daemonNotInstalled, .daemonNotRunning, .peerAuthRejected, .timeout:
        return true
      case .socketError, .writeError, .readError, .invalidResponse, .rpcError:
        return false
      }
    }

    /// What kind of send the user attempted — drafts and reactions need
    /// different wording (a reaction failure phrased as "couldn't send this
    /// draft" reads like a different feature broke).
    enum SendContext {
      case draft
      case reaction
    }

    var userFacingMessage: String {
      userFacingMessage(for: .draft)
    }

    func userFacingMessage(for context: SendContext) -> String {
      switch self {
      case .daemonNotInstalled:
        return "WhatsApp isn't running yet. Open Settings and toggle WhatsApp on."
      case .daemonNotRunning:
        return "WhatsApp lost its connection. Try toggling WhatsApp off and back on in Settings."
      case .peerAuthRejected:
        return "WhatsApp rejected the app connection. Restart Ghostie and try again."
      case .timeout:
        return "WhatsApp took too long to respond. Try again in a moment."
      case .socketError, .writeError, .readError, .invalidResponse:
        return "Ghostie couldn't talk to WhatsApp. Try reconnecting WhatsApp in Settings."
      case .rpcError(let code, let message):
        switch code {
        case RPCCode.notConnected:
          return "WhatsApp is not connected. Open Settings to reconnect."
        case RPCCode.pendingApproval:
          return "Approve this draft before sending."
        case RPCCode.minAgeNotReached:
          return "This draft is still getting ready. Try again in a few seconds."
        case RPCCode.interSendTooFast:
          return context == .reaction
            ? "Ghostie is spacing out sends. Try the reaction again in a moment."
            : "Ghostie is spacing out sends. Try again in a moment."
        case RPCCode.burstLimitHit:
          return context == .reaction
            ? "You've sent a lot at once. Try the reaction again in a minute."
            : "You've sent several messages quickly. Try again in a minute."
        case RPCCode.dailyCapHit:
          return context == .reaction
            ? "Today's WhatsApp send limit has been reached, so the reaction wasn't sent."
            : "Today's WhatsApp send limit has been reached."
        case RPCCode.sendFailed:
          return context == .reaction
            ? "WhatsApp couldn't add that reaction. Check WhatsApp and try again."
            : "WhatsApp couldn't send this draft. Check WhatsApp and try again."
        case RPCCode.draftNotFound:
          return "This draft no longer exists."
        case RPCCode.settingsError:
          return "WhatsApp settings need attention. Open Settings and try again."
        case RPCCode.sendBlocked:
          return message
        case RPCCode.targetNotFound:
          return context == .reaction
            ? "That message is no longer available to react to."
            : "That message is no longer available."
        default:
          return context == .reaction
            ? "WhatsApp couldn't add that reaction. Try again."
            : "WhatsApp couldn't send this draft. Try again."
        }
      }
    }

    var description: String {
      switch self {
      case .daemonNotInstalled:
        return "WhatsApp isn't running yet. Open Settings and toggle WhatsApp on."
      case .daemonNotRunning:
        return "WhatsApp lost its connection. Try toggling WhatsApp off and back on in Settings."
      case .peerAuthRejected:
        return "Ghostie was rebuilt or re-signed since WhatsApp was last connected. Reinstall the app or contact support."
      case .timeout:
        return "WhatsApp daemon did not respond within \(Int(timeoutSeconds))s"
      case .socketError(let errno, let op):
        return "socket \(op) failed: errno \(errno) (\(String(cString: strerror(errno))))"
      case .writeError(let e):
        return "write to daemon socket failed: \(e.localizedDescription)"
      case .readError(let e):
        return "read from daemon socket failed: \(e.localizedDescription)"
      case .invalidResponse(let s):
        return "daemon returned a frame that's not valid JSON-RPC 2.0: \(s)"
      case .rpcError(let code, let message):
        return "daemon RPC error \(code): \(message)"
      }
    }

    private enum RPCCode {
      static let notConnected = -32010
      static let pendingApproval = -32020
      static let minAgeNotReached = -32021
      static let interSendTooFast = -32022
      static let burstLimitHit = -32023
      static let dailyCapHit = -32024
      static let sendFailed = -32025
      static let draftNotFound = -32026
      static let settingsError = -32027
      static let sendBlocked = -32028
      static let targetNotFound = -32029
    }
  }

  // MARK: - JSON-RPC plumbing

  private struct RPCRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: P
  }

  /// JSON-RPC 2.0 response envelope. Exactly one of `result` / `error`
  /// is present. We decode the envelope first, then re-decode `result`
  /// into the caller-typed struct (returned to the caller as raw Data).
  private struct RPCResponseEnvelope: Decodable {
    let jsonrpc: String
    let id: String?
    let result: AnyDecodable?
    let error: RPCErrorPayload?
  }

  private struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
  }

  // Type-erased Decodable that just stashes the raw subdocument so we
  // can re-encode it for the caller's strongly-typed decode pass.
  private struct AnyDecodable: Decodable {
    let raw: Data
    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      // Pull through as a generic JSON Codable bridge by re-encoding.
      // The simpler path (capturing the underlying Data directly from
      // the decoder) isn't available with JSONDecoder, so we decode to
      // a permissive Any-like and re-encode.
      if let v = try? c.decode(JSONValue.self) {
        self.raw = try JSONEncoder().encode(v)
      } else {
        self.raw = Data()
      }
    }
  }

  /// Send one JSON-RPC call. Returns the raw `result` payload as Data
  /// (which the caller decodes into a method-specific result struct).
  /// Async wrapper around `callSync`, dispatched to a background queue so the
  /// blocking socket round-trip never lands on the calling actor.
  private static func call<P: Encodable>(method: String, params: P) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(returning: try callSync(method: method, params: params))
        } catch let e as RPCError {
          continuation.resume(throwing: e)
        } catch {
          continuation.resume(throwing: RPCError.readError(error))
        }
      }
    }
  }

  /// Synchronous JSON-RPC call: connect → write → read-one-frame → decode the
  /// envelope, returning the raw `result` payload as Data. Blocks the calling
  /// thread for the socket round-trip, so callers must already be off the main
  /// thread (the async `call` above dispatches here from a background queue; the
  /// Don't Ghost scan runs in a detached task).
  private static func callSync<P: Encodable>(method: String, params: P) throws -> Data {
    let path = socketPath

    // Fail fast on the common "not installed" case with a specific error so
    // callers can distinguish it from a generic socket failure.
    if !FileManager.default.fileExists(atPath: path) {
      throw RPCError.daemonNotInstalled
    }

    let requestId = UUID().uuidString
    let request = RPCRequest(id: requestId, method: method, params: params)
    let payload = try JSONEncoder().encode(request) + Data([0x0a]) // newline-delimited

    let raw = try sendOneFrame(path: path, payload: payload)
    let envelope = try JSONDecoder().decode(RPCResponseEnvelope.self, from: raw)
    if let err = envelope.error {
      throw RPCError.rpcError(code: err.code, message: err.message)
    }
    guard let result = envelope.result else {
      throw RPCError.invalidResponse("response had neither `result` nor `error`")
    }
    return result.raw
  }

  /// Synchronous connect → write → read-one-line → close. Runs on a
  /// background queue from `call(...)`.
  private static func sendOneFrame(path: String, payload: Data) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw RPCError.socketError(errno: errno, op: "socket()") }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    // sockaddr_un.sun_path is 104 bytes on Darwin.
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw RPCError.socketError(errno: ENAMETOOLONG, op: "path too long")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (i, b) in pathBytes.enumerated() { dest[i] = b }
      }
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, addrLen)
      }
    }
    if connectResult < 0 {
      switch errno {
      case ECONNREFUSED, ENOENT: throw RPCError.daemonNotRunning
      default: throw RPCError.socketError(errno: errno, op: "connect()")
      }
    }

    // Apply send + recv timeouts via SO_SNDTIMEO / SO_RCVTIMEO. Cheaper
    // than a separate watchdog thread.
    var tv = timeval(
      tv_sec: Int(timeoutSeconds),
      tv_usec: Int32((timeoutSeconds - Double(Int(timeoutSeconds))) * 1_000_000)
    )
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Write the entire payload.
    var written = 0
    payload.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
      let base = rawBuf.baseAddress!
      while written < payload.count {
        let n = Darwin.write(fd, base.advanced(by: written), payload.count - written)
        if n <= 0 { break }
        written += n
      }
    }
    if written != payload.count {
      if errno == EAGAIN || errno == EWOULDBLOCK { throw RPCError.timeout }
      throw RPCError.socketError(errno: errno, op: "write()")
    }

    // Read until we see a newline. Daemon frames are tiny (KB-range)
    // so a single 4 KiB buffer + concat-into-Data loop is fine.
    var buffer = Data()
    let chunkSize = 4096
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let n = chunk.withUnsafeMutableBufferPointer { ptr in
        Darwin.read(fd, ptr.baseAddress, chunkSize)
      }
      if n == 0 {
        // EOF before newline — typically peer-auth rejection (daemon
        // closes the connection without responding).
        if buffer.isEmpty { throw RPCError.peerAuthRejected }
        break
      }
      if n < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { throw RPCError.timeout }
        throw RPCError.socketError(errno: errno, op: "read()")
      }
      buffer.append(chunk, count: n)
      if buffer.contains(0x0a) { break }
    }

    // Trim the newline terminator(s) so JSONDecoder gets a clean frame.
    while let last = buffer.last, last == 0x0a || last == 0x0d {
      buffer.removeLast()
    }
    return buffer
  }
}

// MARK: - Permissive JSON value

/// JSON value Decodable + Encodable bridge used by `AnyDecodable` to
/// round-trip an unknown subdocument without losing fidelity. Standard
/// library doesn't ship one; this is the minimal version covering all
/// six JSON types.
fileprivate enum JSONValue: Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let b = try? c.decode(Bool.self) { self = .bool(b); return }
    if let n = try? c.decode(Double.self) { self = .number(n); return }
    if let s = try? c.decode(String.self) { self = .string(s); return }
    if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
    if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognized JSON value")
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}
