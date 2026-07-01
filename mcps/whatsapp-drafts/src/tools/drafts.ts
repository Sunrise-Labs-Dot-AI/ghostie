// MCP draft tools — stage / list / get / discard / send.
//
// Send path:
//   - If settings.require_approval = true (default), MCP send returns
//     PENDING_APPROVAL — the menu bar app's hold-to-fire is the only path
//     that can flip the draft to "approved".
//   - If settings.require_approval = false (a user opts in for fully
//     automated sends), the MCP tool calls daemon.approveDraft itself
//     immediately before invoking daemon.sendDraft.
//
// Daemon errors map to clear MCP error messages. The RPC error CODES
// (-32020..-32027) are propagated so a smart client can switch on them,
// but we always also include a human-readable message.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { callDaemon, DaemonRpcError } from "../daemon/rpc-client.ts";
import { registerWithWitness } from "../witness.ts";
import { DraftIdInput, DraftIdShape, StageDraftInput, StageDraftShape } from "../schema.ts";
import type { Settings } from "../settings.ts";
import { readSettings, SettingsError } from "../settings.ts";
import { acquireSendLock } from "../storage/send-lock.ts";
import { assertSendAllowed, ControlBlockedError } from "../control-gate.ts";
import { resolveDraftAttachments, type ResolvedAttachment } from "../../../shared/src/attachments.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapBodyInPlace, wrapUntrusted } from "./_untrusted.ts";
import { mapDaemonDependentToolError } from "./_daemon-errors.ts";

const RPC_CODE = {
  PENDING_APPROVAL: -32020,
  MIN_AGE_NOT_REACHED: -32021,
  INTER_SEND_TOO_FAST: -32022,
  BURST_LIMIT_HIT: -32023,
  DAILY_CAP_HIT: -32024,
  SEND_FAILED: -32025,
  DRAFT_NOT_FOUND: -32026,
  SETTINGS_ERROR: -32027,
};

const RPC_NAME: Record<number, string> = {
  [RPC_CODE.PENDING_APPROVAL]: "PENDING_APPROVAL",
  [RPC_CODE.MIN_AGE_NOT_REACHED]: "MIN_AGE_NOT_REACHED",
  [RPC_CODE.INTER_SEND_TOO_FAST]: "INTER_SEND_TOO_FAST",
  [RPC_CODE.BURST_LIMIT_HIT]: "BURST_LIMIT_HIT",
  [RPC_CODE.DAILY_CAP_HIT]: "DAILY_CAP_HIT",
  [RPC_CODE.SEND_FAILED]: "SEND_FAILED",
  [RPC_CODE.DRAFT_NOT_FOUND]: "DRAFT_NOT_FOUND",
  [RPC_CODE.SETTINGS_ERROR]: "SETTINGS_ERROR",
};

export interface DraftRpc {
  id: string;
  schema_version: number;
  platform: "whatsapp";
  approval_state: "pending" | "approved";
  to_handle: string;
  /** Best-effort recipient display name resolved at stage time. Attacker-
   *  controlled: it comes from the contact's WhatsApp profile (display_name /
   *  push_name) or a caller-supplied to_handle_name, neither of which passes
   *  through the storage-layer body sanitizer — so it MUST be wrapped as
   *  untrusted at the response boundary (#87). */
  to_handle_name: string | null;
  body: string;
  staged_at: string;
  sent_at: string | null;
  source: string;
  context_messages: Array<{
    message_id: string;
    sender_handle: string;
    sender_name: string | null;
    from_me: boolean;
    sent_at: string;
    body: string | null;
  }>;
  context_diagnostic: null | "no_thread_match" | "thread_empty" | "error";
  induced_by_unknown_contact: boolean;
  quoted_message_id: string | null;
  quoted_preview: {
    message_id: string;
    body: string | null;
    from_me: boolean;
    sender_name: string | null;
  } | null;
  // Files to send with this draft. Resolved (absolute path + size + mime) at
  // stage time; the daemon reads the bytes and picks the Baileys media type at
  // send. Empty for text-only drafts. Older draft files lack this field.
  attachments?: ResolvedAttachment[];
}

/** Wrap untrusted fields (peer-authored context messages) but leave
 *  the agent-authored `body` clean.
 *
 *  Both message bodies AND sender_name are peer-controlled: sender_name
 *  comes from the WhatsApp contact's profile (display_name / push_name in
 *  the contacts table, populated from Baileys contact events). A contact
 *  who sets their profile name to a tag-close payload could otherwise
 *  inject directives into the model's view of the staged draft. The
 *  sanitizeIncomingBody pass at write time (in storage/messages.ts) does
 *  NOT cover contact names — they go through the contacts table on a
 *  different path — so the wrap is essential at the MCP response
 *  boundary. */
/** @internal exported for unit testing the untrusted-wrapping boundary (#87). */
export function maskDraft(d: DraftRpc): DraftRpc {
  return {
    ...d,
    // to_handle_name is attacker-controlled recipient/profile data (#87) — it
    // is spread through to the staged/listed/get draft output and never passed
    // through the storage-layer sanitizer, so wrap it as untrusted here.
    to_handle_name: d.to_handle_name == null ? null : wrapUntrusted(d.to_handle_name),
    context_messages: d.context_messages.map((m) => ({
      ...m,
      body: m.body == null ? null : wrapBodyInPlace({ body: m.body }).body,
      sender_name: m.sender_name == null ? null : wrapUntrusted(m.sender_name),
    })),
    // quoted_preview mirrors a peer message — wrap body + sender_name too.
    quoted_preview:
      d.quoted_preview == null
        ? null
        : {
            ...d.quoted_preview,
            body: d.quoted_preview.body == null ? null : wrapUntrusted(d.quoted_preview.body),
            sender_name:
              d.quoted_preview.sender_name == null ? null : wrapUntrusted(d.quoted_preview.sender_name),
          },
  };
}

export function registerDraftTools(server: McpServer) {
  registerWithWitness(
    server,
    "stage_whatsapp_draft",
    {
      description:
        "Stage an outbound WhatsApp message as a DRAFT (does NOT send). The user " +
        "approves via the menu bar app's hold-to-fire (Phase 3) or, if " +
        "settings.require_approval is OFF, via send_whatsapp_draft. Drafts " +
        "include a 5-message thread-context snapshot for the approval surface. " +
        "Pass `attachments` (array of `{path, filename?, mime_type?}`) to send photos/" +
        "videos/documents/audio — each `path` must exist on disk now. The body may be " +
        "empty when attachments are present (it becomes the media caption).",
      inputSchema: StageDraftShape,
    },
    async (raw) => {
      const parsed = StageDraftInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      const resolved = resolveDraftAttachments(parsed.data.attachments);
      if (!resolved.ok) return errorResult(resolved.error);
      if (parsed.data.body.trim().length === 0 && resolved.attachments.length === 0) {
        return errorResult("provide a non-empty `body`, one or more `attachments`, or both");
      }
      try {
        const { draft } = await callDaemon<{ draft: DraftRpc }>("stageDraft", {
          ...parsed.data,
          attachments: resolved.attachments,
        });
        return jsonResult({ ok: true, draft: maskDraft(draft) });
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "list_whatsapp_drafts",
    {
      description:
        "List currently-staged drafts, newest-first. Drafts with sent_at set " +
        "are returned until the daemon's daily sweep purges them.",
    },
    async () => {
      try {
        const r = await callDaemon<{ drafts: DraftRpc[]; skipped: number }>("getDrafts");
        return jsonResult({ ok: true, drafts: r.drafts.map(maskDraft), skipped: r.skipped });
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "get_whatsapp_draft",
    {
      description: "Retrieve a single staged draft by id.",
      inputSchema: DraftIdShape,
    },
    async (raw) => {
      const parsed = DraftIdInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      try {
        const { draft } = await callDaemon<{ draft: DraftRpc }>("getDraft", parsed.data);
        return jsonResult({ ok: true, draft: maskDraft(draft) });
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "discard_whatsapp_draft",
    {
      description: "Delete a staged draft. The draft must not have been sent.",
      inputSchema: DraftIdShape,
    },
    async (raw) => {
      const parsed = DraftIdInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      try {
        const r = await callDaemon<{ ok: true; existed: boolean }>("discardDraft", parsed.data);
        return jsonResult(r);
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "send_whatsapp_draft",
    {
      description:
        "Send a previously-staged WhatsApp draft. Subject to the full check ladder: " +
        "approval-gate (default ON), minimum staged age, inter-send delay, " +
        "burst limit, daily cap. Returns explicit error codes so callers can " +
        "distinguish 'not approved' from 'cap hit' from 'send failed'.",
      inputSchema: DraftIdShape,
    },
    async (raw) => {
      const parsed = DraftIdInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));

      // Issue #76: consult the cloud kill switch / forced-upgrade floor BEFORE
      // anything else — before acquiring the send lock, approving, or touching
      // the daemon. The Swift SendGate blocks the menu-bar hold-to-fire path;
      // this closes the OTHER path (the MCP tool calling the daemon directly
      // when require_approval is off). Re-verifies the manifest's Ed25519
      // signature on disk, so a same-UID forged manifest can't lift a kill.
      try {
        assertSendAllowed("whatsapp");
      } catch (e) {
        if (e instanceof ControlBlockedError) return errorResult(e.reason);
        // A non-block error from the gate must NOT silently allow a send.
        return errorResult(`send blocked: control gate error: ${(e as Error).message}`);
      }

      // Issue #88: serialize the whole approve → send sequence behind a
      // cross-process, per-draft lock so a menu-bar hold-to-fire and an MCP
      // send (or a second MCP instance — Claude Desktop + Claude Code both
      // load this MCP) of the SAME draft can't both reach the daemon and both
      // fire Baileys. The lock lives at ~/.messages-mcp/locks/<draft-id>.lock;
      // the Swift menu bar app acquires the SAME file before its send. We lock
      // in the INITIATOR (here), not in the daemon, so a Swift lock-holder
      // calling the daemon doesn't deadlock against the daemon re-grabbing it.
      // Non-blocking: a concurrent send is refused, not queued.
      const lock = acquireSendLock(parsed.data.draft_id);
      if (lock == null) {
        return errorResult(
          `send blocked: another send for draft ${parsed.data.draft_id} is already in flight ` +
          `(cross-process send lock held). Refusing a concurrent send to avoid duplicate delivery. ` +
          `If you believe this is stale, wait a moment and retry.`
        );
      }
      try {
        // Read settings on THIS side too so we can pre-approve when
        // require_approval is OFF. (The daemon also reads settings inside
        // sendDraft for the rate-limit checks.)
        let settings: Settings;
        try {
          settings = readSettings();
        } catch (e) {
          if (e instanceof SettingsError) return errorResult(`SETTINGS_ERROR: ${e.message}`);
          throw e;
        }

        if (!settings.require_approval) {
          // Flip approval_state for the user. In production this happens
          // via the menu bar app's hold-to-fire UI.
          try {
            await callDaemon("approveDraft", parsed.data);
          } catch (e) {
            return mapDaemonError(e);
          }
        }

        try {
          const r = await callDaemon<{
            ok: true;
            draft_id: string;
            message_id: string;
            sent_at: string;
          }>("sendDraft", parsed.data);
          return jsonResult(r);
        } catch (e) {
          return mapDaemonError(e);
        }
      } finally {
        // Always release the per-draft send lock — including the early returns
        // above (settings error, approve failure) and any throw.
        lock.release();
      }
    },
  );
}

function mapDaemonError(e: unknown) {
  if (e instanceof DaemonRpcError) {
    const name = RPC_NAME[e.code];
    if (name != null) return errorResult(`${name}: ${e.message}`);
  }
  return errorResult(mapDaemonDependentToolError(e));
}
