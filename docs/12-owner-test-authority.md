# 12 · Owner-Test Authority

**Status:** ACTIVE — absolute source of truth
**Effective:** 2026-10-24
**Owner:** Johan Rembeci

---

## The rule

Results from the owner's personal testing are the **highest-priority source of truth** for this project.

They override, for acceptance and truth-of-record:

- every previous benchmark and performance number;
- every automated census and test count;
- every gate receipt and release-candidate claim;
- every README, design note, graph report, or AI summary;
- any earlier acceptance decision.

If the owner's testing contradicts a document, **the document is wrong and must be corrected**. If the automated suite is green but the owner experiences a bug, **the bug is real**. “But the tests pass” is not a valid reply.

This rule is retroactive: once an owner result is recorded, it outranks all earlier benchmarks and claims, including the 212/0/9 census and the G8 acceptance receipt.

---

## What counts as an owner result

- Manual use on the owner's Mac: launch, import, read, page-turn, notes, collections, quit/relaunch, library integrity, performance feel, crashes, UI problems, and data loss.
- Optional-feature checks such as Mirage behavior.
- Any observed mismatch between what the app does and what the documentation says.
- A spoken or chat report also counts; it should be written down as soon as practical, but the lack of a written record does not downgrade it.

---

## Precedence order

1. **Newest recorded owner result** — the current truth.
2. **Live app behavior and live library data** — what actually happened.
3. **Automated census and benchmarks** — useful early warning, subordinate evidence.
4. **Historical documents, graph reports, and AI summaries** — context only.

When two owner results conflict, the newer one wins unless the owner says otherwise.

---

## How to run a session

### Option A — Release package (recommended for acceptance)

Test the thing you would actually ship, including the embedded Mirage runtime
and the Release build:

```bash
cd /Users/johanrembeci/Desktop/AsterismaV1.0
rm -rf /tmp/asterisma-owner-test
mkdir -p /tmp/asterisma-owner-test
ditto -x -k dist/AsterismaV2.5-2.0-arm64.zip /tmp/asterisma-owner-test
open /tmp/asterisma-owner-test/AsterismaV2.5.app
```

To keep it for daily use, drag `AsterismaV2.5.app` from that folder to
`/Applications` and launch it normally. If macOS blocks the first launch,
right-click → Open.

### Option B — Xcode Run (for debugging)

Use this when you need the debugger, console logs, or the Developer Console
(⌘⇧D):

1. Open `AsterismaV2.5.xcodeproj`.
2. Select scheme `AsterismaV2.5`, destination **My Mac**.
3. Press ⌘R.

Or from the terminal:

```bash
xcodebuild build \
  -project "AsterismaV2.5.xcodeproj" \
  -scheme "AsterismaV2.5" \
  -configuration Debug \
  -destination 'platform=macOS'

open ~/Library/Developer/Xcode/DerivedData/AsterismaV2.5-*/Build/Products/Debug/AsterismaV2.5.app
```

Run **one copy at a time**. Both Debug and Release use the same live sandbox
library; two copies writing at once is not a supported test.

### Full automated suite (optional)

```bash
./scripts/census.sh
```

This is the repeatable regression check. It does not outrank your own results.

## Before testing: snapshot the live library

Quit the app first, then:

```bash
D="$HOME/Library/Containers/johan.Reading-Tracker/Data/Library/Application Support/Asterisma"
B="$HOME/Desktop/Asterisma-Backups/$(date +%F)-pre-owner-test"
mkdir -p "$B"
ditto "$D" "$B/Asterisma"
cd "$B" && find . -type f -print0 | xargs -0 shasum -a 256 > SHA256-MANIFEST.txt
```

The snapshot is outside the repo. It is the rollback source if a test damages
the live library. The owner deleted the earlier 2026-10-24 snapshots; this
command creates a fresh one only when you choose to run it. If you do not keep
local snapshots, make sure Time Machine or an external backup covers the live
`Asterisma/` directory.

## How results are recorded

1. Copy `docs/owner-test-results/TEMPLATE.md` to
   `docs/owner-test-results/<date>-session-<n>.md`.
2. Record the build tested, launch method, macOS version, data counts before and
   after, each test, expected vs actual, verdict, and evidence.
3. Commit the result file.
4. Tag the session when it closes:
   `owner-test-results-YYYY-MM-DD`.
5. A **FAIL** is a release blocker until it is fixed or explicitly waived by
   the owner.

The policy itself is pinned by the tag `owner-test-authority-2026-10-24`.
Actual results are pinned by their own session tags.

---

## Relationship to the automated suite

The census remains valuable: it catches regressions early and gives a repeatable
baseline. It is not the final judge. Owner testing is.

If an owner result exposes a gap the suite missed, the fix must include a named
regression test where practical — not a claim that the suite was already green.
