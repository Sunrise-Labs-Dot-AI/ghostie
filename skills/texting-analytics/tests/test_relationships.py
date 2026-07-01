import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
sys.path.insert(0, SCRIPTS)

import relationships  # noqa: E402


class RelationshipsTests(unittest.TestCase):
    def test_contact_normalization_keeps_email_and_last_ten_phone_digits(self):
        self.assertEqual(relationships.norm_for_contacts("JAMES@EXAMPLE.COM"), "james@example.com")
        self.assertEqual(relationships.norm_for_contacts("+1 (415) 555-1212"), "4155551212")
        self.assertEqual(relationships.norm_for_contacts("262966"), "262966")

    def test_trajectory_marks_stale_zero_recent_relationship_dormant(self):
        day = relationships.DAY
        now = 500 * day
        person = {
            "sent": 50,
            "recv": 50,
            "first": 0,
            "last": 200 * day,
            "r90": 0,
        }

        label, ratio = relationships.trajectory(person, now)

        self.assertEqual(label, "dormant")
        self.assertEqual(ratio, 0)


if __name__ == "__main__":
    unittest.main()
