# Reader & Library Polish — 2026-10-25

**Status:** Phase 1 implemented; Phase 2 (reader customization) implemented 2026-10-29; owner retest pending on a real book
**Phase 2 tree:** V2.0 working tree, uncommitted; no release package
**Ready build (Phase 1, historical):** app code `1c88ae5` · tag `asterisma-v1.0-ready-2026-10-26`
**Ready package:** `dist/AsterismaV1.0-1.0-arm64.zip` · SHA-256 `786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`
**Historical candidate:** `3bff002` · tag `asterisma-v1.0-polish-1` · SHA-256 `a8ebf2ec1efd0b3513dd59a04a1efb8a830aefb2007b32632539906ba0517009` (superseded for retest; reader behavior unchanged)
**Benchmark:** Apple Books on macOS, plus Apple's public Books user guide

## What Apple Books exposes

Apple's Mac guide and current Books builds make the reading surface tunable:

- Six page themes: Original, Quiet, Paper, Bold, Calm, Focus.
- Font size with A-/A+ and reset.
- Font family, including Original and several serif/sans options.
- Bold text.
- Line spacing, character spacing, word spacing, and margins.
- Justify Text on/off.
- Allow Multiple Columns on/off (one or two pages).
- Light / Dark / Automatic page background.
- Auto-hyphenation.
- Page-turn style (Curl, Fast Fade, Scroll) and scrolling view on iOS.
- Page brightness dimming that leaves the controls legible.
- Both Margins Advance (either edge goes forward).
- Reading controls that recede so the page owns the screen.

Primary references:

- https://support.apple.com/guide/books/change-a-books-appearance-ibks8923126d/mac
- https://support.apple.com/guide/iphone/read-books-iphc1af7c57/ios

## What MangaDex exposes

MangaDex forum guidance documents page-fit choices (no limit, fit width, fit
height, fit both) and single/double-page modes. The official help page was not
retrievable during this pass, so right-to-left direction, page gap, background,
and brightness are recorded as **MangaDex-adjacent native controls**, not as
verified MangaDex settings. The PDF panel implements them because PDFKit itself
supports the presentation model; it does not claim to be a MangaDex clone.

Sources:

- https://forums.mangadex.org/threads/how-to-make-pages-bigger.2235276/
- https://forums.mangadex.org/threads/double-page-view-settings-where.1893042/

## Phase 1 shipped

### Appearance panel

- Six Asterisma theme presets, each with its own page palette and typography
  starting point.
- Theme tiles with live `Aa` previews and a selected ring.
- Font menu: Original, New York, Georgia, Palatino, Charter, Iowan Old Style,
  Athelas, Avenir Next, Seravek, San Francisco, Times New Roman.
- Bold Text toggle.
- Text size A-/A+ plus slider, 80–200%.
- Line spacing, character spacing, word spacing, and margin sliders.
- Justify Text toggle.
- Columns: Auto / One / Two, with narrow-window fallback.
- Hyphenate toggle.
- Page turn: Slide / Fade / Instant.
- Show Page Numbers toggle.
- Reset Theme restores the active theme's typography and layout; text size is
  intentionally preserved.

### Reader chrome

- Top and bottom capsules now follow the page theme instead of always using a
  black pill with white text.
- Persistent chrome remains auto-hiding on the top-left.
- Page-number capsule can be hidden entirely.
- Edge clicks turn pages; this is implemented inside the document so trackpad
  scrolling and links keep working.
- Page turns animate with a short eased slide or a fast fade; instant remains
  available.

### Library polish

- Selected-book detail is now a horizontal book plate with a large cover,
  serif title, metadata pills, progress bar, and paired primary actions.
- Sidebar rows drop the boxed format badge and use a quieter metadata line with
  progress percentage.

## Phase 2 implemented — reader customization (2026-10-29)

### EPUB

- **Paged / Scrolling** mode. Paged keeps the CSS-column spread model; Scrolling
  switches the same chapter to a vertical flow without reloading the document.
  Switching back restores the current page.
- **Brightness 35–100%** as a non-interactive black veil over the page only;
  the controls remain at full brightness. macOS does not let a normal app
  change display brightness without private APIs, so page dimming is the honest
  Apple Books-equivalent behavior.
- **Both Margins Advance**, persisted independently of page-turn style.
- Every control writes through `@AppStorage`; the chapter's WKWebView receives a
  new `settingsJSON` and calls `window.__epubApplySettings` in place. There is no
  page reload and no chapter reopen.

### PDF

- **Layout:** Single, Continuous, Facing, Facing + Scroll.
- **Fit:** Fit Page, Fit Width, Fit Height, Actual Size (`PDFFitMode`).
- **Reading direction:** Left to Right / Right to Left, mapped to PDFKit's
  `displaysRTL`; page order really changes, while page numbers and resume
  positions keep their PDF page indices.
- **Cover Alone:** mapped to PDFKit's `displaysAsBook` for facing layouts.
- **Page Gap:** 0–80 pt, mapped to `pageBreakMargins`; clamped by
  `PDFReaderSettings.clampedPageGap`.
- **Page Background:** System, Paper, Slate.
- **Brightness:** the same page-only dimmer as EPUB.
- Layout, fit, gap, cover, direction, and background are applied in
  `updateNSView` without reopening the document. The active page is preserved.
- Fonts, font size, and spacing are deliberately absent from the PDF panel: a
  PDF carries its own typography and cannot be reflowed without changing the
  document.

## Deliberately still open

- Highlights, notes anchored to text, bookmarks, and in-book search.
- Page-curl animation.
- Per-theme customizations remembered separately.
- Whole-book physical page map.
- Full VoiceOver/focus audit of the Appearance panels, edge clicks, and the new
  Scrolling mode.
- PDF text reflow or publisher-font override (not possible without document
  conversion; the panel says so).
- A real-book visual pass by the owner, plus a keyboard-only pass at the 900 × 640
  window floor.

## Owner acceptance checklist

### EPUB

1. Open an EPUB and open Appearance from the `Aa` button.
2. Switch through all six themes; page colors and chrome should update live.
3. Change font, size, bold, spacing, and margins; text should reflow.
4. Toggle Justify and One/Two columns; page count should update honestly.
5. Try Slide/Fade/Instant page turns and hide page numbers.
6. Toggle Both Margins Advance; both edges should go forward.
7. Switch to Scrolling, scroll a few screens, then switch back; the page should
   return near where you left it.
8. Drag Brightness to 35%; the page should dim while the controls stay legible.
9. Close and reopen the book; appearance and mode settings should persist.

### PDF

10. Open a PDF and open Appearance; change Layout and Fit; the document should
    not reopen, and the current page should stay put.
11. Select Right to Left in a facing layout; page one should move to the right
    and the left/right arrow keys should follow the new direction.
12. Toggle Cover Alone; page one should sit by itself in a facing layout.
13. Change Page Gap, background, and Brightness; all should update live.
14. Reopen the PDF; the PDF settings should persist.

### Library

15. Select a book in the library; the book plate should fit at 900×640.

## Next polish phases

1. **In-book navigation** — search, bookmarks, and a persistent chapter/page
   scrubber that matches Apple Books' reading position model.
2. **Annotations** — text selection, highlights, and notes anchored to EPUB
   CFI or a stable text offset.
3. **Page-curl presentation** — only if it can be made performant in WKWebView.
4. **Per-theme memory** — remember custom font/spacing per theme rather than
   one global typography profile.
5. **Library finish** — richer resume state and a consistent focus/hover token
   pass.
6. **Verification** — VoiceOver/keyboard matrix, narrow-window matrix, and a
   real-book visual pass on the owner's Mac.

## Verification — Phase 2 (2026-10-29)

- Debug build: `** BUILD SUCCEEDED **`, exit 0.
- Focused `ReaderAppearanceTests`: **9 tests in 1 suite passed**, exit 0;
  xcresult `Test-AsterismaV2.5-2026.10.29_01-29-24--0400.xcresult`. The suite
  now covers PDF fit/layout mapping, page-gap margins, RTL presentation, and
  brightness clamping in addition to the Phase 1 pins.
- Full unit census at the Stage AA boundary: **441 tests / 671 runs / 432
  passed / 9 skipped / 0 failed**, exit 0; xcresult
  `rt-census-20261029-012648.xcresult`. The offline pass later moved the current
  unit census to 447 / 671 / 438 passed / 9 skipped / 0 failed (Stage AB).
- Browser harness (Chromium, 1280×720, not CI): paged mode rendered **23 pages**;
  scrolling mode rendered **21 viewport-pages**; `goToPage(3)` landed at
  `scrollY = 2160`; switching back restored page 3 at `scrollLeft = 3840`.
- Source count at the Stage AA boundary: **171 Swift files / 64,758 raw lines /
  57,220 non-blank**; unit-test folder **67 Swift files**. The offline pass later
  counted 172 / 64,868 / 57,315 and 68 test files.

## Verification — Phase 1 (2026-10-25/26, historical)

- Debug build: **BUILD SUCCEEDED**.
- `ReaderAppearanceTests`: **5/5 passed** — WCAG AA contrast for all six
  themes, legacy theme migration, theme defaults, full settings injection, and
  Original-font preservation.
- Local unit census: **220 passed / 0 failed / 9 skipped**.
- GitHub unit census: **229 tests / 10 deliberate skips / 0 failures**
  (run `40266848038`, green on macOS 26 / Xcode 26.6).
- The earlier full UI-inclusive rerun was blocked before test discovery by the
  macOS UI-test runner (`testmanagerd` automation bootstrap). That remains an
  unclaimed gate, not an app assertion; the deterministic unit gate and this
  suite are green.
- Owner visual acceptance is still required for theme fit, spacing, page-turn
  feel, and the redesigned book plate.

## Phase 2 limits

- No owner visual acceptance and no real-book pass; the macOS screen-capture
  permission remains denied, so there is no screenshot receipt.
- The browser harness is a one-off JavaScript check, not a standing CI job; the
  Swift appearance model has unit tests, but the WKWebView integration does not.
- Scrolling mode's page count is a viewport estimate (`ceil(scrollHeight /
  innerHeight)`), not a publisher page count; position persistence is therefore
  approximate when the window size changes.
- PDF page gap is disabled in Single layout because PDFKit turns page breaks off
  there; the gap slider is visible but inactive.
- No remote CI run for this working tree. The V2.0 rename, UI tranches, and this
  reader pass are uncommitted.

## Phase 1 session close (2026-10-25/26, historical)

Committed as `3bff002` (docs `6bcea96`) and tagged
`asterisma-v1.0-polish-1`. The final signed package was preserved; generated
Xcode/test residue was removed. Graphify was rebuilt against the new source
(5,305 nodes / 11,901 edges / 595 communities); `graph.html` was regenerated as
the aggregated community view because the graph exceeds the default 5,000-node
limit. The 2026-10-26 close-out refreshed the graph again during the final
clean-up; the final run reports the same 5,305-node shape.

### Ready close-out — 2026-10-26 (historical)

The signed package was rebuilt from app code `1c88ae5` after the CI concurrency
fix and the repository reorganization. The ready package SHA-256 is
`786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`.
Reader behavior is unchanged from the `3bff002` candidate; the owner retest
checklist above still applies. GitHub unit census `40266848038` is green
(**229 tests / 10 deliberate skips / 0 failures**), and graphify was refreshed
against the ready tree.
