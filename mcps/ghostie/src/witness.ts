// MIRROR: keep the on-disk record format in sync with
// ../../imessage-drafts/src/witness.ts and
// ../../whatsapp-drafts/src/witness.ts. Those modules are per-transport
// (one hardcoded TRANSPORT constant each); this facade variant is
// parameterized by transport because one ghostie tool call can touch
// either or both transports. The Swift readers
// (LastInvocationStore, SetupWalkthroughView, HistoryPane) consume the
// exact same files — last_invocation_{imessage,whatsapp}.json +
// mcp-activity.jsonl — so a facade-routed call must be indistinguishable
// from a transport-MCP call on disk.
//
// Writes ~/.messages-mcp/last_invocation_<transport>.json atomically
// (temp+rename) after every successful tool call so the menubar app can
// witness Claude reaching the transport through this facade.
// DispatchSourceFileSystemObject on a directory only fires on structural
// events (add/remove/rename), so atomic rename — not in-place write — is
// what makes the watcher reliable.

import { randomBytes } from "node:crypto";
import {
  closeSync,
  constants,
  fchmodSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { McpServer, ToolCallback } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ZodRawShapeCompat } from "@modelcontextprotocol/sdk/server/zod-compat.js";

export type WitnessTransport = "imessage" | "whatsapp";

const ACTIVITY_FILENAME = "mcp-activity.jsonl";
const ACTIVITY_MAX_LINES = 1000;

let testHomeOverride: string | null = null;

/** Test seam: route writes to a tempdir during unit tests. Pass null to reset. */
export function _setHomeForTesting(path: string | null): void {
  testHomeOverride = path;
}

function homeDir(): string {
  if (testHomeOverride !== null) return testHomeOverride;
  return process.env.MESSAGES_MCP_HOME ?? join(homedir(), ".messages-mcp");
}

export interface WitnessRecord {
  tool: string;
  ts: string;
  pid: number;
  writer_path: string;
  /** Live chat.db access at write time, populated only on iMessage
   *  records and only when a probe is wired via `setChatDbAccessProbe`
   *  (mirrors the iMessage MCP, which forwards the DAEMON's open_status).
   *  The walkthrough refuses to green iMessage on a permission_denied
   *  witness — omitting the field entirely would let a facade-routed
   *  call green a half-working FDA setup. WhatsApp records never carry
   *  the field, matching the WhatsApp transport witness. */
  chatdb_access?: "ok" | "permission_denied" | "not_found" | "error";
}

// Injectable chat.db access probe (iMessage records only). Kept as a hook —
// rather than importing daemon RPC here — so this module stays pure for unit
// tests; only the facade server entry point wires a real probe. Returns
// undefined to omit the field.
let chatDbAccessProbe: (() => WitnessRecord["chatdb_access"]) | null = null;

/** Wire the chat.db access probe (facade server entry point only). Pass
 *  null to reset (tests). */
export function setChatDbAccessProbe(
  fn: (() => WitnessRecord["chatdb_access"]) | null,
): void {
  chatDbAccessProbe = fn;
}

/**
 * Best-effort: write the witness record for one transport. Swallows all
 * errors so a witness failure (disk full, EACCES, transient FS issue)
 * never propagates back to the MCP caller. The MCP must never crash
 * because we couldn't write a diagnostic timestamp.
 */
export function writeLastInvocation(transport: WitnessTransport, toolName: string): void {
  try {
    const dir = homeDir();
    mkdirSync(dir, { recursive: true });
    // process.execPath is the canonical "real path to the running
    // executable" — in Bun-compiled standalone binaries it returns the
    // path to the compiled binary. process.argv[0], counterintuitively,
    // returns "bun" (Bun's embedded runtime identity inside the compiled
    // image), which makes the menubar's writer_path codesign check
    // useless. The walkthrough relies on this path to verify the writer's
    // identity — keep it accurate.
    let chatdb_access: WitnessRecord["chatdb_access"];
    if (transport === "imessage" && chatDbAccessProbe !== null) {
      try { chatdb_access = chatDbAccessProbe(); } catch { /* omit on failure */ }
    }
    const record: WitnessRecord = {
      tool: toolName,
      ts: new Date().toISOString(),
      pid: process.pid,
      writer_path: process.execPath,
      ...(chatdb_access !== undefined ? { chatdb_access } : {}),
    };
    const finalPath = join(dir, `last_invocation_${transport}.json`);
    // Random suffix on the tmp path prevents a local attacker from
    // pre-creating `last_invocation_<transport>.json.tmp.<pid>` as a
    // symlink to a sensitive file (e.g. settings.json) and tricking
    // writeFileSync into overwriting that file. pid alone is predictable
    // from `/proc`-style enumeration; random bytes are not.
    const tmpPath = `${finalPath}.tmp.${process.pid}.${randomBytes(6).toString("hex")}`;
    writeFileSync(tmpPath, JSON.stringify(record));
    renameSync(tmpPath, finalPath);
    appendActivity(dir, transport, record);
  } catch {
    // swallow — see function doc
  }
}

function appendActivity(dir: string, transport: WitnessTransport, record: WitnessRecord): void {
  try {
    const path = join(dir, ACTIVITY_FILENAME);
    if (!safeActivityTarget(dir, path)) return;
    const flags =
      constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_APPEND |
      ("O_NOFOLLOW" in constants ? constants.O_NOFOLLOW : 0);
    const fd = openSync(path, flags, 0o600);
    try {
      writeSync(fd, JSON.stringify({ transport, ...record }) + "\n");
      try { fchmodSync(fd, 0o600); } catch { /* best effort */ }
    } finally {
      closeSync(fd);
    }
    trimActivity(path);
  } catch {
    // swallow — activity history must never affect the tool response
  }
}

function safeActivityTarget(dir: string, path: string): boolean {
  try {
    const dirStat = lstatSync(dir);
    if (!dirStat.isDirectory() || dirStat.isSymbolicLink()) return false;
  } catch {
    return false;
  }
  try {
    const targetStat = lstatSync(path);
    return targetStat.isFile() && !targetStat.isSymbolicLink();
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return true;
    return false;
  }
}

function trimActivity(path: string): void {
  try {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink()) return;
    const lines = readFileSync(path, "utf8").split("\n");
    if (lines.length <= ACTIVITY_MAX_LINES + 1) return;
    const trimmed = lines.slice(-(ACTIVITY_MAX_LINES + 1)).join("\n");
    const tmpPath = `${path}.tmp.${process.pid}.${randomBytes(6).toString("hex")}`;
    writeFileSync(tmpPath, trimmed, { mode: 0o600 });
    renameSync(tmpPath, path);
  } catch {
    // best effort
  }
}

/** Per-invocation recorder handed to each facade tool handler. Handlers
 *  call `touch(transport)` after a transport operation SUCCEEDS (a daemon
 *  RPC resolved, or a local transport-scoped storage op completed). On
 *  handler success the wrapper flushes one witness record per touched
 *  transport — so a cross-transport call with one side down only
 *  witnesses the side that actually worked, and the walkthrough's
 *  per-transport verification can't false-green through the facade. */
export interface WitnessScope {
  touch(transport: WitnessTransport): void;
}

type FacadeToolResult = Awaited<ReturnType<ToolCallback<ZodRawShapeCompat>>>;

/**
 * Wraps `server.tool`, emitting per-transport witness writes after the
 * handler resolves SUCCESSFULLY. Handler-thrown errors propagate
 * unchanged AND skip every witness write. Handler-returned MCP error
 * results (`{isError: true, ...}` — the standard MCP failure signal)
 * also skip every witness write. Partial cross-transport success is the
 * recorder's job: handlers only `touch` transports whose operations
 * succeeded, so an `access_issues` partial result still witnesses the
 * healthy transport and never the failed one.
 *
 * Witness errors themselves are absorbed at two layers
 * (writeLastInvocation's own try/catch and this outer try/catch —
 * defense in depth).
 */
export function registerWithWitness<Args extends ZodRawShapeCompat>(
  server: McpServer,
  name: string,
  description: string,
  paramsSchema: Args,
  cb: (args: Parameters<ToolCallback<Args>>[0], witness: WitnessScope) => Promise<FacadeToolResult>,
): void {
  const wrapped = (async (...callbackArgs: Parameters<ToolCallback<Args>>) => {
    const touched = new Set<WitnessTransport>();
    const witness: WitnessScope = { touch: (transport) => touched.add(transport) };
    const result = await cb(callbackArgs[0], witness);
    // Skip witness when the handler returned an MCP error result.
    // Tools in this codebase use errorResult() which returns
    // { isError: true, content: [...] }; we trust that single boolean.
    const isError =
      typeof result === "object" &&
      result !== null &&
      (result as { isError?: unknown }).isError === true;
    if (!isError) {
      for (const transport of touched) {
        try {
          writeLastInvocation(transport, name);
        } catch {
          // swallow — never propagate witness errors to MCP callers
        }
      }
    }
    return result;
  }) as ToolCallback<Args>;
  server.tool(name, description, paramsSchema, wrapped);
}
