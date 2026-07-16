import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
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
  validateManagedDraftAttachmentSet,
  verifyManagedDraftAttachment,
} from "../../shared/src/attachments.ts";

let root: string;

function draftId(n: number): string {
  return `00000000-0000-4000-8000-${n.toString().padStart(12, "0")}`;
}

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
    const [attachment] = snapshotDraftAttachments(root, draftId(1), [{
      path: source,
      filename: "spoof.pdf",
      mime_type: "application/pdf",
    }]);
    expect(attachment).toBeDefined();
    rmSync(source);

    expect(attachment!.filename).toBe("photo.jpg");
    expect(attachment!.mime_type).toBe("image/jpeg");
    expect(attachment!.path).toStartWith(join(root, "draft-attachments", draftId(1)));
    expect(readFileSync(attachment!.path)).toEqual(Buffer.from([0xff, 0xd8, 0xff, 0x01]));
    expect(statSync(join(root, "draft-attachments")).mode & 0o777).toBe(0o700);
    expect(statSync(join(root, "draft-attachments", draftId(1))).mode & 0o777).toBe(0o700);
    expect(statSync(attachment!.path).mode & 0o777).toBe(0o600);
    expect(verifyManagedDraftAttachment(root, draftId(1), attachment).ok).toBe(true);
  });

  test("rejects source symlinks and cleans the partial draft directory", () => {
    const target = makeFile("target.txt");
    const link = join(root, "link.txt");
    symlinkSync(target, link);
    expect(() => snapshotDraftAttachments(root, draftId(2), [{ path: link }])).toThrow(/symlink/);
    expect(existsSync(join(root, "draft-attachments", draftId(2)))).toBe(false);
  });

  test("detects byte and manifest tampering before delivery", () => {
    const [attachment] = snapshotDraftAttachments(root, draftId(3), [{ path: makeFile("note.txt") }]);
    writeFileSync(attachment!.path, "HELLO");
    const bytes = verifyManagedDraftAttachment(root, draftId(3), attachment);
    expect(bytes.ok).toBe(false);
    if (!bytes.ok) expect(bytes.error).toContain("hash changed");
    expect(verifyManagedDraftAttachment(root, draftId(3), { ...attachment!, path: makeFile("other.txt") }).ok).toBe(false);
    expect(verifyManagedDraftAttachment(root, draftId(3), { path: attachment!.path }).ok).toBe(false);
  });

  test("rejects a symlinked managed draft directory instead of reading its target", () => {
    const [attachment] = snapshotDraftAttachments(root, draftId(4), [{
      path: makeFile("parent-link-source.txt", "reviewed"),
    }]);
    const draftDir = join(root, "draft-attachments", draftId(4));
    const target = join(root, "protected-target");
    mkdirSync(target, { mode: 0o700 });
    writeFileSync(join(target, attachment!.path.split("/").pop()!), "reviewed");
    rmSync(draftDir, { recursive: true });
    symlinkSync(target, draftDir);

    expect(verifyManagedDraftAttachment(root, draftId(4), attachment).ok).toBe(false);
    expect(readFileSync(join(target, attachment!.path.split("/").pop()!), "utf8")).toBe("reviewed");
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
    expect(() => snapshotDraftAttachments(root, draftId(5), [{ path: a }, { path: b }, { path: c }])).toThrow(/250 MB/);
    expect(existsSync(join(root, "draft-attachments", draftId(5)))).toBe(false);
  });

  test("enforces count and 100 MB per-file caps", () => {
    const tooLarge = makeFile("too-large.bin");
    truncateSync(tooLarge, MAX_ATTACHMENT_BYTES + 1);
    expect(() => snapshotDraftAttachments(root, draftId(6), [{ path: tooLarge }])).toThrow(/100 MB/);
    const one = makeFile("one.txt");
    expect(() => snapshotDraftAttachments(
      root,
      draftId(7),
      Array.from({ length: MAX_DRAFT_ATTACHMENTS + 1 }, () => ({ path: one })),
    )).toThrow(/too many attachments/);
  });

  test("re-enforces count, per-file, and aggregate caps on a hand-written manifest", () => {
    const base = {
      asset_id: "00000000-0000-4000-8000-000000000001",
      path: "/tmp/managed.bin",
      filename: "managed.bin",
      mime_type: null,
      byte_count: 1,
      sha256: "a".repeat(64),
    };
    expect(validateManagedDraftAttachmentSet(
      Array.from({ length: MAX_DRAFT_ATTACHMENTS + 1 }, () => base),
    ).ok).toBe(false);
    expect(validateManagedDraftAttachmentSet([{ ...base, byte_count: MAX_ATTACHMENT_BYTES + 1 }]).ok).toBe(false);
    expect(validateManagedDraftAttachmentSet([
      { ...base, byte_count: 90 * 1024 * 1024 },
      { ...base, asset_id: "00000000-0000-4000-8000-000000000002", byte_count: 90 * 1024 * 1024 },
      { ...base, asset_id: "00000000-0000-4000-8000-000000000003", byte_count: 90 * 1024 * 1024 },
    ]).ok).toBe(false);
  });

  test("requires canonical UUID asset ids and exact managed filenames", () => {
    const source = makeFile("exact-name.png", "reviewed");
    const [attachment] = snapshotDraftAttachments(root, draftId(8), [{ path: source }]);
    expect(attachment).toBeDefined();
    const wrongName = `${attachment!.path}.extra`;
    writeFileSync(wrongName, "reviewed");
    expect(verifyManagedDraftAttachment(root, draftId(8), {
      ...attachment!,
      path: wrongName,
      byte_count: 8,
    }).ok).toBe(false);
    expect(validateManagedDraftAttachmentSet([{
      ...attachment!,
      asset_id: "------------------------------------",
    }]).ok).toBe(false);
  });

  test("cleanup removes only the selected draft snapshot", () => {
    const source = makeFile("x.txt");
    const [a] = snapshotDraftAttachments(root, draftId(9), [{ path: source }]);
    const [b] = snapshotDraftAttachments(root, draftId(10), [{ path: source }]);
    const unrecognized = join(root, "draft-attachments", draftId(9), "keep.txt");
    writeFileSync(unrecognized, "keep");
    cleanupDraftAttachments(root, draftId(9));
    expect(existsSync(a!.path)).toBe(false);
    expect(readFileSync(unrecognized, "utf8")).toBe("keep");
    expect(existsSync(b!.path)).toBe(true);
  });

  test("cleanup refuses a symlinked attachment root without touching its target", () => {
    const id = draftId(12);
    const protectedRoot = join(root, "protected-root");
    const protectedDraft = join(protectedRoot, id);
    mkdirSync(protectedDraft, { recursive: true, mode: 0o700 });
    const protectedFile = join(protectedDraft, `${draftId(13)}.txt`);
    writeFileSync(protectedFile, "keep");
    symlinkSync(protectedRoot, join(root, "draft-attachments"));

    expect(() => cleanupDraftAttachments(root, id)).toThrow();
    expect(readFileSync(protectedFile, "utf8")).toBe("keep");
  });

  test("fails unreadable source opens", () => {
    const source = makeFile("private.txt");
    chmodSync(source, 0o000);
    // Root can still read mode-000 files on some CI hosts, so only pin the
    // regular-file/no-follow shape here when the OS grants the open.
    try {
      const [attachment] = snapshotDraftAttachments(root, draftId(11), [{ path: source }]);
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
