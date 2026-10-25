import Foundation

/// The structured recipe the model fills in. Richer than Mela's format, and every
/// line cites the source blocks it came from so the checker can verify it.
public struct RecipeDraft: Codable, Sendable, Equatable {
    public var title: String
    public var headnote: String?
    public var yield: String?
    public var prepTime: String?
    public var cookTime: String?
    public var totalTime: String?
    public var ingredientGroups: [IngredientGroup]
    public var stepGroups: [StepGroup]
    public var notes: [Note]
    public var nutrition: String?
    public var crossReferences: [CrossReference]
    /// Names of fields the model worked out rather than read ("totalTime", "yield").
    public var inferred: [String]

    public struct Line: Codable, Sendable, Equatable {
        public var text: String
        public var source: [String]
        public init(text: String, source: [String]) { self.text = text; self.source = source }
    }

    public struct IngredientGroup: Codable, Sendable, Equatable {
        public var name: String?
        public var items: [Line]
    }

    public struct StepGroup: Codable, Sendable, Equatable {
        public var name: String?
        public var steps: [Line]
    }

    public enum NoteKind: String, Codable, Sendable, CaseIterable {
        case tip, variation, makeAhead = "make_ahead", storage, serving, other
    }

    public struct Note: Codable, Sendable, Equatable {
        public var kind: NoteKind
        public var text: String
        public var source: [String]
    }

    public struct CrossReference: Codable, Sendable, Equatable {
        public var text: String
        public var page: String?
    }

    public var allIngredients: [Line] { ingredientGroups.flatMap(\.items) }
    public var allSteps: [Line] { stepGroups.flatMap(\.steps) }
}

public enum RecipeDraftSchema {
    /// Bump when the schema changes; part of the parse cache key.
    public static let version = 1

    /// JSON Schema draft-07 that satisfies both engines: every property required,
    /// null unions for missing values, no additional properties, no allOf/not/if.
    public static let json: String = {
        let line = #"{"type":"object","properties":{"text":{"type":"string"},"source":{"type":"array","items":{"type":"string"}}},"required":["text","source"],"additionalProperties":false}"#
        let nullableString = #"{"type":["string","null"]}"#
        let kinds = RecipeDraft.NoteKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return """
        {"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{\
        "title":{"type":"string"},\
        "headnote":\(nullableString),\
        "yield":\(nullableString),\
        "prepTime":\(nullableString),\
        "cookTime":\(nullableString),\
        "totalTime":\(nullableString),\
        "ingredientGroups":{"type":"array","items":{"type":"object","properties":{"name":\(nullableString),"items":{"type":"array","items":\(line)}},"required":["name","items"],"additionalProperties":false}},\
        "stepGroups":{"type":"array","items":{"type":"object","properties":{"name":\(nullableString),"steps":{"type":"array","items":\(line)}},"required":["name","steps"],"additionalProperties":false}},\
        "notes":{"type":"array","items":{"type":"object","properties":{"kind":{"type":"string","enum":[\(kinds)]},"text":{"type":"string"},"source":{"type":"array","items":{"type":"string"}}},"required":["kind","text","source"],"additionalProperties":false}},\
        "nutrition":\(nullableString),\
        "crossReferences":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"page":\(nullableString)},"required":["text","page"],"additionalProperties":false}},\
        "inferred":{"type":"array","items":{"type":"string"}}\
        },"required":["title","headnote","yield","prepTime","cookTime","totalTime","ingredientGroups","stepGroups","notes","nutrition","crossReferences","inferred"],"additionalProperties":false}
        """
    }()
}
