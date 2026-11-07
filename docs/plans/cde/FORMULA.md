# The Asterisma Difficulty Formula (ADF) — specification v0.3

- **Status:** implemented and measured; **not validated against human readers**.
- **Code:** `tools/cde/` (pure Python 3.9, standard library only).
- **Frozen inputs:** `tools/cde/config/reference-v3.json`,
  `tools/cde/config/lexicon-v1.json`, `tools/cde/config/cde-v0.2.json` (the
  previous configuration, kept so v0.2 stays reproducible).
- **Measured artefacts:** `docs/audits/evidence/cde-v0-features-2026-10-29.json`,
  `docs/audits/evidence/cde-v0.3-scores-2026-10-29.json`,
  `docs/audits/evidence/cde-critique-v0.3-2026-10-29.json`,
  `docs/audits/evidence/cde-recalibration-2026-10-29.json`.
- **Predecessors:** `docs/plans/cde/PHASE-1-AUDIT.md` (why the shipped engine was
  rebuilt), `docs/plans/cde/REVIEW-RESPONSE.md` (external review, answered).

Read §12 first if you want to know how much to trust it. §16 records what changed
from v0.2 and what each change bought.

---

## 0. Name

This document specifies **one** model, and that model has one canonical name.
Use it in prose, in code comments, in commit messages and in review
correspondence; do not invent a fresh handle per document.

| Form | Value | Where it is used |
|---|---|---|
| Full name | Asterisma Difficulty Formula | prose, UI copy, review correspondence |
| Handle | **ADF** | tables, changelogs, shorthand |
| Versioned handle | **ADF v0.3** | anywhere a bare "ADF" could be read as v0.2 |
| Machine identifier | `asterisma-difficulty-formula@0.3` | code, JSON, tooling |
| Code symbols | `FORMULA_NAME`, `FORMULA_HANDLE`, `FORMULA_ID`, `FORMULA_VERSION` | `tools/cde/cde_model.py#L44` |
| Artifact string | `cde-v0.3` | the `"version"` field already written into evidence JSON |

### Three nearby names that are not the formula

Conflating these is how a specification starts contradicting itself.

- **CDE — Cognitive Difficulty Engine.** The *instrument*: the corpus, the
extractor, the frozen lexicons and reference grids that turn EPUBs into
measurements. CDE is the engine; ADF is the model that engine computes.
- **`DifficultyAnalyzer`** — the *legacy in-app* engine (word length, sentence
length, a multiplier). ADF replaces its output; it is not a later version of it.
Measured independence from it is 0.626 (§11).
- **`D`** — the *number* the formula returns, `D ∈ [0,1]`. The formula is the
procedure; `D` is one run of that procedure on one book.

In one line: **the engine is CDE, the formula is ADF, the answer is `D`.**

---

## 1. What the number is

The output `D ∈ [0,1]` is a **text-demand index**: how much processing effort the
sampled prose asks of a reader, relative to a frozen reference corpus of 135
books. `D = 0.5` means "median book in that reference set". It is not a
probability, not a grade level, and not a claim about any individual reader.

It is deliberately **not** used for length. Length is words. Difficulty changes
time per word, never word count (audit defect X2).

---

## 2. Pipeline

```
EPUB ──► spine text ──► 12 stratified windows ──► 18 stored features
     ──► 6 dimension demands (15 features in use) ──► percentiles vs frozen reference
     ──► weighted sum ──► D with a two-source interval
```

| Stage | Module | Output |
|---|---|---|
| Extract | `cde_extract.py` | ordered documents, excluded documents with reasons |
| Segment | `cde_text.py` | canonical sentences, paragraphs, prose test |
| Sample | `cde_extract.select_windows` | 12 windows, fixed positions |
| Feature | `cde_features.py` | 18 raw statistics per window |
| Score | `cde_model.py` | dimension percentiles, `D`, interval, band |

Features are stored per window and are immutable inputs. A new configuration is
fitted and scored from `cde-v0-features-*.json` alone, without re-reading the
EPUBs (`cde_run.py refit`). That is what makes version bumps cheap and
reproducible.

---

## 3. The equations

For book *b*, window *w*, dimension *d*, feature *f*:

```
s(w,d)  =  Σ_f  β(d,f) · x(w,f)  /  Σ_f β(d,f)

peak_d  = Q85_w s(w,d)

R(b,d)  =  (1 − λ_d) · mean_w s(w,d)  +  λ_d · peak_d

A(b,d)  =  P(d, R(b,d))                    percentile against frozen reference

D(b)    =  Σ_d  w_d · A(b,d)  +  Σ_(i,j)∈I  v_ij · A(b,i) · A(b,j)
```

with `β(d,f) = 1/|features(d)|` (equal inside every dimension), `λ_d = 0.35`,
`Σ w_d = 1`, and `I = ∅` (no interaction terms) in v0.3.

`Q85` is the 85th percentile over windows. It separates a book that is uniformly
moderate from one that is easy except for four brutal chapters, at `λ = 0.35`.
It was chosen over Q90 and CVaR90 because at the same `λ` it produced the lowest
split-half disagreement: **0.0550** against 0.0617 and 0.0633 (§11.2). The margin
is small and is not claimed to be statistically significant; the 85th percentile
is also the least tail-dependent of the three.

**Interaction terms are empty on purpose.** A non-zero `v` needs an ablation on
human grades. There are none, so `v = 0`. The schema and the arithmetic support
them; the evidence does not.

---

## 4. Dimensions

Dimension weights are equal (`1/6`) because no evidence ranks them against each
other. Feature weights inside a dimension are equal for the same reason: after
deduplication there is no basis for a 0.55/0.25/0.20 split, and v0.2's splits
implied a precision nothing supported.

| d | Name | Features (equal β) | λ | w |
|---|---|---|---|---|
| **A** | Lexical load | `A_oov · A_abstract` | 0.35 | 1/6 |
| **B** | Syntactic load | `B_clause · B_pronoun · B_passive` | 0.35 | 1/6 |
| **G** | Entity interaction | `G_names · G_cooc` | 0.35 | 1/6 |
| **H** | Continuity and direction | `H_discontinuity · H_shift · H_orphan` | 0.35 | 1/6 |
| **I** | Information density | `I_content · I_novelty` | 0.35 | 1/6 |
| **K** | Dialogue load | `K_tagless · K_speakers · K_quote` | 0.35 | 1/6 |

**Three features are stored but no longer scored**, because each duplicated
another feature in its own dimension (|r| ≥ 0.90 across 135 books):
`A_morph` (+0.954 with `A_abstract`), `B_sentence` (+0.951 with `B_clause`),
`I_np` (+0.905 with `I_content`). Removing them changed reliability by 0.0000
and stops a dimension from being one indicator wearing three names. They remain
in the feature file so a future version can revisit the choice.

### Operational definitions (complete enough to reimplement)

All counts are over one window of ≈9,600 characters (≈1,700 words).

| Feature | Definition |
|---|---|
| `A_oov` | Share of **non-proper-noun** content tokens whose lowercase form, or a stripped variant (`-s`, `-es`, `-ed`, `-ing`, `-ly`, `-er`, `-est`, `'s`), is absent from the top 20,000 word forms of the reference corpus. |
| `A_abstract` | Share of content tokens ending in an abstract-noun suffix (`-tion`, `-sion`, `-ment`, `-ness`, `-ity`, `-ism`, `-ance`, `-ence`, `-ship`, `-hood`, `-acy`, `-ology`). |
| `B_clause` | (Subordinators + coordinators) ÷ sentences. |
| `B_pronoun` | Pronoun tokens ÷ tokens. |
| `B_passive` | (BE-form followed within 3 tokens by a >4-character word ending `-ed`/`-en`) ÷ sentences. |
| `G_names` | Distinct capitalised non-function-word tokens per 100 tokens. |
| `G_cooc` | Mean per-sentence count of distinct name pairs, `k(k−1)/2`. |
| `H_discontinuity` | `1 −` mean Jaccard overlap of content lemmas between adjacent paragraphs. |
| `H_shift` | Scene-shift markers (`meanwhile`, `later`, `earlier`, `elsewhere`, `afterwards`, `eventually`, `simultaneously`, `somewhere`) per 100 tokens. |
| `H_orphan` | Share of sentences containing a pronoun with no name in that sentence or the two before it. |
| `I_content` | Content tokens ÷ tokens. |
| `I_novelty` | Share of content lemmas not seen earlier in the window. |
| `K_quote` | Quoted characters ÷ characters. |
| `K_tagless` | Share of quoted sentences with no attribution verb. |
| `K_speakers` | Distinct non-function words within ±6 tokens of an attribution verb. |

**Orientation rule.** Every feature is defined so that **higher = more
demanding**. `H_discontinuity` is inverted for this reason: low paragraph
overlap means the reader rebuilds context, which is harder.

**A consequence of deduplication worth stating:** `B` no longer contains a raw
sentence-length term. On this corpus clause density carried it (r = 0.951), but
a book whose difficulty comes purely from long sentences with few conjunctions
would now be under-measured.

---

## 5. Sampling

12 windows at fixed fractions `0.02 + 0.95·(i+0.5)/12` of the character stream,
≈9,600 characters each (the `tokens_per_window * 8` chunk in
`cde_extract.py`; a window that reaches the end of a spine document continues
into the next, so lengths are approximate). In practice this yields
19,692–31,749 tokens per book.

Excluded before sampling, and reported: navigation and contents documents,
images, empty documents, documents whose first 3,000 characters exceed 25%
numeric tokens, list-like documents with a mean line under 3 tokens.

Deterministic by construction: no RNG, no clock, no hash seed.

**Coverage is uneven and is reported per book.** As a share of the book, the
sample is a median **23.2%** of words, p10 **6.6%**, p90 **63.0%**. 25 of 135
books are more than half sampled; the extremes are 0.5% (a 4.9M-word omnibus,
26,768 tokens) and 82.2%. Every score now carries `sampled_share` and a
`low_coverage` flag for books below 3%: **six** of the 135 are flagged, all of
them long light-novel compilations or omnibuses. Their scores rest on under 3%
of the text and should be read as the least stable in the corpus — two of the six
were in v0.2's top five.

**Overlap precondition.** Windows start `0.95 · total / 12` characters apart —
about 50,000 characters at median book size — so for a book below roughly 22,000
words the windows would overlap. The shortest book in the reference corpus is
32,480 words, so no committed score is affected, but a short imported book would
need a guard.

---

## 6. Normalisation and the reference

Percentile against a frozen grid of 101 quantiles per dimension, built from the
book-level `R(b,d)` of the 135 reference books.

```
A(b,d) = (# grid values ≤ R(b,d)) / 100
```

Three intended consequences:

1. **Scores never move when a new book is added.** The grid is a file, not a
   computation at import time.
2. **Dimensions are comparable.** Each is uniform on the reference corpus, so
   equal weights are meaningful. A z-score would preserve each dimension's tail
   and let the widest-spread dimension dominate a fixed-weight sum.
3. **The index is corpus-relative.** A book unlike the reference saturates at 0
   or 1.

---

## 7. Uncertainty and refusal

**Two-source sampling interval.** 200 draws, seeded (`20261029`), 2.5th–97.5th
percentile. Each draw resamples **both** the twelve windows *and* the 135
reference books (rebuilding the percentile grids), then rescores the book.

| Component | Median width |
|---|---:|
| window resampling only | 0.150 |
| reference resampling only | 0.055 |
| both (reported) | 0.158 |

The two sources combine roughly in quadrature, which is what independent
resampling should do. The reported interval is therefore the window-only interval
plus the reference-composition uncertainty it was missing.

It is still **not** a confidence interval for reading difficulty. It covers
sampling and reference composition. It does not cover feature measurement error,
model form, or disagreement between readers. It is called a *sampling stability
interval* everywhere in the output.

**Refusal.** The engine returns `INSUFFICIENT_EVIDENCE` instead of a number when:

- fewer than 3 usable windows survive filtering, or
- fewer than 5,000 tokens are sampled, or
- the caller's prose-share check falls below 0.60.

No corpus book triggered a refusal (135/135 scored), so the refusal path is
exercised by unit tests rather than by real inputs. `low_coverage` is a flag, not
a refusal: it marks books sampled below 3% without suppressing their score.

---

## 8. Output contract

Per book (abridged; real record from the v0.3 artefact):

```json
{
  "status": "ok",
  "title": "The Goldfinch",
  "file": "The Goldfinch.epub",
  "words": 294094,
  "tokens_sampled": 20729,
  "sampled_share": 0.0705,
  "low_coverage": false,
  "score": 0.7767,
  "interval": [0.6831, 0.8367],
  "interval_window_only": [0.6799, 0.8383],
  "band_provisional": "Very heavy",
  "dimensions": {
    "A": {"label": "Lexical load", "score": 0.97, "weight": 0.1667,
          "contribution": 0.1617, "raw": 0.05169, "window_spread": 0.00898},
    "...": "..."
  },
  "explanation": ["Information density (percentile 1.0 × weight 0.167)", "..."]
}
```

Every dimension carries its raw value, percentile, weight and contribution, so
any total can be re-added by hand and any dimension challenged on its own.

### Bands

Five provisional bands, cut at the **quintiles of the reference corpus**:

| Band | Upper bound |
|---|---:|
| Light | 0.3833 |
| Moderate | 0.4653 |
| Demanding | 0.5340 |
| Heavy | 0.6183 |
| Very heavy | 1.0100 |

Corpus-relative quantiles, **not** validated reading-experience categories. They
carry `"provisional": true` in config and must be replaced by calibrated cut
points before any UI shows them.

---

## 9. Configuration

The configuration is one declarative block, `DEFAULT_CONFIG` at the top of
`tools/cde/cde_model.py`; the previous version is frozen as
`tools/cde/config/cde-v0.2.json`. Scoring code never contains a coefficient
literal. Serialised shape (one dimension shown):

```json
{
  "version": "cde-v0.3",
  "reference_version": "ref-v3",
  "peak_kind": "peak85",
  "dimensions": {
    "A": {"weight": 0.166666666666667, "lambda": 0.35, "label": "Lexical load",
          "features": {"A_oov": 0.5, "A_abstract": 0.5}}
  },
  "interactions": [],
  "refusal": {"min_tokens": 5000, "min_windows": 3, "min_prose_share": 0.60},
  "labels": {"provisional": true, "bands": []}
}
```

Rules enforced by construction:

- Weights are data, never literals in scoring code.
- Every result records `config_version` and `reference_version`.
- Reference grids are files; changing them is a new `reference_version`.
- No per-title special cases exist anywhere in the pipeline, and none may be
  added.

---

## 10. Worked example

**The Goldfinch**, 12/12 windows, 20,729 tokens, 7.05% of the book:

| d | raw `R` | percentile | weight | contribution |
|---|---:|---:|---:|---:|
| A | 0.05169 | 0.97 | 0.1667 | 0.1617 |
| B | 0.73124 | 0.83 | 0.1667 | 0.1383 |
| G | 3.01633 | 0.87 | 0.1667 | 0.1450 |
| H | 0.43548 | 0.54 | 0.1667 | 0.0900 |
| I | 0.61537 | 1.00 | 0.1667 | 0.1667 |
| K | 25.85355 | 0.45 | 0.1667 | 0.0750 |
| **D** | | | | **0.7767** |

Interval `[0.6831, 0.8367]`; independent addition of the contributions gives
0.7767 exactly.

**The House on the Cliff**, same pipeline, 66.2% of the book sampled:

| d | percentile | contribution |
|---|---:|---:|
| A | 0.05 | 0.0083 |
| B | 0.55 | 0.0917 |
| G | 0.10 | 0.0167 |
| H | 0.43 | 0.0717 |
| I | 0.02 | 0.0033 |
| K | 0.81 | 0.1350 |
| **D** | | **0.3267** |

---

## 11. Measured behaviour

Every number is printed by `cde_eval.py`, `cde_critique.py` or
`cde_recalibrate.py` against the committed artefacts. None of it is accuracy.

### 11.1 Determinism
**135/135** books reproduce their score bit-for-bit on a second run.

### 11.2 Reliability (split-half)
Each book's 12 windows split odd/even into two half-scores:

| Statistic | v0.2 | v0.3 |
|---|---:|---:|
| median abs difference | 0.0567 | **0.0550** |
| p90 | 0.1433 | 0.1360 |

Peak operator at λ = 0.35: `peak85` 0.0550, `peak90` 0.0617, `CVaR90` 0.0633.
Plain mean 0.0533 — the best reliability, and the reason λ is not chosen by
reliability: that criterion would delete the peak term entirely.

### 11.3 Sampling stability
Three disjoint 4-window subsets: median within-book SD **0.045**, p90 0.082, max
0.135 (v0.2: 0.046 / 0.085 / 0.156).

### 11.4 Ablation (remove one dimension)

| Removed | mean abs ΔD | max abs ΔD | Spearman vs full |
|---|---:|---:|---:|
| A | 0.0360 | 0.1030 | 0.925 |
| B | 0.0413 | 0.1033 | 0.910 |
| G | 0.0437 | 0.1177 | 0.917 |
| H | 0.0485 | 0.1407 | 0.915 |
| I | 0.0435 | 0.1260 | 0.922 |
| K | 0.0531 | 0.1383 | 0.921 |

No dimension dominates. Each removal costs 3.6–5.3 index points. v0.2's minimum
Spearman was 0.885; v0.3's is 0.910.

### 11.5 Weight sensitivity
±50% on any single weight: minimum rank correlation **0.977**, median 0.982
(v0.2: 0.974 / 0.978).

### 11.6 Independence from the shipped formula
`Spearman(D, shipped multiplier)` = **+0.626** (v0.2: +0.643). The shipped
multiplier is r = +0.975 with Flesch–Kincaid, so this rules out "same formula"
and nothing more.

### 11.7 Within-series consistency

| Cluster | n | SD | range |
|---|---:|---:|---:|
| Narnia | 6 | 0.038 | 0.123 |
| Spy Classroom | 15 | 0.067 | 0.315 |
| Naruto novels | 9 | 0.057 | 0.175 |
| **Whole corpus** | 135 | **0.118** | 0.560 |

### 11.8 Interval width
Window-only: median 0.150, p90 0.231, max 0.338. With reference composition
included: median 0.158. A single book's rank should not be trusted to better than
roughly ±0.08.

### 11.9 Does the interval cover window sampling?
Median half-to-half gap **0.0550** against a median reported width **0.1584** —
ratio **0.34**; halves land further apart than the interval for **1.5%** of books
(2 of 135). Conservative for sampling, silent on the three sources in §7.

### 11.10 Aggregation and λ, after recalibration
Each scheme rebuilt end to end (new grids, then new scores):

| Scheme | Spearman | max abs ΔD | top-10 overlap |
|---|---:|---:|---:|
| mean only (λ = 0) | 0.989 | 0.048 | 9/10 |
| **Q85 / 65-35 (shipped)** | 1.000 | 0.000 | 10/10 |
| Q85 / 70-30 | 0.999 | 0.010 | 9/10 |
| Q90 / 65-35 | 0.994 | 0.050 | 8/10 |
| CVaR90 | 0.915 | 0.222 | 4/10 |
| max (λ = 1) | 0.858 | 0.255 | 5/10 |

λ sweep at Q90: 0.964–0.996. The peak term changes fewer than two places in the
top ten at any λ, which is the honest reading: it is a design requirement, not a
measured improvement.

---

## 12. What this formula does not do

1. **It is not validated.** No human graded these 135 books in a way that
   survives audit. There is no accuracy figure, no correlation with human
   judgement, and no calibration of the bands.
2. **Six dimensions, not twelve.** Semantic complexity, information withholding,
   prior knowledge, structural memory, register and reader familiarity are
   absent. This is closer to a measure of surface linguistic and discourse
   complexity than of reading difficulty.
3. **Lexical rarity is corpus frequency, not a published norm.** A book about
   beekeeping will look lexically hard because this corpus contains no
   beekeeping.
4. **Names are heuristic.** Capitalisation plus a function-word blocklist. It
   will miss lowercased names, mis-read sentence-initial common nouns, and
   under-count in dialogue without tags.
5. **No syntax, really.** `B` is clause density, pronoun rate and a passive
   guess. It is not a parse tree, and it no longer has a raw sentence-length
   term at all. `H_orphan` is proximity, not coreference.
6. **The index is corpus-relative.** A book unlike the reference saturates at 0
   or 1.
7. **No reader.** Intrinsic text demand only.
8. **Refusal is untested on real bad input.** The refusal path is covered only by
   unit tests.
9. **Dimensions are not perfectly independent.** After deduplication the
   strongest between-dimension correlation is **A/I at +0.43** (v0.2: +0.20),
   because both now lean on content-word measures. I/K is −0.45. Equal weighting
   therefore still double-counts some shared variance.
10. **Percentiles preserve order, not distance.** Equal weights assume equal
    spacing across dimensions that this model cannot check.
11. **Two uncertainty sources are modelled, three are not.** Feature measurement
    error, model form and reader disagreement are outside the interval.

---

## 13. Reproduction

```bash
# machinery tests
python3 -m unittest discover -s tools/cde -p 'test_*.py'        # 9 tests, 0.024 s

# rebuild grids + scores from stored features (no EPUB corpus needed)
python3 tools/cde/cde_run.py refit \
  --features docs/audits/evidence/cde-v0-features-2026-10-29.json \
  --reference-out tools/cde/config/reference-v3.json \
  --scores-out docs/audits/evidence/cde-v0.3-scores-2026-10-29.json \
  --draws 200                                                   # 12.3 s

# measured behaviour
python3 tools/cde/cde_eval.py \
  --features docs/audits/evidence/cde-v0-features-2026-10-29.json \
  --reference tools/cde/config/reference-v3.json \
  --engine docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json  # 51 s

# adversarial checks
python3 tools/cde/cde_critique.py \
  --features docs/audits/evidence/cde-v0-features-2026-10-29.json \
  --reference tools/cde/config/reference-v3.json \
  --scores docs/audits/evidence/cde-v0.3-scores-2026-10-29.json \
  --out /tmp/critique.json                                      # 0.13 s

# why the operator and weights are what they are
python3 tools/cde/cde_recalibrate.py \
  --features docs/audits/evidence/cde-v0-features-2026-10-29.json  # 0.18 s
```

**Not reproducible from a clean checkout:** `frequency` and `calibrate`. They
need the EPUB corpus, which is not in this repository, and they would rewrite the
frozen lexicon. `refit` is the reproducible path for everything after feature
extraction.

The eval prints to stdout rather than to a file. The numbers in §11 are that
stdout, and the command above regenerates them exactly.

---

## 14. Versioning rule

Changing a `β`, a weight, a `λ`, the peak operator, a feature definition, the
window count, the lexicon or a reference grid **is a new version**, and requires:

1. a new `config_version` or `reference_version`,
2. the full evaluation battery re-run,
3. a row in the experiment log with the deltas.

The previous configuration is frozen as a JSON file before the constant changes,
so any released score can be reproduced exactly.

---

## 15. Adversarial review, answered with measurements

An external reviewer graded the *description* of v0.2 and raised objections that
could only be settled against code and data. `REVIEW-RESPONSE.md` is the
point-by-point reply; the numbers below are the v0.3 equivalents.

**What the review got wrong about the implementation** — both caused by loose
wording in my summary, both corrected there:

| Objection | Actual code |
|---|---|
| "35% of the maximum chunk" | the peak operator; never the maximum |
| "samples from 20% to 97%" | 5.96% to 93.04% |

**Where the review was right, and what changed because of it:**

1. *Construct redundancy.* Three feature pairs exceeded r = 0.90. v0.3 removes
   one half of each pair; reliability was unchanged (0.0550 both ways).
2. *The peak weight was arbitrary.* v0.3 chooses the operator by split-half
   reliability and documents that the choice is a small, non-significant margin.
3. *The interval overclaimed.* It is a sampling stability interval, now covering
   reference composition as well as window sampling (§7).
4. *Percentiles preserve order, not distance.* Stated as a limitation (§12.10);
   there is no fix inside this design.
5. *Validation was underspecified.* `PHASE-3-VALIDATION.md` §5.1 fixes a mixed
   model, variance decomposition, an ICC floor and a cluster bootstrap before any
   data exists.

**Where the review is right and no fix is available here:** no human ratings
exist, so construct validity, predictive validity and generalisation remain
unmeasured.

---

## 16. What changed in v0.3, and what each change bought

| Change | Why | Measured effect |
|---|---|---|
| Within-dimension β made equal (was 0.55/0.25/0.20 and similar) | The old splits implied precision no evidence supported | Reliability 0.0567 → 0.0550 |
| `A_morph`, `B_sentence`, `I_np` retired | Each duplicated another feature in its dimension at r ≥ 0.90 | Reliability unchanged; fewer near-duplicate indicators |
| Peak operator Q90 → Q85 | Lowest split-half disagreement of the three candidates at λ = 0.35 | 0.0617 → 0.0550 for that operator alone |
| Interval now resamples the reference corpus too | The old interval was silent on reference composition | Median width 0.150 → 0.158; reference-only component 0.055 |
| `sampled_share` and `low_coverage` in every record | Sampling coverage ranges 0.5%–82.2% and was invisible | No score change; six long compilations flagged below 3% |

**What the recalibration cost:** ranking correlation with v0.2 is **0.929**,
mean |ΔD| **0.031**, max **0.182**, and the top ten keeps **8 of 10**. There is no
human target that can say which version is closer to a reader. The claim made
here is narrower: v0.3 is more internally reliable, its dimensions each matter
slightly more (ablation ρ 0.910 minimum against 0.885), its interval covers one
more source, and its weights no longer pretend to a precision that was never
measured.

Largest movers, for inspection rather than celebration:

| Book | v0.2 | v0.3 | Cause |
|---|---:|---:|---|
| *No Longer Human* | 0.473 | 0.577 | abstract vocabulary now 1/2 of A instead of 1/5 |
| *A Study in Scarlet* | 0.585 | 0.675 | clause density now 1/3 of B instead of 3/10, sentence length retired |
| *Man's Search for Meaning* | 0.538 | 0.628 | same two shifts |
| *REVEREND INSANITY 1* | 0.612 | 0.430 | 0.5% coverage; its score is the least stable in the corpus |
| *The Rage of Dragons* | 0.312 | 0.287 | plain-clause prose, now unopposed by a sentence-length term |
