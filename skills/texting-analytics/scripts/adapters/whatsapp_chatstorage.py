#!/usr/bin/env python3
"""WhatsApp adapter: official ChatStorage.sqlite -> normalized message export (contract v1.0).

This is service-specific work ONLY: retrieve + normalize WhatsApp's Core Data store
into the shared `normalized_messages` contract. Everything downstream (metrics, charts)
is platform-agnostic and never sees this file.

Metadata only: reads LENGTH(ZTEXT), never the message text. Opens the store read-only.
No Full Disk Access needed (the WhatsApp group container is POSIX-readable).
"""
import argparse, json, os, sqlite3, sys, time

APPLE_EPOCH = 978307200  # seconds between the unix epoch (1970) and the Core Data epoch (2001)
DEFAULT_DB = os.path.expanduser(
    "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
)
# WhatsApp ZMESSAGETYPE: 0 = text. The rest are media/contact/location/doc/etc.
# System notices, edits, and reactions are not reliably distinguishable here, so they
# fall through to "other" (a known per-adapter fidelity gap, documented in the skill).
MEDIA_TYPES = {1, 2, 3, 4, 5, 8, 9, 11, 13}


def kind_for(mtype):
    if mtype == 0:
        return "text"
    if mtype in MEDIA_TYPES:
        return "media"
    return "other"


def norm_jid(jid):
    """JID -> normalized sender_key. Phone JIDs become +<E.164-ish>; others pass through."""
    if not jid:
        return None
    local = jid.split("@", 1)[0]
    return "+" + local if local.isdigit() else jid


def cd_to_ms(zdate):
    if zdate is None:
        return None
    return int(round((zdate + APPLE_EPOCH) * 1000))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--since-days", type=int, default=730, help="lookback; clamped to the 2yr ceiling")
    ap.add_argument("--max-events", type=int, default=500_000,
                    help="hard cap on exported events; newest rows win, output marks truncated=true")
    ap.add_argument("--output", default="-")
    a = ap.parse_args()

    since_days = min(a.since_days, 730)  # honor the contract's 2-year ceiling
    until_ms = int(time.time() * 1000)
    since_ms = until_ms - since_days * 86400 * 1000
    since_cd = since_ms / 1000.0 - APPLE_EPOCH  # Core Data seconds

    con = sqlite3.connect(f"file:{a.db}?mode=ro&immutable=1", uri=True)
    con.row_factory = sqlite3.Row

    threads, pk_to_thread = [], {}
    for r in con.execute(
        "SELECT Z_PK, ZSESSIONTYPE, ZCONTACTJID, ZPARTNERNAME, ZLASTMESSAGEDATE FROM ZWACHATSESSION"
    ):
        is_group = (r["ZSESSIONTYPE"] == 1)
        jid = r["ZCONTACTJID"] or f"pk{r['Z_PK']}"
        tid = f"whatsapp:{jid}"
        pk_to_thread[r["Z_PK"]] = (tid, is_group, jid)
        threads.append({
            "platform": "whatsapp",
            "thread_id": tid,
            "is_group": is_group,
            "participant_count": None if is_group else 2,
            "display_name": r["ZPARTNERNAME"],
            "last_event_ts_ms": cd_to_ms(r["ZLASTMESSAGEDATE"]),
        })

    events = []
    for r in con.execute(
        """SELECT ZISFROMME, ZMESSAGEDATE, ZMESSAGETYPE, ZCHATSESSION, ZFROMJID,
                  ZSTANZAID, Z_PK, LENGTH(ZTEXT) AS TLEN
           FROM ZWAMESSAGE
           WHERE ZMESSAGEDATE >= ? AND ZCHATSESSION IS NOT NULL
           ORDER BY ZMESSAGEDATE DESC
           LIMIT ?""",
        (since_cd, a.max_events),
    ):
        sess = pk_to_thread.get(r["ZCHATSESSION"])
        if not sess:
            continue
        tid, is_group, jid = sess
        from_me = bool(r["ZISFROMME"])
        if from_me:
            sender = None
        elif is_group:
            sender = norm_jid(r["ZFROMJID"])
        else:
            sender = norm_jid(jid)
        events.append({
            "platform": "whatsapp",
            "thread_id": tid,
            "event_id": f"whatsapp:{r['ZSTANZAID'] or ('pk' + str(r['Z_PK']))}",
            "sender_key": sender,
            "from_me": from_me,
            "ts_ms": cd_to_ms(r["ZMESSAGEDATE"]),
            "kind": kind_for(r["ZMESSAGETYPE"]),
            "text_len": r["TLEN"],
        })
    con.close()

    out = {
        "schema_version": "1.0",
        "source_platform": "whatsapp",
        "window": {"since_ms": since_ms, "until_ms": until_ms},
        "generated_at_ms": until_ms,
        "truncated": len(events) >= a.max_events,
        "threads": threads,
        "events": events,
    }
    payload = json.dumps(out, indent=2)
    if a.output == "-":
        print(payload)
    else:
        with open(a.output, "w") as f:
            f.write(payload)
    sys.stderr.write(f"[whatsapp_chatstorage] {len(threads)} threads, {len(events)} events\n")


if __name__ == "__main__":
    main()
