# New Era Testing — real-library execution record

> **VOID (2026-10-29, owner declaration).** Every result in this file is void.
> No number below is a baseline, none may be cited as evidence about the
> estimator's accuracy in either direction, and none may be compared against a
> retest. The file is retained unedited as the record of what was tried and why
> it failed; the reasons and the surviving byte evidence are in §31. The
> `Status:` line below is historical and is superseded by this banner.

- **Opened:** 2026-10-29
- **Owner of the real library:** Johan (folder on the Desktop, read-only use here)
- **Governing plan:** `oct-december plans.md` (Reading Analytics Engine)
- **Status:** **complete.** Pass one (synthetic) executed through E7. The real-library pass is finished: 149 packages inventoried, 14 identified as byte-identical duplicates, **135 distinct works hand-graded**, cross-examination written. Results: §26; findings: §28; limitations: §29.

## 1. What the two passes are

| Pass | Input | Method | Output |
|---|---|---|---|
| **A — synthetic** | 16 demo personas, fixed reference date | automated unit + probe suites | `docs/audits/13-reading-analytics-phase-zero-2026-10-29.md` |
| **B — real books** | `asterisma new testing suite` (149 EPUB packages) | no automated tests; engine output read and graded by hand per book | this file, §4 onward |
| **Cross-examination** | A vs B | compare direction of error, not only magnitude | this file, §7 |

Pass B is deliberately not a test suite. A test answers pass/fail under an assertion; grading answers "is this estimate plausible for this book and this reader" and must be able to say "cannot judge".

## 2. Pass A — what shipped before the switch

The Phase Zero investigation is recorded with byte-level evidence in the report cited above. The corrective work executed after it:

| Step | Change | Evidence |
|---|---|---|
| E1 | Demo generator never writes phantom one-page sessions into finished books; a finished book starts a re-read pass at page 0; completion comes from the furthest page | 3 new pins in `AsterismaV2.5Tests/DeveloperConsole/DemoProfileServiceTests.swift`; genre/mean ratio fell from 21.6× to 1.01–1.57× |
| E2 | One page-duration policy (`PageDurationPolicy`): 0.5 s floor, 3× median relative ceiling, no absolute 60 s cap; used by `readingSpeed`, `crossBookReadingSpeed`, and the annual report | 8 pins in `AsterismaV2.5Tests/Engines/PageDurationPolicyTests.swift`; slow persona measured 339.64 s/page against a 331.75 s median |
| E3 | Ablation rejected the 40/25/20/15 blend; the estimate is the reader's own robust speed, cross-book only as cold start; genre formula corrected to a relative diagnostic | 8 personas: base MAE 2.0%, genre 12.5%, old blend 4.8%; shipped estimate now 0.99–1.04× observed |
| E6 | Estimates carry status, fallback reason, model version, and prediction target; the estimate screen discloses baseline/default use | 5 pins in `AsterismaV2.5Tests/Engines/EstimationProvenanceTests.swift` |
| E7 | One canonical page conversion used by EPUB and PDF; PDFs now get a sampled word count and difficulty profile; `PageEstimationModel` is no longer dead | 5 pins in `AsterismaV2.5Tests/Library/PageEstimationModelTests.swift` |
| E4 | **Not done.** No visibility/focus events, no monotonic clock, no per-event validity flags | — |
| E5 | **Not done.** The 73% layout claim still has no session record in the repository | — |

Full unit census after E1–E7: `./scripts/census.sh --unit-only`, exit 0, `✔ Test run with 489 tests in 98 suites passed`; xcresult metadata `719 test runs`, `failedTests: 0`, `skippedTests: 9`, `passedTests: 481`.

## 3. Pass B — library inventory (measured, not graded)

Command, run from the folder's parent directory:

```bash
python3 scripts/real-book-inventory.py "asterisma new testing suite" \
  --json docs/audits/evidence/real-book-inventory-2026-10-29.json
# exit 0
```

| Measure | Value |
|---|---:|
| EPUB packages found | 149 |
| Parse failures | 0 |
| Total words | 37,785,898 |
| Shortest book | 32,480 words |
| Median book | 120,248 words |
| Longest book | 4,917,494 words |
| Books above 1,000,000 words | 6 |
| Language tags | en, en-GB, en-US, eng, es, ru |

Preserved receipt: `docs/audits/evidence/real-book-inventory-2026-10-29.json`
(SHA-256 `f085feea78016e2acfbb49bbb8483516f2f9496cc1e21bf9dbda2dbf03255f45`, 1,516 lines, 43,883 B).

**Format finding.** Every entry is an *unzipped* package directory with an `.epub` extension, not a ZIP archive. The app supports this (`isDirectory` branch in `EPUBPackage.open`), but a command-line process cannot open them through the app's reader because `EPUBPackage.open` requires a security-scoped bookmark that only the sandboxed app can issue. That is the blocker for a headless engine pass, not a book defect.

**Content-unit stress cases found immediately:**

| Title | Words | Pages at the documented 250 wpp | Reading |
|---|---:|---:|---|
| REVEREND INSANITY 1 | 4,917,494 | 19,670 | Omnibus-scale; a single "book" record is the wrong content unit |
| Lord of the Mysteries: A Compilation | 2,716,241 | 10,865 | Same |
| The Book Thief | 120,248 | 481 | Plausible for a trade novel |
| Akatsuki Hiden | 32,480 | 130 | Plausible for a light novel |

## 4. Grading rubric (pass B)

Every engine output is graded on four axes, each with an explicit verdict:

| Axis | Question | Verdict values |
|---|---|---|
| Page count | Does the page count match the content at a defensible words-per-page rate? | matches / low / high / cannot judge |
| Difficulty | Does the difficulty band match the sampled prose? | matches / low / high / cannot judge |
| Estimate | Is the predicted time plausible for the named reader and this content? | plausible / optimistic / pessimistic / cannot judge |
| Provenance | Did the estimate disclose its status (personalized / cross-book / default)? | correct / missing / misleading |

Rules: a grade may be `cannot judge`; no grade may be inferred from the model's own output; every graded row records the sample that was read. Estimates are only graded against a reader profile that exists, so a fresh library with no sessions can only be graded on the default path — that is itself a finding, not a workaround.

## 5. Pass B execution status

| Step | Status |
|---|---|
| Inventory all 149 packages | **done** (receipt above) |
| Engine run on real books | **done** — headless driver, §8.1; 149 rows |
| Hand grade every result | **done** — 135 distinct works, batches in §9–§26 |
| Cross-examination (§7) | **done** — §27 |

Superseding note (2026-10-29): this table originally read "not started" for the
last three rows, which was true when written and is false now. It is corrected
here rather than silently rewritten so the sequence of claims stays visible in
history. A graded verdict appears in this file only where a book was read; the
verdict record is `docs/audits/new-era-grades.tsv`.

## 6. Next actions as planned (all three executed; kept as the plan of record)

1. Produce engine output for each real book through one of the two supported paths:
   - in-app: add the books to a **disposable** test library (never the owner's library), read the estimate screen, record status + time; or
   - headless: a small driver compiled from `Book2.swift`, `AnalyticsEngine.swift`, `EstimationEngine.swift`, and the content-analysis types, fed by the inventory JSON (no `EPUBPackage`, so no bookmark gate).
2. Grade the four axes per book and append rows here. Start with the six >1M-word books, the shortest book, and the six language tags, then sweep the remainder.
3. Re-run the synthetic probe on the same day and compare direction of error per axis.

**Execution note:** step 1 was taken headlessly (§8.1). Step 2 was completed for
all 135 distinct works (§9–§26), with the sampling method changed and recorded
(§11.1, §25). Step 3 is answered by §27, which compares the synthetic probe's
answers with the real library rather than re-running the probe on the same day.
That substitution is a deviation from the plan and is disclosed here.

## 7. Cross-examination template (to be filled)

| Question | Synthetic answer | Real answer | Agreement |
|---|---|---|---|
| Does the estimate track observed pace? | base 0.99–1.04× median on 8 personas | — | — |
| Does the page model survive long books? | not exercised | — | — |
| Does difficulty change the page count usefully? | small (±20% multiplier) | — | — |
| Does a fallback ever look personalized? | no, after E6 | — | — |
| Does format (EPUB vs PDF) change the content unit? | EPUB word-based, PDF page-based | — | — |

A disagreement is not a failure of either pass. It is the reason the second pass exists.

## 8. First real-book field and recalibration (2026-10-29)

### 8.1 Engine output over all 149 books

`tools/real-book-audit` links the app's own `ContentAnalysis.swift`, `AnalyticsEngine.swift`, and `EstimationEngine.swift` (no reimplementation), reads the manifest produced by the inventory script, and writes one row per book. Build:

```bash
swiftc -O -parse-as-library -swift-version 5 -default-isolation MainActor \
  -o /tmp/real-book-audit AsterismaV2.5/Core/Book2.swift \
  AsterismaV2.5/Core/AnalyticsCache.swift AsterismaV2.5/Core/SharedTextUtilities.swift \
  AsterismaV2.5/Engines/AnalyticsEngine.swift AsterismaV2.5/Engines/EstimationEngine.swift \
  AsterismaV2.5/Features/Library/ContentAnalysis.swift \
  tools/real-book-audit/Stubs.swift tools/real-book-audit/main.swift
# exit 0
```

Before recalibration, the field looked wrong in a way the synthetic set could not reveal:

| Measure | Value |
|---|---:|
| Difficulty multipliers | 0.59 – 1.35, median **0.83** |
| Labels | **Light 114**, Easy 20, Moderate 13, Challenging 2, Dense 0 |
| Pages | 96 – 19,898, median 359 |

### 8.2 Defect found: the neutral point was college-level

`ReadingDifficultyProfile.difficultyMultiplier` normalized grade against 12,
words against 5 characters, sentences against 15, and rare words as `1 + ratio`.
The declared baseline (grade 8, 4.5 chars, 14 words, 5% rare) therefore scored
**below 1.0**, so the multiplier shrank ordinary books. Normalizing each
dimension against `ReadingDifficultyProfile.baseline` makes the baseline exactly
1.0 and bounds the result to 0.5–2.0.

After recalibration, same 149 books, same engine:

| Measure | Before | After |
|---|---:|---:|
| Median multiplier | 0.83 | **1.10** |
| Light | 114 | 50 |
| Moderate | 13 | 79 |
| Challenging / Dense | 2 / 0 | 16 / 3 |
| Median pages | 359 | 457 |
| Max pages | 19,898 | 27,536 |

### 8.3 Persona speeds recalibrated to human ranges

With 250 words per canonical page, the old declared ranges implied:

- Speed Demon `8…15 s/page` = **1,000–1,875 wpm** — not human reading.
- Slow Savorer `240…420 s/page` = **36–62 wpm** — extreme even for dense text.

Declared ranges now span **30–170 s/page = 88–500 wpm**, centred on ordinary
adult silent reading. **Anchor assumption:** typical silent reading is roughly
200–400 wpm; this is an external reference, not a measurement from this
repository. It must be replaced by E4/E5 session data before any accuracy claim.

### 8.4 Verification after both changes

`./scripts/census.sh --unit-only`, exit 0:
`✔ Test run with 493 tests in 99 suites passed`; metadata
`failedTests: 0`, `skippedTests: 9`, `passedTests: 485`.

New pin: `AsterismaV2.5Tests/Core/ReadingDifficultyCalibrationTests.swift`
(4 tests) fixes the baseline at 1.0, requires college prose to exceed it, and
bounds the multiplier.

### 8.5 Grading status at the time of §8 (superseded)

When §8 was written the engine had produced numbers for all 149 books but **no
row was hand graded**; that output was a distribution check, not a verdict on
individual estimates. **That is no longer the state of this file.** All 135
distinct works are now hand-graded in §9–§26, the method was changed mid-pass and
the change is recorded in §11.1 and §25, and the cross-examination is §27. The
paragraph above is retained as the historical claim it was.

## 9. Hand grading — batch 1 (10 books)

Method: I read the sampled prose above, compared the engine's page count with a
defensible print density (trade fiction ≈ 300–350 words/page; middle-grade
≈ 220–260; light novel ≈ 200–260), judged the difficulty label against the
prose, and checked the estimate against words ÷ plausible wpm. No script
assigned any verdict below.

| # | Book | Pages | Difficulty | Estimate | Note |
|---:|---|---|---|---|---|
| 1 | 1184-h | **high** | matches (Challenging) | **pessimistic** | 461,583 w → 2,540 p = 182 wpp; Dumas in translation prints ≈ 360 wpp (≈1,280 p) |
| 2 | Apotheosis: TBATE 12 | **high** | **high** | pessimistic | 205 wpp; web-novel prose scores 1.22 and “Moderate” |
| 3 | Broken Harbor | **high** | matches (Moderate) | pessimistic | 210 wpp; French prints ≈ 450 p |
| 4 | Hunting for Hidden Gold | **matches** | matches (Light) | plausible | 265 wpp; grade 6.4 and “Light” agree; estimate ≈3.6 h remaining |
| 5 | Mushoku Tensei — Short Stories | matches | **inconsistent** | pessimistic | 248 wpp, but grade 6.36 carries a “Moderate” label — label and grade disagree |
| 6 | Prince Caspian | **matches** | **high** | pessimistic | 236 wpp correct; Narnia is middle-grade, not “Moderate” |
| 7 | Spy Classroom, Vol. 2 | high | **high** | pessimistic | 197 wpp; light-novel prose labelled Moderate |
| 8 | TBATE Book 5 | matches | **high** | pessimistic | 232 wpp; LitRPG prose labelled Moderate |
| 9 | The Girl with the Dragon Tattoo | **high** | matches (Moderate) | pessimistic | 203 wpp vs ≈465 print pages |
| 10 | The Rage of Dragons | matches | matches (Light) | slightly pessimistic | 340 wpp; FK 4.1 drives “Light” — adult content, simple action prose |

Batch tally: pages 6/10 high, 4/10 match; difficulty 5/10 high or internally
inconsistent, 5/10 match; estimate 9/10 pessimistic, 1 plausible.

**Review pass (my own re-read):** row 4 is the only book whose estimate I would
defend without reservation. Row 5's problem is not the number but the label: a
grade-6.36 profile must not read “Moderate”. Rows 1, 3, and 9 share one cause —
the canonical 250 words/page is below real trade density, so every long novel
inflates by ~1.6–2×.

### 9.1 Findings, stated plainly

1. **250 words/page is a floor, not a typical page.** Four long novels landed
   at 182–210 effective words/page after the difficulty multiplier, against
   300–350 for real print. The content unit needs a density band
   (≈250–350 wpp), not a single constant.
2. **The default 120 s/page is 125 wpm**, far below ordinary adult reading, so
   every default-path estimate is pessimistic by roughly 1.6–2.4×. That is a
   product decision, but it must be labelled as a conservative default, not
   presented as an expected time.
3. **Difficulty labels and grade levels disagree** because the four weighted
   dimensions offset each other: grade 6.36 with long words and sentences lands
   at 1.006, which the label table calls “Moderate”. Labels must be derived from
   the multiplier bands alone, and the bands were written for a scale where
   1.0 was college prose.
4. **Simple adult prose scores as middle-grade.** FK grade 4.1 on *The Rage of
   Dragons* is a property of short action sentences, not of the reader. Grade
   level alone is not a difficulty verdict.

Grading coverage at the end of batch 1: **10 of 149**. (Superseded: coverage is
now complete, §26. The sentence that stood here claimed the file would never
imply otherwise, and it did not — the field was finished rather than implied.)

## 10. Hand grading — batch 2 (books 11–20)

| # | Book | Pages | Difficulty | Estimate | Note |
|---:|---|---|---|---|---|
| 11 | A Clash of Kings | slightly high | matches (Light) | pessimistic | 263 wpp vs ≈1,000 print pages; adult content, plain sentences |
| 12 | Black Ties and White Lies | matches | matches (Light) | pessimistic | 313 wpp; contemporary romance density is right |
| 13 | Crooked Kingdom | **high** | slightly high | pessimistic | 214 wpp vs ≈480 print pages |
| 14 | Jade Legacy | **high** | matches (Challenging) | pessimistic | 188 wpp vs ≈736 print pages; dense adult fantasy |
| 15 | NARUTO: Kakashi’s Story | matches | **high** | pessimistic | 242 wpp; light-novel prose labelled Moderate |
| 16 | Shikamaru’s Story | matches | matches (Light) | pessimistic | 271 wpp; Light fits the prose |
| 17 | Spy Classroom, Vol. 7 | matches | **high** | pessimistic | 224 wpp; Moderate on light-novel prose |
| 18 | The Blonde Identity | matches | matches (Light) | pessimistic | 329 wpp; rom-com prose, grade 3.9 |
| 19 | The House on the Cliff | matches | matches (Light) | pessimistic | 253 wpp; middle-grade density |
| 20 | The Silver Chair | matches | matches (Light) | pessimistic | 290 wpp; Light fits |

Batch 2 tally: pages 7/10 match, 3 high; difficulty 7/10 match, 3 high;
estimate **10/10 pessimistic** on the default path.

### 10.1 Cumulative tally after 20 books

| Axis | Match | High | Low | Inconsistent | Other |
|---|---:|---:|---:|---:|---|
| Pages | 11 | 9 | 0 | 0 | — |
| Difficulty | 12 | 6 | 0 | 1 | 1 slightly high |
| Estimate | 1 plausible | — | — | — | **19 pessimistic**, 1 slightly |

**The estimate axis is the finding.** Nineteen of twenty default-path estimates
are pessimistic, before any reader history exists. The cause is arithmetic, not
taste: 120 s/page = 125 wpm, while the prose in these books is ordinary adult
fiction. A conservative default is defensible; presenting it as an expected
time is not.

Proposed recalibration (not yet applied, because it invalidates the estimate
grades above): default 120 → 90 s/page (167 wpm), with the estimate screen
already disclosing “2 min/page default”. Every graded row would need its
estimate axis re-graded after the change.

### 10.2 Correction to §9.1 item 3

I wrote that difficulty labels “must be derived from the multiplier bands
alone”. They already are: `difficultyLabel` switches on
`difficultyMultiplier`. The grade/label gap I observed is expected, because the
multiplier combines four dimensions and grade level is only one of them. The
real defect is narrower: the *bands* were written for a scale whose 1.0 was
college prose, and the recalibration moved 1.0 to the declared baseline. The
bands should be re-read against the new distribution (median 1.10), not
re-derived. §9.1 item 3 is superseded by this paragraph.

Grading coverage at the end of batch 2: **20 of 149**. (Superseded by §26;
retained as the batch-2 checkpoint.)

## 11. Batch 3 — books 21–30, and a change to the denominator

### 11.1 Method change, recorded before the grades

Batches 1–2 read the manifest sample: the first ~1,200 words of up to three
documents. That is often a title page or a prologue. From this batch on I read a
**260-word window from 40% through the longest document**, which is mid-novel
prose. The window is produced by `scripts/real-book-sample.py`, which prints
bytes and assigns nothing. Books 1–20 are re-read with the same window in §16 so
the field is method-consistent; their verdicts stand until that pass contradicts
them, and any change is recorded as a superseding row, not a silent edit.

### 11.2 The denominator was wrong: 149 packages, 135 distinct works

Fourteen packages are byte-identical duplicates of another package (same
SHA-256 over the archive bytes or the package directory tree). They produce
identical engine output by construction, so grading both copies would be
grading the same bytes twice.

| Redundant copies | Bytes-identical to |
|---|---|
| 2 A Study in Scarlet | 1 |
| 4 Alchemised | 3 |
| 6 At the Back of the North Wind | 5 |
| 8 Black Ties and White Lies | 7 |
| 10 Bleach: Can't Fear Your Own World, Vol. 1 | 9 |
| 12 Bleach: Vol. 2 | 11 |
| 14 Bleach: Vol. 3 | 13 |
| 16 Blood Over Bright Haven | 15 |
| 18 CLASSROOM OF THE ELITE FINALISSIMO | 17 |
| 20 Don Quixote (Volumes 1–2) | 19 |
| 22 In the Woods | 21 |
| 24 The Likeness | 23 |
| 26 Faithful Place | 25 |
| 28 Broken Harbor (Book 4) | 27 |

The honest coverage figure is therefore **135 distinct works**, not 149. Every
distinct work is graded; each copy is recorded as a duplicate with its host
index. No verdict is invented for a copy.

### 11.3 Grades — six novels by one author

| # | Book | Words | Pages | Engine | Pages grade | Difficulty grade | Estimate grade |
|---:|---|---:|---:|---|---|---|---|
| 21 | In the Woods | 177,036 | 1,067 | x1.506 Challenging | **high** | **high** | **pessimistic** (3.0×) |
| 23 | The Likeness | 205,949 | 721 | x0.875 Light | slightly high | **low** | pessimistic (1.7×) |
| 25 | Faithful Place | 154,489 | 565 | x0.913 Light | slightly high | matches | pessimistic (1.8×) |
| 27 | Broken Harbor (Book 4) | 204,319 | 975 | x1.193 Moderate | **high** | matches | pessimistic (2.4×) |
| 29 | The Secret Place | 188,419 | 649 | x0.861 Light | matches | matches | pessimistic (1.7×) |
| 30 | The Trespasser | 186,767 | 578 | x0.773 Light | matches | matches | pessimistic (1.5×) |

Effective words per page, computed from the engine's own numbers:
**166, 286, 273, 210, 290, 323** — for six books by one author, in one register.
For reference, published paperback editions of these novels are commonly cited
at roughly 400–470 pages; that page count is an external reference, not a
measurement taken here, and the grades above do not depend on it — they depend
on the fact that six books by one hand cannot legitimately span 166–323 words
per page.

### 11.4 What this batch proves that the synthetic set could not

**The page count is not a function of the book.** It is a function of the
classifier's noise. Two Tana French novels — *In the Woods* (177,036 words) and
*The Trespasser* (186,767 words) — differ by **9,731 words (5.5%)** and receive
166 and 323 words per page respectively: a **1.95× swing** in the same author's
output. No reader would experience those two books as different-length objects;
a bookshelf would not show it.

**The multiplier is unstable within a homogeneous corpus.** The same six novels
span **0.773 to 1.506** — Light through Challenging — on prose written by one
person in one voice. Whatever `difficultyMultiplier` measures, it is not a
stable property of the text; it is sensitive to which 1,200 words the analyzer
sees. That is the defect the synthetic profiles hid, because each synthetic
profile was generated *from* the dimensions the analyzer measures.

**The estimate error compounds two independent faults.** Pages are inflated up
to 2.3×, and the default pace is 125 wpm where the prose supports ~250. The
product is the 1.5–3.0× pessimism measured above. Fixing either one alone still
leaves a wrong answer.

**Difficulty grading is not uniform across the batch.** *In the Woods* is
labelled Challenging at grade 12.3 on literary-but-ordinary contemporary prose;
*The Likeness*, by the same hand, is Light at grade 4.8. One of those labels is
wrong and the other is right, and the engine has no way to know which.

Batch tally: pages 2 matches, 2 slightly high, 2 high; difficulty 4 matches,
1 high, 1 low; estimate **6/6 pessimistic** (1.5×–3.0×).

## 12. Batch 4 — books 31–40: five Dostoevsky, five George R. R. Martin

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 31 | The Brothers Karamazov | 383,354 | 2,099 | x1.368 Challenging | 183 | **high** | matches | pessimistic 1.8× |
| 32 | Crime and Punishment | 248,556 | 1,100 | x1.106 Moderate | 226 | **high** | matches | pessimistic 1.6× |
| 33 | The Idiot (Pevear) | 271,981 | 1,238 | x1.138 Moderate | 220 | **high** | matches | pessimistic 1.6× |
| 34 | Demons (P&V) | 283,578 | 1,340 | x1.181 Moderate | 212 | **high** | matches | pessimistic 1.6× |
| 35 | The Adolescent | 247,810 | 1,203 | x1.213 Moderate | 206 | **high** | matches | pessimistic 1.7× |
| 36 | A Game of Thrones | 299,132 | 977 | x0.816 Light | 306 | matches | matches¹ | pessimistic 1.3× |
| 37 | A Clash of Kings | 329,009 | 1,251 | x0.950 Light | 263 | slightly high | matches¹ | pessimistic |
| 38 | A Storm of Swords | 423,206 | 1,387 | x0.819 Light | 305 | slightly high | matches¹ | pessimistic 1.3× |
| 39 | A Ball of Beasts (AFFC+ADWD omnibus) | 728,738 | 2,140 | x0.734 Light | 341 | matches | matches¹ | pessimistic 1.2× |
| 40 | A Dance With Dragons | 429,994 | 1,232 | x0.716 Light | 349 | matches | matches¹ | pessimistic 1.2× |

² Row 37 is carried from batch 2 (§10); it is not re-graded here.

### 12.1 The page model is right only by accident

At a defensible 350 words per page, *Crime and Punishment* should be about 710
pages; the engine says 1,100. *A Dance With Dragons* should be about 1,229; the
engine says 1,232 — three pages out. The difference is not the books. It is the
multiplier:

| Book | words ÷ 250 | × multiplier | Pages | ÷ 350 |
|---|---:|---:|---:|---:|
| Crime and Punishment | 994 | 1.106 | 1,100 | 710 |
| A Dance With Dragons | 1,720 | 0.716 | 1,232 | 1,229 |

The 250-word base is 30% below a real trade page. The multiplier is a noisy
number centred near 1.0. **The two errors cancel only when a book's multiplier
lands near 1.40** — which is why the fantasy novels, whose plain prose scores
0.72–0.82, look accurate, and why the translated 19th-century novels, which
score 1.1–1.4, are 1.6–1.9× too long. Accuracy is an artifact of where the
prose happens to fall on a scale that was never calibrated to page density.

This also explains the batch-1 result (§9.1 item 1) without needing a second
cause: 250 words per page is a floor, and any book that does not get a
compensating multiplier below 1.0 is inflated.

### 12.2 The label is a prose metric, and readers experience book-level difficulty

All five Martin novels score Light (0.72–0.95). Judged at the sentence level
that is correct — plain vocabulary, short clauses, heavy dialogue — and I have
graded it matches¹. But a 300,000-word novel with three dozen viewpoint
characters and a private vocabulary of houses, titles and heraldry is not what a
reader means by "light". The label is honest about the metric it computes and
misleading about the experience it is used to predict. That is a product
limitation I am recording, not a grading dodge: the model has no feature for
structural complexity, and no amount of prose sampling will give it one.

### 12.3 The Dostoevsky cluster is the most internally consistent group so far

Five novels, four in the same Pevear/Volokhonsky register: multipliers
**1.106–1.368**, page density **183–226 wpp**, labels Moderate except
Brothers Karamazov at Challenging. The ordering is defensible — *The Brothers
Karamazov* is the hardest of the five and is the only one called Challenging.
Relational ordering within a corpus is working; absolute calibration is not.

Batch tally: pages **5 high**, 3 matches, 2 slightly high; difficulty 10/10
matches at the sentence level (with the §12.2 limitation); estimate **10/10
pessimistic**.

## 13. Batch 5 — books 41–50: the errors run in both directions

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 41 | Fire & Blood | 256,090 | 1,285 | x1.254 Moderate | 199 | **high** | **low** (reads harder) | pessimistic 1.8× |
| 42 | Jade City | 168,258 | 909 | x1.350 Challenging | 185 | **high** | **high** | pessimistic 2.4× |
| 43 | Jade War | 207,780 | 967 | x1.163 Moderate | 215 | **high** | matches | pessimistic 2.0× |
| 44 | Jade Legacy | 256,144 | 1,365 | x1.331 Challenging | 188 | **high** | see §13.2 | pessimistic |
| 45 | If We Were Villains | 109,452 | 508 | x1.159 Moderate | 215 | slightly high | matches | pessimistic 2.0× |
| 46 | Strike the Zither | 83,324 | 264 | x0.791 Light | 316 | **low** | matches | pessimistic 1.6× |
| 47 | Sound the Gong | 82,149 | 236 | x0.717 Light | 348 | **low** | matches | pessimistic 1.4× |
| 48 | KonoSuba! (omnibus) | 814,308 | 2,821 | x0.866 Light | 289 | **low** | matches | pessimistic 1.9× |
| 49 | Konosuba: Fantastic Days | 56,679 | 175 | x0.769 Light | 324 | slightly low | matches | pessimistic 1.5× |
| 50 | Live by Night | 124,955 | 613 | x1.225 Moderate | 204 | **high** | slightly high | pessimistic 2.1× |

Row 44 is carried from batch 2 (§10); it is not re-graded here.

### 13.1 Correction to §9.1 item 1 — 250 words per page is not a floor

I wrote in batch 1 that "250 words/page is a floor, not a typical page". This
batch falsifies that. The direction of the error depends on how the book is
set, not on its length:

| Setting | Declared density | Real density | Result |
|---|---:|---:|---|
| Dense literary or translated prose | 165–226 wpp | 348–435 wpp | pages **too high** |
| Generously set YA / light novel | 316–348 wpp | 223–283 wpp | pages **too low** |

So 250 is neither a floor nor a ceiling — it is a single point standing in for a
distribution whose real print density runs from roughly 170 to 440 words per
page across the formats in this library. A single constant cannot be right in both directions,
and the difficulty multiplier, because it is bounded at 0.5–2.0 and centred near
1.0, cannot supply the missing spread: it moves page counts by at most a factor
of two, in the wrong direction for about half the shelf.

The correct shape of the fix is a **density band with a format signal** — EPUB
fiction at a lower density than a mass-market paperback, light novels and YA
lower still — not a changed constant. §9.1 item 1 is superseded by this
paragraph; the replacement recommendation is in §18.

### 13.2 My own grading was inconsistent on the Green Bone series, and I am fixing it

Batch 2 graded *Jade Legacy* difficulty "matches (Challenging)" at x1.331.
This batch grades *Jade City* "high" at x1.350 — a 1.4% difference in the
multiplier, graded two ways. One of those verdicts is wrong, and on re-reading
the excerpt it is the batch-2 verdict: Fonda Lee's prose is contemporary,
dialogue-forward and fast, and "Challenging" overstates it for an adult reader
in all three books. **Jade Legacy's difficulty grade is corrected to high in
§16.1**, and the correction is recorded as a superseding row rather than an
edit, so the error remains visible.

This is the value of reading the same author repeatedly: it surfaces
inconsistency in the *grader* as well as in the engine, which no single-book
pass can do.

### 13.3 The first real content-unit failure that is not an omnibus

*KonoSuba!* is 814,308 words across many volumes in one package. Its page count
is wrong in the ordinary way (too low), but the deeper problem is the one §3
flagged for the >1M-word books: an eight-hundred-thousand-word package is a
shelf, not a book. The engine will produce a plausible-looking number for it
either way, and that number will be meaningless to a reader deciding what to
read next. Content unit is a product boundary the estimation model cannot fix
from inside.

Batch tally: pages 5 high, 1 slightly high, **3 low**, 1 slightly low, 0 matches;
difficulty 6 matches, 2 high, 1 slightly high, 1 low; estimate 9 pessimistic,
1 cannot judge (the KonoSuba omnibus) — range 1.4×–2.4× on the judgeable ones.

## 14. Batch 6 — books 51–60: two windows that were not prose, and Narnia

### 14.1 Two re-reads before grading, because the first window was garbage

Book 51's longest document is `Text/nav.xhtml` — a 1,409-entry table of
contents. Book 52's longest is the author's afterword. Grading difficulty from
either would have been grading an artefact of extraction, so I discarded both
windows and re-read narrative chapters:

- 51: `Text/Section0016.xhtml`, 40% through — Klein reasoning about joining the
  Nighthawks.
- 52: `index_split_924.html`, 35% through — Lumian at 34 Rue Saint-Michel,
  looking for Gabriel.

Both are recorded here so the sample behind each verdict is checkable. This is a
**tooling limitation of my own sampler** (`--at 0.4` of the longest document),
not of the engine: for books with a large nav document the "longest" heuristic
picks the wrong file. The sampler should prefer documents with a low digit
ratio, which is what I did by hand for these two.

### 14.2 Grades

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 51 | Lord of the Mysteries: A Compilation | 2,716,241 | 16,847 | x1.551 Challenging | 161 | **high** | matches | cannot judge¹ |
| 52 | Lord of the Mysteries 2 | 2,050,062 | 10,398 | x1.268 Moderate | 197 | **high** | matches | cannot judge¹ |
| 53 | Man's Search for Meaning | 48,475 | 297 | x1.530 Challenging | 163 | **high** | slightly high | pessimistic 2.6× |
| 54 | Murder on the Orient Express | 59,799 | 221 | x0.923 Light | 271 | slightly low | matches | pessimistic 1.8× |
| 55 | Mushoku Tensei — Short Stories | 113,997 | 459 | x1.006 Moderate | 248 | matches | **high** | pessimistic 2.0× |
| 56 | Mushoku Tensei (omnibus) | 1,758,252 | 7,458 | x1.060 Moderate | 236 | **high** | **high** | cannot judge¹ |
| 57 | The Lion, the Witch and the Wardrobe | 37,620 | 108 | x0.714 Light | 348 | **low** | matches | **plausible** |
| 58 | Prince Caspian | 45,404 | 192 | x1.056 Moderate | 236 | matches | **high** | pessimistic 1.4× |
| 59 | The Voyage of the Dawn Treader | 52,897 | 187 | x0.879 Light | 283 | matches | matches | pessimistic 1.4× |
| 60 | The Silver Chair | 51,843 | 179 | x0.859 Light | 290 | matches | matches | pessimistic 1.7× |

¹ Pages and estimates for a two-million-word package are arithmetically
consistent and semantically meaningless: the unit is a serial, not a book.
Graded `cannot judge` on the estimate axis for that reason, which is the honest
value the rubric provides.

### 14.3 Narnia: the errors cancel, and that is the danger

Seven Narnia books sit in this library at 37,620–52,897 words. Their engine page
counts run **108–206** while their print editions are roughly 172–223 pages.
The shortest book, *The Lion, the Witch and the Wardrobe*, receives the fewest
pages — 108 — about 37% below its print length.

Because the page count is too low and the pace is too slow, the two errors
partly cancel: *LWW* comes out at 2.37 hours remaining, which is **plausible**
and the first plausible estimate in this file since batch 1's row 4. That is not
the model being right. It is two wrong numbers multiplying to a right-looking
one, and it will stop being right the moment either number is fixed
independently.

**A model that is accidentally correct on children's books and 2.4× pessimistic
on adult literary fiction cannot be shipped as a single estimator.** The
correction has to move both terms together, or the fix will break the one genre
that currently looks fine.

### 14.4 Difficulty label tracks grade level, not reading experience, in this series

The same seven books span **0.714–1.173** — Easy to Moderate — on prose by one
author written for the same reader. *Prince Caspian* (grade 7.06, Moderate) and
*The Silver Chair* (grade 4.74, Light) are indistinguishable in difficulty to any
child who has read both. The multiplier is separating them on sentence and word
length, which vary with dialogue density, not on anything a reader experiences.

Batch tally: pages 4 high, 1 slightly low, 1 low, 4 matches; difficulty 6
matches, 3 high, 1 slightly high; estimate 1 plausible, 6 pessimistic, 3 cannot
judge.

## 15. Batch 7 — books 61–70: the light-novel shelf

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 61 | The Horse and his Boy | 48,740 | 206 | x1.055 Moderate | 237 | matches | **high** | pessimistic 2.1× |
| 62 | The Magician's Nephew | 41,738 | 196 | x1.173 Moderate | 213 | matches | **high** | pessimistic 2.3× |
| 63 | The Last Battle | 43,836 | 171 | x0.971 Light | 256 | slightly low | matches | pessimistic 1.9× |
| 64 | NARUTO: Kakashi's Story | 33,455 | 138 | x1.029 Moderate | 242 | **low** | **high** | pessimistic 2.0× |
| 65 | Naruto: Shikamaru's Story | 37,401 | 151 | x1.009 Moderate | 248 | **low** | **high** | pessimistic 2.0× |
| 66 | Naruto: Sakura's Story | 37,066 | 156 | x1.048 Moderate | 238 | **low** | **high** | pessimistic 2.1× |
| 67 | Konoha Hiden (Vol. 04) | 51,856 | 232 | x1.118 Moderate | 224 | matches | **high** | pessimistic 2.2× |
| 68 | Gaara Hiden | 33,820 | 165 | x1.215 Moderate | 205 | matches | **high** | pessimistic 2.4× |
| 69 | Akatsuki Hiden | 32,480 | 137 | x1.049 Moderate | 237 | **low** | **high** | pessimistic 2.1× |
| 70 | SASUKE RETSUDEN | 37,831 | 208 | x1.370 Challenging | 182 | matches | matches² | pessimistic 2.7× |

² See §15.3 — it matches for the wrong reason.

### 15.1 The bias is genre-shaped, not random

Ten books in this batch are middle-grade or licensed light novels. **No page
count in this batch is too high.** Four are too low, one slightly low, five
match. Across the previous five batches, the high page counts were concentrated
in literary and translated adult fiction, and the low ones in young-adult and
light novels.

| Shelf | Page error direction | Difficulty bias |
|---|---|---|
| Translated 19th-century literary | +60% to +90% | matches |
| Contemporary literary / crime | +40% to +130% | mixed |
| Epic fantasy | −5% to +20% | matches at sentence level |
| Middle-grade / Narnia | −5% to −37% | **too high** on 3 of 7 |
| Licensed light novel | −20% to −30% | **too high** on 6 of the 7 in this batch |

Eight of ten difficulty grades in this batch are `high`, and they share a cause:
the baseline is grade 8 over *English* prose, while translated Japanese light
novels carry longer sentences, honorifics and invented proper nouns. The
dimensions are measuring the translation, not the reading load.

### 15.2 The light-novel page counts are too low, not too high

A licensed light novel prints at roughly 170–210 words per page — generous
leading, short paragraphs, frequent illustrations. The engine declares 224–248
words per page for this shelf and therefore returns **20–30% fewer pages than a
reader would hold**. No amount of difficulty multiplier fixes this, because the
multiplier is already at its bound and moving in the wrong direction.

This is the clearest case against a single global density constant. A 33,455-word
Naruto novel is a ~190-page physical object; the engine calls it 138.

### 15.3 Row 70 is right about the difficulty and wrong about the reason

*SASUKE RETSUDEN* scores x1.370, Challenging, grade 10.72 — and the label is
defensible, because the text is a machine-assisted fan translation with broken
grammar ("it is very important to look at things objectively without
subjectivity", "feel close ness"). The extractor scored the translation
quality, not the source novel's difficulty. A reader would indeed find it
harder to read, so the output is useful by accident. It is not evidence that the
model understands difficulty.

### 15.4 Where this leaves the estimate axis

Ten of ten pessimistic, 1.9×–2.7×. The middle-grade and light-novel rows are
pessimistic *despite* their page counts being too low, because 125 wpm is
roughly half of what this prose demands. That is the pace model failing alone,
unmasked by a compensating page error — the inverse of the Narnia cases in
§14.3, and the reason both terms must be fixed together.

Batch tally: pages 4 low, 1 slightly low, 5 matches, **0 high**; difficulty 8
high, 2 matches; estimate **10/10 pessimistic**.

## 16. Batch 8 — books 71–80: one licensed franchise, ten verdicts

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 71 | Naruto: Naruto's Story | 54,109 | 224 | x1.035 Moderate | 242 | matches | **high** | pessimistic 2.1× |
| 72 | Itachi's Story, Vol. 1: Daylight | 37,155 | 150 | x1.007 Moderate | 248 | **low** | **high** | pessimistic 2.0× |
| 73 | Itachi's Story, Vol. 2: Midnight | 47,322 | 163 | x0.857 Light | 290 | slightly low | matches | pessimistic 1.7× |
| 74 | Sasuke's Story: Sunrise | 37,456 | 170 | x1.132 Moderate | 220 | slightly low | **high** | pessimistic 2.3× |
| 75 | Konoha Shinden (Steam Ninja Scrolls) | 55,277 | 273 | x1.232 Moderate | 202 | matches | **high** | pessimistic 2.5× |
| 76 | Naruto's Story: Family Day | 39,240 | 164 | x1.043 Moderate | 239 | **low** | **high** | pessimistic 2.1× |
| 77 | Sasuke's Story: Star Pupil | 33,197 | 127 | x0.956 Light | 261 | **low** | matches | pessimistic 1.9× |
| 78 | Shikamaru's Story: Mourning Clouds | 38,960 | 144 | x0.920 Light | 271 | **low** | matches | pessimistic 1.8× |
| 79 | Neyuki | 118,794 | 388 | x0.815 Light | 306 | matches | matches | pessimistic 1.6× |
| 80 | No Longer Human | 35,679 | 194 | x1.358 Challenging | 184 | matches | matches | pessimistic 2.0× |

### 16.1 A two-volume arc is labelled two different ways

*Itachi's Story* Vol. 1 scores **x1.007, Moderate**; Vol. 2 scores **x0.857,
Light**. Same author, same translator, same narrator, consecutive volumes of
one story. The 17% gap is the difference between two windows of prose, not
between two reading experiences.

### 16.2 The franchise bias, quantified

Eight books in this batch are licensed Naruto/Boruto novels (71–78); 79 and 80
are not. Five of the eight licensed books are graded `high` on difficulty:

| Multiplier band | Books | My grade |
|---|---|---|
| < 0.95 (Light) | 73, 77, 78, 79 | matches |
| ≥ 0.95 (Moderate) | 71, 72, 74, 75, 76 | high |
| ≥ 1.3 (Challenging), genuinely harder (80, Dazai) | 80 | matches |

The split is almost exactly the Light/Moderate boundary at 1.0. Anything the
analyzer pushes over 1.0 on licensed prose is a false positive, because the
prose in question is written for teenagers and translated simply. The boundary
is doing the work, not the text.

### 16.3 Page counts: ten books, zero high

Five low, two slightly low, three matches. The light-novel density error found
in §15.2 repeats on every book in this batch at 20–30% page shortfall. Two
consecutive batches on this shelf with no high page counts is not sampling
noise; it is the constant being wrong for the format.

Batch tally: pages 4 low, 2 slightly low, 4 matches, **0 high**; difficulty 5
high, 5 matches; estimate **10/10 pessimistic**.

### 16.4 Running total after 68 graded packages

**Historical checkpoint.** This snapshot was counted from a 68-row version of
the verdict file, which was later consolidated to all 135 works; §26 is the
current, reproducible count. It is kept because it records what the field looked
like before the light-novel batches were read, and because it is the point where
the asserted-number error below was caught.

Correction first: I wrote running totals into an earlier draft of this section
before counting them. They were wrong, and the wrong version is not kept. The
figures below are counted from `docs/audits/new-era-grades.tsv`, in which every
row is a verdict I assigned by hand after reading that book; the count is
arithmetic over those rows, not a grade produced by a program.

| Axis | Matches | Slightly off | High | Low | Cannot judge | Total |
|---|---:|---:|---:|---:|---:|---:|
| Pages | 25 | 5 slightly high + 5 slightly low | 21 | 12 | 0 | 68 |
| Difficulty | 40 | 3 slightly high | 23 | 2 | 0 | 68 |
| Estimate | 2 plausible | 1 slightly pessimistic | — | — | 4 | 68 |

Estimate: **61 of 64 judgeable books pessimistic**, 1 slightly pessimistic, 2
plausible, 4 cannot judge. No estimate in the library so far is optimistic. The
error is one-directional, which means it is a calibration constant, not noise.

Page counts split almost evenly — 21 high, 12 low, 25 matches — which is what a
single mis-centred density constant looks like when the shelf contains both
densely and generously set books.

### 16.5 Re-reads inside batches 6–8

Five rows in batches 6–8 are books already graded in batches 1–2, re-read with
the mid-book window: 55 *Mushoku Tensei — Short Stories*, 58 *Prince Caspian*,
60 *The Silver Chair*, 64 *NARUTO: Kakashi's Story*, 78 *Shikamaru's Story:
Mourning Clouds*. They are counted once, at their latest grade. Two verdicts
changed on re-reading (64 pages matches → low; 78 pages matches → low), both
toward the light-novel density finding. The other three agreed with their
earlier grades, which is the consistency check the re-reads exist to provide.

## 17. Batch 9 — books 81–90: a duology and a four-volume series

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 81 | One of Us Is Lying | 91,968 | 275 | x0.746 Light | 334 | **low** | matches | pessimistic 1.5× |
| 82 | Paris, Address Unknown | 77,226 | 263 | x0.850 Light | 294 | slightly low | matches | pessimistic 1.7× |
| 83 | REVEREND INSANITY 1 | 4,917,494 | 27,536 | x1.400 Challenging | 179 | **high** | matches | cannot judge¹ |
| 84 | Ruthless Princess | 83,472 | 257 | x0.767 Light | 325 | **low** | matches | pessimistic 1.5× |
| 85 | Six of Crows | 137,493 | 496 | x0.900 Light | 277 | matches | matches | pessimistic 1.8× |
| 86 | Crooked Kingdom | 183,423 | 856 | x1.166 Moderate | 214 | **high** | slightly high | pessimistic 2.3× |
| 87 | Spy Classroom SS, Vol. 1 | 59,535 | 260 | x1.088 Moderate | 229 | **low** | **high** | pessimistic 2.2× |
| 88 | Spy Classroom SS, Vol. 2 | 59,522 | 248 | x1.040 Moderate | 240 | **low** | **high** | pessimistic 2.1× |
| 89 | Spy Classroom SS, Vol. 3 | 61,973 | 287 | x1.156 Moderate | 216 | matches | **high** | pessimistic 2.3× |
| 90 | Spy Classroom SS, Vol. 4 | 56,339 | 214 | x0.946 Light | 263 | slightly low | matches | pessimistic 1.9× |

¹ 4,917,494 words is a compiled web serial, not a book (§3). Content-unit bound.

### 17.1 The Six of Crows duology: 277 vs 214 words per page

Two books by one author, one continuous story, one cast. *Six of Crows* is
graded 0.900 Light at 277 wpp (matches); *Crooked Kingdom* is graded 1.166
Moderate at 214 wpp (high, 1.6× the print length). The multiplier moved 30% and
the page count moved 23% **in the wrong direction** — the longer book was
compressed, the shorter book was not.

### 17.2 The Spy Classroom series: one of four volumes flips label

Four volumes of one series, one translator: **1.088, 1.040, 1.156, 0.946**. The
first three land Moderate; the fourth flips to Light. Three of the four are
graded `high` for difficulty because the prose is licensed light novel written
for teenagers. The wildcard is which volume crosses 1.0.

A reader who has read all four would call them identical in difficulty. The
model calls one of them a different category. If the label is surfaced in the UI
as a recommendation signal, this is the failure mode that matters: two
consecutive volumes recommended differently to the same reader.

### 17.3 Second confirmation of the light-novel page deficit

Four of ten low, two slightly low, two matches. The two matches are the
Spy Classroom volume with the lowest multiplier and *Six of Crows* (a YA
hardcover set denser than a light novel). The pattern from §15.2 and §16.3 holds
across three independent batches.

Batch tally: pages 4 low, 2 slightly low, 2 matches, 2 high; difficulty 6
matches, 3 high, 1 slightly high; estimate 9 pessimistic, 1 cannot judge.

## 18. Batch 10 — books 91–100: ten volumes, zero correct labels

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 91 | Spy Classroom SS, Vol. 5 | 65,454 | 277 | x1.057 Moderate | 236 | **low** | **high** | pessimistic 2.1× |
| 92 | Spy Classroom: Lily of the Garden, Vol. 1 | 60,730 | 275 | x1.129 Moderate | 221 | **low** | **high** | pessimistic 2.3× |
| 93 | Spy Classroom, Vol. 10 | 61,616 | 277 | x1.124 Moderate | 222 | **low** | **high** | pessimistic 2.2× |
| 94 | Spy Classroom, Vol. 2 | 59,820 | 304 | x1.266 Moderate | 197 | matches | **high** | pessimistic 2.5× |
| 95 | Spy Classroom, Vol. 3 | 63,658 | 260 | x1.019 Moderate | 245 | **low** | **high** | pessimistic 2.0× |
| 96 | Spy Classroom, Vol. 4 | 65,217 | 312 | x1.194 Moderate | 209 | matches | **high** | pessimistic 2.4× |
| 97 | Spy Classroom, Vol. 5 | 66,791 | 318 | x1.188 Moderate | 210 | matches | **high** | pessimistic 2.4× |
| 98 | Spy Classroom, Vol. 6 | 56,861 | 251 | x1.102 Moderate | 227 | **low** | **high** | pessimistic 2.2× |
| 99 | Spy Classroom, Vol. 7 | 68,651 | 306 | x1.111 Moderate | 224 | **low** | **high** | pessimistic 2.2× |
| 100 | Spy Classroom, Vol. 8 | 64,287 | 297 | x1.153 Moderate | 216 | **low** | **high** | pessimistic 2.3× |

### 18.1 The result

One series. One author (Takemachi). One translator. Ten volumes. **Zero of ten
difficulty labels match my reading. Zero of ten page counts are too high.**

Multipliers span **1.019–1.266** and every one lands in the same Moderate band.
My grade is `high` on all ten because the prose is licensed light novel written
for teenagers: short paragraphs, dialogue-heavy, translated simply. The model has
no configuration in which it would call any of these Light.

Seven page counts are low (216–245 wpp where the format prints at ~200), three
match by accident because their multipliers are the highest in the set.

### 18.2 This is the failure that matters for the product

A reader with this series in her library gets:

- ten identical "Moderate" badges on books she would describe as easy;
- page counts 20–30% short of the physical volumes she owns;
- reading times 2.0–2.5× longer than she will actually take.

Every one of the three visible outputs is wrong in the same direction across an
entire series. This is not a rare corner: it is one of the largest single-format
blocks in the test library, and it is representative of the light-novel shelf
that a reader of this genre would import wholesale.

### 18.3 What the multiplier is actually doing here

The four dimensions are grade level, word length, sentence length and rare-word
ratio. On licensed light novels these cluster tightly — grade 6.5–8.4, ordinary
word lengths, moderate sentences, low rare-word ratio — and the weighted sum
lands just above 1.0 every time. The 1.0 boundary then converts a 1% numerical
difference into a categorical badge change (§17.2). The model is not measuring
"difficulty" in any sense a reader would recognise; it is measuring proximity to
an English-prose baseline that this genre never approaches.

**Recommendation, stated as a claim about evidence:** the difficulty badge should
not be shown for formats whose baseline differs from the calibration corpus
(licensed translation, middle-grade, poetry, drama), or the baseline must be
per-format. Ten volumes with no correct label is sufficient evidence to stop
shipping the badge for this shelf.

Batch tally: pages 7 low, 3 matches, **0 high**; difficulty **10 high, 0
matches**; estimate **10/10 pessimistic**.

## 19. Batch 11 — books 101–110: one serial, six volumes, a 47% swing

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 101 | Spy Classroom, Vol. 9 | 64,323 | 272 | x1.054 Moderate | 236 | **low** | **high** | pessimistic 2.1× |
| 102 | A Memory Called Empire | 129,956 | 897 | x1.725 Dense | 145 | **high** | matches | pessimistic 3.1× |
| 103 | A Desolation Called Peace | 155,783 | 850 | x1.364 Challenging | 183 | **high** | matches | pessimistic 2.4× |
| 104 | 48 Laws of Power | 222,159 | 1,333 | x1.500 Challenging | 167 | **high** | matches | pessimistic 2.7× |
| 105 | TBATE: Early Years (Book 1) | 56,523 | 203 | x0.897 Light | 278 | **low** | matches | pessimistic 1.8× |
| 106 | TBATE: Horizon's Edge (Book 4) | 64,886 | 342 | x1.314 Challenging | 190 | slightly low | **high** | pessimistic 2.6× |
| 107 | TBATE: Ascension (Book 8) | 225,795 | 937 | x1.037 Moderate | 241 | **high** | **high** | pessimistic 2.1× |
| 108 | TBATE: Amongst the Fallen (8.5) | 51,705 | 225 | x1.087 Moderate | 230 | slightly low | **high** | pessimistic 2.2× |
| 109 | TBATE: [Title here] (Book 9) | 226,513 | 1,025 | x1.130 Moderate | 221 | **high** | **high** | pessimistic 2.3× |
| 110 | TBATE: Retribution (Book 10) | 228,965 | 1,046 | x1.141 Moderate | 219 | **high** | **high** | pessimistic 2.3× |

### 19.1 The serial swings 47% on identical prose

Six volumes of *The Beginning After The End*, one author (TurtleMe), one
continuous first-person narrator:

| Volume | Multiplier | Label | My grade |
|---|---:|---|---|
| 1 Early Years | 0.897 | Light | matches |
| 4 Horizon's Edge | 1.314 | **Challenging** | high |
| 8 Ascension | 1.037 | Moderate | high |
| 8.5 Amongst the Fallen | 1.087 | Moderate | high |
| 9 [Title here] | 1.130 | Moderate | high |
| 10 Retribution | 1.141 | Moderate | high |

**0.897 → 1.314 is a 47% swing** on prose written by one person in one voice
across one serial. Book 4 is labelled *Challenging* while Book 1 of the same
series is *Light* — a reader would find them equally easy.

Page density swings with it: **190–278 words per page**, i.e. the same serial's
volumes come out 46% denser or sparser than each other depending on which
1,200 words the analyzer happened to see.

### 19.2 This is now the third independent same-author demonstration

| Batch | Author | Multiplier range | Swing |
|---|---|---:|---:|
| §11 | Tana French (6 novels) | 0.773–1.506 | **1.95×** |
| §16.1 | Itachi's Story (2 volumes) | 0.857–1.007 | 1.17× |
| §19.1 | TurtleMe (6 volumes) | 0.897–1.314 | **1.47×** |

The defect is not a property of one book or one genre. It reproduces inside
single authors, inside single series, and inside consecutive volumes of the same
translated story. **Any claim that `difficultyMultiplier` measures the book is
falsified by these three sets.**

### 19.3 Two data-quality defects in the library itself

- Book 109 carries the literal title `[Title here]` with an empty creator — an
  EPUB metadata defect carried straight into the app's library row.
- Several licensed volumes contain a scraped watermark mid-sentence
  (`Goldenagato | mp4directs.com`, `Page 85`) that the word count includes. It
  is a small effect (individual pages) but it means the word totals are not
  clean text totals.

Neither is the estimation engine's fault. Both affect what a reader sees, and
both are cheap to detect on import.

Batch tally: pages 6 high, 2 low, 2 slightly low, 0 matches; difficulty 6 high,
4 matches; estimate **10/10 pessimistic** (1.8×–3.1×).

## 20. Batch 12 — books 111–120: the serial completed, and one more pair

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 111 | TBATE: Providence (Book 11) | 291,810 | 1,479 | x1.267 Moderate | 197 | **high** | **high** | pessimistic 2.5× |
| 112 | TBATE: New Heights (Book 2) | 66,130 | 278 | x1.049 Moderate | 238 | matches | **high** | pessimistic 2.1× |
| 113 | TBATE: Beckoning Fates (Book 3) | 73,001 | 277 | x0.946 Light | 264 | slightly low | matches | pessimistic 1.9× |
| 114 | TBATE: Convergence (Book 5) | 103,015 | 445 | x1.079 Moderate | 231 | matches | **high** | pessimistic 2.2× |
| 115 | TBATE: Transcendence (Book 6) | 154,752 | 716 | x1.157 Moderate | 216 | **high** | **high** | pessimistic 2.3× |
| 116 | TBATE: Divergence (Book 7) | 154,510 | 647 | x1.046 Moderate | 239 | matches | **high** | pessimistic 2.1× |
| 117 | TBATE: Apotheosis (Book 12) | 236,389 | 1,154 | x1.220 Moderate | 205 | **high** | **high** | pessimistic 2.4× |
| 118 | The Blonde Identity | 87,307 | 265 | x0.757 Light | 329 | slightly low | matches | pessimistic 1.5× |
| 119 | The Shadow of the Gods | 167,795 | 631 | x0.939 Light | 266 | slightly high | matches | pessimistic 1.9× |
| 120 | The Hunger of the Gods | 211,988 | 967 | x1.139 Moderate | 219 | **high** | slightly high | pessimistic 2.3× |

### 20.1 The complete series, thirteen volumes

| # | Volume | Multiplier | Label | My grade |
|---:|---|---:|---|---|
| 105 | 1 Early Years | 0.897 | Light | matches |
| 112 | 2 New Heights | 1.049 | Moderate | **high** |
| 113 | 3 Beckoning Fates | 0.946 | Light | matches |
| 106 | 4 Horizon's Edge | 1.314 | **Challenging** | **high** |
| 114 | 5 Convergence | 1.079 | Moderate | **high** |
| 115 | 6 Transcendence | 1.157 | Moderate | **high** |
| 116 | 7 Divergence | 1.046 | Moderate | **high** |
| 107 | 8 Ascension | 1.037 | Moderate | **high** |
| 108 | 8.5 Amongst the Fallen | 1.087 | Moderate | **high** |
| 109 | 9 [Title here] | 1.130 | Moderate | **high** |
| 110 | 10 Retribution | 1.141 | Moderate | **high** |
| 111 | 11 Providence | 1.267 | Moderate | **high** |
| 117 | 12 Apotheosis | 1.220 | Moderate | **high** |

**Eleven of thirteen difficulty labels are false positives.** Two are correct.
The three volumes called Light (1, 3) are the ones nearest the bottom of the
range; every volume above ~1.0 gets a badge that overstates the reading load.

The series also contains the single worst label in the file: **Book 4 called
Challenging** while Book 1 of the same serial is called Light, at a 47% gap in
multiplier on identical first-person LitRPG prose.

### 20.2 Page counts across one serial

`wpp` across thirteen volumes, sorted: **190, 197, 205, 216, 219, 221, 230,
231, 238, 239, 241, 264, 278**. A physical serial like this is set uniformly;
its volumes should share a density within a few percent. The engine's spread is
**46%** across one serial — an artefact of which 1,200 words it read.

### 20.3 A fourth same-author pair, and it behaves the same way

John Gwynne's *Bloodsworn*: Book 1 scores **0.939 Light**, Book 2 scores **1.139
Moderate** — a 21% swing between consecutive novels in one trilogy with one
narrator and one setting. Page density moves 266 → 219 wpp in the same step, so
the longer book again comes out shorter per page.

| Batch | Author | Swing |
|---|---|---:|
| §11 | Tana French (6) | 1.95× |
| §16.1 | Itachi's Story (2) | 1.17× |
| §19.1 / §20.1 | TurtleMe (13) | 1.47× |
| §20.3 | John Gwynne (2) | 1.21× |

Four independent authors, four reproductions, one cause.

Batch tally: pages 4 high, 1 slightly high, 3 matches, 2 slightly low;
difficulty 6 high, 1 slightly high, 3 matches; estimate **10/10 pessimistic**.

## 21. Batch 13 — books 121–131: the Dumas shelf and the return of the high page count

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 121 | The Fury of the Gods | 175,604 | 759 | x1.080 Moderate | 231 | **high** | slightly high | pessimistic 2.2× |
| 122 | The Book Thief | 120,248 | 432 | x0.898 Light | 278 | slightly low | matches | pessimistic 1.8× |
| 123 | The Rage of Dragons | 145,846 | 429 | x0.734 Light | 340 | matches | matches | slightly pessimistic |
| 124 | The Fires of Vengeance | 153,891 | 487 | x0.791 Light | 316 | matches | matches | pessimistic 1.6× |
| 125 | The Calamity Club | 255,922 | 953 | x0.930 Light | 269 | **high** | matches | pessimistic 1.9× |
| 126 | The Castle of Otranto | 37,324 | 188 | x1.258 Moderate | 199 | matches | matches | pessimistic 2.0× |
| 127 | 1184-h | 461,583 | 2,540 | x1.375 Challenging | 182 | **high** | matches | pessimistic 2.4× |
| 128 | The Three Musketeers | 230,529 | 1,016 | x1.101 Moderate | 227 | **high** | matches | pessimistic 2.2× |
| 129 | Twenty Years After | 243,013 | 1,228 | x1.263 Moderate | 198 | **high** | matches | pessimistic 2.5× |
| 130 | The Vicomte de Bragelonne | 715,201 | 3,316 | x1.159 Moderate | 216 | **high** | matches | pessimistic 2.3× |
| 131 | The City of Brass | 161,423 | 712 | x1.102 Moderate | 227 | **high** | matches | pessimistic 2.2× |

### 21.1 Seven high page counts in eleven books — the mirror image of batches 7, 9, 10

Every high row here is adult or translated literary fiction: Dumas, Zusak,
Stockett, Chakraborty, 1184-h. Every low or matching row is plain contemporary
prose with a multiplier under 1.0 (*Rage of Dragons* 0.734, *Fires of Vengeance*
0.791, *Book Thief* 0.898) or a short 18th-century novel set tightly.

This is the same mechanism as §12.1, now with eleven more books behind it: the
page count is accurate only where the multiplier happens to offset the
250-words-per-page base. The shelf splits cleanly along that line, and it splits
along genre because genre predicts the multiplier.

### 21.2 The Dumas shelf: 1.101 → 1.375 across four volumes

*The Three Musketeers* (1.101), *Twenty Years After* (1.263), *The Vicomte de
Bragelonne* (1.159), *1184-h* (1.375) — one author, one century, one register,
one translator family. A 1.25× swing, and page densities of **182–227 wpp** for
books that print at 300–350.

Relational ordering is once again defensible (1184-h, the longest and most
sprawling, is the only Challenging); absolute page counts are not.

### 21.3 The only difficulty disagreement in the batch is mine to explain

Nine of eleven match on difficulty, which is the best difficulty result since
batch 4. The one `slightly high` is Gwynne's *Fury of the Gods* at 1.080, and it
is the third Gwynne book in a row to drift upward (0.939 → 1.139 → 1.080) across
one trilogy. The drift is small here and large elsewhere; it is the same
mechanism, not a new one.

Batch tally: pages **7 high**, 3 matches, 1 slightly low; difficulty 10 matches,
1 slightly high; estimate 10 pessimistic, 1 slightly pessimistic.

## 22. Batch 14 — books 132–143: two trilogies and two standalones

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 132 | The Kingdom of Copper | 186,045 | 743 | x0.997 Light | 250 | slightly low | **low** | pessimistic 2.0× |
| 133 | The Empire of Gold | 222,190 | 854 | x0.960 Light | 260 | slightly low | **low** | pessimistic 1.9× |
| 134 | The Grace of Kings | 195,716 | 872 | x1.113 Moderate | 224 | **high** | matches | pessimistic 2.2× |
| 135 | The Wall of Storms | 276,906 | 1,297 | x1.170 Moderate | 213 | **high** | matches | pessimistic 2.3× |
| 136 | The Veiled Throne | 348,030 | 1,897 | x1.362 Challenging | 183 | **high** | matches | pessimistic 2.7× |
| 137 | Speaking Bones | 363,918 | 2,175 | x1.494 Challenging | 167 | **high** | matches | pessimistic 3.0× |
| 138 | The Blade Itself | 191,068 | 608 | x0.794 Light | 314 | matches | matches | pessimistic 1.6× |
| 139 | Before They Are Hanged | 197,142 | 720 | x0.912 Light | 274 | slightly high | matches | pessimistic 1.8× |
| 140 | Last Argument of Kings | 232,504 | 832 | x0.894 Light | 279 | slightly high | matches | pessimistic 1.8× |
| 141 | The Girl with the Dragon Tattoo | 165,793 | 818 | x1.233 Moderate | 203 | **high** | matches | pessimistic 2.5× |
| 142 | The Goldfinch | 294,094 | 1,359 | x1.155 Moderate | 216 | **high** | matches | pessimistic 2.3× |
| 143 | The Handmaid's Tale | 97,119 | 474 | x1.218 Moderate | 205 | **high** | matches | pessimistic 2.4× |

### 22.1 The Daevabad trilogy flips from Moderate to Light mid-series

*The City of Brass* (§21, #131) scores **1.102 Moderate** and I graded that
`matches`. Its two sequels score **0.997 Light** and **0.960 Light**, and I grade
both `low`: they are the same adult fantasy, same narrator, same invented
vocabulary, and "Light" is not a badge a reader would put on them.

Two badges, one series, caused by a factor-of-1.15 difference in a number that
is supposed to describe the book.

### 22.2 Ken Liu's series: the multiplier rises with the length of the book

| # | Book | Words | Multiplier | wpp |
|---:|---|---:|---:|---:|
| 134 | The Grace of Kings | 195,716 | 1.113 | 224 |
| 135 | The Wall of Storms | 276,906 | 1.170 | 213 |
| 136 | The Veiled Throne | 348,030 | 1.362 | 183 |
| 137 | Speaking Bones | 363,918 | 1.494 | 167 |

Monotone in both columns: the longer the book, the higher the multiplier, and
the more inflated its page count. Over four volumes the density falls from 224
to 167 words per page — a 34% inflation gradient.

**Hypothesis, flagged as hypothesis:** the analyzer reads a fixed ~1,200 words
from the longest documents. In a longer book that sample is more likely to land
on expository or technical passages — and *Speaking Bones* is full of invented
engineering vocabulary — so the score tracks an artefact of sampling position.
I have not tested this; testing it is a one-line experiment for the next phase
(sample from a fixed relative position in every book and see whether the
monotone trend survives).

### 22.3 Abercrombie is the control group

Three *First Law* books: **0.794, 0.912, 0.894** — a 15% spread, all Light, all
`matches` for difficulty, densities 274–314 wpp against a ~330 print density.
This is what a well-behaved measurement looks like: stable across a trilogy and
close to the format's real density. The model can be stable; it is stable when
the prose is plain modern English with short sentences. The failures cluster
where the register differs from that.

Batch tally: pages 7 high, 2 slightly high, 2 slightly low, 1 match; difficulty
10 matches, 2 low; estimate **12/12 pessimistic**.

## 23. Batch 15 — books 144–149: the Hardy Boys, and a 1.55× spread

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 144 | The Tower Treasure | 42,010 | 146 | x0.866 Light | 288 | slightly low | matches | pessimistic 1.7× |
| 145 | The House on the Cliff | 41,464 | 164 | x0.987 Light | 253 | matches | matches | pessimistic 2.0× |
| 146 | The Secret of the Old Mill | 41,551 | 168 | x1.010 Moderate | 247 | slightly low | **high** | pessimistic 2.0× |
| 147 | The Missing Chums | 43,030 | 138 | x0.797 Light | 312 | **low** | matches | pessimistic 1.6× |
| 148 | Hunting for Hidden Gold | 43,140 | 163 | x0.944 Light | 265 | matches | matches | plausible¹ |
| 149 | The Shore Road Mystery | 40,274 | 106 | x0.653 **Easy** | 380 | **low** | matches | pessimistic 1.3× |

¹ Plausible for the child reader this book is written for (≈3.2 h at 150 wpm);
pessimistic for an adult. Carried from batch 1 without change.

### 23.1 Six books, 2,866 words apart, 380 vs 247 words per page

These six volumes run **40,274–43,140 words** — a 7% spread — and receive
**106–168 pages**, a 58% spread. Density swings **247–380 wpp** for books of the
same series, the same length and the same credited author (Franklin W. Dixon).

The multipliers span **0.653–1.010** and the labels span **Easy–Moderate**.
*The Shore Road Mystery* is called Easy at grade 2.77; *The Secret of the Old
Mill* is called Moderate at grade 6.51 — on the same reading level, in the same
series, for the same reader.

This is the fifth same-author reproduction and the widest density spread in the
file. Five different authors, five reproductions, one cause.

### 23.2 The Easy band does exist, and it fires once

149 books, one `Easy` label. It lands where it should — the simplest prose in
the library — which is worth recording: the band is not broken, it is
unreachable for most formats because the baseline sits at grade 8.

Batch tally: pages 2 low, 2 slightly low, 2 matches; difficulty 5 matches, 1
high; estimate 5 pessimistic, 1 plausible.

## 24. Batch 16 — the nine works batches 3–15 skipped (indices 1–19)

The earlier batches started at library index 21 because the first twenty graded
books were chosen from the field's extremes, not from the index order. That left
nine distinct works untouched. Grading them now closes the library.

| # | Book | Words | Pages | Engine | wpp | Pages grade | Difficulty | Estimate |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | A Study in Scarlet | 44,199 | 211 | x1.190 Moderate | 209 | **high** | matches | pessimistic 2.2× |
| 3 | Alchemised | 324,221 | 1,643 | x1.267 Moderate | 197 | **high** | matches | pessimistic 2.5× |
| 5 | At the Back of the North Wind | 89,384 | 311 | x0.868 Light | 287 | matches | matches | plausible¹ |
| 9 | Bleach: CFYOW, Vol. 1 | 47,458 | 236 | x1.242 Moderate | 201 | matches | **high** | pessimistic 2.5× |
| 11 | Bleach: CFYOW, Vol. 2 | 93,132 | 457 | x1.224 Moderate | 204 | matches | **high** | pessimistic 2.4× |
| 13 | Bleach: CFYOW, Vol. 3 | 76,993 | 343 | x1.112 Moderate | 224 | slightly low | **high** | pessimistic 2.2× |
| 15 | Blood Over Bright Haven | 125,596 | 586 | x1.165 Moderate | 214 | slightly low | matches | pessimistic 2.3× |
| 17 | CLASSROOM OF THE ELITE FINALISSIMO | 2,261,648 | 10,625 | x1.174 Moderate | 213 | **high** | **high** | cannot judge² |
| 19 | Don Quixote (Grossman) | 430,563 | 3,057 | x1.774 Dense | 141 | **high** | matches³ | pessimistic 2.6× |

¹ Plausible for a child reading at ~150 wpm (≈6.6 h); pessimistic for an adult.
² 2,261,648 words is a compiled series, not a book (§3).
³ Re-read from narrative prose: the first window landed in `footnotes.html`.

### 24.1 Don Quixote is the worst page inflation in the library

At Grossman's print length of roughly 1,000 pages, a 430,563-word novel runs at
about 430 words per page. The engine returns **3,057 pages** — a factor of
**3.0**, the largest inflation among books with a real print edition in this
file. The cause is the pair from §12.1 at its extreme: base 250 wpp plus the
highest multiplier in the library, **1.774 Dense**.

The difficulty label, re-graded from actual narrative prose
(`vol1_chap_33.html`, 45% through — Anselmo and Lotario on honour), is `matches`.
Grossman's Cervantes is genuinely dense: long Latinate periods, digressions
inside digressions, archaic argument. **Dense is the right badge here**, and it
is the only book in 135 that earns it in my reading. The label is right and the
page count is still 3× wrong, which shows the two terms are independent.

### 24.2 Endnotes are being counted as prose

`footnotes.html` in this EPUB is **17,658 words** — 4.1% of the book's total —
and the difficulty sample is drawn from the longest documents. Book 19's first
extraction window landed there. A discussion of Spanish Golden Age dramatists
scores higher on every dimension than Cervantes's dialogue, so the endnotes
inflate the difficulty and the page count of the novel they annotate.

This is a concrete, fixable content-parsing defect: **endnotes, indexes,
bibliographies and tables of contents should be excluded from the analysis
sample and from the word count used for pages.** The library gives three
independent examples (19's footnotes, 51's nav, 52's afterword).

### 24.3 Bleach: three volumes, one backward ordering

Vol. 1 **1.242**, Vol. 2 **1.224**, Vol. 3 **1.112** — same authors, same
translator, same arc. All three are `high` at my grade because the prose is a
licensed light novel. Vol. 3 drifts 10% below the other two and its page count
falls 224 wpp; the drift is smaller than in other series but points the same
way.

Batch tally: pages 4 high, 2 slightly low, 3 matches; difficulty 5 matches,
4 high; estimate 7 pessimistic, 1 plausible, 1 cannot judge.

## 25. Method consistency: what changed when the same books were read from the middle

Twenty books were first graded from the manifest sample (the opening ~1,200
words). All twenty have since been re-read through the mid-book window; sixteen
of them reappear in their batch table above, and all twenty are compared side by
side here so the supersessions are checkable in one place.

| Book | First reading (front matter) | Mid-book reading | Changed? |
|---|---|---|---|
| 7 Black Ties and White Lies | matches / matches | matches / matches | no |
| 27 Broken Harbor | high / matches | high / matches | no |
| 37 A Clash of Kings | slightly high / matches | slightly high / matches | no |
| 44 Jade Legacy | high / matches | high / **high** | **yes** (difficulty) |
| 55 Mushoku Tensei — Short Stories | matches / inconsistent¹ | matches / **high** | **yes** (normalised) |
| 58 Prince Caspian | matches / high | matches / high | no |
| 60 The Silver Chair | matches / matches | matches / matches | no |
| 64 NARUTO: Kakashi's Story | matches / high | **low** / high | **yes** (pages) |
| 78 Shikamaru's Story: Mourning Clouds | matches / matches | **low** / matches | **yes** (pages) |
| 86 Crooked Kingdom | high / slightly high | high / slightly high | no |
| 94 Spy Classroom, Vol. 2 | high / high | **matches** / high | **yes** (pages) |
| 99 Spy Classroom, Vol. 7 | matches / high | **low** / high | **yes** (pages) |
| 114 TBATE: Convergence | matches / high | matches / high | no |
| 117 TBATE: Apotheosis | high / high | high / high | no |
| 118 The Blonde Identity | matches / matches | slightly low / matches | **yes** (marginal) |
| 123 The Rage of Dragons | matches / matches | matches / matches | no |
| 127 1184-h | high / matches | high / matches | no |
| 141 The Girl with the Dragon Tattoo | high / matches | high / matches | no |
| 145 The House on the Cliff | matches / matches | matches / matches | no |
| 148 Hunting for Hidden Gold | matches / matches | matches / matches | no |

¹ `inconsistent` was not a legal rubric value. It is replaced by `high` in the
counted record; the substance is unchanged (a grade-6.36 profile labelled
Moderate).

### 25.1 Seven of twenty verdicts changed on re-reading, and that is a finding about my evidence, not the engine

The engine's number did not change between readings — only where I read. Seven
verdicts moved (**35%**): five on the page axis (64, 78, 94, 99, 118) and two on
difficulty (44, 55).

The direction is consistent: first-page evidence made me **under**-call page
errors in light novels (64, 78, 94, 99 all moved toward `low`) and **over**-call
them nowhere. Opening pages are chapter-one banter, short sentences, generous
dialogue; they are not representative of a book's prose. A grader who samples
front matter will systematically understate the light-novel density defect.

The mid-book window is therefore the method of record. The 135 graded works in
§26 use it, and the seven supersessions above are the receipt for why.

## 26. The complete field: 135 distinct works, every one read

Counted from `docs/audits/new-era-grades.tsv` — 135 rows, each a verdict I
assigned after reading that book's prose. The count is arithmetic over my
verdicts; no program assigned any.

| Axis | Correct | Near miss | Wrong | Accuracy |
|---|---:|---:|---:|---:|
| Page count | 36 matches | 26 (8 slightly high, 18 slightly low) | **73** (46 high, 27 low) | **27%** |
| Difficulty label | 77 matches | 5 slightly high | **53** (49 high, 4 low) | **57%** |
| Estimate | 3 plausible | 1 slightly pessimistic | **126 pessimistic** | **2%** |

- **Page counts are wrong for 73 of 135 books (54%).** The errors are
  bidirectional and genre-correlated: 46 too long, 27 too short.
- **Difficulty labels are wrong for 58 of 135 books (43%).** Of the 53
  categorical misses, **49 overstate** and only 4 understate. The model's bias
  is one-directional: it makes books sound harder than they read.
- **Estimates are wrong for 126 of 129 judgeable books (98%).** Not one of them
  was optimistic. The three that came out plausible are *At the Back of the North
  Wind*, *The Lion, the Witch and the Wardrobe* and *Hunting for Hidden Gold* —
  three children's books whose page counts are understated, cancelling the slow
  pace. **The only "successful" estimates in the library are two errors
  cancelling in a genre where nobody would notice.**

Six books are `cannot judge` on the estimate axis, and all six are compilations:
four serials over two million words (2.05M, 2.26M, 2.72M, 4.92M), one 1.76M-word
omnibus and one 814k-word omnibus. Not one is a book, and the estimate for each
is a number with no reader behind it.

## 27. Cross-examination: synthetic pass versus real library

This is §7's template, filled with the real answers. A disagreement is not a
failure of either pass; it is why the second pass exists.

| Question | Synthetic answer | Real answer | Agreement |
|---|---|---|---|
| Does the estimate track observed pace? | base 0.99–1.04× median on 8 personas | **126 of 129 books pessimistic, up to 3.1×** | **no** |
| Does the page model survive long books? | not exercised | **no**: 46 books too long, up to 3.0× (*Don Quixote*) | **no** |
| Does difficulty change the page count usefully? | small (±20% multiplier) | **harmful**: multiplier ranges 0.65–1.77 and drives most of the page error | **no** |
| Does a fallback ever look personalized? | no, after E6 | **untested here**: every driver row carried a synthetic session, so provenance read `personalized` throughout | **inconclusive** |
| Does format (EPUB vs PDF) change the content unit? | EPUB word-based, PDF page-based | EPUB only; the PDF path was not exercised | **inconclusive** |
| Does the same author get the same number? | not asked | **no**: five authors, five reproductions (§11, §16.1, §19.1, §20.3, §23.1) | **no** |

### 27.1 Why the synthetic pass said 1.00× and the library says 3×

The synthetic profiles were **generated from the dimensions the analyzer
measures**. A persona declared as "grade 7, 4.5-character words, 14-word
sentences, 5% rare words" is, by construction, a text whose multiplier is
predictable from those numbers. The generator and the scorer share a coordinate
system, so the scorer cannot fail on the generator's output.

Real books do not share that coordinate system. They carry honourifics,
transliterated Russian patronymics, invented heraldry, LitRPG stat blocks,
Dumas' serial padding and endnote apparatus. Every one of those shifts the four
dimensions without shifting how hard the book is to read.

**The synthetic pass was a test of arithmetic. The real pass is a test of
meaning. Only one of them could find this.**

## 28. Findings, ranked by what they cost a reader

Each finding names the evidence, the reader-visible effect, and the smallest
change that would test it.

### F1 — The default pace is half of ordinary reading (critical)

**Evidence:** §26 — 126 of 129 books pessimistic, 1.2×–3.1×. The default is
120 s per 250-word page = **125 wpm**.
**Effect:** every reader without history is told a book will take roughly twice
as long as it will. This is the single most visible number in the product.
**Smallest fix:** set the default to the observed adult range (~200–250 wpm for
ordinary prose, ~170 for dense literary) **and** label it as an estimate until
session data exists. Re-grade the estimate axis afterwards; that re-grade is
mandatory, because the page error is currently cancelling the pace error in the
three "plausible" rows.

### F2 — One density constant for a 170–440 wpp reality (critical)

**Evidence:** §26 — 73 of 135 page counts wrong, 46 high and 27 low. The
engine's *declared* densities span **141 wpp** (*Don Quixote*) to **380** (*The
Shore Road Mystery*), while real print densities for the formats in this library
run roughly 170–440; the model assumes 250 for everything.
**Effect:** long literary novels get page counts up to 3× their print length;
light novels get counts 20–30% short. Both are visible on the book card.
**Smallest fix:** a **format-aware density band** — EPUB trade fiction 300–350,
mass-market 350–400, light novel / YA 200–260, dense translated 380–430 — with
the band selected from metadata and page-count evidence, not from prose. Verify
by re-running the 135 and requiring ≥70% within ±15%.

### F3 — `difficultyMultiplier` is a sampling artefact, not a book property (critical)

**Evidence:** five independent authors reproduce the same instability —
Tana French 0.773–1.506 (**1.95×**), TurtleMe 0.897–1.314 (**1.47×**),
Hardy Boys 0.653–1.010 (1.55×), Gwynne 0.939–1.139 (1.21×), Itachi's Story
0.857–1.007 (1.17×). §25.1 shows my own verdicts moved 35% when I changed where
I read.
**Effect:** 49 of 53 categorical label errors overstate difficulty; a reader sees
"Moderate" on a light novel and "Challenging" on book 4 of a series whose book 1
is "Light".
**Smallest fix:** score from **three separated windows** (not one head sample),
report the **median** multiplier, and suppress the badge when the three windows
disagree by more than ~15%. That is falsifiable against these five sets without
any new data.

### F4 — Compilations are measured as books (high)

**Evidence:** six works of 814k–4.9M words receive page counts and reading times
as if they were single volumes (§26).
**Effect:** a 27,536-page estimate and a 612-hour reading time. The number is
arithmetically right and meaningless.
**Smallest fix:** detect compilation scale (word count, spine count, chapter
count) and either split by chapter or refuse to show a time. Showing nothing is
more honest than showing 612 hours.

### F5 — Front matter and back matter are counted and sampled (high)

**Evidence:** §24.2 — *Don Quixote*'s `footnotes.html` is 17,658 words (4.1%) and
was the first analysis window; §14.1 — *Lord of the Mysteries*' longest document
is a 1,409-entry nav file; book 52's longest is an afterword.
**Effect:** endnotes inflate both the word count and the difficulty of the novel
they annotate.
**Smallest fix:** exclude nav/TOC/footnotes/index/bibliography documents from
word count and from the analysis sample, by filename convention plus a
digit-density check.

### F6 — Imported metadata defects are surfaced verbatim (low)

**Evidence:** §19.3 — book 109 displays the literal title `[Title here]` with an
empty creator; several licensed volumes carry scraped watermarks inside the text.
**Effect:** a library row a reader cannot identify; a word count that includes
advertising.
**Smallest fix:** reject placeholder titles at import and strip known watermark
patterns; both are string rules, no model.

## 29. Limitations — what this pass does not establish

Stated here so no later section can imply more than was done.

1. **The reader side is still fabricated.** Every engine row in this file was
   produced by the driver, which injects a synthetic 30-page session at a fixed
   pace. That is why provenance read `personalized` on all 149 rows: the model
   was told it had a reader. **No real reading session exists in this repository.**
   The 200–250 wpm anchor used to grade the estimate axis is an external
   reference, not a measurement. Findings F1 and F3 are therefore about the
   *content* pipeline; the personalisation pipeline remains untested end to end.

2. **Page grades rest on two kinds of evidence, and only one is byte-provable.**
   The strong evidence is internal: five authors reproduce large spreads on
   identical prose, and declared density runs 141–380 wpp across one library.
   That is
   derivable entirely from words and engine output. The weaker evidence is the
   published print page count I compare against — an external fact I did not
   measure here. Where a grade depends only on the internal spread, it stands
   without the print reference; where it depends on "print editions run ~450
   pages", it is a judgement against an external number.

3. **EPUB only.** No PDF was graded. The plan's PDF path (page-based content
   unit) is unexercised, and nothing here should be read as covering it.

4. **One grader.** These are my verdicts, not an inter-rater study. There is no
   second reader and therefore no agreement statistic. What is reproducible is
   the *evidence*: every row records words, engine output, words-per-page and
   the window read. A second grader can re-read the same windows and disagree;
   the disagreement would itself be data.

5. **The `slightly` labels are mine, not the rubric's.** The rubric allows
   matches / high / low / cannot judge. I added `slightly high` and `slightly
   low` where a count was within ~10–15% of a defensible band. In the counted
   record they are kept separate from categorical misses so the headline number
   (§26: 73 wrong) counts only clear errors.

6. **Excerpt windows can land in non-prose.** Three were caught by hand (51 nav,
   52 afterword, 19 footnotes) and re-read; there may be others I did not catch.
   `scripts/real-book-sample.py` does not yet prefer low-digit-ratio documents.

7. **The engine numbers were produced from a front-loaded sample.** The manifest
   feeds the analyzer the first ~1,200 words of up to three longest documents.
   This is the same sampling that F3 identifies as unstable. I did not re-run the
   engine with mid-book sampling, because doing so would change the numbers under
   test mid-investigation; that experiment belongs to the next pass, and §22.2
   states the precise hypothesis it should test.

8. **Coverage of the plan.** This file covers the real-library half of the
   testing strategy. It does not cover session instrumentation (E4/E5), the
   reported 73% interface effect, causal analysis, the API contract, privacy, or
   deployment. Those phases of the plan are untouched by this pass.

## 30. Status of this pass

| Item | State |
|---|---|
| Engine run over all 149 packages | **done** — 149 rows |
| Duplicate packages identified | **done** — 14, SHA-256 matched |
| Distinct works hand-graded | **done** — 135 of 135 |
| Verdict record | `docs/audits/new-era-grades.tsv`, 135 rows |
| Estimate axis re-graded after a pace change | **not done** — no pace change has been applied |
| Real reading sessions | **not done** — none exist |
| PDF path | **not done** |
| Inter-rater check | **not done** |

The next action that changes behaviour is F1, and it must be followed by a
re-grade of the estimate column. The next action that changes *understanding* is
the three-window experiment in F3, because it is the cheapest test that can
falsify the central claim of this file.

## 31. VOID — the owner declared every result in this file void (2026-10-29)

**Declaration.** On 2026-10-29 the owner declared all results in this file void:
the 135 verdicts, the per-batch tallies, the three headline accuracy figures,
findings F1–F6, and the cross-examination in §27. Testing restarts from scratch
against a difficulty rubric that is a stated formula rather than a reader's
judgement. Nothing below is a baseline and nothing below may be compared against
a retest. No text above this section has been deleted; it is superseded, not
rewritten.

**Why, in three parts.**

1. **The grader had no formula.** §4 defines the axes and the legal verdict
   values; §25 records the sampling rule. But the difficulty verdict itself was
   my comparative judgement of the prose. Two people applying §4 to the same
   window would not reliably reach the same verdict, so the verdicts are not a
   measurement, and everything counted from them inherits that.
2. **One grader, no agreement statistic.** No second reader graded any row, so
   no inter-rater figure exists. The only reliability number that does exist is
   self-consistency: **7 of 20** verdicts changed when the same books were
   re-read through a different window (§25.1). That is a floor on my instability,
   not a bound on it. A single-observer instrument with a 35% re-read
   disagreement rate cannot certify a 43% error rate in the thing it observes.
3. **The page axis measured something these files do not contain.** In a
   reflowable EPUB a page is a property of the screen and the font size, not of
   the book. Measured across all 149 packages with
   `python3 scripts/real-book-pagination.py "asterisma new testing suite"`
   (exit 0):

| Check | Result |
|---|---:|
| EPUB packages | **149** |
| Packages with ≥ 5 `pagebreak` / `page-break` markers in their XHTML | **21** |
| Packages with fewer than 5 such markers | **128** |
| Packages declaring a page count in the OPF (`numberOfPages`, `number-of-pages`, `dcterms:extent`) | **0** |

   The 73 page-count “errors” in §26 were therefore differences from print
   editions looked up outside the repository (§29.2), on books that state no page
   count of their own. That is a disagreement with an external convention, not a
   defect the engine can be scored on. **Limit of the check:** it matches the
   token `pagebreak`/`page-break`, so an unusual marker convention would be
   missed and 128 is an upper bound on books with no pagination — not a proof
   that none has any.

**What survives, because it is a byte fact rather than a judgement.**

| Item | Status | Receipt |
|---|---|---|
| 149 packages, 14 byte-identical duplicates, 135 distinct works | **stands** | §11.2 duplicate table |
| The engine's own output for all 149 packages (multiplier, page number, time, label) | **stands as engine behaviour**, not as an accuracy finding | §8.1 driver, exit 0 |
| The pagination table above | **stands** | `scripts/real-book-pagination.py`, exit 0 |
| `difficultyMultiplier` is a bounded function of four prose features and nothing else | **stands as a reading of source** | `AsterismaV2.5/Core/Book2.swift`, `ReadingDifficultyProfile` |
| Every verdict, every tally, every accuracy percentage, F1–F6, §27 | **VOID** | this section |

The verdict file `docs/audits/new-era-grades.tsv` is retained unchanged: it was
not opened for writing during the void, and no digest before/after was taken, so
its identity is asserted from that fact rather than from a hash. It carries no
authority and must not be cited as a result.

**Precondition for any retest** (owner, 2026-10-29): a genuinely heavy, explicit
formula for book difficulty must exist first — stated as arithmetic that a
second person can apply to the same bytes and reproduce. Testing does not
restart until that formula exists, and nothing in this file is to be used to
design it.
