import Foundation

/// Everything one encode needs, resolved from a job and the sidebar settings.
struct EncodeRequest: Sendable {
    var input: URL
    var info: MediaInfo
    var settings: EncodeSettings
    var standard: VideoStandard
    var audio: AudioSource
    var subtitle: URL?
    var subtitleLanguage: String = "eng"
    /// On-screen menu for BDMV output. nil: the disc auto-plays the film.
    var menu: DiscMenu?
    /// The job's menu design. The pipeline renders it into `menu` once the
    /// chapter times are known.
    var menuTemplate: MenuTemplate?

    var wantsMenu: Bool { menu != nil || menuTemplate != nil }
    /// Write `<name>.menu.json` (see `HDMVMenuAuthor.MenuMap`) next to the
    /// disc. Headless and debugging only; the app doesn't set it.
    var writesMenuMap = false

    init(job: EncodeJob, settings: EncodeSettings) {
        self.input = job.inputURL
        self.info = job.mediaInfo
        self.settings = settings
        self.standard = job.standard(with: settings)
        self.audio = job.audioSource
        self.subtitle = job.subtitleURL
        self.subtitleLanguage = job.subtitleLanguageCode.isEmpty ? "eng" : job.subtitleLanguageCode
        self.menuTemplate = Features.discMenus ? job.menu : nil
    }

    init(input: URL, info: MediaInfo, settings: EncodeSettings,
         standard: VideoStandard, audio: AudioSource,
         subtitle: URL? = nil, subtitleLanguage: String = "eng") {
        self.input = input
        self.info = info
        self.settings = settings
        self.standard = standard
        self.audio = audio
        self.subtitle = subtitle
        self.subtitleLanguage = subtitleLanguage
    }
}

struct PlanWarning: Equatable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case info, caution, blocking
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    var level: Level
    var text: String
}

/// The numbers and warnings for an encode, computed without running
/// anything. The queue shows these before a job starts, so problems like a
/// title that won't fit or a frame-rate mismatch surface before hours of
/// encoding instead of after.
struct EncodePlan: Equatable, Sendable {
    var videoBitrate: Int
    var audioBitrateKbps: Int
    var fitsOnDisc: Bool
    /// Approximate size of the finished output, which is also roughly the
    /// size of the intermediate streams in the work folder.
    var estimatedBytes: Int64
    var chapterTimes: [Double]
    var warnings: [PlanWarning]

    var isBlocked: Bool { warnings.contains { $0.level == .blocking } }
    var worstLevel: PlanWarning.Level? { warnings.map(\.level).max() }

    static func make(_ req: EncodeRequest,
                     capabilities: BluRayEncoder.Capabilities,
                     fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> EncodePlan {
        let info = req.info
        let settings = req.settings
        let audioKbps = effectiveAudioKbps(req)
        let audioBps = audioKbps * 1000
        let disc = settings.discSize
        let vBitrate = BluRayEncoder.videoBitrate(
            durationSeconds: info.duration,
            discBytes: disc.usableBytes,
            audioBitsPerSecond: audioBps
        )
        let fits = BluRayEncoder.fitsOnDisc(
            videoBitrate: vBitrate,
            durationSeconds: info.duration,
            discBytes: disc.usableBytes,
            audioBitsPerSecond: audioBps
        )
        // ~3% transport-stream overhead on top of the elementary streams.
        let bytes = Int64(Double(vBitrate + audioBps) * info.duration / 8 * 1.03)
        // Chapter marks on frame starts, where the video encode puts IDR
        // frames, so a chapter (from Next or a menu) starts exactly on it
        // instead of at the GOP before.
        let chapters = settings.chapters.chapterTimes(duration: info.duration)
            .map { req.standard.frameStart(nearest: $0) }
            .reduce(into: [Double]()) { if $0.last != $1 { $0.append($1) } }

        var warnings: [PlanWarning] = []
        let checksDisc = settings.outputMode != .m2tsOnly
        if checksDisc && !fits {
            // Only suggest changes that would actually make it fit.
            var fixes: [String] = []
            func fitsWith(disc d: DiscSize, audioKbps a: Int) -> Bool {
                let v = BluRayEncoder.videoBitrate(durationSeconds: info.duration, discBytes: d.usableBytes,
                                                   audioBitsPerSecond: a * 1000)
                return BluRayEncoder.fitsOnDisc(videoBitrate: v, durationSeconds: info.duration,
                                                discBytes: d.usableBytes, audioBitsPerSecond: a * 1000)
            }
            if disc == .bd25 && fitsWith(disc: .bd50, audioKbps: audioKbps) { fixes.append("switch to BD-50") }
            if audioKbps > 448 && fitsWith(disc: disc, audioKbps: 448) { fixes.append("use 448 kbps audio") }
            fixes.append(fixes.isEmpty ? "split it across discs" : "trim it")
            let advice = fixes.count == 1 ? fixes[0] : fixes.dropLast().joined(separator: ", ") + " or " + fixes.last!
            warnings.append(PlanWarning(level: .blocking, text:
                "\(formatDuration(info.duration)) is too long for \(disc.shortName). To fit, \(advice)."))
        } else if checksDisc && vBitrate < BluRayEncoder.videoBitrateQualityFloor {
            warnings.append(PlanWarning(level: .caution, text:
                "Video gets \(vBitrate / 1000) kbps to fit \(disc.shortName), below the 8,000 kbps where compression starts to show."
                + (disc == .bd25 ? " BD-50 would double it." : "")))
        }
        if let note = req.standard.rateNote(sourceFrameRate: info.frameRate,
                                            sourceInterlaced: info.sourceIsInterlaced) {
            switch note {
            case .major(let m): warnings.append(PlanWarning(level: .caution, text: m))
            case .minor(let m): warnings.append(PlanWarning(level: .info, text: m))
            }
        }
        if info.isHDR {
            warnings.append(capabilities.canTonemapHDR
                ? PlanWarning(level: .info, text: "HDR source: tonemapped to SDR BT.709 for Blu-ray. For full control, export an SDR master.")
                : PlanWarning(level: .caution, text: "HDR source and this ffmpeg can't tonemap, so colors will look washed out. Export an SDR Rec.709 master."))
        }
        switch req.audio {
        case .silence:
            warnings.append(PlanWarning(level: .info, text: "No audio in the source. The disc gets a silent stereo track."))
        case .stream(let index):
            if let s = info.audioStream(index: index) {
                if s.isAmbiguous {
                    warnings.append(PlanWarning(level: .caution, text: "Audio track \(index) has 8 channels and no layout tag. It could be 7.1 or 5.1 plus a stereo fold-down. Check before encoding."))
                }
                if s.isMono && info.monoStreams.count >= 2 {
                    warnings.append(PlanWarning(level: .caution, text: "Only mono track \(index) is used. Pick the stereo or 5.1 option in the audio menu to combine the mono tracks."))
                }
            }
        case .discrete:
            break
        }
        if req.wantsMenu {
            switch settings.outputMode {
            case .bdmvFolder: break
            case .iso: break
            case .m2tsOnly:
                warnings.append(PlanWarning(level: .info, text: "M2TS output has no menus. Author them in Toast, or choose BDMV Folder."))
            }
        }
        if !chapters.isEmpty && settings.outputMode == .m2tsOnly {
            warnings.append(PlanWarning(level: .info, text: "Chapters live in the disc playlist, which M2TS output doesn't have. Add them in Toast."))
        }
        if req.subtitle != nil {
            let arial = ["/Library/Fonts/Arial.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"]
            if !arial.contains(where: fileExists) {
                warnings.append(PlanWarning(level: .caution, text: "Arial isn't installed, so subtitles may come out blank."))
            }
        }
        if info.height > 0 && info.height < req.standard.height * 2 / 3 {
            warnings.append(PlanWarning(level: .info, text: "\(info.width)×\(info.height) source is upscaled to \(req.standard.width)×\(req.standard.height)."))
        }
        return EncodePlan(videoBitrate: vBitrate, audioBitrateKbps: audioKbps,
                          fitsOnDisc: fits, estimatedBytes: bytes,
                          chapterTimes: chapters, warnings: warnings)
    }

    static func effectiveAudioKbps(_ req: EncodeRequest) -> Int {
        let requested = req.settings.audioBitrateKbps
        switch req.audio {
        case .silence: return 192
        case .discrete(let idx, _):
            return min(requested, BluRayEncoder.maxAC3Bitrate(channels: idx.count >= 6 ? 6 : 2))
        case .stream(let i):
            let ch = min(max(req.info.audioStream(index: i)?.channels ?? 2, 1), 6)
            return min(requested, BluRayEncoder.maxAC3Bitrate(channels: ch))
        }
    }
}

enum OutputNaming {
    /// Characters tsMuxeR's meta format can't carry in a path. Replacing
    /// them up front beats failing at the mux step after hours of encoding.
    static func sanitizedBase(_ name: String) -> String {
        var s = name
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix(".") { s = "Disc" + s }
        return s
    }

    /// File names are limited to 255 bytes. Leave room for "_BluRay", a
    /// "_999" counter and the longest extension a job writes (".menu.json").
    static let baseByteBudget = 255 - "_BluRay_999".utf8.count - ".menu.json".utf8.count

    /// Cuts a name to `maxBytes` of UTF-8 without splitting a character.
    static func truncated(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var out = ""
        for ch in name {
            if out.utf8.count + String(ch).utf8.count > maxBytes { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Picks `<folder>/<input name>_BluRay` (numbered if taken) and claims it
    /// by creating its log file exclusively, so two encodes running at the
    /// same time can never pick the same output.
    static func reserveBase(in folder: URL, for input: URL) throws -> URL {
        let fm = FileManager.default
        var excluded = Set<String>()
        while true {
            let base = uniqueBase(in: folder, for: input,
                                  fileExists: { excluded.contains($0) || fm.fileExists(atPath: $0) })
            let log = base.appendingPathExtension("log")
            let fd = open(log.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                return base
            }
            if errno != EEXIST {
                throw EncodePipeline.PipelineError.preflight(
                    "Can't create \(log.lastPathComponent) in \(folder.path): \(String(cString: strerror(errno))).")
            }
            excluded.insert(log.path)
        }
    }

    /// `<folder>/<input name>_BluRay`, numbered if anything with that stem
    /// (folder, .iso, .m2ts or .log) already exists.
    static func uniqueBase(in folder: URL, for input: URL,
                           fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL {
        let stem = truncated(sanitizedBase(input.deletingPathExtension().lastPathComponent),
                             maxBytes: baseByteBudget) + "_BluRay"
        var candidate = folder.appendingPathComponent(stem)
        var counter = 2
        func taken(_ url: URL) -> Bool {
            fileExists(url.path)
                || fileExists(url.appendingPathExtension("iso").path)
                || fileExists(url.appendingPathExtension("m2ts").path)
                || fileExists(url.appendingPathExtension("log").path)
        }
        while taken(candidate) {
            candidate = folder.appendingPathComponent("\(stem)_\(counter)")
            counter += 1
        }
        return candidate
    }

    static func output(base: URL, mode: OutputMode) -> URL {
        switch mode {
        case .bdmvFolder: return base
        case .iso:        return base.appendingPathExtension("iso")
        case .m2tsOnly:   return base.appendingPathExtension("m2ts")
        }
    }
}

enum SubtitlePrep {
    /// tsMuxeR reads SRT as UTF-8. Subtitle files from Windows tools are
    /// often UTF-16 or Windows-1252, which come out as garbage or nothing,
    /// so decode whatever the file is and write a clean UTF-8 copy.
    static func utf8Text(from data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func writeUTF8Copy(of srt: URL, to dest: URL) throws {
        let data = try Data(contentsOf: srt)
        guard let text = utf8Text(from: data) else {
            throw EncodePipeline.PipelineError.preflight("Couldn't read \(srt.lastPathComponent) as text.")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        try normalized.write(to: dest, atomically: true, encoding: .utf8)
    }
}

/// Runs one encode end to end: checks, video, audio, mux. No UI; the app's
/// queue and the headless command line both drive it.
struct EncodePipeline {
    let tools: ExternalTools
    let capabilities: BluRayEncoder.Capabilities

    struct Output: Sendable {
        var output: URL
        var log: URL
    }

    enum PipelineError: LocalizedError {
        case blocked(String)
        case preflight(String)
        case stage(String, detail: String, log: URL)

        var errorDescription: String? {
            switch self {
            case .blocked(let m), .preflight(let m): return m
            case .stage(let stage, let detail, let log):
                return "\(stage) failed: \(detail)\n\nLog: \(log.path)"
            }
        }

        var logURL: URL? {
            if case .stage(_, _, let log) = self { return log }
            return nil
        }
    }

    func run(
        _ req: EncodeRequest,
        onStage: @escaping @Sendable (EncodeStage, Double) -> Void,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> Output {
        var req = req
        let fm = FileManager.default
        let info = req.info
        let settings = req.settings
        let plan = EncodePlan.make(req, capabilities: capabilities)
        if let block = plan.warnings.first(where: { $0.level == .blocking }) {
            throw PipelineError.blocked(block.text)
        }
        onStage(.checking, 0)

        // ---- Output location ----
        let folder = settings.outputFolder ?? req.input.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw PipelineError.preflight("Can't create the output folder \(folder.path): \(error.localizedDescription)")
        }
        guard Self.isWritable(folder) else {
            throw PipelineError.preflight("Can't write to \(folder.path). Choose another output folder in the sidebar.")
        }
        // ---- Work folder on the output volume, so a long encode doesn't
        // fill the startup disk when the output goes to an external drive.
        let workDir: URL
        if let onVolume = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: folder, create: true) {
            workDir = onVolume
        } else {
            workDir = fm.temporaryDirectory.appendingPathComponent("disc-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: workDir) }

        // ---- Free space ----
        let margin: Int64 = 1_000_000_000
        if Self.sameVolume(workDir, folder) {
            try Self.requireSpace(plan.estimatedBytes * 2 + margin, at: folder, purpose: "the encode and the finished output")
        } else {
            try Self.requireSpace(plan.estimatedBytes + margin, at: workDir, purpose: "temporary streams")
            try Self.requireSpace(plan.estimatedBytes + margin, at: folder, purpose: "the finished output")
        }

        // Claim the output name last among the checks, so a failed check
        // leaves no empty log behind.
        let base = try OutputNaming.reserveBase(in: folder, for: req.input)
        let target = OutputNaming.output(base: base, mode: settings.outputMode)

        // ---- Log ----
        let logURL = base.appendingPathExtension("log")
        let log = RunLogger(url: logURL)
        guard log.isOpen else {
            try? fm.removeItem(at: logURL)
            throw PipelineError.preflight("Can't write the log \(logURL.lastPathComponent) in \(folder.path).")
        }
        log.write("\(AppInfo.name) \(AppInfo.version) — \(req.input.lastPathComponent)")
        log.table("Inputs", [
            ("input", req.input.path),
            ("output", target.path),
            ("output mode", settings.outputMode.rawValue),
            ("work folder", workDir.path),
            ("subtitle", req.subtitle?.path ?? "—")
        ])
        log.table("Source media", [
            ("duration (s)", String(format: "%.3f", info.duration)),
            ("video", "\(info.width)×\(info.height) \(info.videoCodec) @ \(String(format: "%.3f", info.frameRate)) fps"),
            ("interlaced", info.sourceIsInterlaced ? "yes" : "no"),
            ("color", "\(info.colorPrimaries)/\(info.colorTransfer)/\(info.colorSpace) \(info.pixelFormat)"),
            ("audio streams", "\(info.audioStreams.count)")
        ])
        for s in info.audioStreams {
            log.write("  audio[\(s.ffmpegIndex)]: \(s.displayLabel)" + (s.isAmbiguous ? " (LAYOUT AMBIGUOUS)" : ""))
        }
        log.table("Encode plan", [
            ("disc size", settings.discSize.rawValue),
            ("video standard", req.standard.rawValue),
            ("video bitrate (bps)", "\(plan.videoBitrate)"),
            ("audio", "\(info.label(for: req.audio)) → AC-3 \(plan.audioBitrateKbps) kbps"),
            ("two-pass", settings.twoPass ? "yes" : "no"),
            ("chapters", "\(settings.chapters.mode.rawValue) (\(plan.chapterTimes.count))"),
            ("estimated size", ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))
        ])
        for w in plan.warnings {
            log.write("\(w.level == .info ? "NOTE" : "WARNING"): \(w.text)")
            onLog("  \(w.level == .info ? "·" : "⚠") \(w.text)")
        }
        onLog("  \(req.standard.shortName) · \(plan.videoBitrate / 1000) kbps video · AC-3 \(plan.audioBitrateKbps) kbps · \(settings.twoPass ? "two-pass" : "one-pass")")

        var succeeded = false
        defer {
            // Never leave a half-written disc where someone might burn it.
            if !succeeded { try? fm.removeItem(at: target) }
        }

        func fail(_ stage: String, _ error: Error) -> Error {
            if error is CancellationError {
                log.closeWithStatus("STOPPED by user")
                return error
            }
            log.error("\(stage) failed: \(error.localizedDescription)")
            log.closeWithStatus("FAILED — \(stage.lowercased())")
            return PipelineError.stage(stage, detail: error.localizedDescription, log: logURL)
        }

        // ---- Menu ----
        // Rendered before the long encode so a problem with the design (a
        // missing background image) fails in seconds, not hours.
        if req.menu == nil, let template = req.menuTemplate, settings.outputMode != .m2tsOnly {
            onLog("  rendering the disc menu")
            log.section("MENU RENDER")
            let hdr = info.isHDR && capabilities.canTonemapHDR ? info.colorTransfer : nil
            do {
                req.menu = try await MenuRenderer(ffmpeg: tools.ffmpeg, hdrTransfer: hdr,
                                                  deinterlace: info.sourceIsInterlaced)
                    .render(template: template, film: req.input, chapters: plan.chapterTimes,
                            hasSubtitles: req.subtitle != nil)
                log.write("Rendered \(req.menu?.pages.count ?? 0) menu pages (\(template.style.displayName))")
                // Refuse a layout the disc image can't hold now, not after the encode.
                try UDFImageWriter.checkLayout(menuPages: req.menu?.pages.count ?? 0)
            } catch {
                throw fail("Menu render", error)
            }
        }

        // ---- Subtitles ----
        var subtitleTrack: BDMVAuthor.SubtitleTrack?
        if let srt = req.subtitle {
            let copy = workDir.appendingPathComponent("subtitles.srt")
            do {
                try SubtitlePrep.writeUTF8Copy(of: srt, to: copy)
            } catch {
                throw fail("Subtitle prep", error)
            }
            subtitleTrack = BDMVAuthor.SubtitleTrack(srt: copy, languageCode: req.subtitleLanguage)
        }

        let encoder = BluRayEncoder(ffmpeg: tools.ffmpeg)
        let videoOut = workDir.appendingPathComponent("video.h264")
        let audioOut = workDir.appendingPathComponent("audio.ac3")

        // ---- Video (0–80%) ----
        onStage(.encodingVideo, 0)
        log.section("VIDEO ENCODE")
        do {
            try await encoder.encodeVideo(
                input: req.input, videoOut: videoOut, workDir: workDir,
                bitrate: plan.videoBitrate, standard: req.standard,
                source: info, capabilities: capabilities,
                twoPass: settings.twoPass, keyframes: plan.chapterTimes, logger: log,
                progress: { frac in onStage(.encodingVideo, frac * 0.80) }
            )
        } catch {
            throw fail("Video encode", error)
        }
        onLog("  ✓ video")

        // ---- Audio (80–88%) ----
        onStage(.encodingAudio, 0.80)
        log.section("AUDIO ENCODE")
        do {
            try await encoder.encodeAudio(
                input: req.input, audioOut: audioOut, source: req.audio,
                info: info, bitrateKbps: plan.audioBitrateKbps, logger: log,
                progress: { frac in onStage(.encodingAudio, 0.80 + frac * 0.08) }
            )
        } catch {
            throw fail("Audio encode", error)
        }
        onLog("  ✓ audio")

        // ---- Mux (88–100%) ----
        onStage(.muxing, 0.88)
        log.section("MUX / AUTHOR")
        let author = BDMVAuthor(tsMuxeR: tools.tsMuxeR)
        let lang = Self.audioLanguage(req)
        var menuMap: HDMVMenuAuthor.MenuMap?
        do {
            try Task.checkCancellation()
            switch settings.outputMode {
            case .m2tsOnly:
                try await author.muxSingleM2TS(
                    videoH264: videoOut, audioAC3: audioOut,
                    frameRate: req.standard.frameRateValue,
                    videoWidth: req.standard.width, videoHeight: req.standard.height,
                    outputFile: target, chapters: plan.chapterTimes,
                    subtitle: subtitleTrack, languageCode: lang, logger: log)
            case .bdmvFolder:
                try await author.authorBDMV(
                    videoH264: videoOut, audioAC3: audioOut,
                    frameRate: req.standard.frameRateValue,
                    videoWidth: req.standard.width, videoHeight: req.standard.height,
                    outputFolder: target, chapters: plan.chapterTimes,
                    subtitle: subtitleTrack, languageCode: lang, logger: log)
                if let menu = req.menu {
                    log.section("DISC MENU")
                    menuMap = try await HDMVMenuAuthor(ffmpeg: tools.ffmpeg)
                        .author(menu, disc: target, workDir: workDir, logger: log, onLog: onLog)
                }
            case .iso where req.menu != nil:
                // tsMuxeR only images what it muxed itself, so author the
                // folder here, add the menus, then write the UDF 2.50 image.
                let folder = workDir.appendingPathComponent("disc")
                try await author.authorBDMV(
                    videoH264: videoOut, audioAC3: audioOut,
                    frameRate: req.standard.frameRateValue,
                    videoWidth: req.standard.width, videoHeight: req.standard.height,
                    outputFolder: folder, chapters: plan.chapterTimes,
                    subtitle: subtitleTrack, languageCode: lang, logger: log)
                // The streams are now in the folder; free their space for the image.
                try? fm.removeItem(at: videoOut)
                try? fm.removeItem(at: audioOut)
                log.section("DISC MENU")
                menuMap = try await HDMVMenuAuthor(ffmpeg: tools.ffmpeg)
                    .author(req.menu!, disc: folder, workDir: workDir, logger: log, onLog: onLog)
                log.section("UDF 2.50 IMAGE")
                let label = BDMVAuthor.discLabel(for: req.input.deletingPathExtension().lastPathComponent)
                try await Self.writeImage(of: folder, to: target, label: label)
                log.write("Wrote \(target.lastPathComponent), label \(label)")
            case .iso:
                try await author.authorISO(
                    videoH264: videoOut, audioAC3: audioOut,
                    frameRate: req.standard.frameRateValue,
                    videoWidth: req.standard.width, videoHeight: req.standard.height,
                    outputISO: target, chapters: plan.chapterTimes,
                    subtitle: subtitleTrack, languageCode: lang,
                    discLabel: BDMVAuthor.discLabel(for: req.input.deletingPathExtension().lastPathComponent),
                    logger: log)
            }
        } catch {
            throw fail("Disc authoring", error)
        }
        succeeded = true
        Self.makeReadable(target)
        if req.writesMenuMap, var map = menuMap {
            map.chapters = plan.chapterTimes
            let mapURL = URL(fileURLWithPath: base.path + ".menu.json")
            try? map.json().write(to: mapURL)
            onLog("  menu map: \(mapURL.path)")
        }
        log.closeWithStatus("OK")
        onLog("  ✓ wrote \(target.lastPathComponent)")
        onStage(.done, 1)
        return Output(output: target, log: logURL)
    }

    // MARK: - Helpers

    /// Runs the (blocking) image writer off the cooperative pool, stopping
    /// it if the job is cancelled.
    static func writeImage(of folder: URL, to iso: URL, label: String) async throws {
        let stop = CancelFlag()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try UDFImageWriter.writeImage(of: folder, to: iso, label: label, isCancelled: { stop.isSet })
            }.value
        } onCancel: {
            stop.set()
        }
        try Task.checkCancellation()
    }

    /// Language tag for the disc's video and audio streams: the source audio
    /// track's tag when it's a real ISO 639-2 code, English otherwise.
    static func audioLanguage(_ req: EncodeRequest) -> String {
        let index: Int?
        switch req.audio {
        case .stream(let i): index = i
        case .discrete(let idx, _): index = idx.first
        case .silence: index = nil
        }
        guard let index, let lang = req.info.audioStream(index: index)?.language?.lowercased(),
              lang.count == 3, lang != "und", lang.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return "eng" }
        return lang
    }

    /// tsMuxeR creates its files owner-only (0640). Open them up to 0644 so
    /// the disc can be read from a shared drive or by another user account.
    static func makeReadable(_ target: URL) {
        let fm = FileManager.default
        var paths = [target.path]
        if let walker = fm.enumerator(atPath: target.path) {
            paths += walker.compactMap { ($0 as? String).map { (target.path as NSString).appendingPathComponent($0) } }
        }
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            try? fm.setAttributes([.posixPermissions: isDir.boolValue ? 0o755 : 0o644], ofItemAtPath: path)
        }
    }

    static func isWritable(_ folder: URL) -> Bool {
        let probe = folder.appendingPathComponent(".write-test-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let kb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let ka, let kb else { return true }
        return ka.isEqual(kb)
    }

    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func requireSpace(_ bytes: Int64, at url: URL, purpose: String) throws {
        guard let free = freeBytes(at: url) else { return }
        if free < bytes {
            let need = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            throw PipelineError.preflight("Not enough space for \(purpose): needs about \(need), \(have) free on the volume holding \(url.path).")
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

enum AppInfo {
    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Lacquer"
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

/// A flag set from a cancellation handler and polled by blocking work.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
