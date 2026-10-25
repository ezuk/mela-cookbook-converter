import SwiftUI
import AppKit
import MelaCore

struct ReviewTarget: Identifiable, Hashable { let id: String }

/// The book window: filters, the recipe outline or gallery, and the book's page.
struct BookView: View {
    @Bindable var book: BookModel
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var showParse = false
    @State private var showQueue = false
    @State private var showExport = false
    @State private var review: ReviewTarget?

    var body: some View {
        NavigationSplitView {
            BookSidebar(book: book)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            VStack(spacing: 0) {
                if case .warning(let w) = book.check, !book.fixedLayoutWarningDismissed {
                    WarningBanner(text: w.description) { book.fixedLayoutWarningDismissed = true }
                }
                if !book.search.isEmpty {
                    SearchBar(book: book)
                }
                Group {
                    if book.found.recipes.isEmpty {
                        NoRecipesView(book: book)
                    } else if book.state.mode == .outline {
                        RecipeOutline(book: book, review: $review)
                    } else {
                        RecipeGallery(book: book, review: $review)
                    }
                }
                .frame(maxHeight: .infinity)
                TickBar(book: book, showParse: $showParse)
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            SourcePane(book: book)
        }
        .navigationTitle(book.title)
        .navigationSubtitle(book.author)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Cookbooks", systemImage: "chevron.backward") { app.closeBook() }
                    .help("Back to your cookbooks")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $book.state.mode) {
                    Label("Outline", systemImage: "list.bullet").tag(BrowseMode.outline)
                    Label("Gallery", systemImage: "square.grid.2x2").tag(BrowseMode.gallery)
                }
                .pickerStyle(.segmented)
                .help("Outline ⌘1 · Gallery ⌘2")
            }
            ToolbarItem {
                Button {
                    showQueue.toggle()
                } label: {
                    Label("Queue", systemImage: book.isQueueRunning ? "hourglass" : "list.bullet.rectangle")
                }
                .help("Parse queue")
                .popover(isPresented: $showQueue, arrowEdge: .bottom) {
                    QueueView(book: book, review: $review)
                        .frame(width: 520, height: 460)
                }
            }
            ToolbarItem {
                Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                    .disabled(book.exportable.isEmpty)
                    .help("Export approved recipes for Mela")
            }
        }
        .searchable(text: $book.search, placement: .toolbar, prompt: "Search recipes")
        .searchScopes($book.scope) {
            ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
        }
        .focusedSceneValue(\.bookModel, book)
        .sheet(isPresented: $showParse) {
            ParseSheet(book: book) { showQueue = true }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(book: book)
        }
        .sheet(item: $review) { target in
            ReviewView(book: book, startID: target.id)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .onAppear { book.undoManager = undoManager }
        .onChange(of: book.queuePaused) { _, paused in if paused != nil { showQueue = true } }
        // A sheet can't open over the queue popover: close it first.
        .onChange(of: review) { _, r in if r != nil { showQueue = false } }
    }
}

struct BookSidebar: View {
    @Bindable var book: BookModel

    var body: some View {
        List(selection: Binding(get: { book.sidebarFilter }, set: { book.sidebarFilter = $0 ?? .all })) {
            Section {
                HStack(spacing: 10) {
                    BookCover(title: book.title, author: book.author, image: book.package.coverImagePath.flatMap { book.image($0) })
                        .frame(width: 40)
                    VStack(alignment: .leading) {
                        Text(book.title).font(.headline).lineLimit(2)
                        Text(book.author).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            }
            Section("Recipes") {
                row(.all); row(.ticked); row(.hasPhoto)
            }
            Section("Progress") {
                row(.parsed); row(.needsReview); row(.failed); row(.notExported); row(.exported)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show all sections", isOn: $book.showAllSections)
                Text("\(book.found.sections.count) intros, essays and charts hidden")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private func row(_ f: SidebarFilter) -> some View {
        Label(f.title, systemImage: f.symbol)
            .badge(book.count(f))
            .tag(f)
    }
}

struct WarningBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }
}

/// Bulk ticking for search results. Ticks outside the results are kept.
struct SearchBar: View {
    @Bindable var book: BookModel

    var body: some View {
        let ids = book.visibleRecipes.map(\.id)
        HStack {
            Text("\(ids.count) results").foregroundStyle(.secondary)
            Spacer()
            Button("Tick all \(ids.count)") { book.tickAll(ids, on: true) }.disabled(ids.isEmpty)
            Button("Untick all \(ids.count)") { book.tickAll(ids, on: false) }.disabled(ids.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct TickBar: View {
    @Bindable var book: BookModel
    @Binding var showParse: Bool

    var body: some View {
        let n = book.state.ticked.count
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(n == 1 ? "1 recipe ticked" : "\(n) recipes ticked").font(.headline)
                Text("Space ticks highlighted rows · ⌘Z undoes").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Parse \(book.toParse.count)…") { showParse = true }
                .buttonStyle(.borderedProminent)
                .tint(.tomato)
                .disabled(book.toParse.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// When the finder found nothing: mark recipes by hand from the book's headings.
struct NoRecipesView: View {
    @Bindable var book: BookModel

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView("No recipes spotted",
                                   systemImage: "magnifyingglass",
                                   description: Text("Pick the headings that start a recipe."))
                .frame(height: 180)
            List(book.headingBlocks, id: \.index) { block in
                HStack {
                    Text(block.text)
                    Spacer()
                    Button("Mark as Recipe") { book.markAsRecipe(blockIndex: block.index) }.controlSize(.small)
                }
            }
        }
    }
}
