import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
sys.path.insert(0, SCRIPTS)

import analyze  # noqa: E402


def event(thread_id, from_me, ts_ms, text_len, kind="text", sender_key=None):
    return {
        "platform": "imessage",
        "thread_id": thread_id,
        "event_id": f"{thread_id}-{ts_ms}-{from_me}",
        "sender_key": sender_key,
        "from_me": from_me,
        "ts_ms": ts_ms,
        "kind": kind,
        "text_len": text_len,
    }


class TextingAnalyticsAnalyzeTests(unittest.TestCase):
    def test_business_threads_are_pattern_filtered(self):
        threads = {
            "person": {"thread_id": "person", "is_group": False, "display_name": "Alice"},
            "alerts": {"thread_id": "alerts", "is_group": False, "display_name": "ALERTS"},
        }
        events = [
            event("person", False, 1, 20, sender_key="+15551234567"),
            event("alerts", False, 2, 20, sender_key="ALERTS"),
        ]

        self.assertEqual(analyze.business_thread_ids(threads, events), {"alerts"})

    def test_talk_listen_highlights_are_distinct_and_material(self):
        threads = {
            "balanced": {"thread_id": "balanced", "is_group": False, "display_name": "Balanced"},
            "talk": {"thread_id": "talk", "is_group": False, "display_name": "Talk"},
            "listen": {"thread_id": "listen", "is_group": False, "display_name": "Listen"},
        }
        events = [
            event("balanced", True, 1, 508),
            event("balanced", False, 2, 492),
            event("talk", True, 3, 800),
            event("talk", False, 4, 200),
            event("listen", True, 5, 250),
            event("listen", False, 6, 750),
        ]

        out = analyze.talk_listen_block(threads, events)

        self.assertEqual(out["highlights"]["most_balanced"]["name"], "Balanced")
        self.assertEqual(out["highlights"]["most_you_talk"]["name"], "Talk")
        self.assertEqual(out["highlights"]["most_you_listen"]["name"], "Listen")
        names = [row["name"] for row in out["highlights"].values() if row]
        self.assertEqual(len(names), len(set(names)))

    def test_talk_listen_does_not_promote_barely_balanced_thread_to_skew(self):
        threads = {
            "balanced": {"thread_id": "balanced", "is_group": False, "display_name": "Balanced"},
        }
        events = [
            event("balanced", True, 1, 508),
            event("balanced", False, 2, 492),
        ]

        out = analyze.talk_listen_block(threads, events)

        self.assertEqual(out["highlights"]["most_balanced"]["name"], "Balanced")
        self.assertIsNone(out["highlights"]["most_you_talk"])
        self.assertIsNone(out["highlights"]["most_you_listen"])

    def test_group_worst_offender_not_lost_to_chart_truncation(self):
        threads = {}
        events = []
        for idx in range(14):
            tid = f"group-{idx}"
            threads[tid] = {
                "thread_id": tid,
                "is_group": True,
                "display_name": f"Group {idx}",
                "participant_count": 6,
            }
            user_count = 0 if idx == 13 else idx + 1
            for n in range(user_count):
                events.append(event(tid, True, idx * 1000 + n, 10))
            for n in range(30 - user_count):
                events.append(event(tid, False, idx * 1000 + 100 + n, 10))

        out = analyze.group_block(threads, events, min_msgs=20)

        self.assertEqual(out["worst_offender"]["thread_label"], "Group 13")
        self.assertEqual(out["worst_offender"]["user_count"], 0)


if __name__ == "__main__":
    unittest.main()
