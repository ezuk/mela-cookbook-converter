import Foundation

public enum EngineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    public var other: EngineKind { self == .claude ? .codex : .claude }
    var binaryName: String { rawValue }
}

public enum EngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case notInstalled(EngineKind)
    case notLoggedIn(EngineKind)
    case usageLimit(resetsAt: Date?)
    case invalidOutput(String)
    case failed(String)
    case cancelled

    public var description: String {
        switch self {
        case .notInstalled(let k): return "\(k.displayName) isn't installed."
        case .notLoggedIn(let k): return "\(k.displayName) isn't logged in. Run it once in Terminal to log in."
        case .usageLimit(let date):
            if let date { return "Usage limit reached. Resets \(date.formatted(date: .omitted, time: .shortened))." }
            return "Usage limit reached."
        case .invalidOutput(let s): return "The engine's answer wasn't usable: \(s)"
        case .failed(let s): return s
        case .cancelled: return "Cancelled."
        }
    }

    /// Errors that should pause the queue instead of failing the recipe.
    public var pausesQueue: Bool {
        switch self {
        case .usageLimit, .notLoggedIn, .notInstalled: return true
        default: return false
        }
    }
}

public struct EngineUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// The CLI's own estimate. Not billing data, logged only.
    public var estimatedCostUSD: Double?
}

public struct EngineOutput: Sendable {
    public let draft: RecipeDraft
    public let raw: String
    public let model: String?
    public let usage: EngineUsage
}

public struct EngineInfo: Sendable, Equatable {
    public let kind: EngineKind
    public let executable: URL
    public let version: String?
    public let loggedIn: Bool
    public let account: String?
    /// Model names the user can pick. Empty means "the CLI's default".
    public let models: [String]
}

public protocol RecipeEngine: Sendable {
    var kind: EngineKind { get }
    func parse(prompt: String, model: String?) async throws -> EngineOutput
}

/// Finds CLIs at absolute paths: apps launched from Finder get a minimal PATH.
public enum ToolLocator {
    public static func searchDirectories(home: String = NSHomeDirectory()) -> [String] {
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for d in path.split(separator: ":").map(String.init) where !dirs.contains(d) { dirs.append(d) }
        }
        dirs.append(contentsOf: ["/usr/bin", "/bin"])
        return dirs
    }

    public static func find(_ name: String, home: String = NSHomeDirectory()) -> URL? {
        for dir in searchDirectories(home: home) {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// The environment a CLI child gets: the user's, with an explicit PATH and without API keys,
    /// so runs use the subscription login instead of silently billing an API key.
    public static func childEnvironment(for executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY"] { env.removeValue(forKey: key) }
        let dir = executable.deletingLastPathComponent().path
        let path = ([dir] + searchDirectories()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        env["PATH"] = path.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env
    }

    /// True when the user's shell has an API key that would bill instead of the subscription.
    public static var hasAnthropicAPIKey: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ANTHROPIC_API_KEY"] != nil || env["ANTHROPIC_AUTH_TOKEN"] != nil
    }

    /// An empty folder owned by the app for CLI runs, so no project hooks or MCP servers load.
    public static func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MelaImporter-runs", isDirectory: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum EngineFactory {
    public static func make(_ kind: EngineKind, executable: URL? = nil) throws -> any RecipeEngine {
        guard let exe = executable ?? ToolLocator.find(kind.binaryName) else { throw EngineError.notInstalled(kind) }
        switch kind {
        case .claude: return ClaudeEngine(executable: exe)
        case .codex: return CodexEngine(executable: exe)
        }
    }

    /// Looks up a CLI, its version and login state.
    public static func info(_ kind: EngineKind, executable: URL? = nil) async -> EngineInfo? {
        guard let exe = executable ?? ToolLocator.find(kind.binaryName) else { return nil }
        let env = ToolLocator.childEnvironment(for: exe)
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
        let version = try? await ProcessRunner.run(executable: exe, arguments: ["--version"], environment: env, workingDirectory: cwd, stdin: nil, timeout: 20)
        let versionString = version.map { $0.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init) ?? $0 }
        switch kind {
        case .claude:
            let status = try? await ProcessRunner.run(executable: exe, arguments: ["auth", "status"], environment: env, workingDirectory: cwd, stdin: nil, timeout: 20)
            var loggedIn = status?.exitCode == 0
            var account: String?
            if let data = status?.stdout, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                loggedIn = (obj["loggedIn"] as? Bool) ?? loggedIn
                account = (obj["subscriptionType"] as? String) ?? (obj["authMethod"] as? String)
            }
            return EngineInfo(kind: .claude, executable: exe, version: versionString, loggedIn: loggedIn, account: account,
                              models: ["sonnet", "opus", "haiku"])
        case .codex:
            let status = try? await ProcessRunner.run(executable: exe, arguments: ["login", "status"], environment: env, workingDirectory: cwd, stdin: nil, timeout: 20)
            let text = ((status?.stdoutString ?? "") + (status?.stderrString ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            return EngineInfo(kind: .codex, executable: exe, version: versionString, loggedIn: status?.exitCode == 0,
                              account: text.isEmpty ? nil : text, models: [])
        }
    }
}

enum EngineText {
    /// Spots usage-limit messages and the reset time some of them carry ("…limit reached|1767225600").
    static func usageLimit(in text: String) -> EngineError? {
        let lower = text.lowercased()
        guard lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("rate_limit")
                || lower.contains("limit reached") || lower.contains("429") || lower.contains("quota") else { return nil }
        if let bar = text.range(of: #"\|(\d{10})"#, options: .regularExpression) {
            let digits = text[bar].dropFirst()
            if let t = TimeInterval(digits) { return .usageLimit(resetsAt: Date(timeIntervalSince1970: t)) }
        }
        return .usageLimit(resetsAt: nil)
    }

    static func notLoggedIn(in text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("invalid api key")
            || lower.contains("authentication_failed") || lower.contains("login required") || lower.contains("codex login")
    }
}
