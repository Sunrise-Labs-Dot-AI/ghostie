// messages.db content is wrapped with the SAME master key as the WhatsApp
// session (see the module header in messages.ts, #81). So any event that loses
// or rotates that key — the reset path used to delete it outright — leaves rows
// behind that can never be decrypted again.
//
// The read path used to end in a bare `return unwrap(buf)`, so ONE such row
// threw out of getThreadMessages and took the entire thread (or search) with
// it: the transport looked completely broken rather than missing one body.
// These tests pin the fail-soft behaviour.

import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

const tmp = mkdtempSync(join(tmpdir(), "whatsapp-mcp-undecryptable-"));
const savedHome = process.env.WHATSAPP_MCP_HOME;
const savedTestKey = process.env.WHATSAPP_MCP_TEST_KEY;
process.env.WHATSAPP_MCP_HOME = tmp;

const KEY_A = randomBytes(32).toString("base64");
const KEY_B = randomBytes(32).toString("base64");
process.env.WHATSAPP_MCP_TEST_KEY = KEY_A;

const {
  insertMessage,
  upsertThread,
  getThreadMessages,
  searchMessages,
  getMessageFull,
  getMediaDescriptor,
  getMessagesDb,
  _getUndecryptableCount,
  _resetForTesting,
} = await import("./messages.ts");
const { _resetKeyCache } = await import("./crypto.ts");
_resetKeyCache();

function useKey(b64: string): void {
  process.env.WHATSAPP_MCP_TEST_KEY = b64;
  _resetKeyCache();
}

beforeEach(() => {
  useKey(KEY_A);
  const db = getMessagesDb();
  db.exec("DELETE FROM messages");
  db.exec("DELETE FROM threads");
});

afterAll(() => {
  _resetForTesting();
  if (savedHome == null) delete process.env.WHATSAPP_MCP_HOME;
  else process.env.WHATSAPP_MCP_HOME = savedHome;
  if (savedTestKey == null) delete process.env.WHATSAPP_MCP_TEST_KEY;
  else process.env.WHATSAPP_MCP_TEST_KEY = savedTestKey;
  _resetKeyCache();
  rmSync(tmp, { recursive: true, force: true });
});

const THREAD = "12025550123@s.whatsapp.net";

function seedMessage(id: string, body: string, ts: number): void {
  upsertThread({ thread_jid: THREAD, display_name: "Test", is_group: false, last_message_ts: ts });
  insertMessage({
    message_id: id,
    thread_jid: THREAD,
    sender_jid: THREAD,
    from_me: false,
    ts,
    body,
    message_type: "text",
    attachment_meta: null,
    media_descriptor: null,
    reply_to_id: null,
    source: "live",
  });
}

describe("content written under a lost master key", () => {
  test("a thread read degrades that message to null instead of throwing", () => {
    seedMessage("old-1", "written under the old key", 1_700_000_000_000);

    useKey(KEY_B); // the key rotated out from under us

    let rows: ReturnType<typeof getThreadMessages> | undefined;
    expect(() => { rows = getThreadMessages({ thread_jid: THREAD, limit: 10 }); }).not.toThrow();
    expect(rows).toHaveLength(1);
    expect(rows?.[0]?.body).toBeNull();
  });

  test("readable messages in the same thread still come back intact", () => {
    seedMessage("old-1", "unreadable after rotation", 1_700_000_000_000);
    useKey(KEY_B);
    seedMessage("new-1", "written under the new key", 1_700_000_001_000);

    const rows = getThreadMessages({ thread_jid: THREAD, limit: 10 });
    const byId = new Map(rows.map((r) => [r.message_id, r.body]));

    expect(byId.get("old-1")).toBeNull();
    expect(byId.get("new-1")).toBe("written under the new key");
  });

  test("search skips undecryptable rows rather than failing the query", () => {
    seedMessage("old-1", "needle in the old key", 1_700_000_000_000);
    useKey(KEY_B);
    seedMessage("new-1", "needle in the new key", 1_700_000_001_000);

    let hits: ReturnType<typeof searchMessages> | undefined;
    expect(() => { hits = searchMessages({ query: "needle", limit: 10 }); }).not.toThrow();
    expect(hits?.map((h) => h.message_id)).toEqual(["new-1"]);
  });

  test("getMessageFull degrades instead of throwing", () => {
    seedMessage("old-1", "full body under the old key", 1_700_000_000_000);
    useKey(KEY_B);

    expect(() => getMessageFull(THREAD, "old-1")).not.toThrow();
  });

  test("an undecryptable media descriptor reads as 'no media', not a crash", () => {
    upsertThread({ thread_jid: THREAD, display_name: "T", is_group: false, last_message_ts: 1 });
    insertMessage({
      message_id: "media-1",
      thread_jid: THREAD,
      sender_jid: THREAD,
      from_me: false,
      ts: 1_700_000_000_000,
      body: null,
      message_type: "image",
      attachment_meta: { mime: "image/jpeg" },
      media_descriptor: new Uint8Array([1, 2, 3, 4]),
      reply_to_id: null,
      source: "live",
    });

    useKey(KEY_B);

    expect(() => getMediaDescriptor(THREAD, "media-1")).not.toThrow();
    expect(getMediaDescriptor(THREAD, "media-1")).toBeNull();
  });

  test("undecryptable reads are counted so the failure is observable", () => {
    const before = _getUndecryptableCount();
    seedMessage("old-1", "counted", 1_700_000_000_000);
    useKey(KEY_B);

    getThreadMessages({ thread_jid: THREAD, limit: 10 });

    expect(_getUndecryptableCount()).toBeGreaterThan(before);
  });
});
