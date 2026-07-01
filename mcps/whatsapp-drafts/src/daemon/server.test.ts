import { describe, expect, test } from "bun:test";

import { makeFrameReader, MAX_FRAME_BYTES, checkHistoryBounds } from "./server.ts";

describe("makeFrameReader frame-size cap (#84)", () => {
  test("emits complete newline-delimited frames", () => {
    const lines: string[] = [];
    const reader = makeFrameReader((l) => lines.push(l), () => {});
    reader.push('{"a":1}\n{"b":2}\n');
    expect(lines).toEqual(['{"a":1}', '{"b":2}']);
  });

  test("reassembles a frame split across chunks", () => {
    const lines: string[] = [];
    const reader = makeFrameReader((l) => lines.push(l), () => {});
    reader.push('{"hel');
    reader.push('lo":true}\n');
    expect(lines).toEqual(['{"hello":true}']);
  });

  test("skips blank lines", () => {
    const lines: string[] = [];
    const reader = makeFrameReader((l) => lines.push(l), () => {});
    reader.push("\n  \n{\"x\":1}\n");
    expect(lines).toEqual(['{"x":1}']);
  });

  test("rejects an oversized no-newline frame instead of buffering unbounded", () => {
    const lines: string[] = [];
    let overflowed = false;
    const reader = makeFrameReader((l) => lines.push(l), () => { overflowed = true; });
    // Stream past the cap with no newline.
    reader.push("x".repeat(MAX_FRAME_BYTES + 1));
    expect(overflowed).toBe(true);
    expect(lines).toHaveLength(0);
  });

  test("overflow triggers even when bytes arrive in many small chunks", () => {
    let overflowed = false;
    const reader = makeFrameReader(() => {}, () => { overflowed = true; });
    const chunk = "y".repeat(100_000); // no newline
    for (let i = 0; i < 11 && !overflowed; i++) reader.push(chunk);
    expect(overflowed).toBe(true);
  });

  test("ignores further input after overflow (socket already destroyed)", () => {
    const lines: string[] = [];
    let overflowCount = 0;
    const reader = makeFrameReader((l) => lines.push(l), () => { overflowCount += 1; });
    reader.push("z".repeat(MAX_FRAME_BYTES + 1));
    reader.push('{"valid":1}\n'); // would otherwise be processed
    expect(overflowCount).toBe(1);
    expect(lines).toHaveLength(0);
  });

  test("a frame exactly at the cap with a trailing newline is still processed", () => {
    const lines: string[] = [];
    let overflowed = false;
    const reader = makeFrameReader((l) => lines.push(l), () => { overflowed = true; });
    // length === MAX_FRAME_BYTES is allowed (cap is strict >), and the
    // newline lets it flush before any subsequent byte trips the cap.
    const payload = "a".repeat(MAX_FRAME_BYTES - 1) + "\n";
    reader.push(payload);
    expect(overflowed).toBe(false);
    expect(lines).toHaveLength(1);
    expect(lines[0]!.length).toBe(MAX_FRAME_BYTES - 1);
  });

  // #84: the cap is on RAW BYTES checked BEFORE decode/append. A single
  // oversized chunk must overflow without being allocated into the buffer.
  test("rejects a single oversized chunk on BYTE length before appending", () => {
    let overflowed = false;
    const reader = makeFrameReader(() => {}, () => { overflowed = true; });
    reader.push(Buffer.alloc(MAX_FRAME_BYTES + 1, 0x78)); // 'x', no newline
    expect(overflowed).toBe(true);
  });

  // A multibyte chunk whose BYTE length exceeds the cap (even if its character
  // count would be smaller) must be rejected on bytes, not on string length.
  test("rejects a multibyte chunk on byte length, not decoded char count", () => {
    let overflowed = false;
    const reader = makeFrameReader(() => {}, () => { overflowed = true; });
    // "你" is 3 bytes in UTF-8. (cap/3 + 1) chars → > MAX_FRAME_BYTES BYTES but
    // only ~cap/3 CHARACTERS, so a char-length check would have under-counted.
    const chars = Math.ceil(MAX_FRAME_BYTES / 3) + 1;
    const multibyte = Buffer.from("你".repeat(chars), "utf8");
    expect(multibyte.byteLength).toBeGreaterThan(MAX_FRAME_BYTES);
    reader.push(multibyte);
    expect(overflowed).toBe(true);
  });

  // A multibyte codepoint split across two chunks still decodes correctly once
  // the full frame arrives (we only decode COMPLETE frames).
  test("reassembles a multibyte codepoint split across chunk boundaries", () => {
    const lines: string[] = [];
    const reader = makeFrameReader((l) => lines.push(l), () => {});
    const full = Buffer.from('{"x":"你"}\n', "utf8");
    // Split mid-"你" (its 3 bytes straddle the boundary).
    const at = full.indexOf(0xe4) + 1; // first byte of 你 is 0xE4; cut after it
    reader.push(full.subarray(0, at));
    reader.push(full.subarray(at));
    expect(lines).toEqual(['{"x":"你"}']);
  });
});

// Defense-in-depth: the daemon must enforce the same since/contact_filter
// history bounds the MCP schema enforces, so a raw daemon RPC (one that
// bypasses the MCP and wins peer-auth) can't dump unbounded history (issue #78).
describe("daemon-enforced read bounds — checkHistoryBounds (issue #78)", () => {
  test("neither since nor contact_filter → error", () => {
    const e = checkHistoryBounds(undefined, undefined);
    expect(e).not.toBeNull();
    expect(e).toContain("either");
  });

  test("a valid numeric since within 2 years passes", () => {
    expect(checkHistoryBounds(Date.now() - 1000, undefined)).toBeNull();
  });

  test("a since older than 2 years → error", () => {
    const tenYearsAgo = Date.now() - 10 * 365 * 24 * 60 * 60 * 1000;
    const e = checkHistoryBounds(tenYearsAgo, undefined);
    expect(e).not.toBeNull();
    expect(e).toContain("2 years");
  });

  test("a non-numeric since with no filter → error (treated as absent)", () => {
    const e = checkHistoryBounds("not-a-number", undefined);
    expect(e).not.toBeNull();
    expect(e).toContain("either");
  });

  test("a >=2-char contact_filter passes", () => {
    expect(checkHistoryBounds(undefined, "Al")).toBeNull();
  });

  test("a 1-char contact_filter → error (>=2 chars)", () => {
    const e = checkHistoryBounds(undefined, "a");
    expect(e).not.toBeNull();
    expect(e).toContain("at least 2");
  });

  test("an empty-string contact_filter with no since → error (>=2 chars), not an unbounded dump", () => {
    const e = checkHistoryBounds(undefined, "");
    expect(e).not.toBeNull();
    expect(e).toContain("at least 2");
  });
});
