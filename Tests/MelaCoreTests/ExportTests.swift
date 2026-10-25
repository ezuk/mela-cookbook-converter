import XCTest
import ZIPFoundation
@testable import MelaCore

final class MelaExportTests: XCTestCase {
    func testRecipeMapping() throws {
        let p = try TestBook.cookbook().package()
        let map = BlockMap(package: p)
        let found = RecipeFinder.find(package: p, map: map)
        let source = RecipeSource(candidate: found.recipes[1], map: map, bookTitle: p.metadata.title)
        var draft = soupDraft(source)
        draft.ingredientGroups.append(.init(name: "To serve", items: [.init(text: "Crusty bread", source: [])]))
        draft.notes = [.init(kind: .tip, text: "Freezes well.", source: [])]
        draft.totalTime = "40 minutes"
        draft.inferred = ["totalTime"]
        let titles = Dictionary(uniqueKeysWithValues: found.recipes.map { ($0.id, $0.title) })
        let r = MelaExporter.recipe(ExportItem(candidate: found.recipes[1], draft: draft), book: p, map: map, titlesByID: titles, options: ExportOptions())
        XCTAssertEqual(r.id, found.recipes[1].id)
        XCTAssertEqual(r.categories, ["Soups"])
        XCTAssertEqual(r.ingredients, "1 kg tomatoes\n500 ml Basic Stock (page 12)\n½ teaspoon salt\n2 tbsp olive oil\n# To serve\nCrusty bread")
        XCTAssertEqual(r.instructions, "Roast the tomatoes at 200°C for 30 minutes.\nBlend with the stock and season.")
        XCTAssertEqual(r.prepTime, "10 minutes")
        XCTAssertEqual(r.totalTime, "", "inferred times are off by default")
        XCTAssertEqual(r.notes, "Freezes well.\n\nSee also: Basic Stock")
        XCTAssertEqual(r.link, "Test Kitchen, Ada Cook, p. 13")
        XCTAssertEqual(r.images.count, 0, "the synthetic photo isn't a real image")

        var options = ExportOptions()
        options.chapterAsCategory = false
        options.bookInSource = false
        options.includeInferredTimes = true
        let r2 = MelaExporter.recipe(ExportItem(candidate: found.recipes[1], draft: draft), book: p, map: map, titlesByID: titles, options: options)
        XCTAssertEqual(r2.categories, [])
        XCTAssertEqual(r2.link, "")
        XCTAssertEqual(r2.totalTime, "40 minutes")
    }

    func testBundleIsAZipOfMelarecipeJSON() throws {
        let p = try TestBook.cookbook().package()
        let map = BlockMap(package: p)
        let found = RecipeFinder.find(package: p, map: map)
        let source = RecipeSource(candidate: found.recipes[1], map: map, bookTitle: p.metadata.title)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).melarecipes")
        defer { try? FileManager.default.removeItem(at: url) }
        try MelaExporter.export([ExportItem(candidate: found.recipes[1], draft: soupDraft(source))], book: p, map: map, options: ExportOptions(), to: url)
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        XCTAssertEqual(entries.map(\.path), ["\(found.recipes[1].id).melarecipe"])
        var data = Data()
        _ = try archive.extract(entries[0]) { data.append($0) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["id", "title", "text", "images", "categories", "yield", "prepTime", "cookTime", "totalTime", "ingredients", "instructions", "notes", "nutrition", "link"] {
            XCTAssertNotNil(json[key], key)
        }
        XCTAssertEqual(json["title"] as? String, "Tomato Soup")
    }

    func testShortTitleAndImageSize() {
        XCTAssertEqual(MelaExporter.shortTitle("Cook It in Cast Iron (Cook's Country)"), "Cook It in Cast Iron")
        XCTAssertEqual(MelaExporter.shortTitle("Joshua Weissman: An Unapologetic Cookbook. #1 NEW YORK TIMES BESTSELLER"), "Joshua Weissman: An Unapologetic Cookbook")
        // A PNG header claiming 640×480.
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        png += [0, 0, 2, 128, 0, 0, 1, 224]
        XCTAssertEqual(ImageResizer.pixelSize(Data(png))?.width, 640)
        XCTAssertEqual(ImageResizer.pixelSize(Data(png))?.height, 480)
    }
}

final class CalibreTests: XCTestCase {
    func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calibre-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: root.appendingPathComponent("metadata.db").path, readOnly: false)
        try db.execute("""
            CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, path TEXT, has_cover BOOL, timestamp TIMESTAMP);
            CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
            CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER);
            CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, uncompressed_size INTEGER, name TEXT);
            INSERT INTO books VALUES (1, 'Cook It in Cast Iron', 'Americas Test Kitchen/Cook It in Cast Iron (1)', 1, '2022-08-29 16:05:55.123456+00:00');
            INSERT INTO books VALUES (2, 'A Novel', 'Someone/A Novel (2)', 0, '2023-01-01 10:00:00+00:00');
            INSERT INTO books VALUES (3, 'The Home Kitchen', 'Ana/The Home Kitchen (3)', 0, '2024-01-01 10:00:00+00:00');
            INSERT INTO books VALUES (4, 'Mobi Only Cookbook', 'X/Mobi (4)', 0, '2024-02-01 10:00:00+00:00');
            INSERT INTO authors VALUES (1, 'America''s Test Kitchen'), (2, 'Someone'), (3, 'Ana Soto');
            INSERT INTO books_authors_link VALUES (1, 1, 1), (2, 2, 2), (3, 3, 3);
            INSERT INTO tags VALUES (1, 'Cookbook'), (2, 'Fiction');
            INSERT INTO books_tags_link VALUES (1, 1, 1), (2, 2, 2);
            INSERT INTO data VALUES (1, 1, 'EPUB', 1, 'Cook It in Cast Iron - Americas Test Kitchen'), (2, 2, 'EPUB', 1, 'A Novel - Someone'),
                                    (3, 3, 'EPUB', 1, 'The Home Kitchen - Ana Soto'), (4, 4, 'MOBI', 1, 'Mobi');
            """)
        for (folder, file) in [("Americas Test Kitchen/Cook It in Cast Iron (1)", "Cook It in Cast Iron - Americas Test Kitchen"),
                               ("Someone/A Novel (2)", "A Novel - Someone"), ("Ana/The Home Kitchen (3)", "The Home Kitchen - Ana Soto")] {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("epub".utf8).write(to: dir.appendingPathComponent("\(file).epub"))
        }
        return root
    }

    func testCookbooksMatchTagsOrTitleWords() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try CalibreLibrary(root: root)
        XCTAssertEqual(library.bookCount, 4)
        let books = try library.cookbooks(matching: CookbookFilter(tags: ["cookbook"], titleWords: ["kitchen"]))
        XCTAssertEqual(books.map(\.title), ["The Home Kitchen", "Cook It in Cast Iron"], "newest first; the novel and the MOBI-only book are left out")
        let castIron = books[1]
        XCTAssertEqual(castIron.authors, ["America's Test Kitchen"])
        XCTAssertEqual(castIron.tags, ["Cookbook"])
        XCTAssertNotNil(castIron.dateAdded)
        XCTAssertEqual(castIron.exportURL.lastPathComponent, "Cook It in Cast Iron - Americas Test Kitchen.melarecipes")
        XCTAssertFalse(castIron.processed)
        try Data().write(to: castIron.exportURL)
        XCTAssertTrue(castIron.processed)
        XCTAssertEqual(try library.cookbooks(matching: CookbookFilter(tags: [], titleWords: ["cast iron"])).count, 1)
    }

    func testBookStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BookStore(key: "abc", root: root)
        var state = store.loadState(defaultTitle: "Book")
        state.ticked = ["r1", "r2"]
        state.exports.append(ExportRecord(date: Date(timeIntervalSince1970: 1000), file: "x.melarecipes", recipeIDs: ["r1"]))
        store.saveState(state)
        let again = try BookStore(key: "abc", root: root).loadState(defaultTitle: "Book")
        XCTAssertEqual(again.ticked, ["r1", "r2"])
        XCTAssertEqual(again.exportedDates["r1"], Date(timeIntervalSince1970: 1000))
        try store.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
}
