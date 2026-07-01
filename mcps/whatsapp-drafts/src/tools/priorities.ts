// Thread-priority tools — set / clear / list.
//
// These write ~/.whatsapp-mcp/thread-priorities.json directly from the tool
// process (no daemon RPC): the file isn't daemon-owned state, and the menu
// bar app reads it directly to render its priority queue. The on-disk shape
// is a load-bearing contract — see storage/priorities.ts.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { registerWithWitness } from "../witness.ts";
import {
  ClearThreadPriorityInput,
  ClearThreadPriorityShape,
  ListThreadPrioritiesShape,
  SetThreadPriorityInput,
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
// write and read — same trust posture as the draft fields maskDraft wraps.
// Wrap it as data at the response boundary.
function wrapEntryForResponse(entry: ThreadPriorityEntry): ThreadPriorityEntry {
  if (entry.reason === undefined) return entry;
  return { ...entry, reason: wrapUntrusted(entry.reason) ?? undefined };
}

/** @internal exported for unit testing — the registered tool is a thin shell
 *  over this handler (matches the maskDraft tool-test pattern). */
export function _handleSetThreadPriority(rawArgs: unknown) {
  const parsed = SetThreadPriorityInput.safeParse(rawArgs);
  if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
  const args = parsed.data;
  try {
    const { key, entry } = setThreadPriority(args.thread_jid, args.level, args.reason);
    return jsonResult({
      ok: true,
      thread_jid: key,
      priority: wrapEntryForResponse(entry),
      path: threadPrioritiesFile(),
    });
  } catch (e) {
    return errorResult(`set_whatsapp_thread_priority failed: ${(e as Error).message}`);
  }
}

/** @internal exported for unit testing. */
export function _handleClearThreadPriority(rawArgs: unknown) {
  const parsed = ClearThreadPriorityInput.safeParse(rawArgs);
  if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
  try {
    const removed = clearThreadPriority(parsed.data.thread_jid);
    return jsonResult({ ok: true, thread_jid: parsed.data.thread_jid, removed });
  } catch (e) {
    return errorResult(`clear_whatsapp_thread_priority failed: ${(e as Error).message}`);
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
    return errorResult(`list_whatsapp_thread_priorities failed: ${(e as Error).message}`);
  }
}

export function registerPriorityTools(server: McpServer) {
  registerWithWitness(
    server,
    "set_whatsapp_thread_priority",
    {
      description:
        "Mark a WhatsApp thread as a priority in the user's Messages-app priority queue " +
        "(rendered by the Messages for AI menu bar app). `thread_jid` is the JID from " +
        "`list_whatsapp_threads`. `level` is 1–3: 1 = urgent, 2 = high, 3 = elevated — " +
        "lower is more urgent (Linear-style P1/P2/P3). Optionally pass a short `reason` " +
        "(max 200 chars) the user will see next to the thread. Setting a priority on a " +
        "thread that already has one replaces it.",
      inputSchema: SetThreadPriorityShape,
      annotations: {
        title: "Set WhatsApp thread priority",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (rawArgs) => _handleSetThreadPriority(rawArgs),
  );

  registerWithWitness(
    server,
    "clear_whatsapp_thread_priority",
    {
      description:
        "Remove a WhatsApp thread from the user's Messages-app priority queue. Idempotent: " +
        "clearing a thread that has no priority succeeds and reports `removed: false`.",
      inputSchema: ClearThreadPriorityShape,
      annotations: {
        title: "Clear WhatsApp thread priority",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (rawArgs) => _handleClearThreadPriority(rawArgs),
  );

  registerWithWitness(
    server,
    "list_whatsapp_thread_priorities",
    {
      description:
        "List all current WhatsApp thread priorities (the user's Messages-app priority " +
        "queue), keyed by thread_jid. Each entry has `level` (1=urgent, 2=high, 3=elevated), " +
        "`set_at`, `set_by`, and an optional `reason` (wrapped as untrusted data).",
      inputSchema: ListThreadPrioritiesShape,
      annotations: {
        title: "List WhatsApp thread priorities",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => _handleListThreadPriorities(),
  );
}
