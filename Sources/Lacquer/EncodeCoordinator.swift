import Foundation
import SwiftUI
import AppKit

/// Drives the UI: the job queue, the sidebar settings and the run loop.
/// The encode itself lives in `EncodePipeline`.
@MainActor
final class EncodeCoordinator: ObservableObject {
    @Published var jobs: [EncodeJob] = []
    @Published var runningJobID: UUID?
    @Published var log: String = ""
    @Published var settings = EncodeSettings.load() {
        didSet { if settings != oldValue { settings.save() } }
    }
    @Published var errorMessage: String?
    @Published var tools: ExternalTools?
    @Published var capabilities: BluRayEncoder.Capabilities = .none
    @Published private(set) var stopRequested = false

    private var runTask: Task<Void, Never>?

    var isRunning: Bool { runTask != nil }
    var hasPendingJobs: Bool { jobs.contains { $0.status == .pending } }

    // MARK: - Setup

    func loadTools() {
        do {
            let found = try ToolLocator.locate()
            tools = found
            Task {
                let caps = await ToolLocator.capabilities(ffmpeg: found.ffmpeg)
                self.capabilities = caps
            }
        } catch {
            tools = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Input

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "ts", "mpg", "mpeg", "webm"
    ]

    func loadInputs(_ urls: [URL]) async {
        // Expand dropped folders one level so a folder of reels works.
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files += children
                    .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                files.append(url)
            }
        }
        var failures: [String] = []
        for url in files {
            if let reason = await loadInput(url) { failures.append(reason) }
        }
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n\n")
        }
    }

    /// Returns a failure message instead of alerting, so a multi-file drop
    /// reports every bad file in one alert.
    @discardableResult
    func loadInput(_ url: URL) async -> String? {
        guard let tools else {
            return "The encoding tools weren't found, so \(url.lastPathComponent) can't be read."
        }
        if jobs.contains(where: { $0.inputURL == url && $0.status != .done }) {
            return nil
        }
        do {
            let info = try await MediaProbe(ffprobe: tools.ffprobe).probe(url)
            let job = EncodeJob(inputURL: url, mediaInfo: info)
            jobs.append(job)
            appendLog(String(
                format: "+ %@  %d×%d  %@ fps%@  %@  %@",
                url.lastPathComponent,
                info.width, info.height,
                VideoStandard.formatRate(info.frameRate),
                info.sourceIsInterlaced ? " interlaced" : "",
                info.videoCodec,
                formatDuration(info.duration)
            ))
            appendLog("    audio: \(info.label(for: job.audioSource))")
            return nil
        } catch {
            return "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Per-job settings

    /// Mutators are no-ops while the job is running; the pipeline has
    /// already taken its snapshot.
    func setSubtitle(_ url: URL?, for jobID: UUID) {
        mutateEditable(jobID) { $0.subtitleURL = url }
    }

    func setSubtitleLanguage(_ code: String, for jobID: UUID) {
        mutateEditable(jobID) { $0.subtitleLanguageCode = code }
    }

    func setAudioSource(_ source: AudioSource, for jobID: UUID) {
        mutateEditable(jobID) { $0.audioSource = source }
    }

    func setStandardOverride(_ standard: VideoStandard?, for jobID: UUID) {
        mutateEditable(jobID) { $0.standardOverride = standard }
    }

    func plan(for job: EncodeJob) -> EncodePlan {
        EncodePlan.make(EncodeRequest(job: job, settings: settings), capabilities: capabilities)
    }

    // MARK: - Queue management

    func removeJob(_ job: EncodeJob) {
        guard job.status != .running else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func retry(_ job: EncodeJob) {
        mutateJob(id: job.id) {
            guard $0.status.canRetry else { return }
            $0.status = .pending
            $0.stage = .idle
            $0.progress = 0
            $0.errorMessage = nil
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.status == .done }
    }

    // MARK: - Run

    func start() {
        guard runTask == nil, tools != nil else { return }
        stopRequested = false
        runTask = Task { [weak self] in
            await self?.runQueue()
            self?.runTask = nil
        }
    }

    /// Stops the running job (its partial output is deleted) and leaves the
    /// rest of the queue pending.
    func stop() {
        stopRequested = true
        runTask?.cancel()
    }

    private func runQueue() async {
        // Keep the Mac awake for the whole queue; idle sleep would pause
        // a multi-hour encode.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Encoding a Blu-ray"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        var finished = 0
        var failed = 0
        while !Task.isCancelled,
              let job = jobs.first(where: { $0.status == .pending }) {
            let ok = await run(job)
            if ok { finished += 1 } else if !Task.isCancelled { failed += 1 }
        }
        if finished + failed > 0 && !stopRequested {
            NSApp.requestUserAttention(.informationalRequest)
            appendLog(failed == 0
                ? "Queue finished: \(finished) done."
                : "Queue finished: \(finished) done, \(failed) failed.")
        }
    }

    private func run(_ job: EncodeJob) async -> Bool {
        guard let tools else { return false }
        let jobID = job.id
        runningJobID = jobID
        defer { runningJobID = nil }

        mutateJob(id: jobID) {
            $0.status = .running
            $0.stage = .checking
            $0.progress = 0
            $0.startedAt = Date()
            $0.errorMessage = nil
        }
        appendLog("")
        appendLog("▶ \(job.inputURL.lastPathComponent)")

        let request = EncodeRequest(job: job, settings: settings)
        let pipeline = EncodePipeline(tools: tools, capabilities: capabilities)
        do {
            let output = try await pipeline.run(
                request,
                onStage: { [weak self] stage, overall in
                    Task { @MainActor in
                        self?.mutateJob(id: jobID) {
                            guard $0.status == .running else { return }
                            $0.stage = stage
                            $0.progress = overall
                        }
                    }
                },
                onLog: { [weak self] line in
                    Task { @MainActor in self?.appendLog(line) }
                }
            )
            mutateJob(id: jobID) {
                $0.status = .done
                $0.stage = .done
                $0.progress = 1
                $0.outputURL = output.output
                $0.logURL = output.log
            }
            appendLog("  log: \(output.log.lastPathComponent)")
            return true
        } catch is CancellationError {
            appendLog("  ■ stopped")
            mutateJob(id: jobID) {
                $0.status = .cancelled
                $0.stage = .idle
                $0.progress = 0
            }
            return false
        } catch {
            let message = error.localizedDescription
            appendLog("  ✗ \(message)")
            mutateJob(id: jobID) {
                $0.status = .failed
                $0.stage = .failed
                $0.errorMessage = message
                $0.logURL = (error as? EncodePipeline.PipelineError)?.logURL
            }
            return false
        }
    }

    // MARK: - Helpers

    private func mutateEditable(_ id: UUID, _ block: (inout EncodeJob) -> Void) {
        mutateJob(id: id) {
            guard $0.status.isEditable else { return }
            block(&$0)
        }
    }

    private func mutateJob(id: UUID, _ block: (inout EncodeJob) -> Void) {
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            block(&jobs[idx])
        }
    }

    private func appendLog(_ line: String) {
        log.append(line + "\n")
        // The on-screen log is a summary; the full record is in each job's
        // .log file. Cap it so a long session doesn't grow without bound.
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }
}
