import Foundation
import Observation
import MelaCore

/// User settings, stored in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var calibreLibraryPath: String { didSet { defaults.set(calibreLibraryPath, forKey: "calibreLibraryPath") } }
    var cookbookTags: [String] { didSet { defaults.set(cookbookTags, forKey: "cookbookTags") } }
    var titleWords: [String] { didSet { defaults.set(titleWords, forKey: "titleWords") } }
    /// Calibre book ids removed from the home screen by hand.
    var excludedBookIDs: Set<Int> { didSet { defaults.set(Array(excludedBookIDs), forKey: "excludedBookIDs") } }
    var saveNextToEPUB: Bool { didSet { defaults.set(saveNextToEPUB, forKey: "saveNextToEPUB") } }
    var defaultEngine: EngineKind { didSet { defaults.set(defaultEngine.rawValue, forKey: "defaultEngine") } }
    var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    var codexModel: String { didSet { defaults.set(codexModel, forKey: "codexModel") } }
    var concurrency: Int { didSet { defaults.set(concurrency, forKey: "concurrency") } }
    /// Last folder used for exports of books outside Calibre.
    var lastExportFolder: String { didSet { defaults.set(lastExportFolder, forKey: "lastExportFolder") } }

    private init() {
        let guess = CalibreLibrary.defaultLocations().first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("metadata.db").path) }
        calibreLibraryPath = defaults.string(forKey: "calibreLibraryPath") ?? guess?.path ?? ""
        cookbookTags = defaults.stringArray(forKey: "cookbookTags") ?? CookbookFilter.default.tags
        titleWords = defaults.stringArray(forKey: "titleWords") ?? CookbookFilter.default.titleWords
        excludedBookIDs = Set((defaults.array(forKey: "excludedBookIDs") as? [Int]) ?? [])
        saveNextToEPUB = defaults.object(forKey: "saveNextToEPUB") as? Bool ?? true
        defaultEngine = EngineKind(rawValue: defaults.string(forKey: "defaultEngine") ?? "") ?? .claude
        claudeModel = defaults.string(forKey: "claudeModel") ?? "sonnet"
        codexModel = defaults.string(forKey: "codexModel") ?? ""
        concurrency = defaults.object(forKey: "concurrency") as? Int ?? 10
        lastExportFolder = defaults.string(forKey: "lastExportFolder")
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    var filter: CookbookFilter { CookbookFilter(tags: cookbookTags, titleWords: titleWords, excludedIDs: excludedBookIDs) }

    func model(for engine: EngineKind) -> String {
        engine == .claude ? claudeModel : codexModel
    }

    func setModel(_ model: String, for engine: EngineKind) {
        if engine == .claude { claudeModel = model } else { codexModel = model }
    }
}

/// What the home screen remembers about books opened before: progress badges and Open Recent.
struct BookSummary: Codable, Equatable {
    var path: String
    var title: String
    var storeKey: String
    var ticked: Int
    var parsed: Int
    var lastOpened: Date
}

@MainActor
@Observable
final class RecentBooks {
    static let shared = RecentBooks()
    private(set) var byPath: [String: BookSummary] = [:]
    private let url: URL

    private init() {
        url = BookStore.defaultRoot.deletingLastPathComponent().appendingPathComponent("recent.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: BookSummary].self, from: data) {
            byPath = decoded
        }
    }

    var recent: [BookSummary] {
        byPath.values.sorted { $0.lastOpened > $1.lastOpened }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func update(_ summary: BookSummary) {
        byPath[summary.path] = summary
        save()
    }

    func remove(path: String) {
        byPath[path] = nil
        save()
    }

    func clear() {
        byPath = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(byPath) { try? data.write(to: url, options: .atomic) }
    }
}
