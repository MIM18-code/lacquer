import Foundation

/// Per-job diagnostic log. Captures everything a future debugger would want:
/// the exact ffmpeg/tsMuxeR command lines, full stderr from each subprocess,
/// the tsMuxeR meta file content, and any errors. Writes incrementally so a
/// crashed run still leaves a useful trail behind it.
///
/// Lifetime: one per job. `EncodeCoordinator` creates it before encoding and
/// closes it on completion (success or failure) — see `closeWithStatus(_:)`.
final class RunLogger: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let handle: FileHandle?
    /// Guarded by `lock`. Once true, writes are dropped instead of racing
    /// with the FileHandle teardown — important because subprocess stderr
    /// callbacks can fire from background queues even after the foreground
    /// run code has called `closeWithStatus`.
    private var isClosed = false
    private let dateFormatter: DateFormatter

    init(url: URL) {
        self.url = url
        self.dateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            f.timeZone = .current
            return f
        }()

        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fm.createFile(atPath: url.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: url)
    }

    /// False when the log file couldn't be opened for writing.
    var isOpen: Bool { handle != nil }

    deinit {
        try? handle?.close()
    }

    // MARK: - Public surface

    /// Free-form message line. Prepends a timestamp.
    func write(_ message: String) {
        appendRaw("[\(dateFormatter.string(from: Date()))] \(message)\n")
    }

    /// Section divider. Use for major phases like "VIDEO ENCODE", "MUX".
    func section(_ title: String) {
        let bar = String(repeating: "─", count: 60)
        appendRaw("\n\(bar)\n■ \(title)\n\(bar)\n")
    }

    /// Captures a key/value table — used for run parameters at the top of the log.
    func table(_ title: String, _ rows: [(String, String)]) {
        appendRaw("\n\(title)\n")
        let keyWidth = rows.map(\.0.count).max() ?? 0
        for (k, v) in rows {
            let padded = k.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
            appendRaw("  \(padded)  \(v)\n")
        }
    }

    /// Records a subprocess invocation header. Call this before launching the
    /// process; pair the resulting `RunLogger.SubprocessRecorder` with the
    /// process's stderr callback so each line gets teed into the log.
    func beginSubprocess(name: String, executable: URL, arguments: [String]) -> SubprocessRecorder {
        section("SUBPROCESS — \(name)")
        appendRaw("  exec: \(executable.path)\n")
        appendRaw("  argc: \(arguments.count)\n")
        for (i, arg) in arguments.enumerated() {
            appendRaw("    [\(i)] \(arg)\n")
        }
        appendRaw("  stderr:\n")
        return SubprocessRecorder(parent: self)
    }

    /// Snapshots a sidecar file (e.g. the tsMuxeR meta) into the log so it
    /// survives the temp-file cleanup.
    func captureFile(label: String, at url: URL) {
        section("FILE — \(label) (\(url.path))")
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            appendRaw(text)
            if !text.hasSuffix("\n") { appendRaw("\n") }
        } else {
            appendRaw("(could not read file)\n")
        }
    }

    func error(_ message: String) {
        appendRaw("\n[!] \(message)\n")
    }

    /// Final status line, then closes the underlying handle. Idempotent —
    /// safe to call multiple times.
    func closeWithStatus(_ status: String) {
        section("RESULT — \(status)")
        write("Run ended.")
        lock.lock()
        if !isClosed {
            isClosed = true
            try? handle?.synchronize()
            try? handle?.close()
        }
        lock.unlock()
    }

    // MARK: - Internals

    private func appendRaw(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        lock.lock()
        if !isClosed {
            try? handle?.write(contentsOf: data)
        }
        lock.unlock()
    }

    /// Helper for streaming stderr line-by-line into the log. Indent each
    /// line so subprocess output reads as a nested block.
    final class SubprocessRecorder: @unchecked Sendable {
        private weak var parent: RunLogger?
        private let lock = NSLock()
        private var lineCount = 0

        init(parent: RunLogger) { self.parent = parent }

        /// Pass this directly as ProcessRunner's `onStderrLine`.
        func recordStderr(_ line: String) {
            lock.lock()
            lineCount += 1
            lock.unlock()
            parent?.appendRaw("    │ \(line)\n")
        }

        /// Call after the subprocess exits to record exit code and a tally.
        func finish(exitCode: Int32) {
            lock.lock()
            let count = lineCount
            lock.unlock()
            parent?.appendRaw("  exit: \(exitCode)  (\(count) stderr lines)\n")
        }
    }
}
