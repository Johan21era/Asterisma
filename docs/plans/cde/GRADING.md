# Grading ADF against prose — protocol

- **Status:** instrument defined; first calibration batch graded and reported.
- **Governing plan:** `oct-december plans.md` §15 (Human Evaluation and Manual
  Grading), §13 (metrics), §12.1 (ground-truth definition).
- **Formula under test:** Asterisma Difficulty Formula (ADF) v0.3,
  `asterisma-difficulty-formula@0.3`.
- **Scores being graded:** `docs/audits/evidence/adf-149-scores-2026-10-29.json`.

## 0. What this protocol can and cannot decide

The governing plan is explicit, and it binds this document:

> "Human reviewers cannot establish the actual reading time of an individual
> merely by looking at a document. Their estimates are judgments, not
> automatically ground truth." — §15.2

> "Use manual review to improve content-quality assessment and identify
> suspicious outputs. Use observed outcomes to evaluate actual reading-time
> prediction accuracy." — §15.3

So grading answers exactly one question:

> **Does the band ADF assigns to this book match what a careful reader says the
> prose demands?**

It does **not** answer "is ADF accurate", because accuracy requires observed
reading sessions, which no amount of document inspection can supply. A grading
pass can find a book where the model is obviously wrong. It cannot certify that
the model is right.

This is the same trap that voided the previous pass: 135 verdicts, one grader,
no agreement statistic, and a page axis the files do not contain. The protocol
below fixes those three defects or declares them unfixed.

## 1. Labels

Four values, no others. The verdict is about the **band**, not the raw number:
a book graded `OK` agrees with ADF within one band on either side.

| Label | Meaning |
|---|---|
| `OK` | The band matches the demand of the sampled prose, within one band. |
| `TOO_LOW` | The prose is harder than the band claims. ADF under-calls this book. |
| `TOO_HIGH` | The prose is easier than the band claims. ADF over-calls this book. |
| `CANNOT_JUDGE` | The excerpt cannot support a verdict: it is not prose, it is a list or table, it is not English, the extraction is visibly broken, or the sample is unrepresentative of the book. |

`CANNOT_JUDGE` is a real answer and must not be replaced by a guess. Its rate is
itself a finding: it measures how often the sampled text is not gradeable.

**Required:** `band_as_i_would_call_it`, the grader's own band, using the same
five names. The verdict is then derived from the distance between that band and
ADF's, instead of being a separate judgement. Two independent judgements per row
(`verdict` *and* a band) can disagree with each other, and the previous protocol
gave no way to notice.

Optional fields, recorded but never required:

- `severity` — `1` slightly off, `2` clearly off, `3` badly off.
- `reason` — one clause, e.g. `dialogue-only window`, `dense nominal style`.

## 2. Bands

Bands are corpus quintiles (`Light`, `Moderate`, `Demanding`, `Heavy`,
`Extreme`), ordered 0–4. A verdict compares the reader's band judgement to
ADF's band; it does not compare raw `D` values, because `D` is a percentile and
its third decimal is noise.

## 3. Blindness

The grader must not see `D`, the band, the dimension breakdown, or the model's
explanation before assigning a label. The worksheet therefore ships two files:

- `*.blind.tsv` — book, window index, excerpt, empty `verdict` column. This is
  what the grader fills in.
- `*.scores.tsv` — the same rows with `D` and `band`. Used only by `analyze`.

Grading against a visible band invites anchoring, and an anchored grade cannot
detect bias.

## 4. Two independent passes, and what "independent" means here

With one available grader, true independence is impossible. The protocol
therefore asks for the strongest thing that is honest:

1. **Pass A** — grade a batch from the first sampled window.
2. **Pass B** — grade the same books from a different window, at least a day
   apart or after an intervening task, without looking at Pass A.
3. Report **percent agreement** and **Cohen's κ** between A and B, labelled
   `self-consistency`, never `inter-rater`.

A second human grader is the target state. Until one exists, every number from
this instrument is a single-observer result and must be reported that way. The
previous pass's self-consistency was 13/20 (65%); anything near that means the
verdicts cannot certify anything.

## 5. Adjudication

- A and B agree → the label stands.
- A and B disagree → the row is `UNRESOLVED` unless a third read resolves it.
  `UNRESOLVED` rows are excluded from bias estimates and counted separately.
- A row is never resolved by looking at the model's score. The model is the
  thing on trial.

## 6. Calibration before the main batch

Grade five books whose difficulty is not in doubt, spanning the range — one
children's chapter book, one plain commercial thriller, one literary novel, one
19th-century translated novel, one dense philosophical work. If those five do
not produce the expected ordering, the grader is not calibrated and the batch
does not start.

Expected ordering, stated before grading (so it can be wrong):

```
children's < commercial thriller < literary < 19th-century translated < dense philosophical
```

This is a coarse check on the grader, not on ADF.

## 7. Metrics reported

| Metric | Definition | Why |
|---|---|---|
| Verdict tally | counts of `OK` / `TOO_LOW` / `TOO_HIGH` / `CANNOT_JUDGE` | direction of failure |
| Band agreement | share of gradeable rows within one band | tolerance-based accuracy |
| Mean band delta | mean(reader band − ADF band) over resolved rows | systematic over/under-calling |
| Median band delta | median of the same | robust to one four-band miss |
| Largest over/under-call | extreme deltas | how bad the worst case is |
| Bias by band | signed bias within each ADF band | catches a model that is fine in the middle and wrong in the tails |
| `CANNOT_JUDGE` rate | share of unusable excerpts | data-quality signal |
| Self-consistency | % agreement and κ between passes A and B | how much the verdicts can bear |
| Coverage | graded rows / 149 packages | how much of the corpus was actually looked at |

A single headline accuracy number is deliberately not defined. With one grader
and no observed sessions, such a number would overstate what was measured.

## 8. Holdout discipline

- No grade is used to change a weight, a feature, or a threshold until the whole
  batch is complete and written down.
- If the grades lead to a change, the change is a new formula version and the
  grades are re-run against it. The grades are not re-read into the old version.
- `CANNOT_JUDGE` rows are never dropped silently; they are reported and, where
  the cause is a sampling defect, fixed in the sampler rather than in the label.

## 9. Reproduction

```bash
# 1. score every package (149, duplicates included)
python3 tools/cde/cde_sheet.py \
  --corpus "asterisma new testing suite" \
  --queue docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json \
  --reference tools/cde/config/reference-v3.json \
  --features-out docs/audits/evidence/adf-149-features-2026-10-29.json \
  --out-json docs/audits/evidence/adf-149-scores-2026-10-29.json \
  --out-md docs/audits/evidence/adf-149-sheet-2026-10-29.md

# 2. build the blind worksheet and the scores-only key
python3 tools/cde/cde_grade.py worksheet \
  --corpus "asterisma new testing suite" \
  --scores docs/audits/evidence/adf-149-scores-2026-10-29.json \
  --out docs/audits/evidence/adf-grades-worksheet-2026-10-29 \
  --window 0 --excerpt-chars 800

# 3. after grading, analyse (pass A, then A vs B)
python3 tools/cde/cde_grade.py analyze \
  --grades docs/audits/evidence/adf-grades-worksheet-2026-10-29.blind.tsv \
  --second-pass docs/audits/evidence/adf-grades-pass-b-2026-10-29.tsv \
  --out docs/audits/evidence/adf-grade-report-2026-10-29.json
```

## 10. What would change this protocol

- A second human grader becomes available → replace self-consistency with
  inter-rater agreement, and require κ ≥ 0.6 before trusting any bias estimate.
- Observed reading sessions for these 149 books exist → difficulty grading
  becomes a covariate in a time model, and accuracy is measured there instead.
- The sampler produces a `CANNOT_JUDGE` rate above 10% → fix sampling first;
  a grading pass on bad excerpts measures the sampler, not the formula.
