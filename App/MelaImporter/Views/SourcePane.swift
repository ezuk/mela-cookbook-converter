import SwiftUI
import WebKit
import MelaCore

/// The detail pane: the highlighted recipe's page, rendered from the book itself.
struct SourcePane: View {
    @Bindable var book: BookModel

    var body: some View {
        if let id = book.highlighted.first, let r = book.recipe(id) {
            VStack(spacing: 0) {
                HStack {
                    Text([r.chapter, r.page.map { "page \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(book.isTicked(r.id) ? "Untick" : "Tick") { book.toggle(r.id) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                ForEach(r.uses, id: \.self) { usedID in
                    if let used = book.recipe(usedID) {
                        HStack {
                            Image(systemName: "link").foregroundStyle(Color.tomato)
                            Text("Uses **\(used.title)**") + Text(used.page.map { "  (page \($0))" } ?? "").foregroundColor(.secondary)
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
                BookPageView(container: book.package.container, target: pageTarget(for: r))
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
        view.setValue(false, forKey: "drawsBackground")
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
