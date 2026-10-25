import Foundation

public enum RecipeConfidence: String, Codable, Sendable {
    case high      // ingredient list and steps
    case low       // only one of them: shown dimmed with "not sure this is a recipe"
}

/// A recipe found in the book, before any parsing.
public struct RecipeCandidate: Codable, Sendable, Identifiable, Equatable {
    /// Stable Mela id: UUIDv5 of (book key, first block id).
    public let id: String
    public var title: String
    public var chapter: String?
    /// Block range [start, end).
    public var start: Int
    public var end: Int
    public var page: String?
    public var confidence: RecipeConfidence
    /// Resolved zip paths, best first.
    public var photos: [String]
    /// Ids of other candidates this recipe uses ("1 cup Basic Stock, page 212").
    public var uses: [String]
    public var ingredientLines: Int
    public var stepLines: Int
    /// True when the user marked it by hand.
    public var manual: Bool = false
}

/// A titled part of the book that isn't a recipe (intro, essay, chart). Hidden behind "Show all sections".
public struct BookSection: Codable, Sendable, Equatable {
    public let title: String
    public let chapter: String?
    public let start: Int
    public let end: Int
}

/// What the finder learned about the book's markup.
public struct LayoutProfile: Codable, Sendable, Equatable {
    public var titleStyle: String
    public var ingredientStyles: [String]
}

public struct FindResult: Sendable {
    public var recipes: [RecipeCandidate]
    public var sections: [BookSection]
    public var profile: LayoutProfile?
    public var chapters: [String]
}

/// Manual corrections the user made in the browser, applied on top of the finder.
public struct FinderOverrides: Codable, Sendable, Equatable {
    /// Block indices the user marked as the start of a recipe.
    public var markedRecipeStarts: Set<Int> = []
    /// Candidate ids the user marked as not a recipe.
    public var notRecipes: Set<String> = []
    public init() {}
}

public enum RecipeFinder {
    static let minimumPhotoBytes = 12_000

    public static func find(package: EPUBPackage, map: BlockMap, overrides: FinderOverrides = FinderOverrides()) -> FindResult {
        let blocks = map.blocks
        guard !blocks.isEmpty else { return FindResult(recipes: [], sections: [], profile: nil, chapters: []) }
        let isIngredient = blocks.map { !$0.text.isEmpty && TextPatterns.isIngredient($0.text) }
        let isStep = blocks.map { TextPatterns.isStep($0.text) }

        // 1. Ingredient runs: consecutive ingredient-like blocks (classes may alternate), at least 3, mostly ingredient-like.
        var runs: [Range<Int>] = []
        var i = 0
        while i < blocks.count {
            var j = i
            while j < blocks.count, !blocks[j].text.isEmpty, !isStep[j],
                  blocks[j].styleKey == blocks[i].styleKey || (isIngredient[j] && (j == i || isIngredient[j - 1])) {
                j += 1
            }
            let count = j - i
            if count >= 3 {
                let hits = (i..<j).filter { isIngredient[$0] }.count
                if Double(hits) / Double(count) >= 0.6 { runs.append(i..<j) }
            }
            i = max(j, i + 1)
        }

        // 2. Learn the title style: the style that most often sits just before ingredient runs,
        //    weighted against styles that are common everywhere.
        func titleLike(_ k: Int) -> Bool {
            let t = blocks[k].text
            guard !t.isEmpty, t.count < 90, !isIngredient[k], !t.hasSuffix(":"), !TextPatterns.isTimeOrYield(t) else { return false }
            guard let first = t.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first),
                  !TextPatterns.fractions.unicodeScalars.contains(first) else { return false }
            return true
        }
        var candidates: [String: Int] = [:]
        for run in runs {
            var seen = 0
            var k = run.lowerBound - 1
            while k >= max(0, run.lowerBound - 25), seen < 4 {
                if titleLike(k) { candidates[blocks[k].styleKey, default: 0] += 1; seen += 1 }
                k -= 1
            }
        }
        var totals: [String: Int] = [:]
        for b in blocks { totals[b.styleKey, default: 0] += 1 }
        let titleStyle = candidates.max { a, b in
            Double(a.value * a.value) / Double(totals[a.key]!) < Double(b.value * b.value) / Double(totals[b.key]!)
        }?.key

        // 3. Split the book at title-style blocks; keep segments with recipe signals.
        var starts = Set(titleStyle.map { style in blocks.indices.filter { blocks[$0].styleKey == style && titleLike($0) } } ?? [])

        // Starts the book itself points at, for recipes set in another style (boxed recipes, sub-recipes):
        // ToC leaves, and contents links whose text matches the title they point to.
        var pointedStarts = Set<Int>()
        func nearestTitle(from idx: Int, key: String?) -> Int? {
            for k in idx..<min(blocks.count, idx + 4) where titleLike(k) {
                if let key, TextPatterns.titleKey(blocks[k].text) != key { continue }
                return k
            }
            return nil
        }
        for entry in package.toc where entry.isLeaf && entry.depth > 0 {
            if let idx = map.index(path: entry.path, fragment: entry.fragment), let k = nearestTitle(from: idx, key: nil) { pointedStarts.insert(k) }
        }
        for b in blocks where !b.links.isEmpty && b.links.count <= 2 && titleLike(b.index) {
            for link in b.links {
                let (path, frag) = EPUBPath.splitFragment(link)
                if let idx = map.index(path: path, fragment: frag), idx != b.index,
                   let k = nearestTitle(from: idx, key: TextPatterns.titleKey(b.text)) { pointedStarts.insert(k) }
            }
        }
        for k in pointedStarts where !(max(0, k - 3)...(k + 3)).contains(where: { starts.contains($0) }) {
            starts.insert(k)
        }
        let sortedStarts = Array(starts.union(overrides.markedRecipeStarts)).sorted()

        let bookKey = package.metadata.isbn.map { "isbn:\($0)" } ?? package.metadata.identifier ?? package.metadata.title

        // A recipe also ends where the ToC starts something new (a chapter opener, say).
        let tocStarts = package.toc.compactMap { map.index(path: $0.path, fragment: $0.fragment) }.sorted()

        var recipes: [RecipeCandidate] = []
        var sections: [BookSection] = []
        for (n, start) in sortedStarts.enumerated() {
            var end = n + 1 < sortedStarts.count ? sortedStarts[n + 1] : min(blocks.count, start + 200)
            if let cut = tocStarts.first(where: { $0 > start + 2 && $0 < end }) { end = cut }
            let segment = start..<end
            let ingredientLines = runs.filter { segment.contains($0.lowerBound) }.reduce(0) { $0 + $1.count }
            let stepLines = segment.filter { isStep[$0] }.count
            let hasTimeOrYield = segment.prefix(30).contains { TextPatterns.isTimeOrYield(blocks[$0].text) }
            let manual = overrides.markedRecipeStarts.contains(start)
            let pointed = pointedStarts.contains(start)
            let isRecipe = manual || ingredientLines > 0 || (stepLines >= 2 && (hasTimeOrYield || pointed))
            let title = blocks[start].text
            guard isRecipe else {
                sections.append(BookSection(title: title, chapter: nil, start: start, end: end))
                continue
            }
            let id = UUIDv5.make(namespace: UUIDv5.recipeNamespace, name: "\(bookKey)|\(blocks[start].id)").uuidString
            if overrides.notRecipes.contains(id) {
                sections.append(BookSection(title: title, chapter: nil, start: start, end: end))
                continue
            }
            recipes.append(RecipeCandidate(
                id: id, title: displayTitle(title), chapter: nil, start: start, end: end,
                page: blocks[start].page,
                confidence: ingredientLines > 0 && stepLines > 0 ? .high : .low,
                photos: photos(for: start..<end, title: title, blocks: blocks, isStep: isStep, container: package.container),
                uses: [], ingredientLines: ingredientLines, stepLines: stepLines, manual: manual))
        }

        // Chapters, once it's known which starts are recipes.
        let chapterOf = chapterLookup(package: package, map: map, recipeStarts: Set(recipes.map(\.start)))
        for i in recipes.indices { recipes[i].chapter = chapterOf(recipes[i].start) }
        sections = sections.map { BookSection(title: $0.title, chapter: chapterOf($0.start), start: $0.start, end: $0.end) }

        // 4. Sub-recipes: an ingredient line naming another recipe, or pointing at its page.
        var byTitle: [String: String] = [:]
        var byPage: [String: String] = [:]
        for r in recipes {
            let key = TextPatterns.normalizeForMatch(r.title)
            if key.count >= 6 { byTitle[key] = r.id }
            if let p = r.page, byPage[p] == nil { byPage[p] = r.id }
        }
        let pageRef = try! NSRegularExpression(pattern: "\\b(?:page|p\\.)\\s*(\\d{1,4})\\b", options: [.caseInsensitive])
        for idx in recipes.indices {
            var uses: [String] = []
            let r = recipes[idx]
            for k in r.start..<r.end where isIngredient[k] {
                let line = TextPatterns.normalizeForMatch(blocks[k].text)
                for (title, id) in byTitle where id != r.id && line.contains(title) && !uses.contains(id) { uses.append(id) }
                let ns = blocks[k].text as NSString
                for m in pageRef.matches(in: blocks[k].text, range: NSRange(location: 0, length: ns.length)) {
                    let page = ns.substring(with: m.range(at: 1))
                    if let id = byPage[page], id != r.id, !uses.contains(id) { uses.append(id) }
                }
            }
            recipes[idx].uses = uses
        }

        let ingredientStyles = Array(Set(runs.flatMap { $0.map { blocks[$0].styleKey } })).sorted()
        var chapters: [String] = []
        for r in recipes { if let c = r.chapter, !chapters.contains(c) { chapters.append(c) } }
        return FindResult(recipes: recipes, sections: sections,
                          profile: titleStyle.map { LayoutProfile(titleStyle: $0, ingredientStyles: ingredientStyles) },
                          chapters: chapters)
    }

    /// Books often set titles in capitals ("JEFFREY'S BLUE RIBBON CHILI"). Title-case those for display.
    public static func displayTitle(_ t: String) -> String {
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty, letters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else { return t }
        let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "with"]
        return t.lowercased().split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, word in
            let w = String(word)
            if i > 0 && small.contains(w) { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    /// Chapter for a block: the nearest earlier ToC entry that has children (a chapter with recipes under it).
    /// Flat ToCs (chapters only) use every entry that isn't itself a recipe.
    static func chapterLookup(package: EPUBPackage, map: BlockMap, recipeStarts: Set<Int>) -> (Int) -> String? {
        let nested = package.toc.contains { !$0.isLeaf }
        var entries: [(index: Int, title: String)] = []
        for entry in package.toc {
            guard let idx = map.index(path: entry.path, fragment: entry.fragment) else { continue }
            if nested {
                if !entry.isLeaf { entries.append((idx, entry.title)) }
            } else {
                // A ToC entry within a couple of blocks of a recipe start is that recipe, not a chapter.
                let isRecipe = (max(0, idx - 2)...(idx + 3)).contains { recipeStarts.contains($0) }
                if !isRecipe { entries.append((idx, entry.title)) }
            }
        }
        entries.sort { $0.index < $1.index }
        return { block in
            var result: String?
            for e in entries {
                if e.index <= block { result = e.title } else { break }
            }
            return result.map(displayTitle)
        }
    }

    /// Up to 3 photos: the image captioned with the title or right next to the recipe first, then images before the steps.
    static func photos(for range: Range<Int>, title: String, blocks: [Block], isStep: [Bool], container: EPUBContainer) -> [String] {
        let key = TextPatterns.titleKey(title)
        func usable(_ path: String) -> Bool {
            guard let data = container.data(path) else { return false }
            return data.count >= minimumPhotoBytes
        }
        var result: [String] = []
        func add(_ paths: [String]) {
            for p in paths where !result.contains(p) && usable(p) && result.count < 3 { result.append(p) }
        }
        let lo = max(0, range.lowerBound - 8), hi = min(blocks.count, range.upperBound + 8)
        // Captioned with the recipe title.
        for k in lo..<hi where !blocks[k].images.isEmpty {
            let near = max(0, k - 1)...min(blocks.count - 1, k + 2)
            if near.contains(where: { TextPatterns.titleKey(blocks[$0].text) == key && !key.isEmpty }) { add(blocks[k].images) }
        }
        // Image-only blocks right before the title or right after the recipe.
        if result.isEmpty {
            let before = Array(max(0, range.lowerBound - 3)..<range.lowerBound).reversed()
            let after = Array(range.upperBound..<min(blocks.count, range.upperBound + 2))
            for k in before + after where !blocks[k].images.isEmpty && blocks[k].text.isEmpty { add(blocks[k].images) }
        }
        // Images inside the recipe before its first step (step photos are skipped).
        let firstStep = range.first { isStep[$0] } ?? range.upperBound
        for k in range.lowerBound..<firstStep where !blocks[k].images.isEmpty { add(blocks[k].images) }
        return result
    }
}
