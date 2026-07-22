// Draft staging. Each draft is a single JSON file at
// ~/.whatsapp-mcp/drafts/{uuid}.json with mode 0600. Mirrors the
// imessage-mcp draft schema and adds:
//   - platform: "whatsapp"
//   - schema_version: 1   (Phase 2 decoder rejects unknown versions)
//   - approval_state: "pending" | "approved"
//   - induced_by_unknown_contact: boolean (Phase 3 hint for the menu bar)
//
// Approval flow:
//   - stage_whatsapp_draft → writes file with approval_state="pending"
//   - menu bar app's hold-to-fire → flips to "approved" and calls daemon
//     sendDraft via the Unix socket
//   - When settings.require_approval = false (dev convenience),
//     MCP-side send_whatsapp_draft tool sets approval_state="approved"
//     on the tool side BEFORE invoking sendDraft

import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import { PATHS } from "../paths.ts";
import {
  cleanupDraftAttachments,
  validateManagedDraftAttachmentSnapshot,
  type ManagedDraftAttachment,
} from "../../../shared/src/attachments.ts";

export const DRAFT_SCHEMA_VERSION = 1;

export interface DraftContext {
  /** Snapshot of the last N messages in the thread when the draft was staged.
   *
   *  v0.3.2 field rename: `sender_jid` → `sender_handle`, `ts` (unix ms) →
   *  `sent_at` (ISO-8601 string). Aligns with the menubar's existing
   *  ContextMessage Codable terminology that the iMessage path already
   *  uses. Also adds `sender_name` resolved via getContactDisplayName at
   *  stage time so context bubbles render names instead of raw JIDs. The
   *  v0.3.0/v0.3.1 daemon wrote `sender_jid` + `ts`; the menubar's
   *  Codable handles both shapes for one release (see
   *  menubar/Sources/MessagesForAIMenu/Models/Draft.swift). */
  context_messages: Array<{
    message_id: string;
    sender_handle: string;
    sender_name: string | null;
    from_me: boolean;
    sent_at: string;
    body: string | null;
  }>;
  /** Diagnostic when context lookup failed. Mirrors imessage-mcp's pattern. */
  context_diagnostic: null | "no_thread_match" | "thread_empty" | "error";
}

/** Snapshot of the message a reply-draft quotes, resolved at stage time so
 *  the menubar can render a "Replying to …" callout without a daemon lookup.
 *  Mirrors the read-side reply_to shape. `body`/`sender_name` are peer-/
 *  sidecar-sourced; the menubar wraps untrusted content for display. */
export interface QuotedPreview {
  message_id: string;
  body: string | null;
  from_me: boolean;
  sender_name: string | null;
}

// A private, draft-owned attachment snapshot. Optional identity/hash fields
// retain read compatibility with legacy path-only drafts; send rejects those.
export interface DraftAttachment {
  asset_id?: string;
  path: string;
  filename: string;
  mime_type: string | null;
  byte_count: number | null;
  sha256?: string;
}

export interface DeliveryProgress {
  completed_attachment_count: number;
  body_sent: boolean;
  ambiguous_part: string | null;
}

export interface Draft extends DraftContext {
  id: string;
  schema_version: number;
  platform: "whatsapp";
  approval_state: "pending" | "approved";
  to_handle: string;       // WhatsApp JID
  /** Best-effort human-readable recipient name at stage time. Falls back
   *  to a pretty-printed phone number if no contact is known. The
   *  menubar prefers this over `to_handle` for the row title. */
  to_handle_name: string | null;
  body: string;            // agent-authored text
  staged_at: string;       // ISO-8601
  sent_at: string | null;
  source: string;          // e.g. "claude-desktop" — informational only
  induced_by_unknown_contact: boolean;
  /** When set, this draft sends as a quoted reply to this message id
   *  (stanzaId) in `to_handle`'s thread. null = ordinary message.
   *  Additive optional field — schema_version stays 1; older readers
   *  ignore it and the strict version gate still matches. */
  quoted_message_id: string | null;
  /** Stage-time snapshot of the quoted message for UI. null when the draft
   *  isn't a reply or the quoted message couldn't be resolved. */
  quoted_preview: QuotedPreview | null;
  /** Files to send with this draft (photos/videos/documents/audio). Empty for
   *  text-only drafts. Additive optional field — schema_version stays 1; older
   *  readers ignore it. The body may be empty when this is non-empty. */
  attachments: DraftAttachment[];
  delivery_progress: DeliveryProgress;
  scheduled_send_at: string | null;
  schedule_hold_reason: string | null;
  override_send: boolean | null;
  schedule_approved: boolean | null;
  schedule_approval_tag: string | null;
  /** Cross-device relay (SUN-613): which machine may execute this draft, as a
   *  `~/.messages-mcp/device.json` device id. Null on ordinary local drafts.
   *  Additive optional field — schema_version stays 1; older readers ignore it
   *  and the strict version gate still matches.
   *
   *  WhatsApp is inherently single-executor (the Baileys session lives in one
   *  machine's session.db and is not portable), so v1 never routes a WhatsApp
   *  draft to another Mac. The gate is defence in depth: if a stamp ever does
   *  appear here, the send is refused rather than assumed benign. */
  relay_executor: string | null;
}

export class DraftSchemaError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DraftSchemaError";
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function ensureDir(): void {
  if (!existsSync(PATHS.draftsDir)) {
    mkdirSync(PATHS.draftsDir, { recursive: true, mode: 0o700 });
  }
}

function draftPath(id: string): string {
  if (!UUID_RE.test(id)) {
    throw new DraftSchemaError(`invalid draft id: ${id}`);
  }
  return join(PATHS.draftsDir, `${id}.json`);
}

export interface StageInput {
  /** Generated by the unprivileged MCP caller that owns media snapshotting. */
  draft_id?: string;
  to_handle: string;
  to_handle_name?: string | null;
  body: string;
  source?: string;
  context_messages?: DraftContext["context_messages"];
  context_diagnostic?: DraftContext["context_diagnostic"];
  induced_by_unknown_contact?: boolean;
  quoted_message_id?: string | null;
  quoted_preview?: QuotedPreview | null;
  attachments?: ManagedDraftAttachment[] | null;
}

/** Stage a new draft. Returns the full draft object as written. */
export function stageDraft(input: StageInput): Draft {
  ensureDir();
  const id = input.draft_id ?? crypto.randomUUID();
  const attachments = (input.attachments ?? []).map((attachment) => {
    const verified = validateManagedDraftAttachmentSnapshot(PATHS.root, id, attachment);
    if (!verified.ok) throw new DraftSchemaError(verified.error);
    return verified.attachment;
  });
  const draft: Draft = {
    id,
    schema_version: DRAFT_SCHEMA_VERSION,
    platform: "whatsapp",
    approval_state: "pending",
    to_handle: input.to_handle,
    to_handle_name: input.to_handle_name ?? null,
    body: input.body,
    staged_at: new Date().toISOString(),
    sent_at: null,
    source: input.source ?? "unknown",
    context_messages: input.context_messages ?? [],
    context_diagnostic: input.context_diagnostic ?? null,
    induced_by_unknown_contact: input.induced_by_unknown_contact ?? false,
    quoted_message_id: input.quoted_message_id ?? null,
    quoted_preview: input.quoted_preview ?? null,
    attachments,
    delivery_progress: {
      completed_attachment_count: 0,
      body_sent: false,
      ambiguous_part: null,
    },
    scheduled_send_at: null,
    schedule_hold_reason: null,
    override_send: null,
    schedule_approved: null,
    schedule_approval_tag: null,
    relay_executor: null,
  };
  try {
    writeFileSync(draftPath(id), JSON.stringify(draft, null, 2), { mode: 0o600 });
  } catch (e) {
    cleanupDraftAttachments(PATHS.root, id);
    throw e;
  }
  return draft;
}

/** Read a draft by id. Throws DraftSchemaError if version mismatch. */
export function getDraft(id: string): Draft | null {
  const path = draftPath(id);
  if (!existsSync(path)) return null;
  const raw = readFileSync(path, "utf8");
  let parsed: Partial<Draft> & { schema_version?: unknown };
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new DraftSchemaError(`${path}: malformed JSON — ${(e as Error).message}`);
  }
  // Strict version check — Phase 2 decoder rejects (not silently
  // upgrades or downgrades) unknown versions. This is the rollback
  // safety described in the plan.
  if (parsed.schema_version !== DRAFT_SCHEMA_VERSION) {
    throw new DraftSchemaError(
      `${path}: unknown schema_version ${String(parsed.schema_version)} — expected ${DRAFT_SCHEMA_VERSION}`,
    );
  }
  const attachments = normalizeAttachments(parsed.attachments);
  return {
    ...(parsed as Draft),
    attachments,
    delivery_progress: normalizeDeliveryProgress((parsed as Partial<Draft>).delivery_progress, attachments.length),
    scheduled_send_at: typeof parsed.scheduled_send_at === "string" ? parsed.scheduled_send_at : null,
    schedule_hold_reason: typeof parsed.schedule_hold_reason === "string" ? parsed.schedule_hold_reason : null,
    override_send: typeof parsed.override_send === "boolean" ? parsed.override_send : null,
    schedule_approved: typeof parsed.schedule_approved === "boolean" ? parsed.schedule_approved : null,
    schedule_approval_tag: typeof parsed.schedule_approval_tag === "string" ? parsed.schedule_approval_tag : null,
    // Only absent and explicit null collapse to "unrouted". A present but
    // unusable value is preserved verbatim so `executorRefusal` can refuse it;
    // normalizing malformed routing data to null would fail OPEN.
    relay_executor:
      parsed.relay_executor === undefined || parsed.relay_executor === null
        ? null
        : typeof parsed.relay_executor === "string"
          ? parsed.relay_executor
          : String(parsed.relay_executor),
  };
}

function normalizeAttachments(raw: unknown): DraftAttachment[] {
  if (!Array.isArray(raw)) return [];
  const out: DraftAttachment[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const a = item as Record<string, unknown>;
    if (typeof a.path !== "string" || a.path.length === 0) continue;
    out.push({
      asset_id: typeof a.asset_id === "string" ? a.asset_id : undefined,
      path: a.path,
      filename: typeof a.filename === "string" && a.filename.length > 0 ? a.filename : "attachment",
      mime_type: typeof a.mime_type === "string" ? a.mime_type : null,
      byte_count: typeof a.byte_count === "number" && Number.isFinite(a.byte_count) ? a.byte_count : null,
      sha256: typeof a.sha256 === "string" ? a.sha256 : undefined,
    });
  }
  return out;
}

function normalizeDeliveryProgress(raw: unknown, attachmentCount: number): DeliveryProgress {
  if (!raw || typeof raw !== "object") return { completed_attachment_count: 0, body_sent: false, ambiguous_part: null };
  const p = raw as Record<string, unknown>;
  const completed =
    typeof p.completed_attachment_count === "number" && Number.isSafeInteger(p.completed_attachment_count)
      ? Math.max(0, Math.min(attachmentCount, p.completed_attachment_count))
      : 0;
  return {
    completed_attachment_count: completed,
    body_sent: p.body_sent === true,
    ambiguous_part: typeof p.ambiguous_part === "string" && p.ambiguous_part.length > 0 ? p.ambiguous_part : null,
  };
}

/** List drafts, newest-first by staged_at. Skips files that fail schema check. */
export function listDrafts(): { drafts: Draft[]; skipped: number } {
  ensureDir();
  const files = readdirSync(PATHS.draftsDir).filter((f) => f.endsWith(".json"));
  const drafts: Draft[] = [];
  let skipped = 0;
  for (const f of files) {
    const id = f.slice(0, -".json".length);
    try {
      const d = getDraft(id);
      if (d != null) drafts.push(d);
    } catch {
      skipped++;
    }
  }
  drafts.sort((a, b) => b.staged_at.localeCompare(a.staged_at));
  return { drafts, skipped };
}

/** Update a draft in-place. Used for approval-state flips and sent_at marking.
 *
 * Atomic write via temp+rename. A direct overwrite of the file produces
 * NO event on the parent directory's `DispatchSourceFileSystemObject`
 * watcher in the menubar (which only fires on structural changes —
 * files added, removed, renamed). The rename here produces a `.write`
 * event on the directory FD, which the menubar's DraftStore consumes
 * to re-list drafts and surface the `sent_at` flip. */
export function updateDraft(id: string, patch: Partial<Pick<Draft, "approval_state" | "sent_at" | "delivery_progress">>): Draft {
  const cur = getDraft(id);
  if (cur == null) throw new DraftSchemaError(`draft not found: ${id}`);
  const next: Draft = { ...cur, ...patch };
  const finalPath = draftPath(id);
  const tmpPath = `${finalPath}.tmp-${process.pid}`;
  writeFileSync(tmpPath, JSON.stringify(next, null, 2), { mode: 0o600 });
  renameSync(tmpPath, finalPath);
  return next;
}

/** Delete a draft. Returns true if the file existed. */
export function discardDraft(id: string): boolean {
  const path = draftPath(id);
  const existed = existsSync(path);
  if (existed) unlinkSync(path);
  cleanupDraftAttachments(PATHS.root, id);
  return existed;
}

/**
 * Sweep:
 *   - drafts older than ttl_days that were never sent → deleted
 *   - drafts with sent_at older than 24h → deleted
 */
export function sweepDrafts(
  ttlDays: number,
  now: number = Date.now(),
): { deleted: number; kept: number; orphaned_attachments: number } {
  ensureDir();
  const ttlCutoff = now - ttlDays * 24 * 60 * 60 * 1000;
  const sentCutoff = now - 24 * 60 * 60 * 1000;
  let deleted = 0;
  let kept = 0;
  let orphanedAttachments = 0;
  for (const f of readdirSync(PATHS.draftsDir)) {
    if (!f.endsWith(".json")) continue;
    const id = f.slice(0, -".json".length);
    try {
      const d = getDraft(id);
      if (d == null) continue;
      const staged = Date.parse(d.staged_at);
      const sent = d.sent_at != null ? Date.parse(d.sent_at) : null;
      if (sent != null && sent < sentCutoff) {
        discardDraft(id);
        deleted++;
        continue;
      }
      if (sent == null && Number.isFinite(staged) && staged < ttlCutoff) {
        discardDraft(id);
        deleted++;
        continue;
      }
      kept++;
    } catch {
      // Malformed draft file: leave it (operator can clean up manually).
      kept++;
    }
  }

  // A socket timeout after stageDraft is ambiguous, so the unprivileged MCP
  // caller deliberately leaves its snapshot in place. Once no matching draft
  // has appeared for an hour, it is safe to treat the directory as orphaned.
  const orphanCutoff = now - 60 * 60 * 1000;
  if (existsSync(PATHS.draftAttachmentsDir)) {
    try {
      const rootStat = lstatSync(PATHS.draftAttachmentsDir);
      if (!rootStat.isSymbolicLink() && rootStat.isDirectory()) {
        for (const id of readdirSync(PATHS.draftAttachmentsDir)) {
          try {
            if (existsSync(draftPath(id))) continue;
            const dirStat = lstatSync(join(PATHS.draftAttachmentsDir, id));
            if (dirStat.mtimeMs >= orphanCutoff) continue;
            cleanupDraftAttachments(PATHS.root, id);
            orphanedAttachments++;
          } catch {
            // A concurrent stage or cleanup owns this entry now.
          }
        }
      }
    } catch {
      // Permission enforcement reports root issues separately; sweeping stays
      // best effort and must never stop the daemon from starting.
    }
  }
  return { deleted, kept, orphaned_attachments: orphanedAttachments };
}

/** Re-chmod the drafts directory and all draft files to 0600 / 0700.
 *  Defense in depth in case something created them with wider perms. */
export function enforcePermissions(): void {
  ensureDir();
  try { chmodSync(PATHS.draftsDir, 0o700); } catch { /* ignore */ }
  for (const f of readdirSync(PATHS.draftsDir)) {
    if (!f.endsWith(".json")) continue;
    try { chmodSync(join(PATHS.draftsDir, f), 0o600); } catch { /* ignore */ }
  }
  if (existsSync(PATHS.draftAttachmentsDir)) {
    try { chmodSync(PATHS.draftAttachmentsDir, 0o700); } catch { /* ignore */ }
    for (const draftId of readdirSync(PATHS.draftAttachmentsDir)) {
      const dir = join(PATHS.draftAttachmentsDir, draftId);
      try { chmodSync(dir, 0o700); } catch { continue; }
      try {
        for (const asset of readdirSync(dir)) chmodSync(join(dir, asset), 0o600);
      } catch { /* ignore */ }
    }
  }
}
