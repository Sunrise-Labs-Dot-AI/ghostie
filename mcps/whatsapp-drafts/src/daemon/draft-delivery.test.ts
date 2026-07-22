import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { snapshotDraftAttachments } from "../../../shared/src/attachments.ts";
import { draftPayloadDigest } from "../../../shared/src/draft-payload.ts";
import type { Draft } from "../storage/drafts.ts";
import { updateDraft } from "../storage/drafts.ts";
import type { WhatsAppConnection } from "./connection.ts";
import { deliverDraftParts, payloadDigestForDraft } from "./server.ts";

let root: string;
const DELIVERY_DRAFT_ID = "00000000-0000-4000-8000-000000000100";

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ghostie-wa-delivery-"));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function draftFixture(overrides: Partial<Draft> = {}): Draft {
  return {
    id: DELIVERY_DRAFT_ID,
    schema_version: 1,
    platform: "whatsapp",
    approval_state: "approved",
    to_handle: "12025550001@s.whatsapp.net",
    to_handle_name: "Example",
    body: "caption",
    staged_at: "2026-07-16T18:00:00.000Z",
    sent_at: null,
    source: "test",
    induced_by_unknown_contact: false,
    quoted_message_id: null,
    quoted_preview: null,
    attachments: [],
    delivery_progress: {
      completed_attachment_count: 0,
      body_sent: false,
      ambiguous_part: null,
    },
    scheduled_send_at: null,
    schedule_hold_reason: null,
    override_send: null,
    schedule_approved: null,
    schedule_approval_tag: null,
    relay_executor: null,
    context_messages: [],
    context_diagnostic: null,
    ...overrides,
  };
}

function inMemoryJournal(initial: Draft): {
  current: () => Draft;
  update: typeof updateDraft;
} {
  let current = initial;
  return {
    current: () => current,
    update: ((id, patch) => {
      if (id !== current.id) throw new Error("wrong draft id");
      current = { ...current, ...patch };
      return current;
    }) as typeof updateDraft,
  };
}

describe("WhatsApp draft part delivery", () => {
  test("single captionable media sends the exact verified Buffer and journals completion", async () => {
    const source = join(root, "photo.jpg");
    const bytes = Buffer.from([0xff, 0xd8, 0xff, 0x22]);
    writeFileSync(source, bytes);
    const attachments = snapshotDraftAttachments(root, DELIVERY_DRAFT_ID, [{ path: source }]);
    const draft = draftFixture({ attachments });
    const journal = inMemoryJournal(draft);
    const calls: Array<{ bytes: Buffer; caption: string | null }> = [];
    const connection = {
      sendMedia: async (_jid: string, _attachment: unknown, sentBytes: Buffer, caption: string | null) => {
        calls.push({ bytes: Buffer.from(sentBytes), caption });
        return { message_id: "media-1" };
      },
      sendText: async () => ({ message_id: "text-unexpected" }),
    } as unknown as Pick<WhatsAppConnection, "sendText" | "sendMedia">;

    const messageId = await deliverDraftParts(draft, connection, null, {
      transportRoot: root,
      update: journal.update,
    });

    expect(messageId).toBe("media-1");
    expect(calls).toEqual([{ bytes, caption: "caption" }]);
    expect(journal.current().delivery_progress).toEqual({
      completed_attachment_count: 1,
      body_sent: true,
      ambiguous_part: null,
    });
  });

  test("multipart failure preserves confirmed progress and the ambiguous wire part", async () => {
    const firstSource = join(root, "first.jpg");
    const secondSource = join(root, "second.jpg");
    writeFileSync(firstSource, Buffer.from([0xff, 0xd8, 0xff, 0x01]));
    writeFileSync(secondSource, Buffer.from([0xff, 0xd8, 0xff, 0x02]));
    const attachments = snapshotDraftAttachments(root, DELIVERY_DRAFT_ID, [
      { path: firstSource },
      { path: secondSource },
    ]);
    const draft = draftFixture({ attachments, body: "after media" });
    const journal = inMemoryJournal(draft);
    let mediaCalls = 0;
    const connection = {
      sendMedia: async () => {
        mediaCalls += 1;
        if (mediaCalls === 2) throw new Error("simulated uncertain transport failure");
        return { message_id: "media-1" };
      },
      sendText: async () => ({ message_id: "text-unexpected" }),
    } as unknown as Pick<WhatsAppConnection, "sendText" | "sendMedia">;

    await expect(deliverDraftParts(draft, connection, null, {
      transportRoot: root,
      update: journal.update,
    })).rejects.toThrow("simulated uncertain transport failure");

    expect(mediaCalls).toBe(2);
    expect(journal.current().delivery_progress).toEqual({
      completed_attachment_count: 1,
      body_sent: false,
      ambiguous_part: "attachment:1",
    });
  });

  test("a fully confirmed combined send resumes without replaying media", async () => {
    const source = join(root, "photo.jpg");
    writeFileSync(source, Buffer.from([0xff, 0xd8, 0xff, 0x33]));
    const attachments = snapshotDraftAttachments(root, DELIVERY_DRAFT_ID, [{ path: source }]);
    const draft = draftFixture({
      attachments,
      delivery_progress: {
        completed_attachment_count: 1,
        body_sent: true,
        ambiguous_part: null,
      },
    });
    let wireCalls = 0;
    const connection = {
      sendMedia: async () => { wireCalls += 1; return { message_id: "unexpected" }; },
      sendText: async () => { wireCalls += 1; return { message_id: "unexpected" }; },
    } as unknown as Pick<WhatsAppConnection, "sendText" | "sendMedia">;

    expect(await deliverDraftParts(draft, connection, null, { transportRoot: root })).toBe("resumed-complete");
    expect(wireCalls).toBe(0);
  });

  test("scheduled approval digest binds the actual scheduled time", () => {
    const scheduled = draftFixture({ scheduled_send_at: "2026-07-17T01:30:00.000Z" });
    const result = payloadDigestForDraft(scheduled);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.digest).toBe(draftPayloadDigest({
      id: scheduled.id,
      platform: scheduled.platform,
      to_handle: scheduled.to_handle,
      body: scheduled.body,
      quoted_message_id: scheduled.quoted_message_id,
      scheduled_send_at: scheduled.scheduled_send_at,
      attachments: [],
    }));
    const unscheduled = payloadDigestForDraft({ ...scheduled, scheduled_send_at: null });
    expect(unscheduled.ok).toBe(true);
    if (unscheduled.ok) expect(result.digest).not.toBe(unscheduled.digest);
  });
});
