// Private, draft-owned attachment snapshots shared by the iMessage and
// WhatsApp staging paths. A caller-provided path is an input only: the draft
// manifest always points at an immutable-at-approval-time copy under the
// transport root's draft-attachments/<draft-id>/ directory.

import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readSync,
  rmSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { basename, dirname, extname, isAbsolute, join, resolve, sep } from "node:path";

export const MAX_DRAFT_ATTACHMENTS = 10;
export const MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024;
export const MAX_DRAFT_ATTACHMENT_BYTES = 250 * 1024 * 1024;

export interface RawAttachmentInput {
  path: string;
  // Kept in the public tool schema for compatibility. Snapshot metadata never
  // trusts these caller claims: filename comes from basename(path) and MIME is
  // sniffed/inferred from the bytes/path.
  filename?: string | null;
  mime_type?: string | null;
}

export interface ManagedDraftAttachment {
  asset_id: string;
  path: string;
  filename: string;
  mime_type: string | null;
  byte_count: number;
  sha256: string;
}

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
  const ext = extname(path).slice(1).toLowerCase();
  return EXT_MIME[ext] ?? null;
}

export function inferMime(path: string, header: Uint8Array): string | null {
  const b = Buffer.from(header);
  if (b.length >= 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 6 && (b.subarray(0, 6).toString("ascii") === "GIF87a" || b.subarray(0, 6).toString("ascii") === "GIF89a")) return "image/gif";
  if (b.length >= 12 && b.subarray(0, 4).toString("ascii") === "RIFF" && b.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
  if (b.length >= 4 && b.subarray(0, 4).toString("ascii") === "%PDF") return "application/pdf";
  if (b.length >= 4 && b[0] === 0x50 && b[1] === 0x4b && b[2] === 0x03 && b[3] === 0x04) return inferMimeFromPath(path) ?? "application/zip";
  if (b.length >= 12 && b.subarray(4, 8).toString("ascii") === "ftyp") {
    const brand = b.subarray(8, 12).toString("ascii").toLowerCase();
    if (["heic", "heix", "hevc", "hevx", "mif1", "msf1"].includes(brand)) return "image/heic";
    if (brand === "qt  ") return "video/quicktime";
    return "video/mp4";
  }
  return inferMimeFromPath(path);
}

export function expandPath(input: string): string {
  let p = input.trim();
  if (p === "~") p = homedir();
  else if (p.startsWith("~/")) p = resolve(homedir(), p.slice(2));
  return isAbsolute(p) ? resolve(p) : resolve(p);
}

function assertDraftId(draftId: string): void {
  if (!/^[A-Za-z0-9_-]+$/.test(draftId)) throw new Error(`invalid draft id: ${draftId}`);
}

function ensurePrivateDirectory(path: string): void {
  try {
    const st = lstatSync(path);
    if (st.isSymbolicLink() || !st.isDirectory()) throw new Error(`attachment directory is not a real directory: ${path}`);
    chmodSync(path, 0o700);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    mkdirSync(path, { recursive: false, mode: 0o700 });
    chmodSync(path, 0o700);
  }
}

export function draftAttachmentDirectory(transportRoot: string, draftId: string): string {
  assertDraftId(draftId);
  return join(transportRoot, "draft-attachments", draftId);
}

export function cleanupDraftAttachments(transportRoot: string, draftId: string): void {
  const attachmentsRoot = join(transportRoot, "draft-attachments");
  try {
    const rootStat = lstatSync(attachmentsRoot);
    if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
      throw new Error(`attachment root is not a real directory: ${attachmentsRoot}`);
    }
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return;
    throw e;
  }
  const dir = draftAttachmentDirectory(transportRoot, draftId);
  try {
    const st = lstatSync(dir);
    if (st.isSymbolicLink()) unlinkSync(dir);
    else rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
}

function destinationExtension(filename: string): string {
  const ext = extname(filename).toLowerCase();
  return /^\.[a-z0-9]{1,12}$/.test(ext) ? ext : "";
}

/**
 * Copy caller paths into a private draft-owned directory. Sources are opened
 * O_NOFOLLOW and copied from that already-validated descriptor, so a symlink
 * swap cannot redirect the snapshot after validation.
 */
export function snapshotDraftAttachments(
  transportRoot: string,
  draftId: string,
  inputs: readonly RawAttachmentInput[] | null | undefined,
): ManagedDraftAttachment[] {
  if (inputs == null || inputs.length === 0) return [];
  if (inputs.length > MAX_DRAFT_ATTACHMENTS) {
    throw new Error(`too many attachments: ${inputs.length} (max ${MAX_DRAFT_ATTACHMENTS})`);
  }

  const attachmentsRoot = join(transportRoot, "draft-attachments");
  const draftDir = draftAttachmentDirectory(transportRoot, draftId);
  ensurePrivateDirectory(transportRoot);
  ensurePrivateDirectory(attachmentsRoot);
  if (lstatSync(attachmentsRoot).isSymbolicLink()) throw new Error(`attachment root is a symlink: ${attachmentsRoot}`);
  try {
    mkdirSync(draftDir, { mode: 0o700 });
    chmodSync(draftDir, 0o700);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "EEXIST") throw new Error(`attachment snapshot already exists for draft ${draftId}`);
    throw e;
  }

  const out: ManagedDraftAttachment[] = [];
  let cumulativeBytes = 0;
  try {
    for (const raw of inputs) {
      if (!raw || typeof raw.path !== "string" || raw.path.trim().length === 0) {
        throw new Error("each attachment needs a non-empty `path`");
      }
      const sourcePath = expandPath(raw.path);
      const filename = basename(sourcePath);
      let sourceFd: number | null = null;
      let destFd: number | null = null;
      try {
        sourceFd = openSync(sourcePath, constants.O_RDONLY | constants.O_NOFOLLOW);
        const sourceStat = fstatSync(sourceFd);
        if (!sourceStat.isFile()) throw new Error(`attachment is not a regular file: ${raw.path}`);
        if (sourceStat.size > MAX_ATTACHMENT_BYTES) {
          throw new Error(`attachment too large: ${raw.path} is ${(sourceStat.size / (1024 * 1024)).toFixed(1)} MB (max 100 MB)`);
        }
        cumulativeBytes += sourceStat.size;
        if (cumulativeBytes > MAX_DRAFT_ATTACHMENT_BYTES) {
          throw new Error(`attachments total ${(cumulativeBytes / (1024 * 1024)).toFixed(1)} MB exceeds 250 MB per draft`);
        }

        const asset_id = randomUUID();
        const managedPath = join(draftDir, `${asset_id}${destinationExtension(filename)}`);
        destFd = openSync(
          managedPath,
          constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
          0o600,
        );
        const hash = createHash("sha256");
        const header = Buffer.alloc(32);
        const buffer = Buffer.allocUnsafe(1024 * 1024);
        let total = 0;
        let headerBytes = 0;
        while (true) {
          const n = readSync(sourceFd, buffer, 0, buffer.length, null);
          if (n === 0) break;
          total += n;
          if (total > MAX_ATTACHMENT_BYTES) throw new Error(`attachment grew beyond 100 MB while staging: ${raw.path}`);
          if (cumulativeBytes - sourceStat.size + total > MAX_DRAFT_ATTACHMENT_BYTES) {
            throw new Error("attachments grew beyond 250 MB cumulative limit while staging");
          }
          if (headerBytes < header.length) {
            const take = Math.min(n, header.length - headerBytes);
            buffer.copy(header, headerBytes, 0, take);
            headerBytes += take;
          }
          hash.update(buffer.subarray(0, n));
          let written = 0;
          while (written < n) written += writeSync(destFd, buffer, written, n - written);
        }
        if (total !== sourceStat.size) throw new Error(`attachment changed size while staging: ${raw.path}`);
        fsyncSync(destFd);
        chmodSync(managedPath, 0o600);
        out.push({
          asset_id,
          path: managedPath,
          filename,
          mime_type: inferMime(sourcePath, header.subarray(0, headerBytes)),
          byte_count: total,
          sha256: hash.digest("hex"),
        });
      } catch (e) {
        const code = (e as NodeJS.ErrnoException).code;
        if (code === "ELOOP") throw new Error(`attachment path must not be a symlink: ${raw.path}`);
        if (code === "ENOENT" || code === "EACCES") throw new Error(`attachment file not found or unreadable: ${raw.path}`);
        throw e;
      } finally {
        if (destFd != null) try { closeSync(destFd); } catch { /* best effort */ }
        if (sourceFd != null) try { closeSync(sourceFd); } catch { /* best effort */ }
      }
    }
    return out;
  } catch (e) {
    cleanupDraftAttachments(transportRoot, draftId);
    throw e;
  }
}

export function isManagedDraftAttachment(value: unknown): value is ManagedDraftAttachment {
  if (!value || typeof value !== "object") return false;
  const a = value as Record<string, unknown>;
  return (
    typeof a.asset_id === "string" && /^[0-9a-f-]{36}$/i.test(a.asset_id) &&
    typeof a.path === "string" &&
    typeof a.filename === "string" && a.filename.length > 0 &&
    (a.mime_type === null || typeof a.mime_type === "string") &&
    typeof a.byte_count === "number" && Number.isSafeInteger(a.byte_count) && a.byte_count >= 0 &&
    typeof a.sha256 === "string" && /^[0-9a-f]{64}$/i.test(a.sha256)
  );
}

/** Verify ownership, regular-file shape, byte count, and SHA-256 immediately before delivery. */
export function verifyManagedDraftAttachment(
  transportRoot: string,
  draftId: string,
  attachment: unknown,
): { ok: true; attachment: ManagedDraftAttachment } | { ok: false; error: string } {
  if (!isManagedDraftAttachment(attachment)) {
    return { ok: false, error: "legacy or incomplete attachment manifest; discard and restage this draft" };
  }
  const expectedDir = draftAttachmentDirectory(transportRoot, draftId);
  const managedPath = resolve(attachment.path);
  if (dirname(managedPath) !== resolve(expectedDir) || !managedPath.startsWith(resolve(expectedDir) + sep)) {
    return { ok: false, error: "attachment path is outside this draft's managed snapshot; discard and restage" };
  }
  if (!basename(managedPath).startsWith(attachment.asset_id)) {
    return { ok: false, error: "attachment path does not match its asset id; discard and restage" };
  }
  let fd: number | null = null;
  try {
    const rootStat = lstatSync(join(transportRoot, "draft-attachments"));
    const dirStat = lstatSync(expectedDir);
    if (rootStat.isSymbolicLink() || !rootStat.isDirectory() || dirStat.isSymbolicLink() || !dirStat.isDirectory()) {
      return { ok: false, error: "attachment snapshot directory is not trustworthy; discard and restage" };
    }
    fd = openSync(managedPath, constants.O_RDONLY | constants.O_NOFOLLOW);
    const st = fstatSync(fd);
    if (!st.isFile()) return { ok: false, error: "managed attachment is not a regular file; discard and restage" };
    if (st.size !== attachment.byte_count) return { ok: false, error: "managed attachment byte count changed; discard and restage" };
    const hash = createHash("sha256");
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    while (true) {
      const n = readSync(fd, buffer, 0, buffer.length, null);
      if (n === 0) break;
      hash.update(buffer.subarray(0, n));
    }
    if (hash.digest("hex") !== attachment.sha256.toLowerCase()) {
      return { ok: false, error: "managed attachment hash changed; discard and restage" };
    }
    return { ok: true, attachment };
  } catch {
    return { ok: false, error: "managed attachment is missing or unreadable; discard and restage" };
  } finally {
    if (fd != null) try { closeSync(fd); } catch { /* best effort */ }
  }
}
