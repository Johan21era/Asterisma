import unittest

import adversarial_eval as evaluation


class AdversarialTests(unittest.TestCase):
    def test_opaque_reproducible_and_disjoint(self):
        cases, truth = evaluation.generate('development', 37)
        self.assertEqual((cases, truth), evaluation.generate('development', 37))
        other, _ = evaluation.generate('evaluation', 81)
        self.assertEqual(len(cases), 8)
        self.assertTrue(all(len(row['id']) == 16 and all(c in '0123456789abcdef' for c in row['id']) for row in cases))
        self.assertTrue({row['id'] for row in cases}.isdisjoint(row['id'] for row in other))
        self.assertTrue(any(any(a > b for a, b in zip(s['pages'], s['pages'][1:]))
                            for r in cases for s in r['history']))
        self.assertTrue(all('active_seconds' not in row for row in cases))

    def test_corpus_split_and_distinct_scenarios(self):
        groups = evaluation.corpus_split()
        self.assertEqual(sum(map(len, groups.values())), 149)
        self.assertTrue({r['digest'] for r in groups['development']}.isdisjoint(
            r['digest'] for r in groups['evaluation']))
        for split, expected_scenarios in [('development', 12), ('evaluation', 6)]:
            inputs, truth = evaluation.generate_corpus(split, 19, 2)
            self.assertEqual(len(inputs), 2 * len(groups[split]))
            self.assertEqual(len({r['id'] for r in inputs}), len(inputs))
            self.assertEqual(len({r['scenario'] for r in truth}), expected_scenarios)
            self.assertTrue(all('active_seconds' not in r for r in inputs))
            self.assertEqual((inputs, truth), evaluation.generate_corpus(split, 19, 2))

    def test_restart_at_first_spike_and_strict_predictions(self):
        cases, truth = evaluation.generate('development', 37)
        preds = [{'id': t['id'], 'baseline': t['active_seconds'] * 2,
                  'filtered': t['active_seconds'], 'guarded': t['active_seconds'], 'recent': t['active_seconds'],
                  'blend': t['active_seconds']} for t in truth]
        cut = evaluation.grade(cases, truth, preds, 'baseline', stop_at_spike=True)
        self.assertEqual(len(cut), 1)
        self.assertEqual(cut[0]['position'], 1)
        full = evaluation.grade(cases, truth, preds, 'filtered', stop_at_spike=True)
        self.assertEqual(len(full), 8)
        self.assertFalse(any(row['spike'] for row in full))
        with self.assertRaises(ValueError):
            evaluation.grade(cases, truth, preds[:-1], 'baseline')


if __name__ == '__main__':
    unittest.main()
