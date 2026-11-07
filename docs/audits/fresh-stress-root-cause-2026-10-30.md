# Fresh stress-run root-cause audit — 2026-10-30

**Scope.** This is an analysis of the saved predictions from the 100 fresh rounds. This audit changed no estimator, production weight, candidate weight, or saved prediction. The numbers below come from `python3 tools/cde/audit_fresh_tail.py` (exit 0); its full output is preserved as a compressed log in [the evidence archive](evidence/fresh-stress-evidence-archive-2026-10-31.md); the raw log was deleted on 2026-10-31. This audit supplements [the 100-round report](fresh-reading-stress-100-2026-10-30.md); it does not replace that report's results or turn synthetic outcomes into measurements of people.

## The question

The 100-round report showed the experimental candidate with a lower median error but a higher worst case. That comparison mixes two different questions:

1. Which synthetic cases produce the largest absolute errors?
2. Which of those errors are caused by the candidate rather than by the production baseline?

The answers are different, and the difference matters more than the ranking.

## Headline

All 991,400 saved cases:

| Model | Median | Mean | 90th percentile | Worst | Spikes |
|---|---:|---:|---:|---:|---:|
| Production baseline | 21.69% | 42.07% | 71.26% | 2865.27% | 91,273 |
| Experimental candidate | 16.57% | 39.86% | 69.30% | 3628.89% | 88,810 |

**48.9% of cases produce output numerically identical to the baseline.** In the `none` regime (240,800 cases) and the `cross_book` regime (240,800 cases) this is 100.0%: without at least one usable timing from the target book, `recent` is absent and the blend falls through to the same filtered value. The 800 constant-pace controls also coincide because their recent and full-history means are equal. The all-case table therefore counts the production model twice for nearly half its weight.

On the 507,095 cases where the candidate output differs:

| Model | Median | Mean | 90th percentile | Worst | Spikes |
|---|---:|---:|---:|---:|---:|
| Production baseline | 12.61% | 21.44% | 48.48% | 1776.25% | 17,006 |
| Experimental candidate | 8.52% | 17.11% | 25.11% | 3628.89% | 14,543 |

The candidate is better on every central measure and on spike count, and worse on the single worst case. The rest of this audit explains that one regression and the cases that dominate the absolute maximum.

## Finding 1 — the candidate's own tail is entirely interruption contamination

Of the 1,000 largest candidate errors among the 507,095 cases where the candidate output differs:

| Scenario world | History regime | Cases |
|---|---|---:|
| `interruptions` | `sparse` | 914 |
| `interruptions` | `same_book` | 86 |

No other scenario appears. The tail is not spread across the harness; it is one scenario world, across two history regimes.

On the 68,400 interruption cases where the candidate output differs:

| Model | Median | Mean | 90th percentile | Worst |
|---|---:|---:|---:|---:|
| Production baseline | 13.77% | 19.65% | 43.07% | 1776.25% |
| Experimental candidate | 11.01% | 56.21% | 160.58% | 3628.89% |

On the other 438,695 differing cases, with interruptions excluded:

| Model | Median | Mean | 90th percentile | Worst |
|---|---:|---:|---:|---:|
| Production baseline | 12.43% | 21.72% | 50.32% | 499.58% |
| Experimental candidate | 8.26% | 11.01% | 22.69% | 300.12% |

Without interruptions, the candidate is better at every reported statistic, including the maximum. The tail regression is specific to idle-time contamination, not a general weakness of the blend.

## Finding 2 — two target samples make the outlier filter powerless

The `sparse` recipe appends exactly two target-book pages: `2 if regime == 'sparse' else 12` in [synthetic_eval.py:107](../../tools/cde/synthetic_eval.py#L107). All 240,400 sparse cases have exactly two target-book samples, confirmed by the audit script.

`PageDurationPolicy.robustMeanSeconds` ([AnalyticsEngine.swift:399](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L399)) keeps values up to `median * 3` ([line 396](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L396)). Its median is `sorted[count / 2]`, not the average of the middle pair. With two values the median is the larger one, so both values survive unless the larger exceeds three times the smaller. A pair of 694.7 and 718.4 survives trivially.

The candidate's `recent` path is the robust mean of the last eight usable target timings ([AdversarialEvaluationTests.swift:81](../../AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift#L81)), and `recent` receives 0.998814921031034 of the blend ([fresh_100.py:95](../../tools/cde/fresh_100.py#L95)). With two samples, that is simply the mean of two page durations multiplied by 40.

Round 29, case `7610b1d828f009e9c071`:

- target-book durations: 694.7023745644276 and 718.4242053601389;
- median: 718.4, so the 3× bound is 2,155.3 and both values are retained;
- `706.56 × 40 = 28,262.5`, exactly the saved candidate;
- saved baseline `1,061.5` is the pooled prior-book mean (26.5) times 40;
- synthetic target: 757.9 seconds, so the candidate error is 3,628.89%.

The log reproduces the same candidate identity for rounds 18, 82, 85, 5, 32, 3, 92, 24 and 1: each candidate equals 40 times the mean of its two target durations. The baseline in those cases is the pooled cross-book pace. It matches the prior-only mean in round 29 (1,061.5) and differs slightly in some others because the pooled set also contains the target's two samples, which can move the pooled median and its 3× bound (round 3: 768.2 against a prior-only 781.0).

Two design details make this worse than a tuning problem:

- **The guard is one-sided.** It fires only when the target's pace is much faster than the prior books: `all < prior * 0.35` ([line 88](../../AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift#L88)). A target contaminated by idle time is much slower, so it cannot trigger the fallback.
- **The guard is almost weightless.** Even when it fires, it contributes 0.001185 to the blend, or 0.12%. The candidate is effectively `recent` alone.

The distribution shows the trade-off. On all 240,400 sparse cases:

| Model | Median | Mean | 90th percentile | Worst |
|---|---:|---:|---:|---:|
| Production baseline | 24.92% | 33.27% | 59.01% | 631.10% |
| Experimental candidate | 10.76% | 22.96% | 26.91% | 3628.89% |

The candidate is better in the middle and catastrophically worse at the maximum. That is consistent with replacing a moderately noisy cross-book estimate with an almost-unfiltered two-sample estimate.

## Finding 3 — when contamination is the majority, the median moves with it

The evaluation corpus contains a different interruption recipe: add 180 seconds every third page and 700 seconds every seventh page ([adversarial_eval.py](../../tools/cde/adversarial_eval.py)). With short sessions, contaminated pages can occupy or exceed the median. Then the 3× bound rises with the contamination and stops rejecting most of it.

Round 60, the largest corpus error, is evaluation scenario 1:

- target durations: 966.7, 71.3, 69.1, 254.0, 72.1, 72.3, 254.1, 759.8;
- median: 254.0; upper bound: 762.0; 7 of 8 values retained;
- retained mean: 221.8; `221.8 × 40 = 8,873.2`, exactly the saved baseline and candidate;
- synthetic target: 2,217.6 seconds; error 300.1%.

Round 69 is the same shape with 10 samples: median 227.5, upper bound 682.5, 8 of 10 retained, baseline `112.4 × 40 = 4,496.2`. The candidate is slightly different there (`4,947.0`) because its `recent` suffix is not the same set as the full history, but both models over-predict the same 1,302.0-second target.

Of the 1,000 largest corpus errors, 508 are evaluation scenario 1. The same saturation appears in the synthetic `interruptions/same_book` recipe, which supplies 1,508 of the spikes in differing cases.

This one is not specific to the candidate. It is a limitation of a median-relative filter whose reference point is itself contaminated. The filter assumes interruptions are a minority of a session; these recipes violate that assumption deliberately.

## Finding 4 — cross-book pooling lets one book dominate

`AnalyticsEngine.crossBookReadingSpeed` ([AnalyticsEngine.swift:75](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L75)) pools every duration from every book, then applies one median and one 3× bound to the pooled list. There is no per-book normalization before pooling.

Round 59, case `4fd1468cbf1c0237dd41`:

- two prior books, 12 durations each;
- one book's durations average 978.0 seconds, the other's 24.9 seconds;
- pooled median 814.4; upper bound 2,443.3; all 24 values retained;
- pooled mean 501.4; `501.4 × 40 = 20,057.1`, exactly the saved baseline and candidate;
- synthetic target: 676.4 seconds; error 2,865.27%.

The slow book contributes half the samples at roughly 40 times the other book's pace, so the pooled mean lands between them. The fast reader's actual future pace is about 17 seconds per page. The production estimator has no way to prefer the faster book because it never computes a pace per book before combining. When the target book has no timings, as here, the candidate cannot change this result: it is 100.0% identical in the `cross_book` regime.

All ten largest shared errors have this shape.

## Finding 5 — cold start is the largest source of spikes, and weights cannot fix it

The `none` regime has no history at all: 240,800 cases, 24.3% of the run. Both models return the fallback `defaultSecondsPerPage` of 120 ([AnalyticsEngine.swift:425](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L425)) times 40 pages, or 4,800 seconds. The audit confirms 100.0% identical output.

| Model | Median | Mean | 90th percentile | Worst |
|---|---:|---:|---:|---:|
| Production baseline | 46.04% | 76.03% | 175.00% | 2536.09% |
| Experimental candidate | 46.04% | 76.03% | 175.00% | 2536.09% |

The two columns are identical because the prediction is identical. These cases supply 56,212 of the 88,810 spikes, or 63.3%. No change to blend weights can affect them: the candidate has no different value to offer when there is no history. Fixing cold start requires a different input (a prior book, a stated reading speed, or a user preference), not a better formula.

## Finding 6 — the absolute worst cases are unlearnable by construction

The `unrelated` world gives the target book a hidden response effect orthogonal to the six ADF dimensions the estimator can see. It contains 137,200 cases. Candidate errors there: median 15.13%, mean 82.93%, 90th percentile 195.29%, worst 2,865.27%.

- 814 of the global top 1,000 errors are `unrelated/cross_book`;
- 92 of the global worst 100 are `unrelated/cross_book`;
- in those cases the target has no history, so the candidate equals the baseline exactly.

The global worst 100 span 66 of the 100 rounds, so this is not one unlucky seed.

The adversarial set contains a related designed reversal. Slot 6 gives the target book 15 pages at 0.12 times the reader's pace, then a future at 1.8 times that pace ([adversarial_eval.py](../../tools/cde/adversarial_eval.py)). The ten largest under-estimates are all 93.4% and all adversarial; a history at 0.12× against a future at 1.8× explains a shortfall of roughly that size. The guard condition is satisfied by construction here (0.12 is below 0.35), but the guard contributes 0.12% of the blend, so it cannot rescue the prediction.

These are information limits in the scenarios. They are worth reporting because they set the ceiling on what any reweighting can achieve on this harness, but they are not estimator defects.

## Finding 7 — the controls confirm arithmetic, not discrimination

Both control families report 0.00% error in each of their 400 cases. Each control reader has a constant-pace history, so `40 × pace` is exact. The "different" control pairs two separate readers with different constant paces; it does not test one reader whose pace changes. The controls therefore confirm that the multiplication and the adapter are wired correctly, not that the model distinguishes fast from slow readers.

## Harness artifact or production defect?

| Observation | Where it lives | Classification | What would test it |
|---|---|---|---|
| Sparse cases always have exactly two target samples | Harness recipe | Harness exposes a production weakness: `recent` has no minimum sample count | Require at least three usable target timings before trusting `recent` |
| Median-relative 3× bound fails when contamination is the majority | Production filter | Production limitation | Compare a fixed absolute cap, a trimmed mean, or a lower quantile on the corpus recipes |
| One slow or contaminated book dominates the pooled pace | Production structure | Production defect candidate | Compute a robust mean per book, then combine across books |
| No history at all falls to 120 s/page | Production fallback | Information limit | Needs an external prior; not reachable from the current inputs |
| `unrelated` world and adversarial slot 6 | Harness design | Unlearnable by construction | Exclude from accuracy claims; keep as a ceiling test |
| 48.9% of cases are numerically identical to the baseline | Harness composition | Reporting dilution | Report the subset where the candidate output differs alongside the all-case table |

## What I would test next

At the time of this audit, nothing in this list had been implemented, measured, or approved; each was a hypothesis for a future run. Items 1–3 were implemented on 2026-10-30 and tested in the 200-round run; their status is recorded below. Item 4 is used in that report. Item 5 remains not done.

1. **Minimum sample count for `recent`.** Require at least three usable target timings; otherwise fall back to the guarded value or the baseline. This targets the 914 sparse cases in the tail directly.
2. **Per-book normalization before cross-book pooling.** Compute each book's robust mean first, then combine across books (for example, a median of book means). This targets the round-59 shape without changing how a single book's pages are filtered.
3. **Two-sided guard.** Also fall back when the target's median is much slower than the prior books, not only when it is much faster.
4. **Report the differing subset.** Any future comparison should state how many cases actually differ, because nearly half of this run does not.
5. **Stop-on-spike re-run.** If the owner wants the original cat-and-mouse protocol, run the new rules with a pre-registered stop rule and restart at round one. This audit did not do that.

## Implementation status — 2026-10-31

The owner asked for the audited defects to be fixed before a 200-round rerun. The production changes are in [`AnalyticsEngine.swift`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift): per-book normalization and consensus in [`crossBookReadingSpeed`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L83) and [`consensusSeconds`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L459); the `max(median, lowerQuartile × 3)` ceiling in [`robustMeanSeconds`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L424) and [`upperBound`](../../AsterismaV2.5/Engines/AnalyticsEngine.swift#L444). The candidate-only rules are in the evaluation adapter: [`minimumRecentTimings = 3`](../../AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift#L71) and the two-sided `0.35/3.0` guard at [lines 73–74](../../AsterismaV2.5Tests/Engines/AdversarialEvaluationTests.swift#L73). They are not production wiring.

The results are in [the 200-round report](fresh-reading-stress-200-2026-10-30.md). The fixed baseline improved overall against the saved legacy comparator (median 18.98% against 21.42%; 170,404 spikes against 185,341), with a `corpus-evaluation` median exception. That comparator is a hybrid: it equals the baseline on `same_book` and uses the current per-book policy there, so it isolates the pooling change on no-personal-speed cases, not the ceiling change on personal-speed books. The candidate lost to the fixed baseline at the fitted 0.979 weight and at the pre-registered 0.5 weight; the report records the mechanisms. The weight was fitted only on rounds 1–100 and frozen for 101–200. The stop-on-spike protocol (item 5) was not run. No production weight was changed.

## Reproduction

```bash
python3 tools/cde/audit_fresh_tail.py
```

The script reads the saved `rounds-*-graded.json`, `rounds-*-input.json` and `rounds-*-truth.json` files. It rebuilds each synthetic case's world and regime from the generator's deterministic hashes, reproduces the Swift median convention, and prints the tables above. It does not invoke Xcode and does not modify any file. The run recorded here exited 0.

## Limitations

- The outcomes are generated assumptions, not measurements of real readers. Absolute error percentages describe the harness, not people.
- Scenario labels are not stored in the truth files. They were reconstructed from the generator code and the hashed case IDs; the audit reports the reconstruction as a mapping, not as recorded metadata.
- One prediction per case, with no independent hand grading and no second reader. The earlier report's SKIPPED disclosures still apply.
- The 100 rounds reuse the same recipes and book sets; only the seeds are new. Recurrence across rounds shows stability of the recipe, not independence.
- Live app behavior — storage reloads, real interruptions, page-turn events — was not exercised. The interruption evidence is synthetic.
- The production estimator was not re-run for this 100-round audit. The saved baseline and candidate values were audited as saved, and the arithmetic was reproduced from the saved inputs. The later 200-round run did invoke the production estimator; see the implementation-status section.
