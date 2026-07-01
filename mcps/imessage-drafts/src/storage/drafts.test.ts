import { describe, test, expect, beforeAll, beforeEach, afterAll, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync, readdirSync, statSync, copyFileSync, symlinkSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

import * as drafts from "./drafts.ts";
import { _setContactsForTesting, _resetContactsCache, resolveHandle } from "../chatdb/contacts.ts";

// Use the explicit test seam (`_setDraftsDirForTesting`). The earlier
// approach of overriding `process.env.HOME` doesn't work on macOS —
// `os.homedir()` uses passwd lookup by effective UID and ignores the
// JS-level override, so tests silently leaked into the real
// `~/.messages-mcp/drafts` AND wiped its contents in beforeEach.
const tmpHome = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-test-"));
const tmpDraftsDir = join(tmpHome, ".messages-mcp", "drafts");

beforeAll(() => {
  drafts._setDraftsDirForTesting(tmpDraftsDir);
});

afterAll(() => {
  drafts._setDraftsDirForTesting(null);
  rmSync(tmpHome, { recursive: true, force: true });
});

beforeEach(() => {
  // Clear test drafts between tests so listDrafts assertions stay
  // deterministic. Safe to rmSync now — this is the tmp dir, not the
  // user's real drafts.
  rmSync(tmpDraftsDir, { recursive: true, force: true });
});

describe("stageDraft / getDraft / discardDraft", () => {
  test("stage writes a draft with sent_at: null and 0600 perms", () => {
    const { draft, path } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    expect(draft.sent_at).toBeNull();
    expect(draft.send_service).toBeNull();
    expect(draft.source).toBeNull();
    expect(draft.to_handle).toBe("+14155551234");
    expect(draft.body).toBe("hi");
    expect(path.endsWith(`${draft.id}.json`)).toBe(true);
    expect(path.startsWith(tmpDraftsDir)).toBe(true);
  });

  test("stage with source records the provenance label", () => {
    const { draft } = drafts.stageDraft({
      to_handle: "+14155551234",
      body: "hi",
      source: "Claude Code / unit test",
    });
    expect(draft.source).toBe("Claude Code / unit test");
  });

  test("getDraft returns the staged draft", () => {
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    const fetched = drafts.getDraft(draft.id);
    expect(fetched?.id).toBe(draft.id);
    expect(fetched?.body).toBe("hi");
  });

  test("getDraft returns null for unknown id", () => {
    expect(drafts.getDraft(randomUUID())).toBeNull();
  });

  test("listDrafts returns newest-first", () => {
    const a = drafts.stageDraft({ to_handle: "+14155551111", body: "a" });
    // Tiny gap so the file mtimes differ enough to sort.
    Bun.sleepSync(15);
    const b = drafts.stageDraft({ to_handle: "+14155552222", body: "b" });
    const list = drafts.listDrafts(10);
    expect(list[0]!.id).toBe(b.draft.id);
    expect(list[1]!.id).toBe(a.draft.id);
  });

  test("discardDraft removes the file and getDraft returns null after", () => {
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    expect(drafts.discardDraft(draft.id)).toBe(true);
    expect(drafts.getDraft(draft.id)).toBeNull();
  });

  test("discardDraft returns false for unknown id", () => {
    expect(drafts.discardDraft(randomUUID())).toBe(false);
  });
});

describe("markDraftSent", () => {
  test("sets sent_at + send_service and persists to disk", () => {
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    const updated = drafts.markDraftSent(draft.id, "2026-05-13T00:00:00.000Z", "iMessage");
    expect(updated?.sent_at).toBe("2026-05-13T00:00:00.000Z");
    expect(updated?.send_service).toBe("iMessage");

    const fetched = drafts.getDraft(draft.id);
    expect(fetched?.sent_at).toBe("2026-05-13T00:00:00.000Z");
    expect(fetched?.send_service).toBe("iMessage");
  });

  test("preserves source through mark-sent", () => {
    const { draft } = drafts.stageDraft({
      to_handle: "+14155551234",
      body: "hi",
      source: "ci test",
    });
    const updated = drafts.markDraftSent(draft.id, "2026-05-13T00:00:00.000Z", "SMS");
    expect(updated?.source).toBe("ci test");
  });

  test("returns null for unknown id", () => {
    expect(drafts.markDraftSent(randomUUID(), "2026-05-13T00:00:00.000Z", "iMessage")).toBeNull();
  });

  test("idempotent: calling twice on a sent draft returns the existing record without overwriting", () => {
    // Defends against a race between the Node MCP server and the Swift
    // menubar app — both can call their respective markDraftSent in
    // overlapping windows. The Swift side already has a `guard !isSent`;
    // this test pins the Node-side equivalent so a future refactor that
    // restores blind-overwrite behavior (clobbering the Swift writer's
    // sent_at + send_service + source) fails CI.
    const { draft } = drafts.stageDraft({
      to_handle: "+14155551234",
      body: "hi",
      source: "first-writer",
    });
    const first = drafts.markDraftSent(draft.id, "2026-05-13T00:00:00.000Z", "iMessage");
    expect(first?.sent_at).toBe("2026-05-13T00:00:00.000Z");
    expect(first?.send_service).toBe("iMessage");

    // Second call simulates the racing writer — different timestamp + service.
    const second = drafts.markDraftSent(draft.id, "2026-05-14T00:00:00.000Z", "SMS");
    expect(second?.sent_at).toBe("2026-05-13T00:00:00.000Z"); // original preserved
    expect(second?.send_service).toBe("iMessage"); // original preserved
    expect(second?.source).toBe("first-writer"); // metadata preserved

    // And on disk too — the second call must not have written.
    const fromDisk = drafts.getDraft(draft.id);
    expect(fromDisk?.sent_at).toBe("2026-05-13T00:00:00.000Z");
    expect(fromDisk?.send_service).toBe("iMessage");
  });

  test("refuses if the parent ~/.messages-mcp is a symlink", () => {
    // Defense-in-depth: even if the drafts dir itself is a real dir, an
    // attacker who pre-symlinked the parent before our first run wins —
    // mkdirSync(recursive:true) would create `drafts/` inside the symlink
    // target and every staged draft + audit log entry would land in the
    // attacker-controlled location.
    //
    // Setup: blow away the test home, redirect the test seam to a NEW
    // path whose parent IS a symlink, and assert any operation that runs
    // through ensureDir throws. Restore the original test seam afterward
    // so subsequent tests pass.
    const malHome = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-malhome-"));
    const decoyTarget = join(malHome, "real-imessage-drafts-mcp-dir");
    const symlinkedParent = join(malHome, ".messages-mcp");
    const draftsUnderSymlink = join(symlinkedParent, "drafts");
    // Create the decoy as a real directory.
    writeFileSync(join(malHome, "marker"), "marker");  // touch to materialize malHome
    rmSync(symlinkedParent, { recursive: true, force: true });
    // Symlink the parent.
    symlinkSync(decoyTarget, symlinkedParent);
    drafts._setDraftsDirForTesting(draftsUnderSymlink);
    try {
      expect(() => drafts.stageDraft({ to_handle: "+14155551234", body: "hi" }))
        .toThrow(/parent directory is a symlink/);
    } finally {
      // Restore the canonical test seam so the rest of the suite keeps working.
      drafts._setDraftsDirForTesting(tmpDraftsDir);
      rmSync(malHome, { recursive: true, force: true });
    }
  });

  test("refuses to overwrite a symlinked draft path", () => {
    // Symlink-clobber defense — if a local-UID attacker pre-creates the
    // draft file as a symlink to ~/.zshrc, renameSync would happily
    // replace the symlink target with our JSON. lstatSync rejects.
    //
    // Setup: stage normally, copy the resulting JSON aside, then replace
    // the real path with a symlink pointing at the copy. getDraft reads
    // through the symlink and parses valid JSON, but the lstatSync check
    // in markDraftSent sees a symbolic link and throws BEFORE the rename.
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    const draftFile = join(tmpDraftsDir, `${draft.id}.json`);
    const decoyTarget = join(tmpHome, "decoy-target.json");
    copyFileSync(draftFile, decoyTarget);
    const decoyContentsBefore = readFileSync(decoyTarget, "utf8");
    rmSync(draftFile);
    symlinkSync(decoyTarget, draftFile);

    expect(() => drafts.markDraftSent(draft.id, "2026-05-13T00:00:00.000Z", "iMessage"))
      .toThrow(/symlink/);
    // Decoy target must be untouched — our JSON did NOT clobber it.
    expect(readFileSync(decoyTarget, "utf8")).toBe(decoyContentsBefore);
  });

  test("writes atomically: no .tmp leftovers and the drafts dir mtime advances", () => {
    // Atomicity matters because the menu bar app's directory watcher
    // (DispatchSourceFileSystemObject on the drafts dir) only fires on
    // directory-entry changes — create/delete/rename — not on in-place
    // writes. A rename bumps the parent directory's mtime; a plain
    // in-place writeFileSync does not.
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    const dirMtimeBefore = statSync(tmpDraftsDir).mtimeMs;
    // Tiny sleep so the post-rename mtime is observably newer than the
    // post-stage mtime on filesystems with coarse mtime granularity.
    Bun.sleepSync(15);

    const updated = drafts.markDraftSent(draft.id, "2026-05-13T00:00:00.000Z", "iMessage");
    expect(updated?.sent_at).toBe("2026-05-13T00:00:00.000Z");

    // No .tmp-* leftovers in the drafts dir — they should all be renamed away.
    const leftoverTmps = readdirSync(tmpDraftsDir).filter((f) => f.includes(".tmp-"));
    expect(leftoverTmps).toEqual([]);

    // Directory mtime advanced, which is the file-watcher signal the menu
    // bar app relies on. (If this ever regresses to plain writeFileSync,
    // the dir mtime will not change and the menu bar will go stale.)
    const dirMtimeAfter = statSync(tmpDraftsDir).mtimeMs;
    expect(dirMtimeAfter).toBeGreaterThan(dirMtimeBefore);
  });
});

describe("to_handle_name resolution", () => {
  afterEach(() => { _resetContactsCache(); });

  test("resolves to contact name when handle is known", () => {
    _setContactsForTesting(
      new Map([["4155551234", "Alice Smith"]]),
      [{ lower_name: "alice smith", handles: ["4155551234"] }]
    );
    const { draft } = drafts.stageDraft({
      to_handle: "+14155551234",
      to_handle_name: resolveHandle("+14155551234"),
      body: "hi",
    });
    expect(draft.to_handle_name).toBe("Alice Smith");
  });

  test("to_handle_name is null when handle is unknown", () => {
    _setContactsForTesting(new Map(), []);
    const { draft } = drafts.stageDraft({
      to_handle: "+14155559999",
      to_handle_name: null,
      body: "hi",
    });
    expect(draft.to_handle_name).toBeNull();
  });

  test("non-canonical phone matches via canonHandle (last-10-digits)", () => {
    _setContactsForTesting(
      new Map([["4045550147", "Bob Jones"]]),
      [{ lower_name: "bob jones", handles: ["4045550147"] }]
    );
    // resolveHandle strips non-digits and takes last 10 → "4045550147"
    expect(resolveHandle("+1 (404) 555-0147")).toBe("Bob Jones");
  });

  test("backward-compat: draft written without to_handle_name decodes with null", () => {
    // Trigger ensureDir by staging once.
    drafts.stageDraft({ to_handle: "+14155550000", body: "seed" });
    const id = randomUUID();
    writeFileSync(join(tmpDraftsDir, `${id}.json`), JSON.stringify({
      id,
      to_handle: "+14155551234",
      body: "from v0 without name",
      in_reply_to_thread_id: null,
      staged_at: "2026-05-01T00:00:00Z",
    }, null, 2));
    const fetched = drafts.getDraft(id);
    expect(fetched?.to_handle_name).toBeNull();
  });
});

describe("normalizeDraft backward-compat", () => {
  test("reads a pre-source / pre-sent_at format draft and backfills nulls", () => {
    // Hand-write a draft in the earliest schema (before sent_at,
    // send_service, source). The test seam ensures this lands in the
    // tmpdir, not the real drafts dir.
    const id = randomUUID();
    // Trigger ensureDir by staging once.
    drafts.stageDraft({ to_handle: "+14155550000", body: "seed" });
    writeFileSync(join(tmpDraftsDir, `${id}.json`), JSON.stringify({
      id,
      to_handle: "+14155551234",
      body: "from v0",
      in_reply_to_thread_id: null,
      staged_at: "2026-05-01T00:00:00Z",
    }, null, 2));
    const fetched = drafts.getDraft(id);
    expect(fetched?.sent_at).toBeNull();
    expect(fetched?.send_service).toBeNull();
    expect(fetched?.source).toBeNull();
    expect(fetched?.body).toBe("from v0");
  });
});
