# ADR-7 amendment 1 — verified chapter-boundary graph (with engine action contract)

Status: **OWNER-AUTHORIZED FOR IMPLEMENTATION — 2026-11-07.** The RT graph,
gate, cache, and tests are implemented. The pinned Mirage engine does **not**
implement `edition_chapters` yet, so the shipped app reports a typed
`engineUnsupported` state instead of rendering a graph. This document is an
amendment, not a claim that the feature is live.

Authorization provenance: the owner selected the countersign-amendment option in
the 2026-11-07 session. That session transcript is not a repository artifact, so
the authorization line itself is recorded as `SKIPPED` in
`docs/registers/05-doc-audit.md`; the code, tests, and command receipts below are
the repository evidence.

## 1. Why this amendment exists

The owner requirement is literal: while reading any chapter, summoning the
Mirage graph must work in **at most two seconds**. The existing integration could
not meet it:

- RT had no graph surface at all.
- ADR-7's gate refused every cursor because no verified page→unit or
  chapter→unit conversion existed.
- The engine had no wire action exposing chapter boundaries, even though
  ingestion stores chapter identity on every content unit.
- The only estimate available (progress fraction × inventory `max_cursor`) can
  land inside the chapter being read, which violates ADR-7's
  no-over-disclosure rule.

The owner authorized the narrow amendment described here on 2026-11-07. Claim,
evidence, entity-detail, search, and correction surfaces remain disabled.

## 2. Measured baseline (pinned engine, 2026-11-07)

The pinned engine was exercised with a 24-unit synthetic EPUB through the local
wire. These are process/transport measurements, not a graph-render benchmark:

| Step | Observed |
|---|---:|
| Engine banner | **72.04 ms** |
| Version handshake | **0.08 ms** |
| Import | **3.21 ms** |
| Analyze | **7.39 ms** |
| Warm projection p50 | **0.05 ms** |
| Warm projection p95 | **0.09 ms** |
| Cold restart to ready | **55.0 ms** |

**Important limitation:** the synthetic fixture produced **0 nodes / 0 edges**.
The projection timings measure transport and empty-result handling only. They do
not prove a large real graph renders within two seconds. The cache-hit path is
covered by a unit test that asserts **< 2 s** and completed in 0.001 s in the
focused run; that is a controller/cache measurement, not a visual one.

The measured cold-start envelope (55–72 ms) leaves ample room under two seconds
even with a real projection, but the real-graph number remains unmeasured until
the engine action exists and a real ledger is available.

## 3. Decision

### 3.1 One new read-only wire action

The engine owner adds exactly one action:

```json
{"id": "req-1", "action": "edition_chapters",
 "payload": {"edition_id": "edition_0123456789abcdef"}}
```

Successful result:

```json
{"id": "req-1", "ok": true,
 "result": {
   "edition_id": "edition_0123456789abcdef",
   "chapters": [
     {"chapter_index": 1, "first_unit_index": 0,
      "last_unit_index": 11, "unit_count": 12},
     {"chapter_index": 2, "first_unit_index": 12,
      "last_unit_index": 23, "unit_count": 12}
   ]
 }}
```

Contract:

| Field | Rule |
|---|---|
| `edition_id` | Exactly the requested edition. |
| `chapter_index` | Engine spine chapter number, **1-based**, unique, ascending. |
| `first_unit_index` | Inclusive global `unit_index`; non-negative. |
| `last_unit_index` | Inclusive global `unit_index`; `>= first_unit_index`. |
| `unit_count` | Exactly `last_unit_index - first_unit_index + 1`. |
| Coverage | Chapter ranges must not overlap; gaps are allowed only between chapters, never inside one. |
| Content | **No prose, claim text, entity content, evidence, excerpts, or offsets beyond the unit indexes.** |
| Side effects | None. This is a read; it must not mutate the ledger, checkpoints, deltas, or series state. |
| Unknown edition | Engine `not_found`. |
| Unknown action | Engine `validation_error` with status 404; RT maps this to the capability-gap state. |

The engine must derive the chapter number from its own ingested chapter identity
already associated with `content_units`; the exact query is engine-owned. RT does
not infer chapter boundaries from pages, percentages, file order, or titles.

### 3.2 The only cursor RT may construct

For RT's 0-based EPUB spine chapter `i`:

| RT chapter `i` | Engine chapter used | Cursor |
|---:|---:|---|
| `0` | none | No graph. Chapter 1 has no earlier boundary. |
| `1` | chapter `1` | last unit of chapter 1 |
| `2` | chapter `2` | last unit of chapter 2 |
| `n` | chapter `n` | last unit of chapter `n` |

In other words, **the graph for chapter N includes only content through the end
of chapter N−1**. The current chapter is never included. This is deliberately
coarser than a within-chapter cursor; a future calibration amendment may narrow
it, but this amendment does not.

The cursor is accepted only when the boundary map's `edition_id` matches the
active identity-map edition. Missing mapping, missing chapter, malformed map, or
edition mismatch fails closed.

### 3.3 What the graph may contain

The existing `projection` result is decoded into a cached snapshot with a strict
field whitelist:

- Node: `node_id`, `entity_id`, `label`, `node_type`, `epistemic_status`,
  `confidence`, `source_position`.
- Edge: `edge_id`, `source_entity_id`, `target_entity_id`, `predicate`,
  `epistemic_status`, `confidence`, `source_position`.
- Metadata: `mode`, `ledger_version`, `projection_hash` when present.

No claim body, evidence excerpt, entity description, search result, correction,
or raw prose is copied into the snapshot. Duplicate ids, missing required fields,
impossible numbers, a mismatched edition id, or an unexpected envelope shape
refuse the whole snapshot rather than rendering a partial graph.

### 3.4 Scope

- **EPUB only.** Comic editions are page-per-spine OCR EPUBs; RT comic pages have
  no verified page→spine mapping. The comic reader intentionally has no graph
  button in this amendment.
- **Explicit gesture only.** The graph is opened from the reader controls. No
  page-turn, scroll, chapter-change, or book-open path runs a Mirage request.
  No automatic prewarm is added; ADR-13's warm-engine lifecycle is unchanged.
- **Projection only.** The gate still refuses `search`, `cited_claims`,
  `neighborhood`, `edge_detail`, `history`, corrections, and every other
  detail action.

### 3.5 Cache and freshness

- Key: mapped `edition_id` + RT chapter index.
- Stored value: boundary cursor, decoded snapshot, and cache timestamp.
- Location: `mirage/graph-cache/` (derived data; deleting it loses no analysis).
- Bound: 64 entries, oldest evicted first.
- A cache hit returns before any engine lease and is the path used for the
  second and later summons.
- A successful re-analysis of the same edition clears that edition's cache, so a
  changed ledger cannot be shown under an old boundary.
- A refresh gesture bypasses the cache and replaces the entry on success.

## 4. Failure behavior

| Condition | RT state | What is transmitted |
|---|---|---|
| Mirage disabled in Settings | `unavailable` | Nothing. |
| No active identity mapping | `unavailable` | Nothing. |
| RT chapter 1 | `firstChapter` | Nothing. |
| Engine lacks `edition_chapters` (`validation_error` 404) | `engineUnsupported` | The boundary read only; no projection. |
| Boundary map malformed / overlaps / wrong edition | `failed` | The boundary read only; no projection. |
| Projection malformed / wrong edition | `failed` | Boundary read + refused projection. |
| Engine unreachable | `failed` | Nothing beyond the attempted lease. |
| Cache hit | `ready(source: .cache)` | Nothing. |

Refusals are typed and displayed in plain language. There is no retry loop, no
fallback estimate, and no conversion of a page number into a unit index.

## 5. Engine work required before the graph can render

The engine owner must, in the separately-owned engine repository:

1. Add `edition_chapters` to the dispatcher.
2. Return the exact contract in §3.1 from ingested chapter identity.
3. Add engine tests for: normal multi-chapter EPUB, single-chapter EPUB, unknown
   edition, unknown action, duplicate/overlapping chapter ranges, and a book with
   units that have no chapter identity.
4. Run the engine's Python suite and publish the receipt.
5. Keep the action read-only; do not add a mutation, correction, or search path
   under this amendment.

Until those steps land and a real edition produces a non-empty projection, the
RT feature is **wired, cached, tested, and blocked** — not live.

## 6. Verification receipt (RT side)

Focused run on 2026-11-07:

```text
xcodebuild test -project AsterismaV2.0.xcodeproj \
  -scheme AsterismaV2.0 -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AsterismaV2.0Tests/MirageGraphTests \
  -only-testing:AsterismaV2.0Tests/MirageCursorContractTests \
  -only-testing:AsterismaV2.0Tests/MirageSpoilerProbeTests \
  -only-testing:AsterismaV2.0Tests/MirageProtocolConformanceTests \
  -only-testing:AsterismaV2.0Tests/MiragePageTurnNonTriggerTests
```

Result: **41 tests in 5 suites passed, exit 0**. Full census: **610 tests in 115 suites passed**
(console) and **611 passed / 10 skipped / 0 failed / 719 runs** (result bundle), exit 0. The suite covers:

- boundary anchoring at the previous chapter's last unit;
- first-chapter refusal and no engine call;
- strict boundary and projection decoding;
- cache round-trip, cache hit under two seconds, and edition-scoped clearing;
- engine-unsupported mapping;
- the verified boundary as the only detail transmission;
- old estimate/page/unit refusals and transport tripwires;
- deterministic bounded layout;
- the 28-action pin plus the single `edition_chapters` extension;
- controller initialization inertness (no auto-prewarm).

**Not verified:** app launch, reader screenshot, Settings/reader visual
inspection, a real library graph, a real engine `edition_chapters` response, a
real-graph two-second measurement, or a comic graph. The focused cache test is
not a substitute for a UI latency measurement.

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| RT spine chapter and engine chapter numbering diverge | Contract requires 1-based engine numbering; RT refuses a missing requested chapter; no page fallback. |
| Engine returns a gap or overlap | Strict decoder refuses the map. |
| Stale graph after re-analysis | Successful linked analysis clears that edition's cache. |
| Graph over-discloses the current chapter | Cursor is the previous chapter's last unit; tests pin chapter 1 and the previous-chapter rule. |
| Large graph stalls the sheet | Deterministic one-pass layout caps visible nodes at 80 and reports hidden count; no force simulation. |
| Engine action is expensive on a huge book | Boundary response is O(chapters), not O(units); real large-book timing remains an acceptance gate. |
| Comic page→spine mismatch | Comic reader has no graph mount in this amendment. |
| Cache leaks content | Snapshot contains only whitelisted labels/statuses/ids/positions; no claim/evidence text. |

## 8. Rollback

Remove the reader button and sheet mount, the graph controller/cache/view, and
the `edition_chapters` case from `MirageWireAction`; restore the old conformance
count. The engine action can remain in the engine because it is read-only and
not called. No ledger data is changed by rollback.

## 9. Approvals and ownership

- **Owner:** authorized this amendment and the engine-read path in the
  2026-11-07 session.
- **RT implementation:** Buffy (main administrator); RT cannot edit the pinned
  engine, commit, or push under this authorization.
- **Engine implementation:** engine owner; required before live rendering.
- **Commit/push:** separate explicit owner approvals; not implied by this
  amendment.

## 10. Links

- Base contract: `docs/integration/adr/ADR-7-spoiler-cursor-contract.md`.
- Engine deep dive and performance baseline:
  `docs/integration/MIRAGE-DEEP-DIVE-2026-10-28.md`.
- RT controller: `AsterismaV2.0/Features/Mirage/MirageGraphController.swift`.
- Boundary model: `AsterismaV2.0/Features/Mirage/MirageChapterBoundaries.swift`.
- Snapshot: `AsterismaV2.0/Features/Mirage/MirageGraphSnapshot.swift`.
- Cache: `AsterismaV2.0/Features/Mirage/MirageGraphCache.swift`.
- Sheet and renderer: `AsterismaV2.0/Features/Mirage/MirageGraphView.swift`.
- Tests: `AsterismaV2.0Tests/Mirage/MirageGraphTests.swift`.
