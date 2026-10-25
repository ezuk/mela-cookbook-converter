import Foundation
import Observation
import AppKit
import MelaCore

enum SearchScope: String, CaseIterable, Identifiable {
    case titles, ingredients, everything
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all, ticked, hasPhoto, parsed, needsReview, failed, notExported, exported
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All recipes"
        case .ticked: return "Ticked"
        case .hasPhoto: return "Has photo"
        case .parsed: return "Parsed"
        case .needsReview: return "Needs review"
        case .failed: return "Failed"
        case .notExported: return "Not yet exported"
        case .exported: return "Exported"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "book"
        case .ticked: return "checkmark.square"
        case .hasPhoto: return "photo"
        case .parsed: return "text.badge.checkmark"
        case .needsReview: return "exclamationmark.circle"
        case .failed: return "xmark.octagon"
        case .notExported: return "tray"
        case .exported: return "tray.and.arrow.up"
        }
    }
}

/// A recipe's live status in the queue or after parsing.
enum RowState: Equatable {
    case none, waiting, parsing, approved, needsReview, failed(String)

    var label: String {
        switch self {
        case .none: return ""
        case .waiting: return "Waiting"
        case .parsing: return "Parsing"
        case .approved: return "Approved"
        case .needsReview: return "Needs review"
        case .failed: return "Failed"
        }
    }
}

struct ChapterGroup: Identifiable {
    let id: String
    let name: String
    var recipes: [RecipeCandidate]
}

/// One open book: what was found, what I ticked, parse results, edits and exports.
@MainActor
@Observable
final class BookModel {
    let url: URL
    let calibreBook: CalibreBook?
    let package: EPUBPackage
    let map: BlockMap
    private(set) var found: FindResult
    let check: BookCheckResult
    let store: BookStore
    private let storeKey: String

    var state: BookState { didSet { store.saveState(state); updateRecent() } }
    private(set) var parsed: [String: ParsedRecipe] = [:]
    private(set) var queueState: [String: RowState] = [:]
    var highlighted: Set<String> = []
    var search = ""
    var scope: SearchScope = .titles
    var sidebarFilter: SidebarFilter = .all
    var showAllSections = false
    var fixedLayoutWarningDismissed = false
    var queuePaused: EngineError?
    var isQueueRunning = false
    var undoManager: UndoManager?
    private var queue: ParseQueue?
    private var queueEngine: EngineKind?
    private var queueModel: String?
    /// Events from a replaced queue are ignored.
    private var queueGeneration = 0

    var title: String { MelaExporter.displayBookTitle(package.metadata.title) }
    var author: String { package.metadata.authors.joined(separator: ", ") }

    // MARK: Opening

    struct OpenError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Opens and checks a book off the main thread. Throws for refused books.
    static func open(url: URL, calibreBook: CalibreBook?) async throws -> BookModel {
        let loaded = try await Task.detached(priority: .userInitiated) { () throws -> (EPUBPackage, BookCheckResult, BlockMap, FindResult, String) in
            let package = try EPUBPackage(url: url)
            let check = BookCheck.run(package)
            if case .refused(let why) = check { throw OpenError(message: why.description) }
            let map = BlockMap(package: package)
            let key = BookStore.key(metadata: package.metadata, fileURL: url)
            let store = try BookStore(key: key)
            let overrides = store.loadState(defaultTitle: package.metadata.title).overrides
            return (package, check, map, RecipeFinder.find(package: package, map: map, overrides: overrides), key)
        }.value
        return try BookModel(url: url, calibreBook: calibreBook, package: loaded.0, check: loaded.1, map: loaded.2, found: loaded.3, key: loaded.4)
    }

    private init(url: URL, calibreBook: CalibreBook?, package: EPUBPackage, check: BookCheckResult, map: BlockMap, found: FindResult, key: String) throws {
        self.url = url
        self.calibreBook = calibreBook
        self.package = package
        self.check = check
        self.map = map
        self.found = found
        storeKey = key
        store = try BookStore(key: key)
        state = store.loadState(defaultTitle: package.metadata.title)
        parsed = store.loadParsed()
        state.lastOpened = Date()
        let ids = Set(found.recipes.map(\.id))
        state.ticked = state.ticked.intersection(ids)
        if let first = found.recipes.first { highlighted = [first.id] }
        updateRecent()
    }

    func updateRecent() {
        RecentBooks.shared.update(BookSummary(path: url.path, title: package.metadata.title, storeKey: storeKey,
                                              ticked: state.ticked.count, parsed: parsed.count, lastOpened: state.lastOpened))
    }

    // MARK: Lists

    var recipesByID: [String: RecipeCandidate] { Dictionary(uniqueKeysWithValues: found.recipes.map { ($0.id, $0) }) }

    func recipe(_ id: String) -> RecipeCandidate? { found.recipes.first { $0.id == id } }

    func rowState(_ id: String) -> RowState {
        if let q = queueState[id] { return q }
        guard let p = parsed[id] else { return .none }
        if state.approvedByMe.contains(id) { return .approved }
        switch p.state {
        case .approved, .exported: return .approved
        case .needsReview: return .needsReview
        case .failed: return .failed(p.error ?? "Failed")
        default: return .none
        }
    }

    func exportedDate(_ id: String) -> Date? { state.exportedDates[id] }

    private func matchesFilter(_ r: RecipeCandidate, _ f: SidebarFilter? = nil) -> Bool {
        switch f ?? sidebarFilter {
        case .all: return true
        case .ticked: return state.ticked.contains(r.id)
        case .hasPhoto: return !r.photos.isEmpty
        case .parsed: return parsed[r.id] != nil
        case .needsReview: return rowState(r.id) == .needsReview
        case .failed: if case .failed = rowState(r.id) { return true } else { return false }
        case .notExported: return exportedDate(r.id) == nil
        case .exported: return exportedDate(r.id) != nil
        }
    }

    private func matchesSearch(_ r: RecipeCandidate) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if r.title.localizedCaseInsensitiveContains(q) { return true }
        switch scope {
        case .titles: return false
        case .ingredients:
            return (r.start..<r.end).contains { k in TextPatterns.isIngredient(map.blocks[k].text) && map.blocks[k].text.localizedCaseInsensitiveContains(q) }
        case .everything:
            return (r.start..<r.end).contains { map.blocks[$0].text.localizedCaseInsensitiveContains(q) }
        }
    }

    /// The first matching line, for showing under a search result.
    func searchSnippet(_ r: RecipeCandidate) -> String? {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, scope != .titles else { return nil }
        return (r.start..<r.end).map { map.blocks[$0].text }.first { $0.localizedCaseInsensitiveContains(q) && $0 != r.title }
    }

    var visibleRecipes: [RecipeCandidate] {
        found.recipes.filter { matchesFilter($0, nil) && matchesSearch($0) && (showAllSections || $0.confidence == .high || state.ticked.contains($0.id) || $0.manual || isLowButLikely($0)) }
    }

    /// Low-confidence candidates with steps stay visible (dimmed); those with neither steps nor ingredients hide with sections.
    private func isLowButLikely(_ r: RecipeCandidate) -> Bool { r.stepLines >= 2 }

    var chapters: [ChapterGroup] {
        var groups: [ChapterGroup] = []
        for r in visibleRecipes {
            let name = r.chapter ?? "Other"
            if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].recipes.append(r) } else {
                groups.append(ChapterGroup(id: name, name: name, recipes: [r]))
            }
        }
        return groups
    }

    func count(_ f: SidebarFilter) -> Int {
        found.recipes.filter { matchesFilter($0, f) }.count
    }

    // MARK: Ticking (every change can be undone)

    private func setTicked(_ new: Set<String>, actionName: String) {
        let old = state.ticked
        guard old != new else { return }
        state.ticked = new
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setTicked(old, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }

    func isTicked(_ id: String) -> Bool { state.ticked.contains(id) }

    func toggle(_ id: String) {
        var t = state.ticked
        if t.contains(id) { t.remove(id) } else { t.insert(id) }
        setTicked(t, actionName: "Tick")
    }

    /// Space bar: ticks the highlighted rows, or unticks them if all are ticked.
    func toggleHighlighted() {
        guard !highlighted.isEmpty else { return }
        var t = state.ticked
        if highlighted.isSubset(of: t) { t.subtract(highlighted) } else { t.formUnion(highlighted) }
        setTicked(t, actionName: "Tick")
    }

    enum TriState { case off, mixed, on }

    func triState(_ ids: [String]) -> TriState {
        let n = ids.filter { state.ticked.contains($0) }.count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    /// Clicking a mixed or empty chapter ticks all of it; clicking a full one unticks all.
    func toggleGroup(_ ids: [String]) {
        var t = state.ticked
        if triState(ids) == .on { t.subtract(ids) } else { t.formUnion(ids) }
        setTicked(t, actionName: "Tick Chapter")
    }

    func tickAll(_ ids: [String], on: Bool) {
        var t = state.ticked
        if on { t.formUnion(ids) } else { t.subtract(ids) }
        setTicked(t, actionName: on ? "Tick All" : "Untick All")
    }

    // MARK: Marking recipes by hand

    func markAsRecipe(blockIndex: Int) {
        state.overrides.markedRecipeStarts.insert(blockIndex)
        refind()
    }

    func markNotRecipe(_ id: String) {
        state.overrides.notRecipes.insert(id)
        state.ticked.remove(id)
        refind()
    }

    private func refind() {
        found = RecipeFinder.find(package: package, map: map, overrides: state.overrides)
    }

    /// Headings to mark by hand when the finder found nothing.
    var headingBlocks: [Block] {
        map.blocks.filter { ["h1", "h2", "h3", "h4"].contains($0.tag) && !$0.text.isEmpty && $0.text.count < 90 }
    }

    // MARK: Parsing

    var tickedRecipes: [RecipeCandidate] { found.recipes.filter { state.ticked.contains($0.id) } }

    /// Ticked recipes not yet parsed (finished results are never re-sent).
    var toParse: [RecipeCandidate] { tickedRecipes.filter { parsed[$0.id] == nil || parsed[$0.id]?.state == .failed } }

    func source(for r: RecipeCandidate) -> RecipeSource {
        RecipeSource(candidate: r, map: map, bookTitle: package.metadata.title)
    }

    func startParsing(_ recipes: [RecipeCandidate], engine kind: EngineKind, model: String?, concurrency: Int) throws {
        let engine = try EngineFactory.make(kind)
        if queue == nil || queueEngine != kind || queueModel != model {
            queue?.cancelAllDetached()
            queueGeneration += 1
            let generation = queueGeneration
            queue = ParseQueue(engine: engine, model: model?.isEmpty == true ? nil : model, concurrency: concurrency, cache: store.cache) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    // A replaced queue's finished results still count; its other events don't.
                    if case .finished = event { self.handle(event) } else if self.queueGeneration == generation { self.handle(event) }
                }
            }
            queueEngine = kind
            queueModel = model
        }
        for r in recipes { queueState[r.id] = .waiting }
        isQueueRunning = true
        let sources = recipes.map(source(for:))
        let q = queue!
        Task { await q.enqueue(sources) }
    }

    func reparse(_ id: String, engine: EngineKind? = nil) {
        guard let r = recipe(id) else { return }
        parsed[id] = nil
        state.approvedByMe.remove(id)
        let kind = engine ?? queueEngine ?? AppSettings.shared.defaultEngine
        let model = AppSettings.shared.model(for: kind)
        // A re-parse must reach the model: drop the cached answer for this source.
        let key = ParsePipeline.cacheKey(source: source(for: r), engine: kind, model: model.isEmpty ? nil : model)
        try? FileManager.default.removeItem(at: store.cache.directory.appendingPathComponent("\(key).json"))
        try? startParsing([r], engine: kind, model: model, concurrency: AppSettings.shared.concurrency)
    }

    func pauseQueue() { if let q = queue { Task { await q.pause() } } }
    func resumeQueue() {
        queuePaused = nil
        if let q = queue { Task { await q.resume() } }
    }
    func cancel(_ id: String) { if let q = queue { Task { await q.cancel(id) } } }
    func cancelAll() { if let q = queue { Task { await q.cancelAll() } } }

    private func handle(_ event: ParseQueue.Event) {
        switch event {
        case .started(let id): queueState[id] = .parsing
        case .finished(let p):
            queueState[p.candidateID] = nil
            parsed[p.candidateID] = p
            store.saveParsed(p)
            updateRecent()
        case .paused(let error): queuePaused = error
        case .resumed: queuePaused = nil
        case .cancelled(let id): queueState[id] = nil
        case .idle: isQueueRunning = false
        }
    }

    var queueRows: [RecipeCandidate] {
        found.recipes.filter { queueState[$0.id] != nil || (parsed[$0.id] != nil && state.ticked.contains($0.id)) }
    }

    // MARK: Review

    /// The draft to show and export: my edits if any, else the parse.
    func draft(_ id: String) -> RecipeDraft? { state.edits[id] ?? parsed[id]?.draft }

    func isEdited(_ id: String) -> Bool { state.edits[id] != nil }

    func saveEdit(_ id: String, _ draft: RecipeDraft) {
        guard let original = parsed[id]?.draft else { return }
        state.edits[id] = draft == original ? nil : draft
    }

    func revertEdits(_ id: String) { state.edits[id] = nil }

    func approve(_ id: String) {
        state.approvedByMe.insert(id)
    }

    var reviewable: [RecipeCandidate] { found.recipes.filter { parsed[$0.id] != nil && parsed[$0.id]?.state != .failed } }

    func photos(_ id: String) -> [String] { state.photoOrder[id] ?? recipe(id)?.photos ?? [] }

    func setPhotos(_ id: String, _ paths: [String]) { state.photoOrder[id] = paths }

    func image(_ path: String) -> NSImage? {
        package.container.data(path).flatMap(NSImage.init(data:))
    }

    // MARK: Export

    var exportable: [RecipeCandidate] {
        tickedRecipes.filter { rowState($0.id) == .approved }
    }

    var defaultExportURL: URL {
        if let book = calibreBook, AppSettings.shared.saveNextToEPUB { return book.exportURL }
        let name = MelaExporter.displayBookTitle(package.metadata.title)
            .replacingOccurrences(of: "/", with: "-") + ".melarecipes"
        return URL(fileURLWithPath: AppSettings.shared.lastExportFolder).appendingPathComponent(name)
    }

    func export(_ recipes: [RecipeCandidate], options: ExportOptions, to url: URL) throws {
        let items = recipes.compactMap { r -> ExportItem? in
            guard let d = draft(r.id) else { return nil }
            return ExportItem(candidate: r, draft: d, photos: state.photoOrder[r.id])
        }
        try MelaExporter.export(items, book: package, map: map, options: options, to: url)
        state.exports.append(ExportRecord(date: Date(), file: url.path, recipeIDs: items.map(\.candidate.id)))
    }

    func forget() throws {
        try store.forget()
        RecentBooks.shared.remove(path: url.path)
    }
}

extension ParseQueue {
    nonisolated func cancelAllDetached() { Task { await self.cancelAll() } }
}

extension MelaExporter {
    static func displayBookTitle(_ t: String) -> String { shortTitle(t) }
}
