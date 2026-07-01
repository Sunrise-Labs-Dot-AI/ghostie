import { describe, test, expect, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  _setAutomationsPathForTesting,
  deletePendingAutomation,
  listAutomations,
  proposeAutomation,
} from "./automations.ts";

const tmpHome = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-automations-test-"));
const automationsPath = join(tmpHome, ".messages-mcp", "automations.json");

beforeEach(() => {
  _setAutomationsPathForTesting(automationsPath);
  rmSync(join(tmpHome, ".messages-mcp"), { recursive: true, force: true });
});

afterAll(() => {
  _setAutomationsPathForTesting(null);
  rmSync(tmpHome, { recursive: true, force: true });
});

describe("automation proposal storage", () => {
  test("stores MCP-created automations as pending and disabled", () => {
    const automation = proposeAutomation({
      title: "Weekly Ryan",
      platform: "imessage",
      toHandle: "+12155550121",
      toHandleName: "Ryan",
      body: "Hope your Friday is good",
      cadence: "weekly",
      firstSendAt: "2026-06-05T17:00:00Z",
      proposedBy: "Claude Desktop",
    });

    expect(automation.approvalStatus).toBe("pending");
    expect(automation.isEnabled).toBe(false);
    expect(automation.nextRunAt).toBe("2026-06-05T17:00:00.000Z");
    expect(listAutomations()[0]!.id).toBe(automation.id);
  });

  test("deletes pending proposals", () => {
    const automation = proposeAutomation({
      platform: "whatsapp",
      toHandle: "14155551234@s.whatsapp.net",
      body: "hi",
      cadence: "monthly",
      firstSendAt: "2026-06-05T17:00:00Z",
    });

    const deleted = deletePendingAutomation(automation.id);

    expect(deleted!.id).toBe(automation.id);
    expect(listAutomations()).toEqual([]);
  });

  test("rejects invalid first send timestamps", () => {
    expect(() => proposeAutomation({
      platform: "imessage",
      toHandle: "+14155551234",
      body: "hi",
      cadence: "weekly",
      firstSendAt: "friday-ish",
    })).toThrow("first_send_at");
  });
});
