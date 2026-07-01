#!/usr/bin/env python3
"""Tests for render_birthday_voice.py. Run: python3 -m unittest (or this file directly).

Covers the refresh contract (no-overwrite without --force; --force overwrites and
reports drift) and the no-body-in-output invariant, driven off the committed
example fingerprint.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(__file__)
SCRIPT = os.path.join(HERE, "..", "scripts", "render_birthday_voice.py")
EXAMPLE = os.path.join(HERE, "..", "examples", "sample-fingerprint.json")


def render(fingerprint_path, out_dir, force=False):
    args = [sys.executable, SCRIPT, "--fingerprint", fingerprint_path, "--output-dir", out_dir]
    if force:
        args.append("--force")
    p = subprocess.run(args, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


class RenderBirthdayVoiceTest(unittest.TestCase):
    def test_first_run_writes_files(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out, err = render(EXAMPLE, d)
            self.assertEqual(rc, 0, err)
            self.assertTrue(os.path.exists(os.path.join(d, "VOICE.md")))
            self.assertTrue(os.path.exists(os.path.join(d, "fingerprint.json")))

    def test_refuses_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(render(EXAMPLE, d)[0], 0)
            rc, _, _ = render(EXAMPLE, d)  # second run, no --force
            self.assertEqual(rc, 4)

    def test_force_overwrites_and_reports_drift(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(render(EXAMPLE, d)[0], 0)
            # Bump a stat so drift is visible, then refresh in place.
            with open(EXAMPLE) as f:
                fp = json.load(f)
            fp["sample_size"] = fp["sample_size"] + 100
            bumped = os.path.join(d, "bumped.json")
            with open(bumped, "w") as f:
                json.dump(fp, f)
            rc, out, err = render(bumped, d, force=True)
            self.assertEqual(rc, 0, err)
            self.assertTrue(json.loads(out)["refreshed"])
            with open(os.path.join(d, "VOICE.md")) as f:
                voice = f.read()
            self.assertIn("Drift since last refresh", voice)
            self.assertIn("Sample size", voice)

    def test_rejects_non_birthday_fingerprint(self):
        with tempfile.TemporaryDirectory() as d:
            bad = os.path.join(d, "bad.json")
            with open(bad, "w") as f:
                json.dump({"slug": "x", "length": {}}, f)  # no kind: birthday-voice
            self.assertEqual(render(bad, d)[0], 2)

    def test_no_body_in_voice_md(self):
        # The renderer only reformats aggregates — VOICE.md must contain no prose
        # sentence from a message. (Belt-and-suspenders: the example has no bodies.)
        with tempfile.TemporaryDirectory() as d:
            render(EXAMPLE, d)
            with open(os.path.join(d, "VOICE.md")) as f:
                voice = f.read()
            self.assertNotIn("hope it's a great one", voice)
            self.assertNotIn("love you so much", voice)


if __name__ == "__main__":
    unittest.main()
