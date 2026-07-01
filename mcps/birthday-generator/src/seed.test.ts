import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isoUtcToAppleDateNs } from "../../imessage-drafts/src/chatdb/open.ts";
import { buildSeed, type SeedContact } from "./seed.ts";

let dir: string;
let dbPath: string;
const NOW = Date.parse("2026-06-01T00:00:00Z");
const CORE = 978_307_200; // Apple Core Data epoch (for the calls DB)

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "bday-seed-"));
  dbPath = join(dir, "chat.db");
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

// Minimal chat.db (mirrors signals.test.ts).
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
      item_type INTEGER DEFAULT 0
    );
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
  `);
  const handle = (id: string) => {
    db.run(`INSERT INTO handle (id, service) VALUES (?, 'iMessage')`, [id]);
    return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  };
  const chat = () => {
    db.run(`INSERT INTO chat (guid) VALUES (?)`, [`g-${db.query<{ n: number }, []>(`SELECT count(*) AS n FROM chat`).get()!.n}`]);
    return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  };
  const link = (c: number, h: number) => db.run(`INSERT INTO chat_handle_join VALUES (?, ?)`, [c, h]);
  const msg = (c: number, text: string, iso: string, fromMe: boolean) => {
    db.run(`INSERT INTO message (text, date, is_from_me, associated_message_type, item_type) VALUES (?, ?, ?, 0, 0)`,
      [text, isoUtcToAppleDateNs(iso), fromMe ? 1 : 0]);
    const mid = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
    db.run(`INSERT INTO chat_message_join VALUES (?, ?)`, [c, mid]);
  };
  const outbound = (c: number, n: number, isoBase: string) => {
    for (let i = 0; i < n; i++) msg(c, `m${i}`, isoBase, true);
  };

  // Eve: 6 recent outbound, no saved birthday, no wish → regular, inferred null.
  const eve = handle("+15553334444"); const cEve = chat(); link(cEve, eve);
  outbound(cEve, 6, "2026-03-01T12:00:00Z");

  // Allie: 5 recent outbound + a past birthday wish (2024-06-04) → regular,
  // inferred 06-04 (no saved birthday).
  const allie = handle("+14045550147"); const cAl = chat(); link(cAl, allie);
  outbound(cAl, 5, "2026-02-01T12:00:00Z");
  msg(cAl, "happy birthday Allie hope it's great", "2024-06-04T12:00:00Z", true);

  // Dave: 6 recent outbound + a wish, but HAS a saved birthday → saved wins,
  // inference skipped.
  const dave = handle("+15557776666"); const cDa = chat(); link(cDa, dave);
  outbound(cDa, 6, "2026-04-01T12:00:00Z");
  msg(cDa, "happy bday Dave!", "2023-09-09T12:00:00Z", true);

  // Bob: only 1 outbound (below MIN_OUT) → texts alone don't qualify; he's saved
  // by recent calls in the call-history test.
  const bob = handle("+15551112222"); const cBob = chat(); link(cBob, bob);
  outbound(cBob, 1, "2026-01-01T12:00:00Z");

  // Stale Steve: 8 outbound but all 3 years ago (> 365d) → excluded (not recent).
  const steve = handle("+15558889999"); const cSt = chat(); link(cSt, steve);
  outbound(cSt, 8, "2023-01-01T12:00:00Z");

  // Unnamed: 6 recent outbound but NOT in the name map → excluded.
  const un = handle("+15550001111"); const cUn = chat(); link(cUn, un);
  outbound(cUn, 6, "2026-03-15T12:00:00Z");

  // Regression: a contact whose NAME ("happy bday") coincides with a wish-phrase
  // message text. The earlier substring body-guard crashed here (the scanned body
  // "happy bday" is a substring of the output's name); the shape-guard does not.
  const weird = handle("+15552223333"); const cW = chat(); link(cW, weird);
  outbound(cW, 5, "2026-03-20T12:00:00Z");
  msg(cW, "happy bday", "2024-08-08T12:00:00Z", true);

  // Target: a SHORTCODE business with plenty of recent outbound (you reply to
  // their texts) and a saved name → must be filtered (handle).
  const target = handle("262966"); const cTg = chat(); link(cTg, target);
  outbound(cTg, 6, "2026-03-10T12:00:00Z");

  // Acme Pharmacy: a named business on an ORDINARY number → must be filtered
  // (name), the One Medical case for the birthday list.
  const pharm = handle("+15554445555"); const cPh = chat(); link(cPh, pharm);
  outbound(cPh, 6, "2026-03-12T12:00:00Z");

  db.close();
}

const nameByCanon = new Map<string, string>([
  ["5553334444", "Eve"],
  ["4045550147", "Allie"],
  ["5557776666", "Dave"],
  ["5551112222", "Bob"],
  ["5558889999", "Stale Steve"],
  ["5552223333", "happy bday"], // name == a wish phrase (regression fixture)
  ["262966", "Target"], // shortcode business (filtered by handle)
  ["5554445555", "Acme Pharmacy"], // named business on an ordinary number (filtered by name)
  // "5550001111" intentionally absent (unnamed).
]);
const savedByCanon = new Map<string, string>([["5557776666", "07-15"]]); // Dave only

function byName(contacts: SeedContact[]): Map<string, SeedContact> {
  return new Map(contacts.map((c) => [c.name, c]));
}

describe("buildSeed", () => {
  test("includes regular contacts (incl. no saved birthday); excludes stale + unnamed + below-threshold", () => {
    buildDb();
    const { available, contacts } = buildSeed(dbPath, nameByCanon, savedByCanon, { nowMs: NOW });
    expect(available).toBe(true);
    const names = new Set(contacts.map((c) => c.name));
    expect(names).toContain("Eve");
    expect(names).toContain("Allie");
    expect(names).toContain("Dave");
    expect(names).not.toContain("Stale Steve"); // last texted ~3y ago
    expect(names).not.toContain("Bob"); // 1 text, no recent call (texts alone)
    expect(contacts.find((c) => c.best_handle === "+15550001111")).toBeUndefined(); // unnamed
    expect(names).not.toContain("Target"); // shortcode business (handle filter)
    expect(names).not.toContain("Acme Pharmacy"); // named business on an ordinary number (name filter)
  });

  test("infers birthday from a past wish when none is saved; skips inference when saved", () => {
    buildDb();
    const m = byName(buildSeed(dbPath, nameByCanon, savedByCanon, { nowMs: NOW }).contacts);
    expect(m.get("Allie")!.saved_birthday).toBeNull();
    expect(m.get("Allie")!.inferred_birthday).toBe("06-04"); // wish date
    expect(m.get("Eve")!.inferred_birthday).toBeNull(); // no wish
    expect(m.get("Dave")!.saved_birthday).toBe("07-15");
    expect(m.get("Dave")!.inferred_birthday).toBeNull(); // saved → no inference
  });

  test("emits dispatchable handle + a reason; no message body leaks into output", () => {
    buildDb();
    const { contacts } = buildSeed(dbPath, nameByCanon, savedByCanon, { nowMs: NOW });
    const allie = byName(contacts).get("Allie")!;
    expect(allie.best_handle).toBe("+14045550147");
    expect(allie.out_count).toBe(6); // 5 plain + 1 wish
    expect(allie.reason).toContain("text");
    // No message body (the wish text) anywhere in the serialized seed.
    expect(JSON.stringify(contacts)).not.toContain("happy birthday");
  });

  test("a recent call qualifies a barely-texted contact", () => {
    buildDb();
    const callDbPath = join(dir, "calls.db");
    const cdb = new Database(callDbPath);
    cdb.exec(`CREATE TABLE ZCALLRECORD (ZADDRESS TEXT, ZDATE REAL);`);
    const recent = Date.parse("2026-05-20T00:00:00Z") / 1000 - CORE;
    for (let i = 0; i < 4; i++) cdb.run(`INSERT INTO ZCALLRECORD VALUES (?, ?)`, ["+15551112222", recent]);
    cdb.close();
    const m = byName(buildSeed(dbPath, nameByCanon, savedByCanon, { nowMs: NOW, callDbPath }).contacts);
    expect(m.get("Bob")).toBeDefined(); // 1 text but 4 recent calls → regular
    expect(m.get("Bob")!.call_count).toBe(4);
  });

  test("muted contacts are excluded even when they meet the threshold", () => {
    buildDb();
    const { contacts } = buildSeed(dbPath, nameByCanon, savedByCanon, {
      nowMs: NOW,
      mutedCanon: new Set(["5553334444"]), // Eve, dismissed
    });
    expect(contacts.find((c) => c.name === "Eve")).toBeUndefined();
    expect(contacts.find((c) => c.name === "Allie")).toBeDefined(); // others unaffected
  });

  test("two distinct people sharing a name both survive (no dedupe-by-name)", () => {
    buildDb();
    const twoSams = new Map<string, string>([
      ["5553334444", "Sam"], // Eve's handle
      ["4045550147", "Sam"], // Allie's handle — same display name, different person
    ]);
    const contacts = buildSeed(dbPath, twoSams, new Map(), { nowMs: NOW }).contacts;
    expect(contacts.filter((c) => c.name === "Sam").length).toBe(2);
  });

  test("does not crash when a contact name coincides with wish-phrase message text", () => {
    buildDb();
    let res!: ReturnType<typeof buildSeed>;
    expect(() => { res = buildSeed(dbPath, nameByCanon, savedByCanon, { nowMs: NOW }); }).not.toThrow();
    const c = byName(res.contacts).get("happy bday");
    expect(c).toBeDefined();
    expect(c!.inferred_birthday).toMatch(/^\d{2}-\d{2}$/); // inferred from the wish, strict shape
  });

  test("graceful degrade when chat.db is unreadable", () => {
    const { available, contacts } = buildSeed(join(dir, "nope.db"), nameByCanon, savedByCanon, { nowMs: NOW });
    expect(available).toBe(false);
    expect(contacts).toEqual([]);
  });
});
