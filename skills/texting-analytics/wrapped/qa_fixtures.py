#!/usr/bin/env python3
"""qa_fixtures.py — synthetic users covering every Texting Wrapped archetype.

Generates one analysis.json per archetype (crafted to trip each branch of
build_wrapped.derive_archetype), writes them to examples/archetypes/ as reusable
committed fixtures, then renders each to a clickable wrapped.html preview under
dist/wrapped-preview/fixtures/ (gitignored) plus an index. Use this to QA the
whole card system across the full range of real-world texters in one pass.

All fixture data is SYNTHETIC — invented names, invented numbers. No real data.

Run:  python3 qa_fixtures.py        (then open the printed fixtures/index.html)
"""

import json
import os
import subprocess
import sys

import build_wrapped  # same dir

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FIXTURES = os.path.join(HERE, "..", "examples", "archetypes")
OUT = os.path.join(REPO, "dist", "wrapped-preview", "fixtures")


TOP_PEOPLE = [
    {"name": "Sample Contact A", "count": 2847}, {"name": "Sample Contact B", "count": 1962},
    {"name": "Sample Contact C", "count": 1403}, {"name": "Sample Contact D", "count": 982},
    {"name": "Sample Contact E", "count": 711}, {"name": "Sample Contact F", "count": 640},
    {"name": "Sample Contact G", "count": 588}, {"name": "Sample Contact H", "count": 502},
    {"name": "Sample Contact I", "count": 477}, {"name": "Sample Contact J", "count": 401},
]


def analysis(median, mean, fast, ball, group_pct, silent, total_groups,
             worst_total, worst_user, emoji_pct=23.0, reaction_rate=30,
             thread_count=90):
    """Build a schema-complete analysis.json for a synthetic user.
    emoji_pct=None omits the emoji/style blocks entirely (no content pass)."""
    a = {
        "top_people": TOP_PEOPLE,
        "latency": {
            "total_reply_pairs": 800, "pct_within_5min": fast, "pct_within_30min": min(fast + 20, 95),
            "pct_within_1hr": min(fast + 30, 97), "pct_within_4hr": min(fast + 45, 99),
            "mean_minutes": mean, "median_minutes": median, "thread_count": thread_count,
            "window_label": "past 12 months",
        },
        "ball_in_court": {
            "total_threads_sampled": 100, "threads_with_ball_in_court": ball,
            "pct_ball_in_court": ball, "live_conversations_estimate": 40, "snapshot_label": "May 2026",
        },
        "group_contribution": {
            "total_groups_analyzed": total_groups, "total_messages_in_groups": 900,
            "user_messages_in_groups": int(900 * group_pct / 100), "user_contribution_pct": group_pct,
            "user_reaction_rate_pct": reaction_rate, "peer_reaction_rate_pct": 32,
            "groups_where_user_silent": silent, "groups_mostly_reactions": 5,
            "per_thread": [
                {"thread_label": "the worst offender crew", "total": worst_total,
                 "user_count": worst_user, "user_pct": 0, "user_reaction_pct": 0},
                {"thread_label": "weekend plans", "total": 60, "user_count": 14, "user_pct": 23, "user_reaction_pct": 10},
            ],
        },
    }
    if emoji_pct is not None:
        a["emoji"] = {
            "pct_messages_with_emoji": emoji_pct, "emoji_per_message": round(emoji_pct / 56, 2),
            "top": [{"emoji": "😂", "count": 612}, {"emoji": "❤️", "count": 388},
                    {"emoji": "🙏", "count": 201}, {"emoji": "🔥", "count": 144},
                    {"emoji": "😭", "count": 97}],
        }
        a["style"] = {
            "pct_end_period": 9.0, "pct_all_lowercase": 61.0,
            "laugh_tokens": {"lol": 240, "haha": 180, "joy": 612}, "dominant_laugh": "joy",
            "sample_size": 4000, "active_days": 120,
        }
    return a


# (key, total_sent|None, expected_archetype, analysis) — one per archetype, in
# the derive_archetype priority order so the whole table stays covered.
SCENARIOS = [
    ("ghost",        None,  "The Group Chat Ghost",
     analysis(median=8,  mean=90,  fast=44, ball=60, group_pct=0.7, silent=12, total_groups=15, worst_total=1589, worst_user=0)),
    ("town_crier",   12100, "The Town Crier",
     analysis(median=7,  mean=20,  fast=42, ball=50, group_pct=51.2, silent=0, total_groups=9,  worst_total=70,  worst_user=30)),
    ("lightning",    14200, "The Lightning Round",
     analysis(median=1,  mean=4,   fast=82, ball=44, group_pct=14,  silent=1,  total_groups=10, worst_total=80,  worst_user=3)),
    ("royalty",      None,  "Left-on-Read Royalty",
     analysis(median=22, mean=40,  fast=24, ball=12, group_pct=9,   silent=2,  total_groups=11, worst_total=120, worst_user=2)),
    ("last_word",    9800,  "The Last Word",
     analysis(median=9,  mean=18,  fast=40, ball=88, group_pct=12,  silent=3,  total_groups=14, worst_total=120, worst_user=2)),
    ("ping_pong",    16400, "The Ping-Pong Pro",
     analysis(median=2.5, mean=7,  fast=68, ball=62, group_pct=12,  silent=1,  total_groups=10, worst_total=90,  worst_user=4)),
    ("mvp",          11200, "The Group MVP",
     analysis(median=6,  mean=15,  fast=50, ball=45, group_pct=33,  silent=0,  total_groups=8,  worst_total=60,  worst_user=20)),
    ("maximalist",   None,  "The Emoji Maximalist",
     analysis(median=5,  mean=12,  fast=52, ball=40, group_pct=15,  silent=1,  total_groups=10, worst_total=70,  worst_user=5, emoji_pct=52.0)),
    ("deadpan",      None,  "The Deadpan",
     analysis(median=18, mean=30,  fast=24, ball=42, group_pct=12,  silent=1,  total_groups=10, worst_total=70,  worst_user=5, emoji_pct=0.8)),
    ("sorry",        None,  "The Sorry-Just-Saw-This",
     analysis(median=50, mean=240, fast=10, ball=40, group_pct=10,  silent=2,  total_groups=12, worst_total=200, worst_user=1)),
    ("slow_burn",    None,  "The Slow Burn",
     analysis(median=95, mean=120, fast=6,  ball=44, group_pct=10,  silent=2,  total_groups=12, worst_total=200, worst_user=1)),
    ("fast_starter", None,  "The Fast Starter",
     analysis(median=4,  mean=77,  fast=47, ball=44, group_pct=8.8, silent=2,  total_groups=19, worst_total=48,  worst_user=0)),
    ("quick_draw",   14200, "The Quick Draw",
     analysis(median=2.5, mean=8,  fast=72, ball=45, group_pct=18,  silent=1,  total_groups=10, worst_total=80,  worst_user=3)),
    ("vip_room",     None,  "The VIP Room",
     analysis(median=6,  mean=14,  fast=48, ball=44, group_pct=5.5, silent=6,  total_groups=10, worst_total=140, worst_user=0)),
    ("lurker",       None,  "The Quiet Lurker",
     analysis(median=12, mean=25,  fast=20, ball=42, group_pct=4,   silent=3,  total_groups=14, worst_total=200, worst_user=0)),
    ("main_stage",   None,  "The Main Stage",
     analysis(median=12, mean=25,  fast=30, ball=28, group_pct=21,  silent=0,  total_groups=9,  worst_total=70,  worst_user=18)),
    ("diplomat",     None,  "The Diplomat",
     analysis(median=12, mean=24,  fast=34, ball=52, group_pct=11,  silent=1,  total_groups=10, worst_total=70,  worst_user=6)),
    ("steady",       None,  "The Steady Hand",
     analysis(median=35, mean=50,  fast=14, ball=66, group_pct=10,  silent=1,  total_groups=12, worst_total=70,  worst_user=6)),
    # Context-keyed reads — corpus-level signals (reaction rate, contact
    # breadth/concentration, raw volume).
    ("reaction_regular", None, "The Reaction Regular",
     analysis(median=12, mean=24,  fast=26, ball=42, group_pct=18,  silent=1,  total_groups=10, worst_total=90,  worst_user=4, reaction_rate=58)),
    ("connector",    24000, "The Social Connector",
     analysis(median=14, mean=26,  fast=30, ball=44, group_pct=12,  silent=1,  total_groups=12, worst_total=90,  worst_user=4)),
    ("inner_circle", 6000,  "The Inner-Circle Texter",
     analysis(median=20, mean=32,  fast=18, ball=42, group_pct=13,  silent=1,  total_groups=10, worst_total=90,  worst_user=4)),
    ("high_volume",  16000, "The High-Volume Texter",
     analysis(median=24, mean=39,  fast=18, ball=43, group_pct=24,  silent=2,  total_groups=24, worst_total=90,  worst_user=4, thread_count=48)),
]


def archetype_of(a, total_sent=None):
    lat, bic, grp = a["latency"], a["ball_in_court"], a["group_contribution"]
    emoji = a.get("emoji")
    return build_wrapped.derive_archetype(
        float(lat["median_minutes"]), float(lat["mean_minutes"]), lat["pct_within_5min"],
        bic["pct_ball_in_court"], grp["user_contribution_pct"],
        grp["groups_where_user_silent"], grp["total_groups_analyzed"],
        emoji["pct_messages_with_emoji"] if emoji else None,
        {
            "totalSent": total_sent,
            "threadCount": lat.get("thread_count"),
            "topPeople": a.get("top_people"),
            "reactionRate": grp.get("user_reaction_rate_pct"),
        },
    )["name"]


def main():
    os.makedirs(FIXTURES, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    # Clear stale fixtures from earlier archetype sets so the directory always
    # mirrors the CURRENT scenario keys.
    keep = {f"{key}.json" for key, *_ in SCENARIOS}
    for name in os.listdir(FIXTURES):
        if name.endswith(".json") and name not in keep:
            os.unlink(os.path.join(FIXTURES, name))
    rows, tiles, mismatches = [], [], 0

    for key, total_sent, expected, a in SCENARIOS:
        fpath = os.path.join(FIXTURES, f"{key}.json")
        with open(fpath, "w") as f:
            json.dump(a, f, indent=2)

        # Merge a playful texting-age block (age_estimate reads style/latency).
        if a.get("style"):
            age_cmd = [sys.executable, os.path.join(HERE, "..", "scripts", "age_estimate.py"), "--analysis", fpath]
            if total_sent:
                age_cmd += ["--total-sent", str(total_sent)]
            age_out = subprocess.run(age_cmd, capture_output=True, text=True)
            if age_out.returncode == 0:
                a["age"] = json.loads(age_out.stdout)["age"]
                with open(fpath, "w") as f:
                    json.dump(a, f, indent=2)

        got = archetype_of(a, total_sent)
        ok = got == expected
        mismatches += 0 if ok else 1

        html = os.path.join(OUT, f"{key}.html")
        cmd = [sys.executable, os.path.join(HERE, "build_wrapped.py"),
               "--analysis", fpath, "--output", html]
        if total_sent:
            cmd += ["--total-sent", str(total_sent)]
        subprocess.run(cmd, check=True, capture_output=True)

        rows.append(f"  {'✓' if ok else '✗'} {key:<13} → {got}"
                    + ("" if ok else f"  (expected {expected})"))
        tiles.append(
            f'<a class="tile" href="{key}.html" target="_blank">'
            f'<div class="frame"><iframe src="{key}.html" scrolling="no" loading="lazy" tabindex="-1"></iframe></div>'
            f'<div class="meta"><span class="name">{got}</span>'
            f'<span class="sub">{key}{" · +volume" if total_sent else ""}</span></div></a>'
        )

    index_html = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Texting Wrapped — QA gallery</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 40px 28px 64px; background: #0a0a0c; color: #f4f0e8;
    font-family: -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
  header { max-width: 1100px; margin: 0 auto 28px; }
  h1 { font-size: 26px; font-weight: 700; letter-spacing: -0.02em; margin: 0 0 6px; }
  p { margin: 0; color: #8a8694; font-size: 14px; }
  .grid { max-width: 1100px; margin: 0 auto;
    display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 22px; }
  .tile { text-decoration: none; color: inherit; display: block;
    border-radius: 18px; overflow: hidden; background: #131318;
    border: 1px solid rgba(255,255,255,0.08); transition: transform .15s ease, border-color .15s ease; }
  .tile:hover { transform: translateY(-3px); border-color: rgba(255,255,255,0.22); }
  .frame { position: relative; height: 380px; overflow: hidden; background: #000; }
  .frame iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0;
    pointer-events: none; }
  .meta { padding: 12px 16px 14px; }
  .name { display: block; font-weight: 600; font-size: 16px; letter-spacing: -0.01em; }
  .sub { display: block; margin-top: 2px; color: #8a8694;
    font-family: ui-monospace, "JetBrains Mono", monospace; font-size: 11px;
    letter-spacing: 0.04em; text-transform: uppercase; }
</style></head><body>
<header><h1>Texting Wrapped — QA gallery</h1>
<p>One synthetic user per archetype. Click a tile to open it full-size (swipe ←/→, test Share).</p></header>
<div class="grid">__TILES__</div>
</body></html>"""
    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write(index_html.replace("__TILES__", "".join(tiles)))

    print("\n".join(rows))
    print(f"\nfixtures: {os.path.relpath(FIXTURES, REPO)}/  ·  previews: {os.path.relpath(OUT, REPO)}/index.html")
    if mismatches:
        print(f"\n✗ {mismatches} archetype mismatch(es) — derive_archetype and the fixtures disagree.")
        sys.exit(1)
    print(f"\n✓ all {len(SCENARIOS)} archetypes rendered and matched.")


if __name__ == "__main__":
    main()
