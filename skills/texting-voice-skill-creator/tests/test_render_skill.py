#!/usr/bin/env python3
"""Tests for render_skill.py — the create + --force/drift refresh contract.
Run: python3 -m unittest (or this file directly). Driven off the example fingerprint.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(__file__)
SCRIPT = os.path.join(HERE, "..", "scripts", "render_skill.py")
EXAMPLE = os.path.join(HERE, "..", "examples", "sample-fingerprint.json")

with open(EXAMPLE) as _f:
    SLUG = json.load(_f)["slug"]


def render(fingerprint_path, out_dir, force=False):
    args = [sys.executable, SCRIPT, "--fingerprint", fingerprint_path, "--output-dir", out_dir]
    if force:
        args.append("--force")
    p = subprocess.run(args, capture_output=True, text=True)
    out = json.loads(p.stdout) if p.stdout.strip() else None
    return p.returncode, out, p.stderr


def skill_files(out_dir):
    d = os.path.join(out_dir, f"{SLUG}-text-voice")
    return os.path.join(d, "SKILL.md"), os.path.join(d, "fingerprint.json")


class RenderSkillTest(unittest.TestCase):
    def test_first_run_creates_skill(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out, err = render(EXAMPLE, d)
            self.assertEqual(rc, 0, err)
            self.assertFalse(out["refreshed"])
            md, fp = skill_files(d)
            self.assertTrue(os.path.exists(md) and os.path.exists(fp))

    def test_second_run_without_force_exits_4(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(render(EXAMPLE, d)[0], 0)
            rc, _, _ = render(EXAMPLE, d)
            self.assertEqual(rc, 4)

    def test_force_refreshes_in_place_with_drift(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(render(EXAMPLE, d)[0], 0)
            # Bump a headline stat so drift is visible, then refresh.
            with open(EXAMPLE) as f:
                fp = json.load(f)
            fp["sample_size"] += 200
            bumped = os.path.join(d, "bumped.json")
            with open(bumped, "w") as f:
                json.dump(fp, f)
            rc, out, err = render(bumped, d, force=True)
            self.assertEqual(rc, 0, err)
            self.assertTrue(out["refreshed"])
            self.assertIn("drift", out)
            self.assertEqual(out["drift"]["sample_size"]["now"], fp["sample_size"])
            # The on-disk fingerprint was overwritten with the new sample size.
            _, fp_path = skill_files(d)
            with open(fp_path) as f:
                self.assertEqual(json.load(f)["sample_size"], fp["sample_size"])


if __name__ == "__main__":
    unittest.main()
