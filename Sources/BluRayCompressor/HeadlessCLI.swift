import Foundation

/// `BluRayCompressor --headless --input FILE [options]` runs one encode
/// without a window. Exit code 0 on success, 1 on failure, 2 on bad usage.
enum HeadlessCLI {
    static let usage = """
    usage: --headless --input FILE [--output-dir DIR] [--mode bdmv|iso|m2ts]
           [--disc bd25|bd50] [--standard auto|1080p23.976|1080p24|1080i29.97|1080i25|720p59.94|720p50|720p23.976|720p24]
           [--audio auto|N|mono5.1|mono5.1-film|monostereo|silence] [--audio-kbps 448|640]
           [--one-pass] [--chapters none|5|10|"00:00,05:30"] [--srt FILE] [--srt-lang eng]
           [--plan-only]
    """

    static func run(_ args: [String]) async -> Int32 {
        var opts: [String: String] = [:]
        var flags: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if ["--headless", "--one-pass", "--plan-only"].contains(a) {
                flags.insert(a)
            } else if a.hasPrefix("--"), i + 1 < args.count {
                opts[a] = args[i + 1]
                i += 1
            } else {
                return fail("unexpected argument \(a)\n\(usage)", code: 2)
            }
            i += 1
        }
        guard let inputPath = opts["--input"] else { return fail(usage, code: 2) }
        let input = URL(fileURLWithPath: inputPath)

        let tools: ExternalTools
        do { tools = try ToolLocator.locate() } catch { return fail(error.localizedDescription) }
        let caps = await ToolLocator.capabilities(ffmpeg: tools.ffmpeg)

        let info: MediaInfo
        do { info = try await MediaProbe(ffprobe: tools.ffprobe).probe(input) } catch {
            return fail("can't read \(input.path): \(error.localizedDescription)")
        }

        var settings = EncodeSettings()
        settings.outputFolderPath = opts["--output-dir"]
        settings.twoPass = !flags.contains("--one-pass")
        switch opts["--mode"] ?? "bdmv" {
        case "bdmv": settings.outputMode = .bdmvFolder
        case "iso": settings.outputMode = .iso
        case "m2ts": settings.outputMode = .m2tsOnly
        case let m: return fail("unknown --mode \(m)", code: 2)
        }
        switch opts["--disc"] ?? "bd25" {
        case "bd25": settings.discSize = .bd25
        case "bd50": settings.discSize = .bd50
        case let d: return fail("unknown --disc \(d)", code: 2)
        }
        if let kbps = opts["--audio-kbps"] {
            guard let v = Int(kbps), v == 448 || v == 640 else { return fail("--audio-kbps must be 448 or 640", code: 2) }
            settings.audioBitrateKbps = v
        }
        switch opts["--chapters"] ?? "5" {
        case "none": settings.chapters.mode = .none
        case "5": settings.chapters.mode = .auto5
        case "10": settings.chapters.mode = .auto10
        case let list:
            settings.chapters.mode = .custom
            settings.chapters.customText = list
        }

        var standard = VideoStandard.suggested(forFrameRate: info.frameRate, interlaced: info.sourceIsInterlaced)
        if let s = opts["--standard"], s != "auto" {
            guard let parsed = VideoStandard.fromCLIName(s) else { return fail("unknown --standard \(s)", code: 2) }
            standard = parsed
        }

        let mono = info.monoStreams.map(\.ffmpegIndex)
        var audio = AudioStreamPicker.bestSource(for: info)
        switch opts["--audio"] ?? "auto" {
        case "auto": break
        case "silence": audio = .silence
        case "mono5.1", "mono5.1-film":
            guard mono.count >= 6 else { return fail("source has \(mono.count) mono tracks; 5.1 needs 6") }
            audio = .discrete(Array(mono.prefix(6)), opts["--audio"] == "mono5.1" ? .smpte : .film)
        case "monostereo":
            guard mono.count >= 2 else { return fail("source has \(mono.count) mono tracks; stereo needs 2") }
            audio = .discrete(Array(mono.prefix(2)), .smpte)
        case let n:
            guard let idx = Int(n), info.audioStream(index: idx) != nil else { return fail("no audio stream \(n)", code: 2) }
            audio = .stream(idx)
        }

        let request = EncodeRequest(
            input: input, info: info, settings: settings, standard: standard, audio: audio,
            subtitle: opts["--srt"].map { URL(fileURLWithPath: $0) },
            subtitleLanguage: opts["--srt-lang"] ?? "eng"
        )
        let plan = EncodePlan.make(request, capabilities: caps)
        print("source: \(info.width)x\(info.height) \(VideoStandard.formatRate(info.frameRate)) fps\(info.sourceIsInterlaced ? " interlaced" : "") \(info.videoCodec) \(formatDuration(info.duration))")
        print("plan: \(standard.shortName) · \(plan.videoBitrate / 1000) kbps video · \(info.label(for: audio)) → AC-3 \(plan.audioBitrateKbps) kbps · ~\(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))")
        for w in plan.warnings { print("warning[\(w.level)]: \(w.text)") }
        if flags.contains("--plan-only") { return plan.isBlocked ? 1 : 0 }

        let pipeline = EncodePipeline(tools: tools, capabilities: caps)
        let lastPrinted = Locked(-1)
        do {
            let out = try await pipeline.run(request, onStage: { stage, overall in
                let pct = Int(overall * 100)
                if lastPrinted.swap(pct) != pct && pct % 5 == 0 {
                    print("progress: \(pct)% \(stage.rawValue)")
                }
            }, onLog: { print($0) })
            print("output: \(out.output.path)")
            print("log: \(out.log.path)")
            return 0
        } catch is CancellationError {
            return fail("stopped", code: 130)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        return code
    }
}

/// Tiny lock-protected box for values shared with @Sendable callbacks.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }

    /// Stores `newValue` and returns the previous value.
    func swap(_ newValue: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
