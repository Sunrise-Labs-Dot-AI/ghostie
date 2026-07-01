// Thread-priority tools — set / clear / list.
//
// These write ~/.messages-mcp/thread-priorities.json directly from the tool
// process (no daemon RPC): the file lives outside the FDA-gated chat.db
// surface, same as drafts staging. The menu bar app reads the file directly
// to render its priority queue, so the on-disk shape is a load-bearing
// contract — see storage/priorities.ts.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerWithWitness } from "../witness.ts";
import {
  ClearThreadPriorityShape,
  ListThreadPrioritiesShape,
  SetThreadPriorityShape,
} from "../schema.ts";
import {
  clearThreadPriority,
  listThreadPriorities,
  setThreadPriority,
  threadPrioritiesFile,
  type ThreadPriorityEntry,
} from "../storage/priorities.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapUntrusted } from "./_untrusted.ts";

// The reason is agent-authored at write time, but it round-trips through a
// user-home JSON file that any local process (or the user) can edit between
// write and read — same trust posture as automations.json, whose title/body
// get wrapped on the way out. Wrap it as data at the response boundary.
function wrapEntryForResponse(entry: ThreadPriorityEntry): ThreadPriorityEntry {
  if (entry.reason === undefined) return entry;
  return { ...entry, reason: wrapUntrusted(entry.reason) ?? undefined };
}

/** @internal exported for unit testing — the registered tool is a thin shell
 *  over this handler (matches the health/drafts tool-test pattern). */
export function _handleSetThreadPriority(args: { thread_id: number; level: number; reason?: string }) {
  try {
    const { key, entry } = setThreadPriority(args.thread_id, args.level, args.reason);
    return jsonResult({
      ok: true,
      thread_id: args.thread_id,
      key,
      priority: wrapEntryForResponse(entry),
      path: threadPrioritiesFile(),
    });
  } catch (e) {
    return errorResult(`set_thread_priority failed: ${(e as Error).message}`);
  }
}

/** @internal exported for unit testing. */
export function _handleClearThreadPriority(args: { thread_id: number }) {
  try {
    const removed = clearThreadPriority(args.thread_id);
    return jsonResult({ ok: true, thread_id: args.thread_id, removed });
  } catch (e) {
    return errorResult(`clear_thread_priority failed: ${(e as Error).message}`);
  }
}

/** @internal exported for unit testing. */
export function _handleListThreadPriorities() {
  try {
    const priorities = listThreadPriorities();
    const wrapped: Record<string, ThreadPriorityEntry> = {};
    for (const [key, entry] of Object.entries(priorities)) {
      wrapped[key] = wrapEntryForResponse(entry);
    }
    return jsonResult({
      ok: true,
      path: threadPrioritiesFile(),
      count: Object.keys(wrapped).length,
      priorities: wrapped,
    });
  } catch (e) {
    return errorResult(`list_thread_priorities failed: ${(e as Error).message}`);
  }
}

export function registerPriorityTools(server: McpServer): void {
  registerWithWitness(
    server,
    "set_thread_priority",
    {
      title: "Set iMessage thread priority",
      description:
        "Mark an iMessage thread as a priority in the user's Messages-app priority queue " +
        "(rendered by the Messages for AI menu bar app). `thread_id` is the numeric id from " +
        "`list_threads`/`get_thread`. `level` is 1–3: 1 = urgent, 2 = high, 3 = elevated — " +
        "lower is more urgent (Linear-style P1/P2/P3). Optionally pass a short `reason` " +
        "(max 200 chars) the user will see next to the thread. Setting a priority on a " +
        "thread that already has one replaces it.",
      inputSchema: SetThreadPriorityShape,
      annotations: {
        title: "Set thread priority",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (args) => _handleSetThreadPriority(args),
  );

  registerWithWitness(
    server,
    "clear_thread_priority",
    {
      title: "Clear iMessage thread priority",
      description:
        "Remove a thread from the user's Messages-app priority queue. Idempotent: clearing a " +
        "thread that has no priority succeeds and reports `removed: false`.",
      inputSchema: ClearThreadPriorityShape,
      annotations: {
        title: "Clear thread priority",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (args) => _handleClearThreadPriority(args),
  );

  registerWithWitness(
    server,
    "list_thread_priorities",
    {
      title: "List iMessage thread priorities",
      description:
        "List all current thread priorities (the user's Messages-app priority queue), keyed by " +
        "thread_id. Each entry has `level` (1=urgent, 2=high, 3=elevated), `set_at`, `set_by`, " +
        "and an optional `reason` (wrapped as untrusted data).",
      inputSchema: ListThreadPrioritiesShape,
      annotations: {
        title: "List thread priorities",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => _handleListThreadPriorities(),
  );
}
