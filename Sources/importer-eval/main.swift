import Foundation
import MelaCore

// importer-eval: the parser without the app, for testing on real books.
//
//   importer-eval check  <book.epub>
//   importer-eval find   <book.epub> [--json]
//   importer-eval parse  <book.epub> [--recipes 1-5,9] [--engine claude|codex] [--model m] [--concurrency 10] [--out dir]
//   importer-eval export <book.epub> --from <parse dir> --out <file.melarecipes> [--no-category] [--no-source]
//   importer-eval calibre <library dir> [--tags a,b] [--words x,y]

struct CLIError: Error, CustomStringConvertible { let description: String }

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func parseRange(_ spec: String?, count: Int) -> [Int] {
    guard let spec, !spec.isEmpty else { return Array(0..<count) }
    var out: [Int] = []
    for part in spec.split(separator: ",") {
        let bounds = part.split(separator: "-").compactMap { Int($0) }
        if bounds.count == 2 { out += Array(bounds[0]...bounds[1]).map { $0 - 1 } } else if let one = bounds.first { out.append(one - 1) }
    }
    return out.filter { $0 >= 0 && $0 < count }
}

func loadBook(_ path: String) throws -> (EPUBPackage, BlockMap, FindResult) {
    let package = try EPUBPackage(url: URL(fileURLWithPath: path))
    let check = BookCheck.run(package)
    if case .refused(let why) = check { throw CLIError(description: why.description) }
    if case .warning(let w) = check { FileHandle.standardError.write(Data("Warning: \(w)\n".utf8)) }
    let map = BlockMap(package: package)
    return (package, map, RecipeFinder.find(package: package, map: map))
}

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
}()

func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first, args.count >= 2 else {
        print("usage: importer-eval check|find|parse|export|calibre <path> [options]")
        return
    }
    let path = args[1]
    switch command {
    case "check":
        let package = try EPUBPackage(url: URL(fileURLWithPath: path))
        print(package.metadata.title, "—", package.metadata.authors.joined(separator: ", "))
        print("Check:", BookCheck.run(package))
        print("Spine files: \(package.spine.count), ToC entries: \(package.toc.count), page list: \(package.pageList.count)")

    case "find":
        let (package, _, result) = try loadBook(path)
        if args.contains("--json") {
            print(String(decoding: try encoder.encode(result.recipes), as: UTF8.self))
            return
        }
        print("\(package.metadata.title): \(result.recipes.count) recipes, \(result.sections.count) other sections")
        if let p = result.profile { print("Layout: titles are \(p.titleStyle)") }
        for (n, r) in result.recipes.enumerated() {
            let flags = [r.confidence == .low ? "not sure" : nil, r.photos.isEmpty ? nil : "\(r.photos.count) photo",
                         r.uses.isEmpty ? nil : "uses \(r.uses.count)"].compactMap { $0 }.joined(separator: ", ")
            print(String(format: "%4d  ", n + 1) + "[\(r.chapter ?? "-")] \(r.title)" + (r.page.map { "  p. \($0)" } ?? "") + (flags.isEmpty ? "" : "  (\(flags))"))
        }

    case "parse":
        let (package, map, result) = try loadBook(path)
        let kind = EngineKind(rawValue: option("--engine", in: args) ?? "claude") ?? .claude
        let engine = try EngineFactory.make(kind)
        let model = option("--model", in: args)
        let concurrency = Int(option("--concurrency", in: args) ?? "10") ?? 10
        let outDir = URL(fileURLWithPath: option("--out", in: args) ?? "parsed")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let picks = parseRange(option("--recipes", in: args), count: result.recipes.count)
        let sources = picks.map { RecipeSource(candidate: result.recipes[$0], map: map, bookTitle: package.metadata.title) }
        let cache = DirectoryParseCache(directory: outDir.appendingPathComponent("cache"))
        print("Parsing \(sources.count) recipes with \(kind.displayName)\(model.map { " (\($0))" } ?? ""), \(concurrency) at a time…")
        let done = AsyncStream<ParseQueue.Event>.makeStream()
        let queue = ParseQueue(engine: engine, model: model, concurrency: concurrency, cache: cache) { done.continuation.yield($0) }
        await queue.enqueue(sources)
        var finished = 0
        var states: [RecipeState: Int] = [:]
        for await event in done.stream {
            switch event {
            case .finished(let parsed):
                finished += 1
                states[parsed.state, default: 0] += 1
                let title = result.recipes.first { $0.id == parsed.candidateID }?.title ?? parsed.draft.title
                let detail = parsed.error ?? (parsed.report.issues.isEmpty ? "" : parsed.report.issues.map(\.message).joined(separator: " | "))
                let fixes = parsed.report.fixes.isEmpty ? "" : " [\(parsed.report.fixes.count) fixed from book]"
                print("[\(finished)/\(sources.count)] \(parsed.state.rawValue): \(title)\(fixes) \(detail.prefix(400))")
                let file = outDir.appendingPathComponent("\(parsed.candidateID).json")
                try encoder.encode(parsed).write(to: file)
            case .paused(let error):
                print("Paused: \(error)")
                if case .usageLimit(nil) = error { done.continuation.finish() }
                if case .notLoggedIn = error { done.continuation.finish() }
                if case .notInstalled = error { done.continuation.finish() }
            case .idle:
                done.continuation.finish()
            default: break
            }
        }
        print("Done:", states.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", "))

    case "export":
        let (package, map, result) = try loadBook(path)
        guard let from = option("--from", in: args), let out = option("--out", in: args) else { throw CLIError(description: "export needs --from <parse dir> and --out <file>") }
        var parsed: [ParsedRecipe] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: from) where file.hasSuffix(".json") {
            if let p = try? JSONDecoder.iso.decode(ParsedRecipe.self, from: Data(contentsOf: URL(fileURLWithPath: from).appendingPathComponent(file))) {
                parsed.append(p)
            }
        }
        var options = ExportOptions()
        options.chapterAsCategory = !args.contains("--no-category")
        options.bookInSource = !args.contains("--no-source")
        let items: [ExportItem] = parsed.compactMap { p in
            guard p.state != .failed, let c = result.recipes.first(where: { $0.id == p.candidateID }) else { return nil }
            return ExportItem(candidate: c, draft: p.draft)
        }
        let url = URL(fileURLWithPath: out)
        try MelaExporter.export(items, book: package, map: map, options: options, to: url)
        print("Wrote \(items.count) recipes to \(url.path)")

    case "calibre":
        let tags = option("--tags", in: args)?.split(separator: ",").map(String.init) ?? ["cookbook", "cookbooks", "recipes", "cooking"]
        let words = option("--words", in: args)?.split(separator: ",").map(String.init) ?? ["cookbook", "recipes", "kitchen"]
        let library = try CalibreLibrary(root: URL(fileURLWithPath: path))
        let books = try library.cookbooks(matching: CookbookFilter(tags: tags, titleWords: words))
        print("\(books.count) cookbooks in \(path)")
        for b in books {
            print("  \(b.processed ? "processed" : "to do    ")  \(b.title) — \(b.authors.joined(separator: ", "))  [\(b.tags.joined(separator: ", "))]")
        }

    default:
        throw CLIError(description: "Unknown command \(command)")
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
