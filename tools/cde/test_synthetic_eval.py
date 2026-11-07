"""Synthetic harness invariants; no accuracy threshold is asserted."""
import copy
import unittest

import synthetic_eval as evaluation


class SyntheticEvaluationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dev = evaluation.prepare('development', 24, 101)
        cls.held = evaluation.prepare('holdout', 24, 102)

    def test_determinism_and_distinct_book_splits(self):
        self.assertEqual(self.dev, evaluation.prepare('development', 24, 101))
        self.assertTrue(set(b['id'] for b in self.dev['books']).isdisjoint(
            b['id'] for b in self.held['books']))
        self.assertTrue(set(t['reader'] for t in self.dev['truth']).isdisjoint(
            t['reader'] for t in self.held['truth']))

    def test_engine_view_cannot_see_outcomes(self):
        for row in self.dev['app_inputs']:
            self.assertEqual(set(row), {'id', 'target', 'remainingPages', 'history'})
            for history in row['history']:
                self.assertEqual(set(history), {'book', 'durations'})
        self.assertFalse(any('active_seconds' in row for row in self.dev['app_inputs']))

    def test_cde_sources_and_cold_start(self):
        records = {r['id']: r for r in self.dev['cde_predictions']}
        for truth in self.dev['truth']:
            record = records[truth['id']]
            if truth['regime'] == 'none':
                self.assertIsNone(record['candidate'])
                self.assertEqual(record['source'], 'insufficient_reader_history')
            elif truth['regime'] in ('same_book', 'sparse'):
                self.assertEqual(record['source'], 'same_book')
            else:
                self.assertEqual(record['source'], 'nearest_adf_profile')

    def test_worlds_include_navigation_and_sparse_history(self):
        worlds = {r['world'] for r in self.dev['truth']}
        self.assertIn('navigation', worlds)
        sparse = [r for r in self.dev['app_inputs'] if r['id'].startswith('development-reader-14-target-')]
        self.assertTrue(sparse)
        self.assertTrue(all(len(r['history'][-1]['durations']) == 2 for r in sparse))

    def test_changing_hidden_truth_does_not_change_inputs_or_predictions(self):
        changed = copy.deepcopy(self.dev)
        for row in changed['truth']:
            row['active_seconds'] *= 2
        self.assertEqual(changed['app_inputs'], self.dev['app_inputs'])
        self.assertEqual(changed['cde_predictions'], self.dev['cde_predictions'])

    def test_scorer_rejects_missing_extra_duplicate_and_bad_predictions(self):
        predictions = [{'id': row['id'], 'seconds': 100, 'status': 'synthetic'}
                       for row in self.dev['truth']]
        report = evaluation.score(self.dev, predictions)
        self.assertEqual(report['cases'], len(predictions))
        for bad in (predictions[:-1], predictions + [predictions[0]],
                    predictions + [{'id': 'unexpected', 'seconds': 1, 'status': 'x'}]):
            with self.assertRaises(ValueError):
                evaluation.score(self.dev, bad)
        bad = copy.deepcopy(predictions)
        bad[0]['seconds'] = float('nan')
        with self.assertRaises(ValueError):
            evaluation.score(self.dev, bad)

    def test_controls_include_equal_and_different_truth(self):
        truth = {r['id']: r for r in self.dev['truth']}
        a, b = (truth[f'development-control-equal-{i}'] for i in (0, 1))
        self.assertEqual(a['active_seconds'], b['active_seconds'])
        a, b = (truth[f'development-control-different-{i}'] for i in (0, 1))
        self.assertEqual(b['active_seconds'], 2 * a['active_seconds'])


if __name__ == '__main__':
    unittest.main()
