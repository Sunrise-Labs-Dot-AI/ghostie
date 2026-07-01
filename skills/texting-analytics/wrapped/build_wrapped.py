#!/usr/bin/env python3
"""build_wrapped.py — render a shareable "Texting Wrapped" from analysis.json.

Takes the analysis.json the chart generator uses and produces a single,
self-contained wrapped.html: a swipeable story in an iPhone frame, from the
Claude Design handoff (see DESIGN-HANDOFF.md). The design files (ios-frame.jsx,
treatments.jsx, app.jsx) are the source of truth for the look; this script just
maps real data into them and inlines everything into one file.

ONE canonical look (the "sunrise" system — warm editorial gradients, serif hero
numbers). There is no treatment flag anymore: less choice, more polish.

TWO time windows, ONE file. Pass the past-year analysis via --analysis and
(optionally) the all-time analysis via --analysis-all-time; the generated HTML
embeds BOTH metric sets and shows a small "All time" toggle inside the
presentation UI (default view: past year). With only --analysis, no toggle.

Pure stdlib. Deterministic: no LLM calls, no network at build time, and the
injected data is aggregates only — never message bodies.

Data mapping (analysis.json → card data):
  latency.median_minutes        → median reply
  latency.mean_minutes          → mean reply
  latency.pct_within_5min       → fast %
  ball_in_court.pct_ball_in_court → last-word % (threads where YOU sent last)
  group_contribution.user_contribution_pct → group share
  group_contribution.groups_where_user_silent / total_groups_analyzed
  group_contribution.per_thread → "top offender" ghost thread (derived)
  archetype                     → derived from the metrics (see derive_archetype)

Honest about gaps in the current analytics:
  - The Volume card needs a total-sent count, which analysis.json doesn't carry
    yet. Pass --total-sent N (and --all-time-total-sent N) to include it.
  - The Top People card needs contact NAMES — a privacy call. Suppress with
    --no-people when generating a Wrapped meant for public sharing.

Usage:
  python3 build_wrapped.py --analysis analysis.json --output wrapped.html
  python3 build_wrapped.py --analysis year.json --analysis-all-time all.json \\
      --total-sent 12400 --all-time-total-sent 48200 --output wrapped.html

Exit codes: 0 ok · 2 input malformed
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def derive_worst_ghost(group):
    """Pick the most damning group thread: highest message count where the user
    contributed least (ideally zero). Returns {name, messages, userSent} or
    None. Prefers the `worst_offender` block emitted by analyze.py (computed
    over the FULL group set); falls back to scanning per_thread for older
    analyses that didn't emit it (per_thread is truncated to top-12 by user
    contribution, so silent groups can be missing — the fallback is best-
    effort)."""
    pick = group.get("worst_offender")
    if not pick:
        threads = group.get("per_thread") or []
        if not threads:
            return None
        zero = [t for t in threads if t.get("user_count", 1) == 0]
        pool = zero or threads
        pick = max(pool, key=lambda t: (t.get("total", 0), -t.get("user_count", 0)))
    return {
        "name": pick.get("thread_label", "a group"),
        "messages": pick.get("total", 0),
        "userSent": pick.get("user_count", 0),
    }


def derive_archetype(median, mean, fast_pct, ball, group_pct, silent, total_groups, emoji_pct=None, context=None):
    """Pick the most salient archetype. Priority-ordered: first match wins,
    most distinctive first. Verdict/why use the user's REAL numbers so it's
    honest; the verdicts are roast-adjacent but only ever roast the USER,
    never a named third party.

    Semantics (matches analyze.py's ball_block): `ball` = % of threads where
    the USER sent the last substantive message. High ball → you served and
    they went quiet; LOW ball → most threads are parked on YOUR reply.
    (Earlier archetypes read this backwards — fixed here.)

    `emoji_pct` is None when no emoji pass ran — the emoji-keyed archetypes
    only fire when the signal actually exists (a missing block is not 0%).

    `context` carries optional corpus-level signals (total sent, thread
    breadth, top-contact concentration, group reaction rate). The context-keyed archetypes sit BELOW the distinctive
    single-signal reads and ABOVE the generic fallbacks, so they widen the
    spread without shadowing an established read.

    Calibration metadata (see research/texting-personalization-calibration.md):
    `drivers` name the real numbers behind the call, `confidence` grades the
    evidence, and `support_level` marks the weaker reads (ball-in-court and
    mixed-signal inferences) as cautious/playful instead of fact-grade.

    Thresholds are tuned so the distribution SPREADS: across varied users most
    archetypes are reachable, and the Steady Hand fallback is a last resort,
    not an 80% bucket. The synthetic-persona eval
    (tests/test_synthetic_eval.py) enforces >= 10 distinct archetypes across
    its persona set; tests/fixtures/texting/wrapped-personas.json pins
    per-persona expectations.
    """
    context = context or {}
    slow_tail = mean >= max(4 * max(median, 0.1), median + 20)
    groups_known = total_groups >= 3
    silent_ratio = (silent / total_groups) if total_groups else 0.0
    active_groups = max(total_groups - silent, 0)
    total_sent = context.get("totalSent")
    thread_count = context.get("threadCount")
    top_people = context.get("topPeople") or []
    top_count = top_people[0].get("count") if top_people else None
    top_share = ((100 * top_count / total_sent) if total_sent and top_count is not None else None)
    reaction_rate = context.get("reactionRate") or 0

    def A(name, short, verdict, why, drivers, confidence="medium", support_level="supported"):
        return {
            "name": name, "short": short, "verdict": verdict, "why": why, "drivers": drivers,
            "confidence": confidence, "support_level": support_level,
        }

    if groups_known and group_pct < 3 and silent_ratio >= 0.5:
        return A("The Group Chat Ghost", "Ghost", "present in name, absent in spirit.",
                 f"{group_pct:.1f}% group share, silent in {silent} of {total_groups} groups.",
                 [f"{group_pct:.1f}% group share", f"silent in {silent} of {total_groups} groups", f"last word in {ball}% of threads"],
                 "low", "playful")
    if groups_known and group_pct >= 45:
        return A("The Town Crier", "Crier", "you don't have a group chat. the group chat has you.",
                 f"you sent {group_pct:.1f}% of every group message — the others are an audience.",
                 [f"{group_pct:.1f}% group share", f"active in {active_groups} of {total_groups} groups", f"{median:g} min median reply"],
                 "high", "supported")
    if median <= 1.5 and fast_pct >= 70:
        return A("The Lightning Round", "Lightning", "replying this fast is legally a reflex.",
                 f"median reply {median:g} min, {fast_pct}% inside five minutes.",
                 [f"{median:g} min median reply", f"{fast_pct}% within five", f"last word in {ball}% of threads"],
                 "high", "supported")
    if ball <= 18:
        return A("Left-on-Read Royalty", "Royalty", "everyone's favorite person to wait on.",
                 f"you had the last word in only {ball}% of threads — the other {100 - ball}% are parked on your reply.",
                 [f"last word in {ball}% of threads", f"{median:g} min median reply", f"{group_pct:.1f}% group share"],
                 "low", "playful")
    if ball >= 80:
        return A("The Last Word", "Last Word", "you simply must close every thread. the silence after is on them.",
                 f"you sent the final message in {ball}% of your threads.",
                 [f"last word in {ball}% of threads", f"{median:g} min median reply", f"{fast_pct}% within five"],
                 "low", "playful")
    if ball >= 55 and fast_pct >= 55 and median <= 5:
        return A("The Ping-Pong Pro", "Ping-Pong", "every serve comes back. every single one.",
                 f"median {median:g} min, {fast_pct}% within five, last word in {ball}% of threads.",
                 [f"{median:g} min median reply", f"{fast_pct}% within five", f"last word in {ball}% of threads"],
                 "medium", "cautious")
    if groups_known and group_pct >= 28:
        return A("The Group MVP", "MVP", "the group chat would flatline without you. you've checked.",
                 f"you send {group_pct:.1f}% of all group messages — far above an even share.",
                 [f"{group_pct:.1f}% group share", f"active in {active_groups} of {total_groups} groups", f"last word in {ball}% of threads"],
                 "high", "supported")
    if emoji_pct is not None and emoji_pct >= 45:
        return A("The Emoji Maximalist", "Maximalist", "why use words when a tiny face says it worse.",
                 f"{emoji_pct:.0f}% of your texts carry at least one emoji.",
                 [f"{emoji_pct:.0f}% emoji-bearing texts", f"{median:g} min median reply", f"{group_pct:.1f}% group share"],
                 "medium", "supported")
    if emoji_pct is not None and emoji_pct <= 2:
        return A("The Deadpan", "Deadpan", "every message delivered at room temperature.",
                 f"only {emoji_pct:.1f}% of your texts contain an emoji.",
                 [f"{emoji_pct:.1f}% emoji-bearing texts", f"{median:g} min median reply", f"{group_pct:.1f}% group share"],
                 "medium", "supported")
    if median >= 45 and slow_tail:
        return A("The Sorry-Just-Saw-This", "Sorry", "'sorry, just saw this.' you saw it. everyone knows you saw it.",
                 f"median reply {median:g} min, and the slow ones stretch the average to {mean:g}.",
                 [f"{median:g} min median reply", f"{mean:g} min mean reply", f"{fast_pct}% within five"],
                 "medium", "supported")
    if median >= 60:
        return A("The Slow Burn", "Slow Burn", "replies measured in business days.",
                 f"half your replies take longer than {median:g} minutes.",
                 [f"{median:g} min median reply", f"{fast_pct}% within five", f"last word in {ball}% of threads"],
                 "medium", "supported")
    if slow_tail and median <= 10:
        return A("The Fast Starter", "Fast Starter", "quick on the draw, slow on the follow-through.",
                 f"median reply {median:g} min, but the mean is {mean:g} min — the long tail tells on you.",
                 [f"{median:g} min median reply", f"{mean:g} min mean reply", f"{fast_pct}% within five"],
                 "medium", "supported")
    if median <= 3:
        return A("The Quick Draw", "Quick Draw", "replies before the typing bubble fades.",
                 f"median reply {median:g} min, {fast_pct}% within five.",
                 [f"{median:g} min median reply", f"{fast_pct}% within five", f"last word in {ball}% of threads"],
                 "high", "supported")
    if groups_known and silent_ratio >= 0.5 and median <= 8:
        return A("The VIP Room", "VIP", "fast for the chosen few. the group chat didn't make the list.",
                 f"median reply {median:g} min in your threads, yet silent in {silent} of {total_groups} groups.",
                 [f"{median:g} min median reply", f"silent in {silent} of {total_groups} groups", f"{group_pct:.1f}% group share"],
                 "medium", "cautious")
    if groups_known and group_pct < 5:
        return A("The Quiet Lurker", "Lurker", "sees everything. says nothing. knows all.",
                 f"just {group_pct:.1f}% of group messages, silent in {silent} of {total_groups} groups.",
                 [f"{group_pct:.1f}% group share", f"silent in {silent} of {total_groups} groups", f"{median:g} min median reply"],
                 "medium", "cautious")
    if groups_known and ball <= 35 and group_pct >= 15:
        return A("The Main Stage", "Main Stage", "electric in the group chat, bankrupt in the DMs.",
                 f"{group_pct:.1f}% group share while {100 - ball}% of threads wait on your reply.",
                 [f"{group_pct:.1f}% group share", f"last word in {ball}% of threads", f"{median:g} min median reply"],
                 "medium", "cautious")
    if groups_known and reaction_rate >= 45:
        return A("The Reaction Regular", "Reactor", "keeps the thread warm without writing a novel.",
                 f"{reaction_rate:.0f}% of your group-chat activity is reactions.",
                 [f"{reaction_rate:.0f}% reaction rate", f"active in {active_groups} of {total_groups} groups", f"{group_pct:.1f}% group share"],
                 "medium", "supported")
    if total_sent is not None and thread_count is not None and top_share is not None and total_sent >= 9000 and thread_count >= 60 and top_share <= 20:
        return A("The Social Connector", "Connector", "many threads, no single lane.",
                 f"{total_sent:,} texts across {thread_count} active threads, with your top contact at {top_share:.1f}% of sends.",
                 [f"{total_sent:,} texts sent", f"{thread_count} active threads", f"{top_share:.1f}% to top contact"],
                 "high", "supported")
    if top_share is not None and total_sent is not None and total_sent >= 1500 and top_share >= 28:
        return A("The Inner-Circle Texter", "Inner Circle", "small circle, strong signal.",
                 f"{top_share:.1f}% of your sent texts go to your top contact.",
                 [f"{top_share:.1f}% to top contact", f"{total_sent:,} texts sent", f"{median:g} min median reply"],
                 "high", "supported")
    if total_sent is not None and total_sent >= 15000:
        return A("The High-Volume Texter", "High Volume", "the conversation engine is always on.",
                 f"{total_sent:,} sent texts in this window.",
                 [f"{total_sent:,} texts sent", f"{median:g} min median reply", f"{group_pct:.1f}% group share"],
                 "medium", "supported")
    if 45 <= ball <= 60 and 5 <= median <= 30:
        return A("The Diplomat", "Diplomat", "balanced, measured, suspiciously reasonable.",
                 f"median {median:g} min, last word in {ball}% of threads — even on both sides of the net.",
                 [f"{median:g} min median reply", f"last word in {ball}% of threads", f"{group_pct:.1f}% group share"],
                 "medium", "cautious")
    return A("The Steady Hand", "Steady", "consistent, present, hard to rattle.",
             f"median {median:g} min, {ball}% last-word rate, {group_pct:.1f}% group share.",
             [f"{median:g} min median reply", f"{ball}% last-word rate", f"{group_pct:.1f}% group share"],
             "medium", "cautious")


def should_show_age(age):
    """Render the playful age card only when the estimator left enough
    evidence behind (mirrors the guardrails in age_estimate.py): a real
    estimate, 500+ outbound messages, 30+ active days, and 3+ independent
    fired features with 3 explainable drivers."""
    if not age:
        return False
    drivers = age.get("drivers") or []
    sample_size = age.get("sample_size")
    evidence_count = age.get("evidence_count")
    return (
        age.get("estimated_age") is not None
        and sample_size is not None and sample_size >= 500
        and age.get("active_days") is not None and age.get("active_days") >= 30
        and evidence_count is not None and evidence_count >= 3
        and len(drivers) >= 3
    )


def build_data(analysis, year, total_sent, show_people):
    lat = analysis.get("latency", {})
    bic = analysis.get("ball_in_court", {})
    grp = analysis.get("group_contribution", {})

    median = float(lat.get("median_minutes", 0))
    mean = float(lat.get("mean_minutes", 0))
    fast_pct = int(round(lat.get("pct_within_5min", 0)))
    ball = int(round(bic.get("pct_ball_in_court", 0)))
    group_pct = float(grp.get("user_contribution_pct", 0))
    silent = int(grp.get("groups_where_user_silent", 0))
    total_groups = int(grp.get("total_groups_analyzed", 0))
    emoji_block = analysis.get("emoji")
    emoji_pct = float(emoji_block.get("pct_messages_with_emoji", 0)) if emoji_block else None

    archetype = derive_archetype(median, mean, fast_pct, ball, group_pct, silent, total_groups, emoji_pct, {
        "totalSent": total_sent,
        "threadCount": lat.get("thread_count"),
        "topPeople": analysis.get("top_people"),
        "reactionRate": grp.get("user_reaction_rate_pct"),
    })
    worst_ghost = derive_worst_ghost(grp)

    # Card arc — start with the always-available cards.
    cards = ["cover"]
    if total_sent:
        cards.append("volume")
    # Top people: included whenever analyze.py produced the list (it's a
    # personal "keep" card). show_people=False suppresses it (e.g. public share).
    top_people = analysis.get("top_people") if show_people else None
    top_people_by_chars = analysis.get("top_people_by_chars") if show_people else None
    if top_people:
        cards.append("people")
    top_people_l30 = analysis.get("top_people_l30") if show_people else None
    if top_people_l30:
        # Second People card — same surface, restricted to the LAST 30 DAYS.
        # Pairs with the past-year ranking to show what's hot right now.
        cards.append("people_l30")
    talk_listen = analysis.get("talk_listen") if show_people else None
    if talk_listen and talk_listen.get("you_words") and talk_listen.get("them_words"):
        # Third People-adjacent card — aggregate talker/listener ratio + per-
        # person outliers. Highlights surface names → personal-only.
        cards.append("talk_listen")
    cards += ["latency", "ballincourt", "groups"]
    emoji = analysis.get("emoji")
    if emoji:
        cards.append("emoji")
    age = analysis.get("age") if should_show_age(analysis.get("age")) else None
    if age:
        cards.append("age")
    cards += ["archetype", "share"]

    # Window label: "May 2025 — May 2026" for a year-bounded analysis, "All
    # time" if the analyze step ran with --window-days 0. Lets the wrapped
    # show the actual data range instead of anchoring to a single calendar
    # year (a Wrapped run in mid-2026 should say so).
    import datetime as _dt
    f = analysis.get("filters", {}) or {}
    since_ms, until_ms = f.get("since_ts_ms"), f.get("until_ts_ms")
    window_days = f.get("window_days")
    if window_days == 0 or since_ms in (None, 0):
        window_label = "All time"
    elif until_ms:
        start = _dt.datetime.fromtimestamp(since_ms / 1000)
        end = _dt.datetime.fromtimestamp(until_ms / 1000)
        window_label = f"{start.strftime('%b %Y')} — {end.strftime('%b %Y')}"
    else:
        window_label = str(year)

    data = {
        "year": year,
        "windowLabel": window_label,
        "windowDays": window_days if window_days is not None else 365,
        "median": round(median, 1),
        "mean": round(mean, 1),
        "fastPct": fast_pct,
        "ballInCourt": ball,
        "groupContribPct": round(group_pct, 1),
        "silentGroups": silent,
        "totalGroups": total_groups,
        "worstGhost": worst_ghost,
        "archetype": archetype,
        "cards": cards,
    }
    if total_sent:
        data["totalSent"] = int(total_sent)
    if top_people:
        data["topPeople"] = top_people
    if top_people_l30:
        data["topPeopleL30"] = top_people_l30
    if talk_listen and talk_listen.get("you_words") and talk_listen.get("them_words"):
        data["talkListen"] = talk_listen
    if emoji:
        data["emoji"] = emoji
    if analysis.get("style"):
        data["style"] = analysis["style"]
    if age:
        data["age"] = age
    return data


HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Texting Wrapped {year}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Instrument+Serif:ital@0;1&family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  html, body {{ margin: 0; padding: 0; height: 100%; background: #0a0a0c;
    font-family: 'Inter', system-ui, sans-serif; -webkit-font-smoothing: antialiased;
    text-rendering: geometricPrecision; }}
  #root {{ width: 100%; height: 100%; }}
  * {{ box-sizing: border-box; }}
  button {{ font: inherit; }}
</style>
</head>
<body>
<div id="root"></div>
<script src="https://unpkg.com/react@18.3.1/umd/react.production.min.js" crossorigin></script>
<script src="https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js" crossorigin></script>
<script src="https://unpkg.com/@babel/standalone@7.29.0/babel.min.js" crossorigin></script>
"""


def escape_script(source):
    return source.replace("</script", "<\\/script")


def safe_json(value):
    """Serialize for embedding inside an inline <script>. json.dumps does NOT
    escape the substring "</script>", and the HTML tokenizer closes the script
    element at the first literal "</script>" regardless of JS string context —
    so a chat.db-derived value (a group renamed to "</script><img …>") reaching
    WRAPPED_DATASETS would break out and execute when the user opens the file.
    Escaping "<" as \\u003c round-trips identically through JSON.parse while
    keeping "</script>"/"<!--" out of the tokenizer's view."""
    return json.dumps(value, ensure_ascii=False).replace("<", "\\u003c")


def read_capture_runtime():
    candidates = [
        os.path.join(HERE, "html2canvas.min.js"),
        os.path.normpath(os.path.join(
            HERE,
            "..", "..", "..",
            "mcps", "wrapped-generator", "node_modules",
            "html2canvas", "dist", "html2canvas.min.js",
        )),
    ]
    for path in candidates:
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                return f.read()
    raise FileNotFoundError(
        "html2canvas.min.js not found. Run `bun install` in mcps/wrapped-generator "
        "or place html2canvas.min.js next to build_wrapped.py."
    )


def load_json(path, label):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": f"{label} file not found", "path": path}), file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON", "path": path, "detail": str(e)}), file=sys.stderr)
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description="Render a shareable Texting Wrapped from analysis.json.")
    ap.add_argument("--analysis", required=True, help="Path to the past-year analysis.json.")
    ap.add_argument("--analysis-all-time", default=None,
                    help="Path to the all-time analysis.json. When given, the generated HTML "
                         "embeds BOTH metric sets and shows an in-page 'All time' toggle "
                         "(default view: past year).")
    ap.add_argument("--output", required=True, help="Path to write wrapped.html.")
    ap.add_argument("--year", type=int, default=2026)
    ap.add_argument("--total-sent", type=int, default=None,
                    help="Total texts sent in the past-year window — enables the Volume card.")
    ap.add_argument("--all-time-total-sent", type=int, default=None,
                    help="Total texts sent all-time — Volume card for the all-time view.")
    ap.add_argument("--no-people", action="store_true",
                    help="Suppress the Top People card (it shows contact NAMES — pass this "
                         "when generating a Wrapped meant for public sharing).")
    args = ap.parse_args()

    analysis = load_json(args.analysis, "analysis")
    show_people = not args.no_people
    data = build_data(analysis, args.year, args.total_sent, show_people=show_people)

    all_time_data = None
    if args.analysis_all_time:
        all_time_analysis = load_json(args.analysis_all_time, "all-time analysis")
        all_time_data = build_data(all_time_analysis, args.year,
                                   args.all_time_total_sent, show_people=show_people)

    # Read the design files (source of truth for the look).
    def read(name):
        with open(os.path.join(HERE, name), encoding="utf-8") as f:
            return f.read()

    try:
        ios = read("ios-frame.jsx")
        treatments = read("treatments.jsx")
        app = read("app.jsx")
        capture_runtime = read_capture_runtime()
    except FileNotFoundError as e:
        print(json.dumps({"error": "wrapped asset missing", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)

    datasets = {"past_year": data, "all_time": all_time_data}
    parts = [
        HEAD.format(year=args.year),
        f'<script>\n{escape_script(capture_runtime)}\n</script>',
        f'<script>window.WRAPPED_DATASETS = {safe_json(datasets)};</script>',
        f'<script type="text/babel">\n{ios}\n</script>',
        f'<script type="text/babel">\n{treatments}\n</script>',
        f'<script type="text/babel">\n{app}\n</script>',
        "</body>\n</html>\n",
    ]
    html = "\n".join(parts)

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(html)

    print(json.dumps({
        "status": "ok",
        "output": args.output,
        "cards": data["cards"],
        "archetype": data["archetype"]["name"],
        "all_time_archetype": (all_time_data["archetype"]["name"] if all_time_data else None),
        "windows": ["past_year"] + (["all_time"] if all_time_data else []),
        "note": (None if args.total_sent else
                 "Volume card omitted (no --total-sent). Top People shows when analysis.json has top_people (suppress with --no-people)."),
    }, indent=2))


if __name__ == "__main__":
    main()
