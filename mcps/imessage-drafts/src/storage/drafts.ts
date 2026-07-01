import { mkdirSync, readdirSync, readFileSync, writeFileSync, unlinkSync, statSync, lstatSync, existsSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import { randomUUID } from "node:crypto";
import type { DraftContextMessage, ContextLookupDiagnostic } from "../chatdb/queries.ts";

// Compute the drafts directory on every access rather than caching it at
// module load. This is mostly for symmetry — the real test-seam below
// (`_setDraftsDirForTesting`) is what actually prevents leakage.
//
// IMPORTANT: a previous attempt to test this module via `process.env.HOME`
// swap did NOT work — on macOS, `os.homedir()` uses passwd lookup keyed on
// the effective UID, and ignores the JS-level HOME override. That oversight
// caused test artifacts to leak into the real ~/.messages-mcp/drafts AND
// the test's beforeEach rmSync wiped previously-staged production drafts.
// Production paths never call the override; only the test fixture does.
let testDirOverride: string | null = null;

function draftsDirPath(): string {
  return testDirOverride ?? join(homedir(), ".messages-mcp", "drafts");
}

export function _setDraftsDirForTesting(dir: string | null): void {
  testDirOverride = dir;
}

// A file staged to be sent alongside (or instead of) the draft body. The
// human reviewer sees the filename + a preview before approving; the send path
// hands the POSIX `path` to Messages.app (iMessage) or reads the bytes for
// Baileys (WhatsApp) at fire time. Paths are resolved to absolute + checked for
// existence when the draft is staged, but a file can still vanish before send —
// the send path re-checks and fails gracefully.
export interface DraftAttachment {
  path: string;
  // Display name; the sender's label for the file. Defaults to basename(path).
  filename: string;
  // Best-effort MIME, provided or inferred from the extension. Drives the
  // WhatsApp send type; informational for iMessage.
  mime_type: string | null;
  // Size in bytes at stage time, for the approval UI + a sanity gate. Null if
  // it couldn't be stat'd.
  byte_count: number | null;
}

export interface Draft {
  id: string;
  to_handle: string;
  // Resolved contact name from the CNContactStore-backed sidecar
  // (`~/.messages-mcp/contacts-cache.json`, written by the menu bar
  // app), or null if no match / sidecar absent. Surfaced in MCP tool
  // responses so agents can confirm the recipient by name, and used
  // by the menu bar to render a human-recognizable row header.
  to_handle_name: string | null;
  body: string;
  // Files to send with this draft (photos, videos, documents). Empty array for
  // a text-only draft. The body may be empty when attachments are present
  // (attachment-only message). Sent before the body so the text reads as a
  // caption under the media, matching Messages.app's ordering.
  attachments: DraftAttachment[];
  in_reply_to_thread_id: number | null;
  staged_at: string;
  sent_at: string | null;
  send_service: "iMessage" | "SMS" | null;
  // Free-form provenance label set by the staging agent. Examples:
  // "Claude Desktop / morning email triage", "Claude Code in
  // personal-assistant", "evening recap cron". Shown in the menu bar app
  // so a human reviewer can tell which agent staged the draft.
  source: string | null;
  // Snapshot of the last few messages in the recipient's thread, captured
  // at stage time. Embedded so the menu bar app (or any other reviewer)
  // can display thread context without needing chat.db access. Null when
  // no matching thread was found, or when the lookup failed (no FDA).
  context_messages: DraftContextMessage[] | null;
  // Structured breadcrumb of how the context lookup went. Populated even
  // on success (status: "ok") so the menu bar app can show "no_chat_for_handle"
  // vs "error" vs "no_handle_match" when context_messages is null/empty.
  context_diagnostic: ContextLookupDiagnostic | null;
  // ── Approve-now/send-later (schedule-send) — additive, all nullable ─────────
  // When set, the menu-bar app's scheduler fires this draft at/after this
  // instant (ISO-8601) instead of waiting for hold-to-fire. The user approved
  // the text + time up front; the gate is satisfied at approval, execution is
  // deferred. Null for ordinary hold-to-fire drafts.
  scheduled_send_at: string | null;
  // Set by the scheduler when it declined to send a due scheduled draft —
  // "quiet_hours" or "stale". Surfaced in the Scheduled view; the user resolves
  // it (send now / reschedule / revert to draft). Null when not held.
  schedule_hold_reason: string | null;
  // User/agent request to send a held or scheduled draft immediately, bypassing
  // quiet hours. Honored once by the scheduler. Null/false otherwise.
  override_send: boolean | null;
  // GUI-approval gate: the scheduler ONLY auto-sends a scheduled draft when this
  // is true. The menu-bar Schedule button sets it (the click IS the approval);
  // a scheduled draft written any other way (e.g. by a shell process) stays
  // unapproved and is HELD for explicit in-app approval, never silently sent.
  schedule_approved: boolean | null;
}

function ensureDir(): void {
  const d = draftsDirPath();
  // Walk up one level: check that the *parent* (`~/.messages-mcp`) isn't
  // a symlink before we let `mkdirSync(recursive:true)` traverse it.
  // Without this, an attacker who pre-symlinked the parent before our
  // first run wins — mkdirSync creates `drafts/` *inside* the symlink
  // target and our subsequent same-dir check sees a real directory and
  // proceeds. The drafts-dir-itself check below still matters for the
  // already-bootstrapped case (parent is a real dir, attacker replaces
  // just `drafts/` with a symlink). We use lstatSync directly (not
  // existsSync+lstatSync) because existsSync follows symlinks and would
  // return false for a dangling-symlink parent, skipping the guard.
  const parent = join(d, "..");
  try {
    if (lstatSync(parent).isSymbolicLink()) {
      throw new Error(`drafts parent directory is a symlink, refusing to use: ${parent}`);
    }
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  if (existsSync(d)) {
    if (lstatSync(d).isSymbolicLink()) {
      throw new Error(`drafts directory is a symlink, refusing to use: ${d}`);
    }
    return;
  }
  mkdirSync(d, { recursive: true });
}

function draftPath(id: string): string {
  return join(draftsDirPath(), `${id}.json`);
}

export interface StageDraftArgs {
  to_handle: string;
  to_handle_name?: string | null;
  body: string;
  attachments?: DraftAttachment[] | null;
  in_reply_to_thread_id?: number | null;
  source?: string | null;
  context_messages?: DraftContextMessage[] | null;
  context_diagnostic?: ContextLookupDiagnostic | null;
  scheduled_send_at?: string | null;
  schedule_approved?: boolean | null;
}

export function stageDraft(args: StageDraftArgs): { draft: Draft; path: string } {
  ensureDir();
  const draft: Draft = {
    id: randomUUID(),
    to_handle: args.to_handle,
    to_handle_name: args.to_handle_name ?? null,
    body: args.body,
    attachments: args.attachments ?? [],
    in_reply_to_thread_id: args.in_reply_to_thread_id ?? null,
    staged_at: new Date().toISOString(),
    sent_at: null,
    send_service: null,
    source: args.source ?? null,
    context_messages: args.context_messages ?? null,
    context_diagnostic: args.context_diagnostic ?? null,
    scheduled_send_at: args.scheduled_send_at ?? null,
    schedule_hold_reason: null,
    override_send: null,
    schedule_approved: args.schedule_approved ?? null,
  };
  const path = draftPath(draft.id);
  writeFileSync(path, JSON.stringify(draft, null, 2), { mode: 0o600 });
  return { draft, path };
}

export function listDrafts(limit: number): Draft[] {
  ensureDir();
  const dir = draftsDirPath();
  const entries = readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => {
      const p = join(dir, f);
      return { path: p, mtime: statSync(p).mtimeMs };
    })
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, limit);
  const out: Draft[] = [];
  for (const e of entries) {
    try {
      const normalized = normalizeDraft(JSON.parse(readFileSync(e.path, "utf8")) as Partial<Draft>);
      if (normalized) out.push(normalized);
    } catch {
      // Skip corrupt entries silently — the user can `rm` them by hand.
    }
  }
  return out;
}

export function getDraft(id: string): Draft | null {
  ensureDir();
  const path = draftPath(id);
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8")) as Partial<Draft>;
    return normalizeDraft(raw);
  } catch {
    return null;
  }
}

// Coerce a possibly-legacy / possibly-malformed attachments value into the
// current shape. Drops entries without a usable path; never throws.
function normalizeAttachments(raw: unknown): DraftAttachment[] {
  if (!Array.isArray(raw)) return [];
  const out: DraftAttachment[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const path = typeof o.path === "string" ? o.path : null;
    if (!path) continue;
    out.push({
      path,
      filename: typeof o.filename === "string" && o.filename.length > 0 ? o.filename : basename(path),
      mime_type: typeof o.mime_type === "string" ? o.mime_type : null,
      byte_count: typeof o.byte_count === "number" && Number.isFinite(o.byte_count) ? o.byte_count : null,
    });
  }
  return out;
}

// Backfill fields added in later schema revisions so callers can rely on
// the current Draft shape regardless of when the file was written.
function normalizeDraft(raw: Partial<Draft>): Draft | null {
  if (!raw || !raw.id || !raw.to_handle || raw.body == null || !raw.staged_at) return null;
  return {
    id: raw.id,
    to_handle: raw.to_handle,
    to_handle_name: raw.to_handle_name ?? null,
    body: raw.body,
    attachments: normalizeAttachments(raw.attachments),
    in_reply_to_thread_id: raw.in_reply_to_thread_id ?? null,
    staged_at: raw.staged_at,
    sent_at: raw.sent_at ?? null,
    send_service: raw.send_service ?? null,
    source: raw.source ?? null,
    context_messages: raw.context_messages ?? null,
    context_diagnostic: raw.context_diagnostic ?? null,
    scheduled_send_at: raw.scheduled_send_at ?? null,
    schedule_hold_reason: raw.schedule_hold_reason ?? null,
    override_send: raw.override_send ?? null,
    schedule_approved: raw.schedule_approved ?? null,
  };
}

// Mark a draft as sent. Returns the updated draft, or null if not found.
// Older draft files written before the sent_at field existed will be migrated
// in-place on read (see getDraft), so this just overwrites in the current
// schema.
export function markDraftSent(id: string, sentAt: string, service: "iMessage" | "SMS"): Draft | null {
  const existing = getDraft(id);
  if (!existing) return null;
  // Idempotency guard — match the Swift menubar app's `guard !existing.isSent`
  // check (DraftStore.swift). Without this, a race between the Node MCP
  // server and the Swift app (e.g. user holds Send in menubar while an
  // agent is mid-send_draft) lets the second writer clobber the
  // first writer's `sent_at` + `send_service` + `source` on disk. This is
  // the on-disk-state half of cross-process defense; preventing two
  // AppleScript sends from firing (the wire-level half) needs a file lock
  // acquired by BOTH Node and Swift before their respective sendIMessage
  // calls — tracked as a separate hardening task.
  if (existing.sent_at) return existing;
  const updated: Draft = { ...existing, sent_at: sentAt, send_service: service };
  // Atomic write: temp file + rename. The menu bar app watches the drafts
  // directory via DispatchSourceFileSystemObject, which fires on directory-
  // entry changes (create/delete/rename) but NOT on in-place modifications
  // of existing files. A plain writeFileSync over the existing path leaves
  // the menu bar with a stale in-memory draft (sent_at still null), so the
  // just-sent message stays parked in the "pending" list until the next
  // unrelated directory event. Rename fires the watcher reliably.
  const finalPath = draftPath(id);
  // Refuse to overwrite if finalPath is a symlink. `renameSync` follows
  // symlinks at the destination (no O_NOFOLLOW equivalent in node:fs), so
  // a local-UID attacker who can replace `<id>.json` with a symlink to
  // `~/.zshrc` between getDraft above and the rename below would have us
  // write the JSON-serialized Draft into that target. lstatSync inspects
  // the link itself, not what it points to.
  if (existsSync(finalPath) && lstatSync(finalPath).isSymbolicLink()) {
    throw new Error(`draft path is a symlink, refusing to overwrite: ${finalPath}`);
  }
  const tmpPath = `${finalPath}.tmp-${randomUUID()}`;
  writeFileSync(tmpPath, JSON.stringify(updated, null, 2), { mode: 0o600 });
  try {
    renameSync(tmpPath, finalPath);
  } catch (err) {
    // Rename can throw on EACCES, ENOSPC, EROFS, or transient EBUSY (e.g.
    // Spotlight indexing holds an fd on the tmp file). Without this cleanup
    // the orphan `.tmp-<uuid>` persists at 0600 with the full draft body —
    // recipient handle, message text, and the context_messages snapshot of
    // recent thread messages. Backup tools (Time Machine, Backblaze) and
    // local indexers will happily ingest it.
    try { unlinkSync(tmpPath); } catch { /* best-effort cleanup */ }
    throw err;
  }
  return updated;
}

// Patch the schedule-send fields on a draft (atomic temp+rename so the menu
// bar's directory watcher fires). Used by the MCP override tool so a user can
// ask Claude to send a held/scheduled birthday draft now. Returns the updated
// draft, or null if not found.
export function updateScheduling(
  id: string,
  patch: {
    scheduled_send_at?: string | null;
    schedule_hold_reason?: string | null;
    override_send?: boolean | null;
    schedule_approved?: boolean | null;
  },
): Draft | null {
  const existing = getDraft(id);
  if (!existing) return null;
  const updated: Draft = {
    ...existing,
    scheduled_send_at: patch.scheduled_send_at !== undefined ? patch.scheduled_send_at : existing.scheduled_send_at,
    schedule_hold_reason: patch.schedule_hold_reason !== undefined ? patch.schedule_hold_reason : existing.schedule_hold_reason,
    override_send: patch.override_send !== undefined ? patch.override_send : existing.override_send,
    schedule_approved: patch.schedule_approved !== undefined ? patch.schedule_approved : existing.schedule_approved,
  };
  const finalPath = draftPath(id);
  if (existsSync(finalPath) && lstatSync(finalPath).isSymbolicLink()) {
    throw new Error(`draft path is a symlink, refusing to overwrite: ${finalPath}`);
  }
  const tmpPath = `${finalPath}.tmp-${randomUUID()}`;
  writeFileSync(tmpPath, JSON.stringify(updated, null, 2), { mode: 0o600 });
  try {
    renameSync(tmpPath, finalPath);
  } catch (err) {
    try { unlinkSync(tmpPath); } catch { /* best-effort */ }
    throw err;
  }
  return updated;
}

export function discardDraft(id: string): boolean {
  ensureDir();
  const path = draftPath(id);
  if (!existsSync(path)) return false;
  unlinkSync(path);
  return true;
}

export function draftsDir(): string {
  return draftsDirPath();
}
