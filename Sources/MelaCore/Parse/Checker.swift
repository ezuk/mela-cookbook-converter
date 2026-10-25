import Foundation

public enum RecipeState: String, Codable, Sendable {
    case waiting, parsing, checking, approved, needsReview, failed, exported
}

/// Where a field's value came from, shown in the review screen.
public enum FieldStatus: String, Codable, Sendable {
    case found      // read from the book
    case inferred   // worked out by the model
    case missing    // not in the book
    case edited     // changed by me
}

public struct CheckIssue: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case lineNotInSource      // an output line doesn't match the blocks it cites
        case unknownSource        // cites a label that doesn't exist
        case missingSourceLine    // an ingredient or step line in the book isn't in the output
        case numberNotInSource    // a number in a field that isn't in the book
        case noTitle, noIngredients, noSteps
    }
    public var kind: Kind
    public var message: String
    /// The output line it's about, as "ingredient 3" / "step 2" / a field name.
    public var field: String?
    /// Block indices in the book to highlight.
    public var blocks: [Int]
}

/// A line the checker replaced with the book's text because only a number differed.
public struct CheckFix: Codable, Sendable, Equatable {
    public var field: String
    public var modelText: String
    public var bookText: String
}

public struct CheckReport: Codable, Sendable, Equatable {
    public var issues: [CheckIssue]
    public var fixes: [CheckFix]
    public var state: RecipeState { issues.isEmpty ? .approved : .needsReview }

    /// Short descriptions for feeding back to the model on retry.
    public var feedback: [String] { issues.map(\.message) }
}

public enum Checker {
    /// Checks a draft against its source without an LLM, fixing number-only mismatches from the book.
    /// Returns the fixed draft and the report.
    public static func check(_ input: RecipeDraft, source: RecipeSource) -> (draft: RecipeDraft, report: CheckReport) {
        var draft = input
        var issues: [CheckIssue] = []
        var fixes: [CheckFix] = []
        var cited = Set<String>()

        let sourceNumbers = Set(source.lines.flatMap { TextPatterns.numbers(in: $0.text) })

        func blockText(_ label: String) -> String? { source.line(label)?.text }

        /// Verifies one line; returns the text to keep (the book's text when only numbers differed).
        func verify(_ line: RecipeDraft.Line, field: String, isStep: Bool) -> String {
            let known = line.source.filter { blockText($0) != nil }
            let unknown = line.source.filter { blockText($0) == nil }
            cited.formUnion(known)
            if !unknown.isEmpty || known.isEmpty {
                // No usable citation: accept if the text appears anywhere in the recipe.
                if let match = source.lines.first(where: { nearlyContains(stripStepNumber($0.text), line.text) }) {
                    cited.insert(match.label)
                    return line.text
                }
                issues.append(CheckIssue(kind: unknown.isEmpty ? .lineNotInSource : .unknownSource,
                                         message: "\(field) “\(line.text)” cites no line of the recipe that contains it.",
                                         field: field, blocks: []))
                return line.text
            }
            let cites = known.compactMap(blockText).map(stripStepNumber)
            let joined = cites.joined(separator: " ")
            if nearlyContains(joined, line.text) || nearlyContains(line.text, joined) { return line.text }
            let blocks = known.compactMap { source.line($0)?.blockIndex }
            // Only the numbers differ: use the book's text.
            if known.count == 1, withoutNumbers(joined) == withoutNumbers(line.text), !withoutNumbers(joined).isEmpty {
                fixes.append(CheckFix(field: field, modelText: line.text, bookText: cites[0]))
                return cites[0]
            }
            if let wrong = TextPatterns.numbers(in: line.text).first(where: { !sourceNumbers.contains($0) }) {
                issues.append(CheckIssue(kind: .numberNotInSource, message: "\(field) “\(line.text)” has \(wrong), which isn't in the book.",
                                         field: field, blocks: blocks))
                return line.text
            }
            issues.append(CheckIssue(kind: .lineNotInSource, message: "\(field) “\(line.text)” doesn't match the book’s line “\(joined.prefix(160))”.",
                                     field: field, blocks: blocks))
            return line.text
        }

        // Ingredients and steps.
        var n = 0
        for g in draft.ingredientGroups.indices {
            for i in draft.ingredientGroups[g].items.indices {
                n += 1
                draft.ingredientGroups[g].items[i].text = verify(draft.ingredientGroups[g].items[i], field: "Ingredient \(n)", isStep: false)
            }
        }
        n = 0
        for g in draft.stepGroups.indices {
            for i in draft.stepGroups[g].steps.indices {
                n += 1
                draft.stepGroups[g].steps[i].text = verify(draft.stepGroups[g].steps[i], field: "Step \(n)", isStep: true)
            }
        }
        for note in draft.notes { cited.formUnion(note.source) }

        // Numbers in single-value fields must be in the book unless the model says it worked them out.
        let inferred = Set(draft.inferred)
        for (name, value) in [("yield", draft.yield), ("prepTime", draft.prepTime), ("cookTime", draft.cookTime), ("totalTime", draft.totalTime)] {
            guard let value, !inferred.contains(name) else { continue }
            if let wrong = TextPatterns.numbers(in: value).first(where: { !sourceNumbers.contains($0) }) {
                issues.append(CheckIssue(kind: .numberNotInSource, message: "\(name) “\(value)” has \(wrong), which isn't in the book. Use null or list it in inferred.",
                                         field: name, blocks: []))
            }
        }

        // Coverage: ingredient and step lines of the book that ended up nowhere.
        let fieldTexts = ([draft.title, draft.headnote, draft.yield, draft.prepTime, draft.cookTime, draft.totalTime, draft.nutrition]
                          .compactMap { $0 } + draft.notes.map(\.text) + draft.crossReferences.map(\.text))
            .map { TextPatterns.normalizeForMatch($0) }
        let allOutput = (draft.allIngredients + draft.allSteps).map { TextPatterns.normalizeForMatch($0.text) }
        for line in source.lines where !cited.contains(line.label) {
            let isIng = TextPatterns.isIngredient(line.text), isStep = TextPatterns.isStep(line.text)
            guard isIng || isStep else { continue }
            let norm = TextPatterns.normalizeForMatch(stripStepNumber(line.text))
            if allOutput.contains(where: { $0.contains(norm) || norm.contains($0) && $0.count > 8 }) { continue }
            // Used in a single-value field (yield, a time) or a note, maybe with its label added or dropped.
            if fieldTexts.contains(where: { $0.contains(norm) || (norm.contains($0) && $0.count >= 2) }) { continue }
            if fieldTexts.contains(where: { Checker.nearlyContains($0, norm) }) { continue }
            issues.append(CheckIssue(kind: .missingSourceLine,
                                     message: "The book's line “\(line.text.prefix(160))” (\(line.label)) isn't in the parsed recipe.",
                                     field: nil, blocks: [line.blockIndex]))
        }

        // Structure.
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(CheckIssue(kind: .noTitle, message: "The recipe has no title.", field: "title", blocks: []))
        }
        if draft.allIngredients.isEmpty && source.candidate.ingredientLines > 0 {
            issues.append(CheckIssue(kind: .noIngredients, message: "No ingredients were found, but the book lists some.", field: nil, blocks: []))
        }
        if draft.allSteps.isEmpty {
            issues.append(CheckIssue(kind: .noSteps, message: "No method steps were found.", field: nil, blocks: []))
        }
        return (draft, CheckReport(issues: issues, fixes: fixes))
    }

    static func stripStepNumber(_ s: String) -> String {
        s.replacingOccurrences(of: #"^([Ss]tep\s*)?\d{1,2}[.):]?\s+(?=\p{Lu})"#, with: "", options: .regularExpression)
    }

    static func withoutNumbers(_ s: String) -> String {
        TextPatterns.normalizeForMatch(s)
            .replacingOccurrences(of: #"[\d/.,]+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"#(\s*#)*"#, with: "#", options: .regularExpression)
    }

    /// True when `needle` appears in `haystack` after normalizing, or nearly so (≥ 90% of its words, in order-free match).
    static func nearlyContains(_ haystack: String, _ needle: String) -> Bool {
        let h = TextPatterns.normalizeForMatch(haystack), n = TextPatterns.normalizeForMatch(needle)
        guard !n.isEmpty else { return true }
        if h.contains(n) { return true }
        let strip: (String) -> String = { $0.replacingOccurrences(of: #"[^\p{L}\p{N}/ ]"#, with: "", options: .regularExpression) }
        let hs = strip(h), ns = strip(n)
        if hs.contains(ns) { return true }
        let hw = hs.split(separator: " "), nw = ns.split(separator: " ")
        guard nw.count >= 4 else { return false }
        var pool = Dictionary(hw.map { ($0, 1) }, uniquingKeysWith: +)
        var hits = 0
        for w in nw { if let c = pool[w], c > 0 { pool[w] = c - 1; hits += 1 } }
        // Numbers must all be present for a near match.
        let numbersOK = TextPatterns.numbers(in: n).allSatisfy { TextPatterns.numbers(in: h).contains($0) }
        return numbersOK && Double(hits) / Double(nw.count) >= 0.9
    }

    /// Per-field status for the review screen.
    public static func fieldStatus(_ draft: RecipeDraft, field: String) -> FieldStatus {
        let value: String?
        switch field {
        case "yield": value = draft.yield
        case "prepTime": value = draft.prepTime
        case "cookTime": value = draft.cookTime
        case "totalTime": value = draft.totalTime
        case "headnote": value = draft.headnote
        case "nutrition": value = draft.nutrition
        default: value = nil
        }
        guard let v = value, !v.isEmpty else { return .missing }
        return draft.inferred.contains(field) ? .inferred : .found
    }
}
