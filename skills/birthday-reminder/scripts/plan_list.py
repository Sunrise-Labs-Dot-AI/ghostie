#!/usr/bin/env python3
"""plan_list.py — turn the engine `--seed` output into an actionable work-list.

The birthday list-builder flow: the `birthday-generator --seed` mode emits
everyone the user is in regular contact with (affinity-sorted, closest first),
each marked with a saved birthday, an inferred birthday (from the date of a past
"happy birthday" text), or neither. This script diffs that seed against the
already-built list (`birthdays.json`) and buckets each person by what the LLM
must DO next — so the model acts on clean categories instead of eyeballing 120
rows and miscategorizing.

Buckets (each contact lands in exactly one, by this precedence):
  already_on_list  — present in birthdays.json already; skip or just confirm.
  ready_saved      — not on the list, but has a saved birthday; ready to add.
  confirm_inferred — not on the list, no saved date, but a birthday was inferred
                     from a past wish; CONFIRM with the user (it's approximate).
  needs_sourcing   — not on the list, no saved, no inferred; ASK the user (or
                     read the thread) for the date.

Pure stdlib. Reads the seed (Contacts + chat.db signals) only as JSON; never
touches chat.db itself.

Usage:
    python3 plan_list.py --seed PATH|-  [--hand PATH] [--top N]

    # piped straight from the engine:
    bun run mcps/birthday-generator/src/index.ts --seed | python3 plan_list.py --seed -

Output JSON (stdout):
    {
      "total_seed": N,            # contacts considered (after --top)
      "counts": { "already_on_list": .., "ready_saved": .., "confirm_inferred": .., "needs_sourcing": .. },
      "already_on_list": [ {contact...}, ... ],
      "ready_saved": [...],
      "confirm_inferred": [...],
      "needs_sourcing": [...]
    }

Exit codes:
    0 — success
    2 — seed missing / malformed
"""

import argparse
import json
import os
import re
import sys
import unicodedata

DEFAULT_HAND = os.path.join(os.path.expanduser("~"), ".messages-mcp", "birthdays.json")

# Fields carried through from each seed contact into the buckets, so the skill
# has everything it needs to act + present without re-reading the seed.
PASS_FIELDS = (
    "name",
    "best_handle",
    "saved_birthday",
    "inferred_birthday",
    "out_count",
    "call_count",
    "last_texted_days",
    "last_call_days",
    "reason",
)


def canon_handle(h):
    """Mirror the engine's canonHandle (imessage-drafts/src/chatdb/canon.ts) EXACTLY
    so the already_on_list dedup matches what the engine wrote: lowercased email
    (no trim), else last-10 digits for phones (full digits if fewer)."""
    if not h:
        return ""
    if "@" in h:
        return h.lower()
    digits = re.sub(r"\D", "", h)
    return digits[-10:] if len(digits) >= 10 else digits


def norm_name(s):
    """Mirror the engine's normName (store.ts) EXACTLY: NFD, strip only the
    combining-diacritical-marks block U+0300–U+036F (NOT all combining marks, which
    would over-strip non-Latin scripts vs. the engine), lowercase, collapse space."""
    if not s:
        return ""
    s = unicodedata.normalize("NFD", s)
    s = re.sub(r"[̀-ͯ]", "", s)
    return re.sub(r"\s+", " ", s.lower().strip())


def load_json(path, what):
    """Read + parse JSON from a path, or stdin when path == '-'. Exit 2 on failure."""
    try:
        if path == "-":
            return json.load(sys.stdin)
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": f"{what} not found", "path": path}), file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"{what} invalid JSON", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)


def build_hand_index(hand_path):
    """Set of canonical handles + set of normalized names already in birthdays.json.

    Missing/unreadable hand file → empty index (a fresh user, no list yet). A
    malformed hand file is non-fatal here: it shouldn't block planning, so we
    treat it as empty and note it.
    """
    canons = set()
    names = set()
    note = None
    if not os.path.exists(hand_path):
        return canons, names, note
    try:
        with open(hand_path) as f:
            entries = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        return canons, names, f"birthdays.json unreadable ({e}); treating list as empty"
    if not isinstance(entries, list):
        return canons, names, "birthdays.json is not a JSON array; treating list as empty"
    for e in entries:
        if not isinstance(e, dict):
            continue
        h = e.get("contact_handle")
        if isinstance(h, str):
            c = canon_handle(h)
            if c:
                canons.add(c)
        n = e.get("name")
        if isinstance(n, str):
            nk = norm_name(n)
            if nk:
                names.add(nk)
    return canons, names, note


def main():
    ap = argparse.ArgumentParser(description="Bucket the birthday seed into an actionable work-list.")
    ap.add_argument("--seed", required=True, help="Path to the engine --seed JSON, or '-' for stdin.")
    ap.add_argument("--hand", default=DEFAULT_HAND, help="Path to birthdays.json (the already-built list).")
    ap.add_argument("--top", type=int, default=None, help="Only consider the closest N seed contacts.")
    args = ap.parse_args()

    seed = load_json(args.seed, "seed")
    contacts = seed.get("contacts") if isinstance(seed, dict) else None
    if not isinstance(contacts, list):
        print(json.dumps({"error": "seed has no 'contacts' array"}), file=sys.stderr)
        sys.exit(2)

    if args.top is not None:
        if args.top < 1:
            print(json.dumps({"error": "--top must be >= 1", "top": args.top}), file=sys.stderr)
            sys.exit(2)
        contacts = contacts[: args.top]

    hand_canons, hand_names, hand_note = build_hand_index(args.hand)

    buckets = {
        "already_on_list": [],
        "ready_saved": [],
        "confirm_inferred": [],
        "needs_sourcing": [],
    }

    for c in contacts:
        if not isinstance(c, dict):
            continue
        row = {k: c.get(k) for k in PASS_FIELDS}
        handle_canon = canon_handle(c.get("best_handle") or "")
        name_key = norm_name(c.get("name") or "")
        on_list = (handle_canon and handle_canon in hand_canons) or (name_key and name_key in hand_names)

        if on_list:
            buckets["already_on_list"].append(row)
        elif c.get("saved_birthday"):
            buckets["ready_saved"].append(row)
        elif c.get("inferred_birthday"):
            buckets["confirm_inferred"].append(row)
        else:
            buckets["needs_sourcing"].append(row)

    out = {
        "total_seed": len(contacts),
        "counts": {k: len(v) for k, v in buckets.items()},
        **buckets,
    }
    if hand_note:
        out["hand_note"] = hand_note
    # Surface seed availability so the skill can warn if chat.db wasn't readable.
    if isinstance(seed, dict):
        if "signals_available" in seed:
            out["signals_available"] = seed["signals_available"]
        if "contacts_available" in seed:
            out["contacts_available"] = seed["contacts_available"]

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
