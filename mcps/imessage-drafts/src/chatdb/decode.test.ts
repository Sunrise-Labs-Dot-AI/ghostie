import { describe, test, expect } from "bun:test";
import { decodeAttributedBody, bestMessageBody, truncateBody } from "./decode.ts";

// Build a minimal typedstream blob that contains an NSString payload. The
// decoder scans for the "NSString" class marker, then a 0x01 0x2B byte pair
// (typedstream's NSString instance signature), then a length-prefixed UTF-8
// string. Real attributedBody payloads have much more class metadata before
// and after the string, but the decoder is intentionally tolerant of
// trailing bytes and skips ahead to the marker.
function buildShortNSString(text: string): Buffer {
  const utf8 = Buffer.from(text, "utf8");
  if (utf8.length >= 0x80) throw new Error("test helper only supports short strings");
  return Buffer.concat([
    Buffer.from("streamtyped\x00", "binary"), // header preamble (decoder skips past)
    Buffer.from("NSString", "utf8"),
    Buffer.from([0x86, 0x84, 0x40, 0x40]),   // class metadata bytes (filler — decoder scans through)
    Buffer.from([0x01, 0x2b]),                // NSString instance marker
    Buffer.from([utf8.length]),               // short-form length
    utf8,
  ]);
}

// 0x81 marks a uint16 LITTLE-endian length (the real typedstream encoding) for
// any body 0x80..0xFFFF bytes. The earlier helper wrongly used a single byte
// after 0x81, which matched the buggy decoder rather than real data.
function buildLongNSString(text: string): Buffer {
  const utf8 = Buffer.from(text, "utf8");
  if (utf8.length < 0x80 || utf8.length > 0xffff) throw new Error("test helper expects 128..65535 bytes");
  const lenBuf = Buffer.alloc(2);
  lenBuf.writeUInt16LE(utf8.length, 0);
  return Buffer.concat([
    Buffer.from("NSString", "utf8"),
    Buffer.from([0x01, 0x2b, 0x81]),
    lenBuf,
    utf8,
  ]);
}

describe("decodeAttributedBody", () => {
  test("returns null for null/empty input", () => {
    expect(decodeAttributedBody(null)).toBeNull();
    expect(decodeAttributedBody(Buffer.alloc(0))).toBeNull();
  });

  test("returns null when no NSString marker present", () => {
    expect(decodeAttributedBody(Buffer.from("nothing to see here"))).toBeNull();
  });

  test("decodes short-form length (single byte < 0x80)", () => {
    const blob = buildShortNSString("hello world");
    expect(decodeAttributedBody(blob)).toBe("hello world");
  });

  test("decodes 0x81 uint16-LE length (128-255 bytes)", () => {
    const text = "x".repeat(200);
    expect(decodeAttributedBody(buildLongNSString(text))).toBe(text);
  });

  test("decodes a >=256-byte body fully, with no leading control-char artifact", () => {
    // Regression: a 500-char body's real length is `0x81 F4 01` (uint16 LE).
    // The old decoder read len=0xF4=244 and started the string at the 0x01
    // byte → "\x01" + first 243 chars (leading control char + truncated).
    const text = "A" + "b".repeat(498) + "Z"; // 500 chars, distinctive ends
    const decoded = decodeAttributedBody(buildLongNSString(text));
    expect(decoded).toBe(text);
    expect(decoded!.length).toBe(500);
    expect(decoded!.charCodeAt(0)).toBeGreaterThanOrEqual(0x20); // not a control char
  });

  test("decodes 0x82 uint32-LE length (>= 64 KB body)", () => {
    const text = "y".repeat(70_000);
    const utf8 = Buffer.from(text, "utf8");
    const lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32LE(utf8.length, 0);
    const blob = Buffer.concat([
      Buffer.from("NSString", "utf8"),
      Buffer.from([0x01, 0x2b, 0x82]),
      lenBuf,
      utf8,
    ]);
    expect(decodeAttributedBody(blob)).toBe(text);
  });

  test("strips a leading control-char artifact if one slips through", () => {
    expect(decodeAttributedBody(buildShortNSString("hello"))).toBe("hello");
  });

  test("decodes UTF-8 multi-byte sequences correctly", () => {
    const blob = buildShortNSString("café 🍕");
    expect(decodeAttributedBody(blob)).toBe("café 🍕");
  });

  test("returns null when length field overruns the buffer", () => {
    // Truncate after the length byte — no payload follows.
    const truncated = Buffer.concat([Buffer.from("NSString", "utf8"), Buffer.from([0x01, 0x2b, 0x10])]);
    expect(decodeAttributedBody(truncated)).toBeNull();
  });
});

describe("bestMessageBody", () => {
  test("prefers text column when present", () => {
    const blob = buildShortNSString("from blob");
    expect(bestMessageBody("from text", blob)).toBe("from text");
  });

  test("falls back to attributedBody when text is null", () => {
    const blob = buildShortNSString("from blob");
    expect(bestMessageBody(null, blob)).toBe("from blob");
  });

  test("falls back to attributedBody when text is empty string", () => {
    const blob = buildShortNSString("from blob");
    expect(bestMessageBody("", blob)).toBe("from blob");
  });

  test("returns null when both are unavailable", () => {
    expect(bestMessageBody(null, null)).toBeNull();
    expect(bestMessageBody("", null)).toBeNull();
  });
});

describe("truncateBody", () => {
  test("passes through bodies under 8 KB", () => {
    expect(truncateBody("short")).toBe("short");
    expect(truncateBody(null)).toBeNull();
  });

  test("truncates long bodies and appends marker with omitted count", () => {
    const long = "x".repeat(20_000);
    const truncated = truncateBody(long);
    expect(truncated).not.toBeNull();
    expect(Buffer.byteLength(truncated!, "utf8")).toBeLessThanOrEqual(8 * 1024);
    expect(truncated!).toMatch(/\.\.\. \[truncated, \d+ chars omitted\]$/);
  });
});
