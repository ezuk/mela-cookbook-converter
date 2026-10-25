import Foundation

/// The text of one recipe as sent to the model: one tagged line per block.
public struct RecipeSource: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let label: String       // "b1", "b2", … local to this recipe
        public let blockIndex: Int
        public let style: String
        public let text: String
    }

    public let candidate: RecipeCandidate
    public let lines: [Line]
    public let bookTitle: String

    public init(candidate: RecipeCandidate, map: BlockMap, bookTitle: String) {
        self.candidate = candidate
        self.bookTitle = bookTitle
        var lines: [Line] = []
        for k in candidate.start..<min(candidate.end, map.blocks.count) {
            let b = map.blocks[k]
            guard !b.text.isEmpty else { continue }
            lines.append(Line(label: "b\(lines.count + 1)", blockIndex: k, style: b.styleKey, text: b.text))
        }
        self.lines = lines
    }

    public var tagged: String {
        lines.map { "[\($0.label) \($0.style)] \($0.text)" }.joined(separator: "\n")
    }

    public func line(_ label: String) -> Line? { lines.first { $0.label == label } }

    /// Changes whenever the recipe's source text changes. Part of the parse cache key.
    public var hash: String { SHA1.hex(tagged) }
}

public enum PromptBuilder {
    /// Bump when the prompt changes; part of the parse cache key.
    public static let version = 2

    public static func prompt(for source: RecipeSource, feedback: [String] = []) -> String {
        var p = """
        You are converting one recipe from the cookbook "\(source.bookTitle)" into structured data.
        The recipe text follows, one block of the book per line, as: [label style] text.
        The style is the book's own markup class; it hints at the block's role.

        Rules:
        - Copy the book's wording, units and language exactly. Do not convert units, translate, rewrite, summarize or fix the author's text.
        - title: the recipe title as printed. If it is set in ALL CAPS, write it in normal title case.
        - headnote: the introduction before the ingredients, or null.
        - yield: as printed, including its word ("Serves 4–6", "Makes 12"), or null.
        - prepTime, cookTime, totalTime: the value as printed without its label ("15 minutes", not "Prep Time 15 minutes"), or null if the book doesn't say.
          If the book gives several cooking stages (e.g. sauté, pressure cook), cookTime is the main cooking stage and the others go in notes only if they matter.
          If you work a value out instead of reading it, fill it and add the field name to "inferred". Prefer null over guessing.
        - ingredientGroups: one item per ingredient line. If the list has sub-headings ("For the dressing:", "TO SERVE"), make one group per sub-heading with name set to the heading text without a trailing colon; otherwise one group with name null.
        - stepGroups: one step per method paragraph, with any leading step number removed. Use named groups only if the method has sub-headings.
        - notes: tips, variations, make-ahead, storage and serving notes, keeping their text.
        - crossReferences: references to other recipes ("see page 212", "Basic Stock, page 212").
        - nutrition: as printed, or null.
        - source: for every ingredient, step and note, list the labels (like "b12") of the lines it came from.
        - Ignore photo captions, page furniture and anything that belongs to a different recipe.

        Recipe:
        \(source.tagged)
        """
        if !feedback.isEmpty {
            p += "\n\nA check of your previous answer against the book found these problems. Fix them and answer again:\n"
            p += feedback.map { "- \($0)" }.joined(separator: "\n")
        }
        return p
    }
}
