import Foundation

/// Which books in the Calibre library are cookbooks: any matching tag, or any title word.
public struct CookbookFilter: Codable, Sendable, Equatable {
    public var tags: [String]
    public var titleWords: [String]

    public init(tags: [String], titleWords: [String]) {
        self.tags = tags
        self.titleWords = titleWords
    }

    public static let `default` = CookbookFilter(tags: ["cookbook", "recipes"], titleWords: ["cookbook", "recipes", "kitchen"])

    public func matches(title: String, tags bookTags: [String]) -> Bool {
        let lowerTags = Set(bookTags.map { $0.lowercased() })
        if tags.contains(where: { lowerTags.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }) { return true }
        let lowerTitle = title.lowercased()
        return titleWords.contains { w in
            let word = w.lowercased().trimmingCharacters(in: .whitespaces)
            return !word.isEmpty && lowerTitle.contains(word)
        }
    }
}

public struct CalibreBook: Sendable, Identifiable, Equatable, Hashable {
    public let id: Int
    public let title: String
    public let authors: [String]
    public let tags: [String]
    public let folder: URL
    public let epub: URL
    public let cover: URL?
    public let dateAdded: Date?

    /// The Mela export saved next to the ePub: "<same name>.melarecipes".
    public var exportURL: URL { epub.deletingPathExtension().appendingPathExtension("melarecipes") }
    /// Processed once its export exists next to the ePub.
    public var processed: Bool { FileManager.default.fileExists(atPath: exportURL.path) }
}

/// Reads a Calibre library's metadata.db read-only. Never writes to the database.
public struct CalibreLibrary: Sendable {
    public let root: URL
    public var databaseURL: URL { root.appendingPathComponent("metadata.db") }

    public init(root: URL) throws {
        self.root = root
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("metadata.db").path) else {
            throw SQLiteError(description: "No Calibre library at \(root.path) (metadata.db is missing).")
        }
    }

    /// The usual library locations, for a first-run guess.
    public static func defaultLocations(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        ["Calibre Library", "Documents/Calibre Library", "Books/Calibre Library"].map { home.appendingPathComponent($0) }
    }

    public var bookCount: Int {
        (try? SQLiteDatabase(path: databaseURL.path).query("SELECT COUNT(*) AS n FROM books").first?["n"] ?? nil).flatMap { Int($0 ?? "") } ?? 0
    }

    public func allBooksWithEPUB() throws -> [CalibreBook] {
        let db = try SQLiteDatabase(path: databaseURL.path)
        let rows = try db.query("""
            SELECT b.id AS id, b.title AS title, b.path AS path, b.has_cover AS has_cover, b.timestamp AS added, d.name AS file
            FROM books b JOIN data d ON d.book = b.id AND upper(d.format) = 'EPUB'
            ORDER BY b.timestamp DESC
            """)
        var authors: [Int: [String]] = [:]
        for r in try db.query("SELECT l.book AS book, a.name AS name FROM books_authors_link l JOIN authors a ON a.id = l.author ORDER BY l.id") {
            if let b = Int((r["book"] ?? nil) ?? ""), let n = r["name"] ?? nil { authors[b, default: []].append(n.replacingOccurrences(of: "|", with: ",")) }
        }
        var tags: [Int: [String]] = [:]
        for r in try db.query("SELECT l.book AS book, t.name AS name FROM books_tags_link l JOIN tags t ON t.id = l.tag") {
            if let b = Int((r["book"] ?? nil) ?? ""), let n = r["name"] ?? nil { tags[b, default: []].append(n) }
        }
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainParser = ISO8601DateFormatter()
        return rows.compactMap { r in
            guard let id = Int((r["id"] ?? nil) ?? ""), let title = r["title"] ?? nil, let path = r["path"] ?? nil, let file = r["file"] ?? nil else { return nil }
            let folder = root.appendingPathComponent(path, isDirectory: true)
            let epub = folder.appendingPathComponent("\(file).epub")
            let coverURL = folder.appendingPathComponent("cover.jpg")
            let added = (r["added"] ?? nil).flatMap { s -> Date? in
                let iso = s.replacingOccurrences(of: " ", with: "T")
                let noFraction = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
                return dateParser.date(from: iso) ?? plainParser.date(from: noFraction)
            }
            return CalibreBook(id: id, title: title, authors: authors[id] ?? [], tags: (tags[id] ?? []).sorted(), folder: folder, epub: epub,
                               cover: (r["has_cover"] ?? nil) == "1" || FileManager.default.fileExists(atPath: coverURL.path) ? coverURL : nil,
                               dateAdded: added)
        }
    }

    public func cookbooks(matching filter: CookbookFilter) throws -> [CalibreBook] {
        try allBooksWithEPUB().filter { filter.matches(title: $0.title, tags: $0.tags) && FileManager.default.fileExists(atPath: $0.epub.path) }
    }
}
