import Foundation

/// Runs Claude Code headless with structured output, no tools and no saved session.
public struct ClaudeEngine: RecipeEngine {
    public let kind = EngineKind.claude
    public let executable: URL
    public var timeout: TimeInterval = 900

    public init(executable: URL) { self.executable = executable }

    public func arguments(model: String?) -> [String] {
        var args = ["-p", "--output-format", "json", "--json-schema", RecipeDraftSchema.json,
                    "--tools", "", "--no-session-persistence", "--max-turns", "3", "--safe-mode"]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    public func parse(prompt: String, model: String?) async throws -> EngineOutput {
        let cwd = try ToolLocator.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(executable: executable, arguments: arguments(model: model),
                                                 environment: ToolLocator.childEnvironment(for: executable),
                                                 workingDirectory: cwd, stdin: Data(prompt.utf8), timeout: timeout)
        } catch ProcessRunnerError.cancelled {
            throw EngineError.cancelled
        } catch ProcessRunnerError.timedOut {
            throw EngineError.failed("Claude Code took too long and was stopped.")
        } catch ProcessRunnerError.launchFailed(let why) {
            throw EngineError.failed("Couldn't start Claude Code: \(why)")
        }
        return try ClaudeEngine.decode(result)
    }

    /// Reads `structured_output` from the final result. A logged-out run still reports "success",
    /// so a success without structured output is a failure too.
    public static func decode(_ result: ProcessResult) throws -> EngineOutput {
        let all = result.stdoutString + "\n" + result.stderrString
        guard let obj = lastJSONObject(in: result.stdoutString) else {
            if EngineText.notLoggedIn(in: all) { throw EngineError.notLoggedIn(.claude) }
            if let limit = EngineText.usageLimit(in: all) { throw limit }
            throw EngineError.failed("Claude Code exited with code \(result.exitCode): \(all.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        let resultText = obj["result"] as? String ?? ""
        let subtype = obj["subtype"] as? String ?? ""
        let isError = obj["is_error"] as? Bool ?? false
        if isError || subtype.hasPrefix("error") || result.exitCode != 0 || obj["structured_output"] == nil {
            if EngineText.notLoggedIn(in: resultText + all) { throw EngineError.notLoggedIn(.claude) }
            if let limit = EngineText.usageLimit(in: resultText) { throw limit }
            if obj["structured_output"] == nil && !isError && subtype == "success" {
                throw EngineError.invalidOutput("no structured output (\(resultText.prefix(200)))")
            }
            throw EngineError.failed("Claude Code failed (\(subtype)): \(resultText.prefix(300))")
        }
        let structured = obj["structured_output"]!
        let data = try JSONSerialization.data(withJSONObject: structured)
        let draft: RecipeDraft
        do {
            draft = try JSONDecoder().decode(RecipeDraft.self, from: data)
        } catch {
            throw EngineError.invalidOutput("\(error)")
        }
        var usage = EngineUsage()
        usage.estimatedCostUSD = obj["total_cost_usd"] as? Double
        var model: String?
        if let mu = obj["modelUsage"] as? [String: Any] {
            model = mu.keys.sorted().first
            if let m = model, let u = mu[m] as? [String: Any] {
                usage.inputTokens = u["inputTokens"] as? Int
                usage.outputTokens = u["outputTokens"] as? Int
            }
        }
        return EngineOutput(draft: draft, raw: String(decoding: data, as: UTF8.self), model: model, usage: usage)
    }

    static func lastJSONObject(in text: String) -> [String: Any]? {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        for line in text.split(separator: "\n").reversed() {
            if let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["type"] as? String == "result" {
                return o
            }
        }
        return nil
    }
}
