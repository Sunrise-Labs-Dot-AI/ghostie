// Unix-socket JSON-RPC server. Speaks newline-delimited JSON-RPC 2.0.
// Single source of truth for what the MCP binary and the menu bar app
// can ask the daemon to do.
//
// Methods (Phase 1 read-only + recovery):
//   - getThreads({ since?, contact_filter?, limit? })
//   - getThread({ thread_jid, before_ts?, limit? })
//   - searchMessages({ query, since?, contact_filter?, limit? })
//   - getMessageFull({ thread_jid, message_id })
//   - getConnectionStatus()
//   - subscribe(channel)   // "qr" | "state" — server-pushed events
//   - unsubscribe(subscription_id)
//   - unlinkAndReset()     // menu-bar-only; deletes session, clears sentinel
//
// Methods (Phase 2 — drafts/send; placeholder):
//   - stageDraft / getDrafts / getDraft / discardDraft / sendDraft

import { randomUUID } from "node:crypto";
import { createServer, type Server, type Socket } from "node:net";
import { existsSync, unlinkSync } from "node:fs";

import { PATHS } from "../paths.ts";
import type { WhatsAppConnection } from "./connection.ts";
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
  getMessageFull,
  getContactDisplayName,
  formatJidAsPhone,
  getQuotedPreview,
  getQuotedReconstruction,
  getReactionTargetKey,
  sweepOldMessages,
} from "../storage/messages.ts";
import { deleteSession } from "../storage/session.ts";
import {
  type StageInput,
  discardDraft,
  getDraft,
  listDrafts,
  stageDraft,
  updateDraft,
  DraftSchemaError,
} from "../storage/drafts.ts";
import { reserveSend, SEND_ERR, type ReserveErr } from "../storage/audit.ts";
import { readSettings, SettingsError, type Settings } from "../settings.ts";
import { assertSendAllowed, ControlBlockedError } from "../control-gate.ts";
import { isManagedDraftAttachment, verifyManagedDraftAttachment } from "../../../shared/src/attachments.ts";
import { draftPayloadDigest } from "../../../shared/src/draft-payload.ts";

// Per-connection inbound frame cap (#84). A single JSON-RPC frame is
// newline-delimited and tiny in practice; anything past this without a
// newline is treated as abuse (local DoS) and the socket is destroyed.
// Matches the iMessage daemon's 1 MB cap.
export const MAX_FRAME_BYTES = 1_000_000;

const TWO_YEARS_MS = 2 * 365 * 24 * 60 * 60 * 1000;

// Defense-in-depth privacy bounds, enforced HERE in the daemon — not only at
// the MCP schema layer (schema.ts). The MCP is the agent's own trust domain
// and can be bypassed by any socket peer that wins peer-auth; the daemon is
// the last gate before messages.db. List + search reads MUST be scoped by
// either `since` (unix ms, within the last 2 years) or a `contact_filter`
// (>=2 chars), so a raw daemon RPC can't dump unbounded history. Returns an
// error string when the bounds are violated, else null. (issue #78)
//
// Exported for direct unit testing — the dispatch `handle()` takes a live
// WhatsAppConnection, so the bounds gate is tested as a pure function.
export function checkHistoryBounds(since: unknown, contactFilter: unknown): string | null {
  const hasSince = typeof since === "number" && Number.isFinite(since);
  // Match the iMessage daemon: any string (incl. "") is treated as a supplied
  // filter for the "either required" gate, then separately held to the >=2
  // floor below. So an empty/1-char filter fails with the explicit floor error
  // rather than silently widening to an unbounded dump.
  const hasFilter = typeof contactFilter === "string";

  if (!hasSince && !hasFilter) {
    return "either `since` (unix-ms within 2 years) or `contact_filter` (>=2 chars) is required";
  }
  if (hasSince && Date.now() - (since as number) > TWO_YEARS_MS) {
    return "`since` is older than 2 years; deep history requires an explicit opt-in (not supported)";
  }
  if (hasFilter && (contactFilter as string).length < 2) {
    return "`contact_filter` must be at least 2 characters";
  }
  return null;
}

// Optional `limit` bound, enforced in the daemon as well as the MCP schema.
// The WhatsApp read tools pass `limit` optionally (storage applies a default
// when absent), so an absent limit is allowed — but a present one must clear
// the same 1..500 window the schema enforces, so a raw RPC can't request a
// 100k-row page. Returns an error string when violated, else null. (issue #78)
function checkLimit(limit: unknown): string | null {
  if (limit == null) return null;
  if (!Number.isInteger(limit) || (limit as number) < 1 || (limit as number) > 500) {
    return "limit must be an integer 1..500";
  }
  return null;
}

const RPC_ERR = {
  PEER_NOT_AUTHORIZED: -32001,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL: -32603,
  NOT_CONNECTED: -32010,
  // Send-path errors map to specific codes so the MCP layer can
  // surface a stable error name to Claude without parsing strings.
  PENDING_APPROVAL: -32020,
  MIN_AGE_NOT_REACHED: -32021,
  INTER_SEND_TOO_FAST: -32022,
  BURST_LIMIT_HIT: -32023,
  DAILY_CAP_HIT: -32024,
  SEND_FAILED: -32025,
  DRAFT_NOT_FOUND: -32026,
  SETTINGS_ERROR: -32027,
  SEND_BLOCKED: -32028,
  TARGET_NOT_FOUND: -32029,
};

const DIRECT_SEND_SOURCE = "first_party_inline_composer";
const DIRECT_REACTION_SOURCE = "first_party_message_tab";

// Approval is intentionally process-memory-only. A daemon restart requires a
// fresh human approval, and an on-disk `approval_state: approved` bit alone is
// never authority to send a changed payload.
const approvedPayloadDigests = new Map<string, string>();

interface RpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

const DAY_MS = 24 * 60 * 60 * 1000;

export function runMessageRetentionSweep(
  settings: Pick<Settings, "message_retention_days">,
  sweep: (retentionMs: number) => number = sweepOldMessages,
): number {
  return sweep(settings.message_retention_days * DAY_MS);
}

function startMessageRetentionSweep(): Timer {
  const run = () => {
    try {
      const settings = readSettings();
      const deleted = runMessageRetentionSweep(settings);
      if (deleted > 0) {
        process.stderr.write(`message retention sweep deleted ${deleted} old rows\n`);
      }
    } catch (e) {
      process.stderr.write(`message retention sweep skipped: ${(e as Error).message}\n`);
    }
  };
  run();
  return setInterval(run, DAY_MS);
}

export async function startRpcServer(connection: WhatsAppConnection): Promise<RpcServer> {
  // Dev-mode safeguard: refuse to honor WHATSAPP_MCP_DEV in a signed prod binary.
  const safeguard = refuseDevModeInProduction();
  if (!safeguard.allow) {
    throw new Error(safeguard.reason ?? "Dev-mode refused in production");
  }

  // Clean any stale socket from a previous crash.
  if (existsSync(PATHS.daemonSock)) {
    try { unlinkSync(PATHS.daemonSock); } catch { /* ignore */ }
  }

  type Sub = { id: string; channel: "qr" | "state"; sock: Socket };
  const subs = new Map<string, Sub>();

  const broadcast = (channel: "qr" | "state", payload: unknown) => {
    const note: RpcNotification = { jsonrpc: "2.0", method: `${channel}.update`, params: payload };
    const line = JSON.stringify(note) + "\n";
    for (const sub of subs.values()) {
      // qr subscribers also receive state.update broadcasts: the
      // pairing flow inherently cares about the post-scan transition
      // (so the view can auto-dismiss on "connected") AND about the
      // post-pair restartRequired cycle (so the view can stay on
      // "pairingHandshake" rather than time out reading and surface a
      // spurious "connection dropped" error). The contract is
      // documented in menubar/Sources/.../WhatsAppQRSession.swift.
      const wantsThis =
        sub.channel === channel ||
        (channel === "state" && sub.channel === "qr");
      if (wantsThis) {
        try { sub.sock.write(line); } catch { /* peer gone */ }
      }
    }
  };

  connection.on("qr", (qr) => broadcast("qr", { qr }));
  connection.on("state", (s) => broadcast("state", { state: s }));
  connection.on("paired", (info) => broadcast("state", { state: "connected", ...info }));
  let retentionTimer: Timer | null = null;

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
        let req: RpcRequest;
        try {
          req = JSON.parse(line) as RpcRequest;
        } catch {
          return; // ignore malformed lines
        }
        void handle(req, sock, subs, connection).then((resp) => {
          if (resp == null) return; // notifications get no response
          try { sock.write(JSON.stringify(resp) + "\n"); } catch { /* peer gone */ }
        });
      },
      () => sock.destroy(),
    );
    // Push the RAW chunk (Buffer) so the reader caps on BYTE length BEFORE
    // decoding (#84) — a single oversized/multibyte chunk can't be decoded +
    // appended past the byte cap.
    sock.on("data", (chunk: Buffer) => reader.push(chunk));

    sock.on("close", () => {
      // Drop any subscriptions held by this socket.
      for (const [id, sub] of subs.entries()) {
        if (sub.sock === sock) subs.delete(id);
      }
    });
    sock.on("error", () => { /* ignore */ });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(PATHS.daemonSock, () => {
      // Restrict the socket to owner only.
      try {
        // chmod the socket file itself. node:net binds before this runs.
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { chmodSync } = require("node:fs") as typeof import("node:fs");
        chmodSync(PATHS.daemonSock, 0o600);
      } catch { /* ignore */ }
      resolve();
    });
  });

  retentionTimer = startMessageRetentionSweep();

  return {
    stop: async () => {
      if (retentionTimer != null) clearInterval(retentionTimer);
      await new Promise<void>((resolve) => server.close(() => resolve()));
      try { unlinkSync(PATHS.daemonSock); } catch { /* ignore */ }
    },
  };
}

async function handle(
  req: RpcRequest,
  sock: Socket,
  subs: Map<string, { id: string; channel: "qr" | "state"; sock: Socket }>,
  connection: WhatsAppConnection,
): Promise<RpcResponse | null> {
  const id = req.id ?? null;
  try {
    switch (req.method) {
      case "getConnectionStatus": {
        return ok(id, { state: connection.getState(), me: connection.getMe() });
      }
      case "getThreads": {
        const p = (req.params ?? {}) as { since?: number; contact_filter?: string; limit?: number };
        const gtBounds = checkHistoryBounds(p.since, p.contact_filter);
        if (gtBounds) return err(id, RPC_ERR.INVALID_PARAMS, gtBounds);
        const gtLimit = checkLimit(p.limit);
        if (gtLimit) return err(id, RPC_ERR.INVALID_PARAMS, gtLimit);
        return ok(id, { threads: listThreads(p) });
      }
      case "getThread": {
        const p = req.params as { thread_jid: string; before_ts?: number; limit?: number };
        if (typeof p?.thread_jid !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid required");
        // Single-thread read, so no since/contact_filter gate — but a present
        // limit must still clear 1..500 so a raw RPC can't page an entire
        // thread in one shot (issue #78).
        const gtLimit = checkLimit(p.limit);
        if (gtLimit) return err(id, RPC_ERR.INVALID_PARAMS, gtLimit);
        // #78: bound the pagination cursor to the same 2-year window as
        // list/search so an authed peer can't walk a known thread arbitrarily far
        // back via before_ts (unix-ms, matching m.ts). A normal recent read omits
        // before_ts (defaults to "now") or passes a recent one — only deep
        // historical extraction is refused.
        if (typeof p.before_ts === "number" && Number.isFinite(p.before_ts) && Date.now() - p.before_ts > TWO_YEARS_MS) {
          return err(id, RPC_ERR.INVALID_PARAMS, "`before_ts` is older than the 2-year history window");
        }
        return ok(id, { messages: getThreadMessages(p) });
      }
      case "searchMessages": {
        const p = req.params as { query: string; since?: number; contact_filter?: string; limit?: number };
        if (typeof p?.query !== "string" || p.query.length < 2) return err(id, RPC_ERR.INVALID_PARAMS, "query must be ≥2 chars");
        const smBounds = checkHistoryBounds(p.since, p.contact_filter);
        if (smBounds) return err(id, RPC_ERR.INVALID_PARAMS, smBounds);
        const smLimit = checkLimit(p.limit);
        if (smLimit) return err(id, RPC_ERR.INVALID_PARAMS, smLimit);
        return ok(id, { messages: searchMessages(p) });
      }
      case "getMessageFull": {
        const p = req.params as { thread_jid: string; message_id: string };
        if (typeof p?.thread_jid !== "string" || typeof p?.message_id !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid and message_id required");
        }
        const body = getMessageFull(p.thread_jid, p.message_id);
        return ok(id, { body });
      }
      case "downloadMedia": {
        const p = req.params as { thread_jid: string; message_id: string };
        if (typeof p?.thread_jid !== "string" || typeof p?.message_id !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid and message_id required");
        }
        try {
          const { path, mime } = await connection.downloadMedia(p.thread_jid, p.message_id);
          return ok(id, { path, mime });
        } catch (e) {
          return err(id, RPC_ERR.INTERNAL, `media download failed: ${(e as Error).message}`);
        }
      }
      case "subscribe": {
        const p = req.params as { channel: "qr" | "state" };
        if (p?.channel !== "qr" && p?.channel !== "state") {
          return err(id, RPC_ERR.INVALID_PARAMS, "channel must be 'qr' or 'state'");
        }
        const subId = `sub_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
        subs.set(subId, { id: subId, channel: p.channel, sock });
        // Immediately push current state so subscribers don't wait for the next event.
        if (p.channel === "state") {
          const note: RpcNotification = { jsonrpc: "2.0", method: "state.update", params: { state: connection.getState() } };
          sock.write(JSON.stringify(note) + "\n");
        } else if (p.channel === "qr") {
          const qr = connection.getQr();
          if (qr != null) {
            const note: RpcNotification = { jsonrpc: "2.0", method: "qr.update", params: { qr } };
            sock.write(JSON.stringify(note) + "\n");
          }
        }
        return ok(id, { subscription_id: subId });
      }
      case "unsubscribe": {
        const p = req.params as { subscription_id: string };
        subs.delete(p?.subscription_id);
        return ok(id, { ok: true });
      }
      case "unlinkAndReset": {
        deleteSession();
        try { unlinkSync(PATHS.loggedOutSentinel); } catch { /* ignore */ }
        // Reply BEFORE kicking off the async reconnect — Baileys's
        // connect path takes a couple seconds (auth state + version
        // fetch) and the menubar shouldn't be blocked on it.
        setImmediate(() => {
          connection.start().catch((e) => {
            process.stderr.write(`unlinkAndReset → connection.start() failed: ${(e as Error).message}\n`);
          });
        });
        return ok(id, { ok: true, note: "Session wiped; daemon reconnecting." });
      }
      // ──────────────────────────────────────────────────────────────────
      // Phase 2 — Draft + Send
      // ──────────────────────────────────────────────────────────────────
      case "stageDraft": {
        const p = req.params as StageInput;
        if (typeof p?.to_handle !== "string" || typeof p?.body !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "to_handle and body required");
        }
        // Sanity-check attachments shape (the MCP already resolved + size-checked
        // them; this is the daemon-side trust boundary). Empty body is allowed
        // ONLY when at least one attachment is present (media-only message).
        const stageAttachments = Array.isArray(p.attachments) ? p.attachments : [];
        for (const a of stageAttachments) {
          if (!a || typeof a.path !== "string" || a.path.length === 0) {
            return err(id, RPC_ERR.INVALID_PARAMS, "each attachment needs a string path");
          }
        }
        if (p.body.length === 0 && stageAttachments.length === 0) {
          return err(id, RPC_ERR.INVALID_PARAMS, "body must not be empty without attachments");
        }
        if (p.quoted_message_id != null && typeof p.quoted_message_id !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "quoted_message_id must be a string");
        }
        // Resolve the quoted message into a stage-time preview snapshot so the
        // menubar can render "Replying to …" without its own daemon lookup.
        // Null when the message isn't cached — the draft still carries
        // quoted_message_id and the reply is reconstructed at send time.
        const quotedPreview =
          p.quoted_message_id != null && p.quoted_message_id.length > 0
            ? getQuotedPreview(p.to_handle, p.quoted_message_id)
            : null;
        // Pull last 5 messages from messages.db as the context snapshot.
        let ctx: ReturnType<typeof getThreadMessages> = [];
        let diag: "no_thread_match" | "thread_empty" | "error" | null = null;
        try {
          ctx = getThreadMessages({ thread_jid: p.to_handle, limit: 5 });
          if (ctx.length === 0) diag = "thread_empty";
        } catch {
          diag = "error";
        }
        // Resolve a recipient display name at stage time. Caller may have
        // pre-resolved one (an MCP middleware lookup); otherwise pull
        // from contacts/threads tables; otherwise pretty-format the JID.
        // Group JIDs always fall through to thread name → raw JID.
        let resolvedName: string | null = p.to_handle_name ?? null;
        if (resolvedName == null) {
          try {
            resolvedName = getContactDisplayName(p.to_handle);
          } catch { /* DB hiccup — fall through to phone format */ }
        }
        if (resolvedName == null && !p.to_handle.endsWith("@g.us")) {
          // Self-send special case: if the user is messaging themselves,
          // show "You" rather than their own phone number — matches what
          // every other chat app does for the self-thread.
          const meJid = connection.getMe().jid;
          if (meJid != null && p.to_handle === meJid) {
            resolvedName = "You";
          } else {
            resolvedName = formatJidAsPhone(p.to_handle);
          }
        }
        const draft = stageDraft({
          to_handle: p.to_handle,
          to_handle_name: resolvedName,
          body: p.body,
          source: p.source,
          context_messages: ctx.map((m) => ({
            message_id: m.message_id,
            // v0.3.2: write the menubar-side field names directly so
            // ContextMessage Codable parses without compat fallback.
            // sender_name resolved at stage time using the same helper
            // the read-path tools use (gets @lid mapping for free).
            sender_handle: m.sender_jid,
            sender_name: m.from_me ? null : (() => {
              try {
                return getContactDisplayName(m.sender_jid);
              } catch {
                return null;
              }
            })(),
            from_me: m.from_me,
            sent_at: new Date(m.ts).toISOString(),
            body: m.body,
          })),
          context_diagnostic: diag,
          induced_by_unknown_contact: p.induced_by_unknown_contact ?? false,
          quoted_message_id: p.quoted_message_id ?? null,
          quoted_preview: quotedPreview,
          attachments: stageAttachments,
        });
        return ok(id, { draft });
      }
      case "getDrafts": {
        const r = listDrafts();
        return ok(id, r);
      }
      case "getDraft": {
        const p = req.params as { draft_id: string };
        if (typeof p?.draft_id !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "draft_id required");
        try {
          const draft = getDraft(p.draft_id);
          if (draft == null) return err(id, RPC_ERR.DRAFT_NOT_FOUND, `no draft ${p.draft_id}`);
          return ok(id, { draft });
        } catch (e) {
          if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
          throw e;
        }
      }
      case "discardDraft": {
        const p = req.params as { draft_id: string };
        if (typeof p?.draft_id !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "draft_id required");
        try {
          const existed = discardDraft(p.draft_id);
          approvedPayloadDigests.delete(p.draft_id);
          return ok(id, { ok: true, existed });
        } catch (e) {
          if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
          throw e;
        }
      }
      case "approveDraft": {
        // Called by the menu bar app's hold-to-fire BEFORE sendDraft.
        // Also callable from MCP when settings.require_approval = false
        // (the MCP tool side handles that gate).
        const p = req.params as { draft_id: string; expected_payload_digest: string };
        if (typeof p?.draft_id !== "string" || typeof p?.expected_payload_digest !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "draft_id and expected_payload_digest required");
        }
        try {
          const current = getDraft(p.draft_id);
          if (current == null) return err(id, RPC_ERR.DRAFT_NOT_FOUND, `no draft ${p.draft_id}`);
          const digest = payloadDigestForDraft(current);
          if (!digest.ok) return err(id, RPC_ERR.SEND_FAILED, digest.error);
          if (digest.digest !== p.expected_payload_digest) {
            approvedPayloadDigests.delete(p.draft_id);
            return err(id, RPC_ERR.PENDING_APPROVAL, "draft payload changed before approval; review the current draft and approve again");
          }
          const d = updateDraft(p.draft_id, { approval_state: "approved" });
          approvedPayloadDigests.set(p.draft_id, digest.digest);
          return ok(id, { draft: d });
        } catch (e) {
          if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
          throw e;
        }
      }
      case "sendDraft": {
        const p = req.params as { draft_id: string };
        if (typeof p?.draft_id !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "draft_id required");
        return await handleSendDraft(id, p.draft_id, connection);
      }
      case "sendDirectMessage": {
        const p = req.params as { thread_jid: string; body: string; source?: string };
        if (typeof p?.thread_jid !== "string" || typeof p?.body !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid and body required");
        }
        if (p.thread_jid.trim().length === 0) return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid must not be empty");
        if (p.body.trim().length === 0) return err(id, RPC_ERR.INVALID_PARAMS, "body must not be empty");
        if (p.source !== DIRECT_SEND_SOURCE) {
          return err(id, RPC_ERR.INVALID_PARAMS, "source must be first_party_inline_composer");
        }
        return await handleSendDirectMessage(id, p.thread_jid, p.body, p.source, connection);
      }
      case "sendReaction": {
        const p = req.params as { thread_jid: string; message_id: string; emoji: string; source?: string };
        if (typeof p?.thread_jid !== "string" || typeof p?.message_id !== "string" || typeof p?.emoji !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid, message_id, and emoji required");
        }
        if (p.thread_jid.trim().length === 0) return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid must not be empty");
        if (p.message_id.trim().length === 0) return err(id, RPC_ERR.INVALID_PARAMS, "message_id must not be empty");
        if (p.source !== DIRECT_REACTION_SOURCE) {
          return err(id, RPC_ERR.INVALID_PARAMS, "source must be first_party_message_tab");
        }
        return await handleSendDirectReaction(id, p.thread_jid, p.message_id, p.emoji, p.source, connection);
      }
      default:
        return err(id, RPC_ERR.METHOD_NOT_FOUND, `Method not found: ${req.method}`);
    }
  } catch (e) {
    return err(id, RPC_ERR.INTERNAL, (e as Error).message);
  }
}

/**
 * Newline-delimited frame reader with a per-connection BYTE-size cap (#84).
 *
 * Accumulates incoming chunks and emits complete `\n`-delimited frames via
 * `onLine`. The cap is checked on RAW BYTE length BEFORE decoding/appending:
 * if `bufferedBytes + chunk.byteLength > MAX_FRAME_BYTES` we overflow rather
 * than allocating the oversized buffer. (The earlier version measured JS string
 * length AFTER `chunk.toString("utf8")` + append — a single oversized or
 * multibyte chunk could be decoded and allocated past the byte cap before the
 * length check fired.) On overflow it calls `onOverflow` (which destroys the
 * socket) and stops processing. Blank lines are skipped.
 *
 * Chunks are Buffers (the raw socket bytes). We split on the newline byte
 * (0x0A) and only decode COMPLETE frames to UTF-8, so a multibyte codepoint
 * straddling a chunk boundary is still decoded correctly.
 *
 * Extracted as a pure factory so the cap is unit-testable without standing
 * up a real socket + peer-auth.
 */
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

/** SHA-256 of the body, hex-encoded. Audit-only — body itself never logged. */
function bodyHash(body: string): string {
  return new Bun.CryptoHasher("sha256").update(body).digest("hex");
}

export function mapReservationError(id: string | number | null, reservation: ReserveErr): RpcResponse {
  switch (reservation.error) {
    case SEND_ERR.DAILY_CAP_HIT: return err(id, RPC_ERR.DAILY_CAP_HIT, reservation.detail);
    case SEND_ERR.BURST_LIMIT_HIT: return err(id, RPC_ERR.BURST_LIMIT_HIT, reservation.detail);
    case SEND_ERR.INTER_SEND_TOO_FAST: return err(id, RPC_ERR.INTER_SEND_TOO_FAST, reservation.detail);
    default: return err(id, RPC_ERR.SEND_FAILED, "send reservation failed");
  }
}

async function waitSendJitter(): Promise<void> {
  const jitterMs = Math.floor((Math.random() * 2 - 1) * 500);
  if (jitterMs > 0) {
    await new Promise<void>((resolve) => setTimeout(resolve, jitterMs));
  }
}

export async function handleSendDirectMessage(
  id: string | number | null,
  threadJid: string,
  body: string,
  source: string,
  connection: WhatsAppConnection,
): Promise<RpcResponse> {
  if (source !== DIRECT_SEND_SOURCE) {
    return err(id, RPC_ERR.INVALID_PARAMS, "source must be first_party_inline_composer");
  }

  // First-party typed sends use the human's visible composer action as approval;
  // AI/MCP-authored sends still require staged-draft approval. The remote kill
  // switch applies to both paths, so enforce it in the daemon too.
  try {
    assertSendAllowed("whatsapp");
  } catch (e) {
    if (e instanceof ControlBlockedError) return err(id, RPC_ERR.SEND_BLOCKED, e.reason);
    return err(id, RPC_ERR.SEND_BLOCKED, `send blocked: control gate error: ${(e as Error).message}`);
  }

  let settings;
  try {
    settings = readSettings();
  } catch (e) {
    if (e instanceof SettingsError) return err(id, RPC_ERR.SETTINGS_ERROR, e.message);
    throw e;
  }

  const directId = `direct-${randomUUID()}`;
  const reservation = reserveSend({
    draft_id: directId,
    to_handle: threadJid,
    body_sha256: bodyHash(body),
    settings,
  });
  if (!reservation.ok) return mapReservationError(id, reservation);

  await waitSendJitter();

  try {
    const result = await connection.sendText(threadJid, body);
    reservation.commit("ok");
    return ok(id, {
      ok: true,
      draft_id: directId,
      message_id: result.message_id,
      sent_at: new Date().toISOString(),
    });
  } catch (e) {
    reservation.commit("send_failed");
    return err(id, RPC_ERR.SEND_FAILED, (e as Error).message);
  }
}

export async function handleSendDirectReaction(
  id: string | number | null,
  threadJid: string,
  messageId: string,
  emoji: string,
  source: string,
  connection: WhatsAppConnection,
): Promise<RpcResponse> {
  if (source !== DIRECT_REACTION_SOURCE) {
    return err(id, RPC_ERR.INVALID_PARAMS, "source must be first_party_message_tab");
  }

  try {
    assertSendAllowed("whatsapp");
  } catch (e) {
    if (e instanceof ControlBlockedError) return err(id, RPC_ERR.SEND_BLOCKED, e.reason);
    return err(id, RPC_ERR.SEND_BLOCKED, `send blocked: control gate error: ${(e as Error).message}`);
  }

  let settings;
  try {
    settings = readSettings();
  } catch (e) {
    if (e instanceof SettingsError) return err(id, RPC_ERR.SETTINGS_ERROR, e.message);
    throw e;
  }

  const targetKey = getReactionTargetKey(threadJid, messageId);
  if (targetKey == null) {
    return err(id, RPC_ERR.TARGET_NOT_FOUND, "target message is no longer available");
  }

  const directId = `direct-reaction-${randomUUID()}`;
  const reservation = reserveSend({
    draft_id: directId,
    to_handle: threadJid,
    body_sha256: bodyHash(`reaction:${messageId}:${emoji}`),
    settings,
  });
  if (!reservation.ok) return mapReservationError(id, reservation);

  await waitSendJitter();

  try {
    const result = await connection.sendReaction(threadJid, emoji, targetKey);
    reservation.commit("ok");
    return ok(id, {
      ok: true,
      draft_id: directId,
      message_id: result.message_id,
      reacted_to_message_id: messageId,
      sent_at: new Date().toISOString(),
    });
  } catch (e) {
    reservation.commit("send_failed");
    return err(id, RPC_ERR.SEND_FAILED, (e as Error).message);
  }
}

async function handleSendDraft(
  id: string | number | null,
  draftId: string,
  connection: WhatsAppConnection,
): Promise<RpcResponse> {
  // 1. Settings (fail-closed on any error).
  let settings;
  try {
    settings = readSettings();
  } catch (e) {
    if (e instanceof SettingsError) return err(id, RPC_ERR.SETTINGS_ERROR, e.message);
    throw e;
  }

  // 2. Load draft.
  let draft;
  try {
    draft = getDraft(draftId);
  } catch (e) {
    if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
    throw e;
  }
  if (draft == null) return err(id, RPC_ERR.DRAFT_NOT_FOUND, `no draft ${draftId}`);
  if (draft.sent_at != null) return err(id, RPC_ERR.INVALID_PARAMS, "draft already sent");

  const currentDigest = payloadDigestForDraft(draft);
  if (!currentDigest.ok) return err(id, RPC_ERR.SEND_FAILED, currentDigest.error);

  // 3. Approval gate.
  if (draft.approval_state !== "approved") {
    return err(id, RPC_ERR.PENDING_APPROVAL, "draft has not been approved");
  }
  const approvedDigest = approvedPayloadDigests.get(draft.id);
  if (approvedDigest == null || approvedDigest !== currentDigest.digest) {
    approvedPayloadDigests.delete(draft.id);
    return err(id, RPC_ERR.PENDING_APPROVAL, "draft payload is not bound to the current daemon approval; review and approve it again");
  }
  if (draft.delivery_progress.ambiguous_part != null) {
    return err(
      id,
      RPC_ERR.SEND_FAILED,
      `draft has an ambiguous prior wire attempt (${draft.delivery_progress.ambiguous_part}); refusing ordinary retry to prevent duplicates`,
    );
  }

  // 4. Min staged age.
  const stagedMs = Date.parse(draft.staged_at);
  if (Number.isFinite(stagedMs)) {
    const age = Date.now() - stagedMs;
    if (age < settings.min_staged_age_ms) {
      return err(id, RPC_ERR.MIN_AGE_NOT_REACHED, `staged ${age}ms ago, min ${settings.min_staged_age_ms}ms`);
    }
  }

  // 5. Atomic cap + burst + inter-send reservation.
  const reservation = reserveSend({
    draft_id: draft.id,
    to_handle: draft.to_handle,
    body_sha256: bodyHash(draft.body),
    settings,
  });
  if (!reservation.ok) return mapReservationError(id, reservation);

  // 6. Inter-send jitter (±500ms) — burned AFTER reservation so the slot
  // is already counted but Meta's anti-bot heuristics see staggered timing.
  await waitSendJitter();

  // 7. Baileys send with durable per-part progress.
  try {
    // Reply-draft: reconstruct the quoted message from the cache so Baileys
    // threads the reply. Null (quoted message no longer cached) degrades
    // gracefully to a normal message.
    const quoted =
      draft.quoted_message_id != null
        ? getQuotedReconstruction(draft.to_handle, draft.quoted_message_id)
        : null;
    // Attachments + body are one logical send (one reserved slot). Common case
    // — a single captionable file with body text — goes as one captioned media
    // message. Otherwise: each file (quoting only the first), then the body as
    // its own text message. `message_id` is the last message sent.
    const atts = draft.attachments ?? [];
    let progress = draft.delivery_progress;
    let messageId: string;
    if (atts.length === 0) {
      if (!progress.body_sent) {
        progress = updateDraft(draft.id, { delivery_progress: { ...progress, ambiguous_part: "body" } }).delivery_progress;
        const result = await connection.sendText(draft.to_handle, draft.body, quoted);
        messageId = result.message_id;
        progress = updateDraft(draft.id, {
          delivery_progress: { ...progress, body_sent: true, ambiguous_part: null },
        }).delivery_progress;
      } else {
        messageId = "resumed-complete";
      }
    } else {
      const body = draft.body ?? "";
      const firstMime = (atts[0]!.mime_type ?? "").toLowerCase();
      const canCaption = !firstMime.startsWith("audio/");
      if (atts.length === 1 && body.length > 0 && canCaption) {
        if (progress.completed_attachment_count === 1 && progress.body_sent) {
          messageId = "resumed-complete";
        } else {
          if (progress.completed_attachment_count !== 0 || progress.body_sent) {
            throw new Error("combined media-caption delivery progress is inconsistent; discard and restage");
          }
          const verified = verifyManagedDraftAttachment(PATHS.root, draft.id, atts[0]);
          if (!verified.ok) throw new Error(verified.error);
          progress = updateDraft(draft.id, {
            delivery_progress: { ...progress, ambiguous_part: "attachment:0+body" },
          }).delivery_progress;
          const result = await connection.sendMedia(draft.to_handle, verified.attachment, body, quoted);
          messageId = result.message_id;
          progress = updateDraft(draft.id, {
            delivery_progress: { completed_attachment_count: 1, body_sent: true, ambiguous_part: null },
          }).delivery_progress;
        }
      } else {
        let last = "";
        for (let i = progress.completed_attachment_count; i < atts.length; i++) {
          const verified = verifyManagedDraftAttachment(PATHS.root, draft.id, atts[i]);
          if (!verified.ok) throw new Error(verified.error);
          progress = updateDraft(draft.id, {
            delivery_progress: { ...progress, ambiguous_part: `attachment:${i}` },
          }).delivery_progress;
          const r = await connection.sendMedia(draft.to_handle, verified.attachment, null, i === 0 ? quoted : null);
          last = r.message_id;
          progress = updateDraft(draft.id, {
            delivery_progress: { completed_attachment_count: i + 1, body_sent: progress.body_sent, ambiguous_part: null },
          }).delivery_progress;
        }
        if (body.length > 0 && !progress.body_sent) {
          progress = updateDraft(draft.id, {
            delivery_progress: { ...progress, ambiguous_part: "body" },
          }).delivery_progress;
          const r = await connection.sendText(draft.to_handle, body, null);
          last = r.message_id;
          progress = updateDraft(draft.id, {
            delivery_progress: { ...progress, body_sent: true, ambiguous_part: null },
          }).delivery_progress;
        }
        messageId = last || "resumed-complete";
      }
    }
    reservation.commit("ok");
    const sent_at = new Date().toISOString();
    try { updateDraft(draft.id, { sent_at }); } catch { /* draft sweep handles cleanup */ }
    approvedPayloadDigests.delete(draft.id);
    return ok(id, {
      ok: true,
      draft_id: draft.id,
      message_id: messageId,
      sent_at,
    });
  } catch (e) {
    reservation.commit("send_failed");
    return err(id, RPC_ERR.SEND_FAILED, (e as Error).message);
  }
}

function payloadDigestForDraft(
  draft: import("../storage/drafts.ts").Draft,
): { ok: true; digest: string } | { ok: false; error: string } {
  if (!draft.attachments.every(isManagedDraftAttachment)) {
    return { ok: false, error: "legacy or incomplete attachment manifest; discard and restage this draft" };
  }
  return {
    ok: true,
    digest: draftPayloadDigest({
      id: draft.id,
      platform: "whatsapp",
      to_handle: draft.to_handle,
      body: draft.body,
      quoted_message_id: draft.quoted_message_id,
      scheduled_send_at: null,
      attachments: draft.attachments,
    }),
  };
}
