import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isoUtcToAppleDateNs } from "../../imessage-drafts/src/chatdb/open.ts";
import {
  buildKeepTabsRecommendations,
  buildKeepTabsStatus,
  buildKeepTabsCadence,
  affinityScore,
  lastContactedDays,
  suggestFrequencyDays,
  suggestedCadence,
  FREQ_WEEKLY,
  FREQ_BIWEEKLY,
  FREQ_MONTHLY,
  FREQ_QUARTERLY,
  FREQ_SEMIANNUAL,
  FREQ_YEARLY,
} from "./keeptabs.ts";

let dir: string;
let dbPath: string;
let callDbPath: string;
const NOW = Date.parse("2026-06-01T00:00:00Z");
const CORE = 978_307_200; // Core Data epoch (for the calls DB)

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "keeptabs-"));
  dbPath = join(dir, "chat.db");
  callDbPath = join(dir, "CallHistory.storedata");
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

// Minimal chat.db (mirrors seed.test.ts / signals.test.ts).
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
  const msg = (c: number, iso: string) => {
    db.run(`INSERT INTO message (text, date, is_from_me, associated_message_type, item_type) VALUES (?, ?, 1, 0, 0)`,
      [`m`, isoUtcToAppleDateNs(iso)]);
    const mid = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
    db.run(`INSERT INTO chat_message_join VALUES (?, ?)`, [c, mid]);
  };
  const outbound = (id: string, n: number, iso: string) => {
    const h = handle(id); const c = chat(); link(c, h);
    for (let i = 0; i < n; i++) msg(c, iso);
  };

  outbound("+15551110001", 90, "2026-05-30T12:00:00Z"); // Alice — heavy texter → weekly
  outbound("+15551110002", 35, "2026-05-12T12:00:00Z"); // Bob — moderate, 20d → biweekly
  outbound("+15551110003", 8, "2026-02-20T12:00:00Z"); // Carol — light, 100d → monthly
  outbound("friend@example.com", 7, "2026-05-20T12:00:00Z"); // Email Friend — email = person
  outbound("262966", 5, "2026-05-25T12:00:00Z"); // Target — SHORTCODE (business)
  outbound("+18005551212", 5, "2026-05-25T12:00:00Z"); // My Bank — TOLL-FREE (business)
  outbound("+15551110005", 10, "2026-05-28T12:00:00Z"); // One Medical — named business on an ORDINARY number
  outbound("+15551110007", 12, "2026-05-28T12:00:00Z"); // Tyler Banks — surname look-alike, a real person
  outbound("+15551119999", 6, "2026-05-25T12:00:00Z"); // Unnamed — not in the name map
  db.close();
}

function buildCallDb(rows: Array<{ addr: string; iso: string }>): void {
  const db = new Database(callDbPath);
  db.exec(`CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY, ZADDRESS TEXT, ZDATE REAL);`);
  for (const r of rows) {
    db.run(`INSERT INTO ZCALLRECORD (ZADDRESS, ZDATE) VALUES (?, ?)`, [r.addr, Date.parse(r.iso) / 1000 - CORE]);
  }
  db.close();
}

// canon → name (what readContactsNameMap would return). Unnamed +15551119999 is
// deliberately absent. Businesses ARE named (a user can save a bank/shop) so we
// prove the business filter — not the name guard — is what drops them.
function nameMap(): Map<string, string> {
  return new Map<string, string>([
    ["5551110001", "Alice"],
    ["5551110002", "Bob"],
    ["5551110003", "Carol"],
    ["friend@example.com", "Email Friend"],
    ["5551110004", "Dad"],
    ["262966", "Target"],
    ["8005551212", "My Bank"],
    ["5551110005", "One Medical"], // named business, ordinary number — name catches it
    ["5551110007", "Tyler Banks"], // 'Banks' ≠ 'bank' — must NOT be filtered
  ]);
}

describe("buildKeepTabsRecommendations", () => {
  test("ranks by combined text+call affinity, names resolved", () => {
    buildDb();
    buildCallDb(Array.from({ length: 20 }, () => ({ addr: "+15551110004", iso: "2026-05-29T10:00:00Z" }))); // Dad: 20 calls, 3d ago
    const r = buildKeepTabsRecommendations(dbPath, nameMap(), { nowMs: NOW, callDbPath });
    expect(r.available).toBe(true);
    const order = r.recommendations.map((x) => x.name);
    // Alice 90, Dad 60 (20*3), Bob 35, Tyler Banks 12, Carol 8, Email Friend 7.
    // One Medical (10) is dropped by the name filter despite its ordinary number.
    expect(order).toEqual(["Alice", "Dad", "Bob", "Tyler Banks", "Carol", "Email Friend"]);
    const dad = r.recommendations.find((x) => x.name === "Dad")!;
    expect(dad.out_count).toBe(0);
    expect(dad.call_count).toBe(20);
    expect(dad.last_call_days).toBe(2); // 2026-05-29T10:00 → NOW 2026-06-01T00:00 = 2.6d, floored
    expect(dad.last_texted_days).toBeNull();
  });

  test("filters out businesses by handle AND name; keeps people (incl. surname look-alikes)", () => {
    buildDb();
    const names = buildKeepTabsRecommendations(dbPath, nameMap(), { nowMs: NOW }).recommendations.map((x) => x.name);
    expect(names).not.toContain("Target"); // shortcode 262966 (handle)
    expect(names).not.toContain("My Bank"); // toll-free 800 (handle)
    expect(names).not.toContain("One Medical"); // ordinary number, but the NAME catches it
    expect(names).toContain("Tyler Banks"); // 'Banks' ≠ 'bank' — real person, kept
    expect(names).toContain("Email Friend"); // email handle = person, retained
    expect(names).toContain("Alice"); // plain phone = person, retained
  });

  test("excludes unnamed handles (a watchlist needs a person)", () => {
    buildDb();
    const r = buildKeepTabsRecommendations(dbPath, nameMap(), { nowMs: NOW });
    expect(r.recommendations.every((x) => x.best_handle !== "+15551119999")).toBe(true);
  });

  test("excludeCanon drops already-watched people", () => {
    buildDb();
    const r = buildKeepTabsRecommendations(dbPath, nameMap(), {
      nowMs: NOW,
      excludeCanon: new Set(["5551110001"]), // Alice already watched
    });
    expect(r.recommendations.map((x) => x.name)).not.toContain("Alice");
    expect(r.recommendations[0]!.name).toBe("Bob"); // Bob now leads (no call DB)
  });

  test("suggested frequency reflects volume + recency", () => {
    buildDb();
    buildCallDb(Array.from({ length: 20 }, () => ({ addr: "+15551110004", iso: "2026-05-29T10:00:00Z" })));
    const r = buildKeepTabsRecommendations(dbPath, nameMap(), { nowMs: NOW, callDbPath });
    const by = (n: string) => r.recommendations.find((x) => x.name === n)!;
    expect(by("Alice").suggested_frequency_days).toBe(FREQ_WEEKLY); // 90 texts, texted 1d ago (warm)
    expect(by("Dad").suggested_frequency_days).toBe(FREQ_WEEKLY); // called 2d ago ≤ 10 (warm)
    expect(by("Bob").suggested_frequency_days).toBe(FREQ_BIWEEKLY); // 35 texts, 20d ago (warm grace)
    expect(by("Carol").suggested_frequency_days).toBe(FREQ_QUARTERLY); // 100d silent → lapsed, tempered loose
  });

  test("suggested frequency defaults to the median message gap with that person", () => {
    // A contact texted every 5 days → suggested cadence ≈ 5d (the median gap),
    // NOT the coarse volume bucket.
    const db = new Database(dbPath);
    db.exec(`
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    `);
    db.run(`INSERT INTO handle (id, service) VALUES ('+15559990000', 'iMessage')`);
    db.run(`INSERT INTO chat (guid) VALUES ('g0')`);
    db.run(`INSERT INTO chat_handle_join VALUES (1, 1)`);
    for (let i = 0; i < 12; i++) {
      const iso = new Date(NOW - i * 5 * 86_400_000).toISOString(); // every 5 days
      db.run(`INSERT INTO message (text, date, is_from_me, associated_message_type, item_type) VALUES ('m', ?, ?, 0, 0)`,
        [isoUtcToAppleDateNs(iso), i % 2]);
      db.run(`INSERT INTO chat_message_join VALUES (1, ?)`, [i + 1]);
    }
    db.close();

    const r = buildKeepTabsRecommendations(dbPath, new Map([["5559990000", "Median Mike"]]), { nowMs: NOW });
    const mike = r.recommendations.find((x) => x.name === "Median Mike")!;
    expect(mike.suggested_frequency_days).toBe(5);
  });

  test("median uses distinct conversation DAYS, not sub-day message bursts", () => {
    // 4 conversation days a week apart, with a 5-message burst each day. The
    // cadence is weekly (~7d), NOT ~0d — guards the message-vs-day-gap bug.
    const db = new Database(dbPath);
    db.exec(`
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    `);
    db.run(`INSERT INTO handle (id, service) VALUES ('+15558880000', 'iMessage')`);
    db.run(`INSERT INTO chat (guid) VALUES ('g0')`);
    db.run(`INSERT INTO chat_handle_join VALUES (1, 1)`);
    let mid = 0;
    const base = Date.parse("2026-05-30T12:00:00Z"); // midday so a burst can't cross a UTC day boundary
    for (let day = 0; day < 4; day++) {
      for (let burst = 0; burst < 5; burst++) {
        const iso = new Date(base - day * 7 * 86_400_000 + burst * 600_000).toISOString(); // 7d apart, 10-min bursts
        db.run(`INSERT INTO message (text, date, is_from_me, associated_message_type, item_type) VALUES ('m', ?, ?, 0, 0)`,
          [isoUtcToAppleDateNs(iso), (day + burst) % 2]);
        db.run(`INSERT INTO chat_message_join VALUES (1, ?)`, [++mid]);
      }
    }
    db.close();

    const r = buildKeepTabsRecommendations(dbPath, new Map([["5558880000", "Burst Betty"]]), { nowMs: NOW });
    expect(r.recommendations.find((x) => x.name === "Burst Betty")!.suggested_frequency_days).toBe(7);
  });

  test("folds call/FaceTime days into cadence for a call-only contact", () => {
    buildDb(); // text contacts (no Carl)
    const base = Date.parse("2026-05-30T12:00:00Z");
    buildCallDb(Array.from({ length: 6 }, (_, i) => ({ addr: "+15551112345", iso: new Date(base - i * 14 * 86_400_000).toISOString() }))); // called every 14d
    const names = nameMap();
    names.set("5551112345", "Call Carl");
    const r = buildKeepTabsRecommendations(dbPath, names, { nowMs: NOW, callDbPath });
    const carl = r.recommendations.find((x) => x.name === "Call Carl")!;
    expect(carl.out_count).toBe(0);
    expect(carl.call_count).toBe(6);
    expect(carl.suggested_frequency_days).toBe(14); // cadence from calls alone
  });

  test("respects --limit", () => {
    buildDb();
    const r = buildKeepTabsRecommendations(dbPath, nameMap(), { nowMs: NOW, limit: 2 });
    expect(r.recommendations).toHaveLength(2);
    expect(r.recommendations.map((x) => x.name)).toEqual(["Alice", "Bob"]);
  });

  test("unreadable chat.db → available:false, graceful", () => {
    const r = buildKeepTabsRecommendations(join(dir, "nope.db"), nameMap(), { nowMs: NOW });
    expect(r.available).toBe(false);
    expect(r.recommendations).toEqual([]);
  });
});

describe("buildKeepTabsStatus", () => {
  test("reports live last-texted / last-called for watched canons, calls credited", () => {
    buildDb();
    buildCallDb(Array.from({ length: 5 }, () => ({ addr: "+15551110004", iso: "2026-05-29T10:00:00Z" }))); // Dad: call 2d ago
    const r = buildKeepTabsStatus(dbPath, ["5551110001", "5551110004"], { nowMs: NOW, callDbPath });
    expect(r.available).toBe(true);
    const alice = r.statuses.find((s) => s.canon === "5551110001")!;
    expect(alice.last_texted_days).toBe(1); // texted 2026-05-30T12:00 → NOW 2026-06-01T00:00 = 1.5d, floored
    expect(alice.thread_id).not.toBeNull(); // has an iMessage thread to prioritize
    const dad = r.statuses.find((s) => s.canon === "5551110004")!;
    expect(dad.last_texted_days).toBeNull(); // call-only
    expect(dad.last_call_days).toBe(2);
    expect(dad.thread_id).toBeNull(); // call-only → no thread to prioritize
  });

  test("never-contacted watched canon comes back with nulls (treated as quiet)", () => {
    buildDb();
    const r = buildKeepTabsStatus(dbPath, ["9999999999"], { nowMs: NOW });
    expect(r.available).toBe(true);
    expect(r.statuses).toEqual([{ canon: "9999999999", thread_id: null, last_texted_days: null, last_call_days: null }]);
  });

  test("empty canon list short-circuits to available:true / empty", () => {
    const r = buildKeepTabsStatus(join(dir, "nope.db"), [], { nowMs: NOW });
    expect(r).toEqual({ available: true, statuses: [] });
  });

  test("unreadable chat.db → available:false", () => {
    const r = buildKeepTabsStatus(join(dir, "nope.db"), ["5551110001"], { nowMs: NOW });
    expect(r.available).toBe(false);
    expect(r.statuses).toEqual([]);
  });
});

describe("buildKeepTabsCadence", () => {
  test("returns the median text+call cadence for an ARBITRARY canon (manual-add picker default)", () => {
    // A contact texted every 5 days who is NOT in the affinity-ranked recommend
    // list (no name map needed) — the manual-add flow still gets their rhythm.
    const db = new Database(dbPath);
    db.exec(`
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    `);
    db.run(`INSERT INTO handle (id, service) VALUES ('+15559990000', 'iMessage')`);
    db.run(`INSERT INTO chat (guid) VALUES ('g0')`);
    db.run(`INSERT INTO chat_handle_join VALUES (1, 1)`);
    for (let i = 0; i < 12; i++) {
      const iso = new Date(NOW - i * 5 * 86_400_000).toISOString(); // every 5 days
      db.run(`INSERT INTO message (text, date, is_from_me, associated_message_type, item_type) VALUES ('m', ?, ?, 0, 0)`,
        [isoUtcToAppleDateNs(iso), i % 2]);
      db.run(`INSERT INTO chat_message_join VALUES (1, ?)`, [i + 1]);
    }
    db.close();

    const r = buildKeepTabsCadence(dbPath, ["5559990000"], { nowMs: NOW });
    expect(r.available).toBe(true);
    // Texted through today (L=0) → warm → keeps the precise 5-day rhythm.
    expect(r.cadences).toEqual([{ canon: "5559990000", suggested_frequency_days: 5, last_contacted_days: 0 }]);
  });

  test("folds call/FaceTime days into the cadence for a call-only canon", () => {
    buildDb();
    const base = Date.parse("2026-05-30T12:00:00Z");
    buildCallDb(Array.from({ length: 6 }, (_, i) => ({ addr: "+15551112345", iso: new Date(base - i * 14 * 86_400_000).toISOString() }))); // every 14d, last ~1d ago (warm)
    const r = buildKeepTabsCadence(dbPath, ["5551112345"], { nowMs: NOW, callDbPath });
    expect(r.cadences[0]).toEqual({ canon: "5551112345", suggested_frequency_days: 14, last_contacted_days: 1 });
  });

  test("a once-active contact who went quiet for MONTHS is tempered loose, not its stale rhythm", () => {
    // The Frank Wang bug: texted every 4 days during a burst that ENDED ~168 days
    // ago. The raw median is ~4, but the go-forward suggestion must be quarterly.
    const db = new Database(dbPath);
    db.exec(`
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    `);
    db.run(`INSERT INTO handle (id, service) VALUES ('+15557770000', 'iMessage')`);
    db.run(`INSERT INTO chat (guid) VALUES ('g0')`);
    db.run(`INSERT INTO chat_handle_join VALUES (1, 1)`);
    const lastBurst = NOW - 168 * 86_400_000; // burst ended 168 days ago
    for (let i = 0; i < 20; i++) {
      const iso = new Date(lastBurst - i * 4 * 86_400_000).toISOString(); // every 4 days, all old
      db.run(`INSERT INTO message (text, date, is_from_me, associated_message_type, item_type) VALUES ('m', ?, ?, 0, 0)`,
        [isoUtcToAppleDateNs(iso), i % 2]);
      db.run(`INSERT INTO chat_message_join VALUES (1, ?)`, [i + 1]);
    }
    db.close();

    const c = buildKeepTabsCadence(dbPath, ["5557770000"], { nowMs: NOW }).cadences[0]!;
    expect(c.last_contacted_days).toBe(168);
    expect(c.suggested_frequency_days).toBe(FREQ_QUARTERLY); // NOT ~4
  });

  test("falls back to a recency-tempered bucket when there's too little history for a median", () => {
    buildDb(); // Carol: 8 texts all at one instant (no median) AND 100d silent → lapsed
    const r = buildKeepTabsCadence(dbPath, ["5551110003"], { nowMs: NOW });
    expect(r.cadences[0]!.canon).toBe("5551110003");
    expect(r.cadences[0]!.last_contacted_days).toBe(100);
    expect(r.cadences[0]!.suggested_frequency_days).toBe(FREQ_QUARTERLY); // light + 100d quiet → quarterly
  });

  test("empty canon list short-circuits to available:true / empty", () => {
    const r = buildKeepTabsCadence(join(dir, "nope.db"), [], { nowMs: NOW });
    expect(r).toEqual({ available: true, cadences: [] });
  });

  test("unreadable chat.db → available:false", () => {
    const r = buildKeepTabsCadence(join(dir, "nope.db"), ["5551110001"], { nowMs: NOW });
    expect(r.available).toBe(false);
    expect(r.cadences).toEqual([]);
  });
});

describe("suggestedCadence (recency tempering)", () => {
  // Representative anchors: (median, lastContacted, out, calls).
  // WARM (last contact within 3× rhythm OR ≤21d) keeps the precise median;
  // LAPSED buckets on absolute silence and never goes tighter than the silence.
  test("keeps the precise rhythm for active contacts (warm)", () => {
    expect(suggestedCadence(1, 0, 10829, 156)).toBe(1); // Dana, texted today
    expect(suggestedCadence(5, 5, 426, 49)).toBe(5); // Dad, called 5d ago
    expect(suggestedCadence(2, 7, 1286, 7)).toBe(2); // Tyler, tight rhythm, 7d (absolute grace)
    expect(suggestedCadence(4, 10, 436, 22)).toBe(4); // Chelsea
    expect(suggestedCadence(5, 12, 205, 0)).toBe(5); // Amber
    expect(suggestedCadence(11, 33, 126, 0)).toBe(11); // Azita, slow rhythm on schedule (relative gate)
  });

  test("loosens lapsed contacts toward the silence (monthly/quarterly), monotonic", () => {
    expect(suggestedCadence(7, 36, 199, 4)).toBe(FREQ_BIWEEKLY); // Erin, ~1mo quiet
    expect(suggestedCadence(8, 45, 432, 9)).toBe(FREQ_BIWEEKLY); // JB, ~6wk quiet
    expect(suggestedCadence(6, 78, 220, 5)).toBe(FREQ_MONTHLY); // Matt, ~2.5mo quiet
    expect(suggestedCadence(4, 168, 87, 0)).toBe(FREQ_QUARTERLY); // Frank, ~5.6mo — the bug
    expect(suggestedCadence(2, 612, 134, 0)).toBe(FREQ_YEARLY); // Ben, ~20mo → once a year
    expect(suggestedCadence(5, 200, 50, 0)).toBe(FREQ_SEMIANNUAL); // ~6.5mo quiet → twice a year
  });

  test("a slow-rhythm contact stays warm through proportionally longer gaps (relative gate)", () => {
    // 60-day rhythm, 70d quiet: 70 ≤ 3×60, so still 'keeping it' → keep 60, not bucketed.
    expect(suggestedCadence(60, 70, 50, 0)).toBe(60);
    // Same rhythm, but now well past 3× → lapsed, loosens toward the silence.
    expect(suggestedCadence(60, 200, 50, 0)).toBe(FREQ_SEMIANNUAL);
  });

  test("smooths the warm-grace cliff: a near-daily friend gone ~3 weeks → weekly, not biweekly", () => {
    expect(suggestedCadence(1, 24, 100, 0)).toBe(FREQ_WEEKLY); // lapsed but ≤30d → 7, gentle 3→7
    expect(suggestedCadence(1, 21, 100, 0)).toBe(1); // still warm at exactly 21d
  });

  test("never-contacted (null lastContacted) defaults loose", () => {
    expect(suggestedCadence(null, null, 0, 0)).toBe(FREQ_QUARTERLY); // brand-new contact
    expect(suggestedCadence(5, null, 100, 0)).toBe(FREQ_QUARTERLY); // a rhythm but no recorded contact
  });

  test("median=null reuses the volume/recency bucket as the rhythm, then tempers", () => {
    expect(suggestedCadence(null, 3, 200, 0)).toBe(FREQ_WEEKLY); // high volume + recent → weekly, warm
    expect(suggestedCadence(null, 100, 8, 0)).toBe(FREQ_QUARTERLY); // light + 100d quiet → lapsed
  });

  test("call-only rhythm (median from calls) is tempered the same way", () => {
    expect(suggestedCadence(14, 2, 0, 6)).toBe(14); // called every 14d, last 2d ago → warm
    expect(suggestedCadence(14, 200, 0, 6)).toBe(FREQ_SEMIANNUAL); // same rhythm, gone 200d → lapsed
  });

  test("caps sparse-thread median noise at yearly", () => {
    expect(suggestedCadence(798, 50, 134, 0)).toBe(FREQ_YEARLY); // absurd 798d 'rhythm' → 365
  });
});

describe("pure helpers", () => {
  test("affinityScore weights calls 3x", () => {
    expect(affinityScore(10, 0)).toBe(10);
    expect(affinityScore(0, 10)).toBe(30);
    expect(affinityScore(5, 2)).toBe(11);
  });

  test("lastContactedDays takes the more-recent axis, null = absent", () => {
    expect(lastContactedDays(10, 3)).toBe(3);
    expect(lastContactedDays(null, 3)).toBe(3);
    expect(lastContactedDays(10, null)).toBe(10);
    expect(lastContactedDays(null, null)).toBeNull();
  });

  test("suggestFrequencyDays bucket boundaries", () => {
    expect(suggestFrequencyDays(80, 0, 999, 999)).toBe(FREQ_WEEKLY); // score 80
    expect(suggestFrequencyDays(0, 0, 10, null)).toBe(FREQ_WEEKLY); // texted 10d ago
    expect(suggestFrequencyDays(30, 0, 999, 999)).toBe(FREQ_BIWEEKLY); // score 30
    expect(suggestFrequencyDays(0, 0, 25, null)).toBe(FREQ_BIWEEKLY); // texted 25d ago
    expect(suggestFrequencyDays(10, 0, 100, null)).toBe(FREQ_MONTHLY); // weak + stale
    expect(suggestFrequencyDays(0, 0, null, null)).toBe(FREQ_MONTHLY); // no signal
  });
});
