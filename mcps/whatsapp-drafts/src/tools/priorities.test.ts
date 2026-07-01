import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Env seam before the dynamic import — PATHS resolves WHATSAPP_MCP_HOME
// lazily per access (see paths.ts), so the handlers below write into this
// tmp dir, not the real ~/.whatsapp-mcp.
const tmp = mkdtempSync(join(tmpdir(), "whatsapp-mcp-priorities-tool-"));
process.env.WHATSAPP_MCP_HOME = tmp;

const {
  _handleClearThreadPriority,
  _handleListThreadPriorities,
  _handleSetThreadPriority,
} = await import("./priorities.ts");

const prioritiesPath = join(tmp, "thread-priorities.json");
const JID = "12025550001@s.whatsapp.net";

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

beforeEach(() => {
  process.env.WHATSAPP_MCP_HOME = tmp;
  rmSync(prioritiesPath, { force: true });
});

function payload(result: { content: Array<{ type: "text"; text: string }> }) {
  return JSON.parse(result.content[0]!.text);
}

describe("set_whatsapp_thread_priority handler", () => {
  test("set → list roundtrip through the tool layer", () => {
    const setRes = _handleSetThreadPriority({ thread_jid: JID, level: 1, reason: "urgent reply needed" });
    expect((setRes as { isError?: boolean }).isError).toBeUndefined();
    const set = payload(setRes);
    expect(set.ok).toBe(true);
    expect(set.thread_jid).toBe(JID);
    expect(set.priority.level).toBe(1);
    expect(set.priority.set_by).toBe("agent");
    expect(set.path).toBe(prioritiesPath);

    const list = payload(_handleListThreadPriorities());
    expect(list.ok).toBe(true);
    expect(list.count).toBe(1);
    expect(list.priorities[JID].level).toBe(1);
  });

  test("reason round-trips wrapped as untrusted data", () => {
    _handleSetThreadPriority({ thread_jid: JID, level: 2, reason: "check in about dinner" });
    const list = payload(_handleListThreadPriorities());
    expect(list.priorities[JID].reason).toBe("<untrusted_content>\ncheck in about dinner\n</untrusted_content>");
  });

  test("level outside 1–3 is rejected at the zod boundary", () => {
    for (const level of [0, 4, 1.5]) {
      const res = _handleSetThreadPriority({ thread_jid: JID, level });
      expect((res as { isError?: boolean }).isError).toBe(true);
    }
    expect(payload(_handleListThreadPriorities()).count).toBe(0);
  });

  test("empty thread_jid and over-long reason are rejected", () => {
    const emptyJid = _handleSetThreadPriority({ thread_jid: "", level: 1 });
    expect((emptyJid as { isError?: boolean }).isError).toBe(true);

    const longReason = _handleSetThreadPriority({ thread_jid: JID, level: 1, reason: "x".repeat(201) });
    expect((longReason as { isError?: boolean }).isError).toBe(true);
  });
});

describe("clear_whatsapp_thread_priority handler", () => {
  test("clear reports removed: true then removed: false (idempotent)", () => {
    _handleSetThreadPriority({ thread_jid: JID, level: 2 });
    const first = payload(_handleClearThreadPriority({ thread_jid: JID }));
    expect(first.ok).toBe(true);
    expect(first.removed).toBe(true);

    const second = payload(_handleClearThreadPriority({ thread_jid: JID }));
    expect(second.ok).toBe(true);
    expect(second.removed).toBe(false);

    expect(payload(_handleListThreadPriorities()).count).toBe(0);
  });
});

describe("list_whatsapp_thread_priorities handler", () => {
  test("empty store lists zero priorities", () => {
    const list = payload(_handleListThreadPriorities());
    expect(list.ok).toBe(true);
    expect(list.count).toBe(0);
    expect(list.priorities).toEqual({});
  });
});
