import Foundation

/// Cheap text signals shared by the recipe finder and the checker.
public enum TextPatterns {
    static let fractions = "½¼¾⅓⅔⅛⅜⅝⅞⅕⅖⅗⅘⅙⅚"

    static let quantityStart = try! NSRegularExpression(
        pattern: "^(\\d|[\(fractions)]|(one |two |three |four |five |six |half |a few |a handful |a pinch |pinch |dash |a dash ))",
        options: [.caseInsensitive])
    static let unitWord = try! NSRegularExpression(
        pattern: "\\b(cups?|tablespoons?|teaspoons?|tbsp|tbs|tsp|ounces?|oz|pounds?|lbs?|grams?|g|kg|ml|millilit(er|re)s?|lit(er|re)s?|l|cloves?|cans?|sticks?|pinch|dash|bunch(es)?|sprigs?|slices?|large|medium|small|handful)\\b",
        options: [.caseInsensitive])
    static let stepStart = try! NSRegularExpression(pattern: "^([Ss]tep\\s*)?\\d{1,2}[.):]?\\s+\\p{Lu}")
    static let timeYield = try! NSRegularExpression(
        pattern: "\\b(prep|cook|total|active|bake|baking|rest|resting|chill|sauté|pressure)\\b.{0,20}\\btime\\b|^\\s*(serves|makes|yield|yields|servings|portions)\\b",
        options: [.caseInsensitive])

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func isStep(_ text: String) -> Bool {
        text.count > 12 && matches(stepStart, text)
    }

    public static func isIngredient(_ text: String) -> Bool {
        guard text.count < 200, !isStep(text), !isTimeOrYield(text) else { return false }
        if matches(quantityStart, text) { return true }
        return text.count < 90 && matches(unitWord, text)
    }

    public static func isTimeOrYield(_ text: String) -> Bool {
        text.count < 120 && matches(timeYield, text)
    }

    /// Lower-case alphanumerics only, "&" read as "and". Used to compare titles.
    public static func titleKey(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "&", with: "and").unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// Normalizes text for "nearly matches" comparisons: quotes, dashes, fractions, spacing, case.
    public static func normalizeForMatch(_ s: String) -> String {
        var t = s.lowercased()
        let map: [String: String] = [
            "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{2013}": "-", "\u{2014}": "-",
            "\u{2212}": "-", "\u{00A0}": " ", "\u{2009}": " ", "\u{2044}": "/",
            "½": " 1/2", "¼": " 1/4", "¾": " 3/4", "⅓": " 1/3", "⅔": " 2/3", "⅛": " 1/8", "⅜": " 3/8", "⅝": " 5/8", "⅞": " 7/8",
        ]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: "(\\d)\\s+(\\d+/\\d+)", with: "$1 $2", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Every number, fraction and range in a text, normalized ("1½" → "1 1/2", "8–10" → "8", "10").
    public static func numbers(in s: String) -> [String] {
        let n = normalizeForMatch(s)
        let re = try! NSRegularExpression(pattern: "\\d+ \\d+/\\d+|\\d+/\\d+|\\d+(?:[.,]\\d+)?")
        return re.matches(in: n, range: NSRange(n.startIndex..., in: n)).compactMap { Range($0.range, in: n).map { String(n[$0]) } }
    }
}
