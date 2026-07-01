#!/usr/bin/env python3
"""Tests for analyze_voice.py. Run: python3 -m unittest, or python3 test_analyze_voice.py

Subprocess-based: exercises the real CLI, exit codes, and — critically — the
privacy invariant (no message body leaks into the output).
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "analyze_voice.py")


def run(messages, contact="Test Person", slug="test"):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(messages, f)
        path = f.name
    try:
        p = subprocess.run(
            [sys.executable, SCRIPT, "--input", path, "--contact", contact, "--slug", slug],
            capture_output=True, text=True,
        )
        out = json.loads(p.stdout) if p.stdout.strip() else None
        return p.returncode, out, p.stdout, p.stderr
    finally:
        os.unlink(path)


def make_messages(n, text="hey", thread_id=1, start_hour=9):
    # n messages, 5 minutes apart, naive timestamps.
    msgs = []
    for i in range(n):
        h = start_hour + (i // 12)
        m = (i % 12) * 5
        msgs.append({"ts": f"2026-05-0{1 + (i // 50)}T{h:02d}:{m:02d}:00",
                     "text": text, "thread_id": thread_id})
    return msgs


class AnalyzeVoiceTest(unittest.TestCase):
    def test_mixed_timezone_does_not_crash(self):
        # Regression: tz-aware ("Z") + naive timestamps used to crash min()/max()/sorted().
        msgs = []
        for i in range(35):
            ts = f"2026-05-01T10:{i % 60:02d}:00" + ("Z" if i % 2 else "")
            msgs.append({"ts": ts, "text": "ok cool", "thread_id": 1})
        rc, out, _, err = run(msgs)
        self.assertEqual(rc, 0, f"mixed-tz must not crash; stderr={err}")
        self.assertIn("window", out)

    def test_sample_too_small_exits_3(self):
        rc, out, _, err = run(make_messages(10))
        self.assertEqual(rc, 3)

    def test_no_message_body_leaks_into_output(self):
        # A distinctive multi-word body must not appear verbatim anywhere in output.
        secret = "meeting at 1234 Confidential Avenue downtown"
        msgs = make_messages(34, text="ok")
        msgs.append({"ts": "2026-05-02T12:00:00", "text": secret, "thread_id": 1})
        rc, out, stdout, err = run(msgs)
        self.assertEqual(rc, 0, f"stderr={err}")
        self.assertNotIn("Confidential", stdout)
        self.assertNotIn(secret, stdout)

    def test_openers_allowlist_drops_proper_nouns(self):
        # First word "Smith" (a surname) must NOT surface; "hey" (allowlisted) may.
        msgs = [{"ts": f"2026-05-01T10:{i:02d}:00", "text": "Smith we should talk", "thread_id": 1}
                for i in range(20)]
        msgs += [{"ts": f"2026-05-01T11:{i:02d}:00", "text": "hey there", "thread_id": 1}
                 for i in range(15)]
        rc, out, stdout, err = run(msgs)
        self.assertEqual(rc, 0, f"stderr={err}")
        opener_phrases = [o["phrase"] for o in out["openers"]["top_3"]]
        self.assertNotIn("smith", opener_phrases)
        self.assertIn("hey", opener_phrases)

    def test_valid_output_contract(self):
        rc, out, _, err = run(make_messages(40, text="yeah sounds good"))
        self.assertEqual(rc, 0)
        for key in ("contact", "slug", "sample_size", "window", "length",
                    "capitalization", "punctuation", "emoji", "abbreviations",
                    "bursts", "openers", "closers"):
            self.assertIn(key, out)
        self.assertEqual(out["sample_size"], 40)
        self.assertIsInstance(out["length"]["median_chars"], int)

    def test_letterlike_symbols_do_not_leak_as_emoji(self):
        # Circled letters (category "So") are readable letters — they must NOT
        # surface in the committed emoji list (a name could spell out).
        rc, out, stdout, err = run(make_messages(35, text="ok ⓙⓞⓗⓝ 🎂"))
        self.assertEqual(rc, 0, err)
        emoji = [e["emoji"] for e in out["emoji"]["top_5"]]
        self.assertIn("🎂", emoji)
        for circled in ("ⓙ", "ⓞ", "ⓗ", "ⓝ"):
            self.assertNotIn(circled, emoji)
            self.assertNotIn(circled, stdout)

    def test_trailing_heart_vs16_counts_as_exclaim(self):
        # "see you! ❤️" ends in "!" under a ❤️ (heart + U+FE0F); the variation
        # selector must not hide the exclamation.
        rc, out, _, err = run(make_messages(35, text="see you! ❤️"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["punctuation"]["pct_ending_with_exclaim"], 1.0)


if __name__ == "__main__":
    unittest.main()
