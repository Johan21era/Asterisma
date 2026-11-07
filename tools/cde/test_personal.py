"""Tests for the experimental personalized reading-time model."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import cde_model
import cde_personal


class PersonalPredictionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "sessions.json"
        self.profiles = {
            "a": {d: 0.1 for d in cde_model.DIMENSIONS},
            "b": {d: 0.9 for d in cde_model.DIMENSIONS},
            "target": {d: 0.15 for d in cde_model.DIMENSIONS},
        }
        self.rows = [
            {"id": "a1", "reader_id": "john", "book_id": "a",
             "start": "2026-01-01T10:00:00Z", "end": "2026-01-01T10:10:00Z",
             "words_read": 1000, "active_seconds": 600},
            {"id": "b1", "reader_id": "john", "book_id": "b",
             "start": "2026-01-02T10:00:00Z", "end": "2026-01-02T10:20:00Z",
             "words_read": 1000, "active_seconds": 1200},
            {"id": "ava1", "reader_id": "ava", "book_id": "a",
             "start": "2026-01-01T10:00:00Z", "end": "2026-01-01T10:20:00Z",
             "words_read": 1000, "active_seconds": 1200},
        ]

    def load(self, rows=None):
        self.path.write_text(json.dumps(self.rows if rows is None else rows))
        return cde_personal.load_sessions(self.path)

    def test_nearest_adf_book_and_reader_isolation(self):
        sessions = self.load()
        result = cde_personal.predict(sessions, self.profiles, "john", "target", 1000,
                                      "2026-01-03T00:00:00Z")
        self.assertEqual(result["baseline_seconds"], 900)
        self.assertEqual(result["candidate_seconds"], 600)
        self.assertEqual(result["candidate_source"], "nearest_adf_profile")
        self.assertEqual(result["candidate_source_book"], "a")
        ava = cde_personal.predict(sessions, self.profiles, "ava", "target", 1000,
                                   "2026-01-03T00:00:00Z")
        self.assertEqual(ava["candidate_seconds"], 1200)

    def test_same_book_and_future_data_exclusion(self):
        sessions = self.load()
        first = cde_personal.predict(sessions, self.profiles, "john", "b", 1000,
                                     "2026-01-02T10:00:00Z")
        self.assertEqual(first["candidate_seconds"], 600)
        later = cde_personal.predict(sessions, self.profiles, "john", "b", 1000,
                                     "2026-01-03T00:00:00Z")
        self.assertEqual(later["candidate_seconds"], 1200)
        self.assertEqual(later["candidate_source"], "same_book")
        missing = cde_personal.predict(sessions, self.profiles, "new", "b", 1000,
                                       "2026-01-03T00:00:00Z")
        self.assertEqual(missing["status"], "insufficient_reader_history")
        self.assertIsNone(missing["candidate_seconds"])

    def test_later_observations_change_reader_pace_without_changing_book_profile(self):
        sessions = self.load()
        before = cde_personal.predict(sessions, self.profiles, "john", "target", 1000,
                                       "2026-01-02T00:00:00Z")
        after = cde_personal.predict(sessions, self.profiles, "john", "target", 1000,
                                      "2026-08-03T00:00:00Z")
        self.assertEqual(before["baseline_seconds"], 600)
        self.assertEqual(after["baseline_seconds"], 900)
        self.assertEqual(before["candidate_seconds"], after["candidate_seconds"])
        self.assertEqual(before["formula"], after["formula"])

    def test_missing_profile_uses_baseline(self):
        result = cde_personal.predict(self.load(), self.profiles, "john", "missing", 1000,
                                      "2026-01-03T00:00:00Z")
        self.assertEqual(result["candidate_source"], "reader_baseline")
        self.assertEqual(result["candidate_seconds"], result["baseline_seconds"])

    def test_invalid_session_rejected(self):
        for field, value in (("words_read", 0), ("active_seconds", 601),
                             ("start", "2026-01-01T10:00:00")):
            row = dict(self.rows[0], **{field: value})
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    self.load([row])
        with self.assertRaises(ValueError):
            self.load([self.rows[0], self.rows[0]])

    def test_evaluation_is_chronological(self):
        result = cde_personal.evaluate(self.load(), self.profiles)
        self.assertEqual(result["sessions"], 3)
        self.assertEqual(result["evaluated"], 1)
        self.assertEqual(result["skipped_no_prior_history"], 2)
        self.assertEqual(result["predictions"][0]["baseline_seconds"], 600)
        self.assertEqual(result["predictions"][0]["actual_seconds"], 1200)

    def test_cli_with_real_adf_scores_and_synthetic_sessions(self):
        root = Path(__file__).resolve().parents[2]
        scores = root / "docs/audits/evidence/adf-149-scores-2026-10-29.json"
        profiles = cde_personal.load_profiles(scores)
        book_ids = sorted(profiles)
        rows = [dict(self.rows[0], book_id=book_ids[0]),
                dict(self.rows[1], book_id=book_ids[1])]
        self.path.write_text(json.dumps(rows))
        result = subprocess.run(
            [sys.executable, str(root / "tools/cde/cde_personal.py"), "evaluate",
             "--scores", str(scores), "--sessions", str(self.path)],
            capture_output=True, text=True, check=True,
        )
        report = json.loads(result.stdout)
        self.assertEqual(report["evaluated"], 1)
        self.assertEqual(report["adf_matched"]["count"], 1)
        self.assertEqual(report["predictions"][0]["baseline_seconds"], 600)

    def test_sheet_profiles_and_conflicting_duplicates(self):
        path = Path(self.temp.name) / "scores.json"
        row = {"status": "ok", "digest": "a", "dimensions": self.profiles["a"]}
        path.write_text(json.dumps({"summary": {"formula": cde_model.FORMULA_ID},
                                    "rows": [row, dict(row)]}))
        self.assertEqual(cde_personal.load_profiles(path), {"a": self.profiles["a"]})
        conflicting = dict(row, dimensions=self.profiles["b"])
        path.write_text(json.dumps({"summary": {"formula": cde_model.FORMULA_ID},
                                    "rows": [row, conflicting]}))
        with self.assertRaises(ValueError):
            cde_personal.load_profiles(path)



if __name__ == "__main__":
    unittest.main()
