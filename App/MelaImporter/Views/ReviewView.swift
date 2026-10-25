import SwiftUI
import MelaCore

/// Review: the book's lines on the left, the parsed recipe on the right. Clicking a line of the
/// recipe highlights where it came from. Flagged lines wait for a decision.
struct ReviewView: View {
    @Bindable var book: BookModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @State private var highlightedBlocks: Set<Int> = []
    @State private var editing = false

    init(book: BookModel, startID: String) {
        self.book = book
        _currentID = State(initialValue: startID)
    }

    private var list: [RecipeCandidate] { book.reviewable }
    private var index: Int { list.firstIndex { $0.id == currentID } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let r = book.recipe(currentID), let parsed = book.parsed[currentID], let draft = book.draft(currentID) {
                HSplitView {
                    SourceLines(book: book, recipe: r, highlighted: highlightedBlocks, flagged: flaggedBlocks(parsed))
                        .frame(minWidth: 380)
                    Group {
                        if editing {
                            RecipeEditor(draft: draft) { edited in
                                book.saveEdit(currentID, edited)
                                editing = false
                            } cancel: { editing = false }
                        } else {
                            ParsedCard(book: book, recipe: r, parsed: parsed, draft: draft) { blocks in
                                highlightedBlocks = blocks
                            }
                        }
                    }
                    .frame(minWidth: 460, idealWidth: 560)
                }
            } else {
                ContentUnavailableView("Nothing to review yet", systemImage: "checklist")
            }
        }
        .focusedSceneValue(\.reviewActions, ReviewActions(approve: approve, reparse: { book.reparse(currentID) }))
        .onKeyPress(characters: ["j", "k"]) { press in
            guard !editing else { return .ignored }
            move(press.characters == "j" ? 1 : -1)
            return .handled
        }
        .onKeyPress(.downArrow) { guard !editing else { return .ignored }; move(1); return .handled }
        .onKeyPress(.upArrow) { guard !editing else { return .ignored }; move(-1); return .handled }
        .onChange(of: currentID) { _, _ in highlightedBlocks = []; editing = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ControlGroup {
                Button("Previous", systemImage: "chevron.left") { move(-1) }.disabled(index == 0)
                Button("Next", systemImage: "chevron.right") { move(1) }.disabled(index >= list.count - 1)
            }
            .fixedSize()
            if let r = book.recipe(currentID) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.draft(currentID)?.title ?? r.title).font(.headline).lineLimit(1)
                    Text(["\(index + 1) of \(list.count) parsed", r.chapter, r.page.map { "p. \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                StatePill(state: book.rowState(currentID))
                if book.isEdited(currentID) { Badge(text: "Edited by me", tint: .blue) }
            }
            Spacer()
            if book.isEdited(currentID) {
                Button("Revert Edits") { book.revertEdits(currentID) }
            }
            Button(editing ? "Editing…" : "Edit") { editing = true }.disabled(editing)
            Button("Re-parse") { book.reparse(currentID) }.help("⌘R")
            Button("Approve") { approve() }
                .buttonStyle(.borderedProminent)
                .tint(.tomato)
                .help("⌘↩")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func move(_ delta: Int) {
        let i = index + delta
        guard list.indices.contains(i) else { return }
        currentID = list[i].id
    }

    /// Approves and moves on to the next recipe that still needs review.
    private func approve() {
        book.approve(currentID)
        if let next = list.dropFirst(index + 1).first(where: { book.rowState($0.id) == .needsReview }) ?? list.first(where: { book.rowState($0.id) == .needsReview }) {
            currentID = next.id
        }
    }

    private func flaggedBlocks(_ p: ParsedRecipe) -> Set<Int> {
        Set(p.report.issues.flatMap(\.blocks))
    }
}

/// The recipe's blocks as text, with the selected line's source highlighted and flagged lines underlined.
struct SourceLines: View {
    let book: BookModel
    let recipe: RecipeCandidate
    let highlighted: Set<Int>
    let flagged: Set<Int>

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Source · \(MelaExporter.displayBookTitle(book.package.metadata.title))\(recipe.page.map { ", p. \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(recipe.start..<recipe.end), id: \.self) { k in
                        let b = book.map.blocks[k]
                        if !b.text.isEmpty {
                            Text(b.text)
                                .font(font(for: b))
                                .foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.13))
                                .underline(flagged.contains(k), pattern: .dot, color: .orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(highlighted.contains(k) ? Color.tomato.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 3))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(k)
                        }
                    }
                }
                .padding(24)
                .background(Color(red: 0.98, green: 0.97, blue: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(16)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: highlighted) { _, blocks in
                if let first = blocks.min() { withAnimation { proxy.scrollTo(first, anchor: .center) } }
            }
        }
    }

    private func font(for b: Block) -> Font {
        if b.index == recipe.start { return .system(.title, design: .serif) }
        if b.tag.hasPrefix("h") { return .system(.headline, design: .serif) }
        if TextPatterns.isIngredient(b.text) { return .system(.body, design: .serif) }
        return .system(.callout, design: .serif)
    }
}

/// The parsed recipe, Mela-style, with field status and per-line decisions.
struct ParsedCard: View {
    @Bindable var book: BookModel
    let recipe: RecipeCandidate
    let parsed: ParsedRecipe
    let draft: RecipeDraft
    let select: (Set<Int>) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PhotoStrip(book: book, recipeID: recipe.id)
                Text(draft.title).font(.system(.title, design: .serif))
                FlowLayout(spacing: 14) {
                    field("yield", "Yield", draft.yield)
                    field("prepTime", "Prep", draft.prepTime)
                    field("cookTime", "Cook", draft.cookTime)
                    field("totalTime", "Total", draft.totalTime)
                }
                if let head = draft.headnote, !head.isEmpty {
                    Text(head).font(.callout).italic().foregroundStyle(.secondary).lineLimit(6)
                }
                missingLines
                sectionTitle("Ingredients")
                ForEach(Array(draft.ingredientGroups.enumerated()), id: \.offset) { gi, group in
                    if let name = group.name { Text(name).font(.subheadline.weight(.semibold)).padding(.top, 4) }
                    ForEach(Array(group.items.enumerated()), id: \.offset) { ii, line in
                        LineRow(text: line.text, field: "Ingredient \(number(gi, ii, in: draft.ingredientGroups.map(\.items.count)))",
                                parsed: parsed, edited: book.isEdited(recipe.id)) { select(blocks(line)) }
                    }
                }
                sectionTitle("Method")
                ForEach(Array(draft.stepGroups.enumerated()), id: \.offset) { gi, group in
                    if let name = group.name { Text(name).font(.subheadline.weight(.semibold)).padding(.top, 4) }
                    ForEach(Array(group.steps.enumerated()), id: \.offset) { si, line in
                        LineRow(text: line.text, field: "Step \(number(gi, si, in: draft.stepGroups.map(\.steps.count)))",
                                parsed: parsed, edited: book.isEdited(recipe.id)) { select(blocks(line)) }
                    }
                }
                if !draft.notes.isEmpty {
                    sectionTitle("Notes")
                    ForEach(Array(draft.notes.enumerated()), id: \.offset) { _, note in
                        LineRow(text: note.text, field: "", parsed: parsed, edited: false) { select(blocks(RecipeDraft.Line(text: note.text, source: note.source))) }
                    }
                }
                legend
            }
            .padding(20)
        }
    }

    private var missingLines: some View {
        ForEach(parsed.report.issues.filter { $0.kind == .missingSourceLine }, id: \.self) { issue in
            if let k = issue.blocks.first {
                let text = book.map.blocks[k].text
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not in the parsed recipe: “\(text)”").foregroundStyle(Color.reviewAmber)
                    HStack {
                        Button("Add to Ingredients") { add(text, block: k, asStep: false) }
                        Button("Add to Method") { add(text, block: k, asStep: true) }
                        Button("Not Needed") { book.approve(recipe.id) }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .onTapGesture { select([k]) }
            }
        }
    }

    private func add(_ text: String, block: Int, asStep: Bool) {
        var d = draft
        let label = book.source(for: recipe).lines.first { $0.blockIndex == block }?.label ?? ""
        let line = RecipeDraft.Line(text: asStep ? text.replacingOccurrences(of: #"^\d{1,2}[.)]?\s+"#, with: "", options: .regularExpression) : text, source: [label])
        if asStep {
            if d.stepGroups.isEmpty { d.stepGroups = [.init(name: nil, steps: [])] }
            d.stepGroups[d.stepGroups.count - 1].steps.append(line)
        } else {
            // Put it back in book order among the ingredients.
            if d.ingredientGroups.isEmpty { d.ingredientGroups = [.init(name: nil, items: [])] }
            let src = book.source(for: recipe)
            let order = { (l: RecipeDraft.Line) -> Int in l.source.compactMap { s in src.line(s)?.blockIndex }.min() ?? Int.max }
            var placed = false
            for g in d.ingredientGroups.indices where !placed {
                if let i = d.ingredientGroups[g].items.firstIndex(where: { order($0) > block }) {
                    d.ingredientGroups[g].items.insert(line, at: i)
                    placed = true
                }
            }
            if !placed { d.ingredientGroups[d.ingredientGroups.count - 1].items.append(line) }
        }
        book.saveEdit(recipe.id, d)
        book.approve(recipe.id)
    }

    private func blocks(_ line: RecipeDraft.Line) -> Set<Int> {
        let src = book.source(for: recipe)
        return Set(line.source.compactMap { src.line($0)?.blockIndex })
    }

    private func number(_ group: Int, _ item: Int, in counts: [Int]) -> Int {
        counts.prefix(group).reduce(0, +) + item + 1
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 8)
    }

    private func field(_ key: String, _ label: String, _ value: String?) -> some View {
        let status = Checker.fieldStatus(draft, field: key)
        return HStack(spacing: 5) {
            StatusDot(status: status)
            Text(value.map { "\(label) \($0)" } ?? "\(label): not in book")
                .foregroundStyle(status == .missing ? .secondary : .primary)
            if status == .inferred { Text("worked out · not exported").font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    private var legend: some View {
        FlowLayout(spacing: 14) {
            HStack(spacing: 4) { StatusDot(status: .found); Text("Found in book") }
            HStack(spacing: 4) { StatusDot(status: .inferred); Text("Worked out") }
            HStack(spacing: 4) { StatusDot(status: .missing); Text("Missing") }
            HStack(spacing: 4) { Circle().fill(Color.orange).frame(width: 8, height: 8); Text("Needs a decision") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 14)
    }
}

struct StatusDot: View {
    let status: FieldStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityLabel(status.rawValue)
    }
    private var color: Color {
        switch status {
        case .found: return .approvedGreen
        case .inferred: return .blue
        case .missing: return .secondary.opacity(0.5)
        case .edited: return .purple
        }
    }
}

struct LineRow: View {
    let text: String
    let field: String
    let parsed: ParsedRecipe
    let edited: Bool
    let tap: () -> Void

    var body: some View {
        let issue = parsed.report.issues.first { !field.isEmpty && $0.field == field }
        let fix = parsed.report.fixes.first { !field.isEmpty && $0.field == field }
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(issue == nil ? Color.approvedGreen : Color.orange).frame(width: 7, height: 7)
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
                if let fix { Text("Fixed from book · model wrote “\(fix.modelText)”").font(.caption).foregroundStyle(.secondary) }
            }
            if let issue {
                Text(issue.message).font(.caption).foregroundStyle(Color.reviewAmber).padding(.leading, 15)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(issue == nil ? Color.clear : Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}

/// Up to three photos; the first is Mela's main photo.
struct PhotoStrip: View {
    @Bindable var book: BookModel
    let recipeID: String

    var body: some View {
        let photos = book.photos(recipeID)
        if !photos.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element) { i, path in
                    ZStack(alignment: .bottomLeading) {
                        if let img = book.image(path) {
                            Image(nsImage: img).resizable().scaledToFill()
                                .frame(width: i == 0 ? 200 : 110, height: 130).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if i == 0 {
                            Badge(text: "Main", tint: .white).padding(6).background(.black.opacity(0.4), in: Capsule()).padding(6)
                        }
                    }
                    .contextMenu {
                        if i > 0 { Button("Make Main Photo") { var p = photos; p.remove(at: i); p.insert(path, at: 0); book.setPhotos(recipeID, p) } }
                        Button("Remove Photo") { book.setPhotos(recipeID, photos.filter { $0 != path }) }
                    }
                    .draggable(path)
                    .dropDestination(for: String.self) { items, _ in
                        guard let moved = items.first, let from = photos.firstIndex(of: moved) else { return false }
                        var p = photos
                        p.remove(at: from)
                        p.insert(moved, at: min(i, p.count))
                        book.setPhotos(recipeID, p)
                        return true
                    }
                }
            }
        }
    }
}

/// Plain-text editing: one ingredient or step per line, "# Name" starts a group.
struct RecipeEditor: View {
    let draft: RecipeDraft
    let save: (RecipeDraft) -> Void
    let cancel: () -> Void
    @State private var title = ""
    @State private var yield = ""
    @State private var prep = ""
    @State private var cook = ""
    @State private var total = ""
    @State private var headnote = ""
    @State private var ingredients = ""
    @State private var steps = ""
    @State private var notes = ""

    var body: some View {
        Form {
            TextField("Title", text: $title)
            TextField("Yield", text: $yield)
            HStack {
                TextField("Prep", text: $prep)
                TextField("Cook", text: $cook)
                TextField("Total", text: $total)
            }
            Section("Headnote") { TextEditor(text: $headnote).frame(minHeight: 60) }
            Section("Ingredients · one per line, “# Name” starts a group") { TextEditor(text: $ingredients).frame(minHeight: 160) }
            Section("Method · one step per line") { TextEditor(text: $steps).frame(minHeight: 160) }
            Section("Notes · one per line") { TextEditor(text: $notes).frame(minHeight: 60) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save Edits") { save(edited()) }.buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        title = draft.title
        yield = draft.yield ?? ""
        prep = draft.prepTime ?? ""
        cook = draft.cookTime ?? ""
        total = draft.totalTime ?? ""
        headnote = draft.headnote ?? ""
        ingredients = draft.ingredientGroups.flatMap { g in (g.name.map { ["# \($0)"] } ?? []) + g.items.map(\.text) }.joined(separator: "\n")
        steps = draft.stepGroups.flatMap { g in (g.name.map { ["# \($0)"] } ?? []) + g.steps.map(\.text) }.joined(separator: "\n")
        notes = draft.notes.map(\.text).joined(separator: "\n")
    }

    private func edited() -> RecipeDraft {
        var d = draft
        func opt(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        d.title = title.trimmingCharacters(in: .whitespaces)
        d.yield = opt(yield); d.prepTime = opt(prep); d.cookTime = opt(cook); d.totalTime = opt(total); d.headnote = opt(headnote)
        // Keep each line's source when its text didn't change.
        let oldSources = Dictionary((draft.allIngredients + draft.allSteps).map { ($0.text, $0.source) }, uniquingKeysWith: { a, _ in a })
        func groups(_ text: String) -> [(String?, [RecipeDraft.Line])] {
            var out: [(String?, [RecipeDraft.Line])] = []
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if line.hasPrefix("#") {
                    out.append((line.drop { $0 == "#" || $0 == " " }.description, []))
                } else {
                    if out.isEmpty { out.append((nil, [])) }
                    out[out.count - 1].1.append(RecipeDraft.Line(text: line, source: oldSources[line] ?? []))
                }
            }
            return out
        }
        d.ingredientGroups = groups(ingredients).map { .init(name: $0.0, items: $0.1) }
        d.stepGroups = groups(steps).map { .init(name: $0.0, steps: $0.1) }
        let oldNotes = Dictionary(draft.notes.map { ($0.text, $0) }, uniquingKeysWith: { a, _ in a })
        d.notes = notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { oldNotes[$0] ?? .init(kind: .other, text: $0, source: []) }
        for (field, old, new) in [("yield", draft.yield, d.yield), ("prepTime", draft.prepTime, d.prepTime), ("cookTime", draft.cookTime, d.cookTime), ("totalTime", draft.totalTime, d.totalTime)] where old != new {
            d.inferred.removeAll { $0 == field }
        }
        return d
    }
}
