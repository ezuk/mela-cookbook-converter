# Mela Importer: notes for Claude

Personal macOS 26 app: turns recipes from DRM-free cookbook ePubs (from the user's Calibre library) into `.melarecipes` files for Mela (used on iOS only). Not published. Read `spec.md` for decisions, `docs/reference-books.md` for what real books look like, `docs/next-steps.md` for what's left.

## Layout

- `Sources/MelaCore`: all logic, UI-free, builds and tests on Linux too. ePub reading, recipe finder (no LLM), parse pipeline (Claude Code / Codex CLIs, checker, cache, queue), Mela writer, Calibre reader, per-book store.
- `Sources/importer-eval`: CLI over MelaCore (`check`, `find`, `parse`, `export`, `calibre`).
- `App/MelaImporter`: SwiftUI app, Swift 5 language mode, macOS 26. Thin over MelaCore.
- `Tests/MelaCoreTests`: XCTest. `MELA_TEST_BOOKS=<dir of epubs> swift test` also runs answer keys on the three reference books (Weissman, Instant Pot, Cook It in Cast Iron).
- Design mockups: https://claude.ai/artifact/4yBVUR6QezqcJ4DiNLsTmq

## Build, run, test

```sh
swift build && swift test
scripts/build-app.sh && open "build/Mela Importer.app"   # or: swift run MelaImporter
```

To check UI changes, build, launch the app and use computer use to click through it. Keep logic in MelaCore with tests; keep the app thin.

## Rules that matter

- Keep the book's wording; the app, not the model, writes the Mela file.
- Never write to Calibre's metadata.db (read-only). Exports go next to the ePub.
- CLI runs: no `--bare` (it skips the Keychain login), strip ANTHROPIC_API_KEY from the child env, run in an empty scratch folder.
- Don't commit ePubs or parsed recipe text (copyrighted). `*.epub` is git-ignored.
- Bump `PromptBuilder.version` / `RecipeDraftSchema.version` when the prompt or schema changes (cache key).

## State (Oct 2026)

- Core done and tested: finder 99–100% recall on reference books; live parses 129/130 on a full book.
- App builds and runs on the Mac. Recently added, not yet checked on the Mac: Exclude on the home screen (right-click a book), and the detail pane's Recipe | Book Page switch (Recipe reads the whole recipe from the ePub, across split files).
- Not yet verified: Mela import on iPhone and repeat-id behavior, Calibre Check Library with exports in book folders, Codex live, Review screen on real parses.
