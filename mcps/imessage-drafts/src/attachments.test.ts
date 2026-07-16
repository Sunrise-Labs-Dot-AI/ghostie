import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cleanupDraftAttachments,
  inferMimeFromPath,
  MAX_ATTACHMENT_BYTES,
  MAX_DRAFT_ATTACHMENTS,
  MAX_DRAFT_ATTACHMENT_BYTES,
  snapshotDraftAttachments,
  verifyManagedDraftAttachment,
} from "../../shared/src/attachments.ts";

let root: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ghostie-attach-test-"));
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

function makeFile(name: string, data: Uint8Array | string = "hello"): string {
  const path = join(root, name);
  writeFileSync(path, data);
  return path;
}

describe("draft-owned attachment snapshots", () => {
  test("copies bytes into a private manifest that survives source deletion", () => {
    const source = makeFile("photo.jpg", Buffer.from([0xff, 0xd8, 0xff, 0x01]));
    const [attachment] = snapshotDraftAttachments(root, "draft-one", [{
      path: source,
      filename: "spoof.pdf",
      mime_type: "application/pdf",
    }]);
    expect(attachment).toBeDefined();
    rmSync(source);

    expect(attachment!.filename).toBe("photo.jpg");
    expect(attachment!.mime_type).toBe("image/jpeg");
    expect(attachment!.path).toStartWith(join(root, "draft-attachments", "draft-one"));
    expect(readFileSync(attachment!.path)).toEqual(Buffer.from([0xff, 0xd8, 0xff, 0x01]));
    expect(statSync(join(root, "draft-attachments")).mode & 0o777).toBe(0o700);
    expect(statSync(join(root, "draft-attachments", "draft-one")).mode & 0o777).toBe(0o700);
    expect(statSync(attachment!.path).mode & 0o777).toBe(0o600);
    expect(verifyManagedDraftAttachment(root, "draft-one", attachment).ok).toBe(true);
  });

  test("rejects source symlinks and cleans the partial draft directory", () => {
    const target = makeFile("target.txt");
    const link = join(root, "link.txt");
    symlinkSync(target, link);
    expect(() => snapshotDraftAttachments(root, "draft-link", [{ path: link }])).toThrow(/symlink/);
    expect(existsSync(join(root, "draft-attachments", "draft-link"))).toBe(false);
  });

  test("detects byte and manifest tampering before delivery", () => {
    const [attachment] = snapshotDraftAttachments(root, "draft-tamper", [{ path: makeFile("note.txt") }]);
    writeFileSync(attachment!.path, "HELLO");
    const bytes = verifyManagedDraftAttachment(root, "draft-tamper", attachment);
    expect(bytes.ok).toBe(false);
    if (!bytes.ok) expect(bytes.error).toContain("hash changed");
    expect(verifyManagedDraftAttachment(root, "draft-tamper", { ...attachment!, path: makeFile("other.txt") }).ok).toBe(false);
    expect(verifyManagedDraftAttachment(root, "draft-tamper", { path: attachment!.path }).ok).toBe(false);
  });

  test("enforces the 250 MB cumulative cap before copying", () => {
    const a = makeFile("a.bin");
    const b = makeFile("b.bin");
    const c = makeFile("c.bin");
    // Sparse files keep this regression fast while exercising real fstat sizes.
    truncateSync(a, 90 * 1024 * 1024);
    truncateSync(b, 90 * 1024 * 1024);
    truncateSync(c, 90 * 1024 * 1024);
    expect(MAX_DRAFT_ATTACHMENT_BYTES).toBe(250 * 1024 * 1024);
    expect(() => snapshotDraftAttachments(root, "draft-cap", [{ path: a }, { path: b }, { path: c }])).toThrow(/250 MB/);
    expect(existsSync(join(root, "draft-attachments", "draft-cap"))).toBe(false);
  });

  test("enforces count and 100 MB per-file caps", () => {
    const tooLarge = makeFile("too-large.bin");
    truncateSync(tooLarge, MAX_ATTACHMENT_BYTES + 1);
    expect(() => snapshotDraftAttachments(root, "draft-large", [{ path: tooLarge }])).toThrow(/100 MB/);
    const one = makeFile("one.txt");
    expect(() => snapshotDraftAttachments(
      root,
      "draft-count",
      Array.from({ length: MAX_DRAFT_ATTACHMENTS + 1 }, () => ({ path: one })),
    )).toThrow(/too many attachments/);
  });

  test("cleanup removes only the selected draft snapshot", () => {
    const source = makeFile("x.txt");
    const [a] = snapshotDraftAttachments(root, "draft-a", [{ path: source }]);
    const [b] = snapshotDraftAttachments(root, "draft-b", [{ path: source }]);
    cleanupDraftAttachments(root, "draft-a");
    expect(existsSync(a!.path)).toBe(false);
    expect(existsSync(b!.path)).toBe(true);
  });

  test("fails unreadable source opens", () => {
    const source = makeFile("private.txt");
    chmodSync(source, 0o000);
    // Root can still read mode-000 files on some CI hosts, so only pin the
    // regular-file/no-follow shape here when the OS grants the open.
    try {
      const [attachment] = snapshotDraftAttachments(root, "draft-readable", [{ path: source }]);
      expect(lstatSync(attachment!.path).isFile()).toBe(true);
    } catch (e) {
      expect((e as Error).message).toContain("unreadable");
    }
  });
});

describe("inferMimeFromPath", () => {
  test("maps common extensions", () => {
    expect(inferMimeFromPath("/x/a.HEIC")).toBe("image/heic");
    expect(inferMimeFromPath("/x/a.mov")).toBe("video/quicktime");
    expect(inferMimeFromPath("/x/a.unknownext")).toBeNull();
  });
});
