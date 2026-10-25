import Foundation

/// One block of the book in reading order: a paragraph, heading, list item,
/// table cell or a standalone image.
public struct Block: Sendable, Equatable, Codable {
    /// Stable id, "<spine file>#b<index within file>", for example "text/part0024_split_001.html#b12".
    public let id: String
    /// Position in the whole book.
    public let index: Int
    public let file: String
    public let tag: String
    public let cls: String
    public let text: String
    /// Element ids inside the block, so links and ToC fragments can be resolved to it.
    public let anchors: [String]
    /// Resolved zip paths of images inside the block.
    public let images: [String]
    /// Resolved internal link targets ("path#fragment").
    public let links: [String]
    /// The printed page in effect where the block starts, when the book marks pages.
    public let page: String?

    /// The book's layout key for this block, for example "p.ingredient".
    public var styleKey: String { cls.isEmpty ? tag : "\(tag).\(cls)" }
}

/// The whole book flattened into blocks, across spine files.
public struct BlockMap: Sendable {
    public let blocks: [Block]
    /// "path" and "path#anchor" → block index.
    public let anchorIndex: [String: Int]

    static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "div", "td", "th", "dt", "dd",
        "figcaption", "blockquote", "caption", "section", "article", "aside", "header", "footer", "figure", "pre",
    ]

    public init(package: EPUBPackage) {
        var blocks: [Block] = []
        var anchorIndex: [String: Int] = [:]
        var currentPage: String?

        // Page targets from the page list, if the book has one.
        var pageAnchors: [String: String] = [:]
        for target in package.pageList {
            pageAnchors[target.path + "#" + (target.fragment ?? "")] = target.label
        }

        for item in package.spine {
            guard item.mediaType.contains("html") || item.path.hasSuffix("html") || item.path.hasSuffix("htm"),
                  let html = package.container.string(item.path) else { continue }
            let file = item.path
            anchorIndex[file] = blocks.count
            var stack: [(tag: String, cls: String)] = []
            var text = ""
            var anchors: [String] = []
            var images: [String] = []
            var links: [String] = []
            var pageAtStart: String?
            var localIndex = 0
            var inBody = false

            func flush() {
                let t = text.replacingOccurrences(of: "[\\s\u{00A0}]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !t.isEmpty || !images.isEmpty {
                    let top = stack.last ?? ("div", "")
                    let index = blocks.count
                    blocks.append(Block(id: "\(file)#b\(localIndex)", index: index, file: file, tag: top.tag, cls: top.cls,
                                        text: t, anchors: anchors, images: images, links: links, page: pageAtStart ?? currentPage))
                    for a in anchors { anchorIndex["\(file)#\(a)"] = index }
                    localIndex += 1
                    anchors = []
                } else if !anchors.isEmpty {
                    // Anchors with no text of their own point at the next block.
                    for a in anchors { anchorIndex["\(file)#\(a)"] = blocks.count }
                    anchors = []
                }
                text = ""
                images = []
                links = []
                pageAtStart = nil
            }

            for token in HTMLTokenizer.tokenize(html) {
                switch token {
                case let .startTag(name, attrs, selfClosing):
                    if name == "body" { inBody = true; continue }
                    guard inBody else { continue }
                    if let id = attrs["id"] {
                        anchors.append(id)
                        if let label = BlockMap.pageLabel(name: name, attrs: attrs, id: id, file: file, pageAnchors: pageAnchors) {
                            currentPage = label
                            if text.isEmpty { pageAtStart = label }
                        }
                    } else if let label = BlockMap.pageLabel(name: name, attrs: attrs, id: nil, file: file, pageAnchors: pageAnchors) {
                        currentPage = label
                        if text.isEmpty { pageAtStart = label }
                    }
                    if name == "br" { text += " "; continue }
                    if name == "img" || name == "image" {
                        let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"]
                        if let src, let path = EPUBPath.resolve(src, relativeTo: file) { images.append(path) }
                        continue
                    }
                    if name == "a", let href = attrs["href"], let path = EPUBPath.resolve(href, relativeTo: file) {
                        let frag = EPUBPath.splitFragment(href).fragment
                        links.append(frag.map { "\(path)#\($0)" } ?? path)
                    }
                    if BlockMap.blockTags.contains(name), !selfClosing {
                        flush()
                        stack.append((name, attrs["class"] ?? ""))
                    }
                case .endTag(let name):
                    if name == "body" { flush(); inBody = false; continue }
                    if BlockMap.blockTags.contains(name) {
                        flush()
                        if let idx = stack.lastIndex(where: { $0.tag == name }) { stack.removeSubrange(idx...) }
                    } else if name == "p" || name.hasPrefix("h") {
                        flush()
                    }
                case .text(let t):
                    if inBody { text += t }
                }
            }
            flush()
        }
        self.blocks = blocks
        self.anchorIndex = anchorIndex
    }

    /// Detects a printed-page marker: `epub:type="pagebreak"`, a page-list target, or an id like "page-12" / "page_iv".
    static func pageLabel(name: String, attrs: [String: String], id: String?, file: String, pageAnchors: [String: String]) -> String? {
        if let id, let label = pageAnchors["\(file)#\(id)"] { return label }
        let type = (attrs["epub:type"] ?? "") + " " + (attrs["role"] ?? "")
        if type.contains("pagebreak") {
            return attrs["title"] ?? attrs["aria-label"] ?? id.flatMap(labelFromID)
        }
        if let id, let label = labelFromID(id) { return label }
        return nil
    }

    static func labelFromID(_ id: String) -> String? {
        let lower = id.lowercased()
        for prefix in ["page-", "page_", "pg-", "pg_", "page"] where lower.hasPrefix(prefix) {
            let rest = String(lower.dropFirst(prefix.count))
            if !rest.isEmpty, rest.count <= 5, rest.allSatisfy({ $0.isNumber }) || rest.allSatisfy({ "ivxlc".contains($0) }) {
                return rest
            }
        }
        return nil
    }

    /// Resolves "path#fragment" (or a ToC entry) to a block index.
    public func index(path: String, fragment: String?) -> Int? {
        if let fragment, let i = anchorIndex["\(path)#\(fragment)"] { return i }
        return anchorIndex[path]
    }
}
