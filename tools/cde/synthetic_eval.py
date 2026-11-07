#!/usr/bin/env python3
"""Synthetic stress evaluation; scenarios are assumptions, not human data.

prepare creates separate predictor inputs and hidden outcomes. score requires
predictions produced by the real Swift estimator through SyntheticEvaluationTests.
No generator parameters are fitted to either estimator.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
from pathlib import Path
import random
import statistics

import cde_model
import cde_personal

WORLDS = ('stable', 'aligned', 'opposed', 'unrelated', 'drift', 'interruptions', 'navigation')
REGIMES = ('none', 'cross_book', 'sparse', 'same_book')
EPOCH = datetime(2024, 1, 1, tzinfo=timezone.utc)
VERSION = 'synthetic-eval/1'
SCORES_PATH = Path(__file__).resolve().parents[2] / 'docs/audits/evidence/adf-149-scores-2026-10-29.json'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def book_set(split):
    # Real book-level ADF outputs, split by distinct content digest. Synthetic
    # per-page word counts and latent effects do not describe those actual books.
    rng = random.Random({'development': 5167, 'validation': 8221, 'holdout': 49331}[split])
    profiles = cde_personal.load_profiles(SCORES_PATH)
    identifiers = sorted(profiles)
    random.Random(1181).shuffle(identifiers)
    start = {'development': 0, 'validation': 12, 'holdout': 24}[split]
    selected = identifiers[start:start + 12]
    if len(selected) != 12:
        raise ValueError('score artifact must contain at least 36 distinct books')
    return [dict(id=key, words=rng.randint(110, 390), latent=rng.uniform(-1, 1),
                 dimensions=profiles[key]) for key in selected]


def page_seconds(rng, reader, book, world, time_step):
    # Independent reader/book interaction, deliberately not fitted to ADF.
    factor = 1.0
    if world == 'aligned':
        factor = math.exp(reader['sensitivity'] * (book['dimensions']['A'] - 0.5))
    elif world == 'opposed':
        factor = math.exp(-reader['sensitivity'] * (book['dimensions']['A'] - 0.5))
    elif world == 'unrelated':
        factor = math.exp(reader['sensitivity'] * book['latent'])
    elif world == 'drift':
        factor = 1.0 + 0.45 * time_step
    active = reader['seconds_per_word'] * book['words'] * factor * rng.uniform(0.7, 1.3)
    return active


def make_segment(rng, reader, book, world, index, pages):
    start = EPOCH + timedelta(days=index * 2)
    active = [page_seconds(rng, reader, book, world, index / 4) for _ in range(pages)]
    # Only the future segment navigates: pages can be skipped or reread.
    # The requested target remains 40 page positions, not the hidden visit count.
    if world == 'navigation' and index == 4:
        visits = []
        for duration in active:
            if rng.random() < .15:
                continue
            visits.append(duration)
            if rng.random() < .12:
                visits.append(duration * rng.uniform(.5, 1.1))
        active = visits
    # An interruption is wall-clock time on a page. It is not active reading.
    observed = [v + (rng.uniform(200, 700) if world == 'interruptions' and rng.random() < .18 else 0)
                for v in active]
    return {'book': book['id'], 'start': start, 'end': start + timedelta(seconds=sum(observed)),
            'words': pages * book['words'], 'active': sum(active), 'observed': observed}


def prepare(split, readers, seed):
    if readers < 1:
        raise ValueError('readers must be positive')
    rng = random.Random(seed)
    books = book_set(split)
    profiles = {b['id']: b['dimensions'] for b in books}
    inputs, truths, cde = [], [], []
    for i in range(readers):
        # No identity labels are interpreted as proxies for pace or difficulty.
        reader = {'seconds_per_word': rng.uniform(.10, .90), 'sensitivity': rng.uniform(.3, 1.8)}
        reader_id = f'{split}-reader-{i}'
        world = WORLDS[i % len(WORLDS)]
        regime = REGIMES[(i // len(WORLDS)) % len(REGIMES)]
        for j, target in enumerate(books[8:]):
            history_books = [books[(j * 2) % 8], books[(j * 2 + 1) % 8]]
            segments = []
            if regime != 'none':
                segments = [make_segment(rng, reader, b, world, k, 12) for k, b in enumerate(history_books)]
            if regime in ('same_book', 'sparse'):
                segments.append(make_segment(rng, reader, target, world, 2, 2 if regime == 'sparse' else 12))
            future = make_segment(rng, reader, target, world, 4, 40)
            rows = [{'id': f'{reader_id}-{j}-{k}', 'reader_id': reader_id, 'book_id': s['book'],
                     'start': s['start'], 'end': s['end'], 'words_read': s['words'],
                     'active_seconds': s['active']} for k, s in enumerate(segments)]
            # Only already-ended sessions are presented to CDE; its word count
            # and active-time inputs are oracle measurements, not available in app.
            result = cde_personal.predict(rows, profiles, reader_id, target['id'],
                                          future['words'], future['start'])
            case_id = f'{reader_id}-target-{j}'
            inputs.append({'id': case_id, 'target': target['id'], 'remainingPages': 40,
                           'history': [{'book': s['book'], 'durations': s['observed']} for s in segments]})
            truths.append({'id': case_id, 'reader': reader_id, 'book': target['id'], 'world': world,
                           'regime': regime, 'active_seconds': future['active'],
                           'wall_seconds': sum(future['observed'])})
            cde.append({'id': case_id, 'baseline': result.get('baseline_seconds'),
                        'candidate': result.get('candidate_seconds'),
                        'source': result.get('candidate_source', result['status'])})
    # Explicit paired controls: identical observable histories must not invent a
    # difference; a twofold pace difference should be distinguishable. Each pair
    # reads the same target and has known (synthetic) future outcomes.
    target = books[8]
    for label, paces in [('equal', (60.0, 60.0)), ('different', (40.0, 80.0))]:
        for k, pace in enumerate(paces):
            case_id = f'{split}-control-{label}-{k}'
            reader_id = case_id
            past = make_segment(rng, {'seconds_per_word': pace / target['words'], 'sensitivity': 0},
                                target, 'stable', 0, 12)
            past['active'] = 12 * pace
            past['observed'] = [pace] * 12
            past['end'] = past['start'] + timedelta(seconds=past['active'])
            observed = [{'id': case_id, 'reader_id': reader_id, 'book_id': target['id'],
                         'start': past['start'], 'end': past['end'], 'words_read': past['words'],
                         'active_seconds': past['active']}]
            result = cde_personal.predict(observed, profiles, reader_id, target['id'],
                                          40 * target['words'], EPOCH + timedelta(days=8))
            inputs.append({'id': case_id, 'target': target['id'], 'remainingPages': 40,
                           'history': [{'book': target['id'], 'durations': past['observed']}]})
            truths.append({'id': case_id, 'reader': reader_id, 'book': target['id'],
                           'world': f'control_{label}', 'regime': 'same_book',
                           'active_seconds': 40 * pace, 'wall_seconds': 40 * pace})
            cde.append({'id': case_id, 'baseline': result['baseline_seconds'],
                        'candidate': result['candidate_seconds'], 'source': result['candidate_source']})
    return {'version': VERSION, 'split': split, 'seed': seed, 'readers': readers,
            'generated_by_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'books': books, 'app_inputs': inputs, 'truth': truths, 'cde_predictions': cde}


def percentile(values, q):
    values = sorted(values)
    return values[round((len(values) - 1) * q)] if values else None


def metrics(rows, key):
    pairs = [(r[key], r['active_seconds']) for r in rows if r.get(key) is not None]
    if not pairs:
        return {'count': 0}
    errors = [prediction - actual for prediction, actual in pairs]
    absolute = [abs(e) for e in errors]
    return {'count': len(pairs), 'mae_seconds': statistics.mean(absolute),
            'median_ae_seconds': statistics.median(absolute), 'p90_ae_seconds': percentile(absolute, .9),
            'bias_seconds': statistics.mean(errors),
            'median_absolute_percent_error': statistics.median(abs(e) / a * 100 for e, (_, a) in zip(errors, pairs))}


def score(prepared, swift):
    expected = {r['id'] for r in prepared['truth']}
    if len(expected) != len(prepared['truth']):
        raise ValueError('duplicate truth IDs')
    def keyed(records):
        result = {r['id']: r for r in records}
        if len(result) != len(records) or set(result) != expected:
            raise ValueError('missing, extra, or duplicate prediction IDs')
        return result
    app = keyed(swift)
    cde = keyed(prepared['cde_predictions'])
    rows = []
    for truth in prepared['truth']:
        pred = app[truth['id']]
        candidate = cde[truth['id']]
        for value in (pred['seconds'], candidate['baseline'], candidate['candidate']):
            if value is not None and (not math.isfinite(value) or value < 0):
                raise ValueError('invalid prediction')
        rows.append({**truth, 'app': pred['seconds'], 'status': pred['status'],
                     'cde_baseline': candidate['baseline'], 'cde_candidate': candidate['candidate'],
                     'cde_source': candidate['source']})
    def summarize(group):
        return {name: metrics(group, name) for name in ('app', 'cde_baseline', 'cde_candidate')}
    strata = {}
    for dimension in ('world', 'regime', 'status', 'cde_source'):
        strata[dimension] = {value: summarize([r for r in rows if r[dimension] == value])
                             for value in sorted({r[dimension] for r in rows})}
    # Cross-tabulation separates ADF matching from same-book reuse.
    strata['world_by_cde_source'] = {
        world: {source: summarize([r for r in rows if r['world'] == world and r['cde_source'] == source])
                for source in sorted({r['cde_source'] for r in rows if r['world'] == world})}
        for world in sorted({r['world'] for r in rows})
    }
    # Matched comparisons on exactly the same target and scenario/regime.
    groups = {}
    for row in rows:
        groups.setdefault((row['book'], row['world'], row['regime']), []).append(row)
    comparisons = {'different_truth': 0, 'correct_direction': 0, 'ties': 0,
                   'equal_truth': 0, 'equal_truth_different_prediction': 0}
    by_regime = {regime: {'different_truth': 0, 'correct_direction': 0, 'ties': 0,
                          'equal_truth': 0, 'equal_truth_different_prediction': 0}
                 for regime in sorted({r['regime'] for r in rows})}
    for group in groups.values():
        for a, b in zip(group[::2], group[1::2]):
            delta, predicted = a['active_seconds'] - b['active_seconds'], a['app'] - b['app']
            for counts in (comparisons, by_regime[a['regime']]):
                if abs(delta) < 1e-9:
                    counts['equal_truth'] += 1
                    if abs(predicted) >= 1e-9:
                        counts['equal_truth_different_prediction'] += 1
                else:
                    counts['different_truth'] += 1
                    if abs(predicted) < 1e-9:
                        counts['ties'] += 1
                    elif delta * predicted > 0:
                        counts['correct_direction'] += 1
    return {'version': VERSION, 'split': prepared['split'], 'seed': prepared['seed'],
            'random_readers': prepared['readers'], 'control_readers': 4,
            'cases': len(rows), 'books': len(prepared['books']),
            'generator_sha256': prepared.get('generated_by_sha256'),
            'scorer_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'adf_scores_sha256': hashlib.sha256(SCORES_PATH.read_bytes()).hexdigest(),
            'cde_predictor_sha256': hashlib.sha256(Path(cde_personal.__file__).read_bytes()).hexdigest(),
            'swift_estimator_sha256': hashlib.sha256((SCORES_PATH.parents[3] / 'AsterismaV2.0/Engines/EstimationEngine.swift').read_bytes()).hexdigest(),
            'inputs_sha256': digest(prepared['app_inputs']), 'truth_sha256': digest(prepared['truth']),
            'swift_predictions_sha256': digest(swift), 'cde_predictions_sha256': digest(prepared['cde_predictions']),
            'overall': summarize(rows), 'strata': strata, 'matched_pairs_app': comparisons,
            'matched_pairs_by_regime': by_regime,
            'limitations': ['Synthetic assumptions are not evidence of real-reader accuracy.',
                            'CDE receives exact synthetic words and active time; Swift receives wall-clock page durations.',
                            'Only active time for a known 40-page future segment is scored; no completion-date claim.',
                            'Planned segment word count is supplied to CDE; app uses page count.',
                            'Navigation changes future visits; it is not encoded as a visible skip or reread flag.',
                            'ADF dimensions come from stored book scores; synthetic page lengths and effects do not represent their real text.',
                            'No empirical confidence intervals or demographic outcomes are evaluated.',
                            'This public deterministic split is not a permanently blind holdout.',
                            'The original preparation did not record a generator file hash.' if not prepared.get('generated_by_sha256') else 'Generator hash recorded at preparation.']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    make = sub.add_parser('prepare')
    make.add_argument('--split', choices=('development', 'validation', 'holdout'), required=True)
    make.add_argument('--readers', type=int, required=True)
    make.add_argument('--seed', type=int, required=True)
    make.add_argument('--directory', type=Path, required=True)
    evaluate = sub.add_parser('score')
    evaluate.add_argument('--directory', type=Path, required=True)
    evaluate.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.action == 'prepare':
        data = prepare(args.split, args.readers, args.seed)
        args.directory.mkdir(parents=True, exist_ok=True)
        for name, value in [('app-input.json', data['app_inputs']), ('prepared.json', data)]:
            path = args.directory / name
            if path.exists():
                raise FileExistsError(f'refusing to overwrite {path}')
            path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
        print(f"prepared {len(data['app_inputs'])} cases for {args.readers} readers")
    else:
        data = json.loads((args.directory / 'prepared.json').read_text())
        swift = json.loads((args.directory / 'swift-predictions.json').read_text())
        report = score(data, swift)
        if args.output.exists():
            raise FileExistsError(f'refusing to overwrite {args.output}')
        args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
        print(json.dumps({'cases': report['cases'], 'overall': report['overall'],
                          'matched_pairs_app': report['matched_pairs_app']}, indent=2))


if __name__ == '__main__':
    main()
