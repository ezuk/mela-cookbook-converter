import Foundation
import Observation
import MelaCore

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, toDo, processed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .toDo: return "To be processed"
        case .processed: return "Processed"
        }
    }
}

/// The home screen: cookbooks from the Calibre library.
@MainActor
@Observable
final class LibraryModel {
    var books: [CalibreBook] = []
    var filter: LibraryFilter = .toDo
    var search = ""
    var error: String?
    var isLoading = false
    private var watcher: DispatchSourceFileSystemObject?

    var visibleBooks: [CalibreBook] {
        books.filter { book in
            switch filter {
            case .all: break
            case .toDo: if book.processed { return false }
            case .processed: if !book.processed { return false }
            }
            return search.isEmpty || book.title.localizedCaseInsensitiveContains(search)
                || book.authors.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    func count(_ f: LibraryFilter) -> Int {
        switch f {
        case .all: return books.count
        case .toDo: return books.filter { !$0.processed }.count
        case .processed: return books.filter(\.processed).count
        }
    }

    func reload() {
        let settings = AppSettings.shared
        guard !settings.calibreLibraryPath.isEmpty else {
            books = []
            error = nil
            return
        }
        let root = URL(fileURLWithPath: settings.calibreLibraryPath)
        let filter = settings.filter
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result: Result<[CalibreBook], Error> = Result {
                try CalibreLibrary(root: root).cookbooks(matching: filter)
            }
            await MainActor.run {
                self.isLoading = false
                switch result {
                case .success(let books):
                    self.books = books
                    self.error = nil
                case .failure(let e):
                    self.books = []
                    self.error = "\(e)"
                }
                self.watch(root.appendingPathComponent("metadata.db"))
            }
        }
    }

    /// Refreshes when Calibre changes its database.
    private func watch(_ db: URL) {
        watcher?.cancel()
        let fd = open(db.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Removes a book from the list (it stays in Calibre). Undo from the Edit menu or Settings › Library.
    func exclude(_ book: CalibreBook, undoManager: UndoManager?) {
        AppSettings.shared.excludedBookIDs.insert(book.id)
        books.removeAll { $0.id == book.id }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.include(book.id) }
        }
        undoManager?.setActionName("Exclude “\(book.title)”")
    }

    func include(_ id: Int) {
        AppSettings.shared.excludedBookIDs.remove(id)
        reload()
    }

    /// Status line for a book card.
    func status(of book: CalibreBook) -> BookStatus {
        if book.processed { return .processed }
        if let s = RecentBooks.shared.byPath[book.epub.path], s.ticked > 0 || s.parsed > 0 {
            return .started(ticked: s.ticked, parsed: s.parsed)
        }
        return .toDo
    }
}

enum BookStatus: Equatable {
    case toDo, started(ticked: Int, parsed: Int), processed

    var label: String {
        switch self {
        case .toDo: return "To be processed"
        case let .started(ticked, parsed): return parsed > 0 ? "Started · \(parsed) parsed" : "Started · \(ticked) ticked"
        case .processed: return "Processed"
        }
    }
}
