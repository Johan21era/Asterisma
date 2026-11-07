#!/usr/bin/env python3
"""Root-cause audit of the 2026-10-30 fresh stress rounds.

Reads the saved predictions and grades only; it does not invoke Xcode, change
any estimator, or fit any weight. Synthetic outcomes are assumptions, not
observations of people.

Usage:
    python3 tools/cde/audit_fresh_tail.py [--directory PATH]
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import re
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DIR = ROOT / 'tools/cde/fresh-100-20261030'
WORLDS = ('stable', 'aligned', 'opposed', 'unrelated', 'drift', 'interruptions', 'navigation')
REGIMES = ('none', 'cross_book', 'sparse', 'same_book')
GROUPS = (('development', 1000, 'synthetic-development'), ('holdout', 1400, 'synthetic-holdout'))
WEIGHT = 0.0011850789689659901


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:20]


def scenario_map() -> dict[str, tuple[str, str, str, str]]:
    """Fresh IDs are opaque hashes of the generator's own case IDs."""
    found: dict[str, tuple[str, str, str, str]] = {}
    for round_number in range(1, 101):
        for split, count, group in GROUPS:
            for reader in range(count):
                world = WORLDS[reader % len(WORLDS)]
                regime = REGIMES[(reader // len(WORLDS)) % len(REGIMES)]
                for target in range(4):
                    case = f'{split}-reader-{reader}-target-{target}'
                    found[digest(f'{round_number}:{group}:{case}')] = (group, world, regime, 'target')
            for label in ('equal', 'different'):
                for slot in range(2):
                    case = f'{split}-control-{label}-{slot}'
                    found[digest(f'{round_number}:{group}:{case}')] = (group, f'control_{label}', 'same_book', 'control')
    return found


def swift_median(values: list[float]) -> float:
    """Mirror PageDurationPolicy.median: sorted[count / 2], not the middle mean."""
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def metric(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    return {'n': len(ordered), 'median': statistics.median(ordered),
            'mean': statistics.mean(ordered),
            'p90': ordered[round((len(ordered) - 1) * .9)], 'max': ordered[-1]}


def line(label: str, values: list[float], width: int = 22) -> str:
    m = metric(values)
    return (f'  {label:<{width}} n={m["n"]:>7} median={m["median"]:7.2f}% '
            f'mean={m["mean"]:7.2f}% p90={m["p90"]:8.2f}% max={m["max"]:9.2f}%')


def load_rows(directory: Path) -> list[dict]:
    rows = []
    for path in sorted(directory.glob('rounds-*-graded.json')):
        rows.extend(json.loads(path.read_text()))
    return rows


class Inputs:
    """Lazily load one batch input file at a time."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.index: list[tuple[int, int, Path]] = []
        for path in directory.glob('rounds-*-input.json'):
            match = re.match(r'rounds-(\d+)-(\d+)-input\.json', path.name)
            self.index.append((int(match.group(1)), int(match.group(2)), path))
        self.cache: dict[Path, dict[str, dict]] = {}

    def get(self, round_number: int, case_id: str) -> dict | None:
        for first, last, path in self.index:
            if first <= round_number <= last:
                if path not in self.cache:
                    self.cache = {path: {row['id']: row for row in json.loads(path.read_text())}}
                return self.cache[path].get(case_id)
        return None


def mechanism(inputs: Inputs, row: dict) -> dict:
    """Reproduce the estimator's arithmetic for one saved case."""
    case = inputs.get(row['round'], row['id'])
    if case is None:
        return {}
    target = [segment for segment in case['history'] if segment['book'] == case['target']]
    prior = [value for segment in case['history']
             if segment['book'] != case['target'] for value in segment['durations']]
    durations = [value for segment in target for value in segment['durations']]
    result = {'target_n': len(durations)}
    if durations:
        result['target_median'] = swift_median(durations)
        kept = [value for value in durations if value <= result['target_median'] * 3]
        result['target_kept'] = len(kept)
        result['target_robust_mean'] = statistics.mean(kept)
        result['target_x40'] = result['target_robust_mean'] * 40
        result['target_durations'] = [round(value, 1) for value in durations]
    if prior:
        median = swift_median(prior)
        kept = [value for value in prior if value <= median * 3]
        result['prior_n'] = len(prior)
        result['prior_median'] = median
        result['prior_kept'] = len(kept)
        result['prior_robust_mean'] = statistics.mean(kept)
        result['prior_x40'] = result['prior_robust_mean'] * 40
        result['prior_books'] = [(segment['book'][:10], len(segment['durations']),
                                  round(statistics.mean(segment['durations']), 1))
                                 for segment in case['history'] if segment['book'] != case['target']]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--directory', type=Path, default=DEFAULT_DIR)
    args = parser.parse_args()

    scenarios = scenario_map()
    rows = load_rows(args.directory)
    inputs = Inputs(args.directory)

    def key(row):
        found = scenarios.get(row['id'])
        return (found[1], found[2]) if found else ('corpus/adversarial', 'fixed-recipe')

    baseline = [row['baseline_ape'] for row in rows]
    selected = [row['selected_ape'] for row in rows]
    print(f'saved cases: {len(rows)}')
    print(line('baseline', baseline))
    print(line('candidate', selected))
    print(f'  baseline spikes={sum(row["baseline_spike"] for row in rows)} '
          f'candidate spikes={sum(row["selected_spike"] for row in rows)}')

    print('\nScenario coverage (synthetic cases):')
    counts = collections.Counter(key(row) for row in rows)
    for name, count in counts.most_common():
        print(f'  {name[0]:<18} {name[1]:<12} {count:>7}')

    print('\nOutput identical to production baseline:')
    identical = collections.Counter()
    totals = collections.Counter()
    for row in rows:
        regime = key(row)[1]
        totals[regime] += 1
        if abs(row['selected'] - row['baseline']) < 1e-9:
            identical[regime] += 1
    for regime in (*REGIMES, 'fixed-recipe'):
        print(f'  {regime:<12} {identical[regime]:>7} of {totals[regime]:>7} '
              f'({identical[regime] / totals[regime] * 100:5.1f}%)')
    same = sum(identical.values())
    print(f'  {"total":<12} {same:>7} of {len(rows):>7} ({same / len(rows) * 100:5.1f}%)')

    live = [row for row in rows if abs(row['selected'] - row['baseline']) > 1e-9]
    print(f'\nWhere the candidate can differ ({len(live)} cases):')
    print(line('baseline', [row['baseline_ape'] for row in live]))
    print(line('candidate', [row['selected_ape'] for row in live]))
    print(f'  baseline spikes={sum(row["baseline_spike"] for row in live)} '
          f'candidate spikes={sum(row["selected_spike"] for row in live)}')

    print('\nErrors by scenario world (candidate):')
    by_world = collections.defaultdict(list)
    for row in rows:
        by_world[key(row)[0]].append(row['selected_ape'])
    for world in ('stable', 'aligned', 'opposed', 'unrelated', 'drift', 'interruptions',
                  'navigation', 'control_equal', 'control_different', 'corpus/adversarial'):
        if by_world[world]:
            print(line(world, by_world[world]))

    print('\nErrors by history regime (candidate):')
    by_regime = collections.defaultdict(list)
    for row in rows:
        by_regime[key(row)[1]].append(row['selected_ape'])
    for regime in REGIMES:
        print(line(regime, by_regime[regime]))

    print('\nConcentration of the largest errors:')
    top_all = sorted(rows, key=lambda row: -row['selected_ape'])[:1000]
    top_live = sorted(live, key=lambda row: -row['selected_ape'])[:1000]
    print('  global top 1000 by scenario:')
    for name, count in collections.Counter(key(row) for row in top_all).most_common():
        print(f'    {name[0]:<18} {name[1]:<12} {count:>4}')
    print('  candidate-specific top 1000 by scenario:')
    for name, count in collections.Counter(key(row) for row in top_live).most_common():        print(f'  {name[0]:<18} {name[1]:<12} {count:>4}')
    print('  global worst 100 by scenario:')
    for name, count in collections.Counter(key(row) for row in top_all[:100]).most_common():
        print(f'    {name[0]:<18} {name[1]:<12} {count:>4}')
    print(f'  global worst 100 span {len({row["round"] for row in top_all[:100]})} of 100 rounds')

    print('\nSpikes by scenario across all cases (candidate):')
    spike_counts = collections.Counter(key(row) for row in rows if row['selected_spike'])
    for name, count in spike_counts.most_common(10):
        print(f'  {name[0]:<18} {name[1]:<12} {count:>6} ({count / sum(spike_counts.values()) * 100:5.1f}%)')
    none_spikes = sum(count for (world, regime), count in spike_counts.items() if regime == 'none')
    print(f'  cold start total: {none_spikes} of {sum(spike_counts.values())} '
          f'({none_spikes / sum(spike_counts.values()) * 100:.1f}%)')

    print('\nSpikes among candidate-specific cases by scenario:')
    live_counts = collections.Counter(key(row) for row in live if row['selected_spike'])
    for name, count in live_counts.most_common(6):
        print(f'  {name[0]:<18} {name[1]:<12} {count:>6}')

    print('\nInterruption subset, where the candidate can differ:')
    interruptions = [row for row in live if key(row)[0] == 'interruptions']
    print(line('baseline', [row['baseline_ape'] for row in interruptions]))
    print(line('candidate', [row['selected_ape'] for row in interruptions]))

    without = [row for row in live if key(row)[0] != 'interruptions']
    print(f'\nCandidate-specific cases excluding interruptions ({len(without)}):')
    print(line('baseline', [row['baseline_ape'] for row in without]))
    print(line('candidate', [row['selected_ape'] for row in without]))

    print('\nTen largest under-estimates (candidate):')
    unders = sorted(rows, key=lambda row: -((row['active_seconds'] - row['selected']) / row['active_seconds']))[:10]
    for row in unders:
        print(f'  r{row["round"]:>3} {row["group"]:<20} {key(row)[0]}/{key(row)[1]} '
              f'target={row["active_seconds"]:.1f} candidate={row["selected"]:.1f} '
              f'error={row["selected_ape"]:.1f}%')

    print('\nArithmetic for the ten largest candidate errors:')
    for row in sorted(live, key=lambda item: -item['selected_ape'])[:10]:
        facts = mechanism(inputs, row)
        print(f'  r{row["round"]:>3} {row["id"]} {key(row)[0]}/{key(row)[1]} '
              f'target={row["active_seconds"]:.1f} baseline={row["baseline"]:.1f} '
              f'candidate={row["selected"]:.1f}')
        print(f'      target n={facts.get("target_n", 0)} '
              f'median={facts.get("target_median", float("nan")):.1f} '
              f'robust mean x40={facts.get("target_x40", float("nan")):.1f}; '
              f'prior n={facts.get("prior_n", 0)} median={facts.get("prior_median", float("nan")):.1f} '
              f'retained={facts.get("prior_kept", 0)} pooled mean x40={facts.get("prior_x40", float("nan")):.1f}')

    print('\nArithmetic for the ten largest shared (unrelated) errors:')
    shared = [row for row in sorted(rows, key=lambda item: -item['selected_ape'])
              if key(row)[0] == 'unrelated'][:10]
    for row in shared:
        facts = mechanism(inputs, row)
        print(f'  r{row["round"]:>3} {row["id"]} {key(row)[0]}/{key(row)[1]} '
              f'target={row["active_seconds"]:.1f} baseline={row["baseline"]:.1f} '
              f'candidate={row["selected"]:.1f} target_n={facts.get("target_n", 0)} '
              f'pooled x40={facts.get("prior_x40", float("nan")):.1f} '
              f'prior_books={facts.get("prior_books")}')

    print('\nSparse-regime target histories:')
    sparse = [row for row in rows if key(row)[1] == 'sparse']
    thin = [row for row in sparse if mechanism(inputs, row).get('target_n', 0) < 3]
    exactly_two = [row for row in sparse if mechanism(inputs, row).get('target_n', 0) == 2]
    thin_spikes = [row for row in thin if row['selected_spike']]
    print(f'  cases={len(sparse)} target samples <3: {len(thin)}; exactly 2: {len(exactly_two)}; '
          f'their spikes={len(thin_spikes)}')
    print(f'  their candidate errors: {line("thin history", [row["selected_ape"] for row in thin]).strip()}')
    print(f'  their baseline errors:  {line("thin history", [row["baseline_ape"] for row in thin]).strip()}')

    print('\nCorpus recipes for the largest corpus errors:')
    import adversarial_eval

    def corpus_labels():
        labels = {}
        for round_number in range(1, 101):
            for split, offset in (('development', 1), ('evaluation', 2)):
                records, truth = adversarial_eval.generate_corpus(split, 86000000 + round_number * 100 + offset, 2)
                for record, outcome in zip(records, truth):
                    case = digest(f'{round_number}:corpus-{split}:{record["id"]}')
                    labels[case] = (split, outcome['scenario'])
        return labels

    labels = corpus_labels()
    corpus = [row for row in rows if row['group'].startswith('corpus')]
    for title, chosen in (('all corpus', corpus),
                          ('largest 1000 corpus', sorted(corpus, key=lambda row: -row['selected_ape'])[:1000])):
        print(f'  {title}:')
        for (split, scenario), count in collections.Counter(labels.get(row['id']) for row in chosen).most_common(6):
            print(f'    {split:<12} scenario {scenario:>2}  {count:>5}')
    print('  arithmetic for the five largest corpus errors:')
    for row in sorted(corpus, key=lambda item: -item['selected_ape'])[:5]:
        facts = mechanism(inputs, row)
        print(f'    r{row["round"]:>3} {labels.get(row["id"])} target={row["active_seconds"]:.1f} '
              f'baseline={row["baseline"]:.1f} candidate={row["selected"]:.1f} '
              f'target_n={facts.get("target_n", 0)} median={facts.get("target_median", float("nan")):.1f} '
              f'kept={facts.get("target_kept", 0)} '
              f'mean={facts.get("target_robust_mean", float("nan")):.1f} '
              f'x40={facts.get("target_x40", float("nan")):.1f} '
              f'durations={facts.get("target_durations")}')

    print('\nControl cases:')
    for name in ('control_equal', 'control_different'):
        values = [row['selected_ape'] for row in rows if key(row)[0] == name]
        print(line(name, values))

    print('\nWeight and formula identity:')
    print(f'  candidate = {WEIGHT} * guarded + {1 - WEIGHT} * recent')
    print('  The saved grades contain only baseline and selected, not guarded/recent.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
