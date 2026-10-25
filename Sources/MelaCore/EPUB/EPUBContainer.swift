import Foundation
import ZIPFoundation

public enum EPUBError: Error, Equatable, CustomStringConvertible {
    case notAZip
    case missingContainer
    case missingPackage(String)
    case missingFile(String)

    public var description: String {
        switch self {
        case .notAZip: return "The file isn't a valid ePub (not a zip archive)."
        case .missingContainer: return "The ePub has no META-INF/container.xml."
        case .missingPackage(let path): return "The ePub's package file is missing: \(path)."
        case .missingFile(let path): return "The ePub is missing \(path)."
        }
    }
}

/// Every file in an ePub, read into memory once.
///
/// Cookbooks are tens of megabytes at most, and holding them as an immutable
/// value keeps the rest of the parser free of file handles and locking.
public struct EPUBContainer: Sendable {
    public let files: [String: Data]

    public init(files: [String: Data]) {
        self.files = files
    }

    public init(url: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBError.notAZip
        }
        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            files[entry.path] = data
        }
        self.files = files
    }

    public func data(_ path: String) -> Data? {
        if let d = files[path] { return d }
        // Some zips percent-encode or vary case; fall back to a case-insensitive match.
        let lower = path.lowercased()
        return files.first { $0.key.lowercased() == lower }?.value
    }

    public func string(_ path: String) -> String? {
        guard let d = data(path) else { return nil }
        if let s = String(data: d, encoding: .utf8) { return s }
        return String(data: d, encoding: .isoLatin1)
    }

    public func contains(_ path: String) -> Bool { data(path) != nil }
}

public enum EPUBPath {
    /// The folder part of a path inside the zip ("OEBPS/text/a.html" → "OEBPS/text").
    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Splits "a.html#frag" into ("a.html", "frag").
    public static func splitFragment(_ href: String) -> (path: String, fragment: String?) {
        guard let hash = href.firstIndex(of: "#") else { return (href, nil) }
        let frag = String(href[href.index(after: hash)...])
        return (String(href[..<hash]), frag.isEmpty ? nil : frag)
    }

    /// Resolves an href found in `base` (a file path inside the zip) to a normalized zip path.
    /// An empty path (a bare "#frag") resolves to `base` itself. External URLs return nil.
    public static func resolve(_ href: String, relativeTo base: String) -> String? {
        let (rawPath, _) = splitFragment(href)
        if rawPath.contains("://") || rawPath.hasPrefix("mailto:") || rawPath.hasPrefix("data:") { return nil }
        if rawPath.isEmpty { return base }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        var parts: [Substring] = decoded.hasPrefix("/") ? [] : directory(of: base).split(separator: "/")
        for component in decoded.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }
}
