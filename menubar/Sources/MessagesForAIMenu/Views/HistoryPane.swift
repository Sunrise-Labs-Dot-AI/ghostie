import SwiftUI
import SQLite3

struct HistoryFeedItem: Identifiable, Equatable {
  enum Kind: String {
    case sentMessage
    case sendAudit
    case mcpActivity
  }

  let id: String
  let kind: Kind
  let date: Date
  let title: String
  let detail: String
  let preview: String?
  let platform: Platform?
  let activityTransport: String?
  let activityTool: String?
  let systemImage: String
  let tint: HistoryTint

  init(
    id: String,
    kind: Kind,
    date: Date,
    title: String,
    detail: String,
    preview: String?,
    platform: Platform?,
    activityTransport: String? = nil,
    activityTool: String? = nil,
    systemImage: String,
    tint: HistoryTint
  ) {
    self.id = id
    self.kind = kind
    self.date = date
    self.title = title
    self.detail = detail
    self.preview = preview
    self.platform = platform
    self.activityTransport = activityTransport
    self.activityTool = activityTool
    self.systemImage = systemImage
    self.tint = tint
  }
}

enum HistoryTint {
  case blue
  case green
  case amber
  case neutral

  func color(_ scheme: ColorScheme) -> Color {
    switch self {
    case .blue: return DS.Color.blue
    case .green: return DS.Color.green(scheme)
    case .amber: return DS.Color.amber(scheme)
    case .neutral: return DS.Color.ink3(scheme)
    }
  }
}

enum HistoryFeedLoader {
  private static let tailReadBytes: UInt64 = 256 * 1024
  private static let fallbackDedupWindow: TimeInterval = 2
  private static let isoFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let isoPlainFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
  private static let absoluteFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  static func load(home: URL = AppStoragePaths.homeDirectory, drafts: [Draft], limit: Int = 200) -> [HistoryFeedItem] {
    let sentDraftIDs = Set(drafts.filter(\.isSent).map(\.id))
    var items: [HistoryFeedItem] = []
    items.append(contentsOf: sentDraftItems(drafts))
    items.append(contentsOf: iMessageAuditItems(home: home, excludingDraftIDs: sentDraftIDs))
    items.append(contentsOf: whatsAppAuditItems(home: home, excludingDraftIDs: sentDraftIDs))
    let activityItems = mcpActivityItems(home: home)
    items.append(contentsOf: activityItems)
    items.append(contentsOf: latestWitnessFallbackItems(home: home, existingActivity: activityItems))
    return Array(items.sorted { $0.date > $1.date }.prefix(limit))
  }

  private static func sentDraftItems(_ drafts: [Draft]) -> [HistoryFeedItem] {
    drafts.compactMap { draft in
      guard draft.isSent, let sent = draft.sentDate else { return nil }
      let recipient = draft.recipientDisplayName
      let service = draft.send_service ?? draft.effectivePlatform.displayName
      return HistoryFeedItem(
        id: "sent-draft-\(draft.id)",
        kind: .sentMessage,
        date: sent,
        title: "Sent to \(recipient)",
        detail: "\(service) · \(absolute(sent))",
        preview: draft.body,
        platform: draft.effectivePlatform,
        systemImage: "paperplane.fill",
        tint: draft.effectivePlatform == .whatsapp ? .green : .blue
      )
    }
  }

  private struct RawIMessageAudit: Decodable {
    let ts: String
    let draft_id: String
    let to_handle: String
    let body_sha256: String
    let service: String
  }

  private static func iMessageAuditItems(home: URL, excludingDraftIDs sentDraftIDs: Set<String>) -> [HistoryFeedItem] {
    let url = home.appendingPathComponent(".messages-mcp/send-audit.log")
    guard let raw = tailText(url) else { return [] }
    return raw.split(separator: "\n").compactMap { line in
      guard let data = String(line).data(using: .utf8),
            let audit = try? JSONDecoder().decode(RawIMessageAudit.self, from: data),
            !sentDraftIDs.contains(audit.draft_id),
            let date = parseISO(audit.ts) else {
        return nil
      }
      return HistoryFeedItem(
        id: "imessage-audit-\(audit.draft_id)-\(audit.ts)",
        kind: .sendAudit,
        date: date,
        title: "\(audit.service) send recorded",
        detail: "To \(audit.to_handle) · \(absolute(date))",
        preview: "Body hash \(shortHash(audit.body_sha256))",
        platform: .imessage,
        systemImage: "checkmark.seal",
        tint: .blue
      )
    }
  }

  private static func whatsAppAuditItems(home: URL, excludingDraftIDs sentDraftIDs: Set<String>) -> [HistoryFeedItem] {
    let url = home.appendingPathComponent(".whatsapp-mcp/audit.db")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }

    // Keep this projection in sync with mcps/whatsapp-drafts audit migration.
    let sql = "SELECT ts, draft_id, to_handle, body_sha256, status FROM sends ORDER BY ts DESC LIMIT 200"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
    defer { sqlite3_finalize(stmt) }

    var items: [HistoryFeedItem] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let ts = sqlite3_column_int64(stmt, 0)
      let date = Date(timeIntervalSince1970: Double(ts) / 1000)
      let draftID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
      guard !sentDraftIDs.contains(draftID) else { continue }
      let toHandle = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "unknown"
      let hash = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
      let status = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "ok"
      let ok = status == "ok"
      items.append(
        HistoryFeedItem(
          id: "whatsapp-audit-\(draftID)-\(ts)",
          kind: .sendAudit,
          date: date,
          title: ok ? "WhatsApp send recorded" : "WhatsApp send failed",
          detail: "To \(prettyWhatsAppHandle(toHandle)) · \(absolute(date))",
          preview: hash.isEmpty ? nil : "Body hash \(shortHash(hash))",
          platform: .whatsapp,
          systemImage: ok ? "checkmark.seal" : "exclamationmark.triangle.fill",
          tint: ok ? .green : .amber
        )
      )
    }
    return items
  }

  private struct RawMCPActivity: Decodable {
    let transport: String
    let tool: String
    let ts: String
    let pid: Int?
    let writer_path: String?
    let chatdb_access: String?
  }

  private static func mcpActivityItems(home: URL) -> [HistoryFeedItem] {
    let url = home.appendingPathComponent(".messages-mcp/mcp-activity.jsonl")
    guard let raw = tailText(url) else { return [] }
    return raw.split(separator: "\n").compactMap { line in
      guard let data = String(line).data(using: .utf8),
            let activity = try? JSONDecoder().decode(RawMCPActivity.self, from: data),
            let date = parseISO(activity.ts) else {
        return nil
      }
      return mcpItem(
        id: "mcp-\(activity.transport)-\(activity.tool)-\(activity.ts)",
        date: date,
        transport: activity.transport,
        tool: activity.tool,
        chatDbAccess: activity.chatdb_access,
        pid: activity.pid
      )
    }
  }

  private struct RawWitness: Decodable {
    let tool: String
    let ts: String
    let pid: Int?
    let writer_path: String?
    let chatdb_access: String?
  }

  private static func latestWitnessFallbackItems(home: URL, existingActivity: [HistoryFeedItem]) -> [HistoryFeedItem] {
    var items: [HistoryFeedItem] = []
    for transport in ["imessage", "whatsapp"] {
      let url = home.appendingPathComponent(".messages-mcp/last_invocation_\(transport).json")
      guard let data = try? Data(contentsOf: url),
            let witness = try? JSONDecoder().decode(RawWitness.self, from: data),
            let date = parseISO(witness.ts),
            !hasActivity(existingActivity, transport: transport, tool: witness.tool, date: date) else {
        continue
      }
      items.append(
        mcpItem(
          id: "latest-witness-\(transport)-\(witness.tool)-\(witness.ts)",
          date: date,
          transport: transport,
          tool: witness.tool,
          chatDbAccess: witness.chatdb_access,
          pid: witness.pid
        )
      )
    }
    return items
  }

  private static func mcpItem(id: String, date: Date, transport: String, tool: String, chatDbAccess: String?, pid: Int?) -> HistoryFeedItem {
    let platform = Platform(rawValue: transport)
    let titleTransport = platform?.displayName ?? transport
    let accessNote: String = {
      switch chatDbAccess {
      case "ok": return " · FDA ok"
      case "permission_denied": return " · FDA denied"
      case "not_found": return " · no Messages DB"
      default: return ""
      }
    }()
    let pidNote = pid.map { " · pid \($0)" } ?? ""
    return HistoryFeedItem(
      id: id,
      kind: .mcpActivity,
      date: date,
      title: "\(titleTransport) MCP: \(humanToolName(tool))",
      detail: "\(absolute(date))\(pidNote)\(accessNote)",
      preview: nil,
      platform: platform,
      activityTransport: transport,
      activityTool: tool,
      systemImage: "terminal",
      tint: platform == .whatsapp ? .green : .neutral
    )
  }

  private static func hasActivity(_ items: [HistoryFeedItem], transport: String, tool: String, date: Date) -> Bool {
    items.contains { item in
      guard item.kind == .mcpActivity,
            item.activityTransport == transport,
            item.activityTool == tool else {
        return false
      }
      return abs(item.date.timeIntervalSince(date)) < fallbackDedupWindow
    }
  }

  private static func humanToolName(_ tool: String) -> String {
    tool
      .split(separator: "_")
      .map { part in part.prefix(1).uppercased() + part.dropFirst() }
      .joined(separator: " ")
  }

  private static func parseISO(_ raw: String) -> Date? {
    if let date = isoFractionalFormatter.date(from: raw) { return date }
    return isoPlainFormatter.date(from: raw)
  }

  private static func absolute(_ date: Date) -> String {
    absoluteFormatter.string(from: date)
  }

  private static func tailText(_ url: URL, maxBytes: UInt64 = tailReadBytes) -> String? {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      let offset = size > maxBytes ? size - maxBytes : 0
      try handle.seek(toOffset: offset)
      guard let data = try handle.readToEnd(),
            var text = String(data: data, encoding: .utf8) else {
        return nil
      }
      if offset > 0, let newline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: newline)...])
      }
      return text
    } catch {
      return nil
    }
  }

  private static func shortHash(_ hash: String) -> String {
    String(hash.prefix(10))
  }

  private static func prettyWhatsAppHandle(_ jid: String) -> String {
    guard let at = jid.firstIndex(of: "@") else { return jid }
    let suffix = jid[at...]
    if suffix == "@g.us" { return jid }
    let digits = jid[..<at].filter(\.isNumber)
    guard !digits.isEmpty else { return jid }
    if digits.count == 11, digits.hasPrefix("1") {
      let local = String(digits.dropFirst())
      return "+1 \(local.prefix(3))-\(local.dropFirst(3).prefix(3))-\(local.suffix(4))"
    }
    return "+\(digits)"
  }
}

struct HistoryPane: View {
  @EnvironmentObject private var store: DraftStore
  @Environment(\.colorScheme) private var colorScheme
  @State private var items: [HistoryFeedItem] = []
  @State private var loadToken = UUID()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if items.isEmpty {
          emptyState
        } else {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
              HistoryFeedRow(item: item)
            }
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 760, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.Color.g100(colorScheme))
    .onAppear { reload() }
    .onChange(of: store.drafts.map { "\($0.id)-\($0.sent_at ?? "")" }) { _, _ in reload() }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 6) {
        Label("History", systemImage: "clock.arrow.circlepath")
          .font(DS.Font.paneTitle)
          .foregroundStyle(DS.Color.ink(colorScheme))
          .labelStyle(.titleAndIcon)
        Text("Sent messages from the tool and MCP activity, newest first.")
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.ink3(colorScheme))
      }
      Spacer()
      Button {
        reload()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .dsButton(.ghost)
      .help("Refresh history")
      .accessibilityLabel("Refresh history")
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "clock")
        .font(.system(size: 34))
        .foregroundStyle(.tertiary)
      Text("No history yet")
        .font(DS.Font.settingsLabel)
        .foregroundStyle(DS.Color.ink(colorScheme))
      Text("Sent messages and MCP tool calls will appear here.")
        .font(DS.Font.settingsCaption)
        .foregroundStyle(DS.Color.ink3(colorScheme))
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, minHeight: 260)
    .dsCard(colorScheme, fill: DS.Color.g080(colorScheme))
  }

  private func reload() {
    let token = UUID()
    loadToken = token
    let drafts = store.drafts
    DispatchQueue.global(qos: .userInitiated).async {
      let loaded = HistoryFeedLoader.load(drafts: drafts)
      DispatchQueue.main.async {
        guard loadToken == token else { return }
        items = loaded
      }
    }
  }
}

private struct HistoryFeedRow: View {
  let item: HistoryFeedItem
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: item.systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(item.tint.color(colorScheme))
        .frame(width: 24, height: 24)
        .background(
          RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(DS.Color.g130(colorScheme))
        )

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.title)
            .font(DS.Font.settingsLabel)
            .foregroundStyle(DS.Color.ink(colorScheme))
            .lineLimit(1)
            .truncationMode(.tail)
          if let platform = item.platform {
            PlatformBadge(platform: platform)
          }
          Spacer(minLength: 0)
          Text(relativeDate)
            .font(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.ink3(colorScheme))
            .monospacedDigit()
        }
        Text(item.detail)
          .font(DS.Font.monoValue)
          .foregroundStyle(DS.Color.ink3(colorScheme))
          .lineLimit(1)
          .truncationMode(.middle)
        if let preview = item.preview, !preview.isEmpty {
          Text(preview)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ink2(colorScheme))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .fill(DS.Color.g080(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        .strokeBorder(DS.Color.line(colorScheme), lineWidth: 1)
    )
  }

  private var relativeDate: String {
    Self.relativeFormatter.localizedString(for: item.date, relativeTo: Date())
  }

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()
}
