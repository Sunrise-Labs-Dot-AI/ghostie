// Unix-socket JSON-RPC server for the iMessage daemon. Speaks
// newline-delimited JSON-RPC 2.0 (same wire format as the WhatsApp daemon).
// Single source of truth for what the MCP binary can ask the daemon to do.
//
// All methods are READ-ONLY chat.db / AddressBook lookups — the daemon holds
// Full Disk Access (inherited from the menu-bar app that launches it) and
// performs the reads the Claude-launched MCP can't. Sending + draft files
// stay in the MCP (AppleScript + local JSON, no FDA needed).
//
// Methods:
//   - chatDbDiagnostic()                       → ChatDbDiagnostic
//   - health()                                 → { chatdb, addressbook, contacts_load }
//   - probeHandle({ handle })                  → { input, canonical, resolved_name }
//   - listThreads({ limit, sinceIso?, beforeIso?, contactFilter? })
//   - getThread({ threadId, limit, beforeIso? })
//   - searchMessages({ query, limit, sinceIso?, contactFilter? })
//   - recentContext({ recipientHandle?, threadId?, limit })
//   - resolveDirectChat({ handle })          → ResolvedDirectChat | null

import { createServer, type Server, type Socket } from "node:net";
import { existsSync, unlinkSync, chmodSync } from "node:fs";

import { PATHS } from "./paths.ts";
import { authenticatePeer, refuseDevModeInProduction } from "./peer-auth.ts";
import {
  makeFrameReader as makeSharedFrameReader,
  rpcErr,
  rpcOk,
  type RpcRequest,
  type RpcResponse,
  type RpcServer,
} from "../../../shared/src/rpc.ts";
import {
  listThreads,
  getThreadMessages,
  searchMessages,
  recentContextForRecipient,
  resolveDirectChat,
} from "../chatdb/queries.ts";
import { getChatDbDiagnostic } from "../chatdb/open.ts";
import {
  getAddressBookSqliteDiagnostic,
  getContactsLoadDiagnostic,
  canonHandlePublic,
  resolveHandle,
} from "../chatdb/contacts.ts";

const RPC_ERR = {
  PEER_NOT_AUTHORIZED: -32001,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL: -32603,
};

export const MAX_FRAME_BYTES = 1_000_000;
const TWO_YEARS_MS = 2 * 365 * 24 * 60 * 60 * 1000;

// Defense-in-depth privacy bounds, enforced HERE in the FDA-holding daemon —
// not only at the MCP schema layer (schema.ts / requireSinceOrContactFilter).
// The MCP is the agent's own trust domain and can be bypassed by any socket
// peer that wins peer-auth; the daemon is the last gate before chat.db. List
// + search reads MUST be scoped by either `sinceIso` (within the last 2 years)
// or a `contactFilter` (>=2 chars), so a raw daemon RPC can't dump unbounded
// history. Returns an error string when the bounds are violated, else null.
function checkHistoryBounds(sinceIso: unknown, contactFilter: unknown): string | null {
  const hasSince = typeof sinceIso === "string" && sinceIso.length > 0;
  const hasFilter = typeof contactFilter === "string";

  if (!hasSince && !hasFilter) {
    return "either 'sinceIso' (ISO-8601, within 2 years) or 'contactFilter' (>=2 chars) is required";
  }
  if (hasSince) {
    const t = Date.parse(sinceIso as string);
    if (Number.isNaN(t)) return "sinceIso must be a valid ISO-8601 timestamp";
    if (Date.now() - t > TWO_YEARS_MS) {
      return "sinceIso is older than 2 years; deep history requires an explicit opt-in (not supported)";
    }
  }
  // If a contactFilter is supplied it must clear the >=2-char floor even when a
  // valid `sinceIso` is also present — a 1-char filter is treated as absent at
  // the MCP layer, and the daemon should reject it rather than silently widen.
  if (hasFilter && (contactFilter as string).length < 2) {
    return "contactFilter must be at least 2 characters";
  }
  return null;
}

export async function startRpcServer(): Promise<RpcServer> {
  const safeguard = refuseDevModeInProduction();
  if (!safeguard.allow) {
    throw new Error(safeguard.reason ?? "Dev-mode refused in production");
  }

  // Clean any stale socket from a previous crash.
  if (existsSync(PATHS.daemonSock)) {
    try { unlinkSync(PATHS.daemonSock); } catch { /* ignore */ }
  }

  const server: Server = createServer();

  server.on("connection", async (sock) => {
    const auth = await authenticatePeer(sock);
    if (!auth.authorized) {
      const err: RpcResponse = {
        jsonrpc: "2.0",
        id: null,
        error: { code: RPC_ERR.PEER_NOT_AUTHORIZED, message: auth.reason ?? "peer not authorized" },
      };
      try { sock.write(JSON.stringify(err) + "\n"); } catch { /* ignore */ }
      sock.end();
      return;
    }

    const reader = makeFrameReader(
      (line) => {
        if (line.trim().length === 0) return;
        let req: RpcRequest;
        try {
          req = JSON.parse(line) as RpcRequest;
        } catch {
          return; // ignore malformed lines
        }
        const resp = handle(req);
        try { sock.write(JSON.stringify(resp) + "\n"); } catch { /* peer gone */ }
      },
      () => sock.destroy(),
    );
    sock.on("data", (chunk: Buffer) => reader.push(chunk));
    sock.on("error", () => { /* ignore */ });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(PATHS.daemonSock, () => {
      try { chmodSync(PATHS.daemonSock, 0o600); } catch { /* ignore */ }
      resolve();
    });
  });

  return {
    stop: async () => {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      try { unlinkSync(PATHS.daemonSock); } catch { /* ignore */ }
    },
  };
}

// Exported for unit testing the dispatch/validation logic directly, without
// standing up a socket + peer-auth. Production callers go through the socket.
export function handle(req: RpcRequest): RpcResponse {
  const id = req.id ?? null;
  try {
    switch (req.method) {
      case "chatDbDiagnostic": {
        return ok(id, getChatDbDiagnostic());
      }
      case "health": {
        return ok(id, {
          chatdb: getChatDbDiagnostic(),
          addressbook: getAddressBookSqliteDiagnostic(),
          contacts_load: getContactsLoadDiagnostic(),
        });
      }
      case "probeHandle": {
        const p = req.params as { handle?: unknown };
        if (typeof p?.handle !== "string" || p.handle.length === 0) {
          return err(id, RPC_ERR.INVALID_PARAMS, "handle (non-empty string) required");
        }
        return ok(id, {
          input: p.handle,
          canonical: canonHandlePublic(p.handle),
          resolved_name: resolveHandle(p.handle),
        });
      }
      case "listThreads": {
        const p = (req.params ?? {}) as {
          limit?: unknown; sinceIso?: unknown; beforeIso?: unknown; contactFilter?: unknown;
        };
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        const ltBounds = checkHistoryBounds(p.sinceIso, p.contactFilter);
        if (ltBounds) return err(id, RPC_ERR.INVALID_PARAMS, ltBounds);
        return ok(id, listThreads({
          limit: p.limit as number,
          sinceIso: typeof p.sinceIso === "string" ? p.sinceIso : undefined,
          beforeIso: typeof p.beforeIso === "string" ? p.beforeIso : undefined,
          contactFilter: typeof p.contactFilter === "string" ? p.contactFilter : undefined,
        }));
      }
      case "getThread": {
        const p = (req.params ?? {}) as { threadId?: unknown; limit?: unknown; beforeIso?: unknown };
        if (!Number.isInteger(p.threadId) || (p.threadId as number) < 1) return err(id, RPC_ERR.INVALID_PARAMS, "threadId must be a positive integer");
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        // Issue #78 (round 2): a single-thread read was the one read path NOT
        // subject to the bounded-history rule — `beforeIso` could page
        // arbitrarily far back, letting an authed peer extract a thread's entire
        // multi-year history one 500-message page at a time. We bound the
        // historical reach: a `beforeIso` cursor older than the 2-year window
        // (the same window listThreads/searchMessages enforce) is rejected.
        // DECISION: cap the pagination FLOOR rather than the per-call limit
        // (already 1..500) — normal use reads the most recent N messages
        // (no `beforeIso`, or a recent cursor) and is unaffected; only
        // deep-history walks are stopped. If `beforeIso` is malformed we reject
        // rather than silently widen to "all history".
        const beforeIso = typeof p.beforeIso === "string" && p.beforeIso.length > 0 ? p.beforeIso : undefined;
        if (beforeIso !== undefined) {
          const t = Date.parse(beforeIso);
          if (Number.isNaN(t)) return err(id, RPC_ERR.INVALID_PARAMS, "beforeIso must be a valid ISO-8601 timestamp");
          if (Date.now() - t > TWO_YEARS_MS) {
            return err(
              id,
              RPC_ERR.INVALID_PARAMS,
              "beforeIso is older than 2 years; getThread does not page beyond the 2-year window (deep history requires an explicit opt-in, not supported)"
            );
          }
        }
        return ok(id, getThreadMessages({
          threadId: p.threadId as number,
          limit: p.limit as number,
          beforeIso,
        }));
      }
      case "searchMessages": {
        const p = (req.params ?? {}) as {
          query?: unknown; limit?: unknown; sinceIso?: unknown; contactFilter?: unknown;
        };
        if (typeof p.query !== "string" || p.query.length < 2) return err(id, RPC_ERR.INVALID_PARAMS, "query (>=2 chars) required");
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        const smBounds = checkHistoryBounds(p.sinceIso, p.contactFilter);
        if (smBounds) return err(id, RPC_ERR.INVALID_PARAMS, smBounds);
        return ok(id, searchMessages({
          query: p.query,
          limit: p.limit as number,
          sinceIso: typeof p.sinceIso === "string" ? p.sinceIso : undefined,
          contactFilter: typeof p.contactFilter === "string" ? p.contactFilter : undefined,
        }));
      }
      case "recentContext": {
        const p = (req.params ?? {}) as { recipientHandle?: unknown; threadId?: unknown; limit?: unknown };
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        return ok(id, recentContextForRecipient({
          recipientHandle: typeof p.recipientHandle === "string" ? p.recipientHandle : undefined,
          threadId: typeof p.threadId === "number" ? p.threadId : undefined,
          limit: p.limit as number,
        }));
      }
      case "resolveDirectChat": {
        // 1:1 send routing: resolve the recipient's existing addressable chat
        // so the MCP can send by `chat id` (real transport) instead of guessing
        // iMessage via the buddy cascade. Returns null when there's no
        // addressable single-participant chat — the MCP then falls back to the
        // buddy cascade. A single handle is not bounded-history-sensitive (it's
        // a membership lookup, not a content read), so no checkHistoryBounds.
        const p = req.params as { handle?: unknown };
        if (typeof p?.handle !== "string" || p.handle.length === 0) {
          return err(id, RPC_ERR.INVALID_PARAMS, "handle (non-empty string) required");
        }
        return ok(id, resolveDirectChat(p.handle));
      }
      default:
        return err(id, RPC_ERR.METHOD_NOT_FOUND, `Method not found: ${req.method}`);
    }
  } catch (e) {
    return err(id, RPC_ERR.INTERNAL, (e as Error).message);
  }
}

export function makeFrameReader(
  onLine: (line: string) => void,
  onOverflow: () => void,
): { push(chunk: Buffer | Uint8Array | string): void } {
  return makeSharedFrameReader(MAX_FRAME_BYTES, onLine, onOverflow);
}

function ok(id: string | number | null, result: unknown): RpcResponse {
  return rpcOk(id, result);
}
function err(id: string | number | null, code: number, message: string): RpcResponse {
  return rpcErr(id, code, message);
}
