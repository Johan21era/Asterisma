# Response to the external review (2026-10-29)

**To:** the reviewing engineer.
**Re:** the 62.84/100 grading of the CDE description.
**Status of this document:** a point-by-point reply, not a re-grading. Nothing
here claims the model is validated. Where the review was right, the repo was
changed and the change is listed in §5. Where the review was aimed at something
the code does not do, the line is cited.

You said you would not audit code you have not seen. §6 is the manifest, with
sizes and SHA-256, and §7 is the commands. The engine is ~82 KB of Python (82,315
bytes across nine files) and standard library only.

> **Postscript.** After this reply, the model was recalibrated to **v0.3**
> (`FORMULA.md` §16): equal within-dimension weights, three duplicated features
> retired, the peak operator moved to Q85 on measured reliability, and the
> interval extended to cover reference composition. Numbers in this document
> describe **v0.2**, which is frozen in `tools/cde/config/cde-v0.2.json`. Where
> the two differ, `FORMULA.md` v0.3 is canonical; the arguments below are
> unchanged by the recalibration.

---

## 1. The verdict is accepted

62.84 is a fair grade for what exists. The summary you graded was more confident
in tone than the artefact deserves, and two specific phrases in it were simply
wrong (§2). "Its statistical sophistication exceeds its demonstrated empirical
validity" is accurate, and the three-way split — engineering / measurement
science / product — is the right frame. The model is engineering that works and
measurement science that has not started.

One correction to the scorecard's premise: several subscores were necessarily
judged from prose, and prose is where the errors were. Two of the "major
statistical concerns" are objections to behaviour the code does not have.

---

## 2. Two errors in the description you reviewed — mine, not the code's

| What I wrote | What the code does |
|---|---|
| "35% of the **worst chunk**" | `quantile(per_window, 0.90)` — the 90th percentile. There is no maximum anywhere in `cde_model.raw_dimension`. |
| "**20% to 97%** through the book" | `0.02 + 0.95·(i+0.5)/12` → first window centred at **5.96%**, last at **93.04%**. The opening fifth is *not* excluded. |

The second error is the worse one: it made the sampling design look like it
skipped exposition, which it does not. The first window lands at 6% of the
character stream and every split-half test includes it. The specification
(`FORMULA.md` §5) always had the correct formula; the summary did not.

Consequences:

- The "0.65·mean + 0.35·max" formula you dismantled in §1.3 is not the formula.
  The peak is bounded by Q90 and is far less outlier-sensitive than a max. Your
  example — one chunk at 1.00 versus 0.60 — cannot happen at Q90 with twelve
  points, because Q90 interpolates between the 10th and 11th ranked windows.
- The 54.04% miss probability in §1.1 is the probability for **independent
  random** sampling. This sampler is deterministic and evenly spaced, so that
  arithmetic does not apply. The real coverage number is worse than you assumed
  in one way and better in another — see §3.1.

---

## 3. Objection by objection

### 3.1 Twelve samples (your 76.40)

**Accepted in part.** Measured coverage, as sampled tokens over book words:

| Statistic | Value |
|---|---:|
| median | **23.2%** |
| p10 | 6.6% |
| p90 | 63.0% |
| range | 0.5% – 82.2% |

25 of 135 books are more than half sampled. The 0.5% case is a 4.9M-word
omnibus sampled at 26,768 words; that book's score should be treated as a
different kind of estimate from one sampled at 82%. Your "record the proportion of the book actually
represented" is now a required per-book field (`tokens_sampled` / `words`), and
`FORMULA.md` §5 states the distribution instead of implying uniformity.

The old engine's figure for comparison: 0.75% of the book, taken from the front.

**A defect your objection exposed:** windows are ~9,600 characters and start
`0.95 · total / 12` characters apart — about 50,000 at median book size. For a
book **below about 22,000 words**, windows overlap and the bootstrap would treat
duplicated text as independent evidence. The shortest book in the corpus is 32,480 words, so no
committed score is affected — but an imported short book would be. That is now
written down as a precondition (`FORMULA.md` §5) rather than silently true.

I did not adopt adaptive sampling around discontinuities. It is a sound idea,
but it changes the sample based on the measurement, which makes the estimator
depend on its own output. If it is added, it belongs as a separate, tested
configuration, not as a patch to this one.

### 3.2 Construct redundancy (your 69.85)

**Accepted, and now quantified.** Across 135 books, averaging each feature over
its windows:

| Pair | r |
|---|---:|
| `A_morph` / `A_abstract` | **+0.954** |
| `B_sentence` / `B_clause` | **+0.951** |
| `I_content` / `I_np` | **+0.905** |
| `B_sentence` / `B_passive` | +0.883 |

So the 18 features carry roughly a dozen independent signals, and the β weights
inside A, B and I are close to arbitrary: they divide weight between two
measurements of nearly the same thing. This is in `FORMULA.md` §11.9 and §12.9.

What survives: the **six dimensions** are not redundant. Strongest
between-dimension correlation is B/G at **+0.40**; largest negative is I/K at
**−0.40**. Your proposed latent-variable model is the correct long-run answer
precisely because it would estimate six factors from eighteen correlated
indicators instead of trusting my partition.

Feature definitions were always in `FORMULA.md` §4, one line each, including
units and orientation. Your §3.2 list of required specifications is what that
table is; if it is not legible enough, that is a documentation failure and I
will rewrite it.

### 3.3 Aggregation (your 58.20)

**Accepted that 65/35 is unjustified. Refuted that it is fragile.** Every scheme
below was rebuilt end to end — new grids, then new scores:

| Scheme | Spearman vs shipped | max abs ΔD | top-10 overlap |
|---|---:|---:|---:|
| mean only (λ = 0) | 0.978 | 0.078 | 8/10 |
| **your Q85 / 70-30** | **0.994** | 0.052 | **10/10** |
| Q90 / 65-35 (shipped) | 1.000 | 0.000 | 10/10 |
| CVaR90 (mean of hardest 10%) | 0.906 | 0.210 | 7/10 |
| max (λ = 1) | 0.836 | 0.257 | 6/10 |

Sweeping λ from 0 to 1 at Q90 keeps Spearman between 0.972 and 1.000.

Your preferred alternative and mine are empirically the same model. That is a
stronger defence than an argument, but it cuts both ways: the peak term is not
doing measurable work on this corpus. Its justification is conceptual — a book
whose hardest chapter is far above its average should not read as average — and
`FORMULA.md` §11.10 now says exactly that instead of implying the term was
validated.

CVaR is a better construction than Q90 in principle; it just changes fewer
things than you expected, and it moves 3 of the top 10. I kept Q90 because
changing it now would invalidate every committed score for a 0.906 correlation
and no evidence that either is closer to a human.

### 3.4 Percentiles (your 54.60)

**Accepted, with no fix available inside this design.** All four of your
objections hold:

- the reference corpus defines difficulty;
- percentiles preserve order, not distance;
- 135 books gives 0.74% steps;
- 0.80 means "80th percentile of these 135 books", not a universal level.

`FORMULA.md` §12.10 now states the equal-spacing assumption explicitly, because
equal weights assume it and nothing here tests it.

On genre: the reference is **one person's library**, not a stratified sample. It
is heavy on fantasy, science fiction, light novels and literary fiction, with a
handful of nonfiction. The titles are all in
`docs/audits/evidence/cde-v0-scores-2026-10-29.json`; the composition can be
read directly and the skew is real. A genre-conditioned reference is on the list
in §8, not in this version.

### 3.5 Equal weights (your 83.10)

**Accepted.** Equal weights are defensible as a maximum-ignorance prior and
indefensible as a claim that a percentile point means the same thing on every
axis. The ±50% weight test (min rank correlation 0.974) shows the *current
ranking* does not depend on the weighting; it says nothing about whether equal
spacing is right. Those are different claims and I conflated them in the
summary.

### 3.6 The interval (your 43.75 — your strongest objection)

**Accepted.** It is now named a **sampling stability interval**, everywhere.

What it covers: resampling of the 12 windows, seeded, 2.5th–97.5th percentile.
What it does not cover: feature measurement error, model form, reference corpus
composition, or reader disagreement. Calling it a 95% confidence interval was
wrong and the specification no longer does.

I also ran the check you implied — does it even cover what it claims? Split each
book's windows odd/even into two half-scores:

| Statistic | Value |
|---|---:|
| median abs difference between halves | **0.0567** |
| median reported interval width | 0.1600 |
| ratio | **0.38** |
| books where halves differ by more than the interval | **3.0%** (4/135) |

So it is conservative for window sampling, not optimistic. It remains silent on
the other four uncertainties, which is the honest reading.

I did not adopt a block bootstrap. The windows are far apart relative to their
length (median book 114,000 words, 12 windows of ~1,700), and a block design
would need an assumed dependence structure that the corpus cannot identify.
Split-half is the empirical check, and it is now reported.

### 3.7 The statistical claims in §2 of your review

All five are correct as written, and all five were mis-labelled in my summary.

| My claim | Your reading | Correction adopted |
|---|---|---|
| 135/135 identical | Reproducibility, not validity | Kept as determinism only |
| 0.046 movement | Incomplete distribution | Full distribution now reported: median 0.046, p90 0.085, max 0.156 |
| 3.8–5.3 points | Ambiguous | Restated as "no single dimension carries the total; removing one costs 4–5 index points" |
| ±50% weights | Needs precise definition | It is Spearman rank correlation, reported as min 0.974, median 0.978 |
| 0.64 vs old formula | Not proof of improvement | Agreed; the file says it is not |

The 0.64 claim is the one I most over-sold. It rules out "same formula", and it
rules out nothing else.

### 3.8 Construct definition (§3.1 of your review)

**Accepted, with a clarification.** The definition is stated at
`FORMULA.md` §1: effort to process, interpret, connect, retain and understand at
a natural pace. It is a **stipulated** definition, not an operationalised
construct. Six dimensions were chosen because they are measurable from text
without a reader; they were not derived from a factor model of reading. That is
the gap your "construct validity 38.6" is measuring, and it is real.

### 3.9 Operational definitions (§3.2)

They exist, one row each, in `FORMULA.md` §4. Two deserve your suspicion:

- `H_orphan` is a **proximity heuristic**: a pronoun with no name in the same
  sentence or the two before. It is not coreference resolution. Long-range
  references will be missed. Now stated in §12.5.
- `G_names` is capitalisation plus a function-word blocklist. It will miss
  lowercase names and mis-read sentence-initial common nouns. Stated in §12.4.

### 3.10 Sampling window (§3.3)

My error, corrected in §2 above. Actual range 5.96%–93.04%. Nothing is excluded
before or after; the 2% and 97% margins are just the half-step of the spacing
formula.

### 3.11 Reader calibration (§3.4)

**Accepted.** The model measures text, not the interaction. Your two-output
proposal — intrinsic text demand versus reader-relative demand — is the right
architecture, and the second output should not exist until there is data to fit
it. The app should not show either as a verdict yet.

### 3.12 Validation design (§3.5)

**Accepted — this was the most substantive gap.** `PHASE-3-VALIDATION.md` §5.1
now fixes, before any data exists:

1. a linear mixed model with random intercepts for book, passage-within-book and
   rater;
2. a variance decomposition reported *before* any model comparison, so the study
   fails loudly if passage-level variance swamps book-level variance;
3. ICC(2,5) with a floor of 0.40 below which the instrument, not the model, is
   declared broken;
4. a **cluster bootstrap over books** for every reported CI;
5. a random-effects logistic model for the pairwise task, with ties separate.

Your nested-observations objection is exactly right, and 600 ratings would have
been counted as 600 independent points without this.

Preregistration already existed and is unchanged: fixed splits by series,
untouched test set, thresholds written before data. `PHASE-3-VALIDATION.md` §7.

### 3.13 Missing dimensions (§4 of your review)

**Accepted.** The directive listed twelve; six exist. Present: lexical,
syntactic (proxied), entity interaction, continuity, density, dialogue. Absent:
inferential burden, conceptual abstraction, causal complexity, narrative
structure, knowledge prerequisites, referential distance.

Your framing is the one I should have used: this is closer to a measure of
**surface linguistic and discourse complexity** than of reading difficulty.
`FORMULA.md` §12.2 says "six dimensions, not twelve" and now §15 says the
construct is stipulated.

I will not add the missing six as keyword heuristics. That would raise the
feature count and lower the honesty, which is the trade the old engine made.

### 3.14 Gates (§5 of your review)

| Gate | Status |
|---|---|
| 1. Measurement integrity | **Partial.** Definitions and determinism exist; extraction accuracy against a second implementation has not been tested. |
| 2. Construct validity | **Not done.** Needs human ratings or a factor analysis on a larger corpus. |
| 3. Human validation | **Designed, not run.** `PHASE-3-VALIDATION.md`. |
| 4. Generalisation | **Not done.** The reference is one library. |

You asked for comparisons against established readability baselines. Flesch–
Kincaid is computable on the same windows; it is not yet in the evaluation
battery, and it should be, because "our complexity buys something" is currently
unproven against the cheapest possible baseline.

---

## 4. Where I disagree

**One thing only.** The review treats the absence of validation as a deficiency
of this iteration. It is a constraint inherited from the data: the previous
grading round was declared void by the owner on 2026-10-29 because its
instrument could not be defended. Building a second unvalidated instrument and
declaring it better would repeat that failure with more arithmetic. The engine
is deliberately gated behind "do not ship until Phase 3 passes", and that gate
is in the file, not just in the summary.

Everything else in the review — every numbered objection to the statistics — I
accept as stated.

---

## 5. What changed in the repo because of this review

| Change | File |
|---|---|
| New adversarial measurement script (coverage, redundancy, aggregation, λ, split-half) | `tools/cde/cde_critique.py` |
| Raw output of every number in this document | `docs/audits/evidence/cde-critique-2026-10-29.json` |
| Interval renamed and its scope stated | `FORMULA.md` §7 |
| Coverage distribution and overlap precondition | `FORMULA.md` §5 |
| Split-half check | `FORMULA.md` §11.8 |
| Feature redundancy table | `FORMULA.md` §11.9 |
| Aggregation-alternative table and λ sweep | `FORMULA.md` §11.10 |
| Percentile spacing and feature redundancy as explicit limitations | `FORMULA.md` §12.9–10 |
| "Adversarial review, answered with measurements" | `FORMULA.md` §15 |
| Mixed model, variance decomposition, ICC floor, cluster bootstrap, pairwise model | `PHASE-3-VALIDATION.md` §5.1 |
| One-hop rows for the review response | `docs/INDEX.md` |

Not changed: the formula itself, the weights, the reference grid, and every
committed score. The review produced no evidence that a different coefficient
would be better, and changing one to look responsive would be the exact failure
mode under discussion.

---

## 6. Manifest

Sizes in bytes; SHA-256 as the files stand in the working tree at **v0.3**
(refreshed after the recalibration, which changed three of them).

| Path | Bytes | SHA-256 |
|---|---:|---|
| `tools/cde/cde_extract.py` | 5,722 | `afc25fb98dda7dbc3235a087a48feabdbaf3176d2f92938f6db2095fa2d9ced3` |
| `tools/cde/cde_text.py` | 7,155 | `c84662557855322026d7354d75c832ad1469a82b12b9bf02556c5a5143225c3e` |
| `tools/cde/cde_features.py` | 10,453 | `0783e7aaa594e9af85fd3a7cd4c6f7e5c6025dc8a6ce0e3712ad5ff49f1a1660` |
| `tools/cde/cde_model.py` | 13,323 | `9ffcc9635a1299694a236f596c0d7c29a049ed1f2c8398c2d631038caec92d75` |
| `tools/cde/cde_run.py` | 15,658 | `fd5298c206fcbb843d8317dd4dbce3ed23c29701a1c90a11467c8d225e61c059` |
| `tools/cde/cde_eval.py` | 8,450 | `fc891814f222ddfdd69a454c89d354d1fb1b9934019fb0e4d54df20f60b732b8` |
| `tools/cde/cde_critique.py` | 11,296 | `a0a3327867b838d93482e104a592fa6b3d74e9a936679feb2e05f9cb725ca199` |
| `tools/cde/cde_recalibrate.py` | 7,386 | `fbe72e1e092c382b743689ef66dbd81ff21e12a102bebd4262105f4bc55c8423` |
| `tools/cde/test_cde.py` | 3,450 | `60a63665df8aa2135383511a133e85ba3baf3395d14c8d6673c9ca6c57d93b4d` |
| `tools/cde/config/lexicon-v1.json` | 265,028 | `809517c43f1099de48307888a5c960e958136cc9cb00fcc325af5bc1cab0e325` |
| `tools/cde/config/reference-v3.json` | 10,281 | `7b1536e11afb357beadc8b41a0a962f349da0d55ef042a52e3b8b5ce127a11cf` |
| `tools/cde/config/cde-v0.2.json` | 1,711 | `37f1739e95d40b0d05bcd04a3e2972f489b546957ed7e87014f36f5dda7c5628` |
| `docs/audits/evidence/cde-v0-features-2026-10-29.json` | 1,077,188 | `6641ec16cba25e8cf5eca89c2f1b006474a703415525f1c51db57500a6720eff` |
| `docs/audits/evidence/cde-v0.3-scores-2026-10-29.json` | 174,376 | `5205c6a389c7efa9912f0226770b7d031faf70f2189701fbec34d8532aa09f19` |
| `docs/audits/evidence/cde-critique-v0.3-2026-10-29.json` | 2,914 | `7d1523bf67572c21a92d0c91f034e1a4d9d83e6b4181287482a86da52b88221e` |
| `docs/audits/evidence/cde-recalibration-2026-10-29.json` | 975 | `9dee9efb07d4f123c3ff377d1ac3818242bbc651136372b8fc79a679023e0bfe` |

`test_cde.py` is 9 tests. There is no hidden model code: `cde_model.py` is the
whole formula, 329 lines including docstrings. `cde_critique.py` is 301 lines;
`cde_recalibrate.py` is 192.

The v0.2 artefacts this reply originally cited remain on disk unchanged:
`reference-v1.json` (`9ca957b7…41243a`) and `cde-v0-scores-2026-10-29.json`
(`cb0a1220…81fcc5`). They are the historical record, not the current model.

---

## 7. Reproduction

```bash
python3 -m unittest discover -s tools/cde -p 'test_*.py'     # 9 tests, 0.024 s
python3 tools/cde/cde_critique.py \
  --features docs/audits/evidence/cde-v0-features-2026-10-29.json \
  --reference tools/cde/config/reference-v1.json \
  --scores docs/audits/evidence/cde-v0-scores-2026-10-29.json \
  --out /tmp/critique.json                                    # 0.16 s
python3 tools/cde/cde_eval.py \
  --features docs/audits/evidence/cde-v0-features-2026-10-29.json \
  --reference tools/cde/config/reference-v1.json \
  --engine docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json  # 47 s
```

**Not reproducible from a clean checkout:** `frequency` and `calibrate`. They
need the EPUB corpus, which is not in this repository, and they would rewrite
the frozen files. If you want a from-scratch rebuild, the folder is
`asterisma new testing suite` and the queue is
`docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json`.

---

## 8. What would move the grade, in order of effect

1. **Human ratings.** Nothing else moves construct validity, predictive validity
   or generalisation. 120 passages, 5 raters, ~120 rater-hours. Until then, no
   number in this repo should be called accuracy.
2. **A factor model on a larger corpus.** Twenty thousand books would let the
   six dimensions be estimated instead of stipulated, and would answer the
   redundancy objection properly rather than with a correlation table.
3. **A parser for `B`.** Dependency depth is the single largest gap between the
   directive and the build, and it is measurable without humans.
4. **A genre-stratified or second reference corpus.** Tests whether the index
   survives leaving this library.
5. **Flesch–Kincaid in the evaluation battery.** The baseline that makes
   "complexity buys something" testable.
