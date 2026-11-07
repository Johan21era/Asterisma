#!/usr/bin/env python3
"""Verify fresh stress receipts; arithmetic checks are not manual case grades."""
import hashlib
import json
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'tools/cde/fresh-100-20261030'
WEIGHT = 0.0011850789689659901


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summary(rows):
    vals = sorted(rows)
    return {'cases': len(vals), 'mean_ape': statistics.mean(vals),
            'median_ape': statistics.median(vals), 'p90_ape': vals[round((len(vals)-1)*.9)],
            'max_ape': vals[-1]}


def main():
    output = OUT / 'verified-summary.json'
    if output.exists():
        raise FileExistsError(output)
    rounds, manifests, seen = [], [], set()
    groups = defaultdict(lambda: {'base': [], 'candidate': [], 'base_spikes': 0, 'candidate_spikes': 0})
    for sp in sorted(OUT.glob('rounds-*-summary.json')):
        stem = sp.name.removesuffix('-summary.json')
        paths = {key: OUT / f'{stem}-{key}.json' for key in ('input', 'truth', 'predictions', 'graded', 'summary')}
        inputs, truth, predictions, grades, round_summary = [read(paths[key]) for key in ('input','truth','predictions','graded','summary')]
        input_by_id = {r['id']:r for r in inputs}
        truth_by_id = {r['id']:r for r in truth}
        pred_by_id = {r['id']:r for r in predictions}
        grade_by_id = {r['id']:r for r in grades}
        ids = set(input_by_id)
        if not (len(ids)==len(inputs)==len(truth)==len(predictions)==len(grades) and ids==set(truth_by_id)==set(pred_by_id)==set(grade_by_id)):
            raise ValueError('incomplete IDs for '+stem)
        if seen.intersection(ids):
            raise ValueError('ID overlaps earlier batches')
        seen.update(ids)
        for ident in ids:
            t,p,g = truth_by_id[ident],pred_by_id[ident],grade_by_id[ident]
            a=t['active_seconds']; b=p['baseline']; c=WEIGHT*p['guarded']+(1-WEIGHT)*p['recent']
            if not all(math.isfinite(v) and v>0 for v in (a,b,c)):
                raise ValueError('nonpositive or invalid result')
            for v,w in ((g['active_seconds'],a),(g['baseline'],b),(g['selected'],c),
                        (g['baseline_ape'],100*abs(b-a)/a),(g['selected_ape'],100*abs(c-a)/a)):
                if not math.isclose(v,w,rel_tol=1e-11,abs_tol=1e-8):
                    raise ValueError('arithmetic mismatch '+ident)
            if g['round'] != t['round'] or g['group'] != t['group']:
                raise ValueError('metadata mismatch '+ident)
            bs=abs(b-a)>max(300,.75*a); cs=abs(c-a)>max(300,.75*a)
            if (bs,cs)!=(g['baseline_spike'],g['selected_spike']):
                raise ValueError('spike mismatch '+ident)
            bucket=groups[g['group']]
            bucket['base'].append(g['baseline_ape']); bucket['candidate'].append(g['selected_ape'])
            bucket['base_spikes']+=bs; bucket['candidate_spikes']+=cs
        for rs in round_summary:
            sub=[r for r in grades if r['round']==rs['round']]
            if len(sub)!=9914 or rs['cases']!=len(sub):
                raise ValueError('round coverage '+str(rs['round']))
            if sum(r['selected_spike'] for r in sub)!=rs['selected_spikes'] or sum(r['baseline_spike'] for r in sub)!=rs['baseline_spikes']:
                raise ValueError('round spike mismatch')
            for label,k in [('baseline','baseline_ape'),('selected','selected_ape')]:
                actual=summary([r[k] for r in sub]); expected=rs[label]
                for a,b in [('cases','n'),('mean_ape','mean_pct'),('median_ape','median_pct'),('p90_ape','p90_pct'),('max_ape','max_pct')]:
                    if not math.isclose(actual[a],expected[b],rel_tol=1e-11,abs_tol=1e-8):
                        raise ValueError('round summary mismatch')
            rounds.append(rs)
        manifests.append({'batch':stem,'cases':len(ids),'sha256':{k:sha(v) for k,v in paths.items()}})
    rounds.sort(key=lambda r:r['round'])
    if [r['round'] for r in rounds]!=list(range(1,101)) or len(seen)!=991400:
        raise ValueError('missing rounds or cases')
    attach=OUT/'demo-100-detailed-attachments'
    manifest=read(attach/'manifest.json')
    names=[a['exportedFileName'] for x in manifest for a in x['attachments'] if 'fresh-demo-predictions' in a['suggestedHumanReadableName']]
    if len(names)!=1:
        raise ValueError('demo attachment missing')
    demo=read(attach/names[0]); old=read(OUT/'demo-all-predictions.json'); by_id={x['id']:x for x in old}
    if len(demo)!=1600 or len(by_id)!=1600 or {r['id'] for r in demo}!=set(by_id):
        raise ValueError('demo IDs mismatch')
    counts=Counter(r['round'] for r in demo)
    if counts!={r:16 for r in range(1,101)}:
        raise ValueError('demo round counts')
    db,dc=[],[]; ds,bs=0,0
    for r in demo:
        a=r['actual_seconds']; b=r['baseline']; c=WEIGHT*r['guarded']+(1-WEIGHT)*r['recent']
        if not all(math.isfinite(v) and v>0 for v in (a,b,c)) or not math.isclose(sum(r['futureDurations']),a,abs_tol=1e-6):
            raise ValueError('demo invalid')
        if any(not math.isclose(r[k],by_id[r['id']][k],rel_tol=1e-10,abs_tol=1e-6) for k in ('actual_seconds','baseline','guarded','recent')):
            raise ValueError('demo rerun mismatch')
        db.append(abs(b-a)/a*100); dc.append(abs(c-a)/a*100)
        bs+=abs(b-a)>max(300,.75*a); ds+=abs(c-a)>max(300,.75*a)
    all_base=[v for bucket in groups.values() for v in bucket['base']]
    all_candidate=[v for bucket in groups.values() for v in bucket['candidate']]
    result={'rounds':rounds,'batches':manifests,
            'overall':{'baseline':summary(all_base),'candidate':summary(all_candidate),
                       'baseline_spikes':sum(b['base_spikes'] for b in groups.values()),
                       'candidate_spikes':sum(b['candidate_spikes'] for b in groups.values())},
            'groups':{k:{'baseline':summary(v['base']),'candidate':summary(v['candidate']),
                         'baseline_spikes':v['base_spikes'],'candidate_spikes':v['candidate_spikes']}
                      for k,v in groups.items()},
            'demo':{'baseline':summary(db),'candidate':summary(dc),'baseline_spikes':bs,
                    'candidate_spikes':ds,'attachment':str((attach/names[0]).relative_to(ROOT)),
                    'attachment_sha256':sha(attach/names[0])},
            'weight':WEIGHT,
            'source_sha256':{str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'tools/cde/fresh_100.py',ROOT/'tools/cde/review_fresh_100.py',ROOT/'AsterismaV2.0Tests/Engines/AdversarialEvaluationTests.swift',ROOT/'AsterismaV2.0Tests/Engines/FreshStressBundleTests.swift']}}
    output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')
    print('verified 100 rounds, 991400 synthetic predictions and grades, and 1600 demo predictions')
    print('overall',result['overall'])
    print('groups',result['groups'])
    print('demo',result['demo'])
    print('summary sha256',sha(output))


if __name__=='__main__':
    main()
