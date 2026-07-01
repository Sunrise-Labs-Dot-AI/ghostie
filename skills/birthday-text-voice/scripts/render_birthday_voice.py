#!/usr/bin/env python3
"""render_birthday_voice.py — turn a segmented birthday fingerprint into the
learned-voice data the birthday-text-voice skill applies at draft time.

Reads a fingerprint JSON (from analyze_birthday_voice.py) and writes, into the
output dir (default: the skill dir):
    fingerprint.json   — the raw aggregate stats (regenerable data)
    VOICE.md           — human/LLM-readable: observed patterns + derived drafting
                         rules, overall and per relationship tier.

Deterministic: same fingerprint in, same VOICE.md out (no timestamps), so re-runs
are diffable. INVARIANT: the output never contains a message body — it only
reformats the already-aggregate fingerprint.

Refresh: unlike texting-voice-skill-creator's render_skill.py (which hard-refuses
to overwrite), this supports re-running. Without --force it refuses to clobber an
existing VOICE.md/fingerprint.json (exit 4); with --force it overwrites AND prints
a drift summary (which overall stats moved vs the prior fingerprint.json).

Usage:
    python3 render_birthday_voice.py --fingerprint fp.json [--output-dir DIR] [--force]

Exit codes:
    0 — success
    2 — fingerprint malformed
    4 — output already has VOICE.md/fingerprint.json and --force not given
"""

import argparse
import json
import os
import sys

DEFAULT_OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..")


def _p(x):  # percent int
    return int(round(x * 100))


def render_bullets(sub):
    lines = []
    L = sub["length"]
    lines.append(f"- **Length** — median {L['median_chars']} chars (p25 {L['p25_chars']}, "
                 f"p75 {L['p75_chars']}); {_p(L['pct_under_20_chars'])}% under 20 chars.")
    C = sub["capitalization"]
    lines.append(f"- **Capitalization** — {_p(C['pct_lowercase_start'])}% start lowercase; "
                 f"{_p(C['pct_all_lowercase'])}% fully lowercase.")
    P = sub["punctuation"]
    lines.append(f"- **Punctuation** — {_p(P['pct_ending_with_nothing'])}% end with nothing, "
                 f"{_p(P['pct_ending_with_period'])}% a period, {_p(P['pct_ending_with_exclaim'])}% `!`.")
    E = sub["emoji"]
    top_emo = ", ".join(f"{e['emoji']} ({e['count']})" for e in E["top_5"]) or "none"
    lines.append(f"- **Emoji** — {_p(E['pct_messages_with_emoji'])}% have emoji. Top: {top_emo}.")
    Bd = sub["birthday"]
    lines.append(f"- **Birthday warmth** — {_p(Bd['pct_with_birthday_emoji'])}% use a birthday emoji "
                 f"(🎂🎉🎁…); {_p(Bd['pct_with_double_exclaim'])}% use an emphatic `!!`.")
    if sub.get("abbreviations"):
        abbr = ", ".join(f"{k}×{v}" for k, v in sub["abbreviations"].items())
        lines.append(f"- **Abbreviations** — {abbr}.")
    O = sub["openers"]
    if O["top_3"]:
        lines.append("- **Top openers** — " + ", ".join(f"\"{o['phrase']}\" ({o['count']})" for o in O["top_3"]) + ".")
    Cl = sub["closers"]
    if Cl["top_3"]:
        lines.append("- **Top closers** — " + ", ".join(f"\"{c['phrase']}\" ({c['count']})" for c in Cl["top_3"]) + ".")
    return "\n".join(lines)


def render_rules(sub):
    rules = []
    L = sub["length"]
    rules.append(f"- Aim for ~{L['median_chars']} chars. Longer than p75 ({L['p75_chars']}) reads off-voice.")
    C = sub["capitalization"]
    if C["pct_lowercase_start"] >= 0.5:
        rules.append("- Default to a lowercase first word.")
    elif C["pct_lowercase_start"] < 0.2:
        rules.append("- Use standard capitalization here.")
    P = sub["punctuation"]
    if P["pct_ending_with_exclaim"] >= 0.4:
        rules.append("- Birthday wishes here usually end on a `!` — keep the energy up.")
    elif P["pct_ending_with_nothing"] >= 0.5:
        rules.append("- Most end with no terminal punctuation — don't force a period.")
    E = sub["emoji"]
    Bd = sub["birthday"]
    if E["pct_messages_with_emoji"] >= 0.3 and E["top_5"]:
        favs = " / ".join(e["emoji"] for e in E["top_5"][:3])
        rules.append(f"- Emoji are common ({_p(E['pct_messages_with_emoji'])}%). Favor {favs}.")
    elif E["pct_messages_with_emoji"] < 0.1:
        rules.append("- Emoji are rare here — don't add them by default.")
    if Bd["pct_with_birthday_emoji"] >= 0.4:
        rules.append("- A birthday emoji (🎂/🎉) is the norm — include one.")
    B = sub["bursts"]
    if B["median_messages_per_burst"] >= 2:
        rules.append(f"- Often two-part (median {B['median_messages_per_burst']}) — the wish, then a follow-up "
                     "line. Stage as two drafts, not one long message.")
    return "\n".join(rules)


def render_segment(label, sub):
    return (f"### {label} (N={sub['sample_size']})\n\n"
            f"{render_bullets(sub)}\n\n**Drafting rules**\n\n{render_rules(sub)}\n")


def render_drift(prev, curr):
    """Overall-stat deltas vs the prior fingerprint. Returns a markdown block."""
    if not prev:
        return "_First refresh — no prior snapshot to compare._"
    po, co = prev.get("overall", {}), curr["overall"]

    def g(d, *path):
        for k in path:
            d = (d or {}).get(k, {})
        return d if isinstance(d, (int, float)) else None

    rows = [
        ("Sample size", prev.get("sample_size"), curr["sample_size"], False),
        ("Median length (chars)", g(po, "length", "median_chars"), g(co, "length", "median_chars"), False),
        ("Emoji rate", g(po, "emoji", "pct_messages_with_emoji"), g(co, "emoji", "pct_messages_with_emoji"), True),
        ("Ends with !", g(po, "punctuation", "pct_ending_with_exclaim"), g(co, "punctuation", "pct_ending_with_exclaim"), True),
        ("Birthday-emoji rate", g(po, "birthday", "pct_with_birthday_emoji"), g(co, "birthday", "pct_with_birthday_emoji"), True),
    ]
    out = ["| Stat | Was | Now |", "|---|---|---|"]
    for name, was, now, is_pct in rows:
        fw = "—" if was is None else (f"{_p(was)}%" if is_pct else str(was))
        fn = "—" if now is None else (f"{_p(now)}%" if is_pct else str(now))
        out.append(f"| {name} | {fw} | {fn} |")
    return "\n".join(out)


def render_voice_md(fp, prev):
    parts = [
        "# Birthday voice (learned)\n",
        f"Aggregate stats only — no message bodies. Learned from **N={fp['sample_size']}** past "
        f"outbound birthday wishes ({fp['window']}); {fp['group_count']} from group threads, "
        f"{fp['untiered_count']} not attributable to a tier.\n",
    ]
    if fp.get("warnings"):
        parts.append("> " + " ".join(fp["warnings"]) + "\n")

    parts.append("## Overall birthday voice\n")
    parts.append(render_bullets(fp["overall"]) + "\n")
    parts.append("**Drafting rules**\n\n" + render_rules(fp["overall"]) + "\n")

    if fp.get("tiers"):
        parts.append("## By relationship tier\n")
        for tier in sorted(fp["tiers"]):
            parts.append(render_segment(tier, fp["tiers"][tier]))
    if fp.get("genders"):
        parts.append("## By gender\n")
        for g_ in sorted(fp["genders"]):
            parts.append(render_segment(g_, fp["genders"][g_]))

    if fp.get("segments_omitted"):
        omitted = ", ".join(f"{s['segment']} ({s['count']})" for s in fp["segments_omitted"])
        parts.append(f"## Segments below threshold\n\nNot shown (too few wishes): {omitted}. "
                     "**Fall back to the overall voice** for these recipients.\n")

    parts.append("## Drift since last refresh\n\n" + render_drift(prev, fp) + "\n")

    parts.append(
        "## How to use\n\n"
        "This is an **overlay** on `anthropic-skills:james-text-voice`. To draft a birthday "
        "wish: apply james-text-voice's base rules, then pick the section matching the "
        "recipient's relationship tier (family / friend / partner / colleague). If that tier "
        "isn't shown, use **Overall**; if Overall is thin, defer to james-text-voice. "
        "Patterns are statistical — honor any explicit override from James.\n"
    )
    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser(description="Render the learned birthday voice from a fingerprint.")
    ap.add_argument("--fingerprint", required=True, help="Path to fingerprint JSON from analyze_birthday_voice.py.")
    ap.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                    help="Where to write VOICE.md + fingerprint.json (default: the skill dir).")
    ap.add_argument("--force", action="store_true", help="Overwrite existing output (and print a drift summary).")
    args = ap.parse_args()

    try:
        with open(args.fingerprint) as f:
            fp = json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": "fingerprint not found", "path": args.fingerprint}), file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)

    if not isinstance(fp, dict) or fp.get("kind") != "birthday-voice":
        print(json.dumps({"error": "not a birthday-voice fingerprint (missing kind)"}), file=sys.stderr)
        sys.exit(2)
    overall = fp.get("overall")
    needed = {"length", "capitalization", "punctuation", "emoji", "abbreviations",
              "bursts", "openers", "closers", "birthday"}
    if not isinstance(overall, dict) or (needed - set(overall)):
        print(json.dumps({"error": "fingerprint 'overall' missing required sections",
                          "missing": sorted(needed - set(overall or {}))}), file=sys.stderr)
        sys.exit(2)

    # Validate the inner shape too — top-level keys alone let "length": {} through,
    # which then KeyErrors mid-render (after partial writes). Fail fast instead.
    inner_required = {
        "length": ["median_chars", "p25_chars", "p75_chars", "pct_under_20_chars"],
        "capitalization": ["pct_lowercase_start", "pct_all_lowercase"],
        "punctuation": ["pct_ending_with_period", "pct_ending_with_nothing",
                        "pct_ending_with_exclaim", "pct_ending_with_question"],
        "emoji": ["pct_messages_with_emoji", "top_5"],
        "bursts": ["median_messages_per_burst", "p75_messages_per_burst", "burst_definition_minutes"],
        "openers": ["top_3"], "closers": ["top_3"],
        "birthday": ["pct_with_birthday_emoji", "pct_with_double_exclaim"],
    }
    for key, subkeys in inner_required.items():
        sec = overall.get(key)
        if not isinstance(sec, dict) or any(s not in sec for s in subkeys):
            print(json.dumps({"error": f"fingerprint 'overall.{key}' missing required fields",
                              "expected": subkeys}), file=sys.stderr)
            sys.exit(2)

    out_dir = args.output_dir
    voice_path = os.path.join(out_dir, "VOICE.md")
    fp_path = os.path.join(out_dir, "fingerprint.json")

    prev = None
    if os.path.exists(fp_path):
        if not args.force:
            print(json.dumps({
                "error": "output already exists",
                "path": fp_path,
                "guidance": "Re-run with --force to refresh in place (a drift summary is printed).",
            }), file=sys.stderr)
            sys.exit(4)
        try:
            with open(fp_path) as f:
                prev = json.load(f)
        except (json.JSONDecodeError, OSError):
            prev = None  # corrupt prior snapshot → treat as first run for drift

    os.makedirs(out_dir, exist_ok=True)
    with open(voice_path, "w") as f:
        f.write(render_voice_md(fp, prev))
    with open(fp_path, "w") as f:
        json.dump(fp, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(json.dumps({
        "status": "ok",
        "refreshed": bool(prev),
        "files": ["VOICE.md", "fingerprint.json"],
        "output_dir": os.path.realpath(out_dir),
        "sample_size": fp["sample_size"],
        "tiers": sorted(fp.get("tiers", {})),
    }, indent=2))


if __name__ == "__main__":
    main()
