#!/usr/bin/env python3
"""Tests for plan_list.py. Run: python3 -m unittest, or python3 test_plan_list.py

Subprocess-based: exercises the real CLI, exit codes, and bucket logic.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "plan_list.py")


def seed(*contacts, signals_available=True, contacts_available=True):
    return {
        "contacts_available": contacts_available,
        "signals_available": signals_available,
        "count": len(contacts),
        "contacts": list(contacts),
    }


def contact(name, best_handle=None, saved=None, inferred=None):
    return {
        "name": name,
        "best_handle": best_handle,
        "saved_birthday": saved,
        "inferred_birthday": inferred,
        "out_count": 100,
        "call_count": 0,
        "last_texted_days": 3,
        "last_call_days": None,
        "reason": "100 texts, last 3d ago",
    }


def run(seed_obj, hand=None, *extra):
    """Write seed (+ optional hand) to temp files, run plan_list.py, return (rc, out, err)."""
    tmp = tempfile.mkdtemp()
    seed_path = os.path.join(tmp, "seed.json")
    with open(seed_path, "w") as f:
        json.dump(seed_obj, f)
    cmd = [sys.executable, SCRIPT, "--seed", seed_path]
    if hand is not None:
        hand_path = os.path.join(tmp, "birthdays.json")
        with open(hand_path, "w") as f:
            json.dump(hand, f)
        cmd += ["--hand", hand_path]
    else:
        # Point --hand at a guaranteed-missing path so we never read the real one.
        cmd += ["--hand", os.path.join(tmp, "no-such-birthdays.json")]
    cmd += list(extra)
    p = subprocess.run(cmd, capture_output=True, text=True)
    out = json.loads(p.stdout) if p.stdout.strip() else None
    return p.returncode, out, p.stderr


class PlanListTest(unittest.TestCase):
    def test_buckets_by_precedence(self):
        rc, out, err = run(
            seed(
                contact("Ann Saved", "+15550000001", saved="1990-01-02"),
                contact("Iggy Inferred", "+15550000002", inferred="06-04"),
                contact("Nora None", "+15550000003"),
            )
        )
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["counts"], {
            "already_on_list": 0, "ready_saved": 1, "confirm_inferred": 1, "needs_sourcing": 1,
        })
        self.assertEqual(out["ready_saved"][0]["name"], "Ann Saved")
        self.assertEqual(out["confirm_inferred"][0]["name"], "Iggy Inferred")
        self.assertEqual(out["needs_sourcing"][0]["name"], "Nora None")

    def test_already_on_list_wins_by_handle_match(self):
        # Last-10-digit canon: seed "+1 (555) 000-1234" matches hand "5550001234".
        rc, out, err = run(
            seed(contact("On List", "+1 (555) 000-1234", saved="07-15")),
            [{"name": "On List", "contact_handle": "5550001234", "birthday": "07-15", "pinned": True}],
        )
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["counts"]["already_on_list"], 1)
        self.assertEqual(out["counts"]["ready_saved"], 0)  # NOT double-counted

    def test_already_on_list_by_diacritic_insensitive_name(self):
        rc, out, err = run(
            seed(contact("José Díaz", best_handle=None, inferred="03-15")),
            [{"name": "Jose Diaz", "birthday": "03-15"}],  # no handle on either side
        )
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["counts"]["already_on_list"], 1)
        self.assertEqual(out["counts"]["confirm_inferred"], 0)

    def test_email_handle_canon_match(self):
        rc, out, err = run(
            seed(contact("Sam", "SamSample@Example.com", saved="07-15")),
            [{"name": "Sam", "contact_handle": "samsample@example.com", "birthday": "07-15"}],
        )
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["counts"]["already_on_list"], 1)

    def test_top_limits_to_closest_n(self):
        rc, out, err = run(
            seed(
                contact("First", "+15550000001"),
                contact("Second", "+15550000002"),
                contact("Third", "+15550000003"),
            ),
            None,
            "--top", "2",
        )
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["total_seed"], 2)
        names = [r["name"] for r in out["needs_sourcing"]]
        self.assertEqual(names, ["First", "Second"])  # seed order preserved (affinity)

    def test_missing_seed_exits_2(self):
        p = subprocess.run(
            [sys.executable, SCRIPT, "--seed", "/no/such/seed.json"],
            capture_output=True, text=True,
        )
        self.assertEqual(p.returncode, 2)

    def test_no_hand_file_is_fresh_user_not_a_crash(self):
        rc, out, err = run(seed(contact("Solo", "+15550000009", saved="01-01")))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["counts"]["already_on_list"], 0)
        self.assertEqual(out["counts"]["ready_saved"], 1)

    def test_signals_unavailable_surfaced(self):
        rc, out, err = run(seed(signals_available=False, contacts_available=True))
        self.assertEqual(rc, 0, err)
        self.assertFalse(out["signals_available"])
        self.assertEqual(out["total_seed"], 0)

    def test_stdin_seed(self):
        # --seed - reads stdin (the engine | plan_list.py pipe).
        s = seed(contact("Piped", "+15550000010", inferred="12-12"))
        p = subprocess.run(
            [sys.executable, SCRIPT, "--seed", "-", "--hand", "/no/such/hand.json"],
            input=json.dumps(s), capture_output=True, text=True,
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        out = json.loads(p.stdout)
        self.assertEqual(out["counts"]["confirm_inferred"], 1)


if __name__ == "__main__":
    unittest.main()
