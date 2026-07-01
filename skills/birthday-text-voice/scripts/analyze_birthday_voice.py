#!/usr/bin/env python3
"""analyze_birthday_voice.py — segmented birthday-wish voice fingerprint.

Reads a JSON file of the user's OUTBOUND birthday wishes (the caller pulls them
from 1:1 AND group threads via the iMessage MCP, matches them with a happy-birthday
pattern, drops tapbacks, and tags each with the recipient's relationship tier) and
emits an aggregate, SEGMENTED voice fingerprint: how the user writes birthday wishes
overall, and per relationship tier (family / friend / partner / colleague) where the
sample is large enough.

Pure stdlib. INVARIANT: the output never contains a message body. Aggregates only.

Why a separate analyzer from texting-voice-skill-creator's analyze_voice.py:
  - birthday wishes are SPARSE (~1 per contact per year), so the corpus is pooled
    across people and segmented by tier, not per-contact;
  - they span 1:1 AND group threads (general texting voice is 1:1 only);
  - the min-sample floor is lower, and segments below threshold gracefully fall
    back to the overall voice (the renderer/skill handles the fallback);
  - it adds birthday-specific warmth signals (birthday-emoji rate, "!!" intensity).
The shared aggregation helpers are intentionally VENDORED (copied) rather than
imported — skills are symlinked into .claude/skills/ individually, so each must be
self-contained.

Input JSON (array at top level):
    [
      { "ts": "2025-03-14T09:02:11", "text": "happy birthday!! 🎂",
        "thread_id": 42, "is_group": false, "tier": "family", "gender": "f" },
      ...
    ]
  - tier: "family" | "friend" | "partner" | "colleague" | null  (null = a group
    wish we couldn't attribute to a known recipient — it feeds `overall` only).
  - gender: optional free string; a `genders` segmentation is emitted only if any
    message carries one AND the segment clears the min.
  - is_group: informational; all messages feed the analysis.
  - thread_id: the iMessage chat/thread ROW id (not a contact handle) — bursts
    group consecutive same-thread messages, so a contact id here would over-group.

Usage:
    python3 analyze_birthday_voice.py --input wishes.json [--burst-minutes 2]

Exit codes:
    0 — success (may include warnings for thin segments)
    2 — input malformed
    3 — overall sample too small (< OVERALL_MIN substantive wishes)
    5 — privacy guard tripped (a full message body leaked into the output)
"""

import argparse
import json
import re
import statistics
import sys
import unicodedata
from collections import Counter, defaultdict
from datetime import datetime, timezone

# Common texting abbreviations — case-insensitive whole-word match.
ABBREVIATIONS = [
    "lol", "lmao", "lmfao", "omg", "omw", "ty", "tysm", "btw", "idk",
    "imo", "tbh", "fyi", "np", "rn", "ngl", "ily", "wyd", "smh", "hbd",
]

# Openers/closers are emitted VERBATIM into a committed file, so they're restricted
# to this allowlist of generic greeting / acknowledgment / warmth / sign-off words.
# A message's actual first/last word surfaces only if it's in here — otherwise it's
# dropped. Keeps proper nouns (names, places) out of the fingerprint. Birthday-
# relevant warmth tokens are included (happy, love, miss, congrats, xo, proud...).
SAFE_TOKENS = frozenset({
    "hey", "hi", "hello", "yo", "hiya", "heya", "morning", "gm", "gn", "night",
    "goodnight", "evening", "afternoon",
    "ok", "okay", "k", "kk", "yeah", "yea", "yep", "yup", "yes", "sure", "cool",
    "nice", "perfect", "awesome", "great", "sounds", "word", "bet", "deal", "done",
    "gotcha", "right", "true", "fair", "facts",
    "no", "nope", "nah",
    "lol", "lmao", "lmfao", "haha", "hahaha", "hah", "omg", "oh", "ah", "ahh",
    "hmm", "huh", "ugh", "aww", "aw", "wow", "yay", "ooh", "eh", "well", "so",
    "anyway", "wait", "damn",
    "thanks", "thank", "thx", "ty", "tysm", "please", "pls", "sorry", "welcome",
    "np", "cheers", "bye", "later", "ttyl", "soon", "careful", "safe",
    "love", "miss", "xo", "xoxo", "hugs", "mwah",
    "happy", "congrats", "congratulations", "good", "glad", "excited", "proud",
    "hope", "wishing", "best", "cheers", "celebrate",
})

# Birthday-wish warmth signals. Literals (not an iterated string) so multi-codepoint
# emoji like "❤️" (heart + U+FE0F) stay intact; matched by substring, not per-char.
BIRTHDAY_EMOJI = ("🎂", "🎉", "🎁", "🥳", "🎈", "🎊", "🍾", "🥂", "❤️", "💕", "🎀")

DEFAULT_BURST_MINUTES = 2

# Lower than analyze_voice's 30: birthday wishes are sparse. Overall must clear
# OVERALL_MIN to produce anything; a tier/gender segment must clear SEGMENT_MIN to
# be emitted on its own (otherwise it falls back to `overall`).
OVERALL_MIN = 12
SEGMENT_MIN = 8
LOW_SAMPLE = 40

# Allowed relationship tiers (matches birthdays.json's relationship field). Other
# values are normalized but kept as-is; unknown/blank tiers become untiered.
KNOWN_TIERS = frozenset({"family", "friend", "partner", "colleague"})


def is_emoji_char(c):
    if not c:
        return False
    cp = ord(c)
    if cp < 0x2000:
        return False
    # Exclude letterlike + enclosed-alphanumeric symbols. These are category "So"
    # (or in the supplementary range) but are READABLE LETTERS — e.g. circled
    # letters Ⓙⓞⓗⓝ — so they could spell a name verbatim into the committed emoji
    # list. Privacy first: drop them rather than treat them as emoji.
    if 0x2100 <= cp <= 0x214F:   # Letterlike Symbols (™ ℠ ℡ ℅ …)
        return False
    if 0x2460 <= cp <= 0x24FF:   # Enclosed Alphanumerics (① Ⓐ ⓐ …)
        return False
    if 0x1F100 <= cp <= 0x1F1FF: # Enclosed Alphanumeric Supplement + regional indicators
        return False
    cat = unicodedata.category(c)
    if cat == "So":
        return True
    if 0x1F000 <= cp <= 0x1FFFF:
        return True
    if 0x2600 <= cp <= 0x27BF:
        return True
    return False


def extract_emoji(text):
    return [c for c in text if is_emoji_char(c)]


def is_strippable_tail(c):
    """A trailing char that decorates a message end without being its terminal
    punctuation: an emoji, a variation selector / combining mark / modifier (Mn,
    Cf, Sk — e.g. U+FE0F after ❤). Stripping these finds the real terminal `!`/`.`
    under a trailing "❤️"/"🎉" so punctuation stats aren't skewed."""
    return is_emoji_char(c) or unicodedata.category(c) in ("Mn", "Cf", "Sk")


def first_word(text):
    m = re.match(r"\s*([A-Za-z']+)", text)
    return m.group(1).lower() if m else None


def last_word(text):
    stripped = text.rstrip()
    while stripped and (
        stripped[-1] in ".!?,;:" or is_strippable_tail(stripped[-1]) or stripped[-1].isspace()
    ):
        stripped = stripped[:-1]
    m = re.search(r"([A-Za-z']+)$", stripped)
    return m.group(1).lower() if m else None


def pct(n, d):
    return round(n / d, 4) if d else 0.0


def percentile(values, p):
    if not values:
        return 0
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def compute_length(texts):
    if not texts:
        return {"median_chars": 0, "p25_chars": 0, "p75_chars": 0, "pct_under_20_chars": 0.0}
    lengths = [len(t) for t in texts]
    return {
        "median_chars": int(statistics.median(lengths)),
        "p25_chars": int(percentile(lengths, 25)),
        "p75_chars": int(percentile(lengths, 75)),
        "pct_under_20_chars": pct(sum(1 for l in lengths if l < 20), len(lengths)),
    }


def compute_capitalization(texts):
    if not texts:
        return {"pct_lowercase_start": 0.0, "pct_all_lowercase": 0.0}
    starts_lower = all_lower = 0
    for t in texts:
        first = next((c for c in t if c.isalpha()), None)
        if first and first.islower():
            starts_lower += 1
        if not any(c.isupper() for c in t):
            all_lower += 1
    return {
        "pct_lowercase_start": pct(starts_lower, len(texts)),
        "pct_all_lowercase": pct(all_lower, len(texts)),
    }


def compute_punctuation(texts):
    if not texts:
        return {"pct_ending_with_period": 0.0, "pct_ending_with_nothing": 0.0,
                "pct_ending_with_exclaim": 0.0, "pct_ending_with_question": 0.0}
    period = exclaim = question = nothing = 0
    for t in texts:
        s = t.rstrip()
        while s and is_strippable_tail(s[-1]):
            s = s[:-1].rstrip()
        if not s:
            nothing += 1
            continue
        last = s[-1]
        if last == ".":
            period += 1
        elif last == "!":
            exclaim += 1
        elif last == "?":
            question += 1
        else:
            nothing += 1
    n = len(texts)
    return {
        "pct_ending_with_period": pct(period, n),
        "pct_ending_with_nothing": pct(nothing, n),
        "pct_ending_with_exclaim": pct(exclaim, n),
        "pct_ending_with_question": pct(question, n),
    }


def compute_emoji(texts):
    with_emoji = 0
    all_emoji = Counter()
    for t in texts:
        emo = extract_emoji(t)
        if emo:
            with_emoji += 1
            all_emoji.update(emo)
    return {
        "pct_messages_with_emoji": pct(with_emoji, len(texts)),
        "top_5": [{"emoji": e, "count": c} for e, c in all_emoji.most_common(5)],
    }


def compute_abbreviations(texts):
    counts = Counter()
    for t in texts:
        lower = t.lower()
        for abbr in ABBREVIATIONS:
            matches = re.findall(rf"\b{re.escape(abbr)}\b", lower)
            if matches:
                counts[abbr] += len(matches)
    return dict(counts.most_common(15))


def compute_bursts(messages, burst_minutes):
    if not messages:
        return {"median_messages_per_burst": 0, "p75_messages_per_burst": 0,
                "burst_definition_minutes": burst_minutes}
    msgs = sorted(messages, key=lambda m: m["_ts"])
    burst_sizes = []
    current = 1
    for prev, curr in zip(msgs, msgs[1:]):
        same_thread = prev.get("thread_id") == curr.get("thread_id")
        gap_min = (curr["_ts"] - prev["_ts"]).total_seconds() / 60
        if same_thread and gap_min <= burst_minutes:
            current += 1
        else:
            burst_sizes.append(current)
            current = 1
    burst_sizes.append(current)
    return {
        "median_messages_per_burst": int(statistics.median(burst_sizes)),
        "p75_messages_per_burst": int(percentile(burst_sizes, 75)),
        "burst_definition_minutes": burst_minutes,
    }


def compute_openers(texts):
    counter = Counter(w for w in (first_word(t) for t in texts) if w in SAFE_TOKENS)
    return {"top_3": [{"phrase": p, "count": c} for p, c in counter.most_common(3)]}


def compute_closers(texts):
    counter = Counter(w for w in (last_word(t) for t in texts) if w in SAFE_TOKENS)
    return {"top_3": [{"phrase": p, "count": c} for p, c in counter.most_common(3)]}


def compute_birthday(texts):
    """Birthday-specific warmth signals (aggregate counts only)."""
    # Substring match so multi-codepoint emoji (e.g. "❤️") are detected whole.
    with_bday_emoji = sum(1 for t in texts if any(e in t for e in BIRTHDAY_EMOJI))
    double_exclaim = sum(1 for t in texts if "!!" in t)
    return {
        "pct_with_birthday_emoji": pct(with_bday_emoji, len(texts)),
        "pct_with_double_exclaim": pct(double_exclaim, len(texts)),
    }


def compute_fingerprint(normalized, burst_minutes):
    """The per-segment fingerprint sub-document. `normalized` is a list of
    {text, _ts, thread_id} dicts (bodies held only in memory)."""
    texts = [m["text"] for m in normalized]
    return {
        "sample_size": len(texts),
        "length": compute_length(texts),
        "capitalization": compute_capitalization(texts),
        "punctuation": compute_punctuation(texts),
        "emoji": compute_emoji(texts),
        "abbreviations": compute_abbreviations(texts),
        "bursts": compute_bursts(normalized, burst_minutes),
        "openers": compute_openers(texts),
        "closers": compute_closers(texts),
        "birthday": compute_birthday(texts),
    }


def main():
    ap = argparse.ArgumentParser(description="Compute a segmented birthday-wish voice fingerprint.")
    ap.add_argument("--input", required=True, help="Path to outbound-birthday-wishes JSON.")
    ap.add_argument("--burst-minutes", type=int, default=DEFAULT_BURST_MINUTES,
                    help=f"Gap threshold for burst grouping (default {DEFAULT_BURST_MINUTES}).")
    args = ap.parse_args()

    try:
        with open(args.input) as f:
            messages = json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": "file not found", "path": args.input}), file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)

    if not isinstance(messages, list):
        print(json.dumps({"error": "expected a JSON array"}), file=sys.stderr)
        sys.exit(2)

    normalized = []
    group_count = 0
    for m in messages:
        if not isinstance(m, dict):
            continue
        text = (m.get("text") or "").strip()
        ts = m.get("ts")
        if not text or not ts:
            continue
        try:
            parsed_ts = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            continue
        # Normalize tz-aware + naive to naive-UTC so sorting never mixes the two.
        if parsed_ts.tzinfo is not None:
            parsed_ts = parsed_ts.astimezone(timezone.utc).replace(tzinfo=None)
        tier_raw = m.get("tier")
        tier = tier_raw.strip().lower() if isinstance(tier_raw, str) and tier_raw.strip() else None
        gender_raw = m.get("gender")
        gender = gender_raw.strip().lower() if isinstance(gender_raw, str) and gender_raw.strip() else None
        is_group = bool(m.get("is_group"))
        if is_group:
            group_count += 1
        normalized.append({
            "text": text, "_ts": parsed_ts, "thread_id": m.get("thread_id"),
            "tier": tier, "gender": gender, "is_group": is_group,
        })

    if len(normalized) < OVERALL_MIN:
        print(json.dumps({
            "error": "sample too small",
            "sample_size": len(normalized),
            "minimum": OVERALL_MIN,
            "guidance": "Widen the lookback window, or you may simply not have enough "
                        "past birthday wishes on file yet.",
        }), file=sys.stderr)
        sys.exit(3)

    timestamps = [m["_ts"] for m in normalized]
    window = f"{min(timestamps).date().isoformat()} to {max(timestamps).date().isoformat()}"

    # Segment. A segment is emitted only when it clears SEGMENT_MIN; otherwise it's
    # listed in segments_omitted and callers fall back to `overall`.
    by_tier = defaultdict(list)
    by_gender = defaultdict(list)
    untiered = 0
    for m in normalized:
        if m["tier"]:
            by_tier[m["tier"]].append(m)
        else:
            untiered += 1
        if m["gender"]:
            by_gender[m["gender"]].append(m)

    segments_omitted = []
    tiers = {}
    for tier, msgs in sorted(by_tier.items()):
        if len(msgs) >= SEGMENT_MIN:
            tiers[tier] = compute_fingerprint(msgs, args.burst_minutes)
        else:
            segments_omitted.append({"segment": f"tier:{tier}", "count": len(msgs),
                                     "reason": f"only {len(msgs)} wishes (< {SEGMENT_MIN})"})
    genders = {}
    for gender, msgs in sorted(by_gender.items()):
        if len(msgs) >= SEGMENT_MIN:
            genders[gender] = compute_fingerprint(msgs, args.burst_minutes)
        else:
            segments_omitted.append({"segment": f"gender:{gender}", "count": len(msgs),
                                     "reason": f"only {len(msgs)} wishes (< {SEGMENT_MIN})"})

    warnings = []
    if len(normalized) < LOW_SAMPLE:
        warnings.append(
            f"Overall sample {len(normalized)} is under {LOW_SAMPLE} — patterns are "
            "suggestive, not strongly statistical. Tier segments are coarser still."
        )
    unknown_tiers = sorted(set(by_tier) - KNOWN_TIERS)
    if unknown_tiers:
        warnings.append(f"Non-standard tiers present (kept as-is): {', '.join(unknown_tiers)}.")

    result = {
        "kind": "birthday-voice",
        "sample_size": len(normalized),
        "window": window,
        "group_count": group_count,
        "untiered_count": untiered,
        "overall": compute_fingerprint(normalized, args.burst_minutes),
        "tiers": tiers,
        "genders": genders,
        "segments_omitted": segments_omitted,
        "warnings": warnings,
    }

    # Privacy guard, layer 1 (allowlist post-validation): every emitted opener/closer
    # must be a SAFE_TOKEN and every abbreviation a known ABBREVIATION. A value outside
    # its allowlist means content escaped the aggregation — fail closed. This catches
    # SINGLE-TOKEN leaks (e.g. a name surfacing as an opener) that the verbatim-body
    # scan below cannot (it requires a multi-word, space-containing match).
    segments = [result["overall"], *result["tiers"].values(), *result["genders"].values()]
    for seg in segments:
        emitted = (
            [("opener", o["phrase"]) for o in seg["openers"]["top_3"]]
            + [("closer", c["phrase"]) for c in seg["closers"]["top_3"]]
            + [("abbr", k) for k in seg["abbreviations"]]
        )
        for kind, tok in emitted:
            allowed = tok in SAFE_TOKENS if kind in ("opener", "closer") else tok in ABBREVIATIONS
            if not allowed:
                print(json.dumps({
                    "error": "privacy guard tripped: non-allowlisted token in output",
                    "field": kind,
                }), file=sys.stderr)
                sys.exit(5)

    # Privacy guard, layer 2 (belt-and-suspenders): no multi-word body may appear
    # verbatim in the serialized output. A match here means a regression embedded a
    # whole message body into some field.
    blob = json.dumps(result, ensure_ascii=False)
    for m in normalized:
        t = m["text"]
        if " " in t and t in blob:
            print(json.dumps({
                "error": "privacy guard tripped: a message body appears in the output",
                "body_length": len(t),
            }), file=sys.stderr)
            sys.exit(5)

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
