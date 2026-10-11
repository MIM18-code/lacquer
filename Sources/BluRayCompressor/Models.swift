import Foundation

// MARK: - Disc size

enum DiscSize: String, CaseIterable, Identifiable, Sendable {
    case bd25 = "BD-25 (25 GB, single layer)"
    case bd50 = "BD-50 (50 GB, dual layer)"

    var id: String { rawValue }

    /// Usable bytes after UDF + BDMV overhead (~2%).
    var usableBytes: Int64 {
        switch self {
        case .bd25: return 23_400_000_000
        case .bd50: return 46_800_000_000
        }
    }
}

// MARK: - Video standard

enum VideoStandard: String, CaseIterable, Identifiable, Sendable {
    case p1080_2398 = "1080p / 23.976 fps"
    case p1080_24   = "1080p / 24 fps"
    case i1080_2997 = "1080i / 29.97 fps (NTSC)"
    case i1080_25   = "1080i / 25 fps (PAL)"
    case p720_5994  = "720p / 59.94 fps"
    case p720_50    = "720p / 50 fps"
    case p720_2398  = "720p / 23.976 fps"
    case p720_24    = "720p / 24 fps"

    var id: String { rawValue }

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

    /// Decimal frame rate for display and tsMuxeR meta files.
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
}

// MARK: - Output mode

enum OutputMode: String, CaseIterable, Identifiable, Sendable {
    case bdmvFolder = "BDMV Folder (ready to burn)"
    case iso        = "ISO Disc Image (.iso)"
    case m2tsOnly   = "M2TS File Only (for Toast)"

    var id: String { rawValue }
}

// MARK: - Chapters

enum ChaptersMode: String, CaseIterable, Identifiable, Sendable {
    case none   = "None (auto-play only)"
    case auto5  = "Auto — every 5 min"
    case auto10 = "Auto — every 10 min"
    case custom = "Custom list"

    var id: String { rawValue }
}

struct ChaptersConfig: Equatable, Sendable {
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

    private static func parseTime(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]),
                  let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        case 1:
            return Double(parts[0])
        default:
            return nil
        }
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

// MARK: - Preset

struct BluRayPreset: Equatable, Sendable {
    var discSize: DiscSize
    var standard: VideoStandard
    var outputMode: OutputMode
    var audioBitrateKbps: Int     // 448 or 640
    var twoPass: Bool
    var chapters: ChaptersConfig

    static let `default` = BluRayPreset(
        discSize: .bd25,
        standard: .p1080_2398,
        outputMode: .bdmvFolder,
        audioBitrateKbps: 640,
        twoPass: true,
        chapters: ChaptersConfig()
    )
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

    var id: Int { ffmpegIndex }

    /// Display string for the stream picker — short and dense.
    var displayLabel: String {
        var parts: [String] = []
        parts.append(layout.isEmpty ? "\(channels)ch" : layout)
        parts.append(codec.uppercased())
        if let language, !language.isEmpty, language != "und" {
            parts.append(language)
        }
        if let title, !title.isEmpty {
            parts.append("“\(title)”")
        }
        return parts.joined(separator: " · ")
    }

    /// True when channel count and layout disagree in a way that suggests the
    /// real layout is ambiguous — most commonly 8 channels with no layout tag,
    /// which could be 7.1 or 5.1+Lt/Rt and a human needs to confirm.
    var isAmbiguous: Bool {
        channels >= 8 && (layout.isEmpty || layout.lowercased() == "unknown")
    }
}

struct MediaInfo: Equatable, Sendable {
    var duration: Double
    var width: Int
    var height: Int
    var videoCodec: String
    var frameRate: Double
    var audioStreams: [AudioStreamInfo]
    var sourceIsInterlaced: Bool

    /// Convenience accessor for the first stream — used by the auto-picker
    /// fallback when nothing scored higher.
    var firstAudioStream: AudioStreamInfo? { audioStreams.first }
}

// MARK: - Job

enum JobStatus: String, Equatable, Sendable {
    case pending = "Pending"
    case running = "Running"
    case done    = "Done"
    case failed  = "Failed"
}

enum EncodeStage: String, Equatable, Sendable {
    case idle          = "Idle"
    case probing       = "Analyzing source"
    case encodingVideo = "Encoding video"
    case encodingAudio = "Encoding audio"
    case muxing        = "Authoring BDMV"
    case done          = "Done"
    case failed        = "Failed"
}

struct EncodeJob: Identifiable, Equatable, Sendable {
    let id: UUID
    var inputURL: URL
    var outputURL: URL
    var preset: BluRayPreset
    var mediaInfo: MediaInfo?
    /// ffmpeg stream index of the audio track to encode. Defaults to the
    /// auto-picked best track; the user can override before running.
    var selectedAudioIndex: Int?
    /// Optional .srt file. When present, tsMuxeR converts it to PGS at mux
    /// time so the disc gets viewer-selectable soft subtitles.
    var subtitleURL: URL?
    /// ISO 639-2/B language code (3-letter) tagged on the PGS track. Players
    /// that filter subtitle tracks by preferred language need this to match.
    /// Defaults to "eng"; user can override per job when attaching the .srt.
    var subtitleLanguageCode: String = "eng"
    var status: JobStatus = .pending
    var stage: EncodeStage = .idle
    var progress: Double = 0
    var stageProgress: Double = 0
    var errorMessage: String?

    init(inputURL: URL, outputURL: URL, preset: BluRayPreset) {
        self.id = UUID()
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.preset = preset
    }
}
