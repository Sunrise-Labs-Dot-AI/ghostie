#!/usr/bin/env python3
"""synthetic_chatdb.py — fabricate chat.db-shaped sqlite fixtures for eval.

Builds a minimal-but-faithful iMessage chat.db (chat / handle / message /
chat_handle_join / chat_message_join, Apple-epoch nanosecond dates) for a
roster of synthetic PERSONAS — fast replier, ghost, group MVP, night owl,
emoji maximalist, and friends. The eval (test_synthetic_eval.py) runs the REAL
metric pipeline (adapters/imessage_chatdb.py → analyze.py → emoji_stats.py →
build_wrapped.derive_archetype) over each fixture and asserts the expected
archetype.

EVERYTHING here is synthetic: invented handles, invented names, a fixed
template corpus for message bodies. NO real data, ever. Deterministic by
construction: all scheduling is pure arithmetic off a fixed anchor timestamp
(no randomness at all), so two runs produce identical databases.

Persona config knobs (see PERSONAS):
  reply_deltas      — multiset of the user's 1:1 reply latencies, in minutes.
                      Each delta becomes one inbound→outbound pair; analyze.py's
                      latency block recovers exactly this distribution.
  n_dm              — number of 1:1 threads (deltas are spread round-robin).
  dm_user_last      — how many 1:1 threads end with the USER's message
                      (drives ball-in-court, together with group last-senders).
  groups            — list of (name, members, peer_msgs, user_msgs, user_last).
                      peer+user msgs ≥ 20 so analyze counts the group.
  emoji_every       — every Nth outbound text gets an emoji (None = never).
  slang             — {token: count} standalone outbound messages, exercising
                      the guarded slang-cohort counters.
  night_owl         — schedule all traffic between 2–4 AM instead of midday.
"""

import os
import sqlite3

APPLE_EPOCH = 978307200
# Fixed anchor: 2026-05-01 12:00:00 UTC, expressed in unix seconds. All events
# are scheduled BACKWARD from here so "past year" windows are stable.
ANCHOR_UNIX_S = 1777636800  # 2026-05-01 12:00:00 UTC

# Synthetic body corpus — template lines only, cycled deterministically.
SYNTH_BODIES = [
    "synthetic fixture line one",
    "synthetic fixture line two",
    "synthetic fixture line three",
    "ok",
    "sounds good",
    "synthetic fixture line four",
    "on my way",
    "synthetic fixture line five",
]

SYNTH_CONTACT_POOL = [
    "+15125550101", "+15125550102", "+15125550103", "+15125550104",
    "+15125550105", "+15125550106", "+15125550107", "+15125550108",
    "+15125550109", "+15125550110", "+15125550111", "+15125550112",
    "+15125550113", "+15125550114", "+15125550115", "+15125550116",
    "+15125550117", "+15125550118", "+15125550119", "+15125550120",
    "+15125550121", "+15125550122", "+15125550123", "+15125550124",
]


def _g(name, members, peer_msgs, user_msgs, user_last):
    return {"name": name, "members": members, "peer_msgs": peer_msgs,
            "user_msgs": user_msgs, "user_last": user_last}


# Default group roster reused by personas that aren't group-defined: enough
# groups for groups_known (>=3) with a mid-range user share (~10%).
def _default_groups(user_share_msgs=6, user_last_groups=0):
    return [
        _g("synthetic crew a", 5, 54, user_share_msgs, user_last_groups >= 1),
        _g("synthetic crew b", 4, 54, user_share_msgs, user_last_groups >= 2),
        _g("synthetic crew c", 6, 54, user_share_msgs, False),
        _g("synthetic crew d", 5, 54, user_share_msgs, False),
    ]


PERSONAS = {
    # median 1, fast 100% → The Lightning Round
    "lightning_larry": {
        "reply_deltas": [0.5] * 12 + [1.0] * 18 + [1.5] * 10,
        "n_dm": 16, "dm_user_last": 8,
        "groups": _default_groups(),
        "emoji_every": 4,
        "expected": "The Lightning Round",
    },
    # ball ~12% → Left-on-Read Royalty (you owe replies almost everywhere)
    "royal_rhea": {
        "reply_deltas": [15.0] * 10 + [20.0] * 16 + [30.0] * 10,
        "n_dm": 21, "dm_user_last": 3,
        "groups": _default_groups(),  # 4 groups, none user-last → 3/25 = 12%
        "emoji_every": 4,
        "expected": "Left-on-Read Royalty",
    },
    # ball ~88% → The Last Word
    "last_word_louise": {
        "reply_deltas": [8.0] * 12 + [10.0] * 16 + [12.0] * 10,
        "n_dm": 21, "dm_user_last": 20,
        "groups": _default_groups(user_share_msgs=6, user_last_groups=2),
        "emoji_every": 4,
        "expected": "The Last Word",
    },
    # group share <3%, silent in most groups → The Group Chat Ghost
    "ghost_gary": {
        "reply_deltas": [10.0] * 8 + [15.0] * 8,
        "n_dm": 10, "dm_user_last": 5,
        "groups": [
            _g("synthetic kayak crew", 6, 60, 3, False),
            _g("synthetic fantasy league", 8, 60, 0, False),
            _g("synthetic family thread", 5, 60, 0, False),
            _g("synthetic college chat", 7, 60, 0, False),
            _g("synthetic ski trip", 6, 60, 0, False),
            _g("synthetic book club", 5, 60, 0, False),
            _g("synthetic trivia team", 6, 60, 0, False),
            _g("synthetic neighbors", 4, 60, 0, False),
        ],
        "emoji_every": 4,
        "expected": "The Group Chat Ghost",
    },
    # group share ~50% → The Town Crier
    "crier_cathy": {
        "reply_deltas": [5.0] * 10 + [7.0] * 16 + [10.0] * 10,
        "n_dm": 16, "dm_user_last": 8,
        "groups": [
            _g("synthetic crew a", 5, 30, 30, True),
            _g("synthetic crew b", 4, 30, 30, True),
            _g("synthetic crew c", 6, 30, 30, False),
            _g("synthetic crew d", 5, 30, 30, False),
        ],
        "emoji_every": 4,
        "expected": "The Town Crier",
    },
    # group share ~32% → The Group MVP
    "mvp_mike": {
        "reply_deltas": [4.0] * 10 + [6.0] * 16 + [9.0] * 10,
        "n_dm": 16, "dm_user_last": 8,
        "groups": [
            _g("synthetic crew a", 5, 54, 26, True),
            _g("synthetic crew b", 4, 54, 26, False),
            _g("synthetic crew c", 6, 54, 26, False),
            _g("synthetic crew d", 5, 54, 26, False),
            _g("synthetic crew e", 5, 56, 26, False),
        ],
        "emoji_every": 4,
        "expected": "The Group MVP",
    },
    # 50% of texts carry an emoji → The Emoji Maximalist
    "emoji_elena": {
        "reply_deltas": [4.0] * 10 + [6.0] * 16 + [8.0] * 10,
        "n_dm": 16, "dm_user_last": 8,
        "groups": _default_groups(),
        "emoji_every": 2,
        "expected": "The Emoji Maximalist",
    },
    # zero emoji → The Deadpan
    "deadpan_dana": {
        "reply_deltas": [15.0] * 10 + [20.0] * 16 + [25.0] * 10,
        "n_dm": 16, "dm_user_last": 8,
        "groups": _default_groups(),
        "emoji_every": None,
        "expected": "The Deadpan",
    },
    # median ~50 with a monster tail → The Sorry-Just-Saw-This
    "sorry_sam": {
        "reply_deltas": [45.0] * 10 + [50.0] * 12 + [55.0] * 8 + [900.0] * 20,
        "n_dm": 16, "dm_user_last": 8,
        "groups": _default_groups(),
        "emoji_every": 4,
        "expected": "The Sorry-Just-Saw-This",
    },
    # median ~90, no tail → The Slow Burn
    "burn_beatrice": {
        "reply_deltas": [80.0] * 10 + [90.0] * 16 + [100.0] * 10,
        "n_dm": 16, "dm_user_last": 8,
        "groups": _default_groups(),
        "emoji_every": 4,
        "expected": "The Slow Burn",
    },
    # median ~3.5, mean dragged out by a few 300s → The Fast Starter
    "starter_steve": {
        "reply_deltas": [2.0] * 12 + [3.0] * 14 + [5.0] * 14 + [300.0] * 10,
        "n_dm": 16, "dm_user_last": 7,
        "groups": _default_groups(),
        "emoji_every": 4,
        "expected": "The Fast Starter",
    },
    # median ~2.5, no tail, mid ball → The Quick Draw (+ gen-z slang for the
    # cohort counters)
    "quick_quinn": {
        "reply_deltas": [2.0] * 14 + [2.5] * 14 + [3.0] * 12,
        "n_dm": 16, "dm_user_last": 7,
        "groups": _default_groups(),
        "emoji_every": 4,
        "slang": {"no cap": 10, "rizz": 9},
        "expected": "The Quick Draw",
    },
    # fast in 1:1, silent in most groups → The VIP Room
    "vip_vera": {
        "reply_deltas": [4.0] * 10 + [6.0] * 16 + [8.0] * 10,
        "n_dm": 16, "dm_user_last": 7,
        "groups": [
            _g("synthetic crew a", 5, 43, 7, False),
            _g("synthetic crew b", 4, 43, 7, False),
            _g("synthetic crew c", 6, 43, 7, False),
            _g("synthetic fantasy league", 8, 50, 0, False),
            _g("synthetic ski trip", 6, 50, 0, False),
            _g("synthetic book club", 5, 50, 0, False),
            _g("synthetic trivia team", 6, 50, 0, False),
            _g("synthetic neighbors", 4, 50, 0, False),
        ],
        "emoji_every": 4,
        "expected": "The VIP Room",
    },
    # group share ~4.2%, not silent enough for ghost/vip → The Quiet Lurker
    "lurker_lou": {
        "reply_deltas": [12.0] * 10 + [15.0] * 16 + [20.0] * 10,
        "n_dm": 16, "dm_user_last": 7,
        "groups": [
            _g("synthetic crew a", 5, 55, 5, False),
            _g("synthetic crew b", 4, 55, 5, False),
            _g("synthetic crew c", 6, 60, 0, False),
            _g("synthetic crew d", 5, 60, 0, False),
        ],
        "emoji_every": 4,
        "expected": "The Quiet Lurker",
    },
    # low-ish ball + real group presence → The Main Stage
    "stage_stella": {
        "reply_deltas": [10.0] * 10 + [12.0] * 16 + [15.0] * 10,
        "n_dm": 16, "dm_user_last": 4,
        "groups": [
            _g("synthetic crew a", 5, 48, 12, True),
            _g("synthetic crew b", 4, 48, 12, True),
            _g("synthetic crew c", 6, 48, 12, False),
            _g("synthetic crew d", 5, 48, 12, False),
        ],
        "emoji_every": 4,
        "expected": "The Main Stage",
    },
    # mid ball, mid median → The Diplomat
    "diplomat_dev": {
        "reply_deltas": [10.0] * 10 + [12.0] * 16 + [15.0] * 10,
        "n_dm": 16, "dm_user_last": 9,
        "groups": _default_groups(user_last_groups=1),
        "emoji_every": 4,
        "expected": "The Diplomat",
    },
    # nothing extreme anywhere → The Steady Hand (+ boomer slang for cohorts)
    "steady_sasha": {
        "reply_deltas": [30.0] * 10 + [35.0] * 16 + [40.0] * 10,
        "n_dm": 16, "dm_user_last": 12,
        "groups": _default_groups(user_last_groups=2),
        "emoji_every": 4,
        "slang": {"groovy": 10, "far out": 9},
        "expected": "The Steady Hand",
    },
    # ball 55–79 + fast + quick median → The Ping-Pong Pro
    "pingpong_pete": {
        "reply_deltas": [1.6] * 10 + [2.0] * 12 + [3.0] * 10 + [8.0] * 8,
        "n_dm": 21, "dm_user_last": 14,
        "groups": _default_groups(user_last_groups=1),
        "emoji_every": 4,
        "expected": "The Ping-Pong Pro",
    },
    # all traffic at 2–4 AM; otherwise unremarkable → The Steady Hand
    "night_owl_nina": {
        "reply_deltas": [25.0] * 10 + [28.0] * 16 + [32.0] * 10,
        "n_dm": 16, "dm_user_last": 11,
        "groups": _default_groups(user_last_groups=2),
        "emoji_every": 3,
        "night_owl": True,
        "expected": "The Steady Hand",
    },
}


def _apple_ns(unix_s):
    return int(round((unix_s - APPLE_EPOCH) * 1e9))


class _Db:
    def __init__(self, path):
        if os.path.exists(path):
            os.unlink(path)
        self.con = sqlite3.connect(path)
        c = self.con
        c.executescript("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
                               display_name TEXT, chat_identifier TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, handle_id INTEGER,
                                  date INTEGER, is_from_me INTEGER, item_type INTEGER,
                                  associated_message_type INTEGER, cache_has_attachments INTEGER,
                                  text TEXT, attributedBody BLOB);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        """)
        self.handle_ids = {}
        self.msg_rowid = 0
        self.outbound_count = 0

    def handle(self, hid):
        if hid not in self.handle_ids:
            rowid = len(self.handle_ids) + 1
            self.con.execute("INSERT INTO handle (ROWID, id) VALUES (?, ?)", (rowid, hid))
            self.handle_ids[hid] = rowid
        return self.handle_ids[hid]

    def chat(self, rowid, guid, style, display_name, identifier, member_handles):
        self.con.execute(
            "INSERT INTO chat (ROWID, guid, style, display_name, chat_identifier) VALUES (?, ?, ?, ?, ?)",
            (rowid, guid, style, display_name, identifier))
        for h in member_handles:
            self.con.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)",
                             (rowid, self.handle(h)))

    def message(self, chat_rowid, unix_s, from_me, text, sender_handle=None):
        self.msg_rowid += 1
        self.con.execute(
            "INSERT INTO message (ROWID, guid, handle_id, date, is_from_me, item_type, "
            "associated_message_type, cache_has_attachments, text, attributedBody) "
            "VALUES (?, ?, ?, ?, ?, 0, 0, 0, ?, NULL)",
            (self.msg_rowid, f"SYN-{self.msg_rowid:06d}",
             self.handle(sender_handle) if sender_handle else 0,
             _apple_ns(unix_s), 1 if from_me else 0, text))
        self.con.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
                         (chat_rowid, self.msg_rowid))

    def close(self):
        self.con.commit()
        self.con.close()


def _outbound_text(db, persona, body_idx):
    """Cycle the synthetic corpus; append an emoji every Nth outbound."""
    db.outbound_count += 1
    body = SYNTH_BODIES[body_idx % len(SYNTH_BODIES)]
    every = persona.get("emoji_every")
    if every and db.outbound_count % every == 0:
        body = body + " 😂"
    return body


def build_chatdb(path, persona_name):
    """Write a chat.db-shaped sqlite fixture for `persona_name`. Deterministic:
    same persona → byte-identical event content."""
    persona = PERSONAS[persona_name]
    db = _Db(path)

    day_anchor_hour = 3 if persona.get("night_owl") else 12
    # Re-anchor the day so all events land near the persona's active hour.
    base = ANCHOR_UNIX_S - (12 - day_anchor_hour) * 3600

    n_dm = persona["n_dm"]
    deltas = persona["reply_deltas"]
    dm_user_last = persona["dm_user_last"]
    chat_rowid = 0
    body_idx = 0

    # 1:1 threads — deltas distributed round-robin; thread i gets every
    # n_dm-th delta. Conversations are stacked backward in time, one thread
    # per day-slot, all inside the past ~90 days (well within a year window).
    per_thread = [[] for _ in range(n_dm)]
    for i, d in enumerate(deltas):
        per_thread[i % n_dm].append(d)

    for t in range(n_dm):
        contact = SYNTH_CONTACT_POOL[t % len(SYNTH_CONTACT_POOL)]
        chat_rowid += 1
        db.chat(chat_rowid, f"iMessage;-;{contact}-{t}", 45, None, contact, [contact])
        # Thread t's conversation happens t+2 days before the anchor.
        ts = base - (t + 2) * 86400
        for d in per_thread[t]:
            db.message(chat_rowid, ts, False, SYNTH_BODIES[(body_idx + 3) % len(SYNTH_BODIES)], contact)
            ts += d * 60.0
            db.message(chat_rowid, ts, True, _outbound_text(db, persona, body_idx))
            body_idx += 1
            ts += 4 * 3600  # space pairs out so they never chain
        if t >= dm_user_last:
            # They get the last word in this thread.
            ts += 600
            db.message(chat_rowid, ts, False, SYNTH_BODIES[(body_idx + 5) % len(SYNTH_BODIES)], contact)

        # Slang personas: standalone outbound messages parked right after the
        # FIRST outbound of thread 0 (outbound-after-outbound → no new latency
        # pair, and never the thread's last message).
        if t == 0:
            slang_ts = base - (t + 2) * 86400 + 3600
            for token, count in (persona.get("slang") or {}).items():
                for k in range(count):
                    db.message(chat_rowid, slang_ts, True, token)
                    slang_ts += 1

    # Group threads.
    for gi, g in enumerate(persona["groups"]):
        chat_rowid += 1
        members = [SYNTH_CONTACT_POOL[-(m + 1)] for m in range(g["members"])]
        db.chat(chat_rowid, f"iMessage;+;syngroup-{gi}", 43, g["name"], f"syngroup-{gi}", members)
        ts = base - (40 + gi) * 86400
        peer_left = g["peer_msgs"]
        user_left = g["user_msgs"]
        # Interleave: peers post in round-robin; user posts every
        # (total // user_msgs)-th slot when they post at all.
        total = peer_left + user_left
        stride = (total // user_left) if user_left else 0
        slot = 0
        while peer_left or user_left:
            slot += 1
            ts += 600
            # User posts on slots ≡ 1 (mod stride) so the FINAL slot is always
            # a peer's — `user_last` alone controls who closes the group.
            post_user = user_left and stride and (slot % stride == 1 if stride > 1 else True)
            if post_user or (user_left and not peer_left):
                db.message(chat_rowid, ts, True, _outbound_text(db, persona, body_idx))
                body_idx += 1
                user_left -= 1
            else:
                sender = members[slot % len(members)]
                db.message(chat_rowid, ts, False, SYNTH_BODIES[slot % len(SYNTH_BODIES)], sender)
                peer_left -= 1
        if g["user_last"] and g["user_msgs"]:
            ts += 600
            db.message(chat_rowid, ts, True, _outbound_text(db, persona, body_idx))
            body_idx += 1

    db.close()
    return path


if __name__ == "__main__":
    import sys
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    for name in PERSONAS:
        p = os.path.join(out_dir, f"{name}.db")
        build_chatdb(p, name)
        print(f"wrote {p}")
