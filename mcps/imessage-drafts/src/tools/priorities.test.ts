import { describe, test, expect, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";

import {
  _handleClearThreadPriority,
  _handleListThreadPriorities,
  _handleSetThreadPriority,
} from "./priorities.ts";
import { _setThreadPrioritiesPathForTesting } from "../storage/priorities.ts";
import { SetThreadPriorityShape } from "../schema.ts";

// Tool-layer tests exercise the exported handlers directly rather than
// spinning up an McpServer fixture — same rationale as health.test.ts and
// drafts.test.ts: the registered tools are thin shells over these handlers,
// and the registration wiring is type-checked by tsc.

const tmpHome = mkdtempSync(join(tmpdir(), "imessage-drafts-mcp-priorities-tool-test-"));
const prioritiesPath = join(tmpHome, ".messages-mcp", "thread-priorities.json");

beforeEach(() => {
  _setThreadPrioritiesPathForTesting(prioritiesPath);
  rmSync(join(tmpHome, ".messages-mcp"), { recursive: true, force: true });
});

afterAll(() => {
  _setThreadPrioritiesPathForTesting(null);
  rmSync(tmpHome, { recursive: true, force: true });
});

function payload(result: { content: Array<{ type: "text"; text: string }> }) {
  return JSON.parse(result.content[0]!.text);
}

describe("set_thread_priority handler", () => {
  test("set → list roundtrip through the tool layer", () => {
    const setRes = _handleSetThreadPriority({ thread_id: 42, level: 1, reason: "urgent reply needed" });
    expect((setRes as { isError?: boolean }).isError).toBeUndefined();
    const set = payload(setRes);
    expect(set.ok).toBe(true);
    expect(set.thread_id).toBe(42);
    expect(set.key).toBe("42");
    expect(set.priority.level).toBe(1);
    expect(set.priority.set_by).toBe("agent");
    expect(set.path).toBe(prioritiesPath);

    const list = payload(_handleListThreadPriorities());
    expect(list.ok).toBe(true);
    expect(list.count).toBe(1);
    expect(list.priorities["42"].level).toBe(1);
  });

  test("reason round-trips wrapped as untrusted data", () => {
    _handleSetThreadPriority({ thread_id: 1, level: 2, reason: "check in about dinner" });
    const list = payload(_handleListThreadPriorities());
    expect(list.priorities["1"].reason).toBe("<untrusted_content>\ncheck in about dinner\n</untrusted_content>");
  });

  test("level outside 1–3 returns an MCP error result (store-level guard)", () => {
    const res = _handleSetThreadPriority({ thread_id: 1, level: 4 });
    expect((res as { isError?: boolean }).isError).toBe(true);
    expect(payload(res).error).toMatch(/level must be an integer between 1 and 3/);
  });

  test("zod shape rejects out-of-bounds levels and non-positive thread ids at the SDK boundary", () => {
    const schema = z.object(SetThreadPriorityShape);
    expect(schema.safeParse({ thread_id: 1, level: 0 }).success).toBe(false);
    expect(schema.safeParse({ thread_id: 1, level: 4 }).success).toBe(false);
    expect(schema.safeParse({ thread_id: 1, level: 1.5 }).success).toBe(false);
    expect(schema.safeParse({ thread_id: 0, level: 1 }).success).toBe(false);
    expect(schema.safeParse({ thread_id: 1, level: 2, reason: "x".repeat(201) }).success).toBe(false);
    expect(schema.safeParse({ thread_id: 1, level: 2, reason: "ok" }).success).toBe(true);
    expect(schema.safeParse({ thread_id: 1, level: 3 }).success).toBe(true);
  });
});

describe("clear_thread_priority handler", () => {
  test("clear reports removed: true then removed: false (idempotent)", () => {
    _handleSetThreadPriority({ thread_id: 7, level: 2 });
    const first = payload(_handleClearThreadPriority({ thread_id: 7 }));
    expect(first.ok).toBe(true);
    expect(first.removed).toBe(true);

    const second = payload(_handleClearThreadPriority({ thread_id: 7 }));
    expect(second.ok).toBe(true);
    expect(second.removed).toBe(false);

    expect(payload(_handleListThreadPriorities()).count).toBe(0);
  });
});

describe("list_thread_priorities handler", () => {
  test("empty store lists zero priorities (corrupt-file tolerant)", () => {
    const list = payload(_handleListThreadPriorities());
    expect(list.ok).toBe(true);
    expect(list.count).toBe(0);
    expect(list.priorities).toEqual({});
  });
});
