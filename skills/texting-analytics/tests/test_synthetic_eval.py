"""Synthetic-persona eval: real metric pipeline over fabricated chat.dbs.

For every persona in synthetic_chatdb.PERSONAS this builds a chat.db-shaped
sqlite fixture, then runs the ACTUAL pipeline the skill ships:

    adapters/imessage_chatdb.py  (chat.db → normalized export)
      → scripts/analyze.py       (export → analysis.json, past-year window)
      → scripts/emoji_stats.py   (bodies → aggregate emoji/style, guarded)
      → scripts/age_estimate.py  (style → playful age block, optional)
      → wrapped/build_wrapped.py derive_archetype (via build_data)

and asserts:
  (a) nothing crashes (every subprocess exits cleanly),
  (b) the archetype distribution across personas covers >= 10 distinct
      archetypes (the table must SPREAD, not funnel into the fallback),
  (c) each persona lands on its expected archetype,
plus determinism (two builds of the same persona produce identical exports)
and the no-bodies privacy invariant on the emoji/style output.

All fixture data is synthetic (see synthetic_chatdb.py). No real data.
"""

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

TESTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TESTS)
SCRIPTS = os.path.join(ROOT, "scripts")
WRAPPED = os.path.join(ROOT, "wrapped")
sys.path.insert(0, TESTS)
sys.path.insert(0, WRAPPED)

import build_wrapped  # noqa: E402  (wrapped/build_wrapped.py)
import synthetic_chatdb  # noqa: E402


def run_checked(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise AssertionError(f"pipeline step failed ({out.returncode}): {cmd}\n{out.stderr}")
    return out


def export_bodies(db_path):
    """Outbound message bodies straight from the fixture (the eval stand-in for
    the MCP body pull). Synthetic text only."""
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = con.execute("SELECT text, is_from_me FROM message ORDER BY ROWID").fetchall()
    con.close()
    return [{"text": t, "from_me": bool(f), "kind": "text"} for t, f in rows if t]


def run_pipeline(workdir, persona):
    """chat.db fixture → analysis dict with emoji/style merged. Returns
    (analysis, emoji_stats_stdout)."""
    db = os.path.join(workdir, f"{persona}.db")
    synthetic_chatdb.build_chatdb(db, persona)

    export = os.path.join(workdir, f"{persona}-export.json")
    run_checked([sys.executable, os.path.join(SCRIPTS, "adapters", "imessage_chatdb.py"),
                 "--db", db, "--all-time", "--output", export])

    analysis_path = os.path.join(workdir, f"{persona}-analysis.json")
    run_checked([sys.executable, os.path.join(SCRIPTS, "analyze.py"),
                 "--input", export, "--output", analysis_path, "--window-days", "365"])
    with open(analysis_path) as f:
        analysis = json.load(f)

    bodies_path = os.path.join(workdir, f"{persona}-bodies.json")
    with open(bodies_path, "w") as f:
        json.dump(export_bodies(db), f)
    emoji_out = run_checked([sys.executable, os.path.join(SCRIPTS, "emoji_stats.py"),
                             "--input", bodies_path, "--outbound-only"])
    merged = json.loads(emoji_out.stdout)
    analysis.update(merged)

    # Age pass: exit 0 (block) or exit 2 (no observable features) are both
    # clean outcomes; anything else is a crash.
    with open(analysis_path, "w") as f:
        json.dump(analysis, f)
    age = subprocess.run([sys.executable, os.path.join(SCRIPTS, "age_estimate.py"),
                          "--analysis", analysis_path],
                         capture_output=True, text=True)
    if age.returncode not in (0, 2):
        raise AssertionError(f"age_estimate crashed ({age.returncode}): {age.stderr}")

    return analysis, emoji_out.stdout


def archetype_of(analysis):
    data = build_wrapped.build_data(analysis, 2026, None, show_people=True)
    return data["archetype"]["name"]


class SyntheticEvalTests(unittest.TestCase):
    maxDiff = None
    results = None

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.results = {}
        cls.outputs = {}
        for persona in synthetic_chatdb.PERSONAS:
            analysis, emoji_stdout = run_pipeline(cls.tmp.name, persona)
            cls.results[persona] = analysis
            cls.outputs[persona] = emoji_stdout

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_per_persona_expected_archetype(self):
        mismatches = []
        for persona, cfg in synthetic_chatdb.PERSONAS.items():
            got = archetype_of(self.results[persona])
            if got != cfg["expected"]:
                lat = self.results[persona].get("latency", {})
                bic = self.results[persona].get("ball_in_court", {})
                grp = self.results[persona].get("group_contribution", {})
                emo = self.results[persona].get("emoji", {})
                mismatches.append(
                    f"{persona}: got {got!r}, expected {cfg['expected']!r} "
                    f"(median={lat.get('median_minutes')}, mean={lat.get('mean_minutes')}, "
                    f"fast={lat.get('pct_within_5min')}, ball={bic.get('pct_ball_in_court')}, "
                    f"group={grp.get('user_contribution_pct')}, "
                    f"silent={grp.get('groups_where_user_silent')}/{grp.get('total_groups_analyzed')}, "
                    f"emoji={emo.get('pct_messages_with_emoji')})")
        self.assertEqual(mismatches, [], "\n" + "\n".join(mismatches))

    def test_distribution_spreads_across_at_least_10_archetypes(self):
        names = {archetype_of(a) for a in self.results.values()}
        self.assertGreaterEqual(
            len(names), 10,
            f"archetype distribution collapsed to {len(names)}: {sorted(names)}")

    def test_fixture_build_is_deterministic(self):
        p1 = os.path.join(self.tmp.name, "det-a.db")
        p2 = os.path.join(self.tmp.name, "det-b.db")
        synthetic_chatdb.build_chatdb(p1, "quick_quinn")
        synthetic_chatdb.build_chatdb(p2, "quick_quinn")
        dump = lambda p: list(sqlite3.connect(p).iterdump())
        self.assertEqual(dump(p1), dump(p2))

    def test_slang_cohort_counts_surface_without_bodies(self):
        style = self.results["quick_quinn"]["style"]
        self.assertGreaterEqual(style["genz_slang_breakdown"].get("no cap", 0), 8)
        self.assertGreaterEqual(style["genz_slang_breakdown"].get("rizz", 0), 8)
        boomer = self.results["steady_sasha"]["style"]["boomer_slang_breakdown"]
        self.assertGreaterEqual(boomer.get("groovy", 0), 8)
        self.assertGreaterEqual(boomer.get("far out", 0), 8)
        # No-bodies invariant: no multi-word synthetic body line shows up in
        # the emoji/style output (token labels are the documented exception).
        for persona, stdout in self.outputs.items():
            for body in synthetic_chatdb.SYNTH_BODIES:
                if " " in body:
                    self.assertNotIn(body, stdout, f"body leaked for {persona}")

    def test_dual_window_build_data_runs_for_every_persona(self):
        # The wrapped pipeline always renders past-year AND all-time datasets;
        # build_data must not crash on either for any persona.
        for persona, analysis in self.results.items():
            data = build_wrapped.build_data(analysis, 2026, None, show_people=True)
            self.assertIn("archetype", data)
            all_time = dict(analysis)
            all_time["filters"] = dict(analysis.get("filters") or {},
                                       window_days=0, since_ts_ms=0)
            data_all = build_wrapped.build_data(all_time, 2026, None, show_people=True)
            self.assertEqual(data_all["windowLabel"], "All time")


if __name__ == "__main__":
    unittest.main()
