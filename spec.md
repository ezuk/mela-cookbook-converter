# Mela Recipe Importer

A native macOS app for AI-assisted parsing of DRM-free cookbook ePub files. The user picks the recipes they want, the app parses them with a locally installed LLM CLI, the user checks the results, and the app writes them out for the Mela recipe app.

Mela file format: https://mela.recipes/fileformat/index.html

## Decisions

| Topic | Decision |
|---|---|
| Audience | Personal tool. Not published, no App Store. |
| Distribution | Built and run locally, signed with my own developer certificate, App Sandbox off so the app can launch the CLIs with my normal login and settings. |
| Minimum macOS | 26 (Tahoe). Gives SwiftUI `WebView`/`WebPage`, Liquid Glass in standard controls, and Foundation Models if wanted later. |
| Books | One book at a time, no library. Open via File > Open, Open Recent, drag onto the window or Dock icon, or Open With in Finder. |
| Coming back | Reopening the same ePub restores its state (ticks, parse results, edits, export history) from a per-book store keyed by the book's identifier and file hash. |
| Engines | Claude Code first. Codex second, behind the same engine interface. One engine per parse run, chosen in Settings, with "Retry with the other engine" per recipe. |
| Wording | Keep the book's wording, units and language. No unit conversion, translation or rewriting. |
| Review gate | Recipes where every field was found in the book go straight to Approved. Anything flagged waits for my OK. |
| Export | One `.melarecipes` bundle per export, pending the Mela handoff test. |
| Order of work | Parsing spike on real books before the review screen design is final. Everything else can be designed now. |

## How it works

1. **Open and check the book** (code). Reject DRM, warn on scanned and fixed-layout books.
2. **Find recipes** (code, free). Read the whole book, not just the ToC, and build a list of recipe candidates grouped by chapter.
3. **Select** (UI). Tick recipes, chapters, search results.
4. **Parse** (LLM). Only ticked recipes. The model returns structured data that cites where each line came from.
5. **Check** (code). Verify every line and number against the book. Set each recipe's state.
6. **Review** (UI). Source page beside the parsed card, with flagged fields highlighted.
7. **Export** (code). The app, not the model, writes the Mela file.

## Challenge 1: UX

The app is fully native macOS and should feel lightweight, delightful and visual. Cooking is fun!

The visual design lives in a Claude Design canvas (the Design artifact type), not in this file. This section lists the screens and the behavior they must show.

### Screens

1. **Open a book.** Drop zone, Open button, Open Recent.
2. **Book can't be used.** DRM-locked, looks scanned, fixed layout, no recipes found (with a "pick by hand" path).
3. **Browse and select, Outline view.** Three-column window: sidebar filters, recipe outline with tri-state chapter checkboxes, detail pane showing the source page. Bottom bar with "N recipes ticked" and Parse.
4. **Browse and select, Gallery view.** Recipe cards grouped by chapter, using the book's photos, with a type-only card when there is no photo. Cmd-1 and Cmd-2 switch views; the choice is remembered per book.
5. **Search.** Scopes (Titles, Ingredients, Everything), results filtered in place with chapter headers kept, "Tick all N" and "Untick all N".
6. **Parse.** Confirm sheet (engine, count), then a queue with per-recipe states, cancel, retry, pause, and a paused-on-usage-limit state.
7. **Review.** Source page on the left, Mela-style card on the right. Clicking a field highlights where it came from. Each field is Found in book, Worked out, or Missing. Inline edits are marked as mine. Keyboard: arrows or J/K to move, Cmd-Return to approve, Cmd-R to re-parse.
8. **Export.** Sheet with options (chapter as category, book and page in the source field), then success with Show in Finder and an import tip.
9. **Settings > Engines.** Which CLIs were found, version, login state, default engine, API-key billing warning.

### Behavior the mocks must show

- **Highlight is not tick.** Click, shift-click and Cmd-click select rows like any Mac list. The checkbox means "import this". Space ticks or unticks all highlighted rows.
- **Chapters are tri-state.** Partly ticked shows a dash. Clicking a partly ticked chapter ticks all of it, clicking again unticks all.
- **Ticks survive search and filters.** Every bulk change can be undone with Cmd-Z.
- **Not-a-recipe sections** (intros, essays, basics, index) are hidden by default behind "Show all sections". Right-click to mark something as a recipe or not.
- **Low-confidence candidates** show dimmed with a "not sure this is a recipe" badge.
- **Sub-recipes.** A recipe that uses another one ("1 cup Basic Stock, page 212") shows "uses Basic Stock" with an offer to tick it too.
- **Review while parsing.** Finished recipes can be reviewed while others are still running.
- **Sidebar filters.** Ticked, Has photo, Parsed, Needs review, Failed, Not yet exported, Exported.
- **Photo strip in review.** Up to 3 candidate photos. Drag to reorder; the first is the main photo.
- **Exported badge.** Exported recipes show the date, and exporting one again warns until the repeat-id behavior is known.
- **Delight lives in the content.** Covers, the book's photos, small card animations. Toolbars and sidebars stay standard so Liquid Glass applies. Animations respect Reduce Motion.
- **Accessibility.** VoiceOver labels such as "Desserts, 4 of 12 ticked", full keyboard access.

## Challenge 2: Parsing the book

### Book checks on open

- **DRM.** Read `META-INF/encryption.xml`. Accept the book if the file is absent or every `EncryptionMethod` uses `http://www.idpf.org/2008/embedding` (IDPF font obfuscation, which the spec says is not encryption). Reject if any other algorithm appears, or if `META-INF/license.lcpl` (Readium LCP) or `META-INF/rights.xml` (reserved for DRM) exists. Test against my own DRM-free files, since other font-obfuscation methods or empty `encryption.xml` files may exist.
- **Scanned.** Count visible text per spine document. Almost no text means a scan: refuse in v1.
- **Fixed layout.** `rendition:layout` is `pre-paginated`: one page per file, so recipe ranges may be odd. Warn, don't block.

### Finding recipes (no LLM)

- Unzip with ZIPFoundation, read the OPF, walk the **spine** in reading order. Use `nav.xhtml` (EPUB 3) or fall back to `toc.ncx` (EPUB 2).
- Flatten every spine document into an ordered **block map**: headings, paragraphs, list items, table rows, images, `epub:type="pagebreak"` markers. Each block has a stable id (for example `ch05.xhtml#b0123`), its tag, class and text.
- A **recipe candidate** is a range of blocks. It can cross file boundaries. The block map feeds selection, the LLM input, the checks, source highlighting, page numbers, image choice and the cache key.
- Score candidate starts with cheap signals: ToC entries pointing inside a file, a heading followed by a list or by lines dense in quantities and units (½, g, ml, cup, tbsp), "Serves" or "Makes" lines, index entries pointing at the same anchors. Skip front and back matter. End each candidate at the next start.
- If a chapter is too ambiguous, an optional cheap LLM pass returns titles and block ranges only, never the recipe text.

### Parsing (LLM)

- Send the recipe as tagged lines, one block per line: `[b0123 li.ing] 2 tbsp unsalted butter`.
- The model fills the app's own **recipe draft** format, which is richer than Mela: title, headnote, yield, prep/cook/total as printed, ingredient groups, step groups, notes sections (tips, variations, make-ahead), nutrition, cross-references, start and end page, per-field flags. Every ingredient and step carries the block ids it came from.
- Fields the book doesn't state come back as `null`. Anything the model worked out is flagged as inferred.
- **One schema for both engines.** JSON Schema draft-07 (Claude rejects newer drafts), every property listed in `required`, `null` unions for missing values, `additionalProperties: false` on every object, no `allOf`/`not`/`if`/`then`/`else` (OpenAI strict mode rules).
- Later, if real books show consistent markup: learn a **layout profile** per book from 2 or 3 samples (selectors for title, ingredients, steps, etc.), apply it in code, and send only outliers to the model. Also later: batch several short recipes per call, since each call has fixed overhead.

### Checking (code)

After every parse, without an LLM:

1. Each ingredient and step nearly matches its cited blocks (after normalizing spaces, quotes and fractions like ½ vs 1/2).
2. Every number, range, temperature and time in the output appears in the recipe's source range.
3. Coverage: ingredient-like and method-like source blocks all ended up somewhere in the output.
4. Structure: a title, at least one ingredient, at least one step.

Any failure sets the recipe to Needs review and the review screen highlights the exact lines. One automatic retry feeds the failures back to the model.

### Recipe states

Waiting → Parsing → Checking → Approved, Needs review, or Failed (with a reason). Approved recipes can be Exported. Finished results are never re-sent to the model.

### Mapping to Mela

| Mela field | Source |
|---|---|
| `id` | UUIDv5 of (book identifier, ideally ISBN; spine href of the first block; anchor or block index). Never empty, stable across re-parses. |
| `title` | Recipe heading. |
| `text` | Headnote. Markdown links only. |
| `images` | Up to 3, JPEG or PNG at least 300 px per side, re-encoded to about 512 px long edge, best first (Mela uses the first as the main image). |
| `categories` | Chapter name, commas stripped (Mela forbids commas). Toggle at export. |
| `yield` | As printed. |
| `prepTime`, `cookTime`, `totalTime` | As printed. Empty if the book doesn't say. Inferred values are off by default. |
| `ingredients` | One per line. Sub-lists become `# Group` lines. |
| `instructions` | One step per line. Multi-part methods use `#` headers. |
| `notes` | Tips, variations, make-ahead, storage. A "See also" line for cross-references. |
| `nutrition` | If printed. |
| `link` | "Book Title, Author, p. 212" from the nearest page break, else the chapter. |
| `favorite`, `wantToCook`, `date` | Omitted. Mela ignores them on import. |

Cross-references like "(page 212)" are resolved in code through `page-list` or page-break markers, and written as the referenced recipe's title.

### Engine integration

Both CLIs are installed on this Mac in `~/.local/bin` (Claude Code 2.1.310, Codex 0.160.1) and both returned structured JSON from a script during research.

**Claude Code**

- Run: `claude -p --output-format json --json-schema '<schema>' --tools "" --no-session-persistence --max-turns 3 --max-budget-usd <cap>`, plus `--safe-mode`. For live progress, use `--output-format stream-json --verbose --include-partial-messages`.
- Read the answer from `structured_output`, not `result`. Treat a non-zero exit, `is_error: true`, any `error_*` subtype, or success without `structured_output` as failure. A logged-out run still reports subtype `success`.
- Never use `--bare`: it skips the Keychain login. The docs say bare will become the default for `-p` in a future release, so detect a broken login (init event's `apiKeySource`, "Not logged in") and pause cleanly.
- Remove `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` from the child environment, or runs silently bill the API key instead of the subscription.
- Run from an empty app-owned folder: without `--bare`, `-p` loads hooks and MCP servers from the working folder.
- Cancel with SIGINT (SIGTERM leaves the turn unfinished). A run can wait up to 10 minutes for background work.
- Login check: `claude auth status` prints JSON and exits 0 when logged in, 1 when not.

**Codex**

- Run: `codex exec --json --output-schema <file> -o <file> --ephemeral --skip-git-repo-check -s read-only --ignore-user-config -C <scratch folder>`. Pass `-s` explicitly: my user config overrides the read-only default.
- Set stdin to `/dev/null` or close it at once: Codex waits for stdin to close.
- Answer: `item.completed` with `item.type == agent_message`. Usage: `turn.completed`. Failure: `turn.failed` or a top-level `error`. Ignore `item.completed` events of type `error` (hook warnings).
- Login check: `codex login status`.

**Both**

- Finder-launched apps get `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Look for the binaries at absolute paths (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) and give each child an explicit PATH.
- Default 2 parses at a time (no documented limit). Pause the queue on usage limits instead of failing the batch. Claude emits `system/api_retry` events with an error category (`rate_limit`, `authentication_failed`, `billing_error`, `overloaded`).
- Show costs as estimates: `total_cost_usd` and Codex token counts are not billing data.
- Log both CLI versions at launch, skip unknown event types, and rerun a small live test set when a version changes.

### Rendering the source page

SwiftUI `WebPage` with a custom `URLSchemeHandler` that serves XHTML, CSS and images straight from the ePub zip. JavaScript off, network loads and navigation denied, so a book can't reach the network. Needs a spike: XHTML rendering this way is unverified.

### Storage

Per-book state lives in Application Support, keyed by book identifier and file hash: ticks, block map, parse cache (keyed by source hash, schema and prompt version, engine and model), raw engine output, check reports, my edits (stored separately so a re-parse shows a diff instead of wiping them), export history. A "Forget this book" command deletes all of it. CLIs run with `--no-session-persistence` and `--ephemeral` so they keep no transcripts.

### Code layout

The parser (ingest, detection, engine adapters, checks, Mela writer) lives in a UI-free Swift package with a command-line runner, for example `importer-eval book.epub --engine claude --recipes 1-20`. Raw engine outputs are saved as fixtures so most tests never call a model.

## Out of scope

Publishing or the App Store. A library of books. PDF, MOBI, Kindle. DRM books. Scanned books. Web recipes (Mela already imports those). Unit conversion and translation. Editing recipes after they're in Mela. Other export formats. iOS.

## Acceptance tests

1. Ticking a chapter and then unticking two recipes shows the chapter as mixed, and the count updates.
2. On each test book, the found-recipe list matches a hand-made answer key (target set after the spike).
3. Every exported ingredient line can be found in the source, or the recipe was flagged.
4. A recipe with no stated times exports with empty time fields.
5. The exported `.melarecipes` opens in Mela on the Mac, and sampled recipes show the right title, yield, grouped ingredients, steps and main photo.
6. Quitting mid-batch and reopening the book keeps finished results and doesn't re-send them.
7. With no CLI installed, the app still opens a book and allows selection; Parse explains the setup.
8. A book with LCP or non-font encryption is refused; a book with only font obfuscation opens.

## Phases

- **Phase 0, spike.** Parse about 10 recipes from each of 3 different DRM-free cookbooks with Claude, against a hand-checked answer key, with the jphastings tool (main branch) as a baseline. Test the Mela handoff with throwaway recipes. Confirm a Finder-launched build can run `claude` with its Keychain login. Try the `WebPage` source view on a real ePub.
- **Phase 1, MVP.** Open and check a book, find recipes, Outline view with tri-state selection, title search, parse with Claude, queue, review screen, `.melarecipes` export, per-book state.
- **Phase 2.** Codex engine, inline edits, photo picker, full-text search, re-export, layout profiles, batching.
- **Phase 3, delight.** Gallery polish, animations, Foundation Models for "is this a recipe?" checks, drag-out and Quick Look.

## Open questions (need a hands-on test)

- How a `.melarecipe` or `.melarecipes` file is opened in Mela on the Mac (double-click, Open With, drag, menu).
- What Mela does with a repeated `id` (update, duplicate or skip), which fields are actually required, and image size limits. The developer takes questions by email via mela.recipes/help.
- Whether `--safe-mode`, `--json-schema` and `--tools ""` work together (each was tested alone). Whether `--restricted` is a better fit and keeps the subscription login.
- Whether Codex `--output-schema` enforces strict rules on nested objects.
- Whether `WebPage` with a custom scheme renders `application/xhtml+xml` pages with their CSS and images, and can highlight a passage with content JavaScript off.
- What clicking a mixed `Toggle(_:sources:isOn:)` does by default.
- How real cookbook ePubs are structured: recipe-level or chapter-only ToC, recipes per file, class names, `page-list`.
- Foundation Models context size on this Mac (Apple sources say 4,096 or 8,192 tokens; read `contextSize` at runtime).

## Prior art

- **jphastings/mela-recipes** (Go, MIT). Mostly a converter between recipe app formats. Its main branch also extracts recipes from cookbook ePubs (`epub/` and `epub/induce/`, commits from Nov 2024 to Jul 2026), but the latest tagged release, v0.0.7 from May 2024, predates that. Ideas worth borrowing: a verbatim check that drops recipes it can't match to the source, and image filters (300 px minimum, max 3, 512 px JPEG). Proposes a `urn:isbn:...` id convention that Mela doesn't document.
- **IanDBallard/RecipeParser** (GPL-3.0). ePub or PDF to Paprika with Gemini, one call per chapter with a keyword pre-filter. Read for ideas only; copying code would bring GPL terms.
- **GiuseppeDM98/my-recipe-book.** PDF to recipes with Claude, Markdown output then a parser.
- **antass/miso.** Local macOS app to search ePub and MOBI cookbooks. No Mela export.
- **Mela itself** imports web pages, blog feeds, book pages scanned one at a time with the camera, and `.melarecipes`/`.paprikarecipes` files. No bulk ePub import.

## Sources

- Mela format: https://mela.recipes/fileformat/index.html
- Mela help: https://mela.recipes/help
- Claude Code headless: https://code.claude.com/docs/en/headless
- Claude Code CLI reference: https://code.claude.com/docs/en/cli-reference
- Claude structured outputs: https://code.claude.com/docs/en/agent-sdk/structured-outputs
- Claude auth: https://code.claude.com/docs/en/authentication
- Codex non-interactive mode: https://learn.chatgpt.com/docs/non-interactive-mode
- Codex events: https://raw.githubusercontent.com/openai/codex/main/codex-rs/exec/src/exec_events.rs
- OpenAI strict structured outputs: https://developers.openai.com/api/docs/guides/structured-outputs
- EPUB 3.3: https://www.w3.org/TR/epub-33/
- EPUB OCF (encryption, font obfuscation): https://idpf.org/epub/30/spec/epub30-ocf.html
- Readium LCP: https://readium.org/lcp-specs/releases/lcp/latest
- App Sandbox child processes: https://developer.apple.com/forums/thread/706390
- WebKit `WebPage`: https://developer.apple.com/documentation/webkit/webpage
- SwiftUI `Toggle(_:sources:isOn:)`: https://developer.apple.com/documentation/swiftui/toggle/init(_:sources:ison:)
- Foundation Models `contextSize`: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize
- Liquid Glass: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- jphastings/mela-recipes: https://github.com/jphastings/mela-recipes
