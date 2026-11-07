# ADR-7 — Spoiler-cursor contract (with S10-ES-3 formal sub-document as annex)

Status: **ACCEPTED — countersigned by the owner 2026-10-18; amended 2026-11-07.** PR-6's spoiler-sensitive gates released. Claim, evidence, entity-detail, search, and correction surfaces remain disabled. [Amendment 1](ADR-7-amendment-1-chapter-boundary-graph.md) adds exactly one verified provenance — an engine-read chapter boundary — and one read-only projection for the reader graph; it does not enable any other detail surface.

## Problem statement

PR-6 must expose Mirage's literary analysis to RT *without ever revealing content the reader
has not reached*. The migration across that boundary is the "spoiler cursor": a claim that
"up to position N" defines what the engine may disclose. The playbook (S10-ES-3, Appendix C
invariant 4) forbids shipping any spoiler-sensitive query path until this contract is
countersigned, and forbids unpackaged inference: the cursor's provenance, conversion,
validation, and failure behavior must be written down first.

## Context (source-anchored)

- **Engine cursor semantics:** `projection.edition_id + cursor_unit` are REQUIRED
  (`MirageV1.0/src/miragev10/api/service.py` — the `projection` dispatch raises without them);
  the inventory row carries `max_cursor` (the edition's highest unit index); eligibility is
  computed *at or before* the cursor with forbidden tokens derived from evidence *after* it
  (`query/projection.py:301-383` — `derive_forbidden_tokens_from_tokens(..., cursor_position)`).
- **Engine state vocabulary (validated at the tagged source):** `unread | reading@cursor | read`
  (`cli/__init__.py:46`, storage/schema.py:565, `storage/ledger.py:1777`). The `reading@cursor`
  cursor is the SAME paragraph-unit coordinate the projection uses.
- **Engine unit coordinate:** paragraph units, one ledger counter per edition
  (`unit_index`, `chapter`, `reading_order_path` — `ingestion/epub.py:218-249`).
- **RT position coordinates:** `Book.currentPage / totalPages / progressFraction`
  (`Core/Book2.swift:38-96`), chapters with page ranges (`Chapter.startPage/endPage`,
  `:338-344`), reading sessions in pages (`ReadingSession.startPage/endPage`, `:360-371`), and
  the EPUB reader's in-memory `currentChapterIndex` (view state, not persisted).
- **No shared calibration exists.** Mirage counts paragraphs; RT counts pages. RT has no
  field, store, or bridge read that maps a page (or a chapter) to a Mirage `unit_index`; the
  only estimate — fraction of progress × `books_list.max_cursor` — cannot guarantee
  "≤ current position" and is therefore an *unverified cursor*, which Appendix C invariant 4
  forbids feeding spoiler-sensitive surfaces.

## Decision

1. **Conversion algorithm: none verified exists — so the spoiler-sensitive detail surface
   ships DISABLED.** (The "no-conversion-is-the-safe-conversion" doctrine of S10-ES-3.) RT
   renders analysis availability (status) but does not render claim/evidence/graph detail,
   until a future ADR-7 amendment defines and pins a VERIFIED chapter→unit calibration
   (e.g., an engine-side per-chapter unit-boundary read), countersigned separately.
   **Amendment 1 (2026-11-07)** supplies that boundary read and enables only the
   previous-chapter graph projection; every other detail surface remains disabled.
2. **RT's cursor machinery is built and pinned, but gated.** The typed cursor value,
   validation, and fail-closed tripwires exist and are test-pinned now (S9-ES-5 cursor codes:
   `SPOILER-CURSOR-UNVERIFIED`, `SPOILER-PROBE-REJECTED`, `CURSOR-MISSING`); the detail-query
   call site refuses to send any cursor it cannot prove verified, on any path.
3. **Provenance rule:** an RT cursor is only usable against its mapped `mirageEditionID`
   (ADR-5's identity map); an unmapped/orphaned book has NO cursor (missing-data ⇒ fail
   closed) — never title-based inference (ID-* discipline).
4. **Invalidation conditions:** re-import with a changed fingerprint (ADR-5 orphaning),
   re-ingestion/pipeline-version change engine-side, duplicate editions appearing ledger-side,
   or identity-map `unreadable` state all invalidate; no cursor survives content change.
5. **State-vocabulary transduction table (validated; no invented states):**
   `Book.isCompleted == true → "read"`; `isInProgress == true → "reading@<unit cursor >
   UNVALIDATED>`; else `→ "unread"`. Because no verified unit cursor exists, the
   `reading@N` value cannot be produced yet — so RT renders the third state faithfully
   (human-readable, e.g., "reading — page N of M") and **makes no Mirage declaration**.
   The `series_read_state` mutation path is deliberately OUT of PR-6 scope (playbook:
   no series editing / no corrections / no bulk ops in PR-6).
6. **Page-turn non-trigger:** no Mirage request may be triggered by reading progress events
   (S10-ES-4 pin 1) — the only wire call sites are the explicit analyze button (PR-5) and the
   disabled-by-default detail gate (PR-6), never reader scroll/page-turn handlers.

## Alternatives (considered, rejected)

- **Estimated cursor (fraction × max_cursor)** — rejected: an unverified cursor feeding a
  spoiler surface is exactly the failure Appendix C forbids; uncertainty cannot be proven
  one-directional (a chapter boundary can misplace the cursor BY a chapter, both ways).
- **Ship detail queries with RT's page coordinate sent verbatim** — rejected: coordinate-space
  injection; the engine's unit_index is a different scale; even benignly wrong values leak
  (type-confused cursor).
- **Forward-only status-only ship without machinery** — rejected as strictly weaker than this
  decision: the machinery (validation + pin tests + render rules) is required by S10-ES-5 and
  is harmless while gated.

## Consequences

- **Positive:** spoiler safety is provable now (no detail surface consumes unverified data);
  the status story is honest and immediately testable; the machine rests are pinned so the
  future amendment is a small, verified increment.
- **Negative:** RT users see *that* Mirage analyzed their book but not the analysis content
  yet — an acknowledged functional gap, ledgered rather than hidden.
- **Neutral:** the engine still supports everything; nothing engine-side changes.

## Security & privacy impact

The engine remains local-only; RT surfaces add no network paths. The disabled detail surface
removes the largest potential over-disclosure vector at PR-6 by construction. Rendered counts
(`units`, `claims` from `books_list`) are engine-attested inventory facts, shown with
provenance labels ("Mirage ledger counts, as of the last check") — never promoted to RT truth
(corrections-never-truth rule holds; user-corrections overlay metadata never rendered as
content).

## Rollback implications

Revert PR-6 ⇒ RT returns to PR-5 behavior (analyze button + identity stratum; no analysis
surface at all). The identity stratum and ledger remain untouched; `disable-deletes-nothing`
(verified in PR-7) covers this feature's strata too.

## Tests required (named, per S10-ES-5 + S-C-ES-1)

- `MirageCursorContractTests`: cursor type/validation pins; refusal pins for unverified
  cursor classes (estimate/coordinate-confused/unmapped-book) at the gated call site;
  missing cursor ⇒ fail-closed (S9-ES-5 codes; CU-REQUIRE observed semantics — the engine's
  `projection` refuses without `cursor_unit`, ValidationError).
- `MirageSpoilerProbeTests` (fake transport): a probe claiming detail disclosure with no
  verified cursor is REFUSED client-side (preflight tripwire), engine never contacted.
- `MiragePageTurnNonTriggerTests` / structural pin: no Mirage call sites reachable from
  reader page-turn/scroll paths (S10-ES-4 pin 1).
- `MirageStatusSurfaceTests`: status rendering uses only the pinned vocabulary and
  provenance labels; transduction table renders human states without Mirage declarations.
- (E2E, opt-in real engine): status surface against a real analyzed edition via the PR-5
  single-lifecycle harness detail-free (counts only).

## Approving owners

- Owner (Johan) — countersign pending, recorded on acceptance.

---

## Annex A — S10-ES-3 formal cursor contract sub-document (normative)

Per the S10-ES-3 escalation, this annex is the standalone normative cursor contract. All seven
required elements follow, each source-anchored.

### A.1 Field provenance

The complete inventory of RT position-bearing fields, their stores, and the mutation events
that last touch them:

| Field | Store / model | Mutation events | Provenance class |
|---|---|---|---|
| `Book.currentPage` | RT SwiftData book model (`Core/Book2.swift:220` decoded; range-clamped) | (a) `Core/DataStore3.swift:374` — persistence-layer update while/after reading; (b) `:393-394` — the paired re-read write (`book.currentPage = newPage` with `book.sessions[sIdx].endPage = newPage`); (c) `Core/DataIntegrityValidator.swift:178` — **repair clamping** (guards, never advances reading); (d) `Features/Discovery/DemoDataService.swift:465-468` — **demo seeding** (synthetic catalog data, not user reading); (e) `Core/Book2.swift:179` — model init | (a),(b) genuine reading progress; (c) repair; (d) synthetic |
| `Book.totalPages` / `progressFraction` | same model (`Core/Book2.swift:38-96` region) | derivation + import-time metadata | derived, RT-native |
| `Chapter.startPage / endPage` | same model (`Core/Book2.swift:338-344`) | import-time metadata | RT-native, page-coordinate |
| `ReadingSession.startPage / endPage` | `Book.sessions` (`Core/Book2.swift:360-371`) | session open/close by the reading-session recorder; adjustment via `DataStore3.swift:393` | genuine reading telemetry |
| EPUB reader's current-chapter/location state | view-layer state in `Features/Reader/` | page turns in the reader UI; **explicitly not persisted** (nothing on the wire, nothing in the store) | ephemeral |

**Provenance rule enforced by this annex:** only class "genuine reading progress" may ever be
*considered* a cursor source; repair and synthetic writes are metadata-hygiene events that do
not move any cursor, forward or back.

### A.2 Conversion algorithm

**None verified exists.** The candidate estimate (progress-fraction × the edition's
`max_cursor` from `books_list`) was examined and rejected: it is an unverified cursor by
construction, cannot guarantee "≤ current reader position" (a mis-estimated chapter boundary
can place the cursor ONTO unread content), and Appendix C invariant 4 forbids feeding
spoiler-sensitive surfaces from unverified cursors. Therefore, per the no-conversion-is-the-
safe-conversion doctrine, **the spoiler-sensitive detail surface ships disabled** until a
future countersigned amendment defines a verified chapter→unit calibration.

### A.3 Edition-identity requirement

A cursor — today's rendered states, and any future unit cursor — is valid only against the
user's mapped `mirageEditionID` per the ADR-5 identity map. Unmapped book ⇒ no cursor;
orphaned (source-changed / drift) mapping ⇒ dead cursor; duplicate-edition ambiguity ⇒ the
refusal rule ADR-5 already pins. Title- or file-name-based positioning is forbidden
(ID-* discipline: no identity synthesis of any kind).

### A.4 Invalidation conditions

A cursor (or any rendered analysis status) becomes invalid and must fail closed immediately
upon: (1) re-import with a changed content fingerprint — ADR-5 orphaning already removes the
identity link, which removes the cursor with it; (2) ledger-side re-ingestion or
`pipeline_version` change (analysis replaced upstream); (3) duplicate-edition ambiguity
appearing ledger-side; (4) identity-map `unreadable` state — the fail-closed degrade ADR-5
pins. No cursor ever survives a content change.

### A.5 Regression policy

Cursor movement may only ever move **forward on verified evidence**; backward movement
requires an explicit re-declaration event under a countersigned amendment. In the current
doctrine no cursor value is produced, moved, or consumed by any RT surface at all — the
policy therefore governs the machinery being pinned for the future amendment, not any
shipping path today.

### A.6 Missing-data behavior (fail closed)

Missing or unverifiable cursor data ⇒ RT refuses the spoiler-sensitive query path with typed
errors (S9-ES-5 classes): `CURSOR-MISSING` (no mapped edition, no position data),
`SPOILER-CURSOR-UNVERIFIED` (any attempt to source a cursor from an estimate),
`SPOILER-PROBE-REJECTED` (a request seeking detail disclosure with no verified cursor basis).
Engine-side analog, observed and pinned: the engine's `projection` raises a hard
`ValidationError` when `cursor_unit` is absent — RT mirrors that refusal semantics
additively, never retrying, never relaxing.

### A.7 State-vocabulary transduction table

Validated against the engine's domain vocabulary at the pinned source
(`MirageV1.0/src/miragev10/cli/__init__.py:46`, `storage/schema.py:565`,
`storage/ledger.py:1777`): the engine's declared states are exactly
`unread | reading@cursor | read`. No intermediate states are invented.

| RT field condition | RT-rendered state (RT's own words) | Engine vocabulary correspondence | Mirage declaration transmitted? |
|---|---|---|---|
| `Book.isCompleted == true` | "read" | `read` | No |
| `Book.isInProgress == true` | "reading — page N of M" | `reading@cursor` — the cursor component is **unproducible** today (A.2) | No |
| otherwise | "unread" | `unread` | No |

The `series_read_state` declaration path (a ledger mutation) is deliberately out of PR-6
scope: nothing in RT's rendering produces a Mirage write. The table is rendered read-only.

### A.8 Unsafe-by-default reminder

Until this annex is countersigned by the owner, no spoiler-sensitive query path ships —
read-only status surfaces only. On countersignature, PR-6 implements precisely the status
surface + gated cursor machinery described in the body of this ADR, and nothing more.

## Supersedes / superseded-by

None in the body. **Amendment 1** (2026-11-07) is the first countersigned increment:
[ADR-7 amendment 1 — verified chapter-boundary graph](ADR-7-amendment-1-chapter-boundary-graph.md).
It enables the previous-chapter graph projection only; claim, evidence, entity detail,
search, corrections, and every other detail surface remain disabled.
