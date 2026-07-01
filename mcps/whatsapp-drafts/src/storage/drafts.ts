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
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import { PATHS } from "../paths.ts";

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

// A file to send with the draft. `path` is an absolute local path resolved +
// existence-checked by the MCP stage tool; the daemon reads its bytes and picks
// the Baileys media type from `mime_type` at send time.
export interface DraftAttachment {
  path: string;
  filename: string;
  mime_type: string | null;
  byte_count: number | null;
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
}

export class DraftSchemaError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DraftSchemaError";
  }
}

function ensureDir(): void {
  if (!existsSync(PATHS.draftsDir)) {
    mkdirSync(PATHS.draftsDir, { recursive: true, mode: 0o700 });
  }
}

function draftPath(id: string): string {
  // Path-traversal guard — IDs are UUIDs so they never contain "/" or "..".
  if (id.includes("/") || id.includes("..") || id.length === 0) {
    throw new DraftSchemaError(`invalid draft id: ${id}`);
  }
  return join(PATHS.draftsDir, `${id}.json`);
}

export interface StageInput {
  to_handle: string;
  to_handle_name?: string | null;
  body: string;
  source?: string;
  context_messages?: DraftContext["context_messages"];
  context_diagnostic?: DraftContext["context_diagnostic"];
  induced_by_unknown_contact?: boolean;
  quoted_message_id?: string | null;
  quoted_preview?: QuotedPreview | null;
  attachments?: DraftAttachment[] | null;
}

/** Stage a new draft. Returns the full draft object as written. */
export function stageDraft(input: StageInput): Draft {
  ensureDir();
  const id = crypto.randomUUID();
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
    attachments: input.attachments ?? [],
  };
  writeFileSync(draftPath(id), JSON.stringify(draft, null, 2), { mode: 0o600 });
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
  // Backfill the additive `attachments` field so older draft files (written
  // before media support) read as the current shape.
  return { ...(parsed as Draft), attachments: Array.isArray(parsed.attachments) ? parsed.attachments : [] };
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
export function updateDraft(id: string, patch: Partial<Pick<Draft, "approval_state" | "sent_at">>): Draft {
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
  if (!existsSync(path)) return false;
  unlinkSync(path);
  return true;
}

/**
 * Sweep:
 *   - drafts older than ttl_days that were never sent → deleted
 *   - drafts with sent_at older than 24h → deleted
 */
export function sweepDrafts(ttlDays: number, now: number = Date.now()): { deleted: number; kept: number } {
  ensureDir();
  const ttlCutoff = now - ttlDays * 24 * 60 * 60 * 1000;
  const sentCutoff = now - 24 * 60 * 60 * 1000;
  let deleted = 0;
  let kept = 0;
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
  return { deleted, kept };
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
}
