# Synthetic reading-time evaluation

This report describes a synthetic experiment, not a measurement of real-reader
accuracy. The first reported batch is an exploratory run: its results have been
inspected, so its deterministic split is no longer a blind final test.

## Purpose and safeguards

The harness in `tools/cde/synthetic_eval.py` generates independent reader
histories and hidden future outcomes. It does not fit simulator parameters to
estimator weights. It constructs the data directly rather than using the
Developer Console personas; those profiles remain a separate source of demo
scenarios and were not evaluated in this batch.

The Swift adapter in
`AsterismaV2.0Tests/Engines/SyntheticEvaluationTests.swift` calls the actual
`EstimationEngine`. The Python harness calls `tools/cde/cde_personal.py` for
its separate experimental CDE prediction. The CDE model is not integrated
into the app. Prior history only is supplied; synthetic future active seconds
are kept in the prepared data and are not passed to either predictor.

The three named splits use disjoint content digests and reader identifiers.
The reported batch used the holdout-labelled split, but the split is public,
deterministic and now inspected. No model was trained for this evaluation;
the split does not establish generalization to independently sampled people or
books. A fresh unseen test must be reserved before selecting or tuning models.
The generator uses stored ADF dimensions from
`docs/audits/evidence/adf-149-scores-2026-10-29.json`. Page word counts and
reader responses are invented, not observations about those books or readers.

The seven scenario families cover stable pace, a response aligned with one
ADF dimension, an opposite response, a latent book effect unrelated to ADF,
pace drift, interruptions, and future skipped or reread pages. Four history
conditions cover none, cross-book, sparse same-book, and more same-book
history. These are chosen stress cases, not population frequencies. ADF-linked
worlds intentionally assume a relationship with one dimension; the opposite,
stable and unrelated worlds challenge that assumption, but none establishes
whether any such relationship exists in real life. Pairs of controls with equal
or different synthetic pace check whether the app invents or detects a difference.

The target is active seconds for a known future segment of 40 page positions.
The app receives synthetic wall-clock page timings; the experimental model
receives exact synthetic active seconds and word counts for previous segments,
as well as the planned target word count. The app has no equivalent active-time
or word-count measurement in these inputs. Consequently the two engines' raw
error figures are not a fair head-to-head comparison. Interruptions are modeled
as wall-clock page time; navigation changes the hidden number of page visits.
There is no explicit pause or skip flag in the app input. Predicted completion
dates, confidence intervals, demographic outcomes, and real reader experience
are not evaluated.

## Batch receipt and results

On 2026-10-30, `python3 tools/cde/synthetic_eval.py prepare --split holdout --readers 1400 --seed 762944 --directory tools/cde/synthetic-batch-762944` exited 0 and produced 5,604 cases: four targets per simulated reader and four control cases. The target books are shared among readers within the batch. A separate Swift test run called the estimator for all 5,604 cases and exited 0. The resulting attachment was exported and scored with `python3 tools/cde/synthetic_eval.py score --directory tools/cde/synthetic-batch-762944 --output docs/audits/evidence/synthetic-reading-eval-762944.json`, exit 0.

The summary receipt is
`docs/audits/evidence/synthetic-reading-eval-762944.json` (SHA-256
`7f556be18ff0b0bf26150c9da3b2f1227988b0d08278227648fc2a4e41e6c49c`).
The generated inputs, hidden outcomes, Swift predictions and Xcode result bundle
are retained in `tools/cde/synthetic-batch-762944`. The receipt contains the
input, outcome, prediction, generator, estimator and score-file fingerprints.
The generated JSON is produced by the score command above, not hand-edited.

The app's median absolute error over all 5,604 synthetic cases was 1,228.9
seconds; its 90th-percentile absolute error was 5,014.5 seconds. These are
errors for the simulated 40-page target, not real-reader performance.
Median absolute error by history condition was 2,353.6 seconds with no history,
1,473.3 with cross-book history, 1,283.3 with sparse same-book history, and
279.6 with more same-book history. These groups are different synthetic cases;
the differences are not a controlled estimate of the causal benefit of more
history.

Among 700 matched app-reader pairs with different synthetic outcomes and no
history, all 700 predictions tied. Among 700 cross-book pairs, 660 had the
correct ordering; among 700 sparse-history pairs, 662 did; among 701 more
same-book pairs, 659 did. One equal-outcome control pair had equal predictions.
Pairs are constructed within the same target, scenario family and history
condition; these observations do not prove the magnitude of the differences
is correct or establish any result for real people.

For cases where the CDE candidate actually used a nearest ADF profile, each
scenario family contained 200 predictions. Median absolute error in the
aligned family was 705.1 seconds for the reader baseline versus 423.9 for
the candidate. In the stable family it was 164.6 versus 191.6; in the
interruption family, 131.2 versus 185.4; in the drift family, 2,355.2 versus
2,398.9. These are synthetic comparisons on the same cases, not evidence that
ADF improves real-world timing. See the receipt for all families and error
measures; the overall CDE figure also includes same-book reuse and must not be
read as an ADF-only effect.

## Adversarial stop-and-restart experiment — 2026-10-30

Eight scenario recipes generate synthetic histories with opaque 16-character
hash identifiers. They include back-and-forth turns, interruptions, jumping
within a book, reading a series out of order, pace changes, and sparse history.
The test cases are generated by `tools/cde/adversarial_eval.py`, not by the
Developer Console profiles. Identifiers conceal names in the grading output,
not the behavior from the developer: the generator and recipe-to-ID mapping
are accessible. This is not a blinded independent assessment.

The Swift adapter in
`AsterismaV2.0Tests/Engines/AdversarialEvaluationTests.swift` obtains the
production estimate and also computes experimental candidates. Predictions
are produced in a batch; the stop rule applies to the subsequent ordered
review, not to the calculation of predictions. The grading tool calculates
errors automatically; the numbers were inspected, not independently hand
measured. The stop rule marks a spike when absolute error exceeds both 300
seconds and 75% of the simulated future active time. This is a chosen trigger,
not a standard of acceptable accuracy.

- Round 1 stopped its ordered review at case 2: the production baseline
  estimated 408.8 seconds versus 6,069.2 simulated seconds, a 93.3%
  underestimate. Receipt: `tools/cde/adversarial-development-81521/round-1.json`.
- An experimental candidate filters certain navigation events and, when its
  target-book pace is less than 35% of prior-book pace, falls back to the
  prior-book pace. Round 2 restarted at case 1 and reviewed all eight cases
  without triggering that spike rule. Its largest error was 44.5%.
  Receipt: `tools/cde/adversarial-development-81521/round-2.json`.
- Round 3 reviewed a fresh eight-case development batch with the same candidate;
  there was no additional recalibration. Its largest error was 45.1% and no
  case triggered the spike rule. Receipt:
  `tools/cde/adversarial-development-81522/round-3.json`.
- The frozen candidate was then reviewed on eight separate generated cases.
  Its largest error was 44.8%: 3,467.2 seconds predicted versus 6,279.9
  simulated seconds. The production baseline on that same case predicted
  420.0 seconds, a 93.3% underestimate. Receipts:
  `tools/cde/adversarial-evaluation-92743/grade.json` and
  `tools/cde/adversarial-evaluation-92743/baseline-review.json`.

The baseline reviews saved alongside the rounds were generated later for
comparison and inspect all eight records; they are not additional
stop-and-restart rounds. The separate cases have different seeds and IDs but
use the same eight recipes, so they are not independent behavioral validation.
There were three ordered rounds and one experimental adjustment, not three
separately fitted formulas or a 200-profile run. Rapid page turns alone cannot
establish whether someone skimmed, read a genuinely easier book, or changed
pace. Falling back to a prior book may be wrong for a real reader. The
candidate remains test-only; these results do not justify changing the
production formula or establish accuracy for real readers.

The focused Swift adapter runs for the two development batches and the
separate batch each reported success; the saved exit files show status 0.
`python3 -m unittest discover -s tools/cde -p 'test_adversarial_eval.py' -v`
exited 0 with two tests. The repository's surface check and documentation
index validation exited 0, and the unit census exited 0 with 494 passed,
0 failed, and 9 skipped in its summary; skipped tests are not passes.
The optional batch test returns without evaluating a batch when its request
file is absent, so the census is not itself an adversarial batch run.
Real-reader validation and new, independently designed behavior families remain
unperformed.

## Expanded corpus stress experiment — 2026-10-30

This experiment uses all 149 package rows from the stored ADF score artifact:
117 rows representing 108 content digests for development and 32 rows
representing 27 disjoint digests for evaluation. Duplicate packages stay in the
same split. Two synthetic reader cases were generated per package: 234 for
development and 64 for evaluation. The generator has 12 development and six
separate evaluation scenario recipes. Cases have hash identifiers; their
recipes and outcomes are accessible to the developer, so the experiment is not
independently blinded. Inputs include book digests, invented page positions
and timings; the Swift estimator receives no book text or ADF dimensions.
One development recipe and one evaluation recipe use the stored ADF A
score to modify the invented future time. This is an assumption, not a
measurement of that book or a validated book-difficulty effect. The same
40-page prediction target is used for every case, with some simulated skips or
rereads. Package copies are not independent books, and results are not a
population sample.

The Swift adapter generated predictions in batches. Reviews restarted from the
first saved case after each spike, but calculations themselves were not
restarted sequentially. The same predefined trigger as the earlier experiment
was used. The ordered review receipts are:

- `tools/cde/corpus-development-430122/round1-baseline.json`: baseline
  stopped at case 48, an 83.7% underestimate.
- `tools/cde/corpus-development-430122/round2-guarded.json`: the earlier
  cross-book guard stopped at case 1, a 223.8% overestimate.
- `tools/cde/corpus-development-430122/round3-recent.json`: recent filtered
  pace stopped at case 48, an 83.7% underestimate.
- `tools/cde/corpus-development-430122/round4-blend.json`: a blend of the
  earlier guard and recent pace stopped at case 1, a 111.9% overestimate.
- `tools/cde/corpus-development-430122/round5-filtered.json`: filtered pace
  stopped at case 48, an 83.7% underestimate.

These are five comparisons of already implemented candidate formulas, not
five new weight recalibrations. A recent-pace candidate was frozen in
`tools/cde/corpus-development-430122/freeze.json` before the separate batch
was scored. It is exploratory: it did not resolve case 48, and it remains in
test code only. The full per-case receipts are
`tools/cde/corpus-development-430122/all-cases-baseline.json`,
`tools/cde/corpus-development-430122/all-cases-recent.json`,
`tools/cde/corpus-evaluation-430123/baseline-review.json`, and
`tools/cde/corpus-evaluation-430123/frozen-review.json`. These full reviews
are retrospective comparisons, not additional stop-and-restart rounds.

In the 64 evaluation cases, median absolute percentage error was 20.4% for
the production baseline and 18.9% for the frozen candidate. The baseline had
two cases meeting the spike rule, with a maximum error of 90.8%; the candidate
had three, with a maximum error of 181.3%. Those are statistics for the chosen
synthetic cases, not estimates of real-world performance. In particular, a
lower median does not eliminate the candidate's larger failures. Histories
showing very rapid page turns can lead to different future paces in this
simulator, so the available history alone cannot identify which future occurs.

The error calculations and complete per-case receipts were generated by code;
a genuinely independent manual assessment of every case and manual grading of
all 149 books were **SKIPPED**. There was no reader available to judge every
book or independently review each case. Previously stored ADF scores are not
manual grades or observed reading times. The scenario designer also had access
to the formulas, so the evaluation recipes are separate but not independently
designed or blinded. The corpus outcomes are assumed, not observed. No real
reader accuracy, demographic inference, or production-ready improvement is
established. Further evaluation needs independently collected reader outcomes.

The two Swift batch runs reported success for 234 and 64 cases respectively;
their saved exit files each contain 0. The Python test suite reported 27 tests,
zero failures. The surface and index checks exited 0. The required unit census
result is reported separately in the documentation audit ledger.

## Checks and remaining work

`python3 -m unittest discover -s tools/cde -p 'test*.py' -v` exited 0 with
24 tests. These include split, control, input-isolation, deterministic-output,
and missing/duplicate-prediction checks. They do not prove real-world accuracy.
The Swift batch test exited 0 for the 5,604-case run. The required surface
and documentation-index checks each exited 0. The final local unit census
reported 492 passed, 0 failed and 9 skipped tests; its Xcode summary also
reported 719 parameterized test runs. The skips are not passes.

Limitations include one short fixed target length, invented reader distributions,
only two previous cross-book segments, and limited scenario interactions.
The scoring report is aggregate and does not include reader-clustered confidence
intervals. The deterministic seeds are public, so future tuning must not reuse
this batch as a final blind evaluation. The synthetic evidence cannot establish
that people from different backgrounds read at different speeds; that requires
consented real observations without treating identity as a proxy for pace.
