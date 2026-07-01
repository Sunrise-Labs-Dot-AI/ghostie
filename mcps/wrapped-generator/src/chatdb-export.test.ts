import { test, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { rmSync } from "node:fs";
import { appleToMs, normHandle, kindFor, exportChatDb } from "./chatdb-export.ts";

test("appleToMs: nanosecond dates (High Sierra+)", () => {
  // 2025-03-21T17:54:43.790Z ≈ Apple-ns 764272483790000000 region.
  // Exact value cross-checked against the Python apple_to_ms.
  expect(appleToMs(764272483790000000)).toBe(1742579683790);
  expect(appleToMs(0)).toBe(978307200000); // Apple epoch → 2001-01-01 UTC ms
  expect(appleToMs(null)).toBeNull();
});

test("appleToMs: legacy second-based dates", () => {
  // Small magnitude (< 1e12) is treated as seconds since Apple epoch.
  expect(appleToMs(100)).toBe((978307200 + 100) * 1000);
});

test("appleToMs: banker's rounding matches Python round()", () => {
  // Construct a value whose (secs+epoch)*1000 lands exactly on K.5 with K
  // even → Python rounds down (to even), JS Math.round would round up.
  // 0.0005 s after epoch = 0.5 ms → K=978307200000, even → rounds to itself.
  expect(appleToMs(0.0005)).toBe(978307200000);
  // 0.0015 s = 1.5 ms → K=...001 odd → rounds up to ...002.
  expect(appleToMs(0.0015)).toBe(978307200002);
});

test("normHandle: emails lowercase, phones canonicalized", () => {
  expect(normHandle("Foo@Bar.COM")).toBe("foo@bar.com");
  expect(normHandle("+1 (404) 555-0147".replace(/[^\d+]/g, ""))).toBe("+14045550147");
  expect(normHandle("14045550147")).toBe("+14045550147");
  expect(normHandle("shortcode")).toBe("shortcode");
  expect(normHandle(null)).toBeNull();
});

test("kindFor: classification branches", () => {
  expect(kindFor(2000, 0, 0, null, false)).toBe("reaction"); // tapback
  expect(kindFor(3007, 0, 0, null, false)).toBe("reaction"); // removed tapback
  expect(kindFor(null, 1, 0, null, false)).toBe("system"); // group event
  expect(kindFor(null, 0, 1, null, false)).toBe("media"); // attachment
  expect(kindFor(null, 0, 0, 12, false)).toBe("text"); // text column
  expect(kindFor(null, 0, 0, null, true)).toBe("text"); // attributedBody
  expect(kindFor(null, 0, 0, null, false)).toBe("other"); // empty
  // reaction takes precedence over an attachment flag
  expect(kindFor(2001, 0, 1, null, false)).toBe("reaction");
});

test("exportChatDb: end-to-end against an in-memory fixture", () => {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, display_name TEXT, chat_identifier TEXT);
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, handle_id INTEGER, date INTEGER,
      is_from_me INTEGER, item_type INTEGER, associated_message_type INTEGER,
      cache_has_attachments INTEGER, text TEXT, attributedBody BLOB);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    INSERT INTO chat VALUES (1, 'g1', 45, NULL, '+15551112222');     -- 1:1
    INSERT INTO handle VALUES (1, '+15551112222');
    INSERT INTO chat_handle_join VALUES (1, 1);
    INSERT INTO message VALUES (1, 'm1', 1, 700000000000000000, 0, 0, 0, 0, 'hi there', NULL); -- inbound text
    INSERT INTO message VALUES (2, 'm2', NULL, 700000000001000000, 1, 0, 0, 0, 'ok 👍', NULL); -- outbound text w/ emoji
    INSERT INTO message VALUES (3, 'm3', 1, 700000000002000000, 0, 0, 2000, 0, NULL, NULL); -- inbound reaction
    INSERT INTO chat_message_join VALUES (1, 1), (1, 2), (1, 3);
  `);
  // Re-open as the export expects a path; VACUUM to a fresh temp file.
  const tmp = `/tmp/wg-fixture-${process.pid}-${Math.random().toString(36).slice(2)}.db`;
  rmSync(tmp, { force: true });
  db.exec(`VACUUM INTO '${tmp}'`);
  db.close();

  let out;
  try {
    out = exportChatDb({ dbPath: tmp, allTime: true, nowMs: 1779000000000 });
  } finally {
    rmSync(tmp, { force: true });
  }
  expect(out.threads).toHaveLength(1);
  expect(out.threads[0]!.is_group).toBe(false);
  expect(out.threads[0]!.participant_count).toBe(2);
  expect(out.events).toHaveLength(3);
  const byId = Object.fromEntries(out.events.map((e) => [e.event_id, e]));
  expect(byId["imessage:m1"]!.kind).toBe("text");
  expect(byId["imessage:m1"]!.from_me).toBe(false);
  expect(byId["imessage:m1"]!.sender_key).toBe("+15551112222");
  expect(byId["imessage:m1"]!.text_len).toBe(8);
  expect(byId["imessage:m2"]!.from_me).toBe(true);
  expect(byId["imessage:m2"]!.text_len).toBe(4); // "ok 👍" = 4 code points (emoji counts as 1)
  expect(byId["imessage:m3"]!.kind).toBe("reaction");
});
