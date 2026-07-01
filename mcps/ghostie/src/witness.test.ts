import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  _setHomeForTesting,
  registerWithWitness,
  setChatDbAccessProbe,
  writeLastInvocation,
  type WitnessRecord,
} from "./witness.ts";

let tmpDir: string | null = null;

afterEach(() => {
  _setHomeForTesting(null);
  setChatDbAccessProbe(null);
  if (tmpDir !== null) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = null;
  }
});

function setupTmpHome(): string {
  tmpDir = mkdtempSync(join(tmpdir(), "ghostie-witness-test-"));
  _setHomeForTesting(tmpDir);
  return tmpDir;
}

function readRecord(dir: string, transport: "imessage" | "whatsapp"): WitnessRecord {
  return JSON.parse(readFileSync(join(dir, `last_invocation_${transport}.json`), "utf8")) as WitnessRecord;
}

function readActivity(dir: string): Array<WitnessRecord & { transport: string }> {
  return readFileSync(join(dir, "mcp-activity.jsonl"), "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as WitnessRecord & { transport: string });
}

describe("writeLastInvocation (ghostie, per-transport)", () => {
  test("writes the per-transport witness record with all expected fields", () => {
    const dir = setupTmpHome();
    writeLastInvocation("imessage", "list_message_threads");
    writeLastInvocation("whatsapp", "list_message_threads");

    for (const transport of ["imessage", "whatsapp"] as const) {
      const record = readRecord(dir, transport);
      expect(record.tool).toBe("list_message_threads");
      expect(record.pid).toBe(process.pid);
      expect(typeof record.writer_path).toBe("string");
      expect(Number.isNaN(new Date(record.ts).getTime())).toBe(false);
      expect(record.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
    }

    const activity = readActivity(dir);
    expect(activity).toHaveLength(2);
    expect(activity.map((entry) => entry.transport)).toEqual(["imessage", "whatsapp"]);
    expect(activity.map((entry) => entry.tool)).toEqual(["list_message_threads", "list_message_threads"]);
  });

  test("transports never clobber each other's witness file", () => {
    const dir = setupTmpHome();
    writeLastInvocation("imessage", "search_message_history");
    writeLastInvocation("whatsapp", "stage_message_draft");

    expect(readRecord(dir, "imessage").tool).toBe("search_message_history");
    expect(readRecord(dir, "whatsapp").tool).toBe("stage_message_draft");
  });

  test("overwrites prior record without leaving stale temp files behind", () => {
    const dir = setupTmpHome();
    writeLastInvocation("imessage", "list_message_threads");
    writeLastInvocation("imessage", "get_message_thread");

    expect(readRecord(dir, "imessage").tool).toBe("get_message_thread");
    const orphans = readdirSync(dir).filter((f) => f.includes(".tmp."));
    expect(orphans).toEqual([]);
  });

  test("the final file changes inode across writes (rename, not in-place)", () => {
    const dir = setupTmpHome();
    const path = join(dir, "last_invocation_whatsapp.json");
    writeLastInvocation("whatsapp", "first");
    const inoBefore = statSync(path).ino;
    writeLastInvocation("whatsapp", "second");
    const inoAfter = statSync(path).ino;
    // The rename swaps the inode; an in-place writeFileSync would preserve
    // it. The menubar's DispatchSource watcher relies on the rename.
    expect(inoAfter).not.toBe(inoBefore);
  });

  test("records chatdb_access from the wired probe on iMessage records only", () => {
    const dir = setupTmpHome();
    setChatDbAccessProbe(() => "permission_denied");
    writeLastInvocation("imessage", "ghostie_health_check");
    writeLastInvocation("whatsapp", "ghostie_health_check");

    expect(readRecord(dir, "imessage").chatdb_access).toBe("permission_denied");
    // The WhatsApp transport witness never carries the field — mirror that.
    expect(readRecord(dir, "whatsapp").chatdb_access).toBeUndefined();
  });

  test("omits chatdb_access when no probe is wired", () => {
    const dir = setupTmpHome();
    writeLastInvocation("imessage", "list_message_threads");
    expect(readRecord(dir, "imessage").chatdb_access).toBeUndefined();
  });

  test("a throwing probe never blocks the witness write", () => {
    const dir = setupTmpHome();
    setChatDbAccessProbe(() => { throw new Error("probe boom"); });
    expect(() => writeLastInvocation("imessage", "list_message_threads")).not.toThrow();
    const record = readRecord(dir, "imessage");
    expect(record.tool).toBe("list_message_threads");
    expect(record.chatdb_access).toBeUndefined();
  });

  test("refuses to append activity through a symlink", () => {
    const dir = setupTmpHome();
    const target = join(dir, "target.txt");
    writeFileSync(target, "safe");
    symlinkSync(target, join(dir, "mcp-activity.jsonl"));

    expect(() => writeLastInvocation("imessage", "list_message_threads")).not.toThrow();
    expect(readFileSync(target, "utf8")).toBe("safe");
  });

  test("keeps activity history bounded to a rolling window", () => {
    const dir = setupTmpHome();
    for (let i = 0; i < 1050; i++) {
      writeLastInvocation(i % 2 === 0 ? "imessage" : "whatsapp", `tool_${i}`);
    }
    const activity = readActivity(dir);
    expect(activity).toHaveLength(1000);
    expect(activity[0]!.tool).toBe("tool_50");
    expect(activity.at(-1)?.tool).toBe("tool_1049");
  });
});

// The facade equivalent of the transport MCPs' error-result gating tests,
// plus the facade-specific contract: only TOUCHED transports are witnessed,
// so a cross-transport call with one side down never greens the dead side.
describe("registerWithWitness: touch + error-result gating", () => {
  /** Captures the wrapped callback for direct invocation in tests. */
  function makeStubServer() {
    let captured: ((...args: unknown[]) => Promise<unknown>) | null = null;
    const stub = {
      tool: (
        _name: unknown,
        _description: unknown,
        _schema: unknown,
        cb: (...args: unknown[]) => Promise<unknown>,
      ) => {
        captured = cb;
        return {} as unknown;
      },
    };
    return {
      server: stub as unknown as McpServer,
      run: async (...args: unknown[]) => {
        if (captured == null) throw new Error("handler never registered");
        return captured(...args);
      },
    };
  }

  test("touched transports are witnessed on success; untouched are not", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_message_threads", "test", {}, async (_args, witness) => {
      witness.touch("imessage");
      return { content: [{ type: "text" as const, text: "ok" }] };
    });

    await run({});

    expect(readRecord(dir, "imessage").tool).toBe("list_message_threads");
    expect(existsSync(join(dir, "last_invocation_whatsapp.json"))).toBe(false);
  });

  test("touching both transports writes both witnesses", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "search_message_history", "test", {}, async (_args, witness) => {
      witness.touch("imessage");
      witness.touch("whatsapp");
      return { content: [{ type: "text" as const, text: "ok" }] };
    });

    await run({});

    expect(readRecord(dir, "imessage").tool).toBe("search_message_history");
    expect(readRecord(dir, "whatsapp").tool).toBe("search_message_history");
  });

  test("a successful handler that touched nothing writes nothing", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "get_message_current_time", "test", {}, async () => ({
      content: [{ type: "text" as const, text: "ok" }],
    }));

    await run({});

    expect(readdirSync(dir)).toEqual([]);
  });

  test("isError:true handler result does NOT write a witness, even when touched", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_message_threads", "test", {}, async (_args, witness) => {
      witness.touch("imessage");
      return { isError: true, content: [{ type: "text" as const, text: "daemon unavailable" }] };
    });

    await run({});

    expect(existsSync(join(dir, "last_invocation_imessage.json"))).toBe(false);
  });

  test("handler-thrown errors propagate AND skip every witness write", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_message_threads", "test", {}, async (_args, witness) => {
      witness.touch("whatsapp");
      throw new Error("boom");
    });

    await expect(run({})).rejects.toThrow("boom");
    expect(existsSync(join(dir, "last_invocation_whatsapp.json"))).toBe(false);
  });
});
