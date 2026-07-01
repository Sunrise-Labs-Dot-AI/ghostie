import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isoUtcToAppleDateNs } from "../../imessage-drafts/src/chatdb/open.ts";
import { computeSignals, assertNoBodyLeak, PrivacyGuardError, type SignalCandidate } from "./signals.ts";

let dir: string;
let dbPath: string;
const NOW = Date.parse("2026-06-01T00:00:00Z");

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "bday-signals-"));
  dbPath = join(dir, "chat.db");
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

function buildDb(): void {
  const db = new Database(dbPath);
  db.exec(`
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT);
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      text TEXT, attributedBody BLOB, date INTEGER,
      is_from_me INTEGER DEFAULT 0,
      associated_message_type INTEGER DEFAULT 0,
      item_type INTEGER DEFAULT 0,
      cache_has_attachments INTEGER DEFAULT 0
    );
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
  `);
  const handle = (id: string) => {
    db.run(`INSERT INTO handle (id, service) VALUES (?, 'iMessage')`, [id]);
    return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  };
  const chat = () => {
    db.run(`INSERT INTO chat (guid) VALUES (?)`, [`g-${Math.round(Math.random() * 1e9)}`]);
    return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  };
  const link = (c: number, h: number) => db.run(`INSERT INTO chat_handle_join VALUES (?, ?)`, [c, h]);
  const msg = (c: number, o: { text: string; iso: string; fromMe: boolean; assoc?: number }) => {
    db.run(
      `INSERT INTO message (text, date, is_from_me, associated_message_type, item_type) VALUES (?, ?, ?, ?, 0)`,
      [o.text, isoUtcToAppleDateNs(o.iso), o.fromMe ? 1 : 0, o.assoc ?? 0],
    );
    const mid = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
    db.run(`INSERT INTO chat_message_join VALUES (?, ?)`, [c, mid]);
  };

  const allie = handle("+14045550147");
  const bob = handle("+15551112222");
  const c1 = chat();
  link(c1, allie);
  const c2 = chat();
  link(c2, bob);

  // Allie: 4 plain outbound + 1 birthday wish outbound (near her June 4 b'day in
  // 2024) + 1 recent inbound (for recency) + 1 outbound tapback (must NOT count).
  msg(c1, { text: "hey", iso: "2025-02-01T10:00:00Z", fromMe: true });
  msg(c1, { text: "lunch?", iso: "2025-03-01T10:00:00Z", fromMe: true });
  msg(c1, { text: "nice", iso: "2025-04-01T10:00:00Z", fromMe: true });
  msg(c1, { text: "cool", iso: "2025-05-01T10:00:00Z", fromMe: true });
  msg(c1, { text: "happy birthday Allie hope it is great", iso: "2024-06-04T17:00:00Z", fromMe: true });
  msg(c1, { text: "miss you", iso: "2026-05-30T12:00:00Z", fromMe: false }); // inbound, recency
  msg(c1, { text: "👍", iso: "2025-05-02T10:00:00Z", fromMe: true, assoc: 2000 }); // tapback, excluded

  // Bob: 1 outbound, no birthday wish.
  msg(c2, { text: "yo", iso: "2026-01-01T10:00:00Z", fromMe: true });

  db.close();
}

const candidates: SignalCandidate[] = [
  { key: "allie", handles: ["4045550147"], month: 6, day: 4 },
  { key: "bob", handles: ["5551112222"], month: 8, day: 20 },
];

describe("computeSignals", () => {
  test("frequency, rank, recency, and wished-before", () => {
    buildDb();
    const { byKey, available } = computeSignals(dbPath, candidates, { topN: 1, nowMs: NOW });
    expect(available).toBe(true);

    const allie = byKey.get("allie")!;
    expect(allie.out_count).toBe(5); // 4 plain + 1 wish; tapback excluded
    expect(allie.text_rank).toBe(1); // most outbound
    expect(allie.last_texted_days).toBe(1); // inbound 2026-05-30T12:00Z, ~1.5d before now → floor 1
    expect(allie.wished_before).toBe(true);
    expect(allie.wished_years).toEqual([2024]);

    const bob = byKey.get("bob")!;
    expect(bob.out_count).toBe(1);
    expect(bob.text_rank).toBe(2);
    expect(bob.wished_before).toBe(false);
    expect(bob.wished_years).toEqual([]);
  });

  test("call history is a separate affinity axis (call-only contact ranks via calls)", () => {
    buildDb();
    const callDbPath = join(dir, "calls.db");
    const cdb = new Database(callDbPath);
    cdb.exec(`CREATE TABLE ZCALLRECORD (ZADDRESS TEXT, ZDATE REAL);`);
    // Bob is called a lot (10×) but barely texted; Allie not called.
    const CORE = 978_307_200;
    const recent = (Date.parse("2026-05-31T00:00:00Z") / 1000) - CORE;
    for (let i = 0; i < 10; i++) cdb.run(`INSERT INTO ZCALLRECORD VALUES (?, ?)`, ["+15551112222", recent]);
    cdb.close();

    const { byKey } = computeSignals(dbPath, candidates, { topN: 1, nowMs: NOW, callDbPath });
    const bob = byKey.get("bob")!;
    expect(bob.call_count).toBe(10);
    expect(bob.call_rank).toBe(1); // most-called
    expect(bob.last_call_days).not.toBeNull();
    const allie = byKey.get("allie")!;
    expect(allie.call_count).toBe(0);
    expect(allie.call_rank).toBeNull();
  });

  test("missing call DB is ignored (text signals intact)", () => {
    buildDb();
    const { byKey } = computeSignals(dbPath, candidates, { topN: 1, nowMs: NOW, callDbPath: join(dir, "no-calls.db") });
    expect(byKey.get("allie")!.call_count).toBe(0);
    expect(byKey.get("allie")!.text_rank).toBe(1); // text path unaffected
  });

  test("graceful degrade when chat.db is unreadable", () => {
    const { byKey, available } = computeSignals(join(dir, "nope.db"), candidates, { topN: 25, nowMs: NOW });
    expect(available).toBe(false);
    expect(byKey.get("allie")!.out_count).toBe(0);
    expect(byKey.get("allie")!.wished_before).toBe(false);
  });

  test("no birthday wish outside the date window", () => {
    buildDb();
    // Same chat, but treat Allie's birthday as Dec 25 — the June wish must not count.
    const { byKey } = computeSignals(dbPath, [{ key: "allie", handles: ["4045550147"], month: 12, day: 25 }], {
      topN: 1,
      nowMs: NOW,
    });
    expect(byKey.get("allie")!.wished_before).toBe(false);
  });
});

describe("assertNoBodyLeak", () => {
  test("passes when no body appears in output", () => {
    expect(() => assertNoBodyLeak(JSON.stringify({ wished: true }), ["happy birthday friend"])).not.toThrow();
  });
  test("throws when a multi-word body leaks", () => {
    expect(() => assertNoBodyLeak(JSON.stringify({ preview: "happy birthday friend" }), ["happy birthday friend"])).toThrow(
      PrivacyGuardError,
    );
  });
});
