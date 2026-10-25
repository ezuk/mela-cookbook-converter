# What's left, and what needs your Mac

Everything below was built and tested in a Linux cloud container, which can compile and test MelaCore and the command line but not the macOS app. These are the steps only a Mac can do, in order.

## 1. Build the app (about 10 minutes)

```sh
git pull
scripts/build-app.sh           # or open Package.swift in Xcode and run MelaImporter
open "build/Mela Importer.app"
```

The app code has never been compiled. A review against the MelaCore sources and the macOS 26 SDK found and fixed one compile error and four runtime bugs, but expect a few more compile errors on the first build. They should be small, and a Claude Code session on the Mac can fix them in place.

## 2. Check these by hand

1. **Claude Code from a Finder-launched app.** Parse one recipe from the app, not from Terminal. If it says "not logged in", the Keychain login isn't reachable from the app; tell Claude.
2. **The book page view.** Open a book and select a recipe. The right pane should show the book's own page with its photos, scrolled to the recipe.
3. **Mela import.** Export a few recipes, put the `.melarecipes` file in iCloud Drive and open it from the Files app on your iPhone. Check the title, yield, grouped ingredients, steps and main photo. Then export one of them again and import it: does Mela update it or add a copy? Note the answer in the spec's open questions.
4. **Calibre.** After an export lands next to an ePub, run Calibre's Check Library, and rename that book in Calibre. If the export gets flagged or left behind, tell Claude: the fix is to register it as a Calibre format instead.
5. **Codex.** Never run live (it isn't installed in the cloud). Parse one recipe with Codex and check the model menu: it is a free-text field until the app learns Codex's model list.

## 3. Not built yet

- **AI recipe finder** for books where the code finds nothing. Today you mark recipes by hand from the book's headings.
- **Variations as their own recipes.** They stay in the parent recipe's notes.
- **Phase 3:** Foundation Models checks, drag-out and Quick Look, more animation.
- **A "this isn't a recipe" answer from the model**, so essays parsed by mistake fail instead of passing.
