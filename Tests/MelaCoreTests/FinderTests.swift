import XCTest
@testable import MelaCore

final class FinderTests: XCTestCase {
    func testFindsRecipesInSyntheticBook() throws {
        let p = try TestBook.cookbook().package()
        let result = RecipeFinder.find(package: p, map: BlockMap(package: p))
        XCTAssertEqual(result.profile?.titleStyle, "h2.rt")
        XCTAssertEqual(result.recipes.map(\.title), ["Basic Stock", "Tomato Soup", "Soft-Boiled Eggs"])
        XCTAssertEqual(result.recipes.map(\.chapter), ["Soups", "Soups", "Soups"])
        XCTAssertEqual(result.sections.map(\.title), ["A Note on Salt"])

        let stock = result.recipes[0], soup = result.recipes[1], eggs = result.recipes[2]
        XCTAssertEqual(stock.page, "12")
        XCTAssertEqual(stock.confidence, .high)
        XCTAssertEqual(stock.ingredientLines, 3)
        XCTAssertEqual(stock.stepLines, 2)
        // The captioned hero photo is picked; the step photo isn't.
        XCTAssertEqual(soup.photos, ["OEBPS/images/soup.jpg"])
        XCTAssertEqual(soup.ingredientLines, 4, "alternating classes stay one list")
        XCTAssertEqual(soup.uses, [stock.id])
        // No ingredient list, but steps and a yield: kept, low confidence.
        XCTAssertEqual(eggs.confidence, .low)
        XCTAssertEqual(eggs.ingredientLines, 0)
    }

    func testIDsAreStable() throws {
        let p = try TestBook.cookbook().package()
        let a = RecipeFinder.find(package: p, map: BlockMap(package: p))
        let b = RecipeFinder.find(package: p, map: BlockMap(package: p))
        XCTAssertEqual(a.recipes.map(\.id), b.recipes.map(\.id))
        XCTAssertEqual(Set(a.recipes.map(\.id)).count, 3)
    }

    func testOverrides() throws {
        let p = try TestBook.cookbook().package()
        let map = BlockMap(package: p)
        let first = RecipeFinder.find(package: p, map: map)
        var overrides = FinderOverrides()
        overrides.notRecipes = [first.recipes[0].id]
        overrides.markedRecipeStarts = [first.sections[0].start]
        let second = RecipeFinder.find(package: p, map: map, overrides: overrides)
        XCTAssertEqual(second.recipes.map(\.title), ["Tomato Soup", "Soft-Boiled Eggs", "A Note on Salt"])
        XCTAssertTrue(second.recipes.last!.manual)
    }

    func testTextPatterns() {
        XCTAssertTrue(TextPatterns.isIngredient("2 tbsp olive oil"))
        XCTAssertTrue(TextPatterns.isIngredient("½ cup beer"))
        XCTAssertTrue(TextPatterns.isIngredient("Kosher salt, 1 pinch"))
        XCTAssertFalse(TextPatterns.isIngredient("1 Place the butter in the pot and hit Sauté."))
        XCTAssertTrue(TextPatterns.isStep("1 Place the butter in the pot and hit Sauté."))
        XCTAssertTrue(TextPatterns.isStep("Step 2. Add the onions and cook for 5 minutes."))
        XCTAssertTrue(TextPatterns.isTimeOrYield("Prep Time 15 minutes"))
        XCTAssertTrue(TextPatterns.isTimeOrYield("SERVES 8 TO 10"))
        XCTAssertEqual(TextPatterns.numbers(in: "1½ cups, 8–10 minutes at 200°C"), ["1 1/2", "8", "10", "200"])
        XCTAssertEqual(RecipeFinder.displayTitle("JEFFREY’S BLUE RIBBON CHILI"), "Jeffrey’s Blue Ribbon Chili")
        XCTAssertEqual(RecipeFinder.displayTitle("SALT AND PEPPER SHRIMP"), "Salt and Pepper Shrimp")
        XCTAssertEqual(RecipeFinder.displayTitle("pesto gnocchi"), "pesto gnocchi")
    }
}

/// Runs the finder on the real reference cookbooks when they're available.
/// Point MELA_TEST_BOOKS at a folder holding the .epub files; the test skips otherwise.
final class AnswerKeyTests: XCTestCase {
    func testReferenceBooks() throws {
        let dir = ProcessInfo.processInfo.environment["MELA_TEST_BOOKS"] ?? ""
        guard !dir.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            throw XCTSkip("Set MELA_TEST_BOOKS to a folder with the reference ePubs")
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "answer-keys", withExtension: "json", subdirectory: "Fixtures"))
        let keys = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        var checked = 0
        for (fragment, titles) in keys {
            guard let file = names.first(where: { $0.contains(fragment) && $0.hasSuffix(".epub") }) else { continue }
            let p = try EPUBPackage(url: URL(fileURLWithPath: dir).appendingPathComponent(file))
            XCTAssertEqual(BookCheck.run(p), .ok, file)
            let found = Set(RecipeFinder.find(package: p, map: BlockMap(package: p)).recipes.map { TextPatterns.titleKey($0.title) })
            let expected = titles.map(TextPatterns.titleKey)
            let hits = expected.filter(found.contains).count
            let recall = Double(hits) / Double(expected.count)
            XCTAssertGreaterThanOrEqual(recall, 0.95, "\(file): recall \(recall)")
            checked += 1
        }
        if checked == 0 { throw XCTSkip("No reference ePubs in \(dir)") }
    }
}
