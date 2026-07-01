// Shared Zod validators. Mirrors imessage-mcp/src/schema.ts patterns.

import { z } from "zod";

const TWO_YEARS_MS = 1000 * 60 * 60 * 24 * 365 * 2;

/** ISO-8601 datetime, must be within the last 2 years and not in the future. */
const SinceIso = z.string().refine(
  (s) => {
    const t = Date.parse(s);
    if (!Number.isFinite(t)) return false;
    const now = Date.now();
    return t >= now - TWO_YEARS_MS && t <= now;
  },
  { message: "must be ISO-8601 within the last 2 years, not in the future" },
);

const ContactFilter = z.string().min(2, "contact_filter must be at least 2 chars");

/** Either since OR contact_filter is required — prevents unbounded history dumps. */
function eitherFilter<T extends { since?: string; contact_filter?: string }>(arg: T): boolean {
  return arg.since != null || (arg.contact_filter != null && arg.contact_filter.length > 0);
}
const eitherFilterErr = { message: "either `since` (ISO-8601) or `contact_filter` (≥2 chars) is required" };

// Split each input into an object shape (for MCP tool registration's
// `.shape` requirement) and a fully-refined schema (for validation).
// `.refine()` returns ZodEffects, which doesn't have `.shape` — so we
// can't compress these into one expression.

const ListThreadsObj = z.object({
  since: SinceIso.optional(),
  contact_filter: ContactFilter.optional(),
  limit: z.number().int().positive().max(500).optional(),
});
export const ListThreadsShape = ListThreadsObj.shape;
export const ListThreadsInput = ListThreadsObj.refine(eitherFilter, eitherFilterErr);

const GetThreadObj = z.object({
  thread_jid: z.string().min(1),
  before_ts: z.number().int().positive().optional(),
  limit: z.number().int().positive().max(500).optional(),
});
export const GetThreadShape = GetThreadObj.shape;
export const GetThreadInput = GetThreadObj;

const SearchObj = z.object({
  query: z.string().min(2, "query must be at least 2 chars"),
  since: SinceIso.optional(),
  contact_filter: ContactFilter.optional(),
  limit: z.number().int().positive().max(500).optional(),
});
export const SearchShape = SearchObj.shape;
export const SearchInput = SearchObj.refine(eitherFilter, eitherFilterErr);

const GetMessageFullObj = z.object({
  thread_jid: z.string().min(1),
  message_id: z.string().min(1),
});
export const GetMessageFullShape = GetMessageFullObj.shape;
export const GetMessageFullInput = GetMessageFullObj;

// WhatsApp JID: either a phone-number user JID like "12025550001@s.whatsapp.net"
// or a group JID like "120363xxxx@g.us". We don't try to enforce the full
// shape — Baileys returns errors for malformed JIDs anyway — but we require
// a non-empty string with no whitespace and the "@" separator.
const WhatsAppJid = z.string().min(1).regex(/^[^@\s]+@[^@\s]+$/, "expected a WhatsApp JID like 12025550001@s.whatsapp.net or 12036xx@g.us");

// One file to attach to an outbound WhatsApp draft. `path` is a local
// filesystem path (absolute or ~-prefixed); the daemon reads its bytes and
// chooses the Baileys media type from the MIME at send time.
export const DraftAttachmentSchema = z.object({
  path: z.string().min(1).max(4096),
  filename: z.string().min(1).max(255).optional(),
  mime_type: z.string().min(1).max(255).optional(),
});

const StageDraftObj = z.object({
  to_handle: WhatsAppJid,
  // Empty allowed only when `attachments` is non-empty (media-only message).
  // The tool enforces "body or attachment required".
  body: z.string().max(60_000, "body too long"),
  source: z.string().optional(),
  // Photos / videos / documents / audio to send with the draft. Each file is
  // sent first, the body becomes the caption on the last one. Max 10, 100 MB each.
  attachments: z.array(DraftAttachmentSchema).max(10).optional(),
  // When set, the draft sends as a quoted reply to this message id (the
  // `message_id` / stanzaId from get_whatsapp_thread) in to_handle's thread.
  quoted_message_id: z.string().min(1).optional(),
});
export const StageDraftShape = StageDraftObj.shape;
export const StageDraftInput = StageDraftObj;

const DraftIdObj = z.object({ draft_id: z.string().uuid("draft_id must be a UUID") });
export const DraftIdShape = DraftIdObj.shape;
export const DraftIdInput = DraftIdObj;

// Thread priorities — thread_jid validated the same way the read tools
// validate it (non-empty string; Baileys rejects malformed JIDs anyway).
// level 1=urgent, 2=high, 3=elevated — lower is more urgent (P1/P2/P3).
const SetThreadPriorityObj = z.object({
  thread_jid: z.string().min(1),
  level: z.number().int().min(1).max(3),
  reason: z.string().min(1).max(200).optional(),
});
export const SetThreadPriorityShape = SetThreadPriorityObj.shape;
export const SetThreadPriorityInput = SetThreadPriorityObj;

const ClearThreadPriorityObj = z.object({
  thread_jid: z.string().min(1),
});
export const ClearThreadPriorityShape = ClearThreadPriorityObj.shape;
export const ClearThreadPriorityInput = ClearThreadPriorityObj;

const ListThreadPrioritiesObj = z.object({});
export const ListThreadPrioritiesShape = ListThreadPrioritiesObj.shape;
export const ListThreadPrioritiesInput = ListThreadPrioritiesObj;

export type ListThreadsArgs = z.infer<typeof ListThreadsInput>;
export type GetThreadArgs = z.infer<typeof GetThreadInput>;
export type SearchArgs = z.infer<typeof SearchInput>;
export type GetMessageFullArgs = z.infer<typeof GetMessageFullInput>;

export function isoToMs(iso: string | undefined): number | undefined {
  if (iso == null) return undefined;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : undefined;
}
