import Foundation

/// Video and audio encoding with Blu-ray-compliant parameters.
struct BluRayEncoder {
    let ffmpeg: URL

    // MARK: - Bitrate math

    /// Blu-ray H.264 max is 40 Mbps total A/V; leave headroom under 35 Mbps
    /// for video so audio + mux overhead never push us past spec.
    static let videoBitrateCeiling = 34_500_000

    /// Recommended quality floor for 1080p Blu-ray content. Picture quality
    /// visibly degrades below this rate. Not a hard limit — long titles may
    /// fall below it to fit the disc, in which case the coordinator surfaces
    /// a warning. 720p content tolerates lower bitrates but we use the same
    /// threshold for the warning to err on the side of flagging.
    static let videoBitrateQualityFloor = 8_000_000

    /// Encoder-sane absolute minimum. libx264 will accept lower values but
    /// the picture becomes unwatchable. If the disc-fit math wants a value
    /// even lower than this, the duration × disc-size × audio-rate combo is
    /// physically impossible — the coordinator detects this and fails the
    /// job with a useful error rather than silently producing oversized
    /// output (the previous bug: an 8 Mbps "floor" forced the math to lie
    /// when long titles couldn't actually fit at that rate).
    static let videoBitrateAbsoluteFloor = 1_000_000

    /// Target video bitrate (bps) so the encode fits the disc, capped at the
    /// Blu-ray H.264 ceiling. NOTE: the result is also clamped at a 1 Mbps
    /// absolute floor so libx264 always has a workable target. The caller
    /// should check `fitsOnDisc(...)` separately to detect the case where
    /// the title is too long to fit on the selected disc — in that case the
    /// returned bitrate alone will not actually fit the encode.
    static func videoBitrate(
        durationSeconds: Double,
        discBytes: Int64,
        audioBitsPerSecond: Int
    ) -> Int {
        guard durationSeconds > 0 else { return 15_000_000 }
        let totalBits = Double(discBytes) * 8
        let audioBits = Double(audioBitsPerSecond) * durationSeconds
        let usable = max(totalBits - audioBits, 0)
        let bps = usable / durationSeconds
        return max(videoBitrateAbsoluteFloor,
                   min(videoBitrateCeiling, Int(bps)))
    }

    /// True when the requested bitrate actually fits on the disc with the
    /// requested audio for the given duration. Use this AFTER `videoBitrate`
    /// to catch the case where the math's hard floor (1 Mbps) is higher
    /// than the disc-fit value would naturally be, i.e. the title is
    /// physically too long to fit at any usable encode quality.
    static func fitsOnDisc(
        videoBitrate: Int,
        durationSeconds: Double,
        discBytes: Int64,
        audioBitsPerSecond: Int
    ) -> Bool {
        guard durationSeconds > 0 else { return true }
        let totalBits = Double(discBytes) * 8
        let plannedBits = Double(videoBitrate) * durationSeconds
            + Double(audioBitsPerSecond) * durationSeconds
        return plannedBits <= totalBits
    }

    // MARK: - Video

    /// What the bundled ffmpeg can do beyond the basics. Detected once at
    /// launch so a Homebrew ffmpeg without zimg still works, minus HDR
    /// tonemapping.
    struct Capabilities: Equatable, Sendable {
        var canTonemapHDR: Bool

        static let none = Capabilities(canTonemapHDR: false)
    }

    /// The `-vf` chain for one encode. Order matters:
    ///
    ///   [bwdif?] → [HDR tonemap?] → scale → pad → setsar → [interlace|setfield?] → format
    static func videoFilterChain(
        standard: VideoStandard,
        source: MediaInfo,
        capabilities: Capabilities
    ) -> String {
        let w = standard.width
        let h = standard.height
        let sourceFrameRate = source.frameRate
        var filters: [String] = []

        if !standard.isInterlaced && source.sourceIsInterlaced {
            // Interlaced → progressive needs a real deinterlacer, and it has
            // to run BEFORE the scaler, or the scaler blends the two fields
            // of each combed frame together first. `send_field` turns every
            // field into a frame when the target rate is ~2× the source
            // frame rate (1080i29.97 → 720p59.94), keeping all the motion;
            // `send_frame` covers everything else. `parity=auto` reads the
            // source's field order tag.
            let ratio = sourceFrameRate > 0 ? standard.frameRateValue / sourceFrameRate : 0
            let mode = abs(ratio - 2.0) < 0.05 ? "send_field" : "send_frame"
            filters.append("bwdif=mode=\(mode):parity=auto:deint=all")
        }

        if source.isHDR && capabilities.canTonemapHDR {
            // PQ/HLG → linear light → BT.709 primaries → Hable tonemap →
            // BT.709 transfer. Without this, HDR pixels tagged as BT.709
            // play back flat and washed out.
            let tin = source.colorTransfer
            filters.append("zscale=tin=\(tin):min=bt2020nc:pin=bt2020:t=linear:npl=100")
            filters.append("format=gbrpf32le")
            filters.append("zscale=p=bt709")
            filters.append("tonemap=tonemap=hable:desat=0")
            filters.append("zscale=t=bt709:m=bt709:r=tv")
        }

        if abs(source.sampleAspect - 1) > 0.01 {
            // Anamorphic source: stretch to square pixels first, or the fit
            // below works from the stored width and squeezes the picture.
            // Horizontal only, so interlaced fields stay apart.
            filters.append("scale=trunc(iw*sar/2)*2:ih:flags=lanczos")
            filters.append("setsar=1")
        }

        // `force_original_aspect_ratio=decrease` fits the source inside the
        // frame without stretching; `pad` adds the black bars. Letterboxes
        // scope/1.85/DCI, pillarboxes 4:3, no-op for 16:9.
        var scale = "scale=\(w):\(h):flags=lanczos:force_original_aspect_ratio=decrease"
        if source.usesBT601Matrix && !source.isHDR {
            // SD sources use the BT.601 matrix; Blu-ray HD is BT.709.
            scale += ":in_color_matrix=bt601:out_color_matrix=bt709"
        }
        scale += ":out_range=tv"
        if standard.isInterlaced && source.sourceIsInterlaced {
            // Interlaced in and out: scale each field separately so the
            // fields don't smear into each other.
            scale += ":interl=1"
        }
        filters.append(scale)
        filters.append("pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black")
        filters.append("setsar=1/1")

        if standard.isInterlaced && !source.sourceIsInterlaced {
            // Progressive → interlaced. Only a source at ~2× the target
            // frame rate (50p → 25i, 59.94p → 29.97i) gets paired into
            // fields; anything else is flagged as progressive segmented
            // frames, which keeps its cadence. The tolerance excludes
            // cross-standard cases like 50p → 29.97i (ratio 1.67), where
            // pairing would stutter.
            let ratio = standard.frameRateValue > 0 ? sourceFrameRate / standard.frameRateValue : 0
            if abs(ratio - 2.0) < 0.05 {
                filters.append("interlace=scan=tff:lowpass=0")
            } else {
                filters.append("setfield=mode=tff")
            }
        }
        filters.append("format=yuv420p")
        return filters.joined(separator: ",")
    }

    static func x264Params(standard: VideoStandard) -> String {
        var params: [String] = [
            "bluray-compat=1",
            "level=\(standard.h264Level)",
            "keyint=\(standard.keyint)",
            "min-keyint=\(standard.keyint)",
            "bframes=3",
            "b-pyramid=strict",
            "weightp=0",
            "weightb=1",
            "ref=3",
            "aud=1",
            "nal-hrd=vbr",
            "colorprim=bt709",
            "transfer=bt709",
            "colormatrix=bt709",
            "slices=4"
        ]
        if standard.isInterlaced {
            // libx264 accepts `tff=1`. `interlaced=tff` fails to parse and
            // ffmpeg silently falls back to progressive.
            params.append("tff=1")
        }
        return params.joined(separator: ":")
    }

    func encodeVideo(
        input: URL,
        videoOut: URL,
        workDir: URL,
        bitrate: Int,
        standard: VideoStandard,
        source: MediaInfo,
        capabilities: Capabilities,
        twoPass: Bool,
        logger: RunLogger? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let vf = Self.videoFilterChain(standard: standard, source: source,
                                       capabilities: capabilities)
        let x264Joined = Self.x264Params(standard: standard)
        let bitrateK = "\(bitrate / 1000)k"
        let duration = source.duration

        func baseArgs(pass: Int?, passlog: URL?) -> [String] {
            var args: [String] = [
                "-hide_banner", "-y",
                "-i", input.path,
                "-map", "0:\(source.videoStreamIndex)",
                "-an", "-sn", "-dn",
                "-vf", vf,
                "-r", standard.frameRate,
                "-c:v", "libx264",
                "-preset", "slow",
                "-profile:v", "high",
                "-level:v", standard.h264Level,
                "-pix_fmt", "yuv420p",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709",
                "-b:v", bitrateK,
                "-maxrate", "35000k",
                "-bufsize", "30000k",
                "-x264-params", x264Joined,
                "-f", "h264",
                "-progress", "pipe:1",
                "-nostats"
            ]
            if standard.isInterlaced {
                // Field order comes from x264's `tff=1` and the filter
                // chain. Don't add `-top 1`: ffmpeg 9 rejects it as an
                // encoder option and refuses to start.
                args += ["-flags", "+ildct+ilme"]
            }
            if let p = pass, let log = passlog {
                args += ["-pass", "\(p)", "-passlogfile", log.path]
            }
            return args
        }

        if twoPass {
            // The stats files live in the job's work directory, which the
            // pipeline deletes on success, failure and cancel alike.
            let passlog = workDir.appendingPathComponent("x264-pass")

            var p1 = baseArgs(pass: 1, passlog: passlog)
            p1 += ["/dev/null"]
            try await runFFmpeg(args: p1, duration: duration, logger: logger,
                                subprocessName: "ffmpeg video pass 1") { frac in
                progress(frac * 0.5)
            }

            var p2 = baseArgs(pass: 2, passlog: passlog)
            p2.append(videoOut.path)
            try await runFFmpeg(args: p2, duration: duration, logger: logger,
                                subprocessName: "ffmpeg video pass 2") { frac in
                progress(0.5 + frac * 0.5)
            }
        } else {
            var args = baseArgs(pass: nil, passlog: nil)
            args.append(videoOut.path)
            try await runFFmpeg(args: args, duration: duration, logger: logger,
                                subprocessName: "ffmpeg video", progress: progress)
        }
    }

    // MARK: - Audio

    /// ffmpeg arguments (minus `-progress` and the output path) that turn the
    /// chosen audio source into AC-3. Single streams with more than six
    /// channels are downmixed to 5.1 by ffmpeg's standard matrix; discrete
    /// mono tracks are joined into one program in the given channel order.
    /// Filter that lines the audio up with the video. The raw AC-3 and
    /// H.264 streams both start at zero, so a track that begins later (or
    /// earlier) than the picture in the source has to be padded (or trimmed)
    /// here, or it plays out of sync on the disc.
    static func syncFilter(audioStart: Double, videoStart: Double) -> String? {
        let offset = audioStart - videoStart
        guard offset.isFinite, abs(offset) >= 0.001 else { return nil }
        if offset > 0 {
            return "adelay=delays=\(Int((offset * 1000).rounded())):all=1"
        }
        return String(format: "atrim=start=%.6f,asetpts=PTS-STARTPTS", -offset)
    }

    static func audioArguments(
        source: AudioSource,
        input: URL,
        info: MediaInfo,
        bitrateKbps: Int
    ) -> [String] {
        switch source {
        case .stream(let index):
            let stream = info.audioStream(index: index)
            let sourceChannels = stream?.channels ?? 2
            let channels = min(max(sourceChannels, 1), 6)
            var args = [
                "-i", input.path,
                "-map", "0:\(index)",
                "-vn", "-sn", "-dn"
            ]
            if let sync = syncFilter(audioStart: stream?.startTime ?? 0, videoStart: info.videoStartTime) {
                args += ["-af", sync]
            }
            return args + [
                "-c:a", "ac3",
                "-b:a", "\(min(bitrateKbps, maxAC3Bitrate(channels: channels)))k",
                "-ac", "\(channels)",
                "-ar", "48000"
            ]
        case .discrete(let indices, let order):
            let inputs = indices.map { "[0:\($0)]" }.joined()
            let layout: String
            let channelNames: [String]
            if indices.count >= 6 {
                layout = "5.1"
                switch order {
                case .smpte: channelNames = ["FL", "FR", "FC", "LFE", "BL", "BR"]
                case .film:  channelNames = ["FL", "FC", "FR", "BL", "BR", "LFE"]
                }
            } else {
                layout = "stereo"
                channelNames = ["FL", "FR"]
            }
            let used = Array(indices.prefix(channelNames.count))
            let map = zip(used.indices, channelNames)
                .map { "\($0).0-\($1)" }
                .joined(separator: "|")
            var graph = "\(inputs)join=inputs=\(used.count):channel_layout=\(layout):map=\(map)"
            if let sync = syncFilter(audioStart: info.audioStream(index: used[0])?.startTime ?? 0,
                                     videoStart: info.videoStartTime) {
                graph += ",\(sync)"
            }
            graph += "[aout]"
            return [
                "-i", input.path,
                "-filter_complex", graph,
                "-map", "[aout]",
                "-c:a", "ac3",
                "-b:a", "\(min(bitrateKbps, maxAC3Bitrate(channels: used.count)))k",
                "-ar", "48000"
            ]
        case .silence:
            return [
                "-f", "lavfi",
                "-i", "anullsrc=r=48000:cl=stereo",
                "-t", String(format: "%.3f", info.duration),
                "-c:a", "ac3",
                "-b:a", "192k"
            ]
        }
    }

    /// Stereo and mono AC-3 above 448 kbps wastes disc space and some
    /// encoders reject it, so cap them.
    static func maxAC3Bitrate(channels: Int) -> Int {
        channels >= 3 ? 640 : 448
    }

    func encodeAudio(
        input: URL,
        audioOut: URL,
        source: AudioSource,
        info: MediaInfo,
        bitrateKbps: Int,
        logger: RunLogger? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var args = ["-hide_banner", "-y"]
        args += Self.audioArguments(source: source, input: input, info: info,
                                    bitrateKbps: bitrateKbps)
        args += ["-progress", "pipe:1", "-nostats", "-f", "ac3", audioOut.path]
        try await runFFmpeg(args: args, duration: info.duration, logger: logger,
                            subprocessName: "ffmpeg audio", progress: progress)
    }

    // MARK: - Helper

    private func runFFmpeg(
        args: [String],
        duration: Double,
        logger: RunLogger?,
        subprocessName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let recorder = logger?.beginSubprocess(
            name: subprocessName, executable: ffmpeg, arguments: args
        )
        do {
            let result = try await ProcessRunner.run(
                ffmpeg,
                arguments: args,
                onStdoutLine: { line in
                    // FFmpeg -progress writes key=value lines. We parse `out_time=`
                    // which is HH:MM:SS.ffffff — unambiguous across ffmpeg versions.
                    if line.hasPrefix("out_time=") {
                        let v = line.dropFirst("out_time=".count)
                        // Before the first frame ffmpeg reports "N/A" or a
                        // negative time; skip those.
                        if v.hasPrefix("-") || v.hasPrefix("N") { return }
                        let parts = v.split(separator: ":")
                        if parts.count == 3,
                           let h = Double(parts[0]),
                           let m = Double(parts[1]),
                           let s = Double(parts[2]) {
                            let seconds = h * 3600 + m * 60 + s
                            if duration > 0 {
                                let frac = min(max(seconds / duration, 0), 1)
                                progress(frac)
                            }
                        }
                    } else if line.hasPrefix("progress=end") {
                        progress(1.0)
                    }
                },
                onStderrLine: { line in
                    recorder?.recordStderr(line)
                }
            )
            recorder?.finish(exitCode: result.exitCode)
        } catch {
            recorder?.finish(exitCode: -1)
            throw error
        }
    }
}
