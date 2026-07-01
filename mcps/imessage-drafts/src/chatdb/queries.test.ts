import { describe, test, expect, beforeEach, afterAll } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { _setChatDbForTesting, isoUtcToAppleDateNs } from "./open.ts";
import {
  _setContactsForTesting,
  _resetContactsCache,
  findHandlesByContactName,
  resolveHandle,
  getLastContactsLoadSource,
} from "./contacts.ts";
import {
  _setSidecarPathForTesting,
  CONTACTS_CACHE_SCHEMA_VERSION,
} from "../storage/contacts-cache.ts";
import {
  listThreads,
  getThreadMessages,
  searchMessages,
  classifyAttachmentKind,
  _resetChatHandlesCacheForTesting,
  _resetAttachmentColumnCacheForTesting,
  resolveDirectChat,
} from "./queries.ts";

// ─── fixture builder ────────────────────────────────────────────────────────
// Minimal chat.db schema covering only the columns these queries touch.
// chat.db has many more columns in real life — recreating them all would
// add noise without changing test behavior.
function buildChatDb(): Database {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      guid TEXT,
      display_name TEXT,
      style INTEGER
    );
    CREATE TABLE handle (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      id TEXT,
      service TEXT
    );
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      guid TEXT,
      text TEXT,
      attributedBody BLOB,
      date INTEGER,
      is_from_me INTEGER DEFAULT 0,
      is_read INTEGER DEFAULT 0,
      cache_has_attachments INTEGER DEFAULT 0,
      handle_id INTEGER,
      thread_originator_guid TEXT
    );
    CREATE TABLE chat_message_join (
      chat_id INTEGER,
      message_id INTEGER,
      message_date INTEGER
    );
    CREATE TABLE chat_handle_join (
      chat_id INTEGER,
      handle_id INTEGER
    );
    CREATE TABLE attachment (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      filename TEXT,
      uti TEXT,
      mime_type TEXT,
      transfer_name TEXT,
      total_bytes INTEGER,
      is_sticker INTEGER DEFAULT 0,
      hide_attachment INTEGER DEFAULT 0
    );
    CREATE TABLE message_attachment_join (
      message_id INTEGER,
      attachment_id INTEGER
    );
  `);
  return db;
}

// Attach a file to a message. Mirrors how Messages records attachments:
// a row in `attachment` plus a join row. Returns the attachment ROWID.
function insertAttachment(
  db: Database,
  opts: {
    message_id: number;
    filename?: string | null;
    mime_type?: string | null;
    transfer_name?: string | null;
    total_bytes?: number | null;
    uti?: string | null;
    is_sticker?: boolean;
    hide_attachment?: boolean;
  }
): number {
  db.run(
    `INSERT INTO attachment (filename, uti, mime_type, transfer_name, total_bytes, is_sticker, hide_attachment) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [
      opts.filename ?? null,
      opts.uti ?? null,
      opts.mime_type ?? null,
      opts.transfer_name ?? null,
      opts.total_bytes ?? null,
      opts.is_sticker ? 1 : 0,
      opts.hide_attachment ? 1 : 0,
    ]
  );
  const att_id = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  db.run(`INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)`, [opts.message_id, att_id]);
  return att_id;
}

function nsAt(iso: string): bigint {
  return isoUtcToAppleDateNs(iso);
}

// Helpers for inserting rows. Each returns its ROWID for joining.
function insertChat(db: Database, opts: { guid: string; display_name?: string | null; style?: number }): number {
  db.run(`INSERT INTO chat (guid, display_name, style) VALUES (?, ?, ?)`, [
    opts.guid,
    opts.display_name ?? null,
    opts.style ?? 45,
  ]);
  return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
}

function insertHandle(db: Database, opts: { id: string; service?: string }): number {
  db.run(`INSERT INTO handle (id, service) VALUES (?, ?)`, [opts.id, opts.service ?? "iMessage"]);
  return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
}

function linkChatHandle(db: Database, chat_id: number, handle_id: number): void {
  db.run(`INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)`, [chat_id, handle_id]);
}

let guidCounter = 0;

function insertMessage(
  db: Database,
  opts: {
    chat_id: number;
    text: string | null;
    attributedBody?: Uint8Array | null;
    date_iso: string;
    is_from_me?: boolean;
    handle_id?: number | null;
    // Real chat.db rows always carry a `guid`; auto-generated here when the
    // test doesn't care. Pass an explicit `guid` to make a message a reply
    // target, and `thread_originator_guid` to mark a message as a reply.
    guid?: string;
    thread_originator_guid?: string | null;
    cache_has_attachments?: boolean;
  }
): number {
  const guid = opts.guid ?? `fixture-guid-${++guidCounter}`;
  db.run(
    `INSERT INTO message (guid, text, attributedBody, date, is_from_me, handle_id, thread_originator_guid, cache_has_attachments) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      guid,
      opts.text,
      opts.attributedBody ?? null,
      nsAt(opts.date_iso),
      opts.is_from_me ? 1 : 0,
      opts.handle_id ?? null,
      opts.thread_originator_guid ?? null,
      opts.cache_has_attachments ? 1 : 0,
    ]
  );
  const msg_id = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  db.run(`INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)`, [
    opts.chat_id,
    msg_id,
    nsAt(opts.date_iso),
  ]);
  return msg_id;
}

// Build a small typedstream attributedBody blob carrying `text` — same
// shape as decode.test.ts's helper, kept local so this fixture file is
// self-contained.
function buildAttributedBody(text: string): Buffer {
  const utf8 = Buffer.from(text, "utf8");
  if (utf8.length >= 0x80) throw new Error("fixture only handles short strings");
  return Buffer.concat([
    Buffer.from("streamtyped\x00", "binary"),
    Buffer.from("NSString", "utf8"),
    Buffer.from([0x86, 0x84, 0x40, 0x40]),
    Buffer.from([0x01, 0x2b]),
    Buffer.from([utf8.length]),
    utf8,
  ]);
}

// ─── tests ──────────────────────────────────────────────────────────────────

let db: Database;

beforeEach(() => {
  db = buildChatDb();
  _setChatDbForTesting(db);
  _resetChatHandlesCacheForTesting();
  _resetAttachmentColumnCacheForTesting();
  _resetContactsCache();
});

describe("listThreads", () => {
  test("returns threads newest-first with last_message_at / preview", () => {
    const h1 = insertHandle(db, { id: "+14155551111" });
    const h2 = insertHandle(db, { id: "+14155552222" });
    const c1 = insertChat(db, { guid: "c1" });
    const c2 = insertChat(db, { guid: "c2" });
    linkChatHandle(db, c1, h1);
    linkChatHandle(db, c2, h2);
    insertMessage(db, { chat_id: c1, text: "hello from c1", date_iso: "2026-05-10T12:00:00Z", handle_id: h1 });
    insertMessage(db, { chat_id: c2, text: "hello from c2", date_iso: "2026-05-12T12:00:00Z", handle_id: h2 });

    const r = listThreads({ limit: 10, sinceIso: "2026-05-01T00:00:00Z" });
    expect(r.threads.length).toBe(2);
    expect(r.threads[0]!.thread_id).toBe(c2);
    expect(r.threads[0]!.last_message_preview).toBe("hello from c2");
    expect(r.threads[1]!.thread_id).toBe(c1);
    expect(r.oldest_at).toBe(r.threads[1]!.last_message_at);
    expect(r.has_more).toBe(false);
  });

  test("respects `before` cursor strictly less than (no boundary duplication)", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c1 = insertChat(db, { guid: "c1" });
    const c2 = insertChat(db, { guid: "c2" });
    const c3 = insertChat(db, { guid: "c3" });
    linkChatHandle(db, c1, h);
    linkChatHandle(db, c2, h);
    linkChatHandle(db, c3, h);
    insertMessage(db, { chat_id: c1, text: "old", date_iso: "2026-05-10T12:00:00Z", handle_id: h });
    insertMessage(db, { chat_id: c2, text: "mid", date_iso: "2026-05-11T12:00:00Z", handle_id: h });
    insertMessage(db, { chat_id: c3, text: "new", date_iso: "2026-05-12T12:00:00Z", handle_id: h });

    // Page 1: limit 2, newest first.
    const page1 = listThreads({ limit: 2, sinceIso: "2026-05-01T00:00:00Z" });
    expect(page1.threads.map((t) => t.thread_id)).toEqual([c3, c2]);
    expect(page1.has_more).toBe(true);
    expect(page1.oldest_at).toBe("2026-05-11T12:00:00.000Z");

    // Page 2 using oldest_at as the `before` cursor. c2 must NOT reappear.
    const page2 = listThreads({ limit: 2, sinceIso: "2026-05-01T00:00:00Z", beforeIso: page1.oldest_at! });
    expect(page2.threads.map((t) => t.thread_id)).toEqual([c1]);
    expect(page2.has_more).toBe(false);
  });

  test("contact_filter matches resolved Contact name even when raw handle differs (the Fairfax fix)", () => {
    const h_fairfax = insertHandle(db, { id: "+14045550147" });
    const h_other = insertHandle(db, { id: "+14155551234" });
    const c_fairfax = insertChat(db, { guid: "c_fairfax" });
    const c_other = insertChat(db, { guid: "c_other" });
    linkChatHandle(db, c_fairfax, h_fairfax);
    linkChatHandle(db, c_other, h_other);
    insertMessage(db, { chat_id: c_fairfax, text: "hey", date_iso: "2026-05-12T12:00:00Z", handle_id: h_fairfax });
    insertMessage(db, { chat_id: c_other, text: "yo", date_iso: "2026-05-12T11:00:00Z", handle_id: h_other });

    // Inject contacts so the name->handles index has "fairfax sample" -> ["4045550147"].
    _setContactsForTesting(
      new Map([["4045550147", "Fairfax Sample"]]),
      [{ lower_name: "fairfax sample", handles: ["4045550147"] }]
    );

    const r = listThreads({ limit: 10, contactFilter: "Fairfax" });
    expect(r.threads.length).toBe(1);
    expect(r.threads[0]!.thread_id).toBe(c_fairfax);
    expect(r.threads[0]!.participants[0]!.name).toBe("Fairfax Sample");
  });

  test("contact_filter still matches raw handle substring when no Contact match", () => {
    const h = insertHandle(db, { id: "+14155551234" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, { chat_id: c, text: "hi", date_iso: "2026-05-12T12:00:00Z", handle_id: h });

    _setContactsForTesting(new Map(), []); // no contacts known
    const r = listThreads({ limit: 10, contactFilter: "415555" });
    expect(r.threads.length).toBe(1);
    expect(r.threads[0]!.thread_id).toBe(c);
  });
});

describe("getThreadMessages", () => {
  test("returns messages newest-first; decodes attributedBody when text is null", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, { chat_id: c, text: "first", date_iso: "2026-05-10T12:00:00Z", handle_id: h });
    insertMessage(db, {
      chat_id: c,
      text: null,
      attributedBody: buildAttributedBody("from blob"),
      date_iso: "2026-05-11T12:00:00Z",
      handle_id: h,
    });

    const rows = getThreadMessages({ threadId: c, limit: 10 });
    expect(rows.length).toBe(2);
    expect(rows[0]!.body).toBe("from blob");
    expect(rows[1]!.body).toBe("first");
  });

  test("populates reply_to with the originator's body + sender for an inline reply", () => {
    const them = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, them);
    insertMessage(db, {
      chat_id: c,
      text: "what time works?",
      date_iso: "2026-05-10T12:00:00Z",
      handle_id: them,
      guid: "orig-guid-1",
    });
    insertMessage(db, {
      chat_id: c,
      text: "3pm",
      date_iso: "2026-05-10T12:05:00Z",
      is_from_me: true,
      thread_originator_guid: "orig-guid-1",
    });

    const rows = getThreadMessages({ threadId: c, limit: 10 });
    // newest-first → the reply is rows[0], the originator rows[1].
    expect(rows[0]!.body).toBe("3pm");
    expect(rows[0]!.reply_to).not.toBeNull();
    expect(rows[0]!.reply_to!.guid).toBe("orig-guid-1");
    expect(rows[0]!.reply_to!.body).toBe("what time works?");
    expect(rows[0]!.reply_to!.from_me).toBe(false);
    expect(rows[0]!.reply_to!.sender.handle).toBe("+14155551111");
    expect(rows[1]!.reply_to).toBeNull();
  });

  test("reply_to is a guid-only stub (body null) when the originator isn't in chat.db", () => {
    const them = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, them);
    insertMessage(db, {
      chat_id: c,
      text: "later reply",
      date_iso: "2026-05-10T12:05:00Z",
      handle_id: them,
      thread_originator_guid: "missing-orig-guid",
    });

    const rows = getThreadMessages({ threadId: c, limit: 10 });
    expect(rows[0]!.reply_to).not.toBeNull();
    expect(rows[0]!.reply_to!.guid).toBe("missing-orig-guid");
    expect(rows[0]!.reply_to!.body).toBeNull();
  });
});

describe("getThreadMessages — attachments", () => {
  test("surfaces per-attachment metadata + coarse kind for media messages", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    const m = insertMessage(db, {
      chat_id: c,
      text: "look at this",
      date_iso: "2026-05-10T12:00:00Z",
      handle_id: h,
      cache_has_attachments: true,
    });
    insertAttachment(db, {
      message_id: m,
      filename: "~/Library/Messages/Attachments/ab/01/IMG_0001.HEIC",
      mime_type: "image/heic",
      transfer_name: "IMG_0001.HEIC",
      total_bytes: 482910,
      uti: "public.heic",
    });

    const rows = getThreadMessages({ threadId: c, limit: 10 });
    expect(rows.length).toBe(1);
    expect(rows[0]!.has_attachments).toBe(true);
    expect(rows[0]!.attachments.length).toBe(1);
    const att = rows[0]!.attachments[0]!;
    expect(att.filename).toBe("IMG_0001.HEIC");
    expect(att.path).toBe("~/Library/Messages/Attachments/ab/01/IMG_0001.HEIC");
    expect(att.mime_type).toBe("image/heic");
    expect(att.total_bytes).toBe(482910);
    expect(att.kind).toBe("image");
  });

  test("returns multiple attachments in join order; empty array for text-only messages", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, { chat_id: c, text: "no media", date_iso: "2026-05-10T12:00:00Z", handle_id: h });
    const m = insertMessage(db, {
      chat_id: c,
      text: null,
      date_iso: "2026-05-10T12:01:00Z",
      handle_id: h,
      cache_has_attachments: true,
    });
    insertAttachment(db, { message_id: m, transfer_name: "clip.mov", mime_type: "video/quicktime", total_bytes: 10 });
    insertAttachment(db, { message_id: m, transfer_name: "notes.pdf", mime_type: "application/pdf", total_bytes: 20 });

    const rows = getThreadMessages({ threadId: c, limit: 10 });
    // newest-first → media message is rows[0]
    expect(rows[0]!.attachments.map((a) => a.kind)).toEqual(["video", "document"]);
    expect(rows[1]!.attachments).toEqual([]);
  });

  test("hidden attachments are excluded", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    const m = insertMessage(db, {
      chat_id: c,
      text: "hi",
      date_iso: "2026-05-10T12:00:00Z",
      handle_id: h,
      cache_has_attachments: true,
    });
    insertAttachment(db, { message_id: m, transfer_name: "secret.png", mime_type: "image/png", hide_attachment: true });

    const rows = getThreadMessages({ threadId: c, limit: 10 });
    expect(rows[0]!.attachments).toEqual([]);
  });

  test("classifyAttachmentKind falls back to uti then extension when mime is absent", () => {
    expect(classifyAttachmentKind(null, "com.apple.sticker", "x")).toBe("image");
    expect(classifyAttachmentKind(null, null, "clip.MP4")).toBe("video");
    expect(classifyAttachmentKind(null, null, "voice.m4a")).toBe("audio");
    expect(classifyAttachmentKind(null, null, "resume.docx")).toBe("document");
    expect(classifyAttachmentKind(null, null, null)).toBe("other");
  });
});

describe("searchMessages — attributedBody decode (Fix 3)", () => {
  test("matches inside attributedBody when text column is null", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, {
      chat_id: c,
      text: null,
      attributedBody: buildAttributedBody("thanks my dude"),
      date_iso: "2026-05-12T12:00:00Z",
      handle_id: h,
    });

    const hits = searchMessages({ query: "thanks", limit: 10, sinceIso: "2026-05-01T00:00:00Z" });
    expect(hits.length).toBe(1);
    expect(hits[0]!.body).toBe("thanks my dude");
  });

  test("does not match when neither text nor attributedBody contains the query", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, {
      chat_id: c,
      text: "no thanks here",
      date_iso: "2026-05-12T12:00:00Z",
      handle_id: h,
    });

    const hits = searchMessages({ query: "zzznomatch", limit: 10, sinceIso: "2026-05-01T00:00:00Z" });
    expect(hits.length).toBe(0);
  });

  test("contact_filter on search widens through resolved names", () => {
    const h_c = insertHandle(db, { id: "+14045550147" });
    const h_o = insertHandle(db, { id: "+14155551234" });
    const chat_c = insertChat(db, { guid: "c_c" });
    const chat_o = insertChat(db, { guid: "c_o" });
    linkChatHandle(db, chat_c, h_c);
    linkChatHandle(db, chat_o, h_o);
    insertMessage(db, { chat_id: chat_c, text: "thanks", date_iso: "2026-05-12T12:00:00Z", handle_id: h_c });
    insertMessage(db, { chat_id: chat_o, text: "thanks", date_iso: "2026-05-12T12:00:00Z", handle_id: h_o });

    _setContactsForTesting(
      new Map([["4045550147", "Fairfax Sample"]]),
      [{ lower_name: "fairfax sample", handles: ["4045550147"] }]
    );

    const hits = searchMessages({ query: "thanks", limit: 10, contactFilter: "Fairfax" });
    expect(hits.length).toBe(1);
    expect(hits[0]!.thread_id).toBe(chat_c);
  });

  test("contact_filter-only search applies a default recent window", () => {
    const now = Date.now;
    Date.now = () => Date.parse("2026-06-01T00:00:00Z");
    try {
      const h = insertHandle(db, { id: "+14045550147" });
      const chat = insertChat(db, { guid: "c_recent_window" });
      linkChatHandle(db, chat, h);
      insertMessage(db, { chat_id: chat, text: "ancient thanks", date_iso: "2024-01-01T00:00:00Z", handle_id: h });
      insertMessage(db, { chat_id: chat, text: "recent thanks", date_iso: "2026-05-01T00:00:00Z", handle_id: h });

      _setContactsForTesting(
        new Map([["4045550147", "Fairfax Sample"]]),
        [{ lower_name: "fairfax sample", handles: ["4045550147"] }]
      );

      const hits = searchMessages({ query: "thanks", limit: 10, contactFilter: "Fairfax" });
      expect(hits.map((h) => h.body)).toEqual(["recent thanks"]);
    } finally {
      Date.now = now;
    }
  });

  test("hits carry reply_to resolved from the originator", () => {
    const them = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, them);
    insertMessage(db, {
      chat_id: c,
      text: "dinner plan question",
      date_iso: "2026-05-12T12:00:00Z",
      handle_id: them,
      guid: "orig-search-1",
    });
    insertMessage(db, {
      chat_id: c,
      text: "yes dinner sounds great",
      date_iso: "2026-05-12T12:05:00Z",
      is_from_me: true,
      thread_originator_guid: "orig-search-1",
    });

    const hits = searchMessages({ query: "dinner sounds", limit: 10, sinceIso: "2026-05-01T00:00:00Z" });
    expect(hits.length).toBe(1);
    expect(hits[0]!.reply_to).not.toBeNull();
    expect(hits[0]!.reply_to!.guid).toBe("orig-search-1");
    expect(hits[0]!.reply_to!.body).toBe("dinner plan question");
  });
});

describe("resolveDirectChat", () => {
  test("chooses the most recent addressable single-participant chat for a handle", () => {
    const target = insertHandle(db, { id: "+14155551234" });
    const other = insertHandle(db, { id: "+14155550000" });

    const oldSms = insertChat(db, { guid: "SMS;-;+14155551234" });
    const newRcs = insertChat(db, { guid: "RCS;-;+14155551234" });
    const unboundAny = insertChat(db, { guid: "any;-;+14155551234" });
    const group = insertChat(db, { guid: "iMessage;+;group-chat", style: 43 });

    linkChatHandle(db, oldSms, target);
    linkChatHandle(db, newRcs, target);
    linkChatHandle(db, unboundAny, target);
    linkChatHandle(db, group, target);
    linkChatHandle(db, group, other);

    insertMessage(db, { chat_id: oldSms, text: "sms", date_iso: "2026-05-10T12:00:00Z", handle_id: target });
    insertMessage(db, { chat_id: newRcs, text: "rcs", date_iso: "2026-05-12T12:00:00Z", handle_id: target });
    insertMessage(db, { chat_id: unboundAny, text: "any", date_iso: "2026-05-13T12:00:00Z", handle_id: target });
    insertMessage(db, { chat_id: group, text: "group", date_iso: "2026-05-14T12:00:00Z", handle_id: target });

    expect(resolveDirectChat("+1 (415) 555-1234")).toEqual({
      chatGUID: "RCS;-;+14155551234",
      service: "RCS",
    });
  });

  test("accepts addressable service prefixes case-insensitively", () => {
    const target = insertHandle(db, { id: "+14155551234" });
    const chat = insertChat(db, { guid: "sms;-;+14155551234" });
    linkChatHandle(db, chat, target);
    insertMessage(db, { chat_id: chat, text: "lowercase sms", date_iso: "2026-05-12T12:00:00Z", handle_id: target });

    expect(resolveDirectChat("+14155551234")).toEqual({
      chatGUID: "sms;-;+14155551234",
      service: "sms",
    });
  });

  test("returns null for unbound or group-only chats", () => {
    const target = insertHandle(db, { id: "+14155551234" });
    const other = insertHandle(db, { id: "+14155550000" });
    const unboundAny = insertChat(db, { guid: "any;-;+14155551234" });
    const group = insertChat(db, { guid: "iMessage;+;group-chat", style: 43 });

    linkChatHandle(db, unboundAny, target);
    linkChatHandle(db, group, target);
    linkChatHandle(db, group, other);
    insertMessage(db, { chat_id: unboundAny, text: "any", date_iso: "2026-05-13T12:00:00Z", handle_id: target });
    insertMessage(db, { chat_id: group, text: "group", date_iso: "2026-05-14T12:00:00Z", handle_id: target });

    expect(resolveDirectChat("+14155551234")).toBeNull();
  });
});

// Regression for the contact_filter-by-name bug (Thomas Fixture / thread 1971):
// list_threads(contact_filter="Thomas") returned [] while search_messages
// resolved sender.name to "Thomas Fixture" fine. Root cause: load()'s sidecar
// branch populated handleToName (so resolveHandle worked) but never built
// nameIndex (so findHandlesByContactName — the reverse lookup that widens
// contact_filter — returned []), and the sidecar is the DEFAULT load source
// once the menu bar app is installed.
//
// These tests deliberately AVOID _setContactsForTesting: that seam injects
// nameIndex directly, which is exactly what hid this bug from the existing
// "Fairfax fix" test. Here we write a real granted sidecar and force a real
// layered load(), so contact_filter exercises the same path the daemon runs
// in production.
describe("contact_filter through the real sidecar load (regression: sidecar nameIndex)", () => {
  const sidecarRoot = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-queries-sidecar-"));
  const sidecarPath = join(sidecarRoot, "contacts-cache.json");

  function writeSidecar(handles: Record<string, string>) {
    mkdirSync(sidecarRoot, { recursive: true });
    writeFileSync(
      sidecarPath,
      JSON.stringify({
        version: CONTACTS_CACHE_SCHEMA_VERSION,
        generated_at: "2026-06-02T00:00:00Z",
        source: "menubar-cnContactStore",
        permission_status: "granted",
        count: Object.keys(handles).length,
        handles,
      })
    );
    // lstat-safe check rejects anything broader than 0600 (matches the Swift writer).
    chmodSync(sidecarPath, 0o600);
  }

  beforeEach(() => {
    _setSidecarPathForTesting(sidecarPath);
    // Thomas Fixture: saved by name, but messaged from a bare +1 number whose
    // canonical tail is 2025550148 (the exact repro contact + handle).
    writeSidecar({ "2025550148": "Thomas Fixture" });
    _resetContactsCache(); // force the real layered load() on next access
  });

  afterAll(() => {
    _setSidecarPathForTesting(null);
    _resetContactsCache();
    rmSync(sidecarRoot, { recursive: true, force: true });
  });

  // Build the by-number thread (no chat display_name, handle has no name in it),
  // plus an unrelated thread that must NOT match the name filter.
  function buildThomasThread(): number {
    const h = insertHandle(db, { id: "+12025550148" });
    const other = insertHandle(db, { id: "+14155550000" });
    const c = insertChat(db, { guid: "c_thomas" });
    const c_other = insertChat(db, { guid: "c_other" });
    linkChatHandle(db, c, h);
    linkChatHandle(db, c_other, other);
    insertMessage(db, {
      chat_id: c,
      text: "so botco I know mostly designers",
      date_iso: "2026-05-30T01:18:46Z",
      handle_id: h,
    });
    insertMessage(db, {
      chat_id: c_other,
      text: "unrelated",
      date_iso: "2026-05-30T01:00:00Z",
      handle_id: other,
    });
    return c;
  }

  test("sidecar load resolves the handle AND builds the name index (both paths consistent)", () => {
    buildThomasThread();
    // Body-search resolution path (handleToName) — already worked before the fix.
    expect(resolveHandle("+12025550148")).toBe("Thomas Fixture");
    expect(getLastContactsLoadSource()).toBe("sidecar");
    // contact_filter reverse-lookup path (nameIndex) — was empty before the fix.
    expect(findHandlesByContactName("Thomas")).toContain("2025550148"); // first name
    expect(findHandlesByContactName("Fixture")).toContain("2025550148");  // last name
  });

  test("list_threads contact_filter by FIRST name finds the by-number thread", () => {
    const thread = buildThomasThread();
    const r = listThreads({ limit: 10, contactFilter: "Thomas" });
    expect(r.threads.map((t) => t.thread_id)).toEqual([thread]);
    expect(r.threads[0]!.participants[0]!.name).toBe("Thomas Fixture");
  });

  test("list_threads contact_filter by LAST name finds the by-number thread", () => {
    const thread = buildThomasThread();
    const r = listThreads({ limit: 10, contactFilter: "Fixture" });
    expect(r.threads.map((t) => t.thread_id)).toEqual([thread]);
  });

  test("search_messages contact_filter by last name widens to the by-number thread", () => {
    const thread = buildThomasThread();
    const hits = searchMessages({ query: "botco", limit: 10, contactFilter: "Fixture" });
    expect(hits.length).toBe(1);
    expect(hits[0]!.thread_id).toBe(thread);
    expect(hits[0]!.sender.name).toBe("Thomas Fixture");
  });

  test("contact_filter that matches no contact name still does NOT match the by-number thread by name", () => {
    // Guard against a false-positive fix: a name that isn't in contacts must
    // not suddenly match. Confirms the widening is name-driven, not a blanket pass.
    buildThomasThread();
    const r = listThreads({ limit: 10, contactFilter: "Nonexistent" });
    expect(r.threads).toEqual([]);
  });

  // ROOT_CAUSE-contact-filter.md #2: name matching must be diacritic-insensitive.
  test("contact_filter is diacritic-insensitive (jose matches José)", () => {
    writeSidecar({ "5551230000": "José Díaz" });
    _resetContactsCache();
    expect(resolveHandle("+15551230000")).toBe("José Díaz");
    // Accent-free filter must match the accented stored name (and vice versa).
    expect(findHandlesByContactName("jose")).toContain("5551230000");
    expect(findHandlesByContactName("diaz")).toContain("5551230000");
    expect(findHandlesByContactName("José")).toContain("5551230000");
  });

  // ROOT_CAUSE-contact-filter.md #3: the reverse index must stay reachable —
  // every named handle in handleToName resolves back via its own name. Catches
  // any future contacts source that populates one structure but not the other.
  test("invariant: every named handle is reachable via findHandlesByContactName on its own name", () => {
    const handles: Record<string, string> = {
      "2025550148": "Thomas Fixture",
      "5551230000": "José Díaz",
      "alice@example.com": "Alice O'Brien",
    };
    writeSidecar(handles);
    _resetContactsCache();
    for (const [canon, name] of Object.entries(handles)) {
      expect(resolveHandle(canon)).toBe(name); // forward (handleToName)
      expect(findHandlesByContactName(name)).toContain(canon); // reverse (nameIndex)
    }
  });
});
