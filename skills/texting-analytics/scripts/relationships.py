#!/usr/bin/env python3
"""Friendship-graph analysis over the normalized contract.

Generalized core (no service knowledge): closeness ranking ("who am I close with"),
year-over-year change (risers / faders), and a reconnect list ("who do I owe a check-in").
Optionally renders a social graph (networkx) and labels nodes from a contacts map.
"""
import argparse, json, math, os, statistics, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze import business_thread_ids, SUBSTANTIVE  # reuse the shared primitives

DAY = 86400 * 1000


def load(paths):
    threads, events = {}, []
    for pth in paths:
        d = json.load(open(pth))
        for t in d["threads"]:
            threads[t["thread_id"]] = t
        events += d["events"]
    return threads, events


def norm_for_contacts(sk):
    if not sk:
        return None
    if "@" in sk:
        return sk.strip().lower()
    digits = "".join(c for c in sk if c.isdigit())
    return digits[-10:] if len(digits) >= 10 else (digits or None)


def closeness(p, now):
    total = p["sent"] + p["recv"]
    if total == 0:
        return 0.0
    recip = 1 - abs(p["sent"] - p["recv"]) / total           # 1 = perfectly two-way
    recency = math.exp(-((now - p["last"]) / DAY) / 120.0)    # decays over ~months
    span_weeks = max(1.0, (p["last"] - p["first"]) / (7 * DAY))
    freq = total / span_weeks
    return round(math.log1p(total) * (0.5 + 0.5 * recip) * recency * math.log1p(freq), 3)


def trajectory(p, now):
    """Cadence vs the relationship's OWN baseline. recent-90d rate against lifetime rate."""
    total = p["sent"] + p["recv"]
    span_days = max(1.0, (p["last"] - p["first"]) / DAY)
    baseline90 = total / span_days * 90.0
    ratio = round(p["r90"] / baseline90, 2) if baseline90 > 0 else 0.0
    last_days = (now - p["last"]) / DAY
    if total < 40 or span_days < 120:
        return "light", ratio                       # too little history to judge
    if last_days >= 150 and p["r90"] == 0:
        return "dormant", ratio
    if ratio < 0.45:
        return "drifting", ratio                     # still alive, cadence decaying
    if ratio > 1.8:
        return "intensifying", ratio
    return "steady", ratio


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--events", nargs="+", required=True, help="one or more normalized exports (text, calls)")
    ap.add_argument("--contacts", default=None)
    ap.add_argument("--output", required=True)
    ap.add_argument("--graph", default=None)
    a = ap.parse_args()

    threads, events = load(a.events)
    names = json.load(open(a.contacts)) if a.contacts else {}
    biz = business_thread_ids(threads, events)
    now = max((e["ts_ms"] for e in events), default=int(time.time() * 1000))
    year = now - 365 * DAY

    def _entry(sk):
        k = norm_for_contacts(sk)
        return names.get(k) if k else None

    def nm(sk):
        v = _entry(sk)
        return v["name"] if isinstance(v, dict) else v

    def org(sk):
        v = _entry(sk)
        return v.get("org") if isinstance(v, dict) else None

    # Aggregate per 1:1 counterparty (exclude business + group threads).
    th_events, cp = {}, {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or t["is_group"] or t["thread_id"] in biz:
            continue
        th_events.setdefault(e["thread_id"], []).append(e)
        if not e["from_me"] and e.get("sender_key"):
            cp.setdefault(e["thread_id"], e["sender_key"])

    people = {}
    for tid, sk in cp.items():
        sub = sorted((e for e in th_events.get(tid, []) if e["kind"] in SUBSTANTIVE), key=lambda e: e["ts_ms"])
        if not sub:
            continue
        p = people.setdefault(sk, dict(sent=0, recv=0, first=None, last=0, recent=0, older=0,
                                       r90=0, chars=0, chars_n=0, lat=[]))
        pending_inbound = []
        for e in sub:
            ts = e["ts_ms"]
            p["first"] = ts if p["first"] is None else min(p["first"], ts)
            p["last"] = max(p["last"], ts)
            if e["from_me"]:
                p["sent"] += 1
            else:
                p["recv"] += 1
            p["recent" if ts >= year else "older"] += 1
            if ts >= now - 90 * DAY:
                p["r90"] += 1
            if e.get("text_len"):
                p["chars"] += e["text_len"]; p["chars_n"] += 1
            if not e["from_me"]:
                pending_inbound.append(ts)
            else:
                for inbound_ts in pending_inbound:
                    d = (ts - inbound_ts) / 60000.0
                    if 0 < d < 960:
                        p["lat"].append(d)
                pending_inbound = []

    # Group co-activity: a silent 1:1 isn't a silent relationship if you're both
    # active in shared group threads (e.g. someone in your family/couple group chat).
    gact = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if not t or not t["is_group"] or t["thread_id"] in biz or e["from_me"] or not e.get("sender_key"):
            continue
        g = gact.setdefault(e["sender_key"], dict(msgs=0, last=0, threads=set()))
        g["msgs"] += 1; g["last"] = max(g["last"], e["ts_ms"]); g["threads"].add(e["thread_id"])

    # Calls are another channel: you call your close people, and a recent call means
    # the relationship isn't owed even if the texts went quiet.
    cact = {}
    for e in events:
        if e.get("kind") != "call" or not e.get("sender_key"):
            continue
        c = cact.setdefault(e["sender_key"], dict(calls=0, answered=0, last=0, dur=0))
        c["calls"] += 1; c["last"] = max(c["last"], e["ts_ms"]); c["dur"] += e.get("duration_s") or 0
        if e.get("answered"):
            c["answered"] += 1

    rows = []
    for sk, p in people.items():
        total = p["sent"] + p["recv"]
        traj, ratio = trajectory(p, now)
        g = gact.get(sk); c = cact.get(sk)
        last1 = round((now - p["last"]) / DAY)
        glast = round((now - g["last"]) / DAY) if g else None
        clast = round((now - c["last"]) / DAY) if c else None
        eff = min([d for d in (last1, glast, clast) if d is not None])  # last contact on ANY channel
        rows.append(dict(
            key=sk, name=nm(sk), org=org(sk), total=total, sent=p["sent"], recv=p["recv"],
            reciprocity=round(1 - abs(p["sent"] - p["recv"]) / total, 2) if total else 0,
            last_days=last1, eff_last_days=eff,
            group_msgs=g["msgs"] if g else 0, group_threads=len(g["threads"]) if g else 0,
            group_last_days=glast,
            calls=c["calls"] if c else 0, calls_answered=c["answered"] if c else 0,
            call_last_days=clast, call_mins=round(c["dur"] / 60) if c else 0,
            recent=p["recent"], older=p["older"], delta=p["recent"] - p["older"],
            trajectory=traj, cadence_ratio=ratio,
            avg_chars=round(p["chars"] / p["chars_n"]) if p["chars_n"] else None,
            median_reply_min=round(statistics.median(p["lat"]), 1) if p["lat"] else None,
            closeness=closeness(p, now),
        ))
    rows.sort(key=lambda r: r["closeness"], reverse=True)

    # eff_last_days gates by last contact on ANY channel, so group-active people drop off.
    drifting = sorted([r for r in rows if r["trajectory"] == "drifting" and r["eff_last_days"] >= 30],
                      key=lambda r: r["closeness"], reverse=True)[:10]
    intensifying = sorted([r for r in rows if r["trajectory"] == "intensifying"],
                          key=lambda r: r["closeness"], reverse=True)[:10]
    dormant = sorted([r for r in rows if r["trajectory"] == "dormant" and r["eff_last_days"] >= 120],
                     key=lambda r: r["closeness"], reverse=True)[:12]
    out = dict(n_people=len(rows), top_close=rows[:20],
               drifting=drifting, intensifying=intensifying, dormant=dormant)
    json.dump(out, open(a.output, "w"), indent=2, ensure_ascii=False)
    named = sum(1 for r in rows if r["name"])
    print(f"[relationships] {len(rows)} 1:1 people ({named} named) | "
          f"top: {[r['name'] or r['key'] for r in rows[:5]]}")
    if a.graph:
        render_graph(threads, events, biz, names, rows, a.graph)


def render_graph(threads, events, biz, names, rows, path):
    try:
        import matplotlib; matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import networkx as nx
    except Exception as e:
        sys.stderr.write(f"[graph] skipped (missing dep): {e}\n"); return
    from itertools import combinations

    def nm(sk):
        k = norm_for_contacts(sk)
        v = names.get(k) if k else None
        if isinstance(v, dict):
            v = v.get("name")
        return v or "?"

    top = {r["key"]: r for r in rows[:35]}
    G = nx.Graph()
    for k, r in top.items():
        G.add_node(k, w=r["closeness"])
    members = {}
    for e in events:
        t = threads.get(e["thread_id"])
        if t and t["is_group"] and t["thread_id"] not in biz and not e["from_me"] and e.get("sender_key"):
            members.setdefault(e["thread_id"], set()).add(e["sender_key"])
    for mem in members.values():
        for x, y in combinations(sorted(m for m in mem if m in top), 2):
            if G.has_edge(x, y):
                G[x][y]["weight"] += 1
            else:
                G.add_edge(x, y, weight=1)
    try:
        from networkx.algorithms.community import greedy_modularity_communities
        comms = list(greedy_modularity_communities(G))
    except Exception:
        comms = [set(G.nodes())]
    color = {n: i for i, c in enumerate(comms) for n in c}

    pos = nx.spring_layout(G, seed=42, k=0.7)
    plt.figure(figsize=(15, 11))
    if G.number_of_edges():
        nx.draw_networkx_edges(G, pos, alpha=0.18,
                               width=[0.4 + 0.4 * G[u][v]["weight"] for u, v in G.edges()])
    nx.draw_networkx_nodes(G, pos, node_size=[400 + G.nodes[n]["w"] * 130 for n in G.nodes()],
                           node_color=[color.get(n, 0) for n in G.nodes()], cmap="tab20", alpha=0.9)
    nx.draw_networkx_labels(G, pos, {n: nm(n) for n in G.nodes()}, font_size=8)
    plt.axis("off")
    plt.title("Your friendship graph — node size = closeness, color = community (shared group chats)", fontsize=13)
    plt.tight_layout()
    plt.savefig(path, dpi=120, facecolor="white"); plt.close()
    sys.stderr.write(f"[graph] {G.number_of_nodes()} nodes, {G.number_of_edges()} edges -> {path}\n")


if __name__ == "__main__":
    main()
