# Asterisma Rebrands — V1.0, V2.0, and V2.5

This file records the product-name changes. The V2.5 section is the current
identity; the V1.0 and V2.0 sections are historical receipts.

---

## V2.5 rename (2026-11-07) — current

| Layer | V2.5 value |
|---|---|
| Product / app bundle | `AsterismaV2.5.app` |
| Display name | `AsterismaV2.5` |
| Xcode project | `AsterismaV2.5.xcodeproj` |
| App target / scheme | `AsterismaV2.5` |
| Test targets | `AsterismaV2.5Tests`, `AsterismaV2.5UITests` |
| Swift module | `AsterismaV2_5` |
| App entry point | `AsterismaApp.swift` / `AsterismaApp` (unchanged type) |
| Source folder | `AsterismaV2.5/` |
| Entitlements | `AsterismaV2.5.entitlements` |
| Info.plist | `AsterismaV2.5-Info.plist` |
| Release package | `dist/AsterismaV2.5-<version>-arm64.zip` |
| Data root | `Application Support/Asterisma/` (unchanged) |
| Bundle identifier | `johan.Reading-Tracker` (unchanged, not user-visible) |
| Marketing version | 2.5 (build 2) |

The bundle identifier and data-directory name were deliberately **not**
renamed. The sandbox container is keyed by bundle identifier, and the library
lives under `Application Support/Asterisma/`; changing either would orphan the
existing library. Only the product, project, module, folder, and marketing
version moved.

**Verification.** `./scripts/census.sh --unit-only` ran under
`AsterismaV2.5.xcodeproj` / scheme `AsterismaV2.5` and exited **0** with
**610 tests in 115 suites passed** (console) and **611 passed / 10 skipped /
0 failed / 621 total** (result bundle). The surface, comprehension, Markdown,
and whitespace gates all exited 0. No app launch or visual acceptance was
performed for this rename. The evidence archive
`AsterismaV2.0-Evidence-Archive-2026-11-07/` keeps its old name because it is a
frozen historical capture.

---

## V2.0 rename (2026-10-29) — historical

| Layer | V2.0 value |
|---|---|
| Product / app bundle | `AsterismaV2.0.app` |
| Display name | `AsterismaV2.0` |
| Xcode project | `AsterismaV2.0.xcodeproj` |
| App target / scheme | `AsterismaV2.0` |
| Test targets | `AsterismaV2.0Tests`, `AsterismaV2.0UITests` |
| Swift module | `AsterismaV2_0` |
| App entry point | `AsterismaApp.swift` / `AsterismaApp` (unchanged type) |
| Source folder | `AsterismaV2.0/` |
| Entitlements | `AsterismaV2.0.entitlements` |
| Info.plist | `AsterismaV2.0-Info.plist` |
| Release package | `dist/AsterismaV2.0-<version>-arm64.zip` |
| Data root | `Application Support/Asterisma/` (unchanged) |
| Bundle identifier | `johan.Reading-Tracker` (unchanged, not user-visible) |
| Marketing version | 2.0 (build 2) |

The rename was a working-tree change on 2026-10-29. Debug and Release builds
succeeded under `AsterismaV2.0.xcodeproj` / scheme `AsterismaV2.0`; the unit
census at that boundary was **432 tests / 671 runs / 423 passed / 9 skipped /
0 failed**; the surface and comprehension gates passed. Those figures are the
2026-10-29 receipt, not the current census. The V2.5 rename above superseded
this identity on 2026-11-07.

---

## V1.0 rebrand (2026-10-24) — historical

**Date:** 2026-10-24
**Official product name:** **Asterisma**
**MVP build name:** **AsterismaV1.0**

---

### V1.0 — what changed

| Layer | New value |
|---|---|
| Product / app bundle | `AsterismaV1.0.app` |
| Display name | `AsterismaV1.0` |
| Xcode project | `AsterismaV1.0.xcodeproj` |
| App target / scheme | `AsterismaV1.0` |
| Test targets | `AsterismaV1.0Tests`, `AsterismaV1.0UITests` |
| Swift module | `AsterismaV1_0` |
| App entry point | `AsterismaApp.swift` / `AsterismaApp` |
| Source folder | `AsterismaV1.0/` |
| Entitlements | `AsterismaV1.0.entitlements` |
| Info.plist | `AsterismaV1.0-Info.plist` |
| Release package | `dist/AsterismaV1.0-<version>-arm64.zip` |
| Data root | `Application Support/Asterisma/` (auto-migrates from `ReadTracker/`) |
| User-facing copy | “AsterismaV1.0” |

## Deliberate MVP constraint: bundle identifier

The sandbox container is keyed by bundle identifier. Changing it would create a
new, empty container and orphan the current library. For the MVP:

- **Display/product name:** AsterismaV1.0
- **Internal bundle id:** `johan.Reading-Tracker` (unchanged, not user-visible)

A future distribution release should adopt `com.asterisma.app` with an explicit
container-migration plan (outside-sandbox copy or a security-scoped migration
helper). Do not change the bundle id casually.

## Data migration

`AppIdentity` moves the legacy data root in place on first launch:

```text
~/Library/Containers/johan.Reading-Tracker/Data/Library/Application Support/
  ReadTracker/  →  Asterisma/
```

The migration is:
- only performed when the new directory does not exist;
- a move first, then a copy fallback;
- leaves the legacy directory untouched if it cannot move/copy;
- never deletes user data.

The weather store migrates into the Asterisma root on next weather-service init.

## Verification

- Live migration run: `ReadTracker` removed, `Asterisma` created.
- SQLite counts after migration: **7 books / 292 sessions / 138,459 timings**.
- App launched successfully under `AsterismaV1.0.app`.
- Full rebrand census: **213 passed / 0 failed / 9 skipped** (222 cases), re-run
  on the merged `main`.
- Release package built, ad-hoc signed, and launch-smoked:
  `dist/AsterismaV1.0-1.0-arm64.zip`.

## Release receipt

- `main` fast-forwarded from `bafb9e9` to `aba8aa4` and pushed to GitHub.
- Release commit: `6da2d81`; tag: `asterisma-v1.0-mvp`.
- Latest ready build: app code `1c88ae5`; tag `asterisma-v1.0-ready-2026-10-26`
  (supersedes the `3bff002` polish candidate).
- Ready package SHA-256:
  `786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`.
- Canonical worktree: `/Users/johanrembeci/Desktop/AsterismaV1.0`.

## Rollback

The pre-rename snapshot was deleted by the owner on 2026-10-24:

```text
~/Desktop/Asterisma-Backups/2026-10-24-pre-rename/   (deleted)
```

There is no local data snapshot anymore. Use Time Machine or an external
backup if one exists, then check out `bedrock-g8` (the last pre-rebrand release
candidate) if needed.
