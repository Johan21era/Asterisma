# UI/UX Overhaul — 2026-10-29

**Question:** with regard to the current UI and UX of Asterisma, how can the
layout and the concept be made the best possible for humans?

**Status:** two tranches implemented and compiled; **owner visual acceptance is
pending**. This document is the design record, not a claim that the app has been
usability-tested.

**Receipts at the Stage Z boundary (2026-10-29)**

| Check | Command | Result |
|---|---|---|
| Debug build | `xcodebuild build -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **`, exit 0 |
| Unit census | `./scripts/census.sh --unit-only` | 437 tests / 671 runs / 428 passed / 9 skipped / 0 failed, exit 0 |
| App source size | `find AsterismaV2.5 -name '*.swift' \| wc -l`; concatenated line count; non-blank count | 170 files / 64,084 raw lines / 56,626 non-blank |
| Test folder | `find AsterismaV2.5Tests -name '*.swift' \| wc -l` | 67 files |

> **Superseded 2026-10-31:** the figures below are the 2026-10-29 boundary, not current totals. The current receipt is **515 tests / 99 suites / 719 runs / 506 passed / 9 skipped / 0 failed** (`./scripts/census.sh --unit-only`, exit 0; see `README.md`).
>
> **Later counts (2026-10-29):** the offline contract pass (Stage AB) recorded
> 447 unit tests / 671 runs / 438 passed / 9 skipped / 0 failed, and the ADR-13
> Mirage pass (Stage AE) recorded 459 / 671 / 450 / 9 / 0 in 93 suites. The
> environment/Sentinel/console pass (§9, Stage AH) recorded 464 / 671 / 455 /
> 9 / 0; the Phase Zero boundary was **469 unit tests / 671 runs / 460 passed /
> 9 skipped / 0 failed** (95 suites). After the reading-analytics recalibration
> the boundary at that time was **493 unit tests / 719 runs / 485 passed / 9 skipped /
> 0 failed** (99 suites), adding the reading-analytics `Engines` group, the
> page-estimation model suite and the difficulty-calibration pins. App source is now 179
> Swift files / 67,757 raw lines / 59,942 non-blank; the test folder was 74 Swift
> files. The Stage Z figures above are the receipt for the first UI tranche, not
> the current repository totals.

The 9 skips are the repository's deliberate environment/history skips, not new
UI-test skips. The app was launched once and its window was observed through
`CGWindowListCopyWindowInfo` (1200 × 742). A screenshot could not be captured:
macOS denied the screen-capture request (`screencapture` returned "could not
create image from window/rect"). See [Limits](#limits).

---

## 1. The model

The priority score is a multi-criteria decision analysis, not a substitute for
user testing. Each surface is scored 0–10 on eight dimensions (higher is better;
`U` measures the urgency of the usability debt, so a high `U` is good for
priority). Weights sum to 1.0.

| Symbol | Dimension | Weight | What a high score means |
|---|---|---:|---|
| `T` | Task centrality | 0.18 | The surface is on the path to reading or managing the library |
| `U` | Usability debt | 0.16 | Current friction is large and repeatedly observed |
| `L` | Cognitive-load reduction | 0.14 | A change removes choices, recall, or hidden state |
| `A` | Accessibility / keyboard reach | 0.10 | The change improves focus order, labels, or non-pointer use |
| `C` | Consistency / information architecture | 0.14 | The change removes a duplicate model or a hidden destination |
| `V` | Visual and emotional clarity | 0.10 | The change makes the next action legible at a glance |
| `E` | Engineering leverage | 0.10 | High user value is available for low effort and low risk |
| `X` | Cross-surface compounding | 0.08 | The change improves several screens, not just one |

```text
P(s)  = Σ_i w_i · n_i(s)              raw weighted priority, 0–10
A(s)  = P(s) · (0.6 + 0.4 · q(s))     confidence-adjusted priority
q(s)  ∈ {0.6, 0.7, 0.85, 0.9, 1.0}    evidence quality
L(s)  = A(s) / e(s)                   leverage; e = effort, 1 (small) … 5 (large)
```

`q` is deliberately conservative: 1.0 only when the current code and a repeated
owner finding agree; 0.6 when the judgement is an inference. `L` is a
tie-breaker, not a decision rule. A high-leverage change to a low-consistency
surface can still be the wrong change if the surface should not exist.

### Scores

Scores are expert estimates from the code audit, the existing UX register, and
the platform guidance in §2. They are not measured task times.

| Surface | P | A | L | Decision |
|---|---:|---:|---:|---|
| Shell / navigation | 8.72 | 8.72 | 2.91 | Rebuild |
| Home / launch surface | 8.64 | 8.29 | 4.15 | Build first |
| Library browser | 8.38 | 8.21 | 2.74 | Build first |
| Book detail / dock | 7.32 | 6.88 | 3.44 | Build first |
| Reader | 6.00 | 5.88 | 1.18 | Leave alone |
| Goals | 6.16 | 5.42 | 2.71 | Embed |
| Spatial explorer | 5.54 | 5.32 | 5.32 | Retire the entry point |
| Insights | 5.66 | 4.75 | 2.38 | Embed |
| Settings | 5.14 | 4.32 | 2.16 | Defer |
| Secondary menus / sheets | 4.64 | 3.90 | 1.95 | Defer |

The spatial explorer has the highest leverage only because it is cheap to
remove. Its consistency score is 2/10: it is a second library with a different
mental model, and the app already has a library. High leverage on a duplicate is
an argument for deletion, not investment.

### Weight sensitivity

The ranking was re-computed 20,000 times with every weight multiplied by a
uniform value in `[0.85, 1.15]` and re-normalized. The top three surfaces were
**Shell / navigation, Home, Library in 100% of draws**; their mean ranks were
exactly 1.00, 2.00, and 3.00. The conclusion is stable to ±15% weight
perturbation. The scores themselves remain expert judgement.

---

## 2. Evidence and principles

The model is informed by primary platform and usability guidance:

- Apple HIG, **Sidebars** — durable destinations and collections belong in a
  sidebar; transient filters and item details do not:
  <https://developer.apple.com/design/human-interface-guidelines/sidebars>
- Apple HIG, **Split views** — adjacent panes are appropriate when related
  content should be seen together:
  <https://developer.apple.com/design/human-interface-guidelines/split-views>
- Apple HIG, **Toolbars** — reserve the toolbar for frequent commands,
  navigation, and search:
  <https://developer.apple.com/design/human-interface-guidelines/toolbars>
- NN/g, **Progressive disclosure** — show the common path first and reveal
  advanced or rare actions on request:
  <https://www.nngroup.com/articles/progressive-disclosure/>
- NN/g, **Fitts's law** — frequent targets should be large and close to the task:
  <https://www.nngroup.com/articles/fitts-law/>
- NN/g, **Recognition over recall** — keep recognizable choices visible:
  <https://www.nngroup.com/articles/recognition-and-recall/>
- W3C, **WCAG 2.2 contrast minimum** — 4.5:1 for normal text, 3:1 for large:
  <https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html>
- W3C, **WCAG2ICT** — the bridge for applying WCAG intent to native software:
  <https://www.w3.org/TR/wcag2ict-22/>

The existing project audit independently names the same weak surfaces: sparse
launch canvas, weak selection/detail contract, search discoverability, and a
shelf/grid/resume layout still being a product decision. See
[UX-BETA-AUDIT-2026-10-25.md](UX-BETA-AUDIT-2026-10-25.md), findings
`ASTER-001`, `ASTER-003`, `ASTER-004`, `ASTER-011`, `ASTER-017`, and `ASTER-019`.

---

## 3. Diagnosis

1. **The app opened without a reading task.** The main canvas began with a book
   list and, when nothing was selected, a prompt to select a book. The user had
   to construct the reading task from a management surface.
2. **The library existed twice.** The spatial explorer in
   `AsterismaV2.5/Features/Library/LibraryExplorerView2.swift` is a second
   `NavigationSplitView` with a different presentation and its own filter
   sidebar. Two libraries for one collection is a conceptual cost, not a feature.
3. **Primary destinations were not visible.** Insights and Goals were historically
   reachable through a menu/window/sheet path. A user cannot form a stable map
   of the app when the map is hidden behind an ellipsis.
4. **Selection had no payoff.** A selected book revealed a sparse plate and two
   actions; notes, session count, reading time, last-read date, and the next
   action were not gathered in one place.
5. **The reader is already the strongest surface.** It has a content-first
   layout, appearance controls, exact position persistence, and quiet chrome.
   Rewriting it would spend risk on the one area that does not need it.

---

## 4. Chosen concept: a reading desk, not a dashboard

The shell now has four durable destinations:

| Destination | Human question it answers | Surface |
|---|---|---|
| **Home** | “What am I reading, and what is next?” | Resume hero, live stats, in-progress and next-up shelves |
| **Library** | “Where is that book, and what do I know about it?” | Adaptive grid/list, search, shelf filters, selected-book dock |
| **Insights** | “How is my reading going?” | Existing analytics dashboard, embedded |
| **Goals** | “What am I aiming at?” | Existing goals dashboard, embedded |

Everything else is contextual: discovery, annual reports, recommendations,
achievements, session history, environment/context, import/export, and erase
live in the sidebar's **More** menu rather than competing for top-level space.

### Home

`AsterismaV2.5/Features/Home/ReadingDeskView.swift` is the launch surface.

- One **resume-first hero** for the most recently read in-progress book, or the
  newest unread book. The primary button is **Resume** or **Start reading**.
- Four honest stats: today's pages/time, current streak, books in progress, and
  all-time finished count. Values come from `AnalyticsEngine` and `DataStore`;
  nothing is fabricated or benchmarked from a stale receipt.
- **Also in progress** and **Next up** shelves for recognition over recall.
- An empty state that offers Add Book and Discover without requiring a goal or
  an account.

### Library

`AsterismaV2.5/Features/Library/LibraryBrowserView.swift` replaces the split
between the old sidebar list and the modal spatial explorer.

- Adaptive grid as the default; a list toggle for scanning title/author/progress.
- Search, sort, and shelf filters (`All`, `Reading`, `Unread`, `Finished`,
  `Favorites`) in the library itself.
- A selected-book **dock** with cover, metadata, progress, Open, Info, Estimate,
  notes count, session count, reading time, and last-read date.
- Single click selects; double click opens. The dock's **Open Book** button is a
  second, explicit path, so the interaction does not depend on a double-click.
- Empty and no-match states explain the next action and clear the filters.

### Shell

`AsterismaV2.5/App/NewContentView.swift` owns the custom two-column surface
(the repository deliberately avoids `NavigationSplitView`'s macOS 26 glass
shell; see [fullscreen-surface-audit.md](fullscreen-surface-audit.md)).

- Four navigation rows with ⌘1–⌘4 shortcuts.
- Home adds a compact **Jump back in** list.
- Add Book remains one click away; More retains secondary actions.
- The reader still owns the `NavigationStack` path; its back button, title, and
  toolbar behavior are unchanged.

---

## 5. What shipped

| File | Change |
|---|---|
| `AsterismaV2.5/App/AppSection.swift` | Four durable destinations, icons, shortcuts, purpose text |
| `AsterismaV2.5/Features/Home/ReadingDeskView.swift` | Resume hero, live stats, shelves, empty/caught-up states |
| `AsterismaV2.5/Features/Library/LibraryBrowserView.swift` | Unified grid/list, filters, search, selected-book dock, empty states |
| `AsterismaV2.5/App/NewContentView.swift` | New sidebar shell; embedded Insights/Goals; removed the Explore entry point; responsive header work |
| `AsterismaV2.5/Features/Insights/ReadingInsightsDashboard.swift` | `embedded` flag hides the standalone Done button and minimum size |
| `AsterismaV2.5/Features/Goals/GoalsDashboard.swift` | `embedded` flag hides the standalone Done button and minimum size |
| `AsterismaV2.5/Core/DesignGrid.swift` | Shared workspace, nav, shelf, dock, and grid tokens; adaptive dock floor |
| `AsterismaV2.5/App/CommandPalette.swift` | Quick Open index (pure ranking) and the ⌘K overlay |
| `AsterismaV2.5Tests/App/CommandPaletteTests.swift` | Five tests pin empty-query scope, exact-title rank, all-token matching, subtitle matches, and the result cap |
| `AsterismaV2.5/Features/Home/ReadingDeskView.swift` | Adaptive wide/narrow hero, goal-aware Today card, recently finished shelf |
| `AsterismaV2.5/Features/Library/LibraryBrowserView.swift` | Dock clamped to 236–292 pt, stacked dock actions when compact, ⌘F search focus, filter accessibility values |

Deliberately **not** changed in this tranche: the EPUB/PDF readers, the
appearance system, the data model, persistence, and the Sentinel/recovery
surfaces. The spatial explorer source remains in the tree as an unreferenced
alternative; removing it is a separate cleanup decision, not part of this first
tranche.

> **Postscript (2026-10-29, later session):** a separate reader customization
> pass did change the readers. EPUB gained Paged/Scrolling mode, Both Margins
> Advance, and brightness dimming; PDF gained layout/fit/cover/RTL/page-gap/
> background controls and the same dimmer. The shell model and scores in this
> document are unchanged. Reader record:
> [READER-POLISH-2026-10-25.md](READER-POLISH-2026-10-25.md) Phase 2.

---

## 6. Limits

- **No screenshot or pixel-level visual acceptance.** The macOS screen-capture
  permission was denied, so `screencapture` could not create an image. The app
  was launched and its 1200 × 742 window was observed, but the visual result has
  not been reviewed by the owner.
- **No usability test.** The weighted scores are expert estimates; the
  sensitivity analysis tests the weights, not whether the interface helps real
  readers.
- **No VoiceOver, keyboard-only, or 200% text-size matrix.** Accessibility labels
  and button semantics were added to the new surfaces, but those gates remain
  open. Quick Open's focus and ⌘K behavior are compile-only; the pure index is
  covered by five tests.
- **No remote CI run.** The local build and census are green. The V2.0 rename and
  both UI tranches are uncommitted in the working tree; the last remote run
  predates them.
- **Secondary surfaces still use sheets.** Discovery, reports, recommendations,
  achievements, session history, environment/context, and book details remain
  sheets by design for this tranche. They are now secondary actions rather than
  primary navigation.
- **The old spatial library is still code.** It is no longer reachable from the
  main window, but its files and tests remain. Do not treat it as the primary
  library in future work.

## 7. Second tranche — Quick Open and adaptive geometry (2026-10-29)

The first tranche answered *where things live*. The second asks how they behave
when the window is not the ideal size, and how a keyboard user reaches anything
without hunting through the sidebar.

### 7.1 Quick Open

`CommandPalette.swift` is a pure index over destinations, three quick actions,
and the library, plus a 620 × 430 overlay opened by the sidebar's **Quick open**
button or ⌘K. An empty query deliberately omits books; typing ranks exact title,
title prefix, title token, then subtitle. Every query token must match, so
`ursula le` finds *The Left Hand of Darkness* but `ursula tolkien` returns
nothing. Selecting a result either changes destination, opens the book, starts
import/discovery, or opens Settings. The palette never mutates data.

Why not make the sidebar search do this? Because Library search should stay a
filter over the visible shelf, while Quick Open is a command surface over the
whole app. Keeping them separate avoids a search box whose results depend on
which destination happens to be open.

### 7.2 Adaptive geometry

The window floor is 900 × 640, the sidebar ranges 200–300 pt, and the library
tile is 132 pt with a 22 pt gap. A fixed 292 pt dock therefore leaves 244–344 pt
for the grid depending on the sidebar. The dock now takes about one third of
the canvas, clamped between 236 and 292 pt; below 270 pt its Info/Estimate
actions stack, its cover shrinks to 100 × 142, and its title gets four lines.
The Home hero uses `ViewThatFits`: the wide shape needs 148 + 26 + 380 = 554 pt
of content plus 48 pt padding, so it falls back to the stacked cover/title shape
at the narrowest sidebar configuration rather than squeezing the title.

Layout arithmetic at the 900 pt floor (240 pt sidebar, 64 pt grid padding):

| Dock | Grid content | Grid columns |
|---|---:|---:|
| fixed 292 | 304 pt | 2 |
| adaptive 236 | 360 pt | 2 |

The column count is the same; the adaptive dock buys 56 pt of breathing room,
not a third column. That is the honest benefit, and it is why the model below
scores adaptation but does not claim a density win.

### 7.3 Layout fitness model

This is a second, narrower multi-criteria model for layout alternatives. It is
not a substitute for watching a reader use the app. Weights sum to 1.0; scores
are 0–10 expert estimates anchored to the measured window floor, sidebar range,
dock range, tile size, and the keyboard paths above.

```text
F(l) = 0.20·S + 0.18·F + 0.14·R + 0.14·C + 0.12·A + 0.10·K + 0.07·P + 0.05·E
```

| Symbol | Dimension | Weight | High score means |
|---|---|---:|---|
| `S` | Scanability | 0.20 | The next book and its progress are found quickly |
| `F` | Focus | 0.18 | Reading and the current task dominate the canvas |
| `R` | Reach / motor cost | 0.14 | Frequent actions are close and large |
| `C` | Cognitive load | 0.14 | Few competing panes and mental models |
| `A` | Adaptation | 0.12 | Narrow window, keyboard, and text scale remain usable |
| `K` | Platform consistency | 0.10 | Matches macOS window and control expectations |
| `P` | Layout stability | 0.07 | The surface does not jump when content changes |
| `E` | Engineering safety | 0.05 | Low regression risk for the value delivered |

| Layout | F | Decision |
|---|---:|---|
| Adaptive sidebar + clamped dock + adaptive hero (shipped) | 8.59 | Keep |
| Fixed sidebar + fixed 292 pt dock + horizontal hero | 7.36 | Superseded |
| `NavigationSplitView` + inspector | 7.26 | Rejected for this shell |
| Fixed three-column | 6.05 | Rejected |

With every weight multiplied by a uniform draw in `[0.85, 1.15]` and
re-normalized, the shipped layout ranked first in **20,000 / 20,000 draws**
(100.0%, mean rank 1.000); the fixed layout's mean rank was 2.000. This tests the
weights, not whether the design is right. The scores are judgement, and the next
gate is still a human at both window sizes.

**Receipts (Stage Z boundary):** Debug build exit 0; `./scripts/census.sh
--unit-only` → 437 tests / 671 runs / 428 passed / 9 skipped / 0 failed, exit 0.
The five new palette tests cover the pure index only; the overlay itself has no
recorded UI test. The later reader pass moved the census to 441 / 671 / 432
passed / 9 skipped / 0 failed (Stage AA); the offline pass then moved the current
unit census to 447 / 671 / 438 passed / 9 skipped / 0 failed (Stage AB).

## 8. Next

1. Owner opens the app and validates Home, the adaptive hero, Library, the
dock, Quick Open, and the reader return path at 900 × 640, 900 × 640 with a
300 pt sidebar, and 1200 × 780.
2. Exercise ⌘K, ⌘F, ↑/↓/Return/Escape, and VoiceOver over the four destinations,
the dock, and the palette. The palette's pure ranking is tested; its focus and
keyboard behavior are compile-only until that pass.
3. If accepted, add a notes/highlights destination inside the book dock rather
than increasing modal count.
4. Run the reader acceptance checklist in
   [READER-POLISH-2026-10-25.md](READER-POLISH-2026-10-25.md) Phase 2 on a real
   EPUB and PDF; its panels were not part of the shell tranche.
5. Only then consider deleting the unreferenced spatial-library files.
## 9. Third tranche — environment, Sentinel, and console navigation (2026-10-29)

**Why this tranche:** the owner reported that the background was not live or
flowing, that weather had no visual effect anywhere (including the Developer
Console), that morning and afternoon were too bright to read over, and that
Sentinel and the Developer Console were hard to navigate. This section records
what was actually built; owner visual acceptance is still the gate.

### 9.1 Environment liveness and weather

| Change | Where | Behavior |
|---|---|---|
| Faster palette cadence | `AsterismaV2.5/Features/Environment/Engine/EnvironmentEngine2.swift` | The default recompute interval is 10 s (was 45 s). The palette is still eased on every tick; the shorter tick removes the visible jump between palette keyframes. |
| Continuous atmosphere | `AsterismaV2.5/Features/Environment/Weather/WeatherEffectView.swift` (`LiveAtmosphereView`) | Two large radial glows drift on a 20 fps `TimelineView`, independent of the palette tick; reduced motion freezes them. |
| Real weather layer | `AsterismaV2.5/Features/Environment/Weather/WeatherVisual.swift`, `WeatherEffectView.swift` | A snapshot is classified into clear, cloudy, fog, rain, heavy rain, snow, heavy snow, storm, or wind. Rain/heavy rain/storm draw slanted streaks, snow draws drifting flakes, fog draws banks, wind draws streaks, cloud cover draws a drifting shadow field, and storm adds a deterministic flash. `.clear` draws nothing. |
| Full snapshot carried to the view | `AsterismaV2.5/Features/Environment/Weather/WeatherEnvironmentModifier.swift` | The read-only modifier now carries condition, precipitation, snowfall, visibility, wind, storm index, and capture time from the same recent SQLite snapshot that already drove the cloud-cover nudge. `visual` is derived from those values; a missing condition stays `.clear`. |
| Deepened daytime palettes + veil | `AsterismaV2.5/Features/Environment/Engine/EnvironmentPalette.swift`, `EnvironmentState.swift`, `EnvironmentBackgroundView2.swift` | Morning, midday, and afternoon snapshots use the same reference hues in their shadow range. The engine computes a black readability scrim from gradient luminance, clamped to 0.04…0.42, and the background draws it above the gradient and below content. |
| Studio overrides are Debug-only | `EnvironmentEngine2.swift` (`#if DEBUG`) | A stale studio key cannot repaint a Release launch; in Release the real clock and captured weather are always used. |

The effect layer is deterministic: every streak/flake position is a pure
function of elapsed time and a fixed per-index seed, so the same state renders
the same frame and reduced motion can freeze it rather than disabling it.

### 9.2 Developer Console navigation

- The root sidebar now groups **LIVE** and **PLANNED** panes and has a filter
  field over pane names and phase labels
  (`DeveloperConsoleRootView.swift`).
- **Environment Studio** (`EnvironmentStudioView.swift`) embeds the real
  `EnvironmentBackgroundView` and the real engine. It can force any minute
  (0–1439, presets for dawn/morning/noon/golden/dusk/night) and any weather kind
  with an intensity slider, labels forced vs live values, shows the computed
  clock, anchor blend, luminance, scrim, star visibility, and atmosphere, and
  clears its overrides when the pane disappears.
- **Subsystem Explorer** (`SubsystemExplorerView.swift`) lists every registered
  subsystem with a status dot, filters by category, searches id, display name,
  category, purpose, activity, status, warnings, errors, and metrics, and shows
  a detail pane with purpose, activity, status meaning, metrics, warnings/errors,
  and last update.

### 9.3 Sentinel navigation

`AsterismaV2.5/Features/Sentinel/SentinelHealthCenterView.swift` is now a
`NavigationSplitView`:

- the sidebar always shows the current band, headline, and coverage line, then
  groups Overview/Issues under **Health**, Recovery under **Library**,
  History/Checks under **Records**, and Settings under **Configure**;
- issue and check counts are badges; **Check now** (⌘R) stays pinned at the
  bottom with the last-check time;
- the detail pane has a per-pane title, subtitle, a **Review N issues** shortcut,
  and a **Full check** action;
- Issues adds a search field over title, summary, domain, status, and rule id, a
  severity filter, an `N of M` count, and **Next issue** (⌘]) that cycles the
  filtered set without losing the selection.

### 9.4 Receipts

| Check | Command | Result |
|---|---|---|
| Focused environment tests | `xcodebuild test -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:AsterismaV2.5Tests/EnvironmentWeatherVisualTests` | 5 tests passed, exit 0 |
| Full unit census | `./scripts/census.sh --unit-only` | 464 tests / 94 suites / 671 runs / 455 passed / 9 skipped / 0 failed, exit 0; xcresult `rt-census-20261029-033957.xcresult` |
| Surface manifest | `./scripts/verify-sentinel-surface.sh` | `sentinel-surface: OK — 15 tables, 8 defaults keys, 5 notification names`, exit 0 |
| Index bank | `python3 scripts/comprehension-bench.py --validate-only` | `bank ok: 30 facts, 12 overview facts`, exit 0 |

### 9.5 Limits

- No owner visual acceptance yet, and no screenshot: the macOS screen-capture
  permission was denied in the earlier UI tranche, and this tranche did not
  retry it.
- Live precipitation only appears when a real weather snapshot exists within the
  six-hour lookback. The Environment Studio is the deterministic way to see every
  kind.
- The new Sentinel and console panes were compiled and their shared logic is
  covered by the census, but no UI automation drives the sidebar, search fields,
  or Next issue control.
- The 3D/2D graph views and the remote CI run were not refreshed for this
  tranche.
