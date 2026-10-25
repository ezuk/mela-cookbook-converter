import Foundation

/// A forgiving tokenizer for the XHTML and HTML found in ePubs.
///
/// Calibre output is mostly well-formed XHTML, but books use undeclared HTML
/// entities (`&nbsp;`) that make `XMLParser` fail, so the importer reads
/// markup with this instead.
public enum HTMLToken: Equatable, Sendable {
    case startTag(name: String, attributes: [String: String], selfClosing: Bool)
    case endTag(name: String)
    case text(String)
}

public struct HTMLTokenizer {
    /// Elements whose content is never text the reader sees.
    static let rawTextElements: Set<String> = ["script", "style"]

    public static func tokenize(_ source: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        let chars = Array(source.unicodeScalars)
        var i = 0
        var text = String.UnicodeScalarView()

        func flushText() {
            if !text.isEmpty {
                tokens.append(.text(decodeEntities(String(text))))
                text = String.UnicodeScalarView()
            }
        }

        while i < chars.count {
            let c = chars[i]
            guard c == "<" else {
                text.append(c)
                i += 1
                continue
            }
            // Comment, CDATA, doctype, processing instruction.
            if hasPrefix(chars, i, "<!--") {
                flushText()
                i = indexAfter(chars, from: i + 4, terminator: "-->")
                continue
            }
            if hasPrefix(chars, i, "<![CDATA[") {
                flushText()
                let end = indexOf(chars, from: i + 9, terminator: "]]>") ?? chars.count
                tokens.append(.text(String(String.UnicodeScalarView(chars[(i + 9)..<end]))))
                i = min(chars.count, end + 3)
                continue
            }
            if hasPrefix(chars, i, "<!") || hasPrefix(chars, i, "<?") {
                flushText()
                i = indexAfter(chars, from: i + 2, terminator: ">")
                continue
            }
            // End tag.
            if i + 1 < chars.count, chars[i + 1] == "/" {
                flushText()
                var j = i + 2
                var name = String.UnicodeScalarView()
                while j < chars.count, chars[j] != ">" {
                    if !chars[j].properties.isWhitespace { name.append(chars[j]) }
                    j += 1
                }
                tokens.append(.endTag(name: localName(String(name))))
                i = min(chars.count, j + 1)
                continue
            }
            // Start tag: must begin with a letter, otherwise it is text.
            guard i + 1 < chars.count, chars[i + 1].properties.isAlphabetic else {
                text.append(c)
                i += 1
                continue
            }
            flushText()
            var j = i + 1
            var name = String.UnicodeScalarView()
            while j < chars.count, !chars[j].properties.isWhitespace, chars[j] != ">", chars[j] != "/" {
                name.append(chars[j])
                j += 1
            }
            var attributes: [String: String] = [:]
            var selfClosing = false
            while j < chars.count {
                while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                guard j < chars.count else { break }
                if chars[j] == ">" { j += 1; break }
                if chars[j] == "/" { selfClosing = true; j += 1; continue }
                var attrName = String.UnicodeScalarView()
                while j < chars.count, !chars[j].properties.isWhitespace, chars[j] != "=", chars[j] != ">", chars[j] != "/" {
                    attrName.append(chars[j])
                    j += 1
                }
                while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                var value = ""
                if j < chars.count, chars[j] == "=" {
                    j += 1
                    while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
                        let quote = chars[j]
                        j += 1
                        let start = j
                        while j < chars.count, chars[j] != quote { j += 1 }
                        value = String(String.UnicodeScalarView(chars[start..<min(j, chars.count)]))
                        j += 1
                    } else {
                        let start = j
                        while j < chars.count, !chars[j].properties.isWhitespace, chars[j] != ">" { j += 1 }
                        value = String(String.UnicodeScalarView(chars[start..<j]))
                    }
                }
                if !attrName.isEmpty {
                    attributes[String(attrName).lowercased()] = decodeEntities(value)
                }
            }
            let tagName = localName(String(name))
            tokens.append(.startTag(name: tagName, attributes: attributes, selfClosing: selfClosing))
            i = j
            if rawTextElements.contains(tagName), !selfClosing {
                let close = "</\(tagName)"
                let end = indexOf(chars, from: i, terminator: close, caseInsensitive: true) ?? chars.count
                i = indexAfter(chars, from: end, terminator: ">")
                tokens.append(.endTag(name: tagName))
            }
        }
        flushText()
        return tokens
    }

    /// Lower-cased element name without a namespace prefix (`epub:switch` stays, `xhtml:p` becomes `p`).
    static func localName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasPrefix("epub:") { return lower }
        if let colon = lower.lastIndex(of: ":") { return String(lower[lower.index(after: colon)...]) }
        return lower
    }

    private static func hasPrefix(_ chars: [Unicode.Scalar], _ i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.unicodeScalars)
        guard i + p.count <= chars.count else { return false }
        for k in 0..<p.count where chars[i + k] != p[k] { return false }
        return true
    }

    private static func indexOf(_ chars: [Unicode.Scalar], from: Int, terminator: String, caseInsensitive: Bool = false) -> Int? {
        let t = Array((caseInsensitive ? terminator.lowercased() : terminator).unicodeScalars)
        guard !t.isEmpty, from <= chars.count - t.count else { return nil }
        var i = from
        while i <= chars.count - t.count {
            var match = true
            for k in 0..<t.count {
                var c = chars[i + k]
                if caseInsensitive, let lowered = String(c).lowercased().unicodeScalars.first { c = lowered }
                if c != t[k] { match = false; break }
            }
            if match { return i }
            i += 1
        }
        return nil
    }

    private static func indexAfter(_ chars: [Unicode.Scalar], from: Int, terminator: String) -> Int {
        guard let i = indexOf(chars, from: from, terminator: terminator) else { return chars.count }
        return i + terminator.unicodeScalars.count
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "sbquo": "\u{201A}", "bdquo": "\u{201E}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "bull": "\u{2022}", "middot": "\u{00B7}",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "frac13": "⅓", "frac23": "⅔", "frac18": "⅛",
        "frac38": "⅜", "frac58": "⅝", "frac78": "⅞", "deg": "°", "times": "×", "divide": "÷", "plusmn": "±",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶", "shy": "\u{00AD}",
        "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â",
        "auml": "ä", "atilde": "ã", "aring": "å", "aelig": "æ", "ccedil": "ç", "iacute": "í", "igrave": "ì",
        "icirc": "î", "iuml": "ï", "ntilde": "ñ", "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö",
        "otilde": "õ", "oslash": "ø", "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü", "szlig": "ß",
        "Eacute": "É", "Egrave": "È", "Aacute": "Á", "Agrave": "À", "Ccedil": "Ç", "Ntilde": "Ñ",
        "Oacute": "Ó", "Ouml": "Ö", "Uuml": "Ü", "Auml": "Ä", "oelig": "œ", "OElig": "Œ",
        "prime": "′", "Prime": "″", "minus": "−", "frasl": "⁄", "cent": "¢", "pound": "£", "euro": "€", "yen": "¥",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            guard ch == "&", let semi = s[idx...].prefix(12).firstIndex(of: ";") else {
                out.append(ch)
                idx = s.index(after: idx)
                continue
            }
            let name = String(s[s.index(after: idx)..<semi])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(u) }
            } else if name.hasPrefix("#") {
                if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { replacement = String(u) }
            } else {
                replacement = namedEntities[name]
            }
            if let r = replacement {
                out += r
                idx = s.index(after: semi)
            } else {
                out.append(ch)
                idx = s.index(after: idx)
            }
        }
        return out
    }
}
