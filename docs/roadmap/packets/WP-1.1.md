# WP-1.1 — Annotation domain and schema

**Status:** completed — accepted 2026-11-07
**Administrator:** Buffy
**Executor:** `opencode/glm-5.3-flash-free`
**Baseline:** `bd40080`
**Mode:** code writer, isolated worktree only

## Objective

Extend the existing `BookNote` model so a note can also represent a highlight or
quote with a durable logical anchor:

- optional `selectedText: String?`;
- optional `color: AnnotationColor?`;
- optional `anchor: BookNoteAnchor?`;
- `AnnotationColor`: `yellow`, `green`, `blue`, `pink`, `purple`;
- `BookNoteAnchor`: `.epub(chapterIndex: Int, cfi: String, pageInChapter: Int?)`
  or `.pdf(pageIndex: Int, rect: NormalizedRect)`;
- `NormalizedRect` stores `x`, `y`, `width`, `height` as `Double` in 0…1;
- add `NoteTag.quote` without removing or renaming existing tags;
- keep `pageNumber` for older notes and the current library UI;
- keep note deletion hard for P1.1; P1.5 owns export/orphan recovery.

The schema must accept every pre-P1.1 note without a migration failure. New
fields are optional and absent keys decode as `nil`.

## Allowed paths

- `AsterismaV2.0/Core/Book2.swift`
- `AsterismaV2.0/Core/Storage/LibraryDatabase.swift`
- `AsterismaV2.0Tests/Library/AnnotationSchemaTests.swift` (new file)
- `.agent-handoff/WP-1.1.md` in the worktree only

Do not touch `BookDetailsView.swift`, the readers, `DataStore3.swift`,
`project.pbxproj`, `AGENTS.md`, `README.md`, or any document outside the
worktree handoff.

## SQLite requirements

- Add a `v2` migration to `LibraryDatabase.migrator` that adds nullable
  `selected_text`, `color`, and `anchor_json` columns to `notes`.
- Update both existing note INSERT statements (import and save) to persist the
  new columns.
- Encode the anchor as JSON text. Keep the existing `books.payload_json` as the
  authoritative load path; the flat columns are parity/query fields.
- Do not add a second store or change the save debounce.

## Required tests

Create `AsterismaV2.0Tests/Library/AnnotationSchemaTests.swift` with:

1. A legacy `BookNote` JSON payload (only old keys) decodes with all new fields
   `nil`.
2. EPUB anchor round-trips through `JSONEncoder`/`JSONDecoder`.
3. PDF anchor round-trips, including normalized rect values.
4. A SQLite library save/reopen preserves `selectedText`, `color`, and both anchor
   shapes.
5. Existing tag values still decode; `.quote` is available.

Use temporary directories and delete them after each test. Keep the suite
`@MainActor` only where `DataStore` requires it.

## Acceptance

- `xcodebuild -project AsterismaV2.0.xcodeproj -scheme AsterismaV2.0 -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` exits 0.
- The focused annotation tests pass.
- `git diff --check` exits 0.
- No file outside the allowed paths changes.
- Handoff names the model session, files changed, commands, and any skipped
  check. Do not commit or push.

## Stop authority

Buffy may interrupt or terminate this session at any time, deny any request,
revert any change, and discard the worktree. Stop immediately if asked to exceed
the allowed paths, touch a secret, or change the save model.

## Acceptance receipt — 2026-11-07

**Merged in `6e35429`.**

The model's session ended without writing a handoff file, so Buffy reviewed the
worktree diff directly and reran every check in the main tree after applying it.

| Check | Command | Result |
|---|---|---|
| Build | `xcodebuild -project AsterismaV2.0.xcodeproj -scheme AsterismaV2.0 -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0, `** BUILD SUCCEEDED **` |
| Focused suites | `xcodebuild test` limited to `AnnotationSchemaTests`, `SQLiteFoundationTests`, `SQLiteDataStoreTests`, `SQLiteLoadIntegrityTests`, `SchemaEvolutionTests`, `LibraryRebuildAndRowRepairTests` | exit 0, **26 tests in 6 suites passed** |
| Whitespace | `git diff --check` | exit 0 |
| Migration DDL | `sqlite3` on a populated v1 `notes` table followed by the three `ALTER TABLE notes ADD COLUMN` statements | exit 0; the existing row survived with `selected_text`, `color`, and `anchor_json` `NULL` |

Three files changed, all inside the allowed paths. `project.pbxproj` was not
touched: the test target uses Xcode file-system-synchronized groups, so a new
file under `AsterismaV2.0Tests/Library/` joins the target automatically.

Deletion stays hard for P1.1 as specified. The repair path is safe: 
`LibraryRowRepairService` exports and re-inserts `SELECT rowid, *` rows
column-by-column, so `anchor_json` survives orphan export and undo without a
fixed column list. The authoritative load path remains `books.payload_json`;
the flat columns are parity/query fields.
