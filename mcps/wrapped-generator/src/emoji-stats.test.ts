import { test, expect } from "bun:test";
import { isEmojiChar, extractEmoji, endPeriod, emojiStats } from "./emoji-stats.ts";
import type { MessageBody } from "./chatdb-export.ts";

test("isEmojiChar / extractEmoji", () => {
  expect(isEmojiChar("😂")).toBe(true);
  expect(isEmojiChar("🔥")).toBe(true);
  expect(isEmojiChar("a")).toBe(false);
  expect(isEmojiChar("1")).toBe(false);
  expect(extractEmoji("ok 👍 cool 😂")).toEqual(["👍", "😂"]);
  expect(extractEmoji("photo ￼ here")).toEqual([]); // FFFC placeholder skipped
});

test("endPeriod: strips trailing emoji/space before the period test", () => {
  expect(endPeriod("done.")).toBe(true);
  expect(endPeriod("done. 👍")).toBe(true); // trailing emoji stripped, then '.'
  expect(endPeriod("wait...")).toBe(false); // ".." excluded
  expect(endPeriod("no period")).toBe(false);
});

test("emojiStats: inline vs reaction split + tapback mapping", () => {
  const msgs: MessageBody[] = [
    { text: "lol that's funny 😂", from_me: true, kind: "text", assoc: null, ts_ms: 1000 },
    { text: "ok 👍", from_me: true, kind: "text", assoc: null, ts_ms: 1000 },
    { text: "tbh tbh tbh", from_me: true, kind: "text", assoc: null, ts_ms: 86400000 + 1000 }, // 3 'tbh'
    { text: null, from_me: true, kind: "reaction", assoc: 2001 }, // 👍 tapback
    { text: "Reacted 🔥 to a message", from_me: true, kind: "reaction", assoc: 2006 }, // custom
    { text: "incoming", from_me: false, kind: "text", assoc: null }, // filtered by outboundOnly
  ];
  const out = emojiStats(msgs, { outboundOnly: true });
  expect(out.style.sample_size).toBe(3); // 3 inline outbound texts
  expect(out.style.active_days).toBe(2);
  // inline emoji: 😂 and 👍 (one each)
  expect(out.emoji.top_inline.map((e) => e.emoji).sort()).toEqual(["👍", "😂"].sort());
  // reactions: 👍 (tapback 2001) + 🔥 (custom 2006)
  expect(out.emoji.top_reactions.map((e) => e.emoji).sort()).toEqual(["👍", "🔥"].sort());
  // slang breakdown counts the 3 tbh
  expect(out.style.aging_slang_breakdown["tbh"]).toBe(3);
  // dominant laugh = lol (one "lol")
  expect(out.style.dominant_laugh).toBe("lol");
});

test("emojiStats: a body equal to a multi-word slang token does NOT trip the privacy guard", () => {
  // Regression: "no cap" / "fr fr" are output KEYS in genz_slang_breakdown. A
  // user who literally texts "no cap" used to trip the privacy guard (the body
  // coincides with the aggregate label) → PrivacyGuardError → hard crash. The
  // guard now excludes known token labels; the output still holds only a count.
  const msgs: MessageBody[] = [
    { text: "no cap", from_me: true, kind: "text", assoc: null },
    { text: "fr fr", from_me: true, kind: "text", assoc: null },
    { text: "ok sounds good", from_me: true, kind: "text", assoc: null },
  ];
  let out: ReturnType<typeof emojiStats> | undefined;
  expect(() => { out = emojiStats(msgs, { outboundOnly: true }); }).not.toThrow();
  expect(out!.style.genz_slang_breakdown["no cap"]).toBe(1);
  expect(out!.style.genz_slang_breakdown["fr fr"]).toBe(1);
});
