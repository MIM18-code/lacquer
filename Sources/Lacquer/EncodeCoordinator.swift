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
    /// Headline for the alert showing `errorMessage`.
    @Published var errorTitle = "Lacquer couldn't continue"
    @Published var tools: ExternalTools?
    @Published var capabilities: BluRayEncoder.Capabilities = .none
    @Published private(set) var stopRequested = false

    private var runTask: Task<Void, Never>?
    /// Files being probed right now, so the same file added twice at once
    /// (Open With plus a drop) becomes one job.
    private var loading: Set<URL> = []

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
            errorTitle = "Encoding tools are missing"
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Input

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "ts", "mpg", "mpeg", "webm"
    ]

    /// File › Add Files… and the toolbar button: pick masters or folders.
    func chooseAndAddFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await loadInputs(urls) }
    }

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
            errorTitle = failures.count == 1 ? "This file wasn't added" : "\(failures.count) files weren't added"
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
        let key = url.standardizedFileURL
        if loading.contains(key) || jobs.contains(where: { $0.inputURL.standardizedFileURL == key && $0.status != .done }) {
            return nil
        }
        loading.insert(key)
        defer { loading.remove(key) }
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
            return Self.unreadableMessage(for: url, error: error)
        }
    }

    /// ffprobe's own errors ("moov atom not found") mean little to most
    /// people; say what's likely wrong and what to do.
    static func unreadableMessage(for url: URL, error: Error) -> String {
        let name = url.lastPathComponent
        let detail = "\(error)"
        if detail.contains("moov atom not found") {
            return "\(name) isn't a complete movie file. If it's still exporting or copying, wait for it to finish and add it again."
        }
        if detail.contains("No video stream") {
            return "\(name) has no video, so there's nothing to put on a disc."
        }
        if detail.contains("Invalid data found") {
            return "\(name) isn't a video format Lacquer can read. Export a ProRes, DNxHR, H.264 or HEVC master and add that."
        }
        return "\(name) couldn't be read. \(error.localizedDescription)"
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

    func setMenu(_ menu: MenuTemplate?, for jobID: UUID) {
        mutateEditable(jobID) { $0.menu = menu }
    }

    /// Chapter times for a job under the current settings; the menu's scene
    /// pages follow them.
    func chapters(for job: EncodeJob) -> [Double] {
        settings.chapters.chapterTimes(duration: job.mediaInfo.duration)
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
            $0.startedOutputMode = nil
            $0.startedStandard = nil
            $0.stage = .idle
            $0.progress = 0
            $0.errorMessage = nil
        }
    }

    func retryFailed() {
        for job in jobs where job.status.canRetry { retry(job) }
    }

    func clearFinished() {
        jobs.removeAll { $0.status == .done }
    }

    // MARK: - Run

    func start() {
        guard runTask == nil, tools != nil else { return }
        // A chosen output folder that can't be written would fail every
        // job in turn; catch it once, up front.
        if let folder = settings.outputFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !EncodePipeline.isWritable(folder) {
                errorTitle = "Can't save to that folder"
                errorMessage = "Lacquer can't save to \(folder.path). Choose another folder under Save to, or set it back to next to each master."
                return
            }
        }
        stopRequested = false
        runTask = Task { [weak self] in
            // A pop-up menu applies its new value a beat after it closes, so
            // "pick BDMV, press ⌘↩" could start with the old setting. Give
            // that change time to land before the first job reads settings.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { await self?.runQueue() }
            self?.runTask = nil
        }
    }

    /// Stops the running job (its partial output is deleted) and leaves the
    /// rest of the queue pending.
    func stop() {
        stopRequested = true
        runTask?.cancel()
    }

    /// Stops the running job and returns once its cleanup (deleting the
    /// partial output, closing the log) has finished.
    func stopAndWait() async {
        guard let task = runTask else { return }
        stop()
        await task.value
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

        let request = EncodeRequest(job: job, settings: settings)
        mutateJob(id: jobID) {
            $0.status = .running
            $0.startedOutputMode = request.settings.outputMode
            $0.startedStandard = request.standard
            $0.stage = .checking
            $0.progress = 0
            $0.startedAt = Date()
            $0.errorMessage = nil
        }
        appendLog("")
        appendLog("▶ \(job.inputURL.lastPathComponent)")

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
