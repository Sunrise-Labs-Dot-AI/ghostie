import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tmp = mkdtempSync(join(tmpdir(), "whatsapp-mcp-drafts-"));
process.env.WHATSAPP_MCP_HOME = tmp;

const {
  stageDraft,
  getDraft,
  listDrafts,
  updateDraft,
  discardDraft,
  sweepDrafts,
  DraftSchemaError,
  DRAFT_SCHEMA_VERSION,
} = await import("./drafts.ts");

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  const dir = join(tmp, "drafts");
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    return;
  }
  for (const f of readdirSync(dir).filter((x) => x.endsWith(".json"))) {
    rmSync(join(dir, f));
  }
});

describe("drafts", () => {
  test("stage writes a draft with schema_version + pending approval", () => {
    const d = stageDraft({ to_handle: "12025550001@s.whatsapp.net", body: "hi" });
    expect(d.id).toBeTruthy();
    expect(d.schema_version).toBe(DRAFT_SCHEMA_VERSION);
    expect(d.platform).toBe("whatsapp");
    expect(d.approval_state).toBe("pending");
    expect(d.sent_at).toBeNull();
  });

  test("get returns the staged draft", () => {
    const d = stageDraft({ to_handle: "to", body: "body" });
    const got = getDraft(d.id);
    expect(got).not.toBeNull();
    expect(got!.body).toBe("body");
  });

  test("get throws on schema-version mismatch", () => {
    const d = stageDraft({ to_handle: "to", body: "x" });
    // Corrupt the file with a fake schema_version.
    const path = join(tmp, "drafts", `${d.id}.json`);
    const bad = { ...d, schema_version: 999 };
    writeFileSync(path, JSON.stringify(bad), { mode: 0o600 });
    expect(() => getDraft(d.id)).toThrow(DraftSchemaError);
  });

  test("list returns newest-first; skips schema-version mismatches", () => {
    const a = stageDraft({ to_handle: "1", body: "a" });
    const b = stageDraft({ to_handle: "2", body: "b" });
    // Corrupt one.
    writeFileSync(join(tmp, "drafts", `${a.id}.json`), JSON.stringify({ schema_version: 99 }), { mode: 0o600 });
    const r = listDrafts();
    expect(r.drafts).toHaveLength(1);
    expect(r.drafts[0]!.id).toBe(b.id);
    expect(r.skipped).toBe(1);
  });

  test("update flips approval_state and marks sent_at", () => {
    const d = stageDraft({ to_handle: "to", body: "x" });
    const next = updateDraft(d.id, { approval_state: "approved", sent_at: new Date().toISOString() });
    expect(next.approval_state).toBe("approved");
    expect(next.sent_at).not.toBeNull();
  });

  test("discard removes the file", () => {
    const d = stageDraft({ to_handle: "to", body: "x" });
    expect(discardDraft(d.id)).toBe(true);
    expect(getDraft(d.id)).toBeNull();
    expect(discardDraft(d.id)).toBe(false);
  });

  test("invalid draft id is rejected", () => {
    expect(() => getDraft("../etc/passwd")).toThrow(DraftSchemaError);
    expect(() => getDraft("a/b")).toThrow(DraftSchemaError);
    expect(() => getDraft("")).toThrow(DraftSchemaError);
  });

  test("sweep deletes drafts older than TTL", () => {
    const now = Date.now();
    const d = stageDraft({ to_handle: "to", body: "x" });
    // Forge an old staged_at on disk.
    const path = join(tmp, "drafts", `${d.id}.json`);
    const old = { ...d, staged_at: new Date(now - 10 * 86_400_000).toISOString() };
    writeFileSync(path, JSON.stringify(old), { mode: 0o600 });
    const r = sweepDrafts(7, now);
    expect(r.deleted).toBe(1);
    expect(getDraft(d.id)).toBeNull();
  });

  test("sweep deletes sent drafts older than 24h", () => {
    const now = Date.now();
    const d = stageDraft({ to_handle: "to", body: "x" });
    const path = join(tmp, "drafts", `${d.id}.json`);
    const sentLongAgo = { ...d, sent_at: new Date(now - 48 * 3_600_000).toISOString() };
    writeFileSync(path, JSON.stringify(sentLongAgo), { mode: 0o600 });
    const r = sweepDrafts(7, now);
    expect(r.deleted).toBe(1);
  });

  test("sweep keeps recent unsent drafts", () => {
    stageDraft({ to_handle: "to", body: "fresh" });
    const r = sweepDrafts(7);
    expect(r.deleted).toBe(0);
    expect(r.kept).toBe(1);
  });

  test("normal draft has null quoted_message_id + quoted_preview", () => {
    const d = stageDraft({ to_handle: "to", body: "hi" });
    expect(d.quoted_message_id).toBeNull();
    expect(d.quoted_preview).toBeNull();
  });

  test("stage persists quoted_message_id + quoted_preview and round-trips through getDraft", () => {
    const d = stageDraft({
      to_handle: "12025550001@s.whatsapp.net",
      body: "yes!",
      quoted_message_id: "orig-1",
      quoted_preview: { message_id: "orig-1", body: "are we still on?", from_me: false, sender_name: "Alice" },
    });
    expect(d.quoted_message_id).toBe("orig-1");
    expect(d.quoted_preview!.sender_name).toBe("Alice");
    const got = getDraft(d.id)!;
    expect(got.quoted_message_id).toBe("orig-1");
    expect(got.quoted_preview!.body).toBe("are we still on?");
    expect(got.quoted_preview!.from_me).toBe(false);
    // Additive optional fields — schema_version stays 1, no migration.
    expect(got.schema_version).toBe(DRAFT_SCHEMA_VERSION);
  });
});
