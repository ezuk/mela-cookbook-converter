import XCTest
@testable import MelaCore

final class TokenizerTests: XCTestCase {
    func testEntitiesAttributesAndRawText() {
        let tokens = HTMLTokenizer.tokenize(#"<p class='a' id=x>Salt &amp; pepper&nbsp;&#189; &frac12;<br/></p><script>if (a<b) {}</script><style>p{}</style>"#)
        XCTAssertEqual(tokens[0], .startTag(name: "p", attributes: ["class": "a", "id": "x"], selfClosing: false))
        XCTAssertEqual(tokens[1], .text("Salt & pepper\u{00A0}½ ½"))
        XCTAssertEqual(tokens[2], .startTag(name: "br", attributes: [:], selfClosing: true))
        XCTAssertEqual(tokens[3], .endTag(name: "p"))
        XCTAssertFalse(tokens.contains(.text("if (a<b) {}")))
        XCTAssertEqual(tokens.last, .endTag(name: "style"))
    }

    func testCommentsCDATAAndStrayLessThan() {
        let tokens = HTMLTokenizer.tokenize("<!-- hi --><p>1 < 2</p><![CDATA[x<y]]>")
        XCTAssertEqual(tokens, [.startTag(name: "p", attributes: [:], selfClosing: false), .text("1 < 2"), .endTag(name: "p"), .text("x<y")])
    }

    func testNamespacedNames() {
        XCTAssertEqual(HTMLTokenizer.localName("dc:Title"), "title")
        XCTAssertEqual(HTMLTokenizer.localName("epub:switch"), "epub:switch")
    }
}

final class PathTests: XCTestCase {
    func testResolve() {
        XCTAssertEqual(EPUBPath.resolve("../images/a%20b.jpg", relativeTo: "OEBPS/text/ch1.html"), "OEBPS/images/a b.jpg")
        XCTAssertEqual(EPUBPath.resolve("ch2.html#x", relativeTo: "OEBPS/ch1.html"), "OEBPS/ch2.html")
        XCTAssertEqual(EPUBPath.resolve("#x", relativeTo: "OEBPS/ch1.html"), "OEBPS/ch1.html")
        XCTAssertNil(EPUBPath.resolve("https://example.com/a", relativeTo: "OEBPS/ch1.html"))
        XCTAssertEqual(EPUBPath.splitFragment("a.html#f").fragment, "f")
    }
}

final class PackageTests: XCTestCase {
    func testMetadataSpineAndNCX() throws {
        let p = try TestBook.cookbook().package()
        XCTAssertEqual(p.metadata.title, "Test Kitchen")
        XCTAssertEqual(p.metadata.authors, ["Ada Cook"])
        XCTAssertEqual(p.metadata.isbn, "9780000000002")
        XCTAssertEqual(p.metadata.identifier, "urn:uuid:11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(p.spine.map(\.path), ["OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml"])
        XCTAssertEqual(p.toc.map(\.title), ["Soups", "Basic Stock", "Tomato Soup", "Soft-Boiled Eggs"])
        XCTAssertEqual(p.toc.map(\.depth), [0, 1, 1, 1])
        XCTAssertEqual(p.toc.map(\.isLeaf), [false, true, true, true])
        XCTAssertEqual(p.toc[1].fragment, "r1")
    }

    func testNavDocumentAndPageList() throws {
        var book = TestBook()
        book.chapter("a.xhtml", body: "<h1 id='h'>A</h1>")
        book.navHTML = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol><li><a href="a.xhtml#h">Part One</a><ol><li><a href="a.xhtml">Leaf</a></li></ol></li></ol></nav>
        <nav epub:type="page-list"><ol><li><a href="a.xhtml#p1">1</a></li></ol></nav>
        </body></html>
        """
        book.metadataExtras = #"<meta property="rendition:layout">pre-paginated</meta>"#
        let p = try book.package()
        XCTAssertEqual(p.toc.map(\.title), ["Part One", "Leaf"])
        XCTAssertEqual(p.toc.map(\.isLeaf), [false, true])
        XCTAssertEqual(p.pageList, [PageTarget(label: "1", path: "OEBPS/a.xhtml", fragment: "p1")])
        XCTAssertTrue(p.isFixedLayout)
        XCTAssertEqual(BookCheck.run(p), .warning(.fixedLayout))
    }
}

final class BookCheckTests: XCTestCase {
    func encryption(_ algorithm: String, _ uri: String) -> String {
        """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="\(algorithm)"/>
          <enc:CipherData><enc:CipherReference URI="\(uri)"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """
    }

    func testDRMFreeAndFontObfuscationPass() throws {
        var book = TestBook.cookbook()
        XCTAssertEqual(BookCheck.run(try book.package()), .ok)
        book.add("META-INF/encryption.xml", encryption("http://www.idpf.org/2008/embedding", "OEBPS/fonts/a.otf"))
        XCTAssertEqual(BookCheck.run(try book.package()), .ok)
        book.add("META-INF/encryption.xml", encryption("http://ns.adobe.com/pdf/enc#RC", "fonts/00001.ttf"))
        XCTAssertEqual(BookCheck.run(try book.package()), .ok)
    }

    func testDRMIsRefused() throws {
        var book = TestBook.cookbook()
        book.add("META-INF/encryption.xml", encryption("http://ns.adobe.com/pdf/enc#RC", "OEBPS/ch1.xhtml"))
        guard case .refused(.drm) = BookCheck.run(try book.package()) else { return XCTFail("obfuscated text must be refused") }
        book.add("META-INF/encryption.xml", encryption("http://www.w3.org/2001/04/xmlenc#aes128-cbc", "OEBPS/ch1.xhtml"))
        guard case .refused(.drm) = BookCheck.run(try book.package()) else { return XCTFail("AES must be refused") }
        var lcp = TestBook.cookbook()
        lcp.add("META-INF/license.lcpl", "{}")
        XCTAssertEqual(BookCheck.run(try lcp.package()), .refused(.drm("Readium LCP")))
    }

    func testScannedBookIsRefused() throws {
        var book = TestBook()
        for i in 0..<10 { book.chapter("p\(i).xhtml", body: "<div><img src='img\(i).jpg'/></div>") }
        guard case .refused(.scanned(let img, let total)) = BookCheck.run(try book.package()) else { return XCTFail() }
        XCTAssertEqual(img, 10)
        XCTAssertEqual(total, 10)
    }
}

final class BlockMapTests: XCTestCase {
    func testBlocksPagesImagesAndAnchors() throws {
        let p = try TestBook.cookbook().package()
        let map = BlockMap(package: p)
        let stock = try XCTUnwrap(map.blocks.first { $0.text == "Basic Stock" })
        XCTAssertEqual(stock.page, "12")
        XCTAssertEqual(stock.styleKey, "h2.rt")
        XCTAssertEqual(map.index(path: "OEBPS/ch1.xhtml", fragment: "r1"), stock.index)
        let prep = try XCTUnwrap(map.blocks.first { $0.text.hasPrefix("Prep time") })
        XCTAssertEqual(prep.text, "Prep time 10 minutes")
        XCTAssertEqual(prep.page, "13")
        let photo = try XCTUnwrap(map.blocks.first { !$0.images.isEmpty })
        XCTAssertEqual(photo.images, ["OEBPS/images/soup.jpg"])
        XCTAssertTrue(map.blocks.last!.id.hasPrefix("OEBPS/ch2.xhtml#b"))
    }

    func testPageLabelsFromIDs() {
        XCTAssertEqual(BlockMap.labelFromID("page-12"), "12")
        XCTAssertEqual(BlockMap.labelFromID("page_iv"), "iv")
        XCTAssertNil(BlockMap.labelFromID("p20"))
        XCTAssertNil(BlockMap.labelFromID("pagetitle"))
    }
}

final class HashTests: XCTestCase {
    func testSHA1AndUUIDv5() {
        XCTAssertEqual(SHA1.hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(UUIDv5.make(namespace: dns, name: "python.org").uuidString.lowercased(), "886313e1-3b8a-5372-9b90-0c9aee199e5d")
    }
}
