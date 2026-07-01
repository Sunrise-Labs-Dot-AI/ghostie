// Phase A2 — emoji + writing-style aggregates. Port of emoji_stats.py.
//
// PRIVACY: reads message text in memory and emits ONLY aggregates — counts,
// percentages, single emoji glyphs, short slang/laugh tokens. Never emits a
// message body; a guard rejects the output if a multi-word body leaks. This is
// the one content-reading path in the generator (the rest is metadata-only).

import { pyRound } from "./analyze.ts";
import type { MessageBody } from "./chatdb-export.ts";

const LAUGH_PATTERNS: [string, RegExp][] = [
  ["haha", /\b(?:ha){2,}h?\b/g],
  ["hehe", /\b(?:he){2,}\b/g],
  ["lol", /\blol\b/g],
  ["lmao", /\blmao+\b/g],
  ["lmfao", /\blmfao+\b/g],
  ["rofl", /\brofl\b/g],
];
const LAUGH_EMOJI: Record<string, string> = { "😂": "joy", "🤣": "rofl", "💀": "skull", "😭": "sob" };

// Canonical emoji for legacy iMessage tapback types (2006 = custom emoji,
// parsed from the body; 2007 = sticker, skipped).
const TAPBACK_EMOJI: Record<number, string> = { 2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂", 2004: "‼️", 2005: "❓" };

// ── Generation-cohort slang dictionary ──────────────────────────────────────
// Deterministic slang-marker counts, one list per generational cohort, feeding
// the inferred-age estimate as a weighted signal (age-estimate.ts +
// data/age_rubric.json). PARITY: mirrors SLANG_COHORTS in
// skills/texting-analytics/scripts/emoji_stats.py — keep both identical.
//
// Token selection rules (keep the signal honest):
//   1. DISTINCTIVE — hard to produce by accident in generic English ("mid",
//      "ate", "lit", "salty", "extra", "as if" were all dropped for exactly
//      that failure mode).
//   2. COHORT-CODED — placed in the cohort that coined / peak-used the term:
//      gen_z ≈ "rizz / no cap / fr fr / bet"; millennial ≈ "tbh / omg /
//      adulting"; gen_x ≈ "da bomb / talk to the hand"; boomer_plus ≈
//      "groovy / far out".
//   3. AMBIGUOUS TOKENS GET STRICTER REGEXES — "bet" only counts as a
//      STANDALONE message (^bet[.!?]*$), because \bbet\b would match
//      "I bet you $5". "far out" relies on the frequency threshold in
//      age-estimate.ts (SLANG_TOKEN_MIN) to suppress stray literal uses.
const SLANG_COHORTS: Record<string, [string, RegExp][]> = {
  gen_z: [
    ["rizz", /\brizz\b/g], ["skibidi", /\bskibidi\b/g], ["no cap", /\bno cap\b/g], ["fr fr", /\bfr fr\b/g],
    ["bussin", /\bbussin\b/g], ["gyat", /\bgyatt?\b/g], ["delulu", /\bdelulu\b/g], ["slay", /\bslay\b/g],
    ["ong", /\bong\b/g], ["bet", /^bet[.!?]*$/g],
  ],
  millennial: [
    ["tbh", /\btbh\b/g], ["ngl", /\bngl\b/g], ["lowkey", /\blowkey\b/g],
    ["highkey", /\bhighkey\b/g], ["sus", /\bsus\b/g], ["yeet", /\byeet\b/g],
    ["omg", /\bomg\b/g], ["totes", /\btotes\b/g], ["adulting", /\badulting\b/g],
  ],
  gen_x: [
    ["hella", /\bhella\b/g], ["da bomb", /\bda bomb\b/g], ["talk to the hand", /\btalk to the hand\b/g],
    ["phat", /\bphat\b/g], ["bogus", /\bbogus\b/g], ["wazzup", /\bwaz+up\b/g],
  ],
  boomer_plus: [
    ["groovy", /\bgroovy\b/g], ["far out", /\bfar out\b/g], ["golly", /\bgolly\b/g],
    ["gee whiz", /\bgee whiz\b/g], ["good grief", /\bgood grief\b/g], ["heavens", /\bheavens\b/g],
  ],
};
// Legacy field-name note: in the output below, gen_z ↔ "genz_slang_*" and
// millennial ↔ "aging_slang_*" (names kept stable for older consumers).

// Emoji detection — mirrors the Python is_emoji_char: code point ≥ 0x2000 AND
// (Unicode General_Category Other_Symbol, OR in the 0x1F000–0x1FFFF /
// 0x2600–0x27BF blocks). `\p{So}` is JS's category check (uses the engine's
// Unicode tables; parity-checked against Python's unicodedata).
const SO_RE = /\p{So}/u;
const LU_RE = /\p{Lu}/u;

export function isEmojiChar(c: string): boolean {
  if (!c) return false;
  const cp = c.codePointAt(0)!;
  if (cp < 0x2000) return false;
  if (SO_RE.test(c)) return true;
  if (cp >= 0x1f000 && cp <= 0x1ffff) return true;
  if (cp >= 0x2600 && cp <= 0x27bf) return true;
  return false;
}

// Iterate code points (for…of), skip U+FFFC (attachment placeholder).
export function extractEmoji(text: string): string[] {
  const out: string[] = [];
  for (const c of text) if (isEmojiChar(c) && c !== "￼") out.push(c);
  return out;
}

export function endPeriod(text: string): boolean {
  // rstrip, then strip trailing emoji + whitespace, then test for a single
  // trailing period (not "..").
  let chars = [...text.replace(/\s+$/u, "")];
  while (chars.length) {
    const lastCh = chars[chars.length - 1]!;
    if (isEmojiChar(lastCh) || /\s/u.test(lastCh)) {
      chars.pop();
      // also rstrip whitespace after popping (Python does s[:-1].rstrip())
      while (chars.length && /\s/u.test(chars[chars.length - 1]!)) chars.pop();
    } else break;
  }
  const s = chars.join("");
  return s.length > 0 && s.endsWith(".") && !s.endsWith("..");
}

function mostCommon(counter: Map<string, number>, n?: number): [string, number][] {
  // Stable sort by count desc; ties keep insertion order (Python Counter).
  const entries = [...counter.entries()].sort((a, b) => b[1] - a[1]);
  return n == null ? entries : entries.slice(0, n);
}

function inc(m: Map<string, number>, k: string, by = 1) {
  m.set(k, (m.get(k) ?? 0) + by);
}

export interface EmojiStats {
  emoji: {
    pct_messages_with_emoji: number;
    emoji_per_message: number;
    top_inline: { emoji: string; count: number }[];
    top_reactions: { emoji: string; count: number }[];
    top: { emoji: string; count: number }[];
  };
  style: {
    pct_end_period: number;
    pct_all_lowercase: number;
    laugh_tokens: Record<string, number>;
    dominant_laugh: string | null;
    genz_slang_hits: number;
    aging_slang_hits: number;
    genz_slang_breakdown: Record<string, number>;
    aging_slang_breakdown: Record<string, number>;
    genx_slang_hits: number;
    boomer_slang_hits: number;
    genx_slang_breakdown: Record<string, number>;
    boomer_slang_breakdown: Record<string, number>;
    pct_ellipsis: number;
    pct_repeated_exclaim: number;
    pct_emoji_ending: number;
    sample_size: number;
    active_days: number | null;
  };
}

export class NoUsableMessagesError extends Error {}
export class PrivacyGuardError extends Error {}

// Multi-word strings that legitimately appear in the output as aggregate KEYS,
// not as leaked bodies: the slang/laugh token LABELS (e.g. "no cap", "fr fr").
// The privacy guard below flags any inline body that appears verbatim in the
// serialized output — but a user who literally texts "no cap" would otherwise
// trip it on the token label, not on a real body leak (the output still holds
// only a COUNT for that token, never the message). Exclude these known labels
// so that false positive can't hard-crash the whole generation.
const OUTPUT_TOKEN_LABELS: ReadonlySet<string> = new Set<string>([
  ...Object.values(SLANG_COHORTS).flatMap((toks) => toks.map(([tok]) => tok)),
  ...LAUGH_PATTERNS.map(([name]) => name),
]);

export function emojiStats(messages: MessageBody[], opts: { outboundOnly?: boolean } = {}): EmojiStats {
  const inlineTexts: string[] = [];
  const activeDays = new Set<number>();
  const reactionEmoji = new Map<string, number>();

  for (const m of messages) {
    if (opts.outboundOnly && !m.from_me) continue;
    if (m.kind === "reaction") {
      const assoc = m.assoc;
      if (assoc != null && TAPBACK_EMOJI[assoc]) {
        inc(reactionEmoji, TAPBACK_EMOJI[assoc]!);
      } else {
        const body = (m.text ?? "").trim();
        const emo = extractEmoji(body);
        if (emo.length) inc(reactionEmoji, emo[0]!); // first emoji = the reaction
      }
      continue;
    }
    if (m.kind && m.kind !== "text" && m.kind !== "media") continue;
    const t = (m.text ?? "").trim();
    if (t) {
      inlineTexts.push(t);
      if (m.ts_ms != null) activeDays.add(Math.floor(m.ts_ms / 86400000));
    }
  }

  const n = inlineTexts.length;
  if (n === 0) throw new NoUsableMessagesError("no usable messages");

  let withEmoji = 0;
  let totalEmoji = 0;
  const glyphs = new Map<string, number>();
  let period = 0;
  let allLower = 0;
  const laughs = new Map<string, number>();
  const cohortTok: Record<string, Map<string, number>> = Object.fromEntries(
    Object.keys(SLANG_COHORTS).map((c) => [c, new Map<string, number>()]),
  );
  let ellipsisMsgs = 0;
  let rexclMsgs = 0;
  let emojiEndMsgs = 0;

  for (const t of inlineTexts) {
    const emo = extractEmoji(t);
    if (emo.length) {
      withEmoji += 1;
      totalEmoji += emo.length;
      for (const g of emo) inc(glyphs, g);
    }
    if (endPeriod(t)) period += 1;
    let hasUpper = false;
    for (const c of t) if (LU_RE.test(c)) { hasUpper = true; break; }
    if (!hasUpper) allLower += 1;

    const lower = t.toLowerCase();
    for (const [name, re] of LAUGH_PATTERNS) {
      const c = (lower.match(re) ?? []).length;
      if (c) inc(laughs, name, c);
    }
    for (const c of t) {
      const mapped = LAUGH_EMOJI[c];
      if (mapped) inc(laughs, mapped);
    }
    for (const [cohort, toks] of Object.entries(SLANG_COHORTS)) {
      const counter = cohortTok[cohort]!;
      for (const [tok, re] of toks) {
        const hits = (lower.match(re) ?? []).length;
        if (hits) inc(counter, tok, hits);
      }
    }
    if (t.includes("...") || t.includes("…")) ellipsisMsgs += 1;
    if (/[!?]{2,}/.test(t)) rexclMsgs += 1;
    const stripped = t.replace(/\s+$/u, "");
    const lastCh = [...stripped].pop();
    if (stripped && lastCh && isEmojiChar(lastCh)) emojiEndMsgs += 1;
  }

  const pct = (x: number) => pyRound((100 * x) / n, 1);
  const sumVals = (m: Map<string, number>) => [...m.values()].reduce((a, b) => a + b, 0);
  const obj = (entries: [string, number][]) => Object.fromEntries(entries);

  const out: EmojiStats = {
    emoji: {
      pct_messages_with_emoji: pct(withEmoji),
      emoji_per_message: pyRound(totalEmoji / n, 2),
      top_inline: mostCommon(glyphs, 8).map(([emoji, count]) => ({ emoji, count })),
      top_reactions: mostCommon(reactionEmoji, 8).map(([emoji, count]) => ({ emoji, count })),
      top: mostCommon(glyphs, 8).map(([emoji, count]) => ({ emoji, count })),
    },
    style: {
      pct_end_period: pct(period),
      pct_all_lowercase: pct(allLower),
      laugh_tokens: obj(mostCommon(laughs, 8)),
      dominant_laugh: laughs.size ? mostCommon(laughs, 1)[0]![0] : null,
      genz_slang_hits: sumVals(cohortTok.gen_z!),
      aging_slang_hits: sumVals(cohortTok.millennial!),
      genz_slang_breakdown: obj([...cohortTok.gen_z!.entries()]),
      aging_slang_breakdown: obj([...cohortTok.millennial!.entries()]),
      genx_slang_hits: sumVals(cohortTok.gen_x!),
      boomer_slang_hits: sumVals(cohortTok.boomer_plus!),
      genx_slang_breakdown: obj([...cohortTok.gen_x!.entries()]),
      boomer_slang_breakdown: obj([...cohortTok.boomer_plus!.entries()]),
      pct_ellipsis: pct(ellipsisMsgs),
      pct_repeated_exclaim: pct(rexclMsgs),
      pct_emoji_ending: pct(emojiEndMsgs),
      sample_size: n,
      active_days: activeDays.size ? activeDays.size : null,
    },
  };

  // Privacy guard: no multi-word inline body may appear in the output — EXCEPT a
  // body that exactly equals a known token label (e.g. "no cap"), which is an
  // aggregate key, not a leak (see OUTPUT_TOKEN_LABELS).
  const blob = JSON.stringify(out);
  for (const t of inlineTexts) {
    if (t.includes(" ") && !OUTPUT_TOKEN_LABELS.has(t.toLowerCase()) && blob.includes(t)) {
      throw new PrivacyGuardError(`privacy guard tripped: a ${t.length}-char body in output`);
    }
  }
  return out;
}
