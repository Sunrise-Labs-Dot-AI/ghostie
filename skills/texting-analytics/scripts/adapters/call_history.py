#!/usr/bin/env python3
"""Call-history adapter: macOS CallHistory.storedata -> normalized contract.

Calls are relationship events too: emitted as kind="call", platform="call", with
duration_s + answered. FaceTime is always logged; regular phone calls only if
Continuity call-relay synced them to this Mac (so phone coverage can be partial).
FDA-protected; opened read-only + immutable. Metadata only (no audio, obviously).
"""
import argparse, json, os, sqlite3, sys, time

APPLE_EPOCH = 978307200
DEFAULT_DB = os.path.expanduser("~/Library/Application Support/CallHistoryDB/CallHistory.storedata")


def norm_addr(addr):
    if not addr:
        return None
    a = addr.strip()
    if "@" in a:
        return a.lower()
    d = "".join(c for c in a if c.isdigit())
    return "+" + d if d else None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--output", default="-")
    a = ap.parse_args()
    until_ms = int(time.time() * 1000)

    con = sqlite3.connect(f"file:{a.db}?mode=ro&immutable=1", uri=True)
    con.row_factory = sqlite3.Row
    threads, events = {}, []
    for r in con.execute(
        "SELECT ZADDRESS, ZDATE, ZDURATION, ZORIGINATED, ZANSWERED, ZUNIQUE_ID, Z_PK FROM ZCALLRECORD"
    ):
        sk = norm_addr(r["ZADDRESS"])
        if not sk:
            continue
        tid = f"call:{sk}"
        threads.setdefault(tid, {"platform": "call", "thread_id": tid, "is_group": False,
                                 "participant_count": 2, "display_name": None, "last_event_ts_ms": None})
        events.append({
            "platform": "call", "thread_id": tid,
            "event_id": f"call:{r['ZUNIQUE_ID'] or ('pk' + str(r['Z_PK']))}",
            "sender_key": sk,                       # counterparty either direction; from_me carries direction
            "from_me": bool(r["ZORIGINATED"]),
            "ts_ms": int(round((r["ZDATE"] + APPLE_EPOCH) * 1000)),
            "kind": "call", "text_len": None,
            "duration_s": round(r["ZDURATION"] or 0), "answered": bool(r["ZANSWERED"]),
        })
    con.close()
    last = {}
    for e in events:
        last[e["thread_id"]] = max(last.get(e["thread_id"], 0), e["ts_ms"])
    for t in threads.values():
        t["last_event_ts_ms"] = last.get(t["thread_id"])

    out = {"schema_version": "1.0", "source_platform": "call",
           "window": {"since_ms": 0, "until_ms": until_ms}, "generated_at_ms": until_ms,
           "truncated": False, "threads": list(threads.values()), "events": events}
    payload = json.dumps(out)
    print(payload) if a.output == "-" else open(a.output, "w").write(payload)
    sys.stderr.write(f"[call_history] {len(threads)} call-contacts, {len(events)} calls\n")


if __name__ == "__main__":
    main()
