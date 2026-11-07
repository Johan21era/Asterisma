import unittest

import fresh_100


class FreshRoundTests(unittest.TestCase):
    def test_fresh_rounds_are_reproducible_distinct_and_hide_truth(self):
        inputs, truth = fresh_100.generate(1)
        repeated = fresh_100.generate(1)
        other_inputs, other_truth = fresh_100.generate(2)
        self.assertEqual((inputs, truth), repeated)
        self.assertEqual(len(inputs), 9914)
        self.assertEqual(len(truth), len(inputs))
        self.assertEqual({row['id'] for row in inputs}, {row['id'] for row in truth})
        self.assertEqual(len({row['id'] for row in inputs}), len(inputs))
        self.assertTrue({row['id'] for row in inputs}.isdisjoint(row['id'] for row in other_inputs))
        self.assertTrue(all('active_seconds' not in row for row in inputs))
        self.assertEqual({row['round'] for row in truth}, {1})
        self.assertEqual({row['round'] for row in other_truth}, {2})
        counts = {group: sum(row['group'] == group for row in truth)
                  for group in {row['group'] for row in truth}}
        self.assertEqual(counts, {'corpus-development': 234, 'corpus-evaluation': 64,
                                  'adversarial': 8, 'synthetic-development': 4004,
                                  'synthetic-holdout': 5604})


if __name__ == '__main__':
    unittest.main()
