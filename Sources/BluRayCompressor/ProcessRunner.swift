import Foundation

/// Thin async wrapper around Foundation.Process with line-by-line
/// streaming of stdout and stderr.
enum ProcessRunner {

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum RunnerError: LocalizedError {
        case nonZeroExit(code: Int32, stderr: String)
        case failedToLaunch(String)

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let code, let stderr):
                let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
                return "Exit code \(code).\n\(tail)"
            case .failedToLaunch(let msg):
                return "Failed to launch process: \(msg)"
            }
        }
    }

    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = executable
            task.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            let stdoutAccum = LineAccumulator(callback: onStdoutLine)
            let stderrAccum = LineAccumulator(callback: onStderrLine)

            // Streaming order: handlers are kept live until after the process
            // exits, then nil'd, then `readToEnd` drains anything still in
            // the kernel pipe. There is a brief window where the handler can
            // fire concurrently with `readToEnd`, but `LineAccumulator` is
            // NSLock-protected, so the worst case is mild reordering of one
            // log line — not corruption.
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdoutAccum.feed(data) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrAccum.feed(data) }
            }

            do {
                try task.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw RunnerError.failedToLaunch(error.localizedDescription)
            }

            task.waitUntilExit()

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            // Drain anything that slipped in during teardown.
            if let d = try? outPipe.fileHandleForReading.readToEnd(), !d.isEmpty {
                stdoutAccum.feed(d)
            }
            if let d = try? errPipe.fileHandleForReading.readToEnd(), !d.isEmpty {
                stderrAccum.feed(d)
            }
            stdoutAccum.flush()
            stderrAccum.flush()

            let result = Result(
                exitCode: task.terminationStatus,
                stdout: stdoutAccum.text,
                stderr: stderrAccum.text
            )
            if task.terminationStatus != 0 {
                throw RunnerError.nonZeroExit(code: task.terminationStatus,
                                              stderr: stderrAccum.text)
            }
            return result
        }.value
    }
}

/// Accumulates a stream of bytes, decodes as UTF-8, and emits complete
/// lines via the callback as they arrive. Thread-safe.
private final class LineAccumulator: @unchecked Sendable {
    private var buffer = ""
    private(set) var text = ""
    private let callback: (@Sendable (String) -> Void)?
    private let lock = NSLock()

    init(callback: (@Sendable (String) -> Void)?) {
        self.callback = callback
    }

    func feed(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        var completed: [String] = []
        lock.lock()
        buffer += chunk
        text += chunk
        let parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.count > 1 {
            for i in 0..<(parts.count - 1) {
                completed.append(String(parts[i]))
            }
            buffer = String(parts.last ?? "")
        }
        lock.unlock()
        for line in completed { callback?(line) }
    }

    func flush() {
        lock.lock()
        let remaining = buffer
        buffer = ""
        lock.unlock()
        if !remaining.isEmpty { callback?(remaining) }
    }
}
