# Cognitive Difficulty Engine (CDE) — Phase 1 audit and proposed architecture

- **Opened:** 2026-10-29
- **Status:** Phase 1 complete. **No production code was changed.** The existing
  engine is preserved untouched as the baseline.
- **Scope:** audit the shipped difficulty and time pipeline, measure its defects
  against the real corpus, and propose the replacement architecture. This is the
  document the owner reviews before Phase 2 begins.
- **Predecessor:** the hand-graded real-library results were declared **void** on
  2026-10-29 (`docs/audits/new-era-testing.md` §31). Nothing from those verdicts
  is used here as evidence, in either direction.

## 0. What this document is, and what it is not

It **is** a measurement-based audit. Every number below came from a command run
today against the 149-package corpus, or from reading a named line of source.

It **is not** a literature review, a feature catalogue pretending to be a model,
or a claim that the proposed architecture works. Phase 2 is where the research
and the specification belong. No citation is asserted anywhere in this document,
because none has been verified yet.

---

## 1. Corpus and method

| Item | Value | Source |
|---|---|---|
| EPUB packages | **149** | `scripts/real-book-inventory.py` |
| Distinct works (byte-identical duplicates removed) | **135** | §11.2 of the void file, SHA-256 |
| Packages containing page-break markers | **21** | `scripts/real-book-pagination.py`, exit 0 |
| Packages declaring a page count in the OPF | **0** | same, exit 0 |
| Recorded engine output | 149 rows | `docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json` (328 KB, SHA-256 `415e85c0b1420a0c7c88b2924fd31d8055aa1d02cd51de2d91c539e60e397bbe`), produced by the driver built from app source |

Two new read-only scripts were added for this audit and are committed with it:

- `scripts/real-book-pagination.py` — counts page markers and declared page
  counts. Assigns no verdict.
- `scripts/cde-phase1-audit.py` — reproduces the closed-form check, the
  multiplier distribution, the extraction comparison and the sample-coverage
  measurement. Assigns no verdict.

A word counter compiled from the app's own `SharedTextUtilities.swift` was used
to test whether the shipped extraction agrees with an independent one. It is a
build artifact under `/tmp`, not repository source.

---

## 2. The shipped pipeline, end to end

Read in this order; each step is a real code path, not a summary:

1. **Import** (`BookImporter.swift:292`) calls `extractSampleText(…, maxChars: 5000)`.
2. **Sample extraction** (`BookImporter.swift:518`) concatenates the *first*
   spine documents, strips HTML, and truncates at exactly 5,000 characters.
3. **Difficulty** (`BookImporter.swift:293`) runs `DifficultyAnalyzer.analyze`
   over that one string and stores a `ReadingDifficultyProfile`.
4. **Page count** (`BookImporter.swift:297`) computes
   `ceil(words × difficultyMultiplier / 250)`.
5. **Time** (`AnalyticsEngine.swift:121`) multiplies remaining pages by a
   seconds-per-page figure; the default constant is 120 s
   (`AnalyticsEngine.swift:425`).
6. **Word count** (`BookImporter.swift:506`) sums `wordCount(html:fromHTML:)`
   over every spine document. This is the only whole-book measurement in the
   system.

The whole difficulty model is therefore: **one 5,000-character window from the
front of the book determines a multiplier, which is applied to the word count to
produce a page count, which is multiplied by a fixed pace to produce time.**

---

## 3. The model as implemented

`ContentAnalysis.swift:12` — four statistics are computed from the sample:

```
words        = sample.split(whitespace)
sentences    = sample.split(on any of ".", "!", "?")        // line 17
avgWordLen   = Σ len(word) / |words|
avgSentLen   = |words| / |sentences|
rareRatio    = count(len(word) > 8) / |words|               // line 27
syllables    = vowel-group count per word
gradeLevel   = 0.39·avgSentLen + 11.8·avgSyllables − 15.59  // Flesch–Kincaid
```

`Book2.swift:543` — the multiplier normalizes each statistic against a declared
baseline and clamps twice:

```
gradeNorm    = min(gradeLevel / 8.0,  2.0)
wordNorm     = min(avgWordLen / 4.5,  2.0)
sentenceNorm = min(avgSentLen / 14.0, 2.0)
rareNorm     = min(rareRatio / 0.05,  2.0)

raw = 0.40·gradeNorm + 0.20·wordNorm + 0.20·sentenceNorm + 0.20·rareNorm
m   = clamp(raw, 0.5, 2.0)
```

`Book2.swift:560` — the label is a fixed band on `m`:

| Band | Label |
|---|---|
| `< 0.7` | Easy |
| `< 1.0` | Light |
| `< 1.3` | Moderate |
| `< 1.6` | Challenging |
| `≥ 1.6` | Dense |

That is the entire difficulty system: one readability formula, two length
statistics, one long-word ratio, four fixed weights, two clamps, five fixed
cut points.

---

## 4. What it actually measures

Measured over all 135 distinct works:

| Question | Measurement |
|---|---|
| How much of the multiplier's variance is explained by Flesch–Kincaid grade alone? | **r = +0.975** |
| How much is explained by book length? | r = +0.238 against log₁₀(words) |
| Multiplier range | **0.653 – 1.774** (2.72×) |
| Median multiplier | 1.080 |
| Books with `m` in [0.80, 1.30] | **76.3%** |
| Books saturating the 0.5 or 2.0 clamp | **0** |
| Label distribution | Easy 1 · Light 46 · Moderate 71 · Challenging 15 · Dense 2 |

So the four-feature weighted sum is, to a first approximation, a
Flesch–Kincaid grade with three decoration terms. **87% of books land in two
adjacent labels.** Five labels are declared; two are effectively used.

---

## 5. Defects, with receipts

### X1 — The system measures lexical grade, and calls it reading difficulty

The output claims to describe cognitive effort. Every input is a surface
statistic of one prose window. Nothing measures concepts, relationships,
inference, memory, discourse, or prior knowledge. This is not a weighting
problem; it is a different quantity.

### X2 — Difficulty is applied to *length* (category error)

`ContentAnalysis.swift:81` multiplies the word count by the difficulty
multiplier before dividing by a fixed 250 words per page. Difficulty is thereby
converted into pages. A hard book is not longer than an easy one; it takes
longer. This single line is why page counts inflate for dense prose and why the
engine's page numbers are not a measurable property of anything.

### X3 — Two estimate paths exist and they disagree by a factor of `m`

**Historical finding:** the following describes the estimator at this audit.
The main `EstimationEngine` now uses the measured page pace directly; the
legacy `AnalyticsEngine` path still applies its difficulty profile. The
historical factor below has not been re-measured after that change.

- `EstimationEngine.swift:262` — `effective = hasPersonalSpeed ? base : cross`.
  For a new book with no timings, the pace is the reader's cross-book average,
  which does **not** include this book's multiplier. Difficulty enters once.
- `AnalyticsEngine.swift:58` / `:121` — `effectiveReadingSpeed` returns
  `adjustedReadingSpeed` (which is `base × m`, `AnalyticsEngine.swift:48`)
  scaled by `m` again through the page count. Difficulty enters twice.

For the same book the two paths differ by exactly the multiplier: up to
**1.77×** on this corpus. The recorded 135-book numbers came from the first
path; the second is reachable from other screens. This is a correctness defect
independent of every modelling question below.

### X4 — A whole novel is characterised by 0.75% of its text, taken from the front

`BookImporter.swift:292` passes `maxChars: 5000`. Measured across 135 books, that
window is:

| Statistic | Value |
|---|---|
| Median share of the book | **0.75%** |
| Minimum | 0.02% |
| Maximum | 2.83% |

The window is the *first* spine documents, so for a novel it is front matter and
chapter one — dialogue-heavy, short-sentence, unrepresentative prose. The one
empirical test of this in the project's history was the re-read of 20 books from
mid-book, where 7 of 20 verdicts changed; that result is void as a grade, but it
is still evidence that the first pages are not the book.

### X5 — The shipped sentence splitter counts 1.34× too many sentences

`ContentAnalysis.swift:17` splits on every `.`, `!` and `?` character, so
decimals, ellipses, `Mr.`, `Dr.`, and every quoted sentence boundary create a
new "sentence". The project already owns a better splitter —
`SharedTextUtilities.swift:186`, which requires a following capital letter — and
the difficulty analyzer does not use it.

Measured on the same 5,000-character window for all 135 books, comparing the
shipped split with that canonical splitter:

| Statistic | Value |
|---|---|
| Shipped sentence count ÷ canonical count | **1.34×** (median) |
| Canonical average sentence length ÷ shipped | 1.34× |
| Grade-level change if the canonical splitter were used | **+2.26 grades** (median) |
| Books where the canonical splitter lengthens average sentences | **130 / 135** |

The shipped analyzer systematically *understates* grade level by roughly two
grades, on 96% of the corpus. That is a large, uniform bias — and it is hidden
because the normalization baseline was tuned around it.

### X6 — "Rare lexicon" is word length, which the directive forbids

`ContentAnalysis.swift:27` defines the rare-word ratio as the share of tokens
longer than 8 characters. `something`, `different`, `everything`, `important`
and `understand` all count as "rare". This is the exact substitution the
directive prohibits: length standing in for difficulty. It carries 20% of the
multiplier.

### X7 — Word length includes punctuation

`words` are whitespace-delimited, and `.count` counts characters, so `word,` and
`"word."` are longer than `word`. The bias is small but uniform, and it interacts
with X5 (a splitter that leaves punctuation attached).

### X8 — Two hard clamps, no uncertainty

Every normalization term saturates at 2.0, and the result is clamped to
[0.5, 2.0]. Above a grade of about 16 the model cannot distinguish a difficult
book from an impossible one. No interval, no per-dimension spread, no
"insufficient evidence" state. The number is presented as exact.

### X9 — "Confidence" is book length

`ContentAnalysis.swift:84` returns `min(1, words / 20_000)`. A book of 20,000+
words is reported as maximally confident regardless of whether it is poetry,
a table of contents, or prose in an unmodelled register. Confidence here measures
how much text existed, not how much is known.

### X10 — The label cut points are unvalidated and the resolution is poor

The bands 0.7 / 1.0 / 1.3 / 1.6 are constants in source with no calibration
record. Measured consequences:

- 87% of the corpus sits in Light or Moderate.
- Within one series by one author, `m` moves almost as much as across the whole
  library:

| Cluster | Books | Multiplier range | Spread | Labels |
|---|---:|---|---:|---|
| Chronicles of Narnia | 7 | 0.714 – 1.173 | **1.64×** | 4 Light, 3 Moderate |
| Spy Classroom | 15 | 0.946 – 1.266 | **1.34×** | 14 Moderate, 1 Light |
| Naruto novels | 9 | 0.857 – 1.132 | **1.32×** | 8 Moderate, 1 Light |
| Whole corpus | 135 | 0.653 – 1.774 | 2.72× | 5 labels used |

Same author, same series, same target reader, and the model reports a
Light-to-Moderate difference. On Narnia in particular, no child who read all
seven would report a difficulty difference at all. **Most of the model's
variation is within-author noise, not between-book signal.**

### X11 — No dimension is inspectable, so nothing can be debugged

The output is one number and one label. No component scores, no explanation, no
provenance for *why* a book scored as it did. The only diagnostic available is
the raw profile struct.

### X12 — Extraction is sound for word counting, and unmeasured for everything else

Positive result, measured: the app's Swift `wordCount` and an independent Python
count over the same spine agree on **all 135 books with 0.0000 median relative
deviation** and no book off by more than 5%. Word counting is trustworthy.

Unmeasured: reading order, duplicate text, nav/TOC contamination, entity and
hyphenation handling, chapter boundaries. `estimateTotalWords` sums every spine
document, including navigation documents, and nothing reports how much of a
"book" was navigation.

### X13 — The audited time estimate contains no reader and no content

Measured: for all 135 books, estimated hours is a product of two numbers and a
constant. Re-deriving it reproduces the recorded value on **133 of 135 books
within 0.5%** (maximum error 0.73%, which is the recorded values' two-decimal
rounding), so the structure is exact and only the printed value is rounded.

| Predictor | R² against estimated hours |
|---|---:|
| words | 0.9823 |
| **words × multiplier** | **1.0000** |
| words × multiplier² | 0.9885 |

Fitted slope: `8.888×10⁻⁵` hours per (word × multiplier), which is exactly
`(2/3) × (1/250) × (120/3600)` — two-thirds of the book remaining, 250 words per
page, 120 seconds per page.

**The complete shipped model of reading time is `T = 0.0000889 × words × m`.** Not
one page of actual text influenced it beyond a word count and four statistics
from 0.75% of the book.

---

## 6. What the existing system gets right

Fair assessment, because a replacement that loses these is worse:

- **Determinism.** The same book always produces the same number. No model drift,
  no sampling noise, no hidden state.
- **Provenance for speed.** `EstimationStatus` distinguishes personalized,
  cross-book and global-default pace, and the UI must disclose which
  (`EstimationEngine.swift`, E6). This is better discipline than most of the
  replacement proposal needs.
- **Idle-page rejection.** `PageDurationPolicy` filters implausible page timings
  from a reader's own distribution before averaging.
- **One content unit.** `PageEstimationModel` is a single conversion both import
  paths use, replacing two that had drifted.
- **Honest word counting.** Verified above at zero disagreement across 135 books.
- **Calibration pins.** Tests fix the baseline at 1.0 and bound the multiplier, so
  the old behaviour cannot silently return.

These stay in the replacement: determinism, provenance, outlier rejection, a
single content unit, and pinned calibration behaviour.

---

## 7. Requirements derived from the defects

Each requirement is traceable to a defect. A feature that serves none of these is
not added.

| ID | Requirement | From |
|---|---|---|
| R1 | Difficulty and length are separate quantities. Length never depends on difficulty. | X2 |
| R2 | Exactly one path computes an estimate; both readers and screens call it. | X3 |
| R3 | Every book-level score is computed from a stratified sample of the whole book, with the sampling recorded. | X4 |
| R4 | Sentence segmentation is the canonical implementation, and its accuracy is tested. | X5 |
| R5 | No feature may be a proxy for the thing it claims to measure (length ≠ rarity). | X6, X7 |
| R6 | Scores carry uncertainty and a refusal state. | X8 |
| R7 | Confidence describes knowledge, not volume. | X9 |
| R8 | Label cut points are calibrated against human grades and report their confusion matrix. | X10 |
| R9 | Every component score is inspectable and explainable. | X11 |
| R10 | Extraction reports what it skipped and why. | X12 |
| R11 | Reading time uses an observed pace, and states the assumption when it has none. | X13 |
| R12 | Weights are external, versioned, and recorded with every result. | §8.8 |
| R13 | Two independent blind graders, with an agreement statistic. | §9 |
| R14 | Out-of-sample evaluation split by author and series. | §9 |
| R15 | A component that fails ablation is removed or demoted to explanatory only. | §9 |

---

## 8. Proposed architecture

### 8.1 Target quantity

Reading difficulty is the cognitive effort required by a **specified reader** to
accurately process, connect, retain and understand a passage at a natural,
sustained pace.

Three consequences, adopted as design rules:

1. **Difficulty is not a property of a book alone.** It is a book × reader
   interaction. The engine must therefore produce two separate things: an
   intrinsic text measurement (what the text demands) and a reader-relative
   estimate (what this reader will experience). The first ships in v1; the
   second is a hook (R-Reader).
2. **Difficulty is not length.** It changes *time per word*, never word count.
3. **Difficulty is not quality or intelligence.** The label describes effort.

### 8.2 Dimensions

Each dimension is a separate module with its own measurement, normalization and
validation. The reliability column is the honest current status, not a wish:
**A** = deterministic and defensible today; **B** = computable, needs validation
before it may carry weight; **C** = proxy only, explanatory at most.

| ID | Dimension | Operational measurement | Reliability |
|---|---|---|---|
| A | Lexical difficulty | Token rarity against a pinned frequency norm; abstractness; technical-term density; unexplained invented-term density; polysemy in context | B (needs a frequency resource) |
| B | Syntactic complexity | Dependency-depth distribution, clause count, embedding depth, subject–verb distance, passive rate, pronoun ambiguity | B (needs a parser) |
| C | Semantic complexity | Propositions per clause, abstraction, metaphor/idiom density, semantic ambiguity | C (proxy only) |
| D | Contextual dependency | Referential distance in tokens/paragraphs; share of referring expressions whose antecedent is out of window; reappearance lag | C |
| E | Information withholding and inference | Deliberate withholding vs ambiguity; unresolved-question density; unreliable-narration signals | C (explanatory only) |
| F | Prior knowledge | Domain-term density; concepts introduced and explained vs assumed; prerequisite chains | C |
| G | Entity interaction | Mentions, roles, interactions, active-thread count, relationship changes, graph components and turnover | B |
| H | Continuity and direction | Viewpoint/scene/topic shift rate between adjacent segments; transition explicitness | B |
| I | Information density | New entities and concepts per passage; propositions; lexical novelty rate; retention load | B |
| J | Structural memory | Recurrence of entities across chapters; unresolved-thread persistence; callback distance | C |
| K | Dialogue | Speaker count, attribution explicitness, tagless turns, nested quotation, subtext density | A/B |
| L | Register and translation | Collocation rarity, idiom density, translation-artifact markers, register consistency | B |

**Design constraint.** A dimension may not carry weight until it clears the
validation gate in §9. In v1 that means A, B, G, H, I, K are candidates; C, E, J
are explanatory output only; F and L are experiments.

### 8.3 Hierarchical analysis

Six levels, each with its own contract:

| Level | Unit | What is computed |
|---|---|---|
| 1 | Word | token class, lemma, rarity, morphology |
| 2 | Sentence | syntax depth, clause count, proposition proxy, referring expressions |
| 3 | Paragraph | density, topic shift, entity introduction |
| 4 | Passage (~1,000 tokens) | contextual dependency, active entities, continuity |
| 5 | Chapter | thread count, structural memory, sustained-complexity runs |
| 6 | Book | distribution, spread, and the aggregation in §8.4 |

**Aggregation is not a mean.** For each dimension:

```
A_d = (1 − λ_d) · mean_p(n_{p,d}) + λ_d · Q90_p(n_{p,d})
```

`λ_d` is configurable per dimension and represents how much a book's worst
sustained passages matter versus its average. `Q90` is the 90th percentile over
passages. This distinguishes "uniformly moderate" from "mostly easy with four
brutal chapters", which a mean cannot.

Three additional book-level statistics are reported per dimension: the standard
deviation across passages, the length of the longest run above the 75th
percentile, and the chapter-to-chapter delta series.

### 8.4 Mathematical specification (v0, to be fixed in Phase 2)

**Normalization.** Every raw statistic is mapped to [0,1] against a **pinned**
reference distribution stored in configuration, never recomputed per import:

```
n = clamp( (x − μ_ref) / (k · σ_ref) , 0, 1 )
```

Default `k = 3`, so three reference standard deviations spans the scale. Pinning
is deliberate: corpus-relative normalization that moves when a new book is added
makes a score unreproducible and would violate R12.

**Model.**

```
D_raw = Σ_d w_d · A_d + Σ_{(i,j) ∈ I} v_ij · A_i · A_j
```

with `Σ w_d = 1`, `w_d ≥ 0`, and `I` an explicitly declared, small interaction
set. Candidate interactions, each of which must earn its place by ablation:
A×F (hard vocabulary in an unglossed domain), B×I (dense syntax plus dense
content), D×J (long dependencies plus long memory), G×H (many entities plus
frequent shifts), A×B (rare words in complex sentences).

**Saturation.** Replace the hard clamp with a monotone squash so ranking is
preserved beyond the old ceiling:

```
D = D_min + (D_max − D_min) · (1 / (1 + e^(−a(D_raw − b))))
```

with `a`, `b`, `D_min`, `D_max` calibrated, not chosen. Ranking is what the app
needs; the old clamp destroyed it above grade ~16.

**Interactions and overfitting.** `|I| ≤ 5` at first. Every `v_ij` is L2-
regularized and must survive leave-one-interaction-out ablation. With 135 works,
each added coefficient costs real statistical power; the corpus cannot support
dozens.

**Uncertainty.** For each book, bootstrap the sampled passages (≥1,000 resamples)
and report the 2.5–97.5 percentile interval of `D`. Separately report an
**evidence grade**: the share of weighted dimensions at class A/B/C. A wide
interval or a low evidence grade suppresses the label (§8.6).

**Calibration.** Cut points are chosen to maximize agreement with blind human
grades on a held-out split, then frozen and versioned. They are a property of a
configuration, not of source code.

### 8.5 Difficulty and time are computed once, together

```
density = format_density(format, typography)     // words per displayed page; a CONVENTION
pages   = words / density                        // never depends on difficulty
T       = words / S_reader · h(D)                // difficulty enters exactly once
```

- `h(D)` is a single monotone function on reading speed, calibrated from observed
  sessions; `h(1.0) = 1.0`.
- `S_reader` is the reader's observed pace, or a declared default with its
  provenance shown.
- A page number is displayed only with its density assumption attached, e.g.
  "≈ 412 pages at 300 words per page". Never "412 pages".
- **No quantity named `pages` may ever enter the time equation** other than
  through `T` above, and difficulty must not appear in `pages`.

This one rule removes X2, X3 and half of X13.

### 8.6 Output contract

Per book, the engine emits:

```
words, chapters, sampled_share, excluded_sections[]
density_assumption, page_estimate_or_absent
D, D_interval, evidence_grade, label_or_refusal
per-dimension: raw, normalized, weight, contribution, reliability_class
explanation[]        // top three contributors, in words
config_id, config_hash, code_version, corpus_hash
provenance[]         // measured | extracted | modelled | human-validated
```

Rules: if `D_interval` exceeds a configured width, or evidence grade is below a
threshold, the output is **`INSUFFICIENT EVIDENCE TO ESTIMATE RELIABLY`** with the
reason. A refusal is a correct output, not a failure.

### 8.7 Labels

Keep the ordinal idea, drop the fixed constants. Six bands (Very Easy … Very
Challenging) with cut points calibrated per configuration and reported with a
confusion matrix. A label is never shown without its interval, and never claims
to measure intelligence, education, or literary merit.

### 8.8 Configuration and experiment tracking

One versioned JSON document, one entry per dimension:

```json
{
  "id": "contextual_dependency",
  "display": "Contextual dependency",
  "weight": 0.120000000000000,
  "default_weight": 0.120000000000000,
  "min": 0.0, "max": 0.5, "precision": 15, "enabled": true,
  "normalization": {"mu": 0.0, "sigma": 1.0, "k": 3.0, "ref_version": "ref-1"},
  "aggregation": {"lambda": 0.35, "statistic": "mean+Q90"},
  "reliability": "C",
  "version": 3,
  "last_modified": "2026-10-29",
  "validation": "explanatory only — excluded from D by experiment E-004"
}
```

- Numeric values stored at full precision; display rounding is separate.
- Every result records `config_id` and a hash of the configuration.
- No weight change may occur without a new configuration version and an
  experiment row.
- Experiment log: append-only JSONL — config id, corpus hash, code version,
  date, metrics, deltas from baseline, observations, limitations.

### 8.9 Software architecture

Modules with explicit contracts. The prototype lives in `tools/cde/` and never
writes to the app's data:

| Module | Input → Output |
|---|---|
| `extract` | package path → ordered documents, word count, diagnostics |
| `clean` | documents → normalized text, excluded sections |
| `segment` | text → sentences, paragraphs, chapters (canonical splitter) |
| `sample` | book → deterministic stratified windows + sampling record |
| `lexical` | tokens → dimension A features |
| `syntax` | sentences → dimension B features |
| `semantics` | clauses → C, I features |
| `entities` | passages → G graph features |
| `discourse` | passage sequence → D, H, J features |
| `dialogue` | segments → K features |
| `register` | tokens → L features |
| `normalize` | features + reference → [0,1] scores |
| `aggregate` | passage scores → dimension and book scores |
| `calibrate` | scores + human grades → cut points, intervals |
| `report` | everything → the §8.6 contract |

Determinism: extraction, segmentation, sampling, lexical, dialogue and
aggregation must be pure functions of bytes plus config. Anything probabilistic
(embeddings, model-based semantics) is isolated behind an interface, versioned,
cached by content hash, and must declare itself in `provenance[]`.

### 8.10 Reader relativity (deferred, hook only)

`D_reader = D_text − familiarity(reader_profile, features)` with familiarity
computed only from observed reader data. Not shipped in v1. No inference about a
reader's intelligence or education from their library.

---

## 9. Validation framework

**Corpus.** Stratify the 135 works plus additions by: contemporary fiction,
literary, fantasy, science fiction, mystery, translated, technical nonfiction,
philosophical, large-cast, simple-prose/complex-plot, complex-prose/simple-plot.
Report coverage per cell; no aggregate metric is reported without it.

**Blinding.** Graders see a passage, not the book's title, author, cover or the
engine's output. Title and author leak reputation and genre; the previous pass
was not blind, which is one reason it is void.

**Grading instrument.** 7-point ordinal effort scale with written anchors
("read once, no re-reading" … "multiple re-readings and external lookup"), plus a
separate `cannot judge`. Two independent graders per passage; a third adjudicates
disagreements above one band.

**Agreement.** Report Krippendorff's α (ordinal) with a bootstrap interval, plus
a confusion matrix. Target and rationale are fixed in Phase 3 *before* grading
begins, so the target cannot be chosen after seeing results.

**Metrics.** Spearman ρ and Kendall τ against the mean grade; ordinal MAE; label
agreement with adjacent-label tolerance; interval coverage (does the 95% interval
contain the human band 95% of the time?). Classification accuracy alone is
meaningless here: the labels are ordinal and partly subjective.

**Baselines, all reported on the same split:**

1. Flesch–Kincaid grade alone — the honest test, since the shipped model is
   r = 0.975 of it.
2. The shipped engine.
3. Word count.
4. The full CDE model.

A model that cannot beat FK grade alone has not earned its complexity.

**Ablation.** Leave one dimension out; report Δρ with interval. Any dimension
whose removal does not degrade performance is demoted to explanatory output.

**Out-of-sample discipline.** Split by author **and** series. No volume of a
series may appear in both training and evaluation. Report per-split results, not
pooled.

---

## 10. Failure analysis and refusal conditions

Known failure modes, each with a required handling:

| Failure | Handling |
|---|---|
| Poetry, verse, experimental prose | detect (line-break density, fragment ratio) → refuse |
| Nonlinear narrative, unreliable narrator | dimension E is C-class; refuse to report E as a score |
| Tables, indexes, appendices dominate | excluded sections reported; refuse if prose share is low |
| OCR corruption, broken encoding | diagnostic ratio; refuse below threshold |
| Multiple authors in one package | flag; do not attribute a single style |
| Omnibus / serial packages | detect by word count and chapter discontinuity; report as collection |
| Very short works | minimum token threshold → refuse |
| Language not modelled | refuse explicitly |
| Translated prose | never a penalty; measured through L, reported separately |
| Illegible sentence segmentation | segmentation confidence; refuse label |

The engine must prefer `INSUFFICIENT EVIDENCE TO ESTIMATE RELIABLY` to a
confident wrong answer. On this corpus, that state is reachable and real: 128 of
149 packages have no pagination at all, and **five** exceed one million words
(largest 4,917,494). Extraction contamination is measurable too: one navigation
document is a **1,414-entry** table of contents that the shipped counter reports
as **6,471 words** — 0.24% of its package, small here, but the mechanism is
unbounded because `estimateTotalWords` sums every spine document with no
prose test.

---

## 11. Feasibility: what is measurable now, what is not

This is the section that decides whether the architecture is real or decorative.

| Need | Status | Consequence |
|---|---|---|
| Word counts | **Available, verified** | Foundation is solid |
| Sentence/paragraph segmentation | Available; canonical splitter exists and must be adopted | R4 is cheap |
| Lexical frequency norms | **Not in the repository** | Dimension A blocked until a pinned, licensed list is chosen |
| Syntactic parser | **Not in the repository** | Dimension B needs a dependency parser or a validated heuristic |
| Coreference resolution | **Not available** | Dimensions D and J are proxy-only; must be labelled as such |
| Named-entity recognition | Available via the platform's natural-language framework | G is feasible at B class |
| Sentence embeddings | Available on-platform | C, H, I proxies feasible, must be versioned and cached |
| Page numbers | Not measurable for 128 of 149 packages | Page display is a convention (X12, §8.5) |
| Reading speed | **No observed data exists** | Time estimates cannot be validated until sessions are collected |

The dependency list is the real Phase 2 decision: a frequency norm and a parser
are prerequisites for the two dimensions the directive cares most about
(lexical difficulty and syntactic complexity). Neither can be assumed; both
need the owner's decision on size, licence and platform.

---

## 12. Phased plan and gates

| Phase | Deliverable | Gate to proceed |
|---|---|---|
| **P1 — audit** | this document; two read-only scripts; measured defect list | Owner accepts the defect list as the problem statement |
| **P2 — specification** | full feature dictionary, equations, config schema, dependency decision (frequency norm, parser) | Every dimension has an operational definition and a reliability class; every weight has a justification |
| **P3 — validation design** | blind rubric, anchors, corpus strata, metric targets, grader recruitment | Two graders committed; instrument piloted on 20 passages before full grading |
| **P4 — prototype** | `tools/cde/` executable alongside the app, writing nothing | Reproduces §4's measurements exactly on the existing corpus |
| **P5 — comparative testing** | CDE vs FK vs shipped engine vs human grades; ablation table | Out-of-sample results with intervals; failures published, not filtered |
| **P6 — refinement** | revised weights/features from P5 evidence | Every change has an experiment row and a measured delta |
| **P7 — migration** | recommendation, rollback plan, migration notes | CDE beats baselines out-of-sample; refusal behaviour tested |

**No production behaviour changes before P7.** The shipped engine remains the
baseline and stays untouched; the prototype is read-only and independent.

---

## 13. Decisions required from the owner

These cannot be made unilaterally because they change scope, cost or licensing:

1. **Lexical frequency resource.** Bundle a normed word-frequency list, derive
   one from the corpus (circular — not recommended), or proceed without
   dimension A. Affects app size and licence.
2. **Parser.** Adopt a dependency parser (new dependency, platform support to
   verify), or accept heuristic syntax features at lower reliability.
3. **Graders.** Two independent readers for ≥100 passages is the single largest
   cost in the plan. Without it, R13 is unmet and no accuracy claim is possible.
4. **Platform constraint.** On-device only, or may the prototype call a hosted
   model? This bounds what C, E and F can be.
5. **Purpose.** Is the primary consumer the reading-time estimate, the
   discovery/recommendation surfaces, or a displayed difficulty label? The
   metric to optimize differs.
6. **Refusal tolerance.** How often may the product say "cannot estimate"? A
   low tolerance pushes toward confident wrong answers, which is the current
   failure.

---

## 14. Limits of this audit

- Only one code path produced the 135 audited estimates. The second path (X3) is
  proven from source, not measured end to end through a UI.
- No reading-session data exists, so no claim here concerns real readers' speed.
- The 5,000-character coverage statistic assumes the app's spine order matches
  the package order; extraction order itself was not verified document by
  document.
- Page-marker detection matches the tokens `pagebreak` / `page-break`; an unusual
  convention would be missed, so 128 is an upper bound on unpaginated packages.
- The three series clusters are described, not statistically tested; 7 to 15
  books cannot support a variance decomposition on their own.
- The engine output this audit measures is a preserved snapshot (receipt in §1),
  not a re-run: `scripts/cde-phase1-audit.py` reads it rather than rebuilding the
  driver, so the numbers are stable but a rebuild could in principle differ.
- No literature was reviewed for this phase. Every method referenced above is
  described operationally, not cited. Phase 2 must ground or replace each one.
