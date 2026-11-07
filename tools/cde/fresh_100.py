#!/usr/bin/env python3
"""Fresh synthetic stress batches: generated outcomes are not human observations."""
import argparse
import hashlib
import json
import math
import os
import random
import statistics
from pathlib import Path

import adversarial_eval
import synthetic_eval

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('FRESH_OUT', ROOT / 'tools/cde/fresh-100-20261030'))
RESOURCE = ROOT / 'AsterismaV2.5Tests/Engines/FreshStressInput.json'


def save(path, obj):
    if path.exists():
        raise FileExistsError(path)
    path.write_text(json.dumps(obj, separators=(',', ':'), allow_nan=False) + '\n')


def h(value):
    return hashlib.sha256(value).hexdigest()


def generate(round_number):
    seed = 86000000 + round_number * 100
    inputs, truth = [], []
    def append(group, rows, outcomes, world=None, regime=None):
        keyed = {r['id']: r for r in outcomes}
        if len(keyed) != len(outcomes) or set(keyed) != {r['id'] for r in rows}:
            raise ValueError('input/truth IDs do not match')
        for row in rows:
            t = keyed[row['id']]
            ident = h(f'{round_number}:{group}:{row["id"]}'.encode())[:20]
            history = [dict(seg, pages=seg.get('pages', list(range(len(seg['durations'])))))
                       for seg in row['history']]
            inputs.append({'id': ident, 'target': row['target'],
                           'remainingPages': row['remainingPages'], 'history': history})
            # Labels are stored for honest reporting; the predictor never sees
            # this file, and the app input above carries none of them.
            record = {'id': ident, 'round': round_number, 'group': group,
                      'world': t.get('world', world), 'regime': t.get('regime', regime),
                      'active_seconds': t['active_seconds']}
            if 'scenario' in t:
                record['scenario'] = t['scenario']
            truth.append(record)
    for split, offset in [('development', 1), ('evaluation', 2)]:
        rows, outcomes = adversarial_eval.generate_corpus(split, seed + offset, 2)
        append('corpus-' + split, rows, outcomes, world='corpus', regime='corpus')
    rows, outcomes = adversarial_eval.generate('evaluation', seed + 3)
    append('adversarial', rows, outcomes, world='adversarial', regime='adversarial')
    # Each round creates 1,000 + 1,400 new synthetic readers, plus controls.
    for split, count, offset in [('development', 1000, 4), ('holdout', 1400, 5)]:
        data = synthetic_eval.prepare(split, count, seed + offset)
        append('synthetic-' + split, data['app_inputs'], data['truth'])
    ids = [r['id'] for r in inputs]
    if len(set(ids)) != len(ids):
        raise ValueError('duplicate generated identifier')
    order = list(range(len(inputs)))
    random.Random(seed + 6).shuffle(order)
    return [inputs[i] for i in order], [truth[i] for i in order]


def prepare(first, last):
    inputs, truth = [], []
    for n in range(first, last + 1):
        x, y = generate(n)
        inputs.extend(x)
        truth.extend(y)
        print(f'prepared round {n}: {len(x)} fresh cases', flush=True)
    stem = f'rounds-{first:03d}-{last:03d}'
    save(OUT / f'{stem}-input.json', inputs)
    save(OUT / f'{stem}-truth.json', truth)
    # Only this request-created fixture is replaced by the driver.
    RESOURCE.write_text(json.dumps(inputs, separators=(',', ':'), allow_nan=False) + '\n')
    print(f'prepared {len(inputs)} cases; input SHA256 {h(RESOURCE.read_bytes())}', flush=True)


def metric(values):
    values = sorted(values)
    return {'n': len(values), 'mean_pct': statistics.mean(values),
            'median_pct': statistics.median(values),
            'p90_pct': values[round((len(values) - 1) * .9)], 'max_pct': values[-1]}


GUARD_LOWER = 0.35
GUARD_UPPER = 3.0


def selected_seconds(prediction, weight):
    """The candidate rule; must mirror AdversarialEvaluationTests.candidateSeconds."""
    recent = prediction.get('recent_seconds')
    prior = prediction.get('prior_seconds')
    if recent is None:
        return prediction['baseline'] if prior is None else prior
    if prior is None:
        return recent
    ratio = recent / prior
    if ratio < GUARD_LOWER or ratio > GUARD_UPPER:
        return prior
    return weight * recent + (1 - weight) * prior


def spike(prediction, actual):
    return abs(prediction - actual) > max(300, .75 * actual)


def grade(first, last, prediction_path, weight):
    stem = f'rounds-{first:03d}-{last:03d}'
    inputs = json.loads((OUT / f'{stem}-input.json').read_text())
    truth = json.loads((OUT / f'{stem}-truth.json').read_text())
    predictions = json.loads(prediction_path.read_text())
    t = {r['id']: r for r in truth}
    p = {r['id']: r for r in predictions}
    ids = [r['id'] for r in inputs]
    if len(t) != len(truth) or len(p) != len(predictions) or len(set(ids)) != len(ids) or set(ids) != set(t) or set(ids) != set(p):
        raise ValueError('missing, duplicate or extra prediction IDs')
    expected = {'id', 'baseline', 'legacy', 'filtered', 'prior_seconds',
                'recent_seconds', 'candidate_seconds', 'target_samples', 'prior_samples'}
    required = expected - {'prior_seconds', 'recent_seconds'}
    # Swift's synthesized encoder omits nil optionals; absent means "no value".
    predictions = [dict(row, prior_seconds=row.get('prior_seconds'),
                        recent_seconds=row.get('recent_seconds')) for row in predictions]
    if any(not required <= set(row) <= expected for row in predictions):
        raise ValueError('prediction fields do not match the fixed adapter')
    if not 0.0 <= weight <= 1.0:
        raise ValueError('weight outside [0, 1]')
    rows = []
    for ident in ids:
        actual = t[ident]['active_seconds']
        row = p[ident]
        prior, recent = row['prior_seconds'], row['recent_seconds']
        selected = selected_seconds(row, weight)
        numbers = [actual, row['baseline'], row['legacy'], row['filtered'], selected]
        numbers += [v for v in (prior, recent) if v is not None]
        if not all(math.isfinite(v) and v > 0 for v in numbers):
            raise ValueError('invalid prediction or synthetic outcome')
        if abs(row['candidate_seconds'] - selected_seconds(row, 0.5)) > 1e-9 * max(1, abs(selected)):
            raise ValueError(f'Swift/Python candidate rule mismatch {ident}')
        rows.append({**t[ident], 'baseline': row['baseline'], 'legacy': row['legacy'],
                     'filtered': row['filtered'],
                     'prior_seconds': prior, 'recent_seconds': recent,
                     'candidate_seconds': row['candidate_seconds'],
                     'target_samples': row['target_samples'],
                     'prior_samples': row['prior_samples'],
                     'selected': selected,
                     'baseline_ape': abs(row['baseline']-actual)/actual*100,
                     'legacy_ape': abs(row['legacy']-actual)/actual*100,
                     'selected_ape': abs(selected-actual)/actual*100,
                     'baseline_spike': spike(row['baseline'], actual),
                     'legacy_spike': spike(row['legacy'], actual),
                     'selected_spike': spike(selected, actual),
                     'differs': abs(selected-row['baseline']) > 1e-9 * max(1, abs(selected))})
    rounds = []
    for n in range(first, last + 1):
        batch = [r for r in rows if r['round'] == n]
        if not batch:
            raise ValueError('empty round')
        differing = [r for r in batch if r['differs']]
        rounds.append({'round': n, 'cases': len(batch),
                       'differing': len(differing),
                       'baseline': metric([r['baseline_ape'] for r in batch]),
                       'legacy': metric([r['legacy_ape'] for r in batch]),
                       'selected': metric([r['selected_ape'] for r in batch]),
                       'baseline_spikes': sum(r['baseline_spike'] for r in batch),
                       'legacy_spikes': sum(r['legacy_spike'] for r in batch),
                       'selected_spikes': sum(r['selected_spike'] for r in batch),
                       'first_selected_spike': next((i for i,r in enumerate(batch,1) if r['selected_spike']),None)})
    save(OUT / f'{stem}-graded.json', rows)
    save(OUT / f'{stem}-summary.json', rounds)
    print(f'graded {len(rows)} generated cases in {len(rounds)} rounds; '
          f'weight={weight!r}; differing={sum(r["differs"] for r in rows)}', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('prepare','grade'))
    parser.add_argument('--first', type=int, required=True)
    parser.add_argument('--last', type=int, required=True)
    parser.add_argument('--predictions', type=Path)
    parser.add_argument('--weight', type=float, default=0.5)
    args = parser.parse_args()
    if not 1 <= args.first <= args.last <= 200:
        parser.error('rounds must be within 1..200')
    if args.action == 'prepare':
        prepare(args.first, args.last)
    else:
        if not args.predictions:
            parser.error('grade needs --predictions')
        grade(args.first, args.last, args.predictions, args.weight)


if __name__ == '__main__':
    main()
