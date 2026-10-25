import SwiftUI
import AppKit
import MelaCore

/// Home: the cookbooks in the Calibre library, with progress and filters.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16, alignment: .top)]

    var body: some View {
        @Bindable var library = app.library
        Group {
            if AppSettings.shared.calibreLibraryPath.isEmpty {
                setupState
            } else if let error = library.error {
                ContentUnavailableView {
                    Label("Can’t read the Calibre library", systemImage: "books.vertical")
                } description: {
                    Text(error)
                } actions: {
                    Button("Library Settings…") { openSettings() }
                }
            } else if library.books.isEmpty && !library.isLoading {
                ContentUnavailableView {
                    Label("No cookbooks found", systemImage: "fork.knife")
                } description: {
                    Text("No book in the library has your cookbook tags or title words.")
                } actions: {
                    Button("Library Settings…") { openSettings() }
                    Button("Open ePub…") { app.showOpenPanel() }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(library.visibleBooks) { book in
                            BookCard(book: book, status: library.status(of: book)) {
                                app.open(url: book.epub, calibreBook: book)
                            } exclude: {
                                library.exclude(book, undoManager: undoManager)
                            }
                        }
                    }
                    .padding(20)
                    if library.visibleBooks.isEmpty {
                        Text(library.filter == .processed ? "Nothing processed yet." : "Everything here is processed.")
                            .foregroundStyle(.secondary)
                            .padding(40)
                    }
                }
            }
        }
        .navigationTitle("Cookbooks")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $library.filter) {
                    ForEach(LibraryFilter.allCases) { f in
                        Text("\(f.title) \(library.count(f))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem {
                Button("Open ePub…", systemImage: "plus") { app.showOpenPanel() }
                    .help("Open a cookbook that isn’t in Calibre")
            }
        }
        .searchable(text: $library.search, prompt: "Search titles")
        .onAppear { library.reload() }
    }

    private var subtitle: String {
        let s = AppSettings.shared
        let tags = s.cookbookTags.joined(separator: " or ")
        return tags.isEmpty ? "From your Calibre library" : "From Calibre · tagged \(tags) · \(app.library.books.count) books"
    }

    private var setupState: some View {
        ContentUnavailableView {
            Label("Show your Calibre cookbooks here", systemImage: "books.vertical")
        } description: {
            Text("Choose your Calibre library and the tags that mark a cookbook. You can also open any DRM-free ePub, or drop one on this window.")
        } actions: {
            Button("Choose Calibre Library…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.message = "Choose the folder that holds metadata.db"
                if panel.runModal() == .OK, let url = panel.url {
                    AppSettings.shared.calibreLibraryPath = url.path
                    app.library.reload()
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Open ePub…") { app.showOpenPanel() }
        }
    }
}

struct BookCard: View {
    let book: CalibreBook
    let status: BookStatus
    let open: () -> Void
    let exclude: () -> Void
    @State private var cover: NSImage?

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                BookCover(title: book.title, author: book.authors.first ?? "", image: cover)
                Text(MelaExporter.displayBookTitle(book.title))
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(book.title)
                Badge(text: status.label, tint: tint)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.title), \(status.label)")
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.epub]) }
            if book.processed {
                Button("Show Export in Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.exportURL]) }
            }
            Divider()
            Button("Exclude", action: exclude)
                .help("Remove it from this list. It stays in Calibre.")
        }
        .task(id: book.cover) {
            guard let url = book.cover else { return }
            cover = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }

    private var tint: Color {
        switch status {
        case .processed: return .approvedGreen
        case .started: return .reviewAmber
        case .toDo: return .secondary
        }
    }
}
