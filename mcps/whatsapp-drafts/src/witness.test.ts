import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, chmodSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  _setHomeForTesting,
  registerWithWitness,
  writeLastInvocation,
  type WitnessRecord,
} from "./witness.ts";

let tmpDir: string | null = null;

afterEach(() => {
  _setHomeForTesting(null);
  if (tmpDir !== null) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = null;
  }
});

function setupTmpHome(): string {
  tmpDir = mkdtempSync(join(tmpdir(), "witness-test-"));
  _setHomeForTesting(tmpDir);
  return tmpDir;
}

describe("writeLastInvocation (WhatsApp)", () => {
  test("writes the witness record with all expected fields", () => {
    const dir = setupTmpHome();
    writeLastInvocation("list_whatsapp_threads");

    const raw = readFileSync(join(dir, "last_invocation_whatsapp.json"), "utf8");
    const record = JSON.parse(raw) as WitnessRecord;

    expect(record.tool).toBe("list_whatsapp_threads");
    expect(record.pid).toBe(process.pid);
    expect(typeof record.writer_path).toBe("string");
    expect(Number.isNaN(new Date(record.ts).getTime())).toBe(false);
    expect(record.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);

    const activity = readFileSync(join(dir, "mcp-activity.jsonl"), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(activity).toHaveLength(1);
    expect(activity[0].transport).toBe("whatsapp");
    expect(activity[0].tool).toBe("list_whatsapp_threads");
  });

  test("creates the home directory if it doesn't exist", () => {
    tmpDir = mkdtempSync(join(tmpdir(), "witness-test-parent-"));
    const nestedHome = join(tmpDir, "nested", "messages-mcp-home");
    _setHomeForTesting(nestedHome);

    writeLastInvocation("get_whatsapp_thread");

    const raw = readFileSync(join(nestedHome, "last_invocation_whatsapp.json"), "utf8");
    expect((JSON.parse(raw) as WitnessRecord).tool).toBe("get_whatsapp_thread");
  });

  test("overwrites prior record without leaving stale temp files behind", () => {
    const dir = setupTmpHome();
    writeLastInvocation("list_whatsapp_threads");
    writeLastInvocation("get_whatsapp_thread");
    writeLastInvocation("stage_whatsapp_draft");

    const final = JSON.parse(
      readFileSync(join(dir, "last_invocation_whatsapp.json"), "utf8"),
    ) as WitnessRecord;
    expect(final.tool).toBe("stage_whatsapp_draft");

    const orphans = readdirSync(dir).filter((f) => f.includes(".tmp."));
    expect(orphans).toEqual([]);
  });

  test("atomic-rename semantics: file is never partially-written at the final path", () => {
    const dir = setupTmpHome();
    for (let i = 0; i < 50; i++) {
      writeLastInvocation(`tool_${i}`);
      const raw = readFileSync(join(dir, "last_invocation_whatsapp.json"), "utf8");
      const record = JSON.parse(raw) as WitnessRecord;
      expect(record.tool).toBe(`tool_${i}`);
    }
  });

  test("swallows failure when the target directory is read-only", () => {
    tmpDir = mkdtempSync(join(tmpdir(), "witness-test-ro-"));
    _setHomeForTesting(tmpDir);
    writeLastInvocation("setup");
    chmodSync(tmpDir, 0o500);
    try {
      expect(() => writeLastInvocation("would_fail")).not.toThrow();
    } finally {
      chmodSync(tmpDir, 0o700);
    }
  });

  test("the final file has a single inode that changes across writes (rename, not in-place)", () => {
    const dir = setupTmpHome();
    const path = join(dir, "last_invocation_whatsapp.json");
    writeLastInvocation("first");
    const inoBefore = statSync(path).ino;
    writeLastInvocation("second");
    const inoAfter = statSync(path).ino;
    expect(inoAfter).not.toBe(inoBefore);
  });

  test("refuses to append activity through a symlink", () => {
    const dir = setupTmpHome();
    const target = join(dir, "target.txt");
    writeFileSync(target, "safe");
    symlinkSync(target, join(dir, "mcp-activity.jsonl"));

    expect(() => writeLastInvocation("list_whatsapp_threads")).not.toThrow();

    expect(readFileSync(target, "utf8")).toBe("safe");
  });

  test("keeps activity history bounded to a rolling window", () => {
    const dir = setupTmpHome();
    for (let i = 0; i < 1050; i++) {
      writeLastInvocation(`tool_${i}`);
    }

    const activity = readFileSync(join(dir, "mcp-activity.jsonl"), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(activity).toHaveLength(1000);
    expect(activity[0].tool).toBe("tool_50");
    expect(activity.at(-1)?.tool).toBe("tool_1049");
  });
});

// Regression coverage for the code-review fix that gates the witness write
// on handler success — mirror of the iMessage tests.
describe("registerWithWitness: error-result gating", () => {
  function makeStubServer() {
    let captured: ((extra: unknown) => Promise<unknown>) | null = null;
    const stub = {
      registerTool: (
        _name: unknown,
        _config: unknown,
        cb: (extra: unknown) => Promise<unknown>,
      ) => {
        captured = cb;
        return {} as unknown;
      },
    };
    return {
      server: stub as unknown as McpServer,
      run: async (...args: unknown[]) => {
        if (captured == null) throw new Error("handler never registered");
        return (captured as (...a: unknown[]) => Promise<unknown>)(...args);
      },
    };
  }

  test("isError:true handler result does NOT write a witness", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_whatsapp_threads", { description: "test" }, async () => ({
      isError: true,
      content: [{ type: "text", text: "daemon not running" }],
    }));

    await run({});

    expect(existsSync(join(dir, "last_invocation_whatsapp.json"))).toBe(false);
  });

  test("isError:false (or absent) handler result DOES write a witness", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_whatsapp_threads", { description: "test" }, async () => ({
      content: [{ type: "text", text: "ok" }],
    }));

    await run({});

    const raw = readFileSync(join(dir, "last_invocation_whatsapp.json"), "utf8");
    expect((JSON.parse(raw) as WitnessRecord).tool).toBe("list_whatsapp_threads");
  });

  test("handler-thrown errors propagate AND skip the witness write", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_whatsapp_threads", { description: "test" }, async () => {
      throw new Error("boom");
    });

    await expect(run({})).rejects.toThrow("boom");
    expect(existsSync(join(dir, "last_invocation_whatsapp.json"))).toBe(false);
  });
});
