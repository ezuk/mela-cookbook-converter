import SwiftUI
import WebKit
import AppKit
import MelaCore

/// The detail pane: the highlighted recipe's page, rendered from the book itself.
struct SourcePane: View {
    @Bindable var book: BookModel
    /// Text: the whole recipe drawn from its blocks. Book page: the ePub's own layout of its first file.
    @AppStorage("detailShowsBookPage") private var showBookPage = false

    var body: some View {
        if let id = book.highlighted.first, let r = book.recipe(id) {
            let ticked = book.isTicked(r.id)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("Show", selection: $showBookPage) {
                        Text("Recipe").tag(false)
                        Text("Book Page").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if showBookPage {
                        Text([r.chapter, r.page.map { "page \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { book.toggle(r.id) } label: {
                        Label(ticked ? "Ticked" : "Tick", systemImage: ticked ? "checkmark.circle.fill" : "circle")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .foregroundStyle(ticked ? Color.tomatoText : Color.primary)
                    .help(ticked ? "Untick this recipe" : "Tick this recipe to parse it")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                ForEach(r.uses, id: \.self) { usedID in
                    if let used = book.recipe(usedID) {
                        HStack {
                            Image(systemName: "link").foregroundStyle(Color.tomatoText)
                            Text("Uses **\(used.title)**\(Text(used.page.map { "  (page \($0))" } ?? "").foregroundStyle(.secondary))")
                            Spacer()
                            if book.isTicked(usedID) {
                                Text("Ticked").font(.caption.weight(.semibold)).foregroundStyle(Color.approvedGreen)
                            } else {
                                Button("Tick It Too") { book.toggle(usedID) }.controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)) }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                }
                if showBookPage {
                    BookPageView(container: book.package.container, target: pageTarget(for: r))
                } else {
                    RecipeReader(book: book, recipe: r)
                        .id(r.id)
                }
            }
            .background(Color.pane)
        } else {
            ContentUnavailableView("Select a recipe", systemImage: "book.pages", description: Text("The whole recipe from the book appears here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.pane)
        }
    }

    /// The recipe's file, with the nearest anchor at or before its first block so the page opens scrolled to it.
    func pageTarget(for r: RecipeCandidate) -> BookPageView.Target {
        let blocks = book.map.blocks
        let file = blocks[r.start].file
        var k = r.start
        while k >= 0, blocks[k].file == file {
            if let a = blocks[k].anchors.first { return .init(path: file, fragment: a) }
            k -= 1
        }
        return .init(path: file, fragment: nil)
    }
}

/// Renders XHTML from the ePub through a custom URL scheme. JavaScript is off and every
/// non-book URL is blocked, so a book can't reach the network.
struct BookPageView: NSViewRepresentable {
    struct Target: Equatable {
        let path: String
        let fragment: String?
    }

    static let scheme = "epub-book"
    let container: EPUBContainer
    let target: Target

    func makeCoordinator() -> Coordinator { Coordinator(container: container) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: Self.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        // Block everything that isn't the book itself.
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^epub-book:"},"action":{"type":"ignore-previous-rules"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "book-only", encodedContentRuleList: rules) { list, _ in
            if let list { view.configuration.userContentController.add(list) }
            context.coordinator.rulesReady = true
            context.coordinator.loadPending(in: view)
        }
        context.coordinator.pending = target
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != target else { return }
        context.coordinator.pending = target
        context.coordinator.loadPending(in: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        let container: EPUBContainer
        var pending: Target?
        var loaded: Target?
        var rulesReady = false

        init(container: EPUBContainer) { self.container = container }

        func loadPending(in view: WKWebView) {
            guard rulesReady, let t = pending else { return }
            pending = nil
            loaded = t
            var c = URLComponents()
            c.scheme = BookPageView.scheme
            c.host = "book"
            c.path = "/" + t.path
            c.fragment = t.fragment
            if let url = c.url { view.load(URLRequest(url: url)) }
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let path = String(url.path.dropFirst())
            guard let data = container.data(path) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = URLResponse(url: url, mimeType: Self.mimeType(path), expectedContentLength: data.count, textEncodingName: "utf-8")
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.scheme == BookPageView.scheme ? .allow : .cancel)
        }

        static func mimeType(_ path: String) -> String {
            switch (path as NSString).pathExtension.lowercased() {
            case "xhtml", "xht": return "application/xhtml+xml"
            case "html", "htm": return "text/html"
            case "css": return "text/css"
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "gif": return "image/gif"
            case "svg": return "image/svg+xml"
            case "webp": return "image/webp"
            case "otf": return "font/otf"
            case "ttf": return "font/ttf"
            case "woff": return "font/woff"
            case "woff2": return "font/woff2"
            default: return "application/octet-stream"
            }
        }
    }
}

/// The recipe as it is in the book, read straight from the ePub: every block of its range,
/// across however many files the book split it into, with its photos. No parsing needed.
struct RecipeReader: View {
    let book: BookModel
    let recipe: RecipeCandidate

    var body: some View {
        let page = ReaderPage(book: book, recipe: recipe)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let hero = page.hero, let img = book.image(hero) {
                    heroPhoto(img)
                }
                VStack(alignment: .leading, spacing: 14) {
                    header(page)
                    ForEach(page.intro) { piece($0, intro: true) }
                    if !page.ingredients.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 28) {
                                column(page.ingredients, spacing: 7)
                                    .frame(width: 220, alignment: .leading)
                                column(page.method, spacing: 12)
                                    .frame(minWidth: 240, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 22) {
                                column(page.ingredients, spacing: 7)
                                column(page.method, spacing: 12)
                            }
                        }
                        .padding(.top, 6)
                    } else {
                        column(page.method, spacing: 12)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, page.hero == nil ? 34 : 26)
                .padding(.bottom, 40)
            }
            .background(Color.paper)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.paperEdge) }
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
    }

    private func header(_ page: ReaderPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !page.eyebrow.isEmpty {
                Text(page.eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.eyebrow)
            }
            Text(page.title)
                .font(.system(size: 30, weight: .medium, design: .serif))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !page.meta.isEmpty {
                FlowLayout(spacing: 16) {
                    ForEach(page.meta, id: \.self) { m in
                        Label {
                            Text(m).foregroundStyle(Color.ink)
                        } icon: {
                            Image(systemName: Self.symbol(forMeta: m)).foregroundStyle(Color.eyebrow)
                        }
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 4)
    }

    private func column(_ pieces: [ReaderPage.Piece], spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(pieces) { piece($0, intro: false) }
        }
    }

    @ViewBuilder
    private func piece(_ p: ReaderPage.Piece, intro: Bool) -> some View {
        switch p.kind {
        case .photo:
            if let img = book.image(p.text) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Photo from the book")
            }
        case .meta:
            Text(p.text)
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(Color.ink)
        case .heading:
            Text(p.text)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.eyebrow)
                .padding(.top, 8)
        case .ingredient:
            Text(p.text)
                .font(.system(size: 14.5, design: .serif))
                .foregroundStyle(Color.ink)
                .lineSpacing(2)
        case .step:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(p.number ?? "")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.tomatoText)
                    .frame(minWidth: 16, alignment: .trailing)
                prose(p.text)
            }
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Color.eyebrow)
                prose(p.text)
            }
        case .paragraph:
            if intro {
                Text(p.text)
                    .font(.system(size: 15, design: .serif).italic())
                    .foregroundStyle(Color.inkSoft)
                    .lineSpacing(5)
            } else {
                prose(p.text)
            }
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, design: .serif))
            .foregroundStyle(Color.ink)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The main photo across the top of the page, cropped no taller than 1.85:1.
    private func heroPhoto(_ img: NSImage) -> some View {
        let aspect = img.size.height > 0 ? max(img.size.width / img.size.height, 1.85) : 1.85
        return Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { Image(nsImage: img).resizable().scaledToFill() }
            .clipped()
            .accessibilityLabel("Photo from the book")
    }

    static func symbol(forMeta text: String) -> String {
        let t = text.lowercased()
        if t.hasPrefix("serves") || t.contains("serving") || t.contains("portion") { return "person.2" }
        if t.contains("time") || t.hasPrefix("prep") || t.hasPrefix("cook") { return "clock" }
        return "fork.knife"
    }
}

/// A recipe's blocks sorted for reading: header, intro, then ingredients beside the method.
/// Everything stays in book order; it only decides how each block looks.
struct ReaderPage {
    struct Piece: Identifiable {
        enum Kind { case photo, meta, heading, ingredient, step, bullet, paragraph }
        let id: String
        let kind: Kind
        /// The block's text, or the image path for a photo.
        let text: String
        var number: String?
    }

    /// The recipe's own first photo, else the one the finder picked from beside it.
    var hero: String?
    let eyebrow: String
    let title: String
    /// Times and yields before the ingredients.
    var meta: [String] = []
    /// Headnote and photos before the ingredients.
    var intro: [Piece] = []
    /// Set when the ingredients form one list (with group headings) before the method.
    var ingredients: [Piece] = []
    /// The method, or the whole recipe in book order when the ingredients are split up.
    var method: [Piece] = []

    /// Images smaller than this are ornaments and rules, not photos.
    static let minimumPhotoBytes = 12_000
    static let stepNumber = try! NSRegularExpression(pattern: "^(?:[Ss]tep\\s*)?(\\d{1,2})[.):]?\\s+")

    @MainActor
    init(book: BookModel, recipe r: RecipeCandidate) {
        let blocks = book.map.blocks[r.start..<min(r.end, book.map.blocks.count)]
        eyebrow = [r.chapter, r.page.map { "Page \($0)" }].compactMap { $0 }.joined(separator: "  ·  ")
        title = r.title

        var pieces: [Piece] = []
        var listStyle: String?
        var label: Block?
        for (i, b) in zip(blocks.indices, blocks) {
            for (k, path) in b.images.enumerated() where (book.package.container.data(path)?.count ?? 0) >= Self.minimumPhotoBytes {
                pieces.append(Piece(id: "\(b.index).\(k)", kind: .photo, text: path))
            }
            guard b.index != r.start, !b.text.isEmpty else { continue }
            // "PREP TIME:" and its value are often separate blocks.
            if let l = label {
                label = nil
                let joined = "\(l.text) \(b.text)"
                if b.text.count < 100, TextPatterns.isTimeOrYield(joined) {
                    pieces.removeAll { $0.id == "\(l.index)" }
                    pieces.append(Piece(id: "\(l.index)", kind: .meta, text: joined))
                    continue
                }
            }
            let nextText = blocks[(i + 1)...].first { !$0.text.isEmpty }?.text ?? ""
            let p = Self.piece(b, continuesList: listStyle != nil && (b.styleKey == listStyle || TextPatterns.isIngredient(nextText)))
            if p.kind == .ingredient { listStyle = b.styleKey } else if p.kind != .heading { listStyle = nil }
            if b.text.hasSuffix(":"), b.text.count < 25 { label = b }
            pieces.append(p)
        }

        // Photos at the very end that the finder gave to the next recipe belong to it, with their captions.
        if let next = book.found.recipes.first(where: { $0.start >= r.end }) {
            let theirs = Set(next.photos)
            var cut: Int?
            for i in pieces.indices.reversed() {
                if pieces[i].kind == .photo {
                    if theirs.contains(pieces[i].text) { cut = i }
                } else if pieces[i].text.count > 80 || pieces[i].kind == .step || pieces[i].kind == .ingredient {
                    break
                }
            }
            if let cut { pieces.removeSubrange(cut...) }
        }

        // The intro runs up to the first ingredient or step, less any headings that label it.
        var split = pieces.firstIndex { $0.kind == .ingredient || $0.kind == .step } ?? pieces.count
        while split > 0, pieces[split - 1].kind == .heading { split -= 1 }
        if let i = pieces[..<split].firstIndex(where: { $0.kind == .photo }) {
            hero = pieces.remove(at: i).text
            split -= 1
        } else if let photo = r.photos.first {
            hero = photo
            pieces.removeAll { $0.kind == .photo && $0.text == photo }
            split = min(split, pieces.count)
        }
        for p in pieces[..<split] {
            if p.kind == .meta { meta.append(p.text) } else { intro.append(p) }
        }
        let main = Array(pieces[split...])
        let ingredientIndices = main.indices.filter { main[$0].kind == .ingredient }
        if let last = ingredientIndices.last, ingredientIndices.count >= 2, last + 1 < main.count,
           main[...last].allSatisfy({ $0.kind == .ingredient || $0.kind == .heading }) {
            ingredients = Array(main[...last])
            method = Array(main[(last + 1)...])
        } else {
            method = main
        }
    }

    /// How one block looks. `continuesList`: an ingredient comes before it, in its style or with another after it.
    static func piece(_ b: Block, continuesList: Bool) -> Piece {
        let t = b.text
        let id = "\(b.index)"
        if TextPatterns.isTimeOrYield(t) { return Piece(id: id, kind: .meta, text: t) }
        if TextPatterns.isStep(t), let m = stepNumber.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let num = Range(m.range(at: 1), in: t), let all = Range(m.range, in: t) {
            return Piece(id: id, kind: .step, text: String(t[all.upperBound...]), number: String(t[num]))
        }
        if TextPatterns.isIngredient(t) { return Piece(id: id, kind: .ingredient, text: t) }
        let shortCaps = t.count < 40 && t == t.uppercased() && t.contains(where: \.isLetter)
        if b.tag.hasPrefix("h") || shortCaps || (t.hasSuffix(":") && t.count < 40) {
            return Piece(id: id, kind: .heading, text: t.trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
        }
        if continuesList, t.count < 100 { return Piece(id: id, kind: .ingredient, text: t) }
        if let first = t.first, "–—-•·▪".contains(first), t.count > 2 {
            return Piece(id: id, kind: .bullet, text: t.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        return Piece(id: id, kind: .paragraph, text: t)
    }
}
