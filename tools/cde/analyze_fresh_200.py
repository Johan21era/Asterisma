#!/usr/bin/env python3
"""Verify and analyze the 200 fresh synthetic stress rounds.

The blend weight is fitted only on rounds 1-100 (development) by minimizing
mean absolute percentage error over the exact piecewise-linear objective; the
frozen weight is then applied to rounds 101-200 (holdout) and to the demo
profiles. Synthetic outcomes are assumptions, not measurements of people.

Usage:
    python3 tools/cde/analyze_fresh_200.py [--directory PATH]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DIR = ROOT / 'tools/cde/fresh-200-20261030'
GUARD_LOWER = 0.35
GUARD_UPPER = 3.0
SPIKE_MINIMUM = 300.0
SPIKE_RATIO = 0.75
CALIBRATION_ROUNDS = 100
TOTAL_ROUNDS = 200


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def selected_seconds(row: dict, weight: float) -> float:
    # Absent optionals in a demo attachment mean "no value".
    recent = row.get('recent_seconds')
    prior = row.get('prior_seconds')
    if recent is None:
        return row['baseline'] if prior is None else prior
    if prior is None:
        return recent
    ratio = recent / prior
    if ratio < GUARD_LOWER or ratio > GUARD_UPPER:
        return prior
    return weight * recent + (1 - weight) * prior


def is_spike(prediction: float, actual: float) -> bool:
    return abs(prediction - actual) > max(SPIKE_MINIMUM, SPIKE_RATIO * actual)


def metric(values: list[float]) -> dict:
    ordered = sorted(values)
    n = len(ordered)
    if n % 2:
        median = ordered[n // 2]
    else:
        median = (ordered[n // 2 - 1] + ordered[n // 2]) / 2
    return {'n': n, 'median_pct': median, 'mean_pct': sum(ordered) / n,
            'p90_pct': ordered[round((n - 1) * 0.9)], 'max_pct': ordered[-1]}


def bucket(rows: list[dict], key: str) -> dict:
    values = [row[key] for row in rows]
    entry = metric(values)
    entry['spikes'] = sum(row['spike'] for row in rows)
    return entry


def objective(weight: float, cases: list[tuple[float, float, float, float]]) -> float:
    total = 0.0
    for actual, prior, recent, _ in cases:
        total += abs(weight * recent + (1 - weight) * prior - actual) / actual
    return total / len(cases)


def calibrate(cases: list[tuple[float, float, float, float]]) -> dict:
    """Ternary search on a convex piecewise-linear objective; then verify."""
    lo, hi = 0.0, 1.0
    for _ in range(90):
        third = (hi - lo) / 3
        low, high = lo + third, hi - third
        flow, fhigh = objective(low, cases), objective(high, cases)
        if flow < fhigh:
            hi = high
        elif fhigh < flow:
            lo = low
        else:
            lo, hi = low, high
    raw = (lo + hi) / 2
    weight = round(raw, 12)
    endpoints = {str(w): objective(w, cases) for w in (0.0, 0.25, 0.5, 0.75, 1.0)}
    return {'weight': weight, 'raw_weight': raw, 'cases': len(cases),
            'development_mean_ape_pct': objective(weight, cases) * 100,
            'objective_at': {key: value * 100 for key, value in endpoints.items()},
            'near_optimal_band': [round(max(0.0, weight - 0.001), 12),
                                  round(min(1.0, weight + 0.001), 12)],
            'band_mean_ape_pct': [objective(max(0.0, weight - 0.001), cases) * 100,
                                  objective(min(1.0, weight + 0.001), cases) * 100]}


def collect(directory: Path):
    """Pass 1: verify every graded row and collect calibration cases."""
    calibration, rounds, seen = [], {}, set()
    verification = {'rows': 0, 'batches': 0, 'errors': []}
    group_counts: dict[str, int] = {}
    for path in sorted(directory.glob('rounds-*-graded.json')):
        rows = json.loads(path.read_text())
        verification['batches'] += 1
        for row in rows:
            ident = row['id']
            if ident in seen:
                verification['errors'].append(f'duplicate id {ident}')
            seen.add(ident)
            actual = row['active_seconds']
            selected = selected_seconds(row, 0.5)
            numbers = [actual, row['baseline'], row['legacy'], row['filtered'], selected]
            numbers += [v for v in (row['prior_seconds'], row['recent_seconds'])
                        if v is not None]
            if not all(isinstance(v, (int, float)) and math.isfinite(v) and v > 0
                       for v in numbers):
                verification['errors'].append(f'invalid number {ident}')
                continue
            expected = {
                'baseline_ape': abs(row['baseline'] - actual) / actual * 100,
                'legacy_ape': abs(row['legacy'] - actual) / actual * 100,
                'selected_ape': abs(selected - actual) / actual * 100,
                'baseline_spike': is_spike(row['baseline'], actual),
                'legacy_spike': is_spike(row['legacy'], actual),
                'selected_spike': is_spike(selected, actual),
                'differs': abs(selected - row['baseline']) > 1e-9 * max(1, abs(selected)),
            }
            for key, value in expected.items():
                saved = row[key]
                if isinstance(value, bool):
                    if saved != value:
                        verification['errors'].append(f'{key} mismatch {ident}')
                elif not math.isclose(saved, value, rel_tol=1e-11, abs_tol=1e-8):
                    verification['errors'].append(f'{key} mismatch {ident}')
            if abs(row['candidate_seconds'] - selected) > 1e-9 * max(1, abs(selected)):
                verification['errors'].append(f'candidate rule mismatch {ident}')
            if row['round'] <= CALIBRATION_ROUNDS and row['recent_seconds'] is not None \
                    and row['prior_seconds'] is not None \
                    and GUARD_LOWER <= row['recent_seconds'] / row['prior_seconds'] <= GUARD_UPPER:
                calibration.append((actual, row['prior_seconds'],
                                    row['recent_seconds'], row['baseline']))
            rounds.setdefault(row['round'], 0)
            rounds[row['round']] += 1
            group_counts[row['group']] = group_counts.get(row['group'], 0) + 1
            verification['rows'] += 1
    if sorted(rounds) != list(range(1, TOTAL_ROUNDS + 1)):
        verification['errors'].append('round coverage is not 1..200')
    if len(seen) != verification['rows']:
        verification['errors'].append('duplicate identifiers')
    return calibration, verification, group_counts


def analyze_pass(directory: Path, weight: float, first: int = 1, last: int = TOTAL_ROUNDS) -> dict:
    """Pass 2: compute every reported statistic at one frozen weight."""
    overall = {'baseline': [], 'legacy': [], 'selected': []}
    spikes = {'baseline': 0, 'legacy': 0, 'selected': 0}
    differing = {'baseline': [], 'legacy': [], 'selected': []}
    differing_spikes = {'baseline': 0, 'legacy': 0, 'selected': 0}
    groups: dict[str, dict] = {}
    worlds: dict[str, dict] = {}
    regimes: dict[str, dict] = {}
    round_buckets: dict[int, dict] = {}
    extrema = {'selected': [], 'baseline': [], 'legacy': []}
    differing_cases = 0

    def add(table, key):
        return table.setdefault(key, {'baseline': [], 'legacy': [], 'selected': [],
                                      'baseline_spikes': 0, 'legacy_spikes': 0,
                                      'selected_spikes': 0, 'differing': 0})

    for path in sorted(directory.glob('rounds-*-graded.json')):
        rows = json.loads(path.read_text())
        for row in rows:
            if not (first <= row['round'] <= last):
                continue
            actual = row['active_seconds']
            values = {'baseline': row['baseline'], 'legacy': row['legacy'],
                      'selected': selected_seconds(row, weight)}
            differs = abs(values['selected'] - values['baseline']) > 1e-9 * max(1, values['selected'])
            differing_cases += differs
            by_round = round_buckets.setdefault(row['round'], {
                'cases': 0, 'differing': 0,
                'baseline': [], 'legacy': [], 'selected': [],
                'baseline_spikes': 0, 'legacy_spikes': 0, 'selected_spikes': 0})
            by_round['cases'] += 1
            by_round['differing'] += differs
            for key, prediction in values.items():
                ape = abs(prediction - actual) / actual * 100
                spike = is_spike(prediction, actual)
                overall[key].append(ape)
                spikes[key] += spike
                by_round[key].append(ape)
                by_round[key + '_spikes'] += spike
                if differs:
                    differing[key].append(ape)
                    differing_spikes[key] += spike
                for table, label in ((groups, row['group']), (worlds, row['world']),
                                     (regimes, row['regime'])):
                    entry = add(table, label)
                    entry[key].append(ape)
                    entry[key + '_spikes'] += spike
                extrema[key].append({'id': row['id'], 'round': row['round'],
                                     'group': row['group'], 'world': row['world'],
                                     'regime': row['regime'],
                                     'actual_seconds': actual, 'prediction_seconds': prediction,
                                     'absolute_percent_error': ape,
                                     'target_samples': row['target_samples'],
                                     'prior_seconds': row['prior_seconds'],
                                     'recent_seconds': row['recent_seconds']})
            if differs:
                for table, label in ((groups, row['group']), (worlds, row['world']),
                                     (regimes, row['regime'])):
                    add(table, label)['differing'] += 1
    per_round = [{'round': number,
                  'cases': by_round['cases'], 'differing': by_round['differing'],
                  'baseline': metric(by_round['baseline']),
                  'legacy': metric(by_round['legacy']),
                  'selected': metric(by_round['selected']),
                  'baseline_spikes': by_round['baseline_spikes'],
                  'legacy_spikes': by_round['legacy_spikes'],
                  'selected_spikes': by_round['selected_spikes']}
                 for number, by_round in sorted(round_buckets.items())]
    for key in extrema:
        extrema[key].sort(key=lambda item: item['absolute_percent_error'], reverse=True)
        extrema[key] = extrema[key][:25]
    return {
        'weight': weight,
        'cases': len(overall['baseline']),
        'differing_cases': differing_cases,
        'overall': {key: metric(values) | {'spikes': spikes[key]}
                    for key, values in overall.items()},
        'differing': {key: metric(values) | {'spikes': differing_spikes[key]}
                      for key, values in differing.items()},
        'groups': {key: {model: metric(value[model]) | {'spikes': value[model + '_spikes']}
                         for model in ('baseline', 'legacy', 'selected')}
                   | {'differing': value['differing']}
                   for key, value in groups.items()},
        'worlds': {key: {model: metric(value[model]) | {'spikes': value[model + '_spikes']}
                         for model in ('baseline', 'legacy', 'selected')}
                   | {'differing': value['differing']}
                   for key, value in worlds.items()},
        'regimes': {key: {model: metric(value[model]) | {'spikes': value[model + '_spikes']}
                          for model in ('baseline', 'legacy', 'selected')}
                    | {'differing': value['differing']}
                    for key, value in regimes.items()},
        'rounds': per_round,
        'extrema': extrema,
    }


def demo_analysis(path: Path, weight: float) -> dict:
    rows = json.loads(path.read_text())
    counts: dict[int, int] = {}
    errors = []
    baseline, legacy, selected = [], [], []
    spikes = {'baseline': 0, 'legacy': 0, 'selected': 0}
    for row in rows:
        counts[row['round']] = counts.get(row['round'], 0) + 1
        actual = row['actual_seconds']
        if abs(sum(row['futureDurations']) - actual) > 1e-6:
            errors.append(f"future sum mismatch {row['id']}")
        if not math.isfinite(actual) or actual <= 0:
            errors.append(f"invalid actual {row['id']}")
        value = selected_seconds(row, weight)
        if abs(row['candidate_seconds'] - selected_seconds(row, 0.5)) > 1e-9 * max(1, value):
            errors.append(f"candidate rule mismatch {row['id']}")
        baseline.append(abs(row['baseline'] - actual) / actual * 100)
        legacy.append(abs(row['legacy'] - actual) / actual * 100)
        selected.append(abs(value - actual) / actual * 100)
        spikes['baseline'] += is_spike(row['baseline'], actual)
        spikes['legacy'] += is_spike(row['legacy'], actual)
        spikes['selected'] += is_spike(value, actual)
    if counts != {n: 16 for n in range(1, TOTAL_ROUNDS + 1)}:
        errors.append('demo round counts are not 16 × 200')
    return {'cases': len(rows), 'weight': weight,
            'baseline': metric(baseline) | {'spikes': spikes['baseline']},
            'legacy': metric(legacy) | {'spikes': spikes['legacy']},
            'selected': metric(selected) | {'spikes': spikes['selected']},
            'errors': errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=DEFAULT_DIR)
    parser.add_argument('--output', type=Path, default=None)
    args = parser.parse_args()
    directory = args.directory
    output = args.output or directory / 'verified-summary.json'
    calibration, verification, group_counts = collect(directory)
    if verification['errors']:
        for error in verification['errors'][:20]:
            print('ERROR', error)
        raise SystemExit(f"{len(verification['errors'])} verification errors")
    fit = calibrate(calibration)
    weight = fit['weight']
    development = analyze_pass(directory, weight)
    holdout = analyze_pass(directory, weight, CALIBRATION_ROUNDS + 1, TOTAL_ROUNDS)
    demo = demo_analysis(directory / 'demo-200-predictions.json', weight)
    if demo['errors']:
        for error in demo['errors'][:20]:
            print('ERROR', error)
        raise SystemExit(f"{len(demo['errors'])} demo verification errors")
    result = {
        'definition': '200 fresh rounds, 9,914 main cases each, plus 3,200 demo cases',
        'weight': weight,
        'calibration': fit,
        'verification': {**verification, 'group_counts': group_counts,
                         'expected_rows': TOTAL_ROUNDS * 9914},
        'summary': {key: value for key, value in development.items() if key != 'rounds'},
        'rounds': development['rounds'],
        'holdout_rounds_101_200': {key: value for key, value in holdout.items()
                                   if key not in ('weight', 'rounds', 'extrema')},
        'demo': demo,
        'source_sha256': {str(path.relative_to(ROOT)): digest(path) for path in [
            ROOT / 'tools/cde/fresh_100.py',
            ROOT / 'tools/cde/analyze_fresh_200.py',
            ROOT / 'AsterismaV2.0/Engines/AnalyticsEngine.swift',
            ROOT / 'AsterismaV2.0/Engines/EstimationEngine.swift',
            ROOT / 'AsterismaV2.0Tests/Engines/AdversarialEvaluationTests.swift',
            ROOT / 'AsterismaV2.0Tests/Engines/FreshStressBundleTests.swift',
        ]},
        'batch_sha256': {path.name: digest(path)
                         for path in sorted(directory.glob('rounds-*-graded.json'))},
    }
    if output.exists():
        raise FileExistsError(output)
    output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
    print(json.dumps({'weight': weight, 'calibration': fit,
                      'cases': development['cases'],
                      'differing_cases': development['differing_cases'],
                      'overall': development['overall'],
                      'differing': development['differing'],
                      'demo': {key: demo[key] for key in ('cases', 'baseline', 'selected')},
                      'holdout': result['holdout_rounds_101_200']}, indent=2))
    print('summary sha256', digest(output))


if __name__ == '__main__':
    main()
