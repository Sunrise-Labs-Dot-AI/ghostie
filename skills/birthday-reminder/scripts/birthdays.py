#!/usr/bin/env python3
"""birthdays.py — read birthday JSON, list upcoming within a window.

The birthday-reminder skill's date logic. The model is not great at "what day
is 14 days from today" — this script is the source of truth. Pure stdlib.

Usage:
    python3 birthdays.py --input PATH [--window 14] [--today YYYY-MM-DD]

Input JSON schema (array at top level):
    [
      {
        "name": "Allison",                       # required
        "contact_handle": "+15551234567",        # optional, used for stage_draft
        "birthday": "MM-DD" or "YYYY-MM-DD",     # required
        "relationship": "partner|family|friend|colleague",  # optional
        "notes": "free-form context for drafting",          # optional
        "last_year_skipped": false               # optional
      }
    ]

Output JSON (stdout):
    {
      "today": "YYYY-MM-DD",
      "window_days": 14,
      "count": N,
      "upcoming": [
        { ...enriched entry with next_occurrence, days_until, weekday, age_turning... }
      ]
    }

Exit codes:
    0 — success
    2 — input file missing or malformed
"""

import argparse
import json
import sys
from datetime import date, datetime


def parse_birthday(s):
    """Return (month, day, year_or_None). Accepts 'MM-DD' or 'YYYY-MM-DD'."""
    parts = s.split("-")
    if len(parts) == 2:
        return int(parts[0]), int(parts[1]), None
    if len(parts) == 3:
        return int(parts[1]), int(parts[2]), int(parts[0])
    raise ValueError(f"unrecognized birthday format: {s!r}")


def next_occurrence(today, month, day):
    """Next date >= today with given month/day. Feb 29 slides to Feb 28 in non-leap years."""

    def safe_date(year, m, d):
        try:
            return date(year, m, d)
        except ValueError:
            if m == 2 and d == 29:
                return date(year, 2, 28)
            raise

    candidate = safe_date(today.year, month, day)
    if candidate < today:
        candidate = safe_date(today.year + 1, month, day)
    return candidate


def main():
    ap = argparse.ArgumentParser(description="List upcoming birthdays within a window.")
    ap.add_argument("--input", required=True, help="Path to birthdays JSON.")
    ap.add_argument("--window", type=int, default=14, help="Window in days (default 14).")
    ap.add_argument("--today", help="Override today (YYYY-MM-DD) — for testing.")
    args = ap.parse_args()

    if args.window < 0:
        print(
            json.dumps({"error": "window must be >= 0", "window": args.window}),
            file=sys.stderr,
        )
        sys.exit(2)

    today = (
        datetime.strptime(args.today, "%Y-%m-%d").date() if args.today else date.today()
    )

    try:
        with open(args.input) as f:
            entries = json.load(f)
    except FileNotFoundError:
        print(
            json.dumps({"error": "file not found", "path": args.input}), file=sys.stderr
        )
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)

    if not isinstance(entries, list):
        print(
            json.dumps({"error": "expected a JSON array at the top level"}),
            file=sys.stderr,
        )
        sys.exit(2)

    upcoming = []
    for i, entry in enumerate(entries):
        try:
            month, day, year = parse_birthday(entry["birthday"])
            # next_occurrence is inside the try on purpose: an impossible-but-
            # well-formed date like "06-31" raises ValueError here, and we want
            # to skip just that entry with a warning — not crash the whole run.
            next_dt = next_occurrence(today, month, day)
        except (KeyError, ValueError, TypeError) as e:
            print(f"  warn: skipping entry {i}: {e}", file=sys.stderr)
            continue
        delta = (next_dt - today).days
        if delta > args.window:
            continue
        age_turning = next_dt.year - year if year is not None else None
        upcoming.append(
            {
                "name": entry.get("name", "(unnamed)"),
                "contact_handle": entry.get("contact_handle"),
                "birthday": entry["birthday"],
                "next_occurrence": next_dt.isoformat(),
                "days_until": delta,
                "weekday": next_dt.strftime("%a"),
                "age_turning": age_turning,
                "relationship": entry.get("relationship"),
                "notes": entry.get("notes"),
                "last_year_skipped": entry.get("last_year_skipped", False),
            }
        )

    upcoming.sort(key=lambda x: x["days_until"])

    print(
        json.dumps(
            {
                "today": today.isoformat(),
                "window_days": args.window,
                "count": len(upcoming),
                "upcoming": upcoming,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
