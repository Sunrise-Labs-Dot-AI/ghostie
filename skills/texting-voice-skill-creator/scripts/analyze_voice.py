#!/usr/bin/env python3
"""analyze_voice.py — voice fingerprint from outbound iMessage history.

Reads a JSON file of outbound messages (from_me=true, substantive only — the
caller filters tapbacks/reactions before piping in) and emits an aggregate
voice fingerprint. Pure stdlib.

INVARIANT: the output never contains a message body. Aggregates only.

Input JSON (array at top level):
    [
      { "ts": "2026-05-28T14:23:11", "text": "hey what's up", "thread_id": 42 },
      ...
    ]

Usage:
    python3 analyze_voice.py --input messages.json \\
        --contact "Allison" --slug allison [--burst-minutes 2]

Output JSON (stdout):
    {
      "contact": "Allison",
      "slug": "allison",
      "sample_size": 432,
      "window": "2025-05-28 to 2026-05-28",
      "length": { ... },
      "capitalization": { ... },
      "punctuation": { ... },
      "emoji": { ... },
      "abbreviations": { ... },
      "bursts": { ... },
      "openers": { ... },
      "closers": { ... },
      "warnings": [ ... ]
    }

Exit codes:
    0 — success (may include warnings for low sample size)
    2 — input malformed
    3 — sample too small (<30 substantive messages)
    5 — privacy guard tripped (a full message body leaked into the output)
"""

import argparse
import json
import re
import statistics
import sys
import unicodedata
from collections import Counter
from datetime import datetime, timezone

# Common texting abbreviations — case-insensitive whole-word match.
ABBREVIATIONS = [
    "lol", "lmao", "lmfao", "omg", "omw", "ty", "tysm", "btw", "idk",
    "imo", "tbh", "fyi", "np", "rn", "ngl", "ily", "wyd", "smh",
]

# Openers/closers get emitted VERBATIM into a committed, shareable file, so they
# are restricted to this allowlist of generic greeting / acknowledgment / sign-off
# words. A message's actual first/last word is surfaced only if it's in here —
# otherwise it's dropped. This keeps proper nouns (names, places, employers) out
# of the fingerprint, honoring the no-message-bodies invariant.
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
    "happy", "congrats", "good", "glad", "excited",
})

# Burst definition default — consecutive outbound messages within this gap form one burst.
DEFAULT_BURST_MINUTES = 2

MIN_SAMPLE = 30
LOW_SAMPLE = 100


def is_emoji_char(c):
    """Heuristic: an emoji is a Unicode 'Symbol, Other' OR in supplementary ranges."""
    if not c:
        return False
    cp = ord(c)
    # Skip ASCII whitespace and basic punctuation explicitly.
    if cp < 0x2000:
        return False
    # Exclude letterlike + enclosed-alphanumeric symbols. These are category "So"
    # (or supplementary) but are READABLE LETTERS — e.g. circled letters Ⓙⓞⓗⓝ — so
    # they could spell a name verbatim into the committed emoji list. Privacy first.
    if 0x2100 <= cp <= 0x214F:   # Letterlike Symbols (™ ℠ ℡ ℅ …)
        return False
    if 0x2460 <= cp <= 0x24FF:   # Enclosed Alphanumerics (① Ⓐ ⓐ …)
        return False
    if 0x1F100 <= cp <= 0x1F1FF: # Enclosed Alphanumeric Supplement + regional indicators
        return False
    cat = unicodedata.category(c)
    if cat == "So":  # Symbol, Other — catches most emoji
        return True
    # Supplementary plane (emoji+pictographs+misc).
    if 0x1F000 <= cp <= 0x1FFFF:
        return True
    # Some emoji land in BMP miscellaneous symbols / dingbats.
    if 0x2600 <= cp <= 0x27BF:
        return True
    return False


def extract_emoji(text):
    """Return list of emoji code-point strings found in text."""
    return [c for c in text if is_emoji_char(c)]


def is_strippable_tail(c):
    """A trailing char that decorates a message end without being its terminal
    punctuation: an emoji, or a variation selector / combining mark / modifier
    (Mn, Cf, Sk — e.g. U+FE0F after ❤). Stripping these finds the real terminal
    `!`/`.` under a trailing "❤️"/"🎉" so punctuation stats aren't skewed."""
    return is_emoji_char(c) or unicodedata.category(c) in ("Mn", "Cf", "Sk")


def first_word(text):
    m = re.match(r"\s*([A-Za-z']+)", text)
    return m.group(1).lower() if m else None


def last_word(text):
    """Last alpha word, ignoring trailing punctuation/emoji."""
    # Strip trailing whitespace, punctuation, emoji.
    stripped = text.rstrip()
    while stripped and (
        stripped[-1] in ".!?,;:" or is_strippable_tail(stripped[-1]) or stripped[-1].isspace()
    ):
        stripped = stripped[:-1]
    m = re.search(r"([A-Za-z']+)$", stripped)
    return m.group(1).lower() if m else None


def pct(n, d):
    return round(n / d, 4) if d else 0.0


def compute_length(texts):
    lengths = [len(t) for t in texts]
    return {
        "median_chars": int(statistics.median(lengths)),
        "p25_chars": int(percentile(lengths, 25)),
        "p75_chars": int(percentile(lengths, 75)),
        "pct_under_20_chars": pct(sum(1 for l in lengths if l < 20), len(lengths)),
    }


def percentile(values, p):
    """Percentile via linear interpolation. (Distinct from pct(), which is a ratio.)"""
    if not values:
        return 0
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def compute_capitalization(texts):
    starts_lower = 0
    all_lower = 0
    for t in texts:
        first = next((c for c in t if c.isalpha()), None)
        if first and first.islower():
            starts_lower += 1
        # "all lowercase" = no uppercase alpha
        if not any(c.isupper() for c in t):
            all_lower += 1
    return {
        "pct_lowercase_start": pct(starts_lower, len(texts)),
        "pct_all_lowercase": pct(all_lower, len(texts)),
    }


def compute_punctuation(texts):
    period = exclaim = question = nothing = 0
    for t in texts:
        # Strip trailing whitespace + emoji (and variation selectors) to find the
        # real terminal char — e.g. "see you! ❤️" ends with "!", not the heart.
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
    top_5 = [{"emoji": e, "count": c} for e, c in all_emoji.most_common(5)]
    return {
        "pct_messages_with_emoji": pct(with_emoji, len(texts)),
        "top_5": top_5,
    }


def compute_abbreviations(texts):
    counts = Counter()
    for t in texts:
        lower = t.lower()
        for abbr in ABBREVIATIONS:
            # whole-word match
            matches = re.findall(rf"\b{re.escape(abbr)}\b", lower)
            if matches:
                counts[abbr] += len(matches)
    return dict(counts.most_common(15))


def compute_bursts(messages, burst_minutes):
    """Group consecutive outbound msgs (sorted by ts) where gap <= burst_minutes."""
    if not messages:
        return {"median_messages_per_burst": 0, "p75_messages_per_burst": 0,
                "burst_definition_minutes": burst_minutes}
    msgs = sorted(messages, key=lambda m: m["_ts"])
    burst_sizes = []
    current = 1
    for prev, curr in zip(msgs, msgs[1:]):
        # Require same thread for a burst.
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
    # Allowlist-only: surface a first word verbatim only if it's a recognized
    # greeting/filler. Drops proper nouns (names/places) to protect privacy.
    counter = Counter(w for w in (first_word(t) for t in texts) if w in SAFE_TOKENS)
    return {"top_3": [{"phrase": p, "count": c} for p, c in counter.most_common(3)]}


def compute_closers(texts):
    counter = Counter(w for w in (last_word(t) for t in texts) if w in SAFE_TOKENS)
    return {"top_3": [{"phrase": p, "count": c} for p, c in counter.most_common(3)]}


def main():
    ap = argparse.ArgumentParser(description="Compute a per-relationship texting voice fingerprint.")
    ap.add_argument("--input", required=True, help="Path to outbound-messages JSON.")
    ap.add_argument("--contact", required=True, help="Contact display name.")
    ap.add_argument("--slug", required=True, help="Slug for the generated skill (lowercase-hyphenated).")
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

    # Normalize + drop empty / non-text / malformed entries.
    normalized = []
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
        # Real exports mix tz-aware ("...Z") and naive timestamps. Comparing the
        # two raises TypeError in min()/max()/sorted(). Normalize everything to
        # naive-UTC so the rest of the pipeline never mixes the two.
        if parsed_ts.tzinfo is not None:
            parsed_ts = parsed_ts.astimezone(timezone.utc).replace(tzinfo=None)
        normalized.append({"text": text, "_ts": parsed_ts, "thread_id": m.get("thread_id")})

    if len(normalized) < MIN_SAMPLE:
        print(json.dumps({
            "error": "sample too small",
            "sample_size": len(normalized),
            "minimum": MIN_SAMPLE,
            "guidance": "Pick a contact with more outbound history, or widen the time window.",
        }), file=sys.stderr)
        sys.exit(3)

    texts = [m["text"] for m in normalized]
    timestamps = [m["_ts"] for m in normalized]
    window = f"{min(timestamps).date().isoformat()} to {max(timestamps).date().isoformat()}"

    warnings = []
    if len(normalized) < LOW_SAMPLE:
        warnings.append(
            f"Sample size {len(normalized)} is between {MIN_SAMPLE} and {LOW_SAMPLE} — "
            "patterns are suggestive but not strongly statistical. The generated SKILL.md "
            "will surface this caveat."
        )

    fingerprint = {
        "contact": args.contact,
        "slug": args.slug,
        "sample_size": len(normalized),
        "window": window,
        "length": compute_length(texts),
        "capitalization": compute_capitalization(texts),
        "punctuation": compute_punctuation(texts),
        "emoji": compute_emoji(texts),
        "abbreviations": compute_abbreviations(texts),
        "bursts": compute_bursts(normalized, args.burst_minutes),
        "openers": compute_openers(texts),
        "closers": compute_closers(texts),
        "warnings": warnings,
    }

    # Privacy guard, layer 1 (allowlist post-validation): every emitted opener/
    # closer must be a SAFE_TOKEN and every abbreviation a known ABBREVIATION. A
    # value outside its allowlist means content escaped aggregation — fail closed.
    # This catches SINGLE-TOKEN leaks (e.g. a name as an opener) that the verbatim-
    # body scan below cannot (it requires a multi-word, space-containing match).
    emitted = (
        [("opener", o["phrase"]) for o in fingerprint["openers"]["top_3"]]
        + [("closer", c["phrase"]) for c in fingerprint["closers"]["top_3"]]
        + [("abbr", k) for k in fingerprint["abbreviations"]]
    )
    for kind, tok in emitted:
        allowed = tok in SAFE_TOKENS if kind in ("opener", "closer") else tok in ABBREVIATIONS
        if not allowed:
            print(json.dumps({
                "error": "privacy guard tripped: non-allowlisted token in output",
                "field": kind,
            }), file=sys.stderr)
            sys.exit(5)

    # Privacy guard, layer 2 (belt-and-suspenders for the no-message-bodies
    # invariant): no full message body (any multi-word text) may appear verbatim in
    # the output. A match here means a regression embedded a whole body in a field.
    blob = json.dumps(fingerprint, ensure_ascii=False)
    for t in texts:
        if " " in t and t in blob:
            print(json.dumps({
                "error": "privacy guard tripped: a message body appears in the output",
                "body_length": len(t),  # never print the body itself
            }), file=sys.stderr)
            sys.exit(5)

    print(json.dumps(fingerprint, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
