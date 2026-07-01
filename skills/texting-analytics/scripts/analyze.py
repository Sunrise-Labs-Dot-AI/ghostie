#!/usr/bin/env python3
"""Generalized analytics core: normalized message export(s) -> analysis.json.

Platform-agnostic. Consumes ONLY the normalized_messages contract (v1.0) and knows
nothing about iMessage or WhatsApp. Accepts one or more exports and merges them, so a
cross-platform Wrapped is just `--input imessage.json whatsapp.json`.

Output matches the analysis.json schema that build_charts.py renders.
"""
import argparse, json, re, statistics, time

SUBSTANTIVE = {"text", "media"}
REPLY_CAP_MIN = 960  # 16h: longer gaps are conversation death, not a reply
TOLLFREE_NPAS = {"800", "833", "844", "855", "866", "877", "888"}


def counterparty_class(sender_key):
    """Body-free classification of a 1:1 counterparty from its normalized sender_key.
    Returns 'person' | 'shortcode' | 'tollfree' | 'alpha'. Business = the non-person ones.
    NOTE: the strongest business signal (not-in-contacts AND never-replied) needs an
    adapter-supplied `in_contacts` flag; this covers the pattern-detectable cases."""
    if not sender_key or "@" in sender_key:
        return "person"
    digits = sender_key.lstrip("+")
    if digits.isdigit():
        if 3 <= len(digits) <= 6:
            return "shortcode"
        npa = digits[1:4] if (len(digits) == 11 and digits[0] == "1") else digits[0:3]
        return "tollfree" if npa in TOLLFREE_NPAS else "person"
    if re.search("[A-Za-z]", sender_key):
        return "alpha"  # alphanumeric sender ID (AMAZON, Uber, VERIFY...)
    return "person"


def business_thread_ids(threads, events):
    """1:1 threads whose counterparty looks automated/business (pattern-based)."""
    counterparty = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or t["is_group"] or e["from_me"]:
            continue
        counterparty.setdefault(e["thread_id"], e.get("sender_key"))
    return {tid for tid, sk in counterparty.items()
            if counterparty_class(sk) != "person"}


def size_bucket(participant_count, large_min=6):
    if participant_count is None:
        return "unknown"
    if participant_count <= 2:
        return "one_to_one"
    return "small" if participant_count < large_min else "large"


def load(paths):
    threads, events = {}, []
    for p in paths:
        d = json.load(open(p))
        for t in d["threads"]:
            threads[t["thread_id"]] = t
        events.extend(d["events"])
    return threads, events


def latency_block(threads, events):
    """How fast the user replies, over 1:1 threads, substantive messages only."""
    by_thread = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or t["is_group"] or e["kind"] not in SUBSTANTIVE:
            continue
        by_thread.setdefault(e["thread_id"], []).append(e)
    deltas, tcount = [], 0
    for evs in by_thread.values():
        evs.sort(key=lambda e: e["ts_ms"])
        pending_inbound = []
        had = False
        for e in evs:
            if not e["from_me"]:
                pending_inbound.append(e["ts_ms"])
                continue
            for inbound_ts in pending_inbound:
                d = (e["ts_ms"] - inbound_ts) / 60000.0
                if 0 < d < REPLY_CAP_MIN:
                    deltas.append(d)
                    had = True
            pending_inbound = []
        if had:
            tcount += 1
    n = len(deltas)
    pct = lambda thr: round(100 * sum(1 for d in deltas if d <= thr) / n, 1) if n else 0
    return {
        "total_reply_pairs": n,
        "pct_within_5min": pct(5), "pct_within_30min": pct(30),
        "pct_within_1hr": pct(60), "pct_within_4hr": pct(240),
        "mean_minutes": round(statistics.mean(deltas), 1) if n else 0,
        "median_minutes": round(statistics.median(deltas), 1) if n else 0,
        "thread_count": tcount, "window_label": "past 24 months",
    }


def ball_block(threads, events, until_ms):
    """Ball-in-your-court: threads where YOU had the last word — i.e., you
    were the one who fired off the most recent shot, and it's now their move.
    SUBSTANTIVE only: a 👍 tapback isn't "ending the thread" — the message
    BEFORE the tapback is what really sits at the end. (Earlier versions
    counted the inverse — threads where THEY sent last and you owe a reply —
    but per James's framing the card name takes the "balls you served"
    reading: high % = you've done your part, low % = you owe replies in
    most of your threads.)"""
    last = {}
    for e in events:
        if e.get("kind") not in SUBSTANTIVE:
            continue
        cur = last.get(e["thread_id"])
        if cur is None or e["ts_ms"] > cur["ts_ms"]:
            last[e["thread_id"]] = e
    recent = sorted(last.items(), key=lambda kv: kv[1]["ts_ms"], reverse=True)[:100]
    sampled = len(recent)
    bic = sum(1 for _, e in recent if e["from_me"])
    live = sum(1 for _, e in recent if (until_ms - e["ts_ms"]) <= 30 * 86400 * 1000)
    return {
        "total_threads_sampled": sampled,
        "threads_with_ball_in_court": bic,
        "pct_ball_in_court": round(100 * bic / sampled, 1) if sampled else 0,
        "live_conversations_estimate": live,
        "snapshot_label": "now",
    }


def group_block(threads, events, min_msgs=20, large_min=6):
    """Group-thread contribution stats. Split SUBSTANTIVE messages (text +
    media) from REACTIONS so the user_contribution_pct reads as "what share
    of real messages did you send" — not inflated by tapback noise. Reaction
    counts still tracked separately for the reaction-rate signal."""
    groups = {tid: t for tid, t in threads.items() if t["is_group"]}
    per = {}
    for e in events:
        if e["thread_id"] not in groups:
            continue
        d = per.setdefault(e["thread_id"], dict(total=0, user=0, user_react=0, peer=0, peer_react=0))
        react = e["kind"] == "reaction"
        substantive = e["kind"] in SUBSTANTIVE
        # Skip events that are neither substantive nor reactions (system
        # notices, deletes, etc. — they shouldn't appear in any group stat).
        if not (react or substantive):
            continue
        d["total"] += int(substantive)
        if e["from_me"]:
            if substantive:
                d["user"] += 1
            if react:
                d["user_react"] += 1
        else:
            if substantive:
                d["peer"] += 1
            if react:
                d["peer_react"] += 1
    # Keep only groups with real activity; 1-2 message "groups" are noise.
    per = {tid: d for tid, d in per.items() if d["total"] >= min_msgs}
    tot = sum(d["total"] for d in per.values())
    um = sum(d["user"] for d in per.values())
    ur = sum(d["user_react"] for d in per.values())
    pm = sum(d["peer"] for d in per.values())
    pr = sum(d["peer_react"] for d in per.values())
    per_thread, silent, mostly = [], 0, 0
    buckets = {}  # size bucket -> rollup
    for tid, d in per.items():
        pc = groups[tid].get("participant_count")
        bucket = size_bucket(pc, large_min)
        b = buckets.setdefault(bucket, dict(groups=0, total=0, user=0))
        b["groups"] += 1; b["total"] += d["total"]; b["user"] += d["user"]
        if d["user"] == 0 and d["user_react"] == 0:
            silent += 1
        # "mostly reactions" — over half your activity in the group is
        # tapbacks, not real messages.
        u_total = d["user"] + d["user_react"]
        if u_total and d["user_react"] / u_total >= 0.5:
            mostly += 1
        upct = round(100 * d["user"] / d["total"], 1) if d["total"] else 0
        # fair-share ratio: your share vs an even split (1/N). 1.0 = even, <1 = lurking.
        fair = round(upct / (100.0 / pc), 2) if (pc and pc > 1 and d["total"]) else None
        per_thread.append({
            "thread_label": groups[tid].get("display_name") or tid,
            "participant_count": pc, "size": bucket,
            "total": d["total"], "user_count": d["user"],
            "user_pct": upct, "fair_share_ratio": fair,
            "user_reaction_pct": round(100 * d["user_react"] / (d["user"] + d["user_react"]), 1) if (d["user"] + d["user_react"]) else 0,
        })
    # Worst offender computed BEFORE per_thread is truncated to top-12 —
    # otherwise silent groups (the most damning ones) get sorted to the
    # bottom and never reach derive_worst_ghost. Prefer threads the user
    # sent 0 to; among those, the largest. Else the largest thread with
    # the lowest user share.
    if per_thread:
        zero = [t for t in per_thread if t.get("user_count", 1) == 0]
        pool = zero or per_thread
        worst_offender = max(pool, key=lambda t: (t.get("total", 0), -t.get("user_count", 0)))
    else:
        worst_offender = None
    per_thread.sort(key=lambda x: x["user_pct"], reverse=True)
    per_thread = per_thread[:12]  # chart readability; aggregates below still cover all groups
    by_size = {b: {"groups": v["groups"],
                   "contribution_pct": round(100 * v["user"] / v["total"], 1) if v["total"] else 0}
               for b, v in buckets.items()}
    return {
        "total_groups_analyzed": len(per),
        "total_messages_in_groups": tot,
        "user_messages_in_groups": um,
        "user_contribution_pct": round(100 * um / tot, 1) if tot else 0,
        # Reaction rate = reactions / (substantive + reactions). Was previously
        # reactions / substantive (could exceed 100 once reactions stopped
        # being summed into the denominator).
        "user_reaction_rate_pct": round(100 * ur / (um + ur), 1) if (um + ur) else 0,
        "peer_reaction_rate_pct": round(100 * pr / (pm + pr), 1) if (pm + pr) else 0,
        "groups_where_user_silent": silent,
        "groups_mostly_reactions": mostly,
        "by_size": by_size,
        "per_thread": per_thread,
        "worst_offender": worst_offender,
    }


def top_people_block(threads, events, limit=10):
    """1:1 people you SENT the most substantive messages to, across all
    platforms (events are already merged). Outbound only — counting both
    directions would double every relationship and obscure asymmetries (a
    wife who replies as much as you ranks the same as a chatty colleague
    who replies twice as much). SUBSTANTIVE kinds only — tapbacks/reactions
    ("Liked", 👍 reactions) and chat-system events don't get counted as
    messages sent (they inflated couple/spouse rows ~15%). Name comes from
    the thread's display_name (MCP resolves real contact names in
    production; the harness may show a handle). For the user's own view —
    keep it out of any shared composite."""
    counts = {}
    for e in events:
        if not e.get("from_me"):
            continue
        if e.get("kind") not in SUBSTANTIVE:
            continue
        t = threads.get(e["thread_id"])
        if not t or t["is_group"]:
            continue
        counts[e["thread_id"]] = counts.get(e["thread_id"], 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:limit]
    return [{"name": threads.get(tid, {}).get("display_name") or tid, "count": c}
            for tid, c in ranked]


def talk_listen_block(threads, events, person_limit=8):
    """Talker-or-listener: how do the user's outbound words compare to the
    inbound words across 1:1 threads? Surfaces aggregate (do you talk or
    listen more overall?) and per-relationship outliers (Most balanced /
    You talk way more / You mostly listen). Words = chars/5; metadata only
    (text LENGTH never the body)."""
    sent, recv = {}, {}
    for e in events:
        if e.get("kind") not in SUBSTANTIVE:
            continue
        t = threads.get(e["thread_id"])
        if not t or t["is_group"]:
            continue
        n = e.get("text_len") or 0
        if n <= 0:
            continue
        bucket = sent if e.get("from_me") else recv
        bucket[e["thread_id"]] = bucket.get(e["thread_id"], 0) + n
    # Per-thread snapshots — only count threads with both sides talking to
    # avoid noise from one-shot promos or threads where one side never
    # responded (often a misclassified business contact).
    per_thread = []
    for tid in set(list(sent) + list(recv)):
        s, r = sent.get(tid, 0), recv.get(tid, 0)
        if s + r < 200:  # both-sides minimum (~40 words exchanged total)
            continue
        if s == 0 or r == 0:
            continue
        per_thread.append({
            "name": threads.get(tid, {}).get("display_name") or tid,
            "you_words": int(round(s / 5)),
            "them_words": int(round(r / 5)),
            "your_share_pct": round(100 * s / (s + r), 1),
        })
    total_sent_words = int(round(sum(sent.values()) / 5))
    total_recv_words = int(round(sum(recv.values()) / 5))
    overall_pct = (round(100 * sum(sent.values()) / (sum(sent.values()) + sum(recv.values())), 1)
                   if (sum(sent.values()) + sum(recv.values())) > 0 else 50.0)
    # Sort by you_words desc to take the most informative top-N (heavy
    # relationships drive the ranking; tiny threads with extreme ratios
    # are filtered above).
    per_thread.sort(key=lambda x: -(x["you_words"] + x["them_words"]))
    top = per_thread[:person_limit]
    # Highlights must be materially distinct. A 50.8% thread can be "most
    # balanced" but should not also be "you talk more" just because every
    # relationship is balanced. Use material thresholds and avoid reusing the
    # same conversation across categories when enough candidates exist.
    used = set()
    most_balanced = min(top, key=lambda p: abs(p["your_share_pct"] - 50)) if top else None
    if most_balanced:
        used.add(most_balanced["name"])

    def pick_material(pred, key, reverse=False):
        pool = [p for p in top if pred(p) and p["name"] not in used]
        if not pool:
            return None
        picked = sorted(pool, key=key, reverse=reverse)[0]
        used.add(picked["name"])
        return picked

    most_you_talk = pick_material(lambda p: p["your_share_pct"] >= 60, lambda p: p["your_share_pct"], True)
    most_you_listen = pick_material(lambda p: p["your_share_pct"] <= 40, lambda p: p["your_share_pct"])
    return {
        "you_words": total_sent_words,
        "them_words": total_recv_words,
        "your_share_pct": overall_pct,
        "per_thread": top,
        "highlights": {
            "most_balanced": most_balanced,
            "most_you_talk": most_you_talk,
            "most_you_listen": most_you_listen,
        },
    }


def top_people_l30_block(threads, events, until_ms, limit=10):
    """Same shape as top_people_block but restricted to the LAST 30 DAYS from
    `until_ms`. Pairs with the past-year top_people to show what's gone hot/
    cold most recently — Wrapped's people slice gains a 'right now' read,
    not just an annual aggregate."""
    since = until_ms - 30 * 86400 * 1000
    counts = {}
    for e in events:
        if not e.get("from_me"):
            continue
        if e.get("kind") not in SUBSTANTIVE:
            continue
        if e["ts_ms"] < since:
            continue
        t = threads.get(e["thread_id"])
        if not t or t["is_group"]:
            continue
        counts[e["thread_id"]] = counts.get(e["thread_id"], 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:limit]
    return [{"name": threads.get(tid, {}).get("display_name") or tid, "count": c}
            for tid, c in ranked]


def top_people_by_chars_block(threads, events, limit=10):
    """Same 1:1 ranking but summed by character volume (text_len) of messages
    YOU sent — surfaces the people you actually wrote PARAGRAPHS to vs. the
    rapid-fire short-text relationships. Outbound only, same reasoning as
    top_people_block. Metadata-only: we only have the per-message text LENGTH,
    never the body."""
    chars = {}
    for e in events:
        if not e.get("from_me"):
            continue
        if e.get("kind") not in SUBSTANTIVE:
            continue
        t = threads.get(e["thread_id"])
        if not t or t["is_group"]:
            continue
        n = e.get("text_len") or 0
        if n <= 0:
            continue
        chars[e["thread_id"]] = chars.get(e["thread_id"], 0) + n
    ranked = sorted(chars.items(), key=lambda kv: kv[1], reverse=True)[:limit]
    return [{"name": threads.get(tid, {}).get("display_name") or tid, "chars": c}
            for tid, c in ranked]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", nargs="+", required=True, help="one or more normalized exports")
    ap.add_argument("--output", required=True)
    ap.add_argument("--large-min", type=int, default=6, help="participant count at which a group is 'large'")
    ap.add_argument("--keep-business", action="store_true", help="don't filter automated/business 1:1 threads")
    ap.add_argument("--window-days", type=int, default=365,
                    help="bound analysis to the last N days from the newest event (default: 365 for 'Wrapped'). "
                         "Pass --window-days 0 for all-time.")
    a = ap.parse_args()
    threads, events = load(a.input)
    biz = set() if a.keep_business else business_thread_ids(threads, events)
    if biz:
        events = [e for e in events if e["thread_id"] not in biz]
        threads = {tid: t for tid, t in threads.items() if tid not in biz}
    # Bound to a window so a Wrapped reads as a year-in-review, not a
    # full-history accumulator (4 years of texts to a spouse can easily hit
    # 12k+ — a Wrapped should be the LAST YEAR's view by default).
    until_ms = max((e["ts_ms"] for e in events), default=int(time.time() * 1000))
    since_ms = 0 if a.window_days <= 0 else (until_ms - a.window_days * 86400 * 1000)
    if since_ms > 0:
        events_full = events  # ball_block stays on full timeline (snapshot of CURRENT inboxes)
        events = [e for e in events if e["ts_ms"] >= since_ms]
    else:
        events_full = events
    out = {
        "latency": latency_block(threads, events),
        # ball_in_court is a CURRENT snapshot ("which threads is the ball
        # parked in right now?") — uses full event history so threads that
        # last got a reply 14 months ago still surface.
        "ball_in_court": ball_block(threads, events_full, until_ms),
        "group_contribution": group_block(threads, events, large_min=a.large_min),
        "top_people": top_people_block(threads, events),
        # L30d snapshot uses the windowed event stream too so businesses are
        # already filtered; using events_full would re-include them.
        "top_people_l30": top_people_l30_block(threads, events, until_ms),
        "top_people_by_chars": top_people_by_chars_block(threads, events),
        "talk_listen": talk_listen_block(threads, events),
        "filters": {
            "excluded_business_1to1_threads": len(biz),
            "window_days": a.window_days,
            "since_ts_ms": since_ms,
            "until_ts_ms": until_ms,
        },
    }
    json.dump(out, open(a.output, "w"), indent=2)
    print(f"[analyze] threads={len(threads)} events={len(events)} window={a.window_days}d biz_excluded={len(biz)} -> {a.output}")


if __name__ == "__main__":
    main()
