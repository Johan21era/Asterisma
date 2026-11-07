# Mirage Deep-Dive Report — Final Synthesis (Engine Envelope v1.0.0)

| | |
|---|---|
| **Document ID** | MIRAGE-DEEP-DIVE-2026-10-28 |
| **Status** | Final synthesis of the 2026-10 deep-dive arc; supersedes no prior record, consolidates the deep-dive evidence. **2026-10-29 revision:** the per-gesture lifecycle bullet in §2.3 and the RT file count in §3.2 are historical; see §10 and ADR-13 |
| **Scope** | RT ↔ Mirage integration band + Mirage engine runtime (`.mirage-runtime/mirage-runtime` staged bundle ↔ `/Users/johanrembeci/Desktop/MirageV1.0` canonical checkout) |
| **Governing documents** | `docs/integration/RT_Mirage_Codebase_Merge_Playbook.md` · ADR-2…ADR-8, ADR-12 · `docs/integration/merge-log.md` · `docs/integration/final-acceptance-2026-10-18.md` · docs/product_era_plan.md (P18–P23) · docs/problems.md (P-001…P-028) · `docs/12-owner-test-authority.md` |
| **Author / date** | Engineering investigation session, 2026-10-28 (final deep-dive pass) |
| **Evidence-class legend** | **[V]** = verified today by inspection/artifact on disk · **[S]** = session-phase observation from today's debugging cycles (log or artifact *not retained*; repeatable by procedure) · **[U]** = unverified hypothesis/unknown |

> **Path rule.** The product-era plan and problems register named in the table belong to the MirageV1.0 checkout, not this repository; they are plain text. Only paths under this repository are backticked.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Scope and Snapshot](#2-scope-and-snapshot)
3. [Architecture Map](#3-architecture-map)
4. [Verified Strengths](#4-verified-strengths)
5. [Defect and Gap Inventory](#5-defect-and-gap-inventory)
6. [Honest Unknowns — Not Covered by This Deep Dive](#6-honest-unknowns--not-covered-by-this-deep-dive)
7. [Prioritized Improvement Roadmap](#7-prioritized-improvement-roadmap)
8. [Verification Protocol per Roadmap Item](#8-verification-protocol-per-roadmap-item)
9. [References and Source Links](#9-references-and-source-links)

---

## 1. Executive Summary

The deep dive is **complete** and the verdict is a qualified **green**.

**Verdict:** the Mirage engine + RT integration band is mechanically sound at the v1.0.0 envelope.
The adversarial, lifecycle, ledger, spoiler, and ingestion surfaces all held up under the deep-dive
probes (3-unit EPUB re-analyze idempotence, 12-para synthetic book, fixed JOIN defect, MERGES via
`unique-partial-name`, projection counters). The remaining work is **not** on the runtime-critical
path — it is on the **frontier of honesty and trust**:

1. **Extraction quality is the standing gap.** Open defects P-017…P-022 (foreign-word fragments, sentence-initial
   verb/adjective entities, name-plausible common nouns, narrator hedges/retractions, tag-line dialogue, non-literal
   predication) remain 🔴 open, with the deep-audit-verified P18-era plan pointing at structural fixes rather than
   more stoplist entries. P-005 was re-scoped (graded-cohort claim tp 475/479 ≈ 1.0 modulo cited rows).
2. **Trust hardening (P18) is the named engineering-debt queue** — all six verified items from the 2026-10-17 deep audit
   remain open: `POST /command` Origin gap, SSE queue bounds, commit-before-delta window, chain-order-on-timestamp,
   Linux `rss_mb` misread, vacuous `ALLOWED_DISPLAY_STATUSES` gate. Plan: docs/product_era_plan.md §P18.
3. **A new finding was just confirmed in the dispatcher:** the NDJSON command dispatcher (`api/service.py`,
   `run_command`) carries **two** `import_epub` branches with divergent return shapes (set-membership branch at line ~827
   vs standalone branch at ~920) and divergent payload handling (`title_guess` accepted only in the first). Latent
   contract drift, low severity, hygiene-class.
4. **RT-side integration gaps are known and parked:** no `backup` wire action (ADR-4 limitation), TB-M0 gate plan open
   (7 consecutive ledger days + tamper drill), no Mirage performance-budget report for the RT UX, spoiler detail surfaces
   disabled pending countersigned chapter→unit calibration (ADR-7).

**Best-supported path:** finish the P18 trust-hardening batch + dispatcher dedupe this session (small, mechanical, high
evidence-yield), then run the P22 quality rounds (structural extraction fixes + first post-freeze recall measurement) in
the coming weeks, in owner-gated order.

---

## 2. Scope and Snapshot

### 2.1 Repository and runtime snapshot (verified 2026-10-28)

| Item | Verified value |
|---|---|
| App repo | `/Users/johanrembeci/Desktop/AsterismaV1.0` — branch `main`, HEAD `6099e4e`, app code `1c88ae5` |
| Tags | `asterisma-v1.0-mvp`, `asterisma-v1.0-ready-2026-10-26` |
| Canonical engine checkout | `/Users/johanrembeci/Desktop/MirageV1.0` — HEAD `8142261` (single initial-import commit), bundle SHA `81422613610701d81956394d9601bcb61e2938e9` |
| Staged runtime pin | `.mirage-runtime/mirage-runtime` — `RUNTIME-MANIFEST.json`, bundled CPython 3.12.7, `PYTHONDONTWRITEBYTECODE=1` |
| Live data root | `~/Library/Containers/johan.Reading-Tracker/Data/Library/Application Support/Asterisma/` |
| Uncommitted working tree | Modified `AsterismaV2.5/Core/DataStore3.swift`, `AsterismaV2.5/Core/Storage/LibraryDatabase.swift` (fail-closed SQLite load); untracked `AsterismaV2.5Tests/Core/SQLiteLoadIntegrityTests.swift`, `docs/plans/sentinel/` |

### 2.2 Verification reality (owner-test authority still governs)

- **Engine suite:** 316 Python + 3 Rust tests green at v1.0.0 (deep-dive re-run 2026-10-28: `Ran 316 tests … OK`, ~5.0 s).
  Caveat recorded: suite must be discovered with `-t .` (bare `-s tests` hits `ImportError: Start directory is not importable`).
  Interpreter caveat: pinned runtime is CPython 3.12.7; deep-dive used system Python 3.14.
- **Census (deterministic unit receipt):** GitHub CI run `40266848038` was green on 2026-10-26 — **229 tests / 10 deliberate skips / 0 failures**
  (macOS 26 / Xcode 26.6; CI-001 fix). Local unit census with staged Mirage runtime: **220 passed / 0 failed / 9 skipped** (both figures are the 2026-10-26 snapshot; the 2026-10-28 post-SG8 local census is **432 tests / 671 runs / 9 skipped / 0 failed**).
  Opt-in gates: 4 Mirage real-engine, 1 bundled-runtime (CI only), 1 benchmark, 2 real-library SQLite parity, 2 live Open-Meteo.
- **UI tests:** placeholder launch stubs — not part of the deterministic CI merge receipt.

### 2.3 Engine envelope (v1.0.0, verified this deep-dive)

- API `1.0.0` (min = max); schema `ledger@0.0.10`; NDJSON one compact JSON per LF line; request
  `{action, payload?, id}`; response `{ok:true, result}` / `{ok:false, error:{type, code, status, message}}` with echoed `id`.
- 28-action dispatcher surface (health, version, import/import_epub, analyze, projection, search, checkpoint,
  verify_checkpoint, reconstruct, verify_deltas, export_graph, cited_claims, translate, neighborhood, edge_detail,
  history, books_list, edition_remove, book_remove, search_eligible, series_create, series_list, series_candidates,
  series_attach, series_detach, series_read_state, series_breakdown, series_remove).
- RT never sends bare `import`; identity faults are terminal `protocol_incompatible`; pid-file single-instance guard.
  At the **2026-10-28 snapshot (historical)**, one gesture meant one clean sidecar (spawn → work → SIGTERM→5 s grace →
  SIGKILL), backoff `[2,4,8]` s → `permanentDown`. The handshake and backoff still govern each (re)connect; the
  per-gesture teardown was superseded by ADR-13 on 2026-10-29.

### 2.4 Deep-dive probe results (this session)

| Probe | Result |
|---|---|
| 3-unit EPUB re-analyze idempotence | `completed_no_mutation` (idempotent) |
| 12-para synthetic book | analyze → units 12 / entities 9 / claims 4 / evidence 23 / uncertainties 2; projection 7 nodes / 0 edges |
| MERGES via `unique-partial-name` | confirmed incl. partial-name forms (`The clerk`, `Mara Velez`, `Elias Reed`, …) |
| Fixed missing JOIN | confirmed resolved; entity_names now complete |

---

## 3. Architecture Map

### 3.1 Engine layer stack (canonical checkout)

```
ingestion/        epub.py (EpubIngestor) + readers/adapters.py   (EPUB 2/3, Calibre div-only, HoC, caps)
extraction/       heuristic.py (47 funcs, deterministic classical extraction)
domain/           contracts (P-002 mitigated; 69 tests)
pipeline/         analyze.py, screening.py                          (one analysis job at a time; 8 GB budget)
storage/          ledger.py (2,298 LOC, 105 funcs), schema.py (ledger@0.0.10, m0001–m0016)
spoilers/         eligibility.py (fail-closed leak gate, dependency closure)
query/            cited_claims, neighborhood, edge_detail, history, search, search_eligible, series_*
checkpoints/      reconstruction.py
deltas/           delta chains + inverse replay
identity/         resolution.py
api/              service.py (dispatcher), errors.py
serve/            serve.py, webserve.py (P13 stdlib browser relay: POST /command, GET /events SSE, 10 MiB body cap, 127.0.0.1 bind)
i18n/, config.py, diagnostics.py, cli/, __init__.py
```

### 3.2 RT integration band

`Features/Mirage/` — **17 typed files as of 2026-10-29**: MirageWireTypes, MirageProtocolConstants, MirageClient,
MirageTransport, MirageSettings, MirageSidecarSupervisor, MirageRuntimeLocator, MirageChildProcess, MirageImportFlow,
MirageIdentityMap, MirageCursor, MirageStatusSurface, MirageAnalysisSheetView, MirageAppImportMount, and the ADR-13
additions `MirageEngineService.swift`, `MirageLibraryIndex.swift`, and `MirageBatchAnalyzer.swift`.

### 3.3 Cross-cutting contracts

- **Wire:** NDJSON command/response; SSE `GET /events`; loopback-only web serve.
- **Ledger:** append-only claim versions, delta chains, corrections, series registry, single delete path, backup, inverse replay.
- **Spoiler contract:** fail-closed; `ALLOWED_DISPLAY_STATUSES`; dependency closure; cursor-bound detail surfaces.
- **Identity:** entries born only from validated `import_epub` receipts; RT store and Mirage ledger never unified.

---

## 4. Verified Strengths

1. **Mechanical runtime green:** 316 Python + 3 Rust tests OK (~5 s); deep-dive re-verified.
2. **Calibration on graded cohort (P7/P8/P9/P28):** entities tp retention **234/234 (1.0)**, claims **475/479 (1.0 modulo the
   4-row cited below-surface register)**, fp suppression **0.589 / 0.401** (docs/artifacts/p28/calibration.json).
   Effective reader-facing precision on the hardest 14 books: ~31% entities, ~45% claims.
3. **Performance envelope (P4 mitigated, measured):** peak RSS **~211 MB of 8,192 MB**; 10k units analyze **5.18 s**;
   projection p95 **0.15 s**; page-turn **~0.39 s median**. Budget respected with ~39× headroom.
4. **Spoiler safety (P6/E-024):** fail-closed leak gate + dependency closure; invariants **I-SP1/2/3, I-PRIV1** green; §43.3
   real-pipeline proof executed.
5. **Persistence (P8/E-025, ADR-0003):** deltas emitted+verified, payload checkpoints, crash recovery, idempotent undo.
6. **Ingestion hardening (P7/E-037):** namespace typo → **63/63 real books**; DOCTYPE refusal → EPUB2; archive/catalog caps →
   illustrated books; 64 KiB per-unit cap (Karamazov 23.6 KB paragraph); div-only chapters → **492/492 unit-exact**.
7. **Incremental correctness (P6/E-031):** second object-less claim visibility, partial-name merge scope, caseless-script
   extraction, metamorphic determinism — all fixed and pinned.

---

## 5. Defect and Gap Inventory

### 5.1 Engine — open extraction frontier

| ID | Defect | Status | Disposition |
|---|---|---|---|
| P-017 | Foreign-word fragments mint entities | 🔴 OPEN | Language/foreign-word gate owed (E-034 lineage) |
| P-018 | Sentence-initial capitalized verbs/adjectives mint entities | 🔴 OPEN | Structural sentence-initial fix owed, not more stoplist entries (ties P-012) |
| P-019 | Name-plausible common nouns remain entities | 🔴 OPEN | Deliberate trade-off; needs contextual gating |
| P-020 | Narrator hedges/retractions beyond cue sentence not captured | 🔴 OPEN | Cross-sentence retraction linking owed |
| P-021 | Tag-line dialogue mints no statement claims | 🔴 OPEN | Statement-minting for `**Name:**` lines owed |
| P-022 | Non-literal predication asserted as literal | 🔴 OPEN | Needs object lexicon / metaphor detection; model-adjacent, gate to P23 |

Plus: **P-005 re-scoped** 🟠 (E-037; claims tp 475/479 on graded cohort); **P-007 / P-009 / P-010 deferred** (reader-adapter
real-reader measurement; confidence thresholds/scheduler weights; text-based PDF adapter).

### 5.2 Engine — P18 trust-hardening debt (deep-audit verified, still open)

1. `POST /command` no Origin/Host validation (drive-by capable page risk while `--serve-web` runs).
2. Unauthenticated `/events` SSE; unbounded per-client queues; no rate limit.
3. `add_claim` commits before delta emits (commit→emit window).
4. Delta chain predecessor chosen by `ORDER BY created_at DESC, delta_id DESC` (same-microsecond hazard).
5. Linux `MemoryBudget.rss_mb` misclassification.
6. Vacuous `ALLOWED_DISPLAY_STATUSES` gate (set mirrors enum; rejection currently dead).

Plan: docs/product_era_plan.md §P18 (~1–2 days; keep all 316 tests green; add pins).

### 5.3 NEW deep-dive finding — dispatcher duplicate `import_epub` branches

- **Where:** `api/service.py`, `MirageService.run_command` — set-membership branch (`action in {"import", "import_epub"}`) ~line 827
  vs standalone branch (`action == "import_epub"`) ~line 920.
- **Divergence:** payload handling — first accepts `title_guess`; second does not. Return shape — first returns the raw
  `import_epub` result (`status`, `units`, `book_id`, `edition_id`, `reused`, `series_hint`, optional `skipped_documents`);
  second returns a normalized summary (`book_id`, `edition_id`, `units`, `reused`, `status`) and drops `series_hint` /
  `skipped_documents`.
- **Impact:** latent contract drift; currently harmless only because behavior resolves through the standalone branch for the
  live RT action name. Hygiene/defect-class: **Low-Medium**, fix before P23 upgrade-era screening.
- **Note:** bare `"import"` remains accepted by the dispatcher family even though RT never sends it — doctrinal, not a defect.

### 5.4 RT-side integration gaps

| Gap | Source | Status |
|---|---|---|
| No `backup` wire action | ADR-4 (ledger placement & backup ownership) | Known limitation |
| TB-M0 gate (7 consecutive ledger days + tamper drill) | `docs/integration/tib/TB-M0-gate-plan.md` | Open |
| No Mirage performance-budget report for RT UX | — | Missing deliverable |
| Spoiler detail surfaces disabled pending countersigned chapter→unit calibration | ADR-7 (spoiler cursor contract) | Owner-gated pending |

---

## 6. Honest Unknowns — Not Covered by This Deep Dive

- **Recall on real books / fresh books:** unmeasured (the single most valuable remaining unknown; P22 plan).
- **Day-2 real library** (`~/Desktop/mirage testing day2`) absent → P20 hand-grade not yet triggerable.
- **On-device M3 numbers**, real `pipx` install outside the sandbox, post-freeze recall numbers — carried UNKNOWNs.
- **§45 UI truth batch (P19):** protocol/firewall/client byte-shipped; node-level uncertainty cosmetics cannot fire from real
  data (hardcoded node type/status/confidence; unstyled `.node-shape`); node selection and `projection()` were dead affordances.
- Linux `rss_mb` / OS-specific behavior beyond the misread — P18 item 5.

---

## 7. Prioritized Improvement Roadmap

### 7.1 This session (owner-authorized execution window)

| Order | Item | Rationale | Est. effort |
|---|---|---|---|
| 1 | **P18 trust-hardening batch** (all six verified items: Origin gate, SSE bounds, commit-before-delta, chain order, rss_mb, ALLOWED gate) + pins/adversarial tests | Highest owner value per deep audit; mechanical; keeps 316-test green | ~1–2 days |
| 2 | **Dispatcher dedupe** of the two `import_epub` branches into one contract (unify payload + return shape; pin with tests) | New finding from final deep-dive; small blast radius | ~0.5 day |
| 3 | **Capture Mirage performance-budget numbers** into a report for the RT UX band (from §2.4 envelope) | Closes the "no perf-budget report" gap | ~0.5 day (owner-gated run) |

### 7.2 Upcoming weeks (in owner-gated order)

| Order | Item | Trigger / gate |
|---|---|---|
| 1 | **P22 quality rounds P-017→P-022** + first post-freeze recall measurement: structural sentence-initial gating; tag-line dialogue (P-021); hedge/retraction (P-020); non-literal predication (P-022, object-lexicon-gated → P23); fresh-book recall measurement | Calibration gates must hold (tp 1.0) |
| 2 | **P19 UI truth batch** (§45 visual language in fact; tautology fix for node type/status/confidence; wire/remove dead affordances; render snapshots) | Engine stable |
| 3 | **TB-M0 gate** (7 consecutive ledger days + tamper drill) | Ops readiness |
| 4 | **P20 day-2 cohort** hand-grade (trigger: `~/Desktop/mirage testing day2` exists) | Owner directive |
| 5 | **P21 daily-driver**: Tauri shell, real pipx install, on-device M3 benchmark | After P20–P22 |

---

## 8. Verification Protocol per Roadmap Item

Per `docs/12-owner-test-authority.md` and `docs/method/07-testing-strategy.md`:

1. Engine change → full suite (316 + 3 Rust) + regression pins + census (229/0/10) on macOS 26 / Xcode 26.6.
2. RT change → targeted Mirage suites + combined-run isolation + stub lifecycle suites.
3. Owner gate → owner retest before any release claim; owner results outrank automated tests/docs.

---

## 9. References and Source Links

- `docs/integration/RT_Mirage_Codebase_Merge_Playbook.md`, `docs/integration/merge-log.md`, `docs/integration/final-acceptance-2026-10-18.md`
- docs/integration/adr/ADR-2…ADR-8, `ADR-12-titanium-bridge-charter.md`
- `docs/integration/tib/TB-M0-gate-plan.md`, `docs/integration/tib/observe-ledger.md`
- docs/product_era_plan.md (P18–P23), docs/problems.md (P-001…P-028), `docs/12-owner-test-authority.md`
- `/Users/johanrembeci/Desktop/MirageV1.0/src/miragev10/` (engine), `/Users/johanrembeci/Desktop/AsterismaV1.0/Features/Mirage/` (RT band)
- `/Users/johanrembeci/Desktop/AsterismaV1.0/docs/owner-test-results/2026-10-24-session-1.md` (F1–F3 owner findings)

---

## 10. 2026-10-29 addendum — warm engine and library scale (ADR-13)

This addendum records the post-deep-dive architecture change; it does not rewrite the
2026-10-28 evidence above.

- **Warm session.** `AsterismaV2.5/Features/Mirage/MirageEngineService.swift` owns one
  `MirageAnalyzeSession` for the app process and serializes requests through a FIFO gate.
  The sheet, the status check, and the batch runner all lease that one session; none of them
  spawn or tear down a process. Idle warm-down is 10 minutes, and the app's `.background`
  scene phase requests a stop. Disable still deletes nothing.
- **Library index.** `AsterismaV2.5/Features/Mirage/MirageLibraryIndex.swift` refreshes the
  whole inventory with one read-only `books_list`, writes `mirage/library-index.json`
  (`mirage-library-index@1`) atomically, and orphans active links whose edition vanished.
- **Batch queue.** `AsterismaV2.5/Features/Mirage/MirageBatchAnalyzer.swift` sequences EPUB
  jobs through the same one-book analyze path. Cancel is cooperative; retry re-queues only
  failed rows. The queue is session-scoped, not persisted across launches.
- **UI.** Settings ▸ Mirage is now a control center for warm/asleep engine state, coverage,
  scan freshness, and batch progress (`AsterismaV2.5/Features/Goals/SettingsRootView.swift`).
- **Decision record.** `docs/integration/adr/ADR-13-mirage-warm-engine-and-library-scale.md`
  supersedes ADR-6 decision 5 only. The wire, runtime ladder, ledger ownership, identity
  mapping, and spoiler-cursor contracts are unchanged.
- **Receipts (2026-10-29).** `./scripts/run-latest.sh --build-only` exited 0;
  `./scripts/census.sh --unit-only` exited 0 with **450 passed / 9 skipped / 0 failed**
  across **459 tests / 671 runs**. New pins: `MirageEngineServiceTests`,
  `MirageLibraryIndexTests`, `MirageBatchAnalyzerTests`.
- **Limits.** No owner acceptance run, no real-engine smoke test of the warm session in this
  session, and no remote CI run for this working tree. The opt-in real-engine suites remain
  environment-gated and were skipped by the census.

---

*End of MIRAGE-DEEP-DIVE-2026-10-28 (with 2026-10-29 addendum).*
