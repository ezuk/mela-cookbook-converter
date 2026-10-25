import Foundation

/// Runs `codex exec` with an output schema, read-only sandbox, no saved session and no user config.
public struct CodexEngine: RecipeEngine {
    public let kind = EngineKind.codex
    public let executable: URL
    public var timeout: TimeInterval = 900

    public init(executable: URL) { self.executable = executable }

    public func arguments(model: String?, schemaFile: URL, outputFile: URL, workingDirectory: URL, prompt: String) -> [String] {
        var args = ["exec", "--json", "--output-schema", schemaFile.path, "-o", outputFile.path, "--ephemeral",
                    "--skip-git-repo-check", "-s", "read-only", "--ignore-user-config", "-C", workingDirectory.path]
        if let model, !model.isEmpty { args += ["-m", model] }
        args.append(prompt)
        return args
    }

    public func parse(prompt: String, model: String?) async throws -> EngineOutput {
        let cwd = try ToolLocator.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let schemaFile = cwd.appendingPathComponent("schema.json")
        let outputFile = cwd.appendingPathComponent("answer.json")
        try Data(RecipeDraftSchema.json.utf8).write(to: schemaFile)
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments(model: model, schemaFile: schemaFile, outputFile: outputFile, workingDirectory: cwd, prompt: prompt),
                environment: ToolLocator.childEnvironment(for: executable), workingDirectory: cwd, stdin: nil, timeout: timeout)
        } catch ProcessRunnerError.cancelled {
            throw EngineError.cancelled
        } catch ProcessRunnerError.timedOut {
            throw EngineError.failed("Codex took too long and was stopped.")
        } catch ProcessRunnerError.launchFailed(let why) {
            throw EngineError.failed("Couldn't start Codex: \(why)")
        }
        let lastMessage = try? String(contentsOf: outputFile, encoding: .utf8)
        return try CodexEngine.decode(result, lastMessageFile: lastMessage)
    }

    /// Reads the JSONL event stream: `item.completed` agent messages hold the answer, `turn.completed`
    /// the usage, `turn.failed` or a top-level `error` a failure. `item.completed` errors are hook warnings.
    public static func decode(_ result: ProcessResult, lastMessageFile: String?) throws -> EngineOutput {
        var answer = lastMessageFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        var usage = EngineUsage()
        var failure: String?
        var model: String?
        for line in result.stdoutString.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "item.completed":
                if let item = ev["item"] as? [String: Any], item["type"] as? String == "agent_message", let text = item["text"] as? String,
                   answer?.isEmpty ?? true {
                    answer = text
                }
            case "turn.completed":
                if let u = ev["usage"] as? [String: Any] {
                    usage.inputTokens = u["input_tokens"] as? Int
                    usage.outputTokens = u["output_tokens"] as? Int
                }
            case "turn.failed":
                failure = ((ev["error"] as? [String: Any])?["message"] as? String) ?? "turn failed"
            case "error":
                failure = (ev["message"] as? String) ?? "error"
            case "thread.started", "turn.started":
                model = (ev["model"] as? String) ?? model
            default: continue
            }
        }
        let all = result.stdoutString + "\n" + result.stderrString
        if let failure {
            if EngineText.notLoggedIn(in: failure) { throw EngineError.notLoggedIn(.codex) }
            if let limit = EngineText.usageLimit(in: failure) { throw limit }
            throw EngineError.failed("Codex failed: \(failure.prefix(300))")
        }
        guard let text = answer, !text.isEmpty else {
            if EngineText.notLoggedIn(in: all) { throw EngineError.notLoggedIn(.codex) }
            if let limit = EngineText.usageLimit(in: all) { throw limit }
            throw EngineError.failed("Codex exited with code \(result.exitCode) and no answer: \(all.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        let json = stripCodeFence(text)
        do {
            let draft = try JSONDecoder().decode(RecipeDraft.self, from: Data(json.utf8))
            return EngineOutput(draft: draft, raw: json, model: model, usage: usage)
        } catch {
            throw EngineError.invalidOutput("\(error)")
        }
    }

    static func stripCodeFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
