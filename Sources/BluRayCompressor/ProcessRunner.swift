import Foundation

/// Async wrapper around Foundation.Process with line-by-line streaming of
/// stdout and stderr. Cancelling the calling task terminates the process,
/// and every live process is tracked so the app can kill them on quit.
/// macOS does not kill child processes when their parent exits, so without
/// this a quit mid-encode leaves ffmpeg running with no window.
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
        let run = RunningProcess(executable: executable, arguments: arguments,
                                 onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)
        let result = try await withTaskCancellationHandler {
            try await run.start()
        } onCancel: {
            run.cancel()
        }
        if run.wasCancelled { throw CancellationError() }
        if result.exitCode != 0 {
            throw RunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// Kills every process started through `run`. Called on app quit.
    static func terminateAll() {
        ProcessRegistry.shared.terminateAll()
    }
}

/// One subprocess run. The continuation resumes once the process has exited
/// and both pipes have reached EOF, so no output is lost and no thread blocks
/// in `waitUntilExit`.
private final class RunningProcess: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let stdoutAccum: LineAccumulator
    private let stderrAccum: LineAccumulator
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessRunner.Result, Error>?
    private var pending = 3   // stdout EOF, stderr EOF, termination
    private var cancelled = false
    private var started = false

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    init(executable: URL, arguments: [String],
         onStdoutLine: (@Sendable (String) -> Void)?,
         onStderrLine: (@Sendable (String) -> Void)?) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        stdoutAccum = LineAccumulator(callback: onStdoutLine)
        stderrAccum = LineAccumulator(callback: onStderrLine)
    }

    func start() async throws -> ProcessRunner.Result {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if cancelled {
                lock.unlock()
                cont.resume(throwing: CancellationError())
                return
            }
            continuation = cont
            lock.unlock()

            attach(outPipe, to: stdoutAccum)
            attach(errPipe, to: stderrAccum)
            process.terminationHandler = { [weak self] _ in self?.finishOne() }

            ProcessRegistry.shared.add(process)
            do {
                try process.run()
            } catch {
                ProcessRegistry.shared.remove(process)
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                let c = continuation
                continuation = nil
                lock.unlock()
                c?.resume(throwing: ProcessRunner.RunnerError.failedToLaunch(error.localizedDescription))
                return
            }
            lock.lock()
            started = true
            let cancelledEarly = cancelled
            lock.unlock()
            if cancelledEarly { terminate() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let isStarted = started
        lock.unlock()
        if isStarted { terminate() }
    }

    /// SIGTERM, then SIGKILL if the process ignores it for five seconds.
    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func attach(_ pipe: Pipe, to accum: LineAccumulator) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.finishOne()
            } else {
                accum.feed(data)
            }
        }
    }

    private func finishOne() {
        lock.lock()
        pending -= 1
        let done = pending == 0
        let c = done ? continuation : nil
        if done { continuation = nil }
        lock.unlock()
        guard done, let c else { return }
        ProcessRegistry.shared.remove(process)
        stdoutAccum.flush()
        stderrAccum.flush()
        c.resume(returning: ProcessRunner.Result(
            exitCode: process.terminationStatus,
            stdout: stdoutAccum.text,
            stderr: stderrAccum.text
        ))
    }
}

private final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ p: Process) {
        lock.lock(); processes[ObjectIdentifier(p)] = p; lock.unlock()
    }

    func remove(_ p: Process) {
        lock.lock(); processes[ObjectIdentifier(p)] = nil; lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let live = Array(processes.values)
        lock.unlock()
        for p in live where p.isRunning {
            p.terminate()
        }
        // Quit can't wait long; give SIGTERM a moment, then force it.
        let deadline = Date().addingTimeInterval(2)
        while live.contains(where: \.isRunning) && Date() < deadline {
            usleep(50_000)
        }
        for p in live where p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }
}

/// Accumulates a stream of bytes, decodes as UTF-8, and emits complete
/// lines via the callback as they arrive. Thread-safe. Bytes that aren't
/// valid UTF-8 (ffmpeg echoes file metadata verbatim) are decoded lossily
/// instead of dropping the whole chunk.
private final class LineAccumulator: @unchecked Sendable {
    private var pendingBytes = Data()
    private var buffer = ""
    private var _text = ""
    private let callback: (@Sendable (String) -> Void)?
    private let lock = NSLock()

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return _text
    }

    init(callback: (@Sendable (String) -> Void)?) {
        self.callback = callback
    }

    func feed(_ data: Data) {
        var completed: [String] = []
        lock.lock()
        pendingBytes.append(data)
        // Hold back an incomplete trailing UTF-8 sequence for the next chunk.
        let cut = Self.completePrefixLength(pendingBytes)
        let chunk = String(decoding: pendingBytes.prefix(cut), as: UTF8.self)
        pendingBytes = Data(pendingBytes.suffix(from: pendingBytes.startIndex + cut))
        buffer += chunk
        _text += chunk
        // ffmpeg separates some status output with bare \r.
        let parts = buffer.split(omittingEmptySubsequences: false,
                                 whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        if parts.count > 1 {
            completed = parts.dropLast().map(String.init).filter { !$0.isEmpty }
            buffer = String(parts.last ?? "")
        }
        lock.unlock()
        for line in completed { callback?(line) }
    }

    func flush() {
        lock.lock()
        if !pendingBytes.isEmpty {
            let tail = String(decoding: pendingBytes, as: UTF8.self)
            buffer += tail
            _text += tail
            pendingBytes.removeAll()
        }
        let remaining = buffer
        buffer = ""
        lock.unlock()
        if !remaining.isEmpty { callback?(remaining) }
    }

    /// Length of the longest prefix that doesn't end mid-way through a
    /// multi-byte UTF-8 sequence.
    private static func completePrefixLength(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        let n = data.count
        for (offset, byte) in bytes.reversed().enumerated() {
            let back = offset + 1
            if byte & 0b1100_0000 == 0b1000_0000 { continue }   // continuation byte
            let need: Int
            if byte & 0b1000_0000 == 0 { need = 1 }
            else if byte & 0b1110_0000 == 0b1100_0000 { need = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { need = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { need = 4 }
            else { return n }
            return back >= need ? n : n - back
        }
        return n
    }
}
