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
import { unwrap, wrap } from "./crypto.ts";
import { deleteMasterKey } from "./keychain.ts";

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

/** Wipe the session entirely. Called from unlinkAndReset recovery path.
 *  Also deletes the Keychain master key so a fresh re-pair generates a
 *  fresh wrapping key (defense in depth). */
export function deleteSession(): void {
  const db = getDb();
  db.exec("DELETE FROM auth_state");
  db.exec("DELETE FROM auth_creds");
  try { deleteMasterKey(); } catch (e) {
    // Best-effort: if Keychain delete fails, surface to stderr but don't
    // block the reset. The session ciphertext is gone either way.
    process.stderr.write(`Keychain key delete warning: ${(e as Error).message}\n`);
  }
}

/** Test seam. */
export function _resetForTesting(): void {
  if (_db != null) {
    _db.close();
    _db = null;
  }
}
