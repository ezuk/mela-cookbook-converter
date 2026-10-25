import Foundation

/// A parsed recipe with everything needed to review, re-check and export it.
public struct ParsedRecipe: Codable, Sendable, Equatable, Identifiable {
    public var id: String { candidateID }
    public let candidateID: String
    /// The draft after automatic fixes, before my edits.
    public var draft: RecipeDraft
    /// The model's answer as given, so the checker can be re-run for free when it improves.
    public var modelDraft: RecipeDraft?
    public var report: CheckReport
    public var state: RecipeState
    public var engine: EngineKind
    public var model: String?
    public var sourceHash: String
    public var cacheKey: String
    /// Raw engine answers, one per attempt, kept for debugging and as test fixtures.
    public var rawOutputs: [String]
    public var parsedAt: Date
    public var usage: EngineUsage
    public var error: String?
}

public protocol ParseCache: Sendable {
    func cached(_ key: String) -> ParsedRecipe?
    func store(_ recipe: ParsedRecipe)
}

/// A cache kept in memory, for the CLI and tests.
public final class MemoryParseCache: ParseCache, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: ParsedRecipe] = [:]
    public init() {}
    public func cached(_ key: String) -> ParsedRecipe? { lock.withLock { items[key] } }
    public func store(_ recipe: ParsedRecipe) { lock.withLock { items[recipe.cacheKey] = recipe } }
}

public enum ParsePipeline {
    public static func cacheKey(source: RecipeSource, engine: EngineKind, model: String?) -> String {
        SHA1.hex("\(source.hash)|schema\(RecipeDraftSchema.version)|prompt\(PromptBuilder.version)|\(engine.rawValue)|\(model ?? "default")")
    }

    /// Parses one recipe: engine → checker → one retry with the checker's findings if anything failed.
    /// Engine errors that should pause the queue (usage limit, login) are thrown; other failures
    /// come back as a recipe in the `failed` state. Finished results are never re-sent.
    public static func parse(source: RecipeSource, engine: any RecipeEngine, model: String?,
                             cache: (any ParseCache)? = nil, retry: Bool = true) async throws -> ParsedRecipe {
        let key = cacheKey(source: source, engine: engine.kind, model: model)
        if var hit = cache?.cached(key), hit.state != .failed {
            // Re-run the checker on the model's answer: checker improvements never cost a model call.
            if let original = hit.modelDraft {
                let (draft, report) = Checker.check(original, source: source)
                hit.draft = draft
                hit.report = report
                hit.state = report.state
            }
            return hit
        }

        var raws: [String] = []
        var usage = EngineUsage()
        var best: (draft: RecipeDraft, report: CheckReport, model: String?, original: RecipeDraft)?
        var lastError: String?
        var feedback: [String] = []

        for attempt in 0..<(retry ? 2 : 1) {
            try Task.checkCancellation()
            do {
                let out = try await engine.parse(prompt: PromptBuilder.prompt(for: source, feedback: feedback), model: model)
                raws.append(out.raw)
                usage.inputTokens = (usage.inputTokens ?? 0) + (out.usage.inputTokens ?? 0)
                usage.outputTokens = (usage.outputTokens ?? 0) + (out.usage.outputTokens ?? 0)
                usage.estimatedCostUSD = (usage.estimatedCostUSD ?? 0) + (out.usage.estimatedCostUSD ?? 0)
                let (draft, report) = Checker.check(out.draft, source: source)
                if best == nil || report.issues.count < best!.report.issues.count { best = (draft, report, out.model, out.draft) }
                if report.issues.isEmpty { break }
                feedback = report.feedback
            } catch let error as EngineError {
                if error.pausesQueue || error == .cancelled { throw error }
                lastError = error.description
                if attempt == 0 && retry { continue }
            }
        }

        let result: ParsedRecipe
        if let best {
            result = ParsedRecipe(candidateID: source.candidate.id, draft: best.draft, modelDraft: best.original, report: best.report, state: best.report.state,
                                  engine: engine.kind, model: best.model ?? model, sourceHash: source.hash, cacheKey: key,
                                  rawOutputs: raws, parsedAt: Date(), usage: usage, error: nil)
        } else {
            let empty = RecipeDraft(title: source.candidate.title, headnote: nil, yield: nil, prepTime: nil, cookTime: nil, totalTime: nil,
                                    ingredientGroups: [], stepGroups: [], notes: [], nutrition: nil, crossReferences: [], inferred: [])
            result = ParsedRecipe(candidateID: source.candidate.id, draft: empty, modelDraft: nil, report: CheckReport(issues: [], fixes: []), state: .failed,
                                  engine: engine.kind, model: model, sourceHash: source.hash, cacheKey: key,
                                  rawOutputs: raws, parsedAt: Date(), usage: usage, error: lastError ?? "Unknown error")
        }
        cache?.store(result)
        return result
    }
}

/// Runs parses N at a time, pauses on usage limits or a broken login instead of failing the batch,
/// and resumes on its own when a limit's reset time is known.
public actor ParseQueue {
    public enum Event: Sendable {
        case started(String)
        case finished(ParsedRecipe)
        case paused(EngineError)
        case resumed
        case cancelled(String)
        case idle
    }

    public private(set) var isPaused = false
    public private(set) var pauseReason: EngineError?
    private var pending: [RecipeSource] = []
    private var running: [String: Task<Void, Never>] = [:]
    private let engine: any RecipeEngine
    private let model: String?
    private let concurrency: Int
    private let cache: (any ParseCache)?
    private let onEvent: @Sendable (Event) -> Void
    private var resumeTask: Task<Void, Never>?

    public init(engine: any RecipeEngine, model: String?, concurrency: Int = 10, cache: (any ParseCache)?, onEvent: @escaping @Sendable (Event) -> Void) {
        self.engine = engine
        self.model = model
        self.concurrency = max(1, concurrency)
        self.cache = cache
        self.onEvent = onEvent
    }

    public var pendingIDs: [String] { pending.map(\.candidate.id) }
    public var runningIDs: [String] { Array(running.keys) }

    public func enqueue(_ sources: [RecipeSource]) {
        let known = Set(pendingIDs).union(running.keys)
        pending.append(contentsOf: sources.filter { !known.contains($0.candidate.id) })
        pump()
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        resumeTask?.cancel()
        resumeTask = nil
        guard isPaused else { return }
        isPaused = false
        pauseReason = nil
        onEvent(.resumed)
        pump()
    }

    public func cancel(_ id: String) {
        if let i = pending.firstIndex(where: { $0.candidate.id == id }) {
            pending.remove(at: i)
            onEvent(.cancelled(id))
        }
        running[id]?.cancel()
    }

    public func cancelAll() {
        for s in pending { onEvent(.cancelled(s.candidate.id)) }
        pending.removeAll()
        for t in running.values { t.cancel() }
    }

    private func pump() {
        while !isPaused, running.count < concurrency, !pending.isEmpty {
            let source = pending.removeFirst()
            let id = source.candidate.id
            onEvent(.started(id))
            let engine = self.engine, model = self.model, cache = self.cache
            running[id] = Task {
                do {
                    let parsed = try await ParsePipeline.parse(source: source, engine: engine, model: model, cache: cache)
                    self.finished(id, parsed)
                } catch let error as EngineError where error.pausesQueue {
                    self.hitLimit(source, error)
                } catch {
                    self.wasCancelled(id)
                }
            }
        }
        if running.isEmpty && pending.isEmpty { onEvent(.idle) }
    }

    private func finished(_ id: String, _ parsed: ParsedRecipe) {
        running[id] = nil
        onEvent(.finished(parsed))
        pump()
    }

    private func wasCancelled(_ id: String) {
        running[id] = nil
        onEvent(.cancelled(id))
        pump()
    }

    private func hitLimit(_ source: RecipeSource, _ error: EngineError) {
        running[source.candidate.id] = nil
        pending.insert(source, at: 0)
        if !isPaused {
            isPaused = true
            pauseReason = error
            onEvent(.paused(error))
            if case .usageLimit(let resetsAt?) = error {
                let delay = max(5, resetsAt.timeIntervalSinceNow + 30)
                resumeTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.resume()
                }
            }
        }
    }
}
