#!/usr/bin/env python3
"""Deterministic adversarial reader cases, for experimental calibration only.

The generated inputs and truth are separate; IDs reveal no scenario labels.
Synthetic active-time outcomes are assumptions, not observations of people.
"""
import argparse
import hashlib
import json
import math
import random
from pathlib import Path

SCORES_PATH = Path(__file__).resolve().parents[2] / 'docs/audits/evidence/adf-149-scores-2026-10-29.json'



def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def generate(split, seed):
    rng = random.Random(seed)
    records, truth = [], []
    for slot in range(8):
        # IDs deliberately do not contain names, behavior labels or ordering.
        identifier = hashlib.sha256(f'{split}:{seed}:{slot}'.encode()).hexdigest()[:16]
        target = hashlib.sha256(f'{split}:shared-target'.encode()).hexdigest()[:16]
        prior = [hashlib.sha256(f'{split}:series:{i}'.encode()).hexdigest()[:16] for i in range(4)]
        speed = rng.uniform(55, 95)
        history = []

        def segment(book, pages, durations):
            history.append({'book': book, 'pages': pages, 'durations': durations})

        segment(prior[0], list(range(14)), [speed * rng.uniform(.9, 1.1) for _ in range(14)])
        if slot == 0:
            pages = list(range(10)) + [10, 11, 10, 11, 10, 11, 10, 11] + list(range(12, 20))
            durations = [speed] * 10 + [.2, .25, .2, .25, .2, .25, .2, .25] + [speed] * 8
            segment(target, pages, durations)
        elif slot == 1:
            segment(target, list(range(16)), [speed if n not in (4, 9, 12) else speed + 600 for n in range(16)])
        elif slot == 2:
            # A nonsequential series history, followed by target-book history.
            segment(prior[3], list(range(12)), [speed * 1.5] * 12)
            segment(prior[1], list(range(10)), [speed * .7] * 10)
            segment(target, list(range(12)), [speed] * 12)
        elif slot == 3:
            segment(target, list(range(8)), [speed * 2.2] * 8)
            segment(target, list(range(8, 20)), [speed * .55] * 12)
        elif slot == 4:
            segment(target, list(range(18)), [speed * (.45 if n % 2 else 1.8) for n in range(18)])
        elif slot == 5:
            segment(target, [0, 1, 2, 30, 31, 32, 70, 71, 72, 73], [speed] * 10)
        elif slot == 6:
            segment(target, list(range(15)), [speed * .12] * 15)
        else:
            segment(target, list(range(4)), [speed * 1.6] * 4)
        # Future behavior can differ from history. Outcomes are never fed to Swift.
        future_pace = speed * ([1, 1, 1.25, .55, 1.2, .85, 1.8, 1.6][slot])
        future = sum(future_pace * rng.uniform(.9, 1.1) for _ in range(40))
        records.append({'id': identifier, 'target': target, 'remainingPages': 40, 'history': history})
        truth.append({'id': identifier, 'active_seconds': future})
    order = list(range(8))
    rng.shuffle(order)
    return [records[i] for i in order], [truth[i] for i in order]


def corpus_split():
    """Keep duplicate content on one side; preserve every package row."""
    data = json.loads(SCORES_PATH.read_text())
    rows = data['rows']
    if len(rows) != 149 or any(row['status'] != 'ok' for row in rows):
        raise ValueError('expected 149 scored packages')
    digests = sorted({row['digest'] for row in rows})
    random.Random(47021).shuffle(digests)
    evaluation = set(digests[108:])
    return {
        'development': [r for r in rows if r['digest'] not in evaluation],
        'evaluation': [r for r in rows if r['digest'] in evaluation],
    }


def generate_corpus(split, seed, readers_per_package):
    """Invent reading events, not book page counts or observed reader outcomes.

    Scenario probabilities and future effects are design assumptions, set without
    looking at predictions. Evaluation uses different recipes, not just new seeds.
    """
    if readers_per_package < 1 or split not in ('development', 'evaluation'):
        raise ValueError('invalid corpus request')
    packages = corpus_split()[split]
    rng = random.Random(seed)
    records, truth = [], []
    for package_index, package in enumerate(packages):
        for person in range(readers_per_package):
            identifier = hashlib.sha256(f'corpus:{split}:{seed}:{package_index}:{person}'.encode()).hexdigest()[:16]
            target = package['digest']
            # Choose another content digest, never the target or evaluation data for training.
            others = [r['digest'] for r in packages if r['digest'] != target]
            prior = rng.choice(others)
            speed = rng.uniform(35, 175)
            scenario = (package_index * readers_per_package + person) % (12 if split == 'development' else 6)
            prior_speed = speed * rng.uniform(.55, 1.8)
            history = [{'book': prior, 'pages': list(range(12)),
                        'durations': [prior_speed * rng.uniform(.8, 1.2) for _ in range(12)]}]
            pace = speed * rng.uniform(.75, 1.25)
            n = rng.randint(6, 22)
            pages = list(range(n))
            durations = [pace * rng.uniform(.75, 1.25) for _ in pages]
            future = speed * rng.uniform(.8, 1.3)
            if split == 'development':
                if scenario == 0:  # rapid search across pages then normal reading
                    pages = [0, 8, 2, 12, 3, 14] + list(range(15, 25))
                    durations = [.3, 1.2, .4, 1.1, .3, .9] + [pace] * 10
                elif scenario == 1:  # interruptions mixed into elapsed page time
                    durations = [d + (rng.uniform(240, 900) if i % 5 == 0 else 0) for i, d in enumerate(durations)]
                elif scenario == 2:  # slow start then sustained fast reading
                    durations = [pace * (1.7 if i < n // 2 else .65) for i in range(n)]
                    future *= .7
                elif scenario == 3:  # fast history then slower future
                    durations = [pace * .25 for _ in pages]
                    future *= 1.4
                elif scenario == 4:  # legitimate fast reading continues
                    durations = [pace * .25 for _ in pages]
                    future = pace * .25
                elif scenario == 5:  # jumps across sections
                    pages = [0, 1, 2, 18, 19, 37, 38, 39, 70, 71]
                    durations = [pace * rng.uniform(.8, 1.2) for _ in pages]
                elif scenario == 6:  # non-consecutive book history
                    other = rng.choice(others)
                    history.append({'book': other, 'pages': list(range(8)), 'durations': [pace * 1.8] * 8})
                elif scenario == 7:  # no same-book evidence
                    pages, durations = [], []
                elif scenario == 8:  # sparse history
                    pages, durations = [0, 1], [pace, pace * 1.2]
                elif scenario == 9:  # long but valid reading alongside interruptions
                    durations = [pace * 2.2 if i % 3 else pace * 3.5 for i in range(n)]
                    future = pace * 2.2
                elif scenario == 10:  # alternating pace
                    durations = [pace * (.5 if i % 2 else 1.7) for i in range(n)]
                else:  # repeated rereading
                    pages = [0, 1, 2, 1, 2, 3, 4, 3, 4, 5, 6, 7]
                    durations = [pace * rng.uniform(.65, 1.15) for _ in pages]
            else:
                if scenario == 0:  # real increase in speed after a slower book
                    durations = [pace * .3] * n
                    future = pace * .3
                elif scenario == 1:  # mixed short and lengthy interruptions
                    durations = [d + (180 if i % 3 == 0 else 0) + (700 if i % 7 == 0 else 0) for i, d in enumerate(durations)]
                elif scenario == 2:  # short history, then time-consuming rereads
                    pages, durations = [0, 1, 2], [pace] * 3
                elif scenario == 3:  # speed decelerates gradually
                    durations = [pace * (.6 + i / n) for i in range(n)]
                    future = pace * 1.7
                elif scenario == 4:  # multiple navigational jumps with slow pages
                    pages = [0, 1, 14, 13, 14, 40, 41, 11, 12, 13, 14]
                    durations = [pace * rng.uniform(.7, 1.5) for _ in pages]
                else:  # genuinely slow pace absent previous-book samples
                    history = []
                    durations = [pace * 2.5] * n
                    future = pace * 2.5
            if pages:
                history.append({'book': target, 'pages': pages, 'durations': durations})
            # One hypothetical book-response world is aligned with a stored
            # dimension and another is opposed. These are simulator assumptions,
            # not measured effects of ADF or actual page lengths.
            dimension = package['dimensions']['A']
            if split == 'development' and scenario == 10:
                future *= 0.7 + 0.6 * dimension
            elif split == 'evaluation' and scenario == 4:
                future *= 1.3 - 0.6 * dimension
            # Future visits are synthesized independently of estimator parameters.
            visits = 40
            if split == 'evaluation' and scenario == 2:
                visits = 56
            elif split == 'development' and scenario == 5:
                visits = 30
            active = sum(future * rng.uniform(.85, 1.15) for _ in range(visits))
            records.append({'id': identifier, 'target': target, 'remainingPages': 40, 'history': history})
            truth.append({'id': identifier, 'active_seconds': active,
                          'package_index': package_index, 'scenario': scenario})
    order = list(range(len(records)))
    rng.shuffle(order)
    return [records[i] for i in order], [truth[i] for i in order]


def grade(inputs, truth, predictions, candidate, threshold=0.75, minimum=300, stop_at_spike=False):
    if candidate not in ('baseline', 'filtered', 'guarded', 'recent', 'blend'):
        raise ValueError('unknown candidate')
    t = {x['id']: x for x in truth}
    p = {x['id']: x for x in predictions}
    if len(t) != len(truth) or len(p) != len(predictions) or len(inputs) != len(t):
        raise ValueError('duplicate IDs or incomplete inputs')
    if {x['id'] for x in inputs} != set(t) or set(p) != set(t):
        raise ValueError('prediction ID mismatch')
    output = []
    for i, row in enumerate(inputs, 1):
        actual = t[row['id']]['active_seconds']
        estimate = p[row['id']][candidate]
        if not all(math.isfinite(v) and v > 0 for v in (actual, estimate)):
            raise ValueError('invalid number')
        error = estimate - actual
        output.append({'position': i, 'id': row['id'], 'predicted_seconds': estimate,
                       'actual_seconds': actual, 'error_seconds': error,
                       'absolute_percent_error': abs(error) / actual * 100,
                       'spike': abs(error) > max(minimum, threshold * actual)})
        if stop_at_spike and output[-1]['spike']:
            break
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    prepare = sub.add_parser('prepare')
    prepare.add_argument('--split', choices=('development', 'evaluation'), required=True)
    prepare.add_argument('--seed', type=int, required=True)
    prepare.add_argument('--directory', type=Path, required=True)
    prepare.add_argument('--corpus-149', action='store_true')
    prepare.add_argument('--readers-per-package', type=int, default=2)
    inspect = sub.add_parser('grade')
    inspect.add_argument('--directory', type=Path, required=True)
    inspect.add_argument('--candidate', choices=('baseline', 'filtered', 'guarded', 'recent', 'blend'), required=True)
    inspect.add_argument('--output', type=Path, required=True)
    inspect.add_argument('--stop-at-spike', action='store_true')
    args = parser.parse_args()
    if args.action == 'prepare':
        rows, truth = (generate_corpus(args.split, args.seed, args.readers_per_package)
                       if args.corpus_149 else generate(args.split, args.seed))
        args.directory.mkdir(parents=True, exist_ok=True)
        values = [('app-input.json', rows), ('truth.json', truth),
                  ('manifest.json', {'split': args.split, 'seed': args.seed,
                                     'inputs_sha256': fingerprint(rows), 'truth_sha256': fingerprint(truth),
                                     'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                     'corpus_scores_sha256': hashlib.sha256(SCORES_PATH.read_bytes()).hexdigest() if args.corpus_149 else None,
                                     'readers_per_package': args.readers_per_package if args.corpus_149 else None})]
        if any((args.directory / name).exists() for name, _ in values):
            raise FileExistsError('refusing to overwrite a prepared batch')
        for name, value in values:
            (args.directory / name).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
        print(f'prepared {len(rows)} opaque {args.split} cases')
    else:
        rows = json.loads((args.directory / 'app-input.json').read_text())
        truth = json.loads((args.directory / 'truth.json').read_text())
        predictions = json.loads((args.directory / 'predictions.json').read_text())
        graded = grade(rows, truth, predictions, args.candidate, stop_at_spike=args.stop_at_spike)
        if args.output.exists():
            raise FileExistsError('refusing to overwrite a grade receipt')
        args.output.write_text(json.dumps(graded, indent=2, allow_nan=False) + '\n')
        for row in graded:
            print(f"{row['position']:02d} {row['id']} prediction={row['predicted_seconds']:.1f}s "
                  f"actual={row['actual_seconds']:.1f}s error={row['error_seconds']:+.1f}s "
                  f"error%={row['absolute_percent_error']:.1f} spike={row['spike']}")


if __name__ == '__main__':
    main()
