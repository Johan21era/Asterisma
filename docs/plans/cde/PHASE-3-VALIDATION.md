# CDE Phase 3 — validation protocol

- **Status: NOT RUN.** No human has graded a passage for this protocol. Nothing in
  this document is a result.
- **Blocks:** replacing the shipped difficulty engine. Phase 1 is done
  (`PHASE-1-AUDIT.md`), Phase 2 is done (`FORMULA.md`), Phase 4 (prototype) is done
  (`tools/cde/`). Phase 5 cannot start without the data this protocol produces.
- **Why it exists:** the previous round of testing produced grades, and those
  grades were declared void because the instrument behind them could not be
  defended. Repeating a weak instrument more carefully does not fix that. This
  protocol is designed so that a sceptic can re-derive every number from raw
  rater responses and the committed corpus artefacts.

---

## 1. What is being measured

The CDE output `D` is a claim about **cognitive effort**, not about comprehension
outcome and not about grade level. The validation target must therefore be an
effort judgement, not a quiz score, and not a vibes-based book ranking.

Primary target:

> For a 700-word passage, read once at a natural pace, how much effort did
> understanding it require?

Secondary target:

> Which of two passages required more effort?

The secondary target exists because people are far better at relative judgements
than at absolute ones, and it gives us a scale-free check on the primary target.

---

## 2. Ground truth: what we do not have

| Candidate | Status |
|---|---|
| Prior human grades (the "149-book" round) | **Void**, by owner decision, 2026-10-29 |
| Shipped engine's multiplier | Not ground truth; `r = +0.975` with Flesch–Kincaid, i.e. a readability proxy |
| Flesch–Kincaid / SMOG / Dale–Chall on the same text | Baselines, not truth |
| CDE v0 output | The thing under test |

There is currently **no** set of human effort ratings for these books. Every
accuracy statement about CDE v0 in `FORMULA.md` is therefore absent by design;
only reproducibility and internal behaviour are reported.

---

## 3. Instrument

### 3.1 Unit of judgement

A **passage of 650–800 words**, taken from the same 12-window sampling scheme the
engine uses, so the rated unit and the modelled unit coincide. Passages are
stripped of chapter headings, book titles, author names, and any in-text clue to
the title or series.

### 3.2 Per-passage tasks, in order

1. Read the passage once, at natural speed, no notes, no rereading. Time recorded
   (self-reported start/stop is acceptable; total elapsed is logged).
2. Rate effort on a **7-point anchored scale**:
   1 = effortless, could skim
   3 = easy, needed no backtracking
   5 = demanding, had to re-read a sentence or hold earlier detail
   7 = exhausting, lost the thread at least once
3. Answer **two comprehension items** written by a second person from the passage
   (not by the rater, not by the model). Items target a fact stated in the passage
   and an inference the passage supports. These are a manipulation check: if a
   rater scores 0/2 on both items, their effort rating is not measuring
   comprehension of that passage and is flagged, not deleted.
4. Answer one attribution item: "what made this passage hard?" with a fixed
   multiple-choice list mirroring the six dimensions (vocabulary / sentence
   structure / too many people and relationships to track / jumps in time or
   place / too much packed in / dialogue), plus "it was not hard".

Step 4 is the only place the model's own dimensions appear, and it appears as a
*check* on attribution, never as an input to the score.

### 3.3 Pairwise task

Each rater also receives 12 forced-choice pairs (same rater pool, different
passages), drawn so that the model predicts a large difference in one case and a
small one in another. No ties allowed; "too close to call" is recorded as its own
answer and analysed separately.

### 3.4 Rater pool and blinding

- **≥ 5 independent raters per passage**, ≥ 8 preferred.
- Passages randomised per rater; no rater sees two passages from the same book.
- No rater is told any model's score, any band, or any book identity.
- Raters who authored the comprehension items are excluded from rating those
  passages.

---

## 4. Sampling design

| Level | Count | Rule |
|---|---:|---|
| Books | 40 | Stratified by CDE decile, 4 per decile, series kept together |
| Passages per book | 3 | Window 2, 6, 10 of the 12 (early / middle / late) |
| Passages total | 120 | |
| Ratings needed | 600 | 5 raters × 120 passages |
| Pairwise items | 144 | 12 per rater × 12 raters |

40 books is chosen so that a book-level Spearman can distinguish ρ = 0.5 from
ρ = 0.7 with reasonable power; it is not chosen to make the number look good.

**Series rule.** Books from one series go to the same split. Otherwise a model
could learn "Narnia is easy" from book 3 and be scored on book 5.

---

## 5. Splits and what may be fitted

| Split | Books | Use |
|---|---:|---|
| Train | 28 | Fitting β and weights, if we fit anything at all |
| Validation | 6 | Choosing between configurations |
| Test | 6 | **Touched once**, at the end, for the headline number |

Rules:

- Equal weights (`FORMULA.md` §4) are the **pre-registered default** and are
  reported whatever else is fitted.
- If β or weights are fitted, fitting is non-negative least squares on
  train-only ratings with a sum-to-one constraint, and the fitted variant is
  reported alongside the default, never instead of it.
- Reference grids are rebuilt from the **train books only** for the test
  evaluation, so no test book contributes to its own normalisation.
- Interaction terms may only be added if their train-set gain survives a
  bootstrap (1,000 resamples, 95% CI excludes zero) **and** they do not lower
  validation ρ.
- Any choice made after seeing validation results is logged in the experiment
  log with the reason. Test stays untouched until the choice is frozen.

### 5.1 Unit of analysis (fixed before data exists)

Ratings are **nested**: passages within books, and every rater sees many
passages. Treating 600 ratings as 600 independent observations would overstate
the evidence and inflate apparent accuracy. The analysis is therefore fixed now:

1. **Primary model.** A linear mixed model on the 1–7 effort rating with fixed
effects for the six CDE dimension percentiles (or `D`, in the reduced form) and
random intercepts for book, passage-within-book, and rater. Report the fixed
effects with 95% CIs and the variance components.
2. **Variance decomposition first.** Report the share of rating variance
   attributable to books, to passages within books, and to raters, *before* any
   model comparison. If passage-within-book variance swamps book variance, the
   book-level target is not well defined and the study has failed for a reason
   that has nothing to do with CDE.
3. **Inter-rater agreement.** ICC(2,5) on the passage means, with its CI. Below
   **0.40**, the instrument is too noisy to validate anything and the result is
   reported as an instrument failure, not a model failure.
4. **Cluster bootstrap.** All CIs for ρ_book resample **books**, not ratings or
   passages, because books are the unit the product would deploy on.
5. **Pairwise outcomes.** Analysed with a random-effects logistic model on the
   choice, with the model's predicted difference as the regressor; ties reported
   separately and never folded into either side.

The mixed model is not sophistication for its own sake: it is the minimum needed
to keep nested ratings from being counted as independent evidence.

---

## 6. Metrics

Reported together, always, with bootstrap CIs over books:

| Metric | Definition | Why |
|---|---|---|
| **ρ_book** | Spearman(mean rater effort, `D`), book level, test split | The headline |
| **ρ_pair** | Share of pairwise choices the model orders correctly | Scale-free check |
| **MAE_band** | Mean absolute error in band units | Is the label right, not just the order |
| **PICP** | Share of books whose rater-mean lies inside the CDE interval | Is the uncertainty honest |
| **ρ_FK** | Same as ρ_book but for Flesch–Kincaid on the same passages | The baseline to beat |
| **ρ_ship** | Same for the shipped multiplier | The engine to beat |
| **within-series SD ratio** | mean within-series SD ÷ corpus SD | Over-reaction to series noise |
| **attribution agreement** | Share of step-4 answers matching the dimension with the largest percentile | Does the model's *why* survive contact |

`PICP` is the one most likely to embarrass the model: the intervals in
`FORMULA.md` §11.7 are bootstrap-over-windows intervals, not calibrated
prediction intervals, and they will probably be too narrow.

---

## 7. Pre-registered success criteria

Fix these now, before any data exists, so the outcome cannot be negotiated later.

**Replace the shipped engine** only if all of:

1. `ρ_book ≥ 0.65` with the 95% CI lower bound above **0.45**.
2. `ρ_book` exceeds `ρ_FK` by **≥ 0.10** absolute.
3. `ρ_book` exceeds `ρ_ship` by **≥ 0.05** absolute.
4. `PICP ≥ 0.80`.
5. `within-series SD ratio ≤ 0.60`.

**Ship as an advisory signal only** (shown with intervals, no band labels) if
1–4 hold but 5 fails, or if `ρ_book` lands in **0.45–0.65**.

**Do not ship** if `ρ_book < 0.45`, or if `ρ_book ≤ ρ_FK`, or if `PICP < 0.60`.

A negative result is a result. `FORMULA.md` stays as documentation of what was
tried, and the shipped engine keeps its current behaviour.

---

## 8. Cost

| Item | Estimate |
|---|---|
| Passage preparation and comprehension items | ~12 hours of work |
| Rating time | 120 passages × 5 raters × ~12 min ≈ 120 rater-hours |
| Analysis | ~4 hours, scripted |

This is the real reason the phase is blocked. It is a person-hours problem, not a
software problem, and it cannot be shortcut by a better formula.

---

## 9. What can proceed without human data

Done already:

- the audit of the shipped engine (`PHASE-1-AUDIT.md`);
- the six-dimension model and its exact specification (`FORMULA.md`);
- the prototype and its evaluation battery (`tools/cde/`);
- determinism, sampling stability, ablation, weight sensitivity, independence
  from the shipped formula, within-series consistency.

Still possible without humans, and worth doing next:

- **A parser-based `B`.** Replace the passive/pronoun proxies with dependency
  depth and clause embedding from a real parse. This is the largest known gap
  between what the directive asked for and what exists.
- **A proper named-entity pass** to replace the capitalisation heuristic, which
  is the second-largest.
- **A withheld-information detector** built from narrative questions raised and
  resolved, which is the dimension most central to the stated mission and
  entirely absent.

None of these can be justified by accuracy until §3 produces data. They can be
justified by construct validity — they measure the thing they claim to measure —
which is a different and weaker argument, and should be labelled as such when
made.

---

## 10. Reproduction

Nothing in this document can be reproduced, because it has not been run. When it
is, the artefacts it must leave behind are:

- raw per-rater responses (one row per passage × rater), untransformed;
- the exact passage texts used, with their source book and window index;
- the split assignment, by book;
- the analysis script, committed, with the seed;
- the metric table with bootstrap CIs;
- a row in the experiment log naming the config version tested.

Without the raw rows, a result is not auditable, and an unauditable result is the
thing this project is trying to stop producing.
