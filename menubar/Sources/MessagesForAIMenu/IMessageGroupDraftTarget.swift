import Foundation
import SQLite3

struct IMessageGroupDraftTarget: Codable, Equatable {
  var chat_guid: String?
  var participant_handles: [String]
  var participant_names: [String]

  var displayName: String {
    let names = participant_names
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !names.isEmpty { return names.joined(separator: ", ") }
    return participant_handles.joined(separator: ", ")
  }

  /// User-facing row title that makes the group-ness explicit ("Group thread
  /// with Maya & Alex") instead of a bare name list that reads like a single
  /// contact. Falls back to handles, then a generic label; never the raw
  /// canonical binding.
  var groupDisplayLabel: String {
    let names = participant_names
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let people = names.isEmpty
      ? participant_handles
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      : names
    guard !people.isEmpty else { return "Group thread" }
    let joined = people.count == 2 ? people.joined(separator: " & ") : people.joined(separator: ", ")
    return "Group thread with \(joined)"
  }

  var canonicalRecipient: String {
    if let chat = chat_guid?.trimmingCharacters(in: .whitespacesAndNewlines), !chat.isEmpty {
      return "imessage-group:\(chat)"
    }
    let key = participant_handles
      .compactMap { ContactAvatarStore.canonicalKey($0) }
      .sorted()
      .joined(separator: "|")
    return "imessage-group-pending:\(key)"
  }
}

enum IMessageGroupTargetError: Error, LocalizedError, CustomStringConvertible, Equatable {
  case wrongParticipantCount
  case duplicateParticipants
  case invalidParticipant

  var description: String {
    switch self {
    case .wrongParticipantCount:
      return "Babysitter group texts must include exactly one babysitter and one partner."
    case .duplicateParticipants:
      return "Babysitter and partner must be different contacts."
    case .invalidParticipant:
      return "Every group participant needs a usable Messages handle."
    }
  }

  /// LocalizedError conformance so `error.localizedDescription` (what
  /// DraftSender surfaces in SendResult) yields the policy text instead of
  /// the generic "The operation couldn't be completed" Foundation string.
  var errorDescription: String? { description }
}

enum IMessageGroupTargetPolicy {
  static func makeTarget(
    sitter: BabysitterProfile,
    partner: BabysitterContactSnapshot,
    resolver: IMessageGroupResolving = IMessageGroupResolver()
  ) throws -> IMessageGroupDraftTarget {
    let sitterHandle = sitter.displayHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    let partnerHandle = partner.bestHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    let handles = [sitterHandle, partnerHandle]
    try validateTwoParticipantTarget(handles)
    let resolved = resolver.resolveExactGroup(participantHandles: handles)
    return IMessageGroupDraftTarget(
      chat_guid: resolved?.chatGUID,
      participant_handles: handles,
      participant_names: [sitter.contact.name, partner.name]
    )
  }

  static func validateTwoParticipantTarget(_ handles: [String]) throws {
    let trimmed = handles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard trimmed.count == 2 else { throw IMessageGroupTargetError.wrongParticipantCount }
    let keys = trimmed.compactMap { ContactAvatarStore.canonicalKey($0) }
    guard keys.count == 2 else { throw IMessageGroupTargetError.invalidParticipant }
    guard Set(keys).count == 2 else { throw IMessageGroupTargetError.duplicateParticipants }
  }
}

struct IMessageResolvedGroup: Equatable {
  let chatID: Int
  let chatGUID: String
}

protocol IMessageGroupResolving {
  func resolveExactGroup(participantHandles: [String]) -> IMessageResolvedGroup?
}

struct IMessageGroupResolver: IMessageGroupResolving {
  var dbURL: URL = AppStoragePaths.homeDirectory
    .appendingPathComponent("Library")
    .appendingPathComponent("Messages")
    .appendingPathComponent("chat.db")

  func resolveExactGroup(participantHandles: [String]) -> IMessageResolvedGroup? {
    let targetKeys = Set(participantHandles.compactMap { ContactAvatarStore.canonicalKey($0) })
    guard targetKeys.count == participantHandles.count, targetKeys.count == 2 else { return nil }
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return nil
    }
    defer { sqlite3_close(db) }

    // Phase 1: participant sets straight from chat_handle_join — no message
    // join. The previous query GROUP_CONCAT'ed handle ids across EVERY
    // message row per chat (chat × messages fan-out) and sorted the whole DB
    // by MAX(m.date); on a big chat.db that's seconds of work for what is a
    // membership lookup. chat_handle_join is tiny (one row per member).
    let sql = """
      SELECT c.ROWID,
             c.guid,
             GROUP_CONCAT(h.id, char(31))
      FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      JOIN handle h ON h.ROWID = chj.handle_id
      GROUP BY c.ROWID
      HAVING COUNT(DISTINCT h.ROWID) = ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(targetKeys.count))

    var candidates: [IMessageResolvedGroup] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      guard let guidPtr = sqlite3_column_text(stmt, 1) else { continue }
      let chatGUID = String(cString: guidPtr)
      let participantsRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
      let participantKeys = Set(
        participantsRaw
          .split(separator: "\u{1F}")
          .compactMap { ContactAvatarStore.canonicalKey(String($0)) }
      )
      if participantKeys == targetKeys {
        candidates.append(IMessageResolvedGroup(chatID: chatID, chatGUID: chatGUID))
      }
    }
    guard candidates.count > 1 else { return candidates.first }

    // Phase 2: same people across services (iMessage + SMS chats, say) —
    // pick the most recently used. chat_message_join carries message_date
    // and is indexed by chat_id, so this stays per-candidate cheap and the
    // message table is never touched. Older schemas without message_date
    // fall back to the newest chat row.
    let recency = mostRecentMessageDates(db: db, chatIDs: candidates.map(\.chatID))
    return candidates.max { a, b in
      let ra = recency[a.chatID] ?? Int64.min
      let rb = recency[b.chatID] ?? Int64.min
      if ra != rb { return ra < rb }
      return a.chatID < b.chatID
    }
  }

  private func mostRecentMessageDates(db: OpaquePointer, chatIDs: [Int]) -> [Int: Int64] {
    var stmt: OpaquePointer?
    let sql = "SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = ?"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
    defer { sqlite3_finalize(stmt) }
    var out: [Int: Int64] = [:]
    for chatID in chatIDs {
      sqlite3_reset(stmt)
      sqlite3_clear_bindings(stmt)
      sqlite3_bind_int64(stmt, 1, Int64(chatID))
      if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
        out[chatID] = sqlite3_column_int64(stmt, 0)
      }
    }
    return out
  }
}

/// Resolves the most-recent 1:1 chat for a handle so a staged-draft send can
/// target `chat id` (whose GUID prefix encodes the service) instead of guessing
/// iMessage. Guessing silently fails for SMS-only contacts: `buddy <addr> of
/// iMessageService` does not error, so the message is "sent" into the void and
/// the SMS fallback never fires. Sending into the existing chat routes through
/// the thread's real transport. Two-phase like IMessageGroupResolver: cheap
/// membership scan, then pick the most-recently-used when a person has chats
/// across services (an iMessage and an SMS chat, say).
struct IMessageDirectChatResolver {
  var dbURL: URL = AppStoragePaths.homeDirectory
    .appendingPathComponent("Library")
    .appendingPathComponent("Messages")
    .appendingPathComponent("chat.db")

  func resolveDirectChat(handle: String) -> IMessageResolvedChat? {
    guard let targetKey = ContactAvatarStore.canonicalKey(handle) else { return nil }
    guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return nil
    }
    defer { sqlite3_close(db) }

    // Single-participant chats only, with that participant's handle. No message
    // join here — membership lives in chat_handle_join (one row per member).
    let sql = """
      SELECT c.ROWID,
             c.guid,
             h.id
      FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      JOIN handle h ON h.ROWID = chj.handle_id
      WHERE (
        SELECT COUNT(*) FROM chat_handle_join one WHERE one.chat_id = c.ROWID
      ) = 1
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }

    var candidates: [IMessageResolvedChat] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let chatID = Int(sqlite3_column_int64(stmt, 0))
      guard let guidPtr = sqlite3_column_text(stmt, 1) else { continue }
      let chatGUID = String(cString: guidPtr)
      let rawHandle = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
      // Only chats AppleScript can actually address by `chat id`. macOS stores
      // some chats with an unbound/aggregate guid ("any;-;+1555…"); sending to
      // that id fails with -1728 ("Can't get chat id"). Skip them so the send
      // falls back to the buddy cascade instead of hard-failing.
      if ContactAvatarStore.canonicalKey(rawHandle) == targetKey,
         Self.isAddressableChatGUID(chatGUID) {
        candidates.append(IMessageResolvedChat(chatID: chatID, chatGUID: chatGUID))
      }
    }
    guard candidates.count > 1 else { return candidates.first }

    // Same person across services → the most recently used chat is what
    // Messages.app would continue in.
    let recency = mostRecentMessageDates(db: db, chatIDs: candidates.map(\.chatID))
    return candidates.max { a, b in
      let ra = recency[a.chatID] ?? Int64.min
      let rb = recency[b.chatID] ?? Int64.min
      if ra != rb { return ra < rb }
      return a.chatID < b.chatID
    }
  }

  private func mostRecentMessageDates(db: OpaquePointer, chatIDs: [Int]) -> [Int: Int64] {
    var stmt: OpaquePointer?
    let sql = "SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = ?"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
    defer { sqlite3_finalize(stmt) }
    var out: [Int: Int64] = [:]
    for chatID in chatIDs {
      sqlite3_reset(stmt)
      sqlite3_clear_bindings(stmt)
      sqlite3_bind_int64(stmt, 1, Int64(chatID))
      if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
        out[chatID] = sqlite3_column_int64(stmt, 0)
      }
    }
    return out
  }

  /// True only when a chat GUID's service prefix is one AppleScript `chat id`
  /// can resolve: `iMessage`/`SMS`/`RCS`. Deliberately STRICT (not via
  /// `serviceFromChatGUID`, which defaults unknown prefixes to "iMessage" and
  /// would wrongly admit an unaddressable `any;-;…`).
  static func isAddressableChatGUID(_ guid: String) -> Bool {
    let prefix = guid.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init)?.uppercased() ?? ""
    return prefix == "IMESSAGE" || prefix == "SMS" || prefix == "RCS"
  }
}

struct IMessageResolvedChat: Equatable {
  let chatID: Int
  let chatGUID: String
}
