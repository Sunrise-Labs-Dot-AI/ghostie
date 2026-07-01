import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, chmodSync, statSync, symlinkSync, writeFileSync } from "node:fs";
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
  tmpDir = mkdtempSync(join(tmpdir(), "witness-test-"));
  _setHomeForTesting(tmpDir);
  return tmpDir;
}

describe("writeLastInvocation (iMessage)", () => {
  test("writes the witness record with all expected fields", () => {
    const dir = setupTmpHome();
    writeLastInvocation("list_threads");

    const raw = readFileSync(join(dir, "last_invocation_imessage.json"), "utf8");
    const record = JSON.parse(raw) as WitnessRecord;

    expect(record.tool).toBe("list_threads");
    expect(record.pid).toBe(process.pid);
    expect(typeof record.writer_path).toBe("string");
    // ISO-8601 sanity: parses to a valid Date and re-stringifies to the same shape
    expect(Number.isNaN(new Date(record.ts).getTime())).toBe(false);
    expect(record.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);

    const activity = readFileSync(join(dir, "mcp-activity.jsonl"), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(activity).toHaveLength(1);
    expect(activity[0].transport).toBe("imessage");
    expect(activity[0].tool).toBe("list_threads");
  });

  test("creates the home directory if it doesn't exist", () => {
    tmpDir = mkdtempSync(join(tmpdir(), "witness-test-parent-"));
    const nestedHome = join(tmpDir, "nested", "messages-mcp-home");
    _setHomeForTesting(nestedHome);

    writeLastInvocation("get_thread");

    const raw = readFileSync(join(nestedHome, "last_invocation_imessage.json"), "utf8");
    expect((JSON.parse(raw) as WitnessRecord).tool).toBe("get_thread");
  });

  test("overwrites prior record without leaving stale temp files behind", () => {
    const dir = setupTmpHome();
    writeLastInvocation("list_threads");
    writeLastInvocation("get_thread");
    writeLastInvocation("search_messages");

    const final = JSON.parse(
      readFileSync(join(dir, "last_invocation_imessage.json"), "utf8"),
    ) as WitnessRecord;
    expect(final.tool).toBe("search_messages");

    // No orphan .tmp.* files left in the directory
    const orphans = readdirSync(dir).filter((f) => f.includes(".tmp."));
    expect(orphans).toEqual([]);
  });

  test("atomic-rename semantics: file is never partially-written at the final path", () => {
    // Stronger guarantee: the final path is created via rename, not as a
    // streaming write target. We can't easily race against the write here,
    // but we can confirm that statting the final path always yields a fully-
    // parseable JSON record after the call returns.
    const dir = setupTmpHome();
    for (let i = 0; i < 50; i++) {
      writeLastInvocation(`tool_${i}`);
      const raw = readFileSync(join(dir, "last_invocation_imessage.json"), "utf8");
      const record = JSON.parse(raw) as WitnessRecord;
      expect(record.tool).toBe(`tool_${i}`);
    }
  });

  test("swallows failure when the target directory is read-only", () => {
    tmpDir = mkdtempSync(join(tmpdir(), "witness-test-ro-"));
    // Create the dir, write into it, then make it read-only to block the
    // atomic-rename's temp-file creation.
    _setHomeForTesting(tmpDir);
    writeLastInvocation("setup");
    chmodSync(tmpDir, 0o500);
    try {
      // Must not throw despite the underlying write failing.
      expect(() => writeLastInvocation("would_fail")).not.toThrow();
    } finally {
      // Restore writable perms so afterEach's rmSync can clean up.
      chmodSync(tmpDir, 0o700);
    }
  });

  test("the final file has a single inode that changes across writes (rename, not in-place)", () => {
    const dir = setupTmpHome();
    const path = join(dir, "last_invocation_imessage.json");
    writeLastInvocation("first");
    const inoBefore = statSync(path).ino;
    writeLastInvocation("second");
    const inoAfter = statSync(path).ino;
    // The rename swaps the inode; an in-place writeFileSync would preserve it.
    // Asserting the change confirms the DispatchSource-friendly write path.
    expect(inoAfter).not.toBe(inoBefore);
  });

  test("omits chatdb_access when no probe is wired", () => {
    const dir = setupTmpHome();
    writeLastInvocation("list_threads");
    const record = JSON.parse(
      readFileSync(join(dir, "last_invocation_imessage.json"), "utf8"),
    ) as WitnessRecord;
    expect(record.chatdb_access).toBeUndefined();
  });

  test("records chatdb_access from the wired probe (the issue #17 client-FDA signal)", () => {
    const dir = setupTmpHome();
    setChatDbAccessProbe(() => "permission_denied");
    writeLastInvocation("health_check");
    const record = JSON.parse(
      readFileSync(join(dir, "last_invocation_imessage.json"), "utf8"),
    ) as WitnessRecord;
    expect(record.chatdb_access).toBe("permission_denied");
  });

  test("a throwing probe never blocks the witness write", () => {
    const dir = setupTmpHome();
    setChatDbAccessProbe(() => { throw new Error("probe boom"); });
    expect(() => writeLastInvocation("list_threads")).not.toThrow();
    const record = JSON.parse(
      readFileSync(join(dir, "last_invocation_imessage.json"), "utf8"),
    ) as WitnessRecord;
    expect(record.tool).toBe("list_threads");
    expect(record.chatdb_access).toBeUndefined();
  });

  test("refuses to append activity through a symlink", () => {
    const dir = setupTmpHome();
    const target = join(dir, "target.txt");
    writeFileSync(target, "safe");
    symlinkSync(target, join(dir, "mcp-activity.jsonl"));

    expect(() => writeLastInvocation("list_threads")).not.toThrow();

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
// on handler success. Without this, an MCP error result (e.g. FDA-not-granted
// returning `errorResult(...)`) would still flip the walkthrough's
// "Claude reached this MCP" check to green.
describe("registerWithWitness: error-result gating", () => {
  /** Captures the wrapped callback for direct invocation in tests. */
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
    registerWithWitness(server, "list_threads", { description: "test" }, async () => ({
      isError: true,
      content: [{ type: "text", text: "FDA not granted" }],
    }));

    await run({});

    expect(existsSync(join(dir, "last_invocation_imessage.json"))).toBe(false);
  });

  test("isError:false (or absent) handler result DOES write a witness", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_threads", { description: "test" }, async () => ({
      content: [{ type: "text", text: "ok" }],
    }));

    await run({});

    const raw = readFileSync(join(dir, "last_invocation_imessage.json"), "utf8");
    expect((JSON.parse(raw) as WitnessRecord).tool).toBe("list_threads");
  });

  test("handler-thrown errors propagate AND skip the witness write", async () => {
    const dir = setupTmpHome();
    const { server, run } = makeStubServer();
    registerWithWitness(server, "list_threads", { description: "test" }, async () => {
      throw new Error("boom");
    });

    await expect(run({})).rejects.toThrow("boom");
    expect(existsSync(join(dir, "last_invocation_imessage.json"))).toBe(false);
  });
});
