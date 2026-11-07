"""Self-tests for the CDE prototype.

    python3 -m unittest discover -s tools/cde -p 'test_*.py'

These test the machinery, not the model's validity. Validity needs human
grades; see PHASE-3-VALIDATION.md. What is tested here is that segmentation is
canonical, that non-prose is refused, that scores are deterministic, and that
the refusal path actually fires.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cde_model
import cde_text


class SegmentationTests(unittest.TestCase):
    def test_abbreviation_does_not_split(self):
        text = "Mr. Smith arrived at 9 a.m. and left. Nobody saw him."
        self.assertEqual(len(cde_text.split_sentences(text)), 2)

    def test_decimal_does_not_split(self):
        text = "The reading was 3.5 hours. That is too long."
        self.assertEqual(len(cde_text.split_sentences(text)), 2)

    def test_naive_split_overcounts(self):
        # The shipped analyzer splits on every period; this one must not.
        text = "Mr. Smith paid 4.5 pounds. Dr. Jones agreed. They left."
        self.assertEqual(len(cde_text.split_sentences(text)), 3)

    def test_syllables(self):
        self.assertEqual(cde_text.syllables("cat"), 1)
        self.assertEqual(cde_text.syllables("reading"), 2)


class ProseGateTests(unittest.TestCase):
    def test_table_of_contents_is_not_prose(self):
        toc = "\n".join(f"Chapter {i} .......... {i * 7}" for i in range(1, 80))
        self.assertFalse(cde_text.is_prose(toc))

    def test_narrative_is_prose(self):
        text = ("She walked to the window and looked out at the rain. "
                "It had been falling since morning, and the street was empty. "
                "Nobody had come to the door all day, which was unusual. ") * 3
        self.assertTrue(cde_text.is_prose(text))


class ModelTests(unittest.TestCase):
    def _config(self):
        return json.loads(json.dumps(cde_model.DEFAULT_CONFIG))

    def test_percentile_is_monotone(self):
        grid = [i / 100 for i in range(101)]
        a = cde_model.percentile(0.2, grid)
        b = cde_model.percentile(0.8, grid)
        self.assertLess(a, b)
        self.assertGreaterEqual(a, 0.0)
        self.assertLessEqual(b, 1.0)

    def test_refuses_below_minimum_windows(self):
        config = self._config()
        self.assertIsNone(cde_model.score_book([], config))

    def test_deterministic(self):
        config = self._config()
        config["reference"] = {d: [i / 100 for i in range(101)]
                               for d in cde_model.DIMENSIONS}
        windows = [
            {"tokens": 1200, "A_oov": 0.10 + i * 0.01, "A_morph": 0.2,
             "A_abstract": 0.1, "B_sentence": 18 + i, "B_clause": 1.2,
             "B_pronoun": 0.08, "B_passive": 0.1, "G_names": 2.0,
             "G_cooc": 0.4, "H_discontinuity": 0.7, "H_shift": 0.5,
             "H_orphan": 0.2, "I_content": 0.5, "I_novelty": 0.6,
             "I_np": 3.0, "K_quote": 0.2, "K_tagless": 0.3, "K_speakers": 2.0}
            for i in range(6)
        ]
        first = cde_model.score_book(windows, config)
        second = cde_model.score_book(windows, config)
        self.assertIsNotNone(first)
        self.assertEqual(first["score"], second["score"])
        self.assertEqual(first["interval"], second["interval"])


if __name__ == "__main__":
    unittest.main()
