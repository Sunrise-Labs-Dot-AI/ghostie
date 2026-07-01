import Foundation

/// Append-only JSONL log of FAILED sends, so a send that errors leaves a durable
/// trace. Today nothing records failures: the send-audit log holds successes
/// only, and chat.db holds queued messages only — so a hard send failure (the
/// "I had to resend Jordan by hand" case) is invisible after the fact. Shared
/// on-disk format with the TS daemon side.
///
/// Path: ~/.messages-mcp/logs/send-failures.log (0600 — `handle` is a
/// phone/email in cleartext, same sensitivity as the existing send-audit log).
enum SendFailureLog {
  struct Entry: Codable, Equatable {
    let ts: String
    let platform: String
    let handle: String
    /// The send strategy that failed: "chat-id", "buddy-cascade",
    /// "non-imessage-first", "group", "group-create", etc.
    let route: String
    let error: String
    let durationMs: Int
    /// Origin of the send: "swift-direct", "swift-draft", "ts-send_draft".
    let source: String

    enum CodingKeys: String, CodingKey {
      case ts, platform, handle, route, error
      case durationMs = "duration_ms"
      case source
    }
  }

  /// Pure constructor (unit-tested). `now` is injectable for deterministic tests.
  static func makeEntry(
    platform: String,
    handle: String,
    route: String,
    error: String,
    durationMs: Int,
    source: String,
    now: Date = Date()
  ) -> Entry {
    Entry(
      ts: Self.isoFormatter.string(from: now),
      platform: platform,
      handle: handle,
      route: route,
      error: error,
      durationMs: durationMs,
      source: source
    )
  }

  /// One compact JSON line (no trailing newline), or nil if encoding fails.
  static func encodeLine(_ entry: Entry) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(entry) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static var logURL: URL {
    AppStoragePaths.homeDirectory
      .appendingPathComponent(".messages-mcp")
      .appendingPathComponent("logs")
      .appendingPathComponent("send-failures.log")
  }

  /// Best-effort append. Never throws — a logging failure must not affect the
  /// send result the user sees.
  static func record(
    platform: String,
    handle: String,
    route: String,
    error: String,
    durationMs: Int,
    source: String
  ) {
    let entry = makeEntry(
      platform: platform, handle: handle, route: route,
      error: error, durationMs: durationMs, source: source
    )
    guard let line = encodeLine(entry) else { return }
    let url = logURL
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url, options: .atomic)
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}
