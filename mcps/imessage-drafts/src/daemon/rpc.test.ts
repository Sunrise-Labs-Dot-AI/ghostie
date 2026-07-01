// Tests for the daemon RPC layer: the dispatch/validation logic (handle())
// exercised directly, plus the client's daemon-unavailable behavior. The full
// socket + peer-auth round-trip is covered by the live menu-bar integration,
// not here (it needs a signed binary + a running daemon).

import { test, expect, describe, beforeAll, afterAll, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { handle } from "./server.ts";
import { callDaemon, DaemonUnavailableError } from "./rpc-client.ts";
import { _setChatDbForTesting, isoUtcToAppleDateNs } from "../chatdb/open.ts";

function buildDirectChatDb(): Database {
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
    CREATE TABLE chat_handle_join (
      chat_id INTEGER,
      handle_id INTEGER
    );
    CREATE TABLE chat_message_join (
      chat_id INTEGER,
      message_id INTEGER,
      message_date INTEGER
    );
  `);
  return db;
}

function insertDirectChatFixture(db: Database): void {
  db.run(`INSERT INTO handle (id, service) VALUES (?, ?)`, ["+14155551234", "SMS"]);
  const handleId = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  db.run(`INSERT INTO chat (guid, display_name, style) VALUES (?, ?, ?)`, ["SMS;-;+14155551234", null, 45]);
  const chatId = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  db.run(`INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)`, [chatId, handleId]);
  db.run(`INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)`, [
    chatId,
    1,
    isoUtcToAppleDateNs("2026-05-12T12:00:00Z"),
  ]);
}

afterEach(() => {
  _setChatDbForTesting(null);
});

describe("daemon RPC dispatch (handle)", () => {
  test("chatDbDiagnostic returns a diagnostic (never throws)", () => {
    const r = handle({ jsonrpc: "2.0", id: 1, method: "chatDbDiagnostic" });
    expect(r.error).toBeUndefined();
    expect((r.result as { open_status?: string }).open_status).toBeDefined();
  });

  test("health returns chatdb + addressbook + contacts_load", () => {
    const r = handle({ jsonrpc: "2.0", id: 2, method: "health" });
    expect(r.error).toBeUndefined();
    const res = r.result as Record<string, unknown>;
    expect(res.chatdb).toBeDefined();
    expect(res.addressbook).toBeDefined();
    expect(res.contacts_load).toBeDefined();
  });

  test("unknown method → METHOD_NOT_FOUND (-32601)", () => {
    const r = handle({ jsonrpc: "2.0", id: 3, method: "definitelyNotAMethod" });
    expect(r.error?.code).toBe(-32601);
  });

  test("probeHandle canonicalizes; missing handle → INVALID_PARAMS", () => {
    const ok = handle({
      jsonrpc: "2.0", id: 4, method: "probeHandle",
      params: { handle: "+1 (415) 555-1234" },
    });
    expect(ok.error).toBeUndefined();
    // resolved_name depends on the local Contacts sidecar (not asserted);
    // canonicalization is deterministic.
    expect((ok.result as { canonical?: string }).canonical).toBe("4155551234");

    const bad = handle({ jsonrpc: "2.0", id: 5, method: "probeHandle", params: {} });
    expect(bad.error?.code).toBe(-32602);
  });

  test("listThreads without limit → INVALID_PARAMS (-32602)", () => {
    const r = handle({ jsonrpc: "2.0", id: 6, method: "listThreads", params: {} });
    expect(r.error?.code).toBe(-32602);
  });

  test("getThread without threadId → INVALID_PARAMS", () => {
    const r = handle({ jsonrpc: "2.0", id: 7, method: "getThread", params: { limit: 10 } });
    expect(r.error?.code).toBe(-32602);
  });

  test("searchMessages with <2-char query → INVALID_PARAMS", () => {
    const r = handle({
      jsonrpc: "2.0", id: 8, method: "searchMessages",
      params: { query: "a", limit: 5 },
    });
    expect(r.error?.code).toBe(-32602);
  });

  test("recentContext without limit → INVALID_PARAMS", () => {
    const r = handle({ jsonrpc: "2.0", id: 9, method: "recentContext", params: {} });
    expect(r.error?.code).toBe(-32602);
  });

  test("resolveDirectChat validates params and returns the daemon-resolved chat", () => {
    const bad = handle({ jsonrpc: "2.0", id: 10, method: "resolveDirectChat", params: {} });
    expect(bad.error?.code).toBe(-32602);

    const db = buildDirectChatDb();
    insertDirectChatFixture(db);
    _setChatDbForTesting(db);

    const ok = handle({
      jsonrpc: "2.0",
      id: 11,
      method: "resolveDirectChat",
      params: { handle: "+1 (415) 555-1234" },
    });
    expect(ok.error).toBeUndefined();
    expect(ok.result).toEqual({ chatGUID: "SMS;-;+14155551234", service: "SMS" });
  });
});

// Defense-in-depth: the daemon must enforce the same since/contact_filter
// history bounds the MCP schema enforces, so a raw daemon RPC (one that
// bypasses the MCP and wins peer-auth) can't dump unbounded history (issue #78).
describe("daemon-enforced read bounds (issue #78)", () => {
  test("listThreads with neither sinceIso nor contactFilter → INVALID_PARAMS", () => {
    const r = handle({ jsonrpc: "2.0", id: 20, method: "listThreads", params: { limit: 50 } });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("sinceIso");
  });

  test("searchMessages with valid query but no sinceIso/contactFilter → INVALID_PARAMS", () => {
    const r = handle({
      jsonrpc: "2.0", id: 21, method: "searchMessages",
      params: { query: "hello", limit: 50 },
    });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("sinceIso");
  });

  test("listThreads with a 1-char contactFilter → INVALID_PARAMS (>=2 chars)", () => {
    const r = handle({
      jsonrpc: "2.0", id: 22, method: "listThreads",
      params: { limit: 50, contactFilter: "a" },
    });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("at least 2");
  });

  test("searchMessages with sinceIso older than 2 years → INVALID_PARAMS", () => {
    const tenYearsAgo = new Date(Date.now() - 10 * 365 * 24 * 60 * 60 * 1000).toISOString();
    const r = handle({
      jsonrpc: "2.0", id: 23, method: "searchMessages",
      params: { query: "hello", limit: 50, sinceIso: tenYearsAgo },
    });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("2 years");
  });

  test("listThreads with sinceIso that isn't a valid timestamp → INVALID_PARAMS", () => {
    const r = handle({
      jsonrpc: "2.0", id: 24, method: "listThreads",
      params: { limit: 50, sinceIso: "not-a-date" },
    });
    expect(r.error?.code).toBe(-32602);
  });

  test("an over-limit listThreads (>500) is still rejected", () => {
    const r = handle({
      jsonrpc: "2.0", id: 25, method: "listThreads",
      params: { limit: 100000, contactFilter: "Alex" },
    });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("1..500");
  });

  // Round 2 (issue #78): getThread was the one read path with no historical
  // bound — beforeIso could page back arbitrarily far. It now rejects a cursor
  // older than the 2-year window, capping deep historical extraction by an
  // authed peer while leaving recent-thread reads usable.
  test("getThread with a beforeIso older than 2 years → INVALID_PARAMS", () => {
    const tenYearsAgo = new Date(Date.now() - 10 * 365 * 24 * 60 * 60 * 1000).toISOString();
    const r = handle({
      jsonrpc: "2.0", id: 30, method: "getThread",
      params: { threadId: 1, limit: 50, beforeIso: tenYearsAgo },
    });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("2 years");
  });

  test("getThread with a malformed beforeIso → INVALID_PARAMS (no silent widen)", () => {
    const r = handle({
      jsonrpc: "2.0", id: 31, method: "getThread",
      params: { threadId: 1, limit: 50, beforeIso: "not-a-date" },
    });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("ISO-8601");
  });

  test("getThread with a recent beforeIso passes the bounds gate (not rejected for bounds)", () => {
    // May still error if chat.db isn't readable in CI, but must NOT be rejected
    // for the historical bound.
    const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const r = handle({
      jsonrpc: "2.0", id: 32, method: "getThread",
      params: { threadId: 1, limit: 25, beforeIso: yesterday },
    });
    if (r.error) {
      expect(r.error.message).not.toContain("2 years");
      expect(r.error.message).not.toContain("ISO-8601");
    }
  });

  test("getThread with an over-limit (>500) is still rejected", () => {
    const r = handle({
      jsonrpc: "2.0", id: 33, method: "getThread",
      params: { threadId: 1, limit: 100000 },
    });
    expect(r.error?.code).toBe(-32602);
    expect(r.error?.message).toContain("1..500");
  });

  test("listThreads with a valid contactFilter passes the bounds gate (no INVALID_PARAMS for bounds)", () => {
    // It may still error internally if chat.db isn't readable in CI, but it
    // must NOT be rejected for missing bounds. Assert the error, if any, is
    // not the bounds INVALID_PARAMS.
    const r = handle({
      jsonrpc: "2.0", id: 26, method: "listThreads",
      params: { limit: 25, contactFilter: "Alex" },
    });
    if (r.error) {
      expect(r.error.message).not.toContain("sinceIso");
      expect(r.error.message).not.toContain("at least 2");
    }
  });
});

describe("rpc-client (daemon unavailable)", () => {
  const prev = process.env.MESSAGES_MCP_HOME;
  beforeAll(() => {
    // Point at a tmpdir with no daemon.sock so connectWithTimeout's
    // existsSync gate fails fast.
    process.env.MESSAGES_MCP_HOME = mkdtempSync(join(tmpdir(), "imsg-rpc-test-"));
  });
  afterAll(() => {
    if (prev === undefined) delete process.env.MESSAGES_MCP_HOME;
    else process.env.MESSAGES_MCP_HOME = prev;
  });

  test("callDaemon rejects with DaemonUnavailableError when the socket is missing", async () => {
    await expect(callDaemon("chatDbDiagnostic")).rejects.toBeInstanceOf(DaemonUnavailableError);
  });
});
