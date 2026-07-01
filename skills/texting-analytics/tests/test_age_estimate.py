import os
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
sys.path.insert(0, SCRIPTS)

import age_estimate  # noqa: E402


SCRIPT = os.path.join(SCRIPTS, "age_estimate.py")


class AgeEstimateTests(unittest.TestCase):
    def test_slang_and_reply_latency_do_not_fire_age_features(self):
        analysis = {
            "style": {
                "dominant_laugh": "haha",
                "pct_all_lowercase": 5,
                "pct_end_period": 45,
                "aging_slang_breakdown": {"lowkey": 99},
                "genz_slang_breakdown": {"rizz": 99},
            },
            "latency": {"median_minutes": 0.2},
        }

        fired = age_estimate.fired_features(analysis, total_sent=10_000)

        self.assertNotIn("aging_slang", fired)
        self.assertNotIn("current_genz_slang", fired)
        self.assertNotIn("fast_replies", fired)
        self.assertIn("proper_caps", fired)
        self.assertIn("period_end_short", fired)

    def test_emoji_and_volume_can_fire_age_features(self):
        analysis = {
            "style": {
                "active_days": 100,
                "genz_slang_breakdown": {},
                "aging_slang_breakdown": {},
            },
            "emoji": {"pct_messages_with_emoji": 42},
        }

        fired = age_estimate.fired_features(analysis, total_sent=6000)

        self.assertIn("inline_emoji_heavy", fired)
        self.assertIn("high_volume", fired)

    def run_script(self, analysis, *args):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(analysis, handle)
            path = handle.name
        try:
            return subprocess.run(
                [sys.executable, SCRIPT, "--analysis", path, *args],
                text=True,
                capture_output=True,
                check=False,
            )
        finally:
            os.unlink(path)

    def test_script_emits_evidence_count_for_explainable_age(self):
        analysis = {
            "style": {
                "dominant_laugh": "lol",
                "pct_all_lowercase": 5,
                "pct_end_period": 40,
                "aging_slang_breakdown": {},
                "genz_slang_breakdown": {},
                "sample_size": 900,
                "active_days": 90,
            },
            "emoji": {"pct_messages_with_emoji": 4},
            "latency": {"median_minutes": 30},
        }

        result = self.run_script(analysis, "--total-sent", "5000")

        self.assertEqual(result.returncode, 0, result.stderr)
        age = json.loads(result.stdout)["age"]
        self.assertGreaterEqual(age["evidence_count"], 3)
        self.assertGreaterEqual(age["sample_size"], 500)
        self.assertGreaterEqual(age["active_days"], 30)
        self.assertEqual(len(age["drivers"]), 3)
        self.assertIn("generation_scores", age)

    def test_script_omits_age_for_thin_samples(self):
        analysis = {
            "style": {
                "dominant_laugh": "joy",
                "pct_all_lowercase": None,
                "pct_end_period": None,
                "aging_slang_breakdown": {},
                "genz_slang_breakdown": {},
                "sample_size": 22,
                "active_days": 2,
            },
            "latency": {},
        }

        result = self.run_script(analysis)

        self.assertEqual(result.returncode, 2)
        self.assertIn("not enough outbound texts", result.stderr)

    def test_cohort_slang_breakdowns_never_fire_age_features(self):
        # The emoji_stats pass still emits all four cohort breakdowns (they
        # power other surfaces), but slang is calibrated OUT of age scoring:
        # tokens turn over every 12-36 months and are culture-confounded
        # (research/texting-personalization-calibration.md).
        analysis = {
            "style": {
                "genx_slang_breakdown": {"hella": 99},
                "boomer_slang_breakdown": {"groovy": 99, "far out": 99},
            },
            "latency": {},
        }

        fired = age_estimate.fired_features(analysis, total_sent=None)

        self.assertNotIn("genx_slang", fired)
        self.assertNotIn("boomer_slang", fired)


if __name__ == "__main__":
    unittest.main()
