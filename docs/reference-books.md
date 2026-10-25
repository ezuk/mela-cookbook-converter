# Reference books: what the parser has to handle

Three real DRM-free cookbook ePubs, studied for the Phase 0 spike. The books themselves are not in the repo (`*.epub` is git-ignored). Run the tools in `tools/phase0/` against an unzipped copy.

| | Cook It in Cast Iron | An Unapologetic Cookbook | Step-by-Step Instant Pot |
|---|---|---|---|
| Publisher | America's Test Kitchen | DK | Little, Brown |
| Origin | Calibre 6.6 conversion | Calibre 6.10 conversion | Calibre 6.8 conversion |
| Spine files | 360 | 273 | 413 |
| Images | 234 | 123 | 820 |
| `toc.ncx` | 16 entries, chapters only | 135 entries, one per recipe | 121 entries, one per recipe |
| Recipes (answer key) | 124, plus 19 variations | 114 ToC leaves | 103 ToC leaves, ~97 real recipes |
| Found by the prototype | 119 | 101 | 97 |
| Page numbers | `epub:type="pagebreak"` spans | none | `id="page-N"` anchors |
| `encryption.xml` | 8 fonts, Adobe obfuscation | 16 fonts, Adobe obfuscation | none |

## Findings that change the spec

1. **All three are Calibre conversions, and two have `encryption.xml`.** It lists only fonts, with `http://ns.adobe.com/pdf/enc#RC` (Adobe font obfuscation), not the IDPF algorithm. The DRM rule must accept Adobe font obfuscation when every encrypted URI is a font, or it refuses two of three real books.
2. **The ToC is not enough.** One book in three lists only chapters. That book has an in-book contents page per chapter whose links point at each recipe; links like that are a strong recipe-start signal when present.
3. **Class names mean nothing across books, but are consistent inside one.** Weissman's steps use `dedication_text` and its headnotes `tocentry`. Instant Pot's title is `h1.preface-title`. So hard-coded selectors are out, and a per-book layout profile learned automatically is in.
4. **A per-book layout profile can be learned without a model.** The prototype finds ingredient runs, then picks the block class that most often sits just before them as the title class. It got it right on all three books (`div.intro_head`, `h1.preface-title`, `p.b_head`) and found 88–96% of recipes with no LLM.
5. **Recipes span files.** Calibre splits one recipe into `partNNNN_split_000.html`, `_001`, … (title, ingredients, a second ingredient group, tips). The block map must flow across files, as the spec already says.
6. **Ingredient runs can mix classes.** Cast Iron alternates `il_item` and `il_item1` inside one list. A run is consecutive ingredient-like blocks, not one class.
7. **Some recipes have no ingredient list.** Weissman's soft-boiled eggs has title, times and numbered steps only. Title class + yield/time block + numbered steps should also count as a recipe. Most of the prototype's misses are this case or very short lists.
8. **Variations are their own entries.** Cast Iron has 19 (`cc_item_var`, "Tex-Mex Fondue" under "Beer and Cheddar Fondue"). Treat them like sub-recipes: listed under the parent, tickable, exported as their own recipe or as a note on the parent.
9. **Photos come in two kinds.** Instant Pot has a photo after nearly every step (820 images). The hero photo sits in its own file just before or after the recipe, with a caption equal to the recipe title (Cast Iron `p.caption_m`, Weissman `p.caption`). Pick the captioned, adjacent image as the main photo and skip step photos by default.
10. **Times and yields are split with `<br>` and spans** ("Prep Time<br/>15<br/>minutes"). Join with spaces when flattening, or numbers glue to labels.
11. **Page numbers are optional and come in three forms**: real `epub:type="pagebreak"`, bare `id="page-N"` anchors, or nothing. The source field falls back to the chapter, as the spec says. The index carries no print page numbers in these Calibre files.
12. **Section-only intros mark the end of a recipe.** Tips boxes ("JEFF'S TIPS", "WHY THIS RECIPE WORKS", "note:") belong in Mela notes, not in steps.

## Tools

- `tools/phase0/dump_blocks.py`: prints the block structure (tag.class | text) of one or more spine files.
- `tools/phase0/find_recipes.py`: the prototype finder. Prints ingredient runs, the learned title class, recipes found, and matches against the ToC or in-book contents.
