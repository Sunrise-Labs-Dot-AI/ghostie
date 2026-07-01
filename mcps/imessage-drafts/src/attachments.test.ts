// Unit tests for the shared outbound-attachment resolver. Lives in this
// package (rather than mcps/shared, which has no test target) because the
// iMessage stage tool is the primary consumer.

import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveDraftAttachments,
  inferMimeFromPath,
  MAX_DRAFT_ATTACHMENTS,
} from "../../shared/src/attachments.ts";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ghostie-attach-test-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function makeFile(name: string, bytes = 4): string {
  const p = join(dir, name);
  writeFileSync(p, Buffer.alloc(bytes, 1));
  return p;
}

describe("resolveDraftAttachments", () => {
  test("empty / absent input resolves to []", () => {
    expect(resolveDraftAttachments(undefined)).toEqual({ ok: true, attachments: [] });
    expect(resolveDraftAttachments([])).toEqual({ ok: true, attachments: [] });
  });

  test("resolves an existing file, capturing size + inferred mime + basename", () => {
    const p = makeFile("photo.jpg", 9);
    const r = resolveDraftAttachments([{ path: p }]);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.attachments[0]).toEqual({
      path: p,
      filename: "photo.jpg",
      mime_type: "image/jpeg",
      byte_count: 9,
    });
  });

  test("honors explicit filename + mime_type over inference", () => {
    const p = makeFile("raw.bin");
    const r = resolveDraftAttachments([{ path: p, filename: "report.pdf", mime_type: "application/pdf" }]);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.attachments[0]!.filename).toBe("report.pdf");
    expect(r.attachments[0]!.mime_type).toBe("application/pdf");
  });

  test("rejects a missing file", () => {
    const r = resolveDraftAttachments([{ path: join(dir, "ghost.png") }]);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.error).toContain("not found");
  });

  test("rejects an empty path", () => {
    const r = resolveDraftAttachments([{ path: "   " }]);
    expect(r.ok).toBe(false);
  });

  test("rejects more than the max count", () => {
    const inputs = Array.from({ length: MAX_DRAFT_ATTACHMENTS + 1 }, (_, i) => ({ path: makeFile(`f${i}.txt`) }));
    const r = resolveDraftAttachments(inputs);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.error).toContain("too many");
  });
});

describe("inferMimeFromPath", () => {
  test("maps common photo/video/doc extensions", () => {
    expect(inferMimeFromPath("/x/a.HEIC")).toBe("image/heic");
    expect(inferMimeFromPath("/x/a.mov")).toBe("video/quicktime");
    expect(inferMimeFromPath("/x/a.pdf")).toBe("application/pdf");
    expect(inferMimeFromPath("/x/a.unknownext")).toBeNull();
  });
});
