# 07 · Testing Strategy

## What this document is

This describes **what to build so the same classes of bug get caught automatically next time**, rather than by another full manual audit pass. Where other documents describe what is wrong, this describes how to prevent it from happening again.

**Who should read this:** Anyone who wants to write tests for the project, or understand how the project guards itself against regressions.

**Status:** Current as of the offline contract pass (2026-10-29), after Bedrock, the rebrand, repository reorganization, Sentinel v2, the UI shell tranches, reader customization, and offline hardening. The audit-era "step zero" (the test target running one placeholder) was resolved long ago: the suite is now real, wide, and enforced at every work boundary.

> **Precedence:** the automated census is a strong early-warning system, not the final judge. The owner's personal test results are the absolute source of truth and override every benchmark, census, gate receipt, and documentation claim. See `docs/12-owner-test-authority.md`.

---

## The test landscape today

| | |
|---|---|
| **Framework** | Swift Testing — `@Suite` / `@Test` / `#expect` (the project standardized after converting the original XCTest suites) |
| **Scale** | 82 Swift files in the test folder · 515 tests in 99 suites · 719 runs · responsibility-based groups plus Sentinel domain/runtime/catalog/persistence suites |
| **Standing census** | GitHub census run `40811182851` (2026-10-29, Xcode 26.6) passed the older **432 tests in 88 suites** before the V2.0 rename. The current local unit receipt records **515 tests / 719 runs / 506 passed / 9 skipped / 0 failed** in 99 suites (`./scripts/census.sh --unit-only`, exit 0; 2026-10-31), including five `CommandPaletteTests`, nine `ReaderAppearanceTests`, six offline/network pins, twelve ADR-13 Mirage pins, five environment/weather pins, four Book File Relink tests, one Phase Zero reading-analytics probe, and the 24 reading-analytics tests added by the recalibration. The older full UI-inclusive census was 450 tests / 673 runs / 441 passed / 9 skipped / 0 failed (not re-run for the ADR-13 tree). The workflow uploads the census log for its run. |
| **CI scope** | The deterministic unit target is the merge-presence receipt. UI tests are placeholder launch stubs and depend on interactive automation, so they are not part of CI. The bundled-runtime assertion self-gates on `.mirage-runtime` being staged. |
| **The 9 local skips** | 4 Mirage real-engine cases (identity import, handshake/health, and the two lifecycle steps), 1 benchmark, 2 real-library SQLite parity cases, and 2 live Open-Meteo cases. None are Sentinel coverage skips. CI may add a bundled-runtime presence skip on a clean checkout without the staged 47 MB runtime. |
| **Census discipline** | Every fixing session opens and closes on a green census; canonical numbers come from `xcrun xcresulttool get test-results summary --path <.xcresult>` — never from eyeballing the console |

---

## House conventions (pinned by practice)

1. **Harness-shared helpers live at the tests root** — e.g. `MirageStubSidecarSupport.swift` (temp-dir factory, scripted-transport double). A transport double that runs `#expect` inside the double is an accepted, precedented pattern.
2. **Suites serialize with `.serialized`** — tests that touch process machinery or shared singletons run one-at-a-time inside their suite.
3. **Runtime `Skip` is not supported by the runtime — use `.enabled(if:)`** for conditional suites. That is why the nine "skipped" census cases appear as skips: the gating is compile-time metadata, not a throw.
4. **Test-runner `print()` output lands in the xcresult, not in the xcodebuild console.** To capture diagnostics, read them from the `.xcresult` bundle or write to a file.
5. **Never pass `-derivedDataPath` on a Desktop/iCloud-synced checkout.** The iCloud File Provider stamp (`com.apple.fileprovider.fpfs#P`) on the derived-data tree breaks code signing outright (BUG-003). `.rt-dd` debris was deleted; default DerivedData is the standing rule — including in worktrees built outside the synced tree.
6. **Green census at every PR boundary** — one green default census per commit unit; at least one named suite per defect class.

---

## The Mirage integration band (added by the merge campaign)

The Mirage surface is tested as bands, mirroring the boundary's enforcement rules (`docs/integration/` is the campaign of record; the playbook's census receipts tie to these):

| Band | Suites | What they pin |
|---|---|---|
| **Wire conformance** | `MirageWire*Tests`-family | Every NDJSON shape — request lines, envelopes, malformed-line refusals, protocol version gates |
| **Process lifecycle** | `MirageSidecarLifecycleTests` | Spawn → banner → exchange → teardown; EOF/timeout/reap; SIGTERM→SIGKILL escalation; foreign-guard pid files |
| **Identity & drift** | `MirageIdentity*Tests` | Entry birth only from validated receipts; superseded-orphan transitions; crash-atomic writes; fail-closed on unknown schema |
| **Spoiler contract** | `MirageSpoilerProbeTests`, `MirageCursorContractTests` | Fail-closed refusal codes (`CURSOR-MISSING`, `SPOILER-CURSOR-UNVERIFIED`, `SPOILER-PROBE-REJECTED`); no unverified cursor is ever produced |
| **Feature lifecycle** | `MirageFeatureLifecycleTests` | One switch, disable-spawns-nothing, **disable-deletes-nothing (byte-identical)** |
| **Page-turn isolation** | `MiragePageTurnNonTriggerTests` | Reader navigation carries no Mirage machinery; analysis is gesture-only |
| **Bundled runtime** | `MirageBundledRuntimeTests` | Manifest strict decode, SHA-256 tamper refusals, the locator ladder (bundled → dev gate → nothing) |
| **Opt-in real-engine** | `MirageIdentityRealEngineImportTests`, `MirageRealEngineProxy…`, `MirageZBootDiagnosticTests` | The actual Python engine, spawned live for ONE lifecycle: real identity receipt, detail-free status, version/inventory exchange |

### Engaging the opt-in suites

```bash
# Real engine, one lifecycle, the proven dev channel:
TEST_RUNNER_MIRAGE_REAL_ENGINE_DIR=/path/to/MirageV1.0 \
xcodebuild test … -only-testing:"AsterismaV2.0Tests/MirageIdentityRealEngineImportTests"

# The standing M-027 boundary probe (only when deliberately hunting the machinery boundary):
TEST_RUNNER_MIRAGE_REAL_ENGINE_DIR=/path/to/MirageV1.0 \
TEST_RUNNER_MIRAGE_BOOT_DIAGNOSTIC=1 \
xcodebuild test … -only-testing:"AsterismaV2.0Tests/MirageZBootDiagnosticTests"
```

`-only-testing` matches Swift Testing type identifiers. The boot diagnostic uses the **disposable-data** path plus `MIRAGE_BOOT_DIAGNOSTIC=1`; the single-lifecycle doctrine holds even under it.

### Standing Mirage doctrine (same rules the code enforces)

- Entries are born **only** from validated `import_epub` receipts — a test may not invent a mapping.
- The engine's spawn contract is `<interpreter> <engine>/examples/mirage_sidecar.py <ledger>` on a disposable ledger; the real ledger is never touched by tests.
- The packaged runtime bundle must verify byte-verbatim: no test mutates the staged bundle except the whole-directory swap rehearsal.

---

## The Sentinel v2 band (2026-10-28)

Sentinel is tested in four layers, plus the product surface:

| Band | Suites | What they pin |
|---|---|---|
| **Domain laws** | `SentinelDomainTests` | Fingerprint stability, ordering, lifecycle edges, evidence, copy, diagnosis, trend |
| **Persistence** | `SentinelPersistenceTests` | Journal segments/checksums/rotation, v1 import, torn state fallback, issue rebuild, config migration |
| **Runtime** | `SentinelRuntimeTests` | One cycle lock, generation snapshots, timeout/failure isolation, coverage honesty, repair guards |
| **Catalog contract** | `SentinelCatalogTests` | Per descriptor: clean-install silence, determinism, privacy; damaged-fixture evidence; SQL fixtures; 50 ms fast-pass budget |
| **Repairs** | `SentinelLaunchAndRepairTests` | Launch-card states, executor refusal matrix, plan builders, rollback/undo, notification cap, diagnostics redaction |
| **Legacy pins** | `SentinelSG0Tests`, `SentinelPinsTests` | v1 security doctrine S1–S7 and write confinement |

The 414 parameterized probe-contract cases come from running three tests over all
138 descriptors. The catalog is designed so adding a probe automatically adds its
three contract cases. A new probe with no clean/determinism/privacy coverage is a
gate failure by construction.

Known test gaps are recorded in [SG7](../plans/sentinel/gates/SG7.md): no automated
accessibility pass, no 10× SQLite benchmark, and no per-repair fault injection for
all 25 plans.

## The reader customization band (2026-10-29)

The EPUB appearance model and PDF settings are pure-value types, so their
contracts are pinned without a UI runner:

| Suite | What it pins |
|---|---|
| `ReaderAppearanceTests` | WCAG AA contrast for all six themes, legacy theme migration, per-theme defaults, full settings-JSON injection, brightness clamping, PDF layout/fit mapping, page-gap margins, right-to-left presentation, and Original-font preservation |
| Browser harness (not CI) | Paged mode rendered 23 pages at 1280×720; scrolling mode rendered 21 viewport-pages; `goToPage(3)` landed at `scrollY = 2160`; switching back restored page 3 at `scrollLeft = 3840` |

The two new test functions in this pass are `pdfPageGap` and
`pdfReadingDirection`; the existing appearance pin was extended with
`readingMode`. The harness is a one-off check, not a standing CI job, so a
future JavaScript regression still needs a human or a new browser test.

## The offline contract band (2026-10-29)

Offline is treated as a product contract: the local library, readers, goals,
analytics, and settings must work with no route to the internet. The source
audit finds only four live network surfaces — Open-Meteo weather, Open Library,
Gutendex, and remote discovery cover images — and no `URLSession`, `Network`,
or `NWPathMonitor` use in the reader, library, goals, insights, engines, or
core groups.

| Suite | What it pins |
|---|---|
| `DiscoveryOfflineTests` | The discovery session is ephemeral, capped at 10 s per request / 15 s per resource, and never waits for connectivity. Both providers return an empty array quickly on `URLError.notConnectedToInternet`. Duplicate ISBNs are removed. Cancelling the search task cancels both in-flight provider requests. |
| `OpenMeteoProviderTests` (offline case) | An offline `URLError` is typed and propagated, never converted into fabricated weather; the request carries the same 10 s bound. |

The tests inject an `OfflineURLProtocol` and a short-timeout session, so they
never touch the real network. The full unit census after this band was **447
tests / 671 runs / 438 passed / 9 skipped / 0 failed** (Stage AB, historical;
the ADR-13 boundary is 459 / 671 / 450 / 9 / 0 in Stage AE; the Phase Zero
boundary was 469 / 671 / 460 / 9 / 0; the reading-analytics recalibration
boundary was 493 / 719 / 485 / 9 / 0; the current boundary after the 200-round
stress evaluation is **515 / 719 / 506 / 9 / 0**; the Stage AH environment
boundary remains 464 / 671 / 455 / 9 / 0).

**Limitation:** a whole-suite run under an OS-level network denial was attempted
with `sandbox-exec`; Xcode's test runner hung before establishing its connection,
and launching the already App-Sandboxed app directly trapped. That is recorded
as `SKIPPED`, not as an offline pass. The offline behavior is pinned at the
provider/session layer and by the source audit.

---

## What to cover, mapped to what's risky

The original audit-era table earned its keep: the risky classes it listed (persistence failure paths, multi-index deletes, toast FIFO, calendar math, observer lifecycle, SQLite transactions, celebration timers) are now all **covered and pinned by named suites** — that is what the census is made of. The current frontier of coverage:

1. **Mirage-era deltas (ledgered, not blocking):** a dedicated Mirage performance-budget report (spawn latency is measured; per-exchange paths have no standing regression budget); large-library soak beyond fixtures.
2. **RSVP edge conditions:** the feature ships (P5-B2); its tokenizer and pacing engine have production paths but only partial direct pins — worth a tokenizer-matrix suite before any format overhaul.
3. **Weather honesty (NEW-DE-7/8):** the missing coverage is the honesty behavior itself — coverage ratio and locale fallback are product decisions still pending, so their tests wait on the decision.
4. **BCE Phase-2:** dormant by product decision; its activation must arrive with its own band (see the register) or the scaffold must go.

---

## Example: the shape of a pin in this repo

```swift
// From the merge campaign — the disable-deletes-nothing pin:
@Suite("Mirage Feature Lifecycle", .serialized)
struct MirageFeatureLifecycleTests {
    @Test func disablingMirageDeletesNothing() throws {
        // Seed the stratum, toggle mirage.enabled OFF,
        // assert every stored byte is identical across the toggle.
    }
}
```

When you add a pin, name it after the defect or the contract it guards so the suite reads like the defect history — the standing examples are `TextExtractionTests` ↔ F-03, `NonGregorianCalendarTests` ↔ F-01, `CelebrationTimelineTests` ↔ F-02, `SentinelPinsTests` ↔ S1/S5, and the Mirage band ↔ the merge playbook's census receipts.
