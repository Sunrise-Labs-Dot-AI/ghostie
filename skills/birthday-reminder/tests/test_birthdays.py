#!/usr/bin/env python3
"""Tests for birthdays.py. Run: python3 -m unittest, or python3 test_birthdays.py

Subprocess-based: exercises the real CLI entrypoint, exit codes, and JSON output.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "birthdays.py")


def run(entries, *extra):
    """Write entries to a temp JSON file, run birthdays.py, return (rc, parsed_stdout_or_None, stderr)."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(entries, f)
        path = f.name
    try:
        p = subprocess.run(
            [sys.executable, SCRIPT, "--input", path, *extra],
            capture_output=True, text=True,
        )
        out = None
        if p.stdout.strip():
            try:
                out = json.loads(p.stdout)
            except json.JSONDecodeError:
                out = None
        return p.returncode, out, p.stderr
    finally:
        os.unlink(path)


class BirthdaysTest(unittest.TestCase):
    def test_impossible_date_skips_one_entry_not_crash(self):
        # Regression: "06-31" used to crash the whole run (next_occurrence outside try).
        rc, out, err = run(
            [{"name": "Bad", "birthday": "06-31"}, {"name": "Good", "birthday": "01-01"}],
            "--today", "2026-01-01", "--window", "400",
        )
        self.assertEqual(rc, 0, f"should not crash; stderr={err}")
        self.assertIsNotNone(out)
        names = [e["name"] for e in out["upcoming"]]
        self.assertIn("Good", names)
        self.assertNotIn("Bad", names)
        self.assertIn("warn", err)  # surfaced, not silent

    def test_leap_day_slides_in_non_leap_year(self):
        rc, out, err = run(
            [{"name": "Leap", "birthday": "02-29"}],
            "--today", "2027-02-25", "--window", "10",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out["count"], 1)
        self.assertEqual(out["upcoming"][0]["next_occurrence"], "2027-02-28")

    def test_negative_window_rejected(self):
        rc, out, err = run([{"name": "X", "birthday": "01-01"}], "--window", "-1")
        self.assertEqual(rc, 2)

    def test_birthday_today_is_included(self):
        rc, out, err = run(
            [{"name": "Today", "birthday": "03-15"}],
            "--today", "2026-03-15", "--window", "14",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out["count"], 1)
        self.assertEqual(out["upcoming"][0]["days_until"], 0)

    def test_missing_file_exits_2(self):
        p = subprocess.run(
            [sys.executable, SCRIPT, "--input", "/no/such/file.json"],
            capture_output=True, text=True,
        )
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
