# Mela Importer

A personal macOS app that turns recipes from DRM-free cookbook ePubs into a `.melarecipes` file for [Mela](https://mela.recipes). It lists the cookbooks in your Calibre library, finds the recipes in a book without AI, parses the ones you tick with Claude Code or Codex, checks every line against the book, and saves the Mela export next to the ePub.

- [spec.md](spec.md): what the app does and why.
- [docs/reference-books.md](docs/reference-books.md): what three real cookbooks taught the parser.
- Design mockups: https://claude.ai/artifact/4yBVUR6QezqcJ4DiNLsTmq

## Layout

| Path | What |
|---|---|
| `Sources/MelaCore/EPUB` | Reading ePubs: tokenizer, package and ToC, DRM/scan/fixed-layout checks, block map |
| `Sources/MelaCore/Find` | Recipe finder: ingredient runs, learned title style, chapters, photos, sub-recipes |
| `Sources/MelaCore/Parse` | Recipe draft schema, prompt, checker, pipeline with cache and retry, queue |
| `Sources/MelaCore/Engines` | Claude Code and Codex adapters, process runner, CLI discovery |
| `Sources/MelaCore/Mela` | `.melarecipes` writer and photo resizing |
| `Sources/MelaCore/Calibre` | Read-only Calibre `metadata.db` reader |
| `Sources/MelaCore/Store` | Per-book state in Application Support |
| `Sources/importer-eval` | Command-line runner for testing on real books |
| `App/MelaImporter` | The SwiftUI app (macOS 26) |
| `scripts/build-app.sh` | Builds and signs `Mela Importer.app` |
| `tools/phase0` | The Python prototypes from the first study |

## Build the app (macOS 26, Xcode 26)

```sh
scripts/build-app.sh                  # build/Mela Importer.app, ad-hoc signed
INSTALL=1 scripts/build-app.sh        # also copy it to ~/Applications
SIGN_ID="Apple Development: you@example.com (TEAMID)" scripts/build-app.sh   # sign with your certificate
```

Or open `Package.swift` in Xcode and run the `MelaImporter` scheme. App Sandbox is off on purpose: the app runs the `claude` and `codex` CLIs with your normal login.

## Command line

```sh
swift build
.build/debug/importer-eval check  Book.epub
.build/debug/importer-eval find   Book.epub
.build/debug/importer-eval parse  Book.epub --recipes 1-10 --engine claude --model sonnet --out parsed
.build/debug/importer-eval export Book.epub --from parsed --out Book.melarecipes
.build/debug/importer-eval calibre ~/"Calibre Library" --tags cookbook,recipes --words kitchen
```

`parse` skips recipes it has already parsed (the cache lives in `parsed/cache`), so re-running only sends new or failed ones.

## Tests

```sh
swift test                                            # unit tests on synthetic books
MELA_TEST_BOOKS=/path/to/epubs swift test             # also runs the answer keys on the real books
```

The answer keys in `Tests/MelaCoreTests/Fixtures/answer-keys.json` list the recipe titles of the three reference books. The books themselves stay out of git.
