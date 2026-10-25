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
            VStack(spacing: 0) {
                HStack {
                    Text([r.chapter, r.page.map { "page \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Show", selection: $showBookPage) {
                        Text("Recipe").tag(false)
                        Text("Book Page").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button(book.isTicked(r.id) ? "Untick" : "Tick") { book.toggle(r.id) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                ForEach(r.uses, id: \.self) { usedID in
                    if let used = book.recipe(usedID) {
                        HStack {
                            Image(systemName: "link").foregroundStyle(Color.tomato)
                            Text("Uses **\(used.title)**\(Text(used.page.map { "  (page \($0))" } ?? "").foregroundStyle(.secondary))")
                            Spacer()
                            if book.isTicked(usedID) {
                                Text("Ticked").font(.caption.weight(.semibold)).foregroundStyle(Color.approvedGreen)
                            } else {
                                Button("Tick It Too") { book.toggle(usedID) }.controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
                if showBookPage {
                    BookPageView(container: book.package.container, target: pageTarget(for: r))
                } else {
                    RecipeReader(book: book, recipe: r)
                        .id(r.id)
                }
            }
        } else {
            ContentUnavailableView("Select a recipe", systemImage: "book.pages", description: Text("Its page from the book appears here."))
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
        let blocks = Array(book.map.blocks[recipe.start..<min(recipe.end, book.map.blocks.count)])
        let inlineImages = Set(blocks.flatMap(\.images))
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // The hero photo often sits just outside the recipe's range (its own file before or after).
                if let hero = recipe.photos.first, !inlineImages.contains(hero), let img = book.image(hero) {
                    photo(img)
                }
                ForEach(blocks, id: \.index) { b in
                    ForEach(b.images, id: \.self) { path in
                        if let img = book.image(path) { photo(img) }
                    }
                    if !b.text.isEmpty { line(b) }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .background(Color(red: 0.98, green: 0.97, blue: 0.95))
    }

    private func photo(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func line(_ b: Block) -> some View {
        let ink = Color(red: 0.16, green: 0.15, blue: 0.13)
        if b.index == recipe.start {
            Text(b.text).font(.system(.largeTitle, design: .serif)).foregroundStyle(ink).padding(.bottom, 4)
        } else if TextPatterns.isIngredient(b.text) {
            Text(b.text).font(.system(.body, design: .serif)).foregroundStyle(ink).padding(.leading, 14)
        } else if TextPatterns.isTimeOrYield(b.text) {
            Text(b.text).font(.system(.callout, design: .serif).weight(.semibold)).foregroundStyle(ink)
        } else if b.tag.hasPrefix("h") || (b.text.count < 40 && b.text == b.text.uppercased() && b.text.contains(where: \.isLetter)) || b.text.hasSuffix(":") {
            Text(b.text).font(.system(.headline, design: .serif)).foregroundStyle(ink).padding(.top, 6)
        } else {
            Text(b.text).font(.system(.body, design: .serif)).foregroundStyle(ink).lineSpacing(3)
        }
    }
}
