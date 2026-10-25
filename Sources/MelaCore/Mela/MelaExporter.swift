import Foundation
import ZIPFoundation

/// One recipe in Mela's file format (https://mela.recipes/fileformat/index.html).
public struct MelaRecipe: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var text: String
    public var images: [String]          // base64 JPEG/PNG, first is the main image
    public var categories: [String]
    public var yield: String
    public var prepTime: String
    public var cookTime: String
    public var totalTime: String
    public var ingredients: String       // one per line, "# Group" headers
    public var instructions: String      // one step per line, "# Part" headers
    public var notes: String
    public var nutrition: String
    public var link: String
}

public struct ExportOptions: Codable, Sendable, Equatable {
    public var chapterAsCategory = true
    public var bookInSource = true
    public var includeInferredTimes = false
    public var includePhotos = true
    public init() {}
}

public struct ExportItem: Sendable {
    public let candidate: RecipeCandidate
    /// The draft to export: the parsed draft with my edits applied.
    public let draft: RecipeDraft
    /// Photo order chosen in review; defaults to the finder's order.
    public let photos: [String]?

    public init(candidate: RecipeCandidate, draft: RecipeDraft, photos: [String]? = nil) {
        self.candidate = candidate
        self.draft = draft
        self.photos = photos
    }
}

public enum MelaExporter {
    /// Builds the Mela recipe for one item. The app, not the model, writes the file.
    public static func recipe(_ item: ExportItem, book: EPUBPackage, map: BlockMap, titlesByID: [String: String],
                              options: ExportOptions) -> MelaRecipe {
        let d = item.draft
        func time(_ field: String, _ value: String?) -> String {
            guard let value else { return "" }
            if d.inferred.contains(field) && !options.includeInferredTimes { return "" }
            return value
        }
        let ingredients = d.ingredientGroups.flatMap { g -> [String] in
            (g.name.map { ["# \(clean($0))"] } ?? []) + g.items.map { clean($0.text) }
        }.joined(separator: "\n")
        let instructions = d.stepGroups.flatMap { g -> [String] in
            (g.name.map { ["# \(clean($0))"] } ?? []) + g.steps.map { clean($0.text) }
        }.joined(separator: "\n")

        var notes: [String] = d.notes.map { clean($0.text) }
        let refs = item.candidate.uses.compactMap { titlesByID[$0] }
        var seeAlso = refs
        for x in d.crossReferences where !refs.contains(where: { TextPatterns.titleKey($0) == TextPatterns.titleKey(x.text) }) {
            seeAlso.append(x.page.map { "\(x.text) (p. \($0))" } ?? x.text)
        }
        if !seeAlso.isEmpty { notes.append("See also: " + seeAlso.joined(separator: "; ")) }

        var link = ""
        if options.bookInSource {
            let author = book.metadata.authors.first.map { ", \($0)" } ?? ""
            let place = item.candidate.page.map { ", p. \($0)" } ?? item.candidate.chapter.map { ", \($0)" } ?? ""
            link = "\(shortTitle(book.metadata.title))\(author)\(place)"
        }

        var images: [String] = []
        if options.includePhotos {
            for path in (item.photos ?? item.candidate.photos).prefix(3) {
                guard let data = book.container.data(path), let jpeg = ImageResizer.prepare(data) else { continue }
                images.append(jpeg.base64EncodedString())
            }
        }

        let category = item.candidate.chapter.map { $0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces) }
        return MelaRecipe(
            id: item.candidate.id,
            title: clean(d.title.isEmpty ? item.candidate.title : d.title),
            text: d.headnote.map(clean) ?? "",
            images: images,
            categories: options.chapterAsCategory ? [category].compactMap { $0 }.filter { !$0.isEmpty } : [],
            yield: d.yield ?? "",
            prepTime: time("prepTime", d.prepTime),
            cookTime: time("cookTime", d.cookTime),
            totalTime: time("totalTime", d.totalTime),
            ingredients: ingredients,
            instructions: instructions,
            notes: notes.joined(separator: "\n\n"),
            nutrition: d.nutrition ?? "",
            link: link)
    }

    /// Writes a `.melarecipes` bundle: a zip of `.melarecipe` JSON files.
    public static func export(_ items: [ExportItem], book: EPUBPackage, map: BlockMap, options: ExportOptions, to url: URL) throws {
        let titles = Dictionary(items.map { ($0.candidate.id, $0.draft.title.isEmpty ? $0.candidate.title : $0.draft.title) }, uniquingKeysWith: { a, _ in a })
        // Titles of recipes not in this export can still be named in "See also".
        var allTitles = titles
        for r in RecipeFinder.find(package: book, map: map).recipes where allTitles[r.id] == nil { allTitles[r.id] = r.title }

        let recipes = items.map { recipe($0, book: book, map: map, titlesByID: allTitles, options: options) }
        try write(recipes, to: url)
    }

    public static func write(_ recipes: [MelaRecipe], to url: URL) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        let archive = try Archive(url: temp, accessMode: .create)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for r in recipes {
            let data = try encoder.encode(r)
            try archive.addEntry(with: "\(r.id).melarecipe", type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: temp, to: url)
    }

    /// Strips Mela-unfriendly whitespace and invisible characters.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "[\\t\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Cook It in Cast Iron (Cook's Country)" → "Cook It in Cast Iron"; drops marketing after a period or colon is kept.
    static func shortTitle(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\.\s*#?\d+\s+.*$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
