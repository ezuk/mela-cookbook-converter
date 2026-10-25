import Foundation

public struct ManifestItem: Sendable, Equatable {
    public let id: String
    public let path: String       // resolved zip path
    public let mediaType: String
    public let properties: Set<String>
}

public struct TOCEntry: Sendable, Equatable {
    public let title: String
    public let path: String       // resolved zip path
    public let fragment: String?
    public let depth: Int
    public let isLeaf: Bool
}

public struct PageTarget: Sendable, Equatable {
    public let label: String
    public let path: String
    public let fragment: String?
}

public struct BookMetadata: Sendable, Equatable, Codable {
    public var title: String
    public var authors: [String]
    public var language: String?
    public var isbn: String?
    public var identifier: String?
    public var publisher: String?
}

/// The parsed OPF package: metadata, manifest, spine and table of contents.
public struct EPUBPackage: Sendable {
    public let container: EPUBContainer
    public let packagePath: String
    public let metadata: BookMetadata
    public let manifest: [String: ManifestItem]
    public let spine: [ManifestItem]
    public let toc: [TOCEntry]
    public let pageList: [PageTarget]
    public let isFixedLayout: Bool
    public let coverImagePath: String?

    public init(container: EPUBContainer) throws {
        self.container = container
        guard let containerXML = container.string("META-INF/container.xml") else { throw EPUBError.missingContainer }
        var rootfile: String?
        for case let .startTag(name, attrs, _) in HTMLTokenizer.tokenize(containerXML) where name == "rootfile" {
            if attrs["media-type"] == nil || attrs["media-type"] == "application/oebps-package+xml" {
                rootfile = attrs["full-path"]
                break
            }
        }
        guard let opfPath = rootfile, let opf = container.string(opfPath) else {
            throw EPUBError.missingPackage(rootfile ?? "(none)")
        }
        packagePath = opfPath
        let tokens = HTMLTokenizer.tokenize(opf)

        var title = "", authors: [String] = [], language: String?, publisher: String?
        var identifiers: [(scheme: String?, value: String, id: String?)] = []
        var uniqueID: String?
        var manifest: [String: ManifestItem] = [:]
        var spineRefs: [String] = []
        var tocID: String?
        var fixed = false
        var coverID: String?

        var i = 0
        func textUntilEnd(_ name: String) -> String {
            var s = ""
            var j = i + 1
            while j < tokens.count {
                if case .endTag(let n) = tokens[j], n == name { break }
                if case .text(let t) = tokens[j] { s += t }
                j += 1
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while i < tokens.count {
            if case let .startTag(name, attrs, selfClosing) = tokens[i] {
                switch name {
                case "package": uniqueID = attrs["unique-identifier"]
                case "title" where title.isEmpty: title = textUntilEnd("title")
                case "creator": let a = textUntilEnd("creator"); if !a.isEmpty { authors.append(a) }
                case "language" where language == nil: language = textUntilEnd("language")
                case "publisher" where publisher == nil: publisher = textUntilEnd("publisher")
                case "identifier":
                    identifiers.append((attrs["opf:scheme"] ?? attrs["scheme"], textUntilEnd("identifier"), attrs["id"]))
                case "meta":
                    if attrs["property"] == "rendition:layout", !selfClosing, textUntilEnd("meta") == "pre-paginated" { fixed = true }
                    if attrs["name"] == "cover" { coverID = attrs["content"] }
                case "item":
                    if let id = attrs["id"], let href = attrs["href"], let path = EPUBPath.resolve(href, relativeTo: opfPath) {
                        let props = Set((attrs["properties"] ?? "").split(separator: " ").map(String.init))
                        manifest[id] = ManifestItem(id: id, path: path, mediaType: attrs["media-type"] ?? "", properties: props)
                    }
                case "spine": tocID = attrs["toc"]
                case "itemref":
                    if let ref = attrs["idref"], attrs["linear"] != "no" { spineRefs.append(ref) }
                default: break
                }
            }
            i += 1
        }

        let isbn = identifiers.compactMap { ident -> String? in
            let v = ident.value
            if ident.scheme?.uppercased() == "ISBN" || v.lowercased().hasPrefix("urn:isbn:") || v.lowercased().hasPrefix("isbn:") {
                let digits = v.filter { $0.isNumber || $0 == "X" || $0 == "x" }
                return digits.count == 10 || digits.count == 13 ? digits : nil
            }
            return nil
        }.first
        let unique = identifiers.first { $0.id != nil && $0.id == uniqueID }?.value ?? identifiers.first?.value
        metadata = BookMetadata(title: title, authors: authors, language: language, isbn: isbn, identifier: unique, publisher: publisher)
        self.manifest = manifest
        spine = spineRefs.compactMap { manifest[$0] }
        isFixedLayout = fixed

        var cover = manifest.values.first { $0.properties.contains("cover-image") }?.path
        if cover == nil, let coverID, let item = manifest[coverID], item.mediaType.hasPrefix("image/") { cover = item.path }
        coverImagePath = cover

        // Table of contents: prefer the EPUB 3 nav document, fall back to the NCX.
        var toc: [TOCEntry] = []
        var pages: [PageTarget] = []
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }), let navHTML = container.string(nav.path) {
            (toc, pages) = EPUBPackage.parseNav(navHTML, basePath: nav.path)
        }
        if toc.isEmpty {
            let ncxItem = tocID.flatMap { manifest[$0] } ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncxItem, let ncx = container.string(ncxItem.path) {
                let parsed = EPUBPackage.parseNCX(ncx, basePath: ncxItem.path)
                toc = parsed.toc
                if pages.isEmpty { pages = parsed.pages }
            }
        }
        self.toc = toc
        pageList = pages
    }

    public init(url: URL) throws {
        try self.init(container: EPUBContainer(url: url))
    }

    static func parseNCX(_ xml: String, basePath: String) -> (toc: [TOCEntry], pages: [PageTarget]) {
        // Each navPoint: (title, src, depth); a navPoint is emitted when its <content> is seen.
        var stack: [(title: String, emitted: Bool)] = []
        var raw: [(title: String, href: String, depth: Int)] = []
        var pages: [PageTarget] = []
        var inPageTarget = false, inText = false
        var pageLabel = "", pageSrc: String?
        for token in HTMLTokenizer.tokenize(xml) {
            switch token {
            case .startTag("navpoint", _, _): stack.append(("", false))
            case .endTag("navpoint"): _ = stack.popLast()
            case .startTag("pagetarget", _, _): inPageTarget = true; pageLabel = ""; pageSrc = nil
            case .startTag("text", _, _): inText = true
            case .endTag("text"): inText = false
            case .text(let t) where inText:
                if inPageTarget { pageLabel += t } else if let last = stack.indices.last, !stack[last].emitted { stack[last].title += t }
            case .startTag("content", let attrs, _):
                if inPageTarget { pageSrc = attrs["src"] } else if let last = stack.indices.last, !stack[last].emitted, let src = attrs["src"] {
                    stack[last].emitted = true
                    raw.append((stack[last].title, src, last))
                }
            case .endTag("pagetarget"):
                inPageTarget = false
                if let src = pageSrc, let path = EPUBPath.resolve(src, relativeTo: basePath) {
                    pages.append(PageTarget(label: pageLabel.trimmingCharacters(in: .whitespacesAndNewlines), path: path, fragment: EPUBPath.splitFragment(src).fragment))
                }
            default: break
            }
        }
        return (makeTOC(raw, basePath: basePath), pages)
    }

    static func makeTOC(_ raw: [(title: String, href: String, depth: Int)], basePath: String) -> [TOCEntry] {
        var toc: [TOCEntry] = []
        for (n, r) in raw.enumerated() {
            guard let path = EPUBPath.resolve(r.href, relativeTo: basePath) else { continue }
            let isLeaf = n + 1 >= raw.count || raw[n + 1].depth <= r.depth
            let title = r.title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            toc.append(TOCEntry(title: title, path: path, fragment: EPUBPath.splitFragment(r.href).fragment, depth: r.depth, isLeaf: isLeaf))
        }
        return toc
    }

    static func parseNav(_ html: String, basePath: String) -> (toc: [TOCEntry], pages: [PageTarget]) {
        enum Kind { case toc, pages, other }
        var kind: Kind?
        var navDepth = 0
        var olDepth = 0
        var current: (title: String, href: String, depth: Int)?
        var tocRaw: [(title: String, href: String, depth: Int)] = []
        var pages: [PageTarget] = []
        for token in HTMLTokenizer.tokenize(html) {
            switch token {
            case .startTag("nav", let attrs, _):
                navDepth += 1
                let type = attrs["epub:type"] ?? attrs["role"] ?? ""
                kind = type.contains("toc") ? .toc : type.contains("page-list") || type.contains("doc-pagelist") ? .pages : .other
                olDepth = 0
            case .endTag("nav"):
                navDepth -= 1
                kind = nil
            case .startTag("ol", _, _): olDepth += 1
            case .endTag("ol"): olDepth -= 1
            case .startTag("a", let attrs, _) where kind != nil:
                current = ("", attrs["href"] ?? "", max(0, olDepth - 1))
            case .text(let t) where current != nil:
                current!.title += t
            case .endTag("a"):
                if let c = current {
                    if kind == .toc { tocRaw.append(c) }
                    if kind == .pages, let path = EPUBPath.resolve(c.href, relativeTo: basePath) {
                        pages.append(PageTarget(label: c.title.trimmingCharacters(in: .whitespacesAndNewlines), path: path, fragment: EPUBPath.splitFragment(c.href).fragment))
                    }
                }
                current = nil
            default: break
            }
        }
        return (makeTOC(tocRaw, basePath: basePath), pages)
    }
}
