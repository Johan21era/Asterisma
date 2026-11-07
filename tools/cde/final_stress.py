#!/usr/bin/env python3
"""Final synthetic stress experiment; not independent real-reader validation."""
import argparse
import csv
import gzip
import hashlib
import json
import math
import random
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'tools/cde/final-stress-20261030'


def read(path):
    return json.loads(path.read_text())


def write(path, data):
    if path.exists():
        raise FileExistsError(path)
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + '\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def case_id(source, old):
    return hashlib.sha256(f'{source}:{old}'.encode()).hexdigest()[:16]


def prepare():
    cases, truth, inventory = [], [], []
    sources = [
        ('adversarial-development-81521', 'development', 'adversarial'),
        ('adversarial-development-81522', 'development', 'adversarial'),
        ('adversarial-evaluation-92743', 'evaluation', 'adversarial'),
        ('corpus-development-430122', 'development', 'corpus'),
        ('corpus-evaluation-430123', 'evaluation', 'corpus'),
        ('synthetic-batch-762943-final', 'development', 'synthetic'),
        ('synthetic-batch-762944', 'evaluation', 'synthetic'),
    ]
    for source, split, group in sources:
        folder = ROOT / 'tools/cde' / source
        inputs = read(folder / 'app-input.json')
        expected = read(folder / ('prepared.json' if group == 'synthetic' else 'truth.json'))
        expected = expected['truth'] if group == 'synthetic' else expected
        keyed = {r['id']: r for r in expected}
        if len(keyed) != len(expected) or set(keyed) != {r['id'] for r in inputs}:
            raise ValueError(f'missing or duplicate truth: {source}')
        for item in inputs:
            old = item['id']
            opaque = case_id(source, old)
            record = dict(item, id=opaque)
            record['history'] = [dict(seg, pages=seg.get('pages', list(range(len(seg['durations'])))))
                                 for seg in item['history']]
            actual = keyed[old]['active_seconds']
            cases.append(record)
            truth.append({'id': opaque, 'source': source, 'split': split, 'group': group,
                          'actual_seconds': actual, 'target_kind': 'simulated active seconds'})
        inventory.append({'source': source, 'split': split, 'group': group, 'cases': len(inputs),
                          'input_sha256': digest(folder / 'app-input.json'),
                          'truth_sha256': digest(folder / ('prepared.json' if group == 'synthetic' else 'truth.json'))})
    attachments = read(OUT / 'demo-attachments/manifest.json')
    name = attachments[0]['attachments'][0]['exportedFileName']
    demo = read(OUT / 'demo-attachments' / name)
    if demo['excluded']:
        raise ValueError(f"demo profiles excluded: {demo['excluded']}")
    demo_truth = {r['id']: r for r in demo['truth']}
    for case in demo['inputs']:
        cases.append(case)
        truth.append({'id': case['id'], 'source': 'demo-snapshot', 'split': 'evaluation',
                      'group': 'demo', 'actual_seconds': demo_truth[case['id']]['active_seconds'],
                      'target_kind': demo_truth[case['id']]['target_kind']})
    inventory.append({'source': 'demo-snapshot', 'split': 'evaluation', 'group': 'demo',
                      'cases': len(demo['inputs']), 'attachment_sha256': digest(OUT / 'demo-attachments' / name)})
    if len({r['id'] for r in cases}) != len(cases) or len(cases) != len(truth):
        raise ValueError('case IDs collide')
    indices = list(range(len(cases)))
    random.Random(947061).shuffle(indices)
    write(OUT / 'app-input.json', [cases[i] for i in indices])
    write(OUT / 'truth.json', [truth[i] for i in indices])
    write(OUT / 'inventory.json', inventory)
    print('prepared', len(cases), 'cases', 'inventory', inventory)


def percentile(values, q):
    return sorted(values)[round((len(values)-1)*q)]


def stats(pairs):
    errors = [abs(p-a)/a*100 for p, a in pairs]
    return {'cases': len(errors), 'median_ape': statistics.median(errors),
            'mean_ape': statistics.mean(errors), 'p90_ape': percentile(errors, .90),
            'max_ape': max(errors),
            'spikes': sum(abs(p-a) > max(300, .75*a) for p,a in pairs)}


def reuse():
    predictions = []
    sources = ['adversarial-development-81521', 'adversarial-development-81522',
               'adversarial-evaluation-92743', 'corpus-development-430122',
               'corpus-evaluation-430123']
    for source in sources:
        path = ROOT / 'tools/cde' / source / 'predictions.json'
        predictions.extend(dict(r, id=case_id(source, r['id'])) for r in read(path))
    write(OUT / 'retrospective-predictions.json', predictions)
    print('reused', len(predictions), 'historical Swift candidate predictions')


def analyze():
    all_cases = read(OUT / 'app-input.json')
    truth = {r['id']: r for r in read(OUT / 'truth.json')}
    predictions = read(OUT / 'retrospective-predictions.json')
    pred = {r['id']: r for r in predictions}
    ids = [c['id'] for c in all_cases if c['id'] in pred]
    truth = {k: truth[k] for k in ids}
    if len(set(ids)) != len(ids) or len(pred) != len(predictions) or set(ids) != set(pred) or set(ids) != set(truth):
        raise ValueError('IDs missing, extra or duplicated')
    for ident in ids:
        if not math.isfinite(truth[ident]['actual_seconds']) or truth[ident]['actual_seconds'] <= 0:
            raise ValueError('invalid outcome')
        if any(not math.isfinite(pred[ident][k]) or pred[ident][k] <= 0
               for k in ('baseline', 'guarded', 'recent')):
            raise ValueError('invalid prediction')
    dev = [ident for ident in ids if truth[ident]['split'] == 'development']
    evaluation = [ident for ident in ids if truth[ident]['split'] == 'evaluation']
    # Exactly 100 predefined weights. The selection score is development mean
    # absolute percentage error, with lower weight as deterministic tie-break.
    weights = [i / 99 for i in range(100)]
    def estimate(ident, weight):
        return weight*pred[ident]['guarded'] + (1-weight)*pred[ident]['recent']
    def pairs(subset, weight):
        return [(estimate(i, weight), truth[i]['actual_seconds']) for i in subset]
    dev_metrics = [stats(pairs(dev,w)) for w in weights]
    selected = min(range(100), key=lambda n: (dev_metrics[n]['mean_ape'], n))
    # Only now evaluate all rounds on the previously seen evaluation sets.
    rounds = []
    for n,w in enumerate(weights):
        combined = [(estimate(i,w), truth[i]['actual_seconds']) for i in ids]
        first_spike = next((j for j,(p,a) in enumerate(combined,1) if abs(p-a) > max(300,.75*a)), None)
        rounds.append({'round': n+1, 'guarded_weight': w, 'recent_weight': 1-w,
                       'development': dev_metrics[n], 'evaluation': stats(pairs(evaluation,w)),
                       'all': stats(combined), 'first_spike_position': first_spike})
    selected_w = weights[selected]
    details = []
    for position, ident in enumerate(ids,1):
        t, p = truth[ident], pred[ident]
        estimate_seconds = estimate(ident,selected_w)
        actual = t['actual_seconds']
        error = estimate_seconds-actual
        details.append({'position': position, **t, 'baseline': p['baseline'],
                        'guarded': p['guarded'], 'recent': p['recent'],
                        'selected_prediction': estimate_seconds, 'error_seconds': error,
                        'absolute_percent_error': abs(error)/actual*100,
                        'spike': abs(error)>max(300,.75*actual)})
    results = {'definition': '100 post-processing trials on prior Swift predictions for 322 adversarial/corpus cases; other cases excluded',
               'selection': 'minimum development mean absolute percentage error; tie: lowest round',
               'selected_round': selected+1, 'selected_weight': selected_w,
               'rounds': rounds,
               'baseline_development': stats([(pred[i]['baseline'],truth[i]['actual_seconds']) for i in dev]),
               'baseline_evaluation': stats([(pred[i]['baseline'],truth[i]['actual_seconds']) for i in evaluation]),
               'selected_by_group': {g: stats([(r['selected_prediction'],r['actual_seconds']) for r in details if r['group']==g])
                                     for g in sorted({r['group'] for r in details})},
               'source_hashes': {name: digest(ROOT/name) for name in [
                   'AsterismaV2.5/Engines/EstimationEngine.swift',
                   'AsterismaV2.5/Engines/AnalyticsEngine.swift',
                   'AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift',
                   'AsterismaV2.5Tests/Engines/FinalStressDemoSnapshotTests.swift',
                   'tools/cde/final_stress.py']},
               'input_sha256': digest(OUT / 'app-input.json'),
               'truth_sha256': digest(OUT / 'truth.json'),
               'prediction_sha256': digest(OUT / 'retrospective-predictions.json')}
    write(OUT / 'results.json', results)
    write(OUT / 'selected-cases.json', details)
    # Retain a complete per-case/per-round receipt without claiming manual grades.
    path = OUT / 'all-rounds.csv.gz'
    if path.exists():
        raise FileExistsError(path)
    with gzip.open(path, 'wt', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['round','id','split','prediction_seconds','actual_seconds','absolute_percent_error','spike'])
        for n,w in enumerate(weights,1):
            for ident in ids:
                actual = truth[ident]['actual_seconds']
                predicted = estimate(ident,w)
                writer.writerow([n,ident,truth[ident]['split'],repr(predicted),repr(actual),
                                 repr(abs(predicted-actual)/actual*100),
                                 int(abs(predicted-actual)>max(300,.75*actual))])
    print('selected round', selected+1, 'weight', repr(selected_w))
    print('development',dev_metrics[selected], 'evaluation', rounds[selected]['evaluation'])
    print('baseline development',results['baseline_development'], 'evaluation', results['baseline_evaluation'])
    print('groups',results['selected_by_group'])
    print('rounds',len(rounds),'cases',len(ids),'records',len(ids)*len(rounds))


def refine():
    rows = read(OUT / 'selected-cases.json')
    development = [r for r in rows if r['split'] == 'development']
    evaluation = [r for r in rows if r['split'] == 'evaluation']
    candidates = {0.0, 1.0}
    for row in development:
        delta = row['guarded'] - row['recent']
        if delta:
            root = (row['actual_seconds'] - row['recent']) / delta
            if 0 <= root <= 1:
                candidates.add(root)
    def pairs(subset, weight):
        return [(r['recent'] * (1 - weight) + r['guarded'] * weight,
                 r['actual_seconds']) for r in subset]
    weight = min(candidates, key=lambda w: (stats(pairs(development, w))['mean_ape'], w))
    result = {'method': 'evaluate endpoints and every absolute-error breakpoint; development only',
              'candidate_points': len(candidates), 'guarded_weight': weight,
              'recent_weight': 1-weight, 'development': stats(pairs(development, weight)),
              'evaluation': stats(pairs(evaluation, weight)),
              'input_sha256': digest(OUT / 'selected-cases.json'),
              'script_sha256': digest(Path(__file__))}
    write(OUT / 'refinement.json', result)
    print(json.dumps(result, indent=2))


def baseline_review():
    results = {}
    for source in ('synthetic-batch-762943-final', 'synthetic-batch-762944'):
        folder = ROOT / 'tools/cde' / source
        prepared = read(folder / 'prepared.json')
        predictions = read(folder / 'swift-predictions.json')
        truth = {r['id']: r for r in prepared['truth']}
        keyed = {r['id']: r for r in predictions}
        if len(truth) != len(prepared['truth']) or len(keyed) != len(predictions) or set(truth) != set(keyed):
            raise ValueError('synthetic prediction coverage mismatch')
        pairs = [(keyed[i]['seconds'], truth[i]['active_seconds']) for i in truth]
        if any(not math.isfinite(p) or p < 0 or not math.isfinite(a) or a <= 0 for p, a in pairs):
            raise ValueError('invalid synthetic prediction or target')
        results[source] = {'metrics': stats(pairs),
                           'prepared_sha256': digest(folder / 'prepared.json'),
                           'predictions_sha256': digest(folder / 'swift-predictions.json')}
    write(OUT / 'baseline-review.json', results)
    print(json.dumps(results, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare','reuse','analyze','refine','baseline-review'])
    args = parser.parse_args()
    {'prepare': prepare, 'reuse': reuse, 'analyze': analyze, 'refine': refine,
     'baseline-review': baseline_review}[args.action]()


if __name__ == '__main__':
    main()
