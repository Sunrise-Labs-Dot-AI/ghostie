import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "wrapped"))

import build_wrapped  # noqa: E402


def arch(median=10, mean=20, fast=40, ball=50, group_pct=10, silent=1,
         total_groups=10, emoji_pct=20.0):
    return build_wrapped.derive_archetype(
        median, mean, fast, ball, group_pct, silent, total_groups, emoji_pct)["name"]


class DeriveArchetypeTests(unittest.TestCase):
    def test_priority_ordered_selection(self):
        self.assertEqual(arch(group_pct=0.7, silent=12, total_groups=15), "The Group Chat Ghost")
        self.assertEqual(arch(group_pct=51.2), "The Town Crier")
        self.assertEqual(arch(median=1, fast=82), "The Lightning Round")
        self.assertEqual(arch(ball=12, median=22), "Left-on-Read Royalty")
        self.assertEqual(arch(ball=88), "The Last Word")
        self.assertEqual(arch(ball=62, fast=68, median=2.5, mean=7), "The Ping-Pong Pro")
        self.assertEqual(arch(group_pct=33, median=6, ball=45), "The Group MVP")
        self.assertEqual(arch(emoji_pct=52.0, median=5, mean=12, ball=40), "The Emoji Maximalist")
        self.assertEqual(arch(emoji_pct=0.8, median=18, mean=30, ball=42), "The Deadpan")
        self.assertEqual(arch(median=50, mean=240, ball=40), "The Sorry-Just-Saw-This")
        self.assertEqual(arch(median=95, mean=120, ball=44), "The Slow Burn")
        self.assertEqual(arch(median=4, mean=77, ball=44), "The Fast Starter")
        self.assertEqual(arch(median=2.5, mean=8, fast=72, ball=45), "The Quick Draw")
        self.assertEqual(arch(median=6, mean=14, ball=44, group_pct=5.5, silent=6), "The VIP Room")
        self.assertEqual(arch(median=12, mean=25, ball=42, group_pct=4, silent=3, total_groups=14), "The Quiet Lurker")
        self.assertEqual(arch(median=12, mean=25, ball=28, group_pct=21), "The Main Stage")
        self.assertEqual(arch(median=12, mean=24, ball=52, group_pct=11), "The Diplomat")
        self.assertEqual(arch(median=35, mean=50, ball=66), "The Steady Hand")

    def test_table_has_at_least_16_distinct_archetypes(self):
        names = {
            arch(group_pct=0.7, silent=12, total_groups=15),
            arch(group_pct=51.2),
            arch(median=1, fast=82),
            arch(ball=12, median=22),
            arch(ball=88),
            arch(ball=62, fast=68, median=2.5, mean=7),
            arch(group_pct=33, median=6, ball=45),
            arch(emoji_pct=52.0, median=5, mean=12, ball=40),
            arch(emoji_pct=0.8, median=18, mean=30, ball=42),
            arch(median=50, mean=240, ball=40),
            arch(median=95, mean=120, ball=44),
            arch(median=4, mean=77, ball=44),
            arch(median=2.5, mean=8, fast=72, ball=45),
            arch(median=6, mean=14, ball=44, group_pct=5.5, silent=6),
            arch(median=12, mean=25, ball=42, group_pct=4, silent=3, total_groups=14),
            arch(median=12, mean=25, ball=28, group_pct=21),
            arch(median=12, mean=24, ball=52, group_pct=11),
            arch(median=35, mean=50, ball=66),
        }
        self.assertGreaterEqual(len(names), 16)

    def test_missing_emoji_block_never_fires_emoji_archetypes(self):
        # emoji_pct=None means "no emoji pass ran" — must NOT read as 0% and
        # crown everyone The Deadpan.
        name = build_wrapped.derive_archetype(18, 30, 24, 42, 12, 1, 10, None)["name"]
        self.assertNotIn(name, ("The Deadpan", "The Emoji Maximalist"))

    def test_why_strings_carry_the_real_numbers(self):
        a = build_wrapped.derive_archetype(8, 90, 44, 60, 0.7, 12, 15, None)
        self.assertEqual(a["why"], "0.7% group share, silent in 12 of 15 groups.")
        royalty = build_wrapped.derive_archetype(22, 40, 24, 12, 9, 2, 11, None)
        self.assertIn("only 12% of threads", royalty["why"])
        self.assertIn("88% are parked on your reply", royalty["why"])

    def test_context_keyed_archetypes_fire_between_distinct_reads_and_fallbacks(self):
        base = dict(median=18, mean=30, fast=22, ball=50, group_pct=22,
                    silent=1, total_groups=12, emoji_pct=23)

        def with_ctx(ctx):
            return build_wrapped.derive_archetype(
                base["median"], base["mean"], base["fast"], base["ball"],
                base["group_pct"], base["silent"], base["total_groups"],
                base["emoji_pct"], ctx)["name"]

        self.assertEqual(with_ctx({"reactionRate": 52}), "The Reaction Regular")
        self.assertEqual(with_ctx({"totalSent": 10000, "threadCount": 70,
                                   "topPeople": [{"count": 1200}]}), "The Social Connector")
        self.assertEqual(with_ctx({"totalSent": 3000,
                                   "topPeople": [{"count": 1000}]}), "The Inner-Circle Texter")
        self.assertEqual(with_ctx({"totalSent": 18000}), "The High-Volume Texter")
        # No context → the generic middle bucket, untouched.
        self.assertEqual(with_ctx(None), "The Diplomat")

    def test_archetype_includes_personalized_drivers(self):
        out = build_wrapped.derive_archetype(4, 77, 47, 60, 8.8, 2, 19, 23)
        self.assertEqual(out["name"], "The Fast Starter")
        self.assertEqual(out["drivers"], ["4 min median reply", "77 min mean reply", "47% within five"])
        self.assertEqual(out["support_level"], "supported")

    def test_archetype_marks_weak_ball_in_court_reads_as_playful(self):
        # ball >= 80 means the USER had the last word in 82% of threads
        # (analyze.py semantics) — a read-state-dependent roast, marked playful.
        out = build_wrapped.derive_archetype(9, 30, 40, 82, 12, 3, 14, 0)
        self.assertEqual(out["name"], "The Last Word")
        self.assertEqual(out["support_level"], "playful")
        self.assertEqual(out["confidence"], "low")

    def test_build_data_suppresses_weak_age_block(self):
        analysis = {
            "latency": {"median_minutes": 5, "mean_minutes": 30, "pct_within_5min": 40},
            "ball_in_court": {"pct_ball_in_court": 50},
            "group_contribution": {
                "user_contribution_pct": 15,
                "groups_where_user_silent": 2,
                "total_groups_analyzed": 10,
            },
            "age": {
                "estimated_age": 35,
                "band": "millennial",
                "label": "Millennial",
                "approx_age": "28-43",
                "confidence": "low",
                "drivers": [],
                "sample_size": 22,
                "evidence_count": 1,
            },
            "filters": {"window_days": 0, "since_ts_ms": 0, "until_ts_ms": 1780272000000},
        }
        data = build_wrapped.build_data(analysis, 2026, None, True)
        self.assertNotIn("age", data["cards"])
        self.assertNotIn("age", data)

    def test_build_data_passes_none_emoji_when_block_missing(self):
        analysis = {
            "latency": {"median_minutes": 18, "mean_minutes": 30, "pct_within_5min": 24},
            "ball_in_court": {"pct_ball_in_court": 42},
            "group_contribution": {"user_contribution_pct": 12,
                                   "groups_where_user_silent": 1,
                                   "total_groups_analyzed": 10},
            "filters": {"window_days": 365, "since_ts_ms": 1, "until_ts_ms": 2},
        }
        data = build_wrapped.build_data(analysis, 2026, None, show_people=True)
        self.assertNotEqual(data["archetype"]["name"], "The Deadpan")
        self.assertNotIn("emoji", data["cards"])


class SafeJsonTests(unittest.TestCase):
    def test_script_breakout_is_neutralized_and_round_trips(self):
        import json
        payload = '</script><img src=x onerror="alert(1)">'
        s = build_wrapped.safe_json({"name": payload})
        self.assertNotIn("</script", s)
        self.assertEqual(json.loads(s), {"name": payload})


if __name__ == "__main__":
    unittest.main()
