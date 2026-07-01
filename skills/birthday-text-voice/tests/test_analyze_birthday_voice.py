#!/usr/bin/env python3
"""Tests for analyze_birthday_voice.py. Run: python3 -m unittest (or this file directly).

Subprocess-based: exercises the real CLI, exit codes, segmentation, group-wish
inclusion, and — critically — the privacy invariant (no body leaks into output).
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "analyze_birthday_voice.py")


def run(wishes):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(wishes, f)
        path = f.name
    try:
        p = subprocess.run([sys.executable, SCRIPT, "--input", path],
                           capture_output=True, text=True)
        out = json.loads(p.stdout) if p.stdout.strip() else None
        return p.returncode, out, p.stdout, p.stderr
    finally:
        os.unlink(path)


def wish(idx=0, text="happy birthday!! 🎂", tier=None, gender=None, is_group=False, thread_id=1):
    h = 9 + (idx // 60) % 12
    m = idx % 60
    return {"ts": f"2025-03-14T{h:02d}:{m:02d}:00", "text": text, "thread_id": thread_id,
            "is_group": is_group, "tier": tier, "gender": gender}


def make(n, start=0, **kw):
    return [wish(idx=start + i, **kw) for i in range(n)]


class AnalyzeBirthdayVoiceTest(unittest.TestCase):
    def test_overall_too_small_exits_3(self):
        rc, _, _, _ = run(make(8, tier="friend"))
        self.assertEqual(rc, 3)

    def test_output_contract(self):
        rc, out, _, err = run(make(15, tier="friend"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["kind"], "birthday-voice")
        self.assertEqual(out["sample_size"], 15)
        for k in ("overall", "tiers", "genders", "segments_omitted", "window"):
            self.assertIn(k, out)
        for section in ("length", "capitalization", "punctuation", "emoji",
                        "abbreviations", "bursts", "openers", "closers", "birthday"):
            self.assertIn(section, out["overall"])

    def test_tier_segmentation_and_threshold(self):
        wishes = make(10, start=0, tier="family") + make(9, start=10, tier="friend") \
            + make(3, start=19, tier="colleague")  # colleague below SEGMENT_MIN (8)
        rc, out, _, err = run(wishes)
        self.assertEqual(rc, 0, err)
        self.assertIn("family", out["tiers"])
        self.assertIn("friend", out["tiers"])
        self.assertNotIn("colleague", out["tiers"])
        omitted = {s["segment"] for s in out["segments_omitted"]}
        self.assertIn("tier:colleague", omitted)
        self.assertEqual(out["tiers"]["family"]["sample_size"], 10)

    def test_group_wishes_feed_overall_but_not_tier(self):
        wishes = make(12, start=0, tier="family") \
            + make(5, start=12, is_group=True, tier=None)  # unattributed group wishes
        rc, out, _, err = run(wishes)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["sample_size"], 17)
        self.assertEqual(out["group_count"], 5)
        self.assertEqual(out["untiered_count"], 5)
        self.assertEqual(out["tiers"]["family"]["sample_size"], 12)  # group wishes not in tier

    def test_gender_segment_only_when_tagged_and_sufficient(self):
        wishes = make(8, start=0, tier="friend", gender="f") \
            + make(4, start=8, tier="friend", gender="m")  # m below SEGMENT_MIN
        rc, out, _, err = run(wishes)
        self.assertEqual(rc, 0, err)
        self.assertIn("f", out["genders"])
        self.assertNotIn("m", out["genders"])

    def test_no_body_leak_and_openers_allowlist(self):
        # A distinctive multi-word body must not surface; a proper-noun first word
        # ("Sarah") must be dropped from openers while "happy" is allowed.
        secret = "secret plans at 5pm downtown tomorrow"
        wishes = make(13, tier="friend")
        wishes.append(wish(idx=99, text=secret, tier="friend"))
        wishes.append(wish(idx=100, text="Sarah hope your day rocks", tier="friend"))
        rc, out, stdout, err = run(wishes)
        self.assertEqual(rc, 0, err)
        self.assertNotIn("secret", stdout)
        self.assertNotIn(secret, stdout)
        openers = [o["phrase"] for o in out["overall"]["openers"]["top_3"]]
        self.assertNotIn("sarah", openers)
        self.assertIn("happy", openers)

    def test_birthday_signals_present(self):
        rc, out, _, err = run(make(15, tier="friend", text="happy birthday!! 🎂"))
        self.assertEqual(rc, 0, err)
        bd = out["overall"]["birthday"]
        self.assertEqual(bd["pct_with_birthday_emoji"], 1.0)
        self.assertEqual(bd["pct_with_double_exclaim"], 1.0)

    def test_malformed_input_exits_2(self):
        rc, _, _, _ = run({"not": "a list"})
        self.assertEqual(rc, 2)

    def test_letterlike_symbols_do_not_leak_as_emoji(self):
        # Circled letters (U+24D9…, category "So") could spell a name — they must
        # NOT surface in the emoji list. "happy" still opens.
        rc, out, stdout, err = run(make(13, tier="friend", text="happy bday ⓙⓞⓗⓝ 🎂"))
        self.assertEqual(rc, 0, err)
        emoji = [e["emoji"] for e in out["overall"]["emoji"]["top_5"]]
        self.assertIn("🎂", emoji)
        for circled in ("ⓙ", "ⓞ", "ⓗ", "ⓝ"):
            self.assertNotIn(circled, emoji)
            self.assertNotIn(circled, stdout)

    def test_trailing_heart_vs16_counts_as_exclaim(self):
        # "happy birthday! ❤️" ends in "!" under a ❤️ (heart + U+FE0F); the variation
        # selector must not hide the exclamation, and ❤️ counts as a birthday emoji.
        rc, out, _, err = run(make(13, tier="friend", text="happy birthday! ❤️"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["overall"]["punctuation"]["pct_ending_with_exclaim"], 1.0)
        self.assertEqual(out["overall"]["birthday"]["pct_with_birthday_emoji"], 1.0)


if __name__ == "__main__":
    unittest.main()
