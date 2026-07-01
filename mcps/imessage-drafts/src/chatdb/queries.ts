// All SQL against chat.db is parameterized and lives here. Keeping queries
// centralized makes it easy to audit for injection (none — parameters only)
// and for accidental unbounded scans.

import { statSync } from "node:fs";

import { openChatDb, chatDbPath, appleDateToIsoUtc, isoUtcToAppleDateNs } from "./open.ts";
import { bestMessageBody, truncateBody, decodeAttributedBody, isOverBudget } from "./decode.ts";
import { resolveHandle, resolveMany, findHandlesByContactName } from "./contacts.ts";
// canonChatHandle is the shared canonHandle (unified in canon.ts; see
// ROOT_CAUSE-contact-filter.md #1). Aliased to keep the local call sites stable.
import { canonHandle as canonChatHandle } from "./canon.ts";

export interface ThreadSummary {
  thread_id: number;
  guid: string;
  display_name: string | null;
  is_group: boolean;
  participants: { handle: string; name: string | null }[];
  last_message_at: string | null;
  last_message_from: { handle: string | null; name: string | null; from_me: boolean } | null;
  last_message_preview: string | null;
}

// The message an inline reply points back at. Resolved from chat.db's
// `message.thread_originator_guid` (the originator's `guid`). `body` is null
// when the originator isn't in the returned page / was deleted — the caller
// still learns the message was a reply. `body` and `sender.name` are
// peer-/sidecar-sourced and MUST be wrapped as untrusted at the tool boundary,
// same as the top-level fields.
export interface ReplyTo {
  guid: string;
  body: string | null;
  from_me: boolean;
  sender: { handle: string | null; name: string | null };
}

// Coarse media class derived from a chat.db attachment's mime_type / uti /
// filename. Lets Claude filter "show me the photos" without parsing MIME.
export type AttachmentKind = "image" | "video" | "audio" | "document" | "other";

// One attachment on a chat.db message, read from the `attachment` +
// `message_attachment_join` tables. This is metadata only — the bytes are not
// inlined. `path` is the local on-disk location (under
// ~/Library/Messages/Attachments, often stored ~-prefixed in chat.db); it lets
// the menu bar / a follow-up tool open or re-send the file. `filename` is the
// original transfer name as the sender labelled it and is UNTRUSTED — wrap it
// at the tool boundary like any peer-authored text.
export interface MessageAttachment {
  filename: string | null;
  path: string | null;
  mime_type: string | null;
  uti: string | null;
  total_bytes: number | null;
  is_sticker: boolean;
  kind: AttachmentKind;
}

export interface ThreadMessage {
  message_id: number;
  thread_id: number;
  sent_at: string | null;
  from_me: boolean;
  sender: { handle: string | null; name: string | null };
  body: string | null;
  // True when `body` was clipped to the byte budget (truncateBody) — the
  // returned text is intentionally shortened, not the complete message.
  body_truncated: boolean;
  is_read: boolean;
  has_attachments: boolean;
  // Per-attachment metadata (photos, videos, files, stickers) for messages
  // where has_attachments is true. Empty array when the message carries none.
  // The `filename` field on each entry is untrusted and wrapped at the tool
  // boundary.
  attachments: MessageAttachment[];
  // The message this one is an inline reply to, or null if it's not a reply.
  reply_to: ReplyTo | null;
}

// Lighter-weight shape we embed in staged drafts so the menu bar app can
// render thread context without reading chat.db itself. No message_id /
// thread_id / read state — the reviewer doesn't need those.
export interface DraftContextMessage {
  from_me: boolean;
  sender_handle: string | null;
  sender_name: string | null;
  body: string | null;
  sent_at: string | null;
  // Attachments on this context message, so the approval surface can show
  // "[Photo]" / a thumbnail next to the body the way Messages.app does.
  attachments: MessageAttachment[];
}

function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (c) => `\\${c}`);
}

// Cached map of canonical chat.db handle → its ROWID, populated on first use.
// chat.db's `handle` table is small (one row per (id, service) pair) so this
// is a one-time scan.
interface ChatHandleEntry { rowid: number; id: string; canon: string }
interface ChatHandlesCache {
  entries: ChatHandleEntry[];
  loadedAtMs: number;
  chatDbMtimeMs: number | null;
}
let chatHandlesCache: ChatHandleEntry[] | null = null;
let chatHandlesCacheMeta: ChatHandlesCache | null = null;
const CHAT_HANDLES_CACHE_TTL_MS = 60_000;

// Test-only: drop the cached handle list. Used between fixtures so test B
// doesn't see test A's chat.db handles.
export function _resetChatHandlesCacheForTesting(): void {
  chatHandlesCache = null;
  chatHandlesCacheMeta = null;
}
function loadChatHandles(): ChatHandleEntry[] {
  const now = Date.now();
  const chatDbMtimeMs = chatDbMtime();
  if (
    chatHandlesCacheMeta != null &&
    now - chatHandlesCacheMeta.loadedAtMs < CHAT_HANDLES_CACHE_TTL_MS &&
    chatHandlesCacheMeta.chatDbMtimeMs === chatDbMtimeMs
  ) {
    return chatHandlesCacheMeta.entries;
  }
  const db = openChatDb();
  const rows = db.query<{ ROWID: number; id: string }, []>(
    "SELECT ROWID, id FROM handle"
  ).all();
  chatHandlesCache = rows.map((r) => ({ rowid: r.ROWID, id: r.id, canon: canonChatHandle(r.id) }));
  chatHandlesCacheMeta = { entries: chatHandlesCache, loadedAtMs: now, chatDbMtimeMs };
  return chatHandlesCache;
}

function chatDbMtime(): number | null {
  try {
    return statSync(chatDbPath()).mtimeMs;
  } catch {
    // In tests the DB is in-memory; in production TCC may also deny stat.
    // Fall back to TTL-only invalidation rather than making contact-filter
    // lookups fail.
    return null;
  }
}

// Given a contact-name substring, return chat.db `handle.ROWID` values for
// any handle whose owner (per AddressBook) has a matching name. The caller
// uses these to widen a WHERE clause that would otherwise only match against
// the raw handle string.
function chatHandleRowIdsForContactName(filter: string): number[] {
  const targets = new Set(findHandlesByContactName(filter));
  if (targets.size === 0) return [];
  return loadChatHandles().filter((h) => targets.has(h.canon)).map((h) => h.rowid);
}

interface ListThreadRow {
  chat_id: number;
  guid: string;
  chat_display_name: string | null;
  style: number;
  last_msg_id: number;
  last_text: string | null;
  last_ab: Uint8Array | null;
  last_date: number | bigint | null;
  last_from_me: number;
  last_is_read: number;
  last_has_attach: number;
  last_handle_id: number | null;
  last_sender_handle: string | null;
}

function participantsForThreads(threadIds: readonly number[]): Map<number, string[]> {
  const out = new Map<number, string[]>();
  if (threadIds.length === 0) return out;
  const db = openChatDb();
  const placeholders = threadIds.map(() => "?").join(",");
  const rows = db.query<{ chat_id: number; handle: string }, number[]>(
    `SELECT chj.chat_id AS chat_id, h.id AS handle
     FROM chat_handle_join chj
     JOIN handle h ON h.ROWID = chj.handle_id
     WHERE chj.chat_id IN (${placeholders})`
  ).all(...threadIds);
  for (const r of rows) {
    const arr = out.get(r.chat_id) ?? [];
    arr.push(r.handle);
    out.set(r.chat_id, arr);
  }
  return out;
}

export interface ListThreadsArgs {
  limit: number;
  sinceIso?: string | undefined;
  beforeIso?: string | undefined;
  contactFilter?: string | undefined;
}

export interface ListThreadsResult {
  threads: ThreadSummary[];
  oldest_at: string | null;
  has_more: boolean;
}

export function listThreads(args: ListThreadsArgs): ListThreadsResult {
  const db = openChatDb();
  const { limit, sinceIso, beforeIso, contactFilter } = args;

  // Build the contact_filter widening list BEFORE the SQL: pre-resolve which
  // chat.db handle ROWIDs match the contact-name substring, so we can OR
  // them into the EXISTS clause as a fixed IN-list. This is what makes
  // contact_filter: "Fairfax" work even though the raw handle is "+14045550147".
  const matchedHandleRowIds = contactFilter ? chatHandleRowIdsForContactName(contactFilter) : [];

  const recencyParams: (string | number | bigint)[] = [];
  const recencyWhere: string[] = [];
  const params: (string | number | bigint)[] = [];
  let filterClause = "";

  if (sinceIso) {
    filterClause += " AND m.date >= ?";
    const sinceNs = isoUtcToAppleDateNs(sinceIso);
    params.push(sinceNs);
    recencyWhere.push("m2.date >= ?");
    recencyParams.push(sinceNs);
  }
  if (beforeIso) {
    filterClause += " AND m.date < ?";
    const beforeNs = isoUtcToAppleDateNs(beforeIso);
    params.push(beforeNs);
    recencyWhere.push("m2.date < ?");
    recencyParams.push(beforeNs);
  }
  if (contactFilter) {
    const like = `%${escapeLike(contactFilter)}%`;
    const handleInClause = matchedHandleRowIds.length
      ? ` OR h2.ROWID IN (${matchedHandleRowIds.map(() => "?").join(",")})`
      : "";
    filterClause +=
      " AND (EXISTS (" +
      "SELECT 1 FROM chat_handle_join chj2 " +
      "JOIN handle h2 ON h2.ROWID = chj2.handle_id " +
      `WHERE chj2.chat_id = c.ROWID AND (LOWER(h2.id) LIKE LOWER(?) ESCAPE '\\'${handleInClause}))` +
      " OR LOWER(COALESCE(c.display_name, '')) LIKE LOWER(?) ESCAPE '\\')";
    params.push(like);
    for (const id of matchedHandleRowIds) params.push(id);
    params.push(like);
  }
  const allParams = [...recencyParams, ...params, limit];
  const recencyWhereSql = recencyWhere.length > 0 ? `WHERE ${recencyWhere.join(" AND ")}` : "";

  // Recency CTE: keep the date cursor inside the CTE when present so large
  // histories don't first GROUP BY every chat ever and only then discard old
  // rows in the outer WHERE.
  const rows = db.query<ListThreadRow, (string | number | bigint)[]>(
    `WITH chat_recency AS (
       SELECT cmj2.chat_id, MAX(cmj2.message_id) AS last_msg_id
       FROM chat_message_join cmj2
       ${recencyWhere.length > 0 ? "JOIN message m2 ON m2.ROWID = cmj2.message_id" : ""}
       ${recencyWhereSql}
       GROUP BY cmj2.chat_id
     )
     SELECT c.ROWID AS chat_id,
            c.guid AS guid,
            c.display_name AS chat_display_name,
            c.style AS style,
            m.ROWID AS last_msg_id,
            m.text AS last_text,
            m.attributedBody AS last_ab,
            m.date AS last_date,
            m.is_from_me AS last_from_me,
            m.is_read AS last_is_read,
            m.cache_has_attachments AS last_has_attach,
            m.handle_id AS last_handle_id,
            h.id AS last_sender_handle
     FROM chat c
     JOIN chat_recency cr ON cr.chat_id = c.ROWID
     JOIN message m ON m.ROWID = cr.last_msg_id
     LEFT JOIN handle h ON h.ROWID = m.handle_id
     WHERE 1=1${filterClause}
     ORDER BY m.date DESC
     LIMIT ?`
  ).all(...allParams);

  const threadIds = rows.map((r) => r.chat_id);
  const partsByThread = participantsForThreads(threadIds);

  // Pre-resolve all participant + sender handles via the bulk in-memory map.
  const allHandles = new Set<string>();
  for (const arr of partsByThread.values()) for (const h of arr) allHandles.add(h);
  for (const r of rows) if (r.last_sender_handle) allHandles.add(r.last_sender_handle);
  const nameMap = resolveMany([...allHandles]);

  const threads: ThreadSummary[] = rows.map((r) => {
    const handles = partsByThread.get(r.chat_id) ?? [];
    return {
      thread_id: r.chat_id,
      guid: r.guid,
      display_name: r.chat_display_name,
      is_group: r.style === 43 || handles.length > 1,
      participants: handles.map((h) => ({ handle: h, name: nameMap.get(h) ?? null })),
      last_message_at: appleDateToIsoUtc(r.last_date),
      last_message_from:
        r.last_from_me === 1
          ? { handle: null, name: null, from_me: true }
          : {
              handle: r.last_sender_handle,
              name: r.last_sender_handle ? nameMap.get(r.last_sender_handle) ?? null : null,
              from_me: false,
            },
      last_message_preview: truncateBody(bestMessageBody(r.last_text, r.last_ab)),
    };
  });

  const oldest = threads.length > 0 ? threads[threads.length - 1]!.last_message_at : null;
  return { threads, oldest_at: oldest, has_more: threads.length === limit };
}

interface MessageRowLite {
  ROWID: number;
  text: string | null;
  attributedBody: Uint8Array | null;
  date: number | bigint | null;
  is_from_me: number;
  is_read: number;
  cache_has_attachments: number;
  handle_id: number | null;
  sender_handle: string | null;
  thread_id: number;
  // Reply columns — only SELECTed by getThreadMessages / searchMessages
  // (the recentContext query omits them), hence optional.
  guid?: string;
  thread_originator_guid?: string | null;
}

// Resolve a set of originator message GUIDs to their displayable form
// (body + sender) in ONE batched query — used to populate
// `ThreadMessage.reply_to` without an N+1 per reply. GUIDs are globally
// unique in chat.db, so the lookup isn't thread-scoped.
function resolveOriginators(guids: readonly string[]): Map<string, ReplyTo> {
  const out = new Map<string, ReplyTo>();
  if (guids.length === 0) return out;
  const db = openChatDb();
  const placeholders = guids.map(() => "?").join(",");
  const rows = db.query<{
    guid: string;
    text: string | null;
    attributedBody: Uint8Array | null;
    is_from_me: number;
    sender_handle: string | null;
  }, string[]>(
    `SELECT m.guid AS guid,
            m.text AS text,
            m.attributedBody AS attributedBody,
            m.is_from_me AS is_from_me,
            h.id AS sender_handle
     FROM message m
     LEFT JOIN handle h ON h.ROWID = m.handle_id
     WHERE m.guid IN (${placeholders})`
  ).all(...guids);

  const handles = new Set<string>();
  for (const r of rows) if (r.sender_handle) handles.add(r.sender_handle);
  const nameMap = resolveMany([...handles]);

  for (const r of rows) {
    out.set(r.guid, {
      guid: r.guid,
      body: truncateBody(bestMessageBody(r.text, r.attributedBody)),
      from_me: r.is_from_me === 1,
      sender: {
        handle: r.is_from_me ? null : r.sender_handle,
        name: r.is_from_me ? null : r.sender_handle ? nameMap.get(r.sender_handle) ?? null : null,
      },
    });
  }
  return out;
}

// Build a `reply_to` value from a message's thread_originator_guid. Falls back
// to a guid-only stub (body null) when the originator wasn't resolved.
function replyToFor(
  originatorGuid: string | null | undefined,
  resolved: Map<string, ReplyTo>,
): ReplyTo | null {
  if (!originatorGuid) return null;
  return (
    resolved.get(originatorGuid) ?? {
      guid: originatorGuid,
      body: null,
      from_me: false,
      sender: { handle: null, name: null },
    }
  );
}

// ─── attachments ────────────────────────────────────────────────────────────
// chat.db's `attachment` schema has drifted across macOS versions. The columns
// we read (filename, mime_type, transfer_name, total_bytes) exist on every
// supported release (macOS 14+), but `uti`, `is_sticker`, and `hide_attachment`
// are probed so an older/odd schema degrades to "no metadata" rather than a SQL
// error that would blank out an entire thread read.

const columnCache = new Map<string, Set<string>>();

function tableColumns(db: ReturnType<typeof openChatDb>, table: string): Set<string> {
  const cached = columnCache.get(table);
  if (cached) return cached;
  let cols = new Set<string>();
  try {
    const rows = db.query<{ name: string }, []>(`PRAGMA table_info(${table})`).all();
    cols = new Set(rows.map((r) => r.name));
  } catch {
    // Table missing (older schema / test fixture without it) → no columns.
  }
  columnCache.set(table, cols);
  return cols;
}

export function _resetAttachmentColumnCacheForTesting(): void {
  columnCache.clear();
}

// Map a chat.db attachment to a coarse kind. mime_type wins; uti and the
// filename extension are fallbacks for rows where Messages never recorded a
// MIME (common for stickers and some legacy transfers).
export function classifyAttachmentKind(
  mime: string | null,
  uti: string | null,
  filename: string | null,
): AttachmentKind {
  const m = (mime ?? "").toLowerCase();
  if (m.startsWith("image/")) return "image";
  if (m.startsWith("video/")) return "video";
  if (m.startsWith("audio/")) return "audio";
  if (m.length > 0) return "document";
  const u = (uti ?? "").toLowerCase();
  if (u.includes("image") || u.includes("sticker") || u.includes("heic") || u.includes("png") || u.includes("jpeg") || u.includes("gif")) return "image";
  if (u.includes("movie") || u.includes("video") || u.includes("mpeg-4")) return "video";
  if (u.includes("audio") || u.includes("waveform") || u.includes("m4a")) return "audio";
  const ext = (filename ?? "").toLowerCase().split(".").pop() ?? "";
  if (["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"].includes(ext)) return "image";
  if (["mov", "mp4", "m4v", "avi", "webm", "mkv", "3gp"].includes(ext)) return "video";
  if (["m4a", "mp3", "aac", "wav", "caf", "amr", "ogg", "opus"].includes(ext)) return "audio";
  if (ext.length > 0) return "document";
  return "other";
}

interface AttachmentRowLite {
  message_id: number;
  filename: string | null;
  mime_type: string | null;
  transfer_name: string | null;
  total_bytes: number | bigint | null;
  uti: string | null;
  is_sticker: number | null;
}

// Resolve attachments for a window of message ROWIDs in ONE batched IN query —
// mirrors the menu bar's chat.db reader so the MCP surface and the UI agree on
// what's attached. Returns a map keyed by message ROWID; messages with no
// attachments are simply absent. Never throws: any failure degrades to {}.
export function loadAttachmentsFor(messageRowIds: readonly number[]): Map<number, MessageAttachment[]> {
  const out = new Map<number, MessageAttachment[]>();
  if (messageRowIds.length === 0) return out;
  try {
    const db = openChatDb();
    const cols = tableColumns(db, "attachment");
    if (cols.size === 0) return out; // no attachment table in this schema
    const hasUti = cols.has("uti");
    const hasSticker = cols.has("is_sticker");
    const hasHide = cols.has("hide_attachment");
    const hideClause = hasHide ? "AND COALESCE(a.hide_attachment, 0) = 0" : "";
    const placeholders = messageRowIds.map(() => "?").join(",");
    const rows = db.query<AttachmentRowLite, number[]>(
      `SELECT maj.message_id AS message_id,
              a.filename AS filename,
              a.mime_type AS mime_type,
              a.transfer_name AS transfer_name,
              a.total_bytes AS total_bytes,
              ${hasUti ? "a.uti" : "NULL"} AS uti,
              ${hasSticker ? "a.is_sticker" : "0"} AS is_sticker
       FROM message_attachment_join maj
       JOIN attachment a ON a.ROWID = maj.attachment_id
       WHERE maj.message_id IN (${placeholders}) ${hideClause}
       ORDER BY maj.message_id, a.ROWID`
    ).all(...(messageRowIds as number[]));
    for (const r of rows) {
      const name = r.transfer_name ?? null;
      const bytes = r.total_bytes == null ? null : Number(r.total_bytes);
      const att: MessageAttachment = {
        filename: name,
        path: r.filename ?? null,
        mime_type: r.mime_type ?? null,
        uti: r.uti ?? null,
        total_bytes: bytes != null && Number.isFinite(bytes) ? bytes : null,
        is_sticker: r.is_sticker === 1,
        kind: classifyAttachmentKind(r.mime_type, r.uti, name),
      };
      const list = out.get(r.message_id);
      if (list) list.push(att);
      else out.set(r.message_id, [att]);
    }
  } catch {
    // FDA loss mid-read, schema drift, etc. — degrade to no attachment metadata.
  }
  return out;
}

export interface GetThreadArgs {
  threadId: number;
  limit: number;
  beforeIso?: string | undefined;
}

export function getThreadMessages(args: GetThreadArgs): ThreadMessage[] {
  const db = openChatDb();
  const { threadId, limit, beforeIso } = args;
  const params: (string | number | bigint)[] = [threadId];
  let extra = "";
  if (beforeIso) {
    extra = " AND m.date < ?";
    params.push(isoUtcToAppleDateNs(beforeIso));
  }
  params.push(limit);
  const rows = db.query<MessageRowLite, (string | number | bigint)[]>(
    `SELECT m.ROWID AS ROWID,
            m.guid AS guid,
            m.text AS text,
            m.attributedBody AS attributedBody,
            m.date AS date,
            m.is_from_me AS is_from_me,
            m.is_read AS is_read,
            m.cache_has_attachments AS cache_has_attachments,
            m.handle_id AS handle_id,
            m.thread_originator_guid AS thread_originator_guid,
            h.id AS sender_handle,
            cmj.chat_id AS thread_id
     FROM chat_message_join cmj
     JOIN message m ON m.ROWID = cmj.message_id
     LEFT JOIN handle h ON h.ROWID = m.handle_id
     WHERE cmj.chat_id = ?${extra}
     ORDER BY m.date DESC
     LIMIT ?`
  ).all(...params);

  const originators = resolveOriginators(
    rows.map((r) => r.thread_originator_guid).filter((g): g is string => !!g),
  );

  // Only probe the attachment tables for messages chat.db flags as carrying
  // one — keeps the IN query small on attachment-light threads.
  const attachmentsByMessage = loadAttachmentsFor(
    rows.filter((r) => r.cache_has_attachments === 1).map((r) => r.ROWID),
  );

  return rows.map((r) => {
    const raw = bestMessageBody(r.text, r.attributedBody);
    return {
      message_id: r.ROWID,
      thread_id: r.thread_id,
      sent_at: appleDateToIsoUtc(r.date),
      from_me: r.is_from_me === 1,
      sender: {
        handle: r.is_from_me ? null : r.sender_handle,
        name: r.is_from_me ? null : r.sender_handle ? resolveHandle(r.sender_handle) : null,
      },
      body: truncateBody(raw),
      body_truncated: isOverBudget(raw),
      is_read: r.is_read === 1,
      has_attachments: r.cache_has_attachments === 1,
      attachments: attachmentsByMessage.get(r.ROWID) ?? [],
      reply_to: replyToFor(r.thread_originator_guid, originators),
    };
  });
}

// Embedded in staged drafts so the menu bar app can render thread context
// without reading chat.db itself. Either a `threadId` (when the agent
// knows which thread to reply into) or a recipient `handle` (we find the
// best matching 1:1 thread). Failures (no FDA, no matching thread) return
// an empty array — never throw.
export interface RecentContextArgs {
  recipientHandle?: string | undefined;
  threadId?: number | undefined;
  limit: number;
}

// Structured breadcrumb of what happened during a context lookup. Embedded
// in the draft so when `context_messages` is null we can see *why* without
// needing to re-run the query or attach a debugger.
export interface ContextLookupDiagnostic {
  // Reason context_messages came back empty / null. "ok" means messages
  // were found and returned — diagnostic is informational, not an error.
  status:
    | "ok"
    | "no_input"               // neither threadId nor recipientHandle passed
    | "no_handle_match"        // canonicalized recipient didn't match any chat.db handle
    | "no_chat_for_handle"     // handle matched but no chat contains it
    | "empty_thread"           // chat exists but has zero messages (rare)
    | "error";                 // exception thrown — see `error` field
  canonical_recipient: string | null;  // what canonChatHandle produced
  matched_handle_ids: number[];         // handle.ROWID values matched (empty for status no_handle_match)
  chat_id: number | null;               // the chat we ended up querying
  message_count: number;                // length of the returned messages array
  error: string | null;                 // populated only on status="error"
}

export interface ContextLookupResult {
  messages: DraftContextMessage[];
  diagnostic: ContextLookupDiagnostic;
}

export function recentContextForRecipient(args: RecentContextArgs): ContextLookupResult {
  const { recipientHandle, threadId, limit } = args;
  if (limit <= 0) {
    return {
      messages: [],
      diagnostic: emptyDiagnostic("no_input", null),
    };
  }

  if (threadId == null && !recipientHandle) {
    return {
      messages: [],
      diagnostic: emptyDiagnostic("no_input", null),
    };
  }

  try {
    const db = openChatDb();
    let chatId: number | null = threadId ?? null;
    let canon: string | null = null;
    let matchedHandleIds: number[] = [];

    if (chatId == null && recipientHandle) {
      canon = canonChatHandle(recipientHandle);
      matchedHandleIds = loadChatHandles()
        .filter((h) => h.canon === canon)
        .map((h) => h.rowid);

      if (matchedHandleIds.length === 0) {
        return {
          messages: [],
          diagnostic: {
            status: "no_handle_match",
            canonical_recipient: canon,
            matched_handle_ids: [],
            chat_id: null,
            message_count: 0,
            error: null,
          },
        };
      }

      const placeholders = matchedHandleIds.map(() => "?").join(",");
      const row = db.query<{ chat_id: number }, number[]>(
        `WITH cand AS (
           SELECT DISTINCT chj.chat_id FROM chat_handle_join chj WHERE chj.handle_id IN (${placeholders})
         ),
         counts AS (
           SELECT chj.chat_id, COUNT(*) AS participant_count
           FROM chat_handle_join chj
           WHERE chj.chat_id IN (SELECT chat_id FROM cand)
           GROUP BY chj.chat_id
         ),
         recency AS (
           SELECT cmj.chat_id, MAX(cmj.message_id) AS last_msg
           FROM chat_message_join cmj
           WHERE cmj.chat_id IN (SELECT chat_id FROM cand)
           GROUP BY cmj.chat_id
         )
         SELECT counts.chat_id AS chat_id
         FROM counts JOIN recency ON recency.chat_id = counts.chat_id
         ORDER BY (counts.participant_count = 1) DESC, recency.last_msg DESC
         LIMIT 1`
      ).get(...matchedHandleIds) ?? null;

      if (!row) {
        return {
          messages: [],
          diagnostic: {
            status: "no_chat_for_handle",
            canonical_recipient: canon,
            matched_handle_ids: matchedHandleIds,
            chat_id: null,
            message_count: 0,
            error: null,
          },
        };
      }
      chatId = row.chat_id;
    }

    if (chatId == null) {
      return {
        messages: [],
        diagnostic: emptyDiagnostic("no_input", canon),
      };
    }

    const rows = db.query<MessageRowLite, [number, number]>(
      `SELECT m.ROWID AS ROWID,
              m.text AS text,
              m.attributedBody AS attributedBody,
              m.date AS date,
              m.is_from_me AS is_from_me,
              m.is_read AS is_read,
              m.cache_has_attachments AS cache_has_attachments,
              m.handle_id AS handle_id,
              h.id AS sender_handle,
              cmj.chat_id AS thread_id
       FROM chat_message_join cmj
       JOIN message m ON m.ROWID = cmj.message_id
       LEFT JOIN handle h ON h.ROWID = m.handle_id
       WHERE cmj.chat_id = ?
       ORDER BY m.date DESC
       LIMIT ?`
    ).all(chatId, limit);

    const reversed = rows.reverse();
    const ctxAttachments = loadAttachmentsFor(
      reversed.filter((r) => r.cache_has_attachments === 1).map((r) => r.ROWID),
    );
    const messages: DraftContextMessage[] = reversed.map((r) => ({
      from_me: r.is_from_me === 1,
      sender_handle: r.is_from_me ? null : r.sender_handle,
      sender_name: r.is_from_me ? null : r.sender_handle ? resolveHandle(r.sender_handle) : null,
      body: truncateBody(bestMessageBody(r.text, r.attributedBody)),
      sent_at: appleDateToIsoUtc(r.date),
      attachments: ctxAttachments.get(r.ROWID) ?? [],
    }));

    return {
      messages,
      diagnostic: {
        status: messages.length > 0 ? "ok" : "empty_thread",
        canonical_recipient: canon,
        matched_handle_ids: matchedHandleIds,
        chat_id: chatId,
        message_count: messages.length,
        error: null,
      },
    };
  } catch (e) {
    return {
      messages: [],
      diagnostic: {
        status: "error",
        canonical_recipient: null,
        matched_handle_ids: [],
        chat_id: null,
        message_count: 0,
        error: (e as Error).message,
      },
    };
  }
}

// ─── direct (1:1) chat resolution ───────────────────────────────────────────
// Mirrors the Swift IMessageDirectChatResolver (menubar/.../
// IMessageGroupDraftTarget.swift). Resolves the most-recent single-participant
// chat for a handle so a 1:1 send can target `chat id` (whose GUID prefix
// encodes the real transport) instead of guessing iMessage via the buddy
// cascade. Guessing iMessage silently fails for SMS/RCS-only contacts — the
// AppleScript "buddy of iMessageService" send does not error, so the message
// goes into the void and the SMS fallback never fires.

export interface ResolvedDirectChat {
  // The chat GUID to address via `send … to chat id` (e.g. "SMS;-;+14155551234").
  chatGUID: string;
  // The service prefix recorded in chat.db ("iMessage" / "SMS" / "RCS"),
  // surfaced for diagnostics. Derived from the GUID prefix; null if unknown.
  service: string | null;
}

// addressability + service-prefix helpers live in chat-guid.ts (no chat.db
// dependency) so the MCP can import the addressability check without pulling
// bun:sqlite. Re-exported here for the daemon's one import surface.
export { isAddressableChatGUID, serviceFromChatGUID } from "../imessage/chat-guid.ts";
import { isAddressableChatGUID, serviceFromChatGUID } from "../imessage/chat-guid.ts";

// Resolve the most-recent addressable 1:1 chat for `handle`, or null when the
// handle has no single-participant chat with an addressable GUID. Single-
// participant membership lives in chat_handle_join (one row per member); the
// recency tiebreak (a person with both an iMessage and an SMS chat) uses
// chat_message_join.message_date, same two-phase approach as the Swift resolver
// and recentContextForRecipient. Never throws — the daemon dispatch wraps this.
export function resolveDirectChat(handle: string): ResolvedDirectChat | null {
  const target = canonChatHandle(handle);
  if (target.length === 0) return null;
  const db = openChatDb();

  // Single-participant chats only, joined to their one member's handle. The
  // correlated COUNT subquery keeps us to chats with exactly one participant.
  const rows = db.query<{ chat_id: number; guid: string; handle_id: string }, []>(
    `SELECT c.ROWID AS chat_id,
            c.guid AS guid,
            h.id AS handle_id
     FROM chat c
     JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
     JOIN handle h ON h.ROWID = chj.handle_id
     WHERE (
       SELECT COUNT(*) FROM chat_handle_join one WHERE one.chat_id = c.ROWID
     ) = 1`
  ).all();

  const candidates: { chatId: number; chatGUID: string }[] = [];
  for (const r of rows) {
    if (canonChatHandle(r.handle_id) !== target) continue;
    // Only chats AppleScript can actually address by `chat id`. Skip unbound
    // "any;-;…" guids so the send falls back to the buddy cascade rather than
    // hard-failing with -1728.
    if (!isAddressableChatGUID(r.guid)) continue;
    candidates.push({ chatId: r.chat_id, chatGUID: r.guid });
  }

  if (candidates.length === 0) return null;

  let chosen = candidates[0]!;
  if (candidates.length > 1) {
    // Same person across services → the most recently used chat is the one
    // Messages.app would continue in. Tiebreak on chat_id for determinism.
    const recency = mostRecentMessageDates(candidates.map((c) => c.chatId));
    chosen = candidates.reduce((best, cur) => {
      const rb = recency.get(best.chatId) ?? -Infinity;
      const rc = recency.get(cur.chatId) ?? -Infinity;
      if (rc !== rb) return rc > rb ? cur : best;
      return cur.chatId > best.chatId ? cur : best;
    });
  }

  return { chatGUID: chosen.chatGUID, service: serviceFromChatGUID(chosen.chatGUID) };
}

// MAX(message_date) per chat for the recency tiebreak. Mirrors the Swift
// resolver's helper of the same name. chat_message_join.message_date is the
// Apple-epoch send time; we only compare magnitudes so the raw value is fine.
function mostRecentMessageDates(chatIds: readonly number[]): Map<number, number> {
  const out = new Map<number, number>();
  if (chatIds.length === 0) return out;
  const db = openChatDb();
  const placeholders = chatIds.map(() => "?").join(",");
  const rows = db.query<{ chat_id: number; last_date: number | bigint | null }, number[]>(
    `SELECT chat_id, MAX(message_date) AS last_date
     FROM chat_message_join
     WHERE chat_id IN (${placeholders})
     GROUP BY chat_id`
  ).all(...chatIds);
  for (const r of rows) {
    if (r.last_date != null) out.set(r.chat_id, Number(r.last_date));
  }
  return out;
}

function emptyDiagnostic(status: ContextLookupDiagnostic["status"], canon: string | null): ContextLookupDiagnostic {
  return {
    status,
    canonical_recipient: canon,
    matched_handle_ids: [],
    chat_id: null,
    message_count: 0,
    error: null,
  };
}

export interface SearchArgs {
  query: string;
  limit: number;
  sinceIso?: string | undefined;
  contactFilter?: string | undefined;
}

// Search without an explicit date bound is allowed when contact_filter is
// present. Default that path to a recent window so a broad contact filter
// doesn't devolve into a whole-chat.db scan.
const DEFAULT_SEARCH_WINDOW_MS = 365 * 24 * 60 * 60 * 1000;

// Cap on how many candidate rows we'll pull from SQL before giving up.
// With required filters and SQL text prefiltering the candidate set should
// normally be in the hundreds, not thousands. The cap is a safety belt
// against pathological queries.
const SEARCH_SCAN_CAP = 5000;

export function searchMessages(args: SearchArgs): ThreadMessage[] {
  const db = openChatDb();
  const { query, limit, sinceIso, contactFilter } = args;

  // SQL filters (sargable): date + handle. Body text matching happens in JS
  // after we decode attributedBody, because attributedBody is a typedstream
  // BLOB that SQLite cannot LIKE-search reliably.
  const matchedHandleRowIds = contactFilter ? chatHandleRowIdsForContactName(contactFilter) : [];
  const params: (string | number | bigint)[] = [];
  let where = "WHERE 1=1";
  const effectiveSinceIso = sinceIso ?? (contactFilter ? new Date(Date.now() - DEFAULT_SEARCH_WINDOW_MS).toISOString() : undefined);
  if (effectiveSinceIso) {
    where += " AND m.date >= ?";
    params.push(isoUtcToAppleDateNs(effectiveSinceIso));
  }
  if (contactFilter) {
    const like = `%${escapeLike(contactFilter)}%`;
    const handleInClause = matchedHandleRowIds.length
      ? ` OR h.ROWID IN (${matchedHandleRowIds.map(() => "?").join(",")})`
      : "";
    // Match if EITHER the message's sender handle matches OR any participant
    // in the message's thread does — covers "show me what Fairfax said" and
    // "show me anything in Fairfax's thread".
    where +=
      ` AND (LOWER(h.id) LIKE LOWER(?) ESCAPE '\\'${handleInClause} OR EXISTS (` +
      "SELECT 1 FROM chat_handle_join chj " +
      "JOIN handle h2 ON h2.ROWID = chj.handle_id " +
      `WHERE chj.chat_id = cmj.chat_id AND (LOWER(h2.id) LIKE LOWER(?) ESCAPE '\\'${handleInClause})))`;
    params.push(like);
    for (const id of matchedHandleRowIds) params.push(id);
    params.push(like);
    for (const id of matchedHandleRowIds) params.push(id);
  }
  where += " AND (LOWER(COALESCE(m.text, '')) LIKE LOWER(?) ESCAPE '\\' OR m.attributedBody IS NOT NULL)";
  params.push(`%${escapeLike(query)}%`);
  params.push(SEARCH_SCAN_CAP);

  const rows = db.query<MessageRowLite, (string | number | bigint)[]>(
    `SELECT m.ROWID AS ROWID,
            m.guid AS guid,
            m.text AS text,
            m.attributedBody AS attributedBody,
            m.date AS date,
            m.is_from_me AS is_from_me,
            m.is_read AS is_read,
            m.cache_has_attachments AS cache_has_attachments,
            m.handle_id AS handle_id,
            m.thread_originator_guid AS thread_originator_guid,
            h.id AS sender_handle,
            cmj.chat_id AS thread_id
     FROM message m
     JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
     LEFT JOIN handle h ON h.ROWID = m.handle_id
     ${where}
     ORDER BY m.date DESC
     LIMIT ?`
  ).all(...params);

  const lowerQuery = query.toLowerCase();
  const matches: ThreadMessage[] = [];
  // Parallel to `matches`: each entry's originator guid (or null). Resolved in
  // one batch after the scan loop so we only look up originators for the hits.
  const matchOriginatorGuids: (string | null)[] = [];
  for (const r of rows) {
    // Cheap path first: if `text` exists and matches, we're done with this row.
    let body: string | null = r.text;
    if (!body || body.length === 0) {
      body = decodeAttributedBody(r.attributedBody);
    }
    if (!body) continue;
    if (!body.toLowerCase().includes(lowerQuery)) continue;
    matches.push({
      message_id: r.ROWID,
      thread_id: r.thread_id,
      sent_at: appleDateToIsoUtc(r.date),
      from_me: r.is_from_me === 1,
      sender: {
        handle: r.is_from_me ? null : r.sender_handle,
        name: r.is_from_me ? null : r.sender_handle ? resolveHandle(r.sender_handle) : null,
      },
      body: truncateBody(body),
      body_truncated: isOverBudget(body),
      is_read: r.is_read === 1,
      has_attachments: r.cache_has_attachments === 1,
      attachments: [],
      reply_to: null,
    });
    matchOriginatorGuids.push(r.thread_originator_guid ?? null);
    if (matches.length >= limit) break;
  }

  const originators = resolveOriginators(
    matchOriginatorGuids.filter((g): g is string => !!g),
  );
  const searchAttachments = loadAttachmentsFor(
    matches.filter((m) => m.has_attachments).map((m) => m.message_id),
  );
  for (let i = 0; i < matches.length; i++) {
    matches[i]!.reply_to = replyToFor(matchOriginatorGuids[i], originators);
    matches[i]!.attachments = searchAttachments.get(matches[i]!.message_id) ?? [];
  }
  return matches;
}
