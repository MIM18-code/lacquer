import Foundation

// MARK: - Disc size

enum DiscSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case bd25 = "BD-25 (25 GB, single layer)"
    case bd50 = "BD-50 (50 GB, dual layer)"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .bd25: return "BD-25"
        case .bd50: return "BD-50"
        }
    }

    /// What the disc holds, as printed on it (BD-25 is 25.0 GB).
    var capacityBytes: Int64 {
        switch self {
        case .bd25: return 25_025_314_816
        case .bd50: return 50_050_629_632
        }
    }

    /// Bytes the encode aims for: capacity less filesystem, BDMV and
    /// muxing overhead, with margin.
    var usableBytes: Int64 {
        switch self {
        case .bd25: return 23_400_000_000
        case .bd50: return 46_800_000_000
        }
    }
}

// MARK: - Video standard

enum VideoStandard: String, CaseIterable, Identifiable, Codable, Sendable {
    case p1080_2398 = "1080p / 23.976 fps"
    case p1080_24   = "1080p / 24 fps"
    case i1080_2997 = "1080i / 29.97 fps (NTSC)"
    case i1080_25   = "1080i / 25 fps (PAL)"
    case p720_5994  = "720p / 59.94 fps"
    case p720_50    = "720p / 50 fps"
    case p720_2398  = "720p / 23.976 fps"
    case p720_24    = "720p / 24 fps"

    var id: String { rawValue }

    /// Compact label for job rows ("1080i29.97").
    var shortName: String {
        switch self {
        case .p1080_2398: return "1080p23.976"
        case .p1080_24:   return "1080p24"
        case .i1080_2997: return "1080i29.97"
        case .i1080_25:   return "1080i25"
        case .p720_5994:  return "720p59.94"
        case .p720_50:    return "720p50"
        case .p720_2398:  return "720p23.976"
        case .p720_24:    return "720p24"
        }
    }

    /// Value accepted by the headless CLI's `--standard` flag.
    var cliName: String { shortName.lowercased() }

    var width: Int {
        switch self {
        case .p1080_2398, .p1080_24, .i1080_2997, .i1080_25: return 1920
        case .p720_5994, .p720_50, .p720_2398, .p720_24:     return 1280
        }
    }

    var height: Int {
        switch self {
        case .p1080_2398, .p1080_24, .i1080_2997, .i1080_25: return 1080
        case .p720_5994, .p720_50, .p720_2398, .p720_24:     return 720
        }
    }

    /// Rational form for ffmpeg's `-r`.
    var frameRate: String {
        switch self {
        case .p1080_2398, .p720_2398: return "24000/1001"
        case .p1080_24, .p720_24:     return "24/1"
        case .i1080_2997:             return "30000/1001"
        case .i1080_25:               return "25/1"
        case .p720_5994:              return "60000/1001"
        case .p720_50:                return "50/1"
        }
    }

    /// Decimal frame rate for display and tsMuxeR meta files. For the 1080i
    /// standards this is the *frame* rate (two fields per frame).
    var frameRateValue: Double {
        switch self {
        case .p1080_2398, .p720_2398: return 24000.0 / 1001.0
        case .p1080_24, .p720_24:     return 24.0
        case .i1080_2997:             return 30000.0 / 1001.0
        case .i1080_25:               return 25.0
        case .p720_5994:              return 60000.0 / 1001.0
        case .p720_50:                return 50.0
        }
    }

    /// Keyint: Blu-ray limits GOP to ~1 second.
    var keyint: Int {
        switch self {
        case .p1080_2398, .p1080_24, .p720_2398, .p720_24: return 24
        case .i1080_2997: return 30
        case .i1080_25:   return 25
        case .p720_5994:  return 60
        case .p720_50:    return 50
        }
    }

    var h264Level: String {
        switch self {
        case .p1080_2398, .p1080_24, .i1080_2997, .i1080_25: return "4.1"
        case .p720_5994, .p720_50:                           return "4.1"
        case .p720_2398, .p720_24:                           return "4.0"
        }
    }

    var isInterlaced: Bool {
        self == .i1080_2997 || self == .i1080_25
    }

    /// The Blu-ray standard that carries a source's motion without dropping
    /// or repeating frames. Blu-ray has no 1080p25 or 1080p29.97, so 25p and
    /// 29.97p sources go out as 1080i flagged as progressive segmented
    /// frames, and 50p/59.94p sources are paired into fields. Rates that
    /// match nothing fall back to 1080p23.976.
    static func suggested(forFrameRate fps: Double, interlaced: Bool) -> VideoStandard {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.02 }
        if interlaced {
            if near(fps, 25) { return .i1080_25 }
            if near(fps, 29.97) || near(fps, 30) { return .i1080_2997 }
        }
        if near(fps, 23.976) { return .p1080_2398 }
        if near(fps, 24) { return .p1080_24 }
        if near(fps, 25) || near(fps, 50) { return .i1080_25 }
        if near(fps, 29.97) || near(fps, 30) || near(fps, 59.94) || near(fps, 60) { return .i1080_2997 }
        return .p1080_2398
    }

    /// How cleanly a source's frame rate maps onto this standard. Nil means
    /// every source frame (or field) lands on the disc once.
    func rateNote(sourceFrameRate fps: Double, sourceInterlaced: Bool) -> RateNote? {
        guard fps > 0 else { return nil }
        let target = frameRateValue
        // Candidate source cadences this standard can carry 1:1.
        var clean: [Double] = [target]
        if isInterlaced {
            // Progressive at the field rate pairs into fields.
            if !sourceInterlaced { clean.append(target * 2) }
        } else if sourceInterlaced {
            // bwdif send_field turns each field into a frame, so an
            // interlaced source at half the target rate maps 1:1.
            clean.append(target / 2)
        }
        func ratio(_ c: Double) -> Double { fps / c }
        if clean.contains(where: { abs(ratio($0) - 1) < 0.0002 }) { return nil }

        let sourceLabel = Self.formatRate(fps) + (sourceInterlaced ? "i" : " fps")
        let targetLabel = shortName
        // 1000/1001 pairs (24 vs 23.976, 30 vs 29.97, 60 vs 59.94).
        if clean.contains(where: { abs(ratio($0) - 1) < 0.0015 }) {
            let base = clean.first(where: { abs(ratio($0) - 1) < 0.0015 }) ?? target
            let secondsPerFrame = 1 / abs(fps - base)
            let verb = fps > base ? "dropped" : "repeated"
            return .minor("\(sourceLabel) source on \(targetLabel): one frame \(verb) every \(Int(secondsPerFrame.rounded())) s.")
        }
        let suggestion = Self.suggested(forFrameRate: fps, interlaced: sourceInterlaced)
        let hint = suggestion == self ? "" : " Use \(suggestion.shortName) instead."
        if fps > target {
            let dropped = (1 - target / fps) * 100
            return .major("\(sourceLabel) source on \(targetLabel) drops about \(Int(dropped.rounded()))% of frames, so motion will stutter.\(hint)")
        }
        let repeated = (target / fps - 1) * 100
        return .major("\(sourceLabel) source on \(targetLabel) repeats about \(Int(repeated.rounded()))% of frames, so motion will judder.\(hint)")
    }

    static func formatRate(_ fps: Double) -> String {
        let rounded = (fps * 1000).rounded() / 1000
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.3f", rounded)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func fromCLIName(_ name: String) -> VideoStandard? {
        allCases.first { $0.cliName == name.lowercased() }
    }
}

enum RateNote: Equatable, Sendable {
    /// 1000/1001 mismatch: a frame dropped or repeated every ~40 seconds.
    case minor(String)
    /// Visible stutter or judder.
    case major(String)

    var message: String {
        switch self {
        case .minor(let m), .major(let m): return m
        }
    }
}

// MARK: - Output mode

enum OutputMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bdmvFolder = "BDMV Folder (ready to burn)"
    case iso        = "ISO Disc Image (.iso)"
    case m2tsOnly   = "M2TS File Only (for Toast)"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .bdmvFolder: return "BDMV"
        case .iso:        return "ISO"
        case .m2tsOnly:   return "M2TS"
        }
    }
}

// MARK: - Chapters

enum ChaptersMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case none   = "None (auto-play only)"
    case auto5  = "Auto — every 5 min"
    case auto10 = "Auto — every 10 min"
    case custom = "Custom list"

    var id: String { rawValue }
}

struct ChaptersConfig: Equatable, Codable, Sendable {
    var mode: ChaptersMode = .auto5
    /// Used only when `mode == .custom`. Accepts comma, newline, or
    /// semicolon-separated entries in `HH:MM:SS`, `MM:SS`, or `SS` form.
    var customText: String = ""

    /// Computes chapter timestamps (seconds from start) for the given duration.
    /// Always yields 0.0 as the first entry when chapters are enabled.
    func chapterTimes(duration: Double) -> [Double] {
        switch mode {
        case .none:
            return []
        case .auto5:
            return autoChapters(interval: 300, duration: duration)
        case .auto10:
            return autoChapters(interval: 600, duration: duration)
        case .custom:
            let parsed = customText
                .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
                .compactMap { Self.parseTime(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { $0 >= 0 && $0 < duration }
            return ([0] + parsed).sorted().uniqued()
        }
    }

    private func autoChapters(interval: Double, duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        var times: [Double] = [0]
        var t = interval
        // Don't drop a chapter right at the end (< 5s before end).
        while t < duration - 5 {
            times.append(t)
            t += interval
        }
        return times
    }

    static func parseTime(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").map(String.init)
        let value: Double?
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let sec = Double(parts[2]) else { return nil }
            value = h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]),
                  let sec = Double(parts[1]) else { return nil }
            value = m * 60 + sec
        case 1:
            value = Double(parts[0])
        default:
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }
}

private extension Array where Element: Equatable {
    func uniqued() -> [Element] {
        var result: [Element] = []
        for item in self where !result.contains(item) {
            result.append(item)
        }
        return result
    }
}

// MARK: - Settings

/// Sidebar settings. Pending jobs read these when they start, so changing a
/// setting affects every job that hasn't run yet. Per-job choices (video
/// standard override, audio source, subtitles) live on `EncodeJob`.
struct EncodeSettings: Equatable, Codable, Sendable {
    var discSize: DiscSize = .bd25
    /// Nil means pick the standard that matches each source's frame rate.
    var videoStandard: VideoStandard? = nil
    var outputMode: OutputMode = .bdmvFolder
    var audioBitrateKbps: Int = 640     // 448 or 640
    var twoPass: Bool = true
    var chapters = ChaptersConfig()
    /// Nil means write output next to each source file.
    var outputFolderPath: String? = nil

    var outputFolder: URL? {
        outputFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static let defaultsKey = "encodeSettings.v1"

    static func load(from defaults: UserDefaults = .standard) -> EncodeSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(EncodeSettings.self, from: data)
        else { return EncodeSettings() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Media info

/// One audio stream as reported by ffprobe. Layout is the *semantic* tag
/// ("5.1", "7.1(side)", "stereo", "downmix") not just channel count, because
/// 8 channels can mean true 7.1 *or* 5.1 + Lt/Rt matrix stereo and they need
/// different downstream handling.
struct AudioStreamInfo: Equatable, Sendable, Identifiable {
    /// ffmpeg stream index — passed verbatim to `-map 0:N`.
    var ffmpegIndex: Int
    var codec: String
    var channels: Int
    /// Layout tag as reported by ffprobe; empty when the source didn't tag it.
    var layout: String
    var sampleRate: Int?
    var language: String?
    /// Track title metadata, if any. Helps disambiguate "5.1 program" from
    /// "Lt/Rt fold-down" when a file carries multiple tracks.
    var title: String?
    /// Seconds; compared with the video's start to keep a delayed track in sync.
    var startTime: Double = 0

    var id: Int { ffmpegIndex }

    var isMono: Bool { channels == 1 }

    /// Display string for the stream picker: "5.1 PCM, English, “Main mix”".
    var displayLabel: String {
        var parts = ["\(layout.isEmpty ? "\(channels)-channel" : layout) \(Self.codecName(codec))"]
        if let language, !language.isEmpty, language != "und" {
            parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        if let title, !title.isEmpty {
            parts.append("“\(title)”")
        }
        return parts.joined(separator: ", ")
    }

    static func codecName(_ codec: String) -> String {
        if codec.hasPrefix("pcm_") { return "PCM" }
        switch codec {
        case "aac": return "AAC"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "truehd": return "TrueHD"
        case "dts": return "DTS"
        default: return codec.uppercased()
        }
    }

    /// True when channel count and layout disagree in a way that suggests the
    /// real layout is ambiguous — most commonly 8 channels with no layout tag,
    /// which could be 7.1 or 5.1+Lt/Rt and a human needs to confirm.
    var isAmbiguous: Bool {
        channels >= 8 && (layout.isEmpty || layout.lowercased() == "unknown")
    }
}

/// Channel order of a set of discrete mono tracks.
enum DiscreteOrder: String, Codable, Sendable, CaseIterable {
    /// L R C LFE Ls Rs: SMPTE/ITU order, the default in Resolve, Premiere
    /// and Final Cut exports.
    case smpte
    /// L C R Ls Rs LFE: film (Pro Tools) order.
    case film

    var label: String {
        switch self {
        case .smpte: return "L R C LFE Ls Rs"
        case .film:  return "L C R Ls Rs LFE"
        }
    }
}

/// Where the disc's audio comes from.
enum AudioSource: Hashable, Codable, Sendable {
    /// One source stream, downmixed to 5.1 if it has more channels.
    case stream(Int)
    /// Several mono streams joined into one program: 2 streams make stereo,
    /// 6 make 5.1 in the given channel order.
    case discrete([Int], DiscreteOrder)
    /// No audio in the source: the disc gets a silent stereo track, since
    /// some players refuse a title without audio.
    case silence

    var channelCount: Int {
        switch self {
        case .stream: return 0  // depends on the stream
        case .discrete(let idx, _): return idx.count
        case .silence: return 2
        }
    }
}

struct AudioOption: Hashable, Identifiable, Sendable {
    var source: AudioSource
    var label: String
    var id: AudioSource { source }
}

struct MediaInfo: Equatable, Sendable {
    var duration: Double
    var width: Int
    var height: Int
    var videoCodec: String
    var frameRate: Double
    var audioStreams: [AudioStreamInfo]
    var sourceIsInterlaced: Bool
    /// ffprobe `color_transfer`, `color_primaries`, `color_space`; empty when untagged.
    var colorTransfer: String = ""
    var colorPrimaries: String = ""
    var colorSpace: String = ""
    var pixelFormat: String = ""
    /// ffmpeg index of the film's video stream (cover art is skipped).
    var videoStreamIndex: Int = 0
    /// Pixel aspect ratio; 1 for square pixels. Anamorphic DV is 32:27 or 8:9.
    var sampleAspect: Double = 1
    var videoStartTime: Double = 0

    /// PQ (HDR10, Dolby Vision base layer) or HLG.
    var isHDR: Bool {
        colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }

    /// Standard-definition matrices that need converting to BT.709.
    var usesBT601Matrix: Bool {
        ["smpte170m", "bt470bg", "bt601"].contains(colorSpace)
    }

    var firstAudioStream: AudioStreamInfo? { audioStreams.first }

    var monoStreams: [AudioStreamInfo] { audioStreams.filter(\.isMono) }

    func audioStream(index: Int) -> AudioStreamInfo? {
        audioStreams.first { $0.ffmpegIndex == index }
    }

    /// Every audio choice the job picker offers, single streams first.
    var audioOptions: [AudioOption] {
        if audioStreams.isEmpty {
            return [AudioOption(source: .silence, label: "No audio in source (silent track)")]
        }
        var options = audioStreams.map {
            AudioOption(source: .stream($0.ffmpegIndex), label: "Track \($0.ffmpegIndex), \($0.displayLabel)")
        }
        let mono = monoStreams.map(\.ffmpegIndex)
        if mono.count >= 6 {
            let six = Array(mono.prefix(6))
            for order in DiscreteOrder.allCases {
                options.append(AudioOption(
                    source: .discrete(six, order),
                    label: "Mono tracks \(Self.rangeLabel(six)) as 5.1 (\(order.label))"
                ))
            }
        }
        if mono.count >= 2 {
            let two = Array(mono.prefix(2))
            options.append(AudioOption(
                source: .discrete(two, .smpte),
                label: "Mono tracks \(Self.rangeLabel(two)) as stereo (L R)"
            ))
        }
        return options
    }

    func label(for source: AudioSource) -> String {
        audioOptions.first { $0.source == source }?.label ?? "Unknown audio"
    }

    private static func rangeLabel(_ idx: [Int]) -> String {
        guard let first = idx.first, let last = idx.last else { return "" }
        let contiguous = zip(idx, idx.dropFirst()).allSatisfy { $1 == $0 + 1 }
        return contiguous ? "\(first)–\(last)" : idx.map(String.init).joined(separator: ",")
    }
}

// MARK: - Job

enum JobStatus: String, Equatable, Sendable {
    case pending   = "Pending"
    case running   = "Running"
    case done      = "Done"
    case failed    = "Failed"
    case cancelled = "Stopped"

    var canRetry: Bool { self == .failed || self == .cancelled }
    var isEditable: Bool { self == .pending || canRetry }
}

enum EncodeStage: String, Equatable, Sendable {
    case idle          = "Idle"
    case checking      = "Checking"
    case encodingVideo = "Encoding video"
    case encodingAudio = "Encoding audio"
    case muxing        = "Authoring disc"
    case done          = "Done"
    case failed        = "Failed"
}

struct EncodeJob: Identifiable, Equatable, Sendable {
    let id: UUID
    var inputURL: URL
    var mediaInfo: MediaInfo
    /// Per-job video standard. Nil follows the sidebar setting.
    var standardOverride: VideoStandard?
    var audioSource: AudioSource
    /// Optional .srt file. When present, tsMuxeR converts it to PGS at mux
    /// time so the disc gets viewer-selectable soft subtitles.
    var subtitleURL: URL?
    /// ISO 639-2/B language code (3-letter) tagged on the PGS track. Players
    /// that filter subtitle tracks by preferred language need this to match.
    var subtitleLanguageCode: String = "eng"
    var status: JobStatus = .pending
    var stage: EncodeStage = .idle
    var progress: Double = 0
    var startedAt: Date?
    var errorMessage: String?
    /// Set when the job finishes or fails after writing a log.
    var outputURL: URL?
    var logURL: URL?

    init(inputURL: URL, mediaInfo: MediaInfo) {
        self.id = UUID()
        self.inputURL = inputURL
        self.mediaInfo = mediaInfo
        self.audioSource = AudioStreamPicker.bestSource(for: mediaInfo)
    }

    func standard(with settings: EncodeSettings) -> VideoStandard {
        standardOverride
            ?? settings.videoStandard
            ?? VideoStandard.suggested(forFrameRate: mediaInfo.frameRate,
                                       interlaced: mediaInfo.sourceIsInterlaced)
    }
}
