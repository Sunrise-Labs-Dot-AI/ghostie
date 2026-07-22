// SUN-613 phase 0. The stamp has to survive every read/write round-trip in the
// storage layer.
//
// `normalizeDraft` projects field-by-field, so a field it forgets is silently
// dropped on the next write. For `relay_executor` that failure is not cosmetic:
// dropping it un-routes the draft and hands a second Mac permission to send it.

import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { _setDraftsDirForTesting, getDraft, markDraftSent, stageDraft, updateScheduling } from "./drafts.ts";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ghostie-relay-executor-"));
  _setDraftsDirForTesting(dir);
});

afterEach(() => {
  _setDraftsDirForTesting(null);
  rmSync(dir, { recursive: true, force: true });
});

/** Write a draft file directly so we can seed a stamp the way the relay will. */
function seedStampedDraft(id: string, relayExecutor: string | null): void {
  writeFileSync(
    join(dir, `${id}.json`),
    JSON.stringify({
      id,
      to_handle: "+14155551234",
      to_handle_name: null,
      body: "hi",
      attachments: [],
      in_reply_to_thread_id: null,
      staged_at: "2026-05-15T00:00:00Z",
      sent_at: null,
      send_service: null,
      source: null,
      context_messages: null,
      context_diagnostic: null,
      scheduled_send_at: null,
      schedule_hold_reason: null,
      override_send: null,
      schedule_approved: null,
      delivery_progress: { completed_attachment_count: 0, body_sent: false, ambiguous_part: null },
      relay_executor: relayExecutor,
    }),
    { mode: 0o600 },
  );
}

test("a newly staged draft is unrouted", () => {
  const { draft } = stageDraft({ to_handle: "+14155551234", body: "hi" });
  expect(draft.relay_executor).toBeNull();
});

test("getDraft reads the stamp back", () => {
  seedStampedDraft("11111111-1111-4111-8111-111111111111", "device-aaaaaaaa");
  expect(getDraft("11111111-1111-4111-8111-111111111111")?.relay_executor).toBe("device-aaaaaaaa");
});

test("a legacy draft without the field reads as unrouted", () => {
  // Back-compat: every draft on disk today predates this field.
  writeFileSync(
    join(dir, "22222222-2222-4222-8222-222222222222.json"),
    JSON.stringify({
      id: "22222222-2222-4222-8222-222222222222",
      to_handle: "+14155551234",
      body: "hi",
      staged_at: "2026-05-15T00:00:00Z",
    }),
    { mode: 0o600 },
  );
  expect(getDraft("22222222-2222-4222-8222-222222222222")?.relay_executor).toBeNull();
});

test("a present but malformed stamp is PRESERVED, not normalized to null", () => {
  // Normalizing corrupt routing data to null would make the draft look unrouted
  // and therefore sendable by any Mac — fail open. Keep it so the gate refuses.
  // (Second-lane review, finding 6.)
  seedStampedDraft("33333333-3333-4333-8333-333333333333", "");
  expect(getDraft("33333333-3333-4333-8333-333333333333")?.relay_executor).toBe("");
});

test("a non-string stamp is preserved as a string so the gate can refuse it", () => {
  writeFileSync(
    join(dir, "66666666-6666-4666-8666-666666666666.json"),
    JSON.stringify({
      id: "66666666-6666-4666-8666-666666666666",
      to_handle: "+14155551234",
      body: "hi",
      staged_at: "2026-05-15T00:00:00Z",
      relay_executor: 42,
    }),
    { mode: 0o600 },
  );
  expect(getDraft("66666666-6666-4666-8666-666666666666")?.relay_executor).toBe("42");
});

test("markDraftSent does not strip the stamp", () => {
  const id = "44444444-4444-4444-8444-444444444444";
  seedStampedDraft(id, "device-aaaaaaaa");
  markDraftSent(id, "2026-05-15T00:01:00Z", "iMessage");

  expect(getDraft(id)?.relay_executor).toBe("device-aaaaaaaa");
  // Assert on the FILE too: an in-memory-only survival would still lose the
  // stamp for the menu bar and the other Mac, which read the JSON.
  const onDisk = JSON.parse(readFileSync(join(dir, `${id}.json`), "utf8")) as {
    relay_executor: string | null;
  };
  expect(onDisk.relay_executor).toBe("device-aaaaaaaa");
});

test("updateScheduling does not strip the stamp", () => {
  const id = "55555555-5555-4555-8555-555555555555";
  seedStampedDraft(id, "device-aaaaaaaa");
  updateScheduling(id, { scheduled_send_at: "2026-05-16T09:00:00Z" });
  expect(getDraft(id)?.relay_executor).toBe("device-aaaaaaaa");
});
