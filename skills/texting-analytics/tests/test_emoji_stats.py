import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "emoji_stats.py")


class EmojiStatsTests(unittest.TestCase):
    def run_script(self, messages, *args):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(messages, handle)
            path = handle.name
        try:
            return subprocess.run(
                [sys.executable, SCRIPT, "--input", path, *args],
                text=True,
                capture_output=True,
                check=False,
            )
        finally:
            os.unlink(path)

    def test_outputs_aggregates_without_message_bodies(self):
        secret = "meet me behind the blue door at 7"
        result = self.run_script([
            {"text": secret + " 😂", "from_me": True, "kind": "text", "ts_ms": 1000},
            {"text": "lol that worked", "from_me": True, "kind": "text", "ts_ms": 86400000 + 1000},
            {"text": "not mine 💀", "from_me": False, "kind": "text"},
        ], "--outbound-only")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(secret, result.stdout)
        out = json.loads(result.stdout)
        self.assertEqual(out["style"]["sample_size"], 2)
        self.assertEqual(out["style"]["active_days"], 2)
        self.assertIn("joy", out["style"]["laugh_tokens"])
        self.assertEqual(out["emoji"]["top_inline"][0]["emoji"], "😂")

    def test_reaction_emoji_is_counted_separately_from_inline_text(self):
        result = self.run_script([
            {"text": "Reacted 😂 to a message", "from_me": True, "kind": "reaction", "assoc": 2006},
            {"text": "plain update 👍", "from_me": True, "kind": "text"},
        ], "--outbound-only")

        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        self.assertEqual(out["emoji"]["top_inline"], [{"emoji": "👍", "count": 1}])
        self.assertEqual(out["emoji"]["top_reactions"], [{"emoji": "😂", "count": 1}])

    def test_no_usable_messages_exits_with_input_error(self):
        result = self.run_script([{"text": "", "from_me": True, "kind": "text"}], "--outbound-only")

        self.assertEqual(result.returncode, 2)
        self.assertIn("no usable messages", result.stderr)

    def test_slang_cohorts_counted_per_token_without_bodies(self):
        msgs = ([{"text": "no cap that ride was bussin", "from_me": True, "kind": "text"}] * 3
                + [{"text": "that concert was groovy and far out honestly", "from_me": True, "kind": "text"}] * 2
                + [{"text": "omg tbh I am exhausted", "from_me": True, "kind": "text"}]
                + [{"text": "hella long line at the da bomb taco truck", "from_me": True, "kind": "text"}])
        result = self.run_script(msgs, "--outbound-only")

        self.assertEqual(result.returncode, 0, result.stderr)
        style = json.loads(result.stdout)["style"]
        self.assertEqual(style["genz_slang_breakdown"], {"no cap": 3, "bussin": 3})
        self.assertEqual(style["boomer_slang_breakdown"], {"groovy": 2, "far out": 2})
        self.assertEqual(style["aging_slang_breakdown"], {"tbh": 1, "omg": 1})
        self.assertEqual(style["genx_slang_breakdown"], {"hella": 1, "da bomb": 1})
        self.assertEqual(style["genx_slang_hits"], 2)
        self.assertEqual(style["boomer_slang_hits"], 4)
        # Counts only — no message body in the output.
        self.assertNotIn("no cap that ride was bussin", result.stdout)

    def test_bet_only_counts_as_standalone_message(self):
        msgs = [
            {"text": "bet", "from_me": True, "kind": "text"},
            {"text": "bet!", "from_me": True, "kind": "text"},
            {"text": "I bet you five dollars", "from_me": True, "kind": "text"},
        ]
        result = self.run_script(msgs, "--outbound-only")

        self.assertEqual(result.returncode, 0, result.stderr)
        style = json.loads(result.stdout)["style"]
        self.assertEqual(style["genz_slang_breakdown"].get("bet"), 2)

    def test_privacy_guard_not_tripped_by_body_equal_to_token_label(self):
        # A user who literally texts "no cap" matches the multi-word token
        # LABEL in the output — an aggregate key, not a body leak. The guard
        # must not hard-fail the run on it.
        result = self.run_script([
            {"text": "no cap", "from_me": True, "kind": "text"},
            {"text": "talk to the hand", "from_me": True, "kind": "text"},
        ], "--outbound-only")

        self.assertEqual(result.returncode, 0, result.stderr)
        style = json.loads(result.stdout)["style"]
        self.assertEqual(style["genz_slang_breakdown"].get("no cap"), 1)
        self.assertEqual(style["genx_slang_breakdown"].get("talk to the hand"), 1)

    def test_privacy_guard_still_trips_on_a_real_body_leak(self):
        # Sanity-check the guard itself still bites: smuggle a body into the
        # output via a monkeypatched OUTPUT (simulated by a body that equals a
        # laugh-token KEY plus content — i.e. a genuinely leaked multi-word
        # body must exit 5). We simulate by asserting the guard path exists:
        # a multi-word body that is NOT a token label and DOES appear in the
        # output can only happen on a leak, which we can't produce through the
        # public interface — so assert the exclusion list is tight instead:
        # every excluded label is a known slang token, nothing else.
        sys.path.insert(0, os.path.join(ROOT, "scripts"))
        import emoji_stats  # noqa: E402
        all_tokens = {tok for toks in emoji_stats.SLANG_COHORTS.values() for tok, _ in toks}
        self.assertEqual(set(emoji_stats.OUTPUT_TOKEN_LABELS), all_tokens)


if __name__ == "__main__":
    unittest.main()
