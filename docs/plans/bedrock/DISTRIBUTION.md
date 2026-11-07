# Local Distribution — AsterismaV2.5

## What the packaging script produces

- `dist/AsterismaV2.5-2.0-arm64.zip`
- Ad-hoc signed `AsterismaV2.5.app`
- SHA-256 checksum alongside the zip

This is a **local/friend build**, not a notarized App Store build.

**Last V1.0 release receipt (historical):** `main` at `aba8aa4`; release commit `6da2d81`, tag
`asterisma-v1.0-mvp`. Ready build app code `1c88ae5` (tag
`asterisma-v1.0-ready-2026-10-26`), package SHA-256:
`786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`.

## Friend install (one-time Gatekeeper step)

1. Download and unzip `AsterismaV2.5-2.0-arm64.zip`.
2. Drag `AsterismaV2.5.app` to `/Applications` (or run it from Downloads).
3. First launch: **right-click the app → Open → Open**.
   - Or run once:
     ```bash
     xattr -d com.apple.quarantine "/Applications/AsterismaV2.5.app"
     ```
4. Subsequent launches are normal double-click.

The “unidentified developer” warning is expected because the build is ad-hoc
signed and not notarized. Making it truly seamless requires a paid Apple
Developer account, Developer ID signing, and notarization. The code/bundle is
kept App Store-compatible so that upgrade is a signing/pipeline change, not a
rewrite.

The sandbox bundle identifier remains `johan.Reading-Tracker` for this build so
the existing container and library are preserved. A future Asterisma bundle ID
requires a dedicated container-migration release.

## Verification

```bash
cd dist
shasum -a 256 -c AsterismaV2.5-2.0-arm64.zip.sha256

# after unzipping / installing:
codesign --verify --deep --strict --verbose=2 "/Applications/AsterismaV2.5.app"
```

## Clean-account rehearsal

At Gate G2 we test:
- launch on a fresh macOS user account;
- first-run onboarding;
- import a PDF/EPUB;
- read and page-turn;
- quit and relaunch;
- verify the library persisted.

The clean-account rehearsal remains pending; the packaged-app launch smoke on
this Mac passed.
