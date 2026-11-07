# 07 · Asterisma Master Progression Roadmap

> **Status:** owner-directed execution plan, written 2026-11-07. This document
> is a plan, not shipped behavior. It does not claim that any phase below has
> started or passed. The literal session directive is recorded in
> [`AGENTS.md`](../../AGENTS.md#session-directive--2026-11-07-literal-owner-authored).
>
> **Baseline at the time of writing:** the plan baseline is `main` at `e69677a`;
> the docs commit is `84b0177` and does not change app code. The local unit census
> is **518 tests / 100 suites / 719 runs / 509 passed / 9 skipped / 0 failed**
> (`./scripts/census.sh --unit-only`, exit 0, 2026-11-07). Rename CI run
> `42332377245` is green. The docs run `42333251100` was still **in progress**
> when this revision was written; no phase execution starts until it is green.
>
> **Models in scope:** `opencode/glm-5.3-flash-free` (primary, free), then
> `openrouter/stealth/crouton-alpha` (handoff executor/reviewer), with
> `opencode/crouton-alpha-free` as the recorded fallback if OpenRouter refuses
> the request. Buffy is the orchestrator, integrator, verifier, and the only
> process allowed to commit or push.

---

## Contents

| § | Section |
|---|---|
| 0 | Executive summary |
| 1 | Baseline, scope, and constraints |
| 2 | Multi-LLM operating model |
| 3 | Parallel lanes and integration protocol |
| 4 | Phase map and progression gates |
| 5 | Phases P0–P14 |
| 6 | Work-package index |
| 7 | Resource allocation and the GLM-to-Crouton transition |
| 8 | Risk register and stop rules |
| 9 | Definition of done and release gates |
| 10 | What this roadmap deliberately does not do |
| 11 | First ten actions |

---

## 0 · Executive summary

Asterisma is no longer a prototype that needs a long list of isolated bug fixes.
It is a working macOS reading application with a real library, a reader, goals,
analytics, reports, Sentinel recovery, and Mirage integration. Its remaining
work is a sequence of **product capabilities, reliability programs, and release
gates**, not a pile of micro-tickets.

This roadmap therefore treats the multi-LLM environment as the production
system it is:

- **GLM-5.3 Flash free** is the primary builder for the first execution window.
  It gets the large, parallelizable work: reader annotations, library/import
  hardening, goals/analytics completion, persistence scaling, and the truth
  reconciliation that unblocks everything else.
- **Crouton Alpha** takes the second window: reliability, Mirage, UI/accessibility,
  distribution, Swift 6, performance, and independent review. It receives
  written work-package packets and already-verified interfaces, not verbal
  context.
- **Buffy** owns the control plane: worktree allocation, prompt packets,
  conflict resolution, integration, local verification, commit messages, pushes,
  CI watching, and the final truth audit. No agent commits or pushes.
- **The owner** owns product acceptance: the Library Recovery LR-G6 script, the
  Sentinel SG7 scenarios, reader/annotation feel, visual acceptance, signing
  credentials, and the release decision.

The plan has **15 phases (P0–P14)**, **15 progression gates (G0–G14)**, **15
milestones (M0–M14)**, and **74 work packages**. Work packages are deliberately
substantial: a package is a coherent capability or verification program, not a
one-line lint fix. Small correctness items are bundled into larger packages so
the roadmap does not fragment into busywork.

The central sequencing rule is simple: **build the interfaces that other
workstreams need first, then parallelize, then integrate at a gate.** The reader
annotation schema, the persistence boundary, the provider harness, the
worktree protocol, and the truth reconciliation are the five dependency roots.
Everything else hangs from them.

---

## 1 · Baseline, scope, and constraints

### 1.1 Verified baseline

| Fact | Value | Evidence |
|---|---|---|
| Branch and commit | `main` at `84b0177` (docs commit); plan baseline `e69677a` | `git rev-parse --short HEAD` |
| Local unit census | **518 tests / 100 suites / 719 runs / 509 passed / 9 skipped / 0 failed** | `./scripts/census.sh --unit-only`, exit 0, 2026-11-07 |
| Remote rename CI | run `42332377245`, **success** | `gh run view 42332377245` |
| Docs commit CI | run `42333251100`, **in progress at revision time** | `gh run view 42333251100` |
| Product identity | `AsterismaV2.0`, SwiftUI + AppKit, Swift 5 mode | `README.md` §2 |
| Persistence | SQLite summary store plus JSON compatibility surfaces | `AsterismaV2.0/Core/Storage/LibraryDatabase.swift` |
| Dependency policy | Two Swift packages: GRDB 7.11.1 and ZIPFoundation 0.9.20; Mirage is a bundled runtime | `README.md` §2, `Package.resolved` |
| Test policy | Swift Testing; census is the merge gate | `AGENTS.md`, `scripts/census.sh` |
| Known skips | 4 Mirage real-engine, 1 benchmark, 2 real-library SQLite parity, 2 live Open-Meteo | `README.md` §4 |

### 1.2 Open work this roadmap must absorb

The plan starts from the open-work list in `README.md` §5 and
`docs/registers/04-handoff.md`, then folds the stale roadmap items into the
appropriate phase. It does not reopen work that code already proves is done.

| Source item | Current state | Roadmap home |
|---|---|---|
| Library Recovery LR-G6 owner acceptance | Code complete, owner script pending | P5, G5 |
| Sentinel SG7 acceptance and holds | Holds recorded, manual scenarios pending | P5, G5 |
| Distribution hardening | Ad-hoc signed, not notarized | P8, G8 |
| Bundle-ID migration | Still `johan.Reading-Tracker` for container compatibility | P8, G8 |
| Swift 6 strict concurrency | The last recorded attempt reported 148 actor-isolation errors (inherited; `docs/plans/bedrock/gates/GATE-G7.md#L20`); P9.1 re-derives the exact baseline | P9, G9 |
| Reader selection highlights/quotes | Notes/tags/anchors exist; text selection is not wired | P1, G1 |
| Legacy/dead code cleanup | Some zero-caller fragments remain | P9, G9 |
| Mirage standing items | Observation cadence, perf budget, backup-surface gap | P6, G6 |
| Environment/Sentinel/console visual acceptance | No screenshot receipt; owner review pending | P7, G7 |
| Reading analytics Phase Zero → E4/E5 | E1–E3, E6, E7 executed 2026-10-29; E4 focus/visibility instrumentation and E5 73% session-record proof remain | P3, G3 |

The old remediation roadmap (`docs/roadmap/05-remediation-roadmap.md`) remains
the detailed defect ledger. It is not deleted or contradicted. Items already
implemented in code — the report generation token, privacy manifest, apple-events
entitlement, and F-12 rebind reset — are treated as **verify-and-close**, not
as new implementation work.

### 1.3 Non-negotiable constraints

1. **No agent pushes or commits.** Buffy integrates and commits only after a
   gate and a clean local verification.
2. **One writer per shared file.** Two agents may not edit `Book2.swift`,
   `DataStore3.swift`, `LibraryDatabase.swift`, `project.pbxproj`, or
   `docs/INDEX.md` at the same time.
3. **A worktree per work package.** Agent work happens in
   `../asterisma-worktrees/<wp-id>` or an OpenCode `--worktree`; the main tree is
   for integration and verification.
4. **No secret exposure.** Agents never receive API keys, tokens, or `.env`
   contents. Provider preflight uses the already configured OpenCode auth.
5. **No test weakening.** A failing test is fixed at the cause; it is never
   skipped, deleted, or suppressed to make a gate green.
6. **No mixed commits.** Feature work, remediation work, documentation work, and
   release packaging stay in separate commits.
7. **No truth drift.** Every edited `.md` gets a ledger row in
   `docs/registers/05-doc-audit.md`; present-tense claims need a receipt or a
   `SKIPPED` reason.
8. **No silent provider substitution.** If OpenRouter refuses a request, record
   the exact failure and use the documented Crouton fallback; do not quietly
   switch to another premium model.
9. **No phase skipping.** A phase gate is pass/fail. A partially complete phase
   can continue internally, but it cannot advance the release line.

---

## 2 · Multi-LLM operating model

### 2.1 Roles and administrator authority

| Role | Actor | Owns | May edit | May commit/push |
|---|---|---|---|---|
| Owner | Johan | Product acceptance, signing credentials, release decision | Any, by instruction | Yes, by instruction |
| Main administrator | Buffy | Every agent outcome and regression; work packets, worktrees, integration, verification, CI, docs truth | Main tree and worktrees | **Yes, Buffy only** |
| Primary builder | `opencode/glm-5.3-flash-free` | P0–P4 implementation and analysis | Its worktree only | No |
| Handoff builder/reviewer | `openrouter/stealth/crouton-alpha` | P5–P10 implementation, independent review | Its worktree only | No |
| Fallback builder | `opencode/crouton-alpha-free` | Same packets when OpenRouter is unavailable | Its worktree only | No |

**Administrator authority.** Buffy is the main administrator and the only
accountable process. The delegated models are workers, not peers: they may
execute an assigned packet and report, but they may not exercise judgment over
scope, safety, secrets, merges, or release state. A request from a builder is a
proposal, not a permission. Buffy may assign, pause, interrupt, inspect, or
terminate any session; deny any request; revert any change; and discard any
unmerged worktree. The default answer to an unplanned request is **no**. Every
regression, broken build, bad merge, or data-loss risk introduced by a delegated
model is Buffy's responsibility, not the model's.

### 2.2 Work-package contract

Every delegation uses this packet. A prompt that lacks any field is not ready to
send.

```text
WP ID:                 <phase>.<sequence> — <name>
Objective:             <one user-visible or gate-visible outcome>
Why:                   <the risk or capability this unlocks>
Baseline:              <commit SHA, current test receipt, relevant open item>
Inputs:                <files, interfaces, fixtures, prior gate receipts>
Allowed paths:         <exact directories/files the agent may edit>
Forbidden:             <paths and behaviors the agent must not touch>
Acceptance:            <observable behavior, not "looks good">
Verification:          <commands, focused tests, manual script>
Output:                <branch/worktree, diff summary, test log, unresolved questions>
Model:                 <exact handle>
Session budget:        <message ceiling and stop condition>
Stop authority:        Buffy may interrupt or terminate at any time; stop on request
Handoff:               <what must be written to disk before the session ends>
```

### 2.3 Work-package sizing

A work package should be large enough to matter and small enough to verify in
one session. The default target is **one coherent capability plus its tests**,
roughly 1–4 hours of agent work. If a packet needs more than one session, split
it at a **stable interface**, not at an arbitrary file boundary.

The following are **not** standalone work packages: a single nil-check, a single
warning, a one-line comment correction, a single test rename, a single color
tweak. Those ride inside the nearest capability package.

### 2.4 Prompts and evidence

Every agent run records:

- exact model handle and session ID;
- worktree path and starting commit;
- files changed;
- commands run and exit statuses;
- tests passed/failed/skipped;
- unresolved questions;
- the model's own summary, quoted only as model output, never as a verification
  receipt.

Buffy then re-runs the relevant verification locally. **An agent's claim that a
test passed is not a receipt.**

### 2.5 Provider preflight

Run once at the start of each execution window and again after any provider
error:

```bash
opencode models | rg 'opencode/glm-5.3-flash-free|openrouter/stealth/crouton-alpha|opencode/crouton-alpha-free'
opencode auth list
```

The exact handles must resolve. Then run a one-line smoke prompt through each
model before assigning real work. Record the session ID and outcome.

**Known provider constraint (2026-11-07):** two OpenRouter smoke requests were
refused with HTTP 402 because the requested completion ceiling exceeded the
available credit balance. The exact sessions are `ses_e4c052f0affeRdQlFgpLYdVnXD`
and `ses_e4c04fa4cffeLMbdGo53gJH56J`. This is a **credit** ceiling, not proof
that the daily request allocation is exhausted. The preflight must therefore
check both request access and the model's `max_tokens` fit; if it returns 402,
record the blocked request and use `opencode/crouton-alpha-free` rather than
retrying paid calls blindly. A minimal Crouton smoke on 2026-11-07
(`ses_e4bea78ddffetH7olv1j7NqkID`) returned `PREFLIGHT_OK` at cost 0, confirming
that the earlier 402 was a completion-ceiling fit issue rather than a blanket
request block. The fit check still applies.

### 2.6 Message accounting

OpenCode sessions are not an unlimited context. The owner's working estimate is
100–200 messages per window. This plan uses:

- **soft transition at 120 messages** — finish the current packet, write the
  handoff, stop starting new GLM packets;
- **hard transition at 160 messages** — no new GLM work; remaining reserve is
  for integration questions and diff review;
- **20-message reserve** — kept for the final integration and ambiguity checks.

Count from `opencode session export <session-id>` and the work-package ledger,
not from memory. A phase may not depend on context that exists only in a session
transcript.

### 2.7 Verification ladder

| Level | Check | When |
|---|---|---|
| L0 | Debug build (`xcodebuild build`) | Every work package before handoff |
| L1 | Focused tests for the touched subsystem | Every work package |
| L2 | Full unit census (`./scripts/census.sh --unit-only`) | Every phase gate |
| L3 | Owner visual/product script | Phases with user-facing changes |
| L4 | Release/notarization/clean-machine script | P8 and P13 |

The surface-manifest check (`./scripts/verify-sentinel-surface.sh`) and the
index validation (`python3 scripts/comprehension-bench.py --validate-only`) run
at every gate that changes a surface, a table, or a documentation anchor.

---

## 3 · Parallel lanes and integration protocol

### 3.1 Lanes

| Lane | Scope | Typical phases | Shared bottleneck |
|---|---|---|---|
| A — Reader | EPUB/PDF selection, annotations, navigation, export | P1 | Reader views, `Book2`, annotation schema |
| B — Library | Collections, import, relink, search, recovery UX | P2, P5 | `DataStore3`, `LibraryDatabase`, `project.pbxproj` |
| C — Intelligence | Goals, analytics, reports, achievements | P3 | Analytics engines, goal store, report views |
| D — Platform | Persistence, Swift 6, performance, distribution | P4, P8, P9, P10 | `PersistenceWriter`, concurrency annotations, signing |
| E — Reliability | Sentinel, Mirage, diagnostics, offline | P5, P6 | Probe catalog, Mirage boundary, recovery gate |
| F — Experience | UI/UX, accessibility, onboarding, docs | P7, P12 | Shared design tokens, `docs/INDEX.md` |

At most **three agents** are active at once: one builder per lane, no two in the
same shared file. Buffy runs the integration lane.

### 3.2 Dependency roots

These interfaces must land before aggressive parallelism:

1. **Annotation domain + schema** (P1.1) — EPUB and PDF selection both need it.
2. **Persistence boundary** (P4.1) — async saves and large-library tests need it.
3. **Provider harness** (P0.2) — every delegated packet needs a recorded session.
4. **Worktree protocol** (P0.3) — prevents agents from colliding on the main tree.
5. **Truth reconciliation** (P0.1) — prevents agents from rebuilding shipped work.

### 3.3 Worktree protocol

```bash
git worktree add ../asterisma-worktrees/wp-1-2 -b agent/wp-1-2 main
```

Agent work happens there. When the packet is complete:

1. Agent writes a handoff file inside the worktree
   (`.agent-handoff/<wp-id>.md`) with changed files, commands, tests, and open
   questions.
2. Buffy reviews the diff, not the agent's summary.
3. Buffy runs L0/L1 in the worktree.
4. Buffy merges only the reviewed files into `main`; generated artifacts and
   unrelated edits are not merged.
5. The worktree is removed after the merge; the branch is retained until the
   phase gate passes.

### 3.4 Integration windows

- **I1 (after P1.1):** schema and migration merge; reader lanes unblock.
- **I2 (after P2.2):** import and collection work merge; library lane unblocks.
- **I3 (after P3.3):** analytics and goals merge; report/achievement work
  unblocks.
- **I4 (after P4.3):** persistence and scale merge; performance work unblocks.
- **I5 (after P6.4):** Mirage and Sentinel merge; release-readiness lane unblocks.
- **I6 (after P10.4):** performance and Swift 6 merge; release candidate branch.

A merge window is a hard synchronization point: no new agent starts until the
full census is green in the integrated tree.

### 3.5 Conflict policy

- `project.pbxproj`: only Buffy edits it, in a single batch per phase.
- `Book2.swift` and `LibraryDatabase.swift`: one writer per phase; schema changes
  are announced in the phase packet before work starts.
- `docs/INDEX.md`: only Buffy edits it after the phase's docs are stable.
- If two agents produce conflicting implementations, Buffy chooses one, writes
  the decision in the phase handoff, and archives the other worktree; do not
  merge both.
- If an agent edits outside its allowed paths, touches a shared file without the
  announced writer slot, or cannot explain a change, Buffy terminates the
  session, preserves the worktree for inspection, and discards any unverified
  work before resuming.

---

## 4 · Phase map and progression gates

### 4.1 Dependency graph

```text
P0 Control plane
 ├──► P1 Reader annotations ──► P7 Experience ─────────────────────┐
 ├──► P2 Library/import ──────┘                                    │
 ├──► P3 Goals/analytics ──────────────────────────────────────────┤
 ├──► P4 Persistence/scale ──► P10 Performance                     │
 │        └──► P5 Sentinel/recovery ──► P8 Distribution ───────────┤
 ├──► P6 Mirage ────────────────────────────────────────────────────┤
 ├──► P9 Swift 6 ─────────────► P10 Performance                    │
 └──► P11 Quality ────────────► P12 Docs ──────────────────────────┴──► P13 Release
```

P0 and P1 are the critical path. P4 feeds both P5 and P8; P5's recovery
receipts are an input to P8. P8 and P13 have owner/credential dependencies and
must start early enough to absorb external delays. P6's clean-machine Mirage
smoke uses an ad-hoc package; Developer ID signing and notarization are P8.

### 4.2 Gate summary

Progression gates `G0–G14` are distinct from the inherited **Library Recovery**
gate, written `LR-G6` in this document (`docs/plans/library-recovery/G6.md`).

| Gate | Name | Pass condition (summary) | Evidence |
|---|---|---|---|
| G0 | Control plane | CI green, provider smoke recorded, baseline ledger written, stale items reconciled, administrator rule recorded in every packet | run ID, session IDs, `./scripts/census.sh --unit-only` |
| G1 | Reader annotation core | Highlight/note/quote create-edit-delete persists across relaunch in EPUB and PDF; focused tests; owner script | L1 + L2 + owner script |
| G2 | Library/import | Duplicate import is visible, relink works, collection bulk operations persist, 100-book fixture | L1 + L2 + fixture receipt |
| G3 | Goals/analytics | Goal editor round-trip, weekly streak, achievements gallery, report race guard | L1 + L2 + owner script |
| G4 | Persistence/scale | Save path has no main-actor disk I/O; 20-mutation storm produces one write; 10× fixture | L1 + L2 + benchmark |
| G5 | Sentinel/recovery | `LR-G6` owner script passes on a copied library; SG7 scenarios recorded; no critical issue | owner receipt + SG7 |
| G6 | Mirage | Warm engine, idle stop, batch cancel/retry, backup surface, spoiler-safe refusal | L1 + L2 + Mirage script |
| G7 | Experience | Owner visual acceptance at 900×640, 900×640+300 pt sidebar, 1200×780; accessibility audit | owner receipt |
| G8 | Distribution | Bundle-ID migration plan executed; Developer ID signed; notarized; clean-machine launch | notarization receipt + clean-Mac log |
| G9 | Swift 6/architecture | The last recorded 148 actor-isolation errors (`GATE-G7`) → 0; P9.1 re-derives the baseline; full census green; no behavior regression | build log + L2 |
| G10 | Performance | Baseline budgets measured; 10×/100× fixtures; no unexplained regression | benchmark report |
| G11 | Quality | Critical-path UI tests, fixture suite, 20 consecutive clean runs | CI receipts |
| G12 | Documentation | INDEX anchors resolve; full facts gate; touched docs audited | `--mode all`, audit ledger |
| G13 | Release candidate | RC gate, owner acceptance, signed/notarized package, release notes | tag + package SHA-256 |
| G14 | Evolution | Post-release owner feedback triaged; next debt list | owner session record |

### 4.3 Milestones

| Milestone | Meaning | Gate |
|---|---|---|
| M0 | Trustworthy control plane | G0 |
| M1 | Reader annotations are real | G1 |
| M2 | Library/import is safe at scale | G2 |
| M3 | Goals and reports are coherent | G3 |
| M4 | Persistence scales without freezes | G4 |
| M5 | Recovery and Sentinel are owner-accepted | G5 |
| M6 | Mirage is operationally complete | G6 |
| M7 | The product feels finished | G7 |
| M8 | A stranger can install it | G8 |
| M9 | The codebase is Swift 6-ready | G9 |
| M10 | Performance is measured, not guessed | G10 |
| M11 | The test system catches regressions | G11 |
| M12 | The docs are trustworthy | G12 |
| M13 | Release candidate | G13 |
| M14 | Post-release loop | G14 |

---

## 5 · Phases P0–P14

### P0 — Control plane, truth reconciliation, and provider preflight

**Window:** GLM-5.3 Flash. **Priority:** critical. **Gate:** G0.

**Objective.** Make the execution environment safe and truthful before any
feature work: reconcile the stale remediation claims, prove the model handles,
establish worktrees and the resource ledger, and record the baseline.

**Why it matters.** Parallel agents compound mistakes. If an agent rebuilds a
shipped feature or edits the main tree while another agent is working, the cost
is larger than any single bug. P0 is the cheapest possible insurance.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-0.1 | Open-work reconciliation: map every README/handoff/roadmap open item to code, and mark implemented items `verify-and-close` | GLM | — | with 0.2 |
| WP-0.2 | Provider preflight and resource ledger: exact handles, smoke sessions, message/request accounting template | Buffy | — | with 0.1 |
| WP-0.3 | Worktree and packet harness: branch naming, handoff file, merge checklist | GLM + Buffy | 0.2 | no |
| WP-0.4 | Baseline health gate: build, focused smoke, full census, surface/index checks | Buffy | 0.1 | no |
| WP-0.5 | Correctness truth bundle: close or correct the stale NA-3/NA-4/NA-5/F-12 claims with code receipts | GLM | 0.1 | with 0.3 |

**Validation gate G0**

- [x] Docs CI run `42333251100` is green; rename run `42332377245` is green.
- [x] `./scripts/verify-sentinel-surface.sh` exits 0.
- [x] `python3 scripts/comprehension-bench.py --validate-only` exits 0.
- [x] `./scripts/census.sh --unit-only` exits 0 with the baseline count.
- [x] GLM smoke session recorded with a session ID and a successful response.
- [x] Crouton preflight recorded, including the earlier 402 and the successful
  minimal smoke.
- [x] Every stale open item has a code path or an explicit "still open" receipt.
- [x] The worktree protocol and resource ledger exist in the repo.

**G0 receipt (2026-11-07):** Docs run `42333251100` success; rename run
`42332377245` success; surface exit 0; index validation exit 0; census exit 0
(**518 tests / 509 passed / 9 skipped / 0 failed / 719 runs**); GLM smoke
`ses_e4bea8366ffegZHg4pXCbazItP`; Crouton smoke
`ses_e4bea78ddffetH7olv1j7NqkID`; stale-item dispositions in
`docs/audits/2026-11-07-open-work-reconciliation.md`; worktree protocol in
`docs/roadmap/execution-harness.md`; resource ledger in
`docs/registers/06-resource-ledger.md`. **G0 passed.** P1.1 then merged in
`6e35429`; no other feature code has been merged.

**Exit criteria.** G0 passes; no feature code has been merged yet; the first
phase packet is ready for P1.

**Rollback.** P0 is documentation and harness work. If it fails, revert the
harness files only; do not touch app code.

---

### P1 — Reader Annotation Core

**Window:** GLM-5.3 Flash. **Priority:** highest user-facing. **Gate:** G1.

**Objective.** Make text selection, highlights, notes, and quotes first-class in
both EPUB and PDF readers, with durable storage, page anchors, navigation, and
export.

**Why it matters.** This is the largest visible capability gap in the product.
Notes, tags, page anchors, and collections already exist; the missing piece is
the selection-to-annotation loop. It also creates the data model that future
search, study, and export features depend on.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-1.1 | Annotation domain and schema: highlight, note, quote, color, page anchor, timestamps; migration and deletion semantics | GLM | P0 | no; root interface |
| WP-1.2 | EPUB selection bridge: JS selection capture, range serialization, restore after reflow, selection menu | GLM | 1.1 | with 1.3 |
| WP-1.3 | PDF selection bridge: PDFKit selection, page/rect anchor, restore across layouts | GLM | 1.1 | with 1.2 |
| WP-1.4 | Annotation UI: sidebar list, inline highlight, note editor, quote copy/export, filters | GLM | 1.2, 1.3 | no |
| WP-1.5 | Persistence, backup, and recovery: annotation rows in the store, export/import, orphan handling | GLM | 1.4 | with 1.6 |
| WP-1.6 | Accessibility and owner acceptance script: keyboard, VoiceOver labels, empty/error states, 10-step script | Crouton/GLM | 1.4 | with 1.5 |

**WP-1.1 receipt (2026-11-07): merged in `6e35429`.** `BookNote` now carries
nullable `selectedText`, `color`, and `anchor`; `NoteTag.quote` is appended
after the existing cases so every old raw value still decodes.
`AnnotationColor` is the five-color palette, and `BookNoteAnchor` is either
`.epub(chapterIndex:cfi:pageInChapter:)` or `.pdf(pageIndex:rect:)` with a
normalized rect. `LibraryDatabase` registers the `v2` migration, which adds
nullable `selected_text`, `color`, and `anchor_json` to `notes`, and both note
INSERT paths persist all three. The worktree build exited 0, six focused suites
passed **26 tests**, `git diff --check` exited 0, and the three `ALTER TABLE`
statements were applied to a populated v1 `notes` table in `sqlite3` with the
existing row preserved. G1's remaining boxes are the two reader bridges, the
annotation UI, and the owner script.

**WP-1.2/WP-1.3 receipts (2026-11-07): merged in `3a82d50` and `a010a72`.** The
EPUB bridge captures a settled selection in the chapter web view and reduces it
to `ch:<chapter>:<start>:<end>` plus the quote; the PDF bridge reads
`.PDFViewSelectionChanged` and reduces the selection to a page index plus a
crop-box-relative normalized rect. Both expose `onSelection`, clear on page
change, truncate at 4,000 characters, and leave the note schema untouched.
Review found one real defect in the PDF work: `PDFViewDelegate` declares no
selection callback, so the delegate method the model wrote could never fire.
Buffy replaced it with a `NotificationCenter` observer registered against the
view, added the teardown, and added a notification-path test. Seven EPUB
selection tests and six PDF geometry/anchor tests pass; the full census is
**536 tests / 527 passed / 9 skipped / 0 failed**.

**Crouton CR-1/CR-2 receipts (2026-11-07).** Crouton ran alongside the GLM
builders: CR-1 reviewed the merged tranche as code, CR-2 designed WP-1.4. CR-1's
three S1 findings were confirmed by Buffy and fixed in `98aaaf3` — chapter-
absolute EPUB offsets clamped to the quote length, a multi-page PDF quote paired
with a first-page rect, and an unknown `Quote` tag that could make the library
unreadable after a downgrade. Four further findings are deferred with reasons in
`docs/audits/2026-11-07-cr1-annotation-review.md`; two are assigned to WP-1.4.
The census after the fixes is **537 tests / 528 passed / 9 skipped / 0 failed**.

**WP-1.4 receipt (2026-11-07).** GLM session `ses_e4b97d907ffe7MZavRdmhkB9bN`
wrote the factory, restore resolver, shared views, tests, and DataStore helpers,
then hit its free-message cap before wiring the EPUB coordinator or opening
`PDFReaderView2.swift`. Buffy kept what held up and finished the packet: the
EPUB coordinator members and an idempotent CSS-Highlight renderer with a
tap-to-edit bridge, clearing on deselection (closing CR-1 finding 4 for EPUB),
and PDF annotations resolved per page from page text with a click hit test, the
same action bar, and the same editor popover. One Swift `..<` parsing bug in
GLM's resolver was fixed. Debug build exit 0; 29 focused tests in 3 suites
passed; full census exit 0 at **557 tests / 548 passed / 9 skipped / 0 failed**
(`rt-census-20261107-002415.xcresult`). No live reader run or owner visual pass
exists; the EPUB renderer and PDF drawing are compiled and reviewed only.

**Bug hunt receipt (2026-11-07).** Two real defects fixed: a duplicate note id
aborted the library save and `payload_json` retained both copies (CR-1 finding
6; both INSERT sites now `INSERT OR REPLACE` and `writeBook` normalises notes
by id, pinned by `duplicateNoteIDDoesNotAbortSave`), and the library editor
overwrote `pageNumber` on anchored notes (CR-1 finding 7; editorial page now
applies only without an anchor). A red full-suite run was self-inflicted by two
concurrent `xcodebuild` runs and is explained in
`docs/audits/2026-11-07-bughunt-and-full-suite.md`. Clean full scheme exit 0,
**Passed**: 561 tests / 552 passed / 9 skipped / 0 failed / 721 runs; analyzer
exit 0; test isolation proves the real store byte-identical. No live reader run
and no annotation UI automation exist.

**Technical guardrails**

- Store annotation anchors as logical locators (chapter/CFI or page + normalized
  rect), not transient view coordinates.
- Never mutate the source EPUB/PDF. Annotations are a separate layer.
- Deleting a book must not delete its annotations silently; the recovery path
  must offer export or cascade with an explicit confirmation.
- EPUB reflow changes must restore highlights without duplicating them.
- PDF facing/continuous layouts must map the same annotation to the correct
  visible page.
- All writes go through the existing persistence boundary; no new JSON store.

**Validation gate G1**

- [ ] Create, edit, delete a highlight in EPUB; relaunch; it is intact.
- [ ] Create, edit, delete a highlight in PDF; relaunch; it is intact.
- [ ] Restore after changing EPUB font size and PDF layout; no drift or duplicate.
- [ ] Note editor saves; quote copy produces the selected text plus page/chapter.
- [ ] 50 create/delete cycles produce no orphaned rows in the store.
- [x] Focused tests for schema, serialization, and anchor restore pass: 29
      tests in 3 suites, exit 0, on the WP-1.4 code.
- [ ] Full census is green (557 / 548 / 9 / 0, run `42342871417`), but the owner
      10-step script is **written and not run**:
      `docs/audits/2026-11-07-g1-owner-script.md`. G1 cannot close on tests alone.

**Exit criteria.** G1 passes; the annotation schema is frozen for P7 and P12;
no reader regression in the existing appearance tests.

**Rollback.** Disable the annotation surface behind a feature flag if the schema
migration fails; do not ship a partial migration.

---

### P2 — Library, Import, and Recovery UX

**Window:** GLM-5.3 Flash. **Priority:** high. **Gate:** G2.

**Objective.** Turn library management from a set of working APIs into a safe,
legible workflow at 100+ books: duplicate handling, metadata repair, relinking,
collection operations, and search/sort/filter.

**Why it matters.** The store can hold a real library, but silent duplicate
imports and missing-file states are trust failures. A reader who imports the
same book twice should see a clear choice, not a silent no-op.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-2.1 | Collection operations: bulk move, remove, rename (already shipped), ordering, empty states | GLM | P0 | with 2.2 |
| WP-2.2 | Import intelligence v2: duplicate detection, conflict resolution sheet, metadata merge, import warnings | GLM | P0 | with 2.1 |
| WP-2.3 | Relink and missing-file recovery UX: locate, verify, relink, undo, batch repair | GLM | 2.2 | with 2.4 |
| WP-2.4 | Search/sort/filter and selected-book dock: tokenized search, stable sort, empty/error states | GLM | P0 | with 2.3 |
| WP-2.5 | 100-book fixture and integration gate | Crouton/Buffy | 2.1–2.4 | no |

**Validation gate G2**

- [ ] Importing a byte-identical book shows a duplicate choice with a cancel path.
- [ ] Importing a same-title/different-file book offers merge or keep-both.
- [ ] A missing file can be relinked; the book opens and the old sessions remain.
- [ ] Bulk collection operations persist and can be undone.
- [ ] Search/sort/filter work on a 100-book fixture without blocking the UI.
- [ ] Full census green; no silent import no-op remains.

**Exit criteria.** G2 passes; the 100-book fixture is committed as a test asset
or generated deterministically.

---

### P3 — Goals, Analytics, Reports, and Achievements

**Window:** GLM-5.3 Flash. **Priority:** high. **Gate:** G3.

**Objective.** Finish the goal/analytics loop so the numbers the app shows are
coherent, the goals are editable end-to-end, weekly streaks are earnable, and
the annual report cannot render stale data.

**Why it matters.** Analytics is the product's differentiator, but a dashboard
that shows an unreachable goal or a stale report destroys trust faster than a
missing feature. The report generation token and goals surfaces already exist in
part; this phase verifies, completes, and connects them.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-3.1 | Goals editor audit and completion: round-trip set/edit/reload; deadlines; status refresh | GLM | P0 | with 3.2 |
| WP-3.2 | Weekly streak and achievements gallery: weekGoalStreak detection, earn-once, gallery filters | GLM | 3.1 | with 3.3 |
| WP-3.3 | Analytics and report correctness: coverage score, confidence provenance, annual report race, data maturity | GLM | P0 | with 3.1 |
| WP-3.4 | Symbol-color and notification polish: settings integration, accessible labels, toast consistency | GLM | 3.1 | no |
| WP-3.5 | Analytics fixture and integration gate | Crouton/Buffy | 3.1–3.4 | no |

**Validation gate G3**

- [ ] Set a daily page goal; reload the store; dashboard reflects it.
- [ ] Seven consecutive qualifying days earn `weekGoalStreak` exactly once.
- [ ] An interleaved miss breaks the streak.
- [ ] Rapid year switching in Annual Reports always renders the newest selection.
- [ ] Coverage/confidence fields have a documented source, not a constant.
- [ ] Achievements gallery shows earned and unearned states without layout breaks.
- [ ] Full census green.

**Exit criteria.** G3 passes; stale "goals unreachable" and "report race" claims
are corrected in the defect register and fix log.

---

### P4 — Persistence, Scale, and Recovery

**Window:** GLM-5.3 Flash. **Priority:** high. **Gate:** G4.

**Objective.** Make the persistence layer scale without freezing the main actor,
without unbounded growth, and without losing the recovery guarantees the app
already earned.

**Why it matters.** The library is the user's years of reading history. The
current architecture is stable, but the roadmap's own scaling analysis says
10× volume starts to hurt and 100× volume dominates. This phase turns that
warning into measured behavior.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-4.1 | Async save boundary: capture values, encode/write off the main actor, preserve debounce and health banner | GLM | P0 | no; root interface |
| WP-4.2 | Pruning/archival policy: session/page-timing retention, backup retention, export before delete | GLM | 4.1 | with 4.3 |
| WP-4.3 | SQLite parity and migration: JSON compatibility, schema migrations, recovery path | GLM | 4.1 | with 4.2 |
| WP-4.4 | Large-library benchmark: 10×/100× fixtures, launch/save/analytics timings | GLM | 4.1 | with 4.5 |
| WP-4.5 | Save-storm and recovery integration gate | Crouton/Buffy | 4.1–4.4 | no |

**Validation gate G4**

- [ ] `scheduleSave()` performs no synchronous disk I/O on the main actor.
- [ ] 20 rapid mutations produce exactly one observable write cycle.
- [ ] A failed write still produces the existing degraded banner.
- [ ] 10× fixture opens, saves, and runs analytics without a freeze.
- [ ] Backup/restore round-trip preserves book, session, and annotation counts.
- [ ] Full census green; no data-loss regression.

**Exit criteria.** G4 passes; performance budgets from 4.4 become the baseline
for P10.

---

### P5 — Sentinel, Recovery, and Trust

**Window:** Crouton Alpha. **Priority:** high. **Gate:** G5.

**Objective.** Close the owner-facing reliability gates: Library Recovery LR-G6,
Sentinel SG7, diagnostics, redaction, offline behavior, and the holds that are
still explicitly open.

**Why it matters.** Sentinel is the app's trust layer. A green unit suite does
not prove that a human can recover a damaged library or understand a repair.
This phase converts code-complete recovery into owner-accepted recovery.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-5.1 | Library Recovery LR-G6 owner script: copied-library drill, restore, rollback, orphan repair (`docs/plans/library-recovery/G6.md`) | Crouton + owner | P4 | no |
| WP-5.2 | Sentinel SG7 scenario harness: ten manual scenarios, issue lifecycle, repair verification | Crouton | P0 | with 5.1 |
| WP-5.3 | Diagnostics/redaction/offline safety: export review, no secret leakage, offline session close | Crouton | 5.2 | with 5.4 |
| WP-5.4 | Localization/menu-bar/accessibility holds: narrow or close each SG7 hold explicitly | Crouton | 5.2 | with 5.3 |
| WP-5.5 | Reliability integration gate | Buffy | 5.1–5.4 | no |

**Validation gate G5**

- [ ] LR-G6 nine-step owner script passes on a copied library.
- [ ] Sentinel ten scenarios are recorded in `docs/owner-test-results/`.
- [ ] Diagnostics export contains no API keys, tokens, or raw personal text.
- [ ] Offline session close does not delay notifications or local analysis.
- [ ] Every SG7 hold is closed or explicitly narrowed with a reason.
- [ ] Full census green.

**Exit criteria.** G5 passes; the reliability claims in README/handoff match the
owner receipts.

---

### P6 — Mirage Operational Completeness

**Window:** Crouton Alpha. **Priority:** medium-high. **Gate:** G6.

**Objective.** Finish the Mirage operating model: warm-engine cadence, idle
teardown, batch cancel/retry, performance budget, backup surface, and spoiler
safety.

**Why it matters.** Mirage is optional, but it has a separate owner and a typed
boundary. An operational gap is both a product bug and an ownership violation.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-6.1 | Warm engine/observation cadence: start, reuse, idle stop, background behavior | Crouton | P0 | with 6.2 |
| WP-6.2 | Mirage performance budget and backup-surface gap: measured analysis time, backup ownership | Crouton | P0 | with 6.1 |
| WP-6.3 | Chapter-cursor mapping and spoiler safety: calibration gate, typed refusal, no leak | Crouton | 6.1 | with 6.4 |
| WP-6.4 | Ad-hoc packaging and clean-machine Mirage rehearsal: embedded runtime, ad-hoc signature, manifest; Developer ID/notarization is P8 | Crouton | 6.2 | with 6.3 |
| WP-6.5 | Mirage integration and owner gate | Buffy + owner | 6.1–6.4 | no |

**Validation gate G6**

- [ ] Start Mirage, run two analyses without a cold restart, idle stop.
- [ ] Batch cancel and retry-failed produce the documented states.
- [ ] No second sidecar lifecycle is spawned while one lives.
- [ ] Spoiler detail surfaces refuse safely until calibration is verified.
- [ ] Ad-hoc packaged app can run the Mirage smoke test on a clean account; Developer ID/notarized clean-machine launch is G8.
- [ ] Full census green; Mirage real-engine tests remain explicitly skipped.

**Exit criteria.** G6 passes; Mirage standing items are closed or moved to an
owner-approved maintenance list.

---

### P7 — Experience, Accessibility, and Onboarding

**Window:** Crouton Alpha. **Priority:** medium-high. **Gate:** G7.

**Objective.** Make the product feel finished: consistent design tokens,
accessible controls, keyboard navigation, onboarding, empty/error/loading states,
and owner visual acceptance of the Home/Library/reader shell.

**Why it matters.** The app's capability is ahead of its visual proof. The
existing UI tranches are compiled and unit-tested but not owner-accepted; this
phase closes that gap and prevents accessibility from becoming a release-week
scramble.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-7.1 | Design tokens and component consistency: spacing, type, color, focus, disabled states | Crouton | P1 | with 7.2 |
| WP-7.2 | Accessibility and keyboard: VoiceOver labels, focus order, contrast, shortcuts | Crouton | P1 | with 7.1 |
| WP-7.3 | Onboarding and first-run: import, goal, sample book, recovery explanation | Crouton | P2 | with 7.4 |
| WP-7.4 | Empty/error/loading states across Library, Reader, Goals, Reports, Sentinel | Crouton | P2 | with 7.3 |
| WP-7.5 | Owner visual acceptance at three window sizes | Buffy + owner | 7.1–7.4 | no |

**Validation gate G7**

- [ ] Owner reviews 900×640, 900×640 with 300 pt sidebar, 1200×780.
- [ ] No clipped labels, unreachable controls, or focus traps.
- [ ] VoiceOver reads every primary action; keyboard-only path works.
- [ ] First-run flow reaches a readable book without a dead end.
- [ ] Empty and error states are actionable, not blank.
- [ ] Screenshot or explicit owner receipt recorded.

**Exit criteria.** G7 passes; visual acceptance is no longer "pending" in the
docs.

---

### P8 — Distribution and Release Engineering

**Window:** Crouton Alpha + owner credentials. **Priority:** high (external
lead time). **Gate:** G8.

**Objective.** Make Asterisma installable by someone who is not the developer:
stable bundle identity, Developer ID signing, notarization, update path, privacy
and entitlement review, clean-machine rehearsal.

**Why it matters.** The current build is ad-hoc signed. This is the longest
external dependency in the plan (certificates, notarization, account setup), so
it starts before the code is otherwise release-perfect.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-8.1 | Bundle-ID and container migration plan: new ID, copy/migrate container, rollback | Crouton + owner | P4 | no |
| WP-8.2 | Developer ID signing and notarization pipeline: scripts, credentials, receipt | Crouton + owner | 8.1 | with 8.3 |
| WP-8.3 | Versioning/update path: semantic version, build number, update channel decision | Crouton | P0 | with 8.2 |
| WP-8.4 | Privacy/entitlement/security review: manifest, usage strings, sandbox, network | Crouton | P0 | with 8.1 |
| WP-8.5 | Clean-machine release rehearsal: install, launch, import, read, recover | Buffy + owner | 8.1–8.4 | no |

**Validation gate G8**

- [ ] A new bundle ID launches with a migrated copy of the existing library.
- [ ] Developer ID signature verifies; notarization ticket staples.
- [ ] Clean Mac launches with a normal double-click.
- [ ] Import, read, save, relaunch, and recovery all pass on the clean machine.
- [ ] No secret or development-only entitlement ships.
- [ ] Release script produces a reproducible package and checksum.

**Exit criteria.** G8 passes; the release package is genuinely distributable,
not just locally ad-hoc signed.

---

### P9 — Swift 6 and Architecture

**Window:** Crouton Alpha. **Priority:** medium (long arc). **Gate:** G9.

**Objective.** Move from Swift 5 mode to Swift 6 strict concurrency without
behavior regressions, while paying down the module, dependency, and dead-code
debt that blocks the flip.

**Why it matters.** The last recorded 148-error attempt
(`docs/plans/bedrock/gates/GATE-G7.md#L20`) is a concrete ceiling on future
concurrency work. Leaving it unresolved makes every new async feature more
expensive.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-9.1 | Error inventory and actor map: categorize the re-derived error inventory (last recorded: 148) by root cause and file owner | Crouton | P4 | no |
| WP-9.2 | Concurrency boundary fixes, batch 1: persistence, analytics, weather, discovery | Crouton | 9.1 | with 9.3 |
| WP-9.3 | Concurrency boundary fixes, batch 2: reader, Mirage, Sentinel, UI bridges | Crouton | 9.1 | with 9.2 |
| WP-9.4 | Module/dependency/dead-code cleanup: zero-caller fragments, duplicate utilities | Crouton | 9.1 | with 9.2 |
| WP-9.5 | Swift 6 flip and full validation | Buffy | 9.2–9.4 | no |

**Validation gate G9**

- [ ] `SWIFT_VERSION = 6` builds with zero actor-isolation errors.
- [ ] Full census green in Swift 6 mode.
- [ ] No behavior regression in reader, persistence, or Mirage.
- [ ] Dead-code deletions are listed with zero-caller proof.
- [ ] A documented rollback to Swift 5 mode exists if a blocking regression appears.

**Exit criteria.** G9 passes; the project no longer depends on Swift 5 mode.

---

### P10 — Performance and Scale

**Window:** Crouton Alpha. **Priority:** medium. **Gate:** G10.

**Objective.** Replace performance guesses with a repeatable benchmark harness
and measurable budgets for launch, save, analytics, reader, and large libraries.

**Why it matters.** The roadmap's scaling analysis is a warning, not a measurement.
This phase makes the warning actionable and prevents future work from silently
regressing the app.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-10.1 | Benchmark harness: fixtures, commands, machine metadata, report format | Crouton | P4 | no |
| WP-10.2 | Launch/memory/hot-path profile: startup, library load, analytics, reader | Crouton | 10.1 | with 10.3 |
| WP-10.3 | 10×/100× scale runs: save, search, analytics, report generation | Crouton | 10.1 | with 10.2 |
| WP-10.4 | Regression budget and dashboard: pass/fail thresholds tied to baseline | Crouton | 10.2, 10.3 | no |
| WP-10.5 | Performance integration and owner smoke | Buffy | 10.1–10.4 | no |

**Validation gate G10**

- [ ] Benchmark command runs on a clean checkout and records machine metadata.
- [ ] 10× and 100× fixture results are recorded, not inferred.
- [ ] Every budget has a baseline and a tolerance.
- [ ] No unexplained regression above the tolerance in the release path.
- [ ] The app remains responsive during the measured operations.

**Exit criteria.** G10 passes; performance claims in docs point to the benchmark
report, not to anecdotes.

---

### P11 — Quality and Test Maturity

**Window:** Buffy + Crouton review. **Priority:** medium. **Gate:** G11.

**Objective.** Expand verification beyond the unit census: critical-path UI
tests, deterministic fixtures, flaky-test control, and a CI matrix that catches
regressions agents cannot see.

**Why it matters.** Multi-agent work increases the chance of interface drift.
The test system must catch integration errors, not just unit-level mistakes.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-11.1 | UI test harness and fixtures: launch, import, read, annotate, recover | Crouton | P1, P2 | with 11.2 |
| WP-11.2 | Critical-path integration tests: persistence, recovery, Mirage boundary | Crouton | P4, P6 | with 11.1 |
| WP-11.3 | Flaky-test quarantine and CI matrix: repeat runs, failure capture | Crouton | P0 | with 11.1 |
| WP-11.4 | Coverage/quality metrics: critical-path coverage, test runtime, skip register | Crouton | 11.1–11.3 | no |
| WP-11.5 | Quality gate integration | Buffy | 11.1–11.4 | no |

**Validation gate G11**

- [ ] Critical-path UI tests run in CI or a documented local harness.
- [ ] 20 consecutive census runs have no unexplained flake.
- [ ] Every skip has an owner and a reason.
- [ ] Test runtime stays within the agreed budget.
- [ ] The release path has an end-to-end test, not only unit coverage.

**Exit criteria.** G11 passes; the test system is trustworthy enough to support
release candidates.

---

### P12 — Documentation and Knowledge System

**Window:** Buffy + Crouton review. **Priority:** medium. **Gate:** G12.

**Objective.** Keep the repo's documentation truthful, one-hop navigable, and
current after the feature and architecture work.

**Why it matters.** This repository treats a Markdown claim as a defect when it
is unsupported. The roadmap adds many new interfaces, phases, and receipts; the
docs must not drift.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-12.1 | Truth audit and INDEX refresh: every touched doc, anchor, count, receipt | Buffy | P1–P11 | no |
| WP-12.2 | ADR/runbook consolidation: architecture decisions, recovery, release, provider harness | Crouton | P1–P11 | with 12.3 |
| WP-12.3 | Handoff/release-notes template: current state, next actions, known gaps | Crouton | P1–P11 | with 12.2 |
| WP-12.4 | Onboarding/architecture guide: new contributor path, lane map, worktree protocol | Crouton | 12.2 | with 12.3 |
| WP-12.5 | Documentation gate | Buffy | 12.1–12.4 | no |

**Validation gate G12**

- [ ] `python3 scripts/comprehension-bench.py --validate-only` exits 0.
- [ ] `python3 scripts/comprehension-bench.py --mode all` exits 0 with zero
  fallbacks.
- [ ] Every edited Markdown file has an audit ledger row.
- [ ] Every phase receipt is linked from README or handoff.
- [ ] The graph is refreshed if code counts changed.

**Exit criteria.** G12 passes; the docs describe the shipped tree, not a past one.

---

### P13 — Release Candidate and Owner Acceptance

**Window:** Buffy + owner + Crouton review. **Priority:** critical. **Gate:** G13.

**Objective.** Freeze a release candidate, run the full product and distribution
gates, obtain owner acceptance, and publish a signed/notarized package.

**Why it matters.** This is the first point where all prior work is judged as a
product rather than as branches. It is deliberately late and deliberately
explicit.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-13.1 | RC freeze and full gate: build, census, surface, index, audit | Buffy | P1–P12 | no |
| WP-13.2 | Owner acceptance scripts: library recovery, Sentinel, reader, annotations, UI | Owner + Buffy | 13.1 | no |
| WP-13.3 | Package/sign/notarize: final artifact and checksum | Buffy + owner | P8 | with 13.2 |
| WP-13.4 | Release notes, tag, and publication record | Buffy | 13.2, 13.3 | no |
| WP-13.5 | Post-release verification: clean install, first-run, update path | Buffy + owner | 13.4 | no |

**Validation gate G13**

- [ ] RC commit is frozen; no unreviewed changes after the freeze.
- [ ] Full census green; surface and index gates green.
- [ ] Owner acceptance scripts signed off.
- [ ] Package is signed, notarized, checksummed, and launches on a clean Mac.
- [ ] Release notes list known limitations and skips honestly.
- [ ] Tag and push are separately approved by the owner.

**Exit criteria.** G13 passes; the release is shipped or explicitly held with a
written reason.

---

### P14 — Post-Release Evolution

**Window:** Buffy + Crouton review. **Priority:** low. **Gate:** G14.

**Objective.** Turn owner feedback and real usage into the next roadmap without
reopening the release line.

**Why it matters.** A release is a checkpoint, not the end. The app's value is in
the reading loop; post-release evidence should drive the next investment.

**Work packages**

| ID | Outcome | Model | Depends on | Parallel |
|---|---|---|---|---|
| WP-14.1 | Owner feedback triage: sessions, friction, missing capabilities | Buffy + owner | P13 | no |
| WP-14.2 | Debt/roadmap refresh: close, carry, or kill each open item | Crouton | 14.1 | with 14.3 |
| WP-14.3 | Maintenance cadence: security, dependency, backup, CI health | Crouton | 14.1 | with 14.2 |

**Validation gate G14**

- [ ] Owner feedback is recorded in `docs/owner-test-results/`.
- [ ] Every open item has a disposition: fix, defer with reason, or delete.
- [ ] The next roadmap is dated and linked from `docs/INDEX.md`.

**Exit criteria.** G14 passes; the next cycle starts from evidence, not memory.

---

## 6 · Work-package index

This index is the execution checklist. It is intentionally grouped by phase; a
work package is not a micro-task. The model column is the default; Buffy may
reassign within the same provider window if a packet is blocked.

| WP | Phase | Lane | Default model | Depends on |
|---|---|---|---|---|
| 0.1 | P0 | Truth | GLM | — |
| 0.2 | P0 | Control | Buffy | — |
| 0.3 | P0 | Control | GLM + Buffy | 0.2 |
| 0.4 | P0 | Control | Buffy | 0.1 |
| 0.5 | P0 | Truth | GLM | 0.1 |
| 1.1 | P1 | Reader | GLM | P0 |
| 1.2 | P1 | Reader | GLM | 1.1 |
| 1.3 | P1 | Reader | GLM | 1.1 |
| 1.4 | P1 | Reader | GLM | 1.2, 1.3 |
| 1.5 | P1 | Reader | GLM | 1.4 |
| 1.6 | P1 | Reader | Crouton/GLM | 1.4 |
| 2.1 | P2 | Library | GLM | P0 |
| 2.2 | P2 | Library | GLM | P0 |
| 2.3 | P2 | Library | GLM | 2.2 |
| 2.4 | P2 | Library | GLM | P0 |
| 2.5 | P2 | Library | Crouton/Buffy | 2.1–2.4 |
| 3.1 | P3 | Intelligence | GLM | P0 |
| 3.2 | P3 | Intelligence | GLM | 3.1 |
| 3.3 | P3 | Intelligence | GLM | P0 |
| 3.4 | P3 | Intelligence | GLM | 3.1 |
| 3.5 | P3 | Intelligence | Crouton/Buffy | 3.1–3.4 |
| 4.1 | P4 | Platform | GLM | P0 |
| 4.2 | P4 | Platform | GLM | 4.1 |
| 4.3 | P4 | Platform | GLM | 4.1 |
| 4.4 | P4 | Platform | GLM | 4.1 |
| 4.5 | P4 | Platform | Crouton/Buffy | 4.1–4.4 |
| 5.1 | P5 | Reliability | Crouton | P4 |
| 5.2 | P5 | Reliability | Crouton | P0 |
| 5.3 | P5 | Reliability | Crouton | 5.2 |
| 5.4 | P5 | Reliability | Crouton | 5.2 |
| 5.5 | P5 | Reliability | Buffy | 5.1–5.4 |
| 6.1 | P6 | Reliability | Crouton | P0 |
| 6.2 | P6 | Reliability | Crouton | P0 |
| 6.3 | P6 | Reliability | Crouton | 6.1 |
| 6.4 | P6 | Reliability | Crouton | 6.2 |
| 6.5 | P6 | Reliability | Buffy | 6.1–6.4 |
| 7.1 | P7 | Experience | Crouton | P1 |
| 7.2 | P7 | Experience | Crouton | P1 |
| 7.3 | P7 | Experience | Crouton | P2 |
| 7.4 | P7 | Experience | Crouton | P2 |
| 7.5 | P7 | Experience | Buffy + owner | 7.1–7.4 |
| 8.1 | P8 | Platform | Crouton + owner | P4 |
| 8.2 | P8 | Platform | Crouton + owner | 8.1 |
| 8.3 | P8 | Platform | Crouton | P0 |
| 8.4 | P8 | Platform | Crouton | P0 |
| 8.5 | P8 | Platform | Buffy + owner | 8.1–8.4 |
| 9.1 | P9 | Platform | Crouton | P4 |
| 9.2 | P9 | Platform | Crouton | 9.1 |
| 9.3 | P9 | Platform | Crouton | 9.1 |
| 9.4 | P9 | Platform | Crouton | 9.1 |
| 9.5 | P9 | Platform | Buffy | 9.2–9.4 |
| 10.1 | P10 | Platform | Crouton | P4 |
| 10.2 | P10 | Platform | Crouton | 10.1 |
| 10.3 | P10 | Platform | Crouton | 10.1 |
| 10.4 | P10 | Platform | Crouton | 10.2, 10.3 |
| 10.5 | P10 | Platform | Buffy | 10.1–10.4 |
| 11.1 | P11 | Quality | Crouton | P1, P2 |
| 11.2 | P11 | Quality | Crouton | P4, P6 |
| 11.3 | P11 | Quality | Crouton | P0 |
| 11.4 | P11 | Quality | Crouton | 11.1–11.3 |
| 11.5 | P11 | Quality | Buffy | 11.1–11.4 |
| 12.1 | P12 | Docs | Buffy | P1–P11 |
| 12.2 | P12 | Docs | Crouton | P1–P11 |
| 12.3 | P12 | Docs | Crouton | P1–P11 |
| 12.4 | P12 | Docs | Crouton | 12.2 |
| 12.5 | P12 | Docs | Buffy | 12.1–12.4 |
| 13.1 | P13 | Release | Buffy | P1–P12 |
| 13.2 | P13 | Release | Owner + Buffy | 13.1 |
| 13.3 | P13 | Release | Buffy + owner | P8 |
| 13.4 | P13 | Release | Buffy | 13.2, 13.3 |
| 13.5 | P13 | Release | Buffy + owner | 13.4 |
| 14.1 | P14 | Evolution | Buffy + owner | P13 |
| 14.2 | P14 | Evolution | Crouton | 14.1 |
| 14.3 | P14 | Evolution | Crouton | 14.1 |

---

## 7 · Resource allocation and the GLM-to-Crouton transition

### 7.1 GLM window

**Primary model:** `opencode/glm-5.3-flash-free`.

**Configuration rule:** use the exact free handle at the model's maximum
available context; do not select a smaller variant or a different provider. The
preflight records the model metadata and session ID. If the model cannot accept
a packet because of context size, split the packet at a stable interface rather
than silently downgrading.

**Scope:** P0–P4, plus any read-only audits needed by later phases.

**Message budget (planning estimate, not a measurement):**

| Phase | Work packages | Estimated messages | Stop condition |
|---|---|---:|---|
| P0 | 5 | 12 | G0 green; provider ledger written |
| P1 | 6 | 48 | G1 green; annotation schema frozen |
| P2 | 5 | 28 | G2 green; 100-book fixture |
| P3 | 5 | 24 | G3 green; analytics receipt |
| P4 | 5 | 28 | G4 green; benchmark baseline |
| Reserve | — | 20 | Integration/ambiguity only |
| **Total** | **26** | **160** | Hard transition |

The soft transition is **120 messages**: finish the current packet, write the
handoff, and stop starting new GLM packets. The hard transition is **160**.
These are inside the owner's 100–200 estimate and leave a reserve for
integration. Add two earlier checkpoints: at **80 messages**, finish the current
packet and re-plan; at **100 messages**, start no new GLM packet. If the measured
ceiling is 100 or lower, protect P1.1/P1.2 and move P2–P4 to Crouton rather than
blowing the cap mid-phase.

### 7.2 Transition gate T1

T1 is a real gate, not a calendar event. It passes only when:

- [ ] All in-flight GLM packets are merged or reverted; none are left in an
  unmerged worktree.
- [ ] The GLM session ledger lists every packet, session ID, message count, and
  outcome.
- [ ] `docs/registers/04-handoff.md` states the exact integrated commit and the
  first Crouton packet.
- [ ] The main tree is green at L2.
- [ ] No phase depends on an unwritten GLM conversation.
- [ ] Crouton preflight has succeeded, or the recorded fallback is active.

If T1 cannot pass, do not start Crouton work. Fix the integration first.

### 7.3 Crouton window

**Primary model:** `openrouter/stealth/crouton-alpha`.

**Fallback:** `opencode/crouton-alpha-free`, used only when OpenRouter returns a
recorded provider/quota refusal. The fallback is recorded in the work-package
ledger; it is not a silent substitution.

**Scope:** P5–P10, plus independent review of P1–P4.

**Request budget:** the owner states a 1,000-request daily allocation. This plan
reserves it as follows:

| Use | Share | Notes |
|---|---:|---|
| Implementation packets | 40% | P5–P10, one packet per session |
| Independent review | 25% | Diff/test review of GLM output |
| Verification/reproduction | 20% | Re-run a failing gate, inspect a regression |
| Reserve | 15% | Provider errors, owner questions, integration |

**Per-phase request ceilings (sum = 1,000):**

| Phase | Work packages | Request ceiling | Per-packet ceiling |
|---|---:|---:|---:|
| P5 | 5 | 70 | 14 |
| P6 | 5 | 70 | 14 |
| P7 | 5 | 60 | 12 |
| P8 | 5 | 80 | 16 |
| P9 | 5 | 80 | 16 |
| P10 | 5 | 40 | 8 |
| Independent review | — | 250 | — |
| Verification/reproduction | — | 200 | — |
| Reserve | — | 150 | — |

No packet may exceed **30 requests**. At **750 requests** (75% of the daily
allocation), stop starting new Crouton packets, finish the in-flight packet, and
hand the remainder to Buffy. The request allowance is not a credit guarantee.
The 2026-11-07 smoke attempts returned HTTP 402 when the completion ceiling
exceeded the available balance. Preflight must select a model/limit that fits,
or record the block and use the fallback. Do not retry a 402 with the same
request.

### 7.4 Final window

P11–P14 are Buffy-led, with Crouton used for independent review and the owner
for acceptance. The final window is deliberately slower: integration, docs
truth, release engineering, and acceptance are not parallelizable in the same
way as feature construction.

### 7.5 Daily execution loop

1. **Control block (Buffy):** check CI, provider preflight, worktrees, and the
   resource ledger; choose at most three packets.
2. **Build block A (GLM or Crouton):** one packet, one worktree, one handoff.
3. **Build block B (second lane):** a non-conflicting packet.
4. **Integration block (Buffy):** review diffs, run L0/L1, merge, update the
   ledger.
5. **Verification block:** run the phase's gate checks; if green, update docs and
   close the gate; if red, fix the cause and do not start a new phase.

No more than three agents are active at once. No agent starts a second packet
before its first handoff is written.

---

## 8 · Risk register and stop rules

| Risk | Early signal | Mitigation | Gate |
|---|---|---|---|
| GLM message cap reached mid-packet | Session count near 80, 100, or 120 | Checkpoints; soft/hard transition; written handoff; packet split at interface | T1 |
| OpenRouter 402/quota | Provider error in preflight | Fit max tokens, use fallback, record refusal; never blind retry | G0, T1 |
| Crouton daily allocation exhausted | 750 requests used or repeated 429 | Stop starting new packets; finish in-flight; Buffy takes the remainder | T1, P5–P10 |
| Agent edits outside scope | Diff touches forbidden paths | Worktree-only, allowed-path list, Buffy diff review; terminate and discard unverified work | Every packet |
| Agent breaks a shared interface or ignores a stop | Build/test failure after handoff; unexplained diff | Terminate the session, preserve the worktree, revert, re-run the gate; the assignment remains Buffy's responsibility | Every packet |
| Merge conflict in shared files | Two branches touch `Book2`/`DataStore3` | One writer per shared file; Buffy serializes schema edits | Every merge |
| Annotation data loss | Orphan rows or duplicate highlights | Schema migration test, 50-cycle create/delete, backup/restore | G1 |
| EPUB selection drift after reflow | Highlight rect moves | Logical anchors, reflow test at two font sizes | G1 |
| PDF layout mapping error | Highlight appears on wrong page | Page+normalized rect fixture across four layouts | G1 |
| Duplicate import still silent | No prompt on identical file | Conflict sheet, import warning test | G2 |
| Persistence freeze returns | Main-thread save time rises | Async boundary, save-storm test, 10× fixture | G4 |
| Migration corrupts library | Count mismatch after restore | Copy-first drill, rollback, recovery gate | G5 |
| Swift 6 cascade | Error count grows after fixes | Batch by root cause; keep Swift 5 rollback | G9 |
| Notarization delay | No certificate/ticket | Start P8 early; separate external blocker from code | G8 |
| Bundle-ID migration loses container | New app sees empty library | Copy/migrate/rollback plan; clean-machine test | G8 |
| Mirage ownership violation | RT writes Mirage ledger | Boundary tests; fail closed; owner review | G6 |
| Test flake | Same test passes/fails without change | Quarantine with owner, repeat-run receipt | G11 |
| Secret leakage | Key/token in prompt or log | No `.env` reads; redacted diagnostics; audit | Every packet |
| Documentation drift | Counts/anchors stale after merge | Audit ledger, INDEX gate, phase closeout | G12 |
| Over-parallelization | Agents waiting on each other | Three-agent cap; dependency roots first | Every phase |
| Owner acceptance bottleneck | Gate waits on owner | Schedule owner scripts at phase start, not end | G5, G7, G13 |

### Stop rules

Stop and escalate to the owner when:

- a gate fails twice for the same cause;
- an agent proposes weakening or deleting a test;
- an agent requests a capability, credential, path, or scope expansion (Buffy
  decides; default deny);
- an agent ignores or questions a stop instruction;
- a migration cannot be rolled back;
- a provider refusal cannot be resolved without new credentials;
- a change would alter the live user library without a copied-library drill;
- CI is red on `main` and the cause is not understood;
- two agents have produced incompatible schema designs.

A stop is not a failure. A silent workaround is.

---

## 9 · Definition of done and release gates

### 9.1 Phase definition of done

A phase is done only when:

1. Every work package is merged, reverted, or explicitly deferred with a reason.
2. The phase gate's checks have exact receipts (commands, exit status, session
   IDs, test counts).
3. The full unit census is green at the integrated commit.
4. Docs touched by the phase are updated and audited.
5. The next phase's dependency roots are available.
6. No agent worktree is left unmerged without a written disposition.

### 9.2 Product definition of done

Asterisma is ready for a release candidate when:

- A reader can import EPUB/PDF, read, annotate, search, set goals, and see
  accurate analytics without a dead end.
- The library survives relaunch, backup, restore, and a copied-library recovery
  drill.
- Sentinel and Mirage are owner-accepted or explicitly narrowed.
- The app is signed, notarized, and installable on a clean Mac.
- The codebase builds in Swift 6 mode.
- The release package has a checksum, a tag, and honest release notes.
- The owner has signed the acceptance record.

### 9.3 Release gate order

1. G13.1 RC freeze.
2. Full L2 + surface + index + doc audit.
3. Owner acceptance scripts (G5, G7, G13.2).
4. Package/sign/notarize (G8, G13.3).
5. Release notes/tag (G13.4).
6. Clean-install post-release check (G13.5).

A release candidate is not a release. The owner's separate commit/push approval
still applies to the release commit.

---

## 10 · What this roadmap deliberately does not do

- It does not treat every defect-register row as a standalone phase. Small
  correctness items are bundled into P0, P4, or P9.
- It does not assume unlimited premium models. GLM is primary; Crouton is the
  handoff; OpenRouter is request-budgeted and credit-checked.
- It does not let agents commit, push, or merge their own work.
- It does not replace the existing remediation roadmap or defect register; it
  sequences them.
- It does not promise a date. It promises gates and evidence.
- It does not claim that any phase is complete. The baseline is a plan, not a
  receipt.

---

## 11 · First ten actions

1. Confirm docs CI run `42333251100` and the execution-baseline census run are green.
2. Run the provider preflight for GLM, OpenRouter Crouton, and the Zen fallback;
   record session IDs and any 402.
3. Create the resource ledger and worktree directories.
4. Write the P0.1 open-work reconciliation table; mark shipped items
   `verify-and-close`.
5. Run the baseline health gate: build, focused smoke, full census, surface,
   index.
6. Freeze the annotation domain interface in P1.1 before any reader UI work.
7. Start P1.2 and P1.3 in parallel only after P1.1 merges.
8. Run the first integration window I1; do not start P1.4 until it is green.
9. At 120 GLM messages, write the transition handoff; at 160, stop new GLM work.
10. At T1, preflight Crouton and begin P5 with the reliability owner scripts.

---

*This roadmap is the plan of record for the 2026-11-07 progression session. It
does not become shipped behavior until a phase gate passes with a receipt.*
