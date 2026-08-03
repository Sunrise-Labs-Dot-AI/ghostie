// SQLite-backed Baileys auth state. Replaces Baileys' default file-based
// useMultiFileAuthState (which their own docs warn against: "I wouldn't
// endorse this for any production level use other than perhaps a bot.").
//
// One row per (type, id). WAL mode for concurrent safety even though we
// only have one writer. mode 0600 on the DB file + WAL/SHM sidecars.
//
// Row values are AES-256-GCM wrapped with a Keychain-stored master key
// (see storage/crypto.ts + storage/keychain.ts). A copy-out attacker
// who reads the .db file off disk gets ciphertext only.

import { Database } from "bun:sqlite";
import {
  type AuthenticationCreds,
  type AuthenticationState,
  type SignalDataTypeMap,
  initAuthCreds,
  proto,
  BufferJSON,
} from "@whiskeysockets/baileys";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { PATHS } from "../paths.ts";
import { isCiphertextAuthError, unwrap, wrap } from "./crypto.ts";

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS auth_state (
  type   TEXT NOT NULL,
  id     TEXT NOT NULL,
  value  BLOB NOT NULL,
  PRIMARY KEY (type, id)
);
CREATE TABLE IF NOT EXISTS auth_creds (
  k     TEXT PRIMARY KEY,
  value BLOB NOT NULL
);
`;

const CREDS_KEY = "creds";

let _db: Database | null = null;

function getDb(): Database {
  if (_db != null) return _db;
  const path = PATHS.sessionDb;
  if (!existsSync(dirname(path))) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  }
  const db = new Database(path, { create: true });
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA synchronous = NORMAL");
  db.exec(SCHEMA_SQL);
  try { chmodSync(path, 0o600); } catch { /* not on disk in some edge cases */ }
  for (const suffix of ["-wal", "-shm"] as const) {
    try { chmodSync(path + suffix, 0o600); } catch { /* not created yet */ }
  }
  _db = db;
  return db;
}

function readCreds(): AuthenticationCreds | null {
  const db = getDb();
  const row = db.prepare("SELECT value FROM auth_creds WHERE k = ?").get(CREDS_KEY) as { value: Buffer } | null;
  if (row == null) return null;
  const plaintext = unwrap(Buffer.from(row.value));
  return JSON.parse(plaintext, BufferJSON.reviver) as AuthenticationCreds;
}

function writeCreds(creds: AuthenticationCreds): void {
  const db = getDb();
  const serialized = JSON.stringify(creds, BufferJSON.replacer);
  const blob = wrap(serialized);
  db.prepare(`
    INSERT INTO auth_creds (k, value) VALUES (?, ?)
    ON CONFLICT(k) DO UPDATE SET value = excluded.value
  `).run(CREDS_KEY, blob);
}

function readKey<T extends keyof SignalDataTypeMap>(type: T, id: string): SignalDataTypeMap[T] | undefined {
  const db = getDb();
  const row = db.prepare("SELECT value FROM auth_state WHERE type = ? AND id = ?").get(type, id) as { value: Buffer } | null;
  if (row == null) return undefined;
  const plaintext = unwrap(Buffer.from(row.value));
  const decoded = JSON.parse(plaintext, BufferJSON.reviver);
  // Baileys stores app-state-sync-keys as proto.Message.AppStateSyncKeyData;
  // the rest are plain objects/Buffers. proto.fromObject reconstitutes the
  // protobuf shape so Baileys can use it.
  if (type === "app-state-sync-key") {
    // proto.fromObject returns a specific message subtype; cast through
    // unknown because TypeScript can't prove the type-parameter match.
    return proto.Message.AppStateSyncKeyData.fromObject(decoded) as unknown as SignalDataTypeMap[T];
  }
  return decoded as SignalDataTypeMap[T];
}

function writeKey<T extends keyof SignalDataTypeMap>(type: T, id: string, value: SignalDataTypeMap[T] | null): void {
  const db = getDb();
  if (value == null) {
    db.prepare("DELETE FROM auth_state WHERE type = ? AND id = ?").run(type, id);
    return;
  }
  const serialized = JSON.stringify(value, BufferJSON.replacer);
  const blob = wrap(serialized);
  db.prepare(`
    INSERT INTO auth_state (type, id, value) VALUES (?, ?, ?)
    ON CONFLICT(type, id) DO UPDATE SET value = excluded.value
  `).run(type, id, blob);
}

/**
 * Baileys-compatible auth state backed by SQLite.
 *
 * Returned shape matches `useMultiFileAuthState`:
 *   - state: { creds, keys: { get, set } }
 *   - saveCreds: function the caller invokes inside creds.update handler
 *
 * IMPORTANT: callers MUST attach saveCreds to the creds.update event so
 * Signal session keys persist. Without this, the session breaks silently
 * after a few message exchanges.
 */
export async function useSqliteAuthState(): Promise<{
  state: AuthenticationState;
  saveCreds: () => Promise<void>;
}> {
  // Initialize / load creds.
  let creds = readCreds();
  if (creds == null) {
    creds = initAuthCreds();
    writeCreds(creds);
  }

  const keys: AuthenticationState["keys"] = {
    get: async <T extends keyof SignalDataTypeMap>(type: T, ids: string[]) => {
      const out: { [id: string]: SignalDataTypeMap[T] } = {};
      for (const id of ids) {
        const v = readKey(type, id);
        if (v != null) out[id] = v;
      }
      return out;
    },
    set: async (data) => {
      for (const category of Object.keys(data) as Array<keyof SignalDataTypeMap>) {
        const entries = data[category];
        if (entries == null) continue;
        for (const id of Object.keys(entries)) {
          writeKey(category, id, (entries as Record<string, SignalDataTypeMap[typeof category] | null>)[id] ?? null);
        }
      }
    },
  };

  return {
    state: { creds, keys },
    saveCreds: async () => {
      // creds is the SAME object Baileys mutates in-place; re-serialize on save.
      writeCreds(creds!);
    },
  };
}

/**
 * Wipe the Baileys session so the daemon can re-pair from scratch. Called from
 * the unlinkAndReset recovery path.
 *
 * Deletes the auth rows ONLY. It deliberately does NOT rotate the Keychain
 * master key, despite that having once looked like free defense in depth:
 *
 *   `messages.db` encrypts `body` / `body_full` / `media_descriptor` with the
 *   SAME master key as these auth rows (see storage/messages.ts, #81). Deleting
 *   the key therefore did not just invalidate the session — it silently made
 *   every cached message body permanently undecryptable, on a code path whose
 *   own UI copy promised "your message history is preserved".
 *
 * It was also self-defeating: crypto.ts caches the master key for the process
 * lifetime, so after a delete the SAME process kept wrapping the freshly-paired
 * credentials with the now-deleted key. The next daemon start found no Keychain
 * item, minted a new one, and every read failed the GCM auth check — a reset
 * that bricked the session it had just repaired, one restart later.
 *
 * Rotating the key is only safe once message content is keyed separately.
 */
export function deleteSession(): void {
  const db = getDb();
  // Forensic breadcrumb. Wiping the session silently unlinks the user's phone,
  // and during this change we hit a real instance of the auth rows vanishing
  // that could not be attributed after the fact: no daemon was running, no
  // caller was in any log, and every candidate (tests, MCP, review tooling, the
  // menu bar's confirm-gated reset paths) was individually ruled out. The event
  // was real but unexplained, which is a bad place to leave a destructive
  // operation. Record who called and what was destroyed so a recurrence is
  // attributable instead of forensic guesswork. Cheap: runs only on reset.
  const before = countAuthRows(db);
  const caller = (new Error().stack ?? "").split("\n").slice(2, 6).join(" <- ").trim();
  process.stderr.write(
    `deleteSession: wiping ${before.creds} creds + ${before.state} key rows at ${PATHS.sessionDb}\n` +
    `deleteSession: called from ${caller || "(no stack)"}\n`,
  );

  db.exec("DELETE FROM auth_state");
  db.exec("DELETE FROM auth_creds");
}

/** Row counts for the forensic log above. Never touches row VALUES. */
function countAuthRows(db: Database): { creds: number; state: number } {
  try {
    return {
      creds: (db.prepare("SELECT count(*) AS n FROM auth_creds").get() as { n: number }).n,
      state: (db.prepare("SELECT count(*) AS n FROM auth_state").get() as { n: number }).n,
    };
  } catch {
    return { creds: -1, state: -1 };
  }
}

/**
 * Raised when stored auth rows exist but cannot be decrypted under the current
 * master key. Terminal for the session: the only fix is a re-pair.
 *
 * NOT raised when the Keychain itself is unreachable — that surfaces as
 * `KeychainAccessError`, which is transient and must never trigger a wipe.
 */
export class SessionUnreadableError extends Error {
  /** How many auth rows failed to decrypt (creds counts as one). */
  readonly failedRows: number;
  constructor(message: string, failedRows: number) {
    super(message);
    this.name = "SessionUnreadableError";
    this.failedRows = failedRows;
  }
}

/**
 * Decrypt-check every stored auth row BEFORE Baileys is constructed.
 *
 * Why preflight rather than letting it fail naturally: `readCreds` runs inside
 * `useSqliteAuthState`, but the per-key `auth_state` rows are decrypted lazily
 * by `keys.get` long after `connection.start()` has returned. A corrupt Signal
 * key row would therefore throw from deep inside a Baileys event handler, with
 * no caller positioned to catch it and park the daemon. Checking everything up
 * front gives exactly one decision point.
 *
 * Cost is trivial: a few thousand small AES-GCM opens, single-digit ms.
 *
 * Throws `SessionUnreadableError` if any row fails to authenticate, and lets
 * `KeychainAccessError` propagate untouched.
 */
export function assertSessionReadable(): void {
  const db = getDb();
  let failed = 0;

  const credsRow = db.prepare("SELECT value FROM auth_creds WHERE k = ?").get(CREDS_KEY) as { value: Buffer } | null;
  if (credsRow != null) {
    try {
      JSON.parse(unwrap(Buffer.from(credsRow.value)), BufferJSON.reviver);
    } catch (e) {
      if (!isCiphertextAuthError(e)) throw e;
      failed += 1;
    }
  }

  const rows = db.prepare("SELECT value FROM auth_state").all() as Array<{ value: Buffer }>;
  for (const row of rows) {
    try {
      unwrap(Buffer.from(row.value));
    } catch (e) {
      if (!isCiphertextAuthError(e)) throw e;
      failed += 1;
    }
  }

  if (failed > 0) {
    throw new SessionUnreadableError(
      `${failed} of ${rows.length + (credsRow != null ? 1 : 0)} stored WhatsApp auth rows could not be decrypted ` +
      "with the current Keychain key. The session must be re-paired.",
      failed,
    );
  }
}

/** Test seam. */
export function _resetForTesting(): void {
  if (_db != null) {
    _db.close();
    _db = null;
  }
}
