import Foundation

/// The result of the checks run when a book is opened.
public enum BookCheckResult: Equatable, Sendable {
    case ok
    case warning(BookWarning)
    case refused(BookRefusal)
}

public enum BookRefusal: Equatable, Sendable, CustomStringConvertible {
    case drm(String)
    case scanned(imageOnlyFiles: Int, totalFiles: Int)

    public var description: String {
        switch self {
        case .drm(let detail): return "This book is DRM-locked (\(detail)). Only DRM-free books work."
        case let .scanned(img, total): return "This book looks scanned: \(img) of \(total) pages are images with almost no text."
        }
    }
}

public enum BookWarning: Equatable, Sendable, CustomStringConvertible {
    case fixedLayout

    public var description: String {
        "Fixed-layout book. A recipe that spans two pages may be split or merged. Check the list before parsing."
    }
}

public enum BookCheck {
    /// Font obfuscation algorithms. Neither is DRM: they only scramble embedded fonts.
    static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding",   // IDPF
        "http://ns.adobe.com/pdf/enc#RC",        // Adobe, written by Calibre
    ]
    static let fontExtensions: Set<String> = ["otf", "ttf", "woff", "woff2", "eot"]

    public static func run(_ package: EPUBPackage) -> BookCheckResult {
        if let drm = drmProblem(package.container) { return .refused(.drm(drm)) }
        let (imageOnly, total) = scanCounts(package)
        if total >= 8, Double(imageOnly) / Double(total) > 0.8 { return .refused(.scanned(imageOnlyFiles: imageOnly, totalFiles: total)) }
        if package.isFixedLayout { return .warning(.fixedLayout) }
        return .ok
    }

    /// Returns a reason if the container holds DRM, nil when it's DRM-free.
    public static func drmProblem(_ container: EPUBContainer) -> String? {
        if container.contains("META-INF/license.lcpl") { return "Readium LCP" }
        if container.contains("META-INF/rights.xml") { return "rights.xml" }
        guard let xml = container.string("META-INF/encryption.xml") else { return nil }
        var algorithm: String?
        for token in HTMLTokenizer.tokenize(xml) {
            switch token {
            case .startTag("encryptionmethod", let attrs, _):
                algorithm = attrs["algorithm"]
            case .startTag("cipherreference", let attrs, _):
                let uri = attrs["uri"] ?? ""
                let ext = (uri as NSString).pathExtension.lowercased()
                guard let alg = algorithm, fontObfuscation.contains(alg) else {
                    return "encrypted with \(algorithm ?? "an unknown method")"
                }
                if !fontExtensions.contains(ext) { return "\(uri) is encrypted" }
            case .endTag("encrypteddata"):
                algorithm = nil
            default: break
            }
        }
        return nil
    }

    /// Counts spine documents with images but almost no text.
    static func scanCounts(_ package: EPUBPackage) -> (imageOnly: Int, total: Int) {
        var imageOnly = 0, total = 0
        for item in package.spine {
            guard let html = package.container.string(item.path) else { continue }
            total += 1
            var textCount = 0, images = 0
            var inBody = false
            for token in HTMLTokenizer.tokenize(html) {
                switch token {
                case .startTag("body", _, _): inBody = true
                case .startTag(let name, _, _) where inBody && (name == "img" || name == "image"): images += 1
                case .text(let t) where inBody: textCount += t.unicodeScalars.filter { !$0.properties.isWhitespace }.count
                default: break
                }
            }
            if images > 0, textCount < 40 { imageOnly += 1 }
        }
        return (imageOnly, total)
    }
}
