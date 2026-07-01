import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isoUtcToAppleDateNs } from "../../imessage-drafts/src/chatdb/open.ts";
import { topGaps } from "./gaps.ts";

let dir: string;
let dbPath: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "bday-gaps-"));
  dbPath = join(dir, "chat.db");
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

// chat.db with two 1:1 threads: Allie (texted a lot) and Bob (texted once).
function buildChat(): void {
  const db = new Database(dbPath);
  db.exec(`
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, attributedBody BLOB, date INTEGER,
      is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
  `);
  const handle = (id: string) => {
    db.run(`INSERT INTO handle (id, service) VALUES (?, 'iMessage')`, [id]);
    return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  };
  const chat = (g: string) => {
    db.run(`INSERT INTO chat (guid) VALUES (?)`, [g]);
    return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  };
  const msg = (c: number, n: number) => {
    for (let i = 0; i < n; i++) {
      db.run(`INSERT INTO message (text, date, is_from_me) VALUES ('x', ?, 1)`, [isoUtcToAppleDateNs("2026-01-01T00:00:00Z")]);
      const mid = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
      db.run(`INSERT INTO chat_message_join VALUES (?, ?)`, [c, mid]);
    }
  };
  const allie = handle("+14045550147");
  const bob = handle("+15551112222");
  const cA = chat("a"); db.run(`INSERT INTO chat_handle_join VALUES (?, ?)`, [cA, allie]); msg(cA, 8);
  const cB = chat("b"); db.run(`INSERT INTO chat_handle_join VALUES (?, ?)`, [cB, bob]); msg(cB, 1);
  db.close();
}

const names = new Map<string, string>([
  ["4045550147", "Allie Texted"],
  ["5551112222", "Bob Oneoff"],
]);

describe("topGaps", () => {
  test("surfaces high-affinity contacts who have no birthday, with a dispatchable handle", () => {
    buildChat();
    const gaps = topGaps(dbPath, names, new Set(), { topN: 1, limit: 10 });
    // topN=1 → only Allie is "texts a lot"; Bob (1 message, rank 2) has no reason → excluded.
    expect(gaps.map((g) => g.name)).toEqual(["Allie Texted"]);
    expect(gaps[0]!.best_handle).toBe("+14045550147"); // original E.164 from chat.db, dispatchable
    expect(gaps[0]!.reasons).toContain("You text them a lot");
  });

  test("excludes contacts who already have a birthday", () => {
    buildChat();
    const gaps = topGaps(dbPath, names, new Set(["4045550147"]), { topN: 5, limit: 10 });
    expect(gaps.map((g) => g.name)).not.toContain("Allie Texted");
  });

  test("unnamed handles are not surfaced (can't label them)", () => {
    buildChat();
    const gaps = topGaps(dbPath, new Map(), new Set(), { topN: 5, limit: 10 });
    expect(gaps).toEqual([]);
  });

  test("missing chat.db → empty (no crash)", () => {
    const gaps = topGaps(join(dir, "nope.db"), names, new Set(), { topN: 5, limit: 10 });
    expect(gaps).toEqual([]);
  });
});
