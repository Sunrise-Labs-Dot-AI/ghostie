// Persistent message cache. Baileys emits messages.upsert / messaging-
// history.set events; this module is the write target. All read tools
// (list_whatsapp_threads, get_whatsapp_thread, search_whatsapps) read
// from here — never directly from Baileys in-memory state. Decouples
// read latency from connection state and survives reconnects.
//
// Message CONTENT is encrypted at rest (#81). The `body` and `body_full`
// columns hold AES-256-GCM ciphertext (the same Keychain-keyed wrap path
// used for session creds — see storage/crypto.ts), not plaintext. This
// removes the second, unencrypted copy of E2EE history that a same-user
// process or a backup tool (Time Machine, Backblaze, iCloud) could read
// with `sqlite3 messages.db 'select body from messages'`.
//
// Scope: ONLY message content is encrypted. JIDs, timestamps, message_type,
// reply_to_id, thread/contact names and the lid_pn_map are left plaintext —
// they're used for joins, threading, recency filtering and contact-filter
// matching, all of which must run in SQL. body_sha256 is a one-way hash
// (audit stability), not recoverable content, so it stays as-is.
//
// Read path decrypts in JS after the SQL query. Content search can no longer
// use SQL LIKE on the ciphertext: searchMessages filters candidate rows by
// the plaintext metadata bounds (since / contact_filter) first, then
// decrypts and substring-matches in JS. A migration (migrateEncryptBodies)
// encrypts any pre-existing plaintext rows on first run.

import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { PATHS } from "../paths.ts";
import { wrap, unwrap } from "./crypto.ts";
import { DEFAULT_BODY_CAP_BYTES, sanitizeIncomingBody, truncateToBytes } from "../tools/_untrusted.ts";

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS messages (
  message_id      TEXT NOT NULL,
  thread_jid      TEXT NOT NULL,
  sender_jid      TEXT NOT NULL,
  from_me         INTEGER NOT NULL,
  ts              INTEGER NOT NULL,
  body            TEXT,
  body_full       BLOB,
  body_sha256     TEXT,
  message_type    TEXT NOT NULL,
  attachment_meta TEXT,
  reply_to_id     TEXT,
  inserted_at     INTEGER NOT NULL,
  source          TEXT NOT NULL,
  -- AES-256-GCM ciphertext of the base64 Baileys media node (mediaKey +
  -- directPath + url + hashes) for image/video/document/audio messages, so
  -- the payload can be downloaded on demand later. Encrypted at rest because
  -- it contains the media decryption key. NULL for non-media messages and for
  -- media ingested before download support existed.
  media_descriptor BLOB,
  PRIMARY KEY (thread_jid, message_id)
);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts DESC);
CREATE INDEX IF NOT EXISTS idx_messages_thread_ts ON messages(thread_jid, ts DESC);

CREATE TABLE IF NOT EXISTS message_reactions (
  thread_jid        TEXT NOT NULL,
  target_message_id TEXT NOT NULL,
  reactor_jid       TEXT NOT NULL,
  from_me           INTEGER NOT NULL,
  emoji             TEXT NOT NULL,
  ts                INTEGER NOT NULL,
  source            TEXT NOT NULL,
  inserted_at       INTEGER NOT NULL,
  PRIMARY KEY (thread_jid, target_message_id, reactor_jid)
);
CREATE INDEX IF NOT EXISTS idx_message_reactions_target ON message_reactions(thread_jid, target_message_id);
CREATE INDEX IF NOT EXISTS idx_message_reactions_ts ON message_reactions(ts DESC);

CREATE TABLE IF NOT EXISTS threads (
  thread_jid       TEXT PRIMARY KEY,
  display_name     TEXT,
  is_group         INTEGER NOT NULL,
  last_message_ts  INTEGER NOT NULL,
  last_seen_at     INTEGER
);

CREATE TABLE IF NOT EXISTS contacts (
  jid           TEXT PRIMARY KEY,
  display_name  TEXT,
  push_name     TEXT,
  is_business   INTEGER NOT NULL DEFAULT 0
);

-- v0.3.2: WhatsApp emits some sender JIDs in privacy-identifier ("@lid")
-- form rather than the canonical "@s.whatsapp.net" phone-number form.
-- Roughly 30% of contacts surface this way in observed traffic. The
-- mapping from one to the other is exposed by Baileys via auth-state
-- events; the daemon writes (lid, pn) pairs here so read-side resolution
-- (getContactDisplayName, getThreadMessages LEFT JOIN) can JOIN through
-- and present a real name instead of a raw @lid.
--
-- Populated by daemon-side code (see "deferred to v0.3.3" note in
-- daemon/connection.ts when that wiring lands). Until then the table
-- stays empty and the resolution path no-ops — read tools surface
-- unresolved @lid JIDs as raw strings, same as today.
CREATE TABLE IF NOT EXISTS lid_pn_map (
  lid TEXT PRIMARY KEY,
  pn  TEXT NOT NULL
);
`;

export type MessageType = "text" | "image" | "voice" | "video" | "document" | "system";
export type MessageSource = "live" | "history-sync";

export interface IngestMessage {
  message_id: string;
  thread_jid: string;
  sender_jid: string;
  from_me: boolean;
  ts: number;            // unix ms
  body: string | null;   // raw body; sanitized + truncated at write time
  message_type: MessageType;
  attachment_meta?: { caption?: string; filename?: string; mime?: string } | null;
  /** Raw Baileys message-proto bytes for media messages, so the payload can be
   *  downloaded later. Stored encrypted (it carries the media key). */
  media_descriptor?: Uint8Array | null;
  reply_to_id?: string | null;
  source: MessageSource;
}

export interface IngestReaction {
  thread_jid: string;
  target_message_id: string;
  reactor_jid: string;
  from_me: boolean;
  /** Empty string removes the sender's reaction from the target message. */
  emoji: string;
  ts: number;
  source: MessageSource;
}

export interface UpsertThread {
  thread_jid: string;
  display_name?: string | null;
  is_group: boolean;
  last_message_ts: number;
}

export interface UpsertContact {
  jid: string;
  display_name?: string | null;
  push_name?: string | null;
  is_business?: boolean;
}

export interface ThreadRow {
  thread_jid: string;
  display_name: string | null;
  is_group: boolean;
  last_message_ts: number;
  last_seen_at: number | null;
}

export interface MessageRow {
  message_id: string;
  thread_jid: string;
  sender_jid: string;
  /** Best-effort human-readable sender name resolved at read time via
   *  the contacts table. Null for unknown senders (typically @lid
   *  privacy-format JIDs that don't have a contacts row yet). For
   *  `from_me=true` messages this is null — callers render those as
   *  "Me" / "You" themselves. */
  sender_name: string | null;
  from_me: boolean;
  ts: number;
  body: string | null;
  body_sha256: string | null;
  message_type: MessageType;
  attachment_meta: { caption?: string; filename?: string; mime?: string } | null;
  /** True when a media descriptor is stored for this message, so its payload
   *  can be fetched via downloadMedia. False for text/system messages and for
   *  media ingested before download support (no descriptor on file). */
  media_downloadable: boolean;
  /** stanzaId of the message this one quotes/replies to, or null. */
  reply_to_id: string | null;
  /** The quoted message resolved from the cache. Present when reply_to_id is
   *  set; `body` is null when the quoted message isn't in the cache (older
   *  than retention / never synced) — the caller still learns it's a reply.
   *  `body` / `sender_name` are peer-/sidecar-sourced; wrap as untrusted at
   *  the tool boundary. */
  reply_to: {
    message_id: string;
    body: string | null;
    from_me: boolean;
    sender_name: string | null;
  } | null;
  reactions: MessageReactionRow[];
}

export interface MessageReactionRow {
  emoji: string;
  sender_jid: string | null;
  sender_name: string | null;
  from_me: boolean;
  ts: number;
}

let _db: Database | null = null;

/** Bumped when an at-rest re-encryption migration must run once. v1 = message
 *  bodies encrypted at rest (#81). Tracked via PRAGMA user_version. */
const ENCRYPTION_SCHEMA_VERSION = 1;

/** Open (or return cached) handle to messages.db. Exported so tests can
 *  reset table contents between cases without re-opening the file. */
export function getMessagesDb(): Database {
  if (_db != null) return _db;
  const path = PATHS.messagesDb;
  if (!existsSync(dirname(path))) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  }
  const db = new Database(path, { create: true });
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA synchronous = NORMAL");
  db.exec(SCHEMA_SQL);
  // Additive column for installs whose `messages` table predates media
  // download support. CREATE TABLE IF NOT EXISTS won't add it to an existing
  // table, so ALTER it in idempotently (PRAGMA-guarded).
  ensureColumn(db, "messages", "media_descriptor", "BLOB");
  // 0600 on the main DB. WAL/SHM sidecars are created lazily by SQLite;
  // we re-chmod them whenever we know they exist.
  try { chmodSync(path, 0o600); } catch { /* not yet on disk in some edge cases */ }
  for (const suffix of ["-wal", "-shm"] as const) {
    try { chmodSync(path + suffix, 0o600); } catch { /* not created yet */ }
  }
  _db = db;

  // One-time backfill: heal any threads whose last_message_ts is 0 but
  // for which we actually have messages. This recovers from a bug where
  // an earlier daemon version stored last_message_ts=0 because it didn't
  // unpack Baileys' protobuf-Long conversationTimestamp. Idempotent —
  // a fresh install has 0 rows in both tables and this no-ops.
  db.exec(`
    UPDATE threads SET last_message_ts = COALESCE((
      SELECT MAX(ts) FROM messages WHERE messages.thread_jid = threads.thread_jid
    ), 0)
    WHERE last_message_ts = 0
      AND EXISTS (SELECT 1 FROM messages WHERE messages.thread_jid = threads.thread_jid)
  `);

  // One-time encrypt-at-rest migration (#81): encrypt any pre-existing
  // plaintext body / body_full rows. Idempotent (already-ciphertext rows are
  // skipped) and a no-op on a fresh install. Gated on PRAGMA user_version so
  // we don't full-scan + decrypt-probe every row on every daemon start —
  // only the first open after upgrade pays the migration cost. A Keychain
  // failure throws here (fail-closed) rather than silently leaving plaintext.
  const userVersion = (db.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
  if (userVersion < ENCRYPTION_SCHEMA_VERSION) {
    migrateEncryptBodies(db);
    db.exec(`PRAGMA user_version = ${ENCRYPTION_SCHEMA_VERSION}`);
  }
  // After this point the migration has run (this open or a prior one): every
  // content row is expected to be ciphertext. A plaintext string on read is now
  // a fail-closed condition rather than a tolerated legacy value (#81 round 2).
  _migrationComplete = true;

  return db;
}

/** Hex SHA-256 of a string. */
function sha256(input: string): string {
  return new Bun.CryptoHasher("sha256").update(input).digest("hex");
}

/** Idempotently add a column to an existing table (no-op if already present). */
function ensureColumn(db: Database, table: string, column: string, decl: string): void {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>;
  if (cols.some((c) => c.name === column)) return;
  db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${decl}`);
}

/** Encrypt the binary media descriptor (base64 → AES-GCM). null → null. */
function encryptDescriptor(bytes: Uint8Array | null | undefined): Buffer | null {
  if (bytes == null || bytes.length === 0) return null;
  return wrap(Buffer.from(bytes).toString("base64"));
}

/** Decrypt a stored media descriptor blob back to its raw proto bytes. */
function decryptDescriptor(blob: Buffer | null): Uint8Array | null {
  if (blob == null) return null;
  return new Uint8Array(Buffer.from(unwrap(blob), "base64"));
}

// True once the at-rest encryption migration (#81) has completed for the open
// DB — i.e. PRAGMA user_version >= ENCRYPTION_SCHEMA_VERSION. After this point
// EVERY content row MUST be ciphertext; a plaintext string coming back from a
// content column is anomalous and must be fail-closed (#81 round 2), not served
// indefinitely. Set in getMessagesDb after the migration gate.
let _migrationComplete = false;

/** Count of stray-plaintext content rows observed on read post-migration.
 *  Exposed for tests / a future health metric. NOT a body — a count only. */
let _strayPlaintextOnRead = 0;
export function _getStrayPlaintextCount(): number {
  return _strayPlaintextOnRead;
}

// ── Message-content encryption at rest (#81) ───────────────────────────────
//
// `body` / `body_full` are stored as AES-256-GCM ciphertext Buffers. SQLite
// is dynamically typed, so a Buffer round-trips through the TEXT-affinity
// `body` column as a BLOB. Null content (non-text messages) stays null.

/** Encrypt message content for storage. null → null. */
function encryptBody(plaintext: string | null): Buffer | null {
  if (plaintext == null) return null;
  return wrap(plaintext);
}

/**
 * Decrypt a stored content column back to text. null → null.
 *
 * Fail-closed on stray plaintext (#81 round 2). The v1 migration encrypts all
 * existing rows on first open and sets PRAGMA user_version. After the migration
 * has run, EVERY content value must be ciphertext (a Buffer/BLOB). If a
 * plaintext STRING comes back from a content column post-migration, it is an
 * anomaly (a missed/legacy/downgrade-written row). We MUST NOT serve it as a
 * valid body indefinitely:
 *
 *   - If a `heal` callback is provided (read paths that know the row's PK),
 *     we re-encrypt the plaintext in place so the on-disk copy becomes
 *     ciphertext, then return the recovered text. This both fixes the row and
 *     keeps the legitimate body available — a one-time self-heal on read.
 *   - If NO healer is available, we REFUSE: return null and bump a metric,
 *     rather than handing back plaintext that should have been encrypted.
 *
 * During the migration window (before it has run on THIS process), a plaintext
 * string is tolerated and returned as-is — the migration is what converts it.
 *
 * A legitimately-null body (non-text message) stays null and never trips this.
 */
function decryptBody(
  stored: Buffer | Uint8Array | string | null,
  heal?: (cipher: Buffer) => void,
): string | null {
  if (stored == null) return null;
  if (typeof stored === "string") {
    // Pre-migration: tolerate (the migration will encrypt it).
    if (!_migrationComplete) return stored;
    // Post-migration stray plaintext: fail-closed.
    _strayPlaintextOnRead += 1;
    process.stderr.write(
      "WARN messages.db: stray plaintext content row encountered on read post-encryption-migration " +
      "(#81). " + (heal ? "Re-encrypting in place." : "Refusing to serve plaintext.") + "\n",
    );
    if (heal != null) {
      try {
        heal(wrap(stored));
      } catch {
        // Heal failed (DB hiccup): still don't serve plaintext.
        return null;
      }
      return stored; // recovered + now persisted as ciphertext
    }
    return null; // no way to heal → refuse rather than serve plaintext
  }
  const buf = Buffer.isBuffer(stored) ? stored : Buffer.from(stored);
  return unwrap(buf);
}

/** Build a heal callback that re-encrypts a stray-plaintext content column in
 *  place for a specific (thread_jid, message_id) row (#81 round 2). Used by the
 *  read paths so a missed/legacy plaintext row becomes ciphertext on first
 *  read instead of being served plaintext or refused. */
function makeHealer(
  db: Database,
  column: "body" | "body_full",
  thread_jid: string,
  message_id: string,
): (cipher: Buffer) => void {
  return (cipher: Buffer) => {
    db.prepare(`UPDATE messages SET ${column} = ? WHERE thread_jid = ? AND message_id = ?`)
      .run(cipher, thread_jid, message_id);
  };
}

/**
 * One-time migration: encrypt any plaintext `body` / `body_full` rows in
 * place (#81). Idempotent and safe to run on every open:
 *
 *  - A freshly-written row is already ciphertext (a BLOB) → skipped.
 *  - A legacy row's `body` comes back as a JS string (TEXT) → re-encrypted.
 *  - body_full is already BLOB-typed even when plaintext, so we can't use
 *    column type to tell ciphertext from plaintext. Instead we detect by
 *    attempting an unwrap: a value that decrypts cleanly is already
 *    ciphertext and left alone; one that fails the GCM auth check is treated
 *    as legacy plaintext and encrypted. (Random 16-byte GCM tags make a
 *    false "decrypts cleanly" on real plaintext astronomically unlikely.)
 *
 * On a fresh install (0 rows) this no-ops. Runs inside a transaction.
 */
export function migrateEncryptBodies(db: Database): { migrated: number } {
  let migrated = 0;
  const pageSize = 1000;
  let lastRowid = 0;
  const selectPage = db.prepare(`
    SELECT rowid, body, body_full FROM messages
    WHERE rowid > ?
    ORDER BY rowid ASC
    LIMIT ?
  `);
  const update = db.prepare("UPDATE messages SET body = ?, body_full = ? WHERE rowid = ?");
  const runPage = db.transaction((rows: Array<{ rowid: number; body: unknown; body_full: unknown }>) => {
    for (const r of rows) {
      const bodyEnc = reencryptIfPlaintext(r.body);
      const fullEnc = reencryptIfPlaintext(r.body_full);
      if (bodyEnc.changed || fullEnc.changed) {
        update.run(bodyEnc.value, fullEnc.value, r.rowid);
        migrated += 1;
      }
    }
  });
  while (true) {
    const rows = selectPage.all(lastRowid, pageSize) as Array<{ rowid: number; body: unknown; body_full: unknown }>;
    if (rows.length === 0) break;
    runPage(rows);
    lastRowid = rows[rows.length - 1]!.rowid;
  }
  return { migrated };
}

/** Returns ciphertext + whether a change was needed. Already-ciphertext and
 *  null pass through unchanged. */
function reencryptIfPlaintext(
  stored: unknown,
): { value: Buffer | null; changed: boolean } {
  if (stored == null) return { value: null, changed: false };
  if (typeof stored === "string") {
    return { value: wrap(stored), changed: true }; // legacy TEXT plaintext
  }
  const buf = Buffer.isBuffer(stored) ? stored : Buffer.from(stored as Uint8Array);
  try {
    unwrap(buf); // already valid ciphertext
    return { value: buf, changed: false };
  } catch {
    // Not decryptable → treat the BLOB bytes as legacy plaintext UTF-8.
    return { value: wrap(buf.toString("utf8")), changed: true };
  }
}

/**
 * Insert a message. Idempotent on (thread_jid, message_id).
 *
 * - body is sanitized (tag-escape) and truncated to DEFAULT_BODY_CAP_BYTES
 *   before insert. body_full retains the full sanitized form for explicit
 *   get_whatsapp_message_full retrieval.
 * - body_sha256 hashes the FULL sanitized body (not the truncated one) so
 *   audit comparisons remain stable.
 * - Also UPSERTs threads.last_message_ts to MAX(existing, new). This is
 *   the authoritative source for thread recency — never trust Baileys'
 *   conversationTimestamp because it's emitted as a protobuf Long that
 *   we'd have to unpack correctly in every event handler.
 */
export function insertMessage(m: IngestMessage): { inserted: boolean } {
  const db = getMessagesDb();
  return insertMessagesWithDb(db, [m])[0]!;
}

export function insertMessages(messages: readonly IngestMessage[]): { inserted: number } {
  if (messages.length === 0) return { inserted: 0 };
  const db = getMessagesDb();
  const results = insertMessagesWithDb(db, messages);
  return { inserted: results.filter((r) => r.inserted).length };
}

/**
 * Upsert reaction events emitted by WhatsApp. A sender can hold one reaction
 * per target message; an empty emoji removes it. This stores metadata only:
 * message ids, sender ids, emoji, and timestamps, never message bodies.
 *
 * Events can replay out of order (history sync re-delivers old adds after a
 * live removal), so two guards keep the newest event authoritative:
 * - the upsert only applies when the incoming event is at least as new as
 *   the stored one (ts comparison);
 * - removals are stored as empty-emoji tombstone rows instead of deletes, so
 *   a replayed older add hits the ts guard instead of inserting fresh and
 *   resurrecting a removed reaction. Read paths skip empty-emoji rows.
 *
 * Reactions deliberately do NOT touch threads.last_message_ts: WhatsApp
 * itself does not reorder the chat list when a reaction arrives, and bumping
 * it here would.
 */
export function upsertReactionEvents(reactions: readonly IngestReaction[]): { upserted: number; removed: number } {
  if (reactions.length === 0) return { upserted: 0, removed: 0 };
  const db = getMessagesDb();
  let upserted = 0;
  let removed = 0;
  const upsert = db.prepare(`
    INSERT INTO message_reactions
      (thread_jid, target_message_id, reactor_jid, from_me, emoji, ts, source, inserted_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(thread_jid, target_message_id, reactor_jid) DO UPDATE SET
      from_me = excluded.from_me,
      emoji = excluded.emoji,
      ts = excluded.ts,
      source = excluded.source,
      inserted_at = excluded.inserted_at
    WHERE excluded.ts >= message_reactions.ts
  `);
  const run = db.transaction(() => {
    const now = Date.now();
    for (const reaction of reactions) {
      if (
        reaction.thread_jid.length === 0 ||
        reaction.target_message_id.length === 0 ||
        reaction.reactor_jid.length === 0
      ) {
        continue;
      }
      const result = upsert.run(
        reaction.thread_jid,
        reaction.target_message_id,
        reaction.reactor_jid,
        reaction.from_me ? 1 : 0,
        reaction.emoji,
        reaction.ts,
        reaction.source,
        now,
      );
      if (Number(result.changes) > 0) {
        if (reaction.emoji.length === 0) removed += 1;
        else upserted += 1;
      }
    }
  });
  run();
  return { upserted, removed };
}

function prepareStoredBody(m: IngestMessage): {
  bodyTrunc: Buffer | null;
  bodyFull: Buffer | null;
  bodySha: string | null;
} {
  // body / body_full are stored as AES-GCM ciphertext at rest (#81). We
  // sanitize + truncate the plaintext first (so the stored ciphertext, once
  // decrypted on read, is already safe + capped), then encrypt. body_sha256
  // hashes the sanitized PLAINTEXT (not the ciphertext) so audit comparisons
  // stay stable across re-encryption / key rotation.
  let bodyTrunc: Buffer | null = null;
  let bodyFull: Buffer | null = null;
  let bodySha: string | null = null;
  if (m.body != null) {
    const sanitized = sanitizeIncomingBody(m.body);
    const { body: truncated, truncated: didTruncate } = truncateToBytes(sanitized);
    bodyTrunc = encryptBody(truncated);
    bodyFull = didTruncate ? encryptBody(sanitized) : null;
    bodySha = sha256(sanitized);
  }
  return { bodyTrunc, bodyFull, bodySha };
}

function insertMessagesWithDb(db: Database, messages: readonly IngestMessage[]): Array<{ inserted: boolean }> {
  const stmt = db.prepare(`
    INSERT OR IGNORE INTO messages
      (message_id, thread_jid, sender_jid, from_me, ts, body, body_full,
       body_sha256, message_type, attachment_meta, reply_to_id, inserted_at, source,
       media_descriptor)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const threadStmt = db.prepare(`
    INSERT INTO threads (thread_jid, display_name, is_group, last_message_ts)
    VALUES (?, NULL, ?, ?)
    ON CONFLICT(thread_jid) DO UPDATE SET
      last_message_ts = MAX(threads.last_message_ts, excluded.last_message_ts)
  `);
  const results: Array<{ inserted: boolean }> = [];
  const run = db.transaction(() => {
    const now = Date.now();
    for (const m of messages) {
      try {
        const { bodyTrunc, bodyFull, bodySha } = prepareStoredBody(m);
        const result = stmt.run(
          m.message_id,
          m.thread_jid,
          m.sender_jid,
          m.from_me ? 1 : 0,
          m.ts,
          bodyTrunc,
          bodyFull,
          bodySha,
          m.message_type,
          m.attachment_meta ? JSON.stringify(m.attachment_meta) : null,
          m.reply_to_id ?? null,
          now,
          m.source,
          encryptDescriptor(m.media_descriptor),
        );

        // Also bump threads.last_message_ts so list_whatsapp_threads can filter
        // by recency. UPSERT semantics: create the thread row if it didn't
        // already exist (which can happen if messaging-history.set delivered
        // messages before the chat metadata), otherwise raise last_message_ts.
        threadStmt.run(m.thread_jid, m.thread_jid.endsWith("@g.us") ? 1 : 0, m.ts);
        results.push({ inserted: result.changes > 0 });
      } catch (e) {
        process.stderr.write(
          `WhatsApp message ingest skipped ${JSON.stringify(m.message_id)}: ${(e as Error).message}\n`,
        );
        results.push({ inserted: false });
      }
    }
  });
  run();
  return results;
}

export function upsertThread(t: UpsertThread): void {
  const db = getMessagesDb();
  db.prepare(`
    INSERT INTO threads (thread_jid, display_name, is_group, last_message_ts)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(thread_jid) DO UPDATE SET
      display_name = COALESCE(excluded.display_name, threads.display_name),
      is_group = excluded.is_group,
      last_message_ts = MAX(threads.last_message_ts, excluded.last_message_ts)
  `).run(
    t.thread_jid,
    t.display_name ?? null,
    t.is_group ? 1 : 0,
    t.last_message_ts,
  );
}

export function upsertContact(c: UpsertContact): void {
  const db = getMessagesDb();
  db.prepare(`
    INSERT INTO contacts (jid, display_name, push_name, is_business)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(jid) DO UPDATE SET
      display_name = COALESCE(excluded.display_name, contacts.display_name),
      push_name    = COALESCE(excluded.push_name, contacts.push_name),
      is_business  = excluded.is_business
  `).run(
    c.jid,
    c.display_name ?? null,
    c.push_name ?? null,
    c.is_business ? 1 : 0,
  );
}

/**
 * Insert / update a privacy-id → phone-number mapping. Daemon calls this
 * when Baileys exposes a (lid, pn) pair (e.g. via the lid-update event or
 * a contact's `lid` field on contacts.upsert). MCP-side reads don't call
 * this. Safe to call repeatedly with the same pair — UPSERT semantics.
 *
 * Schema columns enumerated explicitly — never SELECT *. Errors are
 * caller-handled; this function does not log row contents (the lid and pn
 * together are personally-identifying information).
 */
export function upsertLidMapping(lid: string, pn: string): void {
  const db = getMessagesDb();
  db.prepare(`
    INSERT INTO lid_pn_map (lid, pn) VALUES (?, ?)
    ON CONFLICT(lid) DO UPDATE SET pn = excluded.pn
  `).run(lid, pn);
}

/**
 * Best-effort human-readable name for a JID. Resolution order:
 *
 *   1. contacts row keyed by the JID directly (display_name → push_name)
 *   2. for `@lid` privacy-id JIDs: look up the phone-number JID via
 *      `lid_pn_map`, then recurse step 1 on the resolved phone JID
 *   3. threads.display_name (Baileys names groups even when individual
 *      contacts aren't yet known)
 *
 * Returns null if nothing matches — caller falls back to `formatJidAsPhone`.
 *
 * Selects enumerated columns only (never SELECT *) to bound what an error
 * stack trace can surface in worst case. Error handlers above this layer
 * must log a generic message ("contact lookup failed") rather than the row
 * contents.
 */
export function getContactDisplayName(jid: string): string | null {
  const db = getMessagesDb();

  const direct = db
    .prepare("SELECT display_name, push_name FROM contacts WHERE jid = ?")
    .get(jid) as { display_name: string | null; push_name: string | null } | undefined;
  if (direct != null) {
    const name = direct.display_name ?? direct.push_name;
    if (name != null && name.trim().length > 0) return name;
  }

  // @lid → phone-number JID indirection. Only attempts the JOIN for inputs
  // that look like a privacy-id JID, so the common @s.whatsapp.net case
  // pays no extra cost.
  if (jid.endsWith("@lid")) {
    const mapped = db
      .prepare("SELECT pn FROM lid_pn_map WHERE lid = ?")
      .get(jid) as { pn: string } | undefined;
    if (mapped != null) {
      const viaLid = db
        .prepare("SELECT display_name, push_name FROM contacts WHERE jid = ?")
        .get(mapped.pn) as { display_name: string | null; push_name: string | null } | undefined;
      if (viaLid != null) {
        const name = viaLid.display_name ?? viaLid.push_name;
        if (name != null && name.trim().length > 0) return name;
      }
    }
  }

  const thread = db
    .prepare("SELECT display_name FROM threads WHERE thread_jid = ?")
    .get(jid) as { display_name: string | null } | undefined;
  if (thread?.display_name != null && thread.display_name.trim().length > 0) {
    return thread.display_name;
  }
  return null;
}

/**
 * Pretty-format a WhatsApp user JID as a phone number when no contact
 * name is available. "12155550129@s.whatsapp.net" → "+1 (215) 555-0129".
 * Group JIDs and unparseable inputs round-trip unchanged.
 */
export function formatJidAsPhone(jid: string): string {
  const at = jid.indexOf("@");
  if (at < 0) return jid;
  const suffix = jid.slice(at);
  if (suffix === "@g.us") return jid;  // groups: caller should prefer thread name
  const num = jid.slice(0, at).replace(/[^0-9]/g, "");
  if (num.length === 0) return jid;
  // US/CA numbers (11 digits starting with 1) get the (NNN) NNN-NNNN
  // pretty form; everything else just gets the leading "+".
  if (num.length === 11 && num.startsWith("1")) {
    return `+1 (${num.slice(1, 4)}) ${num.slice(4, 7)}-${num.slice(7, 11)}`;
  }
  return `+${num}`;
}

/**
 * List threads with a recent message in [since, now]. Optionally filter
 * threads whose display_name OR jid contains contact_filter (substring).
 */
export function listThreads(opts: {
  since?: number;
  contact_filter?: string;
  limit?: number;
}): ThreadRow[] {
  const db = getMessagesDb();
  const where: string[] = [];
  const params: (string | number)[] = [];
  if (opts.since != null) {
    where.push("threads.last_message_ts >= ?");
    params.push(opts.since);
  }
  if (opts.contact_filter != null && opts.contact_filter.length > 0) {
    where.push("(threads.display_name LIKE ? OR threads.thread_jid LIKE ?)");
    const like = `%${opts.contact_filter}%`;
    params.push(like, like);
  }
  // For groups: threads.display_name is set by Baileys's group-meta sync.
  // For individuals: threads.display_name is null (each side knows the
  // other by phone, not by a thread label), so fall back to the contacts
  // table — that's where Baileys writes the Mac Contacts display_name
  // and the WhatsApp profile push_name on contacts.upsert. Without this
  // join, every individual chat surfaces to Claude as a raw JID and
  // contact_filter substring-matches only group names. With the join,
  // ~70% of individual chats resolve (the rest are @lid entries — a
  // known follow-up for Baileys's privacy-format mapping).
  if (opts.contact_filter != null && opts.contact_filter.length > 0) {
    // Replace the basic display_name LIKE clause above with one that
    // also searches the joined contact name.
    where.pop();
    const like = `%${opts.contact_filter}%`;
    params.pop(); params.pop();
    where.push("(threads.display_name LIKE ? OR threads.thread_jid LIKE ? OR contacts.display_name LIKE ? OR contacts.push_name LIKE ?)");
    params.push(like, like, like, like);
  }
  const whereSql = where.length > 0 ? `WHERE ${where.join(" AND ")}` : "";
  const limit = opts.limit ?? 100;
  const rows = db.prepare(`
    SELECT
      threads.thread_jid,
      COALESCE(threads.display_name, contacts.display_name, contacts.push_name) AS display_name,
      threads.is_group,
      threads.last_message_ts,
      threads.last_seen_at
    FROM threads
    LEFT JOIN contacts ON contacts.jid = threads.thread_jid
    ${whereSql}
    ORDER BY threads.last_message_ts DESC
    LIMIT ?
  `).all(...params, limit) as Array<{
    thread_jid: string;
    display_name: string | null;
    is_group: number;
    last_message_ts: number;
    last_seen_at: number | null;
  }>;
  return rows.map((r) => ({
    thread_jid: r.thread_jid,
    display_name: r.display_name,
    is_group: r.is_group === 1,
    last_message_ts: r.last_message_ts,
    last_seen_at: r.last_seen_at,
  }));
}

// Assemble the `reply_to` object from the self-join columns. Null when the
// row isn't a reply; `body` null when the quoted message isn't in the cache.
function buildReplyTo(r: {
  reply_to_id: string | null;
  reply_to_body: string | null;
  reply_to_from_me: number | null;
  reply_to_sender_name: string | null;
}): MessageRow["reply_to"] {
  if (r.reply_to_id == null) return null;
  const fromMe = r.reply_to_from_me === 1;
  return {
    message_id: r.reply_to_id,
    body: r.reply_to_body,
    from_me: fromMe,
    sender_name: fromMe ? null : r.reply_to_sender_name,
  };
}

function loadReactionsForMessages(
  db: Database,
  threadJid: string,
  messageIds: readonly string[],
): Map<string, MessageReactionRow[]> {
  const uniqueIds = [...new Set(messageIds.filter((id) => id.length > 0))];
  const out = new Map<string, MessageReactionRow[]>();
  if (uniqueIds.length === 0) return out;
  const placeholders = uniqueIds.map(() => "?").join(",");
  const rows = db.prepare(`
    SELECT r.target_message_id,
           r.reactor_jid,
           r.from_me,
           r.emoji,
           r.ts,
           COALESCE(
             c_direct.display_name, c_direct.push_name,
             c_via_lid.display_name, c_via_lid.push_name
           ) AS sender_name
    FROM message_reactions r
    LEFT JOIN contacts  c_direct  ON c_direct.jid  = r.reactor_jid
    LEFT JOIN lid_pn_map l        ON l.lid         = r.reactor_jid
    LEFT JOIN contacts  c_via_lid ON c_via_lid.jid = l.pn
    WHERE r.thread_jid = ? AND r.emoji != '' AND r.target_message_id IN (${placeholders})
    ORDER BY r.ts ASC
  `).all(threadJid, ...uniqueIds) as Array<{
    target_message_id: string;
    reactor_jid: string;
    from_me: number;
    emoji: string;
    ts: number;
    sender_name: string | null;
  }>;
  for (const row of rows) {
    const fromMe = row.from_me === 1;
    const reactions = out.get(row.target_message_id) ?? [];
    reactions.push({
      emoji: row.emoji,
      sender_jid: fromMe ? null : row.reactor_jid,
      sender_name: fromMe ? null : row.sender_name,
      from_me: fromMe,
      ts: row.ts,
    });
    out.set(row.target_message_id, reactions);
  }
  return out;
}

export interface ReactionTargetKey {
  remoteJid: string;
  id: string;
  fromMe: boolean;
  participant?: string;
}

export function getThreadMessages(opts: {
  thread_jid: string;
  before_ts?: number;
  limit?: number;
}): MessageRow[] {
  const db = getMessagesDb();
  const limit = opts.limit ?? 50;
  const before = opts.before_ts ?? Number.MAX_SAFE_INTEGER;
  // LEFT JOIN to contacts so the MCP-side tools (and the menubar's
  // context bubbles) see real names instead of raw JIDs. Inbound
  // messages whose sender_jid doesn't have a matching contacts row
  // (mainly @lid privacy-format senders Baileys hasn't mapped yet)
  // get sender_name = null and the caller falls back to phone-format.
  // Two-leg LEFT JOIN to resolve sender_name:
  //   - direct: messages.sender_jid → contacts.jid
  //   - via lid: messages.sender_jid (@lid) → lid_pn_map.lid → lid_pn_map.pn → contacts.jid
  // Direct match wins; @lid indirection fills in the ~30% of senders that
  // Baileys exposes only in privacy-id form (the lid_pn_map populator
  // lands daemon-side in a follow-up; this read path is forward-compat).
  // Self-join `messages q` on (thread_jid, reply_to_id) to resolve the quoted
  // message's body + sender for replies. Same two-leg contacts/@lid join for
  // the quoted sender's name as for the main sender. q.* is all-null when the
  // quoted message isn't cached — buildReplyTo handles that.
  const rows = db.prepare(`
    SELECT m.message_id, m.thread_jid, m.sender_jid, m.from_me, m.ts,
           m.body, m.body_sha256, m.message_type, m.attachment_meta,
           (m.media_descriptor IS NOT NULL) AS media_downloadable,
           m.reply_to_id,
           COALESCE(
             c_direct.display_name, c_direct.push_name,
             c_via_lid.display_name, c_via_lid.push_name
           ) AS sender_name,
           q.body AS reply_to_body,
           q.from_me AS reply_to_from_me,
           COALESCE(
             qc_direct.display_name, qc_direct.push_name,
             qc_via_lid.display_name, qc_via_lid.push_name
           ) AS reply_to_sender_name
    FROM messages m
    LEFT JOIN contacts  c_direct  ON c_direct.jid  = m.sender_jid
    LEFT JOIN lid_pn_map l        ON l.lid         = m.sender_jid
    LEFT JOIN contacts  c_via_lid ON c_via_lid.jid = l.pn
    LEFT JOIN messages  q         ON q.thread_jid  = m.thread_jid AND q.message_id = m.reply_to_id
    LEFT JOIN contacts  qc_direct ON qc_direct.jid = q.sender_jid
    LEFT JOIN lid_pn_map ql       ON ql.lid        = q.sender_jid
    LEFT JOIN contacts  qc_via_lid ON qc_via_lid.jid = ql.pn
    WHERE m.thread_jid = ? AND m.ts < ?
    ORDER BY m.ts DESC
    LIMIT ?
  `).all(opts.thread_jid, before, limit) as Array<{
    message_id: string;
    thread_jid: string;
    sender_jid: string;
    sender_name: string | null;
    from_me: number;
    ts: number;
    body: Buffer | string | null;
    body_sha256: string | null;
    message_type: MessageType;
    attachment_meta: string | null;
    media_downloadable: number;
    reply_to_id: string | null;
    reply_to_body: Buffer | string | null;
    reply_to_from_me: number | null;
    reply_to_sender_name: string | null;
  }>;
  // Decrypt content columns in JS (body, reply_to.body) — they're ciphertext
  // at rest (#81). Everything else (names, JIDs, ts) is plaintext metadata.
  // Pass a healer so a stray-plaintext row (post-migration) is re-encrypted in
  // place on read rather than served plaintext or refused (#81 round 2).
  const reactionsByMessageId = loadReactionsForMessages(db, opts.thread_jid, rows.map((r) => r.message_id));
  return rows.map((r) => ({
    message_id: r.message_id,
    thread_jid: r.thread_jid,
    sender_jid: r.sender_jid,
    sender_name: r.from_me === 1 ? null : r.sender_name,
    from_me: r.from_me === 1,
    ts: r.ts,
    body: decryptBody(r.body, makeHealer(db, "body", r.thread_jid, r.message_id)),
    body_sha256: r.body_sha256,
    message_type: r.message_type,
    attachment_meta: r.attachment_meta ? JSON.parse(r.attachment_meta) : null,
    media_downloadable: r.media_downloadable === 1,
    reply_to_id: r.reply_to_id,
    reply_to: buildReplyTo({
      ...r,
      reply_to_body:
        r.reply_to_id == null
          ? null
          : decryptBody(r.reply_to_body, makeHealer(db, "body", r.thread_jid, r.reply_to_id)),
    }),
    reactions: reactionsByMessageId.get(r.message_id) ?? [],
  }));
}

export function getReactionTargetKey(thread_jid: string, message_id: string): ReactionTargetKey | null {
  const db = getMessagesDb();
  const row = db.prepare(`
    SELECT sender_jid, from_me FROM messages
    WHERE thread_jid = ? AND message_id = ?
  `).get(thread_jid, message_id) as {
    sender_jid: string;
    from_me: number;
  } | null;
  if (row == null) return null;
  const key: ReactionTargetKey = {
    remoteJid: thread_jid,
    id: message_id,
    fromMe: row.from_me === 1,
  };
  if (thread_jid.endsWith("@g.us")) {
    key.participant = row.sender_jid;
  }
  return key;
}

export function getMessageFull(thread_jid: string, message_id: string): string | null {
  const db = getMessagesDb();
  const row = db.prepare(`
    SELECT body, body_full FROM messages
    WHERE thread_jid = ? AND message_id = ?
  `).get(thread_jid, message_id) as {
    body: Buffer | string | null;
    body_full: Buffer | string | null;
  } | null;
  if (row == null) return null;
  // Both columns are ciphertext at rest (#81); decrypt. body_full is the
  // untruncated form (present only when the body was truncated). Heal a stray-
  // plaintext column in place on read (#81 round 2).
  if (row.body_full != null) {
    return decryptBody(row.body_full, makeHealer(db, "body_full", thread_jid, message_id));
  }
  return decryptBody(row.body, makeHealer(db, "body", thread_jid, message_id));
}

/** The stored media descriptor (raw Baileys proto bytes) + the sender/key
 *  fields needed to reconstruct a downloadable WAMessage, or null when the
 *  message has no stored descriptor. Used by the daemon's downloadMedia path. */
export interface StoredMediaDescriptor {
  descriptor: Uint8Array;
  sender_jid: string;
  from_me: boolean;
  message_type: MessageType;
  mime: string | null;
}

export function getMediaDescriptor(thread_jid: string, message_id: string): StoredMediaDescriptor | null {
  const db = getMessagesDb();
  const row = db.prepare(`
    SELECT media_descriptor, sender_jid, from_me, message_type, attachment_meta
    FROM messages WHERE thread_jid = ? AND message_id = ?
  `).get(thread_jid, message_id) as {
    media_descriptor: Buffer | null;
    sender_jid: string;
    from_me: number;
    message_type: MessageType;
    attachment_meta: string | null;
  } | null;
  if (row == null || row.media_descriptor == null) return null;
  const descriptor = decryptDescriptor(row.media_descriptor);
  if (descriptor == null) return null;
  const meta = row.attachment_meta ? (JSON.parse(row.attachment_meta) as { mime?: string }) : null;
  return {
    descriptor,
    sender_jid: row.sender_jid,
    from_me: row.from_me === 1,
    message_type: row.message_type,
    mime: meta?.mime ?? null,
  };
}

/** Minimal Baileys-shaped `quoted` argument. Cast to WAMessage at the
 *  sendMessage call site — Baileys only reads `key` (for the stanzaId
 *  linkage) and `message` (for the rendered quote preview). */
export interface QuotedReconstruction {
  key: { id: string; remoteJid: string; fromMe: boolean; participant: string };
  message: { conversation: string };
}

/**
 * Rebuild the `quoted` argument for a stored message so the daemon can send a
 * WhatsApp quoted reply WITHOUT retaining raw Baileys WAMessage objects — every
 * field comes from the messages.db row. Returns null when the quoted message
 * isn't cached (older than retention / never synced), in which case the caller
 * sends a normal (un-quoted) message.
 *
 * Note: `participant` is the stored sender_jid. For incoming messages (the
 * common reply case) that's correct. For from_me quotes it's the thread JID;
 * the daemon overrides it with the real self-JID where known. Linkage is by
 * `key.id` (stanzaId) regardless.
 */
export function getQuotedReconstruction(
  thread_jid: string,
  message_id: string,
): QuotedReconstruction | null {
  const db = getMessagesDb();
  const row = db.prepare(`
    SELECT sender_jid, from_me, body, body_full FROM messages
    WHERE thread_jid = ? AND message_id = ?
  `).get(thread_jid, message_id) as {
    sender_jid: string;
    from_me: number;
    body: Buffer | string | null;
    body_full: Buffer | string | null;
  } | null;
  if (row == null) return null;
  // body / body_full are ciphertext at rest (#81) — decrypt for the preview.
  // Heal a stray-plaintext column in place on read (#81 round 2).
  const previewBody = row.body_full != null
    ? decryptBody(row.body_full, makeHealer(db, "body_full", thread_jid, message_id))
    : decryptBody(row.body, makeHealer(db, "body", thread_jid, message_id));
  return {
    key: {
      id: message_id,
      remoteJid: thread_jid,
      fromMe: row.from_me === 1,
      participant: row.sender_jid,
    },
    message: { conversation: previewBody ?? "" },
  };
}

/** Stage-time snapshot of a single message, for embedding in a reply-draft's
 *  `quoted_preview`. Resolves sender_name via the same contacts/@lid join as
 *  the read path. Returns null when the message isn't cached. */
export interface QuotedPreviewRow {
  message_id: string;
  body: string | null;
  from_me: boolean;
  sender_name: string | null;
}

export function getQuotedPreview(thread_jid: string, message_id: string): QuotedPreviewRow | null {
  const db = getMessagesDb();
  const row = db.prepare(`
    SELECT m.body, m.from_me,
           COALESCE(
             c_direct.display_name, c_direct.push_name,
             c_via_lid.display_name, c_via_lid.push_name
           ) AS sender_name
    FROM messages m
    LEFT JOIN contacts  c_direct  ON c_direct.jid  = m.sender_jid
    LEFT JOIN lid_pn_map l        ON l.lid         = m.sender_jid
    LEFT JOIN contacts  c_via_lid ON c_via_lid.jid = l.pn
    WHERE m.thread_jid = ? AND m.message_id = ?
  `).get(thread_jid, message_id) as {
    body: Buffer | string | null;
    from_me: number;
    sender_name: string | null;
  } | null;
  if (row == null) return null;
  const fromMe = row.from_me === 1;
  return {
    message_id,
    // ciphertext at rest (#81); heal a stray-plaintext row on read (#81 round 2)
    body: decryptBody(row.body, makeHealer(db, "body", thread_jid, message_id)),
    from_me: fromMe,
    sender_name: fromMe ? null : row.sender_name,
  };
}

/**
 * Content search over the encrypted-at-rest body (#81).
 *
 * `body` is ciphertext, so SQL `LIKE` can no longer match it. Instead:
 *
 *   1. SQL filters CANDIDATE rows by the PLAINTEXT metadata bounds only —
 *      `since` (ts) and `contact_filter` (thread/contact names + JID) — and
 *      returns them newest-first. The tool contract requires at least one of
 *      these, so the candidate set is always metadata-bounded (no full-table
 *      decrypt).
 *   2. Each candidate's body is decrypted in JS and substring-matched
 *      (case-insensitive) against the query. body_full is consulted when the
 *      stored body was truncated, so matches in the tail of a long message
 *      aren't missed.
 *   3. We stop once `limit` matches are collected (iterating newest-first),
 *      bounding decrypt work to roughly the rows needed to fill the page.
 *
 * Behavior note vs. the old SQL LIKE: matching is now done on decrypted text
 * in JS. It's still a case-insensitive substring match, so results are
 * equivalent for normal text. The one difference is collation: SQLite's
 * `COLLATE NOCASE` is ASCII-only, whereas JS `toLowerCase()` is full-unicode,
 * so unicode-cased queries match slightly MORE generously now (a superset).
 */
export function searchMessages(opts: {
  query: string;
  since?: number;
  contact_filter?: string;
  limit?: number;
}): MessageRow[] {
  const db = getMessagesDb();
  const where: string[] = [];
  const params: (string | number)[] = [];
  if (opts.since != null) {
    where.push("m.ts >= ?");
    params.push(opts.since);
  }
  if (opts.contact_filter != null && opts.contact_filter.length > 0) {
    // Match thread name (group), thread JID, or the resolved sender's
    // contact name — so "search for messages from Paul" surfaces hits
    // even when the thread itself isn't named after Paul.
    where.push("(t.display_name LIKE ? OR m.thread_jid LIKE ? OR ct.display_name LIKE ? OR ct.push_name LIKE ?)");
    const like = `%${opts.contact_filter}%`;
    params.push(like, like, like, like);
  }
  const whereSql = where.length > 0 ? `WHERE ${where.join(" AND ")}` : "";
  const limit = opts.limit ?? 50;
  const needle = opts.query.toLowerCase();
  const pageSize = Math.min(5000, Math.max(250, limit * 20));
  let cursorTs = Number.MAX_SAFE_INTEGER;
  let cursorRowid = Number.MAX_SAFE_INTEGER;
  // Candidate rows, newest-first, in bounded pages. Body matching still
  // happens in JS after decrypt, but SQL never materializes the full
  // metadata-bounded set in one `.all()`.
  const selectPage = db.prepare(`
    SELECT m.rowid AS rowid,
           m.message_id, m.thread_jid, m.sender_jid, m.from_me, m.ts, m.body,
           m.body_full, m.body_sha256, m.message_type, m.attachment_meta, m.reply_to_id,
           COALESCE(cs.display_name, cs.push_name) AS sender_name,
           q.body AS reply_to_body,
           q.from_me AS reply_to_from_me,
           COALESCE(qcs.display_name, qcs.push_name) AS reply_to_sender_name
    FROM messages m
    LEFT JOIN threads t ON t.thread_jid = m.thread_jid
    LEFT JOIN contacts ct ON ct.jid = m.thread_jid
    LEFT JOIN contacts cs ON cs.jid = m.sender_jid
    LEFT JOIN messages q ON q.thread_jid = m.thread_jid AND q.message_id = m.reply_to_id
    LEFT JOIN contacts qcs ON qcs.jid = q.sender_jid
    ${whereSql}
    ${whereSql.length > 0 ? "AND" : "WHERE"} (m.ts < ? OR (m.ts = ? AND m.rowid < ?))
    ORDER BY m.ts DESC, m.rowid DESC
    LIMIT ?
  `);

  const out: MessageRow[] = [];
  while (out.length < limit) {
    const rows = selectPage.all(...params, cursorTs, cursorTs, cursorRowid, pageSize) as Array<{
    rowid: number;
    message_id: string;
    thread_jid: string;
    sender_jid: string;
    sender_name: string | null;
    from_me: number;
    ts: number;
    body: Buffer | string | null;
    body_full: Buffer | string | null;
    body_sha256: string | null;
    message_type: MessageType;
    attachment_meta: string | null;
    reply_to_id: string | null;
    reply_to_body: Buffer | string | null;
    reply_to_from_me: number | null;
    reply_to_sender_name: string | null;
  }>;
    if (rows.length === 0) break;
    cursorTs = rows[rows.length - 1]!.ts;
    cursorRowid = rows[rows.length - 1]!.rowid;

    for (const r of rows) {
      if (out.length >= limit) break;
      // Decrypt the full body when present (truncated case) so a match in the
      // tail isn't missed; otherwise decrypt the stored (full) body. Heal a
      // stray-plaintext column in place on read (#81 round 2). A row that can't
      // be decrypted (null after a refuse) is skipped — never matched on
      // plaintext that should have been ciphertext.
      const decryptedBody =
        r.body_full != null
          ? decryptBody(r.body_full, makeHealer(db, "body_full", r.thread_jid, r.message_id))
          : decryptBody(r.body, makeHealer(db, "body", r.thread_jid, r.message_id));
      if (decryptedBody == null) continue;
      if (!decryptedBody.toLowerCase().includes(needle)) continue;
      out.push({
        message_id: r.message_id,
        thread_jid: r.thread_jid,
        sender_jid: r.sender_jid,
        sender_name: r.from_me === 1 ? null : r.sender_name,
        from_me: r.from_me === 1,
        ts: r.ts,
        // Return the (possibly truncated) stored body, consistent with the
        // other read tools — full text is available via get_whatsapp_message_full.
        body: decryptBody(r.body, makeHealer(db, "body", r.thread_jid, r.message_id)),
        body_sha256: r.body_sha256,
        message_type: r.message_type,
        attachment_meta: r.attachment_meta ? JSON.parse(r.attachment_meta) : null,
        // Search results don't drive media download (that's a transcript
        // action); the column isn't selected here, so report not-downloadable.
        media_downloadable: false,
        reply_to_id: r.reply_to_id,
        reply_to: buildReplyTo({
          ...r,
          reply_to_body:
            r.reply_to_id == null
              ? null
              : decryptBody(r.reply_to_body, makeHealer(db, "body", r.thread_jid, r.reply_to_id)),
        }),
        reactions: [],
      });
    }
  }
  return out;
}

/** Delete messages older than `retentionMs` from now. Returns rows deleted. */
export function sweepOldMessages(retentionMs: number): number {
  const db = getMessagesDb();
  const cutoff = Date.now() - retentionMs;
  const run = db.transaction(() => {
    const messages = db.prepare("DELETE FROM messages WHERE ts < ?").run(cutoff);
    db.prepare("DELETE FROM message_reactions WHERE ts < ?").run(cutoff);
    return Number(messages.changes);
  });
  return run();
}

/** Test seam — close and re-open on next call. */
export function _resetForTesting(): void {
  if (_db != null) {
    _db.close();
    _db = null;
  }
}

// Re-export so callers don't need to import from _untrusted.ts.
export { DEFAULT_BODY_CAP_BYTES };
