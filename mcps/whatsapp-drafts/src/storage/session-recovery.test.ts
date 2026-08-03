// Regression cover for the "WhatsApp won't reconnect and there's no way out"
// failure: the Keychain wrap key stops matching the ciphertext in session.db,
// every read throws a GCM auth error, and the daemon crash-loops forever.
//
// Reproduced here the way it actually happened — rows written under key A, then
// read back under key B — rather than by corrupting bytes, so the test fails if
// the classification (unrecoverable ciphertext vs. transient Keychain outage)
// regresses in either direction.

import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const home = mkdtempSync(join(tmpdir(), "whatsapp-mcp-session-recovery-"));
const savedHome = process.env.WHATSAPP_MCP_HOME;
const savedTestKey = process.env.WHATSAPP_MCP_TEST_KEY;
process.env.WHATSAPP_MCP_HOME = home;

const KEY_A = randomBytes(32).toString("base64");
const KEY_B = randomBytes(32).toString("base64");
process.env.WHATSAPP_MCP_TEST_KEY = KEY_A;

const { _resetKeyCache, CiphertextAuthError } = await import("./crypto.ts");
const {
  assertSessionReadable,
  deleteSession,
  useSqliteAuthState,
  SessionUnreadableError,
  _resetForTesting,
} = await import("./session.ts");

const sessionDb = join(home, "session.db");

/** Swap the active master key, exactly as a Keychain rotation would. */
function useKey(b64: string): void {
  process.env.WHATSAPP_MCP_TEST_KEY = b64;
  _resetKeyCache();
}

function rowCounts(): { creds: number; state: number } {
  const db = new Database(sessionDb, { readwrite: true });
  try {
    const creds = (db.prepare("SELECT count(*) AS n FROM auth_creds").get() as { n: number }).n;
    const state = (db.prepare("SELECT count(*) AS n FROM auth_state").get() as { n: number }).n;
    return { creds, state };
  } finally {
    db.close();
  }
}

beforeEach(() => {
  _resetForTesting();
  rmSync(sessionDb, { force: true });
  rmSync(`${sessionDb}-wal`, { force: true });
  rmSync(`${sessionDb}-shm`, { force: true });
  useKey(KEY_A);
});

afterAll(() => {
  _resetForTesting();
  if (savedHome == null) delete process.env.WHATSAPP_MCP_HOME;
  else process.env.WHATSAPP_MCP_HOME = savedHome;
  if (savedTestKey == null) delete process.env.WHATSAPP_MCP_TEST_KEY;
  else process.env.WHATSAPP_MCP_TEST_KEY = savedTestKey;
  _resetKeyCache();
  rmSync(home, { recursive: true, force: true });
});

/** Seed a session: creds plus some Signal key rows, all under the current key. */
async function seedSession(): Promise<void> {
  const { state, saveCreds } = await useSqliteAuthState();
  await saveCreds();
  await state.keys.set({
    "pre-key": {
      "1": { public: Buffer.from("aa"), private: Buffer.from("bb") },
      "2": { public: Buffer.from("cc"), private: Buffer.from("dd") },
    },
  } as never);
}

describe("assertSessionReadable", () => {
  test("passes on a fresh (empty) store — nothing to decrypt yet", () => {
    expect(() => assertSessionReadable()).not.toThrow();
  });

  test("passes on a store written under the current key", async () => {
    await seedSession();
    _resetForTesting();
    expect(() => assertSessionReadable()).not.toThrow();
  });

  test("throws SessionUnreadableError once the wrap key has rotated", async () => {
    await seedSession();
    _resetForTesting();
    useKey(KEY_B); // the Keychain minted a replacement key

    expect(() => assertSessionReadable()).toThrow(SessionUnreadableError);
  });

  // The bug this preflight exists for: creds decrypted fine, so startup
  // "succeeded", and the corrupt Signal key row only blew up later inside a
  // Baileys event handler where nothing could catch it and park the daemon.
  test("catches a bad auth_state row even when creds decrypt cleanly", async () => {
    await seedSession();
    _resetForTesting();

    // Re-wrap ONLY the creds row under key B, leaving auth_state under key A,
    // then read everything under key B: creds pass, key rows fail.
    const db = new Database(sessionDb, { readwrite: true });
    const credsPlain = (db.prepare("SELECT value FROM auth_creds WHERE k = 'creds'").get() as { value: Buffer });
    db.close();
    const { unwrap } = await import("./crypto.ts");
    const plaintext = unwrap(Buffer.from(credsPlain.value));

    useKey(KEY_B);
    const { wrap } = await import("./crypto.ts");
    const db2 = new Database(sessionDb, { readwrite: true });
    db2.prepare("UPDATE auth_creds SET value = ? WHERE k = 'creds'").run(wrap(plaintext));
    db2.close();
    _resetForTesting();

    let caught: unknown;
    try { assertSessionReadable(); } catch (e) { caught = e; }
    expect(caught).toBeInstanceOf(SessionUnreadableError);
    expect((caught as InstanceType<typeof SessionUnreadableError>).failedRows).toBeGreaterThan(0);
  });

  test("reports how many rows failed", async () => {
    await seedSession();
    _resetForTesting();
    useKey(KEY_B);
    try {
      assertSessionReadable();
      throw new Error("expected assertSessionReadable to throw");
    } catch (e) {
      expect(e).toBeInstanceOf(SessionUnreadableError);
      // creds + both pre-keys.
      expect((e as InstanceType<typeof SessionUnreadableError>).failedRows).toBe(3);
    }
  });
});

describe("deleteSession", () => {
  test("clears every auth row so the next start re-pairs", async () => {
    await seedSession();
    expect(rowCounts().state).toBeGreaterThan(0);

    deleteSession();

    expect(rowCounts()).toEqual({ creds: 0, state: 0 });
  });

  test("recovers an unreadable session: wipe, then the preflight passes again", async () => {
    await seedSession();
    _resetForTesting();
    useKey(KEY_B);
    expect(() => assertSessionReadable()).toThrow(SessionUnreadableError);

    deleteSession();

    expect(() => assertSessionReadable()).not.toThrow();
  });

  // The load-bearing one. deleteSession used to call deleteMasterKey(), but
  // messages.db wraps `body`/`body_full`/`media_descriptor` with that SAME key
  // — so "reconnect WhatsApp" silently made every cached message permanently
  // undecryptable while the UI promised history was preserved. It was also
  // self-defeating: crypto.ts caches the key, so the freshly-paired creds got
  // written under the deleted key and died on the next restart.
  test("does NOT rotate the master key — message history stays decryptable", async () => {
    const { wrap, unwrap } = await import("./crypto.ts");
    // Stand in for a messages.db body encrypted under the live key.
    const historyBlob = wrap("a cached message body");

    await seedSession();
    deleteSession();

    expect(unwrap(historyBlob)).toBe("a cached message body");
  });

  test("credentials written after a reset survive a daemon restart", async () => {
    await seedSession();
    deleteSession();

    // Re-pair in the same process (the key cache is still warm)...
    await seedSession();
    // ...then simulate the next daemon start: fresh handles, key re-read.
    _resetForTesting();
    _resetKeyCache();

    expect(() => assertSessionReadable()).not.toThrow();
  });
});

describe("error classification", () => {
  // A locked or denied Keychain must never be reported as unreadable
  // ciphertext: the recovery it offers is destructive, and the session is
  // probably fine.
  test("SessionUnreadableError is distinct from a raw ciphertext error", async () => {
    await seedSession();
    _resetForTesting();
    useKey(KEY_B);

    let caught: unknown;
    try { assertSessionReadable(); } catch (e) { caught = e; }
    expect(caught).toBeInstanceOf(SessionUnreadableError);
    expect(caught).not.toBeInstanceOf(CiphertextAuthError);
  });
});
