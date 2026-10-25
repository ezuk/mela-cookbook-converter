import SwiftUI
import AppKit
import MelaCore

/// Outline view: chapters with tri-state checkboxes. Clicking selects rows like any Mac list;
/// the checkbox means "import this"; Space ticks the highlighted rows.
struct RecipeOutline: View {
    @Bindable var book: BookModel
    @Binding var review: ReviewTarget?

    var body: some View {
        List(selection: $book.highlighted) {
            ForEach(book.chapters) { group in
                Section {
                    ForEach(group.recipes) { r in
                        RecipeRow(book: book, recipe: r)
                            .tag(r.id)
                            .contextMenu { RecipeMenu(book: book, recipe: r, review: $review) }
                    }
                } header: {
                    let ids = group.recipes.map(\.id)
                    let ticked = ids.filter { book.isTicked($0) }.count
                    HStack(spacing: 8) {
                        TriStateCheckbox(state: book.triState(ids), label: "\(group.name), \(ticked) of \(ids.count) ticked") {
                            book.toggleGroup(ids)
                        }
                        Text(group.name).font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Text("\(ticked) of \(ids.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if book.showAllSections && !book.found.sections.isEmpty {
                Section("Other sections") {
                    ForEach(book.found.sections, id: \.start) { s in
                        Text(s.title)
                            .foregroundStyle(.secondary)
                            .contextMenu { Button("Mark as Recipe") { book.markAsRecipe(blockIndex: s.start) } }
                    }
                }
            }
        }
        .onKeyPress(.space) {
            book.toggleHighlighted()
            return .handled
        }
        .onKeyPress(.return) {
            if let id = book.highlighted.first, book.parsed[id] != nil { review = ReviewTarget(id: id) }
            return .handled
        }
    }
}

struct RecipeRow: View {
    @Bindable var book: BookModel
    let recipe: RecipeCandidate

    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(state: book.isTicked(recipe.id) ? .on : .off, label: "Tick \(recipe.title)") {
                book.toggle(recipe.id)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(recipe.title)
                    .foregroundStyle(recipe.confidence == .low ? .secondary : .primary)
                    .lineLimit(1)
                if let snippet = book.searchSnippet(recipe) {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if recipe.confidence == .low { Badge(text: "Not sure this is a recipe") }
            if let date = book.exportedDate(recipe.id) {
                Badge(text: "Exported \(date.formatted(.dateTime.month(.abbreviated).day()))", tint: .approvedGreen)
            }
            StatePill(state: book.rowState(recipe.id))
            if !recipe.photos.isEmpty {
                Image(systemName: "photo").foregroundStyle(.tertiary).accessibilityLabel("Has photo")
            }
            if let page = recipe.page {
                Text("p. \(page)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct RecipeMenu: View {
    @Bindable var book: BookModel
    let recipe: RecipeCandidate
    @Binding var review: ReviewTarget?

    var body: some View {
        Button(book.isTicked(recipe.id) ? "Untick" : "Tick") { book.toggle(recipe.id) }
        if book.parsed[recipe.id] != nil {
            Button("Review…") { review = ReviewTarget(id: recipe.id) }
            Button("Re-parse") { book.reparse(recipe.id) }
            Button("Re-parse with \(AppSettings.shared.defaultEngine.other.displayName)") {
                book.reparse(recipe.id, engine: AppSettings.shared.defaultEngine.other)
            }
        }
        Divider()
        Button("Not a Recipe") { book.markNotRecipe(recipe.id) }
    }
}

/// Gallery view: cards with the book's photos, grouped by chapter.
struct RecipeGallery: View {
    @Bindable var book: BookModel
    @Binding var review: ReviewTarget?
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(book.chapters) { group in
                    let ids = group.recipes.map(\.id)
                    HStack(spacing: 8) {
                        TriStateCheckbox(state: book.triState(ids), label: "\(group.name), \(ids.filter { book.isTicked($0) }.count) of \(ids.count) ticked") {
                            book.toggleGroup(ids)
                        }
                        Text(group.name).font(.system(.title2, design: .serif))
                        Text("\(ids.filter { book.isTicked($0) }.count) of \(ids.count) ticked").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(group.recipes) { r in
                            GalleryCard(book: book, recipe: r)
                                .contextMenu { RecipeMenu(book: book, recipe: r, review: $review) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

struct GalleryCard: View {
    @Bindable var book: BookModel
    let recipe: RecipeCandidate
    @State private var photo: NSImage?

    var body: some View {
        let selected = book.highlighted.contains(recipe.id)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let photo {
                        Image(nsImage: photo).resizable().scaledToFill()
                    } else {
                        Text(recipe.title)
                            .font(.system(.title3, design: .serif).italic())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.eyebrow)
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.paper)
                    }
                }
                .frame(height: 140)
                .clipped()
                TriStateCheckbox(state: book.isTicked(recipe.id) ? .on : .off, label: "Tick \(recipe.title)") { book.toggle(recipe.id) }
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.title).font(.headline).lineLimit(2)
                HStack {
                    if let p = recipe.page { Text("p. \(p)").font(.caption).foregroundStyle(.secondary) }
                    StatePill(state: book.rowState(recipe.id))
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.tomato : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1) }
        .contentShape(Rectangle())
        .onTapGesture { book.highlighted = [recipe.id] }
        .gentleAnimation(value: book.isTicked(recipe.id))
        .task(id: recipe.photos.first) {
            if let path = recipe.photos.first { photo = book.image(path) }
        }
    }
}
