# Reading Analytics — Phase Zero Evidence Report

> **Historical baseline and subsequent execution record.** The demo-profile
> generator was revised again on 2026-10-29; §12 describes its current behavior.
> Earlier measurements and implementation descriptions refer to the versions
> used at the time, not the current generator.

- **Date:** 2026-10-29
- **Status:** Phase Zero complete — investigation and baseline only; no production estimator was rewritten.
- **Baseline commit:** `cb92f08` (`main`), plus the uncommitted reader-recovery changes already present in the working tree. `AnalyticsEngine`, `EstimationEngine`, `DemoDataService`, and `LibraryDatabase` are unchanged from `HEAD`.
- **Scope:** `AsterismaV2.5` reader profiling, synthetic demo profiles, page-timing analytics, and `EstimationEngine` output.
- **Roles:** this pass filled every workstream in the supplied plan (audit, synthetic-profile QA, content analysis, measurement, research design, baseline evaluation, production readiness). The owner remains the acceptance authority.

---

## 1. Verdict

The reported "less variation than expected" is **real and reproducible**. It is **not** explained by profiles failing to reach the estimator.

The raw per-book speed calculation is accurate for every persona whose page timings survive the current filter: base speed is **0.93–1.05×** the observed page-timing median. The variation is destroyed after that point by three independent defects:

1. A hard **60-second ceiling** deletes every genuine slow page and substitutes the **120 s/page** global default.
2. The synthetic generator keeps writing full-length sessions into books that are already at their last page, with `pagesRead = 1`. For the affected fast personas it inflates the genre feature from a true ~11–46 s/page to **776–1,250 s/page**; the slow persona is inflated from 341 to 636 s/page.
3. `genreAdjustedReadingSpeed` multiplies an already reader-specific base speed by `genreAverage / 120`, double-counting the reader and injecting the inflated genre value into **25%** of the integrated estimate.

Measured impact on the eight-persona probe:

| Quantity | Observed page-timing median | Current estimator output |
|---|---:|---:|
| Range | 10.90–331.95 s/page | 33.90–245.51 s/page |
| Max/min ratio | **30.45×** | **7.24×** |
| Fast-persona bias | — | **2.39–3.46× too slow** |
| Slow-persona bias | — | **0.74× (too fast)** |

The estimator therefore compresses real differences by roughly fourfold and is biased in opposite directions at the two ends. This is exactly the failure mode the plan warned about: prediction diversity is not prediction accuracy, and here even the diversity is being lost.

No Class B (data-delivery) failure was observed in the demo path. The engine reads the same `Book.sessions` that the generator writes. That does not rule out a production retrieval failure; it was simply not present in this probe.

---

## 2. Reproducible baseline

### 2.1 Probe

`AsterismaV2.5Tests/Engines/ReadingAnalyticsPhaseZeroTests.swift` generates one library per representative persona with a fixed reference date (`2026-10-29T12:00:00Z`), selects a book, and records:

- raw page-timing count, min, median, max, and how many survive the legacy window;
- `AnalyticsEngine.readingSpeed`, `adjustedReadingSpeed`, `effectiveReadingSpeed`, `crossBookReadingSpeed`, `genreAdjustedReadingSpeed`;
- the genre profile's own seconds-per-page and pages;
- the full `SpeedModel` and remaining-time output from `EstimationEngine`;
- the speed that the SQLite summary path would persist;
- a deterministic 50%-progress projection so a non-zero remaining-time path is exercised.

The test makes **no assertion that the current values are correct**. It attaches a JSON trace and prints one compact line per persona.

### 2.2 Command and result

```bash
xcodebuild test -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 \
  -destination 'platform=macOS' \
  -only-testing:AsterismaV2.5Tests/ReadingAnalyticsPhaseZeroProbeTests \
  -resultBundlePath /tmp/phase-zero.xcresult
```

Result: `** TEST SUCCEEDED **`, 1 test, 0 failures, 1.38 s. The console lines reported `PHASE0` medians and effective speeds; the attachment was exported with:

```bash
xcrun xcresulttool export attachments \
  --path /tmp/phase-zero.xcresult --output-path /tmp/phase-zero
```

The preserved artifact is `docs/audits/evidence/reading-analytics-phase-zero-2026-10-29.json`
(SHA-256 `6f34b3dbb86bd49d65606556142b138572daf4e3cb11ad8a41f9026af7e80793`, 459 lines).
It contains eight persona rows. Its `sourceCommand`, `sourceTest`, `commit`, and
`workingTreeNote` fields make the provenance explicit.

### 2.3 Full table

| Persona | Observed median | Base | Genre profile | Genre-adjusted | Integrated estimate | Estimate / observed |
|---|---:|---:|---:|---:|---:|---:|
| Winter Romantic | 36.82 | 36.86 | 776.56 | 238.51 | 88.00 | 2.39× |
| Fantasy Marathoner | 28.05 | 29.39 | 907.45 | 222.23 | 77.05 | 2.75× |
| Night Owl Scholar | 45.48 | 43.70 | 1,121.20 | 408.30 | 135.58 | 2.98× |
| Business Grinder | 30.64 | 30.43 | 865.35 | 219.43 | 77.17 | 2.52× |
| Speed Demon | 10.90 | 11.14 | 1,250.49 | 116.11 | 37.72 | 3.46× |
| Slow Savorer | 331.95 | 120.00 | 636.44 | 636.44 | 245.51 | 0.74× |
| Commuter Snacker | 29.80 | 27.69 | 253.57 | 58.50 | 33.90 | 1.14× |
| One-Book Wonder | 34.38 | 35.09 | 886.06 | 259.06 | 91.24 | 2.65× |

All values are seconds per page. "Observed median" is the median of the generated
`PageTiming.duration` values for the selected book. The JSON also contains the
min/max, the count inside `0.5 < duration < 60`, the count dropped by that window,
the number of one-page sessions, and the 50%-projection remaining hours.

---

## 3. Current pipeline, as built

The code path is not word-count based. It is page-duration based:

```
Book.sessions[].pageTimes[].duration
  → AnalyticsEngine.readingSpeed(for:)                 // per-book robust-ish mean
  → × difficultyProfile.difficultyMultiplier           // adjustedReadingSpeed
  → AnalyticsEngine.genreAdjustedReadingSpeed(for:books:)
  → AnalyticsEngine.crossBookReadingSpeed(allBooks:)
  → AnalyticsEngine.trendAnalysis(books:)
  → EstimationEngine.buildSpeedModel(...)              // fixed 40/25/20/15 weights
  → remainingPages × effectiveSpeed
```

| Stage | Source | What it actually uses |
|---|---|---|
| Raw timing | `AsterismaV2.5/Core/DataStore3.swift#L789-L807` | Wall-clock `Date()` between page turns; previous timing closed at the new turn. |
| Session close | `AsterismaV2.5/Core/DataStore3.swift#L850-L872` | `endTime = Date()` on normal close; crash recovery clamps to last activity + 300 s. |
| Per-book speed | `AsterismaV2.5/Engines/AnalyticsEngine.swift#L33-L54` | Page timings only; `0.5 < duration < 60`; median, then `median/2`–`2×median` and `≥ 5 s`; arithmetic mean. |
| Difficulty | `AsterismaV2.5/Engines/AnalyticsEngine.swift#L56-L60` | Multiplies the per-book speed by `ReadingDifficultyProfile.difficultyMultiplier`; missing profile = 1.0. |
| Genre profile | `AsterismaV2.5/Engines/AnalyticsEngine.swift#L823-L844` | Session `duration / pagesRead`, not page timings. |
| Genre adjustment | `AsterismaV2.5/Engines/AnalyticsEngine.swift#L847-L855` | `base × (genreAverageSecondsPerPage / 120)`. |
| Cross-book speed | `AsterismaV2.5/Engines/AnalyticsEngine.swift#L81-L98` | Same 60-second window over every book. |
| Integrated model | `AsterismaV2.5/Engines/EstimationEngine.swift#L89-L155`, `#L171-L214` | 40% base, 25% genre, 20% trend, 15% cross; remaining pages = `totalPages - 1 - currentPage`. |
| Output | `AsterismaV2.5/Engines/EstimationEngine.swift#L65-L82` | No status, no fallback reason, no model version, no uncertainty. |

There is no separate reader-profile entity in this path. A "profile" is the set of
sessions attached to the library's books. That is why changing the demo persona
changes the estimates: it changes the page timings.

---

## 4. Confirmed findings

### P0-1 — The 60-second ceiling deletes slow readers (Class C: feature construction)

**Code:** `AsterismaV2.5/Engines/AnalyticsEngine.swift#L33-L45` and
`#L81-L89`.

The first filter is `0.5 < duration < 60`. Any page that took longer than a
minute is discarded before the median is computed. If every page in a book is
slow, the timing list is empty and the function returns
`AnalyticsConstants.defaultSecondsPerPage` (**120 s/page**,
`AsterismaV2.5/Engines/AnalyticsEngine.swift#L391-L396`).

**Evidence (Slow Savorer):**

- 209 page timings in the preserved probe book.
- Minimum 258.80 s, median **331.95 s**, maximum 440.49 s.
- Inside the legacy window: **0**; dropped: **209**.
- Base speed: **120.00 s/page** — the global default, 2.77× faster than the
  reader actually is.
- Persisted summary speed: **120.00 s/page**.

**Evidence (Night Owl Scholar):**

- 20,734 timings; 2,633 (12.7%) are above 60 s.
- Base 43.70 s/page vs median 45.48 s/page (0.96×).
- The surviving majority hides the systematic loss; the 12.7% deletion is still
  a measurement-policy defect even when the average happens to look close.

**Consequence:** every reader slower than 60 s/page is silently replaced by the
global default. The app cannot represent a genuinely slow reader, a dense
technical page, a manga page with heavy visual narrative, or a PDF with little
text. The 60 s ceiling was presumably intended to reject idle time, but it
rejects the reader instead.

### P0-2 — The synthetic generator writes sessions into finished books (Class A: data generation)

**Code:** `AsterismaV2.5/Features/Discovery/DemoDataService.swift#L404-L431` and
`#L463-L469`.

Three related faults:

1. `remainingPages = max(1, totalPages - accumulatedPages)` forces a remaining
   page count of at least one even after the book is finished.
2. `pagesRead = min(remainingPages, max(1, Int(seconds / secPerPage)))` therefore
   records at least one page per later session, while the session still keeps its
   full 35–360 minute duration.
3. `isCompleted` is set only from the catalog's `completed` flag, never from
   `furthest >= totalPages`. A book at its last page therefore reports
   `isCompleted == false` and 100% progress.

**Evidence in the preserved JSON:**

- 6 of 8 selected books are at their last valid page while
  `isCompleted == false`: 411/412, 879/880, 263/264, 309/310, 419/420,
  1419/1420.
- Sessions read more pages than the book contains: 538 pages read for a 412-page
  book, 1,005 for 880, 614 for 420, 1,748 for 1,420.
- One-page sessions per selected book: 125–328 (Winter 126, Fantasy 125,
  Night Owl 197, Business 225, Speed Demon 194, One-Book Wonder 328).
- The genre profile therefore divides a full session duration by one page:
  Winter **776.56 s/page** vs a timing mean of **35.9 s/page**; Speed Demon
  **1,250.49** vs **11.2**; Slow Savorer **636.44** vs **341.1**.

**Consequence:** the demo personas do not represent believable libraries. The
genre feature is measuring "remaining session duration ÷ one page", not the
genre's reading pace. Any conclusion drawn from these profiles about genre
personalization is invalid until the generator is corrected.

### P0-3 — Genre adjustment double-counts the reader (Class C/D: feature construction and estimation)

**Code:** `AsterismaV2.5/Engines/AnalyticsEngine.swift#L847-L855`.

```swift
let base = adjustedReadingSpeed(for: book)          // already this reader's pace
let profile = profiles[genre]
let genreMultiplier = profile.averageSecondsPerPage / 120
return base * genreMultiplier
```

`base` already contains the reader and the book. Multiplying it by
`genreAverage / 120` applies the genre again, and the 120 constant has no
relationship to the reader. The results are not adjustments; they are
multiplicative distortions.

**Evidence:**

- Winter: 36.86 × (776.56 / 120) = **238.51** s/page.
- Speed Demon: 11.14 × (1,250.49 / 120) = **116.11** s/page (10.4× the base).
- Slow Savorer: 120.00 × (636.44 / 120) = **636.44** s/page.

`EstimationEngine` gives this component a 25% weight
(`AsterismaV2.5/Engines/EstimationEngine.swift#L188-L202`), so the error cannot
stay local. The integrated estimate is 2.39–3.46× the observed median for the
fast personas and 0.74× for the slow persona. That is the compression in one
table.

The same builder also records `trendAdjustedSpeed: base * trendMultiplier` but
uses `cross * trendMultiplier` in the effective calculation
(`AsterismaV2.5/Engines/EstimationEngine.swift#L178-L209`). The displayed
component and the used component are not the same number. This is a secondary
consistency defect, not the primary cause.

### P0-4 — The test suite does not measure predictive accuracy (Class E: evaluation)

**Evidence from the test tree:**

- `AsterismaV2.5Tests/DeveloperConsole/DemoProfileServiceTests.swift` verifies
  catalog shape, validator cleanliness, persona signatures, and determinism.
  It does not assert an estimate.
- `AsterismaV2.5Tests/Core/SQLiteDataStoreTests.swift#L128-L133` and
  `#L272-L290` assert that JSON and SQLite produce the same reading speed. That
  is storage equivalence, not accuracy.
- `AsterismaV2.5Tests/App/BedrockBaselineTests.swift#L57-L60` calls
  `EstimationEngine.validate(estimate(...))` only to measure elapsed
  milliseconds.
- `DemoProfileServiceTests` pins persona behavior, not reader-time error.

No test compares a predicted remaining time with an observed outcome, reports
bias, or checks calibration. The current suite can be fully green while every
estimate is wrong. That is the exact "software correctness versus model quality"
separation the plan requires.

### P0-5 — Reading time is wall-clock page delta, with no attention policy (Class D/E: measurement)

**Code:** `AsterismaV2.5/Core/DataStore3.swift#L789-L807` and `#L850-L872`.

- `recordPageTurn` closes the previous timing at `Date()` and opens the next.
- A page left open for ten minutes is recorded as ten minutes of reading.
- The only automatic close outside the reader is `scenePhase == .background`
  (`AsterismaV2.5/App/AsterismaApp.swift#L161-L164`); the readers also close on
  `.onDisappear` (`AsterismaV2.5/Features/Reader/EPUBReaderScreen.swift#L103-L112`,
  `AsterismaV2.5/Features/Reader/PDFReaderView2.swift#L473-L477`).
- No `.inactive`/focus-loss handler, visibility event, monotonic clock, or
  per-event validity flag is present. `PageTiming` carries only page number,
  start, and end (`AsterismaV2.5/Core/Book2.swift#L489-L500`).

This is why the 60-second ceiling exists: it is a crude proxy for "the page was
idle". It cannot distinguish a slow reader from an idle reader, so it fails both
ways. The measurement policy must be decided before the filter is changed; a
one-line ceiling removal without an attention policy would count idle time as
reading.

### P0-6 — EPUB and PDF do not share a content unit (Class C/D: content features)

**Code:**

- EPUB: `totalPages = max(1, wordCount / 250)`
  (`AsterismaV2.5/Features/Library/BookImporter.swift#L274-L275`);
  `wordCountEstimate: wordCount` is stored (`#L307-L318`).
- PDF: `totalPages = doc.pageCount`
  (`AsterismaV2.5/Features/Library/BookImporter.swift#L140`);
  the `Book` initializer receives no `wordCountEstimate`,
  `difficultyProfile`, or `genre` (`#L182-L190`).
- `PageEstimationModel.estimatePages` exists at
  `AsterismaV2.5/Features/Library/BookImporter.swift#L774-L786` but has no
  caller: the repo-wide reference search found only its definition. The live
  EPUB path uses the simpler `wordCount / 250` and ignores the difficulty
  profile it just computed.

**Consequence:** a 300-page PDF and a 300-page EPUB are not the same content
quantity. A PDF page may contain a diagram with 20 words or 800 words; the
current estimator cannot tell. PDFs also have no content features at all, so
their estimates are pure page-duration extrapolation. Cross-format model
comparison is invalid until the content unit is normalized or the formats are
evaluated separately.

### P0-7 — Estimates have no status, provenance, or fallback disclosure (Class D/observability)

**Code:** `BookEstimationResult` at
`AsterismaV2.5/Engines/EstimationEngine.swift#L65-L82` contains only numbers and
the speed model. It has no `status`, `fallbackReason`, `modelVersion`,
`featureVersion`, or `predictionTarget`. `estimate(for:allBooks:)` never calls
`validate(result:)`; the only caller of `validate` found in the repository is
`AsterismaV2.5Tests/App/BedrockBaselineTests.swift#L57-L60`.

`LibraryDatabase.summary(of:)` caches
`AnalyticsEngine.readingSpeed(for: book)` before replacing `sessions` with
summary copies (`AsterismaV2.5/Core/Storage/LibraryDatabase.swift#L328-L333`). The probe
simulates that path and gets **120.0 s/page** for the Slow Savorer. The default
is therefore not a transient fallback; it is persisted and indistinguishable
from a measured value.

This violates the plan's Rule 8 (no silent fallbacks). A user cannot tell whether
"2h 15m" came from their own history, a cross-book average, or the 120 s/page
constant.

### P0-8 — The 73% interface claim has no evidence record in this repository

A repository-wide case-insensitive search for `73%`, `continuous scroll`,
`page-by-page`, and `manga` found:

- reader layout documentation and settings (`docs/design/READER-POLISH-2026-10-25.md`,
  `AsterismaV2.5/Features/Reader/PDFReaderSettings.swift`);
- no session record, log, measurement note, or experiment file containing a 73%
  comparison;
- no code that computes a layout-specific speed effect.

The claim is therefore **unverified**. It is neither accepted nor rejected. It
must be reconstructed from the original sessions, or replaced by a controlled
crossover study with active-time and comprehension measures. A 42% time
reduction and a 72.4% speed increase are not the same number for the same data
(`docs` plan §6.4); the original numerator, denominator, and measurement policy
must be recovered.

---

## 5. Failure classification

| Class | Status | Evidence |
|---|---|---|
| **A — data generation** | **Confirmed** | P0-2: post-completion sessions, one-page denominators, 100% progress with `isCompleted == false`. |
| **B — data delivery** | **Not observed** | The probe reads the same `Book.sessions` the generator writes. No separate profile store exists to fail. Production retrieval was not exercised. |
| **C — feature construction** | **Confirmed** | P0-1 (60 s ceiling), P0-3 (genre multiplier), P0-6 (format-inconsistent content unit). |
| **D — estimation** | **Confirmed** | P0-3 and P0-7: integrated estimate is 2.39–3.46× observed for fast personas, 0.74× for the slow persona; output has no status/provenance. |
| **E — evaluation** | **Confirmed** | P0-4: no accuracy, bias, or calibration test; only storage equality and elapsed-time benchmarks. |

Multiple classes are present simultaneously. Fixing only the model would leave
the generator and evaluation defects in place; fixing only the generator would
leave the 60-second filter and genre formula in place.

---

## 6. What is not a defect

**Reading hours do not predict reading speed.** The plan is right that total
hours are not a speed measure. The demo personas differ by hundreds of hours,
but the estimator never uses `totalReadingTime` for speed; it uses page timings.
A test that expects a 1,000-hour persona to receive a different speed solely
because of the hours is testing the wrong quantity. The valid comparison is
same-content, same-interface page timing.

**The per-book speed calculation is sound for timings it can see.** For the
seven personas with timings inside 0.5–60 s, base/median ratios are 0.93–1.05.
The mean-after-median-filter is doing its job. The failure is what it is allowed
to see, not the arithmetic.

**The demo profiles are deterministic.** `DemoProfileServiceTests` pins
determinism and the probe uses a fixed reference date. Repeated runs produced the
same structure; the values above are stable enough to compare across a fix.

---

## 7. Phase 1 experiments and decision rules

These are the next actions, in order. No production model change should precede
E1 and E2.

### E1 — Correct the synthetic generator (isolated, DEBUG-only)

**Owner:** synthetic-profile QA.

**Change:** stop adding sessions to a book once `accumulatedPages >= totalPages`;
choose another incomplete book for that day's session instead of forcing a
one-page session; set `isCompleted = true` when `furthest >= totalPages`, not
only when the catalog flag says so; never let `pagesRead` exceed remaining
pages.

**Acceptance:**

- No book has `sum(session.pagesRead) > totalPages`.
- No book at `totalPages - 1` has `isCompleted == false`.
- No session has `pagesRead == 1` unless the book genuinely had one page left.
- `DemoProfileServiceTests` still passes (catalog shape, signatures,
  determinism, validator cleanliness).
- Re-run the Phase Zero probe and record the new genre profile / timing mean
  ratio; it should be close to 1.0, not 20–100×.

**Decision rule:** if the regenerated profile breaks a persona signature, the
persona's catalog is wrong, not the completion rule. Fix the persona, do not
reintroduce phantom sessions.

### E2 — Replace the absolute 60-second ceiling with a documented robust policy

**Owner:** measurement / analytics engineering.

**Candidates to evaluate, not assume:**

- **R1:** per-book median filter with a relative upper bound (for example
  `5 s ≤ duration ≤ 3 × median`), no absolute 60 s ceiling.
- **R2:** explicit active/inactive events (visibility, focus, monotonic clock),
  with page timings only accumulated while active.

**Acceptance:**

- A synthetic slow reader at 240–420 s/page is not replaced by 120 s/page.
- A 10-minute idle page is excluded or flagged, not counted as reading.
- Real library sessions with valid long pages are not silently deleted.
- The same policy is used by `readingSpeed`, `crossBookReadingSpeed`, and
  `genreProfiles`.
- A test pins both directions: slow page retained, idle page rejected.

**Decision rule:** if R1 cannot separate slow reading from idle time without
unacceptable loss, adopt R2. Do not tune the ceiling to make the demo look good.

### E3 — Baseline and ablation on real observations

**Owner:** ML / data science.

Compare, on reader-held-out and future-time splits:

- **A:** robust per-book page speed only (no genre, no trend, no cross-book
  blend).
- **B:** A + genre, with a corrected denominator and a shrinkage formula.
- **C:** B + cross-book cold-start.
- **D:** C + trend/context.

**Metrics:** MAE, median absolute error, mean signed error (bias), interval
coverage if intervals are added, and error by reader-history level and content
format. Report sample sizes and uncertainty; do not call a difference real from
eight demo personas.

**Decision rule:** keep a component only if it improves held-out MAE or bias by
a predeclared meaningful margin. If genre does not beat A, remove it from the
estimate rather than keeping it because the plan mentions it.

### E4 — Measure attention explicitly

**Owner:** analytics instrumentation.

Add visibility/focus events and a monotonic elapsed clock to the session event
model. Define active reading time as time with the reader visible, the app
active, and a documented interaction policy. Store event validity/quality flags
so a future policy change can be applied without losing the raw record.

**Acceptance:** a 10-minute page with the app hidden is not active time; a
5-minute page with the app visible and the reader progressing is active time.
Test both.

### E5 — Recover or replace the 73% claim

**Owner:** research lead.

Retrieve the original session records if they exist. If they do not, run a
counterbalanced crossover with comparable content, both layouts, active-time
instrumentation, and a predefined comprehension measure. Report time reduction
and speed increase separately. Do not present an observational association as a
causal layout effect.

### E6 — Add estimate provenance and fallback status

**Owner:** platform / reliability.

Extend `BookEstimationResult` with a prediction target, model/feature version,
input-quality status, and an explicit fallback reason. Make the UI distinguish
"personalized", "cross-book baseline", "global default", and "partial content".
Persist the same status with the prediction record.

### E7 — Normalize content features across formats

**Owner:** content engineering.

Give PDFs a content-quality record (text extraction status, sampled word count,
page count, OCR/extraction flags) or explicitly declare PDF estimates
page-only and do not compare them with EPUB estimates. Remove or wire the dead
`PageEstimationModel`; do not keep two page estimators with different behavior.

---

## 8. Definition of done for Phase Zero

Phase Zero is complete for this pass because:

- [x] The current estimation functions and the profile-to-output path are mapped.
- [x] A reproducible probe and a preserved JSON baseline exist.
- [x] The profile-sensitivity issue is reproduced with exact inputs and outputs.
- [x] Classes A, C, D, and E failures are confirmed; B is not observed.
- [x] Defaults, fallbacks, caching, and the absence of provenance are documented.
- [x] The synthetic generator's assumptions and defects are documented.
- [x] The test suite's accuracy gap is documented.
- [x] The reading-time measurement policy is documented.
- [x] The 73% claim is classified as unverified, with a recovery plan.
- [x] The next experiments have acceptance criteria and decision rules.

It is **not** complete as a product fix. No production estimator behavior was
changed in this pass. E1–E3 must run before a model replacement is proposed.

---

## 9. Artifact manifest and verification

| Artifact | Path | SHA-256 | Size |
|---|---|---|---:|
| Phase Zero probe test | `AsterismaV2.5Tests/Engines/ReadingAnalyticsPhaseZeroTests.swift` | `c5cf83292792f089c1be1d54cbcb899af73293fd1e6b25483cea745fbb536349` | 252 lines |
| Phase Zero JSON trace | `docs/audits/evidence/reading-analytics-phase-zero-2026-10-29.json` | `6f34b3dbb86bd49d65606556142b138572daf4e3cb11ad8a41f9026af7e80793` | 459 lines, 17,599 B |

**Commands run:**

```bash
git rev-parse HEAD
# exit 0; cb92f08...

xcodebuild test -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 \
  -destination 'platform=macOS' \
  -only-testing:AsterismaV2.5Tests/ReadingAnalyticsPhaseZeroProbeTests \
  -resultBundlePath /tmp/phase-zero.xcresult
# exit 0; ** TEST SUCCEEDED ** — 1 test, 0 failures, 1.38 s

xcrun xcresulttool export attachments \
  --path /tmp/phase-zero.xcresult --output-path /tmp/phase-zero
# exit 0; Exported 1 attachment; manifest.json written

./scripts/census.sh --unit-only
# exit 0; ** TEST SUCCEEDED **
# 469 tests / 671 runs / 460 passed / 9 skipped / 0 failed
# xcresult rt-census-20261029-183222.xcresult
```

**Skipped, with reasons:**

| Check | Reason |
|---|---|
| App launch / UI inspection | No production engine changed in this pass. The probe is a unit-level evidence capture; starting the app would not exercise a different path. |
| Real user library inspection | The owner's library was not read. It contains personal reading history; this pass used generated profiles only. |
| Original 73% session records | Not present in the repository. Needs owner/research recovery; see P0-8 and E5. |
| Remote CI | No commit or push was made. The local focused test and the local unit census are the only executed receipts. |

---

## 10. Immediate recommendation

Proceed with **E1 first**, because it is DEBUG-only and removes a source of
false evidence without touching production estimates. Then run **E2** as a
separate, measured change. Do not tune `genreAdjustedReadingSpeed` or the
40/25/20/15 weights until E1 and E2 produce a clean baseline; otherwise the
next measurement will be another mix of generator, measurement, and model
effects.

The owner decision needed before E2 is the definition of active reading time:
should a long page with the app visible count as reading, and how should an
idle page be detected? That is a product/measurement decision, not a coding
preference. Until it is answered, the 60-second ceiling should be treated as a
known defect, not as a tunable parameter.

---

## 11. Phase 1 execution (2026-10-29, same session)

E1, E2, E3, E6, and E7 were executed after this report. E4 and E5 were not.

| Step | Change | Receipt |
|---|---|---|
| E1 | Finished books no longer receive phantom one-page sessions; the next session is a re-read pass from page 0; `isCompleted` follows the furthest page | `DemoProfileServiceTests` 8/8 pass; genre/mean ratio 21.6× → 1.01–1.57×; one-page sessions 125–328 → 0–2 per book, all genuine last pages |
| E2 | `PageDurationPolicy` (0.5 s floor, 3× median relative ceiling) replaces every `0.5 < d < 60` filter in `readingSpeed`, `crossBookReadingSpeed`, and `AnnualReportData2` | `PageDurationPolicyTests` 8/8; base/median 0.99–1.04, 0 timings dropped; slow persona 339.64 s/page vs 331.75 s median (was 120.00) |
| E3 | Ablation: A (own speed) MAE 2.0%, B (+genre) 12.5%, D (old blend) 4.8%; `buildSpeedModel` now returns the own speed, cross-book only as cold start; genre formula is a relative, shrunk diagnostic | `EstimationProvenanceTests` and probe; shipped estimate 0.99–1.04× observed on all eight personas (was 0.74–3.46×) |
| E6 | `EstimationStatus`, `fallbackReason`, `modelVersion`, `predictionTarget` on every result; estimate screen discloses fallbacks | `EstimationProvenanceTests` 5/5; `NewContentView` accessibility id `estimationProvenance` |
| E7 | `PageEstimationModel` is the single conversion (words × difficulty ÷ 250), EPUB uses it instead of a bare `/250`, PDFs gain a sampled word count and difficulty profile | `PageEstimationModelTests` 5/5; `PDFTextSampler` bounded to 24 pages / 60,000 characters |
| E4 | Not done: no visibility/focus events, no monotonic elapsed clock, no per-event validity flags | — |
| E5 | Not done: the 73% claim still has no session record | — |

Full unit census: `./scripts/census.sh --unit-only`, exit 0,
`✔ Test run with 489 tests in 98 suites passed`; xcresult
`rt-census-20261029-184647.xcresult` metadata `719 test runs`,
`failedTests: 0`, `skippedTests: 9`, `passedTests: 481`.

Phase 1 probe artifact: `docs/audits/evidence/reading-analytics-phase-one-2026-10-29.json`
(SHA-256 `72ec093e7d54025b2161fd75051b7b9103399d8fe060b0b6292b4ff2be9eb63a`,
534 lines, 19,904 B).

**Residual defects, unchanged:** a very slow reader's own idle page is still
indistinguishable from slow reading without E4 instrumentation; PDF remains a
page-count content unit even though it now has a word estimate; the trend
component is retained as a diagnostic but no longer affects the estimate.

**Real-library pass:** see `docs/audits/new-era-testing.md`. Nothing there is
graded yet. *(Superseded 2026-10-29: grading was subsequently completed and then
declared **void** by the owner; that file's §31 records the declaration and the
surviving byte evidence. This sentence is left in place as the historical claim
it was.)*

## 12. Demo-profile audit and revision (2026-10-29)

The earlier generator assigned a whole planned session to a book even when it
ran out of pages, repeated its final page timing to fill the time, and could
fabricate a fallback session for a book with no generated history. The declared
catalog hours sized the simulated history but did not guarantee actual hours
per book. The abandoner, comeback, and seasonal descriptions were not all
implemented as behaviors. Profile descriptions also disagreed with some pace
ranges. See `AsterismaV2.5/Features/Discovery/DemoDataService.swift`.

The revised generator stops timing a session at the simulated ending page;
page numbers and session endpoints match the app's recorded page-position
convention in `AsterismaV2.5/Core/DataStore3.swift`. It varies time per page,
occasionally stops early, revisits a page, or jumps forward between sessions;
skipped pages have no invented timings. It includes a quiet period for the
comeback profile, limits abandoned-book progress, and chooses seasonal genres
when available. Book completion now follows simulated progress. Rereading is
possible but not automatic for every finished book. The console labels its
catalog inputs as sizing information rather than actual recorded hours.

These are hand-chosen scenarios, not measured frequencies. They exercise
analytics and data-handling cases, but do not establish real-reader behavior or
prediction accuracy. The generator does not model true active versus idle time,
multiple daily sessions, or actual book text; its word count is an estimate.
The separate experimental CDE reader model is not fed by these demo profiles.
The app's session format has no explicit pause or skip flag; short sessions,
backward page turns, and gaps between session positions only approximate those
behaviors.

The Swift profile checks cover page and time consistency, chronological
sessions, interruptions, revisits, jumps, abandonment, and the comeback break:
`AsterismaV2.5Tests/DeveloperConsole/DemoProfileServiceTests.swift`. These are
synthetic behavior checks, not tests against human reading sessions.
