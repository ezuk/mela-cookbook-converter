import Foundation
@testable import MelaCore

/// Builds small in-memory ePubs for tests.
struct TestBook {
    var files: [String: Data] = [:]
    var spine: [String] = []
    var manifestExtras: [(id: String, href: String, type: String, props: String)] = []
    var metadataExtras = ""
    var navHTML: String?
    var ncx: String?

    mutating func add(_ path: String, _ text: String) { files[path] = Data(text.utf8) }

    mutating func chapter(_ name: String, body: String) {
        add("OEBPS/\(name)", """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>x</title><style>p { color: red; }</style></head>
        <body>\(body)</body></html>
        """)
        spine.append(name)
    }

    func container() -> EPUBContainer {
        var all = files
        all["mimetype"] = Data("application/epub+zip".utf8)
        all["META-INF/container.xml"] = Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8)
        var manifest = spine.enumerated().map { "<item id=\"s\($0.offset)\" href=\"\($0.element)\" media-type=\"application/xhtml+xml\"/>" }
        for extra in manifestExtras {
            manifest.append("<item id=\"\(extra.id)\" href=\"\(extra.href)\" media-type=\"\(extra.type)\" properties=\"\(extra.props)\"/>")
        }
        if let navHTML {
            manifest.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
            all["OEBPS/nav.xhtml"] = Data(navHTML.utf8)
        }
        if let ncx {
            manifest.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
            all["OEBPS/toc.ncx"] = Data(ncx.utf8)
        }
        let itemrefs = spine.indices.map { "<itemref idref=\"s\($0)\"/>" }.joined()
        all["OEBPS/content.opf"] = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>Test Kitchen</dc:title>
            <dc:creator>Ada Cook</dc:creator>
            <dc:language>en</dc:language>
            <dc:identifier id="uid">urn:uuid:11111111-2222-3333-4444-555555555555</dc:identifier>
            <dc:identifier opf:scheme="ISBN">978-0-00-000000-2</dc:identifier>
            \(metadataExtras)
          </metadata>
          <manifest>\(manifest.joined(separator: "\n"))</manifest>
          <spine\(ncx != nil ? " toc=\"ncx\"" : "")>\(itemrefs)</spine>
        </package>
        """.utf8)
        return EPUBContainer(files: all)
    }

    func package() throws -> EPUBPackage { try EPUBPackage(container: container()) }

    /// A small cookbook: one chapter with an intro, three recipes (one uses another, one has no ingredient list).
    static func cookbook() -> TestBook {
        var book = TestBook()
        book.files["OEBPS/images/soup.jpg"] = Data(repeating: 7, count: 20_000)
        book.files["OEBPS/images/step.jpg"] = Data(repeating: 8, count: 20_000)
        book.chapter("ch1.xhtml", body: """
        <h1 class="chap" id="c1">Soups</h1>
        <p class="intro">Soup is the heart of winter cooking, and these are the ones I make most.</p>
        <span epub:type="pagebreak" id="page_12" title="12"/>
        <h2 class="rt" id="r1">Basic Stock</h2>
        <p class="yield">Makes 2 litres</p>
        <p class="ing">1 kg chicken wings</p>
        <p class="ing">2 onions, halved</p>
        <p class="ing">3 litres water</p>
        <p class="step">1 Put everything in a large pan and bring to a simmer.</p>
        <p class="step">2 Simmer for 3 hours, skimming now and then. Strain.</p>
        <span epub:type="pagebreak" id="page_13" title="13"/>
        <div class="photo"><img src="images/soup.jpg" alt=""/></div>
        <p class="caption">Tomato Soup</p>
        <h2 class="rt" id="r2">TOMATO SOUP</h2>
        <p class="note">Prep time<br/>10<br/>minutes</p>
        <p class="ing">1 kg tomatoes</p>
        <p class="ing">500 ml Basic Stock (page 12)</p>
        <p class="ing2">½ teaspoon salt</p>
        <p class="ing">2 tbsp olive oil</p>
        <p class="step">1 Roast the tomatoes at 200°C for 30 minutes.</p>
        <div class="photo"><img src="images/step.jpg" alt=""/></div>
        <p class="step">2 Blend with the stock and season.</p>
        """)
        book.chapter("ch2.xhtml", body: """
        <h2 class="rt" id="r3">Soft-Boiled Eggs</h2>
        <p class="yield">Serves 2</p>
        <p class="step">1 Bring a pan of water to the boil and lower in the eggs.</p>
        <p class="step">2 Cook for 6 minutes, then cool under running water.</p>
        <h2 class="rt" id="a1">A Note on Salt</h2>
        <p class="intro">Salt early and taste often. That is all there is to it, really.</p>
        """)
        book.ncx = """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
          <navPoint id="n1"><navLabel><text>Soups</text></navLabel><content src="ch1.xhtml#c1"/>
            <navPoint id="n2"><navLabel><text>Basic Stock</text></navLabel><content src="ch1.xhtml#r1"/></navPoint>
            <navPoint id="n3"><navLabel><text>Tomato Soup</text></navLabel><content src="ch1.xhtml#r2"/></navPoint>
            <navPoint id="n4"><navLabel><text>Soft-Boiled Eggs</text></navLabel><content src="ch2.xhtml#r3"/></navPoint>
          </navPoint>
        </navMap></ncx>
        """
        return book
    }
}
