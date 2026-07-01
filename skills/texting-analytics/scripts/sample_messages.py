#!/usr/bin/env python3
"""Harness step (b): sample a few readable messages per contact so the model can
classify the RELATIONSHIP (friend / family / partner / coworker / service / acquaintance).

Pulls a small random sample from each handle's 1:1 thread, both directions, from the
`text` column. Body content is used ONLY for one-shot classification, never stored or
dumped wholesale. (attributedBody-only threads sample thin; decoding that blob is a TODO.)
"""
import argparse, json, sqlite3
from collections import Counter, defaultdict


def decode_attributed_body(blob):
    """Extract plain text from chat.db's `attributedBody` (a streamtyped NSAttributedString
    archive). Heuristic: the body string follows the 'NSString' marker + a '+' + a length.
    ~99% of modern messages store their text here, not in the `text` column."""
    if not blob:
        return None
    try:
        i = blob.find(b"NSString")
        if i == -1:
            return None
        s = blob[i + 8:]
        p = s.find(b"+")
        if p == -1:
            return None
        s = s[p + 1:]
        n = s[0]
        if n == 0x81:
            n = int.from_bytes(s[1:3], "little"); s = s[3:]
        elif n == 0x82:
            n = int.from_bytes(s[1:5], "little"); s = s[5:]
        else:
            s = s[1:]
        return s[:n].decode("utf-8", "replace")
    except Exception:
        return None


def norm(h):
    if not h:
        return None
    if "@" in h:
        return h.strip().lower()
    d = "".join(c for c in h if c.isdigit())
    return d[-10:] if len(d) >= 10 else (d or None)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", required=True)
    ap.add_argument("--handles", required=True, help="comma-separated sender_keys")
    ap.add_argument("--n", type=int, default=12)
    ap.add_argument("--output", default="-")
    a = ap.parse_args()
    targets = [h for h in a.handles.split(",") if h]

    con = sqlite3.connect(f"file:{a.db}?mode=ro&immutable=1", uri=True)
    con.row_factory = sqlite3.Row

    hkey = defaultdict(list)
    for r in con.execute("SELECT ROWID, id FROM handle"):
        k = norm(r["id"])
        if k:
            hkey[k].append(r["ROWID"])
    handle_chats = defaultdict(set)
    chat_handle_n = Counter()
    for r in con.execute("SELECT chat_id, handle_id FROM chat_handle_join"):
        handle_chats[r["handle_id"]].add(r["chat_id"])
        chat_handle_n[r["chat_id"]] += 1

    out = {}
    for t in targets:
        rowids = hkey.get(norm(t), [])
        chats = {c for hr in rowids for c in handle_chats.get(hr, set()) if chat_handle_n[c] == 1}  # 1:1 only
        msgs = []
        if chats:
            ph = ",".join("?" * len(chats))
            rows = con.execute(
                f"""SELECT m.is_from_me AS fm, m.text AS t, m.attributedBody AS ab
                    FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    WHERE cmj.chat_id IN ({ph})
                      AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
                      AND COALESCE(m.associated_message_type, 0) = 0
                    ORDER BY RANDOM()
                    LIMIT ?""",
                (*tuple(chats), max(a.n * 3, a.n)))
            for r in rows:
                body = r["t"] or decode_attributed_body(r["ab"])
                if body and len(body.strip()) > 1:
                    msgs.append({"from_me": bool(r["fm"]), "text": body.strip()[:200]})
                if len(msgs) >= a.n:
                    break
        out[t] = {"sampled": len(msgs), "messages": msgs}
    con.close()

    payload = json.dumps(out, ensure_ascii=False, indent=2)
    print(payload) if a.output == "-" else open(a.output, "w").write(payload)


if __name__ == "__main__":
    main()
