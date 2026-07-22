// SUN-613. Repro test for second-lane review finding 2: the WhatsApp daemon
// reached Baileys without ever checking which machine owns the draft.
//
// The point of this file is that the assertion is about the WIRE. A stub
// connection records every call, so "refused" means the transport was never
// touched, not merely that an error was returned somewhere upstream.

import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { localDeviceId, resetDeviceIdCacheForTesting } from "../../../shared/src/device-id.ts";
import type { Draft } from "../storage/drafts.ts";
import { deliverDraftParts } from "./server.ts";

let root: string;
let messagesRoot: string;
let previousHome: string | undefined;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ghostie-wa-executor-"));
  messagesRoot = mkdtempSync(join(tmpdir(), "ghostie-msgs-executor-"));
  previousHome = process.env.MESSAGES_MCP_HOME;
  process.env.MESSAGES_MCP_HOME = messagesRoot;
  resetDeviceIdCacheForTesting();
});

afterEach(() => {
  if (previousHome === undefined) delete process.env.MESSAGES_MCP_HOME;
  else process.env.MESSAGES_MCP_HOME = previousHome;
  resetDeviceIdCacheForTesting();
  rmSync(root, { recursive: true, force: true });
  rmSync(messagesRoot, { recursive: true, force: true });
});

/** Records every wire call so a test can assert the transport was never hit. */
function recordingConnection() {
  const calls: string[] = [];
  return {
    calls,
    sendText: async (to: string) => {
      calls.push(`sendText:${to}`);
      return { message_id: "should-never-happen" };
    },
    sendMedia: async (to: string) => {
      calls.push(`sendMedia:${to}`);
      return { message_id: "should-never-happen" };
    },
  };
}

function draftFixture(relayExecutor: string | null): Draft {
  return {
    id: "00000000-0000-4000-8000-000000000200",
    schema_version: 1,
    platform: "whatsapp",
    approval_state: "approved",
    to_handle: "12025550001@s.whatsapp.net",
    to_handle_name: null,
    body: "hi",
    staged_at: "2026-05-15T00:00:00Z",
    sent_at: null,
    source: "test",
    induced_by_unknown_contact: false,
    quoted_message_id: null,
    quoted_preview: null,
    attachments: [],
    delivery_progress: { completed_attachment_count: 0, body_sent: false, ambiguous_part: null },
    scheduled_send_at: null,
    schedule_hold_reason: null,
    override_send: null,
    schedule_approved: null,
    schedule_approval_tag: null,
    relay_executor: relayExecutor,
    context_messages: [],
    context_diagnostic: null,
  };
}

test("a draft stamped for another Mac never reaches the transport", async () => {
  const connection = recordingConnection();
  await expect(
    deliverDraftParts(draftFixture("BBBBBBBB-0000-1111-2222-333344445555"), connection, null, {
      transportRoot: root,
      update: ((_id: string, patch: Partial<Draft>) => ({ ...draftFixture(null), ...patch })) as never,
    }),
  ).rejects.toThrow(/WRONG_EXECUTOR/);
  expect(connection.calls).toEqual([]);
});

test("a malformed stamp never reaches the transport", async () => {
  // Fail closed: unparseable routing data is a reason to stop, not to guess.
  const connection = recordingConnection();
  await expect(
    deliverDraftParts(draftFixture("not a device id"), connection, null, {
      transportRoot: root,
      update: ((_id: string, patch: Partial<Draft>) => ({ ...draftFixture(null), ...patch })) as never,
    }),
  ).rejects.toThrow(/WRONG_EXECUTOR/);
  expect(connection.calls).toEqual([]);
});

test("a draft stamped for THIS Mac is delivered", async () => {
  // The gate must not break the ordinary path, which is the whole risk of
  // adding a refusal at the wire boundary.
  const mine = localDeviceId();
  expect(mine).not.toBeNull();

  const connection = recordingConnection();
  const messageId = await deliverDraftParts(draftFixture(mine), connection, null, {
    transportRoot: root,
    update: ((_id: string, patch: Partial<Draft>) => ({ ...draftFixture(mine), ...patch })) as never,
  });
  expect(messageId).toBe("should-never-happen");
  expect(connection.calls).toEqual(["sendText:12025550001@s.whatsapp.net"]);
});

test("an unstamped draft is delivered, so legacy drafts still work", async () => {
  const connection = recordingConnection();
  await deliverDraftParts(draftFixture(null), connection, null, {
    transportRoot: root,
    update: ((_id: string, patch: Partial<Draft>) => ({ ...draftFixture(null), ...patch })) as never,
  });
  expect(connection.calls).toEqual(["sendText:12025550001@s.whatsapp.net"]);
});
