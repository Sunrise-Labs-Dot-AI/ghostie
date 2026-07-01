import { z } from "zod";

const TWO_YEARS_MS = 2 * 365 * 24 * 60 * 60 * 1000;

const iso8601 = z
  .string()
  .refine((s) => !Number.isNaN(Date.parse(s)), { message: "must be a valid ISO-8601 timestamp" });

const sinceNotDeepHistory = iso8601.refine(
  (s) => Date.now() - Date.parse(s) <= TWO_YEARS_MS,
  { message: "since is older than 2 years; deep history requires an explicit opt-in flag (not yet supported)" }
);

const contactFilter = z.string().min(2, "contact_filter must be at least 2 characters");
const dispatchHandle = z
  .string()
  .min(1)
  .refine((s) => /@/.test(s) || /^\+?\d[\d\s\-().]{5,}$/.test(s), {
    message: "handle must look like an email address, phone number, or WhatsApp JID",
  });

// Raw shapes — passed to MCP `inputSchema`. The SDK validates with these and
// passes typed args to handlers; cross-field rules (e.g. "since OR contact_filter")
// are checked inline in the handler, where we can return an actionable error.

export const ListThreadsShape = {
  limit: z.number().int().min(1).max(100).default(25),
  since: sinceNotDeepHistory.optional(),
  before: iso8601.optional(),
  contact_filter: contactFilter.optional(),
} as const;

export const GetThreadShape = {
  thread_id: z.number().int().positive(),
  limit: z.number().int().min(1).max(200).default(50),
  before: iso8601.optional(),
} as const;

export const SearchShape = {
  query: z.string().min(2, "query must be at least 2 characters"),
  since: sinceNotDeepHistory.optional(),
  contact_filter: contactFilter.optional(),
  limit: z.number().int().min(1).max(100).default(25),
} as const;

// One file to attach to an outbound draft. `path` is a local filesystem path
// (absolute, or ~-prefixed) that the menu bar app and the send path can read.
// filename/mime_type are optional hints; the stage tool fills them in from the
// file when omitted.
export const DraftAttachmentShape = z.object({
  path: z.string().min(1).max(4096),
  filename: z.string().min(1).max(255).optional(),
  mime_type: z.string().min(1).max(255).optional(),
});

export const StageDraftShape = {
  to_handle: dispatchHandle,
  // Empty allowed ONLY when `attachments` is non-empty (an attachment-only
  // message). The handler enforces "body or attachment required".
  body: z.string().max(20_000),
  // Photos / videos / files to send with the draft. Each must exist on disk at
  // stage time; the file is sent before the body (so the text reads as a
  // caption), matching Messages.app. Capped at 10 files, 100 MB each.
  attachments: z.array(DraftAttachmentShape).max(10).optional(),
  in_reply_to_thread_id: z.number().int().positive().optional(),
  // Short human-readable provenance label. Shown verbatim in the menu
  // bar app's draft review UI so a reviewer can tell which agent or
  // context staged the draft. Free-form; the agent should set it to
  // something the human will actually find informative, e.g.
  // "Claude Desktop / morning triage" or
  // "Claude Code in personal-assistant repo".
  source: z.string().min(1).max(200).optional(),
} as const;

export const ProposeMessageAutomationShape = {
  title: z.string().min(1).max(200).optional(),
  platform: z.enum(["imessage", "whatsapp"]).default("imessage"),
  to_handle: dispatchHandle,
  recipient_name: z.string().min(1).max(200).optional(),
  body: z.string().min(1).max(20_000),
  cadence: z.enum(["daily", "weekly", "biweekly", "monthly", "quarterly", "yearly"]),
  first_send_at: iso8601,
  source: z.string().min(1).max(200).optional(),
} as const;

export const ListMessageAutomationsShape = {
  limit: z.number().int().min(1).max(100).default(50),
} as const;

export const DeleteMessageAutomationProposalShape = {
  automation_id: z.string().uuid(),
} as const;

export const ListDraftsShape = {
  limit: z.number().int().min(1).max(100).default(25),
} as const;

export const GetDraftShape = {
  draft_id: z.string().uuid(),
} as const;

export const DiscardDraftShape = {
  draft_id: z.string().uuid(),
} as const;

export const SendDraftShape = {
  draft_id: z.string().uuid(),
} as const;

export const OverrideScheduledSendShape = {
  draft_id: z.string().uuid(),
} as const;

export const SetThreadPriorityShape = {
  thread_id: z.number().int().positive(),
  // 1 = urgent, 2 = high, 3 = elevated. Lower = more urgent (Linear-style
  // P1/P2/P3). Mirrors the on-disk contract in storage/priorities.ts.
  level: z.number().int().min(1).max(3),
  reason: z.string().min(1).max(200).optional(),
} as const;

export const ClearThreadPriorityShape = {
  thread_id: z.number().int().positive(),
} as const;

export const ListThreadPrioritiesShape = {} as const;

export const CurrentTimeShape = {} as const;

export const HealthCheckShape = {
  probe_handle: z.string().optional().describe(
    "Optional phone/email to canonicalize and look up against the loaded contacts. " +
    "Useful when 'to_handle_name' is unexpectedly null — the response will include " +
    "the canonical form (last-10-digits for phones, lowercased for emails) and " +
    "whether that key resolves to a contact name."
  ),
} as const;

export const ListVoiceProfilesShape = {} as const;

export const GetTextingVoiceShape = {
  profile: z
    .string()
    .regex(/^[a-z0-9][a-z0-9-]{0,63}$/, "profile must be a simple profile id")
    .default("base"),
} as const;

export function requireSinceOrContactFilter(args: { since?: string; contact_filter?: string }): string | null {
  if (!args.since && !args.contact_filter) {
    return "either 'since' (ISO-8601, within 2 years) or 'contact_filter' (>=2 chars) is required";
  }
  return null;
}
