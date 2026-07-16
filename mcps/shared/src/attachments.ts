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
  readdirSync,
  rmdirSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { promises as fsPromises } from "node:fs";
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

export interface VerifiedAttachmentBytes {
  attachment: ManagedDraftAttachment;
  bytes: Buffer;
}

interface StableDirectory {
  fd: number;
  path: string;
  dev: bigint;
  ino: bigint;
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

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isManagedAssetName(fileName: string, assetId: string): boolean {
  if (fileName === assetId) return true;
  return fileName.startsWith(`${assetId}.`) && /^[a-z0-9]{1,12}$/.test(fileName.slice(assetId.length + 1));
}

function isManagedSnapshotFileName(fileName: string): boolean {
  const dot = fileName.indexOf(".");
  const assetId = dot === -1 ? fileName : fileName.slice(0, dot);
  return UUID_RE.test(assetId) && isManagedAssetName(fileName, assetId);
}

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
  if (!UUID_RE.test(draftId)) throw new Error(`invalid draft id: ${draftId}`);
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

function stableDirectoryPath(fd: number, stat: { dev: bigint; ino: bigint }): string {
  if (process.platform === "linux") return `/proc/self/fd/${fd}`;
  if (process.platform === "darwin") return `/.vol/${stat.dev.toString()}/${stat.ino.toString()}`;
  throw new Error(`unsupported platform for descriptor-pinned attachment access: ${process.platform}`);
}

/** Open a directory without following its final component and bind it by inode. */
function openStableDirectory(path: string): StableDirectory {
  const directoryFlag = (constants as typeof constants & { O_DIRECTORY: number }).O_DIRECTORY;
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | directoryFlag);
  try {
    const stat = fstatSync(fd, { bigint: true });
    if (!stat.isDirectory()) throw new Error(`not a directory: ${path}`);
    return { fd, path: stableDirectoryPath(fd, stat), dev: stat.dev, ino: stat.ino };
  } catch (error) {
    closeSync(fd);
    throw error;
  }
}

/**
 * Pin every managed-directory component, then address the asset through the
 * draft directory's file-id path. Renaming or replacing any pathname after
 * this point cannot redirect the open to a different directory.
 */
function openManagedDraftDirectory(transportRoot: string, draftId: string): StableDirectory {
  assertDraftId(draftId);
  const root = openStableDirectory(transportRoot);
  try {
    const attachmentRoot = openStableDirectory(join(root.path, "draft-attachments"));
    try {
      return openStableDirectory(join(attachmentRoot.path, draftId));
    } finally {
      closeSync(attachmentRoot.fd);
    }
  } finally {
    closeSync(root.fd);
  }
}

export function draftAttachmentDirectory(transportRoot: string, draftId: string): string {
  assertDraftId(draftId);
  return join(transportRoot, "draft-attachments", draftId);
}

export function cleanupDraftAttachments(transportRoot: string, draftId: string): void {
  assertDraftId(draftId);
  let root: StableDirectory | null = null;
  let attachmentsRoot: StableDirectory | null = null;
  let draftDirectory: StableDirectory | null = null;
  try {
    root = openStableDirectory(transportRoot);
    attachmentsRoot = openStableDirectory(join(root.path, "draft-attachments"));
    draftDirectory = openStableDirectory(join(attachmentsRoot.path, draftId));

    for (const fileName of readdirSync(draftDirectory.path)) {
      if (!isManagedSnapshotFileName(fileName)) continue;
      const filePath = join(draftDirectory.path, fileName);
      try {
        const fileStat = lstatSync(filePath);
        if (!fileStat.isFile() || fileStat.isSymbolicLink()) continue;
        try { unlinkSync(filePath); } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
        throw error;
      }
    }

    // Remove the parent entry only if it still names the exact directory we
    // pinned. A concurrent rename/replacement can leave an orphan, but it can
    // never redirect cleanup into another tree.
    const current = lstatSync(join(attachmentsRoot.path, draftId), { bigint: true });
    if (current.isDirectory() && current.dev === draftDirectory.dev && current.ino === draftDirectory.ino) {
      try { rmdirSync(join(attachmentsRoot.path, draftId)); } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT" &&
            (error as NodeJS.ErrnoException).code !== "ENOTEMPTY") throw error;
      }
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  } finally {
    if (draftDirectory != null) try { closeSync(draftDirectory.fd); } catch { /* best effort */ }
    if (attachmentsRoot != null) try { closeSync(attachmentsRoot.fd); } catch { /* best effort */ }
    if (root != null) try { closeSync(root.fd); } catch { /* best effort */ }
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
    typeof a.asset_id === "string" && UUID_RE.test(a.asset_id) &&
    typeof a.path === "string" &&
    typeof a.filename === "string" && a.filename.length > 0 &&
    (a.mime_type === null || typeof a.mime_type === "string") &&
    typeof a.byte_count === "number" && Number.isSafeInteger(a.byte_count) && a.byte_count >= 0 &&
    typeof a.sha256 === "string" && /^[0-9a-f]{64}$/i.test(a.sha256)
  );
}

export function validateManagedDraftAttachmentSet(
  attachments: readonly unknown[],
): { ok: true; attachments: ManagedDraftAttachment[] } | { ok: false; error: string } {
  if (attachments.length > MAX_DRAFT_ATTACHMENTS) {
    return { ok: false, error: `too many attachments (max ${MAX_DRAFT_ATTACHMENTS}); discard and restage` };
  }
  const managed: ManagedDraftAttachment[] = [];
  let total = 0;
  for (const attachment of attachments) {
    if (!isManagedDraftAttachment(attachment)) {
      return { ok: false, error: "legacy or incomplete attachment manifest; discard and restage this draft" };
    }
    if (attachment.byte_count > MAX_ATTACHMENT_BYTES) {
      return { ok: false, error: "an attachment exceeds the 100 MB limit; discard and restage" };
    }
    total += attachment.byte_count;
    if (!Number.isSafeInteger(total) || total > MAX_DRAFT_ATTACHMENT_BYTES) {
      return { ok: false, error: "attachments exceed the 250 MB per-draft limit; discard and restage" };
    }
    managed.push(attachment);
  }
  return { ok: true, attachments: managed };
}

/**
 * Validate a managed manifest and regular-file ownership without reading the
 * payload. The WhatsApp daemon uses this at stage time so adopting a caller's
 * already-hashed snapshot never blocks its event loop on up to 250 MB of I/O.
 * Full descriptor-pinned hashing still runs immediately before delivery.
 */
export function validateManagedDraftAttachmentSnapshot(
  transportRoot: string,
  draftId: string,
  attachment: unknown,
): { ok: true; attachment: ManagedDraftAttachment } | { ok: false; error: string } {
  if (!isManagedDraftAttachment(attachment)) {
    return { ok: false, error: "legacy or incomplete attachment manifest; discard and restage this draft" };
  }
  if (attachment.byte_count > MAX_ATTACHMENT_BYTES) {
    return { ok: false, error: "managed attachment exceeds the 100 MB limit; discard and restage" };
  }
  const expectedDir = draftAttachmentDirectory(transportRoot, draftId);
  const managedPath = resolve(attachment.path);
  if (dirname(managedPath) !== resolve(expectedDir) || !managedPath.startsWith(resolve(expectedDir) + sep)) {
    return { ok: false, error: "attachment path is outside this draft's managed snapshot; discard and restage" };
  }
  if (!isManagedAssetName(basename(managedPath), attachment.asset_id)) {
    return { ok: false, error: "attachment path does not match its asset id; discard and restage" };
  }
  let fd: number | null = null;
  let draftDirectory: StableDirectory | null = null;
  try {
    draftDirectory = openManagedDraftDirectory(transportRoot, draftId);
    fd = openSync(join(draftDirectory.path, basename(managedPath)), constants.O_RDONLY | constants.O_NOFOLLOW);
    const st = fstatSync(fd);
    if (!st.isFile()) return { ok: false, error: "managed attachment is not a regular file; discard and restage" };
    if (st.size !== attachment.byte_count) {
      return { ok: false, error: "managed attachment byte count changed; discard and restage" };
    }
    return { ok: true, attachment };
  } catch {
    return { ok: false, error: "managed attachment is missing or unreadable; discard and restage" };
  } finally {
    if (fd != null) try { closeSync(fd); } catch { /* best effort */ }
    if (draftDirectory != null) try { closeSync(draftDirectory.fd); } catch { /* best effort */ }
  }
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
  if (attachment.byte_count > MAX_ATTACHMENT_BYTES) {
    return { ok: false, error: "managed attachment exceeds the 100 MB limit; discard and restage" };
  }
  const expectedDir = draftAttachmentDirectory(transportRoot, draftId);
  const managedPath = resolve(attachment.path);
  if (dirname(managedPath) !== resolve(expectedDir) || !managedPath.startsWith(resolve(expectedDir) + sep)) {
    return { ok: false, error: "attachment path is outside this draft's managed snapshot; discard and restage" };
  }
  if (!isManagedAssetName(basename(managedPath), attachment.asset_id)) {
    return { ok: false, error: "attachment path does not match its asset id; discard and restage" };
  }
  let fd: number | null = null;
  let draftDirectory: StableDirectory | null = null;
  try {
    draftDirectory = openManagedDraftDirectory(transportRoot, draftId);
    fd = openSync(join(draftDirectory.path, basename(managedPath)), constants.O_RDONLY | constants.O_NOFOLLOW);
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
    if (draftDirectory != null) try { closeSync(draftDirectory.fd); } catch { /* best effort */ }
  }
}

/**
 * Load the exact verified bytes through one O_NOFOLLOW descriptor. The caller
 * must pass the returned Buffer directly to its transport instead of reopening
 * `attachment.path`, which would reintroduce a post-verification swap window.
 * Async file I/O keeps the WhatsApp daemon event loop responsive for large
 * (up to 100 MB) media.
 */
export async function loadVerifiedDraftAttachmentBytes(
  transportRoot: string,
  draftId: string,
  attachment: unknown,
): Promise<{ ok: true; value: VerifiedAttachmentBytes } | { ok: false; error: string }> {
  if (!isManagedDraftAttachment(attachment)) {
    return { ok: false, error: "legacy or incomplete attachment manifest; discard and restage this draft" };
  }
  if (attachment.byte_count > MAX_ATTACHMENT_BYTES) {
    return { ok: false, error: "managed attachment exceeds the 100 MB limit; discard and restage" };
  }
  const expectedDir = draftAttachmentDirectory(transportRoot, draftId);
  const managedPath = resolve(attachment.path);
  if (dirname(managedPath) !== resolve(expectedDir) || !managedPath.startsWith(resolve(expectedDir) + sep)) {
    return { ok: false, error: "attachment path is outside this draft's managed snapshot; discard and restage" };
  }
  if (!isManagedAssetName(basename(managedPath), attachment.asset_id)) {
    return { ok: false, error: "attachment path does not match its asset id; discard and restage" };
  }

  let handle: Awaited<ReturnType<typeof fsPromises.open>> | null = null;
  let draftDirectory: StableDirectory | null = null;
  try {
    draftDirectory = openManagedDraftDirectory(transportRoot, draftId);
    handle = await fsPromises.open(
      join(draftDirectory.path, basename(managedPath)),
      constants.O_RDONLY | constants.O_NOFOLLOW,
    );
    const st = await handle.stat();
    if (!st.isFile()) return { ok: false, error: "managed attachment is not a regular file; discard and restage" };
    if (st.size !== attachment.byte_count) {
      return { ok: false, error: "managed attachment byte count changed; discard and restage" };
    }
    const bytes = await handle.readFile();
    if (bytes.byteLength !== attachment.byte_count) {
      return { ok: false, error: "managed attachment changed while being read; discard and restage" };
    }
    const actualHash = createHash("sha256").update(bytes).digest("hex");
    if (actualHash !== attachment.sha256.toLowerCase()) {
      return { ok: false, error: "managed attachment hash changed; discard and restage" };
    }
    return { ok: true, value: { attachment, bytes } };
  } catch {
    return { ok: false, error: "managed attachment is missing or unreadable; discard and restage" };
  } finally {
    if (handle != null) await handle.close().catch(() => undefined);
    if (draftDirectory != null) try { closeSync(draftDirectory.fd); } catch { /* best effort */ }
  }
}
