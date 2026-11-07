# G1 owner acceptance script — annotations

**Status:** written 2026-11-07, **not executed**. Nothing in this file is a pass
claim. The owner runs it; Buffy cannot run it and has no live reader pass.

**Why it exists.** G1's gate requires a recorded 10-step owner script. The code
is merged and its tests are green, but no human has opened a book, made a
highlight, quit the app, and looked at the result. That gap is the difference
between "compiled and unit-tested" and "works".

## Before starting

- Build from `main` at `88506ae` or later (`xcodebuild … build`, Debug).
- Record: commit hash, macOS version, and the two files used.
- Use one EPUB with at least three chapters and one PDF with at least five
  pages. A book whose text you do not mind annotating.
- Keep a screen recording or a screenshot per step. A step without a capture is
  not evidence.

## The ten steps

1. **Create an EPUB highlight.** Open the EPUB, select a phrase of at least
   three words on the first page. The action bar should appear at the bottom of
   the reader with five color swatches, Highlight, and Copy.
2. **Attach a note.** Press Highlight. The editor opens with the quote and the
   color you chose. Type "first highlight", press Save.
3. **Survive relaunch.** Quit the app completely and reopen it. Open the same
   book and chapter. The same words are still highlighted, once, in the same
   color.
4. **Survive reflow.** Change the font size two steps in the reader's
   appearance controls. The highlight stays on the same words and does not
   duplicate or move to a neighbouring sentence.
5. **Survive navigation.** Go to the next chapter and back. The highlight is
   still there, once.
6. **Edit.** Click the highlight. The editor shows "first highlight". Change the
   color to pink and the body to "edited highlight", press Save. There is still
   exactly one mark, now pink.
7. **Copy from the library.** Open Book Details → Notes. The row shows the
   quote, a "— Chapter N" caption, and the body. Press Copy quote, paste into
   TextEdit: exactly two lines, the quote then the caption, nothing else.
8. **Create a PDF highlight.** Open the PDF, go to page 3, select a sentence,
   press Highlight, type "pdf note", Save.
9. **Survive PDF layout.** Zoom to 150% and switch to a facing layout. The
   highlight stays on the same sentence and appears once. Click it: the editor
   opens with "pdf note".
10. **Delete.** In that editor, press Delete once (it arms), press again (it
    confirms). The mark disappears. Quit, relaunch: it is still gone, and the
    EPUB highlight from step 1 is still present.

## What counts as a failure

Stop at the first failure and record the step number, what you saw, and a
screenshot. Do not work around it in the app. Specific things to watch for,
because the tests cannot see them:

- A mark drawn on the wrong words after step 4 or 9 (drift).
- Two marks on the same words after step 5 or 9 (duplicate).
- The action bar staying after you click away from a selection.
- A highlight that exists in the Notes list but not on the page, or the reverse.
- Any modal alert during steps 1–10 (the design forbids them).

## Known limits of this build

- The EPUB renderer uses the CSS Custom Highlight API. On a WebKit build without
  it, no marks draw at all while the notes remain intact; step 1 would then fail
  at "the highlight appears".
- PDF staleness (a quote no longer present in the page text) draws no mark and
  shows no inline warning; the note is still listed in Book Details.
- Only the 10 steps above have a written procedure. There is no script yet for
  keyboard-only use or VoiceOver (WP-1.6's other half).

## Recording the result

Append one row per run to this file: date, commit, macOS version, steps passed,
first failing step, and a link or path to the captures. A run that stops at step
4 is recorded as "1–3 passed, failed at 4", never as "mostly passing".
