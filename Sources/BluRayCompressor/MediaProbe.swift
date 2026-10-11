import Foundation

struct MediaProbe {
    let ffprobe: URL

    func probe(_ url: URL) async throws -> MediaInfo {
        let args = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]
        let result = try await ProcessRunner.run(ffprobe, arguments: args)
        guard let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(
                domain: "MediaProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ffprobe returned invalid JSON"]
            )
        }
        return try parse(json)
    }

    func parse(_ json: [String: Any]) throws -> MediaInfo {
        let format = json["format"] as? [String: Any] ?? [:]
        let duration = Double((format["duration"] as? String) ?? "0") ?? 0

        let streams = json["streams"] as? [[String: Any]] ?? []
        var video: [String: Any]?
        var audioStreams: [AudioStreamInfo] = []
        for s in streams {
            let type = s["codec_type"] as? String ?? ""
            if type == "video", video == nil {
                video = s
            } else if type == "audio" {
                audioStreams.append(parseAudio(s))
            }
        }

        guard let v = video else {
            throw NSError(
                domain: "MediaProbe", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No video stream found in file."]
            )
        }

        let width  = (v["width"]  as? Int) ?? 0
        let height = (v["height"] as? Int) ?? 0
        let codec  = (v["codec_name"] as? String) ?? "unknown"
        // Prefer `avg_frame_rate` over `r_frame_rate`. For genuine interlaced
        // sources (1080i/29.97), ffprobe's `r_frame_rate` reports the *field*
        // rate (60000/1001), not the frame rate (30000/1001) — so a true 1080i
        // source would display as "59.94 fps" and feed the wrong number into
        // any rate-aware logic. `avg_frame_rate` returns the actual frame
        // rate. Fall back to `r_frame_rate` only when `avg_frame_rate` is
        // missing or zero (e.g. some live captures or VFR sources).
        let avgFps = parseRational((v["avg_frame_rate"] as? String) ?? "0/1")
        let rFps   = parseRational((v["r_frame_rate"]   as? String) ?? "0/1")
        let fps    = avgFps > 0 ? avgFps : rFps

        // ffprobe reports field_order as "progressive", "tt", "bb", "tb", "bt",
        // or is absent for sources where it can't be determined. Treat anything
        // other than "progressive" (or absent) as interlaced.
        let fieldOrder = (v["field_order"] as? String)?.lowercased() ?? "progressive"
        let sourceIsInterlaced = !(fieldOrder == "progressive" || fieldOrder.isEmpty
                                   || fieldOrder == "unknown")

        // Some containers (MXF, raw streams) leave format duration empty but
        // carry it on the video stream.
        let streamDuration = Double((v["duration"] as? String) ?? "0") ?? 0
        let resolvedDuration = duration > 0 ? duration : streamDuration
        guard resolvedDuration > 0 else {
            throw NSError(
                domain: "MediaProbe", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't read the file's duration."]
            )
        }

        return MediaInfo(
            duration: resolvedDuration,
            width: width,
            height: height,
            videoCodec: codec,
            frameRate: fps,
            audioStreams: audioStreams,
            sourceIsInterlaced: sourceIsInterlaced,
            colorTransfer: (v["color_transfer"] as? String) ?? "",
            colorPrimaries: (v["color_primaries"] as? String) ?? "",
            colorSpace: (v["color_space"] as? String) ?? "",
            pixelFormat: (v["pix_fmt"] as? String) ?? ""
        )
    }

    private func parseAudio(_ s: [String: Any]) -> AudioStreamInfo {
        let index = (s["index"] as? Int) ?? 0
        let codec = (s["codec_name"] as? String) ?? "unknown"
        let channels = (s["channels"] as? Int) ?? 0
        let layout = (s["channel_layout"] as? String) ?? ""
        let sampleRate = Int((s["sample_rate"] as? String) ?? "0")
        let tags = s["tags"] as? [String: Any] ?? [:]
        let language = (tags["language"] as? String)
            ?? (tags["LANGUAGE"] as? String)
        // QuickTime handler names like "SoundHandler" or "Core Media Audio"
        // say nothing about the track, so only a real name counts as a title.
        let handler = (tags["handler_name"] as? String).flatMap { name -> String? in
            let generic = ["soundhandler", "core media audio", "apple sound media handler",
                           "sound media handler", "gpac isomedia handler"]
            return generic.contains(name.lowercased()) || name.isEmpty ? nil : name
        }
        let title = (tags["title"] as? String)
            ?? (tags["TITLE"] as? String)
            ?? handler
        return AudioStreamInfo(
            ffmpegIndex: index,
            codec: codec,
            channels: channels,
            layout: layout,
            sampleRate: sampleRate,
            language: language,
            title: title
        )
    }

    private func parseRational(_ str: String) -> Double {
        let parts = str.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
        return parts.first ?? 0
    }
}

// MARK: - Audio stream selection

enum AudioStreamPicker {
    /// Picks the disc's audio. A multichannel stream wins. Without one, six
    /// or more discrete mono tracks (how Resolve and Premiere often export a
    /// 5.1 master) are joined into 5.1, and two mono tracks into stereo.
    static func bestSource(for info: MediaInfo) -> AudioSource {
        guard let best = bestStream(from: info.audioStreams) else { return .silence }
        let mono = info.monoStreams.map(\.ffmpegIndex)
        if best.channels < 6 && mono.count >= 6 {
            return .discrete(Array(mono.prefix(6)), .smpte)
        }
        if best.channels < 2 && mono.count >= 2 {
            return .discrete(Array(mono.prefix(2)), .smpte)
        }
        return .stream(best.ffmpegIndex)
    }

    /// Picks the audio stream most likely to be the primary surround program.
    /// Prefers the highest channel count, then a tagged surround layout
    /// (5.1 or 7.1) over an untagged one, then the first stream as a tiebreak.
    /// Returns nil only when the file has no audio streams.
    static func bestStream(from streams: [AudioStreamInfo]) -> AudioStreamInfo? {
        guard !streams.isEmpty else { return nil }
        return streams.max { lhs, rhs in
            // `max(by:)` returns the element where the closure is false for
            // the comparison `lhs < rhs`, so this ranks higher = "better".
            score(lhs) < score(rhs)
        }
    }

    private static func score(_ s: AudioStreamInfo) -> Int {
        var score = s.channels * 100
        let lower = s.layout.lowercased()
        if lower.hasPrefix("7.1") { score += 50 }
        else if lower.hasPrefix("5.1") { score += 40 }
        else if lower == "stereo" { score += 10 }
        // Slight penalty for streams whose title or language tag suggests they
        // are a fold-down/commentary, so a 2.0 "Lt/Rt" doesn't beat a 5.1
        // program when they happen to tie on channel count.
        let title = (s.title ?? "").lowercased()
        if title.contains("lt/rt") || title.contains("ltrt")
            || title.contains("downmix") || title.contains("fold")
            || title.contains("commentary") || title.contains("descriptive") {
            score -= 20
        }
        return score
    }
}
