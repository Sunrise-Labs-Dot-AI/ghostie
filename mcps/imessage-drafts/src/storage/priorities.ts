// Agent-settable thread priorities. Single JSON file at
// ~/.messages-mcp/thread-priorities.json (mode 0600), keyed by
// String(thread_id) — the chat.db chat ROWID that list_threads/get_thread
// already expose. The menu bar app reads this file DIRECTLY to render its
// priority queue, so the on-disk shape is a LOAD-BEARING contract shared
// with the Swift side:
//
//   {
//     "schema_version": 1,
//     "priorities": {
//       "<key>": {
//         "level": 1,                              // 1=urgent 2=high 3=elevated
//         "reason": "optional, max 200 chars",     // omitted when not provided
//         "set_at": "2026-06-09T22:00:00.000Z",
//         "set_by": "agent"
//       }
//     }
//   }
//
// Lower level = more urgent (Linear-style P1/P2/P3). Writes are atomic
// (temp + rename) with the same symlink guards as the drafts/automations
// stores. No daemon involvement: ~/.messages-mcp isn't FDA-gated, so the
// tool process writes the file itself, exactly like drafts staging does.

import { existsSync, lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const THREAD_PRIORITIES_SCHEMA_VERSION = 1;
export const MAX_PRIORITY_REASON_LENGTH = 200;

/** Who set the priority. "agent" = an MCP tool / Claude; "keep-tabs" = the
 *  menu-bar Keep Tabs watchlist auto-prioritizing a contact who's gone quiet;
 *  "user" = a priority set by hand from the GUI. The Swift reader keys its
 *  auto-clear behavior off this marker (Keep Tabs only ever clears its own
 *  entries, never an agent/user one), so it MUST round-trip faithfully. */
export type ThreadPrioritySource = "agent" | "keep-tabs" | "user";

const KNOWN_PRIORITY_SOURCES = new Set<string>(["agent", "keep-tabs", "user"]);

/** Preserve a known provenance value; legacy entries (no set_by) and any
 *  unrecognized value normalize to "agent" — the historical default. Without
 *  this, the menu bar's keep-tabs / user provenance would be silently rewritten
 *  to "agent" on the next read (any agent tool call rewrites the whole file),
 *  and the auto-clear logic could no longer tell a keep-tabs flag apart from a
 *  human/agent one. */
function normalizePrioritySource(raw: unknown): ThreadPrioritySource {
  return typeof raw === "string" && KNOWN_PRIORITY_SOURCES.has(raw)
    ? (raw as ThreadPrioritySource)
    : "agent";
}

export interface ThreadPriorityEntry {
  /** 1 = urgent, 2 = high, 3 = elevated. Lower = more urgent. */
  level: number;
  /** Optional short agent-supplied justification, capped at 200 chars.
   *  Omitted from the JSON entirely when not provided. */
  reason?: string;
  /** ISO-8601 timestamp of when the priority was (last) set. */
  set_at: string;
  /** Provenance marker (see ThreadPrioritySource). The agent tools in this
   *  package always write "agent"; the menu bar may write "keep-tabs"/"user",
   *  which this store now preserves rather than clobbering. */
  set_by: ThreadPrioritySource;
}

export interface ThreadPrioritiesFile {
  schema_version: number;
  priorities: Record<string, ThreadPriorityEntry>;
}

let testFileOverride: string | null = null;

function prioritiesPath(): string {
  return testFileOverride ?? join(homedir(), ".messages-mcp", "thread-priorities.json");
}

export function _setThreadPrioritiesPathForTesting(path: string | null): void {
  testFileOverride = path;
}

export function threadPrioritiesFile(): string {
  return prioritiesPath();
}

function ensureParentDir(): void {
  const file = prioritiesPath();
  const parent = dirname(file);
  // Same parent-symlink guard as the drafts/automations stores: refuse to
  // let mkdirSync(recursive:true) traverse a pre-symlinked ~/.messages-mcp.
  try {
    if (lstatSync(parent).isSymbolicLink()) {
      throw new Error(`thread-priorities parent directory is a symlink, refusing to use: ${parent}`);
    }
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  mkdirSync(parent, { recursive: true });
}

function isValidLevel(level: unknown): level is number {
  return typeof level === "number" && Number.isInteger(level) && level >= 1 && level <= 3;
}

function normalizeEntry(raw: unknown): ThreadPriorityEntry | null {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
  const e = raw as Partial<ThreadPriorityEntry>;
  if (!isValidLevel(e.level)) return null;
  if (typeof e.set_at !== "string" || Number.isNaN(Date.parse(e.set_at))) return null;
  const entry: ThreadPriorityEntry = {
    level: e.level,
    set_at: e.set_at,
    set_by: normalizePrioritySource(e.set_by),
  };
  if (typeof e.reason === "string" && e.reason.length > 0) {
    entry.reason = e.reason.slice(0, MAX_PRIORITY_REASON_LENGTH);
  }
  return entry;
}

// Load with graceful fallback: a missing or corrupt file (malformed JSON,
// non-object root, unknown schema_version) reads as empty — the next save
// rewrites it in the current schema. Individually malformed entries are
// dropped rather than poisoning the whole file. A symlinked file is the
// one case that still throws: that's an attack posture, not corruption.
export function loadThreadPriorities(): ThreadPrioritiesFile {
  const empty: ThreadPrioritiesFile = { schema_version: THREAD_PRIORITIES_SCHEMA_VERSION, priorities: {} };
  const file = prioritiesPath();
  if (!existsSync(file)) return empty;
  if (lstatSync(file).isSymbolicLink()) {
    throw new Error(`thread-priorities file is a symlink, refusing to read: ${file}`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return empty;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return empty;
  const raw = parsed as Partial<ThreadPrioritiesFile>;
  if (raw.schema_version !== THREAD_PRIORITIES_SCHEMA_VERSION) return empty;
  if (typeof raw.priorities !== "object" || raw.priorities === null || Array.isArray(raw.priorities)) return empty;
  const priorities: Record<string, ThreadPriorityEntry> = {};
  for (const [key, value] of Object.entries(raw.priorities)) {
    const entry = normalizeEntry(value);
    if (entry !== null) priorities[key] = entry;
  }
  return { schema_version: THREAD_PRIORITIES_SCHEMA_VERSION, priorities };
}

function saveThreadPriorities(data: ThreadPrioritiesFile): void {
  ensureParentDir();
  const file = prioritiesPath();
  // Refuse to rename over a symlink — renameSync follows symlinks at the
  // destination, so a pre-planted link could redirect our JSON into an
  // arbitrary user file (same guard as drafts.ts/automations.ts).
  if (existsSync(file) && lstatSync(file).isSymbolicLink()) {
    throw new Error(`thread-priorities file is a symlink, refusing to write: ${file}`);
  }
  const tmp = `${file}.tmp-${randomUUID()}`;
  writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
  try {
    renameSync(tmp, file);
  } catch (err) {
    try { unlinkSync(tmp); } catch { /* best-effort */ }
    throw err;
  }
}

export function setThreadPriority(
  threadId: number,
  level: number,
  reason?: string,
): { key: string; entry: ThreadPriorityEntry } {
  if (!Number.isInteger(threadId) || threadId <= 0) {
    throw new Error(`thread_id must be a positive integer, got ${JSON.stringify(threadId)}`);
  }
  if (!isValidLevel(level)) {
    throw new Error(`level must be an integer between 1 and 3 (1=urgent, 2=high, 3=elevated), got ${JSON.stringify(level)}`);
  }
  const key = String(threadId);
  const entry: ThreadPriorityEntry = {
    level,
    set_at: new Date().toISOString(),
    set_by: "agent",
  };
  const trimmed = reason?.trim();
  if (trimmed) entry.reason = trimmed.slice(0, MAX_PRIORITY_REASON_LENGTH);
  const data = loadThreadPriorities();
  data.priorities[key] = entry;
  saveThreadPriorities(data);
  return { key, entry };
}

/** Remove a thread's priority. Returns whether one existed (idempotent —
 *  clearing an unset thread is a no-op that returns false). */
export function clearThreadPriority(threadId: number): boolean {
  if (!Number.isInteger(threadId) || threadId <= 0) {
    throw new Error(`thread_id must be a positive integer, got ${JSON.stringify(threadId)}`);
  }
  const key = String(threadId);
  const data = loadThreadPriorities();
  if (!(key in data.priorities)) return false;
  delete data.priorities[key];
  saveThreadPriorities(data);
  return true;
}

export function listThreadPriorities(): Record<string, ThreadPriorityEntry> {
  return loadThreadPriorities().priorities;
}
