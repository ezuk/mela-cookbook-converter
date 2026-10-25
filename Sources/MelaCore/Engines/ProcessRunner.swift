import Foundation
#if canImport(Glibc)
import Glibc
#endif

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case cancelled
}

/// Runs a command-line tool and collects its output. Cancelling the task sends
/// SIGINT, which lets Claude Code finish its turn cleanly (SIGTERM doesn't).
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: Data?,
        timeout: TimeInterval = 900,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let collector = OutputCollector(onLine: onStdoutLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in collector.appendOut(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in collector.appendErr(h.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                let once = Once()
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    once.run {
                        if collector.cancelled { cont.resume(throwing: ProcessRunnerError.cancelled) }
                        else if collector.timedOut { cont.resume(throwing: ProcessRunnerError.timedOut) }
                        else { cont.resume(returning: ProcessResult(exitCode: p.terminationStatus, stdout: collector.out, stderr: collector.err)) }
                    }
                }
                do {
                    try process.run()
                } catch {
                    once.run { cont.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription)) }
                    return
                }
                collector.process = process
                // Write stdin and close it at once: Codex waits for stdin to close.
                if let stdin { inPipe.fileHandleForWriting.write(stdin) }
                try? inPipe.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        collector.timedOut = true
                        process.interrupt()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
                    }
                }
            }
        } onCancel: {
            collector.cancelled = true
            collector.process?.interrupt()
        }
    }
}

/// Thread-safe output buffers shared with the pipe handlers.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data(), _err = Data(), lineBuffer = Data()
    private var _cancelled = false, _timedOut = false
    private var _process: Process?
    let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }
    var cancelled: Bool { get { lock.withLock { _cancelled } } set { lock.withLock { _cancelled = newValue } } }
    var timedOut: Bool { get { lock.withLock { _timedOut } } set { lock.withLock { _timedOut = newValue } } }
    var process: Process? { get { lock.withLock { _process } } set { lock.withLock { _process = newValue } } }

    func appendOut(_ d: Data) {
        guard !d.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            _out.append(d)
            guard onLine != nil else { return }
            lineBuffer.append(d)
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: lineBuffer[lineBuffer.startIndex..<nl], as: UTF8.self))
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            }
        }
        for l in lines { onLine?(l) }
    }

    func appendErr(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.withLock { _err.append(d) }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first: Bool = lock.withLock { if done { return false }; done = true; return true }
        if first { body() }
    }
}
