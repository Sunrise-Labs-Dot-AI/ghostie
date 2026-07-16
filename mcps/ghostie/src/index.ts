#!/usr/bin/env bun
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import { callDaemon as callIMessageDaemon } from "../../imessage-drafts/src/daemon/rpc-client.ts";
import {
  classifyAttachmentKind,
  type AttachmentKind,
  type ListThreadsResult as IMessageListThreadsResult,
  type MessageAttachment as IMessageAttachment,
  type ThreadMessage as IMessageThreadMessage,
} from "../../imessage-drafts/src/chatdb/queries.ts";
import {
  discardDraft as discardIMessageDraft,
  getDraft as getIMessageDraft,
  listDrafts as listIMessageDrafts,
} from "../../imessage-drafts/src/storage/drafts.ts";
import {
  _wrapDraftForResponse as wrapIMessageDraft,
  stageIMessageDraft,
} from "../../imessage-drafts/src/tools/drafts.ts";
import {
  clearThreadPriority as clearIMessageThreadPriority,
  listThreadPriorities as listIMessageThreadPriorities,
  setThreadPriority as setIMessageThreadPriority,
} from "../../imessage-drafts/src/storage/priorities.ts";

import { callDaemon as callWhatsAppDaemon } from "../../whatsapp-drafts/src/daemon/rpc-client.ts";
import {
  maskDraft as maskWhatsAppDraft,
  stageWhatsAppDraft,
  type DraftRpc as WhatsAppDraft,
} from "../../whatsapp-drafts/src/tools/drafts.ts";
import {
  clearThreadPriority as clearWhatsAppThreadPriority,
  listThreadPriorities as listWhatsAppThreadPriorities,
  setThreadPriority as setWhatsAppThreadPriority,
} from "../../whatsapp-drafts/src/storage/priorities.ts";

import { DaemonRpcError, DaemonUnavailableError } from "../../shared/src/daemon-client.ts";
import { errorResult, jsonResult } from "../../shared/src/mcp-result.ts";
import { wrapBodyInPlace, wrapUntrusted } from "../../shared/src/untrusted.ts";
import { registerWithWitness, setChatDbAccessProbe } from "./witness.ts";

type Platform = "imessage" | "whatsapp";
type PlatformOrAll = Platform | "all";
type AccessIssue = { platform: Platform; error: string };

const TWO_YEARS_MS = 2 * 365 * 24 * 60 * 60 * 1000;
const IMESSAGE_DRAFT_BODY_MAX = 20_000;
const WHATSAPP_DRAFT_BODY_MAX = 60_000;

const iso8601 = z
  .string()
  .refine((s) => !Number.isNaN(Date.parse(s)), { message: "must be a valid ISO-8601 timestamp" });

const sinceNotDeepHistory = iso8601.refine(
  (s) => {
    const t = Date.parse(s);
    return t <= Date.now() && Date.now() - t <= TWO_YEARS_MS;
  },
  { message: "since must be within the last 2 years and not in the future" },
);

const contactFilter = z.string().min(2, "contact_filter must be at least 2 characters");
const uuid = z.string().uuid();
const PlatformShape = z.enum(["imessage", "whatsapp"]);
const PlatformOrAllShape = z.enum(["imessage", "whatsapp", "all"]);
const IMESSAGE_HANDLE_RE = /@|^\+?\d[\d\s\-().]{5,}$/;
const WHATSAPP_JID_RE = /^[^@\s]+@[^@\s]+$/;

const ListThreadsShape = {
  platform: PlatformOrAllShape.default("all"),
  since: sinceNotDeepHistory.optional(),
  before: iso8601.optional(),
  contact_filter: contactFilter.optional(),
  limit: z.number().int().min(1).max(100).default(25),
} as const;

const GetThreadShape = {
  thread_ref: z.string().min(1).describe("Stable generalized ref, e.g. imessage:123 or whatsapp:12025550001@s.whatsapp.net"),
  limit: z.number().int().min(1).max(200).default(50),
  before: iso8601.optional(),
} as const;

const SearchShape = {
  platform: PlatformOrAllShape.default("all"),
  query: z.string().min(2, "query must be at least 2 characters"),
  since: sinceNotDeepHistory.optional(),
  contact_filter: contactFilter.optional(),
  limit: z.number().int().min(1).max(100).default(25),
} as const;

const DraftAttachmentShape = z.object({
  path: z.string().min(1).max(4096),
  filename: z.string().min(1).max(255).optional(),
  mime_type: z.string().min(1).max(255).optional(),
});

const StageDraftShape = {
  platform: PlatformShape,
  to_handle: z.string().min(1),
  // Empty allowed only when `attachments` is non-empty (media-only message).
  body: z.string().max(WHATSAPP_DRAFT_BODY_MAX),
  // Photos / videos / files to send with the draft. Each `path` must exist on
  // disk now. Sent before the body so the text reads as a caption. Max 10.
  attachments: z.array(DraftAttachmentShape).max(10).optional(),
  source: z.string().min(1).max(200).optional(),
  in_reply_to_thread_ref: z.string().min(1).optional(),
  quoted_message_id: z.string().min(1).optional(),
} as const;

const DraftRefShape = {
  draft_ref: z.string().min(1).describe("Stable generalized ref, e.g. imessage:<uuid> or whatsapp:<uuid>"),
} as const;

const ListDraftsShape = {
  platform: PlatformOrAllShape.default("all"),
  limit: z.number().int().min(1).max(100).default(25),
} as const;

const SetPriorityShape = {
  thread_ref: z.string().min(1),
  level: z.number().int().min(1).max(3),
  reason: z.string().min(1).max(200).optional(),
} as const;

const ListPrioritiesShape = {
  platform: PlatformOrAllShape.default("all"),
} as const;

function requireScope(args: { since?: string; contact_filter?: string }): string | null {
  if (!args.since && !args.contact_filter) {
    return "either 'since' (ISO-8601, within 2 years) or 'contact_filter' (>=2 chars) is required";
  }
  return null;
}

function validateStageTarget(platform: Platform, toHandle: string): string | null {
  if (platform === "imessage" && !IMESSAGE_HANDLE_RE.test(toHandle)) {
    return "iMessage to_handle must look like an email address or phone number";
  }
  if (platform === "whatsapp" && !WHATSAPP_JID_RE.test(toHandle)) {
    return "WhatsApp to_handle must look like a JID, e.g. 12025550001@s.whatsapp.net or 12036xx@g.us";
  }
  return null;
}

function platforms(scope: PlatformOrAll): Platform[] {
  return scope === "all" ? ["imessage", "whatsapp"] : [scope];
}

function ref(platform: Platform, id: string | number): string {
  return `${platform}:${String(id)}`;
}

function parseRef(value: string, expected?: Platform): { platform: Platform; id: string } | { error: string } {
  const idx = value.indexOf(":");
  if (idx <= 0) return { error: "ref must look like imessage:<id> or whatsapp:<id>" };
  const platform = value.slice(0, idx);
  const id = value.slice(idx + 1);
  if (platform !== "imessage" && platform !== "whatsapp") {
    return { error: "ref platform must be 'imessage' or 'whatsapp'" };
  }
  if (expected && platform !== expected) {
    return { error: `ref platform ${platform} does not match requested platform ${expected}` };
  }
  if (id.length === 0) return { error: "ref id must not be empty" };
  return { platform, id };
}

function parseThreadRef(value: string, expected?: Platform): { platform: Platform; id: string; imessageThreadId?: number } | { error: string } {
  const parsed = parseRef(value, expected);
  if ("error" in parsed) return parsed;
  if (parsed.platform === "imessage") {
    const id = Number(parsed.id);
    if (!Number.isInteger(id) || id <= 0) return { error: "iMessage thread_ref must look like imessage:<positive integer>" };
    return { ...parsed, imessageThreadId: id };
  }
  return parsed;
}

function parseDraftRef(value: string, expected?: Platform): { platform: Platform; id: string } | { error: string } {
  const parsed = parseRef(value, expected);
  if ("error" in parsed) return parsed;
  const uuidResult = uuid.safeParse(parsed.id);
  if (!uuidResult.success) return { error: "draft_ref id must be a UUID" };
  return parsed;
}

function isDaemonBlocked(e: unknown): boolean {
  if (e instanceof DaemonUnavailableError) return true;
  const message = (e as Error | undefined)?.message ?? "";
  return message.startsWith("Daemon RPC ") && message.includes(" timed out ");
}

function describeError(platform: Platform, e: unknown): string {
  if (isDaemonBlocked(e)) return `${platform} daemon unavailable`;
  if (e instanceof DaemonRpcError) return `${platform} daemon error (${e.code}): ${e.message}`;
  return `${platform} error: ${(e as Error).message}`;
}

function maybePartialError<T>(scope: PlatformOrAll, issues: AccessIssue[], payload: T) {
  if (scope !== "all" && issues.length > 0) return errorResult(issues[0]!.error);
  return jsonResult(payload);
}

function isoToMs(iso: string | undefined): number | undefined {
  if (!iso) return undefined;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : undefined;
}

function wrapIMessageThread(t: IMessageListThreadsResult["threads"][number]) {
  return {
    platform: "imessage" as const,
    thread_ref: ref("imessage", t.thread_id),
    transport_thread_id: t.thread_id,
    guid: t.guid,
    display_name: wrapUntrusted(t.display_name),
    is_group: t.is_group,
    participants: t.participants.map((p) => ({ handle: p.handle, name: wrapUntrusted(p.name) })),
    last_message_at: t.last_message_at,
    last_message_from: t.last_message_from
      ? { ...t.last_message_from, name: wrapUntrusted(t.last_message_from.name) }
      : null,
    last_message_preview: wrapUntrusted(t.last_message_preview),
  };
}

interface WhatsAppThread {
  thread_jid: string;
  display_name: string | null;
  is_group: boolean;
  last_message_ts: number;
  last_seen_at: number | null;
}

function wrapWhatsAppThread(t: WhatsAppThread) {
  return {
    platform: "whatsapp" as const,
    thread_ref: ref("whatsapp", t.thread_jid),
    transport_thread_id: t.thread_jid,
    display_name: wrapUntrusted(t.display_name),
    is_group: t.is_group,
    last_message_at: new Date(t.last_message_ts).toISOString(),
    last_seen_at: t.last_seen_at == null ? null : new Date(t.last_seen_at).toISOString(),
  };
}

// Unified cross-transport media descriptor. Both transports normalize into
// this so a caller reads one shape regardless of platform. Differences are
// faithful, not hidden: iMessage attachments carry a local `path` (the file is
// on disk) and no `caption`; WhatsApp carries a `caption` and no `path` (the
// daemon keeps metadata only, the bytes are not downloaded). `filename` and
// `caption` are peer-supplied and wrapped untrusted.
interface FacadeMedia {
  kind: AttachmentKind;
  filename: string | null;
  caption: string | null;
  mime_type: string | null;
  path: string | null;
  total_bytes: number | null;
  is_sticker: boolean;
}

function imessageMedia(attachments: readonly IMessageAttachment[] | undefined): FacadeMedia[] {
  return (attachments ?? []).map((a) => ({
    kind: a.kind,
    filename: wrapUntrusted(a.filename),
    caption: null,
    mime_type: a.mime_type,
    path: a.path,
    total_bytes: a.total_bytes,
    is_sticker: a.is_sticker,
  }));
}

const WHATSAPP_MEDIA_TYPES = new Set(["image", "video", "audio", "voice", "document", "sticker"]);

function whatsappMediaKind(messageType: string, mime: string | null, filename: string | null): AttachmentKind {
  switch (messageType) {
    case "image":
    case "sticker":
      return "image";
    case "video":
      return "video";
    case "voice":
    case "audio":
      return "audio";
    case "document":
      return "document";
    default:
      return classifyAttachmentKind(mime, null, filename);
  }
}

function whatsappMedia(
  messageType: string,
  meta: { caption?: string; filename?: string; mime?: string } | null,
): FacadeMedia[] {
  if (meta == null && !WHATSAPP_MEDIA_TYPES.has(messageType)) return [];
  const mime = meta?.mime ?? null;
  const filename = meta?.filename ?? null;
  return [
    {
      kind: whatsappMediaKind(messageType, mime, filename),
      filename: wrapUntrusted(filename),
      caption: wrapUntrusted(meta?.caption ?? null),
      mime_type: mime,
      path: null,
      total_bytes: null,
      is_sticker: messageType === "sticker",
    },
  ];
}

function wrapIMessageMessage(m: IMessageThreadMessage) {
  // Strip the raw `attachments` from the spread — we re-expose it as the
  // normalized, untrusted-wrapped `media` field instead so filenames can't
  // smuggle prompt-injection through an unwrapped path.
  const { attachments, ...rest } = m;
  return {
    platform: "imessage" as const,
    thread_ref: ref("imessage", m.thread_id),
    message_ref: ref("imessage", m.message_id),
    ...wrapBodyInPlace(rest),
    sender: { handle: m.sender.handle, name: wrapUntrusted(m.sender.name) },
    media: imessageMedia(attachments),
    reply_to: m.reply_to
      ? {
          ...m.reply_to,
          body: wrapUntrusted(m.reply_to.body),
          sender: {
            handle: m.reply_to.sender.handle,
            name: wrapUntrusted(m.reply_to.sender.name),
          },
        }
      : null,
  };
}

interface WhatsAppMessage {
  message_id: string;
  thread_jid: string;
  sender_jid: string;
  sender_name: string | null;
  from_me: boolean;
  ts: number;
  body: string | null;
  body_sha256: string | null;
  message_type: string;
  attachment_meta: { caption?: string; filename?: string; mime?: string } | null;
  reply_to_id: string | null;
  reply_to: {
    message_id: string;
    body: string | null;
    from_me: boolean;
    sender_name: string | null;
  } | null;
}

function wrapWhatsAppMessage(m: WhatsAppMessage) {
  // attachment_meta.caption / filename are peer-supplied — drop the raw field
  // from the spread and re-expose it through the wrapped `media` array.
  const { attachment_meta, ...rest } = m;
  return {
    platform: "whatsapp" as const,
    thread_ref: ref("whatsapp", m.thread_jid),
    message_ref: ref("whatsapp", m.message_id),
    ...wrapBodyInPlace(rest),
    sent_at: new Date(m.ts).toISOString(),
    sender_name: wrapUntrusted(m.sender_name),
    media: whatsappMedia(m.message_type, attachment_meta),
    reply_to: m.reply_to
      ? {
          ...m.reply_to,
          body: wrapUntrusted(m.reply_to.body),
          sender_name: wrapUntrusted(m.reply_to.sender_name),
        }
      : null,
  };
}

function wrapGeneralDraft(platform: "imessage", draft: ReturnType<typeof wrapIMessageDraft>): unknown;
function wrapGeneralDraft(platform: "whatsapp", draft: WhatsAppDraft): unknown;
function wrapGeneralDraft(platform: Platform, draft: ReturnType<typeof wrapIMessageDraft> | WhatsAppDraft): unknown {
  if (draft == null) return null;
  return {
    ...draft,
    platform,
    draft_ref: ref(platform, draft.id),
    transport_draft_id: draft.id,
  };
}

function wrapPriority(platform: Platform, key: string, entry: { level: number; reason?: string; set_at: string; set_by: "agent" | "keep-tabs" | "user" }) {
  return {
    platform,
    thread_ref: ref(platform, key),
    transport_thread_id: platform === "imessage" ? Number(key) : key,
    ...entry,
    reason: entry.reason === undefined ? undefined : wrapUntrusted(entry.reason) ?? undefined,
  };
}

function registerGeneralizedTools(server: McpServer): void {
  registerWithWitness(
    server,
    "get_message_current_time",
    "Return current UTC/local time for constructing `since` filters across message transports.",
    {},
    async () => {
      const now = new Date();
      const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
      return jsonResult({
        ok: true,
        utc_iso: now.toISOString(),
        epoch_ms: now.getTime(),
        local_timezone: timezone,
      });
    },
  );

  registerWithWitness(
    server,
    "ghostie_health_check",
    "Check the generalized Ghostie facade plus the iMessage and WhatsApp daemon dependencies.",
    {},
    async (_args, witness) => {
      const result: Record<string, unknown> = { ok: true, facade: "reachable" };
      try {
        result.imessage = await callIMessageDaemon("chatDbDiagnostic");
        witness.touch("imessage");
      } catch (e) {
        result.imessage = { ok: false, error: describeError("imessage", e) };
      }
      try {
        result.whatsapp = await callWhatsAppDaemon("getConnectionStatus");
        witness.touch("whatsapp");
      } catch (e) {
        result.whatsapp = { ok: false, error: describeError("whatsapp", e) };
      }
      return jsonResult(result);
    },
  );

  registerWithWitness(
    server,
    "list_message_threads",
    "List message threads across iMessage and/or WhatsApp. Requires either `since` or `contact_filter`; returns stable `thread_ref` values like imessage:123 and whatsapp:<jid>.",
    ListThreadsShape,
    async (args, witness) => {
      const scopeError = requireScope(args);
      if (scopeError) return errorResult(scopeError);
      // The WhatsApp daemon's getThreads has no `before` cursor — only
      // since/contact_filter/limit. Refuse rather than silently mispage:
      // returning un-windowed WhatsApp threads alongside `before`-windowed
      // iMessage ones would corrupt callers' pagination.
      if (args.before && args.platform !== "imessage") {
        return errorResult(
          "`before` is only supported with platform=imessage: the WhatsApp transport cannot page threads by `before`. Retry with platform=imessage, or drop `before` and narrow with `since`/`contact_filter`.",
        );
      }
      const issues: AccessIssue[] = [];
      const threads: unknown[] = [];
      for (const platform of platforms(args.platform)) {
        try {
          if (platform === "imessage") {
            const r = await callIMessageDaemon<IMessageListThreadsResult>("listThreads", {
              limit: args.limit,
              sinceIso: args.since,
              beforeIso: args.before,
              contactFilter: args.contact_filter,
            });
            threads.push(...r.threads.map(wrapIMessageThread));
            witness.touch("imessage");
          } else {
            const r = await callWhatsAppDaemon<{ threads: WhatsAppThread[] }>("getThreads", {
              since: isoToMs(args.since),
              contact_filter: args.contact_filter,
              limit: args.limit,
            });
            threads.push(...r.threads.map(wrapWhatsAppThread));
            witness.touch("whatsapp");
          }
        } catch (e) {
          issues.push({ platform, error: describeError(platform, e) });
        }
      }
      return maybePartialError(args.platform, issues, {
        ok: true,
        threads,
        access_issues: issues,
      });
    },
  );

  registerWithWitness(
    server,
    "get_message_thread",
    "Fetch messages for a stable generalized `thread_ref` returned by list_message_threads. Messages carrying photos/videos/files/voice notes include a normalized `media` array — each entry has `kind` (image|video|audio|document|other), `filename` and `caption` (peer-supplied, wrapped untrusted), `mime_type`, `total_bytes`, `is_sticker`, and (iMessage only) a local `path` to the file on disk. WhatsApp media is metadata-only (no `path`).",
    GetThreadShape,
    async (args, witness) => {
      const parsed = parseThreadRef(args.thread_ref);
      if ("error" in parsed) return errorResult(parsed.error);
      try {
        if (parsed.platform === "imessage") {
          const rows = await callIMessageDaemon<IMessageThreadMessage[]>("getThread", {
            threadId: parsed.imessageThreadId,
            limit: args.limit,
            beforeIso: args.before,
          });
          witness.touch("imessage");
          return jsonResult({
            ok: true,
            platform: "imessage",
            thread_ref: args.thread_ref,
            messages: rows.map(wrapIMessageMessage),
          });
        }
        const r = await callWhatsAppDaemon<{ messages: WhatsAppMessage[] }>("getThread", {
          thread_jid: parsed.id,
          before_ts: isoToMs(args.before),
          limit: args.limit,
        });
        witness.touch("whatsapp");
        return jsonResult({
          ok: true,
          platform: "whatsapp",
          thread_ref: args.thread_ref,
          messages: r.messages.map(wrapWhatsAppMessage),
        });
      } catch (e) {
        return errorResult(describeError(parsed.platform, e));
      }
    },
  );

  registerWithWitness(
    server,
    "search_message_history",
    "Search message history across iMessage and/or WhatsApp. Requires `query` plus either `since` or `contact_filter`. Hits on messages with media include the same normalized `media` array as get_message_thread.",
    SearchShape,
    async (args, witness) => {
      const scopeError = requireScope(args);
      if (scopeError) return errorResult(scopeError);
      const issues: AccessIssue[] = [];
      const hits: unknown[] = [];
      for (const platform of platforms(args.platform)) {
        try {
          if (platform === "imessage") {
            const rows = await callIMessageDaemon<IMessageThreadMessage[]>("searchMessages", {
              query: args.query,
              limit: args.limit,
              sinceIso: args.since,
              contactFilter: args.contact_filter,
            });
            hits.push(...rows.map(wrapIMessageMessage));
            witness.touch("imessage");
          } else {
            const r = await callWhatsAppDaemon<{ messages: WhatsAppMessage[] }>("searchMessages", {
              query: args.query,
              since: isoToMs(args.since),
              contact_filter: args.contact_filter,
              limit: args.limit,
            });
            hits.push(...r.messages.map(wrapWhatsAppMessage));
            witness.touch("whatsapp");
          }
        } catch (e) {
          issues.push({ platform, error: describeError(platform, e) });
        }
      }
      return maybePartialError(args.platform, issues, {
        ok: true,
        query: args.query,
        hits,
        access_issues: issues,
      });
    },
  );

  registerWithWitness(
    server,
    "stage_message_draft",
    "Stage a message draft for human approval. Does NOT send. Pass `platform` as imessage or whatsapp; returns a stable `draft_ref`. Pass `attachments` (array of `{path, filename?, mime_type?}`) to send photos/videos/files. The transport copies each source into a private draft-owned snapshot and derives filename/MIME from the source; the body may be empty when attachments are present.",
    StageDraftShape,
    async (args, witness) => {
      const targetError = validateStageTarget(args.platform, args.to_handle);
      if (targetError) return errorResult(targetError);
      if (args.platform === "imessage" && args.body.length > IMESSAGE_DRAFT_BODY_MAX) {
        return errorResult(`iMessage draft body must be at most ${IMESSAGE_DRAFT_BODY_MAX} characters`);
      }
      if (args.body.trim().length === 0 && (args.attachments?.length ?? 0) === 0) {
        return errorResult("provide a non-empty `body`, one or more `attachments`, or both");
      }
      // Quoting a specific message is a WhatsApp-only capability — the
      // iMessage draft pipeline has no quote field. Refuse rather than
      // silently dropping the caller's quoting intent.
      if (args.platform === "imessage" && args.quoted_message_id) {
        return errorResult(
          "quoted_message_id is WhatsApp-only: iMessage drafts cannot quote a specific message. Omit quoted_message_id (use in_reply_to_thread_ref to target the thread), or stage a WhatsApp draft instead.",
        );
      }
      try {
        if (args.platform === "imessage") {
          let inReplyTo: number | undefined;
          if (args.in_reply_to_thread_ref) {
            const parsed = parseThreadRef(args.in_reply_to_thread_ref, "imessage");
            if ("error" in parsed) return errorResult(parsed.error);
            inReplyTo = parsed.imessageThreadId;
          }
          const result = await stageIMessageDraft({
            to_handle: args.to_handle,
            body: args.body,
            attachments: args.attachments,
            in_reply_to_thread_id: inReplyTo,
            source: args.source ?? "ghostie-mcp",
          });
          witness.touch("imessage");
          return jsonResult({
            ok: true,
            platform: "imessage",
            draft_ref: ref("imessage", result.draft.id),
            path: result.path,
            draft: wrapGeneralDraft("imessage", wrapIMessageDraft(result.draft)),
          });
        }

        if (args.in_reply_to_thread_ref) {
          const parsed = parseThreadRef(args.in_reply_to_thread_ref, "whatsapp");
          if ("error" in parsed) return errorResult(parsed.error);
          if (parsed.id !== args.to_handle) {
            return errorResult("for WhatsApp drafts, in_reply_to_thread_ref must match to_handle");
          }
        }
        const { draft } = await stageWhatsAppDraft({
          to_handle: args.to_handle,
          body: args.body,
          source: args.source ?? "ghostie-mcp",
          quoted_message_id: args.quoted_message_id,
          attachments: args.attachments,
        });
        witness.touch("whatsapp");
        return jsonResult({
          ok: true,
          platform: "whatsapp",
          draft_ref: ref("whatsapp", draft.id),
          draft: wrapGeneralDraft("whatsapp", maskWhatsAppDraft(draft)),
        });
      } catch (e) {
        return errorResult(describeError(args.platform, e));
      }
    },
  );

  registerWithWitness(
    server,
    "list_message_drafts",
    "List staged message drafts across iMessage and/or WhatsApp. Returns stable `draft_ref` values; drafts still require human approval before sending.",
    ListDraftsShape,
    async (args, witness) => {
      const issues: AccessIssue[] = [];
      const drafts: unknown[] = [];
      for (const platform of platforms(args.platform)) {
        try {
          if (platform === "imessage") {
            drafts.push(
              ...listIMessageDrafts(args.limit).map((d) => wrapGeneralDraft("imessage", wrapIMessageDraft(d))),
            );
            witness.touch("imessage");
          } else {
            const r = await callWhatsAppDaemon<{ drafts: WhatsAppDraft[]; skipped: number }>("getDrafts");
            drafts.push(...r.drafts.slice(0, args.limit).map((d) => wrapGeneralDraft("whatsapp", maskWhatsAppDraft(d))));
            witness.touch("whatsapp");
          }
        } catch (e) {
          issues.push({ platform, error: describeError(platform, e) });
        }
      }
      return maybePartialError(args.platform, issues, { ok: true, drafts, access_issues: issues });
    },
  );

  registerWithWitness(
    server,
    "get_message_draft",
    "Fetch one staged draft by generalized `draft_ref`.",
    DraftRefShape,
    async (args, witness) => {
      const parsed = parseDraftRef(args.draft_ref);
      if ("error" in parsed) return errorResult(parsed.error);
      try {
        if (parsed.platform === "imessage") {
          const draft = getIMessageDraft(parsed.id);
          if (!draft) return errorResult(`draft not found: ${args.draft_ref}`);
          witness.touch("imessage");
          return jsonResult({ ok: true, draft: wrapGeneralDraft("imessage", wrapIMessageDraft(draft)) });
        }
        const { draft } = await callWhatsAppDaemon<{ draft: WhatsAppDraft }>("getDraft", { draft_id: parsed.id });
        witness.touch("whatsapp");
        return jsonResult({ ok: true, draft: wrapGeneralDraft("whatsapp", maskWhatsAppDraft(draft)) });
      } catch (e) {
        return errorResult(describeError(parsed.platform, e));
      }
    },
  );

  registerWithWitness(
    server,
    "discard_message_draft",
    "Discard one staged draft by generalized `draft_ref`. Does not send.",
    DraftRefShape,
    async (args, witness) => {
      const parsed = parseDraftRef(args.draft_ref);
      if ("error" in parsed) return errorResult(parsed.error);
      try {
        if (parsed.platform === "imessage") {
          const existed = discardIMessageDraft(parsed.id);
          if (!existed) return errorResult(`draft not found: ${args.draft_ref}`);
          witness.touch("imessage");
          return jsonResult({ ok: true, draft_ref: args.draft_ref, existed });
        }
        const r = await callWhatsAppDaemon<{ ok: true; existed: boolean }>("discardDraft", { draft_id: parsed.id });
        witness.touch("whatsapp");
        return jsonResult({ ok: true, draft_ref: args.draft_ref, existed: r.existed });
      } catch (e) {
        return errorResult(describeError(parsed.platform, e));
      }
    },
  );

  registerWithWitness(
    server,
    "set_message_thread_priority",
    "Set a priority for a generalized `thread_ref`. `level`: 1 urgent, 2 high, 3 elevated.",
    SetPriorityShape,
    async (args, witness) => {
      const parsed = parseThreadRef(args.thread_ref);
      if ("error" in parsed) return errorResult(parsed.error);
      try {
        const result = parsed.platform === "imessage"
          ? setIMessageThreadPriority(parsed.imessageThreadId!, args.level, args.reason)
          : setWhatsAppThreadPriority(parsed.id, args.level, args.reason);
        witness.touch(parsed.platform);
        return jsonResult({
          ok: true,
          priority: wrapPriority(parsed.platform, result.key, result.entry),
        });
      } catch (e) {
        return errorResult(`${parsed.platform} priority failed: ${(e as Error).message}`);
      }
    },
  );

  registerWithWitness(
    server,
    "clear_message_thread_priority",
    "Clear priority for a generalized `thread_ref`. Idempotent.",
    { thread_ref: z.string().min(1) },
    async (args, witness) => {
      const parsed = parseThreadRef(args.thread_ref);
      if ("error" in parsed) return errorResult(parsed.error);
      try {
        const removed = parsed.platform === "imessage"
          ? clearIMessageThreadPriority(parsed.imessageThreadId!)
          : clearWhatsAppThreadPriority(parsed.id);
        witness.touch(parsed.platform);
        return jsonResult({ ok: true, thread_ref: args.thread_ref, removed });
      } catch (e) {
        return errorResult(`${parsed.platform} priority clear failed: ${(e as Error).message}`);
      }
    },
  );

  registerWithWitness(
    server,
    "list_message_thread_priorities",
    "List generalized message thread priorities across iMessage and/or WhatsApp.",
    ListPrioritiesShape,
    async (args, witness) => {
      const priorities: unknown[] = [];
      if (args.platform === "all" || args.platform === "imessage") {
        for (const [key, entry] of Object.entries(listIMessageThreadPriorities())) {
          priorities.push(wrapPriority("imessage", key, entry));
        }
        witness.touch("imessage");
      }
      if (args.platform === "all" || args.platform === "whatsapp") {
        for (const [key, entry] of Object.entries(listWhatsAppThreadPriorities())) {
          priorities.push(wrapPriority("whatsapp", key, entry));
        }
        witness.touch("whatsapp");
      }
      return jsonResult({ ok: true, priorities });
    },
  );
}

async function main() {
  // The iMessage witness records chat.db access for the menubar's #17
  // detection. Like the iMessage transport MCP, this facade never reads
  // chat.db itself — the menu-bar-launched daemon does — so we report
  // the DAEMON's access. callDaemon is async but the witness probe is
  // synchronous, so cache the daemon's status and refresh on a timer.
  // (Mirrors mcps/imessage-drafts/src/index.ts.)
  let cachedChatDbStatus: "ok" | "permission_denied" | "not_found" | "error" | undefined;
  const refreshChatDbStatus = async () => {
    try {
      const d = await callIMessageDaemon<{ open_status: "ok" | "permission_denied" | "not_found" | "error" }>(
        "chatDbDiagnostic",
      );
      cachedChatDbStatus = d.open_status;
    } catch {
      cachedChatDbStatus = "error"; // daemon unreachable
    }
  };
  setChatDbAccessProbe(() => cachedChatDbStatus);
  void refreshChatDbStatus();
  setInterval(() => void refreshChatDbStatus(), 30_000).unref?.();

  const server = new McpServer(
    { name: "ghostie-mcp", version: "0.11.3" },
    {
      instructions:
        "Ghostie: a generalized facade over local iMessage and WhatsApp transports. " +
        "Use stable refs such as imessage:123 and whatsapp:12025550001@s.whatsapp.net. " +
        "This facade can read/search and stage/discard drafts, but intentionally exposes no generalized send tool: " +
        "drafts are reviewed and sent through the companion menu bar app, or via the transport-specific explicit send tools.",
    },
  );

  registerGeneralizedTools(server);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(`fatal: ${(err as Error).message}\n${(err as Error).stack ?? ""}\n`);
  process.exit(1);
});
