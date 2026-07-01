// Shared validation + resolution for outbound draft attachments (photos,
// videos, documents). Used by every stage path — the iMessage stage tool, the
// WhatsApp stage tool, and the generalized Ghostie facade — so the rules on
// what a human can be asked to approve-and-send are identical across transports.
//
// The trust model: an agent proposes a file path, a human reviews the draft
// (filename + preview + size) in the menu bar and holds-to-fire to send. The
// human review IS the authorization for sending a local file. These checks are
// the guardrails around that gate, NOT a substitute for it:
//   - the file must exist and be a regular file at stage time (catch typos /
//     hallucinated paths before they reach the approval surface),
//   - per-file and per-draft size caps (a runaway send can't pin Messages.app
//     or blow past transport limits),
//   - a count cap (one draft can't smuggle a directory's worth of files).
// We deliberately do NOT restrict which directory a path lives in: the user may
// legitimately ask to send anything they reference, and the approval gate is
// what makes that safe.

import { statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, resolve } from "node:path";

export const MAX_DRAFT_ATTACHMENTS = 10;
// 100 MB per file. Comfortably above iMessage's practical limits and at/above
// WhatsApp's document ceiling; the transport rejects anything it can't carry,
// this is just the belt that stops an accidental multi-GB send.
export const MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024;

export interface RawAttachmentInput {
  path: string;
  filename?: string | null;
  mime_type?: string | null;
}

export interface ResolvedAttachment {
  path: string;
  filename: string;
  mime_type: string | null;
  byte_count: number | null;
}

export type ResolveResult =
  | { ok: true; attachments: ResolvedAttachment[] }
  | { ok: false; error: string };

// Minimal extension → MIME map for inference when the caller didn't supply one.
// Covers the common photo/video/audio/doc types; anything unknown stays null
// and the transport falls back to a generic document send.
const EXT_MIME: Record<string, string> = {
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  gif: "image/gif",
  heic: "image/heic",
  heif: "image/heif",
  webp: "image/webp",
  tiff: "image/tiff",
  bmp: "image/bmp",
  mov: "video/quicktime",
  mp4: "video/mp4",
  m4v: "video/x-m4v",
  webm: "video/webm",
  mkv: "video/x-matroska",
  "3gp": "video/3gpp",
  avi: "video/x-msvideo",
  m4a: "audio/mp4",
  mp3: "audio/mpeg",
  aac: "audio/aac",
  wav: "audio/wav",
  caf: "audio/x-caf",
  ogg: "audio/ogg",
  opus: "audio/opus",
  pdf: "application/pdf",
  txt: "text/plain",
  csv: "text/csv",
  doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ppt: "application/vnd.ms-powerpoint",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  zip: "application/zip",
};

export function inferMimeFromPath(path: string): string | null {
  const ext = basename(path).toLowerCase().split(".").pop() ?? "";
  return EXT_MIME[ext] ?? null;
}

// Expand a leading `~` / `~/...` to the user's home directory, then resolve to
// an absolute path. A bare relative path is resolved against the process CWD —
// agents should pass absolute paths, but this keeps a relative path usable
// rather than silently wrong.
export function expandPath(input: string): string {
  let p = input.trim();
  if (p === "~") p = homedir();
  else if (p.startsWith("~/")) p = resolve(homedir(), p.slice(2));
  return isAbsolute(p) ? p : resolve(p);
}

// Validate + normalize a batch of attachment inputs. Returns a single error
// string on the first failure (so the agent gets one clear, actionable message)
// or the resolved list on success. An empty / absent input resolves to [].
export function resolveDraftAttachments(inputs: RawAttachmentInput[] | undefined | null): ResolveResult {
  if (inputs == null || inputs.length === 0) return { ok: true, attachments: [] };
  if (inputs.length > MAX_DRAFT_ATTACHMENTS) {
    return { ok: false, error: `too many attachments: ${inputs.length} (max ${MAX_DRAFT_ATTACHMENTS})` };
  }
  const out: ResolvedAttachment[] = [];
  for (const raw of inputs) {
    if (!raw || typeof raw.path !== "string" || raw.path.trim().length === 0) {
      return { ok: false, error: "each attachment needs a non-empty `path`" };
    }
    const abs = expandPath(raw.path);
    let size: number | null = null;
    try {
      const st = statSync(abs);
      if (!st.isFile()) {
        return { ok: false, error: `attachment is not a regular file: ${raw.path}` };
      }
      size = st.size;
    } catch {
      return { ok: false, error: `attachment file not found or unreadable: ${raw.path}` };
    }
    if (size != null && size > MAX_ATTACHMENT_BYTES) {
      const mb = (size / (1024 * 1024)).toFixed(1);
      return { ok: false, error: `attachment too large: ${raw.path} is ${mb} MB (max ${MAX_ATTACHMENT_BYTES / (1024 * 1024)} MB)` };
    }
    const filename =
      typeof raw.filename === "string" && raw.filename.trim().length > 0 ? raw.filename.trim() : basename(abs);
    const mime_type =
      typeof raw.mime_type === "string" && raw.mime_type.trim().length > 0 ? raw.mime_type.trim() : inferMimeFromPath(abs);
    out.push({ path: abs, filename, mime_type, byte_count: size });
  }
  return { ok: true, attachments: out };
}
