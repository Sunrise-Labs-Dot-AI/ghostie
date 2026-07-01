import { describe, expect, test } from "bun:test";

import { makeFrameReader, MAX_FRAME_BYTES } from "./server.ts";

describe("makeFrameReader", () => {
  test("emits complete newline-delimited frames", () => {
    const lines: string[] = [];
    const reader = makeFrameReader((line) => lines.push(line), () => {});

    reader.push('{"a":1}\n{"b":2}\n');

    expect(lines).toEqual(['{"a":1}', '{"b":2}']);
  });

  test("reassembles a frame split across chunks", () => {
    const lines: string[] = [];
    const reader = makeFrameReader((line) => lines.push(line), () => {});
    const full = Buffer.from('{"x":"you"}\n', "utf8");
    const at = 5;

    reader.push(full.subarray(0, at));
    reader.push(full.subarray(at));

    expect(lines).toEqual(['{"x":"you"}']);
  });

  test("rejects oversized frames by byte length before appending", () => {
    let overflowed = false;
    const reader = makeFrameReader(() => {}, () => { overflowed = true; });

    reader.push(Buffer.alloc(MAX_FRAME_BYTES + 1, 0x78));

    expect(overflowed).toBe(true);
  });
});
