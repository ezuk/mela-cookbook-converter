import XCTest
@testable import MelaCore

/// A fake engine that returns canned drafts or errors, in order.
final class FakeEngine: RecipeEngine, @unchecked Sendable {
    let kind = EngineKind.claude
    private let lock = NSLock()
    private var answers: [Result<RecipeDraft, EngineError>]
    private(set) var prompts: [String] = []

    init(_ answers: [Result<RecipeDraft, EngineError>]) { self.answers = answers }

    func parse(prompt: String, model: String?) async throws -> EngineOutput {
        let next: Result<RecipeDraft, EngineError> = lock.withLock {
            prompts.append(prompt)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        switch next {
        case .success(let d): return EngineOutput(draft: d, raw: "{}", model: "fake", usage: EngineUsage())
        case .failure(let e): throw e
        }
    }
}

func soupSource() throws -> RecipeSource {
    let p = try TestBook.cookbook().package()
    let map = BlockMap(package: p)
    let soup = RecipeFinder.find(package: p, map: map).recipes[1]
    return RecipeSource(candidate: soup, map: map, bookTitle: p.metadata.title)
}

/// A correct draft for the synthetic Tomato Soup, citing labels from its tagged lines.
func soupDraft(_ source: RecipeSource) -> RecipeDraft {
    func label(_ prefix: String) -> String { source.lines.first { $0.text.hasPrefix(prefix) }!.label }
    func L(_ t: String, _ s: [String]) -> RecipeDraft.Line { RecipeDraft.Line(text: t, source: s) }
    return RecipeDraft(
        title: "Tomato Soup", headnote: nil, yield: nil, prepTime: "10 minutes", cookTime: nil, totalTime: nil,
        ingredientGroups: [.init(name: nil, items: [
            L("1 kg tomatoes", [label("1 kg")]), L("500 ml Basic Stock (page 12)", [label("500 ml")]),
            L("½ teaspoon salt", [label("½")]), L("2 tbsp olive oil", [label("2 tbsp")]),
        ])],
        stepGroups: [.init(name: nil, steps: [
            L("Roast the tomatoes at 200°C for 30 minutes.", [label("1 Roast")]),
            L("Blend with the stock and season.", [label("2 Blend")]),
        ])],
        notes: [], nutrition: nil, crossReferences: [.init(text: "Basic Stock", page: "12")], inferred: [])
}

final class CheckerTests: XCTestCase {
    func testCorrectDraftIsApproved() throws {
        let source = try soupSource()
        let (_, report) = Checker.check(soupDraft(source), source: source)
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.state, .approved)
    }

    func testNumberOnlyMismatchIsFixedFromTheBook() throws {
        let source = try soupSource()
        var draft = soupDraft(source)
        draft.ingredientGroups[0].items[0].text = "2 kg tomatoes"
        let (fixed, report) = Checker.check(draft, source: source)
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.fixes, [CheckFix(field: "Ingredient 1", modelText: "2 kg tomatoes", bookText: "1 kg tomatoes")])
        XCTAssertEqual(fixed.ingredientGroups[0].items[0].text, "1 kg tomatoes")
    }

    func testMissingLineAndInventedTextAreFlagged() throws {
        let source = try soupSource()
        var draft = soupDraft(source)
        draft.ingredientGroups[0].items.remove(at: 3)                       // drop the olive oil
        draft.stepGroups[0].steps[1].text = "Blend until silky and finish with cream." // not in the book
        let (_, report) = Checker.check(draft, source: source)
        XCTAssertEqual(Set(report.issues.map(\.kind)), [.missingSourceLine, .lineNotInSource])
        XCTAssertEqual(report.state, .needsReview)
        XCTAssertTrue(report.issues.contains { $0.message.contains("2 tbsp olive oil") })
    }

    func testInventedTimeIsFlaggedUnlessMarkedInferred() throws {
        let source = try soupSource()
        var draft = soupDraft(source)
        draft.totalTime = "45 minutes"
        XCTAssertTrue(Checker.check(draft, source: source).report.issues.contains { $0.kind == .numberNotInSource })
        draft.inferred = ["totalTime"]
        XCTAssertEqual(Checker.check(draft, source: source).report.issues, [])
        XCTAssertEqual(Checker.fieldStatus(draft, field: "totalTime"), .inferred)
        XCTAssertEqual(Checker.fieldStatus(draft, field: "prepTime"), .found)
        XCTAssertEqual(Checker.fieldStatus(draft, field: "yield"), .missing)
    }

    func testSchemaIsValidJSONAndStrict() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(RecipeDraftSchema.json.utf8)) as? [String: Any])
        let props = try XCTUnwrap(obj["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), Set(obj["required"] as! [String]))
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertFalse(RecipeDraftSchema.json.contains("allOf"))
    }
}

final class PipelineTests: XCTestCase {
    func testRetryFeedsCheckerFindingsBack() async throws {
        let source = try soupSource()
        var bad = soupDraft(source)
        bad.stepGroups[0].steps.removeLast()
        let engine = FakeEngine([.success(bad), .success(soupDraft(source))])
        let parsed = try await ParsePipeline.parse(source: source, engine: engine, model: nil)
        XCTAssertEqual(parsed.state, .approved)
        XCTAssertEqual(engine.prompts.count, 2)
        XCTAssertTrue(engine.prompts[1].contains("Blend with the stock"))
    }

    func testCacheNeverResendsAndRechecks() async throws {
        let source = try soupSource()
        let cache = MemoryParseCache()
        let engine = FakeEngine([.success(soupDraft(source))])
        _ = try await ParsePipeline.parse(source: source, engine: engine, model: "m", cache: cache)
        let again = try await ParsePipeline.parse(source: source, engine: engine, model: "m", cache: cache)
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertEqual(again.state, .approved)
    }

    func testFailureAfterRetryBecomesFailedRecipe() async throws {
        let source = try soupSource()
        let engine = FakeEngine([.failure(.invalidOutput("garbage"))])
        let parsed = try await ParsePipeline.parse(source: source, engine: engine, model: nil)
        XCTAssertEqual(parsed.state, .failed)
        XCTAssertEqual(engine.prompts.count, 2)
    }

    func testQueuePausesOnUsageLimitAndKeepsTheRecipe() async throws {
        let source = try soupSource()
        let engine = FakeEngine([.failure(.usageLimit(resetsAt: nil))])
        let events = AsyncStream<ParseQueue.Event>.makeStream()
        let queue = ParseQueue(engine: engine, model: nil, concurrency: 2, cache: nil) { events.continuation.yield($0) }
        await queue.enqueue([source])
        for await e in events.stream { if case .paused(let err) = e { XCTAssertEqual(err, .usageLimit(resetsAt: nil)); break } }
        let paused = await queue.isPaused
        let pending = await queue.pendingIDs
        XCTAssertTrue(paused)
        XCTAssertEqual(pending, [source.candidate.id])
    }
}

final class EngineDecodeTests: XCTestCase {
    let draftJSON = #"{"title":"T","headnote":null,"yield":null,"prepTime":null,"cookTime":null,"totalTime":null,"ingredientGroups":[],"stepGroups":[],"notes":[],"nutrition":null,"crossReferences":[],"inferred":[]}"#

    func result(_ out: String, _ err: String = "", code: Int32 = 0) -> ProcessResult {
        ProcessResult(exitCode: code, stdout: Data(out.utf8), stderr: Data(err.utf8))
    }

    func testClaudeSuccess() throws {
        let out = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":\#(draftJSON),"total_cost_usd":0.01,"modelUsage":{"claude-sonnet-5-5":{"inputTokens":10,"outputTokens":20}}}"#
        let decoded = try ClaudeEngine.decode(result(out))
        XCTAssertEqual(decoded.draft.title, "T")
        XCTAssertEqual(decoded.model, "claude-sonnet-5-5")
        XCTAssertEqual(decoded.usage.outputTokens, 20)
    }

    func testClaudeSuccessWithoutStructuredOutputFails() {
        let out = #"{"type":"result","subtype":"success","is_error":false,"result":"Not logged in · Please run /login"}"#
        XCTAssertThrowsError(try ClaudeEngine.decode(result(out))) { XCTAssertEqual($0 as? EngineError, .notLoggedIn(.claude)) }
    }

    func testClaudeUsageLimit() {
        let out = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Claude AI usage limit reached|1767225600"}"#
        XCTAssertThrowsError(try ClaudeEngine.decode(result(out, code: 1))) {
            XCTAssertEqual($0 as? EngineError, .usageLimit(resetsAt: Date(timeIntervalSince1970: 1767225600)))
        }
    }

    func testClaudeArgumentsAvoidBareAndSetSafety() {
        let args = ClaudeEngine(executable: URL(fileURLWithPath: "/bin/true")).arguments(model: "sonnet")
        XCTAssertFalse(args.contains("--bare"))
        for flag in ["-p", "--json-schema", "--no-session-persistence", "--safe-mode", "--tools"] { XCTAssertTrue(args.contains(flag), flag) }
        XCTAssertEqual(args.suffix(2), ["--model", "sonnet"])
    }

    func testCodexEvents() throws {
        let events = """
        {"type":"thread.started","thread_id":"x"}
        {"type":"item.completed","item":{"type":"error","message":"hook warning"}}
        {"type":"item.completed","item":{"type":"agent_message","text":\(String(data: try JSONEncoder().encode(draftJSON), encoding: .utf8)!)}}
        {"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":7}}
        """
        let decoded = try CodexEngine.decode(result(events), lastMessageFile: nil)
        XCTAssertEqual(decoded.draft.title, "T")
        XCTAssertEqual(decoded.usage.outputTokens, 7)
        XCTAssertThrowsError(try CodexEngine.decode(result(#"{"type":"turn.failed","error":{"message":"You've hit your usage limit"}}"#), lastMessageFile: nil)) {
            XCTAssertEqual($0 as? EngineError, .usageLimit(resetsAt: nil))
        }
        XCTAssertEqual(try CodexEngine.decode(result(""), lastMessageFile: "```json\n\(draftJSON)\n```").draft.title, "T")
    }

    func testChildEnvironmentDropsAPIKeys() {
        setenv("ANTHROPIC_API_KEY", "sk-test", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let env = ToolLocator.childEnvironment(for: URL(fileURLWithPath: "/opt/tools/bin/claude"))
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/opt/tools/bin:"))
    }
}
