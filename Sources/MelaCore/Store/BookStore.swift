import Foundation

public enum BrowseMode: String, Codable, Sendable { case outline, gallery }

public struct ExportRecord: Codable, Sendable, Equatable {
    public var date: Date
    public var file: String
    public var recipeIDs: [String]
}

/// Everything remembered about one book between launches.
public struct BookState: Codable, Sendable, Equatable {
    public var title: String
    public var ticked: Set<String> = []
    public var mode: BrowseMode = .outline
    public var overrides = FinderOverrides()
    /// My edits, kept apart from the parse so a re-parse can show a diff instead of wiping them.
    public var edits: [String: RecipeDraft] = [:]
    /// Photo order chosen in review, per recipe.
    public var photoOrder: [String: [String]] = [:]
    /// Recipes approved by hand in review.
    public var approvedByMe: Set<String> = []
    public var exports: [ExportRecord] = []
    public var lastOpened = Date()

    public init(title: String) { self.title = title }

    /// When each recipe was last exported.
    public var exportedDates: [String: Date] {
        var out: [String: Date] = [:]
        for e in exports { for id in e.recipeIDs where (out[id] ?? .distantPast) < e.date { out[id] = e.date } }
        return out
    }
}

/// Per-book storage in Application Support, keyed by the book's identifier and a file fingerprint.
///
///   <root>/<key>/state.json         ticks, edits, overrides, export history
///   <root>/<key>/parsed/<id>.json   latest parse per recipe
///   <root>/<key>/cache/<hash>.json  parse cache (never re-send finished work)
public final class BookStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    public let cache: DirectoryParseCache

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mela-importer")
        return base.appendingPathComponent("MelaImporter/Books", isDirectory: true)
    }

    /// A stable key: the book's ISBN or identifier plus a fingerprint of the file.
    public static func key(metadata: BookMetadata, fileURL: URL) -> String {
        let ident = metadata.isbn ?? metadata.identifier ?? metadata.title
        return SHA1.hex("\(ident)|\(fingerprint(fileURL))").prefix(20).description
    }

    /// Size plus the first and last megabyte: fast and good enough to tell editions apart.
    public static func fingerprint(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "missing" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        var data = (try? h.read(upToCount: 1 << 20)) ?? Data()
        if size > 2 << 20 {
            try? h.seek(toOffset: size - (1 << 20))
            data.append((try? h.read(upToCount: 1 << 20)) ?? Data())
        }
        return "\(size)-\(SHA1.hex(data))"
    }

    public init(key: String, root: URL = BookStore.defaultRoot) throws {
        directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("parsed"), withIntermediateDirectories: true)
        cache = DirectoryParseCache(directory: directory.appendingPathComponent("cache"))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func loadState(defaultTitle: String) -> BookState {
        lock.withLock {
            let url = directory.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: url), let s = try? BookStore.decoder.decode(BookState.self, from: data) else {
                return BookState(title: defaultTitle)
            }
            return s
        }
    }

    public func saveState(_ state: BookState) {
        lock.withLock {
            guard let data = try? BookStore.encoder.encode(state) else { return }
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }

    public func loadParsed() -> [String: ParsedRecipe] {
        lock.withLock {
            let dir = directory.appendingPathComponent("parsed")
            var out: [String: ParsedRecipe] = [:]
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".json") {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(file)), let p = try? BookStore.decoder.decode(ParsedRecipe.self, from: data) {
                    out[p.candidateID] = p
                }
            }
            return out
        }
    }

    public func saveParsed(_ recipe: ParsedRecipe) {
        lock.withLock {
            guard let data = try? BookStore.encoder.encode(recipe) else { return }
            try? data.write(to: directory.appendingPathComponent("parsed/\(recipe.candidateID).json"), options: .atomic)
        }
    }

    /// "Forget this book": deletes everything stored for it.
    public func forget() throws {
        try lock.withLock { try FileManager.default.removeItem(at: directory) }
    }
}

/// A parse cache in a folder of JSON files.
public final class DirectoryParseCache: ParseCache, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func cached(_ key: String) -> ParsedRecipe? {
        lock.withLock {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(key).json")) else { return nil }
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return try? d.decode(ParsedRecipe.self, from: data)
        }
    }

    public func store(_ recipe: ParsedRecipe) {
        lock.withLock {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            guard let data = try? e.encode(recipe) else { return }
            try? data.write(to: directory.appendingPathComponent("\(recipe.cacheKey).json"), options: .atomic)
        }
    }
}
