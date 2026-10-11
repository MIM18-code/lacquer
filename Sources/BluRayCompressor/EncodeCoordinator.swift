import Foundation
import SwiftUI

/// Main observable driving the UI. Holds the job queue, preset, tool
/// locations, and orchestrates the full encode pipeline for every pending job.
@MainActor
final class EncodeCoordinator: ObservableObject {
    @Published var jobs: [EncodeJob] = []
    @Published var runningJobID: UUID?
    @Published var log: String = ""
    @Published var preset = BluRayPreset.default
    @Published var errorMessage: String?
    @Published var tools: ExternalTools?

    var isRunning: Bool { runningJobID != nil }
    var hasPendingJobs: Bool { jobs.contains { $0.status == .pending } }

    // MARK: - Setup

    func loadTools() {
        do {
            self.tools = try ToolLocator.locate()
        } catch {
            self.tools = nil
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Input

    func loadInputs(_ urls: [URL]) async {
        for url in urls {
            await loadInput(url)
        }
    }

    func loadInput(_ url: URL) async {
        guard let tools else {
            errorMessage = "External tools not found. See setup in README."
            return
        }
        do {
            let info = try await MediaProbe(ffprobe: tools.ffprobe).probe(url)
            let outputURL = makeOutputURL(for: url)
            var j = EncodeJob(inputURL: url, outputURL: outputURL, preset: preset)
            j.mediaInfo = info
            j.selectedAudioIndex = AudioStreamPicker.bestStream(from: info.audioStreams)?.ffmpegIndex
            jobs.append(j)
            appendLog(String(
                format: "+ %@  %d×%d  %.3f fps  %@  %@",
                url.lastPathComponent,
                info.width, info.height,
                info.frameRate,
                info.videoCodec,
                formatDuration(info.duration)
            ))
            for stream in info.audioStreams {
                let marker = stream.ffmpegIndex == j.selectedAudioIndex ? "→" : " "
                appendLog("    \(marker) audio[\(stream.ffmpegIndex)]: \(stream.displayLabel)"
                          + (stream.isAmbiguous ? "  (ambiguous — verify)" : ""))
            }
        } catch {
            errorMessage = "Failed to analyze \(url.lastPathComponent):\n\(error.localizedDescription)"
        }
    }

    // MARK: - Per-job mutators

    /// Track-config mutators are no-ops while the job is running. The UI
    /// gates the buttons in the same way, but the second guard here means
    /// a stray timer/keyboard mutation can't silently overwrite state that
    /// the encode pipeline has already snapshotted.
    func setSubtitle(_ url: URL?, for jobID: UUID) {
        mutateJob(id: jobID) {
            guard $0.status != .running else { return }
            $0.subtitleURL = url
        }
    }

    func setSubtitleLanguage(_ code: String, for jobID: UUID) {
        mutateJob(id: jobID) {
            guard $0.status != .running else { return }
            $0.subtitleLanguageCode = code
        }
    }

    func setAudioStream(_ ffmpegIndex: Int, for jobID: UUID) {
        mutateJob(id: jobID) {
            guard $0.status != .running else { return }
            $0.selectedAudioIndex = ffmpegIndex
        }
    }

    private func makeOutputURL(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base)_BluRay")
        var counter = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path)
                || fm.fileExists(atPath: candidate.appendingPathExtension("iso").path)
                || fm.fileExists(atPath: candidate.appendingPathExtension("m2ts").path)
                || jobs.contains(where: { $0.outputURL == candidate }) {
            candidate = dir.appendingPathComponent("\(base)_BluRay_\(counter)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Queue management

    func removeJob(_ job: EncodeJob) {
        guard job.status != .running else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearDone() {
        jobs.removeAll { $0.status == .done }
    }

    // MARK: - Run

    func runAll() async {
        while let index = jobs.firstIndex(where: { $0.status == .pending }) {
            await runJob(at: index)
        }
    }

    private func runJob(at index: Int) async {
        guard index < jobs.count else { return }
        let jobID = jobs[index].id
        runningJobID = jobID
        defer { runningJobID = nil }

        mutateJob(id: jobID) {
            $0.status = .running
            $0.stage = .encodingVideo
            $0.progress = 0
            $0.stageProgress = 0
            $0.errorMessage = nil
        }

        // Immutable snapshot for this run.
        let job = jobs[index]
        guard let info = job.mediaInfo, let tools else {
            markFailed(id: jobID, message: "Missing tools or media info")
            return
        }
        guard let audioStream = info.audioStreams.first(where: {
            $0.ffmpegIndex == job.selectedAudioIndex
        }) ?? info.firstAudioStream else {
            markFailed(id: jobID, message: "Source has no audio stream")
            return
        }
        let preset = job.preset
        let inputURL = job.inputURL
        let outputURL = job.outputURL
        let subtitleURL = job.subtitleURL

        appendLog("")
        appendLog("▶ \(inputURL.lastPathComponent)")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BluRayCompressor-\(jobID.uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: workDir, withIntermediateDirectories: true
            )
        } catch {
            markFailed(id: jobID, message: "Failed to create workdir: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Per-job diagnostic log — sits next to the output and captures every
        // subprocess invocation (full args + stderr), the tsMuxeR meta file,
        // and the resolved run parameters. Kept regardless of success so a
        // failed run can be debugged after the fact.
        let logURL = outputURL.appendingPathExtension("log")
        let runLog = RunLogger(url: logURL)
        runLog.write("Blu-Ray Compressor — job \(jobID.uuidString)")
        runLog.table("Inputs", [
            ("input", inputURL.path),
            ("output target", outputURL.path),
            ("output mode", preset.outputMode.rawValue),
            ("subtitle", subtitleURL?.path ?? "—")
        ])
        runLog.table("Source media", [
            ("duration (s)", String(format: "%.3f", info.duration)),
            ("video", "\(info.width)×\(info.height) \(info.videoCodec) @ \(String(format: "%.3f", info.frameRate)) fps"),
            ("interlaced", info.sourceIsInterlaced ? "yes" : "no"),
            ("audio streams", "\(info.audioStreams.count)")
        ])
        for s in info.audioStreams {
            let marker = s.ffmpegIndex == audioStream.ffmpegIndex ? " ← selected" : ""
            runLog.write("  audio[\(s.ffmpegIndex)]: \(s.displayLabel)" +
                         (s.isAmbiguous ? " (LAYOUT AMBIGUOUS)" : "") + marker)
        }
        runLog.table("Encode plan", [
            ("disc size", preset.discSize.rawValue),
            ("video standard", preset.standard.rawValue),
            ("video bitrate (bps)", "\(BluRayEncoder.videoBitrate(durationSeconds: info.duration, discBytes: preset.discSize.usableBytes, audioBitsPerSecond: preset.audioBitrateKbps * 1000))"),
            ("audio codec", "AC-3 \(preset.audioBitrateKbps) kbps"),
            ("two-pass", preset.twoPass ? "yes" : "no"),
            ("chapters", preset.chapters.mode.rawValue)
        ])

        let videoOut = workDir.appendingPathComponent("video.h264")
        let audioOut = workDir.appendingPathComponent("audio.ac3")

        let encoder = BluRayEncoder(ffmpeg: tools.ffmpeg)
        let audioBps = preset.audioBitrateKbps * 1000
        let vBitrate = BluRayEncoder.videoBitrate(
            durationSeconds: info.duration,
            discBytes: preset.discSize.usableBytes,
            audioBitsPerSecond: audioBps
        )

        // The bitrate function clamps to a 1 Mbps absolute floor so libx264
        // always has a workable target. If the disc-fit math actually wanted
        // a value below that floor, the title is physically too long for the
        // selected disc with the requested audio rate — fail fast with a
        // useful error rather than silently producing oversized output that
        // overflows the disc and only fails downstream at burn time. (M2TS
        // output mode skips this check — the user is about to author in
        // Toast and disc fit is no longer a constraint.)
        if preset.outputMode != .m2tsOnly,
           !BluRayEncoder.fitsOnDisc(
                videoBitrate: vBitrate,
                durationSeconds: info.duration,
                discBytes: preset.discSize.usableBytes,
                audioBitsPerSecond: audioBps
           )
        {
            let durMin = info.duration / 60.0
            let msg = String(format:
                "Title is too long (%.1f min) to fit on %@ with AC-3 %d kbps audio. "
                + "Switch to BD-50, lower the audio bitrate, or trim the source.",
                durMin, preset.discSize.rawValue, preset.audioBitrateKbps)
            runLog.error(msg)
            runLog.closeWithStatus("FAILED — title too long for selected disc")
            markFailed(id: jobID, message: msg + "\n\nSee log: \(logURL.path)")
            return
        }

        let chapterTimes = preset.chapters.chapterTimes(duration: info.duration)
        appendLog("  target: \(vBitrate / 1000) kbps video · AC-3 \(preset.audioBitrateKbps) kbps" +
                  (preset.twoPass ? " · two-pass" : " · one-pass"))

        // Quality warning: when the planned bitrate is below the recommended
        // floor for 1080p Blu-ray, the encode will fit the disc but visible
        // compression artefacts are likely. Surface in both UI log and run
        // log so the user can choose to switch to a larger disc or shorter
        // content before committing to a multi-hour encode.
        if preset.outputMode != .m2tsOnly,
           vBitrate < BluRayEncoder.videoBitrateQualityFloor
        {
            let plannedKbps = vBitrate / 1000
            let floorKbps = BluRayEncoder.videoBitrateQualityFloor / 1000
            appendLog("  ⚠ planned bitrate (\(plannedKbps) kbps) is below the \(floorKbps) kbps recommended")
            appendLog("    floor for 1080p Blu-ray. Encode will fit the disc but picture quality")
            appendLog("    will visibly compress. Consider BD-50 or shorter content for better quality.")
            runLog.write("WARNING: planned video bitrate \(plannedKbps) kbps is below the \(floorKbps) kbps")
            runLog.write("         quality floor recommended for 1080p Blu-ray. Encode will fit the disc")
            runLog.write("         but visible compression artefacts are likely.")
        }
        appendLog("  audio source: stream[\(audioStream.ffmpegIndex)] · \(audioStream.displayLabel)")
        if let subtitleURL {
            appendLog("  subtitles: \(subtitleURL.lastPathComponent) (PGS, selectable)")
            // tsMuxeR's USAGE.md says fonts come from /Library/Fonts/, but
            // the bundled 2.7.0 also resolves /System/Library/Fonts/Supplemental
            // (where Apple ships Arial). Warn only if Arial isn't in any
            // location tsMuxeR actually searches — false alarms here are
            // worse than no warning at all.
            let arialCandidates = [
                "/Library/Fonts/Arial.ttf",
                "/System/Library/Fonts/Supplemental/Arial.ttf"
            ]
            let fm = FileManager.default
            if !arialCandidates.contains(where: fm.fileExists(atPath:)) {
                appendLog("  ⚠ Arial.ttf not found in /Library/Fonts/ or /System/Library/Fonts/Supplemental/")
                appendLog("    tsMuxeR may render no subtitle text. Install a TTF named Arial.")
            }
        }
        if !chapterTimes.isEmpty {
            if preset.outputMode == .m2tsOnly {
                appendLog("  ⚠ chapters configured (\(chapterTimes.count)) but output mode is M2TS only —")
                appendLog("    chapter marks live in the BDMV playlist, not the M2TS itself, so they")
                appendLog("    will be dropped. Re-add chapters in Toast when authoring the disc.")
                runLog.write("WARNING: \(chapterTimes.count) chapter timestamps configured but output mode is M2TS only.")
                runLog.write("         Chapters live in BDMV/PLAYLIST/*.mpls — there is no playlist in")
                runLog.write("         M2TS-only output, so tsMuxeR's --custom-chapters is intentionally")
                runLog.write("         omitted. Re-add chapters in Toast when authoring the disc.")
            } else {
                appendLog("  chapters: \(chapterTimes.count) stops")
            }
        }
        if preset.standard.isInterlaced {
            appendLog("  output: 1080i (source \(info.sourceIsInterlaced ? "interlaced" : "progressive"))")
        }

        // ---- VIDEO ----
        runLog.section("VIDEO ENCODE")
        do {
            try await encoder.encodeVideo(
                input: inputURL,
                videoOut: videoOut,
                bitrate: vBitrate,
                standard: preset.standard,
                sourceIsInterlaced: info.sourceIsInterlaced,
                sourceFrameRate: info.frameRate,
                twoPass: preset.twoPass,
                duration: info.duration,
                logger: runLog,
                progress: { [weak self] frac in
                    Task { @MainActor [weak self] in
                        self?.mutateJob(id: jobID) {
                            $0.stage = .encodingVideo
                            $0.stageProgress = frac
                            $0.progress = frac * 0.70
                        }
                    }
                }
            )
        } catch {
            runLog.error("Video encode failed: \(error.localizedDescription)")
            runLog.closeWithStatus("FAILED — video encode")
            markFailed(id: jobID, message: "Video encode failed: \(error.localizedDescription)\n\nSee log: \(logURL.path)")
            return
        }
        appendLog("  ✓ video")

        // ---- AUDIO ----
        mutateJob(id: jobID) {
            $0.stage = .encodingAudio
            $0.stageProgress = 0
            $0.progress = 0.70
        }
        runLog.section("AUDIO ENCODE")
        do {
            try await encoder.encodeAudio(
                input: inputURL,
                audioOut: audioOut,
                bitrateKbps: preset.audioBitrateKbps,
                sourceStreamIndex: audioStream.ffmpegIndex,
                sourceChannels: audioStream.channels,
                duration: info.duration,
                logger: runLog,
                progress: { [weak self] frac in
                    Task { @MainActor [weak self] in
                        self?.mutateJob(id: jobID) {
                            $0.stage = .encodingAudio
                            $0.stageProgress = frac
                            $0.progress = 0.70 + frac * 0.15
                        }
                    }
                }
            )
        } catch {
            runLog.error("Audio encode failed: \(error.localizedDescription)")
            runLog.closeWithStatus("FAILED — audio encode")
            markFailed(id: jobID, message: "Audio encode failed: \(error.localizedDescription)\n\nSee log: \(logURL.path)")
            return
        }
        appendLog("  ✓ audio")

        // ---- MUX / AUTHOR ----
        let author = BDMVAuthor(tsMuxeR: tools.tsMuxeR)
        mutateJob(id: jobID) {
            $0.stage = .muxing
            $0.stageProgress = 0
            $0.progress = 0.85
        }

        let subtitleLang = job.subtitleLanguageCode.isEmpty
            ? "eng"
            : job.subtitleLanguageCode
        let subtitleTrack = subtitleURL.map {
            BDMVAuthor.SubtitleTrack(srt: $0, languageCode: subtitleLang)
        }
        let outWidth = preset.standard.width
        let outHeight = preset.standard.height
        // Pass the *encoded* frame rate, not the source's. The video has
        // already been re-rated to `preset.standard.frameRateValue` by the
        // encoder; tsMuxeR's meta needs to agree with what's actually in
        // the H.264 stream or players treat the disc as the wrong rate.
        let muxFrameRate = preset.standard.frameRateValue

        runLog.section("MUX / AUTHOR")

        switch preset.outputMode {
        case .m2tsOnly:
            let outFile = outputURL.appendingPathExtension("m2ts")
            do {
                try await author.muxSingleM2TS(
                    videoH264: videoOut,
                    audioAC3: audioOut,
                    frameRate: muxFrameRate,
                    videoWidth: outWidth,
                    videoHeight: outHeight,
                    outputFile: outFile,
                    chapters: chapterTimes,
                    subtitle: subtitleTrack,
                    logger: runLog
                )
            } catch {
                runLog.error("Muxing failed: \(error.localizedDescription)")
                runLog.closeWithStatus("FAILED — mux")
                markFailed(id: jobID, message: "Muxing failed: \(error.localizedDescription)\n\nSee log: \(logURL.path)")
                return
            }
            appendLog("  ✓ wrote \(outFile.lastPathComponent)")

        case .bdmvFolder:
            do {
                try await author.authorBDMV(
                    videoH264: videoOut,
                    audioAC3: audioOut,
                    frameRate: muxFrameRate,
                    videoWidth: outWidth,
                    videoHeight: outHeight,
                    outputFolder: outputURL,
                    chapters: chapterTimes,
                    subtitle: subtitleTrack,
                    logger: runLog
                )
            } catch {
                runLog.error("BDMV authoring failed: \(error.localizedDescription)")
                runLog.closeWithStatus("FAILED — BDMV authoring")
                markFailed(id: jobID, message: "BDMV authoring failed: \(error.localizedDescription)\n\nSee log: \(logURL.path)")
                return
            }
            appendLog("  ✓ BDMV folder: \(outputURL.lastPathComponent)")

        case .iso:
            // tsMuxeR emits a UDF 2.50 ISO directly when the output path ends
            // in .iso. This replaces the prior `BDMV folder + hdiutil makehybrid`
            // step, which silently downgraded the image to UDF 1.50 — a flaw
            // that produced ISOs that played in software but failed on
            // hardware Blu-ray players.
            let isoOut = outputURL.appendingPathExtension("iso")
            do {
                try await author.authorISO(
                    videoH264: videoOut,
                    audioAC3: audioOut,
                    frameRate: muxFrameRate,
                    videoWidth: outWidth,
                    videoHeight: outHeight,
                    outputISO: isoOut,
                    chapters: chapterTimes,
                    subtitle: subtitleTrack,
                    logger: runLog
                )
            } catch {
                runLog.error("ISO build failed: \(error.localizedDescription)")
                runLog.closeWithStatus("FAILED — ISO build")
                markFailed(id: jobID, message: "ISO build failed: \(error.localizedDescription)\n\nSee log: \(logURL.path)")
                return
            }
            appendLog("  ✓ wrote \(isoOut.lastPathComponent)")
        }

        runLog.closeWithStatus("OK")
        appendLog("  log: \(logURL.lastPathComponent)")

        mutateJob(id: jobID) {
            $0.status = .done
            $0.stage = .done
            $0.progress = 1.0
            $0.stageProgress = 1.0
        }
    }

    // MARK: - Helpers

    private func markFailed(id: UUID, message: String) {
        appendLog("  ✗ \(message)")
        mutateJob(id: id) {
            $0.status = .failed
            $0.stage = .failed
            $0.errorMessage = message
        }
        errorMessage = message
    }

    private func mutateJob(id: UUID, _ block: (inout EncodeJob) -> Void) {
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            block(&jobs[idx])
        }
    }

    private func appendLog(_ line: String) {
        log.append(line + "\n")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d",
                      total / 3600, (total % 3600) / 60, total % 60)
    }
}
