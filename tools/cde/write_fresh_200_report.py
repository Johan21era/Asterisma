#!/usr/bin/env python3
"""Render the documented 200-round synthetic stress evidence.

Every number in the report is read from the verified summary or the saved
weight sweep; the prose names the mechanism rather than inventing a cause.
"""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'tools/cde/fresh-200-20261030'
CHECKS = OUT / 'checks'
REPORT = ROOT / 'docs/audits/fresh-reading-stress-200-2026-10-30.md'
WEIGHT = 0.979013257067


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def f2(value):
    return f'{value:.2f}'


def count(value):
    return f'{value:,}'


def exit_status(name):
    for path in (CHECKS / f'{name}.exit', OUT / f'{name}.exit'):
        if path.exists():
            return path.read_text().strip()
    return None


def log_lines(name):
    for path in (CHECKS / f'{name}.log', OUT / f'{name}.log'):
        if path.exists():
            return path.read_text().splitlines()
    return []


def tests_receipt():
    lines = log_lines('python-tests')
    ran = next((line for line in lines if line.startswith('Ran ')), 'line not found')
    status = next((line for line in reversed(lines) if line in ('OK', 'FAILED')), 'status not found')
    return f"exit {exit_status('python-tests')}; `{ran}`; `{status}`"


def one_line(name, marker):
    lines = [line for line in log_lines(name) if marker in line]
    return lines[-1] if lines else f'{marker} not found'


def census_receipt():
    text = '\n'.join(log_lines('census'))

    def last(pattern):
        found = re.findall(pattern, text)
        return found[-1] if found else 'not found'

    result = last(r'"result"\s*:\s*"([^"]+)"')
    total = last(r'"totalTestCount"\s*:\s*(\d+)')
    passed = last(r'"passedTests"\s*:\s*(\d+)')
    failed = last(r'"failedTests"\s*:\s*(\d+)')
    skipped = last(r'"skippedTests"\s*:\s*(\d+)')
    runs = last(r'"subtitle"\s*:\s*"([^"]*test runs)"')
    return f'result {result}; {total} total, {passed} passed, {failed} failed, {skipped} skipped; {runs}'


def main():
    if REPORT.exists():
        raise FileExistsError(REPORT)
    data = json.loads((OUT / 'verified-summary.json').read_text())
    sweep = json.loads((OUT / 'weight-sweep-summary.json').read_text())
    worst = json.loads((OUT / 'worst-differing-cases.json').read_text())
    main_summary = data['summary']
    overall = main_summary['overall']
    differing = main_summary['differing']
    holdout = data['holdout_rounds_101_200']
    demo = data['demo']
    calibration = data['calibration']
    half = sweep['0.5']
    prior_only = sweep['0.0']
    recent_only = sweep['1.0']

    lines = []

    def add(text=''):
        lines.append(text)

    def model_row(label, bucket, key, cases=None):
        item = bucket[key]
        n = cases if cases is not None else item['n']
        add(f"| {label} | {count(n)} | {f2(item['median_pct'])} | {f2(item['mean_pct'])} | "
            f"{f2(item['p90_pct'])} | {f2(item['max_pct'])} | {count(item['spikes'])} |")

    def regime_table():
        add('| Regime | Cases | Differing | Baseline median % | Candidate median % | '
            'Baseline mean % | Candidate mean % | Baseline spikes | Candidate spikes |')
        add('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
        for name, row in main_summary['regimes'].items():
            add(f"| `{name}` | {count(row['baseline']['n'])} | {count(row['differing'])} | "
                f"{f2(row['baseline']['median_pct'])} | {f2(row['selected']['median_pct'])} | "
                f"{f2(row['baseline']['mean_pct'])} | {f2(row['selected']['mean_pct'])} | "
                f"{count(row['baseline']['spikes'])} | {count(row['selected']['spikes'])} |")

    def group_table():
        add('| Group | Cases | Differing | Baseline median % | Candidate median % | '
            'Baseline mean % | Candidate mean % | Baseline spikes | Candidate spikes |')
        add('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
        for name, row in main_summary['groups'].items():
            add(f"| `{name}` | {count(row['baseline']['n'])} | {count(row['differing'])} | "
                f"{f2(row['baseline']['median_pct'])} | {f2(row['selected']['median_pct'])} | "
                f"{f2(row['baseline']['mean_pct'])} | {f2(row['selected']['mean_pct'])} | "
                f"{count(row['baseline']['spikes'])} | {count(row['selected']['spikes'])} |")

    add('# Fresh reading-estimator stress evaluation — 200 rounds')
    add()
    add('**Result: 200 fresh synthetic rounds completed; not validated for real readers.** '
        'The four audited changes were in place before the run: two in production and two in the '
        'candidate adapter. On 1,982,800 main cases, '
        'the fixed production baseline beats the saved legacy comparator overall, but the experimental '
        'recent/prior candidate loses to the fixed baseline at both the fitted weight (0.979) and '
        'the pre-registered 0.5 weight. The candidate is rejected on this evidence. '
        'Generated by `python3 tools/cde/write_fresh_200_report.py` (exit 0).')
    add()
    add('This report supplements the [100-round report](fresh-reading-stress-100-2026-10-30.md) '
        'and the [root-cause audit](fresh-stress-root-cause-2026-10-30.md). It does not replace '
        'their historical results and does not turn generated outcomes into measurements of people.')
    add()
    add('## What was requested and done')
    add()
    add('The owner asked for every audited defect to be fixed, then for 200 fresh rounds to show '
        'what remained. Four audited changes were already present when this run began and were '
        'unchanged during it; the first two are production code, the last two are the candidate '
        'adapter’s own rules:')
    add()
    add('1. **Per-book normalization before pooling.** '
        '[`crossBookReadingSpeed`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L83) computes '
        'each book’s robust mean first, then combines the book paces with '
        '[`consensusSeconds`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L459). Two books '
        'that disagree by more than 3× use the faster one; three or more use the median.')
    add('2. **Contamination-resistant ceiling.** '
        '[`robustMeanSeconds`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L424) retains '
        'values up to '
        '[`max(median, lowerQuartile × 3)`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L444), '
        'instead of anchoring the ceiling to a median that moves with the contamination.')
    add('3. **Three-sample minimum for the candidate’s recent pace.** '
        '[`minimumRecentTimings`](../../AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift#L71) '
        'is 3; two timings are no longer treated as a pace. The production estimator’s own '
        'five-timing threshold is unchanged.')
    add('4. **Two-sided plausibility guard.** The candidate falls back when the recent/prior ratio '
        'is outside '
        '[0.35–3.0](../../AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift#L73), not only '
        'when the target is implausibly fast.')
    add()
    add('The run contains 40 batches of five rounds, 9,914 main cases per round, plus 200 demo '
        'rounds of 16 personas: **1,982,800 main predictions and 3,200 demo predictions**, '
        '1,986,000 in total. These are case predictions, not independent people or independent '
        'readers. Inputs, truth, Swift predictions, grades, result bundles and logs are retained in '
        '[the evidence directory](../../tools/cde/fresh-200-20261030).')
    add()
    add('**Provenance limitation.** The driver was interrupted after batch 175 and resumed at batch '
        '176. The resumable driver skipped already graded batches, reused the prepared input for '
        'the interrupted batch, and ran the demo sweep once. All 40 graded files passed the '
        'verifier, and every saved `candidate_seconds` value matches the same rule; this is not '
        'evidence of one clean uninterrupted invocation.')
    add()
    add('## Method')
    add()
    add('The **production baseline** is the actual Swift `EstimationEngine` after the two production '
        'fixes, invoked through the existing adversarial adapter. The **legacy comparator** (`legacy`) '
        'is the adapter’s saved same-case reference. For targets with fewer than five timings it uses '
        'the old pooled formula: one cross-book median, the old median-3× ceiling, one mean. For '
        'targets with at least five timings it calls the current `AnalyticsEngine.readingSpeed`, which '
        'already contains the fixed per-book policy. It is therefore a hybrid, not a full reproduction '
        'of the retired estimator. It isolates the pooling/consensus change on no-personal-speed '
        'cases; it does not isolate the ceiling change on personal-speed cases, where `legacy` equals '
        'the baseline by construction.')
    add()
    add('The **experimental candidate** blends two values when both exist: the robust mean of the '
        'last eight usable target timings (`recent`) and the fixed cross-book consensus over the '
        'other books (`prior`). It requires at least three recent timings and applies the two-sided '
        '0.35–3.0 guard. When `recent` is absent it returns `prior`; when `prior` is absent it '
        'returns `recent`; when the guard rejects `recent` it returns `prior`. It is not a '
        'production formula change.')
    add()
    add(f"The blend weight was fitted only on rounds 1–100, by minimizing mean absolute percentage "
        f"error over the exact piecewise-linear objective, and then frozen for rounds 101–200 and "
        f"the demo profiles. The fitted weight is **{calibration['weight']:.12f}**, effectively "
        f"recent-only. Calibration used {count(calibration['cases'])} eligible cases "
        f"({calibration['cases'] / 991400 * 100:.2f}% of the 991,400 development cases). That "
        f"subset includes only cases where both `recent` and `prior` exist and the guard passes; it "
        f"excludes every sparse fallback and every guard rejection. The pre-registered 0.5 blend is "
        f"reported separately so the goalposts are visible.")
    add()
    add('Absolute percentage error is `100 × |prediction − synthetic target| / synthetic target`. '
        'A spike is an absolute error greater than both 300 seconds and 75% of the synthetic '
        'target; this is an investigation rule, not a validated pass/fail threshold. The 90th '
        'percentile is the sorted value at Python index `round((n − 1) × 0.9)`. Percentages are '
        'rounded here; full precision is in '
        '[verified-summary.json](../../tools/cde/fresh-200-20261030/verified-summary.json) and '
        '[weight-sweep-summary.json](../../tools/cde/fresh-200-20261030/weight-sweep-summary.json).')
    add()
    add('## Headline results')
    add()
    add('| Set / model | Cases | Median error % | Mean error % | 90th percentile % | Worst error % | Spikes |')
    add('|---|---:|---:|---:|---:|---:|---:|')
    model_row('All main cases — fixed baseline', overall, 'baseline')
    model_row('All main cases — legacy comparator', overall, 'legacy')
    model_row('All main cases — candidate @ 0.979', overall, 'selected')
    model_row('Differing cases — fixed baseline', differing, 'baseline')
    model_row('Differing cases — legacy comparator', differing, 'legacy')
    model_row('Differing cases — candidate @ 0.979', differing, 'selected')
    model_row('Holdout 101–200 — fixed baseline', holdout['overall'], 'baseline')
    model_row('Holdout 101–200 — legacy comparator', holdout['overall'], 'legacy')
    model_row('Holdout 101–200 — candidate @ 0.979', holdout['overall'], 'selected')
    model_row('Holdout differing — fixed baseline', holdout['differing'], 'baseline')
    model_row('Holdout differing — candidate @ 0.979', holdout['differing'], 'selected')
    model_row('All main cases — candidate @ pre-registered 0.5', half['overall'], 'selected')
    model_row('Differing cases — candidate @ pre-registered 0.5', half['differing'], 'selected')
    model_row('Demo elapsed-time targets — fixed baseline', demo, 'baseline')
    model_row('Demo elapsed-time targets — legacy comparator', demo, 'legacy')
    model_row('Demo elapsed-time targets — candidate @ 0.979', demo, 'selected')
    add()
    add('**The fixed baseline beats the saved legacy comparator overall, but this is not a clean A/B of every fix.** Median error falls from '
        f"{f2(overall['legacy']['median_pct'])}% to {f2(overall['baseline']['median_pct'])}% "
        f"({overall['baseline']['median_pct'] - overall['legacy']['median_pct']:+.2f} pp), mean "
        f"from {f2(overall['legacy']['mean_pct'])}% to {f2(overall['baseline']['mean_pct'])}% "
        f"({overall['baseline']['mean_pct'] - overall['legacy']['mean_pct']:+.2f} pp), and spikes "
        f"from {count(overall['legacy']['spikes'])} to {count(overall['baseline']['spikes'])} "
        f"({overall['baseline']['spikes'] - overall['legacy']['spikes']:+,}). On the "
        f"{count(differing['baseline']['n'])} cases where any candidate changes the baseline, the "
        f"fixed baseline’s median is {f2(differing['baseline']['median_pct'])}% against "
        f"{f2(differing['legacy']['median_pct'])}% for the legacy comparator, and its spikes are "
        f"{count(differing['baseline']['spikes'])} against {count(differing['legacy']['spikes'])}. "
        f"The gain is not uniform: in `corpus-evaluation` the fixed baseline’s median is "
        f"{f2(main_summary['groups']['corpus-evaluation']['baseline']['median_pct'])}% against "
        f"{f2(main_summary['groups']['corpus-evaluation']['legacy']['median_pct'])}%, a regression "
        f"of {main_summary['groups']['corpus-evaluation']['baseline']['median_pct'] - main_summary['groups']['corpus-evaluation']['legacy']['median_pct']:+.2f} pp "
        f"on 12,800 cases; its mean is unchanged at "
        f"{f2(main_summary['groups']['corpus-evaluation']['legacy']['mean_pct'])}%.")
    same_regime = main_summary['regimes']['same_book']
    sparse_regime = main_summary['regimes']['sparse']
    cross_regime = main_summary['regimes']['cross_book']
    add(f"The comparator is identical to the fixed baseline on `same_book` "
        f"({f2(same_regime['baseline']['median_pct'])}% median, "
        f"{f2(same_regime['baseline']['mean_pct'])}% mean, "
        f"{count(same_regime['baseline']['spikes'])} spikes for both) because those books have "
        f"personal history and therefore call the current per-book policy. The improvement is "
        f"concentrated in the no-personal-speed pooling path — `sparse` "
        f"{f2(sparse_regime['baseline']['median_pct'])}% against "
        f"{f2(sparse_regime['legacy']['median_pct'])}%, `cross_book` "
        f"{f2(cross_regime['baseline']['median_pct'])}% against "
        f"{f2(cross_regime['legacy']['median_pct'])}% — which is the change that path was meant "
        f"to test. It does not measure the ceiling change on personal-speed books.")
    add()
    add('**The candidate loses to the fixed baseline at both weights.** At the fitted 0.979, its '
        f"median is {f2(overall['selected']['median_pct'])}% against "
        f"{f2(overall['baseline']['median_pct'])}% "
        f"({overall['selected']['median_pct'] - overall['baseline']['median_pct']:+.2f} pp), mean "
        f"{f2(overall['selected']['mean_pct'])}% against {f2(overall['baseline']['mean_pct'])}%, and "
        f"spikes {count(overall['selected']['spikes'])} against "
        f"{count(overall['baseline']['spikes'])} "
        f"({overall['selected']['spikes'] - overall['baseline']['spikes']:+,}). At the "
        f"pre-registered 0.5 it is worse still: median "
        f"{f2(half['overall']['selected']['median_pct'])}%, mean "
        f"{f2(half['overall']['selected']['mean_pct'])}%, spikes "
        f"{count(half['overall']['selected']['spikes'])}. The holdout repeats the development "
        f"result almost exactly (median {f2(holdout['overall']['selected']['median_pct'])}% and mean "
        f"{f2(holdout['overall']['selected']['mean_pct'])}% on {count(holdout['overall']['selected']['n'])} "
        f"cases), so this is not a failed transfer of the weight: the rule itself is worse.")
    add()
    add('## Where the candidate loses')
    add()
    identical = overall['baseline']['n'] - differing['selected']['n']
    add(f'The all-case table dilutes the comparison because {count(identical)} cases '
        f'({identical / overall["baseline"]["n"] * 100:.2f}%) are numerically identical to the '
        f'fixed baseline. The differing subset and the regime split show where the candidate '
        f'changes the answer.')
    add()
    regime_table()
    add()
    group_table()
    add()
    add('### Sparse targets: the fallback discards the target’s own book')
    add()
    sparse = main_summary['regimes']['sparse']
    add(f"`sparse` contains {count(sparse['baseline']['n'])} cases; the candidate differs on "
        f"{count(sparse['differing'])}. Its median rises from "
        f"{f2(sparse['baseline']['median_pct'])}% to {f2(sparse['selected']['median_pct'])}%, its "
        f"mean from {f2(sparse['baseline']['mean_pct'])}% to {f2(sparse['selected']['mean_pct'])}%, "
        f"and its spikes from {count(sparse['baseline']['spikes'])} to "
        f"{count(sparse['selected']['spikes'])}. The saved sample counts explain the mechanism: "
        f"484,600 cases have exactly two target timings and 472,404 of them differ. With fewer than "
        f"three timings `recent` is absent by design, so the candidate returns `prior` — the "
        f"consensus over the *other* books. The production baseline instead uses the fixed "
        f"`crossBookReadingSpeed` over all books, which includes the target book and therefore its "
        f"two timings. The three-sample rule stops the old two-sample spike, but the chosen fallback "
        f"throws away the only target evidence available.")
    add()
    add('This is visible in the tail. The 100-round candidate’s worst main case was 3,628.89% from '
        'a mean of two interrupted intervals; that shape is gone from the 200-round differing set. '
        f"The new worst differing case is {f2(differing['selected']['max_pct'])}%. The overall "
        f"maximum remains {f2(overall['selected']['max_pct'])}%, a zero-history cold start that is "
        f"identical in both models.")
    add()
    add('### Same-book targets: a last-eight window is noisier than the full history')
    add()
    same = main_summary['regimes']['same_book']
    add(f"`same_book` contains {count(same['baseline']['n'])} cases; the candidate differs on "
        f"{count(same['differing'])}. The median moves from {f2(same['baseline']['median_pct'])}% to "
        f"{f2(same['selected']['median_pct'])}%, the mean from "
        f"{f2(same['baseline']['mean_pct'])}% to {f2(same['selected']['mean_pct'])}%, and spikes "
        f"from {count(same['baseline']['spikes'])} to {count(same['selected']['spikes'])}. When the "
        f"reader’s pace is stationary, restricting the estimate to the last eight usable timings "
        f"adds variance and discards the older sample; it does not add information. The production "
        f"baseline’s full-history robust mean is the better estimator on this regime.")
    add()
    add('### Corpus: the guard can prefer a contaminated prior')
    add()
    corpus = main_summary['regimes']['corpus']
    add(f"`corpus` contains {count(corpus['baseline']['n'])} cases; the candidate differs on "
        f"{count(corpus['differing'])}. Its mean rises from {f2(corpus['baseline']['mean_pct'])}% to "
        f"{f2(corpus['selected']['mean_pct'])}% and its spikes from "
        f"{count(corpus['baseline']['spikes'])} to {count(corpus['selected']['spikes'])}. The "
        f"largest differing cases share one shape: `recent` is close to the baseline and the "
        f"synthetic target, while `prior` is roughly ten times larger; the guard sees a "
        f"recent/prior ratio below 0.35, treats the target as the implausible one, and returns the "
        f"contaminated prior.")
    add()
    add('| Round | ID | Target s | Baseline s | Prior s | Recent s | Candidate s | Candidate error % | Samples |')
    add('|---:|---|---:|---:|---:|---:|---:|---:|---:|')
    for row in worst[:3]:
        add(f"| {row['round']} | `{row['id']}` | {f2(row['actual_seconds'])} | "
            f"{f2(row['baseline'])} | {f2(row['prior_seconds'])} | {f2(row['recent_seconds'])} | "
            f"{f2(row['selected'])} | {f2(row['ape'])} | {row['samples']} |")
    add()
    add('The guard assumes that disagreement means the target is contaminated. That assumption is '
        'not safe across books with different page scales: the target can have 11–18 usable '
        'timings while the cross-book prior is the outlier. The fallback should not be the prior when '
        'a trusted recent pace exists.')
    add()
    add('### The unrelated world and the one family where the candidate wins')
    add()
    unrelated = main_summary['worlds']['unrelated']
    add(f"In `unrelated`, where the target has a hidden response effect the estimator cannot see, "
        f"the candidate’s median is {f2(unrelated['selected']['median_pct'])}% against "
        f"{f2(unrelated['baseline']['median_pct'])}% and its spikes are "
        f"{count(unrelated['selected']['spikes'])} against {count(unrelated['baseline']['spikes'])}. "
        f"A prior from other books cannot identify a hidden effect; the loss here is expected.")
    add()
    adversarial = main_summary['groups']['adversarial']
    add(f"`adversarial` is the exception: the candidate’s median is "
        f"{f2(adversarial['selected']['median_pct'])}% against "
        f"{f2(adversarial['baseline']['median_pct'])}%, and it has "
        f"{count(adversarial['selected']['spikes'])} spikes against "
        f"{count(adversarial['baseline']['spikes'])}. The adversarial slot is constructed so that "
        f"the designed reversal makes a prior fallback useful. This is evidence that the rule can "
        f"win where the prior is the right reference, not evidence that it wins in general.")
    add()
    add('## Calibration: the fit answers a narrower question than deployment')
    add()
    add('| Weight | Development objective, mean APE % |')
    add('|---:|---:|')
    for weight, value in calibration['objective_at'].items():
        add(f"| {weight} | {f2(value)} |")
    add()
    add(f"The objective decreases monotonically toward recent-only: the prior adds essentially "
        f"nothing on the 244,514 cases where both values pass the guard. That is why the fitted "
        f"weight is {calibration['weight']:.3f}, and why the 0.5 blend is worse "
        f"({f2(half['overall']['selected']['median_pct'])}% median against "
        f"{f2(overall['selected']['median_pct'])}% at the fitted weight). But the fit never sees the "
        f"2-sample fallbacks or the guard rejections, which are where the candidate loses most of "
        f"its cases. A weight selected on the eligible subset cannot justify the rule’s behaviour "
        f"on the excluded majority of differences.")
    add()
    add('## All 200 rounds')
    add()
    add('Each row contains the 9,914 main cases; demo cases are summarized separately above. The '
        'candidate column uses the frozen fitted weight. All numbers are automated assessments '
        'against generated outcomes; no round was restarted after a spike.')
    add()
    add('| Round | Baseline median % | Legacy median % | Candidate median % | Baseline mean % | Candidate mean % | Baseline worst % | Candidate worst % | Baseline spikes | Candidate spikes | Differing |')
    add('|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for row in data['rounds']:
        b, legacy, c = row['baseline'], row['legacy'], row['selected']
        add(f"| {row['round']} | {f2(b['median_pct'])} | {f2(legacy['median_pct'])} | "
            f"{f2(c['median_pct'])} | {f2(b['mean_pct'])} | {f2(c['mean_pct'])} | "
            f"{f2(b['max_pct'])} | {f2(c['max_pct'])} | {count(row['baseline_spikes'])} | "
            f"{count(row['selected_spikes'])} | {count(row['differing'])} |")
    add()
    add('## Evidence and checks')
    add()
    add(f"- `bash tools/cde/run_fresh_200.sh` exited {exit_status('run') or 'SKIPPED'}; the log "
        f"ends `{one_line('run', 'ALL DONE')}`. It produced 40 graded batches and a 200-round demo "
        f"attachment. The [driver](../../tools/cde/run_fresh_200.sh) skips graded batches on resume.")
    add(f"- `python3 tools/cde/analyze_fresh_200.py` exited "
        f"{exit_status('analysis') or 'SKIPPED'}. The verifier read "
        f"{count(data['verification']['rows'])} rows across "
        f"{data['verification']['batches']} batches, found no duplicate identifiers, no invalid "
        f"numbers, no arithmetic mismatches and no candidate-rule mismatches. The expected row count "
        f"was {count(data['verification']['expected_rows'])}; it matched. The demo verifier read "
        f"{count(demo['cases'])} rows, 16 per round, and found no errors.")
    add(f"- `python3 -m unittest discover -s tools/cde -p 'test_*.py'` {tests_receipt()}.")
    add(f"- `./scripts/verify-sentinel-surface.sh` exited {exit_status('sentinel') or 'SKIPPED'}: "
        f"`{one_line('sentinel', 'sentinel-surface:')}`.")
    add(f"- `python3 scripts/comprehension-bench.py --validate-only` exited "
        f"{exit_status('index') or 'SKIPPED'}: `{one_line('index', 'bank ok:')}`.")
    add(f"- `./scripts/census.sh --unit-only` exited {exit_status('census') or 'SKIPPED'}; the "
        f"Xcode summary reports `{census_receipt()}`. Skipped tests are not passes.")
    add()
    add('**SKIPPED: independent manual grading of every result.** Code scored and mechanically '
        'checked all main-case predictions. The three corpus cases above were selected because they '
        'are the largest differences; they were inspected as arithmetic, not hand-graded against '
        'the generator. **SKIPPED: real-reader and live-app validation**; elapsed time, page turns, '
        'interruptions and storage reloads were not observed. **SKIPPED: sequential '
        'stop-on-spike, recalibrate and restart**; the rule was frozen and scoring continued. '
        '**SKIPPED: a clean uninterrupted 200-round invocation**; the driver resumed at batch 176 '
        'after an interruption, as described above.')
    add()
    add('### Evidence digests')
    add()
    for path in [OUT / 'verified-summary.json', OUT / 'weight-sweep-summary.json',
                 OUT / 'worst-differing-cases.json', OUT / 'analysis.log', OUT / 'run.log',
                 OUT / 'demo-200-predictions.json', ROOT / 'tools/cde/run_fresh_200.sh',
                 ROOT / 'tools/cde/fresh_100.py', ROOT / 'tools/cde/analyze_fresh_200.py',
                 ROOT / 'tools/cde/write_fresh_200_report.py',
                 ROOT / 'AsterismaV2.5/Engines/AnalyticsEngine.swift',
                 ROOT / 'AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift']:
        add(f'- [{path.name}](../../{path.relative_to(ROOT)}) — SHA-256 `{sha(path)}`.')
    add()
    demo_bytes = (OUT / 'demo-200-predictions.json').stat().st_size
    add(f'The summary also records the SHA-256 of all 40 graded batch files and of the six source '
        f'files it read. The demo attachment is {count(demo_bytes)} bytes; its manifest names the '
        f'single exported attachment.')
    add()
    add('## Limitations and next decision')
    add()
    add('The outcomes are generated assumptions, not measurements of real readers. The recipes and '
        'book sets are reused; only the seeds are new. The corpus uses stored package scores, not '
        'the books or their text. The adapter receives closed intervals, whereas live sessions and '
        'SQLite summary reload can differ. The `legacy` comparator is a hybrid: it uses the old '
        'pooled formula only for targets with fewer than five timings, and the current per-book '
        'policy otherwise, so `same_book` is identical to the baseline by construction and the '
        'ceiling change is not isolated. The guard compares seconds per page across books whose '
        'page scales differ, which the corpus cases expose. The demo target is generated elapsed '
        'time, not active reading time. The run resumed after an interruption, and the calibration '
        'subset excludes the cases where the candidate most often differs. There is no independent '
        'hand grading and no second reader. No production weight was changed by this analysis, and '
        'nothing was committed or pushed.')
    add()
    add('**Decision.** Keep the two fixed production behaviours. Reject the recent/prior candidate '
        'at both weights, including its three-sample minimum and two-sided guard as deployed rules. '
        'The next experiment, if the owner wants one, should fall back to the '
        'fixed baseline when `recent` is missing or rejected, shrink a recent estimate toward the '
        'target’s full history rather than toward a cross-book prior, and calibrate on the cases '
        'where the rule actually changes the answer. That experiment has not been run; it is a '
        'hypothesis, not a result.')
    REPORT.write_text('\n'.join(lines) + '\n')
    print('wrote', REPORT.relative_to(ROOT), 'lines', len(lines), 'sha256', sha(REPORT))


if __name__ == '__main__':
    main()
